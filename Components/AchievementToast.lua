local ALERT_DURATION = 4.5
local FADE_DURATION  = 0.35
local QUEUE = {}

local function GetToastFrame()
  if _G.RepriseHC_AchievementToast then
    return _G.RepriseHC_AchievementToast
  end

  local frame = CreateFrame("Frame", "RepriseHC_AchievementToast", UIParent, "BackdropTemplate")
  frame:SetSize(320, 86)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetClampedToScreen(true)
  frame:Hide()

  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Background")
  frame.bg:SetTexCoord(0, 1, 0, 0.78)
  frame.bg:SetVertexColor(1, 1, 1, 0.95)

  frame.glow = frame:CreateTexture(nil, "BORDER")
  frame.glow:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Glow")
  frame.glow:SetPoint("TOPLEFT", -14, 14)
  frame.glow:SetPoint("BOTTOMRIGHT", 14, -14)
  frame.glow:SetBlendMode("ADD")
  frame.glow:SetAlpha(0)

  frame.iconBG = frame:CreateTexture(nil, "ARTWORK")
  frame.iconBG:SetTexture("Interface\\AchievementFrame\\UI-Achievement-IconFrame")
  frame.iconBG:SetTexCoord(0, 0.5625, 0, 0.5625)
  frame.iconBG:SetSize(64, 64)
  frame.iconBG:SetPoint("LEFT", 18, 0)

  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetTexture("Interface\\Icons\\INV_Misc_Trophy_01")
  frame.icon:SetPoint("CENTER", frame.iconBG, "CENTER", 0, 0)
  frame.icon:SetSize(40, 40)

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  frame.title:SetPoint("TOPLEFT", frame.iconBG, "TOPRIGHT", 12, -4)
  frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -10)
  frame.title:SetJustifyH("LEFT")
  frame.title:SetTextColor(1, 0.82, 0)

  frame.points = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.points:SetPoint("BOTTOMLEFT", frame.iconBG, "BOTTOMRIGHT", 12, 8)
  frame.points:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 10)
  frame.points:SetJustifyH("LEFT")
  frame.points:SetTextColor(0.9, 0.95, 1)

  frame._duration = ALERT_DURATION
  frame._fade = FADE_DURATION

  frame:SetScript("OnHide", function(self)
    self._playing = false
    self._start = nil
    self:SetAlpha(1)
    if #QUEUE > 0 then
      if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function()
          if self:IsShown() then return end
          self:PlayNext()
        end)
      else
        self:PlayNext()
      end
    end
  end)

  frame:SetScript("OnUpdate", function(self)
    if not self._start then return end
    local age = GetTime() - self._start
    if age < self._fade then
      self:SetAlpha(age / self._fade)
    elseif age > (self._duration - self._fade) then
      self:SetAlpha(math.max(0, (self._duration - age) / self._fade))
    else
      self:SetAlpha(1)
    end

    local shine = 0
    if age < 1 then
      shine = age
    elseif age > (self._duration - 1) then
      shine = math.max(0, self._duration - age)
    else
      shine = 1
    end
    if self.glow then
      self.glow:SetAlpha(shine * 0.7)
    end

    if age >= self._duration then
      self:Hide()
    end
  end)

  function frame:PlayNext()
    if self._playing then return end
    local nextEntry = table.remove(QUEUE, 1)
    if not nextEntry then return end

    self.title:SetText(nextEntry.title or "Achievement Earned")
    local pts = tonumber(nextEntry.points) or 0
    self.points:SetText(string.format("+%d Points", pts))

    self._start = GetTime()
    self._playing = true
    self:SetAlpha(0)
    self:Show()
  end

  return frame
end

local function EnqueueToast(title, points)
  table.insert(QUEUE, { title = title, points = points })
  local toast = GetToastFrame()
  toast:PlayNext()
end

RepriseHC = RepriseHC or {}
function RepriseHC.ShowAchievementToast(title, points)
  if not title or title == "" then return end
  EnqueueToast(title, points)
end
