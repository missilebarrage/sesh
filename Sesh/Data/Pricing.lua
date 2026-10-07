local _, ns = ...

--- Item unit values: what an item can actually be sold for. Items that can be traded are
--- worth their Auctionator auction price when Auctionator knows one, otherwise their
--- vendor price. Soulbound items (bind on pickup, quest and account-bound items) can only
--- go to a vendor, so they're worth their vendor price. Lookups are cached per item until
--- Auctionator reports new scan data or an item's data finishes loading.
---@class SeshPricing
local Pricing = ns.Pricing
local Events = ns.Events

---@alias SeshPriceSource "auction"|"vendor"|"soulbound"

local cache = {} ---@type table<integer, integer>
local sources = {} ---@type table<integer, SeshPriceSource>
local loading = {} ---@type table<integer, boolean>
local unavailable = {} ---@type table<integer, boolean>
local revision = 0
local auctionator ---@type table? Auctionator.API.v1

-- Bind types whose items can't be put up for auction.
local SOULBOUND = {}
do
	local bind = Enum and Enum.ItemBind or {}
	for _, kind in ipairs({ bind.OnAcquire or 1, bind.Quest or 4, bind.ToWoWAccount or 7, bind.ToBnetAccount or 8 }) do
		SOULBOUND[kind] = true
	end
end

local function AuctionPrice(itemID)
	if not auctionator then
		return nil
	end
	local ok, price = pcall(auctionator.GetAuctionPriceByItemID, ns.NAME, itemID)
	price = ok and ns.Num(price)
	-- Full scans store buyout / quantity, which can be fractional.
	if price and price > 0 then
		return math.floor(price)
	end
end

--- Copper value of one item and how it was valued, or nil while the item's data is still
--- loading.
---@param itemID integer
---@return integer? unitValue
---@return SeshPriceSource? source
function Pricing.UnitValue(itemID)
	local cached = cache[itemID]
	if cached then
		return cached, sources[itemID]
	end
	local name, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = C_Item.GetItemInfo(itemID)
	if not name then
		if unavailable[itemID] then
			return 0, "vendor"
		end
		Pricing.LoadItem(itemID)
		return nil
	end
	local vendor = ns.Num(sellPrice) or 0
	if SOULBOUND[ns.Num(bindType) or -1] then
		cache[itemID], sources[itemID] = vendor, "soulbound"
	else
		local auction = AuctionPrice(itemID)
		cache[itemID], sources[itemID] = auction or vendor, auction and "auction" or "vendor"
	end
	return cache[itemID], sources[itemID]
end

--- Asks the client to load an item's data; SESH_VALUES_CHANGED fires when it arrives.
---@param itemID integer
function Pricing.LoadItem(itemID)
	if not loading[itemID] and not unavailable[itemID] then
		loading[itemID] = true
		C_Item.RequestLoadItemDataByID(itemID)
	end
end

--- Whether auction prices are available (Auctionator is installed and exposes its API).
---@return boolean
function Pricing.HasAuctionData()
	return auctionator ~= nil
end

--- Increments whenever cached prices change.
function Pricing.Revision()
	return revision
end

--- Forgets every cached price, e.g. after an auction house scan.
function Pricing.Invalidate()
	wipe(cache)
	wipe(sources)
	revision = revision + 1
	Events.Fire("SESH_VALUES_CHANGED")
end

local function OnItemDataLoaded(itemID, success)
	itemID = ns.Num(itemID)
	if not itemID or not loading[itemID] then
		return
	end
	loading[itemID] = nil
	if not success then
		unavailable[itemID] = true
	end
	revision = revision + 1
	Events.Debounce("itemDataLoaded", 0.5, function()
		Events.Fire("SESH_VALUES_CHANGED")
	end)
end

--- Connects to Auctionator when it's loaded. Called at PLAYER_LOGIN.
function Pricing.Init()
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if type(api) == "table" and type(api.GetAuctionPriceByItemID) == "function" then
		auctionator = api
		if type(api.RegisterForDBUpdate) == "function" then
			pcall(api.RegisterForDBUpdate, ns.NAME, function()
				-- Runs synchronously inside Auctionator's scan processing, which has no error
				-- protection: only schedule work here.
				pcall(Events.Debounce, "auctionatorUpdate", 2, Pricing.Invalidate)
			end)
		end
	end
	Events.On("ITEM_DATA_LOAD_RESULT", OnItemDataLoaded)
	-- Auctionator builds its price database at PLAYER_LOGIN; forget anything looked up earlier.
	Events.On("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
		if isInitialLogin or isReloadingUi then
			Pricing.Invalidate()
		end
	end)
end
