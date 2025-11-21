local ALERT_DURATION = 4.5
local FADE_DURATION  = 0.35
local QUEUE = {}

local function GetFactionIcon()
  local faction = UnitFactionGroup("player")
  if faction == "Horde" then
    return "Interface\\Icons\\INV_BannerPVP_01"
  elseif faction == "Alliance" then
    return "Interface\\Icons\\INV_BannerPVP_02"
  end

  return "Interface\\Icons\\INV_Misc_Trophy_01"
end

local function PlayAchievementSound()
  if SOUNDKIT and SOUNDKIT.UI_ACHIEVEMENT_AWARDED and PlaySound then
    PlaySound(SOUNDKIT.UI_ACHIEVEMENT_AWARDED, "Master")
  elseif PlaySound then
    PlaySound(12891, "Master")
  elseif PlaySoundFile then
    PlaySoundFile("Sound\\Interface\\UI_Achievement_Toast.wav", "Master")
  end
end

local function GetToastFrame()
  if _G.RepriseHC_AchievementToast then
    return _G.RepriseHC_AchievementToast
  end

  local frame = CreateFrame("Frame", "RepriseHC_AchievementToast", UIParent, "BackdropTemplate")
  frame:SetSize(356, 82)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetClampedToScreen(true)
  frame:Hide()

  frame.bg = frame:CreateTexture(nil, "BACKGROUND")
  frame.bg:SetAllPoints()
  frame.bg:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Background")
  frame.bg:SetTexCoord(0, 1, 0, 0.78)
  frame.bg:SetVertexColor(1, 1, 1, 0.96)

  frame.border = frame:CreateTexture(nil, "BORDER")
  frame.border:SetTexture("Interface\\AchievementFrame\\UI-Achievement-Alert-Background")
  frame.border:SetTexCoord(0, 1, 0.78, 1)
  frame.border:SetVertexColor(1, 1, 1, 0.82)
  frame.border:SetPoint("TOPLEFT", frame.bg, "BOTTOMLEFT", 0, 6)
  frame.border:SetPoint("TOPRIGHT", frame.bg, "BOTTOMRIGHT", 0, 6)
  frame.border:SetHeight(8)

  frame.iconBG = frame:CreateTexture(nil, "ARTWORK")
  frame.iconBG:SetTexture("Interface\\ACHIEVEMENTFRAME\\UI-Achievement-IconFrame")
  frame.iconBG:SetTexCoord(0, 0.5625, 0, 0.5625)
  frame.iconBG:SetSize(60, 60)
  frame.iconBG:SetPoint("RIGHT", frame, "LEFT", 24, 0)

  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetTexture(GetFactionIcon())
  frame.icon:SetPoint("CENTER", frame.iconBG, "CENTER", 0, 0)
  frame.icon:SetSize(44, 44)

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -10)
  frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -10)
  frame.title:SetJustifyH("LEFT")
  frame.title:SetJustifyV("TOP")
  frame.title:SetWordWrap(true)
  frame.title:SetMaxLines(2)
  frame.title:SetTextColor(1, 0.82, 0)

  frame.points = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.points:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 18, 10)
  frame.points:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 10)
  frame.points:SetJustifyH("CENTER")
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

    self.icon:SetTexture(GetFactionIcon())

    self._start = GetTime()
    self._playing = true
    self:SetAlpha(0)
    self:Show()

    if nextEntry.playSound then
      PlayAchievementSound()
    end
  end

  return frame
end

local function EnqueueToast(title, points)
  local toast = GetToastFrame()
  local shouldPlaySound = not toast._playing and #QUEUE == 0

  table.insert(QUEUE, { title = title, points = points, playSound = shouldPlaySound })
  toast:PlayNext()
end

RepriseHC = RepriseHC or {}
function RepriseHC.ShowAchievementToast(title, points)
  if not title or title == "" then return end
  EnqueueToast(title, points)
end
