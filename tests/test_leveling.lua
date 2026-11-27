-- Leveling.lua: chance of a point, thin markets, what gives skill now, the cheapest path to 300.
local H = ...
local ns = H.newNamespace({ "Leveling.lua" })
local L = ns.Leveling

local function rec(t)
	local r = { id = t.id or 1, name = t.name or ("r" .. (t.id or 1)), learn = t.learn, yellow = t.yellow, grey = t.grey,
		cost = t.cost or 0, ah = t.ah, avail = t.avail, vendor = t.vendor, known = t.known ~= false,
		learnPrice = t.learnPrice, learnWhere = t.learnWhere }
	return r
end

H.test("leveling: chance of a point from orange to grey, below learn none", function()
	local r = rec({ learn = 1, yellow = 50, grey = 100 })
	H.eq(L.Chance(r, 10), 1, "orange")
	H.eq(L.Chance(r, 50), 1, "yellow starts at 100 %")
	H.eq(L.Chance(r, 75), 0.5, "half way")
	H.eq(L.Chance(r, 100), 0, "grey")
	H.eq(L.Chance(r, 120), 0, "past grey")
	H.eq(L.Chance(rec({ learn = 60, yellow = 70, grey = 100 }), 55), 0, "below the learn skill")
	local flat = rec({ learn = 1, yellow = 100, grey = 100 })
	H.eq(L.Chance(flat, 100), 0, "yellow == grey at grey")
	H.eq(L.Chance(flat, 99), 1, "yellow == grey below")
	local odd = rec({ learn = 1, yellow = 120, grey = 100 })
	H.eq(L.Chance(odd, 99), 1, "yellow > grey taken as yellow = grey")
	H.eq(L.Chance(odd, 100), 0)
	H.eq(L.Chance(rec({ yellow = 50, grey = 100 }), 1), 1, "no learn skill: from 1")
end)

H.test("leveling: the value of n units in a thin market", function()
	local r = rec({ ah = 100, vendor = 10, avail = 5 })
	H.eq(L.UnitValue(r, 5), 100)
	H.eq(L.UnitValue(r, 10), 55)
	H.eq(L.UnitValue(rec({ ah = 100, vendor = 10 }), 50), 100, "avail unknown: all at the AH value")
	H.eq(L.UnitValue(rec({ vendor = 10, avail = 5 }), 3), 10, "no AH value: vendor")
	H.eq(L.UnitValue(rec({}), 3), 0, "no value at all")
	H.eq(L.UnitValue(rec({ ah = 100, avail = 5 }), 10), 50, "beyond the market without a vendor price: nothing")
	H.eq(L.UnitValue(rec({ ah = 100, vendor = 10, avail = 0 }), 4), 10, "nothing on the market")
end)

H.test("leveling: gives skill now, sorted by loss per point, grey ones absent", function()
	local recipes = {
		rec({ id = 1, name = "A", learn = 1, yellow = 70, grey = 90, cost = 100, vendor = 20 }),  -- yellow 0.75: (100-20)/0.75 = 106.7
		rec({ id = 2, name = "B", learn = 1, yellow = 80, grey = 120, cost = 90 }),                -- orange: 90
		rec({ id = 3, name = "C", learn = 1, yellow = 60, grey = 80, cost = 200, ah = 300 }),      -- green 0.25: -100/0.25 = -400
		rec({ id = 4, name = "D", learn = 1, yellow = 40, grey = 70, cost = 1 }),                  -- grey at 75
		rec({ id = 5, name = "E", learn = 1, yellow = 10, grey = 76, cost = 10, known = false }),  -- no source: still listed
	}
	local rows = L.GivesNow(recipes, 75)
	H.eq(#rows, 4)
	H.eq(rows[1].r.id, 3); H.eq(rows[1].loss, -400); H.eq(rows[1].colour, "green"); H.eq(rows[1].chance, 0.25)
	H.eq(rows[2].r.id, 2); H.eq(rows[2].loss, 90); H.eq(rows[2].colour, "orange")
	H.eq(rows[3].r.id, 1); H.eq(rows[3].loss, 106); H.eq(rows[3].colour, "yellow"); H.eq(rows[3].cost, 100)
	H.eq(rows[4].r.id, 5); H.eq(rows[4].loss, math.floor(10 / (1 / 66)), "rounded down; no source: last")
end)

H.test("leveling: the cheapest whole path beats greedy (a learn price paid for a few points)", function()
	-- CHEAP is the cheapest craft at 1..4 but must be learned; WIDE must be learned too and covers 1..299
	local cheap = rec({ id = 1, name = "CHEAP", learn = 1, yellow = 4, grey = 5, cost = 10, known = false, learnPrice = 100 })
	local wide = rec({ id = 2, name = "WIDE", learn = 1, yellow = 299, grey = 400, cost = 12, known = false, learnPrice = 200 })
	local plan = L.Plan({ cheap, wide }, 1, 300)
	H.eq(#plan.segments, 1, "one segment")
	local s = plan.segments[1]
	H.eq(s.r, wide); H.eq(s.from, 1); H.eq(s.to, 300); H.eq(s.learn, true)
	H.eq(plan.total, 200 + 299 * 12)
	H.eq(s.loss, plan.total)
	H.eq(plan.stopAt, nil)
	-- known, CHEAP is free to use first
	cheap.known = true
	plan = L.Plan({ cheap, wide }, 1, 300)
	H.eq(#plan.segments, 2)
	H.eq(plan.segments[1].r, cheap); H.eq(plan.segments[1].to, 5); H.eq(plan.segments[1].learn, false)
	H.eq(plan.segments[2].r, wide); H.eq(plan.segments[2].from, 5)
	H.eq(plan.total, 4 * 10 + 200 + 295 * 12)
end)

H.test("leveling: segments are runs of one recipe; the count sums 1/chance", function()
	local a = rec({ id = 1, name = "A", learn = 1, yellow = 10, grey = 20, cost = 10 })  -- 1..19
	local b = rec({ id = 2, name = "B", learn = 15, yellow = 300, grey = 310, cost = 12 }) -- 15..
	local plan = L.Plan({ a, b }, 5, 40)
	H.eq(#plan.segments, 2)
	local s1, s2 = plan.segments[1], plan.segments[2]
	H.eq(s1.r, a); H.eq(s1.from, 5); H.eq(s1.to, 15)
	local count = 0
	for s = 5, 14 do count = count + 1 / L.Chance(a, s) end
	H.ok(math.abs(s1.count - count) < 1e-9, "count " .. s1.count)
	H.ok(s1.count > 10, "yellow levels need more crafts")
	H.eq(s2.r, b); H.eq(s2.from, 15); H.eq(s2.to, 40); H.eq(s2.count, 25)
	H.ok(math.abs(plan.total - (s1.loss + s2.loss)) < 1e-6, "total")
end)

H.test("leveling: a gap stops the plan where nothing gives a point", function()
	local a = rec({ id = 1, learn = 1, yellow = 100, grey = 150, cost = 10 })
	local b = rec({ id = 2, learn = 200, yellow = 250, grey = 300, cost = 10 })
	local plan = L.Plan({ a, b }, 1, 300)
	H.eq(plan.stopAt, 150)
	H.eq(#plan.segments, 1)
	H.eq(plan.segments[1].to, 150)
end)

H.test("leveling: from at or above the end, or above every grey: nothing, no error", function()
	local a = rec({ id = 1, learn = 1, yellow = 100, grey = 150, cost = 10 })
	for _, from in ipairs({ 300, 400 }) do
		local plan = L.Plan({ a }, from, 300)
		H.eq(#plan.segments, 0, "from " .. from)
		H.eq(plan.stopAt, nil)
		H.eq(plan.total, 0)
	end
	local plan = L.Plan({ a }, 200, 300)
	H.eq(#plan.segments, 0)
	H.eq(plan.stopAt, 200, "nothing gives skill from 200")
	plan = L.Plan({}, 1, 300)
	H.eq(#plan.segments, 0); H.eq(plan.stopAt, 1)
end)

H.test("leveling: up to 3 alternatives per segment, cheapest first, covering the segment, learn price in", function()
	local main = rec({ id = 1, name = "MAIN", learn = 1, yellow = 100, grey = 200, cost = 10 })
	local alt1 = rec({ id = 2, name = "ALT1", learn = 1, yellow = 100, grey = 200, cost = 11 })
	local alt2 = rec({ id = 3, name = "ALT2", learn = 1, yellow = 100, grey = 200, cost = 5, known = false, learnPrice = 500 })
	local alt3 = rec({ id = 4, name = "ALT3", learn = 1, yellow = 100, grey = 200, cost = 30 })
	local alt4 = rec({ id = 5, name = "ALT4", learn = 1, yellow = 100, grey = 200, cost = 40 })
	local short = rec({ id = 6, name = "SHORT", learn = 1, yellow = 40, grey = 50, cost = 1 }) -- not the whole segment
	local nosrc = rec({ id = 7, name = "NOSRC", learn = 1, yellow = 100, grey = 200, cost = 1, known = false })
	local recipes = { main, alt1, alt2, alt3, alt4, short, nosrc }
	local plan = L.Plan(recipes, 60, 100)
	H.eq(#plan.segments, 1)
	local s = plan.segments[1]
	H.eq(s.r, main)
	H.eq(#s.alts, 3)
	H.eq(s.alts[1].r, alt1); H.eq(s.alts[1].loss, 40 * 11); H.eq(s.alts[1].count, 40)
	H.eq(s.alts[2].r, alt2); H.eq(s.alts[2].loss, 500 + 40 * 5)
	H.eq(s.alts[3].r, alt3)
	for _, a in ipairs(s.alts) do H.ok(a.r ~= main and a.r ~= short and a.r ~= nosrc, a.r.name) end
	H.eq(s.all, #L.GivesNow(recipes, 60))
	H.eq(s.all, 6, "SHORT is grey at 60; NOSRC counts")
end)

H.test("leveling: a recipe without a known source is never planned, but gives skill now", function()
	local nosrc = rec({ id = 1, name = "NOSRC", learn = 1, yellow = 299, grey = 300, cost = 1, known = false })
	local dear = rec({ id = 2, name = "DEAR", learn = 1, yellow = 299, grey = 300, cost = 500 })
	local plan = L.Plan({ nosrc, dear }, 1, 300)
	for _, s in ipairs(plan.segments) do
		H.ok(s.r ~= nosrc, "segment")
		for _, a in ipairs(s.alts) do H.ok(a.r ~= nosrc, "alt") end
	end
	H.eq(plan.segments[1].r, dear)
	local now = L.GivesNow({ nosrc, dear }, 10)
	H.eq(#now, 2, "listed")
	H.eq(now[1].r, dear, "after the recipes the plan can use, though cheaper")
	H.eq(now[2].r, nosrc); H.eq(now[2].source, false); H.eq(now[1].source, true)
	H.eq(L.Plan({ nosrc }, 1, 300).stopAt, 1, "only an unknown source: stops at once")
end)

H.test("leveling: profit is a negative loss and lowers the total", function()
	local seller = rec({ id = 1, learn = 1, yellow = 299, grey = 300, cost = 10, ah = 30 })
	local plan = L.Plan({ seller }, 1, 300)
	H.eq(plan.total, -20 * 299)
end)

H.test("leveling: the thin market limits a recipe's value over its whole range", function()
	-- 100 crafts needed, 10 sell on the AH at 1000, the rest at the vendor's 10
	local r = rec({ id = 1, learn = 1, yellow = 300, grey = 400, cost = 100, ah = 1000, vendor = 10, avail = 10 })
	local plan = L.Plan({ r }, 200, 300)
	local value = (10 * 1000 + 90 * 10) / 100
	H.ok(math.abs(plan.total - 100 * (100 - value)) < 1e-6, "total " .. plan.total)
end)

H.test("leveling: gives skill now values the product by the crafts from that skill to grey (an alternative's rule)", function()
	-- orange from 250 to 274, grey 275: 25 crafts; 2 sell on the AH at 1000, the rest at the vendor's 50
	local r = rec({ id = 1, learn = 250, yellow = 274, grey = 275, cost = 100, ah = 1000, vendor = 50, avail = 2 })
	local rows = L.GivesNow({ r }, 250)
	local value = (2 * 1000 + 23 * 50) / 25
	H.ok(math.abs(rows[1].crafts - 25) < 1e-9, "crafts " .. rows[1].crafts)
	H.ok(math.abs(rows[1].net - (100 - value)) < 1e-9, "net " .. rows[1].net)
	H.eq(rows[1].loss, math.floor(100 - value), "a loss per point, not the first unit's profit")
	-- yellow levels need more crafts: N sums 1/chance up to grey, capped at 300
	local y = rec({ id = 2, learn = 1, yellow = 280, grey = 320, cost = 100, ah = 1000, vendor = 0, avail = 5 })
	local n = 0
	for s = 290, 299 do n = n + 1 / L.Chance(y, s) end
	local g = L.GivesNow({ y }, 290)[1]
	H.ok(math.abs(g.crafts - n) < 1e-9, "capped at 300: " .. g.crafts .. " vs " .. n)
end)

H.test("leveling: the Ironfeather case: the list and the plan's segment give the same loss", function()
	local iron = rec({ id = 1, name = "IRON", learn = 250, yellow = 274, grey = 275, cost = 150, ah = 1000, vendor = 50, avail = 2 })
	local dear = rec({ id = 2, name = "DEAR", learn = 250, yellow = 300, grey = 310, cost = 200 })
	local plan = L.Plan({ iron, dear }, 250, 300)
	local s = plan.segments[1]
	H.eq(s.r, iron); H.eq(s.from, 250); H.eq(s.to, 275)
	H.ok(math.abs(s.count - 25) < 1e-9)
	local row
	for _, g in ipairs(L.GivesNow({ iron, dear }, 250)) do if g.r == iron then row = g end end
	H.ok(math.abs(s.loss - row.net * s.count) < 1e-6, "segment " .. s.loss .. " list " .. row.net * s.count)
	H.ok(s.loss > 0, "a loss in both")
	H.ok(row.loss > 0, "the list does not show the first unit's profit")
end)

H.test("leveling: a segment's value counts the crafts it uses, not the recipe's whole range", function()
	-- THIN gives 250..289 (40 crafts) but 5 sell on the AH at 1000: over its whole range it looks
	-- worse than CHEAPA, so the old plan used it only at 260 (where nothing else gives a point).
	-- Valued by the crafts it uses it is a profit, and the plan takes it from 250 to 265 (where
	-- RICH, a big profit, takes over).
	local thin = rec({ id = 1, name = "THIN", learn = 250, yellow = 289, grey = 290, cost = 300, ah = 1000, vendor = 0, avail = 5 })
	local cheapA = rec({ id = 2, name = "CHEAPA", learn = 250, yellow = 259, grey = 260, cost = 150 })
	local cheapB = rec({ id = 3, name = "CHEAPB", learn = 261, yellow = 264, grey = 265, cost = 150 })
	local rich = rec({ id = 4, name = "RICH", learn = 265, yellow = 300, grey = 310, cost = 0, ah = 1000 })
	local plan = L.Plan({ thin, cheapA, cheapB, rich }, 250, 300)
	H.eq(plan.segments[1].r, thin, "THIN from the start")
	H.eq(plan.segments[1].from, 250); H.eq(plan.segments[1].to, 265)
	H.eq(plan.segments[2].r, rich)
	local value = 5 * 1000 / 15
	H.ok(math.abs(plan.segments[1].loss - 15 * (300 - value)) < 1e-6, "valued by its 15 crafts: " .. plan.segments[1].loss)
	H.ok(math.abs(plan.total - (plan.segments[1].loss + plan.segments[2].loss)) < 1e-6)
end)

H.test("leveling: a segment's value uses the crafts of its recipe in the plan", function()
	-- the old rule valued SHORT's 10 crafts by its 50 (250..299): now by the 10 it makes
	local short = rec({ id = 1, name = "SHORT", learn = 250, yellow = 299, grey = 300, cost = 100, ah = 1000, vendor = 0, avail = 10 })
	local after = rec({ id = 2, name = "AFTER", learn = 260, yellow = 300, grey = 310, cost = 0, ah = 5000 })
	local plan = L.Plan({ short, after }, 250, 300)
	H.eq(plan.segments[1].r, short); H.eq(plan.segments[1].to, 260)
	H.ok(math.abs(plan.segments[1].loss - 10 * (100 - 1000)) < 1e-6, "loss " .. plan.segments[1].loss)
end)
