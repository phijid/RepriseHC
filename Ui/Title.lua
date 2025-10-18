local ADDON_NAME = ...
local CUSTOM_TITLE = "Reprise Hardcore Seasonal Player"

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("INSPECT_READY")
f:RegisterEvent("UNIT_NAME_UPDATE")
f:RegisterEvent("PLAYER_GUILD_UPDATE")

-- ---------------------------
-- Small helpers
-- ---------------------------
local function SafeCreateTitle(name, anchor)
  if not anchor then return nil end
  local parent = anchor:GetParent() or UIParent
  local fs = parent:CreateFontString(name, "ARTWORK", "GameFontHighlightSmall")
  fs:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
  fs:SetJustifyH("CENTER")
  fs:SetText(CUSTOM_TITLE)
  fs:Hide()
  return fs
end

local function FindCharacterAnchor()
  -- Try the guild line first; if it doesn't exist in your client, fall back to level, then name
  return _G.CharacterGuildText
      or _G.CharacterLevelText
      or _G.CharacterNameText
      or (CharacterFrame and CharacterFrame.TitleText)
end

local function GetInspectAnchor()
  local g = _G.InspectGuildText
  if g and g:IsShown() and (g:GetText() or "") ~= "" then
    return g
  end
  return _G.InspectLevelText or (InspectFrame and InspectFrame.TitleText)
end

local function ShowTitle(unit)
  -- Always show on yourself
  if UnitIsUnit(unit, "player") then
    return true
  end

  -- Show for guildmates in allowed guilds
  local g = GetGuildInfo(unit)
  return g and RepriseHC.allowedGuilds and RepriseHC.allowedGuilds[g]
end

-- ---------------------------
-- Updates
-- ---------------------------
local function UpdateInspectTitle()
  local fs = _G.RepriseHC_InspectTitle
  if not fs or not InspectFrame or not InspectFrame:IsShown() then
    if fs then fs:Hide() end
    return
  end

  local unit = InspectFrame.unit or "target"
  if not unit or not UnitIsPlayer(unit) or not CanInspect(unit) then
    fs:Hide()
    return
  end

  if not ShowTitle(unit) then
    fs:Hide()
    return
  end

  -- re-anchor dynamically so it sits right under guild if present, otherwise right under level
  local anchor = GetInspectAnchor()
  if anchor then
    fs:ClearAllPoints()
    fs:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
  end

  fs:SetText("RepriseHC Seasonal")
  fs:Show()
end

local function UpdateCharacterTitle()
  local fs = _G.RepriseHC_CharacterTitle
  if not fs or not CharacterFrame or not CharacterFrame:IsShown() then
    if fs then fs:Hide() end
    return
  end

  if not RepriseHC.IsGuildAllowed() then
    fs:Hide()
    return
  end

  fs:SetText(CUSTOM_TITLE)
  fs:Show()
end

-- ---------------------------
-- Inits
-- ---------------------------
local function InitInspect()
  if _G.RepriseHC_InspectTitle then return end
  local anchor = GetInspectAnchor()
  if not anchor then return end

  local fs = (anchor:GetParent() or InspectFrame):CreateFontString("RepriseHC_InspectTitle", "ARTWORK", "GameFontHighlightSmall")
  fs:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
  fs:SetJustifyH("CENTER")
  fs:SetText("RepriseHC Seasonal")
  fs:Hide()

  if InspectFrame and not InspectFrame._repriseHooked then
    InspectFrame:HookScript("OnShow", UpdateInspectTitle)
    InspectFrame:HookScript("OnHide", function() fs:Hide() end)
    InspectFrame._repriseHooked = true
  end

  -- Refresh when Blizzard updates the guild/level lines
  if not _G._repriseHookedInspectGuild then
    if InspectPaperDollFrame_SetGuild then hooksecurefunc("InspectPaperDollFrame_SetGuild", UpdateInspectTitle) end
    if InspectPaperDollFrame_SetLevel then hooksecurefunc("InspectPaperDollFrame_SetLevel", UpdateInspectTitle) end
    _G._repriseHookedInspectGuild = true
  end
end

local function InitCharacter()
  if _G.RepriseHC_CharacterTitle then return end
  if not CharacterFrame then return end           -- frame not created yet
  local anchor = FindCharacterAnchor()
  if not anchor then return end
  local fs = SafeCreateTitle("RepriseHC_CharacterTitle", anchor)

  -- Hook both the container and the PaperDoll tab (some clients fire one or the other)
  if not CharacterFrame._repriseHooked then
    CharacterFrame:HookScript("OnShow", UpdateCharacterTitle)
    CharacterFrame:HookScript("OnHide", function() fs:Hide() end)
    CharacterFrame._repriseHooked = true
  end
  if PaperDollFrame and not PaperDollFrame._repriseHooked then
    PaperDollFrame:HookScript("OnShow", UpdateCharacterTitle)
    PaperDollFrame:HookScript("OnHide", function() fs:Hide() end)
    PaperDollFrame._repriseHooked = true
  end

  -- Whenever the level/guild text is refreshed, refresh ours too
  if PaperDollFrame_SetLevel and not _G._repriseHookedSetLevel then
    hooksecurefunc("PaperDollFrame_SetLevel", UpdateCharacterTitle)
    _G._repriseHookedSetLevel = true
  end
end

-- ========= Centralized Handlers for Title overlays =========
local function __RHC_Title_OnEvent(event, arg1)
  if event == "PLAYER_LOGIN" then
    if IsAddOnLoaded("Blizzard_InspectUI") and InitInspect then InitInspect() end
    if CharacterFrame and InitCharacter then InitCharacter() end
  elseif event == "ADDON_LOADED" then
    if arg1 == "Blizzard_InspectUI" and InitInspect then InitInspect()
    elseif (arg1 == "Blizzard_CharacterUI" or arg1 == "Blizzard_PaperDollInfo" or arg1 == "Blizzard_PaperDollUI") and InitCharacter then
      InitCharacter()
    end
  elseif event == "INSPECT_READY" then
    if UpdateInspectTitle then UpdateInspectTitle() end
  elseif event == "UNIT_NAME_UPDATE" then
    if arg1 == "player" and UpdateCharacterTitle then UpdateCharacterTitle() end
  elseif event == "PLAYER_GUILD_UPDATE" then
    if UpdateCharacterTitle then UpdateCharacterTitle() end
  end
end
RepriseHC.RegisterEvent("PLAYER_LOGIN", __RHC_Title_OnEvent); RepriseHC._EnsureEvent("PLAYER_LOGIN")
RepriseHC.RegisterEvent("ADDON_LOADED", __RHC_Title_OnEvent); RepriseHC._EnsureEvent("ADDON_LOADED")
RepriseHC.RegisterEvent("INSPECT_READY", __RHC_Title_OnEvent); RepriseHC._EnsureEvent("INSPECT_READY")
RepriseHC.RegisterEvent("UNIT_NAME_UPDATE", __RHC_Title_OnEvent); RepriseHC._EnsureEvent("UNIT_NAME_UPDATE")
RepriseHC.RegisterEvent("PLAYER_GUILD_UPDATE", __RHC_Title_OnEvent); RepriseHC._EnsureEvent("PLAYER_GUILD_UPDATE")

