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

	-- the roster confirms who really sent a message
	H.eq(ns.Comm.MAX_TEXT, 24000)
	local maxV = ns.Store.LIMITS.maxVersion
	local anaAtMax = { g = "Player-1-00000002", v = maxV, n = "Ana Brightwood", c = "PRIEST", p = { [171] = { s = 1, m = 1, r = {} } } }
	local scratch = ns.Store.New({})
	local realStore = ns.sync.store
	ns.sync.store = scratch -- keep the real database out of this check
	scratch:Apply(anaAtMax)
	local changed = { g = anaAtMax.g, v = maxV, n = "Ana Brightwood", c = "PRIEST", p = { [171] = { s = 9, m = 9, r = {} } } }
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "D", pv = 1, s = anaAtMax.g, r = changed }), "GUILD", "Somebody Else")
	H.eq(scratch:Get(anaAtMax.g).p[171].s, 1, "another sender cannot speak for Ana")
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "D", pv = 1, s = anaAtMax.g, r = changed }), "GUILD", "Ana Brightwood")
	H.eq(scratch:Get(anaAtMax.g).p[171].s, 9, "Ana herself can, the roster knows her name")
	ns.sync.store = realStore

	-- a message that unpacks to far more than any real one is dropped and its sender ignored
	local bomb = ns.Comm.Encode({ t = "D", pv = 1, s = "Player-1-0000000F", junk = string.rep("A", ns.Comm.MAX_SERIALIZED + 10) })
	H.ok(#bomb < ns.Comm.MAX_TEXT, "the bomb is small on the wire (" .. #bomb .. " bytes)")
	local msg, why = ns.Comm.Decode(bomb)
	H.ok(msg == nil and why == "too large", "not deserialized")
	ns.Comm:OnCommReceived("Profguild", bomb, "GUILD", "Evil Sender")
	local good = ns.Comm.Encode({ t = "D", pv = 1, s = "Player-1-0000000F", r = { g = "Player-1-0000000F", v = 1, n = "Evil Sender", p = {} } })
	ns.Comm:OnCommReceived("Profguild", good, "GUILD", "Evil Sender")
	H.eq(ns.store:Get("Player-1-0000000F"), nil, "the sender is ignored for a while")
	M.advance(ns.Comm.BLOCK_SECONDS + 1)
	ns.Comm:OnCommReceived("Profguild", good, "GUILD", "Evil Sender")
	H.ok(ns.store:Get("Player-1-0000000F"), "and heard again later")
	ns.store:Remove("Player-1-0000000F")

	-- many roster events in a row read the roster once
	local reads, realRead = 0, ns.Scanner.ReadRoster
	ns.Scanner.ReadRoster = function(...) reads = reads + 1 return realRead(...) end
	for _ = 1, 10 do M.fire("GUILD_ROSTER_UPDATE") end
	M.advance(3)
	H.eq(reads, 1, "one roster read for ten events")
	ns.Scanner.ReadRoster = realRead

	-- tooltip
	M.tooltipLines = {}
	M.tooltipPostCall(GameTooltip, { id = 12360 })
	H.ok(M.tooltipLines[1] and M.tooltipLines[1]:find("Ana Brightwood"), "tooltip shows the crafter")

	-- UI: three panels (professions, list, details), search, members view, whisper, link
	local UI = ns.UI
	local function visible(list)
		local out = {}
		-- group headers of the recipe list are not results
		for _, r in ipairs(list) do
			local d = rawget(r, "data")
			if r:IsShown() and not (d and d.kind == "header") then out[#out + 1] = d end
		end
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
	H.eq(rawget(UI.rows[1], "data").kind, "header", "the list starts with a group header")
	H.eq(UI.listCount:GetText(), ns.T("MEMBER_RECIPES", 5), "the count leaves the headers out")
	for i = 2, #rows do
		if rows[i - 1].skillLine == rows[i].skillLine then H.ok(rows[i - 1].name <= rows[i].name, "sorted by name") end
	end

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

	-- groups come from the crafted item: armour before other classes, a header before each group;
	-- inside a group the highest item level comes first, items not loaded yet last; a header
	-- cannot be selected
	C_Item.GetItemInfoInstant = function(id)
		if id == 3577 then return id, "Armor", "Plate", "INVTYPE_CHEST", 1, 4, 4 end
		if id == 12360 then return id, "Trade Goods", "Metal & Stone", "", 1, 7, 7 end
	end
	local grouped = UI:BuildRecipeRows("", 171)
	H.eq(#grouped, 4, "two headers, two recipes")
	H.eq(grouped[1].kind, "header")
	H.eq(grouped[1].title, "Armor – Plate")
	H.eq(grouped[2].recipeID, 11479)
	H.eq(grouped[3].title, "Trade Goods – Metal & Stone")
	H.eq(grouped[4].recipeID, 17187)
	local realGetItemInfo = C_Item.GetItemInfo
	local levels = { [3577] = 30, [4305] = 45, [14342] = 60 }
	C_Item.GetItemInfo = function(id)
		if levels[id] then return "Item " .. id, "link", 2, levels[id], levels[id] - 5 end
		return realGetItemInfo(id)
	end
	C_Item.GetItemInfoInstant = function(id)
		if id == 4305 or id == 14342 or id == 7777 then return id, "Armor", "Cloth", "INVTYPE_HEAD", 1, 4, 1 end
	end
	local tailoring = UI:BuildRecipeRows("", 197)
	H.eq(#tailoring, 3, "one Cloth group")
	H.eq(tailoring[2].itemID, 14342, "item level 60 before 45")
	H.eq(tailoring[3].itemID, 4305)
	C_Item.GetItemInfo = realGetItemInfo
	local all = UI:BuildRecipeRows("", nil)
	local titles = {}
	for _, d in ipairs(all) do if d.kind == "header" then titles[#titles + 1] = d.title end end
	H.eq(titles[1], "Alchemy · Armor – Plate", "all professions: the header names the profession")
	C_Item.GetItemInfoInstant = nil
	UI.listCache = nil
	UI:Refresh()
	local headerRow = UI.rows[1]
	H.eq(rawget(headerRow, "data").kind, "header")
	headerRow._scripts.OnClick(headerRow, "LeftButton")
	H.eq(UI.selected, nil, "a header is not selectable")

	-- details: clicking a recipe lists its crafters, clicking a crafter whispers
	H.ok(UI.detail.empty:IsShown(), "details ask to choose a recipe")
	local first = UI.rows[2] -- the first recipe, under its group header
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

	-- more reagents than rows: all of them can be reached with the mouse wheel
	local eight = {}
	for i = 1, 8 do eight[i] = 1 end
	ns.reagents:Set(3865, eight)
	UI:Refresh()
	local shown = visible(UI.detail.reagentRows)
	H.eq(#shown, 6, "six rows")
	H.eq(shown[1].itemID, 1)
	H.eq(UI.detail.reagentCount:GetText(), "1-6 / 8", "heading says which are shown")
	H.ok(not UI.detail.reagentNote:IsShown(), "nothing drawn over the first row")
	local reagentRow = UI.detail.reagentRows[1]
	reagentRow._scripts.OnMouseWheel(reagentRow, -1)
	reagentRow._scripts.OnMouseWheel(reagentRow, -1)
	reagentRow._scripts.OnMouseWheel(reagentRow, -1)
	shown = visible(UI.detail.reagentRows)
	H.eq(shown[6].itemID, 8, "last reagent reached")
	H.eq(UI.detail.reagentCount:GetText(), "3-8 / 8")
	ns.reagents:Set(3865, { [2589] = 2 })

	-- the list is built once: scrolling and selecting reuse it, and no item is looked up
	-- for the list without a search
	local builds, realBuild = 0, UI.BuildRecipeRows
	UI.BuildRecipeRows = function(...) builds = builds + 1 return realBuild(...) end
	UI:SetCategory(nil)
	H.eq(builds, 1, "one pass over the database for a changed filter")
	local lookups, realItemName = 0, ns.Scanner.ItemName
	ns.Scanner.ItemName = function(...) lookups = lookups + 1 return realItemName(...) end
	UI.selected = nil
	UI.listCache = nil
	UI:Refresh()
	H.eq(lookups, 0, "no item lookups for the list without a search")
	builds = 0
	UI.list._scripts.OnMouseWheel(UI.list, -1)
	UI.rows[1]._scripts.OnClick(UI.rows[1], "LeftButton")
	UI:Refresh()
	H.eq(builds, 0, "scrolling and selecting reuse the list")
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "D", pv = 1, s = "Player-1-00000002", r = {
		g = "Player-1-00000002", v = 5, n = "Ana Brightwood", c = "PRIEST", a = "acc2", t = 1794615000,
		p = { [171] = { s = 281, m = 300, k = true, r = { [17187] = 12360, [11479] = 3577 } } } } }), "GUILD", "Ana Brightwood")
	UI:Refresh()
	H.eq(builds, 1, "new data rebuilds it")
	UI.BuildRecipeRows, ns.Scanner.ItemName = realBuild, realItemName
	UI.selected = nil
	UI:SetCategory(197)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == 3865 then r._scripts.OnClick(r, "LeftButton") end
	end
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
	H.ok(UI.playerButton.text:GetText():find("Ana Brightwood", 1, true), "player button names the filtered player")

	-- player filter menu: everyone with recipes, online first; "All players" clears the filter
	H.ok(not UI.playerMenu:IsShown(), "menu closed")
	UI.playerButton._scripts.OnClick(UI.playerButton)
	H.ok(UI.playerMenu:IsShown(), "menu opens")
	local players = visible(UI.playerMenu.rows)
	H.eq(#players, 3, "All players + Frost + Ana")
	H.eq(players[1].guid, nil, "first row clears the filter")
	H.eq(players[2].guid, "Player-1-00000001", "online player first")
	H.eq(players[3].guid, "Player-1-00000002")
	H.eq(players[3].recipes, 2, "recipe count")
	UI.playerMenu.rows[1]._scripts.OnClick(UI.playerMenu.rows[1])
	H.eq(UI.memberFilter, nil, "filter cleared")
	H.ok(not UI.playerMenu:IsShown(), "menu closes after a choice")
	H.eq(UI.playerButton.text:GetText(), ns.T("PLAYER_ALL"))
	-- choosing a player lists only that player's recipes
	UI:SetCategory(nil)
	UI.playerButton._scripts.OnClick(UI.playerButton)
	UI.playerMenu.rows[2]._scripts.OnEnter(UI.playerMenu.rows[2])
	UI.playerMenu.rows[2]._scripts.OnLeave(UI.playerMenu.rows[2])
	UI.playerMenu.rows[2]._scripts.OnClick(UI.playerMenu.rows[2])
	H.eq(UI.memberFilter, "Player-1-00000001", "filtered to Frost")
	local frostRows = visible(UI.rows)
	H.eq(#frostRows, 3, "Frost's three recipes")
	for _, d in ipairs(frostRows) do H.eq(d.crafters[1].guid, "Player-1-00000001") end
	-- the menu scrolls and closes with the window; the button is hidden in the Members view
	UI.playerButton._scripts.OnClick(UI.playerButton)
	UI.playerMenu._scripts.OnMouseWheel(UI.playerMenu, -1)
	UI.membersTab._scripts.OnClick(UI.membersTab)
	H.ok(not UI.playerMenu:IsShown() and not UI.playerButton:IsShown(), "no player filter in the Members view")
	H.eq(UI.memberFilter, nil, "Members view drops the filter")
	UI.recipesTab._scripts.OnClick(UI.recipesTab)
	H.ok(UI.playerButton:IsShown())
	UI:SetCategory(171)
	UI.recipesTab._scripts.OnClick(UI.recipesTab)
	UI:SetCategory(nil)

	-- a guildmate with a newer version: one notice per session, shown in the window too
	local noticeAt = #M.chat
	local function helloFrom(av, pv)
		ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "H", pv = pv or 1, s = "Player-1-00000002", av = av, d = {} }), "GUILD", "Ana Brightwood")
	end
	helloFrom("0.1.0-test") -- same version as ours in the test
	helloFrom("0.0.9")
	helloFrom("|cffff0000junk|r")
	M.advance(8)
	H.eq(ns.newerVersion, nil, "same, older and junk versions say nothing")
	helloFrom("0.2.0")
	helloFrom("0.3.1")
	helloFrom("0.2.5")
	M.advance(8)
	helloFrom("0.3.1")
	M.advance(8)
	local notices = 0
	for i = noticeAt + 1, #M.chat do
		if M.chat[i]:find(ns.T("UPDATE_AVAILABLE", "0.3.1", "0.1.0-test"), 1, true) then notices = notices + 1 end
	end
	H.eq(notices, 1, "one notice with the highest version seen")
	UI:Refresh()
	H.ok(UI.status:GetText():find(ns.T("UPDATE_SHORT", "0.3.1"), 1, true), "window footer shows it")
	-- a newer protocol is announced once as well
	noticeAt = #M.chat
	helloFrom("9.0.0", 2); helloFrom("9.0.0", 2)
	local protocolNotices = 0
	for i = noticeAt + 1, #M.chat do
		if M.chat[i]:find(ns.T("NEWER_VERSION"), 1, true) then protocolNotices = protocolNotices + 1 end
	end
	H.eq(protocolNotices, 1, "newer protocol announced once")
	H.eq(ns.newerVersion, "0.3.1", "a message of another protocol is not read further")

	-- manual sync: says it started, then what arrived
	local function chatSince(index)
		local lines = {}
		for i = index + 1, #M.chat do lines[#lines + 1] = M.chat[i] end
		return table.concat(lines, "\n")
	end
	local chatAt = #M.chat
	ns.sync.lastHello = -1e9
	SlashCmdList.PROFGUILD("sync")
	H.ok(chatSince(chatAt):find(ns.T("SYNC_STARTED"), 1, true), "sync start announced")
	SlashCmdList.PROFGUILD("sync")
	H.ok(chatSince(chatAt):find(ns.T("SYNC_RUNNING"), 1, true), "a second sync is not started")
	M.advance(2)
	-- Ana learned one recipe, and a new member appears
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "D", pv = 1, s = "Player-1-00000002", r = {
		g = "Player-1-00000002", v = 9, n = "Ana Brightwood", c = "PRIEST", a = "acc2", t = 1794615000,
		p = { [171] = { s = 282, m = 300, k = true, r = { [17187] = 12360, [11479] = 3577, [2330] = 118 } } } } }), "GUILD", "Ana Brightwood")
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "D", pv = 1, s = "Player-1-00000007", r = {
		g = "Player-1-00000007", v = 1, n = "New Guy", c = "ROGUE", t = 1794615000,
		p = { [165] = { s = 10, m = 75, k = true, r = { [2149] = 2302, [2152] = 2304 } } } } }), "GUILD", "New Guy")
	H.ok(not chatSince(chatAt):find("Ana Brightwood", 1, true), "no result while data is still arriving")
	M.advance(20)
	local result = chatSince(chatAt)
	H.ok(result:find(ns.T("SYNC_ITEM_MORE", "Ana Brightwood", 1), 1, true), "Ana's new recipe reported: " .. result)
	H.ok(result:find(ns.T("SYNC_ITEM_NEW", "New Guy", 2), 1, true), "new member reported")
	H.eq(ns.syncReport, nil, "report finished")
	ns.store:Remove("Player-1-00000007")
	-- a sync that brings nothing says so
	chatAt = #M.chat
	ns.sync.lastHello = -1e9
	UI.syncButton._scripts.OnClick(UI.syncButton)
	M.advance(20)
	H.ok(chatSince(chatAt):find(ns.T("SYNC_DONE_NONE"), 1, true), "nothing new reported")
	H.eq(UI.syncButton.text:GetText(), "SYNC", "button label")

	-- a steady stream of changes still refreshes the open window
	local refreshes, realRefresh = 0, UI.Refresh
	UI.Refresh = function(...) refreshes = refreshes + 1 return realRefresh(...) end
	for _ = 1, 25 do
		ns.OnDataChanged()
		M.advance(0.2, 0.1)
	end
	H.ok(refreshes >= 5, "window refreshed during 5 s of constant changes (" .. refreshes .. ")")
	UI.Refresh = realRefresh

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

H.test("addon: a guild saved under different realm names is one database", function()
	M.install()
	M.events, M.timers, M.sent, M.chat = {}, {}, {}, {}
	-- two logins reported two realm names, so 0.1.11 and older kept two databases
	ProfguildDB = { guilds = {
		["Black Lotus@RealmOne"] = { records = { ["Player-1-00000002"] = { g = "Player-1-00000002", v = 3, n = "Ana Brightwood",
			p = { [171] = { s = 280, m = 300, k = true, r = { [17187] = 12360 } } } } }, names = { ["Player-1-00000002"] = "Ana Brightwood" } },
		["Black Lotus@RealmTwo"] = { records = { ["Player-1-00000002"] = { g = "Player-1-00000002", v = 2, n = "Ana Brightwood", p = {} } } },
		["Other Guild@RealmOne"] = { records = { X = { g = "X", v = 1, n = "X", p = {} } } },
	} }
	local ns = {}
	loadToc(ns)
	M.fire("ADDON_LOADED", "Profguild")
	GetNormalizedRealmName = function() return "RealmThree" end
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	H.eq(ns.guildKey, "Black Lotus", "the key is the guild name")
	H.eq(ns.store:Get("Player-1-00000002").v, 3, "newest record of the old databases kept")
	H.eq(ProfguildDB.guilds["Black Lotus@RealmOne"], nil); H.eq(ProfguildDB.guilds["Black Lotus@RealmTwo"], nil)
	H.ok(ProfguildDB.guilds["Other Guild@RealmOne"], "another guild is left alone")
	-- the next login reports yet another realm: same database
	GetNormalizedRealmName = function() return "RealmFour" end
	ns.guildKey = nil
	ns.SetupGuild()
	H.eq(ns.guildKey, "Black Lotus"); H.ok(ns.store:Get("Player-1-00000002"), "still there")
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
	M.advance(2)
	H.eq(ns.store:Get("Player-1-00000003"), nil, "former member removed by name")
	H.ok(ns.store:Get("Player-1-00000002") and ns.store:Get("Player-1-00000001"), "members kept")
	H.eq(ns.lastError, nil, "no handler errors: " .. tostring(ns.lastError))
end)
