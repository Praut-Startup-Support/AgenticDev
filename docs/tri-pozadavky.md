# Tři požadavky a co je doopravdy drží

Tenhle dokument existuje proto, aby se dalo ověřit, že platforma dělá to,
kvůli čemu se staví — ne aby popisoval architekturu. Ke každému požadavku
je uvedené **místo, které ho vynucuje**, a **příkaz, kterým se to na živé
instanci pozná**.

Rozdíl mezi „vynucuje" a „je napsané v instrukcích" je celý smysl téhle
tabulky. Instrukce agent přečte a může je nedodržet. Mount a proxy ho
nezajímají.

---

## 1. Na počítači zaměstnance se nic nenastavuje ani nedovoluje

**Co to znamená v praxi.** Člověk dostane odkaz, řekne jméno a e-mail, a
nainstaluje Tailscale plus zástupce na plochu. Nic dalšího. Žádný Docker,
žádné WSL2, žádný klíč k modelu v souboru u sebe, žádné klikání na
„povolit" při práci.

**Kde to drží:**

| Věc | Vynucuje |
|---|---|
| Na stanici nic těžkého není | pod běží na VPS ([ADR-0005](adr/0005-pod-bezi-na-vps.md)), klient je jen SSH a ikona |
| Nastavení nepatří člověku | `GET /v1/workspace/<projekt>/bundle` — instrukce, skills, git nástroj a scope skládá server |
| Není co povolovat | zápis mimo scope selže na `EROFS` (repozitář je `ro`, rw jsou jen cesty ze scope), ven vede jen egress proxy |
| Ani úvodní dotaz na důvěru | harness spouští Pi s `-a`, protože obsah poslal server, ne cizí repozitář |

Oprávnění agenta záměrně **nejsou** v `.pi/settings.json`. Kdyby tam byla,
byla by to prosba. Hranice je mount.

**Jak to ověřit:**

```bash
agenticdev-ctl smoke          # scope všech šesti fází, izolace podu
```

V podu pak musí selhat zápis mimo scope:

```bash
# ve fázi implementation:
echo x >> prd/00-context.md   # EROFS — prd/ v téhle fázi zapisovatelné není
```

---

## 2. Celá firma má stejné a automatizované procesy kolem gitu

**Co to znamená v praxi.** Nikdo nemusí umět git. Zaměstnanec ani agent
nepíšou `git` příkazy — volají `bin/agenticdev-git`, což je obyčejný
skript: žádný model, žádné tokeny, stejné chování pro člověka i agenta.

| Chci | Příkaz | Co se stane |
|---|---|---|
| začít úkol | `start "popis" T-042` | větev z `origin/main` + vlastní worktree |
| průběžně uložit | `checkpoint "co je hotové"` | wip commit, `git bisect` je pak k něčemu |
| uložit kus | `save feat import "…"` | Conventional Commits + `Task-Id:` trailer |
| odevzdat | `finish "titulek"` | sesype wip → narovná na main → vzkaz pro launcher |

Pojistky, které neprogramátor nevymyslí sám: commit na `main` skript
odmítne, push je vždy `--force-with-lease`, u každého commitu je v
`git notes` vidět session, ze které vznikl (`agenticdev-git who <soubor> <řádek>`).

**Agent nedrží přihlašovací údaje k repozitáři.** `finish` jen uloží vzkaz
do `.agenticdev/finished`; větev odešle a PR otevře launcher na VPS. Kdo
neumí git, tedy nemá jak rozbít remote — nemá k němu přístup.

### Konflikt s main

Tady je to místo, kde neprogramátor uvázne, a proto se chová jinak než
`git`. Při konfliktu `sync`:

1. vrátí větev do stavu před rebasem — commity zůstávají, nic se neztratí,
2. vypíše kolidující soubory,
3. zapíše to na VPS jako rozhodnutí pro člověka,
4. skončí nenulově, takže `finish` neodevzdá.

Kdo git umí, dostane původní chování přes `agenticdev-git sync --manual`.

### Brána před mergem

„Hotovo" je smergovaný PR se zeleným workflow ([ADR-0006](adr/0006-hotovo-je-smergovany-pr.md)),
ne něco, co agent odklikne. Každý projekt dostane při zakládání:

- `.forgejo/workflows/test.yml` — spustí testy, které v repozitáři jsou
- branch protection na `main` — bez zeleného statusu merge nejde
- webhook na control plane — po mergi se úkol přepne na `done`

**Tohle si ověř jako první věc po instalaci**, protože jedna konkrétní past
se nedá poznat jinak než měřením: Forgejo pojmenovává commit statusy jako
`workflow / job (událost)`, tedy `test / test (pull_request)`. Kdyby
branch protection požadovala status jiného jména, nikdy nepřijde — a merge
je zablokovaný **navždycky**, přičemž v panelu to vypadá jako funkční
brána.

```bash
agenticdev-ctl gate <projekt>          # porovná požadované vs. vydané statusy
agenticdev-ctl gate <projekt> --fix    # nasadí znovu podle nastavení v panelu
```

Když autoři kódu nejsou programátoři, nastav v panelu
**Brána před mergem → Kolik lidí musí PR odkliknout** aspoň na `1`.
S nulou se kód smerguje, aniž ho kdokoli přečetl.

**Jak to ověřit:**

```bash
make test-git                 # celý tok včetně konfliktu, na dočasném repu
agenticdev-ctl gate <projekt> # brána na živé instanci
```

---

## 3. Všichni mají stejně nastaveného agenta bez ohledu na předplatné

**Co to znamená v praxi.** Instrukce, skills, git flow, scope **a jméno
modelu** jsou sdílené a mění se na serveru. Osobní zůstává jediná věc: kdo
to platí.

| Vrstva | Sdílené, ze serveru | Osobní |
|---|---|---|
| instrukce (`AGENTS.md`) | ano, řetězí se přes vrstvy | — |
| skills, slash příkazy | ano | — |
| scope podle fáze | ano, vynuceno mountem | — |
| **model** | ano — `enabledModels` v bundlu | — |
| přihlášení k modelu | — | `~/.pi/agent/auth.json` na VPS |
| sessions, transkripty | — | tamtéž |

Model se přišpendluje **všem**, ne jen u `restricted` projektů. Kdyby si
každý bral to, co má ve svém předplatném, dostali by dva lidé na stejné
zadání jinou odpověď a nešlo by to srovnat.

**Důsledek, se kterým je třeba počítat:** když něčí předplatné ten model
neumí, Pi to řekne a nepustí ho dál. To je záměr — tichá záměna modelu za
jiný je přesně ta degradace, kterou zakazuje princip P5. Model projektu se
mění v panelu (*Modely → Výchozí model*), případně u jednotlivého projektu
přes `model_allowlist`.

Sdílené prostředí × osobní přihlášení rozebírá
[ADR-0007](adr/0007-prostredi-sdilene-prihlaseni-na-cloveka.md).

**Jak to ověřit:**

```bash
agenticdev-ctl smoke   # „bundle přišpendluje model všem stejně (…)"
```

---

---

## Čím se to dá zkontrolovat a doladit

Metriky ani trace tu nejsou. Co tu je, je záznam po ději — a ten na ladění
stačí:

| Kde | Co v tom je |
|---|---|
| tabulka `event` | auditní stopa, append-only, hash-chained. Databáze na ní odmítne `UPDATE`, `DELETE` i `TRUNCATE` |
| tabulka `agent_run` | řádek na běh: role, model, doba, výsledek, cesta k transkriptu |
| `/trees/.transcripts/*.log` | úplný transkript automatického běhu: každý prompt, výstup agenta, a **celý** výpis každé selhané kontroly |
| panel → Úkoly → klik na úkol | časová osa: události, běhy a rozhodnutí v jedné řadě |
| `git notes` + `Task-Id:` | ze které session je konkrétní řádek |

Dvě věci, na kterých záleží, když to chceš ladit:

- **Transkript leží na hostiteli, ne v podu.** `/trees` je připojený z
  domovského adresáře toho člověka na VPS, takže teardown na něj nedosáhne.
  Kdyby byl v podu, přišel bys o něj přesně u toho běhu, který nikdo
  nesledoval.
- **Do promptu agenta jde z padlé kontroly jen 25 řádků**, aby se nezahltil.
  Do transkriptu jde celý výpis. Ladíš tedy z úplného, ne z ocasu.

**Útrata se neměří a panel to říká rovnou.** Zapisuje se model, doba,
výsledek a transkript; tokeny neohlašuje nikdo, takže `cost_czk` zůstává
nulový. Panel proto místo `0 Kč` píše „útrata se neměří" — nula by se
čtla jako „zdarma". Skutečná čísla potřebují údaje o spotřebě z modelového
klienta harnessu, a než budou, žádné číslo si nevymýšlíme.

**Jak to ověřit:**

```bash
agenticdev-ctl smoke   # „N běhů agenta v ledgeru", časová osa, skript panelu
```

---

## Co tímhle pořád není vyřešené

Poctivě, ať se to nehledá v kódu:

- **Brána běží, ale nikdo ji neviděl zastavit merge.** Runner, workflow,
  ochrana i webhook jsou nasazené a `agenticdev-ctl gate` je změří — ale
  dokud na živém Forgeju neuvidíš červenou kontrolu zablokovat merge,
  neber to jako dokázané.
- **Repozitář bez testů projde branou nazeleno.** Workflow to napíše do
  logu jako varování. Prázdná brána není brána.
- **Sdílené prostředí je tenké.** Instrukce, čtyři skills, git nástroj,
  model. Žádné hooky ani subagenty — v Pi vrstvě zatím nejsou.
- **Útrata se neměří**, takže „vyplatí se to u téhle zakázky" se dnes
  nezodpoví. Doba běhu a výsledek ano.
- **Interaktivní session nemá transkript od nás.** Píše si ho Pi do
  `~/.pi/agent` toho člověka. Tee děláme jen u automatického běhu, protože
  u interaktivního bychom rozbili obrazovku.
- **Běh bez přiděleného úkolu se nezapíše.** `agent_run.task_id` je
  `NOT NULL`. Harness to řekne na obrazovku, ale v ledgeru po takové
  session nezůstane nic.
