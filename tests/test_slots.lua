-- lua tests/test_slots.lua   (run from the GoblinGambling/ folder)
local H = dofile("tests/helpers.lua")
local GG = H.load("Games/SlotsLogic.lua")
local S = GG.SlotsLogic
local cfg = S.config

------------------------------------------------------------------------
-- Config sanity
------------------------------------------------------------------------
for id in pairs(S.SYMBOLS) do
  H.ok(cfg.pays[id], "no 3-of-a-kind pay for " .. id)
end
for r = 1, #cfg.reels do
  local seen = {}
  for _, stop in ipairs(cfg.reels[r]) do
    H.ok(S.SYMBOLS[stop[1]], "unknown symbol on reel " .. r .. ": " .. tostring(stop[1]))
    H.ok(stop[2] > 0 and stop[2] == math.floor(stop[2]), "weights must be positive integers")
    seen[stop[1]] = true
  end
  for id in pairs(S.SYMBOLS) do H.ok(seen[id], id .. " missing from reel " .. r) end
end
for _, line in ipairs(cfg.paylines) do H.eq(#line, #cfg.reels, "payline length") end

------------------------------------------------------------------------
-- Line evaluation, known answers
------------------------------------------------------------------------
local function mult(a, b, c) return (S.EvaluateLine({ a, b, c })) end

H.eq(mult("JACKPOT", "JACKPOT", "JACKPOT"), 250, "3 jackpot")
H.eq(select(3, S.EvaluateLine({ "JACKPOT", "JACKPOT", "JACKPOT" })), true, "jackpot flag")
H.eq(mult("WILD", "WILD", "WILD"), 100, "3 wild")
H.eq(mult("GEM", "GEM", "GEM"), 50, "3 gem")
H.eq(mult("HELM", "HELM", "HELM"), 25, "3 helm")
H.eq(mult("HPOT", "HPOT", "HPOT"), 12, "3 hpot")
H.eq(mult("MPOT", "MPOT", "MPOT"), 10, "3 mpot")
H.eq(mult("CLOTH", "CLOTH", "CLOTH"), 5, "3 cloth")
H.eq(mult("MEAT", "MEAT", "MEAT"), 4, "3 meat")
H.eq(mult("TRASH", "TRASH", "TRASH"), 2, "3 trash")

-- Wild substitution
H.eq(mult("GEM", "WILD", "GEM"), 50, "wild subs for gem")
H.eq(mult("WILD", "WILD", "GEM"), 50, "two wilds + gem = 3 gem")
H.eq(mult("WILD", "WILD", "TRASH"), 3, "two wilds + trash: all-but-one-wild beats 3 trash")
H.eq(mult("MEAT", "WILD", "WILD"), 4, "two wilds + meat = 3 meat")
H.eq(mult("WILD", "GEM", "HELM"), 0, "one wild, mismatched")

-- Wilds never make a jackpot
H.eq(mult("JACKPOT", "WILD", "JACKPOT"), 5, "2 jackpot + wild = consolation, not jackpot")
H.eq(select(3, S.EvaluateLine({ "JACKPOT", "WILD", "JACKPOT" })), false, "no jackpot flag with wild")
H.eq(mult("JACKPOT", "WILD", "WILD"), 3, "jackpot + 2 wild: all-but-one-wild")
H.eq(mult("JACKPOT", "GEM", "TRASH"), 1, "single jackpot money back")
H.eq(mult("GEM", "JACKPOT", "GEM"), 1, "jackpot breaks the gem line, money back")
H.eq(mult("JACKPOT", "JACKPOT", "MEAT"), 5, "two jackpots")

-- Losses
H.eq(mult("GEM", "HELM", "TRASH"), 0, "mixed")
H.eq(mult("TRASH", "TRASH", "MEAT"), 0, "two of a kind pays nothing")

-- Tiers
H.eq(S.TierFor(0, false), "loss", "tier loss")
H.eq(S.TierFor(2, false), "small", "tier small")
H.eq(S.TierFor(25, false), "big", "tier big")
H.eq(S.TierFor(250, true), "jackpot", "tier jackpot")

-- Strip wraps for the rows above/below
local reel = cfg.reels[1]
H.eq(S.SymbolAt(reel, 1, -1), reel[#reel][1], "wrap above")
H.eq(S.SymbolAt(reel, #reel, 1), reel[1][1], "wrap below")

------------------------------------------------------------------------
-- Spin shape and determinism
------------------------------------------------------------------------
local r1 = S.Spin(100, H.rng(42))
local r2 = S.Spin(100, H.rng(42))
H.eq(#r1.reels, 3, "three reels")
for i = 1, 3 do H.eq(r1.reels[i], r2.reels[i], "same seed same result") end
H.ok(r1.tier == "loss" or r1.tier == "small" or r1.tier == "big" or r1.tier == "jackpot", "tier value")
H.eq(r1.payout, math.floor(100 * r1.mult), "payout = bet * mult")

-- Forced outcome: an RNG that always lands on the first JACKPOT stop.
local function forceSymbol(sym)
  local r = 0
  return function(n)
    r = r + 1
    local strip, acc = cfg.reels[r], 0
    for _, stop in ipairs(strip) do
      acc = acc + stop[2]
      if stop[1] == sym then return acc end
    end
  end
end
local jp = S.Spin(10, forceSymbol("JACKPOT"))
H.eq(jp.tier, "jackpot", "forced jackpot tier")
H.eq(jp.payout, 2500, "forced jackpot payout")
local tr = S.Spin(10, forceSymbol("TRASH"))
H.eq(tr.payout, 20, "forced trash payout")
H.eq(tr.tier, "small", "forced trash tier")

------------------------------------------------------------------------
-- Exact RTP
------------------------------------------------------------------------
local rtp, hit, breakdown, sd = S.ComputeRTP()
print(string.format("Exact RTP: %.4f%%   hit rate: %.2f%% (1 in %.2f)   volatility (sd): %.2f",
  rtp * 100, hit * 100, 1 / hit, sd))
local keys = {}
for k in pairs(breakdown) do keys[#keys + 1] = k end
table.sort(keys, function(a, b) return breakdown[a] > breakdown[b] end)
for _, k in ipairs(keys) do
  print(string.format("   %-40s %7.3f%%", k, breakdown[k] * 100))
end
H.ok(rtp >= 0.92 and rtp <= 0.96, string.format("RTP %.4f outside [0.92, 0.96]", rtp))

------------------------------------------------------------------------
-- Monte Carlo sanity check
------------------------------------------------------------------------
local N = 1000000
local rng = H.rng(20260929)
local wagered, returned, jackpots = 0, 0, 0
for _ = 1, N do
  local res = S.Spin(10, rng)
  wagered = wagered + 10
  returned = returned + res.payout
  if res.tier == "jackpot" then jackpots = jackpots + 1 end
end
local observed = returned / wagered
-- Big rare payouts make 1M spins noisy; allow 3 standard errors (about 1.5%).
local tolerance = 3 * sd / math.sqrt(N)
print(string.format("Monte Carlo (%d spins): RTP %.4f%%, off by %.3f%% (tolerance %.3f%%), jackpots %d",
  N, observed * 100, math.abs(observed - rtp) * 100, tolerance * 100, jackpots))
H.ok(math.abs(observed - rtp) < tolerance, "Monte Carlo disagrees with exact RTP beyond 3 standard errors")

print(string.format("test_slots: %d checks passed", H.passed))
