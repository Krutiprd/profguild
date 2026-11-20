-- Runs all Profguild tests: lua5.1 tests/run.lua (from the repository root)
local H = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/harness.lua")
local dir = H.root .. "/tests/"
for _, file in ipairs({ "test_store.lua", "test_sync_sim.lua", "test_reagents.lua", "test_catalog.lua", "test_locale.lua", "test_addon_load.lua", "test_bugs.lua" }) do
	-- a file that does not compile must fail the run, not silently drop its tests
	local chunk = assert(loadfile(dir .. file))
	chunk(H)
end
os.exit(H.run() and 0 or 1)
