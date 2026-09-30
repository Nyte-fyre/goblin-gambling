-- Goblin Gambling Co. : multiplayer Hold'em protocol, host and client.
-- Pure Lua 5.1. No WoW API calls: the host and client take a clock and
-- queue their outgoing messages; Games/PokerMP.lua hands those to WoW's
-- hidden addon-message channel (rate limited) and feeds incoming ones back.
--
-- The host runs the real engine (Games/PokerLogic.lua) and the bots. Every
-- engine event is broadcast so clients can replay the hand on the same
-- table UI. Hole cards go only to their owner, by whisper; everyone else
-- sees them only at showdown. Each player buys in and cashes out with
-- their own Goblin Gold.
--
-- Message: "<version>~<type>~<fields...>", at most MAX_LEN characters.
--   Q                                   who is hosting? (group/guild)
--   T  id~stake~seated~max~running~name table announcement / heartbeat
--   J  id~buyIn                         join request (whisper to host)
--   OK id~seat~buyIn                    seated (whisper)
--   NO id~reason                        join refused (whisper)
--   R  id~seat:kind:name:stack;...      roster (kind h/p/b/e)
--   E  id~seq~event;event;...           engine events, in order
--   C  id~handNo~c1:c2                  your hole cards (whisper)
--   Y  id~handNo~check~call~canRaise~min~max~isBet~currentBet~secs
--                                       your turn and what you may do (whisper)
--   A  id~handNo~type~amount            your action (whisper to host)
--   L  id                               leaving (whisper to host)
--   BYE id~seat~stack                   you were removed; your final stack
--   X  id                               table closed by the host
local ADDON, GG = ...
GG = GG or {}

local Poker = GG.PokerLogic
local Bots = GG.PokerBots
local floor = math.floor

local Net = {}
GG.PokerNet = Net

Net.VERSION = "1"
Net.PREFIX = "GGCASINO"
Net.MAX_LEN = 240
Net.MAX_SEATS = 6
Net.TURN_TIMEOUT = 45        -- seconds a human has to act before auto check/fold
Net.HOST_TIMEOUT = 75        -- seconds of host silence before a client gives up
Net.JOIN_TIMEOUT = 15
Net.ANNOUNCE_EVERY = 30
Net.TABLE_FORGET = 90        -- drop announced tables not heard from in this long
Net.STAKES = {
  copper = { sb = 5, bb = 10 },
  silver = { sb = 25, bb = 50 },
  gold   = { sb = 100, bb = 200 },
}
Net.MIN_BUYIN_BB, Net.MAX_BUYIN_BB = 20, 100
Net.THINK = { 0.5, 1.2 }

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local function Split(s, sep)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then out[#out + 1] = s:sub(start); return out end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
end
Net.Split = Split

-- Non-negative whole number below a billion, or nil.
local function Num(x)
  local n = tonumber(x)
  if n and n == floor(n) and n >= 0 and n < 1e9 then return n end
  return nil
end

local function SeatNum(x)
  local n = Num(x)
  if n and n >= 1 and n <= 12 then return n end
  return nil
end

local function Cards(s)
  local out = {}
  for tok in tostring(s):gmatch("[^:]+") do
    local c = Num(tok)
    if not c or c < 1 or c > 52 then return nil end
    out[#out + 1] = c
  end
  return out
end

-- Names must not contain the separators.
local function Clean(name)
  return (tostring(name or "?"):gsub("[~;:,|]", ""))
end

local function ShortName(full)
  return (tostring(full):match("^([^%-]+)") or tostring(full))
end
Net.ShortName = ShortName

function Net.Msg(kind, ...)
  local parts = { Net.VERSION, kind }
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  return table.concat(parts, "~")
end

-- Returns kind, fields (array) or nil for anything malformed or from
-- another protocol version.
function Net.Parse(text)
  if type(text) ~= "string" or #text > 255 then return nil end
  local f = Split(text, "~")
  if f[1] ~= Net.VERSION or not f[2] or f[2] == "" then return nil end
  local kind = f[2]
  table.remove(f, 1); table.remove(f, 1)
  return kind, f
end

------------------------------------------------------------------------
-- Event codec
------------------------------------------------------------------------
local ACT = { fold = "f", check = "k", call = "c", bet = "b", raise = "r" }
local ACT_R = {}
for k, v in pairs(ACT) do ACT_R[v] = k end
local ST = { flop = "f", turn = "t", river = "r" }
local ST_R = {}
for k, v in pairs(ST) do ST_R[v] = k end

function Net.EncodeEvent(ev)
  local k = ev.type
  if k == "hand" then
    local bits = {}
    for i = 1, #ev.stacks do bits[i] = ev.inHand[i] and "1" or "0" end
    return ("H,%d,%d,%s,%s"):format(ev.handNo, ev.button, table.concat(ev.stacks, ":"), table.concat(bits))
  elseif k == "blind" then
    return ("B,%d,%d,%s"):format(ev.seat, ev.amount, ev.blind == "small" and "s" or "b")
  elseif k == "deal" then
    return "D"
  elseif k == "action" then
    return ("A,%d,%s,%d,%d"):format(ev.seat, ACT[ev.action], ev.amount or 0, ev.allIn and 1 or 0)
  elseif k == "street" then
    return ("S,%s,%s"):format(ST[ev.street], table.concat(ev.cards, ":"))
  elseif k == "showdown" then
    local seats = {}
    for seat in pairs(ev.hands) do seats[#seats + 1] = seat end
    table.sort(seats)
    local parts = { "X" }
    for _, seat in ipairs(seats) do
      local h = ev.hands[seat].hole
      parts[#parts + 1] = ("%d:%d:%d"):format(seat, h[1], h[2])
    end
    return table.concat(parts, ",")
  elseif k == "win" then
    return ("P,%d,%d,%d"):format(ev.seat, ev.amount, ev.pot or 1)
  elseif k == "handEnd" then
    return "Z," .. (ev.reason == "showdown" and "s" or "f")
  elseif k == "turn" then
    return ("T,%d,%d"):format(ev.seat, ev.secs or 0)
  end
  return nil
end

-- Returns an event table (as the engine would emit it) or nil.
-- Showdown hand names and win hand names are filled in by the client,
-- which knows the board.
function Net.DecodeEvent(s)
  local f = Split(s, ",")
  local k = f[1]
  if k == "H" then
    local handNo, button = Num(f[2]), SeatNum(f[3])
    local stacks = {}
    for tok in tostring(f[4] or ""):gmatch("[^:]+") do
      local n = Num(tok)
      if not n then return nil end
      stacks[#stacks + 1] = n
    end
    local bits = f[5] or ""
    if not handNo or not button or #stacks == 0 or #bits ~= #stacks then return nil end
    local inHand = {}
    for i = 1, #bits do inHand[i] = bits:sub(i, i) == "1" end
    return { type = "hand", handNo = handNo, button = button, stacks = stacks, inHand = inHand }
  elseif k == "B" then
    local seat, amount = SeatNum(f[2]), Num(f[3])
    if not seat or not amount or (f[4] ~= "s" and f[4] ~= "b") then return nil end
    return { type = "blind", seat = seat, amount = amount, blind = f[4] == "s" and "small" or "big" }
  elseif k == "D" then
    return { type = "deal" }
  elseif k == "A" then
    local seat, action, amount = SeatNum(f[2]), ACT_R[f[3] or ""], Num(f[4])
    if not seat or not action or not amount then return nil end
    local ev = { type = "action", seat = seat, action = action, allIn = f[5] == "1" }
    if action ~= "fold" and action ~= "check" then ev.amount = amount end
    return ev
  elseif k == "S" then
    local street, cards = ST_R[f[2] or ""], Cards(f[3] or "")
    if not street or not cards or #cards ~= Poker.BOARD_COUNT[street] then return nil end
    return { type = "street", street = street, cards = cards }
  elseif k == "X" then
    local hands = {}
    for i = 2, #f do
      local c = Cards(f[i])
      if not c or #c ~= 3 or c[1] > 12 then return nil end
      hands[c[1]] = { hole = { c[2], c[3] } }
    end
    return { type = "showdown", hands = hands }
  elseif k == "P" then
    local seat, amount, pot = SeatNum(f[2]), Num(f[3]), Num(f[4])
    if not seat or not amount or not pot then return nil end
    return { type = "win", seat = seat, amount = amount, pot = pot }
  elseif k == "Z" then
    if f[2] ~= "s" and f[2] ~= "f" then return nil end
    return { type = "handEnd", reason = f[2] == "s" and "showdown" or "fold" }
  elseif k == "T" then
    local seat, secs = SeatNum(f[2]), Num(f[3])
    if not seat or not secs then return nil end
    return { type = "turn", seat = seat, secs = secs }
  end
  return nil
end

------------------------------------------------------------------------
-- Host
------------------------------------------------------------------------
local Host = {}
Host.__index = Host

-- opts: me (full name), channel ("PARTY"/"RAID"/"GUILD"), stake key,
-- buyIn, now (clock fn), bots (list of Bots.CAST entries), rng, pace (fn),
-- rollouts.
function Net.NewHost(o)
  local st = assert(Net.STAKES[o.stake], "unknown stake")
  local h = setmetatable({}, Host)
  h.kind = "host"
  h.me = o.me
  h.channel = o.channel
  h.stakeKey = o.stake
  h.now = o.now
  h.rng = o.rng or math.random
  h.pace = o.pace or function() return 1 end
  h.rollouts = o.rollouts or 150
  h.id = tostring(h.rng(9000) + 999)
  local seats = { { name = Clean(ShortName(o.me)), stack = o.buyIn, human = true, owner = o.me } }
  for _, bot in ipairs(o.bots or {}) do
    if #seats < Net.MAX_SEATS then
      seats[#seats + 1] = { name = bot.name, stack = Net.MAX_BUYIN_BB * st.bb, bot = bot }
    end
  end
  h.t = Poker.NewTable({ seats = seats, sb = st.sb, bb = st.bb, button = h.rng(#seats), rng = h.rng })
  h.mySeat = 1
  h.seatOf = { [o.me] = 1 }
  h.out, h.pending, h.after = {}, {}, {}
  h.sentHand, h.sentCount, h.seq = 0, 0, 0
  h.handStart = {}
  h:Announce()
  h:Roster()
  return h
end

function Host:Queue(kind, target, text) self.out[#self.out + 1] = { kind = kind, target = target, text = text } end
function Host:Broadcast(text) self:Queue(self.channel, nil, text) end
function Host:Whisper(target, text) self:Queue("WHISPER", target, text) end

function Host:HandRunning()
  return self.t.street ~= "done" and self.t.street ~= "idle"
end

function Host:SeatedCount()
  local n = 0
  for _, p in ipairs(self.t.seats) do if not p.gone then n = n + 1 end end
  return n
end

function Host:Announce()
  self:Broadcast(Net.Msg("T", self.id, self.stakeKey, self:SeatedCount(), Net.MAX_SEATS,
    self:HandRunning() and 1 or 0, Clean(ShortName(self.me))))
  self.nextAnnounce = self.now() + Net.ANNOUNCE_EVERY
end

function Host:RosterString()
  local parts = {}
  for i, p in ipairs(self.t.seats) do
    local kind = p.gone and "e" or (i == self.mySeat and "h") or (p.bot and "b") or "p"
    parts[#parts + 1] = ("%d:%s:%s:%d"):format(i, kind, Clean(p.name), p.stack)
  end
  return table.concat(parts, ";")
end

function Host:Roster()
  self:Broadcast(Net.Msg("R", self.id, self:RosterString()))
end

-- Queue every new engine event, plus a turn marker (and the player's
-- private "your turn" message) whenever a new decision is due.
function Host:Collect()
  local t = self.t
  if t.handNo ~= self.sentHand then self.sentHand, self.sentCount = t.handNo, 0 end
  for i = self.sentCount + 1, #t.events do
    local ev = t.events[i]
    if ev.type == "hand" then
      self.handStart = {}
      for s, v in ipairs(ev.stacks) do self.handStart[s] = v end
    end
    local enc = Net.EncodeEvent(ev)
    if enc then self.pending[#self.pending + 1] = enc end
  end
  self.sentCount = #t.events

  if self:HandRunning() and t.toAct then
    local key = t.handNo .. ":" .. #t.events .. ":" .. t.toAct
    if key ~= self.turnKey then
      self.turnKey = key
      local p = t.seats[t.toAct]
      self.thinkUntil = nil
      if p.bot then
        self.deadline = nil
        self.pending[#self.pending + 1] = ("T,%d,0"):format(t.toAct)
      else
        self.deadline = self.now() + Net.TURN_TIMEOUT
        self.pending[#self.pending + 1] = ("T,%d,%d"):format(t.toAct, Net.TURN_TIMEOUT)
        if t.toAct ~= self.mySeat then self:SendYourTurn(t.toAct) end
      end
    end
  else
    self.turnKey, self.deadline, self.thinkUntil = nil, nil, nil
    if not self:HandRunning() then self:AfterHand() end
  end
end

function Host:SendYourTurn(seat)
  local t, p = self.t, self.t.seats[seat]
  local la = Poker.LegalActions(t, seat)
  if not la or not p.owner then return end
  self:Whisper(p.owner, Net.Msg("Y", self.id, t.handNo, la.check and 1 or 0, la.call, la.canRaise and 1 or 0,
    la.minRaiseTo or 0, la.maxRaiseTo or 0, la.isBet and 1 or 0, la.currentBet, Net.TURN_TIMEOUT))
end

-- Remove leavers and busted players once a hand is over.
function Host:AfterHand()
  for i, p in ipairs(self.t.seats) do
    if not p.gone and i ~= self.mySeat and not p.bot and (p.leaving or p.stack <= 0) then
      self:RemoveSeat(i)
    end
  end
end

function Host:RemoveSeat(seat)
  local p = self.t.seats[seat]
  if not p or p.gone then return end
  if p.owner then
    -- Sent after the queued events, so the player sees the hand finish first.
    self.after[#self.after + 1] = { kind = "WHISPER", target = p.owner, text = Net.Msg("BYE", self.id, seat, p.stack) }
    self.seatOf[p.owner] = nil
  end
  p.gone, p.sittingOut, p.stack = true, true, 0
  p.owner, p.leaving, p.name = nil, nil, "(empty)"
  p.inHand, p.folded = false, false
  self:Roster()
  self:Announce()
end

function Host:Legal()
  return Poker.LegalActions(self.t, self.mySeat)
end

function Host:ActFor(seat, action)
  local ok, err = Poker.Act(self.t, seat, action)
  if ok then self:Collect() end
  return ok, err
end

-- The local (host) player's action.
function Host:Act(action)
  if self.t.toAct ~= self.mySeat then return false, "not your turn" end
  return self:ActFor(self.mySeat, action)
end

function Host:CanDeal()
  if self:HandRunning() then return false, "Hand in progress..." end
  if self.t.seats[self.mySeat].stack <= 0 then return false, "You're busted" end
  local players = 0
  for _, p in ipairs(self.t.seats) do if not p.gone and (p.stack > 0 or p.bot) then players = players + 1 end end
  if players < 2 then return false, "Waiting for players" end
  return true
end

function Host:Deal()
  if not self:CanDeal() then return false end
  local st = self.t
  for _, p in ipairs(st.seats) do
    if p.bot and p.stack <= 0 then p.stack = Net.MAX_BUYIN_BB * st.bb end
  end
  self:Roster()   -- everyone starts each hand with the same seat list
  local ok = Poker.StartHand(st)
  if not ok then return false end
  for i, p in ipairs(st.seats) do
    if p.inHand and p.owner and i ~= self.mySeat then
      self:Whisper(p.owner, Net.Msg("C", self.id, st.handNo, p.hole[1] .. ":" .. p.hole[2]))
    end
  end
  self:Collect()
  self:Announce()
  return true
end

-- Host leaving closes the table. Everyone (host included) gets back their
-- stack from the start of an unfinished hand.
function Host:Leave()
  self:Broadcast(Net.Msg("X", self.id))
  self.closed = true
  local p = self.t.seats[self.mySeat]
  if self:HandRunning() then return self.handStart[self.mySeat] or p.stack end
  return p.stack
end

function Host:Join(sender, buyIn)
  local bb = self.t.bb
  buyIn = Num(buyIn)
  if not buyIn or buyIn < Net.MIN_BUYIN_BB * bb then
    self:Whisper(sender, Net.Msg("NO", self.id, "buyin"))
    return
  end
  buyIn = math.min(buyIn, Net.MAX_BUYIN_BB * bb)
  -- Rejoining (after a reload the client already got its old stack back).
  if self.seatOf[sender] then
    local old = self.seatOf[sender]
    local p = self.t.seats[old]
    self.seatOf[sender] = nil
    p.owner = nil
    if self:HandRunning() and p.inHand and not p.folded then p.leaving = true else self:RemoveSeat(old) end
  end
  local seat
  for i, p in ipairs(self.t.seats) do
    if p.gone and not (self:HandRunning() and p.inHand) then seat = i; break end
  end
  if not seat then
    if #self.t.seats >= Net.MAX_SEATS then
      self:Whisper(sender, Net.Msg("NO", self.id, "full"))
      return
    end
    seat = #self.t.seats + 1
    self.t.seats[seat] = { seat = seat }
  end
  local p = self.t.seats[seat]
  p.name, p.stack, p.owner, p.strikes = Clean(ShortName(sender)), buyIn, sender, 0
  p.gone, p.sittingOut, p.leaving, p.bot, p.human = nil, nil, nil, nil, true
  p.inHand, p.folded, p.allIn, p.bet, p.totalIn, p.hole = false, false, false, 0, 0, nil
  self.seatOf[sender] = seat
  -- The seat list rides along: the group-channel roster can arrive before
  -- this whisper, and a player who is not seated yet would ignore it.
  self:Whisper(sender, Net.Msg("OK", self.id, seat, buyIn, self:RosterString()))
  self:Roster()
  self:Announce()
end

function Host:OnMessage(sender, text)
  if self.closed then return end
  local kind, f = Net.Parse(text)
  if not kind then return end
  if kind == "Q" then
    self:Announce()
    return
  end
  if f[1] ~= self.id then return end
  if kind == "J" then
    self:Join(sender, f[2])
  elseif kind == "A" then
    local seat = self.seatOf[sender]
    local t = self.t
    if seat and seat ~= self.mySeat and t.toAct == seat and Num(f[2]) == t.handNo then
      local ok = self:ActFor(seat, { type = f[3], amount = Num(f[4]) })
      if ok then t.seats[seat].strikes = 0
      elseif t.toAct == seat then self:SendYourTurn(seat) end   -- bad input: ask again
    end
  elseif kind == "L" then
    local seat = self.seatOf[sender]
    if not seat then return end
    local p = self.t.seats[seat]
    if self:HandRunning() and p.inHand and not p.folded then
      p.leaving = true
    else
      self:RemoveSeat(seat)
    end
  end
end

function Host:Pump()
  if self.closed then return end
  local now = self.now()
  if now >= (self.nextAnnounce or 0) then self:Announce() end
  local t = self.t
  if not self:HandRunning() or not t.toAct then return end
  local seat = t.toAct
  local p = t.seats[seat]
  if p.bot then
    if not self.thinkUntil then
      local lo, hi = Net.THINK[1], Net.THINK[2]
      self.thinkUntil = now + (lo + (hi - lo) * self.rng(1000) / 1000) * self.pace()
    elseif now >= self.thinkUntil then
      self.thinkUntil = nil
      local action = Bots.Decide(p.bot, Poker.ViewFor(t, seat), self.rng, { rollouts = self.rollouts })
      if not self:ActFor(seat, action) then
        local la = Poker.LegalActions(t, seat)
        self:ActFor(seat, { type = la and la.check and "check" or "fold" })
      end
    end
  elseif p.leaving or (self.deadline and now >= self.deadline) then
    local la = Poker.LegalActions(t, seat)
    if not p.leaving and seat ~= self.mySeat then
      p.strikes = (p.strikes or 0) + 1
      if p.strikes >= 2 then p.leaving = true end
    end
    self:ActFor(seat, { type = (la and la.check and not p.leaving) and "check" or "fold" })
  end
end

function Host:TurnSecondsLeft()
  if not self.deadline then return nil end
  return math.max(0, math.ceil(self.deadline - self.now()))
end

-- Next message to send, or nil. Control messages first; queued events are
-- batched into as few "E" messages as fit; removals ("BYE") go last.
function Host:NextMessage()
  if #self.out > 0 then return table.remove(self.out, 1) end
  if #self.pending == 0 then
    if #self.after > 0 then return table.remove(self.after, 1) end
    return nil
  end
  local header = Net.Msg("E", self.id, self.seq + 1, "")
  local body, used = {}, #header
  while #self.pending > 0 do
    local ev = self.pending[1]
    local add = #ev + (#body > 0 and 1 or 0)
    if #body > 0 and used + add > Net.MAX_LEN then break end
    body[#body + 1] = table.remove(self.pending, 1)
    used = used + add
  end
  self.seq = self.seq + 1
  return { kind = self.channel, text = header .. table.concat(body, ";") }
end

------------------------------------------------------------------------
-- Client (browsing for tables, then seated at one)
------------------------------------------------------------------------
local Client = {}
Client.__index = Client

-- opts: me (full name), now (clock fn), callbacks: onSeated(seat, buyIn),
-- onRejected(reason), onGone(stack, why) (removed, table closed or host lost),
-- onRoster().
function Net.NewClient(o)
  local c = setmetatable({}, Client)
  c.kind = "client"
  c.me = o.me
  c.now = o.now
  c.cb = o
  c.tables = {}
  c.out = {}
  c.state = "browsing"
  return c
end

function Client:Queue(kind, target, text) self.out[#self.out + 1] = { kind = kind, target = target, text = text } end

function Client:Query(channel)
  self:Queue(channel, nil, Net.Msg("Q"))
end

-- Announced tables heard from recently, newest first.
function Client:Tables()
  local now, list = self.now(), {}
  for id, tb in pairs(self.tables) do
    if now - tb.seen <= Net.TABLE_FORGET then list[#list + 1] = tb else self.tables[id] = nil end
  end
  table.sort(list, function(a, b) return a.seen > b.seen end)
  return list
end

function Client:Join(id, buyIn)
  local tb = self.tables[id]
  if not tb or self.state ~= "browsing" then return false end
  self.state, self.joinId, self.host, self.joinSent = "joining", id, tb.host, self.now()
  self.stakeKey = tb.stake
  self:Queue("WHISPER", tb.host, Net.Msg("J", id, buyIn))
  return true
end

local function NewReplica()
  return { seats = {}, street = "idle", events = {}, handNo = 0, board = {} }
end

function Client:Seat(i)
  local t = self.t
  for k = #t.seats + 1, i do t.seats[k] = { seat = k, name = "(empty)", stack = 0, gone = true } end
  return t.seats[i]
end

function Client:OnRoster(field)
  for _, part in ipairs(Split(field or "", ";")) do
    local f = Split(part, ":")
    local seat, stack = SeatNum(f[1]), Num(f[4])
    if seat and stack and f[2] and f[3] then
      local p = self:Seat(seat)
      p.name, p.gone = f[3], f[2] == "e"
      p.bot = f[2] == "b" and Bots.BY_NAME[f[3]] or nil
      p.isHost = f[2] == "h"
      if not self:HandRunning() or p.gone then p.stack = stack end
      if p.gone then p.inHand, p.folded = false, false end
    end
  end
  if self.cb.onRoster then self.cb.onRoster() end
end

function Client:HandRunning()
  return self.t and self.t.street ~= "done" and self.t.street ~= "idle"
end

-- Apply one decoded event: live model, replica fields, then the event log
-- the table UI replays.
function Client:OnEvent(ev)
  -- Joined mid-hand: sit out the rest of it and start from the next deal.
  if not self.synced then
    if ev.type ~= "hand" then return end
    self.synced = true
  end
  local t, vm = self.t, self.liveVM
  if ev.type == "showdown" then
    for _, h in pairs(ev.hands) do
      local cards = { h.hole[1], h.hole[2] }
      for _, c in ipairs(vm.board) do cards[#cards + 1] = c end
      if #cards >= 5 then h.name = Poker.Evaluate(cards).name else h.name = "" end
    end
  elseif ev.type == "win" then
    local s = vm.seats[ev.seat]
    ev.hand = s and s.shown and s.shown.name or nil
  elseif ev.type == "hand" then
    if #vm.seats < #ev.stacks then vm = Poker.NewDisplay(#ev.stacks); self.liveVM = vm end
    for i = 1, #ev.stacks do
      local p = self:Seat(i)
      if ev.inHand[i] and p.gone then
        -- Dealt in but missing from our seat list: show them anyway.
        p.gone = false
        if p.name == "(empty)" then p.name = "Player " .. i end
      end
    end
  end
  if ev.type ~= "turn" then Poker.ApplyEvent(vm, ev) end

  if ev.type == "hand" then
    t.handNo, t.button, t.street, t.board = ev.handNo, ev.button, "preflop", {}
    self.handStartStack = ev.stacks[self.mySeat]
    -- "Your turn" can arrive before this hand's first events; keep it.
    if self.legal and self.legal.handNo ~= ev.handNo then self.legal = nil end
    local mine = self.holes and self.holes[ev.handNo]
    local me = t.seats[self.mySeat]
    if me then me.hole = mine end
  elseif ev.type == "street" then
    t.street = ev.street
  elseif ev.type == "handEnd" then
    t.street, t.toAct, self.legal = "done", nil, nil
  elseif ev.type == "turn" then
    t.toAct = ev.seat
    t.turnDeadline = ev.secs > 0 and (self.now() + ev.secs) or nil
  elseif ev.type == "action" and ev.seat == t.toAct then
    t.toAct = nil
  end
  for i, s in ipairs(vm.seats) do
    local p = self:Seat(i)
    p.stack, p.inHand, p.folded = s.stack, s.inHand, s.folded
  end
  t.board = vm.board
  t.events[#t.events + 1] = ev
end

function Client:Gone(stack, why)
  if self.state ~= "seated" then return end
  self.state = "gone"
  self.legal = nil
  if self.cb.onGone then self.cb.onGone(stack, why) end
end

-- What we get back if the hand is abandoned (host closed or vanished).
function Client:RefundIfAbandoned()
  local me = self.t.seats[self.mySeat]
  if self:HandRunning() then return self.handStartStack or (me and me.stack) or 0 end
  return me and me.stack or 0
end

function Client:OnMessage(sender, text, channel)
  local kind, f = Net.Parse(text)
  if not kind then return end
  local now = self.now()
  if kind == "T" then
    local id, stake, seated, max = f[1], f[2], Num(f[3]), Num(f[4])
    if id and Net.STAKES[stake or ""] and seated and max then
      self.tables[id] = { id = id, host = sender, hostName = f[6] or ShortName(sender), stake = stake,
                          seated = seated, max = max, running = f[5] == "1", channel = channel, seen = now }
    end
  end
  if kind == "Q" or sender ~= self.host then return end
  if f[1] ~= self.joinId then return end
  self.lastHost = now

  if kind == "OK" and self.state == "joining" then
    local seat, buyIn = SeatNum(f[2]), Num(f[3])
    if not seat or not buyIn then return end
    self.state, self.mySeat, self.buyIn = "seated", seat, buyIn
    self.t = NewReplica()
    self.liveVM = Poker.NewDisplay(seat)
    self.holes, self.seq = {}, 0
    local p = self:Seat(seat)
    p.stack, p.gone, p.name = buyIn, false, Clean(ShortName(self.me))
    if f[4] then self:OnRoster(f[4]) end
    if self.earlyRoster then self:OnRoster(self.earlyRoster); self.earlyRoster = nil end
    if self.cb.onSeated then self.cb.onSeated(seat, buyIn) end
  elseif kind == "NO" and self.state == "joining" then
    self.state, self.host, self.joinId = "browsing", nil, nil
    if self.cb.onRejected then self.cb.onRejected(f[2] or "?") end
  elseif kind == "R" and self.state == "joining" then
    self.earlyRoster = f[2]      -- arrived before our OK; applied once seated
  elseif self.state ~= "seated" then
    return
  elseif kind == "R" then
    self:OnRoster(f[2])
  elseif kind == "E" then
    local seq = Num(f[2])
    if not seq or seq <= self.seq then return end
    self.seq = seq
    for _, enc in ipairs(Split(f[3] or "", ";")) do
      local ev = enc ~= "" and Net.DecodeEvent(enc)
      if ev then self:OnEvent(ev) end
    end
  elseif kind == "C" then
    local handNo, cards = Num(f[2]), Cards(f[3] or "")
    if handNo and cards and #cards == 2 then
      self.holes[handNo] = cards
      if self.t.handNo == handNo then self.t.seats[self.mySeat].hole = cards end
    end
  elseif kind == "Y" then
    local handNo = Num(f[2])
    if not handNo then return end
    self.legal = {
      handNo = handNo, check = f[3] == "1", call = Num(f[4]) or 0, canRaise = f[5] == "1",
      minRaiseTo = Num(f[6]), maxRaiseTo = Num(f[7]), isBet = f[8] == "1",
      currentBet = Num(f[9]) or 0, deadline = now + (Num(f[10]) or Net.TURN_TIMEOUT),
    }
    if not self.legal.canRaise then self.legal.minRaiseTo, self.legal.maxRaiseTo = nil, nil end
  elseif kind == "BYE" then
    self:Gone(Num(f[3]) or 0, "removed")
  elseif kind == "X" then
    self:Gone(self:RefundIfAbandoned(), "closed")
  end
end

function Client:Pump()
  local now = self.now()
  if self.state == "joining" and now - self.joinSent > Net.JOIN_TIMEOUT then
    self.state, self.host, self.joinId = "browsing", nil, nil
    if self.cb.onRejected then self.cb.onRejected("noanswer") end
  elseif self.state == "seated" and now - (self.lastHost or now) > Net.HOST_TIMEOUT then
    self:Gone(self:RefundIfAbandoned(), "lost")
  end
end

-- Session interface used by the table UI --------------------------------

function Client:Legal()
  local la = self.legal
  if la and self.t and la.handNo == self.t.handNo and self:HandRunning() then return la end
  return nil
end

function Client:Act(action)
  local la = self:Legal()
  if not la then return false, "not your turn" end
  local kind = action.type
  local amount = floor(tonumber(action.amount) or 0)
  if kind == "check" and not la.check then return false, "cannot check, there is a bet" end
  if kind == "raise" then
    if not la.canRaise then return false, "raising is not allowed" end
    if amount < la.minRaiseTo or amount > la.maxRaiseTo then return false, "raise out of range" end
  end
  self:Queue("WHISPER", self.host, Net.Msg("A", self.joinId, la.handNo, kind, amount))
  self.legal = nil
  return true
end

function Client:CanDeal() return false, "Waiting for the host..." end
function Client:Deal() return false end

-- Leave between hands or after folding. Returns the stack to cash out.
function Client:Leave()
  if self.state ~= "seated" then return 0 end
  local me = self.t.seats[self.mySeat]
  self:Queue("WHISPER", self.host, Net.Msg("L", self.joinId))
  self.state = "left"
  return me and me.stack or 0
end

function Client:TurnSecondsLeft()
  local d = self.t and self.t.turnDeadline
  if not d then return nil end
  return math.max(0, math.ceil(d - self.now()))
end

function Client:NextMessage()
  if #self.out > 0 then return table.remove(self.out, 1) end
  return nil
end

return Net
