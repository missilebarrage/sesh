local addonName, ns = ...

--- Start-up wiring and the /sesh command.
local Events = ns.Events
local Database = ns.Database
local Recorder = ns.Recorder
local History = ns.History
local Kills = ns.Kills
local Pricing = ns.Pricing
local Theme = ns.Theme
local DataBroker = ns.DataBroker
local Format = ns.Format
local L = ns.L

Recorder.Register(ns.Income, ns.Progress, ns.Activity, ns.Dungeons)

Events.On("ADDON_LOADED", function(name)
	if name == addonName then
		Database.Init()
	end
end)

-- Separate handlers, so a failure in one part can't keep the others from starting.
-- Database.ClaimCharacter runs first: it may clear data that belongs to another character.
-- DataBroker runs before Options: the options page asks whether a data feed exists.
for _, initialize in ipairs({
	Database.ClaimCharacter,
	Theme.Init,
	Pricing.Init,
	ns.Links.Init,
	DataBroker.Init,
	ns.Options.Init,
}) do
	Events.On("PLAYER_LOGIN", initialize)
end

local firstWorldEntry = true

Events.On("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
	Recorder.Begin(isInitialLogin == true, isReloadingUi == true)
	if firstWorldEntry then
		firstWorldEntry = false
		if isInitialLogin and Database.Get("openOnLogin") then
			ns.MainWindow.Open("session")
		end
		ns.MiniWindow.Update()
	end
end)

Events.On("PLAYER_LOGOUT", function()
	Recorder.Suspend()
end)

-- /sesh debug -------------------------------------------------------------------------

local function YesNo(value)
	return value and L.YES_SHORT or L.NO_SHORT
end

--- Diagnostics for in-game verification. Prints counts and capabilities only: never
--- names, messages or other identifying text.
local function PrintDebug()
	local _, build, _, interface = GetBuildInfo()
	ns.Print(L.DEBUG_HEADER:format(ns.VERSION, tostring(build), tostring(interface)))
	local session = Recorder.Current()
	if session then
		ns.Print(
			L.DEBUG_SESSION:format(
				session.id,
				Format.Duration(GetServerTime() - session.startedAt),
				#History.Sessions()
			)
		)
	end
	ns.Print(
		L.DEBUG_FEATURES:format(
			YesNo(Kills.UsesPartyKill()),
			YesNo(Pricing.HasAuctionData()),
			YesNo(EllesmereUI ~= nil),
			YesNo(DataBroker.IsAvailable()),
			YesNo(AddonCompartmentFrame ~= nil)
		)
	)
	local counters = {}
	for key, value in pairs(ns.Debug.counters) do
		counters[#counters + 1] = key .. "=" .. value
	end
	table.sort(counters)
	ns.Print(L.DEBUG_COUNTERS:format(#counters > 0 and table.concat(counters, ", ") or "-"))
	local missing = Theme.MissingIcons()
	ns.Print(L.DEBUG_MISSING_ICONS:format(#missing > 0 and table.concat(missing, ", ") or "-"))
	ns.Print(
		L.DEBUG_SECRETS:format(
			YesNo(C_Secrets and C_Secrets.HasSecretRestrictions and C_Secrets.HasSecretRestrictions())
		)
	)
end

local function PrintPerformance()
	local now = GetServerTime()
	local started = debugprofilestop()
	History.Query("quarter", now)
	local quarter = debugprofilestop() - started
	started = debugprofilestop()
	ns.SummaryView.Measure(now)
	local summary = debugprofilestop() - started
	ns.Print(L.DEBUG_PERFORMANCE:format(quarter, summary, #History.Sessions()))
end

local COMMANDS = {
	[""] = function()
		ns.MainWindow.Toggle()
	end,
	share = function()
		ns.MainWindow.Share()
	end,
	history = function()
		ns.MainWindow.Open("history")
	end,
	leveling = function()
		ns.MainWindow.Open("leveling")
	end,
	mini = function()
		ns.MiniWindow.Toggle()
	end,
	summary = function()
		ns.MainWindow.Open("summary")
	end,
	options = function()
		ns.Options.Open()
	end,
	new = function()
		Recorder.Split()
		ns.Print(L.NEW_SESSION_STARTED)
	end,
	debug = function(argument)
		if argument == "perf" then
			PrintPerformance()
		elseif argument == "rebuild" then
			History.Rebuild()
			ns.Print(L.LIFETIME_REBUILT)
		else
			PrintDebug()
		end
	end,
}

SLASH_SESH1 = "/sesh"
SlashCmdList.SESH = function(message)
	local command, argument = (message or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	local handler = COMMANDS[command]
	if handler then
		handler(argument)
	else
		ns.Print(L.HELP)
	end
end
