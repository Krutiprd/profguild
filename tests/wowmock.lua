-- A small fake of the WoW client API, enough to load Profguild and run its code paths.
-- It is not a game simulation: it only catches runtime errors (nil calls, typos, bad
-- arguments) in Core, Comm, Scanner, Tooltip and UI before the addon reaches the game.

local M = {}

M.time = 1000
M.timers = {}
M.events = {}       -- frames registered per event
M.sent = {}         -- addon messages sent
M.chat = {}         -- chat output

local function noop() end

-- Generic widget: known methods behave, everything else is a harmless no-op.
local Widget = {}
function Widget.new(kind, name)
	local w = { _kind = kind, _shown = kind ~= "Frame" or true, _scripts = {}, _text = "", _checked = false, _children = {} }
	if name then _G[name] = w end
	return setmetatable(w, Widget)
end
Widget.__index = function(t, k)
	local v = rawget(Widget, k)
	if v then return v end
	return noop
end
function Widget:SetScript(event, fn) self._scripts[event] = fn end
function Widget:GetScript(event) return self._scripts[event] end
function Widget:HookScript(event, fn)
	local old = self._scripts[event]
	self._scripts[event] = function(...) if old then old(...) end fn(...) end
end
function Widget:RegisterEvent(event)
	M.events[event] = M.events[event] or {}
	table.insert(M.events[event], self)
end
function Widget:UnregisterEvent(event)
	for i, f in ipairs(M.events[event] or {}) do if f == self then table.remove(M.events[event], i) break end end
end
function Widget:Show() local was = self._shown; self._shown = true; if not was and self._scripts.OnShow then self._scripts.OnShow(self) end end
function Widget:Hide() self._shown = false end
function Widget:IsShown() return self._shown end
function Widget:SetText(t) self._text = t or ""; if self._scripts.OnTextChanged then self._scripts.OnTextChanged(self) end end
function Widget:GetText() return self._text end
-- about 5 pixels per visible character of a small font; colour codes take no room
function Widget:GetStringWidth() return #((self._text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * 5 end
function Widget:SetChecked(c) self._checked = c and true or false end
function Widget:GetChecked() return self._checked end
function Widget:SetPoint(...) self._points = (rawget(self, "_points") or 0) + 1 end
function Widget:ClearAllPoints() self._points = 0 end
function Widget:SetWidth(w) self._width = w end
function Widget:SetSize(w, h) self._width, self._height = w, h end
-- like the game: a frame sized only by anchors has no width until it is anchored
function Widget:GetWidth()
	if rawget(self, "_width") then return self._width end
	if self._kind == "ScrollFrame" and (rawget(self, "_points") or 0) == 0 then return 0 end
	return 640
end
function Widget:GetHeight() return 400 end
function Widget:CreateFontString() return Widget.new("FontString") end
function Widget:CreateTexture() return Widget.new("Texture") end
function Widget:GetItem() return "Bolt of Silk Cloth", "|Hitem:4305::|h[Bolt]|h" end
function Widget:AddLine(text) table.insert(M.tooltipLines, text) end

M.tooltipLines = {}

function M.install()
	-- a fresh game: timers and event frames of an addon loaded by an earlier test are gone
	M.timers, M.events = {}, {}
	-- WoW's Lua passes extra arguments through xpcall; stock Lua 5.1 does not.
	local rawXpcall = M.rawXpcall or xpcall
	M.rawXpcall = rawXpcall
	_G.xpcall = function(f, handler, ...)
		local n, args = select("#", ...), { ... }
		return rawXpcall(function() return f(unpack(args, 1, n)) end, handler)
	end
	_G.CreateFrame = function(kind, name, parent, template)
		local w = Widget.new(kind, name)
		if template == "BasicFrameTemplateWithInset" then
			w.TitleText = Widget.new("FontString")
			w.CloseButton = Widget.new("Button")
			-- the game's close button hides its parent
			w.CloseButton._scripts.OnClick = function() w:Hide() end
		end
		if template == "SearchBoxTemplate" then w.Instructions = Widget.new("FontString") end
		if kind == "Frame" or kind == "Button" or kind == "CheckButton" then w._shown = true end
		return w
	end
	_G.UIParent = Widget.new("Frame")
	_G.Minimap = Widget.new("Frame")
	_G.Minimap.GetWidth = function() return 140 end
	_G.Minimap.GetCenter = function() return 500, 400 end
	_G.Minimap.GetEffectiveScale = function() return 1 end
	_G.GetCursorPosition = function() return M.cursorX or 0, M.cursorY or 0 end
	_G.GameTooltip = Widget.new("GameTooltip")
	_G.ItemRefTooltip = Widget.new("GameTooltip")
	_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(M.chat, msg) end }
	_G.UISpecialFrames = {}
	_G.tinsert = table.insert
	_G.unpack = unpack
	_G.SlashCmdList = {}
	M.errorHandler = function(e) error(e) end
	_G.geterrorhandler = function() return M.errorHandler end
	_G.seterrorhandler = function(fn) M.errorHandler = fn end
	_G.securecallfunction = function(fn, ...) return fn(...) end
	_G.hooksecurefunc = function() end
	_G.issecretvalue = function() return false end
	_G.Ambiguate = function(name) return (name:gsub("%-.*$", "")) end
	_G.strsub, _G.strlen, _G.strfind, _G.strmatch, _G.format = string.sub, string.len, string.find, string.match, string.format
	_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	_G.debugstack = function() return "" end

	_G.GetTime = function() return M.time end
	_G.GetFramerate = function() return 60 end
	_G.GetServerTime = function() return math.floor(1794615000 + M.time) end -- whole seconds
	_G.GetBuildInfo = function() return "1.60.1", "70685", "Nov 2026", 16001 end
	_G.GetLocale = function() return "enUS" end
	_G.C_AddOns = { GetAddOnMetadata = function(_, key) if key == "Version" then return "0.1.0-test" end end }

	_G.C_Timer = {
		After = function(delay, fn) table.insert(M.timers, { at = M.time + delay, fn = fn }) end,
		NewTicker = function(interval, fn) table.insert(M.timers, { at = M.time + interval, fn = fn, every = interval }) return {} end,
	}

	_G.UnitGUID = function() return "Player-1-00000001" end
	_G.UnitName = function() return "Frost" end
	_G.UnitClass = function() return "Mage", "MAGE" end
	_G.UnitFullName = function() return "Frost", "Winterborn" end
	_G.IsInGuild = function() return true end
	_G.GetGuildInfo = function() return "Black Lotus", "Member", 3, nil end
	_G.GetNormalizedRealmName = function() return nil end
	_G.InCombatLockdown = function() return false end
	_G.IsInInstance = function() return false, "none" end
	_G.IsTrialAccount = function() return false end
	_G.IsVeteranTrialAccount = function() return false end
	_G.IsShiftKeyDown = function() return false end
	_G.C_GuildInfo = { GuildRoster = function() end }
	_G.GetNumGuildMembers = function() return 2, 1 end
	_G.GetGuildRosterInfo = function(i)
		if i == 1 then return "Frost Winterborn", "Member", 3, 60, "Mage", "Zone", "", "", true, 0, "MAGE", 0, 0, false, false, 0, "Player-1-00000001" end
		if i == 2 then return "Ana Brightwood", "Member", 3, 60, "Priest", "Zone", "", "", false, 0, "PRIEST", 0, 0, false, false, 0, "Player-1-00000002" end
	end
	_G.GetGuildRosterLastOnline = function(i) return 0, 0, 2, 0 end

	_G.GetProfessions = function() return 1, 2, nil, nil, 3 end
	_G.GetProfessionInfo = function(i)
		if i == 1 then return "Tailoring", 1, 250, 300, 0, 0, 197 end
		if i == 2 then return "Enchanting", 1, 200, 225, 0, 0, 333 end
		if i == 3 then return "Cooking", 1, 120, 150, 0, 0, 185 end
	end
	_G.C_TradeSkillUI = {
		GetAllProfessionTradeSkillLines = function() return { 197, 333, 185, 129 } end,
		GetProfessionInfoBySkillLineID = function(id)
			local map = { [197] = "Tailoring", [333] = "Enchanting", [185] = "Cooking", [129] = "First Aid" }
			local lvl = { [197] = 250, [333] = 200, [185] = 120, [129] = 75 }
			return { professionID = id, professionName = map[id], skillLevel = lvl[id] or 0, maxSkillLevel = 300 }
		end,
		IsTradeSkillReady = function() return true end,
		IsTradeSkillLinked = function() return false end,
		IsTradeSkillGuild = function() return false end,
		IsNPCCrafting = function() return false end,
		GetBaseProfessionInfo = function() return { professionID = 197, professionName = "Tailoring" } end,
		GetAllRecipeIDs = function() return { 3865, 3866, 18560 } end,
		GetRecipeInfo = function(id) return { recipeID = id, learned = id ~= 3866 } end,
		GetRecipeSchematic = function(id)
			local s = { outputItemID = id == 3865 and 4305 or 14342 }
			if id == 3865 then
				-- 2 Linen Cloth + an optional slot that must be left out
				s.reagentSlotSchematics = {
					{ reagents = { { itemID = 2589 } }, quantityRequired = 2, required = true },
					{ reagents = { { itemID = 9999 } }, quantityRequired = 1, required = false },
				}
			end
			return s
		end,
		GetTradeSkillLineForRecipe = function(id) return 185, "Cooking", nil end,
	}
	_G.C_Spell = { GetSpellName = function(id) return "Recipe " .. id end, GetSpellLink = function(id) return "|Hspell:" .. id .. "|h[x]|h" end }
	_G.C_Item = { GetItemInfo = function(id) return "Item " .. id, "|Hitem:" .. id .. "|h[Item]|h" end, RequestLoadItemDataByID = function() end }
	_G.C_ClassColor = { GetClassColor = function() return { WrapTextInColorCode = function(_, s) return s end } end }
	_G.ChatFrame_SendTell = function(name) M.whispered = name end
	_G.ChatEdit_InsertLink = function(link) M.linked = link end

	_G.Enum = { TooltipDataType = { Item = 0 }, SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, GeneralError = 9 } }
	_G.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) M.tooltipPostCall = fn end }
	_G.C_ChatInfo = {
		RegisterAddonMessagePrefix = function() return true end,
		SendAddonMessage = function(prefix, text, chatType) table.insert(M.sent, { prefix = prefix, text = text, chatType = chatType }) return 0 end,
		InChatMessagingLockdown = function() return false end,
	}
end

function M.fire(event, ...)
	for _, f in ipairs(M.events[event] or {}) do
		local fn = f._scripts.OnEvent
		if fn then fn(f, event, ...) end
	end
end

-- Advances fake time and runs due timers (including tickers and OnUpdate for ChatThrottleLib).
function M.advance(seconds, step)
	step = step or 0.5
	local target = M.time + seconds
	while M.time < target do
		M.time = M.time + step
		local due = {}
		for i = #M.timers, 1, -1 do
			local t = M.timers[i]
			if t.at <= M.time then
				table.remove(M.timers, i)
				table.insert(due, t)
			end
		end
		table.sort(due, function(a, b) return a.at < b.at end)
		for _, t in ipairs(due) do
			t.fn()
			if t.every then t.at = M.time + t.every; table.insert(M.timers, t) end
		end
		-- ChatThrottleLib drives its queue from an OnUpdate script
		local ctl = _G.ChatThrottleLib
		if ctl and ctl.Frame and ctl.Frame._scripts.OnUpdate then ctl.Frame._scripts.OnUpdate(ctl.Frame, step) end
	end
end

return M
