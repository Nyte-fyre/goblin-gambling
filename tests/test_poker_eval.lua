-- lua tests/test_poker_eval.lua   (run from the GoblinGambling/ folder)
local H = dofile("tests/helpers.lua")
local GG = H.load("Games/PokerLogic.lua")
local P = GG.PokerLogic
local C = P.CATEGORY

local function ev(str) return P.Evaluate(P.ParseCards(str)) end

------------------------------------------------------------------------
-- Cards and deck
------------------------------------------------------------------------
H.eq(P.CardString(P.ParseCard("As")), "As", "round trip As")
H.eq(P.CardString(P.ParseCard("10h")), "Th", "10h parses as Th")
H.eq(P.CardString(P.ParseCard("td")), "Td", "lowercase rank")
H.eq(P.ParseCard("1x"), nil, "junk card")
H.eq(P.Rank(P.ParseCard("2c")), 2, "rank 2")
H.eq(P.Rank(P.ParseCard("Ac")), 14, "rank A")
H.eq(P.Suit(P.ParseCard("Qs")), 4, "suit spades")

local deck = P.Shuffle(P.NewDeck(), H.rng(7))
local seen = {}
for i = 1, #deck do seen[deck[i]] = true end
H.eq(#deck, 52, "deck size")
for c = 1, 52 do H.ok(seen[c], "missing card " .. c) end
local d2 = P.Shuffle(P.NewDeck(), H.rng(7))
for i = 1, 52 do H.eq(deck[i], d2[i], "shuffle deterministic") end

-- Shuffle uniformity: each card lands in position 1 about 1/52 of the time.
local firstCount = {}
local rng = H.rng(99)
local N = 52000
for _ = 1, N do
  local d = P.Shuffle(P.NewDeck(), rng)
  firstCount[d[1]] = (firstCount[d[1]] or 0) + 1
end
for c = 1, 52 do
  local n = firstCount[c] or 0
  H.ok(n > 800 and n < 1200, "shuffle bias on card " .. c .. ": " .. n .. " / 1000 expected")
end

------------------------------------------------------------------------
-- Known answers: one or more per category
------------------------------------------------------------------------
local known = {
  { "As Ks Qs Js Ts 2d 3c", C.STRAIGHT_FLUSH, "Royal Flush" },
  { "9h 8h 7h 6h 5h Ah Kd", C.STRAIGHT_FLUSH, "Straight Flush, Nine high" },
  { "Ad 2d 3d 4d 5d Kc Qh", C.STRAIGHT_FLUSH, "Straight Flush, Five high" },  -- steel wheel
  { "7c 7d 7h 7s Ks 2d 3c", C.QUADS,          "Four Sevens" },
  { "6c 6d 6h 6s Ks Kd Kc", C.QUADS,          "Four Sixes" },
  { "Jc Jd Jh 4s 4d 2c 9h", C.FULL_HOUSE,     "Full House, Jacks over Fours" },
  { "Jc Jd Jh 4s 4d 4c 9h", C.FULL_HOUSE,     "Full House, Jacks over Fours" }, -- two trips
  { "3c 3d 3h Qs Qd 9c 9h", C.FULL_HOUSE,     "Full House, Threes over Queens" },
  { "Ah 9h 7h 4h 2h Kh 3h", C.FLUSH,          "Flush, Ace high" },   -- 7 of a suit
  { "Ah 9h 7h 4h 2h Kd Qc", C.FLUSH,          "Flush, Ace high" },
  { "Ac Kd Qh Js Tc 3d 2h", C.STRAIGHT,       "Straight, Ace high" },
  { "Ts 9d 8c 7h 6s 2d 2c", C.STRAIGHT,       "Straight, Ten high" },
  { "9c 8d 7h 6s 5c 4d 3h", C.STRAIGHT,       "Straight, Nine high" },  -- 7-card run
  { "Ac 2d 3h 4s 5c Kd 9h", C.STRAIGHT,       "Straight, Five high" },  -- wheel
  { "Qc Qd Qh 8s 5c 3d 2h", C.TRIPS,          "Three Queens" },
  { "Kc Kd 8h 8s 5c 5d Ah", C.TWO_PAIR,       "Two Pair, Kings and Eights" }, -- three pairs
  { "Kc Kd 8h 8s 5c 3d 2h", C.TWO_PAIR,       "Two Pair, Kings and Eights" },
  { "Tc Td 8h 6s 5c 3d 2h", C.PAIR,           "Pair of Tens" },
  { "Ac Jd 8h 6s 5c 3d 2h", C.HIGH_CARD,      "Ace high" },
}
for _, k in ipairs(known) do
  local e = ev(k[1])
  H.eq(e.category, k[2], k[1] .. " category")
  H.eq(e.name, k[3], k[1] .. " name")
end

-- The list above is sorted best first, so each hand beats or ties the next
for i = 1, #known - 1 do
  local a, b = ev(known[i][1]), ev(known[i + 1][1])
  H.ok(a.score >= b.score, known[i][1] .. " should beat or tie " .. known[i + 1][1])
end

-- Tiebreak details
H.eq(ev("Kc Kd 8h 8s 5c 5d Ah").ranks[3], 14, "three pairs: kicker is the ace, not the 5s")
H.eq(ev("Kc Kd 8h 8s 5c 5d 4h").ranks[3], 5, "three pairs: third pair can be the kicker")
H.eq(ev("7c 7d 7h 7s Ks 2d 3c").ranks[2], 13, "quads kicker")
H.eq(ev("3c 3d 3h Qs Qd 9c 9h").ranks[2], 12, "full house takes the higher pair")

------------------------------------------------------------------------
-- Head-to-head, including split pots
------------------------------------------------------------------------
local function winners(board, ...)
  local hands = {}
  for i, hole in ipairs({ ... }) do hands[i] = P.ParseCards(hole .. " " .. board) end
  local w = P.Winners(hands)
  return table.concat(w, ",")
end

H.eq(winners("Kh 9c 5d 3s 2h", "Ks 7d", "Kd Qc"), "2", "same pair, kicker Q beats 7")
H.eq(winners("Kh Kc 9d 9s 4h", "As 2d", "Qs Jd"), "1", "board two pair, ace kicker plays")
H.eq(winners("Kh Kc 9d 9s Ah", "2s 3d", "4s 5d"), "1,2", "board two pair + ace, both play the board: split")
H.eq(winners("Ah Kh Qd Jc Tc", "2s 3d", "9s 9d"), "1,2", "board straight: split")
H.eq(winners("5h 6d 7c 8s Kd", "9h 2c", "4h Ac"), "1", "9-high straight beats 8-high")
H.eq(winners("5h 6d 7c 8s Kd", "9h 2c", "9s 3c"), "1,2", "same straight split")
H.eq(winners("Ah 2h 7h 9h Kc", "3h 4d", "Qh 5d"), "2", "higher flush card wins")
H.eq(winners("Ah Qh 7h 9h 2h", "3c 4d", "5c 6d"), "1,2", "board flush: split")
H.eq(winners("Ah Qh 7h 9h 2h", "Kh 4d", "5c 6d"), "1", "king flush card plays")
H.eq(winners("Jc Jd Jh 4s 4d", "Ac Kc", "2c 3c"), "1,2", "board full house: split")
H.eq(winners("Jc Jd 4h 4s 9d", "Jh 2c", "4c Ac"), "1", "jacks full beats fours full")
H.eq(winners("Ac 2d 3h 4s 9c", "5c Kd", "6d 5h"), "2", "6-high straight beats the wheel")
H.eq(winners("Tc 8d 6h 4s 2c", "Ad Kd", "Ah Kh", "Ac Ks"), "1,2,3", "three-way split")
H.eq(winners("Qc Qd 7h 7s 3c", "Qh 2d", "7c 7d"), "2", "quads beat full house")
H.eq(winners("9s Ts Js 2d 3c", "Qs Ks", "As Kd"), "1", "straight flush beats straight")

------------------------------------------------------------------------
-- Cross-check against an independent brute-force evaluator:
-- best of all 21 five-card subsets, scored the slow obvious way.
------------------------------------------------------------------------
local function score5(cards)
  local ranks, suits = {}, {}
  for i = 1, 5 do ranks[i] = P.Rank(cards[i]); suits[i] = P.Suit(cards[i]) end
  table.sort(ranks, function(a, b) return a > b end)
  local flush = suits[1] == suits[2] and suits[2] == suits[3] and suits[3] == suits[4] and suits[4] == suits[5]
  local distinct = true
  for i = 1, 4 do if ranks[i] == ranks[i + 1] then distinct = false end end
  local straight, high = false, nil
  if distinct and ranks[1] - ranks[5] == 4 then straight, high = true, ranks[1] end
  if distinct and ranks[1] == 14 and ranks[2] == 5 then straight, high = true, 5 end
  -- group by (count desc, rank desc)
  local cnt = {}
  for _, r in ipairs(ranks) do cnt[r] = (cnt[r] or 0) + 1 end
  local groups = {}
  for r, n in pairs(cnt) do groups[#groups + 1] = { r, n } end
  table.sort(groups, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] > b[1] end)
  local order = {}
  for _, g in ipairs(groups) do order[#order + 1] = g[1] end
  local cat
  if straight and flush then cat, order = 9, { high }
  elseif groups[1][2] == 4 then cat = 8
  elseif groups[1][2] == 3 and groups[2][2] == 2 then cat = 7
  elseif flush then cat = 6
  elseif straight then cat, order = 5, { high }
  elseif groups[1][2] == 3 then cat = 4
  elseif groups[1][2] == 2 and groups[2][2] == 2 then cat = 3
  elseif groups[1][2] == 2 then cat = 2
  else cat = 1 end
  local s = cat
  for i = 1, 5 do s = s * 15 + (order[i] or 0) end
  return s
end

local function brute7(cards)
  local best = -1
  for a = 1, 7 do for b = a + 1, 7 do
    local five = {}
    for i = 1, 7 do if i ~= a and i ~= b then five[#five + 1] = cards[i] end end
    local s = score5(five)
    if s > best then best = s end
  end end
  return best
end

local catSeen = {}
local rng2 = H.rng(2026)
local CROSS = 30000
for _ = 1, CROSS do
  local d = P.Shuffle(P.NewDeck(), rng2)
  local seven = { d[1], d[2], d[3], d[4], d[5], d[6], d[7] }
  local e = P.Evaluate(seven)
  local b = brute7(seven)
  if e.score ~= b then
    local s = {}
    for i = 1, 7 do s[i] = P.CardString(seven[i]) end
    error("evaluator mismatch on " .. table.concat(s, " ") .. ": " .. e.name)
  end
  catSeen[e.category] = (catSeen[e.category] or 0) + 1
end
H.passed = H.passed + CROSS
local parts = {}
for cat = 1, 9 do parts[#parts + 1] = P.CATEGORY_NAMES[cat] .. " " .. (catSeen[cat] or 0) end
print("Cross-check " .. CROSS .. " random 7-card hands vs brute force: OK")
print("   " .. table.concat(parts, ", "))

print(string.format("test_poker_eval: %d checks passed", H.passed))
