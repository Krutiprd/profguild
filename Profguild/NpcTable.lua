-- Profguild: NpcTable
-- The table of NPC sheets (ns.NpcData.New): expiry, the sendable part, limits, hashes, saving and
-- the npcOwn import, on top of the sheet functions of NpcData.lua. Pure: no WoW API.
--
-- The work is kept small so that it can run in slices (NpcWork): the sendable part, its hash, the
-- table hash, the counts and the recipe/item index are kept current sheet by sheet at every
-- change, never rebuilt for the whole table; a new day recuts only the sheets that hold something
-- old enough; a saved sheet that loads as it was is not packed again.

local _, ns = ...
ns = ns or {}

local NpcData = ns.NpcData
local I = NpcData.internal
local validID, count, trim, copyPrice, deepEqual = I.validID, I.count, I.trim, I.copyPrice, I.deepEqual
local priceWrites, makeRoom, EMPTY, unpackSame, compareBytes = I.priceWrites, I.makeRoom, I.EMPTY, I.unpackSame, I.compareBytes
local ComparePrice = NpcData.ComparePrice
local KeyHash, hashSheet = NpcData.KeyHash, NpcData.HashSheet
local floor, pairs, ipairs, next, sort, type = math.floor, pairs, ipairs, next, table.sort, type
local RENEW, M, HUGE = NpcData.RENEW, NpcData.HASH_MOD, math.huge

-- Helpers --------------------------------------------------------------------

-- Inside a job of the table's scheduler: waits for the next frame when an item of `units` units
-- would take this one past its budget (see NpcWork). Without a scheduler, or outside a job, nothing.
local function pace(self, units, kind)
	local w = self.work
	if w then w:Pace(units, kind) end
end

-- The sendable part: entries seen at most SEND days ago with their registers of at most SEND days,
-- and the head when such an entry is left; nil without one. Also its number of entries.
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
	if n == 0 then return nil, 0 end
	c.name, c.nd, c.map, c.x, c.y, c.pd = s.name, s.nd, s.map, s.x, s.y, s.pd
	return c, n
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

-- A register (value v, day d; 0 unknown) of b that Merge would take over a's.
local function numWins(av, ad, bv, bd)
	return bv ~= 0 and (av == 0 or bd > ad or (bd == ad and bv > av))
end

-- Whether any register of own sheet o could change held h in Import, whatever the own-visit rules
-- let in: each register of o is tried as if it entered; when none would win its merge, the merge
-- gives h itself and the sheet is skipped without merging. Never false when the merge would
-- change h (it may be true when it would not: then the merge decides).
local function mayEnter(h, o)
	if o.name and (h.name == nil or o.nd > h.nd or (o.nd == h.nd and compareBytes(h.name, o.name) < 0)) then
		return true
	end
	if o.map and (h.map == nil or o.pd > h.pd
		or (o.pd == h.pd and (o.map ~= h.map or o.x ~= h.x or o.y ~= h.y))) then
		return true
	end
	local ht, hv = h.t or EMPTY.t, h.v or EMPTY.v
	for id, e in pairs(o.t) do
		local he = ht[id]
		if not he or e[1] > he[1] or numWins(he[2], he[3], e[2], e[3]) or numWins(he[4], he[5], e[4], e[5]) then
			return true
		end
	end
	for id, e in pairs(o.v) do
		local he = hv[id]
		if not he or e[1] > he[1] then return true end
		local p = e[2]
		if p and (not he[2] or e[3] > he[3] or (e[3] == he[3] and ComparePrice(he[2], p) < 0)) then return true end
	end
	return false
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

-- The index (byT, byV): key -> the NPC ID of its one sheet, or a set { [npc] = true } of two or
-- more. A number stored in a table costs the garbage collector nothing more, a new table makes the
-- (large) index be traversed again at the end of the cycle, in one step: a pause of several ms
-- inside some frame while full tables load. Most keys are held by one NPC. The index is cut into
-- INDEX_PARTS tables by key: one of 20000 keys would grow (be rehashed and allocated anew) in one
-- step of ms, and the collector then pays for the allocation at once.
local INDEX_PARTS = 64
NpcData.INDEX_PARTS = INDEX_PARTS
local function indexAdd(index, k, id)
	local p = k % INDEX_PARTS
	local by = index[p]
	if not by then by = {} index[p] = by end
	local cur = by[k]
	if cur == nil then
		by[k] = id
	elseif type(cur) == "table" then
		cur[id] = true
	elseif cur ~= id then
		by[k] = { [cur] = true, [id] = true }
	end
end

local function indexRemove(index, k, id)
	local by = index[k % INDEX_PARTS]
	if not by then return end
	local cur = by[k]
	if cur == id then
		by[k] = nil
	elseif type(cur) == "table" then
		cur[id] = nil
		local a = next(cur)
		if a == nil then
			by[k] = nil
		elseif next(cur, a) == nil then
			by[k] = a
		end
	end
end

local function entryHash(npcHash, part, id) return KeyHash((KeyHash((npcHash + part) % 4294967296) + id) % 4294967296) end

-- A trained entry's learn skill register as a number (see Table.skillRev).
local function skillKey(id, e)
	return KeyHash((KeyHash((KeyHash(id) + e[2]) % 4294967296) + e[3]) % 4294967296)
end

-- The entries a packed list says it has (its ID columns), before it is unpacked.
local function listEntries(list)
	local a, b = list[9], list[15]
	return (type(a) == "table" and #a or 0) + (type(b) == "table" and #b or 0)
end

-- Table ----------------------------------------------------------------------
-- tab = NpcData.New(saved, now[, limits[, work]]): saved = { e = EPOCH, s = { [npcID] = packed } }
-- (limits.lean: the sendable parts are not kept, only their counts and hashes; for npcOwn)
-- is loaded (other epochs and broken sheets dropped, sheets of days after tomorrow held back: see
-- load) and kept current at every change; now() gives server seconds; limits = { t=, v=, entries=,
-- sheets= } replaces the constants (tests); work (NpcWork) runs the loading as a job: until it is
-- done tab.loading is true, the table holds part of the sheets, and saved stays as it was (the
-- loaded table is swapped in when complete). Without work the table is loaded before New returns.
-- Limits, after every merge (once for all sheets of an NU, MergeAll), in this order: entries per sheet, entries, sheets. The older goes first
-- (an entry by seen, a sheet by its newest entry), then by a hash of the key.
-- Expiry runs at load and on a new day: without work before anything is read; with work at the
-- start of the next job (a read queues one; the read, and a job running across midnight, see the
-- day before). Only the sendable part (see cut) is
-- sent, hashed and counted. Returned sheets and lists are the table's own: do not change them.
-- Every change must be made inside a job of work (or without work): see NpcWork.
--
-- Kept per sheet: sizes (entries), newest and oldest (days of its entries and known registers),
-- cuts (the sendable part), hashes, cn (sendable entries), partial (the cut left something out),
-- keysT/keysV (its keys in byT/byV), skh (its learn skills); for the table: nSheets, nEntries,
-- nSend, sendEntries, total (the table hash), ids (sorted sendable IDs, built when asked),
-- byT/byV ([key % INDEX_PARTS][recipe or item] -> npc, or { [npc] = true } when more: see
-- indexAdd), skillRev (raised when a learn skill changed).

local Table = {}
Table.__index = Table

-- saved table -> the table made on it last (see New): weak both ways, a table no longer used goes
local owners = setmetatable({}, { __mode = "kv" })

local store -- (see below)

-- Loads the saved sheets src into tab, then swaps them into target (the saved table).
local function load(tab, target)
	local today = tab.day
	-- read when the loading starts, not when the table was made: a job before it (/pg npc clear,
	-- the loading of an older table on the same saved one) may have changed saved meanwhile
	local src = target.s
	if target.e ~= NpcData.EPOCH or type(src) ~= "table" then src = {} end
	-- A saved sheet whose newest day is after tomorrow (the clock is behind the day it was saved)
	-- and that is valid as of that day is held back: it stays in saved as it is, is not held,
	-- counted or sent, no later write replaces it (Clear drops it), and it loads at a login whose
	-- clock allows it.
	local future = {}
	for key, list in pairs(src) do
		local base = type(list) == "table" and list[8]
		if type(base) == "number" and base > today + 1 and base == floor(base) then
			pace(tab, 1 + listEntries(list), "load")
			local id, s = NpcData.Unpack(list, base)
			if s and id == key then future[key] = list end
		end
	end
	tab.future = future
	local out = tab.saved.s
	for key, list in pairs(src) do
		if future[key] then
			out[key] = list
		else
			pace(tab, 1 + (type(list) == "table" and listEntries(list) or 0), "load")
			local id, s, same = unpackSame(list, today)
			if s and id == key then
				local a = trim(s.t, tab.lt)
				local b = trim(s.v, tab.lv)
				-- loaded as it was saved: the saved list stays, it is not packed again
				store(tab, id, s, same and not a and not b and list or nil)
			end
		end
	end
	tab:limit()
	-- an older table on a saved table a newer one was made on (a guild key that flickered) keeps
	-- what it loaded in memory only: the newer one loads and keeps saved
	if not tab.retired then
		target.e, target.s = NpcData.EPOCH, tab.saved.s
		tab.saved = target
	end
	tab.loading = nil
end

function NpcData.New(saved, now, limits, work)
	limits = limits or {}
	if type(saved) ~= "table" then saved = {} end
	local tab = setmetatable({ saved = saved, now = now, work = work, skillRev = 0,
		lt = limits.t or NpcData.LIMIT_T, lv = limits.v or NpcData.LIMIT_V,
		le = limits.entries or NpcData.LIMIT_ENTRIES, ls = limits.sheets or NpcData.LIMIT_SHEETS,
		lean = limits.lean or nil }, Table)
	-- A clock not known yet (0): the saved sheets are left untouched and this session's table
	-- lives in memory only (tab.detached).
	local today = tab:Today()
	if today <= 0 then tab.saved, tab.detached, tab.real = {}, true, saved end
	-- the table is built in a table of its own and swapped into saved when complete: a logout
	-- half way leaves saved as it was
	local target = tab.saved
	tab.saved = {}
	-- the newest table made on a saved table owns it: an older one (a guild key that flickered, a
	-- /reload in tests) is retired, it no longer writes saved nor settles its day (Settle)
	tab.target = target
	local old = owners[target]
	if old and old ~= tab then old.retired = true end
	owners[target] = tab
	tab:reset()
	if work then
		if work.Watch then work:Watch(tab) end
		tab.loading = true
		work:Run(function() load(tab, target) end, tab, function()
			-- an error half way: saved is left as it was, this session's table lives in memory only
			tab.loading, tab.detached, tab.real = nil, true, target
		end)
	else
		load(tab, target)
	end
	return tab
end

function Table:reset()
	self.saved.e, self.saved.s = NpcData.EPOCH, {}
	self.future = {}
	self.sheets, self.sizes, self.newest, self.oldest = {}, {}, {}, {}
	self.cuts, self.hashes, self.cn, self.partial = {}, {}, {}, {}
	self.byT, self.byV, self.keysT, self.keysV, self.skh = {}, {}, {}, {}, {}
	self.nSheets, self.nEntries = 0, 0
	self.nSend, self.sendEntries, self.total, self.ids = 0, 0, 0, nil
	self.day, self.expiring = self:Today(), nil
	self.skillRev = self.skillRev + 1
end

-- The sendable part, its hash and the counts of a sheet anew (after a change or a new day).
function Table:recut(id, prep)
	local old = self.cuts[id]
	if old then
		self.nSend, self.sendEntries = self.nSend - 1, self.sendEntries - self.cn[id]
		self.total = (self.total - self.hashes[id]) % M
	end
	local s = self.sheets[id]
	local c, n, h
	if prep and prep.day == self.day then
		c, n, h = prep.c, prep.n, prep.h
	elseif s then
		c, n = cut(s, self.day)
	end
	if c then
		h = h or hashSheet(id, c)
		-- lean (npcOwn, never sent): the sendable part is not kept, Sendable cuts it when asked
		self.cuts[id], self.hashes[id], self.cn[id] = self.lean and true or c, h, n
		self.nSend, self.sendEntries = self.nSend + 1, self.sendEntries + n
		self.total = (self.total + h) % M
	else
		self.cuts[id], self.hashes[id], self.cn[id] = nil, nil, nil
	end
	self.partial[id] = s and self.oldest[id] < self.day - NpcData.SEND or nil
	if (old ~= nil) ~= (c ~= nil) then self.ids = nil end
end

-- A sheet stored by a job in up to three items of work (packed; cut and hashed; then indexed and
-- committed by put), so that a large sheet does not make one long item. Nothing changes the table
-- between them (only this job does, and its day stays: see check), so what was prepared holds
-- when it is committed; the window sees the sheet before or after, never half stored.
function store(self, id, s, packed)
	if s and next(s.t) == nil and next(s.v) == nil then s = nil end
	local prep
	if s then
		local n = count(s.t) + count(s.v)
		if not packed and not self.future[id] and not self.retired then
			pace(self, n, "pack")
			packed = NpcData.Pack(id, s)
		end
		pace(self, n, "cut")
		local c, cn = cut(s, self.day)
		prep = { day = self.day, c = c, n = cn, h = c and hashSheet(id, c) or nil }
		pace(self, n, "index")
	else
		pace(self, (self.sizes[id] or 0) + 1, "index")
	end
	self:put(id, s, packed, prep)
end

-- Stores a sheet (nil or one without entries removes it), keeping counts, caches, the index and
-- saved current; packed: the saved list of exactly s (not packed again); prep: its cut and hash
-- of this day (see store).
function Table:put(id, s, packed, prep)
	if s and next(s.t) == nil and next(s.v) == nil then s = nil end
	local old = self.sizes[id]
	if old then self.nEntries, self.nSheets = self.nEntries - old, self.nSheets - 1 end
	self.sheets[id] = s
	local byT, byV = self.byT, self.byV
	for _, k in ipairs(self.keysT[id] or EMPTY.t) do indexRemove(byT, k, id) end
	for _, k in ipairs(self.keysV[id] or EMPTY.v) do indexRemove(byV, k, id) end
	local sk = 0
	if s then
		local n, newest, oldest, kt, kv = 0, 0, HUGE, {}, {}
		for k, e in pairs(s.t) do
			n = n + 1
			kt[#kt + 1] = k
			indexAdd(byT, k, id)
			local d = e[1]
			if d > newest then newest = d end
			if d < oldest then oldest = d end
			if e[2] ~= 0 and e[3] < oldest then oldest = e[3] end
			if e[4] ~= 0 and e[5] < oldest then oldest = e[5] end
			sk = (sk + skillKey(k, e)) % 4294967296
		end
		for k, e in pairs(s.v) do
			n = n + 1
			kv[#kv + 1] = k
			indexAdd(byV, k, id)
			local d = e[1]
			if d > newest then newest = d end
			if d < oldest then oldest = d end
			if e[2] and e[3] < oldest then oldest = e[3] end
		end
		self.sizes[id], self.newest[id], self.oldest[id], self.keysT[id], self.keysV[id] = n, newest, oldest, kt, kv
		self.nEntries, self.nSheets = self.nEntries + n, self.nSheets + 1
	else
		self.sizes[id], self.newest[id], self.oldest[id], self.keysT[id], self.keysV[id] = nil, nil, nil, nil, nil
	end
	if (self.skh[id] or 0) ~= sk then self.skillRev = self.skillRev + 1 end
	self.skh[id] = sk ~= 0 and sk or nil
	-- a held-back sheet keeps its saved place: what this session holds for that NPC is not saved
	if not self.future[id] and not self.retired then self.saved.s[id] = s and (packed or NpcData.Pack(id, s)) or nil end
	self:recut(id, prep)
end

-- Applies the table limits (the entry limit per sheet is applied by the caller).
function Table:limit()
	local sheets, sizes = self.sheets, self.sizes
	local over = self.nEntries - self.le
	if over > 0 then
		local drop = {}
		for _, d in ipairs(worst(over, function(offer, enters)
			for npc, s in pairs(sheets) do
				pace(self, sizes[npc] or 1, "scan")
				local nh = KeyHash(npc)
				for id, e in pairs(s.t) do
					if enters(e[1]) then offer(e[1], entryHash(nh, 1, id), npc, 1, id) end
				end
				for id, e in pairs(s.v) do
					if enters(e[1]) then offer(e[1], entryHash(nh, 2, id), npc, 2, id) end
				end
			end
		end)) do
			-- thousands of entries may go (a guild change): grouped in parts of 256
			if _ % 256 == 0 then pace(self, 256, "group") end
			local l = drop[d[3]]
			if not l then l = {} drop[d[3]] = l end
			l[#l + 1] = d
		end
		-- a sheet is cut in a copy and stored (store): between slices every sheet agrees with the
		-- counts, caches and index (the window reads them)
		for npc, l in pairs(drop) do
			pace(self, sizes[npc] or 1, "check")
			local s = sheets[npc]
			local m = { name = s.name, nd = s.nd, map = s.map, x = s.x, y = s.y, pd = s.pd, t = {}, v = {} }
			for k, e in pairs(s.t) do m.t[k] = e end
			for k, e in pairs(s.v) do m.v[k] = e end
			for _, d in ipairs(l) do m[d[4] == 1 and "t" or "v"][d[5]] = nil end
			store(self, npc, m)
		end
	end
	over = self.nSheets - self.ls
	if over > 0 then
		local newest = self.newest
		pace(self, self.nSheets, "scan")
		for _, d in ipairs(worst(over, function(offer)
			for npc in pairs(sheets) do offer(newest[npc], KeyHash(npc), npc, 0, 0) end
		end)) do
			store(self, d[3], nil)
		end
	end
end

function Table:Today()
	local t = self.now()
	return floor((type(t) == "number" and t or 0) / 86400)
end

-- A new day (or an expiry an error cut short). Without a scheduler expiry runs now, as at every
-- read. With one a read never changes the table, also inside a job (a job may have read IDs or
-- hashes before it waited for a frame, and may stand inside a pcall): one job is queued for it,
-- whose start settles the day (Settle, see NpcWork:Watch); until then reads see the day before.
local function due(self) return self.expiring ~= nil or self:Today() ~= self.day end

local function check(self)
	if not due(self) then return end
	local w = self.work
	if w and self.retired then return end -- an older table on the same saved one
	if not w then return self:Expire() end
	if not self.expireQueued then
		self.expireQueued = true
		local function done() self.expireQueued = nil end
		w:Run(done, self, done)
	end
end

-- At the start of every job of the scheduler (NpcWork:Watch), before it reads or changes anything:
-- the expiry of a new day, so the job works on the table of its day as a synchronous client would.
function Table:Settle()
	self.expireQueued = nil -- this start settles what the queued job was for
	if self.retired then return end
	if due(self) then self:Expire() end
end

-- Drops what is older than EXPIRE days; the sendable part is cut anew where the day changes it:
-- in the sheets that hold an entry or register older than SEND days, or whose cut left one out.
-- Resumable: the day and the list of sheets are kept (self.expiring) until the last one is done,
-- so an expiry an error cut short is finished by the next one (check and Settle see it due).
function Table:Expire()
	local day = self:Today()
	local ex = self.expiring
	if not ex or ex.day ~= day then
		-- a day later still (or the first try): the sheets an unfinished expiry left are listed again,
		-- since what the new day changes in a sheet is older than SEND days of it
		self.day = day
		local lo, list = day - NpcData.SEND, {}
		for id, d in pairs(self.oldest) do
			if d < lo or self.partial[id] then list[#list + 1] = id end
		end
		ex = { day = day, list = list, i = 1 }
		self.expiring = ex
	end
	local gone, list = day - NpcData.EXPIRE, ex.list
	while ex.i <= #list do
		local id = list[ex.i]
		-- raised first: a sheet whose expiry throws is skipped by the next try, not tried forever
		ex.i = ex.i + 1
		local s = self.sheets[id]
		if s then
			pace(self, self.sizes[id], "store")
			if self.oldest[id] < gone then
				expireSheet(s, day)
				self:put(id, s)
			else
				self:recut(id)
			end
		end
	end
	self.expiring = nil
end

-- Settle ended in an error (NpcWork recorded it; the job runs on): the next job goes on after the
-- sheet that threw; a second failure of the same expiry gives it up (the day stays, later days
-- recut again).
function Table:SettleFailed()
	local ex = self.expiring
	if not ex then return end
	ex.fails = (ex.fails or 0) + 1
	if ex.fails >= 2 then self.expiring = nil end
end

-- Everything goes, also from the saved table a detached table left untouched.
function Table:Clear()
	if self.real then self.real.e, self.real.s = NpcData.EPOCH, {} end
	-- the saved table too while this one still loads (a loading not started yet then finds it empty)
	local t = self.target
	if t and not self.detached then t.e, t.s = NpcData.EPOCH, {} end
	self:reset()
end

function Table:Get(id)
	check(self)
	return self.sheets[id]
end

-- The sendable part as kept, or cut now for a lean table.
local function cutOf(self, id)
	local c = self.cuts[id]
	if c == true then return (cut(self.sheets[id], self.day)) end
	return c
end

function Table:Sendable(id)
	check(self)
	return cutOf(self, id)
end

-- Sorted IDs of the sheets with a sendable part.
function Table:SendableIDs()
	check(self)
	if not self.ids then
		local ids = {}
		for id in pairs(self.cuts) do ids[#ids + 1] = id end
		sort(ids)
		self.ids = ids
	end
	return self.ids
end

-- Sendable sheets and their entries.
function Table:Count()
	check(self)
	return self.nSend, self.sendEntries
end

-- 0..HASH_MOD-1 of the sendable sheet, nil without one.
function Table:SheetHash(id)
	check(self)
	return self.hashes[id]
end

-- The sum of the sheet hashes modulo HASH_MOD; 0 for an empty table.
function Table:Hash()
	check(self)
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
		-- the work of the item: the held sheet and the received one (valid, merged, stored)
		local x = items[i][2]
		local n = type(x) == "table" and ((type(x.t) == "table" and count(x.t) or 0) + (type(x.v) == "table" and count(x.v) or 0)) or 0
		pace(self, (validID(id) and self.sizes[id] or 0) + n + 10, "mergeput")
		local s = validID(id) and NpcData.Valid(items[i][2], self.day) or nil
		if s then
			valid[i] = s
			if before[id] == nil then before[id] = cutOf(self, id) or false end
			local held = self.sheets[id]
			local m = NpcData.Merge(held, s)
			trim(m.t, self.lt)
			trim(m.v, self.lv)
			if not held or not deepEqual(m, held) then
				store(self, id, m)
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
			pace(self, (self.sizes[id] or 0) + 10, "check")
			local now = self.sheets[id]
			if now then
				for k in pairs(s.t) do if now.t[k] then t = true break end end
				if not t then
					for k in pairs(s.v) do if now.v[k] then t = true break end end
				end
			end
			c = not deepEqual(before[id] or nil, cutOf(self, id))
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
	pace(self, (self.sizes[id] or 0) + 100, "mergeput")
	local before = cutOf(self, id)
	local m, changed = NpcData.Visit(self.sheets[id], reading, self.day, { t = self.lt, v = self.lv })
	if not changed then return false end
	store(self, id, m)
	self:limit()
	return not deepEqual(before, cutOf(self, id))
end

-- A reading kept as the last known one (npcOwn, no own-visit rules): every register read replaces
-- the held one with today's day, whatever its value; what was not read stays. New entries enter a
-- sheet at its entry limit only where an entry older than RENEW days makes room. Whether the sheet
-- changed.
function Table:Write(id, reading)
	check(self)
	if not validID(id) then return false end
	pace(self, (self.sizes[id] or 0) + 100, "mergeput")
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
	store(self, id, m)
	self:limit()
	return true
end

-- The registers of own table own (npcOwn) enter by the own-visit rules as of their own days (older
-- days change nothing; at an equal day the greater value stays), then merge. Idempotent. An own
-- sheet none of whose registers could win over the held one is skipped (mayEnter).
function Table:Import(own)
	check(self)
	check(own)
	if own == self then return end
	local touched = false
	for id, o in pairs(own.sheets) do
		local held = self.sheets[id]
		local n = (own.sizes[id] or 0) + (self.sizes[id] or 0)
		pace(self, n, "check")
		if mayEnter(held or EMPTY, o) then
			-- two items: the merged sheet is made (nothing changes), then stored; only this job
			-- changes the table, so held is still the sheet m was made from
			pace(self, n, "merge")
			local ins = ownRegisters(held or EMPTY, o)
			if held or next(ins.t) or next(ins.v) then
				local m = NpcData.Merge(held, ins)
				pace(self, n, "room")
				makeRoom(m.t, held and held.t or EMPTY.t, self.lt, self.day)
				makeRoom(m.v, held and held.v or EMPTY.v, self.lv, self.day)
				if not held or not deepEqual(m, held) then
					store(self, id, m)
					touched = true
				end
			end
		end
	end
	if touched then self:limit() end
end
