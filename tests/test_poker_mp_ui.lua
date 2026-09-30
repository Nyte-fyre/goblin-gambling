-- lua tests/test_poker_mp_ui.lua   (run from the GoblinGambling/ folder)
-- The whole addon (through tests/wowmock.lua) playing multiplayer Hold'em
-- against a second player simulated with Games/PokerNet.lua directly.
--   Part A: the addon joins someone else's table.
--   Part B: the addon hosts and someone joins.
local H = dofile("tests/helpers.lua")
local M = dofile("tests/wowmock.lua")
local GG = M.loadAddon({})
M.fireEvent("ADDON_LOADED", "GoblinGambling")
M.fireEvent("PLAYER_LOGIN")
math.randomseed(2468)

local Net, P, MP, PUI = GG.PokerNet, GG.PokerLogic, GG.PokerMP, GG.PokerUI
PUI.rollouts = 6
local ME = M.player .. "-" .. M.realm

------------------------------------------------------------------------
-- Bridge between the addon (mock WoW) and remote players (PokerNet objects)
------------------------------------------------------------------------
local remotes, remoteOrder = {}, {}
local sentIdx = 0
local sendTimes = {}
local function addRemote(name, node) remotes[name] = node; remoteOrder[#remoteOrder + 1] = name end

local function fireAddon(text, kind, sender)
  M.fireEvent("CHAT_MSG_ADDON", Net.PREFIX, text, kind, sender)
end

local function bridge()
  local moved = true
  while moved do
    moved = false
    -- Addon -> remotes
    while sentIdx < #M.addonSent do
      sentIdx = sentIdx + 1
      local m = M.addonSent[sentIdx]
      sendTimes[#sendTimes + 1] = GetTime()
      H.eq(m.prefix, Net.PREFIX, "only our hidden prefix is used")
      H.ok(#m.text <= 255, "addon message within WoW's limit")
      for _, name in ipairs(remoteOrder) do
        if m.kind ~= "WHISPER" or m.target == name then remotes[name]:OnMessage(ME, m.text, m.kind) end
      end
      moved = true
    end
    -- Remotes -> addon and each other
    for _, name in ipairs(remoteOrder) do
      local n = remotes[name]
      local msg = n:NextMessage()
      while msg do
        if msg.kind == "WHISPER" then
          if msg.target == ME then fireAddon(msg.text, "WHISPER", name) end
        else
          fireAddon(msg.text, msg.kind, name)
          for _, other in ipairs(remoteOrder) do
            if other ~= name then remotes[other]:OnMessage(name, msg.text, msg.kind) end
          end
        end
        moved = true
        msg = n:NextMessage()
      end
    end
  end
end

local function step(dt)
  for _, name in ipairs(remoteOrder) do remotes[name]:Pump() end
  M.advance(dt or 0.25, 0.05)
  bridge()
end

local function runUntil(pred, maxSeconds, each)
  local waited = 0
  while not pred() do
    if each then each() end
    step(0.25)
    waited = waited + 0.25
    if waited > (maxSeconds or 300) then error("timed out", 2) end
  end
end

local function buttonMatching(pattern)
  for _, f in ipairs(M.frames) do
    if f._kind == "Button" and type(f._text) == "string" and f._text:match(pattern) and f:IsVisible() then return f end
  end
end
local function checkbox(label)
  for _, f in ipairs(M.frames) do
    if f._kind == "CheckButton" and f.label and f.label._text == label then return f end
  end
end

local rng = H.rng(55)
local function randomAction(la, careful)
  local r = rng(100)
  if la.canRaise and r <= 8 and not careful then return { type = "raise", amount = la.maxRaiseTo } end
  if la.canRaise and r <= 25 then return { type = "raise", amount = la.minRaiseTo } end
  if r <= 45 and la.call > 0 then return { type = "fold" } end
  if la.check then return { type = "check" } end
  return { type = "call" }
end

local startMoney = 20000
GG.db.balance = startMoney
local function checkMoney(msg)
  local s = GG.db.stats
  local atTable = GG.db.poker and GG.db.poker.stack or 0
  H.eq(GG:GetBalance() + atTable, startMoney + s.totalWon - s.totalWagered + s.bailouts * 1000, "money: " .. msg)
end

GG:ShowWindow()
GG:SelectTab("poker")

------------------------------------------------------------------------
-- Opt-in: nothing happens until multiplayer is enabled
------------------------------------------------------------------------
M.inGroup = true
local host = Net.NewHost({ me = "Hosty-Forever", channel = "PARTY", stake = "copper", buyIn = 1000, now = GetTime,
  rng = H.rng(9), bots = { GG.PokerBots.BY_NAME.Grubnik }, rollouts = 6 })
addRemote("Hosty-Forever", host)
fireAddon(Net.Msg("Q"), "PARTY", "Hosty-Forever")
step()
H.eq(#M.addonSent, 0, "disabled: the addon sends nothing and ignores messages")

-- Everything drawn, so we can look for text on screen.
local drawn = {}
do
  local Widget = getmetatable(UIParent)
  local orig = Widget.SetText
  Widget.SetText = function(self, txt) drawn[self] = txt; return orig(self, txt) end
end
local function onScreen(...)
  local needles = { ... }
  for w, txt in pairs(drawn) do
    if type(txt) == "string" and w:IsVisible() then
      local all = true
      for _, n in ipairs(needles) do if not txt:find(n, 1, true) then all = false end end
      if all then return true end
    end
  end
  return false
end

-- No separate toggle: opening "Play with friends" is the opt-in.
H.eq(checkbox("Enable multiplayer for this session"), nil, "no extra multiplayer checkbox")
buttonMatching("^Play with friends$"):Fire("OnClick")
H.eq(MP.enabled, true, "opening Play with friends turns multiplayer on")
H.ok(buttonMatching("^Open table$"), "multiplayer page shown")
step()
local asked = false
for _, m in ipairs(M.addonSent) do if m.text == Net.Msg("Q") then asked = true end end
H.ok(asked, "and starts looking for tables straight away")
buttonMatching("^Back$"):Fire("OnClick")
H.eq(MP.enabled, false, "Back turns it off again")
buttonMatching("^Play with friends$"):Fire("OnClick")
H.eq(MP.enabled, true, "back on")
step(); step()

------------------------------------------------------------------------
-- Part A: join someone else's table
------------------------------------------------------------------------
runUntil(function() return buttonMatching("^Join %(1,000%)$") ~= nil end, 5)
local join = buttonMatching("^Join %(1,000%)$")
H.ok(join, "host's table listed with a Join button")
join:Fire("OnClick")
runUntil(function() return PUI.Session() ~= nil end, 10)
local s = PUI.Session()
H.eq(s.kind, "client", "seated as a client")
H.eq(GG:GetBalance(), startMoney - 1000, "buy-in paid from Goblin Gold")
H.eq(GG.db.poker.stack, 1000, "stack mirrored")
H.eq(host.t.seats[PUI.MySeat()].name, "Nyte", "host sees us")

-- We see the host, and the felt lists everyone before the first hand.
step(); step()
H.eq(PUI.Table().seats[1].name, "Hosty", "we see the host's seat")
H.eq(PUI.Table().seats[1].gone, false, "host's seat is not blank")
H.ok(onScreen("At the table (3/6)", "Hosty", "host"), "pre-game list shows the host")
H.ok(onScreen("Grubnik", "bot"), "pre-game list shows the bot")
H.ok(onScreen("Nyte", "you"), "pre-game list shows us")
H.ok(onScreen("Waiting for Hosty to deal"), "told who we are waiting for")
H.eq(buttonMatching("^Get a loan$"), nil, "no loan button at a friends' table")
H.eq(GG.db.stats.mp.joined, 1, "joined table counted")

local hands = 0
local function playHostedHand()
  H.ok(host:Deal(), "host deals")
  runUntil(function() return not host:HandRunning() and (PUI.Session() == nil or PUI.Between()) end, 300, function()
    if host:Legal() then host:Act(randomAction(host:Legal())) end
    if PUI.IsHumanTurn() then PUI.Act(randomAction(PUI.Session():Legal(), true)) end
  end)
  hands = hands + 1
  if not PUI.Session() then
    -- Busted: the host removes an empty seat and we are sent back to the lobby.
    H.eq(GG.db.poker, nil, "busted: nothing left at the table")
    checkMoney("after busting at a joined table")
    return
  end
  local t = PUI.Table()
  for i, p in ipairs(host.t.seats) do
    if not p.gone then H.eq(t.seats[i].stack, p.stack, "client view matches host, seat " .. i) end
  end
  local vm = PUI.Display()
  for i, p in ipairs(host.t.seats) do
    if not p.gone then H.eq(vm.seats[i].stack, p.stack, "client display matches host, seat " .. i) end
  end
  checkMoney("after joined hand " .. hands)
end

for _ = 1, 12 do
  if host.t.seats[1].stack == 0 then host.t.seats[1].stack = 1000 end
  if not PUI.Session() or PUI.Table().seats[PUI.MySeat()].stack == 0 then break end
  playHostedHand()
end
H.ok(hands >= 3, "played hands at someone else's table (" .. hands .. ")")
H.eq(GG.db.stats.hands, hands, "those hands count in your stats")
H.eq(GG.db.stats.mp.hands, hands, "and in the With friends stats")
H.ok(not onScreen("At the table ("), "pre-game list gone once hands are dealt")

-- On another tab when it becomes our turn: the casino jumps to poker.
if not PUI.Session() then
  -- Busted earlier: sit back down first.
  runUntil(function() return buttonMatching("^Join %(1,000%)$") ~= nil end, 5)
  buttonMatching("^Join %(1,000%)$"):Fire("OnClick")
  runUntil(function() return PUI.Session() ~= nil end, 10)
end
local jumped = false
for _ = 1, 6 do
  if not PUI.Session() or PUI.Table().seats[PUI.MySeat()].stack == 0 then break end
  if host.t.seats[1].stack == 0 then host.t.seats[1].stack = 1000 end
  H.ok(host:Deal(), "deal for the tab test")
  GG:SelectTab("stats")
  local sawTurn = false
  runUntil(function() return not host:HandRunning() and (PUI.Session() == nil or PUI.Between()) end, 300, function()
    if host:Legal() then host:Act({ type = host:Legal().check and "check" or "call" }) end
    local s = PUI.Session()
    if s and s:Legal() and not sawTurn then
      sawTurn = true
      step(0.05)
      jumped = GG.db.settings.lastTab == "poker"
    end
    if PUI.IsHumanTurn() then PUI.Act({ type = PUI.Session():Legal().check and "check" or "call" }) end
  end)
  hands = hands + 1
  if sawTurn then break end
end
H.ok(jumped, "switched to the poker tab when it became our turn")

-- Deal button shows we wait for the host
if PUI.Session() then H.ok(buttonMatching("^Waiting for the host"), "clients cannot deal") end

-- Leave: stack comes back, host frees the seat
if PUI.Session() then
  local mySeat = PUI.MySeat()
  local stack = PUI.Table().seats[mySeat].stack
  local bal = GG:GetBalance()
  H.eq(PUI.Leave(), true, "leave the table")
  H.eq(GG:GetBalance(), bal + stack, "stack cashed out")
  runUntil(function() return host.t.seats[mySeat].gone end, 10)
  H.ok(host.seatOf[ME] == nil, "host let us go")
  checkMoney("after leaving a joined table")
end

-- Host closes mid-hand: we get our hand-start stack back
runUntil(function() return buttonMatching("^Join %(1,000%)$") ~= nil end, 5)
buttonMatching("^Join %(1,000%)$"):Fire("OnClick")
runUntil(function() return PUI.Session() ~= nil end, 10)
H.ok(host:Deal(), "deal before the host closes")
runUntil(function() return PUI.Display().handNo == host.t.handNo end, 20)
local handStartStack = host.handStart[PUI.MySeat()]
local bal = GG:GetBalance()
host:Leave()
runUntil(function() return PUI.Session() == nil end, 10)
H.eq(GG:GetBalance(), bal + handStartStack, "refunded the stack from the start of the abandoned hand")
checkMoney("after the host closed")

remotes["Hosty-Forever"] = nil
remoteOrder = {}

------------------------------------------------------------------------
-- Part B: host a table; a friend joins
------------------------------------------------------------------------
local alice
alice = Net.NewClient({ me = "Alice-Forever", now = GetTime,
  onSeated = function() end, onRejected = function() end,
  onGone = function(stack, why) alice.goneWith, alice.goneWhy = stack, why end })
addRemote("Alice-Forever", alice)

-- 1 bot, copper, group
PUI.MPState.stake, PUI.MPState.channel, PUI.MPState.bots = 1, 1, 1
local balBefore = GG:GetBalance()
buttonMatching("^Open table$"):Fire("OnClick")
local hs = PUI.Session()
H.eq(hs and hs.kind, "host", "hosting")
H.eq(GG:GetBalance(), balBefore - 1000, "host buy-in paid")
step()

alice:Query("PARTY")
step(); step()
H.eq(#alice:Tables(), 1, "friend sees our table")
alice:Join(alice:Tables()[1].id, 1000)
runUntil(function() return alice.state == "seated" end, 10)
H.eq(hs.t.seats[alice.mySeat].name, "Alice", "friend seated at our table")
step(); step(); step()
H.ok(onScreen("At the table (3/6)", "Alice"), "our pre-game list shows the friend who joined")
H.ok(onScreen("Nyte", "host, you"), "and marks us as the host")
H.ok(onScreen("Deal the first hand when everyone"), "host is told to deal when ready")
H.eq(buttonMatching("^Get a loan$"), nil, "no loan button when hosting either")
H.eq(GG.db.stats.mp.hosted, 1, "hosted table counted")
H.eq(alice.t.seats[1].name, "Nyte", "friend sees us")

local hosted = 0
for _ = 1, 12 do
  if hs.t.seats[1].stack == 0 or alice.state ~= "seated" then break end
  local deal = buttonMatching("^Deal next hand$")
  H.ok(deal, "host can deal")
  deal:Fire("OnClick")
  runUntil(function() return not hs:HandRunning() and PUI.Between() and alice.t.street == "done" end, 300, function()
    if PUI.IsHumanTurn() then PUI.Act(randomAction(hs:Legal(), true)) end
    if alice.state == "seated" and alice:Legal() then alice:Act(randomAction(alice:Legal(), true)) end
  end)
  hosted = hosted + 1
  for i, p in ipairs(hs.t.seats) do
    if not p.gone then H.eq(alice.t.seats[i].stack, p.stack, "friend's view matches ours, seat " .. i) end
  end
  checkMoney("after hosted hand " .. hosted)
end
H.ok(hosted >= 3, "hosted several hands (" .. hosted .. ")")

-- Bots keep playing for everyone while our window is closed
if alice.state == "seated" and hs.t.seats[1].stack > 0 then
  buttonMatching("^Deal next hand$"):Fire("OnClick")
  GoblinGamblingFrame:Hide()
  runUntil(function() return not hs:HandRunning() end, 300, function()
    if alice:Legal() then alice:Act({ type = alice:Legal().check and "check" or "fold" }) end
  end)
  H.ok(true, "hand finished with our window closed (our turns timed out)")
  GG:ShowWindow()
  GG:SelectTab("poker")
  runUntil(function() return PUI.Between() end, 60)
  checkMoney("after a hand played with the window closed")
end

-- Throttle: never more than the burst plus one message per second
table.sort(sendTimes)
for i = 1, #sendTimes do
  local j, count = i, 0
  while j <= #sendTimes and sendTimes[j] - sendTimes[i] < 10 do count = count + 1; j = j + 1 end
  H.ok(count <= 8 + 10 + 1, "addon messages stay under the throttle")
end

-- Closing our table: friend is told, we get our stack
local myStack = hs.t.seats[1].stack
bal = GG:GetBalance()
H.eq(PUI.Leave(), true, "close our table")
H.eq(GG:GetBalance(), bal + myStack, "our stack returned")
runUntil(function() return alice.state == "gone" end, 20)
H.eq(alice.goneWhy, "closed", "friend told the table closed")
checkMoney("after closing our table")

-- Leaving the page switches multiplayer off again once we're not seated
H.ok(buttonMatching("^Back$"), "back on the Play with friends page after closing")
buttonMatching("^Back$"):Fire("OnClick")
H.eq(MP.enabled, false, "disabled again")

-- The With friends stats view
GG:SelectTab("stats")
M.findButton("With friends"):Fire("OnClick")
H.eq(GG.db.settings.statsView, "friends", "stats view switched")
H.ok(onScreen("Hold'em with friends"), "friends stats shown")
H.ok(onScreen(GG.FormatNumber(GG.db.stats.mp.hands)), "hands with friends shown")
M.findButton("All games"):Fire("OnClick")
H.ok(not onScreen("Hold'em with friends"), "back to all games")

M.realPrint(string.format("test_poker_mp_ui: %d checks passed (%d hands joined, %d hands hosted, %d addon messages sent)",
  H.passed, hands, hosted, #sendTimes))
