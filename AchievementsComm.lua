-- AchievementsComm.lua — RepriseHC comms (Classic 1.15.7)
-- Uses AceComm-3.0 + AceSerializer-3.0 (embedded in RepriseHC/Libs)
-- Prefix: RepriseHC_ACH

local PREFIX = "RepriseHC_ACH"
local RHC_DEBUG = true  -- set true to print who we whisper

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
  C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end

-- Ace libs (required)
local AceComm = assert(LibStub("AceComm-3.0"))
local AceSer  = assert(LibStub("AceSerializer-3.0"))

-- Namespace
RepriseHC = RepriseHC or {}
AceComm:Embed(RepriseHC)

-- -------- identity / envelope / seq --------
local function SelfId()
  local name, realm = UnitName("player"); realm = realm or GetRealmName()
  return (realm and realm ~= "" and (name.."-"..realm)) or name or "player"
end

local function Envelope(topic, payload)
  RepriseHC._seq = (RepriseHC._seq or 0) + 1
  return { v=1, t=topic, ts=GetServerTime(), s=SelfId(), q=RepriseHC._seq, p=payload or {} }
end

-- -------- encode/decode (structured primary, legacy RX fallback) --------
local function Encode(tbl)
  -- AceSerializer strings are safe for addon channels and AceComm handles splitting.
  local s = AceSer:Serialize(tbl)
  return s
end

local function TryDecodeAce(payload)
  local ok, t = AceSer:Deserialize(payload)
  if ok and type(t) == "table" then return t end
  if RHC_DEBUG then
    print("|cffff6666[RHC]|r AceSer deserialize failed; raw=", tostring(payload):sub(1, 40), "...")
  end
end


local function TryDecodeLegacy(payload)
  if type(payload) ~= "string" then return end
  if payload == "REQ" then
    return { v=1, t="REQSNAP", q=0, s="LEGACY", p={ need="all" } }
  end
  local tag, rest = payload:match("^([^;]+);(.*)$")
  if not tag then return end
  if tag == "AWARD" then
    local playerKey, id, ptsStr, displayName = rest:match("^([^;]*);([^;]*);([^;]*);?(.*)$")
    if not playerKey or not id then return end
    return { v=1, t="ACH", q=0, s="LEGACY",
      p={ playerKey=playerKey, id=id, pts=tonumber(ptsStr or "0") or 0, name=displayName } }
  elseif tag == "DEAD" then
    local playerKey, levelStr, class, race, zone, subzone, name =
      rest:match("^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);?(.*)$")
    if not playerKey then return end
    return { v=1, t="DEATH", q=0, s="LEGACY",
      p={ playerKey=playerKey, level=tonumber(levelStr or "0") or 0, class=class, race=race, zone=zone, subzone=subzone, name=name } }
  end
end

-- -------- guild readiness grace --------
local lastGuildTouch = 0
local function MarkGuildTouched() lastGuildTouch = GetTime() end
local function GuildRouteReady()
  if not IsInGuild() then return false end
  if not GetGuildInfo("player") then return false end
  return (GetTime() - (lastGuildTouch or 0)) > 3
end
do
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("PLAYER_GUILD_UPDATE")
  f:RegisterEvent("GUILD_ROSTER_UPDATE")
  f:SetScript("OnEvent", function(_, ev)
    if ev == "PLAYER_ENTERING_WORLD" or ev == "PLAYER_GUILD_UPDATE" or ev == "GUILD_ROSTER_UPDATE" then
      MarkGuildTouched()
    end
  end)
end

-- -------- send helpers (AceComm handles throttle/fragmentation) --------
local function sendRoute(route, payload, target)
  AceComm:SendCommMessage(PREFIX, payload, route, target)  -- NORMAL priority
end

local function SendViaGuild(payload)
  if GuildRouteReady() then sendRoute("GUILD", payload); return true end
  return false
end

local function SendViaGroup(payload)
  if IsInRaid()  then sendRoute("RAID",  payload); return true end
  if IsInGroup() then sendRoute("PARTY", payload); return true end
  return false
end

-- Whisper N online guildies (rotating) as reliability fan-out (dedupe on RX)
local whisperIdx = 1

local function IsSelf(fullname)
  if not fullname or fullname == "" then return false end
  local short = Ambiguate(fullname, "short")
  return UnitIsUnit("player", short) or UnitIsUnit("player", fullname)
end



local function debugPrint(...)
  if RHC_DEBUG and print then print("|cff99ccff[RHC]|r", ...) end
end

local function SendWhisperFallback(payload, maxPeers)
  maxPeers = maxPeers or 12
  if not IsInGuild() then return false end

  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  else
    GuildRoster()
  end

  local count = GetNumGuildMembers() or 0
  if count == 0 then return false end

  -- === Special case: exactly 2 online (me + one other) -> target them explicitly ===
  local onlineNames = {}
  for i = 1, count do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name then table.insert(onlineNames, name) end
  end

  if #onlineNames == 2 then
    local other = IsSelf(onlineNames[1]) and onlineNames[2] or onlineNames[1]
    if other and not IsSelf(other) then
      local full  = Ambiguate(other, "none")  -- "Name-Realm"
      local short = Ambiguate(other, "short") -- "Name"
      -- Send both forms (AceComm/SendAddonMessage handles dedupe on RX by content)
      AceComm:SendCommMessage(PREFIX, payload, "WHISPER", full)
      AceComm:SendCommMessage(PREFIX, payload, "WHISPER", short)
      debugPrint("DEATH direct-whisper 2-online ->", full, "/", short)
      return true
    end
  end

  -- === General case: rotate through roster, prefer GM, exclude self ===
  local sent, seen = 0, {}

  local function trySendIndex(i)
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name and not IsSelf(name) and not seen[name] then
      local target = Ambiguate(name, "none")
      AceComm:SendCommMessage(PREFIX, payload, "WHISPER", target)
      debugPrint("fanout ->", target)
      seen[name] = true
      sent = sent + 1
      return true
    end
    return false
  end

  -- Prefer GM
  for i = 1, count do
    local _, _, rankIndex = GetGuildRosterInfo(i)
    if rankIndex == 0 then trySendIndex(i); break end
  end
  if sent >= maxPeers then whisperIdx = whisperIdx + 1; return true end

  -- Rotate
  for i = 1, count do
    local idx = ((whisperIdx + i - 2) % count) + 1
    trySendIndex(idx)
    if sent >= maxPeers then break end
  end

  whisperIdx = whisperIdx + 1
  return sent > 0
end

-- -------- wire building (structured for all topics we send) --------
local function BuildWire(topic, payloadTable)
  return Encode(Envelope(topic, payloadTable or {}))
end

-- -------- snapshot build/merge --------
function BuildSnapshot()
  local db = RepriseHC.DB()
  return {
    ver         = RepriseHC.version or "0",
    characters  = db.characters or {},
    guildFirsts = db.guildFirsts or {},
    deathLog    = db.deathLog or {},
    levelCap    = (db.config and db.config.levelCap) or RepriseHC.levelCap
  }
end

local function SendSmallSnapshot()
  RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() })
end

local function SendDirectToOtherOnline(payload)
  if not IsInGuild() then return false end
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() else GuildRoster() end
  local n, me = GetNumGuildMembers() or 0, UnitName("player")
  local others = {}
  for i=1,n do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name then
      local short = Ambiguate(name, "short")
      if not UnitIsUnit(short, "player") and not UnitIsUnit(name, "player") then
        table.insert(others, name)
      end
    end
  end
  if #others ~= 1 then return false end
  local other = others[1]
  local full  = Ambiguate(other, "none")   -- Name-Realm
  local short = Ambiguate(other, "short")  -- Name
  -- AceComm
  AceComm:SendCommMessage(PREFIX, payload, "WHISPER", full)
  AceComm:SendCommMessage(PREFIX, payload, "WHISPER", short)
  -- Raw API too (belt + suspenders)
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", full)
    C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", short)
  end
  if RHC_DEBUG then print("|cff99ccff[RHC]|r DEATH direct->", full, "/", short) end
  return true
end

local function MergeSnapshot(p)
  if type(p) ~= "table" then return end
  local db = RepriseHC.DB()
  db.characters  = db.characters  or {}
  db.guildFirsts = db.guildFirsts or {}
  db.deathLog    = db.deathLog    or {}

  for k,v in pairs(p.characters or {}) do
    local lc = db.characters[k]
    if not lc or (v.points or 0) > (lc.points or 0) then db.characters[k] = v end
  end
  for id,entry in pairs(p.guildFirsts or {}) do
    if not db.guildFirsts[id] then db.guildFirsts[id] = entry end
  end
  local seen = {}
  for _,d in ipairs(db.deathLog) do if d.playerKey then seen[d.playerKey]=true end end
  for _,d in ipairs(p.deathLog or {}) do
    if d.playerKey and not seen[d.playerKey] then
      table.insert(db.deathLog, d); seen[d.playerKey]=true
    end
  end
end

-- -------- RX dedupe by sender sequence --------
local lastSeqBySender = {} -- [sender]=lastQ
local function IsDup(sender, q)
  if (q or 0) <= 0 then return false end
  local last = lastSeqBySender[sender]
  if not last or q > last then lastSeqBySender[sender] = q; return false end
  return true
end

-- -------- receiver --------
local haveSnapshot = false

local function normalizeKeyAndName(p, sender)
  if not p.playerKey or p.playerKey == "" then
    local _, myRealm = UnitName("player"); myRealm = myRealm or GetRealmName()
    local inferred = sender
    if not (inferred and inferred:find("-")) then
      if p.name and p.name ~= "" and myRealm and myRealm ~= "" then
        inferred = p.name .. "-" .. myRealm
      else
        inferred = p.name or sender or "?"
      end
    end
    p.playerKey = inferred
  end
  if (not p.name or p.name == "") and p.playerKey and p.playerKey ~= "" then
    p.name = p.playerKey:match("^([^%-]+)") or p.playerKey
  end
end

local function HandleIncoming(prefix, payload, channel, sender)

  if RHC_DEBUG then
    print("|cff99ccff[RHC RX]|r", "prefix=", prefix, "dist=", channel, "from=", sender, "len=", #tostring(payload or ""))
  end

  if prefix ~= PREFIX then return end
  local t = TryDecodeAce(payload); if not t then t = TryDecodeLegacy(payload) end
  if not t then
    if RHC_DEBUG then
      print("|cffff6666[RHC]|r decode failed; dropping. prefix=", prefix, "from=", sender)
    end
    return
  end
  if t.v ~= 1 then
    if RHC_DEBUG then print("|cffff6666[RHC]|r bad version", tostring(t.v)) end
    return
  end

  local sid, q = t.s or sender or "?", t.q or 0
  if IsDup(sid, q) then return end

  local p, topic = t.p or {}, t.t

  if topic == "ACH" then
    normalizeKeyAndName(p, sender)

    local db = RepriseHC.DB()
    db.characters[p.playerKey] = db.characters[p.playerKey] or { points=0, achievements={} }
    local c = db.characters[p.playerKey]
    if not c.achievements[p.id] then
      c.achievements[p.id] = { name=p.name or p.id, points=p.pts or 0, when=time() }
      c.points = (c.points or 0) + (p.pts or 0)
    end
    if p.id and p.id:find("^FIRST_" .. RepriseHC.levelCap) then
      db.guildFirsts[p.id] = db.guildFirsts[p.id] or { winner=p.playerKey, when=time() }
    end
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end

  elseif topic == "DEATH" then
    normalizeKeyAndName(p, sender)

    local seen = false
    for _, d in ipairs(RepriseHC.GetDeathLog()) do
      if d.playerKey == p.playerKey then seen = true; break end
    end
    if seen then
      if RHC_DEBUG then print("|cff99ccff[RHC]|r DEATH already logged for", p.playerKey, "— skipping") end
      return
    end

    table.insert(RepriseHC.GetDeathLog(), {
      playerKey=p.playerKey, name=p.name, level=p.level, class=p.class, race=p.race,
      zone=p.zone, subzone=p.subzone, when=time()
    })
    if RHC_DEBUG then print("|cff99ccff[RHC]|r DEATH inserted for", p.playerKey) end
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end

    elseif topic == "REQSNAP" then
      RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() })

    elseif topic == "SNAP" and p and p.data then
      MergeSnapshot(p.data)
      haveSnapshot = true
      if RepriseHC.Print then RepriseHC.Print("Synchronized snapshot.") end
      if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
    end
  end

-- Expose for any external calls (and unit tests)
RepriseHC.Comm_OnAddonMessage = HandleIncoming

-- -------- public send (multi-path with DEATH fan-out) --------
function HasSnapshotFlag()
  if RepriseHC and RepriseHC.Comm_HaveSnapshot then return true end
  return haveSnapshot
end

function RepriseHC.Comm_Send(topic, payloadTable)
  local wire = BuildWire(topic, payloadTable)
  if not wire or wire == "" then return end

  local usedGuild = SendViaGuild(wire)
  local usedGroup = false
  if not usedGuild then
    usedGroup = SendViaGroup(wire)
  end

  -- if topic == "DEATH" then
  --   -- immediate direct whisper(s)
  --   SendWhisperFallback(wire, 12)

  --   -- late safety resend (kept)
  --   local late = wire
  --   C_Timer.After(25, function()
  --     local ok = SendViaGuild(late)
  --     if not ok then ok = SendViaGroup(late) end
  --     SendWhisperFallback(late, 12)
  --   end)
  -- end
  if topic == "DEATH" then
    -- Try the direct 1:1 path first (when only 2 online)
    local didDirect = SendDirectToOtherOnline(wire)

    -- Also do the regular fan-out (covers >2 online)
    SendWhisperFallback(wire, 12)

    -- Late resend for good measure
    local late = wire
    C_Timer.After(25, function()
      local ok = SendViaGuild(late)
      if not ok then ok = SendViaGroup(late) end
      SendWhisperFallback(late, 12)
    end)

    -- Short-delay snapshots heal any missed packets once the channel settles
    C_Timer.After(5,  SendSmallSnapshot)
    C_Timer.After(20, SendSmallSnapshot)
  end
end


-- -------- startup & retries --------
local F = CreateFrame("Frame")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("PLAYER_GUILD_UPDATE")
F:RegisterEvent("GUILD_ROSTER_UPDATE")

local function requestWithBackoff()
  if haveSnapshot then return end
  RepriseHC.Comm_Send("REQSNAP", { need="all" })
end

F:SetScript("OnEvent", function(_, ev)
  if ev == "PLAYER_ENTERING_WORLD" then
    haveSnapshot = false
    C_Timer.After(5,  requestWithBackoff)
    C_Timer.After(15, requestWithBackoff)
    C_Timer.After(30, requestWithBackoff)

    local function periodic()
      RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() })
      C_Timer.After(90, periodic)
    end
    C_Timer.After(20, periodic)

  elseif ev == "PLAYER_GUILD_UPDATE" or ev == "GUILD_ROSTER_UPDATE" then
    if not haveSnapshot then C_Timer.After(2, requestWithBackoff) end
  end
end)

-- -------- AceComm receiver registration --------
RepriseHC:UnregisterComm(PREFIX)  -- safe if not registered yet
RepriseHC:RegisterComm(PREFIX, function(prefix, msg, dist, sender)
  HandleIncoming(prefix, msg, dist, sender)
end)