-- Goblin Gambling Co. : namespace, SavedVariables, balance API, slash commands.
-- Goblin Gold only. Nothing in this addon reads or moves real gold or items.
local ADDON, GG = ...

GG.NAME = "Goblin Gambling Co."
GG.VERSION = "0.4.0"
GG.DB_VERSION = 1

GG.BAILOUT_AMOUNT = 1000
GG.BAILOUT_OWED = 1250

function GG.Say(...)
  print("|cffffd100[GoblinGambling]|r", ...)
end
local Say = GG.Say

------------------------------------------------------------------------
-- Tiny event bus so UI pieces can react without knowing about each other.
--   GG:On("BALANCE_CHANGED", fn)   GG:Fire("BALANCE_CHANGED", new, old)
------------------------------------------------------------------------
local listeners = {}
function GG:On(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end
function GG:Fire(event, ...)
  local list = listeners[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], ...)
    if not ok then geterrorhandler()(err) end
  end
end

------------------------------------------------------------------------
-- SavedVariables
------------------------------------------------------------------------
local function DeepCopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = DeepCopy(x) end
  return t
end
GG.DeepCopy = DeepCopy

-- Fill in anything missing from src without overwriting existing values.
local function FillDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      FillDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local function Defaults()
  return {
    version = GG.DB_VERSION,
    balance = 1000,
    debt = 0,
    settings = {
      sound = true,
      autospinDelay = 0.4,
      windowPos = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 },
      windowScale = 1,
      minimap = { hide = false, angle = 200 },
      lastTab = "slots",
      slotsBet = 10,          -- a number, or "max"
      slotsSpeed = "medium",  -- "slow" | "medium" | "fast" (also paces poker)
      pokerBots = 4,
      pokerAutoDeal = false,
      suitLetters = false,    -- show s/h/d/c instead of suit symbols
      showPaytable = false,
    },
    stats = DeepCopy(GG.Stats.DEFAULTS),
  }
end

local function InitDB()
  if type(GoblinGamblingDB) ~= "table" then GoblinGamblingDB = {} end
  local db = GoblinGamblingDB
  FillDefaults(db, Defaults())
  -- Future schema changes go here, keyed on db.version.
  db.version = GG.DB_VERSION
  -- Repair anything a hand-edited file might have broken.
  if type(db.balance) ~= "number" or db.balance < 0 then db.balance = 0 end
  db.balance = math.floor(db.balance)
  GG.db = db
end

-- Wipes balance, debt and stats. Settings (window spot, sound, minimap) stay.
function GG:ResetAll()
  local d = Defaults()
  local old = self.db.balance
  self.db.balance = d.balance
  self.db.debt = d.debt
  self.db.stats = d.stats
  self:Fire("BALANCE_CHANGED", self.db.balance, old)
  self:Fire("STATS_CHANGED")
end

function GG:ResetStats()
  self.db.stats = GG.Stats.New()
  self:Fire("STATS_CHANGED")
end

------------------------------------------------------------------------
-- Balance API: the only way games touch Goblin Gold.
------------------------------------------------------------------------
local function ValidAmount(n)
  return type(n) == "number" and n > 0 and n == math.floor(n)
end

function GG:GetBalance() return self.db.balance end
function GG:GetDebt() return self.db.debt end

function GG:CanAfford(n)
  return ValidAmount(n) and self.db.balance >= n
end

function GG:Debit(n)
  if not self:CanAfford(n) then return false end
  local old = self.db.balance
  self.db.balance = old - n
  self:Fire("BALANCE_CHANGED", self.db.balance, old)
  return true
end

function GG:Credit(n)
  if n == 0 then return true end
  if not ValidAmount(n) then return false end
  local old = self.db.balance
  self.db.balance = old + n
  self:Fire("BALANCE_CHANGED", self.db.balance, old)
  return true
end

function GG:Bailout()
  self.db.debt = self.db.debt + GG.BAILOUT_OWED
  GG.Stats.RecordBailout(self.db.stats)
  self:Credit(GG.BAILOUT_AMOUNT)
  self:Fire("STATS_CHANGED")
  GG:PlaySound("bailout")
  Say(("Grubnik slides over %s Goblin Gold. You now owe %s. He is smiling."):format(
    GG.FormatNumber(GG.BAILOUT_AMOUNT), GG.FormatNumber(self.db.debt)))
end

-- Pay back as much debt as the balance allows (or n, if given).
-- Returns the amount repaid.
function GG:RepayDebt(n)
  local amount = math.min(n or self.db.debt, self.db.debt, self.db.balance)
  amount = math.floor(amount)
  if amount <= 0 then return 0 end
  self:Debit(amount)
  self.db.debt = self.db.debt - amount
  self:Fire("BALANCE_CHANGED", self.db.balance, self.db.balance)
  if self.db.debt == 0 then
    Say("Debt cleared! Grubnik looks genuinely disappointed.")
  else
    Say(("Paid Grubnik %s. Still owe %s. He counts it twice."):format(
      GG.FormatNumber(amount), GG.FormatNumber(self.db.debt)))
  end
  return amount
end

-- Lowest bet any game offers; below this you are broke.
function GG:IsBroke()
  return self.db.balance < GG.SlotsLogic.MIN_BET
end

------------------------------------------------------------------------
-- Popups (StaticPopup is Blizzard's, but we only add our own dialogs)
------------------------------------------------------------------------
StaticPopupDialogs["GOBLINGAMBLING_RESET"] = {
  text = "Reset |cffffd100Goblin Gambling Co.|r?\n\nGoblin Gold, debt and all stats go back to the start. "
      .. "The goblins will pretend they never met you.",
  button1 = YES, button2 = NO,
  OnAccept = function()
    GG:ResetAll()
    Say("Fresh start. Your record has been 'lost' in a tragic ledger fire.")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["GOBLINGAMBLING_RESET_STATS"] = {
  text = "Reset your lifetime stats?\n\nYour Goblin Gold and debt stay. Only the evidence goes away.",
  button1 = YES, button2 = NO,
  OnAccept = function()
    GG:ResetStats()
    Say("Stats wiped. What stats? There were never any stats.")
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["GOBLINGAMBLING_LOAN"] = {
  text = "|cffffd100Grubnik's Loans|r\n25%% interest, no questions asked.\n\n"
      .. "Take %s Goblin Gold now and owe %s forever?",
  button1 = "Accept", button2 = "Nope",
  OnAccept = function() GG:Bailout() end,
  OnCancel = function(_, _, reason)
    if reason == "clicked" then Say("Grubnik shrugs. \"You'll be back. They always come back.\"") end
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["GOBLINGAMBLING_REPAY"] = {
  text = "Pay Grubnik back %s Goblin Gold?\n\nYou owe %s. He accepts Goblin Gold, gold teeth and firstborns.",
  button1 = "Pay up", button2 = "Not today",
  OnAccept = function() GG:RepayDebt() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function GG:ShowRepay()
  local amount = math.min(self.db.debt, self.db.balance)
  if self.db.debt <= 0 then
    Say("You don't owe Grubnik anything. He finds this suspicious.")
  elseif amount <= 0 then
    Say("You have no Goblin Gold to pay Grubnik with. He writes that down.")
  else
    StaticPopup_Show("GOBLINGAMBLING_REPAY", GG.FormatNumber(amount), GG.FormatNumber(self.db.debt))
  end
end

function GG:ShowLoanShark()
  StaticPopup_Show("GOBLINGAMBLING_LOAN",
    GG.FormatNumber(GG.BAILOUT_AMOUNT), GG.FormatNumber(GG.BAILOUT_OWED))
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local HELP = {
  "|cffffd100/gg|r (or |cffffd100/ggc|r, |cffffd100/goblin|r) - open or close the casino",
  "|cffffd100/gg sound|r - mute or unmute",
  "|cffffd100/gg speed|r [slow|medium|fast] - reel speed (no word = next speed)",
  "|cffffd100/gg suits|r - switch card suits between symbols and letters",
  "|cffffd100/gg soundtest|r - play every casino sound once, with its name",
  "|cffffd100/gg minimap|r - show or hide the minimap button",
  "|cffffd100/gg loan|r - visit Grubnik (bailout: +1,000 Goblin Gold, owe 1,250)",
  "|cffffd100/gg repay|r - pay Grubnik back as much as you can",
  "|cffffd100/gg reset|r - wipe Goblin Gold, debt and stats (asks first)",
}

-- /ggc and /goblin are backups in case another addon also claims /gg.
SLASH_GOBLINGAMBLING1 = "/gg"
SLASH_GOBLINGAMBLING2 = "/ggc"
SLASH_GOBLINGAMBLING3 = "/goblin"
SlashCmdList["GOBLINGAMBLING"] = function(msg)
  local cmd = strtrim(msg or ""):lower()
  if cmd == "" or cmd == "show" or cmd == "toggle" then
    GG:ToggleWindow()
  elseif cmd == "reset" then
    StaticPopup_Show("GOBLINGAMBLING_RESET")
  elseif cmd == "loan" or cmd == "bailout" then
    GG:ShowLoanShark()
  elseif cmd == "repay" or cmd == "pay" then
    GG:ShowRepay()
  elseif cmd == "sound" or cmd == "mute" then
    GG.db.settings.sound = not GG.db.settings.sound
    Say("Sound " .. (GG.db.settings.sound and "on. Ka-ching." or "off. The goblins will mime it."))
    GG:Fire("SETTINGS_CHANGED")
  elseif cmd == "speed" or cmd:match("^speed ") then
    local want = cmd:match("^speed%s+(%S+)")
    local aliases = { turtle = "slow", kodo = "medium", normal = "medium", rocket = "fast" }
    local key = want and (aliases[want] or want)
    if not key then
      local cur = GG.db.settings.slotsSpeed
      local order = { slow = "medium", medium = "fast", fast = "slow" }
      key = order[cur] or "medium"
    end
    local sp = GG:SetSlotSpeed(key)
    if sp then
      Say("Reel speed: |cffffd100" .. sp.name .. "|r. " .. sp.desc)
    else
      Say("Unknown speed. Try |cffffd100/gg speed slow|r, |cffffd100medium|r or |cffffd100fast|r.")
    end
  elseif cmd == "suits" then
    GG.db.settings.suitLetters = not GG.db.settings.suitLetters
    Say("Card suits now show as " .. (GG.db.settings.suitLetters and "letters (s h d c)." or "symbols."))
    GG:Fire("SETTINGS_CHANGED")
  elseif cmd == "soundtest" then
    GG:SoundTest()
  elseif cmd == "minimap" then
    GG.db.settings.minimap.hide = not GG.db.settings.minimap.hide
    GG:UpdateMinimapButton()
    Say("Minimap button " .. (GG.db.settings.minimap.hide and "hidden. /gg minimap brings it back." or "shown."))
  else
    Say(GG.NAME .. " v" .. GG.VERSION .. " - Goblin Gold only, no real gold involved.")
    for _, line in ipairs(HELP) do print("   " .. line) end
  end
end

------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    InitDB()
    GG:Fire("DB_READY")
    -- Seed once per session. WoW may already seed its own RNG; never error.
    pcall(math.randomseed, time() + math.floor(GetTime() * 1000))
    self:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_LOGIN" then
    GG:CreateMinimapButton()
    self:UnregisterEvent("PLAYER_LOGIN")
  end
end)
