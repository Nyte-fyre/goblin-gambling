-- Goblin Gambling Co. : Texas Hold'em table.
-- Plays against bots locally, or with friends through Games/PokerMP.lua.
-- The table draws whatever "session" is active:
--   local  - this file runs the engine and the bots (pauses when hidden)
--   host   - PokerNet host: engine and bots run on this client for everyone
--   client - PokerNet client: a replica fed by the host's events
-- Buy-in comes out of Goblin Gold and cash-out puts the stack back. While
-- seated, your stack is mirrored in GoblinGamblingDB.poker so a /reload or
-- disconnect cashes it back out on the next login.
local ADDON, GG = ...

local Poker = GG.PokerLogic
local Bots = GG.PokerBots
local Net = GG.PokerNet
local MP = GG.PokerMP
local Backdrop = BackdropTemplateMixin and "BackdropTemplate" or nil
local floor = math.floor
local FN = function(n) return GG.FormatNumber(n) end

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
for i, s in ipairs(STAKES) do STAKES_BY_KEY[s.key] = s; s.index = i end
local BUYIN_BB, MIN_BUYIN_BB = 100, 20

-- Seconds each event stays on screen before the next (times the pace).
local EVENT_DELAY = { hand = 0.2, blind = 0.35, deal = 0.7, action = 0.75, street = 0.9,
                      showdown = 1.4, win = 1.1, handEnd = 0.4, turn = 0 }
local THINK = { 0.5, 1.2 }    -- bot "thinking" time range (local games)
local BACKLOG = 25            -- more unseen events than this: skip ahead

-- Seat positions around the felt (offsets from the table centre), by how
-- many other players there are. You are always bottom centre. Worked out
-- for the 488x300 tab: no seat, card, bubble or button overlaps another.
local SEAT_POS = {
  [1] = { { 0, -88 }, { 0, 94 } },
  [2] = { { 0, -88 }, { -182, 20 }, { 182, 20 } },
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
local session            -- active table session, nil when not seated
local t                  -- session.t
local me                 -- our seat index
local vm                 -- display model
local stake
local qi = 1             -- next event in t.events to show
local timer = 0
local thinkingSeat
local handStart, inThisHand
local bubbles = {}
local layoutKey

GG.PokerUI = {}

local function Pace()
  return GG.GetPace and GG:GetPace() or 1
end

local function Rand(a, b) return a + (b - a) * (math.random(1000) / 1000) end

local function SyncStack()
  if t and GG.db.poker and t.seats[me] then GG.db.poker.stack = t.seats[me].stack end
end

local function HandRunning()
  return t and t.street ~= "done" and t.street ~= "idle"
end

-- Still showing events the session has already moved past.
local function Replaying()
  return t and qi <= #t.events
end

local function MeLive()
  local p = t and t.seats[me]
  return p and HandRunning() and p.inHand and not p.folded
end

------------------------------------------------------------------------
-- Local session: you and the bots, engine on this client
------------------------------------------------------------------------
local LocalSession = {}
LocalSession.__index = LocalSession

local function NewLocalSession(st, buyIn, nBots)
  local cast = {}
  for i, b in ipairs(Bots.CAST) do cast[i] = b end
  for i = #cast, 2, -1 do local j = math.random(i); cast[i], cast[j] = cast[j], cast[i] end
  local seats = { { name = UnitName and UnitName("player") or "You", stack = buyIn, human = true } }
  for i = 1, nBots do
    seats[#seats + 1] = { name = cast[i].name, stack = BUYIN_BB * st.bb, bot = cast[i] }
  end
  local s = setmetatable({ kind = "local", mySeat = 1, stakeKey = st.key }, LocalSession)
  s.t = Poker.NewTable({ seats = seats, sb = st.sb, bb = st.bb, button = math.random(#seats) })
  return s
end

function LocalSession:Legal() return Poker.LegalActions(self.t, self.mySeat) end
function LocalSession:Act(action)
  if self.t.toAct ~= self.mySeat then return false, "not your turn" end
  return Poker.Act(self.t, self.mySeat, action)
end
function LocalSession:CanDeal()
  if self.t.street ~= "done" and self.t.street ~= "idle" then return false, "Hand in progress..." end
  if self.t.seats[self.mySeat].stack <= 0 then return false, "You're busted" end
  return true
end
function LocalSession:Deal()
  for i, p in ipairs(self.t.seats) do
    if i ~= self.mySeat and p.stack == 0 then
      p.stack = BUYIN_BB * self.t.bb
      self.rebought = self.rebought or {}
      self.rebought[i] = p.stack
    end
  end
  return Poker.StartHand(self.t)
end
function LocalSession:BotAct(seat)
  local p = self.t.seats[seat]
  local action = Bots.Decide(p.bot, Poker.ViewFor(self.t, seat), nil, { rollouts = GG.PokerUI.rollouts or ROLLOUTS })
  if not Poker.Act(self.t, seat, action) then
    local la = Poker.LegalActions(self.t, seat)
    Poker.Act(self.t, seat, { type = la and la.check and "check" or "fold" })
  end
end
function LocalSession:Leave()
  -- Finish the hand instantly (you have folded) and cash out.
  local guard = 0
  while self.t.street ~= "done" and self.t.street ~= "idle" and self.t.toAct ~= self.mySeat and guard < 500 do
    self:BotAct(self.t.toAct)
    guard = guard + 1
  end
  return self.t.seats[self.mySeat].stack
end
function LocalSession:TurnSecondsLeft() return nil end

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
-- Seat frames: ui.mine for you, ui.seats[1..6] for everyone else
------------------------------------------------------------------------
local function FrameFor(seat)
  if seat == me then return ui.mine end
  return ui.seats[seat]
end

-- Speech bubbles (table only; never sent to chat)
local function Say(seat, text)
  if not text or not ui then return end
  local sf = FrameFor(seat)
  if not sf then return end
  local b = sf.bubble
  b.text:SetText(text)
  b:SetWidth(math.min(170, b.text:GetStringWidth() + 18))
  b:SetHeight(b.text:GetStringHeight() + 12)
  b:Show()
  b.until_ = GetTime() + 3.2 * math.max(Pace(), 0.8)
  bubbles[b] = true
end

local function MaybeTaunt(seat, event, chance)
  local p = t.seats[seat]
  if seat == me or not p or not p.bot then return end
  Say(seat, Bots.Taunt(p.bot, event, nil, chance))
end

------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------
local function SetStatus(text)
  if ui then ui.status:SetText(text or "") end
end

local function Layout()
  if not ui or not t then return end
  local order = { me }
  local n = #t.seats
  for k = 1, n - 1 do
    local s = (me + k - 1) % n + 1
    if not t.seats[s].gone then order[#order + 1] = s end
  end
  local pos = SEAT_POS[math.max(1, math.min(5, #order - 1))]
  for i = 1, 6 do ui.seats[i]:Hide(); ui.seats[i].cards[1]:Hide(); ui.seats[i].cards[2]:Hide() end
  ui.mine:ClearAllPoints()
  ui.mine:SetPoint("CENTER", ui.center, "CENTER", pos[1][1], pos[1][2])
  for k = 2, #order do
    local sf = ui.seats[order[k]]
    local p = pos[k]
    if p then
      sf:ClearAllPoints()
      sf:SetPoint("CENTER", ui.center, "CENTER", p[1], p[2])
      sf.bubble:ClearAllPoints()
      if p[2] >= TOP_ROW_Y then
        sf.bubble:SetPoint("TOP", sf, "BOTTOM", 0, -14)   -- top row: bubble hangs down
      else
        sf.bubble:SetPoint("BOTTOM", sf, "TOP", 0, 4)
      end
      sf.placed = true
    end
  end
  layoutKey = nil
end

local function SeatSetKey()
  local parts = { me }
  for i, p in ipairs(t.seats) do if not p.gone then parts[#parts + 1] = i end end
  return table.concat(parts, ",")
end

local function RenderSeat(i)
  local sf = FrameFor(i)
  local p = t.seats[i]
  if not sf or not p or p.gone then
    if sf and sf ~= ui.mine then sf:Hide(); sf.cards[1]:Hide(); sf.cards[2]:Hide() end
    return
  end
  local s = vm.seats[i] or {}
  sf:Show()
  local name = p.name
  if i == me then name = "|cff33ff33" .. name .. "|r" end
  sf.name:SetText(name)
  -- Between hands the session is the truth (first hand, rebuys, new players).
  local between = not HandRunning() and not Replaying()
  local stack = between and p.stack or s.stack or p.stack
  sf.stack:SetText(FN(stack))

  local label = s.label or ""
  if s.bet and s.bet > 0 and not s.label then label = "Bet " .. FN(s.bet) end
  if stack == 0 and not s.inHand and (vm.handNo or 0) > 0 then label = "|cff888888Busted|r" end
  sf.action:SetText(label)

  local active = thinkingSeat == i or (not Replaying() and t.toAct == i and HandRunning())
  if sf.SetBackdropBorderColor then
    if active then sf:SetBackdropBorderColor(1, 0.82, 0, 1)
    else sf:SetBackdropBorderColor(0.45, 0.4, 0.3, 1) end
  end
  sf:SetAlpha(s.folded and 0.45 or 1)
  sf.dealer:SetShown(vm.button == i)

  -- Cards: yours face up; others face down until shown at showdown.
  local c1, c2 = sf.cards[1], sf.cards[2]
  local shownHole = s.shown and s.shown.hole
  local hole = (i == me and p.hole) or shownHole
  if vm.dealt and s.inHand and not s.folded then
    if hole then
      local wasHidden = not c1.card
      c1:Face(hole[1]); c2:Face(hole[2])
      if wasHidden and i ~= me then c1:FadeIn(); c2:FadeIn() end
    else
      if not c1:IsShown() then c1:FadeIn(); c2:FadeIn() end
      c1:Back(); c2:Back()
    end
  elseif vm.dealt and s.folded and i == me and p.hole then
    c1:Face(p.hole[1], true); c2:Face(p.hole[2], true)
  else
    c1:Hide(); c2:Hide()
    c1.card, c2.card = nil, nil
  end
  if s.shown then
    sf.action:SetText(s.won and s.won > 0 and s.label or ("|cffcccccc" .. (s.shown.name or "") .. "|r"))
  end
end

local function InfoText()
  local line1 = stake.name .. " " .. stake.icon
  if session.kind == "host" then
    line1 = "|cff33ff33Hosting|r " .. line1
  elseif session.kind == "client" then
    line1 = (session.hostShort or "Host") .. "'s " .. line1
  end
  return ("%s\n|cff888888Blinds %s/%s|r\n|cff888888Hand #%d|r"):format(line1, FN(stake.sb), FN(stake.bb),
    vm.handNo or 0)
end

-- Before the first hand at a multiplayer table the felt lists who is here.
local function PreGame()
  return session.kind ~= "local" and (vm.handNo or 0) == 0 and not HandRunning() and not Replaying()
end

local function RosterText()
  local lines, n, hostName = {}, 0, nil
  for i, p in ipairs(t.seats) do
    if not p.gone then
      n = n + 1
      local isHost = (session.kind == "host" and i == me) or p.isHost
      if isHost then hostName = p.name end
      local tags = {}
      if isHost then tags[#tags + 1] = "host" end
      if i == me then tags[#tags + 1] = "you" end
      if p.bot then tags[#tags + 1] = "bot" end
      local tag = #tags > 0 and (" |cff888888(" .. table.concat(tags, ", ") .. ")|r") or ""
      local nameColor = i == me and "|cff33ff33" or "|cffffd100"
      lines[#lines + 1] = ("%s%s|r%s  %s"):format(nameColor, p.name, tag, FN(p.stack))
    end
  end
  table.insert(lines, 1, ("|cffffd100At the table (%d/%d)|r"):format(n, Net.MAX_SEATS))
  return table.concat(lines, "\n"), hostName
end

local function Render()
  if not ui or not t then return end
  local key = SeatSetKey()
  if key ~= layoutKey then Layout(); layoutKey = key end
  for i = 1, #t.seats do RenderSeat(i) end
  if PreGame() then
    local text, hostName = RosterText()
    ui.roster:SetText(text)
    ui.roster:Show()
    if session.kind == "host" then
      SetStatus("Deal the first hand when everyone's here.")
    else
      SetStatus(("Waiting for %s to deal..."):format(hostName or session.hostShort or "the host"))
    end
  else
    ui.roster:Hide()
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
  ui.info:SetText(InfoText())
end

------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------
local function SliderValue()
  return floor(ui.slider:GetValue() + 0.5)
end

local function UpdateControls()
  if not ui or not t then return end
  local la = (not Replaying()) and session:Legal() or nil
  local between = not HandRunning() and not Replaying()
  -- Once you have folded (or between hands) the bottom bar offers Cash out.
  local showDeal = between or not MeLive()

  ui.actionBar:SetShown(not showDeal)
  ui.dealBar:SetShown(showDeal)

  if showDeal then
    local mine = t.seats[me]
    if between then
      local ok, why = session:CanDeal()
      ui.deal:SetEnabled(ok and true or false)
      ui.deal:SetText(ok and "Deal next hand" or why)
    else
      ui.deal:Disable()
      ui.deal:SetText("Hand in progress...")
    end
    ui.cashout:SetText("Cash out " .. FN(mine.stack))
  end
  ui.autodeal:Refresh()
  ui.autodeal:SetShown(session.kind ~= "client")

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
      local key = t.handNo .. t.street .. lo .. ":" .. hi
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
local ACTION_WORDS = { fold = "folds", check = "checks", call = "calls", bet = "bets", raise = "raises to" }

-- Everything an event does to the model and your stats, without the show.
local function Consume(ev)
  Poker.ApplyEvent(vm, ev)
  if ev.type == "hand" then
    handStart = ev.stacks[me]
    inThisHand = ev.inHand[me] and true or false
  elseif ev.type == "handEnd" and inThisHand then
    inThisHand = false
    local s = vm.seats[me]
    local payout = s.won or 0
    local wager = handStart + payout - s.stack
    GG:RecordRound("hand", wager, payout)
    if session.kind ~= "local" then
      GG.Stats.RecordMPHand(GG.db.stats, wager, payout, vm.street == "showdown")
    end
    GG:Fire("STATS_CHANGED")
  end
end

local function ShowEvent(ev)
  Consume(ev)
  local p = ev.seat and t.seats[ev.seat]
  local name = p and p.name or "?"
  if ev.type == "deal" then
    GG:PlaySound("card")
    if session.rebought then
      for seat, amount in pairs(session.rebought) do Say(seat, ("*rebuys for %s*"):format(FN(amount))) end
      session.rebought = nil
    end
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
    if (ev.pot or 1) > 1 then text = text .. " (side pot)" end
    SetStatus(text)
    if ev.seat == me then
      GG:PlaySound(ev.amount >= stake.bb * 40 and "bigWin" or "smallWin")
      if ev.amount >= stake.bb * 40 then GG:FlashWindow(0.2, 0.9, 0.3) end
    else
      MaybeTaunt(ev.seat, "win", 0.6)
    end
  elseif ev.type == "handEnd" then
    for s, seat in ipairs(vm.seats) do
      if seat.shown and (seat.won or 0) == 0 then MaybeTaunt(s, "lose", 0.35) end
    end
  end
  Render()
end

local function DealNextHand()
  if not session or HandRunning() or Replaying() then return end
  if not session:CanDeal() then return end
  if not session:Deal() then return end
  if session.kind ~= "client" then qi = 1 end
  timer = 0
  thinkingSeat = nil
  if ui then
    ui.mine.cards[1].card, ui.mine.cards[2].card = nil, nil
    for i = 1, 6 do ui.seats[i].cards[1].card, ui.seats[i].cards[2].card = nil, nil end
  end
  SyncStack()
  SetStatus("")
  UpdateControls()
end

local function HumanAct(action)
  if not session or Replaying() or not session:Legal() then return false end
  local ok, err = session:Act(action)
  if not ok then
    SetStatus("|cffff5555" .. tostring(err) .. "|r")
    return false
  end
  SyncStack()
  UpdateControls()
  return true
end

-- Driven by the poker panel's OnUpdate, so a local game pauses when the tab
-- or window is hidden. (Multiplayer sessions keep running in PokerMP.)
local function Tick(_, elapsed)
  if not t then return end
  local now = GetTime()
  for b in pairs(bubbles) do
    if now >= b.until_ then b:Hide(); bubbles[b] = nil end
  end
  SyncStack()

  -- Came back to a long backlog (window was closed): skip to near the end.
  if #t.events - qi > BACKLOG then
    while #t.events - qi > 5 do Consume(t.events[qi]); qi = qi + 1 end
    Render()
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
    -- People can sit down or leave between hands: redraw now and then.
    if session.kind ~= "local" and now >= (ui.nextIdleRender or 0) then
      ui.nextIdleRender = now + 0.5
      Render()
    end
    if session.kind ~= "client" and GG.db.settings.pokerAutoDeal and ui.dealBar:IsShown()
       and session:CanDeal() then
      if not ui.autoDealAt then
        ui.autoDealAt = now + 2.5 * Pace()
      elseif now >= ui.autoDealAt then
        ui.autoDealAt = nil
        DealNextHand()
      end
    end
    UpdateControls()
    return
  end

  local seat = t.toAct
  if seat == me then
    -- (A joined player waits here until the host's "your turn" arrives.)
    if session:Legal() then
      local key = t.handNo .. t.street .. #t.events
      if ui.promptedFor ~= key then
        ui.promptedFor = key
        GG:PlaySound("yourTurn")
        Render()
        UpdateControls()
      end
      local left = session:TurnSecondsLeft()
      SetStatus("|cff33ff33Your turn.|r" .. (left and (" |cff888888(%ds)|r"):format(left) or ""))
    end
    return
  end

  if not seat then return end
  if session.kind == "local" then
    if thinkingSeat ~= seat then
      thinkingSeat = seat
      SetStatus(t.seats[seat].name .. " is thinking...")
      Render()
      timer = Rand(THINK[1], THINK[2]) * Pace()
      return
    end
    thinkingSeat = nil
    session:BotAct(seat)
    SyncStack()
    timer = 0
  else
    -- Someone else decides (a bot on the host, or another player).
    local left = session:TurnSecondsLeft()
    local p = t.seats[seat]
    local text = (p and p.name or "?") .. " is thinking..."
    if left and p and not p.bot then text = text .. (" |cff888888(%ds)|r"):format(left) end
    SetStatus(text)
    if thinkingSeat ~= seat then thinkingSeat = seat; Render() end
    timer = 0.25
  end
end

------------------------------------------------------------------------
-- Sitting down and leaving
------------------------------------------------------------------------
local ShowLobby, ShowTable, ShowMP -- forward

local function BuyInFor(st)
  return math.min(GG:GetBalance(), BUYIN_BB * st.bb)
end

local function Start(newSession, st, buyIn)
  session, t, me, stake = newSession, newSession.t, newSession.mySeat, st
  vm = Poker.NewDisplay(#t.seats)
  qi, timer, thinkingSeat, handStart, inThisHand, layoutKey = 1, 0, nil, nil, false, nil
  GG.db.poker = { stack = buyIn, stake = st.key }
  if newSession.kind ~= "local" then
    GG.Stats.RecordMPTable(GG.db.stats, newSession.kind == "host" and "hosted" or "joined")
    GG:Fire("STATS_CHANGED")
  end
  GG:PlaySound("chips")
  ShowTable()
  SetStatus(("You buy in for %s. Good luck. You'll need it."):format(FN(buyIn)))
end

local function Sit(key, nBots)
  if session then return false end
  local st = STAKES_BY_KEY[key]
  nBots = math.max(3, math.min(5, nBots or GG.db.settings.pokerBots or 4))
  local buyIn = BuyInFor(st)
  if buyIn < MIN_BUYIN_BB * st.bb then
    GG.Say(("The %s needs at least %s Goblin Gold. Grubnik can help with that (/gg loan)."):format(
      st.name, FN(MIN_BUYIN_BB * st.bb)))
    return false
  end
  if not GG:Debit(buyIn) then return false end
  local s = NewLocalSession(st, buyIn, nBots)
  Start(s, st, buyIn)
  for i = 2, #s.t.seats do
    if math.random(3) == 1 then Say(i, Bots.Taunt(s.t.seats[i].bot, "raise", nil, 1)) end
  end
  return true
end

local function EndSession(stack, text)
  -- Finish showing (and counting) anything already received.
  if t then
    while qi <= #t.events do Consume(t.events[qi]); qi = qi + 1 end
  end
  local old = session
  session, t = nil, nil
  GG.db.poker = nil
  if stack and stack > 0 then GG:Credit(stack) end
  GG.Say(text)
  for b in pairs(bubbles) do b:Hide() end
  bubbles = {}
  if old and old.kind ~= "local" then
    MP.Release(old)
    MP.Browse()          -- repopulate the table list straight away
    ShowMP()
  else
    ShowLobby()
  end
end

local function Leave()
  if not session then return false end
  if MeLive() then return false end
  local stack = session:Leave() or 0
  while Replaying() do Consume(t.events[qi]); qi = qi + 1 end
  thinkingSeat = nil
  local extra = session.kind == "host" and " The table is closed." or ""
  EndSession(stack, ("You cash out %s Goblin Gold. %s%s"):format(FN(stack),
    stack > 0 and "Grubnik counts it twice before handing it over." or "Grubnik waves goodbye. Mostly at your wallet.",
    extra))
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
-- Multiplayer: hosting and joining
------------------------------------------------------------------------
local mpState = { stake = 1, channel = 1, bots = 0 }
local CHANNELS = { { key = "group", label = "Group" }, { key = "guild", label = "Guild" } }

local function MPStatus(text)
  if ui and ui.mp then ui.mp.status:SetText(text or "") end
end

local function ChannelFor(key)
  if key == "guild" then return MP.GuildChannel() end
  return MP.GroupChannel()
end

local function HostTable()
  local st = STAKES[mpState.stake]
  local channel = ChannelFor(CHANNELS[mpState.channel].key)
  if not channel then
    MPStatus(mpState.channel == 1 and "|cffff5555You're not in a group.|r" or "|cffff5555You're not in a guild.|r")
    return false
  end
  local buyIn = BuyInFor(st)
  if buyIn < MIN_BUYIN_BB * st.bb then
    MPStatus(("|cffff5555The %s needs at least %s Goblin Gold.|r"):format(st.name, FN(MIN_BUYIN_BB * st.bb)))
    return false
  end
  local cast = {}
  for i, b in ipairs(Bots.CAST) do cast[i] = b end
  for i = #cast, 2, -1 do local j = math.random(i); cast[i], cast[j] = cast[j], cast[i] end
  local bots = {}
  for i = 1, mpState.bots do bots[i] = cast[i] end
  if not GG:Debit(buyIn) then return false end
  local h = MP.Host(channel, st.key, buyIn, bots)
  if not h then
    GG:Credit(buyIn)
    MPStatus("|cffff5555Couldn't open a table.|r")
    return false
  end
  Start(h, st, buyIn)
  SetStatus("Table open. Friends can join from their Poker tab. Deal when ready.")
  return true
end

local function JoinTable(tb)
  local st = STAKES_BY_KEY[tb.stake]
  local buyIn = BuyInFor(st)
  if buyIn < MIN_BUYIN_BB * st.bb then
    MPStatus(("|cffff5555That table needs at least %s Goblin Gold.|r"):format(FN(MIN_BUYIN_BB * st.bb)))
    return false
  end
  if MP.Join(tb.id, buyIn) then
    MPStatus("Asking " .. tb.hostName .. " for a seat...")
    return true
  end
  return false
end

MP.callbacks.onSeated = function(seat, buyIn)
  local c = MP.Client()
  local st = STAKES_BY_KEY[c.stakeKey] or STAKES[1]
  if not GG:Debit(buyIn) then
    c:Leave()
    MP.Release(c)
    MPStatus("|cffff5555You no longer have enough Goblin Gold for that buy-in.|r")
    return
  end
  local tb = c.tables[c.joinId]
  c.hostShort = tb and tb.hostName or Net.ShortName(c.host)
  Start(c, st, buyIn)
  SetStatus(("Seated at %s's table. Waiting for the next deal..."):format(c.hostShort))
end

MP.callbacks.onRejected = function(reason)
  local text = { full = "That table is full.", buyin = "The host wants a bigger buy-in.",
                 noanswer = "No answer from the host." }
  MPStatus("|cffff5555" .. (text[reason] or "Couldn't join.") .. "|r")
end

MP.callbacks.onGone = function(stack, why)
  if not session or session.kind ~= "client" then return end
  local text = {
    removed = "The host removed you from the table (too long to act, or you left).",
    closed = "The host closed the table.",
    lost = "Lost contact with the host.",
  }
  EndSession(stack, ("%s You get back %s Goblin Gold."):format(text[why] or "You left the table.", FN(stack)))
end

MP.callbacks.onRoster = function()
  if ui and session and session.kind == "client" then Render() end
end

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

  local friends = GG.CreateButton(lobby, "Play with friends", 120, 20, function() ShowMP() end,
    "Play with friends", "Host or join a table with your group or guild.")
  friends:SetPoint("TOPRIGHT", 0, 0)

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
-- Build: multiplayer page
------------------------------------------------------------------------
local function BuildMP(panel)
  local f = CreateFrame("Frame", nil, panel)
  f:SetAllPoints()

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
  title:SetPoint("TOP", 0, -4)
  title:SetText("Play with friends")
  local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOP", title, "BOTTOM", 0, -3)
  sub:SetWidth(470)
  sub:SetText("Tables are shared with your group or guild through hidden addon messages. "
    .. "Nothing shows in chat. Everyone plays with their own Goblin Gold.")

  -- Host row
  local hostLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  hostLabel:SetPoint("TOPLEFT", 8, -70)
  hostLabel:SetText("Host:")
  f.stakeBtn = GG.CreateButton(f, "", 128, 22, function()
    mpState.stake = mpState.stake % #STAKES + 1
    ShowMP()
  end, "Stakes", "Click to change the table stakes.")
  f.stakeBtn:SetPoint("LEFT", hostLabel, "RIGHT", 8, 0)
  f.chanBtn = GG.CreateButton(f, "", 70, 22, function()
    mpState.channel = mpState.channel % #CHANNELS + 1
    ShowMP()
  end, "Who can see it", "Group: your party or raid. Guild: everyone in your guild with the addon.")
  f.chanBtn:SetPoint("LEFT", f.stakeBtn, "RIGHT", 4, 0)
  f.botsBtn = GG.CreateButton(f, "", 70, 22, function()
    mpState.bots = (mpState.bots + 1) % 4
    ShowMP()
  end, "Bots", "Fill some seats with the regulars. They run on your client.")
  f.botsBtn:SetPoint("LEFT", f.chanBtn, "RIGHT", 4, 0)
  f.hostBtn = GG.CreateButton(f, "Open table", 110, 22, function() HostTable() end,
    "Open table", "Buy in and open a table. You deal; friends join between hands.")
  f.hostBtn:SetPoint("TOPRIGHT", -8, -66)

  -- Open tables
  local listLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  listLabel:SetPoint("TOPLEFT", 8, -106)
  listLabel:SetText("Open tables")
  f.refresh = GG.CreateButton(f, "Refresh", 80, 20, function()
    if MP.Browse() then MPStatus("Looking for tables...") else MPStatus("|cffff5555Join a group or guild first.|r") end
  end)
  f.refresh:SetPoint("LEFT", listLabel, "RIGHT", 10, 0)

  f.rows = {}
  for i = 1, 4 do
    local row = CreateFrame("Frame", nil, f)
    row:SetPoint("TOPLEFT", 8, -106 - i * 26)
    row:SetPoint("TOPRIGHT", -8, -106 - i * 26)
    row:SetHeight(24)
    row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row.join = GG.CreateButton(row, "Join", 120, 22, function() if row.tb then JoinTable(row.tb) end end)
    row.join:SetPoint("RIGHT", 0, 0)
    row:Hide()
    f.rows[i] = row
  end
  f.empty = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", 12, -136)

  f.back = GG.CreateButton(f, "Back", 80, 22, function()
    -- Leaving the page switches multiplayer off again (unless seated).
    if not MP.IsBusy() then MP.SetEnabled(false) end
    ShowLobby()
  end)
  f.back:SetPoint("BOTTOMLEFT", 4, 4)
  f.status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  f.status:SetPoint("BOTTOMLEFT", f.back, "BOTTOMRIGHT", 10, 5)
  f.status:SetPoint("RIGHT", -8, 0)
  f.status:SetJustifyH("LEFT")

  -- Keep the list fresh while the page is open.
  f.elapsed = 0
  f:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed >= 1 then self.elapsed = 0; ShowMP(true) end
  end)
  return f
end

------------------------------------------------------------------------
-- Build: table
------------------------------------------------------------------------
local function BuildSeat(parent, isMine)
  local sf = CreateFrame("Frame", nil, parent, Backdrop)
  sf:SetSize(isMine and 132 or 116, isMine and 50 or 58)
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
  if isMine then
    sf.stack:SetPoint("TOPRIGHT", -7, -6)
    sf.action:SetPoint("BOTTOMLEFT", 7, 7)
    sf.action:SetPoint("BOTTOMRIGHT", -7, 7)
  else
    -- Other players' cards sit inside the seat on the right.
    sf.stack:SetPoint("TOPLEFT", 7, -20)
    sf.action:SetPoint("BOTTOMLEFT", 7, 7)
    sf.action:SetPoint("BOTTOMRIGHT", -54, 7)
  end

  sf.dealer = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sf.dealer:SetPoint("TOPLEFT", sf, "BOTTOMLEFT", 4, -1)
  sf.dealer:SetText("|cffffffff(D) dealer|r")

  sf.cards = {}
  local cw, ch = isMine and 34 or 22, isMine and 46 or 30
  for k = 1, 2 do
    local c = CreateCard(parent, cw, ch)
    c:SetFrameLevel(sf:GetFrameLevel() + 3)
    sf.cards[k] = c
  end
  if isMine then
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
  if isMine then bubble:SetPoint("BOTTOM", sf, "TOP", 0, 4) end
  return sf
end

local function SeatTooltip(sf, seatFn)
  sf:EnableMouse(true)
  GG.AttachTooltip(sf, function()
    local p = t and t.seats[seatFn()]
    return p and p.name
  end, function()
    local seat = seatFn()
    local p = t and t.seats[seat]
    if not p then return nil end
    if p.bot then return ("%s %s\n%s"):format(p.bot.race, p.bot.class, p.bot.blurb) end
    if seat == me then return "That's you. Try to look confident." end
    return "Another adventurer. Probably also bad at this."
  end)
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

  -- Multiplayer: who is at the table before the first hand.
  ui.roster = felt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ui.roster:SetPoint("TOP", 0, -8)
  ui.roster:SetWidth(224)
  ui.roster:SetSpacing(1)      -- 7 lines still clear the status line at the bottom
  ui.roster:Hide()

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

  ui.mine = BuildSeat(tbl, true)
  SeatTooltip(ui.mine, function() return me end)
  ui.seats = {}
  for i = 1, 6 do
    ui.seats[i] = BuildSeat(tbl, false)
    SeatTooltip(ui.seats[i], function() return i end)
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
    local la = session and session:Legal()
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

  -- All-in: the most you may raise to, or a call if raising is not allowed.
  ui.allin = GG.CreateButton(bar, "All-in", 58, 24, function()
    local la = session and session:Legal()
    if not la then return end
    if la.canRaise then HumanAct({ type = "raise", amount = la.maxRaiseTo })
    elseif la.call > 0 then HumanAct({ type = "call" }) end
  end)
  ui.allin:SetPoint("LEFT", slider, "RIGHT", 8, 0)

  -- Between hands (and after you fold)
  local dealBar = CreateFrame("Frame", nil, tbl)
  dealBar:SetAllPoints(bar)
  ui.dealBar = dealBar
  ui.deal = GG.CreateButton(dealBar, "Deal next hand", 140, 24, function() DealNextHand() end)
  ui.deal:SetPoint("CENTER", -20, 0)
  ui.cashout = GG.CreateButton(dealBar, "Cash out", 130, 24, function() Leave() end,
    "Cash out", "Leave the table. Your whole stack goes back into Goblin Gold. (Hosting? This closes the table.)")
  ui.cashout:SetPoint("LEFT", 4, 0)

  return tbl
end

------------------------------------------------------------------------
-- Screens
------------------------------------------------------------------------
function ShowLobby()
  if not ui then return end
  if session then ShowTable(); return end
  ui.tableFrame:Hide()
  ui.mp:Hide()
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

-- refreshOnly: just update the list and buttons (called every second).
function ShowMP(refreshOnly)
  if not ui then return end
  if session then ShowTable(); return end
  if not refreshOnly then
    ui.tableFrame:Hide()
    ui.lobby:Hide()
    ui.mp:Show()
    -- Opening this page is the opt-in: listen for tables from now on.
    if not MP.enabled then
      MP.SetEnabled(true)
      MP.Browse()
    end
  end
  local f = ui.mp
  local on = MP.enabled
  local st = STAKES[mpState.stake]
  f.stakeBtn:SetText(st.name)
  f.chanBtn:SetText(CHANNELS[mpState.channel].label)
  f.botsBtn:SetText(mpState.bots == 1 and "1 bot" or (mpState.bots .. " bots"))
  local busy = MP.IsBusy()
  for _, b in ipairs({ f.stakeBtn, f.chanBtn, f.botsBtn, f.hostBtn, f.refresh }) do b:SetEnabled(on and not busy) end

  local list = on and MP.Tables() or {}
  for i, row in ipairs(f.rows) do
    local tb = list[i]
    row.tb = tb
    if tb then
      local tst = STAKES_BY_KEY[tb.stake]
      row.text:SetText(("|cffffd100%s|r  %s %s  |cff888888%d/%d seated%s|r"):format(tb.hostName, tst.name, tst.icon,
        tb.seated, tb.max, tb.running and ", mid-hand" or ""))
      local buyIn = BuyInFor(tst)
      local can = buyIn >= MIN_BUYIN_BB * tst.bb and tb.seated < tb.max and not busy
      row.join:SetEnabled(can)
      row.join:SetText(tb.seated >= tb.max and "Full" or ("Join (" .. FN(buyIn) .. ")"))
      row:Show()
    else
      row:Hide()
    end
  end
  if #list == 0 then
    f.empty:SetText("No open tables yet. Hit Refresh, or open one yourself.")
  else
    f.empty:SetText("")
  end
end

function ShowTable()
  if not ui or not session then return end
  ui.lobby:Hide()
  ui.mp:Hide()
  ui.tableFrame:Show()
  -- No loans at a friends' table: it would never end.
  ui.loan:SetShown(session.kind == "local")
  layoutKey = nil
  Render()
  UpdateControls()
end

local function BuildPanel(panel)
  ui = {}
  ui.lobby = BuildLobby(panel)
  ui.mp = BuildMP(panel)
  ui.mp:Hide()
  ui.tableFrame = BuildTable(panel)
  panel:SetScript("OnUpdate", Tick)
  panel:SetScript("OnShow", function()
    if session then ShowTable() else ShowLobby() end
  end)
  if session then ShowTable() else ShowLobby() end
end

GG:RegisterPanel("poker", BuildPanel)

-- When it becomes your turn and the casino is open on another tab, jump to
-- the poker table. (Only on the moment it becomes your turn, so you can
-- still look at other tabs while you think.)
local turnWatch = CreateFrame("Frame")
local wasMyTurn = false
turnWatch:SetScript("OnUpdate", function()
  local mine = session ~= nil and session:Legal() ~= nil
  if mine and not wasMyTurn and GG.frame and GG.frame:IsShown()
     and GG.db.settings.lastTab ~= "poker" then
    GG:SelectTab("poker")
  end
  wasMyTurn = mine
end)

GG:On("BALANCE_CHANGED", function()
  if ui and not session then
    if ui.mp:IsShown() then ShowMP(true) else ShowLobby() end
  end
end)
GG:On("SETTINGS_CHANGED", function() if ui and session then
  for _, c in ipairs(ui.board) do c.card = nil end
  ui.mine.cards[1].card, ui.mine.cards[2].card = nil, nil
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
GG.PokerUI.Host = HostTable
GG.PokerUI.JoinTable = JoinTable
GG.PokerUI.MPState = mpState
GG.PokerUI.Session = function() return session end
GG.PokerUI.Table = function() return t end
GG.PokerUI.MySeat = function() return me end
GG.PokerUI.Display = function() return vm end
GG.PokerUI.IsHumanTurn = function()
  return session and not Replaying() and HandRunning() and session:Legal() ~= nil
end
GG.PokerUI.Between = function() return session and not HandRunning() and not Replaying() end
GG.PokerUI.STAKES = STAKES
