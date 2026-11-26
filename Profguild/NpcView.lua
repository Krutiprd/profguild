-- Profguild: NpcView
-- What the recipe detail says (design "Window"): the skill numbers and the ordered sources for
-- FIND RECIPE. Pure: no frames, no WoW API; texts are the UI's.
--
-- src = { own = npcOwn table, guild = guild's (or own) table, info = recipeInfo[recipeID], data = ns.RecipeData }
--   (the numbers of Data.lua come from Prices.RecipeSkill, which reads ns.RecipeData: data is not read here)
-- NpcView.Skill(recipeID, src) -> { learn=|nil, yellow=, green=, grey=, show = { { number, "learn"|"yellow"|"green"|"grey" }, ... } }
-- NpcView.Sources(recipeID, src, where) -> rows in display order; where = { map=, items = { [itemID]=true },
--   recipeItem = id|false|nil, letters = "vd", ah = { copper=, text= }|nil }. A row:
--   { kind = "ah"|"trainer"|"vendor"|"other" (how = { "drop", "quest", "crafted" } present, in that order)|"missing"|"unknown", id=, name=, map=, x=, y=,
--     copper=, other = { { kind, id, count }, ... }|nil, limited=, age=days, approx=, best=, of="vendor"|"trainer" (missing),
--     text = where.ah.text (ah) }
--
-- Finding sheets by recipe or item: the table has no such lookup, so an index (recipe -> NPCs, item -> NPCs) is
-- built per table and rebuilt when the table's hash, sheet count or entry count changes (Hash is cached
-- by the table), never walked on every redraw.

local _, ns = ...
ns = ns or {}

local NpcView = {}
ns.NpcView = NpcView

local OWN_DAYS = 30 -- an own reading of the last 30 days is shown instead of the guild's
local floor, min = math.floor, math.min
local pairs, ipairs, type, sort = pairs, ipairs, type, table.sort

-- The index ------------------------------------------------------------------------------

local indexes = setmetatable({}, { __mode = "k" })

local function indexOf(tab)
	local key = tab:Hash() .. ":" .. tab.nSheets .. ":" .. tab.nEntries
	local ix = indexes[tab]
	if ix and ix.key == key then return ix end
	ix = { key = key, t = {}, v = {} }
	for npc, s in pairs(tab.sheets) do
		for id in pairs(s.t) do
			local l = ix.t[id]
			if not l then l = {} ix.t[id] = l end
			l[#l + 1] = npc
		end
		for id in pairs(s.v) do
			local l = ix.v[id]
			if not l then l = {} ix.v[id] = l end
			l[#l + 1] = npc
		end
	end
	indexes[tab] = ix
	return ix
end

-- NPC IDs of both tables holding the key in part ("t" or "v"), each once.
local function npcs(src, part, key)
	local seen, list = {}, {}
	for _, tab in ipairs({ src.guild or false, src.own or false }) do
		if tab then
			for _, npc in ipairs(indexOf(tab)[part][key] or {}) do
				if not seen[npc] then seen[npc] = true list[#list + 1] = npc end
			end
		end
	end
	return list
end

local function today(src)
	local tab = src.guild or src.own
	return tab and tab:Today() or 0
end

-- Skill ----------------------------------------------------------------------------------

-- Without a guild the guild's table is npcOwn itself: then it is the own reading, not the guild's.
local function plain(src)
	if src.guild == src.own then return { own = src.own, info = src.info, data = src.data } end
	return src
end

function NpcView.Skill(recipeID, src)
	src = plain(src)
	local info = src.info or {}
	local dataLearn, dataYellow, _, dataGrey = nil, nil, nil, nil
	local P = ns.Prices
	if P and P.RecipeSkill then dataLearn, dataYellow, _, dataGrey = P.RecipeSkill(recipeID) end
	local grey = type(info.g) == "number" and info.g > 0 and info.g or dataGrey
	local yellow = dataYellow
	if yellow and grey then yellow = min(yellow, grey) end
	local green = yellow and grey and floor((yellow + grey) / 2) or nil

	-- learn: trainer sheets (the later day, then the greatest), else info.m, else Data.lua
	local function ok(n) return type(n) == "number" and n > 0 and (not grey or n <= grey) end
	local learn
	local bestDay
	for _, npc in ipairs(npcs(src, "t", recipeID)) do
		for _, tab in ipairs({ src.guild or false, src.own or false }) do
			local s = tab and tab:Get(npc)
			local e = s and s.t[recipeID]
			if e and ok(e[2]) and (not learn or e[3] > bestDay or (e[3] == bestDay and e[2] > learn)) then
				learn, bestDay = e[2], e[3]
			end
		end
	end
	if not learn and ok(info.m) then learn = info.m end
	if not learn and ok(dataLearn) then learn = dataLearn end

	local r = { learn = learn, yellow = yellow, green = green, grey = grey, show = {} }
	local show = r.show
	local function add(n, name) if n then show[#show + 1] = { n, name } end end
	if not learn then
		add(yellow, "yellow") add(green, "green") add(grey, "grey")
	elseif grey and learn >= grey then
		add(learn, "learn")
	elseif yellow and learn > yellow then
		add(learn, "learn") add(grey, "grey")
	else
		add(learn, "learn") add(yellow, "yellow") add(green, "green") add(grey, "grey")
	end
	return r
end

-- Sources --------------------------------------------------------------------------------

local function samePrice(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" or a.c ~= b.c or a.l ~= b.l or #a.o ~= #b.o then return false end
	for i, c in ipairs(a.o) do
		local d = b.o[i]
		if c[1] ~= d[1] or c[2] ~= d[2] or c[3] ~= d[3] then return false end
	end
	return true
end

-- Which reading of an NPC is shown. g, o: the guild's and the own register (value, day) or nil.
-- Returns the value, whether it is the guild's (marked ~).
local function choose(gv, gd, ov, od, now, same)
	if ov and od and now - od <= OWN_DAYS then return ov, false end
	if gv and not (ov and same(gv, ov)) then return gv, true end
	if gv then return gv, false end
	if ov then return ov, false end
	return nil
end

local function head(a, b)
	local h = {}
	h.name = (a and a.name) or (b and b.name)
	if a and a.map then h.map, h.x, h.y = a.map, a.x, a.y
	elseif b and b.map then h.map, h.x, h.y = b.map, b.x, b.y end
	return h
end

local function row(kind, npc, gs, os, now, entryOf, valueOf)
	local ge, oe = gs and entryOf(gs), os and entryOf(os)
	local gv, gd, ov, od
	if ge then gv, gd = valueOf(ge) end
	if oe then ov, od = valueOf(oe) end
	local v, approx = choose(gv, gd, ov, od, now, samePrice)
	local h = head(gs, os)
	local seen = math.max(ge and ge[1] or 0, oe and oe[1] or 0)
	return { kind = kind, id = npc, name = h.name, map = h.map, x = h.x, y = h.y, age = now - seen,
		approx = approx and v ~= nil or nil }, v
end

local function copperOf(c) return type(c) == "number" and c > 0 and c or nil end

local function trainerRows(recipeID, src, now)
	local rows = {}
	for _, npc in ipairs(npcs(src, "t", recipeID)) do
		local gs, os = src.guild and src.guild:Get(npc), src.own and src.own:Get(npc)
		if gs == os then os = nil end
		local r, c = row("trainer", npc, gs, os, now, function(s) return s.t[recipeID] end,
			function(e) return copperOf(e[4]), e[5] end)
		r.copper, r.approx = c, c and r.approx or nil
		rows[#rows + 1] = r
	end
	return rows
end

local function vendorRows(src, now, items)
	local byNpc, order = {}, {}
	for item in pairs(items) do
		for _, npc in ipairs(npcs(src, "v", item)) do
			local gs, os = src.guild and src.guild:Get(npc), src.own and src.own:Get(npc)
			if gs == os then os = nil end
			local r, p = row("vendor", npc, gs, os, now, function(s) return s.v[item] end,
				function(e) return e[2] or nil, e[3] end)
			if p then
				r.limited = p.l == 1 or nil
				if #p.o > 0 then r.other = p.o end
				r.copper = p.c > 0 and p.c or nil -- 0 means no copper price
			else
				r.approx = nil
			end
			local old = byNpc[npc]
			if not old then
				byNpc[npc] = r
				order[#order + 1] = r
			elseif r.copper and (not old.copper or r.copper < old.copper) then
				for k in pairs(old) do old[k] = nil end
				for k, v in pairs(r) do old[k] = v end
			end
		end
	end
	return order
end

local function sortRows(rows, map)
	sort(rows, function(a, b)
		local am, bm = a.map == map and map ~= nil, b.map == map and map ~= nil
		if am ~= bm then return am end
		if (a.copper ~= nil) ~= (b.copper ~= nil) then return a.copper ~= nil end
		if a.copper and a.copper ~= b.copper then return a.copper < b.copper end
		local an, bn = a.name or "", b.name or ""
		if an ~= bn then return an < bn end
		return (a.id or 0) < (b.id or 0)
	end)
end

local KIND_OF = { d = "drop", q = "quest", c = "crafted" }

function NpcView.Sources(recipeID, src, where)
	src = plain(src)
	where = where or {}
	local now = today(src)
	local letters = where.letters or ""
	local rows = {}

	if where.recipeItem then
		local ah = where.ah
		rows[#rows + 1] = { kind = "ah", copper = ah and ah.copper or nil, text = ah and ah.text or nil }
	end

	local trainers = trainerRows(recipeID, src, now)
	sortRows(trainers, where.map)
	for _, r in ipairs(trainers) do rows[#rows + 1] = r end
	if #trainers == 0 and where.recipeItem == false then rows[#rows + 1] = { kind = "missing", of = "trainer" } end

	local items = {}
	for item in pairs(where.items or {}) do items[item] = true end
	if type(where.recipeItem) == "number" then items[where.recipeItem] = true end
	local vendors = vendorRows(src, now, items)
	sortRows(vendors, where.map)
	for _, r in ipairs(vendors) do rows[#rows + 1] = r end
	if #vendors == 0 and letters:find("v", 1, true) then rows[#rows + 1] = { kind = "missing", of = "vendor" } end

	local how = {}
	for _, l in ipairs({ "d", "q", "c" }) do
		if letters:find(l, 1, true) then how[#how + 1] = KIND_OF[l] end
	end
	if #how > 0 then rows[#rows + 1] = { kind = "other", how = how } end

	if #rows == 0 then return { { kind = "unknown" } } end

	-- the cheapest copper price among at least two (rows with other costs do not take part)
	local n, best = 0, nil
	for _, r in ipairs(rows) do
		if r.copper and not r.other then
			n = n + 1
			if not best or r.copper < best.copper then best = r end
		end
	end
	if n >= 2 then best.best = true end
	return rows
end
