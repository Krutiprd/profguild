-- Profguild: NpcTable
-- The table of NPC sheets (ns.NpcData.New): expiry, the sendable part, limits, hashes, saving and
-- the npcOwn import, on top of the sheet functions of NpcData.lua. Pure: no WoW API.

local _, ns = ...
ns = ns or {}

local NpcData = ns.NpcData
local I = NpcData.internal
local validID, count, trim, copyPrice, deepEqual = I.validID, I.count, I.trim, I.copyPrice, I.deepEqual
local priceWrites, makeRoom, EMPTY = I.priceWrites, I.makeRoom, I.EMPTY
local KeyHash, hashSheet = NpcData.KeyHash, NpcData.HashSheet
local floor, pairs, ipairs, next, sort = math.floor, pairs, ipairs, next, table.sort
local RENEW, M = NpcData.RENEW, NpcData.HASH_MOD

-- Helpers --------------------------------------------------------------------

-- The sendable part: entries seen at most SEND days ago with their registers of at most SEND days,
-- and the head when such an entry is left; nil without one.
local function cut(s, today)
	local lo, n = today - NpcData.SEND, 0
	local c = { t = {}, v = {} }
	for id, e in pairs(s.t) do
		if e[1] >= lo then
			local r = { e[1], e[2], e[3], e[4], e[5] }
			if r[3] < lo then r[2], r[3] = 0, 0 end
			if r[5] < lo then r[4], r[5] = 0, 0 end
			c.t[id], n = r, n + 1
		end
	end
	for id, e in pairs(s.v) do
		if e[1] >= lo then
			c.v[id], n = e[3] >= lo and { e[1], copyPrice(e[2]), e[3] } or { e[1], false, 0 }, n + 1
		end
	end
	if n == 0 then return nil end
	c.name, c.nd, c.map, c.x, c.y, c.pd = s.name, s.nd, s.map, s.x, s.y, s.pd
	return c
end

-- Drops in place what is older than EXPIRE days; whether anything went.
local function expireSheet(s, today)
	local lo, gone = today - NpcData.EXPIRE, false
	for id, e in pairs(s.t) do
		if e[1] < lo then
			s.t[id], gone = nil, true
		else
			if e[2] ~= 0 and e[3] < lo then e[2], e[3], gone = 0, 0, true end
			if e[4] ~= 0 and e[5] < lo then e[4], e[5], gone = 0, 0, true end
		end
	end
	for id, e in pairs(s.v) do
		if e[1] < lo then
			s.v[id], gone = nil, true
		elseif e[2] and e[3] < lo then
			e[2], e[3], gone = false, 0, true
		end
	end
	return gone
end

-- The registers of own sheet o that enter held h by the own-visit rules as of their own days.
local function ownRegisters(h, o)
	local ins = { t = {}, v = {} }
	if o.name and (h.name == nil or o.nd - h.nd > RENEW) then ins.name, ins.nd = o.name, o.nd end
	if o.map and (h.map == nil or o.pd - h.pd > RENEW) then
		ins.map, ins.x, ins.y, ins.pd = o.map, o.x, o.y, o.pd
	end
	local ht, hv = h.t or EMPTY.t, h.v or EMPTY.v
	for id, e in pairs(o.t) do
		local he = ht[id]
		local r = { 0, 0, 0, 0, 0 }
		if not he or e[1] - he[1] > RENEW then r[1] = e[1] end
		if e[2] ~= 0 and (not he or he[2] == 0 or e[3] - he[3] > RENEW) then r[2], r[3] = e[2], e[3] end
		if e[4] ~= 0 and (not he or he[4] == 0
			or priceWrites({ c = he[4], o = {}, l = 0 }, he[5], { c = e[4], o = {}, l = 0 }, e[5])) then
			r[4], r[5] = e[4], e[5]
		end
		if r[1] ~= 0 or r[2] ~= 0 or r[4] ~= 0 then ins.t[id] = r end
	end
	for id, e in pairs(o.v) do
		local he = hv[id]
		local r = { 0, false, 0 }
		if not he or e[1] - he[1] > RENEW then r[1] = e[1] end
		if e[2] and priceWrites(he and he[2], he and he[3], e[2], e[3]) then r[2], r[3] = copyPrice(e[2]), e[3] end
		if r[1] ~= 0 or r[2] then ins.v[id] = r end
	end
	return ins
end

-- Limits over the table: items { seen, hash, npc, part, id }; true when a goes before b (the older,
-- then the higher hash, then the higher keys).
local function goesBefore(a, b)
	if a[1] ~= b[1] then return a[1] < b[1] end
	for j = 2, 5 do
		if a[j] ~= b[j] then return a[j] > b[j] end
	end
	return false
end

-- The k items that go first of those each(offer, enters) offers, in no particular order. The order
-- is total (keys differ), so the set is the same whatever the order of offers: clients converge.
-- A heap of at most k items whose root goes last of them: n log k, not a sort of every item.
-- enters(seen) is false when an item of that seen cannot enter (the caller skips its hash).
local function worst(k, each)
	local low, n, probe = {}, 0, {}
	local function down(i)
		while true do
			local l, r, top = 2 * i, 2 * i + 1, i
			if l <= n and goesBefore(low[top], low[l]) then top = l end
			if r <= n and goesBefore(low[top], low[r]) then top = r end
			if top == i then return end
			low[i], low[top] = low[top], low[i]
			i = top
		end
	end
	local function enters(s) return n < k or s <= low[1][1] end
	each(function(s, h, npc, part, id)
		if n < k then
			n = n + 1
			low[n] = { s, h, npc, part, id }
			local i = n
			while i > 1 do
				local p = floor(i / 2)
				if not goesBefore(low[p], low[i]) then break end
				low[p], low[i] = low[i], low[p]
				i = p
			end
			return
		end
		probe[1], probe[2], probe[3], probe[4], probe[5] = s, h, npc, part, id
		if not goesBefore(probe, low[1]) then return end
		low[1] = { s, h, npc, part, id }
		down(1)
	end, enters)
	return low
end

local function entryHash(npcHash, part, id) return KeyHash((KeyHash((npcHash + part) % 4294967296) + id) % 4294967296) end

-- Table ----------------------------------------------------------------------
-- tab = NpcData.New(saved, now[, limits]): saved = { e = EPOCH, s = { [npcID] = packed } } is loaded
-- (other epochs and broken sheets dropped) and kept current at every change; now() gives server
-- seconds; limits = { t=, v=, entries=, sheets= } replaces the constants (tests).
-- Limits, after every merge (once for all sheets of an NU, MergeAll), in this order: entries per sheet, entries, sheets. The older goes first
-- (an entry by seen, a sheet by its newest entry), then by a hash of the key.
-- Expiry runs at load and before anything is read on a new day. Only the sendable part (see cut) is
-- sent, hashed and counted. Returned sheets and lists are the table's own: do not change them.

local Table = {}
Table.__index = Table

function NpcData.New(saved, now, limits)
	limits = limits or {}
	if type(saved) ~= "table" then saved = {} end
	local tab = setmetatable({ saved = saved, now = now,
		lt = limits.t or NpcData.LIMIT_T, lv = limits.v or NpcData.LIMIT_V,
		le = limits.entries or NpcData.LIMIT_ENTRIES, ls = limits.sheets or NpcData.LIMIT_SHEETS }, Table)
	local src = saved.s
	if saved.e ~= NpcData.EPOCH or type(src) ~= "table" then src = {} end
	-- A clock not known yet (0) or behind the saved days (most saved sheets newer than tomorrow)
	-- would drop the saved sheets as coming from the future: they are left untouched and this
	-- session's table lives in memory only (tab.detached).
	local today, n, ahead = tab:Today(), 0, 0
	for _, list in pairs(src) do
		n = n + 1
		if type(list) == "table" and type(list[8]) == "number" and list[8] > today + 1 then ahead = ahead + 1 end
	end
	if today <= 0 or ahead * 2 > n then
		tab.saved, tab.detached, tab.real, src = {}, true, saved, {}
	end
	tab:reset()
	for key, list in pairs(src) do
		local id, s = NpcData.Unpack(list, tab.day)
		if s and id == key then
			trim(s.t, tab.lt)
			trim(s.v, tab.lv)
			tab:put(id, s)
		end
	end
	tab:limit()
	return tab
end

function Table:reset()
	self.saved.e, self.saved.s = NpcData.EPOCH, {}
	self.sheets, self.sizes, self.newest = {}, {}, {}
	self.nSheets, self.nEntries = 0, 0
	self.day = self:Today()
	self:forget()
end

function Table:forget() self.cuts, self.hashes, self.total, self.ids = {}, {}, nil, nil end

-- Stores a sheet (nil or one without entries removes it), keeping counts, caches and saved current.
function Table:put(id, s)
	if s and next(s.t) == nil and next(s.v) == nil then s = nil end
	local old = self.sizes[id]
	if old then self.nEntries, self.nSheets = self.nEntries - old, self.nSheets - 1 end
	self.sheets[id], self.sizes[id], self.newest[id] = s, nil, nil
	if s then
		local n, newest = 0, 0
		for _, e in pairs(s.t) do n, newest = n + 1, e[1] > newest and e[1] or newest end
		for _, e in pairs(s.v) do n, newest = n + 1, e[1] > newest and e[1] or newest end
		self.sizes[id], self.newest[id] = n, newest
		self.nEntries, self.nSheets = self.nEntries + n, self.nSheets + 1
	end
	self.saved.s[id] = s and NpcData.Pack(id, s) or nil
	self.cuts[id], self.hashes[id], self.total, self.ids = nil, nil, nil, nil
end

-- Applies the table limits (the entry limit per sheet is applied by the caller).
function Table:limit()
	local sheets = self.sheets
	local over = self.nEntries - self.le
	if over > 0 then
		local touched = {}
		for _, d in ipairs(worst(over, function(offer, enters)
			for npc, s in pairs(sheets) do
				local nh = KeyHash(npc)
				for id, e in pairs(s.t) do
					if enters(e[1]) then offer(e[1], entryHash(nh, 1, id), npc, 1, id) end
				end
				for id, e in pairs(s.v) do
					if enters(e[1]) then offer(e[1], entryHash(nh, 2, id), npc, 2, id) end
				end
			end
		end)) do
			local s = sheets[d[3]]
			s[d[4] == 1 and "t" or "v"][d[5]] = nil
			touched[d[3]] = s
		end
		for npc, s in pairs(touched) do self:put(npc, s) end
	end
	over = self.nSheets - self.ls
	if over > 0 then
		local newest = self.newest
		for _, d in ipairs(worst(over, function(offer)
			for npc in pairs(sheets) do offer(newest[npc], KeyHash(npc), npc, 0, 0) end
		end)) do
			self:put(d[3], nil)
		end
	end
end

function Table:Today()
	local t = self.now()
	return floor((type(t) == "number" and t or 0) / 86400)
end

local function check(self)
	if self:Today() ~= self.day then self:Expire() end
end

-- Drops what is older than EXPIRE days; the sendable part is cut anew.
function Table:Expire()
	self.day = self:Today()
	local gone = {}
	for id, s in pairs(self.sheets) do
		if expireSheet(s, self.day) then gone[#gone + 1] = id end
	end
	for _, id in ipairs(gone) do self:put(id, self.sheets[id]) end
	self:forget()
end

-- Everything goes, also from the saved table a detached table left untouched.
function Table:Clear()
	if self.real then self.real.e, self.real.s = NpcData.EPOCH, {} end
	self:reset()
end

function Table:Get(id)
	check(self)
	return self.sheets[id]
end

function Table:Sendable(id)
	check(self)
	local c = self.cuts[id]
	if c == nil then
		local s = self.sheets[id]
		c = s and cut(s, self.day) or false
		self.cuts[id] = c
	end
	return c or nil
end

-- Sorted IDs of the sheets with a sendable part.
function Table:SendableIDs()
	check(self)
	if not self.ids then
		local ids = {}
		for id in pairs(self.sheets) do
			if self:Sendable(id) then ids[#ids + 1] = id end
		end
		sort(ids)
		self.ids = ids
	end
	return self.ids
end

-- Sendable sheets and their entries.
function Table:Count()
	local ids, n = self:SendableIDs(), 0
	for _, id in ipairs(ids) do
		local c = self.cuts[id]
		n = n + count(c.t) + count(c.v)
	end
	return #ids, n
end

-- 0..HASH_MOD-1 of the sendable sheet, nil without one.
function Table:SheetHash(id)
	check(self)
	local h = self.hashes[id]
	if h == nil then
		local c = self:Sendable(id)
		h = c and hashSheet(id, c) or false
		self.hashes[id] = h
	end
	return h or nil
end

-- The sum of the sheet hashes modulo HASH_MOD; 0 for an empty table.
function Table:Hash()
	check(self)
	if not self.total then
		local x = 0
		for _, id in ipairs(self:SendableIDs()) do x = (x + self:SheetHash(id)) % M end
		self.total = x
	end
	return self.total
end

function Table:SaltedHash(hash, salt) return NpcData.SaltedHash(hash, salt) end

-- Received sheets: items = { { id, sheet }, ... } (one NU) are merged, then the table limits are
-- applied once. Per item: changed[i], its sendable content changed; taken[i], some of its entries
-- are held after the limits.
function Table:MergeAll(items)
	check(self)
	local valid, before, merged = {}, {}, false
	for i = 1, #items do
		local id = items[i][1]
		local s = validID(id) and NpcData.Valid(items[i][2], self.day) or nil
		if s then
			valid[i] = s
			if before[id] == nil then before[id] = self:Sendable(id) or false end
			local held = self.sheets[id]
			local m = NpcData.Merge(held, s)
			trim(m.t, self.lt)
			trim(m.v, self.lv)
			if not held or not deepEqual(m, held) then
				self:put(id, m)
				merged = true
			end
		end
	end
	if merged then self:limit() end
	local changed, taken = {}, {}
	for i = 1, #items do
		local s, c, t = valid[i], false, false
		if s then
			local id = items[i][1]
			local now = self.sheets[id]
			if now then
				for k in pairs(s.t) do if now.t[k] then t = true break end end
				if not t then
					for k in pairs(s.v) do if now.v[k] then t = true break end end
				end
			end
			c = not deepEqual(before[id] or nil, self:Sendable(id))
		end
		changed[i], taken[i] = c, t
	end
	return changed, taken
end

-- A received sheet: changed, taken as MergeAll gives them.
function Table:MergeIn(id, sheet)
	local changed, taken = self:MergeAll({ { id, sheet } })
	return changed[1], taken[1]
end

-- An own reading (see NpcData.Visit); whether the sendable content changed.
function Table:OwnVisit(id, reading)
	check(self)
	if not validID(id) then return false end
	local before = self:Sendable(id)
	local m, changed = NpcData.Visit(self.sheets[id], reading, self.day, { t = self.lt, v = self.lv })
	if not changed then return false end
	self:put(id, m)
	self:limit()
	return not deepEqual(before, self:Sendable(id))
end

-- A reading kept as the last known one (npcOwn, no own-visit rules): every register read replaces
-- the held one with today's day, whatever its value; what was not read stays. New entries enter a
-- sheet at its entry limit only where an entry older than RENEW days makes room. Whether the sheet
-- changed.
function Table:Write(id, reading)
	check(self)
	if not validID(id) then return false end
	local fresh = NpcData.Visit(nil, reading, self.day, { t = self.lt, v = self.lv })
	if not fresh then return false end
	local held = self.sheets[id]
	local h = held or EMPTY
	local m = { name = h.name, nd = h.nd, map = h.map, x = h.x, y = h.y, pd = h.pd, t = {}, v = {} }
	for k, e in pairs(h.t) do m.t[k] = { e[1], e[2], e[3], e[4], e[5] } end
	for k, e in pairs(h.v) do m.v[k] = { e[1], copyPrice(e[2]), e[3] } end
	if fresh.name then m.name, m.nd = fresh.name, fresh.nd end
	if fresh.map then m.map, m.x, m.y, m.pd = fresh.map, fresh.x, fresh.y, fresh.pd end
	for k, e in pairs(fresh.t) do
		local r = m.t[k] or { 0, 0, 0, 0, 0 }
		r[1] = e[1]
		if e[2] ~= 0 then r[2], r[3] = e[2], e[3] end
		if e[4] ~= 0 then r[4], r[5] = e[4], e[5] end
		m.t[k] = r
	end
	for k, e in pairs(fresh.v) do
		local r = m.v[k] or { 0, false, 0 }
		r[1] = e[1]
		if e[2] then r[2], r[3] = e[2], e[3] end
		m.v[k] = r
	end
	makeRoom(m.t, h.t, self.lt, self.day)
	makeRoom(m.v, h.v, self.lv, self.day)
	if held and deepEqual(m, held) then return false end
	self:put(id, m)
	self:limit()
	return true
end

-- The registers of own table own (npcOwn) enter by the own-visit rules as of their own days (older
-- days change nothing; at an equal day the greater value stays), then merge. Idempotent.
function Table:Import(own)
	check(self)
	check(own)
	if own == self then return end
	local touched = false
	for id, o in pairs(own.sheets) do
		local held = self.sheets[id]
		local ins = ownRegisters(held or EMPTY, o)
		if held or next(ins.t) or next(ins.v) then
			local m = NpcData.Merge(held, ins)
			makeRoom(m.t, held and held.t or EMPTY.t, self.lt, self.day)
			makeRoom(m.v, held and held.v or EMPTY.v, self.lv, self.day)
			if not held or not deepEqual(m, held) then
				self:put(id, m)
				touched = true
			end
		end
	end
	if touched then self:limit() end
end
