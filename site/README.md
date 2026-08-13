# Web / Landing page

Jedna statická stránka, dvojjazyčně, nasazuje se na GitHub Pages.
Žádný build, žádné závislosti — `index.html` a čtyři obrázky.

---

## Než to nasadíš

### 1. Formulář

Doplněný je — `index.html` posílá na `https://formspree.io/f/xbgroknv`.
Nasazovací workflow kontroluje, že tam nezůstal zástupný `DOPLN_FORM_ID`,
a když ano, **schválně spadne**: sbírat adresy do prázdna je horší než
formulář nemít.

Když formulář přesměrováváš jinam, změň `action` ve `<form id="f">` a
ověř, že odesílání vrací 200 — stránka hlásí úspěch podle stavového kódu.

Alternativy, kdyby ti Formspree nesedělo: [Tally](https://tally.so),
[Buttondown](https://buttondown.com) (dělaný na newslettery, zdarma do
100 adres), [Formcarry](https://formcarry.com).

### 2. Doména

V `CNAME` je `agenticdev.praut.cz`. Změň, pokud chceš jinou.

U svého DNS poskytovatele přidej záznam:

```
Typ    CNAME
Jméno  agenticdev
Cíl    praut-startup-support.github.io.
TTL    3600
```

Tečka na konci cíle tam patří. **Cíl je jméno účtu, ne produktu** — účet je
`Praut-Startup-Support`, takže Pages jede na `praut-startup-support.github.io`.

#### Ověř, kam doména doopravdy míří

```bash
dig +short agenticdev.praut.cz
```

| Co uvidíš | Co to znamená |
|---|---|
| `185.199.108.153` … `.111.153` | ✅ míří rovnou na GitHub Pages, tak to má být |
| `104.21.x.x`, `172.67.x.x` | ⚠️ **Cloudflare proxy** (oranžový mrak) — viz níž |
| cokoli jiného | ❌ míří jinam, web se nezobrazí |

**Když je tam Cloudflare**, GitHub Pages si nemůže vydat vlastní certifikát,
protože ověřovací požadavek skončí na Cloudflare, ne u GitHubu. Máš dvě
možnosti:

1. **Vypnout proxy** (v Cloudflare přepnout záznam na šedý mrak, „DNS only").
   Pak si GitHub vydá certifikát sám a v Settings → Pages půjde zaškrtnout
   *Enforce HTTPS*. Tohle je jednodušší a doporučuju to.
2. **Nechat proxy zapnutou** a v Cloudflare nastavit SSL/TLS mód na **Full**.
   Při „Flexible" vznikne přesměrovací smyčka, při „Off" to pojede po HTTP.
   *Enforce HTTPS* na straně GitHubu pak nech vypnuté.

Než certifikát naběhne, počítej s desítkami minut. Do té doby může stránka
hlásit chybu certifikátu, i když je jinak nasazená správně.

#### Ověř, že se to vůbec nasadilo

```bash
curl -sSI https://praut-startup-support.github.io/AgenticDev/ | head -1
```

Tahle adresa jede vždycky, i bez vlastní domény. Když vrátí `200`, web je
nasazený a problém je jen v DNS nebo certifikátu. Když vrátí `404`, nenaběhlo
nasazení — koukni do Actions → *pages*.

### 3. Zapni Pages

Settings → Pages → **Source: GitHub Actions**. Ne „Deploy from a branch" —
web se nasazuje workflow z `site/`.

Až se doména propíše, zaškrtni tam **Enforce HTTPS**. Certifikát vydá
GitHub sám, ale trvá to řádově desítky minut po přidání DNS záznamu.

---

## Jak se to nasazuje

Push do `main`, který se dotkne `site/**`, spustí workflow `pages`.
Ručně jde pustit z Actions → pages → Run workflow.

---

## Co je uvnitř

| | |
|---|---|
| `index.html` | celá stránka, včetně stylů i skriptu |
| `logo.svg` | wordmark v hlavičce |
| `agenticdev.ico` | favicon |
| `og.png` | náhled pro sdílení na sítích |
| `CNAME` | doména |

Jazyk se přepíná v prohlížeči přes `localStorage`, výchozí se hádá z
nastavení prohlížeče. Bez JavaScriptu se zobrazí česká verze.

Každý text existuje dvakrát — `<span class="cs">` a `<span class="en">`.
Když přidáváš odstavec, přidej obě varianty; jinak ve druhém jazyce
zmizí. Schéma izolace je výjimka: jsou to dva celé bloky `<pre>`,
protože v jednom by se rozsypalo zarovnání.

---

## Osobní údaje

Formulář má povinné zaškrtávátko se souhlasem, uvedený jediný účel a
adresu pro odvolání. To je minimum, ne komplet — až budeš adresy
skutečně používat, hodí se k tomu mít i informační sdělení podle GDPR
a někde zapsané, kdy kdo souhlas dal.

Formspree ty adresy drží u sebe, takže je to zpracovatel — na to se
váže zpracovatelská smlouva. Mají ji jako součást podmínek, ale je dobré
si to přečíst, než tam padne první adresa.
