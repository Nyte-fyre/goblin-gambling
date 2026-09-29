-- Goblin Gambling Co. : slot machine rules.
-- Pure Lua 5.1. No WoW API calls, so tests can run it from the terminal.
local ADDON, GG = ...
GG = GG or {}

local Slots = {}
GG.SlotsLogic = Slots

local floor = math.floor

------------------------------------------------------------------------
-- Symbols
------------------------------------------------------------------------
local ICON_PREFIX = "Interface\\Icons\\"
Slots.FALLBACK_ICON = ICON_PREFIX .. "INV_Misc_QuestionMark"

Slots.SYMBOLS = {
  WILD    = { name = "Hearthstone",     role = "Wild",    icon = ICON_PREFIX .. "INV_Misc_Rune_01",
              tip = "Substitutes for anything except Thunderfury. Goes home, comes back." },
  JACKPOT = { name = "Thunderfury",     role = "Legendary", icon = ICON_PREFIX .. "INV_Sword_39",
              tip = "Did someone say [Thunderfury, Blessed Blade of the Windseeker]? Both bindings, please. Wilds will not help you here." },
  GEM     = { name = "Epic Gem",        role = "High",    icon = ICON_PREFIX .. "INV_Misc_Gem_Variety_01",
              tip = "Shiny. Jewelcrafters weep." },
  HELM    = { name = "Crusader Helm",   role = "High",    icon = ICON_PREFIX .. "INV_Helmet_74",
              tip = "Righteous, shiny, and only slightly dented from the last crusade." },
  HPOT    = { name = "Healing Potion",  role = "Mid",     icon = ICON_PREFIX .. "INV_Potion_54",
              tip = "The healer is not paying attention, so this is all you have." },
  MPOT    = { name = "Mana Potion",     role = "Mid",     icon = ICON_PREFIX .. "INV_Potion_76",
              tip = "Mage food, but blue." },
  CLOTH   = { name = "Linen Cloth",     role = "Low",     icon = ICON_PREFIX .. "INV_Fabric_Linen_01",
              tip = "Every humanoid carries some. Nobody knows why." },
  MEAT    = { name = "Wolf Meat",       role = "Low",     icon = ICON_PREFIX .. "INV_Misc_Food_14",
              tip = "Dropped by 1 in 40 wolves. Wolves have many organs, none of them meat." },
  TRASH   = { name = "Vendor Trash",    role = "Junk",    icon = ICON_PREFIX .. "INV_Misc_Bone_HumanSkull_01",
              tip = "Grey quality. Sells for 3 copper. Emotional value: priceless." },
}

-- Display order for the paytable (best first).
Slots.SYMBOL_ORDER = { "JACKPOT", "WILD", "GEM", "HELM", "HPOT", "MPOT", "CLOTH", "MEAT", "TRASH" }

------------------------------------------------------------------------
-- Machine config. Everything that shapes the odds lives here, so more
-- reels or paylines is a data change.
--
-- Each reel is a physical strip of stops. A stop is {symbol, weight};
-- weight is how likely the reel is to stop with that entry on row 0.
-- The rows above and below are just the neighbouring stops, which is
-- what the UI draws.
--
-- A payline is one row offset per reel: 0 = middle row, -1 = top, 1 = bottom.
------------------------------------------------------------------------
Slots.config = {
  -- Per reel: JACKPOT 2, WILD 6, GEM 1, HELM 3, HPOT 4, MPOT 4, CLOTH 4,
  -- MEAT 8, TRASH 19 (total 51). Tuned for ~94% RTP, ~27% hit rate,
  -- jackpot about 1 in 16,600 spins. tests/test_slots.lua prints the exact numbers.
  reels = {
    { {"TRASH",5}, {"GEM",1},  {"MEAT",4},    {"TRASH",5}, {"WILD",3}, {"HPOT",4},  {"TRASH",5},
      {"JACKPOT",2}, {"MEAT",4}, {"CLOTH",4}, {"TRASH",4}, {"HELM",3}, {"WILD",3},  {"MPOT",4} },
    { {"MEAT",4},  {"TRASH",5}, {"HELM",3},   {"CLOTH",4}, {"WILD",3}, {"TRASH",5}, {"MPOT",4},
      {"JACKPOT",2}, {"TRASH",5}, {"GEM",1},  {"MEAT",4},  {"HPOT",4}, {"TRASH",4}, {"WILD",3} },
    { {"CLOTH",4}, {"TRASH",5}, {"JACKPOT",2}, {"MEAT",4}, {"WILD",3}, {"TRASH",5}, {"HPOT",4},
      {"GEM",1},   {"TRASH",5}, {"MPOT",4},   {"WILD",3},  {"MEAT",4}, {"TRASH",4}, {"HELM",3} },
  },

  paylines = { { 0, 0, 0 } },

  -- Every reel matching (wilds substitute, except for JACKPOT). Multiplier on bet.
  pays = {
    JACKPOT = 250,
    WILD    = 100,   -- three Hearthstones: you are going home rich
    GEM     = 50,
    HELM    = 25,
    HPOT    = 12,
    MPOT    = 10,
    CLOTH   = 5,
    MEAT    = 4,
    TRASH   = 2,
  },

  allButOneWild = 3,              -- two WILD + any one other symbol
  jackpotPartial = { [1] = 1,     -- one Thunderfury: money back
                     [2] = 5 },   -- two Thunderfuries: consolation

  bigWinMult = 25,                -- mult at or above this is a "big" win
}

------------------------------------------------------------------------
-- Flavor text, keyed by tier. UI picks one at random.
------------------------------------------------------------------------
Slots.FLAVOR = {
  loss = {
    "You have been Ganked by RNG.",
    "The goblin smiles. It is not a nice smile.",
    "Wipe. Run back from the graveyard.",
    "Need roll: lost to a hunter.",
    "Your gold has joined the Burning Legion.",
    "Try turning it off and on again.",
  },
  small = {
    "Not bad. Vendor will buy that.",
    "A modest haul. Enough for a repair bill.",
    "The goblin grudgingly slides some coins over.",
    "Green quality win. Disenchant it later.",
  },
  big = {
    "LOOT! Somebody call the guild bank.",
    "Epic drop! Link it in trade chat (do not actually).",
    "The goblin checks the machine for tampering.",
    "Your bags are getting heavy. Consider a larger bag.",
  },
  jackpot = {
    "FIRST SERVER JACKPOT. Please screenshot.",
    "LEGENDARY! The goblin faints. You step over him.",
    "Grats! /2 is already asking you for a loan.",
  },
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- rng(n) must return an integer in [1, n], exactly like math.random(n).
local function defaultRng(n) return math.random(n) end

local function reelTotal(reel)
  local t = 0
  for i = 1, #reel do t = t + reel[i][2] end
  return t
end

local function pickStop(reel, rng)
  local r = rng(reelTotal(reel))
  for i = 1, #reel do
    r = r - reel[i][2]
    if r <= 0 then return i end
  end
  return #reel
end

-- Symbol shown on a reel at a given stop and row offset (strip wraps).
function Slots.SymbolAt(reel, stop, offset)
  local n = #reel
  return reel[((stop - 1 + (offset or 0)) % n) + 1][1]
end

function Slots.Name(id)
  local s = Slots.SYMBOLS[id]
  return s and s.name or tostring(id)
end

------------------------------------------------------------------------
-- Line evaluation
-- syms: array of symbol ids along one payline.
-- Returns multiplier, label, isJackpot. Picks the best rule that applies.
------------------------------------------------------------------------
function Slots.EvaluateLine(syms, cfg)
  cfg = cfg or Slots.config
  local n = #syms
  local wilds, jacks, base, mixed = 0, 0, nil, false
  for i = 1, n do
    local s = syms[i]
    if s == "WILD" then
      wilds = wilds + 1
    elseif s == "JACKPOT" then
      jacks = jacks + 1
    elseif base == nil then
      base = s
    elseif base ~= s then
      mixed = true
    end
  end

  local bestMult, bestLabel = 0, nil
  local function consider(mult, label)
    if mult and mult > bestMult then bestMult, bestLabel = mult, label end
  end

  if jacks == n then
    return cfg.pays.JACKPOT, n .. "x " .. Slots.Name("JACKPOT"), true
  elseif wilds == n then
    consider(cfg.pays.WILD, n .. "x " .. Slots.Name("WILD"))
  elseif jacks == 0 and not mixed and base then
    local label = n .. "x " .. Slots.Name(base)
    if wilds > 0 then label = label .. " (with Wild)" end
    consider(cfg.pays[base], label)
  end

  if n >= 3 and wilds == n - 1 then
    consider(cfg.allButOneWild, (n - 1) .. "x " .. Slots.Name("WILD") .. " + any")
  end

  if jacks > 0 and jacks < n and cfg.jackpotPartial then
    local label = jacks == 1 and ("1x " .. Slots.Name("JACKPOT") .. " (money back)")
                               or (jacks .. "x " .. Slots.Name("JACKPOT"))
    consider(cfg.jackpotPartial[jacks], label)
  end

  return bestMult, bestLabel, false
end

function Slots.TierFor(mult, isJackpot, cfg)
  cfg = cfg or Slots.config
  if isJackpot then return "jackpot" end
  if mult <= 0 then return "loss" end
  if mult >= cfg.bigWinMult then return "big" end
  return "small"
end

-- Evaluates every payline for a set of stops. Returns total mult, the
-- per-line results, and whether a full JACKPOT line hit.
function Slots.EvaluateStops(stops, cfg)
  cfg = cfg or Slots.config
  local total, lines, jackpot = 0, {}, false
  for li = 1, #cfg.paylines do
    local line = cfg.paylines[li]
    local syms = {}
    for r = 1, #cfg.reels do
      syms[r] = Slots.SymbolAt(cfg.reels[r], stops[r], line[r])
    end
    local mult, label, isJackpot = Slots.EvaluateLine(syms, cfg)
    if isJackpot then jackpot = true end
    if mult > 0 then
      lines[#lines + 1] = { line = li, symbols = syms, mult = mult, label = label }
      total = total + mult
    end
  end
  return total, lines, jackpot
end

------------------------------------------------------------------------
-- spin(bet, rng)
-- Result:
--   reels  = { sym1, sym2, sym3 }   symbols on the middle row
--   stops  = { i1, i2, i3 }         strip indices (for the UI animation)
--   payout = Play Gold returned (0 on a loss; includes the stake on wins)
--   mult, tier ("loss"|"small"|"big"|"jackpot"), label, lines
------------------------------------------------------------------------
function Slots.Spin(bet, rng, cfg)
  cfg = cfg or Slots.config
  rng = rng or defaultRng
  local stops, middle = {}, {}
  for r = 1, #cfg.reels do
    stops[r] = pickStop(cfg.reels[r], rng)
    middle[r] = Slots.SymbolAt(cfg.reels[r], stops[r], 0)
  end
  local mult, lines, jackpot = Slots.EvaluateStops(stops, cfg)
  local tier = Slots.TierFor(mult, jackpot, cfg)
  local label
  if #lines == 1 then
    label = lines[1].label
  elseif #lines > 1 then
    label = #lines .. " winning lines"
  else
    label = "No win"
  end
  return {
    reels = middle, stops = stops, bet = bet,
    payout = floor(bet * mult), mult = mult,
    tier = tier, label = label, lines = lines,
  }
end
Slots.spin = Slots.Spin

------------------------------------------------------------------------
-- Exact return-to-player: enumerate every stop combination, weighted by
-- stop weights. Returns rtp, hitRate, breakdown[label] = contribution,
-- and the per-spin standard deviation of the multiplier (volatility).
------------------------------------------------------------------------
function Slots.ComputeRTP(cfg)
  cfg = cfg or Slots.config
  local reels = cfg.reels
  local nReels = #reels
  local totals, denom = {}, 1
  for r = 1, nReels do
    totals[r] = reelTotal(reels[r])
    denom = denom * totals[r]
  end

  local rtp, hit, m2 = 0, 0, 0
  local breakdown = {}
  local stops = {}

  local function walk(r, weight)
    if r > nReels then
      local mult, lines = Slots.EvaluateStops(stops, cfg)
      if mult > 0 then
        local p = weight / denom
        rtp = rtp + mult * p
        m2 = m2 + mult * mult * p
        hit = hit + p
        for i = 1, #lines do
          local key = lines[i].label
          breakdown[key] = (breakdown[key] or 0) + lines[i].mult * p
        end
      end
      return
    end
    local reel = reels[r]
    for i = 1, #reel do
      stops[r] = i
      walk(r + 1, weight * reel[i][2])
    end
  end
  walk(1, 1)

  return rtp, hit, breakdown, math.sqrt(m2 - rtp * rtp)
end
Slots.computeRTP = Slots.ComputeRTP

-- Lowest and highest selectable bets, shared with the UI and broke check.
Slots.BETS = { 10, 50, 100 }
Slots.MIN_BET = 10
Slots.MAX_BET = 1000

return Slots
