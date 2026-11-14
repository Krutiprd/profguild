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

H.test("HealOwn keeps recipes from the guild copy of unscanned professions", function()
	-- lost SavedVariables: professions known again from the snapshot, recipes not scanned yet
	local own = {}
	Store.BuildOwnRecord(own, { guid = "ME", name = "Me", ok = true,
		profs = { [197] = { s = 300, m = 300 }, [333] = { s = 120, m = 150 } } }, 1)
	Store.SetScannedRecipes(own, 333, { [9000] = 0 }) -- enchanting already scanned again
	Store.AddLearnedRecipe(own, 197, 3867, 0)          -- learned since, output still unknown
	local copy = Store.Validate({ g = "ME", v = 12, n = "Me", a = "acc", p = {
		[197] = { s = 280, m = 300, k = true, r = { [3865] = 4305, [3867] = 4307 } },
		[333] = { s = 100, m = 150, k = true, r = { [8000] = 0 } },
		[171] = { s = 50, m = 75, k = true, r = { [2330] = 118 } }, -- dropped since
	} })
	local rec = Store.HealOwn(own, 12, copy, 5)
	H.eq(rec.v, 13, "above the seen version"); H.eq(own.v, 13); H.eq(own.rec, rec)
	H.eq(rec.p[197].r[3865], 4305, "recipe taken over from the copy")
	H.eq(rec.p[197].r[3867], 4307, "unknown output item filled in")
	H.ok(rec.p[197].k and own.scanned[197], "profession counts as scanned")
	H.eq(rec.p[197].s, 300, "own skill level kept")
	H.eq(rec.p[333].r[8000], nil, "scanned profession not touched")
	H.eq(rec.p[171], nil, "profession we no longer have not taken over")
end)

H.test("HealOwn without a snapshot takes the professions of the copy", function()
	local own = {}
	local copy = Store.Validate({ g = "ME", v = 4, n = "Me", p = { [185] = { s = 75, m = 150, k = true, r = { [7827] = 5095 } } } })
	local rec = Store.HealOwn(own, 4, copy, 1)
	H.eq(rec.v, 5); H.eq(rec.n, "Me"); H.eq(rec.p[185].r[7827], 5095)
	H.eq(Store.HealOwn({}, 4, nil, 1), nil, "no identity, nothing to publish")
end)

H.test("HealOwn without a copy only raises the version", function()
	local own = {}
	Store.BuildOwnRecord(own, { guid = "ME", name = "Me", ok = true, profs = { [197] = { s = 1, m = 75 } } }, 1)
	local rec = Store.HealOwn(own, 9, nil, 2)
	H.eq(rec.v, 10); H.eq(rec.p[197].s, 1)
end)

H.test("PruneToRosterNames removes former members, refuses when names do not match", function()
	local norm = function(n) return (n:gsub("%-.*$", "")) end
	local s = Store.New({})
	s:Apply({ g = "ME", v = 1, n = "Frost Winterborn", p = {} })
	s:Apply({ g = "A", v = 1, n = "Ana Brightwood", p = {} })
	s:Apply({ g = "X", v = 1, n = "Gone Away", p = {} })
	local removed, why = s:PruneToRosterNames({ ["Frost"] = true, ["Ana"] = true }, norm, { ME = true }, "ME")
	H.eq(removed, nil, "own name not in roster form"); H.eq(why, "names do not match")
	H.ok(s:Get("X"), "nothing removed")
	removed = s:PruneToRosterNames({ ["Frost Winterborn"] = true, ["Ana Brightwood"] = true }, norm, { ME = true }, "ME")
	H.eq(#removed, 1); H.eq(removed[1], "X")
	H.ok(s:Get("A") and s:Get("ME") and not s:Get("X"))
	H.eq(s:PruneToRosterNames({}, norm, nil, "ME"), nil, "empty roster")
end)

H.test("Validate strips chat escapes and control characters from names", function()
	local clean = Store.Validate({ g = "G", v = 1, n = "|TInterface/Icons/x:0|t|cffff0000Evil\nName|r", c = "MAGE|r", p = {} })
	H.eq(clean.n, "TInterface/Icons/x:0tcffff0000EvilNamer", "no pipe, no line break")
	H.eq(clean.c, nil, "class with other characters dropped")
	H.eq(Store.Validate({ g = "G", v = 1, n = "||\n|", p = {} }).n, "?", "nothing left of the name")
	H.eq(Store.Validate({ g = "G", v = 1, n = "Ana Brightwood", c = "DEATHKNIGHT", p = {} }).n, "Ana Brightwood")
	H.eq(Store.Validate({ g = "G", v = 1, n = "Žofia Čierna", c = "DEATHKNIGHT", p = {} }).n, "Žofia Čierna", "UTF-8 kept")
end)

H.test("Own version never leaves the valid range", function()
	local max = Store.LIMITS.maxVersion
	local function fresh()
		local own = {}
		Store.BuildOwnRecord(own, { guid = "ME", name = "Me", ok = true, profs = { [197] = { s = 1, m = 75 } } }, 1)
		return own
	end
	for _, bad in ipairs({ 5.5, 1e300, -3, 0 / 0, max + 1 }) do
		local own = fresh()
		H.eq(Store.HealOwn(own, bad, nil, 2), nil, "version " .. tostring(bad) .. " refused")
		H.eq(own.v, 1, "own version untouched")
	end
	local own = fresh()
	local rec = Store.HealOwn(own, max, nil, 2)
	H.eq(rec.v, max, "capped at the maximum"); H.ok(Store.Validate(rec), "still a valid record")
	-- a later change must not push it over the limit either
	local rec2, changed = Store.BuildOwnRecord(own, { guid = "ME", name = "Me", ok = true, profs = { [197] = { s = 2, m = 75 } } }, 3)
	H.ok(changed); H.eq(rec2.v, max); H.ok(Store.Validate(rec2))
end)

H.test("BuildOwnRecord repairs a saved version outside the valid range", function()
	for _, bad in ipairs({ 6.5, 1e300, 2147483648 }) do
		local own = {}
		local snap = { guid = "ME", name = "Me", ok = true, profs = { [197] = { s = 1, m = 75 } } }
		Store.BuildOwnRecord(own, snap, 1)
		own.v, own.rec.v = bad, bad
		local rec, changed = Store.BuildOwnRecord(own, snap, 2)
		H.ok(changed, "republished"); H.eq(rec.v, 1); H.ok(Store.Validate(rec), "valid again")
	end
end)

H.test("Roster without GUIDs matches names in a different form", function()
	local norm = function(n) return (n:gsub("%-.*$", "")) end
	local s = Store.New({})
	s:Apply({ g = "A", v = 1, n = "Ana Brightwood", p = {} })
	s:SetRoster({ { name = "Ana Brightwood-Realm", online = true, daysOffline = 0 } }, norm)
	H.ok(s:IsOnline("A"), "online although the roster name carries the realm")
	H.eq(s:RosterEntry("A").name, "Ana Brightwood-Realm", "roster name kept for whispers")
end)

H.test("Checksum follows the content, not the version or the order", function()
	local a = { g = "G", v = 1, n = "Ana", c = "MAGE", p = { [197] = { s = 10, m = 75, k = true, r = { [1] = 2, [3] = 4 } } } }
	local b = { g = "G", v = 9, t = 5, n = "Ana", c = "MAGE", p = { [197] = { s = 10, m = 75, k = true, r = { [3] = 4, [1] = 2 } } } }
	H.eq(Store.Checksum(a), Store.Checksum(b), "same content")
	b.p[197].r[3] = 5
	H.ok(Store.Checksum(a) ~= Store.Checksum(b), "different item")
	b.p[197].r[3] = 4; b.p[197].s = 11
	H.ok(Store.Checksum(a) ~= Store.Checksum(b), "different skill")
	H.eq(Store.Checksum(nil), 0)
end)

H.test("Apply: at the maximum version only the owner's copy replaces a different one", function()
	local max = Store.LIMITS.maxVersion
	local store = Store.New({})
	local forged = { g = "G", v = max, n = "Ana", p = { [171] = { s = 1, m = 1, r = {} } } }
	local real = { g = "G", v = max, n = "Ana", p = { [197] = { s = 300, m = 300, r = { [1] = 2 } } } }
	H.eq(store:Apply(forged), "new")
	H.eq(store:Apply(real), "same", "a copy from anyone else is ignored")
	H.eq(store:Apply(real, true), "updated", "the owner's copy wins")
	H.ok(store:Get("G").p[197], "owner content stored")
	H.eq(store:Apply(real, true), "same", "identical copy changes nothing")
	H.eq(store:Apply(forged), "same", "and the forged one cannot come back")
	-- below the maximum the usual rule stays: same version, nothing replaced
	local low = Store.New({})
	low:Apply({ g = "G", v = 5, n = "Ana", p = {} })
	H.eq(low:Apply({ g = "G", v = 5, n = "Ana", p = { [197] = { s = 1, m = 1, r = {} } } }, true), "same")
end)

H.test("SetRoster: a partial read keeps the members it did not return", function()
	local store = Store.New({})
	store:Apply({ g = "A", v = 1, n = "Ana", t = 100, p = {} })
	store:Apply({ g = "B", v = 1, n = "Bob", t = 100, p = {} })
	store:SetRoster({ { guid = "A", name = "Ana", online = false, daysOffline = 1 },
		{ guid = "B", name = "Bob", online = false, daysOffline = 2 } })
	local now = 100 + 90 * 86400
	H.ok(not store:IsStale("B", 30, now), "Bob was online 2 days ago")
	-- only online members come back
	store:SetRoster({ { guid = "A", name = "Ana", online = true, daysOffline = 0 } }, nil, true)
	H.ok(store:IsOnline("A"), "Ana updated")
	H.ok(not store:IsStale("B", 30, now), "Bob keeps his roster entry")
	-- a complete read replaces everything
	store:SetRoster({ { guid = "A", name = "Ana", online = true, daysOffline = 0 } })
	H.eq(store:RosterEntry("B"), nil, "Bob left the guild")
end)

H.test("SetRoster does not rebuild the recipe index", function()
	local store = Store.New({})
	store:Apply({ g = "A", v = 1, n = "Ana", p = { [197] = { s = 1, m = 1, r = { [1] = 2 } } } })
	local index, rosterRevision = store:Index(), store.rosterRevision
	store:SetRoster({ { guid = "A", name = "Ana", online = true } })
	H.eq(store:Index(), index, "same index table")
	H.ok(store.rosterRevision > rosterRevision, "roster revision moved")
	store:Apply({ g = "A", v = 2, n = "Ana", p = {} })
	H.ok(store:Index() ~= index, "a record change rebuilds it")
end)

H.test("MergeGuildData keeps the newer record of every character", function()
	local target = { records = { A = { g = "A", v = 5, n = "Ana", p = {} }, B = { g = "B", v = 1, n = "Bob", p = {} } },
		names = { A = "Ana Brightwood" } }
	local source = { records = {
		A = { g = "A", v = 3, n = "Old Ana", p = {} },
		B = { g = "B", v = 4, n = "Bob", p = { [197] = { s = 1, m = 75, r = { [1] = 2 } } } },
		C = { g = "C", v = 2, n = "Cid", p = {} },
		D = { g = "Other", v = 2, n = "Wrong key", p = {} },
		E = "junk",
	}, names = { A = "ignored", C = "Cid Highwind" } }
	H.eq(Store.MergeGuildData(target, source), 2, "B and C taken")
	H.eq(target.records.A.v, 5, "newer A kept")
	H.eq(target.records.B.v, 4); H.ok(target.records.B.p[197], "newer B taken")
	H.ok(target.records.C, "C added")
	H.eq(target.records.D, nil, "record under a wrong key skipped")
	H.eq(target.names.A, "Ana Brightwood"); H.eq(target.names.C, "Cid Highwind")
	H.eq(Store.MergeGuildData({}, nil), 0)
end)

H.test("VersionNewer compares three numbers and ignores what is no version", function()
	H.ok(Store.VersionNewer("0.1.14", "0.1.13"))
	H.ok(Store.VersionNewer("0.2.0", "0.1.99"))
	H.ok(Store.VersionNewer("1.0.0", "0.9.9"))
	H.ok(Store.VersionNewer("0.1.10", "0.1.9"), "numbers, not text")
	H.ok(Store.VersionNewer("0.1.14-beta", "0.1.13"), "suffix ignored")
	H.ok(not Store.VersionNewer("0.1.13", "0.1.13"))
	H.ok(not Store.VersionNewer("0.1.12", "0.1.13"))
	H.ok(not Store.VersionNewer("9.9.9", "dev"), "development copy is never told to update")
	H.ok(not Store.VersionNewer("|cffff0000hack|r", "0.1.13"))
	H.ok(not Store.VersionNewer("99999.0.0", "0.1.13"), "absurd numbers")
	H.ok(not Store.VersionNewer(nil, "0.1.13"))
	H.ok(not Store.VersionNewer(5, "0.1.13"))
end)
