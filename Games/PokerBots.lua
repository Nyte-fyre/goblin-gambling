-- Goblin Gambling Co. : Hold'em bots.
-- Pure Lua 5.1. Bots only ever see Poker.ViewFor(t, seat): their own cards,
-- the board, the pot and what they are allowed to do. No peeking.
local ADDON, GG = ...
GG = GG or {}

local Poker = GG.PokerLogic
local Bots = {}
GG.PokerBots = Bots

local floor = math.floor

------------------------------------------------------------------------
-- The cast
--   tightness  0..1  how picky about starting hands and marginal calls
--   aggression 0..1  how often strength turns into bets and raises
--   bluffFreq  0..1  chance to bet or raise with nothing
--   callBias   0..1  extra willingness to call (calling stations)
--   noise      0..1  random wobble on hand-strength reads
--   potOdds    true  plays exact pot odds (Grubnik)
------------------------------------------------------------------------
Bots.CAST = {
  { name = "Thorgrim",   race = "Dwarf",  class = "Warrior",
    tightness = 0.85, aggression = 0.45, bluffFreq = 0.02, callBias = 0,    noise = 0.03,
    blurb = "Tight as a Dwarven vault. When he bets, believe him." },
  { name = "Shadowstep", race = "Undead", class = "Rogue",
    tightness = 0.4,  aggression = 0.85, bluffFreq = 0.3,  callBias = 0,    noise = 0.05,
    blurb = "Aggressive. Bluffs from stealth. Will absolutely Sap your stack." },
  { name = "Moo-Tan",    race = "Tauren", class = "Druid",
    tightness = 0.1,  aggression = 0.15, bluffFreq = 0.02, callBias = 0.45, noise = 0.05,
    blurb = "Calling station. Moo-Tan has never folded anything, including laundry." },
  { name = "Zapzap",     race = "Gnome",  class = "Mage",
    tightness = 0.35, aggression = 0.6,  bluffFreq = 0.15, callBias = 0.1,  noise = 0.25,
    blurb = "Erratic. Decisions made by a tinker's random number generator." },
  { name = "Grubnik",    race = "Goblin", class = "Banker",
    tightness = 0.55, aggression = 0.5,  bluffFreq = 0.07, callBias = 0,    noise = 0,
    potOdds = true,
    blurb = "Plays the pot odds to the copper. Also holds your loan." },
}
Bots.BY_NAME = {}
for _, b in ipairs(Bots.CAST) do Bots.BY_NAME[b.name] = b end

------------------------------------------------------------------------
-- Table talk. Shown in the poker UI only, never in real chat.
------------------------------------------------------------------------
Bots.TAUNTS = {
  Thorgrim = {
    raise = { "By my beard, I raise.", "Solid as stone, this hand.", "Ye'll want to fold, lad." },
    fold  = { "Not worth the ale.", "Patience is a Dwarven virtue." },
    win   = { "Into the vault it goes.", "Ironforge thanks ye for yer donation." },
    lose  = { "Bah! Cursed cards.", "I'll be takin' that up with the Explorers' League." },
  },
  Shadowstep = {
    raise = { "Nothing personal, kid.", "You never saw it coming.", "Sap. Raise. Repeat." },
    fold  = { "Vanish.", "I'll catch you in the shadows." },
    win   = { "Too easy.", "Pickpocketed." },
    lose  = { "...Resisted.", "Next time, you won't see me." },
  },
  ["Moo-Tan"] = {
    raise = { "Moo? I mean, raise.", "The Earth Mother says bet." },
    call  = { "I call. I always call.", "Moo-Tan sees your bet.", "Calling. What were we doing?" },
    fold  = { "Moo-Tan is... folding? Strange feeling." },
    win   = { "The winds favor Moo-Tan!", "Moo." },
    lose  = { "Moo-Tan is at peace with this.", "The grass is still green." },
  },
  Zapzap = {
    raise = { "RANDOM NUMBER SAYS RAISE!", "Calculations complete! Maybe!", "For science!" },
    fold  = { "Recalculating...", "The gizmo said fold. I trust the gizmo." },
    win   = { "Gnomish engineering WINS!", "I knew that! Probably!" },
    lose  = { "My chips exploded. Again.", "That was a prototype hand." },
  },
  Grubnik = {
    raise = { "Time is money, friend.", "The odds say raise. The odds are never wrong.", "Pay up." },
    call  = { "Correct price. I'll call.", "Pot odds: acceptable." },
    fold  = { "Negative expected value. Pass.", "Not at those prices." },
    win   = { "Pleasure doing business.", "Put it on your tab.", "Interest applies." },
    lose  = { "I'll add that to your loan.", "A temporary market correction." },
  },
}

-- Returns a line for event ("raise"|"call"|"fold"|"win"|"lose") or nil.
-- chance defaults to 0.35 so the table is not a wall of text.
function Bots.Taunt(bot, event, rng, chance)
  rng = rng or math.random
  local lines = Bots.TAUNTS[bot.name] and Bots.TAUNTS[bot.name][event]
  if not lines then return nil end
  if rng(1000) > (chance or 0.35) * 1000 then return nil end
  return lines[rng(#lines)]
end

------------------------------------------------------------------------
-- Hand strength
------------------------------------------------------------------------

-- Chen formula for two hole cards (roughly -1 to 20, higher is better).
function Bots.Chen(hole)
  local r1, r2 = Poker.Rank(hole[1]), Poker.Rank(hole[2])
  if r1 < r2 then r1, r2 = r2, r1 end
  local function hi(r)
    if r == 14 then return 10 elseif r == 13 then return 8 elseif r == 12 then return 7
    elseif r == 11 then return 6 end
    return r / 2
  end
  local score = hi(r1)
  if r1 == r2 then
    score = math.max(score * 2, 5)
  else
    if Poker.Suit(hole[1]) == Poker.Suit(hole[2]) then score = score + 2 end
    local gap = r1 - r2 - 1
    if gap == 1 then score = score - 1
    elseif gap == 2 then score = score - 2
    elseif gap == 3 then score = score - 4
    elseif gap >= 4 then score = score - 5 end
    if gap <= 1 and r1 < 12 then score = score + 1 end
  end
  return math.ceil(score)
end

-- Monte Carlo equity: chance to win (ties split) against `opponents`
-- random hands, given our hole cards and the board so far.
function Bots.Equity(hole, board, opponents, rollouts, rng)
  rng = rng or math.random
  opponents = math.max(1, opponents)
  local known = {}
  known[hole[1]], known[hole[2]] = true, true
  for _, c in ipairs(board) do known[c] = true end
  local rest = {}
  for c = 1, 52 do if not known[c] then rest[#rest + 1] = c end end

  local needBoard = 5 - #board
  local draw = needBoard + opponents * 2
  local nRest = #rest
  local full = { hole[1], hole[2] }
  for i, c in ipairs(board) do full[2 + i] = c end
  local oppCards = {}
  local won = 0

  for _ = 1, rollouts do
    for i = 1, draw do
      local j = i + rng(nRest - i + 1) - 1
      rest[i], rest[j] = rest[j], rest[i]
    end
    for i = 1, needBoard do full[2 + #board + i] = rest[i] end
    local mine = Poker.Score(full)
    local ties, lost = 1, false
    for o = 1, opponents do
      oppCards[1] = rest[needBoard + o * 2 - 1]
      oppCards[2] = rest[needBoard + o * 2]
      for i = 3, 7 do oppCards[i] = full[i] end
      local theirs = Poker.Score(oppCards)
      if theirs > mine then lost = true; break end
      if theirs == mine then ties = ties + 1 end
    end
    if not lost then won = won + 1 / ties end
  end
  return won / rollouts
end

------------------------------------------------------------------------
-- Decisions
------------------------------------------------------------------------
local function Rand01(rng) return (rng(10000) - 1) / 10000 end

-- Implied-odds discount on the call price, by street.
local IMPLIED = { preflop = 0.6, flop = 0.85 }

local function RoundTo(n, step)
  return floor(n / step + 0.5) * step
end

-- A raise-to amount: pot-sized-ish, scaled by aggression and strength.
local function RaiseSize(bot, view, strength, rng)
  local la = view.legal
  local frac = 0.45 + 0.55 * bot.aggression + 0.3 * math.max(0, strength - 0.5)
  frac = frac + (Rand01(rng) - 0.5) * 0.3
  local target = la.currentBet + math.max(la.minRaiseTo - la.currentBet, view.pot * frac)
  target = RoundTo(target, view.bb)
  if target < la.minRaiseTo then target = la.minRaiseTo end
  if target > la.maxRaiseTo then target = la.maxRaiseTo end
  -- Close to all-in anyway? Just shove.
  if la.maxRaiseTo - target < view.bb * 2 then target = la.maxRaiseTo end
  return target
end

-- Returns an action table for Poker.Act, plus the equity it believed.
-- opts.rollouts: Monte Carlo rollouts (default 200; tests use fewer).
function Bots.Decide(bot, view, rng, opts)
  rng = rng or math.random
  opts = opts or {}
  local la = view.legal
  if not la then return nil end

  local opp = math.max(1, view.opponents)
  local equity = Bots.Equity(view.hole, view.board, opp, opts.rollouts or 200, rng)
  local read = equity + (Rand01(rng) - 0.5) * 2 * (bot.noise or 0)
  local fair = 1 / (opp + 1)                -- what an average hand wins
  local strength = read / fair               -- 1.0 = average, 2.0 = twice as good
  local toCall = la.call
  local potOdds = toCall > 0 and toCall / (view.pot + toCall) or 0
  local bluff = Rand01(rng) < (bot.bluffFreq or 0)
  local raiseCap = view.raiseCount >= 4      -- stop endless raise wars

  -- Preflop: tight bots throw away weak starting hands facing a real bet.
  if view.street == "preflop" and toCall > 0 and not bluff then
    local cutoff = 1 + 9 * bot.tightness
    local cheap = toCall <= view.bb * 0.5    -- completing the small blind
    if Bots.Chen(view.hole) < cutoff and not cheap and Rand01(rng) > bot.callBias then
      return { type = "fold" }, equity
    end
  end

  local raiseAt = 1.9 - 0.8 * bot.aggression   -- strength needed to bet or raise
  local callNeed
  if bot.potOdds then
    callNeed = potOdds                           -- exact: call when equity beats the price
  else
    -- Early calls are cheaper than they look (more chips to win later), so
    -- loose bots discount the price more before the turn.
    local implied = IMPLIED[view.street] or 1
    callNeed = potOdds * (1.1 + 0.4 * bot.tightness - bot.callBias) * implied
  end

  if toCall == 0 then
    local wantBet = strength >= raiseAt and Rand01(rng) < 0.35 + 0.65 * bot.aggression
    if la.canRaise and not raiseCap and (wantBet or bluff) then
      return { type = "raise", amount = RaiseSize(bot, view, read, rng) }, equity
    end
    return { type = "check" }, equity
  end

  local wantRaise = strength >= raiseAt * 1.2 and Rand01(rng) < bot.aggression
  if la.canRaise and not raiseCap and (wantRaise or (bluff and Rand01(rng) < 0.5)) then
    return { type = "raise", amount = RaiseSize(bot, view, read, rng) }, equity
  end
  if read >= callNeed then
    return { type = "call" }, equity
  end
  return { type = "fold" }, equity
end

-- Convenience for the table: decide for whoever is to act.
function Bots.Play(t, rng, opts)
  local seat = t.toAct
  local p = t.seats[seat]
  local bot = p.bot or Bots.CAST[1]
  local action = Bots.Decide(bot, Poker.ViewFor(t, seat), rng, opts)
  return seat, action
end

return Bots
