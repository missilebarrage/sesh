local _, ns = ...

--- The main window: Session (the default), History, Leveling and Summary tabs. Views are
--- built the first time they're shown; while the window is open, data changes trigger a
--- coalesced refresh and a one-second ticker keeps durations and rates current.
---@class SeshMainWindow
local MainWindow = ns.MainWindow
local Recorder = ns.Recorder
local Database = ns.Database
local Events = ns.Events
local Format = ns.Format
local Theme = ns.Theme
local Widgets = ns.Widgets
local Window = ns.Window
local SessionView = ns.SessionView
local HistoryView = ns.HistoryView
local SummaryView = ns.SummaryView
local LevelingView = ns.LevelingView
local L = ns.L

MainWindow.WIDTH = 680
MainWindow.HEIGHT = 540

local TAB_BAR_HEIGHT = 30

local frame ---@type table?
local views = {}
local activeTab ---@type "session"|"history"|"leveling"|"summary"|nil
local ticker

local BUILDERS = {
	session = SessionView.New,
	history = HistoryView.New,
	leveling = LevelingView.New,
	summary = SummaryView.New,
}

local function UpdateSubtitle()
	local name = ns.Names.PlayerDisplayName()
	local active = Recorder.Current()
	if active then
		frame.subtitle:SetText(name .. "  ·  " .. L.SESSION_SINCE:format(active.id, Format.Time(active.startedAt)))
	else
		frame.subtitle:SetText(name)
	end
	frame.notice:SetShown(not active and activeTab == "session")
end

local function Refresh()
	if not (frame and frame:IsShown() and activeTab) then
		return
	end
	local now = GetServerTime()
	UpdateSubtitle()
	local view = views[activeTab]
	if activeTab == "session" then
		local live = Recorder.LiveView(now)
		view:SetShown(live ~= nil)
		if live then
			view:SetView(live, { now = now, live = true }, true)
		end
	else
		view:Refresh(now)
	end
end

local function Tick()
	local view = activeTab and views[activeTab]
	if view then
		view:Tick(GetServerTime())
	end
end

local function StartTicker()
	if not ticker then
		ticker = C_Timer.NewTicker(1, Tick)
	end
end

local function StopTicker()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

local function ScheduleRefresh()
	if frame and frame:IsShown() then
		Events.Debounce("mainWindowRefresh", 0.1, Refresh)
	end
end

-- In mini mode, closing the window already brings back the mini window, so the minimize
-- button (which turns mini mode on) only shows while mini mode is off.
local function UpdateHeaderButtons()
	local miniMode = Database.Get("miniMode") == true
	frame.minimizeButton:SetShown(not miniMode)
	frame.close.tooltip = miniMode and L.CLOSE_TO_MINI or nil
	frame.shareButton:ClearAllPoints()
	frame.shareButton:SetPoint("RIGHT", miniMode and frame.close or frame.minimizeButton, "LEFT", -6, 0)
end

local function Build()
	frame = Window.New("SeshMainWindow", "main", MainWindow.WIDTH, MainWindow.HEIGHT)
	frame.title:SetText(L.ADDON_TITLE)

	frame.minimizeButton = Widgets.GlyphButton(frame.header, "minimize", L.MINI_MODE, function()
		ns.MiniWindow.Enter()
	end)
	frame.minimizeButton:SetPoint("RIGHT", frame.close, "LEFT", -2, 0)
	frame.shareButton = Widgets.Button(frame.header, L.SHARE, function()
		MainWindow.Share()
	end, { height = 20, primary = true, tooltip = L.SHARE_TOOLTIP })
	UpdateHeaderButtons()
	frame.optionsButton = Widgets.GlyphButton(frame.header, "settings", L.OPTIONS, function()
		ns.Options.Open()
	end)
	frame.optionsButton:SetPoint("RIGHT", frame.shareButton, "LEFT", -6, 0)

	frame.tabs = Widgets.Tabs(
		frame.content,
		{
			{ key = "session", label = L.TAB_SESSION },
			{ key = "history", label = L.TAB_HISTORY },
			{ key = "leveling", label = L.TAB_LEVELING },
			{ key = "summary", label = L.TAB_SUMMARY },
		},
		"underline",
		function(key)
			MainWindow.ShowTab(key)
		end
	)
	frame.tabs:SetPoint("TOPLEFT", -8, 6)
	local divider = Theme.Divider(frame.content)
	divider:SetPoint("TOPLEFT", 0, -(TAB_BAR_HEIGHT - 8))
	divider:SetPoint("TOPRIGHT", 0, -(TAB_BAR_HEIGHT - 8))

	frame.body = CreateFrame("Frame", nil, frame.content)
	frame.body:SetPoint("TOPLEFT", 0, -TAB_BAR_HEIGHT)
	frame.body:SetSize(frame.content:GetWidth(), frame.content:GetHeight() - TAB_BAR_HEIGHT)

	frame.notice = Widgets.Text(frame.body, "body", "dim")
	frame.notice:SetPoint("TOP", 0, -40)
	frame.notice:SetText(Database.IsReadOnly() and L.DATA_FROM_NEWER_VERSION or L.NO_ACTIVE_SESSION)
	frame.notice:Hide()

	-- In mini mode the mini window stands in for this one while it's closed.
	frame:SetScript("OnShow", function()
		StartTicker()
		Refresh()
		ns.MiniWindow.Update()
	end)
	frame:SetScript("OnHide", function()
		StopTicker()
		GameTooltip:Hide()
		ns.MiniWindow.Update()
	end)
end

local function EnsureBuilt()
	if not frame then
		Build()
	end
end

--- Switches tabs, building the view on first use.
---@param key "session"|"history"|"leveling"|"summary"
function MainWindow.ShowTab(key)
	EnsureBuilt()
	if not views[key] then
		views[key] = BUILDERS[key](frame.body)
	end
	for name, view in pairs(views) do
		view:SetShown(name == key)
	end
	activeTab = key
	frame.tabs:Select(key, true)
	frame.shareButton.tooltip = key == "leveling" and L.SHARE_LEVEL_TOOLTIP or L.SHARE_TOOLTIP
	Refresh()
end

--- Opens the window on a tab (default: the current session).
function MainWindow.Open(tab)
	EnsureBuilt()
	frame:Show()
	MainWindow.ShowTab(tab or "session")
end

---@return boolean
function MainWindow.IsShown()
	return frame ~= nil and frame:IsShown()
end

function MainWindow.Close()
	if frame then
		frame:Hide()
	end
end

function MainWindow.Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		MainWindow.Open("session")
	end
end

--- Opens one session: the Session tab for the running one, otherwise History.
---@param id integer
function MainWindow.OpenSession(id)
	local active = Recorder.Current()
	if active and active.id == id then
		MainWindow.Open("session")
		return
	end
	MainWindow.Open("history")
	views.history:OpenSession(id)
end

--- Opens the Leveling tab on one level.
---@param level integer
function MainWindow.OpenLevel(level)
	MainWindow.Open("leveling")
	views.leveling:OpenLevel(level)
end

--- Opens History filtered to one day.
---@param day integer day number
function MainWindow.OpenDay(day)
	MainWindow.Open("history")
	views.history:ShowDay(day)
end

--- Opens the share dialog for what's in view: a level on the Leveling tab, otherwise a
--- session (the current one by default).
function MainWindow.Share()
	local now = GetServerTime()
	if activeTab == "leveling" and views.leveling then
		local view = views.leveling:ShareView(now)
		if view then
			ns.ShareDialog.Open(view, view.live)
			return
		end
	end
	if activeTab == "history" and views.history then
		local view, live = views.history:OpenSessionView(now)
		if view then
			ns.ShareDialog.Open(view, live)
			return
		end
	end
	local live = Recorder.LiveView(now)
	if live then
		ns.ShareDialog.Open(live, true)
	end
end

for _, signal in ipairs({
	"SESH_SESSION_UPDATED",
	"SESH_SESSION_STARTED",
	"SESH_VALUES_CHANGED",
	"SESH_HISTORY_CHANGED",
	"SESH_LEVELS_CHANGED",
	"SESH_SETTINGS_CHANGED",
}) do
	Events.On(signal, ScheduleRefresh)
end
Events.On("SESH_SETTINGS_CHANGED", function(key)
	if key == "miniMode" and frame then
		UpdateHeaderButtons()
	end
end)
