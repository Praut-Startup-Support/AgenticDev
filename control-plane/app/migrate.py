"""
Migrace schématu.

Init skripty Postgresu (`vps/sql/*.sql`) běží JEN nad prázdnou databází.
U instalace, která už jednou naběhla, se nikdy nespustí — takže cokoli,
co se ve schématu opraví, musí umět dojet i sem.

Každý krok je idempotentní a spouští se při startu control plane. Když
selže, řekne to nahlas do logu a aplikaci nezhasne: nabíhající kontejner
v restart-loopu je horší než jedna nedojetá migrace.
"""
from __future__ import annotations

from .main import db

# (jméno, SQL). Jméno se jen loguje, stav se nikde nedrží — všechny kroky
# jsou napsané tak, že opakované spuštění nic nezmění.
STEPS: list[tuple[str, str]] = [
    (
        "setting — tabulka nastavení měnitelného z panelu",
        """
        CREATE TABLE IF NOT EXISTS setting (
            key        TEXT PRIMARY KEY,
            value      TEXT NOT NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_by TEXT
        )
        """,
    ),
    (
        "enrollment — kdo se přihlásil a čeká na účet",
        # Pody běží na VPS (ADR-0005), takže účet zakládá root příkazem
        # `agenticdev-ctl user add`. Control plane na to nemá právo ani ho
        # mít nemá, proto si jen zapíše, kdo se ohlásil, a správce to vidí.
        """
        CREATE TABLE IF NOT EXISTS enrollment (
            id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            first_name TEXT NOT NULL,
            last_name  TEXT NOT NULL,
            email      TEXT NOT NULL,
            os         TEXT,
            ip         TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            claimed_at TIMESTAMPTZ,
            claimed_by TEXT
        )
        """,
    ),
    (
        "event — append-only přes trigger místo pravidla",
        # Pravidlo na UPDATE blokovalo `INSERT ... ON CONFLICT` na event,
        # a tím KAŽDÝ zápis do auditní stopy. Instalace vydané předtím
        # mají pravidla v sobě, takže je tady odstraníme a nahradíme
        # triggerem, který stejnou věc vynutí a nerozbije idempotenci.
        """
        DO $$
        BEGIN
          DROP RULE IF EXISTS event_no_update ON event;
          DROP RULE IF EXISTS event_no_delete ON event;

          CREATE OR REPLACE FUNCTION event_append_only() RETURNS trigger AS $fn$
          BEGIN
            RAISE EXCEPTION 'event je append-only, % není povolený', TG_OP
              USING HINT = 'Auditní stopa se nepřepisuje. Zapiš opravný záznam.';
          END $fn$ LANGUAGE plpgsql;

          IF NOT EXISTS (SELECT 1 FROM pg_trigger
                          WHERE tgname = 'event_no_change'
                            AND tgrelid = 'event'::regclass) THEN
            CREATE TRIGGER event_no_change BEFORE UPDATE OR DELETE ON event
              FOR EACH ROW EXECUTE FUNCTION event_append_only();
          END IF;

          IF NOT EXISTS (SELECT 1 FROM pg_trigger
                          WHERE tgname = 'event_no_truncate'
                            AND tgrelid = 'event'::regclass) THEN
            CREATE TRIGGER event_no_truncate BEFORE TRUNCATE ON event
              FOR EACH STATEMENT EXECUTE FUNCTION event_append_only();
          END IF;
        END $$
        """,
    ),
    (
        "workstation.ssh_public_key — klíč, kterým se člověk přihlásí na VPS",
        # V režimu domain (bez Tailscale) dělá autentizaci obyčejné SSH, ne
        # tailnet. Veřejný klíč z registrace se proto musí uschovat, aby ho
        # `agenticdev-ctl keys sync` mohl zapsat do authorized_keys toho
        # člověka. Control plane to sám nedělá a nemá — je v kontejneru a
        # do /home nedosáhne, což je záměr.
        """
        ALTER TABLE workstation ADD COLUMN IF NOT EXISTS ssh_public_key TEXT
        """,
    ),
    (
        "workstation.key_installed_at — kdy se klíč dostal do authorized_keys",
        """
        ALTER TABLE workstation ADD COLUMN IF NOT EXISTS key_installed_at TIMESTAMPTZ
        """,
    ),
    (
        "workstation.login — pod jakým účtem na VPS ten člověk pracuje",
        """
        ALTER TABLE workstation ADD COLUMN IF NOT EXISTS login TEXT
        """,
    ),
]


def run() -> list[str]:
    """Projede všechny kroky. Vrátí popisy těch, které selhaly."""
    failed: list[str] = []
    for name, sql in STEPS:
        try:
            with db() as c:
                c.execute(sql)
            print(f"[migrace] {name} ✓")
        except Exception as e:                        # noqa: BLE001
            failed.append(name)
            print(f"[migrace] {name} ✗ {e}")
    return failed
