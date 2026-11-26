-- Profguild: NpcReader
-- Turns the profession trainer and merchant windows into readings, one per NPC (design "Reading").
-- All WoW calls go through the api, so tests inject a fake game. Nothing in either window is
-- changed (no filter, no selection), nothing is read in combat, and a reading that met a value the
-- game marks secret is dropped whole.
--
-- reading = { name=, map=, x=, y=, t = { [recipeID] = { skill=, copper= } }, v = { [itemID] = { price= } } }
--   place: uiMapID and the player's position in whole percent (rounded down), absent when unknown;
--   price = { c = copper, o = { { kind, id, count }, ... } sorted, l = 0|1 }, kind 1 currency, 2 item;
--   an item entry without price is seen only.
--
-- api: now() seconds, after(seconds, fn), inCombat(), secret(v) (issecretvalue), npcGUID(), npcName(),
--      place() -> uiMapID, x, y (fractions 0-1, any of them nil when unknown),
--      tradeskillTrainer(), numServices(), serviceInfo(i) -> name, type, ...,
--      serviceSkill(i) -> profession name, skill, met, serviceCost(i) -> copper,
--      serviceSpell(i) -> spellID|nil (optional: the client gives none),
--      lineOf(profession name) -> skill line|nil,
--      recipes(line) -> { { id=, name=|nil, line=, item=id|false|nil, grey=|nil }, ... }
--        (item: Data.lua's recipe item or false; nil and grey nil for a recipe without Data.lua),
--      numItems(), itemInfo(i) -> C_MerchantFrame.GetItemInfo's table, itemID(i),
--      costCount(i), costItem(i, j) -> texture, value, link, name,
--      itemClass(itemID) -> classID|nil, dataItem(itemID) -> Data.lua has it as a recipe item.
-- onReading(npcID, reading) gets every reading that holds an entry.

local _, ns = ...
ns = ns or {}

local NpcReader = {}
ns.NpcReader = NpcReader

local floor, pairs, ipairs, next, select, sort, type, tostring = math.floor, pairs, ipairs, next, select, table.sort, type, tostring

NpcReader.DEBOUNCE = 0.5      -- a window is read this long after its last event
NpcReader.NAME_RETRY = 60     -- services of a profession with a nameless recipe are matched again then
NpcReader.ITEM_RETRY = 1      -- a merchant entry without its item or cost ID is read again then ...
NpcReader.ITEM_TRIES = 5      -- ... at most this many times
NpcReader.RECIPE_CLASS = 9    -- GetItemInfoInstant's classID of recipes
NpcReader.MAX_ID = 2147483647
NpcReader.MAX_COSTS = 3

-- Matching --------------------------------------------------------------------

-- Values of the match of a recipe, for the comparison of two services giving one recipe.
local function sameValues(a, b) return a.skill == b.skill and a.copper == b.copper end

-- One service among the recipes of its profession (design steps 1-4). Returns the recipe, or
-- false when it is not recorded, or "wait" while a recipe of the profession has no name.
local function matchOne(s, list, nameless)
	if s.spell then
		for _, r in ipairs(list) do
			if r.id == s.spell then return r end
		end
	end
	if nameless then return "wait" end
	if type(s.name) ~= "string" then return false end
	local named = {}
	for _, r in ipairs(list) do
		if r.name == s.name then named[#named + 1] = r end
	end
	if #named == 1 then return named[1] end
	if #named == 0 then return false end
	-- 3 and 4 only among recipes Data.lua has
	local known, noItem = {}, {}
	for _, r in ipairs(named) do
		if r.item ~= nil then
			known[#known + 1] = r
			if r.item == false then noItem[#noItem + 1] = r end
		end
	end
	if #noItem == 1 then return noItem[1] end
	local pool = #noItem > 0 and noItem or known
	if not s.skill then return false end
	local found
	for _, r in ipairs(pool) do
		if type(r.grey) == "number" and r.grey >= s.skill then
			if found then return false end
			found = r
		end
	end
	return found or false
end

-- services = { { name=, line=|nil, skill=|nil, copper=|nil, spell=|nil }, ... }
-- recipes  = { { id=, name=|nil, line=, item=id|false|nil, grey=|nil }, ... }
-- Returns { [recipeID] = { skill=, copper= } }, the number of services not recorded, and the
-- services left undecided because a recipe of their profession has no name yet.
function NpcReader.Match(services, recipes)
	local byLine, nameless = {}, {}
	for _, r in ipairs(recipes or {}) do
		if r.line ~= nil then
			byLine[r.line] = byLine[r.line] or {}
			local l = byLine[r.line]
			l[#l + 1] = r
			if r.name == nil then nameless[r.line] = true end
		end
	end
	local got, from, skipped, pending = {}, {}, 0, {}
	for _, s in ipairs(services or {}) do
		local r = s.line ~= nil and matchOne(s, byLine[s.line] or {}, nameless[s.line]) or false
		if r == "wait" then
			pending[#pending + 1] = s
		elseif not r then
			skipped = skipped + 1
		else
			local values = { skill = s.skill, copper = s.copper }
			local held = got[r.id]
			if held == nil then
				got[r.id], from[r.id] = values, { r = r, n = 1 }
			elseif held and sameValues(held, values) then
				from[r.id].n = from[r.id].n + 1
			else
				-- two services give one recipe different values: both out
				if held then skipped = skipped + from[r.id].n end
				skipped = skipped + 1
				got[r.id] = false
			end
		end
	end
	local out = {}
	for id, v in pairs(got) do
		if v then
			local grey = from[id].r.grey
			local skill = v.skill
			if skill and type(grey) == "number" and skill > grey then skill = nil end
			out[id] = { skill = skill, copper = v.copper }
		end
	end
	return out, skipped, pending
end

-- Reader ----------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

function NpcReader.New(api, onReading)
	return setmetatable({
		api = api, onReading = onReading,
		skipped = 0, skippedBy = {},  -- services not recorded, by NPC (its latest reading)
		held = {},                    -- [npcID] = { head, services } waiting for recipe names
		final = false,                -- the second try is over: nameless recipes are left out
		firstTry = nil, retrying = false,
	}, Reader)
end

-- Calls api[fn]; any secret return marks the current reading tainted and gives nothing.
function Reader:get(fn, ...)
	local f = self.api[fn]
	if type(f) ~= "function" then return nil end
	return self:clean(f(...))
end

function Reader:clean(...)
	local secret = self.api.secret
	if secret then
		for i = 1, select("#", ...) do
			if secret((select(i, ...))) then
				self.tainted = true
				return nil
			end
		end
	end
	return ...
end

-- The NPC ID of a creature from UnitGUID("npc"), or nil.
function Reader:npcID()
	local guid = self:get("npcGUID")
	if type(guid) ~= "string" then return nil end
	local id = tonumber(guid:match("^Creature%-[^%-]*%-[^%-]*%-[^%-]*%-[^%-]*%-(%d+)%-"))
	if not id or id < 1 or id > NpcReader.MAX_ID then return nil end
	return id
end

-- Name and place of the open NPC; a secret value there is simply left out.
function Reader:head()
	self.tainted = false
	local h = {}
	local name = self:get("npcName")
	if not self.tainted and type(name) == "string" and name ~= "" then h.name = name end
	self.tainted = false
	local map, x, y = self:get("place")
	if not self.tainted and type(map) == "number" and type(x) == "number" and type(y) == "number" then
		x, y = floor(x * 100), floor(y * 100)
		if map >= 0 and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
			h.map, h.x, h.y = map, x, y
		end
	end
	self.tainted = false
	return h
end

function Reader:busy()
	local f = self.api.inCombat
	return f and f() and true or false
end

-- Opens a window: the NPC and its place are taken now, the content DEBOUNCE seconds later.
function Reader:open(kind)
	self[kind] = nil
	if self:busy() then return nil end
	self.tainted = false
	local id = self:npcID()
	if not id or self.tainted then return nil end
	local st = { id = id, head = self:head(), tries = 0 }
	self[kind] = st
	return st
end

-- Reads st after delay, only while the same window of the same NPC is open and not in combat.
function Reader:schedule(kind, st, delay, read)
	if not st or st.pending then return end
	st.pending = true
	self.api.after(delay, function()
		st.pending = false
		if self[kind] ~= st or self:busy() then return end
		self.tainted = false
		if self:npcID() ~= st.id or self.tainted then return end
		read(self, st)
	end)
end

-- Trainer ---------------------------------------------------------------------

function Reader:TrainerShow()
	local st = self:open("trainer")
	if st then self:schedule("trainer", st, NpcReader.DEBOUNCE, Reader.readTrainer) end
end

function Reader:TrainerUpdate()
	self:schedule("trainer", self.trainer, NpcReader.DEBOUNCE, Reader.readTrainer)
end

function Reader:TrainerClosed() self.trainer = nil end

function Reader:readTrainer(st)
	if not self:get("tradeskillTrainer") or self.tainted then return end -- a class trainer
	self.tainted = false
	local n = self:get("numServices")
	if type(n) ~= "number" then return end
	local services, profs, nprof = {}, {}, 0
	for i = 1, n do
		local name, kind = self:get("serviceInfo", i)
		if kind ~= "header" then
			local prof, skill = self:get("serviceSkill", i)
			local copper = self:get("serviceCost", i)
			local spell = self:get("serviceSpell", i)
			local s = {
				name = type(name) == "string" and name or nil,
				prof = type(prof) == "string" and prof ~= "" and prof or nil,
				skill = type(skill) == "number" and skill >= 1 and floor(skill) or nil,
				copper = type(copper) == "number" and copper >= 1 and floor(copper) or nil,
				spell = type(spell) == "number" and spell or nil,
			}
			if s.prof and not profs[s.prof] then profs[s.prof] = true; nprof = nprof + 1 end
			services[#services + 1] = s
		end
	end
	if self.tainted then return end
	-- a service without requirement takes the only profession of the others, else it is left out
	local only = nprof == 1 and next(profs) or nil
	for _, s in ipairs(services) do
		s.prof = s.prof or only
		s.line = s.prof and self.api.lineOf(s.prof) or nil
	end
	if self.tainted then return end
	self:matchTrainer(st.id, st.head, services)
end

-- The recipes of the professions of services; after the second try without the nameless ones.
function Reader:recipesFor(services)
	local list, done = {}, {}
	for _, s in ipairs(services) do
		if s.line ~= nil and not done[s.line] then
			done[s.line] = true
			for _, r in ipairs(self.api.recipes(s.line) or {}) do
				if r.name ~= nil or not self.final then list[#list + 1] = r end
			end
		end
	end
	return list
end

function Reader:matchTrainer(id, head, services)
	local now = self.api.now()
	self.firstTry = self.firstTry or now
	local t, skipped, pending = NpcReader.Match(services, self:recipesFor(services))
	if #pending > 0 and not self.final then
		self.held[id] = { head = head, services = services }
		if not self.retrying then
			self.retrying = true
			local wait = self.firstTry + NpcReader.NAME_RETRY - now
			self.api.after(wait > 0 and wait or 0, function() self:secondTry() end)
		end
	end
	self.skippedBy[id] = skipped
	local sum = 0
	for _, k in pairs(self.skippedBy) do sum = sum + k end
	self.skipped = sum
	if next(t) == nil then return end
	self.onReading(id, { name = head.name, map = head.map, x = head.x, y = head.y, t = t, v = {} })
end

-- 60 s after the first try, window open or not: the held services are matched again; from now
-- until logout a recipe still without a name is left out.
function Reader:secondTry()
	self.final = true
	local held = self.held
	self.held = {}
	for id, h in pairs(held) do self:matchTrainer(id, h.head, h.services) end
end

-- Merchant --------------------------------------------------------------------

function Reader:MerchantShow()
	local st = self:open("merchant")
	if st then self:schedule("merchant", st, NpcReader.DEBOUNCE, Reader.readMerchant) end
end

function Reader:MerchantUpdate()
	self:schedule("merchant", self.merchant, NpcReader.DEBOUNCE, Reader.readMerchant)
end

function Reader:MerchantClosed() self.merchant = nil end

local function costLess(a, b)
	if a[1] ~= b[1] then return a[1] < b[1] end
	if a[2] ~= b[2] then return a[2] < b[2] end
	return a[3] < b[3]
end

local function samePrice(a, b)
	if not a or not b then return a == b end
	if a.c ~= b.c or a.l ~= b.l or #a.o ~= #b.o then return false end
	for i = 1, #a.o do
		if costLess(a.o[i], b.o[i]) or costLess(b.o[i], a.o[i]) then return false end
	end
	return true
end

local function validID(v) return type(v) == "number" and v >= 1 and v <= NpcReader.MAX_ID and v == floor(v) end

-- The other cost j of entry i as { kind, id, count }, nil while its ID or count is not known.
function Reader:cost(i, j)
	local _, value, link = self:get("costItem", i, j)
	if type(link) ~= "string" or not validID(value) then return nil end
	local id = tonumber(link:match("currency:(%d+)"))
	if id then return validID(id) and { 1, id, value } or nil end
	id = tonumber(link:match("item:(%d+)"))
	if id then return validID(id) and { 2, id, value } or nil end
	return nil
end

-- The price of entry i: a price table, false when it cannot be held (too many costs), nil when
-- something is not known yet.
function Reader:price(i, info)
	if type(info.price) ~= "number" or info.price < 0 then return nil end
	local stock = info.numAvailable
	local p = { c = floor(info.price), o = {}, l = (type(stock) == "number" and stock >= 0) and 1 or 0 }
	if info.hasExtendedCost then
		local k = self:get("costCount", i)
		if type(k) ~= "number" then return nil end
		for j = 1, k do
			local c = self:cost(i, j)
			if not c then return nil end
			p.o[#p.o + 1] = c
		end
		sort(p.o, costLess)
		if #p.o > NpcReader.MAX_COSTS then return false end
	end
	return p
end

function Reader:readMerchant(st)
	local n = self:get("numItems")
	if type(n) ~= "number" then return end
	local v, incomplete = {}, false
	for i = 1, n do
		local id = self:get("itemID", i)
		local info = self:get("itemInfo", i)
		if type(info) == "table" then info = { self:clean(info.price, info.numAvailable, info.hasExtendedCost) } end
		if self.tainted then return end
		if not validID(id) or type(info) ~= "table" then
			incomplete = true
		else
			info = { price = info[1], numAvailable = info[2], hasExtendedCost = info[3] }
			local class = self:get("itemClass", id)
			if class == NpcReader.RECIPE_CLASS or self:get("dataItem", id) then
				local p = self:price(i, info)
				if self.tainted then return end
				if p == nil then
					incomplete = true -- never recorded in part
				else
					local e = v[id]
					if e == nil then
						v[id] = { price = p or nil }
					elseif not samePrice(e.price, p or nil) then
						v[id] = {} -- two entries of one item that differ: seen only
					end
				end
			end
		end
	end
	if self.tainted then return end
	if incomplete and st.tries < NpcReader.ITEM_TRIES then
		st.tries = st.tries + 1
		self:schedule("merchant", st, NpcReader.ITEM_RETRY, Reader.readMerchant)
		return
	end
	if next(v) == nil then return end -- a merchant that sells no recipe makes no sheet
	local h = st.head
	self.onReading(st.id, { name = h.name, map = h.map, x = h.x, y = h.y, t = {}, v = v })
end

NpcReader.internal = { matchOne = matchOne, Reader = Reader }
