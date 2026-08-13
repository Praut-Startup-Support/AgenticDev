# HANDOFF

Stav repozitáře a co s ním dál. Psáno pro chvíli, kdy někdo (člověk nebo
agent) dostane přístup k repu a má pokračovat.

Poslední aktualizace: 11. 8. 2026

---

## 1. Jak se produkt jmenuje

**Rozhodnuto: AgenticDev.** Sedí to v `LICENSE` (`Licensed Work`), v obou
README, v repozitáři, na webu i v doméně. `Licensed Work` je právní
identifikátor — kdyby se jméno měnilo, musí se změnit i tam, jinak je
licence napadnutelná. Licencor `Praut s.r.o.` se nemění nikdy.

---

## 2. Co nikdy neběželo

Serverová část už proti reálnému Postgresu a běžícímu control plane
běžela (viz sekci 3). Tohle je zbytek, který pořád stojí jen na tom, že
se kód parsuje:

| Co | Riziko |
|---|---|
| **Sandbox (pod)** | mounty, proxy a uid nikdy neběžely proti Dockeru |
| **Windows klient** | WSL2 cesta, `wslpath`, zástupce s ikonou |
| **Linux klient** | detekce správce balíčků, ikona v nabídce |
| **Tailscale Funnel** | vystavení `/join` zvenčí, mapování cest, auth key |
| **Caddy v režimu public** | vydání certifikátu, `handle` bloky |
| **Ikony** | `.icns` se generuje až na macOS přes `iconutil` |
| **Release workflow** | podpis přes cosign, reprodukovatelnost v CI |

**Testovat v tomhle pořadí** — každý krok staví na předchozím:

1. `bash tools/preflight-vps.sh` na čistém VPS
2. Server podle [DEPLOY.md](DEPLOY.md), bez znalostí navíc
3. `agenticdev-ctl smoke` — musí projít celý
3b. `agenticdev-ctl gate <projekt>` — na prvním PR. Musí ukázat, že se
   požadovaná jména statusů potkávají s vydanými. Když ne, `--fix` a znovu.
4. `curl https://<host>.ts.net:8443/health` z mobilních dat (ne z tailnetu).
   Funnel připojuje `/join` na korytko `/`, takže veřejná cesta ke
   health je `/health`, ne `/join/health`.
5. Registrační stránka v prohlížeči, špatné heslo, pak správné
6. macOS klient až do ikony na ploše
7. Klik na ikonu → naběhne pod → agent odpoví
8. Zápis mimo scope musí selhat na EROFS
9. Linux klient, Windows klient
10. `git tag v0.1.0` → workflow → draft release → **publikovat ho**.
    Dokud je release draft, `releases/latest/download/…` vrací 404 a
    instalace podle README nefunguje nikomu.

---

## 3. Co je hotové a ověřené

- Build je **reprodukovatelný** — dvě sestavení dala stejný součet
- `make verify` projde, všech 19 shell skriptů se parsuje
- Schéma se nasadí na čistý Postgres 16 s pgvectorem beze změn
- Proti běžícímu control plane prošlo 38 kontrol `tools/smoke-vps.sh`:
  zápis do ledgeru, idempotence, odmítnutí přepisu i smazání, celistvost
  řetězu hashů, registrace stroje, přihlášení device keyem, vydání work
  orderu, **ověření jeho ed25519 podpisu**, heartbeat, release, scope
  všech šesti fází, panel a maskování tajemství
- Registrace: špatné heslo 401, po pěti pokusech 429, IP zamčená
- Přihlášení do panelu má stejné omezení pokusů (dřív žádné nemělo)
- 12 vlastností izolace ověřeno proti `pod/compose.yaml`
- V dokumentaci nezbyly odkazy na neexistující cesty

---

## 4. Známé díry, vědomě ponechané

Jsou popsané v README i SECURITY.md. Nejsou to překvapení, ale nedělej,
že tam nejsou:

| Díra | Dopad |
|---|---|
| Brána před mergem neběžela proti živému Forgeju | `agenticdev-ctl gate <projekt>` ji změří, ale dokud neuvidíš červenou kontrolu zablokovat merge, není to dokázané |
| Repozitář bez testů projde branou nazeleno | prázdná brána není brána; workflow to hlásí jen jako varování v logu |
| Orchestrační vrstva (directors) neexistuje | postup vynucují kontroly projektu v harnessu (ADR-0003) |
| Join heslo nemá expiraci | odvolání = změna hesla všem |
| Útrata se neměří | tokeny neohlašuje nikdo; `cost_czk` je 0 a panel píše „neměří se" místo `0 Kč`. `PRICING` v kódu nikdy nebyla, `len/3` je rozpočtová brána na kontext |
| Chybí metriky a trace | Grafana, Loki, Prometheus, Tempo zakomentované. Ledger, `agent_run`, transkripty a časová osa úkolu ale fungují |

Pořadí, v jakém by se to mělo řešit, je v README v sekci o omezeních.

---

## 5. Drobnosti k dodělání

- [x] `site/index.html` — ID formuláře doplněné, workflow projde
- [ ] DNS: `CNAME agenticdev → praut-startup-support.github.io.` (pozor: jméno účtu, ne produktu — dřív tu stálo `agenticdev-startup-support`, což je účet, který neexistuje)
- [ ] Settings → Pages → Source: **GitHub Actions**
- [ ] Settings → Actions → Workflow permissions: **Read and write**
- [ ] Topics a Website v About na GitHubu
- [ ] **Licenci nechat projít právníkem** — BSL s příjmovou hranicí je obchodní
      rozhodnutí, ne technické. Nově je v `Additional Use Grant` i podmínka
      uvedení autora (bod b); ta je napsaná tak, aby její porušení ukončilo
      bezplatný grant, ale formulaci ať vidí právník, než na ni někoho
      upozorníš. Platí od té verze, ve které vyšla — dřív vydané verze si
      nesou podmínky, se kterými byly vydané.

---

## 6. Věci, na které si dát pozor při úpravách

**`agenticdev-git` a worktree.** V podu je kořen repozitáře `/workspace`, takže
`dirname` vyjde na `/`. Proto existuje proměnná `AGENTICDEV_TREES`, kterou
launcher nastaví na adresář připojený z hostitele. Kdyby ji někdo odstranil,
rozdělaná práce se bude ztrácet při každém teardownu a nikdo si toho hned
nevšimne.

**Scope vynucují mounty, ne instrukce.** Když přidáš fázi, `scope` soubor
není doporučení — launcher podle něj staví `compose.override.yaml`. Fáze bez
`scope` znamená pod, ve kterém nejde zapsat nikam.

**Egress allowlist je allowlist.** `FilterDefaultDeny Yes` v tinyproxy je to
podstatné. Bez něj by se z toho stal blocklist a všechno neuvedené by prošlo.

**Jméno commit statusu si nevymýšlej.** Forgejo Actions statusy jmenuje
`<workflow> / <job> (<událost>)`, tedy `test / test (pull_request)`. V
branch protection je proto glob `test / *`, ne `test`. Dřív tam bylo
`test` — to se nepotká s ničím, a požadovaný status, který nikdy nepřijde,
drží merge zablokovaný **navždycky**, přičemž v panelu to vypadá jako
funkční brána. Kdyby to nějaká verze pojmenovala jinak, `agenticdev-ctl
gate <projekt>` vypíše skutečná jména a `--fix` je nasadí.

**Workflow potřebuje i importovaný projekt.** Dřív se zakládalo jen u nově
vytvořeného repozitáře, ale branch protection se nasazuje vždycky — takže
v importovaném projektu se čekalo na status, který nikdo nevydá, a nešlo
smergovat vůbec nic. Zakládá se proto v obou cestách, a až po zjištění
majitele: se špatným majitelem v cestě zápis tiše selže.

**Harness odmítne nastartovat**, když je kořen workspace zapisovatelný nebo
chybí proxy. To je záměr — špatně nastavený sandbox má spadnout nahlas, ne
tiše nechránit nic.

**Dokumentace popisovala věci, které v kódu nebyly.** Stalo se to opakovaně
(pod, harness, egress-proxy, directors, `.claude/settings.json`). Než něco
napíšeš do README, ověř `grep`em, že to existuje.

**`BIND_ADDR` je ta nejostřejší hrana celého nasazení.** Na téhle adrese
poslouchá Postgres, Forgejo a MinIO. `0.0.0.0` nebo veřejná adresa znamená
ledger na internetu. Default je `${VPS_HOST}`, aby starší `.env` fungoval
bez úpravy; v režimu `domain` to instalátor nastaví na `127.0.0.1` a
nedovozuje to odnikud — natvrdo, protože chyba v odvození by tady byla
nejdražší v celém projektu. `smoke` to kontroluje z konfigurace **i** ze
skutečných soketů (`ss -tln`).

**Bez Tailscale nikdo neautentizuje SSH za tebe.** `tailscale up --ssh`
je to, co dnes lidem dovoluje přihlásit se bez jakéhokoli klíče. V režimu
`domain` to padá na obyčejné SSH, takže veřejný klíč každého člověka musí
někdo zapsat do `authorized_keys`: `agenticdev-ctl keys add <login> "<klíč>"`,
nebo automaticky z registrace přes `keys sync`. **Control plane to nedělá a
dělat nemá** — běží v kontejneru, do `/home` nedosáhne, a kdyby dosáhl, měl
by cestu k rootu. Kdo to bude chtít „zjednodušit" tak, že to zapíše control
plane, ruší tím jednu z hranic, na kterých platforma stojí.

**Režim se zapéká i do klientského instalátoru.** `__CONNECT__` dosazuje
`enroll.py` (`_fill`) u Linuxu a Windows, a `mk-mac-installer.sh` u Macu.
Kdyby se to někde vynechalo, instalátor by na doménové instanci sháněl
tailnet, který neexistuje, a skončil by na tom.

**Panel je jeden HTML soubor s jedním `<script>`.** Jedna syntaktická chyba
v něm neshodí jednu obrazovku, ale celý skript — tedy i přihlášení. Přesně
tak tam ležel `const esc` vedle `function esc()`: v jednom scope je to
`SyntaxError`, panel byl v prohlížeči mrtvý a přes API se to nepoznalo,
protože smoke test panel testuje curlem. Kontroluje to teď CI (`Parse
embedded JavaScript`) i `smoke`. Když přidáváš do panelu funkci, ověř, že
jméno není použité dvakrát.

**Transkripty musí ležet na `/trees`.** Je to jediná zapisovatelná cesta
připojená z hostitele; `/workspace` je scope-omezený a `/run/agenticdev` je
tmpfs, který teardown smaže. Kdyby to někdo přesunul do podu, ztratí se
přesně ten záznam, podle kterého se automatický běh dá doladit.

**Do `agent_run` neposílej tokeny ani cenu, dokud je někdo neměří.** Harness
je nezná — Pi je neohlašuje. Vymyšlené číslo v auditní stopě je horší než
prázdné pole, protože se za měsíc bude čít jako měření. Panel proto
rozlišuje „nula" a „neměří se" příznakem `spend_measured`.

**Na `event` nesmí být pravidlo (RULE).** Append-only vynucuje trigger
`event_no_change`, ne `CREATE RULE ... DO INSTEAD NOTHING`. Pravidlo na
UPDATE nebo INSERT totiž v Postgresu zakáže `INSERT ... ON CONFLICT` na
téže tabulce — a na tom stojí idempotentní zápis do ledgeru. S pravidlem
selhal **každý** zápis do auditní stopy, tedy skoro každý endpoint.
`tools/smoke-vps.sh` to kontroluje; kdyby to někdo vrátil, chytí se to tam.

**Migrace patří do `control-plane/app/migrate.py`.** Soubory ve
`vps/sql/` běží jen nad prázdnou databází — u instalace, která už jednou
naběhla, se nespustí nikdy. Změna schématu, která nemá migraci, se na
existujících instancích neprojeví.

**Fáze bez adresáře v `workspace/_phase/` rozbije projekt.** Enum
`phase_kind` a `PHASES` v `admin.py` musí souhlasit s tím, co je na disku —
jinak přepnutí do takové fáze vrátí 400 a stanice si nestáhne nastavení.
`make verify` to kontroluje.

**Barvy v shellu se jmenují `G Y R B D O`.** Nepřiřazuj do nich nic
jiného. Odpověď serveru uložená do `$R` nebo `$B` se pak vypíše jako
formát `printf` a rozsype výstup.
