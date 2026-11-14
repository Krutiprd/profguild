-- Reagent catalog, the Q / C exchange in a small simulated guild, and price lookups.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "Reagents.lua", "Prices.lua" })
local Reagents, Prices = ns.Reagents, ns.Prices
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")

H.test("Reagents.Validate keeps whole positive counts and caps the list", function()
	local clean = Reagents.Validate({ [2589] = 2, [2320] = 1, bad = 3, [5] = -1, [6] = 1.5, [7] = 5000 })
	H.eq(clean[2589], 2); H.eq(clean[2320], 1)
	H.eq(clean.bad, nil); H.eq(clean[5], nil); H.eq(clean[6], nil); H.eq(clean[7], nil)
	H.eq(Reagents.Validate({}), nil, "empty")
	H.eq(Reagents.Validate("x"), nil, "not a table")
	local many = {}
	for i = 1, Reagents.MAX_PER_RECIPE + 1 do many[i] = 1 end
	H.eq(Reagents.Validate(many), nil, "too many reagents")
end)

-- A guild where every message reaches everyone else after the serializer round trip.
local function newGuild()
	local g = { t = 0, timers = {}, clients = {}, sent = { Q = 0, C = 0 }, seed = 7 }
	function g.random()
		g.seed = (g.seed * 1103515245 + 12345) % 2147483648
		return g.seed / 2147483648
	end
	function g.add(guid, catalog)
		local client = { guid = guid, blocked = false }
		client.r = Reagents.New({
			send = function(msg)
				g.sent[msg.t] = g.sent[msg.t] + 1
				local text = LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg)))
				for _, other in ipairs(g.clients) do
					local ok, copy = LS:Deserialize(LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(text)))
					assert(ok)
					other.r:OnMessage(copy) -- the sender gets its echo too and must ignore it
				end
			end,
			canSend = function() return not client.blocked end,
			now = function() return g.t end,
			after = function(delay, fn) g.timers[#g.timers + 1] = { at = g.t + delay, fn = fn } end,
			random = g.random,
			myGuid = function() return guid end,
			onChanged = function(id) client.changed = id end,
		}, catalog or {})
		g.clients[#g.clients + 1] = client
		return client
	end
	function g.run(seconds)
		local target = g.t + seconds
		while true do
			table.sort(g.timers, function(a, b) return a.at < b.at end)
			local nextTimer = g.timers[1]
			if not nextTimer or nextTimer.at > target then break end
			table.remove(g.timers, 1)
			g.t = nextTimer.at
			nextTimer.fn()
		end
		g.t = target
	end
	return g
end

H.test("Reagents: a recipe opened in the window is asked for once and answered once", function()
	local g = newGuild()
	local smith = g.add("Player-1-A", { [2662] = { [2840] = 6, [2880] = 2 } })
	local other = g.add("Player-1-B", { [2662] = { [2840] = 6, [2880] = 2 } })
	local asker = g.add("Player-1-C")
	H.ok(asker.r:Want(2662), "query planned")
	H.ok(not asker.r:Want(2662), "not twice")
	H.ok(asker.r:IsAsking(2662))
	g.run(5)
	H.eq(g.sent.Q, 1, "one query")
	H.eq(g.sent.C, 1, "one answer: the first one cancels the other")
	H.eq(asker.r:Get(2662)[2840], 6, "reagents learned")
	H.eq(asker.changed, 2662, "window told to redraw")
	H.ok(not asker.r:IsAsking(2662))
	H.ok(not asker.r:Want(2662), "known now")
	H.eq(smith.r.stats.recvQ + other.r.stats.recvQ, 2)
end)

H.test("Reagents: nobody knows it, no new query before ASK_AGAIN", function()
	local g = newGuild()
	g.add("Player-1-A", {})
	local asker = g.add("Player-1-C")
	asker.r:Want(9999)
	g.run(5)
	H.eq(g.sent.Q, 1); H.eq(g.sent.C, 0)
	H.ok(not asker.r:Want(9999), "too soon")
	g.run(Reagents.ASK_AGAIN)
	H.ok(asker.r:Want(9999), "asked again later")
	H.ok(not asker.r:IsAsking(1), "a recipe never asked for")
end)

H.test("Reagents: blocked sending plans nothing, queries are batched", function()
	local g = newGuild()
	local holder = g.add("Player-1-A", { [1] = { [10] = 1 }, [2] = { [20] = 2 }, [3] = { [30] = 3 } })
	local asker = g.add("Player-1-C")
	asker.blocked = true
	H.ok(not asker.r:Want(1), "nothing in an instance")
	asker.blocked = false
	asker.r:Want(1); asker.r:Want(2); asker.r:Want(3)
	g.run(5)
	H.eq(g.sent.Q, 1, "three recipes in one query")
	H.eq(g.sent.C, 1, "and in one answer")
	H.eq(asker.r:Count(), 3)
	H.eq(holder.r.stats.sentC, 1)
end)

H.test("Reagents: junk in messages is ignored, own scan replaces and reports changes", function()
	local g = newGuild()
	local me = g.add("Player-1-A")
	me.r:Want(5); me.r:Want(6); me.r:Want(8)
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-X", c = { [5] = { [1] = "x" }, x = { [1] = 1 }, [6] = { [7] = 2 } } })
	H.eq(me.r:Get(5), nil); H.eq(me.r:Get(6)[7], 2)
	me.r:OnMessage({ t = "C", pv = 2, s = "Player-1-X", c = { [8] = { [7] = 2 } } })
	H.eq(me.r:Get(8), nil, "other protocol version")
	me.r:OnMessage({ t = "Q", pv = 1, s = "Player-1-X", q = "nope" })
	me.r:OnMessage("garbage")
	H.ok(me.r:Set(6, { [7] = 3 }), "own scan changes it")
	H.ok(not me.r:Set(6, { [7] = 3 }), "same again is no change")
	H.ok(not me.r:Set(6, nil), "empty scan keeps the known list")
	H.eq(me.r:Get(6)[7], 3)
end)

H.test("Reagents: only answers to our own recent questions are stored", function()
	local g = newGuild()
	local me = g.add("Player-1-A")
	local other = g.add("Player-1-B")
	-- nobody asked
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-X", c = { [100] = { [7] = 2 } } })
	H.eq(me.r:Get(100), nil, "unsolicited entry ignored")
	-- somebody else asked: we stay quiet about it and do not store the answer either
	other.r:Want(200)
	g.run(1)
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-X", c = { [200] = { [7] = 2 } } })
	H.eq(me.r:Get(200), nil, "an answer to someone else's question is not stored")
	-- we asked, but the answer comes far too late
	me.r:Want(300)
	g.run(Reagents.ASK_AGAIN + 1)
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-X", c = { [300] = { [7] = 2 } } })
	H.eq(me.r:Get(300), nil, "expired question")
	-- we asked and the answer comes in time; a second, different answer changes nothing
	me.r:Want(400)
	g.run(1)
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-X", c = { [400] = { [7] = 2 } } })
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-Y", c = { [400] = { [9] = 9 } } })
	H.eq(me.r:Get(400)[7], 2, "first answer kept")
	-- what the game says replaces what a guildmate said
	H.ok(me.r:Set(400, { [8] = 1 }), "game data replaces it")
	H.eq(me.r:Get(400)[7], nil); H.eq(me.r:Get(400)[8], 1)
	-- a full catalog takes nothing more from guildmates
	local oldMax = Reagents.MAX_CATALOG
	Reagents.MAX_CATALOG = me.r:Count()
	me.r:Want(500)
	g.run(1)
	me.r:OnMessage({ t = "C", pv = 1, s = "Player-1-X", c = { [500] = { [7] = 2 } } })
	Reagents.MAX_CATALOG = oldMax
	H.eq(me.r:Get(500), nil, "catalog full")
end)

H.test("Prices: Auctionator auction price, then vendor price, then TSM", function()
	local calls = {}
	Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function(caller, id) calls[#calls + 1] = caller; return ({ [2840] = 150 })[id] end,
		GetAuctionAgeByItemID = function(_, id) return id == 2840 and 2 or nil end,
		GetVendorPriceByItemID = function(_, id) return ({ [2880] = 100 })[id] end,
	} } }
	H.eq(Prices.Source(), "Auctionator")
	local p, kind, age = Prices.Get(2840)
	H.eq(p, 150); H.eq(kind, "ah"); H.eq(age, 2)
	H.eq(calls[1], "Profguild", "caller id")
	p, kind = Prices.Get(2880)
	H.eq(p, 100); H.eq(kind, "vendor")
	H.eq(Prices.Get(1), nil, "no price")
	local total, missing = Prices.Cost({ [2840] = 6, [2880] = 2, [1] = 1 })
	H.eq(total, 1100); H.eq(missing, 1)
	Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function() error("broken") end } } }
	H.eq(Prices.Get(2840), nil, "an erroring API is no price")
	Auctionator = nil
	TSM_API = { GetCustomPriceValue = function(source, item) if source == "DBMarket" and item == "i:2840" then return 170 end end }
	H.eq(Prices.Source(), "TSM")
	H.eq(Prices.Get(2840), 170)
	TSM_API = nil
	H.eq(Prices.Source(), nil)
	H.eq(Prices.Get(2840), nil)
end)

H.test("Prices: money format and Auctionator shopping list", function()
	H.eq(Prices.Format(123456), "|cffffd70012|rg |cffc7c7cf34|rs |cffeda55f56|rc")
	H.eq(Prices.Format(305), "|cffc7c7cf3|rs |cffeda55f5|rc")
	H.eq(Prices.Format(7), "|cffeda55f7|rc")
	H.eq(Prices.Format(nil), "-")

	ns.Scanner = { ItemName = function(id) return ({ [2840] = "Copper Bar", [2880] = "Weak Flux" })[id] end }
	local created
	Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function() end,
		ConvertToSearchString = function(_, term)
			return string.format("\"%s\";;;;;;;;;;;;;;%d", term.searchString, term.quantity)
		end,
		CreateShoppingList = function(caller, name, terms) created = { caller = caller, name = name, terms = terms } end,
	} } }
	H.ok(Prices.CanShop())
	H.ok(Prices.ShoppingList("Copper Mace", { [2840] = 6, [2880] = 2 }, 2))
	H.eq(created.name, "Profguild: Copper Mace")
	H.eq(#created.terms, 2)
	H.ok(created.terms[1]:find("Copper Bar", 1, true) and created.terms[1]:find("12", 1, true), "quantity for 2 crafts")
	local ok, why = Prices.ShoppingList("X", { [1] = 1 })
	H.ok(not ok and why == "names", "unknown item name")
	Auctionator = nil
	ok, why = Prices.ShoppingList("X", { [2840] = 1 })
	H.ok(not ok and why == "no auctionator")
	ns.Scanner = nil
end)
