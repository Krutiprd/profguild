-- Profguild: NpcWork
-- One scheduler for all NPC work (loading the tables, merging received sheets, expiry, the
-- messages of NpcSync), so that none of it holds up a frame of the game. Jobs run one after the
-- other in the order they came, each in a coroutine, in slices of at most a time budget per frame.
-- Pure: no WoW API, the adapter gives the clock and the next frame.
--
-- Adapter: clock() -> milliseconds (high resolution, only differences are used),
--          frame() -> a value that changes from one frame to the next (GetTime() in the game),
--          defer(fn) runs fn in a later frame, budget() -> milliseconds this frame may spend,
--          error(err, stack) records an error of a job (the job is dropped, the others go on),
--          rate (optional): milliseconds of one unit of work of every kind, fixed (tests: a
--          deterministic cost model); without it each kind starts at RATES[kind] and learns.
--
-- work:Run(fn[, owner[, fail]]) queues fn as a job behind the jobs queued before it (fail(err) runs
--   when it ends in an error). When nothing waits
--   ahead of it and the frame has budget left it starts at once, in the caller's frame; small work
--   is then done before Run returns, as without a scheduler.
-- work:Pace(units[, kind]) is called by a job before an item of about `units` units of work of a
--   kind (a sheet entry is one; kinds: RATES). When the item would take the frame past its budget,
--   the job waits for the next frame first; the first slice of a frame does at least one item.
--   Outside a job it does nothing. No pcall may stand between a job and its Pace (PUC Lua 5.1
--   cannot yield across it). The time an item took (the clock from its Pace to the next) teaches
--   the estimate of its kind: ms per unit, quick to rise, slow to fall, never under RATES[kind].
-- work:InJob(): the caller runs inside a job (then everything it does is in order already).
-- work:Busy([owner]): jobs are queued or half done (of that owner).
-- work:Flush(): runs every job to its end now, whatever the budget (logout: the game is leaving).
-- work:Flushing(): Flush is running (inbound network data may then be dropped: see NpcSync, Comm).
-- work:Watch(obj): obj:Settle() runs at the start of every job, before the job's own code (an NPC
--   table expires there when the day changed): a job never sees the table change under it but by
--   its own work, and it keeps the day it started with (weak: a table no longer used goes).
--
-- Jobs never run at the same time: between two slices of a job only reads happen (the window),
-- every change of the NPC tables is made by a job. A read never changes a table (a new day is
-- settled at the start of the next job).

local _, ns = ...
ns = ns or {}

local NpcWork = {}
ns.NpcWork = NpcWork

NpcWork.BUDGET = 4      -- ms per frame; one item may go past it (the largest, a sheet, about 1-2 ms)
NpcWork.COMBAT = 3      -- ms per frame in combat
NpcWork.RATE = 0.003    -- estimated ms per unit under PUC Lua 5.1 of a kind not in RATES
-- ms per unit of each kind of item under PUC Lua 5.1 with its garbage collector, measured with full
-- tables (tests/bench_npc.py and the review harness): the start and the floor of what is learned
NpcWork.RATES = {
	load = 0.003,     -- an entry of a saved sheet unpacked and trimmed
	scan = 0.002,     -- an entry offered to the limits' heap
	check = 0.0002,   -- an entry looked at (the import's precheck, what a merge took, a copy)
	merge = 0.002,    -- an entry merged (the import)
	room = 0.002,     -- an entry made room for and compared (the import)
	mergeput = 0.003, -- an entry of a received sheet or own reading checked and merged
	pack = 0.001,     -- an entry of a sheet packed for saved
	cut = 0.0015,     -- an entry of a sheet cut to its sendable part and hashed
	index = 0.001,    -- an entry of a sheet indexed and counted
	group = 0.002,    -- an entry the limits drop, grouped by sheet
	store = 0.0035,   -- an entry of a sheet expired and stored at once (Expire)
	unpack = 0.003,   -- an entry of a received sheet unpacked and hashed
	hash = 0.001,     -- half a sheet's salted hash compared (NI)
	encode = 0.006,   -- a byte of a message encoded (serialize and deflate)
	text = 0.0001,    -- a character of a received text decoded to bytes (Comm)
	inflate = 0.0007, -- a symbol inflated (NpcInflate: units of symbols and bytes)
	deserialize = 0.0004, -- a value deserialized (LibSerialize)
}
local RISE, FALL, JUMP = 0.5, 0.05, 4 -- learning: weights up and down, at most JUMP times at once

local create, resume, yield, running, status = coroutine.create, coroutine.resume, coroutine.yield,
	coroutine.running, coroutine.status

local Work = {}
Work.__index = Work

function NpcWork.New(adapter)
	return setmetatable({ a = adapter, q = {}, cur = nil, slicing = false, deferred = false,
		frame = nil, spent = 0, t0 = 0, left = 0, items = 0, est = 0, unlimited = false,
		rate = adapter.rate, rates = {}, item = nil, watched = setmetatable({}, { __mode = "k" }),
		stats = { jobs = 0, slices = 0, maxMs = 0, errors = 0 } }, Work)
end

-- A later frame runs the next slice (one request at a time).
local function later(self)
	if self.deferred then return end
	self.deferred = true
	self.a.defer(function()
		self.deferred = false
		self:slice()
	end)
end

-- Runs jobs while this frame has budget: the head job is resumed until it yields (its next item
-- would pass the budget) or ends, then the next one starts.
function Work:slice()
	if self.slicing then return end
	local a = self.a
	local f = a.frame()
	if f ~= self.frame then self.frame, self.spent = f, 0 end
	local left = self.unlimited and math.huge or (a.budget() - self.spent)
	if left <= 0 then return later(self) end
	self.slicing = true
	local t0 = a.clock()
	-- the first slice of a frame does one item at least; a later one (a job queued after the frame
	-- spent some of its budget) only what fits
	self.t0, self.left, self.items, self.est = t0, left, self.spent > 0 and 1 or 0, 0
	local q = self.q
	while q[1] do
		local job = q[1]
		if not job.co then
			local fn = job.fn
			job.co = create(function()
				self:settle()
				return fn()
			end)
		end
		self.cur = job
		local ok, err = resume(job.co)
		self.cur, self.item = nil, nil
		if not ok then
			table.remove(q, 1)
			self.stats.errors = self.stats.errors + 1
			local stack = debug and debug.traceback and debug.traceback(job.co, tostring(err)) or nil
			if a.error then pcall(a.error, err, stack) end
			if job.fail then pcall(job.fail, err) end
		elseif status(job.co) == "dead" then
			table.remove(q, 1)
		else
			break -- waits for the next frame
		end
		if a.clock() - t0 >= left then break end
	end
	local ms = a.clock() - t0
	self.spent = self.spent + ms
	local st = self.stats
	st.slices = st.slices + 1
	if ms > st.maxMs then st.maxMs = ms end
	if self.onSlice then self.onSlice(ms) end
	self.slicing = false
	if q[1] and not self.unlimited then later(self) end
end

function Work:Watch(obj) self.watched[obj] = true end

-- At the start of a job, inside its coroutine (it may pace): every watched object settles (the
-- list is taken first: a table made in a window between two slices may be added meanwhile). Each
-- Settle runs in a coroutine of its own (self.sub, where Pace works as in the job): an error in it
-- is recorded and the job's own code still runs (a job that never ran would leave its queue
-- counters up); obj:SettleFailed() lets the object go past what failed.
function Work:settle()
	local list = {}
	for obj in pairs(self.watched) do list[#list + 1] = obj end
	for i = 1, #list do
		local obj = list[i]
		local co = create(function() obj:Settle() end)
		self.sub = co
		local ok, err = resume(co)
		while ok and status(co) == "suspended" do
			-- its Pace waits for the next frame: the job waits with it
			self.sub = nil
			yield()
			self.sub = co
			ok, err = resume(co)
		end
		self.sub = nil
		if not ok then
			self.stats.errors = self.stats.errors + 1
			local a = self.a
			local stack = debug and debug.traceback and debug.traceback(co, tostring(err)) or nil
			if a.error then pcall(a.error, err, stack) end
			if obj.SettleFailed then pcall(obj.SettleFailed, obj, err) end
		end
	end
end

function Work:Flushing() return self.unlimited end

function Work:Run(fn, owner, fail)
	self.q[#self.q + 1] = { fn = fn, owner = owner, fail = fail }
	self.stats.jobs = self.stats.jobs + 1
	if not self.slicing then self:slice() end
end

function Work:InJob()
	local job = self.cur
	if job == nil then return false end
	local co = running()
	return co == job.co or (co ~= nil and co == self.sub)
end

-- ms per unit of a kind: fixed by the adapter, else learned (never under RATES[kind]).
function Work:Rate(kind)
	if self.rate then return self.rate end
	return self.rates[kind] or NpcWork.RATES[kind] or NpcWork.RATE
end

function Work:learn(kind, units, ms)
	if self.rate or self.unlimited or ms < 0 then return end
	local base = NpcWork.RATES[kind] or NpcWork.RATE
	local cur = self.rates[kind] or base
	local r = ms / units
	if r > cur then
		if r > cur * JUMP then r = cur * JUMP end -- one pause of the garbage collector teaches little
		cur = cur + (r - cur) * RISE
	else
		cur = cur + (r - cur) * FALL
	end
	if cur < base then cur = base end
	self.rates[kind] = cur
end

function Work:Pace(units, kind)
	local job = self.cur
	if not job or self.unlimited then return end
	local co = running()
	if co ~= job.co and (co == nil or co ~= self.sub) then return end
	units = units or 1
	kind = kind or "other"
	local a = self.a
	-- the item before (in this slice): its time teaches the estimate of its kind
	local it = self.item
	if it then self:learn(it[1], it[2], a.clock() - it[3]) end
	self.item = nil
	-- checked again after the wait: the job may be resumed in a later slice of a frame that has
	-- spent part of its budget
	-- the time of the slice so far: measured, or the estimate of its items when more (a clock
	-- that stands still, as in tests, or one coarser than an item)
	local cost = units * self:Rate(kind)
	while self.items > 0 and not self.unlimited do
		local used = a.clock() - self.t0
		if self.est > used then used = self.est end
		if used + cost <= self.left then break end
		yield()
	end
	self.items = self.items + 1
	self.est = self.est + cost
	if units > 0 then self.item = { kind, units, a.clock() } end
	if a.spend then a.spend(units) end
end

function Work:Busy(owner)
	if owner == nil then return self.q[1] ~= nil end
	for _, job in ipairs(self.q) do
		if job.owner == owner then return true end
	end
	return false
end

function Work:Flush()
	if self.slicing then return end
	self.unlimited = true
	local guard = 0
	while self.q[1] and guard < 100000 do
		guard = guard + 1
		self:slice()
	end
	self.unlimited = false
end

-- For callers that may run without a scheduler (tests, the simulation): pace when there is one.
function NpcWork.Pace(work, units, kind)
	if work then work:Pace(units, kind) end
end
