# Profguild – test v hre (WoW Forever)

Postup pre prvý test v guilde. Treba aspoň 2 ľudí, ideálne 3.

## 1. Inštalácia

1. Zatvor hru.
2. Rozbaľ `Profguild-0.1.0.zip` do `World of Warcraft\_forever_\Interface\AddOns\`.
   Správne je `AddOns\Profguild\Profguild.toc`, nie `AddOns\Profguild\Profguild\Profguild.toc`.
3. Spusti hru, v zozname addonov musí byť Profguild zapnutý a bez „Out of date“.
4. Odporúčané: zapni zobrazovanie Lua chýb (`/console scriptErrors 1`).

## 2. Diagnostika (každý tester)

1. Prihlás sa a počkaj 30 sekúnd.
2. Napíš `/pg debug`, odfoť výstup alebo pošli súbor
   `WTF\Account\<účet>\SavedVariables\Profguild.lua` (diagnostika je v `debug`).
3. Napíš `/pg status`.

Čo z výstupu potrebujeme:

- [ ] `GetProfessions` a `Snapshot` obsahujú všetky tvoje profesie aj First Aid.
- [ ] `Roster row 1` má vyplnené `guid` a `Roster GUIDs complete: true`.
- [ ] `Addon sender name` (po prvej správe od spoluhráča) – v akom tvare je meno.
- [ ] `TooltipDataProcessor: table`.

## 3. Funkcie

| Krok | Očakávaný výsledok |
| --- | --- |
| Otvor každú svoju profesiu | V chate „<Profesia>: recepty uložené a zdieľané s guildou (N)“ |
| U druhého hráča `/pg` | Do 2 minút vidí tvoje recepty, ty jeho |
| Nauč sa nový recept (tréner, zvitok) | V chate „Nový recept zdieľaný…“, u druhého sa objaví bez otvárania okna |
| Najeď myšou na vyrobiteľný item | Riadok „Crafted by: …“ (po slovensky „Vyrobí: …“) |
| Klik na recept v `/pg` | Otvorí whisper crafterovi (over, že meno so priezviskom funguje) |
| Shift+klik na recept | Link itemu do chatu |
| Záložka Members, klik na člena | Zobrazia sa len jeho recepty |
| Tretí hráč sa prihlási, keď je prvý offline | Do 2 minút má aj recepty offline hráča |
| Vstúp do dungeonu, nauč sa recept / zmeň skill | `/pg status` ukazuje čakajúce správy; po odchode sa odošlú |
| Reštart hry | Dáta ostanú (`/pg status` ukazuje rovnaký počet postáv) |
| Zahoď profesiu (na testovacej postave) | Do ~2 minút zmizne u ostatných |

## 4. Čo poslať späť

- Výstup `/pg debug` a `/pg status` od každého testera.
- Každú Lua chybu (screenshot alebo text z BugSack).
- Čo nefungovalo podľa tabuľky vyššie.
