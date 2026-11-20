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
	H.eq(r.shared, ME .. ":" .. r.t .. ":" .. r.n, "kept for later")
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
	H.ok(not line:find("|c", 1, true) or line:find("^|cff33bbffProfguild|r"), "no colour from the guildmate")
	H.ok(line:find("||Kq1||k", 1, true), "escapes shown as text: " .. line)
end)
