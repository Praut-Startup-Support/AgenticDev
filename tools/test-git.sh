#!/usr/bin/env bash
# Projede agenticdev-git na dočasném repozitáři. Nic nemaže mimo /tmp.
set -euo pipefail
PG="$(cd "$(dirname "$0")/.." && pwd)/workspace/_base/bin/agenticdev-git"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/o" "$T/w"
git init -q --bare "$T/o"
cd "$T/w" && git init -q -b main && git config user.email t@t.cz && git config user.name T
mkdir -p src tests && echo x > src/a.ts && echo x > tests/.keep
git add -A && git commit -qm init && git remote add origin "$T/o" && git push -qu origin main

export AGENTICDEV_SESSION=test-session
W=$("$PG" start "Import karet z DE systému" T-042 2>/dev/null)
[[ -d "$W" ]] || { echo "✗ start nevytvořil worktree"; exit 1; }
cd "$W"
[[ "$(git branch --show-current)" == task/T-042-* ]] || { echo "✗ špatná větev"; exit 1; }
echo "✓ start — worktree a větev s diakritikou"

echo b > src/b.ts && "$PG" checkpoint k1 >/dev/null 2>&1
echo c > src/c.ts && "$PG" checkpoint k2 >/dev/null 2>&1
[[ $(git log --oneline --grep='^wip(' | wc -l) -eq 2 ]] || { echo "✗ checkpointy"; exit 1; }
echo "✓ checkpointy"

echo t > tests/i.test.ts && "$PG" save feat import "karty z DE" >/dev/null 2>&1
echo "✓ save"

"$PG" finish "feat(import): karty z DE systému" >/dev/null 2>&1
B=$(git branch --show-current)
# Pozor: `finish` NEODESÍLÁ. Větev pushne a PR otevře launcher na hostiteli,
# protože agent nemá mít přístup k repozitáři. Kontroluje se proto lokální
# větev, ne `origin/$B` — ta v tuhle chvíli ještě neexistuje.
[[ $(git log --oneline "origin/main..HEAD" | wc -l) -eq 1 ]] \
  || { echo "✗ wip se nesesypaly"; exit 1; }
echo "✓ finish — wip sesypané do jednoho commitu"

[[ -f .agenticdev/finished ]] || { echo "✗ finish nenechal vzkaz pro launcher"; exit 1; }
python3 -c 'import json,sys; d=json.load(open(".agenticdev/finished")); sys.exit(0 if d["branch"] and d["base"] else 1)' \
  || { echo "✗ vzkaz pro launcher je neúplný"; exit 1; }
echo "✓ finish — vzkaz pro launcher (větev, base, titulek)"

# pozor: grep -q uzavře rouru a s pipefail to vypadá jako chyba — čteme do proměnné
OUT=$("$PG" who src/b.ts 2>&1)
[[ "$OUT" == *test-session* ]] || { echo "✗ provenance"; echo "$OUT"; exit 1; }
echo "✓ provenance přežila sesypání"

# ── konflikt nesmí nechat člověka v rozdělaném rebase ──
# Tohle je ta část, na které záleží u lidí, co git neumí: `sync` musí stav
# vrátit, ne ho nechat rozpůlený s instrukcí `git rebase --continue`.
( cd "$T/w" && git checkout -q main \
  && echo "kolize z main" > src/b.ts \
  && git add -A && git commit -qm "feat: kolizní změna" && git push -q origin main )

HEAD_BEFORE=$(git rev-parse HEAD)
set +e; "$PG" sync >/dev/null 2>&1; RC=$?; set -e
[[ "$RC" -ne 0 ]] || { echo "✗ sync konflikt neohlásil"; exit 1; }
[[ ! -d "$(git rev-parse --git-path rebase-merge)" && ! -d "$(git rev-parse --git-path rebase-apply)" ]] \
  || { echo "✗ sync nechal rozdělaný rebase"; exit 1; }
[[ "$(git rev-parse HEAD)" == "$HEAD_BEFORE" ]] \
  || { echo "✗ sync po konfliktu změnil HEAD — práce se mohla ztratit"; exit 1; }
echo "✓ konflikt — stav vrácen, práce zůstala"

# Kdo git umí, musí mít pořád cestu rozdělaný rebase dostat.
set +e; "$PG" sync --manual >/dev/null 2>&1; set -e
[[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]] \
  || { echo "✗ sync --manual rebase nenechal"; exit 1; }
git rebase --abort 2>/dev/null || true
echo "✓ sync --manual — rebase ponechán pro znalce gitu"

echo; echo "✓ VŠE PROŠLO"
