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
