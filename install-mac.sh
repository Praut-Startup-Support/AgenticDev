#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  AGENTICDEV — připojení Macu
#
#  Pody běží na VPS (ADR-0005), takže tady se nic těžkého neinstaluje:
#  Tailscale, jeden konfigurační soubor a ikona v /Applications. Žádný
#  Docker, žádný agent, žádné klíče k repozitářům.
#
#  Idempotentní. Můžeš pustit znovu, nic nerozbije.
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

B='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; O='\033[0m'
step(){ printf "\n${B}▸ %s${O}\n" "$*"; }
ok()  { printf "${G}  ✓${O} %s\n" "$*"; }
warn(){ printf "${Y}  !${O} %s\n" "$*"; }
die() { printf "${R}✗ %s${O}\n" "$*" >&2; exit 1; }

CP="${AGENTICDEV_CP:-__CONTROL_PLANE__}"
# tailscale = přihlášení dělá tailnet, klíč neřešíme
# domain    = obyčejné SSH, klíč se musí vygenerovat a nechat zapsat na VPS
CONNECT="${AGENTICDEV_CONNECT:-__CONNECT__}"
[[ "$CONNECT" == "__CONNECT__" ]] && CONNECT=tailscale
HOME_DIR="$HOME/.agenticdev"
APP="/Applications/AgenticDev.app"

clear
cat <<'BANNER'
  ┌────────────────────────────────┐
  │   P R A U T                    │
  │   připojení Macu               │
  └────────────────────────────────┘
BANNER

[[ "$(uname)" == "Darwin" ]] || die "Tenhle instalátor je pro macOS."
[[ $EUID -ne 0 ]] || die "Nespouštěj přes sudo — pusť to jako svůj uživatel."

# ═══ 1. Tailscale ══════════════════════════════════════════════
if [[ "$CONNECT" == "domain" ]]; then
  step "Připojení"
  ok "bez Tailscale — půjde se obyčejným SSH"
else
step "Tailscale"
TS=""
for c in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
         /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  [[ -x "$c" ]] && { TS="$c"; break; }
done
if [[ -z "$TS" ]]; then
  if command -v brew >/dev/null; then
    warn "instaluji Tailscale"
    brew install -q --cask tailscale >/dev/null 2>&1 || true
  else
    echo "     Nainstaluj Tailscale: https://tailscale.com/download/mac"
  fi
  for c in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
           /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [[ -x "$c" ]] && { TS="$c"; break; }
  done
fi
[[ -n "$TS" ]] || die "Tailscale se nenainstaloval."
open -a Tailscale 2>/dev/null || true
if ! "$TS" status >/dev/null 2>&1; then
  echo
  echo "  Přihlas se v Tailscale do stejné sítě jako VPS."
  echo "  Klíč máš z registrační stránky."
  echo
  read -r -p "  Až budeš připojený, zmáčkni Enter. " _ </dev/tty
fi
"$TS" status >/dev/null 2>&1 && ok "v tailnetu" || warn "tailnet zatím neběží"
fi

# ═══ 2. Kam se připojovat ══════════════════════════════════════
step "Kde je VPS"
VPS_HOST=$(sed -E 's|^https?://||; s|[:/].*$||' <<<"$CP")
[[ -n "$VPS_HOST" && "$VPS_HOST" != "__CONTROL_PLANE__" ]] \
  || die "Instalátor neví, kde je VPS. Vyžádej si nový z registrační stránky."
ok "$VPS_HOST"

# Login na VPS zakládá správce příkazem `agenticdev-ctl user add`, takže
# ho tenhle stroj nemá odkud zjistit — musí ho říct člověk.
LOGIN="${AGENTICDEV_LOGIN:-}"
if [[ -z "$LOGIN" ]]; then
  echo
  echo "  Tvoje přihlašovací jméno na VPS (dal ti ho správce):"
  read -r -p "  login: " LOGIN </dev/tty
fi
[[ -n "$LOGIN" ]] || die "Bez loginu se nepřihlásím."

mkdir -p "$HOME_DIR"; chmod 700 "$HOME_DIR"
cat > "$HOME_DIR/vps" <<CFG
AGENTICDEV_VPS=$VPS_HOST
AGENTICDEV_LOGIN=$LOGIN
CFG
ok "uloženo do $HOME_DIR/vps"

# ═══ 3. Ikona ══════════════════════════════════════════════════
step "Aplikace"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if curl -fsSL "$CP/agenticdev-app.tar.gz" -o "$TMP/app.tgz" 2>/dev/null; then
  rm -rf "$APP"
  tar xzf "$TMP/app.tgz" -C /Applications 2>/dev/null || die "Aplikaci se nepodařilo rozbalit."
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  ok "$APP"
else
  warn "aplikaci se nepodařilo stáhnout, půjde to jen z terminálu"
fi

# Ghostty je hezčí, ale není povinné — spouštěč si poradí i s Terminálem.
if [[ ! -d /Applications/Ghostty.app ]] && command -v brew >/dev/null; then
  brew install -q --cask ghostty >/dev/null 2>&1 || true
fi
if [[ -d /Applications/Ghostty.app ]]; then
  mkdir -p "$HOME/.config/ghostty"
  [[ -f "$HOME/.config/ghostty/config" ]] \
    || curl -fsSL "$CP/ghostty-config" -o "$HOME/.config/ghostty/config" 2>/dev/null || true
  ok "ghostty"
fi

# ═══ SSH klíč (jen bez Tailscale) ══════════════════════════════
# S Tailscale dělá autentizaci tailnet a klíč nikdo neřeší. Bez něj se
# přihlašuje obyčejným SSH, takže tenhle stroj potřebuje vlastní klíč a
# správce musí jeho veřejnou část zapsat na VPS.
if [[ "$CONNECT" == "domain" ]]; then
  step "SSH klíč"
  KEYF="$HOME/.ssh/id_ed25519_agenticdev"
  if [[ ! -f "$KEYF" ]]; then
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -q -t ed25519 -N '' -C "agenticdev-$(hostname -s 2>/dev/null || hostname)" -f "$KEYF"
    ok "vytvořen $KEYF"
  else
    ok "už existuje: $KEYF"
  fi
  # Klíč se v konfiguraci připíše k hostu, ať se nemusí psát -i.
  if [[ -n "$VPS_HOST" ]] && ! grep -q "id_ed25519_agenticdev" "$HOME/.ssh/config" 2>/dev/null; then
    printf '\nHost %s\n  User %s\n  IdentityFile %s\n' "$VPS_HOST" "$LOGIN" "$KEYF" \
      >>"$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"
    ok "zapsáno do ~/.ssh/config"
  fi
  echo
  printf "  ${Y}Pošli tenhle řádek správci${O} — bez něj se nepřihlásíš:\n\n"
  printf "    %s\n\n" "$(cat "$KEYF.pub")"
  printf "  ${D}Správce ho zapíše: sudo agenticdev-ctl keys add %s \"<ten řádek>\"${O}\n" "$LOGIN"
fi

# ═══ 4. Zkouška ════════════════════════════════════════════════
step "Zkouška"
if curl -fsS --max-time 8 "$CP/v1/health" >/dev/null 2>&1; then
  ok "VPS odpovídá"
else
  if [[ "$CONNECT" == "domain" ]]; then
    warn "VPS neodpovídá — zkontroluj adresu $CP a síť"
  else
    warn "VPS neodpovídá — zkontroluj Tailscale"
  fi
fi

cat <<EOF

  ${G}Hotovo.${O}

  Klikni na ${B}AgenticDev${O} v Aplikacích, nebo z terminálu:

      ${Y}$(if [[ "$CONNECT" == "domain" ]]; then echo "ssh $LOGIN@$VPS_HOST"; else echo "tailscale ssh $LOGIN@$VPS_HOST"; fi)${O}
      ${Y}agenticdev${O}

  ${D}Poprvé se v Pi přihlas k modelu přes /login. Pak už to platí.${O}

EOF
