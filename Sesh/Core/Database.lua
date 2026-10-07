local _, ns = ...

--- SavedVariables: SeshDB (account-wide settings and window positions) and SeshCharDB
--- (this character's sessions and levels). Data written by a newer Sesh is never
--- modified: the addon runs read-only and warns instead.
---@class SeshDatabase
local Database = ns.Database
local Events = ns.Events
local L = ns.L

--- Default values for every setting. Keys here are the only settings Sesh knows about.
Database.DEFAULTS = {
	windowScale = 1,
	openOnLogin = false,
	excludeAfk = true,
	resumeMinutes = 5,
	minSessionMinutes = 5,
	weekStart = 1, -- date("*t").wday numbering: 1 = Sunday, 2 = Monday
	heatmapMetric = "gold", -- "gold" | "xp" | "time"
	allowLinkRequests = true,
	brokerMetric = "goldPerHour",
	historyRange = "today",
	listKind = "items",
	levelChartMetric = "time", -- "time" | "xpPerHour" | "gold" | "kills" | "quests" | "deaths"
	announceLevels = true,
	miniMode = true,
	miniScale = 1,
	miniOpacity = 100, -- background and border, in percent
	-- One switch per number the mini window can show (MiniWindow.METRICS).
	miniFields = {
		duration = true,
		goldEarned = true,
		goldPerHour = true,
		rawGold = false,
		itemValue = false,
		xp = false,
		xpPerHour = true,
		levelUpIn = true,
		levelProgress = false,
		kills = false,
		quests = false,
		dungeons = false,
		deaths = false,
	},
	shareFields = {
		duration = true,
		goldEarned = true,
		goldPerHour = true,
		xp = true,
		xpPerHour = true,
		kills = true,
	},
	levelShareFields = {
		duration = true,
		xpPerHour = true,
		goldEarned = true,
		kills = true,
		quests = true,
		dungeons = true,
		deaths = true,
	},
}

-- Numbered migrations: MIGRATIONS[n] upgrades data from schema n - 1 to n.
local ACCOUNT_MIGRATIONS = {}
local CHARACTER_MIGRATIONS = {}

local VALID_POINTS = {
	TOPLEFT = true,
	TOP = true,
	TOPRIGHT = true,
	LEFT = true,
	CENTER = true,
	RIGHT = true,
	BOTTOMLEFT = true,
	BOTTOM = true,
	BOTTOMRIGHT = true,
}

local account ---@type table
local character ---@type table?
local accountReadOnly = false
local characterReadOnly = false

local function CopyDefault(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = CopyDefault(inner)
	end
	return copy
end

-- Settings that are a table of on/off switches, each bound to its own option: switches
-- added by a later version get their default.
local SWITCH_TABLES = { "miniFields" }

local function FillDefaults(settings)
	for key, default in pairs(Database.DEFAULTS) do
		if type(settings[key]) ~= type(default) then
			settings[key] = CopyDefault(default)
		end
	end
	for _, key in ipairs(SWITCH_TABLES) do
		local switches = settings[key]
		for switch, default in pairs(Database.DEFAULTS[key]) do
			if type(switches[switch]) ~= "boolean" then
				switches[switch] = default
			end
		end
	end
end

--- Upgrades data in place. Returns false when the data is unusable or newer than this
--- version of Sesh understands.
local function Upgrade(data, migrations)
	if type(data) ~= "table" then
		return false
	end
	local schema = data.schema
	if type(schema) ~= "number" or schema > ns.SCHEMA then
		return false
	end
	for version = schema + 1, ns.SCHEMA do
		if migrations[version] then
			migrations[version](data)
		end
		data.schema = version
	end
	return true
end

local function InitAccount()
	if SeshDB == nil then
		SeshDB = { schema = ns.SCHEMA }
	end
	if Upgrade(SeshDB, ACCOUNT_MIGRATIONS) then
		account = SeshDB
	else
		accountReadOnly = true
		account = { schema = ns.SCHEMA }
	end
	if type(account.settings) ~= "table" then
		account.settings = {}
	end
	if type(account.windows) ~= "table" then
		account.windows = {}
	end
	FillDefaults(account.settings)
	-- The game's calendar setting decides the first weekday until the user picks one.
	if account.settings.weekStartChosen ~= true and type(CALENDAR_FIRST_WEEKDAY) == "number" then
		account.settings.weekStart = CALENDAR_FIRST_WEEKDAY
	end
end

local function InitCharacter()
	if SeshCharDB == nil then
		SeshCharDB = { schema = ns.SCHEMA }
	end
	if not Upgrade(SeshCharDB, CHARACTER_MIGRATIONS) then
		characterReadOnly = true
		character = nil
		return
	end
	character = SeshCharDB
	if type(character.sessions) ~= "table" then
		character.sessions = {}
	end
	for _, key in ipairs({ "shared", "levels", "sharedLevels" }) do
		if type(character[key]) ~= "table" then
			character[key] = {}
		end
	end
	if type(character.nextId) ~= "number" then
		local last = character.sessions[#character.sessions]
		character.nextId = (last and last.id or 0) + 1
	end
end

--- Loads both saved-variable tables. Called once, at ADDON_LOADED.
function Database.Init()
	InitAccount()
	InitCharacter()
	if accountReadOnly or characterReadOnly then
		ns.Print(L.DATA_FROM_NEWER_VERSION)
	end
end

--- This character's data, or nil while it is read-only (saved by a newer Sesh).
---@return table?
function Database.Char()
	return character
end

---@return boolean
function Database.IsReadOnly()
	return characterReadOnly
end

--- The live settings table (also handed to the Blizzard Settings panel).
---@return table
function Database.Settings()
	return account.settings
end

function Database.Get(key)
	return account.settings[key]
end

--- Stores a setting and notifies listeners with SESH_SETTINGS_CHANGED(key, value).
function Database.Set(key, value)
	account.settings[key] = value
	if key == "weekStart" then
		account.settings.weekStartChosen = true
	end
	Events.Fire("SESH_SETTINGS_CHANGED", key, value)
end

--- Remembers where a window was dragged to.
---@param key string
---@param frame table
function Database.SavePosition(key, frame)
	local point, _, relativePoint, x, y = frame:GetPoint(1)
	if not point then
		return
	end
	account.windows[key] = { point = point, relativePoint = relativePoint, x = x, y = y }
end

--- Moves a window back to its saved position. Returns false (leaving the frame
--- untouched) when nothing valid was saved.
---@param key string
---@param frame table
---@return boolean
function Database.RestorePosition(key, frame)
	local saved = account.windows[key]
	if type(saved) ~= "table" then
		return false
	end
	local x, y = ns.Num(saved.x), ns.Num(saved.y)
	if not (VALID_POINTS[saved.point] and VALID_POINTS[saved.relativePoint] and x and y) then
		return false
	end
	frame:ClearAllPoints()
	frame:SetPoint(saved.point, UIParent, saved.relativePoint, x, y)
	return true
end
