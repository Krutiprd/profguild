-- NPC reader (NpcReader): the trainer and merchant windows to readings, against a fake game made
-- from the probe of the live client (docs/superpowers/specs/2026-11-25-npc-probe-result.md).
local H = ...
local ns = H.newNamespace({ "NpcReader.lua" })
local R = ns.NpcReader

local SECRET = setmetatable({}, { __tostring = function() return "secret" end })
local BENA = "Creature-0-55165-1-15571149-3009-DB04E5BC4A"
local MANI = "Creature-0-14179-1-5712002-3010-69680F65EA"
local NATA = "Creature-0-21094-1-8674439-3012-C36EC7115E"

-- A fake game: g.services / g.items as the windows hold them, g.recipes as Data.lua and the catalog.
local function newGame()
	local g = {
		t = 0, timers = {}, combat = false, guid = BENA, name = "Bena Winterhoof", trainer = true,
		map = 1456, px = 0.473, py = 0.339, filled = true, services = {}, items = {},
		lines = { Alchemy = 171, Enchanting = 333, Tailoring = 197 }, recipes = {}, classes = {}, data = {},
		readings = {}, calls = { numItems = 0 },
	}
	g.api = {
		now = function() return g.t end,
		after = function(d, fn) g.timers[#g.timers + 1] = { at = g.t + d, fn = fn } end,
		inCombat = function() return g.combat end,
		secret = function(v) return v == SECRET end,
		npcGUID = function() return g.guid end,
		npcName = function() return g.name end,
		place = function()
			if not g.map then return nil end
			return g.map, g.px, g.py
		end,
		tradeskillTrainer = function() return g.trainer end,
		-- at TRAINER_SHOW the list is empty, at TRAINER_UPDATE it is filled
		numServices = function() return g.filled and #g.services or 0 end,
		serviceInfo = function(i)
			local s = g.services[i]
			return s.name, s.type or "available", 134835, 0, "", "Elixirs"
		end,
		serviceSkill = function(i)
			local s = g.services[i]
			if s.prof == nil then return nil, 0, true end
			return s.prof, s.skill or 0, true
		end,
		serviceCost = function(i) return g.services[i].copper or 0 end,
		lineOf = function(name) return g.lines[name] end,
		recipes = function(line)
			local out = {}
			for _, r in ipairs(g.recipes) do
				if r.line == line then out[#out + 1] = { id = r.id, name = r.name, line = r.line, item = r.item, grey = r.grey } end
			end
			return out
		end,
		numItems = function() g.calls.numItems = g.calls.numItems + 1 return #g.items end,
		itemInfo = function(i) return g.items[i].info end,
		itemID = function(i) return g.items[i].id end,
		costCount = function(i) return #(g.items[i].costs or {}) end,
		costItem = function(i, j)
			local c = g.items[i].costs[j]
			return 136000, c.count, c.link, c.name
		end,
		itemClass = function(id) return g.classes[id] end,
		dataItem = function(id) return g.data[id] == true end,
	}
	function g.run(seconds)
		local target = g.t + seconds
		while true do
			local best, bi
			for i, e in ipairs(g.timers) do
				if e.at <= target and (not best or e.at < best.at) then best, bi = e, i end
			end
			if not best then break end
			table.remove(g.timers, bi)
			g.t = best.at
			best.fn()
		end
		g.t = target
	end
	g.reader = R.New(g.api, function(id, reading) g.readings[#g.readings + 1] = { id = id, r = reading } end)
	return g
end

-- Alchemy as Data.lua has it: Elixir of Fire Power is a trainer recipe (no item), grey 165.
local function alchemy(g)
	g.recipes = {
		{ id = 7845, name = "Elixir of Fire Power", line = 171, item = false, grey = 165 },
		{ id = 2330, name = "Minor Healing Potion", line = 171, item = false, grey = 55 },
	}
	g.services = {
		{ name = "Alchemy", type = "header" },
		{ name = "Elixir of Fire Power", prof = "Alchemy", skill = 140, copper = 2700 },
	}
end

-- Opens the trainer the way the client does: empty at TRAINER_SHOW, filled at TRAINER_UPDATE.
local function openTrainer(g)
	g.filled = false
	g.reader:TrainerShow()
	g.filled = true
	g.reader:TrainerUpdate()
end

-- Match -----------------------------------------------------------------------

local function svc(name, skill, copper, line, spell)
	return { name = name, skill = skill, copper = copper, line = line or 171, spell = spell }
end

H.test("NpcReader.Match step 1: an exact spell ID decides before the name", function()
	local recipes = { { id = 11, name = "A", line = 171, item = false, grey = 100 }, { id = 12, name = "A", line = 171, item = false, grey = 100 } }
	local t, skipped = R.Match({ svc("A", 50, 100, 171, 12) }, recipes)
	H.eq(t[12].skill, 50) H.eq(t[11], nil) H.eq(skipped, 0)
	-- an ID decides even while a recipe of the profession has no name
	recipes[3] = { id = 13, line = 171, item = false, grey = 100 }
	t = R.Match({ svc("A", 50, 100, 171, 12) }, recipes)
	H.eq(t[12].copper, 100, "step 1 with a nameless recipe")
end)

H.test("NpcReader.Match step 2: the only recipe of that name, in that profession", function()
	local recipes = { { id = 11, name = "A", line = 171, item = 900, grey = 100 }, { id = 21, name = "A", line = 333, item = false, grey = 100 } }
	local t, skipped = R.Match({ svc("A", 50, 100) }, recipes)
	H.eq(t[11].skill, 50) H.eq(t[21], nil, "other profession not looked at") H.eq(skipped, 0)
	t, skipped = R.Match({ svc("B", 50, 100) }, recipes)
	H.eq(next(t), nil, "no recipe of that name") H.eq(skipped, 1)
end)

H.test("NpcReader.Match step 3: equal names, the only one without recipe item", function()
	-- step 3 decides before the greys: the no-item recipe's grey is below the skill
	local recipes = { { id = 11, name = "A", line = 171, item = 900, grey = 100 }, { id = 12, name = "A", line = 171, item = false, grey = 40 } }
	local t, skipped = R.Match({ svc("A", 50, 100) }, recipes)
	H.ok(t[12], "the no-item recipe") H.eq(t[12].copper, 100) H.eq(t[11], nil) H.eq(skipped, 0)
end)

H.test("NpcReader.Match step 4: grey below the skill excluded", function()
	-- among the no-item recipes left by 3
	local recipes = {
		{ id = 11, name = "A", line = 171, item = false, grey = 100 },
		{ id = 12, name = "A", line = 171, item = false, grey = 200 },
		{ id = 13, name = "A", line = 171, item = 900, grey = 300 },
	}
	local t = R.Match({ svc("A", 150, 100) }, recipes)
	H.eq(t[12].skill, 150) H.eq(t[11], nil) H.eq(t[13], nil, "with an item: out after step 3")
	-- 3 left none: among all of that name
	recipes = { { id = 11, name = "A", line = 171, item = 901, grey = 100 }, { id = 12, name = "A", line = 171, item = 902, grey = 200 } }
	t = R.Match({ svc("A", 150, 100) }, recipes)
	H.eq(t[12].skill, 150, "3 left none")
	-- two still fit, or none: not recorded
	local skipped
	t, skipped = R.Match({ svc("A", 50, 100) }, recipes)
	H.eq(next(t), nil, "both greys above") H.eq(skipped, 1)
	t, skipped = R.Match({ svc("A", 250, 100) }, recipes)
	H.eq(next(t), nil, "no grey above") H.eq(skipped, 1)
	-- unknown skill decides nothing in 4
	t, skipped = R.Match({ svc("A", nil, 100) }, recipes)
	H.eq(next(t), nil) H.eq(skipped, 1)
end)

H.test("NpcReader.Match: two services to one recipe with different values are both out", function()
	local recipes = { { id = 11, name = "A", line = 171, item = false, grey = 100 } }
	local t, skipped = R.Match({ svc("A", 50, 100), svc("A", 60, 100) }, recipes)
	H.eq(t[11], nil) H.eq(skipped, 2)
	t, skipped = R.Match({ svc("A", 50, 100), svc("A", 50, 100) }, recipes)
	H.eq(t[11].skill, 50, "equal values: kept") H.eq(skipped, 0)
	t, skipped = R.Match({ svc("A", 50, 100), svc("A", 50, 100), svc("A", 50, 200) }, recipes)
	H.eq(t[11], nil, "a third differs") H.eq(skipped, 3)
end)

H.test("NpcReader.Match: a skill above the recipe's grey is unknown, copper kept", function()
	local t = R.Match({ svc("A", 150, 2700) }, { { id = 11, name = "A", line = 171, item = false, grey = 100 } })
	H.eq(t[11].skill, nil) H.eq(t[11].copper, 2700)
end)

H.test("NpcReader.Match: recipes without Data.lua take part in 1 and 2 only", function()
	-- the only one of its name: step 2, and no grey to compare
	local t = R.Match({ svc("A", 150, 100) }, { { id = 11, name = "A", line = 171 } })
	H.eq(t[11].skill, 150)
	-- equal names: the one without Data.lua is not in 3 and 4
	local recipes = { { id = 11, name = "A", line = 171 }, { id = 12, name = "A", line = 171, item = false, grey = 200 } }
	t = R.Match({ svc("A", 150, 100) }, recipes)
	H.eq(t[12].skill, 150) H.eq(t[11], nil)
	local skipped
	t, skipped = R.Match({ svc("A", 150, 100) }, { { id = 11, name = "A", line = 171 }, { id = 12, name = "A", line = 171 } })
	H.eq(next(t), nil, "two without Data.lua") H.eq(skipped, 1)
end)

H.test("NpcReader.Match: a nameless recipe holds back 2-4 of its profession only", function()
	local recipes = {
		{ id = 11, name = "A", line = 171, item = false, grey = 100 }, { id = 12, line = 171, item = false, grey = 100 },
		{ id = 21, name = "B", line = 333, item = false, grey = 100 },
	}
	local t, skipped, pending = R.Match({ svc("A", 50, 100), svc("B", 50, 100, 333) }, recipes)
	H.eq(t[11], nil, "waits") H.eq(t[21].skill, 50, "other profession goes on")
	H.eq(#pending, 1) H.eq(pending[1].name, "A") H.eq(skipped, 0)
	-- a service without profession is left out
	t, skipped = R.Match({ { name = "B", skill = 50, copper = 100 } }, recipes)
	H.eq(next(t), nil) H.eq(skipped, 1)
end)

-- Trainer ---------------------------------------------------------------------

H.test("NpcReader trainer: NPC and place at TRAINER_SHOW, services 0.5 s later", function()
	local g = newGame()
	alchemy(g)
	openTrainer(g)
	H.eq(#g.readings, 0, "nothing at once")
	g.run(0.5)
	H.eq(#g.readings, 1, "one reading, the update debounced")
	local r = g.readings[1]
	H.eq(r.id, 3009) H.eq(r.r.name, "Bena Winterhoof")
	H.eq(r.r.map, 1456) H.eq(r.r.x, 47, "whole percent, down") H.eq(r.r.y, 33)
	H.eq(r.r.t[7845].skill, 140) H.eq(r.r.t[7845].copper, 2700)
	H.eq(next(r.r.v), nil)
	H.eq(g.reader.skipped, 0)
	-- a later TRAINER_UPDATE that changes nothing reads nothing; one that changes the list reads again
	g.reader:TrainerUpdate()
	g.run(0.5)
	H.eq(#g.readings, 1)
	g.services[3] = { name = "Minor Healing Potion", prof = "Alchemy", skill = 1, copper = 50 }
	g.reader:TrainerUpdate()
	g.run(0.5)
	H.eq(#g.readings, 2) H.eq(g.readings[2].r.t[2330].copper, 50)
end)

H.test("NpcReader trainer: a service without requirement takes the only profession", function()
	local g = newGame()
	alchemy(g)
	g.services[3] = { name = "Minor Healing Potion", copper = 50 }
	openTrainer(g)
	g.run(0.5)
	H.eq(g.readings[1].r.t[2330].copper, 50, "took Alchemy") H.eq(g.readings[1].r.t[2330].skill, nil)
	-- with two professions it is left out and counted
	g = newGame()
	alchemy(g)
	g.recipes[3] = { id = 7421, name = "Runed Copper Rod", line = 333, item = false, grey = 30 }
	g.services[3] = { name = "Runed Copper Rod", prof = "Enchanting", skill = 1, copper = 100 }
	g.services[4] = { name = "Minor Healing Potion", copper = 50 }
	openTrainer(g)
	g.run(0.5)
	local t = g.readings[1].r.t
	H.eq(t[2330], nil, "left out") H.ok(t[7845] and t[7421], "the others are read")
	H.eq(g.reader.skipped, 1)
end)

H.test("NpcReader trainer: a profession with a nameless recipe waits 60 s, then nameless ones are out", function()
	local g = newGame()
	alchemy(g)
	g.recipes[2].name = nil -- Minor Healing Potion not loaded yet
	openTrainer(g)
	g.run(0.5)
	H.eq(#g.readings, 0, "nothing by 2-4")
	g.reader:TrainerClosed()
	g.guid = nil
	g.recipes[2].name = "Minor Healing Potion"
	g.run(59)
	H.eq(#g.readings, 0, "not before 60 s")
	g.run(1)
	H.eq(#g.readings, 1, "again after 60 s, from memory, window closed")
	H.eq(g.readings[1].id, 3009) H.eq(g.readings[1].r.t[7845].skill, 140) H.eq(g.readings[1].r.map, 1456)
	-- from then on a recipe still without a name is left out, and the rest decides at once
	g.guid = BENA
	g.recipes[3] = { id = 7846, line = 171, item = false, grey = 165 }
	g.recipes[4] = { id = 7847, name = "Elixir of Fire Power", line = 171, item = 900, grey = 165 }
	openTrainer(g)
	g.run(0.5)
	H.eq(#g.readings, 2) H.eq(g.readings[2].r.t[7845].copper, 2700, "nameless recipe left out")
	g.run(120)
	H.eq(#g.readings, 2, "no third try")
end)

H.test("NpcReader trainer: closed before 0.5 s or another NPC opened: nothing under the wrong ID", function()
	local g = newGame()
	alchemy(g)
	openTrainer(g)
	g.reader:TrainerClosed()
	g.run(1)
	H.eq(#g.readings, 0, "closed")
	-- another NPC opened at once: only its own reading, under its ID
	openTrainer(g)
	g.guid, g.name = MANI, "Mani Winterhoof"
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 1) H.eq(g.readings[1].id, 3010) H.eq(g.readings[1].r.name, "Mani Winterhoof")
	-- the NPC changed without an event
	openTrainer(g)
	g.guid = BENA
	g.run(1)
	H.eq(#g.readings, 1, "other NPC at the timer")
	-- the trainer window was closed and a merchant of the same NPC opened
	openTrainer(g)
	g.reader:TrainerClosed()
	g.reader:MerchantShow()
	g.run(1)
	H.eq(#g.readings, 1, "trainer of a closed window")
end)

H.test("NpcReader trainer: class trainer, combat, secret value, no creature GUID: nothing", function()
	local function none(setup, msg)
		local g = newGame()
		alchemy(g)
		setup(g, "before")
		openTrainer(g)
		setup(g, "after")
		g.run(1)
		H.eq(#g.readings, 0, msg)
	end
	none(function(g) g.trainer = false end, "class trainer")
	none(function(g, at) if at == "before" then g.combat = true end end, "combat at show")
	none(function(g, at) if at == "after" then g.combat = true end end, "combat at the timer")
	none(function(g) g.services[2].name = SECRET end, "secret service name")
	none(function(g) g.services[2].copper = SECRET end, "secret cost")
	none(function(g) g.guid = SECRET end, "secret GUID")
	none(function(g) g.guid = "Player-1-00000001" end, "player GUID")
	none(function(g) g.guid = "Vehicle-0-55165-1-15571149-3009-DB04E5BC4A" end, "vehicle GUID")
	none(function(g) g.guid = nil end, "no GUID")
	none(function(g) g.services = {} end, "no services: no reading")
	-- a secret name or place only leaves that out
	local g = newGame()
	alchemy(g)
	g.name, g.px = SECRET, SECRET
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 1) H.eq(g.readings[1].r.name, nil) H.eq(g.readings[1].r.map, nil)
end)

H.test("NpcReader: no map or position gives a reading without place", function()
	local g = newGame()
	alchemy(g)
	g.map = nil
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 1) H.eq(g.readings[1].r.map, nil) H.eq(g.readings[1].r.x, nil) H.eq(g.readings[1].r.name, "Bena Winterhoof")
	g = newGame()
	alchemy(g)
	g.px, g.py = nil, nil
	openTrainer(g)
	g.run(1)
	H.eq(g.readings[1].r.map, nil, "map without position") H.ok(g.readings[1].r.t[7845], "services read")
	-- the edge of the map is 100
	g = newGame()
	alchemy(g)
	g.px, g.py = 1, 0
	openTrainer(g)
	g.run(1)
	H.eq(g.readings[1].r.x, 100) H.eq(g.readings[1].r.y, 0)
end)

-- Trainer filters ----------------------------------------------------------------

-- Kray at Thunder Bluff for a player at Alchemy 300: the filters hide what is known ("used"), so
-- the window lists one recipe of four. g.all is the trainer's whole list, g.services what the
-- filters let through; a filter change fires TRAINER_UPDATE at once (and once more a frame later)
-- and leaves nothing selected, like a client may.
local function kray(g)
	g.recipes = {
		{ id = 2330, name = "Minor Healing Potion", line = 171, item = false, grey = 55 },
		{ id = 2331, name = "Minor Mana Potion", line = 171, item = false, grey = 75 },
		{ id = 7845, name = "Elixir of Fire Power", line = 171, item = false, grey = 165 },
		{ id = 11450, name = "Elixir of Greater Defense", line = 171, item = false, grey = 225 },
	}
	g.all = {
		{ name = "Alchemy", type = "header" },
		{ name = "Minor Healing Potion", prof = "Alchemy", skill = 1, copper = 10, type = "used" },
		{ name = "Minor Mana Potion", prof = "Alchemy", skill = 25, copper = 50, type = "used" },
		{ name = "Elixir of Fire Power", prof = "Alchemy", skill = 140, copper = 2700, type = "used" },
		{ name = "Elixir of Greater Defense", prof = "Alchemy", skill = 195, copper = 9000, type = "available" },
	}
	g.filters = { available = true, unavailable = false, used = false }
	g.calls.set, g.calls.select, g.calls.get = 0, 0, 0
	g.updates = 0
	function g.refilter()
		g.services = {}
		for _, s in ipairs(g.all) do
			if s.type == "header" or g.filters[s.type] == true then g.services[#g.services + 1] = s end
		end
	end
	g.refilter()
	g.sel = 0
	g.api.trainerFilter = function(kind) g.calls.get = g.calls.get + 1 return g.filters[kind] end
	g.api.setTrainerFilter = function(kind, on)
		if g.setError then error(g.setError) end
		assert(type(on) == "boolean", "the Forever client wants true / false")
		g.calls.set = g.calls.set + 1
		g.filters[kind] = on
		g.refilter()
		g.sel = 0
		g.updates = g.updates + 1
		g.reader:TrainerUpdate()
		g.api.after(0.01, function() g.reader:TrainerUpdate() end)
	end
	g.api.trainerSelection = function() return g.sel end
	g.api.selectService = function(i) g.calls.select = g.calls.select + 1 g.sel = i end
end

local function selected(g) return g.sel > 0 and g.services[g.sel] or nil end

H.test("NpcReader trainer: the whole list is read under a filter that hides known recipes", function()
	local g = newGame()
	kray(g)
	openTrainer(g)
	g.run(0.5)
	H.eq(#g.readings, 1)
	local t = g.readings[1].r.t
	H.eq(t[2330].skill, 1) H.eq(t[2331].copper, 50) H.eq(t[7845].skill, 140) H.eq(t[11450].copper, 9000)
	-- the filters are as they were, the window shows the one recipe again
	H.eq(g.filters.available, true) H.eq(g.filters.unavailable, false) H.eq(g.filters.used, false)
	H.eq(#g.services, 2, "header and one recipe")
	-- only the filters that were off were switched, and back
	H.eq(g.calls.set, 4)
	-- all filters on already: nothing is switched
	g.calls.set = 0
	g.filters.unavailable, g.filters.used = true, true
	g.refilter()
	g.run(1) -- a player's update, not our own
	g.reader:TrainerUpdate()
	g.run(0.5)
	H.eq(#g.readings, 2) H.eq(g.calls.set, 0, "nothing to switch") H.ok(g.readings[2].r.t[2330])
end)

H.test("NpcReader trainer: the selected service is selected again by what it is, not by index", function()
	local g = newGame()
	kray(g)
	-- the player sees "used" and "available" with Elixir of Fire Power selected (index 3); the
	-- hidden Minor Healing Potion moves it to index 4 while every filter is on
	g.all[2].type = "unavailable"
	g.filters.used = true
	g.refilter()
	g.sel = 3 -- header, Minor Mana Potion, Elixir of Fire Power, Elixir of Greater Defense
	local want = g.services[3]
	H.eq(want.name, "Elixir of Fire Power")
	openTrainer(g)
	g.run(0.5)
	H.eq(#g.readings, 1) H.ok(g.readings[1].r.t[2330], "the hidden one read too")
	H.eq(selected(g), want, "same service selected")
	H.eq(g.sel, 3)
	H.eq(g.filters.unavailable, false) H.eq(g.filters.used, true) H.eq(g.filters.available, true)
	-- nothing selected before: nothing selected after (the player learns Elixir of Greater Defense)
	g.sel = 0
	g.all[5].type = "used"
	g.refilter()
	g.run(1)
	g.reader:TrainerUpdate()
	g.run(0.5)
	H.eq(#g.readings, 2) H.eq(g.sel, 0, "no selection made up") H.eq(g.calls.select, 1)
	-- a selection the restored list no longer holds by name: its index again (the player can
	-- learn Minor Healing Potion now: it shows)
	g.all[2].type = "used"
	g.refilter()
	g.sel = 2
	local name = g.services[2].name
	local info = g.api.serviceInfo
	local renamed = false
	g.api.serviceInfo = function(i)
		local n, k = info(i)
		if renamed and n == name then n = name .. " (new)" end
		return n, k, 134835, 0, "", "Elixirs"
	end
	local set = g.api.setTrainerFilter
	g.api.setTrainerFilter = function(kind, on) set(kind, on) renamed = true end
	g.run(1)
	g.reader:TrainerUpdate()
	g.run(0.5)
	H.eq(g.sel, 2, "fallback to the index")
end)

H.test("NpcReader trainer: our own filter switching does not read again", function()
	local g = newGame()
	kray(g)
	openTrainer(g)
	g.run(0.5)
	H.eq(#g.readings, 1) H.ok(g.updates > 0, "the fake fired TRAINER_UPDATE")
	g.run(10)
	H.eq(#g.readings, 1, "no second read from our own TRAINER_UPDATE")
	H.eq(#g.timers, 0, "nothing scheduled")
	-- an update of the player's afterwards that changes the list reads again, once
	g.all[5].type = "used"
	g.refilter()
	g.reader:TrainerUpdate()
	g.run(10)
	H.eq(#g.readings, 2)
end)

H.test("NpcReader trainer: an error while reading still puts the filters and selection back", function()
	local g = newGame()
	kray(g)
	g.sel = 2
	local want = g.services[2]
	local skill = g.api.serviceSkill
	g.api.serviceSkill = function(i)
		if g.filters.used then error("boom") end
		return skill(i)
	end
	openTrainer(g)
	local ok = pcall(g.run, 0.5)
	H.eq(ok, false, "the error goes on to the caller (Bugs)")
	H.eq(g.filters.available, true) H.eq(g.filters.unavailable, false) H.eq(g.filters.used, false)
	H.eq(selected(g), want, "selection back")
	H.eq(#g.readings, 0)
	H.eq(g.reader.own, false, "the guard is cleared")
end)

-- A client whose TRAINER_UPDATE from our switching comes a frame later, after a frame that took
-- longer than any time window (GetTime only moves between frames): still one reading.
H.test("NpcReader trainer: our own update a slow frame later does not read again", function()
	local g = newGame()
	kray(g)
	g.api.setTrainerFilter = function(kind, on)
		g.calls.set = g.calls.set + 1
		g.filters[kind] = on
		g.refilter()
		g.api.after(0.25, function() g.reader:TrainerUpdate() end)
	end
	g.reader:TrainerShow()
	g.run(10)
	H.eq(#g.readings, 1, "one reading, no loop")
	H.eq(g.calls.set, 4, "switched on and back once")
	-- a player's update that changes nothing: nothing read, nothing switched
	g.reader:TrainerUpdate()
	g.run(10)
	H.eq(#g.readings, 1) H.eq(g.calls.set, 4)
	-- the player learns Elixir of Greater Defense: it leaves the list, read again once
	g.all[5].type = "used"
	g.refilter()
	g.reader:TrainerUpdate()
	g.run(10)
	H.eq(#g.readings, 2, "a real change is read, once") H.eq(g.calls.set, 8)
	H.eq(g.readings[2].r.t[11450].copper, 9000)
	-- a new visit reads again
	g.reader:TrainerClosed()
	g.reader:TrainerShow()
	g.run(10)
	H.eq(#g.readings, 3)
end)

H.test("NpcReader trainer: a filter the client left changed is set back as it was", function()
	-- the switch of "used" takes effect and then throws
	local g = newGame()
	kray(g)
	local set = g.api.setTrainerFilter
	g.api.setTrainerFilter = function(kind, on)
		set(kind, on)
		if kind == "used" and on then error("refused") end
	end
	openTrainer(g)
	g.run(1)
	H.eq(g.filters.available, true) H.eq(g.filters.unavailable, false) H.eq(g.filters.used, false)
	-- switching "unavailable" off also switches "used" off, which was on
	g = newGame()
	kray(g)
	g.filters.used = true
	g.refilter()
	set = g.api.setTrainerFilter
	g.api.setTrainerFilter = function(kind, on)
		set(kind, on)
		if kind == "unavailable" and not on then g.filters.used = false g.refilter() end
	end
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 1) H.ok(g.readings[1].r.t[2330])
	H.eq(g.filters.available, true) H.eq(g.filters.unavailable, false) H.eq(g.filters.used, true)
end)

H.test("NpcReader trainer: of two identical services the one nearest the old index is selected", function()
	local g = newGame()
	kray(g)
	g.all[#g.all + 1] = { name = "Elixir of Greater Defense", prof = "Alchemy", skill = 195, copper = 9000, type = "available" }
	g.refilter()
	g.sel = 3 -- header, Elixir of Greater Defense, Elixir of Greater Defense
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 1)
	H.eq(g.sel, 3, "the second one again")
end)

H.test("NpcReader trainer: filter API missing, or a filter call fails: the visible list as before", function()
	for _, missing in ipairs({ "trainerFilter", "setTrainerFilter", "trainerSelection", "selectService" }) do
		local g = newGame()
		kray(g)
		g.api[missing] = nil
		openTrainer(g)
		g.run(0.5)
		H.eq(#g.readings, 1, missing)
		local t = g.readings[1].r.t
		H.ok(t[11450], missing) H.eq(t[2330], nil, "visible only: " .. missing)
		H.eq(g.calls.set, 0, "nothing switched: " .. missing)
	end
	-- the client refuses the switch
	local g = newGame()
	kray(g)
	g.setError = "Missing on/off parameter"
	openTrainer(g)
	g.run(0.5)
	H.eq(#g.readings, 1) H.eq(g.readings[1].r.t[2330], nil) H.ok(g.readings[1].r.t[11450])
	H.eq(g.filters.used, false)
	-- the second switch fails: the first is put back, the visible list read
	g = newGame()
	kray(g)
	local set = g.api.setTrainerFilter
	local n = 0
	g.api.setTrainerFilter = function(kind, on)
		n = n + 1
		if n == 2 then error("refused") end
		set(kind, on)
	end
	openTrainer(g)
	g.run(0.5)
	H.eq(g.filters.unavailable, false) H.eq(g.filters.used, false) H.eq(g.filters.available, true)
	H.eq(#g.readings, 1) H.eq(g.readings[1].r.t[2330], nil)
	-- a secret filter value: not switched
	g = newGame()
	kray(g)
	g.filters.used = SECRET
	openTrainer(g)
	g.run(0.5)
	H.eq(g.calls.set, 0) H.eq(#g.readings, 1) H.ok(g.readings[1].r.t[11450])
end)

H.test("NpcReader trainer: in combat no filter is touched", function()
	local g = newGame()
	kray(g)
	g.combat = true
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 0) H.eq(g.calls.set, 0) H.eq(g.calls.get, 0) H.eq(g.calls.select, 0)
	-- combat starts between the show and the read
	g = newGame()
	kray(g)
	openTrainer(g)
	g.combat = true
	g.run(1)
	H.eq(#g.readings, 0) H.eq(g.calls.set, 0) H.eq(g.calls.get, 0)
	-- after combat the window is read whole
	g.combat = false
	g.reader:CombatEnded()
	g.run(1)
	H.eq(#g.readings, 1) H.ok(g.readings[1].r.t[2330]) H.eq(g.filters.used, false)
end)

-- Merchant --------------------------------------------------------------------

local function item(id, price, o)
	o = o or {}
	return { id = id, info = { name = o.noName and nil or ("Item " .. id), price = price, stackCount = 1,
		numAvailable = o.stock or -1, isPurchasable = true, isUsable = true, hasExtendedCost = o.costs ~= nil,
		texture = 134939 }, costs = o.costs }
end

-- Nata Dawnstrider: Enchanting formulae (class 9) among reagents.
local function nata(g)
	g.guid, g.name = NATA, "Nata Dawnstrider"
	g.items = { item(6217, 124), item(6377, 900), item(6349, 450, { noName = true }), item(22307, 5400) }
	g.classes = { [6217] = 7, [6377] = 9, [6349] = 9, [22307] = 9 }
end

local function openMerchant(g)
	g.reader:MerchantShow()
	g.reader:MerchantUpdate()
end

H.test("NpcReader merchant: recipes by class 9 or Data.lua, all entries by index", function()
	local g = newGame()
	nata(g)
	g.items[5] = item(5000, 300)
	g.classes[5000] = 15
	g.data[5000] = true -- Data.lua has it as a recipe item
	openMerchant(g)
	H.eq(#g.readings, 0)
	g.run(0.5)
	H.eq(#g.readings, 1)
	local r = g.readings[1]
	H.eq(r.id, 3012) H.eq(r.r.name, "Nata Dawnstrider") H.eq(r.r.x, 47) H.eq(next(r.r.t), nil)
	H.eq(r.r.v[6217], nil, "a reagent is not a recipe")
	H.eq(r.r.v[6377].price.c, 900) H.eq(r.r.v[6377].price.l, 0) H.eq(#r.r.v[6377].price.o, 0)
	H.eq(r.r.v[6349].price.c, 450, "the name may be absent")
	H.eq(r.r.v[5000].price.c, 300, "Data.lua item")
end)

H.test("NpcReader merchant: limited stock and three other costs", function()
	local g = newGame()
	nata(g)
	g.items = {
		item(6377, 900, { stock = 2 }),
		item(6349, 0, { costs = {
			{ count = 30, link = "|cff0070dd|Hitem:20725::::::::60:::::|h[Nexus Crystal]|h|r", name = "Nexus Crystal" },
			{ count = 2, link = "|cffffffff|Hcurrency:1792:0|h[Honor]|h|r", name = "Honor" },
			{ count = 5, link = "|Hitem:20724|h[Shard]|h", name = "Shard" },
		} }),
		item(22307, 5400, { stock = 0 }),
	}
	openMerchant(g)
	g.run(0.5)
	local v = g.readings[1].r.v
	H.eq(v[6377].price.l, 1, "limited") H.eq(v[22307].price.l, 1, "sold out is limited too")
	local o = v[6349].price.o
	H.eq(#o, 3) H.eq(v[6349].price.c, 0)
	H.eq(o[1][1], 1) H.eq(o[1][2], 1792) H.eq(o[1][3], 2, "currency first")
	H.eq(o[2][2], 20724) H.eq(o[2][3], 5) H.eq(o[3][1], 2) H.eq(o[3][2], 20725) H.eq(o[3][3], 30)
end)

H.test("NpcReader merchant: a missing item ID is read again after 1 s, at most 5 times", function()
	local g = newGame()
	nata(g)
	local real = g.items[3]
	g.items[3] = { info = real.info } -- no ID yet
	openMerchant(g)
	g.run(0.5)
	H.eq(#g.readings, 0, "waits for the ID")
	g.run(1)
	H.eq(#g.readings, 0)
	g.items[3] = real
	g.run(1)
	H.eq(#g.readings, 1, "complete") H.eq(g.readings[1].r.v[6349].price.c, 450)
	-- never arrives: after 5 retries the rest without that entry
	g = newGame()
	nata(g)
	g.items[3] = { info = g.items[3].info }
	openMerchant(g)
	g.run(0.5 + 4)
	H.eq(#g.readings, 0, "4 retries")
	g.run(1)
	H.eq(#g.readings, 1, "the 5th retry gives up") H.eq(g.calls.numItems, 6)
	H.eq(g.readings[1].r.v[6377].price.c, 900) H.eq(g.readings[1].r.v[6349], nil)
	g.run(10)
	H.eq(#g.readings, 1, "no more")
	-- closed while waiting: nothing
	g = newGame()
	nata(g)
	g.items[3] = { info = g.items[3].info }
	openMerchant(g)
	g.run(1)
	g.reader:MerchantClosed()
	g.run(10)
	H.eq(#g.readings, 0, "closed while waiting")
end)

H.test("NpcReader merchant: an unknown cost ID likewise, the entry never in part", function()
	local g = newGame()
	nata(g)
	local cost = { count = 2, link = nil, name = "Honor" }
	g.items[4] = item(22307, 5400, { costs = { cost } })
	openMerchant(g)
	g.run(0.5 + 5)
	H.eq(#g.readings, 1)
	H.eq(g.readings[1].r.v[22307], nil, "not even seen") H.eq(g.readings[1].r.v[6377].price.c, 900)
	g = newGame()
	nata(g)
	cost = { count = 2, link = "", name = "Honor" }
	g.items[4] = item(22307, 5400, { costs = { cost } })
	openMerchant(g)
	g.run(1.5)
	cost.link = "|Hcurrency:1792|h[Honor]|h"
	g.run(1)
	H.eq(#g.readings, 1) H.eq(g.readings[1].r.v[22307].price.o[1][2], 1792)
end)

H.test("NpcReader merchant: two different entries of one item are seen only", function()
	local g = newGame()
	nata(g)
	g.items[5] = item(6377, 800)
	g.items[6] = item(6349, 450)
	openMerchant(g)
	g.run(0.5)
	local v = g.readings[1].r.v
	H.ok(v[6377] ~= nil, "seen") H.eq(v[6377].price, nil, "price unknown")
	H.eq(v[6349].price.c, 450, "equal entries: one price")
end)

H.test("NpcReader merchant: no recipe, combat or a secret value: no reading", function()
	local g = newGame()
	nata(g)
	g.items = { item(6217, 124) }
	openMerchant(g)
	g.run(1)
	H.eq(#g.readings, 0, "no recipe")
	g = newGame()
	nata(g)
	g.combat = true
	openMerchant(g)
	g.run(1)
	H.eq(#g.readings, 0, "combat")
	g = newGame()
	nata(g)
	g.items[2].info.price = SECRET
	openMerchant(g)
	g.run(1)
	H.eq(#g.readings, 0, "secret price")
	g = newGame()
	nata(g)
	openMerchant(g)
	g.guid, g.name = MANI, "Mani Winterhoof"
	g.run(1)
	H.eq(#g.readings, 0, "other NPC at the timer")
end)

-- In the addon ------------------------------------------------------------------

H.test("NpcReader in Core: trainer events give a reading, recipeInfo.m as today", function()
	M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M
	M.install()
	ProfguildDB = nil
	local ans = {}
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			assert(loadfile(H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")))("Profguild", ans)
		end
	end
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	ans.catalog:Add(197, { [3865] = 4305 })
	local guid = UnitGUID
	UnitGUID = function(unit) if unit == "npc" then return BENA end return guid(unit) end
	UnitName = function(unit) if unit == "npc" then return "Bena Winterhoof" end return "Frost" end
	C_Map = { GetBestMapForUnit = function() return 1456 end,
		GetPlayerMapPosition = function() return { x = 0.473, y = 0.339, GetXY = function(p) return p.x, p.y end } end }
	IsTradeskillTrainer = function() return true end
	GetNumTrainerServices = function() return 2 end
	GetTrainerServiceInfo = function(i) if i == 1 then return "Recipe 3865", "available", 134835, 0, "", "Cloth" end return "Tailoring", "header" end
	GetTrainerServiceSkillReq = function(i) return "Tailoring", i == 1 and 125 or 0, true end
	GetTrainerServiceCost = function() return 500 end
	local got
	ans.npcReader.onReading = function(id, r) got = { id = id, r = r } end
	M.fire("TRAINER_SHOW")
	M.advance(1)
	H.eq(ProfguildDB.recipeInfo[3865].m, 125, "skill kept as today")
	H.ok(got, "a reading") H.eq(got.id, 3009) H.eq(got.r.t[3865].skill, 125) H.eq(got.r.t[3865].copper, 500)
	H.eq(got.r.map, 1456) H.eq(got.r.x, 47) H.eq(got.r.y, 33) H.eq(got.r.name, "Bena Winterhoof")
	M.fire("TRAINER_CLOSED")
	-- a vendor
	got = nil
	UnitGUID = function(unit) if unit == "npc" then return NATA end return guid(unit) end
	GetMerchantNumItems = function() return 2 end
	GetMerchantItemID = function(i) return i == 1 and 6377 or 6217 end
	C_MerchantFrame = { GetItemInfo = function(i) return { price = i == 1 and 900 or 124, stackCount = 1, numAvailable = -1, hasExtendedCost = false, isPurchasable = true } end }
	GetMerchantItemCostInfo = function() return 0 end
	GetItemInfoInstant = function(id) return id, id == 6377 and "Recipe" or "Trade Goods", "", "", 0, id == 6377 and 9 or 7, 0 end
	M.fire("MERCHANT_SHOW")
	M.advance(1)
	H.ok(got, "a vendor reading") H.eq(got.id, 3012) H.eq(got.r.v[6377].price.c, 900) H.eq(got.r.v[6217], nil)
	M.fire("MERCHANT_CLOSED")
	UnitGUID = guid
	C_Map, IsTradeskillTrainer, GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceSkillReq, GetTrainerServiceCost = nil, nil, nil, nil, nil, nil
	GetMerchantNumItems, GetMerchantItemID, C_MerchantFrame, GetMerchantItemCostInfo, GetItemInfoInstant = nil, nil, nil, nil, nil
end)

H.test("NpcReader bounds (mutation check): grey equal to the skill, 0.5 s, the largest NPC ID, four costs", function()
	local recipes = { { id = 11, name = "A", line = 171, item = 901, grey = 100 }, { id = 12, name = "A", line = 171, item = 902, grey = 99 } }
	local t = R.Match({ svc("A", 100, 5) }, recipes)
	H.ok(t[11], "a grey equal to the skill fits in step 4") H.eq(t[11] and t[11].skill, 100, "and the skill is kept")

	local g = newGame()
	alchemy(g)
	openTrainer(g)
	g.run(0.45)
	H.eq(#g.readings, 0, "not read before 0.5 s")
	g.run(0.05)
	H.eq(#g.readings, 1, "read at 0.5 s")

	for _, case in ipairs({ { "2147483647", 1 }, { "2147483648", 0 } }) do
		g = newGame()
		alchemy(g)
		g.guid = "Creature-0-55165-1-15571149-" .. case[1] .. "-DB04E5BC4A"
		openTrainer(g)
		g.run(1)
		H.eq(#g.readings, case[2], "NPC ID " .. case[1])
	end

	g = newGame()
	nata(g)
	local costs = {}
	for i = 1, 4 do costs[i] = { count = i, link = "|Hitem:" .. (20720 + i) .. "|h[Shard]|h", name = "Shard" } end
	g.items = { item(6377, 900, { costs = costs }) }
	openMerchant(g)
	g.run(0.5)
	H.eq(g.readings[1].r.v[6377].price, nil, "four other costs: seen only")
end)

H.test("NpcReader: a window opened or due in combat is read when combat ends, if still open", function()
	-- trainer opened in combat
	local g = newGame()
	alchemy(g)
	g.combat = true
	openTrainer(g)
	g.run(1)
	H.eq(#g.readings, 0, "nothing in combat")
	g.combat = false
	g.reader:CombatEnded()
	g.run(1)
	H.eq(#g.readings, 1, "read after combat")
	g.reader:CombatEnded()
	g.run(1)
	H.eq(#g.readings, 1, "once")
	-- combat began between the show and the read
	g = newGame()
	alchemy(g)
	openTrainer(g)
	g.combat = true
	g.run(1)
	H.eq(#g.readings, 0)
	g.reader:CombatEnded()
	g.run(1)
	H.eq(#g.readings, 0, "still in combat: nothing")
	g.combat = false
	g.reader:CombatEnded()
	g.run(1)
	H.eq(#g.readings, 1, "read after combat")
	-- closed in combat: nothing
	g = newGame()
	alchemy(g)
	g.combat = true
	openTrainer(g)
	g.reader:TrainerClosed()
	g.combat = false
	g.reader:CombatEnded()
	g.run(1)
	H.eq(#g.readings, 0, "closed meanwhile")
	-- merchant
	g = newGame()
	nata(g)
	g.combat = true
	openMerchant(g)
	g.run(1)
	g.combat = false
	g.reader:CombatEnded()
	g.run(2)
	H.eq(#g.readings, 1, "merchant read after combat")
	g = newGame()
	nata(g)
	g.combat = true
	openMerchant(g)
	g.reader:MerchantClosed()
	g.combat = false
	g.reader:CombatEnded()
	g.run(2)
	H.eq(#g.readings, 0, "merchant closed meanwhile")
end)
