-- The sharing scenarios of the design's Verification, each against its target, on the simulated
-- guild (tests/npcsim.lua). Ported from npcsim/r15/run.lua.
--   luajit tests/run_npc_sim.lua [--seeds N] [--jobs N] [--only pattern] [--skip pattern] [--extra] [--short]
-- (from the repository root; --jobs runs that many scenario processes at once). NPCSIM_SET="NAME=v,..."
-- overrides NpcSync constants (tests/npcsim.lua), to measure what a rule is worth.
-- prints one line "ok|FAIL name value target" per scenario and seed; exit code 1 on a failure.
-- Loaded by tests/run.lua (with the harness as argument) it registers the short set as tests.
local H = ...
local asTests = type(H) == "table"
if not asTests then H = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/harness.lua") end
local npcsim = dofile(H.root .. "/tests/npcsim.lua")(H)
local floor, random = math.floor, math.random
local DAY0 = npcsim.DAY0

local function copy(t)
	local r = {}
	for k, v in pairs(t) do r[k] = v end
	return r
end

local function kb(b) return floor(b / 1000 + 0.5) .. "k" end

-- The world of 180 NPCs, 20 days old (the same in every run).
local function theWorld(d)
	local saved = random(1, 2 ^ 30)
	math.randomseed(1234)
	local W, ids, vendor = npcsim.world(d or DAY0 - 20)
	math.randomseed(saved)
	return W, ids, vendor, npcsim.pack(W)
end

local function loginAll(sim, list, spread)
	for _, c in ipairs(list or sim.clients) do
		if not c.evil then sim:at(random() * (spread or 60), function() sim:login(c) end) end
	end
end

local function honest(sim)
	local l = {}
	for _, c in ipairs(sim.clients) do if not c.evil and c.group == 1 then l[#l + 1] = c end end
	return l
end

-- An own visit that changes c's table (some readings change nothing).
local function visit(sim, c, ids, vendor, W)
	for _ = 1, 50 do
		local id, r = npcsim.visitReading(ids, vendor, W)
		local changed
		if c.sync then changed = c.sync:OwnVisit(id, r) else changed = c.tab:OwnVisit(id, r) end
		if changed then return id end
	end
end

-- 3 h without NI, NR, NU after 900 s of settling; hellos keep running.
local function quiet(sim)
	sim:run(900)
	local eq = sim:equal()
	sim:reset()
	sim:run(10800)
	local data = sim:count("NI") + sim:count("NR") + sim:count("NU")
	return eq and data == 0, (eq and "eq" or "NE") .. " " .. sim:str()
end

local S = {}

-- 20, 72, 200 clients log in within a minute: each missing another random sheet (rand), each
-- holding one sheet nobody else has (uniq), two halves with 10 new sheets each (half).
function S.burst(seed, kind, n, loss)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = loss })
	local miss = {}
	for i = 1, n do
		local t = copy(P)
		if kind == "rand" then
			local id = ids[random(#ids)]
			t[id], miss[id] = nil, W[id]
		elseif kind == "half" then
			for j = 1, 20 do
				local side = j <= 10 and 0 or 1
				if i % 2 ~= side then t[ids[j * 8]] = nil end
				miss[ids[j * 8]] = W[ids[j * 8]]
			end
		end
		sim:client({ packed = t })
	end
	if kind == "uniq" then
		for i, c in ipairs(sim.clients) do
			local id = 50000 + i * 13
			local s = npcsim.sheetGen(id, i % 2 == 0, DAY0 - 20)
			c.tab:MergeIn(id, s)
			miss[id] = s
		end
	end
	loginAll(sim)
	sim:run(60)
	local limit = 3 * npcsim.nuBytes(miss) + 2000 * n
	local te = sim:waitEqual(840)
	if te then sim:run(900) end
	local b = sim:bytes()
	local traffic = sim:str()
	local q1, s1 = quiet(sim)
	visit(sim, sim.clients[1], ids, vendor, W)
	local q2, s2 = quiet(sim)
	local ok = te ~= nil and b <= limit and q1 and q2
	return ok, ("eq@%s %s/%s [%s] quiet %s, after a visit %s"):format(te and floor(te + 60) or "never",
		kb(b), kb(limit), traffic, s1, s2), "eq<=900 bytes<=3*missing+2k*n, 3h quiet x2"
end

-- A newcomer with nothing into a settled guild of n.
function S.newcomer(seed, n, loss, maxBytes)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = loss })
	for _ = 1, n do sim:client({ packed = P }) end
	loginAll(sim)
	sim:run(1800)
	sim:reset()
	local c = sim:client({ name = "New-Realm" })
	sim:login(c)
	local t0, tt, nb = sim.t, nil, nil
	local ref = sim.clients[1]
	while sim.t - t0 < 2400 do
		sim:run(5)
		if not tt and c.tab:Hash() == ref.tab:Hash() then tt, nb = sim.t - t0, sim:bytes() end
	end
	local ok = tt ~= nil and tt <= 600 and (not maxBytes or nb <= maxBytes)
	return ok, ("complete@%s %s [%s]"):format(tt and floor(tt) or "never", kb(nb or sim:bytes()), sim:str()),
		"<=600s" .. (maxBytes and (" <=" .. kb(maxBytes)) or ""), nb or sim:bytes()
end

-- One changing visit per minute, 40 % of the clients blocked now and then, 2 % loss.
function S.cont(seed, n)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = 0.02 })
	for i = 1, n do
		local c = sim:client({ packed = P })
		if i <= 0.4 * n then
			local ph, a = random() * 1200, 300 + random() * 600
			c.block = function(t) return (t + ph) % 1200 < a end
		end
	end
	loginAll(sim, nil, 900)
	local stop = 3600 * 4
	local function v()
		if sim.t < stop then
			visit(sim, sim.clients[random(n)], ids, vendor, W)
			sim:at(60, v)
		end
	end
	sim:at(60, v)
	sim:run(7200)
	sim:reset()
	sim:run(stop - 7200)
	local perHour = sim:bytes() / 2
	local traffic = sim:str()
	sim:reset()
	local t = sim:waitEqual(7200)
	local ok = perHour <= 300000 and t ~= nil and t <= 1800
	return ok, ("%s/h [%s] eq %s after the visits stop"):format(kb(perHour), traffic, t and (floor(t) .. "s") or "never"),
		"<=300k/h, eq<=1800s"
end

-- All clients blocked a share of the time in periods of bp seconds; one holder of 30 sheets and a
-- newcomer.
function S.late(seed, n, bp, share)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n + bp, loss = 0.02 })
	for _ = 1, n do sim:client({ packed = P }) end
	local sole = sim.clients[1]
	for j = 1, 30 do
		local id = 90000 + j * 7
		sole.tab:MergeIn(id, npcsim.sheetGen(id, false, DAY0 - 20))
	end
	sim:client({ name = "New-Realm" })
	loginAll(sim)
	share = share or 0.3
	for i = 1, n do
		local ph = random() * bp
		sim.clients[i].block = function(t) return (t + ph) % bp < share * bp end
	end
	sim:run(120)
	local t = sim:waitEqual(7200)
	local ok = t ~= nil and t + 120 <= 900
	return ok, ("eq@%s [%s]"):format(t and floor(t + 120) or "never", sim:str()), "eq<=900"
end

-- The client that answers a newcomer logs out mid-answer (gone), or is blocked before its first
-- NU and logs out 20 s later (blocked).
function S.gone(seed, n, how)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = 0.02 })
	for _ = 1, n do sim:client({ packed = P }) end
	loginAll(sim)
	sim:run(600 + random() * 900)
	local c = sim:client({ name = "New-Realm" })
	sim:login(c)
	local t0 = sim.t
	sim:reset()
	local last, hit
	local send = sim.send
	sim.send = function(self, x, msg, cb, size)
		if msg.t == "NU" and x ~= c then
			if how == "blocked" and not hit then
				hit = x
				x.block = function() return true end
				sim:at(20, function() sim:logout(x) end)
			end
			last = x
		end
		return send(self, x, msg, cb, size)
	end
	if how == "gone" then
		sim:at(70, function() if last then sim:logout(last) end end)
	end
	local tt
	while sim.t - t0 < 3600 and not tt do
		sim:run(5)
		local ref
		for _, o in ipairs(sim.clients) do if o.online and o ~= c then ref = o break end end
		if c.tab:Hash() == ref.tab:Hash() then tt = sim.t - t0 end
	end
	local ok = tt ~= nil and tt <= 600
	return ok, ("complete@%s [%s]"):format(tt and floor(tt) or "never", sim:str()), "<=600s (95 %), all <=2400s"
end

-- k newcomers, one every gap seconds.
function S.news(seed, n, k, gap)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n + k, loss = 0.02 })
	for _ = 1, n do sim:client({ packed = P }) end
	loginAll(sim)
	sim:run(1800)
	sim:reset()
	local st = {}
	for i = 1, k do
		local c = sim:client({ name = "New" .. i .. "-Realm" })
		st[i] = c
		sim:at((i - 1) * gap, function() sim:login(c) end)
	end
	local ref = sim.clients[1]
	local T, res = sim.t, {}
	while sim.t - T < k * gap + 7200 do
		sim:run(5)
		local all = true
		for i, c in ipairs(st) do
			if not res[i] and c.online and c.tab:Hash() == ref.tab:Hash() then res[i] = floor(sim.t - c.loginAt) end
			if not res[i] then all = false end
		end
		if all then break end
	end
	local within, worst = 0, 0
	for i = 1, k do
		if res[i] and res[i] <= 600 then within = within + 1 end
		worst = math.max(worst, res[i] or 1e9)
	end
	local ok = within >= 0.95 * k and worst <= 2400
	return ok, ("%d/%d in 600s, worst %s [%s]"):format(within, k, worst < 1e9 and worst or "never", sim:str()),
		"95% <=600s, all <=2400s"
end

-- Three groups in one channel: Alliance, Horde, and another epoch and protocol; each must agree
-- inside, newcomers of each complete, then 3 h without data.
function S.mix(seed, n)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = 0.02 })
	local other = npcsim.loadNs(2)
	local groups = {}
	local function make(k, g, faction, ns)
		local l = {}
		for i = 1, k do
			local t = copy(P)
			for _ = 1, 3 do t[ids[random(#ids)]] = nil end
			if g > 1 then for j = 1, #ids do if j % g == 0 then t[ids[j]] = nil end end end
			l[i] = sim:client({ packed = t, faction = faction, ns = ns, group = g })
		end
		groups[g] = l
	end
	make(n, 1, "Alliance") make(floor(n / 2), 2, "Horde") make(floor(n / 4), 3, "Alliance", other)
	loginAll(sim)
	sim:run(60)
	local function wait(maxT)
		local r, t0 = {}, sim.t
		while sim.t - t0 < maxT do
			sim:run(5)
			for g = 1, 3 do if not r[g] and sim:equal(groups[g]) then r[g] = floor(sim.t - t0) end end
			if r[1] and r[2] and r[3] then break end
		end
		return r
	end
	local a = wait(3600)
	sim:run(900)
	for g = 1, 3 do
		local c = sim:client({ name = "New" .. g .. "-Realm", faction = groups[g][1].faction, ns = groups[g][1].ns, group = g })
		groups[g][#groups[g] + 1] = c
		sim:login(c)
	end
	local b = wait(3600)
	sim:run(900)
	sim:reset()
	sim:run(10800)
	local data = sim:count("NI") + sim:count("NR") + sim:count("NU")
	local ok = data == 0
	for g = 1, 3 do ok = ok and a[g] and a[g] + 60 <= 900 and b[g] and b[g] <= 600 end
	local function s(r) return ("%s,%s,%s"):format(tostring(r[1] and r[1] + 60), tostring(r[2] and r[2] + 60), tostring(r[3] and r[3] + 60)) end
	return ok, ("burst eq@%s newcomers@%s,%s,%s quiet3h [%s]"):format(s(a), tostring(b[1]), tostring(b[2]), tostring(b[3]), sim:str()),
		"each group eq<=900, newcomers<=600s, 3h quiet"
end

-- One client refusing rf sheets (its sheet limit): 3 h without visits. The target covers at most
-- 100 refused sheets (the memory of rule 4) with limits equal for all clients; more is --extra.
function S.refuse(seed, n, rf)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n + rf, loss = 0.02 })
	sim:client({ packed = P, limits = { sheets = 180 - rf } })
	for _ = 2, n do sim:client({ packed = P }) end
	loginAll(sim)
	sim:run(1800)
	sim:reset()
	sim:run(10800)
	local b = sim:bytes()
	return b <= 30000, ("%s per 3h [%s]"):format(kb(b), sim:str()), "<=30k/3h (at most 100 refused)"
end

-- Limits: every client caps sheets at 200 with 60 extra sheets spread (sheet), every client caps
-- 40 trained entries per sheet with newer entries spread (entry), one client caps entries (odd).
function S.limit(seed, n, mode)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = 0.02 })
	local ex = {}
	for i = 1, 60 do
		local id = 70000 + i * 13
		ex[i] = { id, npcsim.sheetGen(id, i % 2 == 0, DAY0 - 20) }
	end
	local NpcData = npcsim.ns.NpcData
	for i = 1, n do
		local t = copy(P)
		local limits
		if mode == "sheet" then
			for j = 1, 60 do if j <= 20 or j % 2 == i % 2 then t[ex[j][1]] = NpcData.Pack(ex[j][1], ex[j][2]) end end
			limits = { sheets = 200 }
		elseif mode == "entry" then
			for j = 1, 30 do
				local id = ids[j * 3]
				local s = W[id]
				local e = copy(s.t)
				for _ = 1, 12 do
					local v = npcsim.PROF[id % 12 + 1][random(150)]
					local d = DAY0 - 25 + random(0, 10)
					e[v[1]] = { d, v[2], d, v[3], d }
				end
				t[id] = NpcData.Pack(id, { name = s.name, nd = s.nd, map = s.map, x = s.x, y = s.y, pd = s.pd, t = e, v = s.v })
			end
			limits = { t = 40, v = 40 }
		elseif mode == "odd" and i == 1 then
			limits = { t = 40, v = 40 }
		end
		sim:client({ packed = t, limits = limits })
	end
	loginAll(sim)
	sim:run(120)
	local t = sim:waitEqual(3600)
	sim:run(900)
	sim:reset()
	sim:run(10800)
	local b = sim:bytes()
	return b <= 30000, ("eq %s, then %s per 3h [%s] distinct %d"):format(t and floor(t + 120) or "never", kb(b), sim:str(), sim:distinct()),
		"<=30k/3h"
end

-- Registers 114-119 days old crossing midnight (at 8 h) with clocks skew seconds apart and odd
-- clients 6 h off: the traffic stops or stays under 250 kB an hour.
function S.day(seed, n, skew, odd)
	local W, ids, vendor = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n + odd, loss = 0.02, clock0 = (DAY0 + 1) * 86400 - 28800 })
	local NpcData = npcsim.ns.NpcData
	local W2 = {}
	for id, s in pairs(W) do
		local function f(k, j) return (id % 3 == 0) and (DAY0 - 119 + (k * j + id) % 6) or DAY0 - 20 end
		local x = { name = s.name, nd = DAY0 - 60, map = s.map, x = s.x, y = s.y, pd = DAY0 - 60, t = {}, v = {} }
		for k, e in pairs(s.t) do x.t[k] = { f(k, 7), e[2], f(k, 11), e[4], f(k, 13) } end
		for k, e in pairs(s.v) do x.v[k] = { f(k, 7), e[2], f(k, 13) } end
		W2[id] = NpcData.Pack(id, x)
	end
	for i = 1, n do
		local off = i <= odd and ((i % 2 == 1) and 21600 or -21600) or (random() * 2 - 1) * skew
		sim:client({ packed = W2, offset = off })
	end
	loginAll(sim)
	sim:run(5000)
	sim:reset()
	local worst, last = 0, 0
	while sim.t < 28800 + 86400 * 2.2 do
		sim:run(3600)
		local x = sim:bytes()
		worst = math.max(worst, x - last)
		last = x
	end
	return worst <= 250000, ("max %s/h, %s in 2.2 days [%s] distinct %d"):format(kb(worst), kb(last), sim:str(), sim:distinct()),
		"<=250k/h"
end

-- Forged floods (an evil client) into a settled guild; then a newcomer.
local function forger(sim, n, kind, ids, ref, nc)
	local E = sim:client({ evil = true, name = "Evil-Realm" })
	sim:login(E)
	local seq = 0
	local function every(dt, fn)
		local function g() fn() sim:at(dt, g) end
		sim:at(1 + random() * 5, g)
	end
	local function m(t, fields)
		seq = seq + 1
		local x = { t = t, pv = 1, e = 1, f = "Alliance", s = ("Player-1-%08X"):format(0x7000000 + seq), h = random(1, 1e9) }
		for k, v in pairs(fields) do x[k] = v end
		return x
	end
	local function send(x) sim:send(E, x) end
	local function deltas(list)
		local out, prev = {}, 0
		for i, id in ipairs(list) do out[i], prev = id - prev, id end
		return out
	end
	local all = deltas(ids)
	local function other() return sim.clients[1 + random(n - 1)].name end
	local function sub()
		local l, c = {}, {}
		for _, id in ipairs(ids) do
			if random() < 0.5 then l[#l + 1] = id c[#c + 1] = ref.tab:SaltedHash(ref.tab:SheetHash(id), 1) end
		end
		return deltas(l), c
	end
	local gap = 61
	for k in kind:gmatch("[%w]+") do
		if k == "NUeq" then every(3, function() send(m("NU", { h = ref.tab:Hash(), x = {} })) end)
		elseif k == "NUx" then every(3, function() send(m("NU", { x = {} })) end)
		elseif k == "NIempty" or k == "NI0" then every(gap, function() send(m("NI", { h = 0, r = 1, i = {}, c = {} })) end)
		elseif k == "NIeq" then every(gap, function() send(m("NI", { h = ref.tab:Hash(), r = 1, i = {}, c = {} })) end)
		elseif k == "NIall" or k == "NI" then every(gap, function() send(m("NI", { r = 1, i = {}, c = {} })) end)
		elseif k == "NIs" then every(gap, function() local i, c = sub() send(m("NI", { r = 1, i = i, c = c })) end)
		elseif k == "NIjunk" then
			every(gap, function()
				local i, c = {}, {}
				for j = 1, 600 do i[j], c[j] = j == 1 and 200001 or 1, j end
				send(m("NI", { r = 1, i = i, c = c }))
			end)
		elseif k == "ND" then every(1.2, function() send(m("ND", { n = 180 })) end)
		elseif k == "NDeq" then every(20, function() send(m("ND", { n = 180, h = ref.tab:Hash() })) end)
		elseif k == "NR" then every(3, function() send(m("NR", { h = 1, to = other(), i = all })) end)
		elseif k == "NRall" then every(3, function() send(m("NR", { h = 1, to = E.name, i = all })) end)
		elseif k == "NRnc" then every(20, function() send(m("NR", { to = nc, i = all })) end)
		elseif k == "NUjunk" then every(3, function() send(m("NU", { h = ref.tab:Hash(), x = {} })) end)
		end
	end
end

-- kind: one or more forged kinds joined by "+"; target "newcomer" (seconds) or "honest" (bytes/h).
function S.evil(seed, n, kind, target, limit)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n + #kind, loss = 0.02 })
	for _ = 1, n do sim:client({ packed = P }) end
	loginAll(sim)
	sim:run(1800)
	sim:reset()
	local ref = sim.clients[1]
	forger(sim, n, kind, ids, ref, "New-Realm")
	local pre = 600
	sim:run(pre)
	local c = sim:client({ name = "New-Realm" })
	sim:login(c)
	local t0, tt = sim.t, nil
	local span = target == "newcomer" and limit or 3600
	while sim.t - t0 < math.max(span, 3600) do
		sim:run(5)
		if not tt and c.tab:Hash() == ref.tab:Hash() then tt = sim.t - t0 end
	end
	local perHour = sim:bytes() / ((pre + sim.t - t0) / 3600)
	local evilHour = sim.evil / ((pre + sim.t - t0) / 3600)
	local ok
	if target == "newcomer" then ok = tt ~= nil and tt <= limit else ok = perHour <= limit end
	return ok, ("newcomer@%s honest %s/h evil %s/h [%s]"):format(tt and floor(tt) or "never", kb(perHour), kb(evilHour), sim:str()),
		target == "newcomer" and ("newcomer<=" .. limit .. "s") or ("honest<=" .. kb(limit) .. "/h")
end

-- Two clients cut off from each other read different recipes of one trainer; a newcomer reads a
-- trainer 5 s after login: in the end everybody holds every reading.
function S.cutoff(seed, n)
	local W, ids, vendor, P = theWorld()
	local sim = npcsim.new({ seed = seed * 7919 + n, loss = 0.02 })
	for _ = 1, n do sim:client({ packed = P }) end
	local A, B = sim.clients[1], sim.clients[2]
	sim.cut = { [A] = B, [B] = A }
	loginAll(sim)
	sim:run(120)
	local trainer
	for _, id in ipairs(ids) do if not vendor[id] then trainer = id break end end
	local p = npcsim.PROF[trainer % 12 + 1]
	local function reading(list)
		local r = { name = W[trainer].name, map = W[trainer].map, x = W[trainer].x, y = W[trainer].y, t = {} }
		for _, i in ipairs(list) do r.t[p[i][1]] = { skill = p[i][2], copper = p[i][3] + 1 } end
		return r
	end
	local ra, rb = reading({ 1, 2, 3 }), reading({ 4, 5, 6 })
	A.sync:OwnVisit(trainer, ra)
	B.sync:OwnVisit(trainer, rb)
	local c = sim:client({ name = "New-Realm" })
	sim:login(c)
	local trainer2
	for i = #ids, 1, -1 do if not vendor[ids[i]] then trainer2 = ids[i] break end end
	local p2 = npcsim.PROF[trainer2 % 12 + 1]
	local rc = { name = W[trainer2].name, map = W[trainer2].map, x = W[trainer2].x, y = W[trainer2].y,
		t = { [p2[150][1]] = { skill = p2[150][2], copper = 7 } } }
	sim:at(5, function() c.sync:OwnVisit(trainer2, rc) end)
	local t = sim:waitEqual(900)
	local lost = 0
	for _, o in ipairs(sim.clients) do
		local s, s2 = o.tab:Get(trainer), o.tab:Get(trainer2)
		for _, r in ipairs({ ra, rb }) do
			for id, x in pairs(r.t) do if not (s and s.t[id] and s.t[id][4] == x.copper) then lost = lost + 1 end end
		end
		if not (s2 and s2.t[p2[150][1]]) then lost = lost + 1 end
	end
	local ok = t ~= nil and lost == 0
	return ok, ("eq@%s lost %d [%s]"):format(t and floor(t) or "never", lost, sim:str()), "eq<=900, nothing lost"
end

-- Recipe traffic (Profguild) beside a stream of full NUs (ProfguildNPC, rule 7's pacing) through
-- the real ChatThrottleLib: at most 3 s later than without it.
function S.ctl(seed, size)
	local function measure(withNu)
		local env = setmetatable({}, { __index = _G })
		env._G = env
		local T, tok, last, evs = 100, {}, {}, {}
		env.table = setmetatable({ wipe = function(t) for k in pairs(t) do t[k] = nil end return t end }, { __index = table })
		env.GetTime = function() return T end
		env.GetFramerate = function() return 60 end
		env.hooksecurefunc = function() end
		env.geterrorhandler = function() return print end
		env.securecallfunction = function(f, ...) return f(...) end
		env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, GeneralError = 9 } }
		env.C_ChatInfo = { SendChatMessage = function() end, SendAddonMessageLogged = function() end,
			SendAddonMessage = function(p)
				local k = math.min(10, (tok[p] or 10) + (T - (last[p] or T)))
				last[p] = T
				if k < 1 then tok[p] = k return 3 end
				tok[p] = k - 1
				return 0
			end }
		env.CreateFrame = function()
			return { Hide = function(s) s.h = true end, Show = function(s) s.h = false end,
				SetScript = function(s, e, f) s[e] = f end, RegisterEvent = function() end }
		end
		local chunk = assert(loadfile(H.addon .. "/Libs/AceComm-3.0/ChatThrottleLib.lua"))
		setfenv(chunk, env)
		chunk()
		local C = env.ChatThrottleLib
		local function at(d, f) evs[#evs + 1] = { T + d, f } end
		local function run(to)
			while T < to do
				T = T + 0.02
				if not C.Frame.h then C.Frame.OnUpdate(C.Frame, 0.02) end
				local i = 1
				while i <= #evs do
					if evs[i][1] <= T then local e = table.remove(evs, i) e[2]() else i = i + 1 end
				end
			end
		end
		local PART = npcsim.ns.NpcSync.PART
		local function send(p, bytes, cb)
			local n = math.ceil(bytes / PART)
			for i = 1, n do
				C:SendAddonMessage("BULK", p, ("x"):rep(i < n and 255 or bytes - (n - 1) * PART + 1), "GUILD", nil, p, i == n and cb or nil)
			end
			return n
		end
		local function nu()
			local n
			n = send("ProfguildNPC", size, function() at(n or 4, nu) end)
		end
		run(120)
		if withNu then nu() end
		run(121 + seed % 7)
		local t0, res = T, {}
		send("Profguild", 150, function() res[1] = T - t0 end)
		send("Profguild", 700, function() res[2] = T - t0 end)
		send("Profguild", 11000, function() res[3] = T - t0 end)
		run(T + 200)
		return res
	end
	local a, b = measure(false), measure(true)
	local worst = 0
	for i = 1, 3 do worst = math.max(worst, (b[i] or 1e9) - (a[i] or 0)) end
	return worst <= 3, ("later by %.1f s (request %.1f/%.1f, small %.1f/%.1f, record %.1f/%.1f)"):format(worst,
		a[1] or -1, b[1] or -1, a[2] or -1, b[2] or -1, a[3] or -1, b[3] or -1), "<=3s"
end

-- The matrix -------------------------------------------------------------------

local MATRIX = {}
local function add(name, fn, ...) MATRIX[#MATRIX + 1] = { name = name, fn = fn, args = { ... } } end
for _, loss in ipairs({ 0.02, 0.05 }) do
	for _, kind in ipairs({ "rand", "uniq", "half" }) do
		for _, n in ipairs({ 20, 72, 200 }) do
			add(("burst-%s-%d-%d%%"):format(kind, n, loss * 100), S.burst, kind, n, loss)
		end
	end
end
-- full game: at most 60 kB in the median over the seeds, 80 kB in every run (ruling while building)
add("newcomer-72", S.newcomer, 72, 0.02, 80000)
MATRIX[#MATRIX].median = 60000
add("newcomer-200-5%", S.newcomer, 200, 0.05)
add("cont-72", S.cont, 72)
for _, bp in ipairs({ 12, 15, 20, 30, 45, 100, 300, 611, 900, 1200 }) do add("late-72-bp" .. bp, S.late, 72, bp) end
add("gone-72", S.gone, 72, "gone")
add("gone-blocked-72", S.gone, 72, "blocked")
add("news-72-30x5s", S.news, 72, 30, 5)
add("news-72-10x120s", S.news, 72, 10, 120)
add("news-72-3x60s", S.news, 72, 3, 60)
add("mix-72", S.mix, 72)
for _, rf in ipairs({ 5, 50, 100 }) do add("refuse-72-" .. rf, S.refuse, 72, rf) end
for _, mode in ipairs({ "sheet", "entry" }) do add("limit-72-" .. mode, S.limit, 72, mode) end
add("day-72-skew5-odd1", S.day, 72, 5, 1)
for _, k in ipairs({ "NIempty", "NIeq", "NIall", "NIjunk", "NIs", "ND", "NDeq", "NR", "NRall", "NRnc" }) do
	add("evil-72-" .. k, S.evil, 72, k, "honest", 400000)
end
add("evil-72-NUeq", S.evil, 72, "NUeq", "newcomer", 1800)
add("evil-72-NUx", S.evil, 72, "NUx", "newcomer", 1800)
add("evil-72-NI0-newcomer", S.evil, 72, "NI0", "newcomer", 3600)
for _, k in ipairs({ "NI+NR+ND", "NIs+NRnc", "NI+NUjunk", "NIs+NRnc+NUjunk+ND" }) do
	add("evil-72-" .. k, S.evil, 72, k, "honest", 520000)
end
add("cutoff-20", S.cutoff, 20)
add("ctl-nu1000", S.ctl, 1000)

-- Beyond the design's targets (--extra; lines start with "info", not counted): more refused sheets
-- than the 100 remembered, one client taking sheets in part (its own entry limit), 36 clocks 6 h
-- off. r15 gives the same orders of magnitude.
local EXTRA = {}
local function extra(name, fn, ...) EXTRA[#EXTRA + 1] = { name = name, fn = fn, args = { ... }, info = true } end
for _, rf in ipairs({ 110, 150 }) do extra("refuse-72-" .. rf, S.refuse, 72, rf) end
extra("limit-72-odd", S.limit, 72, "odd")
extra("day-72-skew5-odd36", S.day, 72, 5, 36)

-- The short set for tests/run.lua.
local SHORT = {
	{ "burst-uniq-20-2%", S.burst, "uniq", 20, 0.02 },
	{ "newcomer-72", S.newcomer, 72, 0.02, 80000 },
	{ "late-72-bp12", S.late, 72, 12 },
	{ "evil-72-NUeq", S.evil, 72, "NUeq", "newcomer", 1800 },
	{ "cutoff-20", S.cutoff, 20 },
}

local function runOne(e, seed)
	local ok, value, target, x = e.fn(seed, unpack(e.args))
	if e.info then ok = true end
	return ok, ("%s %s seed=%d %s | target %s%s"):format(e.info and "info" or (ok and "ok" or "FAIL"), e.name, seed, value, target,
		x and (" value=" .. floor(x)) or "")
end

if asTests then
	for _, s in ipairs(SHORT) do
		local e = { name = s[1], fn = s[2], args = { select(3, unpack(s)) } }
		H.test("npc sim: " .. e.name, function()
			local ok, line = runOne(e, 1)
			if not ok then error(line, 0) end
		end)
	end
	return
end

-- Command line.
local seeds, jobs, only, skip, one = 3, 1, nil, nil, nil
local i = 1
while arg[i] do
	if arg[i] == "--seeds" then seeds = tonumber(arg[i + 1]) i = i + 1
	elseif arg[i] == "--jobs" then jobs = tonumber(arg[i + 1]) i = i + 1
	elseif arg[i] == "--only" then only = arg[i + 1] i = i + 1
	elseif arg[i] == "--skip" then skip = arg[i + 1] i = i + 1
	elseif arg[i] == "--one" then one = { arg[i + 1], tonumber(arg[i + 2]) } i = i + 2
	elseif arg[i] == "--extra" then
		for _, e in ipairs(EXTRA) do MATRIX[#MATRIX + 1] = e end
	elseif arg[i] == "--short" then
		MATRIX = {}
		for _, s in ipairs(SHORT) do add(s[1], s[2], select(3, unpack(s))) end
	end
	i = i + 1
end

if one then
	for _, e in ipairs(EXTRA) do MATRIX[#MATRIX + 1] = e end
	for _, e in ipairs(MATRIX) do
		if e.name == one[1] then
			local ok, line = runOne(e, one[2])
			print(line)
			io.stdout:flush()
			os.exit(ok and 0 or 1)
		end
	end
	print("FAIL " .. one[1] .. " unknown scenario")
	os.exit(1)
end

local work = {}
for _, e in ipairs(MATRIX) do
	if (not only or e.name:find(only)) and not (skip and e.name:find(skip)) then
		for s = 1, seeds do work[#work + 1] = { e, s } end
	end
end
local failed, started = 0, os.time()
local values = {} -- scenario name -> values of its runs (for a target over the seeds)
local function note(line)
	local name, v = line:match("^%a+ (%S+) seed=%d+ .* value=(%d+)")
	if name then values[name] = values[name] or {} table.insert(values[name], tonumber(v)) end
end
if jobs <= 1 then
	for _, w in ipairs(work) do
		local ok, line = runOne(w[1], w[2])
		print(line)
		io.stdout:flush()
		note(line)
		if not ok then failed = failed + 1 end
	end
else
	local self = arg[0]
	local k = 1
	while k <= #work do
		local batch = {}
		for j = k, math.min(#work, k + jobs - 1) do
			local w = work[j]
			batch[#batch + 1] = io.popen(('luajit "%s" --one "%s" %d 2>&1'):format(self, w[1].name, w[2]))
		end
		for _, p in ipairs(batch) do
			local out = p:read("*a")
			p:close()
			io.write(out)
			io.stdout:flush()
			note(out)
			if not (out:find("^ok ") or out:find("^info ")) then failed = failed + 1 end
		end
		k = k + jobs
	end
end
-- targets over the seeds: the median of the runs' values
for _, e in ipairs(MATRIX) do
	local l = values[e.name]
	if e.median and l and #l > 0 then
		table.sort(l)
		local m = #l % 2 == 1 and l[(#l + 1) / 2] or (l[#l / 2] + l[#l / 2 + 1]) / 2
		local ok = m <= e.median
		print(("%s %s median over %d seeds %s (runs %s) | target median <=%s"):format(ok and "ok" or "FAIL", e.name, #l, kb(m),
			table.concat((function() local t = {} for i, v in ipairs(l) do t[i] = kb(v) end return t end)(), ","), kb(e.median)))
		if not ok then failed = failed + 1 end
	end
end
print(("%d runs, %d failed, %d s"):format(#work, failed, os.time() - started))
os.exit(failed == 0 and 0 or 1)
