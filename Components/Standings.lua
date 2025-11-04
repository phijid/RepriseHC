local GROUPS = {
  "Rallying Cry of the Dragonslayer","Warchief's Blessing","Spirit of Zandalar","Songflower Serenade",
  "Mol'dar's Moxie","Slip'kik's Savvy","Fengus' Ferocity","Sayge's Dark Fortune"
}

local function DB_SAFE()
  local db = RepriseHC.DB and RepriseHC.DB() or nil
  if not db then return nil end
  db.groupAssignments = db.groupAssignments or {}  -- [characterKey] = { group=..., dbVersion=... }
  db.characters       = db.characters or {}        -- [characterKey] = { points=..., class=..., ... }
  db.deathLog         = db.deathLog or {}          -- array of { name/playerKey, ... }
  return db
end

local function ExtractGroup(raw)
  if type(raw) == "table" then
    local group = raw.group or raw.name or raw.value
    if type(group) == "string" then
      group = group:gsub("^%s+", ""):gsub("%s+$", "")
      if group == "" then group = nil end
    end
    return group, tonumber(raw.dbVersion or raw.dbv) or 0
  elseif type(raw) == "string" then
    local group = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if group == "" then group = nil end
    return group, 0
  end
  return nil, 0
end

local function CurrentDbVersion()
  if RepriseHC and RepriseHC.GetDbVersion then
    local ok = tonumber(RepriseHC.GetDbVersion())
    if ok and ok > 0 then return ok end
  end
  return 0
end

local function CurrentGroupFor(playerKey)
  local db = DB_SAFE()
  if not db then return nil end
  local raw = db.groupAssignments[playerKey]
  return select(1, ExtractGroup(raw))
end

local function MyPoints()
  local db = DB_SAFE(); if not db then return 0 end
  local me = db.characters[RepriseHC.PlayerKey()]
  return tonumber(me and me.points) or 0
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
  local dbVersion = CurrentDbVersion()

  for key, raw in pairs(db.groupAssignments) do
    local g, entryVersion = ExtractGroup(raw)
    if g and GROUP_SET[g] then
      if dbVersion == 0 or entryVersion == 0 or entryVersion == dbVersion then
        local char  = db.characters[key]
        local pts   = tonumber(char and char.points) or 0
        local dead  = RepriseHC.IsDead(key)
        if not dead then
          totals[g] = totals[g] + pts   -- only alive add to totals
        end
        table.insert(members[g], { key = key, points = pts, dead = dead })
      end
    end
  end

  -- Sort members by points desc
  for _, g in ipairs(GROUPS) do
    table.sort(members[g], function(a,b) return a.points > b.points end)
  end

  return totals, members
end

-- Safe check: is the Blizzard dropdown menu currently open for this dropdown?
local function IsMenuOpenFor(dd)
  local open = rawget(_G, "UIDROPDOWNMENU_OPEN_MENU")
  if open and open == dd then return true end
  local list1 = rawget(_G, "DropDownList1")
  if list1 and list1.IsShown and list1:IsShown() then return true end
  return false
end

local function SetMyGroup(groupName)
  local db = DB_SAFE(); if not db then return end
  local ok = false
  for _, g in ipairs(GROUPS) do if g == groupName then ok = true; break end end
  if not ok then return end

  local playerKey = RepriseHC.PlayerKey and RepriseHC.PlayerKey() or nil
  if not playerKey or playerKey == "" then return end
  local existing = CurrentGroupFor(playerKey)
  if existing == groupName then return end
  local stamp = (GetServerTime and GetServerTime()) or time()
  local version = CurrentDbVersion()
  if version and version <= 0 then version = nil end
  local changed, minorVersion = true, nil
  if RepriseHC.UpdateGroupAssignment and playerKey then
    changed, minorVersion = RepriseHC.UpdateGroupAssignment(playerKey, groupName, { when = stamp, dbVersion = version })
  else
    db.groupAssignments[playerKey or "?"] = { group = groupName, when = stamp, dbVersion = version or 0 }
  end

  if changed and RepriseHC.Print then
    RepriseHC.Print(("You joined %s (+%d pts)."):format(groupName, MyPoints()))
  end
  if changed and RepriseHC.Comm_Send and playerKey then
    local baseName = select(1, UnitName("player")) or playerKey
    local payload = {
      playerKey = playerKey,
      name = baseName,
      group = groupName,
      when = stamp,
    }
    if version then
      payload.dbVersion = version
      payload.dbv = version
    end
    if minorVersion and minorVersion > 0 then
      payload.groupVersion = minorVersion
    end
    RepriseHC.Comm_Send("GROUP", payload)
  end
  if changed and RepriseHC.RefreshUI then
    RepriseHC.RefreshUI()
  end
  if UI and UI.Refresh then UI:Refresh() end
end

-- ===== Dropdown =====
local function CenterDropdownText(dd)
  if not dd or not dd.GetName then return end
  local txt = dd.Text or _G[dd:GetName().."Text"]
  if not txt then return end
  if UIDropDownMenu_JustifyText then pcall(UIDropDownMenu_JustifyText, dd, "CENTER") end
  txt:SetJustifyH("CENTER")
  txt:SetWordWrap(false)
  txt:ClearAllPoints()
  txt:SetPoint("LEFT", dd, "LEFT", 25, 2)
  txt:SetPoint("RIGHT", dd, "RIGHT", -40, 2)
end

local function EnsureDropdown(page, y)
  if page._groupDropdown then
    local txt = _G[page._groupDropdown:GetName().."Text"]
    if txt then
      txt:SetWidth(280 - 40)
      txt:SetJustifyH("CENTER")
      txt:SetWordWrap(false)
    end
    if not IsMenuOpenFor(page._groupDropdown) then
      page._groupDropdown._refresh()
    end
    CenterDropdownText(page._groupDropdown)
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
  CenterDropdownText(dd)
  if dd.HookScript then
    dd:HookScript("OnShow", function() CenterDropdownText(dd) end)
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
    local current = nil
    if RepriseHC.PlayerKey then
      current = CurrentGroupFor(RepriseHC.PlayerKey())
    end
    UIDropDownMenu_SetSelectedValue(dd, current)
    UIDropDownMenu_SetText(dd, current or "Choose...")
    CenterDropdownText(dd)
  end

  UIDropDownMenu_Initialize(dd, dd._init)
  dd._refresh()

  page._groupDropdown = dd
  return dd
end

-- Format points in tooltip: red + RepriseHC.skull if dead
local function FormatPointsTooltip(points, dead)
  local txt = ("%d pts"):format(points or 0)
  if dead then    
    return ("|cffff4040%s|r %s"):format(txt, RepriseHC.skull), 1, 0.35, 0.35
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
      GameTooltip:AddLine(("%d) %s  -  %s"):format(i, m.key, ptsTxt), r, g, b)
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

  -- determine my current group to highlight its row
  local myGroup = nil
  if RepriseHC.PlayerKey then
    myGroup = CurrentGroupFor(RepriseHC.PlayerKey())
  end

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

    -- background highlight for the player's group
    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    if g == myGroup then
      -- subtle gold highlight to indicate "your" group
      bg:SetColorTexture(1, 0.82, 0, 0.18)
    else
      -- no highlight for other rows
      bg:SetColorTexture(0, 0, 0, 0)
    end

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

  -- Avoid touching dropdown selection text while a dropdown menu is open,
  -- since some UI updates can cause the menu to close immediately.
  if dd and dd._refresh and not IsMenuOpenFor(dd) then dd._refresh() end
  return -y + 12
end


