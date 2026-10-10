local _, ns = ...

--- The Leveling tab: progress through the current level, a chart comparing the levels
--- Sesh tracked, and a list of them. Any level opens with its full stats, ready to share.
--- Also announces finished levels in chat (only the player sees it).
---@class SeshLevelingView
local LevelingView = ns.LevelingView
local Leveling = ns.Leveling
local Progress = ns.Progress
local Session = ns.Session
local Database = ns.Database
local Events = ns.Events
local Format = ns.Format
local Theme = ns.Theme
local Widgets = ns.Widgets
local LevelChart = ns.LevelChart
local SessionView = ns.SessionView
local Links = ns.Links
local L = ns.L

local HERO_HEIGHT = 70
local HERO_PADDING = 12
local PROGRESS_HEIGHT = 6
local SECTION_GAP = 16
local CHART_HEIGHT = 112
local TOOLBAR_HEIGHT = 30
local ROW_HEIGHT = 22

local function AddLine(left, right)
	GameTooltip:AddDoubleLine(left, right, 0.75, 0.75, 0.75, 1, 1, 1)
end

local function AddNote(text)
	GameTooltip:AddLine(text, 0.6, 0.6, 0.6, true)
end

local function XPPerHourText(value)
	return L.XP_PER_HOUR_SHORT:format(Format.Compact(value))
end

-- What the chart can compare levels by.
local METRICS = {
	time = {
		value = function(row)
			return row.duration
		end,
		format = Format.Duration,
	},
	xpPerHour = {
		value = function(row)
			return row.xpPerHour or 0
		end,
		format = XPPerHourText,
	},
	gold = {
		value = function(row)
			return row.goldEarned
		end,
		format = Format.MoneyShort,
	},
	kills = {
		value = function(row)
			return row.kills
		end,
		format = Format.Integer,
	},
	quests = {
		value = function(row)
			return row.quests
		end,
		format = Format.Integer,
	},
	deaths = {
		value = function(row)
			return row.deaths
		end,
		format = Format.Integer,
	},
}

LevelingView.METRICS = {
	{ key = "time", label = L.METRIC_TIME },
	{ key = "xpPerHour", label = L.METRIC_XP_PER_HOUR },
	{ key = "gold", label = L.METRIC_GOLD },
	{ key = "kills", label = L.METRIC_KILLS },
	{ key = "quests", label = L.METRIC_QUESTS },
	{ key = "deaths", label = L.METRIC_DEATHS },
}

-- One level's numbers, for the chart, the list and the progress panel.
---@param row SeshLevelRow
local function FillLevelTooltip(row)
	GameTooltip:SetText(L.LEVEL_N:format(row.level), 1, 1, 1)
	AddLine(L.CARD_TIME_PLAYED, Format.Duration(row.duration))
	AddLine(L.ACTIVE_TIME, Format.Duration(row.activeSeconds))
	if row.xpPerHour then
		AddLine(L.CARD_XP_PER_HOUR, Format.Integer(row.xpPerHour))
	end
	AddLine(L.CARD_GOLD_EARNED, Format.Money(row.goldEarned))
	AddLine(L.CARD_KILLS, Format.Integer(row.kills))
	AddLine(L.CARD_QUESTS, Format.Integer(row.quests))
	AddLine(L.CARD_DUNGEONS, Format.Integer(row.dungeons))
	AddLine(L.CARD_DEATHS, Format.Integer(row.deaths))
	if row.fromPercent then
		AddNote(L.LEVEL_PARTIAL_NOTE:format(row.fromPercent))
	elseif row.partial then
		AddNote(L.LEVEL_UNFINISHED_NOTE)
	end
	AddNote(L.CLICK_TO_OPEN_LEVEL)
end

-- "Oct 4 – Oct 5", "In progress · 62%" or "Oct 2 – Oct 3 (partly tracked)".
local function LevelDates(row)
	if row.current then
		return row.progress and L.LEVEL_IN_PROGRESS_PERCENT:format(row.progress) or L.IN_PROGRESS
	end
	local dates = row.startedAt and Format.DateRange(row.startedAt, row.endedAt or row.startedAt) or ""
	return row.partial and (dates .. " " .. L.PARTLY_TRACKED) or dates
end

--- The line under the chart: how many levels, time played, the average and the fastest.
---@param rows SeshLevelRow[]
---@return string
function LevelingView.JourneyText(rows)
	if #rows == 0 then
		return L.LEVELING_EMPTY
	end
	local played, finished, finishedSeconds, fastest = 0, 0, 0, nil
	for _, row in ipairs(rows) do
		played = played + row.duration
		if not (row.current or row.partial) then
			finished = finished + 1
			finishedSeconds = finishedSeconds + row.duration
			if not fastest or row.duration < fastest.duration then
				fastest = row
			end
		end
	end
	local parts = { Format.Count(#rows, L.COUNT_LEVELS), L.JOURNEY_PLAYED:format(Format.Duration(played)) }
	if fastest then
		parts[#parts + 1] = L.JOURNEY_AVERAGE:format(Format.Duration(finishedSeconds / finished))
		parts[#parts + 1] = L.JOURNEY_FASTEST:format(fastest.level, Format.Duration(fastest.duration))
	end
	return table.concat(parts, "  ·  ")
end

-- Level list rows --------------------------------------------------------------------------

local function BuildLevelRow(row)
	Widgets.PrepareRow(row)
	row.badge = CreateFrame("Frame", nil, row)
	row.badge:SetSize(30, 16)
	row.badge:SetPoint("LEFT", 4, 0)
	Theme.Fill(row.badge, Theme.COLORS.control)
	Theme.Border(row.badge)
	row.badge.text = Widgets.Text(row.badge, "small")
	row.badge.text:SetPoint("CENTER")
	row.badge.text:SetJustifyH("CENTER")
	row.value = Widgets.Text(row, "body")
	row.value:SetPoint("RIGHT", -6, 0)
	row.value:SetJustifyH("RIGHT")
	row.value:SetWidth(90)
	row.detail = Widgets.Text(row, "small", "dim")
	row.detail:SetPoint("RIGHT", row.value, "LEFT", -10, 0)
	row.detail:SetJustifyH("RIGHT")
	row.detail:SetWidth(250)
	row.name = Widgets.Text(row, "body")
	row.name:SetPoint("LEFT", row.badge, "RIGHT", 10, 0)
	row.name:SetPoint("RIGHT", row.detail, "LEFT", -8, 0)
	row:SetScript("OnEnter", function(self)
		self.highlight:Show()
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		FillLevelTooltip(self.level)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.highlight:Hide()
		GameTooltip:Hide()
	end)
	row:SetScript("OnClick", function(self)
		self.owner:OpenLevel(self.level.level)
	end)
end

local function SetAccent(text, accented)
	if accented then
		Theme.PaintAccent(text, 1, "text")
	else
		Theme.ForgetAccent(text)
	end
end

local function BindLevelRow(row, entry)
	local level = entry.level
	row.level = level
	row.owner = entry.owner
	Widgets.StripeRow(row, entry.index)
	row.badge.text:SetText(tostring(level.level))
	Theme.Tone(row.badge.text, "primary")
	SetAccent(row.badge.text, level.current)
	row.name:SetText(LevelDates(level))
	Theme.Tone(row.name, level.partial and "dim" or "primary")
	SetAccent(row.name, level.current)
	row.detail:SetText(
		L.LEVEL_ROW_DETAIL:format(
			Format.MoneyShortText(level.goldEarned),
			Format.Integer(level.kills),
			Format.Integer(level.quests)
		)
	)
	row.value:SetText(Format.Duration(level.duration))
end

-- The view ----------------------------------------------------------------------------------

local LevelingViewMixin = {}

local function Container(parent, top)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetPoint("TOPLEFT", 0, -top)
	frame:SetSize(parent:GetWidth(), parent:GetHeight() - top)
	return frame
end

-- The current level: number, progress bar with rested experience, time and ETA.
function LevelingViewMixin:BuildProgress(parent, width)
	local panel = CreateFrame("Button", nil, parent)
	panel:SetSize(width, HERO_HEIGHT)
	panel:SetPoint("TOPLEFT")
	Theme.Fill(panel, Theme.COLORS.inset)
	Theme.Border(panel)
	panel.hover = Theme.Fill(panel, Theme.COLORS.hover, "BORDER")
	panel.hover:Hide()

	panel.level = Widgets.Text(panel, "value")
	panel.level:SetPoint("TOPLEFT", HERO_PADDING, -10)
	panel.percent = Widgets.Text(panel, "value")
	panel.percent:SetPoint("TOPRIGHT", -HERO_PADDING, -10)
	panel.percent:SetJustifyH("RIGHT")
	Theme.PaintAccent(panel.percent, 1, "text")

	local barWidth = width - 2 * HERO_PADDING
	panel.barWidth = barWidth
	panel.track = panel:CreateTexture(nil, "ARTWORK")
	panel.track:SetPoint("TOPLEFT", HERO_PADDING, -36)
	panel.track:SetSize(barWidth, PROGRESS_HEIGHT)
	panel.track:SetColorTexture(unpack(Theme.COLORS.track))
	panel.rested = panel:CreateTexture(nil, "ARTWORK", nil, 1)
	panel.rested:SetHeight(PROGRESS_HEIGHT)
	Theme.PaintAccent(panel.rested, 0.3)
	panel.fill = panel:CreateTexture(nil, "ARTWORK", nil, 2)
	panel.fill:SetPoint("TOPLEFT", panel.track)
	panel.fill:SetHeight(PROGRESS_HEIGHT)
	Theme.PaintAccent(panel.fill, 1)

	panel.detail = Widgets.Text(panel, "small", "dim")
	panel.detail:SetPoint("BOTTOMLEFT", HERO_PADDING, 11)
	panel.time = Widgets.Text(panel, "small", "dim")
	panel.time:SetPoint("BOTTOMRIGHT", -HERO_PADDING, 11)
	panel.time:SetJustifyH("RIGHT")

	panel:SetScript("OnEnter", function()
		panel.hover:Show()
		if self.currentRow then
			GameTooltip:SetOwner(panel, "ANCHOR_BOTTOM")
			FillLevelTooltip(self.currentRow)
			GameTooltip:Show()
		end
	end)
	panel:SetScript("OnLeave", function()
		panel.hover:Hide()
		Widgets.HideTooltip()
	end)
	panel:SetScript("OnClick", function()
		if self.currentRow then
			self:OpenLevel(self.currentRow.level)
		end
	end)
	self.progress = panel
end

function LevelingViewMixin:Build()
	local width = self:GetWidth()

	-- Overview.
	self.overview = Container(self, 0)
	self:BuildProgress(self.overview, width)
	local y = HERO_HEIGHT + SECTION_GAP

	local perLevel = Widgets.SectionHeader(self.overview, L.SECTION_PER_LEVEL)
	perLevel:SetPoint("TOPLEFT", 0, -y)
	perLevel:SetWidth(width)
	self.metricTabs = Widgets.Tabs(self.overview, LevelingView.METRICS, "segmented", function(metric)
		Database.Set("levelChartMetric", metric)
	end)
	self.metricTabs:SetPoint("BOTTOMRIGHT", perLevel, "BOTTOMRIGHT", 0, 4)
	y = y + 30
	self.chart = LevelChart.New(self.overview, width, CHART_HEIGHT, {
		onClick = function(row)
			self:OpenLevel(row.level)
		end,
		onTooltip = FillLevelTooltip,
	})
	self.chart:SetPoint("TOPLEFT", 0, -y)
	y = y + CHART_HEIGHT + 6
	self.journey = Widgets.Text(self.overview, "small", "dim")
	self.journey:SetPoint("TOPLEFT", 0, -y)
	self.journey:SetWidth(width)
	y = y + 14 + SECTION_GAP - 6

	local levels = Widgets.SectionHeader(self.overview, L.SECTION_LEVELS)
	levels:SetPoint("TOPLEFT", 0, -y)
	levels:SetWidth(width)
	y = y + 28
	self.list = Widgets.ScrollList(self.overview, ROW_HEIGHT, BuildLevelRow, BindLevelRow)
	self.list:SetPoint("TOPLEFT", 0, -y)
	self.list:SetPoint("BOTTOMRIGHT")
	self.list:SetEmptyText(L.LEVELING_EMPTY)

	-- One level.
	self.detail = Container(self, 0)
	self.detail:Hide()
	self.back = Widgets.GlyphButton(self.detail, "back", L.BACK, function()
		self:CloseLevel()
	end)
	self.back:SetPoint("TOPLEFT", -4, -2)
	self.detailTitle = Widgets.Text(self.detail, "heading")
	self.detailTitle:SetPoint("LEFT", self.back, "RIGHT", 4, 0)
	self.detailInfo = Widgets.Text(self.detail, "small", "dim")
	self.detailInfo:SetPoint("LEFT", self.detailTitle, "RIGHT", 10, 0)
	self.shareButton = Widgets.Button(self.detail, L.SHARE, function()
		self:ShareLevel()
	end, { height = 20, primary = true, tooltip = L.SHARE_LEVEL_TOOLTIP })
	self.shareButton:SetPoint("TOPRIGHT", 0, -2)
	self.levelView = SessionView.New(Container(self.detail, TOOLBAR_HEIGHT))
end

function LevelingViewMixin:RefreshProgress(now)
	local panel = self.progress
	local level, xp, xpMax = Progress.Experience()
	panel.level:SetText(level and L.LEVEL_N:format(level) or "")
	local leveling = (xp and xpMax and Progress.CanLevel(xpMax)) == true
	panel.track:SetShown(leveling)
	panel.fill:SetShown(leveling and xp > 0)
	panel.rested:Hide()
	if not leveling then
		panel.percent:SetText(level and L.MAX_LEVEL or "")
		panel.detail:SetText("")
		self:TickProgress(now)
		return
	end
	local fraction = math.min(1, xp / xpMax)
	panel.percent:SetText(Format.Percent(fraction))
	panel.fill:SetWidth(math.max(1, panel.barWidth * fraction))
	local detail = L.PROGRESS_XP:format(Format.Integer(xp), Format.Integer(xpMax))
	local rested = Progress.Rested()
	if rested and rested > 0 then
		detail = detail .. "  ·  " .. L.PROGRESS_RESTED:format(Format.Integer(rested))
		local restedWidth = math.min(rested / xpMax, 1 - fraction) * panel.barWidth
		if restedWidth >= 1 then
			panel.rested:ClearAllPoints()
			panel.rested:SetPoint("TOPLEFT", panel.track, "TOPLEFT", panel.barWidth * fraction, 0)
			panel.rested:SetWidth(restedWidth)
			panel.rested:Show()
		end
	end
	panel.detail:SetText(detail)
	self:TickProgress(now)
end

--- Time at the current level and when the next one is due; changes every second.
function LevelingViewMixin:TickProgress(now)
	local current = self.currentView
	if not current then
		self.progress.time:SetText("")
		return
	end
	local metrics = Session.Metrics(current, now, Database.Get("excludeAfk"))
	local text = L.PROGRESS_TIME:format(Format.Duration(metrics.duration))
	local levelUpIn = Progress.TimeToLevel(metrics.xpPerHour)
	if levelUpIn then
		text = text .. "  ·  " .. L.PROGRESS_LEVEL_UP_IN:format(current.level + 1, Format.Duration(levelUpIn))
	end
	self.progress.time:SetText(text)
end

function LevelingViewMixin:RefreshOverview(now)
	local rows, current = Leveling.Rows(now, Database.Get("excludeAfk"))
	self.currentView = current
	self.currentRow = nil
	for _, row in ipairs(rows) do
		if row.current then
			self.currentRow = row
		end
	end
	self:RefreshProgress(now)

	local metric = METRICS[Database.Get("levelChartMetric")] and Database.Get("levelChartMetric") or "time"
	self.metricTabs:Select(metric, true)
	self.chart:SetData(rows, METRICS[metric].value, METRICS[metric].format)
	self.journey:SetText(LevelingView.JourneyText(rows))

	local entries = {}
	for index = #rows, 1, -1 do
		entries[#entries + 1] = { index = #entries + 1, level = rows[index], owner = self }
	end
	self.list:SetRows(entries, true)
end

function LevelingViewMixin:RefreshDetail(now)
	local view = Leveling.View(self.openLevel, now)
	if not view then
		return self:CloseLevel()
	end
	local info
	if view.live then
		info = view.progress and L.LEVEL_IN_PROGRESS_PERCENT:format(view.progress) or L.IN_PROGRESS
	else
		info = Format.DateRange(view.startedAt, view.endedAt or view.startedAt)
	end
	info = info .. "  ·  " .. Format.Count(view.sessionCount, L.COUNT_SESSIONS)
	if view.fromPercent then
		info = info .. "  ·  " .. L.CARD_TRACKED_FROM:format(view.fromPercent)
	end
	self.detailTitle:SetText(L.LEVEL_N:format(view.level))
	self.detailInfo:SetText(info)
	self.levelView:SetView(view, { now = now, live = view.live }, true)
end

function LevelingViewMixin:Refresh(now)
	if self.openLevel then
		self:RefreshDetail(now)
	else
		self:RefreshOverview(now)
	end
end

function LevelingViewMixin:Tick(now)
	if self.openLevel then
		self.levelView:Tick(now)
	else
		self:TickProgress(now)
	end
end

--- Shows one level with its full stats.
---@param level integer
function LevelingViewMixin:OpenLevel(level)
	self.openLevel = level
	self.overview:Hide()
	self.detail:Show()
	self:Refresh(GetServerTime())
end

function LevelingViewMixin:CloseLevel()
	self.openLevel = nil
	self.detail:Hide()
	self.overview:Show()
	self:Refresh(GetServerTime())
end

--- The level the Share button shares: the one that's open, otherwise the current level.
---@return SeshView?
function LevelingViewMixin:ShareView(now)
	local level = self.openLevel or Leveling.Current()
	return level and Leveling.View(level, now)
end

function LevelingViewMixin:ShareLevel()
	local view = self:ShareView(GetServerTime())
	if view then
		ns.ShareDialog.Open(view, view.live)
	end
end

---@return table
function LevelingView.New(parent)
	local frame = Mixin(CreateFrame("Frame", nil, parent), LevelingViewMixin)
	frame:SetSize(parent:GetWidth(), parent:GetHeight())
	frame:SetPoint("TOPLEFT")
	frame:Build()
	return frame
end

-- Level-up announcements --------------------------------------------------------------------

--- Prints how a finished level went; the level is a link that opens it. Only the player sees it.
---@param level integer
function LevelingView.Announce(level)
	local now = GetServerTime()
	local view = Leveling.View(level, now)
	if not view then
		return
	end
	local metrics = Session.Metrics(view, now, Database.Get("excludeAfk"))
	local link = Links.MakeLevelLink(level)
	local took = Format.Duration(metrics.duration)
	local lead = view.fromPercent and L.ANNOUNCE_PARTIAL:format(link, took, view.fromPercent)
		or L.ANNOUNCE:format(link, took)
	local details = { Format.Count(metrics.kills, L.COUNT_KILLS), Format.Count(metrics.quests, L.COUNT_QUESTS) }
	if metrics.dungeons > 0 then
		details[#details + 1] = Format.Count(metrics.dungeons, L.COUNT_DUNGEON_RUNS)
	end
	details[#details + 1] = Format.Count(metrics.deaths, L.COUNT_DEATHS)
	ns.Print(lead .. " " .. table.concat(details, ", ") .. ".")
end

Events.On("SESH_LEVEL_UP", function(level)
	if Database.Get("announceLevels") then
		LevelingView.Announce(level)
	end
end)
