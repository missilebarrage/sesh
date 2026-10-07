local _, ns = ...

--- Raw gold and acquired items.
---
--- Money and pushed items that arrive while a merchant, mailbox, trade, auction house or
--- bank window is open (or just closed) don't count: they're transfers, purchases, or
--- sales of items whose value was already counted when they were looted.
---
--- Loot from an item (disenchanting it, opening a clam or a lockbox) counts like any loot,
--- and the item is recorded as used up: its value is taken off where it's used up, so it's
--- never counted twice, whenever and on whichever character that happens.
---@class SeshIncome : SeshTracker
local Income = ns.Income
local Recorder = ns.Recorder
local Session = ns.Session
local Pricing = ns.Pricing
local Events = ns.Events

-- The server's money update can land shortly after a window closes.
local CLOSE_GRACE_SECONDS = 2
-- Loot messages can arrive just after the loot window closes.
local LOOT_GRACE_SECONDS = 1
-- How long the item locked for a disenchant or for opening stays the likely loot source.
local LOCK_SECONDS = 10

local transferTypes = {} ---@type table<integer, boolean>
do
	local types = Enum and Enum.PlayerInteractionType or {}
	for _, name in ipairs({
		"TradePartner",
		"Merchant",
		"Vendor",
		"Banker",
		"GuildBanker",
		"CharacterBanker",
		"AccountBanker",
		"MailInfo",
		"Auctioneer",
	}) do
		if types[name] then
			transferTypes[types[name]] = true
		end
	end
end

local openWindows = {} ---@type table<integer, boolean>
local lastWindowClosedAt = -math.huge
local lastMoney ---@type number?
local playerGUID ---@type string?

---@class SeshConversion
---@field itemID integer? the item being turned into loot, when known
---@field used boolean whether the item was recorded as used up yet
---@field open boolean
---@field closedAt number

local conversion ---@type SeshConversion?
-- The bag item locked last (an item is locked while it's disenchanted or opened).
local lastLock = { at = -math.huge } ---@type {bag: integer?, slot: integer?, itemID: integer?, at: number}

---@class SeshLootPattern
---@field pattern string
---@field order integer[]
---@field pushed boolean

local lootPatterns = {} ---@type SeshLootPattern[]

local function AddLootPattern(globalName, pushed)
	local format = _G[globalName]
	if type(format) == "string" then
		local pattern, order = ns.FormatPattern(format)
		lootPatterns[#lootPatterns + 1] = { pattern = pattern, order = order, pushed = pushed }
	end
end
-- The "multiple" variants must be tried first: the single-item pattern would also match them.
AddLootPattern("LOOT_ITEM_SELF_MULTIPLE", false)
AddLootPattern("LOOT_ITEM_SELF", false)
AddLootPattern("LOOT_ITEM_PUSHED_SELF_MULTIPLE", true)
AddLootPattern("LOOT_ITEM_PUSHED_SELF", true)

--- Whether money or items arriving now come from a transfer or sale window.
---@return boolean
function Income.InTransferWindow()
	return next(openWindows) ~= nil or (GetTime() - lastWindowClosedAt) <= CLOSE_GRACE_SECONDS
end

-- The item a loot window's contents come from: the loot source the client reports, or
-- else the bag item locked just before (for a disenchant or for opening it).
local function SourceItem()
	if GetLootSourceInfo and GetNumLootItems then
		for slot = 1, ns.Num(GetNumLootItems()) or 0 do
			local ok, guid = pcall(GetLootSourceInfo, slot)
			guid = ok and ns.Str(guid)
			if guid and guid:find("^Item%-") then
				local found, itemID = pcall(C_Item.GetItemIDByGUID, guid)
				itemID = found and ns.Num(itemID)
				if itemID then
					ns.Count("conversionFromSource")
					return itemID
				end
			end
		end
	end
	if GetTime() - lastLock.at <= LOCK_SECONDS then
		-- An item that has been put down again was only being moved.
		local info = C_Container.GetContainerItemInfo(lastLock.bag, lastLock.slot)
		if not info or info.isLocked == true then
			ns.Count("conversionFromLock")
			return lastLock.itemID
		end
	end
	ns.Count("conversionUnknown")
end

local function InConversion()
	return conversion ~= nil and (conversion.open or GetTime() - conversion.closedAt <= LOOT_GRACE_SECONDS)
end

-- Loot is arriving from an item: the item is used up. Recorded when the first of the loot
-- arrives, so a loot window closed without looting changes nothing.
local function UseUpSource(session)
	if InConversion() and not conversion.used then
		conversion.used = true
		if conversion.itemID then
			Session.ConsumeItem(session, conversion.itemID, 1)
			ns.Count("itemsUsedUp")
		end
	end
end

local function OnLootOpened(_, isFromItem)
	conversion = nil
	if Recorder.Current() and ns.IsReadable(isFromItem) and isFromItem == true then
		conversion = { itemID = SourceItem(), used = false, open = true, closedAt = 0 }
	end
end

local function OnLootClosed()
	if conversion and conversion.open then
		conversion.open = false
		conversion.closedAt = GetTime()
	end
end

local function OnItemLockChanged(bag, slot)
	bag, slot = ns.Num(bag), ns.Num(slot)
	if not (bag and slot) then
		return -- an equipped item
	end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	local itemID = info and ns.Num(info.itemID)
	if itemID and info.isLocked == true then
		lastLock.bag, lastLock.slot, lastLock.itemID, lastLock.at = bag, slot, itemID, GetTime()
	end
end

function Income.Start()
	lastMoney = ns.Num(GetMoney())
	playerGUID = ns.Str(UnitGUID("player"))
end

local function OnInteractionShow(interactionType)
	interactionType = ns.Num(interactionType)
	if interactionType and transferTypes[interactionType] then
		openWindows[interactionType] = true
	end
end

local function OnInteractionHide(interactionType)
	interactionType = ns.Num(interactionType)
	if interactionType and openWindows[interactionType] then
		openWindows[interactionType] = nil
		lastWindowClosedAt = GetTime()
	end
end

local function OnMoney()
	local session = Recorder.Current()
	local money = ns.Num(GetMoney())
	if not (session and money) then
		return
	end
	local gained = money - (lastMoney or money)
	lastMoney = money
	if gained > 0 then
		if Income.InTransferWindow() then
			ns.Count("moneyIgnored")
		else
			UseUpSource(session)
			ns.Count("moneyCounted")
			Session.AddMoney(session, gained)
		end
	end
end

--- Parses one of your own loot messages. Returns itemID, count and whether the item was
--- pushed (quest reward, purchase...) rather than looted; nil for anything else.
---@param message string
---@return integer? itemID
---@return integer? count
---@return boolean? pushed
function Income.ParseLoot(message)
	for _, loot in ipairs(lootPatterns) do
		local link, count = ns.MatchFormat(message, loot.pattern, loot.order)
		if link then
			local itemID = tonumber(link:match("item:(%d+)"))
			if itemID then
				return itemID, tonumber(count) or 1, loot.pushed
			end
		end
	end
end

local function OnLoot(message, _, _, _, _, _, _, _, _, _, _, guid)
	local session = Recorder.Current()
	message = ns.Str(message)
	if not (session and message) then
		return
	end
	-- Cheap early exit for other players' loot when the looter is known.
	guid = ns.Str(guid)
	if guid and guid ~= "" and playerGUID and guid ~= playerGUID then
		return
	end
	local itemID, count, pushed = Income.ParseLoot(message)
	if not itemID then
		return
	end
	if pushed and Income.InTransferWindow() then
		ns.Count("itemsIgnored")
		return
	end
	UseUpSource(session)
	ns.Count("itemsCounted")
	Session.AddItem(session, itemID, count)
	-- Start loading the price now, so the item's value is ready when it's displayed.
	Pricing.UnitValue(itemID)
end

Events.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", OnInteractionShow)
Events.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", OnInteractionHide)
Events.On("PLAYER_MONEY", OnMoney)
Events.On("CHAT_MSG_LOOT", OnLoot)
Events.On("LOOT_OPENED", OnLootOpened)
Events.On("LOOT_CLOSED", OnLootClosed)
Events.On("ITEM_LOCK_CHANGED", OnItemLockChanged)
