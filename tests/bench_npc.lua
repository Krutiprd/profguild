-- Real-time benchmark of the NPC work with a full table (600 sheets, 20000 entries, in both the
-- guild's table and npcOwn): the most ms one frame spends on it, for every path of the "no
-- hitch" brief. The reference is PUC Lua 5.1, the game's Lua: python tests/bench_npc.py
-- (lupa), or lua5.1 tests/bench_npc.lua from the repository root. luajit runs it too.
--
--   tests/bench_npc.lua [dir]   dir: a folder holding other copies of NpcData/NpcTable/NpcSync/
--                               NpcView (an older version: "before"); without NpcWork.lua there
--                               the work runs in one go, as before the scheduler.
-- A frame is what runs in one go: the call of the path (with the slice it starts at once), then
-- each later frame the scheduler asks for. The garbage collector runs as in the game.
local root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
local A = root .. "/Profguild"
-- "nogc" as an argument: the garbage collector stopped (what the NPC work alone costs per frame)
local dir, nogc = A, false
for i = 1, arg and #arg or 0 do
	if arg[i] == "nogc" then nogc = true else dir = arg[i] end
end
dofile(A .. "/Libs/LibStub/LibStub.lua")
dofile(A .. "/Libs/LibDeflate/LibDeflate.lua")
dofile(A .. "/Libs/LibSerialize/LibSerialize.lua")
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")

local ns = {}
local function exists(f)
	local h = io.open(f, "r")
	if h then h:close() return true end
	return false
end
if exists(dir .. "/NpcWork.lua") then assert(loadfile(dir .. "/NpcWork.lua"))("Profguild", ns) end
for _, f in ipairs({ "NpcData.lua", "NpcTable.lua", "NpcSync.lua", "NpcView.lua" }) do
	assert(loadfile(dir .. "/" .. f))("Profguild", ns)
end
local ND, NS, NW = ns.NpcData, ns.NpcSync, ns.NpcWork

-- ms; hrclock (the runner's high resolution clock) when given, os.clock steps by 1 ms on Windows
local now = hrclock or function() return os.clock() * 1000 end
local CLOCK0 = 1794615000
local DAY = math.floor(CLOCK0 / 86400)
local clockT = CLOCK0
local clock = function() return clockT end
local seed = 4242
local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648 return math.floor(seed / 2147483648 * n) end

-- The scheduler as Core makes it, with os.clock and frames counted here.
local frameNo, pending, budget = 0, {}, NW and NW.BUDGET or 0
local work = NW and NW.New({
	clock = now,
	frame = function() return frameNo end,
	defer = function(fn) pending[#pending + 1] = fn end,
	budget = function() return budget end,
	error = function(e, st) print("ERROR " .. tostring(st or e)) end,
}) or nil

-- fn() in one frame, then the frames the scheduler asks for: max ms of a frame, frames, total ms,
-- frames over 8 ms.
local function frames(fn)
	collectgarbage("collect")
	frameNo = frameNo + 1
	local t0 = now()
	fn()
	local worst = now() - t0
	local total, n, over = worst, 1, worst > 8 and 1 or 0
	while pending[1] do
		frameNo = frameNo + 1
		local p = pending
		pending = {}
		t0 = now()
		for _, f in ipairs(p) do f() end
		local d = now() - t0
		total, n = total + d, n + 1
		if d > 8 then over = over + 1 end
		if d > worst then worst = d end
	end
	return worst, n, total, over
end

-- Full tables -----------------------------------------------------------------------------
local function trainer(id, n, idBase)
	local s = { name = "Trainer Name " .. id, nd = DAY - rnd(100), map = 1400 + rnd(60), x = rnd(100), y = rnd(100),
		pd = DAY - rnd(100), t = {}, v = {} }
	for i = 1, n do
		local d = DAY - rnd(110)
		s.t[idBase + i * 7 + rnd(5)] = { d, 1 + rnd(300), d, 100 + rnd(100000), d }
	end
	return s
end
local function vendor(id, n)
	local s = { name = "Vendor " .. id, nd = DAY, map = 1400 + rnd(60), x = rnd(100), y = rnd(100), pd = DAY, t = {}, v = {} }
	for i = 1, n do
		local d = DAY - rnd(110)
		s.v[2000 + rnd(30000)] = { d, { c = 1000 + rnd(1000000), o = {}, l = rnd(2) }, d }
	end
	return s
end
local function build(saved)
	local tab = ND.New(saved, clock)
	for i = 1, 100 do tab:MergeIn(3000 + i * 13, trainer(3000 + i * 13, 152, i * 2000)) end
	for i = 1, 500 do tab:MergeIn(100000 + i * 17, vendor(100000 + i * 17, 11)) end
	return tab
end
local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end
local savedGuild, savedOwn = {}, {}
local g0, o0 = build(savedGuild), build(savedOwn)

local rows = {}
if nogc then collectgarbage("collect") collectgarbage("stop") end
local gc = collectgarbage
collectgarbage = function(what) if not nogc then return gc(what) end end
local function row(name, worst, n, total, over)
	rows[#rows + 1] = ("%-44s %8.1f %7d %6d %9.1f"):format(name, worst, n, over, total)
end

print(("%s%s, %s, budget %s ms%s"):format(_VERSION, jit and " (LuaJIT)" or "", dir == A and "this version" or dir,
	NW and tostring(NW.BUDGET) or "none (no scheduler)", nogc and ", garbage collector stopped" or ""))
print(("guild %d sheets %d entries; own %d sheets %d entries"):format(g0.nSheets, g0.nEntries, o0.nSheets, o0.nEntries))

-- Login (and /reload, a guild change): both tables made, the import, the first Hash and Count.
-- (the saved tables are copied before, outside the frame)
local own, guild, so, sg
local function login()
	own = ND.New(so, clock, nil, work)
	guild = ND.New(sg, clock, nil, work)
	local o, g = own, guild
	if work then work:Run(function() g:Import(o) end) else g:Import(o) end
	g:Hash() g:Count() o:Hash() o:Count()
end
so, sg = copy(savedOwn), copy(savedGuild)
row("login: New both + Import + Hash + Count", frames(login))
guild:Hash()
local reference = guild:Hash()

-- Combat: the same with the smaller budget.
if NW then
	budget = NW.COMBAT
	so, sg = copy(savedOwn), copy(savedGuild)
	row("login in combat (budget " .. NW.COMBAT .. " ms)", frames(login))
	budget = NW.BUDGET
end

-- NUs: the worst accepted (NU_SHEETS sheets sharing the columns of 100 entries: NU_ENTRIES),
-- decoded as Comm does in the same frame.
local adapter = {
	now = function() return 0 end, after = function() end, random = function() return 0.5 end,
	canSend = function() return true end, send = function() end, selfGuid = function() return "P" end,
	faction = function() return "Alliance" end, changed = function() end,
	isMe = function(n) return n == "Me" end, size = function() return 100 end,
}
local sync = NS.New(adapter, guild)
local function encode(msg) return LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg))) end
local function decode(text) return select(2, LS:Deserialize(LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(text)))) end
local function worstNU(base)
	local per = math.floor(NS.NU_ENTRIES / NS.NU_SHEETS)
	local s = { name = "T", nd = DAY, map = 1453, x = 1, y = 1, pd = DAY, t = {}, v = {} }
	for i = 1, per do s.t[base + i] = { DAY, 1 + rnd(300), DAY, 100 + rnd(100000), DAY } end
	local big = ND.Pack(8, ND.Valid(s, DAY))
	local x = {}
	for i = 1, NS.NU_SHEETS do
		local l = {}
		for j, v in ipairs(big) do l[j] = v end
		l[1] = base + i
		x[i] = l
	end
	return encode({ t = "NU", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "X", h = 1, x = x })
end
-- as Comm receives an NPC text: decoded in a job of the work (at once without a scheduler)
local function receive(text, sender)
	if work then
		work:Run(function()
			work:Pace(#text / 2)
			sync:OnMessage(decode(text), sender, #text)
		end)
	else
		sync:OnMessage(decode(text), sender, #text)
	end
end
local text = worstNU(800000)
row(("worst accepted NU (%d sheets, %d entries)"):format(NS.NU_SHEETS, NS.NU_ENTRIES),
	frames(function() receive(text, "G1") end))
local texts = {}
for k = 1, 5 do texts[k] = worstNU(810000 + k * 1000) end
row("5 worst NUs back to back (one frame)", frames(function()
	for k = 1, 5 do receive(texts[k], "G" .. (k + 1)) end
end))
-- an honest NU: about NU_FILL bytes of real sheets
do
	local x, bytes = {}, 0
	for i = 1, 30 do
		local l = ND.Pack(200000 + i, ND.Valid(vendor(200000 + i, 11), DAY))
		local b = #encode({ x = { l } })
		if bytes + b > NS.NU_FILL and bytes > 0 then break end
		x[#x + 1], bytes = l, bytes + b
	end
	local t = encode({ t = "NU", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "X", h = 1, x = x })
	row(("honest NU (%d vendor sheets, %d bytes)"):format(#x, #t), frames(function() receive(t, "G9") end))
end

-- Own readings at full: npcOwn's Write and the guild's OwnVisit (rule 8) of a new trainer.
local reading = { name = "X", map = 1, x = 1, y = 1, t = {}, v = {} }
for i = 1, 150 do reading.t[700000 + i] = { skill = 10, copper = 100 } end
row("own reading of a trainer (Write + OwnVisit)", frames(function()
	local fn = function() own:Write(4242, reading) sync:OwnVisit(4242, reading) end
	if work then work:Run(fn) else fn() end
end))

-- /pg npc and /pg status: the counts.
row("/pg npc (Count of both)", frames(function() own:Count() guild:Count() end))

-- The window: FIND RECIPE and the Leveling list (NpcView, both tables), first opened.
local src = { own = own, guild = guild }
row("FIND RECIPE: Sources (first opening)", frames(function() ns.NpcView.Sources(3000 + 13 * 7, src, { items = { [12345] = true, [20000] = true } }) end))
row("Leveling: Skill of 300 recipes", frames(function()
	for i = 1, 300 do ns.NpcView.Skill(2000 * (i % 100 + 1) + 7 * (i % 152), src) end
end))

-- Sending: our NI (every sendable ID) and an NU of a large sheet, sized by the real encoding.
do
	-- as Core and Comm do: the text of the message last sized is sent (encoded once), or encoded
	-- twice when the version has no such cache (Comm.EncodeNpc)
	local last, lastText = nil, nil
	local cached = NW ~= nil
	adapter.size = function(msg) last, lastText = msg, encode(msg) return #lastText end
	adapter.now = function() return 1000 end
	local s2 = NS.New(adapter, guild)
	local timers = {}
	adapter.after = function(d, fn) timers[#timers + 1] = fn end
	-- an ND with another hash plans an NI; its timer is run as the game would
	s2:OnMessage({ t = "ND", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "Y", h = 5, n = 3 }, "Other", 10)
	local run = timers
	timers = {}
	adapter.send = function(msg) if not (cached and msg == last) then encode(msg) end end
	row("our NI (600 IDs): sized and sent", frames(function()
		for _, fn in ipairs(run) do fn() end
	end))
	-- an NI of an empty newcomer: every sheet planned, the first NU sized and sent
	timers = {}
	s2:OnMessage({ t = "NI", pv = ND.PROTOCOL, e = ND.EPOCH, f = "Alliance", s = "Z", h = 6, r = 7, i = {}, c = {} }, "New", 10)
	run = timers
	timers = {}
	row("first NU to a newcomer (sizes, encoding)", frames(function()
		for _, fn in ipairs(run) do fn() end
	end))
	adapter.size, adapter.after, adapter.send = function() return 100 end, function() end, function() end
end

-- Day rollover: the next read sees a new day (Expire), then the hash.
clockT = CLOCK0 + 86400
row("day rollover: Expire + Hash", frames(function() guild:Hash() own:Hash() end))
clockT = CLOCK0 + 40 * 86400
row("40 days later: Expire + Hash", frames(function() guild:Hash() own:Hash() end))

print(("%-44s %8s %7s %6s %9s"):format("path", "max ms", "frames", ">8 ms", "total ms"))
for _, r in ipairs(rows) do print(r) end
print(("hash after login %d"):format(reference))
