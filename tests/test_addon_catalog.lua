-- The recipe catalog filled from Data.lua (ns.SeedCatalog), the recipes of Data.lua itself, and the
-- recipe search of NEW REQUEST, which lists recipes nobody in the guild knows too.
local H = ...
M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M

local ME, ANA = "Player-1-00000001", "Player-1-00000002"
local BS, TAILORING, ENCHANTING = 164, 197, 333

local function loadAddon(data)
	M.install()
	local ns = {}
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			assert(loadfile(H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")))("Profguild", ns)
		end
	end
	ns.RecipeData = data or {}
	return ns
end

-- game: { [recipeID] = { skill line, item made or nil } }, the recipes the fake game knows.
-- Returns a table that counts the recipes the game was asked for.
local function setGame(game)
	local asked = { total = 0 }
	C_TradeSkillUI.GetRecipeSchematic = function(id)
		asked.total = asked.total + 1
		return game[id] and { outputItemID = game[id][2] } or nil
	end
	C_TradeSkillUI.GetTradeSkillLineForRecipe = function(id)
		if game[id] then return game[id][1], "x", nil end
	end
	return asked
end

-- n recipes of a profession from id `first`, for Data.lua and for the fake game.
local function recipes(data, game, line, first, n)
	for id = first, first + n - 1 do
		data[id] = { false, "", 0, 1, 2, line }
		game[id] = { line, id + 100000 }
	end
end

-- The addon with the given recipes, signed in, 8 seconds later (before the fill of the login).
local function login(data, game, saved)
	ProfguildDB = saved
	Auctionator = nil
	local ns = loadAddon(data)
	local asked = setGame(game)
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	return ns, asked
end

-- The first message of a type sent after M.sent had `from` messages.
local function sentOfType(ns, from, t)
	for i = from + 1, #M.sent do
		local msg = ns.Comm.Decode(M.sent[i].text)
		if msg and msg.t == t then return msg end
	end
end

local function ids(rows)
	local out = {}
	for _, r in ipairs(rows) do out[#out + 1] = r.recipeID end
	return table.concat(out, ",")
end

---------------------------------------------------------------------------
-- Data.lua
---------------------------------------------------------------------------

H.test("recipe data: every recipe has a crafting skill line and valid fields", function()
	local ns = H.newNamespace({ "Catalog.lua", "Data.lua" })
	local lines = { [164] = 0, [165] = 0, [171] = 0, [185] = 0, [186] = 0, [197] = 0, [202] = 0, [129] = 0, [333] = 0 }
	local function whole(v) return type(v) == "number" and v >= 0 and v == math.floor(v) end
	for id, e in pairs(ns.RecipeData) do
		local at = "recipe " .. tostring(id)
		H.ok(whole(id) and id > 0, at)
		H.eq(#e, 6, at .. " fields")
		H.ok(e[1] == false or (whole(e[1]) and e[1] > 0), at .. " recipe item")
		H.ok(type(e[2]) == "string" and not e[2]:find("[^dvqc]"), at .. " source")
		H.ok(whole(e[3]) and whole(e[4]) and whole(e[5]), at .. " skill levels")
		H.ok(lines[e[6]], at .. " skill line " .. tostring(e[6]))
		lines[e[6]] = lines[e[6]] + 1
	end
	for line, n in pairs(lines) do
		H.ok(n >= 20, "too few recipes of skill line " .. line .. ": " .. n)
		H.ok(n <= ns.Catalog.MAX_PER_PROFESSION, "does not fit the catalog: " .. line)
	end
end)

H.test("recipe data: known recipes are in their profession", function()
	local ns = H.newNamespace({ "Data.lua" })
	-- Rough Sharpening Stone, Handstitched Leather Boots, Minor Healing Potion, Charred Wolf Meat,
	-- Smelt Copper, Bolt of Linen Cloth, Rough Blasting Powder, Linen Bandage, Enchant Bracer
	for id, line in pairs({ [2660] = 164, [2149] = 165, [2330] = 171, [2538] = 185, [2657] = 186, [2963] = 197,
		[3918] = 202, [3275] = 129, [7418] = 333 }) do
		H.ok(ns.RecipeData[id], "recipe " .. id .. " in Data.lua")
		H.eq(ns.RecipeData[id][6], line, "recipe " .. id)
	end
end)

H.test("recipe data: the whole Data.lua fills nine professions", function()
	local data = H.newNamespace({ "Data.lua" }).RecipeData
	local game, want = {}, {}
	for id, e in pairs(data) do
		game[id] = { e[6], 1 }
		want[e[6]] = (want[e[6]] or 0) + 1
	end
	local ns = login(data, game)
	M.advance(60)
	local professions = 0
	for line, n in pairs(want) do
		professions = professions + 1
		H.eq(ns.catalog:Count(line), n, "skill line " .. line)
	end
	H.eq(professions, 9)
end)

---------------------------------------------------------------------------
-- SeedCatalog
---------------------------------------------------------------------------

H.test("catalog fill: runs by itself 20 seconds after the login and is saved", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 10)
	local ns = login(data, game)
	M.advance(11) -- 19 s
	H.eq(ns.catalog:Count(BS), 0, "not before")
	M.advance(3)
	H.eq(ns.catalog:Count(BS), 10)
	H.eq(ProfguildDB.catalog[BS][1001], 101001, "saved, with the item the game says")
end)

H.test("catalog fill: a recipe without an item (an enchant) is kept", function()
	local ns = login({ [1001] = { false, "", 0, 1, 2, ENCHANTING } }, { [1001] = { ENCHANTING } })
	ns.SeedCatalog()
	H.eq(ns.catalog:Get(ENCHANTING)[1001], 0)
end)

H.test("catalog fill: recipes the game does not know are left out", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 3)
	game[1002] = nil
	local ns = login(data, game)
	ns.SeedCatalog()
	H.eq(ns.catalog:Count(BS), 2)
	H.eq(ns.catalog:Get(BS)[1002], nil)
end)

H.test("catalog fill: recipes the game puts in another profession are left out", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 3)
	game[1002][1] = ENCHANTING
	local ns = login(data, game)
	ns.SeedCatalog()
	H.eq(ns.catalog:Count(BS), 2)
	H.eq(ns.catalog:Get(BS)[1002], nil)
	H.eq(ns.catalog:Get(ENCHANTING), nil, "nor put there")
end)

H.test("catalog fill: when the game knows none, the profession stays out of the catalog", function()
	local data = {}
	recipes(data, {}, BS, 1001, 3)
	local ns = login(data, {})
	ns.SeedCatalog()
	H.eq(ns.catalog:Get(BS), nil)
	H.eq(ns.catalog:Digest()[BS], nil, "nothing announced to the guild")
end)

H.test("catalog fill: the game is asked in small steps, the list appears at once", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 130)
	local ns, asked = login(data, game)
	asked.total = 0
	ns.SeedCatalog()
	H.eq(asked.total, 50, "first step")
	H.eq(ns.catalog:Count(BS), 0, "nothing stored half done")
	M.advance(2)
	H.eq(asked.total, 130, "every recipe once")
	H.eq(ns.catalog:Count(BS), 130)
end)

for _, n in ipairs({ 1, 49, 50, 51, 100 }) do
	H.test("catalog fill: no recipe lost at the edge of a step: " .. n, function()
		local data, game = {}, {}
		recipes(data, game, BS, 1001, n)
		local ns = login(data, game)
		ns.SeedCatalog()
		M.advance(2)
		H.eq(ns.catalog:Count(BS), n)
	end)
end

H.test("catalog fill: several professions in one go", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 70)
	recipes(data, game, TAILORING, 2001, 40)
	local ns = login(data, game)
	ns.SeedCatalog()
	M.advance(2)
	H.eq(ns.catalog:Count(BS), 70); H.eq(ns.catalog:Count(TAILORING), 40)
end)

H.test("catalog fill: only recipes the catalog lacks are asked about and added", function()
	local data, game, list = {}, {}, {}
	recipes(data, game, BS, 1001, 10)
	for id = 1001, 1009 do list[id] = 7 end
	list[5555] = 8 -- only the window had it
	local ns, asked = login(data, game, { catalog = { [BS] = list } })
	asked.total = 0
	ns.SeedCatalog()
	H.eq(asked.total, 1)
	H.eq(ns.catalog:Count(BS), 11)
	H.eq(ns.catalog:Get(BS)[1001], 7, "an entry already there stays")
	H.eq(ns.catalog:Get(BS)[1010], 101010)
	H.eq(ns.catalog:Get(BS)[5555], 8)
end)

H.test("catalog fill: a list that broke off after two of three parts is completed", function()
	local data, game, list = {}, {}, {}
	recipes(data, game, TAILORING, 1001, 471)
	for id = 1001, 1400 do list[id] = 7 end
	local ns = login(data, game, { catalog = { [TAILORING] = list } })
	ns.SeedCatalog()
	M.advance(5)
	H.eq(ns.catalog:Count(TAILORING), 471)
end)

H.test("catalog fill: a list that came from the guild meanwhile is merged", function()
	local data, game, list = {}, {}, {}
	recipes(data, game, BS, 1001, 60)
	local ns = login(data, game)
	ns.SeedCatalog()
	for id = 1010, 1058 do list[id] = 7 end
	list[5555] = 8
	ns.catalog:Add(BS, list)
	M.advance(2)
	H.eq(ns.catalog:Count(BS), 61)
	H.eq(ns.catalog:Get(BS)[1010], 7, "the guild's entry stays")
end)

H.test("catalog fill: /pg catalog clear stops a fill that is running", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 200)
	local ns = login(data, game)
	ns.SeedCatalog()
	SlashCmdList.PROFGUILD("catalog clear")
	M.advance(5)
	H.eq(ns.catalog:Count(BS), 0)
	M.advance(20) -- the fill of the login
	H.eq(ns.catalog:Count(BS), 0, "nor does the one of the login bring it back")
end)

H.test("catalog fill: the steps are 0.1 seconds apart", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 130)
	local ns, asked = login(data, game)
	asked.total = 0
	ns.SeedCatalog()
	M.advance(0.08, 0.02)
	H.eq(asked.total, 50, "still the first step")
	M.advance(0.06, 0.02)
	H.eq(asked.total, 100, "second step")
	M.advance(0.12, 0.02)
	H.eq(asked.total, 130)
end)

H.test("catalog fill: filled clients with different lists end with the same one and stop asking", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 5)
	game[5555] = { BS, 8 }
	local ns = login(data, game)
	M.advance(20)
	local function digest(n)
		ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "KD", pv = ns.Catalog.PROTOCOL, s = ANA, d = { [BS] = n } }),
			"GUILD", "Ana Brightwood")
	end
	digest(6)
	M.advance(5)
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "KL", pv = ns.Catalog.PROTOCOL, s = ANA, l = BS, c = 6,
		r = { 1001, 1002, 1003, 1004, 1005, 5555 } }), "GUILD", "Ana Brightwood")
	H.eq(ns.catalog:Count(BS), 6)
	M.advance(130)
	local before = #M.sent
	digest(6)
	M.advance(5)
	H.eq(sentOfType(ns, before, "KR"), nil, "not asked again")
end)

H.test("catalog fill: running again changes nothing", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 60)
	local ns, asked = login(data, game)
	ns.SeedCatalog()
	M.advance(2)
	local revision = ns.catalog.revision
	asked.total = 0
	ns.SeedCatalog()
	M.advance(20) -- the one of the login too
	H.eq(ns.catalog:Count(BS), 60)
	H.eq(ns.catalog.revision, revision); H.eq(asked.total, 0)
end)

H.test("catalog fill: comes back on the next login after /pg catalog clear", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 5)
	local ns = login(data, game)
	M.advance(20)
	H.eq(ns.catalog:Count(BS), 5)
	SlashCmdList.PROFGUILD("catalog clear")
	H.eq(ns.catalog:Count(BS), 0)
	ns = login(data, game, ProfguildDB)
	M.advance(20)
	H.eq(ns.catalog:Count(BS), 5)
end)

H.test("catalog fill: damaged or old entries of the data are skipped", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 2)
	data[1003], data[1004] = false, { false, "", 0, 1, 2 } -- 1004 has no skill line
	game[1003], game[1004] = { BS, 1 }, { BS, 1 }
	local ns = login(data, game)
	ns.SeedCatalog()
	H.eq(ns.catalog:Count(BS), 2)
	ns = login({}, game)
	ns.RecipeData = nil
	ns.SeedCatalog()
	H.eq(ns.catalog:Count(BS), 0, "without data nothing happens")
end)

H.test("catalog fill: works without a guild", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 5)
	ProfguildDB = nil
	local ns = loadAddon(data)
	setGame(game)
	IsInGuild = function() return false end
	GetGuildInfo = function() end
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(30)
	H.eq(ns.guildKey, nil)
	H.eq(ns.catalog:Count(BS), 5)
end)

H.test("catalog fill: opening the window afterwards adds what the data lacks", function()
	local data, game = {}, {}
	recipes(data, game, TAILORING, 1001, 5)
	for _, id in ipairs({ 3865, 3866, 18560 }) do game[id] = { TAILORING, 4305 } end
	local ns = login(data, game)
	M.advance(20)
	H.eq(ns.catalog:Count(TAILORING), 5)
	M.fire("TRADE_SKILL_SHOW")
	M.advance(5)
	H.eq(ns.catalog:Count(TAILORING), 8)
end)

H.test("catalog fill: a guildmate with more recipes is still asked, one with less is not", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 5)
	local ns = login(data, game)
	M.advance(20)
	local function askedAfter(n)
		local before = #M.sent
		ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "KD", pv = ns.Catalog.PROTOCOL, s = ANA, d = { [BS] = n } }),
			"GUILD", "Ana Brightwood")
		M.advance(5)
		return sentOfType(ns, before, "KR") ~= nil
	end
	H.ok(not askedAfter(4), "less")
	H.ok(askedAfter(9), "more")
end)

H.test("catalog fill: the window lists the recipes under UNAVAILABLE and ALL, not under AVAILABLE", function()
	local data, game = {}, {}
	recipes(data, game, BS, 1001, 5)
	local ns = login(data, game)
	M.advance(20)
	local function listed(mode)
		ns.db.settings.recipeFilter = mode
		local _, counts = ns.UI:BuildRecipeRows("", nil)
		return counts[BS] or 0
	end
	H.eq(listed("unknown"), 5); H.eq(listed("all"), 5); H.eq(listed("known"), 0)
end)

---------------------------------------------------------------------------
-- NEW REQUEST: the recipe search
---------------------------------------------------------------------------

-- names: { [recipeID] = { name, crafters, item } }; crafters is a list of guids, nil when only
-- the catalog has the recipe. Returns the rows found and the addon.
local function search(names, query, setup)
	local ns = login({}, {})
	local index, list = {}, {}
	for id, r in pairs(names) do
		if r[2] then
			index[id] = { skillLine = BS, itemID = r[3] or 0, guids = r[2] }
		else
			list[id] = r[3] or 0
		end
	end
	ns.catalog:Add(BS, list)
	ns.store.Index = function() return { recipes = index } end
	C_Spell.GetSpellName = function(id) return names[id] and names[id][1] end
	if setup then setup(ns, index) end
	return ns.UI:FindRequestRecipes(query), ns
end

H.test("request search: finds known and unknown recipes", function()
	local rows = search({ [1] = { "Iron Axe", { ME } }, [2] = { "Iron Mace" }, [3] = { "Silk Robe" } }, "iron")
	H.eq(ids(rows), "1,2")
	H.eq(#rows[1].crafters, 1); H.eq(#rows[2].crafters, 0)
	H.eq(rows[2].skillLine, BS, "the row knows the profession")
end)

H.test("request search: a known recipe is first, equal names by id", function()
	local rows = search({ [1] = { "Big Iron Axe" }, [2] = { "Big Iron Axe" }, [3] = { "Old Iron Axe", { ME } } }, "iron")
	H.eq(ids(rows), "3,1,2")
end)

H.test("request search: the exact name is first even when nobody knows it", function()
	local rows = search({ [1] = { "Iron Axe" }, [2] = { "Iron Axe Handle", { ME } }, [3] = { "Big Iron Axe", { ME } } }, "iron axe")
	H.eq(ids(rows), "1,2,3")
end)

H.test("request search: a recipe in the catalog and known in the guild is one row", function()
	local rows = search({ [1] = { "Iron Axe", { ME } } }, "iron", function(ns) ns.catalog:Add(BS, { [1] = 777 }) end)
	H.eq(ids(rows), "1")
	H.eq(#rows[1].crafters, 1)
	H.eq(rows[1].itemID, 777, "the item comes from the catalog when the guild's record lacks it")
end)

H.test("request search: a recipe whose only crafter is inactive counts as known by nobody", function()
	local rows = search({ [1] = { "Iron Axe", { ANA } } }, "iron", function(ns)
		ns.store.IsStale = function(_, guid) return guid == ANA end
	end)
	H.eq(ids(rows), "1")
	H.eq(#rows[1].crafters, 0)
end)

H.test("request search: an offline crafter counts although ONLINE is on", function()
	local rows = search({ [1] = { "Iron Axe", { ANA } } }, "iron", function(ns)
		ns.db.settings.onlineOnly = true
		ns.store.IsOnline = function() return false end
	end)
	H.eq(#rows[1].crafters, 1)
end)

for _, mode in ipairs({ "known", "unknown", "all" }) do
	H.test("request search: the filters of the recipe list do not count: " .. mode, function()
		local rows = search({ [1] = { "Iron Axe", { ME } }, [2] = { "Iron Mace" } }, "iron", function(ns)
			ns.db.settings.recipeFilter = mode
			ns.UI.memberFilter = "Player-1-0000FFFF"
			ns.UI.category = TAILORING
		end)
		H.eq(ids(rows), "1,2")
		H.eq(#rows[1].crafters, 1)
	end)
end

H.test("request search: an unknown recipe is found by the name of its item", function()
	local rows = search({ [1] = { "Odd name", nil, 4242 } }, "item 4242")
	H.eq(ids(rows), "1")
	H.eq(rows[1].itemID, 4242)
end)

H.test("request search: case and outer spaces do not count, special characters are plain text", function()
	local names = { [1] = { "Iron Axe (x%d)" }, [2] = { "Iron Mace" } }
	H.eq(ids((search(names, "  IRON axe "))), "1")
	H.eq(ids((search(names, "(x%d"))), "1")
	H.eq(ids((search(names, "[%"))), "")
	H.eq(ids((search(names, ".."))), "")
end)

H.test("request search: fewer than two letters or no guild finds nothing", function()
	local names = { [1] = { "Iron Axe" } }
	for _, q in ipairs({ "", " ", "i", " i " }) do H.eq(#search(names, q), 0, "'" .. q .. "'") end
	local rows, ns = search(names, "iron")
	H.eq(#rows, 1)
	H.eq(#ns.UI:FindRequestRecipes(nil), 0)
	ns.store = nil
	H.eq(#ns.UI:FindRequestRecipes("iron"), 0)
end)

local function openBox(names, query)
	local _, ns = search(names, query)
	ns.UI:Toggle()
	ns.UI:SetView("requests")
	ns.UI.newRequestButton._scripts.OnClick(ns.UI.newRequestButton)
	ns.UI.requestBox.search:SetText(query)
	ns.UI:DrawRequestPicks()
	return ns, ns.UI.requestBox
end

H.test("request box: says who can craft it, or that nobody knows it", function()
	local ns, box = openBox({ [1] = { "Iron Axe", { ME } }, [2] = { "Iron Mace" } }, "iron")
	H.eq(box.picks[1].count:GetText(), ns.T("REQ_PICK_CRAFTERS", 1))
	H.eq(box.picks[2].count:GetText(), ns.T("REQ_PICK_NOBODY"))
	H.ok(not box.picks[3]:IsShown())
end)

H.test("request box: without a match it says so", function()
	local ns, box = openBox({ [1] = { "Iron Axe" } }, "zzz")
	H.eq(box.pickNote:GetText(), ns.T("REQ_BOX_NONE")); H.ok(box.pickNote:IsShown())
end)

H.test("request box: a recipe nobody knows is asked for, sent and listed", function()
	local ns, box = openBox({ [1] = { "Iron Axe", nil, 4242 } }, "iron")
	local before = #M.sent
	box.picks[1]._scripts.OnClick(box.picks[1])
	box.count:SetText("2")
	box.saveButton._scripts.OnClick(box.saveButton)
	local rec = ns.requests:All()[1]
	H.ok(rec, "created")
	H.eq(rec.r, 1); H.eq(rec.i, 4242); H.eq(rec.n, 2); H.eq(rec.st, "open")
	M.advance(3)
	local sent = sentOfType(ns, before, "TU")
	H.ok(sent and sent.q[1].r == 1, "sent to the guild")
	local rows, counts = ns.UI:BuildRequestRows("", nil)
	H.eq(#rows, 1); H.ok(rows[1].nobody, "marked as known by nobody")
	H.eq(rows[1].skillLine, BS, "under its profession"); H.eq(counts[BS], 1)
end)

H.test("request box: an open search shows recipes that arrive meanwhile", function()
	local names = { [1] = { "Iron Axe" }, [2] = { "Iron Mace", {} } }
	local ns, box = openBox({ [1] = names[1] }, "iron")
	H.ok(not box.picks[2]:IsShown(), "one so far")
	C_Spell.GetSpellName = function(id) return names[id] and names[id][1] end
	ns.catalog:Add(BS, { [2] = 0 })
	M.advance(5)
	H.ok(box.picks[2]:IsShown(), "the new one too")
end)

H.test("request box: typing searches at most once per 0.15 seconds", function()
	local ns, box = openBox({ [1] = { "Iron Axe" } }, "iron")
	local searches, real = 0, ns.UI.FindRequestRecipes
	ns.UI.FindRequestRecipes = function(...) searches = searches + 1 return real(...) end
	for _ = 1, 5 do
		box.search._scripts.OnTextChanged(box.search, true)
		M.advance(0.02, 0.02)
	end
	H.eq(searches, 0, "waits")
	M.advance(0.2, 0.02)
	H.eq(searches, 1, "one search for five letters")
	box.search._scripts.OnTextChanged(box.search, true)
	M.advance(0.2, 0.02)
	H.eq(searches, 2, "the next letter searches again")
end)

H.test("request box: Enter takes the first match of the text just typed", function()
	local ns, box = openBox({ [1] = { "Iron Axe" }, [2] = { "Silk Robe" } }, "iron")
	box.search._text = "silk"
	box.search._scripts.OnTextChanged(box.search, true)
	box.search._scripts.OnEnterPressed(box.search)
	H.eq(ns.UI.requestRecipe.recipeID, 2)
end)

H.test("request search: 2500 recipes do not freeze the game", function()
	local names = {}
	for id = 1, 2500 do names[id] = { "Recipe number " .. id } end
	local _, ns = search(names, "recipe")
	local start = os.clock()
	local rows = ns.UI:FindRequestRecipes("recipe")
	local took = os.clock() - start
	H.eq(#rows, 2500)
	H.ok(took < 2, "took " .. took)
end)
