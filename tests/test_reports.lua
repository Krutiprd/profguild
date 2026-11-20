-- Bug reports relayed through the guild: records, limits, delivery marks and the exchange.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "Bugs.lua", "Reports.lua" })
local RP = ns.Reports

local CLOCK0 = 1794615000
local A, B, C, R = "Player-1-0000000A", "Player-1-0000000B", "Player-1-0000000C", "Player-1-000000FF"

-- One client: its own clock and timers, sends collected. R is the receiver.
local function client(guid, opts)
	opts = opts or {}
	local c = { guid = guid, sent = {}, changes = {}, delivered = {}, t = 0, timers = {}, online = true }
	c.clock = CLOCK0
	c.inGuild = opts.inGuild ~= false
	c.r = RP.New({
		send = function(msg) c.sent[#c.sent + 1] = msg end,
		canSend = function() return c.online end,
		now = function() return c.t end,
		clock = function() return c.clock end,
		after = function(delay, fn) c.timers[#c.timers + 1] = { at = c.t + delay, fn = fn } end,
		random = function() return 0.5 end,
		myGuid = function() return guid end,
		isReceiver = function() return guid == R end,
		receiverInGuild = function() return c.inGuild end,
		deliver = function(rec) c.delivered[#c.delivered + 1] = rec end,
		onChanged = function(id, what) c.changes[#c.changes + 1] = { id = id, what = what } end,
	}, {})
	return c
end

local function idOf(guid, n, t) return guid .. ":" .. (t or CLOCK0) .. ":" .. n end

local function copy(t)
	if type(t) ~= "table" then return t end
	local o = {}
	for k, v in pairs(t) do o[k] = copy(v) end
	return o
end

local function report(n, text)
	return {
		n = n, t = CLOCK0, v = "0.5.0", who = "Ana-Whychuck", text = text or ("broken " .. n),
		ctx = { "view: recipes", "recipe: Stonescale Oil" },
		errors = { { msg = "Profguild/UI.lua:1: oops", stack = "stack", count = 2, t = CLOCK0, v = "0.5.0" } },
		log = { "line 1", "line 2" },
	}
end

-- Runs every client's timers up to its time + dt and hands every sent message to the others
-- that are online, until nothing moves.
local function run(clients, dt)
	for _, c in ipairs(clients) do c.t = c.t + (dt or 0) end
	for _ = 1, 200 do
		local moved = false
		for _, c in ipairs(clients) do
			local due = {}
			for i = #c.timers, 1, -1 do
				if c.timers[i].at <= c.t then
					due[#due + 1] = c.timers[i]
					table.remove(c.timers, i)
				end
			end
			table.sort(due, function(x, y) return x.at < y.at end)
			for _, tm in ipairs(due) do tm.fn(); moved = true end
		end
		for _, c in ipairs(clients) do
			local out = c.sent
			c.sent = {}
			for _, msg in ipairs(out) do
				moved = true
				for _, o in ipairs(clients) do
					if o ~= c and o.online then o.r:OnMessage(copy(msg)) end
				end
			end
		end
		if not moved then return end
	end
	error("the exchange did not settle")
end

local function settle(clients)
	for _ = 1, 30 do run(clients, 10) end
end

H.test("reports: a shared report is checked, cut and kept", function()
	local a = client(A)
	local rec = a.r:Share(report(1))
	H.ok(rec, "shared")
	H.eq(rec.id, idOf(A, 1)); H.eq(rec.by, A); H.eq(rec.st, "h"); H.eq(rec.text, "broken 1")
	H.eq(rec.who, "Ana-Whychuck"); H.eq(rec.ctx[2], "recipe: Stonescale Oil"); H.eq(rec.errors[1].count, 2)
	H.eq(a.r:Get(rec.id), rec)
	H.eq(a.r:Share(report(1)), nil, "the same report twice")
	local big = report(2, string.rep("a", 1500))
	big.ctx = {}
	for i = 1, 40 do big.ctx[i] = string.rep("x", 500) end
	big.junk = "dropped"
	local r2 = a.r:Share(big)
	H.eq(ns.Bugs.Length(r2.text), RP.MAX_TEXT, "text cut to 1000 letters")
	H.eq(ns.Bugs.Length(a.r:Share(report(3, string.rep("\195\161", 1500))).text), RP.MAX_TEXT, "letters, not bytes")
	H.eq(#r2.ctx, RP.MAX_LINES, "20 context lines")
	H.eq(#r2.ctx[1], RP.MAX_LINE, "a line cut to 200 characters")
	H.eq(r2.junk, nil, "unknown fields dropped")
	H.eq(a.r:Share({ n = 3, t = CLOCK0, text = "   " }), nil, "an empty text")
end)

H.test("reports: merge refuses broken, foreign and old records", function()
	local a, b = client(A), client(B)
	local rec = copy(a.r:Share(report(1)))
	H.ok(b.r:Merge(copy(rec)), "stored")
	H.eq(b.r:Merge(copy(rec)), false, "already held")
	local bad = copy(rec); bad.id = idOf(B, 1)
	H.eq(b.r:Merge(bad), false, "the id names another reporter")
	bad = copy(rec); bad.id = A .. ":" .. CLOCK0 .. ":x"
	H.eq(b.r:Merge(bad), false, "not a number")
	bad = copy(rec); bad.id = A .. ":2"
	H.eq(b.r:Merge(bad), false, "an id without the time")
	bad = copy(rec); bad.id = idOf(A, 2); bad.text = 5
	H.eq(b.r:Merge(bad), false, "text not a string")
	bad = copy(rec); bad.id = idOf(A, 3); bad.t = CLOCK0 + RP.MAX_AHEAD + 10
	H.eq(b.r:Merge(bad), false, "from the future")
	bad = copy(rec); bad.id = idOf(A, 4); bad.t = CLOCK0 - RP.KEEP - 1
	H.eq(b.r:Merge(bad), false, "too old")
	bad = copy(rec); bad.id = idOf(A, 5); bad.st = "d"
	H.eq(b.r:Merge(bad), false, "an update carries only held reports")
	bad = copy(rec); bad.id = idOf(A, 6); bad.text = string.rep(" ", 1200) .. "x"
	H.eq(b.r:Merge(bad), false, "blank once cut to 1000 letters")
	H.eq(b.changes[1].what, "new")
	H.eq(#b.changes, 1)
end)

H.test("reports: the receiver takes the report and marks it delivered", function()
	local a, r = client(A), client(R)
	local rec = a.r:Share(report(1))
	H.ok(r.r:Merge(copy(rec)))
	H.eq(#r.delivered, 1, "handed to the inbox")
	H.eq(r.delivered[1].text, "broken 1")
	local held = r.r:Get(rec.id)
	H.eq(held.st, "d"); H.eq(held.text, nil, "no text kept"); H.eq(held.t, CLOCK0)
	H.ok(not r.r:Merge(copy(rec)), "not again")
	H.eq(#r.delivered, 1)
	-- the receiver's own report goes to the inbox at once, nothing is held
	local own = r.r:Share(report(7))
	H.eq(own.st, "d"); H.eq(#r.delivered, 2)
end)

H.test("reports: a report reaches the receiver through a third player", function()
	local a, b, r = client(A), client(B), client(R)
	local clients = { a, b, r }
	r.online = false
	local rec = a.r:Share(report(1))
	a.r:Announce()
	settle(clients)
	H.ok(b.r:Get(rec.id) and b.r:Get(rec.id).st == "h", "B carries it")
	-- A leaves, the receiver comes
	a.online, r.online = false, true
	r.r:Announce()
	b.r:Announce()
	settle(clients)
	H.eq(#r.delivered, 1, "delivered")
	H.eq(r.delivered[1].id, rec.id)
	H.eq(b.r:Get(rec.id).st, "d", "B dropped the text")
	-- A comes back: the mark reaches it
	a.online, r.online = true, false
	b.r:Announce()
	settle(clients)
	H.eq(a.r:Get(rec.id).st, "d", "A knows it was delivered")
	local seen = false
	for _, ch in ipairs(a.changes) do
		if ch.id == rec.id and ch.what == "delivered" then seen = true end
	end
	H.ok(seen, "A was told")
	H.eq(#r.delivered, 1, "only once")
end)

H.test("reports: nothing leaves a guild without a receiver", function()
	local a, b = client(A, { inGuild = false }), client(B, { inGuild = false })
	local rec = a.r:Share(report(1))
	H.eq(a.r:Announce(), false, "no digest")
	b.r:Announce()
	settle({ a, b })
	H.eq(b.r:Get(rec.id), nil, "B never got it")
	-- a receiver joins: the report goes out
	a.inGuild, b.inGuild = true, true
	a.r:Announce()
	settle({ a, b })
	H.ok(b.r:Get(rec.id), "now it does")
end)

H.test("reports: a delivery mark in a digest spreads without the text", function()
	local a, b, c = client(A), client(B), client(C)
	local rec = a.r:Share(report(1))
	H.ok(b.r:Merge(copy(rec)))
	H.ok(b.r:MarkDelivered(rec.id, rec.t), "marked")
	b.r:Announce()
	settle({ a, b, c })
	H.eq(a.r:Get(rec.id).st, "d")
	H.eq(c.r:Get(rec.id).st, "d", "C learned the mark, never the text")
	H.eq(c.r:Get(rec.id).text, nil)
	-- a held copy from a player who was away does not bring the text back
	H.eq(c.r:Merge(copy(rec)), false)
end)

H.test("reports: limits keep the newest, and a digest asks only for what would be kept", function()
	local x = client(C)
	-- 10 per reporter: the oldest of that reporter goes
	for n = 1, RP.MAX_PER_REPORTER + 1 do
		local r = report(n)
		r.t = CLOCK0 - 1000 + n
		local rec = copy(client(A).r:Share(r))
		x.r:Merge(rec)
	end
	H.eq(x.r:HeldCount(), RP.MAX_PER_REPORTER)
	H.eq(x.r:Get(idOf(A, 1, CLOCK0 - 999)), nil, "the oldest of A went")
	H.ok(x.r:Get(idOf(A, 11, CLOCK0 - 989)))
	-- an older one of A than all held is not taken
	local old = report(50); old.t = CLOCK0 - 5000
	H.eq(x.r:Merge(copy(client(A).r:Share(old))), false, "older than all ten")
	-- the guild limit: many reporters
	local n = 0
	for i = 1, 20 do
		local guid = string.format("Player-1-%08X", 100 + i)
		for k = 1, 5 do
			n = n + 1
			local r = report(k); r.t = CLOCK0 - 900 + n
			x.r:Merge(copy(client(guid).r:Share(r)))
		end
	end
	H.eq(x.r:HeldCount(), RP.MAX_HELD, "60 held")
	-- a digest listing an old report: not asked for
	local holder = client(B)
	local oldest = report(1); oldest.t = CLOCK0 - 4000
	local hrec = holder.r:Share(oldest)
	H.ok(hrec)
	holder.r:Announce()
	local digest = holder.sent[#holder.sent]
	H.eq(x.r:OnMessage(copy(digest)), false, "nothing wanted")
end)

H.test("reports: old records go after 14 days", function()
	local a = client(A)
	local rec = a.r:Share(report(1))
	H.ok(a.r:MarkDelivered(idOf("Player-1-00000077", 3), CLOCK0))
	a.clock = CLOCK0 + RP.KEEP + 1
	H.eq(a.r:Prune(), 2)
	H.eq(a.r:Get(rec.id), nil)
end)

H.test("reports: a broken digest or request is ignored", function()
	local a = client(A)
	H.eq(a.r:OnMessage({ t = "BD", pv = RP.PROTOCOL, s = B, x = { "a", "h" } }), nil, "not triples")
	H.eq(a.r:OnMessage({ t = "BD", pv = RP.PROTOCOL, s = "x", x = {} }), nil, "bad sender")
	H.eq(a.r:OnMessage({ t = "BD", pv = RP.PROTOCOL + 1, s = B, x = {} }), nil, "newer protocol")
	a.r:OnMessage({ t = "BR", pv = RP.PROTOCOL, s = B, to = A, ids = { 1, {}, string.rep("x", 200) } })
	a.r:OnMessage({ t = "BU", pv = RP.PROTOCOL, s = B, q = "junk" })
	H.eq(a.r:HeldCount(), 0)
end)

H.test("reports: a big record is trimmed to fit a message, the log first", function()
	local a = client(A)
	local r = report(1, string.rep("\195\161", 1000))
	r.log, r.ctx = {}, {}
	for i = 1, 15 do r.log[i] = string.rep("l", 200) end
	for i = 1, 20 do r.ctx[i] = string.rep("c", 200) end
	r.errors = {}
	for i = 1, 5 do r.errors[i] = { msg = string.rep("m", 400), stack = string.rep("s", 600), count = 1 } end
	local rec = a.r:Share(r)
	H.ok(rec, "shared")
	H.eq(#rec.text, 2000, "the text is whole")
	H.eq(#rec.log, 0, "the log went")
	local size = #rec.text + #rec.who + #rec.v
	for _, l in ipairs(rec.ctx) do size = size + #l + 2 end
	for _, e in ipairs(rec.errors) do size = size + #e.msg + #(e.stack or "") + 20 end
	H.ok(size <= RP.MAX_BYTES, "under the budget: " .. size)
	-- two of them in one update fit the channel's limit
	H.loadLibs()
	local LibSerialize, LibDeflate = LibStub("LibSerialize"), LibStub("LibDeflate")
	local msg = { t = "BU", pv = 1, s = A, q = { rec, rec } }
	local text = LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(LibSerialize:Serialize(msg)))
	H.ok(#text < 24000, "encoded " .. #text)
end)

H.test("reports: a full guild settles, and then nothing more is sent", function()
	local a, b, c = client(A), client(B), client(C)
	local clients = { a, b, c }
	-- 60 held reports and 140 marks, spread over the three
	for i = 1, RP.MAX_HELD do
		local guid = string.format("Player-1-%08X", 300 + i) -- not R (0xFF)
		local r = report(1); r.t = CLOCK0 - 5000 + i
		local rec = client(guid).r:Share(r)
		clients[1 + i % 3].r:Merge(copy(rec))
	end
	for i = 1, RP.MAX_MARKS + 20 do
		clients[1 + i % 3].r:MarkDelivered(idOf(string.format("Player-1-%08X", 900 + i), 1, CLOCK0 - 3000 + i), CLOCK0 - 3000 + i)
	end
	-- a hello (and our digest) every 15 minutes; 6 reports are asked for at once
	for _ = 1, 8 do
		for _, cl in ipairs(clients) do cl.r:Announce() end
		settle(clients)
		for _, cl in ipairs(clients) do cl.t = cl.t + 600 end
	end
	H.eq(b.r:HeldCount(), RP.MAX_HELD); H.eq(b.r:MarkCount(), RP.MAX_MARKS)
	H.eq(a.r:HeldCount(), RP.MAX_HELD); H.eq(c.r:MarkCount(), RP.MAX_MARKS)
	-- quiet: ten more minutes without a message
	local sent = 0
	for _, cl in ipairs(clients) do sent = sent + cl.r.stats.sentU + cl.r.stats.sentD + cl.r.stats.sentR end
	for _, cl in ipairs(clients) do cl.r:Announce() end
	settle(clients)
	settle(clients)
	local after = 0
	for _, cl in ipairs(clients) do after = after + cl.r.stats.sentU + cl.r.stats.sentD + cl.r.stats.sentR end
	H.eq(after - sent, 3, "only the three digests we asked for")
end)

H.test("reports: a receiver takes the held reports already saved", function()
	local saved = {}
	local a = client(A)
	local rec = a.r:Share(report(1))
	saved.reports = { [rec.id] = copy(rec) }
	local delivered = {}
	local r = RP.New({
		send = function() end, canSend = function() return true end, now = function() return 0 end,
		clock = function() return CLOCK0 end, after = function() end, random = function() return 0.5 end,
		myGuid = function() return R end, isReceiver = function() return true end,
		receiverInGuild = function() return true end,
		deliver = function(x) delivered[#delivered + 1] = x end,
	}, saved)
	H.eq(r:TakeHeld(), 1)
	H.eq(#delivered, 1); H.eq(delivered[1].text, "broken 1")
	H.eq(r:Get(rec.id).st, "d")
	H.eq(r:TakeHeld(), 0, "once")
end)

H.test("reports: a text of junk bytes is cut to its byte limit", function()
	local a = client(A)
	local r = report(1, string.rep("a" .. string.rep("\128", 100), 1000))
	local rec = a.r:Share(r)
	H.ok(rec)
	H.ok(#rec.text <= 4 * RP.MAX_TEXT, "bytes " .. #rec.text)
end)

H.test("reports: our own report is not pushed out by the guild's newer ones", function()
	local x = client(C)
	local mine = x.r:Share(report(1))
	mine = x.r:Get(mine.id)
	for i = 1, RP.MAX_HELD + 5 do
		local guid = string.format("Player-1-%08X", 400 + i)
		local r = report(1); r.t = CLOCK0 + 1 + (i % 5)
		x.r:Merge(copy(client(guid).r:Share(r)))
	end
	H.ok(x.r:Get(mine.id), "ours is still there")
	local others = x.r:HeldCount() - 1
	H.eq(others, RP.MAX_HELD, "the guild's limit counts the others")
end)

H.test("reports: the rest of a holder's reports is asked for right after its answer", function()
	local h, w = client(A), client(B)
	for n = 1, 9 do
		local r = report(n); r.t = CLOCK0 - 100 + n
		h.r:Share(r)
	end
	h.sent = {}
	w.r:Announce()
	h.r:Announce()
	for _ = 1, 8 do run({ h, w }, 10) end -- the holder answers every ANSWER_COOLDOWN
	H.eq(w.r:HeldCount(), 9, "all nine")
	H.eq(w.r.stats.sentD + h.r.stats.sentD, 2, "without another digest")
	H.eq(w.r.stats.sentR, 2, "two requests: 6, then the other 3")
end)
