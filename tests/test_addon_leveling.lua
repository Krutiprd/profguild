-- The leveling guide in the addon: its input from prices, recipes, the guild store and the NPC
-- tables (UI:LevelingInput), and the LEVELING tab drawing it.
local H = ...
M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M

local function loadAddon()
	M.install()
	local ns = {}
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			assert(loadfile(H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")))("Profguild", ns)
		end
	end
	return ns
end

local TAILORING = 197
local ANA = "Player-1-00000002"
-- recipes of the test: id -> { recipe item or false (trainer), letters, learn, yellow, grey }, product
local R = {
	[50001] = { data = { false, "", 1, 240, 270 }, item = 60001 },   -- trainer, the player knows it
	[50002] = { data = { false, "", 100, 245, 290 }, item = 60002 }, -- trainer, learn 100
	[50003] = { data = { false, "", 130, 255, 300 }, item = 60003 }, -- trainer, learn 130, a trainer seen
	[50004] = { data = { 80004, "v", 150, 260, 310 }, item = 60004 }, -- recipe item, AH and a vendor
	[50005] = { data = { false, "", 200, 265, 320 }, item = 60005 }, -- trainer, none seen: no source
	[50006] = { data = { false, "", 1, 240, 270 }, item = 60006 },   -- a reagent without a price
	[50007] = { data = { false, "", 1, 240, 270 }, item = 60007 },   -- no reagents known
	[50008] = { item = 60008 },                                      -- no skill numbers
}
local REAGENT, NOPRICE = 70001, 70002

local function plain(text) return ((text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function receiveNU(ns, npcID, reading)
	local NpcData = ns.NpcData
	local today = math.floor(GetServerTime() / 86400)
	local s = NpcData.Visit(nil, reading, today)
	local msg = { t = "NU", pv = NpcData.PROTOCOL, e = NpcData.EPOCH, f = "Alliance",
		s = ANA, h = 12345, x = { NpcData.Pack(npcID, s) } }
	ns.Comm:OnCommReceived("ProfguildNPC", ns.Comm.Encode(msg), "GUILD", "Ana")
end

-- prices: { [itemID] = copper } on the AH; avail: { [itemID] = pieces }; sell: vendor sell prices
local function auctionator(prices, avail)
	local db = {}
	for id, n in pairs(avail or {}) do db[tostring(id)] = { a = { ["10"] = n } } end
	_G.Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function(_, id) return prices[id] end,
		GetAuctionAgeByItemID = function() return 0 end,
		GetVendorPriceByItemID = function() end,
	} }, Database = { db = db } }
end

local SELL = { [60001] = 50, [60002] = 40 }

-- Logged in (Frost: Tailoring 250), the test recipes in the catalog with reagents and prices.
local function boot(opts)
	opts = opts or {}
	ProfguildDB = nil
	_G.Auctionator = nil
	local ns = loadAddon()
	_G.UnitFactionGroup = function() return "Alliance", "Alliance" end
	local realInfo = C_Item.GetItemInfo
	C_Item.GetItemInfo = function(id)
		if SELL[id] then return "Item " .. id, "link", 1, 1, 1, "", "", 1, "", 0, SELL[id] end
		return realInfo(id)
	end
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	ns.Comm.blocked = {}
	local list = {}
	for id, e in pairs(R) do
		list[id] = e.item
		ns.RecipeData[id] = e.data
		if id ~= 50007 then ns.reagents:Set(id, { [REAGENT] = 2 }) end
	end
	ns.reagents:Set(50006, { [REAGENT] = 1, [NOPRICE] = 1 })
	ns.catalog:Add(TAILORING, list)
	local own = ns.OwnState()
	own.recipes = own.recipes or {}
	own.recipes[TAILORING] = { [50001] = 60001, [50006] = 60006 }
	if not opts.noPrices then
		auctionator({ [REAGENT] = 100, [60001] = 1000, [80004] = 7000 }, { [60001] = 3 })
	end
	return ns
end

local function byID(recipes)
	local t = {}
	for _, r in ipairs(recipes) do t[r.id] = r end
	return t
end

local function memberRecord(profs, t)
	return { g = ANA, v = 5, n = "Ana", c = "PRIEST", t = t or GetServerTime(), p = profs }
end

H.test("leveling input: the player's skill and exactly the recipes the player knows", function()
	local ns = boot()
	local recipes, start, missing = ns.UI:LevelingInput(TAILORING)
	H.eq(start, 250, "the player's skill")
	local r = byID(recipes)
	H.ok(r[50001] and r[50001].known, "known")
	for _, id in ipairs({ 50002, 50003, 50004, 50005 }) do H.ok(r[id] and not r[id].known, "unknown " .. id) end
	H.eq(r[50006], nil, "a reagent without a price: left out")
	H.eq(r[50007], nil, "no reagents: left out")
	H.eq(r[50008], nil, "no skill numbers: left out")
	H.eq(missing, 2, "two recipes without prices")
	-- numbers of the recipe
	H.eq(r[50002].learn, 100); H.eq(r[50002].yellow, 245); H.eq(r[50002].grey, 290)
	H.eq(r[50001].name, "Recipe 50001")
	H.eq(r[50001].itemID, 60001)
	_G.Auctionator = nil
end)

H.test("leveling input: cost from the reagents, value after the cut, the market and the vendor", function()
	local ns = boot()
	local r = byID((ns.UI:LevelingInput(TAILORING)))
	H.eq(r[50001].cost, 200, "2 x 100")
	H.eq(r[50001].ah, 950, "1000 minus 5 %")
	H.eq(r[50001].avail, 3)
	H.eq(r[50001].vendor, 50)
	H.eq(r[50002].ah, nil, "not on the AH")
	H.eq(r[50002].vendor, 40, "the vendor's sell price")
	H.eq(r[50003].ah, nil); H.eq(r[50003].vendor, nil, "no value at all")
	_G.Auctionator = nil
end)

H.test("leveling input: a guild member's skill and recipes; stale or without the profession: nobody's recipes", function()
	local ns = boot()
	ns.store:Apply(memberRecord({ [TAILORING] = { s = 120, m = 150, k = true, r = { [50003] = 60003 } } }))
	local recipes, start = ns.UI:LevelingInput(TAILORING, ANA)
	H.eq(start, 120)
	local r = byID(recipes)
	H.ok(r[50003].known, "Ana's recipe")
	H.ok(not r[50001].known, "the player's recipe is not Ana's")
	-- stale: her skill, nobody's recipes (trainer recipes below 120 learned)
	local isStale = ns.store.IsStale
	ns.store.IsStale = function() return true end
	recipes, start = ns.UI:LevelingInput(TAILORING, ANA)
	ns.store.IsStale = isStale
	H.eq(start, 120)
	r = byID(recipes)
	H.ok(r[50001].known and r[50002].known, "trainer recipes below 120")
	H.ok(not r[50003].known, "learn 130")
	-- without the profession: skill 1
	ns.store:Remove(ANA)
	ns.store:Apply(memberRecord({ [333] = { s = 50, m = 75, k = true, r = {} } }))
	recipes, start = ns.UI:LevelingInput(TAILORING, ANA)
	H.eq(start, 1)
	for _, x in ipairs(recipes) do H.ok(not x.known, "nothing known at 1: " .. x.id) end
	-- somebody not in the store at all
	recipes, start = ns.UI:LevelingInput(TAILORING, "Player-1-00000099")
	H.eq(start, 1)
	_G.Auctionator = nil
end)

H.test("leveling input: an edited skill is nobody's recipes, learn prices from the cheapest known source", function()
	local ns = boot()
	receiveNU(ns, 6001, { name = "Georgio Bolero", t = { [50003] = { skill = 130, copper = 4000 } }, v = {}, map = 1453, x = 43, y = 74 })
	receiveNU(ns, 6002, { name = "Maria Lumere", t = {}, v = { [80004] = { price = { c = 5000, o = {}, l = 0 } } }, map = 1453, x = 56, y = 64 })
	M.advance(1)
	local recipes, start = ns.UI:LevelingInput(TAILORING, { skill = 120 })
	H.eq(start, 120)
	local r = byID(recipes)
	H.ok(r[50001].known and r[50002].known, "trainer recipes below 120 assumed learned")
	H.ok(not r[50003].known, "learn 130: not yet")
	H.eq(r[50003].learnPrice, 4000, "the trainer's price")
	H.eq(r[50003].learnWhere.kind, "trainer")
	H.eq(r[50003].learnWhere.name, "Georgio Bolero")
	H.eq(r[50004].learnPrice, 5000, "the vendor is cheaper than the AH's 7000")
	H.eq(r[50004].learnWhere.kind, "vendor")
	H.eq(r[50005].learnPrice, nil, "no source known")
	H.ok(not r[50005].known)
	-- the AH when it is the cheapest
	auctionator({ [REAGENT] = 100, [80004] = 3000 })
	r = byID((ns.UI:LevelingInput(TAILORING, { skill = 120 })))
	H.eq(r[50004].learnPrice, 3000)
	H.eq(r[50004].learnWhere.kind, "ah")
	_G.Auctionator = nil
end)

H.test("leveling input: no AH data at all: every recipe is missing a price, no error", function()
	local ns = boot({ noPrices = true })
	local recipes, start, missing = ns.UI:LevelingInput(TAILORING)
	H.eq(#recipes, 0)
	H.eq(missing, 7, "every recipe with skill numbers or reagents")
	H.eq(start, 250)
end)
