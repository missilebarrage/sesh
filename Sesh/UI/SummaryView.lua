local _, ns = ...

--- The character summary: all-time totals, the activity heatmap, personal records, play
--- streaks and all-time top items, monsters and zones.
---@class SeshSummaryView
local SummaryView = ns.SummaryView
local History = ns.History
local Session = ns.Session
local Stats = ns.Stats
local Database = ns.Database
local Format = ns.Format
local Theme = ns.Theme
local Widgets = ns.Widgets
local Heatmap = ns.Heatmap
local L = ns.L

local GAP = 10
local SECTION_GAP = 16
local MINI_ROW_HEIGHT = 20
local TOP_COUNT = 5
local NO_VALUE = "—"

-- A compact row: icon, label, value; optionally clickable.
local function MiniRow(parent)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(MINI_ROW_HEIGHT)
	row.highlight = Theme.Fill(row, Theme.COLORS.hover, "BORDER")
	row.highlight:Hide()
	row.icon = Widgets.Icon(row, 16)
	row.icon:SetPoint("LEFT", 2, 0)
	row.value = Widgets.Text(row, "body")
	row.value:SetPoint("RIGHT", -4, 0)
	row.value:SetJustifyH("RIGHT")
	row.label = Widgets.Text(row, "body", "dim")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.label:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
	row:SetScript("OnEnter", function(self)
		self.highlight:Show()
		if self.tooltip then
			Widgets.ShowTooltip(self, self.tooltip[1], self.tooltip[2])
		end
	end)
	row:SetScript("OnLeave", function(self)
		self.highlight:Hide()
		Widgets.HideTooltip()
	end)
	row:SetScript("OnClick", function(self)
		if self.onClick then
			self.onClick()
		end
	end)
	return row
end

local function FillRow(row, icon, label, value, onClick, tooltip)
	row.icon:SetTexture(icon)
	row.label:SetText(label)
	row.value:SetText(value)
	row.onClick = onClick
	row.tooltip = tooltip
	row:Show()
end

-- A titled column of mini rows.
local function Column(parent, title, rows, x, y, width)
	local header = Widgets.SectionHeader(parent, title)
	header:SetPoint("TOPLEFT", x, -y)
	header:SetWidth(width)
	local column = { header = header, rows = {} }
	for index = 1, rows do
		local row = MiniRow(parent)
		row:SetPoint("TOPLEFT", x, -(y + 26 + (index - 1) * MINI_ROW_HEIGHT))
		row:SetWidth(width)
		column.rows[index] = row
	end
	return column
end

local SummaryViewMixin = {}

function SummaryViewMixin:Build()
	local content = self.content
	local width = content:GetWidth()
	local y = 0

	local allTime = Widgets.SectionHeader(content, L.SECTION_ALL_TIME)
	allTime:SetPoint("TOPLEFT", 0, -y)
	allTime:SetWidth(width)
	y = y + 30
	self.cards = {}
	local cardsFrame = CreateFrame("Frame", nil, content)
	cardsFrame:SetPoint("TOPLEFT", 0, -y)
	cardsFrame:SetSize(width, 2 * Widgets.CARD_HEIGHT + GAP)
	for index = 1, 8 do
		self.cards[index] = Widgets.StatCard(cardsFrame)
	end
	Widgets.LayoutGrid(cardsFrame, self.cards, 4, 0, GAP)
	y = y + 2 * Widgets.CARD_HEIGHT + GAP + SECTION_GAP

	local activity = Widgets.SectionHeader(content, L.SECTION_ACTIVITY)
	activity:SetPoint("TOPLEFT", 0, -y)
	activity:SetWidth(width)
	self.metricTabs = Widgets.Tabs(
		content,
		{
			{ key = "gold", label = L.METRIC_GOLD },
			{ key = "xp", label = L.METRIC_XP },
			{ key = "time", label = L.METRIC_TIME },
		},
		"segmented",
		function(metric)
			Database.Set("heatmapMetric", metric)
		end
	)
	self.metricTabs:SetPoint("BOTTOMRIGHT", activity, "BOTTOMRIGHT", 0, 4)
	y = y + 30
	self.heatmap = Heatmap.New(content, function(day)
		ns.MainWindow.OpenDay(day)
	end)
	self.heatmap:SetPoint("TOPLEFT", 0, -y)
	y = y + Heatmap.HEIGHT + SECTION_GAP

	local half = (width - 2 * SECTION_GAP) / 2
	self.records = Column(content, L.SECTION_RECORDS, 5, 0, y, half)
	self.streaks = Column(content, L.SECTION_STREAKS, 4, half + 2 * SECTION_GAP, y, half)
	y = y + 26 + 5 * MINI_ROW_HEIGHT + SECTION_GAP

	local third = (width - 2 * SECTION_GAP) / 3
	self.topItems = Column(content, L.SECTION_TOP_ITEMS, TOP_COUNT, 0, y, third)
	self.topMonsters = Column(content, L.SECTION_TOP_MONSTERS, TOP_COUNT, third + SECTION_GAP, y, third)
	self.topZones = Column(content, L.SECTION_TOP_ZONES, TOP_COUNT, 2 * (third + SECTION_GAP), y, third)
	y = y + 26 + TOP_COUNT * MINI_ROW_HEIGHT

	content:SetHeight(y + 4)
end

local function OpenSession(id)
	return function()
		ns.MainWindow.OpenSession(id)
	end
end

function SummaryViewMixin:RefreshCards(lifetime, now, excludeAfk)
	local metrics = Session.Metrics(lifetime, now, excludeAfk)
	local overview = Stats.Overview(lifetime, now, excludeAfk)
	local specs = {
		{ "duration", L.CARD_TIME_PLAYED, Format.Duration(metrics.duration), L.CARD_SESSIONS:format(metrics.sessions) },
		{
			"goldEarned",
			L.CARD_GOLD_EARNED,
			Format.MoneyShort(metrics.goldEarned),
			Format.PerHour(metrics.goldPerHour, Format.MoneyShortText),
		},
		{
			"rawGold",
			L.CARD_RAW_GOLD,
			Format.MoneyShort(metrics.money),
			Format.PerHour(metrics.moneyPerHour, Format.MoneyShortText),
		},
		{
			"itemValue",
			L.CARD_ITEM_VALUE,
			Format.MoneyShort(metrics.itemValue),
			L.CARD_ITEM_COUNT:format(Format.Integer(metrics.items)),
		},
		{
			"xp",
			L.CARD_XP,
			Format.Compact(metrics.xp),
			Format.PerHour(metrics.xpPerHour, Format.Compact) or L.CARD_LEVELS_GAINED:format(metrics.levels),
		},
		{ "kills", L.CARD_KILLS, Format.Integer(metrics.kills), L.CARD_KINDS:format(metrics.kinds) },
		{ "quests", L.CARD_QUESTS, Format.Integer(metrics.quests), L.CARD_ZONES_VISITED:format(metrics.zones) },
		{
			"average",
			L.CARD_AVERAGE_SESSION,
			Format.Duration(overview.averageSeconds),
			L.CARD_PER_WEEK:format(overview.sessionsPerWeek),
		},
	}
	for index, spec in ipairs(specs) do
		self.cards[index]:SetContent(Theme.Icon(spec[1]), spec[2], spec[3], spec[4])
	end
end

function SummaryViewMixin:RefreshRecords(now, excludeAfk)
	local records = Stats.Records(now, excludeAfk)
	local rows = self.records.rows
	local specs = {
		{ "goldPerHour", L.RECORD_GOLD_PER_HOUR, "goldPerHour", Format.MoneyShort },
		{ "xpPerHour", L.RECORD_XP_PER_HOUR, "xpPerHour", Format.Compact },
		{ "duration", L.RECORD_LONGEST, "longest", Format.Duration },
		{ "kills", L.RECORD_MOST_KILLS, "mostKills", Format.Integer },
		{ "goldEarned", L.RECORD_MOST_GOLD, "mostGold", Format.MoneyShort },
	}
	for index, spec in ipairs(specs) do
		local record = records[spec[3]]
		local tooltip = record and { spec[2], { L.SESSION_NUMBER:format(record.id), L.CLICK_TO_OPEN } }
		FillRow(
			rows[index],
			Theme.Icon(spec[1]),
			spec[2],
			record and spec[4](record.value) or NO_VALUE,
			record and OpenSession(record.id),
			tooltip
		)
	end
end

function SummaryViewMixin:RefreshStreaks(lifetime, now, excludeAfk)
	local streaks = Stats.Streaks(now)
	local overview = Stats.Overview(lifetime, now, excludeAfk)
	local rows = self.streaks.rows
	FillRow(rows[1], Theme.Icon("streak"), L.STREAK_CURRENT, L.DAYS_COUNT:format(streaks.current))
	FillRow(rows[2], Theme.Icon("record"), L.STREAK_LONGEST, L.DAYS_COUNT:format(streaks.longest))
	FillRow(rows[3], Theme.Icon("average"), L.AVERAGE_SESSION, Format.Duration(overview.averageSeconds))
	FillRow(rows[4], Theme.Icon("sessions"), L.SESSIONS_PER_WEEK, string.format("%.1f", overview.sessionsPerWeek))
end

function SummaryViewMixin:RefreshTopLists(lifetime)
	for index, row in ipairs(self.topItems.rows) do
		local item = lifetime.items[index]
		if item then
			local name = C_Item.GetItemInfo(item.itemID)
			FillRow(
				row,
				C_Item.GetItemIconByID(item.itemID),
				name or L.ITEM_LOADING:format(item.itemID),
				Format.MoneyShort(item.value),
				nil,
				{ name or "", { { L.VALUE_TOTAL:format(Format.Integer(item.count)), Format.Money(item.value) } } }
			)
		else
			row:Hide()
		end
	end
	for index, row in ipairs(self.topMonsters.rows) do
		local monster = lifetime.monsters[index]
		if monster then
			FillRow(row, Theme.CreatureIcon(monster.typeID), monster.name, "×" .. Format.Integer(monster.count))
		else
			row:Hide()
		end
	end
	for index, row in ipairs(self.topZones.rows) do
		local zone = lifetime.zones[index]
		if zone then
			FillRow(row, Theme.ZoneIcon(zone.kind), zone.name, Format.Duration(zone.seconds))
		else
			row:Hide()
		end
	end
end

--- Recomputes everything from history and the live session.
function SummaryViewMixin:Refresh(now)
	local excludeAfk = Database.Get("excludeAfk")
	local metric = Database.Get("heatmapMetric")
	local lifetime = History.Query("all", now)
	self:RefreshCards(lifetime, now, excludeAfk)
	self.metricTabs:Select(metric, true)
	self.heatmap:SetData(Stats.Daily(metric, now, excludeAfk), metric, now, Database.Get("weekStart"))
	self:RefreshRecords(now, excludeAfk)
	self:RefreshStreaks(lifetime, now, excludeAfk)
	self:RefreshTopLists(lifetime)
end

--- The summary changes with events, not with time.
function SummaryViewMixin:Tick() end

--- Runs the computations of a refresh without touching frames (for /sesh debug perf).
function SummaryView.Measure(now)
	local excludeAfk = Database.Get("excludeAfk")
	local lifetime = History.Query("all", now)
	Session.Metrics(lifetime, now, excludeAfk)
	Stats.Daily(Database.Get("heatmapMetric"), now, excludeAfk)
	Stats.Records(now, excludeAfk)
	Stats.Streaks(now)
	Stats.Overview(lifetime, now, excludeAfk)
end

---@return table
function SummaryView.New(parent)
	local frame = Mixin(CreateFrame("Frame", nil, parent), SummaryViewMixin)
	frame:SetSize(parent:GetWidth(), parent:GetHeight())
	frame:SetPoint("TOPLEFT")
	local scrollFrame, content = Widgets.ScrollArea(frame)
	scrollFrame:SetPoint("TOPLEFT")
	scrollFrame:SetPoint("BOTTOMRIGHT", -12, 0)
	content:SetWidth(frame:GetWidth() - 12)
	frame.content = content
	frame:Build()
	return frame
end
