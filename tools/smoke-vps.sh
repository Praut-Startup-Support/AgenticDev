#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  AgenticDev — smoke test nasazené platformy
#
#  Pusť PO instalaci, na VPS:
#      agenticdev-ctl smoke
#      bash tools/smoke-vps.sh          (totéž ručně)
#
#  Nekontroluje, že soubory existují — to dělá verify-tree. Kontroluje,
#  že platforma opravdu DĚLÁ, co má: vydá work order, podepíše ho,
#  zapíše do ledgeru, odmítne cizí heslo a nepustí do ledgeru přepis.
#
#  Nedestruktivní: co si založí, to po sobě uklidí. Ledger se nemaže —
#  je append-only, a to je jedna z věcí, kterou tenhle test ověřuje.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

ENVF="${AGENTICDEV_ENV:-/srv/agenticdev/config/.env}"
SRC="${AGENTICDEV_SRC:-/srv/agenticdev/src}"

G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; B='\033[1;36m'; D='\033[2m'; O='\033[0m'
pass=0; fail=0; skip=0
ok()   { printf "${G}  ✓${O} %s\n" "$*"; pass=$((pass+1)); }
bad()  { printf "${R}  ✗${O} %s\n" "$*"; fail=$((fail+1)); }
warn() { printf "${Y}  !${O} %s\n" "$*"; skip=$((skip+1)); }
info() { printf "${D}    %s${O}\n" "$*"; }
hdr()  { printf "\n${B}▸ %s${O}\n" "$*"; }

[[ -r "$ENVF" ]] || { printf "${R}✗ nenašel jsem %s — platforma není nainstalovaná${O}\n" "$ENVF"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$ENVF"; set +a

CP="${CONTROL_PLANE_URL:-http://${VPS_HOST}:8080}"
API="http://${VPS_HOST}:8080"          # napřímo, bez Caddy
PROFILE=(--profile gate)
[[ "${AGENTICDEV_MODE:-tailnet}" == "public" ]] && PROFILE+=(--profile public)
dc() { (cd "$SRC/vps" && docker compose "${PROFILE[@]}" --env-file "$ENVF" "$@"); }
psqlq() { dc exec -T postgres psql -qtAX -U agenticdev -d agenticdev -c "$1" 2>&1; }
jqr() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null; }

printf "\n  AgenticDev — smoke test\n"
printf "  ${D}instance %s · %s${O}\n" "${AGENTICDEV_INSTANCE_ID:0:8}" "$CP"

# ═══ 1. Služby ═════════════════════════════════════════════════
hdr "Služby"
for svc in postgres control-plane; do
  st=$(dc ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk -v s="$svc" '$1==s{print $2}')
  [[ "$st" == "running" ]] && ok "$svc běží" || bad "$svc není running (${st:-chybí})"
done
for svc in forgejo minio; do
  st=$(dc ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk -v s="$svc" '$1==s{print $2}')
  [[ "$st" == "running" ]] && ok "$svc běží" || warn "$svc není running (${st:-chybí})"
done

# ═══ 2. Control plane ══════════════════════════════════════════
hdr "Control plane"
curl -fsS --max-time 10 "$API/v1/health" >/dev/null 2>&1 \
  && ok "health odpovídá" || bad "health neodpovídá na $API"

IDENT=$(curl -fsS --max-time 10 "$API/v1/identity" 2>/dev/null)
FP=$(printf '%s' "$IDENT" | sed -n 's/.*"fingerprint"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
EXP="sha256:$(printf '%s\n%s' "${AGENTICDEV_INSTANCE_ID:-}" "${WO_VERIFY_KEY_B64:-}" | sha256sum | cut -d' ' -f1)"
if [[ -n "$FP" && "$FP" == "$EXP" ]]; then
  ok "fingerprint instance souhlasí s .env"
  info "instalátory se proti cizímu serveru odmítnou nainstalovat"
else
  bad "fingerprint nesouhlasí — instalátory Macu budou hlásit jiný VPS"
fi

# ═══ 3. Migrace a schéma ═══════════════════════════════════════
hdr "Databáze"
[[ "$(psqlq 'SELECT 1')" == "1" ]] && ok "postgres odpovídá" || bad "postgres neodpovídá"

TBL=$(psqlq "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
[[ "${TBL:-0}" -ge 18 ]] && ok "schéma nasazené ($TBL tabulek)" || bad "schéma nesedí ($TBL tabulek)"

RULES=$(psqlq "SELECT count(*) FROM pg_rules WHERE tablename='event'")
if [[ "${RULES:-1}" == "0" ]]; then
  ok "event nemá pravidla — zápis do ledgeru projde"
else
  bad "event má $RULES pravidel: ON CONFLICT selže a NIC se nezapíše do ledgeru"
  info "spusť: agenticdev-ctl restart control-plane (migrace to spraví)"
fi

TRG=$(psqlq "SELECT count(*) FROM pg_trigger WHERE tgrelid='event'::regclass AND tgname IN ('event_no_change','event_no_truncate')")
[[ "${TRG:-0}" == "2" ]] && ok "ledger je append-only (trigger)" \
  || bad "chybí trigger append-only na event ($TRG/2)"

# ═══ 4. Auditní stopa opravdu drží ═════════════════════════════
hdr "Auditní stopa"
KEY="smoke-$(date +%s)-$$"
INS=$(psqlq "INSERT INTO event (subject_type,subject_id,verb,payload,dedupe_key)
             VALUES ('smoke','$KEY','tested','{}','$KEY') RETURNING left(hash,12)")
if [[ "$INS" =~ ^[0-9a-f]{12}$ ]]; then
  ok "zápis do ledgeru prošel, hash $INS"
else
  bad "zápis do ledgeru selhal: $INS"
fi

DUP=$(psqlq "INSERT INTO event (subject_type,subject_id,verb,payload,dedupe_key)
             VALUES ('smoke','$KEY','tested','{}','$KEY') ON CONFLICT DO NOTHING")
[[ -z "$DUP" || "$DUP" == "INSERT 0 0" ]] && ok "opakovaný zápis se nezduplikuje (idempotence)" \
  || bad "idempotence nefunguje: $DUP"

UPD=$(psqlq "UPDATE event SET verb='tampered' WHERE dedupe_key='$KEY'")
echo "$UPD" | grep -q "append-only" && ok "přepis záznamu databáze odmítla" \
  || bad "záznam v ledgeru šel přepsat — auditní stopa negarantuje nic"

DEL=$(psqlq "DELETE FROM event WHERE dedupe_key='$KEY'")
echo "$DEL" | grep -q "append-only" && ok "smazání záznamu databáze odmítla" \
  || bad "záznam v ledgeru šel smazat"

CHAIN=$(psqlq "SELECT count(*) FROM event e
               WHERE e.prev_hash <> COALESCE(
                 (SELECT p.hash FROM event p WHERE p.seq < e.seq ORDER BY p.seq DESC LIMIT 1),
                 repeat('0',64))")
[[ "${CHAIN:-1}" == "0" ]] && ok "řetěz hashů je celý" \
  || bad "$CHAIN záznamů má rozbitý předchůdce"

# ═══ 5. Registrace ═════════════════════════════════════════════
hdr "Registrace strojů"
curl -fsS --max-time 10 "$API/join/health" >/dev/null 2>&1 \
  && ok "/join/health odpovídá" || bad "/join/health neodpovídá"

code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$API/join/api" \
       -H 'content-type: application/json' -d '{"password":"rozhodne-spatne-heslo"}' 2>/dev/null)
[[ "$code" == "401" ]] && ok "špatné heslo odmítnuto (401)" || bad "špatné heslo vrátilo $code, čekal jsem 401"

if [[ -n "${ENROLL_PASSWORD:-}" ]]; then
  # Správné heslo bez identity musí projít neúspěchem: bez jména a e-mailu
  # by v evidenci skončilo prázdno a agent by neměl čím commitovat.
  code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$API/join/api" \
         -H 'content-type: application/json' \
         -d "$(printf '{"password":"%s"}' "$ENROLL_PASSWORD")" 2>/dev/null)
  [[ "$code" == "400" ]] && ok "registrace bez jména a e-mailu odmítnuta (400)" \
    || bad "registrace bez identity vrátila $code, čekal jsem 400"

  JOINED=$(curl -sS --max-time 10 -X POST "$API/join/api" -H 'content-type: application/json' \
           -d "$(printf '{"password":"%s","first_name":"Smoke","last_name":"Test","email":"smoke@example.com"}' \
                 "$ENROLL_PASSWORD")" 2>/dev/null)
  if printf '%s' "$JOINED" | grep -q '"ok":true'; then
    ok "správné heslo projde"
    printf '%s' "$JOINED" | grep -q '"have_installer":true' \
      && ok "instalátor Macu je vygenerovaný" \
      || warn "instalátor Macu chybí — spusť: agenticdev-ctl mac"
  else
    bad "správné heslo neprošlo: $(printf '%s' "$JOINED" | head -c 120)"
  fi
else
  warn "ENROLL_PASSWORD není v .env — registraci nezkusím"
fi

# Zvenčí smí být vidět jen registrace.
code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" -H 'Tailscale-Funnel-Request: ?1' \
       "$API/v1/identity" 2>/dev/null)
[[ "$code" == "404" ]] && ok "zvenčí (Funnel) je API zavřené" \
  || bad "přes Funnel je vidět /v1/identity (HTTP $code) — mělo být 404"

# ═══ 6. Panel ══════════════════════════════════════════════════
hdr "Admin panel"
CK=$(mktemp); trap 'rm -f "$CK"' EXIT
if [[ -n "${DASHBOARD_TOKEN:-}" ]]; then
  code=$(curl -sS --max-time 10 -c "$CK" -o /dev/null -w "%{http_code}" -X POST "$API/v1/auth/dashboard" \
         -H 'content-type: application/json' -d "$(printf '{"token":"%s"}' "$DASHBOARD_TOKEN")" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    ok "přihlášení do panelu funguje"
    curl -fsS --max-time 10 -b "$CK" "$API/v1/board" >/dev/null 2>&1 \
      && ok "nástěnka se načte" || bad "nástěnka nevrací data"
    S=$(curl -fsS --max-time 10 -b "$CK" "$API/v1/settings" 2>/dev/null)
    printf '%s' "$S" | grep -q '"fields"' && ok "nastavení se načte" || bad "nastavení nevrací data"
    printf '%s' "$S" | grep -q '"secret":true' \
      && ok "tajemství jsou v panelu maskovaná" || warn "nenašel jsem maskovaná pole"
  else
    bad "přihlášení do panelu vrátilo $code"
  fi
else
  warn "DASHBOARD_TOKEN není v .env — panel nezkusím"
fi

# ═══ 7. Work order ═════════════════════════════════════════════
hdr "Vydání work orderu"
FPRINT="SHA256:smoke$(date +%s)"
REG=$(curl -sS --max-time 15 -X POST "$API/v1/workstations/register" \
      -H 'content-type: application/json' \
      -d "$(printf '{"join_token":"%s","hostname":"smoke-test","device_key_fp":"%s","display_name":"Smoke Test"}' \
            "${JOIN_TOKEN:-}" "$FPRINT")" 2>/dev/null)
WSID=$(printf '%s' "$REG" | sed -n 's/.*"workstation_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [[ -z "$WSID" ]]; then
  bad "zkušební stanici nešlo zaregistrovat: $(printf '%s' "$REG" | head -c 120)"
else
  ok "zkušební stanice zaregistrovaná"
  TOK=$(curl -sS --max-time 10 -X POST "$API/v1/auth/device" -H 'content-type: application/json' \
        -d "$(printf '{"hostname":"smoke-test","device_key_fp":"%s"}' "$FPRINT")" 2>/dev/null \
        | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [[ -n "$TOK" ]] && ok "stanice se přihlásí device keyem" || bad "přihlášení stanice selhalo"

  if [[ -n "$TOK" ]]; then
    WO=$(curl -sS --max-time 15 "$API/v1/work-orders/next" -H "Authorization: Bearer $TOK" 2>/dev/null)
    if printf '%s' "$WO" | grep -q '"work_order":null'; then
      warn "žádný úkol ve stavu ready — work order se nevydal"
      info "založ úkol v panelu, nebo použij seedovaný projekt sandbox"
    elif printf '%s' "$WO" | grep -q '"signature"'; then
      ok "work order vydán a podepsán"
      # Podpis musí projít stejným veřejným klíčem, jaký dostávají klienti.
      # Work order jde do souboru, ne do roury: heredoc se skriptem zabírá
      # pythonu stdin, takže by z něj `json.load` nic nepřečetl.
      WOF=$(mktemp); printf '%s' "$WO" >"$WOF"
      if WO_VERIFY_KEY_B64="${WO_VERIFY_KEY_B64:-}" WOF="$WOF" python3 - <<'PY' 2>/dev/null
import base64, json, os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
wo = json.load(open(os.environ["WOF"]))["work_order"]
sig = base64.b64decode(wo.pop("signature").split(":", 1)[1])
payload = json.dumps(wo, sort_keys=True, separators=(",", ":")).encode()
Ed25519PublicKey.from_public_bytes(
    base64.b64decode(os.environ["WO_VERIFY_KEY_B64"])).verify(sig, payload)
PY
      then ok "podpis work orderu se ověří veřejným klíčem"
      else bad "podpis work orderu NEPROJDE ověřením"
      fi
      rm -f "$WOF"
      WOID=$(printf '%s' "$WO" | sed -n 's/.*"work_order_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      curl -fsS --max-time 10 -X POST "$API/v1/work-orders/$WOID/heartbeat" \
           -H "Authorization: Bearer $TOK" >/dev/null 2>&1 \
        && ok "heartbeat prodlouží lease" || bad "heartbeat selhal"
      curl -fsS --max-time 10 -X POST "$API/v1/work-orders/$WOID/release?outcome=aborted" \
           -H "Authorization: Bearer $TOK" >/dev/null 2>&1 \
        && ok "release vrátí úkol" || warn "release selhal — úkol zůstal přidělený"
    else
      bad "work order se nevydal: $(printf '%s' "$WO" | head -c 160)"
    fi
  fi
fi

# ═══ 8. Pracovní prostředí ═════════════════════════════════════
hdr "Workspace pro stanice"
if [[ -n "${TOK:-}" ]]; then
  PROJ=$(curl -fsS --max-time 10 "$API/v1/workspace/projects" -H "Authorization: Bearer $TOK" 2>/dev/null \
         | python3 -c "import json,sys
p=json.load(sys.stdin).get('projects') or []
print(p[0]['code'] if p else '')" 2>/dev/null)
  if [[ -n "$PROJ" ]]; then
    ok "seznam projektů se načte (první: $PROJ)"
    for ph in discovery design implementation hardening delivery support; do
      # Pozor na jména proměnných: B, R, G, Y, D a O drží barvy. Bundle je
      # velký JSON a kdyby přepsal barvu, prošel by printf jako formát.
      BUNDLE=$(curl -sS --max-time 10 "$API/v1/workspace/$PROJ/bundle?phase=$ph" \
               -H "Authorization: Bearer $TOK" 2>/dev/null)
      if printf '%s' "$BUNDLE" | grep -q '"scope"'; then
        ok "$(printf 'fáze %-15s scope: %s' "$ph" \
              "$(printf '%s' "$BUNDLE" | python3 -c "import json,sys;print(', '.join(json.load(sys.stdin)['scope']))" 2>/dev/null)")"
      else
        bad "fáze $ph nevrátila scope: $(printf '%s' "$BUNDLE" | head -c 100)"
      fi
    done

    # Bez jména a e-mailu spadne agentovi v podu každý commit na
    # "Author identity unknown" — v podu žádný ~/.gitconfig není.
    AUTHOR=$(printf '%s' "$BUNDLE" | python3 -c "
import json,sys
a=json.load(sys.stdin).get('author') or {}
print(f\"{a.get('name','')}|{a.get('email','')}\")" 2>/dev/null)
    if [[ "$AUTHOR" == *"|"* && "${AUTHOR%%|*}" != "" && "${AUTHOR##*|}" != "" ]]; then
      ok "bundle nese podpis commitů (${AUTHOR%%|*} <${AUTHOR##*|}>)"
    else
      bad "bundle nenese autora — agent nebude mít čím commitovat"
    fi

    # Model je součást sdíleného prostředí, ne osobního přihlášení: kdyby si
    # každý bral to, co má ve svém předplatném, dostali by dva lidé na
    # stejné zadání jinou odpověď a nešlo by to srovnat.
    PINNED=$(printf '%s' "$BUNDLE" | python3 -c "
import json,sys
b=json.load(sys.stdin)
s=json.loads((b.get('files') or {}).get('.pi/settings.json') or '{}')
print(', '.join(s.get('enabledModels') or []))" 2>/dev/null)
    if [[ -n "$PINNED" ]]; then
      ok "bundle přišpendluje model všem stejně ($PINNED)"
    else
      bad "bundle nepřišpendluje model — každý pojede na tom, co má v předplatném"
    fi
  else
    warn "žádný projekt — workspace nezkusím"
  fi
else
  warn "bez tokenu stanice workspace nezkusím"
fi

# ═══ 8a. Brána před mergem ═════════════════════════════════════
hdr "Brána před mergem"
st=$(dc ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="runner"{print $2}')
[[ "$st" == "running" ]] && ok "runner běží" \
  || warn "runner není running (${st:-chybí}) — workflow projektů nemá kdo spustit"

if [[ -n "${FORGEJO_HOOK_SECRET:-}" ]]; then
  ok "podpis webhooku je nastavený"
  # Nepodepsaný požadavek musí odletět: jinak by kdokoli na tailnetu mohl
  # označovat úkoly za hotové.
  code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" -X POST "$API/v1/hooks/forgejo" \
         -H 'content-type: application/json' -d '{"action":"closed"}' 2>/dev/null)
  [[ "$code" == "401" ]] && ok "webhook bez podpisu odmítnut (401)" \
    || bad "webhook bez podpisu vrátil $code — kdokoli může označit úkol za hotový"
else
  bad "FORGEJO_HOOK_SECRET chybí — úkol se po mergi nepřepne na hotovo"
  info "doplň ho do .env a spusť: agenticdev-ctl restart control-plane"
fi

# Tvar jmen commit statusů se z kódu vyčíst nedá — Forgejo je skládá jako
# „workflow / job (událost)". Požadovaný status, který se nikdy neobjeví,
# vypadá jako fungující brána a přitom drží merge zablokovaný navždycky.
if [[ -n "${PROJ:-}" && -f "$CK" ]]; then
  GATE=$(curl -fsS --max-time 20 -b "$CK" "$API/v1/projects/$PROJ/gate" 2>/dev/null || true)
  if [[ -n "$GATE" ]]; then
    V=$(printf '%s' "$GATE" | python3 -c "import json,sys;d=json.load(sys.stdin);print(('ok' if d['ok'] else 'ne')+'|'+d['verdict'])" 2>/dev/null)
    case "$V" in
      ok\|*)  ok "brána projektu $PROJ: ${V#*|}" ;;
      ne\|*)  warn "brána projektu $PROJ: ${V#*|}"
              info "podrobně: agenticdev-ctl gate $PROJ" ;;
      *)      warn "diagnostiku brány se nepodařilo přečíst" ;;
    esac
  else
    warn "diagnostika brány neodpověděla (Forgejo token? projekt bez repozitáře?)"
  fi
fi

# ═══ 8c. Záznam běhů a časová osa ══════════════════════════════
hdr "Co je vidět, když se něco stane"
if [[ -f "$CK" ]]; then
  BOARD=$(curl -fsS --max-time 10 -b "$CK" "$API/v1/board" 2>/dev/null || true)
  if [[ -n "$BOARD" ]]; then
    RUNS=$(printf '%s' "$BOARD" | jqr "['runs_total']")
    MEAS=$(printf '%s' "$BOARD" | jqr "['spend_measured']")
    if [[ "$RUNS" == "0" ]]; then
      warn "v ledgeru není žádný běh agenta — po prvním úkolu tu musí být aspoň 1"
      info "zapisuje ho harness na konci běhu (POST /v1/runs)"
    else
      ok "$RUNS běhů agenta v ledgeru"
    fi
    [[ "$MEAS" == "False" || "$MEAS" == "false" ]] \
      && info "útrata se neměří (tokeny neohlašuje nikdo) — panel to říká místo nuly"
  else
    warn "nástěnku se nepodařilo přečíst"
  fi

  # Časová osa musí odpovědět i pro úkol, se kterým se ještě nic nestalo.
  TID=$(curl -fsS --max-time 10 -b "$CK" "$API/v1/tasks" 2>/dev/null \
        | python3 -c "import json,sys
t=json.load(sys.stdin)
print(t[0]['id'] if t else '')" 2>/dev/null || true)
  if [[ -n "$TID" ]]; then
    TL=$(curl -fsS --max-time 10 -b "$CK" "$API/v1/tasks/$TID/timeline" 2>/dev/null || true)
    if printf '%s' "$TL" | grep -q '"totals"'; then
      ok "časová osa úkolu se načte ($(printf '%s' "$TL" | jqr "['totals']['runs']") běhů, $(printf '%s' "$TL" | python3 -c "import json,sys;print(len(json.load(sys.stdin)['events']))" 2>/dev/null) událostí)"
    else
      bad "časová osa nevrátila data: $(printf '%s' "$TL" | head -c 100)"
    fi
  else
    warn "žádný úkol — časovou osu nezkusím"
  fi

  # Panel je jeden HTML soubor s vloženým skriptem: jedna chyba v něm
  # neshodí obrazovku, ale celý skript, tedy i přihlášení. Přes API se to
  # nepozná, proto se to kontroluje tady.
  if command -v node >/dev/null 2>&1; then
    if (cd "$SRC" && python3 - <<'PY'
import pathlib, re, subprocess, sys
bad = 0
for f in sorted(pathlib.Path("control-plane/app").glob("*.html")):
    for i, s in enumerate(re.findall(r"<script>(.*?)</script>", f.read_text(), re.S)):
        p = pathlib.Path(f"/tmp/smoke-{f.stem}-{i}.js"); p.write_text(s)
        if subprocess.run(["node", "--check", str(p)], capture_output=True).returncode:
            print(f"  {f}", file=sys.stderr); bad = 1
sys.exit(bad)
PY
    ) 2>/dev/null; then
      ok "skript panelu se parsuje"
    else
      bad "skript panelu se NEPARSUJE — panel je v prohlížeči mrtvý včetně přihlášení"
    fi
  else
    info "node není na VPS — skript panelu nezkontroluju (dělá to CI)"
  fi
else
  warn "bez přihlášení do panelu tyhle kontroly nezkusím"
fi

# ═══ 8b. Pody se pouští na VPS ═════════════════════════════════
hdr "Launcher na VPS"
command -v agenticdev >/dev/null \
  && ok "agenticdev je v PATH" \
  || bad "agenticdev není nainstalovaný — pody se pouštějí na VPS (ADR-0005)"

# Bez skupiny docker člověk pod nespustí. Kontrolujeme účty, které mají
# konfiguraci od `agenticdev-ctl user add`.
PEOPLE=0; NODOCKER=""
for h in /home/*; do
  [[ -f "$h/.agenticdev/config" ]] || continue
  PEOPLE=$((PEOPLE+1))
  u=$(basename "$h")
  id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx docker || NODOCKER="$NODOCKER $u"
done
if (( PEOPLE == 0 )); then
  warn "na VPS nemá účet nikdo — 'agenticdev-ctl user add <login>'"
elif [[ -z "$NODOCKER" ]]; then
  ok "$PEOPLE lidí má účet i skupinu docker"
else
  bad "bez skupiny docker (pod nespustí):$NODOCKER"
fi

# ═══ 9. Úklid ══════════════════════════════════════════════════
# Až tady, ne dřív: token zkušební stanice potřebovaly kroky výš, a
# revokace ho okamžitě zneplatní. Stanice zůstane odebraná, ne smazaná —
# v ledgeru na ni vede záznam a mazat řádky, na které odkazuje auditní
# stopa, by bylo horší než nechat v seznamu jednu odebranou stanici.
if [[ -n "${WSID:-}" ]]; then
  psqlq "UPDATE workstation SET revoked_at = now() WHERE id = '$WSID'" >/dev/null
  hdr "Úklid"
  ok "zkušební stanice odebrána (zůstává v evidenci)"
fi

# ═══ 10. Nic nevisí na veřejné adrese ══════════════════════════
hdr "Porty na veřejné adrese"
if command -v ss >/dev/null; then
  LISTEN=$(ss -tlnH 2>/dev/null | awk '{print $4}' \
           | grep -E '^(0\.0\.0\.0|\*|\[::\])' | sed 's/.*://' | sort -un | tr '\n' ' ')
  if [[ "${AGENTICDEV_MODE:-tailnet}" == "public" ]]; then
    ALLOWED="22 80 443"
  else
    ALLOWED="22"
  fi
  EXTRA=""
  for p in $LISTEN; do grep -qw "$p" <<<"$ALLOWED" || EXTRA="$EXTRA $p"; done
  if [[ -z "$EXTRA" ]]; then
    ok "na všech adresách naslouchá jen: ${LISTEN:-nic}"
  else
    bad "navíc naslouchá na:$EXTRA (čekal jsem jen $ALLOWED)"
    info "databáze a MinIO mají být jen na tailnetu, viz VPS_HOST v compose"
  fi
else
  warn "chybí ss — porty nezkontroluji"
fi

# ═══ Výsledek ══════════════════════════════════════════════════
echo
printf "  ${D}%d prošlo · %d neprošlo · %d přeskočeno${O}\n" "$pass" "$fail" "$skip"
if (( fail )); then
  printf "\n${R}✗ Platforma není v pořádku.${O} Nahoře je vidět co.\n\n"
  exit 1
fi
printf "\n${G}✓ Platforma dělá, co má.${O}\n\n"
exit 0
