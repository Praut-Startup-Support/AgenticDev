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

# Jazyk instalace je součástí konfigurace instance. U upgradu se převezme,
# u automatické instalace ho lze nastavit jedním z podporovaných kódů a u nové
# interaktivní instalace je to úplně první volba.
AGENTICDEV_LANG="${AGENTICDEV_LANG:-}"
if [[ -z "$AGENTICDEV_LANG" && -r "$ENVF" ]]; then
  AGENTICDEV_LANG=$(sed -n 's/^AGENTICDEV_LANG=//p' "$ENVF" | tail -1)
fi
if [[ -z "$AGENTICDEV_LANG" && ! $MODE_CHECK -eq 1 && ! $MODE_YES -eq 1 ]]; then
  printf "\n  Choose language / Vyber jazyk\n\n  1) Čeština       2) English\n  3) Deutsch       4) Español\n  5) Русский       6) 中文\n  7) Português     8) Français\n  9) हिन्दी          10) العربية\n\n"
  read -rp "  číslo / number (Enter = 1): " LANG_PICK </dev/tty
  case "${LANG_PICK:-1}" in
    1) AGENTICDEV_LANG=cs ;; 2) AGENTICDEV_LANG=en ;;
    3) AGENTICDEV_LANG=de ;; 4) AGENTICDEV_LANG=es ;;
    5) AGENTICDEV_LANG=ru ;; 6) AGENTICDEV_LANG=zh ;;
    7) AGENTICDEV_LANG=pt ;; 8) AGENTICDEV_LANG=fr ;;
    9) AGENTICDEV_LANG=hi ;; 10) AGENTICDEV_LANG=ar ;;
    *) die "Neplatná volba / Invalid choice" ;;
  esac
fi
AGENTICDEV_LANG="${AGENTICDEV_LANG:-cs}"
[[ "$AGENTICDEV_LANG" =~ ^(cs|en|de|es|ru|zh|pt|fr|hi|ar)$ ]] \
  || die "AGENTICDEV_LANG: cs, en, de, es, ru, zh, pt, fr, hi, ar"

say() { # say "česky" "English"
  [[ "$AGENTICDEV_LANG" == cs ]] && printf '%s\n' "$1" || printf '%s\n' "$2"
}
pick() { # pick "česky" "English"
  [[ "$AGENTICDEV_LANG" == cs ]] && printf '%s' "$1" || printf '%s' "$2"
}

installation_tutorial() {
  [[ -e "$ENVF" || $MODE_CHECK -eq 1 || $MODE_YES -eq 1 ]] && return
  echo
  if [[ "$AGENTICDEV_LANG" == en ]]; then
    cat <<'TUTORIAL'
  Welcome. This wizard will install the complete AgenticDev platform.

  What will happen:
    1. Check the host and install Docker, Claude Code and Codex.
    2. Choose private Tailscale access or your own public domain.
    3. Create the administrator, Git service and encrypted platform secrets.
    4. Start isolated agent workloads, backups and the administration panel.

  You will need:
    • a clean supported Debian/Ubuntu VPS and root access;
    • optionally a domain, or a Tailscale account for the private mode;
    • two new passwords: ADMIN for you and JOIN for team enrollment.

  Model subscriptions are personal. The installer never asks for Claude or
  ChatGPT credentials. Each user signs in to Claude Code or Codex under their
  own Linux account when they first select that provider.

  Existing installations keep their data and secrets. Press Enter to continue.
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == de ]]; then
    cat <<'TUTORIAL'
  Willkommen. Dieser Assistent installiert die vollständige AgenticDev-Plattform.

  Er prüft den Server, installiert Docker, Claude Code und Codex, lässt dich
  zwischen privatem Tailscale-Zugang und eigener Domain wählen und startet
  isolierte Agenten, Git, Backups und das Admin-Dashboard.

  Bereithalten: einen sauberen Debian/Ubuntu-VPS mit Root-Zugang, optional
  Domain oder Tailscale sowie getrennte ADMIN- und JOIN-Passwörter.
  Claude- und ChatGPT-Abos bleiben persönlich; jeder meldet sich unter seinem
  eigenen Linux-Konto an. Vorhandene Daten und Secrets bleiben bei Updates erhalten.

  Drücke Enter, um fortzufahren.
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == es ]]; then
    cat <<'TUTORIAL'
  Bienvenido. Este asistente instala la plataforma AgenticDev completa.

  Comprueba el servidor, instala Docker, Claude Code y Codex, permite elegir
  entre acceso privado con Tailscale o un dominio propio, e inicia agentes
  aislados, Git, copias de seguridad y el panel de administración.

  Prepara un VPS Debian/Ubuntu limpio con acceso root, un dominio o Tailscale
  opcional y contraseñas ADMIN y JOIN separadas. Las suscripciones de Claude y
  ChatGPT son personales; cada usuario inicia sesión en su propia cuenta Linux.

  Pulsa Enter para continuar.
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == ru ]]; then
    cat <<'TUTORIAL'
  Добро пожаловать. Этот мастер установит всю платформу AgenticDev.

  Он проверит сервер, установит Docker, Claude Code и Codex, предложит выбрать
  приватный доступ через Tailscale или собственный домен и запустит изолированных
  агентов, Git, резервные копии и панель администратора.

  Нужны чистый VPS Debian/Ubuntu с root-доступом, при желании домен или Tailscale,
  а также разные пароли ADMIN и JOIN. Подписки Claude и ChatGPT персональные:
  каждый пользователь входит под собственной учетной записью Linux.

  Нажмите Enter, чтобы продолжить.
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == zh ]]; then
    cat <<'TUTORIAL'
  欢迎。本向导将安装完整的 AgenticDev 平台。

  它会检查服务器，安装 Docker、Claude Code 和 Codex，让你选择私有
  Tailscale 访问或自己的域名，并启动隔离代理、Git、备份和管理面板。

  请准备一台具有 root 权限的全新 Debian/Ubuntu VPS；域名或 Tailscale
  可选；ADMIN 与 JOIN 必须使用不同密码。Claude 和 ChatGPT 订阅属于个人，
  每位用户都在自己的 Linux 账户下登录。升级会保留现有数据与密钥。

  按 Enter 继续。
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == pt ]]; then
    cat <<'TUTORIAL'
  Bem-vindo. Este assistente instala a plataforma AgenticDev completa.

  Ele verifica o servidor, instala Docker, Claude Code e Codex, permite escolher
  acesso privado por Tailscale ou domínio próprio e inicia agentes isolados,
  Git, backups e o painel administrativo.

  Prepare um VPS Debian/Ubuntu limpo com acesso root, domínio ou Tailscale
  opcional e senhas ADMIN e JOIN separadas. As assinaturas Claude e ChatGPT são
  pessoais; cada usuário entra em sua própria conta Linux.

  Pressione Enter para continuar.
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == fr ]]; then
    cat <<'TUTORIAL'
  Bienvenue. Cet assistant installe la plateforme AgenticDev complète.

  Il vérifie le serveur, installe Docker, Claude Code et Codex, propose un accès
  privé Tailscale ou votre propre domaine, puis démarre les agents isolés, Git,
  les sauvegardes et le tableau de bord d’administration.

  Préparez un VPS Debian/Ubuntu propre avec accès root, éventuellement un domaine
  ou Tailscale, et des mots de passe ADMIN et JOIN distincts. Les abonnements
  Claude et ChatGPT restent personnels, dans le compte Linux de chaque utilisateur.

  Appuyez sur Entrée pour continuer.
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == hi ]]; then
    cat <<'TUTORIAL'
  स्वागत है। यह सहायक पूरा AgenticDev प्लेटफ़ॉर्म स्थापित करेगा।

  यह सर्वर की जाँच करता है, Docker, Claude Code और Codex स्थापित करता है,
  निजी Tailscale या अपने डोमेन का विकल्प देता है और अलग-थलग एजेंट, Git,
  बैकअप तथा प्रशासन पैनल शुरू करता है।

  root पहुँच वाला साफ Debian/Ubuntu VPS, वैकल्पिक डोमेन या Tailscale और अलग
  ADMIN व JOIN पासवर्ड तैयार रखें। Claude और ChatGPT सदस्यताएँ व्यक्तिगत हैं;
  हर उपयोगकर्ता अपने Linux खाते में लॉग इन करता है।

  आगे बढ़ने के लिए Enter दबाएँ।
TUTORIAL
  elif [[ "$AGENTICDEV_LANG" == ar ]]; then
    cat <<'TUTORIAL'
  مرحباً. سيقوم هذا المعالج بتثبيت منصة AgenticDev كاملة.

  سيتحقق من الخادم ويثبت Docker وClaude Code وCodex، ثم يتيح الاختيار بين
  وصول Tailscale الخاص أو نطاقك الخاص، ويشغّل الوكلاء المعزولين وGit والنسخ
  الاحتياطية ولوحة الإدارة.

  جهّز خادم Debian/Ubuntu نظيفاً بصلاحية root، ونطاقاً أو Tailscale اختيارياً،
  وكلمتي مرور منفصلتين ADMIN وJOIN. اشتراكات Claude وChatGPT شخصية؛ يسجل كل
  مستخدم الدخول من حساب Linux الخاص به.

  اضغط Enter للمتابعة.
TUTORIAL
  else
    cat <<'TUTORIAL'
  Vítej. Tento průvodce nainstaluje kompletní platformu AgenticDev.

  Co proběhne:
    1. Kontrola serveru a instalace Dockeru, Claude Code a Codexu.
    2. Volba soukromého přístupu přes Tailscale nebo vlastní veřejné domény.
    3. Vytvoření správce, Git služby a šifrovaných tajemství platformy.
    4. Spuštění izolovaných agentních běhů, záloh a administračního panelu.

  Připrav si:
    • čistý podporovaný Debian/Ubuntu VPS a root přístup;
    • volitelně doménu, nebo Tailscale účet pro soukromý režim;
    • dvě nová hesla: ADMIN pro tebe a JOIN pro registraci týmu.

  Modelová předplatná jsou osobní. Instalátor nikdy nechce přihlašovací údaje
  ke Claude ani ChatGPT. Každý uživatel se přihlásí do Claude Code nebo Codexu
  pod vlastním linuxovým účtem při prvním výběru providera.

  Existující instalace zachovávají data i tajemství. Pokračuj Enterem.
TUTORIAL
  fi
  read -r </dev/tty
}

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
    read -rsp "  $__q ($(pick 'doporučeno min' 'recommended min') $__min $(pick 'znaků' 'characters')): " __a </dev/tty; echo
    if [[ ${#__a} -lt $__min ]]; then
      read -rp "${YLW}    $(pick 'kratší, než se doporučuje — trvat na tom? [a/N]' 'shorter than recommended — keep it? [y/N]') ${OFF}" __ok </dev/tty
      [[ "$__ok" =~ ^[aAyY]$ ]] || continue
    fi
    read -rsp "  $(pick 'ještě jednou' 'repeat password'): " __b </dev/tty; echo
    [[ "$__a" == "$__b" ]] && break
    printf "${YLW}    %s${OFF}\n" "$(pick 'nesouhlasí — zkus znovu' 'passwords do not match — try again')"
  done
  printf -v "$__v" '%s' "$__a"
}

run() {  # run "popis" cmd...
  local msg="$1"; shift
  printf "  %s" "$msg"
  ( "$@" >>"$LOG" 2>&1 ) & local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf "."; sleep 2; done
  if wait "$pid"; then printf " ${GRN}✓${OFF}\n"
  else printf " ${RED}✗${OFF}\n"; echo; tail -n 30 "$LOG"; die "$msg $(pick 'selhalo. Celý log:' 'failed. Full log:') $LOG"; fi
}

clear 2>/dev/null || true
cat <<'BANNER'
  ┌──────────────────────────────────────────────────┐
  │   P R A U T   P L A T F O R M                    │
  │   instalace VPS                                  │
  └──────────────────────────────────────────────────┘
BANNER
installation_tutorial

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
install -d -o 1000 -g 1000 -m 0750 "$ROOT/data/runner"
# Forgejo běží v kontejneru pod uid 1000. Bez tohohle nepřečte vlastní
# app.ini ("permission denied") a skončí v restart-loopu.
chown -R 1000:1000 $ROOT/data/forgejo
chown -R 1000:1000 "$ROOT/data/runner"
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
  ADMIN_USER="${FORGEJO_ADMIN_USER:-agentic-admin}"
  info "tajemství zůstávají, měnit je nebudu"
else
  step "$(pick 'Nastavení — pár otázek, pak už nic' 'Setup — a few questions, then the installer takes over')"
  echo
  info "$(pick 'Doménu nech prázdnou, jestli VPS nemá veřejné DNS.' 'Leave the domain empty if the VPS has no public DNS.')"
  info "$(pick 'Platforma pak pojede jen po tailnetu.' 'The platform will then be available only inside the tailnet.')"
  ask DOMAIN "$(pick 'Doména platformy (Enter = jen tailnet)' 'Platform domain (Enter = tailnet only)')" ""
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
  ask ADMIN_NAME "$(pick 'Tvoje jméno a příjmení (správce instance)' 'Your full name (instance administrator)')" ""
  [[ -n "$ADMIN_NAME" ]] || die "$(pick 'jméno je povinné — audit musí znát správce' 'name is required — the audit trail must identify the administrator')"
  [[ "$ADMIN_NAME" == *" "* ]] || warn "$(pick 'jen jedno slovo? V auditní stopě to bude takhle.' 'Only one word? It will appear that way in the audit trail.')"
  ask ADMIN_EMAIL "$(pick 'Tvůj e-mail (správce instance)' 'Your email (instance administrator)')" ""
  [[ -n "$ADMIN_EMAIL" ]] || die "$(pick 'e-mail je povinný — Forgejo bez něj admina nezaloží' 'email is required — Forgejo cannot create the administrator without it')"
  # Forgejo 11 reserves the literal username "admin" and rejects bootstrap.
  ask ADMIN_USER "$(pick 'Přihlašovací jméno do gitu' 'Git login name')" "agentic-admin"

  echo
  info "$(pick 'Dvě hesla. Vymysli si je teď, jinam se zapisovat nebudou.' 'Choose two passwords now; they are not sent anywhere else.')"
  info "$(pick '  ADMIN  — přihlášení do admin panelu (jen ty)' '  ADMIN  — administration panel login (only you)')"
  info "$(pick '  JOIN   — dostane každý, kdo si má připojit stroj' '  JOIN   — shared with people enrolling a workstation')"
  askpw ADMIN_PW  "$(pick 'Heslo do admin panelu' 'Administration panel password')" 12
  askpw ENROLL_PW "$(pick 'Heslo pro připojení strojů' 'Workstation enrollment password')" 10

  # Subscription credentials se nikdy neptá root instalátor ani panel.
  # Každý uživatel se přihlásí nativním CLI pod vlastním UID.

  ask SMTP_HOST "$(pick 'SMTP host (Enter = přeskočit maily)' 'SMTP host (Enter = skip email)')" ""
  if [[ -n "${SMTP_HOST:-}" ]]; then
    ask  SMTP_USER "$(pick 'SMTP uživatel' 'SMTP user')" ""
    asks SMTP_PASS "$(pick 'SMTP heslo' 'SMTP password')"
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
  restic openssl rsync python3 python3-cryptography iproute2 xfsprogs
run "instalace agentů       " apt-get install -y -qq nodejs npm
run "Claude a Codex CLI      " npm install -g @anthropic-ai/claude-code @openai/codex

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
bash "$STAGE/tools/runtime-host-check.sh" >>"$LOG" 2>&1 \
  || die "host neumí povinné cgroups/overlay2/XFS project quota; viz $LOG"

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
step "$(pick 'Připojení' 'Access mode')"
CONNECT="${AGENTICDEV_CONNECT:-}"
if [[ -z "$CONNECT" ]]; then
  if (( MODE_YES )); then
    # Bez odpovědi se řídíme tím, co je k dispozici: doména = domain.
    CONNECT=$([[ -n "${DOMAIN:-}" ]] && echo domain || echo tailscale)
  else
    echo
    info "$(pick '  1) Tailscale  — z internetu je vidět jen registrace.' '  1) Tailscale  — only enrollment is visible from the internet.')"
    info "$(pick '                  Potřebuje Tailscale účet pro tuhle instanci.' '                  Requires a Tailscale account for this instance.')"
    info "$(pick "  2) Doména     — bez třetí strany, TLS z Let's Encrypt." "  2) Domain     — no access-network provider, Let's Encrypt TLS.")"
    info "$(pick '                  Z internetu je vidět i panel, chráněný heslem.' '                  The password-protected panel is internet-visible.')"
    [[ -n "${DOMAIN:-}" ]] || info "$(pick '  Doména nebyla zadaná, takže 2) nejde vybrat.' '  No domain was provided, so option 2 is unavailable.')"
    ask CONNECT_N "$(pick 'Volba' 'Choice')" "$([[ -n "${DOMAIN:-}" ]] && echo 2 || echo 1)"
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
  FJ_PW=$(gen 32 24); JOIN_TOKEN=$(gen 48 40); DASH_TOKEN=$(gen 32 20); BROKER_SECRET=$(gen 64 56)
  # Forgejo bez SECRET_KEY + INSTALL_LOCK nabíhá do instalačního
  # průvodce a `forgejo admin ...` selže na MustInstalled().
  FJ_SECRET=$(gen 80 64)
  # Podpis webhooku a dočasná výchozí hodnota runner tokenu. Skutečný
  # registrační token vydá Forgejo po svém prvním startu níže.
  FJ_HOOK_SECRET=$(gen 48 40)
  RUNNER_SECRET=$(openssl rand -hex 20)

  ALLOW="chatgpt.com,api.anthropic.com,registry.npmjs.org,pypi.org,files.pythonhosted.org,codeload.github.com,github.com"
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
AGENTICDEV_LANG=$AGENTICDEV_LANG
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
GITHUB_CLIENT_ID='$(envq "${GITHUB_CLIENT_ID:-}")'

# ─── tajemství ───────────────────────────────────────────────
POSTGRES_PASSWORD=$PG_PW
MINIO_ROOT_PASSWORD=$MINIO_PW
JWT_SECRET=$JWT
WO_SIGNING_KEY_B64=$WO_PRIV
WO_VERIFY_KEY_B64=$WO_PUB
BROKER_SECRET=$BROKER_SECRET
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
PROVIDER_ALLOWLIST=claude,codex
CLAUDE_MODEL_POLICY=
CODEX_MODEL_POLICY=
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
  add AGENTICDEV_LANG        "$AGENTICDEV_LANG"
  add LEASE_HOURS       4
  add ENROLL_PASSWORD   "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)"
  add TS_AUTHKEY        ""
  add TS_API_KEY        ""
  add TS_TAILNET        "-"
  add FORGEJO_SECRET_KEY "$(openssl rand -base64 80 | tr -d '\n=+/' | cut -c1-64)"
  add FORGEJO_HOOK_SECRET "$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-40)"
  add RUNNER_SECRET     "$(openssl rand -hex 20)"
  add RUNNER_TAG        6
  add PROVIDER_ALLOWLIST "claude,codex"
  add CLAUDE_MODEL_POLICY ""
  add CODEX_MODEL_POLICY ""
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

if ! grep -q '^BROKER_SECRET=..' "$ENVF"; then
  printf 'BROKER_SECRET=%s\n' "$(openssl rand -hex 32)" >>"$ENVF"
  chmod 600 "$ENVF"
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
if [[ "$AGENTICDEV_MODE" == "public" ]]; then
  dc restart caddy >>"$LOG" 2>&1 || die "Caddy nenačetlo aktuální konfiguraci"
fi

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

# Sandbox projekt narovnat na tuhle instanci a skutečnou adresu gitu.
# Model spravuje zvolené osobní subscription CLI. V seedu je zástupné 'vps', které se nikde
# nepřeloží — bez tohohle by první klik na ikonu skončil u repozitáře,
# ke kterému se nedá připojit.
dc exec -T postgres psql -qtAX -U agenticdev -d agenticdev -c \
  "UPDATE project
      SET model_allowlist = NULL,
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

# Registrační token runneru vydává Forgejo; náhodný secret autentizaci
# nesplní. Vytvoř ho až po startu Forgeja a jen dokud runner nemá svůj
# persistentní registrační soubor, aby upgrade nezakládal duplicity.
if [[ ! -s "$ROOT/data/runner/.runner" ]] \
   || grep -q '"id"[[:space:]]*:[[:space:]]*0' "$ROOT/data/runner/.runner"; then
  RUNNER_TOKEN=$(dc exec -T -u git forgejo forgejo actions generate-runner-token \
                 2>/dev/null | tr -d '\r\n' || true)
  if [[ -n "$RUNNER_TOKEN" ]]; then
    sed -i "s|^RUNNER_SECRET=.*|RUNNER_SECRET=$RUNNER_TOKEN|" "$ENVF"
    RUNNER_SECRET=$RUNNER_TOKEN
    rm -f "$ROOT/data/runner/.runner"
    run "registrace runneru     " bash -c \
      "cd '$SRC/vps' && docker compose $PROFILE_ARGS --env-file $ENVF up -d --force-recreate runner"
  else
    warn "Forgejo nevydalo registrační token runneru"
  fi
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
if [[ ! -f "$ROOT/config/broker_git_key" ]]; then
  ssh-keygen -q -t ed25519 -N '' -C agenticdev-broker -f "$ROOT/config/broker_git_key"
fi
chmod 600 "$ROOT/config/broker_git_key"; chmod 644 "$ROOT/config/broker_git_key.pub"
ssh-keyscan -p 2222 "$VPS_HOST" >"$ROOT/config/broker_known_hosts" 2>>"$LOG" \
  || die "nelze připnout Forgejo SSH host key pro broker"
chmod 600 "$ROOT/config/broker_known_hosts"
if [[ -n "${FORGEJO_TOKEN:-}" ]]; then
  PUB=$(cat "$ROOT/config/broker_git_key.pub")
  if ! curl -fsS "http://$VPS_HOST:3000/api/v1/user/keys" -H "Authorization: token $FORGEJO_TOKEN" \
       | jq -e --arg k "$PUB" 'any(.[]; .key == $k)' >/dev/null; then
    curl -fsS -X POST "http://$VPS_HOST:3000/api/v1/user/keys" \
      -H "Authorization: token $FORGEJO_TOKEN" -H 'content-type: application/json' \
      -d "$(jq -nc --arg t agenticdev-broker --arg k "$PUB" '{title:$t,key:$k,read_only:false}')" \
      >/dev/null || die "Forgejo odmítlo broker Git key"
  fi
else
  die "FORGEJO_TOKEN chybí; broker nemůže bezpečně provisionovat Git"
fi
getent group agenticdev-broker >/dev/null || groupadd --system agenticdev-broker
for home in /home/*; do
  [[ -f "$home/.agenticdev/config" ]] || continue
  login=$(basename "$home")
  getent group docker >/dev/null && gpasswd -d "$login" docker >/dev/null 2>&1 || true
  getent group sudo >/dev/null && gpasswd -d "$login" sudo >/dev/null 2>&1 || true
  loginctl terminate-user "$login" >/dev/null 2>&1 || true
  usermod -aG agenticdev-broker "$login"
  id -nG "$login" | tr ' ' '\n' | grep -qx docker && die "$login zůstal v docker group"
  id -nG "$login" | tr ' ' '\n' | grep -qx sudo && die "$login zůstal v sudo group"
done
install -d -m 0755 /etc/systemd/system/containerd.service.d
install -m 0644 "$SRC/vps/containerd-agenticdev.conf" \
  /etc/systemd/system/containerd.service.d/agenticdev-socket.conf
[[ ! -S /var/run/docker.sock ]] || { chown root:docker /var/run/docker.sock; chmod 0660 /var/run/docker.sock; }
[[ ! -S /run/containerd/containerd.sock ]] || { chown root:root /run/containerd/containerd.sock; chmod 0600 /run/containerd/containerd.sock; }
install -d -m 0750 /usr/local/lib/agenticdev
install -d -m 0750 /var/lib/agenticdev-broker /srv/agenticdev/workloads /srv/agenticdev/repos /srv/agenticdev/identities
install -d -m 0770 -o root -g agenticdev-broker /run/agenticdev
install -m 0750 "$SRC/vps/broker.py" /usr/local/lib/agenticdev/broker.py
install -m 0755 "$SRC/vps/broker-client.py" /usr/local/bin/agenticdev-broker-client
install -m 0644 "$SRC/vps/agenticdev-broker.service" /etc/systemd/system/agenticdev-broker.service
docker build -t agenticdev/pod:installed "$SRC/pod" >>"$LOG" 2>&1
docker build -t agenticdev/egress:installed "$SRC/pod/egress" >>"$LOG" 2>&1
systemctl daemon-reload
systemctl enable agenticdev-broker.service >>"$LOG" 2>&1
systemctl restart agenticdev-broker.service >>"$LOG" 2>&1
systemctl is-active --quiet agenticdev-broker.service || die "privileged broker neběží"
for _ in $(seq 1 20); do [[ -S /run/agenticdev/broker.sock ]] && break; sleep 1; done
[[ -S /run/agenticdev/broker.sock ]] || die "broker socket nevznikl"
[[ "$(stat -c '%a %U %G' /run/agenticdev/broker.sock)" == "660 root agenticdev-broker" ]] \
  || die "broker socket má nebezpečná práva"
install -m 0755 "$SRC/vps/agenticdev-ctl" /usr/local/bin/agenticdev-ctl
install -m 0644 "$SRC/vps/agenticdev-enrollment.service" /etc/systemd/system/agenticdev-enrollment.service
install -m 0644 "$SRC/vps/agenticdev-enrollment.timer" /etc/systemd/system/agenticdev-enrollment.timer
systemctl daemon-reload
systemctl enable --now agenticdev-enrollment.timer >>"$LOG" 2>&1
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
  PANEL_NOTE="$(pick 'funguje z jakéhokoli prohlížeče — chrání ho tvoje heslo' 'works in any browser — protected by your password')"
else
  PANEL_URL="$CP"
  PANEL_NOTE="$(pick 'jen z tailnetu; nejdřív si připoj stroj odkazem pro tým' 'tailnet only; enroll your workstation first')"
fi
if [[ "$AGENTICDEV_LANG" == en ]]; then
  cat <<EOF

  ${GRN}╔═══════════════════════════════════════════════════════╗
  ║   DONE. The platform is running.                      ║
  ╚═══════════════════════════════════════════════════════╝${OFF}

  ${BLU}1) ADMIN PANEL${OFF} — $PANEL_NOTE
     ${YLW}$PANEL_URL${OFF}
     administrator: $ADMIN_NAME <$ADMIN_EMAIL>
     password: ${YLW}the ADMIN password you entered${OFF}

  ${BLU}2) TEAM ENROLLMENT LINK${OFF} — send it to anyone joining the instance
     ${YLW}${JOIN_URL:-(not available; see the warning above)}${OFF}

     They enter the JOIN password and follow the page. It supports macOS,
     Linux and Windows. Send the public link and private password separately.

  ${BLU}3) PERSONAL MODEL LOGIN${OFF}
     Each person runs ${YLW}agenticdev${OFF}, selects Claude Code or Codex and
     signs in with their own Claude/ChatGPT subscription. Credentials stay in
     that person's Linux home and are never stored in the administration panel.

  ${BLU}4) GIT${OFF}
     ${FORGEJO_ROOT_URL:-http://$VPS_HOST:3000/}
     $FORGEJO_ADMIN_USER / ${YLW}$FORGEJO_ADMIN_PASSWORD${OFF}

  ${YLW}Back up outside this server:${OFF}
     $ENVF        ${DIM}(especially WO_SIGNING_KEY_B64)${OFF}

  ${DIM}Show this again:  agenticdev-info
  Operations:       agenticdev-ctl status | update --check | logs | backup-now${OFF}

EOF
else
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

  ${BLU}3) OSOBNÍ PŘIHLÁŠENÍ K MODELŮM${OFF}
     Každý spustí ${YLW}agenticdev${OFF}, vybere Claude Code nebo Codex a přihlásí
     vlastní Claude/ChatGPT subscription. Údaje zůstávají v jeho linuxovém
     domově a nikdy se neukládají do administračního panelu.

  ${BLU}4) GIT${OFF}
     ${FORGEJO_ROOT_URL:-http://$VPS_HOST:3000/}
     $FORGEJO_ADMIN_USER / ${YLW}$FORGEJO_ADMIN_PASSWORD${OFF}

  ${YLW}Zazálohuj si mimo tenhle stroj:${OFF}
     $ENVF        ${DIM}(hlavně WO_SIGNING_KEY_B64)${OFF}

  ${DIM}Tenhle výpis znovu:  agenticdev-info
  Obsluha:             agenticdev-ctl status | update --check | logs | backup-now${OFF}

EOF
fi
info "subscription credentials zůstávají v osobním ~/.claude nebo ~/.codex"
[[ "$AGENTICDEV_MODE" == "tailnet" ]] && \
  info "Bez domény jede platforma jen po tailnetu. Doménu doplníš do $ENVF (AGENTICDEV_DOMAIN, AGENTICDEV_MODE=public) a pustíš 'agenticdev-ctl up'."

exit 0
#__AGENTICDEV_PAYLOAD_BELOW__
