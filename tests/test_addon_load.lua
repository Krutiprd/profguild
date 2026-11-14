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

	-- UI: open, search, members view, member filter, whisper, language switch
	SlashCmdList.PROFGUILD("")
	H.ok(ns.UI.frame:IsShown(), "window shown")
	H.ok(#ns.UI.rows > 0, "rows drawn")
	ns.UI.search:SetText("recipe 17187")
	M.advance(1)
	H.eq(rawget(ns.UI.rows[1], "data").recipeID, 17187, "search finds the recipe")
	H.ok(not ns.UI.rows[2]:IsShown(), "only one result")
	ns.UI.search:SetText("brightwood")
	M.advance(1)
	H.eq(rawget(ns.UI.rows[1], "data").recipeID ~= nil, true, "search by crafter name")
	ns.UI.search:SetText("")
	ns.UI:SetView("members")
	local d1 = rawget(ns.UI.rows[1], "data")
	H.ok(d1 and d1.kind == "member", "members view")
	ns.UI.rows[1]._scripts.OnEnter(ns.UI.rows[1])
	ns.UI.search:SetText("")
	ns.UI:SetView("recipes")
	local row = ns.UI.rows[1]
	row._scripts.OnEnter(row)
	row._scripts.OnClick(row)
	H.ok(M.whispered, "whisper opened")

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

	H.eq(ns.lastError, nil, "no handler errors: " .. tostring(ns.lastError))
end)
