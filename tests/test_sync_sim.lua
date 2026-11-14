-- Simulated guild: several clients, a fake GUILD channel with WoW's per-prefix
-- throttle (10 messages burst, then 1 per second), real serialization and compression,
-- virtual time. Exercises Profguild's Sync protocol end to end.

local H = ...
H.loadLibs()
local ns = H.newNamespace({ "Store.lua", "Sync.lua" })
local Store, Sync = ns.Store, ns.Sync
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")

---------------------------------------------------------------------------
-- Virtual clock and event queue
---------------------------------------------------------------------------

local Sim = {}
Sim.__index = Sim

local function newSim(seed)
	local self = setmetatable({ t = 0, events = {}, seq = 0, clients = {}, seed = seed or 1 }, Sim)
	self.rng = function()
		self.seed = (self.seed * 1103515245 + 12345) % 2147483648
		return self.seed / 2147483648
	end
	self.messages = { H = 0, R = 0, D = 0 }
	self.chunks = 0
	self.dByGuid = {}
	return self
end

function Sim:at(time, fn)
	self.seq = self.seq + 1
	local ev = { time = time, seq = self.seq, fn = fn }
	local i = #self.events + 1
	while i > 1 do
		local e = self.events[i - 1]
		if e.time < time or (e.time == time and e.seq < ev.seq) then break end
		i = i - 1
	end
	table.insert(self.events, i, ev)
end

function Sim:after(delay, fn) self:at(self.t + delay, fn) end

function Sim:runUntil(time)
	while self.events[1] and self.events[1].time <= time do
		local ev = table.remove(self.events, 1)
		self.t = ev.time
		ev.fn()
	end
	self.t = time
end

---------------------------------------------------------------------------
-- Fake GUILD channel with WoW's throttle
---------------------------------------------------------------------------

local function encode(msg)
	return LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg)))
end

local function decode(text)
	local ok, msg = LS:Deserialize(LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(text)))
	assert(ok, "deserialize failed")
	return msg
end

-- Each client sends through a token bucket: 10 messages, +1 per second.
function Sim:transmit(client, msg)
	local text = encode(msg)
	local chunks = math.max(1, math.ceil(#text / 254))
	self.messages[msg.t] = self.messages[msg.t] + 1
	self.chunks = self.chunks + chunks
	if msg.t == "D" then
		local g = msg.r.g
		self.dByGuid[g] = (self.dByGuid[g] or 0) + 1
	end
	local b = client.bucket
	local done = math.max(self.t, b.busyUntil)
	for _ = 1, chunks do
		-- refill
		local elapsed = done - b.last
		b.tokens = math.min(10, b.tokens + elapsed)
		b.last = done
		if b.tokens < 1 then
			done = done + (1 - b.tokens)
			b.tokens = 1
			b.last = done
		end
		b.tokens = b.tokens - 1
	end
	b.busyUntil = done
	local sender = client
	self:at(done + 0.1, function()
		if not sender.online or not sender.canSend then
			-- lockdown or logout mid-transfer: the receiver never gets the last chunk
			sender.sync:OnSendFailed(msg)
			return
		end
		local useful = false
		for _, c in ipairs(self.clients) do
			if c.online and c.guild == sender.guild then
				local before = c.store.revision
				c.sync:OnMessage(decode(text), sender.name) -- includes the echo to the sender
				if c ~= sender and c.store.revision ~= before then useful = true end
			end
		end
		if msg.t == "D" then
			self.dDelivered = (self.dDelivered or 0) + 1
			if not useful then self.dUseless = (self.dUseless or 0) + 1 end
		end
	end)
end

---------------------------------------------------------------------------
-- Clients
---------------------------------------------------------------------------

function Sim:addClient(name, guild, profs, recipes)
	local c = {
		name = name, guid = "Player-1-" .. name, guild = guild or "G",
		online = false, canSend = true,
		own = {}, db = {}, bucket = { tokens = 10, last = 0, busyUntil = 0 },
		profs = profs or {}, recipes = recipes or {}, session = 0,
	}
	local sim = self
	c.store = Store.New(c.db)
	local adapter = {
		send = function(msg) sim:transmit(c, msg) end,
		canSend = function() return c.online and c.canSend end,
		now = function() return sim.t end,
		after = function(delay, fn)
			local session = c.session
			sim:after(delay, function() if c.online and c.session == session then fn() end end)
		end,
		random = sim.rng,
		myGuid = function() return c.guid end,
		-- the roster of the simulated guild: character X has the guid "Player-1-X"
		isOwner = function(guid, senderName) return guid == "Player-1-" .. tostring(senderName) end,
		ownVersion = function(guid) if guid == c.guid then return c.own.v end end,
		onOwnConflict = function(_, seen, received)
			c.conflicts = (c.conflicts or 0) + 1
			local rec = Store.HealOwn(c.own, seen, received, sim.t)
			if rec then c.sync:PublishOwn(rec) end
		end,
	}
	c.sync = Sync.New(adapter, c.store, "test")
	self.clients[#self.clients + 1] = c
	return c
end

function Sim:snapshot(c)
	return { guid = c.guid, name = c.name, class = "MAGE", account = "acc-" .. c.name, ok = true, profs = c.profs }
end

-- Rebuilds the client's own record from its current profs/recipes and publishes if changed.
function Sim:refresh(c)
	for skillLine, list in pairs(c.recipes) do Store.SetScannedRecipes(c.own, skillLine, list) end
	local rec, changed = Store.BuildOwnRecord(c.own, self:snapshot(c), self.t)
	if changed and c.online then c.sync:PublishOwn(rec) end
	return rec, changed
end

function Sim:login(c)
	c.online = true
	c.session = c.session + 1
	c.sync.lastHello = -1e9
	local rec = self:refresh(c)
	c.sync:PublishOwn(rec)
	local session = c.session
	self:after(15 + 10 * self.rng(), function()
		if c.online and c.session == session then c.sync:Hello(true) end
	end)
end

function Sim:logout(c)
	c.online = false
	c.session = c.session + 1
end

local function hasAll(c, clients)
	for _, other in ipairs(clients) do
		local rec = c.store:Get(other.guid)
		if not rec or rec.v ~= other.own.v then return false, other.name end
	end
	return true
end

local function recipes(base, n)
	local r = {}
	for i = 1, n do r[base + i] = 100000 + base + i end
	return r
end

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------

H.test("sim: 20 members log in and everyone converges", function()
	local sim = newSim(7)
	local all = {}
	for i = 1, 20 do
		local c = sim:addClient("M" .. i, "G", { [197] = { s = 300, m = 300 }, [333] = { s = 250, m = 300 } },
			{ [197] = recipes(i * 1000, 150), [333] = recipes(i * 1000 + 500, 80) })
		all[#all + 1] = c
		sim:at(i * 3, function() sim:login(c) end)
	end
	sim:runUntil(300)
	for _, c in ipairs(all) do
		local ok, missing = hasAll(c, all)
		H.ok(ok, c.name .. " is missing " .. tostring(missing))
	end
	-- duplicate suppression: on average a record should not be broadcast many times
	local total = 0
	for _, n in pairs(sim.dByGuid) do total = total + n end
	local useless = (sim.dUseless or 0) / math.max(1, sim.dDelivered or 0)
	io.write(string.format("       20 members: H=%d R=%d D=%d chunks=%d, D per record=%.1f, useless D=%.0f%%\n",
		sim.messages.H, sim.messages.R, sim.messages.D, sim.chunks, total / 20, useless * 100))
	H.ok(useless <= 0.25, "too many D messages that brought nothing new")
end)

H.test("sim: new member gets data of an offline member from others", function()
	local sim = newSim(3)
	local a = sim:addClient("A", "G", { [171] = { s = 200, m = 225 } }, { [171] = recipes(1000, 40) })
	local b = sim:addClient("B", "G", { [164] = { s = 100, m = 150 } }, {})
	local c = sim:addClient("C", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	H.ok(b.store:Get(a.guid), "B knows A")
	sim:logout(a)
	sim:at(100, function() sim:login(c) end)
	sim:runUntil(200)
	local got = c.store:Get(a.guid)
	H.ok(got and got.v == a.own.v, "C received A's record via B")
	H.eq(got.p[171].r[1001], 101001, "recipe content intact")
end)

H.test("sim: dropped profession disappears for everyone", function()
	local sim = newSim(11)
	local a = sim:addClient("A", "G", { [333] = { s = 150, m = 225 }, [197] = { s = 10, m = 75 } }, { [333] = recipes(5000, 20) })
	local b = sim:addClient("B", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	H.ok(b.store:Get(a.guid).p[333], "B sees enchanting")
	a.profs[333] = nil
	a.recipes[333] = nil
	sim:refresh(a) -- first snapshot without it: kept
	sim:runUntil(80)
	sim:refresh(a) -- second: removed, new version published
	sim:runUntil(120)
	local rec = b.store:Get(a.guid)
	H.ok(rec.p[197] and not rec.p[333], "enchanting removed at B")
	H.eq(rec.v, a.own.v)
end)

H.test("sim: owner heals after losing SavedVariables", function()
	local sim = newSim(5)
	local a = sim:addClient("A", "G", { [197] = { s = 1, m = 75 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	sim:login(a); sim:login(b)
	for i = 2, 5 do
		sim:at(20 + i, function() a.profs[197].s = i; sim:refresh(a) end)
	end
	sim:runUntil(80)
	H.eq(b.store:Get(a.guid).v, 5, "B holds version 5")
	sim:logout(a)
	-- A loses everything locally
	a.own = {}; a.db = {}; a.store = Store.New(a.db); a.sync.store = a.store
	a.profs[197].s = 77
	sim:at(100, function() sim:login(a) end) -- publishes version 1, which B ignores as older
	sim:runUntil(200)
	local rec = b.store:Get(a.guid)
	H.ok(a.own.v > 5, "A jumped above the version others held (now " .. a.own.v .. ")")
	H.eq(rec.v, a.own.v, "B has A's healed version")
	H.eq(rec.p[197].s, 77, "B has A's current data")
end)

H.test("sim: messages wait during lockdown and go out afterwards", function()
	local sim = newSim(9)
	local a = sim:addClient("A", "G", { [185] = { s = 50, m = 75 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	a.canSend = false -- enters a dungeon
	Store.AddLearnedRecipe(a.own, 185, 7827, 5095)
	sim:refresh(a)
	sim:runUntil(120)
	H.ok(not b.store:Get(a.guid).p[185].r[7827], "nothing sent from the dungeon")
	H.ok(a.sync:OutboxSize() > 0, "queued")
	a.canSend = true -- leaves the dungeon
	a.sync:Flush()
	sim:runUntil(140)
	H.eq(b.store:Get(a.guid).p[185].r[7827], 5095, "delivered after leaving")
end)

H.test("sim: a malicious record is sanitized and cannot overwrite the owner", function()
	local sim = newSim(13)
	local a = sim:addClient("A", "G", { [197] = { s = 300, m = 300 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	local c = sim:addClient("C", "G", {}, {})
	sim:login(a); sim:login(b); sim:login(c)
	sim:runUntil(60)
	-- C forges A's record with a huge version while A is online
	sim:transmit(c, { t = "D", pv = Sync.PROTOCOL, s = c.guid, r = { g = a.guid, v = 1000, n = "Fake", p = { [197] = { s = 1, m = 1, r = {} } } } })
	sim:runUntil(120)
	H.ok(a.own.v > 1000, "owner bumped above the forged version")
	H.eq(b.store:Get(a.guid).p[197].s, 300, "real data wins at B")
end)

H.test("sim: other guilds never see the data", function()
	local sim = newSim(17)
	local a = sim:addClient("A", "G1", { [197] = { s = 1, m = 75 } }, {})
	local b = sim:addClient("B", "G2", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	H.eq(b.store:Get(a.guid), nil)
end)

H.test("sim: whole guild logs in at once (raid night) and converges within 3 minutes", function()
	local sim = newSim(21)
	local all = {}
	for i = 1, 20 do
		local c = sim:addClient("R" .. i, "G", { [197] = { s = 300, m = 300 }, [164] = { s = 300, m = 300 } },
			{ [197] = recipes(i * 1000, 200), [164] = recipes(i * 1000 + 500, 120) })
		all[#all + 1] = c
		sim:at(sim.rng() * 5, function() sim:login(c) end)
	end
	local converged
	for t = 10, 600, 5 do
		sim:runUntil(t)
		local done = true
		for _, c in ipairs(all) do if not hasAll(c, all) then done = false break end end
		if done then converged = t break end
	end
	io.write(string.format("       converged after %ss, H=%d R=%d D=%d chunks=%d\n", tostring(converged), sim.messages.H, sim.messages.R, sim.messages.D, sim.chunks))
	H.ok(converged and converged <= 180, "did not converge in 3 minutes")
end)

H.test("sizes: a maxed character and a large digest stay far below Comm.MAX_TEXT (24000)", function()
	local p = {}
	local base = 100
	for _, skillLine in ipairs({ 165, 197, 185, 129, 356 }) do
		local r = {}
		for i = 1, 520 do r[base + i * 3] = 20000 + base + i end
		p[skillLine] = { s = 300, m = 300, k = true, r = r }
		base = base + 5000
	end
	local text = encode({ t = "D", pv = 1, s = "Player-1-0ABCDEF0", r = { g = "Player-1-0ABCDEF0", v = 99, n = "Somebody Longsurname", c = "WARRIOR", a = "0123456789ab", t = 1794615000, p = p } })
	local d = {}
	for i = 1, 400 do d[string.format("Player-%d-%08X", 1000 + i % 7, i * 7919)] = i end
	local hello = encode({ t = "H", pv = 1, s = "Player-1-0ABCDEF0", av = "0.1.0", d = d })
	io.write(string.format("       maxed record (2600 recipes): %d bytes, %d parts; digest of 400 characters: %d bytes\n", #text, math.ceil(#text / 254), #hello))
	H.ok(#text < 24000 / 2 and #hello < 24000 / 2)
end)

H.test("sim: a hello queued in a dungeon still goes out right after leaving", function()
	local sim = newSim(23)
	local a = sim:addClient("A", "G", { [197] = { s = 1, m = 75 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	sim:login(b)
	sim:runUntil(30)
	a.canSend = false
	sim:login(a)
	sim:runUntil(60) -- A's login hello is queued
	a.canSend = true
	a.sync:Flush() -- immediately after leaving, within the hello rate limit
	sim:runUntil(70)
	H.ok(b.sync.stats.recvH >= 1, "B received A's hello")
	H.ok(b.store:Get(a.guid), "and A's record")
end)

H.test("sim: owner who lost SavedVariables keeps its recipes from the guild copy", function()
	local sim = newSim(29)
	local a = sim:addClient("A", "G", { [197] = { s = 250, m = 300 } }, { [197] = recipes(3000, 60) })
	local b = sim:addClient("B", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	H.eq(b.store:Get(a.guid).v, a.own.v, "B holds A")
	sim:logout(a)
	-- A loses SavedVariables and has not opened Tailoring again
	a.own = {}; a.db = {}; a.store = Store.New(a.db); a.sync.store = a.store
	a.recipes = {}
	sim:at(100, function() sim:login(a) end)
	sim:runUntil(200)
	local rec = b.store:Get(a.guid)
	H.eq(rec.v, a.own.v, "B has A's healed version")
	H.ok(rec.p[197].k, "still marked scanned")
	H.eq(rec.p[197].r[3001], 103001, "B still has A's recipes")
	H.ok(a.own.scanned[197] and a.own.recipes[197][3060], "A took its recipes back")
end)

H.test("sim: owner blocked at login (dungeon) still heals and keeps its recipes", function()
	local sim = newSim(31)
	local a = sim:addClient("A", "G", { [197] = { s = 250, m = 300 } }, { [197] = recipes(4000, 30) })
	local b = sim:addClient("B", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	sim:logout(a)
	a.own = {}; a.db = {}; a.store = Store.New(a.db); a.sync.store = a.store
	a.recipes = {}
	-- A comes back but cannot send (dungeon): its own D v1 stays queued, it only hears B's hello
	a.canSend = false
	sim:at(100, function() sim:login(a) end)
	sim:at(110, function() b.sync.lastHello = -1e9; b.sync:Hello(true) end)
	sim:at(115, function() a.canSend = true; a.sync:Flush() end)
	sim:runUntil(200)
	local rec = b.store:Get(a.guid)
	H.eq(rec.v, a.own.v)
	H.eq(rec.p[197].r[4001], 104001, "recipes survived")
end)

H.test("sim: a hello with an impossible version of our record cannot break the owner", function()
	for _, bad in ipairs({ 5.5, 1e300, Store.LIMITS.maxVersion + 1 }) do
		local sim = newSim(21)
		local a = sim:addClient("A", "G", { [197] = { s = 1, m = 75 } }, {})
		local b = sim:addClient("B", "G", {}, {})
		sim:login(a); sim:login(b)
		sim:runUntil(60)
		a.sync:OnMessage({ t = "H", pv = Sync.PROTOCOL, s = "Player-1-Evil", d = { [a.guid] = bad } })
		sim:runUntil(120)
		H.eq(a.conflicts, nil, "no self-heal for version " .. tostring(bad))
		H.eq(a.own.v, 1, "own version untouched")
		a.profs[197].s = 2; sim:refresh(a)
		sim:runUntil(180)
		H.eq(b.store:Get(a.guid).p[197].s, 2, "owner still publishes")
	end
end)

H.test("sim: a forged copy with the maximum version does not start an endless exchange", function()
	local max = Store.LIMITS.maxVersion
	local sim = newSim(22)
	local a = sim:addClient("A", "G", { [197] = { s = 1, m = 75 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	local forged = { t = "D", pv = Sync.PROTOCOL, s = "Player-1-Evil",
		r = { g = a.guid, v = max, n = "A", p = { [171] = { s = 300, m = 300, k = true, r = { [1] = 2 } } } } }
	a.sync:OnMessage(forged); b.sync:OnMessage(forged)
	sim:runUntil(200)
	local before = sim.messages.D
	sim:runUntil(2000)
	H.ok(sim.messages.D - before <= 2, "no D ping-pong: " .. (sim.messages.D - before))
	H.eq(a.own.v, max); H.ok(Store.Validate(a.own.rec), "owner record stays valid")
end)

H.test("sim: a forged copy with the maximum version does not pin the owner's record", function()
	local max = Store.LIMITS.maxVersion
	local sim = newSim(24)
	local a = sim:addClient("A", "G", { [197] = { s = 1, m = 75 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	local c = sim:addClient("C", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	local forged = { g = a.guid, v = max, n = "A", p = { [171] = { s = 300, m = 300, k = true, r = { [1] = 2 } } } }
	-- the forger is not the owner: its name does not match A's guid
	sim:transmit(b, { t = "D", pv = Sync.PROTOCOL, s = "Player-1-Evil", r = forged })
	c.store:Apply(forged) -- C got the forged copy too and is offline while the guild repairs it
	sim:runUntil(200)
	H.eq(a.own.v, max, "owner is at the maximum version")
	H.ok(b.store:Get(a.guid).p[197] and not b.store:Get(a.guid).p[171], "B took the owner's copy back")
	-- the owner keeps publishing changes although its version cannot rise
	a.profs[197].s = 42; sim:refresh(a)
	sim:runUntil(260)
	H.eq(b.store:Get(a.guid).p[197].s, 42, "later changes still reach B")
	-- a forged copy sent again does not replace the owner's
	sim:transmit(b, { t = "D", pv = Sync.PROTOCOL, s = "Player-1-Evil", r = forged })
	sim:runUntil(300)
	H.eq(b.store:Get(a.guid).p[197].s, 42, "forged copy ignored")
	-- C comes back with the forged copy: the owner's hello shows a different checksum
	sim:login(c)
	sim:at(340, function() a.sync.lastHello = -1e9; a.sync:Hello(true) end)
	sim:runUntil(420)
	H.eq(c.store:Get(a.guid).p[197] and c.store:Get(a.guid).p[197].s, 42, "C repaired from the owner")
end)

H.test("sim: a record whose answer was lost is requested again", function()
	local sim = newSim(26)
	local a = sim:addClient("A", "G", { [197] = { s = 5, m = 75 } }, {})
	local b = sim:addClient("B", "G", {}, {})
	local c = sim:addClient("C", "G", {}, {})
	sim:login(a); sim:login(b)
	sim:runUntil(60)
	sim:logout(a)
	sim:login(c)
	c.sync.lastHello = -1e9
	-- C learns from B's hello that A exists, asks, and B logs off before answering
	sim:at(70, function() b.sync.lastHello = -1e9; b.sync:Hello(true) end)
	sim:runUntil(70.5)
	sim:runUntil(72)
	sim:at(72.05, function() sim:logout(b) end)
	sim:runUntil(100)
	if c.store:Get(a.guid) == nil then
		H.ok(c.sync.wanted[a.guid] ~= nil, "still wanted")
		-- B is back; its next hellos advertise the same version
		b.sync.pendingD, b.sync.sendQueue = {}, {} -- a new game session starts without pending answers
		sim:login(b)
		for t = 130, 400, 30 do
			sim:at(t, function() b.sync.lastHello = -1e9; b.sync:Hello(true) end)
		end
		sim:runUntil(420)
	end
	H.ok(c.store:Get(a.guid), "C finally received A's record")
end)

H.test("sim: an empty database does not make everyone send everything", function()
	local sim = newSim(28)
	local all = {}
	for i = 1, 12 do
		local c = sim:addClient("P" .. i, "G", { [197] = { s = 300, m = 300 } }, { [197] = recipes(i * 1000, 20) })
		all[#all + 1] = c
		sim:at(i, function() sim:login(c) end)
	end
	-- 60 more members who are offline: everybody holds their records
	local offline = {}
	for i = 1, 60 do
		local rec = { g = "Player-1-Off" .. i, v = 3, n = "Off" .. i, c = "MAGE", t = 1, p = { [171] = { s = 100, m = 150, k = true, r = recipes(50000 + i * 100, 10) } } }
		offline[#offline + 1] = rec
		for _, c in ipairs(all) do c.store:Apply(rec) end
	end
	sim:runUntil(200)
	local before = sim.messages.D
	local newcomer = sim:addClient("New", "G", {}, {})
	sim:login(newcomer)
	sim:runUntil(600)
	for _, rec in ipairs(offline) do H.ok(newcomer.store:Get(rec.g), "newcomer has " .. rec.g) end
	local sent = sim.messages.D - before
	io.write(string.format("       newcomer: %d records needed, %d D messages sent\n", 72, sent))
	H.ok(sent <= 72 * 1.25, "close to one D per record (99 before answers were paced): " .. sent)
end)
