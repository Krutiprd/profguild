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

-- The LEVELING tab ---------------------------------------------------------------------------

local LV_KEYS = { "LV_PICK", "LV_PICK_HINT", "LV_OLD", "LV_NOW_HEAD", "LV_NOW_COUNT", "LV_NOW_SUB", "LV_NOW_EMPTY",
	"LV_HEAD", "LV_TOTAL_LOSS", "LV_TOTAL_PROFIT", "LV_NOBODY", "LV_NOBODY_HINT", "LV_MISSING", "LV_MISSING_HINT",
	"LV_DONE", "LV_COUNT", "LV_KNOWN", "LV_LEARN", "LV_LEARN_AT", "LV_LEARN_AH", "LV_ALT", "LV_ALL", "LV_ALL_HINT",
	"LV_STOP", "LV_STOP_HINT", "LV_ORANGE", "LV_YELLOW", "LV_GREEN", "LV_SKILL", "LV_FOR", "LV_ME", "LV_NOBODY_SHORT",
	"LV_RESET", "LV_NOW_BTN", "LV_NOW_HINT", "LV_NO_SOURCE", "LV_COMPUTING", "LV_COMPUTING_HINT" }

-- the window on LEVELING, Tailoring
local function window(opts)
	local ns = boot(opts)
	local UI = ns.UI
	-- the test recipes are in the catalog only: the sidebar lists Tailoring with all recipes
	ProfguildDB.settings.recipeFilter = "all"
	UI:Toggle()
	UI:SetView("leveling")
	UI:SetCategory(TAILORING)
	return ns, UI
end

local function levelRows(UI, lv)
	local out = {}
	for _, d in ipairs(UI.levelRows or {}) do
		if d.lv == lv then out[#out + 1] = d end
	end
	return out
end

local function infoRow(UI, title)
	for _, d in ipairs(UI.levelRows or {}) do
		if d.kind == "lvinfo" and d.title == title then return d end
	end
end

local function shownRow(UI, pred)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and r:IsShown() and pred(d) then return r, d end
	end
end

H.test("leveling tab: every text of the guide in English and Slovak", function()
	local ns = boot()
	for _, key in ipairs(LV_KEYS) do
		H.ok(ns.Locales.en[key], "en " .. key)
		H.ok(ns.Locales.sk[key], "sk " .. key)
	end
	_G.Auctionator = nil
end)

H.test("leveling tab: the plan's head, total and one row per segment with ~count, loss and known or learn", function()
	local ns, UI = window()
	local plan = UI:LevelingPlan(TAILORING).plan
	H.ok(#plan.segments > 0, "a plan")
	local head = UI.levelRows[1]
	H.eq(head.kind, "lvinfo")
	H.eq(plain(head.title), "Tailoring 250 -> 300")
	H.ok(plain(head.text):find(plain(ns.Prices.Format(math.abs(plan.total))), 1, true), "total: " .. plain(head.text))
	local segs = levelRows(UI, "seg")
	H.eq(#segs, #plan.segments)
	for i, d in ipairs(segs) do
		local seg = plan.segments[i]
		H.ok(plain(d.lvName):find(seg.from .. "-" .. seg.to .. "  " .. seg.r.name, 1, true), plain(d.lvName))
		H.ok(plain(d.lvSub):find("^~%d+ pcs"), plain(d.lvSub))
		H.ok(plain(d.lvSub):find(seg.r.known and "[known]" or "[learn: ", 1, true), plain(d.lvSub))
		H.ok(plain(d.lvRight):find("^[%+%-]"), "loss or profit")
	end
	-- the AH recipe item is the learn source of 50004
	local learn
	for _, d in ipairs(segs) do if d.recipeID == 50004 then learn = plain(d.lvSub) end end
	H.ok(learn and learn:find("[learn: 70s 0c, AH]", 1, true), tostring(learn))
	-- shown in the list, first
	H.eq(rawget(UI.rows[1], "data"), head)
	H.ok(UI.levelBar:IsShown(), "the controls")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: a segment opens to at most 3 alternatives and All (n), which opens gives skill now at its start", function()
	local ns, UI = window()
	local row, seg = shownRow(UI, function(d) return d.lv == "seg" end)
	H.ok(row, "a segment row")
	row._scripts.OnClick(row, "LeftButton")
	H.eq(UI.selected.key, seg.key, "selected: the detail shows the recipe")
	H.eq(UI.detail.name:GetText(), seg.name)
	local alts = levelRows(UI, "alt")
	H.ok(#alts <= 3, "at most 3")
	local all
	for _, d in ipairs(UI.levelRows) do if d.action == "all" then all = d end end
	H.ok(all, "All (n)")
	local planSeg
	for _, s in ipairs(UI:LevelingPlan(TAILORING).plan.segments) do
		if seg.key == "lvs" .. s.from .. ":" .. s.r.id then planSeg = s end
	end
	H.eq(all.title, ns.T("LV_ALL", planSeg.all))
	-- the alternatives come right after their segment
	local at
	for i, d in ipairs(UI.levelRows) do if d.key == seg.key then at = i end end
	for i = 1, #alts do H.eq(UI.levelRows[at + i].lv, "alt") end
	H.eq(UI.levelRows[at + #alts + 1], all)
	-- All (n): the list at the segment's start
	local allRow = shownRow(UI, function(d) return d == all end)
	H.ok(allRow, "All shown")
	allRow._scripts.OnClick(allRow, "LeftButton")
	H.eq(UI.levelNow, planSeg.from)
	local now = levelRows(UI, "now")
	H.eq(#now, planSeg.all, "All (n) is the list")
	H.eq(#now, #ns.Leveling.GivesNow(UI:LevelingPlan(TAILORING).recipes, planSeg.from))
	-- clicked again, the segment closes
	UI.levelNow = nil
	UI:Refresh()
	row = shownRow(UI, function(d) return d.key == seg.key end)
	row._scripts.OnClick(row, "LeftButton")
	H.eq(#levelRows(UI, "alt"), 0, "closed")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: gives skill now opens at the start skill with colour, chance, cost, loss and known or learn", function()
	local ns, UI = window()
	UI.levelNowButton._scripts.OnClick(UI.levelNowButton)
	H.eq(UI.levelNow, 250)
	H.eq(plain(UI.levelRows[1].title), ns.T("LV_NOW_HEAD", "Tailoring", 250))
	local now = levelRows(UI, "now")
	local list = ns.Leveling.GivesNow(UI:LevelingPlan(TAILORING).recipes, 250)
	H.ok(#list > 0, "something gives skill")
	H.eq(#now, #list)
	for i, d in ipairs(now) do
		local g = list[i]
		H.eq(d.recipeID, g.r.id, "same order")
		local sub = plain(d.lvSub)
		H.ok(sub:find(ns.T("LV_" .. g.colour:upper()), 1, true), sub)
		H.ok(sub:find(math.floor(g.chance * 100 + 0.5) .. " %", 1, true), sub)
		H.ok(sub:find(plain(ns.Prices.Format(g.cost)), 1, true), sub)
		H.ok(sub:find(g.r.known and "[known]" or (g.r.learnPrice and "[learn" or "[no source known]"), 1, true), sub)
		H.eq(plain(d.lvRight), ns.Prices.Short(-g.loss))
	end
	H.ok(UI.levelNowButton.active, "pressed")
	UI.levelNowButton._scripts.OnClick(UI.levelNowButton)
	H.eq(UI.levelNow, nil, "back to the plan")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: an edited start skill, For: a guild member, Reset", function()
	local ns, UI = window()
	ns.store:Apply(memberRecord({ [TAILORING] = { s = 120, m = 150, k = true, r = { [50003] = 60003 } } }))
	UI.levelSkillBox:SetText("120")
	UI.levelSkillBox._scripts.OnEnterPressed(UI.levelSkillBox)
	H.eq(UI.levelSkill, 120)
	H.eq(plain(UI.levelRows[1].title), "Tailoring 120 -> 300")
	H.eq(UI.levelRows[2].title, ns.T("LV_NOBODY"), "nobody's recipes said")
	H.ok(UI.levelForButton.text:GetText():find(ns.T("LV_NOBODY_SHORT"), 1, true), UI.levelForButton.text:GetText())
	-- For: the menu lists the player, then Ana (Tailoring)
	UI.levelForButton._scripts.OnClick(UI.levelForButton)
	H.ok(UI.levelForMenu:IsShown(), "menu")
	local entries = UI:LevelingForEntries(TAILORING)
	H.eq(entries[1].guid, nil, "me first")
	H.eq(entries[2].guid, ANA)
	H.eq(entries[2].skill, 120)
	local anaRow = UI.levelForMenu.rows[2]
	anaRow._scripts.OnClick(anaRow)
	H.eq(UI.levelWho, ANA)
	H.eq(UI.levelSkill, nil, "the edited skill gives way")
	H.ok(not UI.levelForMenu:IsShown())
	H.eq(plain(UI.levelRows[1].title), "Tailoring 120 -> 300")
	H.ok(UI.levelRows[2].title ~= ns.T("LV_NOBODY"), "Ana's own recipes")
	H.ok(UI.levelForButton.text:GetText():find("Ana", 1, true), UI.levelForButton.text:GetText())
	-- Reset: the player's own again
	UI.levelResetButton._scripts.OnClick(UI.levelResetButton)
	H.eq(UI.levelWho, nil); H.eq(UI.levelSkill, nil)
	H.eq(plain(UI.levelRows[1].title), "Tailoring 250 -> 300")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: For: a member who is stale or lacks the profession: nobody's recipes, no error", function()
	local ns, UI = window()
	ns.store:Apply(memberRecord({ [333] = { s = 50, m = 75, k = true, r = {} } }))
	UI:SetLevelingFor(ANA)
	H.eq(plain(UI.levelRows[1].title), "Tailoring 1 -> 300")
	H.eq(UI.levelRows[2].title, ns.T("LV_NOBODY"))
	ns.store:Remove(ANA)
	ns.store:Apply(memberRecord({ [TAILORING] = { s = 120, m = 150, k = true, r = {} } }))
	local isStale = ns.store.IsStale
	ns.store.IsStale = function() return true end
	UI.levelPlans = nil
	UI:Refresh()
	ns.store.IsStale = isStale
	H.eq(plain(UI.levelRows[1].title), "Tailoring 120 -> 300")
	H.eq(UI.levelRows[2].title, ns.T("LV_NOBODY"))
	-- Ana left the guild's store: no error either
	ns.store:Remove(ANA)
	UI:Refresh()
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: no AH data: the missing prices line, no plan, no error; a gap says from which skill", function()
	local ns, UI = window({ noPrices = true })
	local missing = infoRow(UI, ns.T("LV_MISSING", 7))
	H.ok(missing, "missing prices")
	H.eq(missing.text, ns.T("LV_MISSING_HINT"))
	H.eq(#levelRows(UI, "seg"), 0)
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	-- reagents priced, but no source of 50004 (its recipe item not on the AH): the player's
	-- 50001 gives skill up to its grey 270, nothing known after it
	auctionator({ [REAGENT] = 100 })
	UI.levelPlans = nil
	UI:Refresh()
	H.eq(UI:LevelingPlan(TAILORING).plan.stopAt, 270)
	H.ok(infoRow(UI, ns.T("LV_STOP", 270)), "Nothing known gives skill from 270")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	-- at or above 300: nothing to level
	UI:SetLevelingSkill(300)
	H.ok(infoRow(UI, ns.T("LV_DONE", 300)), "done")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: the old list sorted by grey skill stays under the guide", function()
	local ns, UI = window()
	H.eq(UI.levelRows[#UI.levelRows].title, ns.T("LV_OLD"), "the old list's title last")
	local old = UI.listCache.data
	H.ok(#old > 0, "old rows")
	H.eq(old[1].lv, nil)
	for i = 2, #old do H.ok(old[i - 1].grey <= old[i].grey, "sorted by grey") end
	-- the old rows follow in the list
	UI.offset = #UI.levelRows
	UI:Refresh()
	H.eq(rawget(UI.rows[1], "data"), old[1])
	-- All professions: no plan, a line asks for one
	UI:SetCategory(nil)
	H.eq(UI.levelRows[1].title, ns.T("LV_PICK"))
	H.ok(not UI.levelBar:IsShown(), "no controls without a profession")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)

H.test("leveling tab: the plan is kept between draws and computed again at most once per 3 s", function()
	local ns, UI = window()
	local e = UI:LevelingPlan(TAILORING)
	UI:Refresh()
	H.ok(UI:LevelingPlan(TAILORING) == e, "kept")
	ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
	H.ok(UI:LevelingPlan(TAILORING) == e, "a change within 3 s waits")
	M.advance(3.5)
	H.ok(UI:LevelingPlan(TAILORING) ~= e, "computed again")
	_G.Auctionator = nil
end)

H.test("leveling tab: computed as an NpcWork job: behind other work the tab says so, then shows the plan", function()
	local ns, UI = window()
	UI.levelPlans = nil
	local release = false
	ns.npcWork:Run(function() while not release do coroutine.yield() end end)
	UI:Refresh()
	H.ok(infoRow(UI, ns.T("LV_COMPUTING")), "computing")
	H.eq(#levelRows(UI, "seg"), 0)
	H.eq(UI.levelSkillBox:GetText(), "250", "the start skill already shown")
	release = true
	M.advance(1)
	H.ok(not infoRow(UI, ns.T("LV_COMPUTING")), "done and drawn again")
	H.ok(#levelRows(UI, "seg") > 0, "the plan")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	_G.Auctionator = nil
end)
