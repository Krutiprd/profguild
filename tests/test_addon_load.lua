-- Loads the whole addon in a fake WoW environment (TOC order) and drives its main code paths.
local H = ...
M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M

local function loadToc(ns)
	local toc = assert(io.open(H.addon .. "/Profguild.toc")):read("*a")
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			local path = H.addon .. "/" .. line:gsub("\\", "/"):gsub("%s+$", "")
			local chunk = assert(loadfile(path))
			chunk("Profguild", ns)
		end
	end
end

H.test("addon: loads in TOC order and survives login, scan, sync, UI and slash commands", function()
	M.install()
	local ns = {}
	loadToc(ns)
	H.ok(SlashCmdList.PROFGUILD, "slash registered")

	M.fire("ADDON_LOADED", "Profguild")
	H.ok(ProfguildDB and ProfguildDB.account, "db initialized")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	H.ok(ns.store, "guild store created")
	local chatBeforeDump = #M.chat
	M.advance(40)
	H.ok(ProfguildDB.debug and #ProfguildDB.debug.lines > 5, "debug saved automatically after login")
	H.eq(#M.chat, chatBeforeDump, "silently")
	H.ok(ProfguildDB.log and ProfguildDB.log[1]:find("login, version", 1, true), "log kept in SavedVariables")
	M.fire("GUILD_ROSTER_UPDATE")
	M.advance(2)

	-- own record published with professions from GetProfessions + the skill-line fallback (First Aid)
	local own = ProfguildDB.own["Player-1-00000001"]
	H.ok(own and own.v >= 1, "own record built")
	H.ok(own.profs[197] and own.profs[333] and own.profs[185] and own.profs[129], "Tailoring, Enchanting, Cooking, First Aid")

	-- opening the profession window scans recipes
	M.fire("TRADE_SKILL_SHOW")
	M.advance(5)
	H.eq(own.recipes[197][3865], 4305, "scanned recipe with output item")
	H.eq(own.recipes[197][3866], nil, "unlearned recipe skipped")
	H.ok(own.scanned[197], "marked scanned")
	H.eq(ProfguildDB.reagents[3865][2589], 2, "reagents read from the profession window")
	H.eq(ProfguildDB.reagents[3865][9999], nil, "optional reagent left out")

	-- a learned recipe arrives through the event
	M.fire("NEW_RECIPE_LEARNED", 7827)
	M.advance(5)
	H.ok(own.recipes[185] and own.recipes[185][7827], "learned recipe stored under Cooking")

	-- the hello after login actually goes out on the GUILD channel through AceComm
	M.advance(30)
	H.ok(#M.sent > 0, "addon messages sent")
	for _, m in ipairs(M.sent) do
		H.eq(m.prefix, "Profguild"); H.eq(m.chatType, "GUILD")
		H.ok(#m.text <= 255, "message part fits 255 bytes")
	end

	-- a guildmate's record arrives
	local text = ns.Comm.Encode({ t = "D", pv = 1, s = "Player-1-00000002", r = {
		g = "Player-1-00000002", v = 4, n = "Ana Brightwood", c = "PRIEST", a = "acc2", t = 1794615000,
		p = { [171] = { s = 280, m = 300, k = true, r = { [17187] = 12360, [11479] = 3577 } } } } })
	ns.Comm:OnCommReceived("Profguild", text, "GUILD", "Ana Brightwood")
	H.eq(ns.store:Get("Player-1-00000002").v, 4, "remote record stored")
	H.eq(ns.guildDB.names["Player-1-00000002"], "Ana Brightwood", "sender name remembered")
	ns.Comm:OnCommReceived("Profguild", "garbage", "GUILD", "X") -- must not error

	-- tooltip
	M.tooltipLines = {}
	M.tooltipPostCall(GameTooltip, { id = 12360 })
	H.ok(M.tooltipLines[1] and M.tooltipLines[1]:find("Ana Brightwood"), "tooltip shows the crafter")

	-- UI: three panels (professions, list, details), search, members view, whisper, link
	local UI = ns.UI
	local function visible(list)
		local out = {}
		for _, r in ipairs(list) do if r:IsShown() then out[#out + 1] = rawget(r, "data") end end
		return out
	end
	local function profButton(skillLine)
		for _, b in ipairs(UI.profButtons) do
			if b:IsShown() and rawget(b, "skillLine") == skillLine then return b end
		end
	end

	SlashCmdList.PROFGUILD("")
	H.ok(UI.frame:IsShown(), "window shown")
	local rows = visible(UI.rows)
	H.ok(#rows == 5, "all 5 recipes listed (" .. #rows .. ")")
	H.eq(rows[1].kind, "recipe")
	H.ok((rawget(UI.rows[1], "_width") or 0) > 0, "rows have a fixed width")
	for i = 2, #rows do H.ok(rows[i - 1].name <= rows[i].name, "sorted by name") end

	-- the close button hides the window
	UI.closeButton._scripts.OnClick(UI.closeButton, "LeftButton")
	H.ok(not UI.frame:IsShown(), "close button hides the window")
	SlashCmdList.PROFGUILD("")
	H.ok(UI.frame:IsShown(), "window shown again")

	-- search by recipe and by crafter
	UI.search:SetText("recipe 17187")
	M.advance(1)
	rows = visible(UI.rows)
	H.eq(#rows, 1, "only one result")
	H.eq(rows[1].recipeID, 17187, "search finds the recipe")
	UI.search:SetText("brightwood")
	M.advance(1)
	H.eq(#visible(UI.rows), 2, "search by crafter name finds both of Ana's recipes")
	UI.search:SetText("")
	M.advance(1)

	-- professions sidebar: All + every profession with recipes, with counts
	local cats = {}
	for _, b in ipairs(UI.profButtons) do if b:IsShown() then cats[#cats + 1] = rawget(b, "skillLine") or "all" end end
	H.eq(cats[1], "all", "All comes first")
	H.eq(#cats, 4, "All + Alchemy, Cooking, Tailoring")
	profButton(197)._scripts.OnClick(profButton(197))
	H.eq(ProfguildDB.settings.category, 197, "chosen profession saved")
	rows = visible(UI.rows)
	H.eq(#rows, 2, "Tailoring: 2 recipes")
	for _, d in ipairs(rows) do H.eq(d.skillLine, 197) end
	UI:SetCategory(999) -- a profession nobody has any more
	H.eq(#visible(UI.rows), 5, "unknown profession falls back to All")
	UI:SetCategory(171)

	-- details: clicking a recipe lists its crafters, clicking a crafter whispers
	H.ok(UI.detail.empty:IsShown(), "details ask to choose a recipe")
	local first = UI.rows[1]
	first._scripts.OnEnter(first)
	first._scripts.OnLeave(first)
	first._scripts.OnClick(first, "LeftButton")
	H.eq(UI.selected and UI.selected.recipeID, rawget(first, "data").recipeID, "recipe selected")
	H.ok(not UI.detail.empty:IsShown(), "details shown")
	local crafters = visible(UI.detail.rows)
	H.eq(#crafters, 1, "one crafter")
	H.eq(crafters[1].guid, "Player-1-00000002", "Ana crafts it")
	UI.detail.rows[1]._scripts.OnEnter(UI.detail.rows[1])
	UI.detail.rows[1]._scripts.OnClick(UI.detail.rows[1], "LeftButton")
	H.eq(M.whispered, "Ana Brightwood", "click on a crafter whispers")
	M.whispered = nil
	-- shift-click links the item
	local oldShift = IsShiftKeyDown
	IsShiftKeyDown = function() return true end
	first._scripts.OnClick(first, "LeftButton")
	IsShiftKeyDown = oldShift
	H.ok(M.linked, "shift-click links the item")
	UI.detail.action._scripts.OnClick(UI.detail.action, "LeftButton") -- link button
	-- mouse wheel on the list does not break anything
	UI.list._scripts.OnMouseWheel(UI.list, -1)
	UI.list._scripts.OnMouseWheel(UI.list, 1)

	-- reagents of a guildmate's recipe are asked for, then shown with prices
	local selectedID = UI.selected.recipeID
	H.ok(UI.detail.reagentNote:IsShown(), "note while the reagents are unknown")
	local before = #M.sent
	M.advance(1)
	local query
	for i = before + 1, #M.sent do
		local msg = ns.Comm.Decode(M.sent[i].text)
		if msg and msg.t == "Q" then query = msg end
	end
	H.ok(query and query.q[1] == selectedID, "guild asked for the reagents")
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "C", pv = 1, s = "Player-1-00000002",
		c = { [selectedID] = { [3371] = 1, [3820] = 2 } } }), "GUILD", "Ana Brightwood")
	H.eq(ns.reagents:Get(selectedID)[3820], 2, "answer stored")
	M.advance(2)
	H.eq(#visible(UI.detail.reagentRows), 2, "two reagents listed")
	H.ok(not UI.detail.reagentNote:IsShown(), "note hidden")

	-- prices from Auctionator: cost, profit, shopping list
	local created
	Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function(_, id) return ({ [2589] = 150, [4305] = 1000 })[id] end,
		GetVendorPriceByItemID = function() end,
		ConvertToSearchString = function(_, term) return term.searchString .. "#" .. term.quantity end,
		CreateShoppingList = function(_, name, terms) created = { name = name, terms = terms } end,
	} } }
	ProfguildDB.reagents[3865] = nil -- the game describes it, so no question is needed
	local sentBefore = #M.sent
	UI:SetCategory(197)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == 3865 then r._scripts.OnClick(r, "LeftButton") end
	end
	H.eq(UI.selected.recipeID, 3865)
	H.eq(#visible(UI.detail.reagentRows), 1)
	H.eq(ns.reagents:Get(3865)[2589], 2, "reagents read from the game")
	M.advance(1)
	for i = sentBefore + 1, #M.sent do
		local msg = ns.Comm.Decode(M.sent[i].text)
		H.ok(not (msg and msg.t == "Q"), "no question to the guild")
	end
	H.eq(UI.detail.costValue:GetText(), ns.Prices.Format(300), "2 x 150 copper")
	H.eq(UI.detail.profitValue:GetText(), ns.Prices.Format(700), "sells for 1000")
	H.ok(UI.detail.value:GetText():find(ns.Prices.Format(1000), 1, true), "item value shown")
	H.ok(not UI.detail.shopButton.disabled, "shopping list available")
	UI.detail.shopButton._scripts.OnClick(UI.detail.shopButton)
	H.ok(created and created.name == "Profguild: Recipe 3865", "shopping list created")
	H.eq(created.terms[1], "Item 2589#2", "exact reagent with quantity")
	Auctionator = nil
	UI:Refresh()
	H.ok(UI.detail.shopButton.disabled, "no shopping list without Auctionator")
	H.ok(UI.detail.costValue:GetText():find(ns.T("NO_PRICES"), 1, true), "says how to get prices")

	-- online only: Ana is offline, so her recipes disappear
	UI:SetCategory(nil)
	UI.onlineButton._scripts.OnClick(UI.onlineButton)
	H.ok(ProfguildDB.settings.onlineOnly, "online only saved")
	H.eq(#visible(UI.rows), 3, "only the online crafter's recipes")
	UI.onlineButton._scripts.OnClick(UI.onlineButton)

	-- members view: a member's professions, a click shows their recipes of that profession
	UI.membersTab._scripts.OnClick(UI.membersTab)
	H.eq(UI.view, "members")
	local members = visible(UI.rows)
	H.eq(#members, 2, "two members")
	H.eq(members[1].kind, "member")
	H.eq(members[1].guid, "Player-1-00000001", "online member first")
	profButton(171)._scripts.OnClick(profButton(171))
	members = visible(UI.rows)
	H.eq(#members, 1, "only the alchemist")
	H.eq(members[1].guid, "Player-1-00000002")
	UI.rows[1]._scripts.OnEnter(UI.rows[1])
	UI.rows[1]._scripts.OnClick(UI.rows[1], "LeftButton")
	local profs = visible(UI.detail.rows)
	H.eq(#profs, 1, "Ana has one profession")
	H.eq(profs[1].skillLine, 171)
	UI.detail.action._scripts.OnClick(UI.detail.action, "LeftButton") -- whisper button
	H.eq(M.whispered, "Ana Brightwood", "whisper button in member details")
	M.whispered = nil
	UI.detail.rows[1]._scripts.OnClick(UI.detail.rows[1], "LeftButton")
	H.eq(UI.view, "recipes", "back to recipes")
	H.eq(UI.memberFilter, "Player-1-00000002", "filtered to that member")
	H.eq(UI.category, 171, "and that profession")
	H.eq(#visible(UI.rows), 2, "Ana's two alchemy recipes")
	H.ok(UI.filterChip:IsShown(), "member filter chip shown")
	UI.filterChip._scripts.OnClick(UI.filterChip)
	H.eq(UI.memberFilter, nil, "chip clears the member filter")
	UI.recipesTab._scripts.OnClick(UI.recipesTab)
	UI:SetCategory(nil)

	-- sync button and language switch redraw without errors
	UI.syncButton._scripts.OnClick(UI.syncButton)
	SlashCmdList.PROFGUILD("lang sk")
	SlashCmdList.PROFGUILD("lang en")
	H.eq(ns.lastError, nil, "no UI errors: " .. tostring(ns.lastError))

	-- minimap button: click toggles the window, drag moves it around the minimap, /pg minimap hides it
	local mm = ns.Minimap.button
	H.ok(mm and mm:IsShown(), "minimap button shown after login")
	H.eq(ProfguildMinimapButton, mm, "named so that button collectors find it")
	mm._scripts.OnClick(mm, "LeftButton")
	H.ok(not ns.UI.frame:IsShown(), "click closes the open window")
	mm._scripts.OnClick(mm, "LeftButton")
	H.ok(ns.UI.frame:IsShown(), "click opens it again")
	mm._scripts.OnEnter(mm)
	mm._scripts.OnLeave(mm)
	M.cursorX, M.cursorY = 500, 900 -- straight above the minimap centre (500, 400)
	mm._scripts.OnDragStart(mm)
	mm._scripts.OnUpdate(mm, 0.1)
	mm._scripts.OnDragStop(mm)
	H.eq(mm._scripts.OnUpdate, nil, "drag stops following the cursor")
	H.eq(math.floor(ProfguildDB.settings.minimap.angle + 0.5), 90, "dragged angle saved")
	local x, y = ns.Minimap.Offset(90, 70)
	H.ok(math.abs(x) < 0.001 and math.abs(y - 75) < 0.001, "button sits just outside the minimap edge")
	SlashCmdList.PROFGUILD("minimap")
	H.ok(not mm:IsShown() and ProfguildDB.settings.minimap.hide, "/pg minimap hides the button")
	SlashCmdList.PROFGUILD("minimap")
	H.ok(mm:IsShown() and not ProfguildDB.settings.minimap.hide, "and shows it again")

	for _, cmd in ipairs({ "status", "debug", "sync", "lang sk", "status", "lang en", "reset", "reset confirm", "help" }) do
		SlashCmdList.PROFGUILD(cmd)
	end
	H.ok(ProfguildDB.debug and #ProfguildDB.debug.lines > 5, "debug dump saved")

	-- instance: nothing goes out, then it is flushed
	IsInInstance = function() return true, "party" end
	local before = #M.sent
	ns.sync.lastHello = -1e9
	ns.sync:Hello(true)
	M.advance(5)
	H.eq(#M.sent, before, "nothing sent in an instance")
	H.ok(ns.sync:OutboxSize() > 0, "queued")
	IsInInstance = function() return false, "none" end
	M.fire("PLAYER_ENTERING_WORLD")
	M.advance(10)
	H.ok(#M.sent > before, "sent after leaving")

	-- dropping a profession removes it after the confirming snapshot
	GetProfessions = function() return 1, nil, nil, nil, 3 end
	C_TradeSkillUI.GetAllProfessionTradeSkillLines = function() return { 197, 185 } end
	M.fire("SKILL_LINES_CHANGED")
	M.advance(120)
	H.eq(own.profs[333], nil, "Enchanting removed")
	H.eq(ns.store:Get("Player-1-00000001").p[333], nil, "and gone from the published record")

	-- a profession window that reports a tier skill line is mapped by name
	C_TradeSkillUI.GetBaseProfessionInfo = function() return { professionID = 2540, professionName = "Tailoring" } end
	local oldInfo = C_TradeSkillUI.GetProfessionInfoBySkillLineID
	C_TradeSkillUI.GetProfessionInfoBySkillLineID = function(id)
		if id == 2540 then return { professionID = 2540, professionName = "Tailoring", skillLevel = 0 } end
		return oldInfo(id)
	end
	C_TradeSkillUI.GetAllRecipeIDs = function() return { 3865, 3866, 18560, 8000 } end
	M.fire("TRADE_SKILL_SHOW")
	M.advance(10)
	H.ok(own.recipes[197][8000], "recipe stored under Tailoring (197), not 2540")
	H.eq(own.recipes[2540], nil)

	-- debounce: steady skill-ups cannot postpone the update, a learned recipe is not held back
	local realRefresh, refreshes = ns.RefreshOwn, 0
	ns.RefreshOwn = function(...) refreshes = refreshes + 1 return realRefresh(...) end
	M.advance(120)
	refreshes = 0
	for _ = 1, 12 do
		M.fire("SKILL_LINES_CHANGED")
		M.advance(10)
	end
	H.ok(refreshes >= 1, "skill-ups every 10 s still refresh within 120 s (" .. refreshes .. ")")
	M.advance(120)
	refreshes = 0
	M.fire("SKILL_LINES_CHANGED")
	M.advance(1)
	ns.ScheduleRefresh() -- learned recipe / scan: short delay
	M.advance(5)
	H.eq(refreshes, 1, "short delay wins over the pending 60 s one")
	M.advance(70)
	H.eq(refreshes, 1, "and the merged refresh is not run twice")
	ns.RefreshOwn = realRefresh

	-- whisper and link fall back to ChatFrameUtil, then to a chat message
	local oldTell, oldOpen, oldInsert = ChatFrame_SendTell, ChatFrame_OpenChat, ChatEdit_InsertLink
	ChatFrame_SendTell, ChatFrame_OpenChat = nil, nil
	ChatFrameUtil = { SendTell = function(name) M.utilTell = name end, OpenChat = function(text) M.utilOpen = text end }
	ns.UI.OpenWhisper("Ana Brightwood")
	H.eq(M.utilTell, "Ana Brightwood", "ChatFrameUtil.SendTell used")
	ChatFrameUtil.SendTell = function() error("protected") end
	ns.UI.OpenWhisper("Ana Brightwood")
	H.eq(M.utilOpen, "/w Ana Brightwood ", "falls back to opening chat with /w")
	ChatEdit_InsertLink = function() return false end -- no edit box open
	ns.UI.InsertLink(17187, 12360)
	H.ok(M.utilOpen:find("item:12360", 1, true), "link opens a chat box when none is open")
	ChatFrameUtil = nil
	local chatBefore = #M.chat
	ns.UI.OpenWhisper("Ana Brightwood")
	H.ok(M.chat[chatBefore + 1] and M.chat[chatBefore + 1]:find("/w Ana Brightwood", 1, true), "tells the player what to type")
	ChatFrame_SendTell, ChatFrame_OpenChat, ChatEdit_InsertLink = oldTell, oldOpen, oldInsert

	-- /pg debug survives an API that errors and still saves everything else
	local oldGetProfessions, oldRoster = GetProfessions, GetGuildRosterInfo
	GetProfessions = function() error("boom") end
	GetGuildRosterInfo = function() error("roster boom") end
	ProfguildDB.debug = nil
	SlashCmdList.PROFGUILD("debug")
	local dump = table.concat(ProfguildDB.debug and ProfguildDB.debug.lines or {}, "\n")
	H.ok(dump:find("GetProfessions: ERROR", 1, true), "error reported")
	H.ok(dump:find("TooltipDataProcessor: table", 1, true), "later sections still run")
	H.ok(dump:find("ChatFrameUtil.SendTell", 1, true), "chat API reported")
	H.ok(dump:find("Reagents of guildmates' recipes from the game", 1, true), "reagent API reported")
	H.ok(dump:find("Known recipes from the game: 3275 Linen Bandage=", 1, true), "fixed recipe probes reported")
	GetProfessions, GetGuildRosterInfo = oldGetProfessions, oldRoster

	H.eq(ns.lastError, nil, "no handler errors: " .. tostring(ns.lastError))
end)

H.test("addon: roster without GUIDs prunes former members by name", function()
	M.install()
	M.events, M.timers, M.sent, M.chat = {}, {}, {}, {}
	ProfguildDB = nil
	local ns = {}
	loadToc(ns)
	M.fire("ADDON_LOADED", "Profguild")
	-- roster rows without GUIDs (field 17 nil)
	local rows = {
		{ "Frost Winterborn", "Member", 3, 60, "Mage", "Zone", "", "", true, 0, "MAGE" },
		{ "Ana Brightwood", "Member", 3, 60, "Priest", "Zone", "", "", false, 0, "PRIEST" },
	}
	GetNumGuildMembers = function() return #rows, 1 end
	GetGuildRosterInfo = function(i) local r = rows[i] if r then return unpack(r, 1, 11) end end
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	M.fire("GUILD_ROSTER_UPDATE")
	M.advance(5)
	local function deliver(guid, name)
		local text = ns.Comm.Encode({ t = "D", pv = 1, s = guid, r = { g = guid, v = 2, n = name, p = {} } })
		ns.Comm:OnCommReceived("Profguild", text, "GUILD", name)
	end
	deliver("Player-1-00000002", "Ana Brightwood")
	deliver("Player-1-00000003", "Gone Away")
	H.ok(ns.store:Get("Player-1-00000003"), "former member known before the roster update")
	-- own record must carry the roster name for the name match to be trusted
	M.advance(5)
	H.eq(ns.store:Get("Player-1-00000001").n, "Frost Winterborn", "own record uses the roster name")
	M.fire("GUILD_ROSTER_UPDATE")
	H.eq(ns.store:Get("Player-1-00000003"), nil, "former member removed by name")
	H.ok(ns.store:Get("Player-1-00000002") and ns.store:Get("Player-1-00000001"), "members kept")
	H.eq(ns.lastError, nil, "no handler errors: " .. tostring(ns.lastError))
end)
