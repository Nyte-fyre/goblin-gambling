-- lua tests/test_stats.lua   (run from the GoblinGambling/ folder)
local H = dofile("tests/helpers.lua")
local GG = H.load("Stats.lua")
local S = GG.Stats

------------------------------------------------------------------------
-- RecordRound
------------------------------------------------------------------------
local s = S.New()
S.RecordRound(s, "spin", 10, 0)     -- loss
S.RecordRound(s, "spin", 10, 0)     -- loss
S.RecordRound(s, "spin", 10, 10)    -- push: streaks unchanged
S.RecordRound(s, "spin", 10, 0)     -- loss
H.eq(s.curLoseStreak, 3, "push does not break a lose streak")
H.eq(s.maxLoseStreak, 3, "max lose streak")
S.RecordRound(s, "spin", 10, 500)   -- 50x win
S.RecordRound(s, "hand", 100, 250)  -- win
H.eq(s.curLoseStreak, 0, "win resets lose streak")
H.eq(s.curWinStreak, 2, "win streak")
H.eq(s.maxWinStreak, 2, "max win streak")
S.RecordRound(s, "spin", 10, 0)
H.eq(s.curWinStreak, 0, "loss resets win streak")
H.eq(s.maxWinStreak, 2, "max win streak kept")
H.eq(s.spins, 6, "spins counted")
H.eq(s.hands, 1, "hands counted separately")
H.eq(s.totalWagered, 160, "wagered")
H.eq(s.totalWon, 760, "won")
H.eq(S.Net(s), 600, "net")
H.eq(s.biggestWin, 500, "biggest win")
H.eq(s.biggestWinMult, 50, "biggest mult")

S.RecordBailout(s)
H.eq(s.bailouts, 1, "bailout counted")

------------------------------------------------------------------------
-- Titles, including priority when several apply
------------------------------------------------------------------------
local function title(overrides)
  local t = S.New()
  for k, v in pairs(overrides) do t[k] = v end
  return (S.GetTitle(t))
end

H.eq(title({}), "Casual Adventurer", "default")
H.eq(title({ spins = 499 }), "Casual Adventurer", "499 spins")
H.eq(title({ spins = 500 }), "Certified Degenerate", "500 spins")
H.eq(title({ biggestWinMult = 99.9 }), "Casual Adventurer", "99.9x")
H.eq(title({ biggestWinMult = 100 }), "Lucky Goblin", "100x")
H.eq(title({ bailouts = 2 }), "Casual Adventurer", "2 bailouts")
H.eq(title({ bailouts = 3 }), "Debtor of Ratchet", "3 bailouts")
H.eq(title({ totalWagered = 50000 }), "Casual Adventurer", "net exactly -50k is not a whale")
H.eq(title({ totalWagered = 50001 }), "Whale", "net -50,001")
H.eq(title({ totalWagered = 60000, bailouts = 5, spins = 900, biggestWinMult = 250 }), "Whale", "whale outranks all")
H.eq(title({ bailouts = 5, spins = 900, biggestWinMult = 250 }), "Debtor of Ratchet", "debtor outranks lucky")
H.eq(title({ spins = 900, biggestWinMult = 250 }), "Lucky Goblin", "lucky outranks degenerate")

-- Progress list
local prog = S.TitleProgress({ totalWagered = 1000, totalWon = 400, spins = 120, bailouts = 3,
  biggestWinMult = 12.5 })
H.eq(#prog, #S.TITLES, "one progress row per title")
H.eq(prog[1].title, "Whale", "priority order kept")
H.eq(prog[1].cur, 600, "whale progress = amount down")
H.eq(prog[1].earned, false, "not a whale yet")
H.eq(prog[2].earned, true, "debtor earned")
H.eq(prog[2].cur, 3, "bailout progress")
H.eq(prog[3].cur, 12.5, "lucky progress")
H.eq(prog[4].cur, 120, "spin progress")
H.eq(prog[4].goal, 500, "spin goal")
H.eq(prog[5].earned, true, "casual always earned")
H.eq(prog[5].goal, nil, "casual has no progress bar")
H.eq(S.TitleProgress(S.New())[1].cur, 0, "winning players show 0 toward whale")

local _, desc = S.GetTitle(S.New())
H.ok(type(desc) == "string" and #desc > 0, "titles have descriptions")

-- Multiplayer stats
local m = S.New()
local other = S.New()
S.RecordMPHand(m, 100, 0, false)         -- lost 100
S.RecordMPHand(m, 50, 300, true)         -- won a showdown
S.RecordMPHand(m, 20, 45, false)         -- won without showdown
S.RecordMPTable(m, "hosted")
S.RecordMPTable(m, "joined")
S.RecordMPTable(m, "joined")
H.eq(m.mp.hands, 3, "mp hands")
H.eq(m.mp.potsWon, 2, "mp pots won")
H.eq(m.mp.showdownsWon, 1, "mp showdowns won")
H.eq(m.mp.wagered, 170, "mp wagered")
H.eq(m.mp.won, 345, "mp won")
H.eq(m.mp.biggestPot, 300, "mp biggest pot")
H.eq(m.mp.hosted, 1, "tables hosted")
H.eq(m.mp.joined, 2, "tables joined")
H.eq(other.mp.hands, 0, "each New() has its own mp table")
H.eq(m.hands, 0, "mp recording alone does not touch the overall counters")
local legacy = { totalWagered = 0 }     -- saved before mp stats existed
S.RecordMPHand(legacy, 10, 0, false)
H.eq(legacy.mp.hands, 1, "old saves get an mp table on first use")

-- Addon wrappers use GG.db.stats
GG.db = { stats = S.New() }
GG:RecordRound("spin", 10, 2500)
H.eq(GG.db.stats.biggestWinMult, 250, "GG:RecordRound writes to db")
H.eq(GG:GetTitle(), "Lucky Goblin", "GG:GetTitle reads db")

print(string.format("test_stats: %d checks passed", H.passed))
