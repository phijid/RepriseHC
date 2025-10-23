-- AchievementsComm.lua — RepriseHC comms (Classic 1.15.7)
-- Uses AceComm-3.0 + AceSerializer-3.0 (embedded in RepriseHC/Libs)
-- Prefix: RepriseHC_ACH

local PREFIX = "RepriseHC_ACH"
local RHC_DEBUG = true  -- set true to print who we whisper
local lastOwnDeathAnnounceAt = 0
local lastResetStamp
local haveSnapshot = false
local lastUpgradeRequestAt = 0
local SendSnapshotPayload
local DIRECT_ADDON_MAX = 240

local function debugPrint(...)
  if RHC_DEBUG and print then print("|cff99ccff[RHC]|r", ...) end
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

local function SafeDB()
  if RepriseHC and RepriseHC.DB then
    local ok, db = pcall(RepriseHC.DB)
    if ok and type(db) == "table" then return db end
  end
  RepriseHCAchievementsDB = RepriseHCAchievementsDB or {
    characters = {},
    guildFirsts = {},
    deathLog = {},
    config = {},
    groupAssignments = {},
  }
  return RepriseHCAchievementsDB
end

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

local function CurrentDbVersion()
  if RepriseHC and RepriseHC.GetDbVersion then
    local ok = tonumber(RepriseHC.GetDbVersion())
    if ok and ok > 0 then return ok end
  end
  local db = RepriseHC and RepriseHC.DB and RepriseHC.DB()
  if db and db.config and db.config.dbVersion then
    return tonumber(db.config.dbVersion) or 0
  end
  return 0
end

local function EnsureDbVersion(ver)
  local version = tonumber(ver) or 0
  if RepriseHC and RepriseHC.SetDbVersion then
    RepriseHC.SetDbVersion(version)
  else
    local db = RepriseHC and RepriseHC.DB and RepriseHC.DB()
    if db then
      db.config = db.config or {}
      db.config.dbVersion = version
    end
  end
  local removed = 0
  if RepriseHC and RepriseHC.PruneDeathLogToVersion then
    local deaths = RepriseHC.PruneDeathLogToVersion(version)
    if deaths and deaths > 0 then removed = removed + deaths end
  end
  if RepriseHC and RepriseHC.PruneAchievementsToVersion then
    local ach = RepriseHC.PruneAchievementsToVersion(version)
    if ach and ach > 0 then removed = removed + ach end
  end
  if removed > 0 and RepriseHC and RepriseHC.RefreshUI then
    RepriseHC.RefreshUI()
  end
end

local function PruneLocalDataToVersion(version)
  local removed = 0
  if RepriseHC and RepriseHC.PruneDeathLogToVersion then
    local deaths = RepriseHC.PruneDeathLogToVersion(version)
    if deaths and deaths > 0 then removed = removed + deaths end
  end
  if RepriseHC and RepriseHC.PruneAchievementsToVersion then
    local ach = RepriseHC.PruneAchievementsToVersion(version)
    if ach and ach > 0 then removed = removed + ach end
  end
  if removed > 0 and RepriseHC and RepriseHC.RefreshUI then
    RepriseHC.RefreshUI()
  end
  return removed
end

local function PruneLocalDataForCurrentVersion()
  return PruneLocalDataToVersion(CurrentDbVersion())
end

local function ShouldAcceptIncremental(dbv, sender)
  local incoming = tonumber(dbv) or 0
  local localVersion = CurrentDbVersion()
  if incoming == 0 then
    if localVersion ~= 0 and RHC_DEBUG then
      print("|cffff6666[RHC]|r dropping payload without db version (have", localVersion, ")")
    end
    if localVersion ~= 0 and sender and SendSnapshotPayload then
      SendSnapshotPayload({ kind="SNAP", data=BuildSnapshot() }, sender)
    end
    return localVersion == 0
  end
  if localVersion == 0 then
    EnsureDbVersion(incoming)
    return true
  end
  if incoming < localVersion then
    if RHC_DEBUG then
      print("|cffff6666[RHC]|r dropping older payload", incoming, "<", localVersion)
    end
    if sender and SendSnapshotPayload then
      SendSnapshotPayload({ kind="SNAP", data=BuildSnapshot() }, sender)
    end
    return false
  end
  if incoming > localVersion then
    if RHC_DEBUG then
      print("|cffff8800[RHC]|r newer payload detected", incoming, ">", localVersion)
    end
    haveSnapshot = false
    if C_Timer and C_Timer.After then
      local now = GetTime and GetTime() or time()
      if now - (lastUpgradeRequestAt or 0) > 5 then
        lastUpgradeRequestAt = now
        C_Timer.After(1, function()
          if RepriseHC and RepriseHC.Comm_Send then
            RepriseHC.Comm_Send("REQSNAP", { need="all" })
          end
        end)
      end
    end
    return false
  end
  return true
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
      PruneLocalDataForCurrentVersion()
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
        if type(payload) == "string" and #payload <= DIRECT_ADDON_MAX then
          C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", target)
        end
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
  if type(payloadTable) == "table" then
    if payloadTable.dbv == nil then
      local dbv = CurrentDbVersion()
      if dbv > 0 then payloadTable.dbv = dbv else payloadTable.dbv = 0 end
    end
  end
  return Encode(Envelope(topic, payloadTable or {}))
end

-- -------- snapshot build/merge --------
function BuildSnapshot()
  local db = SafeDB()
  db.characters = db.characters or {}
  db.guildFirsts = db.guildFirsts or {}
  db.deathLog = db.deathLog or {}
  db.config = db.config or {}

  local dbVersion = CurrentDbVersion()
  if RepriseHC and RepriseHC.PruneAchievementsToVersion then
    RepriseHC.PruneAchievementsToVersion(dbVersion)
  end
  if RepriseHC and RepriseHC.PruneDeathLogToVersion then
    RepriseHC.PruneDeathLogToVersion(dbVersion)
  end

  local charactersCopy = {}
  for playerKey, entry in pairs(db.characters) do
    if type(entry) == "table" then
      if RepriseHC and RepriseHC.NormalizeCharacterAchievements then
        RepriseHC.NormalizeCharacterAchievements(entry, dbVersion)
      end

      local clone = {}
      for k, v in pairs(entry) do
        if k ~= "achievements" and k ~= "dbv" and k ~= "points" then
          clone[k] = v
        end
      end

      local achClone = {}
      local totalPoints = 0
      for achId, ach in pairs(entry.achievements or {}) do
        if type(ach) == "table" then
          local achVersion = tonumber(ach.dbVersion or ach.dbv) or dbVersion
          if dbVersion == 0 or achVersion == dbVersion then
            local clonedAch = {}
            for ak, av in pairs(ach) do clonedAch[ak] = av end
            if dbVersion ~= 0 then
              clonedAch.dbVersion = dbVersion
            else
              clonedAch.dbVersion = achVersion
            end
            clonedAch.dbv = nil
            clonedAch.points = tonumber(clonedAch.points) or 0
            clonedAch.when = tonumber(clonedAch.when) or 0
            totalPoints = totalPoints + clonedAch.points
            achClone[achId] = clonedAch
          end
        end
      end

      clone.achievements = achClone
      clone.points = totalPoints
      if dbVersion ~= 0 then
        clone.dbVersion = dbVersion
      else
        clone.dbVersion = tonumber(entry.dbVersion or entry.dbv) or 0
      end
      clone.dbv = nil
      charactersCopy[playerKey] = clone
    end
  end

  local guildFirstsCopy = {}
  for id, info in pairs(db.guildFirsts) do
    if type(info) == "table" then
      local entryVersion = tonumber(info.dbVersion or info.dbv) or dbVersion
      if dbVersion == 0 or entryVersion == dbVersion then
        local clone = {}
        for k, v in pairs(info) do clone[k] = v end
        if dbVersion ~= 0 then
          clone.dbVersion = dbVersion
        else
          clone.dbVersion = entryVersion
        end
        clone.dbv = nil
        clone.when = tonumber(clone.when) or 0
        guildFirstsCopy[id] = clone
      end
    end
  end

  local deathLogCopy = {}
  for _, entry in ipairs(db.deathLog) do
    if type(entry) == "table" then
      local cloned = {}
      for k, v in pairs(entry) do cloned[k] = v end
      local entryVersion = tonumber(cloned.dbVersion or cloned.dbv) or dbVersion
      if dbVersion ~= 0 and entryVersion ~= dbVersion then
        entryVersion = dbVersion
      end
      cloned.dbVersion = entryVersion
      cloned.dbv = nil
      table.insert(deathLogCopy, cloned)
    end
  end

  return {
    ver         = RepriseHC.version or "0",
    dbVersion   = dbVersion,
    characters  = charactersCopy,
    guildFirsts = guildFirstsCopy,
    deathLog    = deathLogCopy,
    levelCap    = db.config.levelCap or RepriseHC.levelCap
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

SendSnapshotPayload = function(payloadTable, target)
  if type(payloadTable) == "table" then
    local current = CurrentDbVersion()
    if current and current > 0 and payloadTable.dbVersion == nil then
      payloadTable.dbVersion = current
    end
  end
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

local lastResetSentTo = {}

local function SendTargetedReset(version, target)
  if not target or target == "" then return false end
  if IsSelf and IsSelf(target) then return false end

  local normalized = CanonicalShort(target)
  local now = (GetTime and GetTime()) or time()
  if normalized ~= "" then
    local last = lastResetSentTo[normalized]
    if last and (now - last) < 5 then
      return false
    end
    lastResetSentTo[normalized] = now
  end

  local sig = RepriseHC and RepriseHC._ResetSignature
  if not sig then return false end

  local dbVersion = tonumber(version) or CurrentDbVersion()
  if not dbVersion or dbVersion <= 0 then return false end

  local stamp = (GetServerTime and GetServerTime()) or time()
  local payload = {
    sig = sig,
    stamp = stamp,
    source = SelfId(),
    dbVersion = dbVersion,
    dbv = dbVersion,
  }

  local wire = BuildWire("RESET", payload)
  if not wire or wire == "" then return false end

  if SendWhisperTargets(wire, target, "RESET ->") then
    return true
  end

  return false
end

local function MergeSnapshot(p)
  if type(p) ~= "table" then return end
  local incomingVersion = tonumber(p.dbVersion) or tonumber(p.dbv) or 0
  local localVersion = CurrentDbVersion()

  if incomingVersion == 0 then
    if localVersion ~= 0 then
      if RHC_DEBUG then print("|cffff6666[RHC]|r snapshot rejected (missing version)") end
      return
    end
  elseif localVersion == 0 then
    EnsureDbVersion(incomingVersion)
    localVersion = incomingVersion
  elseif incomingVersion < localVersion then
    if RHC_DEBUG then
      print("|cffff6666[RHC]|r snapshot rejected (older version)", incomingVersion, "<", localVersion)
    end
    return
  elseif incomingVersion > localVersion then
    if RHC_DEBUG then
      print("|cffff8800[RHC]|r snapshot adopting newer version", incomingVersion)
    end
    if RepriseHC and RepriseHC._HardResetDB then
      RepriseHC._HardResetDB("|cffff6060Global reset detected from sync.|r", incomingVersion)
    else
      local db = SafeDB()
      db.characters, db.guildFirsts, db.deathLog, db.groupAssignments = {}, {}, {}, {}
      db.config = db.config or {}
      db.config.dbVersion = incomingVersion
    end
    EnsureDbVersion(incomingVersion)
    if lastResetSentTo then
      if wipe then
        wipe(lastResetSentTo)
      else
        lastResetSentTo = {}
      end
    end
    localVersion = incomingVersion
  end

  local db = SafeDB()
  db.characters  = db.characters  or {}
  db.guildFirsts = db.guildFirsts or {}
  db.deathLog    = db.deathLog    or {}
  db.groupAssignments = db.groupAssignments or {}
  db.config = db.config or {}
  if localVersion ~= 0 or incomingVersion ~= 0 then
    db.config.dbVersion = localVersion ~= 0 and localVersion or incomingVersion
  end

  PruneLocalDataToVersion(localVersion)

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
    local entryVersion = tonumber(src.dbVersion or src.dbv) or incomingVersion or localVersion or 0
    if incomingVersion and incomingVersion ~= 0 then
      entryVersion = incomingVersion
    elseif localVersion and localVersion ~= 0 and entryVersion == 0 then
      entryVersion = localVersion
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
      dbVersion = entryVersion,
    }
  end

  for playerKey, incomingChar in pairs(p.characters or {}) do
    if type(incomingChar) == "table" then
      db.characters[playerKey] = db.characters[playerKey] or { points = 0, achievements = {} }
      local dest = db.characters[playerKey]
      dest.achievements = dest.achievements or {}

      for field, value in pairs(incomingChar) do
        if field ~= "achievements" and field ~= "points" and field ~= "dbVersion" and field ~= "dbv" then
          if dest[field] == nil then dest[field] = value end
        end
      end

      for achId, ach in pairs(incomingChar.achievements or {}) do
        if type(ach) == "table" then
          local entryVersion = tonumber(ach.dbVersion or ach.dbv) or localVersion
          if localVersion == 0 or entryVersion == localVersion then
            local clone = {}
            for ak, av in pairs(ach) do clone[ak] = av end
            if localVersion ~= 0 then
              clone.dbVersion = localVersion
            else
              clone.dbVersion = entryVersion
            end
            clone.dbv = nil
            clone.points = tonumber(clone.points) or 0
            clone.when = tonumber(clone.when) or 0
            dest.achievements[achId] = clone
          end
        end
      end

      if RepriseHC and RepriseHC.NormalizeCharacterAchievements then
        RepriseHC.NormalizeCharacterAchievements(dest, localVersion)
      else
        local total = 0
        for _, ach in pairs(dest.achievements) do
          total = total + (tonumber(ach.points) or 0)
        end
        dest.points = total
      end

      if localVersion ~= 0 then
        dest.dbVersion = localVersion
      else
        dest.dbVersion = tonumber(dest.dbVersion or incomingChar.dbVersion or incomingChar.dbv) or 0
      end
      dest.dbv = nil
    end
  end

  for id, entry in pairs(p.guildFirsts or {}) do
    if type(entry) == "table" then
      local entryVersion = tonumber(entry.dbVersion or entry.dbv) or localVersion
      if localVersion == 0 or entryVersion == localVersion then
        local clone = {}
        for k, v in pairs(entry) do clone[k] = v end
        if localVersion ~= 0 then
          clone.dbVersion = localVersion
        else
          clone.dbVersion = entryVersion
        end
        clone.dbv = nil
        clone.when = tonumber(clone.when) or 0

        local existing = db.guildFirsts[id]
        if not existing or (tonumber(existing.when) or 0) > clone.when then
          db.guildFirsts[id] = clone
        end
      end
    end
  end
  
  local incoming = p.deathLog or {}
  local function normalizeEntryKey(entry)
    if not entry then return "" end
    local key = entry.playerKey
    if not key or key == "" then key = entry.name end
    if not key or key == "" then return "" end
    return key:lower():gsub("%-.*$", "")
  end

  local function fallbackKey(entry)
    if not entry then return nil end
    local name = entry.name or entry.playerKey
    local when = tonumber(entry.when) or 0
    if (not name or name == "") and when == 0 then return nil end
    name = (name or ""):lower()
    return string.format("%s#%d", name, when)
  end

  local function shallowCopy(entry)
    if type(entry) ~= "table" then return nil end
    local cloned = {}
    for k, v in pairs(entry) do cloned[k] = v end
    if localVersion ~= 0 then
      local entryVersion = tonumber(cloned.dbVersion or cloned.dbv) or localVersion
      if entryVersion ~= localVersion then
        entryVersion = localVersion
      end
      cloned.dbVersion = entryVersion
      cloned.dbv = nil
    else
      cloned.dbVersion = tonumber(cloned.dbVersion or cloned.dbv) or 0
      cloned.dbv = nil
    end
    return cloned
  end

  local staged, stagedByNorm = {}, {}
  local copy = stagedByNorm -- backwards compat for older local naming
  -- Some legacy builds referenced a local "copy" table when staging snapshot
  -- entries. Preserve a temporary alias so any outstanding references resolve
  -- to the same staging map instead of a nil global.
  local existingGlobalCopy = rawget(_G, "copy")
  local providedGlobalCopyAlias = false
  if existingGlobalCopy == nil then
    _G.copy = stagedByNorm
    providedGlobalCopyAlias = true
  end
  local function releaseCopyAlias()
    if providedGlobalCopyAlias then
      _G.copy = existingGlobalCopy
    end
  end
  for _, raw in pairs(incoming) do
    local entry = cloneDeathEntry(raw)
    if entry then
      table.insert(staged, entry)
      local norm = normalizeEntryKey(entry)
      if norm ~= "" then
        stagedByNorm[norm] = entry
      end
    end
  end

  if #staged == 0 then
    releaseCopyAlias()
    return
  end

  table.sort(staged, function(a, b)
    return (a.when or 0) < (b.when or 0)
  end)

  local seen, seenFallback = {}, {}
  local function markSeen(entry)
    if not entry then return end
    if localVersion ~= 0 then
      entry.dbVersion = localVersion
    else
      entry.dbVersion = tonumber(entry.dbVersion or entry.dbv) or 0
    end
    entry.dbv = nil
    local norm = normalizeEntryKey(entry)
    if norm ~= "" and not seen[norm] then
      seen[norm] = entry
    end
    local fb = fallbackKey(entry)
    if fb and not seenFallback[fb] then
      seenFallback[fb] = entry
    end
  end

  for _, existing in ipairs(db.deathLog) do
    markSeen(existing)
  end

  local function appendEntry(entry)
    local cloned = shallowCopy(entry)
    if not cloned then return end
    table.insert(db.deathLog, cloned)
    markSeen(cloned)
  end

  for _, entry in ipairs(staged) do
    local norm = normalizeEntryKey(entry)
    if norm ~= "" then
      local dest = seen[norm]
      if dest then
        for k, v in pairs(entry) do
          if v ~= nil and v ~= "" then
            dest[k] = v
          end
        end
        if localVersion ~= 0 then
          dest.dbVersion = localVersion
        end
      else
        appendEntry(entry)
      end
    else
      local fb = fallbackKey(entry)
      local dest = fb and seenFallback[fb] or nil
      if dest then
        for k, v in pairs(entry) do
          if v ~= nil and v ~= "" then
            dest[k] = v
          end
        end
        if localVersion ~= 0 then
          dest.dbVersion = localVersion
        end
      else
        appendEntry(entry)
      end
    end
  end

  -- Ensure our own death record is restored when peers still have it.
  local myNormKey
  if RepriseHC and RepriseHC.PlayerKey then
    local selfKey = RepriseHC.PlayerKey()
    if selfKey and selfKey ~= "" then
      myNormKey = selfKey:lower():gsub("%-.*$", "")
    end
  end

  if myNormKey and myNormKey ~= "" and not seen[myNormKey] then
    local match = stagedByNorm[myNormKey]
    if not match then
      for _, entry in ipairs(staged) do
        local nm = (entry.name or entry.playerKey or ""):lower():gsub("%-.*$", "")
        if nm == myNormKey then
          match = entry
          break
        end
      end
    end
    if match then
      appendEntry(match)
    end
  end

  table.sort(db.deathLog, function(a, b)
    return (a.when or 0) < (b.when or 0)
  end)
  releaseCopyAlias()
end

-- -------- RX dedupe by sender sequence --------
local lastSeqBySender = {} -- [sender]=lastQ
local function IsDup(sender, q)
  if (q or 0) <= 0 then return false end
  local last = lastSeqBySender[sender]
  if not last or q > last then lastSeqBySender[sender] = q; return false end
  return true
end

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
    if not ShouldAcceptIncremental(p.dbv, sender) then return end
    normalizeKeyAndName(p, sender)
    if not p.id or p.id == "" then return end

    local db = SafeDB()
    db.characters = db.characters or {}
    db.guildFirsts = db.guildFirsts or {}

    local targetVersion = CurrentDbVersion()
    local entryVersion = tonumber(p.dbVersion or p.dbv) or targetVersion
    if targetVersion ~= 0 then
      entryVersion = targetVersion
    end

    local when = tonumber(p.when) or time()
    local points = tonumber(p.pts) or 0

    db.characters[p.playerKey] = db.characters[p.playerKey] or { points = 0, achievements = {} }
    local c = db.characters[p.playerKey]
    c.achievements = c.achievements or {}

    c.achievements[p.id] = {
      name = p.name or p.id,
      points = points,
      when = when,
      dbVersion = entryVersion,
    }

    if RepriseHC and RepriseHC.NormalizeCharacterAchievements then
      RepriseHC.NormalizeCharacterAchievements(c, targetVersion)
    else
      local total = 0
      for _, ach in pairs(c.achievements) do
        total = total + (tonumber(ach.points) or 0)
      end
      c.points = total
    end

    if targetVersion ~= 0 then
      c.dbVersion = targetVersion
    else
      c.dbVersion = tonumber(c.dbVersion or c.dbv) or 0
    end
    c.dbv = nil

    if p.id and p.id:find("^FIRST_" .. RepriseHC.levelCap) then
      local gf = db.guildFirsts[p.id]
      if not gf then
        gf = {
          winner = p.playerKey,
          winnerName = p.name,
          when = when,
          dbVersion = entryVersion,
        }
        db.guildFirsts[p.id] = gf
      else
        if not gf.winner then gf.winner = p.playerKey end
        if not gf.winnerName then gf.winnerName = p.name end
        if not gf.when or gf.when == 0 then gf.when = when end
        if targetVersion ~= 0 then
          gf.dbVersion = targetVersion
        else
          gf.dbVersion = tonumber(gf.dbVersion or gf.dbv) or entryVersion
        end
      end
      if gf then gf.dbv = nil end
    end

    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end

  elseif topic == "DEATH" then
    if not ShouldAcceptIncremental(p.dbv, sender) then return end
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
    local entryVersion = tonumber(p.dbVersion or p.dbv) or CurrentDbVersion()
    table.insert(RepriseHC.GetDeathLog(), {
      playerKey=p.playerKey or p.name, name=p.name, level=p.level, class=p.class, race=p.race,
      zone=p.zone, subzone=p.subzone, when=eventWhen, dbVersion=entryVersion
    })

    if RHC_DEBUG then print("|cff99ccff[RHC]|r DEATH inserted for", p.playerKey or p.name or "?") end

    -- Guild announcement for our own death (skip others)
    local announceToGuild = false
    if IsInGuild() and RepriseHC.GetShowToGuild and RepriseHC.GetShowToGuild() then
      local myKey = RepriseHC.PlayerKey and RepriseHC.PlayerKey() or UnitName("player")
      local myNorm = normalizeForCompare(myKey)
      local isSelfSource = IsSelf(sender) or IsSelf(sid)
      if incomingNorm ~= "" and incomingNorm == myNorm and isSelfSource then
        local now = time()
        local age = now - (eventWhen or now)
        if age < 0 then age = 0 end
        local recentlyAnnounced = (now - lastOwnDeathAnnounceAt) < 60
        if age < 120 and not recentlyAnnounced then
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

  elseif topic == "RESET" then
    local sig = tonumber(p.sig)
    local expected = RepriseHC._ResetSignature
    if not sig or not expected or sig ~= expected then
      if RHC_DEBUG then
        print("|cffff6666[RHC]|r reset ignored (bad signature)")
      end
      return
    end

    local stamp = tonumber(p.stamp) or 0
    local dbVersion = tonumber(p.dbv) or tonumber(p.dbVersion) or 0
    if stamp ~= 0 then
      if RepriseHC._LastResetStamp and stamp == RepriseHC._LastResetStamp then
        if RHC_DEBUG then print("|cff99ccff[RHC]|r reset echo ignored") end
        return
      end
      if lastResetStamp and stamp == lastResetStamp then
        return
      end
      lastResetStamp = stamp
    else
      if dbVersion > 0 and RepriseHC._LastResetDbVersion and RepriseHC._LastResetDbVersion == dbVersion then
        if RHC_DEBUG then print("|cff99ccff[RHC]|r duplicate reset version ignored") end
        return
      end
      lastResetStamp = time()
    end

    RepriseHC._LastResetStamp = lastResetStamp
    if dbVersion > 0 then
      RepriseHC._LastResetDbVersion = dbVersion
    end

    local origin = p.source
    if type(origin) ~= "string" or origin == "" then
      origin = sender or ""
    end
    if type(origin) == "string" and origin ~= "" then
      origin = origin:gsub("-.*$", "")
    else
      origin = nil
    end

    local reason = "|cffff6060Global reset applied.|r"
    if origin then
      reason = ("|cffff6060Global reset applied by %s.|r"):format(origin)
    end

    if RepriseHC._HardResetDB then
      if dbVersion > 0 then
        RepriseHC._HardResetDB(reason, dbVersion)
      else
        RepriseHC._HardResetDB(reason)
      end
    end

    if dbVersion and dbVersion > 0 then
      EnsureDbVersion(dbVersion)
    end

    if dbVersion and dbVersion > 0 and lastResetSentTo then
      if wipe then
        wipe(lastResetSentTo)
      else
        lastResetSentTo = {}
      end
    end

    haveSnapshot = false
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end

  elseif topic == "REQSNAP" then
    local requestVersion = tonumber(p.dbVersion) or tonumber(p.dbv) or 0
    local localVersion = CurrentDbVersion()
    if sender and sender ~= "" and localVersion > 0 then
      if requestVersion == 0 or requestVersion < localVersion then
        SendTargetedReset(localVersion, sender)
      end
    end
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

function RepriseHC.Comm_MarkOwnDeathAnnounced(when)
  local stamp = tonumber(when) or time()
  if stamp and stamp > 0 then
    lastOwnDeathAnnounceAt = stamp
  else
    lastOwnDeathAnnounceAt = time()
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
    PruneLocalDataForCurrentVersion()
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