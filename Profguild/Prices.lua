-- Profguild: Prices
-- Reads item prices from Auctionator (last auction house scan, then the vendor price it has
-- seen) or from TradeSkillMaster (DBMarket). Both are optional; without them no prices are
-- shown. Builds Auctionator shopping lists for the reagents of a recipe.

local _, ns = ...
ns = ns or {}

local Prices = {}
ns.Prices = Prices

Prices.CALLER = "Profguild"

local function auctionator()
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if type(api) == "table" and type(api.GetAuctionPriceByItemID) == "function" then return api end
end

local function tsm()
	if type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function" then return TSM_API end
end

local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a = pcall(fn, ...)
	if ok and type(a) == "number" and a > 0 then return a end
end

-- Name of the price source, or nil when there is none. Without Auctionator or TSM the prices
-- shared by guildmates are a source too.
function Prices.Source()
	if auctionator() then return "Auctionator" end
	if tsm() then return "TSM" end
	if ns.guildPrices and ns.guildPrices:Count() > 0 then return "Guild" end
end

-- Price from the addons of this client: Auctionator (auction, then vendor), then TSM.
local function localPrice(itemID)
	local api = auctionator()
	if api then
		local price = call(api.GetAuctionPriceByItemID, Prices.CALLER, itemID)
		if price then
			-- age 0 (seen in today's scan) is a valid answer, so not through call()
			local okAge, age = pcall(api.GetAuctionAgeByItemID, Prices.CALLER, itemID)
			return price, "ah", (okAge and type(age) == "number" and age >= 0) and age or nil
		end
		price = call(api.GetVendorPriceByItemID, Prices.CALLER, itemID)
		if price then return price, "vendor" end
	end
	local t = tsm()
	if t then
		local price = call(t.GetCustomPriceValue, "DBMarket", "i:" .. itemID)
		if price then return price, "ah" end
	end
	return nil
end

local function serverTime()
	local ok, t = pcall(GetServerTime)
	return ok and type(t) == "number" and t or 0
end

-- When this client's own auction price of an item was read, as server time. Auctionator keeps
-- only the day (its scan days start at local midnight, Constants.SCAN_DAY_0), so it is the
-- start of the newest day it has; without that, a whole day before its age.
local function localTime(itemID, age)
	local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
	local e = type(adb) == "table" and adb[tostring(itemID)]
	local day0 = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
	if type(e) == "table" and type(e.h) == "table" and type(day0) == "number" then
		local last
		for day in pairs(e.h) do
			local d = tonumber(day)
			if d and (not last or d > last) then last = d end
		end
		if last then return day0 + last * 86400 end
	end
	return serverTime() - ((age or 0) + 1) * 86400
end

-- The guild's price of an item when it is newer than this client's own auction price. Our own
-- reading in the guild table (w = us) is the price Auctionator holds now: never replaced by it.
local function guildNewer(itemID, kind, age)
	local e = ns.guildPrices and ns.guildPrices:Get(itemID)
	if not e then return nil end
	if kind ~= "ah" then return e end
	if e.w == (UnitGUID and UnitGUID("player")) then return nil end
	if e.t > localTime(itemID, age) then return e end
end

-- Price of one item in copper and where it comes from ("ah" or "vendor"), or nil.
-- For an auction price, the third value is its age in days when it is known. A fourth value
-- is the guild price entry { p, n, t, w } when a guildmate's newer price was taken.
function Prices.Get(itemID)
	if type(itemID) ~= "number" then return nil end
	local price, kind, age = localPrice(itemID)
	local e = guildNewer(itemID, kind, age)
	if e then
		return e.p, "ah", math.max(0, math.floor((serverTime() - e.t) / 86400)), e
	end
	return price, kind, age
end

-- The auction house keeps this share of every sale (5 % on Classic).
Prices.AH_CUT = 0.05

-- What a sale of `price` copper brings in: an auction price minus the auction house cut, a
-- sale to a vendor as it is (a vendor takes no cut).
function Prices.AfterCut(price, source)
	if source == "vendor" then return price end
	return math.floor(price * (1 - Prices.AH_CUT))
end

-- What a crafted item sells for and where: the auction price ("ah"), else what a vendor pays
-- for it ("vendor", the sell price from the game). Not Auctionator's vendor price: that is what
-- a merchant asks, not what one pays.
function Prices.SaleValue(itemID)
	local price, kind, age, e = Prices.Get(itemID)
	if price and kind ~= "vendor" then return price, kind, age, e end
	-- Auctionator knew only a merchant price: TSM may still have an auction value
	local t = tsm()
	if t and type(itemID) == "number" then
		price = call(t.GetCustomPriceValue, "DBMarket", "i:" .. itemID)
		if price then return price, "ah" end
	end
	price = Prices.SellPrice(itemID)
	if price then return price, "vendor" end
	return nil
end

-- What a vendor pays for one item (the game's sell price), or nil when the game has none or has
-- not loaded the item.
function Prices.SellPrice(itemID)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if type(itemID) ~= "number" or type(getInfo) ~= "function" then return nil end
	local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(getInfo, itemID)
	if ok and name and type(sellPrice) == "number" and sellPrice > 0 then return sellPrice end
	return nil
end

-- What a vendor asks for the item (seen at a merchant by Auctionator), or nil. Shown beside the
-- auction price of a reagent; the cost of a craft counts the auction price first (Prices.Get).
function Prices.VendorPrice(itemID)
	if type(itemID) ~= "number" then return nil end
	local api = auctionator()
	if api then return call(api.GetVendorPriceByItemID, Prices.CALLER, itemID) end
end

-- Cost of one craft: total copper of the reagents that have a price, and how many have none.
function Prices.Cost(reagents)
	local total, missing = 0, 0
	for itemID, count in pairs(reagents or {}) do
		local price = Prices.Get(itemID)
		if price then total = total + price * count else missing = missing + 1 end
	end
	return total, missing
end

-- The item that teaches a recipe and how it is obtained, from Data.lua (client data, Wowhead):
-- itemID, source letters ("d" looted, "v" sold by NPCs, "q" quest, "c" crafted).
-- false: no item teaches it (a trainer recipe or similar). nil: not in Data.lua.
function Prices.RecipeItem(recipeID)
	local seen = ns.db and ns.db.recipeItems and ns.db.recipeItems[recipeID]
	local e = ns.RecipeData and ns.RecipeData[recipeID]
	if seen then
		-- found on the auction house (Prices.IndexRecipeItems); the source only Wowhead knows
		local src = type(e) == "table" and e[1] == seen and type(e[2]) == "string" and e[2] or ""
		return seen, src
	end
	if e == false or (type(e) == "table" and e[1] == false) then return false end
	if type(e) == "table" and type(e[1]) == "number" then return e[1], type(e[2]) == "string" and e[2] or "" end
	return nil
end

-- Skill levels of a recipe from Data.lua (the client's tables): learn (orange from there; nil for
-- trainer recipes, the client does not know it), yellow, green, grey. nil when Data.lua lacks them.
function Prices.RecipeSkill(recipeID)
	local e = ns.RecipeData and ns.RecipeData[recipeID]
	if type(e) ~= "table" or type(e[4]) ~= "number" or type(e[5]) ~= "number" then return nil end
	local learn = type(e[3]) == "number" and e[3] > 0 and e[3] or nil
	local yellow = math.min(e[4], e[5]) -- the client has a recipe with yellow above grey
	return learn, yellow, math.floor((yellow + e[5]) / 2), e[5]
end

-- How many of an item were on the market: Auctionator keeps the highest quantity it saw on each
-- day of a scan or search. Returns that count for the latest day it has, or nil.
local function localAvailable(itemID)
	local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
	local e = type(adb) == "table" and itemID and adb[tostring(itemID)]
	if type(e) ~= "table" or type(e.a) ~= "table" then return nil end
	local lastDay, count
	for day, n in pairs(e.a) do
		local d = tonumber(day)
		if d and type(n) == "number" and (not lastDay or d > lastDay) then lastDay, count = d, n end
	end
	return count
end

-- How many were on the market, from the guild when its price is the one shown.
function Prices.Available(itemID)
	local _, _, _, e = Prices.Get(itemID)
	if e then return e.n > 0 and e.n or nil end
	return localAvailable(itemID)
end

-- "from Ana, 2 h ago" for a guildmate's price entry.
function Prices.FromText(e)
	if type(e) ~= "table" then return nil end
	local name = ns.MemberName and ns.MemberName(e.w) or "?"
	return ns.T("PRICE_FROM", name, Prices.AgoText(e.t))
end

-- "2 h ago" for a server time.
function Prices.AgoText(t)
	local secs = math.max(0, serverTime() - t)
	if secs < 3600 then return ns.T("AGO_MIN", math.max(1, math.floor(secs / 60))) end
	if secs < 86400 then return ns.T("AGO_HOURS", math.floor(secs / 3600)) end
	return ns.T("DAYS_AGO", math.floor(secs / 86400))
end

---------------------------------------------------------------------------
-- Sharing with the guild (GuildPrices.lua)
---------------------------------------------------------------------------

-- Items Profguild needs prices of: reagents, crafted items and recipe items. Kept until the
-- data changes (ns.OnDataChanged) or INTEREST_TTL seconds pass, since every price asks it.
Prices.INTEREST_TTL = 30
local interest, interestAt, interestRevision = nil, nil, nil
function Prices.InvalidateInterest()
	interest = nil
end

function Prices.InterestItems()
	local revision = ns.catalog and ns.catalog.revision
	if interest and interestRevision == revision and GetTime() - interestAt < Prices.INTEREST_TTL then
		return interest
	end
	local items = {}
	local function add(id) if type(id) == "number" and id > 0 then items[id] = true end end
	for _, reagents in pairs(ns.db and ns.db.reagents or {}) do
		if type(reagents) == "table" then for itemID in pairs(reagents) do add(itemID) end end
	end
	if ns.catalog then
		for _, list in pairs(ns.catalog:All()) do
			for _, itemID in pairs(list) do add(itemID) end
		end
	end
	for _, itemID in pairs(ns.db and ns.db.recipeItems or {}) do add(itemID) end
	for _, e in pairs(ns.RecipeData or {}) do
		if type(e) == "table" then add(e[1]) end
	end
	interest, interestAt, interestRevision = items, GetTime(), revision
	return items
end

function Prices.IsInteresting(itemID)
	return Prices.InterestItems()[itemID] == true
end

-- What one reading of Auctionator holds: { [dbKey] = { { price, available }, ... } }, the table
-- its Database:ProcessScan gets from a search or a full scan. Auctionator takes the lowest price
-- and the sum of the pieces (Database/Mixin.lua); the same is taken here, for plain item keys of
-- items Profguild needs. Returns { [itemID] = { p, n } }.
function Prices.ReadingOf(itemIndexes)
	local reads = {}
	if type(itemIndexes) ~= "table" then return reads end
	local wanted = Prices.InterestItems()
	for key, list in pairs(itemIndexes) do
		local itemID = type(key) == "string" and key:find("^%d+$") and tonumber(key)
		if itemID and wanted[itemID] and type(list) == "table" and list[1] then
			local minPrice, pieces = nil, 0
			for _, info in ipairs(list) do
				if type(info) == "table" and type(info.price) == "number" then
					if not minPrice or info.price < minPrice then minPrice = info.price end
					if type(info.available) == "number" then pieces = pieces + info.available end
				end
			end
			if minPrice then reads[itemID] = { p = math.floor(minPrice), n = pieces } end
		end
	end
	return reads
end

Prices.READ_DELAY = 0.5 -- readings of searches right after each other go out together
local pendingReads, readTimer = {}, false

-- Takes one reading of Auctionator for the guild.
function Prices.OnReading(itemIndexes)
	if not ns.guildPrices then return end
	for itemID, v in pairs(Prices.ReadingOf(itemIndexes)) do pendingReads[itemID] = v end
	if readTimer or not next(pendingReads) then return end
	readTimer = true
	C_Timer.After(Prices.READ_DELAY, function()
		readTimer = false
		local reads = pendingReads
		pendingReads = {}
		if ns.guildPrices then ns.guildPrices:Record(reads) end
	end)
end

-- Follows every reading of Auctionator (searches and full scans go through ProcessScan). The
-- hook only looks at the table it is given; Auctionator's own work is never touched.
local hookedDB = nil
function Prices.StartSharing()
	local db = Auctionator and Auctionator.Database
	if type(db) ~= "table" or type(db.ProcessScan) ~= "function" then return false end
	if hookedDB == db then return true end
	hookedDB = db
	local function after(_, itemIndexes)
		local ok, err = pcall(Prices.OnReading, itemIndexes)
		if not ok and ns.Log then ns.Log("ERROR price reading: %s", tostring(err)) end
	end
	if type(hooksecurefunc) == "function" and not Prices.TEST_NO_HOOK then
		hooksecurefunc(db, "ProcessScan", after)
	else
		local original = db.ProcessScan
		db.ProcessScan = function(self, itemIndexes, ...)
			after(self, itemIndexes)
			return original(self, itemIndexes, ...)
		end
	end
	return true
end

Prices.REFRESH_LISTEN = 60 -- seconds the window follows Auctionator after a refresh

-- True while the auction house is open and Auctionator can search it for us.
function Prices.CanRefresh()
	local api = auctionator()
	if not api or type(api.MultiSearchExact) ~= "function" then return false end
	local ah = (AuctionFrame and AuctionFrame:IsShown()) or (AuctionHouseFrame and AuctionHouseFrame:IsShown())
	return ah and true or false
end

-- Asks Auctionator to search the open auction house for these items by exact name. The legacy
-- auction house of Auctionator saves the prices it finds, so Prices.Get returns them afterwards;
-- onDone runs when Auctionator says the prices are processed. Returns the number of items
-- searched, or false and a reason ("closed", "names", "error").
function Prices.Refresh(itemIDs, onDone)
	if not Prices.CanRefresh() then return false, "closed" end
	local names, seen = {}, {}
	for _, itemID in ipairs(itemIDs) do
		if itemID and itemID > 0 and not seen[itemID] then
			seen[itemID] = true
			local name = ns.Scanner and ns.Scanner.ItemName(itemID)
			if not name then return false, "names" end
			names[#names + 1] = name
		end
	end
	if #names == 0 then return false, "error" end
	local bus = Auctionator.EventBus
	local event = Auctionator.Search and Auctionator.Search.Events and Auctionator.Search.Events.PricesProcessed
	-- Auctionator says "processed" once per searched item, and saves the prices a frame later
	-- (ProcessScan runs on a ticker): listen to every notice for a while, onDone waits a moment
	if onDone and bus and event and type(bus.Register) == "function" then
		if Prices.refreshListener then pcall(bus.Unregister, bus, Prices.refreshListener, { event }) end
		local listener = {}
		function listener:ReceiveEvent() onDone() end
		Prices.refreshListener = listener
		pcall(bus.Register, bus, listener, { event })
		C_Timer.After(Prices.REFRESH_LISTEN, function()
			if Prices.refreshListener == listener then
				pcall(bus.Unregister, bus, listener, { event })
				Prices.refreshListener = nil
			end
		end)
	end
	local ok = pcall(auctionator().MultiSearchExact, Prices.CALLER, names)
	if not ok then return false, "error" end
	return #names
end

-- Recipe items Auctionator has seen at the auction house, matched to the recipe catalog by
-- name ("Pattern: Big Voodoo Robe" teaches "Big Voodoo Robe"). The item class tells recipes
-- apart without asking the server. The auction database can hold tens of thousands of items,
-- so StartRecipeIndex walks it a few hundred keys per frame, never inside a redraw. The names
-- are loaded through the item queue; ResolveRecipeItems matches the ones that have arrived.
-- Found items go to ProfguildDB.recipeItems.
local RECIPE_CLASS = 9
local SUBCLASS_SKILL = { [1] = 165, [2] = 197, [3] = 202, [4] = 164, [5] = 185, [6] = 171, [7] = 129, [8] = 333, [9] = 356 }
Prices.REINDEX = 300      -- seconds before the auction database is walked again
Prices.INDEX_STEP = 400   -- auction database keys per frame
local pending, byName, indexedAt, indexedRevision, indexing = {}, {}, nil, nil, false

local function norm(s)
	return (s:lower():gsub("[^%w]", ""))
end

local function auctionDB()
	local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
	if type(adb) ~= "table" or not ns.catalog or not ns.db then return nil end
	ns.db.recipeItems = ns.db.recipeItems or {}
	return adb
end

local function buildNames()
	byName = {}
	for skillLine, list in pairs(ns.catalog:All()) do
		local names = {}
		for recipeID in pairs(list) do
			local name = ns.Scanner.RecipeName(recipeID)
			if name then
				local key = norm(name)
				names[key] = names[key] or {}
				table.insert(names[key], recipeID)
			end
		end
		byName[skillLine] = names
	end
end

local getInstant = function(...)
	local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	if type(fn) ~= "function" then return false end
	return pcall(fn, ...)
end

-- One auction database key: a recipe item of a profession in the catalog becomes pending.
local function consider(key, known)
	local itemID = tonumber(key)
	if not itemID or known[itemID] then return end
	local ok, id, _, _, _, _, classID, subclassID = getInstant(itemID)
	local skillLine = ok and id and classID == RECIPE_CLASS and SUBCLASS_SKILL[subclassID]
	if skillLine and byName[skillLine] then pending[itemID] = skillLine end
end

local function knownItems()
	local known = {}
	for _, itemID in pairs(ns.db.recipeItems) do known[itemID] = true end
	return known
end

-- Matches the pending recipe items whose names have arrived. Returns the number of new matches.
function Prices.ResolveRecipeItems()
	if not ns.db or not ns.db.recipeItems then return 0 end
	local found = 0
	for itemID, skillLine in pairs(pending) do
		local name = ns.Scanner.ItemName(itemID) -- not loaded yet: queued, matched on a later call
		if name then
			pending[itemID] = nil
			local base = name:match("^[^:]+:%s*(.+)$")
			for _, recipeID in ipairs(base and byName[skillLine] and byName[skillLine][norm(base)] or {}) do
				if ns.db.recipeItems[recipeID] ~= itemID then
					ns.db.recipeItems[recipeID] = itemID
					found = found + 1
				end
			end
		end
	end
	if found > 0 then
		ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
		if ns.OnDataChanged then ns.OnDataChanged() end
	end
	return found
end

-- Walks the whole auction database at once (tests, small databases). Returns new matches.
function Prices.IndexRecipeItems()
	local adb = auctionDB()
	if not adb then return 0 end
	indexedRevision, indexedAt = ns.catalog.revision, GetTime()
	buildNames()
	pending = {}
	local known = knownItems()
	for key in pairs(adb) do consider(key, known) end
	return Prices.ResolveRecipeItems()
end

-- Walks the auction database in steps when the catalog changed, the last walk is older than
-- REINDEX seconds, or force (the auction house just closed: a scan may have added items).
local indexAgain = false
function Prices.StartRecipeIndex(force)
	local adb = auctionDB()
	if not adb then return false end
	if indexing then
		-- the auction house closed during a walk: walk again when this one ends
		if force then indexAgain = true end
		return false
	end
	local now = GetTime()
	if not force and indexedRevision == ns.catalog.revision and indexedAt and now - indexedAt < Prices.REINDEX then
		return false
	end
	local ok, keys = pcall(function()
		buildNames()
		local list = {}
		for key in pairs(adb) do list[#list + 1] = key end
		return list
	end)
	if not ok then
		if ns.Log then ns.Log("ERROR recipe index: %s", tostring(keys)) end
		return false
	end
	indexing = true
	indexedRevision, indexedAt = ns.catalog.revision, now
	local known, newPending, i = knownItems(), {}, 1
	local function finish()
		indexing = false
		if indexAgain then
			indexAgain = false
			Prices.StartRecipeIndex(true)
		end
	end
	local function step()
		local okStep, err = pcall(function()
			local last = math.min(#keys, i + Prices.INDEX_STEP - 1)
			local saved = pending
			pending = newPending
			for k = i, last do consider(keys[k], known) end
			newPending, pending = pending, saved
			i = last + 1
		end)
		if not okStep then
			if ns.Log then ns.Log("ERROR recipe index: %s", tostring(err)) end
			return finish()
		end
		if i <= #keys then
			C_Timer.After(0, step)
		else
			pending = newPending
			finish()
			Prices.ResolveRecipeItems()
		end
	end
	C_Timer.After(0, step)
	return true
end

-- "12g 3s 40c" with the usual coin colours.
function Prices.Format(copper)
	if not copper then return "-" end
	copper = math.floor(copper + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = string.format("|cffffd700%d|rg", g) end
	if s > 0 or g > 0 then parts[#parts + 1] = string.format("|cffc7c7cf%d|rs", s) end
	parts[#parts + 1] = string.format("|cffeda55f%d|rc", c)
	return table.concat(parts, " ")
end

-- Short signed amount for the recipe list: "+12g", "-35s", "+8c" (only the largest coin).
function Prices.Short(copper)
	if not copper then return "" end
	copper = math.floor(copper + 0.5)
	local sign, a = copper < 0 and "-" or "+", math.abs(copper)
	if a >= 10000 then return sign .. math.floor(a / 10000) .. "g" end
	if a >= 100 then return sign .. math.floor(a / 100) .. "s" end
	return sign .. a .. "c"
end

local function itemName(itemID)
	return ns.Scanner and ns.Scanner.ItemName(itemID)
end

-- True when Auctionator can take a shopping list.
function Prices.CanShop()
	local api = auctionator()
	return api and type(api.CreateShoppingList) == "function" and type(api.ConvertToSearchString) == "function" or false
end

-- Creates (or replaces) the Auctionator shopping list "Profguild: <name>" with every reagent
-- as an exact search and the needed quantity. At the auction house Auctionator starts the
-- search right away. Returns true, or false and a reason ("no auctionator", "names", "error").
function Prices.ShoppingList(name, reagents, crafts)
	local api = auctionator()
	if not Prices.CanShop() then return false, "no auctionator" end
	crafts = crafts or 1
	local ids = {}
	for itemID in pairs(reagents or {}) do ids[#ids + 1] = itemID end
	table.sort(ids)
	local terms = {}
	for _, itemID in ipairs(ids) do
		local itemNameText = itemName(itemID)
		if not itemNameText then return false, "names" end -- item data not loaded yet
		local ok, term = pcall(api.ConvertToSearchString, Prices.CALLER,
			{ searchString = itemNameText, isExact = true, quantity = reagents[itemID] * crafts })
		if not ok or type(term) ~= "string" then return false, "error" end
		terms[#terms + 1] = term
	end
	if #terms == 0 then return false, "error" end
	local ok = pcall(api.CreateShoppingList, Prices.CALLER, "Profguild: " .. name, terms)
	if not ok then return false, "error" end
	return true
end

return Prices
