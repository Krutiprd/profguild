-- A simulated guild for NpcSync: virtual time, the server's throttle per prefix (10 parts, then 1
-- per second), ChatThrottleLib's byte budget (800 bytes/s, burst 4000, 40 bytes overhead per part),
-- loss per part, random latency, blocks, login/logout, a clock offset per client. Every client is
-- the real NpcSync on the real NpcData table; sizes are those of the real encoding
-- (LibSerialize, LibDeflate, EncodeForWoWAddonChannel), cached per content.
-- Ported from npcsim/r15 (net2.lua, base.lua, run.lua).
--
--   local npcsim = dofile(H.root .. "/tests/npcsim.lua")(H)
--   sim = npcsim.new{ seed=, loss=, clock0= }
--   c = sim:client{ name=, sheets={ [id]=sheet } | packed=, block=fn(t), faction=, offset=, limits=, ns= }
--   sim:login(c) / sim:logout(c) / sim:run(seconds) / sim:equal(list) / sim:bytes(type|nil)
--   sim.cut = { [a] = b }: a's messages do not reach b
return function(H)
	H.loadLibs()
	local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")
	local floor, ceil, random, min, max = math.floor, math.ceil, math.random, math.min, math.max

	local function loadNs(epoch)
		local ns = H.newNamespace({ "NpcData.lua", "NpcTable.lua" })
		if epoch then ns.NpcData.EPOCH, ns.NpcData.PROTOCOL = epoch, epoch end
		H.loadAddonFile(ns, "NpcSync.lua")
		-- NPCSIM_SET="NI_EVERY=0,SEND_CAP=1e9": NpcSync constants changed, to measure a rule's worth
		for k, v in (os.getenv("NPCSIM_SET") or ""):gmatch("([%w_]+)=([%d.e+-]+)") do
			assert(type(ns.NpcSync[k]) == "number", "no number constant " .. k)
			ns.NpcSync[k] = tonumber(v)
		end
		return ns
	end

	local npcsim = { CLOCK0 = 1794615000 }
	npcsim.DAY0 = floor(npcsim.CLOCK0 / 86400)
	npcsim.ns = loadNs()
	npcsim.loadNs = loadNs

	-- Sizes ------------------------------------------------------------------
	local sizeCache, lastMsg, lastSize = {}, nil, nil
	local STABLE = { stable = true }
	local NORMAL_GUID, NORMAL_HASH = "Player-0000-0A1B2C3D", 1234567890
	function npcsim.size(msg)
		if msg == lastMsg then return lastSize end
		local s, h = msg.s, msg.h
		msg.s, msg.h = NORMAL_GUID, NORMAL_HASH
		-- stable key order: the string keys' order of pairs differs between processes (LuaJIT seeds
		-- its string hash), which made runs of one seed differ; sizes stay within a few bytes
		local key = LS:SerializeEx(STABLE, msg)
		msg.s, msg.h = s, h
		local n = sizeCache[key]
		if not n then
			n = #LD:EncodeForWoWAddonChannel(LD:CompressDeflate(key))
			sizeCache[key] = n
		end
		lastMsg, lastSize = msg, n
		return n
	end

	-- World (base.lua): 12 professions of 150 recipes; 100 trainers with 20-70, 80 vendors with 10 ---
	local PROF = {}
	do
		local saved = math.random
		math.randomseed(7)
		local rid = 2000
		for p = 1, 12 do
			local l, sk = {}, 1
			for i = 1, 150 do
				rid = rid + random(1, 12)
				sk = min(300, sk + random(0, 4))
				l[i] = { rid + (i > 75 and 15000 or 0), sk,
					({ 50, 100, 200, 250, 400, 500, 750, 900, 1000, 1800, 2500, 5000, 9000, 14000, 22500, 40000 })[min(16, 1 + floor(sk / 20))] * random(1, 3) }
			end
			PROF[p] = l
		end
	end
	npcsim.PROF = PROF
	local NAMES = { "Hahrana Ironhide", "Brom Killian", "Jormund", "Saru Steelfury", "Grumnal", "Thund",
		"Kelgruk Bloodaxe", "Traugh", "Ironus Coldsteel", "Mukdrak" }

	function npcsim.sheetGen(npc, vendor, d)
		local s = { name = NAMES[npc % 10 + 1] .. " " .. npc, nd = d, map = 1400 + npc % 30, x = npc % 100,
			y = npc * 7 % 100, pd = d, t = {}, v = {} }
		local p = PROF[npc % 12 + 1]
		local n = vendor and 10 or random(20, 70)
		while n > 0 do
			local r = p[random(150)]
			if not s.t[r[1]] and not s.v[r[1]] then
				if vendor then s.v[r[1]] = { d, { c = r[3], o = {}, l = 0 }, d }
				else s.t[r[1]] = { d, r[2], d, r[3], d } end
				n = n - 1
			end
		end
		return s
	end

	-- world(d) -> sheets { [id] = sheet }, ids (sorted), vendor { [id] = true }
	function npcsim.world(d, count, first)
		local t, ids, vendor, id = {}, {}, {}, first or 1000
		count = count or 180
		for i = 1, count do
			id = id + random(5, 90)
			local v = i > count * 100 / 180
			t[id], ids[#ids + 1] = npcsim.sheetGen(id, v, d), id
			if v then vendor[id] = true end
		end
		return t, ids, vendor
	end

	function npcsim.pack(sheets)
		local NpcData = npcsim.ns.NpcData
		local out = {}
		for id, s in pairs(sheets) do out[id] = NpcData.Pack(id, s) end
		return out
	end

	-- A reading of 1-6 recipes of a random NPC, half of them at a 10 % lower price.
	function npcsim.visitReading(ids, vendor, sheets)
		local id = ids[random(#ids)]
		local p = PROF[id % 12 + 1]
		local s = sheets and sheets[id]
		local r = { name = s and s.name or ("NPC " .. id), map = 1400 + id % 30, x = id % 100, y = id * 7 % 100, t = {}, v = {} }
		for _ = 1, random(1, 6) do
			local x = p[random(150)]
			local c = random() < 0.5 and x[3] or floor(x[3] * 0.9)
			if vendor[id] then r.v[x[1]] = { price = { c = c, o = {}, l = 0 } }
			else r.t[x[1]] = { skill = x[2], copper = c } end
		end
		return id, r
	end

	-- Simulation -------------------------------------------------------------
	local Sim = {}
	Sim.__index = Sim

	function npcsim.new(o)
		o = o or {}
		if o.seed then math.randomseed(o.seed) end
		local sim = setmetatable({ t = 0, q = {}, n = 0, seq = 0, clients = {}, byName = {},
			bytesBy = {}, countBy = {}, evil = 0, loss = o.loss or 0.02, load = o.load or 0,
			clock0 = o.clock0 or npcsim.CLOCK0, guid = 0, hook = nil }, Sim)
		return sim
	end

	function Sim:at(dt, fn)
		self.seq = self.seq + 1
		local q, n = self.q, self.n + 1
		self.n = n
		local e = { self.t + dt, self.seq, fn }
		local i = n
		while i > 1 do
			local p = floor(i / 2)
			local x = q[p]
			if x[1] < e[1] or (x[1] == e[1] and x[2] < e[2]) then break end
			q[i] = x
			i = p
		end
		q[i] = e
	end

	function Sim:run(seconds)
		local untilT = self.t + seconds
		local q = self.q
		while self.n > 0 and q[1][1] <= untilT do
			local top = q[1]
			local e = q[self.n]
			q[self.n] = nil
			self.n = self.n - 1
			local n = self.n
			if n > 0 then
				local i = 1
				while true do
					local c = 2 * i
					if c > n then break end
					if c < n and (q[c + 1][1] < q[c][1] or (q[c + 1][1] == q[c][1] and q[c + 1][2] < q[c][2])) then c = c + 1 end
					if q[c][1] < e[1] or (q[c][1] == e[1] and q[c][2] < e[2]) then q[i] = q[c] i = c else break end
				end
				q[i] = e
			end
			self.t = top[1]
			top[3]()
		end
		self.t = untilT
	end

	local function blocked(self, c) return c.block ~= nil and c.block(self.t) end

	local function deliver(self, c, msg, size, parts)
		local p = (1 - self.loss) ^ parts
		self:at(0.1 + 0.4 * random(), function()
			for _, o in ipairs(self.clients) do
				if o ~= c and o.online and o.sync and not (self.cut and self.cut[c] == o)
					and (self.loss == 0 or random() < p) then
					o.sync:OnMessage(msg, c.name, size)
				end
			end
		end)
	end

	local function pump(self, c)
		c.pumping = false
		local j = c.outq[1]
		if not j then return end
		if not c.online then c.outq = {} return end
		if blocked(self, c) then
			table.remove(c.outq, 1)
			if j.cb then j.cb(false) end
			return pump(self, c)
		end
		local r = max(60, 800 - self.load)
		local t = self.t
		c.tok = min(10, c.tok + (t - c.tt))
		c.tt = t
		c.av = min(4000, c.av + (t - c.at) * r)
		c.at = t
		local psz = j.bytes / j.parts + 40
		while j.left > 0 and c.tok >= 1 and c.av >= psz do
			c.tok, c.av, j.left = c.tok - 1, c.av - psz, j.left - 1
			if c.evil then self.evil = self.evil + j.bytes / j.parts
			else self.bytesBy[j.t] = (self.bytesBy[j.t] or 0) + j.bytes / j.parts end
		end
		if j.left == 0 then
			table.remove(c.outq, 1)
			if not c.evil then self.countBy[j.t] = (self.countBy[j.t] or 0) + 1 end
			if self.hook then self.hook(c, j.msg) end
			deliver(self, c, j.msg, j.bytes, j.parts)
			if j.cb then j.cb(true) end
			if not c.pumping then return pump(self, c) end
			return
		end
		c.pumping = true
		local sess = c.sess
		self:at(max(0.08, 1 - c.tok, (psz - c.av) / r), function() if c.sess == sess then pump(self, c) end end)
	end

	-- Puts msg into c's queue; size given or measured.
	function Sim:send(c, msg, cb, size)
		size = size or npcsim.size(msg)
		local parts = ceil(size / 254)
		c.outq[#c.outq + 1] = { msg = msg, t = msg.t, left = parts, parts = parts, bytes = size, cb = cb }
		if not c.pumping then pump(self, c) end
	end

	function Sim:client(o)
		local ns = o.ns or npcsim.ns
		self.guid = self.guid + 1
		local c = { name = o.name or ("C" .. self.guid .. "-Realm"), guid = ("Player-1-%08X"):format(self.guid),
			block = o.block, faction = o.faction or "Alliance", offset = o.offset or 0, ns = ns, outq = {},
			tok = 10, tt = 0, av = 4000, at = 0, online = false, sess = 0, evil = o.evil, group = o.group or 1 }
		if not o.evil then
			local saved = { e = ns.NpcData.EPOCH, s = o.packed or (o.sheets and npcsim.pack(o.sheets)) or {} }
			c.tab = ns.NpcData.New(saved, function() return self.clock0 + floor(self.t + c.offset) end, o.limits)
		end
		self.clients[#self.clients + 1] = c
		self.byName[c.name] = c
		return c
	end

	function Sim:adapter(c)
		local sim = self
		return {
			now = function() return sim.t end,
			after = function(s, fn) sim:at(s, fn) end,
			random = random,
			canSend = function() return c.online and not blocked(sim, c) end,
			send = function(msg, done) sim:send(c, msg, done) end,
			selfGuid = function() return c.guid end,
			faction = function() return c.faction end,
			changed = function() end,
			isMe = function(name) return name == c.name end,
			size = npcsim.size,
		}
	end

	-- Login: a new session; hellos 15-25 s after it and every 900 s.
	function Sim:login(c)
		if c.online then return end
		c.online, c.sess = true, c.sess + 1
		c.loginAt = self.t
		if c.evil then return end
		c.sync = c.ns.NpcSync.New(self:adapter(c), c.tab)
		local sync = c.sync
		local function tick()
			if c.sync ~= sync or not c.online then return end
			sync:Announce()
			self:at(900, tick)
		end
		self:at(15 + random() * 10, function()
			if c.sync ~= sync or not c.online then return end
			sync:Announce()
		end)
		self:at(900, tick)
	end

	function Sim:logout(c)
		if not c.online then return end
		c.online, c.sess, c.outq, c.pumping = false, c.sess + 1, {}, false
		if c.sync then c.sync:Stop() end
		c.sync = nil
	end

	-- Whether the online clients of the list (default: all of group 1) hold one table hash.
	function Sim:equal(list)
		local h
		for _, c in ipairs(list or self.clients) do
			if c.online and not c.evil and (list or c.group == 1) then
				local x = c.tab:Hash()
				if h == nil then h = x elseif x ~= h then return false end
			end
		end
		return true
	end

	function Sim:distinct(list)
		local s, k = {}, 0
		for _, c in ipairs(list or self.clients) do
			if c.online and not c.evil then
				local x = c.tab:Hash()
				if not s[x] then s[x], k = true, k + 1 end
			end
		end
		return k
	end

	-- Runs in steps of 5 s until equal or maxT; the seconds it took or nil.
	function Sim:waitEqual(maxT, list)
		local t0 = self.t
		while self.t - t0 < maxT do
			self:run(5)
			if self:equal(list) then return self.t - t0 end
		end
		return nil
	end

	function Sim:bytes(t)
		if t then return self.bytesBy[t] or 0 end
		local x = 0
		for _, v in pairs(self.bytesBy) do x = x + v end
		return x
	end

	function Sim:count(t) return self.countBy[t] or 0 end

	function Sim:reset() self.bytesBy, self.countBy, self.evil = {}, {}, 0 end

	function Sim:str()
		local t = {}
		for _, k in ipairs({ "ND", "NI", "NR", "NU" }) do
			t[#t + 1] = ("%s %d/%dk"):format(k, self:count(k), floor(self:bytes(k) / 1000 + 0.5))
		end
		return table.concat(t, " ")
	end

	-- Bytes of NUs carrying these sheets, as one sender would chunk them.
	function npcsim.nuBytes(sheets)
		local NpcData = npcsim.ns.NpcData
		local ids = {}
		for id in pairs(sheets) do ids[#ids + 1] = id end
		table.sort(ids)
		local function msg(list) return { t = "NU", pv = 1, e = 1, f = "Alliance", s = NORMAL_GUID, h = NORMAL_HASH, x = list } end
		local total, cur, cb = 0, {}, 0
		for _, id in ipairs(ids) do
			local p = NpcData.Pack(id, sheets[id])
			local b = npcsim.size(msg({ p }))
			if cb > 0 and cb + b > 1000 then
				total = total + npcsim.size(msg(cur))
				cur, cb = {}, 0
			end
			cur[#cur + 1] = p
			cb = cb + b
		end
		if #cur > 0 then total = total + npcsim.size(msg(cur)) end
		return total
	end

	return npcsim
end
