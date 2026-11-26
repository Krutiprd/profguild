-- The second addon prefix (ProfguildNPC): sending with done(ok), receiving into ns.npcSync,
-- the size limit, the shared sender block, and the mock's per-prefix throttle and loss.
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

local function login()
	ProfguildDB = nil
	local ns = loadAddon()
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	-- Comm.blocked is module state shared with nothing else, but start clean anyway
	ns.Comm.blocked = {}
	return ns
end

local function fakeNpcSync()
	local s = { got = {} }
	function s:OnMessage(msg, sender, size) s.got[#s.got + 1] = { msg = msg, sender = sender, size = size } end
	return s
end

-- A valid encoded text of exactly `target` bytes (noise does not compress).
local function textOfSize(ns, target)
	math.randomseed(7)
	for n = target, math.floor(target * 1.3) do
		local t = {}
		for i = 1, n do t[i] = string.char(math.random(33, 122)) end
		local text = ns.Comm.Encode({ t = "ND", pad = table.concat(t) })
		if #text == target then return text end
	end
	error("no text of " .. target .. " bytes")
end

H.test("NPC message goes out on ProfguildNPC only", function()
	local ns = login()
	local from = #M.sent
	ns.Comm.SendNpc({ t = "ND", x = 1 })
	M.advance(3)
	H.ok(#M.sent > from, "nothing sent")
	for i = from + 1, #M.sent do H.eq(M.sent[i].prefix, "ProfguildNPC", "prefix") end
	H.eq(ns.Comm.NPC_PREFIX, "ProfguildNPC")
	H.eq(ns.Comm.NPC_MAX_TEXT, 6144)
end)

H.test("received on ProfguildNPC reaches npcSync, with the game's sender name, and never sync", function()
	local ns = login()
	ns.npcSync = fakeNpcSync()
	local synced = 0
	ns.sync = { OnMessage = function() synced = synced + 1 end }
	local text = ns.Comm.Encode({ t = "ND", s = "Player-1-00000002" })
	ns.Comm:OnCommReceived("ProfguildNPC", text, "GUILD", "Ana-Winterborn")
	H.eq(#ns.npcSync.got, 1, "delivered")
	H.eq(ns.npcSync.got[1].sender, "Ana-Winterborn", "sender")
	H.eq(ns.npcSync.got[1].size, #text, "size")
	H.eq(ns.npcSync.got[1].msg.t, "ND", "msg")
	H.eq(synced, 0, "sync untouched")
end)

H.test("an error in npcSync is recorded by Bugs, not thrown", function()
	local ns = login()
	ns.npcSync = { OnMessage = function() error("npc boom") end }
	local got = {}
	local record = ns.Bugs.Record
	ns.Bugs.Record = function(msg, stack, ours) got[#got + 1] = msg return true end
	local ok, err = pcall(ns.Comm.OnCommReceived, ns.Comm, "ProfguildNPC", ns.Comm.Encode({ t = "ND" }), "GUILD", "Ana-Winterborn")
	ns.Bugs.Record = record
	H.ok(ok, tostring(err))
	H.eq(#got, 1, "recorded")
	H.ok(got[1]:find("npc boom", 1, true) ~= nil, got[1])
end)

H.test("an NPC message does not write guildDB.names", function()
	local ns = login()
	ns.npcSync = fakeNpcSync()
	ns.guildDB.names = {}
	ns.Comm:OnCommReceived("ProfguildNPC", ns.Comm.Encode({ t = "ND", s = "Player-1-00000002" }), "GUILD", "Ana-Winterborn")
	H.eq(next(ns.guildDB.names), nil, "names")
	H.eq(#ns.npcSync.got, 1)
end)

H.test("text of 6145 bytes is ignored, 6144 is decoded", function()
	local ns = login()
	ns.npcSync = fakeNpcSync()
	ns.Comm:OnCommReceived("ProfguildNPC", textOfSize(ns, 6145), "GUILD", "Ana")
	H.eq(#ns.npcSync.got, 0, "6145")
	ns.Comm:OnCommReceived("ProfguildNPC", textOfSize(ns, 6144), "GUILD", "Ana")
	H.eq(#ns.npcSync.got, 1, "6144")
	H.eq(ns.npcSync.got[1].size, 6144)
end)

H.test("a sender blocked on one prefix is blocked on both", function()
	local ns = login()
	ns.npcSync = fakeNpcSync()
	local huge = ns.Comm.Encode({ t = "X", pad = string.rep("a", 300000) })
	H.ok(#huge < ns.Comm.MAX_TEXT, "junk is small when packed")
	ns.Comm:OnCommReceived("Profguild", huge, "GUILD", "Evil")
	H.ok(ns.Comm.blocked.Evil, "blocked")
	ns.Comm:OnCommReceived("ProfguildNPC", ns.Comm.Encode({ t = "ND" }), "GUILD", "Evil")
	H.eq(#ns.npcSync.got, 0, "npc from blocked sender")
	-- and the other way round
	ns.Comm.blocked = {}
	ns.Comm:OnCommReceived("ProfguildNPC", huge, "GUILD", "Evil2")
	H.ok(ns.Comm.blocked.Evil2, "blocked via npc prefix")
	local synced = 0
	ns.sync = { OnMessage = function() synced = synced + 1 end }
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "H" }), "GUILD", "Evil2")
	H.eq(synced, 0, "old prefix from blocked sender")
end)

H.test("done(true) once after a 3-part message, done(false) once when a part fails", function()
	local ns = login()
	math.randomseed(3)
	local pad = {}
	for i = 1, 1000 do pad[i] = string.char(math.random(33, 122)) end
	local msg = { t = "ND", pad = table.concat(pad) }
	local calls = {}
	local from = #M.sent
	ns.Comm.SendNpc(msg, function(ok) calls[#calls + 1] = ok end)
	M.advance(5)
	H.ok(#M.sent - from >= 3, "message has parts: " .. (#M.sent - from))
	H.eq(#calls, 1, "called once")
	H.eq(calls[1], true, "ok")

	-- the second part fails with a general error
	local real = C_ChatInfo.SendAddonMessage
	local n = 0
	C_ChatInfo.SendAddonMessage = function(...)
		n = n + 1
		if n == 2 then return 9 end
		return real(...)
	end
	calls = {}
	ns.Comm.SendNpc(msg, function(ok) calls[#calls + 1] = ok end)
	M.advance(5)
	C_ChatInfo.SendAddonMessage = real
	H.eq(#calls, 1, "called once on failure")
	H.eq(calls[1], false, "failed")
end)

H.test("done(false) when the message cannot be encoded", function()
	local ns = login()
	local calls = {}
	ns.Comm.SendNpc({ f = function() end }, function(ok) calls[#calls + 1] = ok end)
	H.eq(#calls, 1)
	H.eq(calls[1], false)
end)

H.test("a message of type ND on the old prefix does not reach npcSync", function()
	local ns = login()
	ns.npcSync = fakeNpcSync()
	local synced = 0
	ns.sync = { OnMessage = function() synced = synced + 1 end }
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "ND" }), "GUILD", "Ana")
	H.eq(#ns.npcSync.got, 0)
	H.eq(synced, 1, "old dispatch as before")
end)

H.test("mock throttle: 10 parts per prefix, then 1 per second, else 3", function()
	loadAddon()
	M.throttle = true
	local send = C_ChatInfo.SendAddonMessage
	for i = 1, 10 do H.eq(send("A", "x", "GUILD"), 0, "part " .. i) end
	H.eq(send("A", "x", "GUILD"), 3, "11th")
	H.eq(send("B", "x", "GUILD"), 0, "other prefix has its own budget")
	M.time = M.time + 1
	H.eq(send("A", "x", "GUILD"), 0, "after 1 s")
	H.eq(send("A", "x", "GUILD"), 3, "again")
	M.throttle = false
end)

H.test("mock loss drops parts silently with a seeded random", function()
	loadAddon()
	M.loss = 0.5
	local seed = 42
	M.random = function() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
	local from = #M.sent
	for _ = 1, 200 do H.eq(C_ChatInfo.SendAddonMessage("A", "x", "GUILD"), 0) end
	local kept = #M.sent - from
	H.ok(kept > 60 and kept < 140, "kept " .. kept)
	M.loss, M.random = 0, math.random
end)

-- Task 7: the NPC tables wired into the addon -------------------------------------------

-- Logs in with ProfguildDB kept (keep) or new; setup() changes the mocked game before the events.
local function boot(setup, keep)
	if not keep then ProfguildDB = nil end
	local ns = loadAddon()
	_G.UnitFactionGroup = function() return "Alliance", "Alliance" end
	if setup then setup() end
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	ns.Comm.blocked = {}
	return ns
end

local function noGuild()
	_G.IsInGuild = function() return false end
	_G.GetGuildInfo = function() return nil end
end

-- Whole messages sent on prefix since index from (AceComm parts joined).
local function texts(from, prefix)
	local out, buf = {}, nil
	for i = from + 1, #M.sent do
		local p = M.sent[i]
		if p.prefix == prefix then
			local c, rest = p.text:match("^([\001-\009])(.*)$")
			if not c then out[#out + 1] = p.text
			elseif c == "\001" then buf = rest
			elseif c == "\002" then buf = (buf or "") .. rest
			elseif c == "\003" then out[#out + 1] = (buf or "") .. rest; buf = nil
			elseif c == "\004" then out[#out + 1] = rest end
		end
	end
	return out
end

local function sentNpc(ns, from, t)
	local list = {}
	for _, text in ipairs(texts(from, "ProfguildNPC")) do
		local msg = ns.Comm.Decode(text, ns.Comm.NPC_MAX_TEXT)
		if msg and (t == nil or msg.t == t) then list[#list + 1] = msg end
	end
	return list
end

local function trainerReading(copper)
	return { name = "Maria Lumere", map = 1453, x = 56, y = 64,
		t = { [3915] = { skill = 50, copper = copper or 500 } }, v = {} }
end

local function vendorReading(copper)
	return { name = "Jormund", map = 1455, x = 38, y = 30, t = {},
		v = { [4355] = { price = { c = copper or 1000, o = {}, l = 0 } } } }
end

-- An NU from a guildmate carrying the sheet of npcID read as reading.
local function receiveNU(ns, npcID, reading, sender, faction)
	local NpcData = ns.NpcData
	local today = math.floor(GetServerTime() / 86400)
	local s = NpcData.Visit(nil, reading, today)
	local msg = { t = "NU", pv = NpcData.PROTOCOL, e = NpcData.EPOCH, f = faction or "Alliance",
		s = "Player-1-00000002", h = 12345, x = { NpcData.Pack(npcID, s) } }
	ns.Comm:OnCommReceived("ProfguildNPC", ns.Comm.Encode(msg), "GUILD", sender or "Ana")
end

local function chatSince(from)
	local t = {}
	for i = from + 1, #M.chat do t[#t + 1] = M.chat[i] end
	return table.concat(t, "\n")
end

H.test("npc: a reading goes into npcOwn and the guild's table and sends one NU; the same again sends none", function()
	local ns = boot()
	H.ok(ns.npcOwn and ns.npc and ns.npcSync, "tables made at login")
	H.ok(ns.npc ~= ns.npcOwn, "the window shows the guild's table")
	local notices = 0
	local onData = ns.OnDataChanged
	ns.OnDataChanged = function() notices = notices + 1 return onData() end
	local from = #M.sent
	ns.npcReader.onReading(5001, trainerReading())
	M.advance(30)
	H.ok(ns.npcOwn:Get(5001), "npcOwn")
	H.ok(ns.npc:Get(5001), "guild's")
	H.eq(#sentNpc(ns, from, "NU"), 1, "one NU")
	H.ok(notices > 0, "the window is told")
	from = #M.sent
	ns.npcReader.onReading(5001, trainerReading())
	M.advance(30)
	H.eq(#sentNpc(ns, from, "NU"), 0, "same reading: no NU")
	local db = ProfguildDB
	H.ok(db.npcOwn.Alliance.s[5001], "npcOwn saved")
	H.eq(db.npcOwn.Alliance.e, ns.NpcData.EPOCH)
	H.ok(db.guilds[ns.guildKey].npc.Alliance.s[5001], "guild's saved")
end)

H.test("npc: npcOwn keeps the last reading, the guild's keeps the higher price the same day", function()
	local ns = boot()
	ns.npcReader.onReading(5002, vendorReading(1000))
	ns.npcReader.onReading(5002, vendorReading(600))
	H.eq(ns.npcOwn:Get(5002).v[4355][2].c, 600, "npcOwn: last reading")
	H.eq(ns.npc:Get(5002).v[4355][2].c, 1000, "guild's: own-visit rules")
	-- a reading without a place and of another item leaves the rest of npcOwn alone
	ns.npcReader.onReading(5002, { name = "Jormund", t = {}, v = { [4356] = { price = { c = 5, o = {}, l = 0 } } } })
	local s = ns.npcOwn:Get(5002)
	H.eq(s.map, 1455, "place stays")
	H.eq(s.v[4355][2].c, 600, "unread item stays")
	H.eq(s.v[4356][2].c, 5, "new item")
	-- trained copper too
	ns.npcReader.onReading(5001, trainerReading(500))
	ns.npcReader.onReading(5001, trainerReading(300))
	H.eq(ns.npcOwn:Get(5001).t[3915][4], 300)
	H.eq(ns.npc:Get(5001).t[3915][4], 500)
end)

H.test("npc: without a guild only npcOwn, nothing sent", function()
	local ns = boot(noGuild)
	H.ok(ns.npcOwn, "npcOwn made")
	H.eq(ns.npcSync, nil, "no sync")
	H.eq(ns.npc, ns.npcOwn, "the window shows npcOwn")
	local from = #M.sent
	ns.npcReader.onReading(5001, trainerReading())
	M.advance(60)
	H.ok(ns.npcOwn:Get(5001))
	H.eq(#sentNpc(ns, from), 0, "nothing on ProfguildNPC")
end)

H.test("npc: guild change stops the sync, npcOwn goes into the new guild, guild A's data stays in A", function()
	local ns = boot()
	local keyA, syncA = ns.guildKey, ns.npcSync
	receiveNU(ns, 7001, vendorReading(2000))
	H.ok(ns.npc:Get(7001), "received in A")
	ns.npcReader.onReading(5001, trainerReading())
	_G.GetGuildInfo = function() return "Red Dawn", "Member", 3, nil end
	M.fire("PLAYER_GUILD_UPDATE", "player")
	M.advance(3)
	H.ok(ns.guildKey ~= keyA, "guild changed")
	H.ok(syncA.dead, "old sync stopped")
	H.ok(ns.npcSync and ns.npcSync ~= syncA, "new sync")
	H.eq(ns.npc:Get(7001), nil, "nothing from A in B")
	H.ok(ns.npc:Get(5001), "npcOwn imported into B")
	H.ok(ProfguildDB.guilds[keyA].npc.Alliance.s[7001], "A keeps its own")
	H.eq(ProfguildDB.guilds[ns.guildKey].npc.Alliance.s[7001], nil)
	-- leaving the guild: the window shows npcOwn
	noGuild()
	M.fire("PLAYER_GUILD_UPDATE", "player")
	M.advance(3)
	H.eq(ns.npcSync, nil)
	H.eq(ns.npc, ns.npcOwn)
	H.eq(ns.npc:Get(7001), nil)
end)

H.test("npc: the other faction has separate tables", function()
	local ns = boot()
	ns.npcReader.onReading(5001, trainerReading())
	receiveNU(ns, 7001, vendorReading(2000))
	ns = boot(function() _G.UnitFactionGroup = function() return "Horde", "Horde" end end, true)
	H.eq(ns.npcFaction, "Horde")
	H.eq(ns.npcOwn:Get(5001), nil, "npcOwn of Horde")
	H.eq(ns.npc:Get(5001), nil, "guild's of Horde")
	H.eq(ns.npc:Get(7001), nil)
	-- an Alliance message is ignored by the Horde character
	receiveNU(ns, 7002, vendorReading(2000), "Ana", "Alliance")
	H.eq(ns.npc:Get(7002), nil, "other faction's message")
	H.ok(ProfguildDB.npcOwn.Alliance.s[5001], "Alliance npcOwn kept")
	H.ok(ProfguildDB.guilds[ns.guildKey].npc.Alliance.s[7001], "Alliance guild's kept")
end)

H.test("npc: faction unknown at login, with and without a guild: no error, tables made later", function()
	local faction = nil
	local ns = boot(function() _G.UnitFactionGroup = function() return faction, faction end end)
	H.eq(ns.npcOwn, nil)
	H.eq(ns.npcSync, nil)
	SlashCmdList.PROFGUILD("npc")
	SlashCmdList.PROFGUILD("status")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	faction = "Alliance"
	M.fire("GUILD_ROSTER_UPDATE")
	M.advance(3)
	H.ok(ns.npcOwn and ns.npcSync, "made at a guild event")
	H.eq(ns.npc, ns.npcGuild)

	faction = nil
	ns = boot(function()
		noGuild()
		_G.UnitFactionGroup = function() return faction, faction end
	end)
	H.eq(ns.npcOwn, nil)
	ns.npcReader.onReading(5001, trainerReading())
	H.eq(ns.npcOwn, nil, "still unknown")
	faction = "Horde"
	ns.npcReader.onReading(5001, trainerReading())
	H.ok(ns.npcOwn and ns.npcOwn:Get(5001), "made at a reading")
	H.eq(ns.npc, ns.npcOwn)
end)

H.test("npc: Hello announces also while sending is blocked; the ND goes out after the block", function()
	local ns = boot()
	M.advance(120)
	local calls = 0
	local announce = ns.npcSync.Announce
	ns.npcSync.Announce = function(self) calls = calls + 1 return announce(self) end
	_G.InCombatLockdown = function() return true end
	local from = #M.sent
	H.ok(ns.Hello(true), "hello")
	H.eq(calls, 1, "announced while blocked")
	M.advance(20)
	H.eq(#sentNpc(ns, from, "ND"), 0, "nothing while blocked")
	_G.InCombatLockdown = function() return false end
	M.advance(60)
	H.ok(#sentNpc(ns, from, "ND") >= 1, "ND after the block")
end)

H.test("npc: saved tables survive a reload; broken saved data loads without an error", function()
	local ns = boot()
	ns.npcReader.onReading(5001, trainerReading())
	receiveNU(ns, 7001, vendorReading(2000))
	ns = boot(nil, true)
	H.ok(ns.npcOwn:Get(5001), "npcOwn")
	H.ok(ns.npc:Get(5001), "guild's own reading")
	H.ok(ns.npc:Get(7001), "guild's received")
	local good = ProfguildDB.npcOwn.Alliance.s[5001]
	ProfguildDB.npcOwn.Alliance.s[5001] = { "junk" }
	ProfguildDB.npcOwn.Alliance.s[6001] = "junk"
	ProfguildDB.guilds[ns.guildKey].npc.Alliance = "junk"
	ns = boot(nil, true)
	H.eq(ns.npcOwn:Get(5001), nil, "broken sheet dropped")
	H.eq(ProfguildDB.npcOwn.Alliance.s[6001], nil)
	H.ok(ns.npc, "guild's table")
	H.eq(ns.npc:Get(7001), nil, "nothing from the broken save")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	ProfguildDB.npcOwn = "junk"
	ns = boot(nil, true)
	H.ok(ns.npcOwn, "npcOwn made again")
	H.eq(ns.npcOwn:Count(), 0)
	ProfguildDB.npcOwn = { Alliance = { e = ns.NpcData.EPOCH + 1, s = { [5001] = good } } }
	ns = boot(nil, true)
	H.eq(ns.npcOwn:Count(), 0, "another epoch dropped")
end)

H.test("npc: /pg npc prints counts, /pg status a line, /pg npc clear empties both tables of the faction", function()
	local ns = boot()
	ns.npcReader.onReading(5001, trainerReading())
	receiveNU(ns, 7001, vendorReading(2000))
	ns.npcReader.skipped = 4
	local from = #M.chat
	SlashCmdList.PROFGUILD("npc")
	local text = chatSince(from)
	H.ok(text:find(ns.T("NPC_COUNTS_GUILD", "Alliance", 2, 2, 1, 1, 4), 1, true), text)
	from = #M.chat
	SlashCmdList.PROFGUILD("status")
	text = chatSince(from)
	H.ok(text:find(ns.T("STATUS_NPC", 2, 2, 0, 0, 0, 0, 0, 0, 0, 1), 1, true), text)
	-- the other faction's tables are not touched
	ProfguildDB.npcOwn.Horde = { e = 1, s = { [1] = "x" } }
	from = #M.chat
	SlashCmdList.PROFGUILD("npc clear")
	H.ok(chatSince(from):find(ns.T("NPC_CLEARED", "Alliance"), 1, true), chatSince(from))
	H.eq(ns.npcOwn:Count(), 0, "npcOwn")
	H.eq(ns.npc:Count(), 0, "guild's")
	H.eq(next(ProfguildDB.npcOwn.Alliance.s), nil, "npcOwn saved")
	H.eq(next(ProfguildDB.guilds[ns.guildKey].npc.Alliance.s), nil, "guild's saved")
	H.ok(ProfguildDB.npcOwn.Horde.s[1], "Horde untouched")
	-- without a guild
	ns = boot(noGuild)
	ns.npcReader.onReading(5001, trainerReading())
	from = #M.chat
	SlashCmdList.PROFGUILD("npc")
	H.ok(chatSince(from):find(ns.T("NPC_COUNTS_OWN", "Alliance", 1, 1, 0), 1, true), chatSince(from))
	SlashCmdList.PROFGUILD("npc clear")
	H.eq(ns.npcOwn:Count(), 0)
	from = #M.chat
	SlashCmdList.PROFGUILD("npc what")
	H.ok(chatSince(from):find(ns.T("NPC_USAGE"), 1, true), chatSince(from))
end)

-- 0.6.0 beside us --------------------------------------------------------------------------

-- A file of the 0.6.0 tag, read with git; nil when git or the tag is not there.
local function gitShow(path)
	local null = package.config:sub(1, 1) == "\\" and "NUL" or "/dev/null"
	local p = io.popen(string.format('git -C "%s" show "0.6.0:%s" 2>%s', H.root, path, null), "r")
	if not p then return nil end
	local text = p:read("*a")
	p:close()
	if not text or text == "" then return nil end
	return text
end

-- Loads 0.6.0 as another character (Ana) in the same mocked game: its own globals (saved data,
-- slash commands), the libraries shared as in the game.
local function load060()
	local toc = gitShow("Profguild/Profguild.toc")
	if not toc then return nil end
	local env = setmetatable({
		ProfguildDB = false, SlashCmdList = {},
		UnitGUID = function() return "Player-1-00000002" end,
		UnitName = function() return "Ana" end,
		UnitFullName = function() return "Ana", "Winterborn" end,
	}, { __index = _G })
	local ns = {}
	for line in toc:gmatch("[^\r\n]+") do
		if not line:match("^##") and line:match("%.lua%s*$") then
			local file = line:gsub("\\", "/"):gsub("%s+$", "")
			local chunk = assert(loadstring(assert(gitShow("Profguild/" .. file), file), "@0.6.0/" .. file))
			if not file:match("^Libs/") then setfenv(chunk, env) end
			chunk("Profguild", ns)
		end
	end
	return ns, env
end

-- Hands the whole messages sent since from to each instance that registered their prefix, as the
-- game and AceComm do.
local function deliver(from, sender, instances)
	local AceComm = LibStub("AceComm-3.0")
	for _, prefix in ipairs({ "Profguild", "ProfguildNPC" }) do
		local listeners = AceComm.callbacks.events[prefix] or {}
		for _, text in ipairs(texts(from, prefix)) do
			for _, inst in ipairs(instances) do
				if listeners[inst.Comm] then inst.Comm:OnCommReceived(prefix, text, "GUILD", sender) end
			end
		end
	end
end

H.test("npc: a 0.6.0 client in the same guild receives nothing on ProfguildNPC and no new message on Profguild", function()
	ProfguildDB = nil
	local ns = loadAddon()
	_G.UnitFactionGroup = function() return "Alliance", "Alliance" end
	M.fire("ADDON_LOADED", "Profguild")
	local old, env = load060()
	H.ok(old, "0.6.0 files from git (git and the tag 0.6.0 are needed)")
	M.fire("ADDON_LOADED", "Profguild")
	H.ok(old.db and old.db ~= ns.db, "0.6.0 has its own saved data")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	ns.Comm.blocked, old.Comm.blocked = {}, {}
	local got = { Profguild = 0, ProfguildNPC = 0 }
	local receive = old.Comm.OnCommReceived
	old.Comm.OnCommReceived = function(self, prefix, ...)
		got[prefix] = (got[prefix] or 0) + 1
		return receive(self, prefix, ...)
	end
	local errors = {}
	local record = old.Bugs.Record
	old.Bugs.Record = function(msg, ...) errors[#errors + 1] = tostring(msg) return record(msg, ...) end
	local from = #M.sent
	ns.npcReader.onReading(5001, trainerReading())
	ns.npcReader.onReading(5002, vendorReading())
	M.advance(60)
	ns.Hello(true)
	M.advance(60)
	H.ok(#sentNpc(ns, from) > 0, "we sent on ProfguildNPC")
	-- the game hands parts only to prefixes the receiver registered: 0.6.0 has only Profguild
	deliver(from, "Frost", { old })
	H.eq(got.ProfguildNPC, 0, "0.6.0 received nothing on ProfguildNPC")
	H.ok(got.Profguild > 0, "0.6.0 received our Profguild messages")
	-- our Profguild messages are of the types 0.6.0 knows
	local known = {}
	for t in ("H R D Q C KD KR KL PU PD PR TU TD TR BU BD BR"):gmatch("%S+") do known[t] = true end
	for _, text in ipairs(texts(from, "Profguild")) do
		local msg = old.Comm.Decode(text)
		H.ok(msg and known[msg.t], "type " .. tostring(msg and msg.t))
	end
	H.eq(#errors, 0, table.concat(errors, "\n"))
	H.eq(old.lastError, nil, tostring(old.lastError))
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	-- and 0.6.0's messages reach us without an error
	from = #M.sent
	old.Hello(true)
	M.advance(30)
	deliver(from, "Ana", { ns })
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	H.ok(env.SlashCmdList.PROFGUILD ~= SlashCmdList.PROFGUILD, "own slash commands")
end)
