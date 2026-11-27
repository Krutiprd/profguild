# Leveling guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The LEVELING tab shows the cheapest plan (smallest AH loss, or profit) from a start skill to 300, with 3 alternatives per segment, an "All (n)" list, a "Gives skill now" view, an editable start skill and a "For: <guild member>" pick.

**Architecture:** A pure module `Profguild/Leveling.lua` (no WoW calls) computes chances, per-level costs, the path, segments, alternatives and the "gives skill now" list from a plain input table. `UI.lua` builds that input from what the addon already knows (Prices, reagents, catalog/store, NpcView) and draws it on the existing LEVELING tab.

**Tech Stack:** Lua 5.1 (WoW Forever; PUC Lua 5.1 in game, LuaJIT for fast tests), existing test harness `tests/harness.lua` + `tests/wowmock.lua`.

**Spec:** `docs/superpowers/specs/2026-11-27-leveling-guide-design.md`

## Global Constraints

- Prices: Auction House for everything (reagents, products, reagents in bags); vendor price only when the AH knows nothing of the item. Reagent cost = `Prices.Cost(reagents)`; product value = `Prices.SaleValue(itemID)` then `Prices.AfterCut(price, source)` (5 % AH cut).
- Thin market: a product's AH value counts only for as many units as `Prices.Available(itemID)`; beyond that the vendor sell price.
- Chance of a point: orange 100 %; yellow..grey `(grey - skill) / (grey - yellow)` clamped to [0,1]; grey 0; below the learn skill the recipe cannot be crafted (chance 0).
- Path: approach A (cheapest whole path), not greedy.
- Max skill 300.
- Counts shown with `~`; recipes with no price are left out and the tab says "missing prices: scan the Auction House".
- No frame over 8 ms in PUC Lua 5.1 for a full profession (every recipe known); if one call cannot meet it, run it as an NpcWork job (`ns.npcWork:Run(fn)`, `Pace(units, kind)`).
- Texts in English and Slovak in `Profguild/Locale.lua`, existing WoW-native style; no GPL data.
- Commits on master, message trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; no push, no tag.

## Review Focus

- A player with no AH scan at all: the plan is empty with the "missing prices" line, no Lua error (test in Task 3).
- Start skill at or above 300, or above every recipe's grey: "nothing gives skill" message, no infinite loop (test in Task 1).
- A gap: no recipe gives points at some level (e.g. waiting for a recipe from a source nobody saw): the plan stops there and says from which skill nothing is known (test in Task 1).
- A recipe with yellow == grey or yellow > grey in Data.lua (the client has one): no division by zero (test in Task 1).
- "For: <member>" whose data is stale or who lacks the profession: falls back to "nobody's recipes" rule, no error (test in Task 3).

---

### Task 1: `Leveling.lua` — the model

**Files:**
- Create: `Profguild/Leveling.lua` (add to `Profguild/Profguild.toc` after `Prices.lua`)
- Test: `tests/test_leveling.lua` (add to the file list in `tests/run.lua`)

**Interfaces:**
- Produces:
  - Input recipe record `r = { id=number, name=string, learn=number|nil, yellow=number, grey=number, cost=copper per craft, ah=copper per unit after cut|nil, avail=number|nil, vendor=copper per unit|nil, known=boolean, learnPrice=copper|nil, learnWhere=any|nil }` (`learnPrice` nil and `known` false = no known source: never in the plan, still in `GivesNow`).
  - `Leveling.Chance(r, skill) -> number` in [0,1].
  - `Leveling.UnitValue(r, n) -> copper` — average value per unit when `n` units are sold (thin market rule).
  - `Leveling.GivesNow(recipes, skill) -> rows` sorted by `loss` ascending; row `{ r=, colour="orange"|"yellow"|"green", chance=, cost=, loss= (copper per point, negative = profit) }`.
  - `Leveling.Plan(recipes, from, to) -> plan`, `plan = { segments = { { from=, to=, r=, count= (expected crafts, number), loss= (copper, incl. learn price), learn=boolean, alts = { {r=, count=, loss=}, ... up to 3 }, all=number } }, total=copper, stopAt=number|nil (first skill nothing can give a point) }`.

- [ ] **Step 1: Write failing tests** in `tests/test_leveling.lua`:
  - `Chance`: r{learn=1,yellow=50,grey=100}: skill 10 -> 1; 50 -> 1; 75 -> 0.5; 100 -> 0; r{learn=60,...} at skill 55 -> 0; r{yellow=100,grey=100} at 100 -> 0 and at 99 -> 1 (no division by zero); yellow > grey treated as yellow = grey.
  - `UnitValue`: r{ah=100, vendor=10, avail=5}: n=5 -> 100; n=10 -> 55; avail nil -> 100; ah nil -> 10.
  - `GivesNow`: three recipes at skill 75 sorted by loss; a grey recipe absent; `loss = (cost - UnitValue(r, 1)) / chance` rounded down.
  - `Plan` approach A beats greedy: recipe CHEAP (known, cost 10, value 0, orange 1..3 then grey at 5) and recipe WIDE (unknown, learnPrice 200, cost 12, value 0, orange 1..299, grey 400): from 1 to 300 the plan uses WIDE for the whole range (one segment, learn=true), total = 200 + 299*12.
  - `Plan` segments: consecutive levels with the same recipe form one segment; `count` = sum of 1/chance over its levels.
  - `Plan` gap: no recipe gives points at 150 -> `stopAt == 150`, segments end at 150.
  - `Plan` from >= to -> no segments, `stopAt` nil, no error; from 400 -> same.
  - `Plan` alternatives: per segment up to 3, cheapest first, never the chosen recipe; each alt covers the whole segment (chance > 0 at every level), `alt.loss` includes its learn price if unknown; `all` = `#GivesNow(recipes, seg.from)`.
  - A recipe with `known=false` and `learnPrice=nil` never appears in `segments` or `alts`, but appears in `GivesNow`.

- [ ] **Step 2: Run, verify FAIL**: `luajit tests/run.lua 2>&1 | grep -i leveling` -> failures ("Leveling" nil).

- [ ] **Step 3: Implement** `Profguild/Leveling.lua`.
  - Per-level cost of recipe r at skill s: `(r.cost - UnitValue(r, N_r)) / Chance(r, s)`, where `N_r` = expected crafts of r over its useful range from `from` (all levels where Chance > 0, capped at `to`) — a fixed per-recipe value so the path search stays linear.
  - Path search (DP over states (skill, current recipe)), O(levels × recipes):

```
best[s][r] = cheapest cost to reach skill s with r the recipe used for the last level
best[s+1][r] = levelCost(r, s) + min( best[s][r], minOther[s] + (r.known and 0 or r.learnPrice) )
minOther[s] = min over q of best[s][q]   (keep the argmin for backtracking)
start: best[from][none] = 0; a recipe entered pays its learn price (re-entering pays again: rare, accepted)
levels where no recipe has Chance > 0: stop, stopAt = s
```
  - Backtrack to segments; for each segment compute alts (cost of covering [from,to) with that recipe alone, + learn price if unknown), keep 3 cheapest, and `all`.

- [ ] **Step 4: Run, verify PASS**: `luajit tests/run.lua` -> all pass.

- [ ] **Step 5: Commit** `Leveling: the cheapest path to 300, alternatives and what gives skill now`.

### Task 2: Input from the addon's data

**Files:**
- Modify: `Profguild/UI.lua` (near `UI:BuildLevelingRows`, line ~751)
- Test: `tests/test_addon_leveling.lua` (new, add to `tests/run.lua`; addon loaded through `wowmock` like `tests/test_addon_npc.lua`)

**Interfaces:**
- Consumes: Task 1 record and functions.
- Produces: `UI:LevelingInput(skillLine, who) -> recipes, startSkill, missingPrices` where `who` = nil (the player), a guild member GUID, or `{ skill = number }` (edited skill, nobody's recipes).

- [ ] **Step 1: Failing tests** (`tests/test_addon_leveling.lua`):
  - the player's profession: `known` true exactly for recipes the player knows; `startSkill` = player's skill.
  - `who = guid` of a member in the store: their skill and recipes; member without the profession or stale (`store:IsStale`) -> rule of `{skill=…}` with their skill if known else 1.
  - `who = { skill = 120 }`: nobody's recipes; trainer recipes (`Prices.RecipeItem(id) == false`) with learn skill < 120 are `known`; others unknown with `learnPrice` from NpcView sources (cheapest of trainer/vendor/AH recipe item) or nil.
  - `cost` = `Prices.Cost(reagents)`; recipe with any reagent unpriced or no reagents known -> left out, counted in `missingPrices`.
  - `ah`/`vendor`/`avail` from `Prices.SaleValue` + `Prices.AfterCut`, `Prices.Available`.
  - `learn/yellow/grey` from `recipeSkillNumbers(id)` (NpcView.Skill); recipe without yellow or grey left out.
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** `UI:LevelingInput` using the existing sources the detail view uses (reagents of a recipe, catalog of the profession's recipes, store for members, `NpcView.Sources` for learn price/place). Recipe product item: same lookup the Recipes detail uses for profit.
- [ ] **Step 4: Run, verify PASS** (`luajit tests/run.lua`).
- [ ] **Step 5: Commit** `Leveling: the guide's input from prices, recipes and NPC sources`.

### Task 3: The LEVELING tab

**Files:**
- Modify: `Profguild/UI.lua` (leveling view), `Profguild/Locale.lua` (EN + SK)
- Test: `tests/test_addon_leveling.lua`

**Interfaces:**
- Consumes: Task 1 `Leveling.Plan`, `Leveling.GivesNow`; Task 2 `UI:LevelingInput`.

- [ ] **Step 1: Failing tests:**
  - plan header "<Profession> <from> -> 300", total, one row per segment with `~count`, loss or profit, `[known]` / `[learn: <price>, <npc>]`.
  - expanding a segment shows ≤ 3 alt rows and the row "All (n) ->"; clicking it opens the GIVES SKILL NOW list at `seg.from`.
  - toggle "Gives skill now" opens the list at the start skill; the list rows show colour, chance %, cost/craft, loss/point, known/learn.
  - start skill edit box: entering 120 replans with `{ skill = 120 }`; "For:" dropdown lists guild members with the profession; "Reset" returns to the player.
  - no AH data: plan area shows the missing-prices text, no error; `stopAt`: "Nothing known gives skill from <n>".
  - the old list (BuildLevelingRows) still renders below.
  - every new text key exists in EN and SK (`tests/test_locale.lua` pattern).
- [ ] **Step 2: Run, verify FAIL.**
- [ ] **Step 3: Implement** in the existing UI style (row frames, gold headers, tooltip/detail on click reusing the recipe detail). Recompute on skill/recipes/prices change, at most once per 3 s, cached per (profession, who).
- [ ] **Step 4: Run, verify PASS**; then PUC: `python C:\Users\majfr\AppData\Local\Temp\claude\66ee6d216dc11530\f3c543f0-977b-4f2c-9e36-907fe6bcb49f\scratchpad\qa\testC\run51.py` -> all pass.
- [ ] **Step 5: Timing**: a script under PUC Lua 5.1 (`python ...\scratchpad\hitch\lua51.py <script>`) building a full profession (~120 recipes, all priced) and calling Plan + GivesNow: worst single frame < 8 ms; if not, move Plan into an NpcWork job with `Pace` per level. Record the numbers in the commit message.
- [ ] **Step 6: Commit** `Window: the leveling guide`.

### Task 4: Docs, zip, install

**Files:**
- Modify: `CHANGELOG.md` (new `## 0.8.0 – unreleased` section, line about the guide), `docs/TESTOVANIE.md` (Slovak rows: plan, alternatives, All, Gives skill now, edited skill, For: member, missing prices)
- Do NOT bump the TOC version yet (0.8.0 has two more parts).

- [ ] **Step 1:** write the docs lines; `luajit tests/run.lua` and the PUC suite pass.
- [ ] **Step 2:** build a test zip `dist/Profguild-0.8.0-dev.zip` the same way as commit d6b10b6 (`git -c core.autocrlf=false archive HEAD Profguild` + Python zipfile), not committed (dist/ is gitignored).
- [ ] **Step 3:** install for in-game testing: edit nothing in WoW folders by hand; the coordinator runs `python C:/Users/majfr/.claude/scripts/profguild-install.py` (it takes the newest dist zip).
- [ ] **Step 4: Commit** `Docs: the leveling guide in the changelog and the test list`.
