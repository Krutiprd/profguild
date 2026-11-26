-- Profguild: NpcData
-- What the guild knows about trainers and recipe vendors: one sheet per NPC, merged register by
-- register. Pure: no WoW API, days are integers (UTC days, server time / 86400).
-- Here: sheets, merge, own visits, validation, packing, hashes; the table of sheets
-- (NpcData.New) is in NpcTable.lua.
--
-- Sheet:
--   { name=, nd=,                 name and its day (both nil when unknown)
--     map=, x=, y=, pd=,          place: uiMapID, finder's position in whole percent, its day (nil when unknown)
--     t = { [recipeID] = { seen, skill, skillDay, copper, copperDay } },   trained
--     v = { [itemID]   = { seen, price, priceDay } } }                     sold (recipe item)
--   In the arrays an unknown value and its day are 0; an unknown price is false with day 0.
--   price = { c = copper, o = { { kind, id, count }, ... } sorted, l = 0|1 (limited stock) },
--   kind 1 currency, 2 item.
--
-- Merge, register by register: the later day wins; at an equal day the greater value (numbers in a
-- fixed field order, names as bytes, prices by ComparePrice); an unknown never erases a known one.
-- Every register is a maximum over one total order, so Merge is a join: any order and any
-- duplicates give the same.
--
-- Own visit (Visit): a reading becomes registers of today by the rules below, and these are merged,
-- so a register that loses a tie changes nothing.
--   seen, skill, name, place: when absent or held older than RENEW days.
--   price (and trained copper, which reputation lowers the same way): when absent; other costs or
--   limited stock differ and held older than RENEW; at the same other costs and stock: higher copper
--   at once, equal after RENEW, lower after FALL days.
--   An own visit adds no entry to a sheet at its entry limit unless an entry older than RENEW days
--   makes room.

local _, ns = ...
ns = ns or {}

local NpcData = {}
ns.NpcData = NpcData

NpcData.LIMIT_T = 200            -- trained entries per sheet
NpcData.LIMIT_V = 60             -- sold entries per sheet
NpcData.EXPIRE = 120             -- an entry's register older than this is dropped
NpcData.RENEW = 14               -- an own visit renews a register older than this
NpcData.FALL = 30                -- ... and writes a lower price over one older than this
NpcData.MAX_ID = 2147483647
NpcData.MAX_COPPER = 9999990000  -- 999 999g
NpcData.MAX_COSTS = 3
NpcData.MAX_NAME = 60
NpcData.MAX_MAP = 100000
NpcData.MAX_SKILL = 1000
NpcData.SEND = 118               -- only entries and registers of at most this age are sent and hashed
NpcData.LIMIT_ENTRIES = 20000    -- entries in a table
NpcData.LIMIT_SHEETS = 600       -- sheets in a table
NpcData.EPOCH = 1                -- raised when held data must be dropped; carried in messages, saved
NpcData.PROTOCOL = 1             -- raised with any change of fields, order or limits on the wire
NpcData.HASH_MOD = 2147483647

local floor, type, pairs, sort = math.floor, type, pairs, table.sort
local RENEW, FALL = NpcData.RENEW, NpcData.FALL

local function int(v, lo, hi)
	return type(v) == "number" and v == floor(v) and v >= lo and v <= hi
end

local function validID(v) return int(v, 1, NpcData.MAX_ID) end

local function validName(s)
	-- the control bytes spelled out: %c follows the C library's locale under PUC Lua 5.1 and may
	-- take UTF-8 continuation bytes such as 0x9D (the second byte of "Ý")
	return type(s) == "string" and #s >= 1 and #s <= NpcData.MAX_NAME and not s:find("[%z\1-\31\127|]")
end

-- Strings compared as bytes (the < of Lua follows the C locale).
local function compareBytes(a, b)
	local n = #a < #b and #a or #b
	for i = 1, n do
		local x, y = a:byte(i), b:byte(i)
		if x ~= y then return x < y and -1 or 1 end
	end
	if #a == #b then return 0 end
	return #a < #b and -1 or 1
end

local function compareCost(x, y)
	for j = 1, 3 do
		if x[j] ~= y[j] then return x[j] < y[j] and -1 or 1 end
	end
	return 0
end

local function costLess(x, y) return compareCost(x, y) < 0 end

-- -1|0|1: copper, number of other costs, then kind, id, count of each in order, then l.
function NpcData.ComparePrice(a, b)
	if a.c ~= b.c then return a.c < b.c and -1 or 1 end
	local ao, bo = a.o, b.o
	if #ao ~= #bo then return #ao < #bo and -1 or 1 end
	for i = 1, #ao do
		local c = compareCost(ao[i], bo[i])
		if c ~= 0 then return c end
	end
	if a.l ~= b.l then return a.l < b.l and -1 or 1 end
	return 0
end
local ComparePrice = NpcData.ComparePrice

-- The same other costs and limited stock (copper aside).
local function sameTerms(a, b)
	if a.l ~= b.l or #a.o ~= #b.o then return false end
	for i = 1, #a.o do
		if compareCost(a.o[i], b.o[i]) ~= 0 then return false end
	end
	return true
end

local function copyPrice(p)
	if not p then return false end
	local o = {}
	for i, c in ipairs(p.o) do o[i] = { c[1], c[2], c[3] } end
	return { c = p.c, o = o, l = p.l }
end

-- A clean, sorted copy of a price, or nil.
local function cleanPrice(p)
	if type(p) ~= "table" or not int(p.c, 0, NpcData.MAX_COPPER) or (p.l ~= 0 and p.l ~= 1) then return nil end
	local src = p.o
	if src == nil then src = {} end
	if type(src) ~= "table" then return nil end
	local n = 0
	for _ in pairs(src) do
		n = n + 1
		if n > NpcData.MAX_COSTS then return nil end
	end
	local o = {}
	for i = 1, n do
		local c = src[i]
		if type(c) ~= "table" or not int(c[1], 1, 2) or not validID(c[2]) or not validID(c[3]) then return nil end
		o[i] = { c[1], c[2], c[3] }
	end
	sort(o, costLess)
	return { c = p.c, o = o, l = p.l }
end

-- Order for dropping entries at equal days: a hash of the key, not the ID (new recipes have the
-- highest IDs). Knuth's multiplicative hash mod 2^32, exact in doubles.
local function mulmod32(a, b)
	local hi, lo = floor(a / 65536), a % 65536
	return ((hi * b % 4294967296) * 65536 + lo * b) % 4294967296
end
function NpcData.KeyHash(id) return mulmod32(id, 2654435761) end
local KeyHash = NpcData.KeyHash

-- Keeps: the newer seen first, then the lower hash.
local function keepBefore(entries)
	return function(a, b)
		local sa, sb = entries[a][1], entries[b][1]
		if sa ~= sb then return sa > sb end
		return KeyHash(a) < KeyHash(b)
	end
end

local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function trim(entries, limit)
	local n = count(entries)
	if n <= limit then return end
	local ids = {}
	for id in pairs(entries) do ids[#ids + 1] = id end
	sort(ids, keepBefore(entries))
	for i = limit + 1, #ids do entries[ids[i]] = nil end
end

-- Merge ----------------------------------------------------------------------

-- A register of value v (0 unknown) and day d.
local function pickNum(av, ad, bv, bd)
	if av == 0 then return bv, bd end
	if bv == 0 then return av, ad end
	if ad ~= bd then
		if ad > bd then return av, ad end
		return bv, bd
	end
	if av >= bv then return av, ad end
	return bv, bd
end

local function pickPrice(ap, ad, bp, bd)
	if not ap then return copyPrice(bp), bp and bd or 0 end
	if not bp then return copyPrice(ap), ad end
	if ad ~= bd then
		if ad > bd then return copyPrice(ap), ad end
		return copyPrice(bp), bd
	end
	if ComparePrice(ap, bp) >= 0 then return copyPrice(ap), ad end
	return copyPrice(bp), bd
end

local function mergeT(ea, eb)
	if not eb then eb = { 0, 0, 0, 0, 0 } end
	if not ea then ea = { 0, 0, 0, 0, 0 } end
	local s, sd = pickNum(ea[2], ea[3], eb[2], eb[3])
	local c, cd = pickNum(ea[4], ea[5], eb[4], eb[5])
	return { ea[1] > eb[1] and ea[1] or eb[1], s, sd, c, cd }
end

local function mergeV(ea, eb)
	if not eb then eb = { 0, false, 0 } end
	if not ea then ea = { 0, false, 0 } end
	local p, pd = pickPrice(ea[2], ea[3], eb[2], eb[3])
	return { ea[1] > eb[1] and ea[1] or eb[1], p, pd }
end

local EMPTY = { t = {}, v = {} }

-- A new sheet; a and b (either may be nil) are left untouched.
function NpcData.Merge(a, b)
	if not a and not b then return nil end
	a, b = a or EMPTY, b or EMPTY
	local m = { t = {}, v = {} }

	local an, bn = a.name, b.name
	if an and (not bn or a.nd > b.nd or (a.nd == b.nd and compareBytes(an, bn) >= 0)) then
		m.name, m.nd = an, a.nd
	elseif bn then
		m.name, m.nd = bn, b.nd
	end

	local src
	if a.map == nil then src = b.map ~= nil and b
	elseif b.map == nil then src = a
	elseif a.pd ~= b.pd then src = a.pd > b.pd and a or b
	elseif a.map ~= b.map then src = a.map > b.map and a or b
	elseif a.x ~= b.x then src = a.x > b.x and a or b
	else src = a.y >= b.y and a or b end
	if src then m.map, m.x, m.y, m.pd = src.map, src.x, src.y, src.pd end

	local at, bt = a.t or EMPTY.t, b.t or EMPTY.t
	for id, e in pairs(at) do m.t[id] = mergeT(e, bt[id]) end
	for id, e in pairs(bt) do if not at[id] then m.t[id] = mergeT(e, nil) end end
	local av, bv = a.v or EMPTY.v, b.v or EMPTY.v
	for id, e in pairs(av) do m.v[id] = mergeV(e, bv[id]) end
	for id, e in pairs(bv) do if not av[id] then m.v[id] = mergeV(e, nil) end end
	return m
end

-- Valid ----------------------------------------------------------------------

-- A cleaned copy, or nil when no entry is left. Bad registers become unknown, bad entries go,
-- the sheet stays. Entry registers older than EXPIRE days are dropped; head registers have no
-- lower age limit; no day may be later than tomorrow.
function NpcData.Valid(sheet, today)
	if type(sheet) ~= "table" or not int(today, 0, math.huge) then return nil end
	local function headDay(d) return int(d, 0, today + 1) end
	local oldest = today - NpcData.EXPIRE
	if oldest < 0 then oldest = 0 end
	local function entryDay(d) return int(d, oldest, today + 1) end

	local s = { t = {}, v = {} }
	if validName(sheet.name) and headDay(sheet.nd) then s.name, s.nd = sheet.name, sheet.nd end
	if int(sheet.map, 0, NpcData.MAX_MAP) and int(sheet.x, 0, 100) and int(sheet.y, 0, 100) and headDay(sheet.pd) then
		s.map, s.x, s.y, s.pd = sheet.map, sheet.x, sheet.y, sheet.pd
	end

	local n = 0
	if type(sheet.t) == "table" then
		for id, e in pairs(sheet.t) do
			if validID(id) and type(e) == "table" and entryDay(e[1]) and e[1] > 0 then
				local skill, sd, copper, cd = e[2], e[3], e[4], e[5]
				if not (int(skill, 1, NpcData.MAX_SKILL) and entryDay(sd)) then skill, sd = 0, 0 end
				if not (int(copper, 1, NpcData.MAX_COPPER) and entryDay(cd)) then copper, cd = 0, 0 end
				s.t[id] = { e[1], skill, sd, copper, cd }
				n = n + 1
			end
		end
		trim(s.t, NpcData.LIMIT_T)
	end
	if type(sheet.v) == "table" then
		for id, e in pairs(sheet.v) do
			if validID(id) and type(e) == "table" and entryDay(e[1]) and e[1] > 0 then
				local p, pd = cleanPrice(e[2]), e[3]
				if not (p and entryDay(pd)) then p, pd = false, 0 end
				s.v[id] = { e[1], p, pd }
				n = n + 1
			end
		end
		trim(s.v, NpcData.LIMIT_V)
	end
	if n == 0 then return nil end
	return s
end

-- Own visit ------------------------------------------------------------------

local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

local function renew(day, today) return day == nil or today - day > RENEW end

-- Whether a read price p goes over the held hp of day hd.
local function priceWrites(hp, hd, p, today)
	if not hp then return true end
	local age = today - hd
	if not sameTerms(hp, p) then return age > RENEW end
	if p.c > hp.c then return true end
	if p.c == hp.c then return age > RENEW end
	return age > FALL
end

-- New own entries enter a sheet over its limit only where held entries older than RENEW days make
-- room (the oldest go first); otherwise the new ones are left out (the ones kept last first).
local function makeRoom(entries, held, limit, today)
	local n = count(entries)
	if n <= limit then return end
	local old, new = {}, {}
	for id, e in pairs(entries) do
		if not held[id] then new[#new + 1] = id
		elseif today - e[1] > RENEW then old[#old + 1] = id end
	end
	local order = keepBefore(entries)
	sort(old, order)
	sort(new, order)
	for i = #old, 1, -1 do
		if n <= limit then break end
		entries[old[i]] = nil
		n = n - 1
	end
	for i = #new, 1, -1 do
		if n <= limit then break end
		entries[new[i]] = nil
		n = n - 1
	end
end

local function limits(limit)
	if type(limit) == "number" then return limit, limit end
	if type(limit) == "table" then return limit.t or NpcData.LIMIT_T, limit.v or NpcData.LIMIT_V end
	return NpcData.LIMIT_T, NpcData.LIMIT_V
end

-- reading = { name=, map=, x=, y=, t = { [id] = { skill=, copper= } }, v = { [id] = { price= } } }
-- limit: { t=, v= } entries per part, a number for both, or nil for LIMIT_T / LIMIT_V.
-- Returns the new sheet (nil when there is none) and whether it differs from held.
function NpcData.Visit(held, reading, today, limit)
	if type(reading) ~= "table" then return held, false end
	local lt, lv = limits(limit)
	local h = held or EMPTY
	local ht, hv = h.t or EMPTY.t, h.v or EMPTY.v
	local own = { t = {}, v = {} }

	if validName(reading.name) and (h.name == nil or renew(h.nd, today)) then
		own.name, own.nd = reading.name, today
	end
	if int(reading.map, 0, NpcData.MAX_MAP) and int(reading.x, 0, 100) and int(reading.y, 0, 100)
		and (h.map == nil or renew(h.pd, today)) then
		own.map, own.x, own.y, own.pd = reading.map, reading.x, reading.y, today
	end

	local entries = 0
	if type(reading.t) == "table" then
		for id, r in pairs(reading.t) do
			if validID(id) and type(r) == "table" then
				local he = ht[id]
				local e = { 0, 0, 0, 0, 0 }
				if not he or renew(he[1], today) then e[1] = today end
				if int(r.skill, 1, NpcData.MAX_SKILL) and (not he or he[2] == 0 or renew(he[3], today)) then
					e[2], e[3] = r.skill, today
				end
				if int(r.copper, 1, NpcData.MAX_COPPER) and (not he or he[4] == 0
					or priceWrites({ c = he[4], o = {}, l = 0 }, he[5], { c = r.copper, o = {}, l = 0 }, today)) then
					e[4], e[5] = r.copper, today
				end
				own.t[id] = e
				entries = entries + 1
			end
		end
	end
	if type(reading.v) == "table" then
		for id, r in pairs(reading.v) do
			if validID(id) and type(r) == "table" then
				local he = hv[id]
				local e = { 0, false, 0 }
				if not he or renew(he[1], today) then e[1] = today end
				local p = r.price ~= nil and cleanPrice(r.price)
				if p and priceWrites(he and he[2], he and he[3], p, today) then e[2], e[3] = p, today end
				own.v[id] = e
				entries = entries + 1
			end
		end
	end
	if not held and entries == 0 then return nil, false end

	local m = NpcData.Merge(held, own)
	makeRoom(m.t, ht, lt, today)
	makeRoom(m.v, hv, lv, today)
	if not held then
		if next(m.t) == nil and next(m.v) == nil then return nil, false end
		return m, true
	end
	return m, not deepEqual(m, held)
end

-- Packing --------------------------------------------------------------------
-- A sheet as a list of columns (for the wire and for SavedVariables):
--   [1] npcID, [2] name or false, [3] its day or false, [4] map or false, [5] x, [6] y, [7] place day,
--   [8] base: the sheet's newest day; every other day is stored as base - day,
--   trained, in ascending ID: [9] IDs (the first, then differences), [10] skill, [11] copper,
--     [12] seen, [13] skill day, [14] copper day,
--   sold, in ascending ID: [15] IDs, [16] copper (-1: price unknown), [17] number of other costs * 2 + l,
--     [18] seen, [19] price day, [20] the other costs of all prices in order, flat: kind, id, count, ...
-- A day column whose days all equal the base is 0; the day of an unknown register is stored as 0.

local function sortedKeys(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = k end
	sort(ks)
	return ks
end

local function flat(col)
	for i = 1, #col do
		if col[i] ~= 0 then return col end
	end
	return 0
end

function NpcData.Pack(id, s)
	local base = 0
	local function up(d) if d and d > base then base = d end end
	up(s.nd) up(s.pd)
	for _, e in pairs(s.t) do up(e[1]) up(e[3]) up(e[5]) end
	for _, e in pairs(s.v) do up(e[1]) up(e[3]) end
	local list = { id, s.name or false, s.name and base - s.nd or false, s.map or false,
		s.map and s.x or false, s.map and s.y or false, s.map and base - s.pd or false, base }

	local ids, sk, cp, d1, d2, d3, prev = {}, {}, {}, {}, {}, {}, 0
	for i, k in ipairs(sortedKeys(s.t)) do
		local e = s.t[k]
		ids[i], prev = k - prev, k
		sk[i], cp[i], d1[i] = e[2], e[4], base - e[1]
		d2[i] = e[2] ~= 0 and base - e[3] or 0
		d3[i] = e[4] ~= 0 and base - e[5] or 0
	end
	list[9], list[10], list[11], list[12], list[13], list[14] = ids, sk, cp, flat(d1), flat(d2), flat(d3)

	local vc, terms, e1, e2, costs
	ids, vc, terms, e1, e2, costs, prev = {}, {}, {}, {}, {}, {}, 0
	for i, k in ipairs(sortedKeys(s.v)) do
		local e = s.v[k]
		local p = e[2]
		ids[i], prev = k - prev, k
		e1[i] = base - e[1]
		if p then
			vc[i], terms[i], e2[i] = p.c, #p.o * 2 + p.l, base - e[3]
			for _, c in ipairs(p.o) do
				costs[#costs + 1], costs[#costs + 2], costs[#costs + 3] = c[1], c[2], c[3]
			end
		else
			vc[i], terms[i], e2[i] = -1, 0, 0
		end
	end
	list[15], list[16], list[17], list[18], list[19], list[20] = ids, vc, terms, flat(e1), flat(e2), costs
	return list
end

-- Whether c is a list of exactly n integers lo..hi (or 0, when zero allows a column of base days).
local function column(c, n, lo, hi, zero)
	if zero and c == 0 then return true end
	if type(c) ~= "table" or c[n + 1] ~= nil then return false end
	for i = 1, n do
		if not int(c[i], lo, hi) then return false end
	end
	return true
end

local function at(c, i) return c == 0 and 0 or c[i] end

local function unpackSheet(l)
	local base = l[8]
	if not int(base, 0, 1e7) then return nil end
	local s = { t = {}, v = {} }
	if l[2] ~= false then
		if type(l[2]) ~= "string" or not int(l[3], 0, base) then return nil end
		s.name, s.nd = l[2], base - l[3]
	end
	if l[4] ~= false then
		if not (int(l[4], 0, NpcData.MAX_MAP) and int(l[5], 0, 100) and int(l[6], 0, 100) and int(l[7], 0, base)) then
			return nil
		end
		s.map, s.x, s.y, s.pd = l[4], l[5], l[6], base - l[7]
	end

	-- An honest sender trims to the limits before packing: more entries are refused before any work.
	local ids = l[9]
	if type(ids) ~= "table" then return nil end
	local n = #ids
	if n > NpcData.LIMIT_T then return nil end
	if not (column(ids, n, 1, NpcData.MAX_ID) and column(l[10], n, 0, NpcData.MAX_SKILL)
		and column(l[11], n, 0, NpcData.MAX_COPPER) and column(l[12], n, 0, base, true)
		and column(l[13], n, 0, base, true) and column(l[14], n, 0, base, true)) then
		return nil
	end
	local id = 0
	for i = 1, n do
		id = id + ids[i]
		if id > NpcData.MAX_ID then return nil end
		local skill, copper = l[10][i], l[11][i]
		s.t[id] = { base - at(l[12], i), skill, skill ~= 0 and base - at(l[13], i) or 0,
			copper, copper ~= 0 and base - at(l[14], i) or 0 }
	end

	ids = l[15]
	if type(ids) ~= "table" then return nil end
	n = #ids
	if n > NpcData.LIMIT_V then return nil end
	local costs = l[20]
	if not (column(ids, n, 1, NpcData.MAX_ID) and column(l[16], n, -1, NpcData.MAX_COPPER)
		and column(l[17], n, 0, NpcData.MAX_COSTS * 2 + 1) and column(l[18], n, 0, base, true)
		and column(l[19], n, 0, base, true) and type(costs) == "table") then
		return nil
	end
	local k = 0
	id = 0
	for i = 1, n do
		id = id + ids[i]
		if id > NpcData.MAX_ID then return nil end
		local c, terms = l[16][i], l[17][i]
		local e = { base - at(l[18], i), false, 0 }
		if c >= 0 then
			local o = {}
			for j = 1, floor(terms / 2) do
				o[j] = { costs[k + 1], costs[k + 2], costs[k + 3] }
				k = k + 3
			end
			e[2], e[3] = { c = c, o = o, l = terms % 2 }, base - at(l[19], i)
		elseif terms ~= 0 then
			return nil
		end
		s.v[id] = e
	end
	if not column(costs, k, 1, NpcData.MAX_ID) then return nil end
	return s
end

-- id (nil when the list has none) and the valid sheet (nil when the list is broken or holds no entry).
function NpcData.Unpack(list, today)
	if type(list) ~= "table" or not validID(list[1]) then return nil, nil end
	local ok, s = pcall(unpackSheet, list)
	if not ok or not s then return list[1], nil end
	return list[1], NpcData.Valid(s, today)
end

-- Hashes ---------------------------------------------------------------------
-- The mixing of GuildPrices.Hash: every intermediate stays below 2^53.

local M = NpcData.HASH_MOD

local function mix(x) return (x + (x % 65521) * (x % 65519)) % M end
local function feed(x, v) return mix((x * 48271 + v % M) % M) end

-- 0..HASH_MOD-1 over the canonical numbers of a (sendable) sheet: absent parts by a marker, entries
-- in ID order.
function NpcData.HashSheet(id, s)
	local x = feed(1, id)
	if s.name then
		x = feed(feed(feed(x, 1), s.nd), #s.name)
		for i = 1, #s.name do x = feed(x, s.name:byte(i)) end
	else
		x = feed(x, 0)
	end
	if s.map then x = feed(feed(feed(feed(feed(x, 1), s.map), s.x), s.y), s.pd) else x = feed(x, 0) end
	local ks = sortedKeys(s.t)
	x = feed(x, #ks)
	for _, k in ipairs(ks) do
		local e = s.t[k]
		x = feed(x, k)
		for j = 1, 5 do x = feed(x, e[j]) end
	end
	ks = sortedKeys(s.v)
	x = feed(x, #ks)
	for _, k in ipairs(ks) do
		local e = s.v[k]
		local p = e[2]
		x = feed(feed(x, k), e[1])
		if p then
			x = feed(feed(feed(feed(feed(x, 1), p.c), #p.o), p.l), e[3])
			for _, c in ipairs(p.o) do x = feed(feed(feed(x, c[1]), c[2]), c[3]) end
		else
			x = feed(x, 0)
		end
	end
	return x
end

-- 0..65535: a hash under a salt, so hashes equal in some bits differ under most salts.
function NpcData.SaltedHash(hash, salt)
	local x = feed(feed(feed(7, hash), salt), hash)
	return floor(x / 32768) % 65536
end

-- For NpcTable.lua (the table of sheets), not for other callers.
NpcData.internal = {
	validID = validID, count = count, trim = trim, copyPrice = copyPrice, deepEqual = deepEqual,
	priceWrites = priceWrites, makeRoom = makeRoom, EMPTY = EMPTY,
}
