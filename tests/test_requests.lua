-- Guild item requests: records, who may change what, the merge of versions, limits and expiry.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "Bugs.lua", "Requests.lua" })
local RQ = ns.Requests

local CLOCK0 = 1794615000
local A, B, C, D = "Player-1-0000000A", "Player-1-0000000B", "Player-1-0000000C", "Player-1-0000000D"

-- One client without a network: its own clock, sends collected.
local function client(guid, clock)
	local c = { sent = {}, changes = {}, t = 0, timers = {} }
	c.clock = clock or CLOCK0
	c.r = RQ.New({
		send = function(msg) c.sent[#c.sent + 1] = msg end,
		canSend = function() return true end,
		now = function() return c.t end,
		clock = function() return c.clock end,
		after = function(delay, fn) c.timers[#c.timers + 1] = { at = c.t + delay, fn = fn } end,
		random = function() return 0.5 end,
		myGuid = function() return guid end,
		onChanged = function(id, what) c.changes[#c.changes + 1] = { id = id, what = what } end,
	}, {})
	return c
end

local function copy(t)
	if type(t) ~= "table" then return t end
	local o = {}
	for k, v in pairs(t) do o[k] = copy(v) end
	return o
end

H.test("requests: create validates and limits", function()
	local a = client(A)
	local rec = a.r:Create(3865, 4305, 3, "  for my alt  ")
	H.ok(rec, "created")
	H.eq(rec.by, A); H.eq(rec.r, 3865); H.eq(rec.i, 4305); H.eq(rec.n, 3); H.eq(rec.st, "open")
	H.eq(rec.note, "for my alt", "trimmed"); H.eq(rec.c, CLOCK0); H.eq(rec.u, CLOCK0); H.eq(rec.ub, A)
	H.eq(a.r:Get(rec.id), rec)
	H.eq(select(2, a.r:Create(3865, 4305, 0)), "invalid", "count 0")
	H.eq(select(2, a.r:Create(3865, 4305, 1001)), "invalid", "count over 1000")
	H.eq(select(2, a.r:Create(3865, 4305, 1.5)), "invalid", "a fraction")
	H.eq(select(2, a.r:Create(-1, 4305, 1)), "invalid", "bad recipe")
	H.ok(a.r:Create(3865, 0, 1), "a recipe without a crafted item")
	local long = a.r:Create(3865, 4305, 1, string.rep("\195\161", 100))
	H.eq(ns.Bugs.Length(long.note), RQ.MAX_NOTE, "note cut to 80 letters")
	for _ = 4, RQ.MAX_OPEN do H.ok(a.r:Create(3865, 4305, 1)) end
	H.eq(select(2, a.r:Create(3865, 4305, 1)), "limit", "21st open request")
	-- ids are unique even within one second
	local seen = {}
	for _, r in ipairs(a.r:All()) do
		H.ok(not seen[r.id], "unique id " .. r.id)
		seen[r.id] = true
	end
end)

H.test("requests: transitions by the allowed player only", function()
	local a, b, c = client(A), client(B), client(C)
	local rec = a.r:Create(3865, 4305, 2, "")
	local function give(from, to) to.r:Merge(copy(from.r:Get(rec.id))) end
	H.eq(select(2, a.r:Take(rec.id)), "not allowed", "the requester cannot take its own")
	give(a, b); give(a, c)
	b.clock = CLOCK0 + 10
	H.ok(b.r:Take(rec.id))
	local t = b.r:Get(rec.id)
	H.eq(t.st, "taken"); H.eq(t.cr, B); H.eq(t.tk, CLOCK0 + 10); H.eq(t.ub, B)
	give(b, c)
	H.eq(select(2, c.r:GiveBack(rec.id)), "not allowed", "only the crafter gives back")
	H.eq(select(2, c.r:Done(rec.id)), "not allowed", "a third player cannot mark it done")
	H.eq(select(2, c.r:Take(rec.id)), "not allowed", "taken already")
	b.clock = CLOCK0 + 20
	H.ok(b.r:GiveBack(rec.id))
	t = b.r:Get(rec.id)
	H.eq(t.st, "open"); H.eq(t.cr, nil); H.eq(t.g[1][2], B, "remembers the take it gave back")
	give(b, c)
	c.clock = CLOCK0 + 30
	H.ok(c.r:Take(rec.id), "taken again by another")
	give(c, a)
	a.clock = CLOCK0 + 40
	H.ok(a.r:Done(rec.id), "the requester marks it done")
	H.eq(a.r:Get(rec.id).st, "done")
	H.eq(select(2, a.r:Cancel(rec.id)), "not allowed", "done is final")
	-- the requester cancels an open one; the crafter marks a taken one done
	local r2 = a.r:Create(3865, 4305, 1)
	H.eq(select(2, b.r:Cancel(r2.id)), "unknown")
	b.r:Merge(copy(r2))
	H.eq(select(2, b.r:Cancel(r2.id)), "not allowed", "only the requester cancels")
	H.ok(a.r:Cancel(r2.id)); H.eq(a.r:Get(r2.id).st, "cancelled")
	local r3 = a.r:Create(3865, 4305, 1)
	b.r:Merge(copy(r3)); b.clock = CLOCK0 + 50
	H.ok(b.r:Take(r3.id)); H.ok(b.r:Done(r3.id), "the crafter marks it done")
	-- a change always moves the version forward, even in the same second
	local r4 = a.r:Create(3865, 4305, 1)
	local u = a.r:Get(r4.id).u
	H.ok(a.r:Cancel(r4.id)); H.ok(a.r:Get(r4.id).u > u)
end)

H.test("requests: two takes, the earlier wins everywhere", function()
	local a, b, c, x, y = client(A), client(B), client(C), client(D), client("Player-1-0000000E")
	local rec = a.r:Create(3865, 4305, 1)
	for _, o in ipairs({ b, c, x, y }) do o.r:Merge(copy(rec)) end
	b.clock, c.clock = CLOCK0 + 10, CLOCK0 + 12
	H.ok(b.r:Take(rec.id)); H.ok(c.r:Take(rec.id))
	local tb, tc = copy(b.r:Get(rec.id)), copy(c.r:Get(rec.id))
	-- x hears b first, y hears c first
	H.ok(x.r:Merge(copy(tb))); H.ok(not x.r:Merge(copy(tc)), "the later take loses")
	H.ok(y.r:Merge(copy(tc))); H.ok(y.r:Merge(copy(tb)), "the earlier take wins although its change is older")
	H.eq(x.r:Get(rec.id).cr, B); H.eq(y.r:Get(rec.id).cr, B)
	-- c learns it lost
	H.ok(c.r:Merge(copy(tb))); H.eq(c.r:Get(rec.id).cr, B)
	H.eq(c.changes[#c.changes].what, "taken")
	-- the same time: the lower guid wins
	local r2 = a.r:Create(3865, 4305, 1)
	b.r:Merge(copy(r2)); c.r:Merge(copy(r2))
	b.clock, c.clock = CLOCK0 + 20, CLOCK0 + 20
	b.r:Take(r2.id); c.r:Take(r2.id)
	H.ok(c.r:Merge(copy(b.r:Get(r2.id)))); H.ok(not b.r:Merge(copy(c.r:Get(r2.id))))
	H.eq(c.r:Get(r2.id).cr, B)
	-- the winner gives it back: a client still holding the losing take accepts that too
	local z = client("Player-1-0000000F")
	z.r:Merge(copy(rec)); z.r:Merge(copy(tc)) -- z only ever heard c's losing take
	b.clock = CLOCK0 + 30
	H.ok(b.r:GiveBack(rec.id))
	H.ok(z.r:Merge(copy(b.r:Get(rec.id))), "the give-back of the earlier take")
	H.eq(z.r:Get(rec.id).st, "open")
	-- and a done by the winner reaches a client that holds the losing take
	local w = client("Player-1-00000010")
	local r3 = a.r:Create(3865, 4305, 1)
	b.r:Merge(copy(r3)); c.r:Merge(copy(r3)); w.r:Merge(copy(r3))
	b.clock, c.clock = CLOCK0 + 40, CLOCK0 + 41
	b.r:Take(r3.id); c.r:Take(r3.id)
	w.r:Merge(copy(c.r:Get(r3.id)))
	b.clock = CLOCK0 + 50
	b.r:Done(r3.id)
	H.ok(w.r:Merge(copy(b.r:Get(r3.id)))); H.eq(w.r:Get(r3.id).st, "done"); H.eq(w.r:Get(r3.id).cr, B)
	-- the losing taker cannot finish it
	H.ok(not w.r:Merge((function()
		local f = copy(c.r:Get(r3.id)); f.st = "done"; f.u = CLOCK0 + 60; f.ub = C
		return f
	end)()), "a done that rests on the losing take")
end)

H.test("requests: a stale take does not reopen or steal a request", function()
	local a, b, c = client(A), client(B), client(C)
	local rec = a.r:Create(3865, 4305, 1)
	b.r:Merge(copy(rec)); c.r:Merge(copy(rec))
	b.clock = CLOCK0 + 10
	b.r:Take(rec.id)
	local take = copy(b.r:Get(rec.id))
	c.r:Merge(copy(take))
	b.clock = CLOCK0 + 20
	b.r:GiveBack(rec.id)
	c.r:Merge(copy(b.r:Get(rec.id)))
	H.ok(not c.r:Merge(copy(take)), "the old take arriving late")
	H.eq(c.r:Get(rec.id).st, "open")
	-- done is final against a late take
	a.r:Merge(copy(take)); a.clock = CLOCK0 + 15
	a.r:Done(rec.id)
	local done = copy(a.r:Get(rec.id))
	H.ok(not a.r:Merge(copy(b.r:Get(rec.id))), "a give-back after done")
	H.eq(a.r:Get(rec.id).st, "done")
	-- two finals: the earlier one wins everywhere
	local r2 = a.r:Create(3865, 4305, 1)
	b.r:Merge(copy(r2)); b.clock = CLOCK0 + 30; b.r:Take(r2.id); a.r:Merge(copy(b.r:Get(r2.id)))
	a.clock, b.clock = CLOCK0 + 40, CLOCK0 + 41
	a.r:Cancel(r2.id); b.r:Done(r2.id)
	local cancel, fin = copy(a.r:Get(r2.id)), copy(b.r:Get(r2.id))
	H.ok(not a.r:Merge(copy(fin))); H.ok(b.r:Merge(copy(cancel)))
	H.eq(a.r:Get(r2.id).st, "cancelled"); H.eq(b.r:Get(r2.id).st, "cancelled")
	H.ok(done)
end)

H.test("requests: forged or broken records are rejected", function()
	local a, b, c = client(A), client(B), client(C)
	local rec = a.r:Create(3865, 4305, 2, "x")
	c.r:Merge(copy(rec))
	-- a stranger cancels someone else's request
	local f = copy(rec); f.st = "cancelled"; f.u = CLOCK0 + 5; f.ub = B
	H.ok(not c.r:Merge(f), "cancel by a stranger")
	-- changing what was asked for
	f = copy(rec); f.n = 99; f.u = CLOCK0 + 5
	H.ok(not c.r:Merge(f), "count changed")
	f = copy(rec); f.i = 1; f.u = CLOCK0 + 5
	H.ok(not c.r:Merge(f), "item changed")
	-- the requester taking its own
	f = copy(rec); f.st = "taken"; f.cr = A; f.tk = CLOCK0 + 5; f.u = CLOCK0 + 5; f.ub = A
	H.ok(not c.r:Merge(f), "own take")
	-- broken shapes
	for _, bad in ipairs({
		{}, { id = "x" }, (function() local x = copy(rec); x.st = "weird"; return x end)(),
		(function() local x = copy(rec); x.by = "Creature-1"; return x end)(),
		(function() local x = copy(rec); x.n = 0; return x end)(),
		(function() local x = copy(rec); x.note = string.rep("a", 500); return x end)(),
		(function() local x = copy(rec); x.u = CLOCK0 + 99999; return x end)(),
		(function() local x = copy(rec); x.st = "taken"; x.u = CLOCK0 + 9; x.ub = B; return x end)(), -- taken without crafter
		"text",
	}) do
		H.ok(not b.r:Merge(bad), "broken record")
	end
	H.eq(#b.r:All(), 0)
end)

H.test("requests: expiry after 7 days open, 2 days finished; the guild limit", function()
	local a, b = client(A), client(B)
	local open = a.r:Create(3865, 4305, 1)
	local fin = a.r:Create(3865, 4305, 1)
	a.clock = CLOCK0 + 10
	a.r:Cancel(fin.id)
	a.clock = CLOCK0 + 2 * 86400 + 20
	H.eq(a.r:Prune(), 1, "the cancelled one after 2 days")
	H.ok(a.r:Get(open.id))
	a.clock = CLOCK0 + 7 * 86400 + 1
	H.eq(a.r:Prune(), 1, "the open one after 7 days")
	-- an expired record from a client that has not pruned yet is not taken again
	b.clock = CLOCK0 + 7 * 86400 + 1
	H.ok(not b.r:Merge(copy(open)), "expired")
	-- the guild holds at most MAX_RECORDS
	local cs = {}
	for i = 1, 11 do cs[i] = client(string.format("Player-1-%08X", 100 + i), b.clock) end
	local taken = 0
	for _, x in ipairs(cs) do
		for _ = 1, RQ.MAX_OPEN do
			local r = x.r:Create(3865, 4305, 1)
			if b.r:Merge(copy(r)) then taken = taken + 1 end
		end
	end
	H.eq(taken, RQ.MAX_RECORDS); H.eq(#b.r:All(), RQ.MAX_RECORDS)
	-- All: open first, newest first
	local all = b.r:All()
	H.ok(all[1].c >= all[#all].c)
end)

-- A guild where every message reaches every online client after the serializer round trip.
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")
local function newGuild()
	local g = { t = 0, timers = {}, clients = {}, sent = { TU = 0, TD = 0, TR = 0 }, bytes = 0 }
	function g.add(guid)
		local c = { guid = guid, online = true, blocked = false, saved = {}, changes = {} }
		c.r = RQ.New({
			send = function(msg)
				g.sent[msg.t] = g.sent[msg.t] + 1
				local text = LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg)))
				assert(#text < 24000)
				g.bytes = g.bytes + #text
				for _, o in ipairs(g.clients) do
					if o.online then
						local ok, m = LS:Deserialize(LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(text)))
						assert(ok)
						o.r:OnMessage(m)
					end
				end
			end,
			canSend = function() return c.online and not c.blocked end,
			now = function() return g.t end,
			clock = function() return CLOCK0 + math.floor(g.t) end,
			after = function(delay, fn) g.timers[#g.timers + 1] = { at = g.t + delay, fn = fn, owner = c } end,
			random = function() return 0.5 end,
			myGuid = function() return guid end,
			onChanged = function(id, what) c.changes[#c.changes + 1] = { id = id, what = what } end,
		}, c.saved)
		g.clients[#g.clients + 1] = c
		return c
	end
	function g.run(seconds)
		local target = g.t + seconds
		while true do
			table.sort(g.timers, function(a, b) return a.at < b.at end)
			local nt = g.timers[1]
			if not nt or nt.at > target then break end
			table.remove(g.timers, 1)
			g.t = nt.at
			if nt.owner.online then nt.fn() end
		end
		g.t = target
	end
	function g.hellos()
		for _, c in ipairs(g.clients) do if c.online then c.r:Announce() end end
		g.run(120)
	end
	function g.same(a, b)
		local x, y = a.r:All(), b.r:All()
		if #x ~= #y then return false end
		for i = 1, #x do
			if x[i].id ~= y[i].id or x[i].u ~= y[i].u or x[i].st ~= y[i].st or x[i].cr ~= y[i].cr then return false end
		end
		return true
	end
	return g
end

H.test("requests sync: a new request reaches everybody, also a player who logs in later", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	local rec = a.r:Create(3865, 4305, 2, "pls")
	g.run(5)
	H.eq(g.sent.TU, 1, "sent at once")
	H.ok(b.r:Get(rec.id), "B has it"); H.eq(b.r:Get(rec.id).note, "pls")
	H.eq(b.changes[#b.changes].what, "new")
	-- C logs in later and says hello: gets it from an answering digest and a request
	local c = g.add(C)
	c.r:Announce()
	g.run(60)
	H.ok(c.r:Get(rec.id), "C has it without waiting for another hello")
	H.ok(g.same(a, c))
	-- a guild in step: digests only
	local tu, tr = g.sent.TU, g.sent.TR
	g.hellos(); g.hellos()
	H.eq(g.sent.TU, tu); H.eq(g.sent.TR, tr)
end)

H.test("requests sync: a take raced by two crafters settles on the earlier one everywhere", function()
	local g = newGuild()
	local a, b, c, d = g.add(A), g.add(B), g.add(C), g.add(D)
	local rec = a.r:Create(3865, 4305, 1)
	g.run(5)
	-- B and C take while cut off from each other
	c.online = false
	g.run(1)
	H.ok(b.r:Take(rec.id))
	g.run(3)
	c.online, b.online = true, false
	g.run(2)
	H.ok(c.r:Take(rec.id))
	g.run(3)
	b.online = true
	g.hellos(); g.hellos()
	for _, x in ipairs({ a, c, d }) do
		H.eq(x.r:Get(rec.id).cr, B, "the earlier take everywhere")
	end
	H.ok(g.same(a, b) and g.same(b, c) and g.same(c, d))
end)

H.test("requests sync: a blocked send arrives through the next digest", function()
	local g = newGuild()
	local a, b = g.add(A), g.add(B)
	a.blocked = true
	local rec = a.r:Create(3865, 4305, 1)
	g.run(5)
	H.eq(b.r:Get(rec.id), nil)
	a.blocked = false
	g.hellos()
	H.ok(b.r:Get(rec.id))
	-- B takes, A was offline; A learns it at its next hello
	a.online = false
	b.r:Take(rec.id)
	g.run(5)
	a.online = true
	a.r:Announce()
	g.run(60)
	H.eq(a.r:Get(rec.id).st, "taken")
	H.eq(a.changes[#a.changes].what, "taken")
end)

H.test("requests sync: bad messages are ignored", function()
	local g = newGuild()
	local a = g.add(A)
	local b = g.add(B)
	local rec = b.r:Create(3865, 4305, 1)
	g.run(5)
	local n = #a.r:All()
	a.r:OnMessage({ t = "TU", pv = 99, s = B, q = { rec } })
	a.r:OnMessage({ t = "TU", pv = RQ.PROTOCOL, s = "x", q = { rec } })
	a.r:OnMessage({ t = "TU", pv = RQ.PROTOCOL, s = B, q = "x" })
	local many = {}
	for i = 1, RQ.MAX_PER_MESSAGE + 5 do
		many[i] = { id = C .. "-" .. CLOCK0 .. "-" .. (100 + i), by = C, r = 3865, i = 4305, n = 1, note = "",
			c = CLOCK0, st = "open", u = CLOCK0, ub = C }
	end
	a.r:OnMessage({ t = "TU", pv = RQ.PROTOCOL, s = B, q = many })
	H.eq(#a.r:All(), n + RQ.MAX_PER_MESSAGE, "the rest of an oversized update is not read")
	a.r:OnMessage({ t = "TD", pv = RQ.PROTOCOL, s = B, x = { 1, 2, 3 } })
	a.r:OnMessage({ t = "TR", pv = RQ.PROTOCOL, s = B, to = A, ids = "x" })
	a.r:OnMessage({ t = "TR", pv = RQ.PROTOCOL, s = A, to = A, ids = { rec.id } }) -- own echo
	g.run(60)
end)

H.test("requests sync: 15 clients settle, then only digests", function()
	local g = newGuild()
	local cs = {}
	for i = 1, 15 do cs[i] = g.add(string.format("Player-1-%08X", 200 + i)) end
	-- each creates requests while alone
	for i, c in ipairs(cs) do
		for _, o in ipairs(cs) do o.online = (o == c) end
		for _ = 1, 3 do c.r:Create(3865, 4305, i) end
		g.run(10)
	end
	for _, c in ipairs(cs) do c.online = true end
	g.bytes = 0
	g.hellos(); g.hellos(); g.hellos()
	for i = 2, 15 do H.ok(g.same(cs[1], cs[i]), "client " .. i .. " in step") end
	H.eq(#cs[1].r:All(), 45)
	H.ok(g.bytes < 120000, "traffic " .. g.bytes)
	local tu, tr = g.sent.TU, g.sent.TR
	g.hellos()
	H.eq(g.sent.TU, tu); H.eq(g.sent.TR, tr)
end)
