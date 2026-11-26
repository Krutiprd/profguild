-- NPC sharing (NpcSync): one test or more per rule of the design's "Sharing", with its numbers,
-- against one object with a scripted guild around it. The whole guild is tests/npcsim.lua.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "NpcData.lua", "NpcTable.lua", "NpcSync.lua" })
local ND, NS = ns.NpcData, ns.NpcSync
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")

local CLOCK0 = 1794615000
local DAY = math.floor(CLOCK0 / 86400)

local function encode(msg) return LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg))) end

-- env.mode: "ok" (done(true) at once), "fail" (done(false)), "never" (no done); env.fail[t] = mode
-- for one message type; env.random: a number for a constant, else a seeded generator.
local function newEnv(o)
	o = o or {}
	local env = { t = 0, q = {}, seq = 0, sent = {}, blocked = false, changes = 0, mode = "ok", fail = {},
		random = o.random, seed = 99 }
	function env.at(dt, fn)
		env.seq = env.seq + 1
		env.q[#env.q + 1] = { env.t + dt, env.seq, fn }
	end
	function env.run(seconds)
		local target = env.t + seconds
		while true do
			local best, bi
			for i, e in ipairs(env.q) do
				if e[1] <= target and (not best or e[1] < best[1] or (e[1] == best[1] and e[2] < best[2])) then
					best, bi = e, i
				end
			end
			if not best then break end
			table.remove(env.q, bi)
			env.t = best[1]
			best[3]()
		end
		env.t = target
	end
	function env.runTo(t) env.run(t - env.t) end
	local adapter = {
		now = function() return env.t end,
		after = env.at,
		random = function()
			if type(env.random) == "number" then return env.random end
			env.seed = (env.seed * 1103515245 + 12345) % 2147483648
			return env.seed / 2147483648
		end,
		canSend = function() return not env.blocked end,
		send = function(msg, done)
			env.sent[#env.sent + 1] = { t = env.t, msg = msg, done = done }
			local mode = env.fail[msg.t] or env.mode
			if mode == "ok" then env.at(0, function() done(true) end)
			elseif mode == "fail" then env.at(0, function() done(false) end)
			elseif mode == "blockfail" then -- the game starts blocking while the message goes out
				env.blocked = true
				env.at(0, function() done(false) end)
			end
		end,
		selfGuid = function() return "Player-1-0000000A" end,
		faction = function() return "Alliance" end,
		changed = function() env.changes = env.changes + 1 end,
		isMe = function(name) return name == "Me-Realm" end,
		size = function(msg) return #encode(msg) end,
	}
	env.adapter = adapter
	env.tab = ND.New({}, function() return CLOCK0 + math.floor(env.t) end, o.limits)
	env.sync = NS.New(adapter, env.tab)
	return env
end

local function sentOf(env, t, from, to)
	local out = {}
	for _, s in ipairs(env.sent) do
		if s.msg.t == t and s.t >= (from or -1) and s.t <= (to or 1e9) then out[#out + 1] = s end
	end
	return out
end

local function idsOf(nu)
	local ids = {}
	for _, list in ipairs(nu.msg.x) do ids[#ids + 1] = list[1] end
	table.sort(ids)
	return table.concat(ids, ",")
end

local function deltas(ids)
	local out, prev = {}, 0
	for i, id in ipairs(ids) do out[i], prev = id - prev, id end
	return out
end

local function incoming(env, t, fields, sender)
	local msg = { t = t, pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "Player-1-0000000B", h = 0 }
	for k, v in pairs(fields or {}) do msg[k] = v end
	env.sync:OnMessage(msg, sender or "Bob-Realm", 100)
end

-- A trainer sheet with recipes (IDs) seen and priced on day d (default today).
local function sheet(id, recipes, d)
	d = d or DAY
	local s = { name = "Trainer " .. id, nd = d, map = 1453, x = 50, y = 40, pd = d, t = {}, v = {} }
	for _, r in ipairs(recipes) do s.t[r] = { d, 100, d, 500 + r, d } end
	return s
end

local function packed(id, s) return ND.Pack(id, s) end

local function hold(env, id, recipes, d) env.tab:MergeIn(id, sheet(id, recipes, d)) end

-- An NI from sender listing ids; equal = { [id] = true } lists ours with our hash, others get a wrong one.
local function ni(env, ids, equal, h, sender, salt)
	salt = salt or 77
	local c = {}
	for i, id in ipairs(ids) do
		local our = env.tab:SheetHash(id)
		if equal and equal[id] and our then c[i] = env.tab:SaltedHash(our, salt)
		else c[i] = ((our and env.tab:SaltedHash(our, salt) or 0) + 1) % 65536 end
	end
	incoming(env, "NI", { h = h or 999, r = salt, i = deltas(ids), c = c }, sender)
end

local function hashWith(list)
	local t = ND.New({}, function() return CLOCK0 end)
	for _, x in ipairs(list) do t:MergeIn(x[1], x[2]) end
	return t:Hash()
end

-- Rule 1 ----------------------------------------------------------------------

H.test("sync 1: ND 10 s after Announce with the common fields", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	env.sync:Announce()
	env.run(9.9)
	H.eq(#sentOf(env, "ND"), 0, "not before 10 s")
	env.run(0.2)
	local nd = sentOf(env, "ND")
	H.eq(#nd, 1, "one ND")
	local m = nd[1].msg
	H.eq(m.pv, ND.PROTOCOL) H.eq(m.e, ND.EPOCH) H.eq(m.f, "Alliance") H.eq(m.s, "Player-1-0000000A")
	H.eq(m.h, env.tab:Hash(), "hash") H.eq(m.n, 1, "sheets")
end)

H.test("sync 1: no hello ND when an equal ND was heard 599 s ago, one at 601 s", function()
	for _, case in ipairs({ { 589, 0 }, { 591, 1 } }) do
		local env = newEnv({ random = 0.5 })
		incoming(env, "ND", { h = env.tab:Hash(), n = 0 })
		env.run(case[1])
		env.sync:Announce()
		env.run(10.5)
		H.eq(#sentOf(env, "ND"), case[2], "heard " .. (case[1] + 10) .. " s before")
	end
end)

H.test("sync 1: an unconfirmed ND is repeated at most 3 times, a confirmed one not", function()
	local env = newEnv()
	env.sync:Announce()
	env.run(5000)
	H.eq(#sentOf(env, "ND"), 4, "first and 3 repeats")
	local nd = sentOf(env, "ND")
	for i = 2, 4 do
		local gap = nd[i].t - nd[i - 1].t
		H.ok(gap >= 60 and gap <= 120, "repeat after 60-120 s: " .. gap)
	end
	env = newEnv()
	env.sync:Announce()
	env.run(11)
	incoming(env, "ND", { h = env.tab:Hash(), n = 0 }, "Cid-Realm")
	env.run(5000)
	H.eq(#sentOf(env, "ND"), 1, "confirmed")
end)

-- Rule 2 ----------------------------------------------------------------------

H.test("sync 2: a differing ND plans an NI in 2-20 s", function()
	for _, r in ipairs({ 0, 0.999 }) do
		local env = newEnv({ random = r })
		incoming(env, "ND", { h = 777, n = 3 })
		env.run(60)
		local list = sentOf(env, "NI")
		H.eq(#list, 1, "one NI")
		H.ok(list[1].t >= 2 and list[1].t <= 20, "at " .. list[1].t)
	end
end)

H.test("sync 2: any NI heard cancels the planned NI", function()
	local env = newEnv({ random = 0.5 })
	incoming(env, "ND", { h = 777, n = 3 })
	env.run(1)
	incoming(env, "NI", { h = 888, r = 1, i = {}, c = {} }, "Cid-Realm")
	env.run(300)
	H.eq(#sentOf(env, "NI"), 0)
end)

H.test("sync 2: the second own NI not before 65 s", function()
	local env = newEnv({ random = 0 })
	incoming(env, "ND", { h = 777, n = 3 })
	env.run(3)
	H.eq(#sentOf(env, "NI"), 1, "first NI at 2 s")
	incoming(env, "ND", { h = 778, n = 3 }, "Cid-Realm")
	env.run(300)
	local list = sentOf(env, "NI")
	H.eq(#list, 2, "second NI")
	H.ok(list[2].t >= list[1].t + 65 and list[2].t <= list[1].t + 66, "at " .. list[2].t)
end)

H.test("sync 2: under constant NU the NI goes 120 s after planning plus one poll", function()
	local env = newEnv({ random = 0.5 })
	incoming(env, "ND", { h = 777, n = 3 })
	for t = 1, 300, 5 do
		env.runTo(t)
		incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
	end
	local list = sentOf(env, "NI")
	H.eq(#list, 1, "one NI")
	H.ok(list[1].t > 120 and list[1].t <= 144, "at " .. list[1].t)
end)

H.test("sync 2: the planned NI is dropped when the ND's hash is ours by then", function()
	local env = newEnv({ random = 0.5 })
	local A = sheet(1001, { 1, 2 })
	incoming(env, "ND", { h = hashWith({ { 1001, A } }), n = 1 })
	env.run(5)
	incoming(env, "NU", { h = 555, x = { packed(1001, A) } }, "Cid-Realm")
	H.eq(env.tab:Hash(), hashWith({ { 1001, A } }), "hash reached")
	env.run(300)
	H.eq(#sentOf(env, "NI"), 0)
end)

-- Rule 3 ----------------------------------------------------------------------

local function threeSheets(env)
	hold(env, 1001, { 1 }) hold(env, 1002, { 2 }) hold(env, 1003, { 3 })
end

H.test("sync 3: NU of the sheets an NI lacks or has with another hash, after 0.5-10 s", function()
	local env = newEnv({ random = 0.5 })
	threeSheets(env)
	ni(env, { 1001, 1002 }, { [1001] = true })
	env.run(100)
	local nu = sentOf(env, "NU")
	H.eq(#nu, 1, "one NU")
	H.eq(idsOf(nu[1]), "1002,1003")
	H.ok(math.abs(nu[1].t - 5.25) < 1e-9, "at 0.5 + 9.5 * 0.5: " .. nu[1].t)
	for _, r in ipairs({ 0, 0.999 }) do
		env = newEnv({ random = r })
		threeSheets(env)
		ni(env, {}, nil)
		env.run(100)
		nu = sentOf(env, "NU")
		H.ok(nu[1].t >= 0.5 and nu[1].t <= 10, "at " .. nu[1].t)
	end
end)

H.test("sync 3: a sheet heard meanwhile in identical content is left out and postpones the rest 40-60 s", function()
	local env = newEnv({ random = 0.5 })
	threeSheets(env)
	ni(env, { 1001, 1002 }, { [1001] = true })
	env.run(2)
	incoming(env, "NU", { h = 555, x = { packed(1003, env.tab:Sendable(1003)) } }, "Cid-Realm")
	env.run(200)
	local nu = sentOf(env, "NU")
	H.eq(#nu, 1, "one NU")
	H.eq(idsOf(nu[1]), "1002", "1003 left out")
	H.ok(math.abs(nu[1].t - 52) < 1e-9, "postponed to 2 + 50: " .. nu[1].t)
end)

H.test("sync 3: an NU without a planned sheet does not postpone", function()
	local env = newEnv({ random = 0.5 })
	threeSheets(env)
	ni(env, { 1001, 1002 }, { [1001] = true })
	env.run(2)
	incoming(env, "NU", { h = 555, x = { packed(1001, env.tab:Sendable(1001)), packed(1009, sheet(1009, { 9 })) } }, "Cid-Realm")
	incoming(env, "NU", { h = 556, x = {} }, "Dan-Realm")
	env.run(200)
	local nu = sentOf(env, "NU")
	H.eq(#nu, 1)
	H.eq(idsOf(nu[1]), "1002,1003")
	H.ok(math.abs(nu[1].t - 5.25) < 1e-9, "not postponed: " .. nu[1].t)
end)

H.test("sync 3: all planned for the NI sender is dropped when its hash becomes ours", function()
	local env = newEnv({ random = 0.5 })
	threeSheets(env)
	ni(env, {}, nil)
	env.run(2)
	incoming(env, "ND", { h = env.tab:Hash(), n = 3 })
	env.run(200)
	H.eq(#sentOf(env, "NU"), 0)
end)

-- Rule 4 ----------------------------------------------------------------------

H.test("sync 4: one NR to the NI's sender after 1-8 s for the IDs we lack", function()
	for _, r in ipairs({ 0, 0.5, 0.999 }) do
		local env = newEnv({ random = r })
		hold(env, 1001, { 1 })
		ni(env, { 1001, 5000, 5001 }, { [1001] = true })
		env.run(100)
		local nr = sentOf(env, "NR")
		H.eq(#nr, 1, "one NR")
		H.ok(nr[1].t >= 1 and nr[1].t <= 8, "at " .. nr[1].t)
		H.eq(nr[1].msg.to, "Bob-Realm", "to the sender")
		H.eq(table.concat(nr[1].msg.i, ","), "5000,1", "deltas of 5000, 5001")
	end
end)

H.test("sync 4: IDs in NRs or NUs heard are not asked for", function()
	local env = newEnv({ random = 0.5 })
	ni(env, { 5000, 5001 }, nil)
	env.run(1)
	incoming(env, "NR", { h = 1, to = "Bob-Realm", i = { 5000 } }, "Cid-Realm")
	incoming(env, "NU", { h = 1, x = { packed(5001, sheet(5001, { 1 })) } }, "Dan-Realm")
	env.run(100)
	H.eq(#sentOf(env, "NR"), 0)
end)

H.test("sync 4: no NR when 10 NRs to that sender were heard in the last hour", function()
	for _, case in ipairs({ { 9, 1 }, { 10, 0 } }) do
		local env = newEnv({ random = 0.5 })
		for i = 1, case[1] do
			incoming(env, "NR", { h = 1, to = "Bob-Realm", i = { i } }, "Cid-Realm")
			env.run(1)
		end
		env.run(50)
		ni(env, { 5000 }, nil)
		env.run(100)
		H.eq(#sentOf(env, "NR"), case[2], case[1] .. " heard")
	end
	local env = newEnv({ random = 0.5 })
	for i = 1, 10 do incoming(env, "NR", { h = 1, to = "Bob-Realm", i = { i } }, "Cid-Realm") end
	env.run(3601)
	ni(env, { 5000 }, nil)
	env.run(100)
	H.eq(#sentOf(env, "NR"), 1, "an hour later")
end)

H.test("sync 4: the NI sender echoes a merged sheet once per round, only when ours adds", function()
	local env = newEnv({ random = 0 })
	hold(env, 1001, { 1, 2 })
	incoming(env, "ND", { h = 777, n = 1 })
	env.run(3)
	H.eq(#sentOf(env, "NI"), 1, "own NI")
	incoming(env, "NU", { h = 777, x = { packed(1001, sheet(1001, { 1 })) } })
	env.run(5)
	incoming(env, "NU", { h = 777, x = { packed(1001, sheet(1001, { 1 })) } }, "Cid-Realm")
	env.run(5)
	local nu = sentOf(env, "NU")
	H.eq(#nu, 1, "one echo")
	H.eq(nu[1].t, 5, "2 s after")
	local _, s = ND.Unpack(nu[1].msg.x[1], DAY)
	H.ok(s.t[1] and s.t[2], "merged sheet")
	-- ours adds nothing
	env = newEnv({ random = 0 })
	hold(env, 1001, { 1, 2 })
	incoming(env, "ND", { h = 777, n = 1 })
	env.run(3)
	incoming(env, "NU", { h = 777, x = { packed(1001, sheet(1001, { 1, 2, 3 })) } })
	env.run(30)
	H.eq(#sentOf(env, "NU"), 0, "no echo")
	-- not our round: no echo
	env = newEnv({ random = 0 })
	hold(env, 1001, { 1, 2 })
	incoming(env, "NU", { h = 777, x = { packed(1001, sheet(1001, { 1 })) } })
	env.run(30)
	H.eq(#sentOf(env, "NU"), 0, "no own NI")
end)

H.test("sync 4: a sheet the limits refuse is listed in own NI with the received content and not asked for", function()
	local env = newEnv({ random = 0.5, limits = { sheets = 1 } })
	hold(env, 1001, { 1 })
	local R = sheet(2001, { 5 }, DAY - 5)
	incoming(env, "NU", { h = 1, x = { packed(2001, R) } }, "Cid-Realm")
	H.eq(env.tab:Sendable(2001), nil, "refused")
	env.run(60)
	ni(env, { 2001 }, nil, 999, "Dan-Realm")
	env.run(30)
	H.eq(#sentOf(env, "NR"), 0, "not asked for")
	env.run(100)
	incoming(env, "ND", { h = 777, n = 1 })
	env.run(100)
	local list = sentOf(env, "NI")
	H.eq(#list, 1)
	local m = list[1].msg
	H.eq(table.concat(m.i, ","), "1001,1000", "both listed")
	H.eq(m.c[2], ND.SaltedHash(ND.HashSheet(2001, select(2, ND.Unpack(packed(2001, R), DAY))), m.r), "received content")
end)

H.test("sync 4: at most 100 refused sheets are remembered; one taken in part is not", function()
	local env = newEnv({ random = 0.5, limits = { sheets = 1 } })
	hold(env, 1001, { 1 })
	local x = {}
	for i = 1, 101 do x[i] = packed(2000 + i, sheet(2000 + i, { 5 }, DAY - 5)) end
	incoming(env, "NU", { h = 1, x = x }, "Cid-Realm")
	env.run(100)
	incoming(env, "ND", { h = 777, n = 1 })
	env.run(100)
	local m = sentOf(env, "NI")[1].msg
	H.eq(#m.i, 101, "own sheet and 100 remembered")
	H.eq(m.i[1] + m.i[2], 2002, "the first refused is forgotten")

	env = newEnv({ random = 0.5, limits = { t = 1 } })
	local P = sheet(3001, { 7, 8 })
	incoming(env, "NU", { h = 1, x = { packed(3001, P) } }, "Cid-Realm")
	env.run(100)
	incoming(env, "ND", { h = 777, n = 1 })
	env.run(100)
	m = sentOf(env, "NI")[1].msg
	H.eq(m.c[1], env.tab:SaltedHash(env.tab:SheetHash(3001), m.r), "listed with our content")
end)

-- Rule 5 ----------------------------------------------------------------------

H.test("sync 5: ND 12-24 s after the last message of a round when the hash changed, at most one per 30 s", function()
	local env = newEnv({ random = 0 })
	incoming(env, "NU", { h = 1, x = { packed(1001, sheet(1001, { 1 })) } })
	env.run(13)
	local nd = sentOf(env, "ND")
	H.eq(#nd, 1, "one ND")
	H.eq(nd[1].t, 12, "12 s after")
	incoming(env, "NU", { h = 1, x = { packed(1002, sheet(1002, { 1 })) } })
	env.run(45)
	H.eq(#sentOf(env, "ND"), 1, "not again within 30 s")
	env = newEnv({ random = 0.999 })
	incoming(env, "NU", { h = 1, x = { packed(1001, sheet(1001, { 1 })) } })
	env.run(30)
	nd = sentOf(env, "ND")
	H.ok(#nd == 1 and nd[1].t <= 24 and nd[1].t >= 23, "24 s after")
	-- an equal ND heard meanwhile
	env = newEnv({ random = 0 })
	incoming(env, "NU", { h = 1, x = { packed(1001, sheet(1001, { 1 })) } })
	env.run(5)
	incoming(env, "ND", { h = env.tab:Hash(), n = 1 }, "Cid-Realm")
	env.run(30)
	H.eq(#sentOf(env, "ND"), 0, "equal heard")
end)

-- Rule 6 ----------------------------------------------------------------------

H.test("sync 6: muted after 2 fruitless rounds, lifted by a change of either hash", function()
	local env = newEnv({ random = 0 })
	hold(env, 1001, { 1 })
	for _, t in ipairs({ 0, 100, 200 }) do
		env.runTo(t)
		incoming(env, "ND", { h = 777, n = 3 })
	end
	env.runTo(300)
	H.eq(#sentOf(env, "NI"), 2, "third ND muted")
	incoming(env, "ND", { h = 778, n = 3 })
	env.runTo(400)
	H.eq(#sentOf(env, "NI"), 3, "their hash changed")
	incoming(env, "NU", { h = 1, x = { packed(1002, sheet(1002, { 1 })) } }, "Cid-Realm")
	env.runTo(500)
	incoming(env, "ND", { h = 777, n = 3 })
	env.runTo(600)
	H.eq(#sentOf(env, "NI"), 4, "our hash changed")
end)

H.test("sync 6: muted after 3 own NIs for the pair", function()
	local env = newEnv({ random = 0 })
	hold(env, 1001, { 1 })
	for _, t in ipairs({ 0, 100, 200, 300 }) do
		env.runTo(t)
		incoming(env, "ND", { h = 777, n = 3 })
		env.run(5)
		incoming(env, "NR", { h = 1, to = "Dan-Realm", i = { 9 } }, "Cid-Realm")
	end
	env.runTo(400)
	H.eq(#sentOf(env, "NI"), 3)
end)

H.test("sync 6: a round silenced by the NR cap is not counted", function()
	local env = newEnv({ random = 0 })
	for i = 1, 10 do incoming(env, "NR", { h = 1, to = "Bob-Realm", i = { i } }, "Cid-Realm") end
	env.runTo(50)
	incoming(env, "NI", { h = 777, r = 1, i = { 5000 }, c = { 1 } })
	env.runTo(150)
	incoming(env, "NI", { h = 777, r = 1, i = { 5000 }, c = { 1 } })
	env.runTo(250)
	H.eq(#sentOf(env, "NR"), 0, "capped")
	incoming(env, "ND", { h = 777, n = 1 })
	env.runTo(350)
	H.eq(#sentOf(env, "NI"), 1, "not muted")
end)

-- Rule 7 ----------------------------------------------------------------------

H.test("sync 7: a planned NU is sent when the block ends at 29 s, dropped at 31 s", function()
	for _, case in ipairs({ { 29.2, 1 }, { 31.2, 0 } }) do
		local env = newEnv({ random = 0 })
		hold(env, 1001, { 1 })
		ni(env, {}, nil)
		env.run(0.1)
		env.blocked = true
		env.runTo(case[1])
		env.blocked = false
		env.run(100)
		local nu = sentOf(env, "NU")
		H.eq(#nu, case[2], "block until " .. case[1])
		if case[2] == 1 then H.eq(nu[1].t, 29.5, "first try after the block") end
	end
end)

H.test("sync 7: NR, NI and ND are dropped while blocked; one ND 10-20 s after the block", function()
	local env = newEnv({ random = 0.5 })
	env.blocked = true
	env.sync:Announce()
	incoming(env, "ND", { h = 777, n = 3 })
	ni(env, { 5000 }, nil, 778, "Cid-Realm")
	env.runTo(100)
	env.blocked = false
	env.runTo(130)
	H.eq(#sentOf(env, "NI"), 0, "NI dropped")
	H.eq(#sentOf(env, "NR"), 0, "NR dropped")
	local nd = sentOf(env, "ND")
	H.eq(#nd, 1, "one ND after the block")
	H.ok(nd[1].t >= 110 and nd[1].t <= 125, "10-20 s after the block (5 s poll): " .. nd[1].t)
end)

H.test("sync 7: no ND after a block when nothing was dropped or due", function()
	local env = newEnv({ random = 0.5 })
	env.blocked = true
	env.runTo(100)
	env.blocked = false
	env.runTo(300)
	H.eq(#env.sent, 0)
end)

-- Rule 8 ----------------------------------------------------------------------

local reading = { name = "Trainer 1001", map = 1453, x = 50, y = 40, t = { [11] = { skill = 50, copper = 900 } } }

H.test("sync 8: an own visit sends the whole sheet after 3 s; one that changed nothing sends nothing", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1, 2 })
	H.eq(env.sync:OwnVisit(1001, reading), true, "changed")
	env.run(2.9)
	H.eq(#sentOf(env, "NU"), 0, "not before 3 s")
	env.run(0.2)
	local nu = sentOf(env, "NU")
	H.eq(#nu, 1)
	local _, s = ND.Unpack(nu[1].msg.x[1], DAY)
	H.ok(s.t[1] and s.t[2] and s.t[11], "whole sheet")
	H.eq(env.sync:OwnVisit(1001, reading), false, "same reading")
	env.run(100)
	H.eq(#sentOf(env, "NU"), 1, "no message")
end)

H.test("sync 8: an own visit while blocked waits like an NU", function()
	for _, case in ipairs({ { 20, 1 }, { 40, 0 } }) do
		local env = newEnv({ random = 0 })
		env.blocked = true
		env.sync:OwnVisit(1001, reading)
		env.runTo(case[1])
		env.blocked = false
		env.run(100)
		H.eq(#sentOf(env, "NU"), case[2], "block until " .. case[1])
	end
end)

-- Rule 9 ----------------------------------------------------------------------

H.test("sync 9: a second NI within 60 s of one sender is ignored, also with a forged s", function()
	for _, case in ipairs({ { 30, "1001" }, { 61, "1001,1002" } }) do
		local env = newEnv({ random = 0.5 })
		hold(env, 1001, { 1 }) hold(env, 1002, { 2 })
		ni(env, { 1002 }, { [1002] = true })
		env.runTo(case[1])
		local c = { env.tab:SaltedHash(env.tab:SheetHash(1001), 5) }
		env.sync:OnMessage({ t = "NI", pv = 1, e = 1, f = "Alliance", s = "Player-1-0000000F", h = 999, r = 5,
			i = { 1001 }, c = c }, "Bob-Realm", 100)
		env.run(200)
		local got = {}
		for _, nu in ipairs(sentOf(env, "NU")) do got[#got + 1] = idsOf(nu) end
		table.sort(got)
		H.eq(table.concat(got, ","), case[2], "second NI at " .. case[1])
	end
end)

H.test("sync 9: a third ND within a minute of one sender is ignored", function()
	for _, case in ipairs({ { 2, 1 }, { 61, 0 } }) do
		local env = newEnv({ random = 0.5 })
		incoming(env, "ND", { h = 11, n = 1 })
		incoming(env, "ND", { h = 12, n = 1, s = "Player-1-0000000F" })
		env.runTo(case[1])
		incoming(env, "ND", { h = env.tab:Hash(), n = 0, s = "Player-1-0000000E" })
		env.sync:Announce()
		env.run(10.5)
		H.eq(#sentOf(env, "ND", case[1] + 9), case[2], "third ND at " .. case[1])
	end
end)

H.test("sync 9: one content at most 6 times an hour per sender name and per NI hash", function()
	-- one sender, other hashes
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	for i = 0, 7 do
		env.runTo(i * 61)
		ni(env, {}, nil, 1000 + i)
	end
	env.run(100)
	H.eq(#sentOf(env, "NU"), 6, "per sender name")
	-- other senders, one hash
	env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	for i = 0, 7 do
		env.runTo(i * 61)
		ni(env, {}, nil, 4242, "S" .. i .. "-Realm")
	end
	env.run(100)
	H.eq(#sentOf(env, "NU"), 6, "per NI hash")
	-- an hour later again
	env.runTo(3700)
	ni(env, {}, nil, 4242, "Late-Realm")
	env.run(100)
	H.eq(#sentOf(env, "NU"), 7, "after an hour")
end)

H.test("sync 9: a counter rises at most once per 60 s", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	for i = 0, 11 do
		env.runTo(i * 10)
		incoming(env, "NR", { h = 1, to = "Me-Realm", i = { 1001 } })
	end
	env.run(100)
	H.eq(#sentOf(env, "NU"), 12, "12 NRs in 2 minutes raise it twice")
end)

H.test("sync 9: an NR raises the name counter only", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	for i = 0, 5 do
		env.runTo(i * 61)
		incoming(env, "NR", { h = 4242, to = "Cid-Realm", i = { 1001 } })
	end
	env.runTo(400)
	ni(env, {}, nil, 4242)
	env.run(30)
	H.eq(#sentOf(env, "NU"), 0, "the name's 7th")
	ni(env, {}, nil, 4242, "Dan-Realm")
	env.run(30)
	H.eq(#sentOf(env, "NU"), 1, "the hash counter was not raised")
end)

-- Rule 10 ---------------------------------------------------------------------

H.test("sync 10: an ND failed by a block is followed by an ND after the block", function()
	local env = newEnv({ random = 0 })
	env.fail.ND = "blockfail"
	env.sync:Announce()
	env.runTo(11)
	H.eq(#sentOf(env, "ND"), 1, "failed")
	env.fail.ND = nil
	env.runTo(40)
	env.blocked = false
	env.runTo(80)
	local nd = sentOf(env, "ND")
	H.eq(#nd, 2, "again")
	H.ok(nd[2].t >= 50 and nd[2].t <= 65, "10-20 s after the block (5 s poll): " .. nd[2].t)
end)

H.test("sync 7, 10: an ND whose send always fails is not repeated in a loop", function()
	for _, mode in ipairs({ "fail", "never" }) do
		local env = newEnv({ random = 0.5 })
		env.fail.ND = mode
		env.sync:Announce()
		env.run(600)
		H.ok(#sentOf(env, "ND") <= 4, mode .. ": " .. #sentOf(env, "ND") .. " NDs in 600 s (1 and 3 repeats of rule 1)")
	end
end)

H.test("sync 7, 10: an NU whose send always fails is dropped 30 s after its first attempt", function()
	for _, mode in ipairs({ "fail", "never" }) do
		local env = newEnv({ random = 0.5 })
		hold(env, 1001, { 1 })
		env.mode = mode
		ni(env, {}, nil)
		env.run(600)
		local n = #sentOf(env, "NU")
		H.ok(n >= 1 and n <= 16, mode .. ": " .. n .. " NUs in 600 s (every 2 s for 30 s)")
		H.ok(#sentOf(env, "ND") <= 5, mode .. ": NDs bounded")
		H.ok(#env.sent <= 25, mode .. ": " .. #env.sent .. " messages in all")
		-- sending works again: the sheet reaches a peer
		env.mode = "ok"
		local from = env.t
		ni(env, {}, nil, 998, "Cid-Realm")
		env.run(30)
		local nu = sentOf(env, "NU", from)
		H.ok(#nu == 1 and idsOf(nu[1]) == "1001", mode .. ": sent once sending works")
	end
end)

H.test("sync 7, 8, 10: an own visit NU whose send always fails is dropped 30 s after its first attempt", function()
	for _, mode in ipairs({ "fail", "never" }) do
		local env = newEnv({ random = 0.5 })
		env.mode = mode
		env.sync:OwnVisit(1001, reading)
		env.run(600)
		local n = #sentOf(env, "NU")
		H.ok(n >= 1 and n <= 16, mode .. ": " .. n .. " NUs in 600 s")
		H.ok(#env.sent <= 25, mode .. ": " .. #env.sent .. " messages in all")
		env.mode = "ok"
		local from = env.t
		ni(env, {}, nil, 998, "Cid-Realm")
		env.run(30)
		local nu = sentOf(env, "NU", from)
		H.ok(#nu == 1 and idsOf(nu[1]) == "1001", mode .. ": sent once sending works")
	end
end)

H.test("sync 10: a failed NI does not hold back the next one 65 s", function()
	local env = newEnv({ random = 0 })
	env.fail.NI = "fail"
	incoming(env, "ND", { h = 777, n = 3 })
	env.run(10)
	incoming(env, "ND", { h = 778, n = 3 }, "Cid-Realm")
	env.run(100)
	local list = sentOf(env, "NI")
	H.ok(#list >= 2 and list[2].t < 30, "second NI at " .. tostring(list[2] and list[2].t))
end)

H.test("sync 10: a failed NR is not counted for the cap", function()
	for _, case in ipairs({ { "fail", 2 }, { "ok", 1 } }) do
		local env = newEnv({ random = 0.5 })
		env.fail.NR = case[1]
		for i = 1, 9 do incoming(env, "NR", { h = 1, to = "Bob-Realm", i = { i } }, "Cid-Realm") end
		ni(env, { 5000 }, nil)
		env.runTo(100)
		ni(env, { 5000 }, nil)
		env.run(100)
		H.eq(#sentOf(env, "NR"), case[2], case[1])
	end
end)

H.test("sync 10: a failed NU is tried again 1-3 s later", function()
	local env = newEnv({ random = 0 })
	hold(env, 1001, { 1 })
	env.fail.NU = "fail"
	ni(env, {}, nil)
	env.run(1)
	env.fail.NU = nil
	env.run(10)
	local nu = sentOf(env, "NU")
	H.eq(#nu, 2)
	H.eq(nu[2].t, 1.5, "1 s after")
end)

H.test("sync 10: no done in 30 s plus 1 s per part is a failure, a late done is ignored", function()
	local env = newEnv({ random = 0 })
	env.fail.ND = "never"
	env.sync:Announce()
	env.runTo(10)
	local first = sentOf(env, "ND")[1]
	H.ok(first, "sent")
	env.runTo(40.9)
	H.eq(#sentOf(env, "ND"), 1, "still waiting")
	env.runTo(41.1)
	env.fail.ND = nil
	-- the failure undid lastND (rule 10): a round ending now may send its ND without the 30 s gap
	incoming(env, "NU", { h = 1, x = { packed(1001, sheet(1001, { 1 })) } })
	env.runTo(41.1 + 24.5)
	local nd = sentOf(env, "ND")
	H.eq(#nd, 2, "rule 5 ND after the failure")
	first.done(true) -- late
	env.run(100)
	H.ok(true, "no error")
end)

H.test("sync 10: after Stop() no timer sends", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	env.sync:Announce()
	incoming(env, "ND", { h = 777, n = 3 })
	ni(env, { 5000 }, nil, 999, "Cid-Realm")
	env.sync:OwnVisit(1001, reading)
	env.sync:Stop()
	env.run(1000)
	H.eq(#env.sent, 0)
	incoming(env, "NR", { h = 1, to = "Me-Realm", i = { 1001 } })
	env.sync:Announce()
	env.run(100)
	H.eq(#env.sent, 0, "dead")
end)

-- Foreign and hostile ---------------------------------------------------------

H.test("sync: other protocol, epoch and faction are ignored without changing state", function()
	local env = newEnv({ random = 0.5 })
	local x = { packed(1001, sheet(1001, { 1 })) }
	for _, f in ipairs({ { pv = 2 }, { e = 2 }, { f = "Horde" }, { pv = "1" }, { f = false } }) do
		local fields = { h = env.tab:Hash(), n = 0, x = x, r = 1, i = { 5000 }, c = { 1 }, to = "Me-Realm" }
		for k, v in pairs(f) do fields[k] = v end
		for _, t in ipairs({ "ND", "NI", "NR", "NU" }) do incoming(env, t, fields, "X" .. t .. "-Realm") end
	end
	H.eq(env.tab:Count(), 0, "nothing merged")
	H.eq(env.sync.stats.foreign, 20, "counted")
	env.sync:Announce()
	env.run(80)
	H.eq(#sentOf(env, "ND"), 1, "no equal ND was taken")
	H.eq(#sentOf(env, "NI") + #sentOf(env, "NR") + #sentOf(env, "NU"), 0, "nothing planned")
end)

H.test("sync: own messages echoed by the game are ignored", function()
	local env = newEnv({ random = 0.5 })
	incoming(env, "ND", { h = 777, n = 1 }, "Me-Realm")
	incoming(env, "NU", { h = 777, x = { packed(1001, sheet(1001, { 1 })) } }, "Me-Realm")
	env.run(100)
	H.eq(#env.sent, 0)
	H.eq(env.tab:Count(), 0)
end)

H.test("sync: hostile fields give no error", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	local nan, inf = 0 / 0, math.huge
	local huge = {}
	for i = 1, 100000 do huge[i] = 1 end
	local msgs = {
		{ "ND", { h = nan } }, { "ND", { h = 1.5 } }, { "ND", { h = -1 } }, { "ND", { h = inf } }, { "ND", { h = "1" } },
		{ "ND", { h = 2147483647 } }, { "ND", { n = "x" } }, { "ND", { n = 601 } }, { "ND", { n = nan } },
		{ "NI", { r = 1, i = { 1, -1 }, c = { 1, 1 } } }, { "NI", { r = 1, i = huge, c = huge } },
		{ "NI", { r = 1, i = { 1 }, c = {} } }, { "NI", { r = 1, i = { 1 }, c = { nan } } },
		{ "NI", { r = 70000, i = {}, c = {} } }, { "NI", { r = 1, i = { 0.5 }, c = { 1 } } },
		{ "NI", { r = 1, i = "x", c = {} } }, { "NI", { r = 1, i = { 2147483647, 5 }, c = { 1, 1 } } },
		{ "NI", { r = 1, i = { 1 }, c = { 65536 } } }, { "NI", { r = nan, i = {}, c = {} } },
		{ "NR", { to = {}, i = { 1 } } }, { "NR", { to = "Me-Realm", i = { 0.5 } } },
		{ "NR", { to = "Me-Realm", i = { 7000, 1, 1 } } }, { "NR", { to = ("x"):rep(500), i = { 1 } } },
		{ "NR", { to = "Me-Realm\0|cff", i = huge } },
		{ "NU", { x = "x" } }, { "NU", { x = { {} } } }, { "NU", { x = { { 1.5 } } } }, { "NU", { x = huge } },
		{ "NU", { x = { { 1001, 5 }, { -3 }, { 1001, false, false, false, false, false, false, nan } } } },
		{ "NU", { x = { { 2002, "n", 0, 1, 2, 3, 0, DAY + 5000, { 1 }, { 1 }, { 1 }, 0, 0, 0, {}, {}, {}, 0, 0, {} } } } },
		{ "XX", {} }, { nil, {} },
	}
	for _, m in ipairs(msgs) do incoming(env, m[1], m[2], "Evil-Realm") end
	env.sync:OnMessage(nil, "Evil-Realm", 1)
	env.sync:OnMessage("x", "Evil-Realm", 1)
	env.sync:OnMessage({ t = "ND", pv = 1, e = 1, f = "Alliance", h = 1, n = 1 }, nil, 1)
	env.sync:OnMessage({ t = "ND", pv = 1, e = 1, f = "Alliance", h = 1, n = 1 }, ("y"):rep(1000), 1)
	env.run(300)
	H.eq(env.tab:Count(), 1, "table unchanged")
	H.eq(#sentOf(env, "NU"), 0, "no NU for unknown IDs")
end)

H.test("sync: lists with holes, other keys and nested junk give no error, also through the wire", function()
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	local good = packed(1002, sheet(1002, { 2 }))
	local cases = {
		{ "NU", { x = { good, good, nil, good } } }, { "NU", { x = { [1] = good, [3] = good } } },
		{ "NU", { x = { 5, 5, nil, 5, 5, 5, 5, 5 } } }, { "NU", { x = { good, "s", 5 } } },
		{ "NU", { x = { [0] = good } } }, { "NU", { x = { good, a = good } } }, { "NU", { x = { [1.5] = good } } },
		{ "NU", { x = { { { {} } }, { 1002, { {} }, { "x" } } } } },
		{ "NU", { x = { { 1002, "n", 0, false, false, false, false, 20000, { 1, nil, 2 }, { 5, nil, 5 }, { 1 }, 0, 0, 0, {}, {}, {}, 0, 0, {} } } } },
		{ "NI", { r = 1, i = { 1001, nil, 3 }, c = { 1, nil, 1 } } }, { "NI", { r = 1, i = { 1001 }, c = { [2] = 1 } } },
		{ "NI", { r = 1, i = { [1] = 1001, [3] = 1 }, c = { 1, 1 } } }, { "NI", { r = 1, i = { 1001, x = 1 }, c = { 1 } } },
		{ "NI", { r = 1, i = { {} }, c = { {} } } }, { "NI", { r = 1, i = { 1001 }, c = { "1" } } },
		{ "NR", { to = "Me-Realm", i = { 1001, nil, 1 } } }, { "NR", { to = { "Me-Realm" }, i = { 1001 } } },
		{ "NR", { to = "Me-Realm", i = { [2] = 1001 } } }, { "NR", { to = "Me-Realm", i = { { 1001 } } } },
		{ "ND", { n = { 1 } } },
	}
	for _, m in ipairs(cases) do
		local msg = { t = m[1], pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "Player-1-0000000B", h = 7 }
		for k, v in pairs(m[2]) do msg[k] = v end
		local ok, wire = LS:Deserialize(LS:Serialize(msg))
		H.ok(ok, "round trip")
		for _, x in ipairs({ msg, wire }) do
			local done, err = pcall(env.sync.OnMessage, env.sync, x, "Evil-Realm", 100)
			H.ok(done, tostring(err))
		end
	end
	env.run(300)
	H.eq(env.tab:Count(), 1, "nothing taken")
	H.eq(#sentOf(env, "NU"), 0, "nothing answered")
	H.eq(NS.sequence({ 1, 2, 3 }, 600), 3) H.eq(NS.sequence({}, 600), 0) H.eq(NS.sequence({ 1, nil, 3 }, 600), nil)
end)

H.test("sync: a sheet's packed content hashes the same at the receiver", function()
	local a, b = newEnv(), newEnv()
	hold(a, 1001, { 1, 2, 3 })
	a.tab:MergeIn(1002, { name = "Vendor", nd = DAY - 3, t = {},
		v = { [55] = { DAY, { c = 100, o = { { 1, 7, 2 } }, l = 1 }, DAY }, [56] = { DAY - 2, false, 0 } } })
	for _, id in ipairs({ 1001, 1002 }) do
		incoming(b, "NU", { h = 1, x = { packed(id, a.tab:Sendable(id)) } })
		H.eq(b.tab:SheetHash(id), a.tab:SheetHash(id), "sheet " .. id)
	end
	H.eq(b.tab:Hash(), a.tab:Hash(), "table")
	H.ok(b.changes > 0, "changed() called")
end)

-- Exact bounds and times the tests above leave open (the 0.7.0 mutation check) ----

local function near(a, b) return math.abs(a - b) < 1e-6 end
local R1 = 0.9999 -- random() near its top: a range [lo, hi] gives lo + (hi - lo) * R1

H.test("sync bounds: an equal ND heard exactly 600 s before the hello holds it back", function()
	local env = newEnv({ random = 0.5 })
	incoming(env, "ND", { h = env.tab:Hash(), n = 0 })
	env.run(590)
	env.sync:Announce()
	env.run(10.5)
	H.eq(#sentOf(env, "ND"), 0, "600 s")
end)

H.test("sync bounds: an ND is repeated 60 s after it at the lowest random, 120 s at the highest", function()
	for _, r in ipairs({ 0, R1 }) do
		local env = newEnv({ random = r })
		env.sync:Announce()
		env.run(1000)
		local nd = sentOf(env, "ND")
		H.eq(#nd, 4, "first and 3 repeats")
		for i = 2, 4 do H.ok(near(nd[i].t - nd[i - 1].t, 60 + 60 * r), "repeat after " .. (nd[i].t - nd[i - 1].t)) end
	end
end)

H.test("sync bounds: an ND repeat waits until 12 s after the last data plus 0-8 s", function()
	-- random 0: ND at 10, check at 70, an NU at 65: the repeat at 65 + 12
	local env = newEnv({ random = 0 })
	env.sync:Announce()
	env.runTo(65)
	incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
	env.runTo(200)
	local nd = sentOf(env, "ND")
	H.ok(nd[2] and near(nd[2].t, 77), "repeat at " .. tostring(nd[2] and nd[2].t))
	-- random 0.5: ND at 10, check at 100, an NU at 95: 100 + 12 - 5 + 4
	env = newEnv({ random = 0.5 })
	env.sync:Announce()
	env.runTo(95)
	incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
	env.runTo(200)
	nd = sentOf(env, "ND")
	H.ok(nd[2] and near(nd[2].t, 111), "repeat at " .. tostring(nd[2] and nd[2].t))
end)

H.test("sync bounds: an equal ND heard while the own one goes out confirms it", function()
	local env = newEnv({ random = 0.5 })
	env.sync:Announce()
	env.runTo(10)
	H.eq(#sentOf(env, "ND"), 1)
	incoming(env, "ND", { h = env.tab:Hash(), n = 0 }, "Cid-Realm")
	env.run(5000)
	H.eq(#sentOf(env, "ND"), 1, "not repeated")
end)

H.test("sync bounds: the NI 2 s after the ND at the lowest random, 20 s at the highest; 12 s after data plus 0-12 s", function()
	for _, r in ipairs({ 0, R1 }) do
		local env = newEnv({ random = r })
		incoming(env, "ND", { h = 777, n = 3 })
		env.run(60)
		local list = sentOf(env, "NI")
		H.ok(#list == 1 and near(list[1].t, 2 + 18 * r), "NI at " .. tostring(list[1] and list[1].t))
	end
	-- random 0.5: the try at 11, an NU at 10: again 12 - 1 + 6 s later
	local env = newEnv({ random = 0.5 })
	incoming(env, "ND", { h = 777, n = 3 })
	env.runTo(10)
	incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
	env.run(60)
	local list = sentOf(env, "NI")
	H.ok(#list == 1 and near(list[1].t, 28), "NI at " .. tostring(list[1] and list[1].t))
end)

H.test("sync bounds: under data the NI waits while at most 120 s have passed since planning", function()
	-- random 0.5: tries at 11, then 18 - q later, q = seconds since the last NU; the last try at 120 or 120.5
	for _, case in ipairs({ { 2, 137 }, { 1.5, 120.5 } }) do
		local env = newEnv({ random = 0.5 })
		incoming(env, "ND", { h = 777, n = 3 })
		local t, qs = 11, { 2.5, 2.5, 2.5, 2.5, 2.5, 2.5, case[1] }
		env.runTo(t - 2.5)
		incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
		for i = 2, #qs do
			t = t + 18 - qs[i - 1]
			env.runTo(t - qs[i])
			incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
		end
		t = t + 18 - qs[#qs]
		env.runTo(t - 1)
		incoming(env, "NU", { h = 555, x = {} }, "Cid-Realm")
		env.runTo(300)
		local list = sentOf(env, "NI")
		H.ok(#list == 1 and near(list[1].t, case[2]), "last try at " .. t .. ": NI at " .. tostring(list[1] and list[1].t))
	end
end)

H.test("sync bounds: the second own NI 65.01 s after the first", function()
	local env = newEnv({ random = 0 })
	incoming(env, "ND", { h = 777, n = 3 })
	env.run(3)
	incoming(env, "ND", { h = 778, n = 3 }, "Cid-Realm")
	env.run(300)
	local list = sentOf(env, "NI")
	H.ok(#list == 2 and near(list[2].t, list[1].t + 65.01), "at " .. tostring(list[2] and list[2].t))
end)

H.test("sync bounds: the NI salt reaches 65535", function()
	local env = newEnv({ random = 0.99999 })
	incoming(env, "ND", { h = 777, n = 3 })
	env.run(60)
	H.eq(sentOf(env, "NI")[1].msg.r, 65535)
end)

H.test("sync bounds: NR 1 s after the NI at the lowest random, 8 s at the highest; the answer 2 s after an NR", function()
	for _, r in ipairs({ 0, R1 }) do
		local env = newEnv({ random = r })
		ni(env, { 5000 }, nil)
		env.run(100)
		local nr = sentOf(env, "NR")
		H.ok(#nr == 1 and near(nr[1].t, 1 + 7 * r), "NR at " .. tostring(nr[1] and nr[1].t))
	end
	local env = newEnv({ random = 0.5 })
	hold(env, 1001, { 1 })
	incoming(env, "NR", { h = 1, to = "Me-Realm", i = { 1001 } })
	env.run(100)
	local nu = sentOf(env, "NU")
	H.ok(#nu == 1 and near(nu[1].t, 2), "NU at " .. tostring(nu[1] and nu[1].t))
end)

H.test("sync bounds: the echo 6 s after the NU at the highest random", function()
	local env = newEnv({ random = R1 })
	hold(env, 1001, { 1, 2 })
	incoming(env, "ND", { h = 777, n = 1 })
	env.run(21)
	H.eq(#sentOf(env, "NI"), 1, "own NI")
	incoming(env, "NU", { h = 777, x = { packed(1001, sheet(1001, { 1 })) } })
	local at = env.t
	env.run(10)
	local nu = sentOf(env, "NU")
	H.ok(#nu == 1 and near(nu[1].t, at + 2 + 4 * R1), "echo at " .. tostring(nu[1] and nu[1].t))
end)

H.test("sync bounds: the round-end ND at least 30 s after the last ND", function()
	for _, case in ipairs({ { 30, 1 }, { 29, 0 } }) do
		local env = newEnv({ random = 0 })
		incoming(env, "NU", { h = 1, x = { packed(1001, sheet(1001, { 1 })) } })
		env.runTo(case[1])
		H.eq(#sentOf(env, "ND"), 1, "ND at 12")
		incoming(env, "NU", { h = 1, x = { packed(1002, sheet(1002, { 1 })) } })
		env.runTo(case[1] + 13)
		H.eq(#sentOf(env, "ND", 13), case[2], "second NU at " .. case[1] .. ", its round ends " .. (case[1] + 12))
	end
end)

H.test("sync bounds: a foreign hash heard exactly 120 s before a fruitless round's end is not counted", function()
	for _, case in ipairs({ { 108, 1 }, { 107.5, 0 } }) do
		local env = newEnv({ random = 0 })
		incoming(env, "ND", { h = 777, n = 3 }) -- own NI at 2, a fruitless round to 14
		env.runTo(case[1])
		incoming(env, "NI", { h = 888, r = 1, i = {}, c = {} }, "Cid-Realm") -- a round to case + 12
		env.runTo(130)
		incoming(env, "ND", { h = 777, n = 3 })
		env.runTo(200)
		H.eq(#sentOf(env, "NI", 130), case[2], "second round ends " .. (case[1] + 12))
	end
end)

H.test("sync bounds: a blocked NU waits exactly 30 s from its first attempt", function()
	-- an own visit: first attempt at 3, retries every 1 s (random 0), the last at 32, dropped at 33
	for _, case in ipairs({ { 31.5, 1 }, { 32.5, 0 } }) do
		local env = newEnv({ random = 0 })
		env.blocked = true
		env.sync:OwnVisit(1001, reading)
		env.runTo(case[1])
		env.blocked = false
		env.run(100)
		H.eq(#sentOf(env, "NU"), case[2], "block until " .. case[1])
	end
end)

H.test("sync bounds: a failed NU is tried again 3 s later at the highest random", function()
	local env = newEnv({ random = R1 })
	hold(env, 1001, { 1 })
	env.fail.NU = "fail"
	ni(env, {}, nil)
	env.run(11)
	env.fail.NU = nil
	env.run(10)
	local nu = sentOf(env, "NU")
	H.ok(#nu == 2 and near(nu[2].t - nu[1].t, 1 + 2 * R1), "again after " .. tostring(nu[2] and nu[2].t - nu[1].t))
end)

H.test("sync bounds: after a block the ND comes 10-20 s after the first 5 s poll that can send", function()
	for _, r in ipairs({ 0, R1 }) do
		local env = newEnv({ random = r })
		env.blocked = true
		env.sync:Announce() -- the ND at 10 is due while blocked: polls at 15, 20, ...
		env.runTo(17)
		env.blocked = false
		env.runTo(100)
		local nd = sentOf(env, "ND")
		H.ok(#nd >= 1 and near(nd[1].t, 20 + 10 + 10 * r), "ND at " .. tostring(nd[1] and nd[1].t))
	end
	-- an equal ND heard at most 60 s before holds it back
	for _, case in ipairs({ { 50, 0 }, { 49.5, 1 } }) do
		local env = newEnv({ random = 0 })
		env.blocked = true
		env.sync:Announce()
		env.runTo(case[1])
		incoming(env, "ND", { h = env.tab:Hash(), n = 0 }, "Cid-Realm")
		env.runTo(99)
		env.blocked = false -- the poll at 100 can send: the ND at 110
		env.runTo(160)
		H.eq(#sentOf(env, "ND"), case[2], "equal ND heard at " .. case[1])
	end
end)

H.test("sync bounds: no done within 30 s plus 1 s per part", function()
	local env = newEnv({ random = 0 })
	env.fail.ND = "never"
	env.sync:Announce()
	env.runTo(40.9)
	H.eq(env.sync.lastND, 10, "the ND of 10 s still counts at 40.9 s")
	env.runTo(41.1)
	H.eq(env.sync.lastND, -1e9, "failed at 41 s")
end)

H.test("sync bounds: one NI per sender within 60 s, at 60 s again", function()
	for _, case in ipairs({ { 60, 0 }, { 59.5, 1 } }) do
		local env = newEnv({ random = 0.5 })
		incoming(env, "NI", { h = 777, r = 1, i = {}, c = {} })
		env.runTo(case[1])
		incoming(env, "NI", { h = 777, r = 1, i = {}, c = {} })
		H.eq(env.sync.stats.capped, case[2], "second NI at " .. case[1])
	end
end)

H.test("sync bounds: two NDs per sender in a minute; the minute is 60 s", function()
	for _, case in ipairs({ { 1, 0 }, { 60, 1 }, { 60.5, 0 } }) do
		local env = newEnv({ random = 0.5 })
		incoming(env, "ND", { h = 11, n = 1 })
		env.runTo(0.5)
		incoming(env, "ND", { h = 12, n = 1 })
		H.eq(env.sync.stats.capped, 0, "the second ND counts")
		if case[1] > 1 then
			env.runTo(case[1])
			incoming(env, "ND", { h = 13, n = 1 })
			H.eq(env.sync.stats.capped, case[2], "third ND at " .. case[1])
		end
	end
end)

H.test("sync bounds: a counter rises once per 60 s, a 7th rise is refused, within the minute its value holds", function()
	local function nus(times)
		local env = newEnv({ random = 0.5 })
		hold(env, 1001, { 1 })
		for _, t in ipairs(times) do
			env.runTo(t)
			incoming(env, "NR", { h = 1, to = "Me-Realm", i = { 1001 } })
		end
		env.run(100)
		return #sentOf(env, "NU")
	end
	H.eq(nus({ 0, 60, 120, 180, 240, 300, 310, 360 }), 7, "6 rises 60 s apart, one more within the minute, the 7th rise refused")
	H.eq(nus({ 0, 59.5, 119, 178.5, 238, 297.5, 357 }), 7, "59.5 s apart: 4 rises")
	H.eq(nus({ 0, 60, 120, 180, 240, 300, 3600 }), 6, "an hour after the first rise the counters still hold")
end)

H.test("sync bounds: NRs to a sender count for the cap for exactly an hour", function()
	-- random 0: the NR goes 1 s after the NI
	for _, case in ipairs({ { 3599, 1 }, { 3598.5, 0 } }) do
		local env = newEnv({ random = 0 })
		for i = 1, 10 do incoming(env, "NR", { h = 1, to = "Bob-Realm", i = { i } }, "Cid-Realm") end
		env.runTo(case[1])
		ni(env, { 5000 }, nil)
		env.run(100)
		H.eq(#sentOf(env, "NR"), case[2], "NR due at " .. (case[1] + 1))
	end
end)

H.test("sync bounds: a muted pair stays muted for exactly an hour", function()
	for _, case in ipairs({ { 3600, 0 }, { 3600.5, 1 } }) do
		local env = newEnv({ random = 0 })
		hold(env, 1001, { 1 })
		for _, t in ipairs({ 0, 100, 200 }) do
			env.runTo(t)
			incoming(env, "ND", { h = 777, n = 3 })
		end
		env.runTo(300)
		H.eq(#sentOf(env, "NI"), 2, "muted")
		env.runTo(case[1])
		incoming(env, "ND", { h = 777, n = 3 })
		env.run(100)
		H.eq(#sentOf(env, "NI", 300), case[2], "ND at " .. case[1])
	end
end)

H.test("sync bounds: a sheet bigger than an NU's fill goes alone", function()
	local env = newEnv({ random = 0.5 })
	local big, x = { name = "Big", nd = DAY, t = {}, v = {} }, 1
	for _ = 1, 200 do
		x = (x * 48271) % 2147483647
		big.t[x % 100000 + 1] = { DAY, x % 300 + 1, DAY, x % 99999 + 1, DAY }
	end
	env.tab:MergeIn(1001, big)
	H.ok(#encode({ x = { packed(1001, env.tab:Sendable(1001)) } }) > 1000, "the big sheet alone is over 1000 bytes")
	hold(env, 1002, { 1 })
	ni(env, {}, nil)
	env.run(100)
	local nu = sentOf(env, "NU")
	local got = {}
	for _, m in ipairs(nu) do got[#got + 1] = idsOf(m) end
	table.sort(got)
	H.eq(table.concat(got, " "), "1001 1002", "two NUs, each with one sheet")
end)

H.test("sync bounds: fields at their bounds pass, one beyond is bad", function()
	local M = 2147483647
	local function long(n) return ("x"):rep(n - 6) .. "-Realm" end
	local many = {}
	for i = 1, 601 do many[i] = 1 end
	local function list(n)
		local l = {}
		for i = 1, n do l[i] = many[i] end
		return l
	end
	local cases = {
		{ "ND", { h = 0, n = 0 }, true }, { "ND", { h = M - 1, n = 600 }, true }, { "ND", { h = M, n = 0 }, false },
		{ "ND", { h = -1, n = 0 }, false }, { "ND", { h = 1, n = -1 }, false },
		{ "NI", { r = 0, i = { 5 }, c = { 0 } }, true }, { "NI", { r = 65535, i = { 5 }, c = { 65535 } }, true },
		{ "NI", { r = -1, i = {}, c = {} }, false }, { "NI", { r = 65536, i = {}, c = {} }, false },
		{ "NI", { r = 1, i = { 5 }, c = { -1 } }, false }, { "NI", { r = 1, i = { 5 }, c = { 65536 } }, false },
		{ "NI", { r = 1, i = { M }, c = { 1 } }, true }, { "NI", { r = 1, i = { M - 1, 1 }, c = { 1, 1 } }, true },
		{ "NI", { r = 1, i = { 5, 0 }, c = { 1, 1 } }, false },
		{ "NI", { r = 1, i = list(600), c = list(600) }, true }, { "NI", { r = 1, i = list(601), c = list(601) }, false },
		{ "NR", { to = long(100), i = { 5 } }, true }, { "NR", { to = long(101), i = { 5 } }, false },
	}
	for k, case in ipairs(cases) do
		local env = newEnv({ random = 0.5 })
		incoming(env, case[1], case[2], "S" .. k .. "-Realm")
		H.eq(env.sync.stats.bad == 0, case[3], "case " .. k .. " " .. case[1])
		H.eq(env.sync.stats.recv[case[1]] == 1, case[3], "case " .. k .. " received")
	end
	for _, case in ipairs({ { 100, 1 }, { 101, nil } }) do
		local env = newEnv({ random = 0.5 })
		incoming(env, "ND", { h = 1, n = 0 }, long(case[1]))
		H.eq(env.sync.stats.recv.ND, case[2], "sender name of " .. case[1] .. " bytes")
	end
end)
