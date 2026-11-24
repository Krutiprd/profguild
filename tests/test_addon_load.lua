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
	-- a collapsed group keeps only its header with the number of its recipes; a search, and
	-- Leveling, still list everything
	ns.db.settings.collapsed = { [grouped[1].group] = true }
	local folded = UI:BuildRecipeRows("", 171)
	H.eq(#folded, 3, "the collapsed group hides its recipe")
	H.ok(folded[1].collapsed and folded[1].count == 1, "header: collapsed, 1 recipe")
	H.eq(folded[2].title, "Trade Goods – Metal & Stone", "the next group follows")
	H.eq(#UI:BuildRecipeRows("", 171, true), 4, "flat: nothing hidden")
	ns.db.settings.collapsed = nil
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
	local group = rawget(headerRow, "data").group
	headerRow._scripts.OnClick(headerRow, "LeftButton")
	H.eq(UI.selected, nil, "a header is not selectable")
	H.ok(ns.db.settings.collapsed[group], "a click on the header collapses its group")
	H.ok(rawget(UI.rows[1], "data").collapsed, "the list was rebuilt with the group collapsed")
	H.ok(UI.rows[1].name:GetText():find("PlusButton", 1, true), "the header shows [+]")
	H.eq(UI.listCache.listed, 2, "the recipe count includes the collapsed group")
	H.eq(UI.listEmpty:GetText(), "", "no empty-list text over a collapsed group")
	local inside = rawget(UI.rows[1], "data").hidden[1]
	UI.selected = inside
	UI:Refresh()
	H.eq(UI.selected and UI.selected.key, inside.key, "a recipe in a collapsed group stays selected")
	UI.selected = nil
	UI.rows[1]._scripts.OnClick(UI.rows[1], "LeftButton")
	H.eq(ns.db.settings.collapsed[group], nil, "a second click opens it again")

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
	-- the tooltip of an item that was not loaded yet is drawn again when the item arrives
	local draws, realSetItem = 0, GameTooltip.SetItemByID
	GameTooltip.SetItemByID = function() draws = draws + 1 end
	GameTooltip.GetOwner = function() return first end
	first._scripts.OnEnter(first)
	H.eq(draws, 1)
	M.fire("GET_ITEM_INFO_RECEIVED", rawget(first, "data").itemID, true)
	H.eq(draws, 2, "tooltip drawn again with the item data")
	first._scripts.OnLeave(first)
	M.fire("GET_ITEM_INFO_RECEIVED", 1, true)
	H.eq(draws, 2, "not after the mouse left")
	GameTooltip.SetItemByID, GameTooltip.GetOwner = realSetItem, nil
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
	H.eq(UI.detail.profitValue:GetText(), ns.Prices.Format(650), "sells for 1000, the auction house keeps 50")
	H.ok(UI.detail.value:GetText():find(ns.Prices.Format(1000), 1, true), "item value shown")
	H.ok(not UI.detail.shopButton.disabled, "shopping list available")
	-- the list shows the profit next to the name: 1000 - 5 % cut - 2 x 150 copper
	local profitRow
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == 3865 then profitRow = r end
	end
	H.ok(profitRow.profit:GetText():find("+6s", 1, true), "profit in the list: " .. profitRow.profit:GetText())
	H.eq(ns.Prices.AfterCut(1000, "ah"), 950, "auction sale minus 5 %")
	H.eq(ns.Prices.AfterCut(1001, "ah"), 950, "the cut rounds down to copper")
	H.eq(ns.Prices.AfterCut(1000, "vendor"), 1000, "a vendor takes no cut")
	-- a reagent a vendor also sells: the auction price counts, the vendor price is shown beside it
	local realVendor = Auctionator.API.v1.GetVendorPriceByItemID
	Auctionator.API.v1.GetVendorPriceByItemID = function(_, id) if id == 2589 then return 200 end end
	H.eq(ns.Prices.Cost({ [2589] = 2 }), 300, "2 x auction 150, not 2 x vendor 200")
	H.eq(ns.Prices.VendorPrice(2589), 200)
	UI:Refresh()
	local reagentText = UI.detail.reagentRows[1].right:GetText()
	H.ok(reagentText:find(ns.Prices.Format(400), 1, true) and reagentText:find(ns.Prices.Format(300), 1, true),
		"reagent row shows vendor 400 and auction 300: " .. reagentText)
	local reagentRow = UI.detail.reagentRows[1]
	H.ok(reagentRow.left._width < 302 - 26 - 4 - reagentRow.right:GetStringWidth() - 7,
		"the name gives way to the longer price text: " .. reagentRow.left._width)
	-- a crafted item with no auction price: a vendor pays its sell price, not what a merchant asks
	local realAuction = Auctionator.API.v1.GetAuctionPriceByItemID
	local realInfo = C_Item.GetItemInfo
	Auctionator.API.v1.GetAuctionPriceByItemID = function(_, id) if id == 2589 then return 150 end end
	Auctionator.API.v1.GetVendorPriceByItemID = function(_, id) if id == 4305 then return 5000 end end
	C_Item.GetItemInfo = function(id)
		if id == 4305 then return "Item 4305", "link", 1, 10, 5, nil, nil, 20, nil, nil, 600 end
		return realInfo(id)
	end
	H.eq(select(2, ns.Prices.Get(4305)), "vendor", "Auctionator knows only what a merchant asks")
	H.eq(ns.Prices.SaleValue(4305), 600, "the sell price, not the merchant's 5000")
	UI:Refresh()
	H.eq(UI.detail.profitValue:GetText(), ns.Prices.Format(300), "600 from a vendor, no cut, - 300")
	H.ok(UI.detail.value:GetText():find(ns.T("ITEM_VALUE_VENDOR", ns.Prices.Format(600)), 1, true),
		"the value says a vendor pays it: " .. UI.detail.value:GetText())
	Auctionator.API.v1.GetAuctionPriceByItemID = realAuction
	C_Item.GetItemInfo = realInfo
	Auctionator.API.v1.GetVendorPriceByItemID = realVendor
	UI:Refresh()
	H.eq(ns.Prices.Short(-123456), "-12g")
	H.eq(ns.Prices.Short(250), "+2s")
	H.eq(ns.Prices.Short(7), "+7c")
	-- an item that binds on pickup cannot be sold: the profit is minus the reagents
	local realGetInfo = C_Item.GetItemInfo
	C_Item.GetItemInfo = function(id)
		if id == 4305 then return "Item 4305", "link", 2, 45, 40, nil, nil, nil, nil, nil, nil, nil, nil, 1 end
		return realGetInfo(id)
	end
	UI:Refresh()
	H.ok(profitRow.profit:GetText():find("-3s", 1, true), "BoP: loss of the reagents: " .. profitRow.profit:GetText())
	H.ok(UI.detail.value:GetText():find(ns.T("ITEM_BOP"), 1, true), "details say it cannot be sold")
	H.ok(UI.detail.profitValue:GetText():find(ns.Prices.Format(300), 1, true), "profit -300 copper")
	C_Item.GetItemInfo = realGetInfo
	-- at the auction house a button asks Auctionator to search the item and its reagents
	H.ok(not UI.detail.refreshButton:IsShown(), "no refresh button away from the auction house")
	local searched, listener
	Auctionator.API.v1.MultiSearchExact = function(_, names) searched = names end
	Auctionator.EventBus = { Register = function(_, l) listener = l end, Unregister = function() end }
	Auctionator.Search = { Events = { PricesProcessed = "search_prices_processed" } }
	AuctionFrame = CreateFrame("Frame")
	UI:Refresh()
	H.ok(UI.detail.refreshButton:IsShown(), "refresh button at the auction house")
	UI.detail.refreshButton._scripts.OnClick(UI.detail.refreshButton)
	-- (4305 binds on pickup since the check above: it cannot be sold, so it is not searched)
	H.ok(searched and searched[1] == "Item 2589" and #searched == 1, "the reagent searched, not the BoP item")
	H.ok(listener and listener.ReceiveEvent, "waits for the prices")
	listener:ReceiveEvent()
	listener:ReceiveEvent() -- one notice per searched item: still listening
	M.advance(7)
	AuctionFrame:Hide()
	UI:Refresh()
	H.ok(not UI.detail.refreshButton:IsShown(), "hidden when the auction house closes")
	AuctionFrame, Auctionator.EventBus, Auctionator.Search = nil, nil, nil
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
	H.eq(#shown, 5, "five rows")
	H.eq(shown[1].itemID, 1)
	H.eq(UI.detail.reagentCount:GetText(), "1-5 / 8", "heading says which are shown")
	H.ok(not UI.detail.reagentNote:IsShown(), "nothing drawn over the first row")
	local reagentRow = UI.detail.reagentRows[1]
	reagentRow._scripts.OnMouseWheel(reagentRow, -1)
	reagentRow._scripts.OnMouseWheel(reagentRow, -1)
	reagentRow._scripts.OnMouseWheel(reagentRow, -1)
	shown = visible(UI.detail.reagentRows)
	H.eq(shown[5].itemID, 8, "last reagent reached")
	H.eq(UI.detail.reagentCount:GetText(), "4-8 / 8")
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

	-- recipe filter: recipes nobody in the guild knows come from the catalog (the profession
	-- window lists the unlearned ones too); a click switches available -> unavailable -> all
	H.eq(ProfguildDB.catalog[197][3866], 14342, "unlearned recipe in the catalog, with its item")
	H.eq(ProfguildDB.catalog[197][3865], 4305, "learned ones too")
	H.eq(ProfguildDB.settings.recipeFilter, "known", "available by default")
	local function listed() return UI.listCache.listed end
	local known = listed()
	H.ok(known > 0)
	H.eq(UI.recipeButton.text:GetText(), ns.T("RECIPES_KNOWN"))
	-- own recipes carry the colour of the profession window
	local ownState = ProfguildDB.own["Player-1-00000001"]
	H.ok(ownState.colors, "colours saved by the scan")
	ownState.colors[3865] = 1
	UI.listCache = nil
	UI:SetCategory(197)
	local dotted
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == 3865 then dotted = r.name:GetText() end
	end
	H.ok(dotted and dotted:find("|cffffff00•|r", 1, true) == 1, "yellow dot before the name: " .. tostring(dotted))
	UI:SetCategory(nil)
	UI.recipeButton._scripts.OnClick(UI.recipeButton)
	H.eq(ProfguildDB.settings.recipeFilter, "unknown")
	local unknown = visible(UI.rows)
	H.eq(#unknown, 1, "one recipe nobody knows")
	H.eq(unknown[1].recipeID, 3866)
	H.ok(unknown[1].nobody, "marked")
	H.ok(UI.rows[2].sub:GetText():find(ns.T("NOBODY_KNOWS"), 1, true), "the row says nobody knows it")
	UI.rows[2]._scripts.OnEnter(UI.rows[2])
	UI.rows[2]._scripts.OnLeave(UI.rows[2])
	UI.rows[2]._scripts.OnClick(UI.rows[2], "LeftButton")
	H.eq(UI.selected.recipeID, 3866)
	H.eq(UI.detail.recipeHint:GetText(), ns.T("HINT_NOBODY"), "details say nobody knows it")
	H.eq(#visible(UI.detail.rows), 0, "no crafters")
	-- where the recipe comes from (Data.lua) and the price of its recipe item (Auctionator)
	H.ok(ns.RecipeData, "Data.lua loaded")
	ns.RecipeData[3866] = { 7777, "dv", 135, 140, 145 }
	ns.RecipeData[3865] = { false, "", 0, 60, 80 }
	H.eq(table.concat({ ns.Prices.RecipeSkill(3866) }, ","), "135,140,142,145", "learn, yellow, green, grey")
	local learn, yellow, green, grey = ns.Prices.RecipeSkill(3865)
	H.ok(learn == nil and yellow == 60 and green == 70 and grey == 80, "a trainer recipe: learn level unknown")
	H.eq(ns.Prices.RecipeSkill(1), nil, "not in Data.lua")
	ns.RecipeData[3864] = { false, "", 0, 320, 310 }
	H.eq(table.concat({ select(2, ns.Prices.RecipeSkill(3864)) }, ","), "310,310,310", "yellow never above grey")
	Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function(_, id) return ({ [7777] = 374000 })[id] end,
		GetAuctionAgeByItemID = function() return 0 end,
		GetVendorPriceByItemID = function() end,
	} } }
	UI.listCache = nil
	UI:Refresh()
	local info = UI.detail.recipeInfo:GetText()
	H.ok(info:find(ns.T("SRC_DROP"), 1, true) and info:find(ns.T("SRC_VENDOR"), 1, true), "sources named: " .. info)
	H.ok(info:find(ns.Prices.Format(374000), 1, true) and info:find(ns.T("TODAY"), 1, true), "price seen today")
	H.ok(UI.rows[2].sub:GetText():find(ns.T("LIST_RECIPE_AH", ns.Prices.Format(374000)), 1, true), "the list row shows the recipe price")
	H.eq(select(1, ns.Prices.RecipeItem(3865)), false, "a trainer recipe")
	Auctionator = nil
	UI:Refresh()
	H.ok(UI.detail.recipeInfo:GetText():find(ns.T("RECIPE_NO_AH"), 1, true), "without prices: not on AH")
	-- the game says where the recipe is found: asked once when the recipe is opened, then kept
	local asked = 0
	C_TradeSkillUI.GetRecipeSourceText = function(id)
		asked = asked + 1
		return "|cffffd200Vendor: |rBena|n|cffffd200Zone: |rThunder Bluff|T icon|t"
	end
	ProfguildDB.sources[3866] = nil
	H.eq(ProfguildDB.sources[3866], nil, "an empty answer was not saved")
	M.advance(61) -- asked again a minute after the empty answer
	UI:Refresh()
	UI:Refresh()
	H.eq(asked, 1, "asked once")
	H.ok(UI.detail.recipeInfo:GetText():find("Bena · |cffffd200Zone: |rThunder Bluff", 1, true), "game text on one line: " .. UI.detail.recipeInfo:GetText())
	H.ok(ProfguildDB.sources[3866], "kept in SavedVariables")
	C_TradeSkillUI.GetRecipeSourceText = nil
	-- skill levels: grey from the game, learnable from the recipe item's tooltip
	local realRecipeInfo = C_TradeSkillUI.GetRecipeInfo
	C_TradeSkillUI.GetRecipeInfo = function(id) local i = realRecipeInfo(id) i.maxTrivialLevel = 320 return i end
	C_TooltipInfo = { GetItemByID = function(id)
		if id == 7777 then return { lines = { { leftText = "Pattern: X" }, { leftText = "|cffff2020Requires Tailoring (275)|r" } } } end
	end }
	ProfguildDB.recipeInfo[3866] = nil
	UI:Refresh()
	local skillText = UI.detail.value:GetText()
	H.ok(skillText:find("275", 1, true) and skillText:find("320", 1, true), "learn at 275, grey at 320: " .. skillText)
	H.eq(ProfguildDB.recipeInfo[3866].m, 275, "kept")
	H.eq(ProfguildDB.recipeInfo[3866].g, 320)
	C_TradeSkillUI.GetRecipeInfo, C_TooltipInfo = realRecipeInfo, nil
	-- recipe items Auctionator has seen are matched to recipes by name, without Wowhead
	local realGetInfo2, realInstant = C_Item.GetItemInfo, C_Item.GetItemInfoInstant
	C_Item.GetItemInfoInstant = function(id)
		if id == 8888 then return 8888, "Recipe", "Tailoring", "", 1, 9, 2 end
		if id == 8889 then return 8889, "Recipe", "Alchemy", "", 1, 9, 6 end
	end
	C_Item.GetItemInfo = function(id)
		if id == 8888 then return "Pattern: Recipe 18560" end
		if id == 8889 then return "Recipe: Recipe 18560" end -- an alchemy item of the same name
		return realGetInfo2(id)
	end
	Auctionator = { Database = { db = { ["8888"] = {}, ["8889"] = {}, ["2589"] = {}, ["g:123"] = {} } } }
	H.eq(ns.Prices.IndexRecipeItems(), 1, "one recipe item found")
	H.eq(ns.Prices.RecipeItem(18560), 8888, "matched to the Tailoring recipe, not the alchemy one")
	H.eq(ProfguildDB.recipeItems[18560], 8888, "kept")
	-- how many were on the market: the latest day Auctionator recorded
	Auctionator.Database.db["2589"] = { m = 150, a = { ["2513"] = 40, ["2514"] = 12 } }
	H.eq(ns.Prices.Available(2589), 12, "quantity of the latest day")
	H.eq(ns.Prices.Available(8888), nil, "no quantity recorded")
	Auctionator = nil
	C_Item.GetItemInfo, C_Item.GetItemInfoInstant = realGetInfo2, realInstant
	-- required character level of the crafted item
	-- (the item was loaded earlier in this test with level 60, required 55)
	UI.listCache = nil
	UI:Refresh()
	local levelShown
	for _, r in ipairs(UI.rows) do if r.level:GetText() == ns.T("LIST_LEVEL", 55) then levelShown = true end end
	H.ok(levelShown, "required level in the list")
	H.ok(UI.detail.sub:GetText():find(ns.T("REQ_LEVEL", 55), 1, true), "required level: " .. UI.detail.sub:GetText())
	UI.recipeButton._scripts.OnClick(UI.recipeButton)
	H.eq(ProfguildDB.settings.recipeFilter, "all")
	H.eq(UI.selected, nil, "switching the filter drops the selection")
	H.eq(listed(), known + 1, "all: available and unavailable")
	-- online only with all recipes: a recipe whose crafters are offline stays, marked
	UI.onlineButton._scripts.OnClick(UI.onlineButton)
	local offline
	for _, d in ipairs(UI.listCache.data) do
		if d.kind == "recipe" and #d.crafters == 0 and not d.nobody then offline = d end
	end
	H.ok(offline, "a recipe of an offline crafter is still listed")
	UI.onlineButton._scripts.OnClick(UI.onlineButton)
	UI.recipeButton._scripts.OnClick(UI.recipeButton)
	H.eq(ProfguildDB.settings.recipeFilter, "known", "back to available")
	H.eq(listed(), known)

	-- leveling: the recipes of a profession sorted by the skill they turn grey at, with the
	-- skill levels in the row; it opens at the first recipe that still gives skill
	ProfguildDB.recipeInfo[3865] = { g = 260, m = 200 }
	ProfguildDB.recipeInfo[3866] = { g = 230 }
	ProfguildDB.recipeInfo[18560] = { g = 300 }
	ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
	ProfguildDB.settings.recipeFilter = "all"
	UI.levelingTab._scripts.OnClick(UI.levelingTab)
	H.eq(UI.view, "leveling")
	UI:SetCategory(197)
	local lv = UI.listCache.data
	H.eq(#lv, 3, "no headers")
	H.eq(lv[1].recipeID, 3866); H.eq(lv[2].recipeID, 3865); H.eq(lv[3].recipeID, 18560)
	H.eq(UI.levelStart, 2, "Frost has 250 Tailoring: starts at the recipe grey at 260")
	H.ok(UI.rows[2].sub:GetText():find("|cffff2020200|r  |cff808080260|r", 1, true), "skill in the row: " .. UI.rows[2].sub:GetText())
	H.eq(UI.listTitle:GetText(), ns.T("HEAD_LEVELING"))
	-- a trainer says the skill every recipe needs
	GetNumTrainerServices = function() return 2 end
	GetTrainerServiceInfo = function(i) if i == 1 then return "Recipe 18560", "", "available" end return "Tailoring", "", "header" end
	GetTrainerServiceSkillReq = function(i) return "Tailoring", i == 1 and 275 or 0, true end
	M.fire("TRAINER_SHOW")
	M.advance(1)
	H.eq(ProfguildDB.recipeInfo[18560].m, 275, "skill from the trainer")
	GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceSkillReq = nil, nil, nil
	UI.recipesTab._scripts.OnClick(UI.recipesTab)
	ProfguildDB.settings.recipeFilter = "known"
	UI:SetCategory(nil)

	-- a guildmate's list is taken only after asking, and only recipes the game puts in that
	-- profession (the fake game puts every recipe into Cooking)
	H.ok(ns.catalog:Want(185), "asked for Cooking")
	H.ok(ns.catalog:Want(333), "asked for Enchanting")
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "KL", pv = 2, s = "Player-1-00000002", l = 185, c = 1,
		r = { 7828 } }), "GUILD", "Ana Brightwood")
	H.eq(ProfguildDB.catalog[185][7828], 14342, "Cooking recipe taken, item from the game")
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "KL", pv = 2, s = "Player-1-00000002", l = 333, c = 1,
		r = { 7829 } }), "GUILD", "Ana Brightwood")
	H.eq(ProfguildDB.catalog[333], nil, "a recipe of another profession is dropped")
	-- the digest goes out after a hello
	local sentBeforeHello = #M.sent
	ns.sync.lastHello = -1e9
	H.ok(ns.Hello(true))
	M.advance(3)
	local digest
	for i = sentBeforeHello + 1, #M.sent do
		local msg = ns.Comm.Decode(M.sent[i].text)
		if msg and msg.t == "KD" then digest = msg end
	end
	H.ok(digest and digest.d[197] == 3, "catalog digest sent after the hello")

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

	-- item data is asked for through a queue: 20 per half second, items on screen first,
	-- and again after 10 s when it did not arrive
	local requested, realRequest, realCached = {}, C_Item.RequestLoadItemDataByID, C_Item.IsItemDataCachedByID
	C_Item.RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end
	C_Item.IsItemDataCachedByID = function() return false end
	M.advance(1)
	requested = {}
	for id = 900001, 900050 do ns.Scanner.WantItem(id) end
	ns.Scanner.WantItem(900050, true)
	M.advance(0.5)
	H.eq(requested[1], 900050, "the urgent item first")
	H.ok(#requested <= 40, "paced (" .. #requested .. ")")
	M.advance(3)
	H.eq(#requested, 50, "all asked for")
	ns.Scanner.WantItem(900001)
	M.advance(1)
	H.eq(#requested, 50, "not again right away")
	M.advance(10)
	ns.Scanner.WantItem(900001)
	M.advance(1)
	H.eq(#requested, 51, "asked again after 10 s")
	C_Item.RequestLoadItemDataByID, C_Item.IsItemDataCachedByID = realRequest, realCached

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
