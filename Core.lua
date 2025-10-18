RepriseHC = {}
RepriseHC.name = "RepriseHC"
RepriseHC.version = "0.2.0a"
RepriseHC.allowedGuilds = { ["Reprise"] = true, ["RepriseHC"] = true, ["Frontier"] = true, ["Midnight Guardians"] = true }

-- ===== Useful to be global ===== 

RepriseHC.levelCap = 20
RepriseHC.levels = {10,20,30,40,50,60}
RepriseHC.showToGuild = true

RepriseHC.speedrunThresholds = {
  [10] = 2,   -- reach 10 under 2 hours
  [20] = 12,  -- reach 20 under 12 hours
  [30] = 27,  -- reach 30 under 27 hours
  [40] = 50,  -- reach 40 under 50 hours
  [50] = 81,  -- reach 50 under 81 hours
  [60] = 120, -- reach 60 under 120 hours
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

-- RepriseHC.profThreshold = {75,150,225,300}

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

--Fuck it ill figure this out later, ipairs and pairs are stupid -_- 
RepriseHC.navigationOrder = { 
  "leaderboard", 
  "standing",
  "level", 
  "speedrun", 
  "quest", 
  "prof", 
  "dungeons", 
  "guildFirst", 
  "deathlog"
 }

-- ===============================

local Core = CreateFrame("Frame", "RepriseHC_Core")
Core:RegisterEvent("ADDON_LOADED")
Core:RegisterEvent("PLAYER_LOGIN")

function RepriseHC.Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff00c0ffRepriseHC:|r " .. (msg or ""))
end

function RepriseHC.GetPlayerKey()
  local name, realm = UnitName("player")
  realm = realm or GetRealmName()
  return name .. "-" .. realm
end

function RepriseHC.IsGuildAllowed()
  local g = GetGuildInfo("player")

  if not g then
    return true
  end

  return g and RepriseHC.allowedGuilds[g] or false
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

-- Helpers to read display names
function RepriseHC.ClassName(eclass)
  local v = RepriseHC.class[eclass or ""]
  if type(v)=="table" then return v.name end
  return v or eclass or "Class"
end

function RepriseHC.RaceName(erace)
  local v = RepriseHC.race[erace or ""]
  if type(v)=="table" then return v.name end
  return v or erace or "Race"
end

function RepriseHC.GetSelectedGroupKey()
  -- always prefer persisted value
  local cfg = RepriseHCAchievementsDB and RepriseHCAchievementsDB.config
  if cfg and cfg.selectedGroupKey ~= nil then
    return cfg.selectedGroupKey
  end
  -- fallback to runtime cache
  return RepriseHC.runtime.groupKey
end

function RepriseHC.SetSelectedGroupKey(key)
  RepriseHCAchievementsDB = RepriseHCAchievementsDB or {}
  RepriseHCAchievementsDB.config = RepriseHCAchievementsDB.config or {}
  RepriseHCAchievementsDB.config.selectedGroupKey = key
  RepriseHC.runtime.groupKey = key
end

-- Make the single source of truth for the death log the DB
function RepriseHC.GetDeathLog()
  RepriseHCAchievementsDB = RepriseHCAchievementsDB or {}
  RepriseHCAchievementsDB.deathLog = RepriseHCAchievementsDB.deathLog or {}
  return RepriseHCAchievementsDB.deathLog
end

-- If you append to the death log anywhere, use this
function RepriseHC.PushDeath(entry)
  local dl = RepriseHC.GetDeathLog()
  dl[#dl+1] = entry
end

-- Hard reset helper (secret)
local function HardResetDB()
  if not RepriseHCAchievementsDB then return end
  -- wipe all character points & achievements + guild firsts
  RepriseHCAchievementsDB.characters = {}
  RepriseHCAchievementsDB.guildFirsts = {}
  RepriseHCAchievementsDB.deathLog = {}
  RepriseHCAchievementsDB.groupAssignments = {}

  RepriseHC.Print("|cffff6060Cleaned!|r")

  C_Timer.After(0, function()
    if RepriseHC_UI and RepriseHC_UI:IsShown() then
      if RepriseHC.UIRefresh then RepriseHC.UIRefresh() end
    end
  end)

end

function RepriseHC.DB() return RepriseHCAchievementsDB end



-- ========= Centralized Event Dispatcher =========
-- All other modules should register their interest via RepriseHC.RegisterEvent(event, fn)
RepriseHC._eventHandlers = RepriseHC._eventHandlers or {}
function RepriseHC.RegisterEvent(event, fn)
  if not event or type(fn) ~= "function" then return end
  local t = RepriseHC._eventHandlers[event]
  if not t then t = {}; RepriseHC._eventHandlers[event] = t end
  table.insert(t, fn)
end
local _CoreEventFrame = CreateFrame("Frame", "RepriseHC_EventBus")
local _registered = {}
local function _ensureRegistered(ev)
  if _registered[ev] then return end
  _CoreEventFrame:RegisterEvent(ev)
  _registered[ev] = true
end
-- Allow modules to request events even before PLAYER_LOGIN
function RepriseHC._EnsureEvent(ev) _ensureRegistered(ev) end

_CoreEventFrame:SetScript("OnEvent", function(_, event, ...)
  local list = RepriseHC._eventHandlers[event]
  if list then
    for i=1,#list do
      local ok, err = pcall(list[i], event, ...)
      if not ok and RepriseHC.Print then RepriseHC.Print(("Handler error for %s: %s"):format(event, tostring(err))) end
    end
  end
end)

-- Register the common set of events used across modules
local __ALL_EVENTS = {
  "ADDON_LOADED","PLAYER_LOGIN","PLAYER_ENTERING_WORLD","ZONE_CHANGED_NEW_AREA","COMBAT_LOG_EVENT_UNFILTERED",
  "PLAYER_LEVEL_UP","TIME_PLAYED_MSG","CHAT_MSG_ADDON","SKILL_LINES_CHANGED","PLAYER_DEAD","QUEST_TURNED_IN",
  "PLAYER_GUILD_UPDATE","GUILD_ROSTER_UPDATE","TRADE_REQUEST","TRADE_SHOW","AUCTION_HOUSE_SHOW",
  "INSPECT_READY","UNIT_NAME_UPDATE"
}
for _, ev in ipairs(__ALL_EVENTS) do _ensureRegistered(ev) end

-- Ensure addon message prefix is registered once (used by Achievements & UI)
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
  C_ChatInfo.RegisterAddonMessagePrefix("RepriseHC_ACH")
end

Core:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == RepriseHC.name then
    if not RepriseHCAchievementsDB then
      RepriseHCAchievementsDB = {
        characters = {}, 
        guildFirsts = {}, 
		    config = {},
        deathLog = {},
        groupAssignments = {},
      }
    else
      RepriseHCAchievementsDB.config = RepriseHCAchievementsDB.config or {}
    end
    -- Source of truth is the constant above in this file
    RepriseHCAchievementsDB.config.levelCap = RepriseHC.levelCap or 60

  elseif event == "PLAYER_LOGIN" then
    C_ChatInfo.RegisterAddonMessagePrefix("RepriseHC_ACH")
    if not RepriseHC.IsGuildAllowed() then
      RepriseHC.Print("|cffff6060Disabled: You must be in the guild 'Reprise' or 'RepriseHC' for this addon to work.|r")
    else
      RepriseHC.Print(("Core loaded v%s"):format(RepriseHC.version))
    end
  end
end)

-- Slash: /rhc + secret reset
SLASH_REPRISEHC1 = "/reprisehc"
SLASH_REPRISEHC2 = "/rhc"
SlashCmdList["REPRISEHC"] = function(msg)
  msg = (msg or ""):gsub("^%s+",""):gsub("%s+$","")
  local lower = msg:lower()

  if lower == "on" then
    RepriseHC._tradeEnabled = true
    RepriseHC.Print("Trade, mail, auction house protection enabled.")
  elseif lower == "off" then
    RepriseHC._tradeEnabled = false
    RepriseHC.Print("Trade, mail, auction house protection disabled.")
  elseif lower == "reload" then
    if RepriseHC.RebuildGuildCache then RepriseHC.RebuildGuildCache() end
    RepriseHC.Print("Guild roster refreshed.")
  elseif lower:match("^reset%s+all$") then
    HardResetDB()
  else
    RepriseHC.Print("Commands: /rhc on, /rhc off, /rhc reload, |cffa0a0a0/rhc reset all|r (SECRET)")
  end
end

