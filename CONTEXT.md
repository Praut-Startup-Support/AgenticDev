# Slovník

Vlastní pojmy tohohle projektu. Jedna až dvě věty na pojem, žádné
implementační detaily. Když někdo použije slovo z `_Vyhýbej se_`, je to
znamení, že si dva lidé nerozumí.

---

## Agent

Program, který v podu píše kód — konkrétně **Pi**
(`@earendil-works/pi-coding-agent`). Spouští ho výhradně harness, až po
kontrole policy. Server agenta neposílá, posílá mu nastavení: instrukce,
skills, oprávnění a kontext podle fáze a projektu.

_Vyhýbej se_: Claude Code (jiný produkt; celá workspace vrstva je psaná
pro Pi — `.pi/settings.json`, Pi skills, extension proti Pi API),
„náš agent".

Viz [ADR-0001](docs/adr/0001-agent-je-pi.md).

## Model

Inteligence, kterou agent volá. Přihlášení k ní leží v
`~/.pi/agent/auth.json` **na VPS**, protože tam běží i pod. Pi se
přihlašuje buď předplatným přes OAuth (`/login`), nebo API klíčem.
`model_allowlist` u projektu je údaj pro lidi; skutečnou hranicí je egress
allowlist.

_Vyhýbej se_: „agent" (to je program, který model volá), „AI",
„Claude Code v Pi" a „Codex v Pi" — Claude Code a Codex jsou samostatné
produkty a v Pi neběží. Pi se přihlašuje ke **stejnému předplatnému**:
Anthropic pro Claude Pro/Max, ChatGPT Plus/Pro pro modely OpenAI.

Viz [ADR-0005](docs/adr/0005-pod-bezi-na-vps.md).

## Director

Postup, kterým musí úkol projít, a limity, kolik se smí opakovat.
Vynucuje ho harness uvnitř podu, ne server: po každém kole spustí
**kontroly projektu** a podle nich se rozhodne dál — o tom, že je hotovo,
nerozhoduje agent. Selhání se zapíše do ledgeru a zkusí se opravit; po
vyčerpání limitu z work orderu jde úkol do `blocked`. Přes neopravené
kontroly se nepokračuje.

_Vyhýbej se_: „orchestrátor", „workflow" (to je běh v Actions).
Pozor: tabulka `director_version` v databázi popisuje directora jako
zvlášť verzovaný a podepsaný artefakt s kanály. Tak to dneska není a
[ADR-0003](docs/adr/0003-postup-ukolu-vynucuje-harness.md) říká proč.

## Restricted

Třída dat, u které nesmí obsah projektu opustit firmu. Vynucuje se tím,
že server pošle egress allowlist **bez jakéhokoli cloudového endpointu** —
pod se ke cloudu nedostane, ať si v Pi kdokoli vybere cokoli. Kontrola
jména modelu v harnessu je jen brzká hláška; závazná je allowlist.

Bez nastaveného lokálního endpointu takový projekt panel nezaloží — bez
něj by v allowlistu nebylo nic a agent by neměl s čím pracovat.

_Vyhýbej se_: „citlivý projekt" bez upřesnění třídy dat, a hlavně
představě, že to hlídá jméno modelu — Pi ho umí přepnout za běhu.

Viz [ADR-0004](docs/adr/0004-restricted-vynucuje-egress.md).

## Hotovo

Stav úkolu, který nastane **mergem PR** se zeleným workflow z repozitáře
projektu. Není to nic, co by někdo odklikl.

_Vyhýbej se_: „done" pro úkol ve stavu `review` — ten čeká na člověka a
hotový není.

Viz [ADR-0006](docs/adr/0006-hotovo-je-smergovany-pr.md).

## Prostředí

Vrstva, kterou server posílá do projektu — nastavení, skills, hooky,
extension a instrukce podle fáze. Je **sdílená a jediná**: mění se na
serveru, ne u lidí. Nepatří do ní přihlášení k modelu ani sessions, ty má
každý vlastní.

_Vyhýbej se_: „prostředí" pro adresář `~/.pi/agent` na VPS — v tom je to,
co je na člověka, tedy pravý opak.

Viz [ADR-0007](docs/adr/0007-prostredi-sdilene-prihlaseni-na-cloveka.md).

## Připojení stroje

První kontakt člověka s instancí: na registrační stránce prokáže znalost
sdíleného hesla, **řekne jméno, příjmení a e-mail**, a dostane klíč do
tailnetu a instalátor. Bez toho se nedostane nikam dál.

_Vyhýbej se_: „registrace" bez upřesnění — v platformě jsou tři různé
kroky, které tak jdou pojmenovat (tenhle, ten následující a přihlášení).

## Registrace stanice

Krok, který dělá instalátor: pošle serveru fingerprint device keye toho
stroje a identitu člověka z připojení. Vznikne z toho řádek ve
`workstation` a SSH klíč se založí ve Forgeju. Jeden člověk může mít víc
stanic; odebrat se dá jednotlivá.

## Přihlášení stanice

Co dělá launcher při každém spuštění: vymění fingerprint device keye za
krátkodobý token. Neplatí déle než lease a nepřenáší se mezi stroji.

_Vyhýbej se_: „login" pro tohle i pro heslo do panelu — panel je jiná
cesta s jiným tajemstvím.
