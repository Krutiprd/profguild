local H = ...

-- A font object or font string: keeps its file, size, flags and the object it copies.
local function font(file, size, flags)
	local f = { file = file, size = size, flags = flags }
	function f:GetFont() return self.file, self.size, self.flags end
	function f:SetFont(file2, size2, flags2) self.file, self.size, self.flags, self.object = file2, size2, flags2, nil end
	function f:CopyFontObject(o) self.file, self.size, self.flags = o:GetFont() end
	function f:SetFontObject(o) self.object = o; self.file, self.size, self.flags = o:GetFont() end
	function f:GetFontObject() return self.object end
	function f:GetText() return self.text end
	return f
end

-- A tooltip that adds lines into Tip1TextLeft1.. and runs its hooks like the game.
local function tooltip(name, base)
	local t = { lines = 0, hooks = {}, scripts = {} }
	function t:GetName() return name end
	function t:NumLines() return self.lines end
	local function line(side, n)
		local key = name .. "Text" .. side .. n
		if not _G[key] then
			_G[key] = font(base:GetFont())
			_G[key].object = base
		end
		return _G[key]
	end
	function t:AddLine(text) self.lines = self.lines + 1; line("Left", self.lines).text = text end
	function t:AddDoubleLine(l, r) self:AddLine(l); line("Right", self.lines).text = r end
	function t:SetText(text) self.lines = 1; line("Left", 1).text = text end
	function t:HookScript(event, fn) self.scripts[event] = fn end
	function t:ClearLines() self.lines = 0; if self.scripts.OnTooltipCleared then self.scripts.OnTooltipCleared(self) end end
	return t
end

local function install()
	_G.GameFontHighlight = font("Fonts\\FRIZQT__.TTF", 12, "")
	_G.GameFontNormalLarge = font("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
	_G.GameTooltipText = font("Fonts\\FRIZQT__.TTF", 12, "")
	_G.CreateFont = function(name) local f = font(); _G[name] = f; return f end
	_G.hooksecurefunc = function(t, method, fn)
		local old = t[method]
		t[method] = function(...) old(...); fn(...) end
	end
	_G.GameTooltip = tooltip("GameTooltip", _G.GameTooltipText)
	_G.ItemRefTooltip = nil
end

H.test("fonts: Slovak switches our font objects to Inter, English back to the game's", function()
	install()
	local ns = H.newNamespace({ "Locale.lua", "Fonts.lua" })
	ns.Fonts.Init()
	local obj = ns.Fonts.Use("GameFontHighlight")
	H.ok(obj ~= GameFontHighlight, "our own copy")
	H.eq(obj:GetFont(), "Fonts\\FRIZQT__.TTF", "English: the game's font")
	H.ok(ns.SetLanguage("sk"))
	local file, size = obj:GetFont()
	H.eq(file, ns.Fonts.REGULAR, "Slovak: Inter")
	H.eq(size, 12, "same size")
	local _, size2, flags2 = ns.Fonts.Use("GameFontNormalLarge"):GetFont()
	H.eq(ns.Fonts.Use("GameFontNormalLarge"):GetFont(), ns.Fonts.BOLD, "titles bold")
	H.eq(size2, 16); H.eq(flags2, "OUTLINE")
	H.eq(ns.Fonts.Use("GameFontDisableSmall"), "GameFontDisableSmall", "a font not covered stays the game's")
	ns.SetLanguage("en")
	H.eq(obj:GetFont(), "Fonts\\FRIZQT__.TTF", "English again")
end)

H.test("fonts: a tooltip line with č/ž/ľ gets Inter until the tooltip is cleared", function()
	install()
	local ns = H.newNamespace({ "Locale.lua", "Fonts.lua" })
	ns.Fonts.Init()
	GameTooltip:AddLine("Crafted by: Anna")
	GameTooltip:AddLine("Vyrobí: Žofia, Ľubo")
	GameTooltip:AddDoubleLine("Cena", "1 zlatý 5 strieborných")
	GameTooltip:AddDoubleLine("Kto", "Čaba")
	H.eq(GameTooltipTextLeft1:GetFont(), "Fonts\\FRIZQT__.TTF", "plain line keeps the game's font")
	H.eq(GameTooltipTextLeft2:GetFont(), ns.Fonts.REGULAR, "Slovak letters: Inter")
	H.eq(select(2, GameTooltipTextLeft2:GetFont()), 12, "at the line's size")
	H.eq(GameTooltipTextRight3:GetFont(), "Fonts\\FRIZQT__.TTF", "á and ý are in the game's font")
	H.eq(GameTooltipTextRight4:GetFont(), ns.Fonts.REGULAR, "right side of a double line")
	GameTooltip:ClearLines()
	H.eq(GameTooltipTextLeft2:GetFont(), "Fonts\\FRIZQT__.TTF", "restored on clear")
	H.eq(GameTooltipTextLeft2:GetFontObject(), GameTooltipText, "its own font object back")
	GameTooltip:SetText("Profguild")
	H.eq(GameTooltipTextLeft1:GetFont(), "Fonts\\FRIZQT__.TTF", "a reused line is not changed")
end)
