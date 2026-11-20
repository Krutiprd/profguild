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

-- Name of the price source, or nil when none is installed.
function Prices.Source()
	if auctionator() then return "Auctionator" end
	if tsm() then return "TSM" end
end

-- Price of one item in copper and where it comes from ("ah" or "vendor"), or nil.
-- For an auction price, the third value is its age in days when Auctionator knows it.
function Prices.Get(itemID)
	if type(itemID) ~= "number" then return nil end
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

-- Cost of one craft: total copper of the reagents that have a price, and how many have none.
function Prices.Cost(reagents)
	local total, missing = 0, 0
	for itemID, count in pairs(reagents or {}) do
		local price = Prices.Get(itemID)
		if price then total = total + price * count else missing = missing + 1 end
	end
	return total, missing
end

-- The item that teaches a recipe and how it is obtained, from Data.lua (Wowhead):
-- itemID, source letters ("d" looted, "v" sold by NPCs, "q" quest, "c" crafted).
-- false: Wowhead lists no such item (a trainer recipe or similar). nil: not in Data.lua.
function Prices.RecipeItem(recipeID)
	local seen = ns.db and ns.db.recipeItems and ns.db.recipeItems[recipeID]
	local e = ns.RecipeData and ns.RecipeData[recipeID]
	if seen then
		-- found on the auction house (Prices.IndexRecipeItems); the source only Wowhead knows
		local src = type(e) == "table" and e[1] == seen and type(e[2]) == "string" and e[2] or ""
		return seen, src
	end
	if e == false then return false end
	if type(e) == "table" and type(e[1]) == "number" then return e[1], type(e[2]) == "string" and e[2] or "" end
	return nil
end

-- How many of an item were on the market: Auctionator keeps the highest quantity it saw on each
-- day of a scan or search. Returns that count for the latest day it has, or nil.
function Prices.Available(itemID)
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
-- apart without asking the server; the names are loaded through the item queue, and every
-- call matches the names that have arrived. Found items go to ProfguildDB.recipeItems.
local RECIPE_CLASS = 9
local SUBCLASS_SKILL = { [1] = 165, [2] = 197, [3] = 202, [4] = 164, [5] = 185, [6] = 171, [7] = 129, [8] = 333, [9] = 356 }
local REINDEX = 300 -- seconds: newer scans add items to the auction database
local pending, byName, indexedAt, indexedRevision = {}, {}, nil, nil

local function norm(s)
	return (s:lower():gsub("[^%w]", ""))
end

function Prices.IndexRecipeItems()
	local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
	if type(adb) ~= "table" or not ns.catalog or not ns.db then return 0 end
	ns.db.recipeItems = ns.db.recipeItems or {}
	local now = GetTime()
	if indexedRevision ~= ns.catalog.revision or not indexedAt or now - indexedAt > REINDEX then
		indexedRevision, indexedAt = ns.catalog.revision, now
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
		pending = {}
		local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
		local known = {}
		for _, itemID in pairs(ns.db.recipeItems) do known[itemID] = true end
		for key in pairs(adb) do
			local itemID = tonumber(key)
			if itemID and not known[itemID] and type(getInstant) == "function" then
				local ok, id, _, _, _, _, classID, subclassID = pcall(getInstant, itemID)
				if ok and id and classID == RECIPE_CLASS and SUBCLASS_SKILL[subclassID] and byName[SUBCLASS_SKILL[subclassID]] then
					pending[itemID] = SUBCLASS_SKILL[subclassID]
				end
			end
		end
	end
	local found = 0
	for itemID, skillLine in pairs(pending) do
		local name = ns.Scanner.ItemName(itemID) -- not loaded yet: queued, matched on a later call
		if name then
			pending[itemID] = nil
			local base = name:match("^[^:]+:%s*(.+)$")
			for _, recipeID in ipairs(base and byName[skillLine][norm(base)] or {}) do
				if ns.db.recipeItems[recipeID] ~= itemID then
					ns.db.recipeItems[recipeID] = itemID
					found = found + 1
				end
			end
		end
	end
	return found
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
