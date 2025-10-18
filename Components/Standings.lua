local GROUPS = {
  "Rallying Cry of the Dragonslayer","Warchief's Blessing","Spirit of Zandalar","Songflower Serenade",
  "Mol'dar's Moxie","Slip'kik's Savvy","Fengus' Ferocity","Darkmoon Faire"
}

local function DB_SAFE()
  local db = RepriseHC.DB and RepriseHC.DB() or nil
  if not db then return nil end
  db.groupAssignments = db.groupAssignments or {}  -- [characterKey] = group name
  db.characters       = db.characters or {}        -- [characterKey] = { points=..., class=..., ... }
  db.deathLog         = db.deathLog or {}          -- array of { name/playerKey, ... }
  return db
end

local function MyPoints()
  local db = DB_SAFE(); if not db then return 0 end
  local me = db.characters[RepriseHC.PlayerKey()]
  return tonumber(me and me.points) or 0
end

-- Normalize for comparisons
local function _norm(s)
  if not s then return nil end
  return tostring(s):gsub("%s+", ""):lower()
end

-- True if this playerKey is present in the death log
local function IsDead(playerKey)
  local db = DB_SAFE(); if not db then return false end
  local wanted = _norm(playerKey)
  for _, d in ipairs(db.deathLog) do
    local k = _norm(d.playerKey or d.name)
    if k and k == wanted then return true end
  end
  return false
end

local GROUP_SET = (function()
  local t = {}
  for _, g in ipairs(GROUPS) do t[g] = true end
  return t
end)()

-- Build totals (excluding dead) and member lists (including dead)
local function CalcGroupStandings()
  local db = DB_SAFE(); if not db then return nil, nil end
  local totals  = {}
  local members = {}
  for _, g in ipairs(GROUPS) do totals[g] = 0; members[g] = {} end

  -- Iterate over assignments so members with 0 points still appear
  for key, g in pairs(db.groupAssignments) do
    if GROUP_SET[g] then
      local char  = db.characters[key]
      local pts   = tonumber(char and char.points) or 0
      local dead  = IsDead(key)
      if not dead then
        totals[g] = totals[g] + pts   -- only alive add to totals
      end
      table.insert(members[g], { key = key, points = pts, dead = dead })
    end
  end

  -- Sort members by points desc
  for _, g in ipairs(GROUPS) do
    table.sort(members[g], function(a,b) return a.points > b.points end)
  end

  return totals, members
end

local function SetMyGroup(groupName)
  local db = DB_SAFE(); if not db then return end
  local ok = false
  for _, g in ipairs(GROUPS) do if g == groupName then ok = true; break end end
  if not ok then return end

  db.groupAssignments[RepriseHC.PlayerKey()] = groupName
  if RepriseHC.Print then
    RepriseHC.Print(("You joined %s (+%d pts)."):format(groupName, MyPoints()))
  end
  if UI and UI.Refresh then UI:Refresh() end
end

-- ===== Dropdown =====
local function EnsureDropdown(page, y)
  if page._groupDropdown then
    local txt = _G[page._groupDropdown:GetName().."Text"]
    if txt then
      txt:SetWidth(280 - 40)
      txt:SetJustifyH("CENTER")
      txt:SetWordWrap(false)
    end
    page._groupDropdown._refresh()
    return page._groupDropdown
  end

  local dd = CreateFrame("Frame", "RepriseHC_GroupDropdown", page, "UIDropDownMenuTemplate")
  dd:SetPoint("TOP", page, "TOP", 0, y)

  dd.Label = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  dd.Label:SetPoint("BOTTOM", dd, "TOP", 0, 8)  -- extra top padding
  dd.Label:SetJustifyH("CENTER")
  dd.Label:SetText("Select Group")

  local desiredWidth = 280
  UIDropDownMenu_SetWidth(dd, desiredWidth)
  local txt = _G[dd:GetName().."Text"]
  if txt then
    txt:SetWidth(desiredWidth - 40)
    txt:SetJustifyH("CENTER")
    txt:SetWordWrap(false)
  end

  dd._init = function(self, level)
    if level ~= 1 then return end
    local function onClick(btn)
      UIDropDownMenu_SetSelectedValue(dd, btn.value)
      SetMyGroup(btn.value)
    end
    for _, g in ipairs(GROUPS) do
      local info = UIDropDownMenu_CreateInfo()
      info.text, info.value, info.func = g, g, onClick
      UIDropDownMenu_AddButton(info, level)
    end
  end

  dd._refresh = function()
    local db = DB_SAFE()
    local current = db and db.groupAssignments[RepriseHC.PlayerKey()] or nil
    UIDropDownMenu_SetSelectedValue(dd, current)
    UIDropDownMenu_SetText(dd, current or "Choose…")
  end

  UIDropDownMenu_Initialize(dd, dd._init)
  dd._refresh()

  page._groupDropdown = dd
  return dd
end

-- Format points in tooltip: red + skull if dead
local function FormatPointsTooltip(points, dead)
  local txt = ("%d pts"):format(points or 0)
  if dead then
    local skull = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12:12:0:0|t"
    return ("|cffff4040%s|r %s"):format(txt, skull), 1, 0.35, 0.35
  end
  return txt, 0.9, 0.9, 0.9
end

-- Tooltip for members of a group
local function ShowGroupTooltip(self, groupName, members)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(("%s Members"):format(groupName), 1, 0.82, 0)
  if not members or #members == 0 then
    GameTooltip:AddLine("No members yet.", 0.9, 0.9, 0.9)
  else
    for i, m in ipairs(members) do
      local ptsTxt, r, g, b = FormatPointsTooltip(m.points, m.dead)
      GameTooltip:AddLine(("%d) %s  —  %s"):format(i, m.key, ptsTxt), r, g, b)
    end
  end
  GameTooltip:Show()
end

-- ===== Renderer =====
function RepriseHC.RenderStandings(page)
  local y = -10
  y = RepriseHC.Header(page, "Group Standings", y)

  -- clear old rows if re-rendering
  if page._rows then
    for _, r in ipairs(page._rows) do r:Hide(); r:SetParent(nil) end
  end
  page._rows = {}

  -- centered dropdown near the top with padding
  local dd = EnsureDropdown(page, y - 25)
  table.insert(page._rows, dd.Label)

  y = y - 60  -- space after dropdown

  local totals, members = CalcGroupStandings()
  totals  = totals  or {}
  members = members or {}

  -- header
  local hGroup = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hGroup:SetPoint("TOPLEFT", 12, y - 6); hGroup:SetText("Group")

  local hPts = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hPts:SetPoint("TOPRIGHT", -12, y - 6); hPts:SetText("Total Points")

  table.insert(page._rows, hGroup); table.insert(page._rows, hPts)
  y = y - 22

  -- rows
  for _, g in ipairs(GROUPS) do
    local row = CreateFrame("Frame", nil, page)
    row:SetPoint("TOPLEFT", 8, y)
    row:SetSize(page:GetWidth() - 16, 18)

    local nameFS = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFS:SetPoint("LEFT", row, "LEFT", 4, 0)
    nameFS:SetText(g)

    local ptsFS = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ptsFS:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    ptsFS:SetText(tostring(totals[g] or 0))

    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
      ShowGroupTooltip(self, g, members[g])
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    table.insert(page._rows, row)
    table.insert(page._rows, nameFS)
    table.insert(page._rows, ptsFS)

    y = y - 22
  end

  if dd and dd._refresh then dd._refresh() end
  return -y + 12
end
