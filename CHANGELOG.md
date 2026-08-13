# Changelog

Všechny podstatné změny. Formát vychází z
[Keep a Changelog](https://keepachangelog.com/cs/1.1.0/), verzování ze
[SemVer](https://semver.org/lang/cs/).

Do `v1.0.0` se drobná čísla hýbou rychle a rozbíjející změny se můžou objevit
i v minor verzi — dokud platí *alpha* v README, ber to tak.

## [Nevydáno]

### Přidáno

- **Doménový režim** — Tailscale už není povinný. Instalace se ptá, jestli má
  platforma jet po tailnetu, nebo na vlastní doméně s Let's Encrypt. Doménový
  režim nepotřebuje žádnou třetí stranu, což je podmínka pro nasazení u
  zákazníků, kteří si instanci provozují sami.
- **`install.sh`** — jeden příkaz, který stáhne vydaný artefakt, ověří `sha256`
  i podpis `cosign`, spustí jeho vlastní `--check` a teprve pak instaluje.
- **`BIND_ADDR`** — explicitní adresa, na které poslouchá Postgres, Forgejo a
  MinIO. V doménovém režimu `127.0.0.1`. `smoke` kontroluje konfiguraci i
  skutečné sokety.
- **`agenticdev-ctl keys add` a `keys sync`** — zápis SSH klíčů do
  `authorized_keys`. Bez Tailscale je to jediná cesta, jak se člověk přihlásí.
- **Správce instance má identitu** — instalace se povinně ptá na jméno a
  e-mail, vzniká z toho `principal`, a panelové zápisy do auditní stopy mají
  konečně koho uvést.
- **`agenticdev-ctl gate <projekt>`** — změří, jestli brána před mergem
  doopravdy stojí, a porovná požadovaná jména commit statusů s těmi, která
  Forgejo skutečně vydává.
- **Záznam běhů a transkripty** — harness zapisuje každý běh do `agent_run`
  (role, model, doba, výsledek, cesta k transkriptu). Transkripty leží na
  hostiteli a přežijí zbourání podu.
- **Časová osa úkolu v panelu** — události, běhy a rozhodnutí v jedné řadě.
- **Uvedení autora v licenci** — bezplatné použití je nově podmíněné tím, že
  zůstane zachované „AgenticDev — © Praut s.r.o.". Viz [LICENSE-FAQ](LICENSE-FAQ.md).

### Opraveno

- **Panel byl v prohlížeči mrtvý.** `const esc` kolidoval s `function esc()`,
  což je v jednom scope `SyntaxError` a shodilo to celý skript včetně
  přihlášení. CI i `smoke` to teď kontrolují.
- **Brána před mergem by v provozu zablokovala každý merge natrvalo.**
  Požadovaný commit status se jmenoval `test`, jenže Forgejo je jmenuje
  `test / test (pull_request)`. Navíc importovaný projekt nedostal workflow
  vůbec, takže se čekalo na status, který nikdo nevydá.
- **Model se přišpendluje všem projektům**, ne jen `restricted` — jinak dva
  lidé na stejné zadání dostali jinou odpověď podle svého předplatného.
- **`agenticdev-decision` v podu vždy spadl** — chyběl `AGENTICDEV_CP` a token
  se hledal na cestě, která v podu neexistuje. `/skill:rozhodnuti` tedy tiše
  nezapisoval nic.
- **Konflikt s `main` už nenechává neprogramátora v rozpůleném rebase.**
  `sync` vrátí stav, vypíše kolidující soubory a zapíše to na VPS.
- **`make test-git` byl rozbitý** — kontroloval `origin/<větev>` po `finish`,
  který ale neodesílá.
- **Fáze `design` neměla `AGENTS.md`**, jediná ze šesti.
- **Cíl pro `CNAME` v návodu byl chybný** — ukazoval na účet, který neexistuje.

### Poznámka k útratě

`cost_czk` zůstává nulový a panel místo `0 Kč` píše „útrata se neměří".
Tokeny dnes neohlašuje nikdo, a vymyšlené číslo v auditní stopě je horší než
prázdné pole. `PRICING`, na kterou se odvolávala starší dokumentace, v kódu
nikdy nebyla.

## [0.1.0] — nevydáno

První sestavení. Tag existuje, release je zatím **draft** — dokud se
nepublikuje, `releases/latest/download/…` vrací 404 a instalace podle README
nefunguje.

- VPS stack: Postgres s pgvectorem, Forgejo s Actions, MinIO, Caddy, control
  plane, denní zálohy přes restic
- Auditní stopa: append-only tabulka `event` s řetězem hashů; databáze na ní
  odmítne `UPDATE`, `DELETE` i `TRUNCATE`
- Sandbox: pod bez cesty do internetu, repozitář read-only, zapisovatelné jen
  cesty ze scope dané fáze
- Fázové brány: šest fází, každá s vlastním scope a instrukcemi
- Klienti pro macOS, Linux a Windows; registrace přes veřejnou stránku
- Reprodukovatelný build instalačního artefaktu

[Nevydáno]: https://github.com/Praut-Startup-Support/AgenticDev/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Praut-Startup-Support/AgenticDev/releases/tag/v0.1.0
