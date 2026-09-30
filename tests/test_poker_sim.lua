-- lua tests/test_poker_sim.lua   (run from the GoblinGambling/ folder)
-- Headless Hold'em: bots and random fuzzers play thousands of hands while
-- we check that chips are never created or destroyed.
local H = dofile("tests/helpers.lua")
local GG = H.load("Games/PokerLogic.lua")
H.load("Games/PokerBots.lua")
local P, B = GG.PokerLogic, GG.PokerBots

local HANDS = tonumber(os.getenv and os.getenv("GG_SIM_HANDS") or nil) or 10000
local START = 1000

------------------------------------------------------------------------
-- Bot sanity
------------------------------------------------------------------------
H.eq(B.Chen(P.ParseCards("As Ad")), 20, "Chen AA")
H.eq(B.Chen(P.ParseCards("As Ks")), 12, "Chen AKs")
H.eq(B.Chen(P.ParseCards("7c 2d")), -1, "Chen 72o")
H.eq(B.Chen(P.ParseCards("5h 5d")), 5, "Chen 55")

local erng = H.rng(8)
local aa = B.Equity(P.ParseCards("As Ad"), {}, 1, 4000, erng)
local sevenTwo = B.Equity(P.ParseCards("7c 2d"), {}, 1, 4000, erng)
local aaFour = B.Equity(P.ParseCards("As Ad"), {}, 4, 3000, erng)
print(string.format("Equity: AA vs 1 = %.3f (true 0.852), 72o vs 1 = %.3f (true 0.346), AA vs 4 = %.3f (true 0.557)",
  aa, sevenTwo, aaFour))
H.ok(math.abs(aa - 0.852) < 0.03, "AA equity")
H.ok(math.abs(sevenTwo - 0.346) < 0.03, "72o equity")
H.ok(math.abs(aaFour - 0.557) < 0.04, "AA vs 4 equity")
local nuts = B.Equity(P.ParseCards("Ah Kh"), P.ParseCards("Qh Jh Th"), 3, 200, erng)
H.eq(nuts, 1, "royal flush never loses")

------------------------------------------------------------------------
-- Shared runner. choose(t, rng) returns the action for t.toAct.
------------------------------------------------------------------------
local function run(label, seats, choose, rng, hands)
  local t = P.NewTable({ seats = seats, sb = 5, bb = 10, rng = rng })
  local total = P.TotalChips(t)
  local stats = { hands = 0, showdowns = 0, sidePots = 0, allIns = 0, splits = 0, rebuys = 0,
                  actions = 0, maxActions = 0, streets = {} }
  local vpip, dealt = {}, {}

  for _ = 1, hands do
    -- Rebuy anyone who busted so the game keeps going (adds to the total).
    for _, p in ipairs(t.seats) do
      if p.stack == 0 then
        p.stack = START
        total = total + START
        stats.rebuys = stats.rebuys + 1
      end
    end
    assert(P.StartHand(t))
    H.eq(P.TotalChips(t), total, label .. ": chips after blinds")
    local actions = 0
    local volunteered = {}
    while t.street ~= "done" do
      local seat = t.toAct
      assert(seat, label .. ": nobody to act but hand not done")
      local a = choose(t, rng)
      local ok, err = P.Act(t, seat, a)
      if not ok then
        error(("%s: illegal %s %s by seat %d on %s: %s"):format(label, a.type, tostring(a.amount), seat,
          t.street, err))
      end
      if t.street == "preflop" or (t.result and #t.board == 0) then
        if a.type == "call" or a.type == "raise" or a.type == "allin" then volunteered[seat] = true end
      end
      actions = actions + 1
      if P.TotalChips(t) ~= total then
        error(("%s: chips changed after %s by seat %d: %d ~= %d"):format(label, a.type, seat,
          P.TotalChips(t), total))
      end
      H.passed = H.passed + 1
      assert(actions < 400, label .. ": hand never ended")
    end

    -- End of hand: every chip is back in a stack.
    local sum = 0
    for _, p in ipairs(t.seats) do
      sum = sum + p.stack
      H.ok(p.stack >= 0, "no negative stacks")
    end
    H.eq(sum, total, label .. ": stacks add up after the hand")
    H.eq(P.Pot(t), 0, "pot emptied")

    stats.hands = stats.hands + 1
    stats.actions = stats.actions + actions
    if actions > stats.maxActions then stats.maxActions = actions end
    if t.result.reason == "showdown" then stats.showdowns = stats.showdowns + 1 end
    -- A real side pot is a later pot two or more players fought over
    -- (not just an uncalled bet coming back).
    for i = 2, #t.result.pots do
      if #t.result.pots[i].eligible > 1 then stats.sidePots = stats.sidePots + 1 break end
    end
    for _, pot in ipairs(t.result.pots) do
      if #pot.winners > 1 then stats.splits = stats.splits + 1 break end
    end
    for _, ev in ipairs(t.events) do
      if ev.type == "action" and ev.allIn then stats.allIns = stats.allIns + 1 break end
    end
    for _, p in ipairs(t.seats) do
      if p.inHand then
        dealt[p.seat] = (dealt[p.seat] or 0) + 1
        if volunteered[p.seat] then vpip[p.seat] = (vpip[p.seat] or 0) + 1 end
      end
    end
  end

  print(string.format(
    "%s: %d hands, %d showdowns, %d with side pots, %d split pots, %d with all-ins, %d rebuys, "
      .. "avg %.1f actions/hand (max %d)",
    label, stats.hands, stats.showdowns, stats.sidePots, stats.splits, stats.allIns, stats.rebuys,
    stats.actions / stats.hands, stats.maxActions))
  for i, p in ipairs(t.seats) do
    stats.vpip = stats.vpip or {}
    stats.vpip[p.name] = (vpip[i] or 0) / math.max(1, dealt[i] or 0)
  end
  return stats, t
end

------------------------------------------------------------------------
-- 1. Fuzz: random legal actions with deliberately uneven stacks
------------------------------------------------------------------------
local function randomAction(t, rng)
  local la = P.LegalActions(t, t.toAct)
  local r = rng(100)
  if la.canRaise and r <= 15 then return { type = "allin" } end
  if la.canRaise and r <= 40 then
    local span = la.maxRaiseTo - la.minRaiseTo
    return { type = "raise", amount = la.minRaiseTo + (span > 0 and rng(span + 1) - 1 or 0) }
  end
  if r <= 55 then return { type = "fold" } end
  if la.check then return { type = "check" } end
  return { type = "call" }
end

local fuzzSeats = {}
for i, st in ipairs({ 1000, 35, 400, 12, 2500, 180 }) do fuzzSeats[i] = { name = "Fuzz" .. i, stack = st } end
local fuzz = run("Fuzz", fuzzSeats, randomAction, H.rng(99), HANDS)
H.ok(fuzz.sidePots > 100, "fuzz produced plenty of side pots")
H.ok(fuzz.splits > 10, "fuzz produced split pots")

------------------------------------------------------------------------
-- 2. The real bots, 10,000 hands. Fewer rollouts than in game, for speed;
--    it is chip conservation we are testing here, not poker skill.
------------------------------------------------------------------------
local botSeats = {}
for i, bot in ipairs(B.CAST) do botSeats[i] = { name = bot.name, stack = START, bot = bot } end
botSeats[#botSeats + 1] = { name = "Grubnik's Cousin", stack = START, bot = B.BY_NAME.Grubnik }
local botRng = H.rng(2026)
local function botAction(t, rng)
  local _, a = B.Play(t, rng, { rollouts = 12 })
  return a
end
local started = os.clock()
local botStats = run("Bots", botSeats, botAction, botRng, HANDS)
print(string.format("   bot run took %.1fs", os.clock() - started))
local names = {}
for _, b in ipairs(B.CAST) do names[#names + 1] = ("%s %.0f%%"):format(b.name, botStats.vpip[b.name] * 100) end
print("   voluntarily put chips in preflop: " .. table.concat(names, ", "))

-- Personalities show up in how often each bot plays a hand
H.ok(botStats.vpip["Moo-Tan"] > botStats.vpip.Thorgrim + 0.2, "Moo-Tan plays far more hands than Thorgrim")
H.ok(botStats.vpip.Shadowstep > botStats.vpip.Thorgrim, "Shadowstep looser than Thorgrim")
H.ok(botStats.showdowns > 0 and botStats.sidePots > 0, "bots reach showdowns and side pots")

-- Taunts never error and respect chance
local trng = H.rng(5)
local said = 0
for _ = 1, 1000 do if B.Taunt(B.BY_NAME.Grubnik, "win", trng) then said = said + 1 end end
H.ok(said > 250 and said < 450, "taunts about 35% of the time (" .. said .. ")")
H.eq(B.Taunt(B.BY_NAME.Thorgrim, "call", trng, 1), nil, "no line for an event without taunts")
for _, bot in ipairs(B.CAST) do H.ok(B.TAUNTS[bot.name], bot.name .. " has taunts") end

print(string.format("test_poker_sim: %d checks passed", H.passed))
