-- The day changing while NPC work is spread over frames (NpcWork). A read never changes a table:
-- the expiry of a new day runs at the start of the next job (Settle), so a job that waited for a
-- frame across midnight keeps the day it started with, and nothing paces under a pcall (PUC Lua 5.1
-- cannot yield across one: run these under real Lua 5.1 too, tests/run.lua through lupa).
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "NpcWork.lua", "NpcData.lua", "NpcTable.lua", "NpcSync.lua" })
local ND, NW, NS = ns.NpcData, ns.NpcWork, ns.NpcSync

local DAY = 20770

-- A scheduler whose clock is the work declared with Pace (each unit 1 ms), frames by hand.
local function work(budget)
	local w
	local units, frame, pending, errors = 0, 0, {}, {}
	w = NW.New({ clock = function() return units end, frame = function() return frame end,
		defer = function(fn) pending[#pending + 1] = fn end, budget = function() return budget end,
		rate = 1, spend = function(u) units = units + u end,
		error = function(e, stack) errors[#errors + 1] = tostring(e) end })
	w.errors = errors
	function w.newFrame() frame = frame + 1 end
	function w.spendNow(u) units = units + u end
	function w.step()
		if not pending[1] then return false end
		frame = frame + 1
		local p = pending
		pending = {}
		for _, fn in ipairs(p) do fn() end
		return true
	end
	function w.pump() local n = 0 while w.step() and n < 100000 do n = n + 1 end return n end
	return w
end

local function adapter(o)
	o = o or {}
	local a = {
		now = function() return o.now and o.now() or 1000 end,
		after = function(s, fn) if o.timers then o.timers[#o.timers + 1] = { s, fn } end end,
		random = function() return 0.5 end, canSend = function() return true end,
		send = function(msg, done)
			if o.sent then o.sent[#o.sent + 1] = msg end
			if done then done(true) end
		end,
		selfGuid = function() return "Me-1" end, faction = function() return "Alliance" end,
		changed = function() end, isMe = function(n) return n == "Me" end,
		size = function(msg) return 60 + 30 * #(msg.x or msg.i or {}) end,
	}
	for k, v in pairs(o.override or {}) do a[k] = v end
	return a
end

local function msg(t, f)
	local x = { t = t, pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "G-1", h = 12345 }
	for k, v in pairs(f) do x[k] = v end
	return x
end

-- A table of n sheets whose entry 1001 is `age` days old today (k > 1 younger), saved.
local function savedTable(n, clock, age)
	local tmp = ND.New({}, clock)
	for id = 1, n do
		local s = { name = "N" .. id, nd = DAY - 5, t = {}, v = {} }
		for k = 1, 20 do
			local d = (k == 1) and (DAY - age) or (DAY - k)
			s.t[1000 + k] = { d, 10 * k, d, 100, d }
		end
		tmp:MergeIn(id, s)
	end
	return tmp.saved
end

-- The hash a table of the same sheets has when cut anew on its clock's day.
local function freshHash(tab, clock)
	local fresh = ND.New({}, clock)
	for id, s in pairs(tab.sheets) do fresh:MergeIn(id, s) end
	return fresh:Hash()
end

H.test("day: midnight while a step waits for the frame of its NU: the NU goes out, no error, the table is recut", function()
	local T = DAY * 86400 + 86000
	local clock = function() return T end
	local w = work(200)
	local tab = ND.New(savedTable(30, clock, 118), clock, nil, w)
	w.pump()
	local timers, sent = {}, {}
	local now = 1000
	local sync = NS.New(adapter({ timers = timers, sent = sent, now = function() return now end }), tab)
	sync:OnMessage(msg("NI", { r = 7, i = {}, c = {} }), "G", 100)
	w.pump()
	-- the step: its sheet sizes known, another job used the frame first, so it waits at pace(bytes)
	for _, id in ipairs(tab:SendableIDs()) do sync.sizes[tab:SheetHash(id) .. ":" .. id] = 90 end
	table.sort(timers, function(a, b) return a[1] < b[1] end)
	local tm = table.remove(timers, 1)
	w.newFrame()
	w:Run(function() w:Pace(1) w.spendNow(50) end)
	tm[2]()
	H.ok(w:Busy(), "the step waits for the next frame")
	T = (DAY + 1) * 86400 + 5
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	local nu = false
	for _, m in ipairs(sent) do if m.t == "NU" then nu = true end end
	H.ok(nu, "the NU was sent")
	H.eq(tab.day, DAY + 1, "the next job settled the day")
	H.eq(tab:Hash(), freshHash(tab, clock), "the table equals one cut on the new day")
	for id in pairs(tab.sheets) do H.ok(not tab.cuts[id].t[1001], "no 119 day old entry sent: " .. id) end
end)

H.test("day: midnight inside a received NI and our own NI: no error, the NI is answered from one day", function()
	local T = DAY * 86400 + 86390
	local clock = function() return T end
	local tmp = ND.New({}, clock)
	for id = 1, 40 do
		local s = { name = "N" .. id, nd = DAY - 5, t = {}, v = {} }
		if id == 30 then
			s.t[5] = { DAY - ND.SEND, 0, 0, 0, 0 } -- sendable today, not tomorrow
		else
			for k = 1, 5 do s.t[1000 + k] = { DAY - k, 10, DAY - k, 0, 0 } end
		end
		tmp:MergeIn(id, s)
	end
	local w = work(20)
	local tab = ND.New(tmp.saved, clock, nil, w)
	w.pump()
	local sync = NS.New(adapter(), tab)
	local ids, c, prev = {}, {}, 0
	for id = 1, 40 do ids[#ids + 1], c[#c + 1], prev = id - prev, 1, id end
	w.newFrame()
	sync:OnMessage(msg("NI", { r = 7, i = ids, c = c }), "G", 100)
	H.ok(w:Busy(), "the NI job waits for a frame")
	T = (DAY + 1) * 86400 + 1
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	local n = 0
	for _ in pairs(sync.push or {}) do n = n + 1 end
	H.eq(n, 40, "every sheet of the day the NI started on is planned")
	H.eq(tab:Count(), 39, "the next job settled the day: sheet 30 is no longer sendable")
	-- a planned sheet without a sendable part any more is dropped by the step, not sent
	H.ok(sync.push[30], "planned on the day before")
end)


H.test("day: our own NI cut short by an error does not count: lastNI and the pair rise only when it goes out", function()
	local clock = function() return DAY * 86400 + 3600 end
	local w = work(20)
	local tab = ND.New(savedTable(60, clock, 5), clock, nil, w)
	w.pump()
	local timers, sent = {}, {}
	local now = 1000
	local sync = NS.New(adapter({ timers = timers, sent = sent, now = function() return now end }), tab)
	local function fire()
		local list = {}
		for i, tm in ipairs(timers) do list[i] = tm timers[i] = nil end
		for _, tm in ipairs(list) do now = now + tm[1] w.newFrame() tm[2]() w.pump() end
	end
	sync:OnMessage(msg("ND", { n = 3, h = 7 }), "Bob", 20)
	w.pump()
	local salted = tab.SaltedHash
	local calls = 0
	tab.SaltedHash = function(self, h, salt)
		calls = calls + 1
		if calls == 30 then error("cut short") end
		return salted(self, h, salt)
	end
	fire()
	tab.SaltedHash = salted
	H.eq(#w.errors, 1, "the NI job ended in the error")
	H.eq(sync.lastNI, -1e9, "an NI never sent does not hold back the next")
	for _, p in pairs(sync.pair) do H.eq(p.n, 0, "nor count toward muting the pair") end
	-- the next ND plans again and the NI goes out
	sync:OnMessage(msg("ND", { n = 3, h = 7 }), "Ann", 20)
	w.pump()
	for _ = 1, 5 do fire() end
	local ni = 0
	for _, m in ipairs(sent) do if m.t == "NI" then ni = ni + 1 end end
	H.eq(ni, 1, "the NI was sent")
	H.ok(sync.lastNI > -1e9, "and counted")
end)

H.test("day: a read inside a job never changes the table; the next job settles the day", function()
	local T = DAY * 86400 + 86390
	local clock = function() return T end
	local w = work(50)
	local tab = ND.New(savedTable(20, clock, 118), clock, nil, w)
	w.pump()
	local h0, seen = tab:Hash(), {}
	w:Run(function()
		T = (DAY + 1) * 86400 + 1
		seen.hash, seen.day, seen.count = tab:Hash(), tab.day, tab:Count()
		-- inside a pcall too (the UI, Bugs.Call): nothing paces there
		seen.ok = pcall(function() return tab:Hash(), tab:SendableIDs(), tab:Sendable(1), tab:Get(1) end)
	end)
	H.eq(seen.hash, h0, "the job sees the day it started with")
	H.eq(seen.day, DAY) H.eq(seen.count, 20) H.ok(seen.ok)
	w.pump()
	H.eq(#w.errors, 0, table.concat(w.errors, "\n"))
	H.eq(tab.day, DAY + 1, "the expiry queued by the read ran")
	H.eq(tab:Hash(), freshHash(tab, clock))
end)

H.test("day: an expiry cut short by an error is finished by the next job; only the sheet that threw is skipped", function()
	local T = DAY * 86400 + 3600
	local clock = function() return T end
	local w = work(50)
	local tab = ND.New(savedTable(40, clock, 118), clock, nil, w)
	w.pump()
	local put, n = tab.put, 0
	tab.put = function(self, id, s, packed)
		n = n + 1
		if n == 7 then error("cut short") end
		return put(self, id, s, packed)
	end
	T = (DAY + 3) * 86400 + 1 -- 121 days: entry 1001 expires in every sheet
	tab:Hash()
	w.pump()
	tab.put = nil
	H.eq(#w.errors, 1, "the expiry ended in the error")
	H.ok(tab.expiring ~= nil, "and is still due")
	tab:Hash()
	w.pump()
	H.eq(#w.errors, 1)
	H.eq(tab.expiring, nil, "finished")
	for id, s in pairs(tab.sheets) do H.ok(not s.t[1001], "expired in sheet " .. id) end
	-- every sheet but the one whose store threw (skipped, not tried forever) as cut on that day
	local fresh = ND.New({}, clock)
	for id, sh in pairs(tab.sheets) do fresh:MergeIn(id, sh) end
	local differ = 0
	for id in pairs(tab.sheets) do if tab:SheetHash(id) ~= fresh:SheetHash(id) then differ = differ + 1 end end
	H.ok(differ <= 1, "sheets cut otherwise: " .. differ)
end)

H.test("day: a step that ends in an error leaves no planned sheet without a step", function()
	local clock = function() return DAY * 86400 + 3600 end
	local w = work(200)
	local tab = ND.New(savedTable(5, clock, 5), clock, nil, w)
	w.pump()
	local timers, sent = {}, {}
	local now, bad = 1000, true
	local a = adapter({ timers = timers, sent = sent, now = function() return now end })
	local size = a.size
	a.size = function(m) if bad and m.t == "NU" then bad = false error("encoder") end return size(m) end
	local sync = NS.New(a, tab)
	sync:OnMessage(msg("NI", { r = 7, i = {}, c = {} }), "G", 100)
	w.pump()
	for _ = 1, 10 do
		local list = {}
		for i, tm in ipairs(timers) do list[i] = tm timers[i] = nil end
		for _, tm in ipairs(list) do now = now + tm[1] tm[2]() w.pump() end
	end
	H.eq(#w.errors, 1, "the step failed once")
	local nu = 0
	for _, m in ipairs(sent) do if m.t == "NU" then nu = nu + #m.x end end
	H.eq(nu, 5, "every planned sheet went out after it")
	H.ok(not sync.sending)
end)

H.test("day: a session stopped while its step waits sends nothing", function()
	local clock = function() return DAY * 86400 + 3600 end
	local w = work(200)
	local tab = ND.New(savedTable(30, clock, 5), clock, nil, w)
	w.pump()
	local timers, sent = {}, {}
	local sync = NS.New(adapter({ timers = timers, sent = sent }), tab)
	sync:OnMessage(msg("NI", { r = 7, i = {}, c = {} }), "G", 100)
	w.pump()
	for _, id in ipairs(tab:SendableIDs()) do sync.sizes[tab:SheetHash(id) .. ":" .. id] = 90 end
	w.newFrame()
	w:Run(function() w:Pace(1) w.spendNow(50) end)
	timers[1][2]()
	H.ok(w:Busy(), "the step waits")
	sync:Stop()
	w.pump()
	H.eq(#sent, 0, "nothing sent for the guild left")
end)

-- Audit: midnight between any two frames of any NPC work, under PUC Lua 5.1 as under LuaJIT. No
-- job ends in an error, and once the work settles every table equals one cut on its day.
H.test("day: midnight at any frame of loading, merges, NIs, NUs, own readings and steps gives no error", function()
	for seed = 1, 6 do
		local rs = seed * 104729
		local function r(n) rs = (rs * 1103515245 + 12345) % 2147483648 return math.floor(rs / 2147483648 * n) + 1 end
		local T = DAY * 86400 + 80000
		local clock = function() return T end
		local w = work(30 + r(60))
		local tmp = ND.New({}, clock)
		for id = 1, 60 do
			local s = { name = "N" .. id, nd = DAY - r(5), t = {}, v = {} }
			for k = 1, r(25) do local d = DAY - 110 - r(12) + (k > 3 and 100 or 0) s.t[1000 + k] = { d, 10, d, 100, d } end
			for k = 1, r(6) do local d = DAY - r(120) s.v[50 + k] = { d, { c = 100, o = {}, l = 0 }, d } end
			tmp:MergeIn(id, s)
		end
		local tab = ND.New(tmp.saved, clock, nil, w)
		local timers, now = {}, 1000
		local sync = NS.New(adapter({ timers = timers, sent = {}, now = function() return now end }), tab)
		for _ = 1, 60 do
			local k = r(6)
			if k == 1 then
				local x = {}
				for j = 1, r(4) do
					local d = DAY - r(119)
					x[j] = ND.Pack(r(80), { name = "X", nd = DAY, t = { [2000 + r(30)] = { d, 5, d, 0, 0 } }, v = {} })
				end
				sync:OnMessage(msg("NU", { x = x, h = r(1000) }), "P" .. r(3), 100)
			elseif k == 2 then
				local d, c = {}, {}
				for j = 1, r(30) do d[j], c[j] = r(3), r(65536) - 1 end
				sync:OnMessage(msg("NI", { r = r(65536) - 1, i = d, c = c, h = r(1000) }), "Q" .. r(5), 100)
			elseif k == 3 then
				sync:OnMessage(msg("ND", { n = r(30), h = r(1000) }), "D" .. r(5), 20)
			elseif k == 4 then
				sync:OwnVisit(r(80), { name = "Me", t = { [3000 + r(20)] = { skill = 10 } }, v = {} })
			else
				local list = {}
				for i, tm in ipairs(timers) do list[i] = tm timers[i] = nil end
				for _, tm in ipairs(list) do now = now + tm[1] w.newFrame() tm[2]() end
			end
			-- frames pass; midnight between some of them
			for _ = 1, r(4) do
				if r(5) == 1 then T = T + 43200 end
				w.step()
			end
			now = now + r(30)
		end
		w.pump()
		tab:Hash()
		w.pump()
		H.eq(#w.errors, 0, "seed " .. seed .. ": " .. table.concat(w.errors, "\n"))
		H.eq(tab.day, math.floor(T / 86400), "seed " .. seed .. ": settled")
		H.eq(tab:Hash(), freshHash(tab, clock), "seed " .. seed .. ": the table equals one cut on its day")
	end
end)

H.test("day: a table no longer used is collected (none kept by the owner map or the scheduler)", function()
	local clock = function() return DAY * 86400 + 3600 end
	local w = work(200)
	local saved = savedTable(5, clock, 5)
	local probe = setmetatable({}, { __mode = "v" })
	probe[1] = ND.New(saved, clock, nil, w)
	w.pump()
	local keep = ND.New(saved, clock, nil, w) -- a newer table on the same saved one
	w.pump()
	H.ok(probe[1].retired, "the older one is retired")
	collectgarbage("collect") collectgarbage("collect")
	H.eq(probe[1], nil, "the older one collected")
	H.ok(keep.nSheets == 5)
	probe[2] = keep
	keep = nil
	collectgarbage("collect") collectgarbage("collect")
	H.eq(probe[2], nil, "the newer one collected once dropped")
end)

H.test("day: an older table on the same saved one neither writes it nor settles; a clear holds", function()
	local T = DAY * 86400 + 3600
	local clock = function() return T end
	local w = work(20)
	local saved = savedTable(30, clock, 5)
	local old = ND.New(saved, clock, nil, w)
	w.pump()
	-- a clear queued, then the table made anew on the same saved one before the clear ran
	w.newFrame()
	w:Run(function() w:Pace(1000) end)
	local now
	w:Run(function() now:Clear() end)
	now = ND.New(saved, clock, nil, w)
	w.pump()
	H.eq(now.nSheets, 0, "the clear holds in the new table")
	H.eq(next(saved.s), nil, "and in saved")
	old:MergeIn(99, { name = "X", nd = DAY, t = { [1] = { DAY, 0, 0, 0, 0 } }, v = {} })
	H.eq(saved.s[99], nil, "the older table does not write saved")
end)

H.test("table: a lean table (npcOwn) keeps no sendable parts, and counts, hashes and Sendable equal a full one", function()
	local T = DAY * 86400 + 3600
	local clock = function() return T end
	local rs = 4711
	local function r(n) rs = (rs * 1103515245 + 12345) % 2147483648 return math.floor(rs / 2147483648 * n) + 1 end
	local full, lean = ND.New({}, clock), ND.New({}, clock, { lean = true })
	for step = 1, 300 do
		local id = r(40)
		local reading = { name = "N" .. r(3), map = r(3), x = r(9), y = r(9), t = {}, v = {} }
		for _ = 1, r(6) do reading.t[r(80)] = { skill = r(4) * 10, copper = r(5) * 100 } end
		for _ = 1, r(3) do reading.v[r(30)] = { price = { c = r(9) * 10, o = {}, l = 0 } } end
		H.eq(lean:Write(id, reading), full:Write(id, reading), "write " .. step)
		if r(20) == 1 then T = T + 86400 * r(40) end
	end
	local n1, e1 = full:Count()
	local n2, e2 = lean:Count()
	H.eq(n2, n1) H.eq(e2, e1) H.eq(lean:Hash(), full:Hash())
	local kept = 0
	for id in pairs(full.sheets) do
		H.eq(lean:SheetHash(id), full:SheetHash(id))
		local a, b = lean:Sendable(id), full:Sendable(id)
		H.ok((a == nil) == (b == nil), "sendable " .. id)
		if a then
			H.eq(ND.HashSheet(id, a), ND.HashSheet(id, b))
			H.ok(type(lean.cuts[id]) ~= "table", "not kept")
			kept = kept + 1
		end
	end
	H.ok(kept > 0)
	H.eq(#lean:SendableIDs(), #full:SendableIDs())
end)

H.test("table: the index holds the NPC itself for one holder, a set for more, in parts by key", function()
	local clock = function() return DAY * 86400 + 3600 end
	local tab = ND.New({}, clock)
	local P = ND.INDEX_PARTS
	local function at(k) local p = tab.byT[k % P] return p and p[k] end
	local function sheet(keys)
		local s = { name = "N", nd = DAY, t = {}, v = {} }
		for _, k in ipairs(keys) do s.t[k] = { DAY, 0, 0, 0, 0 } end
		return s
	end
	tab:MergeIn(1, sheet({ 100, 164, 7 }))
	H.eq(at(100), 1) H.eq(at(164), 1) H.eq(at(7), 1)
	H.ok(tab.byT[100 % P] == tab.byT[164 % P], "keys of one part share it")
	tab:MergeIn(2, sheet({ 100 }))
	H.ok(type(at(100)) == "table" and at(100)[1] and at(100)[2], "a set for two")
	tab:MergeIn(3, sheet({ 100 }))
	tab:put(1, nil)
	H.ok(type(at(100)) == "table" and at(100)[2] and at(100)[3] and not at(100)[1])
	tab:put(3, nil)
	H.eq(at(100), 2, "back to the one holder") H.eq(at(7), nil) H.eq(at(164), nil)
	tab:put(2, nil)
	H.eq(at(100), nil)
end)

H.test("table: the limits group the entries to drop in paced parts (no long item for thousands)", function()
	local clock = function() return DAY * 86400 + 3600 end
	local w = work(1e9)
	local tab = ND.New({}, clock, { entries = 100, t = 300, v = 300 }, w)
	w.pump()
	local kinds = {}
	local pace = w.Pace
	w.Pace = function(self, u, k) kinds[k or "?"] = (kinds[k or "?"] or 0) + 1 return pace(self, u, k) end
	local items = {}
	for id = 1, 12 do
		local s = { name = "N", nd = DAY, t = {}, v = {} }
		for k = 1, 200 do s.t[id * 1000 + k] = { DAY - (k % 50), 0, 0, 0, 0 } end
		items[id] = { id, s }
	end
	w:Run(function() tab:MergeAll(items) end)
	w.pump()
	w.Pace = nil
	H.eq(tab.nEntries, 100)
	H.ok((kinds.group or 0) >= math.floor((2400 - 100) / 256), "grouped in parts: " .. tostring(kinds.group))
end)

H.test("day: a sheet whose expiry throws is skipped once; every later job runs its own code", function()
	local day = DAY
	local clock = function() return day * 86400 + 3600 end
	local w = work(50)
	local tab = ND.New({}, clock, nil, w)
	w:Run(function()
		for id = 1, 20 do tab:MergeIn(id, { name = "N", nd = day, t = { [100 + id] = { day - 25, 0, 0, 0, 0 } }, v = {} }) end
	end)
	w.pump()
	local put = tab.put
	tab.put = function(self, id, ...) if id == 7 and self.expiring then error("poison sheet 7") end return put(self, id, ...) end
	day = day + 100
	local ran = 0
	for _ = 1, 5 do
		w:Run(function() ran = ran + 1 end)
		w.pump()
	end
	tab.put = nil
	H.eq(ran, 5, "every job ran its code")
	H.eq(#w.errors, 1, "recorded once: " .. table.concat(w.errors, " | "))
	H.eq(tab.expiring, nil, "the expiry ended")
	local left = 0
	for id, s in pairs(tab.sheets) do if s.t[100 + id] then left = left + 1 end end
	H.ok(left <= 1, "every other sheet expired: " .. left)
end)
