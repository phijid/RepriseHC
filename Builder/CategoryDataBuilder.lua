local faction = (UnitFactionGroup and select(1, UnitFactionGroup("player"))) or "Alliance"

function RepriseHC.PlayerKey()
  local name, realm = UnitName("player")
  realm = realm or GetRealmName()
  if realm and realm ~= "" then name = name.."-"..realm end
  return name
end

local function DungeonList()
  if RepriseHC and RepriseHC.Ach_DungeonList then
    local list = RepriseHC.Ach_DungeonList()
    if list and #list > 0 then return list end
  end
  local ml = (RepriseHC and RepriseHC.DUNGEON_MINLEVEL) or {}
  local work = {}
  for d,info in pairs(ml) do 
    if (not info.faction) or (faction == info.faction) then
      if (info.minLevel <= ((RepriseHC.GetLevelCap and RepriseHC.GetLevelCap()) or (RepriseHC.levelCap or 60))) then
        table.insert(work, {d=d,l=info.minLevel}) 
      end
    end
  end
  table.sort(work, function(a,b) if a.l==b.l then return a.d<b.d end return a.l<b.l end)
  local out = {}; for _,w in ipairs(work) do table.insert(out, w.d) end; return out
end
local function DungeonPoints(lookupDungeon)
  if RepriseHC and RepriseHC.Ach_GetDungeonPoints then return RepriseHC.Ach_GetDungeonPoints(lookupDungeon) end
  return 0
end
local function DungeonBossName(lookupDungeon)
  if RepriseHC and RepriseHC.Ach_GetDungeonBossName then return RepriseHC.Ach_GetDungeonBossName(lookupDungeon) end
  return lookupDungeon
end

-- Catalog build

local GF_POINTS = { ALL=100, CLASS=75, RACE=75 }

function RepriseHC.BuildCatalog()
  local cat = { ["Level Milestones"]={}, ["Speedrun"]={}, ["Quest Milestones"]={}, ["Professions"]={}, ["Dungeons"]={}, ["Guild First"]={} }

  for _, lvl in ipairs(RepriseHC.levels) do
    if lvl <= RepriseHC.MaxMilestone() then
      table.insert(cat["Level Milestones"], { id="LEVEL_"..lvl, name="Reached Level "..lvl, points=lvl*4 })
    end
  end
  for skill in pairs(RepriseHC.professions) do
    for _, t in ipairs(RepriseHC.profThreshold) do
      if (t.levelRequirement <= ((RepriseHC.GetLevelCap and RepriseHC.GetLevelCap()) or (RepriseHC.levelCap or 60))) then
        local title = (t.threshold==75 and "Apprentice") or (t.threshold==150 and "Journeyman") or (t.threshold==225 and "Expert") or "Artisan"
        local pts   = (t.threshold==75 and 30) or (t.threshold==150 and 60) or (t.threshold==225 and 90) or 120
        local displayName = string.format("%s %s - %d", skill, title, t.threshold)
        table.insert(cat["Professions"], { id=skill.."_"..t.threshold, name=displayName, points=pts, skill=skill, threshold=t.threshold, rank=title })
      end
    end
  end

  local ordered = DungeonList()
  for _, lookup in ipairs(ordered) do
    local id = "DUNGEON_"..lookup
    local points = DungeonPoints(lookup) or 0
    local bossTitle = "Defeat " .. (DungeonBossName(lookup) or lookup)
    table.insert(cat["Dungeons"], { id=id, name=bossTitle, points=points, dungeon=lookup })
  end

  -- Guild First (faction-aware)
  local locks = (RepriseHC.DB().guildFirsts or {})
  local faction = (UnitFactionGroup and select(1, UnitFactionGroup("player"))) or "Alliance"
  -- if RepriseHC and RepriseHC.Ach_GuildFirstOptions then
  --   local opts = RepriseHC.Ach_GuildFirstOptions(faction)
  --   table.insert(cat["Guild First"], { id="FIRST_60", name="Guild First 60", points=GF_POINTS.ALL, gfType="ALL", gfKey="0", locked=locks["FIRST_60"] ~= nil, winner=locks["FIRST_60"] })
  --   for _, cls in ipairs(opts.classes or {}) do
  --     local id = "FIRST_60_CLASS_"..cls:upper()
  --     table.insert(cat["Guild First"], { id=id, name="Guild First 60 "..cls, points=GF_POINTS.CLASS, gfType="CLASS", gfKey=cls, locked=locks[id] ~= nil, winner=locks[id] })
  --   end
  --   for _, race in ipairs(opts.races or {}) do
  --     local id = "FIRST_60_RACE_"..race:upper():gsub("%s","_")
  --     table.insert(cat["Guild First"], { id=id, name="Guild First 60 "..race, points=GF_POINTS.RACE, gfType="RACE", gfKey=race, locked=locks[id] ~= nil, winner=locks[id] })
  --   end
  -- end

  if RepriseHC and RepriseHC.Ach_GuildFirstOptions then

    local opts = RepriseHC.Ach_GuildFirstOptions(faction)

    -- Build Guild First cards for all defined level caps (by index), so old caps remain visible
    local caps = {}
    if type(RepriseHC.levelCap) == "table" then
      for k,v in pairs(RepriseHC.levelCap) do
        table.insert(caps, { idx = tonumber(k) or 0, cap = tonumber(v) or 0 })
      end
      table.sort(caps, function(a,b) return a.idx < b.idx end)
    else
      table.insert(caps, { idx = 0, cap = tonumber(RepriseHC.levelCap) or 0 })
    end

    -- Establish a consistent ordering index for classes and races from options
    local classOrder = {}
    if opts and opts.classes then
      for i, cls in ipairs(opts.classes) do classOrder[cls] = i end
    end
    local raceOrder = {}
    if opts and opts.races then
      for i, race in ipairs(opts.races) do raceOrder[race] = i end
    end

    -- Overall caps
    for _, entry in ipairs(caps) do
      local capVal = entry.cap
      if capVal and capVal > 0 then
        local id_all = "FIRST_" .. capVal
        table.insert(cat["Guild First"], {
          id       = id_all,
          name     = "Guild First " .. capVal,
          points   = GF_POINTS.ALL,
          gfType   = "ALL",
          gfKey    = "0",
          gfOrder  = 0,
          levelCap = capVal,
          locked   = locks[id_all] ~= nil,
          winner   = locks[id_all],
        })
      end
    end

    -- Class caps across all caps
    if (opts) then
      for _, cls in ipairs(opts.classes or {}) do
        local ord = classOrder[cls] or 999
        local clsKey = cls:upper():gsub("%s","_")
        for _, entry in ipairs(caps) do
          local capVal = entry.cap
          if capVal and capVal > 0 then
            local id = "FIRST_" .. capVal .. "_CLASS_" .. clsKey
            table.insert(cat["Guild First"], {
              id       = id,
              name     = "Guild First " .. capVal .. " " .. cls,
              points   = GF_POINTS.CLASS,
              gfType   = "CLASS",
              gfKey    = cls,
              gfOrder  = ord,
              levelCap = capVal,
              locked   = locks[id] ~= nil,
              winner   = locks[id],
            })
          end
        end
      end
    end

    -- Race caps across all caps
    if (opts) then
      for _, race in ipairs(opts.races or {}) do
        local ord = raceOrder[race] or 999
        local raceKey = race:upper():gsub("%s","_")
        for _, entry in ipairs(caps) do
          local capVal = entry.cap
          if capVal and capVal > 0 then
            local id = "FIRST_" .. capVal .. "_RACE_" .. raceKey
            table.insert(cat["Guild First"], {
              id       = id,
              name     = "Guild First " .. capVal .. " " .. race,
              points   = GF_POINTS.RACE,
              gfType   = "RACE",
              gfKey    = race,
              gfOrder  = ord,
              levelCap = capVal,
              locked   = locks[id] ~= nil,
              winner   = locks[id],
            })
          end
        end
      end
    end
  end

  -- Quest Milestones from core (faction-aware)
  local qlist = {}
  if RepriseHC and RepriseHC.Ach_QuestList then
    qlist = RepriseHC.Ach_QuestList(faction) or {}
  end
  table.sort(qlist, function(a,b) if (a.levelCap or 0) == (b.levelCap or 0) then return (a.name or "") < (b.name or "") end return (a.levelCap or 0) < (b.levelCap or 0) end)
  for _,q in ipairs(qlist) do

    if (q.levelCap <= RepriseHC.maxLevelPerCap) then
      table.insert(cat["Quest Milestones"], { id=q.id, name=q.name, points=q.points, levelCap=q.levelCap, questId=q.questId })
    end

  end

  -- Speedrun 6 cards
  local sr = (RepriseHC and RepriseHC.Ach_ListSpeedruns and RepriseHC.Ach_ListSpeedruns())
  table.sort(sr, function(a,b) return (a.level or 0) < (b.level or 0) end)
  
  for _, it in ipairs(sr) do
    if (it.level) <= RepriseHC.MaxMilestone() then
      local id  = it.id or ("SPEED_"..(it.level or 0))
      local pts = it.points or ((it.level or 0) * 4)
      local nm  = it.name or ("Reach level "..(it.level or 0).." by "..(it.hours or 0).." hours")
      table.insert(cat["Speedrun"], { id=id, name=nm, points=pts, level=it.level, hours=it.hours })
    end
  end

  return cat
end
