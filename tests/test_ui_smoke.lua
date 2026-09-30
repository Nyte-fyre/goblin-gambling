-- lua tests/test_ui_smoke.lua   (run from the GoblinGambling/ folder)
-- Runs the whole addon against tests/wowmock.lua: loads every TOC file,
-- fires the login events, and drives the window, tabs, popups and minimap
-- button. Catches nil calls and typos that would be Lua errors in game.
local H = dofile("tests/helpers.lua")
local M = dofile("tests/wowmock.lua")
local GG = M.loadAddon({})

------------------------------------------------------------------------
-- Fresh install: defaults
------------------------------------------------------------------------
M.fireEvent("ADDON_LOADED", "SomeOtherAddon")
H.eq(GG.db, nil, "ignores other addons' ADDON_LOADED")
M.fireEvent("ADDON_LOADED", "GoblinGambling")
M.fireEvent("PLAYER_LOGIN")
H.ok(GoblinGamblingDB, "SavedVariables created")
H.eq(GG:GetBalance(), 1000, "starting balance")
H.eq(GG:GetDebt(), 0, "starting debt")
H.eq(GoblinGamblingDB.stats.biggestWinMult, 0, "stats defaults filled")
H.ok(GoblinGamblingMinimapButton, "minimap button created")
H.ok(GoblinGamblingMinimapButton:IsShown(), "minimap button shown")

------------------------------------------------------------------------
-- Balance API
------------------------------------------------------------------------
H.eq(GG:CanAfford(1000), true, "can afford whole balance")
H.eq(GG:CanAfford(1001), false, "cannot afford more")
H.eq(GG:CanAfford(-5), false, "negative bet rejected")
H.eq(GG:CanAfford(2.5), false, "fractional bet rejected")
H.eq(GG:Debit(1001), false, "debit too much fails")
H.eq(GG:GetBalance(), 1000, "failed debit leaves balance")
H.eq(GG:Debit(250), true, "debit ok")
H.eq(GG:GetBalance(), 750, "balance after debit")
H.eq(GG:Credit(50), true, "credit ok")
H.eq(GG:Credit(0), true, "credit zero is fine")
H.eq(GG:Credit(-10), false, "negative credit rejected")
H.eq(GG:GetBalance(), 800, "balance after credit")

------------------------------------------------------------------------
-- Window: slash toggles, tabs, Esc registration, drag saves position
------------------------------------------------------------------------
M.slash("")
local frame = GoblinGamblingFrame
H.ok(frame, "window built on first toggle")
H.ok(frame:IsShown(), "window open")
H.eq(UISpecialFrames[1], "GoblinGamblingFrame", "registered for Esc")
M.advance(1)

for _, tab in ipairs(GG.TABS) do
  GG:SelectTab(tab.key)
  H.eq(GG.db.settings.lastTab, tab.key, "tab " .. tab.key .. " selected")
end

-- Clicking a tab button (goes through CreateButton's OnClick wrapper)
M.findButton("Poker"):Fire("OnClick")
H.eq(GG.db.settings.lastTab, "poker", "tab button click")

-- Drag: the title bar is the frame with OnDragStop that moves the window
local dragged = false
for _, f in ipairs(M.frames) do
  if f._scripts.OnDragStop and f._parent == frame then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 123, -45)
    f:Fire("OnDragStart")
    f:Fire("OnDragStop")
    dragged = true
  end
end
H.ok(dragged, "found title bar drag handle")
local pos = GG.db.settings.windowPos
H.eq(pos.point, "TOPLEFT", "saved point")
H.eq(pos.x, 123, "saved x")
H.eq(pos.y, -45, "saved y")

-- Resize grip: drag scales the window, right-click resets, scale persists
local grip = frame.resizeGrip
H.ok(grip, "resize grip exists")
M.cursorX = 100 + 520 * 1.3          -- window left is 100 in the mock
grip:Fire("OnMouseDown", "LeftButton")
M.advance(0.1)
grip:Fire("OnMouseUp", "LeftButton")
H.eq(math.floor(GG.db.settings.windowScale * 100 + 0.5), 130, "dragged to 130%")
H.eq(frame:GetScale(), GG.db.settings.windowScale, "frame scaled")
H.eq(GG.db.settings.windowPos.point, "TOPLEFT", "top-left pinned while resizing")
M.cursorX = 5000
grip:Fire("OnMouseDown", "LeftButton"); M.advance(0.1); grip:Fire("OnMouseUp", "LeftButton")
H.eq(GG.db.settings.windowScale, 1.6, "scale capped at 160%")
M.cursorX = 0
grip:Fire("OnMouseDown", "LeftButton"); M.advance(0.1); grip:Fire("OnMouseUp", "LeftButton")
H.eq(GG.db.settings.windowScale, 0.7, "scale floored at 70%")
grip:Fire("OnClick", "RightButton")
H.eq(GG.db.settings.windowScale, 1, "right-click resets size")
GG:SetWindowScale(1.25)
M.cursorX = nil
frame:ClearAllPoints()
frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 123, -45)
for _, f in ipairs(M.frames) do
  if f._scripts.OnDragStop and f._parent == frame then f:Fire("OnDragStop") end
end

M.slash("toggle")
H.eq(frame:IsShown(), false, "toggle closes")
M.slash("show")
H.eq(frame:IsShown(), true, "reopens")

------------------------------------------------------------------------
-- Balance bar: loss snaps, win counts up, freeze holds the display
------------------------------------------------------------------------
-- FontStrings are not in M.frames, so capture the bar text via SetText.
local barValue
do
  local Widget = getmetatable(UIParent)
  local orig = Widget.SetText
  Widget.SetText = function(self, t)
    if type(t) == "string" then
      local num = t:match("^Goblin Gold: |cffffd100([%d,%-]+)|r")
      if num then barValue = tonumber((num:gsub(",", ""))) end
    end
    return orig(self, t)
  end
end

GG:Debit(100)
H.eq(barValue, 700, "loss snaps the bar down immediately")
GG:FreezeBalanceDisplay()
GG:Credit(500)
M.advance(1)
H.eq(barValue, 700, "frozen bar ignores the credit")
GG:ReleaseBalanceDisplay()
M.advance(0.2)
H.ok(barValue > 700 and barValue < 1200, "bar is counting up: " .. tostring(barValue))
M.advance(1)
H.eq(barValue, 1200, "bar lands on the real balance")
GG:FlashWindow(1, 0.8, 0)

------------------------------------------------------------------------
-- Loan shark, reset popups
------------------------------------------------------------------------
M.slash("loan")
H.eq(M.lastPopup().which, "GOBLINGAMBLING_LOAN", "loan popup shown")
local before = GG:GetBalance()
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnAccept()
H.eq(GG:GetBalance(), before + 1000, "bailout credits 1000")
H.eq(GG:GetDebt(), 1250, "bailout adds 1250 debt")
H.eq(GG.db.stats.bailouts, 1, "bailout counted")
StaticPopupDialogs.GOBLINGAMBLING_LOAN.OnCancel(nil, nil, "clicked")
M.advance(1)

GG:RecordRound("spin", 10, 0)
M.slash("reset")
H.eq(M.lastPopup().which, "GOBLINGAMBLING_RESET", "reset asks first")
H.eq(GG.db.stats.spins, 1, "nothing wiped before confirming")
StaticPopupDialogs.GOBLINGAMBLING_RESET.OnAccept()
H.eq(GG:GetBalance(), 1000, "reset balance")
H.eq(GG:GetDebt(), 0, "reset debt")
H.eq(GG.db.stats.spins, 0, "reset stats")
H.eq(GG.db.settings.windowPos.x, 123, "reset keeps window position")

GG:RecordRound("spin", 10, 0)
StaticPopupDialogs.GOBLINGAMBLING_RESET_STATS.OnAccept()
H.eq(GG.db.stats.spins, 0, "stats reset")

------------------------------------------------------------------------
-- Other slash commands
------------------------------------------------------------------------
M.slash("sound")
H.eq(GG.db.settings.sound, false, "mute")
local n = #M.sounds
GG:PlaySound("jackpot")
H.eq(#M.sounds, n, "muted: no sound")
M.slash("sound")
GG:PlaySound("jackpot")
H.eq(M.sounds[#M.sounds], 888, "unmuted: jackpot sound")
GG:PlaySound("nonsense-key")  -- must not error

M.slash("soundtest")
M.advance(20)

M.slash("minimap")
H.eq(GoblinGamblingMinimapButton:IsShown(), false, "minimap hidden")
M.slash("minimap")
H.eq(GoblinGamblingMinimapButton:IsShown(), true, "minimap shown")

M.slash("help")
M.slash("nonsense")

-- Minimap drag changes the saved angle; click toggles the window
M.cursorX, M.cursorY = 500, 600  -- straight above the minimap centre
GoblinGamblingMinimapButton:Fire("OnDragStart")
M.advance(0.1)
GoblinGamblingMinimapButton:Fire("OnDragStop")
H.eq(math.floor(GG.db.settings.minimap.angle + 0.5), 90, "drag to top = 90 degrees")
local wasShown = frame:IsShown()
GoblinGamblingMinimapButton:Fire("OnClick")
H.eq(frame:IsShown(), not wasShown, "minimap click toggles")
GoblinGamblingMinimapButton:Fire("OnEnter")
GoblinGamblingMinimapButton:Fire("OnLeave")

------------------------------------------------------------------------
-- Reload: saved data survives and migration fills new keys only
------------------------------------------------------------------------
GG:Debit(337)
local saved = GoblinGamblingDB
saved.stats.biggestWinMult = nil      -- pretend an old file lacks a newer key
saved.settings.minimap.angle = 45

M.frames, M.timers = {}, {}
GoblinGamblingFrame, GoblinGamblingMinimapButton = nil, nil
UISpecialFrames = {}
local GG2 = M.loadAddon({})
GoblinGamblingDB = saved
M.fireEvent("ADDON_LOADED", "GoblinGambling")
M.fireEvent("PLAYER_LOGIN")
H.eq(GG2:GetBalance(), 1000 - 337, "balance survives reload")
H.eq(GG2.db.settings.minimap.angle, 45, "settings survive reload")
H.eq(GG2.db.stats.biggestWinMult, 0, "missing key filled on load")
H.eq(GG2.db.settings.windowPos.x, 123, "position survives reload")
H.eq(GG2.db.settings.windowScale, 1.25, "size survives reload")
GG2:ShowWindow()
H.eq(GoblinGamblingFrame:GetScale(), 1.25, "window opens at the saved size")

-- Corrupt balance gets repaired, not crashed on
M.frames = {}
local GG3 = M.loadAddon({})
GoblinGamblingDB = { balance = "lots", settings = "broken" }
M.fireEvent("ADDON_LOADED", "GoblinGambling")
H.eq(GG3:GetBalance(), 0, "junk balance repaired")
H.eq(type(GG3.db.settings), "table", "junk settings replaced")
H.eq(GG3.db.settings.sound, true, "junk settings get defaults")

M.realPrint(string.format("test_ui_smoke: %d checks passed", H.passed))
