-- Leaderboard (NO HOVER TOOLTIP)
function RepriseHC.RenderLeaderboard(page)
  local y = -10
  y = RepriseHC.Header(page, "Guild Leaderboard", y)

  local chars = {}
  local db = RepriseHC.DB() or { characters = {} }
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
    local row = CreateFrame("Frame", nil, page, "BackdropTemplate")
    row:SetPoint("TOPLEFT", 6, y); row:SetSize(RepriseHC.GetScrollInnerWidth()-12, 22)
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(); stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
    stripe:SetVertexColor(1,1,1, i%2==0 and 0.06 or 0.03)

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", 8, 0); fs:SetText(("%d. %s"):format(i, char.name))
    fs:SetTextColor(1,1,1,1)

    local pts = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pts:SetPoint("RIGHT", -8, 0); pts:SetText(("%d pts"):format(char.points))
    pts:SetTextColor(1,0.96,0.41,1)

    y = y - 22
  end
  return -y + 12
end