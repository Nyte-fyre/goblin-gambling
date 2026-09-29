-- Goblin Gambling Co. : shared UI helpers.
-- The formatting functions at the top are pure Lua (tested in tests/test_format.lua);
-- the widget builders below only run inside WoW.
local ADDON, GG = ...
GG = GG or {}

local floor = math.floor

------------------------------------------------------------------------
-- Formatting (pure)
------------------------------------------------------------------------

-- 1234567 -> "1,234,567"; -5000 -> "-5,000"
function GG.FormatNumber(n)
  n = floor((tonumber(n) or 0) + 0.5)
  local neg = n < 0
  local s = tostring(neg and -n or n)
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return (neg and "-" or "") .. out
end

GG.GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"

-- "1,234 [coin]" in gold text.
function GG.FormatGold(n)
  return "|cffffd100" .. GG.FormatNumber(n) .. "|r" .. GG.GOLD_ICON
end

------------------------------------------------------------------------
-- Tooltips
------------------------------------------------------------------------
function GG.AttachTooltip(frame, title, body)
  frame:HookScript("OnEnter", function(self)
    local t, b = title, body
    if type(t) == "function" then t = t(self) end
    if type(b) == "function" then b = b(self) end
    if not t then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(t, 1, 0.82, 0)
    if b then GameTooltip:AddLine(b, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

------------------------------------------------------------------------
-- Buttons and checkboxes (own frames, standard non-secure templates)
------------------------------------------------------------------------
function GG.CreateButton(parent, text, width, height, onClick, tipTitle, tipBody)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 100, height or 22)
  b:SetText(text)
  b:SetScript("OnClick", function(self, ...)
    GG:PlaySound("click")
    if onClick then onClick(self, ...) end
  end)
  if tipTitle then GG.AttachTooltip(b, tipTitle, tipBody) end
  return b
end

-- get() returns the current value; set(value) stores it.
function GG.CreateCheckbox(parent, label, get, set, tipTitle, tipBody)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 0, 1)
  fs:SetText(label)
  cb.label = fs
  cb:SetHitRectInsets(0, -fs:GetStringWidth() - 4, 0, 0)
  cb:SetScript("OnClick", function(self)
    GG:PlaySound("click")
    set(self:GetChecked() and true or false)
  end)
  function cb:Refresh() self:SetChecked(get() and true or false) end
  cb:Refresh()
  if tipTitle then GG.AttachTooltip(cb, tipTitle, tipBody) end
  return cb
end

-- Solid-colour texture, used for dividers and highlights.
function GG.CreateLine(parent, r, g, b, a)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(r or 1, g or 0.82, b or 0, a or 0.35)
  return t
end
