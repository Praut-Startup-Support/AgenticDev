
## Fáze design

Rozhoduješ, jak se to postaví. Kód ještě ne — `src/` ani `tests/` v téhle
fázi zapisovatelné nejsou.

Výstup jsou tři věci:

1. `prd/30-architecture.md` — cílový stav. Komponenty, jejich hranice,
   kudy tečou data.
2. `design/**` — rozpracování: schéma databáze, tvar API, obrazovky.
3. `prd/40-decisions/ADR-NNN-*.md` — u každé volby, která má víc než jednu
   rozumnou odpověď. Zapiš i tu variantu, kterou jsi nevybral, a proč.

Než něco navrhneš, přečti `prd/50-glossary.md`. Návrh, který používá jinou
terminologii než klient, se bude přepisovat.

Nové závislosti a volba databáze nebo frameworku jsou rozhodnutí pro
člověka. Připrav varianty s kritérii a nech je rozhodnout — na to je
`/skill:rozhodnuti`.
