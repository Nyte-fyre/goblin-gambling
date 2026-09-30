-- Goblin Gambling Co. : slot machine tab.
-- The result of a spin is decided, debited and credited the instant Spin is
-- clicked; the reels then animate to that predetermined outcome. Closing the
-- window mid-spin just skips the animation, so nothing can be duped or lost.
local ADDON, GG = ...

local Logic = GG.SlotsLogic
local cfg = Logic.config
local Backdrop = BackdropTemplateMixin and "BackdropTemplate" or nil
local floor = math.floor

local CELL = 50          -- height of one reel row
local ICON = 44          -- symbol icon size
local REEL_W = 72
local REEL_GAP = 10

-- Reel speeds. base = seconds until reel 1 stops, stagger = extra seconds
-- per later reel, loops = full turns reel 1 makes, pause = seconds between
-- autospins (scaled by settings.autospinDelay, 0.4 = as listed).
local SPEEDS = {
  { key = "slow",   name = "Riding Turtle", base = 2.0,  stagger = 0.7,  loops = 4, pause = 0.9, pace = 1.6,
    desc = "Slow and dramatic. Every reel takes its sweet time. Feel the tension. Feel the shell." },
  { key = "medium", name = "Kodo Trot",     base = 0.9,  stagger = 0.35, loops = 2, pause = 0.4, pace = 1,
    desc = "The standard goblin experience. Brisk, but you still get to watch." },
  { key = "fast",   name = "Rocket Boots",  base = 0.45, stagger = 0.15, loops = 1, pause = 0.2, pace = 0.5,
    desc = "Goblin engineering at its finest. Fast, loud, occasionally on fire." },
}
local SPEED_BY_KEY = {}
for i, sp in ipairs(SPEEDS) do sp.index = i; SPEED_BY_KEY[sp.key] = sp end

local function CurrentSpeed()
  return SPEED_BY_KEY[GG.db.settings.slotsSpeed] or SPEED_BY_KEY.medium
end
local HISTORY = 7        -- lines in the recent results list

local TIER_COLOR = {
  loss    = { 0.75, 0.75, 0.75 },
  small   = { 0.3, 1, 0.3 },
  big     = { 0.64, 0.21, 0.93 },   -- epic purple
  jackpot = { 1, 0.5, 0 },          -- legendary orange
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local ui            -- widgets, built on first open of the tab
local reels = {}
local spinning = false
local pending       -- result of the spin currently animating
local autospin = false
local autospinGen = 0
local session = { spins = 0, net = 0, lastWin = 0 }
local history = {}

local driver = CreateFrame("Frame")  -- runs the reel animation; not tied to tab visibility

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function Icon(sym)
  local s = Logic.SYMBOLS[sym]
  return s and s.icon or Logic.FALLBACK_ICON
end

local function SetIcon(tex, path)
  if tex:SetTexture(path) == false then tex:SetTexture(Logic.FALLBACK_ICON) end
end

local function CurrentBet()
  local b = GG.db.settings.slotsBet
  if b == "max" then
    return math.min(GG:GetBalance(), Logic.MAX_BET)
  end
  return tonumber(b) or Logic.MIN_BET
end

local function Pick(list)
  return list[math.random(#list)]
end

------------------------------------------------------------------------
-- Reels
------------------------------------------------------------------------
local function RenderReel(reel)
  local pos = reel.pos
  local base = floor(pos)
  local frac = pos - base
  for k = -1, 2 do
    local tex = reel.tex[k]
    local idx = base + k
    local sym = Logic.SymbolAt(reel.strip, idx, 0)
    if tex.sym ~= sym then
      SetIcon(tex, Icon(sym))
      tex.sym = sym
    end
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", reel.view, "CENTER", 0, -(k - frac) * CELL)
  end
end

local function BuildReel(parent, index)
  local reel = { strip = cfg.reels[index], pos = math.random(#cfg.reels[index]), tex = {} }

  local box = CreateFrame("Frame", nil, parent, Backdrop)
  box:SetSize(REEL_W, CELL * 3)
  if box.SetBackdrop then
    box:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    box:SetBackdropColor(0.08, 0.06, 0.03, 1)
    box:SetBackdropBorderColor(0.8, 0.65, 0.2, 1)
  end
  box:SetClipsChildren(true)
  reel.box = box

  local view = CreateFrame("Frame", nil, box)
  view:SetPoint("TOPLEFT", 4, -4)
  view:SetPoint("BOTTOMRIGHT", -4, 4)
  view:SetClipsChildren(true)
  reel.view = view

  for k = -1, 2 do
    local t = view:CreateTexture(nil, "ARTWORK")
    t:SetSize(ICON, ICON)
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    reel.tex[k] = t
  end

  -- Dim the rows that are not on the payline.
  for _, anchor in ipairs({ "TOP", "BOTTOM" }) do
    local shade = view:CreateTexture(nil, "OVERLAY")
    shade:SetColorTexture(0, 0, 0, 0.55)
    shade:SetPoint(anchor .. "LEFT")
    shade:SetPoint(anchor .. "RIGHT")
    shade:SetHeight(CELL - 4)
  end

  RenderReel(reel)
  return reel
end

local Finish -- forward

local function AnimateReels(_, elapsed)
  local allDone = true
  for i, reel in ipairs(reels) do
    if not reel.done then
      reel.t = reel.t + elapsed
      local x = math.min(reel.t / reel.dur, 1)
      local e = 1 - (1 - x) ^ 3        -- ease out: fast start, slow landing
      reel.pos = reel.startPos - reel.travel * e
      if x >= 1 then
        reel.pos = reel.target
        reel.done = true
        GG:PlaySound("reelStop")
      else
        allDone = false
      end
      RenderReel(reel)
    end
  end
  if allDone then Finish(false) end
end

local function StartReels(stops)
  for i, reel in ipairs(reels) do
    local n = #reel.strip
    local target = stops[i]
    -- Reels move downward (pos decreases). Travel whole loops plus the
    -- distance to the target stop so it lands exactly on it.
    local toTarget = (reel.pos - target) % n
    reel.startPos = reel.pos
    reel.target = target
    local speed = CurrentSpeed()
    reel.travel = toTarget + n * (speed.loops + i)
    reel.dur = speed.base + speed.stagger * (i - 1)
    reel.t = 0
    reel.done = false
  end
  driver:SetScript("OnUpdate", AnimateReels)
end

------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------
local function UpdateControls()
  if not ui then return end
  local sel = GG.db.settings.slotsBet
  for _, b in ipairs(ui.betButtons) do
    if b.value == sel then b:LockHighlight() else b:UnlockHighlight() end
    b.underline:SetShown(b.value == sel)
  end

  local bet = CurrentBet()
  local spin = ui.spin
  if spinning then
    spin:SetText("Spinning...")
    spin:Disable()
  elseif GG:IsBroke() then
    spin:SetText("Visit Grubnik")
    spin:Enable()
  elseif not GG:CanAfford(bet) then
    spin:SetText("Can't afford")
    spin:Disable()
  else
    spin:SetText("Spin (" .. GG.FormatNumber(bet) .. ")")
    spin:Enable()
  end

  ui.autospin:SetChecked(autospin)
  ui.speed:SetText("Speed: " .. CurrentSpeed().name)
  ui.sound:Refresh()

  local net = session.net
  local netColor = net > 0 and "|cff33ff33+" or (net < 0 and "|cffff5555" or "|cffffffff")
  ui.sessionText:SetText(
    "|cffffd100This session|r\n"
    .. "Spins: " .. GG.FormatNumber(session.spins) .. "\n"
    .. "Net: " .. netColor .. GG.FormatNumber(net) .. "|r\n"
    .. "Last win: " .. GG.FormatNumber(session.lastWin))
end

local function StopAutospin(reason)
  if autospin and reason and ui then
    ui.detail:SetText("|cffffd100Autospin stopped:|r " .. reason)
  end
  autospin = false
  autospinGen = autospinGen + 1
  UpdateControls()
end

local function AddHistory(res)
  local line
  if res.payout == res.bet then
    line = "|cffccccccmoney back|r"
  elseif res.payout > 0 then
    local c = TIER_COLOR[res.tier]
    line = ("|cff%02x%02x%02x+%s (%sx)|r"):format(c[1] * 255, c[2] * 255, c[3] * 255,
      GG.FormatNumber(res.payout), GG.FormatNumber(res.mult))
  else
    line = "|cff888888-" .. GG.FormatNumber(res.bet) .. "|r"
  end
  table.insert(history, 1, line)
  history[HISTORY + 1] = nil
  if ui then
    ui.historyText:SetText("|cffffd100Recent|r\n" .. table.concat(history, "\n"))
  end
end

local function ShowResult(res)
  local c = TIER_COLOR[res.tier]
  ui.flavor:SetText(Pick(Logic.FLAVOR[res.tier]))
  ui.flavor:SetTextColor(c[1], c[2], c[3])
  if res.payout > 0 then
    ui.detail:SetText(("%s: won %s (%sx)"):format(res.label, GG.FormatGold(res.payout),
      GG.FormatNumber(res.mult)))
  else
    ui.detail:SetText("Bet " .. GG.FormatGold(res.bet) .. " gone. No win.")
  end
  ui.payline:SetAlpha(res.payout > 0 and 1 or 0.45)
end

local DoSpin -- forward

-- silent = true when the window closed mid-spin: snap, settle, no fanfare.
function Finish(silent)
  driver:SetScript("OnUpdate", nil)
  if not spinning then return end
  spinning = false
  local res = pending
  pending = nil
  GG.SlotsUI.lastResult = res

  for i, reel in ipairs(reels) do
    reel.pos, reel.done = res.stops[i], true
    RenderReel(reel)
  end

  GG:ReleaseBalanceDisplay()
  session.spins = session.spins + 1
  session.net = session.net + res.payout - res.bet
  if res.payout > res.bet then session.lastWin = res.payout end
  ShowResult(res)
  AddHistory(res)
  GG:Fire("STATS_CHANGED")

  if not silent then
    if res.tier == "jackpot" then
      GG:PlaySound("jackpot")
      for i = 0, 3 do C_Timer.After(i * 0.6, function() GG:FlashWindow(1, 0.5, 0) end) end
    elseif res.tier == "big" then
      GG:PlaySound("bigWin")
      GG:FlashWindow(0.64, 0.21, 0.93)
    elseif res.tier == "small" then
      GG:PlaySound("smallWin")
    else
      GG:PlaySound("loss")
    end
  end

  UpdateControls()

  if GG:IsBroke() then
    StopAutospin("you are broke.")
    if not silent then
      C_Timer.After(0.8, function()
        if GG:IsBroke() and GG.frame and GG.frame:IsShown() then GG:ShowLoanShark() end
      end)
    end
  elseif autospin then
    if res.tier == "big" or res.tier == "jackpot" then
      StopAutospin("big win! Take a moment to gloat.")
    elseif not GG:CanAfford(CurrentBet()) then
      StopAutospin("not enough Goblin Gold for that bet.")
    else
      local gen = autospinGen
      local pause = CurrentSpeed().pause * ((GG.db.settings.autospinDelay or 0.4) / 0.4)
      C_Timer.After(pause, function()
        if autospin and gen == autospinGen and not spinning
           and GG.frame and GG.frame:IsShown() then
          DoSpin()
        end
      end)
    end
  end
end

function DoSpin()
  if spinning then return end
  if GG:IsBroke() then
    StopAutospin()
    GG:ShowLoanShark()
    return
  end
  local bet = CurrentBet()
  if not GG:CanAfford(bet) then
    StopAutospin("not enough Goblin Gold for that bet.")
    return
  end

  -- Settle the money now; the animation is just theatre.
  local res = Logic.Spin(bet)
  GG:Debit(bet)
  GG:FreezeBalanceDisplay()
  if res.payout > 0 then GG:Credit(res.payout) end
  GG:RecordRound("spin", bet, res.payout)

  pending = res
  spinning = true
  ui.flavor:SetText("The reels are spinning...")
  ui.flavor:SetTextColor(1, 0.82, 0)
  ui.detail:SetText("Bet " .. GG.FormatGold(bet) .. (autospin and "  |cff888888(autospin)|r" or ""))
  ui.payline:SetAlpha(0.45)
  GG:PlaySound("spin")
  StartReels(res.stops)
  UpdateControls()
end

------------------------------------------------------------------------
-- Paytable (pops out to the right of the main window)
------------------------------------------------------------------------
local function PaytableRows()
  local rows = {}
  for _, id in ipairs(Logic.SYMBOL_ORDER) do
    local s = Logic.SYMBOLS[id]
    local body = s.tip .. "\n\n|cffffd100Three on the payline pays " .. cfg.pays[id] .. "x your bet.|r"
    if id ~= "WILD" and id ~= "JACKPOT" then
      body = body .. "\nHearthstones count as this symbol."
    end
    rows[#rows + 1] = { icons = { id, id, id }, mult = cfg.pays[id], title = s.name .. " (" .. s.role .. ")", body = body }
  end
  local wildName, jackName = Logic.Name("WILD"), Logic.Name("JACKPOT")
  rows[#rows + 1] = { icons = { "WILD", "WILD", "ANY" }, mult = cfg.allButOneWild,
    title = "Two " .. wildName .. "s + anything",
    body = "Two Hearthstones and any third symbol. Pays " .. cfg.allButOneWild .. "x, or more if the third one makes a better three of a kind." }
  rows[#rows + 1] = { icons = { "JACKPOT", "JACKPOT", "ANY" }, mult = cfg.jackpotPartial[2],
    title = jackName .. " x2",
    body = "So close. The goblin pats your shoulder and hands you " .. cfg.jackpotPartial[2] .. "x your bet." }
  rows[#rows + 1] = { icons = { "JACKPOT", "ANY", "ANY" }, mult = cfg.jackpotPartial[1],
    title = "One " .. jackName,
    body = "Any single Thunderfury gives your bet back. You only found one binding. The goblin considers this charity." }
  return rows
end

local function BuildPaytable()
  local f = CreateFrame("Frame", nil, GG.frame, Backdrop)
  f:SetSize(230, 420)
  f:SetPoint("TOPLEFT", GG.frame, "TOPRIGHT", -4, 0)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  end
  f:EnableMouse(true)

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -18)
  title:SetText("Paytable")

  local y = -46
  for _, row in ipairs(PaytableRows()) do
    local r = CreateFrame("Frame", nil, f)
    r:SetPoint("TOPLEFT", 18, y)
    r:SetPoint("TOPRIGHT", -18, y)
    r:SetHeight(22)
    r:EnableMouse(true)
    local hl = r:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 0.82, 0, 0.12)
    hl:Hide()
    r:SetScript("OnEnter", function() hl:Show() end)
    r:SetScript("OnLeave", function() hl:Hide() end)
    for i, sym in ipairs(row.icons) do
      local t = r:CreateTexture(nil, "ARTWORK")
      t:SetSize(20, 20)
      t:SetPoint("LEFT", (i - 1) * 23, 0)
      t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      if sym == "ANY" then
        SetIcon(t, Logic.FALLBACK_ICON)
        t:SetDesaturated(true)
        t:SetAlpha(0.6)
      else
        SetIcon(t, Icon(sym))
      end
    end
    local m = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    m:SetPoint("RIGHT", -2, 0)
    m:SetText(row.mult .. "x")
    if row.mult >= cfg.bigWinMult then m:SetTextColor(0.64, 0.21, 0.93) end
    if row.icons[1] == "JACKPOT" and row.icons[3] == "JACKPOT" then m:SetTextColor(1, 0.5, 0) end
    GG.AttachTooltip(r, row.title, row.body)
    y = y - 24
  end

  local rtp = Logic.ComputeRTP()
  local note = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  note:SetPoint("BOTTOMLEFT", 18, 18)
  note:SetPoint("BOTTOMRIGHT", -18, 18)
  note:SetJustifyH("LEFT")
  note:SetText(("Pays on the middle row. Hearthstone is wild, except for Thunderfury.\n"
    .. "Goblin-certified payback: %.1f%%. The house always wins, just slowly."):format(rtp * 100))

  f:SetShown(GG.db.settings.showPaytable)
  return f
end

------------------------------------------------------------------------
-- Build the tab
------------------------------------------------------------------------
local function BuildPanel(panel)
  ui = {}

  -- Reels, centred near the top
  local machineW = REEL_W * 3 + REEL_GAP * 2
  local machine = CreateFrame("Frame", nil, panel)
  machine:SetSize(machineW, CELL * 3)
  machine:SetPoint("TOP", 0, -10)
  for i = 1, #cfg.reels do
    local reel = BuildReel(machine, i)
    reel.box:SetPoint("LEFT", (i - 1) * (REEL_W + REEL_GAP), 0)
    reels[i] = reel
  end

  -- Payline: gold rails above and below the middle row, plus arrows.
  local payline = CreateFrame("Frame", nil, machine)
  payline:SetPoint("LEFT", -14, 0)
  payline:SetPoint("RIGHT", 14, 0)
  payline:SetHeight(CELL)
  payline:SetFrameLevel(machine:GetFrameLevel() + 10)
  for _, edge in ipairs({ "TOP", "BOTTOM" }) do
    local rail = GG.CreateLine(payline, 1, 0.82, 0, 0.9)
    rail:SetPoint(edge .. "LEFT", 10, 0)
    rail:SetPoint(edge .. "RIGHT", -10, 0)
    rail:SetHeight(2)
  end
  local left = payline:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  left:SetPoint("LEFT", -2, 0)
  left:SetText(">")
  local right = payline:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  right:SetPoint("RIGHT", 2, 0)
  right:SetText("<")
  payline:SetAlpha(0.45)
  ui.payline = payline

  -- Side columns: session on the left, recent results on the right
  ui.sessionText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.sessionText:SetPoint("TOPLEFT", 6, -14)
  ui.sessionText:SetWidth(110)
  ui.sessionText:SetJustifyH("LEFT")
  ui.sessionText:SetSpacing(3)

  ui.historyText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.historyText:SetPoint("TOPRIGHT", -6, -14)
  ui.historyText:SetWidth(112)
  ui.historyText:SetJustifyH("RIGHT")
  ui.historyText:SetSpacing(3)
  ui.historyText:SetWordWrap(false)
  ui.historyText:SetText("|cffffd100Recent|r\n" .. (#history > 0 and table.concat(history, "\n") or "|cff888888nothing yet|r"))

  -- Result lines
  ui.flavor = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  ui.flavor:SetPoint("TOP", machine, "BOTTOM", 0, -12)
  ui.flavor:SetWidth(460)
  ui.flavor:SetText("Step right up. Pull the lever. What could go wrong?")

  ui.detail = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.detail:SetPoint("TOP", ui.flavor, "BOTTOM", 0, -4)
  ui.detail:SetWidth(460)
  ui.detail:SetText("Pick a bet and hit Spin. Payouts go straight into your Goblin Gold.")

  -- Bet row
  local betLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  betLabel:SetPoint("BOTTOMLEFT", 10, 52)
  betLabel:SetText("Bet:")

  ui.betButtons = {}
  local prev
  local bets = {}
  for _, v in ipairs(Logic.BETS) do bets[#bets + 1] = v end
  bets[#bets + 1] = "max"
  for _, v in ipairs(bets) do
    local label = v == "max" and "Max" or GG.FormatNumber(v)
    local b = GG.CreateButton(panel, label, 58, 22, function(self)
      if spinning then return end
      GG.db.settings.slotsBet = self.value
      UpdateControls()
    end)
    b.value = v
    if v == "max" then
      GG.AttachTooltip(b, "Max bet", function()
        return "Bets everything you have, up to " .. GG.FormatNumber(Logic.MAX_BET)
          .. ". Right now that is " .. GG.FormatNumber(math.min(GG:GetBalance(), Logic.MAX_BET)) .. "."
      end)
    end
    local ul = GG.CreateLine(b, 1, 0.82, 0, 0.9)
    ul:SetPoint("BOTTOMLEFT", 6, -3)
    ul:SetPoint("BOTTOMRIGHT", -6, -3)
    ul:SetHeight(2)
    b.underline = ul
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("LEFT", betLabel, "RIGHT", 8, 0) end
    prev = b
    ui.betButtons[#ui.betButtons + 1] = b
  end

  ui.sound = GG.CreateCheckbox(panel, "Sound",
    function() return GG.db.settings.sound end,
    function(v) GG.db.settings.sound = v; GG:Fire("SETTINGS_CHANGED") end,
    "Sound", "Mute the goblins. They will keep yelling, you just won't hear it.")
  ui.sound:SetPoint("BOTTOMLEFT", 104, 10)

  ui.speed = GG.CreateButton(panel, "", 130, 22, function()
    local nextSpeed = SPEEDS[CurrentSpeed().index % #SPEEDS + 1]
    GG:SetSlotSpeed(nextSpeed.key)
  end)
  ui.speed:SetPoint("BOTTOMRIGHT", -8, 52)
  GG.AttachTooltip(ui.speed, function() return "Reel speed: " .. CurrentSpeed().name end, function()
    local lines = {}
    for _, sp in ipairs(SPEEDS) do
      local mark = sp == CurrentSpeed() and "|cff33ff33> |r" or "   "
      lines[#lines + 1] = mark .. "|cffffd100" .. sp.name .. "|r: " .. sp.desc
    end
    return table.concat(lines, "\n\n") .. "\n\n|cff888888Click to change. Takes effect on the next spin.|r"
  end)

  -- Bottom row: autospin, SPIN, paytable
  ui.spin = GG.CreateButton(panel, "Spin", 150, 32, function()
    DoSpin()
  end)
  ui.spin:SetPoint("BOTTOM", 0, 6)

  ui.autospin = GG.CreateCheckbox(panel, "Autospin",
    function() return autospin end,
    function(v)
      if v then
        autospin = true
        if not spinning then DoSpin() end
      else
        StopAutospin()
      end
      UpdateControls()
    end,
    "Autospin", "Keeps spinning until you win big, run low on Goblin Gold, or close the window.")
  ui.autospin:SetPoint("BOTTOMLEFT", 8, 10)

  ui.paytableButton = GG.CreateButton(panel, "Paytable", 90, 22, function()
    if not ui.paytable then ui.paytable = BuildPaytable() end
    local show = not ui.paytable:IsShown()
    ui.paytable:SetShown(show)
    GG.db.settings.showPaytable = show
  end, "Paytable", "What pays, and how much. Hover a row for details.")
  ui.paytableButton:SetPoint("BOTTOMRIGHT", -8, 10)

  if GG.db.settings.showPaytable then ui.paytable = BuildPaytable() end

  UpdateControls()
end

GG:RegisterPanel("slots", BuildPanel)

GG.SLOT_SPEEDS = SPEEDS

-- Poker uses the same speed setting: a multiplier on its pauses.
function GG:GetPace()
  return CurrentSpeed().pace or 1
end

-- key: "slow" | "medium" | "fast". Returns the speed, or nil if unknown.
function GG:SetSlotSpeed(key)
  local sp = SPEED_BY_KEY[key]
  if not sp then return nil end
  GG.db.settings.slotsSpeed = key
  UpdateControls()
  return sp
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
GG:On("BALANCE_CHANGED", UpdateControls)
GG:On("SETTINGS_CHANGED", UpdateControls)

GG:On("WINDOW_HIDDEN", function()
  StopAutospin()
  if spinning then Finish(true) end
end)

GG:On("TAB_CHANGED", function(key)
  if key ~= "slots" then StopAutospin() end
  -- The paytable hangs off the main window, so follow the Slots tab by hand.
  -- showPaytable remembers whether it was open, so it comes back with the tab.
  if not ui then return end
  if key == "slots" then
    if GG.db.settings.showPaytable then
      if not ui.paytable then ui.paytable = BuildPaytable() end
      ui.paytable:Show()
    end
  elseif ui.paytable then
    ui.paytable:Hide()
  end
end)

-- Exposed for tests.
GG.SlotsUI = {
  Spin = function() DoSpin() end,
  IsSpinning = function() return spinning end,
  SetAutospin = function(v) if v then autospin = true else StopAutospin() end end,
  IsAutospin = function() return autospin end,
  Session = session,
  CurrentBet = CurrentBet,
  CurrentSpeed = CurrentSpeed,
  -- Symbols the reels are currently showing on the payline.
  PaylineSymbols = function()
    local out = {}
    for i, reel in ipairs(reels) do out[i] = Logic.SymbolAt(reel.strip, floor(reel.pos + 0.5), 0) end
    return out
  end,
}
