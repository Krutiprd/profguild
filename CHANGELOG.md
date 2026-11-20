# Changelog

## 0.5.0 – 2026-11-20

- Bug reports reach the author through the guild: a report saved with "Report a bug" or
  `/pg bug <text>` is handed to every guildmate with Profguild, who keep it (without showing it)
  and pass it on, so it arrives even when the reporter and the author are never online together
  (messages `BU`, `BD`, `BR`). The author's characters get it in an inbox
  (`ProfguildDB.inbox`, `/pg bug inbox`) with a chat notice; the reporter is told when it
  arrived. Only guilds with one of the author's characters pass reports on; reports are kept
  14 days, 60 in the guild, 10 per player.
- The game's own look: dialog frames with the gold border, the red panel buttons.
- A logo, also as the icon of the minimap button and in the addon list.
- `/pg status` shows the carried reports.

## 0.4.0 – 2026-11-20

- Item requests inside the guild: "ASK THE GUILD" in a recipe's details sends a request (count
  and a short note), also for a recipe nobody knows. The new view "REQUESTS" lists them with the
  state, who asked and who crafts; the details show the reagents, their estimated cost and who
  knows the recipe. The first guildmate to press "I'LL CRAFT IT" takes it; the crafter can give
  it back or mark it done, the requester can mark it done or cancel it. No fees.
- Everybody gets the same list, also players who were offline: digests list every request with
  its version, missing or other versions are asked for, answers serve the whole guild (messages
  `TU`, `TD`, `TR`). When two guildmates take a request at the same time, the earlier take wins
  everywhere. 20 open requests per player, 200 in the guild (finished ones that are no longer
  shown make room first); open and taken requests disappear
  after 7 days; done ones are shown for 2 days, cancelled ones leave the list at once.
- A request changes only while the guild can hear it: in an instance or in combat a button says
  why and does nothing; a change made just before combat goes out as soon as sending works.
  When a take does not count (somebody took it earlier), the chat says so.
- Chat notices: a new request for a recipe you know, and your request taken by somebody.
  `/pg status` shows the requests and their messages.

## 0.3.0 – 2026-11-20

- Guild price sharing: auction prices go to the whole guild, the newer price of an item always
  wins. Only the items Profguild needs are shared (reagents, crafted items, recipe items), and
  nothing is written into Auctionator; prices are kept per guild (`guilds[...].prices`).
- Every reading of the auction house by Auctionator (a search, the refresh button, a full scan)
  is shared as it happens: Profguild follows Auctionator's `Database:ProcessScan` and takes the
  same lowest price and pieces of each item read, stamped with the time of the reading. An item
  with no auctions now and what Auctionator holds from earlier sessions are never sent as new,
  so this morning's scan cannot overwrite a guildmate's newer price.
- Messages: `PU` (up to 100 prices: item, copper, pieces, time, who read it), `PD` (per day of
  the last 14 days: how many prices and a checksum; after every hello, and as an answer to a
  digest that lacks something) and `PR` (a request for the days that differ; one answer serves
  the whole guild). Whatever a client missed (offline, a lost part, a blocked send) shows up as a
  differing day in the next digest and is fetched then, in both directions, so the guild's price
  tables become equal. Values are checked (1c to 999 999g, up to 100 000 pieces, at most 14 days
  old and 2 minutes ahead), 5 000 prices at most and 3 000 read by one guildmate (full tables
  keep the same prices everywhere: newest first), prices older than 14 days are dropped at
  login. A holder sends one answer at a time, a minute apart, and does not resend a day that did
  not change; the same prices of a day are asked for once per 5 minutes in the whole guild.
- `Prices.Get` takes the newer of Auctionator's price (the start of its day, or our own reading)
  and the guild's. The details say whose a guild price is and how old ("from Ana, 2 h ago"), also in the
  reagent tooltip and the recipe item line; the pieces on the market come with it. Without
  Auctionator or TSM the guild's prices are the price source.
- `/pg status` shows the guild prices and their messages.

## 0.2.2 – 2026-11-20

- Bug reports: "Report a bug" in the footer (or `/pg bug`) opens a box for the player's text.
  The report keeps what the window showed when the box opened (view, profession, search,
  filters, the selected recipe with its reagent prices, cost and profit), the price source,
  the version, the last Profguild Lua errors and the last log lines. `/pg bug <text>` saves a
  short note directly, `/pg bug list` prints the newest, `/pg bug clear confirm` deletes them. Reports
  are kept in SavedVariables (`bugs`, the newest 30) and written on /reload or logout.
- Lua errors of Profguild are remembered (`errors`, 20 distinct, counted): the ones Profguild
  catches itself (events, timers, drawing the window) and the ones that reach the game's error
  handler or BugSack, which still see those as before.

## 0.2.1 – 2026-11-20

- Profit of a craft subtracts the 5 % auction house cut from the sale (a vendor price takes
  no cut), the same as Auctionator.
- Reagents keep costing their auction price; when a vendor also sells one, the reagent row in
  the details shows the vendor price beside it, e.g. "(vendor 18s)  22s 40c".
- A crafted item with no auction price is valued at what a vendor pays for it (shown as
  "Vendor pays: ..."), not at what a merchant asks for it. So an item that has not been
  scanned yet now shows its profit against the vendor price, often a loss.
- A long reagent name shortens instead of running into its price.

## 0.2.0 – 2026-11-19

- Recipe catalog: every recipe of a profession, also the ones nobody in the guild has learned.
  The profession window lists the unlearned recipes too, so opening a profession once fills
  the catalog. It is kept for the whole account and shared with the guild: after each hello a
  client sends how many recipes it holds per profession (`KD`), a guildmate with fewer asks for
  that profession (`KR`) and one holder sends the recipe IDs (`KL`). A list is stored only when
  this client asked for it, and each recipe only when the game knows it and puts it in that
  profession; the crafted item comes from the game.
- Recipe filter in the Recipes view: "RECIPES: AVAILABLE" (somebody can craft it, as before),
  "UNAVAILABLE" (nobody in the guild knows it) and "ALL". A recipe nobody knows has a grey
  icon and says so in the list, the tooltip and the details; its reagents and their prices are
  shown like for any other recipe. With "online only" and all recipes, recipes whose crafters
  are offline stay listed. A player filter always lists that player's recipes.
- Where a recipe comes from: when a recipe is opened, the game is asked once where it is found
  (the text of the profession window, "Vendor: … · Zone: …") and the answer is kept. The
  details also show what its recipe item costs at the auction house, live from Auctionator with
  the age of the price; a recipe nobody knows shows that price in the list too. Recipe items
  come from `Data.lua`, generated from Wowhead by `tools/recipe_data.py` (156 recipe items so
  far; the generator waits 2 s between requests and stops when Wowhead refuses one).
- Profit or loss of one craft next to each recipe name in the list ("+12g" green, "-35s" red):
  item price minus the reagents, shown when every price is known.
- Skill levels: the details show from which skill a recipe can be learned (read from the
  tooltip of its recipe item, "Requires Leatherworking (275)") and from which skill it turns
  grey (from the game); the character level the crafted item requires; and a dot in the colour
  of the profession window before each recipe of the logged-in character.
- Leveling view (tab next to Recipes and Members): the recipes of a profession sorted by the
  skill they turn grey at, each with its skill levels (red: learnable from, grey: no more
  skill-ups) and the profit or loss of one craft. It opens at the first recipe that still gives
  skill to the logged-in character. The recipe filter works there too.
- At a profession trainer the skill every recipe needs is read and kept, so recipes without a
  recipe item get their red number too.
- An item that binds on pickup (or a quest item) cannot be sold: its profit is the cost of the
  reagents as a loss, and the details say "BoP: cannot be sold".
- Recipe items Auctionator has seen at the auction house are matched to the recipes by name
  ("Pattern: Big Voodoo Robe"), so their price and the skill from their tooltip are known for
  recipes `Data.lua` does not list. Item data is loaded through a paced queue (items on screen
  first, asked again when it did not arrive), and a tooltip is drawn again when its item arrives.
- "REFRESH PRICES" in the details while the auction house is open: Auctionator searches the
  item, its reagents and its recipe item and saves the current prices; the window updates
  when they are processed. A BoP item is not searched.
- How many are on the market (Auctionator's highest count of the latest day) next to the price
  of the item, of each reagent and of the recipe item.
- `/pg scan` reads the open profession window right away; `/pg catalog clear [profession]`
  forgets the catalog of one profession or all of them.
- The online filter button reads "ONLINE: YES / ALL".
- `/pg status` and `/pg debug` show the catalog; `/pg debug` also says how many recipes the
  last profession window listed and how many of them are not learned.

## 0.1.16 – 2026-11-15

- The recipe list is grouped like a profession window: a gold header before every group, named
  after the crafted item's type ("Armor – Plate", "Weapon – Swords", "Consumable – Potion").
  Armour comes first, then weapons, then the other types; recipes without an item (enchants)
  go to "Other" at the end. Inside a group the highest item level comes first (then required
  level, equipment slot and name); an item the game has not loaded yet is asked for once and
  sorts in when it arrives.
  With all professions shown, the recipes are grouped by profession first.

## 0.1.15 – 2026-11-14

- Player filter in the Recipes view: the "PLAYER: ALL" button opens a menu of everyone who has
  recipes (online first, with the recipe count); choosing a player lists only that player's
  recipes, "All players" clears the filter. It replaces the filter chip.

## 0.1.14 – 2026-11-14

- Notice when a guildmate runs a newer version: once per session in chat, in the window footer
  and in `/pg status`. A newer protocol version is announced in chat once as well.

## 0.1.13 – 2026-11-14

- The Sync button is labelled "SYNC". A manual sync (button or `/pg sync`) says that it started
  and, when no more data arrives, what it brought: every character with a new or changed record
  and the number of added recipes, or that nothing is new.

## 0.1.12 – 2026-11-14

- Fix: the guild's data was saved under "guild name@realm", and on Forever the realm name a
  character reports changes between logins. Every new name started an empty database, so only
  the professions opened in that session were listed. The data is now saved under the guild
  name, and databases saved under the old keys are joined (newest record of each character).

## 0.1.11 – 2026-11-14

Fixes from a code review.

- Sync: a requested record whose answer was lost is requested again after 60 s instead of
  staying missing for the session.
- Sync: answers are sent one at a time with a pause, so a record somebody else already sent can
  still be skipped. A client with an empty database no longer makes every member queue their
  whole database at once.
- Sync: a forged record with the maximum version no longer pins a character's data. At that
  version the copy sent by the owner replaces a different one; the owner is the sender the game
  names, checked against the guild roster. The owner's hello carries a checksum there, so
  members holding another copy fetch the owner's. Needs a roster with GUIDs.
- Comm: received messages are limited to 24 kB encoded; one that unpacks to more than 256 kB is
  dropped before it is deserialized and its sender is ignored for 10 minutes.
- Reagents: an answer from a guildmate is stored only for a recipe this client asked for within
  the last minute; what the game says about a recipe replaces it. The catalog takes at most
  20000 recipes from guildmates.
- Roster: a read that did not return every member updates only those members, so nobody turns
  stale by mistake. Several roster events in a row cause one read. Roster changes no longer
  rebuild the recipe index.
- Window: the list is built in one pass and kept until something it depends on changes; item
  data is requested only for a search. The window keeps refreshing during a long sync.
- Window: recipes with more than 6 reagents scroll with the mouse wheel; the note that covered
  the first reagent is gone.

## 0.1.10 – 2026-11-14

- Addon icon (minimap button, window header, addon list) is the Leatherworking icon.

## 0.1.9 – 2026-11-14

- Diagnostics are saved automatically 45 s after login (`ProfguildDB.debug`, nothing printed),
  and a log of the last 400 events and errors is kept in `ProfguildDB.log`. Both are in the
  SavedVariables file after `/reload` or logout.

## 0.1.8 – 2026-11-14

- `/pg debug` also tests reagents of own recipes with the profession window closed and of
  well-known recipes of every profession.

## 0.1.7 – 2026-11-14

- Reagents of a recipe are read from the game first; the guild is asked only when the game does
  not describe the recipe. `/pg debug` reports how many guildmates' recipes the game describes.

## 0.1.6 – 2026-11-14

- Recipe details list the reagents (icon, amount, price). Reagents are read when a profession
  window is opened and kept per account. Reagents of a guildmate's recipe are asked for when the
  recipe is opened (new Q / C messages, at most 40 recipes each, one answer per question);
  older versions ignore these messages.
- Prices from Auctionator (last auction house scan, then the vendor price it has seen) or from
  TSM DBMarket: cost of one craft, value of the crafted item and the profit.
- "Shopping list" button: creates the Auctionator shopping list "Profguild: <recipe>" with every
  reagent as an exact search and the needed amount; at the auction house Auctionator searches
  right away.
- `/pg status` shows the reagent catalog and the price source; `/pg debug` the price API.
- The window is 60 px taller.

## 0.1.5 – 2026-11-14

- New window in three panels on flat dark backgrounds with brass borders: professions with icons
  and counts on the left, recipes (or members) in the middle, details on the right.
- Recipe details list everyone who can craft it, online first; a click on a crafter whispers.
  A button links the item in chat.
- Member details list their professions with skill and recipe count; a click on a profession
  shows that member's recipes of it. A button whispers the member.
- Recipe rows show the item icon, the name in its quality colour and the first crafters.
- Online-only toggle, member filter chip and a Sync button in the window. The list scrolls with
  the mouse wheel and has no row limit.

## 0.1.4 – 2026-11-14

- Fix: the window showed no recipes. The list was anchored only after its width was read, so
  the rows got a width of 0. The list is anchored when the window is created and its content
  follows the list width.
- The close button hides the window directly.
- An error while drawing the window is printed once and shown in `/pg status`.

## 0.1.3 – 2026-11-14

- Recipes view split by profession: a button per profession (with its recipe count) plus "All".
  "All" lists the recipes under a header per profession. Every recipe row shows who can craft
  it (up to 6 names, online first, the rest as +N; the tooltip lists everyone). The chosen
  profession is saved.

## 0.1.2 – 2026-11-14

- Minimap button: click opens or closes the window, dragging moves the button around the
  minimap, `/pg minimap` hides or shows it. Position and visibility are saved.

## 0.1.1 – 2026-11-14

- Self-heal keeps data: an owner who lost SavedVariables (or plays from a second PC) takes over
  the recipes of not yet rescanned professions from the guild's copy instead of overwriting it.
  A hello that shows a newer own version first asks for that copy (republishes without it after
  20 s). Holders that see the owner announce a version they hold with different content send
  their copy back, so the collision is no longer hidden when both sides count from 1.
- Former guild members are pruned by name when the roster has no GUIDs, but only when the own
  character is found in the roster under the same name form.
- Update debounce only moves a pending update earlier: steady skill-ups no longer postpone it
  forever and no longer hold back a learned recipe.
- Whisper and item link fall back to `ChatFrameUtil` and to opening the chat box; if nothing
  works, the chat says what to type.
- `/pg debug` runs each section protected: an API that errors is reported and the rest is still
  printed and saved. Also reports the chat functions and the roster's last-online data.
- Test runner fails when a test file does not compile instead of skipping it.
- A hello that claims an impossible version of our own record (fractional, above the maximum)
  no longer pushes our version out of the valid range, which stopped the character from
  publishing for good. Such versions are dropped from every hello, the own version is capped at
  the maximum, and a saved version that is already out of range is repaired at the next snapshot.
- Names received from guildmates are stripped of UI escape sequences (`|`) and control
  characters; a class that is not a plain class file name is dropped.
- Roster without GUIDs: online state and the 30-day rule now match names in normalized form,
  so a realm suffix in the roster no longer hides the match.

## 0.1.0 – 2026-11-14

First version for WoW Forever (Interface 16001).

- Own professions and skill read at login; recipes read when a profession window is opened and
  added automatically on `NEW_RECIPE_LEARNED`.
- Peer-to-peer guild sync (hello / request / data) with versioned records, relaying of offline
  members, duplicate suppression, owner self-heal and a queue while sending is blocked.
- Dropped professions removed after two consistent snapshots; former guild members pruned when the
  roster is complete; members offline for 30 days hidden.
- Window with search, Recipes and Members views, online filter, whisper and link on click.
- "Crafted by" line in item tooltips.
- English and Slovak texts; `/pg status` and `/pg debug` diagnostics.
