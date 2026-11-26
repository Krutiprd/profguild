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

-- Task 9: FIND RECIPE in the detail pane ---------------------------------------------------

local RECIPE, ITEM = 3865, 7777 -- Tailoring, known after TRADE_SKILL_SHOW (makes 4305); its recipe item
local ANA = "Player-1-00000002"

local function placeOf(map, x, y) return map and { map = map, x = x, y = y } or {} end

local function vendorOf(name, copper, extra, place)
	local p = { c = copper or 0, o = {}, l = 0 }
	for k, v in pairs(extra or {}) do p[k] = v end
	local r = { name = name, t = {}, v = { [ITEM] = { price = p } } }
	for k, v in pairs(place or placeOf(1453, 56, 64)) do r[k] = v end
	return r
end

local function trainerOf(name, recipe, skill, copper, place)
	local r = { name = name, t = { [recipe] = { skill = skill, copper = copper } }, v = {} }
	for k, v in pairs(place or placeOf(1453, 43, 74)) do r[k] = v end
	return r
end

local function clickRecipe(UI, id)
	for _, r in ipairs(UI.rows) do
		local d = rawget(r, "data")
		if d and d.recipeID == id and not d.request then r._scripts.OnClick(r, "LeftButton") return d end
	end
end

local function cleanGame()
	_G.C_Map, _G.UiMapPoint, _G.TomTom, _G.Auctionator, _G.C_CurrencyInfo = nil, nil, nil, nil, nil
end

-- Logged in, Tailoring scanned, the window open on RECIPE.
local function findWindow(setup)
	cleanGame()
	local ns = boot(setup)
	M.fire("TRADE_SKILL_SHOW")
	M.advance(5)
	ns.RecipeData[RECIPE] = { ITEM, "v", 0, 60, 80 }
	ns.RecipeData[18560] = { false, "", 0, 30, 50 }
	_G.C_Map = { GetMapInfo = function(id) return ({ [1453] = { name = "Stormwind" }, [1455] = { name = "Ironforge" } })[id] end }
	local UI = ns.UI
	UI:Toggle()
	UI:SetView("recipes")
	UI:SetCategory(197)
	H.ok(clickRecipe(UI, RECIPE), "recipe listed")
	return ns, UI, UI.detail
end

local function plain(text) return ((text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local function rowTexts(row)
	return plain(row.name:GetText()), plain(row.detail:GetText()), plain(row.price:GetText())
end

local function shownRows(d)
	local n = 0
	for _, r in ipairs(d.findRows) do if r:IsShown() then n = n + 1 end end
	return n
end

-- the five sources of RECIPE: ah, trainer, two vendors with copper, one with another cost
local function fiveSources(ns)
	_G.Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function(_, id) if id == ITEM then return 8000 end end,
		GetAuctionAgeByItemID = function() return 1 end,
		GetVendorPriceByItemID = function() end,
	} } }
	local realInfo = C_Item.GetItemInfo
	C_Item.GetItemInfo = function(id)
		if id == 8888 then return "Merchant's Favor" end
		return realInfo(id)
	end
	receiveNU(ns, 6001, trainerOf("Georgio Bolero", RECIPE, 50, 4000))
	receiveNU(ns, 6002, vendorOf("Maria Lumere", 9500, { l = 1 }))
	receiveNU(ns, 6003, vendorOf("Jormund", 10000, nil, placeOf(nil)))
	receiveNU(ns, 6004, vendorOf("Favor Keeper", 0, { o = { { 2, 8888, 5 } } }))
	M.advance(1)
end

H.test("find: opens in place of reagents and cost, crafters stay; again, back, another recipe, another view close it", function()
	local ns, UI, d = findWindow()
	H.ok(d.findButton:IsShown(), "button shown")
	H.eq(d.findButton.text:GetText(), ns.T("BTN_FIND"))
	H.ok(d.reagentBody:IsShown() and not d.findBody:IsShown(), "reagents first")
	d.findButton._scripts.OnClick(d.findButton)
	H.ok(UI.findOpen, "open")
	H.ok(not d.reagentBody:IsShown(), "reagents and cost hidden")
	H.ok(d.findBody:IsShown(), "the list shown")
	H.eq(d.backButton.text:GetText(), ns.T("BTN_BACK_REAGENTS"))
	H.ok(d.findButton.active, "pressed")
	H.ok(d.recipeBody:IsShown(), "crafters stay")
	H.eq(#d.crafterRows, 4, "4 crafter rows")
	UI:ToggleFind()
	H.ok(not UI.findOpen and d.reagentBody:IsShown() and not d.findBody:IsShown(), "pressed again: closed")
	UI:ToggleFind()
	d.backButton._scripts.OnClick(d.backButton)
	H.ok(not UI.findOpen and d.reagentBody:IsShown(), "back to reagents")
	UI:ToggleFind()
	H.ok(clickRecipe(UI, 18560), "another recipe listed")
	H.ok(not UI.findOpen and d.reagentBody:IsShown() and not d.findBody:IsShown(), "another recipe: closed")
	clickRecipe(UI, RECIPE)
	H.ok(not UI.findOpen, "the first one again: still closed")
	UI:ToggleFind()
	UI:SetView("leveling")
	H.ok(not UI.findOpen, "another view: closed")
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	cleanGame()
end)

H.test("find: rows of every kind, ~, limited stock, other costs, zone only with a place, green frame, 3 visible", function()
	local ns, UI, d = findWindow()
	fiveSources(ns)
	UI:ToggleFind()
	H.eq(shownRows(d), 3, "3 visible")
	local name, detail, price = rowTexts(d.findRows[1])
	H.eq(name, ns.T("FIND_AH"))
	H.ok(detail:find(ns.T("DAYS_AGO", 1), 1, true), "AH age: " .. detail)
	H.eq(price, plain(ns.Prices.Format(8000)))
	H.ok(not d.findRows[1].mapButton:IsShown(), "no map for the AH")
	name, detail, price = rowTexts(d.findRows[2])
	H.eq(name, ns.T("FIND_TRAINER", "Georgio Bolero"))
	H.eq(detail, "Stormwind 43,74")
	H.eq(price, "~" .. plain(ns.Prices.Format(4000)), "the guild's price has ~")
	H.ok(d.findRows[2].bestFrame:IsShown(), "green frame on the cheapest")
	H.ok(not d.findRows[1].bestFrame:IsShown() and not d.findRows[3].bestFrame:IsShown(), "only there")
	name, detail, price = rowTexts(d.findRows[3])
	H.eq(name, ns.T("FIND_VENDOR", "Maria Lumere"))
	H.eq(detail, ns.T("FIND_LIMITED") .. ", Stormwind 56,64", "costs and stock before the place")
	H.eq(price, "~" .. plain(ns.Prices.Format(9500)))
	H.eq(d.findCount:GetText(), "1-3 / 5")
	-- the wheel over the list reaches the last row and no further
	local row = d.findRows[1]
	for _ = 1, 4 do row._scripts.OnMouseWheel(row, -1) end
	H.eq(UI.findOffset, 2, "clamped at the last")
	name, detail, price = rowTexts(d.findRows[2])
	H.eq(name, ns.T("FIND_VENDOR", "Jormund"))
	H.eq(detail, "", "no place: no zone")
	name, detail, price = rowTexts(d.findRows[3])
	H.eq(name, ns.T("FIND_VENDOR", "Favor Keeper"))
	H.ok(detail:find("5 Merchant's Favor", 1, true), "other cost: " .. detail)
	H.eq(price, "", "no copper price")
	H.ok(not d.findRows[2].mapButton:IsShown(), "no place: no map button")
	-- the wheel over the crafters scrolls them, not the list
	local scrolled
	local real = UI.ScrollDetail
	UI.ScrollDetail = function(_, delta) scrolled = delta end
	d.crafterRows[1]._scripts.OnMouseWheel(d.crafterRows[1], -1)
	UI.ScrollDetail = real
	H.eq(scrolled, -1, "crafters")
	H.eq(UI.findOffset, 2, "list untouched")
	-- an own reading of the last 30 days has no ~
	ns.npcReader.onReading(6003, vendorOf("Jormund", 10000, nil, placeOf(nil)))
	M.advance(1)
	name, detail, price = rowTexts(d.findRows[2])
	H.eq(price, plain(ns.Prices.Format(10000)), "own: no ~")
	-- hover: the recipe item's tooltip, the zone, how old, what ~ means
	M.tooltipLines = {}
	local itemShown
	local realSet = GameTooltip.SetItemByID
	GameTooltip.SetItemByID = function(_, id) itemShown = id end
	UI.findOffset = 0
	UI:Refresh()
	d.findRows[3]._scripts.OnEnter(d.findRows[3])
	GameTooltip.SetItemByID = realSet
	local tip = table.concat(M.tooltipLines, "\n")
	H.eq(itemShown, ITEM, "the recipe item's tooltip for a vendor")
	H.ok(tip:find("Stormwind", 1, true) and tip:find(ns.T("FIND_SEEN_TODAY"), 1, true) and tip:find(ns.T("FIND_APPROX"), 1, true), tip)
	H.ok(tip:find(ns.T("FIND_LIMITED"), 1, true), "limited stock in the tooltip: " .. tip)
	-- scrolled under the mouse: the tooltip follows the row (Jormund, then Favor Keeper's other cost)
	M.tooltipLines = {}
	d.findRows[3]._scripts.OnMouseWheel(d.findRows[3], -1)
	tip = table.concat(M.tooltipLines, "\n")
	H.ok(tip:find("Jormund", 1, true) and not tip:find("Maria", 1, true), "redrawn after a scroll: " .. tip)
	M.tooltipLines = {}
	d.findRows[3]._scripts.OnMouseWheel(d.findRows[3], -1)
	tip = table.concat(M.tooltipLines, "\n")
	H.ok(tip:find("Favor Keeper", 1, true) and tip:find("5 Merchant's Favor", 1, true), "other cost in the tooltip: " .. tip)
	H.ok(not tip:find(ns.T("FIND_APPROX"), 1, true), "no ~ note without copper: " .. tip)
	-- one day: singular
	M.tooltipLines = {}
	d.findRows[3].data.age = 1
	d.findRows[3]._scripts.OnEnter(d.findRows[3])
	tip = table.concat(M.tooltipLines, "\n")
	H.ok(tip:find(ns.T("FIND_SEEN_ONE"), 1, true) and not tip:find(ns.T("FIND_SEEN", 1), 1, true), "one day: " .. tip)
	d.findRows[3]._scripts.OnLeave(d.findRows[3])
	UI.findOffset = 0
	UI:Refresh()
	-- other kinds: drop and quest, no vendor seen, no trainer seen, nothing known
	ns.RecipeData[RECIPE] = { ITEM, "vdq", 0, 60, 80 }
	SlashCmdList.PROFGUILD("npc clear")
	UI:Refresh()
	local texts = {}
	for i = 1, shownRows(d) do texts[i] = (rowTexts(d.findRows[i])) end
	H.eq(texts[2], ns.T("FIND_NO_VENDOR"))
	H.eq(texts[3], ns.T("FIND_OTHER", ns.T("SRC_DROP") .. ", " .. ns.T("SRC_QUEST")))
	H.eq(select(2, rowTexts(d.findRows[3])), ns.T("FIND_NO_PLACE"))
	ns.RecipeData[RECIPE] = { false, "", 0, 60, 80 }
	UI:Refresh()
	H.eq((rowTexts(d.findRows[1])), ns.T("FIND_NO_TRAINER"))
	ns.RecipeData[RECIPE] = nil
	UI:Refresh()
	H.eq((rowTexts(d.findRows[1])), ns.T("FIND_UNKNOWN"))
	_G.Auctionator = nil
	UI:Refresh()
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	cleanGame()
end)

H.test("find: a guild sheet arriving while open adds its row and keeps the offset; a shrinking list clamps it", function()
	local ns, UI, d = findWindow()
	fiveSources(ns)
	UI:ToggleFind()
	UI:ScrollFind(-1)
	H.eq(UI.findOffset, 1)
	receiveNU(ns, 6005, vendorOf("Late Vendor", 20000))
	M.advance(1)
	H.ok(UI.findOpen, "still open")
	H.eq(UI.findOffset, 1, "offset kept")
	H.eq(d.findCount:GetText(), "2-4 / 6", "the row added")
	UI:ScrollFind(-5)
	H.eq(UI.findOffset, 3)
	SlashCmdList.PROFGUILD("npc clear")
	M.advance(1)
	H.eq(d.findCount:GetText(), "2", "ah and no vendor")
	H.eq(UI.findOffset, 0, "clamped")
	cleanGame()
end)

H.test("find: map pin by the client, else TomTom, else no button; errors stay inside", function()
	local ns, UI, d = findWindow()
	fiveSources(ns)
	local set, tt
	C_Map.CanSetUserWaypointOnMap = function(m) return m == 1453 end
	C_Map.SetUserWaypoint = function(p) set = p end
	_G.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
	UI:ToggleFind()
	local b = d.findRows[2].mapButton
	H.ok(b:IsShown(), "map button")
	H.eq(b.text:GetText(), ns.T("BTN_MAP"))
	local chat0 = #M.chat
	b._scripts.OnClick(b)
	H.ok(chatSince(chat0):find(ns.T("MAP_PIN_SET", "Georgio Bolero"), 1, true), "one chat line: " .. chatSince(chat0))
	H.ok(set and set.m == 1453 and set.x == 43 / 100 and set.y == 74 / 100, "client waypoint")
	-- refused by the client, TomTom there
	_G.TomTom = { AddWaypoint = function(self, m, x, y, opts) tt = { self = self, m = m, x = x, y = y, title = opts and opts.title } end }
	set = nil
	H.ok(UI.CanMapPin(1455), "TomTom can")
	H.ok(UI.SetMapPin(1455, 38, 30, "Jormund"), "pinned")
	H.eq(set, nil, "not the client's")
	H.ok(tt.self == TomTom and tt.m == 1455 and tt.x == 38 / 100 and tt.y == 30 / 100 and tt.title == "Jormund", "TomTom")
	-- the client's API missing, TomTom there
	C_Map.SetUserWaypoint = nil
	tt = nil
	H.ok(UI.SetMapPin(1453, 43, 74, "Georgio Bolero") and tt and tt.m == 1453, "TomTom without the API")
	-- neither
	_G.TomTom = nil
	H.ok(not UI.CanMapPin(1453), "nothing can")
	UI:Refresh()
	H.ok(not d.findRows[2].mapButton:IsShown(), "button hidden")
	-- an error in the API does not escape
	C_Map.CanSetUserWaypointOnMap = function() error("boom") end
	C_Map.SetUserWaypoint = function() error("boom") end
	local ok, r = pcall(UI.SetMapPin, 1453, 43, 74, "x")
	H.ok(ok and not r, "no error, not pinned")
	H.ok(not UI.CanMapPin(1453))
	C_Map.CanSetUserWaypointOnMap = function() return true end
	ok, r = pcall(UI.SetMapPin, 1453, 43, 74, "x")
	H.ok(ok and not r, "SetUserWaypoint failing: not pinned")
	_G.TomTom = { AddWaypoint = function() error("boom") end }
	ok, r = pcall(UI.SetMapPin, 1455, 1, 1, "x")
	H.ok(ok and not r, "TomTom failing")
	chat0 = #M.chat
	b._scripts.OnClick(b)
	H.ok(chatSince(chat0):find(ns.T("MAP_PIN_FAILED"), 1, true), "a failed pin is said: " .. chatSince(chat0))
	UI:Refresh()
	H.eq(ns.lastError, nil, tostring(ns.lastError))
	cleanGame()
end)

H.test("find: requests and members have no FIND RECIPE; requests have the numbers at the same place", function()
	local ns, UI, d = findWindow()
	ProfguildDB.recipeInfo[RECIPE] = { m = 50, g = 90 }
	UI:Refresh()
	local numbers = d.skillNumbers:GetText()
	H.eq(plain(numbers), "50 60 75 90")
	local clock = GetServerTime()
	local rec = { id = ANA .. "-" .. clock .. "-1", by = ANA, r = RECIPE, i = 4305, n = 2, note = "pls",
		c = clock, st = "open", u = clock, ub = ANA }
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode({ t = "TU", pv = ns.Requests.PROTOCOL, s = ANA, q = { rec } }),
		"GUILD", "Ana Brightwood")
	UI:SetView("requests")
	local found
	for _, r in ipairs(UI.rows) do
		local data = rawget(r, "data")
		if data and data.request then r._scripts.OnClick(r, "LeftButton") found = true break end
	end
	H.ok(found and UI.selected.request, "request selected")
	H.ok(not d.findButton:IsShown(), "no FIND RECIPE on a request")
	UI:ToggleFind()
	H.ok(not UI.findOpen and not d.findBody:IsShown(), "no list on a request")
	H.ok(d.recipeBody:IsShown())
	H.eq(d.skillNumbers:GetText(), numbers, "the numbers at the same place")
	UI:SetView("members")
	UI.rows[1]._scripts.OnClick(UI.rows[1], "LeftButton")
	H.eq(UI.selected.kind, "member")
	H.ok(not d.findButton:IsShown(), "no FIND RECIPE on a member")
	H.ok(not d.recipeBody:IsShown(), "no numbers on a member")
	H.eq(d.sub._width, 250, "full width")
	cleanGame()
end)

H.test("find: the numbers at the right end of the profession line, never written into it by a price refresh", function()
	local ns, UI, d = findWindow()
	ProfguildDB.recipeInfo[RECIPE] = { m = 50, g = 90 }
	local realInfo = C_Item.GetItemInfo
	C_Item.GetItemInfo = function(id)
		if id == 4305 then return "Item 4305", "link", 1, 60, 55 end
		return realInfo(id)
	end
	UI:Refresh()
	H.eq(plain(d.skillNumbers:GetText()), "50 60 75 90")
	H.ok(d.skillNumbers:GetText():find("|cffff2020" .. "50", 1, true), "learn in red")
	H.eq(d.sub:GetText(), "Tailoring  |cff9a9ea3" .. ns.T("REQ_LEVEL_SHORT", 55) .. "|r")
	H.eq(d.sub._width, 250 - d.skillNumbers:GetStringWidth() - 8, "the line ends before the numbers")
	d.sub:SetText("X")
	UI:DrawReagents(UI.selected)
	H.eq(d.sub:GetText(), "X", "a price refresh leaves the line alone")
	UI:Refresh()
	H.ok(not plain(d.value:GetText()):find("90", 1, true), "no numbers on the value line")
	-- Leveling: learn and grey with the same fallbacks, also for the order
	ProfguildDB.recipeInfo[RECIPE], ProfguildDB.recipeInfo[18560] = nil, nil
	UI:SetView("leveling")
	local function order()
		local pos = {}
		for i, row in ipairs(UI.listCache.data) do pos[row.recipeID] = i end
		return pos[18560] < pos[RECIPE] and "18560 first" or "3865 first"
	end
	H.eq(order(), "18560 first", "Data.lua's grey 50 before 80")
	ProfguildDB.recipeInfo[18560] = { g = 95 }
	ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
	UI:Refresh()
	H.eq(order(), "3865 first", "info.g 95 after Data.lua's 80")
	ProfguildDB.recipeInfo[18560] = { g = 80, m = 40 }
	ns.recipeInfoRevision = ns.recipeInfoRevision + 1
	UI:Refresh()
	H.eq(order(), "18560 first", "same grey: learn 40 from info.m, the other unknown")
	receiveNU(ns, 6101, trainerOf("Georgio Bolero", RECIPE, 30, 100))
	M.advance(1)
	H.eq(order(), "3865 first", "the trainer's learn 30 before 40, rebuilt by the sheet")
	local sub
	for _, r in ipairs(UI.rows) do
		local data = rawget(r, "data")
		if data and data.recipeID == RECIPE then sub = r.sub:GetText() end
	end
	H.ok(sub and sub:find("|cffff2020" .. "30|r", 1, true) and sub:find("80|r", 1, true), "learn and grey in the row: " .. tostring(sub))
	cleanGame()
end)

H.test("find: a sheet that changes a learn skill rebuilds the list, 20 that change none do not", function()
	local ns, UI = findWindow()
	local left = 3600 - GetServerTime() % 3600
	if left < 120 then M.advance(left + 1) end -- the list key holds the hour
	UI:SetView("leveling")
	local cache = UI.listCache
	receiveNU(ns, 6201, trainerOf("Georgio Bolero", RECIPE, 30, 100))
	M.advance(1)
	H.ok(UI.listCache ~= cache, "rebuilt")
	cache = UI.listCache
	local revision = ns.npcSkillRevision
	for i = 1, 20 do receiveNU(ns, 6300 + i, vendorOf("Vendor " .. i, 100 + i)) end
	M.advance(1)
	H.eq(ns.npcSkillRevision, revision, "no learn skill changed")
	H.ok(UI.listCache == cache, "not rebuilt")
	-- the same trainer, only its price: no rebuild
	receiveNU(ns, 6201, trainerOf("Georgio Bolero", RECIPE, 30, 50))
	M.advance(1)
	H.ok(UI.listCache == cache, "a price is no learn skill")
	cleanGame()
end)

H.test("find: the name gives way to the price and the Map button; another cost's name follows its item", function()
	local ns, UI, d = findWindow()
	C_Map.CanSetUserWaypointOnMap = function() return true end
	C_Map.SetUserWaypoint = function() end
	_G.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m, x, y } end }
	local realInfo = C_Item.GetItemInfo
	local loaded = false
	C_Item.GetItemInfo = function(id)
		if id == 8889 then if loaded then return "Arcane Token" end return nil end
		return realInfo(id)
	end
	receiveNU(ns, 6401, vendorOf("Maria Lumere of the Very Long Name", 123456))
	receiveNU(ns, 6402, vendorOf("Token Keeper", 0, { o = { { 2, 8889, 5 } } }))
	M.advance(1)
	UI:ToggleFind()
	local row = d.findRows[2]
	H.eq(plain(row.price:GetText()), "~12g 34s 56c")
	H.ok(row.mapButton:IsShown(), "map button")
	H.eq(rawget(row, "priceRight"), 56, "the price ends 6 left of the button")
	H.ok(8 + row.name._width + 8 <= 302 - 56 - row.price:GetStringWidth(), "the name ends 8 before the price: " .. row.name._width)
	row = d.findRows[3]
	H.eq(rawget(row, "priceRight"), 56)
	H.ok(plain(row.detail:GetText()):find("5 #8889", 1, true), "not loaded: " .. plain(row.detail:GetText()))
	H.ok(ns.Scanner.WasAsked(8889), "asked for")
	loaded = true
	M.fire("GET_ITEM_INFO_RECEIVED", 8889, true)
	M.advance(3)
	H.ok(plain(row.detail:GetText()):find("5 Arcane Token", 1, true), "loaded: " .. plain(row.detail:GetText()))
	-- without the button the price ends at -6
	C_Map.CanSetUserWaypointOnMap = function() return false end
	UI:Refresh()
	H.eq(rawget(d.findRows[2], "priceRight"), 6)
	H.ok(8 + d.findRows[2].name._width + 8 <= 302 - 6 - d.findRows[2].price:GetStringWidth())
	cleanGame()
end)

-- ~6 px per character of the small font in the game (the mock measures 5); UTF-8 counted by character
local function gamePx(text)
	local s = plain(text):gsub("[\128-\191]", "")
	return #s * 6
end

H.test("find: every FIND text fits its row in en and sk (about 6 px per character, no wrap)", function()
	local ns, UI, d = findWindow()
	UI:ToggleFind()
	local function check(lang, what)
		for i = 1, shownRows(d) do
			local row = d.findRows[i]
			H.ok(gamePx(row.name:GetText()) <= row.name._width, lang .. " " .. what .. " name: " .. plain(row.name:GetText())
				.. " " .. gamePx(row.name:GetText()) .. " > " .. row.name._width)
			H.ok(gamePx(row.detail:GetText()) <= row.detail._width, lang .. " " .. what .. " detail: " .. plain(row.detail:GetText())
				.. " " .. gamePx(row.detail:GetText()) .. " > " .. row.detail._width)
		end
	end
	for _, lang in ipairs({ "en", "sk" }) do
		ns.SetLanguage(lang)
		SlashCmdList.PROFGUILD("npc clear")
		-- AH not seen, no vendor seen, drop, quest and crafted
		ns.RecipeData[RECIPE] = { ITEM, "vdqc", 0, 60, 80 }
		UI:Refresh()
		H.eq(shownRows(d), 3)
		check(lang, "ah/no vendor/other")
		-- probably a trainer: the second half is the detail line
		ns.RecipeData[RECIPE] = { false, "", 0, 60, 80 }
		UI:Refresh()
		H.eq((rowTexts(d.findRows[1])), ns.T("FIND_NO_TRAINER"))
		H.eq(select(2, rowTexts(d.findRows[1])), ns.T("FIND_NO_TRAINER_SEEN"))
		check(lang, "no trainer")
		ns.RecipeData[RECIPE] = nil
		UI:Refresh()
		check(lang, "unknown")
		-- a limited vendor alone, and a trainer, with a price
		ns.RecipeData[RECIPE] = { ITEM, "v", 0, 60, 80 }
		receiveNU(ns, 6501, vendorOf("Maria Lumere", 9500, { l = 1 }, placeOf(nil)))
		receiveNU(ns, 6502, trainerOf("Georgio Bolero", RECIPE, 50, 4000, placeOf(nil)))
		M.advance(1)
		UI:Refresh()
		check(lang, "vendor and trainer")
		-- with a place, the Map button, another cost and limited stock: the detail line gets the
		-- row but the Map button, the price stays on the name's line
		C_Map.CanSetUserWaypointOnMap = function() return true end
		C_Map.SetUserWaypoint = function() end
		_G.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m, x, y } end }
		local realInfo = C_Item.GetItemInfo
		C_Item.GetItemInfo = function(id)
			if id == 8888 then return "Merchant's Favor" end
			return realInfo(id)
		end
		SlashCmdList.PROFGUILD("npc clear")
		receiveNU(ns, 6601, vendorOf("Maria Lumere", 9500, { l = 1, o = { { 2, 8888, 5 } } }, placeOf(1453, 56, 64)))
		M.advance(1)
		UI:Refresh()
		local row
		for i = 1, shownRows(d) do
			if plain(d.findRows[i].name:GetText()):find("Maria", 1, true) then row = d.findRows[i] end
		end
		H.ok(row and row.mapButton:IsShown(), lang .. ": the vendor row with its Map button")
		local detail = plain(row.detail:GetText())
		H.eq(detail, "5 Merchant's Favor, " .. ns.T("FIND_LIMITED"), lang .. ": costs and stock kept, the place left to the tooltip")
		H.eq(row.detail._width, 302 - 8 - 56 - 8, lang .. ": the detail line runs to the Map button")
		check(lang, "place, Map button, other cost, limited stock")
		C_Item.GetItemInfo = realInfo
		_G.UiMapPoint = nil
	end
	ns.SetLanguage("en")
	cleanGame()
end)

H.test("npc: the end of combat lets the reader read windows opened in combat", function()
	local ns = boot()
	local called = 0
	ns.npcReader.CombatEnded = function() called = called + 1 end
	M.fire("PLAYER_REGEN_ENABLED")
	H.eq(called, 1, "CombatEnded at PLAYER_REGEN_ENABLED")
	ns.npcReader.CombatEnded = nil
end)
