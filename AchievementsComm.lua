-- AchievementsComm.lua — Classic-safe transport for RepriseHC
-- Prefix: RepriseHC_ACH
-- Classic notes:
--  • CHANNEL routing for addon messages is not reliable in Classic → removed
--  • We multi-path critical topics: GUILD (if ready) → PARTY/RAID → WHISPER fanout
--  • Receiver handles both AceSerializer(+LibDeflate) and legacy "AWARD;..."/"DEAD;..." and "REQ"
--  • Late-join healing: REQSNAP retries (5s/15s/30s) + snapshot responses (structured or legacy stream)

local PREFIX = "RepriseHC_ACH"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- ===== libs =====
local AceSer  = LibStub and LibStub("AceSerializer-3.0", true)
local Deflate = LibStub and LibStub("LibDeflate", true)

-- ===== structured encode/decode =====
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

-- ===== legacy decode ("REQ", "AWARD;...", "DEAD;...") =====
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

-- ===== envelope, seq, dedupe =====
RepriseHC = RepriseHC or {}
local function SelfId()
  local name, realm = UnitName("player"); realm = realm or GetRealmName()
  return (realm and realm ~= "" and (name.."-"..realm)) or name or "player"
end
local function Envelope(topic, payload)
  RepriseHC._seq = (RepriseHC._seq or 0) + 1
  return { v=1, t=topic, ts=GetServerTime(), s=SelfId(), q=RepriseHC._seq, p=payload or {} }
end
local lastSeqBySender = {} -- [sender]=lastQ
local function IsDup(sender, q)
  if (q or 0) <= 0 then return false end
  local last = lastSeqBySender[sender]
  if not last or q > last then lastSeqBySender[sender] = q; return false end
  return true
end

-- ===== Classic-safe routing (no CHANNEL) =====
local function guildReady()
  return IsInGuild() and (GetGuildInfo("player") ~= nil)
end
local function SendGuild(payload)
  if guildReady() then
    C_ChatInfo.SendAddonMessage(PREFIX, payload, "GUILD")
    return true
  end
  return false
end
local function SendGroup(payload)
  if IsInRaid() then
    C_ChatInfo.SendAddonMessage(PREFIX, payload, "RAID")
    return true
  elseif IsInGroup() then
    C_ChatInfo.SendAddonMessage(PREFIX, payload, "PARTY")
    return true
  end
  return false
end
-- Whisper up to N online guild members (rotating) as temporary fallback
local whisperIdx = 1
local function SendWhisperFallback(payload, maxPeers)
  maxPeers = maxPeers or 4
  if not IsInGuild() then return false end
  GuildRoster() -- refresh-ish
  local count = GetNumGuildMembers() or 0
  if count == 0 then return false end
  local sent = 0
  for i = 1, count do
    local idx = ((whisperIdx + i - 2) % count) + 1
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(idx)
    if online and name and name ~= UnitName("player") then
      C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", name)
      sent = sent + 1
      if sent >= maxPeers then break end
    end
  end
  whisperIdx = whisperIdx + 1
  return sent > 0
end

-- ===== build wire payloads (structured first, legacy fallback) =====
local function BuildWire(topic, payloadTable)
  -- structured (Ace) first
  local packed = Encode(Envelope(topic, payloadTable or {}))
  if packed then return packed end

  -- legacy fallbacks for ACH/DEATH/REQSNAP only
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
      tostring(p.race or select(2,UnitRace("player")) or ""),
      tostring(p.zone or GetZoneText() or ""),
      tostring(p.subzone or GetSubZoneText() or ""),
      tostring(p.name or UnitName("player") or ""))
  elseif topic == "REQSNAP" then
    return "REQ"
  elseif topic == "SNAP" then
    -- needs structured; if we can't build it, skip (sender lacks Ace)
    return nil
  end
end

-- ===== public send (Classic multi-path) =====
function RepriseHC.Comm_Send(topic, payloadTable)
  local wire = BuildWire(topic, payloadTable)
  if not wire then return end

  -- Try GUILD; if not ready, try GROUP; else WHISPER fanout.
  local delivered = SendGuild(wire)
  if not delivered then delivered = SendGroup(wire) end
  if not delivered then
    -- Fresh invites / solo: WHISPER a few online guildies (dedupe on RX keeps it safe)
    SendWhisperFallback(wire, (topic == "SNAP") and 2 or 4)
  end
end

-- ===== snapshot build/merge/answer =====
local function BuildSnapshot()
  local db = RepriseHC.DB()
  return {
    ver = RepriseHC.version or "0",
    characters  = db.characters or {},
    guildFirsts = db.guildFirsts or {},
    deathLog    = db.deathLog or {}, -- single source of truth
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
    -- Legacy streaming (bounded) using our send paths so it reaches someone for sure
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

-- ===== startup & retries =====
local F = CreateFrame("Frame")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("CHAT_MSG_ADDON")
F:RegisterEvent("PLAYER_GUILD_UPDATE")
F:RegisterEvent("GUILD_ROSTER_UPDATE")

local function requestWithBackoff()
  if haveSnapshot then return end
  -- Ask for a snapshot via all working routes (Comm_Send handles fallback & fanout)
  RepriseHC.Comm_Send("REQSNAP", { need="all" })
  -- also allow plain legacy clients to respond
  if guildReady() then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "GUILD") end
  if IsInRaid() then
    C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "RAID")
  elseif IsInGroup() then
    C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "PARTY")
  end
end

F:SetScript("OnEvent", function(_, ev, ...)
  if ev == "PLAYER_ENTERING_WORLD" then
    haveSnapshot = false
    -- Retry heals: 5s, 15s, 30s
    C_Timer.After(5,  requestWithBackoff)
    C_Timer.After(15, requestWithBackoff)
    C_Timer.After(30, requestWithBackoff)
    -- Periodic self-SNAP (structured only; legacy streaming occurs on REQ)
    local function periodic()
      if AceSer then RepriseHC.Comm_Send("SNAP", { kind="SNAP", data = BuildSnapshot() }) end
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
