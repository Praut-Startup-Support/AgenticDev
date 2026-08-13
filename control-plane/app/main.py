"""
AgenticDev — Control Plane (L2)

Vydává podepsané work ordery, drží leases, přijímá idempotentní write-back.
Záměrně bez ORM: schéma je zdroj pravdy, ne Python třídy.
"""
from __future__ import annotations

import base64, hashlib, json, os, uuid
from datetime import datetime, timedelta, timezone

import jwt
import psycopg
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, PlainTextResponse, Response
from psycopg.rows import dict_row
from pydantic import BaseModel

DB          = os.environ["DATABASE_URL"]
JWT_SECRET  = os.environ["JWT_SECRET"]
GIT_BASE    = os.environ.get("GIT_BASE", "ssh://git@localhost:2222")
DEF_MODEL   = os.environ.get("DEFAULT_MODEL", "gpt-5.5")
LEASE_HOURS = int(os.environ.get("LEASE_HOURS", "4"))

_SIGNING_KEY = Ed25519PrivateKey.from_private_bytes(
    base64.b64decode(os.environ["WO_SIGNING_KEY_B64"])
)

app = FastAPI(title="AgenticDev Control Plane", version="0.1.0")


# ═══════════════════════════════════════════════════════════════
#  Co smí projít zvenčí
# ═══════════════════════════════════════════════════════════════
# Instalátor publikuje přes Tailscale Funnel jedinou cestu — /join.
# Tohle je druhý zámek na stejných dveřích: kdyby někdo Funnel omylem
# namířil na celý control plane (nebo změnil mount point), veřejně se
# stejně nedostane nikam jinam než k registraci.
#
# Tailscaled značí požadavky z Funnelu hlavičkou Tailscale-Funnel-Request.
# Testujeme jen JEJÍ PŘÍTOMNOST, ne hodnotu: útočník si ji může přidat
# sám, čímž se pro sebe omezí ještě víc, ale odebrat cizí hlavičku,
# kterou přilepí tailscaled, nedokáže.
_PUBLIC_PREFIXES = ("/join",)


def _via_funnel(scope_headers: list[tuple[bytes, bytes]]) -> bool:
    return any(k.lower() == b"tailscale-funnel-request" for k, _ in scope_headers)


@app.middleware("http")
async def _funnel_gate(request, call_next):
    if _via_funnel(request.scope.get("headers") or []):
        path = request.url.path
        if not any(path == p or path.startswith(p + "/") for p in _PUBLIC_PREFIXES):
            return Response(status_code=404)
    return await call_next(request)


def db():
    return psycopg.connect(DB, row_factory=dict_row, autocommit=True)


def now() -> datetime:
    return datetime.now(timezone.utc)


# ═══════════════════════════════════════════════════════════════
#  Auth
# ═══════════════════════════════════════════════════════════════
class DeviceAuth(BaseModel):
    hostname: str
    device_key_fp: str


def current_ws(authorization: str = Header(...)) -> dict:
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "chybí Bearer token")
    try:
        claims = jwt.decode(authorization[7:], JWT_SECRET, algorithms=["HS256"])
    except jwt.PyJWTError as e:
        raise HTTPException(401, f"neplatný token: {e}")
    with db() as c:
        ws = c.execute(
            "SELECT * FROM workstation WHERE id = %s AND revoked_at IS NULL",
            (claims["ws"],),
        ).fetchone()
    if not ws:
        raise HTTPException(403, "stanice revokována")
    return ws


@app.post("/v1/auth/device")
def auth_device(body: DeviceAuth):
    """Stanice se prokáže fingerprintem svého device key."""
    with db() as c:
        ws = c.execute(
            "SELECT * FROM workstation WHERE device_key_fp = %s",
            (body.device_key_fp,),
        ).fetchone()
        if not ws:
            raise HTTPException(
                403,
                "neznámý device key — zaregistruj stanici přes `agenticdev admin register-ws`",
            )
        if ws["revoked_at"]:
            raise HTTPException(403, "stanice revokována")
        c.execute("UPDATE workstation SET last_seen_at = now() WHERE id = %s", (ws["id"],))
    token = jwt.encode(
        {"ws": str(ws["id"]), "exp": now() + timedelta(hours=LEASE_HOURS)},
        JWT_SECRET, algorithm="HS256",
    )
    return {"token": token, "expires_in": LEASE_HOURS * 3600, "channel": ws["channel"]}


# ═══════════════════════════════════════════════════════════════
#  Work order
# ═══════════════════════════════════════════════════════════════
def _pick_director(c, project: dict, phase_kind: str, task_kind: str, channel: str) -> dict | None:
    """
    Výběr podle projekt × fáze × druh úkolu. Override projektu vyhrává.

    Vrací None, když žádný záznam nesedí. Dřív to bylo 409, ale postup úkolu
    dneska vynucuje harness a `director_version` je jen přišpendlení verzí
    (ADR-0003) — chybějící řádek pro `bugfix-director` tedy nesmí zabránit
    vydání work orderu.
    """
    override = (project.get("director_overrides") or {}).get(f"{phase_kind}.{task_kind}")
    director_id = override or f"{task_kind}-director"
    row = c.execute(
        """SELECT * FROM director_version
           WHERE director_id = %s
             AND channel = ANY(%s)
           ORDER BY CASE channel WHEN 'canary' THEN 1 WHEN 'beta' THEN 2 ELSE 3 END
           LIMIT 1""",
        (director_id, _visible_channels(channel)),
    ).fetchone()
    if row:
        return row
    # Kterýkoli nasazený, ať se práce nezastaví na chybějícím číselníku.
    return c.execute(
        """SELECT * FROM director_version WHERE channel = ANY(%s)
           ORDER BY released_at DESC LIMIT 1""",
        (_visible_channels(channel),)).fetchone()


def _visible_channels(ws_channel: str) -> list[str]:
    return {"canary": ["canary", "beta", "stable"],
            "beta":   ["beta", "stable"],
            "stable": ["stable"]}[ws_channel]


def _build_context_bundle(c, project: dict, task: dict) -> dict:
    """
    F1: manifest odkazuje na soubory v gitu; harness si je vytáhne z repa.
    F5: nahradit materializací do MinIO s presigned URL.
    """
    items = [
        {"path": f"prd/{project['code']}/00-context.md"},
        {"path": f"prd/{project['code']}/50-glossary.md"},
    ]
    if task.get("spec_ref"):
        items.append({"path": task["spec_ref"].split("#")[0]})
    spec = {"items": items, "budget_tokens": 120_000}
    h = hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()
    c.execute(
        """INSERT INTO context_bundle (manifest_hash, spec, size_tokens)
           VALUES (%s, %s, 0) ON CONFLICT (manifest_hash) DO NOTHING""",
        (h, json.dumps(spec)),
    )
    return {"manifest_hash": f"sha256:{h}", **spec}


@app.get("/v1/work-orders/next")
def next_work_order(ws: dict = Depends(current_ws)):
    with db() as c:
        state = c.execute("SELECT * FROM platform_state WHERE id = 1").fetchone()
        if not state["issuing_enabled"]:
            raise HTTPException(503, f"kill switch aktivní: {state['reason']}")

        # atomický výběr úkolu — SKIP LOCKED brání souběžnému přidělení
        task = c.execute(
            """SELECT t.*, p.kind AS phase_kind, pr.* , t.id AS task_id, pr.id AS project_id
               FROM task t
               JOIN phase p   ON p.id = t.phase_id
               JOIN project pr ON pr.id = p.project_id
               WHERE t.state = 'ready' AND pr.active AND p.active
               ORDER BY t.priority, t.created_at
               FOR UPDATE OF t SKIP LOCKED LIMIT 1"""
        ).fetchone()
        if not task:
            return {"work_order": None, "reason": "žádný úkol ve stavu ready"}

        director = _pick_director(c, task, task["phase_kind"], task["kind"], ws["channel"])
        harness  = c.execute(
            "SELECT * FROM harness_version ORDER BY released_at DESC LIMIT 1"
        ).fetchone()

        expires = now() + timedelta(hours=LEASE_HOURS)
        assignment = c.execute(
            """INSERT INTO assignment (task_id, workstation_id, lease_expires_at)
               VALUES (%s, %s, %s) RETURNING *""",
            (task["task_id"], ws["id"], expires),
        ).fetchone()
        c.execute("UPDATE task SET state = 'assigned' WHERE id = %s", (task["task_id"],))

        bundle = _build_context_bundle(c, task, task)
        models = task["model_allowlist"] or [DEF_MODEL]

        manifest = {
            "work_order_id": str(uuid.uuid4()),
            "issued_at": now().isoformat(),
            "expires_at": expires.isoformat(),
            "task": {
                "id": str(task["task_id"]),
                "project": task["code"],
                "phase": task["phase_kind"],
                "kind": task["kind"],
                "risk_class": task["risk"],
                "title": task["title"],
                "spec_ref": task["spec_ref"],
                "dod": task["dod"],
            },
            "repo": {
                "url": task["repo_url"],
                "base_ref": "main",
                "work_branch": f"task/{str(task['task_id'])[:8]}/wip",
                "write_scope": task["write_scope"],
            },
            "context_bundle": bundle,
            "runtime": {
                "compose": {"ref": f"pods/{task['code']}/compose.yaml@main"},
                "harness": ({"image": harness["image_digest"],
                             "api_version": harness["semver"]} if harness else None),
                "director": ({
                    "id": director["director_id"],
                    "version": director["semver"],
                    "channel": director["channel"],
                    "uri": director["uri"],
                    "sha256": director["sha256"],
                    "requires_harness": director["requires_harness"],
                } if director else None),
            },
            "worker_pool": [
                {"role": r, "profile": f"{r}@0.1.0"}
                for r in ("architect", "implementer", "tester", "reviewer")
            ],
            "policy": {
                "model_allowlist": models,
                "egress_allowlist": os.environ.get(
                    "EGRESS_ALLOWLIST",
                    "api.openai.com,registry.npmjs.org,pypi.org").split(","),
                "human_gate": ["schema_migration", "dependency_add", "prod_deploy"],
                "max_wall_clock_min": 240,
                "budget_czk_total": float(task["budget_czk"]),
                "max_loop_iterations": {"implement_test": 5, "review_rework": 3},
            },
            "telemetry": {"endpoint": "/v1/events"},
        }

        payload = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
        manifest["signature"] = "ed25519:" + base64.b64encode(
            _SIGNING_KEY.sign(payload)
        ).decode()

        c.execute(
            """INSERT INTO work_order
                 (id, assignment_id, manifest, manifest_hash, director_ver, harness_ver, expires_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s)""",
            (manifest["work_order_id"], assignment["id"], json.dumps(manifest),
             hashlib.sha256(payload).hexdigest(),
             director["id"] if director else None,
             harness["id"] if harness else None, expires),
        )
        _emit(c, ws["principal_id"], "task", str(task["task_id"]), "assigned",
              {"work_order": manifest["work_order_id"]}, manifest["work_order_id"])

    return {"work_order": manifest}


@app.post("/v1/work-orders/{wo_id}/heartbeat")
def heartbeat(wo_id: str, ws: dict = Depends(current_ws)):
    with db() as c:
        r = c.execute(
            """UPDATE assignment SET heartbeat_at = now()
               WHERE id = (SELECT assignment_id FROM work_order WHERE id = %s)
                 AND state = 'active' AND lease_expires_at > now()
               RETURNING lease_expires_at""",
            (wo_id,),
        ).fetchone()
    if not r:
        raise HTTPException(409, "lease vypršel nebo byl revokován — zastav directora")
    return {"lease_expires_at": r["lease_expires_at"]}


@app.post("/v1/work-orders/{wo_id}/release")
def release(wo_id: str, outcome: str = "done", ws: dict = Depends(current_ws)):
    final = {"done": "review", "aborted": "aborted", "blocked": "blocked"}.get(outcome, "review")
    with db() as c:
        a = c.execute(
            """UPDATE assignment SET state = 'released'
               WHERE id = (SELECT assignment_id FROM work_order WHERE id = %s)
               RETURNING task_id""", (wo_id,),
        ).fetchone()
        if a:
            c.execute("UPDATE task SET state = %s WHERE id = %s", (final, a["task_id"]))
            _emit(c, ws["principal_id"], "task", str(a["task_id"]), "released",
                  {"outcome": outcome}, wo_id)
    return {"ok": True, "task_state": final}


# ═══════════════════════════════════════════════════════════════
#  Write-back
# ═══════════════════════════════════════════════════════════════
def _emit(c, actor, subject_type, subject_id, verb, payload, dedupe):
    c.execute(
        """INSERT INTO event (actor_id, subject_type, subject_id, verb, payload, dedupe_key)
           VALUES (%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING""",
        (actor, subject_type, subject_id, verb, json.dumps(payload), dedupe),
    )


class Event(BaseModel):
    subject_type: str
    subject_id: str
    verb: str
    payload: dict = {}
    dedupe_key: str


@app.post("/v1/events")
def post_event(e: Event, ws: dict = Depends(current_ws)):
    """Idempotentní. Stejný dedupe_key = žádný duplikát (invariant P6)."""
    with db() as c:
        _emit(c, ws["principal_id"], e.subject_type, e.subject_id, e.verb,
              e.payload, e.dedupe_key)
    return {"ok": True}


class Run(BaseModel):
    task_id: str
    work_order_id: str | None = None
    role: str
    state_name: str | None = None
    model: str
    tokens_in: int = 0
    tokens_out: int = 0
    cost_czk: float = 0
    duration_ms: int | None = None
    outcome: str | None = None
    transcript_uri: str | None = None


@app.post("/v1/runs")
def post_run(r: Run, ws: dict = Depends(current_ws)):
    with db() as c:
        row = c.execute(
            """INSERT INTO agent_run
                 (task_id, work_order_id, role, state_name, model,
                  tokens_in, tokens_out, cost_czk, duration_ms, outcome, transcript_uri)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
            (r.task_id, r.work_order_id, r.role, r.state_name, r.model,
             r.tokens_in, r.tokens_out, r.cost_czk, r.duration_ms, r.outcome, r.transcript_uri),
        ).fetchone()
        spent = c.execute(
            "SELECT COALESCE(SUM(cost_czk),0) AS s FROM agent_run WHERE task_id = %s",
            (r.task_id,),
        ).fetchone()["s"]
        budget = c.execute(
            "SELECT budget_czk FROM task WHERE id = %s", (r.task_id,)
        ).fetchone()["budget_czk"]
    return {"run_id": row["id"], "spent_czk": float(spent),
            "budget_czk": float(budget), "over_budget": spent > budget}


# ═══════════════════════════════════════════════════════════════
#  Rozhodovací matice
# ═══════════════════════════════════════════════════════════════
class DecisionIn(BaseModel):
    task_id: str
    question: str
    options: list = []
    criteria: dict = {}
    recommended: str | None = None


@app.post("/v1/decisions")
def create_decision(d: DecisionIn, ws: dict = Depends(current_ws)):
    with db() as c:
        row = c.execute(
            """INSERT INTO decision (task_id, question, options, criteria, recommended)
               VALUES (%s,%s,%s,%s,%s) RETURNING id""",
            (d.task_id, d.question, json.dumps(d.options),
             json.dumps(d.criteria), d.recommended),
        ).fetchone()
        c.execute("UPDATE task SET state = 'blocked' WHERE id = %s", (d.task_id,))
        _emit(c, ws["principal_id"], "task", d.task_id, "blocked_on_decision",
              {"decision": str(row["id"])}, str(row["id"]))
    # TODO(F4): notifikace přes ntfy
    return {"decision_id": row["id"], "state": "pending_human"}


@app.get("/v1/decisions/{did}")
def get_decision(did: str, ws: dict = Depends(current_ws)):
    with db() as c:
        row = c.execute("SELECT * FROM decision WHERE id = %s", (did,)).fetchone()
    if not row:
        raise HTTPException(404, "rozhodnutí neexistuje")
    return row


@app.get("/v1/decisions")
def list_pending(ws: dict = Depends(current_ws)):
    with db() as c:
        return c.execute(
            """SELECT d.*, t.title FROM decision d JOIN task t ON t.id = d.task_id
               WHERE d.state = 'pending_human' ORDER BY d.created_at"""
        ).fetchall()


# ═══════════════════════════════════════════════════════════════
@app.get("/v1/health")
def health():
    with db() as c:
        c.execute("SELECT 1")
    return {"ok": True, "version": app.version, "ts": now().isoformat()}


@app.get("/v1/identity")
def identity():
    """
    Veřejná identita TÉTO instance. Instalátor Macu si podle fingerprintu
    ověří, že mluví s tím VPS, ke kterému byl vygenerován — a ne s jiným.
    Obsahuje jen veřejné údaje (náhodné ID + veřejný klíč).
    """
    iid = os.environ.get("AGENTICDEV_INSTANCE_ID", "")
    vk = os.environ.get("WO_VERIFY_KEY_B64", "")
    fp = hashlib.sha256(f"{iid}\n{vk}".encode()).hexdigest()
    return {
        "instance_id": iid,
        "domain": os.environ.get("AGENTICDEV_DOMAIN", ""),
        "verify_key": vk,
        "fingerprint": f"sha256:{fp}",
        "api": app.version,
    }


# ═══════════════════════════════════════════════════════════════
#  Nástěnka a instalační skripty
# ═══════════════════════════════════════════════════════════════
from pathlib import Path as _P                                  # noqa: E402
from .admin import router as _admin_router                       # noqa: E402
from .workspace import router as _ws_router                       # noqa: E402
from .enroll import router as _enroll_router                      # noqa: E402
from .hooks import router as _hooks_router                        # noqa: E402

app.include_router(_admin_router)
app.include_router(_ws_router)
app.include_router(_enroll_router)
app.include_router(_hooks_router)


@app.on_event("startup")
def _startup():
    # Migrace jdou tudy: init skripty Postgresu běží jen nad prázdnou
    # databází, u existující instalace by se nespustily.
    from . import migrate as _mig
    try:
        _mig.run()
    except Exception as e:                       # noqa: BLE001
        print(f"[migrace] neproběhly: {e}")

_HERE = _P(__file__).parent
_REPO = _P("/repo")


@app.get("/", include_in_schema=False)
def dashboard():
    return FileResponse(_HERE / "dashboard.html")


@app.get("/install-mac.sh", include_in_schema=False)
def install_mac():
    """Doplní adresu control plane, ať člověk nemusí nic upravovat."""
    f = _REPO / "install-mac.sh"
    if not f.exists():
        raise HTTPException(404, "install-mac.sh není nasazený")
    dom = os.environ.get("AGENTICDEV_DOMAIN", "")
    url = os.environ.get("CONTROL_PLANE_URL") or (
        f"https://{dom}" if dom else "http://localhost:8080")
    return PlainTextResponse(f.read_text().replace("__CONTROL_PLANE__", url),
                             media_type="text/x-shellscript")


@app.get("/install-linux.sh", include_in_schema=False)
def install_linux():
    return _serve_installer("install-linux.sh", "text/x-shellscript")


@app.get("/install-windows.ps1", include_in_schema=False)
def install_windows():
    return _serve_installer("install-windows.ps1", "text/plain")


def _serve_installer(name: str, mime: str):
    f = _REPO / name
    if not f.exists():
        raise HTTPException(404, f"{name} není nasazený")
    dom = os.environ.get("AGENTICDEV_DOMAIN", "")
    url = os.environ.get("CONTROL_PLANE_URL") or (
        f"https://{dom}" if dom else "http://localhost:8080")
    return PlainTextResponse(f.read_text().replace("__CONTROL_PLANE__", url),
                             media_type=mime)


_POD_FILES = {
    "compose.yaml":         "text/yaml",
    "Dockerfile":           "text/plain",
    "egress/Dockerfile":    "text/plain",
    "egress/entrypoint.sh": "text/x-shellscript",
    "harness/harness.py":   "text/x-python",
    "harness/director.py":  "text/x-python",
}


@app.get("/pod/{path:path}", include_in_schema=False)
def pod_file(path: str):
    """Definice sandboxu. Launcher si ji stáhne při prvním spuštění."""
    if path not in _POD_FILES:
        raise HTTPException(404)
    f = _REPO / "pod" / path
    if not f.is_file():
        raise HTTPException(404, f"pod/{path} není nasazený")
    return PlainTextResponse(f.read_text(), media_type=_POD_FILES[path])


@app.get("/linux/agenticdev-launch", include_in_schema=False)
def linux_launch():
    f = _REPO / "linux" / "agenticdev-launch"
    if not f.exists():
        raise HTTPException(404)
    return PlainTextResponse(f.read_text(), media_type="text/x-shellscript")


@app.get("/ghostty-config", include_in_schema=False)
def ghostty_config():
    f = _REPO / "mac" / "ghostty" / "config"
    if not f.exists():
        raise HTTPException(404, "config není nasazený")
    return PlainTextResponse(f.read_text(), media_type="text/plain")


@app.get("/agenticdev-app.tar.gz", include_in_schema=False)
def agenticdev_app():
    """AgenticDev.app zabalená za běhu — instalátor ji rozbalí do /Applications."""
    import io, tarfile
    src = _REPO / "mac" / "AgenticDev.app"
    if not src.exists():
        raise HTTPException(404, "AgenticDev.app není nasazená")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        t.add(src, arcname="AgenticDev.app")
    return Response(content=buf.getvalue(), media_type="application/gzip")


@app.get("/agenticdev", include_in_schema=False)
def launcher():
    f = _REPO / "launcher" / "agenticdev"
    if not f.exists():
        raise HTTPException(404, "launcher není nasazený")
    return PlainTextResponse(f.read_text(), media_type="text/x-shellscript")


# ═══════════════════════════════════════════════════════════════
#  Značka
# ═══════════════════════════════════════════════════════════════
_BRAND_TYPES = {
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".gz":  "application/gzip",
}


@app.get("/brand/{name}", include_in_schema=False)
def brand(name: str):
    """
    logo.svg (wordmark) · mark.svg (značka) · icon.svg (dlaždice)
    agenticdev.ico (Windows) · png/icon-<velikost>.png
    """
    # Bez tohohle by šlo přes ../ číst cokoli z /repo.
    p = (_REPO / "brand" / name).resolve()
    root = (_REPO / "brand").resolve()
    if root not in p.parents or not p.is_file():
        raise HTTPException(404)
    return FileResponse(p, media_type=_BRAND_TYPES.get(p.suffix, "application/octet-stream"))


@app.get("/logo.svg", include_in_schema=False)
def logo():
    f = _REPO / "brand" / "logo.svg"
    if not f.exists():
        raise HTTPException(404)
    return FileResponse(f, media_type="image/svg+xml")


@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    f = _REPO / "brand" / "agenticdev.ico"
    if not f.exists():
        raise HTTPException(404)
    return FileResponse(f, media_type="image/x-icon")
