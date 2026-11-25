# NPC Learning (0.7.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Whoever opens a profession trainer or a vendor of recipes teaches the whole guild where a recipe is learned or bought, from which skill and for how much.

**Architecture:** Four new files: `NpcData.lua` (pure: sheets, registers, merge, expiry, limits, own visits, packing), `NpcSync.lua` (pure, with an adapter: ND/NI/NR/NU and rules 1-10), `NpcReader.lua` (the two windows), `NpcView.lua` (pure: what the detail shows). Glue in Comm, Core and UI. A throwaway probe addon runs in the live client first and is a gate.

**Tech Stack:** Lua 5.1, interface 16001, LibSerialize/LibDeflate/AceComm through `Comm.lua`; tests `luajit tests/run.lua` (193 pass before this plan).

**Spec:** `docs/superpowers/specs/2026-11-25-npc-learning-design.md` (revision 10). Where this plan is silent the spec binds; read both.

## Global Constraints

- Nothing in the trainer or merchant window is changed (no filter, no selection). Not read in combat; nothing `issecretvalue` marks is read.
- No GPL data (Questie, OneForAll, AzerothCore).
- Prefix `ProfguildNPC`, GUILD only; 0.6.0 clients get no new message on `Profguild`.
- Every message carries `pv` (PROTOCOL = 1), `e` (EPOCH = 1), `f` (faction as `UnitFactionGroup` returns it), `s` (own GUID), `h` (table hash); another protocol, epoch or faction is ignored before anything else.
- Limits: name 1-60 bytes without `|` and control characters; map 0-100000; x, y 0-100; skill 1-1000; trained copper 1-9999990000, sold 0-9999990000; 3 other costs; 200 trained and 60 sold per sheet; 20000 entries; 600 sheets; IDs and cost counts 1-2147483647; ND sheets 0-600; message 6144 bytes encoded.
- Days: `floor(GetServerTime() / 86400)`. Expiry 120, sendable 118, own renewal 14, price falls 30, future refused beyond tomorrow.
- Receipt never depends on Data.lua or the catalog.
- Texts in `en` and `sk` with equal format specifiers.
- Any change of fields, order or limits raises EPOCH or PROTOCOL.
- Commits on master (user's choice). No push and no tag without the user's request: a tag publishes to CurseForge.
- Line endings and comment style of the neighbouring files. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

- A filtered trainer window (some services hidden) after a full one: nothing is lost. (Task 2)
- The player changes character to the other faction on one account: tables do not mix, npcOwn neither. (Tasks 3, 7)
- `/reload` in the middle of an answer or with a hand-edited, truncated SavedVariables: loads without an error, bad parts dropped. (Tasks 3, 5)
- The window is closed before the 0.5 s debounce, or another NPC opened at once: nothing is recorded under the wrong NPC. (Task 6)
- A vendor or trainer without position (instance, unknown map): sheet without place, row without zone and Map button. (Tasks 6, 8)

## File Structure

| File | Responsibility |
|---|---|
| `Documents/Projects/Profguiild/npcprobe/NpcProbe/` | throwaway probe, outside the repo |
| `Profguild/NpcData.lua` | `ns.NpcData`: sheets and the table, no WoW API |
| `Profguild/NpcSync.lua` | `ns.NpcSync`: sharing, adapter like GuildPrices |
| `Profguild/NpcReader.lua` | `ns.NpcReader`: windows to readings |
| `Profguild/NpcView.lua` | `ns.NpcView`: choice and text data for the detail |
| `Profguild/Comm.lua`, `Core.lua`, `UI.lua`, `Locale.lua`, `Profguild.toc` | glue |
| `tests/test_npc_data.lua`, `test_npc_sync.lua`, `test_npc_reader.lua`, `test_npc_view.lua`, `test_addon_npc.lua` | in `tests/run.lua` |
| `tests/npcsim.lua`, `tests/run_npc_sim.lua` | simulated guild; the full matrix, run separately |

TOC order: `NpcData.lua`, `NpcSync.lua`, `NpcReader.lua`, `NpcView.lua` directly after `Reports.lua`.

---

### Task 1: Probe addon (gate)

**Files:** Create `C:\Users\majfr\Documents\Projects\Profguiild\npcprobe\NpcProbe\NpcProbe.toc`, `NpcProbe.lua`; result notes `docs/superpowers/specs/2026-11-25-npc-probe-result.md`.

**Interfaces:** Produces: the result notes; Task 6 copies raw values from them into its mocks.

- [ ] **Step 1: Write the addon.** SavedVariables `NpcProbeDB`, Interface 16001. Every call through `pcall`; each value saved as type plus `tostring` (secret values as `"secret"`). Slash `/npcprobe note <text>` stores a note with the time. It records:
  - TRAINER_SHOW, TRAINER_UPDATE, MERCHANT_SHOW, MERCHANT_UPDATE (at the event and 0.5 s later): `UnitGUID("npc")`, `UnitName("npc")`, `C_Map.GetBestMapForUnit("player")`, `C_Map.GetPlayerMapPosition`, `GetServerTime()`, `UnitFactionGroup("player")`, `GetGuildInfo("player")`, `UnitReaction("npc","player")`.
  - Trainer: `IsTradeskillTrainer()`, `GetNumTrainerServices()`, for each service all returns of `GetTrainerServiceInfo`, `GetTrainerServiceSkillReq`, `GetTrainerServiceCost`, `GetTrainerServiceItemLink`, `GetTrainerServiceTypeFilter` for `available`/`unavailable`/`used`; existence of every global matching `Trainer` and `C_Trainer`.
  - Merchant: `GetMerchantNumItems()`, `GetMerchantFilter()`, for each index all returns of `GetMerchantItemInfo` and `C_MerchantFrame.GetItemInfo` (whichever exist), `GetMerchantItemID`, `GetMerchantItemLink`, `GetMerchantItemCostInfo`, `GetMerchantItemCostItem` 1-3, `GetItemInfoInstant`.
  - `/npcprobe pin`: which of `C_Map.SetUserWaypoint`, `C_Map.CanSetUserWaypointOnMap`, `C_Map.ClearUserWaypoint`, `UiMapPoint.CreateFromCoordinates`, `C_SuperTrack`, `TomTom` exist; sets a pin at the player's position and logs the result (the user looks whether it shows on the map and notes it).
  - At login and 60 s later: for all spell IDs of a copied ID list (generated from `Data.lua`) how many lack a name, and the first 50 of them.
- [ ] **Step 2: Check it loads.** Run `luajit -bl NpcProbe.lua > /dev/null` (syntax). Expected: no output on stderr.
- [ ] **Step 3: Hand over to the user.** Copy to `_forever_/Interface/AddOns/NpcProbe`. The user visits: a profession trainer with all filters on and with one off, a trainer of a known profession, a recipe vendor, `/npcprobe pin` in the open world, a vendor with another currency, a limited-stock recipe; if possible one vendor at two reputations. Then `/reload` and says so.
- [ ] **Step 4: Write the result notes** from `WTF/Account/*/SavedVariables/NpcProbe.lua`: one raw example per case, and answers to every item of the spec's "Probe first".
- [ ] **Step 5: GATE.** If `UnitGUID("npc")` gives no creature ID that is equal after a relog: stop, discuss with the user. Tasks 2-5 do not depend on other answers; they may be built while waiting, at the user's risk of the gate.
- [ ] **Step 6: Commit the notes** (`docs: probe result`).

### Task 2: Sheets: validation, merge, own visit

**Files:** Create `Profguild/NpcData.lua`, `tests/test_npc_data.lua`; modify `tests/run.lua`, `Profguild.toc`.

**Interfaces:** Produces:
- Sheet: `{ name=, nd=, map=, x=, y=, pd=, t={ [recipeID]={ seen, skill, skillDay, copper, copperDay } }, v={ [itemID]={ seen, price, priceDay } } }`; unknown is `nil` in fields with names and `0` (value and day) in the arrays, `price` unknown is `false` with day 0. `price = { c=copper, o={ {kind,id,count}, ... } sorted, l=0|1 }`, kind 1 currency, 2 item.
- `NpcData.ComparePrice(a, b) -> -1|0|1`: copper, number of other costs, then kind, id, count of each in order, then l.
- `NpcData.Merge(a, b) -> sheet` (new table, a and b untouched); `NpcData.Valid(sheet, today) -> sheet|nil` (a cleaned copy).
- `NpcData.Visit(held|nil, reading, today, limit) -> sheet, changed`; `reading = { name=, map=, x=, y=, t={ [id]={ skill=, copper= } }, v={ [id]={ price=|nil } } }`.

- [ ] **Step 1: Write failing tests**, names and assertions:
  - "merge is a join": 2000 random triples: `Merge(a,b)==Merge(b,a)`, associative, idempotent (deep compare).
  - "later day wins, equal day greater value, unknown never erases": skill 50@10 with 40@11 gives 40@11; 50@10 with 40@10 gives 50@10; 50@10 with unknown gives 50@10; place compares map, x, y as numbers; name as bytes.
  - "own visit": `seen` absent or 15 days old is written, 14 days old is not; skill, place, name likewise.
  - "price": held 100@10: reading 120 at day 11 writes; 90 at day 40 does not, at day 41 does; equal at day 24 does not, at 25 does; other costs or limited stock differ at day 24 does not, at 25 does.
  - "two reputations": 100/90 alternating daily for 120 days: at most one write per 14 days. "100c / 5 tokens alternating for 60 days": at most 5 writes.
  - "wrong price": 500@0, 90 read on days 30 and 60: 90 by day 60.
  - "filtered window": full reading, next day a reading with 3 of 20 recipes: 20 remain; a second identical reading the same day: `changed == false`.
  - "entry limit": sheet with 200 trained, reading with 10 others the same day: unchanged; with 10 held entries 15 days old: the new ones enter.
  - "Valid": each limit of Global Constraints at its bound and one beyond (entry or register dropped, not the sheet); NaN, fraction, string, boolean, huge list; entry without `seen` dropped; entry register 121 days old dropped, 120 kept; head register 500 days old kept; day today+1 kept, today+2 dropped; name with `|`, `\n`, 61 bytes dropped; sheet without entries gives nil.
- [ ] **Step 2: Run** `luajit tests/run.lua` - Expected: load failure of the missing module.
- [ ] **Step 3: Implement.** An own visit first builds registers of `today` by the rules, then calls `Merge`.
- [ ] **Step 4: Run** - Expected: all pass.
- [ ] **Step 5: Commit** `NpcData: sheets, merge, own visits`.

### Task 3: Table: expiry, limits, hashes, packing, saving

**Files:** Modify `Profguild/NpcData.lua`, `tests/test_npc_data.lua`.

**Interfaces:** Consumes Task 2. Produces:
- `NpcData.New(saved, now) -> tab`; `saved` is `{ e=, s={ [npcID]=packed } }` (kept current at every change); `now()` gives server seconds.
- `tab:Get(id)`, `tab:Count() -> sheets, entries`, `tab:Today()`, `tab:Sendable(id) -> sheet|nil`, `tab:SendableIDs() -> sorted list`, `tab:Hash()`, `tab:SheetHash(id)`, `tab:SaltedHash(hash, salt) -> 0..65535`.
- `tab:MergeIn(id, sheet) -> changed, taken` (`changed`: the sendable content changed; `taken`: something of it is held), `tab:OwnVisit(id, reading) -> changed`, `tab:Import(own)` (npcOwn tab into this one), `tab:Clear()`, `tab:Expire()`.
- `NpcData.Pack(id, sheet) -> list`, `NpcData.Unpack(list, today) -> id, sheet|nil`.

- [ ] **Step 1: Write failing tests:**
  - "expiry": register 120 days old stays, 121 goes; entry with its `seen`; head with the last entry; `Expire` runs before Hash/SendableIDs/Sendable (day advanced without a call).
  - "sendable": entry 118 days old in, 119 out; its older registers out; `Hash` equal for a table with and without the 119-day entry.
  - "hash": independent of insertion order; equal content equal hash, any one register or day changed: different; `0 <= Hash < 2147483647`; empty is 0; two 31-bit hashes with equal low 16 bits differ under at least 60 of 64 salts.
  - "limits": 201 trained keeps the newer `seen`, ties by hash not by ID; 601 sheets; 20000 entries; order entries per sheet, entries, sheets; three tables over every limit exchanging repeatedly become equal.
  - "pack": round trip of 1000 random valid sheets; all days equal is shorter than mixed; `Unpack` of wrong types, shortened columns, NaN, strings: nil, no error.
  - "maximum sheet": 200 trained, 60 sold with 3 costs, every value at its bound, random days, 60-byte name, in a full NU envelope, encoded by `Comm.Encode`'s steps (H.loadLibs): `<= 6144`, worst of 20 seeds.
  - "full game": 100 trainers with 20-70 recipes and 80 vendors with 10 sold, as NU messages of about 1 kB: `<= 60000` bytes.
  - "load": other epoch dropped; garbage saved (`s` a string, a sheet cut in half) loads the rest.
  - "import": a 20-day-old own register enters as of its own day, newer guild data stays; twice changes nothing.
- [ ] **Step 2: Run** - Expected: the new tests fail.
- [ ] **Step 3: Implement.** Pack in columns: delta-coded sorted IDs, one column per register value, day columns relative to the sheet's newest day, replaced by `0` when all equal the base (as `ser` in `npcsim/r15/reg.lua`); other costs in one flat list. Sheet hash: over the canonical numbers of the sendable sheet with the mixing of `GuildPrices.Hash` (stay below 2^53); table hash: sum modulo 2147483647. Cache sheet hashes, recompute on change and on a new day.
- [ ] **Step 4: Run** - Expected: all pass.
- [ ] **Step 5: Commit** `NpcData: table, limits, hashes, packing`.

### Task 4: Comm: a second prefix

**Files:** Modify `Profguild/Comm.lua`, `tests/wowmock.lua`; create `tests/test_addon_npc.lua`; modify `tests/run.lua`.

**Interfaces:** Produces: `Comm.NPC_PREFIX = "ProfguildNPC"`, `Comm.NPC_MAX_TEXT = 6144`, `Comm.SendNpc(msg, done)`; `done(ok)` is called once, when the last part has left (`true`) or a part failed (`false`). Received NPC messages: `ns.npcSync:OnMessage(msg, sender, #text)`. `M.throttle = true` in wowmock: per prefix 10 parts, then 1 per second, else result 3; `M.loss` (0-1).

- [ ] **Step 1: Write failing tests:** "NPC message goes out on ProfguildNPC only"; "received on ProfguildNPC reaches npcSync, with the game's sender name, and never sync"; "text of 6145 bytes is ignored, 6144 is decoded"; "a sender blocked on one prefix is blocked on both"; "done(true) once after a 3-part message, done(false) once when a part fails"; "a message of type ND on the old prefix does not reach npcSync". Also: an NPC message does not write `ns.guildDB.names`.
- [ ] **Step 2: Run** - Expected: fail (`SendNpc` nil).
- [ ] **Step 3: Implement**, sharing encode, decode and the sender block (decode gains a `max` parameter); no copy. Done is called on `sent >= total` in the AceComm callback.
- [ ] **Step 4: Run** - Expected: all pass, the existing 193 included.
- [ ] **Step 5: Commit** `Comm: prefix of NPC data`.

### Task 5: Sharing

**Files:** Create `Profguild/NpcSync.lua`, `tests/test_npc_sync.lua`, `tests/npcsim.lua`, `tests/run_npc_sim.lua`; modify `tests/run.lua`, `Profguild.toc`.

**Interfaces:** Consumes Tasks 2-4. Produces: `NpcSync.New(adapter, tab) -> sync`; adapter `{ now(), after(s, fn), random(), canSend(), send(msg, done), selfGuid(), faction(), changed() }`. Methods `Announce()`, `OnMessage(msg, sender, size)`, `OwnVisit(id, reading)`, `Stop()`, `stats`.

Messages besides the common fields: `ND { n=sheets }`; `NI { r=salt 0-65535, i={ ID deltas }, c={ 16-bit hashes } }`; `NR { to=sender name, i={ ID deltas } }`; `NU { x={ packed, ... } }`. `NR.to` is the sender name the game gave for the NI; the receiver compares it with its own name as the game gives it (`Ambiguate`-free, via `ns.NormalizeName`), so the adapter also has `isMe(name)`.

The reference implementation is `C:\Users\majfr\Documents\Projects\Profguiild\npcsim\r15\p5.lua` with `OPT=dty,rwin=60,lit,wait=30,fix6`; the spec's rules 1-10 bind where they differ. One difference known: rule 8's own-visit NU waits like any NU (rule 7), p5 drops it.

- [ ] **Step 1: Port the simulator** to `tests/npcsim.lua`: virtual time, per-prefix throttle, 2 % and 5 % part loss, ChatThrottleLib byte budget (`npcsim/gsim/ctl.lua`), blocks, login/logout, day and clock offset per client; clients are the real `NpcSync` + `NpcData` with real encoded sizes. API `sim = npcsim.new{ seed=, loss= }`, `sim:client{ name=, sheets=, block=fn }`, `sim:run(seconds)`, `sim:equal()`, `sim:bytes(type|nil)`.
- [ ] **Step 2: Write failing unit tests** (`test_npc_sync.lua`), one per rule, with the exact numbers:
  1. ND 10 s after Announce, none when an equal ND was heard 599 s ago, one at 601 s; unconfirmed ND repeated at most 3 times.
  2. Differing ND: NI within 2-20 s; any NI heard cancels; second own NI not before 65 s; NI sent at the latest 120 s after planning plus one poll under constant NU; dropped when hashes are equal by then.
  3. NU for lacked or differing sheets; identical sheet heard is left out; useful NU postpones 40-60 s, NU without a planned sheet does not; sender's hash becoming ours drops all.
  4. One NR after 1-8 s without IDs heard; none after 10 NRs to that sender within an hour; echo once per sheet and round, only when ours adds; sheet of which nothing is held is listed in own NI with the received content, at most 100 remembered; partly taken is not.
  5. ND 12-24 s after the last message of a round when the hash changed, at most one per 30 s.
  6. Muted after 2 fruitless rounds or 3 own NIs, lifted by a change of either hash; a round silenced by the NR cap does not count.
  7. Blocked: planned NU sent when the block ends at 29 s, dropped at 31 s; NR, NI, ND dropped; ND 10-20 s after the block only if something was dropped or due.
  8. Own visit: NU of the whole sheet after 3 s; changed nothing: no message.
  9. Second NI within 60 s and third ND within a minute of one sender ignored, also with a forged `s`; content sent at most 6 times an hour per sender name and per NI hash; a counter rises at most once per 60 s; an NR raises the name counter only.
  10. `send` failing undoes the marks; after `Stop()` no timer sends.
  Plus: other protocol, epoch, faction ignored without changing state; hostile fields (NaN, huge lists, negative deltas, fractions, wrong types, NR for unknown IDs) no error.
- [ ] **Step 3: Run** - Expected: fail (module missing).
- [ ] **Step 4: Implement** `NpcSync.lua`. An NU is filled to about 1000 bytes; a sheet that would exceed it starts a new message. The next message goes when `done` came, plus 1 s per part (254 bytes).
- [ ] **Step 5: Run** - Expected: unit tests pass.
- [ ] **Step 6: Scenario tests.** `run_npc_sim.lua` runs every sharing scenario of the spec's Verification with its target (3 seeds each, `--seeds N`), one line `ok|FAIL name value target` each and exit code 1 on a failure. A short set goes in `run.lua`: 20-client burst of unique sheets, newcomer (complete <= 600 s, <= 60 kB), sole holder with 12 s block period (<= 900 s), quiet 3 h, junk NU with the guild's hash, newcomer reading a trainer 5 s after login. It must add under 30 s.
- [ ] **Step 7: Run** `luajit tests/run_npc_sim.lua --seeds 3`. Expected: every line `ok`. A failing target is debugged against `r15`, not relaxed. Then measure which rules could go without failing the non-hostile targets and bring the list to the user; cut nothing before that.
- [ ] **Step 8: Commit** `NpcSync: sharing of NPC sheets`.

### Task 6: Reading the windows

**Files:** Create `Profguild/NpcReader.lua`, `tests/test_npc_reader.lua`; modify `Profguild/Core.lua` (trainer and merchant events, beside `readTrainer`), `tests/run.lua`, `Profguild.toc`.

**Interfaces:** Consumes Task 1's notes. Produces: `NpcReader.New(api, onReading) -> reader`, `onReading(npcID, reading)`; `api` holds the WoW calls, so tests inject mocks. `reader:TrainerShow()`, `TrainerUpdate()`, `TrainerClosed()`, `MerchantShow()`, `MerchantUpdate()`, `MerchantClosed()`, `reader.skipped` (count). `NpcReader.Match(services, recipes) -> { [recipeID]={skill,copper} }, skipped`; `recipes = { { id=, name=|nil, line=, item=id|false|nil, grey=|nil }, ... }`.

- [ ] **Step 1: Write failing tests** with mocks made from the notes:
  - matching steps 1-4 of the spec, one test each; equal names with one no-item recipe; grey below the skill excluded; two services to one recipe with different values: both out; skill above grey: skill unknown, copper kept; a service without requirement takes the only profession, with two professions left out; recipes without Data.lua only in 1 and 2.
  - a missing name in the profession: nothing by 2-4; again after 60 s from memory with the window closed; then left out until logout.
  - closed before 0.5 s, or another NPC opened: nothing under the wrong ID; class trainer, combat, secret value, no creature GUID: nothing.
  - no map or position: reading without place.
  - merchant: class 9 or Data.lua item; missing ID retried after 1 s at most 5 times, such an entry never in part; unknown cost ID likewise; two different entries of one item: seen only; no recipe: no reading; limited stock; three other costs.
  - `recipeInfo.m` written as today.
- [ ] **Step 2: Run** - Expected: fail.
- [ ] **Step 3: Implement.** Position whole percent, rounded down. Event handlers go through `ns.Bugs.Call` like `scheduleTrainer`.
- [ ] **Step 4: Run** - Expected: pass.
- [ ] **Step 5: Commit** `NpcReader: trainers and vendors`.

### Task 7: Wiring into the addon

**Files:** Modify `Profguild/Core.lua` (npcOwn created at PLAYER_LOGIN + 5 s before the early return of `SetupGuild`, skipped while the faction is nil and tried again on the next reading or guild event; not in `initDB`, where the faction is not known yet, `ns.Hello` at 617, `ns.SetupGuild` at 623, status at 902, slash), `Locale.lua`, `tests/test_addon_npc.lua`.

**Interfaces:** Consumes Tasks 2-6. Produces: `ns.npc` (the tab shown: guild's, else own), `ns.npcOwn`, `ns.npcSync|nil`, `ns.db.guilds[key].npc[faction]`, `ns.db.npcOwn[faction]`.

- [ ] **Step 1: Write failing tests** on the loaded addon: reading goes into npcOwn and the guild's tab and sends one NU on `ProfguildNPC`; same reading again: none; without a guild only npcOwn; guild change: sync stopped, npcOwn imported into the new guild, nothing received in guild A appears in B; other faction: separate tables; a faction that is nil at login, and a character without a guild: no error, npcOwn made later; Hello calls `Announce` also when blocked (an ND due while blocked); saved tables survive a reload; `/pg npc` prints counts, `/pg npc clear` empties both tables of the faction; 0.6.0 files from the tag (`git show 0.6.0:Profguild/...` into a temporary directory) in the same mocked channel: no error, nothing received.
  npcOwn is last known reading: a same-day lower price read replaces npcOwn's price (no own-visit rules there) while the guild's keeps the higher.
- [ ] **Step 2: Run** - Expected: fail.
- [ ] **Step 3: Implement.** `npcOwn` is written with today's registers directly (merge is not used, the new reading wins); unread registers stay.
- [ ] **Step 4: Run** - Expected: all pass.
- [ ] **Step 5: Commit** `Core: NPC data wired in`.

### Task 8: What the window says

**Files:** Create `Profguild/NpcView.lua`, `tests/test_npc_view.lua`; modify `Locale.lua`, `tests/run.lua`, `Profguild.toc`.

**Interfaces:** Produces:
- `NpcView.Skill(recipeID, src) -> { learn=|nil, yellow=, green=, grey=, show={...}|nil }`, `src = { own=tab, guild=tab, info=recipeInfo, data=RecipeData }`; `show` is the list of `{ number, "learn"|"yellow"|"green"|"grey" }` to print.
- `NpcView.Sources(recipeID, src, where) -> rows`, each `{ kind="ah"|"trainer"|"vendor"|"drop"|"quest"|"crafted"|"missing"|"unknown", id=, name=, map=, x=, y=, copper=, other=, limited=, age=days, approx=bool, best=bool, of="vendor"|"trainer" (missing only) }` in display order; `where = { map=, items={ [itemID]=true }, recipeItem=id|false|nil, letters="vd", ah={ copper=, text= }|nil }` (only a price of kind "ah" of `Prices.Get`).

- [ ] **Step 1: Write failing tests:** order ah, trainers, vendors, then drop/quest/crafted; within a kind player's map, lowest price, name; recipe item without AH price gives an `ah` row without copper (kind "vendor" of `Prices.Get` is not one), no recipe item none; own reading of 30 days shown without `approx`, of 31 days not; equal own and guild: no `approx`; vendors of Data.lua's item and of `recipeItems`; letters "v" without a vendor sheet give `missing` of vendor, recipe item `false` without a trainer sheet `missing` of trainer; nothing at all: one `unknown`; a row without copper price last, by name; `best` only with two copper prices, never on a row with other costs, ties: the first; learn from the later day, then the greatest; one above grey is ignored and the next source taken: `info.m`, then Data.lua; yellow, green, grey from `Prices.RecipeSkill` (grey from `info.g` first); equal numbers shown; learn unknown: three numbers; learn above yellow: learn and grey; learn at or above grey: learn only; the 19 + 1 odd Data.lua entries give no error and no falling numbers.
- [ ] **Step 2: Run** - Expected: fail. **Step 3: Implement. Step 4: Run** - Expected: pass.
- [ ] **Step 5: Commit** `NpcView: choice of trainer and vendor`.

### Task 9: FIND RECIPE in the detail pane

**Files:** Modify `Profguild/UI.lua` (`recipeItemText` 376-394, `recipeSkillText` 450, the list key 2341, `BuildLevelingRows` 705, detail 1205-1277, price refresh 2147-2163, `DrawDetail` 2220-2260, `ScrollDetail`), `Locale.lua`, `tests/test_addon_npc.lua`.

**Interfaces:** Consumes Task 8. Produces: `UI:ToggleFind()`, `UI.findOpen`, `UI.findOffset`, `UI.SetMapPin(map, x, y, title) -> bool`, `UI.CanMapPin(map) -> bool`; `ns.npcSkillRevision` (raised when a learn skill shown changed, in the list key).

- [ ] **Step 1: Write failing tests** (frames of the mock); texts `BTN_FIND` "FIND RECIPE" / "NÁJSŤ RECEPT", `BTN_BACK_REAGENTS` "BACK TO REAGENTS" / "SPÄŤ K SUROVINÁM", `BTN_MAP` "Map" / "Mapa", `FIND_NO_VENDOR` "no vendor seen by the guild yet" / "guilda zatiaľ nevidela vendora", `FIND_NO_TRAINER` "probably a trainer, none seen by the guild yet" / "pravdepodobne tréner, guilda zatiaľ žiadneho nevidela", `REQ_LEVEL_SHORT` "lvl %d" / "lvl %d":
  - "opens and closes": ToggleFind hides reagents and cost, shows the rows and the back button, crafters keep 4 rows; again, back, another recipe, another view: closed, reagents back.
  - "rows": every kind's text; `~`, limited stock, "5 Merchant's Favor"; zone only with a place; green frame on the best; 5 sources: 3 visible, wheel reaches the last, wheel over the crafters scrolls them.
  - "live": a guild sheet arriving while open adds its row and keeps the offset; a shrinking list clamps it.
  - "pin": allowed by the client: waypoint with map, x/100, y/100; refused or missing with TomTom: `TomTom:AddWaypoint(map, x/100, y/100, { title = name })`; neither, or no place: button hidden; an error in the API does not escape.
  - "requests and members": no FIND RECIPE; numbers on requests at the same place.
  - "numbers": `d.sub` never rewritten by a price refresh; its width is 250 minus the numbers' `GetStringWidth()` minus 8, 250 for members; numbers hidden for members; Leveling order uses the fallbacks.
  - "list order": a sheet that changes a learn skill rebuilds the list, 20 sheets that change none do not.
  - "row fits": name with "~12g 34s 56c" and the Map button do not overlap (by the mock's widths); another cost whose name is not loaded shows `#id`, then its name after `WantItem`.
  - Change in `test_addon_load.lua` 541-547: 275 and 320 are read from `UI.detail.skillNumbers`, no longer from `detail.value`.
- [ ] **Step 2: Run** - Expected: fail.
- [ ] **Step 3: Implement.** Buttons 146 x 22 at TOPLEFT 14,-104 and 168,-104. `d.reagentBody` (new frame with today's reagent and cost regions) and `d.findBody` are shown in turn. Title at -130 as the reagent title, rows with step 36 from -154, back button TOPLEFT 14,-268, 300 x 20. `d.skillNumbers` TOPRIGHT -14,-64, right-aligned, child of `recipeBody`; `d.sub` as tested. A FIND row: name and detail line left from 8, Map button 44 x 18 at right -6, price right-aligned ending 6 left of it (at -6 without it), the name's `fitSpec` ends 8 before the price. One function builds the AH text for `recipeItemText` and the AH row. The Slovak request button uses the small font if it does not fit 136 px in the game. Nothing else moves.
- [ ] **Step 4: Run** - Expected: all pass, the existing layout tests unchanged except for the request button's width and the test named above.
- [ ] **Step 5: Commit** `Window: FIND RECIPE`.

### Task 10: Finish

**Files:** Modify `Profguild.toc` (0.7.0), `CHANGELOG.md`, `docs/TESTOVANIE.md`, README if it lists features; build `dist/Profguild-0.7.0.zip`.

- [ ] **Step 1: Mutation check** as for 0.6.0: in NpcData, NpcSync, NpcView change each limit, comparison and day constant by one in a scratch copy; every mutant fails a test or stands in a list of survivors with the reason (equivalent, random delay). Add the missing tests.
- [ ] **Step 2: Run** `luajit tests/run.lua` and `luajit tests/run_npc_sim.lua --seeds 6`. Expected: 0 failed, every line `ok`.
- [ ] **Step 3: Independent review** of the branch, at most 4 rounds (user's rule); fix what is found.
- [ ] **Step 4: Version, changelog, test guide** (section for two players: trainer, vendor, newcomer, combat, FIND RECIPE and the map pin), zip with Python `zipfile`, copy to `_forever_/Interface/AddOns/Profguild`.
- [ ] **Step 5: Commit** `Version 0.7.0`. No push, no tag. Hand over for the in-game test.
