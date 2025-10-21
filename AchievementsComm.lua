-- AchievementsComm.lua — Classic-safe, CTL-powered comms for RepriseHC
-- Prefix: RepriseHC_ACH
-- Transport strategy (Classic-safe):
--   1) Prefer GUILD (only when GetGuildInfo("player") is non-nil and we've waited a few seconds)
--   2) Else GROUP (RAID/PARTY)
--   3) Always WHISPER fan-out for DEATH (dedupe on RX prevents dupes)
-- Uses ChatThrottleLib if available for reliable bandwidth/throttle handling.

local PREFIX = "RepriseHC_ACH"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- ===== libs (optional) =====
local CTL      = _G.ChatThrottleLib                 -- preferred if present
local AceSer   = LibStub and LibStub("AceSerializer-3.0", true)
local Deflate  = LibStub and LibStub("LibDeflate", true)

-- ===== Reprise namespace & helpers =====
RepriseHC = RepriseHC or {}

local function SelfId()
  local name, realm = UnitName("player"); realm = realm or GetRealmName()
  return (realm and realm ~= "" and (name.."-"..realm)) or name or "player"
end

-- Envelope + sequence (for RX dup suppression)
local function Envelope(topic, payload)
  RepriseHC._seq = (RepriseHC._seq or 0) + 1
  return { v=1, t=topic, ts=GetServerTime(), s=SelfId(), q=RepriseHC._seq, p=payload or {} }
end

-- ===== encode/decode =====
local function Encode(tbl)
  if not AceSer then return nil end
  local s = AceSer:Serialize(tbl)
  if Deflate then
    local c = Deflate:CompressDeflate(s)
    return Deflate:EncodeForWoWAddonChannel(c)
  end
  return s
end

local function TryDecodeAce(payload)
  if not AceSer then return end
  if Deflate then
    local c = Deflate:DecodeForWoWAddonChannel(payload); if not c then return end
    local s = Deflate:DecompressDeflate(c);              if not s then return end
    local ok, t = AceSer:Deserialize(s); if ok then return t end
  else
    local ok, t = AceSer:Deserialize(payload); if ok then return t end
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

-- ===== guild readiness grace =====
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

-- ===== routing (one unified stack) =====
local function sendRoute(route, payload, target)
  if CTL then
    if target then CTL:SendAddonMessage("NORMAL", PREFIX, payload, route, target)
    else CTL:SendAddonMessage("NORMAL", PREFIX, payload, route) end
  else
    if target then C_ChatInfo.SendAddonMessage(PREFIX, payload, route, target)
    else C_ChatInfo.SendAddonMessage(PREFIX, payload, route) end
  end
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

-- Whisper up to N online guild members (rotating) as a reliability fan-out
local whisperIdx = 1
local function SendWhisperFallback(payload, maxPeers)
  maxPeers = maxPeers or 3
  if not IsInGuild() then return false end
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
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

-- ===== wire building (single authoritative version) =====
local function BuildWire(topic, payloadTable)
  -- structured path first
  local packed = Encode(Envelope(topic, payloadTable or {}))
  if packed then return packed end

  -- legacy fallbacks (keep compatibility with manual /run tests)
  if topic == "ACH" then
    local p = payloadTable or {}
    return string.format("AWARD;%s;%s;%d;%s",
      tostring(p.playerKey or UnitName("player")),
      tostring(p.id or ""), tonumber(p.pts or 0), tostring(p.name or ""))
  elseif topic == "DEATH" then
    local p = payloadTable or {}
    return string.format("DEAD;%s;%d;%s;%s;%s;%s;%s",
      tostring(p.playerKey or UnitName("player")),
      tonumber(p.level or UnitLevel("player") or 0),
      tostring(p.class or select(2,UnitClass("player")) or ""),
      tostring(p.race  or select(2,UnitRace("player")) or ""),
      tostring(p.zone  or GetZoneText()     or ""),
      tostring(p.subzone or GetSubZoneText() or ""),
      tostring(p.name  or UnitName("player") or ""))
  elseif topic == "REQSNAP" then
    return "REQ"
  elseif topic == "SNAP" then
    return nil -- SNAP is structured-only
  end
end

-- ===== snapshot build/merge/answer =====
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

local function AnswerSnapshot()
  local snap = BuildSnapshot()
  if AceSer then
    RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=snap })
  else
    -- legacy streaming (bounded)
    local sent = 0
    for id, char in pairs(snap.characters or {}) do
      for achId, a in pairs(char.achievements or {}) do
        RepriseHC.Comm_Send("ACH", { playerKey=id, id=achId, pts=tonumber(a.points or 0), name=tostring(a.name or achId) })
        sent = sent + 1; if sent > 400 then break end
      end
      if sent > 400 then break end
    end
    for _, d in ipairs(snap.deathLog or {}) do
      RepriseHC.Comm_Send("DEATH", {
        playerKey=d.playerKey or "?", level=tonumber(d.level or 0),
        class=tostring(d.class or ""), race=tostring(d.race or ""),
        zone=tostring(d.zone or ""), subzone=tostring(d.subzone or ""),
        name=tostring(d.name or d.playerKey or "?"),
      })
      sent = sent + 1; if sent > 600 then break end
    end
  end
end

-- ===== dedupe by sender sequence =====
local lastSeqBySender = {} -- [sender]=lastQ
local function IsDup(sender, q)
  if (q or 0) <= 0 then return false end
  local last = lastSeqBySender[sender]
  if not last or q > last then lastSeqBySender[sender] = q; return false end
  return true
end

-- ===== receiver =====
local haveSnapshot = false
local function HandleIncoming(prefix, payload, channel, sender)
  if prefix ~= PREFIX then return end
  local t = TryDecodeAce(payload); if not t then t = TryDecodeLegacy(payload) end
  if not t or t.v ~= 1 then return end

  local sid, q = t.s or sender or "?", t.q or 0
  if IsDup(sid, q) then return end

  local p, topic = t.p or {}, t.t
  if topic == "ACH" then
    local db = RepriseHC.DB()
    db.characters[p.playerKey] = db.characters[p.playerKey] or { points=0, achievements={} }
    local c = db.characters[p.playerKey]
    if not c.achievements[p.id] then
      c.achievements[p.id] = { name=p.name, points=p.pts or 0, when=time() }
      c.points = (c.points or 0) + (p.pts or 0)
    end
    if p.id and p.id:find("^FIRST_" .. RepriseHC.levelCap) then
      db.guildFirsts[p.id] = db.guildFirsts[p.id] or { winner=p.playerKey, when=time() }
    end
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end

  elseif topic == "DEATH" then
    local seen = false
    for _,d in ipairs(RepriseHC.GetDeathLog()) do if d.playerKey == p.playerKey then seen = true break end end
    if not seen then
      table.insert(RepriseHC.GetDeathLog(), {
        playerKey=p.playerKey, name=p.name, level=p.level, class=p.class, race=p.race,
        zone=p.zone, subzone=p.subzone, when=time()
      })
      if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
    end

  elseif topic == "REQSNAP" then
    AnswerSnapshot()

  elseif topic == "SNAP" and p and p.data then
    MergeSnapshot(p.data)
    haveSnapshot = true
    if RepriseHC.Print then RepriseHC.Print("Synchronized snapshot.") end
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
  end
end

function RepriseHC.Comm_OnAddonMessage(prefix, payload, channel, sender)
  HandleIncoming(prefix, payload, channel, sender)
end

-- Helper to expose snapshot state elsewhere if you want
function RepriseHC.Comm_HasSnapshot() return haveSnapshot end

-- ===== public send (multi-path with DEATH fan-out) =====
local function HasSnapshotFlag()
  -- allow an external flag if you set one, otherwise use our local latch
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

  -- For DEATH, ALWAYS fan out via a few whispers, regardless of usedGuild/usedGroup.
  -- Before first snapshot, also be redundant.
  if topic == "DEATH" or not HasSnapshotFlag() then
    SendWhisperFallback(wire, (topic == "SNAP" and 2) or 4)
  elseif (not usedGuild and not usedGroup) then
    SendWhisperFallback(wire, 3)
  end
end

-- ===== startup & retries =====
local F = CreateFrame("Frame")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("CHAT_MSG_ADDON")
F:RegisterEvent("PLAYER_GUILD_UPDATE")
F:RegisterEvent("GUILD_ROSTER_UPDATE")

local function requestWithBackoff()
  if haveSnapshot then return end
  -- Ask via multi-path (Comm_Send does routing); also send plain legacy on ready routes
  RepriseHC.Comm_Send("REQSNAP", { need="all" })
  if GuildRouteReady() then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "GUILD") end
  if IsInRaid() then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "RAID")
  elseif IsInGroup() then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "PARTY") end
end

F:SetScript("OnEvent", function(_, ev, ...)
  if ev == "PLAYER_ENTERING_WORLD" then
    haveSnapshot = false
    C_Timer.After(5,  requestWithBackoff)
    C_Timer.After(15, requestWithBackoff)
    C_Timer.After(30, requestWithBackoff)

    -- periodic structured SNAP (keeps peers updated)
    local function periodic()
      if AceSer then RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() }) end
      C_Timer.After(90, periodic)
    end
    C_Timer.After(20, periodic)

  elseif ev == "PLAYER_GUILD_UPDATE" or ev == "GUILD_ROSTER_UPDATE" then
    if not haveSnapshot then C_Timer.After(2, requestWithBackoff) end

  elseif ev == "CHAT_MSG_ADDON" then
    local prefix, payload, channel, sender = ...
    HandleIncoming(prefix, payload, channel, sender)
  end
end)
