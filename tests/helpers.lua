-- Shared test helpers. Run tests from the GoblinGambling/ folder:
--   lua tests/test_slots.lua          (standalone Lua 5.1)
--   python tests/run.py               (no Lua installed: uses lupa)
local H = {}

-- Loads an addon file the way WoW does: with (addonName, sharedTable) as `...`.
H.GG = {}
function H.load(path)
  local chunk, err = loadfile(path)
  assert(chunk, err)
  chunk("GoblinGambling", H.GG)
  return H.GG
end

-- Deterministic Park-Miller RNG with the math.random(n) signature.
-- All products stay below 2^53, so it is exact in doubles on any platform.
function H.rng(seed)
  local state = (seed or 12345) % 2147483647
  if state <= 0 then state = state + 2147483646 end
  return function(n)
    state = (state * 16807) % 2147483647
    return math.floor((state - 1) / 2147483646 * n) + 1
  end
end

H.passed = 0
function H.eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", msg or "eq", tostring(expected), tostring(actual)), 2)
  end
  H.passed = H.passed + 1
end

function H.ok(cond, msg)
  if not cond then error(msg or "assertion failed", 2) end
  H.passed = H.passed + 1
end

return H
