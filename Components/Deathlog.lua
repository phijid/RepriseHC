function RepriseHC.RenderDeathLog(page)
  local y = -10
  y = RepriseHC.Header(page, "Death Log", y)

  local dl = RepriseHC.GetDeathLog() or {}
  local rowH = 22

  -- Headers: Player, Lvl, Class, Race, Zone
  local headers = {"Player","Lvl","Class","Race","Zone"}
  local widths  = {150,40,80,80,230}
  local x = 6
  for i,h in ipairs(headers) do
    local fs = page:CreateFontString(nil,"OVERLAY","GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(h); fs:SetTextColor(1,.82,0,1)
    x = x + widths[i] + 6
  end

  y = y - rowH
  table.sort(dl, function(a,b) return (a.when or 0) > (b.when or 0) end)

  local function classLabel(val)
    if RepriseHC and RepriseHC.GetClassLabel then return RepriseHC.GetClassLabel(val) end
    return tostring(val or "?")
  end

  local function raceLabel(val)
    if RepriseHC and RepriseHC.GetRaceLabel then return RepriseHC.GetRaceLabel(val) end
    return tostring(val or "?")
  end

  for i,d in ipairs(dl) do
    local x = 6
    local row = CreateFrame("Frame", nil, page, "BackdropTemplate")
    row:SetPoint("TOPLEFT", x, y)
    row:SetSize(RepriseHC.GetScrollInnerWidth()-12, rowH)
    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints(); stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
    stripe:SetVertexColor(1,1,1, i%2==0 and 0.06 or 0.03)

    local cols = {
      d.name or d.playerKey or "?",
      tostring(d.level or 0),
      classLabel(d.class),
      raceLabel(d.race),
      tostring(d.zone or "?"),
    }
    local cx = 6
    for ci,val in ipairs(cols) do
      local fs = page:CreateFontString(nil,"OVERLAY","GameFontHighlight")
      fs:SetPoint("TOPLEFT", cx, y)
      fs:SetText(val)
      cx = cx + widths[ci] + 6
    end

    -- Tooltip with extra details
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      GameTooltip:AddLine(d.name or d.playerKey or "Player", 1,1,1)
      GameTooltip:AddLine(("Level %s  %s  %s"):format(tostring(d.level or 0), raceLabel(d.race), classLabel(d.class)), .9,.9,.9)
      GameTooltip:AddLine(("Zone: %s"):format(tostring(d.zone or "?")), .9,.9,1)
      if d.subzone and d.subzone ~= "" then
        GameTooltip:AddLine(("Subzone: %s"):format(tostring(d.subzone)), .8,.8,1)
      end
      if d.when then
        GameTooltip:AddLine(("Time: %s"):format(date("%b %d, %Y %H:%M", d.when)), .8,.8,.8)
      end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    y = y - rowH
  end

  y = y - 8
  y = RepriseHC.Header(page, "Death Stats", y)

  local stats = (RepriseHC and RepriseHC.DeathStats and RepriseHC.DeathStats()) or { byClass={}, byRace={}, byZone={}, byBracket={}, total=0 }
  local function makeKVList(tbl)
    local arr = {}
    for k,v in pairs(tbl) do table.insert(arr, {k=k, v=v}) end
    table.sort(arr, function(a,b) return a.v > b.v end)
    return arr
  end
  local colx = 6
  local sections = {
    { title="By Class",  data=makeKVList(stats.byClass),  width=180 },
    { title="By Race",   data=makeKVList(stats.byRace),   width=180 },
    { title="By Zone",   data=makeKVList(stats.byZone),   width=260 },
    { title="By Level Bracket", data=makeKVList(stats.byBracket), width=180 },
  }
  local bottomY = y
  for _,sec in ipairs(sections) do
    local topY = y
    local fs = page:CreateFontString(nil,"OVERLAY","GameFontNormal")
    fs:SetPoint("TOPLEFT", colx, topY)
    fs:SetText(sec.title); fs:SetTextColor(1,.82,0,1)

    local yy = topY - 18
    local shown = 0
    for _,row in ipairs(sec.data) do
      local line = page:CreateFontString(nil,"OVERLAY","GameFontHighlight")
      line:SetPoint("TOPLEFT", colx, yy)
      line:SetText(("- %s: %d"):format(row.k, row.v))
      shown = shown + 1
      yy = yy - 18
      if shown >= 12 then break end
    end
    bottomY = math.min(bottomY, yy - 10)
    colx = colx + sec.width + 20
  end
  return -bottomY + 20
end