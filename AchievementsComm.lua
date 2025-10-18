-- AchievementsComm.lua — resilient, order-independent sync
local PREFIX = "RepriseHC_ACH"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- ===== Libs =====
local AceSer  = LibStub and LibStub("AceSerializer-3.0", true)
local Deflate = LibStub and LibStub("LibDeflate", true)

-- ===== Encode / Decode =====
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

-- Legacy parser: "AWARD;..." and "DEAD;..."
local function TryDecodeLegacy(payload)
  if type(payload) ~= "string" then return end
  if payload == "REQ" then return { v=1, t="REQSNAP", q=0, s="LEGACY", p={ need="all" } } end
  local tag, rest = payload:match("^([^;]+);(.*)$")
  if not tag then return end
  if tag == "AWARD" then
    local playerKey, id, ptsStr, displayName = rest:match("^([^;]*);([^;]*);([^;]*);?(.*)$")
    if not playerKey or not id then return end
    return { v=1, t="ACH", q=0, s="LEGACY",
             p={ playerKey=playerKey, id=id, pts=tonumber(ptsStr or "0") or 0, name=displayName } }
  elseif tag == "DEAD" then
    local playerKey, levelStr, class, race, zone, subzone, name = rest:match("^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);?(.*)$")
    if not playerKey then return end
    return { v=1, t="DEATH", q=0, s="LEGACY",
             p={ playerKey=playerKey, level=tonumber(levelStr or "0") or 0, class=class, race=race, zone=zone, subzone=subzone, name=name } }
  end
end

-- ===== Envelope, seq, dedupe =====
local seq = 0
local function NextSeq() seq = (seq + 1) % 1000000; return seq end
local lastSeqBySender = {} -- [sender]=lastQ
local function IsDup(sender, q)
  if (q or 0) <= 0 then return false end
  local last = lastSeqBySender[sender]
  if not last or q > last then lastSeqBySender[sender] = q; return false end
  return true
end

local function Envelope(topic, payload)
  local name, realm = UnitName("player"); realm = realm or GetRealmName()
  local selfId = (realm and realm ~= "" and (name.."-"..realm)) or name or "player"
  return { v=1, t=topic, ts=GetServerTime(), s=selfId, q=NextSeq(), p=payload or {} }
end

-- ===== Routing (prefer GUILD; fallback to permanent channel) =====
local function SendWire(payload)
  local ok = false
  if IsInGuild() and GetGuildInfo("player") then
    ok = C_ChatInfo.SendAddonMessage(PREFIX, payload, "GUILD") and true or false
  end
  if not ok then
    local id = GetChannelName("RepriseHC")
    if id == 0 then JoinPermanentChannel("RepriseHC"); id = GetChannelName("RepriseHC") end
    if id and id > 0 then C_ChatInfo.SendAddonMessage(PREFIX, payload, "CHANNEL", id) end
  end
end

-- ===== Public send (no early guild-gate!) =====
function RepriseHC.Comm_Send(topic, payloadTable)
  -- Try structured first
  local packed = Encode(Envelope(topic, payloadTable or {}))
  if packed then SendWire(packed); return end

  -- Fallback legacy lines for ACH/DEATH and REQSNAP
  if topic == "ACH" then
    local p = payloadTable or {}
    SendWire(string.format("AWARD;%s;%s;%d;%s",
      tostring(p.playerKey or UnitName("player")), tostring(p.id or ""),
      tonumber(p.pts or 0), tostring(p.name or "")))
  elseif topic == "DEATH" then
    local p = payloadTable or {}
    SendWire(string.format("DEAD;%s;%d;%s;%s;%s;%s;%s",
      tostring(p.playerKey or UnitName("player")), tonumber(p.level or UnitLevel("player") or 0),
      tostring(p.class or select(2,UnitClass("player")) or ""), tostring(p.race or select(2,UnitRace("player")) or ""),
      tostring(p.zone or GetZoneText() or ""), tostring(p.subzone or GetSubZoneText() or ""), tostring(p.name or UnitName("player") or "")))
  elseif topic == "REQSNAP" then
    SendWire("REQ")
  end
end

-- ===== Snapshot build/merge =====
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
    if d.playerKey and not seen[d.playerKey] then table.insert(db.deathLog, d); seen[d.playerKey]=true end
  end
end

local function AnswerSnapshot()
  local snap = BuildSnapshot()
  if AceSer then
    RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=snap })
  else
    -- Legacy stream (bounded) so clients without Ace still heal
    local sent = 0
    for id, char in pairs(snap.characters or {}) do
      for achId, a in pairs(char.achievements or {}) do
        SendWire(string.format("AWARD;%s;%s;%d;%s", id, achId, tonumber(a.points or 0), tostring(a.name or achId)))
        sent = sent + 1; if sent > 400 then break end
      end
      if sent > 400 then break end
    end
    for _, d in ipairs(snap.deathLog or {}) do
      SendWire(string.format("DEAD;%s;%d;%s;%s;%s;%s;%s",
        d.playerKey or "?", tonumber(d.level or 0), tostring(d.class or ""), tostring(d.race or ""),
        tostring(d.zone or ""), tostring(d.subzone or ""), tostring(d.name or d.playerKey or "?")))
      sent = sent + 1; if sent > 600 then break end
    end
  end
end

-- ===== Receiver =====
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
      table.insert(RepriseHC.GetDeathLog(), { playerKey=p.playerKey, name=p.name, level=p.level, class=p.class, race=p.race, zone=p.zone, subzone=p.subzone, when=time() })
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

-- ===== Startup & retries =====
local F = CreateFrame("Frame")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("CHAT_MSG_ADDON")
F:RegisterEvent("PLAYER_GUILD_UPDATE")
F:RegisterEvent("GUILD_ROSTER_UPDATE")

local function requestWithBackoff()
  if haveSnapshot then return end
  RepriseHC.Comm_Send("REQSNAP", { need="all" }) -- structured
  C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "GUILD") -- plain (works even if peers lack Ace)
  local id = GetChannelName("RepriseHC"); if id > 0 then C_ChatInfo.SendAddonMessage(PREFIX, "REQ", "CHANNEL", id) end
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
      RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() })
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
