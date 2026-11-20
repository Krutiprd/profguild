-- Profguild: Bugs
-- Bug reports written in the game, kept in SavedVariables (ProfguildDB.bugs) so they can be
-- read from the file after /reload or logout. A report carries the player's text and what
-- was on the screen: version, view, the selected recipe, the numbers of the details, the
-- price source, the last Lua errors of Profguild and the last lines of the diagnostic log.
-- A report is a plain table of strings and numbers; it is also handed to the guild for the
-- author (Reports.lua, ns.OnBugReport in Core.lua).
--
-- Lua errors: the game's error handler is wrapped. An error whose text names a Profguild file
-- is remembered (ProfguildDB.errors), then the previous handler runs as before, so BugSack or
-- the game's own error frame still see it.

local _, ns = ...
ns = ns or {}

local Bugs = {}
ns.Bugs = Bugs

Bugs.MAX_REPORTS = 30   -- oldest reports are dropped
Bugs.MAX_TEXT = 1000    -- characters of the player's text
Bugs.MAX_ERRORS = 20    -- distinct errors remembered
Bugs.REPORT_ERRORS = 5  -- newest errors copied into a report
Bugs.REPORT_LOG = 15    -- newest log lines copied into a report
Bugs.STACK_CHARS = 600

local pending = {} -- errors raised before the saved data is loaded

local function now()
	local ok, t = pcall(GetServerTime)
	if ok and type(t) == "number" then return t end
	return 0
end

-- Text as it reads on the screen: no colour codes, textures or links.
function Bugs.Plain(text)
	if type(text) ~= "string" then return text ~= nil and tostring(text) or "" end
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	text = text:gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1")
	return text
end

local function errorList()
	local db = ns.db
	if not db then return nil end
	if type(db.errors) ~= "table" then db.errors = {} end
	return db.errors
end

local function remember(e)
	local list = errorList()
	if not list then
		if #pending < Bugs.MAX_ERRORS then pending[#pending + 1] = e end
		return
	end
	for i, old in ipairs(list) do
		if old.msg == e.msg then
			old.count = (old.count or 1) + (e.count or 1)
			old.t = e.t
			old.v = e.v
			old.stack = e.stack
			table.remove(list, i)
			list[#list + 1] = old -- the newest last
			return
		end
	end
	list[#list + 1] = e
	while #list > Bugs.MAX_ERRORS do table.remove(list, 1) end
end

-- True for an error raised in a Profguild file: "Interface/AddOns/Profguild/UI.lua:12: ...", or
-- "Profguild/UI.lua:12: ..." as BugGrabber may shorten the path.
function Bugs.IsOurs(msg)
	if type(msg) ~= "string" then return false end
	return msg:find("^Profguild[/\\]") ~= nil or msg:find("[/\\ ]Profguild[/\\]") ~= nil
end

-- ours: the error was caught around Profguild code (Bugs.Call), so it is kept even when the
-- message names another file (a function of the game that Profguild called).
function Bugs.Record(msg, stack, ours)
	if not ours and not Bugs.IsOurs(msg) then return false end
	if type(msg) ~= "string" then msg = tostring(msg) end
	remember({
		msg = msg:sub(1, 400),
		stack = type(stack) == "string" and stack:sub(1, Bugs.STACK_CHARS) or nil,
		t = now(),
		v = ns.version,
		count = 1,
	})
	return true
end

-- Runs fn(...) protected like pcall; an error is remembered with the stack where it was raised.
-- Returns ok, err like pcall (only the first result of fn).
function Bugs.Call(fn, ...)
	local n, args = select("#", ...), { ... }
	local stack
	local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, function(e)
		stack = type(debugstack) == "function" and debugstack(2) or nil
		return e
	end)
	if not ok then pcall(Bugs.Record, tostring(err), stack, true) end
	return ok, err
end

-- Sees the errors that are not caught by Bugs.Call (scripts of buttons, messages, timers).
-- BugGrabber (BugSack) takes the game's error handler for itself and makes seterrorhandler do
-- nothing, so with it the error is taken from its callback instead. Without it the game's
-- handler is wrapped; recording never breaks the handler chain.
function Bugs.InstallErrorHook()
	if Bugs.hooked then return end
	local grabber = BugGrabber
	if type(grabber) == "table" and type(grabber.RegisterCallback) == "function" then
		local ok = pcall(grabber.RegisterCallback, Bugs, "BugGrabber_BugGrabbed", function(_, e)
			if type(e) == "table" then pcall(Bugs.Record, e.message, e.stack) end
		end)
		if ok then Bugs.hooked = "BugGrabber" return end
	end
	if type(geterrorhandler) ~= "function" or type(seterrorhandler) ~= "function" then return end
	local previous = geterrorhandler()
	if type(previous) ~= "function" then return end
	local function handler(msg, ...)
		if Bugs.IsOurs(msg) then
			local stack = type(debugstack) == "function" and debugstack(2) or nil
			pcall(Bugs.Record, msg, stack)
		end
		return previous(msg, ...)
	end
	seterrorhandler(handler)
	-- another addon may have made seterrorhandler do nothing
	if geterrorhandler() == handler then Bugs.hooked = "handler" end
end

-- Number of characters of a UTF-8 text (the edit box counts letters, not bytes).
function Bugs.Length(text)
	if type(strlenutf8) == "function" then return strlenutf8(text) end
	local _, n = text:gsub("[^\128-\191]", "")
	return n
end

-- The first max characters of a UTF-8 text, never cutting a character in half.
function Bugs.Cut(text, max)
	if Bugs.Length(text) <= max then return text end
	local count, i = 0, 1
	-- a character is a byte that is not a continuation byte (128-191) and the continuation
	-- bytes after it: counted the same way as Bugs.Length, also for broken text
	while i <= #text do
		local first = text:byte(i)
		if first >= 128 and first <= 191 then -- broken text starting mid-character: not a letter
			i = i + 1
		else
			if count == max then break end
			count = count + 1
			i = i + 1
			while i <= #text do
				local c = text:byte(i)
				if c < 128 or c > 191 then break end
				i = i + 1
			end
		end
	end
	return text:sub(1, i - 1)
end

-- Called once the saved data is there: initialises the tables, keeps early errors.
function Bugs.Init()
	local db = ns.db
	if not db then return end
	if type(db.bugs) ~= "table" then db.bugs = {} end
	errorList()
	for _, e in ipairs(pending) do remember(e) end
	pending = {}
end

local function copyErrors()
	local out, list = {}, errorList() or {}
	for i = math.max(1, #list - Bugs.REPORT_ERRORS + 1), #list do
		local e = list[i]
		out[#out + 1] = { msg = e.msg, stack = e.stack, t = e.t, v = e.v, count = e.count }
	end
	return out
end

local function copyLog()
	local out, log = {}, ns.db and ns.db.log
	if type(log) ~= "table" then return out end
	for i = math.max(1, #log - Bugs.REPORT_LOG + 1), #log do out[#out + 1] = log[i] end
	return out
end

local function playerName()
	local okName, name = pcall(UnitName, "player")
	local okRealm, realm = pcall(GetNormalizedRealmName)
	name = okName and name or "?"
	if okRealm and type(realm) == "string" and realm ~= "" then name = name .. "-" .. realm end
	return name
end

-- What was on the screen and around it, as plain text lines.
function Bugs.Context()
	local lines = {}
	local okPrices, source = pcall(ns.Prices and ns.Prices.Source or function() end)
	local ah = (AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown())
		or (AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown())
	lines[#lines + 1] = string.format("prices: %s, auction house %s", okPrices and source or "none", ah and "open" or "closed")
	if ns.UI and ns.UI.BugContext then
		local ok, uiLines = pcall(ns.UI.BugContext, ns.UI)
		if ok and type(uiLines) == "table" then
			for _, l in ipairs(uiLines) do lines[#lines + 1] = Bugs.Plain(l) end
		elseif not ok then
			lines[#lines + 1] = "window: " .. Bugs.Plain(tostring(uiLines))
		end
	end
	return lines
end

-- Saves a report. context: lines taken when the report was started (the window may have
-- changed since), or nil to take them now. Returns the report, or nil for an empty text.
function Bugs.Add(text, context)
	local db = ns.db
	if not db then return nil end
	text = type(text) == "string" and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
	if text == "" then return nil end
	if type(db.bugs) ~= "table" then db.bugs = {} end
	db.bugSeq = (tonumber(db.bugSeq) or 0) + 1
	local okGuild, guild = pcall(GetGuildInfo, "player")
	local okGuid, guid = pcall(UnitGUID, "player")
	local report = {
		n = db.bugSeq,
		t = now(),
		v = ns.version,
		who = playerName(),
		by = okGuid and type(guid) == "string" and guid or nil, -- the character, for sharing later
		guild = okGuild and type(guild) == "string" and guild or nil,
		lang = db.settings and db.settings.lang,
		text = Bugs.Cut(text, Bugs.MAX_TEXT),
		ctx = context or Bugs.Context(),
		errors = copyErrors(),
		log = copyLog(),
	}
	local list = db.bugs
	list[#list + 1] = report
	while #list > Bugs.MAX_REPORTS do table.remove(list, 1) end
	return report
end

function Bugs.All()
	return ns.db and type(ns.db.bugs) == "table" and ns.db.bugs or {}
end

-- How many times Profguild errors were raised since the last clear (each counted).
function Bugs.ErrorCount()
	local n = 0
	for _, e in ipairs(errorList() or {}) do n = n + (tonumber(e.count) or 1) end
	return n
end

function Bugs.Clear()
	if not ns.db then return end
	ns.db.bugs = {}
	ns.db.errors = {}
end

-- Hands a saved report to the guild (after the "saved" line). Never breaks the caller.
function Bugs.Share(report)
	if report and ns.OnBugReport then
		local ok, err = pcall(ns.OnBugReport, report)
		if not ok then pcall(Bugs.Record, tostring(err), nil, true) end
	end
end

-- Text from a guildmate for the chat: plain, and no escape sequence of the game left working.
function Bugs.Safe(text)
	return (Bugs.Plain(text):gsub("|", "||"))
end

function Bugs.Inbox()
	return ns.db and type(ns.db.inbox) == "table" and ns.db.inbox or {}
end

local function stampOf(t)
	local ok, s = pcall(date, "%d.%m. %H:%M", t)
	return ok and s or tostring(t)
end

-- /pg bug [text | list | clear confirm | inbox | inbox clear confirm]
function Bugs.Slash(rest)
	rest = rest or ""
	local word = rest:lower():gsub("%s+", " ")
	if rest == "" then
		if ns.UI and ns.UI.OpenBugReport then ns.UI:OpenBugReport() else ns.Say("BUG_USAGE") end
	elseif word == "list" then
		local list = Bugs.All()
		ns.Say("BUG_LIST", #list, Bugs.ErrorCount())
		for i = math.max(1, #list - 4), #list do
			local r = list[i]
			ns.Print("#%d %s: %s", r.n or i, stampOf(r.t), Bugs.Cut(Bugs.Plain(r.text), 80))
		end
	elseif word == "inbox" then
		local inbox = Bugs.Inbox()
		ns.Say("BUG_INBOX", #inbox)
		for i = math.max(1, #inbox - 4), #inbox do
			local r = inbox[i]
			ns.Print("%s %s (%s): %s", stampOf(r.t), Bugs.Safe(tostring(r.who or "?")), Bugs.Safe(tostring(r.v or "?")),
				Bugs.Safe(Bugs.Cut(tostring(r.text or ""), 80)))
		end
	elseif word == "inbox clear" then
		ns.Say("BUG_INBOX_CLEAR_CONFIRM")
	elseif word == "inbox clear confirm" then
		if ns.db then ns.db.inbox = {} end
		ns.Say("BUG_INBOX_CLEARED")
	elseif word == "clear" then
		ns.Say("BUG_CLEAR_CONFIRM")
	elseif word == "clear confirm" then
		Bugs.Clear()
		ns.Say("BUG_CLEARED")
	else
		local r = Bugs.Add(rest)
		if r then
			ns.Say("BUG_SAVED", r.n)
			Bugs.Share(r)
		end
	end
end

Bugs.InstallErrorHook()
