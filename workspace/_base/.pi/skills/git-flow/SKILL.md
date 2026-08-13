---
name: git-flow
description: Větvení, checkpointy a odevzdání práce přes agenticdev-git.
hidden: true
---

# Git flow

Nikdy nepracuj na `main`. Vždy přes `bin/agenticdev-git`.

## Začátek úkolu

```bash
cd "$(bin/agenticdev-git start "krátký popis úkolu" T-042)"
```

Založí větev z aktuálního `origin/main` a **samostatný worktree**.
Rozdělané úkoly tak leží vedle sebe, přepínáš bez stashování.

## Během práce

```bash
bin/agenticdev-git checkpoint "co jsem právě dodělal"
```

Volej to často — po každém kusu, který dává smysl. Checkpointy jsou
levné, sesypou se při odevzdání. Dělají `git bisect` použitelným
a dovolují vrátit se o krok zpět.

Když je kus hotový a otestovaný:

```bash
bin/agenticdev-git save feat import "import karet z DE systému"
```

Typ: `feat` `fix` `refactor` `test` `docs` `chore` `perf` `build` `ci`

## Odevzdání

```bash
bin/agenticdev-git finish "feat(import): karty z DE systému"
```

Sesype wip commity do jednoho a narovná na main. Odeslat větev a otevřít PR
už není práce podu — agent nemá k repozitáři přístup ani token do Forgeja.
`finish` proto nechá vzkaz v `.agenticdev/finished` a zbytek udělá launcher
na VPS, až pod skončí. Nečekej v podu na URL toho PR, tam nevznikne.

## Když nejde narovnat na main

`sync` i `finish` skončí hláškou „konflikt s main". To není chyba, kterou
máš obejít. Nástroj už vrátil větev do stavu před rebasem, takže se nic
neztratilo, a konflikt zapsal na VPS jako rozhodnutí pro člověka.

Ty v tu chvíli:

1. Neodevzdávej. `finish` schválně nepokračuje.
2. Řekni člověku, které soubory kolidují — nástroj je vypsal.
3. Nezkoušej `git rebase`, `git merge` ani `git checkout --ours` naslepo.

## Ostatní

```bash
bin/agenticdev-git sync                # rebase na aktuální main
bin/agenticdev-git list                # rozdělané úkoly
bin/agenticdev-git who src/a.ts 42     # ze které session je ten řádek
bin/agenticdev-git cleanup             # smaže smergované
```

## Pravidla

- Před `finish` vždy spusť testy. Když padají, neodevzdávej.
- Konflikt při rebase neřeš naslepo — viz sekci výš.
- Nikdy `git push --force` napřímo, `finish` používá `--force-with-lease`.
- Nikdy neměň historii větve, která už je v PR.
