"""Run a GoblinGambling test file under real Lua 5.1 (via lupa) when no
standalone `lua` binary is installed.

    python tests/run.py tests/test_slots.lua [more files...]

Run from the addon folder (GoblinGambling/). Exits non-zero on failure.
"""
import os
import sys

from lupa import lua51

ADDON_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(path):
    lua = lua51.LuaRuntime()
    rel = os.path.relpath(os.path.abspath(path), ADDON_ROOT).replace("\\", "/")
    lua.execute('arg = { [0] = ... }', rel)
    lua.globals().dofile(rel)


def main(paths):
    os.chdir(ADDON_ROOT)
    failed = 0
    for path in paths:
        print(f"== {path} ==", flush=True)
        try:
            run(path)
        except Exception as exc:  # LuaError from assert() or a runtime error
            failed += 1
            print(f"FAIL: {exc}", flush=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main(sys.argv[1:] or [
        "tests/test_slots.lua",
        "tests/test_poker_eval.lua",
        "tests/test_poker_engine.lua",
        "tests/test_poker_sim.lua",
        "tests/test_poker_net.lua",
        "tests/test_stats.lua",
        "tests/test_format.lua",
        "tests/test_ui_smoke.lua",
        "tests/test_slots_ui.lua",
        "tests/test_stats_ui.lua",
        "tests/test_poker_ui.lua",
        "tests/test_poker_mp_ui.lua",
    ])
