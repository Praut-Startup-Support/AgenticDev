"""
Director — postup, kterým musí úkol projít.

Vynucuje ho harness uvnitř podu (ADR-0003). Není to sada instrukcí pro
agenta; instrukce si agent může přečíst a neposlechnout. Tady se po každém
kole spustí **kontroly projektu** a podle jejich výsledku se rozhodne, co
dál. Agent tedy nerozhoduje o tom, že je hotovo.

    plán → implementace → kontroly ─┐
                ▲                   │ selhaly
                └───────────────────┘ (do limitu z work orderu)
                                    │ prošly
                              human gate
                                    │
                                 hotovo

Co je vynucené a co ne:

  vynuceno    postup fází a jejich pořadí; strop opakování; že se přes
              selhané kontroly nepokračuje; že rizikovou změnu odklikne
              člověk

  nevynuceno  kvalita testů. Když projekt testy nemá, kontroly nemají co
              spustit a řekne se to nahlas — brána před mergem na serveru
              je druhá pojistka (ADR-0006).
"""
from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import time
import urllib.error
import urllib.request

WORKSPACE = pathlib.Path("/workspace")

C_OK, C_WARN, C_ERR, C_DIM, C_OFF = (
    "\033[1;32m", "\033[1;33m", "\033[1;31m", "\033[2m", "\033[0m")


# Transkript zakládá harness na hostiteli (`/trees/.transcripts/…`), tady
# se do něj jen dopisuje. Prázdná proměnná = nezapisovat. Bez tohohle je
# všechno, co director vypíše, ztracené v momentě, kdy se pod zbourá — a
# právě tenhle běh nikdo nesleduje, takže je to jediný záznam.
_LOG = pathlib.Path(os.environ["AGENTICDEV_TRANSCRIPT"]) \
    if os.environ.get("AGENTICDEV_TRANSCRIPT") else None


def _log(text: str) -> None:
    """Dopíše do transkriptu. Selhání ignoruje — na zápisu logu běh nestojí."""
    if not _LOG:
        return
    try:
        with _LOG.open("a") as f:
            f.write(text.rstrip() + "\n")
    except OSError:
        pass


def _plain(msg: str) -> str:
    """Bez barev — do souboru escape sekvence nepatří."""
    for c in (C_OK, C_WARN, C_ERR, C_DIM, C_OFF):
        msg = msg.replace(c, "")
    return msg


def _say(msg: str) -> None:
    print(f"  {msg}", flush=True)
    _log(f"  {_plain(msg)}")


def _step(n: int, total: int, name: str) -> None:
    print(f"\n{C_OK}▍{C_OFF} {n}/{total}  {name}", flush=True)
    _log(f"\n== {n}/{total}  {name}  [{time.strftime('%H:%M:%SZ', time.gmtime())}]")


# ═══════════════════════════════════════════════════════════════
#  Kontroly projektu
# ═══════════════════════════════════════════════════════════════
# Stejná detekce jako v šabloně workflow na serveru, ať pod a brána
# neověřují každý něco jiného.
def detect_checks(ws: pathlib.Path) -> list[tuple[str, list[str]]]:
    def has(name: str) -> bool:
        return (ws / name).exists()

    def pkg_has_test() -> bool:
        try:
            return "test" in (json.loads((ws / "package.json").read_text())
                              .get("scripts") or {})
        except Exception:                                   # noqa: BLE001
            return False

    if has("package.json") and pkg_has_test():
        return [("testy", ["npm", "test", "--silent"])]
    if has("pyproject.toml") or has("pytest.ini") or (ws / "tests").is_dir():
        return [("testy", ["python3", "-m", "pytest", "-q"])]
    if has("Makefile"):
        try:
            if any(l.startswith("test:") for l in (ws / "Makefile").read_text().splitlines()):
                return [("testy", ["make", "test"])]
        except Exception:                                   # noqa: BLE001
            pass
    if has("go.mod"):
        return [("testy", ["go", "test", "./..."])]
    return []


def run_checks(checks: list[tuple[str, list[str]]], ws: pathlib.Path) -> tuple[bool, str]:
    """Vrátí (prošlo, výpis). Bez kontrol vrací True a řekne to."""
    if not checks:
        return True, "projekt nemá co spustit"
    for name, cmd in checks:
        if not shutil.which(cmd[0]):
            return False, f"{name}: {cmd[0]} není v obrazu podu"
        p = subprocess.run(cmd, cwd=str(ws), capture_output=True, text=True)
        # Do transkriptu jde celý výpis, ne jen ocas. Do promptu agenta se
        # posílá 25 řádků, aby se nezahltil, ale ladit se musí z úplného.
        _log(f"\n--- {name}: {' '.join(cmd)} (exit {p.returncode})\n"
             + (p.stdout + p.stderr).strip())
        if p.returncode != 0:
            tail = (p.stdout + p.stderr).strip().splitlines()[-25:]
            return False, f"{name} spadly:\n" + "\n".join(tail)
    return True, "kontroly prošly"


# ═══════════════════════════════════════════════════════════════
#  Human gate
# ═══════════════════════════════════════════════════════════════
# Co nesmí projít bez člověka. Poznáme to z toho, co se v diffu změnilo —
# ne z toho, co agent tvrdí, že udělal.
GATE_PATTERNS: dict[str, tuple[str, ...]] = {
    "schema_migration": ("migrations/", "migration/", ".sql"),
    "dependency_add":   ("package.json", "package-lock.json", "pnpm-lock.yaml",
                         "requirements.txt", "pyproject.toml", "poetry.lock",
                         "go.mod", "go.sum", "Cargo.toml", "Gemfile"),
    "prod_deploy":      ("infra/", "deploy/", "compose.yaml", "compose.yml",
                         "docker-compose.yml", "Dockerfile", ".forgejo/workflows/"),
}


def changed_files(ws: pathlib.Path) -> list[str]:
    p = subprocess.run(["git", "status", "--porcelain"], cwd=str(ws),
                       capture_output=True, text=True)
    out = []
    for line in p.stdout.splitlines():
        if len(line) > 3:
            out.append(line[3:].strip().split(" -> ")[-1])
    return out


def gate_hits(files: list[str], gates: list[str]) -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {}
    for gate in gates:
        pats = GATE_PATTERNS.get(gate)
        if not pats:
            continue
        matched = [f for f in files if any(pat in f for pat in pats)]
        if matched:
            hits[gate] = matched
    return hits


# ═══════════════════════════════════════════════════════════════
#  Ledger
# ═══════════════════════════════════════════════════════════════
def emit(policy: dict, verb: str, payload: dict) -> None:
    """
    Zápis do auditní stopy. Selhání se jen zaloguje — postup úkolu nesmí
    spadnout na tom, že se nepovedlo zapsat, že spadl.
    """
    cp = policy.get("control_plane")
    task = (policy.get("task") or {}).get("id") or policy.get("task_id") or ""
    if not (cp and task):
        return
    tok = ""
    try:
        tok = pathlib.Path("/run/agenticdev/token").read_text().strip()
    except OSError:
        return
    body = json.dumps({
        "subject_type": "task", "subject_id": task, "verb": verb,
        "payload": payload,
        "dedupe_key": f"{policy.get('work_order_id', 'wo')}:{verb}:{payload.get('n', 0)}",
    }).encode()
    req = urllib.request.Request(
        f"{cp}/v1/events", data=body, method="POST",
        headers={"content-type": "application/json", "Authorization": f"Bearer {tok}"})
    try:
        urllib.request.urlopen(req, timeout=10).read()
    except (urllib.error.URLError, OSError) as e:
        print(f"{C_DIM}  (do ledgeru se nezapsalo: {e}){C_OFF}", flush=True)


# ═══════════════════════════════════════════════════════════════
#  Kolo agenta
# ═══════════════════════════════════════════════════════════════
def agent_turn(prompt: str, env: dict, deadline: float | None,
               ws: pathlib.Path = WORKSPACE) -> int:
    """
    Jedno kolo agenta neinteraktivně. `-a` dává důvěru projektu pro tenhle
    běh — jinak by Pi nenačetlo skills ani extension ze serveru.
    """
    pi = shutil.which("pi")
    if not pi:
        _say(f"{C_ERR}Pi v obrazu není{C_OFF}")
        return 127
    timeout = None
    if deadline:
        timeout = max(60, int(deadline - time.time()))

    cmd = [pi, "-a", "-p", prompt]
    if _LOG and shutil.which("bash") and shutil.which("tee"):
        _log(f"\n--- kolo agenta ({time.strftime('%H:%M:%SZ', time.gmtime())})\n"
             f"--- prompt:\n{prompt}\n--- výstup:")
        # Výstup má jít na obrazovku i do souboru zároveň, proto tee.
        # `-o pipefail`, aby se vrátil návratový kód Pi a ne kód tee —
        # bez toho by selhané kolo vypadalo jako úspěšné.
        # Prompt jde proměnnou prostředí: má víc řádků a uvozovky, na
        # příkazové řádce by se rozsypal.
        env = {**env, "AGENTICDEV_PROMPT": prompt}
        cmd = ["bash", "-o", "pipefail", "-c",
               '"$0" -a -p "$AGENTICDEV_PROMPT" 2>&1 | tee -a "$AGENTICDEV_TRANSCRIPT"',
               pi]
    try:
        p = subprocess.run(cmd, cwd=str(ws), env=env, timeout=timeout)
        return p.returncode
    except subprocess.TimeoutExpired:
        _say(f"{C_WARN}vypršel lease uprostřed kola{C_OFF}")
        return 124


PLAN = """Přečti .agenticdev/tasks.md a kontext v prd/. Napiš do
.agenticdev/plan.md krátký plán: co změníš, které soubory, jak to otestuješ.
Nic jiného teď needituj."""

IMPLEMENT = """Udělej úkol podle .agenticdev/plan.md. Nejdřív test, který
selže, pak kód, který ho rozsvítí. Drž se cest, do kterých smíš zapisovat
(.agenticdev/scope). Až budeš hotový, skonči."""

FIX = """Kontroly projektu selhaly. Tohle vypsaly:

{report}

Sprav to. Neupravuj testy tak, aby jen prošly — pokud je špatný test, řekni
to a vysvětli proč."""


# ═══════════════════════════════════════════════════════════════
#  Automat
# ═══════════════════════════════════════════════════════════════
def drive(policy: dict, env: dict, ws: pathlib.Path = WORKSPACE) -> str:
    """
    Vrátí výsledek: 'done', 'blocked' nebo 'aborted'. Zapisuje ho i do
    .agenticdev/outcome, aby ho launcher našel a předal control plane.
    """
    limits = policy.get("max_loop_iterations") or {}
    max_fix = int(limits.get("implement_test", 5))
    gates = policy.get("human_gate") or []
    deadline = policy.get("deadline_ts")
    checks = detect_checks(ws)

    _say(f"kontroly: {', '.join(n for n, _ in checks) if checks else 'žádné (projekt je nemá)'}")
    _say(f"strop opakování: {max_fix}")
    if gates:
        _say(f"bez člověka neprojde: {', '.join(gates)}")

    total = 3
    outcome = "blocked"

    # ── 1. plán ──
    _step(1, total, "Plán")
    emit(policy, "phase_started", {"phase": "plan", "n": 0})
    if agent_turn(PLAN, env, deadline, ws) != 0:
        _say(f"{C_WARN}plán se nedokončil, jdu dál — kontroly stejně rozhodnou{C_OFF}")

    # ── 2. implementace a kontroly ──
    _step(2, total, "Implementace")
    emit(policy, "phase_started", {"phase": "implement", "n": 0})
    agent_turn(IMPLEMENT, env, deadline, ws)

    ok, report = run_checks(checks, ws)
    n = 0
    while not ok and n < max_fix:
        n += 1
        _say(f"{C_WARN}{report.splitlines()[0]}{C_OFF}")
        _say(f"oprava {n}/{max_fix}")
        emit(policy, "checks_failed", {"n": n, "report": report[:2000]})
        if agent_turn(FIX.format(report=report), env, deadline, ws) == 124:
            _say(f"{C_ERR}vypršel lease{C_OFF}")
            outcome = "aborted"
            break
        ok, report = run_checks(checks, ws)

    if outcome == "aborted":
        pass
    elif not ok:
        _say(f"{C_ERR}kontroly po {max_fix} pokusech pořád padají{C_OFF}")
        _say("úkol jde do blocked, přes selhané kontroly se nepokračuje")
        emit(policy, "blocked", {"reason": "checks_exhausted", "n": max_fix,
                                 "report": report[:2000]})
    else:
        _say(f"{C_OK}{report}{C_OFF}")
        emit(policy, "checks_passed", {"n": n})

        # ── 3. human gate ──
        _step(3, total, "Co musí vidět člověk")
        hits = gate_hits(changed_files(ws), gates)
        if hits:
            for gate, files in hits.items():
                _say(f"{C_WARN}{gate}{C_OFF}: {', '.join(files[:5])}")
            emit(policy, "human_gate", {"gates": sorted(hits), "n": 0})
            _say("")
            _say("Tohle nesmí projít bez tebe. Projdi diff a rozhodni.")
            outcome = "review"
        else:
            _say(f"{C_OK}nic, co by potřebovalo tvůj podpis{C_OFF}")
            outcome = "done"
            emit(policy, "checks_and_gate_ok", {"n": 0})

    try:
        (ws / ".agenticdev").mkdir(exist_ok=True)
        (ws / ".agenticdev" / "outcome").write_text(outcome + "\n")
    except OSError:
        pass

    print()
    color = C_OK if outcome in ("done", "review") else C_ERR
    _say(f"{color}výsledek: {outcome}{C_OFF}")
    _log(f"\n# konec {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} · "
         f"výsledek {outcome} · oprav {n}")
    return outcome
