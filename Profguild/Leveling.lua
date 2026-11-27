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
-- Leveling.GivesNow(recipes, skill) -> { { r=, colour="orange"|"yellow"|"green", chance=, cost=, loss= }, ... }
--   sorted by loss per point (negative = profit), cheapest first
-- Leveling.Plan(recipes, from, to) -> { from=, to=, total=, stopAt = skill|nil,
--   segments = { { from=, to=, r=, count=, loss=, learn=boolean, alts = { { r=, count=, loss= } x <= 3 }, all=n } } }

local _, ns = ...
ns = ns or {}

local Leveling = {}
ns.Leveling = Leveling

Leveling.MAX = 300
Leveling.ALTS = 3

local floor, huge = math.floor, math.huge
local type, ipairs, sort = type, ipairs, table.sort

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

function Leveling.GivesNow(recipes, skill)
	local rows = {}
	for _, r in ipairs(recipes) do
		local c = chance(r, skill)
		if c > 0 then
			rows[#rows + 1] = { r = r, colour = colour(r, skill), chance = c, cost = r.cost,
				loss = floor((r.cost - unitValue(r, 1)) / c) }
		end
	end
	sort(rows, byLoss)
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

-- The cheapest whole path: a shortest path over (skill, recipe used last). Crafting recipe i at
-- skill s costs net[i] / chance; entering a recipe not known pays its learn price (again when the
-- path leaves it and comes back: rare, accepted). The value of a craft is fixed per recipe (the
-- thin market over all the crafts it can give from `from`), so the search stays linear in
-- levels x recipes.
function Leveling.Plan(recipes, from, to)
	to = floor(to or Leveling.MAX)
	from = floor(from or 1)
	if from < 1 then from = 1 end
	local plan = { from = from, to = to, total = 0, segments = {} }
	if from >= to then return plan end

	-- the recipes the plan may use, in a fixed order (ties go the same way every time)
	local use = {}
	for _, r in ipairs(recipes) do
		if (r.known or type(r.learnPrice) == "number") and limits(r) then use[#use + 1] = r end
	end
	sort(use, function(a, b) return (a.id or 0) < (b.id or 0) end)
	local n = #use
	local net, learn = {}, {}
	for i = 1, n do
		local r = use[i]
		local crafts = 0
		for s = from, to - 1 do
			local c = chance(r, s)
			if c > 0 then crafts = crafts + 1 / c end
		end
		net[i] = r.cost - unitValue(r, crafts)
		learn[i] = learnCost(r)
	end

	-- prev[i]: cheapest cost to reach skill s with recipe i used last; stay[k]: 1 when the best
	-- way to the next skill with i continued i, else it entered i from argmin[s]
	local prev, cur, stay, argmin = {}, {}, {}, {}
	for i = 1, n do prev[i] = huge end
	local minAll, minAt = 0, nil
	local reached = from
	local EPS = 1e-9
	for s = from, to - 1 do
		local base = (s - from) * n
		local any = false
		for i = 1, n do
			local c = chance(use[i], s)
			if c > 0 then
				local step = net[i] / c
				local stayCost, enter = prev[i], minAll + learn[i]
				if stayCost <= enter + EPS then
					cur[i] = stayCost + step
					stay[base + i] = 1
				else
					cur[i] = enter + step
					stay[base + i] = 0
				end
				any = true
			else
				cur[i] = huge
				stay[base + i] = 0
			end
		end
		if not any then
			plan.stopAt = s
			break
		end
		argmin[s] = minAt
		prev, cur = cur, prev
		reached = s + 1
		minAll, minAt = huge, nil
		for i = 1, n do
			if prev[i] < minAll then minAll, minAt = prev[i], i end
		end
	end
	if reached == from then return plan end

	-- back from the last skill reached: which recipe gives each level
	local used = {}
	local i = minAt
	for s = reached - 1, from, -1 do
		used[s] = i
		if stay[(s - from) * n + i] ~= 1 then i = argmin[s] end
	end

	local s = from
	while s < reached do
		local k = used[s]
		local r = use[k]
		local seg = { from = s, r = r, count = 0, loss = learn[k], learn = not r.known }
		while s < reached and used[s] == k do
			local c = chance(r, s)
			seg.count = seg.count + 1 / c
			seg.loss = seg.loss + net[k] / c
			s = s + 1
		end
		seg.to = s
		plan.segments[#plan.segments + 1] = seg
		plan.total = plan.total + seg.loss
	end

	-- alternatives: another recipe alone over the whole segment, its learn price in
	for _, seg in ipairs(plan.segments) do
		local alts = {}
		for j = 1, n do
			local r = use[j]
			if r ~= seg.r then
				local count, loss = 0, learn[j]
				for lv = seg.from, seg.to - 1 do
					local c = chance(r, lv)
					if c <= 0 then count = nil break end
					count = count + 1 / c
					loss = loss + net[j] / c
				end
				if count then alts[#alts + 1] = { r = r, count = count, loss = loss } end
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
