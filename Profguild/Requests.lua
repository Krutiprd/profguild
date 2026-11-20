-- Profguild: Requests
-- Item requests inside the guild: a guildmate asks for something to be crafted, another one takes
-- it ("Vyrobím to"), gives it back or marks it done. The guild charges no fees, so a request only
-- carries the recipe, the crafted item, a count and a short note.
--
-- A request: { id, by = requester guid, r = recipeID, i = itemID (0 none), n = count, note,
--   c = created (server time), st = "open" | "taken" | "done" | "cancelled",
--   cr = crafter guid, tk = time of the take, g = { { tk, cr }, ... } takes given back (newest
--   last, at most MAX_GIVEN), u = time of the last change, ub = guid of the last change }
--
-- Who may change what: the requester creates and cancels (also a taken one); anybody but the
-- requester takes an open one; the crafter gives it back (open again) or marks it done, the
-- requester may mark it done too. Done and cancelled are final.
--
-- Versions of one request meet in any order on different clients, so the merge decides by the
-- request's history, the same way everywhere:
--   * of two different takes the earlier one wins (time of the take, then the lower guid), even
--     when its change is older; a take that was given back (listed in g) never comes back;
--   * a cancel by the requester wins over every state that is not final; of two final states the
--     earlier one wins;
--   * otherwise the newer change wins.
-- The sender of a message is not proven (as everywhere in Profguild): only the shape of a record
-- and its history are checked.
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
Requests.MAX_GIVEN = 5           -- given-back takes remembered
Requests.KEEP_OPEN = 7 * 86400   -- open and taken requests disappear this long after creation
Requests.KEEP_FINAL = 2 * 86400  -- done and cancelled ones this long after their last change
Requests.MAX_AHEAD = 120         -- times may be this far ahead of our clock
Requests.MAX_ID = 2147483647

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

local function copyGiven(g)
	local out = {}
	for i, t in ipairs(g or {}) do out[i] = { t[1], t[2] } end
	return out
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

-- The take a record rests on: time and crafter, or nil.
local function takeOf(rec)
	if rec.cr and rec.tk then return rec.tk, rec.cr end
end

local function earlier(t1, c1, t2, c2)
	return t1 < t2 or (t1 == t2 and c1 < c2)
end

local function given(rec, tk, cr)
	for _, t in ipairs(rec.g or {}) do
		if t[1] == tk and t[2] == cr then return true end
	end
	return false
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
	if rec.g ~= nil then
		if type(rec.g) ~= "table" or #rec.g > Requests.MAX_GIVEN then return false end
		for _, t in ipairs(rec.g) do
			if type(t) ~= "table" or not validInt(t[1]) or not validGuid(t[2]) then return false end
		end
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
	-- open: created by the requester, or given back by the crafter of the last given-back take
	if hasTake then return false end
	local last = rec.g and rec.g[#rec.g]
	return rec.ub == rec.by or (last ~= nil and rec.ub == last[2])
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

local function openCount(self, by)
	local n = 0
	for _, rec in pairs(self.list) do
		if rec.by == by and not FINAL[rec.st] then n = n + 1 end
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

-- Decides whether an incoming version replaces the one held (see the top of the file).
local function wins(held, inc)
	if inc.u == held.u and inc.st == held.st and inc.cr == held.cr and inc.tk == held.tk then return false end
	if FINAL[held.st] then
		if not FINAL[inc.st] then return false end
		return inc.u < held.u or (inc.u == held.u and inc.st < held.st)
	end
	if inc.st == "cancelled" then return true end
	local tIn, cIn = takeOf(inc)
	local tH, cH = takeOf(held)
	if tIn and given(held, tIn, cIn) then return false end -- a take that was given back
	if held.st == "taken" then
		if tIn then
			if tIn == tH and cIn == cH then return FINAL[inc.st] or inc.u > held.u end
			if given(inc, tH, cH) then return true end -- our take was given back meanwhile
			return earlier(tIn, cIn, tH, cH)
		end
		-- open again: the give-back of our take, or of an earlier take than ours
		if given(inc, tH, cH) then return true end
		local last = inc.g and inc.g[#inc.g]
		return last ~= nil and earlier(last[1], last[2], tH, cH)
	end
	-- held open
	if tIn then return true end
	local gi, gh = #(inc.g or {}), #(held.g or {})
	return gi > gh or (gi == gh and inc.u > held.u)
end

local function shallow(rec)
	local out = {}
	for k, v in pairs(rec) do out[k] = v end
	out.g = rec.g and copyGiven(rec.g) or nil
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
	if not wins(held, rec) then return false end
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

-- A new request of ours. Returns the record, or nil and "invalid" / "limit".
function RequestsMT:Create(recipeID, itemID, n, note)
	local me = self.a.myGuid()
	note = type(note) == "string" and cut(note:gsub("^%s+", ""):gsub("%s+$", ""), Requests.MAX_NOTE) or ""
	if not validID(recipeID) or not (itemID == 0 or validID(itemID)) then return nil, "invalid" end
	if type(n) ~= "number" or n < 1 or n > Requests.MAX_COUNT or n ~= math.floor(n) then return nil, "invalid" end
	if openCount(self, me) >= Requests.MAX_OPEN then return nil, "limit" end
	if count(self) >= Requests.MAX_RECORDS then
		self:Prune()
		if count(self) >= Requests.MAX_RECORDS then return nil, "limit" end
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
	local new = shallow(rec)
	new.g = new.g or {}
	new.g[#new.g + 1] = { rec.tk, rec.cr }
	while #new.g > Requests.MAX_GIVEN do table.remove(new.g, 1) end
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

-- The guild changed: this object stops sending (its timers may still run).
function RequestsMT:Stop()
	self.dead = true
end

return Requests
