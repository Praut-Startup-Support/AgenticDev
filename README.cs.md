# AgenticDev

**Vlastní agentní vývojová platforma.** Server drží všechna data, kontext a
orchestraci. Na stroji vývojáře běží agent v izolovaném kontejneru — bez
cesty do internetu, ven jen přes proxy s allowlistem. Repozitář je připojený
read-only a zapisovatelné jsou jen cesty povolené pro danou fázi, takže
zápis jinam selže na úrovni jádra.

Instrukce, scope i fázi dodává server. Rozhodnutí, běhy a náklady se
zapisují zpátky do auditovatelné evidence.

🇬🇧 [English version of this document](README.md)

> **Stav: alfa.** Sandbox ani klienti pro Windows a Linux nebyli zatím
> odzkoušeni v ostrém provozu. Než to nasadíš, přečti si
> [Známá omezení](#známá-omezení) na konci.

---

## Požadavky

| | |
|---|---|
| Server | Debian 12 nebo Ubuntu 22.04/24.04, aspoň 4 GB RAM, root |
| Síť | **Tailscale** — tvrdý požadavek, ne volba |
| Klienti | macOS, Linux nebo Windows 10 build 19041+ (přes WSL2) |
| Volitelně | API klíč k modelu, nebo lokální Ollama |

**Než začneš**, dvě věci v Tailscale konzoli:

1. [DNS](https://login.tailscale.com/admin/dns) → *HTTPS Certificates* →
   **Enable HTTPS**. Bez toho server nedostane certifikát pro svoje
   `.ts.net` jméno.
2. [Access controls](https://login.tailscale.com/admin/acls) → *Funnel* →
   **Add Funnel to policy**. Bez toho nenaběhne veřejná registrační stránka.

Instalátor obojí zkontroluje a řekne ti, co chybí.

---

## Instalace

### 1. Server — jednou

Stáhni soubor, ověř součet, spusť. Nepouštěj ho přes rouru — instalátor to
schválně odmítá.

```bash
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh.sha256
sha256sum -c agenticdev-install-vps.sh.sha256

scp agenticdev-install-vps.sh root@tvuj-server:/root/
ssh root@tvuj-server 'bash /root/agenticdev-install-vps.sh'
```

Zeptá se na pět věcí včetně dvou hesel, zbytek udělá sám. Na konci vypíše
dva odkazy:

| Odkaz | Pro koho | Odkud funguje |
|---|---|---|
| **Admin panel** | jen ty | jen z tailnetu |
| **Registrační stránka** | tvůj tým | z celého internetu |

### 2. Klienti — neomezeně strojů, kdekoliv

Pošli registrační odkaz komukoliv. Zadá heslo, vybere si systém a dostane
dva příkazy ke zkopírování.

**macOS · Linux · Windows.** Windows jede přes WSL2.

Instalátor stroj zaregistruje pod jménem a e-mailem toho člověka, nahraje
mu SSH klíč do Forgeja a položí na plochu **ikonu AgenticDev**. Klik na ni
otevře agenta a výběr projektu.

Objeví se v panelu v záložce *tým*, kde jde každý stroj zvlášť odpojit.

**Co je reálně na internetu:** jediná cesta — registrační stránka —
vystavená přes [Tailscale Funnel](https://tailscale.com/kb/1223/funnel).
Nepotřebuje veřejnou IP ani doménu. Heslo je na ní jediná zábrana, takže má
limit pokusů na IP i globálně a po pěti neúspěších zamkne adresu na hodinu.

Všechno ostatní — panel, git, API — zůstává na tailnetu.

### 3. Admin panel

Dodavatel modelů a API klíč, allowlist domén, obě hesla, platnost lease,
Tailscale klíče a SMTP se mění přímo v panelu a platí okamžitě. Věci, které
potřebují restart kontejneru, žijí v `/srv/agenticdev/config/.env` a panel je
ukazuje jen ke čtení.

---

## Denní práce

**Klikneš na AgenticDev v Docku.** Otevře se Ghostty, vybereš projekt
šipkami (nebo filtruješ psaním), a jsi v Pi. Normální konverzace.

```
  projekt ›
  montexbau   MontexBau s.r.o.    implementation   3 úkolů
  schekonom   SCH-EKONOM s.r.o.   discovery        0 úkolů
```

Z terminálu totéž: `agenticdev work`, nebo zkráceně `adev work`.

### Víc projektů zároveň

Každý projekt = jedno okno. Nic nevypínáš.

```bash
agenticdev work montexbau      # okno 1
agenticdev work schekonom      # okno 2 (⌘T v Ghostty)
```

### Jiná fáze, aniž bys ji měnil týmu

```bash
agenticdev work montexbau --phase delivery
```

Projekt zůstane pro ostatní v implementation. Změna fáze v nástěnce
navíc nikoho nevyhodí — konfigurace se zapíše na disk při startu
a běžící session jede dál.

### Přepínání mezi úkoly

```bash
agenticdev-git list
cd "$(agenticdev-git switch zaokrouhleni)"
```

Rozdělané úkoly leží fyzicky vedle sebe v `~/AgenticDev/.agenticdev-trees/`.

---

## Nový projekt

Nástěnka → **Projekty**:

| Pole | Poznámka |
|---|---|
| Kód | `montexbau` — stane se názvem repa |
| Klient | název firmy |
| Klasifikace dat | `restricted` = jen lokální modely, vynuceno |
| **Existující repozitář** | vyplň URL → naklonuje se i s historií a větvemi |

Když necháš pole prázdné, vznikne prázdné repo s kostrou `prd/`.
Hned potom vyplň `prd/50-glossary.md` — je to nejdůležitější soubor
projektu.

---

## Git

`bin/agenticdev-git` — deterministický shell, nula tokenů. Agent i člověk
volají to samé. Pi ho volá automaticky po každých třech editacích
a na konci session.

```bash
cd "$(agenticdev-git start "Import karet z DE" T-042)"
agenticdev-git checkpoint "kostra"
agenticdev-git save feat import "mapování polí"
agenticdev-git finish "feat(import): karty z DE"
```

Worktree na úkol · checkpointy se při `finish` sesypou do jednoho
commitu · `git notes` drží ID session, takže `agenticdev-git who src/a.ts 42`
řekne, odkud ten řádek je.

Test: `make test-git`

---

## Fáze

| Fáze | Smí měnit |
|---|---|
| discovery | `prd/**`, `docs/**` |
| design | + `design/**` |
| implementation | `src/**`, `tests/**`, ADR |
| hardening | + `infra/**` |
| delivery | `docs/**`, README, CHANGELOG |

---

## Přizpůsobení

`/srv/agenticdev/src/workspace/`:

```
_base/          AGENTS.md, .pi/ (skills, extension), bin/
_phase/<fáze>/  scope + doplněk AGENTS.md
<projekt>/      specifika projektu
```

`AGENTS.md` se řetězí, `settings.json` slévá. Vlastní skill pro klienta:
`workspace/<projekt>/.pi/skills/nazev/SKILL.md`.

---

## Co ověřit

- **`.pi/extensions/agenticdev-git.ts`** je psaný podle dokumentace Pi,
  ne odzkoušený proti běžícímu Pi. Ověř `api.addTool`, `api.addCommand`
  a názvy událostí. `bin/agenticdev-git` na extension nezávisí.
- Pi se ptá na důvěru k projektové složce — nastav `defaultProjectTrust`.
- **Dva lidi můžou vzít stejný úkol.** Zámky nejsou. Při třech lidech
  to vyřešíte tím, že si to řeknete.
- Zálohy: doplň `RESTIC_REPOSITORY` do `/srv/agenticdev/config/.env`.
- CI/CD ve Forgejo Actions není napsané.


---

## Licence

**Business Source License 1.1** — source-available, ne OSI open source.

Zdarma pro vyzkoušení, vývoj, výuku a produkční provoz ve firmách s obratem
**do 1 000 000 EUR**. Větší firmy potřebují komerční licenci. Každá verze se
**čtyři roky po vydání mění na Apache-2.0**.

Vysvětlení lidsky, česky i anglicky: [LICENSE-FAQ.md](LICENSE-FAQ.md).
Závazné znění: [LICENSE](LICENSE).

Komerční licence: **svanda@praut.cz**

© 2026 Praut s.r.o.

---

## Známá omezení

Poctivý stav. Vedeno jako blokátory verze 1.0:

- **Brána před mergem neběžela proti živému Forgeju.** Runner, workflow,
  branch protection i webhook, který po mergi nastaví `done`, jsou
  nasazené, a `agenticdev-ctl gate <projekt>` změří to jediné, co se z kódu
  vyčíst nedá: jestli se požadovaná jména commit statusů potkávají s těmi,
  která Forgejo doopravdy vydává. Pusť to na prvním PR. Dokud neuvidíš
  červenou kontrolu zablokovat merge, neber to jako dokázané.
- **Repozitář bez testů projde branou nazeleno.** Workflow to napíše do logu
  jako varování. Prázdná brána není brána.
- **Chybí metriky a trace.** Grafana, Loki, Prometheus i Tempo jsou v
  compose zakomentované. Co máš: ledger, záznam každého běhu, transkript
  ke každému běhu a časovou osu úkolu v panelu — viz
  [Co je vidět, když se něco stane](#co-je-vidět-když-se-něco-stane).
- **Join tokeny nemají expiraci** a jsou na instanci, ne na osobu.
- **Útrata se neměří a panel to říká.** Ke každému běhu se zapíše model,
  doba, výsledek a transkript, ale tokeny neohlašuje nikdo — `cost_czk`
  proto zůstává nulový a panel místo `0 Kč` píše „útrata se neměří", což by
  se čtlo jako „zdarma". Skutečná čísla potřebují údaje o spotřebě z
  modelového klienta harnessu. (To `len/3` je rozpočtová brána na velikost
  kontextu, ne útrata; tabulka `PRICING` neexistuje.)
- **Orchestrační vrstva (directors) neexistuje.** Architektonický rozbor ji
  popisuje, v kódu není. Postup úkolu vynucují kontroly projektu v harnessu
  ([ADR-0003](docs/adr/0003-postup-ukolu-vynucuje-harness.md)).
- **Útěk z kontejneru je mimo rozsah.** Pod běží bez rootu, se zahozenými
  capabilities a bez Docker socketu — ale kontejner není hypervizor. Ber to
  jako pevný plot, ne jako trezor.

Bezpečnostní dopady najdeš v [SECURITY.md](SECURITY.md).

---

## Co je vidět, když se něco stane

Žádný stack na metriky tu není. Co tu je, je záznam, který si po ději
přečteš — a to je to, co potřebuješ k ladění:

| Kde | Co v tom je |
|---|---|
| tabulka `event` | auditní stopa, append-only, hash-chained; databáze na ní odmítne `UPDATE`, `DELETE` i `TRUNCATE` |
| tabulka `agent_run` | řádek na běh: role, model, doba, výsledek, cesta k transkriptu. Zapisuje harness na konci běhu |
| `/trees/.transcripts/*.log` | úplný transkript automatického běhu — každý prompt, výstup agenta a **celý** výpis každé selhané kontroly (do promptu agenta jde jen posledních 25 řádků). Leží v domovském adresáři toho člověka na VPS, takže teardown podu na něj nedosáhne |
| panel → Úkoly → klik na úkol | časová osa: události, běhy a rozhodnutí v jedné řadě |
| `git notes` + `Task-Id:` | ze které session je konkrétní řádek — `agenticdev-git who src/a.ts 42` |

Interaktivní session si transkript vede sama: Pi ho píše do `~/.pi/agent`
toho člověka, což teardown taky přežije. Běh bez přiděleného úkolu se
nezapíše vůbec — `agent_run.task_id` je `NOT NULL` — a harness to řekne na
obrazovku, místo aby to tiše spolkl.

## Na čem stojí ty tři věci, kvůli kterým se to staví

Na stanici se nic nenastavuje ani nedovoluje · celá firma má jeden
automatizovaný postup kolem gitu, i pro lidi, co git neumí · všichni mají
stejně nastaveného agenta bez ohledu na předplatné.

Co přesně každou z nich vynucuje a jakým příkazem se to na živé instanci
ověří, je v [docs/tri-pozadavky.md](docs/tri-pozadavky.md).

---

## Web

Jednostránkový web je v [`site/`](site/) a nasazuje se na GitHub Pages.
Co doplnit před spuštěním, je v [site/README.md](site/README.md).

---

## Vydáváš vlastní fork?

Viz [PUBLISHING.md](PUBLISHING.md) — co doplnit, jak vydat release a co
otestovat.

---

## Přispívání

Viz [CONTRIBUTING.md](CONTRIBUTING.md). Příspěvky vyžadují podepsání CLA,
protože projekt je dvojlicencovaný a nemůžeme prodávat komerční licence na
kód, ke kterému nemáme práva.
