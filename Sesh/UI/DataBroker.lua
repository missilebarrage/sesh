local _, ns = ...

--- A LibDataBroker feed (shown by data-bar addons such as EllesmereUI's DataBars) and an
--- entry in the minimap's addon compartment. Sesh doesn't bundle LibDataBroker: the feed
--- appears only when another addon has loaded it.
---@class SeshDataBroker
local DataBroker = ns.DataBroker
local Recorder = ns.Recorder
local Session = ns.Session
local Database = ns.Database
local Events = ns.Events
local Format = ns.Format
local Theme = ns.Theme
local L = ns.L

local UPDATE_SECONDS = 30

DataBroker.METRICS = { "goldEarned", "goldPerHour", "xpPerHour", "duration" }

local object ---@type table?

local function Metrics(now)
	local live = Recorder.LiveView(now)
	return live and Session.Metrics(live, now, Database.Get("excludeAfk"))
end

--- The data text for the chosen metric.
---@param metrics SeshMetrics?
---@param metric string
---@return string
function DataBroker.Text(metrics, metric)
	if not metrics then
		return L.ADDON_TITLE
	elseif metric == "goldEarned" then
		return Format.MoneyShort(metrics.goldEarned)
	elseif metric == "goldPerHour" then
		return metrics.goldPerHour and (Format.MoneyShort(metrics.goldPerHour) .. L.PER_HOUR_SUFFIX) or "—"
	elseif metric == "xpPerHour" then
		return metrics.xpPerHour and (Format.Compact(metrics.xpPerHour) .. " " .. L.XP_SHORT .. L.PER_HOUR_SUFFIX)
			or "—"
	end
	return Format.Duration(metrics.duration)
end

local function Update()
	if object then
		object.text = DataBroker.Text(Metrics(GetServerTime()), Database.Get("brokerMetric"))
	end
end

local function FillTooltip(tooltip)
	local metrics = Metrics(GetServerTime())
	tooltip:AddLine(L.ADDON_TITLE .. " — " .. L.CURRENT_SESSION, 1, 1, 1)
	if metrics then
		tooltip:AddDoubleLine(L.CARD_DURATION, Format.Duration(metrics.duration), 0.75, 0.75, 0.75, 1, 1, 1)
		tooltip:AddDoubleLine(L.CARD_GOLD_EARNED, Format.Money(metrics.goldEarned), 0.75, 0.75, 0.75, 1, 1, 1)
		if metrics.goldPerHour then
			tooltip:AddDoubleLine(L.CARD_GOLD_PER_HOUR, Format.Money(metrics.goldPerHour), 0.75, 0.75, 0.75, 1, 1, 1)
		end
		tooltip:AddDoubleLine(L.CARD_XP, Format.Integer(metrics.xp), 0.75, 0.75, 0.75, 1, 1, 1)
		tooltip:AddDoubleLine(L.CARD_KILLS, Format.Integer(metrics.kills), 0.75, 0.75, 0.75, 1, 1, 1)
	end
	tooltip:AddLine(L.BROKER_HINT, 0.6, 0.6, 0.6)
end

local function OnClick(_, mouseButton)
	if mouseButton == "RightButton" then
		ns.MainWindow.Share()
	else
		ns.MainWindow.Toggle()
	end
end

local function RegisterCompartment()
	if not (AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon) then
		return
	end
	AddonCompartmentFrame:RegisterAddon({
		text = L.ADDON_TITLE_PLAIN,
		icon = Theme.Icon("duration"),
		notCheckable = true,
		func = function()
			ns.MainWindow.Toggle()
		end,
		funcOnEnter = function(button)
			GameTooltip:SetOwner(button, "ANCHOR_LEFT")
			FillTooltip(GameTooltip)
			GameTooltip:Show()
		end,
		funcOnLeave = function()
			GameTooltip:Hide()
		end,
	})
end

--- Whether a LibDataBroker feed exists (the setting is only offered then).
---@return boolean
function DataBroker.IsAvailable()
	return object ~= nil
end

--- Creates the feed and the compartment entry. Called at PLAYER_LOGIN.
function DataBroker.Init()
	RegisterCompartment()
	local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
	if not ldb then
		return
	end
	object = ldb:NewDataObject(ns.NAME, {
		type = "data source",
		label = L.ADDON_TITLE_PLAIN,
		icon = Theme.Icon("duration"),
		text = L.ADDON_TITLE_PLAIN,
		OnClick = OnClick,
		OnTooltipShow = FillTooltip,
	})
	for _, signal in ipairs({ "SESH_SESSION_UPDATED", "SESH_SESSION_STARTED", "SESH_VALUES_CHANGED" }) do
		Events.On(signal, Update)
	end
	Events.On("SESH_SETTINGS_CHANGED", function(key)
		if key == "brokerMetric" or key == "excludeAfk" then
			Update()
		end
	end)
	-- Durations and rates change with time alone.
	C_Timer.NewTicker(UPDATE_SECONDS, Update)
	Update()
end
