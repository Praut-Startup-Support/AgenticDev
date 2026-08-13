"""
Admin API — všechno, co obsluhuje nástěnka.
Zakládání projektů, úkolů, registrace stanic, schvalování rozhodnutí.
"""
from __future__ import annotations

import fnmatch, json, os, re, secrets, time
from datetime import datetime, timedelta, timezone

import httpx
import jwt
from fastapi import APIRouter, Cookie, Depends, HTTPException, Request, Response
from pydantic import BaseModel

from .main import DEF_MODEL, JWT_SECRET, _emit, db, now
from . import ratelimit
from . import settings as cfg

router = APIRouter()

JOIN_TOKEN      = os.environ.get("JOIN_TOKEN", "")
DASHBOARD_TOKEN = os.environ.get("DASHBOARD_TOKEN", "")
FORGEJO_URL     = os.environ.get("FORGEJO_URL", "http://forgejo:3000")
FORGEJO_TOKEN   = os.environ.get("FORGEJO_TOKEN", "")
GIT_SSH         = os.environ.get("GIT_SSH_BASE", "ssh://git@vps:2222")
HARNESS_IMAGE   = os.environ.get("HARNESS_IMAGE", "agenticdev/harness:dev")

PHASES = ["discovery", "design", "implementation", "hardening", "delivery", "support"]


# ═══════════════════════════════════════════════════════════════
#  Přihlášení do nástěnky (jen tailnet + sdílené heslo)
# ═══════════════════════════════════════════════════════════════
class Login(BaseModel):
    token: str


# Panel stojí na jednom sdíleném heslu, takže potřebuje stejnou ochranu
# jako registrace. Tailnet není důvod ji vynechat — stačí jeden napadený
# stroj v síti a heslo se dá zkoušet, jak dlouho kdo chce.
_login_limiter = ratelimit.Limiter(window=900, per_ip=10, global_cap=100, lockout=1800)


@router.post("/v1/auth/dashboard")
def dashboard_login(body: Login, request: Request, response: Response):
    ip = ratelimit.client_ip(request)
    _login_limiter.check(ip)

    # Přes nastavení, ať změna hesla platí hned a ne až po restartu.
    pw = cfg.get("DASHBOARD_TOKEN", DASHBOARD_TOKEN)
    if not pw or not secrets.compare_digest(body.token, pw):
        _login_limiter.record(ip)
        time.sleep(0.5)
        raise HTTPException(401, "špatné heslo")

    _login_limiter.clear(ip)

    # Identita admina do relace, ať má auditní stopa u panelových zápisů
    # koho uvést. Selhání nesmí zablokovat přihlášení — bez identity se
    # zapíše None, jako se to dělo vždycky.
    pid = None
    try:
        with db() as c:
            pid = admin_principal(c)
    except Exception:                                   # noqa: BLE001
        pass

    tok = jwt.encode(
        {"role": "operator", "principal_id": pid,
         "exp": now() + timedelta(days=30)},
        JWT_SECRET, algorithm="HS256")
    # Secure podle toho, jak PŘIŠEL TENHLE požadavek, ne podle nastavení
    # instance: k panelu se chodí přes doménu (https) i napřímo po
    # tailnetu (http://<ip>:8080). Kdyby se to řídilo konfigurací, jeden
    # z těch dvou způsobů by cookie neuložil a přihlášení by tiše selhalo.
    https = (request.headers.get("x-forwarded-proto", "").split(",")[0].strip()
             or request.url.scheme) == "https"
    response.set_cookie("agenticdev_session", tok, httponly=True,
                        samesite="lax", max_age=30 * 24 * 3600, secure=https)
    return {"ok": True}


def operator(agenticdev_session: str | None = Cookie(default=None)) -> dict:
    if not agenticdev_session:
        raise HTTPException(401, "nepřihlášeno")
    try:
        return jwt.decode(agenticdev_session, JWT_SECRET, algorithms=["HS256"])
    except jwt.PyJWTError:
        raise HTTPException(401, "relace vypršela")


def who(op: dict) -> str | None:
    """
    Kdo tenhle zápis udělal. Dřív se do auditní stopy dávalo `None`, takže
    u rozhodnutí odklikaného v panelu nebylo vidět, kdo ho odklikl —
    „operátor" nebyl nikdo. Admin je teď `principal` a jeho id nese relace.

    Vrací None jen u instancí, které vznikly před tou změnou a admina
    zaregistrovaného nemají; pak je to poctivější než si někoho vymyslet.
    """
    return op.get("principal_id")


def admin_principal(c) -> str | None:
    """
    Najde (nebo založí) `principal` admina podle ADMIN_NAME z prostředí.

    Zakládá se to při přihlášení, ne při startu: kdyby na tom visel start
    kontejneru, jedna chyba v databázi by shodila celou platformu kvůli
    jednomu řádku.
    """
    name = (os.environ.get("ADMIN_NAME") or "").strip()
    if not name:
        return None
    mail = (os.environ.get("ADMIN_EMAIL") or "").strip() or None
    row = c.execute(
        "SELECT id FROM principal WHERE kind = 'human' AND display_name = %s",
        (name,)).fetchone()
    if row:
        return str(row["id"])
    row = c.execute(
        """INSERT INTO principal (kind, display_name, email)
           VALUES ('human', %s, %s) RETURNING id""", (name, mail)).fetchone()
    return str(row["id"])


# ═══════════════════════════════════════════════════════════════
#  Registrace pracovní stanice (nahrazuje ruční SQL)
# ═══════════════════════════════════════════════════════════════
class Register(BaseModel):
    join_token: str
    hostname: str
    device_key_fp: str
    display_name: str
    email: str | None = None
    ssh_public_key: str | None = None      # bez něj nefunguje git clone
    # V režimu domain (bez Tailscale) je tenhle klíč i tím, čím se člověk
    # přihlásí na VPS — tailnet za něj autentizaci nedělá. Uschová se a
    # `agenticdev-ctl keys sync` ho zapíše do authorized_keys.
    login: str | None = None


@router.post("/v1/workstations/register")
def register_ws(b: Register):
    if not JOIN_TOKEN or not secrets.compare_digest(b.join_token, JOIN_TOKEN):
        raise HTTPException(403, "neplatný join token")
    with db() as c:
        p = c.execute("SELECT * FROM principal WHERE display_name = %s", (b.display_name,)).fetchone()
        if not p:
            p = c.execute(
                """INSERT INTO principal (kind, display_name, email)
                   VALUES ('human', %s, %s) RETURNING *""",
                (b.display_name, b.email)).fetchone()
        # Na workstation jsou dva unikátní klíče, takže se dá narazit dvěma
        # způsoby, a ON CONFLICT umí cílit jen na jeden. Hostname je ten
        # druhý a musí se řešit ručně, jinak přeinstalovaný stroj (stejné
        # jméno, NOVÝ device key) spadne na 500.
        prev = c.execute("SELECT * FROM workstation WHERE hostname = %s",
                         (b.hostname,)).fetchone()
        if prev and prev["principal_id"] != p["id"]:
            # Jména strojů unikátní nejsou — dva lidé mají klidně oba
            # "MacBook-Pro". Přepsat cizí řádek by tomu druhému tiše vzalo
            # přístup, takže radši řekneme, co se děje.
            raise HTTPException(
                409,
                f"stroj se jménem '{b.hostname}' už je registrovaný na někoho jiného. "
                f"Přejmenuj si ho a pusť instalaci znovu.")
        # Nový klíč nikdy nepřepisujeme prázdnou hodnotou: opakovaná
        # registrace bez klíče by jinak člověku vzala přihlášení na VPS.
        if prev:
            ws = c.execute(
                """UPDATE workstation
                      SET device_key_fp = %s, revoked_at = NULL,
                          ssh_public_key = COALESCE(%s, ssh_public_key),
                          login = COALESCE(%s, login),
                          key_installed_at = CASE
                            WHEN %s IS NOT NULL AND %s <> COALESCE(ssh_public_key, '')
                            THEN NULL ELSE key_installed_at END
                    WHERE id = %s
                  RETURNING *""",
                (b.device_key_fp, b.ssh_public_key, b.login,
                 b.ssh_public_key, b.ssh_public_key, prev["id"])).fetchone()
        else:
            ws = c.execute(
                """INSERT INTO workstation (principal_id, hostname, device_key_fp,
                                            channel, ssh_public_key, login)
                   VALUES (%s, %s, %s, 'stable', %s, %s)
                   ON CONFLICT (device_key_fp) DO UPDATE
                     SET hostname = EXCLUDED.hostname, revoked_at = NULL,
                         ssh_public_key = COALESCE(EXCLUDED.ssh_public_key,
                                                   workstation.ssh_public_key),
                         login = COALESCE(EXCLUDED.login, workstation.login)
                   RETURNING *""",
                (p["id"], b.hostname, b.device_key_fp,
                 b.ssh_public_key, b.login)).fetchone()
        _emit(c, p["id"], "workstation", str(ws["id"]), "registered",
              {"hostname": b.hostname}, b.device_key_fp)

    git_ok = _forgejo_add_key(b.display_name, b.email, b.hostname, b.ssh_public_key)

    return {"workstation_id": ws["id"], "channel": ws["channel"],
            "git_ready": git_ok,
            "git_ssh": GIT_SSH,
            "dashboard": os.environ.get("AGENTICDEV_DOMAIN", "")}


# ═══════════════════════════════════════════════════════════════
#  SSH klíče pro přihlášení na VPS (režim domain, bez Tailscale)
# ═══════════════════════════════════════════════════════════════
# S Tailscale dělá autentizaci tailnet a klíče nikdo neřeší. Bez něj se
# člověk přihlašuje obyčejným SSH, takže se jeho veřejný klíč musí dostat
# do `~/.ssh/authorized_keys` na VPS.
#
# Control plane to NEDĚLÁ a dělat nemá: běží v kontejneru, do /home
# nedosáhne, a kdyby dosáhl, měl by cestu k rootu. Zapisuje to `root`
# příkazem `agenticdev-ctl keys sync`, který si sem přijde pro seznam.
@router.get("/v1/ssh-keys/pending")
def ssh_keys_pending(op: dict = Depends(operator)):
    """Klíče, které ještě nejsou v authorized_keys."""
    with db() as c:
        return c.execute(
            """SELECT w.id, w.login, w.hostname, w.ssh_public_key,
                      p.display_name
               FROM workstation w JOIN principal p ON p.id = w.principal_id
               WHERE w.ssh_public_key IS NOT NULL
                 AND w.login IS NOT NULL
                 AND w.key_installed_at IS NULL
                 AND w.revoked_at IS NULL
               ORDER BY w.hostname""").fetchall()


class KeyDone(BaseModel):
    ok: bool = True


@router.post("/v1/ssh-keys/{ws_id}/installed")
def ssh_key_installed(ws_id: str, b: KeyDone, op: dict = Depends(operator)):
    """Potvrzení od `agenticdev-ctl keys sync`, že klíč je na místě."""
    with db() as c:
        row = c.execute(
            """UPDATE workstation SET key_installed_at = now()
                WHERE id = %s RETURNING id, login, hostname""", (ws_id,)).fetchone()
        if not row:
            raise HTTPException(404, "stanice neexistuje")
        _emit(c, who(op), "workstation", ws_id, "ssh_key_installed",
              {"login": row["login"], "hostname": row["hostname"]},
              f"sshkey:{ws_id}")
    return {"ok": True, "login": row["login"]}


def _forgejo_add_key(display_name: str, email: str | None,
                     hostname: str, pubkey: str | None) -> bool:
    """
    Bez klíče ve Forgeju nefunguje `git clone`. Zakládá i uživatele,
    když ještě neexistuje — jinak by nový člověk nemohl commitovat pod sebou.
    """
    if not (pubkey and FORGEJO_TOKEN):
        return False
    login = re.sub(r"[^a-z0-9]+", "", display_name.lower().replace(" ", "."))[:38] or "dev"
    h = {"Authorization": f"token {FORGEJO_TOKEN}", "content-type": "application/json"}
    try:
        r = httpx.get(f"{FORGEJO_URL}/api/v1/users/{login}", headers=h, timeout=15)
        if r.status_code == 404:
            httpx.post(f"{FORGEJO_URL}/api/v1/admin/users", headers=h, timeout=20,
                       json={"username": login, "email": email or f"{login}@agenticdev.local",
                             "password": secrets.token_urlsafe(24),
                             "must_change_password": False})
        r = httpx.post(f"{FORGEJO_URL}/api/v1/admin/users/{login}/keys", headers=h, timeout=20,
                       json={"title": f"agenticdev-{hostname}", "key": pubkey.strip()})
        return r.status_code in (201, 422)          # 422 = klíč už tam je
    except Exception:
        return False


# ═══════════════════════════════════════════════════════════════
#  Projekty
# ═══════════════════════════════════════════════════════════════
class NewProject(BaseModel):
    code: str
    client_name: str
    data_class: str = "internal"
    budget_czk_month: float = 5000
    import_url: str | None = None      # existující repo — naklonuje se i s historií


PRD_FILES = {
    "00-context.md":       "# Kontext klienta\n\nKdo je klient, co dělá, kdo je kontaktní osoba,\njakým jazykem se s ním komunikuje.\n",
    "10-requirements.md":  "# Požadavky\n\n## REQ-001\n\nPopiš první požadavek. Číslování je stabilní — na ID se odkazují úkoly.\n",
    "20-constraints.md":   "# Omezení\n\nTechnická, legislativní, rozpočtová.\n",
    "30-architecture.md":  "# Cílová architektura\n",
    "50-glossary.md":      "# Glosář\n\nDoménové pojmy klienta. NEJDŮLEŽITĚJŠÍ SOUBOR.\nAgent bez klientské terminologie píše syntakticky správný\na sémanticky špatný kód.\n\n| Pojem | Význam |\n|---|---|\n|  |  |\n",
    "40-decisions/README.md": "# ADR\n\nJeden soubor = jedno rozhodnutí.\n",
}

# Brána před mergem (ADR-0006). Pouští to runner na VPS, ne agent ve svém
# podu — o to celé jde. Dokud v repozitáři není co spustit, projde to, ale
# v logu musí být poznat rozdíl mezi „testy nejsou" a „testy padají",
# jinak se z prvního stavu stane trvalý.
TEST_WORKFLOW = """name: test

on:
  pull_request:
  push:
    branches: [main]

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4

      - name: Co je v repozitáři ke spuštění
        id: detect
        run: |
          if   [ -f package.json ] && grep -q '"test"' package.json; then echo "kind=node" >> $GITHUB_OUTPUT
          elif [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; then echo "kind=python" >> $GITHUB_OUTPUT
          elif [ -f Makefile ] && grep -qE '^test:' Makefile; then echo "kind=make" >> $GITHUB_OUTPUT
          elif [ -f go.mod ]; then echo "kind=go" >> $GITHUB_OUTPUT
          else echo "kind=none" >> $GITHUB_OUTPUT
          fi
          echo "zjištěno: $(cat $GITHUB_OUTPUT)"

      - name: Testy nejsou
        if: steps.detect.outputs.kind == 'none'
        run: |
          echo "::warning::V repozitáři nejsou žádné testy. Brána projde, ale nic neověřila."
          echo "Až přidáš testy, začne jejich selhání merge blokovat."

      - name: Testy
        if: steps.detect.outputs.kind != 'none'
        run: |
          set -e
          case "${{ steps.detect.outputs.kind }}" in
            node)   npm ci --no-audit --no-fund || npm install --no-audit --no-fund; npm test ;;
            python) python -m pip install -q -e . 2>/dev/null || true; python -m pytest -q ;;
            make)   make test ;;
            go)     go test ./... ;;
          esac
"""


def _forgejo_create_repo(code: str) -> str | None:
    if not FORGEJO_TOKEN:
        return None
    try:
        r = httpx.post(f"{FORGEJO_URL}/api/v1/user/repos",
                       headers={"Authorization": f"token {FORGEJO_TOKEN}"},
                       json={"name": code, "private": True, "auto_init": True,
                             "default_branch": "main",
                             "description": f"AgenticDev projekt {code}"},
                       timeout=30)
        if r.status_code in (201, 409):
            return f"{GIT_SSH}/{r.json().get('owner', {}).get('login', 'agenticdev')}/{code}.git" \
                   if r.status_code == 201 else f"{GIT_SSH}/agenticdev/{code}.git"
    except Exception:
        pass
    return None


def _forgejo_migrate(code: str, url: str) -> str | None:
    """Naklonuje existující repo i s historií a větvemi."""
    if not FORGEJO_TOKEN:
        return None
    try:
        r = httpx.post(f"{FORGEJO_URL}/api/v1/repos/migrate",
                       headers={"Authorization": f"token {FORGEJO_TOKEN}"},
                       json={"clone_addr": url, "repo_name": code,
                             "private": True, "mirror": False, "service": "git"},
                       timeout=300)
        if r.status_code in (201, 409):
            return f"{GIT_SSH}/agenticdev/{code}.git"
    except Exception:
        pass
    return None


def _forgejo_put(owner: str, code: str, path: str, content: str, message: str) -> bool:
    import base64 as b64
    try:
        r = httpx.post(
            f"{FORGEJO_URL}/api/v1/repos/{owner}/{code}/contents/{path}",
            headers={"Authorization": f"token {FORGEJO_TOKEN}"},
            json={"content": b64.b64encode(content.encode()).decode(),
                  "message": message, "branch": "main"},
            timeout=30)
        return r.status_code in (200, 201)
    except Exception:
        return False


def _forgejo_seed_prd(code: str, owner: str = "agenticdev") -> None:
    if not FORGEJO_TOKEN:
        return
    for path, content in PRD_FILES.items():
        _forgejo_put(owner, code, f"prd/{path}", content, f"prd: {path}")


def _forgejo_seed_workflow(owner: str, code: str) -> bool:
    """
    Brána před mergem musí existovat od prvního dne, jinak se na ni
    zapomene a testy si dál pouští jen agent sám u sebe.

    Platí to i pro importovaný repozitář — tam dokonce víc: branch
    protection čeká na zelený status a bez workflow ho nikdo nevydá, takže
    by v takovém projektu nešlo smergovat vůbec nic.
    """
    if not FORGEJO_TOKEN:
        return False
    return _forgejo_put(owner, code, ".forgejo/workflows/test.yml", TEST_WORKFLOW,
                        "ci: brána před mergem")


def _gate_contexts() -> list[str]:
    """
    Které commit statusy musí být zelené, aby šel merge.

    Pozor na tvar: Forgejo Actions nepublikuje status pod jménem workflow,
    ale jako `<workflow> / <job> (<událost>)` — u našeho workflow tedy
    `test / test (pull_request)`. Prostý `test` se s tím nikdy nepotká.
    A požadovaný status, který nikdy nepřijde, drží merge zablokovaný
    navždycky — tichá varianta téhle chyby je horší než žádná brána,
    protože vypadá jako „brána funguje".

    Forgejo porovnává vzory glob, takže výchozí `test / *` sedne na
    všechny události. Kdyby to tvoje verze pojmenovávala jinak, zjistíš
    skutečný tvar příkazem `agenticdev-ctl gate <projekt>` a přepíšeš to
    v panelu.
    """
    raw = cfg.get("MERGE_GATE_CONTEXTS", "test / *")
    return [c.strip() for c in raw.split(",") if c.strip()] or ["test / *"]


def _forgejo_protect_main(owner: str, code: str) -> bool:
    """
    Bez tohohle by šlo smergovat i s červenými testy a celá brána by byla
    jen ozdoba. `enable_status_check` znamená, že merge čeká na workflow.
    """
    if not FORGEJO_TOKEN:
        return False
    try:
        r = httpx.post(
            f"{FORGEJO_URL}/api/v1/repos/{owner}/{code}/branch_protections",
            headers={"Authorization": f"token {FORGEJO_TOKEN}"},
            json={"branch_name": "main",
                  "enable_push": False,
                  "enable_status_check": True,
                  "status_check_contexts": _gate_contexts(),
                  "block_on_outdated_branch": False,
                  # Kolik lidí musí PR odkliknout. Nula znamená, že kód
                  # projde, aniž by ho někdo přečetl — u týmu, kde autoři
                  # nejsou programátoři, je to ta podstatná pojistka.
                  "required_approvals": cfg.get_int("MERGE_GATE_APPROVALS", 0)},
            timeout=30)
        return r.status_code in (200, 201, 409)
    except Exception:
        return False


def _forgejo_add_hook(owner: str, code: str) -> bool:
    """
    Webhook, kterým se control plane dozví o mergi — bez něj se úkol nikdy
    nepřepne na `done` (ADR-0006). Podepisuje se sdíleným tajemstvím,
    protože nepodepsaný požadavek by komukoli na tailnetu dovolil
    označovat úkoly za hotové.
    """
    secret = os.environ.get("FORGEJO_HOOK_SECRET", "")
    cp = os.environ.get("CONTROL_PLANE_INTERNAL_URL", "http://control-plane:8080")
    if not (FORGEJO_TOKEN and secret):
        return False
    try:
        r = httpx.post(
            f"{FORGEJO_URL}/api/v1/repos/{owner}/{code}/hooks",
            headers={"Authorization": f"token {FORGEJO_TOKEN}"},
            json={"type": "forgejo", "active": True,
                  "events": ["pull_request"],
                  "config": {"url": f"{cp}/v1/hooks/forgejo",
                             "content_type": "json", "secret": secret}},
            timeout=30)
        return r.status_code in (200, 201)
    except Exception:
        return False


@router.post("/v1/projects")
def create_project(p: NewProject, op: dict = Depends(operator)):
    code = p.code.strip().lower().replace(" ", "-")

    if p.import_url:
        repo = _forgejo_migrate(code, p.import_url) or f"{GIT_SSH}/agenticdev/{code}.git"
    else:
        repo = _forgejo_create_repo(code) or f"{GIT_SSH}/agenticdev/{code}.git"

    # Majitele bereme z adresy, kterou Forgejo vrátilo — token nemusí patřit
    # uživateli `agenticdev`. Proto se zakládá až tady, po něm: se špatným
    # majitelem v cestě by zápis tiše selhal a projekt by zůstal bez PRD
    # i bez brány.
    owner = (re.search(r"/([^/]+)/[^/]+?(?:\.git)?$", repo) or [None, "agenticdev"])[1]

    # PRD jen do nového repozitáře — do importovaného cizí soubory nepatří.
    if not p.import_url:
        _forgejo_seed_prd(code, owner)
    flow = _forgejo_seed_workflow(owner, code)
    gate = _forgejo_protect_main(owner, code)
    hook = _forgejo_add_hook(owner, code)

    with db() as c:
        client = c.execute("SELECT * FROM client WHERE name = %s", (p.client_name,)).fetchone()
        if not client:
            client = c.execute("INSERT INTO client (name) VALUES (%s) RETURNING *",
                               (p.client_name,)).fetchone()
        exists = c.execute("SELECT 1 FROM project WHERE code = %s", (code,)).fetchone()
        if exists:
            raise HTTPException(409, f"projekt '{code}' už existuje")

        models = [os.environ.get("LOCAL_MODEL", "local/qwen2.5-coder:32b")] \
                 if p.data_class == "restricted" else [DEF_MODEL]
        proj = c.execute(
            """INSERT INTO project (client_id, code, repo_url, data_class,
                                    model_allowlist, budget_czk_month)
               VALUES (%s,%s,%s,%s,%s,%s) RETURNING *""",
            (client["id"], code, repo, p.data_class, models, p.budget_czk_month)).fetchone()

        for i, kind in enumerate(PHASES):
            c.execute(
                """INSERT INTO phase (project_id, kind, order_idx, active)
                   VALUES (%s,%s,%s,%s)""",
                (proj["id"], kind, i, kind == "implementation"))
        _emit(c, who(op), "project", str(proj["id"]), "created", {"code": code}, code)

    notes = [f"Vyplň prd/{code}/50-glossary.md, pak založ první úkol."]
    if not flow:
        notes.append("Workflow se nezaložilo — bránu před mergem nemá co spustit.")
    if not gate:
        notes.append("Branch protection se nenastavila — merge zatím nic nebrání.")
    if not hook:
        notes.append("Webhook nevznikl — úkol se po mergi nepřepne na hotovo.")
    if flow and gate and hook:
        notes.append(f"Bránu ověř na prvním PR: agenticdev-ctl gate {code}")

    return {"project": proj, "repo_url": repo,
            "prd_seeded": bool(FORGEJO_TOKEN) and not p.import_url,
            "workflow": flow, "merge_gate": gate, "webhook": hook,
            "next": " ".join(notes)}


# ═══════════════════════════════════════════════════════════════
#  Diagnostika brány před mergem
# ═══════════════════════════════════════════════════════════════
def _fj_get(path: str):
    """GET do Forgeja. Vrací (status, tělo) — tělo je None, když to není JSON."""
    try:
        r = httpx.get(f"{FORGEJO_URL}/api/v1{path}",
                      headers={"Authorization": f"token {FORGEJO_TOKEN}"}, timeout=20)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, None
    except Exception:
        return 0, None


@router.get("/v1/projects/{code}/gate")
def gate_status(code: str, op: dict = Depends(operator)):
    """
    Řekne, jestli brána před mergem doopravdy stojí — a hlavně jaká jména
    commit statusů Forgejo skutečně vydává.

    Existuje kvůli jedné konkrétní pasti: požadovaný status, který se
    nikdy neobjeví, vypadá v panelu stejně jako fungující brána, jenže
    drží merge zablokovaný navždycky. Bez porovnání „požadované vs.
    viděné" se to nepozná jinak než tím, že to někomu nejde smergovat.
    """
    if not FORGEJO_TOKEN:
        raise HTTPException(503, "FORGEJO_TOKEN není nastavený — z Forgeja se nedozvím nic")

    with db() as c:
        proj = c.execute("SELECT code, repo_url FROM project WHERE code = %s",
                         (code,)).fetchone()
    if not proj:
        raise HTTPException(404, f"projekt '{code}' neexistuje")

    m = re.search(r"/([^/]+)/([^/]+?)(?:\.git)?$", proj["repo_url"] or "")
    if not m:
        raise HTTPException(400, f"z repo_url '{proj['repo_url']}' nepoznám majitele a jméno")
    slug = f"{m.group(1)}/{m.group(2)}"

    st, _ = _fj_get(f"/repos/{slug}/contents/.forgejo/workflows/test.yml")
    workflow = st == 200

    st, prot = _fj_get(f"/repos/{slug}/branch_protections/main")
    required: list[str] = []
    approvals = None
    status_check = False
    if st == 200 and isinstance(prot, dict):
        required = prot.get("status_check_contexts") or []
        approvals = prot.get("required_approvals")
        status_check = bool(prot.get("enable_status_check"))

    st, hooks = _fj_get(f"/repos/{slug}/hooks")
    webhook = bool(st == 200 and isinstance(hooks, list) and any(
        "/v1/hooks/forgejo" in ((h.get("config") or {}).get("url") or "") for h in hooks))

    # Jména statusů, která Forgejo na posledním PR opravdu vydalo. Tohle je
    # ta jediná hodnota, kterou se z kódu vyčíst nedá.
    seen: list[str] = []
    st, pulls = _fj_get(f"/repos/{slug}/pulls?state=all&sort=recentupdate&limit=1")
    if st == 200 and isinstance(pulls, list) and pulls:
        sha = ((pulls[0].get("head") or {}).get("sha")) or ""
        if sha:
            st, statuses = _fj_get(f"/repos/{slug}/commits/{sha}/statuses")
            if st == 200 and isinstance(statuses, list):
                seen = sorted({s.get("context", "") for s in statuses if s.get("context")})

    matched = [s for s in seen if any(fnmatch.fnmatch(s, pat) for pat in required)]

    if not workflow:
        verdict = "workflow v repozitáři není — bránu nemá co spustit"
    elif not status_check or not required:
        verdict = "branch protection nečeká na žádný status — merge nic nebrání"
    elif not seen:
        verdict = ("na posledním PR nejsou žádné statusy — buď ještě žádné PR nebylo, "
                   "nebo runner workflow nespustil")
    elif not matched:
        verdict = (f"POŽADOVANÉ STATUSY SE NEPOTKÁVAJÍ S VYDANÝMI — merge zůstane "
                   f"zablokovaný navždy. Požaduje se {required}, Forgejo vydává {seen}. "
                   f"Přepiš „Požadované statusy\" v panelu.")
    elif not webhook:
        verdict = "brána stojí, ale webhook chybí — úkol se po mergi nepřepne na hotovo"
    else:
        verdict = "brána stojí a statusy se potkávají"

    return {"project": code, "repo": slug,
            "workflow": workflow, "status_check": status_check,
            "required_contexts": required, "seen_contexts": seen, "matched": matched,
            "required_approvals": approvals, "webhook": webhook,
            "ok": bool(workflow and status_check and required and matched and webhook),
            "verdict": verdict}


@router.post("/v1/projects/{code}/gate")
def gate_apply(code: str, op: dict = Depends(operator)):
    """
    Nasadí bránu znovu podle aktuálního nastavení.

    Branch protection se jinak nastavuje jen při zakládání projektu, takže
    změna „Požadovaných statusů\" v panelu by se do existujících projektů
    nikdy nedostala — a právě u nich se ta chyba s nesedícím jménem statusu
    objeví.
    """
    if not FORGEJO_TOKEN:
        raise HTTPException(503, "FORGEJO_TOKEN není nastavený")

    with db() as c:
        proj = c.execute("SELECT id, code, repo_url FROM project WHERE code = %s",
                         (code,)).fetchone()
    if not proj:
        raise HTTPException(404, f"projekt '{code}' neexistuje")

    m = re.search(r"/([^/]+)/([^/]+?)(?:\.git)?$", proj["repo_url"] or "")
    if not m:
        raise HTTPException(400, f"z repo_url '{proj['repo_url']}' nepoznám majitele a jméno")
    owner, name = m.group(1), m.group(2)

    flow = _forgejo_seed_workflow(owner, name)
    # POST na existující ochranu vrací 409, proto ještě PATCH — jinak by
    # změna nastavení neplatila pro projekt, který ochranu už má.
    gate = _forgejo_protect_main(owner, name)
    try:
        r = httpx.patch(
            f"{FORGEJO_URL}/api/v1/repos/{owner}/{name}/branch_protections/main",
            headers={"Authorization": f"token {FORGEJO_TOKEN}"},
            json={"enable_status_check": True,
                  "status_check_contexts": _gate_contexts(),
                  "required_approvals": cfg.get_int("MERGE_GATE_APPROVALS", 0)},
            timeout=30)
        gate = gate or r.status_code in (200, 201)
    except Exception:
        pass
    hook = _forgejo_add_hook(owner, name)

    with db() as c:
        _emit(c, who(op), "project", str(proj["id"]), "gate_applied",
              {"workflow": flow, "protection": gate, "webhook": hook,
               "contexts": _gate_contexts()}, f"gate:{code}:{'-'.join(_gate_contexts())}")

    return {"project": code, "workflow": flow, "protection": gate, "webhook": hook,
            "required_contexts": _gate_contexts(),
            "next": f"Ověř na PR: agenticdev-ctl gate {code}"}


@router.get("/v1/projects")
def list_projects(op: dict = Depends(operator)):
    with db() as c:
        return c.execute(
            """SELECT p.*, cl.name AS client_name,
                      (SELECT kind FROM phase WHERE project_id = p.id AND active LIMIT 1) AS phase,
                      (SELECT count(*) FROM task t JOIN phase ph ON ph.id=t.phase_id
                        WHERE ph.project_id = p.id) AS task_count,
                      (SELECT COALESCE(SUM(ar.cost_czk),0) FROM agent_run ar
                         JOIN task t ON t.id=ar.task_id JOIN phase ph ON ph.id=t.phase_id
                        WHERE ph.project_id = p.id) AS spent_czk
               FROM project p LEFT JOIN client cl ON cl.id = p.client_id
               ORDER BY p.created_at DESC""").fetchall()


class PhaseSwitch(BaseModel):
    kind: str


@router.post("/v1/projects/{code}/phase")
def set_phase(code: str, b: PhaseSwitch, op: dict = Depends(operator)):
    if b.kind not in PHASES:
        raise HTTPException(400, f"neznámá fáze; povolené: {PHASES}")
    with db() as c:
        pr = c.execute("SELECT id FROM project WHERE code = %s", (code,)).fetchone()
        if not pr:
            raise HTTPException(404, "projekt neexistuje")
        c.execute("UPDATE phase SET active = false WHERE project_id = %s", (pr["id"],))
        c.execute("UPDATE phase SET active = true WHERE project_id = %s AND kind = %s",
                  (pr["id"], b.kind))
    return {"ok": True, "active_phase": b.kind}


# ═══════════════════════════════════════════════════════════════
#  Úkoly
# ═══════════════════════════════════════════════════════════════
class NewTask(BaseModel):
    project: str
    title: str
    kind: str = "feature"
    spec_ref: str | None = None
    dod: list[str] = []
    write_scope: list[str] = ["src/**", "tests/**"]
    risk: str = "standard"
    budget_czk: float = 300
    priority: int = 100


@router.post("/v1/tasks")
def create_task(t: NewTask, op: dict = Depends(operator)):
    if not t.dod:
        raise HTTPException(400, "Úkol bez Definition of Done nezaložím — "
                                 "agent by neměl jak poznat, že skončil.")
    with db() as c:
        ph = c.execute(
            """SELECT ph.id FROM phase ph JOIN project p ON p.id = ph.project_id
               WHERE p.code = %s AND ph.active LIMIT 1""", (t.project,)).fetchone()
        if not ph:
            raise HTTPException(404, f"projekt '{t.project}' nemá aktivní fázi")
        row = c.execute(
            """INSERT INTO task (phase_id, kind, title, spec_ref, dod, write_scope,
                                 risk, budget_czk, state, priority)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'ready',%s) RETURNING *""",
            (ph["id"], t.kind, t.title, t.spec_ref, json.dumps(t.dod),
             t.write_scope, t.risk, t.budget_czk, t.priority)).fetchone()
        _emit(c, who(op), "task", str(row["id"]), "created", {"title": t.title}, str(row["id"]))
    return {"task": row}


@router.get("/v1/tasks")
def list_tasks(state: str | None = None, op: dict = Depends(operator)):
    q = """SELECT t.*, p.code AS project, ph.kind AS phase,
                  COALESCE((SELECT SUM(cost_czk) FROM agent_run WHERE task_id=t.id),0) AS spent_czk,
                  (SELECT display_name FROM principal pr
                     JOIN workstation w ON w.principal_id=pr.id
                     JOIN assignment a ON a.workstation_id=w.id
                    WHERE a.task_id=t.id AND a.state='active' LIMIT 1) AS assignee
           FROM task t JOIN phase ph ON ph.id=t.phase_id JOIN project p ON p.id=ph.project_id"""
    with db() as c:
        if state:
            return c.execute(q + " WHERE t.state = %s ORDER BY t.priority, t.created_at",
                             (state,)).fetchall()
        return c.execute(q + " ORDER BY t.priority, t.created_at LIMIT 200").fetchall()


@router.get("/v1/tasks/{task_id}/timeline")
def task_timeline(task_id: str, op: dict = Depends(operator)):
    """
    Co se s úkolem dělo, krok po kroku.

    Data v ledgeru jsou od začátku, chyběla jen obrazovka. Skládá se to ze
    tří zdrojů: `event` (auditní stopa, append-only), `agent_run` (běhy
    agenta s modelem, dobou a transkriptem) a `decision` (co odklikl
    člověk). Dohromady je z toho odpověď na „kde se co pokazilo".
    """
    with db() as c:
        task = c.execute(
            """SELECT t.id, t.title, t.state, t.budget_czk, p.code AS project,
                      ph.kind AS phase
               FROM task t JOIN phase ph ON ph.id = t.phase_id
               JOIN project p ON p.id = ph.project_id
               WHERE t.id = %s""", (task_id,)).fetchone()
        if not task:
            raise HTTPException(404, "úkol neexistuje")

        events = c.execute(
            """SELECT ts, verb, payload, actor_id FROM event
               WHERE subject_type = 'task' AND subject_id = %s
               ORDER BY ts""", (task_id,)).fetchall()
        runs = c.execute(
            """SELECT created_at, role, state_name, model, duration_ms, outcome,
                      tokens_in, tokens_out, cost_czk, transcript_uri
               FROM agent_run WHERE task_id = %s ORDER BY created_at""",
            (task_id,)).fetchall()
        decisions = c.execute(
            """SELECT decided_at, question, chosen, rationale, state, adr_ref
               FROM decision WHERE task_id = %s ORDER BY created_at""",
            (task_id,)).fetchall()

    totals = {
        "runs": len(runs),
        "duration_ms": sum(r["duration_ms"] or 0 for r in runs),
        "cost_czk": float(sum(r["cost_czk"] or 0 for r in runs)),
        "tokens": sum((r["tokens_in"] or 0) + (r["tokens_out"] or 0) for r in runs),
    }
    # Tokeny dnes nikdo neohlašuje (Pi je nevydává), takže cena zůstává
    # nulová. Říkáme to rovnou, aby se nula nečetla jako „nic to nestálo".
    totals["cost_measured"] = totals["tokens"] > 0

    return {"task": task, "events": events, "runs": runs,
            "decisions": decisions, "totals": totals}


# ═══════════════════════════════════════════════════════════════
#  Rozhodnutí
# ═══════════════════════════════════════════════════════════════
class Resolve(BaseModel):
    chosen: str
    rationale: str
    approve: bool = True


@router.post("/v1/decisions/{did}/resolve")
def resolve(did: str, b: Resolve, op: dict = Depends(operator)):
    with db() as c:
        d = c.execute(
            """UPDATE decision
                  SET state = %s, chosen = %s, rationale = %s, decided_at = now()
                WHERE id = %s AND state = 'pending_human'
              RETURNING *""",
            ("approved" if b.approve else "rejected", b.chosen, b.rationale, did)).fetchone()
        if not d:
            raise HTTPException(409, "rozhodnutí už bylo vyřešeno")
        c.execute("UPDATE task SET state = %s WHERE id = %s",
                  ("ready" if b.approve else "backlog", d["task_id"]))
        _emit(c, who(op), "decision", did, "resolved",
              {"chosen": b.chosen, "approved": b.approve}, did)
    return {"ok": True, "task_state": "ready" if b.approve else "backlog"}


# ═══════════════════════════════════════════════════════════════
#  Tým
# ═══════════════════════════════════════════════════════════════
@router.get("/v1/enrollments")
def enrollments(op: dict = Depends(operator)):
    """
    Kdo se ohlásil na registrační stránce a ještě nemá účet na VPS.
    Účty zakládá root příkazem `agenticdev-ctl user add`, protože control
    plane na to nemá právo — tady je jen vidí, aby věděl koho.
    """
    with db() as c:
        try:
            return c.execute(
                """SELECT e.*,
                          EXISTS (SELECT 1 FROM principal p
                                   WHERE lower(p.email) = lower(e.email)) AS has_account
                   FROM enrollment e
                   WHERE e.claimed_at IS NULL
                   ORDER BY e.created_at DESC LIMIT 50""").fetchall()
        except Exception:                      # tabulka ještě nemigrovala
            return []


@router.get("/v1/team")
def team(op: dict = Depends(operator)):
    with db() as c:
        return c.execute(
            """SELECT w.*, p.display_name, p.email FROM workstation w
               JOIN principal p ON p.id = w.principal_id ORDER BY w.last_seen_at DESC NULLS LAST"""
        ).fetchall()


@router.post("/v1/team/{ws_id}/revoke")
def revoke_ws(ws_id: str, op: dict = Depends(operator)):
    with db() as c:
        c.execute("UPDATE workstation SET revoked_at = now() WHERE id = %s", (ws_id,))
        _emit(c, who(op), "workstation", ws_id, "revoked", {}, f"revoke:{ws_id}")
    return {"ok": True}


class Channel(BaseModel):
    channel: str


@router.post("/v1/team/{ws_id}/channel")
def set_channel(ws_id: str, b: Channel, op: dict = Depends(operator)):
    if b.channel not in ("canary", "beta", "stable"):
        raise HTTPException(400, "kanál musí být canary, beta nebo stable")
    with db() as c:
        c.execute("UPDATE workstation SET channel = %s WHERE id = %s", (b.channel, ws_id))
    return {"ok": True}


# ═══════════════════════════════════════════════════════════════
#  Kill switch
# ═══════════════════════════════════════════════════════════════
class Kill(BaseModel):
    enabled: bool
    reason: str = ""


@router.post("/v1/kill-switch")
def kill_switch(b: Kill, op: dict = Depends(operator)):
    with db() as c:
        c.execute("""UPDATE platform_state
                        SET issuing_enabled = %s, reason = %s, updated_at = now()
                      WHERE id = 1""", (b.enabled, b.reason))
    return {"issuing_enabled": b.enabled}


# ═══════════════════════════════════════════════════════════════
#  Nástěnka — všechno jedním dotazem
# ═══════════════════════════════════════════════════════════════
@router.get("/v1/board")
def board(op: dict = Depends(operator)):
    with db() as c:
        state = c.execute("SELECT * FROM platform_state WHERE id = 1").fetchone()
        counts = c.execute(
            "SELECT state, count(*) AS n FROM task GROUP BY state").fetchall()
        spend = c.execute(
            """SELECT COALESCE(SUM(cost_czk),0) AS today FROM agent_run
                WHERE created_at > date_trunc('day', now())""").fetchone()
        month = c.execute(
            """SELECT COALESCE(SUM(cost_czk),0) AS m FROM agent_run
                WHERE created_at > date_trunc('month', now())""").fetchone()
        pending = c.execute(
            """SELECT d.*, t.title, p.code AS project FROM decision d
               JOIN task t ON t.id = d.task_id
               JOIN phase ph ON ph.id = t.phase_id JOIN project p ON p.id = ph.project_id
               WHERE d.state = 'pending_human' ORDER BY d.created_at""").fetchall()
        active = c.execute(
            """SELECT t.title, p.code AS project, pr.display_name AS who,
                      a.heartbeat_at, a.lease_expires_at
               FROM assignment a
               JOIN task t ON t.id = a.task_id
               JOIN phase ph ON ph.id = t.phase_id JOIN project p ON p.id = ph.project_id
               JOIN workstation w ON w.id = a.workstation_id
               JOIN principal pr ON pr.id = w.principal_id
               WHERE a.state = 'active'""").fetchall()
        recent = c.execute(
            """SELECT ts, subject_type, verb, payload FROM event
               ORDER BY seq DESC LIMIT 25""").fetchall()
        # Nula u útraty má dva různé významy: „nic se neutratilo" a „nikdo
        # to nezměřil". Tokeny dnes neohlašuje nikdo (Pi je nevydává), takže
        # bez tohohle příznaku by panel tvrdil, že agentní vývoj je zdarma.
        runs = c.execute(
            """SELECT count(*) AS n, COALESCE(SUM(tokens_in + tokens_out),0) AS tok
               FROM agent_run""").fetchone()
    return {"platform": state, "task_counts": {r["state"]: r["n"] for r in counts},
            "spend_today_czk": float(spend["today"]), "spend_month_czk": float(month["m"]),
            "runs_total": runs["n"], "spend_measured": runs["tok"] > 0,
            "pending_decisions": pending, "active_work": active, "recent_events": recent}


# ═══════════════════════════════════════════════════════════════
#  Nastavení
# ═══════════════════════════════════════════════════════════════
class SettingsPatch(BaseModel):
    values: dict[str, str]


@router.get("/v1/settings")
def settings_get(op: dict = Depends(operator)):
    return cfg.as_form()


@router.post("/v1/settings")
def settings_set(body: SettingsPatch, op: dict = Depends(operator)):
    changed = cfg.set_many(body.values, by=op.get("role", "panel"))

    # Do ledgeru jde jen seznam klíčů, nikdy hodnoty — jsou mezi nimi hesla.
    # dedupe_key musí být neprázdný (NOT NULL) a pro každou změnu jiný,
    # jinak by unikátní index spolkl druhou úpravu téhož klíče.
    if changed:
        with db() as c:
            _emit(c, who(op), "platform", "settings", "updated",
                  {"keys": sorted(changed)},
                  f"settings:{now().isoformat()}")

    warn = None
    if "DASHBOARD_TOKEN" in changed:
        warn = "Heslo do panelu změněno. Otevřené relace doběhnou, nové už chtějí nové heslo."
    elif "ENROLL_PASSWORD" in changed:
        warn = "Heslo pro připojení změněno. Rozešli lidem nové."

    return {"ok": True, "changed": sorted(changed), "note": warn}
