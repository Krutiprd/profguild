-- Profguild: Tooltip
-- Adds "Crafted by: A, B (+3)" to item tooltips. Online crafters are green and listed first.

local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local MAX_NAMES = 4
local GREEN, GREY = "|cff40ff40", "|cff9d9d9d"

-- Returns a sorted list of { guid, name, online } for everyone who can craft itemID.
function ns.CraftersForItem(itemID)
	local store = ns.store
	if not store or not itemID then return nil end
	local index = store:Index()
	local recipeIDs = index.items[itemID]
	if not recipeIDs then return nil end
	local seen, list = {}, {}
	local now, staleDays = GetServerTime(), ns.StaleDays()
	for _, recipeID in ipairs(recipeIDs) do
		local entry = index.recipes[recipeID]
		for _, guid in ipairs(entry and entry.guids or {}) do
			if not seen[guid] and not store:IsStale(guid, staleDays, now) then
				seen[guid] = true
				local rec = store:Get(guid)
				list[#list + 1] = { guid = guid, name = ns.DisplayName(guid, rec), online = store:IsOnline(guid) }
			end
		end
	end
	table.sort(list, function(a, b)
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return list
end

-- Short name for display: from the roster when known, otherwise from the record.
function ns.DisplayName(guid, rec)
	local entry = ns.store and ns.store:RosterEntry(guid)
	local name = (entry and entry.name) or (rec and rec.n) or "?"
	if Ambiguate then name = Ambiguate(name, "guild") end
	return name
end

local function addLine(tooltip, itemID)
	if not itemID or Tooltip.suppress then return end
	local list = ns.CraftersForItem(itemID)
	if not list or #list == 0 then return end
	local parts = {}
	for i = 1, math.min(MAX_NAMES, #list) do
		local c = list[i]
		parts[#parts + 1] = (c.online and GREEN or GREY) .. c.name .. "|r"
	end
	local text = table.concat(parts, ", ")
	if #list > MAX_NAMES then text = text .. " " .. ns.T("MORE_CRAFTERS", #list - MAX_NAMES) end
	tooltip:AddLine("|cff33bbff" .. ns.T("CRAFTED_BY") .. ":|r " .. text, 1, 1, 1, true)
end

function Tooltip:Init()
	if self.ready then return end
	self.ready = true
	if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
			if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
			local itemID = data and data.id
			local ok = pcall(addLine, tooltip, itemID)
			if not ok then return end
		end)
	elseif GameTooltip and GameTooltip.HookScript then
		-- Fallback for clients without TooltipDataProcessor
		local function onItem(tooltip)
			local _, link = tooltip:GetItem()
			local itemID = link and tonumber(link:match("item:(%d+)"))
			pcall(addLine, tooltip, itemID)
		end
		GameTooltip:HookScript("OnTooltipSetItem", onItem)
		if ItemRefTooltip then ItemRefTooltip:HookScript("OnTooltipSetItem", onItem) end
	end
end
