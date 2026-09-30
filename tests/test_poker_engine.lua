-- lua tests/test_poker_engine.lua   (run from the GoblinGambling/ folder)
-- Rules of the betting state machine, using stacked decks.
local H = dofile("tests/helpers.lua")
local GG = H.load("Games/PokerLogic.lua")
local P = GG.PokerLogic

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function cards(str) return P.ParseCards(str) end

-- Builds a table and a stacked deck so seat s gets holes[s] and the board
-- comes out as given. Deal order: one card each starting left of the
-- button, twice; then burn/flop x3/burn/turn/burn/river.
local function rigged(stacks, holes, board, opts)
  opts = opts or {}
  local seats = {}
  for i, st in ipairs(stacks) do seats[i] = { name = "P" .. i, stack = st } end
  local t = P.NewTable({ seats = seats, sb = opts.sb or 5, bb = opts.bb or 10, button = opts.button or 1,
                         rng = H.rng(1) })
  local order, n = {}, #stacks
  for i = 1, n do
    local s = (t.button + i - 1) % n + 1
    if stacks[s] > 0 then order[#order + 1] = s end
  end
  local deck, used = {}, {}
  local function put(c) deck[#deck + 1] = c; used[c] = true end
  local h = {}
  for s, str in pairs(holes) do h[s] = cards(str) end
  for round = 1, 2 do for _, s in ipairs(order) do put(h[s][round]) end end
  local b = board and cards(board) or {}
  local spare = {}
  for c = 1, 52 do
    local inB = false
    for _, x in ipairs(b) do if x == c then inB = true end end
    if not used[c] and not inB then spare[#spare + 1] = c end
  end
  local si = 0
  local function burn() si = si + 1; put(spare[si]) end
  if #b == 5 then
    burn(); put(b[1]); put(b[2]); put(b[3]); burn(); put(b[4]); burn(); put(b[5])
  end
  for c = 1, 52 do if not used[c] then put(c) end end
  t.nextDeck = deck
  return t
end

local total
local function act(t, seat, kind, amount)
  local ok, err = P.Act(t, seat, { type = kind, amount = amount })
  if not ok then error(("seat %d %s %s failed: %s"):format(seat, kind, tostring(amount), tostring(err)), 2) end
  H.eq(P.TotalChips(t), total, "chips conserved after " .. kind)
end
local function start(t)
  total = P.TotalChips(t)
  assert(P.StartHand(t))
end

------------------------------------------------------------------------
-- Blinds and order, 3 players (button 1: SB 2, BB 3, UTG 1)
------------------------------------------------------------------------
local t = rigged({ 1000, 1000, 1000 }, { "As Ad", "Kc Kd", "2c 7h" }, "3s 4s 9d Jc Qh")
start(t)
H.eq(t.sbSeat, 2, "sb seat")
H.eq(t.bbSeat, 3, "bb seat")
H.eq(t.seats[2].stack, 995, "sb posted")
H.eq(t.seats[3].stack, 990, "bb posted")
H.eq(t.toAct, 1, "UTG acts first preflop")
H.eq(P.LegalActions(t, 2), nil, "not seat 2's turn")
H.eq(P.LegalActions(t, 1).call, 10, "UTG owes the big blind")

-- Everyone calls: big blind gets the option
act(t, 1, "call")
act(t, 2, "call")
H.eq(t.toAct, 3, "big blind option")
local la = P.LegalActions(t, 3)
H.eq(la.check, true, "bb can check")
H.eq(la.canRaise, true, "bb can raise")
act(t, 3, "check")
H.eq(t.street, "flop", "flop dealt")
H.eq(#t.board, 3, "three board cards")
H.eq(t.toAct, 2, "postflop starts left of the button")
act(t, 2, "check"); act(t, 3, "check"); act(t, 1, "check")
H.eq(t.street, "turn", "turn")
act(t, 2, "check"); act(t, 3, "check"); act(t, 1, "check")
act(t, 2, "check"); act(t, 3, "check"); act(t, 1, "check")
H.eq(t.street, "done", "showdown finished")
H.eq(t.result.reason, "showdown", "went to showdown")
H.eq(t.seats[1].stack, 1020, "aces win the 30 pot")
H.eq(t.result.hands[1].name, "Pair of Aces", "hand named")

------------------------------------------------------------------------
-- Heads-up: button posts the small blind and acts first preflop, last after
------------------------------------------------------------------------
t = rigged({ 500, 500 }, { "As Ad", "Kc Kd" }, "3s 4s 9d Jc Qh")
start(t)
H.eq(t.sbSeat, 1, "heads-up button is the small blind")
H.eq(t.bbSeat, 2, "other seat is the big blind")
H.eq(t.toAct, 1, "button acts first preflop")
act(t, 1, "call"); act(t, 2, "check")
H.eq(t.toAct, 2, "big blind acts first postflop")

------------------------------------------------------------------------
-- Everyone folds to the big blind
------------------------------------------------------------------------
t = rigged({ 1000, 1000, 1000 }, { "As Ad", "Kc Kd", "2c 7h" })
start(t)
act(t, 1, "fold")
act(t, 2, "fold")
H.eq(t.street, "done", "hand over")
H.eq(t.result.reason, "fold", "won by folds")
H.eq(t.seats[3].stack, 1005, "bb wins the small blind")
H.eq(t.seats[2].stack, 995, "sb lost the small blind")

------------------------------------------------------------------------
-- Minimum raises
------------------------------------------------------------------------
t = rigged({ 1000, 1000, 1000 }, { "As Ad", "Kc Kd", "2c 7h" })
start(t)
H.eq(P.LegalActions(t, 1).minRaiseTo, 20, "min raise preflop is to 2 big blinds")
local ok, err = P.Act(t, 1, { type = "raise", amount = 15 })
H.eq(ok, false, "raise below minimum rejected")
H.ok(err:find("minimum"), "reason given")
ok = P.Act(t, 1, { type = "raise", amount = 5000 })
H.eq(ok, false, "raise above stack rejected")
ok, err = P.Act(t, 2, { type = "call" })
H.eq(ok, false, "acting out of turn rejected")
ok = P.Act(t, 1, { type = "check" })
H.eq(ok, false, "check facing a bet rejected")
ok = P.Act(t, 1, { type = "dance" })
H.eq(ok, false, "unknown action rejected")
H.eq(P.TotalChips(t), total, "rejected actions change nothing")
act(t, 1, "raise", 40)          -- raise by 30
H.eq(P.LegalActions(t, 2).minRaiseTo, 70, "next raise must be at least another 30")
ok = P.Act(t, 2, { type = "raise", amount = 60 })
H.eq(ok, false, "under-raise rejected")
act(t, 2, "raise", 70)
act(t, 3, "fold")
act(t, 1, "call")
H.eq(t.street, "flop", "betting closed")
H.eq(P.LegalActions(t, 2).minRaiseTo, 10, "postflop minimum bet is the big blind")
H.eq(P.LegalActions(t, 2).isBet, true, "first chips in are a bet")

------------------------------------------------------------------------
-- A short all-in does not reopen raising for players who already acted
------------------------------------------------------------------------
t = rigged({ 1000, 130, 1000 }, { "As Ad", "Kc Kd", "Qc Qd" }, "3s 4s 9d Jc 2h", { button = 3 })
-- button 3: SB 1, BB 2, UTG 3
start(t)
act(t, 3, "call"); act(t, 1, "call"); act(t, 2, "check")
H.eq(t.street, "flop", "flop")
H.eq(t.toAct, 1, "seat 1 first on the flop")
act(t, 1, "raise", 100)                 -- bet 100
act(t, 2, "allin")                      -- 120 total: only 20 more, a short raise
H.eq(t.seats[2].allIn, true, "seat 2 all-in")
H.eq(t.currentBet, 120, "bet to call is now 120")
la = P.LegalActions(t, 3)
H.eq(la.canRaise, true, "seat 3 has not acted yet, may still raise")
act(t, 3, "call")
la = P.LegalActions(t, 1)
H.eq(la.call, 20, "seat 1 owes the extra 20")
H.eq(la.canRaise, false, "short all-in did not reopen raising for seat 1")
act(t, 1, "call")
H.eq(t.street, "turn", "action closed after the call")

------------------------------------------------------------------------
-- Side pots: three all-ins of different sizes
------------------------------------------------------------------------
t = rigged({ 50, 200, 300 }, { "As Ad", "Kc Kd", "2c 7h" }, "3s 4s 9d Jc Qh", { button = 3 })
-- button 3: SB 1 (50 stack), BB 2, UTG 3
start(t)
act(t, 3, "allin")    -- 300
act(t, 1, "allin")    -- 50
act(t, 2, "allin")    -- 200
H.eq(t.street, "done", "all-in runs the board out")
H.eq(#t.board, 5, "full board dealt")
local pots = t.result.pots
H.eq(#pots, 3, "main pot, side pot, and uncalled chips")
H.eq(pots[1].amount, 150, "main pot = 50 x 3")
H.eq(pots[2].amount, 300, "side pot = 150 x 2")
H.eq(pots[3].amount, 100, "seat 3's uncalled 100")
H.eq(t.seats[1].stack, 150, "aces win the main pot")
H.eq(t.seats[2].stack, 300, "kings win the side pot")
H.eq(t.seats[3].stack, 100, "uncalled chips returned")
local sidePotWinEvent = false
for _, ev in ipairs(t.events) do
  if ev.type == "win" and ev.seat == 2 and ev.pot == 2 then sidePotWinEvent = true end
end
H.ok(sidePotWinEvent, "win event for the side pot")

------------------------------------------------------------------------
-- A folded player's chips stay in the pot they reached
------------------------------------------------------------------------
t = rigged({ 1000, 1000, 1000 }, { "2c 7h", "Kc Kd", "As Ad" }, "3s 4s 9d Jc Qh")
start(t)
act(t, 1, "raise", 100)
act(t, 2, "call")
act(t, 3, "call")
act(t, 2, "raise", 500)   -- flop
act(t, 3, "call")
act(t, 1, "fold")
act(t, 2, "check"); act(t, 3, "check")
act(t, 2, "check"); act(t, 3, "check")
H.eq(t.seats[3].stack, 1000 - 600 + 1300, "aces take everything, including the folder's 100")
H.eq(t.seats[1].stack, 900, "folder lost their 100")


------------------------------------------------------------------------
-- Split pot with an odd chip: it goes to the first winner left of the button
------------------------------------------------------------------------
-- Board is a K-high straight that both live players play. Seat 2 posts the
-- small blind and folds, so the pot is 5 + 10 + 10 = 25.
t = rigged({ 1000, 1000, 1000 }, { "2c 3d", "Ac 4h", "2d 3c" }, "Kh Qh Jh Ts 9c")
start(t)
act(t, 1, "call")
act(t, 2, "fold")
act(t, 3, "check")
for _ = 1, 3 do act(t, 3, "check"); act(t, 1, "check") end
H.eq(t.result.reason, "showdown", "split went to showdown")
H.eq(#t.result.pots[1].winners, 2, "two winners")
H.eq(t.seats[3].stack, 1000 - 10 + 13, "seat 3 (first left of button) gets the odd chip")
H.eq(t.seats[1].stack, 1000 - 10 + 12, "seat 1 gets the rest")

------------------------------------------------------------------------
-- Uncalled chips come back even when the bigger stack loses
------------------------------------------------------------------------
t = rigged({ 500, 100 }, { "2c 7h", "As Ad" }, "3s 4s 9d Jc Qh")
start(t)
act(t, 1, "allin")   -- heads-up: seat 1 is the button / small blind
act(t, 2, "call")    -- seat 2 can only put in 100
H.eq(t.street, "done", "all-in call runs it out")
H.eq(t.seats[2].stack, 200, "short stack doubles up")
H.eq(t.seats[1].stack, 400, "big stack gets its uncalled 400 back")

------------------------------------------------------------------------
-- A short big blind: callers still owe the full big blind
------------------------------------------------------------------------
t = rigged({ 1000, 1000, 4 }, { "2c 7h", "Kc Kd", "As Ad" }, "3s 4s 9d Jc Qh")
start(t)
H.eq(t.seats[3].allIn, true, "big blind all-in for 4")
H.eq(t.currentBet, 10, "bet to call is still the full big blind")
act(t, 1, "call")
act(t, 2, "call")
-- Only seats 1 and 2 can still act; nobody owes anything, so betting goes on.
H.eq(t.street, "flop", "flop comes out")
for _ = 1, 3 do act(t, 2, "check"); act(t, 1, "check") end
H.eq(t.seats[3].stack, 12, "aces win the 12-chip main pot")
H.eq(t.seats[2].stack, 1000 - 10 + 12, "kings win the 12-chip side pot (6 + 6 from seats 1 and 2)")

------------------------------------------------------------------------
-- Busted players are skipped; the button moves; game ends at one player
------------------------------------------------------------------------
t = P.NewTable({ seats = { { name = "A", stack = 100 }, { name = "B", stack = 0 }, { name = "C", stack = 100 } },
                 rng = H.rng(3), button = 1 })
total = P.TotalChips(t)
assert(P.StartHand(t))
H.eq(t.seats[2].inHand, false, "busted seat not dealt in")
H.eq(t.seats[2].hole, nil, "busted seat has no cards")
H.eq(t.sbSeat, 1, "heads-up with seat 2 empty: button is SB")
act(t, 1, "fold")
assert(P.StartHand(t))
H.eq(t.button, 3, "button skips the empty seat")
t.seats[1].stack, t.seats[3].stack = 0, 0
t.street = "idle"
local started, why = P.StartHand(t)
H.eq(started, false, "cannot start with fewer than two players")
H.ok(why, "reason given")

------------------------------------------------------------------------
-- Serialization and hidden information
------------------------------------------------------------------------
local enc = P.EncodeAction(4, { type = "raise", amount = 250 })
H.eq(enc, "4:raise:250", "encode")
local seat, action = P.DecodeAction(enc)
H.eq(seat, 4, "decode seat")
H.eq(action.type, "raise", "decode type")
H.eq(action.amount, 250, "decode amount")
H.eq(P.DecodeAction("4:explode:1"), nil, "bad action rejected")
H.eq(P.DecodeAction("garbage"), nil, "garbage rejected")
H.eq(select(2, P.DecodeAction(P.EncodeAction(1, { type = "fold" }))).type, "fold", "fold round trip")

t = rigged({ 1000, 1000, 1000 }, { "As Ad", "Kc Kd", "2c 7h" })
start(t)
local view = P.ViewFor(t, 1)
H.eq(view.hole[1], P.ParseCard("As"), "sees own cards")
H.eq(view.opponents, 2, "counts opponents")
H.eq(view.pot, 15, "sees the pot")
H.eq(view.toCall, 10, "knows the price")
H.eq(view.seats, nil, "no access to other seats")
H.eq(P.ViewFor(t, 2).legal, nil, "no legal actions when not your turn")

-- Event log covers the whole hand
act(t, 1, "fold"); act(t, 2, "fold")
local kinds = {}
for _, ev in ipairs(t.events) do kinds[ev.type] = (kinds[ev.type] or 0) + 1 end
H.eq(kinds.hand, 1, "hand event")
H.eq(kinds.blind, 2, "two blind events")
H.eq(kinds.deal, 1, "deal event")
H.eq(kinds.action, 2, "two action events")
H.eq(kinds.win, 1, "win event")
H.eq(kinds.handEnd, 1, "hand end event")

print(string.format("test_poker_engine: %d checks passed", H.passed))
