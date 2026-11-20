-- Guild prices: readings, newer wins, and keeping a small simulated guild in step with
-- PU / PD / PR (day digests). Includes the cases review round 2 found against the earlier design.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "GuildPrices.lua" })
local GP = ns.GuildPrices
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")

local CLOCK0 = 1794615000 -- server time at the start

local function newGuild()
	local g = { t = 0, timers = {}, clients = {}, sent = { PU = 0, PD = 0, PR = 0 }, bytes = 0, seed = 7 }
	function g.random()
		g.seed = (g.seed * 1103515245 + 12345) % 2147483648
		return g.seed / 2147483648
	end
	function g.add(guid, saved)
		local client = { guid = guid, blocked = false, online = true, saved = saved or {} }
		client.p = GP.New({
			send = function(msg)
				g.sent[msg.t] = g.sent[msg.t] + 1
				local text = LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg)))
				assert(#text < 24000, "message fits the receive limit")
				g.bytes = g.bytes + #text
				if g.drop and g.drop(msg) then return end -- lost on the way
				for _, other in ipairs(g.clients) do
					if other.online then
						local ok, copy = LS:Deserialize(LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(text)))
						assert(ok)
						other.p:OnMessage(copy) -- the sender gets its echo too and must ignore it
					end
				end
			end,
			canSend = function() return client.online and not client.blocked end,
			now = function() return g.t end,
			clock = function() return CLOCK0 + math.floor(g.t) end,
			after = function(delay, fn) g.timers[#g.timers + 1] = { at = g.t + delay, fn = fn, owner = client } end,
			random = g.random,
			myGuid = function() return guid end,
			onChanged = function() client.changes = (client.changes or 0) + 1 end,
		}, client.saved)
		g.clients[#g.clients + 1] = client
		return client
	end
	-- a client logs out and in again: same saved data, a new session
	function g.relog(client)
		for i, c in ipairs(g.clients) do if c == client then table.remove(g.clients, i) break end end
		for i = #g.timers, 1, -1 do if g.timers[i].owner == client then table.remove(g.timers, i) end end
		return g.add(client.guid, client.saved)
	end
	function g.run(seconds)
		local target = g.t + seconds
		while true do
			table.sort(g.timers, function(a, b) return a.at < b.at end)
			local nextTimer = g.timers[1]
			if not nextTimer or nextTimer.at > target then break end
			table.remove(g.timers, 1)
			g.t = nextTimer.at
			if nextTimer.owner.online then nextTimer.fn() end
		end
		g.t = target
	end
	-- everybody online says hello (a digest) and the guild settles
	function g.hellos(rounds)
		for _ = 1, rounds or 1 do
			for _, c in ipairs(g.clients) do
				if c.online then c.p.lastDigest = -1e9; c.p:Announce() end
			end
			g.run(240)
		end
	end
	function g.same(a, b)
		for itemID, e in pairs(a.p.prices) do
			local o = b.p.prices[itemID]
			if not o or o.t ~= e.t or o.p ~= e.p then return false, itemID end
		end
		return a.p:Count() == b.p:Count()
	end
	return g
end

local A, B, C, D = "Player-1-0000000A", "Player-1-0000000B", "Player-1-0000000C", "Player-1-0000000D"

local function reading(from, to, base)
	local r = {}
	for i = from, to do r[i] = { p = (base or 100) + i, n = i } end
	return r
end

H.test("guild prices: Store validates, keeps only newer prices and makes room", function()
	local g = newGuild()
	local p = g.add(A).p
	local now = CLOCK0
	H.ok(p:Store(10, 500, 3, now, B))
	H.eq(p:Get(10).p, 500)
	H.ok(not p:Store(10, 600, 3, now, C), "the same time, a higher price: kept")
	H.ok(p:Store(10, 400, 3, now, C), "the same time, a lower price: every client keeps the same")
	H.ok(not p:Store(10, 300, 3, now - 5, C), "older does not replace")
	H.ok(p:Store(10, 450, 2, now + 5, C), "newer replaces")
	H.eq(p:Get(10).w, C)
	H.ok(not p:Store(11, 0, 1, now, B), "price 0")
	H.ok(not p:Store(11, GP.MAX_PRICE + 1, 1, now, B), "too expensive")
	H.ok(not p:Store(11, 1.5, 1, now, B), "fractions of copper")
	H.ok(not p:Store(11, 5, GP.MAX_PIECES + 1, now, B), "too many pieces")
	H.ok(not p:Store(11, 5, 1, now + GP.MAX_AHEAD + 1, B), "from the future")
	H.ok(not p:Store(11, 5, 1, now - GP.MAX_AGE - 1, B), "too old")
	H.ok(not p:Store(11, 5, 1, 0 / 0, B), "NaN")
	H.ok(not p:Store(11, 5, 1, now, "Creature-1"), "not a player")
	H.ok(not p:Store(-1, 5, 1, now, B), "bad item")
	H.ok(not p:Store("11", 5, 1, now, B), "item as a string")
	H.eq(p:Count(), 1)
	-- one finder holds at most MAX_PER_FINDER prices
	for i = 1, GP.MAX_PER_FINDER + 10 do p:Store(100000 + i, 5, 1, now, "Player-1-0000000F") end
	H.eq(p.perFinder["Player-1-0000000F"], GP.MAX_PER_FINDER, "a flood of one guildmate is capped")
	H.ok(p:Get(100001) and not p:Get(100000 + GP.MAX_PER_FINDER + 10), "the same ones kept everywhere: at the same time the higher item IDs go")
	H.ok(not p:Store(1, 5, 1, now - 100, "Player-1-0000000F"), "an older one of that finder does not push one out")
	H.ok(p:Store(30, 5, 1, now, C), "others still get in")
	-- full: the lowest ranked price makes room, the same everywhere (newest first, then lower item)
	p:Store(20, 5, 1, now - 1000, B)
	local finders = { B, C, D, "Player-1-0000000E" }
	for i = 1, GP.MAX_ENTRIES do p:Store(1000 + i, 5, 1, now, finders[i % 4 + 1]) end
	H.eq(p:Count(), GP.MAX_ENTRIES)
	H.eq(p:Get(20), nil, "the oldest went first")
	H.ok(p:Store(99999, 5, 1, now + 1, B), "a newer item fits")
	H.ok(not p:Store(99998, 5, 1, now - 2000, B), "an item older than everything held does not push one out")
	H.eq(p:Count(), GP.MAX_ENTRIES)
	local n = 0
	for _, c in pairs(p.perFinder) do n = n + c end
	H.eq(n, p:Count(), "finder counts add up")
end)

H.test("guild prices: two full tables become equal (no endless exchange)", function()
	local saved = GP.MAX_ENTRIES
	GP.MAX_ENTRIES = 50
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	b.online = false
	a.p:Record(reading(1, 50))
	g.run(5)
	a.online, b.online = false, true
	b.p:Record(reading(101, 150)) -- the same second as A's: ties everywhere
	g.run(5)
	a.online = true
	g.hellos(3)
	local asks, updates = g.sent.PR, g.sent.PU
	g.hellos(3)
	GP.MAX_ENTRIES = saved
	H.ok(g.same(a, b), "equal")
	H.eq(g.sent.PR, asks, "quiet afterwards"); H.eq(g.sent.PU, updates)
end)

H.test("guild prices: a reading is stored as ours and reaches the guild, newer wins", function()
	local g = newGuild()
	local a, b, c = g.add(A), g.add(B), g.add(C)
	H.eq(a.p:Record(reading(1, 3)), 3)
	H.eq(a.p:Get(2).w, A); H.eq(a.p:Get(2).t, CLOCK0)
	g.run(5)
	H.eq(g.sent.PU, 1, "one update for the reading")
	H.eq(b.p:Get(1).p, 101); H.eq(b.p:Get(1).w, A, "who read it travels with the price")
	H.eq(c.p:Get(3).n, 3)
	g.run(60)
	b.p:Record({ [1] = { p = 650, n = 9 } })
	g.run(5)
	H.eq(a.p:Get(1).p, 650); H.eq(a.p:Get(1).w, B)
	H.ok(not a.p:Store(1, 777, 1, CLOCK0, A), "an old price arriving late does not replace it")
	-- a guildmate's clock a little ahead: our reading now still wins
	b.p:Store(2, 1, 1, CLOCK0 + 100, C)
	b.p:Record({ [2] = { p = 42, n = 1 } })
	H.eq(b.p:Get(2).p, 42); H.eq(b.p:Get(2).t, CLOCK0 + 101)
	H.eq(a.p:Record({ [7] = { p = 0, n = 1 }, [8] = "x" }), 0, "nothing valid")
end)

H.test("guild prices: readings close together leave as one update, big ones in parts", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	for k = 1, 3 do
		a.p:Record({ [k] = { p = 5000 + k, n = 1 } })
		g.run(0.2)
	end
	g.run(5)
	H.eq(g.sent.PU, 1, "merged")
	g.run(10)
	a.p:Record(reading(1, 250))
	g.run(1.2)
	H.eq(b.p:Count(), 100, "parts arrive one by one")
	g.run(10)
	H.eq(b.p:Count(), 250, "all parts arrived")
	H.eq(g.sent.PU, 1 + 3, "250 items in 3 parts")
end)

H.test("guild prices: newcomers get everything from one answer; a guild in step asks nothing", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	a.p:Record(reading(1, 40))
	g.run(5)
	local c, d = g.add(C), g.add(D)
	a.p:Announce()
	g.run(20)
	H.eq(g.sent.PR, 1, "one request: the other newcomer is covered")
	H.ok(g.same(a, c) and g.same(a, d), "both have everything")
	-- everybody says hello: equal digests, nothing asked
	local asks, updates = g.sent.PR, g.sent.PU
	g.hellos()
	H.eq(g.sent.PR, asks, "nothing to ask")
	H.eq(g.sent.PU, updates, "nothing sent")
	H.ok(g.same(a, b))
end)

H.test("guild prices: prices read while others were offline reach everybody (review 2, case 1)", function()
	local g = newGuild()
	local p1, p2, p3 = g.add(A), g.add(B), g.add(C)
	-- each reads while the others are offline
	p2.online, p3.online = false, false
	p1.p:Record({ [1] = { p = 11, n = 1 }, [2] = { p = 12, n = 1 } })
	g.run(100)
	p1.online, p2.online = false, true
	p2.p:Record({ [3] = { p = 13, n = 1 } })
	g.run(100)
	p2.online, p3.online = false, true
	p3.p:Record({ [4] = { p = 14, n = 1 } })
	g.run(100)
	-- in the evening all three are online
	p1.online, p2.online = true, true
	g.hellos(3)
	H.ok(g.same(p1, p2) and g.same(p2, p3), "all three hold the same prices")
	H.eq(p3.p:Get(1).p, 11); H.eq(p2.p:Get(4).p, 14)
end)

H.test("guild prices: a lost or half-heard answer is repaired by the next digest (review 2, case 2)", function()
	local g = newGuild()
	local h = g.add(A)
	h.p:Record(reading(1, 1000))
	g.run(30)
	-- a newcomer asks; a late joiner logs in during the answer and hears only its last parts;
	-- one part is lost on the way
	local n = g.add(B)
	local late = g.add(C)
	late.online = false
	local parts = 0
	g.drop = function(msg)
		if msg.t ~= "PU" then return false end
		parts = parts + 1
		return parts == 3
	end
	h.p:Announce()
	g.run(8)
	late.online = true
	g.run(120)
	g.drop = nil
	H.ok(n.p:Count() < 1000 and late.p:Count() < 1000, "both miss something now: " .. n.p:Count() .. "/" .. late.p:Count())
	g.hellos(3)
	H.eq(n.p:Count(), 1000, "the newcomer is complete")
	H.eq(late.p:Count(), 1000, "the late joiner is complete")
	H.ok(g.same(h, late))
end)

H.test("guild prices: prices of items a client did not need yet are kept (review 2, case 3)", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	a.p:Record(reading(1, 5))
	g.run(5)
	-- every valid price is stored, whatever this client shows today
	H.eq(b.p:Count(), 5)
	H.ok(g.same(a, b))
end)

H.test("guild prices: readings that could not be sent reach the guild through the digests", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	a.blocked = true -- in combat or an instance
	a.p:Record(reading(1, 3))
	g.run(5)
	H.eq(b.p:Count(), 0)
	a.blocked = false
	g.hellos(2)
	H.eq(b.p:Count(), 3)
end)

H.test("guild prices: newer prices on both sides are exchanged both ways", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	a.p:Record(reading(1, 10))
	g.run(5)
	b.online = false
	g.run(100)
	a.p:Record({ [1] = { p = 1, n = 1 } })
	g.run(5)
	b.online, a.online = true, false
	g.run(100)
	b.p:Record({ [2] = { p = 2, n = 1 } })
	g.run(5)
	a.online = true
	g.hellos(3)
	H.ok(g.same(a, b))
	H.eq(b.p:Get(1).p, 1); H.eq(a.p:Get(2).p, 2)
end)

H.test("guild prices: an empty newcomer gets everything within seconds of its own hello", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	a.p:Record(reading(1, 30))
	g.run(5)
	a.p:Announce(); b.p:Announce(); g.run(240) -- the holders' hellos are long past
	local c = g.add(C)
	H.eq(c.p:Count(), 0)
	local digests = g.sent.PD
	c.p:Announce() -- only the newcomer says hello
	g.run(30)
	H.eq(c.p:Count(), 30, "everything, without waiting for another hello")
	H.ok(g.sent.PD - digests <= 3, "its digest and one or two answering digests: " .. (g.sent.PD - digests))
end)

H.test("guild prices: the day sums do not cancel out, broken saved prices are dropped", function()
	-- two versions that a linear sum could not tell apart
	local h1 = GP.Hash(10, CLOCK0, 100) + GP.Hash(11, CLOCK0, 100)
	local h2 = GP.Hash(10, CLOCK0 + 1, 100) + GP.Hash(11, CLOCK0 - 1, 100)
	H.ok(h1 % GP.SUM_MOD ~= h2 % GP.SUM_MOD, "times shifted both ways")
	H.ok(GP.Hash(10, CLOCK0, 100) ~= GP.Hash(10, CLOCK0 - 1, 48371), "price against time")
	local g = newGuild()
	local saved = { prices = { [1] = "x", [2] = { p = 5, n = 1, t = CLOCK0 }, [3] = { p = 5, n = 1, t = CLOCK0, w = A } } }
	local c = g.add(B, saved)
	H.eq(c.p:Count(), 1, "only the valid one"); H.eq(saved.prices[1], nil); H.eq(c.p.perFinder[A], 1)
end)

H.test("guild prices: a holder answers a newcomer's digest with its own", function()
	local g = newGuild()
	local a = g.add(A)
	g.add(B)
	a.p:Record(reading(1, 10))
	g.run(5)
	a.p:Announce(); g.run(240)
	-- a newcomer with an old price says hello; nobody else's hello is due
	local c = g.add(C)
	c.p:Store(1, 5, 1, CLOCK0 - 86400, A)
	local digests = g.sent.PD
	c.p:Announce()
	g.run(30)
	H.ok(g.sent.PD - digests <= 3, "the newcomer's digest and few answering ones: " .. (g.sent.PD - digests))
	H.eq(c.p:Count(), 10, "the newcomer got everything")
end)

H.test("guild prices: answer cooldown merges the days asked by several", function()
	local g = newGuild()
	local a = g.add(A)
	a.p:Record(reading(1, 10))
	g.run(5)
	local before = g.sent.PU
	local day = math.floor(CLOCK0 / 86400)
	a.p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = B, to = A, d = { day } })
	g.run(5)
	H.eq(g.sent.PU - before, 1, "answered at once")
	-- the same day, unchanged: the guild just got it, not sent again
	a.p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = C, to = A, d = { day } })
	g.run(GP.ANSWER_COOLDOWN + 5)
	H.eq(g.sent.PU - before, 1, "an unchanged day is not answered again")
	-- the day changed: answered, once for two askers, after the cooldown
	a.p:Store(500, 5, 1, CLOCK0 + 70, C)
	a.p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = C, to = A, d = { day } })
	a.p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = D, to = A, d = { day, day - 1 } })
	g.run(GP.ANSWER_COOLDOWN + 5)
	H.eq(g.sent.PU - before, 2, "one answer for both")
	-- a day with nothing on it: no answer
	a.p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = B, to = A, d = { day - 5 } })
	g.run(GP.ANSWER_COOLDOWN + 5)
	H.eq(g.sent.PU - before, 2)
end)

H.test("guild prices: bad messages are ignored, Prune drops old prices, Stop stops sending", function()
	local g = newGuild()
	local a = g.add(A)
	local p = a.p
	H.eq(p:OnMessage({ t = "PU", pv = GP.PROTOCOL, s = B, w = { B }, i = { 1, 50, 1, CLOCK0, 1, 2, -5, 1, CLOCK0, 1, 3, 60, 1, CLOCK0, 9 } }), 1,
		"only the valid entry")
	H.eq(p:OnMessage({ t = "PU", pv = GP.PROTOCOL, s = B, w = { "nonsense" }, i = { 4, 50, 1, CLOCK0, 1 } }), 0, "bad finder")
	H.eq(p:OnMessage({ t = "PU", pv = 99, s = B, w = { B }, i = { 5, 50, 1, CLOCK0, 1 } }), nil, "other protocol")
	H.eq(p:OnMessage({ t = "PU", pv = GP.PROTOCOL, s = A, w = { A }, i = { 6, 50, 1, CLOCK0, 1 } }), nil, "own echo")
	H.eq(p:OnMessage({ t = "PU", pv = GP.PROTOCOL, s = B, w = { B }, i = "x" }), nil)
	local many = {}
	for i = 1, GP.MAX_PER_MESSAGE + 20 do
		for _, x in ipairs({ 100 + i, 50, 1, CLOCK0, 1 }) do many[#many + 1] = x end
	end
	H.eq(p:OnMessage({ t = "PU", pv = GP.PROTOCOL, s = B, w = { B }, i = many }), GP.MAX_PER_MESSAGE)
	H.eq(p:OnMessage({ t = "PD", pv = GP.PROTOCOL, s = B, b = { 1, 2 } }), nil, "a broken digest")
	H.eq(p:OnMessage({ t = "PD", pv = GP.PROTOCOL, s = B, b = { 20000, 1, -1 } }), nil, "a negative sum")
	H.eq(p:OnMessage({ t = "PD", pv = GP.PROTOCOL, s = B, b = { 5, 1, 1 } }), false, "a day long gone is not asked for")
	p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = B, to = "x", d = { 1 } })
	g.run(70)
	H.eq(g.sent.PU, 0, "a request to nobody valid")
	-- Stop: the old guild's object sends nothing more
	p:Record({ [9] = { p = 5, n = 1 } })
	p:Stop()
	g.run(5)
	H.eq(g.sent.PU, 0, "stopped before its update left")
	H.ok(not p:Announce())
	-- 15 days later the prices are dropped
	g.t = 15 * 86400
	local count = p:Count()
	H.eq(p:Prune(), count)
	H.eq(p:Count(), 0)
	H.eq(next(a.saved.prices), nil)
end)

H.test("guild prices: 20 clients with different prices settle with bounded traffic", function()
	local g = newGuild()
	local clients = {}
	for i = 1, 20 do clients[i] = g.add(string.format("Player-1-%08X", i)) end
	-- each read some items while alone
	for i, c in ipairs(clients) do
		for _, o in ipairs(clients) do o.online = (o == c) end
		c.p:Record(reading(i * 10, i * 10 + 30, i))
		g.run(50)
	end
	for _, c in ipairs(clients) do c.online = true end
	g.bytes = 0
	g.hellos(4)
	for i = 2, 20 do H.ok(g.same(clients[1], clients[i]), "client " .. i .. " in step") end
	H.ok(g.bytes < 60000, "traffic: " .. g.bytes .. " bytes")
	-- settled: the next rounds only carry digests
	local updates, asks = g.sent.PU, g.sent.PR
	g.hellos(2)
	H.eq(g.sent.PU, updates); H.eq(g.sent.PR, asks)
end)

H.test("guild prices: an answer is sent once at a time, however often it is asked for", function()
	local g = newGuild()
	local a = g.add(A)
	g.add(B)
	local fresh = {}
	for i = 1, 600 do fresh[i] = { p = i, n = 1 } end
	a.p:Record(fresh)
	g.run(15)
	local before = g.sent.PU
	local day = math.floor(CLOCK0 / 86400)
	-- a guildmate asks every 30 s for half an hour, the day changing every time a little
	for k = 1, 60 do
		a.p:Store(10000 + k, 5, 1, CLOCK0 + 15 + k, C)
		a.p:OnMessage({ t = "PR", pv = GP.PROTOCOL, s = B, to = A, d = { day } })
		g.run(30)
	end
	local parts = g.sent.PU - before
	-- 7 parts per answer, one answer per (time of an answer + cooldown) = 70 s at most
	H.ok(parts <= 7 * math.ceil(1800 / (6 * GP.SEND_PACE + GP.ANSWER_COOLDOWN)) + 7, "bounded: " .. parts .. " parts")
	H.ok(#a.p.sendQueue <= 1, "nothing piles up: " .. #a.p.sendQueue)
end)
