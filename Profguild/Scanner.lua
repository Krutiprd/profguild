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

function Scanner.ItemName(itemID)
	if not itemID or itemID == 0 then return nil end
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	local ok, name = call(getInfo, itemID)
	if ok and name then return name end
	if C_Item and C_Item.RequestLoadItemDataByID then call(C_Item.RequestLoadItemDataByID, itemID) end
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
-- server once per session, and GET_ITEM_INFO_RECEIVED then rebuilds the list.
local itemLevelCache, levelRequested = {}, {}

function Scanner.ItemLevel(itemID)
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
	if not levelRequested[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
		levelRequested[itemID] = true
		call(C_Item.RequestLoadItemDataByID, itemID)
	end
	return nil
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
	for _, recipeID in ipairs(ids) do
		local okI, info = call(C_TradeSkillUI.GetRecipeInfo, recipeID)
		if okI and type(info) == "table" and info.learned and not info.isRecraft and not info.isDummyRecipe then
			recipes[recipeID] = Scanner.RecipeOutputItem(recipeID)
			reagents[recipeID] = Scanner.RecipeReagents(recipeID)
			count = count + 1
		end
	end
	return skillLine, recipes, count, reagents
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
