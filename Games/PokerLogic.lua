-- Goblin Gambling Co. : Texas Hold'em rules.
-- Pure Lua 5.1. No WoW API calls, so tests can run it from the terminal.
--
-- This file currently holds cards, deck, shuffle and the hand evaluator.
-- The betting state machine is added in milestone M5.
local ADDON, GG = ...
GG = GG or {}

local Poker = {}
GG.PokerLogic = Poker

local floor = math.floor

------------------------------------------------------------------------
-- Cards
-- A card is an integer 1..52: rank = floor((c-1)/4) + 2 (2..14, A = 14),
-- suit = (c-1) % 4 + 1 (1 = clubs, 2 = diamonds, 3 = hearts, 4 = spades).
-- Integers keep bot Monte Carlo rollouts cheap and serialize trivially
-- for addon messages later.
------------------------------------------------------------------------
Poker.RANK_CHARS = { [2]="2", [3]="3", [4]="4", [5]="5", [6]="6", [7]="7", [8]="8",
                     [9]="9", [10]="T", [11]="J", [12]="Q", [13]="K", [14]="A" }
Poker.RANK_NAMES = { [2]="Two", [3]="Three", [4]="Four", [5]="Five", [6]="Six", [7]="Seven",
                     [8]="Eight", [9]="Nine", [10]="Ten", [11]="Jack", [12]="Queen",
                     [13]="King", [14]="Ace" }
Poker.RANK_PLURAL = { [6] = "Sixes" }
Poker.SUIT_CHARS = { "c", "d", "h", "s" }
Poker.SUIT_NAMES = { "Clubs", "Diamonds", "Hearts", "Spades" }
Poker.SUIT_RED = { false, true, true, false }

local RANK_BY_CHAR, SUIT_BY_CHAR = {}, {}
for r, ch in pairs(Poker.RANK_CHARS) do RANK_BY_CHAR[ch] = r end
for s, ch in ipairs(Poker.SUIT_CHARS) do SUIT_BY_CHAR[ch] = s end

function Poker.Card(rank, suit) return (rank - 2) * 4 + suit end
function Poker.Rank(c) return floor((c - 1) / 4) + 2 end
function Poker.Suit(c) return (c - 1) % 4 + 1 end

function Poker.CardString(c)
  return Poker.RANK_CHARS[Poker.Rank(c)] .. Poker.SUIT_CHARS[Poker.Suit(c)]
end

-- "As" / "Td" / "10h" -> card id. Returns nil for anything else.
function Poker.ParseCard(str)
  str = tostring(str)
  local r, s = str:match("^(10)([cdhsCDHS])$")
  if not r then r, s = str:match("^([2-9TJQKAtjqka])([cdhsCDHS])$") end
  if not r then return nil end
  local rank = (r == "10") and 10 or RANK_BY_CHAR[r:upper()]
  return Poker.Card(rank, SUIT_BY_CHAR[s:lower()])
end

-- "As Kd 7h" -> { cards }
function Poker.ParseCards(str)
  local out = {}
  for token in tostring(str):gmatch("%S+") do
    out[#out + 1] = assert(Poker.ParseCard(token), "bad card: " .. token)
  end
  return out
end

------------------------------------------------------------------------
-- Deck
-- rng(n) must return an integer in [1, n], exactly like math.random(n).
------------------------------------------------------------------------
function Poker.NewDeck()
  local d = {}
  for c = 1, 52 do d[c] = c end
  return d
end

-- Fisher-Yates, in place. Returns the deck for convenience.
function Poker.Shuffle(deck, rng)
  rng = rng or math.random
  for i = #deck, 2, -1 do
    local j = rng(i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  return deck
end

------------------------------------------------------------------------
-- Hand evaluation
------------------------------------------------------------------------
Poker.CATEGORY = {
  HIGH_CARD = 1, PAIR = 2, TWO_PAIR = 3, TRIPS = 4, STRAIGHT = 5,
  FLUSH = 6, FULL_HOUSE = 7, QUADS = 8, STRAIGHT_FLUSH = 9,
}
Poker.CATEGORY_NAMES = {
  "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight",
  "Flush", "Full House", "Four of a Kind", "Straight Flush",
}

local C = Poker.CATEGORY

-- Highest straight in a rank-presence table, or nil. The wheel (A-2-3-4-5) is 5-high.
local function straightHigh(has)
  for high = 14, 6, -1 do
    if has[high] and has[high - 1] and has[high - 2] and has[high - 3] and has[high - 4] then
      return high
    end
  end
  if has[14] and has[2] and has[3] and has[4] and has[5] then return 5 end
  return nil
end

-- Pack category + up to five tiebreak ranks into one comparable number.
-- Base 15 keeps every rank distinct; the max score fits easily in a double.
local function pack(cat, t)
  local s = cat
  for i = 1, 5 do s = s * 15 + (t[i] or 0) end
  return s
end

local function plural(r)
  return Poker.RANK_PLURAL[r] or (Poker.RANK_NAMES[r] .. "s")
end

local function describe(cat, t)
  local N = Poker.RANK_NAMES
  if cat == C.STRAIGHT_FLUSH then
    if t[1] == 14 then return "Royal Flush" end
    return "Straight Flush, " .. N[t[1]] .. " high"
  elseif cat == C.QUADS then return "Four " .. plural(t[1])
  elseif cat == C.FULL_HOUSE then return "Full House, " .. plural(t[1]) .. " over " .. plural(t[2])
  elseif cat == C.FLUSH then return "Flush, " .. N[t[1]] .. " high"
  elseif cat == C.STRAIGHT then return "Straight, " .. N[t[1]] .. " high"
  elseif cat == C.TRIPS then return "Three " .. plural(t[1])
  elseif cat == C.TWO_PAIR then return "Two Pair, " .. plural(t[1]) .. " and " .. plural(t[2])
  elseif cat == C.PAIR then return "Pair of " .. plural(t[1])
  end
  return N[t[1]] .. " high"
end

-- Evaluates the best 5-card hand from 5 to 7 cards.
-- Returns a table: { score, category, name, ranks = {tiebreak ranks} }.
-- Higher score wins; equal scores split.
function Poker.Evaluate(cards)
  local count, has = {}, {}
  local suitRanks = { {}, {}, {}, {} }
  for i = 1, #cards do
    local c = cards[i]
    local r, s = floor((c - 1) / 4) + 2, (c - 1) % 4 + 1
    count[r] = (count[r] or 0) + 1
    has[r] = true
    local sr = suitRanks[s]
    sr[#sr + 1] = r
  end

  local cat, t

  -- Flush / straight flush
  local flushRanks
  for s = 1, 4 do
    if #suitRanks[s] >= 5 then flushRanks = suitRanks[s] end
  end
  if flushRanks then
    local fhas = {}
    for i = 1, #flushRanks do fhas[flushRanks[i]] = true end
    local sf = straightHigh(fhas)
    if sf then
      cat, t = C.STRAIGHT_FLUSH, { sf }
    end
  end

  if not cat then
    -- Group ranks by count, high ranks first.
    local quads, trips, pairs_, singles = {}, {}, {}, {}
    for r = 14, 2, -1 do
      local n = count[r]
      if n == 4 then quads[#quads + 1] = r
      elseif n == 3 then trips[#trips + 1] = r
      elseif n == 2 then pairs_[#pairs_ + 1] = r
      elseif n == 1 then singles[#singles + 1] = r end
    end

    -- Best kicker(s) among all ranks except the excluded ones.
    local function kickers(k, ex1, ex2)
      local out = {}
      for r = 14, 2, -1 do
        if count[r] and r ~= ex1 and r ~= ex2 then
          out[#out + 1] = r
          if #out == k then break end
        end
      end
      return out
    end

    if quads[1] then
      cat, t = C.QUADS, { quads[1], kickers(1, quads[1])[1] }
    elseif trips[1] and (trips[2] or pairs_[1]) then
      local pairRank = trips[2] or 0
      if pairs_[1] and pairs_[1] > pairRank then pairRank = pairs_[1] end
      cat, t = C.FULL_HOUSE, { trips[1], pairRank }
    elseif flushRanks then
      table.sort(flushRanks, function(a, b) return a > b end)
      cat, t = C.FLUSH, { flushRanks[1], flushRanks[2], flushRanks[3], flushRanks[4], flushRanks[5] }
    else
      local st = straightHigh(has)
      if st then
        cat, t = C.STRAIGHT, { st }
      elseif trips[1] then
        local k = kickers(2, trips[1])
        cat, t = C.TRIPS, { trips[1], k[1], k[2] }
      elseif pairs_[2] then
        cat, t = C.TWO_PAIR, { pairs_[1], pairs_[2], kickers(1, pairs_[1], pairs_[2])[1] }
      elseif pairs_[1] then
        local k = kickers(3, pairs_[1])
        cat, t = C.PAIR, { pairs_[1], k[1], k[2], k[3] }
      else
        local k = kickers(5)
        cat, t = C.HIGH_CARD, k
      end
    end
  end

  return { score = pack(cat, t), category = cat, name = describe(cat, t), ranks = t }
end

-- Convenience: score only.
function Poker.Score(cards) return Poker.Evaluate(cards).score end

-- hands: array of card arrays. Returns array of winning indices (ties split),
-- plus the evaluations.
function Poker.Winners(hands)
  local best, winners, evals = -1, {}, {}
  for i = 1, #hands do
    local e = Poker.Evaluate(hands[i])
    evals[i] = e
    if e.score > best then
      best, winners = e.score, { i }
    elseif e.score == best then
      winners[#winners + 1] = i
    end
  end
  return winners, evals
end

return Poker
