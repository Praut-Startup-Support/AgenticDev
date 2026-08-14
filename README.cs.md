# AgenticDev

[![test](https://github.com/Praut-Startup-Support/AgenticDev/actions/workflows/test.yml/badge.svg)](https://github.com/Praut-Startup-Support/AgenticDev/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/Praut-Startup-Support/AgenticDev?include_prereleases&sort=semver)](https://github.com/Praut-Startup-Support/AgenticDev/releases)
[![licence: BSL 1.1](https://img.shields.io/badge/licence-BSL%201.1-blue)](LICENSE)
[![status: alpha](https://img.shields.io/badge/status-alpha-orange)](#)

**Vlastní agentní vývojová platforma.** Server drží všechna data, kontext,
orchestraci — a i samotné agenty. Agent běží v izolovaném kontejneru **na
VPS**, ne na stroji vývojáře ([ADR-0005](docs/adr/0005-pod-bezi-na-vps.md)):
bez cesty do internetu, ven jen přes proxy s allowlistem. Repozitář je
připojený read-only a zapisovatelné jsou jen cesty povolené pro danou fázi,
takže zápis jinam selže na úrovni jádra. U lidí na strojích nepřistane nic
těžkého — ikona, a Tailscale jen když sis vybral ten režim.

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
| Síť | **Buď** Tailscale (z internetu je vidět jen registrace), **nebo** veřejná doména s A záznamem (bez třetí strany, Caddy + Let's Encrypt). Vybírá se při instalaci |
| Klienti | macOS, Linux nebo Windows 10 build 19041+ (přes WSL2) |
| Volitelně | API klíč k modelu, nebo lokální Ollama |

## Dvě cesty, jak se k platformě dostat

Instalátor se zeptá, kterou chceš. Je to jediné architektonické rozhodnutí,
které u instance uděláš, a je to volba mezi bezpečností a nezávislostí.

| | **Tailscale** | **Doména** |
|---|---|---|
| Z internetu vidět | registrační stránka, nic jiného | i panel, git a API — za heslem správce |
| Vnitřní služby (Postgres, Forgejo, MinIO) | jen na tailnetu | jen na `127.0.0.1`, zvenčí přes Caddy |
| TLS | vydá Tailscale pro `.ts.net` jméno | Let's Encrypt pro tvou doménu |
| Přihlášení vývojáře | autentizuje tailnet, klíč nikdo neřeší | obyčejný SSH klíč, zapíše `agenticdev-ctl keys add` |
| Potřebuje třetí stranu | ano — Tailscale účet na každou instanci | ne |
| Potřebuje doménu s A záznamem | ne | ano |

**Tailscale** ber, když si instanci provozuješ sám a chceš nejmenší možnou
plochu: z internetu je vidět přesně jedna cesta.

**Doménu** ber, když instance dáváš jiným firmám. S Tailscale by si každá
musela zřídit Tailscale účet a naklikat dvě věci v konzoli, kterou
neovládáš (*Enable HTTPS*, *Add Funnel to policy*). Nad pár instalacemi to
přestane jít.

V obou případech rozhoduje `BIND_ADDR` v `/srv/agenticdev/config/.env` o
tom, kde poslouchá Postgres a MinIO. **Nikdy tam nesmí být veřejná adresa
ani `0.0.0.0`** — to by znamenalo ledger na internetu. `agenticdev-ctl
smoke` to kontroluje, a kontroluje i skutečné sokety, ne jen konfiguraci.

**Když vybereš Tailscale**, nastav předtím dvě věci v jeho konzoli:

1. [DNS](https://login.tailscale.com/admin/dns) → *HTTPS Certificates* →
   **Enable HTTPS**. Bez toho server nedostane certifikát pro svoje
   `.ts.net` jméno.
2. [Access controls](https://login.tailscale.com/admin/acls) → *Funnel* →
   **Add Funnel to policy**. Bez toho nenaběhne veřejná registrační stránka.

Instalátor obojí zkontroluje a řekne ti, co chybí.

---

## Instalace

### 1. Server — jednou

**Jeden příkaz.** Bootstrap stáhne vydaný instalátor, ověří jeho součet
**i podpis cosign**, a teprve pak ho spustí:

```bash
ssh -t root@tvuj-server 'bash <(curl -fsSL https://raw.githubusercontent.com/Praut-Startup-Support/AgenticDev/main/install.sh)'
```

Zeptá se na sedm věcí — doména, tvoje jméno a e-mail jako správce instance,
dvě hesla, dodavatel modelů a jak se budou lidi připojovat — a zbytek udělá
sám. Na konci vypíše dva odkazy.

Kdo nechce pouštět nic z roury, stáhne si bootstrap, přečte ho a pustí. Nebo
si vezme vydaný artefakt sám:

```bash
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh.sha256
sha256sum -c agenticdev-install-vps.sh.sha256

scp agenticdev-install-vps.sh root@tvuj-server:/root/
ssh -t root@tvuj-server 'bash /root/agenticdev-install-vps.sh'
```

Ten artefakt sám přes rouru pustit nejde a odmítá to schválně — musí si
rozbalit vlastní payload ze souboru na disku.

Na konci vypíše dva odkazy:

| Odkaz | Pro koho | Odkud funguje |
|---|---|---|
| **Admin panel** | jen ty | režim Tailscale: jen z tailnetu. Režim doména: z každého prohlížeče, za heslem správce |
| **Registrační stránka** | tvůj tým | z celého internetu, v obou režimech |

Vypíše k tomu i správce instance — jméno a e-mail, které jsi zadal při
instalaci, se založí jako `principal`, aby v auditní stopě bylo vidět, kdo
rozhodnutí odklikl. Dřív tam byl aktér prázdný.

### 2. Klienti — neomezeně strojů, kdekoliv

Pošli registrační odkaz komukoliv. Zadá jméno, příjmení, e-mail a heslo,
vybere si systém a dostane příkazy ke zkopírování — v režimu Tailscale dva
(připojit se do sítě, nainstalovat), v režimu doména jeden.

**macOS · Linux · Windows.** Windows jede přes WSL2.

Instalátor stroj zaregistruje pod jménem a e-mailem toho člověka, nahraje
mu SSH klíč do Forgeja a položí na plochu **ikonu AgenticDev**. Klik na ni
otevře agenta a výběr projektu.

Objeví se v panelu v záložce *tým*, kde jde každý stroj zvlášť odpojit.

**V režimu doména je jeden krok navíc**, protože autentizaci už nedělá
tailnet: instalátor na stroji vygeneruje SSH klíč a vypíše jeho veřejnou
část. Ten řádek ti člověk pošle a ty ho zapíšeš:

```bash
sudo agenticdev-ctl keys add msvanda "ssh-ed25519 AAAA… msvanda@mac"
```

`agenticdev-ctl user add` klíč z registrace zapíše sám, `agenticdev-ctl keys
sync` dobere pozdější. Control plane do `authorized_keys` nezapisuje a
nemá — běží v kontejneru a do `/home` mu nic nepatří.

**Co je reálně na internetu:** v režimu Tailscale jediná cesta —
registrační stránka vystavená přes
[Tailscale Funnel](https://tailscale.com/kb/1223/funnel), bez veřejné IP i
domény. V režimu doména je to Caddy na 443: registrace, panel a git. Heslo
je na registraci jediná zábrana, takže má limit pokusů na IP i globálně a po
pěti neúspěších zamkne adresu na hodinu; panel má stejné omezení.

Vnitřní služby — Postgres, Forgejo, MinIO — nejsou na internetu v žádném
režimu. Drží to `BIND_ADDR` a kontroluje `agenticdev-ctl smoke`.

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
**do 1 000 000 EUR**, **pokud zachováš uvedení autora** „AgenticDev — © Praut
s.r.o." v administračním rozhraní, v dokumentaci a v hlavičkách zdrojových
souborů. Větší firmy potřebují komerční licenci. Každá verze se **čtyři roky
po vydání mění na Apache-2.0**.

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

- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — jedno pravidlo a pár příkladů
- [SUPPORT.md](SUPPORT.md) — kam s dotazem, s chybou a s bezpečnostní dírou
- [CHANGELOG.md](CHANGELOG.md) — co se kdy změnilo
