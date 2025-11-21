local ALERT_DURATION = 4.5
local FADE_DURATION  = 0.35
local QUEUE = {}

local FitFontString

local TITLE_MIN_SIZE = 10
local TITLE_BASE_SIZE = 13
local SOUND_PATHS = {
  "Sound\\Interface\\UI_Achievement_Toast_01.wav",
  "Sound\\Interface\\UI_Achievement_Toast.wav",
  "Sound\\Interface\\UI_Toast_01.wav",
}

local SOUND_IDS = {
  function()
    if SOUNDKIT and SOUNDKIT.UI_ACHIEVEMENT_AWARDED then
      return SOUNDKIT.UI_ACHIEVEMENT_AWARDED
    end
  end,
  12891,
  567431, -- shared toast fallback
}

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
  if PlaySound then
    for _, idOrFn in ipairs(SOUND_IDS) do
      local id = type(idOrFn) == "function" and idOrFn() or idOrFn
      if id then
        local ok = PlaySound(id, "Master")
        if ok then
          return true
        end
      end
    end
  end

  if PlaySoundFile then
    for _, path in ipairs(SOUND_PATHS) do
      local ok = PlaySoundFile(path, "Master")
      if ok then
        return true
      end
    end
  end

  return false
end

local function GetToastFrame()
  if _G.RepriseHC_AchievementToast then
    return _G.RepriseHC_AchievementToast
  end

  local frame = CreateFrame("Frame", "RepriseHC_AchievementToast", UIParent, "BackdropTemplate")
  frame:SetSize(420, 60)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetClampedToScreen(true)
  frame:Hide()

  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
  })
  frame:SetBackdropColor(0.08, 0.08, 0.08, 0.94)

  frame.shine = frame:CreateTexture(nil, "BACKGROUND")
  frame.shine:SetTexture("Interface\\ACHIEVEMENTFRAME\\UI-Achievement-RecentHighlight")
  frame.shine:SetBlendMode("ADD")
  frame.shine:SetAlpha(0.22)
  frame.shine:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
  frame.shine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)

  frame.accent = frame:CreateTexture(nil, "BACKGROUND")
  frame.accent:SetTexture(1, 0.82, 0)
  frame.accent:SetAlpha(0.65)
  frame.accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
  frame.accent:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
  frame.accent:SetWidth(3)

  frame.iconBG = frame:CreateTexture(nil, "ARTWORK")
  frame.iconBG:SetTexture("Interface\\ACHIEVEMENTFRAME\\UI-Achievement-IconFrame")
  frame.iconBG:SetTexCoord(0, 0.5625, 0, 0.5625)
  frame.iconBG:SetSize(60, 60)
  frame.iconBG:SetPoint("RIGHT", frame, "LEFT", -8, 0)

  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetTexture(GetFactionIcon())
  frame.icon:SetPoint("CENTER", frame.iconBG, "CENTER", 0, 0)
  frame.icon:SetSize(44, 44)

  frame.content = CreateFrame("Frame", nil, frame)
  frame.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -8)
  frame.content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 8)

  frame.points = frame.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.points:SetPoint("BOTTOMLEFT", frame.content, "BOTTOMLEFT", 0, 0)
  frame.points:SetPoint("BOTTOMRIGHT", frame.content, "BOTTOMRIGHT", 0, 0)
  frame.points:SetJustifyH("CENTER")
  frame.points:SetTextColor(0.9, 0.95, 1)
  do
    local font, _, flags = frame.points:GetFont()
    if font then
      frame.points:SetFont(font, 12, flags)
    end
  end

  frame.title = frame.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, 0)
  frame.title:SetPoint("TOPRIGHT", frame.content, "TOPRIGHT", 0, 0)
  frame.title:SetPoint("BOTTOMLEFT", frame.points, "TOPLEFT", 0, 2)
  frame.title:SetPoint("BOTTOMRIGHT", frame.points, "TOPRIGHT", 0, 2)
  frame.title:SetJustifyH("CENTER")
  frame.title:SetJustifyV("TOP")
  frame.title:SetWordWrap(true)
  frame.title:SetMaxLines(3)
  frame.title:SetTextColor(1, 0.82, 0)
  do
    local font, _, flags = frame.title:GetFont()
    if font then
      frame.title:SetFont(font, TITLE_BASE_SIZE, flags)
    end
  end

  frame._duration = ALERT_DURATION
  frame._fade = FADE_DURATION

  function frame:EnsureTitleFits()
    local maxWidth = self.content:GetWidth()
    local text = self.title:GetText() or ""
    local pointsHeight = self.points:GetStringHeight() or self.points:GetLineHeight() or 0
    local availableHeight = math.max(18, self.content:GetHeight() - pointsHeight - 4)
    self.title:SetMaxLines(3)
    self.title:SetHeight(availableHeight)
    FitFontString(self.title, text, maxWidth, 3, 3, availableHeight)
    local usedHeight = math.min(self.title:GetStringHeight() or availableHeight, availableHeight)
    self.title:SetHeight(usedHeight)
  end

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

    local font, _, flags = self.title:GetFont()
    if font then
      self.title:SetFont(font, TITLE_BASE_SIZE, flags)
    end
    self.title:SetText(nextEntry.title or "Achievement Earned")
    local pts = tonumber(nextEntry.points) or 0
    self.points:SetText(string.format("+%d Points", pts))

    self.icon:SetTexture(GetFactionIcon())

    self:EnsureTitleFits()

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

function FitFontString(fs, text, maxWidth, maxLines, fallbackLines, maxHeight)
  if not fs or not text or not maxWidth then return end

  local font, _, flags = fs:GetFont()
  if not font then return end

  local size = TITLE_BASE_SIZE
  fs:SetFont(font, size, flags)
  fs:SetWidth(maxWidth)
  fs:SetText(text)

  local limitLines = maxLines or 2
  fs:SetMaxLines(limitLines)
  fs:SetWordWrap(true)
  local function exceeds()
    local overWidth = fs:GetStringWidth() > maxWidth
    local lineHeight = fs:GetLineHeight() or size
    local overHeight = fs:GetStringHeight() > (lineHeight * limitLines)
    local overBounds = maxHeight and (fs:GetStringHeight() > maxHeight)
    return overWidth or overHeight or overBounds
  end

  while size > TITLE_MIN_SIZE and exceeds() do
    size = size - 1
    fs:SetFont(font, size, flags)
    fs:SetText(text)
  end

  if exceeds() and fallbackLines and fallbackLines > limitLines then
    limitLines = fallbackLines
    fs:SetMaxLines(limitLines)
    size = TITLE_BASE_SIZE
    fs:SetFont(font, size, flags)
    fs:SetText(text)

    while size > TITLE_MIN_SIZE and exceeds() do
      size = size - 1
      fs:SetFont(font, size, flags)
      fs:SetText(text)
    end
  end

  if maxHeight then
    fs:SetHeight(math.min(maxHeight, fs:GetStringHeight() or maxHeight))
  end
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
