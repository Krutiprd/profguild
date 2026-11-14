-- Profguild: Store
-- Pure data logic: records, validation, versions, digests, pruning and search indexes.
-- No WoW API calls here, so this file is unit-tested outside the game.

local _, ns = ...
ns = ns or {}

local Store = {}
ns.Store = Store

-- Limits applied to every record that arrives over the network.
Store.LIMITS = {
	maxStr = 64,           -- max length of short strings (guid, name, account id)
	maxClass = 24,
	maxProfessions = 16,   -- per character
	maxRecipes = 2500,     -- per profession
	maxVersion = 2147483647,
	maxSkill = 1000,
}

local L = Store.LIMITS

local type, pairs, next, tostring, floor = type, pairs, next, tostring, math.floor

local function isInt(n, lo, hi)
	return type(n) == "number" and n == n and floor(n) == n and n >= lo and n <= hi
end

local function shortStr(s, max)
	return type(s) == "string" and #s > 0 and #s <= max
end

-- Names from the network are shown in chat, tooltips and the window, so they must not carry
-- UI escape sequences ("|T" texture, "|c" color, "|H" link) or control characters.
local function cleanName(s)
	if not shortStr(s, L.maxStr) then return "?" end
	s = s:gsub("[|%c]", "")
	return s ~= "" and s or "?"
end

-- Returns a sanitized deep copy of a record, or nil + reason when the record is unusable.
-- Unknown fields are dropped. Malformed professions or recipes are skipped, not fatal.
function Store.Validate(rec)
	if type(rec) ~= "table" then return nil, "not a table" end
	if not shortStr(rec.g, L.maxStr) then return nil, "bad guid" end
	if not isInt(rec.v, 1, L.maxVersion) then return nil, "bad version" end

	local out = {
		g = rec.g,
		v = rec.v,
		n = cleanName(rec.n),
		c = shortStr(rec.c, L.maxClass) and rec.c:find("^%u+$") and rec.c or nil, -- class file name, e.g. "MAGE"
		a = shortStr(rec.a, L.maxStr) and rec.a or nil,
		t = isInt(rec.t, 0, 4102444800) and rec.t or 0,
		p = {},
	}

	if type(rec.p) == "table" then
		local profCount = 0
		for skillLine, prof in pairs(rec.p) do
			if profCount >= L.maxProfessions then break end
			if isInt(skillLine, 1, 1000000) and type(prof) == "table" then
				local p = {
					s = isInt(prof.s, 0, L.maxSkill) and prof.s or 0,
					m = isInt(prof.m, 0, L.maxSkill) and prof.m or 0,
					k = prof.k == true or nil,
					r = {},
				}
				if type(prof.r) == "table" then
					local count = 0
					for recipeID, itemID in pairs(prof.r) do
						if count >= L.maxRecipes then break end
						if isInt(recipeID, 1, 100000000) then
							p.r[recipeID] = isInt(itemID, 0, 100000000) and itemID or 0
							count = count + 1
						end
					end
				end
				out.p[skillLine] = p
				profCount = profCount + 1
			end
		end
	end
	return out
end

local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end
Store.DeepEqual = deepEqual

-- Number that identifies the content of a record (not its version or time). Used to notice
-- two copies with the same version and different content. Not cryptographic.
function Store.Checksum(rec)
	if type(rec) ~= "table" then return 0 end
	local h = 5381
	local function mix(n)
		h = (h * 33 + n) % 2147483647
	end
	local function mixStr(s)
		s = tostring(s or "")
		for i = 1, #s do mix(s:byte(i)) end
		mix(#s)
	end
	mixStr(rec.n); mixStr(rec.c); mixStr(rec.a)
	local lines = {}
	for skillLine in pairs(rec.p or {}) do lines[#lines + 1] = skillLine end
	table.sort(lines)
	for _, skillLine in ipairs(lines) do
		local prof = rec.p[skillLine]
		mix(skillLine); mix(prof.s or 0); mix(prof.m or 0); mix(prof.k and 1 or 0)
		local ids = {}
		for recipeID in pairs(prof.r or {}) do ids[#ids + 1] = recipeID end
		table.sort(ids)
		for _, recipeID in ipairs(ids) do
			mix(recipeID); mix(prof.r[recipeID] or 0)
		end
	end
	return h
end

local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in pairs(t) do c[k] = deepCopy(v) end
	return c
end
Store.DeepCopy = deepCopy

---------------------------------------------------------------------------
-- Guild store object
---------------------------------------------------------------------------

local StoreMT = {}
StoreMT.__index = StoreMT

-- guildDB is the persisted table for one guild: { records = {}, roster = {} }
function Store.New(guildDB)
	guildDB.records = guildDB.records or {}
	guildDB.roster = guildDB.roster or {}
	-- revision counts changes of the records, rosterRevision changes of the roster
	local self = setmetatable({ db = guildDB, revision = 0, rosterRevision = 0 }, StoreMT)
	return self
end

function StoreMT:Get(guid)
	return self.db.records[guid]
end

function StoreMT:All()
	return self.db.records
end

function StoreMT:Count()
	local n = 0
	for _ in pairs(self.db.records) do n = n + 1 end
	return n
end

-- Map guid -> version of every record we hold.
function StoreMT:Digest()
	local d = {}
	for guid, rec in pairs(self.db.records) do d[guid] = rec.v end
	return d
end

local function touch(self)
	self.revision = self.revision + 1
end

-- Applies a record received from the network (or produced locally).
-- Returns "new", "updated", "same", "older" or "invalid".
-- fromOwner: the record comes from its owner (our own record, or a sender the roster confirms).
-- At the maximum version nobody can publish a higher one any more, so there the owner's copy
-- replaces a different copy with the same version. Without this, one forged record with the
-- maximum version would stay in the guild for good.
function StoreMT:Apply(rec, fromOwner)
	local clean, why = Store.Validate(rec)
	if not clean then return "invalid", why end
	local cur = self.db.records[clean.g]
	if not cur then
		self.db.records[clean.g] = clean
		touch(self)
		return "new"
	end
	if clean.v > cur.v then
		self.db.records[clean.g] = clean
		touch(self)
		return "updated"
	elseif clean.v == cur.v then
		if fromOwner and clean.v >= L.maxVersion and Store.Checksum(cur) ~= Store.Checksum(clean) then
			self.db.records[clean.g] = clean
			touch(self)
			return "updated"
		end
		return "same"
	end
	return "older"
end

function StoreMT:Remove(guid)
	if self.db.records[guid] then
		self.db.records[guid] = nil
		touch(self)
		return true
	end
	return false
end

function StoreMT:Clear(keepGuids)
	for guid in pairs(self.db.records) do
		if not (keepGuids and keepGuids[guid]) then self.db.records[guid] = nil end
	end
	touch(self)
end

-- Compares a remote digest with ours.
-- mineNewer: guids where we hold a newer record, or one the remote does not have.
-- theirsNewer: guids where the remote holds a newer record, or one we do not have.
function StoreMT:Compare(remote)
	local mineNewer, theirsNewer = {}, {}
	local recs = self.db.records
	for guid, rec in pairs(recs) do
		local rv = remote[guid]
		if rv == nil or rec.v > rv then mineNewer[#mineNewer + 1] = guid end
	end
	for guid, rv in pairs(remote) do
		local rec = recs[guid]
		if type(rv) == "number" and (not rec or rv > rec.v) then theirsNewer[#theirsNewer + 1] = guid end
	end
	table.sort(mineNewer)
	table.sort(theirsNewer)
	return mineNewer, theirsNewer
end

-- Removes records of characters that are not in the guild roster.
-- rosterGuids: set guid -> true. Never prunes when the roster looks incomplete.
-- keep: optional set of guids that must never be pruned here (none by default).
function StoreMT:PruneToRoster(rosterGuids, keep)
	if type(rosterGuids) ~= "table" or next(rosterGuids) == nil then return {} end
	local removed = {}
	for guid in pairs(self.db.records) do
		if not rosterGuids[guid] and not (keep and keep[guid]) then
			removed[#removed + 1] = guid
		end
	end
	for _, guid in ipairs(removed) do self.db.records[guid] = nil end
	if #removed > 0 then touch(self) end
	return removed
end

-- Fallback for clients whose roster has no GUIDs: removes records whose name is not in the roster.
-- rosterNames: set of normalized names. normalize(name) -> name in the same form (optional).
-- keep: set of guids never pruned. Returns the removed guids, or nil + reason when it refused:
-- names are a weaker key than GUIDs, so nothing is removed when the record of selfGuid (our own
-- character) does not match the roster by name, i.e. when names are in a different form.
function StoreMT:PruneToRosterNames(rosterNames, normalize, keep, selfGuid)
	if type(rosterNames) ~= "table" or next(rosterNames) == nil then return nil, "empty roster" end
	normalize = normalize or function(n) return n end
	local me = selfGuid and self.db.records[selfGuid]
	if not me or not me.n or not rosterNames[normalize(me.n)] then return nil, "names do not match" end
	local removed = {}
	for guid, rec in pairs(self.db.records) do
		if not (keep and keep[guid]) and not (rec.n and rosterNames[normalize(rec.n)]) then
			removed[#removed + 1] = guid
		end
	end
	for _, guid in ipairs(removed) do self.db.records[guid] = nil end
	if #removed > 0 then touch(self) end
	return removed
end

---------------------------------------------------------------------------
-- Roster bookkeeping (local only, never synced)
---------------------------------------------------------------------------

-- entries: array of { guid=, name=, online=bool, daysOffline=number|nil, classFile= }
-- Entries without a GUID are matched to records by name instead (if the client's roster
-- does not return GUIDs). normalize(name) -> name in the form used for that match (optional):
-- the roster may carry a realm suffix that the name in a record does not have.
-- partial: the game returned only some of the members (roster still loading, or offline
-- members hidden). Then the members that were read are updated and the others are kept, so
-- nobody loses their last-online data and turns stale by mistake.
function StoreMT:SetRoster(entries, normalize, partial)
	normalize = normalize or function(n) return n end
	local roster, byName = {}, {}
	if partial then
		for guid, entry in pairs(self.db.roster or {}) do roster[guid] = entry end
		for name, entry in pairs(self.rosterByName or {}) do byName[name] = entry end
	end
	for _, e in ipairs(entries) do
		local entry = { name = e.name, online = e.online and true or false, days = e.daysOffline, c = e.classFile }
		if e.guid then roster[e.guid] = entry end
		if e.name then byName[normalize(e.name)] = entry end
	end
	self.db.roster = roster
	self.rosterByName = byName
	self.normalizeName = normalize
	-- the recipe index depends only on the records, so the roster has its own revision
	self.rosterRevision = self.rosterRevision + 1
end

function StoreMT:RosterEntry(guid)
	local entry = self.db.roster[guid]
	if entry then return entry end
	local rec = self.db.records[guid]
	if rec and self.rosterByName then return self.rosterByName[self.normalizeName(rec.n)] end
	return nil
end

function StoreMT:IsOnline(guid)
	local r = self:RosterEntry(guid)
	return r and r.online or false
end

-- A character is stale when the roster says it has not logged in for staleDays.
-- Without roster info we fall back to the record's own timestamp.
function StoreMT:IsStale(guid, staleDays, now)
	local r = self:RosterEntry(guid)
	if r then
		if r.online then return false end
		if r.days then return r.days >= staleDays end
	end
	local rec = self.db.records[guid]
	if rec and rec.t and rec.t > 0 and now then
		return (now - rec.t) >= staleDays * 86400
	end
	return false
end

---------------------------------------------------------------------------
-- Search indexes
---------------------------------------------------------------------------

-- Builds lookup tables from all records:
--   recipes[recipeID] = { skillLine=, itemID=, guids = {guid,...} }
--   items[itemID]     = { recipeID, ... }
--   alts[accountId]   = { guid, ... }
-- Rebuilt only when the store revision changed.
function StoreMT:Index()
	if self.index and self.indexRevision == self.revision then return self.index end
	local recipes, items, alts = {}, {}, {}
	for guid, rec in pairs(self.db.records) do
		for skillLine, prof in pairs(rec.p) do
			for recipeID, itemID in pairs(prof.r) do
				local e = recipes[recipeID]
				if not e then
					e = { skillLine = skillLine, itemID = itemID, guids = {} }
					recipes[recipeID] = e
					if itemID and itemID > 0 then
						local list = items[itemID]
						if not list then list = {}; items[itemID] = list end
						list[#list + 1] = recipeID
					end
				elseif (e.itemID == nil or e.itemID == 0) and itemID and itemID > 0 then
					e.itemID = itemID
					local list = items[itemID]
					if not list then list = {}; items[itemID] = list end
					list[#list + 1] = recipeID
				end
				e.guids[#e.guids + 1] = guid
			end
		end
		if rec.a then
			local list = alts[rec.a]
			if not list then list = {}; alts[rec.a] = list end
			list[#list + 1] = guid
		end
	end
	self.index = { recipes = recipes, items = items, alts = alts }
	self.indexRevision = self.revision
	return self.index
end

---------------------------------------------------------------------------
-- Owner side: turning snapshots of the player's own character into a record
---------------------------------------------------------------------------

-- Builds the publishable record (without v / t) from the owner's state.
local function buildRecord(own, guid, name, class, account)
	local rec = { g = guid, n = name, c = class, a = account, p = {} }
	for skillLine, info in pairs(own.profs or {}) do
		local r = {}
		for recipeID, itemID in pairs(own.recipes and own.recipes[skillLine] or {}) do r[recipeID] = itemID end
		rec.p[skillLine] = { s = info.s, m = info.m, k = own.scanned and own.scanned[skillLine] or nil, r = r }
	end
	return rec
end

-- own: persisted state for one of the player's characters:
--   { v = version, rec = last published record, recipes = { [skillLine] = { [recipeID] = itemID } },
--     scanned = { [skillLine] = true }, missing = { [skillLine] = count } }
-- snap: { guid=, name=, class=, account=, ok=bool, profs = { [skillLine] = { s=, m= } } }
-- Professions disappear only after two consecutive reliable snapshots without them,
-- so one bad API answer at login never wipes data.
-- Returns the record to publish and whether it changed.
function Store.BuildOwnRecord(own, snap, now)
	own.recipes = own.recipes or {}
	own.scanned = own.scanned or {}
	own.missing = own.missing or {}
	own.profs = own.profs or {}
	own.v = own.v or 0
	-- a saved version outside the valid range can never be published: start again from 0,
	-- the copies held by the guild raise it through the self-heal
	if not isInt(own.v, 0, L.maxVersion) then
		own.v = 0
		own.rec = nil
	end

	if snap.ok then
		for skillLine, info in pairs(snap.profs) do
			own.profs[skillLine] = { s = info.s, m = info.m }
			own.missing[skillLine] = nil
		end
		for skillLine in pairs(own.profs) do
			if not snap.profs[skillLine] then
				own.missing[skillLine] = (own.missing[skillLine] or 0) + 1
				if own.missing[skillLine] >= 2 then
					own.profs[skillLine] = nil
					own.recipes[skillLine] = nil
					own.scanned[skillLine] = nil
					own.missing[skillLine] = nil
				end
			end
		end
	end

	local rec = buildRecord(own, snap.guid, snap.name, snap.class, snap.account)

	local prev = own.rec
	local changed = true
	if prev then
		changed = not (deepEqual(prev.p, rec.p) and prev.n == rec.n and prev.c == rec.c and prev.a == rec.a)
	end
	if changed then
		own.v = math.min(own.v + 1, L.maxVersion)
		rec.v = own.v
		rec.t = now or 0
		own.rec = rec
	end
	return own.rec, changed
end

-- Records the full recipe list of one profession, from an opened profession window.
-- recipes: { [recipeID] = itemID }
function Store.SetScannedRecipes(own, skillLine, recipes)
	own.recipes = own.recipes or {}
	own.scanned = own.scanned or {}
	own.recipes[skillLine] = recipes
	own.scanned[skillLine] = true
end

-- Adds one learned recipe. Returns false when the profession is unknown yet.
function Store.AddLearnedRecipe(own, skillLine, recipeID, itemID)
	if not skillLine then return false end
	own.recipes = own.recipes or {}
	own.recipes[skillLine] = own.recipes[skillLine] or {}
	own.recipes[skillLine][recipeID] = itemID or 0
	return true
end

-- Self-heal: someone holds our record with version seenVersion >= ours (lost SavedVariables,
-- a second PC, or a forged copy). received is that copy, already validated, or nil when only
-- the version is known. Recipes of professions we still have but have not scanned on this
-- install are taken over from the copy, so the guild does not lose them; scanned professions,
-- skill levels and the profession list stay ours. When we have no profession snapshot yet,
-- the professions of the copy are taken over too (the next snapshots correct them).
-- Raises our version above seenVersion and returns the record to publish (nil without identity).
-- A seenVersion that no valid record can carry is ignored (returns nil), and our version never
-- passes the maximum, so the record stays publishable.
function Store.HealOwn(own, seenVersion, received, now)
	if not isInt(seenVersion, 0, L.maxVersion) then return nil end
	own.recipes = own.recipes or {}
	own.scanned = own.scanned or {}
	own.profs = own.profs or {}
	own.v = own.v or 0
	if not isInt(own.v, 0, L.maxVersion) then own.v = 0 end

	if type(received) == "table" and type(received.p) == "table" then
		local noSnapshot = next(own.profs) == nil
		for skillLine, prof in pairs(received.p) do
			if noSnapshot and not own.profs[skillLine] then
				own.profs[skillLine] = { s = prof.s or 0, m = prof.m or 0 }
			end
			if own.profs[skillLine] and not own.scanned[skillLine] and prof.k and type(prof.r) == "table" then
				local mine = own.recipes[skillLine] or {}
				for recipeID, itemID in pairs(prof.r) do
					if mine[recipeID] == nil or mine[recipeID] == 0 then mine[recipeID] = itemID end
				end
				own.recipes[skillLine] = mine
				own.scanned[skillLine] = true
			end
		end
	end

	local base = own.rec or received
	if not base or not base.g then
		if seenVersion > own.v then own.v = seenVersion end
		return nil
	end
	local rec = buildRecord(own, base.g, base.n, base.c, (own.rec and own.rec.a) or base.a)
	own.v = math.min(math.max(own.v, seenVersion) + 1, L.maxVersion)
	rec.v = own.v
	rec.t = now or 0
	own.rec = rec
	return rec
end

-- Raise our own version above a version seen elsewhere (self-heal after lost SavedVariables).
-- Returns true when the version was raised.
function Store.BumpOwnVersion(own, seenVersion, now)
	own.v = own.v or 0
	if seenVersion < own.v then return false end
	own.v = seenVersion + 1
	if own.rec then
		own.rec.v = own.v
		own.rec.t = now or own.rec.t
	end
	return true
end

return Store
