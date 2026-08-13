"""
Nastavení platformy.

Konfigurace žije na dvou místech a je důležité vědět proč:

  .env na serveru   věci, které se čtou při startu kontejneru a jejich
                    změna vyžaduje restart — hesla k databázi, podpisový
                    klíč, doména. Tyhle panel jen ukazuje, needituje.

  databáze          věci, které se čtou při každém požadavku — model,
                    allowlist, hesla do panelu a registrace, SMTP.
                    Tyhle jdou měnit za běhu a platí okamžitě.

Kdyby měl control-plane přepisovat .env a restartovat kontejnery,
potřeboval by přístup k Docker socketu. To je zbytečné riziko pro něco,
co jde vyřešit tabulkou.
"""
from __future__ import annotations

import os
import threading
import time

from .main import db, now

# ═══════════════════════════════════════════════════════════════
#  Co panel smí měnit
# ═══════════════════════════════════════════════════════════════
# key: (skupina, popisek, typ, tajné?, nápověda)
EDITABLE: dict[str, tuple[str, str, str, bool, str]] = {
    # ─── modely ───────────────────────────────────────────────
    "MODEL_BACKEND":    ("modely", "Dodavatel", "select:openai,anthropic,ollama", False,
                         "Určuje tvar API. Po změně zkontroluj adresu i model."),
    "MODEL_BASE_URL":   ("modely", "Adresa API", "text", False,
                         "Např. https://api.openai.com/v1"),
    "MODEL_API_KEY":    ("modely", "API klíč", "text", True,
                         "U Ollamy nech prázdné."),
    "DEFAULT_MODEL":    ("modely", "Výchozí model", "text", False,
                         "Použije se pro projekty bez vlastního nastavení."),
    "LOCAL_MODEL":      ("modely", "Lokální model", "text", False,
                         "Pro projekty označené data_class: restricted."),
    "MODEL_MAX_TOKENS": ("modely", "Strop tokenů", "number", False,
                         "Překročení je tvrdý fail, ne tiché ořezání."),

    # ─── síť ──────────────────────────────────────────────────
    "EGRESS_ALLOWLIST": ("sit", "Povolené domény", "textarea", False,
                         "Čárkou oddělené. Pod se jinam nedostane."),

    # ─── brána před mergem ────────────────────────────────────
    "MERGE_GATE_CONTEXTS":  ("brana", "Požadované statusy", "text", False,
                             "Čárkou oddělené vzory glob. Forgejo statusy jmenuje "
                             "„workflow / job (událost)\", proto výchozí „test / *\". "
                             "Skutečný tvar ukáže: agenticdev-ctl gate <projekt>."),
    "MERGE_GATE_APPROVALS": ("brana", "Kolik lidí musí PR odkliknout", "number", False,
                             "Nula = kód se smerguje, aniž ho někdo přečetl. "
                             "Když autoři nejsou programátoři, dej aspoň 1."),

    # ─── přístup ──────────────────────────────────────────────
    "DASHBOARD_TOKEN":  ("pristup", "Heslo do panelu", "password", True,
                         "Změna odhlásí ostatní relace až po vypršení."),
    "ENROLL_PASSWORD":  ("pristup", "Heslo pro připojení strojů", "password", True,
                         "Tohle dáváš lidem. Po změně přestanou platit staré odkazy."),
    "LEASE_HOURS":      ("pristup", "Platnost lease (h)", "number", False,
                         "Po vypršení se úkol vrátí do fronty."),

    # ─── tailscale ────────────────────────────────────────────
    "TS_API_KEY":       ("tailscale", "API klíč", "text", True,
                         "S ním dostane každý stroj jednorázový klíč místo sdíleného."),
    "TS_TAILNET":       ("tailscale", "Tailnet", "text", False,
                         "Pomlčka = výchozí tailnet účtu."),
    "TS_AUTHKEY":       ("tailscale", "Sdílený auth key", "text", True,
                         "Záloha, když není API klíč. Vyprší nejpozději za 90 dní."),

    # ─── pošta ────────────────────────────────────────────────
    "SMTP_HOST":        ("posta", "Server", "text", False, ""),
    "SMTP_PORT":        ("posta", "Port", "number", False, ""),
    "SMTP_USER":        ("posta", "Uživatel", "text", False, ""),
    "SMTP_PASSWORD":    ("posta", "Heslo", "password", True, ""),
    "SMTP_FROM":        ("posta", "Odesílatel", "text", False, ""),
}

# Jen ke čtení — mění se v .env a potřebují restart.
READONLY = [
    "AGENTICDEV_INSTANCE_ID", "AGENTICDEV_DOMAIN", "AGENTICDEV_MODE", "VPS_HOST",
    "CONTROL_PLANE_URL", "JOIN_URL", "FORGEJO_URL", "HARNESS_IMAGE",
]

GROUPS = {
    "modely":    "Modely",
    "sit":       "Síť",
    "brana":     "Brána před mergem",
    "pristup":   "Přístup",
    "tailscale": "Tailscale",
    "posta":     "Pošta",
}

_MASK = "••••••••"

# ═══════════════════════════════════════════════════════════════
#  Úložiště
# ═══════════════════════════════════════════════════════════════
_cache: dict[str, str] = {}
_cache_at = 0.0
_TTL = 5.0
_lock = threading.Lock()


def _load() -> dict[str, str]:
    global _cache, _cache_at
    with _lock:
        if time.time() - _cache_at < _TTL:
            return _cache
        try:
            with db() as c:
                rows = c.execute("SELECT key, value FROM setting").fetchall()
            _cache = {r["key"]: r["value"] for r in rows}
            _cache_at = time.time()
        except Exception:
            # Databáze může být krátce nedostupná. Radši vrátíme poslední
            # známý stav než abychom shodili požadavek.
            pass
        return _cache


def get(key: str, default: str = "") -> str:
    """Databáze má přednost, pak prostředí, pak default."""
    v = _load().get(key)
    if v is not None and v != "":
        return v
    return os.environ.get(key, default)


def get_int(key: str, default: int) -> int:
    try:
        return int(get(key, str(default)))
    except ValueError:
        return default


def set_many(values: dict[str, str], by: str = "panel") -> list[str]:
    """Zapíše jen známé klíče. Vrátí ty, které opravdu změnil."""
    changed = []
    with db() as c:
        for k, v in values.items():
            if k not in EDITABLE:
                continue
            if v == _MASK:          # tajemství uživatel nesahal
                continue
            c.execute("""
                INSERT INTO setting (key, value, updated_by)
                VALUES (%s, %s, %s)
                ON CONFLICT (key) DO UPDATE
                  SET value = EXCLUDED.value,
                      updated_at = now(),
                      updated_by = EXCLUDED.updated_by
            """, (k, v, by))
            changed.append(k)
    global _cache_at
    _cache_at = 0.0                 # ať se to projeví hned
    return changed


def as_form() -> dict:
    """Podklad pro panel. Tajemství maskovaná, ne prázdná — ať je vidět,
    že hodnota existuje."""
    cur = _load()
    fields = []
    for key, (group, label, kind, secret, hint) in EDITABLE.items():
        raw = cur.get(key) or os.environ.get(key, "")
        fields.append({
            "key": key, "group": group, "label": label, "kind": kind,
            "secret": secret, "hint": hint,
            "value": (_MASK if raw else "") if secret else raw,
            "from_db": key in cur,
        })
    return {
        "groups": GROUPS,
        "fields": fields,
        "readonly": {k: os.environ.get(k, "") for k in READONLY},
    }
