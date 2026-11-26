-- NpcWork: the one scheduler of the NPC work, and the tables and NpcSync running on it. A fake cost
-- model makes the budget tests deterministic: the clock is a meter of the entries the sheet functions
-- of NpcData handled (Pack, Unpack, Valid, Merge, HashSheet, Visit), whatever the code declares with
-- Pace; so a path that does much work without pacing shows as a frame over the budget.
local H = ...
H.loadLibs()
local LS = LibStub("LibSerialize")

-- The namespace, metered: the sheet functions add their entries to `meter` (loaded before
-- NpcTable and NpcSync, which keep them as locals).
local meter = 0
local ns = {}
H.loadAddonFile(ns, "NpcWork.lua")
H.loadAddonFile(ns, "NpcData.lua")
local ND, NW = ns.NpcData, ns.NpcWork
do
	local function entries(s)
		local n = 0
		if type(s) == "table" then
			for _ in pairs(type(s.t) == "table" and s.t or {}) do n = n + 1 end
			for _ in pairs(type(s.v) == "table" and s.v or {}) do n = n + 1 end
		end
		return n
	end
	local function listEntries(l)
		if type(l) ~= "table" then return 0 end
		return (type(l[9]) == "table" and #l[9] or 0) + (type(l[15]) == "table" and #l[15] or 0)
	end
	local I = ND.internal
	local pack, unpack_, valid, merge, hash, visit, same = ND.Pack, ND.Unpack, ND.Valid, ND.Merge, ND.HashSheet,
		ND.Visit, I.unpackSame
	ND.Pack = function(id, s) meter = meter + entries(s) return pack(id, s) end
	ND.Unpack = function(l, d) meter = meter + listEntries(l) return unpack_(l, d) end
	ND.Valid = function(s, d) meter = meter + entries(s) return valid(s, d) end
	ND.Merge = function(a, b) meter = meter + entries(a) + entries(b) return merge(a, b) end
	ND.HashSheet = function(id, s) meter = meter + entries(s) return hash(id, s) end
	ND.Visit = function(h, r, d, l)
		local m, c = visit(h, r, d, l)
		meter = meter + entries(m) + entries(h)
		return m, c
	end
	I.unpackSame = function(l, d) meter = meter + listEntries(l) return same(l, d) end
end
H.loadAddonFile(ns, "NpcTable.lua")
H.loadAddonFile(ns, "NpcSync.lua")
local NS = ns.NpcSync

local CLOCK0 = 1794615000
local DAY = math.floor(CLOCK0 / 86400)

local function deepEq(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end
local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end
-- what the game writes to SavedVariables and reads back at the next login
local function reloadCopy(v)
	local ok, x = LS:Deserialize(LS:Serialize(v))
	assert(ok, "serialize")
	return x
end

-- A scheduler on the meter: frames counted by hand. Per frame the metered work is recorded
-- (the caller's own part included).
local function meteredWork(budget)
	local w
	local frame, pending, errors = 0, {}, {}
	w = NW.New({ clock = function() return meter end, frame = function() return frame end,
		defer = function(fn) pending[#pending + 1] = fn end, budget = function() return budget end,
		rate = 1, error = function(e, stack) errors[#errors + 1] = tostring(stack or e) end })
	w.errors = errors
	w.frames, w.maxFrame = 0, 0
	-- one frame of the game: the deferred slice
	function w.step()
		if not pending[1] then return false end
		frame = frame + 1
		local m0 = meter
		local p = pending
		pending = {}
		for _, fn in ipairs(p) do fn() end
		local d = meter - m0
		w.frames = w.frames + 1
		if d > w.maxFrame then w.maxFrame = d end
		return true
	end
	-- fn in a frame of its own, then every frame the work asks for
	function w.inFrame(fn)
		frame = frame + 1
		local m0 = meter
		fn()
		local d = meter - m0
		w.frames = w.frames + 1
		if d > w.maxFrame then w.maxFrame = d end
	end
	function w.pump()
		local n = 0
		while w.step() do n = n + 1 end
		return n
	end
	function w.reset() w.frames, w.maxFrame = 0, 0 end
	return w
end

-- Full tables: 600 sheets and 20000 entries (100 trainers of 152 recipes, 500 vendors of 11 items).
local seed
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return math.floor(seed / 2147483648 * n) end
local function trainer(id, n, idBase)
	local s = { name = "Trainer " .. id, nd = DAY - rnd(100), map = 1400 + rnd(60), x = rnd(100), y = rnd(100),
		pd = DAY - rnd(100), t = {}, v = {} }
	for i = 1, n do
		local d = DAY - rnd(110)
		s.t[idBase + i * 7 + rnd(5)] = { d, 1 + rnd(300), d, 100 + rnd(100000), d }
	end
	return s
end
local function vendor(id, n)
	local s = { name = "Vendor " .. id, nd = DAY, map = 1400 + rnd(60), x = rnd(100), y = rnd(100), pd = DAY, t = {}, v = {} }
	for i = 1, n do
		local d = DAY - rnd(110)
		s.v[2000 + rnd(30000)] = { d, { c = 1000 + rnd(1000000), o = {}, l = rnd(2) }, d }
	end
	return s
end
local fullSaved
local function full()
	if not fullSaved then
		seed = 4242
		fullSaved = {}
		for k = 1, 2 do
			local saved = {}
			local tab = ND.New(saved, function() return CLOCK0 end)
			for i = 1, 100 do tab:MergeIn(3000 + i * 13, trainer(3000 + i * 13, 152, i * 2000)) end
			for i = 1, 500 do tab:MergeIn(100000 + i * 17, vendor(100000 + i * 17, 11)) end
			H.eq(tab.nSheets, 600) H.eq(tab.nEntries, 20000)
			fullSaved[k] = saved
		end
	end
	return copy(fullSaved[1]), copy(fullSaved[2])
end

local function quietAdapter(o)
	o = o or {}
	return {
		now = function() return 0 end, after = function() end, random = function() return 0.5 end,
		canSend = function() return true end, send = function() end, selfGuid = function() return "P" end,
		faction = function() return "Alliance" end, changed = function() end,
		isMe = function(n) return n == "Me" end, size = function() return 100 end,
	}
end

-- The worst NU the bounds accept: NU_SHEETS sheets sharing columns of NU_ENTRIES / NU_SHEETS entries.
local function worstNU(base)
	local per = math.floor(NS.NU_ENTRIES / NS.NU_SHEETS)
	local s = { name = "T", nd = DAY, map = 1453, x = 1, y = 1, pd = DAY, t = {}, v = {} }
	for i = 1, per do s.t[base + i] = { DAY, 1 + (i % 300), DAY, 100 + i, DAY } end
	local big = ND.Pack(8, s)
	local x = {}
	for i = 1, NS.NU_SHEETS do
		local l = {}
		for j, v in pairs(big) do l[j] = v end
		l[1] = base + i
		x[i] = l
	end
	return { t = "NU", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "X", h = 1, x = x }
end

-- The scheduler ----------------------------------------------------------------------------

H.test("work: jobs in order, slices of the budget with at least one item, Flush, an error drops its job only", function()
	local w = meteredWork(10)
	local order = {}
	local function job(name, items, cost)
		return function()
			for i = 1, items do
				w:Pace(cost)
				meter = meter + cost
				order[#order + 1] = name .. i
			end
		end
	end
	w:Run(job("a", 3, 4))
	-- a1 a2 fit (8), a3 would pass 10: the next frame
	H.eq(table.concat(order, " "), "a1 a2", "started at once, in the caller's frame")
	H.ok(w:Busy(), "busy")
	w:Run(job("b", 2, 30), "B")
	H.ok(w:Busy("B"), "busy of owner B")
	H.eq(w:InJob(), false, "outside a job")
	w.step()
	-- a3 (4), then b1 although over the budget? no: b1 (30) would pass it, yet a slice does one item
	-- at least only when it has done none; a3 was done, so b waits
	H.eq(table.concat(order, " "), "a1 a2 a3", "a3, then b waits")
	w.step()
	H.eq(table.concat(order, " "), "a1 a2 a3 b1", "one item larger than the budget, alone")
	w:Run(function() error("boom") end)
	local inside
	w:Run(function() inside = w:InJob() end)
	w:Flush()
	H.eq(table.concat(order, " "), "a1 a2 a3 b1 b2", "Flush runs to the end")
	H.eq(#w.errors, 1, "the error recorded") H.ok(w.errors[1]:find("boom", 1, true), w.errors[1])
	H.eq(inside, true, "the job after it ran, inside a job")
	H.eq(w:Busy(), false, "done")
	w.pump() -- the frame asked for before Flush finds nothing to do
	H.eq(w:Busy(), false, "still done")
	-- fail(err) of a job
	local failed
	w:Run(function() error("x") end, nil, function(e) failed = e end)
	w.pump()
	H.ok(failed and tostring(failed):find("x", 1, true), "fail called")
	-- a job may queue another: it runs after it, never inside it
	order = {}
	w:Run(function()
		w:Run(function() order[#order + 1] = "inner" end)
		order[#order + 1] = "outer"
	end)
	w.pump()
	H.eq(table.concat(order, " "), "outer inner")
end)

-- Budget per frame, with full tables (the metered clock) --------------------------------------

local BUDGET = 3000
-- one item may go past the budget: the largest is a full sheet merged, packed and hashed
local SLACK = 600

H.test("work budget: login with full tables (both loaded, the import, Hash, Count) never passes a frame's budget", function()
	local savedGuild, savedOwn = full()
	local total0 = meter
	-- the same without a scheduler: one frame
	do
		local own = ND.New(copy(savedOwn), function() return CLOCK0 end)
		local g = ND.New(copy(savedGuild), function() return CLOCK0 end)
		g:Import(own)
		g:Hash() g:Count()
	end
	local whole = meter - total0
	H.ok(whole > 4 * BUDGET, "a full login is much more than one frame's budget: " .. whole)
	local w = meteredWork(BUDGET)
	local own, g
	w.inFrame(function()
		own = ND.New(savedOwn, function() return CLOCK0 end, nil, w)
		g = ND.New(savedGuild, function() return CLOCK0 end, nil, w)
		w:Run(function() g:Import(own) end)
		g:Hash() g:Count() own:Count()
	end)
	H.ok(g.loading, "still loading after the first frame")
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	H.ok(not g.loading and not own.loading, "loaded")
	H.ok(w.frames > 4, "spread: " .. w.frames .. " frames")
	H.ok(w.maxFrame <= BUDGET + SLACK, ("a frame took %d units, budget %d"):format(w.maxFrame, BUDGET))
	H.eq(g.nSheets, 600)
end)

H.test("work budget: the worst accepted NU, alone and 5 back to back, into a full table", function()
	local savedGuild = full()
	local w = meteredWork(BUDGET)
	local g = ND.New(savedGuild, function() return CLOCK0 end, nil, w)
	w.pump()
	local sync = NS.New(quietAdapter(), g)
	w.reset()
	local m0 = meter
	w.inFrame(function() sync:OnMessage(worstNU(800000), "G1", 100) end)
	w.pump()
	H.ok(meter - m0 > 2 * BUDGET, "more than a frame's work: " .. (meter - m0))
	H.ok(w.maxFrame <= BUDGET + SLACK, ("one NU: a frame took %d units"):format(w.maxFrame))
	H.ok(g:Get(800001), "merged")
	w.reset()
	w.inFrame(function()
		for k = 1, 5 do sync:OnMessage(worstNU(810000 + k * 1000), "G" .. (k + 1), 100) end
	end)
	H.ok(sync.queued.NU > 0, "the later NUs wait")
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	H.ok(w.maxFrame <= BUDGET + SLACK, ("5 NUs: a frame took %d units"):format(w.maxFrame))
	H.eq(sync.queued.NU, 0) H.eq(sync.stats.overflow, 0)
	for k = 1, 5 do H.ok(g:Get(810000 + k * 1000 + 1) or g.nSheets == 600, "merged or limited") end
end)

H.test("work budget: the day rollover (expiry of a full table) and 40 days later", function()
	local savedGuild = full()
	local w = meteredWork(BUDGET)
	local t = CLOCK0
	local g = ND.New(savedGuild, function() return t end, nil, w)
	w.pump()
	local h0 = g:Hash()
	t = CLOCK0 + 86400
	w.reset()
	w.inFrame(function() g:Hash() end)
	w.pump()
	H.ok(w.maxFrame <= BUDGET + SLACK, ("rollover: a frame took %d units"):format(w.maxFrame))
	t = CLOCK0 + 40 * 86400
	w.reset()
	local m0 = meter
	w.inFrame(function() H.eq(g:Hash(), g.total, "a read before the expiry sees the day before") end)
	w.pump()
	H.ok(meter - m0 > BUDGET, "much to expire: " .. (meter - m0))
	H.ok(w.frames > 1 and w.maxFrame <= BUDGET + SLACK, ("40 days: %d frames, a frame took %d units"):format(w.frames, w.maxFrame))
	H.ok(g:Hash() ~= h0, "expired")
	-- the same as a table loaded on that day without a scheduler
	local fresh = ND.New(reloadCopy(g.saved), function() return t end)
	H.eq(fresh:Hash(), g:Hash(), "equal to a fresh load")
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
end)

-- Equality: spread processing gives what synchronous processing gives -------------------------

local function randomSheet(r, day)
	local s = { t = {}, v = {} }
	if r(3) > 1 then s.name, s.nd = ({ "A", "B", "Ab" })[r(3)], day - r(130) + 2 end
	if r(3) > 1 then s.map, s.x, s.y, s.pd = r(3), r(3), r(3), day - r(130) + 2 end
	for _ = 1, r(40) do
		local d = day - r(125) + 2
		local e = { d, 0, 0, 0, 0 }
		if r(3) > 1 then e[2], e[3] = r(4) * 10, d - r(3) + 1 end
		if r(3) > 1 then e[4], e[5] = r(4) * 100, d - r(3) + 1 end
		s.t[r(60)] = e
	end
	for _ = 1, r(12) do
		local d = day - r(125) + 2
		local p = r(3) > 1 and { c = r(3) * 100, o = r(4) == 1 and { { 2, r(3), r(2) } } or {}, l = r(2) - 1 } or false
		s.v[r(40)] = { d, p, p and d - r(3) + 1 or 0 }
	end
	return s
end
local function randomReading(r)
	local x = { name = ({ "A", "B", "Zed" })[r(3)], map = r(3), x = r(3), y = r(3), t = {}, v = {} }
	for _ = 1, r(8) do x.t[r(60)] = { skill = r(4) * 10, copper = r(4) * 100 } end
	for _ = 1, r(4) do x.v[r(40)] = { price = { c = r(3) * 100, o = {}, l = 0 } } end
	return x
end

-- One client: its table (with or without a scheduler), its sync, its timers, what it sent.
local function client(work, limits, saved, clock)
	local c = { q = {}, seq = 0, sent = {}, t = 0, rs = 99, work = work }
	local function rand() c.rs = (c.rs * 69069 + 1) % 4294967296 return c.rs / 4294967296 end
	c.tab = ND.New(saved, clock, limits, work)
	c.sync = NS.New({
		now = function() return c.t end,
		after = function(s, fn) c.seq = c.seq + 1 c.q[#c.q + 1] = { c.t + s, c.seq, fn } end,
		random = rand, canSend = function() return true end,
		send = function(msg, done) c.sent[#c.sent + 1] = copy(msg) if done then done(true) end end,
		selfGuid = function() return "Player-1-0000000A" end, faction = function() return "Alliance" end,
		changed = function() end, isMe = function(n) return n == "Me" end,
		size = function(msg) return 60 + 30 * #(msg.x or msg.i or {}) end,
	}, c.tab)
	-- timers due by time t, in order
	function c.due(t)
		while true do
			local best, bi
			for i, e in ipairs(c.q) do
				if e[1] <= t and (not best or e[1] < best[1] or (e[1] == best[1] and e[2] < best[2])) then best, bi = e, i end
			end
			if not best then break end
			table.remove(c.q, bi)
			c.t = best[1]
			best[3]()
			-- its job ends before the clock moves on (a frame is ms, timers are seconds apart)
			if work then work.pump() end
		end
		c.t = t
	end
	return c
end

local function sameClient(a, b, what)
	local A, B = a.tab, b.tab
	-- a read outside a job on a new day queues the expiry and sees the day before: let it run
	A:Hash() B:Hash()
	if b.work then b.work.pump() end
	H.eq(B:Hash(), A:Hash(), what .. ": hash")
	H.ok(deepEq(A.sheets, B.sheets), what .. ": sheets")
	local n1, e1 = A:Count()
	local n2, e2 = B:Count()
	H.eq(n2, n1, what .. ": count") H.eq(e2, e1, what .. ": entries")
	-- saved: the same sheets (a list kept as it was saved, or packed anew, unpacks the same)
	for id, l in pairs(A.saved.s) do
		H.ok(B.saved.s[id], what .. ": saved " .. id)
		local _, x = ND.Unpack(l, A.day)
		local _, y = ND.Unpack(B.saved.s[id], A.day)
		H.ok(deepEq(x, y), what .. ": saved sheet " .. id)
	end
	for id in pairs(B.saved.s) do H.ok(A.saved.s[id], what .. ": saved extra " .. id) end
	-- the same sent, remembered, planned
	H.ok(deepEq(a.sent, b.sent), what .. ": sent messages (" .. #a.sent .. " vs " .. #b.sent .. ")")
	H.ok(deepEq(a.sync.refused, b.sync.refused) and deepEq(a.sync.refusedList, b.sync.refusedList), what .. ": refused")
	local pa, pb = {}, {}
	for id, q in pairs(a.sync.push or {}) do pa[id] = q.who or true end
	for id, q in pairs(b.sync.push or {}) do pb[id] = q.who or true end
	H.ok(deepEq(pa, pb), what .. ": planned sheets")
	H.ok(deepEq(a.sync.stats, b.sync.stats), what .. ": stats")
end

H.test("work equality: spread equals synchronous over random NUs, NIs, NRs, NDs, own visits, days, reloads", function()
	local runs = 0
	for s = 1, 12 do
		local rs = s * 7919
		local function r(n) rs = (rs * 1103515245 + 12345) % 2147483648 return math.floor(rs / 2147483648 * n) + 1 end
		local day = DAY
		local clock = function() return day * 86400 + 3600 end
		local limits = { t = 30, v = 10, entries = 300 + r(400), sheets = 15 + r(20) }
		local savedA, savedB = {}, {}
		local w = meteredWork(40 + r(400))
		local a, b = client(nil, limits, savedA, clock), client(w, limits, savedB, clock)
		local t = 0
		for step = 1, 40 do
			-- a few messages arrive at once; on b, frames pass between them (arrivals mid-work)
			local batch = {}
			for i = 1, r(4) do
				local k = r(10)
				if k <= 4 then
					local x = {}
					for j = 1, r(5) do x[j] = ND.Pack(r(50), ND.Valid(randomSheet(r, day), day) or { t = { [1] = { day, 0, 0, 0, 0 } }, v = {} }) end
					batch[i] = { "msg", { t = "NU", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = r(1000), x = x }, "Peer" .. r(3) }
				elseif k == 5 then
					local ids, c, id = {}, {}, 0
					for j = 1, r(6) do id = id + r(9) ids[j], c[j] = id, r(65536) - 1 end
					local d, prev = {}, 0
					for j, v in ipairs(ids) do d[j], prev = v - prev, v end
					batch[i] = { "msg", { t = "NI", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = r(1000), r = r(65536) - 1, i = d, c = c }, "Peer" .. r(3) }
				elseif k == 6 then
					batch[i] = { "msg", { t = "NR", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = r(1000), to = r(2) == 1 and "Me" or "Other", i = { r(20), r(20) } }, "Peer" .. r(3) }
				elseif k == 7 then
					batch[i] = { "msg", { t = "ND", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = r(1000), n = r(30) }, "Peer" .. r(3) }
				else
					batch[i] = { "visit", r(50), randomReading(r) }
				end
			end
			for _, m in ipairs(batch) do
				for _, c in ipairs({ a, b }) do
					if m[1] == "msg" then c.sync:OnMessage(copy(m[2]), m[3], 100)
					else c.sync:OwnVisit(m[2], copy(m[3])) end
				end
				for _ = 1, r(3) - 1 do w.step() end
			end
			w.pump()
			t = t + r(40)
			a.due(t) b.due(t)
			w.pump()
			if r(12) == 1 then day = day + 1 end
			if r(15) == 1 then
				-- /reload: both made anew from their saved tables (b loads in slices)
				local sa, sb = a.sent, b.sent
				a, b = client(nil, limits, savedA, clock), client(w, limits, savedB, clock)
				a.t, b.t, a.sent, b.sent = t, t, sa, sb
				w.pump()
			end
			sameClient(a, b, ("seed %d step %d"):format(s, step))
			runs = runs + 1
		end
		H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	end
	H.ok(runs == 480)
end)

-- Interruption: a /reload or logout half way leaves valid saved data ---------------------------

H.test("work interruption: saved data stays valid when the game saves in the middle of loading, a merge, an expiry", function()
	local savedGuild = full()
	local original = reloadCopy(savedGuild)
	local t = CLOCK0
	local clock = function() return t end
	-- loading: saved is the saved table untouched until the loaded one is swapped in
	local w = meteredWork(BUDGET)
	local g = ND.New(savedGuild, clock, nil, w)
	for _ = 1, 3 do w.step() end
	H.ok(g.loading, "half loaded")
	H.ok(deepEq(reloadCopy(savedGuild), original), "saved as it was while loading")
	w.pump()
	H.ok(not g.loading)
	local h = g:Hash()
	H.eq(ND.New(reloadCopy(savedGuild), clock):Hash(), h, "after loading, saved loads to the same table")
	-- a merge (the worst NU) half way
	local sync = NS.New(quietAdapter(), g)
	local before = copy(g.sheets)
	local nu = worstNU(800000)
	sync:OnMessage(copy(nu), "G", 100)
	for _ = 1, 4 do w.step() end
	H.ok(w:Busy(), "half merged")
	local mid = reloadCopy(savedGuild)
	w.pump()
	local done = g:Hash()
	local fresh = ND.New(mid, clock)
	H.ok(fresh.nSheets > 0, "the half merged save loads")
	for id, l in pairs(mid.s) do
		local key, s = ND.Unpack(l, DAY)
		H.ok(s and key == id, "every saved sheet valid: " .. tostring(id))
	end
	-- nothing is lost: a sheet held before the merge and as it was after it is in the reloaded table
	H.ok(done ~= h, "the merge changed the table")
	local kept = 0
	for id, s in pairs(before) do
		if deepEq(g.sheets[id], s) then
			H.ok(deepEq(fresh.sheets[id], s), "kept sheet " .. id .. " in the reloaded table")
			kept = kept + 1
		end
	end
	H.ok(kept > 0, "sheets kept: " .. kept)
	H.ok(fresh.nEntries <= ND.LIMIT_ENTRIES and fresh.nSheets <= ND.LIMIT_SHEETS, "within the limits")
	-- an expiry half way
	t = CLOCK0 + 40 * 86400
	g:Hash()
	for _ = 1, 3 do w.step() end
	H.ok(w:Busy(), "half expired")
	mid = reloadCopy(savedGuild)
	w.pump()
	for id, l in pairs(mid.s) do
		local key, s = ND.Unpack(l, DAY + 40)
		H.ok(key == id, "saved sheet keeps its key: " .. tostring(id))
	end
	H.eq(ND.New(mid, clock):Hash(), g:Hash(), "a reload half way through the expiry gives the expired table")
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
end)

H.test("work interruption: Flush (logout) mid-load saves everything; later sheets stay held back", function()
	local savedGuild = full()
	-- a held-back sheet of a later day (f1eaae0): it stays as it is
	local later = ND.Pack(777, { name = "Later", nd = DAY + 5, t = { [1] = { DAY + 5, 0, 0, 0, 0 } }, v = {} })
	savedGuild.s[777] = later
	local w = meteredWork(BUDGET)
	local g = ND.New(savedGuild, function() return CLOCK0 end, nil, w)
	local visited
	w.step()
	w:Run(function() visited = g:OwnVisit(4242, { name = "X", t = { [5] = { skill = 10 } }, v = {} }) end)
	H.ok(g.loading and visited == nil, "the reading waits for the loading")
	w:Flush()
	H.ok(not g.loading, "loaded at logout")
	H.ok(visited ~= nil, "the reading taken")
	H.ok(savedGuild.s[4242], "and saved")
	H.ok(savedGuild.s[777] == later, "the held-back sheet kept as it was")
	H.eq(g:Get(777), nil, "and not held")
end)

-- While loading: reads, messages and own readings ------------------------------------------

H.test("work loading: reads, ND NI NR NU and own readings during loading give no error and are not lost", function()
	local savedGuild = full()
	local w = meteredWork(BUDGET)
	local g = ND.New(copy(savedGuild), function() return CLOCK0 end, nil, w)
	local sync = NS.New(quietAdapter(), g)
	H.ok(g.loading, "loading")
	-- reads of a half loaded table
	g:Hash() g:Count() g:SendableIDs() g:Get(3013) g:Sendable(3013) g:SheetHash(3013)
	local P = ND.PROTOCOL
	local function m(t, f)
		local x = { t = t, pv = P, e = ND.EPOCH, f = "Alliance", s = "S", h = 5 }
		for k, v in pairs(f) do x[k] = v end
		return x
	end
	local nu = { ND.Pack(990001, { name = "New", nd = DAY, t = { [5] = { DAY, 10, DAY, 0, 0 } }, v = {} }) }
	sync:OnMessage(m("ND", { n = 3 }), "A", 10)
	sync:OnMessage(m("NI", { r = 1, i = { 3013 }, c = { 5 } }), "B", 10)
	sync:OnMessage(m("NR", { to = "Me", i = { 3013 } }), "C", 10)
	sync:OnMessage(m("NU", { x = nu }), "D", 10)
	local own = sync:OwnVisit(990002, { name = "Mine", t = { [6] = { skill = 20 } }, v = {} })
	H.eq(own, nil, "the own reading waits")
	H.eq(sync.queued.NU, 1) H.eq(sync.queued.other, 3)
	H.eq(sync.stats.recv.NU, 1, "counted as received")
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	H.ok(g:Get(990001), "the NU merged after the loading")
	H.ok(g:Get(990002), "the own reading taken after the loading")
	H.eq(sync.queued.NU + sync.queued.other, 0)
	-- the same without a scheduler, in the same order, gives the same table
	local s0 = copy(savedGuild)
	local g0 = ND.New(s0, function() return CLOCK0 end)
	local y = NS.New(quietAdapter(), g0)
	y:OnMessage(m("ND", { n = 3 }), "A", 10)
	y:OnMessage(m("NI", { r = 1, i = { 3013 }, c = { 5 } }), "B", 10)
	y:OnMessage(m("NR", { to = "Me", i = { 3013 } }), "C", 10)
	y:OnMessage(m("NU", { x = nu }), "D", 10)
	y:OwnVisit(990002, { name = "Mine", t = { [6] = { skill = 20 } }, v = {} })
	H.eq(g:Hash(), g0:Hash(), "equal to synchronous")
	H.ok(deepEq(sync.stats, y.stats), "the same stats")
end)

-- The bounded queue --------------------------------------------------------------------------

H.test("work queue: a flood while the work is busy fills the queue; the excess is dropped and counted", function()
	local savedGuild = full()
	local w = meteredWork(BUDGET)
	local g = ND.New(savedGuild, function() return CLOCK0 end, nil, w)
	local sync = NS.New(quietAdapter(), g)
	local small = { ND.Pack(5, { name = "N", nd = DAY, t = { [1] = { DAY, 0, 0, 0, 0 } }, v = {} }) }
	for i = 1, NS.QUEUE_NU + 30 do
		sync:OnMessage({ t = "NU", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = 5, x = small }, "Evil" .. i, 50)
	end
	H.eq(sync.queued.NU, NS.QUEUE_NU, "the queue is full")
	H.eq(sync.stats.overflow, 30, "the excess counted")
	for i = 1, NS.QUEUE + 10 do
		sync:OnMessage({ t = "ND", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = 5, n = 1 }, "Evil" .. i, 10)
	end
	H.eq(sync.queued.other, NS.QUEUE) H.eq(sync.stats.overflow, 40)
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	H.eq(sync.queued.NU + sync.queued.other, 0, "drained")
	H.ok(g:Get(5), "the NUs that waited merged")
	-- an honest guild: 72 guildmates' ND and NI and a few NUs while a full table loads
	local g2 = ND.New(full(), function() return CLOCK0 end, nil, w)
	local s2 = NS.New(quietAdapter(), g2)
	for i = 1, 72 do
		s2:OnMessage({ t = "ND", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = 5, n = 1 }, "Mate" .. i, 10)
		if i % 6 == 0 then
			s2:OnMessage({ t = "NU", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "S", h = 5, x = small }, "Mate" .. i, 50)
		end
		w.step()
	end
	w.pump()
	H.eq(s2.stats.overflow, 0, "honest traffic never fills the queue")
end)
