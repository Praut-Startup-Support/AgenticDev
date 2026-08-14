#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  AGENTICDEV PLATFORM — instalátor VPS
#
#  Jeden soubor. Nese v sobě celý repozitář platformy.
#
#      scp agenticdev-install-vps.sh root@<vps>:/root/
#      ssh -t root@<vps> 'bash /root/agenticdev-install-vps.sh'
#
#  Po dokončení najdeš v /srv/agenticdev/out/ druhý instalátor —
#  agenticdev-install-mac.sh — svázaný právě s tímhle VPS.
#
#  Idempotentní: pusť znovu, nic nerozbije, tajemství zachová.
#
#  Přepínače:
#      --check     jen rozbalí a zkontroluje, systému se nedotkne
#      --yes       neinteraktivně (bere hodnoty z prostředí / .env)
#      --mac-only  jen přegeneruje instalátor Macu
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

BLU='\033[1;36m'; GRN='\033[1;32m'; YLW='\033[1;33m'; RED='\033[1;31m'
DIM='\033[2m'; OFF='\033[0m'
step() { printf "\n${BLU}▸ %s${OFF}\n" "$*"; }
ok()   { printf "${GRN}  ✓${OFF} %s\n" "$*"; }
warn() { printf "${YLW}  !${OFF} %s\n" "$*"; }
info() { printf "${DIM}    %s${OFF}\n" "$*"; }
die()  { printf "\n${RED}✗ %s${OFF}\n" "$*" >&2; exit 1; }

SELF="${BASH_SOURCE[0]:-$0}"
ROOT=/srv/agenticdev
SRC=$ROOT/src
ENVF=$ROOT/config/.env
LOG=$ROOT/install.log
MARKER='#__AGENTICDEV_PAYLOAD_BELOW__'

MODE_CHECK=0; MODE_YES=0; MODE_MAC=0
for a in "$@"; do case "$a" in
  --check)    MODE_CHECK=1 ;;
  --yes|-y)   MODE_YES=1 ;;
  --mac-only) MODE_MAC=1 ;;
  -h|--help)  sed -n '2,26p' "$SELF"; exit 0 ;;
  *) die "neznámý přepínač: $a" ;;
esac; done

[[ -r "$SELF" ]] || die "Instalátor musí být SOUBOR na disku — přes 'curl | bash' se nerozbalí.
   Stáhni ho a spusť:  bash agenticdev-install-vps.sh"

# Otázky níž čtou z /dev/tty. Přes 'ssh host cmd' bez -t se na vzdálené
# straně nealoguje pseudoterminál, takže /dev/tty pro proces neexistuje —
# open() spadne na ENXIO ("No such device or address") na první otázce.
# Radši to řekneme rovnou, než ať to vypadá jako rozbitý instalátor.
if (( ! MODE_CHECK && ! MODE_YES )) && ! { true </dev/tty; } 2>/dev/null; then
  die "Bez terminálu se nedá odpovídat na otázky (chybí /dev/tty).
   Přes ssh spouštěj s -t, ať se terminál navážou:
     ssh -t root@<vps> 'bash /root/agenticdev-install-vps.sh'
   Nebo běž neinteraktivně:  bash $SELF --yes  (hodnoty vezme z prostředí/.env)"
fi

ask() {  # ask <proměnná> <otázka> <default>
  local __v=$1 __q=$2 __d=${3:-} __r
  if (( MODE_YES )); then printf -v "$__v" '%s' "${!__v:-$__d}"; return; fi
  if [[ -n "$__d" ]]; then read -rp "  $__q [$__d]: " __r </dev/tty
  else                     read -rp "  $__q: " __r </dev/tty; fi
  printf -v "$__v" '%s' "${__r:-$__d}"
}
asks() { # skryté zadání
  local __v=$1 __q=$2 __r
  if (( MODE_YES )); then printf -v "$__v" '%s' "${!__v:-}"; return; fi
  read -rsp "  $__q: " __r </dev/tty; echo
  printf -v "$__v" '%s' "$__r"
}
askpw() { # askpw <proměnná> <otázka> <min-délka>
  local __v=$1 __q=$2 __min=${3:-10} __a __b
  if (( MODE_YES )); then
    printf -v "$__v" '%s' "${!__v:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)}"
    return
  fi
  while :; do
    read -rsp "  $__q (doporučeno min $__min znaků): " __a </dev/tty; echo
    if [[ ${#__a} -lt $__min ]]; then
      read -rp "${YLW}    kratší, než se doporučuje — trvat na tom? [a/N] ${OFF}" __ok </dev/tty
      [[ "$__ok" =~ ^[aAyY]$ ]] || continue
    fi
    read -rsp "  ještě jednou: " __b </dev/tty; echo
    [[ "$__a" == "$__b" ]] && break
    printf "${YLW}    nesouhlasí — zkus znovu${OFF}\n"
  done
  printf -v "$__v" '%s' "$__a"
}

run() {  # run "popis" cmd...
  local msg="$1"; shift
  printf "  %s" "$msg"
  ( "$@" >>"$LOG" 2>&1 ) & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf "."; sleep 2; done
  if wait "$pid"; then printf " ${GRN}✓${OFF}\n"
  else printf " ${RED}✗${OFF}\n"; echo; tail -n 30 "$LOG"; die "$msg selhalo. Celý log: $LOG"; fi
}

clear 2>/dev/null || true
cat <<'BANNER'
  ┌──────────────────────────────────────────────────┐
  │   P R A U T   P L A T F O R M                    │
  │   instalace VPS                                  │
  └──────────────────────────────────────────────────┘
BANNER

# ═══════════════════════════════════════════════════════════════════════
#  0. Rozbalení vloženého repozitáře
# ═══════════════════════════════════════════════════════════════════════
step "Rozbaluji platformu"

PAY_LINE=$(grep -n "^${MARKER}\$" "$SELF" | head -1 | cut -d: -f1) \
  || die "v souboru chybí payload — je poškozený?"
[[ -n "$PAY_LINE" ]] || die "v souboru chybí payload — je poškozený?"

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
tail -n "+$((PAY_LINE + 1))" "$SELF" | base64 --decode | tar xz -C "$STAGE" \
  || die "payload se nepodařilo rozbalit"
[[ -f "$STAGE/vps/docker-compose.yml" ]] || die "payload je nekompletní"
ok "$(find "$STAGE" -type f | wc -l) souborů"

if (( MODE_CHECK )); then
  step "Kontrola (systému se nedotýkám)"
  ( cd "$STAGE" && bash tools/verify-tree.sh )
  bad=0; n=0
  while read -r f; do
    head -c 100 "$f" 2>/dev/null | grep -qE '^#!.*(bash|/sh)' || continue
    n=$((n+1))
    bash -n "$f" 2>/dev/null || { echo "  ✗ syntaxe: $f"; bad=1; }
  done < <(find "$STAGE" -type f)
  [[ $bad -eq 0 ]] && echo "  ✓ $n shellových skriptů se parsuje"
  python3 -c "import sys,ast;[ast.parse(open(f).read()) for f in sys.argv[1:]]" \
    "$STAGE"/control-plane/app/*.py 2>/dev/null && echo "  ✓ python se parsuje" || true
  [[ $bad -eq 0 ]] && printf "\n${GRN}✓ payload je v pořádku${OFF}\n" \
                   || die "payload má chyby"
  exit 0
fi

[[ $EUID -eq 0 ]] || die "Spusť jako root:  sudo bash $SELF"
[[ -f /etc/os-release ]] || die "neznámý systém"
# shellcheck disable=SC1091
. /etc/os-release
[[ "$ID" =~ ^(debian|ubuntu)$ ]] || die "podporuji Debian/Ubuntu, mám: $ID"

install -d -m 0750 $ROOT $ROOT/config $ROOT/data $ROOT/backup $ROOT/out
install -d -m 0750 $ROOT/data/{postgres,forgejo,minio,caddy,directors}
# Forgejo běží v kontejneru pod uid 1000. Bez tohohle nepřečte vlastní
# app.ini ("permission denied") a skončí v restart-loopu.
chown -R 1000:1000 $ROOT/data/forgejo
: >"$LOG"; chmod 600 "$LOG"

# zdroj: nahradíme jen soubory platformy, data a config zůstávají
install -d -m 0755 "$SRC"
if command -v rsync >/dev/null; then
  rsync -a --delete "$STAGE"/ "$SRC"/ >>"$LOG" 2>&1
else
  rm -rf "$SRC"; mkdir -p "$SRC"; cp -a "$STAGE"/. "$SRC"/
fi
chmod +x "$SRC"/*.sh "$SRC"/tools/*.sh "$SRC"/launcher/agenticdev \
         "$SRC"/vps/*.sh "$SRC"/vps/agenticdev-ctl "$SRC"/vps/backup/*.sh \
         "$SRC"/workspace/_base/bin/* 2>/dev/null || true
# Aby fungovalo i ruční `docker compose ...` bez --env-file. Bez toho
# spadne interpolace na "required variable ... is missing a value".
ln -sfn "$ENVF" "$SRC/vps/.env"
ok "zdroj v $SRC"

# ── jen přegenerovat instalátor Macu a skončit ────────────────────────
if (( MODE_MAC )); then
  [[ -r $ENVF ]] || die "platforma ještě není nainstalovaná"
  step "Generuji instalátor Macu"
  f=$(bash "$SRC/vps/mk-mac-installer.sh")
  ok "$f"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
#  1. Otázky
# ═══════════════════════════════════════════════════════════════════════
FRESH=1
if [[ -f $ENVF ]]; then
  FRESH=0
  step "Konfigurace už existuje — aktualizuji instalaci"
  # shellcheck disable=SC1090
  set -a; . $ENVF; set +a
  DOMAIN="${AGENTICDEV_DOMAIN:-}"; ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-}"
  ADMIN_USER="${FORGEJO_ADMIN_USER:-admin}"
  info "tajemství zůstávají, měnit je nebudu"
else
  step "Nastavení — pár otázek, pak už nic"
  echo
  info "Doménu nech prázdnou, jestli VPS nemá veřejné DNS."
  info "Platforma pak pojede jen po tailnetu."
  ask DOMAIN "Doména platformy (Enter = jen tailnet)" ""
  if [[ "$DOMAIN" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    # Let's Encrypt nevydá certifikát na holou IP adresu, ať už do compose
    # napíšeš cokoli — CA k tomu potřebuje jméno. sslip.io je veřejná DNS
    # služba zdarma: <ip>.sslip.io se přeloží zpátky přesně na <ip>, nic se
    # nekupuje ani neregistruje. Adresa, kterou jsi zadal, zůstává funkční
    # cesta k tomuhle VPS — jen dostane jméno, které certifikát unese.
    RAW_IP="$DOMAIN"; DOMAIN="$RAW_IP.sslip.io"
    warn "$RAW_IP je IP adresa — na tu certifikát nejde vydat"
    info "beru $DOMAIN — sslip.io ji jen přeloží zpátky na $RAW_IP, nic víc"
  fi
  # Kdo instaluje, se musí podepsat. Není to formalita: z tohohle jména
  # vzniká `principal`, a bez něj má auditní stopa u všeho, co se odklikne
  # v panelu, prázdného aktéra — tedy nevíš, kdo co schválil.
  ask ADMIN_NAME "Tvoje jméno a příjmení (správce instance)" ""
  [[ -n "$ADMIN_NAME" ]] || die "jméno je povinné — bez něj nebude v auditní stopě vidět, kdo instanci spravuje"
  [[ "$ADMIN_NAME" == *" "* ]] || warn "jen jedno slovo? V auditní stopě to bude takhle."
  ask ADMIN_EMAIL "Tvůj e-mail (správce instance)" ""
  [[ -n "$ADMIN_EMAIL" ]] || die "e-mail je povinný — Forgejo bez něj admina nezaloží"
  ask ADMIN_USER "Přihlašovací jméno do gitu" "admin"

  echo
  info "Dvě hesla. Vymysli si je teď, jinam se zapisovat nebudou."
  info "  ADMIN  — přihlášení do admin panelu (jen ty)"
  info "  JOIN   — dostane každý, kdo si má připojit stroj"
  askpw ADMIN_PW  "Heslo do admin panelu" 12
  askpw ENROLL_PW "Heslo pro připojení strojů" 10

  # Dodavatel modelů, API klíč, DEFAULT_MODEL i EGRESS_ALLOWLIST jsou
  # DB-backed nastavení (viz control-plane/app/settings.py EDITABLE) —
  # panel je mění za běhu, bez restartu. Ptát se na to teď, uprostřed
  # instalace, kdy člověk často nemá klíč po ruce, je zbytečná zábrana
  # navíc. Necháme rozumný výchozí stav a dotaz přesuneme tam, kde se dá
  # kdykoli beztrestně změnit: Nastavení → Modely v panelu.
  MODEL_BACKEND=openai; MODEL_BASE_URL=https://api.openai.com/v1
  DEFAULT_MODEL=gpt-5.5; MODEL_KEY=""

  ask SMTP_HOST "SMTP host (Enter = přeskočit maily)" ""
  if [[ -n "${SMTP_HOST:-}" ]]; then
    ask  SMTP_USER "SMTP uživatel" ""
    asks SMTP_PASS "SMTP heslo"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
#  2. Systém
# ═══════════════════════════════════════════════════════════════════════
step "Systémové balíčky"
export DEBIAN_FRONTEND=noninteractive
run "apt update              " apt-get update -qq
run "instalace nástrojů      " apt-get install -y -qq \
  ca-certificates curl gnupg git jq ufw fail2ban unattended-upgrades \
  restic openssl rsync python3 iproute2

step "Docker"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
    >/etc/apt/sources.list.d/docker.list
  run "apt update              " apt-get update -qq
  run "instalace Dockeru       " apt-get install -y -qq docker-ce docker-ce-cli \
    containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker >>"$LOG" 2>&1 || true
docker compose version >/dev/null 2>&1 || die "docker compose plugin chybí"
ok "$(docker --version | cut -d, -f1)"

# ═══════════════════════════════════════════════════════════════════════
#  3. Jak se k platformě dostanou lidi
#
#  Dvě cesty, a je to volba mezi bezpečností a nezávislostí:
#
#    tailscale  Vnitřní služby vidí jen tailnet, z internetu je vidět
#               přesně jedna cesta — registrační stránka přes Funnel.
#               Autentizaci SSH dělá tailnet, klíče nikdo neřeší.
#               Cena: každá instance potřebuje Tailscale účet a dvě
#               naklikané věci v cizí administraci (HTTPS certifikáty,
#               Funnel v policy).
#
#    domain     Žádná třetí strana. Caddy s Let's Encrypt na vlastní
#               doméně, vnitřní služby jen na 127.0.0.1, přihlášení
#               obyčejným SSH klíčem. Cena: z internetu je vidět i panel
#               a git, chráněné heslem.
#
#  Kdo tuhle platformu rozdává dál (jiná firma, jiný ajťák, jiný VPS),
#  chce `domain` — jinak musí každý zákazník zřídit Tailscale účet.
# ═══════════════════════════════════════════════════════════════════════
step "Připojení"
CONNECT="${AGENTICDEV_CONNECT:-}"
if [[ -z "$CONNECT" ]]; then
  if (( MODE_YES )); then
    # Bez odpovědi se řídíme tím, co je k dispozici: doména = domain.
    CONNECT=$([[ -n "${DOMAIN:-}" ]] && echo domain || echo tailscale)
  else
    echo
    info "  1) Tailscale  — nic z toho není z internetu vidět, kromě registrace."
    info "                  Potřebuje Tailscale účet pro tuhle instanci."
    info "  2) Doména     — bez třetí strany, TLS z Let's Encrypt."
    info "                  Z internetu je vidět i panel, chráněný heslem."
    [[ -n "${DOMAIN:-}" ]] || info "  ${DIM}Doménu jsi nezadal, takže 2) nejde vybrat.${OFF}"
    ask CONNECT_N "Volba" "$([[ -n "${DOMAIN:-}" ]] && echo 2 || echo 1)"
    CONNECT=$([[ "$CONNECT_N" == "2" ]] && echo domain || echo tailscale)
  fi
fi
if [[ "$CONNECT" == "domain" && -z "${DOMAIN:-}" ]]; then
  die "Režim domain potřebuje doménu. Pusť instalátor znovu a zadej ji, nebo vyber Tailscale."
fi
ok "režim: $CONNECT"

TS_IP=""
if [[ "$CONNECT" == "tailscale" ]]; then
  command -v tailscale >/dev/null || \
    run "instalace Tailscale     " bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'

  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -z "$TS_IP" ]]; then
    warn "VPS ještě není v tailnetu."
    TS_KEY="${TS_AUTHKEY:-}"
    if (( ! MODE_YES )); then
      echo
      info "Vlož auth key z https://login.tailscale.com/admin/settings/keys"
      info "nebo nech prázdné a přihlaš se interaktivně (vypíše se odkaz)."
      asks TS_KEY "Tailscale auth key (Enter = interaktivně)"
    fi
    if [[ -n "$TS_KEY" ]]; then
      tailscale up --ssh --authkey "$TS_KEY" >>"$LOG" 2>&1 || true
    else
      echo; printf "${DIM}    otevři odkaz, který se objeví, a potvrď stroj${OFF}\n"
      tailscale up --ssh || true
    fi
    TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$TS_IP" ]] || die "Tailscale se nepřipojil. Spusť 'tailscale up --ssh' a pusť instalátor znovu."
  ok "tailnet IP: $TS_IP"
else
  # Bez Tailscale se vnitřní služby publikují na loopback a z venku k nim
  # nevede nic než Caddy. Kdyby tu byla veřejná adresa, byl by na internetu
  # i Postgres — proto to není odvozené, ale nastavené natvrdo.
  TS_IP=127.0.0.1
  ok "vnitřní služby jen na 127.0.0.1, zvenčí přes Caddy"
  # Mount socketu tailscaled je v compose bezpodmínečně. Bez Tailscale ta
  # cesta neexistuje a Docker by ji vyrobil jako adresář vlastněný rootem;
  # uděláme to sami, ať je to vidět a ne náhoda.
  mkdir -p /var/run/tailscale
fi

AGENTICDEV_MODE=tailnet
if [[ -n "${DOMAIN:-}" ]]; then
  AGENTICDEV_MODE=public
  PUB_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  DNS_IP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
  # V režimu domain je doména jediná cesta k platformě, takže špatný A
  # záznam není varování — je to instalace, ze které nikdo nic neotevře.
  # V režimu tailscale je doména jen navíc a tailnet funguje i bez ní.
  if [[ -n "$PUB_IP" && -n "$DNS_IP" && "$PUB_IP" != "$DNS_IP" ]]; then
    if [[ "$CONNECT" == "domain" ]]; then
      die "$DOMAIN míří na $DNS_IP, ale tenhle stroj má $PUB_IP.
     Bez správného A záznamu se nevydá certifikát a k platformě se nikdo
     nedostane — v tomhle režimu jiná cesta není. Sprav DNS a pusť to znovu."
    fi
    warn "$DOMAIN míří na $DNS_IP, ale tenhle stroj má $PUB_IP"
    info "TLS certifikát se nevydá, dokud A záznam nesedí. Pokračuji dál —"
    info "po tailnetu to funguje i tak."
  elif [[ -z "$DNS_IP" ]]; then
    if [[ "$CONNECT" == "domain" ]]; then
      die "$DOMAIN se nepřeložil. V tomhle režimu je to jediná cesta k
     platformě, takže bez A záznamu nemá instalace smysl. Sprav DNS a
     pusť to znovu."
    fi
    warn "$DOMAIN se nepřeložil — zkontroluj A záznam"
  else
    ok "DNS $DOMAIN → $DNS_IP"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
#  4. Firewall a SSH
# ═══════════════════════════════════════════════════════════════════════
step "Firewall"
ufw --force reset >>"$LOG" 2>&1
ufw default deny incoming  >>"$LOG" 2>&1
ufw default allow outgoing >>"$LOG" 2>&1
ufw allow 22/tcp           >>"$LOG" 2>&1
if [[ "$AGENTICDEV_MODE" == "public" ]]; then
  ufw allow 80/tcp  >>"$LOG" 2>&1   # ACME HTTP-01 + přesměrování na https
  ufw allow 443/tcp >>"$LOG" 2>&1
fi
ufw allow 41641/udp        >>"$LOG" 2>&1
ufw allow in on tailscale0 >>"$LOG" 2>&1
ufw --force enable         >>"$LOG" 2>&1

# SSH hardening opatrně: na VPS je SSH jediná cesta zpátky.
# Zapíšeme, otestujeme, a když test neprojde, změnu vrátíme.
SSHD_DROPIN=/etc/ssh/sshd_config.d/99-agenticdev.conf
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat >"$SSHD_DROPIN" <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
MaxAuthTries 3
EOF
  if sshd -t 2>>"$LOG"; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    ok "SSH: hesla vypnutá, root jen na klíč"
  else
    rm -f "$SSHD_DROPIN"
    warn "sshd config test neprošel — hardening jsem vrátil, SSH nechávám jak bylo"
  fi
else
  warn "sshd_config nemá Include pro drop-iny — hardening přeskakuji"
  info "dopiš si ručně: PasswordAuthentication no, PermitRootLogin prohibit-password"
fi

if [[ "$AGENTICDEV_MODE" == "public" ]]; then
  ok "zvenčí otevřené 22, 80, 443"
  info "80 potřebuje Caddy na vydání certifikátu; jinak jen přesměrovává"
else
  ok "zvenčí otevřené jen 22 — všechno ostatní po tailnetu"
fi

systemctl enable --now fail2ban >>"$LOG" 2>&1 || true
dpkg-reconfigure -f noninteractive unattended-upgrades >>"$LOG" 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════
#  5. Tajemství
# ═══════════════════════════════════════════════════════════════════════
if (( FRESH )); then
  step "Generuji tajemství"
  gen() { openssl rand -base64 "${1:-32}" | tr -d '\n=+/' | cut -c1-"${2:-32}"; }
  # .env níž se čte trojím způsobem: sourcuje ho bash ("set -a; . .env"),
  # parsuje ho docker compose (--env-file) a čte ho python-dotenv stylem.
  # Cokoli, co napsal člověk — jméno, e-mail, heslo — může mít mezeru, $
  # nebo zpětný apostrof. Bez uzavření do '…' by bash při sourcování na
  # mezeře spadl ("command not found") nebo na $ tiše uřízl hodnotu.
  envq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

  TMPK=$(mktemp -d); chmod 700 "$TMPK"
  openssl genpkey -algorithm ED25519 -out "$TMPK/wo.pem" 2>>"$LOG" \
    || die "openssl neumí ED25519 — potřebuji openssl 1.1.1+"
  WO_PRIV=$(openssl pkey -in "$TMPK/wo.pem" -outform DER | tail -c 32 | base64 -w0)
  WO_PUB=$( openssl pkey -in "$TMPK/wo.pem" -pubout -outform DER | tail -c 32 | base64 -w0)
  rm -rf "$TMPK"
  [[ ${#WO_PRIV} -eq 44 && ${#WO_PUB} -eq 44 ]] \
    || die "podpisový klíč se nevygeneroval správně"

  INSTANCE_ID=$(cat /proc/sys/kernel/random/uuid)
  PG_PW=$(gen 48 40); MINIO_PW=$(gen 48 40); JWT=$(gen 64 56)
  FJ_PW=$(gen 32 24); JOIN_TOKEN=$(gen 48 40); DASH_TOKEN=$(gen 32 20)
  # Forgejo bez SECRET_KEY + INSTALL_LOCK nabíhá do instalačního
  # průvodce a `forgejo admin ...` selže na MustInstalled().
  FJ_SECRET=$(gen 80 64)
  # Podpis webhooku z Forgeja a registrace runneru. Runner secret musí být
  # 40 hex znaků — forgejo-runner na jiný formát nesedne.
  FJ_HOOK_SECRET=$(gen 48 40)
  RUNNER_SECRET=$(openssl rand -hex 20)

  ALLOW="registry.npmjs.org,pypi.org,files.pythonhosted.org,codeload.github.com,github.com"
  [[ -n "${PROV_HOST:-}" ]] && ALLOW="$PROV_HOST,$ALLOW"

  if [[ "$AGENTICDEV_MODE" == "public" ]]; then
    CP_URL="https://$DOMAIN"; FJ_ROOT="https://$DOMAIN/git/"
  else
    CP_URL="http://$TS_IP:8080"; FJ_ROOT="http://$TS_IP:3000/"
  fi

  umask 077
  cat >$ENVF <<EOF
# ═══════════════════════════════════════════════════════════════
#  AgenticDev — konfigurace instance
#  Vygenerováno: $(date -u +%Y-%m-%dT%H:%M:%SZ)
#  NEVERZUJ. WO_SIGNING_KEY_B64 si zvlášť zazálohuj mimo tenhle stroj —
#  bez něj neověříš dřív vydané work ordery.
# ═══════════════════════════════════════════════════════════════
AGENTICDEV_INSTANCE_ID=$INSTANCE_ID
AGENTICDEV_MODE=$AGENTICDEV_MODE
AGENTICDEV_DOMAIN='$(envq "$DOMAIN")'
CONTROL_PLANE_URL='$(envq "$CP_URL")'
VPS_HOST=$TS_IP
# tailscale = vnitřní služby na tailnetu, přihlášení dělá tailnet
# domain    = vnitřní služby na 127.0.0.1, přihlášení obyčejným SSH klíčem
AGENTICDEV_CONNECT=$CONNECT
# Na téhle adrese se publikují Postgres, Forgejo a MinIO. NIKDY 0.0.0.0 —
# veřejná adresa tady znamená databázi na internetu.
BIND_ADDR=$TS_IP
TZ=Europe/Prague

# ─── admin ───────────────────────────────────────────────────
# Kdo tuhle instanci spravuje. Zakládá se z toho \`principal\`, aby u
# rozhodnutí odklikaného v panelu bylo v auditní stopě vidět kdo — dřív
# tam byl actor prázdný.
ADMIN_NAME='$(envq "$ADMIN_NAME")'
ADMIN_EMAIL='$(envq "$ADMIN_EMAIL")'

# ─── tajemství ───────────────────────────────────────────────
POSTGRES_PASSWORD=$PG_PW
MINIO_ROOT_PASSWORD=$MINIO_PW
JWT_SECRET=$JWT
WO_SIGNING_KEY_B64=$WO_PRIV
WO_VERIFY_KEY_B64=$WO_PUB
JOIN_TOKEN=$JOIN_TOKEN
DASHBOARD_TOKEN='$(envq "$ADMIN_PW")'
ENROLL_PASSWORD='$(envq "$ENROLL_PW")'
LEASE_HOURS=4

# ─── veřejná registrace přes Tailscale Funnel ────────────────────────
# TS_API_KEY nepovinný. Když ho doplníš, vyrobí se pro každý stroj
# jednorázový klíč místo sdíleného. https://login.tailscale.com/admin/settings/keys
TS_AUTHKEY=
TS_API_KEY=
TS_TAILNET=-

# ─── Forgejo ─────────────────────────────────────────────────
FORGEJO_ADMIN_USER='$(envq "$ADMIN_USER")'
FORGEJO_ADMIN_EMAIL='$(envq "$ADMIN_EMAIL")'
FORGEJO_ADMIN_PASSWORD=$FJ_PW
FORGEJO_SECRET_KEY=$FJ_SECRET
FORGEJO_ROOT_URL='$(envq "$FJ_ROOT")'
FORGEJO_TOKEN=
FORGEJO_HOOK_SECRET=$FJ_HOOK_SECRET
RUNNER_SECRET=$RUNNER_SECRET
RUNNER_TAG=6

# ─── mail ────────────────────────────────────────────────────
SMTP_HOST='$(envq "${SMTP_HOST:-}")'
SMTP_PORT=587
SMTP_USER='$(envq "${SMTP_USER:-}")'
SMTP_PASSWORD='$(envq "${SMTP_PASS:-}")'
SMTP_FROM='$(envq "$ADMIN_EMAIL")'

# ─── modely ──────────────────────────────────────────────────
MODEL_BACKEND=$MODEL_BACKEND
MODEL_BASE_URL=$MODEL_BASE_URL
MODEL_API_KEY='$(envq "${MODEL_KEY:-}")'
DEFAULT_MODEL=$DEFAULT_MODEL
LOCAL_MODEL=local/qwen2.5-coder:32b
MODEL_MAX_TOKENS=8000
OLLAMA_HOST=http://host.docker.internal:11434
EGRESS_ALLOWLIST=$ALLOW

# ─── zálohy: doplň a spusť 'systemctl enable --now agenticdev-backup.timer' ──
RESTIC_REPOSITORY=
RESTIC_PASSWORD=
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=

# ─── verze image ─────────────────────────────────────────────
FORGEJO_TAG=11
POSTGRES_TAG=pg16
MINIO_TAG=RELEASE.2025-04-22T22-12-26Z
CADDY_TAG=2-alpine
EOF
  umask 022
  chmod 600 $ENVF
  ok "podpisový klíč, join token, hesla"
else
  # doplnění chybějících položek při upgradu ze starší verze
  add() { grep -q "^$1=" $ENVF || echo "$1=$2" >>$ENVF; }
  add AGENTICDEV_INSTANCE_ID "$(cat /proc/sys/kernel/random/uuid)"
  add AGENTICDEV_MODE        "$([[ -n "${AGENTICDEV_DOMAIN:-}" ]] && echo public || echo tailnet)"
  add LEASE_HOURS       4
  add ENROLL_PASSWORD   "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
  add TS_AUTHKEY        ""
  add TS_API_KEY        ""
  add TS_TAILNET        "-"
  add FORGEJO_SECRET_KEY "$(openssl rand -base64 80 | tr -d '\n=+/' | cut -c1-64)"
  add FORGEJO_HOOK_SECRET "$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-40)"
  add RUNNER_SECRET     "$(openssl rand -hex 20)"
  add RUNNER_TAG        6
  add LOCAL_MODEL       "local/qwen2.5-coder:32b"
  add CONTROL_PLANE_URL "$([[ -n "${AGENTICDEV_DOMAIN:-}" ]] && echo "https://$AGENTICDEV_DOMAIN" || echo "http://$TS_IP:8080")"
  add FORGEJO_ROOT_URL  "$([[ -n "${AGENTICDEV_DOMAIN:-}" ]] && echo "https://$AGENTICDEV_DOMAIN/git/" || echo "http://$TS_IP:3000/")"
  if ! grep -q '^WO_VERIFY_KEY_B64=..' $ENVF; then
    warn "chybí veřejný klíč k podpisovému — dopočítat ho z privátního neumím bez Pythonu"
    python3 - "$ENVF" <<'PY' || warn "doplň WO_VERIFY_KEY_B64 ručně"
import base64, re, sys
p = sys.argv[1]; s = open(p).read()
priv = re.search(r'^WO_SIGNING_KEY_B64=(.+)$', s, re.M).group(1).strip()
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as ser
k = Ed25519PrivateKey.from_private_bytes(base64.b64decode(priv))
pub = base64.b64encode(k.public_key().public_bytes(
    ser.Encoding.Raw, ser.PublicFormat.Raw)).decode()
s = re.sub(r'^WO_VERIFY_KEY_B64=.*$', f'WO_VERIFY_KEY_B64={pub}', s, flags=re.M) \
    if 'WO_VERIFY_KEY_B64=' in s else s + f'\nWO_VERIFY_KEY_B64={pub}\n'
open(p, 'w').write(s)
PY
  fi
  ok "konfigurace doplněna"
fi

# shellcheck disable=SC1090
set -a; . $ENVF; set +a

# ═══════════════════════════════════════════════════════════════════════
#  6. Start stacku
# ═══════════════════════════════════════════════════════════════════════
step "Start služeb"
PROFILE_ARGS="--profile gate"
[[ "$AGENTICDEV_MODE" == "public" ]] && PROFILE_ARGS="$PROFILE_ARGS --profile public"
# shellcheck disable=SC2086
dc() { (cd "$SRC/vps" && docker compose $PROFILE_ARGS --env-file $ENVF "$@"); }

# ── TLS: tailnetová doména vs. veřejná doména ─────────────────────────
# Caddyfile má v sobě `tls { get_certificate tailscale }`. To je správně
# pro *.ts.net (Let's Encrypt takovou doménu nikdy neověří — nemá veřejný
# DNS záznam). U běžné veřejné domény ale ten blok musí pryč, jinak by
# Caddy hledal certifikát u tailscaled místo u ACME.
if [[ "$AGENTICDEV_MODE" == "public" ]]; then
  if [[ "$AGENTICDEV_DOMAIN" == *.ts.net ]]; then
    if ! tailscale cert "$AGENTICDEV_DOMAIN" >>"$LOG" 2>&1; then
      warn "Tailscale ti zatím nevydá HTTPS certifikát pro $AGENTICDEV_DOMAIN"
      info "Zapni to jednou: https://login.tailscale.com/admin/dns → HTTPS Certificates → Enable HTTPS"
      info "Pak spusť: agenticdev-ctl restart caddy"
    else
      ok "TLS certifikát od Tailscale"
    fi
  else
    python3 - "$SRC/vps/Caddyfile" <<'PYEOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r"\n\t# Tailnet doména.*?\n\ttls \{\n\t\tget_certificate tailscale\n\t\}\n", "\n", s, flags=re.S)
open(p, "w").write(s)
PYEOF
    ok "TLS přes Let's Encrypt (veřejná doména)"
  fi
fi

info "první běh staví image control plane, 2–3 minuty"
run "docker compose up      " bash -c \
  "cd '$SRC/vps' && docker compose $PROFILE_ARGS --env-file $ENVF up -d --build"

printf "  čekám na databázi       "
for i in $(seq 1 60); do
  dc exec -T postgres pg_isready -U agenticdev -d agenticdev >/dev/null 2>&1 && break
  printf "."; sleep 3
  [[ $i -eq 60 ]] && { echo; dc logs --tail=40 postgres; die "postgres nenaběhl"; }
done
printf " ${GRN}✓${OFF}\n"

printf "  čekám na control plane  "
for i in $(seq 1 60); do
  curl -fsS "http://$VPS_HOST:8080/v1/health" >/dev/null 2>&1 && break
  printf "."; sleep 3
  [[ $i -eq 60 ]] && { echo; dc logs --tail=40 control-plane; die "control plane nenaběhl"; }
done
printf " ${GRN}✓${OFF}\n"

# Sandbox projekt narovnat na tuhle instanci: model, který jsi vybral, a
# skutečná adresa gitu. V seedu je zástupné 'vps', které se nikde
# nepřeloží — bez tohohle by první klik na ikonu skončil u repozitáře,
# ke kterému se nedá připojit.
dc exec -T postgres psql -qtAX -U agenticdev -d agenticdev -c \
  "UPDATE project
      SET model_allowlist = ARRAY['$DEFAULT_MODEL','$LOCAL_MODEL'],
          repo_url = 'ssh://git@$VPS_HOST:2222/$FORGEJO_ADMIN_USER/sandbox.git'
    WHERE code = 'sandbox'" >>"$LOG" 2>&1 || true

# ═══════════════════════════════════════════════════════════════════════
#  7. Forgejo — admin a API token
# ═══════════════════════════════════════════════════════════════════════
step "Git server"
printf "  čekám na Forgejo        "
for i in $(seq 1 60); do
  curl -fsS --max-time 5 "http://$VPS_HOST:3000/api/healthz" >/dev/null 2>&1 && break
  printf "."; sleep 3
  [[ $i -eq 60 ]] && { printf " ${YLW}!${OFF}\n"; warn "Forgejo se rozjíždí pomalu, pokračuji"; }
done
printf " ${GRN}✓${OFF}\n"

if ! dc exec -T -u git forgejo forgejo admin user list 2>/dev/null \
     | awk '{print $2}' | grep -qx "$FORGEJO_ADMIN_USER"; then
  dc exec -T -u git forgejo forgejo admin user create --admin \
    --username "$FORGEJO_ADMIN_USER" --password "$FORGEJO_ADMIN_PASSWORD" \
    --email "$FORGEJO_ADMIN_EMAIL" --must-change-password=false >>"$LOG" 2>&1 \
    && ok "admin '$FORGEJO_ADMIN_USER'" || warn "admina se nepodařilo vytvořit, viz $LOG"
else
  ok "admin '$FORGEJO_ADMIN_USER' už existuje"
fi

if [[ -z "${FORGEJO_TOKEN:-}" ]]; then
  TOK=$(dc exec -T -u git forgejo forgejo admin user generate-access-token \
        --username "$FORGEJO_ADMIN_USER" --token-name "agenticdev-$(date +%s)" \
        --scopes write:repository,write:user,write:admin 2>/dev/null \
        | grep -oE '[A-Za-z0-9]{40}' | head -1 || true)
  if [[ -n "$TOK" ]]; then
    sed -i "s|^FORGEJO_TOKEN=.*|FORGEJO_TOKEN=$TOK|" $ENVF
    FORGEJO_TOKEN=$TOK
    run "restart control plane  " bash -c \
      "cd '$SRC/vps' && docker compose $PROFILE_ARGS --env-file $ENVF up -d control-plane"
    ok "API token — nástěnka umí zakládat projekty a klíče"
  else
    warn "API token nevznikl — projekty a SSH klíče půjde zakládat jen ručně"
    info "vytvoř token ve Forgeju a doplň FORGEJO_TOKEN do $ENVF"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════
#  8. Zálohy
# ═══════════════════════════════════════════════════════════════════════
step "Denní zálohy"
install -m 0700 "$SRC/vps/backup/restic-backup.sh" /usr/local/bin/agenticdev-backup
cat >/etc/systemd/system/agenticdev-backup.service <<EOF
[Unit]
Description=AgenticDev záloha
[Service]
Type=oneshot
EnvironmentFile=$ENVF
ExecStart=/usr/local/bin/agenticdev-backup
EOF
cat >/etc/systemd/system/agenticdev-backup.timer <<'EOF'
[Unit]
Description=Denní záloha AgenticDev
[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15m
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
if grep -q '^RESTIC_REPOSITORY=.\+' $ENVF; then
  systemctl enable --now agenticdev-backup.timer >>"$LOG" 2>&1
  ok "timer aktivní (02:30)"
else
  warn "zálohy vypnuté — doplň RESTIC_REPOSITORY a RESTIC_PASSWORD do $ENVF"
  info "pak: systemctl enable --now agenticdev-backup.timer"
fi

# ═══════════════════════════════════════════════════════════════════════
#  9. Nástroje na VPS
# ═══════════════════════════════════════════════════════════════════════
step "Nástroje"
install -m 0755 "$SRC/vps/agenticdev-ctl" /usr/local/bin/agenticdev-ctl
# Launcher patří na VPS, protože tam běží pody (ADR-0005). Lidé ho pouštějí
# po přihlášení přes Tailscale SSH.
install -m 0755 "$SRC/launcher/agenticdev" /usr/local/bin/agenticdev
ln -sfn /usr/local/bin/agenticdev /usr/local/bin/adev
cat >/usr/local/bin/agenticdev-info <<'INFOEOF'
#!/usr/bin/env bash
set -a; . /srv/agenticdev/config/.env; set +a
Y='\033[1;33m'; B='\033[1;36m'; D='\033[2m'; O='\033[0m'
CP="${CONTROL_PLANE_URL:-http://$VPS_HOST:8080}"
printf "\n  ${B}NÁSTĚNKA${O}   %s\n" "$CP"
printf "             heslo: ${Y}%s${O}\n" "$DASHBOARD_TOKEN"
printf "\n  ${B}GIT${O}        %s\n" "${FORGEJO_ROOT_URL:-http://$VPS_HOST:3000/}"
printf "             %s / ${Y}%s${O}\n" "$FORGEJO_ADMIN_USER" "$FORGEJO_ADMIN_PASSWORD"
printf "\n  ${B}ODKAZ PRO TÝM${O}   %s\n" "${JOIN_URL:-（Funnel neběží）}"
printf "             heslo: ${Y}%s${O}\n" "$ENROLL_PASSWORD"
printf "\n  ${B}INSTALÁTOR MACU${O}\n"
printf "             /srv/agenticdev/out/agenticdev-install-mac.sh\n"
printf "             ${D}scp root@%s:/srv/agenticdev/out/agenticdev-install-mac.sh ~/Downloads/${O}\n" "$VPS_HOST"
printf "\n  ${B}INSTANCE${O}   %s\n" "$AGENTICDEV_INSTANCE_ID"
printf "  ${D}agenticdev-ctl status | logs | mac | backup-now${O}\n\n"
INFOEOF
chmod +x /usr/local/bin/agenticdev-info
ok "agenticdev-ctl, agenticdev-info, agenticdev (adev)"

# ═══════════════════════════════════════════════════════════════════════
#  10. Druhý instalátor — svázaný s touhle instancí
# ═══════════════════════════════════════════════════════════════════════
step "Generuji instalátor Macu"
MACF=$(bash "$SRC/vps/mk-mac-installer.sh") || die "generátor selhal, viz $LOG"
ok "$MACF"
info "vazba: adresa control plane + join token + fingerprint instance + host key gitu"
cat >/usr/local/bin/agenticdev-mac-installer <<EOF
#!/usr/bin/env bash
exec bash $SRC/vps/mk-mac-installer.sh "\$@"
EOF
chmod +x /usr/local/bin/agenticdev-mac-installer

# ═══════════════════════════════════════════════════════════════════════
#  10b. Veřejná registrace — Tailscale Funnel
# ═══════════════════════════════════════════════════════════════════════
# Zvenčí je dostupná JEDINÁ cesta: /join. Všechno ostatní zůstává na
# tailnetu. Funnel jede na 8443, ať se nepere s Caddy na 443.
step "Veřejná registrace"
JOIN_URL=""
if [[ "$CONNECT" == "domain" ]]; then
  # Bez Tailscale není co tunelovat: registrace jde přes Caddy na doméně,
  # stejnou cestou jako panel. Funnel by tu neměl ani co spustit.
  JOIN_URL="https://${DOMAIN}/join"
  ok "registrace na doméně: $JOIN_URL"
  if grep -q '^JOIN_URL=' $ENVF; then
    sed -i "s|^JOIN_URL=.*|JOIN_URL=$JOIN_URL|" $ENVF
  else
    echo "JOIN_URL=$JOIN_URL" >>$ENVF
  fi
elif tailscale funnel --bg --https=8443 "http://${VPS_HOST}:8080/join" >>"$LOG" 2>&1; then
  TS_NAME=$(tailscale status --json 2>/dev/null \
            | grep -oE '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | head -1 | sed 's/.*"\([^"]*\)"$/\1/' | sed 's/\.$//')
  if [[ -n "$TS_NAME" ]]; then
    JOIN_URL="https://${TS_NAME}:8443/"
    ok "veřejně dostupné: $JOIN_URL"
    info "vystavena jen cesta /join, nic jiného"
    # `sed` končí nulou i když nic nenahradil, takže se na jeho návratový
    # kód nedá vázat zápis chybějícího řádku — bez téhle podmínky se
    # JOIN_URL do .env při čisté instalaci nikdy nedostal a
    # `agenticdev-info` pak tvrdil, že Funnel neběží.
    if grep -q '^JOIN_URL=' $ENVF; then
      sed -i "s|^JOIN_URL=.*|JOIN_URL=$JOIN_URL|" $ENVF
    else
      echo "JOIN_URL=$JOIN_URL" >>$ENVF
    fi
  else
    warn "Funnel běží, ale nezjistil jsem veřejné jméno — 'tailscale funnel status'"
  fi
else
  warn "Funnel se nezapnul — registrace zvenčí zatím nepojede"
  info "Potřebuje v ACL uzlu atribut funnel:"
  info "  https://login.tailscale.com/admin/acls  →  sekce Funnel  →  Add Funnel to policy"
  info "Pak spusť:  tailscale funnel --bg --https=8443 http://$VPS_HOST:8080/join"
fi

# ═══════════════════════════════════════════════════════════════════════
#  11. Kontrola
# ═══════════════════════════════════════════════════════════════════════
step "Kontrola"
( cd "$SRC" && bash tools/verify-tree.sh ) >>"$LOG" 2>&1 \
  && ok "strom repa sedí" || warn "verify-tree hlásí chybu, viz $LOG"
curl -fsS "http://$VPS_HOST:8080/v1/health" >/dev/null && ok "control plane odpovídá"
curl -fsS "http://$VPS_HOST:8080/v1/identity" | grep -q fingerprint && ok "identita instance"
LISTEN=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\])' \
         | sed 's/.*://' | sort -un | tr '\n' ' ')
printf "  ${DIM}naslouchá na všech adresách: %s${OFF}\n" "${LISTEN:-nic}"
if [[ "$AGENTICDEV_MODE" == "public" ]]; then
  info "očekávané: 22 80 443 — cokoli dalšího prověř"
else
  info "očekávané: 22 — cokoli dalšího prověř"
fi

# ═══════════════════════════════════════════════════════════════════════
#  HOTOVO
# ═══════════════════════════════════════════════════════════════════════
CP="${CONTROL_PLANE_URL:-http://$VPS_HOST:8080}"
if [[ "$CONNECT" == "domain" ]]; then
  PANEL_URL="https://$DOMAIN/"
  PANEL_NOTE="funguje z jakéhokoli prohlížeče — chrání ho jen tvoje heslo"
else
  PANEL_URL="$CP"
  PANEL_NOTE="jen z tailnetu; nejdřív si připoj stroj odkazem pro tým"
fi
cat <<EOF

  ${GRN}╔═══════════════════════════════════════════════════════╗
  ║   HOTOVO. Platforma běží.                             ║
  ╚═══════════════════════════════════════════════════════╝${OFF}

  ${BLU}1) ADMIN PANEL${OFF} — $PANEL_NOTE
     ${YLW}$PANEL_URL${OFF}
     správce: $ADMIN_NAME <$ADMIN_EMAIL>
     heslo: ${YLW}to, které jsi zadal jako ADMIN${OFF}

  ${BLU}2) ODKAZ PRO TÝM${OFF} — pošli komukoliv, kdekoliv na světě
     ${YLW}${JOIN_URL:-（nezapnulo se, viz výše）}${OFF}

     Zadá heslo, které jsi zadal jako JOIN, a stránka ho provede
     zbytkem. Funguje pro macOS, Linux i Windows.

     Odkaz je veřejný, heslo ne. Posílej je zvlášť.

  ${BLU}3) GIT${OFF}
     ${FORGEJO_ROOT_URL:-http://$VPS_HOST:3000/}
     $FORGEJO_ADMIN_USER / ${YLW}$FORGEJO_ADMIN_PASSWORD${OFF}

  ${YLW}Zazálohuj si mimo tenhle stroj:${OFF}
     $ENVF        ${DIM}(hlavně WO_SIGNING_KEY_B64)${OFF}

  ${DIM}Tenhle výpis znovu:  agenticdev-info
  Obsluha:             agenticdev-ctl status | logs | mac | backup-now${OFF}

EOF
[[ -z "${MODEL_KEY:-}" ]] && \
  warn "dodavatele modelu a API klíč zatím nemáš — nastav je v panelu: Nastavení → Modely (platí okamžitě, bez restartu)"
[[ "$AGENTICDEV_MODE" == "tailnet" ]] && \
  info "Bez domény jede platforma jen po tailnetu. Doménu doplníš do $ENVF (AGENTICDEV_DOMAIN, AGENTICDEV_MODE=public) a pustíš 'agenticdev-ctl up'."

exit 0
#__AGENTICDEV_PAYLOAD_BELOW__
