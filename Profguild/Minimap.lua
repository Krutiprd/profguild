-- Profguild: Minimap
-- A round button on the minimap edge, the same look other addons use. Click opens the window,
-- dragging moves the button around the minimap, /pg minimap hides or shows it.

local _, ns = ...

local MinimapButton = {}
ns.Minimap = MinimapButton

local ICON = "Interface\\Icons\\Trade_LeatherWorking"
local DEFAULT_ANGLE = 215 -- degrees, counter-clockwise from the right: lower left

-- Offset of the button centre from the minimap centre for an angle and a minimap radius.
function MinimapButton.Offset(angle, radius)
	local a = math.rad(angle)
	return math.cos(a) * (radius + 5), math.sin(a) * (radius + 5)
end

function MinimapButton:Settings()
	local s = ns.db.settings
	if type(s.minimap) ~= "table" then s.minimap = {} end
	if type(s.minimap.angle) ~= "number" then s.minimap.angle = DEFAULT_ANGLE end
	s.minimap.hide = s.minimap.hide and true or false
	return s.minimap
end

function MinimapButton:Place()
	local x, y = self.Offset(self:Settings().angle, (Minimap:GetWidth() or 140) / 2)
	self.button:ClearAllPoints()
	self.button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Follows the cursor while the button is dragged.
local function followCursor()
	local mx, my = Minimap:GetCenter()
	local px, py = GetCursorPosition()
	if not mx or not px then return end
	local scale = Minimap:GetEffectiveScale() or 1
	MinimapButton:Settings().angle = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
	MinimapButton:Place()
end

local function showTooltip(button)
	GameTooltip:SetOwner(button, "ANCHOR_LEFT")
	GameTooltip:AddLine("Profguild")
	GameTooltip:AddLine(ns.T("MINIMAP_CLICK"), 1, 1, 1)
	GameTooltip:AddLine(ns.T("MINIMAP_DRAG"), 1, 1, 1)
	GameTooltip:Show()
end

function MinimapButton:Create()
	if self.button or not Minimap then return end
	local b = CreateFrame("Button", "ProfguildMinimapButton", Minimap)
	self.button = b
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = b:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(24, 24)
	background:SetPoint("CENTER")

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	icon:SetSize(18, 18)
	icon:SetPoint("CENTER")
	b.icon = icon

	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(50, 50)
	border:SetPoint("TOPLEFT")

	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetScript("OnClick", function()
		if ns.UI then ns.UI:Toggle() end
	end)
	b:SetScript("OnDragStart", function(btn)
		GameTooltip:Hide()
		btn:SetScript("OnUpdate", followCursor)
	end)
	b:SetScript("OnDragStop", function(btn)
		btn:SetScript("OnUpdate", nil)
	end)
	b:SetScript("OnEnter", showTooltip)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function MinimapButton:Init()
	self:Create()
	if not self.button then return end
	self:Place()
	if self:Settings().hide then self.button:Hide() else self.button:Show() end
end

-- Hides the button when it is shown and the other way round. Returns true when it is now shown.
function MinimapButton:Toggle()
	local settings = self:Settings()
	settings.hide = not settings.hide
	self:Init()
	return not settings.hide
end
