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
