-- Profguild: Reagents
-- Catalog of crafting reagents per recipe and the on-demand exchange that shares it with the
-- guild. Reagents are game data, the same for everyone, so the catalog is kept per account and
-- never travels inside the character records.
--
-- Messages (same channel and protocol version as Sync):
--   Q query   { t="Q", pv, s=senderGuid, q={ recipeID, ... } }
--   C catalog { t="C", pv, s=senderGuid, c={ [recipeID] = { [itemID] = count } } }
--
-- Own recipes get their reagents when a profession window is scanned. Reagents of other
-- members' recipes are asked for when such a recipe is opened in the window. Whoever has them
-- answers after a random delay; an answer seen first cancels the own one.
--
-- An answer is stored only for a recipe this client asked for itself, shortly before: guild
-- members cannot push entries into the catalog. What the game says about a recipe (Set)
-- always replaces what a guildmate said.
--
-- Adapter: send(msg), canSend() -> bool, now(), after(seconds, fn), random() -> [0,1),
--          myGuid(), onChanged(recipeID) (optional)

local _, ns = ...
ns = ns or {}

local Reagents = {}
ns.Reagents = Reagents

Reagents.PROTOCOL = 1
Reagents.MAX_PER_RECIPE = 10
Reagents.MAX_COUNT = 999
Reagents.MAX_ID = 2147483647
Reagents.MAX_PER_MESSAGE = 40
Reagents.MAX_CATALOG = 20000    -- recipes learned from guildmates stop being added above this
Reagents.ASK_DELAY = 0.5        -- collects recipes opened in a row into one query
Reagents.ASK_AGAIN = 60         -- seconds before the same recipe is asked for again
Reagents.REPLY_DELAY = { 1.0, 3.0 }

local function validID(v)
	return type(v) == "number" and v >= 1 and v <= Reagents.MAX_ID and v == math.floor(v)
end

-- { [itemID] = count } with whole positive numbers only. nil when nothing valid is left.
function Reagents.Validate(list)
	if type(list) ~= "table" then return nil end
	local clean, n = {}, 0
	for itemID, count in pairs(list) do
		if validID(itemID) and type(count) == "number" and count >= 1 and count <= Reagents.MAX_COUNT
			and count == math.floor(count) then
			n = n + 1
			if n > Reagents.MAX_PER_RECIPE then return nil end
			clean[itemID] = count
		end
	end
	if n == 0 then return nil end
	return clean
end

local function same(a, b)
	if not a or not b then return false end
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

local ReagentsMT = {}
ReagentsMT.__index = ReagentsMT

-- catalog: the saved table { [recipeID] = { [itemID] = count } }
function Reagents.New(adapter, catalog)
	return setmetatable({
		a = adapter,
		catalog = catalog,
		asked = {},       -- recipeID -> time a query for it was sent or seen
		mine = {},        -- recipeID -> time we asked for it ourselves
		askList = {},     -- recipeIDs waiting for the next query
		askTimer = false,
		replies = {},     -- recipeID -> true, answers we are going to send
		replyTimer = false,
		stats = { sentQ = 0, sentC = 0, recvQ = 0, recvC = 0, learned = 0 },
	}, ReagentsMT)
end

function ReagentsMT:Get(recipeID)
	return self.catalog[recipeID]
end

-- Stores reagents read from our own profession window. Returns true when something changed.
function ReagentsMT:Set(recipeID, list)
	if not validID(recipeID) then return false end
	local clean = Reagents.Validate(list)
	if not clean or same(self.catalog[recipeID], clean) then return false end
	self.catalog[recipeID] = clean
	if self.a.onChanged then self.a.onChanged(recipeID) end
	return true
end

function ReagentsMT:Count()
	local n = 0
	for _ in pairs(self.catalog) do n = n + 1 end
	return n
end

local function send(self, msg)
	msg.pv = Reagents.PROTOCOL
	msg.s = self.a.myGuid()
	self.a.send(msg)
end

-- Sends ids in messages of at most MAX_PER_MESSAGE recipes. build(chunk) makes the message.
local function sendChunks(self, ids, build)
	table.sort(ids)
	local i = 1
	while i <= #ids do
		local chunk = {}
		for j = i, math.min(#ids, i + Reagents.MAX_PER_MESSAGE - 1) do chunk[#chunk + 1] = ids[j] end
		send(self, build(chunk))
		i = i + Reagents.MAX_PER_MESSAGE
	end
end

-- The window wants the reagents of a recipe we do not know. Asks the guild shortly after,
-- together with other recipes opened in the meantime. Returns true when a query is planned.
function ReagentsMT:Want(recipeID)
	if not validID(recipeID) or self.catalog[recipeID] then return false end
	local now = self.a.now()
	if self.asked[recipeID] and now - self.asked[recipeID] < Reagents.ASK_AGAIN then return false end
	if not self.a.canSend() then return false end
	self.asked[recipeID] = now
	self.mine[recipeID] = now
	self.askList[#self.askList + 1] = recipeID
	if not self.askTimer then
		self.askTimer = true
		self.a.after(Reagents.ASK_DELAY, function()
			self.askTimer = false
			local ids = {}
			for _, id in ipairs(self.askList) do
				if not self.catalog[id] then ids[#ids + 1] = id end
			end
			self.askList = {}
			if #ids == 0 or not self.a.canSend() then return end
			sendChunks(self, ids, function(chunk)
				self.stats.sentQ = self.stats.sentQ + 1
				return { t = "Q", q = chunk }
			end)
		end)
	end
	return true
end

-- True while an answer for this recipe is expected (asked recently, not received yet).
function ReagentsMT:IsAsking(recipeID)
	local t = self.asked[recipeID]
	return t ~= nil and not self.catalog[recipeID] and self.a.now() - t < Reagents.ASK_AGAIN
end

function ReagentsMT:_ScheduleReplies()
	if self.replyTimer then return end
	self.replyTimer = true
	local range = Reagents.REPLY_DELAY
	self.a.after(range[1] + (range[2] - range[1]) * self.a.random(), function()
		self.replyTimer = false
		local ids = {}
		for id in pairs(self.replies) do
			if self.catalog[id] then ids[#ids + 1] = id end
		end
		self.replies = {}
		if #ids == 0 or not self.a.canSend() then return end
		sendChunks(self, ids, function(chunk)
			local c = {}
			for _, id in ipairs(chunk) do c[id] = self.catalog[id] end
			self.stats.sentC = self.stats.sentC + 1
			return { t = "C", c = c }
		end)
	end)
end

function ReagentsMT:OnMessage(msg)
	if type(msg) ~= "table" or msg.pv ~= Reagents.PROTOCOL then return end
	if msg.s == self.a.myGuid() then return end -- GUILD addon messages are echoed to the sender
	if msg.t == "Q" then
		if type(msg.q) ~= "table" then return end
		self.stats.recvQ = self.stats.recvQ + 1
		local now, n, any = self.a.now(), 0, false
		for _, id in ipairs(msg.q) do
			n = n + 1
			if n > Reagents.MAX_PER_MESSAGE then break end
			if validID(id) then
				-- the answer reaches us too, so we do not ask for it ourselves
				self.asked[id] = now
				if self.catalog[id] then
					self.replies[id] = true
					any = true
				end
			end
		end
		if any then self:_ScheduleReplies() end
	elseif msg.t == "C" then
		if type(msg.c) ~= "table" then return end
		self.stats.recvC = self.stats.recvC + 1
		local now, n, size = self.a.now(), 0, nil
		for id, list in pairs(msg.c) do
			n = n + 1
			if n > Reagents.MAX_PER_MESSAGE then break end
			if validID(id) then
				self.replies[id] = nil -- someone answered first
				local clean = Reagents.Validate(list)
				-- only what we asked for ourselves, and only while the answer is expected
				local expected = self.mine[id] and now - self.mine[id] < Reagents.ASK_AGAIN
				if clean and expected and not self.catalog[id] then
					size = size or self:Count()
					if size >= Reagents.MAX_CATALOG then break end
					size = size + 1
					self.mine[id] = nil
					self.catalog[id] = clean
					self.stats.learned = self.stats.learned + 1
					if self.a.onChanged then self.a.onChanged(id) end
				end
			end
		end
	end
end

return Reagents
