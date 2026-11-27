-- Profguild: Leveling
-- The leveling guide's model (design "Leveling guide", 0.8.0): the chance of a skill point, the
-- value of crafted items in a thin market, what gives skill at a skill, and the cheapest whole
-- path to the maximum skill with alternatives per segment. Pure: no frames, no WoW API; the UI
-- builds the recipes from prices, reagents, recipes known and the NPC tables (UI:LevelingInput).
--
-- A recipe r = { id=, name=, learn=number|nil, yellow=, grey=, cost = copper per craft,
--   ah = copper per craft after the AH cut|nil, avail = crafts' worth on the market|nil,
--   vendor = copper per craft at a vendor|nil, known = boolean, learnPrice = copper|nil, learnWhere = any }
-- known false and learnPrice nil: no known source; never planned, still in GivesNow.
--
-- Leveling.Chance(r, skill) -> 0..1
-- Leveling.UnitValue(r, n) -> copper per craft when n crafts are sold
-- Leveling.GivesNow(recipes, skill) -> { { r=, colour="orange"|"yellow"|"green", chance=, cost=, loss=,
--   crafts=, net=, source=boolean }, ... }: the product valued as an alternative from that skill
--   (crafts: expected from skill to the recipe's grey, at most MAX); net = cost - value per craft;
--   sorted by loss per point (negative = profit), cheapest first, those without a known source
--   (source false: the plan never uses them) after the others
-- Leveling.Plan(recipes, from, to[, pace]) -> { from=, to=, total=, stopAt = skill|nil,
--   segments = { { from=, to=, r=, count=, loss=, learn=boolean, alts = { { r=, count=, loss= } x <= 3 }, all=n } } }
--   pace(units), when given, is called before each part of the work (the recipes, a level of a
--   search round, a round's segments, a segment's alternatives) with its size in recipe-levels:
--   NpcWork's Pace, so that a job can spread the search over frames.

local _, ns = ...
ns = ns or {}

local Leveling = {}
ns.Leveling = Leveling

Leveling.MAX = 300
Leveling.ALTS = 3
Leveling.ROUNDS = 4 -- searches at most: a craft valued by the crafts the last path made of it

local floor, huge = math.floor, math.huge
local type, ipairs, pairs, sort = type, ipairs, pairs, table.sort

-- yellow and grey of a recipe, yellow never above grey (the client has a recipe with it above);
-- nil when either is missing
local function limits(r)
	local yellow, grey = r.yellow, r.grey
	if type(yellow) ~= "number" or type(grey) ~= "number" then return nil end
	if yellow > grey then yellow = grey end
	return yellow, grey
end

-- Orange 100 %; from yellow to grey (grey - skill) / (grey - yellow); grey and below the learn
-- skill nothing.
function Leveling.Chance(r, skill)
	local yellow, grey = limits(r)
	if not yellow or skill >= grey then return 0 end
	if type(r.learn) == "number" and skill < r.learn then return 0 end
	if skill <= yellow then return 1 end
	-- here yellow < skill < grey, so grey - yellow > 0
	local c = (grey - skill) / (grey - yellow)
	if c > 1 then return 1 end
	if c < 0 then return 0 end
	return c
end
local chance = Leveling.Chance

-- What a craft brings on average when n are sold: the AH value for as many as the market holds,
-- the vendor's price for the rest.
function Leveling.UnitValue(r, n)
	if type(n) ~= "number" or n < 1 then n = 1 end
	local vendor = r.vendor or 0
	local ah = r.ah
	if not ah then return vendor end
	local avail = r.avail
	if type(avail) ~= "number" or avail >= n then return ah end
	if avail < 0 then avail = 0 end
	return (avail * ah + (n - avail) * vendor) / n
end
local unitValue = Leveling.UnitValue

local function colour(r, skill)
	local yellow, grey = limits(r)
	if skill < yellow then return "orange" end
	if skill < floor((yellow + grey) / 2) then return "yellow" end
	return "green"
end

local function byLoss(a, b)
	if a.loss ~= b.loss then return a.loss < b.loss end
	local an, bn = a.r.name or "", b.r.name or ""
	if an ~= bn then return an < bn end
	return (a.r.id or 0) < (b.r.id or 0)
end

-- the plan may use a recipe: known, or a price to learn it
local function hasSource(r)
	return r.known or type(r.learnPrice) == "number"
end

-- Where a recipe gives points: skills lo <= s < hi; y = its yellow (100 % up to it), g = grey.
local function range(r)
	local y, g = limits(r)
	local lo = type(r.learn) == "number" and r.learn > 1 and math.ceil(r.learn) or 1
	return lo, g, y
end

-- harmonic numbers, grown as needed: harm[k] = 1 + 1/2 + ... + 1/k
local harm = { [0] = 0 }
local function harmonic(k)
	for j = #harm + 1, k do harm[j] = harm[j - 1] + 1 / j end
	return harm[k] or 0
end

-- The expected crafts of a recipe with the range (lo, hi, y) from skill a up to b (a <= s < b):
-- 1 per orange level, (hi - y) / (hi - s) per yellow or green one (a harmonic sum, no loop).
local function craftsBetween(lo, hi, y, a, b)
	if a < lo then a = lo end
	if b > hi then b = hi end
	if a >= b then return 0 end
	local n = 0
	local orangeTo = y + 1 < b and y + 1 or b -- orange: a <= s <= y
	if orangeTo > a then n = orangeTo - a end
	local ya = a > y + 1 and a or y + 1
	if ya < b then n = n + (hi - y) * (harmonic(hi - ya) - harmonic(hi - b)) end
	return n
end

-- The list's value rule, the same as an alternative's from skill s: the expected crafts from s
-- until the recipe turns grey, at most up to MAX.
function Leveling.GivesNow(recipes, skill)
	local rows = {}
	for _, r in ipairs(recipes) do
		local c = chance(r, skill)
		if c > 0 then
			local lo, g, y = range(r)
			local crafts = craftsBetween(lo, g, y, skill, Leveling.MAX)
			local net = r.cost - unitValue(r, crafts)
			rows[#rows + 1] = { r = r, colour = colour(r, skill), chance = c, cost = r.cost,
				crafts = crafts, net = net, loss = floor(net / c), source = hasSource(r) and true or false }
		end
	end
	sort(rows, function(a, b)
		if a.source ~= b.source then return a.source end
		return byLoss(a, b)
	end)
	return rows
end

local function givesCount(recipes, skill)
	local n = 0
	for _, r in ipairs(recipes) do
		if chance(r, skill) > 0 then n = n + 1 end
	end
	return n
end

local function learnCost(r)
	if r.known then return 0 end
	return r.learnPrice
end

-- the chance at s of a recipe with the range (lo, hi, y): Leveling.Chance without the lookups
local function rangeChance(lo, hi, y, s)
	if s < lo or s >= hi then return 0 end
	if s <= y then return 1 end
	return (hi - s) / (hi - y)
end

-- The cheapest whole path: a shortest path over (skill, recipe used last). Crafting recipe i at
-- skill s costs net[i] / chance; entering a recipe not known pays its learn price (again when the
-- path leaves it and comes back: rare, accepted). The value of a craft is fixed per recipe within
-- a search, so it stays linear in levels x recipes; each recipe gives points over one run of
-- skills, so a level looks only at the recipes giving points there (about a fifth of a
-- profession). The thin market: the first search values a recipe by all the crafts it can give
-- from `from`; the next ones value the recipes of the last path by the crafts it made of them
-- (the others still by all), until the path stays the same or after ROUNDS searches. Each path
-- is valued by its own crafts; the plan is the cheapest of them.
function Leveling.Plan(recipes, from, to, pace)
	to = floor(to or Leveling.MAX)
	from = floor(from or 1)
	if from < 1 then from = 1 end
	local plan = { from = from, to = to, total = 0, segments = {} }
	if from >= to then return plan end

	-- the recipes the plan may use, in a fixed order (ties go the same way every time)
	local use = {}
	for _, r in ipairs(recipes) do
		if hasSource(r) and limits(r) then use[#use + 1] = r end
	end
	sort(use, function(a, b) return (a.id or 0) < (b.id or 0) end)
	local n = #use
	local whole, learn, lo, hi, ye = {}, {}, {}, {}, {}
	local starts = {} -- skill -> recipes that start giving points there (from at the earliest)
	if pace and n > 0 then pace(n) end
	for i = 1, n do
		local r = use[i]
		local l, g, y = range(r)
		lo[i], hi[i], ye[i] = l, g, y
		local first, last = l > from and l or from, g < to and g or to
		whole[i] = craftsBetween(l, g, y, first, last)
		learn[i] = learnCost(r)
		if first < last then
			local list = starts[first]
			if not list then list = {} starts[first] = list end
			list[#list + 1] = i
		end
	end

	local EPS = 1e-9
	-- One search with the values net[i] per craft: the recipe giving each level (used[s]), the
	-- skill reached and where nothing gave a point (nil: nowhere).
	local function search(net)
		-- best[i]: cheapest cost to reach the current skill with recipe i used last; stay[i][s - first + 1]:
		-- 1 when the best way to s + 1 with i continued i, 0 when it entered i from argmin[s]
		local best, stay, first, argmin = {}, {}, {}, {}
		local active, na = {}, 0
		local minAll, minAt = 0, nil
		local reached, stopAt = from, nil
		for s = from, to - 1 do
			-- recipes grey at s leave, recipes orange from s come in (in the fixed order)
			local k = 0
			for a = 1, na do
				local i = active[a]
				if hi[i] > s then k = k + 1 active[k] = i end
			end
			for a = k + 1, na do active[a] = nil end
			na = k
			local list = starts[s]
			if list then
				for _, i in ipairs(list) do
					best[i], stay[i], first[i] = huge, {}, s
					-- kept in the fixed order: in at its place
					local at = na
					while at > 0 and active[at] > i do
						active[at + 1] = active[at]
						at = at - 1
					end
					active[at + 1] = i
					na = na + 1
				end
			end
			if na == 0 then
				stopAt = s
				break
			end
			if pace then pace(na) end
			for a = 1, na do
				local i = active[a]
				local y = ye[i]
				local c = s <= y and 1 or (hi[i] - s) / (hi[i] - y)
				local step = net[i] / c
				local stayCost, enter = best[i], minAll + learn[i]
				if stayCost <= enter + EPS then
					best[i] = stayCost + step
					stay[i][s - first[i] + 1] = 1
				else
					best[i] = enter + step
					stay[i][s - first[i] + 1] = 0
				end
			end
			argmin[s] = minAt
			reached = s + 1
			minAll, minAt = huge, nil
			for a = 1, na do
				local i = active[a]
				if best[i] < minAll then minAll, minAt = best[i], i end
			end
		end
		local used = {}
		if reached == from then return used, reached, stopAt end
		-- back from the last skill reached: which recipe gives each level
		local i = minAt
		for s = reached - 1, from, -1 do
			used[s] = i
			if stay[i][s - first[i] + 1] ~= 1 then i = argmin[s] end
		end
		return used, reached, stopAt
	end

	-- The segments of a path, each recipe's product valued by the crafts the path makes of it;
	-- also the total and those crafts per recipe.
	local function segments(used, reached)
		if pace then pace(reached - from) end
		local crafts = {}
		for s = from, reached - 1 do
			local k = used[s]
			crafts[k] = (crafts[k] or 0) + 1 / rangeChance(lo[k], hi[k], ye[k], s)
		end
		local net = {}
		for k, c in pairs(crafts) do net[k] = use[k].cost - unitValue(use[k], c) end
		local segs, total = {}, 0
		local s = from
		while s < reached do
			local k = used[s]
			local r = use[k]
			local seg = { from = s, r = r, count = 0, loss = learn[k], learn = not r.known }
			while s < reached and used[s] == k do
				local c = rangeChance(lo[k], hi[k], ye[k], s)
				seg.count = seg.count + 1 / c
				seg.loss = seg.loss + net[k] / c
				s = s + 1
			end
			seg.to = s
			segs[#segs + 1] = seg
			total = total + seg.loss
		end
		return segs, total, crafts
	end

	local N, net = {}, {}
	for i = 1, n do N[i] = whole[i] end
	local prev, bestTotal
	for _ = 1, Leveling.ROUNDS do
		for i = 1, n do net[i] = use[i].cost - unitValue(use[i], N[i]) end
		local used, reached, stopAt = search(net)
		plan.stopAt = stopAt
		if reached == from then return plan end
		local same = prev ~= nil
		if same then
			for s = from, reached - 1 do
				if used[s] ~= prev[s] then same = false break end
			end
		end
		if same then break end
		local segs, total, crafts = segments(used, reached)
		if not bestTotal or total < bestTotal - EPS then
			bestTotal = total
			plan.segments, plan.total = segs, total
		end
		prev = used
		for i = 1, n do N[i] = crafts[i] or whole[i] end
	end

	-- alternatives: another recipe alone over the whole segment, its learn price in, valued as in
	-- the list (the crafts from the segment's start until it turns grey)
	for _, seg in ipairs(plan.segments) do
		if pace then pace(n) end
		local alts = {}
		for j = 1, n do
			local r = use[j]
			if r ~= seg.r and lo[j] <= seg.from and hi[j] >= seg.to then
				local count = craftsBetween(lo[j], hi[j], ye[j], seg.from, seg.to)
				local value = unitValue(r, craftsBetween(lo[j], hi[j], ye[j], seg.from, Leveling.MAX))
				alts[#alts + 1] = { r = r, count = count, loss = learn[j] + (r.cost - value) * count }
			end
		end
		sort(alts, byLoss)
		for j = Leveling.ALTS + 1, #alts do alts[j] = nil end
		seg.alts = alts
		seg.all = givesCount(recipes, seg.from)
	end
	return plan
end

return Leveling
