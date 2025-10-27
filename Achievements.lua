local ADDON = "RepriseHC"
RepriseHC = RepriseHC or {}

local maxMilestone = math.max(
  (RepriseHC.MaxMilestone and RepriseHC.MaxMilestone()) or (math.floor(math.max(0, (RepriseHC.levelCap or 60)) / 10) * 10),
  RepriseHC.levelCap or 0
)
local levelMilestones = {}
if type(RepriseHC.levels) == "table" then
  for _, threshold in ipairs(RepriseHC.levels) do
    table.insert(levelMilestones, threshold)
  end
end
table.sort(levelMilestones)
local faction = (UnitFactionGroup and select(1, UnitFactionGroup("player"))) or "Alliance"

-- ========= DB =========
RepriseHCAchievementsDB = RepriseHCAchievementsDB or { characters = {}, guildFirsts = {}, deathLog = {}, config = {}, groupAssignments = {} }
local function DB() return RepriseHCAchievementsDB end

local function CurrentDbVersion()
  if RepriseHC and RepriseHC.GetDbVersion then
    local ok = tonumber(RepriseHC.GetDbVersion())
    if ok and ok >= 0 then return ok end
  end
  return tonumber(RepriseHC.defaultDbVersion) or 1
end

-- ========= Printing =========
local function Print(msg)
  if RepriseHC and RepriseHC.Print then
    RepriseHC.Print(msg)
  elseif DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff00c0ffRepriseHC:|r "..(msg or ""))
  end
end

-- ========= Player key =========
local function PlayerKey()
  local name, realm = UnitName("player")
  realm = realm or GetRealmName()
  if realm and realm ~= "" then name = name.."-"..realm end
  return name
end

-- ========= Dungeon ordering & bosses =========
local DUNGEON_MINLEVEL = {
  ["Ragefire Chasm"]= { minLevel=13, faction="Horde" } ,
  ["Wailing Caverns"]= { minLevel=17 } , 
  ["The Deadmines"]= { minLevel=17, faction="Alliance"  } , 
  ["Shadowfang Keep"]= { minLevel=22 } , 
  ["Blackfathom Deeps"]= { minLevel=24 } , 
  ["The Stockade"]= { minLevel=24, faction="Alliance" } , 
  ["Razorfen Kraul"]= { minLevel=29 } , 
  ["Gnomeregan"]= { minLevel=29 } , 
  ["Scarlet Monastery: Graveyard"]= { minLevel=30 } , 
  ["Scarlet Monastery: Library"]= { minLevel=33 } , 
  ["Scarlet Monastery: Armory"]= { minLevel=36 } , 
  ["Razorfen Downs"]= { minLevel=37 } , 
  ["Scarlet Monastery: Cathedral"]= { minLevel=38 } , 
  ["Uldaman"]= { minLevel=41 } , 
  ["Zul'Farrak"]= { minLevel=44 } , 
  ["Maraudon"]= { minLevel=46 } ,  
  ["The Temple of Atal'Hakkar"]= { minLevel=50 } , 
  ["Blackrock Depths"]= { minLevel=52 } , 
  ["Dire Maul: East"]= { minLevel=54 } , 
  ["Lower Blackrock Spire"]= { minLevel=55 } , 
  ["Dire Maul: West"]= { minLevel=56 } , 
  ["Dire Maul: North"]= { minLevel=56 } , 
  ["Stratholme"]= { minLevel=58 } , 
  ["Scholomance"]= { minLevel=58 } , 
  ["Upper Blackrock Spire"]= { minLevel=59 } , 
}

local FINAL_BOSS = {
  ["Ragefire Chasm"]               = { npc=11518, boss="Jergosh the Invoker" },
  ["Wailing Caverns"]              = { npc=3654,  boss="Mutanus the Devourer" },
  ["The Deadmines"]                = { npc=639,   boss="Edwin Vancleef", faction="Alliance" },
  ["Shadowfang Keep"]              = { npc=4275,  boss="Archmage Arugal" },
  ["Blackfathom Deeps"]            = { npc=4829,  boss="Aku'mai" },
  ["The Stockade"]                 = { npc=1716,  boss="Bazil Thredd", faction="Alliance" },
  ["Razorfen Kraul"]               = { npc=4421,  boss="Charlga Razorflank" },
  ["Gnomeregan"]                   = { npc=7800,  boss="Mekgineer Thermaplugg" },
  ["Scarlet Monastery: Graveyard"] = { npc=4543,  boss="Bloodmage Thalnos" },
  ["Scarlet Monastery: Library"]   = { npc=6487,  boss="Arcanist Doan" },
  ["Scarlet Monastery: Armory"]    = { npc=3975,  boss="Herod" },
  ["Razorfen Downs"]               = { npc=7358,  boss="Amnennar the Coldbringer" },
  ["Scarlet Monastery: Cathedral"] = { npc=3977,  boss="High Inquisitor Whitemane" },
  ["Uldaman"]                      = { npc=2748,  boss="Archaedas" },
  ["Zul'Farrak"]                   = { npc=7267,  boss="Chief Ukorz Sandscalp" },
  ["Maraudon"]                     = { npc=12201, boss="Princess Theradras" },
  ["The Temple of Atal'Hakkar"]    = { npc=5709,  boss="Shade of Eranikus" },
  ["Blackrock Depths"]             = { npc=9019,  boss="Emperor Dagran Thaurissan" },
  ["Dire Maul: East"]              = { npc=11492, boss="Alzzin the Wildshaper" },
  ["Lower Blackrock Spire"]        = { npc=9568,  boss="Overlord Wyrmthalak" },
  ["Dire Maul: West"]              = { npc=11486, boss="Prince Tortheldrin" },
  ["Dire Maul: North"]             = { npc=11501, boss="King Gordok" },
  ["Stratholme"]                   = { npc=10440, boss="Baron Rivendare" },
  ["Scholomance"]                  = { npc=1853,  boss="Darkmaster Gandling" },
  ["Upper Blackrock Spire"]        = { npc=10363, boss="General Drakkisath" },
}
local FINAL_BOSS_BY_NPCID = {}; for d,info in pairs(FINAL_BOSS) do FINAL_BOSS_BY_NPCID[info.npc]=d end

-- Points per dungeon (15 base, +5 when minlevel increases)
local DUNGEON_POINTS = {}
do
  local work = {}
  for d,info in pairs(DUNGEON_MINLEVEL) do 
    if (not info.faction) or (faction == info.faction) then
      if (info.minLevel <= RepriseHC.levelCap) then
        table.insert(work,{d=d,l=info.minLevel}) 
      end
    end
  end
  table.sort(work,function(a,b) if a.l==b.l then return a.d<b.d end return a.l<b.l end)
  local pts,last=nil,nil; pts=15
  for _,w in ipairs(work) do if last and w.l>last then pts=pts+5 end last=w.l; DUNGEON_POINTS[w.d]=pts end
end

-- Expose helpers for UI
function RepriseHC.Ach_DungeonList()
  local work = {}
  for d,info in pairs(DUNGEON_MINLEVEL) do 
    if (not info.faction) or (faction == info.faction) then
      if (info.minLevel <= RepriseHC.levelCap) then
        table.insert(work,{d=d,l=info.minLevel}) 
      end
    end
  end
  table.sort(work,function(a,b) if a.l==b.l then return a.d<b.d end return a.l<b.l end)
  local out = {}; for _,w in ipairs(work) do table.insert(out, w.d) end; return out
end
function RepriseHC.Ach_GetDungeonPoints(d) return DUNGEON_POINTS[d] or 0 end
function RepriseHC.Ach_GetDungeonBossName(d) return (FINAL_BOSS[d] and FINAL_BOSS[d].boss) or d end

-- ========= Earn core =========
local function EnsureChar()
  local key = PlayerKey()
  DB().characters[key] = DB().characters[key] or { points=0, achievements={} }
  local entry = DB().characters[key]
  if RepriseHC and RepriseHC.NormalizeCharacterAchievements then
    RepriseHC.NormalizeCharacterAchievements(entry, CurrentDbVersion())
  end
  return entry
end

local function EarnAchievement(id, displayName, points)
  if not RepriseHC.IsGuildAllowed() then return false end
  local c = EnsureChar()
  c.achievements = c.achievements or {}
  if c.achievements[id] then return false end

  local now = time()
  local version = CurrentDbVersion()
  points = tonumber(points) or 0
  c.achievements[id] = {
    name = displayName,
    points = points,
    when = now,
    dbVersion = version,
  }

  if RepriseHC and RepriseHC.NormalizeCharacterAchievements then
    RepriseHC.NormalizeCharacterAchievements(c, version)
  else
    c.points = (c.points or 0) + (points or 0)
  end
  return true
end

-- ========= Sync =========
local function Broadcast(tag, payload)
  -- Do NOT block transport here; Comm_Send handles routing (GUILD/GROUP/WHISPER).
  if tag == "AWARD" then
    local data
    if type(payload) == "table" then
      data = payload
    else
      local playerKey, id, ptsStr, name, whenStr, dbvStr = tostring(payload or ""):match("^([^;]*);([^;]*);([^;]*);?([^;]*);?([^;]*);?([^;]*)$")
      if not playerKey or not id then return end
      data = {
        playerKey = playerKey,
        id = id,
        pts = tonumber(ptsStr or "0") or 0,
        name = name,
        when = tonumber(whenStr or "0") or time(),
        dbVersion = tonumber(dbvStr or "0") or CurrentDbVersion(),
      }
    end

    if not data or not data.playerKey or not data.id then return end

    local pts = tonumber(data.pts) or 0
    local when = tonumber(data.when) or time()
    local dbVersion = tonumber(data.dbVersion or data.dbv) or CurrentDbVersion()
    if dbVersion < 0 then dbVersion = CurrentDbVersion() end

    RepriseHC.Comm_Send("ACH", {
      playerKey = data.playerKey,
      id = data.id,
      pts = pts,
      name = data.name,
      when = when,
      dbVersion = dbVersion,
      dbv = dbVersion,
    })
  elseif tag == "DEAD" then
    local playerKey, levelStr, class, race, zone, subzone, name, whenStr = payload:match("^([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);([^;]*);?(.*)$")
    if not playerKey then return end
    local level = tonumber(levelStr or "0") or 0
    local when = tonumber(whenStr) or time()
    local currentVersion = (RepriseHC and RepriseHC.GetDbVersion and RepriseHC.GetDbVersion()) or 0
    RepriseHC.Comm_Send("DEATH", {
      playerKey=playerKey, level=level, class=class, race=race, zone=zone, subzone=subzone,
      name=name, when=when, dbVersion=currentVersion, dbv=currentVersion
    })
  end
end

local function SyncBroadcastAward(id, name, pts)
  local playerKey = PlayerKey()
  local db = DB()
  local char = db.characters and db.characters[playerKey]
  local when = time()
  if char and char.achievements and char.achievements[id] then
    when = tonumber(char.achievements[id].when) or when
  end
  local dbVersion = CurrentDbVersion()
  Broadcast("AWARD", {
    playerKey = playerKey,
    id = id,
    pts = pts or 0,
    name = name,
    when = when,
    dbVersion = dbVersion,
  })
end

function RepriseHC.SyncBroadcastDeath(level, class, race, zone, subzone, name)
  local whenStr = tostring(time())
  Broadcast("DEAD", string.format("%s;%d;%s;%s;%s;%s;%s;%s",
    PlayerKey(), level or 0, class or "", race or "", zone or "", subzone or "", name or "", whenStr))
end

-- ========= Level/Professions =========
function RepriseHC.Ach_AwardLevelsUpTo(level)
  if not (RepriseHC.navigation.level.enabled) then return end
  for _, th in ipairs(levelMilestones) do
    if level >= th and th <= maxMilestone then
      local id = "LEVEL_"..th
      local nm = "Reached Level "..th
      local pts = th*2
      if EarnAchievement(id, nm, pts) then
        local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format(nm, pts)
        Print(msg)
        if (RepriseHC.GetShowToGuild()) then
          SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
        end
        SyncBroadcastAward(id, nm, pts)
      end
    end
  end  
end

local function CollectProfessionRanks()
  local ranks = {}
  local num = GetNumSkillLines and GetNumSkillLines() or 0
  for i = 1, num do
    local name, isHeader, _, skillRank = GetSkillLineInfo(i)
    if name and not isHeader and RepriseHC.professions[name] then
      ranks[name] = math.max(ranks[name] or 0, skillRank or 0)
    end
  end
  return ranks
end

local lastProfessionRanks = nil

local function UpdateProfessionBaseline()
  lastProfessionRanks = CollectProfessionRanks()
end

function RepriseHC.PrimeProfessionBaseline()
  UpdateProfessionBaseline()
end

local function ShouldForceProfessionAward(opts)
  if opts == true then return true end
  if type(opts) == "table" then
    return opts.force == true
  end
  return false
end

function RepriseHC.Ach_CheckProfessions(opts)
  if not (RepriseHC.navigation.prof.enabled) then return end
  if not RepriseHC.IsGuildAllowed() then return end

  if not lastProfessionRanks then
    UpdateProfessionBaseline()
  end

  local force = ShouldForceProfessionAward(opts)
  local ranks = CollectProfessionRanks()
  local previous = lastProfessionRanks or {}

  for skill, _ in pairs(RepriseHC.professions) do
    local newRank = ranks[skill] or 0
    local oldRank = previous[skill] or 0
    for _, th in ipairs(RepriseHC.profThreshold) do
      if th.levelRequirement <= RepriseHC.levelCap and newRank >= th.threshold and (force or oldRank < th.threshold) then
        local id = skill .. "_" .. th.threshold
        local title = (th.threshold==75 and "Apprentice") or (th.threshold==150 and "Journeyman") or (th.threshold==225 and "Expert") or "Artisan"
        local pts = (th.threshold==75 and 15) or (th.threshold==150 and 30) or (th.threshold==225 and 45) or 60
        local nm = skill .. " " .. title
        if EarnAchievement(id, nm, pts) then
          local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format(nm, pts)
          Print(msg)
          if (RepriseHC.GetShowToGuild()) then
            SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
          end
          SyncBroadcastAward(id, nm, pts)
        end
      end
    end
  end

  lastProfessionRanks = ranks
end

-- ========= Speedrun (Hardcore-style) =========
local _speedrunPendingLevel = nil
function RepriseHC.Ach_CheckSpeedrunOnDing(newLevel)
  if not (RepriseHC.navigation.speedrun.enabled) then return end 
  if not RepriseHC.IsGuildAllowed() then return end
  if newLevel <= maxMilestone then
    if RepriseHC.speedrunThresholds[newLevel] then
      _speedrunPendingLevel = newLevel
      RequestTimePlayed()
    end
  end
end
local function AwardSpeedrunIfEligible(totalSeconds)
  if not (RepriseHC.navigation.speedrun.enabled) then return end 
  if not _speedrunPendingLevel then return end
  local lvl = _speedrunPendingLevel
  _speedrunPendingLevel = nil
  local hours = RepriseHC.speedrunThresholds[lvl]
  if not hours then return end
  if lvl <= maxMilestone then
    if totalSeconds <= (hours * 3600) then
      local id  = "SPEED_"..lvl
      local nm  = ("Reach level %d by %d hours"):format(lvl, hours)
      local pts = lvl * 2 
      if EarnAchievement(id, nm, pts) then
        local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format(nm, pts)
        Print(msg)
        if (RepriseHC.GetShowToGuild()) then
          SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
        end
        SyncBroadcastAward(id, nm, pts)
      end
    end
  end
end
function RepriseHC.Ach_ListSpeedruns()
  if not (RepriseHC.navigation.speedrun.enabled) then return end 
  local res = {}
  for lvl, h in pairs(RepriseHC.speedrunThresholds) do
    if lvl <= maxMilestone then
      table.insert(res, {
        id     = "SPEED_"..lvl,
        level  = lvl,
        hours  = h,
        name   = ("Reach level %d by %d hours"):format(lvl, h),
        points = lvl * 2,
      })
    end
  end
  table.sort(res, function(a,b) return a.level < b.level end)
  return res
end

-- ========= Quest Milestones =========
local QUEST_MILESTONES = {
  { questId = 783, levelCap = 2,  title = "A Threat Within", faction = "Alliance" },
  { questId = 5261, levelCap = 2,  title = "Eagan Peltskinner", faction = "Alliance" },
  { questId = 2561, levelCap = 9,  title = "Druid of the Claw", faction = "Alliance" },  
  { questId = 314,  levelCap = 10, title = "Protecting the Herd", faction = "Alliance" },
  { questId = 176,  levelCap = 11, title = "Wanted: Hogger", faction = "Alliance" },
  { questId = 776,  levelCap = 11, title = "Rites of the Earthmother", faction = "Horde" },
  { questId = 408,  levelCap = 11, title = "The Family Crypt", faction = "Horde" },
  { questId = 832,  levelCap = 12, title = "Burning Shadows", faction = "Horde" },
  { questId = 64,   levelCap = 12, title = "The Forgotten Heirloom", faction = "Alliance" },
  { questId = 217,  levelCap = 16, title = "In Defense of the King's Lands", faction = "Alliance" },
  { questId = 731,  levelCap = 19, title = "The Absent Minded Prospector", faction = "Alliance" },
  { questId = 4021, levelCap = 20, title = "Counterattack!", faction = "Horde" },
  { questId = 6481, levelCap = 20, title = "Earthen Arise", faction = "Horde" },
  { questId = 480,  levelCap = 20, title = "The Weaver", faction = "Horde" },
  { questId = 180,  levelCap = 23, title = "Wanted: Lieutenant Fangore", faction = "Alliance" },
  { questId = 1017, levelCap = 23, title = "Mage Summoner", faction = "Alliance" },
  { questId = 247,  levelCap = 26, title = "The Hunt Completed", faction = "Horde" },
  { questId = 1150, levelCap = 30, title = "Test of Endurance", faction = "Horde" },
  { questId = 474,  levelCap = 31, title = "Defeat Nek'rosh", faction = "Alliance" },
  { questId = 550,  levelCap = 33, title = "Battle of Hillsbrad", faction = "Horde" },
  { questId = 228,  levelCap = 33, title = "Mor'Ladim", faction = "Alliance" },
  { questId = 661,  levelCap = 34, title = "Hints of a New Plague?", faction = "Alliance" },
  { questId = 1270, levelCap = 34, title = "Stinky's Escape", faction = "Alliance" },
  { questId = 1222, levelCap = 34, title = "Stinky's Escape", faction = "Horde" },
  { questId = 1393, levelCap = 38, title = "Galen's Escape" },
  { questId = 208,  levelCap = 39, title = "Big Game Hunter" },
  { questId = 1383, levelCap = 40, title = "Nothing But The Truth", faction = "Horde" },
  { questId = 779,  levelCap = 40, title = "Seal of the Earth", faction = "Alliance" },
  { questId = 795,  levelCap = 40, title = "Seal of the Earth", faction = "Horde" },
  { questId = 717,  levelCap = 40, title = "Tremors of the Earth", faction = "Alliance" },
  { questId = 6132, levelCap = 41, title = "Get Me Out of Here!" },
  { questId = 2870, levelCap = 43, title = "Against Lord Shalzaru", faction = "Alliance" },
  { questId = 521,  levelCap = 43, title = "The Crown of Will", faction = "Horde" },
  { questId = 2882, levelCap = 45, title = "Cuergo's Gold" },
  { questId = 3062, levelCap = 48, title = "Dark Heart", faction = "Horde" },
  { questId = 3601, levelCap = 51, title = "Kim'jael Indeed!" },
  { questId = 3822, levelCap = 51, title = "Krom'grul", faction = "Horde" },
  { questId = 2681, levelCap = 54, title = "The Stones That Bind Us" },
  { questId = 5242, levelCap = 55, title = "A Final Blow" },
  { questId = 656,  levelCap = 55, title = "Summoning the Princess" },
  { questId = 7701, levelCap = 56, title = "WANTED: Overseer Maltorius" },
  { questId = 4507, levelCap = 56, title = "Pawn Captures Queen" },
  { questId = 7846, levelCap = 56, title = "Recover the Key!", faction = "Horde" },
  { questId = 4182, levelCap = 57, title = "Dragonkin Menace", faction = "Alliance" },
  { questId = 8283, levelCap = 59, title = "Wanted - Deathclasp, Terror of the Sands" },
  { questId = 5121, levelCap = 59, title = "High Chief Winterfall" },
  { questId = 5056, levelCap = 59, title = "Shy-Rotam", faction = "Horde" }
}

local function QuestPointsForLevelCap(cap)
  if cap <= 10 then return 15
  elseif cap <= 20 then return 25
  elseif cap <= 30 then return 35
  elseif cap <= 40 then return 45
  elseif cap <= 50 then return 55
  else return 65 end
end

-- Expose to UI
function RepriseHC.Ach_QuestList(faction)
  if not (RepriseHC.navigation.quest.enabled) then return end 
  local list = {}
  for _,q in ipairs(QUEST_MILESTONES) do
    if (not q.faction) or (faction == q.faction) then
      if (q.levelCap <= RepriseHC.levelCap) then
        local name = string.format("Complete %s before reaching level %d", q.title, q.levelCap)
        table.insert(list, { id = "QUEST_"..q.questId, questId = q.questId, levelCap = q.levelCap, name = name, points = QuestPointsForLevelCap(q.levelCap), faction = q.faction })
      end
    end
  end
  table.sort(list, function(a,b) if a.levelCap==b.levelCap then return a.name < b.name end return a.levelCap < b.levelCap end)
  return list
end

function RepriseHC.Ach_CheckQuest(questID)
  local level = UnitLevel("player") or 1
  for _,q in ipairs(QUEST_MILESTONES) do
    if (q.levelCap <= RepriseHC.levelCap) then
      if q.questId == questID and level <= q.levelCap then
        local id  = "QUEST_"..q.questId
        local nm  = string.format("Complete %s before reaching level %d", q.title, q.levelCap)
        local pts = QuestPointsForLevelCap(q.levelCap)
        if EarnAchievement(id, nm, pts) then
          local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format(nm, pts)
          Print(msg)
          if (RepriseHC.GetShowToGuild()) then
            SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
          end
          SyncBroadcastAward(id, nm, pts)
        end
        break
      end
    end
  end
end

-- ========= Guild Firsts =========
function RepriseHC.Ach_GuildFirstOptions(faction)
  if not (RepriseHC.navigation.guildFirst.enabled) then return end 
  local classesOrder = { "Druid","Hunter","Mage","Paladin","Priest","Rogue","Shaman","Warlock","Warrior" }
  local racesOrder   = { "Dwarf","Gnome","Human","Night Elf","Orc","Undead","Tauren","Troll" }
  local classFactionByName = {}
  for token,info in pairs(RepriseHC.class) do
    local disp = (type(info)=="table" and info.name) or info
    local fac  = (type(info)=="table" and info.faction) or nil
    classFactionByName[disp] = fac
  end
  local raceFactionByName = {}
  for token,info in pairs(RepriseHC.race) do
    local disp = (type(info)=="table" and info.name) or info
    local fac  = (type(info)=="table" and info.faction) or nil
    raceFactionByName[disp] = fac
  end
  local outClasses, outRaces = {}, {}
  for _,name in ipairs(classesOrder) do
    local fac = classFactionByName[name]
    if (not fac) or (fac == faction) then table.insert(outClasses, name) end
  end
  for _,name in ipairs(racesOrder) do
    local fac = raceFactionByName[name]
    if (not fac) or (fac == faction) then table.insert(outRaces, name) end
  end
  return { classes = outClasses, races = outRaces }
end

local function LockGuildFirst(id, winnerKey, winnerName)
  if not (RepriseHC.navigation.guildFirst.enabled) then return end
  DB().guildFirsts = DB().guildFirsts or {}
  local version = CurrentDbVersion()
  local existing = DB().guildFirsts[id]
  if existing then
    local existingVersion = tonumber(existing.dbVersion or existing.dbv) or 0
    if version ~= 0 and existingVersion ~= version then
      DB().guildFirsts[id] = nil
      existing = nil
    end
  end
  if not existing then
    DB().guildFirsts[id] = {
      winner = winnerKey,
      winnerName = winnerName,
      when = time(),
      dbVersion = version,
    }
    return true
  end
  return false
end

function RepriseHC.Ach_TryGuildFirsts(levelOverride)
  if not (RepriseHC.navigation.guildFirst.enabled) then return end
  if not RepriseHC.IsGuildAllowed() then return end
  local cap = tonumber(RepriseHC.levelCap) or 0
  if cap <= 0 then return end

  local lvl = tonumber(levelOverride)
  if not lvl then
    lvl = UnitLevel and UnitLevel("player") or 0
  end
  if (lvl or 0) < cap then return end
  local pkey = PlayerKey()
  local pname = UnitName("player") or pkey

  -- overall
  if LockGuildFirst("FIRST_" .. cap, pkey, pname) then
    if EarnAchievement("FIRST_" .. cap, "Guild First " .. cap, 200) then
      local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format("Guild First " .. cap, 200)
      Print(msg)
      if (RepriseHC.GetShowToGuild()) then
        SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
      end
      SyncBroadcastAward("FIRST_" .. cap, "Guild First " .. cap, 200)
    end
  end

  -- class
  local _, eclass = UnitClass("player")
  local classDisp = RepriseHC.ClassName(eclass)
  local classKey  = (classDisp and classDisp:upper():gsub("%s","_")) or "CLASS"
  local idc       = "FIRST_" .. cap .. "_CLASS_" .. classKey

  if LockGuildFirst(idc, pkey, pname) then
    local title = "Guild First " .. cap .. " " .. (classDisp or "Class")
    if EarnAchievement(idc, title, 100) then
      local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format("Guild First " .. cap .. " " .. (classDisp or "Class"), 100)
      Print(msg)
      if (RepriseHC.GetShowToGuild()) then
        SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
      end
      SyncBroadcastAward(idc, title, 100)
    end
  end

  -- race
  local _, erace = UnitRace("player")
  local raceDisp = RepriseHC.RaceName(erace)
  local raceKey  = (raceDisp and raceDisp:upper():gsub("%s","_")) or "RACE"
  local idr      = "FIRST_" .. cap .. "_RACE_" .. raceKey

  if LockGuildFirst(idr, pkey, pname) then
    local title = "Guild First " .. cap .. " " .. (raceDisp or "Race")
    if EarnAchievement(idr, title, 100) then
      local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format("Guild First " .. cap .. " " .. (raceDisp or "Race"), 100)
      Print(msg)
      if (RepriseHC.GetShowToGuild()) then
        SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
      end
      SyncBroadcastAward(idr, title, 100)
    end
  end
end

-- ========= Earners helper for UI =========
function RepriseHC.Ach_GetEarners(achId)
  local out = {}
  local currentVersion = CurrentDbVersion()
  for playerKey, data in pairs(DB().characters or {}) do
    if data.achievements and data.achievements[achId] then
      local entry = data.achievements[achId]
      local entryVersion = tonumber(entry.dbVersion or entry.dbv) or 0
      if currentVersion == 0 or entryVersion == currentVersion then
        local nm = entry.name or achId
        table.insert(out, {
          player = playerKey,
          when = entry.when or 0,
          points = entry.points or 0,
          title = nm,
        })
      end
    end
  end
  table.sort(out, function(a,b) return a.when < b.when end)
  return out
end

-- ========= Death Log =========
function CaptureDeath()
  local level = UnitLevel("player") or 0
  local _, eclass = UnitClass("player")
  local _, erace  = UnitRace("player")
  local zone      = GetZoneText() or ""
  local sub       = GetSubZoneText() or ""
  local name      = UnitName("player") or (RepriseHC and RepriseHC.PlayerKey and RepriseHC.PlayerKey()) or "Unknown"

  local pkey = (RepriseHC and RepriseHC.PlayerKey and RepriseHC.PlayerKey()) or name
  local dbVersion = (RepriseHC and RepriseHC.GetDbVersion and RepriseHC.GetDbVersion()) or 0

  -- de-dupe insert with normalized comparison
  local inserted = false
  local log = RepriseHC.GetDeathLog and RepriseHC.GetDeathLog() or nil
  
  local function normalizeForCompare(key)
    return (key or ""):lower():gsub("%-.*$", "")
  end
  
  if log then
    local myNorm = normalizeForCompare(pkey)
    for _, d in ipairs(log) do
      if normalizeForCompare(d.playerKey) == myNorm then
        return  -- Already logged, don't duplicate
      end
    end

    local deathTime = time()
    table.insert(log, {
      playerKey = pkey,
      name      = name,
      level     = level,
      class     = eclass,
      race      = erace,
      zone      = zone,
      subzone   = sub,
      when      = deathTime,
      dbVersion = dbVersion,
    })
    inserted = true

    if inserted and IsInGuild() and RepriseHC.GetShowToGuild and RepriseHC.GetShowToGuild() then
      local where = zone or "Unknown"
      if sub and sub ~= "" then
        where = where .. " - " .. sub
      end
      local msg = string.format("%s has died (lvl %d) in %s.", name or pkey or "Unknown", level or 0, where)
      SendChatMessage(msg, "GUILD")
      if RepriseHC.Comm_MarkOwnDeathAnnounced then
        RepriseHC.Comm_MarkOwnDeathAnnounced(deathTime)
      end
    end
  end

  if not inserted then return end

  local function send()
    if RepriseHC and RepriseHC.SyncBroadcastDeath then
      RepriseHC.SyncBroadcastDeath(level, eclass, erace, zone, sub, name)
    elseif RepriseHC and RepriseHC.Comm_Send then
      local currentVersion = (RepriseHC and RepriseHC.GetDbVersion and RepriseHC.GetDbVersion()) or 0
      RepriseHC.Comm_Send("DEATH", {
        playerKey = pkey, name = name, level = level, class = eclass, race = erace,
        zone = zone, subzone = sub, when = time(), dbVersion = currentVersion, dbv = currentVersion
      })
    end
  end

  -- Immediate send plus robust retries
  send()
  C_Timer.After(1.0,   send)
  C_Timer.After(6.0,   send)
  C_Timer.After(15.0,  send)
  C_Timer.After(30.0,  send)
  C_Timer.After(60.0,  send)
end


-- Quick stats helpers for UI
function RepriseHC.DeathStats()
  local dl = RepriseHC.GetDeathLog() or {}
  local byClass, byRace, byZone, byBracket = {}, {}, {}, {}
  local function bk(lv)
    if lv < 10 then return "1-9"
    elseif lv < 20 then return "10-19"
    elseif lv < 30 then return "20-29"
    elseif lv < 40 then return "30-39"
    elseif lv < 50 then return "40-49"
    elseif lv < 60 then return "50-59"
    else return "60" end
  end
  for _,d in ipairs(dl) do
    byClass[d.class] = (byClass[d.class] or 0)+1
    byRace[d.race] = (byRace[d.race] or 0)+1
    local z = (d.zone or "Unknown")
    byZone[z] = (byZone[z] or 0)+1
    byBracket[bk(d.level or 0)] = (byBracket[bk(d.level or 0)] or 0)+1
  end
  return { byClass=byClass, byRace=byRace, byZone=byZone, byBracket=byBracket, total=#dl }
end

-- ========= Event wiring via Core event bus =========
local inPartyInstance = false
local function UpdateInstanceState()
  local _, _, _, _, _, _, _, _, _, instanceType = GetInstanceInfo()
  inPartyInstance = (instanceType == "party")
end

local function TryGuildFirstsIfReady(levelOverride)
  if not (RepriseHC and RepriseHC.Ach_TryGuildFirsts) then return end
  if not (RepriseHC.navigation and RepriseHC.navigation.guildFirst and RepriseHC.navigation.guildFirst.enabled) then return end
  if not (RepriseHC.IsGuildAllowed and RepriseHC.IsGuildAllowed()) then return end
  local cap = tonumber(RepriseHC.levelCap) or 0
  if cap <= 0 then return end
  local lvl = tonumber(levelOverride)
  if not lvl then
    lvl = UnitLevel and UnitLevel("player") or 0
  end
  if (lvl or 0) < cap then return end
  RepriseHC.Ach_TryGuildFirsts(lvl)
end

local function OnCombatLogEvent()
  if not (RepriseHC.navigation.dungeons.enabled) then return end
  if not RepriseHC.IsGuildAllowed() then return end
  local _, subevent, _, srcGUID, _, srcFlags, _, dstGUID = CombatLogGetCurrentEventInfo()
  if subevent ~= "UNIT_DIED" then return end

  local parts = { strsplit("-", dstGUID or "") }
  local idPart = parts[6]
  local npcid = tonumber(idPart)
  if not npcid then return end
  local dungeonLookup = FINAL_BOSS_BY_NPCID[npcid]
  if not dungeonLookup then return end
  local bossName = (FINAL_BOSS[dungeonLookup] and FINAL_BOSS[dungeonLookup].boss) or dungeonLookup
  local id = "DUNGEON_" .. dungeonLookup
  local pts = (RepriseHC.Ach_GetDungeonPoints and RepriseHC.Ach_GetDungeonPoints(dungeonLookup)) or (DUNGEON_POINTS[dungeonLookup] or 0)
  local nm = "Defeat " .. bossName
  if EarnAchievement(id, nm, pts) then
    local msg = ("Achievement earned: |cff40ff40%s|r (+%d)"):format(nm, pts)
    Print(msg)
    if (RepriseHC.GetShowToGuild()) then
      SendChatMessage(msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""), "GUILD")
    end
    SyncBroadcastAward(id, nm, pts)
  end
end

local function __RHC_Ach_OnEvent(event, ...)
  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    C_Timer.After(0, function() UpdateInstanceState() end)
    C_Timer.After(1.0, function()
      if RepriseHC.PrimeProfessionBaseline then
        RepriseHC.PrimeProfessionBaseline()
      end
      if RepriseHC.IsGuildAllowed and RepriseHC.IsGuildAllowed() then
        if RepriseHC.AchievementTesting then
          local level = UnitLevel("player") or 1
          if RepriseHC.Ach_AwardLevelsUpTo then RepriseHC.Ach_AwardLevelsUpTo(level) end
          if RepriseHC.Ach_CheckProfessions then RepriseHC.Ach_CheckProfessions(true) end
          if RepriseHC.Ach_CheckSpeedrunOnDing then RepriseHC.Ach_CheckSpeedrunOnDing(math.floor(level / 10) * 10) end
          TryGuildFirstsIfReady()
        end
      end
    end)
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    OnCombatLogEvent()
  elseif event == "PLAYER_LEVEL_UP" then
    local level = ...
    if RepriseHC.IsGuildAllowed and RepriseHC.IsGuildAllowed() then
      if RepriseHC.Ach_AwardLevelsUpTo then RepriseHC.Ach_AwardLevelsUpTo(level or UnitLevel("player") or 1) end
      if RepriseHC.Ach_CheckSpeedrunOnDing then RepriseHC.Ach_CheckSpeedrunOnDing(level or UnitLevel("player") or 1) end
      TryGuildFirstsIfReady(level)
    end
  elseif event == "TIME_PLAYED_MSG" then
    local total = ...
    AwardSpeedrunIfEligible(total or 0)
  elseif event == "SKILL_LINES_CHANGED" then
    if RepriseHC.IsGuildAllowed and RepriseHC.IsGuildAllowed() and RepriseHC.Ach_CheckProfessions then
      RepriseHC.Ach_CheckProfessions()
    end
  elseif event == "PLAYER_DEAD" then
    -- No gate here: we already handle routing/retries inside CaptureDeath()
    CaptureDeath()
  elseif event == "QUEST_TURNED_IN" then
    local questID = ...
    if RepriseHC.IsGuildAllowed and questID then
      RepriseHC.Ach_CheckQuest(questID)
    end
  -- elseif event == "PLAYER_GUILD_UPDATE" then
  --   C_Timer.After(0.5, function() TryGuildFirstsIfReady() end)
  end
end

RepriseHC.RegisterEvent("PLAYER_ENTERING_WORLD", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("PLAYER_ENTERING_WORLD")
RepriseHC.RegisterEvent("ZONE_CHANGED_NEW_AREA", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("ZONE_CHANGED_NEW_AREA")
RepriseHC.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("COMBAT_LOG_EVENT_UNFILTERED")
RepriseHC.RegisterEvent("PLAYER_LEVEL_UP", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("PLAYER_LEVEL_UP")
RepriseHC.RegisterEvent("TIME_PLAYED_MSG", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("TIME_PLAYED_MSG")
RepriseHC.RegisterEvent("SKILL_LINES_CHANGED", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("SKILL_LINES_CHANGED")
RepriseHC.RegisterEvent("PLAYER_DEAD", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("PLAYER_DEAD")
RepriseHC.RegisterEvent("QUEST_TURNED_IN", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("QUEST_TURNED_IN")
RepriseHC.RegisterEvent("PLAYER_GUILD_UPDATE", __RHC_Ach_OnEvent); RepriseHC._EnsureEvent("PLAYER_GUILD_UPDATE")
