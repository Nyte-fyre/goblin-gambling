-- lua tests/test_poker_ui.lua   (run from the GoblinGambling/ folder)
-- Plays real hands at the poker table through tests/wowmock.lua.
local H = dofile("tests/helpers.lua")
local M = dofile("tests/wowmock.lua")
local GG = M.loadAddon({})
M.fireEvent("ADDON_LOADED", "GoblinGambling")
M.fireEvent("PLAYER_LOGIN")
math.randomseed(31337)

local PUI = GG.PokerUI
local P = GG.PokerLogic
PUI.rollouts = 8   -- bots think less in tests; game uses 150

local function advanceUntil(pred, maxSeconds)
  local waited = 0
  while not pred() do
    M.advance(0.25, 0.05)
    waited = waited + 0.25
    if waited > (maxSeconds or 120) then error("timed out waiting", 2) end
  end
end

-- Goblin Gold + chips at the table is fully explained by poker results.
local startMoney
local function checkMoney(msg)
  local s = GG.db.stats
  local atTable = GG.db.poker and GG.db.poker.stack or 0
  H.eq(GG:GetBalance() + atTable, startMoney + s.totalWon - s.totalWagered, "money: " .. msg)
end

local function findButtonMatching(pattern)
  for _, f in ipairs(M.frames) do
    if f._kind == "Button" and type(f._text) == "string" and f._text:match(pattern) then return f end
  end
end

------------------------------------------------------------------------
-- Lobby
------------------------------------------------------------------------
GG:ShowWindow()
GG:SelectTab("poker")
H.ok(findButtonMatching("^Sit %(buy in 1,000%)$"), "copper sit button shows the buy-in")
H.ok(findButtonMatching("^Need 4,000$"), "gold table needs 4,000 (20 big blinds)")
M.findButton("5 bots"):Fire("OnClick")
H.eq(GG.db.settings.pokerBots, 5, "bot count saved")
M.findButton("3 bots"):Fire("OnClick")
H.eq(GG.db.settings.pokerBots, 3, "bot count changed")

GG.db.balance = 50
H.eq(PUI.Sit("copper"), false, "cannot sit with less than 20 big blinds")
H.eq(GG:GetBalance(), 50, "no money taken")
GG.db.balance = 20000
GG:Fire("BALANCE_CHANGED", 20000, 50)
startMoney = 20000

------------------------------------------------------------------------
-- Sit down: buy-in comes out of Goblin Gold
------------------------------------------------------------------------
-- Loan button in the lobby
local popups = #M.popups
M.findButton("Get a loan"):Fire("OnClick")
H.eq(M.lastPopup().which, "GOBLINGAMBLING_LOAN", "lobby loan button opens Grubnik")
H.eq(#M.popups, popups + 1, "one popup")

-- Record everything drawn, to check seat stacks before the first hand
local drawn = {}
do
  local Widget = getmetatable(UIParent)
  local orig = Widget.SetText
  Widget.SetText = function(self, txt) drawn[#drawn + 1] = txt; return orig(self, txt) end
end

findButtonMatching("^Sit %(buy in 1,000%)$"):Fire("OnClick")
local t = PUI.Table()
local zeros, thousands = 0, 0
for _, txt in ipairs(drawn) do
  if txt == "0" then zeros = zeros + 1 end
  if txt == "1,000" then thousands = thousands + 1 end
end
H.eq(zeros, 0, "no seat shows 0 chips before the first hand")
H.ok(thousands >= 4, "every seat shows its real stack before the first hand")
H.ok(M.findButton("Get a loan"), "loan button at the table too")
H.ok(t, "seated")
H.eq(#t.seats, 4, "you + 3 bots")
H.eq(GG:GetBalance(), 19000, "buy-in debited")
H.eq(GG.db.poker.stack, 1000, "stack mirrored for safety")
checkMoney("after sit")
H.eq(PUI.Leave(), true, "can leave before any hand")
H.eq(GG:GetBalance(), 20000, "cash out returns the stack")
H.eq(GG.db.poker, nil, "nothing left at the table")

------------------------------------------------------------------------
-- Play hands with random legal choices
------------------------------------------------------------------------
H.eq(PUI.Sit("copper", 5), true, "sit with 5 bots")
t = PUI.Table()
H.eq(#t.seats, 6, "you + 5 bots")

local rng = H.rng(4)
local hands, humanActions, showdowns, sidePots, refusedLeave, busts = 0, 0, 0, 0, false, 0
while hands < 60 do
  if t.seats[1].stack == 0 then
    -- Busted: the deal button says so and is disabled; leave and sit again.
    local b = M.findButton("You're busted")
    H.ok(b, "busted label shown")
    H.eq(b:IsEnabled(), false, "cannot deal when busted")
    H.eq(PUI.Leave(), true, "busted player can leave")
    H.eq(GG.db.poker, nil, "busted: nothing left at the table")
    H.eq(PUI.Sit("copper", 5), true, "sit again")
    t = PUI.Table()
    busts = busts + 1
  end
  H.ok(PUI.Between(), "between hands before dealing")
  M.findButton("Deal next hand"):Fire("OnClick")
  H.ok(not PUI.Between(), "hand started")
  local startHand = t.handNo
  advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
  while not PUI.Between() do
    if PUI.IsHumanTurn() then
      if not refusedLeave then
        H.eq(PUI.Leave(), false, "cannot leave while still in the hand")
        refusedLeave = true
      end
      local la = P.LegalActions(t, 1)
      local r = rng(100)
      local a
      if la.canRaise and r <= 10 then a = { type = "allin" }
      elseif la.canRaise and r <= 30 then a = { type = "raise", amount = la.minRaiseTo }
      elseif r <= 50 and la.call > 0 then a = { type = "fold" }
      elseif la.check then a = { type = "check" }
      else a = { type = "call" } end
      H.eq(PUI.Act(a), true, "human action accepted")
      humanActions = humanActions + 1
    end
    advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
  end
  hands = hands + 1
  H.eq(t.handNo, startHand, "one hand at a time")

  -- Screen matches the engine once the replay finishes
  local vm = PUI.Display()
  H.eq(vm.done, true, "display finished the hand")
  H.eq(vm.pot, 0, "display pot empty")
  for i, p in ipairs(t.seats) do H.eq(vm.seats[i].stack, p.stack, "display stack seat " .. i) end
  H.eq(GG.db.poker.stack, t.seats[1].stack, "mirrored stack up to date")
  checkMoney("after hand " .. hands)
  if t.result.reason == "showdown" then showdowns = showdowns + 1 end
  if #t.result.pots > 1 then sidePots = sidePots + 1 end
end
H.eq(hands, 60, "played 60 hands")
H.ok(humanActions > 0, "human got to act")
H.eq(GG.db.stats.hands, hands, "hands recorded in stats")

-- Every tooltip works
for _, f in ipairs(M.frames) do f:Fire("OnEnter"); f:Fire("OnLeave") end

------------------------------------------------------------------------
-- Leaving after folding mid-hand finishes the hand instantly
------------------------------------------------------------------------
if t.seats[1].stack > 0 then
  local folded = false
  for _ = 1, 20 do
    M.findButton("Deal next hand"):Fire("OnClick")
    advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
    if PUI.IsHumanTurn() and P.LegalActions(t, 1).call > 0 then
      PUI.Act({ type = "fold" })
      folded = true
      break
    end
    advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
    while not PUI.Between() do
      if PUI.IsHumanTurn() then
        local la = P.LegalActions(t, 1)
        PUI.Act({ type = la.check and "check" or "call" })
      end
      advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
    end
  end
  H.ok(folded, "got a chance to fold and leave mid-hand")
  if folded then
    H.eq(M.findButton("Hand in progress...") ~= nil, true, "deal button says the hand is still going")
    H.eq(M.findButton("Hand in progress..."):IsEnabled(), false, "cannot deal mid-hand")
    local cash = findButtonMatching("^Cash out ")
    H.ok(cash and cash:IsVisible(), "cash out offered after folding")
    local stack = t.seats[1].stack
    local before = GG:GetBalance()
    H.eq(PUI.Leave(), true, "can leave after folding")
    H.eq(GG:GetBalance(), before + stack, "folded stack cashed out")
    H.eq(PUI.Table(), nil, "back in the lobby")
    checkMoney("after leaving mid-hand")
  end
end
if PUI.Table() then PUI.Leave() end
checkMoney("after leaving")

------------------------------------------------------------------------
-- Pausing: switching tabs stops the table
------------------------------------------------------------------------
PUI.Sit("copper", 3)
t = PUI.Table()
M.findButton("Deal next hand"):Fire("OnClick")
GG:SelectTab("stats")
local events = #t.events
local shown = PUI.Display().handNo
M.advance(10)
H.eq(#t.events, events, "no bot acts while the tab is hidden")
GG:SelectTab("poker")
advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
H.ok(PUI.Display().handNo >= shown, "resumes when shown again")

------------------------------------------------------------------------
-- Suit display toggle and auto-deal
------------------------------------------------------------------------
M.slash("suits")
H.eq(GG.db.settings.suitLetters, true, "suits as letters")
M.slash("suits")
H.eq(GG.db.settings.suitLetters, false, "suits as symbols")

while not PUI.Between() do
  if PUI.IsHumanTurn() then PUI.Act({ type = "fold" }) end
  advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
end
local autoBox
for _, f in ipairs(M.frames) do
  if f._kind == "CheckButton" and f.label and f.label._text == "Auto-deal" then autoBox = f end
end
H.ok(autoBox, "auto-deal checkbox exists")
autoBox:SetChecked(true); autoBox:Fire("OnClick")
H.eq(GG.db.settings.pokerAutoDeal, true, "auto-deal on")
local hn = t.handNo
M.advance(4)
H.ok(t.handNo > hn, "auto-deal starts the next hand")

-- The checkbox is reachable mid-hand, and unticking it stops the loop
H.ok(PUI.Table() and not PUI.Between(), "a hand is running")
H.eq(autoBox:IsVisible(), true, "auto-deal checkbox visible during a hand")
autoBox:SetChecked(false); autoBox:Fire("OnClick")
H.eq(GG.db.settings.pokerAutoDeal, false, "auto-deal off mid-hand")
while not PUI.Between() do
  if PUI.IsHumanTurn() then PUI.Act({ type = "fold" }) end
  advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
end
hn = t.handNo
M.advance(8)
H.eq(t.handNo, hn, "no more hands dealt after unticking")

------------------------------------------------------------------------
-- A /reload mid-hand: chips at the table come back on login
------------------------------------------------------------------------
advanceUntil(function() return PUI.Between() or PUI.IsHumanTurn() end)
local atTable = GG.db.poker.stack
local balance = GG:GetBalance()
local saved = GoblinGamblingDB
M.frames, M.timers = {}, {}
GoblinGamblingFrame, GoblinGamblingMinimapButton = nil, nil
UISpecialFrames = {}
local GG2 = M.loadAddon({})
GoblinGamblingDB = saved
M.printed = {}
M.fireEvent("ADDON_LOADED", "GoblinGambling")
H.eq(GG2:GetBalance(), balance + atTable, "stack returned after reload")
H.eq(GG2.db.poker, nil, "table cleared")
local said = false
for _, line in ipairs(M.printed) do if line:find("cashed out") then said = true end end
H.ok(said, "player told about it")

M.realPrint(string.format("test_poker_ui: %d checks passed (%d hands, %d showdowns, %d with side pots, you acted %d times)",
  H.passed, hands, showdowns, sidePots, humanActions) .. (", busted %d times"):format(busts))
