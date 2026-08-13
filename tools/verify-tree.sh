#!/usr/bin/env bash
fail=0
chk(){ if [[ -e "$1" ]]; then echo "  ✓ $2"; else echo "  ✗ CHYBÍ: $1"; fail=1; fi; }

echo "── VPS ──"
for f in vps/docker-compose.yml vps/Caddyfile vps/sql/001_schema.sql \
         vps/sql/002_seed.sql vps/backup/restic-backup.sh install-vps.sh \
         vps/mk-mac-installer.sh vps/agenticdev-ctl; do chk "$f" "$f"; done

echo "── control plane ──"
for f in control-plane/Dockerfile control-plane/requirements.txt control-plane/app/main.py \
         control-plane/app/admin.py control-plane/app/workspace.py \
         control-plane/app/dashboard.html control-plane/app/enroll.py \
         control-plane/app/join.html control-plane/app/settings.py \
         control-plane/app/migrate.py control-plane/app/ratelimit.py \
         control-plane/app/hooks.py; do chk "$f" "$f"; done

echo "── workspace (Pi) ──"
chk workspace/_base/AGENTS.md               "AGENTS.md"
chk workspace/_base/.pi/settings.json       "nastavení Pi"
chk workspace/_base/.pi/extensions/agenticdev-git.ts "git extension"
for s in git-flow kontext rozhodnuti; do
  chk "workspace/_base/.pi/skills/$s/SKILL.md" "skill $s"; done
chk workspace/_base/.pi/prompts/hotovo.md   "/hotovo"
chk workspace/_base/bin/agenticdev-git           "git automatizace"
chk workspace/_base/bin/agenticdev-decision      "zápis rozhodnutí"
# Každá fáze z enumu phase_kind musí mít scope — projekt přepnutý do fáze
# bez něj by launcher nesestavil a bundle by vracel 400.
for p in discovery design implementation hardening delivery support; do
  chk "workspace/_phase/$p/scope" "fáze $p"; done

echo "── značka ──"
for f in brand/logo.svg brand/mark.svg brand/icon.svg brand/agenticdev.ico; do chk "$f" "$f"; done

echo "── dokumenty ──"
chk HANDOFF.md              "handoff"
chk DEPLOY.md               "postup nasazení"
chk tools/rename-to-agenticdev.sh "přejmenování produktu"

echo "── nasazení ──"
chk tools/preflight-vps.sh  "preflight"
chk tools/smoke-vps.sh      "smoke test"

echo "── web ──"
chk site/index.html  "onepager"
chk site/CNAME       "doména"
chk site/logo.svg    "logo"

echo "── pod (sandbox) ──"
chk pod/compose.yaml          "compose"
chk pod/Dockerfile            "obraz podu"
chk pod/harness/harness.py    "harness"
chk pod/harness/director.py   "director (postup úkolu)"
chk pod/egress/Dockerfile     "obraz egress"
chk pod/egress/entrypoint.sh  "egress allowlist"

echo "── klienti ──"
chk install-mac.sh       "macOS"
chk install-linux.sh     "Linux"
chk install-windows.ps1  "Windows"
chk linux/agenticdev.desktop  "ikona na plochu"
chk linux/agenticdev-launch   "spouštěč"

echo "── Mac ──"
chk install-mac.sh "instalace"
chk launcher/agenticdev "launcher"

echo
[[ $fail -eq 0 ]] && echo "✓ VŠECHNY CESTY SEDÍ" || echo "✗ NĚCO CHYBÍ"
exit $fail
