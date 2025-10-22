-- AchievementsComm.lua — RepriseHC comms (Classic 1.15.7)
-- Uses AceComm-3.0 + AceSerializer-3.0 (embedded in RepriseHC/Libs)
-- Prefix: RepriseHC_ACH

local PREFIX = "RepriseHC_ACH"
local RHC_DEBUG = true  -- set true to print who we whisper
local suppressGuildAnnouncementsUntil = 0
local lastOwnDeathAnnounceAt = 0

local function debugPrint(...)
  if RHC_DEBUG and print then print("|cff99ccff[RHC]|r", ...) end
end

local function SuppressGuildAnnouncements(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then return end
  local untilTime = GetTime() + seconds
  if untilTime > suppressGuildAnnouncementsUntil then
    suppressGuildAnnouncementsUntil = untilTime
  end
end

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
local selfName, selfRealm
local function RefreshSelfIdentity()
  local name, realm = UnitName("player")
  if name and name ~= "" then
    selfName = name
  end
  realm = realm or GetRealmName()
  if realm and realm ~= "" then
    selfRealm = realm
  end
end

RefreshSelfIdentity()

local function SelfId()
  if not selfName or selfName == "" then RefreshSelfIdentity() end
  local name = selfName or "player"
  local realm = selfRealm
  if realm and realm ~= "" then
    return name .. "-" .. realm
  end
  return name
end

local function SplitNameAndRealm(name)
  if not name or name == "" then return nil end
  local base, realm = name:match("^([^%-]+)%-(.*)$")
  if base then
    if realm == "" then realm = nil end
    return base, realm
  end
  return name, nil
end

local function CanonicalShort(name)
  local base = Ambiguate(name or "", "short")
  return base and base:lower() or ""
end

local function FullName(name, realm)
  if not name or name == "" then return nil end
  if realm and realm ~= "" then
    return name .. "-" .. realm
  end
  if selfRealm and selfRealm ~= "" then
    return name .. "-" .. selfRealm
  end
  return name
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
    local playerKey, levelStr, class, race, zone, subzone, name, whenStr =
      rest:match("^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);?(.*)$")
    if not playerKey then return end
    local when = tonumber(whenStr) or time()
    return { v=1, t="DEATH", q=0, s="LEGACY",
      p={ playerKey=playerKey, level=tonumber(levelStr or "0") or 0, class=class, race=race, zone=zone, subzone=subzone, name=name, when=when } }
  end
end

-- -------- guild readiness grace --------
local lastGuildTouch = 0
local lastRosterRequest = 0
local function MarkGuildTouched() lastGuildTouch = GetTime() end

local function PollGuildRoster()
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  else
    GuildRoster()
  end
  lastRosterRequest = GetTime()
end

local function GuildRouteReady()
  if not IsInGuild() then return false end
  local guildName = GetGuildInfo("player")
  if not guildName or guildName == "" then return false end

  -- Allow immediate sends once we've seen a roster (including ones we triggered).
  if lastGuildTouch == 0 then return true end

  local now = GetTime()
  if now - lastGuildTouch >= 0.5 then return true end

  if lastRosterRequest > 0 and lastGuildTouch >= lastRosterRequest then
    return true
  end

  return false
end
do
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_LOGIN")
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("PLAYER_GUILD_UPDATE")
  f:RegisterEvent("GUILD_ROSTER_UPDATE")
  f:SetScript("OnEvent", function(_, ev)
    if ev == "PLAYER_LOGIN" or ev == "PLAYER_ENTERING_WORLD" then
      RefreshSelfIdentity()
      MarkGuildTouched()
    elseif ev == "PLAYER_GUILD_UPDATE" or ev == "GUILD_ROSTER_UPDATE" then
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

local function IsSelf(name)
  if not name or name == "" then return false end
  if not selfName then RefreshSelfIdentity() end
  local base, realm = SplitNameAndRealm(name)
  if not base then return false end
  realm = realm or selfRealm
  if not realm or realm == "" then
    realm = selfRealm
  end
  return (base == selfName) and ((realm or "") == (selfRealm or ""))
end

local function BuildWhisperTargets(name)
  local targets, seen = {}, {}
  local base, realm = SplitNameAndRealm(name)
  if not base then return targets end

  local function push(target)
    if target and target ~= "" and not seen[target] then
      table.insert(targets, target)
      seen[target] = true
    end
  end

  if realm and realm ~= "" then
    push(base .. "-" .. realm)
  else
    push(FullName(base, selfRealm))
  end
  push(base)

  return targets
end

local function SendWhisperTargets(payload, name, debugLabel)
  local sent = false
  for _, target in ipairs(BuildWhisperTargets(name)) do
    if not IsSelf(target) then
      AceComm:SendCommMessage(PREFIX, payload, "WHISPER", target)
      if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", target)
      end
      if debugLabel then
        debugPrint(debugLabel, target)
      else
        debugPrint("fanout ->", target)
      end
      sent = true
    end
  end
  return sent
end

local function SendWhisperFallback(payload, maxPeers)
  maxPeers = maxPeers or 12
  if not IsInGuild() then return false end

  PollGuildRoster()

  local count = GetNumGuildMembers() or 0
  if count == 0 then return false end

  -- === Special case: exactly 2 online (me + one other) -> target them explicitly ===
  local onlineNames = {}
  for i = 1, count do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name then table.insert(onlineNames, name) end
  end

  if #onlineNames == 2 then
    local other = onlineNames[1]
    if IsSelf(other) then other = onlineNames[2] end
    if other and not IsSelf(other) then
      local sent = SendWhisperTargets(payload, other, "DEATH fallback->")
      return sent
    end
  end

  -- === General case: rotate through roster, prefer GM, exclude self ===
  local sent, seen = 0, {}

  local function trySendIndex(i)
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name then
      local key = CanonicalShort(name)
      if key ~= "" and not seen[key] and not IsSelf(name) then
        local delivered = SendWhisperTargets(payload, name)
        if delivered then
          seen[key] = true
          sent = sent + 1
          return true
        end
      end
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

local function SendDirectToOtherOnline(payload)
  if not IsInGuild() then return false end
  PollGuildRoster()
  local n = GetNumGuildMembers() or 0
  local other
  for i=1,n do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if online and name and not IsSelf(name) then
      if other then
        return false  -- more than one other online
      end
      other = name
    end
  end
  if not other then return false end

  local sent = SendWhisperTargets(payload, other, "DEATH direct->")
  return sent
end

local function SendSnapshotPayload(payloadTable, target)
  local wire = BuildWire("SNAP", payloadTable)
  if not wire or wire == "" then return false end

  local delivered = false
  if target and target ~= "" then
    delivered = SendWhisperTargets(wire, target, "SNAP ->")
  end

  if delivered then return true end

  if SendViaGuild(wire) then return true end
  if SendViaGroup(wire) then return true end

  return SendWhisperFallback(wire, 6)
end

local function SendSmallSnapshot()
  SendSnapshotPayload({ kind="SNAP", data=BuildSnapshot() })
end

local function MergeSnapshot(p)
  if type(p) ~= "table" then return end
  local db = RepriseHC.DB()
  db.characters  = db.characters  or {}
  db.guildFirsts = db.guildFirsts or {}
  db.deathLog    = db.deathLog    or {}

  local function cloneDeathEntry(src)
    if type(src) ~= "table" then return nil end
    local when = tonumber(src.when) or tonumber(src.time)
    if when and when > 0 then
      when = math.floor(when)
    else
      when = time()
    end
    local pk = src.playerKey or src.player or src.name
    if not pk or pk == "" then return nil end
    local nm = src.name
    if (not nm or nm == "") and type(pk) == "string" then
      nm = pk:match("^([^%-]+)") or pk
    end
    return {
      playerKey = pk,
      name      = nm,
      level     = src.level,
      class     = src.class,
      race      = src.race,
      zone      = src.zone,
      subzone   = src.subzone,
      when      = when,
    }
  end

  for k,v in pairs(p.characters or {}) do
    local lc = db.characters[k]
    if not lc or (v.points or 0) > (lc.points or 0) then db.characters[k] = v end
  end
  for id,entry in pairs(p.guildFirsts or {}) do
    if not db.guildFirsts[id] then db.guildFirsts[id] = entry end
  end
  
  local incoming = p.deathLog or {}
  local function normalizeForCompare(key)
    return (key or ""):lower():gsub("%-.*$", "")
  end

  local currentCount = #db.deathLog
  if currentCount == 0 then
    for _,d in ipairs(incoming) do
      local entry = cloneDeathEntry(d)
      if entry then table.insert(db.deathLog, entry) end
    end
    return
  end

  local seen = {}
  for _,d in ipairs(db.deathLog) do
    if d.playerKey or d.name then
      seen[normalizeForCompare(d.playerKey or d.name)] = true
    end
  end

  for _,d in ipairs(incoming) do
    local entry = cloneDeathEntry(d)
    if entry then
      local norm = normalizeForCompare(entry.playerKey)
      if norm ~= "" and not seen[norm] then
        table.insert(db.deathLog, entry)
        seen[norm] = true
      end
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

    -- Check for duplicates using normalized comparison
    local seen = false
    local function normalizeForCompare(key)
      return (key or ""):lower():gsub("%-.*$", "")
    end
    local incomingNorm = normalizeForCompare(p.playerKey or p.name)

    for _, d in ipairs(RepriseHC.GetDeathLog()) do
      if normalizeForCompare(d.playerKey or d.name) == incomingNorm then
        seen = true
        break
      end
    end
    
    if seen then
      if RHC_DEBUG then print("|cff99ccff[RHC]|r DEATH already logged for", p.playerKey, "— skipping") end
      return
    end

    local eventWhen = tonumber(p.when) or tonumber(p.time) or time()
    eventWhen = eventWhen > 0 and math.floor(eventWhen) or time()
    table.insert(RepriseHC.GetDeathLog(), {
      playerKey=p.playerKey or p.name, name=p.name, level=p.level, class=p.class, race=p.race,
      zone=p.zone, subzone=p.subzone, when=eventWhen
    })

    if RHC_DEBUG then print("|cff99ccff[RHC]|r DEATH inserted for", p.playerKey or p.name or "?") end

    -- Guild announcement for our own death (skip others)
    local announceToGuild = false
    if IsInGuild() and RepriseHC.GetShowToGuild and RepriseHC.GetShowToGuild() then
      local myKey = RepriseHC.PlayerKey and RepriseHC.PlayerKey() or UnitName("player")
      local myNorm = normalizeForCompare(myKey)
      if incomingNorm ~= "" and incomingNorm == myNorm then
        local now = time()
        local age = now - (eventWhen or now)
        if age < 0 then age = 0 end
        local suppressed = (GetTime() < suppressGuildAnnouncementsUntil)
        local recentlyAnnounced = (now - lastOwnDeathAnnounceAt) < 60
        if not suppressed and age < 120 and not recentlyAnnounced then
          announceToGuild = true
          lastOwnDeathAnnounceAt = now
        end
      end
    end
    if announceToGuild then
      local where = (p.zone or "Unknown")
      if p.subzone and p.subzone ~= "" then where = where .. " - " .. p.subzone end
      local msg = string.format("%s has died (lvl %d) in %s.", p.name or p.playerKey or "Unknown", p.level or 0, where)
      SendChatMessage(msg, "GUILD")
    end

    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end

  elseif topic == "REQSNAP" then
    SendSnapshotPayload({ kind="SNAP", data=BuildSnapshot() }, sender)

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
  if topic == "SNAP" then
    SendSnapshotPayload(payloadTable or {}, nil)
    return
  end

  if topic == "REQSNAP" then
    SuppressGuildAnnouncements(12)
  end

  local wire = BuildWire(topic, payloadTable)
  if not wire or wire == "" then return end

  local usedGuild = SendViaGuild(wire)
  local usedGroup = false
  if not usedGuild then
    usedGroup = SendViaGroup(wire)
  end

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