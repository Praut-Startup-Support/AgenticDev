# Kam s tím / Where to go

## 🇨🇿 Česky

| Máš… | Jdi sem |
|---|---|
| **Nefunguje instalace** | Nejdřív `bash tools/preflight-vps.sh`, pak [DEPLOY.md](DEPLOY.md). Když to pořád padá, [založ issue](https://github.com/Praut-Startup-Support/AgenticDev/issues/new?template=bug.yml) a přilož `/var/log/agenticdev-install.log` |
| **Něco se chová divně za běhu** | `agenticdev-ctl smoke` — projede 38+ kontrol a řekne, co nesedí. Výstup přilož do issue |
| **Otázku, jak něco funguje** | [Diskuse](https://github.com/Praut-Startup-Support/AgenticDev/discussions), ne issue |
| **Nápad na funkci** | [Feature request](https://github.com/Praut-Startup-Support/AgenticDev/issues/new?template=feature.yml). Přečti si ale [CONTRIBUTING.md](CONTRIBUTING.md) — příspěvky bereme jinak, než čekáš |
| **Bezpečnostní díru** | **Nikdy do veřejného issue.** Postup je v [SECURITY.md](SECURITY.md) |
| **Zájem o komerční licenci** | **svanda@praut.cz** — viz [LICENSE-FAQ.md](LICENSE-FAQ.md) |

### Než založíš issue

Tři věci, které ušetří jedno kolo dotazů:

1. **Verze.** `agenticdev-ctl status` nebo tag, ze kterého jsi stavěl.
2. **Režim.** Tailscale, nebo doména? Je to v `.env` jako `AGENTICDEV_CONNECT`.
3. **Co jsi čekal a co se stalo.** Ne „nefunguje to" — spíš „po `agenticdev
   work` skončí pod hláškou X, čekal jsem, že naběhne agent".

### Na co odpověď nedostaneš

Tenhle projekt dělá jedna firma vedle zakázek. Není tu SLA a na některé věci
se nedostane. Když potřebuješ garantovanou podporu, je to součást komerční
licence — napiš na tu adresu výš.

**Stav projektu je alpha.** Sandbox neběžel proti skutečnému Dockeru,
doménový režim proti skutečné doméně. Než to nasadíš na ostro, přečti si
*Známá omezení* v [README.cs.md](README.cs.md).

---

## 🇬🇧 English

| You have… | Go here |
|---|---|
| **The install fails** | Run `bash tools/preflight-vps.sh` first, then read [DEPLOY.md](DEPLOY.md) (Czech). Still failing? [Open an issue](https://github.com/Praut-Startup-Support/AgenticDev/issues/new?template=bug.yml) and attach `/var/log/agenticdev-install.log` |
| **Something behaves oddly at runtime** | `agenticdev-ctl smoke` — 38+ checks that say what is wrong. Attach the output |
| **A question about how something works** | [Discussions](https://github.com/Praut-Startup-Support/AgenticDev/discussions), not issues |
| **An idea for a feature** | [Feature request](https://github.com/Praut-Startup-Support/AgenticDev/issues/new?template=feature.yml). Read [CONTRIBUTING.md](CONTRIBUTING.md) first — contributions work differently here than you expect |
| **A security hole** | **Never in a public issue.** See [SECURITY.md](SECURITY.md) |
| **Interest in a commercial licence** | **svanda@praut.cz** — see [LICENSE-FAQ.md](LICENSE-FAQ.md) |

### Before you open an issue

Three things that save a round trip:

1. **Version.** `agenticdev-ctl status`, or the tag you built from.
2. **Mode.** Tailscale or domain? It is `AGENTICDEV_CONNECT` in `.env`.
3. **What you expected and what happened.** Not "it doesn't work" — rather
   "after `agenticdev work` the pod exits with X; I expected the agent to
   start".

### What you will not get an answer to

This is built by one company alongside client work. There is no SLA and some
things will not get attention. If you need guaranteed support, it comes with
a commercial licence — write to the address above.

**The project is alpha.** The sandbox has not run against a real Docker
daemon, nor the domain mode against a real domain. Read *Known limitations*
in [README.md](README.md) before deploying it for real.
