-- NPC sheets: registers, merge (a join), own visits and validation.
-- Days in these tests are D + n, so a day of the brief like "100@10" is D + 10.
local H = ...
local ns = H.newNamespace({ "NpcData.lua" })
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
