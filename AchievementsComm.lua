-- Robust communications module for RepriseHC (single prefix: RepriseHC_ACH)
-- Provides: AceSerializer(+LibDeflate) encode/decode, dedupe, topics, snapshots.
-- Public:
--   RepriseHC.Comm_Send(topic, payloadTable)
--   RepriseHC.Comm_OnAddonMessage(prefix, payload, channel, sender)  -- exposed for tests

local PREFIX = "RepriseHC_ACH"
C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

-- ===== Serialization =====
local AceSer   = LibStub and LibStub("AceSerializer-3.0", true)
local Deflate  = LibStub and LibStub("LibDeflate", true)

local function Encode(tbl)
  if not AceSer then return nil end
  local s = AceSer:Serialize(tbl)
  if Deflate then
    local c = Deflate:CompressDeflate(s)
    return Deflate:EncodeForWoWAddonChannel(c)
  end
  return s
end

local function Decode(payload)
  if not AceSer then return nil end
  if Deflate then
    local c = Deflate:DecodeForWoWAddonChannel(payload); if not c then return end
    local s = Deflate:DecompressDeflate(c);              if not s then return end
    local ok, t = AceSer:Deserialize(s); if ok then return t end
    return
  else
    local ok, t = AceSer:Deserialize(payload); if ok then return t end
    return
  end
end

-- ===== Envelope, seq, dedupe =====
local seq = 0
local function NextSeq() seq = (seq + 1) % 1000000; return seq end
local lastSeqBySender = {}  -- [sender] = lastSeq

local function IsDup(sender, q)
  local last = lastSeqBySender[sender]
  if not last or q > last then
    lastSeqBySender[sender] = q
    return false
  end
  return true
end

local function Envelope(topic, payload)
  return { v=1, t=topic, ts=GetServerTime(), s=UnitFullName("player"), q=NextSeq(), p=payload }
end

-- ===== Public send =====
function RepriseHC.Comm_Send(topic, payloadTable)
  if not RepriseHC.IsGuildAllowed() then return end
  local packed = Encode(Envelope(topic, payloadTable or {}))
  if not packed then return end
  -- Prefer GUILD fanout
  if IsInGuild() then
    C_ChatInfo.SendAddonMessage(PREFIX, packed, "GUILD")
  else
    local id = GetChannelName("RepriseHC")
    if id == 0 then JoinPermanentChannel("RepriseHC"); id = GetChannelName("RepriseHC") end
    if id and id > 0 then
      C_ChatInfo.SendAddonMessage(PREFIX, packed, "CHANNEL", id)
    end
  end
end

-- ===== Snapshots =====
local function BuildSnapshot()
  local db = RepriseHC.DB()
  return {
    ver = RepriseHC.version or "0",
    characters  = db.characters or {},
    guildFirsts = db.guildFirsts or {},
    deathLog    = db.deathLog or {},   -- key matches Core.lua helpers
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
    if not lc or (v.points or 0) > (lc.points or 0) then
      db.characters[k] = v
    end
  end
  for id,entry in pairs(p.guildFirsts or {}) do
    if not db.guildFirsts[id] then db.guildFirsts[id] = entry end
  end
  -- Merge death log (keep first death per character)
  local seen = {}
  for _,d in ipairs(db.deathLog) do if d.playerKey then seen[d.playerKey]=true end end
  for _,d in ipairs(p.deathLog or {}) do
    if d.playerKey and not seen[d.playerKey] then
      table.insert(db.deathLog, d)
      seen[d.playerKey] = true
    end
  end
end

local function AnswerSnapshot()
  RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() })
end

-- ===== Receiver =====
local function HandleIncoming(prefix, payload, channel, sender)
  if prefix ~= PREFIX then return end
  local t = Decode(payload); if not t or t.v ~= 1 then return end
  if IsDup(t.s or sender, t.q or 0) then return end
  local p = t.p or {}
  local topic = t.t

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
    if RepriseHC.Print then RepriseHC.Print("Synchronized snapshot.") end
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
  end
end

-- Expose for dev/tests or other modules
function RepriseHC.Comm_OnAddonMessage(prefix, payload, channel, sender)
  HandleIncoming(prefix, payload, channel, sender)
end

-- ===== Event wiring (isolated frame) =====
local F = CreateFrame("Frame")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("CHAT_MSG_ADDON")

F:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    C_Timer.After(5, function() RepriseHC.Comm_Send("REQSNAP", { need="all" }) end)
    local function periodic()
      RepriseHC.Comm_Send("SNAP", { kind="SNAP", data=BuildSnapshot() })
      C_Timer.After(90, periodic)
    end
    C_Timer.After(20, periodic)
  elseif event == "CHAT_MSG_ADDON" then
    local prefix, payload, channel, sender = ...
    HandleIncoming(prefix, payload, channel, sender)
  end
end)