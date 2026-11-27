# Leveling guide (Profguild 0.8.0, part 1 of 3) — design

Status: draft for the user's approval, 2026-11-27.
0.8.0 holds three separate features, built one at a time in this order: 1. leveling guide (this
document), 2. reputation recipes, 3. NPC data bundled in the addon.

## Intent

Today the LEVELING tab only lists the recipes of the recipe filter, sorted by the skill at which they
turn grey (`UI:BuildLevelingRows`, UI.lua:751). It does not say what to craft. The user wants a guide:
"craft this up to skill N, then learn that and craft it up to M …", computed from what the player
knows and from Auction House prices, with the smallest loss (or a profit) to reach skill 300.

## Goals

- A plan for the selected profession from the player's current skill to the maximum (300): a list of
  segments `from–to  recipe  ~count  loss/profit  [known | learn: price, where]`, and a total.
- Each segment can be expanded: the 3 best alternatives for that segment, then a row "All (n) →".
- A view "Gives skill now": every recipe that gives a skill point at a given skill, sorted by loss
  per point, with colour, chance, cost per craft, loss per point and known/learn. Opened by a toggle
  on the tab (at the player's current skill) and by "All (n) →" (at the start of that segment). One
  list implementation serves both.
- **Plan for someone else** (the user's request: advise a friend): the start skill is an editable
  number (default: the player's current skill) and the plan can be made for any profession, also one
  the player does not have. Whose recipes count as known (my proposal):
  - the player's own skill and recipes by default;
  - a "For: <guild member>" pick uses that member's skill and known recipes from the guild store;
  - an edited skill, or a profession the chosen person lacks, means "nobody's recipes": nothing is
    known, every recipe counts its learn price (trainer recipes below the start skill are assumed
    learned, since a player at that skill has them almost always).
  A "Reset" returns to the player's own data.
- Clicking a row shows the existing recipe detail (reagents, prices, where it is learned, map).
- The old list (sorted by grey skill) stays below the plan.

## Non-goals

- Reputation recipes and bundled NPC data (parts 2 and 3 of 0.8.0).
- Farming routes, gathering professions' own leveling, specialisations.
- Anything sent over guild sync: the plan is computed locally.

## Anti-goals

- No hitch: computing the plan must keep to the NpcWork frame budget (<= 8 ms per frame in PUC
  Lua 5.1), or be cheap enough to run in one frame with margin — measure it.
- No made-up numbers shown as facts: counts are labelled as estimates (`~`), recipes without a price
  are left out and the tab says so ("missing prices: scan the Auction House").

## Decisions (the user's)

- **Prices: Auction House for everything** — reagents, products and reagents the player already has
  in bags or bank (no "free" items). A vendor price is used only when the AH knows nothing of the item
  (same rule as reagent prices since 0.2.1).
- **Value of the product:** AH price minus the 5 % AH cut (as Profit since 0.2.1); a product the AH
  does not know is valued at its vendor sell price.
- **Goal:** the smallest total loss (or the biggest profit) to the maximum skill.
- **Path search: approach A** (see Approaches) — the cheapest whole path, not a greedy choice per level.
- **Alternatives:** 3 best per segment plus "All (n) →" into the "Gives skill now" view for that skill.

## Approaches (considered)

- **A. Cheapest whole path (chosen).** Shortest path over skill levels 1..300: from skill s a step
  crafts recipe r once; expected cost per point at s = (craft cost − product value) / chance(r, s);
  learning a recipe not yet known adds its learn price once. Sees that paying to learn a recipe that
  covers 40 levels beats a recipe that is cheap for 3. Alternatives fall out of the same per-level costs.
- **B. Greedy per level.** Take the cheapest recipe at every level. Simpler, but blind ahead: it can
  pay to learn a recipe used for a few points only. Rejected.
- **C. A fixed, hand-written guide.** Ignores AH prices and the guild's market. Rejected.

## Model (proposals — mine, the builder may refine with reason)

- **Chance of a skill point** (classic rule): orange 100 %; from yellow to grey
  chance = (grey − skill) / (grey − yellow), clamped to [0, 1]; grey 0. Colour thresholds from the
  sources the detail already uses (`recipeSkillNumbers` / NpcView.Skill: game, trainers, Data.lua).
  A recipe without skill numbers is left out of the plan.
- **Crafts per point** = 1 / chance; a segment's count is the sum over its levels, rounded and shown
  with `~`.
- **Learn price and place:** from the NPC tables of 0.7.0 (trainer or vendor price, name, zone, map);
  a recipe item sold on the AH may be bought there instead — take the cheaper. A recipe the player
  cannot get from any known source is still shown in "Gives skill now" but not used by the plan.
- **Thin markets:** a product's value counts only for as many units as the AH currently lists
  (Prices.Available); units beyond that are valued at the vendor sell price. This keeps the plan from
  "selling" 60 elixirs nobody buys. (My call; flagged for the user.)
- **Segments:** consecutive levels using the same recipe form one segment.
- **Recompute** when the profession's skill, known recipes or prices change, at most once per few
  seconds; cache per profession.

## UI sketch

```
LEVELING – Alchemy 112 -> 300            total: loss ~38 g
-----------------------------------------------------------------
112-140  Healing Potion          ~34 pcs  loss  4 g 10 s   [known]     [-]
   alt.  Lesser Mana Potion      ~38 pcs  loss  5 g 40 s   [known]
   alt.  Elixir of Wisdom        ~30 pcs  loss  6 g 90 s   [learn 1 g]
   alt.  Swiftness Potion        ~33 pcs  loss  7 g 15 s   [known]
   All (12) ->
140-155  Lesser Mana Potion      ~18 pcs  profit 0 g 60 s  [known]
155-185  Elixir of Agility       ~36 pcs  loss  9 g 05 s   [learn: trainer Kray, 1 g 80 s]
...
[Gives skill now]          (toggle)
-----------------------------------------------------------------
old list sorted by grey skill
```

```
GIVES SKILL NOW – Alchemy 112
Recipe               colour   chance  cost/craft  loss/point  recipe
Healing Potion       yellow   71 %    38 s        12 s        known
Lesser Mana Potion   orange   100 %   45 s        15 s        known
Elixir of Wisdom     orange   100 %   61 s        24 s        learn 1 g
```

Texts in English and Slovak (Locale.lua), in the addon's existing WoW-native style.

## Left to the builder

- Exact layout, widths, and how expand/collapse is drawn within the existing UI code.
- Where the computation lives (a new module, e.g. `Leveling.lua`) and its caching.
- Tests: chance model, path search (A beats greedy on a learn-cost case), thin-market valuation,
  missing prices, segments, alternatives ordering, "All (n)" list equals the "Gives skill now" view
  at that skill, EN/SK texts; timing under PUC Lua 5.1 with a full profession (all recipes known).
- docs/TESTOVANIE.md rows (Slovak), CHANGELOG line.
