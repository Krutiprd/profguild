-- Profguild: NpcSync
-- Shares the guild's NPC sheets (ns.NpcData.New) on the ProfguildNPC prefix. Pure: no WoW API, all
-- of it goes through the adapter. The rules are those of the design's "Sharing" (1-10), as they
-- were tuned in simulation; tests/npcsim.lua runs a guild of these objects.
--
-- Messages (all carry t, pv = PROTOCOL, e = EPOCH, f = faction, s = own GUID, h = table hash):
--   ND digest     { n = sendable sheets }
--   NI inventory  { r = salt 0-65535, i = { ID deltas }, c = { salted 16-bit hash per ID } }
--   NR request    { to = the NI sender's name as the game gave it, i = { ID deltas } }
--   NU update     { x = { packed sheet, ... } }, filled to about NU_FILL bytes
-- A round begins with an NI and ends SETTLE seconds after the last NI, NR or NU.
--
-- Adapter: now() (seconds, monotonic), after(seconds, fn), random() -> [0,1), canSend() -> bool,
--          send(msg, done) (done(ok) once, maybe never), selfGuid(), faction(), changed(),
--          isMe(name) (the game's sender name is our own), size(msg) -> encoded bytes.
-- One object per session: Stop() ends it (logout, guild change); a new session gets a new one.

local _, ns = ...
ns = ns or {}

local NpcSync = {}
ns.NpcSync = NpcSync

local floor, ceil, pairs, ipairs, next, sort, type = math.floor, math.ceil, pairs, ipairs, next, table.sort, type

NpcSync.HELLO_DELAY = 10          -- rule 1: ND this long after a hello
NpcSync.HELLO_EQUAL = 600         -- ... unless an equal ND was heard this recently
NpcSync.CONFIRM = { 60, 120 }     -- an own ND not confirmed in this time is repeated
NpcSync.REPEATS = 3
NpcSync.QUIET = 12                -- seconds without NI, NR, NU
NpcSync.REPEAT_JITTER = 8
NpcSync.NI_DELAY = { 2, 20 }      -- rule 2
NpcSync.NI_JITTER = 12
NpcSync.NI_WAIT = 120
NpcSync.NI_GAP = 65
NpcSync.NU_DELAY = { 0.5, 10 }    -- rule 3
NpcSync.POSTPONE = { 40, 60 }
NpcSync.NR_DELAY = { 1, 8 }       -- rule 4
NpcSync.NR_CAP = 10
NpcSync.ANSWER_DELAY = 2
NpcSync.ECHO_DELAY = { 2, 6 }
NpcSync.REFUSED = 100
NpcSync.SETTLE = { 12, 24 }       -- rule 5
NpcSync.ND_GAP = 30
NpcSync.MUTE_ROUNDS = 2           -- rule 6
NpcSync.MUTE_NIS = 3
NpcSync.FOREIGN = 120             -- a hash heard this recently takes part in a fruitless round
NpcSync.WAIT = 30                 -- rule 7
NpcSync.RETRY = { 1, 3 }
NpcSync.POLL = 5
NpcSync.AFTER_BLOCK = { 10, 20 }
NpcSync.AFTER_BLOCK_EQUAL = 60
NpcSync.VISIT_DELAY = 3           -- rule 8
NpcSync.NI_EVERY = 60             -- rule 9
NpcSync.ND_PER_MINUTE = 2
NpcSync.SEND_CAP = 6
NpcSync.COUNT_EVERY = 60
NpcSync.HOUR = 3600
NpcSync.NU_FILL = 1000
NpcSync.PART = 254
NpcSync.DONE_TIMEOUT = 30         -- no done after this plus 1 s per part: failed
NpcSync.MAX_LIST = 600            -- IDs or sheets read from one message
NpcSync.MAX_NAME = 100

local M = 2147483647

local function int(v, lo, hi)
	return type(v) == "number" and v >= lo and v <= hi and v == floor(v)
end

-- The length of a received list that is exactly 1..n (no holes, no other keys), at most max; else
-- nil. The keys are counted, never taken from # (a list with holes has any border as #).
local function sequence(list, max)
	if type(list) ~= "table" then return nil end
	local n, top = 0, 0
	for k in pairs(list) do
		n = n + 1
		if n > max or not int(k, 1, max) then return nil end
		if k > top then top = k end
	end
	if top ~= n then return nil end -- distinct keys 1..max, as many as the greatest: exactly 1..n
	return n
end
NpcSync.sequence = sequence

-- Sorted IDs from deltas (each at least 1), nil when broken.
local function fromDeltas(list)
	local n = sequence(list, NpcSync.MAX_LIST)
	if not n then return nil end
	local ids, id = {}, 0
	for i = 1, n do
		local d = list[i]
		if not int(d, 1, M) then return nil end
		id = id + d
		if id > M then return nil end
		ids[i] = id
	end
	return ids
end

local function toDeltas(ids)
	local out, prev = {}, 0
	for i, id in ipairs(ids) do out[i], prev = id - prev, id end
	return out
end

-- Received sheets: a packed list unpacked once per day of the receiver (the simulation hands one
-- decoded message to every client; in the game every list is new and this only holds it till GC).
local unpacked = setmetatable({}, { __mode = "k" })

local function unpackSheet(list, today)
	local c = unpacked[list]
	if c and c.day == today then return c.id, c.s, c.h end
	local NpcData = ns.NpcData
	local id, s = NpcData.Unpack(list, today)
	local h = s and NpcData.HashSheet(id, s) or nil
	unpacked[list] = { day = today, id = id, s = s, h = h }
	return id, s, h
end

local Sync = {}
Sync.__index = Sync

function NpcSync.New(adapter, tab)
	local self = setmetatable({ a = adapter, tab = tab, dead = false,
		eqND = {},        -- table hash -> when an ND carrying it was heard
		foreign = {},     -- table hash other than ours -> when heard (ND, NI)
		pair = {},        -- "theirs:ours" -> { n = own NIs, r = fruitless rounds, t = since }
		niSeen = {}, ndSeen = {}, -- sender name -> last NI / { since, NDs }
		nrHeard = {},     -- NI sender name -> times of NRs to it (heard or sent)
		counts = nil,     -- rule 9: { [0] = since, [key] = n }
		raised = {},      -- rule 9: key -> when its counter last rose
		refused = {}, refusedList = {}, -- rule 4: ID -> content hash of a sheet the limits refused
		lastNI = -1e9, lastND = -1e9, lastData = -1e9, lastPrune = 0,
		push = nil,       -- ID -> { who = NI sender name or nil, since = first attempt }: sheets to send
		missing = nil,    -- ID -> true: what the last NI showed we lack
		plan = nil,       -- planned NI { h, t0 }
		sending = false, round = nil, hold = nil, cursor = nil,
		dirtyOn = false, ndSeq = 0, settleSeq = 0, laterSeq = 0,
		sizes = {},       -- "id:hash" -> encoded bytes of an NU of that sheet alone
		stats = { sent = {}, bytes = {}, recv = {}, capped = 0, muted = 0, dropped = 0, foreign = 0, bad = 0 },
	}, Sync)
	return self
end

-- Helpers --------------------------------------------------------------------

local function now(self) return self.a.now() end
local function rnd(self, range) return range[1] + (range[2] - range[1]) * self.a.random() end
local function canSend(self) return not self.dead and self.a.canSend() end

local function after(self, s, fn)
	self.a.after(s, function() if not self.dead then fn() end end)
end

local function equalHeard(self, window)
	local e = self.eqND[self.tab:Hash()]
	return e ~= nil and now(self) - e <= window
end

-- Sends msg of type t with the common fields; done(ok, size) once (a send without done in
-- DONE_TIMEOUT + 1 s per part counts as failed, a late done is ignored).
local function transmit(self, t, msg, done)
	local NpcData = ns.NpcData
	msg.t, msg.pv, msg.e, msg.f, msg.s, msg.h = t, NpcData.PROTOCOL, NpcData.EPOCH, self.a.faction(),
		self.a.selfGuid(), self.tab:Hash()
	local size = self.a.size(msg)
	local st = self.stats
	st.sent[t] = (st.sent[t] or 0) + 1
	st.bytes[t] = (st.bytes[t] or 0) + size
	local fired = false
	local function finish(ok)
		if fired then return end
		fired = true
		-- blocked: the failure came while sending was blocked (rule 7), not from the send itself
		if done and not self.dead then done(ok and true or false, size, not ok and not self.a.canSend()) end
	end
	self.a.after(NpcSync.DONE_TIMEOUT + ceil(size / NpcSync.PART), function() finish(false) end)
	self.a.send(msg, finish)
	return size
end

-- Rule 9: a counter of sheet content sent; true while it is at most SEND_CAP. It rises at most
-- once per COUNT_EVERY; all are cleared an HOUR after the first rose.
local function count(self, key)
	local t = now(self)
	local last = self.raised[key]
	local c = self.counts
	if last and t - last < NpcSync.COUNT_EVERY then
		return ((c and c[key]) or 0) <= NpcSync.SEND_CAP
	end
	self.raised[key] = t
	if not c or t - c[0] > NpcSync.HOUR then
		c = { [0] = t }
		self.counts = c
	end
	local n = (c[key] or 0) + 1
	c[key] = n
	return n <= NpcSync.SEND_CAP
end

local function contentKey(self, id) return self.tab:SheetHash(id) .. ":" .. id end

-- Rule 6: the record of (their hash, our hash), renewed after an hour.
local function pairOf(self, h)
	local key = h .. ":" .. self.tab:Hash()
	local p = self.pair[key]
	if not p or now(self) - p.t > NpcSync.HOUR then
		p = { n = 0, r = 0, t = now(self) }
		self.pair[key] = p
	end
	return p
end

local function muted(p) return p.n >= NpcSync.MUTE_NIS or p.r >= NpcSync.MUTE_ROUNDS end

-- Forgets what is older than an hour, so floods of names and hashes do not pile up.
local function prune(self)
	local t = now(self)
	if t - self.lastPrune < 300 then return end
	self.lastPrune = t
	local old = t - NpcSync.HOUR
	for _, map in ipairs({ self.eqND, self.foreign, self.niSeen }) do
		for k, v in pairs(map) do if v < old then map[k] = nil end end
	end
	for k, v in pairs(self.ndSeen) do if v[1] < old then self.ndSeen[k] = nil end end
	for k, p in pairs(self.pair) do if p.t < old then self.pair[k] = nil end end
	for k, v in pairs(self.raised) do if v < t - NpcSync.COUNT_EVERY then self.raised[k] = nil end end
	for k, list in pairs(self.nrHeard) do
		local keep = {}
		for _, x in ipairs(list) do if x >= old then keep[#keep + 1] = x end end
		self.nrHeard[k] = keep[1] and keep or nil
	end
	-- sizes of old contents: cleared when more than twice the sheets a table holds
	local n = 0
	for _ in pairs(self.sizes) do n = n + 1 end
	if n > 2 * ns.NpcData.LIMIT_SHEETS then self.sizes = {} end
end

-- Rounds ---------------------------------------------------------------------

local function openRound(self)
	if not self.round then self.round = { h0 = self.tab:Hash(), had = false } end
	return self.round
end

local sendND

-- Rule 5 and the end of a round (rule 6).
local function settle(self)
	self.settleSeq = self.settleSeq + 1
	local k = self.settleSeq
	openRound(self)
	after(self, rnd(self, NpcSync.SETTLE), function()
		if k ~= self.settleSeq then return end
		if self.sending then return settle(self) end
		local R = self.round
		self.round = nil
		if not R then return end
		local H, t = self.tab:Hash(), now(self)
		if R.ni and not R.had then
			for h, heard in pairs(self.foreign) do
				if h ~= H and t - heard < NpcSync.FOREIGN then
					local p = pairOf(self, h)
					p.r = p.r + 1
				end
			end
		end
		if H ~= R.h0 or (R.ni and R.hNI and R.hNI ~= H) then
			if not equalHeard(self, NpcSync.ND_GAP) and t - self.lastND >= NpcSync.ND_GAP then sendND(self) end
		end
	end)
end

-- Rule 7: something was dropped or due while blocked; an ND after the block.
local function dirty(self)
	if self.dirtyOn then return end
	self.dirtyOn = true
	local function check()
		if not self.a.canSend() then return after(self, NpcSync.POLL, check) end
		after(self, rnd(self, NpcSync.AFTER_BLOCK), function()
			self.dirtyOn = false
			if not equalHeard(self, NpcSync.AFTER_BLOCK_EQUAL) then sendND(self) end
		end)
	end
	after(self, NpcSync.POLL, check)
end

-- Rule 1: ND, repeated while no equal ND confirms it.
function sendND(self, n)
	if not canSend(self) then return dirty(self) end
	self.lastND = now(self)
	transmit(self, "ND", { n = (self.tab:Count()) }, function(ok, _, blocked)
		if not ok then
			-- rule 10; again after a block (rule 7), but a send that itself fails is not repeated in a loop
			self.lastND = -1e9
			if blocked then dirty(self) end
		end
	end)
	self.ndSeq = self.ndSeq + 1
	local k, sentAt = self.ndSeq, now(self)
	n = n or 0
	if n >= NpcSync.REPEATS then return end
	local function check()
		if k ~= self.ndSeq then return end
		local e = self.eqND[self.tab:Hash()]
		if e and e >= sentAt then return end
		local q = now(self) - self.lastData
		if q < NpcSync.QUIET then
			return after(self, NpcSync.QUIET - q + self.a.random() * NpcSync.REPEAT_JITTER, check)
		end
		sendND(self, n + 1)
	end
	after(self, rnd(self, NpcSync.CONFIRM), check)
end

-- Sending sheets (rules 3, 4, 7) ---------------------------------------------

local step

local function later(self, d)
	self.laterSeq = self.laterSeq + 1
	local k = self.laterSeq
	after(self, d, function() if k == self.laterSeq then step(self) end end)
end

local function sheetSize(self, id)
	local key = contentKey(self, id)
	local n = self.sizes[key]
	if not n then
		local NpcData = ns.NpcData
		n = self.a.size({ t = "NU", pv = NpcData.PROTOCOL, e = NpcData.EPOCH, f = self.a.faction(),
			s = self.a.selfGuid(), h = self.tab:Hash(), x = { NpcData.Pack(id, self.tab:Sendable(id)) } })
		self.sizes[key] = n
	end
	return n
end

function step(self)
	self.sending = false
	local t = now(self)
	if not canSend(self) then
		-- rule 7: each planned sheet waits WAIT seconds from its first attempt, blocked or failed
		local push, left = self.push, false
		if push then
			for id, q in pairs(push) do
				q.since = q.since or t
				if t - q.since >= NpcSync.WAIT then
					push[id] = nil
					self.stats.dropped = self.stats.dropped + 1
				else
					left = true
				end
			end
		end
		if left then return later(self, rnd(self, NpcSync.RETRY)) end
		self.push = nil
		return dirty(self)
	end
	local push = self.push
	if not push then return end
	if self.hold and self.hold > t then
		local d = self.hold - t
		self.hold = nil
		return later(self, d)
	end
	local tab, ids = self.tab, {}
	for id in pairs(push) do
		if tab:Sendable(id) then ids[#ids + 1] = id else push[id] = nil end
	end
	if #ids == 0 then return end
	sort(ids)
	local rot = floor(self.a.random() * #ids)
	if self.cursor then
		rot = 0
		for i, id in ipairs(ids) do
			if id > self.cursor then rot = i - 1 break end
		end
	end
	local list, sent, since, bytes = {}, {}, {}, 0
	for i = 1, #ids do
		local id = ids[(i - 1 + rot) % #ids + 1]
		local b = sheetSize(self, id)
		if bytes > 0 and bytes + b > NpcSync.NU_FILL then break end
		list[#list + 1], sent[#sent + 1] = ns.NpcData.Pack(id, tab:Sendable(id)), id
		since[id] = push[id].since or t
		bytes = bytes + b
		push[id] = nil
		self.cursor = id
	end
	if not next(push) then self.cursor = nil end
	self.sending = true
	self.lastData = t
	openRound(self).had = true
	settle(self)
	-- an error in transmit (the encoding) must not leave sending set: no NU would go out again
	local fine, err = pcall(transmit, self, "NU", { x = list }, function(ok, size)
		if not ok then
			-- rules 7 and 10: the sheets go back and are tried again until WAIT seconds after their
			-- first attempt; then they are dropped and an ND brings them later
			self.sending = false
			local at, dropped = now(self), false
			for _, id in ipairs(sent) do
				if at - since[id] < NpcSync.WAIT then
					self.push = self.push or {}
					self.push[id] = self.push[id] or { since = since[id] }
				else
					dropped = true
					self.stats.dropped = self.stats.dropped + 1
				end
			end
			if dropped then dirty(self) end
			if self.push and next(self.push) then return later(self, rnd(self, NpcSync.RETRY)) end
			return
		end
		after(self, ceil(size / NpcSync.PART), function() step(self) end)
	end)
	if not fine then
		self.sending = false
		error(err, 0)
	end
end

local function plan(self, h)
	local p = pairOf(self, h)
	if muted(p) then
		self.stats.muted = self.stats.muted + 1
		return
	end
	if self.plan then
		self.plan.h = h
		return
	end
	local P = { h = h, t0 = now(self) }
	self.plan = P
	local function try()
		if self.plan ~= P then return end
		if not canSend(self) then
			self.plan = nil
			return dirty(self)
		end
		local tab = self.tab
		local H = tab:Hash()
		if P.h == H then
			self.plan = nil
			return
		end
		local t = now(self)
		local q = t - self.lastData
		if q < NpcSync.QUIET and t - P.t0 <= NpcSync.NI_WAIT then
			return after(self, NpcSync.QUIET - q + self.a.random() * NpcSync.NI_JITTER, try)
		end
		if t - self.lastNI < NpcSync.NI_GAP then
			return after(self, NpcSync.NI_GAP - (t - self.lastNI) + 0.01, try)
		end
		self.plan = nil
		self.lastNI, self.lastData = t, t
		local pr = pairOf(self, P.h)
		pr.n = pr.n + 1
		local salt = floor(self.a.random() * 65536)
		local hashes, ids, n = {}, {}, 0
		for _, id in ipairs(tab:SendableIDs()) do
			hashes[id], n = tab:SaltedHash(tab:SheetHash(id), salt), n + 1
		end
		-- refused sheets, newest first, only while receivers read the list (MAX_LIST IDs)
		local rl = self.refusedList
		for i = #rl, 1, -1 do
			if n >= NpcSync.MAX_LIST then break end
			local id = rl[i]
			if not hashes[id] then hashes[id], n = tab:SaltedHash(self.refused[id], salt), n + 1 end
		end
		for id in pairs(hashes) do ids[#ids + 1] = id end
		sort(ids)
		local c = {}
		for i, id in ipairs(ids) do c[i] = hashes[id] end
		local R = openRound(self)
		R.ni, R.mine, R.hNI = true, true, H
		transmit(self, "NI", { r = salt, i = toDeltas(ids), c = c }, function(ok, _, blocked)
			if not ok then
				self.lastNI = -1e9
				pr.n = pr.n - 1
				self.round = nil
				if blocked then dirty(self) end
			end
		end)
		settle(self)
	end
	after(self, rnd(self, NpcSync.NI_DELAY), try)
end

-- Receiving ------------------------------------------------------------------

local function onND(self, sender, h)
	local t = now(self)
	local seen = self.ndSeen[sender]
	if not seen or t - seen[1] > 60 then
		seen = { t, 0 }
		self.ndSeen[sender] = seen
	end
	seen[2] = seen[2] + 1
	if seen[2] > NpcSync.ND_PER_MINUTE then
		self.stats.capped = self.stats.capped + 1
		return
	end
	self.eqND[h] = t
	if h ~= self.tab:Hash() then
		self.foreign[h] = t
		plan(self, h)
	end
end

local function onNI(self, sender, h, salt, ids, c)
	local t = now(self)
	if t - (self.niSeen[sender] or -1e9) < NpcSync.NI_EVERY then
		self.stats.capped = self.stats.capped + 1
		return
	end
	self.niSeen[sender] = t
	self.lastData = t
	self.plan = nil
	local R = openRound(self)
	R.ni, R.hNI = true, h
	local tab = self.tab
	if h ~= tab:Hash() then self.foreign[h] = t end
	local held = {}
	for i, id in ipairs(ids) do held[id] = c[i] end
	local give = {}
	for _, id in ipairs(tab:SendableIDs()) do
		local their = held[id]
		if not their or their ~= tab:SaltedHash(tab:SheetHash(id), salt) then
			local x = contentKey(self, id)
			local byName = count(self, sender .. ":" .. x)
			local byHash = count(self, "H" .. h .. ":" .. x)
			if byName and byHash then give[#give + 1] = id else self.stats.capped = self.stats.capped + 1 end
		end
	end
	local miss, lack = {}, false
	for id in pairs(held) do
		if not tab:Sendable(id) and not self.refused[id] then miss[id], lack = true, true end
	end
	if #give > 0 then
		local push = self.push or {}
		for _, id in ipairs(give) do push[id] = { who = sender } end
		self.push = push
		if not self.sending then later(self, rnd(self, NpcSync.NU_DELAY)) end
	end
	if lack then
		self.missing = miss
		after(self, rnd(self, NpcSync.NR_DELAY), function()
			if self.missing ~= miss then return end
			if not canSend(self) then return dirty(self) end
			local q = {}
			for id in pairs(miss) do q[#q + 1] = id end
			sort(q)
			local list = self.nrHeard[sender] or {}
			local n, at = 0, now(self)
			for _, x in ipairs(list) do if at - x < NpcSync.HOUR then n = n + 1 end end
			if n >= NpcSync.NR_CAP then
				self.stats.capped = self.stats.capped + 1
				if #q > 0 and self.round then self.round.had = true end -- rule 6: not counted
				return
			end
			if #q == 0 then return end
			list[#list + 1] = at
			self.nrHeard[sender] = list
			self.lastData = at
			openRound(self).had = true
			transmit(self, "NR", { to = sender, i = toDeltas(q) }, function(ok, _, blocked)
				if not ok then
					for i = #list, 1, -1 do
						if list[i] == at then table.remove(list, i) break end
					end
					if blocked then dirty(self) end
				end
			end)
			settle(self)
		end)
	end
	settle(self)
end

local function onNR(self, sender, h, to, ids)
	local t = now(self)
	self.lastData = t
	openRound(self).had = true
	local tab = self.tab
	local mine = self.a.isMe(to)
	if not mine then
		for _, id in ipairs(ids) do
			if tab:Sendable(id) then count(self, sender .. ":" .. contentKey(self, id)) end
		end
	end
	local list = self.nrHeard[to] or {}
	list[#list + 1] = t
	self.nrHeard[to] = list
	if mine then
		local push = self.push or {}
		for _, id in ipairs(ids) do
			if tab:Sendable(id) and count(self, sender .. ":" .. contentKey(self, id)) then
				push[id] = {}
			end
		end
		self.push = push
		if next(push) and not self.sending then later(self, NpcSync.ANSWER_DELAY) end
	elseif self.missing then
		for _, id in ipairs(ids) do self.missing[id] = nil end
	end
	settle(self)
end

local function remember(self, id, h)
	local list = self.refusedList
	for i = #list, 1, -1 do
		if list[i] == id then table.remove(list, i) end
	end
	list[#list + 1] = id
	self.refused[id] = h
	if #list > NpcSync.REFUSED then self.refused[table.remove(list, 1)] = nil end
end

local function onNU(self, sender, h, x)
	local t = now(self)
	self.lastData = t
	local R = openRound(self)
	R.had = true
	local tab = self.tab
	local today, useful, changedAny = tab:Today(), false, false
	for i = 1, #x do
		local id, s, sh = unpackSheet(x[i], today)
		if s then
			local changed, taken
			if tab:SheetHash(id) == sh then
				changed, taken = false, true
			else
				changed, taken = tab:MergeIn(id, s)
			end
			if changed then changedAny = true end
			if not taken then remember(self, id, sh) end
			local ours = tab:SheetHash(id)
			if self.push and self.push[id] and ours == sh then
				useful = true
				self.push[id] = nil
			end
			if self.missing then self.missing[id] = nil end
			if R.mine and taken and ours and ours ~= sh then
				-- rule 4: the NI sender's merged sheet adds to the received one; once per round
				R.echo = R.echo or {}
				if not R.echo[id] then
					R.echo[id] = true
					self.push = self.push or {}
					self.push[id] = {}
					if not self.sending then later(self, rnd(self, NpcSync.ECHO_DELAY)) end
				end
			end
		end
	end
	if useful and self.push and next(self.push) then
		if not self.sending then later(self, rnd(self, NpcSync.POSTPONE)) else self.hold = t + rnd(self, NpcSync.POSTPONE) end
	end
	if changedAny and self.a.changed then self.a.changed() end
	settle(self)
end

function Sync:OnMessage(msg, sender, size)
	if self.dead or type(msg) ~= "table" or type(sender) ~= "string" or #sender > NpcSync.MAX_NAME then return end
	local NpcData = ns.NpcData
	if msg.pv ~= NpcData.PROTOCOL or msg.e ~= NpcData.EPOCH or msg.f ~= self.a.faction() then
		self.stats.foreign = self.stats.foreign + 1
		return
	end
	if self.a.isMe(sender) then return end
	local h, t = msg.h, msg.t
	if not int(h, 0, M - 1) then
		self.stats.bad = self.stats.bad + 1
		return
	end
	local parsed
	if t == "ND" then
		parsed = int(msg.n, 0, NpcData.LIMIT_SHEETS)
	elseif t == "NI" then
		local ids, c = fromDeltas(msg.i), msg.c
		parsed = ids and int(msg.r, 0, 65535) and sequence(c, NpcSync.MAX_LIST) == #ids
		if parsed then
			for i = 1, #ids do
				if not int(c[i], 0, 65535) then parsed = false break end
			end
		end
		if parsed then parsed = { ids, c } end
	elseif t == "NR" then
		local ids = fromDeltas(msg.i)
		parsed = ids and type(msg.to) == "string" and #msg.to <= NpcSync.MAX_NAME and ids
	elseif t == "NU" then
		local n = sequence(msg.x, NpcSync.MAX_LIST)
		parsed = n ~= nil
		for i = 1, n or 0 do
			if type(msg.x[i]) ~= "table" then parsed = false break end
		end
	end
	if not parsed then
		self.stats.bad = self.stats.bad + 1
		return
	end
	self.stats.recv[t] = (self.stats.recv[t] or 0) + 1
	prune(self)
	-- rule 3: what was planned for the sender is dropped once its hash is ours
	if self.push and h == self.tab:Hash() then
		for id, q in pairs(self.push) do
			if q.who == sender then self.push[id] = nil end
		end
	end
	if t == "ND" then
		onND(self, sender, h)
	elseif t == "NI" then
		onNI(self, sender, h, msg.r, parsed[1], parsed[2])
	elseif t == "NR" then
		onNR(self, sender, h, msg.to, parsed)
	else
		onNU(self, sender, h, msg.x)
	end
end

-- Public ---------------------------------------------------------------------

-- A hello (login and periodic): ND after HELLO_DELAY unless an equal one was heard.
function Sync:Announce()
	if self.dead then return end
	after(self, NpcSync.HELLO_DELAY, function()
		if not equalHeard(self, NpcSync.HELLO_EQUAL) then sendND(self) end
	end)
end

-- Rule 8: an own reading; its changed sheet goes out whole after VISIT_DELAY, waiting like an NU
-- while blocked. Returns whether the table changed.
function Sync:OwnVisit(id, reading)
	if self.dead then return false end
	local tab = self.tab
	local old = tab:Hash()
	if not tab:OwnVisit(id, reading) then return false end
	if self.a.changed then self.a.changed() end
	if tab:Hash() == old then return true end
	local since
	local function go()
		local t = now(self)
		since = since or t -- rule 7: WAIT seconds from the first attempt, blocked or failed
		if t - since >= NpcSync.WAIT then
			self.stats.dropped = self.stats.dropped + 1
			return dirty(self)
		end
		if not canSend(self) then return after(self, rnd(self, NpcSync.RETRY), go) end
		local s = tab:Sendable(id)
		if not s then return end
		self.lastData = t
		if not self.round then self.round = { h0 = old, had = false } end
		transmit(self, "NU", { x = { ns.NpcData.Pack(id, s) } }, function(ok)
			if not ok then after(self, rnd(self, NpcSync.RETRY), go) end
		end)
		settle(self)
	end
	after(self, NpcSync.VISIT_DELAY, go)
	return true
end

function Sync:Stop()
	self.dead = true
	self.push, self.plan, self.missing = nil, nil, nil
end
