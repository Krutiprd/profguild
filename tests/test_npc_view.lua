-- What the recipe detail shows: skill numbers and the ordered sources (NpcView, design "Window").
local H = ...
local ns = H.newNamespace({ "NpcData.lua", "NpcTable.lua", "Prices.lua", "Data.lua", "NpcView.lua" })
local V = ns.NpcView
local ND = ns.NpcData
local DATA = ns.RecipeData

local TODAY = 20000
local function newTab() return ND.New({}, function() return TODAY * 86400 + 100 end) end
local function price(c, o, l) return { c = c, o = o or {}, l = l or 0 } end

-- trainer of recipe 900: skill and copper (nil unknown), read `ago` days ago
local function trainer(tab, id, name, map, skill, copper, ago)
	local d = TODAY - (ago or 1)
	tab:MergeIn(id, { name = name, nd = d, map = map, x = 10, y = 20, pd = d,
		t = { [900] = { d, skill or 0, skill and d or 0, copper or 0, copper and d or 0 } }, v = {} })
end
local function vendor(tab, id, name, map, item, p, ago)
	local d = TODAY - (ago or 1)
	tab:MergeIn(id, { name = name, nd = d, map = map, x = 30, y = 40, pd = d,
		t = {}, v = { [item] = { d, p or false, p and d or 0 } } })
end
local function kinds(rows)
	local k = {}
	for i, r in ipairs(rows) do k[i] = r.kind .. (r.name and (":" .. r.name) or "") end
	return table.concat(k, ",")
end
local function src(own, guild, info)
	return { own = own or newTab(), guild = guild or newTab(), info = info or {}, data = ns.RecipeData }
end

H.test("view: order ah, trainers, vendors, then drop, quest, crafted", function()
	local g = newTab()
	vendor(g, 3, "V", 1, 500, price(100))
	trainer(g, 2, "T", 1, nil, 50)
	local rows = V.Sources(900, src(nil, g), { map = 1, items = { [500] = true }, recipeItem = 500, letters = "vdqc", ah = { copper = 10, text = "x" } })
	H.eq(kinds(rows), "ah,trainer:T,vendor:V,drop,quest,crafted")
	H.eq(rows[1].copper, 10)
	H.ok(not rows[1].approx, "ah has no ~")
end)

H.test("view: within a kind player's map, lowest price, name", function()
	local g = newTab()
	vendor(g, 1, "Far", 2, 500, price(10))
	vendor(g, 2, "Zed", 1, 500, price(50))
	vendor(g, 3, "Amy", 1, 500, price(50))
	vendor(g, 4, "Cheap", 1, 500, price(20))
	vendor(g, 5, "NoPrice", 1, 500, false)
	vendor(g, 6, "Another", 1, 500, false)
	local rows = V.Sources(901, src(nil, g), { map = 1, items = { [500] = true }, recipeItem = 500, letters = "v" })
	H.eq(kinds(rows), "ah,vendor:Cheap,vendor:Amy,vendor:Zed,vendor:Another,vendor:NoPrice,vendor:Far")
end)

H.test("view: ah row only for a recipe item, no copper without an AH price", function()
	local rows = V.Sources(900, src(), { items = {}, recipeItem = 500, letters = "" })
	H.eq(kinds(rows), "ah")
	H.eq(rows[1].copper, nil)
	rows = V.Sources(900, src(), { items = {}, recipeItem = false, letters = "" })
	H.eq(kinds(rows), "missing")
	rows = V.Sources(900, src(), { items = {}, recipeItem = nil, letters = "d" })
	H.eq(kinds(rows), "drop")
end)

H.test("view: own reading of 30 days replaces the guild's without approx, 31 not", function()
	local own, g = newTab(), newTab()
	local w = { items = {}, recipeItem = false, letters = "" }
	trainer(g, 2, "T", 1, nil, 90, 5)
	trainer(own, 2, "T", 1, nil, 70, 30)
	local r = V.Sources(900, src(own, g), w)[1]
	H.eq(r.kind, "trainer")
	H.eq(r.copper, 70)
	H.ok(not r.approx, "own, no ~")
	own = newTab()
	trainer(own, 2, "T", 1, nil, 70, 31)
	r = V.Sources(900, src(own, g), w)[1]
	H.eq(r.copper, 90)
	H.ok(r.approx, "guild's, ~")
	own = newTab()
	trainer(own, 2, "T", 1, nil, 90, 31)
	r = V.Sources(900, src(own, g), w)[1]
	H.eq(r.copper, 90)
	H.ok(not r.approx, "equal, no ~")
	r = V.Sources(900, src(newTab(), g), w)[1]
	H.ok(r.approx, "guild only: ~")
	H.eq(r.age, 5)
end)

H.test("view: vendors of Data.lua's item and recipeItems, other costs, limited stock", function()
	local g = newTab()
	vendor(g, 1, "A", 1, 500, price(100, nil, 1))
	vendor(g, 2, "B", 1, 501, price(0, { { 2, 77, 5 } }))
	local rows = V.Sources(901, src(nil, g), { map = 1, items = { [500] = true, [501] = true }, recipeItem = 501, letters = "v" })
	H.eq(kinds(rows), "ah,vendor:A,vendor:B")
	H.ok(rows[2].limited, "limited")
	H.eq(rows[3].copper, nil)
	H.eq(rows[3].other[1][2], 77)
	rows = V.Sources(901, src(nil, g), { map = 1, items = { [500] = true }, recipeItem = 500, letters = "v" })
	H.eq(kinds(rows), "ah,vendor:A")
end)

H.test("view: missing vendor, missing trainer, unknown", function()
	local rows = V.Sources(901, src(), { items = { [500] = true }, recipeItem = 500, letters = "v" })
	H.eq(kinds(rows), "ah,missing")
	H.eq(rows[2].of, "vendor")
	rows = V.Sources(901, src(), { items = {}, recipeItem = false, letters = "" })
	H.eq(rows[1].kind, "missing")
	H.eq(rows[1].of, "trainer")
	rows = V.Sources(901, src(), { items = {}, recipeItem = nil, letters = "" })
	H.eq(#rows, 1)
	H.eq(rows[1].kind, "unknown")
end)

H.test("view: best frame only among two copper prices, not with other costs, ties first", function()
	local g = newTab()
	vendor(g, 1, "A", 1, 500, price(100))
	vendor(g, 2, "B", 1, 500, price(100))
	local w = { map = 1, items = { [500] = true }, recipeItem = 500, letters = "v" }
	local rows = V.Sources(901, src(nil, g), w)
	H.ok(rows[2].best and not rows[3].best, "ah has no price, two vendors tie: the first")
	w.ah = { copper = 300, text = "t" }
	rows = V.Sources(901, src(nil, g), w)
	H.ok(not rows[1].best and rows[2].best and not rows[3].best, "tie: first")
	vendor(g, 3, "C", 1, 500, price(10, { { 1, 5, 1 } }))
	rows = V.Sources(901, src(nil, g), w)
	for _, r in ipairs(rows) do
		if r.name == "C" then H.ok(not r.best, "other costs never") end
	end
	for _, r in ipairs(rows) do
		H.eq(r.best == true, r.name == "A", "best is A only")
	end
	local one = V.Sources(901, src(nil, newTab()), { items = {}, recipeItem = 500, letters = "", ah = { copper = 5, text = "t" } })
	H.ok(not one[1].best, "a single price")
end)

H.test("view: learn from the later day, then the greatest; above grey ignored", function()
	local g = newTab()
	trainer(g, 1, "A", 1, 40, 5, 10)
	trainer(g, 2, "B", 1, 30, 5, 3)
	H.eq(V.Skill(900, src(nil, g, { g = 100 })).learn, 30)
	trainer(g, 3, "C", 1, 35, 5, 3)
	H.eq(V.Skill(900, src(nil, g, { g = 100 })).learn, 35)
	H.eq(V.Skill(900, src(nil, g, { g = 32 })).learn, 30, "35 above grey: next source")
	H.eq(V.Skill(900, src(nil, newTab(), { m = 20, g = 100 })).learn, 20, "info.m")
	H.eq(V.Skill(900, src(nil, newTab(), { m = 200, g = 100 })).learn, nil, "m above grey")
end)

H.test("view: numbers from Prices.RecipeSkill, grey from info.g first", function()
	local _, y, _, gy = ns.Prices.RecipeSkill(3866)
	local r = V.Skill(3866, src())
	H.eq(r.yellow, y)
	H.eq(r.grey, gy)
	H.eq(r.green, math.floor((y + gy) / 2))
	r = V.Skill(3866, src(nil, nil, { g = 144 }))
	H.eq(r.grey, 144)
	H.eq(r.yellow, y)
	H.eq(r.green, math.floor((y + 144) / 2))
	r = V.Skill(3866, src(nil, nil, { g = 100 }))
	H.eq(r.yellow, 100, "yellow at most grey")
end)

local function shown(r)
	local t = {}
	for i, s in ipairs(r.show) do t[i] = s[2] .. "=" .. s[1] end
	return table.concat(t, ",")
end

H.test("view: which numbers are shown", function()
	ns.RecipeData = { [1] = { false, "", 0, 50, 70, 1 }, [2] = { false, "", 0, 50, 50, 1 } }
	H.eq(shown(V.Skill(1, src())), "yellow=50,green=60,grey=70", "learn unknown")
	H.eq(shown(V.Skill(2, src())), "yellow=50,green=50,grey=50", "equal numbers shown")
	H.eq(shown(V.Skill(1, src(nil, nil, { m = 40 }))), "learn=40,yellow=50,green=60,grey=70")
	H.eq(shown(V.Skill(1, src(nil, nil, { m = 50 }))), "learn=50,yellow=50,green=60,grey=70", "at yellow")
	H.eq(shown(V.Skill(1, src(nil, nil, { m = 55 }))), "learn=55,grey=70", "above yellow")
	H.eq(shown(V.Skill(1, src(nil, nil, { m = 70 }))), "learn=70", "at grey")
	ns.RecipeData = DATA
end)

H.test("view: odd Data.lua entries give no error and no falling numbers", function()
	local odd = 0
	for id, e in pairs(DATA) do
		local r = V.Skill(id, src())
		local last = 0
		for _, s in ipairs(r.show) do
			H.ok(s[1] >= last, "falling numbers at " .. id)
			last = s[1]
		end
		if e[4] > e[5] or e[3] > e[4] then odd = odd + 1 end
	end
	H.ok(odd >= 1, "found the odd ones: " .. odd)
end)
