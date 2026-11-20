-- Profguild: Scanner
-- Reads the player's own professions, recipes and guild roster from the game API.
-- Every call that might not exist on WoW Forever is guarded, and /pg debug reports
-- what each API path really returned.

local _, ns = ...

local Scanner = {}
ns.Scanner = Scanner

local C_TradeSkillUI = C_TradeSkillUI

-- English fallback names for the classic skill lines (used only when the client
-- cannot name a profession, e.g. one learned by a guildmate on another character).
Scanner.FALLBACK_NAMES = {
	[171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering",
	[182] = "Herbalism", [165] = "Leatherworking", [186] = "Mining", [393] = "Skinning",
	[197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [356] = "Fishing",
}

local function call(fn, ...)
	if type(fn) ~= "function" then return false end
	return pcall(fn, ...)
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

local profNameCache = {}

function Scanner.ProfessionName(skillLine)
	local cached = profNameCache[skillLine]
	if cached then return cached end
	local name
	if C_TradeSkillUI then
		local ok, info = call(C_TradeSkillUI.GetProfessionInfoBySkillLineID, skillLine)
		if ok and type(info) == "table" then
			name = info.parentProfessionName ~= "" and info.parentProfessionName or info.professionName
		end
		if (not name or name == "") then
			local ok2, n2 = call(C_TradeSkillUI.GetTradeSkillDisplayName, skillLine)
			if ok2 and type(n2) == "string" then name = n2 end
		end
	end
	if not name or name == "" then
		name = Scanner.FALLBACK_NAMES[skillLine] or ("#" .. tostring(skillLine))
	end
	profNameCache[skillLine] = name
	return name
end

function Scanner.RecipeName(recipeID)
	local name
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = call(C_Spell.GetSpellName, recipeID)
		if ok then name = n end
	end
	if not name and GetSpellInfo then
		local ok, n = call(GetSpellInfo, recipeID)
		if ok then name = n end
	end
	return name
end

-- Item data the client has not loaded is asked from the server through a queue: at most
-- ITEM_BATCH requests every ITEM_PACE seconds, because the server drops requests that come in
-- a flood (a list of a thousand catalog recipes asks for a thousand items). Items on screen go
-- first (urgent), and an item that did not arrive is asked for again after ITEM_RETRY seconds.
Scanner.ITEM_BATCH, Scanner.ITEM_PACE, Scanner.ITEM_RETRY = 20, 0.5, 10
local itemQueue, itemQueued, itemAsked, itemPumping = {}, {}, {}, false

local function itemLoaded(itemID)
	if C_Item and C_Item.IsItemDataCachedByID then
		local ok, cached = call(C_Item.IsItemDataCachedByID, itemID)
		if ok then return cached and true or false end
	end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local ok, name = call(getInfo, itemID)
	return ok and name ~= nil
end

local function pumpItems()
	local sent = 0
	while #itemQueue > 0 and sent < Scanner.ITEM_BATCH do
		local itemID = table.remove(itemQueue, 1)
		itemQueued[itemID] = nil
		if not itemLoaded(itemID) then
			call(C_Item.RequestLoadItemDataByID, itemID)
			itemAsked[itemID] = GetTime()
			sent = sent + 1
		end
	end
	if #itemQueue > 0 then
		C_Timer.After(Scanner.ITEM_PACE, pumpItems)
	else
		itemPumping = false
	end
end

-- True when the addon asked the server for this item (queued or requested).
function Scanner.WasAsked(itemID)
	return itemID ~= nil and (itemAsked[itemID] ~= nil or itemQueued[itemID] ~= nil)
end

-- The item arrived: forget the request (keeps the table small over a long session).
function Scanner.Arrived(itemID)
	if itemID and not itemQueued[itemID] then itemAsked[itemID] = nil end
end

function Scanner.WantItem(itemID, urgent)
	if not itemID or itemID == 0 or not (C_Item and C_Item.RequestLoadItemDataByID) then return end
	local asked = itemAsked[itemID]
	if asked and GetTime() - asked < Scanner.ITEM_RETRY then return end
	if itemQueued[itemID] then
		if not urgent then return end
		for i, id in ipairs(itemQueue) do if id == itemID then table.remove(itemQueue, i) break end end
	elseif itemLoaded(itemID) then
		return
	end
	itemQueued[itemID] = true
	if urgent then table.insert(itemQueue, 1, itemID) else itemQueue[#itemQueue + 1] = itemID end
	if not itemPumping then
		itemPumping = true
		C_Timer.After(0, pumpItems)
	end
end

-- noRequest: only what the client has; used while building lists of thousands of recipes,
-- where only the rows on screen ask the server (through the item queue).
function Scanner.ItemName(itemID, noRequest)
	if not itemID or itemID == 0 then return nil end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local ok, name = call(getInfo, itemID)
	if ok and name then return name end
	if not noRequest then Scanner.WantItem(itemID) end
	return nil
end

-- What kind of item a recipe makes: { classID, subclassID, class, subclass, slot }, or nil when
-- the client does not know the item. GetItemInfoInstant reads the client's own item data
-- without asking the server, so it works for every guildmate's recipe and never loads items.
local itemClassCache = {}

function Scanner.ItemClass(itemID)
	if not itemID or itemID == 0 then return nil end
	local cached = itemClassCache[itemID]
	if cached then return cached end
	local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
	local ok, id, itemType, itemSubType, equipLoc, _, classID, subclassID = call(getInstant, itemID)
	if not ok or not id or type(classID) ~= "number" then return nil end
	cached = {
		classID = classID, subclassID = type(subclassID) == "number" and subclassID or 0,
		class = type(itemType) == "string" and itemType or "",
		subclass = type(itemSubType) == "string" and itemSubType or "",
		slot = type(equipLoc) == "string" and equipLoc or "",
	}
	itemClassCache[itemID] = cached
	return cached
end

-- Item level and required level of an item, or nil while the client does not have the item.
-- Unlike the item class this needs the item loaded: a missing item is requested from the
-- server through the item queue, and GET_ITEM_INFO_RECEIVED then rebuilds the list.
local itemLevelCache = {}

function Scanner.ItemLevel(itemID, noRequest)
	if not itemID or itemID == 0 then return nil end
	local cached = itemLevelCache[itemID]
	if cached then return cached.ilvl, cached.req end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local ok, name, _, _, itemLevel, minLevel = call(getInfo, itemID)
	if ok and name and type(itemLevel) == "number" then
		cached = { ilvl = itemLevel, req = type(minLevel) == "number" and minLevel or 0 }
		itemLevelCache[itemID] = cached
		return cached.ilvl, cached.req
	end
	if not noRequest then Scanner.WantItem(itemID) end
	return nil
end

-- True when an item binds on pickup (or is a quest item): it cannot be sold at the auction
-- house. nil while the client has not loaded the item (it is requested by ItemLevel).
local bindCache = {}
function Scanner.ItemBoP(itemID)
	if not itemID or itemID == 0 then return nil end
	if bindCache[itemID] ~= nil then return bindCache[itemID] end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local ok, name, _, _, _, _, _, _, _, _, _, _, _, _, bindType = call(getInfo, itemID)
	if not ok or not name or type(bindType) ~= "number" then return nil end
	bindCache[itemID] = bindType == 1 or bindType == 4
	return bindCache[itemID]
end

---------------------------------------------------------------------------
-- Character identity
---------------------------------------------------------------------------

function Scanner.PlayerIdentity()
	local guid = UnitGUID("player")
	local name = UnitName("player")
	local _, classFile = UnitClass("player")
	return guid, name, classFile
end

---------------------------------------------------------------------------
-- Professions and skill
---------------------------------------------------------------------------

-- Returns the base skill line of a profession (parent if the client splits professions into tiers).
local function baseSkillLine(id)
	if not id or id <= 0 then return nil end
	if C_TradeSkillUI then
		local ok, info = call(C_TradeSkillUI.GetProfessionInfoBySkillLineID, id)
		if ok and type(info) == "table" and info.parentProfessionID and info.parentProfessionID > 0 then
			return info.parentProfessionID
		end
	end
	return id
end

-- snap.ok is true only when at least one API path answered without error.
-- A character without professions is valid; a broken API is not.
function Scanner.Snapshot()
	local guid, name, classFile = Scanner.PlayerIdentity()
	local snap = { guid = guid, name = name, class = classFile, ok = false, profs = {}, sources = {} }

	-- Path 1: GetProfessions / GetProfessionInfo (modern client)
	if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
		local ok, err = pcall(function()
			local list = { GetProfessions() }
			for i = 1, 8 do
				local idx = list[i]
				if idx then
					local _, _, skillLevel, maxSkillLevel, _, _, skillLine = GetProfessionInfo(idx)
					local base = baseSkillLine(skillLine)
					if base and skillLevel then
						snap.profs[base] = { s = skillLevel, m = maxSkillLevel or 0 }
					end
				end
			end
		end)
		snap.sources.getProfessions = ok or tostring(err)
		if ok then snap.ok = true end
	end

	-- Path 2: every profession skill line the client knows about (catches First Aid and
	-- professions that GetProfessions might not report on Forever)
	if C_TradeSkillUI and type(C_TradeSkillUI.GetAllProfessionTradeSkillLines) == "function"
		and type(C_TradeSkillUI.GetProfessionInfoBySkillLineID) == "function" then
		local ok, err = pcall(function()
			for _, id in ipairs(C_TradeSkillUI.GetAllProfessionTradeSkillLines() or {}) do
				local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(id)
				if type(info) == "table" and (info.skillLevel or 0) > 0 then
					local base = baseSkillLine(id)
					local cur = snap.profs[base]
					if not cur or (info.skillLevel or 0) > cur.s then
						snap.profs[base] = { s = info.skillLevel, m = info.maxSkillLevel or 0 }
					end
				end
			end
		end)
		snap.sources.allSkillLines = ok or tostring(err)
		if ok then snap.ok = true end
	end

	if not guid then snap.ok = false end
	return snap
end

---------------------------------------------------------------------------
-- Recipes
---------------------------------------------------------------------------

function Scanner.RecipeOutputItem(recipeID)
	if not C_TradeSkillUI then return 0 end
	local ok, schematic = call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if ok and type(schematic) == "table" and schematic.outputItemID and schematic.outputItemID > 0 then
		return schematic.outputItemID
	end
	local ok2, data = call(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
	if ok2 and type(data) == "table" and data.itemID and data.itemID > 0 then
		return data.itemID
	end
	return 0
end

-- Where an unlearned recipe is found, as the profession window says it ("Vendor: ...", "Drop:
-- ..."), on one line without textures. nil when the game does not say.
function Scanner.RecipeSource(recipeID)
	if not C_TradeSkillUI then return nil end
	local ok, text = call(C_TradeSkillUI.GetRecipeSourceText, recipeID)
	if not ok or type(text) ~= "string" then return nil end
	text = text:gsub("|T.-|t", ""):gsub("|n", "\n")
	local parts = {}
	for line in text:gmatch("[^\n]+") do
		line = line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
		if line ~= "" then parts[#parts + 1] = line end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, " · ")
end

-- Skill from which a recipe is grey (gives no more skill), or nil when the game does not say.
function Scanner.RecipeTrivial(recipeID)
	if not C_TradeSkillUI then return nil end
	local ok, info = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
	if ok and type(info) == "table" and type(info.maxTrivialLevel) == "number" and info.maxTrivialLevel > 0 then
		return info.maxTrivialLevel
	end
	return nil
end

-- "Requires Leatherworking (275)" of the game's tooltip, turned into a pattern for any language.
local skillPattern
local function requiresSkillPattern()
	if skillPattern then return skillPattern end
	local format = type(ITEM_MIN_SKILL) == "string" and ITEM_MIN_SKILL or "Requires %s (%d)"
	local p = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
	skillPattern = "^" .. p .. "$"
	return skillPattern
end

-- Skill a recipe item asks for ("Requires Leatherworking (275)" in its tooltip), or nil.
-- An item the client has not loaded yet is requested; GET_ITEM_INFO_RECEIVED redraws the window.
function Scanner.RecipeItemSkill(itemID)
	if not itemID or itemID == 0 then return nil end
	local lines = {}
	if C_TooltipInfo and C_TooltipInfo.GetItemByID then
		local ok, data = call(C_TooltipInfo.GetItemByID, itemID)
		if ok and type(data) == "table" and type(data.lines) == "table" then
			for _, line in ipairs(data.lines) do
				if type(line) == "table" and type(line.leftText) == "string" then lines[#lines + 1] = line.leftText end
			end
		end
	end
	if #lines == 0 then
		Scanner.WantItem(itemID, true)
		return nil
	end
	local pattern = requiresSkillPattern()
	for _, text in ipairs(lines) do
		local _, skill = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match(pattern)
		if skill then return tonumber(skill) end
	end
	return nil
end

-- How many items one craft makes on average (smelting, ammunition and explosives make several).
local outputCount = {}
function Scanner.RecipeOutputCount(recipeID)
	if outputCount[recipeID] then return outputCount[recipeID] end
	if C_TradeSkillUI then
		local ok, schematic = call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
		if ok and type(schematic) == "table" then
			local lo, hi = schematic.quantityMin, schematic.quantityMax
			if type(lo) == "number" and lo > 0 then
				-- only an answer of the game is kept; without one, 1 now and asked again later
				outputCount[recipeID] = (type(hi) == "number" and hi >= lo) and (lo + hi) / 2 or lo
				return outputCount[recipeID]
			end
		end
	end
	return 1
end

-- Whether the game knows a recipe (any recipe, learned or not), and the item it makes (0 when
-- it makes none, e.g. an enchant). Used to check recipe IDs that guildmates send.
function Scanner.RecipeInGame(recipeID)
	if not C_TradeSkillUI then return false end
	local ok, schematic = call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not ok or type(schematic) ~= "table" then return false end
	local itemID = schematic.outputItemID
	return true, (type(itemID) == "number" and itemID > 0) and itemID or 0
end

-- Basic reagents of a recipe as { [itemID] = count }, or nil when the game does not say.
-- Optional and finishing reagent slots are left out.
function Scanner.RecipeReagents(recipeID)
	if not C_TradeSkillUI then return nil end
	local ok, schematic = call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not ok or type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then return nil end
	local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
	local list, n = {}, 0
	for _, slot in ipairs(schematic.reagentSlotSchematics) do
		if type(slot) == "table" and slot.required ~= false
			and (basic == nil or slot.reagentType == nil or slot.reagentType == basic) then
			local reagent = type(slot.reagents) == "table" and slot.reagents[1]
			local itemID, count = type(reagent) == "table" and reagent.itemID, slot.quantityRequired
			if type(itemID) == "number" and itemID > 0 and type(count) == "number" and count > 0 then
				list[itemID] = (list[itemID] or 0) + count
				n = n + 1
			end
		end
	end
	if n == 0 then return nil end
	return list
end

-- The profession a recipe belongs to (for NEW_RECIPE_LEARNED). nil when unknown.
function Scanner.ProfessionForRecipe(recipeID)
	if not C_TradeSkillUI then return nil end
	local ok, tradeSkillID, _, parentID = call(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
	if ok then
		if parentID and parentID > 0 then return parentID end
		if tradeSkillID and tradeSkillID > 0 then return baseSkillLine(tradeSkillID) end
	end
	local ok2, info = call(C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeID)
	if ok2 and type(info) == "table" then
		if info.parentProfessionID and info.parentProfessionID > 0 then return info.parentProfessionID end
		if info.professionID and info.professionID > 0 then return baseSkillLine(info.professionID) end
	end
	return nil
end

-- Scans the currently open profession window.
-- Returns skillLine, recipes ({ [recipeID] = itemID }), count, reagents
-- ({ [recipeID] = { [itemID] = count } }) — or nil, reason.
function Scanner.ScanOpenProfession()
	if not C_TradeSkillUI then return nil, "no C_TradeSkillUI" end
	local ok, ready = call(C_TradeSkillUI.IsTradeSkillReady)
	if not ok or not ready then return nil, "not ready" end
	local okL, linked = call(C_TradeSkillUI.IsTradeSkillLinked)
	if okL and linked then return nil, "linked" end
	local okG, guildView = call(C_TradeSkillUI.IsTradeSkillGuild)
	if okG and guildView then return nil, "guild view" end
	local okN, npc = call(C_TradeSkillUI.IsNPCCrafting)
	if okN and npc then return nil, "npc crafting" end

	local skillLine
	local okB, base = call(C_TradeSkillUI.GetBaseProfessionInfo)
	if okB and type(base) == "table" and base.professionID and base.professionID > 0 then
		skillLine = base.professionID
	end
	if not skillLine then
		local okC, child = call(C_TradeSkillUI.GetChildProfessionInfo)
		if okC and type(child) == "table" then
			skillLine = (child.parentProfessionID and child.parentProfessionID > 0) and child.parentProfessionID or child.professionID
		end
	end
	skillLine = baseSkillLine(skillLine)
	if not skillLine then return nil, "unknown profession" end

	local okR, ids = call(C_TradeSkillUI.GetAllRecipeIDs)
	if not okR or type(ids) ~= "table" then return nil, "no recipe list" end

	local recipes, count, reagents = {}, 0, {}
	-- the game lists the recipes the character has not learned too: all of them go to the
	-- recipe catalog (listInfo.all), and /pg debug says how many there were
	local listInfo = { total = #ids, unlearned = 0, samples = {}, all = {}, fields = {}, trivial = {}, difficulty = {} }
	-- every plain field the game returns for one learned and one unlearned recipe (/pg debug):
	-- shows whether skill-up colours or the required skill are available on this client
	local function fields(kind, recipeID, info)
		if listInfo.fields[kind] then return end
		local parts = {}
		for k, v in pairs(info) do
			if type(v) ~= "table" and type(v) ~= "function" then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
		end
		local okS, schematic = call(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
		if okS and type(schematic) == "table" then
			for k, v in pairs(schematic) do
				if type(v) ~= "table" and type(v) ~= "function" then parts[#parts + 1] = "schematic." .. tostring(k) .. "=" .. tostring(v) end
			end
		end
		table.sort(parts)
		listInfo.fields[kind] = tostring(recipeID) .. " " .. table.concat(parts, ", ")
	end
	for _, recipeID in ipairs(ids) do
		local okI, info = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
		if okI and type(info) == "table" and not info.isRecraft and not info.isDummyRecipe then
			local itemID = Scanner.RecipeOutputItem(recipeID)
			listInfo.all[recipeID] = itemID
			fields(info.learned and "learned" or "unlearned", recipeID, info)
			-- skill from which the recipe is grey, and its colour for this character right now
			if type(info.maxTrivialLevel) == "number" and info.maxTrivialLevel > 0 then
				listInfo.trivial[recipeID] = info.maxTrivialLevel
			end
			if info.learned and type(info.relativeDifficulty) == "number" then
				listInfo.difficulty[recipeID] = info.relativeDifficulty
			end
			if info.learned then
				recipes[recipeID] = itemID
				reagents[recipeID] = Scanner.RecipeReagents(recipeID)
				count = count + 1
			else
				listInfo.unlearned = listInfo.unlearned + 1
				if #listInfo.samples < 3 then
					listInfo.samples[#listInfo.samples + 1] = string.format("%d %s reagents=%s", recipeID,
						tostring(info.name), Scanner.RecipeReagents(recipeID) and "yes" or "no")
				end
			end
		end
	end
	Scanner.lastListInfo = listInfo
	return skillLine, recipes, count, reagents, listInfo
end

---------------------------------------------------------------------------
-- Guild roster
---------------------------------------------------------------------------

-- Key of the guild's saved data: the guild name. The realm is not part of it, because on
-- Forever the realm name a character reports changes between logins (the same guild showed
-- up as "...EU4Realm2PvP" and "...EU5 Realm 8 PvP" on one day), and every new name started an
-- empty database. Second value: the realm reported right now, for diagnostics only.
function Scanner.GuildKey()
	if not IsInGuild() then return nil end
	local name, _, _, realm = GetGuildInfo("player")
	if not name then return nil end
	if not realm or realm == "" then
		realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
	end
	return name, name, realm
end

function Scanner.RequestRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then
		call(C_GuildInfo.GuildRoster)
	elseif GuildRoster then
		call(GuildRoster)
	end
end

-- Returns entries, complete, namesComplete. complete is true when every member came with a
-- GUID; namesComplete when every member came with a name (the roster is fully loaded).
function Scanner.ReadRoster()
	local entries = {}
	local total = GetNumGuildMembers and GetNumGuildMembers() or 0
	if total == 0 then return entries, false, false end
	local withGuid = 0
	for i = 1, total do
		local name, _, _, _, _, _, _, _, isOnline, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(i)
		if name then
			local days
			if isOnline then
				days = 0
			elseif GetGuildRosterLastOnline then
				local y, m, d = GetGuildRosterLastOnline(i)
				if y then days = (y or 0) * 365 + (m or 0) * 30 + (d or 0) end
			end
			entries[#entries + 1] = { guid = guid, name = name, online = isOnline and true or false, daysOffline = days, classFile = classFile }
			if guid then withGuid = withGuid + 1 end
		end
	end
	return entries, (#entries == total and withGuid == total), #entries == total
end
