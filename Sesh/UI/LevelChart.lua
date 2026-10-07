local _, ns = ...

--- A bar chart with one bar per level: how long each level took, or another metric.
--- Bars are plain textures reused between updates; like the heatmap, a single hit-test
--- frame finds the bar under the cursor, so there are no per-bar mouse frames.
---@class SeshLevelChart
local LevelChart = ns.LevelChart
local Theme = ns.Theme
local Widgets = ns.Widgets
local L = ns.L

local BAR_GAP = 2
local MAX_BAR_WIDTH = 24
local LABEL_HEIGHT = 14
local TOP_SPACE = 14
local MIN_LABEL_SPACING = 20
-- Bar strengths: levels Sesh saw whole, levels it saw part of, the level in progress.
local ALPHA = { complete = 0.8, partial = 0.35, current = 0.55, hovered = 1 }

local LevelChartMixin = {}

function LevelChartMixin:Build()
	self.bars = {}
	self.labels = {}
	self.barsHeight = self:GetHeight() - LABEL_HEIGHT - TOP_SPACE

	local baseline = Theme.Divider(self)
	baseline:SetPoint("BOTTOMLEFT", 0, LABEL_HEIGHT)
	baseline:SetPoint("BOTTOMRIGHT", 0, LABEL_HEIGHT)

	-- The value of the tallest bar, as a scale.
	self.scale = Widgets.Text(self, "label", "faint")
	self.scale:SetPoint("TOPLEFT")

	self.empty = Widgets.Text(self, "body", "faint")
	self.empty:SetPoint("CENTER", 0, LABEL_HEIGHT / 2)
	self.empty:SetJustifyH("CENTER")
	self.empty:SetText(L.LEVEL_CHART_EMPTY)

	local hit = CreateFrame("Button", nil, self)
	hit:SetSize(self:GetWidth(), self.barsHeight)
	hit:SetPoint("BOTTOMLEFT", 0, LABEL_HEIGHT)
	hit:SetScript("OnEnter", function()
		hit:SetScript("OnUpdate", function()
			self:UpdateHover()
		end)
	end)
	hit:SetScript("OnLeave", function()
		hit:SetScript("OnUpdate", nil)
		self:SetHovered(nil)
		GameTooltip:Hide()
	end)
	hit:SetScript("OnClick", function()
		local index = self:IndexAtCursor()
		if index then
			self.onClick(self.rows[index])
		end
	end)
	self.hit = hit
end

function LevelChartMixin:PaintBar(index)
	local row = self.rows[index]
	local alpha = ALPHA.complete
	if index == self.hovered then
		alpha = ALPHA.hovered
	elseif row.current then
		alpha = ALPHA.current
	elseif row.partial then
		alpha = ALPHA.partial
	end
	Theme.PaintAccent(self.bars[index], alpha)
end

function LevelChartMixin:SetHovered(index)
	local previous = self.hovered
	self.hovered = index
	if previous and self.rows[previous] then
		self:PaintBar(previous)
	end
	if index then
		self:PaintBar(index)
	end
end

local function Label(self, index)
	local label = self.labels[index]
	if not label then
		label = Widgets.Text(self, "label", "faint")
		label:SetJustifyH("CENTER")
		self.labels[index] = label
	end
	return label
end

--- Shows one bar per level row, left to right.
---@param rows SeshLevelRow[]
---@param valueOf fun(row: SeshLevelRow): number
---@param formatValue fun(value: number): string for the scale
function LevelChartMixin:SetData(rows, valueOf, formatValue)
	self.rows = rows
	local count = #rows
	self.empty:SetShown(count == 0)
	local barWidth = 1
	if count > 0 then
		barWidth = math.max(1, math.min(MAX_BAR_WIDTH, math.floor((self:GetWidth() - BAR_GAP * (count - 1)) / count)))
	end
	self.step = barWidth + BAR_GAP

	local highest = 0
	for _, row in ipairs(rows) do
		highest = math.max(highest, valueOf(row))
	end
	for index, row in ipairs(rows) do
		local bar = self.bars[index]
		if not bar then
			bar = self:CreateTexture(nil, "ARTWORK")
			self.bars[index] = bar
		end
		local height = highest > 0 and valueOf(row) / highest * self.barsHeight or 0
		bar:ClearAllPoints()
		bar:SetPoint("BOTTOMLEFT", (index - 1) * self.step, LABEL_HEIGHT)
		bar:SetSize(barWidth, math.max(1, height))
		bar:Show()
		self:PaintBar(index)
	end
	for index = count + 1, #self.bars do
		self.bars[index]:Hide()
	end
	if self.hovered and self.hovered > count then
		self.hovered = nil
	end

	-- Level numbers under the bars, spaced out so they don't overlap.
	local every = math.max(1, math.ceil(MIN_LABEL_SPACING / self.step))
	local used = 0
	for index = 1, count, every do
		used = used + 1
		local label = Label(self, used)
		label:ClearAllPoints()
		label:SetPoint("TOP", self, "BOTTOMLEFT", (index - 1) * self.step + barWidth / 2, LABEL_HEIGHT - 3)
		label:SetText(tostring(rows[index].level))
		label:Show()
	end
	for index = used + 1, #self.labels do
		self.labels[index]:Hide()
	end
	self.scale:SetText(highest > 0 and formatValue(highest) or "")
end

--- The index of the bar under the cursor, or nil.
---@return integer?
function LevelChartMixin:IndexAtCursor()
	local rows = self.rows
	if not (rows and #rows > 0) then
		return nil
	end
	local x = GetCursorPosition() / self.hit:GetEffectiveScale()
	local index = math.floor((x - self.hit:GetLeft()) / self.step) + 1
	if index >= 1 and index <= #rows then
		return index
	end
end

function LevelChartMixin:UpdateHover()
	local index = self:IndexAtCursor()
	if index == self.hovered then
		return
	end
	self:SetHovered(index)
	if not index then
		GameTooltip:Hide()
		return
	end
	GameTooltip:SetOwner(self.hit, "ANCHOR_CURSOR")
	self.onTooltip(self.rows[index])
	GameTooltip:Show()
end

---@class SeshLevelChartHandlers
---@field onClick fun(row: SeshLevelRow)
---@field onTooltip fun(row: SeshLevelRow) fills GameTooltip (already owned) for a bar

---@param parent table
---@param width number
---@param height number
---@param handlers SeshLevelChartHandlers
---@return table
function LevelChart.New(parent, width, height, handlers)
	local frame = Mixin(CreateFrame("Frame", nil, parent), LevelChartMixin)
	frame:SetSize(width, height)
	frame.onClick = handlers.onClick
	frame.onTooltip = handlers.onTooltip
	frame:Build()
	return frame
end
