-- Profguild: Sync
-- The H / R / D gossip protocol. Talks to the game only through an adapter,
-- so the whole protocol runs in unit tests and in a simulated guild.
--
-- Messages (tables, serialized by Comm):
--   H hello   { t="H", pv, s=senderGuid, av=addonVersion, d={ [guid]=version } }
--   R request { t="R", pv, s=senderGuid, g={ guid, ... } }
--   D data    { t="D", pv, s=senderGuid, r=record }
--
-- Adapter (all functions required unless noted):
--   send(msg)                 queue msg on the GUILD addon channel
--   canSend() -> bool         false in instances, combat, trial accounts, no guild
--   now() -> seconds
--   after(seconds, fn)        one-shot timer
--   random() -> [0,1)
--   myGuid() -> guid of the logged-in character
--   ownVersion(guid) -> number|nil   version of OUR current character's record
--   onOwnConflict(guid, seenVersion, received) someone holds our record with a version >= ours;
--                             received is that copy (validated) or nil when only a hello showed it
--   onChanged()               (optional) store content changed
--   log(fmt, ...)             (optional) debug output

local _, ns = ...
ns = ns or {}

local Sync = {}
ns.Sync = Sync

Sync.PROTOCOL = 1
Sync.HELLO_MIN_INTERVAL = 30      -- seconds between automatic hellos
Sync.HELLO_FORCE_INTERVAL = 5     -- minimum even for /pg sync
Sync.REPLY_DELAY = { 1.0, 4.0 }   -- random wait before answering with D
Sync.OWNER_DELAY = { 0.3, 0.8 }   -- the owner answers for its own record first
Sync.REQUEST_DELAY = { 1.0, 3.0 }
Sync.MAX_GUIDS_PER_REQUEST = 60
Sync.MAX_DIGEST = 5000
Sync.PEER_TTL = 3600
Sync.HEAL_WAIT = 20               -- seconds to wait for a copy of our own record before republishing

local SyncMT = {}
SyncMT.__index = SyncMT

function Sync.New(adapter, store, addonVersion)
	local self = setmetatable({
		a = adapter,
		store = store,
		av = addonVersion or "0",
		pendingD = {},     -- guid -> { v = version, cancelled = bool }
		wanted = {},       -- guid -> minimal version we are waiting for
		requestTimer = false,
		outbox = {},       -- ordered list of queued messages while sending is blocked
		outboxD = {},      -- guid -> true (dedupe of queued D)
		lastHello = -1e9,
		peers = {},        -- senderGuid -> { seen = time, av = version }
		newerProtocolSeen = false,
		stats = { sentH = 0, sentR = 0, sentD = 0, recvH = 0, recvR = 0, recvD = 0, applied = 0, dropped = 0 },
	}, SyncMT)
	return self
end

local function log(self, ...)
	if self.a.log then self.a.log(...) end
end

local function between(self, range)
	return range[1] + (range[2] - range[1]) * self.a.random()
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function queue(self, msg)
	if msg.t == "D" then
		local guid = msg.r and msg.r.g
		if guid and self.outboxD[guid] then return end
		if guid then self.outboxD[guid] = true end
		self.outbox[#self.outbox + 1] = { t = "D", g = guid }
	elseif msg.t == "H" then
		for _, q in ipairs(self.outbox) do if q.t == "H" then return end end
		self.outbox[#self.outbox + 1] = { t = "H" }
	elseif msg.t == "R" then
		for _, guid in ipairs(msg.g or {}) do
			if self.wanted[guid] == nil then self.wanted[guid] = 0 end
		end
		local hasR = false
		for _, q in ipairs(self.outbox) do if q.t == "R" then hasR = true end end
		if not hasR then self.outbox[#self.outbox + 1] = { t = "R" } end
	end
end

local function rawSend(self, msg)
	msg.pv = Sync.PROTOCOL
	msg.s = self.a.myGuid()
	if msg.t == "H" then
		self.stats.sentH = self.stats.sentH + 1
	elseif msg.t == "R" then
		self.stats.sentR = self.stats.sentR + 1
	elseif msg.t == "D" then
		self.stats.sentD = self.stats.sentD + 1
	end
	self.a.send(msg)
end

local function sendOrQueue(self, msg)
	if self.a.canSend() then
		rawSend(self, msg)
	else
		queue(self, msg)
	end
end

-- Called by Comm when a message could not be delivered (e.g. lockdown started mid-transfer).
function SyncMT:OnSendFailed(msg)
	if type(msg) ~= "table" then return end
	queue(self, msg)
end

-- Sends everything that waited while sending was blocked.
function SyncMT:Flush()
	if #self.outbox == 0 or not self.a.canSend() then return 0 end
	local items = self.outbox
	self.outbox, self.outboxD = {}, {}
	local sent = 0
	for _, q in ipairs(items) do
		if q.t == "H" then
			-- queued hellos bypass the rate limit: the original call already passed it
			self.lastHello = self.a.now()
			sendOrQueue(self, { t = "H", av = self.av, d = self.store:Digest() })
		elseif q.t == "R" then
			self:_SendRequest()
		elseif q.t == "D" and q.g then
			local rec = self.store:Get(q.g)
			if rec then sendOrQueue(self, { t = "D", r = rec }) end
		end
		sent = sent + 1
	end
	return sent
end

function SyncMT:OutboxSize()
	return #self.outbox
end

---------------------------------------------------------------------------
-- Hello
---------------------------------------------------------------------------

-- force: user asked (/pg sync) or we just logged in.
function SyncMT:Hello(force)
	local now = self.a.now()
	local minGap = force and Sync.HELLO_FORCE_INTERVAL or Sync.HELLO_MIN_INTERVAL
	if now - self.lastHello < minGap then return false end
	self.lastHello = now
	sendOrQueue(self, { t = "H", av = self.av, d = self.store:Digest() })
	return true
end

---------------------------------------------------------------------------
-- Scheduling answers with duplicate suppression
---------------------------------------------------------------------------

function SyncMT:ScheduleData(guid, fast)
	local rec = self.store:Get(guid)
	if not rec then return end
	local p = self.pendingD[guid]
	if p and not p.cancelled and p.v >= rec.v then return end
	if p then p.cancelled = true end
	local entry = { v = rec.v, cancelled = false }
	self.pendingD[guid] = entry
	local delay = between(self, fast and Sync.OWNER_DELAY or Sync.REPLY_DELAY)
	self.a.after(delay, function()
		if entry.cancelled then return end
		if self.pendingD[guid] == entry then self.pendingD[guid] = nil end
		local cur = self.store:Get(guid)
		if cur then sendOrQueue(self, { t = "D", r = cur }) end
	end)
end

function SyncMT:_SendRequest()
	local list = {}
	for guid in pairs(self.wanted) do list[#list + 1] = guid end
	if #list == 0 then return end
	table.sort(list)
	local i = 1
	while i <= #list do
		local chunk = {}
		for j = i, math.min(#list, i + Sync.MAX_GUIDS_PER_REQUEST - 1) do chunk[#chunk + 1] = list[j] end
		sendOrQueue(self, { t = "R", g = chunk })
		i = i + Sync.MAX_GUIDS_PER_REQUEST
	end
end

function SyncMT:ScheduleRequest(guids, versions)
	local added = false
	for _, guid in ipairs(guids) do
		local need = versions and versions[guid] or 0
		if self.wanted[guid] == nil or need > self.wanted[guid] then
			self.wanted[guid] = need
			added = true
		end
	end
	if not added or self.requestTimer then return end
	self.requestTimer = true
	self.a.after(between(self, Sync.REQUEST_DELAY), function()
		self.requestTimer = false
		self:_SendRequest()
	end)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- Keeps only versions a valid record can carry (whole numbers up to the store's maximum):
-- anything else could never be fetched, and as a version of our own record it would push
-- our version out of the valid range.
local function validDigest(d)
	if type(d) ~= "table" then return nil end
	local maxVersion = ns.Store.LIMITS.maxVersion
	local out, n = {}, 0
	for guid, v in pairs(d) do
		n = n + 1
		if n > Sync.MAX_DIGEST then break end
		if type(guid) == "string" and #guid <= 64 and type(v) == "number"
			and v >= 1 and v <= maxVersion and v == math.floor(v) then
			out[guid] = v
		end
	end
	return out
end

function SyncMT:OnMessage(msg)
	if type(msg) ~= "table" or type(msg.t) ~= "string" then
		self.stats.dropped = self.stats.dropped + 1
		return
	end
	if msg.pv ~= Sync.PROTOCOL then
		if type(msg.pv) == "number" and msg.pv > Sync.PROTOCOL then self.newerProtocolSeen = true end
		self.stats.dropped = self.stats.dropped + 1
		return
	end
	local me = self.a.myGuid()
	if msg.s == me then return end -- GUILD addon messages are echoed to the sender
	if type(msg.s) == "string" then
		local peer = self.peers[msg.s] or {}
		peer.seen = self.a.now()
		if msg.av then peer.av = tostring(msg.av) end
		self.peers[msg.s] = peer
	end

	if msg.t == "H" then
		self.stats.recvH = self.stats.recvH + 1
		self:_OnHello(msg, me)
	elseif msg.t == "R" then
		self.stats.recvR = self.stats.recvR + 1
		self:_OnRequest(msg, me)
	elseif msg.t == "D" then
		self.stats.recvD = self.stats.recvD + 1
		self:_OnData(msg, me)
	else
		self.stats.dropped = self.stats.dropped + 1
	end
end

function SyncMT:_OnHello(msg, me)
	local d = validDigest(msg.d)
	if not d then return end
	local ownV = self.a.ownVersion(me)
	if ownV and d[me] and d[me] > ownV then
		self:_OwnNewerSeen(me, d[me])
	end
	local mine, theirs = self.store:Compare(d)
	for _, guid in ipairs(mine) do
		self:ScheduleData(guid, guid == me)
	end
	local need = {}
	for _, guid in ipairs(theirs) do
		if guid ~= me then need[#need + 1] = guid end
	end
	if #need > 0 then self:ScheduleRequest(need, d) end
end

-- A hello shows that someone holds our record with a higher version than ours. Ask for the
-- record itself first, so the owner can take over recipes it lost; republish without the copy
-- only when nobody answers within HEAL_WAIT seconds.
function SyncMT:_OwnNewerSeen(me, version)
	if self.healWait and self.healWait >= version then return end
	self.healWait = version
	self:ScheduleRequest({ me }, { [me] = version })
	self.a.after(Sync.HEAL_WAIT, function()
		if self.healWait ~= version then return end
		self.healWait = nil
		if self.wanted[me] ~= nil and self.wanted[me] <= version then self.wanted[me] = nil end
		-- nobody answered: republish above it without the copy
		local ownV = self.a.ownVersion(me) or 0
		if version > ownV then self.a.onOwnConflict(me, version, nil) end
	end)
end

function SyncMT:_OnRequest(msg, me)
	if type(msg.g) ~= "table" then return end
	local n = 0
	for _, guid in ipairs(msg.g) do
		n = n + 1
		if n > Sync.MAX_GUIDS_PER_REQUEST then break end
		if type(guid) == "string" then
			-- Someone else asked for it; the answer reaches us too, so we stop asking.
			if self.wanted[guid] ~= nil then self.wanted[guid] = nil end
			if self.store:Get(guid) then self:ScheduleData(guid, guid == me) end
		end
	end
end

function SyncMT:_OnData(msg, me)
	local rec = msg.r
	if type(rec) ~= "table" or type(rec.g) ~= "string" or type(rec.v) ~= "number" then return end
	local guid = rec.g

	-- Someone else answered: drop our own pending answer if it would not add anything.
	local p = self.pendingD[guid]
	if p and rec.v >= p.v then
		p.cancelled = true
		self.pendingD[guid] = nil
	end

	if guid == me then
		-- Only we write our record. A copy with a higher version, or a different copy with
		-- the same version, means we lost our saved version: jump above it and republish.
		-- The copy goes along, so the owner can keep recipes it has not scanned again.
		local w = self.wanted[me]
		if w ~= nil and rec.v >= w then self.wanted[me] = nil end
		if self.healWait and rec.v >= self.healWait then self.healWait = nil end
		local clean = ns.Store.Validate(rec)
		if not clean then return end
		local ownV = self.a.ownVersion(me) or 0
		local cur = self.store:Get(me)
		local differs = not (cur and ns.Store.DeepEqual(cur.p, clean.p))
		-- At the maximum version we cannot jump above a different copy any more: answering
		-- it would only repeat the same exchange forever, so it is left alone.
		if clean.v > ownV or (clean.v == ownV and differs and ownV < ns.Store.LIMITS.maxVersion) then
			self.a.onOwnConflict(me, clean.v, clean)
		end
		return
	end

	local status = self.store:Apply(rec)
	if status == "new" or status == "updated" then
		self.stats.applied = self.stats.applied + 1
		local w = self.wanted[guid]
		if w ~= nil and rec.v >= w then self.wanted[guid] = nil end
		if self.a.onChanged then self.a.onChanged(guid) end
	elseif status == "same" then
		local w = self.wanted[guid]
		if w ~= nil and rec.v >= w then self.wanted[guid] = nil end
		-- The owner announces a version we hold with other content: it lost its saved version
		-- and counts again from an old number. Send our copy back so it can heal (suppressed
		-- when someone else does it first). Only the owner's own announcement triggers this.
		if msg.s == guid then
			local cur, clean = self.store:Get(guid), ns.Store.Validate(rec)
			if cur and clean and not ns.Store.DeepEqual(cur.p, clean.p) then
				self.stats.collisions = (self.stats.collisions or 0) + 1
				self:ScheduleData(guid, false)
			end
		end
	elseif status == "older" then
		-- We hold something newer: correct the guild (suppressed if others do it first).
		self:ScheduleData(guid, false)
	end
end

---------------------------------------------------------------------------
-- Owner side
---------------------------------------------------------------------------

-- Store and announce the record of the logged-in character.
function SyncMT:PublishOwn(rec)
	local status = self.store:Apply(rec)
	if status == "new" or status == "updated" then
		if self.a.onChanged then self.a.onChanged(rec.g) end
	end
	local p = self.pendingD[rec.g]
	if p then p.cancelled = true; self.pendingD[rec.g] = nil end
	self:ScheduleData(rec.g, true)
end

-- Number of peers seen recently (other characters running Profguild).
function SyncMT:ActivePeers(maxAge)
	local now = self.a.now()
	maxAge = maxAge or 1200
	local n = 0
	for guid, peer in pairs(self.peers) do
		if now - (peer.seen or 0) <= maxAge then
			n = n + 1
		elseif now - (peer.seen or 0) > Sync.PEER_TTL then
			self.peers[guid] = nil
		end
	end
	return n
end

return Sync
