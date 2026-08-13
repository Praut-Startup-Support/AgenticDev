"""
Workspace API — servíruje konfiguraci Pi na stanice.

Tohle je ta modrá vrstva z náčrtu: „serving directors".
VPS neposílá běžícího agenta. Posílá NASTAVENÍ Pi pro daný projekt a fázi.

Co se doopravdy servíruje (a nic víc — dřív tu stál seznam, který
obsahoval subagenty, hooky a MCP servery, jenže ty v žádné vrstvě nejsou):

    AGENTS.md            instrukce, řetězí se přes vrstvy
    .pi/settings.json    nastavení Pi, slévá se přes vrstvy
    .pi/skills/          skills
    .pi/prompts/         slash příkazy
    bin/                 agenticdev-git, agenticdev-decision
    .agenticdev/         fáze, scope, projekt, úkoly ve stavu ready

Oprávnění agenta tady nejsou úmyslně: co smí zapsat, drží mount v podu
(scope se remountuje rw, zbytek je ro), a kam smí ven, drží egress proxy.
Kdyby to bylo v nastavení, byla by to prosba, ne hranice.

Vrstvení (pozdější přepisuje dřívější):
    workspace/_base/            společné pro všechny
    workspace/_phase/<fáze>/    scope a instrukce podle fáze
    workspace/<projekt>/        specifika projektu
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException

from .main import current_ws, db

from . import settings as _cfg

router = APIRouter()

WS_ROOT = Path(os.environ.get("WORKSPACE_ROOT", "/workspace-templates"))
CP_URL = os.environ.get("CONTROL_PLANE_URL", "")


# ═══════════════════════════════════════════════════════════════
#  Skládání vrstev
# ═══════════════════════════════════════════════════════════════
def _collect(base: Path, out: dict[str, str]) -> None:
    """Nasype soubory z adresáře do mapy cesta → obsah."""
    if not base.is_dir():
        return
    for f in sorted(base.rglob("*")):
        if not f.is_file() or "/.git/" in str(f):
            continue
        try:
            out[str(f.relative_to(base))] = f.read_text()
        except UnicodeDecodeError:
            continue


def _merge_settings(layers: list[str]) -> str:
    """
    settings.json se nepřepisuje, ale slévá — jinak by fázová
    vrstva zahodila základní oprávnění a hooky.
    """
    merged: dict = {}
    for raw in layers:
        try:
            cur = json.loads(raw)
        except json.JSONDecodeError:
            continue
        for key, val in cur.items():
            if isinstance(val, dict):
                merged.setdefault(key, {}).update(val)   # compaction, retry…
            elif isinstance(val, list):
                merged[key] = sorted(set(merged.get(key, [])) | set(val))
            else:
                merged[key] = val
    return json.dumps(merged, indent=2, ensure_ascii=False)


def _render(text: str, vars: dict[str, str]) -> str:
    for k, v in vars.items():
        text = text.replace("{{" + k + "}}", str(v))
    return text


# ═══════════════════════════════════════════════════════════════
#  Endpointy
# ═══════════════════════════════════════════════════════════════
@router.get("/v1/workspace/projects")
def list_for_workstation(ws: dict = Depends(current_ws)):
    """Co si můžu vybrat, když dvojkliknu na ikonu."""
    with db() as c:
        rows = c.execute(
            """SELECT p.code, p.data_class, p.repo_url,
                      cl.name AS client_name,
                      (SELECT kind FROM phase WHERE project_id = p.id AND active LIMIT 1) AS phase,
                      (SELECT count(*) FROM task t JOIN phase ph ON ph.id = t.phase_id
                        WHERE ph.project_id = p.id AND t.state = 'ready') AS ready_tasks
               FROM project p
               LEFT JOIN client cl ON cl.id = p.client_id
               WHERE p.active
               ORDER BY p.code"""
        ).fetchall()
    return {"projects": rows}


@router.get("/v1/workspace/{code}/bundle")
def bundle(code: str, phase: str | None = None, ws: dict = Depends(current_ws)):
    """
    Kompletní nastavení Pi pro projekt v jeho aktivní fázi.
    Launcher tohle rozbalí do pracovního adresáře a spustí `pi`.
    """
    with db() as c:
        proj = c.execute(
            """SELECT p.*, cl.name AS client_name,
                      (SELECT kind FROM phase WHERE project_id = p.id AND active LIMIT 1) AS phase
               FROM project p LEFT JOIN client cl ON cl.id = p.client_id
               WHERE p.code = %s AND p.active""", (code,)).fetchone()
        if not proj:
            raise HTTPException(404, f"projekt '{code}' neexistuje nebo není aktivní")

        tasks = c.execute(
            """SELECT t.id, t.title, t.kind, t.dod, t.risk, t.spec_ref
               FROM task t JOIN phase ph ON ph.id = t.phase_id
               WHERE ph.project_id = %s AND t.state = 'ready'
               ORDER BY t.priority, t.created_at LIMIT 20""", (proj["id"],)).fetchall()

        # Kdo commituje. V podu není žádný ~/.gitconfig, takže bez tohohle
        # spadne agentovi každý commit na "Author identity unknown" — a
        # `agenticdev-git` commituje u každého checkpointu.
        who = c.execute(
            "SELECT display_name, email FROM principal WHERE id = %s",
            (ws["principal_id"],)).fetchone() or {}

        c.execute(
            """INSERT INTO event (actor_id, subject_type, subject_id, verb, payload, dedupe_key)
               VALUES (%s,'project',%s,'workspace_served',%s,%s)
               ON CONFLICT DO NOTHING""",
            (ws["principal_id"], str(proj["id"]),
             json.dumps({"phase": proj["phase"], "host": ws["hostname"]}),
             f"{ws['id']}:{code}:{proj['phase']}"))

    # ?phase= přepíše fázi jen pro tuhle stanici, projektu se to nedotkne
    phase = phase or proj["phase"] or "implementation"
    if not (WS_ROOT / "_phase" / phase).is_dir():
        raise HTTPException(400, f"neznámá fáze '{phase}'")

    # ── vrstvení ──
    files: dict[str, str] = {}
    settings_layers: list[str] = []
    agents_parts: list[str] = []
    scope: list[str] = []

    for layer in (WS_ROOT / "_base", WS_ROOT / "_phase" / phase, WS_ROOT / code):
        part: dict[str, str] = {}
        _collect(layer, part)

        # AGENTS.md se řetězí, ne přepisuje — fáze a projekt jen doplňují
        if "AGENTS.md" in part:
            agents_parts.append(part.pop("AGENTS.md"))
        if ".pi/settings.json" in part:
            settings_layers.append(part.pop(".pi/settings.json"))
        if "scope" in part:
            scope = [l for l in part.pop("scope").splitlines() if l.strip()]
        files.update(part)

    vars = {
        "PROJECT_CODE": proj["code"],
        "CLIENT_NAME": proj["client_name"] or "",
        "PHASE": phase,
        "DATA_CLASS": proj["data_class"],
        "SCOPE": ", ".join(scope),
    }
    files = {p: _render(t, vars) for p, t in files.items()}

    if agents_parts:
        files["AGENTS.md"] = _render("\n".join(agents_parts), vars)
    if settings_layers:
        files[".pi/settings.json"] = _merge_settings(settings_layers)

    # ── model se přišpendlí všem, ne jen u restricted ──
    # Přihlášení k modelu je na člověka (ADR-0007), a kdyby si každý bral
    # to, co má ve svém předplatném, dostali by dva lidé na stejné zadání
    # jinou odpověď a nešlo by to srovnat. Sdílené je tedy i JMÉNO modelu;
    # osobní zůstává jen to, kdo ho platí.
    #
    # Když ho něčí předplatné neumí, Pi to řekne a nepustí ho dál. To je
    # záměr: tichá záměna modelu za jiný je přesně ten druh degradace,
    # kterou zakazuje P5.
    allow = proj["model_allowlist"] or (
        ["ollama/*"] if proj["data_class"] == "restricted" else [])
    if allow:
        cur = json.loads(files.get(".pi/settings.json", "{}"))
        cur["enabledModels"] = allow
        files[".pi/settings.json"] = json.dumps(cur, indent=2, ensure_ascii=False)

    # ── stav z ledgeru do pracovního adresáře ──
    files[".agenticdev/phase"] = phase
    files[".agenticdev/scope"] = "\n".join(scope) + "\n"
    files[".agenticdev/project"] = code
    if tasks:
        files[".agenticdev/tasks.md"] = "# Úkoly ve stavu ready\n\n" + "\n\n".join(
            f"## {t['title']}\n"
            f"- id: `{t['id']}`\n- druh: {t['kind']} | riziko: {t['risk']}\n"
            + (f"- spec: `{t['spec_ref']}`\n" if t["spec_ref"] else "")
            + "- Definition of Done:\n"
            + "\n".join(f"  - [ ] {d}" for d in (t["dod"] or []))
            for t in tasks)

    return {
        "project": {
            "code": proj["code"],
            "client": proj["client_name"],
            "repo_url": proj["repo_url"],
            "phase": phase,
            "data_class": proj["data_class"],
            "model_allowlist": proj["model_allowlist"],
        },
        "scope": scope,
        "ready_tasks": len(tasks),
        "files": files,
        # Podpis commitů. Launcher to předá podu proměnnými, ne
        # .gitconfigem — v podu není domovský adresář, na který se dá
        # spolehnout.
        "author": {
            "name": who.get("display_name") or "AgenticDev agent",
            "email": who.get("email") or "agent@agenticdev.local",
        },
        # Pro sandbox: co pod smí ven a kolik tokenů smí spotřebovat.
        # Control plane sem patří vždycky, doplní si ho launcher.
        "egress_allowlist": [
            d.strip() for d in _cfg.get("EGRESS_ALLOWLIST", "").split(",") if d.strip()
        ],
        "budget_tokens": _cfg.get_int("MODEL_MAX_TOKENS", 0) or None,
        "lease_hours": _cfg.get_int("LEASE_HOURS", 4),
    }


# ═══════════════════════════════════════════════════════════════
#  Zápis rozhodnutí ze slash příkazu /rozhodnuti
# ═══════════════════════════════════════════════════════════════
@router.post("/v1/workspace/{code}/decision")
def record_decision(code: str, body: dict, ws: dict = Depends(current_ws)):
    with db() as c:
        t = c.execute(
            """SELECT t.id FROM task t JOIN phase ph ON ph.id = t.phase_id
               JOIN project p ON p.id = ph.project_id
               WHERE p.code = %s ORDER BY t.created_at DESC LIMIT 1""", (code,)).fetchone()
        if not t:
            raise HTTPException(400, "projekt nemá žádný úkol, ke kterému rozhodnutí přiřadit")
        row = c.execute(
            """INSERT INTO decision (task_id, question, chosen, rationale, state,
                                     adr_ref, decided_at, decided_by)
               VALUES (%s,%s,%s,%s,'approved',%s, now(), %s) RETURNING id""",
            (t["id"], body.get("question", ""), body.get("chosen", ""),
             body.get("rationale", ""), body.get("adr_ref"), ws["principal_id"])).fetchone()
    return {"decision_id": row["id"]}
