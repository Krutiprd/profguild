-- Runs all Profguild tests: lua5.1 tests/run.lua (from the repository root)
local H = dofile((arg[0]:match("^(.*)/[^/]+$") or ".") .. "/harness.lua")
local dir = H.root .. "/tests/"
for _, file in ipairs({ "test_store.lua", "test_sync_sim.lua", "test_locale.lua", "test_addon_load.lua" }) do
	local chunk = loadfile(dir .. file)
	if chunk then chunk(H) end
end
os.exit(H.run() and 0 or 1)
