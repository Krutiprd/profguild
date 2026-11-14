-- Profguild: UI
-- Main window: search, Recipes / Members views, online filter, status line.

local _, ns = ...

local UI = {}
ns.UI = UI

local ROW_HEIGHT = 20
local MAX_ROWS = 500
local GREEN, GREY, WHITE = "|cff40ff40", "|cff9d9d9d", "|cffffffff"

UI.view = "recipes"     -- or "members"
UI.memberFilter = nil   -- guid whose recipes are shown

local recipeNameCache = {}
local function recipeName(recipeID, itemID)
	local name = recipeNameCache[recipeID]
	if name then return name end
	name = ns.Scanner.RecipeName(recipeID)
	if not name and itemID and itemID > 0 then name = ns.Scanner.ItemName(itemID) end
	if name then recipeNameCache[recipeID] = name end
	return name or ("#" .. recipeID)
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

---------------------------------------------------------------------------
-- Data for the views
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
				list[#list + 1] = { guid = guid, name = ns.DisplayName(guid, store:Get(guid)), online = online }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return list
end

function UI:BuildRecipeRows(query)
	local store = ns.store
	local rows = {}
	if not store then return rows end
	local index = store:Index()
	local onlineOnly = ns.db.settings.onlineOnly
	local now, staleDays = GetServerTime(), ns.StaleDays()
	for recipeID, entry in pairs(index.recipes) do
		local crafters = craftersOf(entry, onlineOnly, now, staleDays)
		if #crafters > 0 then
			local name = recipeName(recipeID, entry.itemID)
			local prof = ns.Scanner.ProfessionName(entry.skillLine)
			local item = ns.Scanner.ItemName(entry.itemID)
			local crafterHit = false
			if query ~= "" then
				for _, c in ipairs(crafters) do
					if c.name:lower():find(query, 1, true) then crafterHit = true break end
				end
			end
			if crafterHit or matches(query, name, prof, item) then
				rows[#rows + 1] = { kind = "recipe", recipeID = recipeID, itemID = entry.itemID, name = name, prof = prof, crafters = crafters }
			end
		end
	end
	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end

function UI:BuildMemberRows(query)
	local store = ns.store
	local rows = {}
	if not store then return rows end
	local onlineOnly = ns.db.settings.onlineOnly
	local now, staleDays = GetServerTime(), ns.StaleDays()
	for guid, rec in pairs(store:All()) do
		local online = store:IsOnline(guid)
		if not store:IsStale(guid, staleDays, now) and (online or not onlineOnly) then
			local name = ns.DisplayName(guid, rec)
			local profParts, profNames, recipeTotal = {}, {}, 0
			for skillLine, prof in pairs(rec.p) do
				local n = 0
				for _ in pairs(prof.r) do n = n + 1 end
				recipeTotal = recipeTotal + n
				local pname = ns.Scanner.ProfessionName(skillLine)
				profNames[#profNames + 1] = pname
				profParts[#profParts + 1] = string.format("%s %d%s", pname, prof.s, prof.k and string.format(" (%d)", n) or "")
			end
			table.sort(profParts)
			if matches(query, name, unpack(profNames)) then
				rows[#rows + 1] = { kind = "member", guid = guid, rec = rec, name = name, online = online, profs = table.concat(profParts, ", "), recipes = recipeTotal }
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return rows
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function crafterText(crafters, max)
	local parts = {}
	for i = 1, math.min(max, #crafters) do
		local c = crafters[i]
		parts[i] = (c.online and GREEN or GREY) .. c.name .. "|r"
	end
	local text = table.concat(parts, ", ")
	if #crafters > max then text = text .. " " .. ns.T("MORE_CRAFTERS", #crafters - max) end
	return text
end

local function rowOnEnter(row)
	local data = row.data
	if not data then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if data.kind == "recipe" then
		if ns.Tooltip then ns.Tooltip.suppress = true end
		local ok = false
		if data.itemID and data.itemID > 0 then ok = pcall(GameTooltip.SetItemByID, GameTooltip, data.itemID) end
		if not ok then pcall(GameTooltip.SetSpellByID, GameTooltip, data.recipeID) end
		if ns.Tooltip then ns.Tooltip.suppress = false end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(ns.T("CRAFTERS") .. ":", 0.2, 0.73, 1)
		for _, c in ipairs(data.crafters) do
			if c.online then GameTooltip:AddLine(c.name, 0.25, 1, 0.25) else GameTooltip:AddLine(c.name, 0.62, 0.62, 0.62) end
		end
		local first = data.crafters[1]
		if first then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(ns.T(first.online and "CLICK_WHISPER" or "NO_ONE_ONLINE", first.name), 1, 0.82, 0, true)
		end
	else
		local rec = data.rec
		GameTooltip:AddLine(classColored(data.name, rec.c))
		for skillLine, prof in pairs(rec.p) do
			local n = 0
			for _ in pairs(prof.r) do n = n + 1 end
			local right = prof.k and ns.T("MEMBER_RECIPES", n) or ns.T("NOT_SCANNED_HINT")
			GameTooltip:AddDoubleLine(string.format("%s %d/%d", ns.Scanner.ProfessionName(skillLine), prof.s, prof.m), right, 1, 1, 1, 0.7, 0.7, 0.7)
		end
		local index = ns.store:Index()
		local alts = {}
		for _, guid in ipairs(rec.a and index.alts[rec.a] or {}) do
			if guid ~= data.guid then alts[#alts + 1] = ns.DisplayName(guid, ns.store:Get(guid)) end
		end
		if #alts > 0 then
			table.sort(alts)
			GameTooltip:AddLine(ns.T("MEMBER_ALTS", table.concat(alts, ", ")), 0.8, 0.8, 0.8, true)
		end
		GameTooltip:AddLine(ns.T("MEMBER_UPDATED", daysText(rec)), 0.6, 0.6, 0.6)
		GameTooltip:AddLine(ns.T("MEMBER_CLICK"), 1, 0.82, 0, true)
	end
	GameTooltip:Show()
end

local function rowOnLeave() GameTooltip:Hide() end

local function rowOnClick(row)
	local data = row.data
	if not data then return end
	if data.kind == "recipe" then
		if IsShiftKeyDown() then
			insertLink(data.recipeID, data.itemID)
		elseif data.crafters[1] then
			openWhisper(whisperName(data.crafters[1].guid))
		end
	else
		UI.memberFilter = data.guid
		UI.memberFilterName = data.name
		UI:SetView("recipes")
	end
end

local function createRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_HEIGHT)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
	row.col1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.col1:SetPoint("LEFT", 4, 0)
	row.col1:SetWidth(220)
	row.col1:SetJustifyH("LEFT")
	row.col1:SetWordWrap(false)
	row.col2 = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.col2:SetPoint("LEFT", row.col1, "RIGHT", 6, 0)
	row.col2:SetWidth(110)
	row.col2:SetJustifyH("LEFT")
	row.col2:SetWordWrap(false)
	row.col3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.col3:SetPoint("LEFT", row.col2, "RIGHT", 6, 0)
	row.col3:SetPoint("RIGHT", -4, 0)
	row.col3:SetJustifyH("LEFT")
	row.col3:SetWordWrap(false)
	row:SetScript("OnEnter", rowOnEnter)
	row:SetScript("OnLeave", rowOnLeave)
	row:SetScript("OnClick", rowOnClick)
	row:RegisterForClicks("LeftButtonUp")
	return row
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

function UI:Create()
	if self.frame then return end
	local f = CreateFrame("Frame", "ProfguildFrame", UIParent, "BasicFrameTemplateWithInset")
	f:SetSize(700, 480)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	tinsert(UISpecialFrames, "ProfguildFrame")
	self.frame = f

	f.title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not f.TitleText then f.title:SetPoint("TOP", 0, -6) end

	local ok, search = pcall(CreateFrame, "EditBox", nil, f, "SearchBoxTemplate")
	if not ok then search = CreateFrame("EditBox", nil, f, "InputBoxTemplate") end
	search:SetSize(300, 22)
	search:SetPoint("TOPLEFT", 18, -32)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function() UI:ScheduleRefresh(0.15) end)
	search:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)
	self.search = search

	local recipesBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	recipesBtn:SetSize(90, 22)
	recipesBtn:SetPoint("LEFT", search, "RIGHT", 12, 0)
	recipesBtn:SetScript("OnClick", function() UI:SetView("recipes") end)
	self.recipesBtn = recipesBtn

	local membersBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	membersBtn:SetSize(90, 22)
	membersBtn:SetPoint("LEFT", recipesBtn, "RIGHT", 4, 0)
	membersBtn:SetScript("OnClick", function() UI.memberFilter = nil; UI:SetView("members") end)
	self.membersBtn = membersBtn

	local online = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
	online:SetSize(24, 24)
	online:SetPoint("LEFT", membersBtn, "RIGHT", 10, 0)
	online:SetScript("OnClick", function(btn)
		ns.db.settings.onlineOnly = btn:GetChecked() and true or false
		UI:Refresh()
	end)
	online.label = online:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	online.label:SetPoint("LEFT", online, "RIGHT", 2, 0)
	self.onlineCheck = online

	local filterText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	filterText:SetPoint("TOPLEFT", 20, -62)
	self.filterText = filterText
	local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	clearBtn:SetSize(70, 18)
	clearBtn:SetPoint("LEFT", filterText, "RIGHT", 8, 0)
	clearBtn:SetScript("OnClick", function() UI.memberFilter = nil; UI:Refresh() end)
	self.clearBtn = clearBtn

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -82)
	scroll:SetPoint("BOTTOMRIGHT", -32, 30)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(640, 1)
	scroll:SetScrollChild(content)
	self.scroll, self.content, self.rows = scroll, content, {}

	local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("CENTER", scroll, "CENTER")
	empty:SetWidth(500)
	self.empty = empty

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("BOTTOMLEFT", 18, 10)
	status:SetPoint("BOTTOMRIGHT", -18, 10)
	status:SetJustifyH("LEFT")
	self.status = status

	f:SetScript("OnShow", function()
		content:SetWidth(scroll:GetWidth())
		UI:Refresh()
	end)

	local events = CreateFrame("Frame", nil, f)
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:SetScript("OnEvent", function() if f:IsShown() then UI:ScheduleRefresh(0.5) end end)

	self:ApplyTexts()
end

function UI:ApplyTexts()
	if not self.frame then return end
	self.frame.title:SetText(ns.T("WINDOW_TITLE") .. " " .. (ns.version or ""))
	self.recipesBtn:SetText(ns.T("TAB_RECIPES"))
	self.membersBtn:SetText(ns.T("TAB_MEMBERS"))
	self.onlineCheck.label:SetText(ns.T("ONLINE_ONLY"))
	self.clearBtn:SetText(ns.T("CLEAR_FILTER"))
	if self.search.Instructions then self.search.Instructions:SetText(ns.T("SEARCH_HINT")) end
end

function UI:OnLanguageChanged()
	self:ApplyTexts()
	if self.frame and self.frame:IsShown() then self:Refresh() end
end

function UI:Toggle()
	self:Create()
	if self.frame:IsShown() then self.frame:Hide() else self.frame:Show() end
end

function UI:SetView(view)
	self.view = view
	self:Refresh()
end

local refreshToken = 0
function UI:ScheduleRefresh(delay)
	refreshToken = refreshToken + 1
	local token = refreshToken
	C_Timer.After(delay or 0.2, function()
		if token == refreshToken and UI.frame and UI.frame:IsShown() then UI:Refresh() end
	end)
end

function UI:OnDataChanged()
	if self.frame and self.frame:IsShown() then self:ScheduleRefresh(0.3) end
end

function UI:Refresh()
	if not self.frame then return end
	local query = (self.search:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	self.onlineCheck:SetChecked(ns.db.settings.onlineOnly)

	if self.view == "recipes" then self.recipesBtn:LockHighlight() else self.recipesBtn:UnlockHighlight() end
	if self.view == "members" then self.membersBtn:LockHighlight() else self.membersBtn:UnlockHighlight() end

	if self.memberFilter and self.view == "recipes" then
		self.filterText:SetText(ns.T("FILTER_MEMBER", self.memberFilterName or "?"))
		self.clearBtn:Show()
	else
		self.filterText:SetText("")
		self.clearBtn:Hide()
	end

	local data = self.view == "members" and self:BuildMemberRows(query) or self:BuildRecipeRows(query)
	local total = #data
	local shown = math.min(total, MAX_ROWS)

	for i = 1, shown do
		local row = self.rows[i]
		if not row then
			row = createRow(self.content)
			row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
			row:SetPoint("RIGHT", self.content, "RIGHT")
			self.rows[i] = row
		end
		local d = data[i]
		row.data = d
		if d.kind == "recipe" then
			row.col1:SetText(WHITE .. d.name .. "|r")
			row.col2:SetText(d.prof)
			row.col3:SetText(crafterText(d.crafters, 4))
		else
			row.col1:SetText(classColored(d.name, d.rec.c) .. (d.online and (" " .. GREEN .. "•|r") or ""))
			row.col2:SetText(daysText(d.rec))
			row.col3:SetText(d.profs ~= "" and d.profs or GREY .. "-|r")
		end
		row:Show()
	end
	for i = shown + 1, #self.rows do
		self.rows[i]:Hide()
		self.rows[i].data = nil
	end
	self.content:SetHeight(math.max(1, shown * ROW_HEIGHT))

	if not ns.store then
		self.empty:SetText(ns.T("NO_GUILD"))
	elseif ns.store:Count() == 0 then
		self.empty:SetText(ns.T("EMPTY_DB"))
	elseif total == 0 then
		self.empty:SetText(ns.T("NO_RESULTS"))
	else
		self.empty:SetText("")
	end

	local characters, recipes, peers = 0, 0, 0
	if ns.store then
		local now, staleDays = GetServerTime(), ns.StaleDays()
		for guid in pairs(ns.store:All()) do
			if not ns.store:IsStale(guid, staleDays, now) then characters = characters + 1 end
		end
		for _ in pairs(ns.store:Index().recipes) do recipes = recipes + 1 end
		peers = ns.sync and ns.sync:ActivePeers(1200) or 0
	end
	local text = ns.T("STATUSBAR", characters, recipes, peers)
	if total > MAX_ROWS then text = text .. "  |cffffd100" .. ns.T("MORE_RESULTS", MAX_ROWS) .. "|r" end
	self.status:SetText(text)
end
