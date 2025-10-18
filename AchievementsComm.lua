-- AchievementsComm.lua — resilient, order-independent sync for RepriseHC
-- Prefix: RepriseHC_ACH (only)
-- Features:
--  • Reliable send queue with retries (no early guild-gating)
--  • Prefer GUILD routing; fallback to permanent "RepriseHC" channel
--  • Dual-format RX: AceSerializer(+LibDeflate) and legacy "AWARD;..."/"DEAD;..." (and "REQ")
--  • Late-join healing: REQSNAP retries (5s/15s/30s) + periodic SNAP (every ~90s)
--  • Snapshot answer: structured if possible; else bounded legacy stream for interop

local PREFIX = "RepriseHC_ACH"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- ==== optional debug tap (set to true for logs while testing) ====
local DEBUG_WIRE = false
local function D(msg)
  if DEBUG_WIRE and RepriseHC and RepriseHC.Print then RepriseHC.Print(msg) end
end

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
    local playerKey, id, ptsStr, displayName =
      rest:match("^([^;]*);([^;]*);([^;]*);?(.*)$")
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

-- ===== reliable routing (queue + retries) =====
local function guildReady() return IsInGuild() and (GetGuildInfo("player") ~= nil) end
local function channelId()
  local id = GetChannelName("RepriseHC")
  return id and id > 0 and id or nil
end
local function ensureChannel(cb)
  local id = channelId()
  if id then cb(id); return end
  JoinPermanentChannel("RepriseHC")
  C_Timer.After(0.5, function() cb(channelId()) end)
end

-- wire send attempt (one shot)
local function trySend(wire)
  local sent = false
  if guildReady() then
    sent = C_ChatInfo.SendAddonMessage(PREFIX, wire, "GUILD") and true or false
    if sent then D("TX GUILD ok ("..#tostring(wire)..")") else D("|cffff6060TX GUILD fail|r") end
  end
  if not sent then
    ensureChannel(function(id)
      if id then
        C_ChatInfo.SendAddonMessage(PREFIX, wire, "CHANNEL", id)
        D("TX CHANNEL "..tostring(id).." ("..#tostring(wire)..")")
      else
        D("|cffff6060CHANNEL not ready|r")
      end
    end)
  end
  return sent
end

-- queue & flush
local Q = {}         -- array of {wire, tries}
local flushing = false
local function flush()
  if flushing then return end
  flushing = true
  local i = 1
  while i <= #Q do
    local item = Q[i]
    local ok = trySend(item.wire)
    if ok then
      table.remove(Q, i)
    else
      item.tries = (item.tries or 0) + 1
      if item.tries > 10 then
        if RepriseHC.Print then RepriseHC.Print("|cffff6060Drop message after 10 tries|r") end
        table.remove(Q, i)
      else
        i = i + 1
      end
    end
  end
  flushing = false
end

-- re-flush on events that often unstick routing
local flushFrame = CreateFrame("Frame")
flushFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
flushFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
flushFrame:RegisterEvent("CHANNEL_UI_UPDATE")
flushFrame:SetScript("OnEvent", function() C_Timer.After(0.2, flush) end)

-- ===== build wire payloads (structured first, legacy fallback) =====
local function BuildWire(topic, payloadTable)
  -- structured (Ace) first
  local packed = Encode(Envelope(topic, payloadTable or {}))
  if packed then return packed end

  -- legacy fallbacks for ACH/DEATH/REQSNAP only
  if topic == "ACH" then
    local p = payloadTable or {}
    return string.format("AWARD;%s;%s;%d;%s",
      tostring(p.playerKey or UnitName("player")), tostring(p.id or ""),
      tonumber(p.pts or 0), tostring(p.name or ""))
  elseif topic == "DEATH" then
    local p = payloadTable or {}
    return string.format("DEAD;%s;%d;%s;%s;%s;%s;%s",
      tostring(p.playerKey or UnitName("player")), tonumber(p.level or UnitLevel("player") or 0),
      tostring(p.class or select(2,UnitClass("player")) or ""), tostring(p.race or select(2,UnitRace("player")) or ""),
      tostring(p.zone or GetZoneText() or ""), tostring(p.subzone or GetSubZoneText() or ""), tostring(p.name or UnitName("player") or ""))
  elseif topic == "REQSNAP" then
    return "REQ"
  elseif topic == "SNAP" then
    -- needs structured; if we can't build it, skip (sender lacks Ace)
    return nil
  end
end

-- ===== public send (enqueue) =====
function RepriseHC.Comm_Send(topic, payloadTable)
  local wire = BuildWire(topic, payloadTable)
  if not wire then return end
  table.insert(Q, { wire = wire, tries = 0 })
  flush()
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
    -- Legacy streaming (bounded) so clients without Ace still heal
    local sent = 0
    for id, char in pairs(snap.characters or {}) do
      for achId, a in pairs(char.achievements or {}) do
        C_ChatInfo.SendAddonMessage(PREFIX, string.format("AWARD;%s;%s;%d;%s",
          id, achId, tonumber(a.points or 0), tostring(a.name or achId)), "GUILD")
        sent = sent + 1; if sent > 400 then break end
      end
      if sent > 400 then break end
    end
    for _, d in ipairs(snap.deathLog or {}) do
      C_ChatInfo.SendAddonMessage(PREFIX, string.format("DEAD;%s;%d;%s;%s;%s;%s;%s",
        d.playerKey or "?", tonumber(d.level or 0), tostring(d.class or ""), tostring(d.race or ""),
        tostring(d.zone or ""), tostring(d.subzone or ""), tostring(d.name or d.playerKey or "?")), "GUILD")
      sent = sent + 1; if sent > 600 then break end
    end
  end
end

-- ===== receiver =====
local haveSnapshot = false

local function HandleIncoming(prefix, payload, channel, sender)
  if prefix ~= PREFIX then return end

  if DEBUG_WIRE then
    RepriseHC.Print(("RX [%s] from %s (%d bytes)"):format(channel or "?", sender or "?", #tostring(payload or "")))
  end

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
  RepriseHC.Comm_Send("REQSNAP", { need="all" })   -- structured request
  -- also plain legacy request so clients without AceSer answer too
  if guildReady() then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "GUILD") end
  local id = channelId()
  if id then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "CHANNEL", id) end
end

F:SetScript("OnEvent", function(_, ev, ...)
  if ev == "PLAYER_ENTERING_WORLD" then
    haveSnapshot = false
    -- Retry heals: 5s, 15s, 30s
    C_Timer.After(5,  requestWithBackoff)
    C_Timer.After(15, requestWithBackoff)
    C_Timer.After(30, requestWithBackoff)
    -- Periodic self-SNAP helps heal anyone who arrives later
    local function periodic()
      RepriseHC.Comm_Send("SNAP", { kind="SNAP", data = BuildSnapshot() })
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

-- ===== optional: Blizzard send result tap =====
if DEBUG_WIRE then
  local tap = CreateFrame("Frame")
  tap:RegisterEvent("SEND_ADDON_MESSAGE_RESULT")
  tap:SetScript("OnEvent", function(_, _, prefix, target, ok)
    if prefix == PREFIX and not ok and RepriseHC.Print then
      RepriseHC.Print(("|cffff6060SEND FAIL|r to %s"):format(tostring(target)))
    end
  end)
end
