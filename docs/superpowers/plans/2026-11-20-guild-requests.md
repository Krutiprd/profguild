# Guild Item Requests (0.4.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Guildmates post requests for crafted items; anybody else takes one (first wins), gives it back or marks it done; everybody, also offline players later, sees the same list.

**Architecture:** A pure module `Requests.lua` (records, allowed transitions, merge, limits, expiry, sync messages TD/TR/TU) with an adapter like `GuildPrices.lua`; glue in Core/Comm; a fourth window view "Požiadavky" whose rows reuse the recipe detail (reagents, cost, crafters) plus request buttons.

**Tech Stack:** Lua 5.1 (WoW Classic 1.15 client, interface 16001), LibSerialize/LibDeflate/AceComm via `Comm.lua`, tests with `luajit tests/run.lua` and `tests/wowmock.lua`.

**Spec:** `docs/superpowers/specs/2026-11-20-guild-requests-design.md`

## Global Constraints

- States: `open`, `taken`, `done`, `cancelled`. Only the requester creates/cancels; anybody but the requester takes an open one; the crafter gives back (→ open); requester or crafter marks done.
- Two takes of the same open request: the earlier take wins on every client (tie: lower guid).
- 20 open requests per requester, 200 records in the guild; open expire 7 days after creation, done/cancelled 2 days after their last change.
- Count 1–1000, note ≤ 80 characters (UTF-8 letters, cut with `ns.Bugs.Cut`), item/recipe IDs validated like Catalog (`1..2147483647` integers).
- Message types must not collide with existing ones (`H R D Q C KD KR KL PU PD PR`): use `TU` (update), `TD` (digest), `TR` (request).
- Every UI text in Locale.lua in both `en` and `sk` with the same format specifiers (tests/test_locale.lua).
- Version 0.4.0 (TOC, CHANGELOG, docs/TESTOVANIE.md, `dist/Profguild-0.4.0.zip` built with Python zipfile).

## Review Focus

- A take arriving after a newer give-back/done of the same request (stale take): must not reopen or steal it.
- A guildmate offline for days logs in: gets all live requests and sees expired ones gone, without a storm.
- The requester's own client gets an echo-less world: its creation must still reach others after a blocked send (combat) — via the next digest.
- A forged TU changing someone else's request (sender not requester/crafter): rejected.
- Window refresh while a request changes state under the selection: selection stays, buttons match the new state.

---

### Task 1: Requests module — records, transitions, merge, limits

**Files:**
- Create: `Profguild/Requests.lua` (TOC after `GuildPrices.lua`)
- Test: `tests/test_requests.lua` (add to `tests/run.lua` after `test_guild_prices.lua`)

**Interfaces:**
- Produces: `ns.Requests.New(adapter, saved) -> R` with saved = guild table (`saved.requests[id]`); adapter like GuildPrices (`send, canSend, now, clock, after, random, myGuid, onChanged(id, what)`, `knows(recipeID) -> bool` optional).
- Record: `{ id, by, r = recipeID, i = itemID, n = count, note, c = created time, st, cr = crafter guid or nil, tk = take time or nil, u = last change time, ub = guid of the last change }`.
- `R:Create(recipeID, itemID, count, note) -> record | nil, reason` (`"limit"`, `"invalid"`); id = `myGuid .. "-" .. created .. "-" .. seq`.
- `R:Take(id)`, `R:GiveBack(id)`, `R:Done(id)`, `R:Cancel(id)` → `true | false, reason`.
- `R:Get(id)`, `R:All() -> { record, ... }` sorted open first, newest first; `R:Prune()`; `R:Merge(record, sender) -> bool` (validation + transition check + conflict rule).

- [ ] **Step 1: Write failing tests** — `requests: create validates and limits` (count 0/1001 rejected, 21st open request → `"limit"`, note cut to 80 letters); `requests: transitions by the allowed player only` (requester cannot take own; other takes; third cannot give back; crafter gives back → open, cr nil; requester cancels; done by crafter); `requests: two takes — the earlier wins everywhere` (merge order both ways gives the same crafter); `requests: a stale take does not reopen a done request`; `requests: forged change by a stranger rejected`; `requests: prune after 7 / 2 days`.
- [ ] **Step 2: Run** `luajit tests/run.lua` → the new tests FAIL (module missing).
- [ ] **Step 3: Implement** `Requests.lua` records and rules. Merge rule: accept `incoming` when it is a valid transition from the held version (or unknown id with a valid creation by `by`), `u` newer; a take of an open request competing with a held take of the same open version keeps the smaller `(tk, cr)`.
- [ ] **Step 4: Run** → PASS (all, `N passed, 0 failed`).

### Task 2: Requests sync — TU / TD / TR

**Files:**
- Modify: `Profguild/Requests.lua`
- Test: `tests/test_requests.lua` (simulated guild like `tests/test_guild_prices.lua`'s `newGuild`)

**Interfaces:**
- `TU { t="TU", pv=1, s, q = { record, ... } }` (≤ 20 records per message); `TD { t="TD", pv=1, s, x = { id, u, id, u, ... } }`; `TR { t="TR", pv=1, s, to, ids = { ... } }` (≤ 50).
- `R:OnMessage(msg)`, `R:Announce()` (after hello), `R:OnSendFailed(msg)`, `R:Stop()`.
- Own changes are sent at once (TU, 0.5 s merge); digest receivers ask the sender for ids they lack or hold older; holders answer once per 30 s; answering digest when we hold newer/missing ones, at most every 60 s.

- [ ] **Step 1: Write failing tests** — `requests sync: a new request reaches everybody, also a player who logs in later`; `requests sync: a take raced by two crafters settles on the earlier one everywhere`; `requests sync: a blocked send arrives through the next digest`; `requests sync: bad messages ignored (bad ids, too many records, wrong pv, own echo)`; `requests sync: 15 clients settle, then only digests` (bytes bound).
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** the messages in `Requests.lua`.
- [ ] **Step 4: Run** → PASS.

### Task 3: Glue — Core, Comm, notices, status

**Files:**
- Modify: `Profguild/Core.lua` (adapter, `ns.requests` in `SetupGuild` with `Stop` on guild change, `Prune` at setup, `Announce` in `ns.Hello`, `/pg status` line), `Profguild/Comm.lua` (route and OnSendFailed for `TU TD TR`), `Profguild/Locale.lua`.
- Test: `tests/test_addon_requests.lua` (add to run.lua)

**Interfaces:**
- `ns.requests` (nil without a guild); adapter `knows(recipeID)` = any own profession recipe (`ns.OwnState().recipes`).
- Notices via `onChanged(id, what)`: `what = "taken"` for our request → `ns.Say("REQ_TAKEN_NOTICE", name, item)`; `what = "new"` for a recipe we know → `ns.Say("REQ_NEW_NOTICE", name, count, item)`; at most one notice per request and kind.

- [ ] **Step 1: Write failing tests** in the whole-addon mock: a TU from Ana with a new request for 3865 (which we know) prints the notice once; our request taken by Ana prints it; `/pg status` shows the count; a guild change stops the old object.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.

### Task 4: Window — view "Požiadavky", create box, buttons

**Files:**
- Modify: `Profguild/UI.lua`, `Profguild/Locale.lua`
- Test: `tests/test_addon_requests.lua`

**Interfaces:**
- Fourth tab `self.requestsTab` (view `"requests"`), `UI:BuildRequestRows(query, category)` returning rows `{ kind = "recipe", req = record, recipeID, itemID, crafters, ... }` so the recipe detail draws reagents, cost and crafters; the list row shows count × item, requester, state (and crafter).
- In the recipe detail: a button "Požiadať guildu" (`d.requestButton`) opens `UI:OpenRequestBox(recipeID, itemID)` (count EditBox numeric, note EditBox max 80, Save/Cancel; like the bug box).
- With `s.req`: the two action buttons become the request actions allowed for the viewer (`Vyrobím to` / `Vzdať sa` / `Hotovo` / `Zrušiť`), the recipe info line shows the state, requester, crafter and note.

- [ ] **Step 1: Write failing tests** — create from the recipe detail (count 3, note) appears in the view and goes out as TU; Ana's open request shows "Vyrobím to" and taking it sends TU; our taken request shows "Hotovo"/"Zrušiť"; the selection survives a state change; the list cache key includes `ns.requests.revision`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.

### Task 5: Release 0.4.0

- [ ] Version 0.4.0 in TOC, CHANGELOG entry, `docs/TESTOVANIE.md` section for requests; install into the game folder; review rounds by subagent (max 4) with fixes; commit + push on master; `dist/Profguild-0.4.0.zip`.
