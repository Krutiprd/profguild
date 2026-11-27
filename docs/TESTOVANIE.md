# Profguild – test v hre (WoW Forever)

Postup pre prvý test v guilde. Treba aspoň 2 ľudí, ideálne 3.

## 1. Inštalácia

1. Zatvor hru.
2. Rozbaľ `Profguild-0.7.0.zip` do `World of Warcraft\_forever_\Interface\AddOns\`.
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
| Klik na recept v `/pg` | Vpravo detail: ikona, názov a zoznam tých, čo ho vyrobia (online prví) |
| Otvor svoju profesiu, potom klik na svoj recept | V detaile suroviny s ikonou a počtom |
| Klik na recept spoluhráča (on má 0.1.6 a otvoril profesiu) | „Pýtam sa guildy…“, do 5 sekúnd sa objavia suroviny |
| S Auctionatorom po skene aukcie | Cena každej suroviny, cena craftu, hodnota itemu a zisk |
| Tlačidlo „Nákupný zoznam“ | V Auctionatori zoznam „Profguild: <recept>“; na aukcii hneď hľadá |
| Klik na craftera v detaile | Otvorí whisper (over, že meno so priezviskom funguje) |
| Shift+klik na recept alebo tlačidlo „Link itemu do chatu“ | Link itemu do chatu |
| Záložka Členovia, klik na člena | Vpravo jeho profesie so skillom a počtom receptov |
| Klik na profesiu v detaile člena | Recepty tohto člena z tej profesie, tlačidlo „Hráč“ ukazuje jeho meno |
| Tlačidlo „Hráč: všetci“ v Receptoch | Zoznam hráčov s receptami; výber ukáže len jeho recepty, „Všetci hráči“ filter zruší |
| Tretí hráč sa prihlási, keď je prvý offline | Do 2 minút má aj recepty offline hráča |
| Vstúp do dungeonu, nauč sa recept / zmeň skill | `/pg status` ukazuje čakajúce správy; po odchode sa odošlú |
| `/pg` | Okno v troch paneloch: profesie, recepty, detail; krížik a Esc ho zavrú |
| Klik na profesiu vľavo | Len jej recepty; po `/reload` ostane vybraná. „Všetky“ ukáže všetko |
| Zoznam receptov (aj spoluhráča) | Zlaté nadpisy skupín podľa typu itemu (napr. „Armor – Plate“), brnenie prvé, enchanty v „Ostatné“ na konci; v skupine najvyšší item level hore; nadpis sa nedá vybrať |
| Klik na nadpis skupiny [-] | Skupina sa zbalí na [+] s počtom receptov; počet receptov hore ani otvorený detail sa nezmenia; po `/reload` ostane zbalená; hľadanie ukáže aj jej recepty |
| Prihlás sa, počkaj 30 sekúnd, „NEDOSTUPNÉ“, Blacksmithing a Tailoring | Recepty aj bez toho, že by okno profesie niekto v guilde otvoril |
| Koliesko myši nad zoznamom | Zoznam sa posunie, vpravo sa hýbe zlatý pruh |
| „ONLINE: ÁNO“ a „Sync guildy“ | Filter len online crafterov; sync vypíše správu do chatu |
| Otvor profesiu, potom „RECEPTY: DOSTUPNÉ“ → „NEDOSTUPNÉ“ | Recepty, ktoré v guilde nikto nevie: sivá ikona, „v guilde to nikto nevie“, v detaile suroviny s cenou |
| Klik na nedostupný recept (napr. Alchemy) po skene AH | V detaile „Recept: drop, vendor · na AH 37g 40s (dnes)“; v zozname „recept na AH …“ |
| Ďalší klik „RECEPTY: VŠETKY“, potom znova „DOSTUPNÉ“ | Všetky recepty spolu; potom len tie, čo niekto vie |
| Dvaja hráči po minúte od prihlásenia dajú `/pg sync`, potom obaja `/pg status` | Po ďalšej minúte majú v katalógu receptov rovnaké počty |
| Klik na ikonu pri minimape | Otvorí a zavrie okno; ťahaním sa ikona posúva okolo minimapy |
| `/pg minimap` | Ikona zmizne, druhý raz sa vráti; po `/reload` ostane poloha aj skrytie |
| Reštart hry | Dáta ostanú (`/pg status` ukazuje rovnaký počet postáv) |
| Zahoď profesiu (na testovacej postave) | Do ~2 minút zmizne u ostatných |

## 4. Zdieľanie cien (0.3.0)

Treba 2 hráčov s Profguildom 0.3.0, aspoň jeden s Auctionatorom.

| Krok | Očakávaný výsledok |
| --- | --- |
| Hráč A otvorí aukciu, v detaile receptu dá AKTUALIZOVAŤ CENY | Do pár sekúnd má hráč B pri tom recepte nové ceny; v detaile „(… ks, od A, pred 1 min)“, pri surovine v tooltipe „Cena od guildy: od A, …“ |
| A spraví plný sken (Auctionator → Full Scan) a zatvorí aukciu | B dostane ceny surovín a výrobkov, ktoré A videl v ten deň |
| Hráč C sa prihlási neskôr | Do minúty po prihlásení má rovnaké ceny ako A (cez digest a žiadosť) |
| B má starší sken z rána, A aktualizuje cenu | B ukazuje cenu od A, nie svoju rannú |
| A sa odhlási a prihlási | Po prihlásení nič neodošle (staré ceny z Auctionatora sa len zapíšu) |
| `/pg status` u oboch | Riadok „Ceny od guildy: N, najnovšia pred …“, odoslané a prijaté U/D/R |
| Hráč bez Auctionatora | Vidí ceny od guildy, zisk aj cenu craftu |

## 5. Požiadavky v guilde (0.4.0)

Treba 2–3 hráčov s Profguildom 0.4.0.

| Krok | Očakávaný výsledok |
| --- | --- |
| A otvorí recept v `/pg`, dá „POŽIADAŤ O VÝROBU“, počet 2, poznámka | V chate „Požiadavka odoslaná guilde“; v karte „POŽIADAVKY“ je „2x …“, otvorená |
| A v karte POŽIADAVKY dá „NOVÁ POŽIADAVKA“, napíše časť názvu a vyberie recept | Nájde aj recept, ktorý nikto nevie („nikto nevie“). Presný názov je prvý, koliesko posúva dlhší zoznam; „ODOSLAŤ“ funguje až po výbere |
| B, ktorý recept vie | V chate „A žiada guildu o 2x …“; v karte POŽIADAVKY ju vidí |
| B dá „VYROBÍM TO“ | U A v chate „B vyrobí tvoju požiadavku“; stav „prevzal B“ u všetkých |
| B a C dajú „VYROBÍM TO“ naraz (na pokyn) | Po pár sekundách u všetkých ten istý výrobca (kto bol skôr); ten druhý dostane v chate „Tvoje prevzatie … neplatí“ |
| B je v dungeone alebo v boji a dá „VYROBÍM TO“ | V chate „Teraz nie: …“, požiadavka sa nezmení |
| B dá „VZDAŤ SA“ | Požiadavka je znova otvorená |
| B (alebo A) dá „HOTOVO“ | Stav „hotové“ u všetkých; po 2 dňoch zmizne |
| A dá „ZRUŠIŤ POŽIADAVKU“ | Požiadavka zmizne zo zoznamu u všetkých |
| C sa prihlási neskôr | Do minúty vidí tie isté požiadavky v tom istom stave |
| `/pg status` | Riadok „Požiadavky: N otvorených, M prevzatých …“ |

## 6. Trainery a predajcovia (0.7.0)

Treba 2 hráčov s Profguildom 0.7.0 v jednej guilde a rovnakej frakcii; A je skúsený, B práve
založená postava alebo hráč, ktorý sa práve prihlásil. Požiadavky aj ceny z 0.3.0–0.6.0 fungujú ako predtým.

| Krok | Očakávaný výsledok |
| --- | --- |
| A otvorí trénera povolania a zavrie okno | Žiadna Lua chyba, okno trénera sa viditeľne nezmenilo: filtre aj vybraný recept ostali, ako boli. Tréner sa prečíta celý, nech je nastavený akýkoľvek filter. `/pg npc` ukáže +1 NPC a počet receptov |
| Tréner, kde vieš všetko (napr. alchýmia 300, skryté známe recepty) | `/pg npc` ukáže všetky jeho recepty, nie len tie, ktoré okno práve zobrazuje |
| B po ~1 minúte otvorí v `/pg` recept, ktorý ten tréner učí, a dá „NÁJSŤ RECEPT“ | Riadok „Tréner: <meno>“ so zónou, polohou a cenou so `~` (cena od spoluhráča); hover ukáže „videné pred n dňami“ |
| A otvorí predajcu receptov (recept s cenou, s „obmedzené množstvo“) | `/pg npc` ukáže predajcu; u B riadok „Vendor: …“ s cenou, „obmedzené množstvo“ |
| A znova otvorí toho istého trénera s iným filtrom (napr. skryté známe recepty) | Tréner sa prečíta celý ako predtým, nič sa nestratí; filter a výber v okne ostanú, ako ich A nastavil |
| Nová postava C sa prihlási a hneď (do 5 s) otvorí trénera | Dáta od A a B ostanú, C dostane tabuľku guildy do pár minút (`/pg npc` rastie) |
| A otvorí trénera v boji (alebo B v boji otvorí predajcu) | Kým trvá boj, nič sa nezapíše, žiadna chyba; ak je okno po boji ešte otvorené, zapíše sa hneď po boji (inak pri ďalšom otvorení) |
| A vidí vlastnú cenu iného dňa | Vlastná cena z posledných 30 dní je bez `~`, cena guildy so `~` |
| Recept bez trénera aj predajcu | „zdroj nie je známy“ / „pravdepodobne tréner, guilda zatiaľ žiadneho nevidela“ / „guilda zatiaľ nevidela vendora“, aukcia ak recept má predmet |
| Zelený rám | Má ho riadok s najnižšou cenou (aspoň dva riadky s cenou) |
| Tlačidlo „NÁJSŤ RECEPT“ znova, „SPÄŤ K SUROVINÁM“, iný recept, iná karta | Návrat k surovinám, žiadna Lua chyba, kolieskom sa posúva zoznam |
| Tlačidlo „Mapa“ pri trénerovi | Na mape sa objaví špendlík na mieste NPC (alebo TomTom, ak je); v chate „Značka na mape: <meno>“, ak sa nedá, „Značku na mapu sa nepodarilo dať.“ |
| `/pg status` a `/pg npc` | Riadok o NPC dátach; počty NPC, receptov a preskočených mien |
| `/pg npc clear` | Dáta frakcie zmiznú lokálne; do pár minút ich guilda pošle späť |
| Hneď po prihlásení s veľkou tabuľkou (prvé 1–2 s) `/pg npc` a „NÁJSŤ RECEPT“ | `/pg npc` napíše, že sa údaje o NPC ešte načítavajú; riadok namiesto „guilda zatiaľ nevidela vendora“ hovorí „údaje o NPC sa načítavajú...“; o chvíľu sú počty a riadky ako inokedy |
| Hra beží cez polnoc servera (alebo `/reload` tesne po nej) | Žiadna Lua chyba; `/pg npc` po polnoci ukazuje počty, guilda sa ďalej zhoduje (žiadne opakované posielanie toho istého) |

Zatiaľ neoverené v hre, pozorne skontroluj a pošli výsledok:

- Špendlík na mape (`Mapa`): ukáže sa, v správnom meste a na správnom mieste? Bez TomTom aj s ním.
- Predajca s inou menou (žetóny, odznaky, predmet namiesto zlata): cena a „iná cena“ v riadku.
- Obmedzený počet pri predajcovi: riadok hovorí „obmedzené množstvo“ (pred zónou; hover ho ukáže tiež), cena je v riadku mena.
- Dve reputácie: tá istá cena pri inej reputácii (zľava) nerobí zmätok; po čase zostane základná cena.
- Tréner s akýmikoľvek filtrami (všetky zapnuté, alebo skryté nedostupné/známe): prečítajú sa všetky recepty, žiadne dvojité; filtre a vybraný recept v okne ostanú, ako boli, okno nebliká a iný doplnok trénera (napr. OneForAll) sa nespráva inak.
- Neanglické názvy povolaní a receptov (klient v inom jazyku): recepty sa priradia, `/pg npc` nehlási veľa preskočených mien.

## 7. Hlásenie chyby

Keď niečo nesedí, nahlás to hneď, kým je to na obrazovke:

1. Nechaj otvorený recept alebo hráča, ktorého sa chyba týka.
2. Klikni na „Nahlásiť chybu“ dole v okne (alebo napíš `/pg bug`), napíš čo sa stalo
   a čo si čakal, a daj „Uložiť“. Krátka poznámka ide aj priamo: `/pg bug zisk nesedí`.
3. K hláseniu sa samo uloží: verzia, čo ukazuje okno (recept, ceny surovín, zisk),
   zdroj cien, posledné Lua chyby Profguildu a posledné riadky logu.
4. Do súboru sa hlásenia zapíšu pri `/reload` alebo odhlásení:
   `WTF\Account\<účet>\SavedVariables\Profguild.lua`, časť `bugs`.

`/pg bug list` vypíše posledné hlásenia, `/pg bug clear confirm` ich zmaže aj so zapamätanými chybami.

Od 0.5.0 ide hlásenie samo autorovi cez guildu (ak je niektorá z jeho postáv v guilde). V chate
sa ukáže „Hlásenie ide autorovi cez guildu…“ a neskôr „Tvoje hlásenie #N prišlo autorovi“.

| Test | Čo má byť |
|---|---|
| A uloží hlásenie, autor je online | Autorovi príde do pár sekúnd „Nové hlásenie chyby od A…“, A dostane „prišlo autorovi“ |
| A uloží hlásenie, autor offline, B online; A sa odhlási, potom príde autor | Autor ho dostane od B (do pár minút po prihlásení) |
| Autor: `/pg bug inbox` | Posledné hlásenia s menom, časom, verziou a textom |
| `/pg status` | Riadok „Nesené hlásenia chýb: …, autor v guilde: áno“ |

## 8. Čo poslať späť

- Výstup `/pg debug` a `/pg status` od každého testera.
- Každú Lua chybu (screenshot alebo text z BugSack); Profguild si ich pamätá aj sám (`errors`).
- Súbor `SavedVariables\Profguild.lua` s hláseniami (`bugs`).
- Čo nefungovalo podľa tabuľky vyššie.
