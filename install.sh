#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  AgenticDev — jeden příkaz, který postaví celou instanci
#
#  Stáhne vydaný instalátor, OVĚŘÍ ho, a teprve pak spustí. Sám nic
#  neinstaluje a nic nemění — je to jen ověřená cesta k tomu druhému.
#
#  Použití na čerstvém VPS (jako root):
#
#      bash <(curl -fsSL https://raw.githubusercontent.com/\
#Praut-Startup-Support/AgenticDev/main/install.sh)
#
#  Bezpečnější varianta, když nechceš spouštět nic z roury — stáhni si
#  tenhle soubor, přečti ho, a pusť:
#
#      curl -fLO https://raw.githubusercontent.com/Praut-Startup-Support/AgenticDev/main/install.sh
#      less install.sh && bash install.sh
#
#  Co se ověřuje, než se cokoli spustí:
#    1) sha256 proti souboru .sha256 z téhož vydání
#    2) podpis cosign proti identitě tohohle repozitáře (když je cosign)
#
#  Poznámka k té rouře: kdo by ovládal server s tímhle skriptem, ovládá i
#  ten artefakt, takže ověření podpisu proti PODVRŽENÉMU SERVERU nechrání.
#  Chrání proti podvrženému artefaktu u správného serveru a proti
#  poškozenému přenosu. Kdo chce víc, použije druhou variantu výše.
#
#  Flagy:
#    --tag vX.Y.Z   konkrétní vydání (default: latest)
#    --check        jen stáhni a ověř, nic nespouštěj
#    --             všechno za tímhle se předá instalátoru
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO="${AGENTICDEV_REPO:-Praut-Startup-Support/AgenticDev}"
ART="agenticdev-install-vps.sh"

B='\033[1;36m'; G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; D='\033[2m'; O='\033[0m'
step(){ printf "\n${B}▸ %s${O}\n" "$*"; }
ok()  { printf "${G}  ✓${O} %s\n" "$*"; }
warn(){ printf "${Y}  !${O} %s\n" "$*"; }
die() { printf "\n${R}✗ %s${O}\n\n" "$*" >&2; exit 1; }

TAG="latest"; CHECK=0; PASS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)   TAG="${2:?--tag chce verzi, např. v0.2.0}"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --)      shift; PASS=("$@"); break ;;
    -h|--help) sed -n '2,32p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)       die "neznámý přepínač: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Tohle musí root. Zkus: sudo bash $0"

# ─── 1. Co vůbec potřebujeme ke stažení ───────────────────────────────
step "Kontrola prostředí"
command -v curl >/dev/null || die "curl chybí. Doinstaluj: apt-get install -y curl"
command -v sha256sum >/dev/null || die "sha256sum chybí (balík coreutils)"
. /etc/os-release 2>/dev/null || true
case "${ID:-}${VERSION_ID:-}" in
  debian12|ubuntu22.04|ubuntu24.04) ok "${PRETTY_NAME:-$ID $VERSION_ID}" ;;
  *) warn "netestovaný systém: ${PRETTY_NAME:-neznámý}"
     warn "podporované je Debian 12 nebo Ubuntu 22.04/24.04 — pokračuju, ale bez záruky" ;;
esac

# ─── 2. Stažení ───────────────────────────────────────────────────────
step "Stahuji instalátor"
if [[ "$TAG" == "latest" ]]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  BASE="https://github.com/$REPO/releases/download/$TAG"
fi

WORK=$(mktemp -d /root/agenticdev-boot.XXXXXX)
# Po neúspěchu po sobě uklidíme, ať v /root nezůstává hromada prázdných
# adresářů po opakovaných pokusech. Při úspěchu se dělá `exec`, který
# proces nahradí — trap se nespustí a stažený artefakt zůstane k ruce.
trap 'rc=$?; (( rc != 0 )) && rm -rf "$WORK"; exit $rc' EXIT
cd "$WORK"
curl -fLsS -o "$ART" "$BASE/$ART" \
  || die "Instalátor se nestáhl z $BASE/$ART
     Zkontroluj, že vydání existuje: https://github.com/$REPO/releases"
curl -fLsS -o "$ART.sha256" "$BASE/$ART.sha256" \
  || die "Součet se nestáhl — bez něj se nedá ověřit, co jsem stáhl. Nespouštím."
ok "$ART ($(wc -c <"$ART") B)"

# ─── 3. Ověření ───────────────────────────────────────────────────────
step "Ověřuji"
sha256sum -c "$ART.sha256" >/dev/null 2>&1 \
  || die "SHA256 NESOUHLASÍ. Stažený soubor není ten vydaný — nespouštím ho.
     Zkus to znovu; když to trvá, ozvi se, než cokoli pustíš."
ok "sha256 $(cut -c1-16 <"$ART.sha256")…"

# Podpis je keyless přes Sigstore a je vázaný na tenhle repozitář a jeho
# workflow. Když cosign není, řekneme to nahlas — checksum sám o sobě
# ověřuje jen to, že přenos nic nezkomolil, ne KDO to vydal.
if command -v cosign >/dev/null; then
  if curl -fLsS -o "$ART.sig" "$BASE/$ART.sig" \
     && curl -fLsS -o "$ART.pem" "$BASE/$ART.pem"; then
    if cosign verify-blob \
         --certificate "$ART.pem" --signature "$ART.sig" \
         --certificate-identity-regexp "^https://github.com/$REPO/" \
         --certificate-oidc-issuer https://token.actions.githubusercontent.com \
         "$ART" >/dev/null 2>&1; then
      ok "podpis cosign souhlasí — vydal to $REPO"
    else
      die "PODPIS NESOUHLASÍ. Nespouštím to. Tohle nevydal $REPO."
    fi
  else
    warn "podpis k tomuhle vydání není ke stažení — ověřen jen checksum"
  fi
else
  warn "cosign není nainstalovaný, ověřen jen checksum"
  printf "  ${D}kdo chce i podpis: https://docs.sigstore.dev/cosign/installation${O}\n"
fi

# Instalátor umí ověřit sám sebe (rozbalitelnost payloadu). Pustíme to
# dřív, než začne cokoli měnit na stroji.
bash "$ART" --check >/dev/null 2>&1 && ok "instalátor prošel vlastní kontrolou" \
  || die "Instalátor neprošel vlastní kontrolou (--check). Nespouštím ho."

if (( CHECK )); then
  printf "\n  ${G}Ověřeno. Nic jsem nespustil.${O}\n"
  printf "  Soubor: %s/%s\n\n" "$WORK" "$ART"
  exit 0
fi

# ─── 4. Instalace ─────────────────────────────────────────────────────
# Odsud dál to vede vydaný instalátor. Ptá se na doménu, na jméno a e-mail
# správce, na dvě hesla a na dodavatele modelů; na konci vypíše dva odkazy.
step "Spouštím instalaci"
printf "  ${D}%s${O}\n" "$WORK/$ART"
exec bash "$ART" "${PASS[@]+"${PASS[@]}"}"
