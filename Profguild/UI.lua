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

UI.view = "recipes"     -- or "members"
UI.memberFilter = nil   -- guid whose recipes are shown
UI.category = nil       -- skill line shown, nil = all professions
UI.selected = nil       -- data of the selected list row
UI.offset = 0           -- first visible list row - 1
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
	if not name and itemID and itemID > 0 then name = ns.Scanner.ItemName(itemID) end
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

-- Recipes with at least one visible crafter. Returns the rows (sorted by name), the number
-- of recipes per profession counted before the search and profession filters, and their sum.
function UI:BuildRecipeRows(query, category)
	local store = ns.store
	local rows, counts, total = {}, {}, 0
	if not store then return rows, counts, total end
	local onlineOnly = ns.db.settings.onlineOnly
	local now, staleDays = GetServerTime(), ns.StaleDays()
	for recipeID, entry in pairs(store:Index().recipes) do
		local crafters = craftersOf(entry, onlineOnly, now, staleDays)
		if #crafters > 0 then
			local skillLine = entry.skillLine
			counts[skillLine] = (counts[skillLine] or 0) + 1
			total = total + 1
			if not category or category == skillLine then
				local name = recipeName(recipeID, entry.itemID)
				local prof = ns.Scanner.ProfessionName(skillLine)
				-- the item name is looked up only for a search: asking for it makes the game
				-- load the item, which must not happen for every recipe each time the list is drawn
				local hit = query == "" or matches(query, name, prof)
				if not hit then
					for _, c in ipairs(crafters) do
						if c.name:lower():find(query, 1, true) then hit = true break end
					end
				end
				if not hit then hit = matches(query, ns.Scanner.ItemName(entry.itemID)) end
				if hit then
					rows[#rows + 1] = { kind = "recipe", key = "r" .. recipeID, recipeID = recipeID, itemID = entry.itemID,
						skillLine = skillLine, name = name, prof = prof, crafters = crafters }
				end
			end
		end
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows, counts, total
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

local function recipeTooltip(owner, d)
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
	GameTooltip:AddLine(ns.T("ROW_HINT"), C.muted[1], C.muted[2], C.muted[3], true)
	GameTooltip:Show()
end

local function rowColor(row)
	local d = row.data
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
	row:RegisterForClicks("LeftButtonUp")
	row:EnableMouseWheel(true)
	row:SetScript("OnMouseWheel", function(_, delta) UI:Scroll(delta) end)
	row:SetScript("OnEnter", function(self)
		paint(self, C.hover, C.border)
		if self.data and self.data.kind == "recipe" then recipeTooltip(self, self.data) end
	end)
	row:SetScript("OnLeave", function(self)
		GameTooltip:Hide()
		rowColor(self)
	end)
	row:SetScript("OnClick", function(self)
		local d = self.data
		if not d then return end
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
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		pcall(GameTooltip.SetItemByID, GameTooltip, d.itemID)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.bg:SetColorTexture(unpack(C.clear))
		GameTooltip:Hide()
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
	self.recipesTab = pill(f, 110, 24)
	self.recipesTab:SetPoint("RIGHT", self.membersTab, "LEFT", -6, 0)
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

	self.onlineButton = pill(mid, 130, 20)
	self.onlineButton:SetPoint("TOPLEFT", 12, -66)
	self.onlineButton:SetScript("OnClick", function()
		ns.db.settings.onlineOnly = not ns.db.settings.onlineOnly
		UI.offset = 0
		UI:Refresh()
	end)
	self.filterChip = pill(mid, 170, 20)
	self.filterChip:SetPoint("TOPRIGHT", -12, -66)
	self.filterChip:SetScript("OnClick", function()
		UI.memberFilter = nil
		UI.offset = 0
		UI:Refresh()
	end)
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
	d.value:SetPoint("TOPLEFT", 64, -80)
	d.value:SetWidth(DETAIL_W - 80)
	local hover = CreateFrame("Frame", nil, body)
	hover:SetPoint("TOPLEFT", 12, -40)
	hover:SetSize(DETAIL_W - 24, 54)
	hover:EnableMouse(true)
	hover:SetScript("OnEnter", function(self)
		local s = UI.selected
		if s and s.kind == "recipe" then recipeTooltip(self, s) end
	end)
	hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
		if SlashCmdList and SlashCmdList.PROFGUILD then SlashCmdList.PROFGUILD("sync") end
	end)

	local saved = ns.db.settings.category
	self.category = type(saved) == "number" and saved or nil

	f:SetScript("OnShow", function() UI:Refresh() end)
	f:SetScript("OnHide", function() search:ClearFocus() end)
	local events = CreateFrame("Frame", nil, f)
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:SetScript("OnEvent", function()
		UI.nameEpoch = (UI.nameEpoch or 0) + 1 -- item names may have arrived: rebuild the list
		if f:IsShown() then UI:ScheduleRefresh(0.5) end
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
	self.view = view
	self.selected = nil
	self.offset = 0
	self:Refresh()
end

-- skillLine nil = all professions
function UI:SetCategory(skillLine)
	self.category = skillLine
	ns.db.settings.category = skillLine
	self.offset = 0
	self:Refresh()
end

function UI:Scroll(delta)
	self.offset = (self.offset or 0) - (delta or 0) * 2
	self:Refresh()
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
			if d.kind == "recipe" then
				setIcon(row.icon, recipeIcon(d))
				row.name:SetText(qualityName(d))
				row.sub:SetText((self.shownCategory and "" or (HEX_GOLD .. d.prof .. "|r  ")) .. crafterText(d.crafters, 3))
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
	local value = s.itemID and s.itemID > 0 and ns.Prices.Get(s.itemID)
	d.value:SetText(value and ns.T("ITEM_VALUE", ns.Prices.Format(value)) or "")
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
			local profit = value - total
			d.profitValue:SetText((profit < 0 and (HEX_LOSS .. "-|r") or "") .. ns.Prices.Format(math.abs(profit)))
		else
			d.profitValue:SetText("-")
		end
	end
	setPill(d.shopButton, ns.T("BTN_SHOP"), false, not (reagents and ns.Prices.CanShop()))
end

function UI:DrawDetail()
	local d, s = self.detail, self.selected
	d.title:SetText(ns.T("HEAD_DETAILS"))
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
		d.sub:SetText(s.prof)
		self:DrawReagents(s)
		d.crafterTitle:SetText(ns.T("HEAD_CRAFTERS"))
		d.crafterCount:SetText(tostring(#s.crafters))
		for _, c in ipairs(s.crafters) do
			lines[#lines + 1] = { guid = c.guid, left = classColored(c.name, c.rec and c.rec.c),
				right = c.online and (HEX_ONLINE .. ns.T("STATE_ONLINE") .. "|r") or daysText(c.rec) }
		end
		d.recipeHint:SetText(ns.T(#s.crafters > CRAFTER_ROWS and "HINT_CRAFTER_SCROLL" or "HINT_CRAFTER"))
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

	-- texts that follow the language
	self.title:SetText(ns.T("WINDOW_TITLE"):upper())
	self.version:SetText(ns.version and ("v" .. ns.version) or "")
	self.subtitle:SetText(ns.T("SUBTITLE"))
	self.sideTitle:SetText(ns.T("HEAD_PROFESSIONS"))
	self.searchHint:SetText(ns.T("SEARCH_HINT"))
	setPill(self.recipesTab, ns.T("HEAD_RECIPES"), not members)
	setPill(self.membersTab, ns.T("HEAD_MEMBERS"), members)
	setPill(self.onlineButton, ns.T(ns.db.settings.onlineOnly and "ONLINE_ON" or "ONLINE_OFF"), ns.db.settings.onlineOnly)
	setPill(self.syncButton, ns.T("BTN_SYNC"), false)

	-- The list is built once and kept while nothing it depends on changed, so scrolling and
	-- selecting do not walk the whole database again.
	local store = ns.store
	local key = table.concat({ self.view, query, tostring(self.category), tostring(ns.db.settings.onlineOnly),
		tostring(self.memberFilter), tostring(store), store and store.revision or 0, store and store.rosterRevision or 0,
		tostring(ns.lang), self.nameEpoch or 0 }, "\1")
	local cache = self.listCache
	if not cache or cache.key ~= key then
		local build = members and self.BuildMemberRows or self.BuildRecipeRows
		local category = self.category
		local data, counts, total = build(self, query, category)
		-- a profession that is no longer visible (dropped, filtered) shows all of them instead
		if category and not counts[category] then
			category = nil
			data, counts, total = build(self, query, nil)
		end
		cache = { key = key, data = data, counts = counts, total = total, category = category }
		self.listCache = cache
	end
	local data, counts, category = cache.data, cache.counts, cache.category
	self.memberTotal = cache.total
	self.shownCategory = category

	-- keep the selection while it is still listed
	if self.selected then
		local found
		for _, d in ipairs(data) do if d.key == self.selected.key then found = d break end end
		self.selected = found
	end

	self:DrawSidebar(counts, category)

	self.listTitle:SetText(ns.T(members and "HEAD_MEMBERS" or "HEAD_RECIPES"))
	self.listCount:SetText(ns.T(members and "COUNT_MEMBERS" or "MEMBER_RECIPES", #data))
	if self.memberFilter and not members then
		setPill(self.filterChip, ns.T("CHIP_MEMBER", self.memberFilterName or "?"), true)
		self.filterChip:Show()
	else
		self.filterChip:Hide()
	end
	self:DrawList(data)

	if not ns.store then
		self.listEmpty:SetText(ns.T("NO_GUILD"))
	elseif ns.store:Count() == 0 then
		self.listEmpty:SetText(ns.T("EMPTY_DB"))
	elseif #data == 0 then
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
	self.status:SetText(ns.T("STATUSBAR", characters, recipes, peers))
end
