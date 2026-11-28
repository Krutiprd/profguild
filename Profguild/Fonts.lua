-- Profguild: Fonts
-- The game's font (Friz Quadrata of the English client) has no Slovak letters such as č, ž, ľ,
-- ť, ň: they are drawn as squares. In Slovak the window uses the bundled Inter font
-- (Media/Fonts, SIL Open Font License), in English the game's own fonts as before.
-- Tooltip lines with such letters get Inter in any language, and their own font back when the
-- tooltip is cleared.

local _, ns = ...

local Fonts = {}
ns.Fonts = Fonts

local DIR = "Interface\\AddOns\\Profguild\\Media\\Fonts\\"
Fonts.REGULAR = DIR .. "Inter-Regular.ttf"
Fonts.BOLD = DIR .. "Inter-SemiBold.ttf"

-- the game's font objects used by Profguild; the gold "Normal" ones are titles and buttons
local BASES = {
	GameFontNormal = Fonts.BOLD,
	GameFontNormalSmall = Fonts.BOLD,
	GameFontNormalLarge = Fonts.BOLD,
	GameFontHighlight = Fonts.REGULAR,
	GameFontHighlightSmall = Fonts.REGULAR,
	GameFontHighlightLarge = Fonts.REGULAR,
	ChatFontNormal = Fonts.REGULAR,
}

-- A letter the game's font lacks: U+0100..U+017F (Latin Extended-A), UTF-8 lead byte C4 or C5.
local function needsFont(text)
	return type(text) == "string" and text:find("[\196\197]") ~= nil
end
Fonts.NeedsFont = needsFont

-- Our copy of a game font object, by the game's name; nil for a font Profguild does not cover.
function Fonts.Get(name)
	Fonts.Create()
	return Fonts.objects and Fonts.objects[name]
end

-- The font object to use in place of the game's `name` (an object or the name itself).
function Fonts.Use(name)
	return Fonts.Get(name) or (type(name) == "string" and _G[name]) or name
end

function Fonts.Create()
	if Fonts.objects or not CreateFont then return end
	Fonts.objects = {}
	for name in pairs(BASES) do
		local base = _G[name]
		if base and base.GetFont then
			local obj = CreateFont("Profguild" .. name)
			obj:CopyFontObject(base)
			Fonts.objects[name] = obj
		end
	end
end

-- Sets our font objects for the current language; the font strings using them follow.
function Fonts.Apply()
	Fonts.Create()
	for name, obj in pairs(Fonts.objects or {}) do
		local base = _G[name]
		if ns.lang == "en" then
			obj:CopyFontObject(base)
		else
			local _, size, flags = base:GetFont()
			obj:SetFont(BASES[name], size or 12, flags or "")
		end
	end
end

-- Tooltips: a line with a Slovak letter gets Inter at its own size until the tooltip is cleared.
local function fixLine(line, changed)
	if not line or changed[line] or not needsFont(line:GetText()) then return end
	local _, size, flags = line:GetFont()
	changed[line] = line:GetFontObject() or false
	line:SetFont(Fonts.REGULAR, size or 12, flags or "")
end

local function fixLast(tooltip, changed, double)
	local name = tooltip:GetName()
	local n = tooltip:NumLines()
	if not name or not n or n < 1 then return end
	fixLine(_G[name .. "TextLeft" .. n], changed)
	if double then fixLine(_G[name .. "TextRight" .. n], changed) end
end

local function restore(changed)
	for line, obj in pairs(changed) do
		if obj then line:SetFontObject(obj) end
		changed[line] = nil
	end
end

function Fonts.HookTooltip(tooltip)
	if not tooltip or not hooksecurefunc or Fonts.hooked[tooltip] then return end
	local changed = {}
	Fonts.hooked[tooltip] = changed
	hooksecurefunc(tooltip, "AddLine", function(self) pcall(fixLast, self, changed) end)
	hooksecurefunc(tooltip, "AddDoubleLine", function(self) pcall(fixLast, self, changed, true) end)
	hooksecurefunc(tooltip, "SetText", function(self) pcall(fixLast, self, changed) end)
	tooltip:HookScript("OnTooltipCleared", function() restore(changed) end)
	tooltip:HookScript("OnHide", function() restore(changed) end)
end
Fonts.hooked = {}

function Fonts.Init()
	Fonts.Apply()
	Fonts.HookTooltip(GameTooltip)
	Fonts.HookTooltip(ItemRefTooltip)
end
