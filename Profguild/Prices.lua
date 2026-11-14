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
		if price then return price, "ah", call(api.GetAuctionAgeByItemID, Prices.CALLER, itemID) end
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
