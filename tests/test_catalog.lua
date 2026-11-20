-- Recipe catalog: adding recipes, and the KD / KR / KL exchange in a small simulated guild.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "Catalog.lua" })
local Catalog = ns.Catalog
local LS, LD = LibStub("LibSerialize"), LibStub("LibDeflate")

-- Recipes the "game" knows: recipeID -> { skillLine, itemID }
local GAME = {}
for i = 1, 450 do GAME[1000 + i] = { 197, 5000 + i } end -- Tailoring: 450 recipes
for i = 1, 30 do GAME[3000 + i] = { 171, 0 } end         -- Alchemy: 30 recipes without an item

local function gameVerify(recipeID, skillLine)
	local r = GAME[recipeID]
	if r and r[1] == skillLine then return r[2] end
end

local function profession(skillLine)
	local list = {}
	for id, r in pairs(GAME) do if r[1] == skillLine then list[id] = r[2] end end
	return list
end

-- A guild where every message reaches everyone else after the serializer round trip.
local function newGuild()
	local g = { t = 0, timers = {}, clients = {}, sent = { KD = 0, KR = 0, KL = 0 }, seed = 11 }
	function g.random()
		g.seed = (g.seed * 1103515245 + 12345) % 2147483648
		return g.seed / 2147483648
	end
	function g.add(guid, saved, verify)
		local client = { guid = guid, blocked = false }
		client.k = Catalog.New({
			send = function(msg)
				g.sent[msg.t] = g.sent[msg.t] + 1
				local text = LD:EncodeForWoWAddonChannel(LD:CompressDeflate(LS:Serialize(msg)))
				assert(#text < 24000, "message fits the receive limit")
				for _, other in ipairs(g.clients) do
					local ok, copy = LS:Deserialize(LD:DecompressDeflate(LD:DecodeForWoWAddonChannel(text)))
					assert(ok)
					other.k:OnMessage(copy) -- the sender gets its echo too and must ignore it
				end
			end,
			canSend = function() return not client.blocked end,
			now = function() return g.t end,
			after = function(delay, fn) g.timers[#g.timers + 1] = { at = g.t + delay, fn = fn } end,
			random = g.random,
			myGuid = function() return guid end,
			verify = verify or gameVerify,
			onChanged = function(skillLine) client.changed = skillLine end,
		}, saved or {})
		g.clients[#g.clients + 1] = client
		return client
	end
	function g.run(seconds)
		local target = g.t + seconds
		while true do
			table.sort(g.timers, function(a, b) return a.at < b.at end)
			local nextTimer = g.timers[1]
			if not nextTimer or nextTimer.at > target then break end
			table.remove(g.timers, 1)
			g.t = nextTimer.at
			nextTimer.fn()
		end
		g.t = target
	end
	return g
end

H.test("catalog: Add keeps valid recipes, only adds, fills a missing item and caps sizes", function()
	local k = Catalog.New({ now = function() return 0 end }, {})
	H.eq(k:Add(197, { [1001] = 5001, [1002] = 0, bad = 1, [-3] = 1, [1.5] = 1 }), 2)
	H.eq(k:Get(197)[1001], 5001)
	H.eq(k:Get(197)[1002], 0)
	H.eq(k:Add(197, { [1001] = 5001 }), 0, "nothing new")
	H.eq(k:Add(197, { [1002] = 5002 }), 1, "a missing crafted item is filled in")
	H.eq(k:Get(197)[1002], 5002)
	H.eq(k:Add(197, { [1001] = 0 }), 0, "a known item is not taken away")
	H.eq(k:Get(197)[1001], 5001)
	H.eq(k:Add("x", { [1] = 1 }), 0, "bad profession")
	local revision = k.revision
	k:Add(171, { [3001] = 0 })
	H.ok(k.revision > revision, "a change raises the revision")
	local recipes, profs = k:Total()
	H.eq(recipes, 3); H.eq(profs, 2)
	H.eq(k:Digest()[197], 2)

	local big = {}
	for i = 1, Catalog.MAX_PER_PROFESSION + 10 do big[i] = 0 end
	local k2 = Catalog.New({ now = function() return 0 end }, {})
	H.eq(k2:Add(197, big), Catalog.MAX_PER_PROFESSION, "capped per profession")
	for sl = 1, Catalog.MAX_PROFESSIONS + 3 do k2:Add(500 + sl, { [1] = 0 }) end
	local _, n = k2:Total()
	H.eq(n, Catalog.MAX_PROFESSIONS, "capped number of professions")
end)

H.test("catalog: a newcomer gets every profession from the guild in a few messages", function()
	local g = newGuild()
	local a = g.add("A")
	local b = g.add("B")
	local c = g.add("C")
	a.k:Add(197, profession(197))
	b.k:Add(197, profession(197))
	b.k:Add(171, profession(171))
	-- C logs in and announces its empty catalog: A and B answer with their digests
	c.k:Announce()
	g.run(30)
	H.eq(c.k:Count(197), 450, "all Tailoring recipes")
	H.eq(c.k:Count(171), 30, "all Alchemy recipes")
	H.eq(c.k:Get(197)[1001], 5001, "crafted item from the game, not from the message")
	H.eq(a.k:Count(171), 30, "A learned Alchemy from B's digest too")
	-- 450 recipes need 3 parts; one answer per profession and asking client
	H.ok(g.sent.KL <= 3 + 1 + 1, "lists sent once (" .. g.sent.KL .. ")")
	H.ok(g.sent.KR <= 3, "requests not repeated (" .. g.sent.KR .. ")")

	-- everyone is complete: a new round of digests sends no lists
	local lists = g.sent.KL
	g.run(200)
	for _, cl in ipairs(g.clients) do cl.k:Announce() end
	g.run(30)
	H.eq(g.sent.KL, lists, "nothing more to send")
end)

H.test("catalog: only answers to an own question are stored, and only recipes the game knows", function()
	local g = newGuild()
	local victim = g.add("V")
	g.add("X") -- a silent guildmate
	-- an unrequested list is ignored
	victim.k:OnMessage({ t = "KL", pv = 2, s = "X", l = 197, c = 2, r = { 1001, 1002 } })
	H.eq(victim.k:Count(197), 0, "unrequested list ignored")
	-- asked for: made-up IDs and recipes of another profession are dropped
	H.ok(victim.k:Want(197))
	g.run(5)
	victim.k:OnMessage({ t = "KL", pv = 2, s = "X", l = 197, c = 4, r = { 1001, 999999, 3001, "x" } })
	H.eq(victim.k:Count(197), 1, "only the real Tailoring recipe")
	H.eq(victim.k:Get(197)[1001], 5001)
	-- too late: the answer window has closed
	g.run(Catalog.ANSWER_WINDOW + 1)
	victim.k:OnMessage({ t = "KL", pv = 2, s = "X", l = 197, c = 1, r = { 1002 } })
	H.eq(victim.k:Count(197), 1, "late list ignored")
	-- wrong protocol, own echo and junk do not break anything
	victim.k:OnMessage({ t = "KD", pv = 3, s = "X", d = { [197] = 5 } })
	victim.k:OnMessage({ t = "KD", pv = 2, s = "V", d = { [197] = 5 } })
	victim.k:OnMessage({ t = "KD", pv = 2, s = "X", d = "junk" })
	victim.k:OnMessage({ t = "KR", pv = 2, s = "X", l = { "a", 197 } })
	victim.k:OnMessage("junk")
	g.run(10)
end)

H.test("catalog: blocked sending asks later, a request seen first is not repeated", function()
	local g = newGuild()
	local a = g.add("A")
	local b = g.add("B")
	local c = g.add("C")
	a.k:Add(197, profession(197))
	b.blocked, c.blocked = true, true
	a.k:Announce()
	g.run(10)
	H.eq(b.k:Count(197), 0, "nothing while blocked")
	H.eq(g.sent.KR, 0)
	b.blocked, c.blocked = false, false
	g.run(Catalog.ASK_AGAIN)
	a.k:Announce()
	g.run(30)
	H.eq(b.k:Count(197), 450)
	H.eq(c.k:Count(197), 450, "both got it")
	H.eq(g.sent.KR, 1, "the second client did not ask again")
end)

H.test("catalog: only a holder with more answers, not twice in a row, and a refused list is not asked again", function()
	local g = newGuild()
	local big = g.add("BIG")
	local small = g.add("SMALL")
	local asker = g.add("ASK")
	big.k:Add(197, profession(197))
	local part = {}
	for id, item in pairs(profession(197)) do if id <= 1100 then part[id] = item end end
	small.k:Add(197, part)
	asker.k:Add(197, part)
	-- the asker holds as much as SMALL: only BIG answers
	asker.k:Want(197, 450)
	g.run(30)
	H.eq(asker.k:Count(197), 450)
	H.eq(small.k.stats.sentL, 0, "SMALL did not answer")
	H.eq(big.k.stats.sentL, 3, "BIG sent its 450 recipes in 3 parts")
	-- another request right after: BIG does not send the same list again within the cooldown
	small.k.mine[197], small.k.asked[197], small.k.tried[197] = nil, nil, nil
	small.k:Want(197, 450)
	g.run(10)
	H.eq(big.k.stats.sentL, 3, "not again within the cooldown")
	H.ok(small.k:Count(197) < 450)
	g.run(Catalog.REPLY_COOLDOWN + 10)
	H.eq(small.k:Count(197), 450, "answered when the cooldown ended")

	-- the game refuses some IDs: the digest count is never reached, and the same count is not
	-- asked for again on every digest
	local g2 = newGuild()
	local holder = g2.add("H")
	local picky = g2.add("P", {}, function(id, sl) if id % 2 == 0 then return gameVerify(id, sl) end end)
	holder.k:Add(197, profession(197))
	holder.k:Announce()
	g2.run(30)
	H.eq(picky.k:Count(197), 225, "half the IDs accepted")
	local requests = g2.sent.KR
	g2.run(Catalog.ASK_AGAIN + Catalog.REPLY_COOLDOWN + 1)
	holder.k:Announce()
	g2.run(30)
	H.eq(g2.sent.KR, requests, "not asked again at the same count")
	-- a request nobody answers is forgotten after the answer window: the next digest asks again
	local g3 = newGuild()
	local lonely = g3.add("L")
	g3.add("Q") -- holds nothing, never answers
	lonely.k:OnMessage({ t = "KD", pv = 2, s = "Z", d = { [197] = 450 } })
	g3.run(Catalog.ANSWER_WINDOW + 5)
	H.eq(lonely.k.tried[197], nil, "no answer: not marked")
	H.ok(lonely.k:Want(197, 450), "asks again")
	-- a failed request may be asked again at once
	picky.k:OnSendFailed({ t = "KR", l = { 197 } })
	H.eq(picky.k.tried[197], nil)
end)
