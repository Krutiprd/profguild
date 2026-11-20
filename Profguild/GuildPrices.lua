-- Profguild: GuildPrices
-- Auction prices shared inside the guild. Whenever Auctionator reads the auction house (a search
-- or a full scan), the prices of the items Profguild needs go to the guild; the newer price of an
-- item always wins. Nothing is ever written into Auctionator. Prices.lua hands the readings over
-- (Record): exactly what was read and when, so an item with no auctions or a value from an
-- earlier session is never sent as new.
--
-- Messages (GUILD channel):
--   PU update  { t="PU", pv, s=senderGuid, w={ guid, ... }, i={ itemID, copper, pieces, time, w index, ... } }
--   PD digest  { t="PD", pv, s, b={ day, count, sum, day, count, sum, ... } }
--   PR request { t="PR", pv, s, to=holderGuid, d={ day, ... } }
--
-- Keeping the guild in step (anti-entropy): prices are grouped by the UTC day of their time. A
-- digest gives, per day of the last KEEP days, how many prices fall on it and a sum over their
-- items, times and prices. Whoever sees a day that differs from its own, and that the sender has
-- prices on, asks the sender for those days; the sender answers with all its prices of those
-- days, and everybody who hears the answer merges it (newer wins). Two clients that differ both
-- ways fix it from both sides, and a lost part or a missed update shows up in the next digest
-- again, so the guild converges without anybody having to know what it missed. A request heard
-- for the same holder and days covers ours. A client that holds something a digest lacks answers
-- with its own digest (at most once per DIGEST_GAP), so a newcomer does not wait for the next hello.
--
-- Every valid price is kept, also of items this client does not show yet, so the tables of the
-- guild can become equal. Bounded: MAX_ENTRIES in all, kept by one order everywhere (newest
-- first, then the lower item ID), so full tables keep the same prices; MAX_PER_FINDER prices
-- read by one guildmate, so a buggy or hostile one cannot push out everybody else's.
--
-- Traffic: the same prices of a day (the same count and sum at a holder) are asked for once per
-- ASK_SAME_AGAIN in the whole guild (a guildmate's request heard counts); a holder sends one answer at a time, the next one only ANSWER_COOLDOWN
-- after the last part left, and does not answer a day again whose prices did not change since it
-- answered it (ANSWER_SKIP).
--
-- Adapter: send(msg), canSend() -> bool, now() (seconds, monotonic), clock() (server time),
--          after(seconds, fn), random() -> [0,1), myGuid(), onChanged() (optional)

local _, ns = ...
ns = ns or {}

local GuildPrices = {}
ns.GuildPrices = GuildPrices

GuildPrices.PROTOCOL = 1
GuildPrices.MAX_PER_MESSAGE = 100
GuildPrices.MAX_ENTRIES = 5000
GuildPrices.MAX_PER_FINDER = 3000
GuildPrices.MAX_PRICE = 9999990000      -- 999 999g in copper
GuildPrices.MAX_PIECES = 100000
GuildPrices.KEEP = 14 * 86400           -- prices older than this are dropped and not compared
GuildPrices.MAX_AGE = GuildPrices.KEEP  -- an incoming price may be this old
GuildPrices.MAX_AHEAD = 120             -- ... or this far ahead of our clock (all use the realm's time)
GuildPrices.MAX_ID = 2147483647
GuildPrices.SUM_MOD = 2147483647
GuildPrices.MAX_DAYS = 40               -- days read from one digest or request
GuildPrices.SEND_PACE = 1.5             -- seconds between two parts of an update
GuildPrices.SEND_DELAY = 1.0            -- readings are sent this long after them (merges them)
GuildPrices.REQUEST_DELAY = { 1.0, 4.0 }
GuildPrices.DIGEST_DELAY = { 2.0, 6.0 }
GuildPrices.DIGEST_GAP = 60             -- an answering digest at most this often (a digest is ~200 bytes)
GuildPrices.ANSWER_COOLDOWN = 60        -- seconds between the end of an answer and the next one
GuildPrices.ANSWER_SKIP = 120           -- a day answered this recently and unchanged is not sent again
                                        -- (requests racing each other; a later newcomer still gets it)
GuildPrices.ASK_AGAIN = 60              -- a holder is asked again only after this
GuildPrices.ASK_SAME_AGAIN = 300        -- the same prices of a day (from anybody) only after this:
                                        -- a big answer at the throttle's pace takes minutes

local function validID(v)
	return type(v) == "number" and v >= 1 and v <= GuildPrices.MAX_ID and v == math.floor(v)
end

local function validPrice(p)
	return type(p) == "number" and p >= 1 and p <= GuildPrices.MAX_PRICE and p == math.floor(p)
end

local function validPieces(n)
	return type(n) == "number" and n >= 0 and n <= GuildPrices.MAX_PIECES and n == math.floor(n)
end

local function validGuid(g)
	return type(g) == "string" and #g <= 40 and g:find("^Player%-") ~= nil
end

local function dayOf(t)
	return math.floor(t / 86400)
end

local PricesMT = {}
PricesMT.__index = PricesMT

-- saved: the guild's saved table; prices live in saved.prices.
function GuildPrices.New(adapter, saved)
	if type(saved.prices) ~= "table" then saved.prices = {} end
	local self = setmetatable({
		a = adapter,
		saved = saved,
		prices = saved.prices,
		revision = 0,
		dead = false,         -- set when the guild changed: this object must not send any more
		outgoing = {},        -- itemID -> true, own readings waiting to be sent
		sendTimer = false,
		sendQueue = {},       -- updates being sent: { ids, next }
		pumping = false,
		lastAnswer = -1e9,
		answerDays = nil,     -- day -> true, asked for while the answer waits
		answerTimer = false,
		answering = false,    -- an answer is being sent
		answered = {},        -- day -> { count, sum, time } of our last answer of it
		requests = {},        -- holder guid -> { days = { day -> true }, token } waiting to go out
		requestSeq = 0,
		askedAt = {},         -- holder guid -> time we asked it
		dayAsked = {},        -- day -> { [count:sum of the holder's day] = time asked (by anybody) }
		heldBy = {},          -- holder guid -> its digest { [day] = { count, sum } }
		perFinder = {},       -- guid -> number of prices it read
		digestTimer = false,
		digestCovered = false,
		lastDigest = -1e9,
		stats = { sentU = 0, sentD = 0, sentR = 0, recvU = 0, recvD = 0, recvR = 0, stored = 0, recorded = 0 },
	}, PricesMT)
	self.count = 0
	for itemID, e in pairs(self.prices) do
		if type(e) == "table" and validGuid(e.w) and type(e.t) == "number" and type(e.p) == "number" then
			self.count = self.count + 1
			self.perFinder[e.w] = (self.perFinder[e.w] or 0) + 1
		else
			self.prices[itemID] = nil -- broken saved data
		end
	end
	return self
end

local function between(self, range)
	return range[1] + (range[2] - range[1]) * self.a.random()
end

local function changed(self)
	self.revision = self.revision + 1
	if self.a.onChanged then self.a.onChanged() end
end

local function canSend(self)
	return not self.dead and self.a.canSend()
end

local function send(self, msg)
	msg.pv = GuildPrices.PROTOCOL
	msg.s = self.a.myGuid()
	self.a.send(msg)
end

local function validTime(self, t)
	local clock = self.a.clock()
	return type(t) == "number" and t == math.floor(t) and t <= clock + GuildPrices.MAX_AHEAD
		and t >= clock - GuildPrices.MAX_AGE
end

function PricesMT:Get(itemID)
	return self.prices[itemID]
end

function PricesMT:Count()
	return self.count
end

-- Time of the newest price held, 0 when none.
function PricesMT:Newest()
	local m = 0
	for _, e in pairs(self.prices) do
		if e.t > m then m = e.t end
	end
	return m
end

-- Per day of the compared window: { [day] = { count, sum } }, and the first day of the window.
function PricesMT:Buckets()
	local first = dayOf(self.a.clock() - GuildPrices.KEEP) + 1
	local b = {}
	for itemID, e in pairs(self.prices) do
		local d = dayOf(e.t)
		if d >= first then
			local x = b[d]
			if not x then
				x = { 0, 0 }
				b[d] = x
			end
			x[1] = x[1] + 1
			x[2] = (x[2] + GuildPrices.Hash(itemID, e.t, e.p)) % GuildPrices.SUM_MOD
		end
	end
	return b, first
end

-- One entry's share of a day's sum. Each step is mixed by a product of two residues, which is
-- not linear, so differences of several entries do not cancel each other out (every product
-- stays below 2^53, so all clients compute the same number).
local function mix(x, M)
	return (x + (x % 65521) * (x % 65519)) % M
end

function GuildPrices.Hash(itemID, t, p)
	local M = GuildPrices.SUM_MOD
	local x = mix((itemID * 31 + t) % M, M)
	x = mix((x * 48271 + p % M) % M, M)
	return mix((x * 48271) % M, M)
end

-- The order in which prices are kept when the table is full: newer first, then the lower item.
local function ranksBelow(t1, id1, t2, id2)
	return t1 < t2 or (t1 == t2 and id1 > id2)
end

-- The lowest ranked price held (of one finder when w is given).
local function lowest(self, w)
	local lowID, lowT
	for itemID, e in pairs(self.prices) do
		if (not w or e.w == w) and (not lowT or ranksBelow(e.t, itemID, lowT, lowID)) then lowID, lowT = itemID, e.t end
	end
	return lowID, lowT
end

local function forget(self, itemID)
	local e = self.prices[itemID]
	if not e then return end
	self.prices[itemID] = nil
	self.count = self.count - 1
	self.perFinder[e.w] = (self.perFinder[e.w] or 1) - 1
end

-- Stores one price when it is valid and newer than the one held (at the same time the lower
-- price, so every client keeps the same one). Returns true when stored.
function PricesMT:Store(itemID, p, n, t, w)
	if not validID(itemID) or not validPrice(p) or not validPieces(n) or not validGuid(w) then return false end
	if not validTime(self, t) then return false end
	local old = self.prices[itemID]
	if old then
		if t < old.t or (t == old.t and p >= old.p) then return false end
	end
	if (not old or old.w ~= w) and (self.perFinder[w] or 0) >= GuildPrices.MAX_PER_FINDER then
		-- this finder is at its limit: its lowest ranked price goes, by the same order everywhere
		local lowID, lowT = lowest(self, w)
		if not lowID or ranksBelow(t, itemID, lowT, lowID) then return false end
		forget(self, lowID)
		old = self.prices[itemID]
	end
	if not old and self.count >= GuildPrices.MAX_ENTRIES then
		-- full: the lowest ranked price goes, unless the new one would rank even lower
		local lowID, lowT = lowest(self)
		if not lowID or ranksBelow(t, itemID, lowT, lowID) then return false end
		forget(self, lowID)
	end
	if old then forget(self, itemID) end
	self.prices[itemID] = { p = p, n = n, t = t, w = w }
	self.count = self.count + 1
	self.perFinder[w] = (self.perFinder[w] or 0) + 1
	self.stats.stored = self.stats.stored + 1
	return true
end

-- Drops prices older than KEEP (at login). Returns how many.
function PricesMT:Prune()
	local limit, dropped = self.a.clock() - GuildPrices.KEEP, 0
	for itemID, e in pairs(self.prices) do
		if type(e) ~= "table" or type(e.t) ~= "number" or e.t < limit then
			self.prices[itemID] = nil
			dropped = dropped + 1
			if type(e) == "table" and e.w then self.perFinder[e.w] = (self.perFinder[e.w] or 1) - 1 end
		end
	end
	self.count = self.count - dropped
	if dropped > 0 then changed(self) end
	return dropped
end

-- Auctionator just read these items at the auction house: { [itemID] = { p = copper, n = pieces } }.
-- They are stored as our own prices of now and sent to the guild. Returns the number stored.
function PricesMT:Record(reads)
	local me, clock, stored = self.a.myGuid(), math.floor(self.a.clock()), 0
	for itemID, v in pairs(reads) do
		if type(v) == "table" and validPrice(v.p) then
			local n = validPieces(v.n) and v.n or 0
			-- a reading of now is the newest there is, even against a guildmate's clock a little ahead
			local held = self.prices[itemID]
			local t = (held and held.t >= clock) and held.t + 1 or clock
			if self:Store(itemID, v.p, n, t, me) then
				stored = stored + 1
				self.outgoing[itemID] = true
			end
		end
	end
	if stored > 0 then
		self.stats.recorded = self.stats.recorded + stored
		changed(self)
		self:_ScheduleSend()
	end
	return stored
end

-- Own readings go out SEND_DELAY after them, so readings right after each other (one per
-- searched item) leave as one update. Readings that cannot go out now reach the guild through
-- the digests later.
function PricesMT:_ScheduleSend()
	if self.sendTimer then return end
	self.sendTimer = true
	self.a.after(GuildPrices.SEND_DELAY, function()
		self.sendTimer = false
		local ids = {}
		for itemID in pairs(self.outgoing) do ids[#ids + 1] = itemID end
		self.outgoing = {}
		if #ids == 0 or not canSend(self) then return end
		table.sort(ids)
		self.sendQueue[#self.sendQueue + 1] = { ids = ids, next = 1 }
		self:_Pump()
	end)
end

-- Builds one update from the prices held for these items.
local function update(self, ids)
	local w, wIndex, items = {}, {}, {}
	for _, itemID in ipairs(ids) do
		local e = self.prices[itemID]
		if e then
			local wi = wIndex[e.w]
			if not wi then
				w[#w + 1] = e.w
				wi = #w
				wIndex[e.w] = wi
			end
			items[#items + 1] = itemID
			items[#items + 1] = e.p
			items[#items + 1] = e.n
			items[#items + 1] = e.t
			items[#items + 1] = wi
		end
	end
	return { t = "PU", w = w, i = items }
end

function PricesMT:_Pump()
	if self.pumping then return end
	local job = self.sendQueue[1]
	if not job then return end
	if not canSend(self) then
		local wasAnswering = self.answering
		self.sendQueue = {}
		if wasAnswering then self:_AnswerSent() end
		return
	end
	local chunk = {}
	for j = job.next, math.min(#job.ids, job.next + GuildPrices.MAX_PER_MESSAGE - 1) do chunk[#chunk + 1] = job.ids[j] end
	job.next = job.next + GuildPrices.MAX_PER_MESSAGE
	local last = job.next > #job.ids
	if last then table.remove(self.sendQueue, 1) end
	local msg = update(self, chunk)
	if #msg.i > 0 then
		self.stats.sentU = self.stats.sentU + 1
		send(self, msg)
	end
	if last and job.answer then self:_AnswerSent() end
	if #self.sendQueue > 0 then
		self.pumping = true
		self.a.after(GuildPrices.SEND_PACE, function()
			self.pumping = false
			self:_Pump()
		end)
	end
end

-- Sends our digest. Called after every hello of Sync, and as the answer to a digest that lacks
-- something we hold. A client without prices sends an empty one: the holders answer with
-- their digests at once, so it does not wait for their next hello.
function PricesMT:Announce()
	if not canSend(self) then return false end
	local b, days, list = self:Buckets(), {}, {}
	for d in pairs(b) do days[#days + 1] = d end
	table.sort(days)
	for _, d in ipairs(days) do
		list[#list + 1] = d
		list[#list + 1] = b[d][1]
		list[#list + 1] = b[d][2]
	end
	self.lastDigest = self.a.now()
	self.stats.sentD = self.stats.sentD + 1
	send(self, { t = "PD", b = list })
	return true
end

local function scheduleDigest(self)
	if self.digestTimer or self.a.now() - self.lastDigest < GuildPrices.DIGEST_GAP then return end
	self.digestTimer = true
	self.digestCovered = false
	self.a.after(between(self, GuildPrices.DIGEST_DELAY), function()
		self.digestTimer = false
		if self.digestCovered then return end
		if self.a.now() - self.lastDigest >= GuildPrices.DIGEST_GAP then self:Announce() end
	end)
end

-- All prices of the asked days: one answer at a time, ANSWER_COOLDOWN after the previous one
-- ended; days answered within ANSWER_SKIP whose prices did not change are left out.
function PricesMT:_Answer(days)
	self.answerDays = self.answerDays or {}
	for d in pairs(days) do self.answerDays[d] = true end
	self:_ScheduleAnswer()
end

function PricesMT:_ScheduleAnswer()
	if self.answerTimer or self.answering or not self.answerDays then return end
	local wait = math.max(0, GuildPrices.ANSWER_COOLDOWN - (self.a.now() - self.lastAnswer))
	self.answerTimer = true
	self.a.after(wait, function()
		self.answerTimer = false
		local asked = self.answerDays
		self.answerDays = nil
		if not asked or not canSend(self) then return end
		local now = self.a.now()
		local buckets = self:Buckets()
		for d in pairs(asked) do
			local b, done = buckets[d], self.answered[d]
			if not b then
				asked[d] = nil
			elseif done and done[1] == b[1] and done[2] == b[2] and now - done[3] < GuildPrices.ANSWER_SKIP then
				asked[d] = nil -- the guild just got these very prices
			else
				self.answered[d] = { b[1], b[2], now }
			end
		end
		local list = {}
		for itemID, e in pairs(self.prices) do
			if asked[dayOf(e.t)] then list[#list + 1] = itemID end
		end
		if #list == 0 then return end
		-- the newest first: an answer cut short still brings the freshest prices
		table.sort(list, function(x, y)
			local tx, ty = self.prices[x].t, self.prices[y].t
			if tx ~= ty then return tx > ty end
			return x < y
		end)
		self.answering = true
		self.sendQueue[#self.sendQueue + 1] = { ids = list, next = 1, answer = true }
		self:_Pump()
	end)
end

-- The last part of an answer left (or sending stopped): the cooldown runs from now.
function PricesMT:_AnswerSent()
	self.answering = false
	self.lastAnswer = self.a.now()
	self:_ScheduleAnswer()
end

-- The prices of a holder's day, as a key: asking twice for the same key brings the same prices.
local function dayKey(self, holder, d)
	local b = self.heldBy[holder] and self.heldBy[holder][d]
	return b and (b[1] .. ":" .. b[2]) or ("?" .. holder)
end

local function markAsked(self, holder, d, now)
	local keys = self.dayAsked[d]
	if not keys then
		keys = {}
		self.dayAsked[d] = keys
	end
	for k, at in pairs(keys) do
		if now - at >= GuildPrices.ASK_SAME_AGAIN then keys[k] = nil end
	end
	keys[dayKey(self, holder, d)] = now
end

-- Asks a holder for the prices of these days (merged with days wanted from it meanwhile).
function PricesMT:_Request(holder, days)
	local now = self.a.now()
	if self.askedAt[holder] and now - self.askedAt[holder] < GuildPrices.ASK_AGAIN then return false end
	-- the same prices asked for a moment ago (from anybody) are not asked again: that answer reaches us
	local fresh = {}
	for d in pairs(days) do
		local at = self.dayAsked[d] and self.dayAsked[d][dayKey(self, holder, d)]
		if not at or now - at >= GuildPrices.ASK_SAME_AGAIN then fresh[d] = true end
	end
	days = fresh
	if not next(days) then return false end
	for d in pairs(days) do markAsked(self, holder, d, now) end
	local r = self.requests[holder]
	if r then
		for d in pairs(days) do r.days[d] = true end
		return true
	end
	self.requestSeq = self.requestSeq + 1
	local token = self.requestSeq
	r = { days = {}, token = token }
	for d in pairs(days) do r.days[d] = true end
	self.requests[holder] = r
	self.a.after(between(self, GuildPrices.REQUEST_DELAY), function()
		local req = self.requests[holder]
		if not req or req.token ~= token then return end
		self.requests[holder] = nil
		if not canSend(self) then return end
		local list = {}
		for d in pairs(req.days) do list[#list + 1] = d end
		if #list == 0 then return end -- covered by a guildmate's request
		table.sort(list)
		self.askedAt[holder] = self.a.now()
		self.stats.sentR = self.stats.sentR + 1
		send(self, { t = "PR", to = holder, d = list })
	end)
	return true
end

-- Reads the day list of a digest: { [day] = { count, sum } } inside our window, or nil when it
-- is not valid.
local function readBuckets(self, list)
	if type(list) ~= "table" or #list > 3 * GuildPrices.MAX_DAYS then return nil end
	local clock = self.a.clock()
	local first, last = dayOf(clock - GuildPrices.KEEP) + 1, dayOf(clock + GuildPrices.MAX_AHEAD)
	local b = {}
	for i = 1, #list, 3 do
		local d, c, s = list[i], list[i + 1], list[i + 2]
		if not validID(d) or not validID(c) or type(s) ~= "number" or s < 0 or s >= GuildPrices.SUM_MOD
			or s ~= math.floor(s) then
			return nil
		end
		if d >= first and d <= last then b[d] = { c, s } end
	end
	return b
end

function PricesMT:OnMessage(msg)
	if type(msg) ~= "table" or msg.pv ~= GuildPrices.PROTOCOL then return end
	local me = self.a.myGuid()
	if msg.s == me or not validGuid(msg.s) then return end -- GUILD addon messages are echoed
	if msg.t == "PU" then
		if type(msg.i) ~= "table" or type(msg.w) ~= "table" then return end
		self.stats.recvU = self.stats.recvU + 1
		local stored, i = 0, 1
		for _ = 1, GuildPrices.MAX_PER_MESSAGE do
			local itemID, p, n, t, wi = msg.i[i], msg.i[i + 1], msg.i[i + 2], msg.i[i + 3], msg.i[i + 4]
			if itemID == nil then break end
			i = i + 5
			local w = type(wi) == "number" and msg.w[wi]
			if w and self:Store(itemID, p, n, t, w) then stored = stored + 1 end
		end
		if stored > 0 then changed(self) end
		return stored
	elseif msg.t == "PD" then
		self.stats.recvD = self.stats.recvD + 1
		local theirs = readBuckets(self, msg.b)
		if not theirs then return end
		self.heldBy[msg.s] = theirs
		local mine = self:Buckets()
		local want, differs = {}, false
		for d, x in pairs(theirs) do
			local y = mine[d]
			if not y or y[1] ~= x[1] or y[2] ~= x[2] then want[d] = true end
		end
		-- days where we hold something the sender may lack (missing there or different)
		for d, y in pairs(mine) do
			local x = theirs[d]
			if not x or x[1] ~= y[1] or x[2] ~= y[2] then differs = true break end
		end
		-- another digest equal to ours on every day: our answering digest adds nothing
		if self.digestTimer and not differs and not next(want) then self.digestCovered = true end
		if next(want) then self:_Request(msg.s, want) end
		if differs then scheduleDigest(self) end
		return next(want) ~= nil
	elseif msg.t == "PR" then
		self.stats.recvR = self.stats.recvR + 1
		if not validGuid(msg.to) or type(msg.d) ~= "table" or #msg.d > GuildPrices.MAX_DAYS then return end
		local days = {}
		for _, d in ipairs(msg.d) do
			if validID(d) then days[d] = true end
		end
		if msg.to == me then
			if next(days) then self:_Answer(days) end
		else
			-- a guildmate asks for days we want too: that answer reaches us as well
			local now = self.a.now()
			for d in pairs(days) do markAsked(self, msg.to, d, now) end
			local r = self.requests[msg.to]
			if r then
				for d in pairs(days) do r.days[d] = nil end
			end
		end
	end
end

-- A request that could not be sent may be sent again right away.
function PricesMT:OnSendFailed(msg)
	if type(msg) == "table" and msg.t == "PR" and type(msg.to) == "string" then
		self.askedAt[msg.to] = nil
		for _, d in ipairs(type(msg.d) == "table" and msg.d or {}) do
			if self.dayAsked[d] then self.dayAsked[d][dayKey(self, msg.to, d)] = nil end
		end
	end
end

-- The guild changed: this object stops sending (its timers may still run).
function PricesMT:Stop()
	self.dead = true
	self.answering = false
	self.sendQueue = {}
	self.outgoing = {}
	self.requests = {}
end

return GuildPrices
