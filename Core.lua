RepriseHC = RepriseHC or {}
RepriseHC.name = "RepriseHC"
RepriseHC.version = "0.2.0a"
RepriseHC.allowedGuilds = { ["Reprise"] = true, ["RepriseHC"] = true, ["Frontier"] = true, ["Midnight Guardians"] = true }

local DEFAULT_DB_VERSION = 1

RepriseHC.levelCap = 20
RepriseHC.levels = {10,20,30,40,50,60}
local function EnsureLevelMilestones()
  local cap = tonumber(RepriseHC.levelCap) or 0
  if cap <= 0 then return end
  local found = false
  for _, threshold in ipairs(RepriseHC.levels) do
    if threshold == cap then
      found = true
      break
    end
  end
  if not found then
    table.insert(RepriseHC.levels, cap)
    table.sort(RepriseHC.levels)
  end
end
EnsureLevelMilestones()
RepriseHC.showToGuild = true
RepriseHC.runtime = RepriseHC.runtime or {}
RepriseHC.defaultDbVersion = DEFAULT_DB_VERSION
RepriseHC.AchievementTesting = false

RepriseHC.speedrunThresholds = {
  [10] = 2,
  [20] = 12,
  [30] = 27,
  [40] = 50,
  [50] = 81,
  [60] = 120,
}

RepriseHC.class = {
  WARRIOR = { name="Warrior" },
  ROGUE   = { name="Rogue" },
  MAGE    = { name="Mage" },
  HUNTER  = { name="Hunter" },
  WARLOCK = { name="Warlock" },
  PRIEST  = { name="Priest" },
  PALADIN = { name="Paladin", faction="Alliance" },
  DRUID   = { name="Druid" },
  SHAMAN  = { name="Shaman", faction="Horde" },
}

RepriseHC.race  = {
  Human     = { name="Human",     faction="Alliance" },
  Gnome     = { name="Gnome",     faction="Alliance" },
  Dwarf     = { name="Dwarf",     faction="Alliance" },
  ["Night Elf"] = { name="Night Elf", faction="Alliance" },
  NightElf  = { name="Night Elf", faction="Alliance" },
  Orc       = { name="Orc",       faction="Horde" },
  Troll     = { name="Troll",     faction="Horde" },
  Scourge   = { name="Undead",    faction="Horde" },
  Undead    = { name="Undead",    faction="Horde" },
  Tauren    = { name="Tauren",    faction="Horde" },
}

RepriseHC.professions = {
  ["Alchemy"]=true,
  ["Blacksmithing"]=true,
  ["Leatherworking"]=true,
  ["Tailoring"]=true,
  ["Engineering"]=true,
  ["Enchanting"]=true,
  ["Herbalism"]=true,
  ["Mining"]=true,
  ["Skinning"]=true,
  ["Cooking"]=true,
  ["First Aid"]=true,
  ["Fishing"]=true,
}

RepriseHC.profThreshold = {
  { levelRequirement = 5,  threshold = 75 },
  { levelRequirement = 10, threshold = 150 },
  { levelRequirement = 20, threshold = 225 },
  { levelRequirement = 35, threshold = 300 },
}

RepriseHC.navigation = {
  leaderboard = { label="Leaderboard", enabled=true },
  standing    = { label="Group Standings", enabled=true},
  level       = { label="Level Milestones", enabled=true },
  speedrun    = { label="Speedrun", enabled=true },
  quest       = { label="Quest Milestones", enabled=true },
  prof        = { label="Professions", enabled=true },
  dungeons    = { label="Dungeons", enabled=true },
  guildFirst  = { label="Guild First", enabled=true },
  deathlog    = { label="Death Log", enabled=true },
}

RepriseHC.navigationOrder = {
  "leaderboard",
  "standing",
  "level",
  "speedrun",
  "quest",
  "prof",
  "dungeons",
  "guildFirst",
  "deathlog",
}

local Core = CreateFrame("Frame", "RepriseHC_Core")
Core:RegisterEvent("ADDON_LOADED")
Core:RegisterEvent("PLAYER_LOGIN")

function RepriseHC.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff00c0ffRepriseHC:|r " .. (msg or ""))
end

local RESET_SALT = "RepriseHC_ResetSalt_v1"
local RESET_HASH_BASE = 131
local RESET_HASH_MOD  = 2147483647
local RESET_SIGNATURE = 1740334091

RepriseHC._ResetSignature = RESET_SIGNATURE

local function ComputeBattleTagHash(tag)
  if not tag or tag == "" then return nil end
  local acc = 0
  local source = RESET_SALT .. "::" .. tag
  for i = 1, #source do
    acc = (acc * RESET_HASH_BASE + source:byte(i)) % RESET_HASH_MOD
  end
  return acc
end

local function GetPlayerBattleTag()
  if not BNGetInfo then return nil end
  local displayName, battleTag = BNGetInfo()
  if type(battleTag) == "string" and battleTag ~= "" then
    return battleTag
  end
  if type(displayName) == "string" and displayName:find("#", 1, true) then
    return displayName
  end
  return nil
end

function RepriseHC.GetPlayerKey()
  local name, realm = UnitName("player")
  realm = realm or GetRealmName()
  return string.format("%s-%s", name or "", realm or "")
end

function RepriseHC.IsGuildAllowed()
  local g = GetGuildInfo("player")
  -- if not g then
  --   return true
  -- end
  return not not RepriseHC.allowedGuilds[g]
end

function RepriseHC.GetLevelCap()
  return RepriseHC.levelCap or 60
end

function RepriseHC.GetShowToGuild()
  return RepriseHC.showToGuild or false
end

function RepriseHC.MaxMilestone()
  local cap = RepriseHC.levelCap or 60
  return math.floor(math.max(0, cap) / 10) * 10
end

function RepriseHC.ClassName(eclass)
  local v = RepriseHC.class[eclass or ""]
  if type(v) == "table" then return v.name end
  return v or eclass or "Class"
end

function RepriseHC.RaceName(erace)
  local v = RepriseHC.race[erace or ""]
  if type(v) == "table" then return v.name end
  return v or erace or "Race"
end

function RepriseHC.GetSelectedGroupKey()
  local cfg = RepriseHCAchievementsDB and RepriseHCAchievementsDB.config
  if cfg and cfg.selectedGroupKey ~= nil then
    return cfg.selectedGroupKey
  end
  return RepriseHC.runtime.groupKey
end

function RepriseHC.SetSelectedGroupKey(key)
  RepriseHCAchievementsDB = RepriseHCAchievementsDB or {}
  RepriseHCAchievementsDB.config = RepriseHCAchievementsDB.config or {}
  RepriseHCAchievementsDB.config.selectedGroupKey = key
  RepriseHC.runtime.groupKey = key
end

local function EnsureDb()
  RepriseHCAchievementsDB = RepriseHCAchievementsDB or {}
  RepriseHCAchievementsDB.characters = RepriseHCAchievementsDB.characters or {}
  RepriseHCAchievementsDB.guildFirsts = RepriseHCAchievementsDB.guildFirsts or {}
  RepriseHCAchievementsDB.deathLog = RepriseHCAchievementsDB.deathLog or {}
  RepriseHCAchievementsDB.groupAssignments = RepriseHCAchievementsDB.groupAssignments or {}
  RepriseHCAchievementsDB.config = RepriseHCAchievementsDB.config or {}
  if RepriseHCAchievementsDB.config.dbVersion == nil then
    RepriseHCAchievementsDB.config.dbVersion = DEFAULT_DB_VERSION
  elseif RepriseHCAchievementsDB.config.dbVersion > 0 and RepriseHCAchievementsDB.config.dbVersion < DEFAULT_DB_VERSION then
    RepriseHCAchievementsDB.config.dbVersion = DEFAULT_DB_VERSION
  end
  if RepriseHCAchievementsDB.config.groupMinorVersion == nil then
    RepriseHCAchievementsDB.config.groupMinorVersion = 0
  end
  if type(RepriseHCAchievementsDB.config.groupAssignmentMinor) ~= "table" then
    RepriseHCAchievementsDB.config.groupAssignmentMinor = {}
  end
  return RepriseHCAchievementsDB
end

function RepriseHC.DB()
  return EnsureDb()
end

local function ExtractGroupAssignment(value)
  if type(value) == "table" then
    local group = value.group or value.name or value.value
    if not group or group == "" then return nil end
    local when = tonumber(value.when or value.time) or 0
    local version = tonumber(value.dbVersion or value.dbv) or 0
    return group, version, when
  elseif type(value) == "string" then
    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil end
    return trimmed, 0, 0
  end
  return nil
end

function RepriseHC.PruneGroupAssignmentsToVersion(version)
  local db = EnsureDb()
  local assignments = db.groupAssignments
  if not assignments then return 0 end

  local targetVersion = tonumber(version) or 0
  local removed = 0
  local cfg = db.config or {}
  cfg.groupAssignmentMinor = cfg.groupAssignmentMinor or {}
  local minorByPlayer = cfg.groupAssignmentMinor

  for key, value in pairs(assignments) do
    local group, entryVersion, when = ExtractGroupAssignment(value)
    local entryMinor = 0
    if type(value) == "table" then
      entryMinor = tonumber(value.groupVersion or value.groupMinor or value.gv) or 0
    end
    if not group then
      assignments[key] = nil
      minorByPlayer[key] = nil
      removed = removed + 1
    else
      if targetVersion ~= 0 then
        if entryVersion ~= 0 and entryVersion ~= targetVersion then
          assignments[key] = nil
          minorByPlayer[key] = nil
          removed = removed + 1
        else
          assignments[key] = {
            group = group,
            when = when,
            dbVersion = targetVersion,
            groupVersion = entryMinor,
          }
          assignments[key].dbv = nil
          assignments[key].gv = nil
          minorByPlayer[key] = entryMinor
        end
      else
        assignments[key] = {
          group = group,
          when = when,
          dbVersion = entryVersion >= 0 and entryVersion or 0,
          groupVersion = entryMinor,
        }
        assignments[key].dbv = nil
        assignments[key].gv = nil
        minorByPlayer[key] = entryMinor
      end
      local entry = assignments[key]
      if entry then entry.dbv = nil end
    end
  end

  return removed
end

local function CurrentGroupMinorVersion()
  local db = EnsureDb()
  local value = tonumber(db.config.groupMinorVersion) or 0
  if value < 0 then value = 0 end
  db.config.groupMinorVersion = value
  return value
end

function RepriseHC.GetGroupMinorVersion()
  return CurrentGroupMinorVersion()
end

function RepriseHC.SetGroupMinorVersion(ver)
  local value = tonumber(ver) or 0
  if value < 0 then value = 0 end
  value = math.floor(value)
  local db = EnsureDb()
  db.config.groupMinorVersion = value
  return value
end

function RepriseHC.BumpGroupMinorVersion()
  local current = CurrentGroupMinorVersion()
  return RepriseHC.SetGroupMinorVersion(current + 1)
end

local function GetAssignmentMinor(playerKey)
  if not playerKey then return 0 end
  local db = EnsureDb()
  local map = db.config.groupAssignmentMinor or {}
  return tonumber(map[playerKey]) or 0
end

local function RememberAssignmentMinor(playerKey, minor)
  if not playerKey then return end
  local value = tonumber(minor) or 0
  if value < 0 then value = 0 end
  value = math.floor(value)
  local db = EnsureDb()
  db.config.groupAssignmentMinor = db.config.groupAssignmentMinor or {}
  db.config.groupAssignmentMinor[playerKey] = value
end

function RepriseHC.GetGroupAssignmentMinor(playerKey)
  return GetAssignmentMinor(playerKey)
end

function RepriseHC.UpdateGroupAssignment(playerKey, groupName, opts)
  if not playerKey or playerKey == "" then return false end
  local db = EnsureDb()
  db.groupAssignments = db.groupAssignments or {}
  local assignments = db.groupAssignments

  if groupName ~= nil then
    groupName = tostring(groupName)
    groupName = groupName:gsub("^%s+", ""):gsub("%s+$", "")
    if groupName == "" then groupName = nil end
  end

  local when = tonumber(opts and (opts.when or opts.time))
  if not when or when <= 0 then
    when = GetServerTime and GetServerTime() or time()
  end

  local version = tonumber(opts and (opts.dbVersion or opts.dbv))
  if not version then
    version = RepriseHC.GetDbVersion()
  end
  if version < 0 then version = 0 end

  local incomingMinor = tonumber(opts and (opts.groupVersion or opts.groupMinor or opts.groupRevision or opts.gv)) or 0
  if incomingMinor < 0 then incomingMinor = 0 end
  incomingMinor = math.floor(incomingMinor)

  local currentGlobalMinor = CurrentGroupMinorVersion()
  local existing = assignments[playerKey]
  if type(existing) ~= "table" then existing = {} end
  local existingMinor = tonumber(existing.groupVersion or existing.groupMinor or existing.gv) or 0
  local recordedMinor = GetAssignmentMinor(playerKey)
  if recordedMinor > existingMinor then existingMinor = recordedMinor end

  if incomingMinor == 0 then
    incomingMinor = currentGlobalMinor + 1
  end

  if incomingMinor < existingMinor then
    return false, existingMinor
  end

  if incomingMinor > currentGlobalMinor then
    RepriseHC.SetGroupMinorVersion(incomingMinor)
  end

  RememberAssignmentMinor(playerKey, incomingMinor)

  if not groupName or groupName == "" then
    if assignments[playerKey] ~= nil then
      assignments[playerKey] = nil
      return true, incomingMinor
    end
    return false, incomingMinor
  end

  local changed = false
  if type(existing) ~= "table" then
    existing = {}
    changed = true
  end

  if existing.group ~= groupName then changed = true end
  if (existing.dbVersion or 0) ~= version and version ~= 0 then changed = true end
  if (tonumber(existing.when) or 0) ~= when then changed = true end

  existing.group = groupName
  existing.when = when
  if version ~= 0 then
    existing.dbVersion = version
  else
    existing.dbVersion = tonumber(existing.dbVersion or existing.dbv) or 0
  end
  existing.dbv = nil
  existing.groupVersion = incomingMinor
  existing.groupMinor = nil
  existing.gv = nil

  assignments[playerKey] = existing
  return changed, incomingMinor
end

function RepriseHC.GetDeathLog()
  return EnsureDb().deathLog
end

function RepriseHC.PushDeath(entry)
  if not entry then return end
  local version = entry.dbVersion or entry.dbv or RepriseHC.GetDbVersion()
  entry.dbVersion = version
  entry.dbv = nil
  local log = EnsureDb().deathLog
  log[#log + 1] = entry
end

local function NormalizeCharacterAchievements(entry, targetVersion)
  if type(entry) ~= "table" then return 0, 0 end
  entry.achievements = entry.achievements or {}
  local removed, totalPoints = 0, 0
  local desiredVersion = tonumber(targetVersion) or 0
  for id, ach in pairs(entry.achievements) do
    if type(ach) ~= "table" then
      entry.achievements[id] = nil
      removed = removed + 1
    else
      local achVersion = tonumber(ach.dbVersion or ach.dbv) or 0
      if desiredVersion ~= 0 and achVersion ~= desiredVersion then
        entry.achievements[id] = nil
        removed = removed + 1
      else
        if desiredVersion ~= 0 then
          ach.dbVersion = desiredVersion
        else
          ach.dbVersion = achVersion
        end
        ach.dbv = nil
        ach.points = tonumber(ach.points) or 0
        ach.when = tonumber(ach.when) or 0
        totalPoints = totalPoints + ach.points
      end
    end
  end
  entry.points = totalPoints
  if desiredVersion ~= 0 then
    entry.dbVersion = desiredVersion
  else
    local current = tonumber(entry.dbVersion or entry.dbv) or 0
    entry.dbVersion = current
  end
  entry.dbv = nil
  return removed, totalPoints
end

RepriseHC.NormalizeCharacterAchievements = NormalizeCharacterAchievements

function RepriseHC.PruneAchievementsToVersion(version)
  local db = EnsureDb()
  local targetVersion = tonumber(version) or 0
  local removed = 0
  for _, entry in pairs(db.characters) do
    local pruned = NormalizeCharacterAchievements(entry, targetVersion)
    if pruned and pruned > 0 then
      removed = removed + pruned
    end
  end
  for id, info in pairs(db.guildFirsts) do
    local entryVersion = tonumber(info and (info.dbVersion or info.dbv)) or 0
    if targetVersion ~= 0 and entryVersion ~= targetVersion then
      db.guildFirsts[id] = nil
      removed = removed + 1
    else
      if targetVersion ~= 0 then
        info.dbVersion = targetVersion
      else
        info.dbVersion = entryVersion
      end
      info.dbv = nil
      info.when = tonumber(info.when) or 0
    end
  end
  return removed
end

local function NormalizeDbVersion(ver)
  local num = tonumber(ver)
  if not num then return DEFAULT_DB_VERSION end
  num = math.floor(num)
  if num == 0 then return 0 end
  if num < 0 then return DEFAULT_DB_VERSION end
  if num < DEFAULT_DB_VERSION then return DEFAULT_DB_VERSION end
  return num
end

function RepriseHC.GetDbVersion()
  local db = EnsureDb()
  local current = tonumber(db.config.dbVersion)
  if not current then
    db.config.dbVersion = DEFAULT_DB_VERSION
    return DEFAULT_DB_VERSION
  end
  if current == 0 then return 0 end
  if current < DEFAULT_DB_VERSION then
    db.config.dbVersion = DEFAULT_DB_VERSION
    return DEFAULT_DB_VERSION
  end
  return current
end

function RepriseHC.SetDbVersion(ver)
  local db = EnsureDb()
  local previous = tonumber(db.config and db.config.dbVersion) or 0
  if ver == 0 then
    db.config.dbVersion = 0
  else
    db.config.dbVersion = NormalizeDbVersion(ver)
  end
  local current = tonumber(db.config.dbVersion) or 0
  if current ~= previous then
    if db.config then
      db.config.selectedGroupKey = nil
    end
    RepriseHC.runtime = RepriseHC.runtime or {}
    RepriseHC.runtime.groupKey = nil
  end
end

function RepriseHC.PruneDeathLogToVersion(version)
  local db = EnsureDb()
  local log = db.deathLog
  if not log then return 0 end
  local targetVersion = tonumber(version) or 0
  local keep, removed = {}, 0
  for _, entry in ipairs(log) do
    local entryVersion = tonumber(entry and (entry.dbVersion or entry.dbv)) or 0
    if targetVersion == 0 then
      entry.dbVersion = 0
      entry.dbv = nil
      table.insert(keep, entry)
    elseif entryVersion == targetVersion then
      entry.dbVersion = entryVersion
      entry.dbv = nil
      table.insert(keep, entry)
    else
      removed = removed + 1
    end
  end
  if removed > 0 then
    db.deathLog = keep
  end
  return removed
end

local function RefreshUI()
  if RepriseHC.UIRefresh then
    RepriseHC.UIRefresh()
  end
end
RepriseHC.RefreshUI = RefreshUI

local function HardResetDB(reason, newVersion, opts)
  local db = EnsureDb()
  db.characters = {}
  db.guildFirsts = {}
  db.deathLog = {}
  db.groupAssignments = {}
  if db.config then
    db.config.selectedGroupKey = nil
    db.config.groupMinorVersion = 0
    db.config.groupAssignmentMinor = {}
  end
  RepriseHC.runtime = RepriseHC.runtime or {}
  RepriseHC.runtime.groupKey = nil
  if newVersion ~= nil then
    if newVersion == 0 then
      db.config.dbVersion = 0
    else
      db.config.dbVersion = NormalizeDbVersion(newVersion)
    end
  elseif db.config.dbVersion == nil then
    db.config.dbVersion = DEFAULT_DB_VERSION
  elseif db.config.dbVersion > 0 and db.config.dbVersion < DEFAULT_DB_VERSION then
    db.config.dbVersion = DEFAULT_DB_VERSION
  end
  local msg = "|cffff6060Cleaned!|r"
  if type(reason) == "string" and reason ~= "" then
    msg = reason
  end
  if not (opts and opts.skipPrint) then
    RepriseHC.Print(msg)
  end
  if RepriseHC.PrimeProfessionBaseline then
    C_Timer.After(0, function()
      RepriseHC.PrimeProfessionBaseline()
    end)
  end
  if not (opts and opts.skipRefresh) then
    C_Timer.After(0, function()
      if RepriseHC_UI and RepriseHC_UI:IsShown() then
        RefreshUI()
      end
    end)
  end
end

RepriseHC._HardResetDB = HardResetDB

function RepriseHC.CanRunGlobalReset()
  local battleTag = GetPlayerBattleTag()
  if not battleTag then
    return false, nil, "|cffff6060Reset requires a Battle.net login.|r"
  end
  local hash = ComputeBattleTagHash(battleTag)
  if not hash then
    return false, nil, "|cffff6060Unable to validate Battle.net identity.|r"
  end
  if hash ~= RESET_SIGNATURE then
    return false, nil, "|cffff6060Reset not permitted for this account.|r"
  end
  return true, hash
end

function RepriseHC.TriggerGlobalReset(signature)
  if type(signature) ~= "number" or signature ~= RESET_SIGNATURE then return end
  local current = RepriseHC.GetDbVersion()
  if current == 0 then current = DEFAULT_DB_VERSION end
  if current < DEFAULT_DB_VERSION then current = DEFAULT_DB_VERSION end
  local nextVersion = current + 1
  local stamp = GetServerTime and GetServerTime() or time()
  RepriseHC._LastResetStamp = stamp
  RepriseHC._LastResetDbVersion = nextVersion
  HardResetDB("|cffff6060Global reset requested.|r", nextVersion)
  if RepriseHC.Comm_Send then
    local origin = (RepriseHC.GetPlayerKey and RepriseHC.GetPlayerKey()) or (UnitName("player")) or ""
    RepriseHC.Comm_Send("RESET", { sig = signature, stamp = stamp, source = origin, dbv = nextVersion, dbVersion = nextVersion })
  end
end

local EventFrame = CreateFrame("Frame", "RepriseHC_EventBus")
local registeredEvents = {}
RepriseHC._eventHandlers = RepriseHC._eventHandlers or {}

local function EnsureRegistered(ev)
  if not ev or registeredEvents[ev] then return end
  EventFrame:RegisterEvent(ev)
  registeredEvents[ev] = true
end

function RepriseHC.RegisterEvent(event, fn)
  if not event or type(fn) ~= "function" then return end
  local list = RepriseHC._eventHandlers[event]
  if not list then
    list = {}
    RepriseHC._eventHandlers[event] = list
  end
  table.insert(list, fn)
  EnsureRegistered(event)
end

function RepriseHC._EnsureEvent(ev)
  EnsureRegistered(ev)
end

EventFrame:SetScript("OnEvent", function(_, event, ...)
  local list = RepriseHC._eventHandlers[event]
  if list then
    for i = 1, #list do
      local ok, err = pcall(list[i], event, ...)
      if not ok and RepriseHC.Print then
        RepriseHC.Print(("Handler error for %s: %s"):format(event, tostring(err)))
      end
    end
  end
end)

local COMMON_EVENTS = {
  "ADDON_LOADED","PLAYER_LOGIN","PLAYER_ENTERING_WORLD","ZONE_CHANGED_NEW_AREA","COMBAT_LOG_EVENT_UNFILTERED",
  "PLAYER_LEVEL_UP","TIME_PLAYED_MSG","CHAT_MSG_ADDON","SKILL_LINES_CHANGED","PLAYER_DEAD","QUEST_TURNED_IN",
  "PLAYER_GUILD_UPDATE","GUILD_ROSTER_UPDATE","TRADE_REQUEST","TRADE_SHOW","AUCTION_HOUSE_SHOW",
  "INSPECT_READY","UNIT_NAME_UPDATE"
}
for _, ev in ipairs(COMMON_EVENTS) do
  EnsureRegistered(ev)
end

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
  C_ChatInfo.RegisterAddonMessagePrefix("RepriseHC_ACH")
end

Core:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == RepriseHC.name then
    local db = EnsureDb()
    db.config.levelCap = RepriseHC.levelCap or 60
    local currentVersion = RepriseHC.GetDbVersion()
    RepriseHC.PruneAchievementsToVersion(currentVersion)
    RepriseHC.PruneDeathLogToVersion(currentVersion)
    RepriseHC.PruneGroupAssignmentsToVersion(currentVersion)
  elseif event == "PLAYER_LOGIN" then
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
      C_ChatInfo.RegisterAddonMessagePrefix("RepriseHC_ACH")
    end
    if not RepriseHC.IsGuildAllowed() then
      RepriseHC.Print("|cffff6060Disabled: You must be in the guild 'Reprise' or 'RepriseHC' for this addon to work.|r")
    else
      RepriseHC.Print(("Core loaded v%s"):format(RepriseHC.version))
    end
  end
end)

SLASH_REPRISEHC1 = "/reprisehc"
SLASH_REPRISEHC2 = "/rhc"
SlashCmdList["REPRISEHC"] = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local lower = msg:lower()
  if lower == "on" then
    RepriseHC._tradeEnabled = true
    RepriseHC.Print("Trade, mail, auction house protection enabled.")
  elseif lower == "off" then
    RepriseHC._tradeEnabled = false
    RepriseHC.Print("Trade, mail, auction house protection disabled.")
  elseif lower == "reload" then
    if RepriseHC.RebuildGuildCache then RepriseHC.RebuildGuildCache() end
    local requestedSync = false
    if RepriseHC.Comm_RequestSnapshot then
      requestedSync = RepriseHC.Comm_RequestSnapshot() or requestedSync
    elseif RepriseHC.Comm_Send then
      RepriseHC.Comm_Send("REQSNAP", { need="all" })
      requestedSync = true
    end
    if RepriseHC.Comm_BroadcastSnapshot then
      requestedSync = RepriseHC.Comm_BroadcastSnapshot() or requestedSync
    elseif RepriseHC.Comm_Send then
      local builder = RepriseHC.Comm_BuildSnapshot
      local snapshot = builder and builder()
      if snapshot then
        RepriseHC.Comm_Send("SNAP", { kind="SNAP", data = snapshot })
        requestedSync = true
      end
    end
    if requestedSync then
      RepriseHC.Print("Guild roster refreshed. Sync requested.")
    else
      RepriseHC.Print("Guild roster refreshed.")
    end
  elseif lower == "dbv" then
    local ver = RepriseHC.GetDbVersion()
    RepriseHC.Print(("Current database version: |cff40ff40%d|r"):format(ver))
  elseif lower:match("^reset%s+all$") then
    local ok, signature, err = RepriseHC.CanRunGlobalReset()
    if not ok then
      if err then RepriseHC.Print(err) end
      return
    end
    RepriseHC.TriggerGlobalReset(signature)
  else
    RepriseHC.Print("Commands: /rhc on, /rhc off, /rhc reload, /rhc dbv, |cffa0a0a0/rhc reset all|r (SECRET)")
  end
end
