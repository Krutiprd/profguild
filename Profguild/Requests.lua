-- Profguild: Requests
-- Item requests inside the guild: a guildmate asks for something to be crafted, another one takes
-- it ("Vyrobím to"), gives it back or marks it done. The guild charges no fees, so a request only
-- carries the recipe, the crafted item, a count and a short note.
--
-- A request: { id, by = requester guid, r = recipeID, i = itemID (0 none), n = count, note,
--   c = created (server time), st = "open" | "taken" | "done" | "cancelled",
--   cr = crafter guid, tk = time of the take, gn = how many times it was given back (generation),
--   u = time of the last change, ub = guid of the last change }
--
-- Who may change what: the requester creates and cancels (also a taken one); anybody but the
-- requester takes an open one; the crafter gives it back (open again) or marks it done, the
-- requester may mark it done too. Done and cancelled are final.
--
-- Versions of one request meet in any order on different clients. They are ranked by one total
-- order and the higher one is kept, so every client ends with the same version whatever the
-- order of the messages (Requests.Beats):
--   1. a final state (done, cancelled) beats any other; of two finals the earlier change wins;
--   2. otherwise the higher generation wins: a give-back starts a new one, so a take that was
--      given back can never come back;
--   3. in one generation a take beats the open state, and of two takes the earlier one wins
--      (time of the take, then the lower guid); of two open versions the later change wins.
-- A give-back by the loser of a take race, before it heard the winner, opens the request again
-- (rare, and the same everywhere). Own changes are refused while sending is blocked, so a take
-- made in a dungeon cannot win minutes later as "earlier" (UI.lua).
-- The sender of a message is not proven (as everywhere in Profguild): only the shape of a record
-- and its history are checked.
--
-- Messages (GUILD channel):
--   TU update  { t="TU", pv, s, q = { record, ... } }          our changes, and answers
--   TD digest  { t="TD", pv, s, x = { id, version, ... } }      after every hello
--   TR request { t="TR", pv, s, to = holderGuid, ids = { ... } }
-- A client that sees a digest listing a request it lacks or holds in another version asks the
-- sender for it; everybody who hears the answer merges it. A client that holds a request the
-- digest lacks, or another version, answers with its own digest (at most every DIGEST_GAP), so
-- the exchange runs both ways and a newcomer does not wait for the next hello.
--
-- Adapter: send(msg), canSend() -> bool, now() (seconds, monotonic), clock() (server time),
--          after(seconds, fn), random() -> [0,1), myGuid(), onChanged(id, what) (optional;
--          what = "new" | "taken" | "open" | "done" | "cancelled" | "gone")

local _, ns = ...
ns = ns or {}

local Requests = {}
ns.Requests = Requests

Requests.PROTOCOL = 1
Requests.MAX_OPEN = 20           -- requests not yet final per requester
Requests.MAX_RECORDS = 200       -- in the guild
Requests.MAX_COUNT = 1000
Requests.MAX_NOTE = 80           -- letters
Requests.MAX_GEN = 1000         -- give-backs of one request
Requests.KEEP_OPEN = 7 * 86400   -- open and taken requests disappear this long after creation
Requests.KEEP_FINAL = 2 * 86400  -- done and cancelled ones this long after their last change
Requests.MAX_AHEAD = 120         -- times may be this far ahead of our clock
Requests.MAX_ID = 2147483647
Requests.MAX_PER_MESSAGE = 20    -- records in one update
Requests.MAX_DIGEST = 250        -- entries read from one digest
Requests.MAX_ASK = 50            -- ids in one request
Requests.SEND_DELAY = 0.5        -- own changes right after each other leave together
Requests.SEND_PACE = 1.0         -- seconds between two parts of an update
Requests.REQUEST_DELAY = { 1.0, 4.0 }
Requests.DIGEST_DELAY = { 2.0, 6.0 }
Requests.DIGEST_GAP = 60         -- an answering digest at most this often
Requests.ANSWER_COOLDOWN = 30    -- seconds between the end of an answer and the next one
Requests.ASK_AGAIN = 60          -- the same request is asked for again (by anybody) only after this

local STATES = { open = true, taken = true, done = true, cancelled = true }
local FINAL = { done = true, cancelled = true }

local function validID(v)
	return type(v) == "number" and v >= 1 and v <= Requests.MAX_ID and v == math.floor(v)
end

local function validInt(v)
	return type(v) == "number" and v == math.floor(v) and v > 0 and v < 4294967296
end

local function validGuid(g)
	return type(g) == "string" and #g <= 40 and g:find("^Player%-") ~= nil
end

local function length(text)
	if ns.Bugs and ns.Bugs.Length then return ns.Bugs.Length(text) end
	return #text
end

local function cut(text, max)
	if ns.Bugs and ns.Bugs.Cut then return ns.Bugs.Cut(text, max) end
	return text:sub(1, max)
end

local RequestsMT = {}
RequestsMT.__index = RequestsMT

-- saved: the guild's saved table; requests live in saved.requests.
function Requests.New(adapter, saved)
	if type(saved.requests) ~= "table" then saved.requests = {} end
	local self = setmetatable({
		a = adapter,
		saved = saved,
		list = saved.requests,
		revision = 0,
		dead = false,
		outgoing = {},       -- id -> true, own changes waiting to be sent
		sendTimer = false,
		sendQueue = {},      -- updates being sent: { ids, next, answer }
		pumping = false,
		answerIds = nil,     -- id -> true, asked for while the answer waits
		answerTimer = false,
		answering = false,
		lastAnswer = -1e9,
		requests = {},       -- holder guid -> { ids = { id -> true }, token }
		requestSeq = 0,
		asked = {},          -- id -> time it was asked for (by us or a guildmate we heard)
		digestTimer = false,
		digestCovered = false,
		lastDigest = -1e9,
		stats = { sentU = 0, sentD = 0, sentR = 0, recvU = 0, recvD = 0, recvR = 0 },
	}, RequestsMT)
	for id, rec in pairs(self.list) do
		if not self:_Valid(rec) or rec.id ~= id then self.list[id] = nil end -- broken saved data
	end
	return self
end

local function changed(self, id, what)
	self.revision = self.revision + 1
	if self.a.onChanged then self.a.onChanged(id, what) end
end

-- Ranks two versions of the same request (see the top of the file): true when a beats b.
-- Every field that can change takes part, so two different versions never tie.
local function less(x, y)
	if x ~= y then return x < y end
	return nil
end

function Requests.Beats(a, b)
	local fa, fb = FINAL[a.st] and 1 or 0, FINAL[b.st] and 1 or 0
	if fa ~= fb then return fa > fb end
	local r
	if fa == 1 then
		-- two finals: the earlier decision
		r = less(a.u, b.u); if r ~= nil then return r end
		r = less(a.st, b.st); if r ~= nil then return r end
	else
		r = less(b.gn or 0, a.gn or 0); if r ~= nil then return r end
		local ta, tb = a.st == "taken" and 1 or 0, b.st == "taken" and 1 or 0
		if ta ~= tb then return ta > tb end
		if ta == 1 then
			r = less(a.tk, b.tk); if r ~= nil then return r end -- the earlier take
			r = less(a.cr, b.cr); if r ~= nil then return r end
		end
		r = less(b.u, a.u); if r ~= nil then return r end -- open: the later change
	end
	r = less(b.cr or "", a.cr or ""); if r ~= nil then return r end
	r = less(b.tk or 0, a.tk or 0); if r ~= nil then return r end
	r = less(b.gn or 0, a.gn or 0); if r ~= nil then return r end
	r = less(b.u, a.u); if r ~= nil then return r end
	r = less(b.ub, a.ub); if r ~= nil then return r end
	return false -- the same version
end

-- True when the record is past its time.
function RequestsMT:_Expired(rec, clock)
	clock = clock or self.a.clock()
	if FINAL[rec.st] then return rec.u < clock - Requests.KEEP_FINAL end
	return rec.c < clock - Requests.KEEP_OPEN
end

-- Checks the shape of a record and who made its last change.
function RequestsMT:_Valid(rec)
	if type(rec) ~= "table" or type(rec.id) ~= "string" or #rec.id > 80 then return false end
	if not validGuid(rec.by) or rec.id:sub(1, #rec.by + 1) ~= rec.by .. "-" then return false end
	if not validID(rec.r) or not (rec.i == 0 or validID(rec.i)) then return false end
	if type(rec.n) ~= "number" or rec.n < 1 or rec.n > Requests.MAX_COUNT or rec.n ~= math.floor(rec.n) then return false end
	if type(rec.note) ~= "string" or #rec.note > Requests.MAX_NOTE * 4 or length(rec.note) > Requests.MAX_NOTE then return false end
	if not STATES[rec.st] or not validInt(rec.c) or not validInt(rec.u) or rec.u < rec.c then return false end
	if rec.u > self.a.clock() + Requests.MAX_AHEAD or not validGuid(rec.ub) then return false end
	if rec.gn ~= nil and (type(rec.gn) ~= "number" or rec.gn < 0 or rec.gn > Requests.MAX_GEN or rec.gn ~= math.floor(rec.gn)) then
		return false
	end
	local hasTake = rec.cr ~= nil or rec.tk ~= nil
	if hasTake and (not validGuid(rec.cr) or rec.cr == rec.by or not validInt(rec.tk) or rec.tk < rec.c or rec.tk > rec.u) then
		return false
	end
	if rec.st == "taken" then
		return hasTake and rec.ub == rec.cr
	elseif rec.st == "done" then
		return hasTake and (rec.ub == rec.by or rec.ub == rec.cr)
	elseif rec.st == "cancelled" then
		return rec.ub == rec.by
	end
	-- open: created by the requester, or given back by a crafter
	if hasTake then return false end
	return rec.ub == rec.by or (rec.gn or 0) > 0
end

function RequestsMT:Get(id)
	return self.list[id]
end

-- Every request: not final first, then the newest.
function RequestsMT:All()
	local out = {}
	for _, rec in pairs(self.list) do out[#out + 1] = rec end
	table.sort(out, function(x, y)
		local fx, fy = FINAL[x.st] and 1 or 0, FINAL[y.st] and 1 or 0
		if fx ~= fy then return fx < fy end
		if x.c ~= y.c then return x.c > y.c end
		return x.id < y.id
	end)
	return out
end

-- Requests of one requester that are not final and not past their time.
local function openCount(self, by)
	local n, clock = 0, self.a.clock()
	for _, rec in pairs(self.list) do
		if rec.by == by and not FINAL[rec.st] and not self:_Expired(rec, clock) then n = n + 1 end
	end
	return n
end

local function count(self)
	local n = 0
	for _ in pairs(self.list) do n = n + 1 end
	return n
end

-- Drops requests past their time. Returns how many.
function RequestsMT:Prune()
	local clock, dropped = self.a.clock(), 0
	for id, rec in pairs(self.list) do
		if self:_Expired(rec, clock) then
			self.list[id] = nil
			dropped = dropped + 1
			changed(self, id, "gone")
		end
	end
	return dropped
end

local function shallow(rec)
	local out = {}
	for k, v in pairs(rec) do out[k] = v end
	return out
end

-- Takes a version of a request heard from the guild. Returns true when it was stored.
function RequestsMT:Merge(rec)
	if not self:_Valid(rec) or self:_Expired(rec) then return false end
	local held = self.list[rec.id]
	if not held then
		if not FINAL[rec.st] and openCount(self, rec.by) >= Requests.MAX_OPEN then return false end
		if count(self) >= Requests.MAX_RECORDS then
			self:Prune()
			if count(self) >= Requests.MAX_RECORDS then return false end
		end
		self.list[rec.id] = shallow(rec)
		changed(self, rec.id, "new")
		return true
	end
	if held.by ~= rec.by or held.r ~= rec.r or held.i ~= rec.i or held.n ~= rec.n or held.note ~= rec.note
		or held.c ~= rec.c then
		return false -- what was asked for never changes
	end
	if not Requests.Beats(rec, held) then return false end
	local before = held
	self.list[rec.id] = shallow(rec)
	local what = rec.st ~= before.st and rec.st or (rec.cr ~= before.cr and "taken") or nil
	changed(self, rec.id, what)
	return true
end

-- The time of a change by us: never before the request's last change.
local function stamp(self, rec)
	local clock = math.floor(self.a.clock())
	return clock > rec.u and clock or rec.u + 1
end

-- Our own change of a request: checked like one heard from the guild, then stored and sent.
function RequestsMT:_Apply(new)
	if not self:_Valid(new) then return false, "invalid" end
	self.list[new.id] = new
	changed(self, new.id, "own")
	if self._Send then self:_Send(new) end
	return true
end

-- A new request of ours. Returns the record, or nil and "invalid" / "limit" (ours) / "full" (guild).
function RequestsMT:Create(recipeID, itemID, n, note)
	local me = self.a.myGuid()
	note = type(note) == "string" and cut(note:gsub("^%s+", ""):gsub("%s+$", ""), Requests.MAX_NOTE) or ""
	if not validID(recipeID) or not (itemID == 0 or validID(itemID)) then return nil, "invalid" end
	if type(n) ~= "number" or n < 1 or n > Requests.MAX_COUNT or n ~= math.floor(n) then return nil, "invalid" end
	if openCount(self, me) >= Requests.MAX_OPEN then return nil, "limit" end
	if count(self) >= Requests.MAX_RECORDS then
		self:Prune()
		if count(self) >= Requests.MAX_RECORDS then return nil, "full" end
	end
	local clock = math.floor(self.a.clock())
	self.saved.requestSeq = (tonumber(self.saved.requestSeq) or 0) + 1
	local rec = {
		id = me .. "-" .. clock .. "-" .. self.saved.requestSeq,
		by = me, r = recipeID, i = itemID, n = n, note = note,
		c = clock, st = "open", u = clock, ub = me,
	}
	local ok, why = self:_Apply(rec)
	if not ok then return nil, why end
	return rec
end

local function own(self, id)
	local rec = self.list[id]
	if not rec then return nil, "unknown" end
	return rec
end

function RequestsMT:Take(id)
	local rec, why = own(self, id)
	if not rec then return false, why end
	local me = self.a.myGuid()
	if rec.st ~= "open" or rec.by == me then return false, "not allowed" end
	local new = shallow(rec)
	new.st, new.cr = "taken", me
	new.u = stamp(self, rec)
	new.tk, new.ub = new.u, me
	return self:_Apply(new)
end

function RequestsMT:GiveBack(id)
	local rec, why = own(self, id)
	if not rec then return false, why end
	local me = self.a.myGuid()
	if rec.st ~= "taken" or rec.cr ~= me then return false, "not allowed" end
	if (rec.gn or 0) >= Requests.MAX_GEN then return false, "not allowed" end
	local new = shallow(rec)
	new.gn = (rec.gn or 0) + 1
	new.st, new.cr, new.tk = "open", nil, nil
	new.u, new.ub = stamp(self, rec), me
	return self:_Apply(new)
end

function RequestsMT:Done(id)
	local rec, why = own(self, id)
	if not rec then return false, why end
	local me = self.a.myGuid()
	if rec.st ~= "taken" or (me ~= rec.by and me ~= rec.cr) then return false, "not allowed" end
	local new = shallow(rec)
	new.st, new.u, new.ub = "done", stamp(self, rec), me
	return self:_Apply(new)
end

function RequestsMT:Cancel(id)
	local rec, why = own(self, id)
	if not rec then return false, why end
	local me = self.a.myGuid()
	if FINAL[rec.st] or rec.by ~= me then return false, "not allowed" end
	local new = shallow(rec)
	new.st, new.u, new.ub = "cancelled", stamp(self, rec), me
	return self:_Apply(new)
end

---------------------------------------------------------------------------
-- Keeping the guild in step
---------------------------------------------------------------------------

local function between(self, range)
	return range[1] + (range[2] - range[1]) * self.a.random()
end

local function canSend(self)
	return not self.dead and self.a.canSend()
end

local function send(self, msg)
	msg.pv = Requests.PROTOCOL
	msg.s = self.a.myGuid()
	self.a.send(msg)
end

-- What tells two versions of a request apart in a digest: every field that can change.
local function version(rec)
	return (rec.gn or 0) .. ":" .. rec.st .. ":" .. rec.u .. ":" .. (rec.tk or "") .. ":" .. (rec.cr or "") .. ":" .. rec.ub
end
Requests.Version = version

function RequestsMT:_Send(rec)
	self.outgoing[rec.id] = true
	if self.sendTimer then return end
	self.sendTimer = true
	self.a.after(Requests.SEND_DELAY, function()
		self.sendTimer = false
		local ids = {}
		for id in pairs(self.outgoing) do ids[#ids + 1] = id end
		self.outgoing = {}
		if #ids == 0 or not canSend(self) then return end -- the next digest brings it
		table.sort(ids)
		self.sendQueue[#self.sendQueue + 1] = { ids = ids, next = 1 }
		self:_Pump()
	end)
end

function RequestsMT:_AnswerSent()
	self.answering = false
	self.lastAnswer = self.a.now()
	self:_ScheduleAnswer()
end

function RequestsMT:_Pump()
	if self.pumping then return end
	local job = self.sendQueue[1]
	if not job then return end
	if not canSend(self) then
		local was = self.answering
		self.sendQueue = {}
		if was then self:_AnswerSent() end
		return
	end
	local q = {}
	while job.next <= #job.ids and #q < Requests.MAX_PER_MESSAGE do
		local rec = self.list[job.ids[job.next]]
		if rec then q[#q + 1] = rec end
		job.next = job.next + 1
	end
	local last = job.next > #job.ids
	if last then table.remove(self.sendQueue, 1) end
	if #q > 0 then
		self.stats.sentU = self.stats.sentU + 1
		send(self, { t = "TU", q = q })
	end
	if last and job.answer then self:_AnswerSent() end
	if #self.sendQueue > 0 then
		self.pumping = true
		self.a.after(Requests.SEND_PACE, function()
			self.pumping = false
			self:_Pump()
		end)
	end
end

-- Sends our digest. Called after every hello of Sync (also with no requests: a newcomer's empty
-- digest makes the holders answer at once).
function RequestsMT:Announce()
	if not canSend(self) then return false end
	local x, clock = {}, self.a.clock()
	for _, rec in ipairs(self:All()) do
		if not self:_Expired(rec, clock) and #x < 2 * Requests.MAX_DIGEST then
			x[#x + 1] = rec.id
			x[#x + 1] = version(rec)
		end
	end
	self.lastDigest = self.a.now()
	self.stats.sentD = self.stats.sentD + 1
	send(self, { t = "TD", x = x })
	return true
end

local function scheduleDigest(self)
	if self.digestTimer or self.a.now() - self.lastDigest < Requests.DIGEST_GAP then return end
	self.digestTimer = true
	self.digestCovered = false
	self.a.after(between(self, Requests.DIGEST_DELAY), function()
		self.digestTimer = false
		if self.digestCovered then return end
		if self.a.now() - self.lastDigest >= Requests.DIGEST_GAP then self:Announce() end
	end)
end

-- The asked requests: one answer at a time, ANSWER_COOLDOWN after the previous one ended.
function RequestsMT:_Answer(ids)
	self.answerIds = self.answerIds or {}
	for id in pairs(ids) do self.answerIds[id] = true end
	self:_ScheduleAnswer()
end

function RequestsMT:_ScheduleAnswer()
	if self.answerTimer or self.answering or not self.answerIds then return end
	local wait = math.max(0, Requests.ANSWER_COOLDOWN - (self.a.now() - self.lastAnswer))
	self.answerTimer = true
	self.a.after(wait, function()
		self.answerTimer = false
		local asked = self.answerIds
		self.answerIds = nil
		if not asked or not canSend(self) then return end
		local ids = {}
		for id in pairs(asked) do
			if self.list[id] then ids[#ids + 1] = id end
		end
		if #ids == 0 then return end
		table.sort(ids)
		self.answering = true
		self.sendQueue[#self.sendQueue + 1] = { ids = ids, next = 1, answer = true }
		self:_Pump()
	end)
end

-- Asks a holder for these requests (merged with others wanted from it meanwhile).
function RequestsMT:_Request(holder, ids)
	local now = self.a.now()
	local fresh = {}
	for id in pairs(ids) do
		if not self.asked[id] or now - self.asked[id] >= Requests.ASK_AGAIN then fresh[id] = true end
	end
	if not next(fresh) then return false end
	for id in pairs(fresh) do self.asked[id] = now end
	local r = self.requests[holder]
	if r then
		for id in pairs(fresh) do r.ids[id] = true end
		return true
	end
	self.requestSeq = self.requestSeq + 1
	local token = self.requestSeq
	r = { ids = fresh, token = token }
	self.requests[holder] = r
	self.a.after(between(self, Requests.REQUEST_DELAY), function()
		local req = self.requests[holder]
		if not req or req.token ~= token then return end
		self.requests[holder] = nil
		if not canSend(self) then
			for id in pairs(req.ids) do self.asked[id] = nil end
			return
		end
		local list = {}
		for id in pairs(req.ids) do
			if #list < Requests.MAX_ASK then list[#list + 1] = id end
		end
		if #list == 0 then return end -- covered by a guildmate's request
		table.sort(list)
		self.stats.sentR = self.stats.sentR + 1
		send(self, { t = "TR", to = holder, ids = list })
	end)
	return true
end

function RequestsMT:OnMessage(msg)
	if type(msg) ~= "table" or msg.pv ~= Requests.PROTOCOL then return end
	local me = self.a.myGuid()
	if msg.s == me or not validGuid(msg.s) then return end -- GUILD addon messages are echoed
	if msg.t == "TU" then
		if type(msg.q) ~= "table" then return end
		self.stats.recvU = self.stats.recvU + 1
		local stored = 0
		for i = 1, math.min(#msg.q, Requests.MAX_PER_MESSAGE) do
			if self:Merge(msg.q[i]) then stored = stored + 1 end
		end
		return stored
	elseif msg.t == "TD" then
		if type(msg.x) ~= "table" or #msg.x > 2 * Requests.MAX_DIGEST or #msg.x % 2 ~= 0 then return end
		self.stats.recvD = self.stats.recvD + 1
		local theirs, want = {}, {}
		for i = 1, #msg.x, 2 do
			local id, v = msg.x[i], msg.x[i + 1]
			if type(id) ~= "string" or #id > 80 or type(v) ~= "string" or #v > 80 then return end
			theirs[id] = v
			local held = self.list[id]
			if not held or version(held) ~= v then want[id] = true end
		end
		local differs, clock = false, self.a.clock()
		for id, rec in pairs(self.list) do
			if not self:_Expired(rec, clock) and theirs[id] ~= version(rec) then
				differs = true
				break
			end
		end
		if self.digestTimer and not differs and not next(want) then self.digestCovered = true end
		if next(want) then self:_Request(msg.s, want) end
		if differs then scheduleDigest(self) end
		return next(want) ~= nil
	elseif msg.t == "TR" then
		if not validGuid(msg.to) or type(msg.ids) ~= "table" or #msg.ids > Requests.MAX_ASK then return end
		self.stats.recvR = self.stats.recvR + 1
		local ids = {}
		for _, id in ipairs(msg.ids) do
			if type(id) == "string" and #id <= 80 then ids[id] = true end
		end
		if msg.to == me then
			if next(ids) then self:_Answer(ids) end
		else
			-- a guildmate asks for requests we want too: that answer reaches us as well
			local now = self.a.now()
			for id in pairs(ids) do self.asked[id] = now end
			for _, r in pairs(self.requests) do
				for id in pairs(ids) do r.ids[id] = nil end
			end
		end
	end
end

function RequestsMT:OnSendFailed(msg)
	if type(msg) == "table" and msg.t == "TR" and type(msg.ids) == "table" then
		for _, id in ipairs(msg.ids) do self.asked[id] = nil end
	end
end

-- The guild changed: this object stops sending (its timers may still run).
function RequestsMT:Stop()
	self.dead = true
	self.sendQueue = {}
	self.outgoing = {}
	self.requests = {}
	self.answering = false
end

return Requests
