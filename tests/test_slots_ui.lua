-- lua tests/test_slots_ui.lua   (run from the GoblinGambling/ folder)
-- Drives the slot machine tab against tests/wowmock.lua.
local H = dofile("tests/helpers.lua")
local M = dofile("tests/wowmock.lua")
local GG = M.loadAddon({})
M.fireEvent("ADDON_LOADED", "GoblinGambling")
M.fireEvent("PLAYER_LOGIN")
math.randomseed(4242)

local UI = GG.SlotsUI
local S = GG.db.stats

-- Money invariant: everything is explained by wagers, payouts and bailouts.
local function checkLedger(msg)
  local expected = 1000 + S.totalWon - S.totalWagered + S.bailouts * GG.BAILOUT_AMOUNT
  H.eq(GG:GetBalance(), expected, "ledger: " .. msg)
end

local function spinButton()
  for _, f in ipairs(M.frames) do
    if f._kind == "Button" and type(f._text) == "string"
       and (f._text:match("^Spin") or f._text == "Visit Grubnik" or f._text == "Can't afford") then
      return f
    end
  end
end

GG:ShowWindow()
GG:SelectTab("slots")
H.ok(spinButton(), "spin button exists")
H.eq(spinButton():GetText(), "Spin (10)", "spin label shows default bet")

------------------------------------------------------------------------
-- One spin: money settles instantly, reels land on the result
------------------------------------------------------------------------
spinButton():Fire("OnClick")
H.eq(UI.IsSpinning(), true, "spinning after click")
H.eq(S.spins, 1, "spin recorded immediately")
checkLedger("settled before the animation")
H.eq(spinButton():GetText(), "Spinning...", "button shows spinning")
H.eq(spinButton():IsEnabled(), false, "button disabled while spinning")
spinButton():Fire("OnClick")  -- double click does nothing
H.eq(S.spins, 1, "no double spin")

M.advance(3)
H.eq(UI.IsSpinning(), false, "reels stopped")
local res = UI.lastResult
local shown = UI.PaylineSymbols()
for i = 1, 3 do H.eq(shown[i], res.reels[i], "reel " .. i .. " landed on the result") end

------------------------------------------------------------------------
-- Many spins at each bet size
------------------------------------------------------------------------
local tiers = {}
for _, bet in ipairs({ 10, 50, 100 }) do
  M.findButton(GG.FormatNumber(bet)):Fire("OnClick")
  H.eq(UI.CurrentBet(), bet, "bet " .. bet .. " selected")
  for _ = 1, 60 do
    if GG:IsBroke() or not GG:CanAfford(bet) then StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept() end
    UI.Spin()
    M.advance(2.5)
    H.eq(UI.IsSpinning(), false, "spin finished")
    local r = UI.lastResult
    local p = UI.PaylineSymbols()
    for i = 1, 3 do H.eq(p[i], r.reels[i], "landed") end
    tiers[r.tier] = (tiers[r.tier] or 0) + 1
    checkLedger("after spin")
  end
end
H.ok(tiers.loss and tiers.small, "saw both losses and wins")

------------------------------------------------------------------------
-- Max bet
------------------------------------------------------------------------
M.findButton("Max"):Fire("OnClick")
H.eq(GG.db.settings.slotsBet, "max", "max selected")
GG.db.balance = 37
GG:Fire("BALANCE_CHANGED", 37, 0)
H.eq(UI.CurrentBet(), 37, "max = whole balance when under 1,000")
GG.db.balance = 5000
GG:Fire("BALANCE_CHANGED", 5000, 37)
H.eq(UI.CurrentBet(), 1000, "max caps at 1,000")
M.findButton("10"):Fire("OnClick")

------------------------------------------------------------------------
-- Closing the window mid-spin settles instantly
------------------------------------------------------------------------
GG.db.balance = 1000
GG:ResetStats()
GG.db.stats.bailouts = 0
S = GG.db.stats
local before = GG:GetBalance()
UI.Spin()
GoblinGamblingFrame:Hide()
H.eq(UI.IsSpinning(), false, "closing finishes the spin")
H.eq(GG:GetBalance(), before - 10 + UI.lastResult.payout, "money settled on close")
local p = UI.PaylineSymbols()
for i = 1, 3 do H.eq(p[i], UI.lastResult.reels[i], "snapped to result") end
GG:ShowWindow()

------------------------------------------------------------------------
-- Autospin: keeps going, stops on window close
------------------------------------------------------------------------
GG.db.balance = 100000
local spinsBefore = S.spins
UI.SetAutospin(true)
UI.Spin()
M.advance(12)
local ran = S.spins - spinsBefore
H.ok(ran >= 3 or not UI.IsAutospin(), "autospin ran several spins (" .. ran .. ")")
GoblinGamblingFrame:Hide()
H.eq(UI.IsAutospin(), false, "closing window stops autospin")
local after = S.spins
M.advance(5)
H.eq(S.spins, after, "no spins after close")
GG:ShowWindow()

-- Ticking the Autospin checkbox starts spinning; unticking stops it
local autoBox
for _, f in ipairs(M.frames) do
  if f._kind == "CheckButton" and f.label and f.label._text == "Autospin" then autoBox = f end
end
H.ok(autoBox, "autospin checkbox exists")
spinsBefore = S.spins
autoBox:SetChecked(true)
autoBox:Fire("OnClick")
H.eq(UI.IsAutospin(), true, "checkbox turns autospin on")
H.eq(S.spins, spinsBefore + 1, "checkbox starts the first spin")
M.advance(1)
autoBox:SetChecked(false)
autoBox:Fire("OnClick")
H.eq(UI.IsAutospin(), false, "unticking stops autospin")
M.advance(5)
H.eq(UI.IsSpinning(), false, "last spin finished")

-- Autospin stops on a big win: force every spin to be a jackpot
local realSpin = GG.SlotsLogic.Spin
GG.SlotsLogic.Spin = function(bet)
  local r = 0
  return realSpin(bet, function(n)
    r = r + 1
    local acc = 0
    for _, stop in ipairs(GG.SlotsLogic.config.reels[r]) do
      acc = acc + stop[2]
      if stop[1] == "JACKPOT" then return acc end
    end
  end)
end
UI.SetAutospin(true)
UI.Spin()
M.advance(5)
H.eq(UI.lastResult.tier, "jackpot", "forced jackpot")
H.eq(UI.IsAutospin(), false, "autospin stops on jackpot")
GG.SlotsLogic.Spin = realSpin

-- Autospin stops when the bet becomes unaffordable
GG.db.balance = 60
M.findButton("50"):Fire("OnClick")
GG.SlotsLogic.Spin = function(bet) local r = realSpin(bet) r.payout, r.tier, r.mult = 0, "loss", 0 return r end
UI.SetAutospin(true)
UI.Spin()
M.advance(5)
H.eq(UI.IsAutospin(), false, "autospin stops when broke or short")
GG.SlotsLogic.Spin = realSpin
M.findButton("10"):Fire("OnClick")

------------------------------------------------------------------------
-- Broke: button turns into a loan shark visit
------------------------------------------------------------------------
GG.db.balance = 5
GG:Fire("BALANCE_CHANGED", 5, 60)
H.eq(spinButton():GetText(), "Visit Grubnik", "broke label")
local popups = #M.popups
spinButton():Fire("OnClick")
H.eq(M.lastPopup().which, "GOBLINGAMBLING_LOAN", "broke click opens loan shark")
H.eq(#M.popups, popups + 1, "one popup")
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept()
H.eq(spinButton():GetText(), "Spin (10)", "after bailout you can spin again")

-- Unaffordable but not broke
GG.db.balance = 40
M.findButton("50"):Fire("OnClick")
H.eq(spinButton():GetText(), "Can't afford", "unaffordable label")
H.eq(spinButton():IsEnabled(), false, "unaffordable disables spin")

-- Spinning down to broke shows the loan shark on its own
M.findButton("10"):Fire("OnClick")
GG.db.balance = 10
GG.SlotsLogic.Spin = function(bet) local r = realSpin(bet) r.payout, r.tier, r.mult = 0, "loss", 0 return r end
popups = #M.popups
UI.Spin()
M.advance(4)
H.eq(#M.popups, popups + 1, "going broke pops the loan shark")
GG.SlotsLogic.Spin = realSpin

------------------------------------------------------------------------
-- Paytable, sound toggle, tab switching
------------------------------------------------------------------------
M.findButton("Paytable"):Fire("OnClick")
H.eq(GG.db.settings.showPaytable, true, "paytable shown")
M.findButton("Paytable"):Fire("OnClick")
H.eq(GG.db.settings.showPaytable, false, "paytable hidden")

-- The paytable follows the Slots tab: hidden elsewhere, back when you return
local function paytableFrame()
  for _, f in ipairs(M.frames) do
    for _, pt in ipairs(f._points) do
      if pt[1] == "TOPLEFT" and pt[2] == GoblinGamblingFrame and pt[3] == "TOPRIGHT" then return f end
    end
  end
end
M.findButton("Paytable"):Fire("OnClick")
local pt = paytableFrame()
H.ok(pt and pt:IsShown(), "paytable open on slots")
GG:SelectTab("poker")
H.eq(pt:IsShown(), false, "paytable hides on the poker tab")
GG:SelectTab("stats")
H.eq(pt:IsShown(), false, "paytable stays hidden on the stats tab")
H.eq(GG.db.settings.showPaytable, true, "leaving the tab does not forget it was open")
GG:SelectTab("slots")
H.eq(pt:IsShown(), true, "paytable comes back with the slots tab")
M.findButton("Paytable"):Fire("OnClick")
GG:SelectTab("stats")
GG:SelectTab("slots")
H.eq(pt:IsShown(), false, "a closed paytable stays closed when you come back")
for _, f in ipairs(M.frames) do f:Fire("OnEnter"); f:Fire("OnLeave") end  -- every tooltip

GG.db.balance = 1000
UI.SetAutospin(true)
GG:SelectTab("poker")
H.eq(UI.IsAutospin(), false, "leaving the tab stops autospin")
GG:SelectTab("slots")

------------------------------------------------------------------------
-- Reel speeds
------------------------------------------------------------------------
H.eq(UI.CurrentSpeed().key, "medium", "default speed")
local function speedButton()
  for _, f in ipairs(M.frames) do
    if f._kind == "Button" and type(f._text) == "string" and f._text:match("^Speed: ") then return f end
  end
end
H.eq(speedButton():GetText(), "Speed: Kodo Trot", "speed button label")
speedButton():Fire("OnClick")
H.eq(GG.db.settings.slotsSpeed, "fast", "click cycles to fast")
H.eq(speedButton():GetText(), "Speed: Rocket Boots", "label follows")
speedButton():Fire("OnClick")
H.eq(GG.db.settings.slotsSpeed, "slow", "then slow")
speedButton():Fire("OnClick")
H.eq(GG.db.settings.slotsSpeed, "medium", "then back to medium")

-- Timing: last reel stops at base + 2 * stagger
local function timeSpin(key)
  GG:SetSlotSpeed(key)
  local sp = UI.CurrentSpeed()
  local last = sp.base + 2 * sp.stagger
  UI.Spin()
  M.advance(last - 0.15)
  local stillGoing = UI.IsSpinning()
  M.advance(0.3)
  local done = not UI.IsSpinning()
  local p = UI.PaylineSymbols()
  for i = 1, 3 do H.eq(p[i], UI.lastResult.reels[i], key .. " landed") end
  return stillGoing, done, last
end
for _, key in ipairs({ "slow", "medium", "fast" }) do
  local going, done, last = timeSpin(key)
  H.ok(going, key .. ": still spinning just before " .. last .. "s")
  H.ok(done, key .. ": stopped just after " .. last .. "s")
end
H.ok(GG.SLOT_SPEEDS[1].base > GG.SLOT_SPEEDS[3].base * 3, "slow is much slower than fast")

-- Changing speed mid-spin only affects the next spin
GG:SetSlotSpeed("fast")
UI.Spin()
GG:SetSlotSpeed("slow")
M.advance(0.9)
H.eq(UI.IsSpinning(), false, "mid-spin change does not slow the current spin")

-- Slash command
M.slash("speed fast");   H.eq(GG.db.settings.slotsSpeed, "fast", "/gg speed fast")
M.slash("speed turtle"); H.eq(GG.db.settings.slotsSpeed, "slow", "/gg speed turtle alias")
M.slash("speed");        H.eq(GG.db.settings.slotsSpeed, "medium", "/gg speed cycles")
M.slash("speed warp9");  H.eq(GG.db.settings.slotsSpeed, "medium", "unknown speed ignored")
H.eq(GG:SetSlotSpeed("nope"), nil, "SetSlotSpeed rejects junk")
GG.db.settings.slotsSpeed = "garbage"
H.eq(UI.CurrentSpeed().key, "medium", "junk saved speed falls back to medium")
GG:SetSlotSpeed("medium")

-- Reload with the paytable open builds it straight away
GG.db.settings.showPaytable = true

M.realPrint(string.format("test_slots_ui: %d checks passed (tiers seen: loss %d, small %d, big %d)",
  H.passed, tiers.loss or 0, tiers.small or 0, tiers.big or 0))
