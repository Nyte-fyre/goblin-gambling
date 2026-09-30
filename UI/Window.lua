-- Goblin Gambling Co. : main window, tabs, balance bar, minimap button.
-- Own frames only; nothing here hooks or replaces Blizzard UI.
local ADDON, GG = ...

local WIDTH, HEIGHT = 520, 420
local Backdrop = BackdropTemplateMixin and "BackdropTemplate" or nil

------------------------------------------------------------------------
-- Tab panels. Game files register a builder; the panel is built the first
-- time its tab is opened. Tabs without a builder show their placeholder.
------------------------------------------------------------------------
GG.TABS = {
  { key = "slots", label = "Slots",
    placeholder = "The slot machine is still being bolted together by goblin engineers.\n\nPlease stand well back." },
  { key = "poker", label = "Poker",
    placeholder = "Coming soon, the dealer is at the Auction House.\n\nHe said he'd be five minutes. That was two expansions ago." },
  { key = "stats", label = "Stats",
    placeholder = "The accountant is still counting your losses.\n\nIt's taking a while." },
}

local builders = {}
function GG:RegisterPanel(key, builder)
  builders[key] = builder
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
local frame, content, tabButtons, panels, currentTab
local balanceText, debtText

local function SavePosition()
  local point, _, relativePoint, x, y = frame:GetPoint(1)
  local pos = GG.db.settings.windowPos
  pos.point, pos.relativePoint, pos.x, pos.y = point, relativePoint, x, y
end

local function RestorePosition()
  local pos = GG.db.settings.windowPos
  frame:ClearAllPoints()
  frame:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or pos.point or "CENTER", pos.x or 0, pos.y or 0)
end

local function ApplyBackdrop(f, dark)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = dark and "Interface\\DialogFrame\\UI-DialogBox-Background-Dark"
                     or "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  else
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.04, 0.02, 0.92)
  end
end

------------------------------------------------------------------------
-- Balance bar: counts up/down to the real balance. A game can freeze it
-- (the money is already credited) and release it when its animation ends.
------------------------------------------------------------------------
local shown, target, tweenFrom, tweenTime, frozen = 0, 0, 0, 0, false
local TWEEN = 0.8

local function RenderBalance()
  if not balanceText then return end
  balanceText:SetText("Goblin Gold: " .. GG.FormatGold(shown))
  local debt = GG:GetDebt()
  if debt > 0 then
    debtText:SetText("|cffff5555Owed to Grubnik: " .. GG.FormatNumber(debt) .. "|r")
    debtText:Show()
  else
    debtText:Hide()
  end
end

local function StartTween(newTarget)
  tweenFrom, target, tweenTime = shown, newTarget, 0
end

local function TickBalance(_, elapsed)
  if shown == target then return end
  tweenTime = tweenTime + elapsed
  local p = math.min(tweenTime / TWEEN, 1)
  p = 1 - (1 - p) * (1 - p) -- ease out
  shown = math.floor(tweenFrom + (target - tweenFrom) * p + 0.5)
  if p >= 1 then shown = target end
  RenderBalance()
end

function GG:FreezeBalanceDisplay() frozen = true end

function GG:ReleaseBalanceDisplay()
  frozen = false
  StartTween(GG:GetBalance())
end

GG:On("BALANCE_CHANGED", function(new, old)
  if frozen then return end
  -- Losing money snaps; winning counts up.
  if new < shown then
    shown, target = new, new
    RenderBalance()
  else
    StartTween(new)
  end
end)

------------------------------------------------------------------------
-- Win flash: a brief coloured glow over the whole window.
------------------------------------------------------------------------
function GG:FlashWindow(r, g, b)
  if not frame or not frame.flash then return end
  frame.flash:SetColorTexture(r or 1, g or 0.82, b or 0, 1)
  frame.flashAnim:Stop()
  frame.flashAnim:Play()
end

------------------------------------------------------------------------
-- Tabs
------------------------------------------------------------------------
function GG:SelectTab(key)
  if not frame then return end
  if currentTab ~= key then GG:PlaySound("tab") end
  currentTab = key
  GG.db.settings.lastTab = key
  for _, tab in ipairs(GG.TABS) do
    local btn, isSel = tabButtons[tab.key], tab.key == key
    if isSel then btn:LockHighlight() else btn:UnlockHighlight() end
    btn.underline:SetShown(isSel)

    if isSel and not panels[tab.key] then
      local p = CreateFrame("Frame", nil, content)
      p:SetAllPoints()
      if builders[tab.key] then
        builders[tab.key](p)
      else
        local fs = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
        fs:SetPoint("CENTER")
        fs:SetWidth(WIDTH - 80)
        fs:SetText(tab.placeholder)
      end
      panels[tab.key] = p
    end
    if panels[tab.key] then panels[tab.key]:SetShown(isSel) end
  end
  GG:Fire("TAB_CHANGED", key)
end

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
local function Build()
  frame = CreateFrame("Frame", "GoblinGamblingFrame", UIParent, Backdrop)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  ApplyBackdrop(frame, true)
  RestorePosition()
  frame:Hide()
  tinsert(UISpecialFrames, "GoblinGamblingFrame") -- Esc closes it

  -- Title bar (drag handle)
  local titleBar = CreateFrame("Frame", nil, frame)
  titleBar:SetPoint("TOPLEFT", 12, -10)
  titleBar:SetPoint("TOPRIGHT", -34, -10)
  titleBar:SetHeight(28)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
  titleBar:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    SavePosition()
  end)

  local icon = titleBar:CreateTexture(nil, "ARTWORK")
  icon:SetSize(22, 22)
  icon:SetPoint("LEFT", 6, 0)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")

  local title = titleBar:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
  title:SetText(GG.NAME)

  local sub = titleBar:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
  sub:SetText("Fake gold. Real regret.")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  -- Tabs
  tabButtons, panels = {}, {}
  local prev
  for _, tab in ipairs(GG.TABS) do
    local b = GG.CreateButton(frame, tab.label, 96, 24, function() GG:SelectTab(tab.key) end)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 20, -42) end
    local ul = GG.CreateLine(b, 1, 0.82, 0, 0.9)
    ul:SetPoint("BOTTOMLEFT", 6, -3)
    ul:SetPoint("BOTTOMRIGHT", -6, -3)
    ul:SetHeight(2)
    b.underline = ul
    tabButtons[tab.key] = b
    prev = b
  end

  local topRule = GG.CreateLine(frame)
  topRule:SetPoint("TOPLEFT", 16, -72)
  topRule:SetPoint("TOPRIGHT", -16, -72)
  topRule:SetHeight(1)

  -- Content area between the tabs and the balance bar
  content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", 16, -76)
  content:SetPoint("BOTTOMRIGHT", -16, 44)

  -- Balance bar
  local bar = CreateFrame("Frame", nil, frame)
  bar:SetPoint("BOTTOMLEFT", 16, 12)
  bar:SetPoint("BOTTOMRIGHT", -16, 12)
  bar:SetHeight(30)

  local botRule = GG.CreateLine(bar)
  botRule:SetPoint("TOPLEFT")
  botRule:SetPoint("TOPRIGHT")
  botRule:SetHeight(1)

  balanceText = bar:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  balanceText:SetPoint("LEFT", 6, -2)
  debtText = bar:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  debtText:SetPoint("RIGHT", -6, -2)

  local balanceHover = CreateFrame("Frame", nil, bar)
  balanceHover:SetAllPoints(balanceText)
  GG.AttachTooltip(balanceHover, "Goblin Gold",
    "Fake casino money. It is not your real gold and cannot become real gold. "
    .. "The goblins are very clear about this, legally.")

  bar:SetScript("OnUpdate", TickBalance)

  -- Flash overlay
  local flash = frame:CreateTexture(nil, "OVERLAY")
  flash:SetPoint("TOPLEFT", 12, -12)
  flash:SetPoint("BOTTOMRIGHT", -12, 12)
  flash:SetBlendMode("ADD")
  flash:SetAlpha(0)
  frame.flash = flash
  local ag = flash:CreateAnimationGroup()
  local fadeIn = ag:CreateAnimation("Alpha")
  fadeIn:SetFromAlpha(0); fadeIn:SetToAlpha(0.35); fadeIn:SetDuration(0.12); fadeIn:SetOrder(1)
  local fadeOut = ag:CreateAnimation("Alpha")
  fadeOut:SetFromAlpha(0.35); fadeOut:SetToAlpha(0); fadeOut:SetDuration(0.45); fadeOut:SetOrder(2)
  frame.flashAnim = ag

  frame:SetScript("OnShow", function()
    GG:PlaySound("open")
    shown, target = GG:GetBalance(), GG:GetBalance()
    RenderBalance()
    GG:Fire("WINDOW_SHOWN")
  end)
  frame:SetScript("OnHide", function()
    GG:PlaySound("close")
    GG:Fire("WINDOW_HIDDEN")
  end)

  GG.frame = frame
  local last = GG.db.settings.lastTab
  local valid = false
  for _, tab in ipairs(GG.TABS) do if tab.key == last then valid = true end end
  GG:SelectTab(valid and last or "slots")
end

function GG:ToggleWindow()
  if not frame then Build() end
  frame:SetShown(not frame:IsShown())
end

function GG:ShowWindow()
  if not frame then Build() end
  frame:Show()
end

------------------------------------------------------------------------
-- Minimap button (own implementation, no LibDBIcon)
------------------------------------------------------------------------
local mmButton

local function PositionMinimapButton()
  local angle = math.rad(GG.db.settings.minimap.angle or 200)
  local radius = (Minimap:GetWidth() / 2) + 5
  mmButton:ClearAllPoints()
  mmButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragUpdate()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  local atan2 = math.atan2 or math.atan
  GG.db.settings.minimap.angle = math.deg(atan2(py - my, px - mx)) % 360
  PositionMinimapButton()
end

function GG:CreateMinimapButton()
  if mmButton then return end
  mmButton = CreateFrame("Button", "GoblinGamblingMinimapButton", Minimap)
  mmButton:SetSize(31, 31)
  mmButton:SetFrameStrata("MEDIUM")
  mmButton:SetFrameLevel(8)
  mmButton:RegisterForClicks("AnyUp")
  mmButton:RegisterForDrag("LeftButton")
  mmButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = mmButton:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

  local icon = mmButton:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  local border = mmButton:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  mmButton:SetScript("OnClick", function() GG:ToggleWindow() end)
  mmButton:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", DragUpdate) end)
  mmButton:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  GG.AttachTooltip(mmButton, GG.NAME, function()
    return "Goblin Gold: " .. GG.FormatGold(GG:GetBalance())
      .. "\n\n|cff00ff00Click|r to open the casino\n|cff00ff00Drag|r to move this button"
      .. "\n|cff888888/gg minimap hides it|r"
  end)

  GG:UpdateMinimapButton()
end

function GG:UpdateMinimapButton()
  if not mmButton then return end
  if GG.db.settings.minimap.hide then
    mmButton:Hide()
  else
    PositionMinimapButton()
    mmButton:Show()
  end
end
