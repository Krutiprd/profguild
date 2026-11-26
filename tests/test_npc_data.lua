-- NPC sheets: registers, merge (a join), own visits and validation.
-- Days in these tests are D + n, so a day of the brief like "100@10" is D + 10.
local H = ...
local ns = H.newNamespace({ "NpcData.lua", "NpcTable.lua" })
local ND = ns.NpcData

local D = 20000
local LIMIT = { t = 200, v = 60 }

local function deepEq(a, b)
	if a == b then return true end
	if a ~= a and b ~= b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end

local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function price(c, o, l) return { c = c, o = o or {}, l = l or 0 } end

-- Random sheets over small domains, so equal days with different values happen often.
local seed = 12345
local function rnd(n)
	seed = (seed * 1103515245 + 12345) % 2147483648
	return math.floor(seed / 2147483648 * n) + 1
end
local function pick(list) return list[rnd(#list)] end

local function costLess(x, y)
	for j = 1, 3 do
		if x[j] ~= y[j] then return x[j] < y[j] end
	end
	return false
end

local function randomSheet()
	local s = { t = {}, v = {} }
	if rnd(2) == 1 then s.name, s.nd = pick({ "A", "B", "Ab", "a" }), D + rnd(3) end
	if rnd(2) == 1 then s.map, s.x, s.y, s.pd = rnd(2), pick({ 0, 5 }), pick({ 0, 5 }), D + rnd(3) end
	for id = 1, 5 do
		if rnd(2) == 1 then
			local e = { D + rnd(3), 0, 0, 0, 0 }
			if rnd(3) > 1 then e[2], e[3] = pick({ 10, 20 }), D + rnd(3) end
			if rnd(3) > 1 then e[4], e[5] = pick({ 100, 200 }), D + rnd(3) end
			s.t[id] = e
		end
	end
	for id = 1, 4 do
		if rnd(2) == 1 then
			local e = { D + rnd(3), false, 0 }
			if rnd(3) > 1 then
				local o = {}
				for _ = 1, rnd(3) - 1 do o[#o + 1] = { rnd(2), rnd(2), rnd(2) } end
				table.sort(o, costLess)
				e[2], e[3] = price(pick({ 0, 100 }), o, rnd(2) - 1), D + rnd(3)
			end
			s.v[id] = e
		end
	end
	return s
end

H.test("npc data: merge is a join", function()
	for i = 1, 2000 do
		local a, b, c = randomSheet(), randomSheet(), randomSheet()
		local a0, b0 = copy(a), copy(b)
		local ab = ND.Merge(a, b)
		H.ok(deepEq(a, a0) and deepEq(b, b0), "merge leaves its arguments untouched " .. i)
		H.ok(deepEq(ab, ND.Merge(b, a)), "commutative " .. i)
		H.ok(deepEq(ND.Merge(ab, c), ND.Merge(a, ND.Merge(b, c))), "associative " .. i)
		H.ok(deepEq(ND.Merge(a, a), a), "idempotent " .. i)
		H.ok(deepEq(ND.Merge(a, ab), ab), "absorbs a duplicate " .. i)
	end
	local a = randomSheet()
	H.ok(deepEq(ND.Merge(a, nil), a) and deepEq(ND.Merge(nil, a), a), "merge with nothing")
	H.ok(ND.Merge(a, nil) ~= a, "a new table")
end)

H.test("npc data: later day wins, equal day greater value, unknown never erases", function()
	local function skill(v, d) return { t = { [1] = { D, v, d and D + d or 0, 0, 0 } }, v = {} } end
	local m = ND.Merge(skill(50, 10), skill(40, 11))
	H.eq(m.t[1][2], 40, "later day") H.eq(m.t[1][3], D + 11)
	m = ND.Merge(skill(50, 10), skill(40, 10))
	H.eq(m.t[1][2], 50, "equal day: greater") H.eq(m.t[1][3], D + 10)
	m = ND.Merge(skill(50, 10), skill(0))
	H.eq(m.t[1][2], 50, "unknown never erases") H.eq(m.t[1][3], D + 10)
	m = ND.Merge(skill(0), skill(50, 10))
	H.eq(m.t[1][2], 50, "unknown never erases, other side")

	local function place(map, x, y, d) return { map = map, x = x, y = y, pd = D + d, t = { [1] = { D, 0, 0, 0, 0 } }, v = {} } end
	m = ND.Merge(place(2, 0, 0, 5), place(1, 90, 90, 6))
	H.eq(m.map, 1, "place: later day") H.eq(m.x, 90)
	m = ND.Merge(place(1, 90, 90, 5), place(2, 0, 0, 5))
	H.eq(m.map, 2, "place: greater map")
	m = ND.Merge(place(1, 4, 0, 5), place(1, 3, 90, 5))
	H.eq(m.x, 4, "place: then x") H.eq(m.y, 0)
	m = ND.Merge(place(1, 4, 1, 5), place(1, 4, 2, 5))
	H.eq(m.y, 2, "place: then y")
	m = ND.Merge(place(1, 4, 1, 5), { t = { [2] = { D, 0, 0, 0, 0 } }, v = {} })
	H.eq(m.map, 1, "place: unknown never erases") H.eq(m.pd, D + 5)

	local function name(n, d) return { name = n, nd = D + d, t = { [1] = { D, 0, 0, 0, 0 } }, v = {} } end
	H.eq(ND.Merge(name("B", 5), name("a", 5)).name, "a", "name as bytes")
	H.eq(ND.Merge(name("a", 5), name("ab", 5)).name, "ab", "longer after its prefix")
	H.eq(ND.Merge(name("\200", 5), name("z", 5)).name, "\200", "bytes above 127 are greater")
	H.eq(ND.Merge(name("z", 6), name("\200", 5)).name, "z", "name: later day")

	local function sold(p, d) return { t = {}, v = { [7] = { D, p, p and D + d or 0 } } } end
	m = ND.Merge(sold(price(100), 5), sold(price(90, { { 1, 3, 1 } }), 5))
	H.eq(m.v[7][2].c, 100, "price: greater copper first")
	m = ND.Merge(sold(price(100), 5), sold(price(100, { { 1, 3, 1 } }), 5))
	H.eq(#m.v[7][2].o, 1, "price: then more other costs")
	m = ND.Merge(sold(price(100), 6), sold(false))
	H.eq(m.v[7][2].c, 100, "price: unknown never erases") H.eq(m.v[7][3], D + 6)
	H.eq(ND.Merge(sold(price(100, {}, 0), 5), sold(price(100, {}, 1), 5)).v[7][2].l, 1, "price: then l")
end)

H.test("npc data: ComparePrice", function()
	local C = ND.ComparePrice
	H.eq(C(price(1), price(2)), -1) H.eq(C(price(2), price(1)), 1) H.eq(C(price(2), price(2)), 0)
	H.eq(C(price(5, { { 2, 1, 1 } }), price(5, { { 1, 1, 1 }, { 1, 2, 1 } })), -1, "number of other costs")
	H.eq(C(price(5, { { 2, 1, 1 } }), price(5, { { 1, 9, 9 } })), 1, "kind")
	H.eq(C(price(5, { { 1, 1, 9 } }), price(5, { { 1, 2, 1 } })), -1, "id")
	H.eq(C(price(5, { { 1, 1, 2 } }), price(5, { { 1, 1, 1 } })), 1, "count")
	H.eq(C(price(5, { { 1, 1, 1 } }, 0), price(5, { { 1, 1, 1 } }, 1)), -1, "l")
	H.eq(C(price(5, { { 1, 1, 1 } }, 1), price(5, { { 1, 1, 1 } }, 1)), 0, "equal")
end)

local function trainerReading(skills, extra)
	local r = { name = "Trainer", map = 1415, x = 40, y = 60, t = {}, v = {} }
	for id, s in pairs(skills) do r.t[id] = { skill = s, copper = 1000 } end
	for k, v in pairs(extra or {}) do r[k] = v end
	return r
end

H.test("npc data: own visit", function()
	local s, changed = ND.Visit(nil, trainerReading({ [1] = 50 }), D, LIMIT)
	H.ok(changed, "absent: written")
	H.eq(s.t[1][1], D, "seen") H.eq(s.t[1][2], 50) H.eq(s.t[1][3], D) H.eq(s.t[1][4], 1000) H.eq(s.t[1][5], D)
	H.eq(s.name, "Trainer") H.eq(s.nd, D) H.eq(s.map, 1415) H.eq(s.x, 40) H.eq(s.y, 60) H.eq(s.pd, D)

	local r = trainerReading({ [1] = 60 }, { name = "Other", map = 1416 })
	local s14, c14 = ND.Visit(s, r, D + 14, LIMIT)
	H.ok(not c14, "14 days old: nothing written")
	H.ok(deepEq(s14, s), "14 days old: unchanged")
	local s15, c15 = ND.Visit(s, r, D + 15, LIMIT)
	H.ok(c15, "15 days old: written")
	H.eq(s15.t[1][1], D + 15, "seen renewed") H.eq(s15.t[1][2], 60, "skill") H.eq(s15.t[1][3], D + 15)
	H.eq(s15.name, "Other", "name") H.eq(s15.nd, D + 15) H.eq(s15.map, 1416, "place") H.eq(s15.pd, D + 15)

	-- each register by its own day
	local held = { name = "Trainer", nd = D + 10, map = 1415, x = 40, y = 60, pd = D,
		t = { [1] = { D + 10, 50, D, 1000, D + 10 }, [2] = { D + 10, 0, 0, 0, 0 } }, v = {} }
	local h = ND.Visit(held, trainerReading({ [1] = 60, [2] = 70 }, { name = "Other", map = 1416 }), D + 15, LIMIT)
	H.eq(h.t[1][1], D + 10, "seen 5 days old: kept")
	H.eq(h.t[1][2], 60, "skill 15 days old: written") H.eq(h.t[1][3], D + 15)
	H.eq(h.t[2][2], 70, "skill absent: written")
	H.eq(h.name, "Trainer", "name 5 days old: kept") H.eq(h.map, 1416, "place 15 days old: written")
	h = ND.Visit({ t = { [1] = { D + 10, 0, 0, 0, 0 } }, v = {} }, trainerReading({ [1] = 60 }), D + 11, LIMIT)
	H.eq(h.name, "Trainer", "name absent: written") H.eq(h.map, 1415, "place absent: written")
	H.eq(h.t[1][1], D + 10, "seen 1 day old: kept")

	-- a reading without a value leaves the held one alone
	h = ND.Visit(held, { t = { [1] = {} }, v = {} }, D + 40, LIMIT)
	H.eq(h.t[1][2], 50, "unknown reading keeps skill") H.eq(h.t[1][4], 1000) H.eq(h.name, "Trainer") H.eq(h.map, 1415)
	H.ok(deepEq(held.t[1], { D + 10, 50, D, 1000, D + 10 }), "held untouched")
	-- a bad reading value is not written
	h = ND.Visit(nil, trainerReading({ [1] = 1001 }, { name = "a|b", x = 101 }), D, LIMIT)
	H.eq(h.t[1][2], 0, "skill 1001 is unknown") H.eq(h.name, nil) H.eq(h.map, nil)
	H.eq(ND.Visit(nil, { name = "X", t = {}, v = {} }, D, LIMIT), nil, "no entries make no sheet")
end)

local function soldReading(p) return { name = "Vendor", t = {}, v = { [7] = { price = p } } } end

H.test("npc data: price", function()
	local held = { t = {}, v = { [7] = { D + 10, price(100), D + 10 } } }
	local function after(p, day) return ND.Visit(held, soldReading(p), D + day, LIMIT).v[7] end
	H.eq(after(price(120), 11)[2].c, 120, "higher at once") H.eq(after(price(120), 11)[3], D + 11)
	H.eq(after(price(90), 40)[2].c, 100, "lower after 30 days: no") H.eq(after(price(90), 40)[3], D + 10)
	H.eq(after(price(90), 41)[2].c, 90, "lower after 31 days") H.eq(after(price(90), 41)[3], D + 41)
	H.eq(after(price(100), 24)[3], D + 10, "equal after 14 days: no")
	H.eq(after(price(100), 25)[3], D + 25, "equal after 15 days")
	local other = price(100, { { 1, 1220, 5 } })
	H.eq(#after(other, 24)[2].o, 0, "other costs after 14 days: no")
	H.eq(#after(other, 25)[2].o, 1, "other costs after 15 days") H.eq(after(other, 25)[3], D + 25)
	H.eq(after(price(100, {}, 1), 24)[2].l, 0, "limited stock after 14 days: no")
	H.eq(after(price(100, {}, 1), 25)[2].l, 1, "limited stock after 15 days")
	H.eq(after(price(130, {}, 1), 24)[2].l, 0, "higher copper with other stock waits like other costs")
	local fresh = ND.Visit({ t = {}, v = { [7] = { D, false, 0 } } }, soldReading(price(90)), D + 1, LIMIT)
	H.eq(fresh.v[7][2].c, 90, "absent: written")
	local sorted = ND.Visit(nil, soldReading(price(5, { { 2, 9, 1 }, { 1, 9, 1 } })), D, LIMIT)
	H.eq(sorted.v[7][2].o[1][1], 1, "other costs sorted")
end)

H.test("npc data: two reputations", function()
	local s, writes, last = nil, {}, nil
	for day = 0, 119 do
		s = ND.Visit(s, soldReading(price(day % 2 == 0 and 100 or 90)), D + day, LIMIT)
		if s.v[7][3] ~= last then writes[#writes + 1], last = day, s.v[7][3] end
	end
	for i = 2, #writes do
		H.ok(writes[i] - writes[i - 1] >= 14, "at most one price write per 14 days")
	end
	H.eq(s.v[7][2].c, 100, "the base price stays")

	local tokens = price(0, { { 1, 42, 5 } })
	s, last = nil, nil
	local n = 0
	for day = 0, 59 do
		s = ND.Visit(s, soldReading(day % 2 == 0 and price(100) or tokens), D + day, LIMIT)
		if s.v[7][3] ~= last then n, last = n + 1, s.v[7][3] end
	end
	H.ok(n <= 5, "100c / 5 tokens: at most 5 writes, got " .. n)
end)

H.test("npc data: wrong price", function()
	local s = { t = {}, v = { [7] = { D, price(500), D } } }
	s = ND.Visit(s, soldReading(price(90)), D + 30, LIMIT)
	s = ND.Visit(s, soldReading(price(90)), D + 60, LIMIT)
	H.eq(s.v[7][2].c, 90, "90 by day 60")
end)

H.test("npc data: filtered window", function()
	local full = {}
	for id = 1, 20 do full[id] = id * 5 end
	local s = ND.Visit(nil, trainerReading(full), D, LIMIT)
	local again, c0 = ND.Visit(s, trainerReading(full), D, LIMIT)
	H.ok(not c0, "full reading twice the same day: no change") H.ok(deepEq(again, s))
	local part = trainerReading({ [3] = 15, [7] = 35, [11] = 55 })
	local s2 = ND.Visit(s, part, D + 1, LIMIT)
	H.eq(count(s2.t), 20, "20 remain")
	local s3, c3 = ND.Visit(s2, part, D + 1, LIMIT)
	H.ok(not c3, "second identical reading: changed == false") H.ok(deepEq(s3, s2))
end)

H.test("npc data: entry limit", function()
	local full = {}
	for id = 1, 200 do full[id] = 10 end
	local s = ND.Visit(nil, trainerReading(full), D, LIMIT)
	H.eq(count(s.t), 200)
	local others = {}
	for id = 1001, 1010 do others[id] = 10 end
	local s2, changed = ND.Visit(s, trainerReading(others), D, LIMIT)
	H.ok(not changed, "full sheet: unchanged") H.eq(count(s2.t), 200) H.eq(s2.t[1001], nil)

	for id = 191, 200 do s.t[id][1] = D - 15 end
	local s3, c3 = ND.Visit(s, trainerReading(others), D, LIMIT)
	H.ok(c3, "old entries make room") H.eq(count(s3.t), 200)
	for id = 1001, 1010 do H.ok(s3.t[id], "new one entered " .. id) end
	for id = 191, 200 do H.eq(s3.t[id], nil, "old one left " .. id) end

	-- 12 new, 10 old: only 10 enter, nothing fresh is pushed out
	for id = 1011, 1012 do others[id] = 10 end
	local s4 = ND.Visit(s, trainerReading(others), D, LIMIT)
	H.eq(count(s4.t), 200, "still at the limit")
	for id = 1, 190 do H.ok(s4.t[id], "fresh entry kept " .. id) end
	local entered = 0
	for id = 1001, 1012 do if s4.t[id] then entered = entered + 1 end end
	H.eq(entered, 10, "as many enter as made room")

	-- an entry 14 days old makes no room
	for id = 191, 200 do s.t[id][1] = D - 14 end
	H.eq(count(ND.Visit(s, trainerReading(others), D, LIMIT).t), 200)
	H.eq(ND.Visit(s, trainerReading(others), D, LIMIT).t[1001], nil, "14 days old: no room")

	-- sold entries by their own limit; a number limits both parts
	local v = { t = {}, v = {} }
	for id = 1, 60 do v.v[id] = { D, false, 0 } end
	local r = { t = {}, v = { [500] = { price = price(1) } } }
	H.eq(ND.Visit(v, r, D, LIMIT).v[500], nil, "60 sold: full")
	H.ok(ND.Visit(v, r, D, { t = 200, v = 61 }).v[500], "61 allowed: enters")
	H.eq(ND.Visit(v, r, D, 60).v[500], nil, "a number limits both")
	H.eq(count(ND.Visit(nil, trainerReading(full), D, 150).t), 150, "a new sheet is cut to the limit")
end)

H.test("npc data: Valid", function()
	local T = D
	local function base()
		return { name = "Vendor", nd = T, map = 1415, x = 50, y = 50, pd = T,
			t = { [100] = { T, 10, T, 100, T } },
			v = { [200] = { T, price(5, { { 1, 3, 4 } }, 0), T } } }
	end
	local function valid(change)
		local s = base()
		change(s)
		return ND.Valid(s, T)
	end
	local good = ND.Valid(base(), T)
	H.ok(deepEq(good, base()), "a valid sheet stays as it is")
	local b = base()
	H.ok(ND.Valid(b, T) ~= b and ND.Valid(b, T).v[200][2] ~= b.v[200][2], "a copy")

	-- head
	H.eq(valid(function(s) s.name = string.rep("n", 60) end).name, string.rep("n", 60), "name 60 bytes")
	for _, bad in ipairs({ string.rep("n", 61), "", "a|b", "a\nb", "a\127", 5, true, string.rep("n", 100000) }) do
		local s = valid(function(s) s.name = bad end)
		H.ok(s, "sheet kept") H.eq(s.name, nil, "name dropped") H.eq(s.nd, nil) H.eq(s.map, 1415, "place kept")
	end
	H.eq(valid(function(s) s.nd = 1.5 end).name, nil, "name day fraction")
	H.eq(valid(function(s) s.nd = nil end).name, nil, "name without day")
	for _, ok in ipairs({ { "map", 0 }, { "map", 100000 }, { "x", 0 }, { "x", 100 }, { "y", 100 } }) do
		H.eq(valid(function(s) s[ok[1]] = ok[2] end)[ok[1]], ok[2], ok[1] .. " " .. ok[2])
	end
	for _, bad in ipairs({ { "map", -1 }, { "map", 100001 }, { "x", 101 }, { "y", -1 }, { "x", 50.5 },
		{ "map", 0 / 0 }, { "map", "5" }, { "y", false }, { "x", nil }, { "pd", 1 / 0 } }) do
		local s = valid(function(s) s[bad[1]] = bad[2] end)
		H.ok(s, "sheet kept") H.eq(s.map, nil, "place dropped " .. bad[1]) H.eq(s.x, nil) H.eq(s.pd, nil)
		H.eq(s.name, "Vendor", "name kept")
	end
	H.eq(valid(function(s) s.nd, s.pd = T - 500, T - 500 end).nd, T - 500, "head 500 days old kept")
	H.eq(valid(function(s) s.pd = T - 500 end).map, 1415, "place 500 days old kept")
	H.eq(valid(function(s) s.nd = T + 1 end).name, "Vendor", "head tomorrow kept")
	H.eq(valid(function(s) s.nd = T + 2 end).name, nil, "head after tomorrow dropped")
	H.eq(valid(function(s) s.pd = T + 2 end).map, nil, "place after tomorrow dropped")

	-- trained registers
	local function skill(v) return valid(function(s) s.t[100][2] = v end).t[100] end
	H.eq(skill(1)[2], 1) H.eq(skill(1000)[2], 1000)
	for _, bad in ipairs({ 1001, 0.5, -1, 0 / 0, "10", true }) do
		local e = skill(bad)
		H.eq(e[2], 0, "skill dropped " .. tostring(bad)) H.eq(e[3], 0) H.eq(e[4], 100, "copper kept")
	end
	local function copper(v) return valid(function(s) s.t[100][4] = v end).t[100] end
	H.eq(copper(1)[4], 1) H.eq(copper(9999990000)[4], 9999990000)
	H.eq(copper(9999990001)[4], 0, "trained copper beyond") H.eq(copper(9999990001)[5], 0)
	H.eq(copper("1")[4], 0, "trained copper string")
	H.eq(valid(function(s) s.t[100][2] = 0 end).t[100][3], 0, "unknown has day 0")
	H.eq(valid(function(s) s.t[100][3] = T - 120 end).t[100][2], 10, "register 120 days old kept")
	H.eq(valid(function(s) s.t[100][3] = T - 121 end).t[100][2], 0, "register 121 days old dropped")
	H.eq(valid(function(s) s.t[100][5] = T + 1 end).t[100][4], 100, "register tomorrow kept")
	H.eq(valid(function(s) s.t[100][5] = T + 2 end).t[100][4], 0, "register after tomorrow dropped")
	H.ok(valid(function(s) s.t[100][1] = T - 120 end).t[100], "seen 120 days old kept")
	H.eq(valid(function(s) s.t[100][1] = T - 121 end).t[100], nil, "seen 121 days old: entry dropped")
	H.ok(valid(function(s) s.t[100][1] = T + 1 end).t[100], "seen tomorrow kept")
	H.eq(valid(function(s) s.t[100][1] = T + 2 end).t[100], nil, "seen after tomorrow dropped")
	H.eq(valid(function(s) s.t[100][1] = 0 end).t[100], nil, "entry without seen dropped")
	H.eq(valid(function(s) s.t[100][1] = nil end).t[100], nil, "entry without seen dropped (nil)")
	H.eq(valid(function(s) s.t[100] = true end).t[100], nil, "entry not a table")
	local long = valid(function(s) for i = 6, 100000 do s.t[100][i] = i end end).t[100]
	H.eq(#long, 5, "huge entry cut to its registers")

	-- keys
	local keys = valid(function(s)
		s.t[2147483647] = { T, 0, 0, 0, 0 }
		s.t[2147483648] = { T, 0, 0, 0, 0 }
		s.t[0] = { T, 0, 0, 0, 0 }
		s.t[1.5] = { T, 0, 0, 0, 0 }
		s.t.x = { T, 0, 0, 0, 0 }
		s.v[-1] = { T, false, 0 }
	end)
	H.ok(keys.t[2147483647], "ID at its bound") H.eq(keys.t[2147483648], nil, "ID beyond")
	H.eq(keys.t[0], nil) H.eq(keys.t[1.5], nil) H.eq(keys.t.x, nil) H.eq(keys.v[-1], nil, "negative ID")
	H.eq(valid(function(s) s.t = "x" end).t[100], nil, "t not a table") H.ok(valid(function(s) s.t = nil end))

	-- sold registers
	local function sold(p) return valid(function(s) s.v[200][2] = p end).v[200] end
	H.eq(sold(price(0))[2].c, 0, "sold copper 0") H.eq(sold(price(9999990000))[2].c, 9999990000)
	local three = { { 1, 1, 1 }, { 1, 2, 1 }, { 2, 2147483647, 2147483647 } }
	H.eq(#sold(price(1, three))[2].o, 3, "3 other costs")
	H.eq(sold(price(1, { { 2, 5, 1 }, { 1, 5, 1 } }))[2].o[1][1], 1, "other costs sorted")
	local hugeList = {}
	for i = 1, 100000 do hugeList[i] = { 1, i, 1 } end
	for name, bad in pairs({
		beyond = price(9999990001), negative = price(-1), fraction = price(1.5), nan = price(0 / 0),
		four = price(1, { { 1, 1, 1 }, { 1, 2, 1 }, { 1, 3, 1 }, { 1, 4, 1 } }), huge = price(1, hugeList),
		kind = price(1, { { 3, 1, 1 } }), id0 = price(1, { { 1, 0, 1 } }), idBeyond = price(1, { { 1, 2147483648, 1 } }),
		count0 = price(1, { { 1, 1, 0 } }), countBeyond = price(1, { { 1, 1, 2147483648 } }), l2 = price(1, {}, 2),
		lBool = price(1, {}, true), costNotTable = price(1, { 5 }), oString = { c = 1, o = "x", l = 0 },
		str = "5", number = 5, yes = true,
	}) do
		local e = sold(bad)
		H.ok(e, "entry kept " .. name) H.eq(e[2], false, "price dropped " .. name) H.eq(e[3], 0)
	end
	H.eq(valid(function(s) s.v[200][3] = T - 121 end).v[200][2], false, "price 121 days old dropped")
	H.eq(valid(function(s) s.v[200][3] = T - 120 end).v[200][2].c, 5, "price 120 days old kept")
	H.eq(valid(function(s) s.v[200][3] = T + 2 end).v[200][2], false, "price after tomorrow dropped")

	-- entries per sheet
	local function many(part, n, old)
		return valid(function(s)
			for id = 1, n do s[part][1000 + id] = part == "t" and { T, 0, 0, 0, 0 } or { T, false, 0 } end
			s[part][1000 + old][1] = T - 1
			s.t[100], s.v[200] = nil, nil
		end)
	end
	H.eq(count(many("t", 200, 5).t), 200, "200 trained kept")
	local t201 = many("t", 201, 5)
	H.eq(count(t201.t), 200, "201 trained: one dropped") H.eq(t201.t[1005], nil, "the older goes")
	H.eq(count(many("v", 60, 5).v), 60, "60 sold kept")
	local v61 = many("v", 61, 7)
	H.eq(count(v61.v), 60, "61 sold: one dropped") H.eq(v61.v[1007], nil, "the older goes")
	local tie1 = many("t", 202, 1)
	local tie2 = many("t", 202, 1)
	H.ok(deepEq(tie1, tie2), "equal days: a fixed order")

	-- no entries, no sheet
	H.eq(valid(function(s) s.t, s.v = {}, {} end), nil, "sheet without entries")
	H.eq(valid(function(s) s.t[100][1], s.v[200][1] = 0, T + 5 end), nil, "only bad entries")
	H.eq(ND.Valid("sheet", T), nil) H.eq(ND.Valid(nil, T), nil)
	local unsorted = base()
	unsorted.v[200][2].o = { { 2, 1, 1 }, { 1, 1, 1 } }
	ND.Valid(unsorted, T)
	H.eq(unsorted.v[200][2].o[1][1], 2, "the argument is untouched")
	H.eq(valid(function(s) s.extra = 5 end).extra, nil, "unknown fields dropped")
end)

-- Table ----------------------------------------------------------------------

H.loadLibs()
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")
local function encode(msg) return LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg))) end
local function nu(packed)
	return { t = "NU", pv = 1, e = 1, f = "Alliance", s = "Player-1234-0ABCDEF0", h = 2147483646, x = packed }
end

-- A table on its own clock: tab, set(day).
local function newTable(day, saved, limits)
	local clock = day * 86400 + 3600
	local tab = ND.New(saved or {}, function() return clock end, limits)
	return tab, function(d) clock = d * 86400 + 3600 end
end

local function entries(n, seen, first)
	local t = {}
	for id = first or 1, (first or 1) + n - 1 do t[id] = { seen, 0, 0, 0, 0 } end
	return t
end

-- Random valid sheets over the full domains (days today - 120 .. tomorrow).
local function wideSheet(today)
	local function day() return today + 2 - rnd(122) end
	local s = { t = {}, v = {} }
	if rnd(3) > 1 then
		local b = {}
		for i = 1, rnd(60) do
			local c = 31 + rnd(95)
			if c == 124 then c = 65 end
			b[i] = string.char(c)
		end
		s.name, s.nd = table.concat(b), today + 1 - rnd(5000)
	end
	if rnd(3) > 1 then s.map, s.x, s.y, s.pd = rnd(100001) - 1, rnd(101) - 1, rnd(101) - 1, today + 1 - rnd(5000) end
	for _ = 1, rnd(30) - 1 do
		local e = { day(), 0, 0, 0, 0 }
		if rnd(3) > 1 then e[2], e[3] = rnd(1000), day() end
		if rnd(3) > 1 then e[4], e[5] = rnd(9999990000), day() end
		s.t[rnd(2147483647)] = e
	end
	for _ = 1, rnd(10) - 1 do
		local e = { day(), false, 0 }
		if rnd(3) > 1 then
			local o = {}
			for j = 1, rnd(4) - 1 do o[j] = { rnd(2), rnd(2147483647), rnd(2147483647) } end
			table.sort(o, costLess)
			e[2], e[3] = price(rnd(9999990001) - 1, o, rnd(2) - 1), day()
		end
		s.v[rnd(2147483647)] = e
	end
	return ND.Valid(s, today)
end

H.test("npc data: expiry", function()
	local B = D + 300
	local tab, set = newTable(B)
	tab:MergeIn(5, { name = "N", nd = B - 900, t = { [1] = { B, 10, B - 1, 20, B }, [2] = { B - 1, 0, 0, 0, 0 } },
		v = { [3] = { B, price(5), B } } })
	set(B + 119)
	H.ok(tab:Get(5).t[2] and tab:Get(5).t[1][2] == 10, "120 days old stays")
	set(B + 120)
	local s = tab:Get(5)
	H.eq(s.t[2], nil, "entry 121 days old goes with its seen")
	H.eq(s.t[1][2], 0, "register 121 days old goes") H.eq(s.t[1][3], 0)
	H.eq(s.t[1][4], 20, "register 120 days old stays") H.eq(s.name, "N", "head stays")
	H.ok(tab.saved.s[5], "saved")
	set(B + 121)
	H.eq(tab:Get(5), nil, "head goes with the last entry")
	H.eq(tab.saved.s[5], nil, "saved too")

	-- Expire runs before Hash, SendableIDs and Sendable when the day advanced without a call
	for _, call in ipairs({ "Hash", "SendableIDs", "Sendable", "SheetHash", "Count" }) do
		local t2, set2 = newTable(B)
		t2:MergeIn(5, { t = { [1] = { B, 0, 0, 0, 0 } }, v = {} })
		H.ok(t2:Hash() ~= 0, "held")
		set2(B + 121)
		t2[call](t2, 5)
		H.eq(t2.saved.s[5], nil, "expired before " .. call)
	end
end)

H.test("npc data: sendable", function()
	local T = D + 300
	local tab = newTable(T)
	tab:MergeIn(5, { name = "N", nd = T - 900, t = {
		[1] = { T - 118, 10, T - 119, 20, T - 118 }, [2] = { T - 119, 5, T - 119, 0, 0 } },
		v = { [3] = { T - 118, price(5), T - 119 } } })
	local c = tab:Sendable(5)
	H.ok(deepEq(c, { name = "N", nd = T - 900, t = { [1] = { T - 118, 0, 0, 20, T - 118 } },
		v = { [3] = { T - 118, false, 0 } } }), "118 in, 119 out, older registers out")
	H.eq(tab:Get(5).t[2][2], 5, "held still")
	local other = newTable(T)
	other:MergeIn(5, { name = "N", nd = T - 900, t = { [1] = { T - 118, 0, 0, 20, T - 118 } },
		v = { [3] = { T - 118, false, 0 } } })
	H.eq(tab:Hash(), other:Hash(), "hash without the 119-day parts")
	H.eq(tab:SheetHash(5), other:SheetHash(5))
	local s1, e1 = tab:Count()
	H.eq(s1, 1, "counted: sheets") H.eq(e1, 2, "counted: sendable entries")

	local old = newTable(T)
	old:MergeIn(6, { name = "N", nd = T, t = { [1] = { T - 119, 0, 0, 0, 0 } }, v = {} })
	H.ok(old:Get(6), "held")
	H.eq(old:Sendable(6), nil, "a sheet without a sendable entry")
	H.eq(#old:SendableIDs(), 0) H.eq(old:Hash(), 0) H.eq(old:SheetHash(6), nil)
	H.eq(select(1, old:Count()), 0)
end)

H.test("npc data: hash", function()
	local T = D + 3
	H.eq(newTable(T):Hash(), 0, "empty is 0")
	for trial = 1, 30 do
		local sheets = {}
		for i = 1, 12 do sheets[i] = { 100 + rnd(20), randomSheet() } end
		local a, b = newTable(T), newTable(T)
		for i = 1, #sheets do a:MergeIn(sheets[i][1], sheets[i][2]) end
		for i = #sheets, 1, -1 do b:MergeIn(sheets[i][1], sheets[i][2]) end
		H.eq(a:Hash(), b:Hash(), "independent of insertion order " .. trial)
		H.ok(a:Hash() >= 0 and a:Hash() < 2147483647 and a:Hash() == math.floor(a:Hash()), "range")
	end

	local function sheet()
		return { name = "Ab", nd = T - 5, map = 3, x = 4, y = 5, pd = T - 6,
			t = { [10] = { T, 7, T - 1, 9, T - 2 }, [11] = { T - 3, 0, 0, 0, 0 } },
			v = { [20] = { T, price(5, { { 1, 2, 3 }, { 2, 2, 3 } }, 1), T - 1 }, [21] = { T, false, 0 } } }
	end
	local function hashOf(change)
		local s = sheet()
		change(s)
		local tab = newTable(T)
		tab:MergeIn(1, s)
		return tab:Hash()
	end
	local base = hashOf(function() end)
	H.eq(base, hashOf(function() end), "equal content equal hash")
	local seen = { [base] = true }
	local changes = {
		function(s) s.name = "Ac" end, function(s) s.nd = T - 4 end, function(s) s.name, s.nd = nil, nil end,
		function(s) s.map = 4 end, function(s) s.x = 5 end, function(s) s.y = 6 end, function(s) s.pd = T - 7 end,
		function(s) s.map, s.x, s.y, s.pd = nil, nil, nil, nil end,
		function(s) s.t[12] = s.t[11]; s.t[11] = nil end, function(s) s.t[11] = nil end,
		function(s) s.v[22] = s.v[21]; s.v[21] = nil end, function(s) s.v[22] = { T, false, 0 } end,
		function(s) s.v[20][2].l = 0 end, function(s) s.v[20][2].c = 6 end, function(s) s.v[20][3] = T end,
		function(s) s.v[20][2].o[2][3] = 4 end, function(s) s.v[20][2].o[2][2] = 3 end,
		function(s) s.v[20][2].o[2] = nil end, function(s) s.v[21][1] = T - 1 end,
		function(s) s.v[21][2], s.v[21][3] = price(0), T end,
	}
	for j = 1, 5 do
		changes[#changes + 1] = function(s) s.t[10][j] = s.t[10][j] - 1 end
	end
	for i, change in ipairs(changes) do
		local h = hashOf(change)
		H.ok(not seen[h], "one register or day changed: different hash " .. i)
		seen[h] = true
	end
	local x, y = newTable(T), newTable(T)
	x:MergeIn(1, sheet()) y:MergeIn(2, sheet())
	H.ok(x:Hash() ~= y:Hash(), "another NPC ID")

	-- salts
	local tab = newTable(T)
	local pairsTested = 0
	for i = 1, 300 do
		local h1 = rnd(2147483647) - 1
		local h2 = (h1 + 65536 * rnd(32767)) % 2147483647
		if h2 % 65536 == h1 % 65536 and h2 ~= h1 then
			pairsTested = pairsTested + 1
			local differ = 0
			for salt = 1, 64 do
				local s1, s2 = tab:SaltedHash(h1, salt), tab:SaltedHash(h2, salt)
				H.ok(s1 >= 0 and s1 <= 65535 and s1 == math.floor(s1), "salted range")
				if s1 ~= s2 then differ = differ + 1 end
			end
			H.ok(differ >= 60, "equal low 16 bits differ under 60 of 64 salts " .. i .. ": " .. differ)
		end
	end
	H.ok(pairsTested > 100, "pairs tested")
	H.eq(tab:SaltedHash(12345, 7), tab:SaltedHash(12345, 7), "fixed")
end)

H.test("npc data: limits", function()
	local T = D + 300
	-- 201 trained
	local tab = newTable(T)
	tab:MergeIn(1, { t = entries(200, T, 1), v = {} })
	H.eq(select(2, tab:Count()), 200)
	local changed, taken = tab:MergeIn(1, { t = { [1000] = { T - 1, 0, 0, 0, 0 } }, v = {} })
	H.ok(not changed and not taken, "the older is not taken")
	H.eq(tab:Get(1).t[1000], nil)
	changed, taken = tab:MergeIn(1, { t = { [1001] = { T, 0, 0, 0, 0 } }, v = {} })
	local worst, worstHash = nil, -1
	for id = 1, 200 do if ND.KeyHash(id) > worstHash then worst, worstHash = id, ND.KeyHash(id) end end
	if ND.KeyHash(1001) > worstHash then worst = 1001 end
	H.ok(worst ~= 1001 and worst ~= 200, "the case tests the hash, not the ID")
	H.eq(tab:Get(1).t[worst], nil, "ties by hash")
	H.ok(tab:Get(1).t[1001] and tab:Get(1).t[200], "the highest IDs stay")
	H.ok(changed and taken, "taken")
	H.eq(select(2, tab:Count()), 200)

	-- 601 sheets
	tab = newTable(T)
	for id = 1, 601 do tab:MergeIn(id, { t = { [1] = { id == 300 and T - 1 or T, 0, 0, 0, 0 } }, v = {} }) end
	H.eq(tab:Count(), 600, "600 sheets") H.eq(tab:Get(300), nil, "the older sheet goes")
	changed, taken = tab:MergeIn(300, { t = { [1] = { T - 1, 0, 0, 0, 0 } }, v = {} })
	H.ok(not changed and not taken, "refused")
	tab:MergeIn(300, { t = { [1] = { T, 0, 0, 0, 0 } }, v = {} })
	worst, worstHash = nil, -1
	for id = 1, 601 do if ND.KeyHash(id) > worstHash then worst, worstHash = id, ND.KeyHash(id) end end
	H.eq(tab:Count(), 600) H.eq(tab:Get(worst), nil, "equal days: by hash")
	H.ok(worst ~= 601 and tab:Get(300) and tab:Get(601), "not by ID")
	for id in pairs(tab.saved.s) do H.ok(tab:Get(id), "saved current") end

	-- 20000 entries
	tab = newTable(T)
	for id = 1, 100 do tab:MergeIn(id, { t = entries(150, T, 1), v = entries(49, T, 1) }) end
	tab:MergeIn(101, { t = entries(110, T - 5, 1), v = {} })
	local s, n = tab:Count()
	H.eq(n, 20000, "20000 entries") H.eq(s, 101) H.eq(count(tab:Get(101).t), 100, "the older entries go")
	tab:MergeIn(102, { t = entries(20, T - 6, 1), v = entries(5, T, 1) })
	s, n = tab:Count()
	H.eq(n, 20000, "20000 entries") H.eq(s, 102)
	H.eq(count(tab:Get(102).t), 0, "the oldest go") H.eq(count(tab:Get(102).v), 5)
	H.eq(count(tab:Get(101).t), 95, "then the older of another sheet")
	tab:MergeIn(103, { t = entries(5, T - 7, 1), v = {} })
	H.eq(tab:Get(103), nil, "a sheet whose entries all go goes with them") H.eq(tab.saved.s[103], nil)

	-- the order: entries per sheet, entries, sheets (as at load)
	local function load(sheets, limits)
		local saved = { e = 1, s = {} }
		for id, sh in pairs(sheets) do saved.s[id] = ND.Pack(id, sh) end
		return newTable(T, saved, limits)
	end
	tab = load({ [1] = { t = { [1] = { T, 0, 0, 0, 0 }, [2] = { T - 9, 0, 0, 0, 0 } }, v = {} },
		[2] = { t = entries(3, T - 1), v = {} }, [3] = { t = entries(2, T - 2), v = {} } },
		{ t = 2, v = 2, entries = 5, sheets = 3 })
	H.eq(count(tab:Get(3).t), 2, "per sheet before entries") H.eq(tab:Get(1).t[2], nil)
	H.eq(select(2, tab:Count()), 5)
	tab = load({ [1] = { t = { [1] = { T, 0, 0, 0, 0 }, [2] = { T - 9, 0, 0, 0, 0 } }, v = {} },
		[2] = { t = entries(2, T - 1), v = {} }, [3] = { t = entries(2, T - 2), v = {} } },
		{ t = 2, v = 2, entries = 5, sheets = 2 })
	H.eq(tab:Get(1).t[2], nil, "entries before sheets") H.eq(tab:Get(3), nil)
	H.eq(select(2, tab:Count()), 3)

	-- three tables over every limit exchanging repeatedly become equal
	local L = { t = 4, v = 3, entries = 40, sheets = 8 }
	for trial = 1, 20 do
		local tabs = { (newTable(T, nil, L)), (newTable(T, nil, L)), (newTable(T, nil, L)) }
		for _, x in ipairs(tabs) do
			for _ = 1, 12 do
				local sh = { t = {}, v = {} }
				for _ = 1, rnd(8) do sh.t[rnd(10)] = { T - rnd(5), rnd(3) - 1, T - rnd(5), 0, 0 } end
				for _ = 1, rnd(5) - 1 do sh.v[rnd(10)] = { T - rnd(5), rnd(2) == 1 and price(rnd(3)) or false, T - rnd(5) } end
				for _, e in pairs(sh.t) do if e[2] == 0 then e[3] = 0 end end
				for _, e in pairs(sh.v) do if not e[2] then e[3] = 0 end end
				x:MergeIn(rnd(20), sh)
				local ns, ne = 0, 0
				for _, h in pairs(x.sheets) do ns, ne = ns + 1, ne + count(h.t) + count(h.v) end
				H.ok(ne <= 40 and ns <= 8 and count(x.saved.s) == ns, "within the limits")
			end
		end
		local equal = false
		for _ = 1, 10 do
			for i, from in ipairs(tabs) do
				for j, to in ipairs(tabs) do
					if i ~= j then
						for _, id in ipairs(from:SendableIDs()) do to:MergeIn(id, from:Sendable(id)) end
					end
				end
			end
			equal = tabs[1]:Hash() == tabs[2]:Hash() and tabs[2]:Hash() == tabs[3]:Hash()
				and deepEq(tabs[1].saved, tabs[2].saved) and deepEq(tabs[2].saved, tabs[3].saved)
			if equal then break end
		end
		H.ok(equal, "equal after exchanges " .. trial)
		H.eq(tabs[1]:Count(), 8, "full " .. trial)
	end
end)

H.test("npc data: unpack refuses parts over the entry limits", function()
	local T = D + 300
	local function sheet(nt, nv)
		local s = { t = entries(nt, T), v = {} }
		for id = 1, nv do s.v[id] = { T, false, 0 } end
		return s
	end
	local _, s = ND.Unpack(ND.Pack(1, sheet(ND.LIMIT_T, ND.LIMIT_V)), T)
	H.ok(s ~= nil and count(s.t) == ND.LIMIT_T and count(s.v) == ND.LIMIT_V, "at the limits it unpacks")
	local id
	id, s = ND.Unpack(ND.Pack(1, sheet(ND.LIMIT_T + 1, 1)), T)
	H.eq(id, 1, "trained over: id") H.eq(s, nil, "trained over the limit: no sheet")
	id, s = ND.Unpack(ND.Pack(1, sheet(1, ND.LIMIT_V + 1)), T)
	H.eq(id, 1, "sold over: id") H.eq(s, nil, "sold over the limit: no sheet")
	_, s = ND.Unpack(ND.Pack(1, sheet(80000, 0)), T)
	H.eq(s, nil, "80 000 trained entries: no sheet")
end)

H.test("npc data: pack", function()
	local T = D + 300
	local n = 0
	while n < 1000 do
		local s = wideSheet(T)
		if s then
			n = n + 1
			local id = rnd(2147483647)
			local list = ND.Pack(id, s)
			local id2, s2 = ND.Unpack(list, T)
			H.eq(id2, id, "id " .. n)
			H.ok(deepEq(s2, s), "round trip " .. n)
			local ok, back = LS:Deserialize(LS:Serialize(list))
			H.ok(ok and deepEq(select(2, ND.Unpack(back, T)), s), "serialized round trip " .. n)
		end
	end

	local same, mixed = { t = {}, v = {} }, { t = {}, v = {} }
	for id = 1, 50 do
		same.t[id * 37] = { T, 300, T, 5000, T }
		mixed.t[id * 37] = { T - id % 7, 300, T - id % 5, 5000, T - id % 3 }
	end
	H.ok(#LS:Serialize(ND.Pack(1, same)) < #LS:Serialize(ND.Pack(1, mixed)), "all days equal is shorter")

	local good = { name = "N", nd = T, map = 1, x = 2, y = 3, pd = T,
		t = { [5] = { T, 1, T, 2, T - 1 }, [9] = { T - 1, 0, 0, 3, T } },
		v = { [7] = { T, price(5, { { 1, 2, 3 } }, 1), T }, [8] = { T, false, 0 } } }
	local function bad(change)
		local list = ND.Pack(4, good)
		local ok, _, s = pcall(function()
			local l = change(list) or list
			return ND.Unpack(l, T)
		end)
		return ok and s == nil
	end
	H.ok(not bad(function() end), "the good one unpacks")
	H.ok(deepEq(select(2, ND.Unpack(ND.Pack(4, good), T)), good), "and equals")
	local cases = {
		string = function() return "x" end, empty = function() return {} end, number = function() return 5 end,
		idString = function(l) l[1] = "4" end, idNaN = function(l) l[1] = 0 / 0 end,
		baseNaN = function(l) l[8] = 0 / 0 end, baseString = function(l) l[8] = "1" end, baseNeg = function(l) l[8] = -1 end,
		nameNumber = function(l) l[2] = 5 end, ndNaN = function(l) l[3] = 0 / 0 end, mapString = function(l) l[4] = "1" end,
		idsString = function(l) l[9] = "x" end, idsNaN = function(l) l[9][2] = 0 / 0 end, idsZero = function(l) l[9][2] = 0 end,
		idsFraction = function(l) l[9][1] = 1.5 end, idsInf = function(l) l[9][1] = 1 / 0 end,
		skillShort = function(l) l[10][2] = nil end, skillLong = function(l) l[10][3] = 1 end,
		copperNaN = function(l) l[11][1] = 0 / 0 end, seenString = function(l) l[12] = { "0", "1" } end,
		seenTable = function(l) l[12] = { {}, 1 } end, daysShort = function(l) l[14] = { 1 } end,
		vidsShort = function(l) l[16][2] = nil end, termsNaN = function(l) l[17][1] = 0 / 0 end,
		termsOver = function(l) l[17][1] = 9 end, costsShort = function(l) l[20][3] = nil end,
		costsLong = function(l) l[20][4] = 1 end, costsNaN = function(l) l[20][2] = 0 / 0 end,
		costsString = function(l) l[20] = "abc" end, cutInHalf = function(l) for i = 11, 20 do l[i] = nil end end,
		unknownPriceWithTerms = function(l) l[17][2] = 2 end, negativeDay = function(l) l[18] = { -1, 0 } end,
	}
	for name, change in pairs(cases) do H.ok(bad(change), "nil without an error: " .. name) end
end)

-- Every part full, every value random over its bounds (random values compress worst).
local function maximumSheet(today)
	local function day() return today - rnd(119) + 1 end
	local function id() return rnd(2147483647) end
	local b = {}
	for i = 1, 60 do
		local c = 31 + rnd(224)
		if c == 124 or c == 127 then c = 65 end
		b[i] = string.char(c)
	end
	local s = { name = table.concat(b), nd = day(), map = rnd(100001) - 1, x = rnd(101) - 1, y = rnd(101) - 1,
		pd = day(), t = {}, v = {} }
	while count(s.t) < 200 do s.t[id()] = { day(), rnd(1000), day(), rnd(9999990000), day() } end
	while count(s.v) < 60 do
		local o = {}
		for j = 1, 3 do o[j] = { rnd(2), id(), rnd(2147483647) } end
		table.sort(o, costLess)
		s.v[id()] = { day(), price(rnd(9999990001) - 1, o, rnd(2) - 1), day() }
	end
	return s
end

H.test("npc data: maximum sheet", function()
	local T = D + 300
	local worst = 0
	for _ = 1, 20 do
		local s = maximumSheet(T)
		H.ok(deepEq(ND.Valid(s, T), s), "every value valid")
		local bytes = #encode(nu({ ND.Pack(2147483647, s) }))
		if bytes > worst then worst = bytes end
	end
	H.ok(worst <= 6144, "maximum sheet in one NU: " .. worst)
end)

H.test("npc data: full game", function()
	local T = D + 300
	local sheets, id = {}, 3000
	local pools = {}
	for p = 1, 12 do
		pools[p] = {}
		for i = 1, 150 do pools[p][i] = { 2000 + rnd(60000), 5 * rnd(90), 10 * rnd(5000) } end
	end
	for i = 1, 180 do
		id = id + 5 + rnd(85)
		local s = { name = "Trainer Name " .. id, nd = T, map = 1400 + rnd(100), x = rnd(100), y = rnd(100), pd = T, t = {}, v = {} }
		if i <= 100 then
			local pool = pools[rnd(12)]
			local n = 19 + rnd(51)
			while count(s.t) < n do
				local r = pool[rnd(150)]
				s.t[r[1]] = { T, r[2], T, r[3], T }
			end
		else
			while count(s.v) < 10 do s.v[2000 + rnd(40000)] = { T, price(100 * rnd(500)), T } end
		end
		sheets[#sheets + 1] = ND.Pack(id, s)
	end
	local total, msg = 0, {}
	for i, p in ipairs(sheets) do
		msg[#msg + 1] = p
		if i == #sheets or #encode(nu(msg)) >= 1000 then
			total = total + #encode(nu(msg))
			msg = {}
		end
	end
	H.ok(total <= 60000, "full game: " .. total)
end)

H.test("npc data: load", function()
	local T = D + 300
	local function sh(seen) return { name = "N", nd = T, t = { [1] = { seen, 5, seen, 0, 0 } }, v = {} } end
	local tab = newTable(T)
	tab:MergeIn(1, sh(T)) tab:MergeIn(2, sh(T - 1))
	H.ok(deepEq(tab.saved.s[1], ND.Pack(1, tab:Get(1))), "saved is current")
	local again = newTable(T, tab.saved)
	H.eq(again:Hash(), tab:Hash(), "loads what was saved")

	local other = newTable(T, { e = 2, s = { [1] = ND.Pack(1, sh(T)) } })
	H.eq(other:Count(), 0, "other epoch dropped") H.eq(other.saved.e, 1) H.eq(next(other.saved.s), nil)

	local saved = { e = 1, s = "junk" }
	local junk = newTable(T, saved)
	H.eq(junk:Count(), 0, "s a string") H.eq(type(saved.s), "table")
	junk:MergeIn(1, sh(T))
	H.ok(saved.s[1], "saved into the given table")

	local half = ND.Pack(2, sh(T))
	for i = 11, #half do half[i] = nil end
	saved = { e = 1, s = { [1] = ND.Pack(1, sh(T)), [2] = half, [3] = "x", [4] = ND.Pack(5, sh(T)), x = { 1 },
		[6] = ND.Pack(6, sh(T - 121)) } }
	local rest = newTable(T, saved)
	H.eq(rest:Count(), 1, "the rest loads") H.ok(rest:Get(1))
	H.eq(saved.s[2], nil, "cut in half dropped") H.eq(saved.s[3], nil) H.eq(saved.s[4], nil, "wrong key")
	H.eq(saved.s.x, nil) H.eq(saved.s[6], nil, "expired at load")

	-- 600 sheets, 20000 entries: load and hash
	saved = { e = 1, s = {} }
	for id = 1, 600 do
		local s = { name = "Some Trainer " .. id, nd = T, map = 1400, x = 50, y = 50, pd = T, t = {}, v = {} }
		for r = 1, 34 do s.t[id * 100 + r] = { T - r % 50, 5 * r, T - r % 30, 100 * r, T - r % 20 } end
		saved.s[id] = ND.Pack(id, s)
	end
	local start = os.clock()
	local big = newTable(T, saved)
	local h = big:Hash()
	local took = os.clock() - start
	local s, n = big:Count()
	H.eq(s, 600) H.eq(n, 20000) H.ok(h > 0)
	H.ok(took < 2, "load and hash in under 2 s: " .. took)
	start = os.clock()
	for i = 1, 600 do big:MergeIn(1000 + i, { t = entries(3, T, 1), v = {} }) big:Hash() end
	H.ok(os.clock() - start < 2, "600 merges and hashes at the limits: " .. (os.clock() - start))
	H.eq(big:Count(), 600)
end)

H.test("npc data: import", function()
	local T = D + 300
	local clock = (T - 40) * 86400
	local now = function() return clock end
	local guild, own = ND.New({}, now), ND.New({}, now)
	guild:MergeIn(5, { t = { [1] = { T - 40, 90, T - 40, 0, 0 } }, v = {} })
	clock = (T - 28) * 86400
	guild:MergeIn(5, { t = { [2] = { T - 28, 80, T - 28, 0, 0 } }, v = {} })
	clock = (T - 20) * 86400
	own:OwnVisit(5, { name = "Own", t = { [1] = { skill = 100, copper = 500 }, [2] = { skill = 100 } } })
	own:OwnVisit(6, { name = "Six", v = { [3] = { price = price(7) } } })
	clock = T * 86400
	guild:MergeIn(5, { t = { [1] = { T - 10, 0, 0, 600, T - 10 } }, v = {} })
	guild:Import(own)
	local s = guild:Get(5)
	H.ok(deepEq(s.t[1], { T - 10, 100, T - 20, 600, T - 10 }), "a 20-day-old register enters as of its own day, newer stays")
	H.ok(deepEq(s.t[2], { T - 28, 80, T - 28, 0, 0 }), "an 8 days newer one does not")
	H.eq(s.name, "Own") H.eq(s.nd, T - 20)
	H.ok(deepEq(guild:Get(6), own:Get(6)), "a sheet the guild lacks")
	local h, saved = guild:Hash(), copy(guild.saved)
	guild:Import(own)
	H.eq(guild:Hash(), h, "twice changes nothing") H.ok(deepEq(guild.saved, saved))
	H.eq(own:Get(5).t[1][2], 100, "own untouched")

	guild:Clear()
	H.eq(guild:Count(), 0, "clear") H.eq(next(guild.saved.s), nil)
end)

-- Bounds the tests above leave open (the 0.7.0 mutation check) ----------------

H.test("npc data: 1 is a value; other costs of the same number differ in both directions; cost kind 0", function()
	local one = { t = { [1] = { D, 1, D + 1, 1, D + 1 } }, v = {} }
	H.ok(deepEq(ND.Merge(one, nil).t[1], { D, 1, D + 1, 1, D + 1 }), "skill 1 and copper 1 kept by a merge")
	H.ok(deepEq(ND.Merge(nil, one).t[1], { D, 1, D + 1, 1, D + 1 }), "skill 1 and copper 1 kept, other side")

	local held = { t = {}, v = { [7] = { D, price(100, { { 1, 5, 1 } }), D } } }
	for _, id in ipairs({ 4, 6 }) do
		local s = ND.Visit(held, soldReading(price(120, { { 1, id, 1 } })), D + 1, LIMIT)
		H.eq(s.v[7][2].c, 100, "other cost id " .. id .. " instead of 5: a higher copper waits 14 days")
		s = ND.Visit(held, soldReading(price(90, { { 1, id, 1 } })), D + 15, LIMIT)
		H.eq(s.v[7][2].c, 90, "other cost id " .. id .. " instead of 5: a lower copper after 15 days")
	end

	H.eq(ND.Valid({ t = {}, v = { [7] = { D, price(1, { { 0, 1, 1 } }), D } } }, D).v[7][2], false, "cost kind 0 is no price")
end)

H.test("npc data: Valid at the bounds of head days, places and trained copper 0", function()
	local function sheet() return { name = "V", nd = D, map = 1, x = 50, y = 50, pd = D, t = { [1] = { D, 10, D, 100, D } }, v = {} } end
	local function valid(k, v)
		local s = sheet()
		s[k] = v
		return ND.Valid(s, D)
	end
	H.eq(valid("nd", 0).name, "V", "a name of day 0 is kept") H.eq(valid("nd", -1).name, nil, "a name of day -1 is dropped")
	H.eq(valid("pd", 0).map, 1, "a place of day 0 is kept") H.eq(valid("pd", -1).map, nil, "a place of day -1 is dropped")
	H.eq(valid("y", 0).y, 0, "y 0") H.eq(valid("y", 101).map, nil, "y 101") H.eq(valid("x", -1).map, nil, "x -1")
	local s = sheet()
	s.t[1][4] = 0
	local e = ND.Valid(s, D).t[1]
	H.eq(e[4], 0, "trained copper 0 is unknown") H.eq(e[5], 0, "with day 0")
end)

H.test("npc data: an own visit pushes out only as many old entries as the new ones need", function()
	local held = { t = {}, v = {} }
	for id = 1, 10 do held.t[id] = { D - 20, 10, D - 20, 0, 0 } end
	local s = ND.Visit(held, trainerReading({ [100] = 10 }), D, { t = 10, v = 60 })
	H.eq(count(s.t), 10, "at the limit, not below") H.ok(s.t[100], "the new one entered")
end)

H.test("npc data: own visit at the bounds of places, skill and copper", function()
	local function place(map, x, y) return ND.Visit(nil, trainerReading({ [1] = 50 }, { map = map, x = x, y = y }), D, LIMIT) end
	for _, ok in ipairs({ { 0, 0, 0 }, { 1, 100, 100 } }) do
		local s = place(ok[1], ok[2], ok[3])
		H.eq(s.map, ok[1], "place written " .. table.concat(ok, ",")) H.eq(s.x, ok[2]) H.eq(s.y, ok[3])
	end
	for _, bad in ipairs({ { -1, 5, 5 }, { 1, -1, 5 }, { 1, 5, -1 }, { 1, 101, 5 }, { 1, 5, 101 } }) do
		H.eq(place(bad[1], bad[2], bad[3]).map, nil, "place not written " .. table.concat(bad, ","))
	end
	local s = ND.Visit(nil, { t = { [1] = { skill = 1, copper = 1 } }, v = {} }, D, LIMIT)
	H.eq(s.t[1][2], 1, "skill 1 is written") H.eq(s.t[1][4], 1, "copper 1 is written")
	s = ND.Visit({ t = { [1] = { D - 1, 0, 0, 0, 0 } }, v = {} }, { t = { [1] = { skill = 0, copper = 0 } }, v = {} }, D, LIMIT)
	H.ok(deepEq(s.t[1], { D - 1, 0, 0, 0, 0 }), "skill and copper 0 are not written")
	local held = { t = { [1] = { D, 1, D, 1, D } }, v = {} }
	s = ND.Visit(held, { t = { [1] = { skill = 5, copper = 1 } }, v = {} }, D + 1, LIMIT)
	H.ok(deepEq(s.t[1], { D, 1, D, 1, D }), "a held skill 1 and copper 1 of yesterday stay")
end)

H.test("npc data: pack and unpack at the bounds", function()
	local T = D + 300
	local function sheet(x)
		return { name = "N", nd = T - 3, map = x == 0 and 0 or 100000, x = x, y = x, pd = T - 2,
			t = { [5] = { T, 1, T - 7, 1, T - 9 }, [9] = { T - 1, 0, 0, 0, 0 }, [2147483647] = { T, 0, 0, 0, 0 } },
			v = { [3] = { T, price(5, { { 1, 2, 3 } }), T - 1 }, [4] = { T - 1, false, 0 }, [2147483647] = { T, false, 0 } } }
	end
	for _, x in ipairs({ 0, 100 }) do
		local s = sheet(x)
		H.ok(deepEq(select(2, ND.Unpack(ND.Pack(1, s), T)), s), "round trip: place " .. x .. ", skill and copper 1, ID 2^31-1")
	end
	local list = ND.Pack(1, sheet(0))
	H.eq(list[13][2], 0, "the day of an unknown skill is stored as 0")
	H.eq(list[14][2], 0, "the day of an unknown copper is stored as 0")
	local cases = {
		ndNeg = function(l) l[3] = -1 end, mapNeg = function(l) l[4] = -1 end, xNeg = function(l) l[5] = -1 end,
		x101 = function(l) l[5] = 101 end, yNeg = function(l) l[6] = -1 end, y101 = function(l) l[6] = 101 end,
		pdNeg = function(l) l[7] = -1 end, skillNeg = function(l) l[10][1] = -1 end, copperNeg = function(l) l[11][1] = -1 end,
		seenNeg = function(l) l[12][1] = -1 end, skillDayNeg = function(l) l[13][1] = -1 end,
		copperDayNeg = function(l) l[14][1] = -1 end, vidsZero = function(l) l[15][2] = 0 end,
		priceMinus2 = function(l) l[16][2] = -2 end, termsNeg = function(l) l[17][1], l[20] = -1, {} end,
		vseenNeg = function(l) l[18][1] = -1 end, priceDayNeg = function(l) l[19][1] = -1 end,
		fourCosts = function(l) l[17][1], l[20] = 8, { 1, 2, 3, 1, 2, 4, 1, 2, 5, 1, 2, 6 } end,
		unknownPriceLimited = function(l) l[17][2] = 1 end, costZero = function(l) l[20][2] = 0 end,
	}
	for name, change in pairs(cases) do
		local l = ND.Pack(1, sheet(0))
		change(l)
		local id, s = ND.Unpack(l, T)
		H.eq(id, 1, name) H.eq(s, nil, "a broken list is no sheet: " .. name)
	end
end)

H.test("npc data: hash values are fixed (clients compare them)", function()
	local s = { name = "Ab", nd = 20005, map = 1415, x = 40, y = 60, pd = 20004,
		t = { [5] = { 20005, 10, 20003, 500, 20002 }, [9] = { 20004, 0, 0, 0, 0 } },
		v = { [7] = { 20005, price(100, { { 1, 42, 5 } }, 1), 20005 }, [8] = { 20001, false, 0 } } }
	H.eq(ND.HashSheet(1234, s), 1429718044, "HashSheet")
	H.eq(ND.SaltedHash(1429718044, 77), 38687, "SaltedHash")
	H.eq(ND.KeyHash(1234), 2808649522, "KeyHash")
end)

H.test("npc data: the table at its edges: sendable, expiry, the day, import and write", function()
	local T = D + 300
	local tab = newTable(T)
	tab:MergeIn(5, { t = { [1] = { T, 10, T - 118, 20, T - 118 } }, v = { [3] = { T, price(5), T - 118 } } })
	local c = tab:Sendable(5)
	H.eq(c.t[1][2], 10, "a skill 118 days old is sent") H.eq(c.v[3][2].c, 5, "a price 118 days old is sent")

	local tab2, set = newTable(T)
	tab2:MergeIn(5, { t = { [1] = { T, 1, T - 1, 1, T - 1 } }, v = { [3] = { T - 1, price(5), T - 1 }, [4] = { T, price(6), T } } })
	set(T + 119)
	H.ok(tab2:Get(5).v[3] and tab2:Get(5).v[3][2], "a sold entry and price 120 days old stay")
	set(T + 120)
	local s = tab2:Get(5)
	H.eq(s.t[1][2], 0, "a skill 1 of 121 days goes") H.eq(s.t[1][4], 0, "a copper 1 of 121 days goes")
	H.eq(s.v[3], nil, "a sold entry of 121 days goes")

	H.eq(ND.New({}, function() return T * 86400 + 86399 end):Today(), T, "the last second of a day is that day")

	local X = T - 40
	local guild, own = newTable(T), newTable(T)
	local g5 = { name = "G", nd = X, map = 1, x = 1, y = 1, pd = X, t = { [1] = { X, 10, X, 0, 0 } }, v = { [3] = { X, false, 0 } } }
	guild:MergeIn(5, g5)
	own:MergeIn(5, { name = "O", nd = X + 14, map = 2, x = 2, y = 2, pd = X + 14, t = { [1] = { X + 14, 20, X + 14, 0, 0 } },
		v = { [3] = { X + 14, false, 0 } } })
	guild:MergeIn(6, { t = { [2] = { X, 10, X, 0, 0 }, [3] = { X, 0, 0, 500, X }, [4] = { X, 1, X, 1, X } }, v = {} })
	own:MergeIn(6, { t = { [2] = { X + 1, 1, X + 15, 0, 0 }, [3] = { X + 1, 0, 0, 1, X + 31 }, [4] = { X + 1, 5, X + 5, 1, X + 5 } }, v = {} })
	guild:Import(own)
	H.ok(deepEq(guild:Get(5), g5), "own registers 14 days newer do not enter (name, place, seen, skill, sold seen)")
	local g6 = guild:Get(6).t
	H.ok(deepEq(g6[2], { X, 1, X + 15, 0, 0 }), "an own skill 1 of 15 days newer enters")
	H.ok(deepEq(g6[3], { X, 0, 0, 1, X + 31 }), "an own copper 1 of 31 days newer enters")
	H.ok(deepEq(g6[4], { X, 1, X, 1, X }), "a held skill 1 and copper 1 wait like any other")

	local w = newTable(T)
	w:Write(7, { t = { [1] = { skill = 10, copper = 100 } }, v = {} })
	w:Write(7, { t = { [1] = {} }, v = {} })
	H.eq(w:Get(7).t[1][2], 10, "write: a skill not read stays") H.eq(w:Get(7).t[1][4], 100, "write: a copper not read stays")
	w:Write(7, { t = { [1] = { skill = 1, copper = 1 } }, v = {} })
	H.eq(w:Get(7).t[1][2], 1, "write: skill 1") H.eq(w:Get(7).t[1][4], 1, "write: copper 1")
end)
