-- Guild item requests inside the whole addon: Core and Comm glue, chat notices, /pg status, and
-- the window (view, create box, buttons).
local H = ...
M = M or dofile(H.root .. "/tests/wowmock.lua"); local M = M

local ME, ANA = "Player-1-00000001", "Player-1-00000002"

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

local function login()
	ProfguildDB = nil
	Auctionator = nil
	local ns = loadAddon()
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	M.fire("TRADE_SKILL_SHOW") -- Tailoring: we know 3865 (makes 4305)
	M.advance(5)
	return ns
end

local function sentOfType(ns, from, t)
	local out = {}
	for i = from + 1, #M.sent do
		local msg = ns.Comm.Decode(M.sent[i].text)
		if msg and msg.t == t then out[#out + 1] = msg end
	end
	return out
end

local function receive(ns, msg)
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode(msg), "GUILD", "Ana Brightwood")
end

local function anaRequest(ns, recipeID, n)
	local clock = GetServerTime()
	return { id = ANA .. "-" .. clock .. "-1", by = ANA, r = recipeID, i = 4305, n = n or 2, note = "pls",
		c = clock, st = "open", u = clock, ub = ANA }
end

local function chatHas(text)
	for _, line in ipairs(M.chat) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

local function count(text)
	local n = 0
	for _, line in ipairs(M.chat) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

H.test("addon requests: a guildmate's request for a recipe we know is announced once", function()
	local ns = login()
	H.ok(ns.requests, "requests set up with the guild")
	local rec = anaRequest(ns, 3865)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
	H.ok(ns.requests:Get(rec.id), "stored")
	local notice = ns.T("REQ_NEW_NOTICE", "Ana Brightwood", 2, "Item 4305")
	H.ok(chatHas(notice), "notice: " .. notice)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
	H.eq(count(notice), 1, "once")
	-- a recipe we do not know: no notice
	local other = anaRequest(ns, 99999)
	other.id = ANA .. "-" .. other.c .. "-2"
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { other } })
	H.ok(ns.requests:Get(other.id))
	H.eq(count("Ana Brightwood"), 1)
end)

H.test("addon requests: our request taken by a guildmate, status, digest after hello", function()
	local ns = login()
	local before = #M.sent
	local rec = ns.requests:Create(3865, 4305, 1, "")
	M.advance(3)
	H.eq(#sentOfType(ns, before, "TU"), 1, "our request went out")
	local taken = {}
	for k, v in pairs(rec) do taken[k] = v end
	taken.st, taken.cr, taken.tk, taken.u, taken.ub = "taken", ANA, rec.c + 5, rec.c + 5, ANA
	M.advance(5)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { taken } })
	H.eq(ns.requests:Get(rec.id).st, "taken")
	H.ok(chatHas(ns.T("REQ_TAKEN_NOTICE", "Ana Brightwood", "Item 4305")), "the requester is told")
	SlashCmdList.PROFGUILD("status")
	H.ok(chatHas(ns.T("STATUS_REQUESTS", 0, 1, 1, 0, 0, 1, 0, 0)) or chatHas("Requests: 0 open, 1 taken"), "status line")
	before = #M.sent
	ns.sync.lastHello = -1e9
	ns.Hello(true)
	M.advance(2)
	local td = sentOfType(ns, before, "TD")
	H.ok(#td >= 1, "digest after the hello"); H.eq(td[#td].x[1], rec.id)
end)

H.test("addon requests: a guild change stops the old guild's requests", function()
	local ns = login()
	local old = ns.requests
	old:Create(3865, 4305, 1, "")
	GetGuildInfo = function() return "Other Guild", "Member", 3, nil end
	ns.SetupGuild()
	local before = #M.sent
	M.advance(5)
	H.ok(old.dead); H.ok(ns.requests ~= old)
	H.eq(#sentOfType(ns, before, "TU"), 0, "nothing of the old guild reaches the new one")
end)

local function openRecipe(UI, recipeID)
	UI:SetView("recipes")
	UI:SetCategory(197)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == recipeID and not d.request then r._scripts.OnClick(r, "LeftButton") end
	end
	return UI.selected
end

local function openRequest(UI, id)
	UI:SetView("requests")
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.request and d.request.id == id then r._scripts.OnClick(r, "LeftButton") return d, r end
	end
end

H.test("addon requests window: a request is made from the recipe details", function()
	local ns = login()
	local UI = ns.UI
	UI:Toggle()
	H.eq(openRecipe(UI, 3865).recipeID, 3865)
	local d = UI.detail
	H.ok(d.requestButton:IsShown(), "button in the details"); H.eq(d.requestButton.text:GetText(), ns.T("BTN_REQUEST"))
	d.requestButton._scripts.OnClick(d.requestButton)
	local box = UI.requestBox
	H.ok(box:IsShown(), "the box opens")
	box.count:SetText("3")
	box.note:SetText("for my alt")
	local before = #M.sent
	box.saveButton._scripts.OnClick(box.saveButton)
	H.ok(not box:IsShown(), "closed after saving")
	local rec = ns.requests:All()[1]
	H.ok(rec, "created"); H.eq(rec.n, 3); H.eq(rec.note, "for my alt"); H.eq(rec.r, 3865)
	M.advance(3)
	H.eq(#sentOfType(ns, before, "TU"), 1, "sent to the guild")
	-- a wrong count is not saved
	d.requestButton._scripts.OnClick(d.requestButton)
	box.count:SetText("0")
	box.saveButton._scripts.OnClick(box.saveButton)
	H.eq(#ns.requests:All(), 1, "count 0 refused")
	box.cancelButton._scripts.OnClick(box.cancelButton)
	H.ok(not box:IsShown())
	-- the view lists it
	local row = openRequest(UI, rec.id)
	H.ok(row, "listed in the requests view")
	H.eq(UI.requestsTab.text:GetText(), ns.T("HEAD_REQUESTS"))
	-- our own open request: we may only cancel it
	H.ok(not d.linkButton:IsShown() or d.linkButton.disabled, "no take of our own")
	H.eq(d.shopButton.text:GetText(), ns.T("BTN_REQ_CANCEL"))
	H.ok(d.recipeInfo:GetText():find(ns.T("REQ_STATE_OPEN"), 1, true), "state in the details: " .. d.recipeInfo:GetText())
	d.shopButton._scripts.OnClick(d.shopButton)
	H.eq(ns.requests:Get(rec.id).st, "cancelled")
end)

H.test("addon requests window: NEW REQUEST searches a recipe of the guild", function()
	local ns = login()
	local UI = ns.UI
	UI:Toggle()
	UI:SetView("requests")
	local b = UI.newRequestButton
	H.ok(b:IsShown(), "shown in the requests view"); H.eq(b.text:GetText(), ns.T("BTN_NEW_REQUEST"))
	b._scripts.OnClick(b)
	local box = UI.requestBox
	H.ok(box:IsShown() and box.pick:IsShown(), "the box opens with the search")
	H.ok(box.saveButton.disabled, "nothing to send before a recipe is chosen")
	box.saveButton._scripts.OnClick(box.saveButton)
	H.eq(#ns.requests:All(), 0, "no request without a recipe")
	box.search:SetText("r")
	UI:DrawRequestPicks()
	H.eq(box.pickNote:GetText(), ns.T("REQ_BOX_PICK"), "one letter: asks for more")
	box.search:SetText("recipe 3865")
	UI:DrawRequestPicks()
	local first = box.picks[1]
	H.ok(first:IsShown() and first.data.recipeID == 3865, "found the recipe")
	H.ok(not box.picks[2]:IsShown(), "only that one")
	first._scripts.OnClick(first)
	H.ok(not box.saveButton.disabled, "a recipe chosen: can be sent")
	box.count:SetText("2")
	box.saveButton._scripts.OnClick(box.saveButton)
	local rec = ns.requests:All()[1]
	H.ok(rec and rec.r == 3865 and rec.n == 2, "created from the search")
	box.search:SetText("no such thing")
	UI:DrawRequestPicks()
	-- typing after a choice drops it; the player filter of the recipe list does not count here
	b._scripts.OnClick(b)
	box.search:SetText("recipe 3865")
	UI:ChooseRequestRecipe(box.picks[1].data)
	H.ok(UI.requestRecipe, "chosen")
	box.search._scripts.OnTextChanged(box.search, true)
	H.eq(UI.requestRecipe, nil, "typing again drops the choice")
	H.ok(box.saveButton.disabled)
	H.eq(#UI:FindRequestRecipes("recipe 3866"), 1, "a recipe nobody knows can be asked for")
	box.search:SetText("recipe 3866")
	H.eq(box.picks[1].count:GetText(), ns.T("REQ_PICK_NOBODY"))
	box.search:SetText("recipe 3865")
	UI.memberFilter = "Player-1-0000FFFF"
	H.eq(#UI:FindRequestRecipes("recipe 3865"), 1, "found despite a player filter")
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { anaRequest(ns, 3865, 1) } })
	H.ok(#UI:BuildRequestRows("", nil)[1].crafters > 0, "request rows ignore the player filter too")
	UI.memberFilter = nil
	-- the same name first, then names beginning with it; the wheel reaches the rest
	local entries, names = {}, { "Major Pot", "Minor Pot", "Pot", "Pot Big", "Super Pot", "A Pot", "B Pot" }
	for i in ipairs(names) do entries[900000 + i] = { skillLine = 171, itemID = 0, guids = { ME } } end
	local realIndex, realName = ns.store.Index, C_Spell and C_Spell.GetSpellName
	local realRecipeName = ns.Scanner.RecipeName
	ns.store.Index = function() return { recipes = entries } end
	ns.Scanner.RecipeName = function(id) return names[id - 900000] or realRecipeName(id) end
	if realName then C_Spell.GetSpellName = function(id) return names[id - 900000] or realName(id) end end
	local found = UI:FindRequestRecipes("pot")
	H.eq(#found, 7)
	H.eq(found[1].name, "Pot"); H.eq(found[2].name, "Pot Big")
	box.search:SetText("pot")
	H.ok(box.searchLabel:GetText():find("1-5 / 7", 1, true), "caption says which are shown")
	-- typing waits a moment, Enter does not
	box.search._text = "pot big"
	box.search._scripts.OnTextChanged(box.search, true)
	H.eq(box.picks[1].data.name, "Pot", "not searched yet")
	M.advance(1)
	H.eq(box.picks[1].data.name, "Pot Big", "searched after the pause")
	box.search:SetText("pot")
	box.pick._scripts.OnMouseWheel(box.pick, -1)
	box.pick._scripts.OnMouseWheel(box.pick, -1)
	box.pick._scripts.OnMouseWheel(box.pick, -1)
	H.eq(box.picks[5].data.name, found[7].name, "the wheel reaches the last one")
	ns.store.Index, ns.Scanner.RecipeName = realIndex, realRecipeName
	if realName then C_Spell.GetSpellName = realName end
	-- opened from a recipe the search stays hidden
	H.eq(openRecipe(UI, 3865).recipeID, 3865)
	H.ok(not b:IsShown(), "not in the recipes view")
	UI.detail.requestButton._scripts.OnClick(UI.detail.requestButton)
	H.ok(box:IsShown() and not box.pick:IsShown(), "from a recipe: no search")
	H.ok(not box.saveButton.disabled)
end)

H.test("addon requests window: a guildmate's request is taken, then done", function()
	local ns = login()
	local UI = ns.UI
	UI:Toggle()
	local rec = anaRequest(ns, 3865, 4)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
	local row = openRequest(UI, rec.id)
	H.ok(row, "Ana's request is listed")
	local listRow
	for _, r in ipairs(UI.rows) do if rawget(r, "data") == row then listRow = r end end
	H.ok(listRow.name:GetText():find("4x", 1, true), "count in the list: " .. listRow.name:GetText())
	H.ok(listRow.sub:GetText():find("Ana Brightwood", 1, true), "requester in the list")
	local d = UI.detail
	H.eq(d.linkButton.text:GetText(), ns.T("BTN_REQ_TAKE"))
	local before = #M.sent
	d.linkButton._scripts.OnClick(d.linkButton)
	local held = ns.requests:Get(rec.id)
	H.eq(held.st, "taken"); H.eq(held.cr, ME)
	M.advance(3)
	H.eq(#sentOfType(ns, before, "TU"), 1)
	-- the selection stays, the buttons follow the state
	UI:Refresh()
	H.ok(UI.selected and UI.selected.request and UI.selected.request.id == rec.id, "still selected")
	H.eq(d.linkButton.text:GetText(), ns.T("BTN_REQ_DONE"))
	H.eq(d.shopButton.text:GetText(), ns.T("BTN_REQ_GIVEBACK"))
	d.linkButton._scripts.OnClick(d.linkButton)
	H.eq(ns.requests:Get(rec.id).st, "done")
	UI:Refresh()
	H.ok(UI.selected and UI.selected.request.id == rec.id, "still selected after done")
	H.ok(d.linkButton.disabled and d.shopButton.disabled, "nothing more to do")
end)

H.test("addon requests window: a change arriving while selected keeps the selection", function()
	local ns = login()
	local UI = ns.UI
	UI:Toggle()
	local rec = anaRequest(ns, 3865, 1)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
	openRequest(UI, rec.id)
	-- Bob takes it while we look at it
	local taken = {}
	for k, v in pairs(rec) do taken[k] = v end
	taken.st, taken.cr, taken.tk, taken.u, taken.ub = "taken", "Player-1-00000003", rec.u + 3, rec.u + 3, "Player-1-00000003"
	M.advance(4)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { taken } })
	M.advance(1)
	H.ok(UI.selected and UI.selected.request.id == rec.id, "still selected")
	H.eq(UI.selected.request.st, "taken", "the new state")
	-- Ana cancels it: a cancelled request leaves the list at once
	local cancel = {}
	for k, v in pairs(taken) do cancel[k] = v end
	cancel.st, cancel.u, cancel.ub = "cancelled", taken.u + 3, ANA
	M.advance(4)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { cancel } })
	M.advance(1)
	H.eq(UI.selected, nil, "gone from the list")
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		H.ok(not (d and d.request and d.request.id == rec.id), "not listed")
	end
end)


H.test("addon requests window: actions wait while sending is blocked (review 1, I4)", function()
	local ns = login()
	local UI = ns.UI
	UI:Toggle()
	local rec = anaRequest(ns, 3865, 1)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
	openRequest(UI, rec.id)
	IsInInstance = function() return true, "party" end
	UI.detail.linkButton._scripts.OnClick(UI.detail.linkButton)
	H.eq(ns.requests:Get(rec.id).st, "open", "not taken inside a dungeon")
	H.ok(chatHas(ns.T("REQ_BLOCKED", ns.T("REASON_INSTANCE"))), "told why")
	IsInInstance = function() return false, "none" end
	UI.detail.linkButton._scripts.OnClick(UI.detail.linkButton)
	H.eq(ns.requests:Get(rec.id).st, "taken")
end)


H.test("addon requests: a take that did not count is told (review 2, N2)", function()
	local ns = login()
	local rec = anaRequest(ns, 3865, 1)
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
	M.advance(3)
	ns.requests:Take(rec.id)
	-- Bob took it a second earlier
	local bob = {}
	for k, v in pairs(rec) do bob[k] = v end
	bob.st, bob.cr, bob.tk, bob.u, bob.ub = "taken", "Player-1-00000003", rec.c + 1, rec.c + 1, "Player-1-00000003"
	receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { bob } })
	H.eq(ns.requests:Get(rec.id).cr, "Player-1-00000003")
	H.ok(chatHas(ns.T("REQ_LOST_NOTICE", "Item 4305")), "told that our take did not count")
end)


H.test("addon requests: no lost-take notice when the requester finishes or cancels our take, or we give it back", function()
	local ns = login()
	local lost = ns.T("REQ_LOST_NOTICE", "Item 4305")
	local base = count(lost) -- the chat of earlier tests
	for k, change in ipairs({ "done", "cancelled", "giveback" }) do
		local rec = anaRequest(ns, 3865, 1)
		rec.id = ANA .. "-" .. rec.c .. "-" .. (10 + k)
		receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } })
		M.advance(2)
		ns.requests:Take(rec.id)
		M.advance(2)
		if change == "giveback" then
			ns.requests:GiveBack(rec.id)
		else
			local v = {}
			for key, val in pairs(ns.requests:Get(rec.id)) do v[key] = val end
			v.st, v.u, v.ub = change, v.u + 1, ANA
			receive(ns, { t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { v } })
		end
		H.eq(count(lost) - base, 0, "no notice after " .. change)
	end
end)

H.test("addon settings: a damaged list of collapsed groups is replaced", function()
	ProfguildDB = { settings = { collapsed = true } }
	local ns = loadAddon()
	M.fire("ADDON_LOADED", "Profguild")
	H.eq(type(ns.db.settings.collapsed), "table")
end)
