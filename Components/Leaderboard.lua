local function OpenLeaderboardDetail(playerKey)
  if not playerKey or playerKey == "" then return end
  RepriseHCUiDB._leaderboardDetail = { player = playerKey }
  RepriseHCUiDB._lastNav = RepriseHCUiDB.nav or "leaderboard"
  RepriseHC.SelectNav("leaderboardDetail")
end

local function CloseLeaderboardDetail()
  local back = RepriseHCUiDB._lastNav or "leaderboard"
  RepriseHCUiDB._leaderboardDetail = nil
  RepriseHC.SelectNav(back)
end

-- Leaderboard (NO HOVER TOOLTIP)
function RepriseHC.RenderLeaderboard(page)
  local y = -10
  y = RepriseHC.Header(page, "Guild Leaderboard", y)

  local chars = {}
  local db = RepriseHC.DB() or { characters = {} }
  local playerKey
  if RepriseHC and RepriseHC.PlayerKey then
    local ok, key = pcall(RepriseHC.PlayerKey)
    if ok and key and key ~= "" then
      playerKey = key
    end
  end
  for name, data in pairs(db.characters or {}) do
    table.insert(chars, { name=name, points=data.points or 0 })
  end
  table.sort(chars, function(a,b) return a.points > b.points end)

  if #chars == 0 then
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y); fs:SetText("No data yet. Earn achievements or sync with guild to populate.")
    return -y + 30
  end

  for i, char in ipairs(chars) do
    local idx = i
    local row = CreateFrame("Frame", nil, page, "BackdropTemplate")
    row:SetPoint("TOPLEFT", 6, y); row:SetSize(RepriseHC.GetScrollInnerWidth()-12, 22)
    row:EnableMouse(true)
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(); stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
    local isPlayer = (playerKey and char.name == playerKey)
    stripe:SetVertexColor(1,1,1, idx%2==0 and 0.06 or 0.03)
    row:SetScript("OnEnter", function() stripe:SetVertexColor(1,1,1, 0.09) end)
    row:SetScript("OnLeave", function() stripe:SetVertexColor(1,1,1, idx%2==0 and 0.06 or 0.03) end)
    row:SetScript("OnMouseUp", function() OpenLeaderboardDetail(char.name) end)

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", 8, 0)
    local displayName = char.name
    if isPlayer then
      displayName = "|cffffd100" .. char.name .. "|r"
    end
    if RepriseHC and RepriseHC.IsDead and RepriseHC.IsDead(char.name) then
      fs:SetText(("%d. %s %s"):format(idx, RepriseHC.skull, displayName))
    else
      fs:SetText(("%d. %s"):format(idx, displayName))
    end

    local pts = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pts:SetPoint("RIGHT", -8, 0)
    pts:SetText(("|cfff5f268%d pts|r"):format(char.points))
    pts:SetTextColor(1,0.96,0.41,1)

    y = y - 22
  end
  return -y + 12
end

function RepriseHC.RenderLeaderboardDetail(page)
  local detail = RepriseHCUiDB._leaderboardDetail
  local y = -10

  if not detail or not detail.player then
    y = RepriseHC.Header(page, "Player Details", y)
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y); fs:SetText("No player selected.")
    return -y + 40
  end

  local title = detail.player or "Player"
  y = RepriseHC.Header(page, title, y)

  local back = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  back:SetPoint("TOPRIGHT", -10, y + 20)
  back:SetSize(90, 22)
  back:SetText("Back")
  back:SetScript("OnClick", CloseLeaderboardDetail)

  local achievements = {}
  if RepriseHC and RepriseHC.Ach_GetCharacterAchievements then
    achievements = RepriseHC.Ach_GetCharacterAchievements(detail.player) or {}
  end

  if #achievements == 0 then
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y)
    fs:SetText("No achievements earned yet.")
    return -y + 40
  end

  local headers = {"#", "Achievement", "When", "Points"}
  local widths  = {30, 320, 160, 80}
  local x = 6
  for i,h in ipairs(headers) do
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(h); fs:SetTextColor(1,.82,0,1)
    x = x + widths[i] + 8
  end

  y = y - 22
  for i, entry in ipairs(achievements) do
    local x = 6
    local cols = {
      tostring(i),
      entry.name or entry.id or "",
      (entry.when and date("%b %d %H:%M", entry.when) or ""),
      tostring(entry.points or 0).." pts",
    }
    for ci, val in ipairs(cols) do
      local fs = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("TOPLEFT", x, y); fs:SetText(val)
      x = x + widths[ci] + 8
    end
    y = y - 18
  end

  return -y + 20
end