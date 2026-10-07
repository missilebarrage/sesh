local _, ns = ...

--- History: pick a time range (or a single day from the heatmap), see its totals and the
--- sessions in it, and drill into any session to see, share or delete it.
---@class SeshHistoryView
local HistoryView = ns.HistoryView
local History = ns.History
local Recorder = ns.Recorder
local Session = ns.Session
local Stats = ns.Stats
local Database = ns.Database
local Format = ns.Format
local Widgets = ns.Widgets
local SessionView = ns.SessionView
local L = ns.L

local TOOLBAR_HEIGHT = 30

local RANGE_LABELS = {
	today = L.RANGE_TODAY,
	week = L.RANGE_WEEK,
	month = L.RANGE_MONTH,
	quarter = L.RANGE_QUARTER,
	all = L.RANGE_ALL,
}

StaticPopupDialogs.SESH_DELETE_SESSION = {
	text = L.CONFIRM_DELETE_SESSION,
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, id)
		History.Delete(id)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local HistoryViewMixin = {}

local function Container(parent, top)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetPoint("TOPLEFT", 0, -top)
	frame:SetSize(parent:GetWidth(), parent:GetHeight() - top)
	return frame
end

function HistoryViewMixin:Build()
	-- Range overview.
	self.overview = Container(self, 0)
	local items = {}
	for _, range in ipairs(History.RANGES) do
		items[#items + 1] = { key = range, label = RANGE_LABELS[range] }
	end
	self.rangeTabs = Widgets.Tabs(self.overview, items, "segmented", function(range)
		self:SetRange(range)
	end)
	self.rangeTabs:SetPoint("TOPLEFT", 0, -2)

	self.dayChip = Widgets.Button(self.overview, "", function()
		local saved = Database.Get("historyRange")
		self:SetRange(RANGE_LABELS[saved] and saved or "today")
	end, { height = 20, primary = true, tooltip = L.CLEAR_DAY_FILTER })
	self.dayChip:SetPoint("LEFT", self.rangeTabs, "RIGHT", 10, 0)
	self.dayChip:Hide()

	local summaryArea = Container(self.overview, TOOLBAR_HEIGHT)
	self.summary = SessionView.New(summaryArea, {
		showSessions = true,
		onSessionClick = function(id)
			self:OpenSession(id)
		end,
	})

	-- Single session.
	self.detail = Container(self, 0)
	self.detail:Hide()
	self.back = Widgets.GlyphButton(self.detail, "back", L.BACK, function()
		self:CloseSession()
	end)
	self.back:SetPoint("TOPLEFT", -4, -2)
	self.detailTitle = Widgets.Text(self.detail, "heading")
	self.detailTitle:SetPoint("LEFT", self.back, "RIGHT", 4, 0)
	self.deleteButton = Widgets.Button(self.detail, L.DELETE, function()
		StaticPopup_Show("SESH_DELETE_SESSION", nil, nil, self.sessionID)
	end, { height = 20 })
	self.deleteButton:SetPoint("TOPRIGHT", 0, -2)
	self.shareButton = Widgets.Button(self.detail, L.SHARE, function()
		self:ShareOpenSession()
	end, { height = 20, primary = true })
	self.shareButton:SetPoint("RIGHT", self.deleteButton, "LEFT", -6, 0)
	local detailArea = Container(self.detail, TOOLBAR_HEIGHT)
	self.sessionView = SessionView.New(detailArea)

	local saved = Database.Get("historyRange")
	self.range = RANGE_LABELS[saved] and saved or "today"
end

--- Switches to a named range ("today", "week", ...).
function HistoryViewMixin:SetRange(range)
	self.range = range
	Database.Set("historyRange", range)
	self.dayChip:Hide()
	self.rangeTabs:Select(range, true)
	self:CloseSession()
end

--- Shows a single day (from the heatmap).
---@param day integer day number
function HistoryViewMixin:ShowDay(day)
	self.range = { day = day }
	self.rangeTabs:Select(nil, true)
	self.dayChip:SetLabel(Format.DateLong(Stats.MidnightOf(day)) .. "  ×")
	self.dayChip:Show()
	self:CloseSession()
end

--- The view of a session by id: the live one or a stored one.
local function SessionViewFor(id, now)
	local active = Recorder.Current()
	if active and active.id == id then
		return Session.LiveView(active, now), true
	end
	local record = History.Get(id)
	return record and Session.View(record), false
end

---@param id integer
function HistoryViewMixin:OpenSession(id)
	self.sessionID = id
	self.overview:Hide()
	self.detail:Show()
	self:Refresh(GetServerTime())
end

function HistoryViewMixin:CloseSession()
	self.sessionID = nil
	self.detail:Hide()
	self.overview:Show()
	self:Refresh(GetServerTime())
end

--- The session currently open in the detail view, if any.
---@return SeshView?, boolean? live
function HistoryViewMixin:OpenSessionView(now)
	if self.sessionID and self.detail:IsShown() then
		return SessionViewFor(self.sessionID, now)
	end
end

function HistoryViewMixin:ShareOpenSession()
	local view, live = self:OpenSessionView(GetServerTime())
	if view then
		ns.ShareDialog.Open(view, live)
	end
end

local function DetailTitle(view, live, now)
	local started = Format.DateLong(view.startedAt) .. ", " .. Format.Time(view.startedAt)
	if live then
		return started .. " – " .. L.STILL_PLAYING
	end
	local ended = view.endedAt or now
	return started .. " – " .. Format.Time(ended)
end

function HistoryViewMixin:RefreshDetail(now)
	local view, live = SessionViewFor(self.sessionID, now)
	if not view then
		-- Deleted (or never existed): back to the list.
		self.sessionID = nil
		self.detail:Hide()
		self.overview:Show()
		return self:RefreshOverview(now)
	end
	self.detailTitle:SetText(DetailTitle(view, live, now))
	-- The running session can't be deleted.
	self.deleteButton:SetShown(not live)
	self.sessionView:SetView(view, { now = now, live = live }, true)
end

function HistoryViewMixin:RefreshOverview(now)
	local excludeAfk = Database.Get("excludeAfk")
	local view = History.Query(self.range, now)
	local from, to = History.Bounds(self.range, now)
	local active = Recorder.Current()
	local live
	if active and not (from and active.startedAt < from) and not (to and active.startedAt >= to) then
		live = Session.LiveView(active, now)
	end
	local rows = SessionView.SessionRows(History.Between(from, to), live, now, excludeAfk)
	self.rangeTabs:Select(type(self.range) == "string" and self.range or nil, true)
	self.summary:SetView(view, { now = now, sessions = rows }, true)
end

function HistoryViewMixin:Refresh(now)
	if self.sessionID then
		self:RefreshDetail(now)
	else
		self:RefreshOverview(now)
	end
end

function HistoryViewMixin:Tick(now)
	if self.sessionID then
		self.sessionView:Tick(now)
	end
end

---@return table
function HistoryView.New(parent)
	local frame = Mixin(CreateFrame("Frame", nil, parent), HistoryViewMixin)
	frame:SetSize(parent:GetWidth(), parent:GetHeight())
	frame:SetPoint("TOPLEFT")
	frame:Build()
	return frame
end
