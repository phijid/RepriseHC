-- TradeMailBlock.lua — Guild-only trade, mail, and auction house blocking
-- Uses: RepriseHC.IsGuildAllowed() and RepriseHC._tradeEnabled (tied to /rhc on|off)

local guildNames = {}
local playerRealm = GetRealmName() or ""

if RepriseHC._tradeEnabled == nil then RepriseHC._tradeEnabled = true end

-- ---------- Utils ----------
local function NormalizeName(name)
  if not name or name == "" then return nil, nil end
  name = name:gsub("^%s+",""):gsub("%s+$","")
  local base, realm = name:match("^([^%-]+)%-(.+)$")
  base = base or name
  realm = realm or playerRealm
  local baseNorm = base:sub(1,1):upper() .. base:sub(2):lower()
  local fullNorm = baseNorm .. "-" .. realm
  return baseNorm, fullNorm
end

local function InGuildByName(name)
  local short, full = NormalizeName(name)
  if not short then return false end
  return guildNames[short] or guildNames[full] or false
end

local function InGuildByUnit(unit)
  if not UnitExists(unit) or not UnitIsPlayer(unit) then return false end
  local name, realm = UnitName(unit)
  if realm and realm ~= "" then name = name .. "-" .. realm end
  return InGuildByName(name)
end

function RepriseHC.RebuildGuildCache()
  wipe(guildNames)
  if not IsInGuild() then return end
  GuildRoster()
  local n = GetNumGuildMembers()
  for i = 1, n do
    local fullName = GetGuildRosterInfo(i)
    if fullName then
      local short, full = NormalizeName(fullName)
      if short then
        guildNames[short] = true
        if full then guildNames[full] = true end
      end
    end
  end
end

-- ---------- Startup ----------
local F = CreateFrame("Frame", "RepriseHC_TradeBlock")

F:RegisterEvent("PLAYER_LOGIN")
F:RegisterEvent("PLAYER_GUILD_UPDATE")

F:RegisterEvent("GUILD_ROSTER_UPDATE")

-- Helper: master gate
local function AllowedAndEnabled()
  return (RepriseHC.IsGuildAllowed and RepriseHC.IsGuildAllowed()) and (RepriseHC._tradeEnabled == true)
end

-- ---------- Trading: block non-guild ----------
local TradeHandler = CreateFrame("Frame")
TradeHandler:RegisterEvent("TRADE_REQUEST")

local TradeShowHandler = CreateFrame("Frame")

TradeShowHandler:RegisterEvent("TRADE_SHOW")

local _InitiateTrade = InitiateTrade
InitiateTrade = function(unit)
  if not AllowedAndEnabled() then return _InitiateTrade(unit) end
  if InGuildByUnit(unit) then
    return _InitiateTrade(unit)
  else
    UIErrorsFrame:AddMessage("Closed trade window, player not in the guild.", 1, 0.2, 0.2)
    RepriseHC.Print("Blocked trade window from opening, player not in the guild.")
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
  end
end

-- ---------- Mail: block sending to non-guild ----------
local _SendMail = SendMail
SendMail = function(recipient, subject, body, ...)
  if not AllowedAndEnabled() then
    return _SendMail(recipient, subject, body, ...)
  end
  if InGuildByName(recipient) then
    return _SendMail(recipient, subject, body, ...)
  else
    UIErrorsFrame:AddMessage("Cannot send mail to players not in the guild.", 1, 0.2, 0.2)
    RepriseHC.Print("Blocked mail from sending, player not in the guild.")
  end
end

-- ---------- Mail: block OPENING non-guild mail ----------
local function CloseIfSenderNotGuild()
  if not AllowedAndEnabled() then return end
  if not OpenMailFrame or not OpenMailFrame:IsShown() then return end
  local sender = OpenMailSenderName and OpenMailSenderName:GetText()
  if sender and not InGuildByName(sender) then
    CloseMail()
    UIErrorsFrame:AddMessage("Cannot open mail from players not in the guild.", 1, 0.2, 0.2)
    RepriseHC.Print("Blocked mail from opening, player not in the guild.")
  end
end

-- Hook updates when a mail is selected
if OpenMail_Update then
  hooksecurefunc("OpenMail_Update", CloseIfSenderNotGuild)
end

-- Block taking items/money from non-guild mail via API hooks
local _TakeInboxItem = TakeInboxItem
TakeInboxItem = function(index, attachment)
  if not AllowedAndEnabled() then return _TakeInboxItem(index, attachment) end
  local _, _, sender = GetInboxHeaderInfo(index)
  if sender and not InGuildByName(sender) then
    UIErrorsFrame:AddMessage("Cannot take item from inbox, player not in the guild.", 1, 0.2, 0.2)
    RepriseHC.Print("Blocked item from adding to your inventory, player not in the guild.")
  else
    return _TakeInboxItem(index, attachment)
  end
end

local _TakeInboxMoney = TakeInboxMoney
TakeInboxMoney = function(index)
  if not AllowedAndEnabled() then return _TakeInboxMoney(index) end
  local _, _, sender = GetInboxHeaderInfo(index)
  if sender and not InGuildByName(sender) then
    UIErrorsFrame:AddMessage("Cannot take money from inbox, player not in the guild.", 1, 0.2, 0.2)
    RepriseHC.Print("Blocked money from adding to your inventory, player not in the guild.")
  else
    return _TakeInboxMoney(index)
  end
end

-- ---------- Auction House: block interaction entirely ----------
local AHBlock = CreateFrame("Frame", "RepriseHC_AHBlock")
AHBlock:RegisterEvent("AUCTION_HOUSE_SHOW")   -- Classic Era


-- ========= Centralized Handlers for Trade/Mail/AH =========
local function __RHC_Trade_OnEvent(event, ...)
  if not (RepriseHC.IsGuildAllowed and RepriseHC.IsGuildAllowed()) then return end
  if event == "PLAYER_LOGIN" then
    C_Timer.After(2, function()
      if RepriseHC.RebuildGuildCache then RepriseHC.RebuildGuildCache() end
      if RepriseHC.Print then RepriseHC.Print("Guild Only trade, mail, and auction house protection loaded. (/rhc on|off)") end
    end)
  elseif event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE" then
    if RepriseHC.RebuildGuildCache then RepriseHC.RebuildGuildCache() end
  elseif event == "TRADE_REQUEST" then
    local requesterName = ...
    -- reuse existing logic via helpers
    if requesterName and not InGuildByName(requesterName) then
      CancelTrade()
      UIErrorsFrame:AddMessage("Closed trade window, player not in the guild.", 1, 0.2, 0.2)
      if RepriseHC.Print then RepriseHC.Print("Blocked trade window from opening, player not in the guild.") end
    end
  elseif event == "TRADE_SHOW" then
    local blocked = false
    if UnitExists("npc") and UnitIsPlayer("npc") and not InGuildByUnit("npc") then blocked = true
    elseif UnitExists("target") and UnitIsPlayer("target") and not InGuildByUnit("target") then blocked = true end
    if blocked then
      CancelTrade()
      UIErrorsFrame:AddMessage("Closed trade window, player not in the guild.", 1, 0.2, 0.2)
      if RepriseHC.Print then RepriseHC.Print("Blocked trade window from opening, player not in the guild.") end
    end
  elseif event == "AUCTION_HOUSE_SHOW" then
    C_Timer.After(0, function()
      if AuctionFrame and AuctionFrame:IsShown() then HideUIPanel(AuctionFrame) end
      if CloseAuctionHouse then pcall(CloseAuctionHouse) end
      UIErrorsFrame:AddMessage("Cannot use Auction House, guild only.", 1, 0.2, 0.2)
      if RepriseHC.Print then RepriseHC.Print("Blocked Auction House usage, guild only.") end
      if PlaySound then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
    end)
  end
end
RepriseHC.RegisterEvent("PLAYER_LOGIN", __RHC_Trade_OnEvent); RepriseHC._EnsureEvent("PLAYER_LOGIN")
RepriseHC.RegisterEvent("PLAYER_GUILD_UPDATE", __RHC_Trade_OnEvent); RepriseHC._EnsureEvent("PLAYER_GUILD_UPDATE")
RepriseHC.RegisterEvent("GUILD_ROSTER_UPDATE", __RHC_Trade_OnEvent); RepriseHC._EnsureEvent("GUILD_ROSTER_UPDATE")
RepriseHC.RegisterEvent("TRADE_REQUEST", __RHC_Trade_OnEvent); RepriseHC._EnsureEvent("TRADE_REQUEST")
RepriseHC.RegisterEvent("TRADE_SHOW", __RHC_Trade_OnEvent); RepriseHC._EnsureEvent("TRADE_SHOW")
RepriseHC.RegisterEvent("AUCTION_HOUSE_SHOW", __RHC_Trade_OnEvent); RepriseHC._EnsureEvent("AUCTION_HOUSE_SHOW")

