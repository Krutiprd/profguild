local H = ...
local ns = H.newNamespace({ "Store.lua" })
local Store = ns.Store

local function rec(guid, v, profs)
	return { g = guid, v = v, n = "Name " .. guid, c = "MAGE", a = "acc1", t = 100, p = profs or {} }
end

H.test("Validate drops junk and keeps good data", function()
	local clean = Store.Validate({
		g = "G1", v = 3, n = 5, c = "WARRIOR", evil = "x",
		p = {
			[197] = { s = 150, m = 225, k = true, r = { [1001] = 2001, [1002] = "bad", bad = 3 } },
			bad = { s = 1 },
			[171] = "notatable",
		},
	})
	H.ok(clean, "record kept")
	H.eq(clean.evil, nil, "unknown field dropped")
	H.eq(clean.n, "?", "bad name replaced")
	H.eq(clean.p[197].r[1001], 2001, "recipe kept")
	H.eq(clean.p[197].r[1002], 0, "bad item id becomes 0")
	H.eq(clean.p[197].r.bad, nil, "bad recipe key dropped")
	H.eq(clean.p.bad, nil, "bad profession key dropped")
	H.eq(clean.p[171], nil, "non-table profession dropped")
end)

H.test("Validate rejects records without guid or version", function()
	H.eq(Store.Validate({ v = 1 }), nil)
	H.eq(Store.Validate({ g = "G", v = 0 }), nil)
	H.eq(Store.Validate({ g = "G", v = 1.5 }), nil)
	H.eq(Store.Validate("x"), nil)
end)

H.test("Validate caps recipe count", function()
	local r = {}
	for i = 1, 3000 do r[i] = i end
	local clean = Store.Validate({ g = "G", v = 1, p = { [197] = { s = 1, m = 1, r = r } } })
	local n = 0
	for _ in pairs(clean.p[197].r) do n = n + 1 end
	H.eq(n, Store.LIMITS.maxRecipes, "capped")
end)

H.test("Apply keeps only higher versions", function()
	local s = Store.New({})
	H.eq(s:Apply(rec("A", 2)), "new")
	H.eq(s:Apply(rec("A", 1)), "older")
	H.eq(s:Apply(rec("A", 2)), "same")
	H.eq(s:Apply(rec("A", 5)), "updated")
	H.eq(s:Get("A").v, 5)
	H.eq(s:Apply({ g = "A" }), "invalid")
end)

H.test("Compare finds both directions", function()
	local s = Store.New({})
	s:Apply(rec("A", 2)); s:Apply(rec("B", 3)); s:Apply(rec("C", 1))
	local mine, theirs = s:Compare({ A = 2, B = 1, D = 4, C = 7 })
	H.eq(table.concat(mine, ","), "B")
	H.eq(table.concat(theirs, ","), "C,D")
end)

H.test("PruneToRoster removes former members only with a roster", function()
	local s = Store.New({})
	s:Apply(rec("A", 1)); s:Apply(rec("B", 1))
	H.eq(#s:PruneToRoster({}), 0, "empty roster prunes nothing")
	local removed = s:PruneToRoster({ A = true })
	H.eq(#removed, 1); H.eq(removed[1], "B")
	H.ok(s:Get("A") and not s:Get("B"))
end)

H.test("IsStale uses roster days, then record time", function()
	local s = Store.New({})
	s:Apply(rec("A", 1)); s:Apply(rec("B", 1))
	s:SetRoster({ { guid = "A", name = "A", online = false, daysOffline = 31 } })
	H.ok(s:IsStale("A", 30, 0), "31 days offline is stale")
	H.ok(not s:IsStale("B", 30, 100 + 10 * 86400), "B fresh by record time")
	H.ok(s:IsStale("B", 30, 100 + 31 * 86400), "B stale by record time")
	s:SetRoster({ { guid = "A", name = "A", online = true, daysOffline = 99 } })
	H.ok(not s:IsStale("A", 30, 0), "online is never stale")
end)

H.test("Index maps recipes, items and alts", function()
	local s = Store.New({})
	s:Apply(rec("A", 1, { [197] = { s = 1, m = 1, r = { [10] = 500, [11] = 0 } } }))
	s:Apply(rec("B", 1, { [197] = { s = 1, m = 1, r = { [10] = 500 } } }))
	local idx = s:Index()
	H.eq(#idx.recipes[10].guids, 2)
	H.eq(idx.items[500][1], 10)
	H.eq(idx.recipes[11].itemID, 0)
	H.eq(#idx.alts.acc1, 2)
	H.ok(s:Index() == idx, "cached until revision changes")
	s:Apply(rec("A", 2))
	H.ok(s:Index() ~= idx, "rebuilt after change")
end)

H.test("BuildOwnRecord bumps version only on change", function()
	local own = {}
	local snap = { guid = "ME", name = "Me", class = "MAGE", account = "acc", ok = true, profs = { [197] = { s = 10, m = 75 } } }
	local r1, c1 = Store.BuildOwnRecord(own, snap, 1)
	H.ok(c1); H.eq(r1.v, 1)
	local _, c2 = Store.BuildOwnRecord(own, snap, 2)
	H.ok(not c2, "no change, no bump"); H.eq(own.v, 1)
	snap.profs[197].s = 11
	local r3, c3 = Store.BuildOwnRecord(own, snap, 3)
	H.ok(c3); H.eq(r3.v, 2); H.eq(r3.p[197].s, 11)
end)

H.test("Profession disappears only after two snapshots without it", function()
	local own = {}
	local snap = { guid = "ME", name = "Me", ok = true, profs = { [197] = { s = 10, m = 75 }, [333] = { s = 5, m = 75 } } }
	Store.BuildOwnRecord(own, snap, 1)
	Store.SetScannedRecipes(own, 333, { [7000] = 0 })
	Store.BuildOwnRecord(own, snap, 2)
	snap.profs[333] = nil
	local r1 = Store.BuildOwnRecord(own, snap, 3)
	H.ok(r1.p[333], "kept after one missing snapshot")
	local r2, changed = Store.BuildOwnRecord(own, snap, 4)
	H.ok(changed and not r2.p[333], "removed after second")
	H.eq(own.recipes[333], nil, "recipes removed too")
end)

H.test("Unreliable snapshot changes nothing", function()
	local own = {}
	Store.BuildOwnRecord(own, { guid = "ME", ok = true, profs = { [197] = { s = 1, m = 75 } } }, 1)
	for i = 1, 3 do
		Store.BuildOwnRecord(own, { guid = "ME", ok = false, profs = {} }, 1 + i)
	end
	H.ok(own.rec.p[197], "still there")
end)

H.test("Learned recipes are added and published", function()
	local own = {}
	local snap = { guid = "ME", ok = true, profs = { [185] = { s = 50, m = 75 } } }
	Store.BuildOwnRecord(own, snap, 1)
	H.ok(Store.AddLearnedRecipe(own, 185, 7827, 5095))
	local r, changed = Store.BuildOwnRecord(own, snap, 2)
	H.ok(changed); H.eq(r.p[185].r[7827], 5095)
	H.ok(not Store.AddLearnedRecipe(own, nil, 1, 1), "unknown profession")
end)

H.test("BumpOwnVersion jumps above seen version", function()
	local own = {}
	Store.BuildOwnRecord(own, { guid = "ME", ok = true, profs = {} }, 1)
	H.ok(Store.BumpOwnVersion(own, 9, 5))
	H.eq(own.v, 10); H.eq(own.rec.v, 10)
	H.ok(not Store.BumpOwnVersion(own, 3, 6), "lower version ignored")
end)

H.test("Roster without GUIDs is matched by name", function()
	local s = Store.New({})
	s:Apply({ g = "A", v = 1, n = "Ana Brightwood", p = {} })
	s:SetRoster({ { name = "Ana Brightwood", online = true, daysOffline = 0 } })
	H.ok(s:IsOnline("A"), "online by name")
	H.eq(s:RosterEntry("A").name, "Ana Brightwood")
end)
