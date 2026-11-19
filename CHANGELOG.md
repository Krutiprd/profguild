# Changelog

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
