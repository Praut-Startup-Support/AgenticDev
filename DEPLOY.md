# Nasazení na VPS

Postup od prázdného serveru k platformě, na které tým reálně pracuje.
Psáno pro zkušební VPS, který má vydržet i ostrý provoz — nic tady není
"jen na zkoušku".

Anglická verze README je [tady](README.md), architektura
[tady](docs/architektura.md).

---

## 0. Co si připrav předem

| | |
|---|---|
| VPS | Debian 12 nebo Ubuntu 22.04/24.04, root přes SSH. **Paměť podle počtu lidí:** základ ~2,5 GB + ~1,5 GB na každého, kdo pracuje zároveň. Pro tři lidi tedy ~8 GB a ~40 GB disku. Pody běží tady, ne na notebooku. |
| Tailscale | účet, do kterého se VPS i stroje týmu připojí |
| Doména | **nepovinná** — bez ní jede platforma po tailnetu, což je bezpečnější |
| Model | klíč k OpenAI-kompatibilnímu API nebo Anthropicu, nebo lokální Ollama |
| Zálohy | restic repozitář (B2, Wasabi, S3) a heslo k němu |

Dvě věci v [Tailscale konzoli](https://login.tailscale.com/admin), obě
jednorázově a **před** instalací:

1. **DNS → HTTPS Certificates → Enable HTTPS.** Bez toho server nedostane
   certifikát pro své `.ts.net` jméno.
2. **Access controls → Funnel → Add Funnel to policy.** Bez toho nenaběhne
   veřejná registrační stránka a tým se nemá jak připojit.

Vymysli si dvě hesla. Instalátor se na ně zeptá a nikam jinam si je nezapíše:

- **ADMIN** — do admin panelu, jen pro tebe, min. 12 znaků
- **JOIN** — dostane každý, kdo si připojuje stroj, min. 10 znaků

---

## 1. Preflight

Než začneš měnit systém, ať víš, že se to má cenu spustit:

```bash
scp tools/preflight-vps.sh root@<vps>:/root/
# AGENTICDEV_USERS = kolik lidí bude pracovat NARÁZ; podle toho se počítá paměť
ssh root@<vps> 'AGENTICDEV_USERS=3 bash /root/preflight-vps.sh'
```

Kontroluje distribuci, paměť, místo, obsazené porty, dosažitelnost
Docker/Tailscale/Codebergu a synchronizaci hodin. Když skončí nenulově,
nespouštěj instalaci — vypíše, co spravit.

---

## 2. Server

Instalátor je jeden soubor, který v sobě nese celý repozitář. Ověř si ho
kontrolním součtem a **nepouštěj ho přes `curl | bash`** — takhle se
nerozbalí a schválně to odmítne.

```bash
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh
curl -fLO https://github.com/Praut-Startup-Support/AgenticDev/releases/latest/download/agenticdev-install-vps.sh.sha256
sha256sum -c agenticdev-install-vps.sh.sha256

scp agenticdev-install-vps.sh root@<vps>:/root/
ssh -t root@<vps> 'bash /root/agenticdev-install-vps.sh'
```

Nebo z repozitáře: `make dist` vyrobí ten samý soubor a `make check-dist`
ho ověří. Build je deterministický — stejný commit dá stejný součet.

Instalátor se zeptá na doménu, e-mail, jméno do gitu, obě hesla a
dodavatele modelu. Pak si sám postaví Docker, firewall, SSH hardening,
Tailscale, Postgres, Forgejo, MinIO, control plane, denní zálohy a
registrační stránku. Trvá to podle stroje 5–10 minut; první běh staví
obraz control plane.

Je **idempotentní**: pusť ho znovu kdykoli. Tajemství nechá být, jen
narovná soubory a restartuje služby.

Užitečné přepínače:

```bash
bash agenticdev-install-vps.sh --check      # jen ověří obsah, systému se nedotkne
bash agenticdev-install-vps.sh --yes        # neinteraktivně, bere hodnoty z prostředí
bash agenticdev-install-vps.sh --mac-only   # jen přegeneruje instalátor Macu
```

---

## 3. Smoke test

Instalátor na konci řekne, že platforma běží. Tohle řekne, jestli
opravdu **dělá, co má**:

```bash
ssh root@<vps> 'agenticdev-ctl smoke'
```

Projede služby, schéma, auditní stopu (zápis, idempotence, odmítnutí
přepisu, celistvost hashů), registraci strojů, panel, vydání a **podpis**
work orderu, scope všech šesti fází a otevřené porty. Vrací nenulově,
když něco nesedí.

Když někde spadne na tom, že do ledgeru nejde zapsat, spusť
`agenticdev-ctl restart control-plane` — migrace se dojedou při startu.

---

## 4. Doplň, co instalátor nemohl vědět

```bash
ssh root@<vps> 'agenticdev-info'      # odkazy a hesla znovu
```

**Klíč k modelu**, pokud jsi ho nezadal při instalaci: admin panel →
*Nastavení → Modely → API klíč*. Platí okamžitě, bez restartu.

**Zálohy** — dokud nedoplníš repozitář, timer je vypnutý:

```bash
ssh root@<vps>
$EDITOR /srv/agenticdev/config/.env      # RESTIC_REPOSITORY, RESTIC_PASSWORD
systemctl enable --now agenticdev-backup.timer
agenticdev-ctl backup-now                # ať víš hned, že to funguje
agenticdev-ctl backup-check
```

**Zazálohuj si mimo tenhle stroj** `/srv/agenticdev/config/.env`, hlavně
`WO_SIGNING_KEY_B64`. Bez něj neověříš dřív vydané work ordery a
instalátory, které jsi rozeslal týmu, přestanou k serveru patřit.

---

## 5. Lidé v týmu

Pody běží **na VPS** ([ADR-0005](docs/adr/0005-pod-bezi-na-vps.md)), takže
každý člověk potřebuje na serveru účet. Zakládá ho root, jednou na člověka:

```bash
ssh root@<vps>
agenticdev-ctl user add msvanda "Martin Švanda" martin@praut.cz
```

Ten příkaz založí účet, vygeneruje device key i SSH klíč, zaregistruje
stanici u control plane, nahraje klíč do Forgeja a vypíše, co poslat
dotyčnému. Ten pak pracuje takhle:

```bash
tailscale ssh msvanda@<vps>
agenticdev                      # vyber projekt, Enter
```

Poprvé se v Pi přihlásí k modelu přes `/login` — vlastním předplatným nebo
klíčem. Přihlášení mu zůstane v `~/.pi/agent` a platí dál
([ADR-0007](docs/adr/0007-prostredi-sdilene-prihlaseni-na-cloveka.md)).
Prostředí — skills, hooky, instrukce — chodí ze serveru a je pro všechny
společné.

> **Než přidáš prvního člověka, věz tohle.** Aby mohl spustit pod,
> potřebuje být ve skupině `docker`, a to je na tomhle stroji rovnocenné
> rootovi: přes Docker socket se dostane k `/srv/agenticdev/config/.env`,
> tedy k podpisovému klíči a všem tajemstvím instance. Pro malý tým, který
> si věří, je to snesitelné. **Nedávej účet na VPS nikomu, komu bys nedal
> root** — externistovi, klientovi, juniorovi. Řešení (rootless Docker nebo
> privilegovaný pomocník) hotové není.

Registrační stránka s heslem (`JOIN_URL` z `agenticdev-info`) zůstává pro
připojení stroje do tailnetu. Odkaz je veřejný, **heslo posílej zvlášť a
jiným kanálem**.

Když se odkaz nevypíše, Funnel se nezapnul:

```bash
agenticdev-ctl funnel                    # zapne a vypíše odkaz
curl https://<jmeno>.ts.net:8443/health  # ověř ZVENČÍ, ne z tailnetu
```

To `curl` pusť z mobilních dat nebo z jiné sítě. Z tailnetu ti odpoví i
tehdy, když Funnel nefunguje, a nic tím nezjistíš.

Stroje se objeví v panelu na kartě *tým*. Jednotlivý stroj tam kdykoli
odebereš; pracující agent tím přijde o lease.

---

## 6. První projekt

V panelu → *Projekty*:

1. **Kód projektu** a **klient**. Existující repozitář naklonuješ i s
   historií přes *import URL*.
2. **Data** — `restricted` natvrdo zakáže cloudové modely. Pro
   zdravotnictví a osobní údaje. Zpět to nejde odklikem, mění se to v
   databázi, a to je záměr.
3. **Fáze** se přepíná v tabulce projektů. Fáze rozhoduje, kam smí agent
   zapisovat — v `discovery` na zdrojáky nedosáhne, protože je má
   připojené jen ke čtení.

Pak **vyplň `prd/<projekt>/50-glossary.md`**. Je to nejdůležitější soubor
projektu: agent bez klientské terminologie napíše syntakticky správný a
sémanticky špatný kód.

Úkol bez *Definition of Done* panel nezaloží — agent by neměl jak poznat,
že skončil.

---

## 7. Provoz

```bash
agenticdev-ctl status         # co běží, health, otevřené porty
agenticdev-ctl logs [služba]  # živé logy
agenticdev-ctl smoke          # end-to-end kontrola
agenticdev-ctl mac            # přegeneruje instalátor Macu
agenticdev-ctl backup-now     # okamžitá záloha
agenticdev-ctl kill-switch "důvod"   # zastaví vydávání work orderů
agenticdev-ctl resume
```

**Aktualizace platformy.** Nový instalátor pusť stejně jako první:
`bash agenticdev-install-vps.sh`. Migrace schématu dojedou při startu
control plane. Po každé aktualizaci pusť `agenticdev-ctl smoke`.

**Kill switch** používej, když se něco děje a nechceš zastavovat celý
stroj: rozdělaná práce dojede, nové work ordery se přestanou vydávat.

**Brána před mergem.** Runner běží jako služba `runner` v profilu `gate`.
Nový projekt dostane šablonu workflow do `.forgejo/workflows/test.yml`,
branch protection na `main` a webhook, kterým se control plane dozví o
mergi a přepne úkol na `done`. Když panel při zakládání projektu napíše,
že se branch protection nebo webhook nepovedly, chybí `FORGEJO_TOKEN`
nebo `FORGEJO_HOOK_SECRET` v `.env`.

```bash
agenticdev-ctl logs runner    # co runner dělá
agenticdev-ctl smoke          # sekce "Brána před mergem"
```

> Runner potřebuje Docker socket, takže je na tomhle stroji rovnocenný
> rootovi — a běží vedle databáze a podpisového klíče. Kdo umí do repozitáře
> projektu poslat workflow, umí si přečíst `.env`. U vlastních projektů to
> je snesitelné; u repozitáře, do kterého píše někdo cizí, ne.

---

## 8. Co si po nasazení ověř vlastníma očima

Smoke test pokrývá server. Tohle vyžaduje Docker a živé Tailscale, takže
to musí projít člověk. **Dokud tímhle neprojdeš, není ověřené, že agent
pracuje** — smoke test to nezjistí.

Přihlas se jako obyčejný člověk, ne jako root: `tailscale ssh <login>@<vps>`

- [ ] `agenticdev doctor` — všechno zelené, včetně přístupu k Dockeru
- [ ] `agenticdev` otevře výběr projektu
- [ ] Pod naběhne a **Pi se zeptá na model** (poprvé `/login`)
- [ ] Skills a `agenticdev-git` jsou načtené — v Pi zkus `/git-list`.
      Když Pi nabízí jen vestavěné příkazy, nepovedlo se `pi -a` a
      prostředí ze serveru se nenačetlo
- [ ] `git_checkpoint` projde — commit se **nesmí** zastavit na
      „Author identity unknown"
- [ ] Zápis mimo scope selže na `EROFS` — zkus si v `discovery` upravit
      soubor v `src/`
- [ ] Ven se pod dostane jen na domény z allowlistu — zkus `curl` na
      něco, co v něm není
- [ ] Po ukončení podu je větev odeslaná do gitu
- [ ] Druhý člověk může pracovat **současně** s prvním a útrata sedí
      každému na jeho účtu

---

## 9. Když se něco pokazí

| Příznak | Kde hledat |
|---|---|
| instalace spadla | `/srv/agenticdev/install.log`, posledních 30 řádků vypíše sama |
| control plane nenaběhne | `agenticdev-ctl logs control-plane` |
| Forgejo v restart-loopu | práva na `/srv/agenticdev/data/forgejo` (má být `1000:1000`) |
| nic se nepíše do ledgeru | `agenticdev-ctl smoke` → sekce Auditní stopa; restart control plane dojede migrace |
| registrační odkaz nefunguje | `tailscale funnel status`, pak `agenticdev-ctl funnel` |
| certifikát se nevydal | u `.ts.net` zapni HTTPS v Tailscale DNS, pak `agenticdev-ctl restart caddy` |
| stroj se nepřihlásí | `tailscale status` na tom stroji, pak `agenticdev doctor` |
| databáze vidět zvenčí | `agenticdev-ctl status` → porty; publikuje se jen na `VPS_HOST` |

Log instalace i `.env` mají práva `600` a obsahují tajemství — do issue
je neposílej.

---

## 10. Co vědomě není hotové

Před ostrým provozem si přečti [Known
limitations](README.md#known-limitations) a [SECURITY.md](SECURITY.md).
Nejdůležitější: mezi prací agenta a mergem **není serverová brána** —
testy si pouští agent sám ve svém podu. Pro malý tým, který si věří, to
stačí. Jako záruka kvality ne.
