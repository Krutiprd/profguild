"""Runs tests/bench_npc.lua under PUC Lua 5.1 (lupa, pip install lupa), the game's Lua.
python tests/bench_npc.py [dir]   (see tests/bench_npc.lua)"""
import os, sys, time
import lupa.lua51 as lupa

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__))).replace("\\", "/")
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute("arg = {}")
g = lua.globals()
g.hrclock = lambda: time.perf_counter() * 1000  # os.clock steps by 1 ms on Windows
g.arg[0] = root + "/tests/bench_npc.lua"
for i, a in enumerate(sys.argv[1:]):
    g.arg[i + 1] = a if a == "nogc" else os.path.abspath(a).replace("\\", "/")
src = open(root + "/tests/bench_npc.lua", encoding="utf8").read().replace("\r", "")
lua.execute(src)
