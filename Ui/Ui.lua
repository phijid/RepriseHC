local DEFAULT_MINIMAP_ANGLE = math.rad(210)

RepriseHCUiDB = RepriseHCUiDB or {
  minimap = { angle = DEFAULT_MINIMAP_ANGLE },
  nav = "leaderboard",
}
RepriseHCUiDB.minimap = RepriseHCUiDB.minimap or { angle = DEFAULT_MINIMAP_ANGLE }
if not RepriseHCUiDB.minimap.angle or math.abs(RepriseHCUiDB.minimap.angle - 0.75) < 1e-3 then
  RepriseHCUiDB.minimap.angle = DEFAULT_MINIMAP_ANGLE
end

local function RestoreUiPosition(frame)
  local pos = RepriseHCUiDB.position
  frame:ClearAllPoints()
  if pos and pos.point and pos.relativePoint and pos.x and pos.y then
    frame:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
  else
    frame:SetPoint("CENTER")
  end
end

local function SaveUiPosition(frame)
  if not frame then return end
  local point, _, relativePoint, xOfs, yOfs = frame:GetPoint(1)
  if not point then return end
  RepriseHCUiDB.position = {
    point = point,
    relativePoint = relativePoint,
    x = xOfs,
    y = yOfs,
  }
end

-- ==== UI Shell ====
local UI = CreateFrame("Frame", "RepriseHC_UI", UIParent, "BackdropTemplate")
UI:SetSize(900, 560)
RestoreUiPosition(UI)
UI:Hide()
UI:SetMovable(true)
UI:EnableMouse(true)
UI:SetClampedToScreen(true)
UI:RegisterForDrag("LeftButton")
UI:SetScript("OnDragStart", function(self)
  if self:IsMovable() then
    self:StartMoving()
  end
end)
UI:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  SaveUiPosition(self)
end)
UI:SetScript("OnHide", function(self)
  self:StopMovingOrSizing()
  SaveUiPosition(self)
end)
UI:SetBackdrop({
  bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 }
})

UI.titleBG = UI:CreateTexture(nil, "ARTWORK")
UI.titleBG:SetTexture("Interface\\FriendsFrame\\UI-Toast-Background")
UI.titleBG:SetVertexColor(1, 0.82, 0, 0.25)
UI.titleBG:SetPoint("TOPLEFT", 6, -6)
UI.titleBG:SetPoint("TOPRIGHT", -6, -6)
UI.titleBG:SetHeight(28)

UI.titleFS = UI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
UI.titleFS:SetPoint("LEFT", UI.titleBG, "LEFT", 10, 0)
UI.titleFS:SetText("RepriseHC — Guild Achievements")
UI.titleFS:SetTextColor(1, .82, 0, 1)

local close = CreateFrame("Button", nil, UI, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", 2, 2)
close:SetScript("OnClick", function() UI:Hide() end)

UISpecialFrames = UISpecialFrames or {}
local escFound
for i = 1, #UISpecialFrames do
  if UISpecialFrames[i] == "RepriseHC_UI" then
    escFound = true
    break
  end
end
if not escFound then
  table.insert(UISpecialFrames, "RepriseHC_UI")
end

local dragHandle = CreateFrame("Frame", nil, UI)
dragHandle:SetPoint("TOPLEFT", UI, "TOPLEFT", 0, 0)
dragHandle:SetPoint("TOPRIGHT", UI, "TOPRIGHT", -40, 0)
dragHandle:SetHeight(36)
dragHandle:EnableMouse(true)
dragHandle:RegisterForDrag("LeftButton")
dragHandle:SetScript("OnDragStart", function()
  if UI:IsMovable() then
    UI:StartMoving()
  end
end)
dragHandle:SetScript("OnDragStop", function()
  UI:StopMovingOrSizing()
  SaveUiPosition(UI)
end)

local Sidebar = CreateFrame("Frame", nil, UI, "BackdropTemplate")
Sidebar:SetSize(210, 520)
Sidebar:SetPoint("TOPLEFT", 8, -36)
Sidebar:SetBackdrop({
  bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
  tile=true, tileSize=8, edgeSize=12, insets={left=3,right=3,top=3,bottom=3}
})
Sidebar:SetBackdropColor(0,0,0,0.35)

local RightPane = CreateFrame("Frame", nil, UI, "BackdropTemplate")
RightPane:SetPoint("TOPLEFT", Sidebar, "TOPRIGHT", 8, 0)
RightPane:SetPoint("BOTTOMRIGHT", -8, 8)
RightPane:SetBackdrop({
  bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
  tile=true, tileSize=8, edgeSize=12, insets={left=3,right=3,top=3,bottom=3}
})
RightPane:SetBackdropColor(0,0,0,0.20)


local navButtons = {}
function RepriseHC.SelectNav(id)
  RepriseHCUiDB.nav = id
  for _, b in ipairs(navButtons) do
    local on = (b._id == id)
    b.bg:SetVertexColor(1,1,1, on and 0.12 or 0.04)
    b.label:SetTextColor(on and 1 or .9, on and .82 or .9, on and 0 or .9)
  end
  UI:Refresh()
end
local function MakeNavButton(parent, text, id, y)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetPoint("TOPLEFT", 10, y)
  b:SetSize(190, 24)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  b.bg:SetVertexColor(1,1,1, 0.04)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  b.label:SetPoint("LEFT", 8, 0)
  b.label:SetText(text)
  b._id = id
  b:SetScript("OnClick", function() RepriseHC.SelectNav(id) end)
  table.insert(navButtons, b)
  return y - 26
end
do
  local y = -10
  for _, id in ipairs(RepriseHC.navigationOrder) do
    local it = RepriseHC.navigation[id]
    if it.enabled then
      y = MakeNavButton(Sidebar, it.label, id, y)
    end
  end
end

-- Scroll + Page container
local scroll = CreateFrame("ScrollFrame", nil, RightPane, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 6, -6)
scroll:SetPoint("BOTTOMRIGHT", -28, 6)
scroll:SetFrameLevel(RightPane:GetFrameLevel() + 1)

local content = CreateFrame("Frame", nil, scroll)
content:SetPoint("TOPLEFT"); content:SetPoint("TOPRIGHT"); content:SetHeight(1)
scroll:SetScrollChild(content)
content:SetFrameLevel(scroll:GetFrameLevel() + 1)

function RepriseHC.GetScrollInnerWidth()
  local w = scroll:GetWidth() or 0
  if w <= 0 then return 620 end
  return math.max(100, w - 12)
end
scroll:SetScript("OnSizeChanged", function() content:SetWidth(RepriseHC.GetScrollInnerWidth()) end)
content:SetWidth(RepriseHC.GetScrollInnerWidth())

local currentPage
local function BeginPage()
  if currentPage then currentPage:Hide(); currentPage:SetParent(nil) end
  currentPage = CreateFrame("Frame", nil, content)
  currentPage:SetPoint("TOPLEFT")
  currentPage:SetWidth(RepriseHC.GetScrollInnerWidth())
  currentPage:SetHeight(1)
  currentPage:SetFrameLevel(content:GetFrameLevel() + 1)
  return currentPage
end
local function FinishPage(page, height) page:SetHeight(height); content:SetHeight(height) end

function RepriseHC.Header(parent, text, y)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  fs:SetPoint("TOPLEFT", 6, y)
  fs:SetText(text); fs:SetTextColor(1,.82,0,1)
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetTexture("Interface\\Buttons\\WHITE8X8")
  line:SetVertexColor(1,1,1, .07)
  line:SetPoint("TOPLEFT", 6, y-14); line:SetPoint("RIGHT", -6, 0); line:SetHeight(1)
  return y - 24
end

-- ===== Earners "hidden" page state/helpers =====


local function __IsOurGroupDropdownOpen()
  local open = rawget(_G, "UIDROPDOWNMENU_OPEN_MENU")
  if open and open.GetName and open:GetName() == "RepriseHC_GroupDropdown" then
    return true
  end
  return false
end

local __refreshDeferred = false

function UI:Refresh()
  -- If the Group dropdown menu is open, defer repainting to avoid closing it.
  if (RepriseHCUiDB.nav == "standing") and __IsOurGroupDropdownOpen() then
    if not __refreshDeferred then
      __refreshDeferred = true
      C_Timer.After(0.25, function()
        __refreshDeferred = false
        if not __IsOurGroupDropdownOpen() then
          if UI and UI.Refresh then UI:Refresh() end
        else
          -- Still open; try again shortly
          __refreshDeferred = true
          C_Timer.After(0.4, function()
            __refreshDeferred = false
            if UI and UI.Refresh then UI:Refresh() end
          end)
        end
      end)
    end
    return
  end
  local page = BeginPage()
  local id = RepriseHCUiDB.nav or "leaderboard"
  local height = 100
  if id == "leaderboard" then
    height = RepriseHC.RenderLeaderboard(page)
  elseif id == "standing" then
    height = RepriseHC.RenderStandings(page)
  elseif id == "level" then
    height = RepriseHC.RenderCategory(page, "Level Milestones")
  elseif id == "speedrun" then
    height = RepriseHC.RenderCategory(page, "Speedrun")
  elseif id == "quest" then
    height = RepriseHC.RenderCategory(page, "Quest Milestones")
  elseif id == "prof" then
    height = RepriseHC.RenderCategory(page, "Professions")
  elseif id == "dungeons" then
    height = RepriseHC.RenderCategory(page, "Dungeons")
  elseif id == "guildFirst" then
    height = RepriseHC.RenderCategory(page, "Guild First")
  elseif id == "deathlog" then
    height = RepriseHC.RenderDeathLog(page)
  elseif id == "earners" then
    height = RepriseHC.RenderEarners(page)
  end
  FinishPage(page, height or 300)
end

local function RefreshSidebar()
  for _, b in ipairs(navButtons) do
    local on = (b._id == (RepriseHCUiDB.nav or "leaderboard"))
    b.bg:SetVertexColor(1,1,1, on and 0.12 or 0.04)
    b.label:SetTextColor(on and 1 or .9, on and .82 or .9, on and 0 or .9)
  end
end

function RepriseHC.UIRefresh()
  if UI and UI.Refresh then
    UI:Refresh()
  end
  if RefreshSidebar then
    RefreshSidebar()
  end
end

SLASH_RHCU1 = "/rhcu"
SlashCmdList["RHCU"] = function()
  if RepriseHC_UI:IsShown() then
    RepriseHC_UI:Hide()
  else
    if EnsureMinimapButton then
      EnsureMinimapButton()
    end
    RestoreUiPosition(UI)
    RepriseHC_UI:Show()
    UI:Refresh()
    RefreshSidebar()
  end
end

UI:SetScript("OnShow", function()
  RestoreUiPosition(UI)
  UI:Refresh()
  RefreshSidebar()
end)

UI:RegisterEvent("CHAT_MSG_ADDON")

-- Minimap button
local function Minimap_SetPos(btn, angle)
  if not btn then return end
  local parent = Minimap or UIParent
  local radius = 80
  if Minimap and Minimap:GetWidth() and Minimap:GetWidth() > 0 then
    radius = (Minimap:GetWidth() / 2) + 5
  end
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", parent, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local minimapRetryPending
local function EnsureMinimapButton()
  if RepriseHC_MinimapButton and RepriseHC_MinimapButton:IsObjectType("Button") then
    local btn = RepriseHC_MinimapButton
    if btn:GetParent() ~= (Minimap or UIParent) then
      btn:SetParent(Minimap or UIParent)
    end
    btn:SetFrameStrata("MEDIUM")
    local level = Minimap and Minimap:GetFrameLevel() or 0
    btn:SetFrameLevel(level + 5)
    Minimap_SetPos(btn, RepriseHCUiDB.minimap.angle or DEFAULT_MINIMAP_ANGLE)
    btn:Show()
    return btn
  end

  if not Minimap or not Minimap:GetWidth() or Minimap:GetWidth() == 0 then
    if not minimapRetryPending then
      minimapRetryPending = true
      C_Timer.After(1, function()
        minimapRetryPending = false
        EnsureMinimapButton()
      end)
    end
    return nil
  end

  local btn = CreateFrame("Button", "RepriseHC_MinimapButton", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 5)

  local ring = btn:CreateTexture(nil, "OVERLAY")
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  ring:SetSize(54, 54); ring:SetPoint("TOPLEFT")

  local icon = btn:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\AddOns\\RepriseHC\\Icons\\reprise_icon.tga")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  icon:SetSize(20, 20); icon:SetPoint("CENTER")
  btn.icon = icon

  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  btn:RegisterForClicks("LeftButtonUp")
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function(self) self.dragging = true; self:LockHighlight() end)
  btn:SetScript("OnDragStop",  function(self) self.dragging = false; self:UnlockHighlight() end)
  btn:SetScript("OnUpdate", function(self)
    if not self.dragging then return end
    local mx,my = Minimap:GetCenter()
    local cx,cy = GetCursorPosition(); local s = UIParent:GetScale()
    cx,cy = cx/s, cy/s
    RepriseHCUiDB.minimap.angle = math.atan2(cy-my, cx-mx)
    Minimap_SetPos(self, RepriseHCUiDB.minimap.angle)
  end)
  btn:SetScript("OnClick", function()
    if RepriseHC_UI:IsShown() then
      RepriseHC_UI:Hide()
    else
      EnsureMinimapButton()
      RestoreUiPosition(UI)
      RepriseHC_UI:Show(); UI:Refresh(); RefreshSidebar()
    end
  end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("RepriseHC", 0,.8,1)
    GameTooltip:AddLine("Left-click: Toggle Guild Achievements", 1,1,1)
    GameTooltip:AddLine("Drag: Move icon", .9,.9,.9)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  Minimap_SetPos(btn, RepriseHCUiDB.minimap.angle or DEFAULT_MINIMAP_ANGLE)
  btn:Show()
  return btn
end

local Init = CreateFrame("Frame")
Init:RegisterEvent("PLAYER_LOGIN")
Init:RegisterEvent("PLAYER_ENTERING_WORLD")
Init:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    EnsureMinimapButton()
  end
end)


-- ========= Centralized Handlers for UI shell/minimap =========
local function __RHC_UI_OnEvent(event, ...)
  if event == "PLAYER_LOGIN" then
    if EnsureMinimapButton then EnsureMinimapButton() end
  elseif event == "CHAT_MSG_ADDON" then
    local prefix = ...
    if prefix == "RepriseHC_ACH" and RepriseHC_UI and RepriseHC_UI:IsShown() then
      C_Timer.After(0.2, function() if UI and UI.Refresh then UI:Refresh() end end)
    end
  end
end
RepriseHC.RegisterEvent("PLAYER_LOGIN", __RHC_UI_OnEvent); RepriseHC._EnsureEvent("PLAYER_LOGIN")
RepriseHC.RegisterEvent("CHAT_MSG_ADDON", __RHC_UI_OnEvent); RepriseHC._EnsureEvent("CHAT_MSG_ADDON")

RepriseHC.EnsureMinimapButton = EnsureMinimapButton

