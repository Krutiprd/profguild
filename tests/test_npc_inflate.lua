-- NpcInflate: the bounded, sliceable DEFLATE decompressor of NPC texts. Its output equals
-- LibDeflate's for every input (valid streams of every level, stored blocks, broken streams), and
-- it stops at its size limit before writing more.
local H = ...
H.loadLibs()
local ns = H.newNamespace({ "NpcInflate.lua" })
local Inflate = ns.NpcInflate.Inflate
local LD = LibStub("LibDeflate")

local function gen(seed, n, kind)
	local x, t = seed, {}
	local function r(m) x = (x * 1103515245 + 12345) % 2147483648 return x % m end
	for i = 1, n do
		if kind == "noise" then t[i] = string.char(r(256))
		elseif kind == "text" then t[i] = string.char(97 + r(6))
		elseif kind == "runs" then t[i] = string.char(65 + math.floor(i / (1 + r(40))) % 3)
		else t[i] = string.char(48 + (i % 10)) end
	end
	return table.concat(t)
end

H.test("inflate: equals LibDeflate on streams of every level and kind of data", function()
	local n = 0
	for seed = 1, 6 do
		for _, kind in ipairs({ "noise", "text", "runs", "digits" }) do
			for _, len in ipairs({ 0, 1, 17, 300, 5000, 70000 }) do
				local data = gen(seed, len, kind)
				for _, level in ipairs({ 0, 1, 5, 9 }) do
					local c = LD:CompressDeflate(data, { level = level })
					local a = LD:DecompressDeflate(c)
					local b = Inflate(c, 1e9)
					H.ok(a == data and b == data, ("seed %d %s %d level %d"):format(seed, kind, len, level))
					n = n + 1
				end
			end
		end
	end
	H.eq(n, 576)
end)

H.test("inflate: a broken stream gives what LibDeflate gives (nil or the same bytes)", function()
	local x = 99
	local function r(m) x = (x * 1103515245 + 12345) % 2147483648 return x % m end
	local cases, agree = 0, 0
	for seed = 1, 300 do
		local c = LD:CompressDeflate(gen(seed, 200 + r(3000), ({ "text", "runs", "noise" })[1 + r(3)]), { level = r(10) })
		local b = { c:byte(1, -1) }
		local how = r(3)
		if how == 0 then b[1 + r(#b)] = r(256)
		elseif how == 1 then for _ = 1, r(#b) do b[#b] = nil end
		else for _ = 1, 3 do b[1 + r(#b)] = r(256) end end
		local s = string.char(unpack(b))
		local okA, a = pcall(LD.DecompressDeflate, LD, s)
		local okB, d = pcall(Inflate, s, 1e9)
		H.ok(okB, "never an error: " .. tostring(d))
		cases = cases + 1
		if (okA and a or nil) == d then agree = agree + 1 end
	end
	H.eq(agree, cases, "agree with LibDeflate")
end)

H.test("inflate: stops at the limit (a bomb), the parts it ticks are few, a stream at the limit passes", function()
	local big = string.rep("\1", 3000000)
	local c = LD:CompressDeflate(big, { level = 9 })
	local ticks = 0
	local out, why = Inflate(c, 16384, function() ticks = ticks + 1 end)
	H.eq(out, nil) H.eq(why, "too large")
	H.ok(ticks < 10, "stopped early: " .. ticks)
	local exact = gen(3, 16384, "text")
	H.eq(Inflate(LD:CompressDeflate(exact), 16384), exact, "exactly the limit")
	H.eq(select(2, Inflate(LD:CompressDeflate(exact .. "x"), 16384)), "too large", "one byte over")
	-- stored blocks too
	H.eq(select(2, Inflate(LD:CompressDeflate(gen(4, 20000, "noise"), { level = 0 }), 16384)), "too large")
	-- ticks come in parts of a few hundred symbols
	local n = 0
	H.eq(Inflate(LD:CompressDeflate(gen(5, 40000, "text")), 1e9, function() n = n + 1 end), gen(5, 40000, "text"))
	H.ok(n >= 5, "ticked: " .. n)
end)

-- A hostile stream of empty dynamic blocks: no output (the limit never fires) and no symbol loop
-- long enough to tick; each block still costs its code tables.
local function emptyBlocks(n)
	local bits, nb = {}, 0
	local function put(v, k) for _ = 1, k do nb = nb + 1 bits[nb] = v % 2 v = math.floor(v / 2) end end
	for b = 1, n do
		put(b == n and 1 or 0, 1)
		put(2, 2) put(0, 5) put(0, 5) put(14, 4)
		local L = { 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }
		for i = 1, 18 do put(L[i], 3) end
		put(1, 1) put(127, 7) put(1, 1) put(107, 7)
		put(0, 1) put(0, 1)
		put(0, 1)
	end
	local out = {}
	for i = 1, nb, 8 do
		local v = 0
		for j = 7, 0, -1 do v = v * 2 + (bits[i + j] or 0) end
		out[#out + 1] = string.char(v)
	end
	return table.concat(out)
end

H.test("inflate: a stream of many empty blocks ticks at every block", function()
	local s = emptyBlocks(300)
	H.eq(LD:DecompressDeflate(s), "", "LibDeflate reads it as empty")
	local ticks = 0
	H.eq(Inflate(s, 16384, function() ticks = ticks + 1 end), "")
	H.ok(ticks >= 300, "ticked per block: " .. ticks)
end)
