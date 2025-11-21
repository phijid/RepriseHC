-- AchievementsComm.lua — RepriseHC comms (Classic 1.15.7)
-- Uses AceComm-3.0 + AceSerializer-3.0 (embedded in RepriseHC/Libs)
-- Prefix: RepriseHC_ACH

local PREFIX = "RepriseHC_ACH"
local lastOwnDeathAnnounceAt = 0
local lastResetStamp
local haveSnapshot = false
local lastUpgradeRequestAt = 0
local lastSnapshotBroadcastAt = 0
local lastPostChangeSnapshotAt = 0
local lastSnapshotRequestAt = 0
local lastGuildSyncAt = 0
local PERIODIC_SYNC_INTERVAL = 60
local lastDecodeFailureAt = 0
local targetedSnapshotSentAt = {}
local knownOnlineGuildmates = {}
local TARGETED_SNAPSHOT_MIN_INTERVAL = 30
local TARGETED_SNAPSHOT_REFRESH = 180
local SendSnapshotPayload
local MaybeSendTargetedSnapshot
local AdoptIncomingVersion
local DIRECT_ADDON_MAX = 240

local function DebugDeathLog()
  return RepriseHC and RepriseHC.DebugDeathLog
end

local function debugPrint(...)
  if not DebugDeathLog() then return end
  if RepriseHC and RepriseHC.DebugLogDeath then
    RepriseHC.DebugLogDeath(...)
  elseif print then
    print("|cff99ccff[RHC]|r", ...)
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
  local ok, s = pcall(AceSer.Serialize, AceSer, tbl)
  if ok then return s end
  if DebugDeathLog() then
    local keys
    if type(tbl) == "table" then
      keys = {}
      for k in pairs(tbl) do table.insert(keys, tostring(k)) end
      table.sort(keys)
      keys = table.concat(keys, ",")
    end
    debugPrint("AceSer serialize failed; payload keys=", keys or "-")
  end
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

local function CurrentGroupMinor()
  if RepriseHC and RepriseHC.GetGroupMinorVersion then
    local ok = tonumber(RepriseHC.GetGroupMinorVersion())
    if ok and ok >= 0 then return ok end
  end
  local db = SafeDB()
  if db and db.config then
    local gv = tonumber(db.config.groupMinorVersion)
    if gv and gv >= 0 then return gv end
  end
  return 0
end

local function AssignmentMinorFor(playerKey)
  if RepriseHC and RepriseHC.GetGroupAssignmentMinor then
    local ok = tonumber(RepriseHC.GetGroupAssignmentMinor(playerKey))
    if ok and ok >= 0 then return ok end
  end
  local db = SafeDB()
  local cfg = db.config or {}
  local map = cfg.groupAssignmentMinor or {}
  local gv = tonumber(map[playerKey])
  if gv and gv >= 0 then return gv end
  if type(db.groupAssignments) == "table" then
    local entry = db.groupAssignments[playerKey]
    if type(entry) == "table" then
      local v = tonumber(entry.groupVersion or entry.groupMinor or entry.gv)
      if v and v >= 0 then return v end
    end
  end
  return 0
end

local function RememberAssignmentMinor(playerKey, minor)
  if not playerKey then return end
  local value = tonumber(minor) or 0
  if value < 0 then value = 0 end
  if RepriseHC and RepriseHC.GetGroupAssignmentMinor then
    -- Core handles persistence when UpdateGroupAssignment is used.
    if RepriseHC.UpdateGroupAssignment then
      -- no-op; UpdateGroupAssignment already stored the minor
      return
    end
  end
  local db = SafeDB()
  db.config = db.config or {}
  db.config.groupAssignmentMinor = db.config.groupAssignmentMinor or {}
  db.config.groupAssignmentMinor[playerKey] = math.floor(value)
end

local pendingIncrementals = {}
local pendingIncrementalTimers = {}
local pendingIncrementalAttempts = {}
local ProcessPendingIncrementalEntry
local EnsurePendingIncrementalCheck

local function DeepCopy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = DeepCopy(v)
  end
  return out
end

local function QueuePendingIncremental(version, message, sender, sid, channel, seq, ts)
  local target = tonumber(version) or 0
  if target <= 0 then return end
  if type(message) ~= "table" then return end

  pendingIncrementals[target] = pendingIncrementals[target] or {}
  local bucket = pendingIncrementals[target]
  for _, entry in ipairs(bucket) do
    if entry.sid == sid and entry.seq == seq then
      return
    end
  end

  table.insert(bucket, {
    message = DeepCopy(message),
    sender = sender,
    sid = sid,
    channel = channel,
    seq = seq,
    ts = ts,
  })

  local topic = message and message.topic
  if DebugDeathLog() and type(topic) == "string" and topic:upper() == "DEATH" then
    debugPrint(
      "Queueing DEATH payload until version", target,
      "from", sender or "?", "seq=", seq or "?", "channel=", channel or "?", "ts=", ts or "?"
    )
  end
  local urgent = (type(topic) == "string" and topic:upper() == "DEATH")
  EnsurePendingIncrementalCheck(target, topic, urgent)
end

local function FlushPendingIncrementals(version)
  local target = tonumber(version) or 0
  if target <= 0 then return end
  for v, entries in pairs(pendingIncrementals) do
    if v <= target then
      for _, entry in ipairs(entries) do
        ProcessPendingIncrementalEntry(entry)
      end
      pendingIncrementals[v] = nil
      pendingIncrementalAttempts[v] = nil
    end
  end
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
  if RepriseHC and RepriseHC.PruneGroupAssignmentsToVersion then
    local grp = RepriseHC.PruneGroupAssignmentsToVersion(version)
    if grp and grp > 0 then removed = removed + grp end
  end
  if removed > 0 and RepriseHC and RepriseHC.RefreshUI then
    RepriseHC.RefreshUI()
  end
  FlushPendingIncrementals(version)
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
  if RepriseHC and RepriseHC.PruneGroupAssignmentsToVersion then
    local grp = RepriseHC.PruneGroupAssignmentsToVersion(version)
    if grp and grp > 0 then removed = removed + grp end
  end
  if removed > 0 and RepriseHC and RepriseHC.RefreshUI then
    RepriseHC.RefreshUI()
  end
  return removed
end

EnsurePendingIncrementalCheck = function(version, topic, urgent)
  local target = tonumber(version) or 0
  if target <= 0 then return end
  if not C_Timer or not C_Timer.After then return end

  local reason = "pending"
  if type(topic) == "string" and topic ~= "" then
    reason = "pending-" .. topic:lower()
  end

  local delay = urgent and 1 or 5
  local attemptsKey = target

  local existing = pendingIncrementalTimers[target]
  local generation = 1
  if existing then
    if not urgent and existing.urgent then
      -- A faster timer is already queued.
      return
    end
    if not urgent and existing.delay <= delay then
      return
    end
    generation = (existing.gen or 0) + 1
  end

  pendingIncrementalTimers[target] = { gen = generation, delay = delay, urgent = urgent, topic = topic }

  if urgent and RequestFullSnapshot then
    RequestFullSnapshot(reason, true)
  end

  local function poll()
    local timerInfo = pendingIncrementalTimers[target]
    if not timerInfo or timerInfo.gen ~= generation then
      return
    end
    pendingIncrementalTimers[target] = nil

    local current = CurrentDbVersion()
    if current >= target then
      pendingIncrementalAttempts[attemptsKey] = nil
      FlushPendingIncrementals(current)
      return
    end

    local attempts = (pendingIncrementalAttempts[attemptsKey] or 0) + 1
    pendingIncrementalAttempts[attemptsKey] = attempts

    local maxAttempts = urgent and 12 or 6
    if RequestFullSnapshot then
      RequestFullSnapshot(reason, true)
    end

    if attempts < maxAttempts then
      EnsurePendingIncrementalCheck(target, topic, urgent)
    else
      pendingIncrementalAttempts[attemptsKey] = nil
    end
  end

  C_Timer.After(delay, poll)
end

local function PruneLocalDataForCurrentVersion()
  return PruneLocalDataToVersion(CurrentDbVersion())
end

local function Now()
  if GetTime then return GetTime() end
  return time()
end

local function BroadcastFullSnapshot(reason, force)
  if not (RepriseHC and RepriseHC.Comm_Send and BuildSnapshot) then return end
  local now = Now()
  if not force and (now - (lastSnapshotBroadcastAt or 0)) < 10 then return end
  lastSnapshotBroadcastAt = now
  local payload = { kind = "SNAP", data = BuildSnapshot() }
  if reason then payload.reason = reason end
  RepriseHC.Comm_Send("SNAP", payload)
end

local function RequestFullSnapshot(reason, force)
  if not (RepriseHC and RepriseHC.Comm_Send) then return end
  local now = Now()
  if not force and (now - (lastSnapshotRequestAt or 0)) < 10 then return end
  lastSnapshotRequestAt = now
  local payload = { need = "all" }
  if reason then payload.reason = reason end
  local version = CurrentDbVersion()
  if version and version > 0 then
    payload.dbVersion = version
    payload.dbv = version
  end
  RepriseHC.Comm_Send("REQSNAP", payload)
end

local function GuildSync(force, reason)
  if not IsInGuild or not IsInGuild() then return end
  local now = Now()
  if not force and (now - (lastGuildSyncAt or 0)) < 20 then return end
  lastGuildSyncAt = now
  local label = reason or "guild"
  BroadcastFullSnapshot(label, force)
  RequestFullSnapshot(label, true)
end

local function ShouldAcceptIncremental(dbv, sender)
  local incoming = tonumber(dbv) or 0
  local localVersion = CurrentDbVersion()
  if incoming == 0 then
    if localVersion ~= 0 and DebugDeathLog() then
      debugPrint("dropping payload without db version (have", localVersion, ")")
    end
    if localVersion ~= 0 and sender and SendSnapshotPayload then
      SendSnapshotPayload({ kind="SNAP", data=BuildSnapshot() }, sender)
    end
    return localVersion == 0, incoming, localVersion, "missing"
  end
  if localVersion == 0 then
    EnsureDbVersion(incoming)
    return true, incoming, CurrentDbVersion()
  end
  if incoming < localVersion then
    if DebugDeathLog() then
      debugPrint("dropping older payload", incoming, "<", localVersion)
    end
    if sender and SendSnapshotPayload then
      SendSnapshotPayload({ kind="SNAP", data=BuildSnapshot() }, sender)
    end
    return false, incoming, localVersion, "past"
  end
  if incoming > localVersion then
    if DebugDeathLog() then
      debugPrint("newer payload detected", incoming, ">", localVersion)
    end
    haveSnapshot = false

    local adopted = false
    if AdoptIncomingVersion then
      adopted = AdoptIncomingVersion(incoming)
    end

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

    if adopted then
      return true, incoming, CurrentDbVersion()
    end

    local updated = CurrentDbVersion()
    if updated == incoming then
      return true, incoming, updated
    end
    return false, incoming, updated, "future"
  end
  return true, incoming, localVersion
end

local decodeFailureLog = {}

local function TryDecodeAce(payload)
  local payloadType = type(payload)
  if payloadType ~= "string" then
    if DebugDeathLog() then
      debugPrint("AceSer deserialize skipped; payload type=", payloadType)
    end
    return nil, payloadType
  end

  local firstMarker = payload:find("%^1")
  if not firstMarker then
    if DebugDeathLog() then
      debugPrint("AceSer deserialize skipped; no ^1 marker in payload")
    end
    return nil, "no-marker"
  end

  if firstMarker > 1 then
    payload = payload:sub(firstMarker)
  end

  local function attemptDecode(str)
    local ok, success, value = pcall(AceSer.Deserialize, AceSer, str)
    return ok, success, value
  end

  local ok, success, value = attemptDecode(payload)

  if not ok or not success then
    -- If the payload looks like AceSerializer data but might be truncated, try
    -- re-attaching the terminator and decode once more before giving up.
    if payload:sub(1, 2) == "^1" and not payload:find("%^^%^") then
      ok, success, value = attemptDecode(payload .. "^^")
    end

    -- Some payloads arrive with stray leading characters (eg. embedded chat
    -- control bytes) that confuse AceSerializer. Trim to the first marker and
    -- attempt decoding again so we don't treat recoverable payloads as
    -- failures.
    if (not ok or not success) and payload:find("%^^1") then
      local start = payload:find("%^^1")
      local trimmed = payload:sub(start)
      if trimmed and trimmed ~= payload then
        if not trimmed:find("%^^%^") then
          trimmed = trimmed .. "^^"
        end
        ok, success, value = attemptDecode(trimmed)
      end
    end
  end

  if ok and success and type(value) == "table" then
    return value
  end

  local now = GetTime and GetTime() or time()
  local snippet = tostring(payload):sub(1, 80)
  local dedupeKey = snippet
  local shouldLog = true
  if dedupeKey and decodeFailureLog[dedupeKey] then
    if now - decodeFailureLog[dedupeKey] < 3 then
      shouldLog = false
    end
  end
  decodeFailureLog[dedupeKey] = now

  if DebugDeathLog() and shouldLog then
    if not ok then
      debugPrint("AceSer deserialize error; raw=", snippet, "...")
    elseif not success then
      local errText = tostring(value)
      debugPrint("AceSer deserialize rejected payload; reason=", errText, " raw=", snippet, "...")
    else
      debugPrint("AceSer deserialize failed; raw=", snippet, "...")
    end
  end

  local errSummary
  if not ok then
    errSummary = "lua-error"
  elseif not success then
    errSummary = tostring(value)
  else
    errSummary = "unknown"
  end
  return nil, errSummary
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
  db.groupAssignments = db.groupAssignments or {}

  local dbVersion = CurrentDbVersion()
  if RepriseHC and RepriseHC.PruneAchievementsToVersion then
    RepriseHC.PruneAchievementsToVersion(dbVersion)
  end
  if RepriseHC and RepriseHC.PruneDeathLogToVersion then
    RepriseHC.PruneDeathLogToVersion(dbVersion)
  end
  if RepriseHC and RepriseHC.PruneGroupAssignmentsToVersion then
    RepriseHC.PruneGroupAssignmentsToVersion(dbVersion)
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

  local groupAssignmentsCopy = {}
  local groupMinor = CurrentGroupMinor()
  for playerKey, entry in pairs(db.groupAssignments) do
    local groupName, entryVersion, when
    local entryMinor = 0
    if type(entry) == "table" then
      groupName = entry.group or entry.name or entry.value
      entryVersion = tonumber(entry.dbVersion or entry.dbv) or dbVersion
      when = tonumber(entry.when or entry.time) or 0
      entryMinor = tonumber(entry.groupVersion or entry.groupMinor or entry.gv) or AssignmentMinorFor(playerKey)
    elseif type(entry) == "string" then
      groupName = entry
      entryVersion = dbVersion ~= 0 and dbVersion or 0
      when = 0
      entryMinor = AssignmentMinorFor(playerKey)
    end
    if groupName and groupName ~= "" then
      if dbVersion == 0 or entryVersion == 0 or entryVersion == dbVersion then
        local clone = {
          group = groupName,
          when = when,
        }
        if dbVersion ~= 0 then
          clone.dbVersion = dbVersion
        else
          clone.dbVersion = entryVersion
        end
        clone.dbv = nil
        if entryMinor and entryMinor > 0 then
          clone.groupVersion = entryMinor
        elseif groupMinor and groupMinor > 0 then
          clone.groupVersion = groupMinor
        end
        groupAssignmentsCopy[playerKey] = clone
      end
    end
  end

  return {
    ver         = RepriseHC.version or "0",
    dbVersion   = dbVersion,
    characters  = charactersCopy,
    guildFirsts = guildFirstsCopy,
    deathLog    = deathLogCopy,
    groupAssignments = groupAssignmentsCopy,
    groupVersion = groupMinor,
    levelCap    = db.config.levelCap or (RepriseHC.GetLevelCap and RepriseHC.GetLevelCap()) or RepriseHC.levelCap
  }
end

function RepriseHC.Comm_BuildSnapshot()
  return BuildSnapshot()
end

function RepriseHC.Comm_BroadcastSnapshot(target)
  return SendSnapshotPayload({ kind="SNAP", data = BuildSnapshot() }, target)
end

function RepriseHC.Comm_RequestSnapshot()
  if RepriseHC.Comm_Send then
    RepriseHC.Comm_Send("REQSNAP", { need = "all" })
    return true
  end
  return false
end

function RepriseHC.Comm_SyncNow(reason)
  if not GuildSync then return false end
  GuildSync(true, reason or "manual")
  return true
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
    if payloadTable.dbVersion == nil then
      if current and current > 0 then
        payloadTable.dbVersion = current
      elseif payloadTable.data and type(payloadTable.data) == "table" then
        local dataVersion = tonumber(payloadTable.data.dbVersion or payloadTable.data.dbv)
        if dataVersion and dataVersion > 0 then
          payloadTable.dbVersion = dataVersion
        end
      end
    end
    if payloadTable.dbVersion == nil then
      payloadTable.dbVersion = 0
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

local POST_CHANGE_SNAPSHOT_MIN_INTERVAL = 5
local POST_CHANGE_SNAPSHOT_DELAY = 1.25

local function SchedulePostChangeSnapshot(reason)
  if not SendSnapshotPayload or not BuildSnapshot then return end
  local now = Now()
  if lastPostChangeSnapshotAt and (now - lastPostChangeSnapshotAt) < POST_CHANGE_SNAPSHOT_MIN_INTERVAL then
    return
  end
  lastPostChangeSnapshotAt = now

  local label = reason or "postChange"
  local function dispatch()
    local payload = { kind = "SNAP", data = BuildSnapshot(), reason = label }
    SendSnapshotPayload(payload)
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(POST_CHANGE_SNAPSHOT_DELAY, dispatch)
  else
    dispatch()
  end
end

function RepriseHC.Comm_SchedulePostChangeSnapshot(reason)
  SchedulePostChangeSnapshot(reason)
end

local lastResetSentTo = {}

MaybeSendTargetedSnapshot = function(name, reason)
  if not name or name == "" then return end
  if IsSelf(name) then return end

  local short = CanonicalShort(name)
  if short == "" then return end

  local now = Now()
  local previous = targetedSnapshotSentAt[short] or 0
  if now - previous < TARGETED_SNAPSHOT_MIN_INTERVAL then return end

  targetedSnapshotSentAt[short] = now

  local function doSend()
    local payload = { kind = "SNAP", data = BuildSnapshot() }
    if reason then payload.reason = reason end
    local ok = SendSnapshotPayload(payload, name)
    if not ok then
      targetedSnapshotSentAt[short] = previous
    end
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(0.5, doSend)
  else
    doSend()
  end
end

local function UpdateRosterSnapshots()
  if not IsInGuild or not IsInGuild() then
    if knownOnlineGuildmates then
      wipe(knownOnlineGuildmates)
    end
    return
  end

  local count = GetNumGuildMembers and GetNumGuildMembers() or 0
  if count <= 0 then return end

  local now = Now()
  local seen = {}

  for i = 1, count do
    local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
    if name then
      local short = CanonicalShort(name)
      if short ~= "" then
        seen[short] = online and name or false
        if online and not IsSelf(name) then
          local lastSent = targetedSnapshotSentAt[short] or 0
          if not knownOnlineGuildmates[short] then
            MaybeSendTargetedSnapshot(name, "rosterNew")
          elseif now - lastSent > TARGETED_SNAPSHOT_REFRESH then
            MaybeSendTargetedSnapshot(name, "rosterRefresh")
          end
          knownOnlineGuildmates[short] = name
        end
      end
    end
  end

  for short in pairs(knownOnlineGuildmates) do
    local state = seen[short]
    if not state or state == false then
      knownOnlineGuildmates[short] = nil
      targetedSnapshotSentAt[short] = nil
    end
  end
end

local function ResetDbTablesToVersion(target)
  local db = SafeDB()
  db.characters = {}
  db.guildFirsts = {}
  db.deathLog = {}
  db.groupAssignments = {}
  db.config = db.config or {}
  db.config.dbVersion = target
  db.config.groupMinorVersion = 0
  db.config.groupAssignmentMinor = {}
end

AdoptIncomingVersion = function(version)
  local target = tonumber(version) or 0
  if not target or target <= 0 then return false end

  local current = CurrentDbVersion()
  if current >= target then
    return current == target
  end

  local notice = "|cffff8800New database version detected. Syncing...|r"

  if RepriseHC and RepriseHC._HardResetDB then
    RepriseHC._HardResetDB(notice, target, { skipRefresh = true })
  else
    ResetDbTablesToVersion(target)
    if RepriseHC and RepriseHC.Print then
      RepriseHC.Print(notice)
    end
  end

  EnsureDbVersion(target)

  if lastResetSentTo then
    if wipe then
      wipe(lastResetSentTo)
    else
      lastResetSentTo = {}
    end
  end

  haveSnapshot = false

  if RepriseHC and RepriseHC.RefreshUI then
    RepriseHC.RefreshUI()
  end

  if RepriseHC then
    RepriseHC._LastResetDbVersion = target
    RepriseHC._LastResetStamp = RepriseHC._LastResetStamp or ((GetServerTime and GetServerTime()) or time())
  end

  return CurrentDbVersion() >= target
end

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
  local incomingGroupMinor = tonumber(p.groupVersion or p.groupMinorVersion or p.groupMinor or p.gv) or 0
  local localGroupMinor = CurrentGroupMinor()

  if incomingVersion == 0 then
    if localVersion ~= 0 then
      if DebugDeathLog() then debugPrint("snapshot rejected (missing version)") end
      return
    end
  elseif localVersion == 0 then
    EnsureDbVersion(incomingVersion)
    localVersion = incomingVersion
  elseif incomingVersion < localVersion then
    if DebugDeathLog() then
      debugPrint("snapshot rejected (older version)", incomingVersion, "<", localVersion)
    end
    return
  elseif incomingVersion > localVersion then
    if DebugDeathLog() then
      debugPrint("snapshot adopting newer version", incomingVersion)
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

  if incomingGroupMinor > 0 then
    if incomingGroupMinor > localGroupMinor then
      if RepriseHC and RepriseHC.SetGroupMinorVersion then
        RepriseHC.SetGroupMinorVersion(incomingGroupMinor)
      else
        db.config.groupMinorVersion = incomingGroupMinor
      end
      localGroupMinor = incomingGroupMinor
    elseif db.config.groupMinorVersion == nil then
      db.config.groupMinorVersion = incomingGroupMinor
    end
  elseif db.config.groupMinorVersion == nil then
    db.config.groupMinorVersion = localGroupMinor
  end

  PruneLocalDataToVersion(localVersion)

  local groupAssignmentsChanged = false

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

  local guildFirstsToResolve = {}
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
          guildFirstsToResolve[id] = true
        else
          guildFirstsToResolve[id] = guildFirstsToResolve[id] or true
        end
      end
    end
  end

  if RepriseHC and RepriseHC.ResolveGuildFirstConflicts then
    for id in pairs(guildFirstsToResolve) do
      RepriseHC.ResolveGuildFirstConflicts(id)
    end
  end

  for playerKey, info in pairs(p.groupAssignments or {}) do
    local groupName, entryVersion, when = nil, localVersion, 0
    local entryMinor = incomingGroupMinor
    if type(info) == "table" then
      groupName = info.group or info.name or info.value
      entryVersion = tonumber(info.dbVersion or info.dbv) or localVersion
      when = tonumber(info.when or info.time) or 0
      local m = tonumber(info.groupVersion or info.groupMinor or info.gv)
      if m and m > 0 then entryMinor = m end
    elseif type(info) == "string" then
      groupName = info
      entryVersion = localVersion
      when = 0
    end

    if groupName and groupName ~= "" then
      if localVersion == 0 or entryVersion == 0 or entryVersion == localVersion then
        if RepriseHC and RepriseHC.UpdateGroupAssignment then
          local changedNow = RepriseHC.UpdateGroupAssignment(playerKey, groupName, {
            when = when,
            dbVersion = (localVersion ~= 0 and localVersion or entryVersion),
            groupVersion = entryMinor,
          })
          if changedNow then groupAssignmentsChanged = true end
        else
          local versionToUse = localVersion ~= 0 and localVersion or entryVersion
          db.groupAssignments[playerKey] = {
            group = groupName,
            when = when,
            dbVersion = versionToUse,
            groupVersion = entryMinor,
          }
          db.groupAssignments[playerKey].dbv = nil
          if entryMinor and entryMinor > 0 then
            db.config = db.config or {}
            local currentMinor = tonumber(db.config.groupMinorVersion) or 0
            if entryMinor > currentMinor then
              db.config.groupMinorVersion = entryMinor
            end
            RememberAssignmentMinor(playerKey, entryMinor)
          end
          groupAssignmentsChanged = true
        end
      end
    else
      if RepriseHC and RepriseHC.UpdateGroupAssignment then
        local changedNow = RepriseHC.UpdateGroupAssignment(playerKey, nil, { groupVersion = entryMinor })
        if changedNow then groupAssignmentsChanged = true end
      else
        if db.groupAssignments[playerKey] ~= nil then
          db.groupAssignments[playerKey] = nil
          groupAssignmentsChanged = true
        end
        if entryMinor and entryMinor > 0 then
          db.config = db.config or {}
          local currentMinor = tonumber(db.config.groupMinorVersion) or 0
          if entryMinor > currentMinor then
            db.config.groupMinorVersion = entryMinor
          end
          RememberAssignmentMinor(playerKey, entryMinor)
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

    local staged, stagedByNorm, stagedByFallback = {}, {}, {}
    local providedGlobalCopyAlias = false
    if rawget(_G, "copy") == nil then
      _G.copy = stagedByNorm
      providedGlobalCopyAlias = true
    end

    local function releaseCopyAlias()
      if providedGlobalCopyAlias then
        _G.copy = nil
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
        local fb = fallbackKey(entry)
        if fb then
          stagedByFallback[fb] = entry
        end
      end
    end

    if #staged > 0 then
      table.sort(staged, function(a, b)
        return (a.when or 0) < (b.when or 0)
      end)

      local seenByNorm, seenByFallback = {}, {}

      local function remember(entry)
        if not entry then return end
        if localVersion ~= 0 then
          entry.dbVersion = localVersion
        else
          entry.dbVersion = tonumber(entry.dbVersion or entry.dbv) or 0
        end
        entry.dbv = nil
        local norm = normalizeEntryKey(entry)
        if norm ~= "" then
          seenByNorm[norm] = entry
        end
        local fb = fallbackKey(entry)
        if fb then
          seenByFallback[fb] = entry
        end
      end

      local function applyInto(dest, src)
        if not dest or not src then return end
        for k, v in pairs(src) do
          if v ~= nil and v ~= "" then
            dest[k] = v
          end
        end
        if localVersion ~= 0 then
          dest.dbVersion = localVersion
        end
        dest.dbv = nil
        remember(dest)
      end

      for _, existing in ipairs(db.deathLog) do
        remember(existing)
      end

      for _, entry in ipairs(staged) do
        local dest
        local norm = normalizeEntryKey(entry)
        if norm ~= "" then
          dest = seenByNorm[norm]
        end
        if not dest then
          local fb = fallbackKey(entry)
          if fb then dest = seenByFallback[fb] end
        end

        if dest then
          applyInto(dest, entry)
        else
          local cloned = shallowCopy(entry)
          if cloned then
            table.insert(db.deathLog, cloned)
            remember(cloned)
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

      if myNormKey and myNormKey ~= "" and not seenByNorm[myNormKey] then
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
          local cloned = shallowCopy(match)
          if cloned then
            table.insert(db.deathLog, cloned)
            remember(cloned)
          end
        end
      end

      table.sort(db.deathLog, function(a, b)
        return (a.when or 0) < (b.when or 0)
      end)
    end

    if groupAssignmentsChanged and RepriseHC and RepriseHC.RefreshUI then
      RepriseHC.RefreshUI()
    end
    releaseCopyAlias()
end

-- -------- RX dedupe by sender sequence --------
local lastSeqBySender = {} -- [sender] = { seq = <lastQ>, ts = <last server ts>, seenAt = <GetTime()> }
local function IsDup(sender, q, ts)
  if not sender or sender == "" then return false end
  if (q or 0) <= 0 then return false end

  local now = (GetTime and GetTime()) or time()
  ts = tonumber(ts) or 0

  local info = lastSeqBySender[sender]
  if info and info.seenAt and (now - info.seenAt) > 300 then
    info = nil
    lastSeqBySender[sender] = nil
  end

  if not info then
    lastSeqBySender[sender] = { seq = q, ts = ts, seenAt = now }
    return false
  end

  local lastSeq = tonumber(info.seq) or 0
  local lastTs = tonumber(info.ts) or 0

  if ts > 0 and ts > lastTs then
    info.seq, info.ts, info.seenAt = q, ts, now
    return false
  end

  if q > lastSeq then
    info.seq = q
    if ts >= lastTs then info.ts = ts end
    info.seenAt = now
    return false
  end

  if (now - (info.seenAt or 0)) > 30 then
    info.seq, info.ts, info.seenAt = q, (ts > 0 and ts or lastTs), now
    return false
  end

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

local function ApplyAchievementPayload(p, sender)
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

  local hadAchievement = c.achievements[p.id] ~= nil

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

  if not hadAchievement then
    local selfKey
    if RepriseHC and RepriseHC.GetPlayerKey then
      selfKey = RepriseHC.GetPlayerKey()
    elseif RepriseHC and RepriseHC.PlayerKey then
      selfKey = RepriseHC.PlayerKey()
    end

    if selfKey and CanonicalShort(selfKey) == CanonicalShort(p.playerKey) then
      if RepriseHC and RepriseHC.ShowAchievementToast then
        RepriseHC.ShowAchievementToast(p.name or p.id, points)
      end
    end
  end

  if p.id and p.id:find("^FIRST_" .. ((RepriseHC.GetLevelCap and RepriseHC.GetLevelCap()) or (RepriseHC.levelCap or 60))) then
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

    if RepriseHC and RepriseHC.ResolveGuildFirstConflicts then
      RepriseHC.ResolveGuildFirstConflicts(p.id)
    end
  end

  if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
end

local function ApplyDeathPayload(p, sender, sid)
  normalizeKeyAndName(p, sender)

  local function normalizeForCompare(key)
    return (key or ""):lower():gsub("%-.*$", "")
  end

  local seen = false
  local incomingNorm = normalizeForCompare(p.playerKey or p.name)

  for _, d in ipairs(RepriseHC.GetDeathLog()) do
    if normalizeForCompare(d.playerKey or d.name) == incomingNorm then
      seen = true
      break
    end
  end

  if seen then
    if DebugDeathLog() then debugPrint("DEATH already logged for", p.playerKey, "— skipping") end
    return
  end

  local eventWhen = tonumber(p.when) or tonumber(p.time) or time()
  eventWhen = eventWhen > 0 and math.floor(eventWhen) or time()
  local entryVersion = tonumber(p.dbVersion or p.dbv) or CurrentDbVersion()
  table.insert(RepriseHC.GetDeathLog(), {
    playerKey=p.playerKey or p.name, name=p.name, level=p.level, class=p.class, race=p.race,
    zone=p.zone, subzone=p.subzone, when=eventWhen, dbVersion=entryVersion
  })

  if DebugDeathLog() then debugPrint("DEATH inserted for", p.playerKey or p.name or "?") end

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
end

local function ApplyGroupPayload(p, sender)
  normalizeKeyAndName(p, sender)

  local rawGroup = p.group or p.groupName or p.value or p.assignment
  if type(rawGroup) == "string" then
    rawGroup = rawGroup:gsub("^%s+", ""):gsub("%s+$", "")
    if rawGroup == "" then rawGroup = nil end
  else
    rawGroup = nil
  end

  local when = tonumber(p.when or p.time) or time()
  local incomingVersion = tonumber(p.dbVersion or p.dbv) or CurrentDbVersion()
  if incomingVersion < 0 then incomingVersion = 0 end
  local incomingGroupVersion = tonumber(p.groupVersion or p.groupMinor or p.gv) or 0
  if incomingGroupVersion < 0 then incomingGroupVersion = 0 end

  local changed = false
  local db = SafeDB()
  db.groupAssignments = db.groupAssignments or {}

  if rawGroup then
    if RepriseHC and RepriseHC.UpdateGroupAssignment then
      changed = RepriseHC.UpdateGroupAssignment(p.playerKey, rawGroup, {
        when = when,
        dbVersion = incomingVersion ~= 0 and incomingVersion or nil,
        groupVersion = incomingGroupVersion,
      })
    else
      db.groupAssignments[p.playerKey] = {
        group = rawGroup,
        when = when,
        dbVersion = incomingVersion,
        groupVersion = incomingGroupVersion,
      }
      db.groupAssignments[p.playerKey].dbv = nil
      if incomingGroupVersion and incomingGroupVersion > 0 then
        db.config = db.config or {}
        local currentMinor = tonumber(db.config.groupMinorVersion) or 0
        if incomingGroupVersion > currentMinor then
          db.config.groupMinorVersion = incomingGroupVersion
        end
        RememberAssignmentMinor(p.playerKey, incomingGroupVersion)
      end
      changed = true
    end
  else
    if RepriseHC and RepriseHC.UpdateGroupAssignment then
      changed = RepriseHC.UpdateGroupAssignment(p.playerKey, nil, { groupVersion = incomingGroupVersion })
    else
      if db.groupAssignments[p.playerKey] ~= nil then
        db.groupAssignments[p.playerKey] = nil
        changed = true
      end
      if incomingGroupVersion and incomingGroupVersion > 0 then
        db.config = db.config or {}
        local currentMinor = tonumber(db.config.groupMinorVersion) or 0
        if incomingGroupVersion > currentMinor then
          db.config.groupMinorVersion = incomingGroupVersion
        end
        RememberAssignmentMinor(p.playerKey, incomingGroupVersion)
      end
    end
  end

  if changed and RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
end

local lastDecodeSnapshotRequestAt = 0

local function HandleIncoming(prefix, payload, channel, sender)

  if DebugDeathLog() then
    debugPrint("RX", "prefix=", prefix, "dist=", channel, "from=", sender, "len=", #tostring(payload or ""))
  end

  if prefix ~= PREFIX then return end
  local t, decodeErr = TryDecodeAce(payload); if not t then t = TryDecodeLegacy(payload) end
  if not t then
    if DebugDeathLog() then
      debugPrint("decode failed; dropping. prefix=", prefix, "from=", sender, "err=", decodeErr)
    end
    if sender and MaybeSendTargetedSnapshot then
      MaybeSendTargetedSnapshot(sender, "decode-failed")
    end
    local now = GetTime and GetTime() or time()
    if RequestFullSnapshot and (now - lastDecodeSnapshotRequestAt) > 6 then
      lastDecodeSnapshotRequestAt = now
      RequestFullSnapshot("decode-failed", true)
    end
    return
  end
  if t.v ~= 1 then
    if DebugDeathLog() then debugPrint("bad version", tostring(t.v)) end
    return
  end

  local sid, q = t.s or sender or "?", t.q or 0
  if IsDup(sid, q, t.ts) then return end

  local p, topic = t.p or {}, t.t

  if topic == "ACH" then
    local accept, incomingVersion, _, reason = ShouldAcceptIncremental(p.dbv, sender)
    if not accept then
      if reason == "future" then
        QueuePendingIncremental(incomingVersion, { topic = "ACH", payload = DeepCopy(p) }, sender, sid, channel, q, t.ts)
      end
      return
    end
    ApplyAchievementPayload(p, sender)


  elseif topic == "DEATH" then
    if DebugDeathLog() then
      local age = nil
      local when = tonumber(p.when or p.time)
      if when then
        age = (time() - math.floor(when))
        if age < 0 then age = 0 end
      end
      debugPrint("DEATH payload rx from", sender or sid or "?", "age=", age, "dbv=", p.dbv or p.dbVersion or "?")
    end

    local incomingVersion = tonumber(p.dbv or p.dbVersion) or 0
    if incomingVersion == 0 then
      incomingVersion = CurrentDbVersion()
      p.dbv = incomingVersion
      p.dbVersion = incomingVersion
      if DebugDeathLog() then
        debugPrint("DEATH payload missing dbv — defaulting to", incomingVersion)
      end
    end

    local localVersion = CurrentDbVersion()
    if incomingVersion > localVersion then
      EnsureDbVersion(incomingVersion)
      localVersion = incomingVersion
      if DebugDeathLog() then
        debugPrint("DEATH payload advanced local db version to", incomingVersion)
      end
    end

    if incomingVersion < localVersion then
      incomingVersion = localVersion
      p.dbv = localVersion
      p.dbVersion = localVersion
      if DebugDeathLog() then
        debugPrint("DEATH payload normalized to current db version", localVersion)
      end
    end

    -- Always apply deaths immediately after normalizing versions; do not queue.
    if DebugDeathLog() then
      debugPrint(
        "DEATH payload accepted from", sender or sid or "?", "when=", p.when or p.time or "?", "channel=", channel or "?"
      )
    end
    ApplyDeathPayload(p, sender, sid)


  elseif topic == "GROUP" then
    local accept, incomingVersion, _, reason = ShouldAcceptIncremental(p.dbv, sender)
    if not accept then
      if reason == "future" then
        QueuePendingIncremental(incomingVersion, { topic = "GROUP", payload = DeepCopy(p) }, sender, sid, channel, q, t.ts)
      end
      return
    end
    ApplyGroupPayload(p, sender)


  elseif topic == "RESET" then
    local sig = tonumber(p.sig)
    local expected = RepriseHC._ResetSignature
    if not sig or not expected or sig ~= expected then
      if DebugDeathLog() then
        debugPrint("reset ignored (bad signature)")
      end
      return
    end

    local stamp = tonumber(p.stamp) or 0
    local dbVersion = tonumber(p.dbv) or tonumber(p.dbVersion) or 0

    local currentVersion = CurrentDbVersion()
    if dbVersion > 0 and currentVersion >= dbVersion and RepriseHC and RepriseHC._LastResetDbVersion == dbVersion then
      if stamp ~= 0 then
        RepriseHC._LastResetStamp = stamp
      else
        RepriseHC._LastResetStamp = RepriseHC._LastResetStamp or ((GetServerTime and GetServerTime()) or time())
      end
      if DebugDeathLog() then debugPrint("reset ignored (version already adopted)") end
      return
    end

    if stamp ~= 0 then
      if RepriseHC._LastResetStamp and stamp == RepriseHC._LastResetStamp then
        if DebugDeathLog() then debugPrint("reset echo ignored") end
        return
      end
      if lastResetStamp and stamp == lastResetStamp then
        return
      end
      lastResetStamp = stamp
    else
      if dbVersion > 0 and RepriseHC._LastResetDbVersion and RepriseHC._LastResetDbVersion == dbVersion then
        if DebugDeathLog() then debugPrint("duplicate reset version ignored") end
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
    if RepriseHC.Print and DebugDeathLog() then RepriseHC.Print("Synchronized snapshot.") end
    if RepriseHC.RefreshUI then RepriseHC.RefreshUI() end
  end
end

ProcessPendingIncrementalEntry = function(entry)
  if type(entry) ~= "table" then return end
  local msg = entry.message
  if type(msg) ~= "table" then return end
  local payload = msg.payload
  local topic = msg.topic
  if type(payload) ~= "table" or type(topic) ~= "string" then return end

  local clone = DeepCopy(payload)
  if topic == "ACH" then
    ApplyAchievementPayload(clone, entry.sender)
  elseif topic == "DEATH" then
    if DebugDeathLog() then
      debugPrint("Processing queued DEATH payload from", entry.sender or "?", "seq=", entry.seq or "?", "ts=", entry.ts or "?")
    end
    ApplyDeathPayload(clone, entry.sender, entry.sid)
  elseif topic == "GROUP" then
    ApplyGroupPayload(clone, entry.sender)
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

  if topic == "DEATH" and DebugDeathLog() then
    debugPrint(
      "Comm_Send(DEATH): guild=", usedGuild, "group=", usedGroup,
      "snapshotVersion=", CurrentDbVersion()
    )
  end

  if topic ~= "DEATH" and not usedGuild and not usedGroup then
    local peers = 6
    if topic == "REQSNAP" then
      peers = 4
    elseif topic == "GROUP" then
      peers = 5
    end
    SendWhisperFallback(wire, peers)
  end

  if topic == "ACH" or topic == "GROUP" then
    SchedulePostChangeSnapshot(topic)

    -- Even when the guild route succeeds, follow up with a handful of
    -- whispers so peers that haven't finished joining guild chat yet still
    -- receive the incremental payload.
    local peerCount = (topic == "GROUP") and 8 or 6
    SendWhisperFallback(wire, peerCount)

    -- Death announcements resend small snapshots a few seconds later which is
    -- why they recover so reliably after reloads.  Mirror that behaviour for
    -- achievements and group changes so the refreshed standings propagate
    -- without requiring a manual /reload.
    if C_Timer and C_Timer.After then
      C_Timer.After(6, SendSmallSnapshot)
      C_Timer.After(18, SendSmallSnapshot)
    else
      SendSmallSnapshot()
    end
  end

  if topic == "DEATH" then
    local delivered = usedGuild or usedGroup
    -- Try the direct 1:1 path first (when only 2 online)
    if DebugDeathLog() then
      debugPrint("Comm_Send(DEATH): trying direct send to online peer")
    end
    local didDirect = SendDirectToOtherOnline(wire)
    if DebugDeathLog() then
      debugPrint("Comm_Send(DEATH): direct path", didDirect and "hit" or "skipped", "— whisper fan-out next")
    end

    delivered = delivered or didDirect

    -- Also do the regular fan-out (covers >2 online)
    local fanoutSent = SendWhisperFallback(wire, 12)
    if DebugDeathLog() then
      debugPrint("Comm_Send(DEATH): whisper fan-out sent to 12 peers")
    end

    delivered = delivered or fanoutSent

    if not delivered and C_Timer and C_Timer.After then
      C_Timer.After(2, function()
        local retriedGuild = SendViaGuild(wire)
        local retriedGroup = not retriedGuild and SendViaGroup(wire)
        local retriedFanout = SendWhisperFallback(wire, 12)
        if DebugDeathLog() then
          debugPrint(
            "Comm_Send(DEATH): retry (2s) guild=", retriedGuild, "group=", retriedGroup, "fanout=", retriedFanout
          )
        end
      end)
    end

    -- Late resend for good measure
    local late = wire
    C_Timer.After(25, function()
      local ok = SendViaGuild(late)
      if not ok then ok = SendViaGroup(late) end
      SendWhisperFallback(late, 12)
      if DebugDeathLog() then
        debugPrint("Comm_Send(DEATH): late resend executed — guild=", ok, "+ whispers")
      end
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
F:RegisterEvent("PLAYER_LOGIN")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("PLAYER_GUILD_UPDATE")
F:RegisterEvent("GUILD_ROSTER_UPDATE")

local function requestWithBackoff()
  if haveSnapshot then return end
  RequestFullSnapshot("login", true)
end

local wasInGuild

F:SetScript("OnEvent", function(_, ev)
  if ev == "PLAYER_LOGIN" then
    if knownOnlineGuildmates then
      wipe(knownOnlineGuildmates)
    end
    UpdateRosterSnapshots()

  elseif ev == "PLAYER_ENTERING_WORLD" then
    PruneLocalDataForCurrentVersion()
    haveSnapshot = false
    C_Timer.After(5,  requestWithBackoff)
    C_Timer.After(15, requestWithBackoff)
    C_Timer.After(30, requestWithBackoff)

    local function periodic()
      BroadcastFullSnapshot("periodic", true)
      C_Timer.After(5, function()
        RequestFullSnapshot("periodic", true)
      end)
      C_Timer.After(PERIODIC_SYNC_INTERVAL, periodic)
    end
    C_Timer.After(20, periodic)
    C_Timer.After(10, UpdateRosterSnapshots)

  elseif ev == "PLAYER_GUILD_UPDATE" or ev == "GUILD_ROSTER_UPDATE" then
    local inGuild = IsInGuild and IsInGuild()
    if wasInGuild == nil then wasInGuild = inGuild end
    if inGuild then
      local force = not wasInGuild
      GuildSync(force, force and "joinedGuild" or "guildUpdate")
      UpdateRosterSnapshots()
    else
      if knownOnlineGuildmates then
        wipe(knownOnlineGuildmates)
      end
    end
    wasInGuild = inGuild
    if not haveSnapshot then C_Timer.After(2, requestWithBackoff) end
  end
end)

-- -------- AceComm receiver registration --------
RepriseHC:UnregisterComm(PREFIX)  -- safe if not registered yet
RepriseHC:RegisterComm(PREFIX, function(prefix, msg, dist, sender)
  HandleIncoming(prefix, msg, dist, sender)
end)
