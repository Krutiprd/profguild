-- Profguild: Catalog
-- Every recipe of every profession, whether somebody in the guild knows it or not. Recipes are
-- game data, the same for everyone, so the catalog is kept per account and never travels inside
-- the character records. It is filled from opened profession windows (the game lists the
-- recipes a character has not learned too) and shared with the guild on demand.
--
-- Messages (same channel and protocol version as Sync):
--   KD digest  { t="KD", pv, s=senderGuid, d={ [skillLine] = number of recipes } }
--   KR request { t="KR", pv, s=senderGuid, l={ skillLine, ... } }
--   KL list    { t="KL", pv, s=senderGuid, l=skillLine, c=total, r={ recipeID, ... } }
--
-- Every client sends its digest after its hello. Whoever sees a guildmate with more recipes of
-- a profession asks for that profession; one holder answers after a random delay, and an
-- answer or question seen first cancels the own one. A client that holds more than the sender
-- of a digest answers with its own digest (at most once per DIGEST_GAP), so a newcomer does not
-- wait for the next periodic hello.
--
-- A list is stored only for a profession this client asked for shortly before, and each recipe
-- only when the game itself knows it (verify), which also gives the crafted item: guildmates
-- cannot push made-up recipes into the catalog.
--
-- Adapter: send(msg), canSend() -> bool, now(), after(seconds, fn), random() -> [0,1),
--          myGuid(), verify(recipeID, skillLine) -> itemID or nil, onChanged(skillLine) (optional)

local _, ns = ...
ns = ns or {}

local Catalog = {}
ns.Catalog = Catalog

Catalog.PROTOCOL = 1
Catalog.MAX_PROFESSIONS = 16
Catalog.MAX_PER_PROFESSION = 2500
Catalog.MAX_PER_MESSAGE = 200
Catalog.MAX_ID = 2147483647
Catalog.ASK_AGAIN = 60          -- seconds before the same profession is asked for again
Catalog.ANSWER_WINDOW = 120     -- parts of a list are accepted this long after asking
Catalog.REQUEST_DELAY = { 0.5, 2.0 }
Catalog.REPLY_DELAY = { 1.0, 4.0 }
Catalog.DIGEST_DELAY = { 2.0, 6.0 }
Catalog.DIGEST_GAP = 120        -- an answering digest at most this often

local function validID(v, max)
	return type(v) == "number" and v >= 1 and v <= (max or Catalog.MAX_ID) and v == math.floor(v)
end

local CatalogMT = {}
CatalogMT.__index = CatalogMT

-- saved: the saved table { [skillLine] = { [recipeID] = itemID } }
function Catalog.New(adapter, saved)
	return setmetatable({
		a = adapter,
		saved = saved,
		revision = 0,          -- counts changes, for the window's list cache
		asked = {},            -- skillLine -> time a request for it was sent or seen
		mine = {},             -- skillLine -> time we asked for it ourselves
		askList = {},          -- skillLines waiting for the next request
		askTimer = false,
		replies = {},          -- skillLine -> true, lists we are going to send
		replyTimer = false,
		digestTimer = false,
		lastDigest = -1e9,
		stats = { sentD = 0, sentR = 0, sentL = 0, recvD = 0, recvR = 0, recvL = 0, added = 0 },
	}, CatalogMT)
end

local function between(self, range)
	return range[1] + (range[2] - range[1]) * self.a.random()
end

local function changed(self, skillLine)
	self.revision = self.revision + 1
	if self.a.onChanged then self.a.onChanged(skillLine) end
end

local function professions(self)
	local n = 0
	for _ in pairs(self.saved) do n = n + 1 end
	return n
end

-- Stores recipes of one profession: { [recipeID] = itemID }. Recipes are only ever added, the
-- game does not take recipes out of a profession. Returns the number of new recipes.
function CatalogMT:Add(skillLine, list)
	if not validID(skillLine, 1000000) or type(list) ~= "table" then return 0 end
	local prof = self.saved[skillLine]
	if not prof then
		if professions(self) >= Catalog.MAX_PROFESSIONS then return 0 end
		prof = {}
	end
	local count = self:Count(skillLine)
	local added = 0
	for recipeID, itemID in pairs(list) do
		if validID(recipeID) then
			local item = validID(itemID) and itemID or 0
			if prof[recipeID] == nil then
				if count >= Catalog.MAX_PER_PROFESSION then break end
				prof[recipeID] = item
				count = count + 1
				added = added + 1
			elseif prof[recipeID] == 0 and item > 0 then
				prof[recipeID] = item
				added = added + 1
			end
		end
	end
	if added > 0 then
		self.saved[skillLine] = prof
		self.stats.added = self.stats.added + added
		changed(self, skillLine)
	end
	return added
end

-- Forgets one profession (/pg catalog clear). The next profession window fills it again.
function CatalogMT:Remove(skillLine)
	if self.saved[skillLine] == nil then return false end
	self.saved[skillLine] = nil
	changed(self, skillLine)
	return true
end

function CatalogMT:Get(skillLine)
	return self.saved[skillLine]
end

function CatalogMT:All()
	return self.saved
end

function CatalogMT:Count(skillLine)
	local n = 0
	for _ in pairs(self.saved[skillLine] or {}) do n = n + 1 end
	return n
end

-- Total number of recipes and of professions.
function CatalogMT:Total()
	local recipes, profs = 0, 0
	for skillLine in pairs(self.saved) do
		profs = profs + 1
		recipes = recipes + self:Count(skillLine)
	end
	return recipes, profs
end

function CatalogMT:Digest()
	local d = {}
	for skillLine in pairs(self.saved) do d[skillLine] = self:Count(skillLine) end
	return d
end

local function send(self, msg)
	msg.pv = Catalog.PROTOCOL
	msg.s = self.a.myGuid()
	self.a.send(msg)
end

-- Sends our digest. Called after every hello of Sync.
function CatalogMT:Announce()
	if not self.a.canSend() then return false end
	self.lastDigest = self.a.now()
	self.stats.sentD = self.stats.sentD + 1
	send(self, { t = "KD", d = self:Digest() })
	return true
end

local function scheduleDigest(self)
	if self.digestTimer or self.a.now() - self.lastDigest < Catalog.DIGEST_GAP then return end
	self.digestTimer = true
	self.a.after(between(self, Catalog.DIGEST_DELAY), function()
		self.digestTimer = false
		if self.a.now() - self.lastDigest >= Catalog.DIGEST_GAP then self:Announce() end
	end)
end

-- Asks the guild for the recipes of a profession (together with others wanted meanwhile).
function CatalogMT:Want(skillLine)
	if not validID(skillLine, 1000000) then return false end
	local now = self.a.now()
	if self.mine[skillLine] and now - self.mine[skillLine] < Catalog.ASK_AGAIN then return false end
	-- somebody asked for it a moment ago: wait for that answer instead of asking again
	if self.asked[skillLine] and now - self.asked[skillLine] < Catalog.ASK_AGAIN then
		self.mine[skillLine] = now
		return true
	end
	if not self.a.canSend() then return false end
	self.asked[skillLine] = now
	self.mine[skillLine] = now
	self.askList[#self.askList + 1] = skillLine
	if not self.askTimer then
		self.askTimer = true
		self.a.after(between(self, Catalog.REQUEST_DELAY), function()
			self.askTimer = false
			local list = {}
			for _, id in ipairs(self.askList) do list[#list + 1] = id end
			self.askList = {}
			if #list == 0 or not self.a.canSend() then return end
			table.sort(list)
			self.stats.sentR = self.stats.sentR + 1
			send(self, { t = "KR", l = list })
		end)
	end
	return true
end

function CatalogMT:_ScheduleReplies()
	if self.replyTimer then return end
	self.replyTimer = true
	self.a.after(between(self, Catalog.REPLY_DELAY), function()
		self.replyTimer = false
		local lines = {}
		for skillLine in pairs(self.replies) do lines[#lines + 1] = skillLine end
		self.replies = {}
		if #lines == 0 or not self.a.canSend() then return end
		table.sort(lines)
		for _, skillLine in ipairs(lines) do
			local ids = {}
			for recipeID in pairs(self.saved[skillLine] or {}) do ids[#ids + 1] = recipeID end
			table.sort(ids)
			local i = 1
			while i <= #ids do
				local chunk = {}
				for j = i, math.min(#ids, i + Catalog.MAX_PER_MESSAGE - 1) do chunk[#chunk + 1] = ids[j] end
				self.stats.sentL = self.stats.sentL + 1
				send(self, { t = "KL", l = skillLine, c = #ids, r = chunk })
				i = i + Catalog.MAX_PER_MESSAGE
			end
		end
	end)
end

function CatalogMT:OnMessage(msg)
	if type(msg) ~= "table" or msg.pv ~= Catalog.PROTOCOL then return end
	if msg.s == self.a.myGuid() then return end -- GUILD addon messages are echoed to the sender
	local now = self.a.now()
	if msg.t == "KD" then
		if type(msg.d) ~= "table" then return end
		self.stats.recvD = self.stats.recvD + 1
		local n, theirs, wanted = 0, {}, false
		for skillLine, count in pairs(msg.d) do
			n = n + 1
			if n > Catalog.MAX_PROFESSIONS then break end
			if validID(skillLine, 1000000) and validID(count, Catalog.MAX_PER_PROFESSION) then
				theirs[skillLine] = count
				if count > self:Count(skillLine) then
					if self:Want(skillLine) then wanted = true end
				end
			end
		end
		-- we hold a profession the sender lacks, or more of it: tell the guild what we have
		for skillLine in pairs(self.saved) do
			if self:Count(skillLine) > (theirs[skillLine] or 0) then
				scheduleDigest(self)
				break
			end
		end
		return wanted
	elseif msg.t == "KR" then
		if type(msg.l) ~= "table" then return end
		self.stats.recvR = self.stats.recvR + 1
		local n, any = 0, false
		for _, skillLine in ipairs(msg.l) do
			n = n + 1
			if n > Catalog.MAX_PROFESSIONS then break end
			if validID(skillLine, 1000000) then
				-- the answer reaches us too: our own request is not sent, the answer is still accepted
				self.asked[skillLine] = now
				for i = #self.askList, 1, -1 do
					if self.askList[i] == skillLine then table.remove(self.askList, i) end
				end
				if self.saved[skillLine] then
					self.replies[skillLine] = true
					any = true
				end
			end
		end
		if any then self:_ScheduleReplies() end
	elseif msg.t == "KL" then
		local skillLine = msg.l
		if not validID(skillLine, 1000000) or type(msg.r) ~= "table" then return end
		self.stats.recvL = self.stats.recvL + 1
		-- somebody answered with at least what we have: our own answer adds nothing
		if self.replies[skillLine] and validID(msg.c, Catalog.MAX_PER_PROFESSION) and msg.c >= self:Count(skillLine) then
			self.replies[skillLine] = nil
		end
		local askedAt = self.mine[skillLine]
		if not askedAt or now - askedAt > Catalog.ANSWER_WINDOW then return end
		local list, n = {}, 0
		local prof = self.saved[skillLine] or {}
		for _, recipeID in ipairs(msg.r) do
			n = n + 1
			if n > Catalog.MAX_PER_MESSAGE then break end
			if validID(recipeID) and prof[recipeID] == nil then
				local itemID = self.a.verify(recipeID, skillLine)
				if itemID then list[recipeID] = itemID end
			end
		end
		self:Add(skillLine, list)
	end
end

return Catalog
