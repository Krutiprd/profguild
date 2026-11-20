-- Bug reports for the author inside the whole addon: sharing a saved report, the receiver's
-- inbox, the delivery notice, /pg bug inbox and /pg status.
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

-- receiver: log in as one of the author's characters; author: the roster lists one of them.
local function login(opts)
	opts = opts or {}
	ProfguildDB = nil
	Auctionator = nil
	local ns = loadAddon()
	if opts.receiver then
		_G.UnitName = function() return "Krutiprd" end
		_G.UnitFullName = function() return "Krutiprd", "Whychuck" end
	end
	if opts.author then
		local roster = _G.GetGuildRosterInfo
		_G.GetNumGuildMembers = function() return 3, 2 end
		_G.GetGuildRosterInfo = function(i)
			if i == 3 then
				return "Miestny Whychuck", "Officer", 1, 60, "Warrior", "Zone", "", "", false, 0, "WARRIOR", 0, 0, false, false, 0, "Player-1-000000FF"
			end
			return roster(i)
		end
	end
	M.fire("ADDON_LOADED", "Profguild")
	M.fire("PLAYER_LOGIN")
	M.advance(8)
	return ns
end

local function receive(ns, msg)
	ns.Comm:OnCommReceived("Profguild", ns.Comm.Encode(msg), "GUILD", "Ana Brightwood")
end

local function count(text)
	local n = 0
	for _, line in ipairs(M.chat) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function anaReport(ns, n)
	return {
		id = ANA .. ":" .. GetServerTime() .. ":" .. n, by = ANA, t = GetServerTime(), st = "h", who = "Ana-Brightwood", v = "0.5.0",
		text = "the profit is wrong " .. n, ctx = { "view: recipes" }, errors = {}, log = {},
	}
end

H.test("addon reports: without the author in the guild a report stays at home", function()
	local ns = login()
	local before = ns.reports.stats.sentU
	ns.Bugs.Slash("the window is too wide")
	local r = ns.Bugs.All()[1]
	H.ok(r, "saved")
	H.eq(r.shared, nil, "waits for a guild with the author")
	H.eq(ns.reports:HeldCount(), 0, "not held in this guild")
	H.eq(ns.reports.stats.sentU, before, "nothing sent")
	H.eq(count(ns.T("BUG_SHARED")), 0)
end)

H.test("addon reports: with the author in the guild a report goes out, and the delivery is told", function()
	local ns = login({ author = true })
	M.advance(31)
	ns.Bugs.Slash("prices are off")
	local r = ns.Bugs.All()[1]
	H.eq(ns.reports.stats.sentU, 1, "sent to the guild")
	H.eq(count(ns.T("BUG_SHARED")), 1, "told where it goes")
	-- the author's digest marks it delivered
	receive(ns, { t = "BD", pv = ns.Reports.PROTOCOL, s = "Player-1-000000FF", x = { r.shared, "d", r.t } })
	H.eq(ns.reports:Get(r.shared).st, "d")
	H.ok(r.delivered, "noted on the report")
	H.eq(count(ns.T("BUG_DELIVERED", r.n)), 1, "told")
	receive(ns, { t = "BD", pv = ns.Reports.PROTOCOL, s = "Player-1-000000FF", x = { r.shared, "d", r.t } })
	H.eq(count(ns.T("BUG_DELIVERED", r.n)), 1, "once")
	-- the window's save button shares as well
	ns.UI:OpenBugReport()
	ns.UI.bugDialog.edit:SetText("second one")
	ns.UI:SaveBugReport()
	H.eq(ns.reports.stats.sentU, 2)
	-- status line
	SlashCmdList.PROFGUILD("status")
	local s = ns.reports.stats
	H.eq(count(ns.T("STATUS_REPORTS", 1, 1, ns.T("YES"), 2, s.sentD, 0, 0, s.recvD, 0)), 1, "status line")
	H.eq(s.recvD, 2)
end)

H.test("addon reports: the receiver's inbox", function()
	local ns = login({ receiver = true })
	H.ok(ns.IsReportReceiver(), "Krutiprd is a receiver")
	local rec = anaReport(ns, 4)
	receive(ns, { t = "BU", pv = ns.Reports.PROTOCOL, s = ANA, q = { rec } })
	local inbox = ns.db.inbox
	H.eq(#inbox, 1, "in the inbox")
	H.eq(inbox[1].text, "the profit is wrong 4"); H.eq(inbox[1].who, "Ana-Brightwood"); H.ok(inbox[1].got)
	H.eq(ns.reports:Get(rec.id).st, "d", "marked delivered")
	H.eq(count(ns.T("BUG_INBOX_NEW", "Ana-Brightwood", "the profit is wrong 4")), 1, "notice")
	receive(ns, { t = "BU", pv = ns.Reports.PROTOCOL, s = ANA, q = { rec } })
	H.eq(#ns.db.inbox, 1, "not twice")
	-- the receiver's own report goes to the inbox at once
	ns.Bugs.Slash("my own bug")
	H.eq(#ns.db.inbox, 2)
	H.eq(count(ns.T("BUG_INBOX_OWN")), 1)
	H.ok(ns.Bugs.All()[1].delivered)
	-- listed and cleared
	local before = #M.chat
	ns.Bugs.Slash("inbox")
	H.eq(count(ns.T("BUG_INBOX", 2)), 1)
	H.ok(#M.chat >= before + 3, "header and two lines")
	ns.Bugs.Slash("inbox clear confirm")
	H.eq(#ns.db.inbox, 0)
end)

H.test("addon reports: receiver names are compared without case, spaces or a realm", function()
	local ns = login()
	local IS = ns.Reports.IsReceiverName
	H.ok(IS("Krutiprd", "Whychuck"))
	H.ok(IS("krutiprd-whychuck"))
	H.ok(IS("Miestny Whychuck"), "the roster's space")
	H.ok(IS("Zlatan", nil, "Whychuck"), "our realm when none is given")
	H.ok(IS("Fiona", "Vajcak")); H.ok(IS("Bubli", "Prd"))
	H.ok(not IS("Krutiprd", "Vajcak"), "another realm")
	H.ok(not IS("Frost", "Winterborn"))
	H.ok(not IS(nil))
end)

H.test("addon reports: a mark that came while an alt played is told on the next login", function()
	local ns = login({ author = true })
	M.advance(31)
	ns.Bugs.Slash("seen on an alt")
	local r = ns.Bugs.All()[1]
	-- the mark lands in the shared guild data, but the notice is not given (as on an alt)
	ns.reports.list[r.shared] = { id = r.shared, by = r.by, t = r.t, st = "d" }
	H.ok(not r.delivered)
	local base = count(ns.T("BUG_DELIVERED", r.n)) -- the chat of earlier tests
	ns.CheckReports()
	H.ok(r.delivered, "noted")
	H.eq(count(ns.T("BUG_DELIVERED", r.n)) - base, 1, "told")
end)

H.test("addon reports: a report saved before the guild was known goes out later", function()
	local ns = login({ author = true })
	M.advance(31)
	local reports = ns.reports
	ns.reports = nil
	local base = count(ns.T("BUG_SHARED"))
	ns.Bugs.Slash("too early")
	local r = ns.Bugs.All()[1]
	H.eq(r.shared, nil, "not shared yet")
	H.eq(r.by, ME)
	ns.reports = reports
	ns.CheckReports()
	H.ok(r.shared, "shared now")
	H.eq(ns.reports.stats.sentU, 1)
	H.eq(count(ns.T("BUG_SHARED")) - base, 0, "quietly")
end)

H.test("addon reports: a guildmate's text cannot colour the receiver's chat", function()
	local ns = login({ receiver = true })
	local rec = anaReport(ns, 9)
	rec.who = "|cffff0000Ana|r"
	rec.text = "click |Hitem:1|h[here]|h or |Kq1|k"
	receive(ns, { t = "BU", pv = ns.Reports.PROTOCOL, s = ANA, q = { rec } })
	local line = M.chat[#M.chat]
	local prefix = "|cff33bbffProfguild|r: "
	H.eq(line:sub(1, #prefix), prefix)
	local rest = line:sub(#prefix + 1):gsub("||", "")
	H.ok(not rest:find("|", 1, true), "no working escape from the guildmate: " .. line)
	H.ok(line:find("||Kq1||k", 1, true), "escapes shown as text: " .. line)
end)

H.test("addon reports: a report waits for a guild with the author, and goes when one appears", function()
	local ns = login()
	ns.Bugs.Slash("before the author joined")
	local r = ns.Bugs.All()[1]
	H.eq(r.shared, nil)
	-- the author shows up in the roster
	local roster = _G.GetGuildRosterInfo
	_G.GetNumGuildMembers = function() return 3, 2 end
	_G.GetGuildRosterInfo = function(i)
		if i == 3 then return "Zlatan Whychuck", "Member", 3, 60, "Rogue", "Zone", "", "", true, 0, "ROGUE", 0, 0, false, false, 0, "Player-1-000000FE" end
		return roster(i)
	end
	M.advance(6)
	ns.OnRosterUpdate()
	M.advance(1)
	H.ok(r.shared, "shared now")
	H.eq(ns.reports.stats.sentU, 1, "sent")
	M.advance(10)
	H.ok(ns.reports.stats.sentD >= 1, "a digest followed")
end)

H.test("addon reports: the author noticed by any roster read sends waiting reports", function()
	local ns = login()
	ns.Bugs.Slash("waiting")
	local r = ns.Bugs.All()[1]
	H.eq(r.shared, nil)
	local roster = _G.GetGuildRosterInfo
	_G.GetNumGuildMembers = function() return 3, 2 end
	_G.GetGuildRosterInfo = function(i)
		if i == 3 then return "Fiona Vajcak", "Member", 3, 60, "Mage", "Zone", "", "", false, 0, "MAGE", 0, 0, false, false, 0, "Player-1-000000FD" end
		return roster(i)
	end
	-- not a roster event: the cache runs out and /pg status reads the roster
	M.advance(31)
	SlashCmdList.PROFGUILD("status")
	M.advance(1)
	H.ok(r.shared, "shared once the author was seen")
end)

H.test("addon reports: an alt's report in the account's guild data is kept, and a lost one is sent again", function()
	local ns = login({ author = true })
	M.advance(31)
	ns.Bugs.Slash("from an alt")
	local r = ns.Bugs.All()[1]
	-- as if another character of the account had written it
	local rec = ns.reports.list[r.shared]
	H.ok(ns.reports.list[r.shared], "held")
	rec.by = "Player-1-0000ABCD"
	local altId = "Player-1-0000ABCD:" .. r.t .. ":" .. r.n
	ns.reports.list[r.shared] = nil
	rec.id = altId
	ns.reports.list[altId] = rec
	r.shared = altId
	for i = 1, 65 do
		local guid = string.format("Player-1-%08X", 600 + i)
		ns.reports:Merge({ id = guid .. ":" .. GetServerTime() .. ":1", by = guid, t = GetServerTime(), st = "h",
			who = "X", text = "newer " .. i })
	end
	H.ok(ns.reports:Get(altId), "the alt's report is still held")
	-- a report of ours whose copy is gone goes out again with the same id
	ns.Bugs.Slash("second")
	local r2 = ns.Bugs.All()[2]
	local id2 = r2.shared
	ns.reports.list[id2] = nil
	ns.CheckReports()
	H.eq(r2.shared, id2, "same id")
	H.ok(ns.reports:Get(id2), "held again")
end)
