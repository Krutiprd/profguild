-- Profguild: Core
-- Startup, saved data, game events, the Sync adapter and slash commands.

local ADDON, ns = ...

local Store, Sync, Scanner, Comm, Reagents, Catalog = ns.Store, ns.Sync, ns.Scanner, ns.Comm, ns.Reagents, ns.Catalog
local GuildPrices, Requests, Reports = ns.GuildPrices, ns.Requests, ns.Reports
local NpcData, NpcSync, NpcWork = ns.NpcData, ns.NpcSync, ns.NpcWork

ns.Config = {
	staleDays = 30,          -- hide members who have not logged in for this many days
	helloInterval = 900,     -- periodic sync check, seconds
	rosterInterval = 300,    -- roster refresh, seconds
	skillDebounce = 60,      -- skill-ups are merged into one update
	syncMinWait = 8,         -- a manual sync reports its result no sooner than this, seconds
	syncQuiet = 5,           -- ... and only after this long without new data
	syncMaxWait = 60,        -- ... and at the latest after this long
	changeDebounce = 3,      -- recipe scans and learned recipes
	loginHelloDelay = { 15, 25 },
	schema = 1,
}

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "dev"

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------

local PREFIX = "|cff33bbffProfguild|r: "

function ns.Print(fmt, ...)
	local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

function ns.Say(key, ...)
	ns.Print(ns.T(key, ...))
end

-- Diagnostic log kept in SavedVariables (ProfguildDB.log), so it can be read from the file
-- after /reload or logout. Holds the last LOG_LINES lines.
local LOG_LINES = 400
function ns.Log(fmt, ...)
	if not ns.db then return end
	local ok, text = pcall(string.format, fmt, ...)
	local log = ns.db.log
	if type(log) ~= "table" then log = {}; ns.db.log = log end
	local okDate, stamp = pcall(date, "%H:%M:%S")
	log[#log + 1] = (okDate and stamp or "?") .. " " .. (ok and text or tostring(fmt))
	while #log > LOG_LINES do table.remove(log, 1) end
end

function ns.Debug(fmt, ...)
	ns.Log(fmt, ...)
	if ns.db and ns.db.settings.debug then
		local ok, text = pcall(string.format, fmt, ...)
		DEFAULT_CHAT_FRAME:AddMessage("|cff888888Profguild debug: " .. (ok and text or fmt) .. "|r")
	end
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

local function randomId()
	local t = {}
	for i = 1, 12 do t[i] = string.format("%x", math.random(0, 15)) end
	return table.concat(t)
end

local function initDB()
	ProfguildDB = type(ProfguildDB) == "table" and ProfguildDB or {}
	local db = ProfguildDB
	db.schema = db.schema or ns.Config.schema
	db.account = db.account or randomId()
	db.settings = db.settings or {}
	db.settings.lang = db.settings.lang or "en"
	if db.settings.onlineOnly == nil then db.settings.onlineOnly = false end
	db.settings.staleDays = db.settings.staleDays or ns.Config.staleDays
	if type(db.guilds) ~= "table" then db.guilds = {} end
	db.own = db.own or {}
	-- reagents per recipe: game data, kept for the whole account (see Reagents.lua)
	if type(db.reagents) ~= "table" then db.reagents = {} end
	-- every recipe of every profession, learned or not: game data, kept for the whole account
	if type(db.catalog) ~= "table" then db.catalog = {} end
	-- where recipes are found, asked from the game when a recipe is opened in the window
	if type(db.sources) ~= "table" then db.sources = {} end
	-- skill levels of recipes: [recipeID] = { g = grey from, m = learnable from (recipe item) }
	if type(db.recipeInfo) ~= "table" then db.recipeInfo = {} end
	-- recipe items seen at the auction house: [recipeID] = itemID (Prices.IndexRecipeItems)
	if type(db.recipeItems) ~= "table" then db.recipeItems = {} end
	if db.settings.recipeFilter ~= "unknown" and db.settings.recipeFilter ~= "all" then
		db.settings.recipeFilter = "known"
	end
	-- recipe groups collapsed in the window: [skill line .. "\1" .. group] = true
	if type(db.settings.collapsed) ~= "table" then db.settings.collapsed = {} end
	ns.db = db
	ns.SetLanguage(db.settings.lang)
	-- bug reports and the last Lua errors of Profguild (see Bugs.lua)
	if ns.Bugs then ns.Bugs.Init() end
end

function ns.StaleDays()
	return ns.Config.staleDays -- v1: fixed; settings.staleDays is reserved for a later UI option
end

---------------------------------------------------------------------------
-- Sending rules
---------------------------------------------------------------------------

-- Returns nil when sending is allowed, otherwise the locale key of the reason.
function ns.SendBlockReason()
	if not IsInGuild() or not ns.store then return "REASON_NO_GUILD" end
	if (IsTrialAccount and IsTrialAccount()) or (IsVeteranTrialAccount and IsVeteranTrialAccount()) then
		return "REASON_TRIAL"
	end
	if InCombatLockdown() then return "REASON_COMBAT" end
	local inInstance, instanceType = IsInInstance()
	if inInstance and instanceType ~= "none" then return "REASON_INSTANCE" end
	if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
		local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
		if ok and locked then return "REASON_LOCKDOWN" end
	end
	return nil
end

---------------------------------------------------------------------------
-- Own character
---------------------------------------------------------------------------

local function ownState()
	local guid = UnitGUID("player")
	if not guid then return nil end
	local own = ns.db.own[guid]
	if not own then
		own = {}
		ns.db.own[guid] = own
	end
	return own, guid
end
ns.OwnState = ownState

-- Without GUIDs in the roster, find our own row: the only online member of our class whose
-- name is our name, or starts with our name followed by a surname.
local function ownRosterNameByName()
	local store = ns.store
	if not store or not store.rosterByName then return nil end
	local me = UnitName("player")
	local _, classFile = UnitClass("player")
	if not me then return nil end
	local found
	for name, entry in pairs(store.rosterByName) do
		local short = ns.NormalizeName(name)
		if entry.online and (not entry.c or entry.c == classFile)
			and (short == me or short:sub(1, #me + 1) == me .. " ") then
			if found then return nil end -- ambiguous
			found = entry.name or name
		end
	end
	return found
end

local function ownDisplayName(guid)
	local entry = ns.store and ns.store.db.roster[guid]
	local name = entry and entry.name or ownRosterNameByName()
	if name then
		return (Ambiguate and Ambiguate(name, "guild")) or name
	end
	return UnitName("player")
end

-- Takes a fresh snapshot of our professions and publishes our record when it changed.
function ns.RefreshOwn()
	local own, guid = ownState()
	if not own then return end
	local snap = Scanner.Snapshot()
	snap.name = ownDisplayName(guid) or snap.name
	snap.account = ns.db.account
	ns.lastSnapshot = snap
	local rec, changed = Store.BuildOwnRecord(own, snap, GetServerTime())
	if ns.sync and rec and (changed or not ns.store:Get(guid) or ns.store:Get(guid).v < rec.v) then
		ns.sync:PublishOwn(rec)
	end
	-- a profession disappeared once: confirm with a second snapshot soon
	if own.missing and next(own.missing) then ns.ScheduleRefresh(30) end
	ns.RemindToScan()
	return changed
end

local refreshToken, refreshAt = 0, nil
-- Merges bursts of changes (skill-ups, recipe scans) into one update. A pending refresh is
-- only ever moved earlier, never later: steady skill-ups cannot postpone an update forever,
-- and a learned recipe (short delay) is not held back by a pending skill-up (long delay).
function ns.ScheduleRefresh(delay)
	delay = delay or ns.Config.changeDebounce
	local now = GetTime()
	if refreshAt and refreshAt <= now + delay then return end
	refreshToken = refreshToken + 1
	refreshAt = now + delay
	local token = refreshToken
	C_Timer.After(delay, function()
		if token ~= refreshToken then return end
		refreshAt = nil
		ns.RefreshOwn()
	end)
end

local reminded = {}
function ns.RemindToScan()
	local own = ownState()
	if not own or not own.profs then return end
	local names = {}
	for skillLine in pairs(own.profs) do
		local scanned = own.scanned and own.scanned[skillLine]
		-- scanned before the recipe catalog existed (0.1.x): its unlearned recipes are missing
		local noCatalog = scanned and ns.catalog and not ns.catalog:Get(skillLine)
			and own.recipes and own.recipes[skillLine] and next(own.recipes[skillLine]) ~= nil
		if (not scanned or noCatalog) and not reminded[skillLine] then
			reminded[skillLine] = true
			names[#names + 1] = Scanner.ProfessionName(skillLine)
		end
	end
	if #names > 0 then
		table.sort(names)
		ns.Say("OPEN_PROFESSION", table.concat(names, ", "))
	end
end

-- received: the copy of our record someone else holds (validated), or nil.
local function onOwnConflict(guid, seenVersion, received)
	local own = ownState()
	if not own then return end
	if not own.rec then ns.RefreshOwn() end
	local rec = Store.HealOwn(own, seenVersion, received, GetServerTime())
	if rec then
		ns.Debug("own record seen with version %d (%s), publishing %d", seenVersion,
			received and "copy received" or "no copy", own.v)
		ns.sync:PublishOwn(rec)
		ns.OnDataChanged()
	end
end

---------------------------------------------------------------------------
-- Guild context
---------------------------------------------------------------------------

-- Character name without a realm suffix, the form used to compare roster names with records.
function ns.NormalizeName(name)
	if type(name) ~= "string" then return name end
	if Ambiguate then
		local ok, short = pcall(Ambiguate, name, "none")
		if ok and type(short) == "string" then return short end
	end
	return (name:gsub("%-.*$", ""))
end

-- Tells the window that data changed, at most once per half second. A pending notice is not
-- postponed by further changes: during a long sync the window keeps refreshing.
local dataChangedPending = false
function ns.OnDataChanged()
	-- new reagents or recipes: the items whose prices are shared may have changed
	if ns.Prices and ns.Prices.InvalidateInterest then ns.Prices.InvalidateInterest() end
	if dataChangedPending then return end
	dataChangedPending = true
	C_Timer.After(0.5, function()
		dataChangedPending = false
		if ns.UI and ns.UI.OnDataChanged then ns.UI:OnDataChanged() end
	end)
end

-- A guildmate runs a newer version: say so once per session, a few seconds after the first
-- such hello, with the highest version seen by then. The window and /pg status show it too.
local updateNoticePlanned = false
local function onPeerVersion(av)
	if not Store.VersionNewer(av, ns.version) then return end
	if not ns.newerVersion or Store.VersionNewer(av, ns.newerVersion) then
		ns.newerVersion = av
		ns.OnDataChanged()
	end
	if updateNoticePlanned then return end
	updateNoticePlanned = true
	C_Timer.After(5, function()
		ns.Say("UPDATE_AVAILABLE", ns.newerVersion, tostring(ns.version))
	end)
end

local adapter = {
	send = function(msg) Comm.Send(msg) end,
	canSend = function() return ns.SendBlockReason() == nil end,
	now = function() return GetTime() end,
	after = function(delay, fn) C_Timer.After(delay, fn) end,
	random = function() return math.random() end,
	myGuid = function() return UnitGUID("player") end,
	ownVersion = function(guid)
		local own = ns.db.own[guid]
		if guid == UnitGUID("player") and own then return own.v end
	end,
	onOwnConflict = onOwnConflict,
	onPeerVersion = onPeerVersion,
	onNewerProtocol = function() ns.Say("NEWER_VERSION") end,
	-- The game names the real sender of an addon message. When the roster row with this guid
	-- carries that name, the message comes from the owner of the record. Rows matched only by
	-- name (a roster without GUIDs) prove nothing and do not count.
	isOwner = function(guid, senderName)
		local entry = ns.store and ns.store.db.roster[guid]
		return entry ~= nil and type(entry.name) == "string" and type(senderName) == "string"
			and ns.NormalizeName(entry.name) == ns.NormalizeName(senderName)
	end,
	onChanged = function(guid)
		if ns.syncReport and guid then
			ns.syncReport.changed[guid] = true
			ns.syncReport.last = GetTime()
		end
		ns.OnDataChanged()
	end,
	log = function(...) ns.Debug(...) end,
}

local reagentAdapter = {
	send = function(msg) Comm.Send(msg) end,
	canSend = function() return ns.guildKey ~= nil and ns.SendBlockReason() == nil end,
	now = function() return GetTime() end,
	after = function(delay, fn) C_Timer.After(delay, fn) end,
	random = function() return math.random() end,
	myGuid = function() return UnitGUID("player") end,
	onChanged = function() ns.OnDataChanged() end,
}

-- A recipe ID from a guildmate is taken only when the game knows the recipe and does not put
-- it into another profession. Returns the crafted item (0 for none) or nil.
local function verifyRecipe(recipeID, skillLine)
	local known, itemID = Scanner.RecipeInGame(recipeID)
	if not known then return nil end
	local prof = Scanner.ProfessionForRecipe(recipeID)
	if prof and prof ~= skillLine and Scanner.ProfessionName(prof) ~= Scanner.ProfessionName(skillLine) then
		return nil
	end
	return itemID
end

-- Adds the recipes of Data.lua the catalog lacks, so recipes are listed though nobody in the guild
-- opened that profession, and a guildmate's list that broke off on its way is completed. Every
-- recipe is checked with the game first. The data has a few recipes no window lists; they are kept
-- and shared like the others. The game is asked in steps and everything is stored at the end.
-- /pg catalog clear stops a running fill and the one of this login (ns.seedOff).
local SEED_BATCH, SEED_PACE = 50, 0.1
function ns.SeedCatalog()
	local ids = {}
	for recipeID, e in pairs(ns.RecipeData or {}) do
		local line = type(e) == "table" and e[6]
		if line and (ns.catalog:Get(line) or {})[recipeID] == nil then ids[#ids + 1] = recipeID end
	end
	if #ids == 0 then return end
	local found, i = {}, 0
	local function step()
		if ns.seedOff then return end
		for _ = 1, SEED_BATCH do
			i = i + 1
			local recipeID = ids[i]
			if not recipeID then break end
			local line = ns.RecipeData[recipeID][6]
			local itemID = verifyRecipe(recipeID, line)
			if itemID then
				found[line] = found[line] or {}
				found[line][recipeID] = itemID
			end
		end
		if i < #ids then return C_Timer.After(SEED_PACE, step) end
		for line, list in pairs(found) do
			local added = ns.catalog:Add(line, list)
			ns.Log("catalog %s: %d recipes from Data.lua", Scanner.ProfessionName(line), added)
		end
	end
	step()
end

local catalogAdapter = {
	send = function(msg) Comm.Send(msg) end,
	canSend = function() return ns.guildKey ~= nil and ns.SendBlockReason() == nil end,
	now = function() return GetTime() end,
	after = function(delay, fn) C_Timer.After(delay, fn) end,
	random = function() return math.random() end,
	myGuid = function() return UnitGUID("player") end,
	verify = verifyRecipe,
	onChanged = function() ns.OnDataChanged() end,
}

local pricesAdapter = {
	send = function(msg) Comm.Send(msg) end,
	canSend = function() return ns.guildKey ~= nil and ns.SendBlockReason() == nil end,
	now = function() return GetTime() end,
	clock = function() return GetServerTime() end,
	after = function(delay, fn) C_Timer.After(delay, fn) end,
	random = function() return math.random() end,
	myGuid = function() return UnitGUID("player") end,
	onChanged = function() ns.OnDataChanged() end,
}

-- True when one of our characters' professions knows the recipe.
local function knowsRecipe(recipeID)
	for _, own in pairs(ns.db and ns.db.own or {}) do
		for _, list in pairs(type(own) == "table" and own.recipes or {}) do
			if type(list) == "table" and list[recipeID] ~= nil then return true end
		end
	end
	return false
end
ns.KnowsRecipe = knowsRecipe

-- What a request asks for, as text: the crafted item, else the recipe.
function ns.RequestItemName(rec)
	local name = rec.i and rec.i > 0 and Scanner.ItemName(rec.i)
	return name or Scanner.RecipeName(rec.r) or ("#" .. tostring(rec.r))
end

-- Chat notices about requests: a new one for a recipe we know, ours taken by somebody. Each
-- request and kind at most once per session.
local noticed = {}
local function requestNotice(id, what, before)
	local rec = ns.requests and ns.requests:Get(id)
	if not rec then return end
	local me = UnitGUID("player")
	-- our take was beaten by an earlier one, or lost to a give-back we had not heard
	if before and before.st == "taken" and before.cr == me and rec.cr ~= me and not (rec.st == "open" and rec.ub == me) then
		ns.Say("REQ_LOST_NOTICE", ns.RequestItemName(rec))
	end
	local key = id .. "\1" .. tostring(what)
	if noticed[key] then return end
	if what == "new" and rec.st == "open" and rec.by ~= me and knowsRecipe(rec.r) then
		noticed[key] = true
		ns.Say("REQ_NEW_NOTICE", ns.MemberName(rec.by), rec.n, ns.RequestItemName(rec))
	elseif what == "taken" and rec.by == me and rec.cr and rec.cr ~= me then
		key = id .. "\1taken\1" .. rec.cr
		if noticed[key] then return end
		noticed[key] = true
		ns.Say("REQ_TAKEN_NOTICE", ns.MemberName(rec.cr), ns.RequestItemName(rec))
	end
end

local requestsAdapter = {
	send = function(msg) Comm.Send(msg) end,
	canSend = function() return ns.guildKey ~= nil and ns.SendBlockReason() == nil end,
	now = function() return GetTime() end,
	clock = function() return GetServerTime() end,
	after = function(delay, fn) C_Timer.After(delay, fn) end,
	random = function() return math.random() end,
	myGuid = function() return UnitGUID("player") end,
	onChanged = function(id, what, before)
		requestNotice(id, what, before)
		ns.OnDataChanged()
	end,
}

-- Bug reports carried to the author (Reports.lua) ----------------------------------------

local function myRealm()
	local okFull, _, realm = pcall(UnitFullName, "player")
	if okFull and type(realm) == "string" and realm ~= "" then return realm end
	local ok, r = pcall(GetNormalizedRealmName)
	return ok and r or nil
end

-- This character is one of the receivers of bug reports.
function ns.IsReportReceiver()
	local ok, name = pcall(UnitName, "player")
	return ok and Reports.IsReceiverName(name, myRealm()) or false
end

-- A receiver is a member of our guild (the roster is read at most every 30 s).
local receiverSeen = { at = -1e9, value = false }
function ns.ReceiverInGuild()
	if not ns.guildKey then return false end
	local now = GetTime()
	if now - receiverSeen.at < 30 then return receiverSeen.value end
	local value = ns.IsReportReceiver()
	if not value and GetNumGuildMembers and GetGuildRosterInfo then
		local realm = myRealm()
		local ok, total = pcall(GetNumGuildMembers)
		for i = 1, ok and tonumber(total) or 0 do
			local okRow, name = pcall(GetGuildRosterInfo, i)
			if okRow and Reports.IsReceiverName(name, nil, realm) then
				value = true
				break
			end
		end
	end
	local appeared = value and not receiverSeen.value
	receiverSeen.at, receiverSeen.value = now, value
	if appeared and ns.reports then
		-- the author just appeared (whoever asked first): waiting reports go out
		C_Timer.After(0, function()
			ns.Bugs.Call(function()
				if not ns.reports then return end
				ns.CheckReports()
				ns.reports:AnnounceSoon()
			end)
		end)
	end
	return value
end

ns.INBOX_MAX = 150 -- at least Reports.MAX_MARKS: a report coming back is still recognised

-- The receiver's inbox (account-wide, so every receiver character sees it).
local function deliverReport(rec)
	local inbox = ns.db.inbox
	if type(inbox) ~= "table" then inbox = {} ns.db.inbox = inbox end
	for _, old in ipairs(inbox) do
		if old.id == rec.id then return end
	end
	local entry = {}
	for k, v in pairs(rec) do entry[k] = v end
	entry.st = nil
	entry.got = GetServerTime()
	entry.guild = ns.guildName
	inbox[#inbox + 1] = entry
	while #inbox > ns.INBOX_MAX do table.remove(inbox, 1) end
	if rec.by ~= UnitGUID("player") then
		ns.Say("BUG_INBOX_NEW", ns.Bugs.Safe(entry.who or "?"), ns.Bugs.Safe(ns.Bugs.Cut(entry.text or "", 60)))
	end
end

-- A report of this account reached a receiver: noted on the report, told once (also when the
-- mark came while another character of the account was playing: ns.CheckReports).
local function reportChanged(id, what)
	if what ~= "delivered" then return end
	for _, r in ipairs(ns.Bugs.All()) do
		if r.shared == id and not r.delivered then
			r.delivered = GetServerTime()
			ns.Say("BUG_DELIVERED", r.n or 0)
		end
	end
end

local reportsAdapter = {
	send = function(msg) Comm.Send(msg) end,
	canSend = function() return ns.guildKey ~= nil and ns.SendBlockReason() == nil end,
	now = function() return GetTime() end,
	clock = function() return GetServerTime() end,
	after = function(delay, fn) C_Timer.After(delay, function() ns.Bugs.Call(fn) end) end,
	random = function() return math.random() end,
	myGuid = function() return UnitGUID("player") end,
	isReceiver = function() return ns.IsReportReceiver() end,
	ownIds = function()
		local ids = {}
		for _, r in ipairs(ns.Bugs.All()) do
			if r.shared then ids[r.shared] = true end
		end
		return ids
	end,
	receiverInGuild = function() return ns.ReceiverInGuild() end,
	deliver = deliverReport,
	onChanged = reportChanged,
}

-- A report was just saved (Bugs.Add): handed to the guild for the author. quiet: no chat line
-- (a report saved earlier, shared now).
function ns.OnBugReport(report, quiet)
	if not ns.reports or type(report) ~= "table" or report.shared then return end
	-- only into a guild with the author: otherwise it waits (CheckReports when one appears)
	if not ns.IsReportReceiver() and not ns.ReceiverInGuild() then return end
	local rec = ns.reports:Share(report)
	if not rec then return end
	report.shared = rec.id
	if rec.st == "d" then
		report.delivered = GetServerTime()
		if not quiet then ns.Say("BUG_INBOX_OWN") end
	elseif not quiet then
		ns.Say("BUG_SHARED")
	end
end

-- After the guild is set up: this character's reports saved while it could not share them
-- (outside the guild, right after login) go out now; marks that arrived while another character
-- of the account was playing are told.
function ns.CheckReports()
	if not ns.reports then return end
	local me, clock = UnitGUID("player"), GetServerTime()
	for _, r in ipairs(ns.Bugs.All()) do
		if not r.shared and r.by == me and (r.guild == nil or r.guild == ns.guildName)
			and type(r.t) == "number" and r.t > clock - Reports.KEEP then
			ns.OnBugReport(r, true)
		end
		if r.shared and not r.delivered then
			local rec = ns.reports:Get(r.shared)
			if rec and rec.st == "d" then
				reportChanged(r.shared, "delivered")
			elseif not rec and r.by == me and (r.guild == nil or r.guild == ns.guildName)
				and type(r.t) == "number" and r.t > clock - Reports.KEEP
				and (ns.IsReportReceiver() or ns.ReceiverInGuild()) then
				-- our copy was lost (pushed out before 0.5.0's rules, or by an alt): again, same id
				r.shared = nil
				ns.OnBugReport(r, true)
			end
		end
	end
end

-- Trainers and vendors (NpcData, NpcSync) ------------------------------------------------
-- ns.npcOwn: what this account read itself, per faction (ProfguildDB.npcOwn[faction]), the last
-- known reading of every register. ns.npcGuild: the guild's table of the faction
-- (ProfguildDB.guilds[key].npc[faction]), shared by ns.npcSync. ns.npc: the table the window shows,
-- the guild's, else npcOwn. Both are made once the faction is known (it may not be at login).

-- ns.npcWork: the one scheduler of all NPC work (NpcWork): loading both tables, the import, merges,
-- expiry, own readings and NpcSync's messages run as its jobs, in order, at most a budget of ms
-- per frame (less in combat). At logout what is left runs to its end before the game saves.
local function npcClockMs()
	if type(debugprofilestop) == "function" then return debugprofilestop() end
	if type(GetTimePreciseSec) == "function" then return GetTimePreciseSec() * 1000 end
	return os.clock() * 1000
end

ns.npcWork = NpcWork.New({
	clock = npcClockMs,
	frame = function() return GetTime() end,
	defer = function(fn) C_Timer.After(0, function() ns.Bugs.Call(fn) end) end,
	budget = function()
		if type(InCombatLockdown) == "function" and InCombatLockdown() then return NpcWork.COMBAT end
		return NpcWork.BUDGET
	end,
	error = function(err, stack)
		ns.Bugs.Record(tostring(err), stack, true)
		ns.Log("ERROR npc work: %s", tostring(err))
	end,
})

-- Runs fn as a job of the NPC work (at once when nothing waits ahead of it).
local function npcJob(fn) ns.npcWork:Run(fn) end

local npcAdapter = {
	now = function() return GetTime() end,
	after = function(delay, fn) C_Timer.After(delay, function() ns.Bugs.Call(fn) end) end,
	random = function() return math.random() end,
	canSend = function() return ns.guildKey ~= nil and ns.SendBlockReason() == nil end,
	send = function(msg, done) Comm.SendNpc(msg, done) end,
	selfGuid = function() return UnitGUID("player") end,
	faction = function() return ns.npcFaction end,
	changed = function() ns.NoteNpcSkills() ns.OnDataChanged() end,
	isMe = function(name) return type(name) == "string" and ns.NormalizeName(name) == UnitName("player") end,
	size = function(msg) return #Comm.EncodeNpc(msg) end,
}

local function npcClock() return GetServerTime() end

local function playerFaction()
	if type(UnitFactionGroup) ~= "function" then return nil end
	local ok, faction = pcall(UnitFactionGroup, "player")
	if ok and type(faction) == "string" and faction ~= "" then return faction end
	return nil
end

-- The tables were loaded (or a part of their work is done): the window and the skill revision
-- follow.
local function npcLoaded()
	ns.NoteNpcSkills()
	ns.OnDataChanged()
end

-- Makes what is missing: npcOwn of the faction, and with a guild its table and sync (npcOwn imported
-- into it, so nothing learned in another guild comes in). Called at login, at guild events and
-- readings; does nothing while the faction is unknown.
function ns.SetupNpc()
	if not ns.db then return end
	local faction = playerFaction()
	if not faction then return end
	if ns.npcFaction ~= faction then
		-- first time, or the faction changed (a pandaren chose one): the other faction's tables go
		if ns.npcSync then ns.npcSync:Stop() end
		ns.npcSync, ns.npcGuild = nil, nil
		if type(ns.db.npcOwn) ~= "table" then ns.db.npcOwn = {} end
		if type(ns.db.npcOwn[faction]) ~= "table" then ns.db.npcOwn[faction] = {} end
		ns.npcOwn = NpcData.New(ns.db.npcOwn[faction], npcClock, nil, ns.npcWork)
		npcJob(npcLoaded)
		ns.npcFaction = faction
	end
	if ns.guildDB and not ns.npcGuild then
		if type(ns.guildDB.npc) ~= "table" then ns.guildDB.npc = {} end
		if type(ns.guildDB.npc[faction]) ~= "table" then ns.guildDB.npc[faction] = {} end
		-- loads in slices (NpcWork); the import and NpcSync's work queue behind the loading
		local tab = NpcData.New(ns.guildDB.npc[faction], npcClock, nil, ns.npcWork)
		local own = ns.npcOwn
		npcJob(function() tab:Import(own) end)
		npcJob(npcLoaded)
		ns.npcGuild = tab
		ns.npcSync = NpcSync.New(npcAdapter, tab)
		-- made after the login hello (the faction was not known then): its ND need not wait 900 s
		if ns.loginHelloPassed then ns.npcSync:Announce() end
	end
	local shown = ns.npc
	ns.npc = ns.npcGuild or ns.npcOwn
	if ns.npc ~= shown then ns.NoteNpcSkills() end
end

-- ns.npcSkillRevision: raised when a learn skill the window shows could have changed, so that the
-- Leveling list (sorted by it) is rebuilt then and not at every sheet. Each table keeps skillRev,
-- raised when the skill registers (recipe, skill, its day) of a sheet's trainer entries changed
-- (NpcTable); so this costs nothing per sheet, also with a full table.
local skillKey = nil

function ns.NoteNpcSkills()
	local key = tostring(ns.npc) .. tostring(ns.npcOwn)
	for _, tab in ipairs({ ns.npc or false, ns.npcOwn or false }) do
		if tab then key = key .. ":" .. tostring(tab.skillRev) end
	end
	if key ~= skillKey then
		skillKey = key
		ns.npcSkillRevision = (ns.npcSkillRevision or 0) + 1
	end
end

-- A reading of a trainer or vendor (NpcReader): npcOwn takes it as the last known reading; the
-- guild's table takes it by the own-visit rules and NpcSync sends what changed. A job of the NPC
-- work: while the tables load the reading waits its turn.
local function onNpcReading(npcID, reading)
	ns.SetupNpc()
	local own, sync = ns.npcOwn, ns.npcSync
	npcJob(function()
		if own and own == ns.npcOwn and own:Write(npcID, reading) then ns.NoteNpcSkills() ns.OnDataChanged() end
		if sync and sync == ns.npcSync then sync:OwnVisit(npcID, reading) end
	end)
end

-- Name of a guildmate for the window: roster name without the realm, then the sender name.
function ns.MemberName(guid)
	if guid == UnitGUID("player") then return UnitName("player") end
	local entry = ns.store and ns.store:RosterEntry(guid)
	local name = entry and entry.name or (ns.guildDB and ns.guildDB.names and ns.guildDB.names[guid])
	if not name then
		local rec = ns.store and ns.store:Get(guid)
		name = rec and rec.n
	end
	return name and (name:gsub("%-.*$", "")) or "?"
end

-- Sends a hello and, when it went out, the digests of the recipe catalog and of the guild
-- prices after it. Returns what Sync:Hello returned.
function ns.Hello(force)
	if not ns.sync then return false end
	local sent = ns.sync:Hello(force)
	if sent and ns.catalog then ns.catalog:Announce() end
	if sent and ns.guildPrices then ns.guildPrices:Announce() end
	if sent and ns.requests then ns.requests:Announce() end
	if sent and ns.reports then ns.reports:Announce() end
	-- also while sending is blocked: NpcSync sends a due ND once the block ends
	if sent and ns.npcSync then ns.npcSync:Announce() end
	return sent
end

-- (Re)creates the store and sync for the current guild. Called on login and guild changes.
function ns.SetupGuild()
	local key, guildName, realm = Scanner.GuildKey()
	if key == ns.guildKey then
		-- npcOwn (and the guild's table) wait for the faction; a guild event tries again
		ns.SetupNpc()
		return
	end
	ns.guildKey, ns.guildName = key, guildName
	-- the old guild's prices must not reach the new guild (its timers may still run)
	if ns.guildPrices then ns.guildPrices:Stop() end
	if ns.requests then ns.requests:Stop() end
	if ns.reports then ns.reports:Stop() end
	if ns.npcSync then ns.npcSync:Stop() end
	ns.npcSync, ns.npcGuild = nil, nil
	receiverSeen.at, receiverSeen.value = -1e9, false
	if not key then
		ns.store, ns.sync, ns.guildDB, ns.guildPrices, ns.requests, ns.reports = nil, nil, nil, nil, nil, nil
		ns.SetupNpc()
		ns.OnDataChanged()
		return
	end
	if type(ns.db.guilds[key]) ~= "table" then ns.db.guilds[key] = {} end
	-- older versions saved the guild under "name@realm"; join those databases into this one
	local prefix = key .. "@"
	for oldKey, data in pairs(ns.db.guilds) do
		if type(oldKey) == "string" and oldKey ~= key and oldKey:sub(1, #prefix) == prefix and type(data) == "table" then
			local taken = Store.MergeGuildData(ns.db.guilds[key], data)
			ns.db.guilds[oldKey] = nil
			ns.Log("guild data saved as \"%s\" joined: %d records", oldKey, taken)
		end
	end
	ns.Log("guild %s, realm reported now: %s", key, tostring(realm))
	ns.guildDB = ns.db.guilds[key]
	if type(ns.guildDB.names) ~= "table" then ns.guildDB.names = {} end
	ns.store = Store.New(ns.guildDB)
	ns.sync = Sync.New(adapter, ns.store, ns.version)
	-- auction prices shared in this guild (GuildPrices.lua); old ones are dropped
	ns.guildPrices = GuildPrices.New(pricesAdapter, ns.guildDB)
	local dropped = ns.guildPrices:Prune()
	if dropped > 0 then ns.Log("guild prices: %d older than 14 days dropped", dropped) end
	-- item requests of this guild (Requests.lua)
	ns.requests = Requests.New(requestsAdapter, ns.guildDB)
	ns.requests:Prune()
	-- bug reports carried to the author (Reports.lua)
	ns.reports = Reports.New(reportsAdapter, ns.guildDB)
	ns.reports:Prune()
	ns.reports:TakeHeld()
	ns.CheckReports()
	-- trainers and vendors of this guild and faction, npcOwn imported (NpcData, NpcSync)
	ns.SetupNpc()
	if not ns.Prices.StartSharing() then
		-- Auctionator may still be setting up its database
		C_Timer.After(10, function() ns.Prices.StartSharing() end)
	end
	Scanner.RequestRoster()
	ns.RefreshOwn()
	local d = ns.Config.loginHelloDelay
	C_Timer.After(d[1] + math.random() * (d[2] - d[1]), function()
		ns.loginHelloPassed = true
		ns.Hello(true)
	end)
	ns.OnDataChanged()
end

function ns.OnRosterUpdate()
	ns.SetupNpc()
	-- the author may be in a roster that was not read yet at login: read again (at most every
	-- 5 s; an event inside that time is looked at when it ends). ReceiverInGuild sends what waits.
	if not receiverSeen.value and not receiverSeen.recheck then
		local wait = 5 - (GetTime() - receiverSeen.at)
		if wait <= 0 then
			receiverSeen.at = -1e9
			ns.ReceiverInGuild()
		else
			receiverSeen.recheck = true
			C_Timer.After(wait, function()
				receiverSeen.recheck = false
				if not receiverSeen.value then
					receiverSeen.at = -1e9
					ns.Bugs.Call(ns.ReceiverInGuild)
				end
			end)
		end
	end
	if not ns.store then return end
	local entries, complete, namesComplete = Scanner.ReadRoster()
	if #entries == 0 then return end
	-- a read that did not return every member only updates the members it returned
	ns.store:SetRoster(entries, ns.NormalizeName, not namesComplete)
	ns.rosterHasGuids = complete
	local myGuid = UnitGUID("player")
	local keep = { [myGuid or ""] = true }
	if complete then
		local set = {}
		for _, e in ipairs(entries) do set[e.guid] = true end
		local removed = ns.store:PruneToRoster(set, keep)
		if #removed > 0 then ns.Debug("removed %d former members", #removed) end
	elseif namesComplete then
		-- the roster has no GUIDs on this client: fall back to names
		local names = {}
		for _, e in ipairs(entries) do names[ns.NormalizeName(e.name)] = true end
		local removed, why = ns.store:PruneToRosterNames(names, ns.NormalizeName, keep, myGuid)
		ns.rosterPruneByName = removed and "on" or ("off: " .. tostring(why))
		if removed and #removed > 0 then
			ns.Debug("removed %d former members (by name)", #removed)
		elseif not removed then
			ns.Debug("roster has no GUIDs, not pruning by name: %s", tostring(why))
		end
	end
	-- our display name may now come from the roster
	local own, guid = ownState()
	if own and own.rec and own.rec.n ~= ownDisplayName(guid) then ns.ScheduleRefresh(2) end
	ns.OnDataChanged()
end

---------------------------------------------------------------------------
-- Recipes
---------------------------------------------------------------------------

-- The profession window or a learned recipe may report a different skill line ID than
-- GetProfessions (e.g. a tier of the profession). Map it to the profession we publish.
local function resolveSkillLine(own, id)
	if not id or not own.profs or own.profs[id] then return id end
	local name = Scanner.ProfessionName(id)
	for skillLine in pairs(own.profs) do
		if Scanner.ProfessionName(skillLine) == name then
			ns.Debug("skill line %d mapped to %d (%s)", id, skillLine, name)
			return skillLine
		end
	end
	return id
end
ns.ResolveSkillLine = resolveSkillLine

local scanToken = 0
local function scheduleScan()
	scanToken = scanToken + 1
	local token = scanToken
	C_Timer.After(1, function()
		if token ~= scanToken then return end
		-- timer callbacks are not protected like event handlers: an error is logged, not lost
		local ok, err = ns.Bugs.Call(ns.ScanNow)
		if not ok then
			ns.lastError = "scan: " .. tostring(err)
			ns.Log("ERROR %s", ns.lastError)
			ns.Print("%s", ns.lastError)
		end
	end)
end

-- Reads the open profession window: own recipes, reagents and the recipe catalog.
function ns.ScanNow()
	do
		local skillLine, recipes, count, reagents, listInfo = Scanner.ScanOpenProfession()
		if not skillLine then
			ns.Debug("scan skipped: %s", tostring(recipes))
			return
		end
		local own = ownState()
		if not own then return end
		skillLine = resolveSkillLine(own, skillLine)
		-- every recipe of the window, learned or not, goes to the recipe catalog
		if ns.catalog and listInfo and next(listInfo.all) then
			local added = ns.catalog:Add(skillLine, listInfo.all)
			if added > 0 then ns.Log("catalog %s: %d recipes added", Scanner.ProfessionName(skillLine), added) end
		end
		if listInfo then
			for recipeID, grey in pairs(listInfo.trivial) do
				local info = ns.db.recipeInfo[recipeID] or {}
				info.g = grey
				ns.db.recipeInfo[recipeID] = info
			end
			ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
			-- colour of each own recipe for this character (not published)
			own.colors = own.colors or {}
			for recipeID, difficulty in pairs(listInfo.difficulty) do own.colors[recipeID] = difficulty end
		end
		-- never replace a known list with an empty one (data not loaded yet)
		local old = own.recipes and own.recipes[skillLine]
		if count == 0 and old and next(old) then return end
		local wasScanned = own.scanned and own.scanned[skillLine]
		local oldCount = 0
		for _ in pairs(old or {}) do oldCount = oldCount + 1 end
		Store.SetScannedRecipes(own, skillLine, recipes)
		local withReagents = 0
		for _ in pairs(reagents or {}) do withReagents = withReagents + 1 end
		ns.Log("scan %s (%s): %d recipes, %d with reagents", Scanner.ProfessionName(skillLine), tostring(skillLine), count, withReagents)
		if listInfo then
			ns.Log("scan %s: recipe list %d ids, %d not learned; %s", Scanner.ProfessionName(skillLine),
				listInfo.total, listInfo.unlearned, table.concat(listInfo.samples, "; "))
		end
		if ns.reagents then
			for recipeID, list in pairs(reagents or {}) do ns.reagents:Set(recipeID, list) end
		end
		if not wasScanned or oldCount ~= count then
			ns.Say("SCANNED", Scanner.ProfessionName(skillLine), count)
		end
		ns.ScheduleRefresh()
	end
end

local learnedNames = {}
local learnedToken = 0
local function onRecipeLearned(recipeID)
	if type(recipeID) ~= "number" then return end
	local own = ownState()
	if not own then return end
	local skillLine = resolveSkillLine(own, Scanner.ProfessionForRecipe(recipeID))
	if not Store.AddLearnedRecipe(own, skillLine, recipeID, Scanner.RecipeOutputItem(recipeID)) then
		ns.Debug("learned recipe %d: profession unknown, waiting for the next window scan", recipeID)
		return
	end
	if ns.reagents then ns.reagents:Set(recipeID, Scanner.RecipeReagents(recipeID)) end
	learnedNames[#learnedNames + 1] = Scanner.RecipeName(recipeID) or tostring(recipeID)
	learnedToken = learnedToken + 1
	local token = learnedToken
	C_Timer.After(2, function()
		if token ~= learnedToken then return end
		local shown = {}
		for i = 1, math.min(5, #learnedNames) do shown[i] = learnedNames[i] end
		local text = table.concat(shown, ", ")
		if #learnedNames > 5 then text = text .. " …" end
		learnedNames = {}
		ns.Say("LEARNED", text)
	end)
	ns.ScheduleRefresh()
end

---------------------------------------------------------------------------
-- Status and diagnostics
---------------------------------------------------------------------------

local function ago(t)
	if not t or t < 0 then return ns.T("NEVER") end
	return ns.T("SECONDS_AGO", math.floor(GetTime() - t))
end

function ns.Status()
	ns.Say("STATUS_HEADER", ns.version)
	if not ns.store then
		ns.Say("NO_GUILD")
		return
	end
	ns.Say("STATUS_GUILD", ns.guildName or "?")
	local total, stale = 0, 0
	for guid in pairs(ns.store:All()) do
		total = total + 1
		if ns.store:IsStale(guid, ns.StaleDays(), GetServerTime()) then stale = stale + 1 end
	end
	ns.Say("STATUS_RECORDS", total, stale)
	ns.Say("STATUS_PEERS", ns.sync:ActivePeers(1200))
	local own = ownState()
	local profs = {}
	for skillLine, info in pairs(own and own.profs or {}) do
		local n = 0
		for _ in pairs(own.recipes and own.recipes[skillLine] or {}) do n = n + 1 end
		local scanned = own.scanned and own.scanned[skillLine]
		profs[#profs + 1] = string.format("%s %d/%d (%s)", Scanner.ProfessionName(skillLine), info.s, info.m,
			scanned and ns.T("MEMBER_RECIPES", n) or ns.T("NOT_SCANNED"))
	end
	ns.Say("STATUS_OWN", own and own.v or 0, #profs > 0 and table.concat(profs, ", ") or "-")
	local reason = ns.SendBlockReason()
	ns.Say("STATUS_SEND", reason and ns.T(reason) or ns.T("STATUS_SEND_OK"))
	ns.Say("STATUS_QUEUE", ns.sync:OutboxSize())
	local s = ns.sync.stats
	ns.Say("STATUS_TRAFFIC", s.sentH, s.sentR, s.sentD, s.recvH, s.recvR, s.recvD, s.applied)
	ns.Say("STATUS_LAST_HELLO", ago(ns.sync.lastHello))
	if ns.reagents then
		local r = ns.reagents.stats
		ns.Say("STATUS_REAGENTS", ns.reagents:Count(), r.sentQ, r.sentC, r.recvQ, r.recvC, r.learned)
	end
	if ns.catalog then
		local recipes, profs = ns.catalog:Total()
		local k = ns.catalog.stats
		ns.Say("STATUS_CATALOG", recipes, profs, k.sentD, k.sentR, k.sentL, k.recvD, k.recvR, k.recvL)
	end
	if ns.requests then
		local open, taken = 0, 0
		for _, rec in ipairs(ns.requests:All()) do
			if not ns.requests:_Hidden(rec) then
				if rec.st == "open" then open = open + 1 elseif rec.st == "taken" then taken = taken + 1 end
			end
		end
		local s3 = ns.requests.stats
		ns.Say("STATUS_REQUESTS", open, taken, s3.sentU, s3.sentD, s3.sentR, s3.recvU, s3.recvD, s3.recvR)
	end
	if ns.reports then
		local s4 = ns.reports.stats
		ns.Say("STATUS_REPORTS", ns.reports:HeldCount(), ns.reports:MarkCount(),
			ns.ReceiverInGuild() and ns.T("YES") or ns.T("NO"), s4.sentU, s4.sentD, s4.sentR, s4.recvU, s4.recvD, s4.recvR)
	end
	if ns.npc then
		local sheets, entries = ns.npc:Count()
		local s5 = ns.npcSync and ns.npcSync.stats or { sent = {}, recv = {} }
		local function n(list, t) return list[t] or 0 end
		ns.Say("STATUS_NPC", sheets, entries, n(s5.sent, "ND"), n(s5.sent, "NI"), n(s5.sent, "NR"), n(s5.sent, "NU"),
			n(s5.recv, "ND"), n(s5.recv, "NI"), n(s5.recv, "NR"), n(s5.recv, "NU"))
	end
	if ns.guildPrices then
		local gp, s2 = ns.guildPrices, ns.guildPrices.stats
		local newest = gp:Newest()
		ns.Say("STATUS_GUILD_PRICES", gp:Count(), newest > 0 and ns.Prices.AgoText(newest) or "-",
			s2.recorded, s2.sentU, s2.sentD, s2.sentR, s2.recvU, s2.recvD, s2.recvR)
	end
	local source = ns.Prices and ns.Prices.Source()
	ns.Say("STATUS_PRICES", source == "Guild" and ns.T("PRICE_SOURCE_GUILD") or source or ns.T("NO_PRICES"))
	if ns.sync.newerProtocolSeen then ns.Say("NEWER_VERSION") end
	if ns.newerVersion then ns.Say("UPDATE_AVAILABLE", ns.newerVersion, tostring(ns.version)) end
	if ns.lastError then ns.Print("Last error: %s", ns.lastError) end
end

local function describe(v)
	if type(v) == "table" then
		local parts, n = {}, 0
		for k, x in pairs(v) do
			n = n + 1
			if n > 12 then parts[#parts + 1] = "…" break end
			parts[#parts + 1] = tostring(k) .. "=" .. tostring(x)
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(v)
end

-- Prints what the game API really returns on this client and saves it to SavedVariables.
-- silent: only saves (automatic run after login), nothing is printed.
function ns.DebugDump(silent)
	local lines = {}
	local function add(fmt, ...)
		local args, n = { ... }, select("#", ...)
		if n == 0 then lines[#lines + 1] = tostring(fmt) return end
		for i = 1, n do
			if type(args[i]) ~= "number" then args[i] = tostring(args[i]) end
		end
		local ok, text = pcall(string.format, fmt, unpack(args, 1, n))
		lines[#lines + 1] = ok and text or (tostring(fmt) .. " [format error]")
	end
	local function exists(path, t, key) add("%s: %s", path, type(t) == "table" and type(t[key]) or "missing") end
	-- Each section is protected: an API that errors on this client is reported, not fatal.
	local function section(name, fn)
		local ok, err = pcall(fn)
		if not ok then add("%s: ERROR %s", name, tostring(err)) end
	end

	section("Client", function()
		local version, build, date, interface = GetBuildInfo()
		add("Profguild %s, client %s (%s) %s, interface %s, lang %s", ns.version, version, build, date, interface, GetLocale())
		add("UnitGUID=%s UnitName=%s", UnitGUID("player"), UnitName("player"))
		if UnitFullName then add("UnitFullName=%s", describe({ UnitFullName("player") })) end
	end)

	section("GetProfessions", function()
		if GetProfessions then
			local list = { GetProfessions() }
			add("GetProfessions -> %s", describe(list))
			for i = 1, 8 do
				if list[i] then
					section("  GetProfessionInfo(" .. tostring(list[i]) .. ")", function()
						add("  GetProfessionInfo(%d) -> %s", list[i], describe({ GetProfessionInfo(list[i]) }))
					end)
				end
			end
		else
			add("GetProfessions: missing")
		end
	end)

	section("GetAllProfessionTradeSkillLines", function()
		if not (C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines) then
			add("GetAllProfessionTradeSkillLines: missing")
			return
		end
		local ok, ids = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
		add("GetAllProfessionTradeSkillLines -> %s", ok and describe(ids) or ids)
		if ok and type(ids) == "table" then
			for _, id in ipairs(ids) do
				local ok2, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, id)
				if not ok2 then
					add("  skillLine %s: ERROR %s", id, info)
				elseif type(info) == "table" and (info.skillLevel or 0) > 0 then
					add("  skillLine %s: %s %s/%s parent=%s", id, info.professionName, info.skillLevel or 0, info.maxSkillLevel or 0, info.parentProfessionID)
				end
			end
		end
	end)

	section("Snapshot", function()
		local snap = Scanner.Snapshot()
		local t = {}
		for k, v in pairs(snap.profs) do t[k] = tostring(v.s) .. "/" .. tostring(v.m) end
		add("Snapshot ok=%s profs=%s sources=%s", snap.ok, describe(t), describe(snap.sources))
	end)

	section("Guild", function()
		local guildKey, _, guildRealm = Scanner.GuildKey()
		add("IsInGuild=%s GuildKey=%s realm reported now=%s", IsInGuild(), tostring(guildKey), tostring(guildRealm))
		if IsInGuild() and GetNumGuildMembers then
			local total, online = GetNumGuildMembers()
			add("GetNumGuildMembers -> %s total, %s online", total, online)
			if GetGuildRosterInfo then
				local row = { GetGuildRosterInfo(1) }
				add("Roster row 1: name=%s guid=%s", row[1], row[17])
			end
			if GetGuildRosterLastOnline then add("GetGuildRosterLastOnline(1) -> %s", describe({ GetGuildRosterLastOnline(1) })) end
			add("Roster GUIDs complete: %s", ns.rosterHasGuids)
			if ns.rosterPruneByName then add("Roster prune by name: %s", ns.rosterPruneByName) end
		end
		if ns.guildDB and ns.guildDB.names then
			local n = 0
			for guid, sender in pairs(ns.guildDB.names) do
				n = n + 1
				if n <= 3 then add("Addon sender name for %s: %s", guid, sender) end
			end
		end
	end)

	section("API", function()
		exists("C_TradeSkillUI.GetTradeSkillLineForRecipe", C_TradeSkillUI, "GetTradeSkillLineForRecipe")
		exists("C_TradeSkillUI.GetRecipeSchematic", C_TradeSkillUI, "GetRecipeSchematic")
		exists("C_TradeSkillUI.GetAllRecipeIDs", C_TradeSkillUI, "GetAllRecipeIDs")
		exists("C_TradeSkillUI.GetRecipeSourceText", C_TradeSkillUI, "GetRecipeSourceText")
		exists("C_ChatInfo.InChatMessagingLockdown", C_ChatInfo, "InChatMessagingLockdown")
		exists("ChatFrameUtil.SendTell", ChatFrameUtil, "SendTell")
		exists("ChatFrameUtil.OpenChat", ChatFrameUtil, "OpenChat")
		exists("ChatFrameUtil.InsertLink", ChatFrameUtil, "InsertLink")
		add("ChatFrame_SendTell: %s, ChatFrame_OpenChat: %s, ChatEdit_InsertLink: %s",
			type(ChatFrame_SendTell), type(ChatFrame_OpenChat), type(ChatEdit_InsertLink))
		add("TooltipDataProcessor: %s", type(TooltipDataProcessor))
		add("AddonCompartmentFrame: %s", type(AddonCompartmentFrame))
		add("Price source: %s, Auctionator shopping lists: %s", tostring(ns.Prices.Source()), tostring(ns.Prices.CanShop()))
		add("Enum.CraftingReagentType: %s", describe(Enum and Enum.CraftingReagentType))
		add("Minimap: %s, minimap button: %s", type(Minimap), tostring(ns.Minimap.button ~= nil))
		add("Trial=%s Veteran=%s", IsTrialAccount and IsTrialAccount(), IsVeteranTrialAccount and IsVeteranTrialAccount())
	end)

	section("Reagents", function()
		add("Reagent catalog: %d recipes", ns.reagents and ns.reagents:Count() or 0)
		-- can the game read reagents of recipes this character does not know?
		local own = ownState()
		local mine = {}
		for _, list in pairs(own and own.recipes or {}) do
			for id in pairs(list) do mine[id] = true end
		end
		local tried, found, sample = 0, 0, nil
		for id in pairs(ns.store and ns.store:Index().recipes or {}) do
			if not mine[id] then
				tried = tried + 1
				local list = Scanner.RecipeReagents(id)
				if list then
					found = found + 1
					sample = sample or (tostring(id) .. " " .. describe(list))
				end
				if tried >= 20 then break end
			end
		end
		add("Reagents of guildmates' recipes from the game: %d of %d (sample %s)", found, tried, tostring(sample))
		-- own recipes while no profession window is open
		local ownTried, ownFound = 0, 0
		for id in pairs(mine) do
			ownTried = ownTried + 1
			if Scanner.RecipeReagents(id) then ownFound = ownFound + 1 end
			if ownTried >= 20 then break end
		end
		add("Reagents of own recipes from the game (window %s): %d of %d",
			ProfessionsFrame and ProfessionsFrame:IsShown() and "open" or "closed?", ownFound, ownTried)
		-- well-known classic recipes of every profession (spell IDs); Forever may use other IDs
		local probes = {
			{ 3275, "Linen Bandage" }, { 2538, "Charred Wolf Meat" }, { 2329, "Elixir of Lion's Strength" },
			{ 2660, "Rough Sharpening Stone" }, { 2963, "Bolt of Linen Cloth" }, { 2881, "Light Leather" },
			{ 3918, "Rough Blasting Powder" }, { 7418, "Enchant Bracer - Minor Health" }, { 2657, "Smelt Copper" },
		}
		local parts = {}
		for _, probe in ipairs(probes) do
			local id = probe[1]
			local list = Scanner.RecipeReagents(id)
			parts[#parts + 1] = string.format("%d %s=%s%s", id, probe[2], list and describe(list) or "-",
				mine[id] and " (own)" or "")
		end
		add("Known recipes from the game: %s", table.concat(parts, "; "))
	end)

	section("Recipe list", function()
		local li = Scanner.lastListInfo
		if li then
			add("Last profession window: %d recipe ids, %d not learned; %s", li.total, li.unlearned, table.concat(li.samples, "; "))
			for _, kind in ipairs({ "learned", "unlearned" }) do
				if li.fields and li.fields[kind] then add("Recipe fields (%s): %s", kind, li.fields[kind]) end
			end
		else
			add("Last profession window: none opened in this session")
		end
		if ns.catalog then
			local parts = {}
			for skillLine, n in pairs(ns.catalog:Digest()) do
				parts[#parts + 1] = Scanner.ProfessionName(skillLine) .. "=" .. n
			end
			table.sort(parts)
			add("Recipe catalog: %s", #parts > 0 and table.concat(parts, ", ") or "empty")
		end
	end)

	section("Own recipes", function()
		local own = ownState()
		if own and own.recipes then
			for skillLine, list in pairs(own.recipes) do
				local sample
				for id, item in pairs(list) do sample = tostring(id) .. "->" .. tostring(item) break end
				add("Own recipes %s: sample %s", skillLine, sample)
			end
		end
	end)

	if not silent then
		for _, line in ipairs(lines) do DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa" .. line .. "|r") end
	end
	local okDate, now = pcall(date, "%Y-%m-%d %H:%M:%S")
	ns.db.debug = { time = okDate and tostring(now) or "", at = GetServerTime(), lines = lines }
	ns.Log("debug dump saved (%d lines)%s", #lines, silent and ", automatic" or "")
	if not silent then ns.Say("DEBUG_SAVED") end
end

---------------------------------------------------------------------------
-- Manual sync with a result message
---------------------------------------------------------------------------

local function recipeCount(rec)
	local n = 0
	for _, prof in pairs(rec and rec.p or {}) do
		for _ in pairs(prof.r or {}) do n = n + 1 end
	end
	return n
end

-- Says what the sync brought: every character whose record is new or changed, with the
-- number of recipes that were added.
local function reportSync(report)
	local items, me = {}, UnitGUID("player")
	for guid in pairs(report.changed) do
		local rec = ns.store and ns.store:Get(guid)
		if rec and guid ~= me then
			local name, now, before = ns.DisplayName(guid, rec), recipeCount(rec), report.before[guid]
			if before == nil then
				items[#items + 1] = ns.T("SYNC_ITEM_NEW", name, now)
			elseif now > before then
				items[#items + 1] = ns.T("SYNC_ITEM_MORE", name, now - before)
			else
				items[#items + 1] = ns.T("SYNC_ITEM_CHANGED", name)
			end
		end
	end
	if #items == 0 then return ns.Say("SYNC_DONE_NONE") end
	table.sort(items)
	local shown = {}
	for i = 1, math.min(6, #items) do shown[i] = items[i] end
	local text = table.concat(shown, ", ")
	if #items > 6 then text = text .. " " .. ns.T("SYNC_MORE", #items - 6) end
	ns.Say("SYNC_DONE", #items, text)
end

-- /pg sync and the Sync button: asks the guild for updates, then reports what arrived.
-- The protocol has no "finished" message, so the sync counts as finished when nothing new
-- arrived for a while and no requested record is outstanding.
function ns.SyncNow()
	if not ns.sync then return ns.Say("NO_GUILD") end
	if ns.syncReport then return ns.Say("SYNC_RUNNING") end
	Scanner.RequestRoster()
	ns.RefreshOwn()
	local reason = ns.SendBlockReason()
	if not ns.Hello(true) then return ns.Say("SYNC_TOO_SOON") end
	if reason then return ns.Say("SYNC_BLOCKED", ns.T(reason)) end
	ns.Say("SYNC_STARTED")
	local before = {}
	for guid, rec in pairs(ns.store:All()) do before[guid] = recipeCount(rec) end
	local started = GetTime()
	local report = { started = started, last = started, before = before, changed = {}, sync = ns.sync }
	ns.syncReport = report
	local cfg = ns.Config
	local function check()
		if ns.syncReport ~= report then return end
		local now = GetTime()
		local waiting = ns.sync == report.sync and next(ns.sync.wanted) ~= nil
		local quiet = now - report.last >= cfg.syncQuiet and not waiting
		if ns.sync ~= report.sync or now - started >= cfg.syncMaxWait or (now - started >= cfg.syncMinWait and quiet) then
			ns.syncReport = nil
			reportSync(report)
		else
			C_Timer.After(1, check)
		end
	end
	C_Timer.After(1, check)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function slash(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "" then
		if ns.UI then ns.UI:Toggle() end
	elseif cmd == "sync" then
		ns.SyncNow()
	elseif cmd == "status" then
		ns.Status()
	elseif cmd == "catalog" then
		-- /pg catalog clear [profession]: forget the recipe catalog (all, or one profession by name)
		local sub, name = rest:match("^(%S*)%s*(.-)$")
		if sub ~= "clear" or not ns.catalog then return ns.Say("CATALOG_USAGE") end
		local cleared = 0
		ns.seedOff = true
		for skillLine in pairs(ns.catalog:All()) do
			if name == "" or Scanner.ProfessionName(skillLine):lower() == name:lower() then
				ns.catalog:Remove(skillLine)
				cleared = cleared + 1
			end
		end
		ns.Say("CATALOG_CLEARED", cleared)
		ns.OnDataChanged()
	elseif cmd == "npc" then
		-- /pg npc: what is known of trainers and vendors; /pg npc clear: forget it for this faction
		ns.SetupNpc()
		if rest ~= "" and rest ~= "clear" then return ns.Say("NPC_USAGE") end
		if not ns.npcOwn then return ns.Say("NPC_NO_FACTION") end
		if rest == "clear" then
			-- a job: after the loading and merges queued before it
			local own, guild, sync = ns.npcOwn, ns.npcGuild, ns.npcSync
			npcJob(function()
				own:Clear()
				if guild then guild:Clear() end
				-- the guild's comes back from guildmates
				if sync then sync:Announce() end
				ns.NoteNpcSkills()
				ns.OnDataChanged()
			end)
			ns.Say("NPC_CLEARED", ns.npcFaction)
			return
		end
		local ownSheets, ownEntries = ns.npcOwn:Count()
		local skipped = ns.npcReader and ns.npcReader.skipped or 0
		if ns.npcGuild then
			local sheets, entries = ns.npcGuild:Count()
			ns.Say("NPC_COUNTS_GUILD", ns.npcFaction, sheets, entries, ownSheets, ownEntries, skipped)
		else
			ns.Say("NPC_COUNTS_OWN", ns.npcFaction, ownSheets, ownEntries, skipped)
		end
	elseif cmd == "scan" then
		-- reads the open profession window now, without waiting for an event of the game
		Scanner.lastListInfo = nil
		local ok, err = ns.Bugs.Call(ns.ScanNow)
		if not ok then ns.Print("scan: %s", tostring(err)) end
		local li = Scanner.lastListInfo
		if li then ns.Say("SCAN_RESULT", li.total, li.unlearned) else ns.Say("SCAN_NONE") end
	elseif cmd == "debug" then
		if rest == "on" or rest == "off" then
			ns.db.settings.debug = rest == "on"
		else
			ns.DebugDump()
		end
	elseif cmd == "lang" then
		if ns.SetLanguage(rest) then
			ns.db.settings.lang = rest
			ns.Say("LANG_SET")
			if ns.UI and ns.UI.OnLanguageChanged then ns.UI:OnLanguageChanged() end
		else
			ns.Say("LANG_USAGE")
		end
	elseif cmd == "bug" then
		ns.Bugs.Slash(rest)
	elseif cmd == "minimap" then
		if ns.Minimap:Toggle() then ns.Say("MINIMAP_SHOWN") else ns.Say("MINIMAP_HIDDEN") end
	elseif cmd == "reset" then
		if rest ~= "confirm" then return ns.Say("RESET_CONFIRM") end
		if not ns.store then return ns.Say("NO_GUILD") end
		local keep = {}
		for guid in pairs(ns.db.own) do keep[guid] = true end
		ns.store:Clear(keep)
		ns.RefreshOwn()
		ns.sync.lastHello = -1e9
		ns.Hello(true)
		ns.Say("RESET_DONE")
		ns.OnDataChanged()
	else
		ns.Say("HELP")
	end
end

SLASH_PROFGUILD1 = "/pg"
SLASH_PROFGUILD2 = "/profguild"
SlashCmdList.PROFGUILD = slash

-- Addon compartment (the addon list button near the minimap)
function Profguild_OnAddonCompartmentClick()
	if ns.UI then ns.UI:Toggle() end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local events = {}

local function flushSoon()
	C_Timer.After(3, function()
		if ns.sync and ns.SendBlockReason() == nil then
			local n = ns.sync:Flush()
			if n > 0 then ns.Debug("flushed %d queued messages", n) end
		end
	end)
end

function events.ADDON_LOADED(name)
	if name ~= ADDON then return end
	initDB()
	ns.reagents = Reagents.New(reagentAdapter, ns.db.reagents)
	ns.catalog = Catalog.New(catalogAdapter, ns.db.catalog)
	Comm:Init()
	if ns.Tooltip then ns.Tooltip:Init() end
	frame:UnregisterEvent("ADDON_LOADED")
end

-- The game saves after this: NPC work still queued runs to its end now (a half loaded table, or
-- a reading waiting for the loading, would else be left out of the saved data).
function events.PLAYER_LOGOUT()
	ns.npcWork:Flush()
end

function events.PLAYER_LOGIN()
	-- BugGrabber may only offer its callbacks once the addons are loaded
	if not ns.Bugs.hooked then ns.Bugs.InstallErrorHook() end
	ns.Say("ADDON_LOADED", ns.version)
	ns.Minimap:Init()
	C_Timer.After(5, function()
		ns.SetupGuild()
		if not ns.guildKey then ns.Debug("not in a guild") end
	end)
	-- second snapshot: professions removed only when two snapshots agree
	C_Timer.After(60, function() ns.RefreshOwn() end)
	-- diagnostics land in SavedVariables without typing /pg debug
	ns.Log("login, version %s", tostring(ns.version))
	C_Timer.After(20, ns.SeedCatalog) -- once the login rush is over
	C_Timer.After(45, function() ns.DebugDump(true) end)
	C_Timer.NewTicker(ns.Config.helloInterval, function() ns.Hello(false) end)
	C_Timer.NewTicker(ns.Config.rosterInterval, function()
		if IsInGuild() then Scanner.RequestRoster() end
	end)
end

-- Auctionator may have made a new database (a reset): follow its readings again.
function events.AUCTION_HOUSE_SHOW()
	if ns.guildPrices then ns.Prices.StartSharing() end
end

function events.PLAYER_GUILD_UPDATE(unit)
	if unit and unit ~= "player" then return end
	C_Timer.After(2, ns.SetupGuild)
end

-- The event fires on every login, logout and zone change of any member, often several times
-- in a row. The roster is read once, a second after the first of them.
local rosterPending = false
function events.GUILD_ROSTER_UPDATE()
	if not ns.store then
		C_Timer.After(1, ns.SetupGuild)
		return
	end
	if rosterPending then return end
	rosterPending = true
	C_Timer.After(1, function()
		rosterPending = false
		local ok, err = ns.Bugs.Call(ns.OnRosterUpdate)
		if not ok then
			ns.lastError = "roster: " .. tostring(err)
			ns.Log("ERROR %s", ns.lastError)
		end
	end)
end

function events.SKILL_LINES_CHANGED()
	if ns.store then ns.ScheduleRefresh(ns.Config.skillDebounce) end
end

function events.TRADE_SKILL_SHOW() ns.Log("event TRADE_SKILL_SHOW") scheduleScan() end
function events.TRADE_SKILL_LIST_UPDATE() scheduleScan() end
function events.TRADE_SKILL_DATA_SOURCE_CHANGED() ns.Log("event TRADE_SKILL_DATA_SOURCE_CHANGED") scheduleScan() end
function events.NEW_RECIPE_LEARNED(recipeID) onRecipeLearned(recipeID) end

-- A profession trainer says which skill every recipe needs: kept as the skill the recipe is
-- learnable from (ProfguildDB.recipeInfo[recipeID].m), matched to the catalog by name.
local trainerNames, trainerRevision, trainerBuiltAt
local function readTrainer()
	if type(GetNumTrainerServices) ~= "function" or type(GetTrainerServiceSkillReq) ~= "function" then return end
	if type(IsTradeskillTrainer) == "function" and not IsTradeskillTrainer() then return end -- a class trainer
	local n = GetNumTrainerServices() or 0
	if n == 0 or not ns.catalog then return end
	local stale = trainerRevision == false and GetTime() - (trainerBuiltAt or 0) >= 60
	if trainerRevision ~= ns.catalog.revision and (trainerRevision ~= false or stale) then
		trainerRevision, trainerNames, trainerBuiltAt = ns.catalog.revision, {}, GetTime()
		local missing = false
		for _, list in pairs(ns.catalog:All()) do
			for recipeID in pairs(list) do
				local name = Scanner.RecipeName(recipeID)
				if name then
					trainerNames[name] = trainerNames[name] or {}
					table.insert(trainerNames[name], recipeID)
				else
					missing = true
				end
			end
		end
		if missing then trainerRevision = false end -- names not known yet: built again a minute later
	end
	local byName = trainerNames
	local found = 0
	for i = 1, n do
		local name, _, category = GetTrainerServiceInfo(i)
		local _, rank = GetTrainerServiceSkillReq(i)
		if name and category ~= "header" and type(rank) == "number" and rank > 0 and byName[name] then
			for _, recipeID in ipairs(byName[name]) do
				local info = ns.db.recipeInfo[recipeID] or {}
				if info.m ~= rank then found = found + 1 end
				info.m = rank
				ns.db.recipeInfo[recipeID] = info
			end
		end
	end
	if found > 0 then
		ns.recipeInfoRevision = (ns.recipeInfoRevision or 0) + 1
		ns.Log("trainer: skill of %d recipes", found)
		ns.OnDataChanged()
	end
end

local trainerPending = false
local function scheduleTrainer()
	if trainerPending then return end
	trainerPending = true
	C_Timer.After(0.5, function()
		trainerPending = false
		local ok, err = ns.Bugs.Call(readTrainer)
		if not ok then ns.Log("ERROR trainer: %s", tostring(err)) end
	end)
end
-- Trainers and recipe vendors read into one reading per NPC (NpcReader), kept by onNpcReading.
local function call(fn, ...)
	if type(fn) ~= "function" then return nil end
	return fn(...)
end
local npcLines, recipeItems = {}, nil
local function npcLineOf(name)
	if npcLines[name] then return npcLines[name] end
	local lines = {}
	for _, e in pairs(ns.RecipeData or {}) do lines[e[6]] = true end
	for line in pairs(ns.catalog and ns.catalog:All() or {}) do lines[line] = true end
	for line in pairs(lines) do
		if Scanner.ProfessionName(line) == name then
			npcLines[name] = line
			return line
		end
	end
	return nil
end
local function npcRecipes(line)
	local list, seen = {}, {}
	local function add(recipeID)
		if seen[recipeID] then return end
		seen[recipeID] = true
		local e = ns.RecipeData and ns.RecipeData[recipeID]
		list[#list + 1] = { id = recipeID, name = Scanner.RecipeName(recipeID), line = line,
			item = e and (e[1] or false) or nil, grey = e and e[5] or nil }
	end
	for recipeID, e in pairs(ns.RecipeData or {}) do
		if e[6] == line then add(recipeID) end
	end
	for recipeID in pairs(ns.catalog and ns.catalog:Get(line) or {}) do add(recipeID) end
	return list
end
ns.npcReader = ns.NpcReader.New({
	now = function() return GetTime() end,
	after = function(delay, fn) C_Timer.After(delay, function() ns.Bugs.Call(fn) end) end,
	inCombat = function() return InCombatLockdown() end,
	secret = function(v) return type(issecretvalue) == "function" and issecretvalue(v) or false end,
	npcGUID = function() return UnitGUID("npc") end,
	npcName = function() return (UnitName("npc")) end,
	place = function()
		if not C_Map then return nil end
		local map = call(C_Map.GetBestMapForUnit, "player")
		if not map then return nil end
		local pos = call(C_Map.GetPlayerMapPosition, map, "player")
		if type(pos) ~= "table" then return map end
		if type(pos.GetXY) == "function" then return map, pos:GetXY() end
		return map, pos.x, pos.y
	end,
	tradeskillTrainer = function() return type(IsTradeskillTrainer) == "function" and IsTradeskillTrainer() end,
	numServices = function() return call(GetNumTrainerServices) end,
	serviceInfo = function(i) return call(GetTrainerServiceInfo, i) end,
	serviceSkill = function(i) return call(GetTrainerServiceSkillReq, i) end,
	serviceCost = function(i) return call(GetTrainerServiceCost, i) end,
	lineOf = npcLineOf,
	recipes = npcRecipes,
	numItems = function() return call(GetMerchantNumItems) end,
	itemInfo = function(i) return C_MerchantFrame and call(C_MerchantFrame.GetItemInfo, i) end,
	itemID = function(i) return call(GetMerchantItemID, i) end,
	costCount = function(i) return call(GetMerchantItemCostInfo, i) end,
	costItem = function(i, j) return call(GetMerchantItemCostItem, i, j) end,
	itemClass = function(itemID)
		local c = Scanner.ItemClass(itemID)
		return c and c.classID
	end,
	dataItem = function(itemID)
		if not recipeItems then
			recipeItems = {}
			for _, e in pairs(ns.RecipeData or {}) do
				if e[1] then recipeItems[e[1]] = true end
			end
		end
		return recipeItems[itemID] == true
	end,
}, function(npcID, reading)
	local nt, nv = 0, 0
	for _ in pairs(reading.t or {}) do nt = nt + 1 end
	for _ in pairs(reading.v or {}) do nv = nv + 1 end
	ns.Log("npc %d %s: %d trained, %d sold, place %s", npcID, tostring(reading.name), nt, nv,
		reading.map and (reading.map .. " " .. reading.x .. "," .. reading.y) or "unknown")
	onNpcReading(npcID, reading)
end)
local function npcRead(method)
	local ok, err = ns.Bugs.Call(ns.npcReader[method], ns.npcReader)
	if not ok then ns.Log("ERROR npc %s: %s", method, tostring(err)) end
end

function events.TRAINER_SHOW() scheduleTrainer() npcRead("TrainerShow") end
function events.TRAINER_UPDATE() scheduleTrainer() npcRead("TrainerUpdate") end
function events.TRAINER_CLOSED() npcRead("TrainerClosed") end
function events.MERCHANT_SHOW() npcRead("MerchantShow") end
function events.MERCHANT_UPDATE() npcRead("MerchantUpdate") end
function events.MERCHANT_CLOSED() npcRead("MerchantClosed") end

function events.PLAYER_REGEN_ENABLED() flushSoon() npcRead("CombatEnded") end
function events.PLAYER_ENTERING_WORLD() flushSoon() end
function events.ZONE_CHANGED_NEW_AREA() flushSoon() end

frame:SetScript("OnEvent", function(_, event, ...)
	local handler = events[event]
	if handler then
		local ok, err = ns.Bugs.Call(handler, ...)
		if not ok then
			ns.lastError = event .. ": " .. tostring(err)
			ns.Log("ERROR %s", ns.lastError)
			ns.Debug("%s", ns.lastError)
		end
	end
end)

for event in pairs(events) do
	-- Some events may not exist on every client; registering an unknown event must not break loading.
	pcall(frame.RegisterEvent, frame, event)
end
