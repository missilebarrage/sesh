local _, ns = ...

--- Reusable themed widgets, built in Lua with mixins. Visuals: flat fills, hairline
--- borders, white text graded by alpha and the accent colour for selection.
---@class SeshWidgets
local Widgets = ns.Widgets
local Theme = ns.Theme

local HOVER_ALPHA = 1
local IDLE_ALPHA = 0.55

-- Text and tooltips ------------------------------------------------------------------------

---@param parent table
---@param role string? font role (see Theme.Font), default "body"
---@param tone string? "primary" | "dim" | "muted" | "faint", default "primary"
---@return table fontString
function Widgets.Text(parent, role, tone)
	local text = parent:CreateFontString(nil, "OVERLAY")
	text:SetFontObject(Theme.Font(role or "body"))
	Theme.Tone(text, tone or "primary")
	text:SetJustifyH("LEFT")
	text:SetWordWrap(false)
	return text
end

--- Shows GameTooltip next to a frame. Lines are strings or {left, right} pairs.
---@param owner table
---@param title string
---@param lines (string|string[])[]?
function Widgets.ShowTooltip(owner, title, lines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(title, 1, 1, 1)
	for _, line in ipairs(lines or {}) do
		if type(line) == "table" then
			GameTooltip:AddDoubleLine(line[1], line[2], 0.75, 0.75, 0.75, 1, 1, 1)
		else
			GameTooltip:AddLine(line, 0.75, 0.75, 0.75, true)
		end
	end
	GameTooltip:Show()
end

function Widgets.HideTooltip()
	GameTooltip:Hide()
end

--- An icon texture with the default border trimmed off.
---@return table texture
function Widgets.Icon(parent, size, layer)
	local icon = parent:CreateTexture(nil, layer or "ARTWORK")
	icon:SetSize(size, size)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	return icon
end

-- Glyph buttons ------------------------------------------------------------------------

local SETTINGS_ATLAS = "questlog-icon-setting"
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- A white rectangle centred at (x, y), rotated by `degrees`.
local function Bar(parent, width, height, x, y, degrees, layer)
	local bar = parent:CreateTexture(nil, layer or "ARTWORK")
	bar:SetSize(width, height)
	bar:SetPoint("CENTER", parent, "CENTER", x, y)
	bar:SetColorTexture(1, 1, 1, 1)
	bar:SetRotation(math.rad(degrees))
	return bar
end

local function Disc(parent, size, layer)
	local disc = parent:CreateTexture(nil, layer or "ARTWORK")
	disc:SetSize(size, size)
	disc:SetPoint("CENTER")
	disc:SetColorTexture(1, 1, 1, 1)
	local mask = parent:CreateMaskTexture()
	mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(disc)
	disc:AddMaskTexture(mask)
	return disc
end

-- A cog drawn from a disc and eight teeth, for clients without the settings atlas. The
-- hole is a dark disc on top that keeps full opacity when the glyph fades.
local function DrawnCog(button)
	local regions = { Disc(button, 9) }
	for tooth = 0, 7 do
		local radians = math.rad(tooth * 45)
		regions[#regions + 1] = Bar(button, 3, 2.5, math.cos(radians) * 5, math.sin(radians) * 5, tooth * 45)
	end
	Disc(button, 3.5, "OVERLAY"):SetColorTexture(0.04, 0.035, 0.03, 1)
	return regions
end

-- Glyphs are drawn from textures (or use Blizzard's own art), so they stay crisp at any scale.
local GLYPHS = {
	close = function(button)
		return { Bar(button, 11, 1.5, 0, 0, 45), Bar(button, 11, 1.5, 0, 0, -45) }
	end,
	back = function(button)
		return { Bar(button, 7, 1.5, -1, 2.2, 40), Bar(button, 7, 1.5, -1, -2.2, -40) }
	end,
	minimize = function(button)
		return { Bar(button, 10, 1.5, 0, -3, 0) }
	end,
	settings = function(button)
		if not Theme.HasAtlas(SETTINGS_ATLAS) then
			return DrawnCog(button)
		end
		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetAtlas(SETTINGS_ATLAS)
		icon:SetSize(14, 14)
		icon:SetPoint("CENTER")
		icon:SetDesaturated(true)
		return { icon }
	end,
}

local GlyphButtonMixin = {}

function GlyphButtonMixin:SetGlyphAlpha(alpha)
	for _, line in ipairs(self.strokes) do
		line:SetAlpha(alpha)
	end
end

function GlyphButtonMixin:OnEnter()
	self:SetGlyphAlpha(HOVER_ALPHA)
	if self.tooltip then
		Widgets.ShowTooltip(self, self.tooltip)
	end
end

function GlyphButtonMixin:OnLeave()
	self:SetGlyphAlpha(IDLE_ALPHA)
	Widgets.HideTooltip()
end

---@param glyph "close"|"back"|"minimize"|"settings"
---@param tooltip string?
---@param onClick fun(button: table)
---@return table button
function Widgets.GlyphButton(parent, glyph, tooltip, onClick)
	local button = Mixin(CreateFrame("Button", nil, parent), GlyphButtonMixin)
	button:SetSize(20, 20)
	button.tooltip = tooltip
	button.strokes = GLYPHS[glyph](button)
	button:SetGlyphAlpha(IDLE_ALPHA)
	button:SetScript("OnEnter", button.OnEnter)
	button:SetScript("OnLeave", button.OnLeave)
	button:SetScript("OnClick", onClick)
	return button
end

-- Buttons ------------------------------------------------------------------------------

local ButtonMixin = {}

function ButtonMixin:SetLabel(text)
	self.label:SetText(text)
	if self.autoWidth then
		self:SetWidth(math.max(self.minWidth, self.label:GetStringWidth() + 24))
	end
end

function ButtonMixin:SetHighlighted(highlighted)
	local border = Theme.COLORS.controlBorder
	local alpha = highlighted and math.min(1, border[4] + 0.2) or border[4]
	for _, edge in ipairs(self.edges) do
		edge:SetColorTexture(border[1], border[2], border[3], alpha)
	end
	if self.primary then
		Theme.PaintAccent(self.label, highlighted and 1 or 0.85, "text")
	else
		Theme.Tone(self.label, highlighted and "primary" or "dim")
	end
end

function ButtonMixin:OnEnter()
	self:SetHighlighted(true)
	if self.tooltip then
		Widgets.ShowTooltip(self, self.tooltip)
	end
end

function ButtonMixin:OnLeave()
	self:SetHighlighted(false)
	Widgets.HideTooltip()
end

---@class SeshButtonOptions
---@field width number? fixed width; otherwise the button fits its label
---@field height number?
---@field primary boolean? accent-coloured label
---@field tooltip string?

--- A flat text button.
---@param label string
---@param onClick fun(button: table, mouseButton: string)
---@param options SeshButtonOptions?
---@return table button
function Widgets.Button(parent, label, onClick, options)
	options = options or {}
	local button = Mixin(CreateFrame("Button", nil, parent), ButtonMixin)
	button:SetSize(options.width or 80, options.height or 22)
	button.autoWidth = options.width == nil
	button.minWidth = 60
	button.primary = options.primary
	button.tooltip = options.tooltip
	Theme.Fill(button, Theme.COLORS.control)
	button.edges = Theme.Border(button, Theme.COLORS.controlBorder)
	button.label = Widgets.Text(button, "body")
	button.label:SetPoint("CENTER")
	button.label:SetJustifyH("CENTER")
	button:SetLabel(label)
	button:SetHighlighted(false)
	button:SetScript("OnEnter", button.OnEnter)
	button:SetScript("OnLeave", button.OnLeave)
	button:SetScript("OnClick", onClick)
	return button
end

-- Checkbox -----------------------------------------------------------------------------

local CheckboxMixin = {}

function CheckboxMixin:SetValue(checked)
	self.checkedValue = checked == true
	self.fill:SetShown(self.checkedValue)
	Theme.Tone(self.label, self.checkedValue and "primary" or "dim")
end

function CheckboxMixin:GetValue()
	return self.checkedValue
end

--- A filled-square checkbox with a label; the whole row is clickable.
---@param label string
---@param onChange fun(checked: boolean)
---@return table checkbox
function Widgets.Checkbox(parent, label, onChange)
	local checkbox = Mixin(CreateFrame("Button", nil, parent), CheckboxMixin)
	checkbox:SetHeight(18)
	local box = CreateFrame("Frame", nil, checkbox)
	box:SetSize(14, 14)
	box:SetPoint("LEFT")
	Theme.Fill(box, Theme.COLORS.control)
	Theme.Border(box, Theme.COLORS.controlBorder)
	checkbox.fill = box:CreateTexture(nil, "ARTWORK")
	checkbox.fill:SetPoint("TOPLEFT", 3, -3)
	checkbox.fill:SetPoint("BOTTOMRIGHT", -3, 3)
	Theme.PaintAccent(checkbox.fill, 1)
	checkbox.label = Widgets.Text(checkbox, "body", "dim")
	checkbox.label:SetPoint("LEFT", box, "RIGHT", 8, 0)
	checkbox.label:SetText(label)
	checkbox:SetWidth(checkbox.label:GetStringWidth() + 30)
	checkbox:SetScript("OnClick", function(self)
		self:SetValue(not self.checkedValue)
		onChange(self.checkedValue)
	end)
	checkbox:SetValue(false)
	return checkbox
end

-- Tabs ---------------------------------------------------------------------------------

local TabsMixin = {}

function TabsMixin:Select(key, silent)
	self.selected = key
	for _, tab in ipairs(self.tabs) do
		local active = tab.key == key
		if self.style == "underline" then
			tab.underline:SetShown(active)
			Theme.Tone(tab.label, active and "primary" or "dim")
		else
			tab.activeFill:SetShown(active)
			if active then
				Theme.PaintAccent(tab.label, 1, "text")
			else
				Theme.ForgetAccent(tab.label)
				Theme.Tone(tab.label, "dim")
			end
		end
	end
	if not silent and self.onSelect then
		self.onSelect(key)
	end
end

--- Changes tab labels (e.g. to show counts), then lays the tabs out once.
---@param labels table<any, string> label per tab key
function TabsMixin:SetLabels(labels)
	for _, tab in ipairs(self.tabs) do
		if labels[tab.key] then
			tab.label:SetText(labels[tab.key])
		end
	end
	self:Layout()
end

function TabsMixin:Layout()
	local x = 0
	for _, tab in ipairs(self.tabs) do
		local width = tab.label:GetStringWidth() + (self.style == "underline" and 16 or 20)
		tab:SetWidth(width)
		tab:ClearAllPoints()
		tab:SetPoint("LEFT", self, "LEFT", x, 0)
		x = x + width + (self.style == "underline" and 4 or 6)
	end
	self:SetWidth(math.max(1, x))
end

---@param items {key: any, label: string}[]
---@param style "underline"|"segmented"
---@param onSelect fun(key: any)
---@return table tabs
function Widgets.Tabs(parent, items, style, onSelect)
	local tabs = Mixin(CreateFrame("Frame", nil, parent), TabsMixin)
	tabs:SetHeight(style == "underline" and 28 or 20)
	tabs.style = style
	tabs.onSelect = onSelect
	tabs.tabs = {}
	for index, item in ipairs(items) do
		local tab = CreateFrame("Button", nil, tabs)
		tab.key = item.key
		tab:SetHeight(tabs:GetHeight())
		tab.label = Widgets.Text(tab, style == "underline" and "heading" or "small", "dim")
		tab.label:SetPoint("CENTER")
		tab.label:SetJustifyH("CENTER")
		tab.label:SetText(item.label)
		if style == "underline" then
			tab.underline = tab:CreateTexture(nil, "ARTWORK")
			tab.underline:SetPoint("BOTTOMLEFT", 4, 0)
			tab.underline:SetPoint("BOTTOMRIGHT", -4, 0)
			tab.underline:SetHeight(2)
			Theme.PaintAccent(tab.underline, 1)
		else
			Theme.Fill(tab, Theme.COLORS.control)
			Theme.Border(tab, Theme.COLORS.border)
			tab.activeFill = tab:CreateTexture(nil, "BORDER")
			tab.activeFill:SetAllPoints()
			Theme.PaintAccent(tab.activeFill, 0.12)
		end
		tab:SetScript("OnEnter", function(self)
			if tabs.selected ~= self.key then
				Theme.Tone(self.label, "primary")
			end
		end)
		tab:SetScript("OnLeave", function(self)
			if tabs.selected ~= self.key then
				Theme.Tone(self.label, "dim")
			end
		end)
		tab:SetScript("OnClick", function(self)
			tabs:Select(self.key)
		end)
		tabs.tabs[index] = tab
	end
	tabs:Layout()
	return tabs
end

-- Section header -----------------------------------------------------------------------

--- An uppercase label over a hairline.
---@return table header
function Widgets.SectionHeader(parent, text)
	local header = CreateFrame("Frame", nil, parent)
	header:SetHeight(22)
	header.text = Widgets.Text(header, "label", "muted")
	header.text:SetPoint("BOTTOMLEFT", 0, 5)
	header.text:SetText(text:upper())
	local line = Theme.Divider(header)
	line:SetPoint("BOTTOMLEFT")
	line:SetPoint("BOTTOMRIGHT")
	return header
end

-- Stat card ----------------------------------------------------------------------------

local StatCardMixin = {}

---@param icon string|number texture path or file id
---@param label string
---@param value string
---@param sub string?
---@param tooltip (fun(card: table))? fills GameTooltip on hover
function StatCardMixin:SetContent(icon, label, value, sub, tooltip)
	self.icon:SetTexture(icon)
	self.label:SetText(label:upper())
	self.value:SetText(value)
	self.sub:SetText(sub or "")
	self.tooltipFill = tooltip
end

function StatCardMixin:OnEnter()
	self.hover:Show()
	if self.tooltipFill then
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		self.tooltipFill(self)
		GameTooltip:Show()
	end
end

function StatCardMixin:OnLeave()
	self.hover:Hide()
	Widgets.HideTooltip()
end

Widgets.CARD_HEIGHT = 70

local CARD_PADDING = 12
local CARD_ICON_SIZE = 32

--- A metric tile: icon, small uppercase label, big value and a dim detail line, with the
--- text block centred beside the icon.
---@return table card
function Widgets.StatCard(parent)
	local card = Mixin(CreateFrame("Button", nil, parent), StatCardMixin)
	card:SetHeight(Widgets.CARD_HEIGHT)
	Theme.Fill(card, Theme.COLORS.inset)
	Theme.Border(card)
	card.hover = Theme.Fill(card, Theme.COLORS.hover, "BORDER")
	card.hover:Hide()
	card.icon = Widgets.Icon(card, CARD_ICON_SIZE)
	card.icon:SetPoint("LEFT", CARD_PADDING, 0)
	local textLeft = CARD_PADDING + CARD_ICON_SIZE + CARD_PADDING
	card.value = Widgets.Text(card, "value")
	card.value:SetPoint("LEFT", textLeft, 1)
	card.value:SetPoint("RIGHT", -CARD_PADDING, 1)
	card.label = Widgets.Text(card, "label", "muted")
	card.label:SetPoint("BOTTOMLEFT", card.value, "TOPLEFT", 0, 3)
	card.label:SetPoint("RIGHT", -CARD_PADDING, 0)
	card.sub = Widgets.Text(card, "small", "dim")
	card.sub:SetPoint("TOPLEFT", card.value, "BOTTOMLEFT", 0, -3)
	card.sub:SetPoint("RIGHT", -CARD_PADDING, 0)
	card:SetScript("OnEnter", card.OnEnter)
	card:SetScript("OnLeave", card.OnLeave)
	return card
end

--- Lays cards out in a grid inside parent, width split evenly.
---@param cards table[]
---@param columns integer
---@param top number offset from the parent's top
---@param gap number
function Widgets.LayoutGrid(parent, cards, columns, top, gap)
	local width = (parent:GetWidth() - gap * (columns - 1)) / columns
	for index, card in ipairs(cards) do
		local column = (index - 1) % columns
		local row = math.floor((index - 1) / columns)
		card:ClearAllPoints()
		card:SetWidth(width)
		card:SetPoint("TOPLEFT", parent, "TOPLEFT", column * (width + gap), -(top + row * (card:GetHeight() + gap)))
	end
end

-- Scrolling ------------------------------------------------------------------------------

local ScrollBarMixin = {}

--- Recomputes the thumb from the scroll position.
function ScrollBarMixin:Update()
	local source = self.source
	if not source.IsScrollable() then
		self:Hide()
		return
	end
	self:Show()
	local height = self:GetHeight()
	local thumbHeight = math.max(24, height * source.VisibleFraction())
	self.thumb:SetHeight(thumbHeight)
	self.thumb:ClearAllPoints()
	self.thumb:SetPoint("TOP", self, "TOP", 0, -(height - thumbHeight) * source.Percentage())
end

function ScrollBarMixin:OnUpdate()
	-- Only runs while the thumb is being dragged.
	local _, cursorY = GetCursorPosition()
	cursorY = cursorY / self:GetEffectiveScale()
	local travel = self:GetHeight() - self.thumb:GetHeight()
	if travel > 0 then
		local offset = self.dragStart.thumbTop - (cursorY - self.dragStart.cursorY)
		self.source.SetPercentage(math.min(1, math.max(0, offset / travel)))
	end
end

---@class SeshScrollSource
---@field IsScrollable fun(): boolean
---@field VisibleFraction fun(): number
---@field Percentage fun(): number
---@field SetPercentage fun(percentage: number)

--- A 4-pixel scrollbar strip in the EllesmereUI style, driven by a scroll source.
---@param source SeshScrollSource
---@return table bar
function Widgets.ScrollBar(parent, source)
	local bar = Mixin(CreateFrame("Frame", nil, parent), ScrollBarMixin)
	bar:SetWidth(4)
	bar.source = source
	Theme.Fill(bar, Theme.COLORS.track)
	bar.thumb = CreateFrame("Frame", nil, bar)
	bar.thumb:SetWidth(4)
	bar.thumbFill = Theme.Fill(bar.thumb, { 1, 1, 1, 0.27 }, "ARTWORK")
	bar.thumb:EnableMouse(true)
	bar.thumb:SetScript("OnEnter", function()
		bar.thumbFill:SetColorTexture(1, 1, 1, 0.45)
	end)
	bar.thumb:SetScript("OnLeave", function()
		bar.thumbFill:SetColorTexture(1, 1, 1, 0.27)
	end)
	bar.thumb:SetScript("OnMouseDown", function()
		local _, cursorY = GetCursorPosition()
		local thumbTop = (bar:GetTop() - bar.thumb:GetTop())
		bar.dragStart = { cursorY = cursorY / bar:GetEffectiveScale(), thumbTop = thumbTop }
		bar:SetScript("OnUpdate", bar.OnUpdate)
	end)
	bar.thumb:SetScript("OnMouseUp", function()
		bar:SetScript("OnUpdate", nil)
	end)
	bar:Hide()
	return bar
end

local ScrollListMixin = {}

--- Replaces the rows. keepPosition keeps the scroll offset (for live refreshes).
---@param rows table[]
---@param keepPosition boolean?
function ScrollListMixin:SetRows(rows, keepPosition)
	self.rows = rows
	self.scrollBox:SetDataProvider(
		CreateDataProvider(rows),
		keepPosition and ScrollBoxConstants.RetainScrollPosition or ScrollBoxConstants.DiscardScrollPosition
	)
	self.empty:SetShown(#rows == 0)
	self.bar:Update()
end

--- Re-binds the visible rows (e.g. after item names finished loading).
function ScrollListMixin:Refresh()
	self.scrollBox:ForEachFrame(function(row, data)
		self.bindRow(row, data)
	end)
end

function ScrollListMixin:SetEmptyText(text)
	self.empty:SetText(text)
end

--- A virtualized list: Blizzard's ScrollBox recycles a handful of row frames however
--- many rows there are.
---@param rowHeight number
---@param buildRow fun(row: table) creates a row's regions once
---@param bindRow fun(row: table, data: table) fills a row for one element
---@return table list
function Widgets.ScrollList(parent, rowHeight, buildRow, bindRow)
	local list = Mixin(CreateFrame("Frame", nil, parent), ScrollListMixin)
	list.bindRow = bindRow
	local scrollBox = CreateFrame("Frame", nil, list, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT")
	scrollBox:SetPoint("BOTTOMRIGHT", -10, 0)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(rowHeight)
	view:SetElementInitializer("Button", function(row, data)
		if not row.built then
			row:SetHeight(rowHeight)
			buildRow(row)
			row.built = true
		end
		bindRow(row, data)
	end)
	scrollBox:Init(view)
	list.scrollBox = scrollBox

	local percentage = 0
	list.bar = Widgets.ScrollBar(list, {
		IsScrollable = function()
			return scrollBox:HasScrollableExtent()
		end,
		VisibleFraction = function()
			return scrollBox:GetVisibleExtentPercentage()
		end,
		Percentage = function()
			return percentage
		end,
		SetPercentage = function(value)
			scrollBox:SetScrollPercentage(value)
		end,
	})
	list.bar:SetPoint("TOPRIGHT", 0, 0)
	list.bar:SetPoint("BOTTOMRIGHT", 0, 0)
	scrollBox:RegisterCallback(BaseScrollBoxEvents.OnScroll, function(_, scrollPercentage)
		percentage = scrollPercentage
		list.bar:Update()
	end, list)
	scrollBox:RegisterCallback(BaseScrollBoxEvents.OnLayout, function()
		list.bar:Update()
	end, list)

	list.empty = Widgets.Text(list, "body", "faint")
	list.empty:SetPoint("TOP", 0, -24)
	list.empty:SetJustifyH("CENTER")
	list.empty:Hide()
	return list
end

--- Shared row chrome: zebra background and hover highlight. Call from buildRow.
function Widgets.PrepareRow(row)
	row.background = row:CreateTexture(nil, "BACKGROUND")
	row.background:SetAllPoints()
	row.highlight = row:CreateTexture(nil, "BORDER")
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(unpack(Theme.COLORS.hover))
	row.highlight:Hide()
end

--- Zebra striping by element position. Call from bindRow.
function Widgets.StripeRow(row, index)
	local color = (index % 2 == 0) and Theme.COLORS.rowEven or Theme.COLORS.rowOdd
	row.background:SetColorTexture(unpack(color))
end

--- A scroll frame for free-form content taller than its window area.
--- Returns the scroll frame and the content frame to build into.
---@return table scrollFrame
---@return table content
function Widgets.ScrollArea(parent)
	local scrollFrame = CreateFrame("ScrollFrame", nil, parent)
	local content = CreateFrame("Frame", nil, scrollFrame)
	content:SetSize(1, 1)
	scrollFrame:SetScrollChild(content)
	scrollFrame:EnableMouseWheel(true)

	local bar = Widgets.ScrollBar(parent, {
		IsScrollable = function()
			return scrollFrame:GetVerticalScrollRange() > 0
		end,
		VisibleFraction = function()
			local height = scrollFrame:GetHeight()
			return height / math.max(height, height + scrollFrame:GetVerticalScrollRange())
		end,
		Percentage = function()
			local range = scrollFrame:GetVerticalScrollRange()
			return range > 0 and scrollFrame:GetVerticalScroll() / range or 0
		end,
		SetPercentage = function(value)
			scrollFrame:SetVerticalScroll(value * scrollFrame:GetVerticalScrollRange())
		end,
	})
	bar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 6, 0)
	bar:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 6, 0)
	scrollFrame:SetScript("OnMouseWheel", function(self, delta)
		local target = self:GetVerticalScroll() - delta * 40
		self:SetVerticalScroll(math.min(self:GetVerticalScrollRange(), math.max(0, target)))
	end)
	scrollFrame:SetScript("OnVerticalScroll", function()
		bar:Update()
	end)
	scrollFrame:SetScript("OnScrollRangeChanged", function()
		bar:Update()
	end)
	scrollFrame:SetScript("OnSizeChanged", function(_, width)
		content:SetWidth(width)
		bar:Update()
	end)
	return scrollFrame, content
end
