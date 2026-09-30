-- Goblin Gambling Co. : lifetime stats and titles.
-- Pure Lua 5.1: every function takes the stats table it works on, so tests
-- can run it from the terminal. Core.lua passes GG.db.stats in.
local ADDON, GG = ...
GG = GG or {}

local Stats = {}
GG.Stats = Stats

Stats.DEFAULTS = {
  totalWagered = 0, totalWon = 0,
  biggestWin = 0,      -- largest single payout, in Goblin Gold
  biggestWinMult = 0,  -- largest payout / wager, for the Lucky Goblin title
  spins = 0, hands = 0,
  curLoseStreak = 0, maxLoseStreak = 0,
  curWinStreak = 0, maxWinStreak = 0,
  bailouts = 0,
}

function Stats.New()
  local t = {}
  for k, v in pairs(Stats.DEFAULTS) do t[k] = v end
  return t
end

function Stats.Net(s)
  return (s.totalWon or 0) - (s.totalWagered or 0)
end

-- Record one finished round.
-- kind: "spin" or "hand". wager: Goblin Gold put in. payout: Goblin Gold
-- returned (0 on a loss, includes the stake on a win).
-- A payout above the wager is a win, below is a loss, equal is a push
-- (money back), which leaves both streaks alone.
function Stats.RecordRound(s, kind, wager, payout)
  wager, payout = wager or 0, payout or 0
  s.totalWagered = s.totalWagered + wager
  s.totalWon = s.totalWon + payout
  if kind == "hand" then
    s.hands = s.hands + 1
  else
    s.spins = s.spins + 1
  end

  if payout > s.biggestWin then s.biggestWin = payout end
  if wager > 0 then
    local mult = payout / wager
    if mult > s.biggestWinMult then s.biggestWinMult = mult end
  end

  if payout > wager then
    s.curWinStreak = s.curWinStreak + 1
    s.curLoseStreak = 0
    if s.curWinStreak > s.maxWinStreak then s.maxWinStreak = s.curWinStreak end
  elseif payout < wager then
    s.curLoseStreak = s.curLoseStreak + 1
    s.curWinStreak = 0
    if s.curLoseStreak > s.maxLoseStreak then s.maxLoseStreak = s.curLoseStreak end
  end
end

function Stats.RecordBailout(s)
  s.bailouts = s.bailouts + 1
end

------------------------------------------------------------------------
-- Titles. First match wins, so the list is in priority order.
------------------------------------------------------------------------
Stats.TITLES = {
  { title = "Whale",
    desc  = "Down more than 50,000 Goblin Gold. The goblins have named a yacht after you.",
    test  = function(s) return Stats.Net(s) < -50000 end,
    progress = function(s) return math.max(0, -Stats.Net(s)), 50000, "Goblin Gold down" end },
  { title = "Debtor of Ratchet",
    desc  = "Took 3 or more bailouts. Grubnik knows where you hearth.",
    test  = function(s) return (s.bailouts or 0) >= 3 end,
    progress = function(s) return s.bailouts or 0, 3, "bailouts" end },
  { title = "Lucky Goblin",
    desc  = "Won 100x your bet or more in one go.",
    test  = function(s) return (s.biggestWinMult or 0) >= 100 end,
    progress = function(s) return s.biggestWinMult or 0, 100, "x best win" end },
  { title = "Certified Degenerate",
    desc  = "Pulled the lever 500+ times. Touch grass. Or Peacebloom.",
    test  = function(s) return (s.spins or 0) >= 500 end,
    progress = function(s) return s.spins or 0, 500, "spins" end },
  { title = "Casual Adventurer",
    desc  = "Just here for the free drinks.",
    test  = function() return true end },
}

-- Every title with whether the stats qualify and how close they are.
-- Returns { {title, desc, earned, cur, goal, unit}, ... } in priority order.
function Stats.TitleProgress(s)
  local out = {}
  for i = 1, #Stats.TITLES do
    local t = Stats.TITLES[i]
    local cur, goal, unit
    if t.progress then cur, goal, unit = t.progress(s) end
    out[i] = { title = t.title, desc = t.desc, earned = t.test(s) and true or false,
               cur = cur, goal = goal, unit = unit }
  end
  return out
end

-- Returns title, description.
function Stats.GetTitle(s)
  for i = 1, #Stats.TITLES do
    local t = Stats.TITLES[i]
    if t.test(s) then return t.title, t.desc end
  end
end

------------------------------------------------------------------------
-- Addon-side convenience wrappers (no WoW API, just GG.db).
------------------------------------------------------------------------
function GG:RecordRound(kind, wager, payout)
  Stats.RecordRound(self.db.stats, kind, wager, payout)
end

function GG:GetTitle()
  return Stats.GetTitle(self.db.stats)
end

return Stats
