# 0.7.0 – Learning trainers and recipe vendors from NPCs (design)

Decisions of the user are marked *(user)*, decisions taken here *(call)*. Revision 6, after ten
independent readers (history at the end).

## Intent

One guildmate opens a trainer or a vendor; the whole guild then sees in a recipe's details where
the recipe is learned or bought, from which skill and for how much *(user)*. There is no clean
source for this: it is server data, not in the client tables, and GPL databases (Questie,
OneForAll, AzerothCore) must not be used. So the addon collects it by being played with.

Success: after some weeks of normal play most trainer recipes of the guild's professions show a
trainer, without anybody doing anything for it, and nobody notices the traffic.

Non-goals: reagents sold by vendors (a later version, *(user)* starts with recipes), drops and
quest rewards, map pins, routes, data shipped with the addon, sharing between guilds, judging
whether the viewer meets a recipe's requirements (the game's tooltip on hover says them).

Anti-goals: the addon changes filters or anything else in the trainer or merchant window; the other
messages of the addon get slower; clients overwrite each other back and forth; made-up or wrong
data cannot be got rid of.

## Today

- Core.lua `readTrainer` runs 0.5 s after TRAINER_SHOW / TRAINER_UPDATE, matches services to catalog
  recipes by name and keeps the skill in `ProfguildDB.recipeInfo[recipeID].m`. No NPC, local only.
- No merchant capture. Data.lua has 2501 recipes: 694 without a recipe item, 863 sold by some NPC.
- Data.lua has yellow and grey for every recipe, the window shows only learn and grey
  (`recipeSkillText`). 19 entries have learn >= grey and one yellow > grey.

## Approaches

- **A. A module of its own, NpcData.lua (chosen by the user).** Independent of 0.6.0 clients, reaches
  members who were offline. Most code.
- B. Extend the catalog's channel (KD/KR/KL). 0.6.0 sends only recipe IDs there.
- C. Put it into the character records. The data leaves with the player.

Inside A: (1) ever-growing joined tables with hash buckets: wrong entries stay for ever, a small gap moves
nearly everything. (2) One sheet per NPC, the newest replaces the other whole: a newcomer's partial
reading destroys the guild's full sheet (windows hide services by filter). (3) **chosen:** one sheet per NPC
as the unit of transfer, merged entry by entry, every entry with the day it was read.

## Data

A sheet holds what is known about one NPC, keyed by the NPC ID from `UnitGUID("npc")` of a creature:

| Part | Key | Registers (each with its own day) | Limits |
|---|---|---|---|
| head | - | name; place (uiMapID, finder's position in whole percent) | name 1-60 bytes without `|` and control characters; map 0-100000; x, y 0-100 |
| trained | recipeID | seen; skill; copper | 200 entries; skill 1-1000; copper 1c-999 999g |
| sold | recipe item ID | seen; price (copper 0-999 999g, up to 3 other costs: currency or item, ID, count; limited stock) | 60 entries |

A *register* is a value and the UTC day (server time / 86400) it was read. Unknown means the register is
absent; `seen` is only a day. On the wire and on disk days are stored relative to a base (usually all equal).

**Merge**, register by register: the later day wins; equal day: the greater value, compared as numbers in a
fixed field order (names as bytes). An absent one takes the other's. A join: any order and any duplicates
give the same, and an unknown never erases a known value.

**Expiry:** a register not read for 120 days is removed, an entry when `seen` is; the head goes with the last
entry, and its own days do not expire. Done before every digest, inventory and answer, and at load. *Sendable* is an
entry whose `seen` is at most 118 days old, with its registers of at most 118 days, and the head of a sheet with a
sendable entry. Only that is sent, hashed, counted and compared. A received entry without `seen` is ignored, so is a register
older than 120 days or with a day later than tomorrow.

**Own visit** is turned into registers of today, and these are merged (so one that loses a tie changes nothing):
- `seen`: when absent or older than 14 days.
- skill, place, name: when absent, or held is older than 14 days.
- price: when absent; other costs or limited stock differ and held older than 14 days; at the same other costs and
  stock: higher copper than held; equal and held older than 14 days; lower and held older than 30 days. Reputation lowers prices, so the base price
  mostly stays (a joiner or a client offline for long may replace it by a discounted one until somebody reads the
  higher). One too high is corrected by the first lower reading more than 30 days after its saved day.
- What is unknown or not read is left alone and expires. Nothing is deleted because a window hid it, and a second
  identical reading the same day sends nothing.

**Wrong data** is overwritten as above or expires 120 days after it was last read. A wrong entry that a faulty
reader keeps reading goes only with the fix and `EPOCH`, a constant of the release carried in every message and
saved with the tables: other epochs are ignored and dropped at load. That loses the good data too *(call)*.
`/pg npc clear` drops what is held for the current faction, npcOwn too; the guild's comes back.

Saved: `ProfguildDB.guilds[key].npc[faction] = { e = EPOCH, s = { [npcID] = sheet } }`, the guild's, and
`ProfguildDB.npcOwn[faction]` (no realm: its name changes between logins, see Scanner.GuildKey), the same shape: only what was read on this account, always the last known
reading of each register with its day (local, no traffic). At guild setup every npcOwn register goes into the
guild's table by the own-visit rules as of its own day (older or equal days change nothing). So nothing learned from guild A
reaches guild B. Without a guild the window reads npcOwn. Both tables are validated at load like messages.
Messages carry the faction, another one is ignored.

Limits, applied in this order after a merge: entries per sheet (no limit by size: one by content does not converge); 20 000 entries; 600 sheets. The older goes first (`seen`; a
sheet by its newest entry), then by a hash of the key (not by ID: new recipes have the highest IDs). A message over
4 kB (as received, encoded) is ignored; the largest sheet must fit (a test).
Any change of fields, order or limits raises EPOCH or the protocol. Receipt never depends on Data.lua or the catalog.

Trust: the guild is trusted as for prices. A malicious member can fill the table and waste
traffic within bounds; kicking and EPOCH help.

## Reading

Trainer: the NPC and place are taken at TRAINER_SHOW; the services 0.5 s later (existing debounce) and
at TRAINER_UPDATE, only while the same NPC is open. Only profession trainers. The profession is the one
GetTrainerServiceSkillReq names; a service without a requirement takes the only profession of the other
services, else it is left out. Service to recipe, among the recipes (Data.lua and catalog) of that profession:
1. an exact spell ID, if the probe finds one;
2. the only recipe of that name;
3. the only one of these that Data.lua says has no recipe item;
4. the only one of those left by 3 (or of all, when 3 left none) whose Data.lua grey is at least the skill.
Otherwise not recorded, and counted for `/pg npc`. Recipes without Data.lua take part in 1 and 2 only. After
matching, two services that give one recipe different values are both left out, and a skill above the recipe's Data.lua grey is recorded as unknown. While a recipe's name is
not loaded, 2-4 decide nothing for its profession; tried again 60 s later by a timer (the same NPC still open), from then on such
recipes are left out. `recipeInfo.m` keeps its present behaviour.

Merchant: MERCHANT_SHOW and MERCHANT_UPDATE, 0.5 s debounce, all entries by index. An item counts when
`GetItemInfoInstant` says class 9 or Data.lua has it as a recipe item. Some entry without an item ID yet: again
1 s later, at most 5 times; the same for an other cost whose ID is not known, such an entry is never recorded in part. Two entries
of one item that differ: `seen` only, price unknown. A merchant that sells no recipe makes no sheet.

Nothing the game marks secret (`issecretvalue`) is read. Not in combat.

**Probe first.** A throwaway addon outside the repo logs raw values in the live client: API names and returns
of both windows, whether known services are listed and their cost, `UnitGUID("npc")`, position and map, other
costs, spell IDs of services, services without a requirement, equal names per profession, merchant filter and
conditional items, price at two reputations if possible, guild and faction. Gate: without a usable NPC ID
this design is stopped and discussed again. Anything else found changes only the reader.

## Sharing

Prefix `ProfguildNPC`, GUILD channel, encoding, size limits and sender block of Comm (shared, not copied).
The throttle queues per prefix, so this does not stand in front of recipes, prices and requests, and 0.6.0
clients do not receive it. Sends follow `ns.SendBlockReason`. All messages carry protocol, epoch, faction, sender.

- `ND` digest: number of sheets and one hash of the table (at least 31 bits).
- `NI` inventory, to everyone: (NPC ID, 16-bit hash of the random number of this NI together with the sheet's content hash of at least 31 bits) of all
  sendable sheets, delta coded (about 0.75 kB for 180, 1.7 kB for 600).
- `NR` request, to the sender of an NI: NPC IDs.
- `NU` update: whole sheets, about 1 kB per message.
All carry the sender's current table hash, which replaces what was known of it.

Rules, simulated by reader 10 for revision 5 with registers and own visits (repo encoding, per-prefix throttle, 2 % and 5 % loss
per part, 20/72/200 clients): all 180 burst runs equal within 375 s. The changes of revision 6 were simulated one by one or in part.
Epoch, faction and 0.6.0 were not simulated. The plan rebuilds the simulation as tests before the module is
wired in; its targets bind, and details may change to meet them. A *round* begins with an NI and ends with 12 s
without NI, NR, NU.
1. ND 10 s after hello (login and periodic), unless an equal one was heard in the last 10 minutes. An ND of ours that no equal
   ND confirmed in 60-120 s is repeated, at most 3 times, after 12 s without NI, NR, NU.
2. Hearing a differing ND: plan an NI in 2-20 s. Any NI heard cancels it. It waits for 12 s without data and then a fresh random
   0-12 s, 120 s at most, and is dropped when the hash of that ND is ours by then. Own NI at most every 65 s, an earlier one is delayed.
3. NI heard: everyone plans NU of the sheets it lacks or has with another hash, after 0.5-10 s, starting at a random
   place. A sheet heard meanwhile in identical content is left out; all is dropped when the NI sender's hash becomes ours.
   An NU that holds, in identical content, a sheet we had planned postpones the rest by 40-60 s (so one that fell silent is
   replaced); no other NU does.
4. IDs we lack: one NR to the NI's sender after 1-8 s, without IDs in NRs or NUs heard;
   none when 10 NRs to that sender were heard or sent in the last hour. It answers with NU. The sender of the
   NI also sends a merged sheet when merging its own into the received one changes the received one, at most once per sheet and
   round. Everybody merges every NU. A sheet received of which nothing is held (limits) is remembered for the session (ID,
   content; the latest 100): our NIs list it as held with that content, and we do not ask for it. A sheet taken in part is not.
5. 12-24 s after the last NI, NR or NU: ND if our hash changed or differs from the NI's, unless an equal one was heard; at most one
   per 30 s.
6. After 2 rounds without any NU or NR (bystanders count them too), or 3 own NIs for it, the pair (our hash, their hash) is
   ignored for an hour. Any change of either hash lifts it.
7. The next message goes when the one before has left, plus 1 s per part. Blocked: what waits is dropped; the next
   hello's ND brings it.
8. An own visit sends its changed sheet (whole) after 3 s; blocked: as rule 7.
9. Caps, by the sender name the game gives (not a field of the message): one NI per 60 s and 2 ND per minute have any
   effect; the same sheet content is sent at most 6 times an hour for one sender, and for one table hash
   carried by NIs: one counter per (name, content) and one per (hash, content),
   raised for every NI and NR heard that lacks or asks for it, whoever it is addressed to.
10. A failed send (OnSendFailed) undoes its marks. Guild change stops the object.

## Window

Detail of a recipe:

```
Recipe: trainer                                    (existing source line)
Hahrana Ironhide (+2), Feralas 74,43 · ~40s        (new line)
[ REQUEST CRAFT ]            100 · 120 · 130 · 140  (numbers: right of the button, right-aligned)
```

- The new line has its own hover area; it and the numbers are empty for members.
- Vendors of a recipe are those of Data.lua's recipe item or of the one in `recipeItems`.
- The new line shows the trainer, else the vendor. Which of several: the player's map, then the lowest price,
  then name. "(+2)" counts the others. `~` marks a price from guildmates. What this
  account read itself (npcOwn) in the last 30 days is shown instead of the guild's, without `~`; also no `~` when both are equal. Unknown price or position: left out. Limited stock and other
  costs ("5 Merchant's Favor") are said. Too long: cut at the end, hover has all.
- Hover lists all (at most 12, "and n more") with "seen n days ago", for a vendor the game's tooltip of the recipe
  item (reputation, level, specialisation it asks for), and what `~` means.
- The skill numbers move from the end of the value or profession line (the code that rewrites `d.sub` goes), where they would be cut, to the right of the
  button. Requests (no button) have them at the same place and have no NPC line.
- The window keeps its size: the crafter list shows 3 rows instead of 4 and scrolls as today; what is
  between the new line and it moves down one line. Same positions for requests.
- Skill: learn from own or guild trainer sheets (the later day, then greatest; not above grey), else `recipeInfo.m`, else
  Data.lua (> 0); grey from `recipeInfo.g`, else Data.lua; yellow from Data.lua, at most grey; green = floor((yellow
  + grey) / 2). Equal numbers are shown. Learn unknown: three numbers. Learn above yellow: learn and grey only;
  learn at or above grey: learn only.
- Leveling rows keep showing learn and grey, now with the same fallbacks, also for their order.
- en and sk texts. `/pg status` gets a line; `/pg npc` shows counts (NPCs, recipes, skipped names); `/pg npc clear`.

## Verification

Test first. Pure module with an adapter; a simulated guild with the real encoding, the server's throttle per prefix
(10, then 1 part per second; the mock is extended) and ChatThrottleLib's byte budget. Loss is per part, 2 %.
- Merge: random sheets in any order, with duplicates: equal tables. At the limits: equal after an exchange.
- Two clients cut off from each other read different recipes of one trainer, and a newcomer reads a trainer 5 s after
  login: nothing is lost anywhere.
- Full game (100 trainers with 20-70 recipes, 80 vendors, 10 sold each): at most 60 kB on the wire with 2 % loss; newcomer
  complete in 10 minutes.
- 20, 72, 200 clients log in within a minute, each missing another random visit; and: each holding one sheet nobody else
  has; and: two halves with 10 new sheets each. Bytes at most 3 times the encoded missing sheets plus 2 kB per
  client; all equal within 15 minutes; then 3 hours without NI, NR, NU with hellos running, and again
  after one new visit.
- One changing visit per minute, 2 % loss, 40 % of clients blocked now and then: at most 300 kB per hour guild-wide at
  72 clients, and equal within 30 minutes after the visits stop.
- Holder blocked mid-answer or before its first NU, logs out; newcomers one after another; other epoch, faction, protocol;
  a client refusing sheets (limits): at most 30 kB per 3 hours
  at 72 clients without visits.
- 0.6.0 files from the tag in the same guild: no error, no extra message.
- Hostile: wrong types, NaN, fractions, huge lists, names with escapes, floods, future days, forged NI and ND.
- Recipe traffic beside a full answer arrives at most 3 s later than without it, with no other addon sending.
- Crossing NIs while some registers are 119 days old, and one clock 6 hours off: the traffic stops or stays under 250 kB an hour.
- All clients blocked 30 % of the time, one holder of 30 sheets: equal within 15 minutes.
- Forged NI, NR, ND floods (honest clients' traffic): under 400 kB an hour; junk NU every 3 s, also with the guild's hash: a newcomer is
  complete within 30 minutes. A forger of empty tables' NIs may delay a newcomer by an hour *(call)*.
- One merchant with two costs of one item; costs that differ between visitors.
- Expiry at the edge with clients that do not log out; alternating visits with two reputations, languages, positions:
  no more than one write per register and 14 days each, except that
  a price may also rise to a higher reading; with a login after each visit; different Data.lua
  versions; unknown against known; a price too high with a visit at least every 30 days (corrected within 60).
- Reader with mocks made from the probe's log; UI texts and layout; mutation tests as for 0.6.0.
- Independent review, up to 4 rounds, then a test in the game by docs/TESTOVANIE.md. Push and tag only
  when the user says so.

## Left to the builder

File split, hash function, message field names, exact texts, where the probe's log is kept.

## History

- 1 to 2 (readers 1, 2): sheets with newest-wins instead of joined facts; inventory instead of hash buckets; retries;
  epoch; expiry; faction; matching order; no-NPC-ID fallback removed; skill ties; price per NPC; tooltip.
- 2 to 3 (readers 3, 4, with a simulation): merge per entry with the day read, so partial readings lose nothing and no list
  is deleted; finder and second-precision time dropped; npcOwn holds own readings only; own visits cannot flap;
  sharing rules changed as measured (useless inventories); hash covers content; targets for bursts and continuous use;
  layout with 3 crafter rows, numbers beside the button.
- 3 to 4 (readers 5, 6, both with models): registers with their own day (unknown never erases, wrong prices cannot
  be renewed unread); npcOwn enters by the own-visit rules; hashes cover sendable data only; inventory to everyone
  with postponed answers instead of pairwise exchange; per-sender entry limit dropped.
- 4 to 5 (readers 7, 8, both with models): npcOwn without realm; sendable defined for entries and head; skill waits for the
  renewal; deterministic order and size of limits; sharing: echo once per sheet and round, refused sheets
  remembered, ND after a block, caps by the game's sender name, bounded wait; targets made exact.
- 5 to 6 (readers 9, 10, both with models): price rule for other costs, no limit by size and no memory of evictions, names
  not loaded, postponement only by a useful NU, NR cap, echo only when it adds, hash widths, ND after a block dropped.
