-- Goblin Gambling Co. : Texas Hold'em table (you vs. 3-5 bots).
-- Buy-in comes out of Goblin Gold and cash-out puts the stack back. While
-- seated, your stack is mirrored in GoblinGamblingDB.poker so a /reload or
-- disconnect cashes it back out on the next login.
local ADDON, GG = ...

local Poker = GG.PokerLogic
local Bots = GG.PokerBots
local Backdrop = BackdropTemplateMixin and "BackdropTemplate" or nil
local floor = math.floor
local FN = function(n) return GG.FormatNumber(n) end

local HUMAN = 1
local ROLLOUTS = 150          -- Monte Carlo rollouts per bot decision

local STAKES = {
  { key = "copper", name = "Copper Table", sb = 5,   bb = 10,
    icon = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
    desc = "Peons, fresh bailouts and one confused murloc." },
  { key = "silver", name = "Silver Table", sb = 25,  bb = 50,
    icon = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
    desc = "Mid-level adventurers. Somebody is definitely wearing heirlooms." },
  { key = "gold",   name = "Gold Table",   sb = 100, bb = 200,
    icon = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
    desc = "High rollers only. Grubnik brings his good monocle." },
}
local STAKES_BY_KEY = {}
for _, s in ipairs(STAKES) do STAKES_BY_KEY[s.key] = s end
local BUYIN_BB, MIN_BUYIN_BB = 100, 20

-- Seconds each event stays on screen before the next (times the pace).
local EVENT_DELAY = { hand = 0.2, blind = 0.35, deal = 0.7, action = 0.75, street = 0.9,
                      showdown = 1.4, win = 1.1, handEnd = 0.4 }
local THINK = { 0.5, 1.2 }    -- bot "thinking" time range

-- Seat positions around the felt (offsets from the table centre), per bot count.
-- Seat 1 (you) is always bottom centre. Worked out for the 488x300 tab:
-- no seat, card, bubble or button overlaps another at any bot count.
local SEAT_POS = {
  [3] = { { 0, -88 }, { -182, 20 }, { 0, 94 }, { 182, 20 } },
  [4] = { { 0, -88 }, { -182, -24 }, { -182, 56 }, { 182, 56 }, { 182, -24 } },
  [5] = { { 0, -88 }, { -182, -24 }, { -182, 56 }, { 0, 94 }, { 182, 56 }, { 182, -24 } },
}
local TOP_ROW_Y = 90

local SUIT_GLYPH = { "\226\153\163", "\226\153\166", "\226\153\165", "\226\153\160" } -- c d h s
local SUIT_LETTER = { "c", "d", "h", "s" }
local CARD_FONT = "Fonts\\ARIALN.TTF"

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local ui
local t                  -- engine table, nil when not seated
local vm                 -- display model
local stake
local qi = 1             -- next event in t.events to show
local timer = 0
local thinkingSeat
local humanStartStack    -- stack when the current hand started (for stats)
local handRecorded = true
local bubbles = {}

GG.PokerUI = {}

local function Pace()
  return GG.GetPace and GG:GetPace() or 1
end

local function Rand(a, b) return a + (b - a) * (math.random(1000) / 1000) end

local function Seated() return t ~= nil end

local function SyncStack()
  if t and GG.db.poker then GG.db.poker.stack = t.seats[HUMAN].stack end
end

local function HandRunning()
  return t and t.street ~= "done" and t.street ~= "idle"
end

-- Still showing events from a hand the engine has already finished.
local function Replaying()
  return t and qi <= #t.events
end

local function HumanLive()
  local p = t and t.seats[HUMAN]
  return p and HandRunning() and p.inHand and not p.folded
end

------------------------------------------------------------------------
-- Cards
------------------------------------------------------------------------
local function CreateCard(parent, w, h)
  local f = CreateFrame("Frame", nil, parent, Backdrop)
  f:SetSize(w, h)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 8, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    f:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
  end
  f.rank = f:CreateFontString(nil, "OVERLAY")
  f.rank:SetFont(CARD_FONT, floor(h * 0.36), "")
  f.rank:SetPoint("TOPLEFT", 3, -2)
  f.suit = f:CreateFontString(nil, "OVERLAY")
  f.suit:SetFont(CARD_FONT, floor(h * 0.5), "")
  f.suit:SetPoint("BOTTOMRIGHT", -3, 2)
  f.back = f:CreateTexture(nil, "ARTWORK")
  f.back:SetPoint("TOPLEFT", 3, -3)
  f.back:SetPoint("BOTTOMRIGHT", -3, 3)
  f.back:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  f.back:SetTexCoord(0.2, 0.8, 0.1, 0.9)
  f.back:SetVertexColor(0.8, 0.35, 0.3)

  local ag = f:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0); a:SetToAlpha(1); a:SetDuration(0.25)
  f.fade = ag

  function f:Face(c, dim)
    self.card = c
    self:SetBackdropColor(dim and 0.6 or 0.96, dim and 0.6 or 0.95, dim and 0.58 or 0.9, 1)
    local red = Poker.SUIT_RED[Poker.Suit(c)]
    local r, g, b = red and 0.8 or 0.08, red and 0.1 or 0.08, red and 0.1 or 0.08
    local rank = Poker.RANK_CHARS[Poker.Rank(c)]
    if rank == "T" then rank = "10" end
    self.rank:SetText(rank)
    self.rank:SetTextColor(r, g, b)
    local suits = GG.db.settings.suitLetters and SUIT_LETTER or SUIT_GLYPH
    self.suit:SetText(suits[Poker.Suit(c)])
    self.suit:SetTextColor(r, g, b)
    self.back:Hide()
    self:Show()
  end
  function f:Back()
    self.card = nil
    self:SetBackdropColor(0.35, 0.08, 0.08, 1)
    self.rank:SetText("")
    self.suit:SetText("")
    self.back:Show()
    self:Show()
  end
  function f:FadeIn()
    self.fade:Stop()
    self.fade:Play()
  end
  f:Hide()
  return f
end

------------------------------------------------------------------------
-- Speech bubbles (table only; never sent to chat)
------------------------------------------------------------------------
local function Say(seat, text)
  if not text or not ui then return end
  local sf = ui.seats[seat]
  if not sf then return end
  local b = sf.bubble
  b.text:SetText(text)
  b:SetWidth(math.min(170, b.text:GetStringWidth() + 18))
  b:SetHeight(b.text:GetStringHeight() + 12)
  b:Show()
  b.until_ = GetTime() + 3.2 * math.max(Pace(), 0.8)
  bubbles[seat] = b
end

local function MaybeTaunt(seat, event, chance)
  local p = t.seats[seat]
  if seat == HUMAN or not p.bot then return end
  Say(seat, Bots.Taunt(p.bot, event, nil, chance))
end

------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------
local function SetStatus(text)
  if ui then ui.status:SetText(text or "") end
end

local function RenderSeat(i)
  local sf = ui.seats[i]
  local p = t.seats[i]
  local s = vm.seats[i] or {}
  sf:Show()
  local name = p.name
  if i == HUMAN then name = "|cff33ff33" .. name .. "|r" end
  sf.name:SetText(name)
  -- Between hands the engine is the truth (covers the first hand and bot rebuys).
  local between = not HandRunning() and not Replaying()
  local stack = between and p.stack or s.stack or p.stack
  sf.stack:SetText(FN(stack))

  local label = s.label or ""
  if s.bet and s.bet > 0 and not s.label then label = "Bet " .. FN(s.bet) end
  if stack == 0 and not s.inHand and vm.handNo > 0 then label = "|cff888888Busted|r" end
  sf.action:SetText(label)

  local active = thinkingSeat == i or (not Replaying() and t.toAct == i and HandRunning())
  if sf.SetBackdropBorderColor then
    if active then sf:SetBackdropBorderColor(1, 0.82, 0, 1)
    else sf:SetBackdropBorderColor(0.45, 0.4, 0.3, 1) end
  end
  sf:SetAlpha(s.folded and 0.45 or 1)
  sf.dealer:SetShown(vm.button == i)

  -- Cards: yours face up; bots face down until shown at showdown.
  local c1, c2 = sf.cards[1], sf.cards[2]
  if vm.dealt and s.inHand and not s.folded and p.hole then
    if i == HUMAN or s.shown then
      local wasHidden = not c1.card
      c1:Face(p.hole[1]); c2:Face(p.hole[2])
      if wasHidden and i ~= HUMAN then c1:FadeIn(); c2:FadeIn() end
    else
      if not c1:IsShown() then c1:FadeIn(); c2:FadeIn() end
      c1:Back(); c2:Back()
    end
  elseif vm.dealt and s.folded and i == HUMAN and p.hole then
    c1:Face(p.hole[1], true); c2:Face(p.hole[2], true)
  else
    c1:Hide(); c2:Hide()
    c1.card, c2.card = nil, nil
  end
  if s.shown then
    sf.action:SetText(s.won and s.won > 0 and s.label or ("|cffcccccc" .. s.shown.name .. "|r"))
  end
end

local function Render()
  if not ui or not t then return end
  for i = 1, #ui.seats do
    if t.seats[i] then RenderSeat(i) else ui.seats[i]:Hide() end
  end
  for i = 1, 5 do
    local c = vm.board[i]
    local cf = ui.board[i]
    if c then
      if cf.card ~= c then cf:Face(c); cf:FadeIn() end
    else
      cf:Hide(); cf.card = nil
    end
  end
  local inFront = 0
  for _, s in ipairs(vm.seats) do inFront = inFront + (s.bet or 0) end
  if vm.pot > 0 or inFront > 0 then
    ui.pot:SetText("Pot: " .. GG.FormatGold(vm.pot + inFront))
  else
    ui.pot:SetText("")
  end
  ui.info:SetText(("%s %s\n|cff888888Blinds %s/%s|r\n|cff888888Hand #%d|r"):format(stake.name, stake.icon,
    FN(stake.sb), FN(stake.bb), vm.handNo or 0))
end

------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------
local function SliderValue()
  return floor(ui.slider:GetValue() + 0.5)
end

local function UpdateControls()
  if not ui or not t then return end
  local la = (not Replaying()) and Poker.LegalActions(t, HUMAN) or nil
  local between = not HandRunning() and not Replaying()
  -- Once you have folded (or between hands) the bottom bar offers Cash out.
  local showDeal = between or not HumanLive()

  ui.actionBar:SetShown(not showDeal)
  ui.dealBar:SetShown(showDeal)

  if showDeal then
    local me = t.seats[HUMAN]
    if between then
      ui.deal:SetEnabled(me.stack > 0)
      ui.deal:SetText(me.stack > 0 and "Deal next hand" or "You're busted")
    else
      ui.deal:Disable()
      ui.deal:SetText("Hand in progress...")
    end
    ui.cashout:SetText("Cash out " .. FN(me.stack))
  end
  ui.autodeal:Refresh()

  if la then
    ui.fold:SetEnabled(la.call > 0)
    ui.call:Enable()
    ui.call:SetText(la.check and "Check" or ("Call " .. FN(la.call)))
    if la.canRaise then
      ui.raise:Enable()
      ui.allin:Enable()
      ui.slider:Enable()
      local lo, hi = la.minRaiseTo, la.maxRaiseTo
      ui.slider:SetMinMaxValues(lo, hi)
      ui.slider:SetValueStep(math.max(1, math.min(stake.bb, hi - lo)))
      local v = SliderValue()
      local key = t.handNo .. t.street .. t.currentBet
      if v < lo or v > hi or ui.slider.forHand ~= key then
        ui.slider.forHand = key
        ui.slider:SetValue(lo)
      end
      local to = SliderValue()
      local word = la.isBet and "Bet " or "Raise to "
      ui.raise:SetText(to >= hi and "All-in " .. FN(hi) or (word .. FN(to)))
    else
      ui.raise:Disable(); ui.allin:Disable(); ui.slider:Disable()
      ui.raise:SetText("Raise")
    end
  else
    ui.fold:Disable(); ui.call:Disable(); ui.raise:Disable(); ui.allin:Disable(); ui.slider:Disable()
    ui.call:SetText("Check")
    ui.raise:SetText("Raise")
  end
end

------------------------------------------------------------------------
-- Hand flow
------------------------------------------------------------------------
local function RecordHand()
  if handRecorded or not t.result or not humanStartStack then return end
  handRecorded = true
  local p = t.seats[HUMAN]
  local payout = t.result.payouts[HUMAN] or 0
  local wager = humanStartStack + payout - p.stack
  GG:RecordRound("hand", wager, payout)
  GG:Fire("STATS_CHANGED")
end

-- Busted bots rebuy so the table stays full.
local function RebuyBots()
  for i, p in ipairs(t.seats) do
    if i ~= HUMAN and p.stack == 0 then
      p.stack = BUYIN_BB * stake.bb
      Say(i, ("*rebuys for %s*"):format(FN(p.stack)))
    end
  end
end

local function DealNextHand()
  if not t or HandRunning() or Replaying() then return end
  if t.seats[HUMAN].stack <= 0 then return end
  RebuyBots()
  humanStartStack = t.seats[HUMAN].stack
  handRecorded = false
  local ok = Poker.StartHand(t)
  if not ok then return end
  qi = 1
  timer = 0
  thinkingSeat = nil
  for i = 1, #t.seats do
    local sf = ui and ui.seats[i]
    if sf then sf.cards[1].card, sf.cards[2].card = nil, nil end
  end
  SyncStack()
  SetStatus("")
  UpdateControls()
end

local function HumanAct(action)
  if not t or Replaying() or t.toAct ~= HUMAN then return false end
  local ok, err = Poker.Act(t, HUMAN, action)
  if not ok then
    SetStatus("|cffff5555" .. tostring(err) .. "|r")
    return false
  end
  SyncStack()
  if t.street == "done" then RecordHand() end
  UpdateControls()
  return true
end

local function BotAct(seat)
  local p = t.seats[seat]
  local action = Bots.Decide(p.bot, Poker.ViewFor(t, seat), nil, { rollouts = GG.PokerUI.rollouts or ROLLOUTS })
  local ok = Poker.Act(t, seat, action)
  if not ok then
    -- Should never happen; never let a bot stall the table.
    local la = Poker.LegalActions(t, seat)
    Poker.Act(t, seat, { type = la and la.check and "check" or "fold" })
  end
  SyncStack()
  if t.street == "done" then RecordHand() end
end

local ACTION_WORDS = { fold = "folds", check = "checks", call = "calls", bet = "bets", raise = "raises to" }

local function ShowEvent(ev)
  Poker.ApplyEvent(vm, ev)
  local name = ev.seat and t.seats[ev.seat].name
  if ev.type == "deal" then
    GG:PlaySound("card")
  elseif ev.type == "blind" then
    SetStatus(("%s posts the %s blind (%s)"):format(name, ev.blind, FN(ev.amount)))
  elseif ev.type == "action" then
    local amt = ev.amount and (" " .. FN(ev.amount)) or ""
    if ev.action == "check" or ev.action == "fold" then amt = "" end
    SetStatus(("%s %s%s%s"):format(name, ACTION_WORDS[ev.action] or ev.action, amt,
      ev.allIn and " |cffff8800(all-in)|r" or ""))
    if ev.action ~= "check" and ev.action ~= "fold" then GG:PlaySound("chips") end
    local map = { bet = "raise", raise = "raise", call = "call", fold = "fold" }
    if map[ev.action] then MaybeTaunt(ev.seat, ev.allIn and "raise" or map[ev.action]) end
  elseif ev.type == "street" then
    GG:PlaySound("card")
    SetStatus(ev.street:sub(1, 1):upper() .. ev.street:sub(2))
  elseif ev.type == "showdown" then
    SetStatus("Showdown!")
  elseif ev.type == "win" then
    local text = ("%s wins %s"):format(name, FN(ev.amount))
    if ev.hand then text = text .. " with " .. ev.hand end
    if ev.pot > 1 then text = text .. " (side pot)" end
    SetStatus(text)
    if ev.seat == HUMAN then
      GG:PlaySound(ev.amount >= stake.bb * 40 and "bigWin" or "smallWin")
      if ev.amount >= stake.bb * 40 then GG:FlashWindow(0.2, 0.9, 0.3) end
    else
      MaybeTaunt(ev.seat, "win", 0.6)
    end
  elseif ev.type == "handEnd" then
    if t.result and t.result.reason == "showdown" then
      for s in pairs(t.result.hands) do
        if not t.result.payouts[s] then MaybeTaunt(s, "lose", 0.35) end
      end
    end
  end
  Render()
end

-- Driven by the poker panel's OnUpdate, so it pauses when the tab or
-- window is hidden.
local function Tick(_, elapsed)
  if not t then return end
  local now = GetTime()
  for seat, b in pairs(bubbles) do
    if now >= b.until_ then b:Hide(); bubbles[seat] = nil end
  end

  timer = timer - elapsed
  if timer > 0 then return end

  if Replaying() then
    local ev = t.events[qi]
    qi = qi + 1
    ShowEvent(ev)
    timer = (EVENT_DELAY[ev.type] or 0.5) * Pace()
    if not Replaying() then UpdateControls() end
    return
  end

  if not HandRunning() then
    if GG.db.settings.pokerAutoDeal and t.seats[HUMAN].stack > 0 and ui.dealBar:IsShown() then
      if not ui.autoDealAt then
        ui.autoDealAt = now + 2.5 * Pace()
      elseif now >= ui.autoDealAt then
        ui.autoDealAt = nil
        DealNextHand()
      end
    end
    return
  end

  local seat = t.toAct
  if seat == HUMAN then
    if not ui.promptedFor or ui.promptedFor ~= t.handNo .. t.street .. #t.events then
      ui.promptedFor = t.handNo .. t.street .. #t.events
      SetStatus("|cff33ff33Your turn.|r")
      GG:PlaySound("yourTurn")
      Render()
      UpdateControls()
    end
    return
  end

  if thinkingSeat ~= seat then
    thinkingSeat = seat
    SetStatus(t.seats[seat].name .. " is thinking...")
    Render()
    timer = Rand(THINK[1], THINK[2]) * Pace()
    return
  end
  thinkingSeat = nil
  BotAct(seat)
  timer = 0
end

-- Finish the current hand instantly (you folded and want to leave).
local function FastForward()
  local guard = 0
  while HandRunning() and t.toAct ~= HUMAN and guard < 500 do
    BotAct(t.toAct)
    guard = guard + 1
  end
  while Replaying() do
    Poker.ApplyEvent(vm, t.events[qi])
    qi = qi + 1
  end
  thinkingSeat = nil
end

------------------------------------------------------------------------
-- Sitting down and leaving
------------------------------------------------------------------------
local ShowLobby, ShowTable -- forward

local function BuyInFor(st)
  return math.min(GG:GetBalance(), BUYIN_BB * st.bb)
end

local function Sit(key, nBots)
  if t then return false end
  local st = STAKES_BY_KEY[key]
  nBots = math.max(3, math.min(5, nBots or GG.db.settings.pokerBots or 4))
  local buyIn = BuyInFor(st)
  if buyIn < MIN_BUYIN_BB * st.bb then
    GG.Say(("The %s needs at least %s Goblin Gold. Grubnik can help with that (/gg loan)."):format(
      st.name, FN(MIN_BUYIN_BB * st.bb)))
    return false
  end
  if not GG:Debit(buyIn) then return false end
  stake = st
  GG.db.poker = { stack = buyIn, stake = key }

  -- Random pick of bots from the cast, random seats.
  local cast = {}
  for i, b in ipairs(Bots.CAST) do cast[i] = b end
  for i = #cast, 2, -1 do local j = math.random(i); cast[i], cast[j] = cast[j], cast[i] end
  local seats = { { name = UnitName and UnitName("player") or "You", stack = buyIn, human = true } }
  for i = 1, nBots do
    seats[#seats + 1] = { name = cast[i].name, stack = BUYIN_BB * st.bb, bot = cast[i] }
  end
  t = Poker.NewTable({ seats = seats, sb = st.sb, bb = st.bb, button = math.random(#seats) })
  vm = Poker.NewDisplay(#seats)
  qi, timer, thinkingSeat, humanStartStack, handRecorded = 1, 0, nil, nil, true
  GG:PlaySound("chips")
  ShowTable()
  for i = 2, #seats do
    if math.random(3) == 1 then Say(i, Bots.Taunt(seats[i].bot, "raise", nil, 1)) end
  end
  SetStatus(("You buy in for %s. Good luck. You'll need it."):format(FN(buyIn)))
  return true
end

local function Leave()
  if not t then return false end
  if HumanLive() then return false end
  if HandRunning() or Replaying() then FastForward() end
  local stack = t.seats[HUMAN].stack
  t = nil
  GG.db.poker = nil
  if stack > 0 then GG:Credit(stack) end
  GG.Say(("You cash out %s Goblin Gold. %s"):format(FN(stack),
    stack > 0 and "Grubnik counts it twice before handing it over." or "Grubnik waves goodbye. Mostly at your wallet."))
  for _, b in pairs(bubbles) do b:Hide() end
  bubbles = {}
  ShowLobby()
  return true
end

-- Chips left at the table by a /reload or disconnect come back.
GG:On("DB_READY", function()
  local saved = GG.db.poker
  if saved and (saved.stack or 0) > 0 then
    local stack = floor(saved.stack)
    GG.db.poker = nil
    GG:Credit(stack)
    GG.Say(("Grubnik cashed out the %s chips you left at the poker table. Fee waived. This once."):format(FN(stack)))
  else
    GG.db.poker = nil
  end
end)

------------------------------------------------------------------------
-- Build: lobby
------------------------------------------------------------------------
local function BuildLobby(panel)
  local lobby = CreateFrame("Frame", nil, panel)
  lobby:SetAllPoints()

  local title = lobby:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
  title:SetPoint("TOP", 0, -4)
  title:SetText("Grubnik's Back Room")
  local sub = lobby:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOP", title, "BOTTOM", 0, -3)
  sub:SetText("No-limit Texas Hold'em. Buy in with Goblin Gold, cash out whatever survives.")

  lobby.rows = {}
  local y = -52
  for _, st in ipairs(STAKES) do
    local row = CreateFrame("Frame", nil, lobby)
    row:SetPoint("TOPLEFT", 8, y)
    row:SetPoint("TOPRIGHT", -8, y)
    row:SetHeight(40)
    local name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    name:SetPoint("TOPLEFT", 0, -2)
    name:SetText(("%s %s  |cffccccccBlinds %s/%s|r"):format(st.name, st.icon, FN(st.sb), FN(st.bb)))
    local desc = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -3)
    desc:SetText(st.desc)
    local b = GG.CreateButton(row, "Sit", 150, 24, function() Sit(st.key) end)
    b:SetPoint("RIGHT", 0, 0)
    b.stake = st
    row.button = b
    lobby.rows[#lobby.rows + 1] = row
    y = y - 46
  end

  local botsLabel = lobby:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  botsLabel:SetPoint("TOPLEFT", 8, y - 6)
  botsLabel:SetText("Opponents:")
  lobby.botButtons = {}
  local prev = botsLabel
  for n = 3, 5 do
    local b = GG.CreateButton(lobby, n .. " bots", 64, 22, function()
      GG.db.settings.pokerBots = n
      ShowLobby()
    end)
    b:SetPoint("LEFT", prev, "RIGHT", prev == botsLabel and 8 or 4, 0)
    b.n = n
    local ul = GG.CreateLine(b, 1, 0.82, 0, 0.9)
    ul:SetPoint("BOTTOMLEFT", 6, -3); ul:SetPoint("BOTTOMRIGHT", -6, -3); ul:SetHeight(2)
    b.underline = ul
    lobby.botButtons[#lobby.botButtons + 1] = b
    prev = b
  end

  local loan = GG.CreateButton(lobby, "Get a loan", 96, 22, function() GG:ShowLoanShark() end,
    "Grubnik's Loans", "+1,000 Goblin Gold now, 1,250 owed forever. No questions asked.")
  loan:SetPoint("TOPRIGHT", -8, y - 6)

  -- The cast on one line; hover a name for how they play.
  local castLabel = lobby:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  castLabel:SetPoint("TOPLEFT", 8, y - 38)
  castLabel:SetText("Regulars:")
  local prevName = castLabel
  for _, b in ipairs(Bots.CAST) do
    local tile = CreateFrame("Frame", nil, lobby)
    tile:SetHeight(14)
    local fs = tile:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT")
    fs:SetText(b.name)
    tile:SetWidth(fs:GetStringWidth() + 4)
    tile:SetPoint("LEFT", prevName, "RIGHT", 10, 0)
    tile:EnableMouse(true)
    GG.AttachTooltip(tile, b.name, ("%s %s\n%s"):format(b.race, b.class, b.blurb))
    prevName = tile
  end
  local hint = lobby:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", castLabel, "BOTTOMLEFT", 0, -4)
  hint:SetText("Hover a name to see how they play.")

  return lobby
end

------------------------------------------------------------------------
-- Build: table
------------------------------------------------------------------------
local function BuildSeat(parent, i)
  local isHuman = i == HUMAN
  local sf = CreateFrame("Frame", nil, parent, Backdrop)
  sf:SetSize(isHuman and 132 or 116, isHuman and 50 or 58)
  if sf.SetBackdrop then
    sf:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    sf:SetBackdropColor(0.06, 0.05, 0.03, 0.92)
  end
  sf.name = sf:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  sf.name:SetPoint("TOPLEFT", 7, -6)
  sf.stack = sf:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sf.action = sf:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sf.action:SetJustifyH("LEFT")
  sf.action:SetWordWrap(false)
  if isHuman then
    sf.stack:SetPoint("TOPRIGHT", -7, -6)
    sf.action:SetPoint("BOTTOMLEFT", 7, 7)
    sf.action:SetPoint("BOTTOMRIGHT", -7, 7)
  else
    -- Bot cards sit inside the seat on the right, so text stays left of them.
    sf.stack:SetPoint("TOPLEFT", 7, -20)
    sf.action:SetPoint("BOTTOMLEFT", 7, 7)
    sf.action:SetPoint("BOTTOMRIGHT", -54, 7)
  end

  sf.dealer = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sf.dealer:SetPoint("TOPLEFT", sf, "BOTTOMLEFT", 4, -1)
  sf.dealer:SetText("|cffffffff(D) dealer|r")

  sf.cards = {}
  local cw, ch = isHuman and 34 or 22, isHuman and 46 or 30
  for k = 1, 2 do
    local c = CreateCard(parent, cw, ch)
    c:SetFrameLevel(sf:GetFrameLevel() + 3)
    sf.cards[k] = c
  end
  if isHuman then
    sf.cards[1]:SetPoint("LEFT", sf, "RIGHT", 6, 0)
    sf.cards[2]:SetPoint("LEFT", sf.cards[1], "RIGHT", 3, 0)
  else
    sf.cards[2]:SetPoint("RIGHT", sf, "RIGHT", -6, 0)
    sf.cards[1]:SetPoint("RIGHT", sf.cards[2], "LEFT", -2, 0)
  end

  local bubble = CreateFrame("Frame", nil, parent, Backdrop)
  if bubble.SetBackdrop then
    bubble:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                         edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                         edgeSize = 10, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    bubble:SetBackdropColor(1, 1, 1, 0.92)
  end
  bubble:SetFrameLevel(sf:GetFrameLevel() + 10)
  bubble.text = bubble:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bubble.text:SetPoint("CENTER")
  bubble.text:SetWidth(150)
  bubble.text:SetTextColor(0.1, 0.1, 0.1)
  bubble:Hide()
  sf.bubble = bubble

  sf:EnableMouse(true)
  GG.AttachTooltip(sf, function() return t and t.seats[i] and t.seats[i].name end, function()
    local p = t and t.seats[i]
    if not p then return nil end
    if p.bot then return ("%s %s\n%s"):format(p.bot.race, p.bot.class, p.bot.blurb) end
    return "That's you. Try to look confident."
  end)
  return sf
end

local function BuildTable(panel)
  local tbl = CreateFrame("Frame", nil, panel)
  tbl:SetAllPoints()

  local center = CreateFrame("Frame", nil, tbl)
  center:SetSize(1, 1)
  center:SetPoint("CENTER", 0, 26)
  ui.center = center

  local felt = CreateFrame("Frame", nil, tbl, Backdrop)
  felt:SetSize(240, 120)
  felt:SetPoint("CENTER", center, "CENTER", 0, 4)
  if felt.SetBackdrop then
    felt:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                       edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    felt:SetBackdropColor(0.05, 0.28, 0.12, 1)
    felt:SetBackdropBorderColor(0.55, 0.35, 0.12, 1)
  end

  ui.pot = felt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ui.pot:SetPoint("TOP", 0, -8)

  ui.board = {}
  for k = 1, 5 do
    local c = CreateCard(felt, 34, 46)
    c:SetPoint("CENTER", felt, "CENTER", (k - 3) * 38, 2)
    ui.board[k] = c
  end

  ui.status = felt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ui.status:SetPoint("BOTTOM", 0, 8)
  ui.status:SetWidth(228)
  ui.status:SetWordWrap(false)

  ui.info = tbl:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  ui.info:SetPoint("TOPLEFT", 4, -2)
  ui.info:SetJustifyH("LEFT")

  -- Top right: Grubnik's loans and the Auto-deal switch. Both stay reachable
  -- during a hand, so auto-deal can always be turned off.
  ui.loan = GG.CreateButton(tbl, "Get a loan", 84, 20, function() GG:ShowLoanShark() end,
    "Grubnik's Loans", "+1,000 Goblin Gold into your balance (not your stack). You'll owe 1,250. "
      .. "Cash out and sit again to use it at the table.")
  ui.loan:SetPoint("TOPRIGHT", -2, 0)

  ui.autodeal = GG.CreateCheckbox(tbl, "Auto-deal",
    function() return GG.db.settings.pokerAutoDeal end,
    function(v) GG.db.settings.pokerAutoDeal = v; ui.autoDealAt = nil end,
    "Auto-deal", "Deals the next hand a couple of seconds after the last one ends. Untick any time to stop.")
  ui.autodeal:SetPoint("RIGHT", ui.loan, "LEFT", -64, 0)

  ui.seats = {}
  for i = 1, 6 do
    ui.seats[i] = BuildSeat(tbl, i)
    ui.seats[i]:Hide()
  end

  -- Action bar (your turn)
  local bar = CreateFrame("Frame", nil, tbl)
  bar:SetPoint("BOTTOMLEFT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", 0, 0)
  bar:SetHeight(28)
  ui.actionBar = bar

  ui.fold = GG.CreateButton(bar, "Fold", 64, 24, function() HumanAct({ type = "fold" }) end)
  ui.fold:SetPoint("LEFT", 4, 0)
  ui.call = GG.CreateButton(bar, "Check", 100, 24, function()
    local la = Poker.LegalActions(t, HUMAN)
    if la then HumanAct({ type = la.check and "check" or "call" }) end
  end)
  ui.call:SetPoint("LEFT", ui.fold, "RIGHT", 4, 0)
  ui.raise = GG.CreateButton(bar, "Raise", 118, 24, function()
    HumanAct({ type = "raise", amount = SliderValue() })
  end)
  ui.raise:SetPoint("LEFT", ui.call, "RIGHT", 4, 0)

  local slider = CreateFrame("Slider", nil, bar, Backdrop)
  slider:SetOrientation("HORIZONTAL")
  slider:SetSize(120, 16)
  slider:SetPoint("LEFT", ui.raise, "RIGHT", 8, 0)
  if slider.SetBackdrop then
    slider:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
                         edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
                         tile = true, tileSize = 8, edgeSize = 8,
                         insets = { left = 3, right = 3, top = 6, bottom = 6 } })
  end
  slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  slider:SetMinMaxValues(0, 1)
  slider:SetValue(0)
  slider:SetObeyStepOnDrag(true)
  slider:EnableMouseWheel(true)
  slider:SetScript("OnValueChanged", function() UpdateControls() end)
  slider:SetScript("OnMouseWheel", function(self, delta)
    local lo, hi = self:GetMinMaxValues()
    self:SetValue(math.max(lo, math.min(hi, self:GetValue() + delta * stake.bb)))
  end)
  ui.slider = slider

  ui.allin = GG.CreateButton(bar, "All-in", 58, 24, function() HumanAct({ type = "allin" }) end)
  ui.allin:SetPoint("LEFT", slider, "RIGHT", 8, 0)

  -- Between hands
  local dealBar = CreateFrame("Frame", nil, tbl)
  dealBar:SetAllPoints(bar)
  ui.dealBar = dealBar
  ui.deal = GG.CreateButton(dealBar, "Deal next hand", 140, 24, function() DealNextHand() end)
  ui.deal:SetPoint("CENTER", -20, 0)
  ui.cashout = GG.CreateButton(dealBar, "Cash out", 130, 24, function() Leave() end,
    "Cash out", "Leave the table. Your whole stack goes back into Goblin Gold.")
  ui.cashout:SetPoint("LEFT", 4, 0)

  return tbl
end

------------------------------------------------------------------------
-- Screens
------------------------------------------------------------------------
function ShowLobby()
  if not ui then return end
  ui.tableFrame:Hide()
  ui.lobby:Show()
  local n = GG.db.settings.pokerBots or 4
  for _, b in ipairs(ui.lobby.botButtons) do
    if b.n == n then b:LockHighlight() else b:UnlockHighlight() end
    b.underline:SetShown(b.n == n)
  end
  for _, row in ipairs(ui.lobby.rows) do
    local st = row.button.stake
    local buyIn = BuyInFor(st)
    local ok = buyIn >= MIN_BUYIN_BB * st.bb
    row.button:SetEnabled(ok)
    row.button:SetText(ok and ("Sit (buy in " .. FN(buyIn) .. ")") or ("Need " .. FN(MIN_BUYIN_BB * st.bb)))
  end
end

function ShowTable()
  if not ui then return end
  ui.lobby:Hide()
  ui.tableFrame:Show()
  local pos = SEAT_POS[#t.seats - 1]
  for i = 1, 6 do
    local sf = ui.seats[i]
    sf:ClearAllPoints()
    if pos[i] then
      sf:SetPoint("CENTER", ui.center, "CENTER", pos[i][1], pos[i][2])
      sf.bubble:ClearAllPoints()
      if pos[i][2] >= TOP_ROW_Y then
        sf.bubble:SetPoint("TOP", sf, "BOTTOM", 0, -14)   -- top row: bubble hangs down
      else
        sf.bubble:SetPoint("BOTTOM", sf, "TOP", 0, 4)
      end
    else
      sf:Hide()
      sf.cards[1]:Hide(); sf.cards[2]:Hide()
    end
  end
  Render()
  UpdateControls()
end

local function BuildPanel(panel)
  ui = {}
  ui.lobby = BuildLobby(panel)
  ui.tableFrame = BuildTable(panel)
  panel:SetScript("OnUpdate", Tick)
  panel:SetScript("OnShow", function()
    if t then ShowTable() else ShowLobby() end
  end)
  if t then ShowTable() else ShowLobby() end
end

GG:RegisterPanel("poker", BuildPanel)

GG:On("BALANCE_CHANGED", function() if ui and not t then ShowLobby() end end)
GG:On("SETTINGS_CHANGED", function() if ui and t then
  for _, c in ipairs(ui.board) do c.card = nil end
  for _, sf in ipairs(ui.seats) do sf.cards[1].card, sf.cards[2].card = nil, nil end
  Render()
end end)

------------------------------------------------------------------------
-- Exposed for tests
------------------------------------------------------------------------
GG.PokerUI.Sit = Sit
GG.PokerUI.Leave = Leave
GG.PokerUI.Deal = DealNextHand
GG.PokerUI.Act = HumanAct
GG.PokerUI.Table = function() return t end
GG.PokerUI.Display = function() return vm end
GG.PokerUI.IsHumanTurn = function() return t and not Replaying() and t.toAct == HUMAN and HandRunning() end
GG.PokerUI.Between = function() return t and not HandRunning() and not Replaying() end
GG.PokerUI.STAKES = STAKES
