-- Minimal test harness for Profguild (Lua 5.1, outside the game).

local H = {}

H.root = (arg and arg[0] and arg[0]:match("^(.*)/tests/[^/]+$")) or "."
H.addon = H.root .. "/Profguild"

-- Loads an addon file the way WoW does: with (addonName, namespace) as varargs.
function H.loadAddonFile(ns, file)
	local chunk = assert(loadfile(H.addon .. "/" .. file))
	return chunk("Profguild", ns)
end

function H.newNamespace(files)
	local ns = {}
	for _, f in ipairs(files) do H.loadAddonFile(ns, f) end
	return ns
end

local loadedLibs = false
function H.loadLibs()
	if loadedLibs then return end
	dofile(H.addon .. "/Libs/LibStub/LibStub.lua")
	dofile(H.addon .. "/Libs/LibDeflate/LibDeflate.lua")
	dofile(H.addon .. "/Libs/LibSerialize/LibSerialize.lua")
	loadedLibs = true
end

-- Tests -------------------------------------------------------------------

local tests, failures = {}, {}

function H.test(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

function H.eq(actual, expected, msg)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
	end
end

function H.ok(cond, msg)
	if not cond then error(msg or "assertion failed", 2) end
end

function H.run()
	local passed = 0
	for _, t in ipairs(tests) do
		local ok, err = xpcall(t.fn, debug.traceback)
		if ok then
			passed = passed + 1
			io.write("  ok   ", t.name, "\n")
		else
			failures[#failures + 1] = t.name
			io.write("  FAIL ", t.name, "\n", err, "\n")
		end
	end
	io.write(string.format("\n%d passed, %d failed\n", passed, #failures))
	return #failures == 0
end

return H
