-- Goblin Gambling Co. : Stats tab (lifetime numbers, title, title progress).
local ADDON, GG = ...

local Stats = GG.Stats
local FN = function(n) return GG.FormatNumber(n) end

local ui

local function Colored(n, text)
  if n > 0 then return "|cff33ff33+" .. text .. "|r" end
  if n < 0 then return "|cffff5555" .. text .. "|r" end
  return text
end

-- Label / value rows, left column. Each returns the value text.
local ROWS = {
  { "Goblin Gold",           function(s) return GG.FormatGold(GG:GetBalance()) end },
  { "Lifetime wagered",    function(s) return FN(s.totalWagered) end },
  { "Lifetime won",        function(s) return FN(s.totalWon) end },
  { "Net",                 function(s) local n = Stats.Net(s) return Colored(n, FN(n)) end },
  { "Biggest win",         function(s)
      if s.biggestWin <= 0 then return "|cff888888none yet|r" end
      return FN(s.biggestWin) .. (" |cff888888(%sx)|r"):format(FN(s.biggestWinMult))
    end },
  { "Spins played",        function(s) return FN(s.spins) end },
  { "Poker hands",         function(s) return FN(s.hands) end },
  { "Current streak",      function(s)
      if s.curWinStreak > 0 then return "|cff33ff33" .. s.curWinStreak .. (s.curWinStreak == 1 and " win" or " wins") .. "|r" end
      if s.curLoseStreak > 0 then return "|cffff5555" .. s.curLoseStreak .. (s.curLoseStreak == 1 and " loss" or " losses") .. "|r" end
      return "|cff888888-|r"
    end },
  { "Longest win streak",  function(s) return FN(s.maxWinStreak) end },
  { "Longest lose streak", function(s) return FN(s.maxLoseStreak) end },
  { "Bailouts taken",      function(s) return FN(s.bailouts) end },
  { "Owed to Grubnik",     function(s)
      local d = GG:GetDebt()
      return d > 0 and ("|cffff5555" .. FN(d) .. "|r") or "|cff33ff33nothing|r"
    end },
}

-- "With friends" view: multiplayer Hold'em only.
local function Pct(part, whole)
  if whole <= 0 then return "" end
  return (" |cff888888(%d%%)|r"):format(math.floor(part / whole * 100 + 0.5))
end

local MP_ROWS = {
  left = {
    { "Hands played",   function(m) return FN(m.hands) end },
    { "Pots won",       function(m) return FN(m.potsWon) .. Pct(m.potsWon, m.hands) end },
    { "Showdowns won",  function(m) return FN(m.showdownsWon) end },
    { "Biggest pot",    function(m) return m.biggestPot > 0 and FN(m.biggestPot) or "|cff888888none yet|r" end },
  },
  right = {
    { "Wagered",        function(m) return FN(m.wagered) end },
    { "Won",            function(m) return FN(m.won) end },
    { "Net",            function(m) local n = m.won - m.wagered return Colored(n, FN(n)) end },
    { "Tables hosted",  function(m) return FN(m.hosted) end },
    { "Tables joined",  function(m) return FN(m.joined) end },
  },
}

local function RefreshFriends()
  local m = GG.db.stats.mp or Stats.New().mp
  for side, rows in pairs(MP_ROWS) do
    for i, row in ipairs(rows) do ui.mpValues[side][i]:SetText(row[2](m)) end
  end
  ui.mpEmpty:SetShown(m.hands == 0)
end

local function ShowView(key)
  GG.db.settings.statsView = key
  ui.all:SetShown(key ~= "friends")
  ui.friends:SetShown(key == "friends")
  for _, b in ipairs(ui.viewButtons) do
    if b.key == key then b:LockHighlight() else b:UnlockHighlight() end
    b.underline:SetShown(b.key == key)
  end
end

local function Refresh()
  if not ui then return end
  RefreshFriends()
  local s = GG.db.stats
  local title, desc = Stats.GetTitle(s)
  ui.title:SetText(title)
  ui.titleDesc:SetText(desc)

  for i, row in ipairs(ROWS) do
    ui.values[i]:SetText(row[2](s))
  end

  for i, p in ipairs(Stats.TitleProgress(s)) do
    local line = ui.titleLines[i]
    local isCurrent = p.title == title
    local name
    if isCurrent then
      name = "|cffffd100> " .. p.title .. "|r"
    elseif p.earned then
      name = "|cffffffff" .. p.title .. "|r |cff33ff33(earned)|r"
    else
      name = "|cff999999" .. p.title .. "|r"
    end
    line.name:SetText(name)
    if p.goal then
      local cur = math.min(p.cur, p.goal)
      line.bar:SetValue(cur / p.goal)
      line.bar:Show()
      line.progress:SetText(("%s / %s %s"):format(FN(math.floor(cur)), FN(p.goal), p.unit))
    else
      line.bar:Hide()
      line.progress:SetText("|cff888888always available|r")
    end
    line.frame.tipBody = p.desc
  end

  ui.repay:SetEnabled(GG:GetDebt() > 0 and GG:GetBalance() > 0)
end

local function BuildFriends(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints()
  local head = f:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
  head:SetPoint("TOP", 0, -4)
  head:SetText("Hold'em with friends")
  local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOP", head, "BOTTOM", 0, -3)
  sub:SetText("Hands at tables you hosted or joined. They also count in All games.")

  ui.mpValues = { left = {}, right = {} }
  for side, rows in pairs(MP_ROWS) do
    local x = side == "left" and 8 or 252
    local y = -70
    for i, row in ipairs(rows) do
      local l = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
      l:SetPoint("TOPLEFT", x, y)
      l:SetText(row[1])
      local v = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      v:SetPoint("TOPRIGHT", f, "TOPLEFT", x + 220, y)
      v:SetJustifyH("RIGHT")
      ui.mpValues[side][i] = v
      y = y - 22
    end
  end
  local divider = GG.CreateLine(f)
  divider:SetPoint("TOPLEFT", 240, -70)
  divider:SetSize(1, 106)

  ui.mpEmpty = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  ui.mpEmpty:SetPoint("TOP", 0, -196)
  ui.mpEmpty:SetText("No hands with friends yet. Poker tab, then Play with friends.")
  return f
end

local function BuildPanel(panel)
  ui = { values = {}, titleLines = {} }
  ui.friends = BuildFriends(panel)
  ui.all = CreateFrame("Frame", nil, panel)
  ui.all:SetAllPoints()
  local root = panel
  panel = ui.all

  -- Current title, big and centred
  local label = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  label:SetPoint("TOP", 0, -4)
  label:SetText("YOUR TITLE")
  ui.title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
  ui.title:SetPoint("TOP", label, "BOTTOM", 0, -2)
  ui.titleDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  ui.titleDesc:SetPoint("TOP", ui.title, "BOTTOM", 0, -3)
  ui.titleDesc:SetWidth(460)

  -- Left column: numbers
  local y = -70
  for i, row in ipairs(ROWS) do
    local l = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    l:SetPoint("TOPLEFT", 8, y)
    l:SetText(row[1])
    local v = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    v:SetPoint("TOPRIGHT", panel, "TOPLEFT", 228, y)
    v:SetJustifyH("RIGHT")
    ui.values[i] = v
    y = y - 16
  end

  local divider = GG.CreateLine(panel)
  divider:SetPoint("TOPLEFT", 240, -70)
  divider:SetSize(1, 190)

  -- Right column: title progress
  local head = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  head:SetPoint("TOPLEFT", 252, -68)
  head:SetText("Titles")
  y = -88
  for i = 1, #Stats.TITLES do
    local f = CreateFrame("Frame", nil, panel)
    f:SetPoint("TOPLEFT", 252, y)
    f:SetSize(224, 34)
    f:EnableMouse(true)
    local name = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    name:SetPoint("TOPLEFT")
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("TOPLEFT", 0, -15)
    bar:SetSize(224, 12)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(1, 0.7, 0)
    bar:SetMinMaxValues(0, 1)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    local progress = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progress:SetPoint("CENTER")
    local line = { frame = f, name = name, bar = bar, progress = progress }
    f.titleName = Stats.TITLES[i].title
    GG.AttachTooltip(f, function(self) return self.titleName end, function(self) return self.tipBody end)
    ui.titleLines[i] = line
    y = y - 36
  end

  -- Buttons (shared by both views)
  ui.repay = GG.CreateButton(root, "Pay Grubnik", 110, 22, function() GG:ShowRepay() end,
    "Pay Grubnik", "Pay back as much of your debt as your Goblin Gold covers. Asks first.")
  ui.repay:SetPoint("BOTTOMLEFT", 8, 4)

  local reset = GG.CreateButton(root, "Reset stats", 110, 22,
    function() StaticPopup_Show("GOBLINGAMBLING_RESET_STATS") end,
    "Reset stats", "Wipes all stats (both views) and your title. Goblin Gold and debt stay. Asks first.")
  reset:SetPoint("BOTTOMRIGHT", -8, 4)

  -- View switch, bottom centre
  ui.viewButtons = {}
  local views = { { key = "all", label = "All games" }, { key = "friends", label = "With friends" } }
  for i, v in ipairs(views) do
    local b = GG.CreateButton(root, v.label, 92, 22, function() ShowView(v.key) end)
    b:SetPoint("BOTTOM", root, "BOTTOM", (i - 1.5) * 96, 4)
    b.key = v.key
    local ul = GG.CreateLine(b, 1, 0.82, 0, 0.9)
    ul:SetPoint("BOTTOMLEFT", 6, -3); ul:SetPoint("BOTTOMRIGHT", -6, -3); ul:SetHeight(2)
    b.underline = ul
    ui.viewButtons[i] = b
  end

  root:SetScript("OnShow", Refresh)
  ShowView(GG.db.settings.statsView == "friends" and "friends" or "all")
  Refresh()
end

GG:RegisterPanel("stats", BuildPanel)

------------------------------------------------------------------------
-- Keep it fresh, and announce new titles (locally, never in chat).
------------------------------------------------------------------------
local function CheckTitle()
  if not GG.db then return end
  local title, desc = Stats.GetTitle(GG.db.stats)
  local last = GG.db.lastTitle
  GG.db.lastTitle = title
  if last and last ~= title and title ~= "Casual Adventurer" then
    GG.Say(("New title: |cffffd100%s|r. %s"):format(title, desc))
    GG:PlaySound("bigWin")
  end
end

GG:On("STATS_CHANGED", function()
  CheckTitle()
  Refresh()
end)
GG:On("BALANCE_CHANGED", Refresh)
