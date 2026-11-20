-- Guild prices inside the whole addon: readings of Auctionator (its Database:ProcessScan),
-- sending and receiving PU / PD / PR through the GUILD channel, and the window.
local H = ...
M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M

local ME, ANA = "Player-1-00000001", "Player-1-00000002"
local DAY0 = 1577836800 -- Auctionator's SCAN_DAY_0 in the tests

local function loadAddon()
	M.install()
	local ns = {}
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			assert(loadfile(H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")))("Profguild", ns)
		end
	end
	ns.Prices.TEST_NO_HOOK = true -- the mock's hooksecurefunc does nothing
	return ns
end

-- A fake Auctionator: its database (prices per day), ProcessScan as the real one (lowest price,
-- sum of pieces) and the search API.
local function fakeAuctionator()
	local A = { searched = {} }
	local today = math.floor((GetServerTime() - DAY0) / 86400)
	A.today = today
	local db = {}
	local function set(id, price, pieces, day)
		day = tostring(day or today)
		db[tostring(id)] = db[tostring(id)] or { l = {}, h = {}, a = {}, m = 0 }
		local e = db[tostring(id)]
		e.m, e.h[day], e.a[day] = price, price, pieces
	end
	A.set = set
	set(2589, 150, 40)
	set(4305, 1000, 3)
	Auctionator = {
		Constants = { SCAN_DAY_0 = DAY0 },
		API = { v1 = {
			GetAuctionPriceByItemID = function(_, id) local e = db[tostring(id)] return e and e.m end,
			GetAuctionAgeByItemID = function(_, id)
				local e = db[tostring(id)]
				if not e then return nil end
				local last
				for day in pairs(e.h) do if not last or tonumber(day) > last then last = tonumber(day) end end
				return today - last
			end,
			GetVendorPriceByItemID = function() end,
			MultiSearchExact = function(_, names) A.searched = names end,
		} },
		EventBus = { Register = function() end, Unregister = function() end },
		Search = { Events = { PricesProcessed = "search_prices_processed" } },
		Database = { db = db },
	}
	function Auctionator.Database:ProcessScan(itemIndexes)
		for key, list in pairs(itemIndexes) do
			local minPrice, pieces = list[1].price, 0
			for _, x in ipairs(list) do
				pieces = pieces + x.available
				if x.price < minPrice then minPrice = x.price end
			end
			set(key, minPrice, pieces)
		end
	end
	-- a search or a full scan as Auctionator hands it over: { [key] = { { price, available }, ... } }
	function A.read(list)
		local idx = {}
		for key, auctions in pairs(list) do
			idx[tostring(key)] = {}
			for _, x in ipairs(auctions) do table.insert(idx[tostring(key)], { price = x[1], available = x[2] }) end
		end
		Auctionator.Database:ProcessScan(idx)
	end
	return A
end

local function sentOfType(ns, from, t)
	local out = {}
	for i = from + 1, #M.sent do
		local msg = ns.Comm.Decode(M.sent[i].text)
		if msg and msg.t == t then out[#out + 1] = msg end
	end
	return out
end

local function receive(ns, msg, sender)
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode(msg), "GUILD", sender or "Ana Brightwood")
end

local function login()
	ProfguildDB = nil
	local ns = loadAddon()
	local A = fakeAuctionator()
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8) -- the guild is set up after 5 s
	M.fire("TRADE_SKILL_SHOW") -- Tailoring: 3865 makes 4305 from 2 x 2589
	M.advance(5)
	return ns, A
end

H.test("addon prices: a reading of Auctionator is stored as ours and sent", function()
	local ns, A = login()
	H.ok(ns.guildPrices, "guild prices set up with the guild")
	H.eq(ns.guildPrices:Count(), 0, "what Auctionator held before is not ours to announce")
	local before = #M.sent
	-- a search finds the reagent in two auctions and an item Profguild does not need
	A.read({ [2589] = { { 130, 5 }, { 120, 10 } }, [77777] = { { 5, 1 } } })
	M.advance(5)
	local pu = sentOfType(ns, before, "PU")
	H.eq(#pu, 1, "one update")
	H.eq(#pu[1].i, 5, "only the needed item")
	H.eq(pu[1].i[1], 2589); H.eq(pu[1].i[2], 120, "the lowest price"); H.eq(pu[1].i[3], 15, "all pieces")
	H.eq(pu[1].w[pu[1].i[5]], ME)
	H.eq(ns.Prices.Get(2589), 120)
	-- searches right after each other go out together; the same price read again is sent again
	before = #M.sent
	A.read({ [2589] = { { 120, 15 } } })
	A.read({ [4305] = { { 990, 2 } } })
	M.advance(5)
	pu = sentOfType(ns, before, "PU")
	H.eq(#pu, 1, "together"); H.eq(#pu[1].i, 10, "both items")
	-- an item with no auctions now is not in the reading and not sent
	before = #M.sent
	A.read({})
	M.advance(5)
	H.eq(#sentOfType(ns, before, "PU"), 0)
	-- the hello carries the digest
	before = #M.sent
	ns.sync.lastHello = -1e9
	ns.Hello(true)
	M.advance(2)
	local pd = sentOfType(ns, before, "PD")
	H.ok(#pd >= 1, "digest after the hello")
	pd = pd[#pd]
	H.eq(pd.b[1], math.floor(GetServerTime() / 86400), "today's day"); H.eq(pd.b[2], 2, "two prices on it")
end)

H.test("addon prices: a guildmate's newer price wins and the window says whose it is", function()
	local ns, A = login()
	local clock = GetServerTime()
	-- Ana read the auction house a minute ago: newer than Auctionator's day of our price
	receive(ns, { t = "PU", pv = ns.GuildPrices.PROTOCOL, s = ANA, w = { ANA }, i = { 2589, 90, 12, clock - 60, 1 } })
	H.eq(ns.guildPrices:Get(2589).p, 90)
	local price, kind, age, e = ns.Prices.Get(2589)
	H.eq(price, 90); H.eq(kind, "ah"); H.eq(age, 0); H.eq(e.w, ANA)
	H.eq(ns.Prices.Available(2589), 12, "pieces from the guild too")
	H.eq(ns.Prices.Cost({ [2589] = 2 }), 180, "the cost uses the newer price")
	-- older than the start of Auctionator's day: ours stays
	receive(ns, { t = "PU", pv = ns.GuildPrices.PROTOCOL, s = ANA, w = { ANA }, i = { 4305, 5000, 1, clock - 3 * 86400, 1 } })
	H.eq(ns.Prices.Get(4305), 1000, "an old guild price loses against today's")
	-- our own reading is never replaced by Auctionator's older day
	A.read({ [2589] = { { 140, 3 } } })
	M.advance(2)
	H.eq(ns.Prices.Get(2589), 140, "read just now")
	local _, _, _, own = ns.Prices.Get(2589)
	H.eq(own, nil, "our own price is not shown as the guild's")
	-- the window
	local UI = ns.UI
	UI:Toggle()
	UI:SetCategory(197)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == 3865 then r._scripts.OnClick(r, "LeftButton") end
	end
	H.eq(UI.selected.recipeID, 3865)
	H.eq(UI.detail.costValue:GetText(), ns.Prices.Format(280))
	-- Ana's price of the crafted item is newer than our scan of two days ago
	local e4305 = Auctionator.Database.db["4305"]
	e4305.h, e4305.a = {}, {}
	A.set(4305, 1000, 3, A.today - 2)
	receive(ns, { t = "PU", pv = ns.GuildPrices.PROTOCOL, s = ANA, w = { ANA }, i = { 4305, 2000, 4, clock - 7200, 1 } })
	UI:Refresh()
	local value = UI.detail.value:GetText()
	H.ok(value:find(ns.T("PRICE_FROM", "Ana Brightwood", ns.T("AGO_HOURS", 2)), 1, true), "whose and how old: " .. value)
	H.ok(value:find(ns.T("PCS", 4), 1, true), "pieces from the guild")
	H.eq(UI.detail.profitValue:GetText(), ns.Prices.Format(1900 - 280), "profit from the guild's price minus the cut")
	-- the reagent row's tooltip names the guildmate when its price is the guild's
	receive(ns, { t = "PU", pv = ns.GuildPrices.PROTOCOL, s = ANA, w = { ANA }, i = { 2589, 95, 12, clock + 5, 1 } })
	UI:Refresh()
	M.tooltipLines = {}
	local row = UI.detail.reagentRows[1]
	row._scripts.OnEnter(row)
	H.ok(table.concat(M.tooltipLines, "\n"):find("Ana Brightwood", 1, true), "tooltip: " .. table.concat(M.tooltipLines, "|"))
	-- refreshing twice does not repeat anything on the line above
	UI:Refresh(); UI:Refresh()
	local sub = UI.detail.sub:GetText()
	local _, n = sub:gsub("Tailoring", "")
	H.eq(n, 1, "profession once: " .. sub)
	-- /pg status shows the guild prices
	SlashCmdList.PROFGUILD("status")
	H.ok(table.concat(M.chat, "\n"):find("Guild prices: 2", 1, true), "status line")
end)

H.test("addon prices: a digest that differs is asked for by day, a request to us is answered", function()
	local ns, A = login()
	local clock = GetServerTime()
	local today = math.floor(clock / 86400)
	A.read({ [2589] = { { 111, 4 } } })
	M.advance(5)
	-- Ana holds prices of today and of yesterday that we do not have
	local before = #M.sent
	receive(ns, { t = "PD", pv = ns.GuildPrices.PROTOCOL, s = ANA, b = { today - 1, 3, 12345, today, 5, 999 } })
	M.advance(6)
	local pr = sentOfType(ns, before, "PR")
	H.eq(#pr, 1, "asked Ana"); H.eq(pr[1].to, ANA)
	H.eq(#pr[1].d, 2); H.eq(pr[1].d[1], today - 1); H.eq(pr[1].d[2], today)
	-- we hold a day Ana lacks: our own digest follows
	local pd = sentOfType(ns, before, "PD")
	H.ok(#pd >= 1, "answering digest")
	-- Ana asks us for today
	before = #M.sent
	receive(ns, { t = "PR", pv = ns.GuildPrices.PROTOCOL, s = ANA, to = ME, d = { today } })
	M.advance(10)
	local pu = sentOfType(ns, before, "PU")
	H.eq(#pu, 1, "answered"); H.eq(pu[1].i[1], 2589); H.eq(pu[1].i[2], 111)
	-- a request to somebody else is not ours to answer
	before = #M.sent
	receive(ns, { t = "PR", pv = ns.GuildPrices.PROTOCOL, s = "Player-1-00000005", to = "Player-1-00000009", d = { today } })
	M.advance(70)
	H.eq(#sentOfType(ns, before, "PU"), 0)
end)

H.test("addon prices: a guild change stops the old guild's prices", function()
	local ns = login()
	local old = ns.guildPrices
	old:Record({ [2589] = { p = 111, n = 4 } }) -- its update would leave a second later
	GetGuildInfo = function() return "Other Guild", "Member", 3, nil end
	ns.SetupGuild()
	local before = #M.sent
	M.advance(5)
	H.ok(old.dead, "the old object is stopped")
	H.ok(ns.guildPrices ~= old)
	H.eq(#sentOfType(ns, before, "PU"), 0, "the old guild's reading does not reach the new guild")
end)

H.test("addon prices: without Auctionator the guild's prices are the source", function()
	local ns = login()
	Auctionator = nil
	H.eq(ns.Prices.Source(), nil, "nothing yet")
	local clock = GetServerTime()
	receive(ns, { t = "PU", pv = ns.GuildPrices.PROTOCOL, s = ANA, w = { ANA }, i = { 2589, 90, 12, clock - 60, 1 } })
	H.eq(ns.Prices.Source(), "Guild")
	H.eq(ns.Prices.Get(2589), 90)
	SlashCmdList.PROFGUILD("status")
	H.ok(table.concat(M.chat, "\n"):find(ns.T("PRICE_SOURCE_GUILD"), 1, true), "translated in /pg status")
	-- a guildmate's price of an item this client does not show yet is kept too
	receive(ns, { t = "PU", pv = ns.GuildPrices.PROTOCOL, s = ANA, w = { ANA }, i = { 77777, 90, 12, clock - 60, 1 } })
	H.eq(ns.guildPrices:Get(77777).p, 90)
end)
