-- Minimal fake WoW API so UI files can execute outside the client.
-- It does not draw anything; it records scripts and state so tests can
-- drive clicks, drags, events and OnUpdate ticks and catch Lua errors.
local M = {}

M.printed = {}
M.sounds = {}
M.timers = {}
M.now = 1000

------------------------------------------------------------------------
-- Widget objects: any unknown method is a harmless no-op, so the mock
-- only needs to model the calls whose return values matter.
------------------------------------------------------------------------
local Widget = {}
local function noop() end

local function newWidget(kind, name, parent)
  local w = {
    _kind = kind, _name = name, _parent = parent, _scripts = {}, _hooks = {},
    _shown = true, _points = {}, _width = 100, _height = 20, _text = "",
    _checked = false, _events = {}, _alpha = 1, _highlightLocked = false,
  }
  setmetatable(w, Widget)
  if name then _G[name] = w end
  return w
end
M.newWidget = newWidget

Widget.__index = function(self, key)
  local m = rawget(Widget, key)
  if m then return m end
  return noop
end

function Widget:SetScript(which, fn) self._scripts[which] = fn end
function Widget:GetScript(which) return self._scripts[which] end
function Widget:HookScript(which, fn)
  self._hooks[which] = self._hooks[which] or {}
  table.insert(self._hooks[which], fn)
end
function Widget:Fire(which, ...)
  if self._scripts[which] then self._scripts[which](self, ...) end
  for _, fn in ipairs(self._hooks[which] or {}) do fn(self, ...) end
end

function Widget:Show()
  local was = self._shown
  self._shown = true
  if not was then self:Fire("OnShow") end
end
function Widget:Hide()
  local was = self._shown
  self._shown = false
  if was then self:Fire("OnHide") end
end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:IsShown() return self._shown end
function Widget:IsVisible()
  -- Visible only if this frame and every parent is shown, like WoW.
  local f = self
  while f do
    if not rawget(f, "_shown") then return false end
    f = rawget(f, "_parent")
  end
  return true
end

function Widget:SetPoint(...) table.insert(self._points, { ... }) end
function Widget:ClearAllPoints() self._points = {} end
function Widget:GetPoint(i)
  local p = self._points[i or 1]
  if not p then return nil end
  -- Normalise to (point, relativeTo, relativePoint, x, y)
  local point, rel, relPoint, x, y = p[1], p[2], p[3], p[4], p[5]
  if type(rel) == "number" then return point, UIParent, point, rel, relPoint end
  return point, rel or UIParent, relPoint or point, x or 0, y or 0
end
function Widget:SetSize(w, h) self._width, self._height = w, h end
function Widget:SetWidth(w) self._width = w end
function Widget:SetHeight(h) self._height = h end
function Widget:GetWidth() return self._width end
function Widget:GetHeight() return self._height end
function Widget:GetCenter() return 500, 400 end
function Widget:SetScale(s) self._scale = s end
function Widget:GetScale() return rawget(self, "_scale") or 1 end
function Widget:GetEffectiveScale() return rawget(self, "_scale") or 1 end
function Widget:GetLeft() return 100 end
function Widget:GetTop() return 500 end
function Widget:GetName() return self._name end
function Widget:GetParent() return self._parent end

function Widget:SetText(t) self._text = t end
function Widget:GetText() return self._text end
function Widget:SetFormattedText(fmt, ...) self._text = fmt:format(...) end
function Widget:GetStringWidth() return #tostring(self._text) * 6 end
function Widget:GetStringHeight() return 12 end
function Widget:SetChecked(v) self._checked = v and true or false end
function Widget:GetChecked() return self._checked end
function Widget:LockHighlight() self._highlightLocked = true end
function Widget:UnlockHighlight() self._highlightLocked = false end
function Widget:SetAlpha(a) self._alpha = a end
function Widget:GetAlpha() return self._alpha end
function Widget:Enable() self._enabled = true end
function Widget:Disable() self._enabled = false end
function Widget:SetEnabled(v) self._enabled = v and true or false end
function Widget:IsEnabled() return self._enabled ~= false end
function Widget:SetValue(v) self._value = v end
function Widget:GetValue() return self._value or 0 end
function Widget:SetMinMaxValues(a, b) self._min, self._max = a, b end
function Widget:GetMinMaxValues() return self._min or 0, self._max or 1 end
function Widget:GetFrameLevel() return 1 end
function Widget:IsMouseOver() return false end
function Widget:GetTexture() return self._texture end
function Widget:SetTexture(t) self._texture = t end

function Widget:RegisterEvent(e) self._events[e] = true end
function Widget:UnregisterEvent(e) self._events[e] = nil end
function Widget:UnregisterAllEvents() self._events = {} end

function Widget:CreateTexture(name) return newWidget("Texture", name, self) end
function Widget:CreateFontString(name) return newWidget("FontString", name, self) end
function Widget:CreateAnimationGroup(name)
  local g = newWidget("AnimationGroup", name, self)
  function g:CreateAnimation(kind) return newWidget(kind or "Animation", nil, self) end
  function g:Play() self._playing = true end
  function g:Stop() self._playing = false end
  function g:IsPlaying() return self._playing end
  return g
end
function Widget:CreateMaskTexture(name) return newWidget("MaskTexture", name, self) end

M.frames = {}
function CreateFrame(kind, name, parent, template)
  local f = newWidget(kind, name, parent)
  f._template = template
  if kind == "Frame" or kind == "Button" or kind == "CheckButton" or kind == "Slider" then
    -- New frames start shown in WoW.
    f._shown = true
  end
  table.insert(M.frames, f)
  return f
end

------------------------------------------------------------------------
-- Globals the addon uses
------------------------------------------------------------------------
UIParent = newWidget("Frame", "UIParent")
Minimap = newWidget("Frame", "Minimap")
Minimap._width = 140
GameTooltip = newWidget("GameTooltip", "GameTooltip")
function GameTooltip:SetOwner() end
function GameTooltip:AddLine() end
UISpecialFrames = {}
BackdropTemplateMixin = {}
SOUNDKIT = { LEVELUP = 888, IG_MAINMENU_OPEN = 850, IG_MAINMENU_CLOSE = 851 }
YES, NO = "Yes", "No"
StaticPopupDialogs = {}
M.popups = {}
function StaticPopup_Show(which, a, b)
  -- WoW always runs the dialog text through format(text, a, b), so a stray
  -- "%" in the text errors in game. Do the same here.
  local dialog = assert(StaticPopupDialogs[which], "unknown popup " .. tostring(which))
  local text = string.format(dialog.text, a or "", b or "")
  table.insert(M.popups, { which = which, a = a, b = b, text = text })
  return StaticPopupDialogs[which]
end
function PlaySound(id) table.insert(M.sounds, id) end
function GetTime() return M.now end
function time() return 1790000000 end
function GetCursorPosition() return M.cursorX or 600, M.cursorY or 400 end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
tinsert = table.insert
tremove = table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
SlashCmdList = {}
C_Timer = {
  After = function(delay, fn) table.insert(M.timers, { at = M.now + delay, fn = fn }) end,
}
function geterrorhandler() return function(err) error(err, 0) end end

-- Player identity, groups and hidden addon messages
M.player, M.realm = "Nyte", "Forever"
M.inGroup, M.inRaid, M.inGuild = false, false, false
M.addonSent = {}
function UnitName() return M.player end
function UnitFullName() return M.player, M.realm end
function GetNormalizedRealmName() return M.realm end
function IsInRaid() return M.inRaid end
function IsInGroup() return M.inGroup or M.inRaid end
function IsInGuild() return M.inGuild end
C_ChatInfo = {
  RegisterAddonMessagePrefix = function() return true end,
  SendAddonMessage = function(prefix, text, kind, target)
    table.insert(M.addonSent, { prefix = prefix, text = text, kind = kind, target = target })
    return 0
  end,
}
math.atan2 = math.atan2 or math.atan

local realPrint = print
M.quiet = true
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  table.insert(M.printed, table.concat(parts, " "))
  if not M.quiet then realPrint(...) end
end
M.realPrint = realPrint

------------------------------------------------------------------------
-- Driving helpers
------------------------------------------------------------------------

-- Advance fake time: run OnUpdate on every shown frame and fire due timers.
function M.advance(seconds, step)
  step = step or 0.05
  local t = 0
  while t < seconds - 1e-9 do
    M.now = M.now + step
    t = t + step
    for _, f in ipairs(M.frames) do
      local fn = f._scripts.OnUpdate
      if fn and f:IsVisible() then fn(f, step) end
    end
    local due = {}
    for i = #M.timers, 1, -1 do
      if M.timers[i].at <= M.now then table.insert(due, 1, table.remove(M.timers, i)) end
    end
    for _, tm in ipairs(due) do tm.fn() end
  end
end

function M.fireEvent(event, ...)
  for _, f in ipairs(M.frames) do
    if f._events[event] and f._scripts.OnEvent then f._scripts.OnEvent(f, event, ...) end
  end
end

function M.slash(msg)
  SlashCmdList["GOBLINGAMBLING"](msg or "")
end

function M.lastPopup() return M.popups[#M.popups] end

-- Load the addon files listed in the TOC, sharing one namespace table.
function M.loadAddon(GG)
  GG = GG or {}
  local toc = assert(io.open("GoblinGambling.toc", "r"))
  for line in toc:lines() do
    line = line:gsub("\r", "")
    if line ~= "" and not line:match("^#") then
      local chunk = assert(loadfile((line:gsub("\\", "/"))))
      chunk("GoblinGambling", GG)
    end
  end
  toc:close()
  return GG
end

-- Find a Button created with a given label.
function M.findButton(label)
  for _, f in ipairs(M.frames) do
    if (f._kind == "Button" or f._kind == "CheckButton") and f._text == label then return f end
  end
end

return M
