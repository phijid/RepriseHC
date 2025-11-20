function RepriseHC.RenderRules(page)
  local y = -10
  y = RepriseHC.Header(page, "Rules", y)

  local sections = (RepriseHC.BuildRulesPageData and RepriseHC.BuildRulesPageData()) or {}
  if #sections == 0 then
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    fs:SetPoint("TOPLEFT", 10, y)
    fs:SetText("No rules to display.")
    return -y + 24
  end

  local innerWidth = RepriseHC.GetScrollInnerWidth()

  for idx, section in ipairs(sections) do
    local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, y)
    title:SetText(section.title or "")
    title:SetTextColor(1, .82, 0, 1)
    y = y - 22

    for _, line in ipairs(section.lines or {}) do
      local fs = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      fs:SetPoint("TOPLEFT", 14, y)
      fs:SetWidth(math.max(100, innerWidth - 20))
      fs:SetJustifyH("LEFT")
      fs:SetText(line)
      local h = fs:GetStringHeight()
      y = y - (h + 8)
    end

    if idx < #sections then
      y = y - 6
    end
  end

  return -y + 10
end
