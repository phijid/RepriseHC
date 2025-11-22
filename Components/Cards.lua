local function OpenEarners(achId, titleText)
  RepriseHCUiDB._earners = { id = achId, title = titleText or "Achievement" }
  RepriseHCUiDB._lastNav = RepriseHCUiDB.nav or "leaderboard"
  RepriseHC.SelectNav("earners")
end

local function CloseEarners()
  local back = RepriseHCUiDB._lastNav or "leaderboard"
  RepriseHCUiDB._earners = nil
  RepriseHC.SelectNav(back)
end

-- Render earners list as a full page
function RepriseHC.RenderEarners(page)
  local e = RepriseHCUiDB._earners
  local y = -10
  if not e or not e.id then
    y = RepriseHC.Header(page, "Earners", y)
    local fs = page:CreateFontString(nil,"OVERLAY","GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y)
    fs:SetText("No achievement selected.")
    return -y + 40
  end

  local title = e.title or "Achievement"
  y = RepriseHC.Header(page, title, y)

  -- Back button
  local back = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  back:SetPoint("TOPRIGHT", -10, y + 20)
  back:SetSize(90, 22)
  back:SetText("Back")
  back:SetScript("OnClick", CloseEarners)

  local earners = {}
  if RepriseHC and RepriseHC.Ach_GetEarners then
    earners = RepriseHC.Ach_GetEarners(e.id) or {}
  end
  if #earners == 0 then
    local fs = page:CreateFontString(nil,"OVERLAY","GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y)
    fs:SetText("No one has earned this yet.")
    return -y + 40
  end

  -- Table headers
  local headers = {"#", "Player", "When", "Points"}
  local widths  = {30, 300, 160, 80}
  local x = 6
  for i,h in ipairs(headers) do
    local fs = page:CreateFontString(nil,"OVERLAY","GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(h); fs:SetTextColor(1,.82,0,1)
    x = x + widths[i] + 8
  end

  y = y - 22
  for i,e in ipairs(earners) do
    local x = 6
    local cols = {
      tostring(i),
      e.player or "?",
      (e.when and date("%b %d %H:%M", e.when) or ""),
      tostring(e.points or 0).." pts",
    }
    for ci,val in ipairs(cols) do
      local fs = page:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
      fs:SetPoint("TOPLEFT", x, y); fs:SetText(val)
      x = x + widths[ci] + 8
    end
    y = y - 18
  end

  return -y + 20
end

-- Card builder
local function MakeCard(parent, x, y, w, h, title, points, earned, locked, winner, achId)
  local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
  card:SetPoint("TOPLEFT", x, y); card:SetSize(w, h)
  card:SetBackdrop({
    bgFile="Interface\\Buttons\\WHITE8X8",
    edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true, tileSize=8, edgeSize=12,
    insets={left=3,right=3,top=3,bottom=3}
  })
  if earned then card:SetBackdropColor(0, 0.5, 0, 0.3) else card:SetBackdropColor(0,0,0,0.15) end

  local badge = CreateFrame("Frame", nil, card, "BackdropTemplate")
  badge:SetPoint("TOPRIGHT", -8, -8); badge:SetSize(80, 20)
  badge:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
    tile=true, tileSize=8, edgeSize=10, insets={left=2,right=2,top=2,bottom=2} })
  badge:SetBackdropColor(0,0,0,0.25)
  local badgeFS = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  badgeFS:SetPoint("CENTER"); badgeFS:SetText(("%d pts"):format(points or 0)); badgeFS:SetTextColor(1,0.96,0.41,1)

  if locked and not earned then
    local lock = card:CreateTexture(nil, "OVERLAY")
    lock:SetTexture("Interface\\GuildFrame\\GuildLogo-NoLogoSm")
    lock:SetPoint("TOPLEFT", 8, -8); lock:SetSize(16,16)
    card.lock = lock
  end

  local titleFS = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  local leftPad = (locked and not earned) and (10+18) or 10
  titleFS:SetPoint("TOPLEFT", leftPad, -10)
  titleFS:SetWidth(w - leftPad - 8 - badge:GetWidth() - 6)
  titleFS:SetJustifyH("LEFT"); titleFS:SetWordWrap(true); titleFS:SetNonSpaceWrap(true)
  titleFS:SetText(title or "")

  -- local cb = CreateFrame("CheckButton", nil, card, "UICheckButtonTemplate")
  -- cb:SetPoint("BOTTOMLEFT", 8, 10); cb:SetChecked(earned and true or false);
  -- -- Tint the check mark to yellow when shown
  -- local chk = cb:GetCheckedTexture(); if chk then chk:SetDesaturated(false); chk:SetVertexColor(1, 0.82, 0, 1) end
  -- local dis = cb:GetDisabledCheckedTexture(); if dis then dis:SetDesaturated(false); dis:SetVertexColor(1, 0.82, 0, 1) end
  -- local psh = cb:GetPushedTexture(); if psh then psh:SetDesaturated(false); psh:SetVertexColor(1, 0.82, 0, 1) end
  -- cb:EnableMouse(true)
  -- cb:SetScript("OnClick", function(self) self:SetChecked(earned and true or false) end)

    local cb = CreateFrame("CheckButton", nil, card, "UICheckButtonTemplate")
  cb:SetPoint("BOTTOMLEFT", 8, 10)
  cb:EnableMouse(true)

  if locked and not earned then
    cb:SetChecked(false)

    -- Keep the checkbox box visible
    local nor = cb:GetNormalTexture()
    if nor then
      nor:SetDesaturated(false)
      nor:SetVertexColor(1, 1, 1, 1)
      nor:Show()
    end

    -- Hide any checkmark visuals
    local chk = cb:GetCheckedTexture();            if chk  then chk:Hide() end
    local dis = cb:GetDisabledCheckedTexture();    if dis  then dis:Hide() end
    local psh = cb:GetPushedTexture();             if psh  then psh:Hide() end
    local hl  = cb:GetHighlightTexture();          if hl   then hl:SetAlpha(0.25) end

    -- Add a GREY X (slightly larger, sits cleanly in the box)
    local xTex = cb:CreateTexture(nil, "OVERLAY", nil, 1)
    xTex:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-NotReady")
    xTex:SetPoint("CENTER", cb, "CENTER", 0, 0)
    xTex:SetSize(17, 17)
    xTex:SetVertexColor(1, 0, 0, 1) -- bright red
    cb.xTex = xTex

    -- Ensure the border stays above the X
    nor:SetDrawLayer("OVERLAY", 2)

    cb:Disable()
    cb:EnableMouse(false)
    cb:SetScript("OnClick", nil)
  else

    -- Normal behavior for earned/not-earned
    cb:SetChecked(earned and true or false)
    local chk = cb:GetCheckedTexture();           if chk then chk:SetDesaturated(false); chk:SetVertexColor(1, 0.82, 0, 1) end
    local dis = cb:GetDisabledCheckedTexture();   if dis then dis:SetDesaturated(false); dis:SetVertexColor(1, 0.82, 0, 1) end
    local psh = cb:GetPushedTexture();            if psh then psh:SetDesaturated(false); psh:SetVertexColor(1, 0.82, 0, 1) end
    cb:SetScript("OnClick", function(self) self:SetChecked(earned and true or false) end)
  end

  local cbLabel = card:CreateFontString(nil,"OVERLAY","GameFontDisableSmall")
  cbLabel:SetPoint("LEFT", cb, "RIGHT", 2, 1)
  if locked and not earned then cbLabel:SetText("Locked") else cbLabel:SetText(earned and "Earned" or "Not earned") end

  if locked and not earned then card:SetBackdropColor(0.5, 0, 0, 0.3)  end

  -- Click to show earners list (internal page)
  if achId then
    card:SetScript("OnClick", function()
      OpenEarners(achId, title or "Achievement")
    end)
  end

  return y - h - 8
end

-- Category cards
local RANK_ORDER = { Apprentice=1, Journeyman=2, Expert=3, Artisan=4 }

local function earnedSet()
  local set = {}
  local char = (RepriseHC.DB() and RepriseHC.DB().characters and RepriseHC.DB().characters[RepriseHC.PlayerKey()]) or nil
  if char and char.achievements then for id in pairs(char.achievements) do set[id]=true end end
  return set
end

local function DebugCategory(catName, list, earnedLookup)
  if not (RepriseHC and RepriseHC.DebugAchievements and RepriseHC.DebugLogAchievements) then return end

  local earnedCount = 0
  for _, ach in ipairs(list) do
    if earnedLookup[ach.id] then
      earnedCount = earnedCount + 1
    end
  end

  local entries = {}
  if catName == "Speedrun" then
    for _, ach in ipairs(list) do
      table.insert(entries, string.format("L%s@%sh", tostring(ach.level or "?"), tostring(ach.hours or "?")))
    end
  elseif catName == "Level Milestones" then
    for _, ach in ipairs(list) do
      table.insert(entries, tostring(ach.id or ach.name or "?"))
    end
  elseif catName == "Quest Milestones" then
    for _, ach in ipairs(list) do
      table.insert(entries, string.format("%s (cap %s)", ach.name or (ach.id or "?"), tostring(ach.levelCap or "?")))
    end
  elseif catName == "Professions" then
    for _, ach in ipairs(list) do
      table.insert(entries, string.format("%s %s %s", ach.skill or "?", ach.rank or "?", tostring(ach.threshold or "?")))
    end
  elseif catName == "Guild First" then
    for _, ach in ipairs(list) do
      table.insert(entries, string.format("%s %s cap %s", ach.gfType or "?", ach.gfKey or "?", tostring(ach.levelCap or "?")))
    end
  end

  local orderText = (#entries > 0) and table.concat(entries, ", ") or "(no entries)"
  RepriseHC.DebugLogAchievements(string.format("[UI] Rendering %s panel: %d entries (%d earned). Order: %s", catName, #list, earnedCount, orderText))
end

function RepriseHC.RenderCategory(page, catName)
  local y = -10
  y = RepriseHC.Header(page, catName, y)

  local catalog = RepriseHC.BuildCatalog()
  local list = catalog[catName] or {}
  local got = earnedSet()

  if catName == "Professions" then
    table.sort(list, function(a,b)
      if a.skill == b.skill then return ( (RANK_ORDER[a.rank] or 99) < (RANK_ORDER[b.rank] or 99) ) end
      return a.skill < b.skill
    end)
  elseif catName == "Guild First" then
    local order = { ALL = 1, CLASS = 2, RACE = 3 }
    table.sort(list, function(a,b)
      local ta = order[a.gfType or "RACE"] or 3
      local tb = order[b.gfType or "RACE"] or 3
      if ta ~= tb then return ta < tb end
      local oa = tonumber(a.gfOrder or 0) or 0
      local ob = tonumber(b.gfOrder or 0) or 0
      if oa ~= ob then return oa < ob end
      local ca = tonumber(a.levelCap or a.cap or 0) or 0
      local cb = tonumber(b.levelCap or b.cap or 0) or 0
      if ca ~= cb then return ca < cb end
      local ka = tostring(a.gfKey or a.name or "")
      local kb = tostring(b.gfKey or b.name or "")
      return ka < kb
    end)
  elseif catName == "Quest Milestones" then
    table.sort(list, function(a,b) if (a.levelCap or 0) == (b.levelCap or 0) then return (a.name or "") < (b.name or "") end return (a.levelCap or 0) < (b.levelCap or 0) end)
  elseif catName == "Speedrun" then
    table.sort(list, function(a,b) return (a.level or 0) < (b.level or 0) end)
  end

  DebugCategory(catName, list, got)

  if #list == 0 then
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y); fs:SetText("No entries to display.")
    return -y + 30
  end

  local innerW = RepriseHC.GetScrollInnerWidth()
  local cols   = 1
  local gutter = 10
  local leftPad = 6
  local usable = innerW - leftPad - (gutter * (cols - 1))
  local cardW  = math.floor(usable / cols)
  if cardW < 200 then cols = 2; usable = innerW - leftPad - (gutter * (cols - 1)); cardW = math.floor(usable / cols) end
  local cardH = (catName == "Dungeons") and 110 or 84

  local totalRows = math.ceil(#list / cols)
  local totalHeight = -y + (math.max(0, totalRows - 1) * (cardH + 8)) + 12

  -- Building every card in a single frame causes noticeable hitching on large
  -- lists (e.g., Quest Milestones, Professions). Build them in small batches
  -- across multiple frames so the UI can keep rendering while we work.
  local cancelled = false
  page:HookScript("OnHide", function() cancelled = true end)

  local function BuildBatch(startIndex)
    if cancelled or not page:IsShown() then return end

    local created = 0
    local index = startIndex
    while index <= #list and created < 10 do
      local ach = list[index]
      local earned = got[ach.id]
      local locked = ach.locked
      local winner = ach.winner
      local nm = ach.name or ""

      local row = math.floor((index - 1) / cols)
      local col = (index - 1) % cols
      local x = leftPad + (col * (cardW + gutter))
      local rowTopY = y - (row * (cardH + 8))

      MakeCard(page, x, rowTopY, cardW, cardH, nm, ach.points or 0, earned, locked, winner, ach.id)

      created = created + 1
      index = index + 1
    end

    if index <= #list and not cancelled then
      C_Timer.After(0, function()
        BuildBatch(index)
      end)
    end
  end

  BuildBatch(1)

  return totalHeight
end
