-- Goblin Gambling Co. : multiplayer wiring (WoW side of Games/PokerNet.lua).
-- Opt-in per session. Uses hidden addon messages (prefix GGCASINO) on the
-- group or guild channel, plus addon whispers for private bits. Nothing is
-- ever sent as a chat message. Outgoing messages go through a small token
-- bucket so we stay under WoW's addon-message throttle.
local ADDON, GG = ...

local Net = GG.PokerNet
local MP = { enabled = false }
GG.PokerMP = MP

local BURST, REFILL = 8, 1.0    -- up to 8 messages at once, then one per second

local tokens = BURST
local host, client              -- current PokerNet host / client objects
local draining = {}             -- objects that left but still have messages to send

local function Now() return GetTime() end

function MP.MyName()
  local name, realm = UnitFullName("player")
  if not realm or realm == "" then realm = GetNormalizedRealmName and GetNormalizedRealmName() or "" end
  return realm ~= "" and (name .. "-" .. realm) or name
end

-- "RAID" / "PARTY" when grouped, else nil.
function MP.GroupChannel()
  if IsInRaid and IsInRaid() then return "RAID" end
  if IsInGroup and IsInGroup() then return "PARTY" end
  return nil
end

function MP.GuildChannel()
  return (IsInGuild and IsInGuild()) and "GUILD" or nil
end

pcall(C_ChatInfo.RegisterAddonMessagePrefix, Net.PREFIX)

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------
local function Send(msg)
  pcall(C_ChatInfo.SendAddonMessage, Net.PREFIX, msg.text, msg.kind, msg.target)
end

local function NextFrom(obj)
  return obj and obj:NextMessage()
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, elapsed)
  tokens = math.min(BURST, tokens + elapsed / REFILL)
  if host then host:Pump() end
  if client then client:Pump() end
  while tokens >= 1 do
    local msg = NextFrom(host) or NextFrom(client)
    if not msg then
      local obj = draining[1]
      msg = obj and obj:NextMessage()
      if obj and not msg then table.remove(draining, 1) end
      if not obj then break end
    end
    if msg then
      Send(msg)
      tokens = tokens - 1
    end
  end
end)

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
  if prefix ~= Net.PREFIX or not MP.enabled then return end
  if sender == MP.MyName() then return end   -- our own broadcasts echo back
  if host then host:OnMessage(sender, text, channel) end
  if client then client:OnMessage(sender, text, channel) end
end)

------------------------------------------------------------------------
-- API for the poker UI
------------------------------------------------------------------------
MP.callbacks = {}   -- onSeated(seat, buyIn), onRejected(reason), onGone(stack, why), onRoster()

function MP.SetEnabled(on)
  MP.enabled = on and true or false
  if not MP.enabled then client = nil end
end

-- The browsing/seated client, created on first use.
function MP.Client()
  if not client then
    client = Net.NewClient({
      me = MP.MyName(), now = Now,
      onSeated = function(...) if MP.callbacks.onSeated then MP.callbacks.onSeated(...) end end,
      onRejected = function(...) if MP.callbacks.onRejected then MP.callbacks.onRejected(...) end end,
      onGone = function(...)
        local c = client
        client = nil
        if c then draining[#draining + 1] = c end
        if MP.callbacks.onGone then MP.callbacks.onGone(...) end
      end,
      onRoster = function() if MP.callbacks.onRoster then MP.callbacks.onRoster() end end,
    })
  end
  return client
end

function MP.Browse()
  if not MP.enabled then return end
  local c = MP.Client()
  local sent = false
  for _, ch in ipairs({ MP.GroupChannel(), MP.GuildChannel() }) do
    if ch then c:Query(ch); sent = true end
  end
  return sent
end

function MP.Tables()
  return client and client:Tables() or {}
end

function MP.Join(id, buyIn)
  if not MP.enabled or host then return false end
  return MP.Client():Join(id, buyIn)
end

-- Start hosting. Returns the host object (the table session) or nil.
function MP.Host(channel, stakeKey, buyIn, bots)
  if not MP.enabled or host or not channel then return nil end
  if client and client.state ~= "browsing" then return nil end
  host = Net.NewHost({
    me = MP.MyName(), channel = channel, stake = stakeKey, buyIn = buyIn, now = Now,
    bots = bots, pace = function() return GG.GetPace and GG:GetPace() or 1 end,
  })
  return host
end

-- Stop using a host/client after leaving; its last messages still go out.
function MP.Release(obj)
  if obj == host then host = nil end
  if obj == client then client = nil end
  if obj then draining[#draining + 1] = obj end
end

function MP.IsBusy()
  return host ~= nil or (client ~= nil and client.state ~= "browsing")
end
