#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  AgenticDev — generátor instalátoru Macu
#
#  Vyrobí JEDEN soubor svázaný S TOUTO instancí VPS:
#     /srv/agenticdev/out/agenticdev-install-mac.sh
#
#  Vazba = dvě věci zapečené do souboru při generování:
#     1. adresa control plane (doména + tailnet fallback)
#     2. fingerprint identity instance (ověří se proti /v1/identity)
#
#  Join token v souboru NENÍ. Účty na VPS zakládá `agenticdev-ctl user add`
#  (ADR-0005), takže klient se u control plane neregistruje a tenhle
#  soubor není tajemství — může se posílat po Slacku.
#
#  Když ten soubor pustíš proti jiné instanci, odmítne se nainstalovat.
#
#  Spouštění:  sudo agenticdev-mac-installer        (kdykoliv, idempotentní)
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

ENVF="${AGENTICDEV_ENV:-/srv/agenticdev/config/.env}"
SRC="${AGENTICDEV_SRC:-/srv/agenticdev/src}"
OUT="${AGENTICDEV_OUT:-/srv/agenticdev/out}"
BODY="$SRC/install-mac.sh"

[[ -r "$ENVF" ]] || { echo "✗ nenašel jsem $ENVF" >&2; exit 1; }
[[ -r "$BODY" ]] || { echo "✗ nenašel jsem $BODY" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENVF"; set +a

: "${AGENTICDEV_INSTANCE_ID:?v .env chybí AGENTICDEV_INSTANCE_ID}"
: "${WO_VERIFY_KEY_B64:?v .env chybí WO_VERIFY_KEY_B64}"
: "${VPS_HOST:?v .env chybí VPS_HOST}"

CP_FALLBACK="http://${VPS_HOST}:8080"
if [[ "${AGENTICDEV_MODE:-tailnet}" == "public" && -n "${AGENTICDEV_DOMAIN:-}" ]]; then
  CP_PRIMARY="https://${AGENTICDEV_DOMAIN}"
else
  CP_PRIMARY="$CP_FALLBACK"
fi

# fingerprint identity — musí souhlasit s tím, co počítá /v1/identity
IDENT="sha256:$(printf '%s\n%s' "$AGENTICDEV_INSTANCE_ID" "$WO_VERIFY_KEY_B64" \
                | sha256sum | cut -d' ' -f1)"

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
install -d -m 0750 "$OUT"
TARGET="$OUT/agenticdev-install-mac.sh"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# ─── 1. hlavička s vazbou (proměnné se dosazují) ────────────────
cat >"$TMP" <<EOF
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  AGENTICDEV — instalátor Macu
#
#  Vygenerováno: $STAMP
#  Instance:     $AGENTICDEV_INSTANCE_ID
#  Control plane: $CP_PRIMARY
#
#  Tenhle soubor patří k JEDNÉ konkrétní instanci AgenticDev. Proti jiné
#  se odmítne nainstalovat. Tajemství v sobě nemá.
#
#  Použití na Macu:   bash agenticdev-install-mac.sh
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

AGENTICDEV_INSTANCE="$AGENTICDEV_INSTANCE_ID"
AGENTICDEV_CP_PRIMARY="$CP_PRIMARY"
AGENTICDEV_CP_FALLBACK="$CP_FALLBACK"
AGENTICDEV_IDENTITY="$IDENT"
AGENTICDEV_GIT_HOST="$VPS_HOST"
AGENTICDEV_GIT_PORT="2222"
AGENTICDEV_GENERATED="$STAMP"
# Režim připojení se zapéká sem: instalátor patří k jedné instanci, a ta
# je buď na tailnetu, nebo na doméně. Bez toho by na Macu sháněl tailnet,
# který u domain instalace neexistuje.
AGENTICDEV_CONNECT_MODE="${AGENTICDEV_CONNECT:-tailscale}"
AGENTICDEV_BODY_B64="$(base64 -w0 <"$BODY")"
EOF

# ─── 2. statická logika (bez dosazování) ───────────────────────
cat >>"$TMP" <<'OUTER'

B='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; O='\033[0m'
step(){ printf "\n${B}▸ %s${O}\n" "$*"; }
ok()  { printf "${G}  ✓${O} %s\n" "$*"; }
warn(){ printf "${Y}  !${O} %s\n" "$*"; }
die() { printf "\n${R}✗ %s${O}\n" "$*" >&2; exit 1; }

cat <<BANNER
  ┌────────────────────────────────────────┐
  │   P R A U T   —   připojení Macu       │
  └────────────────────────────────────────┘
BANNER
printf "  ${D}instance %s · vygenerováno %s${O}\n" \
  "${AGENTICDEV_INSTANCE:0:8}" "$AGENTICDEV_GENERATED"

[[ "$(uname)" == "Darwin" ]] || die "Tenhle instalátor je pro macOS."
[[ $EUID -ne 0 ]] || die "Nespouštěj přes sudo — pusť to jako svůj uživatel."
for t in curl shasum; do command -v "$t" >/dev/null || die "chybí $t"; done

# ═══ 1. Najdi VPS ══════════════════════════════════════════════
step "Hledám VPS"
CP=""
probe() { curl -fsS --max-time 8 "$1/v1/identity" 2>/dev/null; }
IDENT_JSON=""
for cand in "$AGENTICDEV_CP_PRIMARY" "$AGENTICDEV_CP_FALLBACK"; do
  [[ -n "$cand" ]] || continue
  if IDENT_JSON="$(probe "$cand")"; then CP="$cand"; break; fi
done

if [[ -z "$CP" ]]; then
  warn "VPS není vidět — pravděpodobně chybí Tailscale."
  if [[ ! -d /Applications/Tailscale.app ]] && ! command -v tailscale >/dev/null; then
    if command -v brew >/dev/null; then
      warn "instaluji Tailscale"
      brew install -q --cask tailscale >/dev/null 2>&1 || true
    else
      echo "     Nainstaluj Tailscale: https://tailscale.com/download/mac"
    fi
  fi
  open -a Tailscale 2>/dev/null || true
  echo
  echo "     Přihlas se v Tailscale do stejné sítě jako VPS a zmáčkni Enter."
  read -r </dev/tty
  for cand in "$AGENTICDEV_CP_PRIMARY" "$AGENTICDEV_CP_FALLBACK"; do
    if IDENT_JSON="$(probe "$cand")"; then CP="$cand"; break; fi
  done
fi
[[ -n "$CP" ]] || die "VPS pořád nedostupný ($AGENTICDEV_CP_PRIMARY, $AGENTICDEV_CP_FALLBACK).
   Zkontroluj: tailscale status"
ok "$CP"

# ═══ 2. Ověř, že je to TEN VPS ═════════════════════════════════
step "Ověřuji identitu VPS"
got_fp=$(sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$IDENT_JSON")
got_id=$(sed -n 's/.*"instance_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$IDENT_JSON")
[[ -n "$got_fp" ]] || die "VPS neodpověděl identitou. Starší verze control plane?"
if [[ "$got_fp" != "$AGENTICDEV_IDENTITY" ]]; then
  die "TOHLE JE JINÝ VPS.
   instalátor patří k: ${AGENTICDEV_INSTANCE}
   odpovídá:           ${got_id:-?}
   Nic jsem neměnil. Vyžádej si instalátor z toho správného VPS."
fi
ok "instance ${got_id:0:8} — souhlasí"

# ═══ 3. Vlastní instalace ══════════════════════════════════════
BODY="$(mktemp "${TMPDIR:-/tmp}/agenticdev-install-mac.XXXXXX")"
trap 'rm -f "$BODY"' EXIT
base64 --decode <<<"$AGENTICDEV_BODY_B64" >"$BODY"
export AGENTICDEV_CP="$CP"
export AGENTICDEV_INSTANCE_ID="$AGENTICDEV_INSTANCE"
export AGENTICDEV_CONNECT="$AGENTICDEV_CONNECT_MODE"
bash "$BODY"
OUTER

install -m 0644 "$TMP" "$TARGET"
( cd "$OUT" && sha256sum "$(basename "$TARGET")" > "$(basename "$TARGET").sha256" )
bash -n "$TARGET" || { echo "✗ vygenerovaný soubor má syntaktickou chybu" >&2; exit 1; }

echo "$TARGET"
