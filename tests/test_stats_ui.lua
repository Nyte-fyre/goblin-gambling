-- lua tests/test_stats_ui.lua   (run from the GoblinGambling/ folder)
-- Drives the Stats tab, titles and debt repayment against tests/wowmock.lua.
local H = dofile("tests/helpers.lua")
local M = dofile("tests/wowmock.lua")
local GG = M.loadAddon({})
M.fireEvent("ADDON_LOADED", "GoblinGambling")
M.fireEvent("PLAYER_LOGIN")
math.randomseed(77)

-- Capture every FontString text so we can look for values on screen.
local texts = {}
do
  local Widget = getmetatable(UIParent)
  local orig = Widget.SetText
  Widget.SetText = function(self, t)
    texts[self] = t
    return orig(self, t)
  end
end
local function onScreen(pattern)
  for w, t in pairs(texts) do
    if type(t) == "string" and t:find(pattern) then return true end
  end
  return false
end
local function said(pattern)
  for _, line in ipairs(M.printed) do if line:find(pattern) then return true end end
  return false
end

GG:ShowWindow()
GG:SelectTab("stats")
H.ok(onScreen("^Casual Adventurer$"), "starting title shown")
H.ok(onScreen("^Lifetime wagered$"), "row labels shown")
H.ok(onScreen("0 / 500 spins"), "spin progress shown")
H.ok(onScreen("none yet"), "no biggest win yet")

------------------------------------------------------------------------
-- Stats update from slot spins (while the stats tab is built)
------------------------------------------------------------------------
GG:SelectTab("slots")
for _ = 1, 30 do
  GG.SlotsUI.Spin()
  M.advance(2.5)
end
GG:SelectTab("stats")
local s = GG.db.stats
H.eq(s.spins, 30, "30 spins recorded")
H.ok(onScreen("^" .. GG.FormatNumber(s.totalWagered) .. "$"), "wagered value on screen")
H.ok(onScreen("30 / 500 spins"), "progress updated")

------------------------------------------------------------------------
-- Title unlock announcement (local print only)
------------------------------------------------------------------------
M.printed = {}
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept()
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept()
H.ok(not said("New title"), "no announcement before earning one")
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept()
H.eq(GG:GetTitle(), "Debtor of Ratchet", "3 bailouts = debtor")
H.ok(said("New title: .*Debtor of Ratchet"), "title announced")
H.ok(onScreen("^Debtor of Ratchet$"), "title shown on tab")
H.ok(onScreen("3,750"), "debt shown")
M.printed = {}
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept()
H.ok(not said("New title"), "no repeat announcement")

------------------------------------------------------------------------
-- Repaying debt
------------------------------------------------------------------------
GG.db.balance = 2000
GG:Fire("BALANCE_CHANGED", 2000, 0)
local debt = GG:GetDebt()
M.findButton("Pay Grubnik"):Fire("OnClick")
H.eq(M.lastPopup().which, "GOBLINGAMBLING_REPAY", "repay asks first")
H.eq(GG:GetDebt(), debt, "nothing paid before confirming")
StaticPopupDialogs.GOBLINGAMBLING_REPAY.OnAccept()
H.eq(GG:GetBalance(), 0, "paid everything we had")
H.eq(GG:GetDebt(), debt - 2000, "debt reduced")
local debtLineOk = false
for w, txt in pairs(texts) do
  if type(txt) == "string" and txt:find("Owed to Grubnik: " .. GG.FormatNumber(debt - 2000), 1, true)
     and w:IsShown() then debtLineOk = true end
end
H.ok(debtLineOk, "balance bar debt line shows the reduced debt after a partial payment")
GG.db.balance = 100000
GG:Fire("BALANCE_CHANGED", 100000, 0)
M.slash("repay")
StaticPopupDialogs.GOBLINGAMBLING_REPAY.OnAccept()
H.eq(GG:GetDebt(), 0, "debt cleared")
H.eq(GG:GetBalance(), 100000 - (debt - 2000), "only the debt was taken")
H.ok(said("Debt cleared"), "cleared message")
-- The red debt line on the balance bar goes away once the debt is paid
for w, txt in pairs(texts) do
  if type(txt) == "string" and txt:find("Owed to Grubnik: ") then
    H.eq(w:IsShown(), false, "balance bar debt line hidden after paying off")
  end
end
H.ok(onScreen("nothing"), "tab shows no debt")
local n = #M.popups
M.slash("repay")
H.eq(#M.popups, n, "no popup when nothing is owed")
H.eq(GG:RepayDebt(), 0, "repay with no debt does nothing")

------------------------------------------------------------------------
-- Reset stats is confirm-gated and keeps balance
------------------------------------------------------------------------
local bal = GG:GetBalance()
M.findButton("Reset stats"):Fire("OnClick")
H.eq(M.lastPopup().which, "GOBLINGAMBLING_RESET_STATS", "reset asks first")
H.eq(GG.db.stats.spins, 30, "not wiped before confirming")
StaticPopupDialogs.GOBLINGAMBLING_RESET_STATS.OnAccept()
H.eq(GG.db.stats.spins, 0, "stats wiped")
H.eq(GG:GetBalance(), bal, "balance kept")
H.ok(onScreen("^Casual Adventurer$"), "title back to casual")
H.ok(onScreen("0 / 500 spins"), "progress reset on screen")

-- Every tooltip on every frame runs without error
for _, f in ipairs(M.frames) do f:Fire("OnEnter"); f:Fire("OnLeave") end

-- Stats persist through a reload
GG:RecordRound("spin", 10, 1000)
local saved = GoblinGamblingDB
M.frames, M.timers = {}, {}
local GG2 = M.loadAddon({})
GoblinGamblingDB = saved
M.fireEvent("ADDON_LOADED", "GoblinGambling")
H.eq(GG2.db.stats.spins, 1, "stats survive reload")
H.eq(GG2:GetTitle(), "Lucky Goblin", "title survives reload")

M.realPrint(string.format("test_stats_ui: %d checks passed", H.passed))
