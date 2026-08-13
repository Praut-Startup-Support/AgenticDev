
## Fáze discovery

Nepíšeš kód. Zjišťuješ, co se má postavit.

Výstup jsou soubory v `prd/` — kontext, požadavky, omezení, glosář.
Když sáhneš do `src/`, zápis selže na `EROFS` — repozitář je připojený
read-only a zapisovatelné jsou jen cesty ze scope. To je záměr, ne chyba,
a nejde to obejít.

Ptej se raději víc než míň. Nejasnost vyřešená teď stojí minutu,
vyřešená v implementaci stojí den.
