local _, ns = ...

--- The mini window: a small panel with just the current-session numbers the player picked,
--- and nothing else. In mini mode it takes the main window's place whenever that is closed.
--- Click it to open Sesh, Shift-drag it to move it, right-click it to choose what it shows
--- or to hide it. Its background can be faded out completely, leaving just the numbers.
---@class SeshMiniWindow
local MiniWindow = ns.MiniWindow
local Recorder = ns.Recorder
local Session = ns.Session
local Progress = ns.Progress
local Database = ns.Database
local Events = ns.Events
local Format = ns.Format
local Theme = ns.Theme
local Widgets = ns.Widgets
local L = ns.L

local WIDTH = 200
local ROW_HEIGHT = 18
local PROGRESS_ROW_HEIGHT = 24
local TOP_PADDING = 4
local BOTTOM_PADDING = 4
local PADDING = 10
local ICON_SIZE = 14
local BAR_HEIGHT = 2
local NO_VALUE = "—"

local frame ---@type table?
local ticker
local view ---@type SeshView? the current session, rebuilt when it changes

---@class SeshMiniContext
---@field metrics SeshMetrics? nil while no session is being recorded
---@field level number?
---@field xp number?
---@field xpMax number?
---@field canLevel boolean the character can still level up

-- Reused on every update, so the per-second ticker doesn't allocate.
local context = { canLevel = false } ---@type SeshMiniContext

---@class SeshMiniMetric
---@field key string
---@field name string shown on the row, in the menu and in the options
---@field icon string Theme icon key
---@field value fun(m: SeshMetrics, context: SeshMiniContext): string
---@field label (fun(context: SeshMiniContext): string)? row label when it isn't the name
---@field leveling boolean? only shown while the character can still level up
---@field progress boolean? draws the level's progress bar

local function PerHour(rate, formatter)
	return rate and formatter(rate) or NO_VALUE
end

--- What the mini window can show, in display order. The leveling numbers come last, so
--- the level's progress bar closes the window.
---@type SeshMiniMetric[]
MiniWindow.METRICS = {
	{
		key = "duration",
		name = L.MINI_SESSION,
		icon = "duration",
		value = function(m)
			return Format.Duration(m.duration)
		end,
	},
	{
		key = "goldEarned",
		name = L.CARD_GOLD_EARNED,
		icon = "goldEarned",
		value = function(m)
			return Format.MoneyShort(m.goldEarned)
		end,
	},
	{
		key = "goldPerHour",
		name = L.CARD_GOLD_PER_HOUR,
		icon = "goldPerHour",
		value = function(m)
			return PerHour(m.goldPerHour, Format.MoneyShort)
		end,
	},
	{
		key = "rawGold",
		name = L.CARD_RAW_GOLD,
		icon = "rawGold",
		value = function(m)
			return Format.MoneyShort(m.money)
		end,
	},
	{
		key = "itemValue",
		name = L.CARD_ITEM_VALUE,
		icon = "itemValue",
		value = function(m)
			return Format.MoneyShort(m.itemValue)
		end,
	},
	{
		key = "kills",
		name = L.CARD_KILLS,
		icon = "kills",
		value = function(m)
			return Format.Integer(m.kills)
		end,
	},
	{
		key = "quests",
		name = L.CARD_QUESTS,
		icon = "quests",
		value = function(m)
			return Format.Integer(m.quests)
		end,
	},
	{
		key = "dungeons",
		name = L.CARD_DUNGEONS,
		icon = "zoneDungeon",
		value = function(m)
			return Format.Integer(m.dungeons)
		end,
	},
	{
		key = "deaths",
		name = L.CARD_DEATHS,
		icon = "deaths",
		value = function(m)
			return Format.Integer(m.deaths)
		end,
	},
	{
		key = "xp",
		name = L.CARD_XP,
		icon = "xp",
		leveling = true,
		value = function(m)
			return Format.Compact(m.xp)
		end,
	},
	{
		key = "xpPerHour",
		name = L.CARD_XP_PER_HOUR,
		icon = "xpPerHour",
		leveling = true,
		value = function(m)
			return PerHour(m.xpPerHour, Format.Compact)
		end,
	},
	{
		key = "levelUpIn",
		name = L.LEVEL_UP_IN,
		icon = "average",
		leveling = true,
		value = function(m)
			local seconds = Progress.TimeToLevel(m.xpPerHour)
			return seconds and Format.Duration(seconds) or NO_VALUE
		end,
	},
	{
		key = "levelProgress",
		name = L.MINI_LEVEL_PROGRESS,
		icon = "levelUp",
		leveling = true,
		progress = true,
		label = function(c)
			return L.LEVEL_N:format(c.level)
		end,
		value = function(_, c)
			return Format.Percent(c.xp / c.xpMax)
		end,
	},
}

local function IsChosen(key)
	return Database.Get("miniFields")[key] == true
end

local function ToggleChosen(key)
	local fields = Database.Get("miniFields")
	fields[key] = not fields[key]
	Database.Set("miniFields", fields)
end

local function UpdateContext(now)
	context.metrics = view and Session.Metrics(view, now, Database.Get("excludeAfk"))
	context.level, context.xp, context.xpMax = Progress.Experience()
	context.canLevel = context.level ~= nil and context.xp ~= nil and Progress.CanLevel(context.xpMax)
end

-- Leveling numbers don't apply at the level cap.
local function Applies(metric)
	return not metric.leveling or context.canLevel
end

-- Rows -------------------------------------------------------------------------------------

local function BuildRow(metric)
	local row = CreateFrame("Frame", nil, frame)
	row:SetHeight(metric.progress and PROGRESS_ROW_HEIGHT or ROW_HEIGHT)
	-- A row with a bar keeps its text clear of the bar.
	local lift = metric.progress and 3 or 0
	row.icon = Widgets.Icon(row, ICON_SIZE)
	row.icon:SetPoint("LEFT", PADDING, lift)
	row.icon:SetTexture(Theme.Icon(metric.icon))
	row.value = Widgets.Text(row, "body")
	row.value:SetPoint("RIGHT", -PADDING, lift)
	row.value:SetJustifyH("RIGHT")
	row.label = Widgets.Text(row, "small", "dim")
	row.label:SetPoint("LEFT", row.icon, "RIGHT", 7, 0)
	row.label:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
	row.label:SetText(metric.name)
	if metric.progress then
		row.barWidth = WIDTH - 2 * PADDING
		row.track = row:CreateTexture(nil, "ARTWORK")
		row.track:SetPoint("BOTTOMLEFT", PADDING, 4)
		row.track:SetSize(row.barWidth, BAR_HEIGHT)
		row.track:SetColorTexture(unpack(Theme.COLORS.track))
		row.rested = row:CreateTexture(nil, "ARTWORK", nil, 1)
		row.rested:SetHeight(BAR_HEIGHT)
		Theme.PaintAccent(row.rested, 0.35)
		row.fill = row:CreateTexture(nil, "ARTWORK", nil, 2)
		row.fill:SetPoint("TOPLEFT", row.track)
		row.fill:SetHeight(BAR_HEIGHT)
		Theme.PaintAccent(row.fill, 1)
	end
	return row
end

local function FillBar(row)
	local fraction = math.min(1, context.xp / context.xpMax)
	row.fill:SetShown(fraction > 0)
	row.fill:SetWidth(math.max(1, row.barWidth * fraction))
	local rested = Progress.Rested()
	local restedWidth = rested and math.min(rested / context.xpMax, 1 - fraction) * row.barWidth or 0
	row.rested:SetShown(restedWidth >= 1)
	if restedWidth >= 1 then
		row.rested:ClearAllPoints()
		row.rested:SetPoint("TOPLEFT", row.track, "TOPLEFT", row.barWidth * fraction, 0)
		row.rested:SetWidth(restedWidth)
	end
end

--- Writes the current numbers into the shown rows.
local function Fill()
	local metrics = context.metrics
	for index, metric in ipairs(MiniWindow.METRICS) do
		local row = frame.rows[index]
		if row:IsShown() then
			if metric.label then
				row.label:SetText(metric.label(context))
			end
			row.value:SetText(metrics and metric.value(metrics, context) or NO_VALUE)
			if metric.progress then
				FillBar(row)
			end
		end
	end
end

--- Shows the rows the player chose (that apply right now) and fits the window to them.
--- The window is anchored by its top, so it grows and shrinks downward.
local function Layout()
	local y = TOP_PADDING
	for index, metric in ipairs(MiniWindow.METRICS) do
		local row = frame.rows[index]
		local shown = IsChosen(metric.key) and Applies(metric)
		row:SetShown(shown)
		if shown then
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, -y)
			row:SetPoint("TOPRIGHT", 0, -y)
			y = y + row:GetHeight()
		end
	end
	-- With nothing to show, say how to choose something.
	local empty = y == TOP_PADDING
	frame.empty:SetShown(empty)
	if empty then
		y = y + ROW_HEIGHT
	end
	frame:SetHeight(y + BOTTOM_PADDING)
	frame.laidOutLeveling = context.canLevel
end

local function Refresh()
	if not (frame and frame:IsShown()) then
		return
	end
	local now = GetServerTime()
	view = Recorder.LiveView(now)
	UpdateContext(now)
	Layout()
	Fill()
end

local function Tick()
	UpdateContext(GetServerTime())
	-- Leveling rows come and go with the level cap.
	if context.canLevel ~= frame.laidOutLeveling then
		Layout()
	end
	Fill()
end

local function ScheduleRefresh()
	if frame and frame:IsShown() then
		Events.Debounce("miniRefresh", 0.1, Refresh)
	end
end

--- Fades the background and border; the numbers and icons stay fully visible.
local function ApplyOpacity()
	local opacity = math.max(0, math.min(100, Database.Get("miniOpacity"))) / 100
	local panel, border = Theme.COLORS.panel, Theme.COLORS.border
	frame.background:SetColorTexture(panel[1], panel[2], panel[3], panel[4] * opacity)
	for _, edge in ipairs(frame.edges) do
		edge:SetColorTexture(border[1], border[2], border[3], border[4] * opacity)
	end
end

-- Interaction ------------------------------------------------------------------------------

local function ShowTooltip(owner)
	-- Open the tooltip toward the middle of the screen.
	local x = owner:GetCenter()
	local onRight = x and x * owner:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2
	GameTooltip:SetOwner(owner, onRight and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	GameTooltip:SetText(L.ADDON_TITLE_PLAIN, 1, 1, 1)
	GameTooltip:AddLine(L.MINI_HINT_CLICK, 0.75, 0.75, 0.75)
	GameTooltip:AddLine(L.MINI_HINT_MOVE, 0.75, 0.75, 0.75)
	GameTooltip:AddLine(L.MINI_HINT_MENU, 0.75, 0.75, 0.75)
	GameTooltip:Show()
end

local function AddMetricCheckboxes(root, leveling)
	for _, metric in ipairs(MiniWindow.METRICS) do
		if (metric.leveling == true) == leveling then
			root:CreateCheckbox(metric.name, IsChosen, ToggleChosen, metric.key)
		end
	end
end

local function OpenMenu(owner)
	GameTooltip:Hide()
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		ns.Options.Open()
		return
	end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(L.MINI_SHOWS)
		AddMetricCheckboxes(root, false)
		-- Shown on any character that can still level up.
		root:CreateTitle(L.MINI_WHILE_LEVELING)
		AddMetricCheckboxes(root, true)
		root:CreateDivider()
		root:CreateButton(L.OPEN_SESH, function()
			ns.MainWindow.Open("session")
		end)
		root:CreateButton(L.OPTIONS, function()
			ns.Options.Open()
		end)
		root:CreateButton(L.MINI_HIDE, function()
			MiniWindow.Exit()
		end)
	end)
end

-- After a move the client may anchor the window by any point; anchoring it by its
-- top-left corner keeps the top in place when rows come and go.
local function AnchorByTopLeft(self)
	local left, top = self:GetLeft(), self:GetTop()
	if left and top then
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	end
end

local function StopMoving(self)
	if self.moving then
		self:StopMovingOrSizing()
		self.moving = nil
		self.movedAt = GetTime()
		AnchorByTopLeft(self)
		Database.SavePosition("mini", self)
	end
end

local function Build()
	frame = CreateFrame("Button", "SeshMiniWindow", UIParent)
	frame:SetSize(WIDTH, TOP_PADDING + ROW_HEIGHT + BOTTOM_PADDING)
	frame:SetFrameStrata("MEDIUM")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetDontSavePosition(true)
	frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	frame:SetScale(Database.Get("miniScale"))
	frame.background = Theme.Fill(frame, Theme.COLORS.panel)
	frame.edges = Theme.Border(frame)
	frame.hover = Theme.Fill(frame, Theme.COLORS.hover, "BORDER")
	frame.hover:Hide()
	ApplyOpacity()

	frame.rows = {}
	for index, metric in ipairs(MiniWindow.METRICS) do
		frame.rows[index] = BuildRow(metric)
	end
	frame.empty = Widgets.Text(frame, "small", "faint")
	frame.empty:SetPoint("TOPLEFT", PADDING, -(TOP_PADDING + 3))
	frame.empty:SetText(L.MINI_EMPTY)

	frame:SetScript("OnEnter", function(self)
		self.hover:Show()
		if not self.moving then
			ShowTooltip(self)
		end
	end)
	frame:SetScript("OnLeave", function(self)
		self.hover:Hide()
		GameTooltip:Hide()
	end)
	-- Moving needs Shift, so a plain click never drags the window by accident.
	frame:SetScript("OnMouseDown", function(self, button)
		if button == "LeftButton" and IsShiftKeyDown() then
			GameTooltip:Hide()
			self.moving = true
			self:StartMoving()
		end
	end)
	frame:SetScript("OnMouseUp", StopMoving)
	frame:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			OpenMenu(self)
		elseif not (self.moving or self.movedAt == GetTime() or IsShiftKeyDown()) then
			ns.MainWindow.Open("session")
		end
	end)
	frame:SetScript("OnShow", function()
		if not ticker then
			ticker = C_Timer.NewTicker(1, Tick)
		end
		Refresh()
	end)
	frame:SetScript("OnHide", function(self)
		StopMoving(self)
		self.hover:Hide()
		if ticker then
			ticker:Cancel()
			ticker = nil
		end
	end)

	if not Database.RestorePosition("mini", frame) then
		-- Left of centre by default: the quest tracker usually fills the right side.
		frame:SetPoint("TOPLEFT", UIParent, "LEFT", 40, 180)
	end
	frame:Hide()
end

-- Mini mode ----------------------------------------------------------------------------------

--- Shows the mini window when mini mode is on and the main window is closed, hides it
--- otherwise.
function MiniWindow.Update()
	if Database.Get("miniMode") == true and not ns.MainWindow.IsShown() then
		if not frame then
			Build()
		end
		frame:Show()
	elseif frame then
		frame:Hide()
	end
end

--- Turns mini mode on: Sesh collapses into the mini window.
function MiniWindow.Enter()
	Database.Set("miniMode", true)
	ns.MainWindow.Close()
	MiniWindow.Update()
end

--- Turns mini mode off and hides the mini window.
function MiniWindow.Exit()
	Database.Set("miniMode", false)
	ns.Print(L.MINI_HIDDEN)
end

--- /sesh mini: shrinks Sesh into the mini window, or hides the mini window when that is
--- what's showing.
function MiniWindow.Toggle()
	if Database.Get("miniMode") == true and not ns.MainWindow.IsShown() then
		MiniWindow.Exit()
	else
		MiniWindow.Enter()
	end
end

for _, signal in ipairs({
	"SESH_SESSION_UPDATED",
	"SESH_SESSION_STARTED",
	"SESH_VALUES_CHANGED",
	"SESH_LEVELS_CHANGED",
}) do
	Events.On(signal, ScheduleRefresh)
end
-- Rested experience changes on its own while resting.
Events.On("UPDATE_EXHAUSTION", ScheduleRefresh)
Events.On("SESH_SETTINGS_CHANGED", function(key)
	if key == "miniMode" then
		MiniWindow.Update()
	elseif key == "miniScale" and frame then
		frame:SetScale(Database.Get("miniScale"))
		Theme.RefreshPixels()
	elseif key == "miniOpacity" and frame then
		ApplyOpacity()
	elseif key == "miniFields" or key == "excludeAfk" then
		ScheduleRefresh()
	end
end)
