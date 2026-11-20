-- Bug reports: the window, /pg bug, the Lua error hook and the limits.
local H = ...
M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M

local function loadAddon()
	M.install()
	local ns = {}
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			assert(loadfile(H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")))("Profguild", ns)
		end
	end
	return ns
end

H.test("bugs: a report from the window carries the text and what the window showed", function()
	ProfguildDB = nil
	local ns = loadAddon()
	-- an error raised before the saved data exists is kept for later
	H.ok(pcall(M.errorHandler, "Interface/AddOns/Profguild/UI.lua:12: early") == false, "the previous handler still runs")
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(10)
	H.eq(#ProfguildDB.errors, 1, "the early error is remembered")
	Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function(_, id) return ({ [2589] = 150, [4305] = 1000 })[id] end,
		GetVendorPriceByItemID = function() end,
	} } }
	M.fire("TRADE_SKILL_SHOW")
	M.advance(5)
	local UI = ns.UI
	UI:Toggle()
	UI:SetCategory(197)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == 3865 then r._scripts.OnClick(r, "LeftButton") end
	end
	H.eq(UI.selected.recipeID, 3865)

	H.eq(UI.bugButton.text:GetText(), ns.T("BUG_BUTTON"), "button in the footer")
	UI.bugButton._scripts.OnClick(UI.bugButton)
	local bug = UI.bugDialog
	H.ok(bug:IsShown(), "the box opens")
	H.ok(UI.bugButton and bug.saveButton.disabled, "nothing to save yet")
	H.ok(bug.errors:GetText():find("1", 1, true), "it says how many errors are remembered")
	-- the window changes after the box opened: the report keeps what it showed then
	UI.selected = nil
	bug.edit:SetText("  Profit looks wrong  ")
	H.ok(not bug.saveButton.disabled, "text: can be saved")
	bug.saveButton._scripts.OnClick(bug.saveButton)
	H.ok(not bug:IsShown(), "the box closes")
	local r = ProfguildDB.bugs[1]
	H.eq(r.n, 1); H.eq(r.text, "Profit looks wrong", "trimmed")
	H.eq(r.v, ns.version); H.eq(r.who, "Frost"); H.eq(r.guild, "Black Lotus")
	H.ok(type(r.t) == "number" and r.t > 0, "time of the report")
	local ctx = table.concat(r.ctx, "\n")
	H.ok(ctx:find("prices: Auctionator, auction house closed", 1, true), ctx)
	H.ok(ctx:find("view recipes, profession Tailoring (197)", 1, true), ctx)
	H.ok(ctx:find("selected: recipe", 1, true) and ctx:find("recipe 3865, item 4305", 1, true), ctx)
	H.ok(ctx:find("reagent: 2x Item 2589 | " .. ns.Bugs.Plain(ns.Prices.Format(300)), 1, true), ctx)
	H.ok(ctx:find("Profit when sold " .. ns.Bugs.Plain(ns.Prices.Format(650)), 1, true), "profit of the details: " .. ctx)
	H.ok(not ctx:find("|c", 1, true) and not ctx:find("|r", 1, true), "no colour codes")
	H.eq(#r.errors, 1, "the remembered error is copied")
	H.ok(r.errors[1].msg:find("early", 1, true))
	H.ok(#r.log > 0 and #r.log <= ns.Bugs.REPORT_LOG, "last lines of the log")
	H.ok(M.chat[#M.chat]:find(ns.T("BUG_SAVED", 1), 1, true), "chat confirms the number")

	H.eq(bug.edit:GetText(), "", "a saved text is gone from the box")

	-- an empty text saves nothing
	UI:OpenBugReport()
	bug.edit:SetText("   ")
	H.ok(bug.saveButton.disabled)
	bug.saveButton._scripts.OnClick(bug.saveButton)
	H.eq(#ProfguildDB.bugs, 1, "nothing saved")
	-- Esc only leaves the text; closing the window keeps the draft for the next time
	bug.edit:SetText("half written")
	bug.edit._scripts.OnEscapePressed(bug.edit)
	H.ok(bug:IsShown(), "Esc does not close the box")
	UI.frame._scripts.OnHide(UI.frame)
	H.ok(not bug:IsShown(), "closing the window closes the box")
	H.eq(UI.bugContext, nil)
	UI:OpenBugReport()
	H.eq(bug.edit:GetText(), "half written", "the draft is still there")
	H.ok(not bug.saveButton.disabled)
	-- Cancel throws it away
	bug.cancelButton._scripts.OnClick(bug.cancelButton)
	H.ok(not bug:IsShown())
	UI:OpenBugReport()
	H.eq(bug.edit:GetText(), "", "Cancel forgets the text")
	-- the texts follow a change of language while the box is open
	SlashCmdList.PROFGUILD("lang sk")
	H.eq(bug.title:GetText(), ns.T("BUG_TITLE"))
	H.eq(bug.cancelButton.text:GetText(), "Zrušiť")
	SlashCmdList.PROFGUILD("lang en")
	UI:CloseBugReport(true)

	-- an error while drawing is caught by the window and still remembered, with its stack
	local realDraw = UI.Draw
	local realStack = debugstack
	debugstack = function() return "Interface/AddOns/Profguild/UI.lua:99: in function Draw" end
	UI.Draw = function() error("Interface/AddOns/Profguild/UI.lua:99: draw broke", 0) end
	UI:Refresh()
	UI.Draw, debugstack = realDraw, realStack
	local last = ProfguildDB.errors[#ProfguildDB.errors]
	H.ok(last.msg:find("draw broke", 1, true), "a caught error is remembered")
	H.ok(last.stack and last.stack:find("in function Draw", 1, true), "with the stack where it was raised")
	H.ok(bug.errors and ns.Bugs.ErrorCount() == 2, "every raise counts: " .. ns.Bugs.ErrorCount())
	-- a game function that Profguild called fails: the message names the game's file
	H.ok(not ns.Bugs.Call(function() error("Interface/FrameXML/Util.lua:5: bad argument", 0) end))
	H.ok(ProfguildDB.errors[#ProfguildDB.errors].msg:find("FrameXML", 1, true), "caught around our code: kept")
end)

H.test("bugs: /pg bug, the error hook and the limits", function()
	ProfguildDB = nil
	local ns = loadAddon()
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(10)
	local slash = SlashCmdList.PROFGUILD
	-- before the window was ever opened
	slash("bug Window never opened")
	local r = ProfguildDB.bugs[1]
	H.eq(r.text, "Window never opened")
	H.ok(table.concat(r.ctx, "\n"):find("window: not opened", 1, true))
	-- /pg bug alone opens the box
	slash("bug")
	H.ok(ns.UI.bugDialog:IsShown(), "the box opens from the command")
	ns.UI:CloseBugReport()

	-- only Profguild errors are kept; the same error counts up; the chain goes on
	local before = M.errorHandler
	H.ok(ns.Bugs.hooked, "hook installed at load")
	H.ok(not pcall(M.errorHandler, "Interface/AddOns/OtherAddon/x.lua:1: theirs"))
	H.eq(#ProfguildDB.errors, 0, "another addon's error is not ours")
	for _ = 1, 3 do pcall(M.errorHandler, "Interface\\AddOns\\Profguild\\Prices.lua:5: boom") end
	H.eq(#ProfguildDB.errors, 1); H.eq(ProfguildDB.errors[1].count, 3, "counted, not repeated")
	for i = 1, ns.Bugs.MAX_ERRORS + 5 do pcall(M.errorHandler, "Interface/AddOns/Profguild/UI.lua:" .. i .. ": e") end
	H.eq(#ProfguildDB.errors, ns.Bugs.MAX_ERRORS, "oldest errors dropped")
	H.eq(before, M.errorHandler, "nothing replaced the handler")

	slash("bug list")
	H.ok(table.concat(M.chat, "\n"):find("Window never opened", 1, true), "list prints the newest")

	-- limits: long text cut, oldest reports dropped
	slash("bug " .. string.rep("x", ns.Bugs.MAX_TEXT + 50))
	H.eq(#ProfguildDB.bugs[2].text, ns.Bugs.MAX_TEXT)
	for i = 1, ns.Bugs.MAX_REPORTS do slash("bug report " .. i) end
	H.eq(#ProfguildDB.bugs, ns.Bugs.MAX_REPORTS)
	H.eq(ProfguildDB.bugs[#ProfguildDB.bugs].n, ns.Bugs.MAX_REPORTS + 2, "numbers keep counting")
	H.eq(ns.Bugs.Plain("|cff70d08c+6s|r |Hitem:1|h[Linen]|h |TInterface\\x:0|t"), "+6s [Linen] ")

	-- letters, not bytes: a Slovak text is cut at a whole character
	local sk = string.rep("\195\161", ns.Bugs.MAX_TEXT + 5) -- "á" is 2 bytes
	slash("bug " .. sk)
	local cut = ProfguildDB.bugs[#ProfguildDB.bugs].text
	H.eq(ns.Bugs.Length(cut), ns.Bugs.MAX_TEXT); H.eq(#cut, 2 * ns.Bugs.MAX_TEXT, "no half character")
	H.eq(ns.Bugs.Cut("a\195\161b", 2), "a\195\161")
	H.eq(ns.Bugs.Length("\195\161\195\169"), 2)
	-- broken text: Cut counts like Length and never runs past the end
	H.eq(ns.Bugs.Cut("\195a\161b", 2), "\195a\161")
	H.eq(ns.Bugs.Length(ns.Bugs.Cut("\161\161\161x", 1)), 1)
	H.eq(ns.Bugs.Cut("\240\159", 5), "\240\159")
	H.eq(ns.Bugs.Length(ns.Bugs.Cut("\128abc", 2)), 2, "a stray continuation byte is not a letter")

	slash("bug clear")
	H.eq(#ProfguildDB.bugs, ns.Bugs.MAX_REPORTS, "clear asks for a confirmation first")
	H.ok(M.chat[#M.chat]:find("clear confirm", 1, true))
	slash("bug clear   confirm")
	H.eq(#ProfguildDB.bugs, 0); H.eq(#ProfguildDB.errors, 0)
	-- the numbers go on after a clear, so an old number never means a new report
	slash("bug after clear")
	H.eq(ProfguildDB.bugs[1].n, ns.Bugs.MAX_REPORTS + 4)
end)

H.test("bugs: with BugGrabber the errors come from its callback", function()
	ProfguildDB = nil
	local callback
	BugGrabber = { RegisterCallback = function(_, event, fn) if event == "BugGrabber_BugGrabbed" then callback = fn end end }
	local ns = loadAddon()
	BugGrabber = nil
	H.eq(ns.Bugs.hooked, "BugGrabber")
	M.fire("ADDON_LOADED", "Profguild")
	H.ok(callback, "registered")
	callback("BugGrabber_BugGrabbed", { message = "Interface/AddOns/Profguild/Sync.lua:3: oops", stack = "s" })
	callback("BugGrabber_BugGrabbed", { message = "Interface/AddOns/Other/a.lua:1: theirs" })
	H.eq(#ProfguildDB.errors, 1); H.eq(ProfguildDB.errors[1].stack, "s")
	callback("BugGrabber_BugGrabbed", { message = "Profguild/UI.lua:7: a shortened path" })
	H.eq(#ProfguildDB.errors, 2, "BugGrabber's short path is ours too")
	H.ok(not ns.Bugs.IsOurs("Interface/AddOns/NotProfguild/x.lua:1: e"))
end)

H.test("bugs: a handler that cannot be replaced is not claimed", function()
	ProfguildDB = nil
	M.install()
	local realSet = seterrorhandler
	seterrorhandler = function() end -- what BugGrabber leaves behind
	local ns = {}
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			assert(loadfile(H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")))("Profguild", ns)
		end
	end
	seterrorhandler = realSet
	H.eq(ns.Bugs.hooked, nil, "not hooked")
	-- BugGrabber offers its callback later: the hook is tried again at login
	local callback
	BugGrabber = { RegisterCallback = function(_, _, fn) callback = fn end }
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	BugGrabber = nil
	H.eq(ns.Bugs.hooked, "BugGrabber")
	callback("BugGrabber_BugGrabbed", { message = "Interface/AddOns/Profguild/Core.lua:1: late" })
	H.eq(#ProfguildDB.errors, 1)
end)
