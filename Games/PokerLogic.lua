-- Goblin Gambling Co. : Texas Hold'em rules.
-- Pure Lua 5.1. No WoW API calls, so tests can run it from the terminal.
--
-- Cards, deck, shuffle, the 7-card evaluator, and the no-limit betting
-- state machine (blinds, streets, min-raise rules, side pots, showdown).
-- Every player decision is a plain {seat, type, amount} table that can be
-- encoded to a string, so the same engine can run over addon messages later.
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

------------------------------------------------------------------------
-- Table and hand state machine
--
--   local t = Poker.NewTable({ seats = { {name="You", stack=1000, human=true}, ... },
--                              sb = 5, bb = 10, rng = math.random })
--   Poker.StartHand(t)
--   while t.street ~= "done" do
--     Poker.Act(t, t.toAct, { type = "call" })   -- fold | check | call | raise | allin
--   end
--   -- t.result has pots, payouts and shown hands; t.events is the play log.
--
-- Per-seat hand fields: hole, bet (this street), totalIn (this hand),
-- inHand, folded, allIn, hasActed, raiseRight.
------------------------------------------------------------------------
Poker.STREET_ORDER = { preflop = "flop", flop = "turn", turn = "river", river = "showdown" }
Poker.BOARD_COUNT = { flop = 3, turn = 1, river = 1 }

function Poker.NewTable(opts)
  local t = {
    seats = {}, sb = opts.sb or 5, bb = opts.bb or 10,
    button = opts.button or 1, handNo = 0,
    rng = opts.rng or math.random,
    street = "idle", events = {}, board = {},
  }
  for i, s in ipairs(opts.seats) do
    t.seats[i] = { seat = i, name = s.name, stack = s.stack or 0, human = s.human, bot = s.bot,
                   sittingOut = s.sittingOut }
  end
  return t
end

local function Emit(t, ev)
  t.events[#t.events + 1] = ev
end

local function CanAct(p)
  return p.inHand and not p.folded and not p.allIn
end
Poker.CanAct = CanAct

local function Live(p)
  return p.inHand and not p.folded
end
Poker.IsLive = Live

-- Next seat after `from` (wrapping) matching pred, or nil.
local function NextSeat(t, from, pred)
  local n = #t.seats
  for i = 1, n do
    local s = (from + i - 1) % n + 1
    if pred(t.seats[s]) then return s end
  end
  return nil
end
Poker.NextSeat = NextSeat

local function Count(t, pred)
  local c = 0
  for _, p in ipairs(t.seats) do if pred(p) then c = c + 1 end end
  return c
end

function Poker.Pot(t)
  local total = 0
  for _, p in ipairs(t.seats) do total = total + (p.totalIn or 0) end
  return total
end

-- Chips on the table right now: all stacks plus everything in the pot.
function Poker.TotalChips(t)
  local total = Poker.Pot(t)
  for _, p in ipairs(t.seats) do total = total + p.stack end
  return total
end

local function Pay(p, amount)
  amount = math.min(amount, p.stack)
  p.stack = p.stack - amount
  p.bet = p.bet + amount
  p.totalIn = p.totalIn + amount
  if p.stack == 0 then p.allIn = true end
  return amount
end

local function DrawCard(t)
  local c = t.deck[t.deckPos]
  t.deckPos = t.deckPos + 1
  return c
end

local function Eligible(p)
  return p.stack > 0 and not p.sittingOut
end

------------------------------------------------------------------------
-- Pots and showdown
------------------------------------------------------------------------

-- Splits everything put in this hand into main and side pots.
-- Returns { {amount, eligible = {seat,...}}, ... } from the main pot outward.
-- Chips a player put in that nobody matched come back as a pot only
-- they are eligible for (the uncalled bet is returned).
function Poker.BuildPots(t)
  local levels, seen = {}, {}
  for _, p in ipairs(t.seats) do
    local v = p.totalIn or 0
    if v > 0 and not seen[v] then seen[v] = true; levels[#levels + 1] = v end
  end
  table.sort(levels)

  local pots, prev = {}, 0
  for _, level in ipairs(levels) do
    local amount, eligible = 0, {}
    for _, p in ipairs(t.seats) do
      local v = p.totalIn or 0
      amount = amount + math.max(0, math.min(v, level) - prev)
      if Live(p) and v >= level then eligible[#eligible + 1] = p.seat end
    end
    local last = pots[#pots]
    if #eligible == 0 and last then
      -- Only folded players reached this level: it belongs to the pot below.
      last.amount = last.amount + amount
    else
      local same = last and #last.eligible == #eligible
      if same then
        for i, s in ipairs(eligible) do if last.eligible[i] ~= s then same = false end end
      end
      if same then
        last.amount = last.amount + amount
      else
        pots[#pots + 1] = { amount = amount, eligible = eligible }
      end
    end
    prev = level
  end

  -- A pot with no live contender (only possible if every contributor at the
  -- lowest level folded) goes to everyone still in the hand.
  for _, pot in ipairs(pots) do
    if #pot.eligible == 0 then
      for _, p in ipairs(t.seats) do if Live(p) then pot.eligible[#pot.eligible + 1] = p.seat end end
    end
  end
  return pots
end

-- Winners in payout order: the first seat left of the button gets odd chips.
local function OddChipOrder(t, seats)
  local n = #t.seats
  table.sort(seats, function(a, b)
    return (a - t.button - 1) % n < (b - t.button - 1) % n
  end)
  return seats
end

local function Settle(t, reason)
  local payouts, hands = {}, {}
  local pots = Poker.BuildPots(t)

  if reason == "showdown" then
    for _, p in ipairs(t.seats) do
      if Live(p) then
        local cards = { p.hole[1], p.hole[2] }
        for _, c in ipairs(t.board) do cards[#cards + 1] = c end
        hands[p.seat] = Poker.Evaluate(cards)
      end
    end
  end

  for _, pot in ipairs(pots) do
    local winners
    if #pot.eligible == 1 then
      winners = { pot.eligible[1] }
    else
      local best = -1
      winners = {}
      for _, s in ipairs(pot.eligible) do
        local sc = hands[s].score
        if sc > best then best, winners = sc, { s }
        elseif sc == best then winners[#winners + 1] = s end
      end
    end
    OddChipOrder(t, winners)
    local share = floor(pot.amount / #winners)
    local odd = pot.amount - share * #winners
    pot.winners, pot.shares = winners, {}
    for i, s in ipairs(winners) do
      local amt = share + (i <= odd and 1 or 0)
      pot.shares[s] = amt
      payouts[s] = (payouts[s] or 0) + amt
    end
  end

  for s, amt in pairs(payouts) do t.seats[s].stack = t.seats[s].stack + amt end
  for _, p in ipairs(t.seats) do p.bet = 0; p.totalIn = 0 end

  t.result = { reason = reason, pots = pots, payouts = payouts, hands = hands, board = t.board }
  t.street = "done"
  t.toAct = nil

  if reason == "showdown" then
    local shown = {}
    for s, h in pairs(hands) do shown[s] = { hole = t.seats[s].hole, name = h.name } end
    Emit(t, { type = "showdown", hands = shown })
  end
  for i, pot in ipairs(pots) do
    for _, s in ipairs(pot.winners) do
      Emit(t, { type = "win", seat = s, amount = pot.shares[s], pot = i,
                hand = hands[s] and hands[s].name or nil })
    end
  end
  Emit(t, { type = "handEnd", reason = reason })
end

------------------------------------------------------------------------
-- Streets
------------------------------------------------------------------------
local function ResetStreet(t)
  for _, p in ipairs(t.seats) do
    p.bet = 0
    p.hasActed = false
    p.raiseRight = true
  end
  t.currentBet = 0
  t.minRaise = t.bb
  t.raiseCount = 0
end

-- Deals the next street. Keeps dealing while fewer than two players can
-- act (everyone else all-in), finishing with the showdown.
local function NextStreet(t)
  while true do
    local nextStreet = Poker.STREET_ORDER[t.street]
    ResetStreet(t)
    if nextStreet == "showdown" then
      Settle(t, "showdown")
      return
    end
    t.street = nextStreet
    DrawCard(t) -- burn
    local dealt = {}
    for _ = 1, Poker.BOARD_COUNT[nextStreet] do
      local c = DrawCard(t)
      t.board[#t.board + 1] = c
      dealt[#dealt + 1] = c
    end
    Emit(t, { type = "street", street = nextStreet, cards = dealt })
    if Count(t, CanAct) >= 2 then
      t.toAct = NextSeat(t, t.button, CanAct)
      return
    end
  end
end

local function NeedsAction(t)
  return function(p)
    return CanAct(p) and (not p.hasActed or p.bet < t.currentBet)
  end
end

local function Advance(t)
  if Count(t, Live) == 1 then
    Settle(t, "fold")
    return
  end
  local needs = NeedsAction(t)
  local waiting = Count(t, needs)
  -- Nobody left to bet against: a lone player who already covers the bet
  -- has nothing to decide.
  if Count(t, CanAct) <= 1 then
    local s = NextSeat(t, 0, CanAct)
    if not s or t.seats[s].bet >= t.currentBet then waiting = 0 end
  end
  if waiting == 0 then
    NextStreet(t)
  else
    t.toAct = NextSeat(t, t.toAct, needs)
  end
end

------------------------------------------------------------------------
-- Starting a hand
------------------------------------------------------------------------

-- Returns true, or false + reason if fewer than two players have chips.
-- Tests may set t.nextDeck to a stacked deck before calling.
function Poker.StartHand(t)
  if Count(t, Eligible) < 2 then return false, "not enough players with chips" end
  t.handNo = t.handNo + 1
  if t.handNo > 1 or not Eligible(t.seats[t.button]) then
    t.button = NextSeat(t, t.button, Eligible)
  end

  for _, p in ipairs(t.seats) do
    p.inHand = Eligible(p)
    p.folded, p.allIn = false, false
    p.bet, p.totalIn = 0, 0
    p.hole = nil
    p.hasActed, p.raiseRight = false, true
    p.lastAction = nil
  end
  t.deck = t.nextDeck or Poker.Shuffle(Poker.NewDeck(), t.rng)
  t.nextDeck = nil
  t.deckPos = 1
  t.board = {}
  t.events = {}
  t.result = nil
  t.street = "preflop"
  t.raiseCount = 0

  Emit(t, { type = "hand", handNo = t.handNo, button = t.button })

  local inHand = function(p) return p.inHand end
  local sbSeat, bbSeat
  if Count(t, inHand) == 2 then
    sbSeat = t.button                       -- heads-up: the button posts the small blind
    bbSeat = NextSeat(t, sbSeat, inHand)
  else
    sbSeat = NextSeat(t, t.button, inHand)
    bbSeat = NextSeat(t, sbSeat, inHand)
  end
  t.sbSeat, t.bbSeat = sbSeat, bbSeat
  Emit(t, { type = "blind", seat = sbSeat, amount = Pay(t.seats[sbSeat], t.sb), blind = "small" })
  Emit(t, { type = "blind", seat = bbSeat, amount = Pay(t.seats[bbSeat], t.bb), blind = "big" })
  -- Callers owe the full big blind even if the big blind was short.
  t.currentBet = t.bb
  t.minRaise = t.bb

  -- Two cards each, one at a time, starting left of the button.
  for round = 1, 2 do
    local s = t.button
    for _ = 1, Count(t, inHand) do
      s = NextSeat(t, s, inHand)
      local p = t.seats[s]
      p.hole = p.hole or {}
      p.hole[round] = DrawCard(t)
    end
  end
  Emit(t, { type = "deal" })

  t.toAct = bbSeat
  Advance(t)
  return true
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------

-- What the player to act may do, or nil if it is not their turn.
function Poker.LegalActions(t, seat)
  if t.street == "done" or t.street == "idle" or t.toAct ~= seat then return nil end
  local p = t.seats[seat]
  if not CanAct(p) then return nil end
  local toCall = math.min(t.currentBet - p.bet, p.stack)
  local maxTo = p.bet + p.stack
  local others = 0
  for _, o in ipairs(t.seats) do
    if o ~= p and CanAct(o) then others = others + 1 end
  end
  -- Raise rights are lost after acting, and only a full raise restores them.
  local canRaise = p.raiseRight and p.stack > (t.currentBet - p.bet) and others > 0
  return {
    check = toCall == 0,
    call = toCall,
    canRaise = canRaise,
    isBet = t.currentBet == 0,
    minRaiseTo = canRaise and math.min(t.currentBet + t.minRaise, maxTo) or nil,
    maxRaiseTo = canRaise and maxTo or nil,
    currentBet = t.currentBet,
    stack = p.stack,
    bet = p.bet,
  }
end

-- action = { type = "fold"|"check"|"call"|"raise"|"allin", amount = raise-to total }
-- Returns true, or false + reason (state unchanged).
function Poker.Act(t, seat, action)
  local la = Poker.LegalActions(t, seat)
  if not la then return false, "not your turn" end
  local p = t.seats[seat]
  local kind = action.type
  local amount = tonumber(action.amount)

  if kind == "allin" then
    if la.canRaise then
      kind, amount = "raise", la.maxRaiseTo
    elseif la.call > 0 then
      kind = "call"
    else
      kind = "check"
    end
  end

  local ev = { type = "action", seat = seat }
  if kind == "fold" then
    p.folded = true
    ev.action = "fold"
  elseif kind == "check" then
    if not la.check then return false, "cannot check, there is a bet" end
    ev.action = "check"
  elseif kind == "call" then
    if la.call <= 0 then return false, "nothing to call" end
    ev.action, ev.amount = "call", Pay(p, la.call)
  elseif kind == "raise" then
    if not la.canRaise then return false, "raising is not allowed" end
    if not amount then return false, "raise needs an amount" end
    amount = floor(amount)
    if amount > la.maxRaiseTo then return false, "raise is more than your stack" end
    if amount < la.minRaiseTo then return false, "raise is below the minimum" end
    local increment = amount - t.currentBet
    Pay(p, amount - p.bet)
    if increment >= t.minRaise then
      -- Full raise: reopens betting for everyone else.
      t.minRaise = increment
      for _, o in ipairs(t.seats) do if o ~= p then o.raiseRight = true end end
    end
    t.currentBet = amount
    t.raiseCount = t.raiseCount + 1
    for _, o in ipairs(t.seats) do if o ~= p then o.hasActed = false end end
    ev.action, ev.amount = la.isBet and "bet" or "raise", amount
  else
    return false, "unknown action " .. tostring(kind)
  end

  p.hasActed = true
  p.raiseRight = false
  p.lastAction = ev.action
  ev.allIn = p.allIn
  Emit(t, ev)
  Advance(t)
  return true
end

------------------------------------------------------------------------
-- Serialization for (future) addon messages: "seat:type:amount"
------------------------------------------------------------------------
local VALID_ACTIONS = { fold = true, check = true, call = true, raise = true, allin = true }

function Poker.EncodeAction(seat, action)
  return ("%d:%s:%d"):format(seat, action.type, floor(tonumber(action.amount) or 0))
end

function Poker.DecodeAction(str)
  local seat, kind, amount = tostring(str):match("^(%d+):(%a+):(%d+)$")
  if not seat or not VALID_ACTIONS[kind] then return nil end
  return tonumber(seat), { type = kind, amount = tonumber(amount) }
end

------------------------------------------------------------------------
-- What one seat is allowed to know (other players' cards stay hidden).
------------------------------------------------------------------------
function Poker.ViewFor(t, seat)
  local p = t.seats[seat]
  local opponents = 0
  for _, o in ipairs(t.seats) do
    if o ~= p and Live(o) then opponents = opponents + 1 end
  end
  local board = {}
  for i, c in ipairs(t.board) do board[i] = c end
  local la = Poker.LegalActions(t, seat)
  return {
    seat = seat,
    hole = p.hole and { p.hole[1], p.hole[2] } or nil,
    board = board,
    street = t.street,
    pot = Poker.Pot(t),
    stack = p.stack,
    bet = p.bet,
    bb = t.bb,
    opponents = opponents,
    raiseCount = t.raiseCount,
    legal = la,
    toCall = la and la.call or 0,
  }
end

return Poker
