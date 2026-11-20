-- Profguild: Reports
-- Bug reports carried through the guild to the author of the addon. A guildmate saves a report
-- (Bugs.lua); it is handed to the guild, every guildmate with Profguild keeps it (without showing
-- it) and passes it on, so it reaches a receiver even when the reporter and the receiver are never
-- online together. The receiver puts it in its inbox and marks it delivered; the mark spreads,
-- the carriers drop the text and the reporter is told.
--
-- A record: { id = by .. ":" .. t .. ":" .. n, by = reporter guid, t = time of the report (server
--   time), st = "h" (held: with who, v, text, ctx, errors, log) | "d" (delivered: no text) }
-- The time in the id keeps ids apart when a player's saved data was deleted and the numbers start
-- again. A report never changes, so two versions of one id differ only in the state, and "d"
-- beats "h". Both kinds go KEEP after t, and a held copy is refused after that too. A mark pushed
-- out by MAX_MARKS newer ones before that may let a carrier bring the text back; the receiver's
-- inbox keeps one entry per id, so the author sees it once.
--
-- Messages (GUILD channel), only when a receiver is a member of the guild:
--   BU update  { t="BU", pv, s, q = { record, ... } }        held reports (shares and answers)
--   BD digest  { t="BD", pv, s, x = { id, st, t, ... } }       after every hello
--   BR request { t="BR", pv, s, to = holderGuid, ids = { ... } }
-- A digest's marks are taken from it directly; held reports it lists that we lack are asked
-- for. A client that holds something the digest lacks, or holds it less far, answers with its own
-- digest (at most every DIGEST_GAP). The sender of a message is not proven (as everywhere in
-- Profguild): a false mark only costs a report that is not delivered.
--
-- Adapter: send(msg), canSend() -> bool, now() (seconds, monotonic), clock() (server time),
--          after(seconds, fn), random() -> [0,1), myGuid(), isReceiver() -> bool,
--          receiverInGuild() -> bool, deliver(record) (the receiver's inbox),
--          ownIds() -> { id -> true } (optional: reports of this account, also of its alts),
--          onChanged(id, what) (optional; what = "new" | "delivered" | "gone")

local _, ns = ...
ns = ns or {}

local Reports = {}
ns.Reports = Reports

Reports.PROTOCOL = 1
Reports.RECEIVERS = { -- the author's characters: name-realm, compared without case and spaces
	"Krutiprd-Whychuck", "Miestny-Whychuck", "Bubliprd-Whychuck", "Zlatan-Whychuck",
	"Fiona-Vajcak", "Bubli-Prd",
}
Reports.KEEP = 14 * 86400
Reports.MAX_AHEAD = 10           -- server time on every client: a report is never from the future
Reports.MAX_HELD = 60            -- held reports in the guild
Reports.MAX_PER_REPORTER = 10    -- held reports of one reporter
Reports.MAX_MARKS = 140          -- delivery marks (held + marks fit one digest)
Reports.MAX_TEXT = 1000          -- letters
Reports.MAX_LINES = 20           -- context lines
Reports.MAX_LOG = 15
Reports.MAX_ERRORS = 5
Reports.MAX_LINE = 200           -- characters of a context or log line
Reports.MAX_MSG = 400
Reports.MAX_STACK = 600
Reports.MAX_PER_MESSAGE = 2      -- reports in one update (the text is the bulk)
-- entries in one digest: all we hold (others' held, our own, marks)
Reports.MAX_DIGEST = Reports.MAX_HELD + Reports.MAX_PER_REPORTER + Reports.MAX_MARKS
Reports.MAX_ASK = 6              -- reports asked for at once (each a few kB)
Reports.MAX_BYTES = 6000         -- characters of one record (the text alone stays under this)
Reports.SEND_PACE = 1.0
Reports.REQUEST_DELAY = { 1.0, 4.0 }
Reports.DIGEST_DELAY = { 2.0, 6.0 }
Reports.DIGEST_GAP = 60
Reports.ANSWER_COOLDOWN = 30
Reports.ASK_AGAIN = 60

local function validGuid(g)
	return type(g) == "string" and #g <= 40 and g:find("^Player%-") ~= nil
end

local function validTime(v)
	return type(v) == "number" and v == math.floor(v) and v > 0 and v < 4294967296
end

-- The reporter of an id "<guid>:<time>:<n>", or nil.
local function reporterOf(id)
	if type(id) ~= "string" or #id > 70 then return nil end
	local by, t, n = id:match("^(Player%-[^:]+):(%d+):(%d+)$")
	if not by or #t > 10 or #n > 9 or not validGuid(by) then return nil end
	return by
end
Reports.ReporterOf = reporterOf

local function cutText(text, max)
	if ns.Bugs and ns.Bugs.Cut then return ns.Bugs.Cut(text, max) end
	return text:sub(1, max)
end

local function line(v, max)
	if type(v) ~= "string" then return nil end
	return cutText(v, max or Reports.MAX_LINE):sub(1, 4 * (max or Reports.MAX_LINE))
end

local function lines(list, max)
	local out = {}
	if type(list) ~= "table" then return out end
	for i = 1, math.min(#list, max) do
		local l = line(list[i])
		if l then out[#out + 1] = l end
	end
	return out
end

-- Only the known fields, every one limited: what a guildmate put in beyond that is not passed on.
local function clean(rec)
	if rec.st == "d" then return { id = rec.id, by = rec.by, t = rec.t, st = "d" } end
	local errors = {}
	if type(rec.errors) == "table" then
		for i = 1, math.min(#rec.errors, Reports.MAX_ERRORS) do
			local e = rec.errors[i]
			if type(e) == "table" and type(e.msg) == "string" then
				errors[#errors + 1] = {
					msg = line(e.msg, Reports.MAX_MSG),
					stack = line(e.stack, Reports.MAX_STACK),
					count = validTime(e.count) and e.count or 1,
					t = validTime(e.t) and e.t or nil,
					v = line(e.v, 20),
				}
			end
		end
	end
	local out = {
		id = rec.id, by = rec.by, t = rec.t, st = "h",
		who = line(rec.who, 60) or "?",
		v = line(rec.v, 20),
		text = type(rec.text) == "string" and cutText(rec.text, Reports.MAX_TEXT):sub(1, 4 * Reports.MAX_TEXT) or rec.text,
		ctx = lines(rec.ctx, Reports.MAX_LINES),
		errors = errors,
		log = lines(rec.log, Reports.MAX_LOG),
	}
	-- one record stays under MAX_BYTES (two fit one message): the log goes first, then the
	-- stacks, then context lines and errors from the end
	local function size()
		local n = #out.who + #(out.v or "") + (type(out.text) == "string" and #out.text or 0)
		for _, l in ipairs(out.ctx) do n = n + #l + 2 end
		for _, l in ipairs(out.log) do n = n + #l + 2 end
		for _, e in ipairs(out.errors) do n = n + #e.msg + #(e.stack or "") + 20 end
		return n
	end
	while size() > Reports.MAX_BYTES do
		if #out.log > 0 then
			table.remove(out.log)
		else
			local stacked
			for _, e in ipairs(out.errors) do
				if e.stack then stacked = e end
			end
			if stacked then
				stacked.stack = nil
			elseif #out.ctx > 0 then
				table.remove(out.ctx)
			elseif #out.errors > 0 then
				table.remove(out.errors)
			else
				break
			end
		end
	end
	return out
end

local ReportsMT = {}
ReportsMT.__index = ReportsMT

-- A test for "our own held report": this character's, or one of the account's (an alt's report
-- in the account-wide guild data is often the only copy, too).
local function ownTest(self)
	local me = self.a.myGuid()
	local ids = self.a.ownIds and self.a.ownIds() or {}
	return function(rec) return rec.st == "h" and (rec.by == me or ids[rec.id] == true) end
end

-- saved: the guild's saved table; records live in saved.reports.
function Reports.New(adapter, saved)
	if type(saved.reports) ~= "table" then saved.reports = {} end
	local self = setmetatable({
		a = adapter,
		saved = saved,
		list = saved.reports,
		dead = false,
		sendQueue = {},      -- { ids, next, answer }
		pumping = false,
		answerIds = nil,
		answerTimer = false,
		answering = false,
		lastAnswer = -1e9,
		requests = {},       -- holder guid -> { ids = { id -> true }, token }
		more = {},           -- holder guid -> { id -> true } wanted beyond MAX_ASK, asked after its answer
		requestSeq = 0,
		asked = {},
		digestTimer = false,
		digestCovered = false,
		lastDigest = -1e9,
		stats = { sentU = 0, sentD = 0, sentR = 0, recvU = 0, recvD = 0, recvR = 0 },
	}, ReportsMT)
	for id, rec in pairs(self.list) do
		if not self:_Valid(rec, true) or rec.id ~= id then self.list[id] = nil end
	end
	return self
end

-- A receiver takes the held reports already in the saved data (carried by an alt of the same
-- account in this guild, or before the character became a receiver). Called once set up.
function ReportsMT:TakeHeld()
	if not self.a.isReceiver() then return 0 end
	local held = {}
	for _, rec in pairs(self.list) do
		if rec.st == "h" then held[#held + 1] = rec end
	end
	table.sort(held, function(x, y) return x.id < y.id end)
	for _, rec in ipairs(held) do self:_Deliver(rec) end
	return #held
end

local function changed(self, id, what)
	if self.a.onChanged then self.a.onChanged(id, what) end
end

-- Checks the shape of a record (held or a mark). saved: records of our own file may be any age.
function ReportsMT:_Valid(rec, saved)
	if type(rec) ~= "table" or reporterOf(rec.id) ~= rec.by then return false end
	if not validTime(rec.t) then return false end
	if not saved and (rec.t > self.a.clock() + Reports.MAX_AHEAD or self:_Expired(rec)) then return false end
	if rec.st == "d" then return true end
	if rec.st ~= "h" or type(rec.text) ~= "string" or rec.text:find("^%s*$") then return false end
	return true
end

function ReportsMT:_Expired(rec, clock)
	return rec.t < (clock or self.a.clock()) - Reports.KEEP
end

function ReportsMT:Get(id)
	return self.list[id]
end

function ReportsMT:HeldCount()
	local n = 0
	for _, rec in pairs(self.list) do
		if rec.st == "h" then n = n + 1 end
	end
	return n
end

function ReportsMT:MarkCount()
	local n = 0
	for _, rec in pairs(self.list) do
		if rec.st == "d" then n = n + 1 end
	end
	return n
end

-- Records ordered newest first (time, then id): the order in which the limits keep them.
local function newer(x, y)
	if x.t ~= y.t then return x.t > y.t end
	return x.id > y.id
end

-- Would a record of this kind be kept, with the limits as they are now? The same answer on every
-- client that holds the same records, so a report one client drops is not asked for again. Our
-- own held reports do not count: we keep them whatever the guild holds (often the only copy).
function ReportsMT:_WouldKeep(cand)
	local total, mine, limitTotal = 0, 0, cand.st == "d" and Reports.MAX_MARKS or Reports.MAX_HELD
	local own = ownTest(self)
	for _, rec in pairs(self.list) do
		if rec.st == cand.st and rec.id ~= cand.id and newer(rec, cand) and not own(rec) then
			total = total + 1
			if cand.st == "h" and rec.by == cand.by then mine = mine + 1 end
		end
	end
	if total >= limitTotal then return false end
	return cand.st == "d" or mine < Reports.MAX_PER_REPORTER
end

-- Drops the oldest records over the limits.
function ReportsMT:_Trim()
	local held, marks = {}, {}
	for _, rec in pairs(self.list) do
		if rec.st == "h" then held[#held + 1] = rec else marks[#marks + 1] = rec end
	end
	table.sort(held, newer)
	table.sort(marks, newer)
	local per, kept, own = {}, 0, ownTest(self)
	for _, rec in ipairs(held) do
		per[rec.by] = (per[rec.by] or 0) + 1
		if own(rec) then
			-- ours: kept until delivered or old (MAX_PER_REPORTER still holds for us)
			if per[rec.by] > Reports.MAX_PER_REPORTER then
				self.list[rec.id] = nil
				changed(self, rec.id, "gone")
			end
		elseif per[rec.by] > Reports.MAX_PER_REPORTER or kept >= Reports.MAX_HELD then
			self.list[rec.id] = nil
			changed(self, rec.id, "gone")
		else
			kept = kept + 1
		end
	end
	for i = Reports.MAX_MARKS + 1, #marks do
		self.list[marks[i].id] = nil
		changed(self, marks[i].id, "gone")
	end
end

function ReportsMT:Prune()
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

local scheduleDigest

-- The receiver takes a held report: to the inbox, and only the mark is kept.
function ReportsMT:_Deliver(rec)
	if self.a.deliver then self.a.deliver(rec) end
	self.list[rec.id] = { id = rec.id, by = rec.by, t = rec.t, st = "d" }
	self:_Trim()
	changed(self, rec.id, "delivered")
	scheduleDigest(self, true)
end

-- A held report from a guildmate. Returns true when it was new to us.
function ReportsMT:Merge(rec)
	if type(rec) ~= "table" or rec.st ~= "h" then return false end
	rec = clean(rec) -- checked as it would be kept and passed on
	if not self:_Valid(rec) or self.list[rec.id] then return false end
	if self.a.isReceiver() then
		self:_Deliver(rec)
		return true
	end
	if not self:_WouldKeep(rec) then return false end
	self.list[rec.id] = rec
	self:_Trim()
	changed(self, rec.id, "new")
	return true
end

-- The report with this id was delivered (a mark from a digest). Returns true when it changed.
-- bulk: the caller trims once after many marks and tells about them (returns them).
function ReportsMT:MarkDelivered(id, t, bulk)
	local by = reporterOf(id)
	local mark = { id = id, by = by, t = t, st = "d" }
	if not by or not self:_Valid(mark) then return false end
	local held = self.list[id]
	if held and held.st == "d" then return false end
	if not held and not self:_WouldKeep(mark) then return false end
	self.list[id] = mark
	if bulk then return true end
	self:_Trim()
	if self.list[id] then changed(self, id, "delivered") end
	return true
end

-- Our own report (a Bugs.lua report: n, t, v, who, text, ctx, errors, log) for the guild. The
-- receiver's own one goes to its inbox at once. Returns the record, or nil.
function ReportsMT:Share(report)
	if type(report) ~= "table" or type(report.n) ~= "number" then return nil end
	local me = self.a.myGuid()
	local t = validTime(report.t) and report.t or self.a.clock()
	local rec = clean({
		id = me .. ":" .. string.format("%d:%d", t, report.n), by = me, t = t, st = "h",
		who = report.who, v = report.v, text = report.text, ctx = report.ctx,
		errors = report.errors, log = report.log,
	})
	if not self:_Valid(rec) or self.list[rec.id] then return nil end
	if self.a.isReceiver() then
		self:_Deliver(rec)
		return self.list[rec.id]
	end
	self.list[rec.id] = rec
	self:_Trim()
	if not self.list[rec.id] then return nil end
	changed(self, rec.id, "new")
	if self:_Open() then
		self.sendQueue[#self.sendQueue + 1] = { ids = { rec.id }, next = 1 }
		self:_Pump()
	end
	return rec
end

---------------------------------------------------------------------------
-- Keeping the guild in step
---------------------------------------------------------------------------

local function between(self, range)
	return range[1] + (range[2] - range[1]) * self.a.random()
end

-- Sending is possible and worth it: a receiver is in the guild.
function ReportsMT:_Open()
	return not self.dead and self.a.canSend() and self.a.receiverInGuild()
end

local function send(self, msg)
	msg.pv = Reports.PROTOCOL
	msg.s = self.a.myGuid()
	self.a.send(msg)
end

function ReportsMT:_AnswerSent()
	self.answering = false
	self.lastAnswer = self.a.now()
	self:_ScheduleAnswer()
end

function ReportsMT:_Pump()
	if self.pumping then return end
	local job = self.sendQueue[1]
	if not job then return end
	if not self:_Open() then
		local was = self.answering
		self.sendQueue = {}
		if was then self:_AnswerSent() end
		return
	end
	local q = {}
	while job.next <= #job.ids and #q < Reports.MAX_PER_MESSAGE do
		local rec = self.list[job.ids[job.next]]
		if rec and rec.st == "h" then q[#q + 1] = rec end
		job.next = job.next + 1
	end
	local last = job.next > #job.ids
	if last then table.remove(self.sendQueue, 1) end
	if #q > 0 then
		self.stats.sentU = self.stats.sentU + 1
		send(self, { t = "BU", q = q })
	end
	if last and job.answer then self:_AnswerSent() end
	if #self.sendQueue > 0 then
		self.pumping = true
		self.a.after(Reports.SEND_PACE, function()
			self.pumping = false
			self:_Pump()
		end)
	end
end

-- Sends our digest (after every hello of Sync; also an empty one, so the holders answer a
-- newcomer at once). Returns false when nothing was sent.
function ReportsMT:Announce()
	if not self:_Open() then return false end
	self:Prune()
	local all = {}
	for _, rec in pairs(self.list) do all[#all + 1] = rec end
	-- our own held reports first: they may be the only copies
	local own = ownTest(self)
	table.sort(all, function(p, q)
		local op, oq = own(p), own(q)
		if op ~= oq then return op end
		return newer(p, q)
	end)
	local x = {}
	for i = 1, math.min(#all, Reports.MAX_DIGEST) do
		local rec = all[i]
		x[#x + 1] = rec.id
		x[#x + 1] = rec.st
		x[#x + 1] = rec.t
	end
	self.lastDigest = self.a.now()
	self.stats.sentD = self.stats.sentD + 1
	send(self, { t = "BD", x = x })
	return true
end

-- An answering digest: at most every DIGEST_GAP; soon: after a delivery, waits out the gap
-- instead of skipping it, so the mark leaves even when we just sent a digest.
scheduleDigest = function(self, soon)
	if self.digestTimer then return end
	local wait = Reports.DIGEST_GAP - (self.a.now() - self.lastDigest)
	if wait > 0 and not soon then return end
	self.digestTimer = true
	self.digestCovered = false
	self.a.after(math.max(wait, between(self, Reports.DIGEST_DELAY)), function()
		self.digestTimer = false
		if self.digestCovered and not soon then return end
		if self.a.now() - self.lastDigest >= Reports.DIGEST_GAP or soon then self:Announce() end
	end)
end

function ReportsMT:_Answer(ids)
	self.answerIds = self.answerIds or {}
	for id in pairs(ids) do self.answerIds[id] = true end
	self:_ScheduleAnswer()
end

function ReportsMT:_ScheduleAnswer()
	if self.answerTimer or self.answering or not self.answerIds then return end
	local wait = math.max(0, Reports.ANSWER_COOLDOWN - (self.a.now() - self.lastAnswer))
	self.answerTimer = true
	self.a.after(wait, function()
		self.answerTimer = false
		local asked = self.answerIds
		self.answerIds = nil
		if not asked or not self:_Open() then return end
		local ids = {}
		for id in pairs(asked) do
			local rec = self.list[id]
			if rec and rec.st == "h" then ids[#ids + 1] = id end
		end
		if #ids == 0 then return end
		table.sort(ids)
		self.answering = true
		self.sendQueue[#self.sendQueue + 1] = { ids = ids, next = 1, answer = true }
		self:_Pump()
	end)
end

function ReportsMT:_Request(holder, ids)
	local now = self.a.now()
	local fresh = {}
	for id in pairs(ids) do
		if not self.asked[id] or now - self.asked[id] >= Reports.ASK_AGAIN then fresh[id] = true end
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
	self.requests[holder] = { ids = fresh, token = token }
	self.a.after(between(self, Reports.REQUEST_DELAY), function()
		local req = self.requests[holder]
		if not req or req.token ~= token then return end
		self.requests[holder] = nil
		if not self:_Open() then
			for id in pairs(req.ids) do self.asked[id] = nil end
			return
		end
		local list = {}
		for id in pairs(req.ids) do
			if not self.list[id] then list[#list + 1] = id end
		end
		if #list == 0 then return end
		table.sort(list)
		-- the rest is asked for when this answer came (or after the next digest)
		for i = #list, Reports.MAX_ASK + 1, -1 do
			self.asked[list[i]] = nil
			self.more[holder] = self.more[holder] or {}
			self.more[holder][list[i]] = true
			list[i] = nil
		end
		self.stats.sentR = self.stats.sentR + 1
		send(self, { t = "BR", to = holder, ids = list })
	end)
	return true
end

function ReportsMT:OnMessage(msg)
	if type(msg) ~= "table" or msg.pv ~= Reports.PROTOCOL then return end
	local me = self.a.myGuid()
	if msg.s == me or not validGuid(msg.s) then return end
	if msg.t == "BU" then
		if type(msg.q) ~= "table" then return end
		self.stats.recvU = self.stats.recvU + 1
		local stored = 0
		for i = 1, math.min(#msg.q, Reports.MAX_PER_MESSAGE) do
			if self:Merge(msg.q[i]) then stored = stored + 1 end
		end
		local more = self.more[msg.s]
		if more then
			self.more[msg.s] = nil
			local still = {}
			for id in pairs(more) do
				if not self.list[id] then still[id] = true end
			end
			if next(still) then self:_Request(msg.s, still) end
		end
		return stored
	elseif msg.t == "BD" then
		if type(msg.x) ~= "table" or #msg.x > 3 * Reports.MAX_DIGEST or #msg.x % 3 ~= 0 then return end
		self.stats.recvD = self.stats.recvD + 1
		local theirs, want, receiver, marked = {}, {}, self.a.isReceiver(), {}
		local oldest
		for i = 1, #msg.x, 3 do
			local id, st, t = msg.x[i], msg.x[i + 1], msg.x[i + 2]
			local by = reporterOf(id)
			if by and (st == "h" or st == "d") and validTime(t) then
				theirs[id] = st
				if not oldest or t < oldest then oldest = t end
				local held = self.list[id]
				if st == "d" then
					if self:MarkDelivered(id, t, true) then marked[#marked + 1] = id end
				elseif not held then
					local mark = { id = id, by = by, t = t, st = "d" }
					local cand = receiver and mark or { id = id, by = by, t = t, st = "h" }
					if self:_Valid(mark) and self:_WouldKeep(cand) then
						want[id] = true
					end
				end
			end
		end
		if #marked > 0 then
			self:_Trim()
			for _, id in ipairs(marked) do
				if self.list[id] then changed(self, id, "delivered") end
			end
		end
		-- they lack a record we hold, or know less about it: our digest tells them. A full digest
		-- leaves out their oldest records, so ours older than its oldest entry are not counted.
		-- (clients that keep different own reports differ for good: one answering digest per
		-- hello at most, DIGEST_GAP stops the ping-pong)
		local full = #msg.x >= 3 * Reports.MAX_DIGEST
		-- the sender's own reports come first, the rest newest first: the last entry is the cut
		if full and validTime(msg.x[#msg.x]) then oldest = msg.x[#msg.x] end
		local differs, clock = false, self.a.clock()
		for id, rec in pairs(self.list) do
			if theirs[id] ~= rec.st and theirs[id] ~= "d" and not self:_Expired(rec, clock)
				and not (full and oldest and rec.t < oldest) then
				differs = true
				break
			end
		end
		if self.digestTimer and not differs and not next(want) then self.digestCovered = true end
		if next(want) then self:_Request(msg.s, want) end
		if differs then scheduleDigest(self) end
		return next(want) ~= nil
	elseif msg.t == "BR" then
		if not validGuid(msg.to) or type(msg.ids) ~= "table" or #msg.ids > Reports.MAX_ASK then return end
		self.stats.recvR = self.stats.recvR + 1
		local ids = {}
		for _, id in ipairs(msg.ids) do
			if reporterOf(id) then ids[id] = true end
		end
		if msg.to == me then
			if next(ids) then self:_Answer(ids) end
		else
			local now = self.a.now()
			for id in pairs(ids) do self.asked[id] = now end
			for _, r in pairs(self.requests) do
				for id in pairs(ids) do r.ids[id] = nil end
			end
		end
	end
end

function ReportsMT:OnSendFailed(msg)
	if type(msg) ~= "table" then return end
	if msg.t == "BR" and type(msg.ids) == "table" then
		for _, id in ipairs(msg.ids) do self.asked[id] = nil end
	end
	-- a lost update or digest: the next hello's digest brings everything again
end

-- The guild changed: this object stops sending (its timers may still run).
function ReportsMT:Stop()
	self.dead = true
	self.sendQueue = {}
	self.requests = {}
	self.more = {}
	self.answering = false
end

-- Our digest soon (a receiver just appeared in the roster): with the usual random delay, so the
-- guild does not answer in the same second.
function ReportsMT:AnnounceSoon()
	scheduleDigest(self, true)
end

-- Name and realm folded for comparing: no case, no spaces or apostrophes.
local function fold(s)
	return type(s) == "string" and s:lower():gsub("[%s']", "") or ""
end

-- Is this character (name, realm; or "Name-Realm" in name) one of the receivers? A missing realm
-- is taken as our own (myRealm).
function Reports.IsReceiverName(name, realm, myRealm)
	if type(name) ~= "string" then return false end
	if not realm or realm == "" then
		local n, r = name:match("^([^%-%s]+)[%-%s](.+)$")
		if n then name, realm = n, r end
	end
	if not realm or realm == "" then realm = myRealm end
	local key = fold(name) .. "-" .. fold(realm)
	for _, r in ipairs(Reports.RECEIVERS) do
		local rn, rr = r:match("^([^%-]+)%-(.+)$")
		if key == fold(rn) .. "-" .. fold(rr) then return true end
	end
	return false
end

return Reports
