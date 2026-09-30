-- lua tests/test_poker_net.lua   (run from the GoblinGambling/ folder)
-- Multiplayer protocol: a host and clients talk over an in-memory "chat"
-- that behaves like WoW's addon channels (broadcasts reach everyone else,
-- whispers reach one player).
local H = dofile("tests/helpers.lua")
local GG = H.load("Games/PokerLogic.lua")
H.load("Games/PokerBots.lua")
H.load("Games/PokerNet.lua")
local P, B, Net = GG.PokerLogic, GG.PokerBots, GG.PokerNet
math.randomseed(99)

------------------------------------------------------------------------
-- Codec
------------------------------------------------------------------------
H.eq(Net.Parse("2~E~1~1~D"), nil, "other protocol versions ignored")
H.eq(Net.Parse("garbage"), nil, "garbage ignored")
H.eq(Net.Parse(string.rep("x", 300)), nil, "oversized ignored")
local kind, f = Net.Parse("1~J~1234~500")
H.eq(kind, "J", "parse kind")
H.eq(f[1], "1234", "parse field 1")
H.eq(f[2], "500", "parse field 2")
for _, bad in ipairs({ "H,1", "H,1,2,100:200,1", "A,99,k,0,0", "A,1,z,0,0", "S,f,1:2", "S,x,1:2:3",
                       "X,1:2", "X,1:2:60", "P,1,-5,1", "Z,q", "T,1", "Q,1", "B,1,5,x", "" }) do
  H.eq(Net.DecodeEvent(bad), nil, "rejects bad event '" .. bad .. "'")
end

-- Round trip every event of 2000 simulated hands; replaying decoded events
-- gives the same table as replaying the originals.
local rng = H.rng(12)
local seats = {}
for i, st in ipairs({ 1000, 40, 700, 15, 2500, 300 }) do seats[i] = { name = "S" .. i, stack = st } end
local t = P.NewTable({ seats = seats, rng = rng })
local longest = 0
for _ = 1, 2000 do
  for _, p in ipairs(t.seats) do if p.stack == 0 then p.stack = 500 end end
  P.StartHand(t)
  while t.street ~= "done" do
    local la = P.LegalActions(t, t.toAct)
    local r = rng(100)
    local a = (la.canRaise and r <= 20) and { type = "allin" } or (r <= 45 and { type = "fold" })
      or (la.check and { type = "check" }) or { type = "call" }
    P.Act(t, t.toAct, a)
  end
  local a, b = P.NewDisplay(6), P.NewDisplay(6)
  for _, ev in ipairs(t.events) do
    P.ApplyEvent(a, ev)
    local enc = Net.EncodeEvent(ev)
    H.ok(enc and not enc:find("[~;|]"), "encoded event has no separators")
    if #enc > longest then longest = #enc end
    local dec = Net.DecodeEvent(enc)
    H.ok(dec, "decodes: " .. enc)
    if dec.type == "showdown" then
      for s, h in pairs(dec.hands) do
        H.eq(h.hole[1], t.seats[s].hole[1], "showdown card 1")
        h.name = ev.hands[s].name
      end
    end
    if dec.type == "win" then dec.hand = ev.hand end
    P.ApplyEvent(b, dec)
  end
  for i = 1, 6 do H.eq(b.seats[i].stack, a.seats[i].stack, "decoded replay stack") end
  H.eq(#b.board, #a.board, "decoded board")
end
H.ok(longest < 80, "events are short (" .. longest .. " chars max)")

------------------------------------------------------------------------
-- In-memory chat
------------------------------------------------------------------------
local now = 0
local function clock() return now end
local nodes, order, log = {}, {}, {}
local mute = {}          -- players whose messages are lost (offline)
local afk = {}           -- players still online who stop acting
local function add(name, node) nodes[name] = node; order[#order + 1] = name end
local function remove(name)
  nodes[name] = nil
  for i, n in ipairs(order) do if n == name then table.remove(order, i) end end
end

local function deliver(from, msg)
  H.ok(#msg.text <= Net.MAX_LEN, "message within the size limit")
  log[#log + 1] = { from = from, kind = msg.kind, target = msg.target, text = msg.text }
  if msg.kind == "WHISPER" then
    local n = nodes[msg.target]
    if n and not mute[msg.target] then n:OnMessage(from, msg.text, "WHISPER") end
  else
    for _, name in ipairs(order) do
      if name ~= from and not mute[name] then nodes[name]:OnMessage(from, msg.text, msg.kind) end
    end
  end
end

local function pump(dt)
  now = now + (dt or 0.1)
  for _, name in ipairs(order) do
    local n = nodes[name]
    if n and not mute[name] then n:Pump() end
  end
  local moved = true
  while moved do
    moved = false
    for _, name in ipairs(order) do
      local n = nodes[name]
      if n and not mute[name] then
        local msg = n:NextMessage()
        while msg do
          deliver(name, msg)
          moved = true
          msg = n:NextMessage()
        end
      end
    end
  end
end

-- Wallets: each player's own Goblin Gold, outside the table.
local wallet = { ["Hosty-Realm"] = 5000, ["Alice-Realm"] = 5000, ["Bob-Realm"] = 5000 }
local gone = {}
local function newClient(name)
  wallet[name] = wallet[name] or 100000
  local c
  c = Net.NewClient({
    me = name, now = clock,
    onSeated = function(_, buyIn) wallet[name] = wallet[name] - buyIn end,
    onRejected = function(reason) c.rejected = reason end,
    onGone = function(stack, why) wallet[name] = wallet[name] + stack; gone[name] = why; c.goneStack = stack end,
  })
  add(name, c)
  return c
end

local host = Net.NewHost({ me = "Hosty-Realm", channel = "PARTY", stake = "copper", buyIn = 1000, now = clock,
  rng = H.rng(3), bots = { B.BY_NAME.Thorgrim, B.BY_NAME["Moo-Tan"] }, rollouts = 6 })
wallet["Hosty-Realm"] = wallet["Hosty-Realm"] - 1000
add("Hosty-Realm", host)
local alice, bob = newClient("Alice-Realm"), newClient("Bob-Realm")

------------------------------------------------------------------------
-- Discovery and joining
------------------------------------------------------------------------
alice:Query("PARTY")
pump()
local list = alice:Tables()
H.eq(#list, 1, "alice sees one table")
H.eq(list[1].hostName, "Hosty", "host name shown")
H.eq(list[1].stake, "copper", "stakes announced")
H.eq(list[1].channel, "PARTY", "channel remembered")
H.eq(#bob:Tables(), 1, "bob heard the announcement too")

alice:Join(list[1].id, 50)            -- below 20 big blinds
pump()
H.eq(alice.rejected, "buyin", "tiny buy-in refused")
H.eq(alice.state, "browsing", "back to browsing")

H.ok(alice:Join(host.id, 1000), "join sent")
H.ok(bob:Join(host.id, 5000), "bob asks for too much")
pump()
H.eq(alice.state, "seated", "alice seated")
H.eq(bob.state, "seated", "bob seated")
H.eq(bob.buyIn, 1000, "buy-in capped at 100 big blinds")
H.eq(wallet["Bob-Realm"], 4000, "bob paid only the capped buy-in")
H.eq(alice.mySeat, 4, "alice after host + 2 bots")
H.eq(bob.mySeat, 5, "bob next")
H.eq(alice.t.seats[2].name, "Thorgrim", "roster reached clients")
H.ok(alice.t.seats[2].bot, "bots marked as bots on clients")
H.eq(host.t.seats[4].name, "Alice", "host shows the short name")

------------------------------------------------------------------------
-- Play
------------------------------------------------------------------------
local actRng = H.rng(77)
local function randomAction(la)
  local r = actRng(100)
  if la.canRaise and r <= 8 then return { type = "allin" } end
  if la.canRaise and r <= 25 then return { type = "raise", amount = la.minRaiseTo } end
  if r <= 45 and la.call > 0 then return { type = "fold" } end
  if la.check then return { type = "check" } end
  return { type = "call" }
end

local function playHand(opts)
  opts = opts or {}
  H.ok(host:Deal(), "host deals")
  local guard = 0
  while host:HandRunning() do
    if host:Legal() then host:Act(randomAction(host:Legal())) end
    for _, c in ipairs({ alice, bob }) do
      if c.state == "seated" and not mute[c.me] and not afk[c.me] and c:Legal() then
        c:Act(randomAction(c:Legal()))
      end
    end
    pump(opts.dt or 0.5)
    guard = guard + 1
    assert(guard < 5000, "hand never finished")
  end
  pump(0.1); pump(0.1)
end

local function checkReplicas(label)
  for _, c in ipairs({ alice, bob }) do
    if c.state == "seated" then
      H.eq(c.t.street, "done", label .. ": client saw the hand end")
      for i, p in ipairs(host.t.seats) do
        if not p.gone then H.eq(c.t.seats[i].stack, p.stack, label .. ": " .. c.me .. " sees seat " .. i) end
      end
      -- The client's event log replays to the same numbers.
      local vm = P.NewDisplay(#host.t.seats)
      for _, ev in ipairs(c.t.events) do if ev.type ~= "turn" then P.ApplyEvent(vm, ev) end end
      for i, p in ipairs(host.t.seats) do
        if not p.gone then H.eq(vm.seats[i].stack, p.stack, label .. ": replayed log") end
      end
    end
  end
end

local showdowns = 0
for hand = 1, 120 do
  local logStart = #log
  local seatOfAtDeal = {}
  for k, v in pairs(host.seatOf) do seatOfAtDeal[k] = v end
  playHand()
  checkReplicas("hand " .. hand)

  -- Hidden information: hole cards only in whispers to their owner, or in
  -- the showdown event for players who reached it.
  local shownSeats = {}
  for i = logStart + 1, #log do
    local m = log[i]
    local k, fields = Net.Parse(m.text)
    if k == "C" then
      H.eq(m.kind, "WHISPER", "hole cards are whispered")
      local seat = seatOfAtDeal[m.target]
      H.ok(seat, "whispered to a seated player")
      local cards = fields[3]
      local p = host.t.seats[seat]
      H.eq(cards, p.hole[1] .. ":" .. p.hole[2], "only their own cards")
    elseif k == "E" then
      for _, enc in ipairs(Net.Split(fields[3], ";")) do
        local ev = Net.DecodeEvent(enc)
        if ev and ev.type == "showdown" then for s in pairs(ev.hands) do shownSeats[s] = true end end
      end
    end
  end
  local expected = host.t.result.reason == "showdown" and host.t.result.hands or {}
  for s in pairs(shownSeats) do H.ok(expected[s], "only showdown players' cards were revealed") end
  for s in pairs(expected) do H.ok(shownSeats[s], "every showdown hand was revealed") end
  if host.t.result.reason == "showdown" then showdowns = showdowns + 1 end

  -- Everyone is responsive here: nobody should ever time out.
  for _, c in ipairs({ alice, bob }) do
    local seat = host.seatOf[c.me]
    if seat then H.eq(host.t.seats[seat].strikes or 0, 0, c.me .. " never timed out") end
  end
  -- Busted humans are removed and can rejoin
  for _, c in ipairs({ alice, bob }) do
    if gone[c.me] == "removed" then
      H.eq(c.goneStack, 0, c.me .. " was only removed for busting")
      gone[c.me] = nil
      c.state = "browsing"
      c:Join(host.id, 1000)
      pump()
    end
  end
  -- Test harness only: a busted host buys back in from its wallet.
  if host.t.seats[1].stack == 0 then
    host.t.seats[1].stack = 1000
    wallet["Hosty-Realm"] = wallet["Hosty-Realm"] - 1000
  end
end
H.ok(showdowns > 5, "played through showdowns (" .. showdowns .. ")")

------------------------------------------------------------------------
-- Spoofing: only the host's messages count, only the right seat may act
------------------------------------------------------------------------
local before = #alice.t.events
alice:OnMessage("Mallory-Realm", Net.Msg("E", host.id, 99999, "H,999,1,5:5,11"), "PARTY")
H.eq(#alice.t.events, before, "events from a non-host are ignored")
alice:OnMessage("Mallory-Realm", Net.Msg("X", host.id), "PARTY")
H.eq(alice.state, "seated", "a fake close from a non-host is ignored")
H.ok(host:Deal(), "deal for spoof test")
pump()
local toAct = host.t.toAct
local events = #host.t.events
host:OnMessage("Mallory-Realm", Net.Msg("A", host.id, host.t.handNo, "fold", 0))
H.eq(#host.t.events, events, "action from a stranger ignored")
local wrong = toAct == alice.mySeat and "Bob-Realm" or "Alice-Realm"
host:OnMessage(wrong, Net.Msg("A", host.id, host.t.handNo, "fold", 0))
H.eq(#host.t.events, events, "action out of turn ignored")
while host:HandRunning() do
  if host:Legal() then host:Act({ type = "fold" }) end
  for _, c in ipairs({ alice, bob }) do if c:Legal() then c:Act({ type = "fold" }) end end
  pump(0.5)
end
pump(); pump()

------------------------------------------------------------------------
-- A player who stops answering is auto-folded, then removed
------------------------------------------------------------------------
afk["Bob-Realm"] = true
for _ = 1, 10 do
  if bob.state ~= "seated" or not host.seatOf["Bob-Realm"] then break end
  playHand({ dt = 5 })
end
H.eq(host.seatOf["Bob-Realm"], nil, "silent player removed from the table")
afk["Bob-Realm"] = nil
pump()
H.eq(gone["Bob-Realm"], "removed", "bob told he was removed")
H.eq(bob.state, "gone", "bob no longer seated")

------------------------------------------------------------------------
-- Leaving between hands: stack comes back, seat opens up, rejoin reuses it
------------------------------------------------------------------------
local aliceSeat = alice.mySeat
local stack = host.t.seats[aliceSeat].stack
local w = wallet["Alice-Realm"]
local refund = alice:Leave()
H.eq(refund, stack, "leave returns exactly the host's stack")
wallet["Alice-Realm"] = w + refund
pump()
H.eq(host.t.seats[aliceSeat].gone, true, "seat freed")
H.eq(host.seatOf["Alice-Realm"], nil, "alice no longer seated on the host")
alice.state = "browsing"
alice:Join(host.id, 1000)
pump()
H.eq(alice.state, "seated", "alice rejoined")
H.eq(alice.mySeat, aliceSeat, "empty seat reused")

------------------------------------------------------------------------
-- Host closes mid-hand: everyone gets their stack from the start of it
------------------------------------------------------------------------
H.ok(host:Deal(), "deal before closing")
pump()
local aliceStart = host.handStart[alice.mySeat]
local hostStart = host.handStart[1]
local aw = wallet["Alice-Realm"]
local hostRefund = host:Leave()
H.eq(hostRefund, hostStart, "host gets its hand-start stack back")
pump()
H.eq(gone["Alice-Realm"], "closed", "alice told the table closed")
H.eq(wallet["Alice-Realm"], aw + aliceStart, "alice gets her hand-start stack back")

------------------------------------------------------------------------
-- Host vanishes: clients give up after the timeout and keep their chips
------------------------------------------------------------------------
remove("Hosty-Realm")
local host2 = Net.NewHost({ me = "Other-Realm", channel = "GUILD", stake = "silver", buyIn = 5000, now = clock,
  rng = H.rng(8), bots = {}, rollouts = 6 })
add("Other-Realm", host2)
local carol = newClient("Carol-Realm")
wallet["Carol-Realm"] = 20000
carol:Query("GUILD")
pump()
carol:Join(host2.id, 5000)
pump()
H.eq(carol.state, "seated", "carol seated at the silver table")
H.eq(carol.stakeKey, "silver", "stake remembered")
mute["Other-Realm"] = true
for _ = 1, 20 do pump(5) end
H.eq(gone["Carol-Realm"], "lost", "carol gave up on a silent host")
H.eq(wallet["Carol-Realm"], 20000, "and got her whole buy-in back")

-- A join that is never answered times out
mute["Other-Realm"] = nil
local dave = newClient("Dave-Realm")
dave:Query("GUILD"); pump()
mute["Other-Realm"] = true
dave:Join(host2.id, 5000)
for _ = 1, 5 do pump(5) end
H.eq(dave.rejected, "noanswer", "unanswered join times out")
H.eq(dave.state, "browsing", "back to browsing")

-- Table full
mute["Other-Realm"] = nil
local full = {}
for i = 1, 6 do
  local c = newClient("P" .. i .. "-Realm")
  c:Query("GUILD"); pump()
  c:Join(host2.id, 5000); pump()
  full[i] = c
end
local seatedCount = 0
for _, c in ipairs(full) do if c.state == "seated" then seatedCount = seatedCount + 1 end end
-- Carol's old seat still exists on the host (it was the host that went
-- quiet), so host + Carol + 4 more fills the six seats.
H.eq(seatedCount, 4, "four more players fill the table")
H.eq(full[5].rejected, "full", "fifth joiner told the table is full")
H.eq(full[6].rejected, "full", "sixth joiner told the table is full")

print(string.format("test_poker_net: %d checks passed (%d showdowns over the network)", H.passed, showdowns))
