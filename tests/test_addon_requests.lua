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
