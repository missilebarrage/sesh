local _, ns = ...

--- Options > AddOns > Sesh, built with Blizzard's native settings controls (searchable,
--- with a working Defaults button). Settings live in SeshDB.settings.
---@class SeshOptions
local Options = ns.Options
local Database = ns.Database
local Events = ns.Events
local History = ns.History
local Leveling = ns.Leveling
local LevelingView = ns.LevelingView
local MiniWindow = ns.MiniWindow
local DataBroker = ns.DataBroker
local L = ns.L

local category ---@type table?
-- Setting objects by Sesh setting key, so the panel can show changes made elsewhere (the
-- mini window's menu, /sesh mini). The mini window's switches share the key "miniFields".
local settings = {} ---@type table<string, table[]>
local notifying = false

local function Track(key, setting)
	settings[key] = settings[key] or {}
	table.insert(settings[key], setting)
end

StaticPopupDialogs.SESH_DELETE_HISTORY = {
	text = L.CONFIRM_DELETE_HISTORY,
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		History.DeleteAll()
		Leveling.DeleteAll(GetServerTime())
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
}

local function Register(key, varType, name)
	local setting = Settings.RegisterAddOnSetting(
		category,
		"SESH_" .. key,
		key,
		Database.Settings(),
		varType,
		name,
		Database.DEFAULTS[key]
	)
	-- Route changes through Database.Set so the rest of Sesh hears about them.
	setting:SetValueChangedCallback(function(_, value)
		if not notifying then
			Database.Set(key, value)
		end
	end)
	Track(key, setting)
	return setting
end

local function Checkbox(key, name, tooltip)
	Settings.CreateCheckbox(category, Register(key, Settings.VarType.Boolean, name), tooltip)
end

local function Dropdown(key, varType, name, tooltip, choices)
	Settings.CreateDropdown(category, Register(key, varType, name), function()
		local container = Settings.CreateControlTextContainer()
		for _, choice in ipairs(choices) do
			container:Add(choice[1], choice[2])
		end
		return container:GetData()
	end, tooltip)
end

-- A slider that shows its value as a percentage; `toPercent` scales the stored value.
local function PercentSlider(key, name, tooltip, minimum, maximum, step, toPercent)
	local options = Settings.CreateSliderOptions(minimum, maximum, step)
	options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
		return string.format("%d%%", value * toPercent + 0.5)
	end)
	Settings.CreateSlider(category, Register(key, Settings.VarType.Number, name), options, tooltip)
end

local function Scale(key, name, tooltip)
	PercentSlider(key, name, tooltip, 0.75, 1.5, 0.05, 100)
end

-- One checkbox per number the mini window can show, all kept in the miniFields table.
local function MiniFieldCheckbox(metric)
	local fields = Database.Get("miniFields")
	local setting = Settings.RegisterAddOnSetting(
		category,
		"SESH_miniFields_" .. metric.key,
		metric.key,
		fields,
		Settings.VarType.Boolean,
		metric.name,
		Database.DEFAULTS.miniFields[metric.key]
	)
	setting:SetValueChangedCallback(function(_, value)
		if not notifying then
			fields[metric.key] = value
			Database.Set("miniFields", fields)
		end
	end)
	Track("miniFields", setting)
	Settings.CreateCheckbox(category, setting)
end

local function Minutes(values)
	local choices = {}
	for _, minutes in ipairs(values) do
		choices[#choices + 1] = { minutes, minutes == 0 and L.OFF or L.MINUTES_COUNT:format(minutes) }
	end
	return choices
end

local function Build(layout)
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_GENERAL))
	Checkbox("openOnLogin", L.OPTION_OPEN_ON_LOGIN, L.OPTION_OPEN_ON_LOGIN_TOOLTIP)
	Scale("windowScale", L.OPTION_WINDOW_SCALE, L.OPTION_WINDOW_SCALE_TOOLTIP)

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_MINI))
	Checkbox("miniMode", L.OPTION_MINI_MODE, L.OPTION_MINI_MODE_TOOLTIP)
	Scale("miniScale", L.OPTION_MINI_SCALE, L.OPTION_MINI_SCALE_TOOLTIP)
	PercentSlider("miniOpacity", L.OPTION_MINI_OPACITY, L.OPTION_MINI_OPACITY_TOOLTIP, 0, 100, 5, 1)
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_MINI_SHOWS))
	for _, metric in ipairs(MiniWindow.METRICS) do
		if not metric.leveling then
			MiniFieldCheckbox(metric)
		end
	end
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_MINI_SHOWS_LEVELING))
	for _, metric in ipairs(MiniWindow.METRICS) do
		if metric.leveling then
			MiniFieldCheckbox(metric)
		end
	end

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_TRACKING))
	Checkbox("excludeAfk", L.OPTION_EXCLUDE_AFK, L.OPTION_EXCLUDE_AFK_TOOLTIP)
	Dropdown(
		"resumeMinutes",
		Settings.VarType.Number,
		L.OPTION_RESUME,
		L.OPTION_RESUME_TOOLTIP,
		Minutes({ 0, 5, 10, 15 })
	)
	Dropdown(
		"minSessionMinutes",
		Settings.VarType.Number,
		L.OPTION_MIN_SESSION,
		L.OPTION_MIN_SESSION_TOOLTIP,
		Minutes({ 0, 1, 5, 10 })
	)

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_SUMMARY))
	Dropdown("weekStart", Settings.VarType.Number, L.OPTION_WEEK_START, L.OPTION_WEEK_START_TOOLTIP, {
		{ 1, L.WEEKDAY_SUNDAY },
		{ 2, L.WEEKDAY_MONDAY },
	})
	Dropdown("heatmapMetric", Settings.VarType.String, L.OPTION_HEATMAP_METRIC, L.OPTION_HEATMAP_METRIC_TOOLTIP, {
		{ "gold", L.METRIC_GOLD },
		{ "xp", L.METRIC_XP },
		{ "time", L.METRIC_TIME },
	})

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_LEVELING))
	Checkbox("announceLevels", L.OPTION_ANNOUNCE_LEVELS, L.OPTION_ANNOUNCE_LEVELS_TOOLTIP)
	local chartMetrics = {}
	for _, metric in ipairs(LevelingView.METRICS) do
		chartMetrics[#chartMetrics + 1] = { metric.key, metric.label }
	end
	Dropdown(
		"levelChartMetric",
		Settings.VarType.String,
		L.OPTION_LEVEL_CHART_METRIC,
		L.OPTION_LEVEL_CHART_METRIC_TOOLTIP,
		chartMetrics
	)

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_SHARING))
	Checkbox("allowLinkRequests", L.OPTION_ALLOW_REQUESTS, L.OPTION_ALLOW_REQUESTS_TOOLTIP)

	if DataBroker.IsAvailable() then
		layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_DATA_TEXT))
		Dropdown("brokerMetric", Settings.VarType.String, L.OPTION_BROKER_METRIC, L.OPTION_BROKER_METRIC_TOOLTIP, {
			{ "goldEarned", L.CARD_GOLD_EARNED },
			{ "goldPerHour", L.CARD_GOLD_PER_HOUR },
			{ "xpPerHour", L.CARD_XP_PER_HOUR },
			{ "duration", L.CARD_DURATION },
		})
	end

	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L.OPTIONS_DATA))
	layout:AddInitializer(CreateSettingsButtonInitializer(L.OPTION_DELETE_HISTORY, L.DELETE, function()
		StaticPopup_Show("SESH_DELETE_HISTORY")
	end, L.OPTION_DELETE_HISTORY_TOOLTIP, true))
end

-- A setting changed somewhere else: the panel's controls read their values again. Their
-- change callbacks run too and are told not to store the value a second time.
Events.On("SESH_SETTINGS_CHANGED", function(key)
	if notifying then
		return
	end
	notifying = true
	for _, setting in ipairs(settings[key] or {}) do
		setting:NotifyUpdate()
	end
	notifying = false
end)

--- Registers the options page. Called at PLAYER_LOGIN.
function Options.Init()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory(L.ADDON_TITLE_PLAIN)
	Build(layout)
	Settings.RegisterAddOnCategory(category)
end

--- Opens Options > AddOns > Sesh (not possible during combat).
function Options.Open()
	if InCombatLockdown() then
		ns.Print(L.OPTIONS_IN_COMBAT)
		return
	end
	Settings.OpenToCategory(category:GetID())
end
