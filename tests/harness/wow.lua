-- Fake WoW client: a table-driven "world" (clock, player, units, items, chat...) plus the
-- game API functions the addon calls, installed into a sandbox environment.

local Widgets = dofile(HARNESS_DIR .. "/widgets.lua")

local Wow = {}

-- Tooltip methods.
Widgets.Define("SetOwner", function(self, owner, anchor)
	self.owner, self.anchor = owner, anchor
	self.lines = {}
end)
Widgets.Define("AddLine AddDoubleLine", function(self, ...)
	self.lines = self.lines or {}
	self.lines[#self.lines + 1] = { ... }
end)
Widgets.Define("ClearLines", function(self)
	self.lines = {}
end)
Widgets.Define("NumLines", function(self)
	return #(self.lines or {})
end)

--- A value the game would hide from addons. Any attempt to inspect it raises.
local SECRET = newproxy(true)
do
	local meta = getmetatable(SECRET)
	local function Forbidden()
		error("attempt to inspect a secret value", 2)
	end
	meta.__index = Forbidden
	meta.__newindex = Forbidden
	meta.__call = Forbidden
	meta.__concat = Forbidden
	meta.__add = Forbidden
	meta.__sub = Forbidden
	meta.__mul = Forbidden
	meta.__div = Forbidden
	meta.__unm = Forbidden
	meta.__lt = Forbidden
	meta.__le = Forbidden
	meta.__len = Forbidden
	meta.__tostring = Forbidden
end
Wow.SECRET = SECRET

local GLOBAL_STRINGS = {
	LOOT_ITEM_SELF = "You receive loot: %s.",
	LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d.",
	LOOT_ITEM_PUSHED_SELF = "You receive item: %s.",
	LOOT_ITEM_PUSHED_SELF_MULTIPLE = "You receive item: %sx%d.",
	LOOT_ITEM_CREATED_SELF = "You create: %s.",
	LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d.",
	COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience.",
	COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = "You gain %d experience.",
	LARGE_NUMBER_SEPERATOR = ",",
	CALENDAR_FIRST_WEEKDAY = 1,
}

local World = {}
World.__index = World

---@return table world
function Wow.NewWorld(options)
	options = options or {}
	local world = setmetatable({
		options = options,
		clock = { server = options.now or 1790000000, uptime = 5000 },
		timers = {},
		nextTimerId = 0,
		eventFrames = {},
		unknownEvents = {},
		createdObjects = 0,
		errors = {},
		printed = {},
		player = {
			guid = "Player-1-0000AAAA",
			name = "Tester",
			realm = "TestRealm",
			level = 10,
			maxLevel = 60,
			xp = 100,
			xpMax = 1000,
			afk = false,
			money = 50000,
		},
		units = {},
		items = {},
		auctionPrices = {},
		quests = {},
		achievements = {},
		zone = { name = "Elwynn Forest", instanceType = "none" },
		chatFilters = {},
		registryCallbacks = {},
		popups = {},
		combat = false,
		loadedAddons = {},
		missingAtlases = {},
		missingFiles = {},
		requestedItems = {},
		settingsCategories = {},
		openedSettings = {},
		cursor = { x = 0, y = 0 },
		legacyConfigID = 501,
		tooltips = {},
		unitErrors = {},
		missingFonts = {},
		activeEditBox = nil,
		openedChat = {},
		menus = {},
		lootSources = {}, -- the open loot window's source GUID per slot
		itemGUIDs = {}, -- item GUID -> itemID
		bags = {}, -- bags[bag][slot] = { itemID, locked }
		accentCallbacks = {},
		auctionatorCallbacks = {},
		ldbObjects = {},
		compartment = {},
	}, World)
	return world
end

--- Fires a game event at every frame that registered it.
function World:Fire(event, ...)
	local frames = self.eventFrames[event]
	if not frames then
		return
	end
	-- Snapshot first: handlers may register or unregister while dispatching.
	local list = {}
	for frame in pairs(frames) do
		list[#list + 1] = frame
	end
	for _, frame in ipairs(list) do
		Widgets.RunScript(frame, "OnEvent", event, ...)
	end
end

--- Advances both clocks and runs every timer that comes due, in order.
function World:Advance(seconds)
	local target = self.clock.uptime + seconds
	while true do
		local nextTimer
		for _, timer in ipairs(self.timers) do
			if not timer.cancelled and timer.due <= target and (not nextTimer or timer.due < nextTimer.due) then
				nextTimer = timer
			end
		end
		if not nextTimer then
			break
		end
		local delta = nextTimer.due - self.clock.uptime
		self.clock.uptime = nextTimer.due
		self.clock.server = self.clock.server + delta
		if nextTimer.interval then
			nextTimer.due = nextTimer.due + nextTimer.interval
			nextTimer.remaining = nextTimer.remaining and nextTimer.remaining - 1
			if nextTimer.remaining == 0 then
				nextTimer.cancelled = true
			end
		else
			nextTimer.cancelled = true
		end
		nextTimer.callback(nextTimer.handle)
	end
	self.clock.server = self.clock.server + (target - self.clock.uptime)
	self.clock.uptime = target
end

--- Number of timers still waiting to run.
function World:PendingTimers()
	local count = 0
	for _, timer in ipairs(self.timers) do
		if not timer.cancelled then
			count = count + 1
		end
	end
	return count
end

--- Runs a chat message through the registered message filters, the way the chat frame
--- would before displaying it. Returns the (possibly rewritten) message and whether it
--- was discarded.
function World:Chat(event, message, author, ...)
	local args = { message, author, ... }
	for _, filter in ipairs(self.chatFilters[event] or {}) do
		local result = { filter(nil, event, unpack(args, 1, 14)) }
		if result[1] then
			return nil, true
		end
		if #result > 1 then
			args = { unpack(result, 2, 15) }
		end
	end
	return args[1], false, args
end

--- Simulates clicking a hyperlink in chat.
function World:ClickLink(link, text, button)
	for _, entry in ipairs(self.registryCallbacks.SetItemRef or {}) do
		entry.func(entry.owner, link, text, button or "LeftButton", nil)
	end
end

local function Copy(source, into)
	into = into or {}
	for key, value in pairs(source) do
		into[key] = value
	end
	return into
end

--- Builds a sandbox environment exposing the fake API backed by the given world.
function Wow.CreateEnvironment(world)
	local options = world.options
	local env = {}
	world.env = env

	-- Lua standard library (no io/os/require/load*: addons can't use them either).
	for _, name in ipairs({
		"assert",
		"error",
		"ipairs",
		"next",
		"pairs",
		"pcall",
		"rawequal",
		"rawget",
		"rawset",
		"select",
		"setmetatable",
		"getmetatable",
		"tonumber",
		"tostring",
		"type",
		"unpack",
		"xpcall",
		"newproxy",
	}) do
		env[name] = _G[name]
	end
	env.string = Copy(string)
	env.table = Copy(table)
	env.math = Copy(math)
	env.math.random = function(low, high)
		world.randomState = ((world.randomState or 12345) * 1103515245 + 12345) % 2147483648
		local fraction = world.randomState / 2147483648
		if not low then
			return fraction
		elseif not high then
			low, high = 1, low
		end
		return low + math.floor(fraction * (high - low + 1))
	end
	env._G = env
	env.print = function(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[#parts + 1] = tostring((select(index, ...)))
		end
		world.printed[#world.printed + 1] = table.concat(parts, " ")
	end
	env.time = function(fields)
		if fields then
			return os.time(fields)
		end
		return world.clock.server
	end
	env.date = function(format, timestamp)
		return os.date(format, timestamp or world.clock.server)
	end
	env.debugprofilestop = function()
		return os.clock() * 1000
	end

	-- WoW string/table helpers.
	env.strsplit = function(separator, text, limit)
		local results = {}
		local position = 1
		while true do
			if limit and #results == limit - 1 then
				results[#results + 1] = text:sub(position)
				break
			end
			local first, last = text:find(separator, position, true)
			if not first then
				results[#results + 1] = text:sub(position)
				break
			end
			results[#results + 1] = text:sub(position, first - 1)
			position = last + 1
		end
		return unpack(results)
	end
	env.strtrim = function(text)
		return (text:gsub("^%s+", ""):gsub("%s+$", ""))
	end
	env.wipe = function(t)
		for key in pairs(t) do
			t[key] = nil
		end
		return t
	end
	env.tinsert = table.insert
	env.tremove = table.remove
	env.format = string.format
	env.floor = math.floor

	for name, value in pairs(GLOBAL_STRINGS) do
		env[name] = value
	end

	-- Secrets and error isolation.
	env.issecretvalue = function(value)
		return rawequal(value, SECRET)
	end
	env.geterrorhandler = function()
		return function(err)
			world.errors[#world.errors + 1] = err
		end
	end
	env.securecallfunction = function(fn, ...)
		local results = { pcall(fn, ...) }
		if not results[1] then
			world.errors[#world.errors + 1] = results[2]
			return
		end
		return unpack(results, 2, table.maxn(results))
	end

	-- Time.
	env.GetTime = function()
		return world.clock.uptime
	end
	env.GetServerTime = function()
		return world.clock.server
	end
	env.C_Timer = {}
	local function AddTimer(delay, callback, interval, iterations)
		world.nextTimerId = world.nextTimerId + 1
		local timer = {
			id = world.nextTimerId,
			due = world.clock.uptime + delay,
			callback = callback,
			interval = interval,
			remaining = iterations,
		}
		local handle = {
			Cancel = function()
				timer.cancelled = true
			end,
			IsCancelled = function()
				return timer.cancelled == true
			end,
		}
		timer.handle = handle
		world.timers[#world.timers + 1] = timer
		return handle
	end
	env.C_Timer.After = function(delay, callback)
		AddTimer(delay, callback)
	end
	env.C_Timer.NewTimer = function(delay, callback)
		return AddTimer(delay, callback)
	end
	env.C_Timer.NewTicker = function(interval, callback, iterations)
		return AddTimer(interval, callback, interval, iterations)
	end

	-- Frames.
	env.CreateFrame = function(frameType, name, parent, template)
		local frame = Widgets.Create(world, frameType, name, parent, { template = template })
		if template == "MinimalScrollBar" or template == "WowScrollBoxList" or template == "WowScrollBox" then
			frame.allowChildren = true
		end
		if name then
			env[name] = frame
		end
		return frame
	end
	env.UIParent = Widgets.Create(world, "Frame", "UIParent")
	env.UIParent.width, env.UIParent.height = 1920, 1080
	env.GameTooltip = Widgets.Create(world, "GameTooltip", "GameTooltip")
	env.GameTooltip.shown = false
	env.UISpecialFrames = {}
	env.SlashCmdList = {}
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, _, _, data)
		world.popups[#world.popups + 1] = { which = which, data = data }
		return {}
	end
	env.CreateFont = function(name)
		local font = { name = name }
		-- Like the client: no return value, and an error for a font file that can't load.
		function font:SetFont(path, size, flags)
			if world.missingFonts[path] then
				error("invalid font asset")
			end
			self.path, self.size, self.flags = path, size, flags
		end
		function font:GetFont()
			return self.path, self.size, self.flags
		end
		function font:SetShadowColor() end
		function font:SetShadowOffset() end
		function font:SetTextColor() end
		function font:SetJustifyH() end
		if name then
			env[name] = font
		end
		return font
	end
	env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
	env.Mixin = function(object, ...)
		for index = 1, select("#", ...) do
			for key, value in pairs((select(index, ...))) do
				object[key] = value
			end
		end
		return object
	end
	env.CreateFromMixins = function(...)
		return env.Mixin({}, ...)
	end
	env.PixelUtil = {
		GetPixelToUIUnitFactor = function()
			return 1
		end,
		GetNearestPixelSize = function(size, _, minPixels)
			return math.max(size, minPixels or 0)
		end,
		SetHeight = function(region, height)
			region:SetHeight(height)
		end,
		SetWidth = function(region, width)
			region:SetWidth(width)
		end,
		SetSize = function(region, width, height)
			region:SetSize(width, height)
		end,
		SetPoint = function(region, ...)
			region:SetPoint(...)
		end,
	}
	env.C_Texture = {
		GetAtlasInfo = function(atlas)
			if world.missingAtlases[atlas] then
				return nil
			end
			return { width = 16, height = 16, file = 1 }
		end,
	}
	env.GetFileIDFromPath = function(path)
		if world.missingFiles[path] then
			return nil
		end
		return 100000 + #path
	end
	env.GetCursorPosition = function()
		return world.cursor.x, world.cursor.y
	end
	env.InCombatLockdown = function()
		return world.combat
	end
	env.IsShiftKeyDown = function()
		return world.shiftDown == true
	end
	env.GetBuildInfo = function()
		return "1.60.1", "70124", "Oct 1 2026", 16001
	end
	env.C_Secrets = {
		HasSecretRestrictions = function()
			return false
		end,
	}
	env.YES = "Yes"
	env.NO = "No"
	env.BaseScrollBoxEvents = { OnScroll = "OnScroll", OnLayout = "OnLayout", OnSizeChanged = "OnSizeChanged" }
	env.GetCVarBool = function()
		return false
	end

	-- ScrollBox framework.
	env.CreateDataProvider = function(collection)
		local provider = { collection = collection or {} }
		function provider:GetSize()
			return #self.collection
		end
		function provider:Enumerate()
			return ipairs(self.collection)
		end
		function provider:Find(index)
			return self.collection[index]
		end
		return provider
	end
	env.CreateScrollBoxListLinearView = function()
		local view = {}
		function view:SetElementInitializer(frameType, initializer)
			self.frameType = frameType
			self.initializer = function(row, data)
				row.elementData = data
				initializer(row, data)
			end
		end
		function view:SetElementExtent(extent)
			self.extent = extent
		end
		function view:SetPadding() end
		return view
	end
	env.ScrollUtil = {
		InitScrollBoxListWithScrollBar = function(scrollBox, _, view)
			scrollBox:SetView(view)
		end,
		AddManagedScrollBarVisibilityBehavior = function() end,
		RegisterScrollBoxWithScrollBar = function() end,
	}
	env.ScrollBoxConstants = { RetainScrollPosition = true, DiscardScrollPosition = false }

	-- Settings panel.
	env.Settings = {
		VarType = { Boolean = "boolean", Number = "number", String = "string" },
		RegisterVerticalLayoutCategory = function(name)
			local category = { name = name, settings = {}, initializers = {} }
			function category:GetID()
				return 77
			end
			local layout = {}
			function layout:AddInitializer(initializer)
				category.initializers[#category.initializers + 1] = initializer
			end
			world.settingsCategories[#world.settingsCategories + 1] = category
			return category, layout
		end,
		RegisterAddOnCategory = function(category)
			category.registered = true
		end,
		RegisterAddOnSetting = function(category, variable, variableKey, variableTbl, variableType, name, default)
			local setting = {
				variable = variable,
				key = variableKey,
				table = variableTbl,
				type = variableType,
				name = name,
				default = default,
			}
			function setting:SetValueChangedCallback(callback)
				self.callback = callback
			end
			function setting:SetValue(value)
				variableTbl[variableKey] = value
				if self.callback then
					self.callback(self, value)
				end
			end
			function setting:GetValue()
				return variableTbl[variableKey]
			end
			-- Like Blizzard's: tells listeners (the control and the change callback) to read
			-- the value again.
			function setting:NotifyUpdate()
				self.notified = (self.notified or 0) + 1
				if self.callback then
					self.callback(self, variableTbl[variableKey])
				end
			end
			category.settings[variableKey] = setting
			return setting
		end,
		CreateCheckbox = function(_, setting)
			setting.control = "checkbox"
		end,
		CreateSlider = function(_, setting, sliderOptions)
			setting.control = "slider"
			setting.options = sliderOptions
		end,
		CreateDropdown = function(_, setting, getOptions)
			setting.control = "dropdown"
			setting.getOptions = getOptions
		end,
		CreateSliderOptions = function(minimum, maximum, step)
			local sliderOptions = { minimum = minimum, maximum = maximum, step = step }
			function sliderOptions:SetLabelFormatter(_, formatter)
				self.formatter = formatter
			end
			return sliderOptions
		end,
		CreateControlTextContainer = function()
			local container = { data = {} }
			function container:Add(value, label)
				self.data[#self.data + 1] = { value = value, label = label }
			end
			function container:GetData()
				return self.data
			end
			return container
		end,
		OpenToCategory = function(categoryID)
			world.openedSettings[#world.openedSettings + 1] = categoryID
		end,
	}
	env.CreateSettingsListSectionHeaderInitializer = function(name)
		return { kind = "header", name = name }
	end
	env.CreateSettingsButtonInitializer = function(name, buttonText, click)
		return { kind = "button", name = name, buttonText = buttonText, click = click }
	end
	env.MinimalSliderWithSteppersMixin = { Label = { Left = 1, Right = 2 } }

	-- Units.
	local function Unit(unit)
		if unit == "player" then
			return world.player
		end
		return world.units[unit]
	end
	env.UnitExists = function(unit)
		return Unit(unit) ~= nil
	end
	env.UnitGUID = function(unit)
		if world.unitErrors[unit] then
			error("unit token not allowed here")
		end
		local data = Unit(unit)
		return data and data.guid
	end
	-- Forever (Camelot): the second value is the surname, not a realm.
	env.UnitName = function(unit)
		local data = Unit(unit)
		if data then
			return data.name, data.surname
		end
	end
	env.NameUtil = {
		FormatUnitNameForDisplay = function(unit)
			local name, surname = env.UnitName(unit)
			return surname and (name .. " " .. surname) or name
		end,
	}
	env.GetRealmName = function()
		return world.player.realm
	end
	env.UnitFullName = function(unit)
		local data = Unit(unit)
		return data and data.name, data and data.realm
	end
	env.GetNormalizedRealmName = function()
		return world.player.realm
	end
	env.UnitLevel = function(unit)
		local data = Unit(unit)
		return data and data.level or 0
	end
	env.UnitXP = function()
		return world.player.xp
	end
	env.UnitXPMax = function()
		return world.player.xpMax
	end
	env.UnitIsAFK = function(unit)
		local data = Unit(unit)
		return data and data.afk
	end
	env.UnitCanAttack = function(_, unit)
		local data = Unit(unit)
		return data and data.attackable == true
	end
	env.UnitPlayerControlled = function(unit)
		local data = Unit(unit)
		return data and data.playerControlled == true
	end
	env.UnitCreatureType = function(unit)
		local data = Unit(unit)
		if data and data.typeID then
			return data.typeName or "Beast", data.typeID
		end
	end
	env.UnitCreatureFamily = function(unit)
		local data = Unit(unit)
		if data and data.familyID then
			return "Wolf", data.familyID
		end
	end
	env.UnitClassification = function(unit)
		local data = Unit(unit)
		return data and data.classification or "normal"
	end
	env.UnitTokenFromGUID = function(guid)
		if rawequal(guid, SECRET) then
			return SECRET
		end
		for token, data in pairs(world.units) do
			if data.guid == guid then
				return token
			end
		end
	end
	env.GetMoney = function()
		return world.player.money
	end
	env.IsInInstance = function()
		local instanceType = world.zone.instanceType
		return instanceType ~= "none", instanceType
	end
	env.GetInstanceInfo = function()
		local zone = world.zone
		local inside = zone.instanceType ~= "none"
		return inside and zone.name or "Eastern Kingdoms",
			zone.instanceType,
			inside and 1 or 0,
			inside and "Normal" or "",
			inside and 5 or 0,
			0,
			false,
			zone.instanceID or (inside and 36 or 0),
			0,
			nil,
			false
	end
	env.GetXPExhaustion = function()
		return world.player.rested
	end
	env.GameRulesUtil = {
		IsPlayerAtEffectiveMaxLevel = function()
			return world.player.level >= world.player.maxLevel
		end,
	}
	env.GetRealZoneText = function()
		return world.zone.name
	end
	env.C_CreatureInfo = {
		GetCreatureFamilyInfo = function(familyID)
			return { name = "Family " .. familyID, iconFile = 2000 + familyID }
		end,
		GetCreatureTypeIDs = function()
			local ids = {}
			for id = 1, 15 do
				ids[id] = id
			end
			return ids
		end,
		GetCreatureTypeInfo = function(typeID)
			local names = {
				"Beast",
				"Dragonkin",
				"Demon",
				"Elemental",
				"Giant",
				"Undead",
				"Humanoid",
				"Critter",
				"Mechanical",
				"Not specified",
				"Totem",
				"Non-combat Pet",
				"Gas Cloud",
				"Wild Pet",
				"Aberration",
			}
			return names[typeID] and { id = typeID, name = names[typeID] }
		end,
	}
	env.C_TooltipInfo = {
		GetHyperlink = function(link)
			local guid = link:match("^unit:(.+)$")
			return { lines = guid and world.tooltips[guid] or {} }
		end,
	}

	-- Items.
	env.C_Item = {
		GetItemInfo = function(item)
			local data = world.items[item]
			if not data then
				return nil
			end
			return data.name,
				data.link,
				data.quality or 1,
				10,
				1,
				"Misc",
				"Junk",
				20,
				"",
				data.icon or 134400,
				data.sellPrice or 0,
				15,
				0,
				data.bindType or 0
		end,
		GetItemIDByGUID = function(guid)
			return world.itemGUIDs[guid]
		end,
		GetItemIconByID = function(itemID)
			local data = world.items[itemID]
			return data and data.icon or 134400
		end,
		GetItemQualityByID = function(itemID)
			local data = world.items[itemID]
			return data and data.quality
		end,
		GetItemNameByID = function(itemID)
			local data = world.items[itemID]
			return data and data.name
		end,
		GetItemQualityColor = function()
			return 1, 1, 1, "ffffffff"
		end,
		RequestLoadItemDataByID = function(itemID)
			world.requestedItems[#world.requestedItems + 1] = itemID
		end,
	}
	-- Loot windows and bags.
	env.GetNumLootItems = function()
		return #world.lootSources
	end
	if not options.noLootSources then
		env.GetLootSourceInfo = function(slot)
			return world.lootSources[slot], 1
		end
	end
	env.C_Container = {
		GetContainerItemInfo = function(bag, slot)
			local item = world.bags[bag] and world.bags[bag][slot]
			if item then
				return { itemID = item.itemID, isLocked = item.locked == true, stackCount = 1 }
			end
		end,
	}
	env.C_QuestLog = {
		GetTitleForQuestID = function(questID)
			return world.quests[questID]
		end,
	}
	env.GetAchievementInfo = function(achievementID)
		local data = world.achievements[achievementID]
		if not data then
			return nil
		end
		return achievementID, data.name, 10, true, 1, 1, 26, "", 0, data.icon or 236376
	end

	-- Chat.
	env.ChatFrameUtil = {
		AddMessageEventFilter = function(event, filter)
			world.chatFilters[event] = world.chatFilters[event] or {}
			table.insert(world.chatFilters[event], filter)
		end,
		GetActiveWindow = function()
			return world.activeEditBox
		end,
		OpenChat = function(text)
			world.openedChat[#world.openedChat + 1] = text
		end,
	}
	-- Context menus (Blizzard_Menu): the generator runs at once and the entries are kept, so
	-- tests can read them and pick checkboxes and buttons.
	env.MenuUtil = {
		CreateContextMenu = function(owner, generator)
			local menu = { owner = owner, entries = {} }
			local root = {}
			local function Add(entry)
				menu.entries[#menu.entries + 1] = entry
				return entry
			end
			function root.CreateTitle(_, text)
				return Add({ kind = "title", text = text })
			end
			function root.CreateDivider()
				return Add({ kind = "divider" })
			end
			function root.CreateButton(_, text, callback, data)
				return Add({ kind = "button", text = text, callback = callback, data = data })
			end
			function root.CreateCheckbox(_, text, isSelected, setSelected, data)
				return Add({
					kind = "checkbox",
					text = text,
					isSelected = isSelected,
					setSelected = setSelected,
					data = data,
				})
			end
			generator(owner, root)
			world.menus[#world.menus + 1] = menu
			return menu
		end,
	}
	env.EventRegistry = {
		RegisterCallback = function(_, event, func, owner)
			world.registryCallbacks[event] = world.registryCallbacks[event] or {}
			table.insert(world.registryCallbacks[event], { func = func, owner = owner })
		end,
	}

	env.Enum = {
		PlayerInteractionType = {
			TradePartner = 1,
			Merchant = 5,
			Banker = 8,
			GuildBanker = 10,
			Vendor = 12,
			MailInfo = 17,
			Auctioneer = 21,
			CharacterBanker = 67,
			AccountBanker = 68,
			QuestGiver = 3,
		},
	}

	env.C_AddOns = {
		GetAddOnMetadata = function(_, field)
			if field == "Version" then
				return options.version or "@project-version@"
			end
		end,
		IsAddOnLoaded = function(name)
			return world.loadedAddons[name] == true
		end,
	}

	env.Constants = {
		CharacterNameSeparatorConsts = { CHARACTERNAME_SURNAME_SEPARATOR = " " },
	}

	-- Legacy Points (Forever).
	if options.legacy ~= false then
		world.legacy = world.legacy or { quantity = 0, spent = 0 }
		env.Constants.LegacyConsts = {
			LEGACY_POINTS_TRAIT_CURRENCY_ID = 4225,
			LEGACY_TREE_PROFESSIONS_ID = 1187,
			LEGACY_TREE_ADVENTURE_ID = 1188,
			LEGACY_TREE_PROGRESSION_ID = 1189,
		}
		env.C_Traits = {
			GetConfigIDByTreeID = function()
				return world.legacyConfigID
			end,
			GetTreeCurrencyInfo = function()
				return {
					{ traitCurrencyID = 4225, quantity = world.legacy.quantity, spent = world.legacy.spent },
				}
			end,
			GetTraitCurrencyInfo = function()
				return 0, 0, nil, 5555
			end,
		}
	end

	-- Optional third-party addons.
	if options.auctionator then
		world.loadedAddons.Auctionator = true
		env.Auctionator = {
			API = {
				v1 = {
					GetAuctionPriceByItemID = function(callerID, itemID)
						assert(callerID == "Sesh", "unexpected callerID")
						return world.auctionPrices[itemID]
					end,
					RegisterForDBUpdate = function(callerID, callback)
						assert(callerID == "Sesh", "unexpected callerID")
						world.auctionatorCallbacks[#world.auctionatorCallbacks + 1] = callback
					end,
				},
			},
		}
	end
	if options.ellesmere then
		world.loadedAddons.EllesmereUI = true
		env.EllesmereUI = {
			GetAccentColor = function()
				return 0.2, 0.4, 0.6
			end,
			RegAccent = function(entry)
				world.accentCallbacks[#world.accentCallbacks + 1] = entry.fn
			end,
			GetFontPath = function()
				return "Fonts\\Expressway.ttf"
			end,
		}
	end
	if options.ldb then
		local ldb = {}
		function ldb:NewDataObject(name, object)
			world.ldbObjects[name] = object
			return object
		end
		env.LibStub = setmetatable({}, {
			__call = function(_, name)
				if name == "LibDataBroker-1.1" then
					return ldb
				end
			end,
		})
	end
	if options.compartment then
		env.AddonCompartmentFrame = {
			RegisterAddon = function(_, data)
				world.compartment[#world.compartment + 1] = data
			end,
		}
	end

	world.baselineGlobals = {}
	for key in pairs(env) do
		world.baselineGlobals[key] = true
	end
	return env
end

--- Globals the addon created that it isn't allowed to.
function World:LeakedGlobals(allowed)
	local leaked = {}
	for key in pairs(self.env) do
		if not self.baselineGlobals[key] and not allowed[key] then
			leaked[#leaked + 1] = key
		end
	end
	table.sort(leaked)
	return leaked
end

-- Saved variables round trip -------------------------------------------------------

local function SerializeSaved(value)
	local kind = type(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("non-finite number in saved variables")
		end
		return string.format("%.17g", value)
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind == "table" then
		local parts = {}
		for key, inner in pairs(value) do
			if type(key) ~= "string" and type(key) ~= "number" then
				error("unsupported key type in saved variables: " .. type(key))
			end
			parts[#parts + 1] = "[" .. SerializeSaved(key) .. "]=" .. SerializeSaved(inner)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot save a " .. kind)
end

--- Writes a saved variable out and reads it back, the way the client does at logout.
function Wow.RoundTrip(value)
	if value == nil then
		return nil
	end
	local chunk = assert(loadstring("return " .. SerializeSaved(value)))
	return chunk()
end

Wow.World = World
return Wow
