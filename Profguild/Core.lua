-- Profguild: Core
-- Startup, saved data, game events, the Sync adapter and slash commands.

local ADDON, ns = ...

local Store, Sync, Scanner, Comm, Reagents = ns.Store, ns.Sync, ns.Scanner, ns.Comm, ns.Reagents

ns.Config = {
	staleDays = 30,          -- hide members who have not logged in for this many days
	helloInterval = 900,     -- periodic sync check, seconds
	rosterInterval = 300,    -- roster refresh, seconds
	skillDebounce = 60,      -- skill-ups are merged into one update
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
	db.guilds = db.guilds or {}
	db.own = db.own or {}
	-- reagents per recipe: game data, kept for the whole account (see Reagents.lua)
	if type(db.reagents) ~= "table" then db.reagents = {} end
	ns.db = db
	ns.SetLanguage(db.settings.lang)
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
		if not (own.scanned and own.scanned[skillLine]) and not reminded[skillLine] then
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
	if dataChangedPending then return end
	dataChangedPending = true
	C_Timer.After(0.5, function()
		dataChangedPending = false
		if ns.UI and ns.UI.OnDataChanged then ns.UI:OnDataChanged() end
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
	-- The game names the real sender of an addon message. When the roster row with this guid
	-- carries that name, the message comes from the owner of the record. Rows matched only by
	-- name (a roster without GUIDs) prove nothing and do not count.
	isOwner = function(guid, senderName)
		local entry = ns.store and ns.store.db.roster[guid]
		return entry ~= nil and type(entry.name) == "string" and type(senderName) == "string"
			and ns.NormalizeName(entry.name) == ns.NormalizeName(senderName)
	end,
	onChanged = function() ns.OnDataChanged() end,
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

-- (Re)creates the store and sync for the current guild. Called on login and guild changes.
function ns.SetupGuild()
	local key, guildName = Scanner.GuildKey()
	if key == ns.guildKey then return end
	ns.guildKey, ns.guildName = key, guildName
	if not key then
		ns.store, ns.sync, ns.guildDB = nil, nil, nil
		ns.OnDataChanged()
		return
	end
	ns.db.guilds[key] = ns.db.guilds[key] or {}
	ns.guildDB = ns.db.guilds[key]
	ns.guildDB.names = ns.guildDB.names or {}
	ns.store = Store.New(ns.guildDB)
	ns.sync = Sync.New(adapter, ns.store, ns.version)
	Scanner.RequestRoster()
	ns.RefreshOwn()
	local d = ns.Config.loginHelloDelay
	C_Timer.After(d[1] + math.random() * (d[2] - d[1]), function()
		if ns.sync then ns.sync:Hello(true) end
	end)
	ns.OnDataChanged()
end

function ns.OnRosterUpdate()
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
		local skillLine, recipes, count, reagents = Scanner.ScanOpenProfession()
		if not skillLine then
			ns.Debug("scan skipped: %s", tostring(recipes))
			return
		end
		local own = ownState()
		if not own then return end
		skillLine = resolveSkillLine(own, skillLine)
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
		if ns.reagents then
			for recipeID, list in pairs(reagents or {}) do ns.reagents:Set(recipeID, list) end
		end
		if not wasScanned or oldCount ~= count then
			ns.Say("SCANNED", Scanner.ProfessionName(skillLine), count)
		end
		ns.ScheduleRefresh()
	end)
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
	ns.Say("STATUS_PRICES", ns.Prices and ns.Prices.Source() or ns.T("NO_PRICES"))
	if ns.sync.newerProtocolSeen then ns.Say("NEWER_VERSION") end
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
		add("IsInGuild=%s GuildKey=%s", IsInGuild(), Scanner.GuildKey())
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
-- Slash commands
---------------------------------------------------------------------------

local function slash(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "" then
		if ns.UI then ns.UI:Toggle() end
	elseif cmd == "sync" then
		if not ns.sync then return ns.Say("NO_GUILD") end
		Scanner.RequestRoster()
		ns.RefreshOwn()
		local reason = ns.SendBlockReason()
		if ns.sync:Hello(true) then
			if reason then ns.Say("SYNC_BLOCKED", ns.T(reason)) else ns.Say("SYNC_STARTED") end
		else
			ns.Say("SYNC_TOO_SOON")
		end
	elseif cmd == "status" then
		ns.Status()
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
		ns.sync:Hello(true)
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
	Comm:Init()
	if ns.Tooltip then ns.Tooltip:Init() end
	frame:UnregisterEvent("ADDON_LOADED")
end

function events.PLAYER_LOGIN()
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
	C_Timer.After(45, function() ns.DebugDump(true) end)
	C_Timer.NewTicker(ns.Config.helloInterval, function()
		if ns.sync then ns.sync:Hello(false) end
	end)
	C_Timer.NewTicker(ns.Config.rosterInterval, function()
		if IsInGuild() then Scanner.RequestRoster() end
	end)
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
		local ok, err = pcall(ns.OnRosterUpdate)
		if not ok then
			ns.lastError = "roster: " .. tostring(err)
			ns.Log("ERROR %s", ns.lastError)
		end
	end)
end

function events.SKILL_LINES_CHANGED()
	if ns.store then ns.ScheduleRefresh(ns.Config.skillDebounce) end
end

function events.TRADE_SKILL_SHOW() scheduleScan() end
function events.TRADE_SKILL_LIST_UPDATE() scheduleScan() end
function events.TRADE_SKILL_DATA_SOURCE_CHANGED() scheduleScan() end
function events.NEW_RECIPE_LEARNED(recipeID) onRecipeLearned(recipeID) end

function events.PLAYER_REGEN_ENABLED() flushSoon() end
function events.PLAYER_ENTERING_WORLD() flushSoon() end
function events.ZONE_CHANGED_NEW_AREA() flushSoon() end

frame:SetScript("OnEvent", function(_, event, ...)
	local handler = events[event]
	if handler then
		local ok, err = pcall(handler, ...)
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
