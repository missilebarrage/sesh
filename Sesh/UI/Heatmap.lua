local _, ns = ...

--- GitHub-style activity grid: one column per week, one row per weekday, the last 53
--- weeks. Cells are coloured with the accent at four strengths (quartiles of the active
--- days). The 371 cells are plain textures created once; a single hit-test frame resolves
--- which day is under the cursor, so there are no per-cell mouse frames.
---@class SeshHeatmap
local Heatmap = ns.Heatmap
local Stats = ns.Stats
local Theme = ns.Theme
local Widgets = ns.Widgets
local Format = ns.Format
local L = ns.L

local WEEKS = 53
local CELL = 9
local STEP = CELL + 2
local LABEL_WIDTH = 28
local MONTH_HEIGHT = 14
local LEGEND_HEIGHT = 18
local LEVEL_ALPHAS = { 0.3, 0.5, 0.75, 1 }
local MONDAY, WEDNESDAY, FRIDAY = 2, 4, 6

Heatmap.WIDTH = LABEL_WIDTH + WEEKS * STEP
Heatmap.HEIGHT = MONTH_HEIGHT + 7 * STEP + LEGEND_HEIGHT

local HeatmapMixin = {}

local function PaintLevel(texture, level)
	if level == 0 then
		Theme.ForgetAccent(texture)
		texture:SetColorTexture(unpack(Theme.COLORS.empty))
	else
		Theme.PaintAccent(texture, LEVEL_ALPHAS[level])
	end
end

function HeatmapMixin:Build()
	self.cells = {}
	for column = 1, WEEKS do
		for row = 1, 7 do
			local cell = self:CreateTexture(nil, "ARTWORK")
			cell:SetSize(CELL, CELL)
			cell:SetPoint("TOPLEFT", LABEL_WIDTH + (column - 1) * STEP, -(MONTH_HEIGHT + (row - 1) * STEP))
			self.cells[(column - 1) * 7 + row] = cell
		end
	end

	self.hoverMark = self:CreateTexture(nil, "OVERLAY")
	self.hoverMark:SetSize(CELL, CELL)
	self.hoverMark:SetColorTexture(1, 1, 1, 0.45)
	self.hoverMark:Hide()

	self.weekdayLabels = {}
	for row = 1, 7 do
		local label = Widgets.Text(self, "label", "faint")
		label:SetPoint("TOPLEFT", 0, -(MONTH_HEIGHT + (row - 1) * STEP) + 1)
		self.weekdayLabels[row] = label
	end
	self.monthLabels = {}

	local legendRight = Widgets.Text(self, "label", "faint")
	legendRight:SetPoint("BOTTOMRIGHT", 0, 2)
	legendRight:SetText(L.MORE_ACTIVITY)
	local anchor = legendRight
	for level = 4, 0, -1 do
		local swatch = self:CreateTexture(nil, "ARTWORK")
		swatch:SetSize(CELL, CELL)
		swatch:SetPoint("RIGHT", anchor, "LEFT", level == 4 and -4 or -2, 0)
		PaintLevel(swatch, level)
		anchor = swatch
	end
	local legendLeft = Widgets.Text(self, "label", "faint")
	legendLeft:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
	legendLeft:SetText(L.LESS_ACTIVITY)

	-- One invisible button over the grid handles hover and clicks for every cell.
	local hit = CreateFrame("Button", nil, self)
	hit:SetPoint("TOPLEFT", LABEL_WIDTH, -MONTH_HEIGHT)
	hit:SetSize(WEEKS * STEP, 7 * STEP)
	hit:SetScript("OnEnter", function()
		hit:SetScript("OnUpdate", function()
			self:UpdateHover()
		end)
	end)
	hit:SetScript("OnLeave", function()
		hit:SetScript("OnUpdate", nil)
		self.hoveredDay = nil
		self.hoverMark:Hide()
		GameTooltip:Hide()
	end)
	hit:SetScript("OnClick", function()
		local day = self:DayAtCursor()
		if day and self.onDayClick then
			self.onDayClick(day)
		end
	end)
	self.hit = hit
end

local function MonthLabel(self, index)
	local label = self.monthLabels[index]
	if not label then
		label = Widgets.Text(self, "label", "faint")
		self.monthLabels[index] = label
	end
	return label
end

--- Shows daily totals for the 53 weeks ending today.
---@param daily table<integer, number> metric total per day number
---@param metric "gold"|"xp"|"time"
---@param now integer
---@param weekStart integer 1 = Sunday ... 7 = Saturday
function HeatmapMixin:SetData(daily, metric, now, weekStart)
	local today = Stats.DayOf(now)
	local todayRow = (Stats.Weekday(today) - weekStart) % 7
	local firstDay = today - todayRow - (WEEKS - 1) * 7
	self.daily, self.metric, self.firstDay, self.today = daily, metric, firstDay, today

	local values = {}
	for day = firstDay, today do
		if daily[day] then
			values[#values + 1] = daily[day]
		end
	end
	local thresholds = Stats.Thresholds(values)
	for index, cell in ipairs(self.cells) do
		local day = firstDay + index - 1
		cell:SetShown(day <= today)
		if day <= today then
			PaintLevel(cell, Stats.Bucket(daily[day], thresholds))
		end
	end

	for row, label in ipairs(self.weekdayLabels) do
		local weekday = (weekStart - 1 + row - 1) % 7 + 1
		local shown = weekday == MONDAY or weekday == WEDNESDAY or weekday == FRIDAY
		label:SetText(shown and L.WEEKDAYS_SHORT[weekday] or "")
	end

	-- A month label above the first column containing the 1st, unless it would collide
	-- with the previous label.
	local used, lastColumn = 0, -10
	for column = 0, WEEKS - 1 do
		for row = 0, 6 do
			local day = firstDay + column * 7 + row
			local _, month, dayOfMonth = Stats.DateOf(day)
			if dayOfMonth == 1 and day <= today and column - lastColumn > 2 then
				used = used + 1
				local label = MonthLabel(self, used)
				label:ClearAllPoints()
				label:SetPoint("TOPLEFT", LABEL_WIDTH + column * STEP, 0)
				label:SetText(L.MONTHS_SHORT[month])
				label:Show()
				lastColumn = column
				break
			end
		end
	end
	for index = used + 1, #self.monthLabels do
		self.monthLabels[index]:Hide()
	end
end

--- The day number under the cursor, or nil.
---@return integer?
function HeatmapMixin:DayAtCursor()
	if not self.firstDay then
		return nil
	end
	local x, y = GetCursorPosition()
	local scale = self.hit:GetEffectiveScale()
	x, y = x / scale, y / scale
	local column = math.floor((x - self.hit:GetLeft()) / STEP)
	local row = math.floor((self.hit:GetTop() - y) / STEP)
	if column < 0 or column >= WEEKS or row < 0 or row > 6 then
		return nil
	end
	local day = self.firstDay + column * 7 + row
	return day <= self.today and day or nil
end

local function FormatMetric(metric, value)
	if metric == "gold" then
		return Format.Money(value)
	elseif metric == "xp" then
		return Format.Integer(value) .. " " .. L.XP_SHORT
	end
	return Format.Duration(value)
end

function HeatmapMixin:UpdateHover()
	local day = self:DayAtCursor()
	if day == self.hoveredDay then
		return
	end
	self.hoveredDay = day
	if not day then
		self.hoverMark:Hide()
		GameTooltip:Hide()
		return
	end
	local cell = self.cells[day - self.firstDay + 1]
	self.hoverMark:ClearAllPoints()
	self.hoverMark:SetAllPoints(cell)
	self.hoverMark:Show()
	GameTooltip:SetOwner(self.hit, "ANCHOR_CURSOR")
	GameTooltip:SetText(Format.DateLong(Stats.MidnightOf(day)), 1, 1, 1)
	local value = self.daily[day]
	if value and value > 0 then
		GameTooltip:AddLine(FormatMetric(self.metric, value), 1, 1, 1)
		GameTooltip:AddLine(L.CLICK_FOR_DAY, 0.6, 0.6, 0.6)
	else
		GameTooltip:AddLine(L.NO_ACTIVITY, 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

---@param parent table
---@param onDayClick fun(day: integer)
---@return table
function Heatmap.New(parent, onDayClick)
	local frame = Mixin(CreateFrame("Frame", nil, parent), HeatmapMixin)
	frame:SetSize(Heatmap.WIDTH, Heatmap.HEIGHT)
	frame.onDayClick = onDayClick
	frame:Build()
	return frame
end
