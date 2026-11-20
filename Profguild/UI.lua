-- Profguild: UI
-- Main window in three panels: professions on the left, recipes or members in the middle,
-- details on the right (reagents with prices and who can craft the recipe, or the member's
-- professions).
-- Flat dark panels with thin brass borders; only the game's own textures and fonts are used.

local _, ns = ...

local UI = {}
ns.UI = UI

---------------------------------------------------------------------------
-- Look
---------------------------------------------------------------------------

local WIDTH, HEIGHT = 880, 600
local SIDEBAR_W, LIST_W, DETAIL_W = 180, 330, 330
local GAP = 8
local PANEL_TOP = -72
local FOOTER_H = 30
local PANEL_H = HEIGHT + PANEL_TOP - FOOTER_H - 18

local PROF_STEP = 26
local LIST_ROWS, ROW_H, ROW_STEP = 8, 36, 38
local DETAIL_ROWS, DETAIL_STEP = 10, 24  -- member professions
local CRAFTER_ROWS, CRAFTER_STEP, CRAFTER_TOP = 4, 22, -334
local REAGENT_ROWS, REAGENT_STEP, REAGENT_TOP = 6, 22, -128
local MENU_ROWS, MENU_STEP, MENU_W = 12, 20, 190

local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

-- colours as { r, g, b, a }
local C = {
	bg       = { 0.07, 0.07, 0.08, 0.97 },
	panel    = { 0.11, 0.11, 0.12, 0.96 },
	row      = { 0.15, 0.15, 0.16, 0.92 },
	hover    = { 0.21, 0.20, 0.17, 0.96 },
	selected = { 0.27, 0.23, 0.15, 0.98 },
	border   = { 0.50, 0.40, 0.24, 0.85 },
	line     = { 0.32, 0.30, 0.26, 0.70 },
	gold     = { 0.92, 0.76, 0.45, 1 },
	muted    = { 0.60, 0.62, 0.64, 1 },
	text     = { 0.93, 0.92, 0.89, 1 },
	clear    = { 0, 0, 0, 0 },
}
local HEX_ONLINE, HEX_OFFLINE, HEX_MUTED, HEX_GOLD = "|cff70d08c", "|cff8a8f94", "|cff9a9ea3", "|cffebc273"
local HEX_LOSS = "|cffe06c5f"
local HEX_PROFIT = "|cff70d08c"
-- skill-up colours of the profession window: 0 optimal, 1 medium, 2 easy, 3 trivial
local HEX_DIFFICULTY = { [0] = "|cffff8040", [1] = "|cffffff00", [2] = "|cff40bf40", [3] = "|cff808080" }
local HEX_SKILL_MIN = "|cffff2020"

-- base profession skill line -> icon
local PROF_ICONS = {
	[171] = "Interface\\Icons\\Trade_Alchemy",
	[164] = "Interface\\Icons\\Trade_BlackSmithing",
	[333] = "Interface\\Icons\\Trade_Engraving",
	[202] = "Interface\\Icons\\Trade_Engineering",
	[165] = "Interface\\Icons\\Trade_LeatherWorking",
	[197] = "Interface\\Icons\\Trade_Tailoring",
	[182] = "Interface\\Icons\\Trade_Herbalism",
	[186] = "Interface\\Icons\\Trade_Mining",
	[393] = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
	[185] = "Interface\\Icons\\INV_Misc_Food_15",
	[129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
	[356] = "Interface\\Icons\\Trade_Fishing",
}
local ALL_ICON = "Interface\\Icons\\INV_Misc_Book_11"

UI.view = "recipes"     -- or "leveling", "members"
UI.ITEM_REBUILD = 2     -- seconds: the list is rebuilt at most this often while items load
UI.memberFilter = nil   -- guid whose recipes are shown
UI.category = nil       -- skill line shown, nil = all professions
UI.selected = nil       -- data of the selected list row
UI.offset = 0           -- first visible list row - 1
UI.menuOffset = 0       -- first visible row of the player menu - 1
UI.detailOffset = 0

---------------------------------------------------------------------------
-- Small widget helpers
---------------------------------------------------------------------------

local function showIf(region, cond)
	if cond then region:Show() else region:Hide() end
end

-- Flat background with a 1 px border. Falls back to a plain texture without backdrops.
local function paint(frame, bg, border)
	if frame.SetBackdrop then
		if not frame._backdrop then
			frame:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
			frame._backdrop = true
		end
		frame:SetBackdropColor(unpack(bg))
		frame:SetBackdropBorderColor(unpack(border or C.line))
	else
		if not frame._bgTex then
			frame._bgTex = frame:CreateTexture(nil, "BACKGROUND")
			frame._bgTex:SetAllPoints()
		end
		frame._bgTex:SetColorTexture(unpack(bg))
	end
end

local function panel(parent, bg, border, kind)
	local f = CreateFrame(kind or "Frame", nil, parent, BACKDROP_TEMPLATE)
	paint(f, bg or C.panel, border or C.line)
	return f
end

local function label(parent, font, color)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetTextColor(unpack(color or C.text))
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end

local function hline(parent, x, y, width)
	local t = parent:CreateTexture(nil, "ARTWORK")
	t:SetColorTexture(unpack(C.line))
	t:SetSize(width, 1)
	t:SetPoint("TOPLEFT", x, y)
	return t
end

-- Flat button with centred text; active pills keep the selected colour and a brass border.
local function pill(parent, width, height)
	local b = panel(parent, C.row, C.line, "Button")
	b:SetSize(width, height)
	b.text = label(b, "GameFontHighlightSmall", C.text)
	b.text:SetPoint("CENTER")
	b.text:SetJustifyH("CENTER")
	b.text:SetWidth(width - 8) -- a long text (a player's name) is cut, not drawn over the neighbour
	b:SetScript("OnEnter", function(self) paint(self, C.hover, self.active and C.border or C.line) end)
	b:SetScript("OnLeave", function(self) paint(self, self.active and C.selected or C.row, self.active and C.border or C.line) end)
	return b
end

local function setPill(b, text, active, disabled)
	b.text:SetText(text)
	b.active = active and true or false
	b.disabled = disabled and true or false
	b.text:SetTextColor(unpack(b.disabled and C.muted or C.text))
	paint(b, b.active and C.selected or C.row, b.active and C.border or C.line)
end

---------------------------------------------------------------------------
-- Names, icons, chat
---------------------------------------------------------------------------

local recipeNameCache = {}
local function recipeName(recipeID, itemID)
	local name = recipeNameCache[recipeID]
	if name then return name end
	name = ns.Scanner.RecipeName(recipeID)
	if not name and itemID and itemID > 0 then name = ns.Scanner.ItemName(itemID, true) end
	if name then recipeNameCache[recipeID] = name end
	return name or ("#" .. recipeID)
end

local function safeCall(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a = pcall(fn, ...)
	if ok then return a end
end

local function recipeIcon(d)
	local icon
	if d.itemID and d.itemID > 0 then
		icon = safeCall(C_Item and C_Item.GetItemIconByID, d.itemID) or safeCall(GetItemIcon, d.itemID)
	end
	icon = icon or safeCall(C_Spell and C_Spell.GetSpellTexture, d.recipeID) or safeCall(GetSpellTexture, d.recipeID)
	return icon or PROF_ICONS[d.skillLine] or QUESTION
end

-- Item name in its quality colour when the game knows the quality.
local function qualityName(d)
	local quality = d.itemID and d.itemID > 0 and safeCall(C_Item and C_Item.GetItemQualityByID, d.itemID)
	local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if color and color.hex then return color.hex .. d.name .. "|r" end
	return d.name
end

local function classColored(name, classFile)
	if classFile and C_ClassColor and C_ClassColor.GetClassColor then
		local color = C_ClassColor.GetClassColor(classFile)
		if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(name) end
	end
	if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] and RAID_CLASS_COLORS[classFile].colorStr then
		return "|c" .. RAID_CLASS_COLORS[classFile].colorStr .. name .. "|r"
	end
	return name
end

local function setClassIcon(texture, classFile)
	local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
	if coords then
		texture:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
		texture:SetTexCoord(unpack(coords))
	else
		texture:SetTexture(QUESTION)
		texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	end
end

local function setIcon(texture, path)
	texture:SetTexture(path)
	texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

-- Name the game accepts for a whisper: roster name first, then the addon sender name.
local function whisperName(guid)
	local entry = ns.store and ns.store:RosterEntry(guid)
	if entry and entry.name then return entry.name end
	if ns.guildDB and ns.guildDB.names and ns.guildDB.names[guid] then return ns.guildDB.names[guid] end
	local rec = ns.store and ns.store:Get(guid)
	return rec and rec.n
end

-- Chat helpers moved between client versions (global functions vs. ChatFrameUtil), so each
-- candidate is tried in turn. Returns true when one of them worked.
local function tryCalls(candidates, ...)
	-- candidates may contain nils (missing functions), so ipairs would stop early
	for i = 1, table.maxn(candidates) do
		local fn = candidates[i]
		if type(fn) == "function" and pcall(fn, ...) then return true end
	end
	return false
end

local function chatUtil(key)
	return ChatFrameUtil and ChatFrameUtil[key]
end

local function openChat(text)
	return tryCalls({ chatUtil("OpenChat"), ChatFrame_OpenChat }, text)
end

local function openWhisper(name)
	if not name then return end
	if tryCalls({ ChatFrame_SendTell, chatUtil("SendTell") }, name) then return end
	if openChat("/w " .. name .. " ") then return end
	ns.Say("WHISPER_FAILED", name)
end
UI.OpenWhisper = openWhisper

local function insertLink(recipeID, itemID)
	local link
	if itemID and itemID > 0 then
		local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
		local ok, _, l = pcall(getInfo, itemID)
		if ok then link = l end
	end
	if not link and C_Spell and C_Spell.GetSpellLink then
		local ok, l = pcall(C_Spell.GetSpellLink, recipeID)
		if ok then link = l end
	end
	if not link then return end
	-- InsertLink returns false when no chat edit box is open: then open one with the link
	local candidates = { ChatEdit_InsertLink, chatUtil("InsertLink") }
	for i = 1, table.maxn(candidates) do
		local fn = candidates[i]
		if type(fn) == "function" then
			local ok, inserted = pcall(fn, link)
			if ok and inserted ~= false then return end
		end
	end
	if openChat(link) then return end
	ns.Print("%s", link)
end
UI.InsertLink = insertLink

local function daysText(rec)
	if not rec or not rec.t or rec.t == 0 then return "" end
	local days = math.floor((GetServerTime() - rec.t) / 86400)
	if days <= 0 then return ns.T("TODAY") end
	return ns.T("DAYS_AGO", days)
end

-- Where the recipe comes from and what its recipe item costs at the auction house (Data.lua
-- from Wowhead, the price live from Auctionator or TSM). Returns the text for the details and a
-- short price text for the list ("" when the item is not on the auction house), or nil.
local SOURCE_KEYS = { d = "SRC_DROP", v = "SRC_VENDOR", q = "SRC_QUEST", c = "SRC_CRAFT" }
-- The game's own text is asked for only when a recipe is opened (ask = true), once, and kept in
-- ProfguildDB.sources; the list uses what is already known. "No text" is not saved: the game is
-- asked again a minute later (it may not have had the data yet).
local noSource = {}
local function recipeItemText(recipeID, ask)
	local sources = ns.db.sources
	if ask and sources and sources[recipeID] == nil and GetTime() - (noSource[recipeID] or -1e9) >= 60 then
		local text = ns.Scanner.RecipeSource(recipeID)
		if text then sources[recipeID] = text else noSource[recipeID] = GetTime() end
	end
	local gameText = sources and sources[recipeID] or nil
	local itemID, src = ns.Prices.RecipeItem(recipeID)
	if not itemID then
		if gameText then return gameText, "" end -- already says "Vendor: ...", "Drop: ..."
		if itemID == false then return ns.T("RECIPE_FROM", ns.T("RECIPE_TRAINER")), "" end
		return nil
	end
	local parts = {}
	for letter in src:gmatch("%a") do
		if SOURCE_KEYS[letter] then parts[#parts + 1] = ns.T(SOURCE_KEYS[letter]) end
	end
	local text = gameText or ns.T("RECIPE_FROM", #parts > 0 and table.concat(parts, ", ") or "?")
	local price, kind, age = ns.Prices.Get(itemID)
	if price and kind == "ah" then
		local onAH = age and ns.T("RECIPE_AH", ns.Prices.Format(price), age <= 0 and ns.T("TODAY") or ns.T("DAYS_AGO", age))
			or ns.T("RECIPE_AH_PRICE", ns.Prices.Format(price))
		local onMarket = ns.Prices.Available(itemID)
		if onMarket then onAH = onAH .. ", " .. ns.T("PCS", onMarket) end
		return text .. " · " .. onAH, ns.T("LIST_RECIPE_AH", ns.Prices.Format(price))
	end
	return text .. " · " .. ns.T("RECIPE_NO_AH"), ""
end

-- Profit of one craft: item price minus the auction house cut and the reagents, or nil when a
-- price is missing. Reagents come from the catalog of guildmates or straight from the game
-- (asked once per session).
local gameReagents = {}
local function craftProfit(d)
	if not d.itemID or d.itemID == 0 or not ns.Prices.Source() then return nil end
	local reagents = ns.reagents and ns.reagents:Get(d.recipeID)
	if not reagents then
		if gameReagents[d.recipeID] == nil then gameReagents[d.recipeID] = ns.Scanner.RecipeReagents(d.recipeID) or false end
		reagents = gameReagents[d.recipeID] or nil
	end
	if not reagents then return nil end
	-- an item that binds on pickup cannot be sold: one craft costs the reagents
	local value, source
	if ns.Scanner.ItemBoP(d.itemID) then value = 0 else value, source = ns.Prices.SaleValue(d.itemID) end
	if not value then return nil end
	local total, missing = ns.Prices.Cost(reagents)
	if missing > 0 then return nil end
	return ns.Prices.AfterCut(value * ns.Scanner.RecipeOutputCount(d.recipeID), source) - total
end
UI.CraftProfit = craftProfit

-- Skill levels of a recipe: learnable from (recipe item tooltip) and grey from (the game).
-- ask = true (recipe opened): what is missing is asked from the game once and kept.
local function recipeSkill(recipeID, ask)
	local all = ns.db.recipeInfo
	if not all then return nil end
	local info = all[recipeID]
	if ask then
		info = info or {}
		local g, m = info.g, info.m
		if info.g == nil then info.g = ns.Scanner.RecipeTrivial(recipeID) end
		if info.m == nil then
			local itemID = ns.Prices.RecipeItem(recipeID)
			if itemID then info.m = ns.Scanner.RecipeItemSkill(itemID) end
		end
		if next(info) then all[recipeID] = info end
		-- a new number changes the order of the Leveling list: rebuilt once, a moment later,
		-- not on every scroll step that shows new rows
		if (info.g ~= g or info.m ~= m) and not UI.skillResort then
			UI.skillResort = true
			C_Timer.After(UI.ITEM_REBUILD, function()
				UI.skillResort = false
				ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
				ns.OnDataChanged()
			end)
		end
	end
	return info
end

local function recipeSkillText(recipeID)
	local info = recipeSkill(recipeID, true)
	if not info or not (info.g or info.m) then return nil end
	-- only coloured numbers, like Wowhead: red = learnable from, grey = no more skill-ups from
	local parts = {}
	if info.m then parts[#parts + 1] = HEX_SKILL_MIN .. info.m .. "|r" end
	if info.g then parts[#parts + 1] = HEX_DIFFICULTY[3] .. info.g .. "|r" end
	return table.concat(parts, "  ")
end

-- Colour of a recipe for the logged-in character (only recipes it knows), as a dot.
local function ownColorDot(recipeID)
	local own = ns.OwnState and ns.OwnState()
	local difficulty = own and own.colors and own.colors[recipeID]
	return difficulty and HEX_DIFFICULTY[difficulty] and (HEX_DIFFICULTY[difficulty] .. "•|r ") or ""
end

local function crafterText(crafters, max)
	local parts = {}
	for i = 1, math.min(max, #crafters) do
		local c = crafters[i]
		parts[i] = (c.online and HEX_ONLINE or HEX_OFFLINE) .. c.name .. "|r"
	end
	local text = table.concat(parts, ", ")
	if #crafters > max then text = text .. " " .. HEX_MUTED .. ns.T("MORE_CRAFTERS", #crafters - max) .. "|r" end
	return text
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function matches(query, ...)
	if query == "" then return true end
	for i = 1, select("#", ...) do
		local s = select(i, ...)
		if s and s:lower():find(query, 1, true) then return true end
	end
	return false
end

-- Visible crafters of one recipe, filtered by staleness, online and member filters.
local function craftersOf(entry, onlineOnly, now, staleDays)
	local store = ns.store
	local list = {}
	for _, guid in ipairs(entry.guids) do
		if (not UI.memberFilter or UI.memberFilter == guid) and not store:IsStale(guid, staleDays, now) then
			local online = store:IsOnline(guid)
			if online or not onlineOnly then
				local rec = store:Get(guid)
				list[#list + 1] = { guid = guid, name = ns.DisplayName(guid, rec), online = online, rec = rec }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return list
end

-- True when somebody in the guild who is not inactive knows the recipe, online or not.
local function anyCrafter(entry, now, staleDays)
	for _, guid in ipairs(entry.guids) do
		if not ns.store:IsStale(guid, staleDays, now) then return true end
	end
	return false
end

-- Recipe filter states in click order: somebody can craft it, nobody in the guild knows it, all.
local RECIPE_FILTERS = { known = "unknown", unknown = "all", all = "known" }
local RECIPE_FILTER_TEXT = { known = "RECIPES_KNOWN", unknown = "RECIPES_UNKNOWN", all = "RECIPES_ALL" }

-- Recipe groups, like the categories of the profession window but taken from the crafted item:
-- the game describes any item, while profession categories are known only for one's own open
-- professions. Armour first, then weapons, then the other item classes by name; recipes
-- without a known item (enchants) last. Inside a group: highest item level first (like the
-- profession window; items the client has not loaded yet at the end), then required level,
-- equipment slot and name.
local CLASS_RANK = { [4] = 1, [2] = 2 } -- Armor, Weapon
local RANK_OTHER_CLASS, RANK_NO_ITEM, SLOT_UNKNOWN = 3, 4, 99
local SLOT_ORDER = {}
for i, slot in ipairs({ "INVTYPE_HEAD", "INVTYPE_NECK", "INVTYPE_SHOULDER", "INVTYPE_CLOAK", "INVTYPE_CHEST",
	"INVTYPE_ROBE", "INVTYPE_BODY", "INVTYPE_TABARD", "INVTYPE_WRIST", "INVTYPE_HAND", "INVTYPE_WAIST",
	"INVTYPE_LEGS", "INVTYPE_FEET", "INVTYPE_FINGER", "INVTYPE_TRINKET", "INVTYPE_WEAPON", "INVTYPE_2HWEAPON",
	"INVTYPE_WEAPONMAINHAND", "INVTYPE_WEAPONOFFHAND", "INVTYPE_SHIELD", "INVTYPE_HOLDABLE", "INVTYPE_RANGED",
	"INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_AMMO", "INVTYPE_RELIC" }) do
	SLOT_ORDER[slot] = i
end

-- rank, title, slot rank of the group a recipe's item belongs to
local function recipeGroup(itemID)
	local c = ns.Scanner.ItemClass(itemID)
	if not c then return RANK_NO_ITEM, ns.T("GROUP_OTHER"), SLOT_UNKNOWN end
	local title = c.class ~= "" and c.class or ns.T("GROUP_OTHER")
	if c.subclass ~= "" and c.subclass ~= c.class then title = title .. " – " .. c.subclass end
	return CLASS_RANK[c.classID] or RANK_OTHER_CLASS, title, SLOT_ORDER[c.slot] or SLOT_UNKNOWN
end

-- Recipes for the recipe filter (ns.db.settings.recipeFilter): "known" lists recipes with at
-- least one visible crafter, "unknown" the recipes of the catalog nobody in the guild knows,
-- "all" both (and recipes whose crafters are all offline while "online only" is on). A player
-- filter always lists that player's known recipes. Returns the rows (grouped by profession when
-- all are shown, then by item group, each group led by a header row), the number of recipes per
-- profession counted before the search and profession filters, and their sum.
function UI:BuildRecipeRows(query, category)
	local store = ns.store
	local rows, counts, total = {}, {}, 0
	if not store then return rows, counts, total end
	local onlineOnly = ns.db.settings.onlineOnly
	local mode = self.memberFilter and "known" or ns.db.settings.recipeFilter or "known"
	local now, staleDays = GetServerTime(), ns.StaleDays()
	local index = store:Index().recipes

	local function consider(recipeID, skillLine, itemID, entry)
		local crafters = entry and craftersOf(entry, onlineOnly, now, staleDays) or {}
		local nobody = #crafters == 0 and not (entry and anyCrafter(entry, now, staleDays))
		if mode == "known" and #crafters == 0 then return end
		if mode == "unknown" and not nobody then return end
		counts[skillLine] = (counts[skillLine] or 0) + 1
		total = total + 1
		if category and category ~= skillLine then return end
		local name = recipeName(recipeID, itemID)
		local prof = ns.Scanner.ProfessionName(skillLine)
		-- the item name is looked up only for a search: asking for it makes the game
		-- load the item, which must not happen for every recipe each time the list is drawn
		local hit = query == "" or matches(query, name, prof)
		if not hit then
			for _, c in ipairs(crafters) do
				if c.name:lower():find(query, 1, true) then hit = true break end
			end
		end
		if not hit then hit = matches(query, ns.Scanner.ItemName(itemID, true)) end
		if not hit then return end
		local groupRank, group, slotRank = recipeGroup(itemID)
		local ilvl, req = ns.Scanner.ItemLevel(itemID, true)
		rows[#rows + 1] = { kind = "recipe", key = "r" .. recipeID, recipeID = recipeID, itemID = itemID,
			skillLine = skillLine, name = name, prof = prof, crafters = crafters, nobody = nobody,
			groupRank = groupRank, group = group, slotRank = slotRank, ilvl = ilvl or -1, req = req or -1 }
	end

	local catalog = ns.catalog and ns.catalog:All() or {}
	for recipeID, entry in pairs(index) do
		local itemID = entry.itemID
		if (not itemID or itemID == 0) and catalog[entry.skillLine] then itemID = catalog[entry.skillLine][recipeID] or itemID end
		consider(recipeID, entry.skillLine, itemID or 0, entry)
	end
	if mode ~= "known" then
		for skillLine, list in pairs(catalog) do
			for recipeID, itemID in pairs(list) do
				if not index[recipeID] then consider(recipeID, skillLine, itemID, nil) end
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.skillLine ~= b.skillLine then
			if a.prof ~= b.prof then return a.prof < b.prof end
			return a.skillLine < b.skillLine
		end
		if a.groupRank ~= b.groupRank then return a.groupRank < b.groupRank end
		if a.group ~= b.group then return a.group < b.group end
		if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
		if a.req ~= b.req then return a.req > b.req end
		if a.slotRank ~= b.slotRank then return a.slotRank < b.slotRank end
		if a.name ~= b.name then return a.name < b.name end
		return a.recipeID < b.recipeID
	end)
	-- a header row before every group; with all professions shown it names the profession too
	local out, last = {}, nil
	for _, r in ipairs(rows) do
		local title = category and r.group or (r.prof .. " · " .. r.group)
		local key = r.skillLine .. "\1" .. r.group
		if key ~= last then
			out[#out + 1] = { kind = "header", key = "h" .. key, title = title }
			last = key
		end
		out[#out + 1] = r
	end
	return out, counts, total
end

-- Leveling: the recipes of the recipe filter without group headers, sorted by the skill from
-- which they turn grey (the game knows it for every recipe of an opened profession window),
-- then by the skill they are learned at. Recipes without skill data come last.
function UI:BuildLevelingRows(query, category)
	local rows, counts, total = self:BuildRecipeRows(query, category)
	local out = {}
	for _, d in ipairs(rows) do
		if d.kind == "recipe" then
			local info = ns.db.recipeInfo and ns.db.recipeInfo[d.recipeID]
			d.grey = info and info.g or 99999
			d.minSkill = info and info.m or d.grey
			out[#out + 1] = d
		end
	end
	table.sort(out, function(a, b)
		if a.grey ~= b.grey then return a.grey < b.grey end
		if a.minSkill ~= b.minSkill then return a.minSkill < b.minSkill end
		if a.name ~= b.name then return a.name < b.name end
		return a.recipeID < b.recipeID
	end)
	return out, counts, total
end

-- Members (not stale, online filter). Returns the rows (online first), the number of members
-- per profession counted before the search and profession filters, and the number of members.
function UI:BuildMemberRows(query, category)
	local store = ns.store
	local rows, counts, total = {}, {}, 0
	if not store then return rows, counts, total end
	local onlineOnly = ns.db.settings.onlineOnly
	local now, staleDays = GetServerTime(), ns.StaleDays()
	for guid, rec in pairs(store:All()) do
		local online = store:IsOnline(guid)
		if not store:IsStale(guid, staleDays, now) and (online or not onlineOnly) then
			total = total + 1
			local profNames, parts = {}, {}
			for skillLine, prof in pairs(rec.p) do
				counts[skillLine] = (counts[skillLine] or 0) + 1
				local pname = ns.Scanner.ProfessionName(skillLine)
				profNames[#profNames + 1] = pname
				parts[#parts + 1] = string.format("%s %d", pname, prof.s or 0)
			end
			table.sort(parts)
			local name = ns.DisplayName(guid, rec)
			if (not category or rec.p[category]) and matches(query, name, unpack(profNames)) then
				rows[#rows + 1] = { kind = "member", key = "m" .. guid, guid = guid, rec = rec, name = name,
					online = online, profs = table.concat(parts, ", ") }
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return rows, counts, total
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

-- A tooltip of an item the client has not loaded says "Retrieving item information" and does
-- not update by itself: the shown tooltip is drawn again when the item arrives.
local tooltipShown -- { owner =, draw = function } while one of our tooltips is shown
-- items: the item IDs the tooltip shows; it is drawn again only when one of them arrives
local function showTooltip(owner, draw, items)
	tooltipShown = { owner = owner, draw = draw, items = items }
	draw()
end
local function hideTooltip()
	tooltipShown = nil
	GameTooltip:Hide()
end
function UI:OnItemInfo(itemID)
	local t = tooltipShown
	if t and GameTooltip:IsShown() and GameTooltip:GetOwner() == t.owner and t.items and t.items[itemID] then t.draw() end
end

local function recipeTooltip(owner, d)
	ns.Scanner.WantItem(d.itemID, true)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	if ns.Tooltip then ns.Tooltip.suppress = true end
	local ok = false
	if d.itemID and d.itemID > 0 then ok = pcall(GameTooltip.SetItemByID, GameTooltip, d.itemID) end
	if not ok then pcall(GameTooltip.SetSpellByID, GameTooltip, d.recipeID) end
	if ns.Tooltip then ns.Tooltip.suppress = false end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine(ns.T("CRAFTERS") .. ":", C.gold[1], C.gold[2], C.gold[3])
	for _, c in ipairs(d.crafters) do
		if c.online then GameTooltip:AddLine(c.name, 0.44, 0.82, 0.55) else GameTooltip:AddLine(c.name, 0.55, 0.56, 0.58) end
	end
	if #d.crafters == 0 then
		GameTooltip:AddLine(ns.T(d.nobody and "NOBODY_KNOWS" or "NOBODY_ONLINE"), C.muted[1], C.muted[2], C.muted[3])
	end
	GameTooltip:AddLine(ns.T("ROW_HINT"), C.muted[1], C.muted[2], C.muted[3], true)
	GameTooltip:Show()
end

local function rowColor(row)
	local d = row.data
	if d and d.kind == "header" then
		paint(row, C.clear, C.clear)
		return
	end
	local selected = d and UI.selected and UI.selected.key == d.key
	paint(row, selected and C.selected or C.row, selected and C.border or C.line)
end

local function createListRow(parent, index)
	local row = panel(parent, C.row, C.line, "Button")
	row:SetSize(LIST_W - 36, ROW_H)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_STEP)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(26, 26)
	row.icon:SetPoint("LEFT", 6, 0)
	row.name = label(row, "GameFontHighlight", C.text)
	row.name:SetPoint("TOPLEFT", 40, -4)
	row.name:SetWidth(LIST_W - 86)
	row.sub = label(row, "GameFontHighlightSmall", C.muted)
	row.sub:SetPoint("TOPLEFT", 40, -20)
	row.sub:SetWidth(LIST_W - 86)
	-- profit or loss of one craft, right of the name
	row.profit = label(row, "GameFontHighlightSmall", C.text)
	row.profit:SetPoint("TOPRIGHT", -8, -5)
	row.profit:SetJustifyH("RIGHT")
	-- character level the crafted item requires, under the profit
	row.level = label(row, "GameFontHighlightSmall", C.muted)
	row.level:SetPoint("TOPRIGHT", -8, -20)
	row.level:SetJustifyH("RIGHT")
	row:RegisterForClicks("LeftButtonUp")
	row:EnableMouseWheel(true)
	row:SetScript("OnMouseWheel", function(_, delta) UI:Scroll(delta) end)
	row:SetScript("OnEnter", function(self)
		if self.data and self.data.kind == "header" then return end
		paint(self, C.hover, C.border)
		if self.data and self.data.kind == "recipe" then
			local d = self.data
			showTooltip(self, function() recipeTooltip(self, d) end, { [d.itemID or 0] = true })
		end
	end)
	row:SetScript("OnLeave", function(self)
		hideTooltip()
		rowColor(self)
	end)
	row:SetScript("OnClick", function(self)
		local d = self.data
		if not d or d.kind == "header" then return end
		if d.kind == "recipe" and IsShiftKeyDown() then
			insertLink(d.recipeID, d.itemID)
			return
		end
		UI.selected = d
		UI.detailOffset = 0
		UI.reagentOffset = 0
		UI:Refresh()
	end)
	return row
end

local function createDetailRow(parent, index, top, step)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(DETAIL_W - 28, step - 2)
	row:SetPoint("TOPLEFT", 14, top - (index - 1) * step)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(unpack(C.clear))
	row.left = label(row, "GameFontHighlight", C.text)
	row.left:SetPoint("LEFT", 6, 0)
	row.left:SetWidth(DETAIL_W - 150)
	row.right = label(row, "GameFontHighlightSmall", C.muted)
	row.right:SetPoint("RIGHT", -6, 0)
	row.right:SetJustifyH("RIGHT")
	row:RegisterForClicks("LeftButtonUp")
	row:EnableMouseWheel(true)
	row:SetScript("OnMouseWheel", function(_, delta) UI:ScrollDetail(delta) end)
	row:SetScript("OnEnter", function(self) self.bg:SetColorTexture(unpack(C.hover)) end)
	row:SetScript("OnLeave", function(self) self.bg:SetColorTexture(unpack(C.clear)) end)
	row:SetScript("OnClick", function(self)
		local d = self.data
		if not d then return end
		if d.guid then
			openWhisper(whisperName(d.guid))
		elseif d.skillLine and UI.selected and UI.selected.kind == "member" then
			-- this member's recipes of that profession
			UI.memberFilter = UI.selected.guid
			UI.memberFilterName = UI.selected.name
			UI.category = d.skillLine
			UI.view = "recipes"
			UI.selected = nil
			UI.offset = 0
			UI:Refresh()
		end
	end)
	return row
end

-- One reagent: icon, "6x name", price of that amount. Hover shows the item, shift-click links it.
local function createReagentRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(DETAIL_W - 28, REAGENT_STEP - 2)
	row:SetPoint("TOPLEFT", 14, REAGENT_TOP - (index - 1) * REAGENT_STEP)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints()
	row.bg:SetColorTexture(unpack(C.clear))
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(16, 16)
	row.icon:SetPoint("LEFT", 4, 0)
	row.left = label(row, "GameFontHighlightSmall", C.text)
	row.left:SetPoint("LEFT", 26, 0)
	row.left:SetWidth(DETAIL_W - 140)
	-- a long price text (pieces, vendor price) shortens the name instead of covering it
	row.fitSpec = { width = DETAIL_W - 28, left = 26, right = 4, max = DETAIL_W - 140 }
	row.right = label(row, "GameFontHighlightSmall", C.muted)
	row.right:SetPoint("RIGHT", -4, 0)
	row.right:SetJustifyH("RIGHT")
	row:RegisterForClicks("LeftButtonUp")
	row:EnableMouseWheel(true)
	row:SetScript("OnMouseWheel", function(_, delta) UI:ScrollReagents(delta) end)
	row:SetScript("OnEnter", function(self)
		self.bg:SetColorTexture(unpack(C.hover))
		local d = self.data
		if not d then return end
		ns.Scanner.WantItem(d.itemID, true)
		showTooltip(self, function()
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			pcall(GameTooltip.SetItemByID, GameTooltip, d.itemID)
			GameTooltip:Show()
		end, { [d.itemID] = true })
	end)
	row:SetScript("OnLeave", function(self)
		self.bg:SetColorTexture(unpack(C.clear))
		hideTooltip()
	end)
	row:SetScript("OnClick", function(self)
		if self.data and IsShiftKeyDown() then insertLink(0, self.data.itemID) end
	end)
	return row
end

local function createProfButton(parent, index)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(SIDEBAR_W - 20, PROF_STEP - 2)
	b:SetPoint("TOPLEFT", 10, -40 - (index - 1) * PROF_STEP)
	b.bg = b:CreateTexture(nil, "BACKGROUND")
	b.bg:SetAllPoints()
	b.bg:SetColorTexture(unpack(C.clear))
	b.bar = b:CreateTexture(nil, "ARTWORK")
	b.bar:SetColorTexture(unpack(C.gold))
	b.bar:SetSize(2, PROF_STEP - 2)
	b.bar:SetPoint("LEFT")
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetSize(18, 18)
	b.icon:SetPoint("LEFT", 8, 0)
	b.name = label(b, "GameFontHighlight", C.text)
	b.name:SetPoint("LEFT", 32, 0)
	b.name:SetWidth(SIDEBAR_W - 90)
	b.count = label(b, "GameFontHighlightSmall", C.muted)
	b.count:SetPoint("RIGHT", -6, 0)
	b.count:SetJustifyH("RIGHT")
	b:SetScript("OnEnter", function(self) if not self.active then self.bg:SetColorTexture(unpack(C.hover)) end end)
	b:SetScript("OnLeave", function(self) self.bg:SetColorTexture(unpack(self.active and C.selected or C.clear)) end)
	b:SetScript("OnClick", function(self) UI:SetCategory(self.skillLine) end)
	return b
end

function UI:Create()
	if self.frame then return end
	local f = panel(UIParent, C.bg, C.border)
	_G.ProfguildFrame = f
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER", 0, 20)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	tinsert(UISpecialFrames, "ProfguildFrame") -- Esc closes the window
	self.frame = f

	-- header
	local accent = f:CreateTexture(nil, "OVERLAY")
	accent:SetColorTexture(unpack(C.gold))
	accent:SetHeight(2)
	accent:SetPoint("TOPLEFT", 1, -1)
	accent:SetPoint("TOPRIGHT", -1, -1)
	local logo = f:CreateTexture(nil, "ARTWORK")
	logo:SetSize(34, 34)
	logo:SetPoint("TOPLEFT", 16, -16)
	setIcon(logo, "Interface\\Icons\\Trade_LeatherWorking")
	self.title = label(f, "GameFontNormalLarge", C.gold)
	self.title:SetPoint("TOPLEFT", 60, -17)
	self.version = label(f, "GameFontHighlightSmall", C.muted)
	self.version:SetPoint("LEFT", self.title, "RIGHT", 8, -1)
	self.subtitle = label(f, "GameFontHighlightSmall", C.muted)
	self.subtitle:SetPoint("TOPLEFT", 60, -38)

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -6)
	close:SetScript("OnClick", function() f:Hide() end)
	self.closeButton = close

	self.membersTab = pill(f, 110, 24)
	self.membersTab:SetPoint("TOPRIGHT", -44, -20)
	self.membersTab:SetScript("OnClick", function() UI:SetView("members") end)
	self.levelingTab = pill(f, 110, 24)
	self.levelingTab:SetPoint("RIGHT", self.membersTab, "LEFT", -6, 0)
	self.levelingTab:SetScript("OnClick", function() UI:SetView("leveling") end)
	self.recipesTab = pill(f, 110, 24)
	self.recipesTab:SetPoint("RIGHT", self.levelingTab, "LEFT", -6, 0)
	self.recipesTab:SetScript("OnClick", function() UI:SetView("recipes") end)
	hline(f, 14, -64, WIDTH - 28)

	-- left: professions
	local side = panel(f, C.panel, C.line)
	side:SetSize(SIDEBAR_W, PANEL_H)
	side:SetPoint("TOPLEFT", 12, PANEL_TOP)
	self.sideTitle = label(side, "GameFontNormal", C.gold)
	self.sideTitle:SetPoint("TOPLEFT", 12, -12)
	hline(side, 10, -32, SIDEBAR_W - 20)
	self.sidebar, self.profButtons = side, {}

	-- middle: search, filters, list
	local mid = panel(f, C.panel, C.line)
	mid:SetSize(LIST_W, PANEL_H)
	mid:SetPoint("TOPLEFT", 12 + SIDEBAR_W + GAP, PANEL_TOP)
	self.listTitle = label(mid, "GameFontNormal", C.gold)
	self.listTitle:SetPoint("TOPLEFT", 12, -12)
	self.listCount = label(mid, "GameFontHighlightSmall", C.muted)
	self.listCount:SetPoint("TOPRIGHT", -12, -14)
	self.listCount:SetJustifyH("RIGHT")

	local box = panel(mid, C.bg, C.line)
	box:SetSize(LIST_W - 24, 26)
	box:SetPoint("TOPLEFT", 12, -34)
	box:EnableMouse(true)
	local search = CreateFrame("EditBox", nil, box)
	search:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
	search:SetPoint("LEFT", 8, 0)
	search:SetPoint("RIGHT", -8, 0)
	search:SetHeight(20)
	search:SetAutoFocus(false)
	search:EnableMouse(true)
	search:SetMaxLetters(60)
	local hint = label(box, "GameFontHighlightSmall", C.muted)
	hint:SetPoint("LEFT", 10, 0)
	box:SetScript("OnMouseDown", function() search:SetFocus() end)
	search:SetScript("OnEditFocusGained", function() paint(box, C.bg, C.border) end)
	search:SetScript("OnEditFocusLost", function() paint(box, C.bg, C.line) end)
	search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	search:SetScript("OnTextChanged", function(self)
		showIf(hint, (self:GetText() or "") == "")
		UI.offset = 0
		UI:ScheduleRefresh(0.15)
	end)
	self.search, self.searchHint = search, hint

	self.onlineButton = pill(mid, 74, 20)
	self.onlineButton:SetPoint("TOPLEFT", 12, -66)
	self.onlineButton:SetScript("OnClick", function()
		ns.db.settings.onlineOnly = not ns.db.settings.onlineOnly
		UI.offset = 0
		UI:Refresh()
	end)
	-- recipe filter: known by somebody, known by nobody, all (click switches to the next)
	self.recipeButton = pill(mid, 140, 20)
	self.recipeButton:SetPoint("LEFT", self.onlineButton, "RIGHT", 4, 0)
	self.recipeButton:SetScript("OnClick", function(self)
		if self.disabled then return end
		ns.db.settings.recipeFilter = RECIPE_FILTERS[ns.db.settings.recipeFilter] or "known"
		UI.offset = 0
		UI.selected = nil
		UI:Refresh()
	end)
	self.recipeButton:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(ns.T("RECIPE_FILTER_HINT"), 1, 1, 1, true)
		GameTooltip:Show()
	end)
	self.recipeButton:HookScript("OnLeave", function() GameTooltip:Hide() end)
	-- player filter: a button that opens a menu of everyone who has recipes
	self.playerButton = pill(mid, 84, 20)
	self.playerButton:SetPoint("TOPRIGHT", -12, -66)
	self.playerButton:SetScript("OnClick", function()
		if UI.playerMenu:IsShown() then
			UI.playerMenu:Hide()
		else
			UI.menuOffset = 0
			UI.playerMenu:Show()
			UI:DrawPlayerMenu()
		end
	end)
	local menu = panel(mid, C.bg, C.border)
	menu:SetFrameLevel((mid:GetFrameLevel() or 1) + 30)
	menu:SetSize(MENU_W, MENU_ROWS * MENU_STEP + 8)
	menu:SetPoint("TOPRIGHT", self.playerButton, "BOTTOMRIGHT", 0, -2)
	menu:EnableMouse(true)
	menu:EnableMouseWheel(true)
	menu:SetScript("OnMouseWheel", function(_, delta) UI:ScrollPlayerMenu(delta) end)
	menu:Hide()
	menu.rows = {}
	for i = 1, MENU_ROWS do
		local row = CreateFrame("Button", nil, menu)
		row:SetSize(MENU_W - 10, MENU_STEP - 1)
		row:SetPoint("TOPLEFT", 5, -4 - (i - 1) * MENU_STEP)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(unpack(C.clear))
		row.left = label(row, "GameFontHighlightSmall", C.text)
		row.left:SetPoint("LEFT", 6, 0)
		row.left:SetWidth(MENU_W - 60)
		row.right = label(row, "GameFontHighlightSmall", C.muted)
		row.right:SetPoint("RIGHT", -6, 0)
		row.right:SetJustifyH("RIGHT")
		row:EnableMouseWheel(true)
		row:SetScript("OnMouseWheel", function(_, delta) UI:ScrollPlayerMenu(delta) end)
		row:SetScript("OnEnter", function(self) self.bg:SetColorTexture(unpack(C.hover)) end)
		row:SetScript("OnLeave", function(self) self.bg:SetColorTexture(unpack(self.active and C.selected or C.clear)) end)
		row:SetScript("OnClick", function(self)
			local d = self.data
			if not d then return end
			UI.memberFilter, UI.memberFilterName = d.guid, d.guid and d.name or nil
			UI.selected = nil
			UI.offset = 0
			menu:Hide()
			UI:Refresh()
		end)
		menu.rows[i] = row
	end
	self.playerMenu = menu
	hline(mid, 10, -92, LIST_W - 20)

	local list = CreateFrame("Frame", nil, mid)
	list:SetSize(LIST_W - 22, LIST_ROWS * ROW_STEP)
	list:SetPoint("TOPLEFT", 10, -98)
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, delta) UI:Scroll(delta) end)
	self.list, self.rows = list, {}
	for i = 1, LIST_ROWS do self.rows[i] = createListRow(list, i) end
	local track = list:CreateTexture(nil, "BACKGROUND")
	track:SetColorTexture(unpack(C.bg))
	track:SetWidth(4)
	track:SetPoint("TOPRIGHT", 0, 0)
	track:SetPoint("BOTTOMRIGHT", 0, 2)
	local thumb = list:CreateTexture(nil, "ARTWORK")
	thumb:SetColorTexture(unpack(C.gold))
	thumb:SetWidth(4)
	self.track, self.thumb = track, thumb
	self.listEmpty = label(list, "GameFontHighlight", C.muted)
	self.listEmpty:SetPoint("CENTER", -4, 20)
	self.listEmpty:SetWidth(LIST_W - 60)
	self.listEmpty:SetWordWrap(true)
	self.listEmpty:SetJustifyH("CENTER")

	-- right: details
	local det = panel(f, C.panel, C.line)
	det:SetSize(DETAIL_W, PANEL_H)
	det:SetPoint("TOPLEFT", 12 + SIDEBAR_W + GAP + LIST_W + GAP, PANEL_TOP)
	det:EnableMouseWheel(true)
	det:SetScript("OnMouseWheel", function(_, delta) UI:ScrollDetail(delta) end)
	local d = { frame = det }
	d.title = label(det, "GameFontNormal", C.gold)
	d.title:SetPoint("TOPLEFT", 12, -12)
	-- at the auction house: search the item, its reagents and its recipe item for current prices
	d.refreshButton = pill(det, 140, 18)
	d.refreshButton:SetPoint("TOPRIGHT", -10, -8)
	d.refreshButton:SetFrameLevel((det:GetFrameLevel() or 1) + 10)
	d.refreshButton:SetScript("OnClick", function() UI:RefreshPrices() end)
	d.refreshButton:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(ns.T("BTN_REFRESH"), C.gold[1], C.gold[2], C.gold[3])
		GameTooltip:AddLine(ns.T("REFRESH_HINT"), 1, 1, 1, true)
		GameTooltip:Show()
	end)
	d.refreshButton:HookScript("OnLeave", function() GameTooltip:Hide() end)
	d.refreshButton:Hide()
	hline(det, 10, -32, DETAIL_W - 20)
	d.empty = label(det, "GameFontHighlight", C.muted)
	d.empty:SetPoint("CENTER", 0, 20)
	d.empty:SetWidth(DETAIL_W - 60)
	d.empty:SetWordWrap(true)
	d.empty:SetJustifyH("CENTER")

	local body = CreateFrame("Frame", nil, det)
	body:SetAllPoints()
	d.body = body
	d.icon = body:CreateTexture(nil, "ARTWORK")
	d.icon:SetSize(40, 40)
	d.icon:SetPoint("TOPLEFT", 14, -42)
	d.name = label(body, "GameFontHighlightLarge", C.text)
	d.name:SetPoint("TOPLEFT", 64, -44)
	d.name:SetWidth(DETAIL_W - 80)
	d.sub = label(body, "GameFontHighlightSmall", C.muted)
	d.sub:SetPoint("TOPLEFT", 64, -64)
	d.sub:SetWidth(DETAIL_W - 80)
	d.value = label(body, "GameFontHighlightSmall", C.muted)
	d.value:SetPoint("TOPLEFT", 64, -78)
	d.value:SetWidth(DETAIL_W - 80)
	-- where the recipe comes from and its price at the auction house
	d.recipeInfo = label(body, "GameFontHighlightSmall", C.muted)
	d.recipeInfo:SetPoint("TOPLEFT", 14, -91)
	d.recipeInfo:SetWidth(DETAIL_W - 28)
	local hover = CreateFrame("Frame", nil, body)
	hover:SetPoint("TOPLEFT", 12, -40)
	hover:SetSize(DETAIL_W - 24, 54)
	hover:EnableMouse(true)
	hover:SetScript("OnEnter", function(self)
		local s = UI.selected
		if s and s.kind == "recipe" then showTooltip(self, function() recipeTooltip(self, s) end, { [s.itemID or 0] = true }) end
	end)
	hover:SetScript("OnLeave", hideTooltip)
	hover:SetScript("OnMouseUp", function()
		local s = UI.selected
		if s and s.kind == "recipe" and IsShiftKeyDown() then insertLink(s.recipeID, s.itemID) end
	end)

	-- recipe: reagents, cost, crafters
	local rb = CreateFrame("Frame", nil, body)
	rb:SetAllPoints()
	d.recipeBody = rb
	d.reagentTitle = label(rb, "GameFontNormal", C.gold)
	d.reagentTitle:SetPoint("TOPLEFT", 14, -104)
	d.reagentCount = label(rb, "GameFontHighlightSmall", C.muted)
	d.reagentCount:SetPoint("TOPRIGHT", -14, -106)
	d.reagentCount:SetJustifyH("RIGHT")
	hline(rb, 12, -122, DETAIL_W - 24)
	d.reagentRows = {}
	for i = 1, REAGENT_ROWS do d.reagentRows[i] = createReagentRow(rb, i) end
	d.reagentNote = label(rb, "GameFontHighlightSmall", C.muted)
	d.reagentNote:SetPoint("TOPLEFT", 16, REAGENT_TOP - 4)
	d.reagentNote:SetWidth(DETAIL_W - 32)
	d.reagentNote:SetWordWrap(true)
	local costTop = REAGENT_TOP - REAGENT_ROWS * REAGENT_STEP - 6
	hline(rb, 12, costTop, DETAIL_W - 24)
	d.costLabel = label(rb, "GameFontHighlightSmall", C.muted)
	d.costLabel:SetPoint("TOPLEFT", 16, costTop - 8)
	d.costValue = label(rb, "GameFontHighlightSmall", C.text)
	d.costValue:SetPoint("TOPRIGHT", -16, costTop - 8)
	d.costValue:SetJustifyH("RIGHT")
	d.profitLabel = label(rb, "GameFontHighlightSmall", C.muted)
	d.profitLabel:SetPoint("TOPLEFT", 16, costTop - 26)
	d.profitValue = label(rb, "GameFontHighlightSmall", C.text)
	d.profitValue:SetPoint("TOPRIGHT", -16, costTop - 26)
	d.profitValue:SetJustifyH("RIGHT")
	d.crafterTitle = label(rb, "GameFontNormal", C.gold)
	d.crafterTitle:SetPoint("TOPLEFT", 14, CRAFTER_TOP + 24)
	d.crafterCount = label(rb, "GameFontHighlightSmall", C.muted)
	d.crafterCount:SetPoint("TOPRIGHT", -14, CRAFTER_TOP + 22)
	d.crafterCount:SetJustifyH("RIGHT")
	hline(rb, 12, CRAFTER_TOP + 6, DETAIL_W - 24)
	d.crafterRows = {}
	for i = 1, CRAFTER_ROWS do d.crafterRows[i] = createDetailRow(rb, i, CRAFTER_TOP, CRAFTER_STEP) end
	d.recipeHint = label(rb, "GameFontHighlightSmall", C.muted)
	d.recipeHint:SetPoint("BOTTOMLEFT", 14, 42)
	d.recipeHint:SetWidth(DETAIL_W - 28)
	local half = (DETAIL_W - 34) / 2
	d.linkButton = pill(rb, half, 24)
	d.linkButton:SetPoint("BOTTOMLEFT", 14, 12)
	d.linkButton:SetScript("OnClick", function()
		local s = UI.selected
		if s and s.kind == "recipe" then insertLink(s.recipeID, s.itemID) end
	end)
	d.shopButton = pill(rb, half, 24)
	d.shopButton:SetPoint("BOTTOMRIGHT", -14, 12)
	d.shopButton:SetScript("OnClick", function(self)
		local s = UI.selected
		if self.disabled or not s or s.kind ~= "recipe" then return end
		local reagents = ns.reagents and ns.reagents:Get(s.recipeID)
		local ok, why = ns.Prices.ShoppingList(s.name, reagents, 1)
		if ok then
			ns.Say("SHOP_DONE", s.name)
		elseif why == "names" then
			ns.Say("SHOP_NAMES")
		else
			ns.Say("SHOP_FAILED")
		end
	end)
	d.shopButton:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(ns.T("BTN_SHOP"), C.gold[1], C.gold[2], C.gold[3])
		GameTooltip:AddLine(ns.T(ns.Prices.CanShop() and "SHOP_HINT" or "SHOP_NEEDS"), 1, 1, 1, true)
		GameTooltip:Show()
	end)
	d.shopButton:HookScript("OnLeave", function() GameTooltip:Hide() end)

	-- member: professions
	local mb = CreateFrame("Frame", nil, body)
	mb:SetAllPoints()
	d.memberBody = mb
	d.section = label(mb, "GameFontNormal", C.gold)
	d.section:SetPoint("TOPLEFT", 14, -104)
	d.count = label(mb, "GameFontHighlightSmall", C.muted)
	d.count:SetPoint("TOPRIGHT", -14, -106)
	d.count:SetJustifyH("RIGHT")
	hline(mb, 12, -122, DETAIL_W - 24)
	d.profRows = {}
	for i = 1, DETAIL_ROWS do d.profRows[i] = createDetailRow(mb, i, -128, DETAIL_STEP) end
	d.hint = label(mb, "GameFontHighlightSmall", C.muted)
	d.hint:SetPoint("BOTTOMLEFT", 14, 44)
	d.hint:SetWidth(DETAIL_W - 28)
	d.hint:SetWordWrap(true)
	d.whisperButton = pill(mb, DETAIL_W - 28, 24)
	d.whisperButton:SetPoint("BOTTOMLEFT", 14, 12)
	d.whisperButton:SetScript("OnClick", function()
		local s = UI.selected
		if s and s.kind == "member" then openWhisper(whisperName(s.guid)) end
	end)
	d.rows, d.action = d.crafterRows, d.linkButton
	self.detail = d

	-- footer
	local foot = panel(f, C.panel, C.line)
	foot:SetHeight(FOOTER_H)
	foot:SetPoint("BOTTOMLEFT", 12, 10)
	foot:SetPoint("BOTTOMRIGHT", -12, 10)
	self.status = label(foot, "GameFontHighlightSmall", C.muted)
	self.status:SetPoint("LEFT", 10, 0)
	self.status:SetWidth(WIDTH - 180)
	self.syncButton = pill(foot, 120, 22)
	self.syncButton:SetPoint("RIGHT", -4, 0)
	self.syncButton:SetScript("OnClick", function()
		ns.SyncNow()
	end)

	local saved = ns.db.settings.category
	self.category = type(saved) == "number" and saved or nil

	f:SetScript("OnShow", function()
		ns.Prices.StartRecipeIndex()
		UI:Refresh()
	end)
	f:SetScript("OnHide", function()
		search:ClearFocus()
		menu:Hide()
	end)
	local events = CreateFrame("Frame", nil, f)
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	-- the refresh button is shown only while the auction house is open
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_SHOW")
	pcall(events.RegisterEvent, events, "AUCTION_HOUSE_CLOSED")
	-- Items arrive by the dozen while the queue loads: the list is rebuilt (and the recipe items
	-- of the auction house matched) at most once per ITEM_REBUILD seconds, not for every item.
	local rebuildPending = false
	events:SetScript("OnEvent", function(_, event, itemID, success)
		if event ~= "GET_ITEM_INFO_RECEIVED" then
			-- a scan may have added recipe items to the auction database
			if event == "AUCTION_HOUSE_CLOSED" then ns.Prices.StartRecipeIndex(true) end
			if f:IsShown() then UI:ScheduleRefresh(0.3) end
			return
		end
		UI:OnItemInfo(itemID)
		-- items loaded for other reasons (bags, chat, Auctionator) change nothing in the list
		local asked = ns.Scanner.WasAsked(itemID)
		-- a load that failed keeps its request time, so it is retried only after ITEM_RETRY
		if success ~= false then ns.Scanner.Arrived(itemID) end
		if rebuildPending or not asked then return end
		rebuildPending = true
		C_Timer.After(UI.ITEM_REBUILD, function()
			rebuildPending = false
			ns.Prices.ResolveRecipeItems()
			UI.nameEpoch = (UI.nameEpoch or 0) + 1 -- item names arrived: rebuild the list
			if f:IsShown() then UI:ScheduleRefresh(0.1) end
		end)
	end)
end

---------------------------------------------------------------------------
-- State changes
---------------------------------------------------------------------------

function UI:Toggle()
	self:Create()
	if self.frame:IsShown() then self.frame:Hide() else self.frame:Show() end
end

function UI:SetView(view)
	if view == "members" then self.memberFilter = nil end
	if self.playerMenu then self.playerMenu:Hide() end
	self.view = view
	self.selected = nil
	self.offset = 0
	self.levelJump = view == "leveling"
	self:Refresh()
end

-- skillLine nil = all professions
function UI:SetCategory(skillLine)
	self.category = skillLine
	ns.db.settings.category = skillLine
	self.offset = 0
	self.levelJump = self.view == "leveling"
	self:Refresh()
end

function UI:Scroll(delta)
	self.offset = (self.offset or 0) - (delta or 0) * 2
	self:Refresh()
end

function UI:ScrollPlayerMenu(delta)
	self.menuOffset = (self.menuOffset or 0) - (delta or 0) * 3
	self:DrawPlayerMenu()
end

-- Everyone who has at least one recipe (not stale, online filter), online first.
function UI:PlayerEntries()
	local list = {}
	local store = ns.store
	if not store then return list end
	local onlineOnly = ns.db.settings.onlineOnly
	local now, staleDays = GetServerTime(), ns.StaleDays()
	for guid, rec in pairs(store:All()) do
		local online = store:IsOnline(guid)
		if not store:IsStale(guid, staleDays, now) and (online or not onlineOnly) then
			local n = 0
			for _, prof in pairs(rec.p) do
				for _ in pairs(prof.r) do n = n + 1 end
			end
			if n > 0 then
				list[#list + 1] = { guid = guid, name = ns.DisplayName(guid, rec), online = online, class = rec.c, recipes = n }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return list
end

function UI:DrawPlayerMenu()
	local menu = self.playerMenu
	if not menu or not menu:IsShown() then return end
	local entries = self:PlayerEntries()
	table.insert(entries, 1, { name = ns.T("PLAYER_MENU_ALL") }) -- no guid: clears the filter
	local maxOffset = math.max(0, #entries - MENU_ROWS)
	self.menuOffset = math.max(0, math.min(maxOffset, math.floor(self.menuOffset or 0)))
	for i = 1, MENU_ROWS do
		local row, e = menu.rows[i], entries[self.menuOffset + i]
		row.data = e
		if e then
			row.active = e.guid == self.memberFilter
			row.left:SetText(e.guid and ((e.online and HEX_ONLINE or HEX_OFFLINE) .. "•|r " .. classColored(e.name, e.class)) or (HEX_GOLD .. e.name .. "|r"))
			row.right:SetText(e.recipes and tostring(e.recipes) or "")
			row.bg:SetColorTexture(unpack(row.active and C.selected or C.clear))
			row:Show()
		else
			row:Hide()
		end
	end
	menu:SetHeight(math.min(#entries, MENU_ROWS) * MENU_STEP + 8)
end

function UI:ScrollReagents(delta)
	self.reagentOffset = (self.reagentOffset or 0) - (delta or 0)
	self:Refresh()
end

function UI:ScrollDetail(delta)
	self.detailOffset = (self.detailOffset or 0) - (delta or 0) * 2
	self:Refresh()
end

function UI:ApplyTexts()
	if self.frame then self:Refresh() end
end

function UI:OnLanguageChanged()
	if self.frame and self.frame:IsShown() then self:Refresh() end
end

local refreshToken = 0
function UI:ScheduleRefresh(delay)
	refreshToken = refreshToken + 1
	local token = refreshToken
	C_Timer.After(delay or 0.2, function()
		if token == refreshToken and UI.frame and UI.frame:IsShown() then UI:Refresh() end
	end)
end

-- Core already limits these notices to one per half second.
function UI:OnDataChanged()
	if self.frame and self.frame:IsShown() then self:Refresh() end
end

-- An error while drawing is reported once and kept for /pg status.
local reportedError = false
function UI:Refresh()
	if not self.frame then return end
	local ok, err = pcall(self.Draw, self)
	if not ok then
		ns.lastError = "UI: " .. tostring(err)
		ns.Log("ERROR %s", ns.lastError)
		if not reportedError then
			reportedError = true
			ns.Print("%s", ns.lastError)
		end
	end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

function UI:DrawSidebar(counts, shown)
	local entries = { { name = ns.T("CATEGORY_ALL"), icon = ALL_ICON, count = 0 } }
	for skillLine, n in pairs(counts) do
		entries[1].count = entries[1].count + n
		entries[#entries + 1] = { skillLine = skillLine, name = ns.Scanner.ProfessionName(skillLine), icon = PROF_ICONS[skillLine] or QUESTION, count = n }
	end
	if self.view == "members" then entries[1].count = self.memberTotal or 0 end
	table.sort(entries, function(a, b)
		if not a.skillLine then return b.skillLine ~= nil end
		if not b.skillLine then return false end
		return a.name < b.name
	end)
	for i, e in ipairs(entries) do
		local b = self.profButtons[i] or createProfButton(self.sidebar, i)
		self.profButtons[i] = b
		b.skillLine = e.skillLine
		b.active = e.skillLine == shown
		setIcon(b.icon, e.icon)
		b.name:SetText(e.name)
		b.name:SetTextColor(unpack(b.active and C.gold or C.text))
		b.count:SetText(tostring(e.count))
		b.bg:SetColorTexture(unpack(b.active and C.selected or C.clear))
		showIf(b.bar, b.active)
		b:Show()
	end
	for i = #entries + 1, #self.profButtons do self.profButtons[i]:Hide() end
end

function UI:DrawList(data)
	local total = #data
	local maxOffset = math.max(0, total - LIST_ROWS)
	self.offset = math.max(0, math.min(maxOffset, math.floor(self.offset or 0)))
	for i = 1, LIST_ROWS do
		local row, d = self.rows[i], data[self.offset + i]
		row.data = d
		if d then
			-- a group header: gold title at the bottom of the row, next to its first recipe
			local header = d.kind == "header"
			if header ~= row.isHeader then
				row.isHeader = header
				row.name:ClearAllPoints()
				if header then
					row.name:SetPoint("BOTTOMLEFT", 6, 5)
					row.name:SetWidth(LIST_W - 48)
				else
					row.name:SetPoint("TOPLEFT", 40, -4)
					row.name:SetWidth(LIST_W - 86)
				end
				showIf(row.icon, not header)
			end
			-- a recipe nobody in the guild knows has a grey icon
			row.icon:SetDesaturated(d.kind == "recipe" and d.nobody or false)
			-- items on screen are loaded first
			if d.kind == "recipe" then ns.Scanner.WantItem(d.itemID, true) end
			local profit = d.kind == "recipe" and craftProfit(d) or nil
			row.profit:SetText(profit and ((profit < 0 and HEX_LOSS or HEX_PROFIT) .. ns.Prices.Short(profit) .. "|r") or "")
			if not header then row.name:SetWidth(LIST_W - 86 - (profit and 44 or 0)) end
			local req = d.kind == "recipe" and d.req or -1
			row.level:SetText(req > 1 and ns.T("LIST_LEVEL", req) or "")
			row.sub:SetWidth(LIST_W - 86 - (req > 1 and 40 or 0))
			if header then
				row.name:SetText(HEX_GOLD .. d.title .. "|r")
				row.sub:SetText("")
			elseif d.kind == "recipe" then
				setIcon(row.icon, recipeIcon(d))
				row.name:SetText(ownColorDot(d.recipeID) .. qualityName(d))
				local who = #d.crafters > 0 and crafterText(d.crafters, 3)
					or (HEX_MUTED .. ns.T(d.nobody and "NOBODY_KNOWS" or "NOBODY_ONLINE") .. "|r")
				if d.nobody then
					local _, short = recipeItemText(d.recipeID)
					if short and short ~= "" then who = who .. HEX_MUTED .. " · |r" .. short end
				end
				if self.view == "leveling" then
					-- the skill levels go first: learnable from (red) and grey from
					local skill = recipeSkillText(d.recipeID)
					who = (skill and (skill .. "  ") or (HEX_MUTED .. ns.T("SKILL_UNKNOWN") .. "|r  ")) .. who
				end
				row.sub:SetText((self.shownCategory and "" or (HEX_GOLD .. d.prof .. "|r  ")) .. who)
			else
				setClassIcon(row.icon, d.rec.c)
				row.name:SetText(classColored(d.name, d.rec.c) .. (d.online and (" " .. HEX_ONLINE .. ns.T("STATE_ONLINE") .. "|r") or ""))
				row.sub:SetText(d.profs ~= "" and d.profs or "-")
			end
			rowColor(row)
			row:Show()
		else
			row:Hide()
		end
	end
	-- scroll position indicator
	local trackH = LIST_ROWS * ROW_STEP - 2
	if maxOffset > 0 then
		local thumbH = math.max(20, trackH * LIST_ROWS / total)
		self.thumb:SetHeight(thumbH)
		self.thumb:ClearAllPoints()
		self.thumb:SetPoint("TOPRIGHT", self.list, "TOPRIGHT", 0, -(trackH - thumbH) * self.offset / maxOffset)
		self.thumb:Show()
		self.track:Show()
	else
		self.thumb:Hide()
		self.track:Hide()
	end
end

local function fillRows(rows, lines, offset)
	for i = 1, #rows do
		local row, line = rows[i], lines[offset + i]
		row.data = line
		if line then
			if row.icon and line.icon then setIcon(row.icon, line.icon) end
			row.left:SetText(line.left)
			row.right:SetText(line.right or "")
			local fit = rawget(row, "fitSpec")
			if fit and row.right.GetStringWidth then
				local free = fit.width - fit.left - fit.right - (row.right:GetStringWidth() or 0) - 8
				row.left:SetWidth(math.max(40, math.min(fit.max, free)))
			end
			row:Show()
		else
			row:Hide()
		end
	end
end

local gameChecked = {} -- recipes the game was asked about in this session

-- Reagents, their cost and the value of the crafted item.
function UI:DrawReagents(s)
	local d = self.detail
	d.reagentTitle:SetText(ns.T("HEAD_REAGENTS"))
	if ns.reagents and not gameChecked[s.recipeID] then
		-- the game describes recipes we do not know ourselves; then no guildmate is needed,
		-- and what the game says replaces what a guildmate said
		gameChecked[s.recipeID] = true
		local fromGame = ns.Scanner.RecipeReagents(s.recipeID)
		if fromGame then ns.reagents:Set(s.recipeID, fromGame) end
	end
	local reagents = ns.reagents and ns.reagents:Get(s.recipeID)
	local lines = {}
	if reagents then
		for itemID, count in pairs(reagents) do
			local name = ns.Scanner.ItemName(itemID) or ("#" .. itemID)
			local price, kind = ns.Prices.Get(itemID)
			local right = price and ns.Prices.Format(price * count) or (HEX_MUTED .. "?|r")
			-- an auction price counts; a vendor that also sells it is shown beside it
			local vendor = kind == "ah" and ns.Prices.VendorPrice(itemID)
			if vendor then
				right = HEX_MUTED .. "(" .. ns.T("PRICE_VENDOR") .. " " .. ns.Prices.Format(vendor * count) .. ")|r  " .. right
			end
			local onMarket = kind == "ah" and ns.Prices.Available(itemID)
			if onMarket then right = HEX_MUTED .. ns.T("PCS", onMarket) .. "|r  " .. right end
			if kind == "vendor" then right = HEX_MUTED .. ns.T("PRICE_VENDOR") .. "|r " .. right end
			lines[#lines + 1] = { itemID = itemID, count = count, name = name,
				icon = safeCall(C_Item and C_Item.GetItemIconByID, itemID) or safeCall(GetItemIcon, itemID) or QUESTION,
				left = string.format("%dx %s", count, name), right = right }
		end
		table.sort(lines, function(a, b) return a.name < b.name end)
		d.reagentNote:Hide()
	else
		if ns.reagents then ns.reagents:Want(s.recipeID) end
		d.reagentNote:SetText(ns.T(ns.reagents and ns.reagents:IsAsking(s.recipeID) and "REAGENTS_ASKING" or "REAGENTS_UNKNOWN"))
		d.reagentNote:Show()
	end
	-- more reagents than rows: the mouse wheel scrolls them and the heading says which are shown
	local maxOffset = math.max(0, #lines - REAGENT_ROWS)
	self.reagentOffset = math.max(0, math.min(maxOffset, math.floor(self.reagentOffset or 0)))
	if not reagents then
		d.reagentCount:SetText("")
	elseif maxOffset > 0 then
		d.reagentCount:SetText(string.format("%d-%d / %d", self.reagentOffset + 1, self.reagentOffset + REAGENT_ROWS, #lines))
	else
		d.reagentCount:SetText(tostring(#lines))
	end
	fillRows(d.reagentRows, lines, self.reagentOffset)

	-- cost of one craft and what the item sells for
	local source = ns.Prices.Source()
	local bop = ns.Scanner.ItemBoP(s.itemID)
	local value, valueSource
	if s.itemID and s.itemID > 0 then
		if bop then value = 0 else value, valueSource = ns.Prices.SaleValue(s.itemID) end
	end
	local skill = recipeSkillText(s.recipeID)
	local valueText = bop and (HEX_LOSS .. ns.T("ITEM_BOP") .. "|r")
		or (value and ns.T(valueSource == "vendor" and "ITEM_VALUE_VENDOR" or "ITEM_VALUE", ns.Prices.Format(value))) or ""
	local onMarket = value and not bop and valueSource ~= "vendor" and ns.Prices.Available(s.itemID)
	if onMarket then valueText = valueText .. " " .. HEX_MUTED .. "(" .. ns.T("PCS", onMarket) .. ")|r" end
	if skill then valueText = valueText ~= "" and (valueText .. "  ·  " .. skill) or skill end
	d.value:SetText(valueText)
	d.costLabel:SetText(ns.T("COST_LABEL"))
	d.profitLabel:SetText(ns.T("PROFIT_LABEL"))
	if not source then
		d.costValue:SetText(HEX_MUTED .. ns.T("NO_PRICES") .. "|r")
		d.profitValue:SetText("")
	elseif not reagents then
		d.costValue:SetText("-")
		d.profitValue:SetText("-")
	else
		local total, missing = ns.Prices.Cost(reagents)
		d.costValue:SetText(ns.Prices.Format(total) .. (missing > 0 and (HEX_MUTED .. " " .. ns.T("COST_MISSING", missing) .. "|r") or ""))
		if value and missing == 0 then
			local profit = ns.Prices.AfterCut(value * ns.Scanner.RecipeOutputCount(s.recipeID), valueSource) - total
			d.profitValue:SetText((profit < 0 and (HEX_LOSS .. "-|r") or "") .. ns.Prices.Format(math.abs(profit)))
		else
			d.profitValue:SetText("-")
		end
	end
	setPill(d.shopButton, ns.T("BTN_SHOP"), false, not (reagents and ns.Prices.CanShop()))
end

-- Searches the auction house (through Auctionator) for the selected recipe's item, reagents
-- and recipe item; the window is drawn again when Auctionator has saved the prices.
function UI:RefreshPrices()
	local s = self.selected
	if not s or s.kind ~= "recipe" then return end
	local ids = {}
	if s.itemID and s.itemID > 0 and not ns.Scanner.ItemBoP(s.itemID) then ids[#ids + 1] = s.itemID end
	local reagents = (ns.reagents and ns.reagents:Get(s.recipeID)) or ns.Scanner.RecipeReagents(s.recipeID) or {}
	local sorted = {}
	for itemID in pairs(reagents) do sorted[#sorted + 1] = itemID end
	table.sort(sorted)
	for _, itemID in ipairs(sorted) do ids[#ids + 1] = itemID end
	local recipeItem = ns.Prices.RecipeItem(s.recipeID)
	if recipeItem then ids[#ids + 1] = recipeItem end
	local function redraw()
		UI.listCache = nil
		UI:ScheduleRefresh(0.5) -- Auctionator saves the prices a frame after its notice
	end
	local n, why = ns.Prices.Refresh(ids, redraw)
	if n then
		ns.Say("REFRESH_STARTED", n)
		-- in case a notice is missed: draw again a few times while the search runs
		for _, delay in ipairs({ 1, 3, 6 }) do C_Timer.After(delay, redraw) end
	elseif why == "names" then
		for _, itemID in ipairs(ids) do ns.Scanner.WantItem(itemID, true) end
		ns.Say("SHOP_NAMES")
	elseif why == "closed" then
		ns.Say("REFRESH_CLOSED")
	else
		ns.Say("SHOP_FAILED")
	end
end

function UI:DrawDetail()
	local d, s = self.detail, self.selected
	d.title:SetText(ns.T("HEAD_DETAILS"))
	setPill(d.refreshButton, ns.T("BTN_REFRESH"), false)
	showIf(d.refreshButton, s ~= nil and s.kind == "recipe" and ns.Prices.CanRefresh())
	if not s then
		d.body:Hide()
		d.empty:SetText(ns.T(self.view == "members" and "PICK_MEMBER" or "PICK_RECIPE"))
		d.empty:Show()
		return
	end
	d.empty:Hide()
	d.body:Show()

	local lines = {}
	if s.kind == "recipe" then
		d.recipeBody:Show()
		d.memberBody:Hide()
		d.rows, d.action = d.crafterRows, d.linkButton
		setIcon(d.icon, recipeIcon(s))
		d.name:SetText(qualityName(s))
		local _, req = ns.Scanner.ItemLevel(s.itemID)
		d.sub:SetText(s.prof .. ((req and req > 1) and ("  " .. HEX_MUTED .. ns.T("REQ_LEVEL", req) .. "|r") or ""))
		d.recipeInfo:SetText((recipeItemText(s.recipeID, true)) or "")
		self:DrawReagents(s)
		d.crafterTitle:SetText(ns.T("HEAD_CRAFTERS"))
		d.crafterCount:SetText(tostring(#s.crafters))
		for _, c in ipairs(s.crafters) do
			lines[#lines + 1] = { guid = c.guid, left = classColored(c.name, c.rec and c.rec.c),
				right = c.online and (HEX_ONLINE .. ns.T("STATE_ONLINE") .. "|r") or daysText(c.rec) }
		end
		local hint = #s.crafters > CRAFTER_ROWS and "HINT_CRAFTER_SCROLL" or "HINT_CRAFTER"
		if #s.crafters == 0 then hint = s.nobody and "HINT_NOBODY" or "HINT_NOBODY_ONLINE" end
		d.recipeHint:SetText(ns.T(hint))
		setPill(d.linkButton, ns.T("BTN_LINK"), false)
	else
		d.recipeBody:Hide()
		d.memberBody:Show()
		d.rows, d.action = d.profRows, d.whisperButton
		local rec = s.rec
		setClassIcon(d.icon, rec.c)
		d.name:SetText(classColored(s.name, rec.c))
		d.sub:SetText(s.online and (HEX_ONLINE .. ns.T("STATE_ONLINE") .. "|r") or ns.T("MEMBER_UPDATED", daysText(rec)))
		d.value:SetText("")
		d.recipeInfo:SetText("")
		d.section:SetText(ns.T("HEAD_MEMBER_PROFS"))
		for skillLine, prof in pairs(rec.p) do
			local n = 0
			for _ in pairs(prof.r) do n = n + 1 end
			lines[#lines + 1] = { skillLine = skillLine, left = ns.Scanner.ProfessionName(skillLine),
				right = prof.k and ns.T("PROF_SKILL", prof.s or 0, prof.m or 0, n) or ns.T("NOT_SCANNED_HINT") }
		end
		table.sort(lines, function(a, b) return a.left < b.left end)
		d.count:SetText(tostring(#lines))
		local hint = ns.T("HINT_PROF")
		local alts = {}
		for _, guid in ipairs(rec.a and ns.store:Index().alts[rec.a] or {}) do
			if guid ~= s.guid then alts[#alts + 1] = ns.DisplayName(guid, ns.store:Get(guid)) end
		end
		if #alts > 0 then
			table.sort(alts)
			hint = ns.T("MEMBER_ALTS", table.concat(alts, ", ")) .. "\n" .. hint
		end
		d.hint:SetText(hint)
		setPill(d.whisperButton, ns.T("BTN_WHISPER"), false)
	end

	local maxOffset = math.max(0, #lines - #d.rows)
	self.detailOffset = math.max(0, math.min(maxOffset, math.floor(self.detailOffset or 0)))
	fillRows(d.rows, lines, self.detailOffset)
end

function UI:Draw()
	local query = (self.search:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local members = self.view == "members"
	local leveling = self.view == "leveling"

	-- texts that follow the language
	self.title:SetText(ns.T("WINDOW_TITLE"):upper())
	self.version:SetText(ns.version and ("v" .. ns.version) or "")
	self.subtitle:SetText(ns.T("SUBTITLE"))
	self.sideTitle:SetText(ns.T("HEAD_PROFESSIONS"))
	self.searchHint:SetText(ns.T("SEARCH_HINT"))
	setPill(self.recipesTab, ns.T("HEAD_RECIPES"), self.view == "recipes")
	setPill(self.levelingTab, ns.T("HEAD_LEVELING"), leveling)
	setPill(self.membersTab, ns.T("HEAD_MEMBERS"), members)
	setPill(self.onlineButton, ns.T(ns.db.settings.onlineOnly and "ONLINE_ON" or "ONLINE_OFF"), ns.db.settings.onlineOnly)
	local recipeFilter = ns.db.settings.recipeFilter or "known"
	setPill(self.recipeButton, ns.T(RECIPE_FILTER_TEXT[recipeFilter] or "RECIPES_KNOWN"), recipeFilter ~= "known",
		self.memberFilter ~= nil) -- a player filter lists that player's known recipes
	showIf(self.recipeButton, not members)
	setPill(self.syncButton, ns.T("BTN_SYNC"), false)

	-- The list is built once and kept while nothing it depends on changed, so scrolling and
	-- selecting do not walk the whole database again.
	local store = ns.store
	local key = table.concat({ self.view, query, tostring(self.category), tostring(ns.db.settings.onlineOnly),
		tostring(ns.db.settings.recipeFilter), ns.catalog and ns.catalog.revision or 0,
		tostring(self.memberFilter), tostring(store), store and store.revision or 0, store and store.rosterRevision or 0,
		tostring(ns.lang), self.nameEpoch or 0, ns.recipeInfoRevision or 0 }, "\1")
	local cache = self.listCache
	if not cache or cache.key ~= key then
		local build = members and self.BuildMemberRows or (leveling and self.BuildLevelingRows) or self.BuildRecipeRows
		local category = self.category
		local data, counts, total = build(self, query, category)
		-- a profession that is no longer visible (dropped, filtered) shows all of them instead
		if category and not counts[category] then
			category = nil
			data, counts, total = build(self, query, nil)
		end
		local listed = 0 -- rows without the group headers
		for _, d in ipairs(data) do if d.kind ~= "header" then listed = listed + 1 end end
		cache = { key = key, data = data, counts = counts, total = total, category = category, listed = listed }
		self.listCache = cache
	end
	local data, counts, category = cache.data, cache.counts, cache.category
	self.memberTotal = cache.total
	self.shownCategory = category
	-- leveling opens at the first recipe that still gives skill to this character
	if leveling and self.levelJump then
		self.levelJump = false
		local own = ns.OwnState and ns.OwnState()
		local mine = category and own and own.profs and own.profs[category]
		if mine and mine.s then
			for i, d in ipairs(data) do
				if d.grey and d.grey > mine.s then self.offset, self.levelStart = i - 1, i break end
			end
		end
	end

	-- keep the selection while it is still listed
	if self.selected then
		local found
		for _, d in ipairs(data) do if d.key == self.selected.key then found = d break end end
		self.selected = found
	end

	self:DrawSidebar(counts, category)

	self.listTitle:SetText(ns.T(members and "HEAD_MEMBERS" or (leveling and "HEAD_LEVELING") or "HEAD_RECIPES"))
	self.listCount:SetText(ns.T(members and "COUNT_MEMBERS" or "MEMBER_RECIPES", cache.listed))
	if members then
		self.playerButton:Hide()
		self.playerMenu:Hide()
	else
		-- a filtered player who left the guild (or was pruned) is not a filter any more
		if self.memberFilter and not (ns.store and ns.store:Get(self.memberFilter)) then
			self.memberFilter, self.memberFilterName = nil, nil
			self.listCache = nil
			return self:Draw()
		end
		setPill(self.playerButton, self.memberFilter and ns.T("PLAYER_ONE", self.memberFilterName or "?") or ns.T("PLAYER_ALL"),
			self.memberFilter ~= nil)
		self.playerButton:Show()
		self:DrawPlayerMenu()
	end
	self:DrawList(data)

	if not ns.store then
		self.listEmpty:SetText(ns.T("NO_GUILD"))
	elseif ns.store:Count() == 0 then
		self.listEmpty:SetText(ns.T("EMPTY_DB"))
	elseif cache.listed == 0 and not members and (ns.db.settings.recipeFilter or "known") ~= "known"
		and not self.memberFilter and not (ns.catalog and next(ns.catalog:All())) then
		-- the catalog fills only from opened profession windows (own or a guildmate's)
		self.listEmpty:SetText(ns.T("CATALOG_EMPTY"))
	elseif cache.listed == 0 then
		self.listEmpty:SetText(ns.T("NO_RESULTS"))
	else
		self.listEmpty:SetText("")
	end

	self:DrawDetail()

	local characters, recipes, peers = 0, 0, 0
	if ns.store then
		local now, staleDays = GetServerTime(), ns.StaleDays()
		for guid in pairs(ns.store:All()) do
			if not ns.store:IsStale(guid, staleDays, now) then characters = characters + 1 end
		end
		for _ in pairs(ns.store:Index().recipes) do recipes = recipes + 1 end
		peers = ns.sync and ns.sync:ActivePeers(1200) or 0
	end
	local statusText = ns.T("STATUSBAR", characters, recipes, peers)
	if ns.newerVersion then statusText = statusText .. "   " .. HEX_GOLD .. ns.T("UPDATE_SHORT", ns.newerVersion) .. "|r" end
	self.status:SetText(statusText)
end
