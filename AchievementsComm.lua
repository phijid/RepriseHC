-- AchievementsComm.lua — RepriseHC comms (Classic 1.15.7)
-- Uses AceComm-3.0 + AceSerializer-3.0 (embedded in RepriseHC/Libs)
-- Prefix: RepriseHC_ACH

local PREFIX = "RepriseHC_ACH"

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
local function SendWhisperFallback(payload, maxPeers)
  maxPeers = maxPeers or 3
  if not IsInGuild() then return false end
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() else GuildRoster() end
  local count = GetNumGuildMembers() or 0
  if count == 0 then return false end
  local me = UnitName("player")
  local sent = 0
  for i = 1, count do
    local idx = ((whisperIdx + i - 2) % count) + 1
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(idx)
    if online and name and name ~= me then
      sendRoute("WHISPER", payload, Ambiguate(name, "none"))
      sent = sent + 1
      if sent >= maxPeers then break end
    end
  end
  whisperIdx = whisperIdx + 1
  return sent > 0
end

-- -------- wire building (structured for all topics we send) --------
local function BuildWire(topic, payloadTable)
  return Encode(Envelope(topic, payloadTable or {}))
end

-- -------- snapshot build/merge --------
local function BuildSnapshot()
  local db = RepriseHC.DB()
  return {
    ver         = RepriseHC.version or "0",
    characters  = db.characters or {},
    guildFirsts = db.guildFirsts or {},
    deathLog    = db.deathLog or {},
    levelCap    = (db.config and db.config.levelCap) or RepriseHC.levelCap
  }
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
  if prefix ~= PREFIX then return end
  local t = TryDecodeAce(payload); if not t then t = TryDecodeLegacy(payload) end
  if not t or t.v ~= 1 then return end

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
    for _, d in ipairs(RepriseHC.GetDeathLog()) do if d.playerKey == p.playerKey then seen = true; break end end
    if not seen then
      table.insert(RepriseHC.GetDeathLog(), {
        playerKey=p.playerKey, name=p.name, level=p.level, class=p.class, race=p.race,
        zone=p.zone, subzone=p.subzone, when=time()
      })
      if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
    end

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
local function HasSnapshotFlag()
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

  -- Fan-out: always for DEATH; also before first snapshot.
  if topic == "DEATH" then
    local late = wire
    C_Timer.After(25, function()
      -- try guild/group again, then whisper a few peers
      local ok = SendViaGuild(late)
      if not ok then ok = SendViaGroup(late) end
      SendWhisperFallback(late, 4)
    end)
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
RepriseHC:UnregisterComm(PREFIX)
RepriseHC:RegisterComm(PREFIX, function(_, prefix, msg, dist, sender)
  HandleIncoming(prefix, msg, dist, sender)
end)