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
--          rate (optional) -> estimated milliseconds of one unit of work (default RATE).
--
-- work:Run(fn[, owner[, fail]]) queues fn as a job behind the jobs queued before it (fail(err) runs
--   when it ends in an error). When nothing waits
--   ahead of it and the frame has budget left it starts at once, in the caller's frame; small work
--   is then done before Run returns, as without a scheduler.
-- work:Pace(units) is called by a job before an item of about `units` units of work (a sheet
--   entry is one). When the item would take the frame past its budget, the job waits for the next
--   frame first; the first slice of a frame does at least one item. Outside a job it does nothing.
--   No pcall may stand between a job and its Pace (PUC Lua 5.1 cannot yield across it).
-- work:InJob(): the caller runs inside a job (then everything it does is in order already).
-- work:Busy([owner]): jobs are queued or half done (of that owner).
-- work:Flush(): runs every job to its end now, whatever the budget (logout: the game is leaving).
--
-- Jobs never run at the same time: between two slices of a job only reads happen (the window),
-- every change of the NPC tables is made by a job.

local _, ns = ...
ns = ns or {}

local NpcWork = {}
ns.NpcWork = NpcWork

NpcWork.BUDGET = 4      -- ms per frame; one item may go past it (the largest, a sheet, about 1-2 ms)
NpcWork.COMBAT = 3      -- ms per frame in combat
NpcWork.RATE = 0.003    -- estimated ms per unit under PUC Lua 5.1 (an entry merged, packed, hashed); the
                        -- clock decides when an item takes longer, the estimate when the clock is coarse

local create, resume, yield, running, status = coroutine.create, coroutine.resume, coroutine.yield,
	coroutine.running, coroutine.status

local Work = {}
Work.__index = Work

function NpcWork.New(adapter)
	return setmetatable({ a = adapter, q = {}, cur = nil, slicing = false, deferred = false,
		frame = nil, spent = 0, t0 = 0, left = 0, items = 0, est = 0, unlimited = false,
		rate = adapter.rate or NpcWork.RATE,
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
		if not job.co then job.co = create(job.fn) end
		self.cur = job
		local ok, err = resume(job.co)
		self.cur = nil
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

function Work:Run(fn, owner, fail)
	self.q[#self.q + 1] = { fn = fn, owner = owner, fail = fail }
	self.stats.jobs = self.stats.jobs + 1
	if not self.slicing then self:slice() end
end

function Work:InJob()
	local job = self.cur
	return job ~= nil and running() == job.co
end

function Work:Pace(units)
	local job = self.cur
	if not job or running() ~= job.co or self.unlimited then return end
	units = units or 1
	-- checked again after the wait: the job may be resumed in a later slice of a frame that has
	-- spent part of its budget
	-- the time of the slice so far: measured, or the estimate of its items when more (a clock
	-- that stands still, as in tests, or one coarser than an item)
	local cost = units * self.rate
	while self.items > 0 and not self.unlimited do
		local used = self.a.clock() - self.t0
		if self.est > used then used = self.est end
		if used + cost <= self.left then break end
		yield()
	end
	self.items = self.items + 1
	self.est = self.est + cost
	if self.a.spend then self.a.spend(units) end
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
function NpcWork.Pace(work, units)
	if work then work:Pace(units) end
end
