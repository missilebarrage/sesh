local _, ns = ...

--- Choose which metrics go into the chat line for a session or a level, preview it, then
--- insert it into chat. Choices are remembered separately for sessions and levels.
---@class SeshShareDialog
local ShareDialog = ns.ShareDialog
local Database = ns.Database
local Links = ns.Links
local Theme = ns.Theme
local Widgets = ns.Widgets
local Window = ns.Window
local L = ns.L

local WIDTH, HEIGHT = 420, 430
local ROW_HEIGHT = 22
local PREVIEW_HEIGHT = 58

local frame ---@type table?
local current ---@type {view: SeshView, live: boolean}?

local function SettingKey()
	return current.view.level and "levelShareFields" or "shareFields"
end

local function Fields()
	return Database.Get(SettingKey())
end

-- Lays out the checkboxes of the metrics that apply, two per row.
local function LayoutCheckboxes()
	local applies = {}
	for _, field in ipairs(current.view.level and Links.LEVEL_FIELDS or Links.FIELDS) do
		applies[field] = true
	end
	local position = 0
	for _, field in ipairs(Links.FIELDS) do
		local checkbox = frame.checkboxes[field]
		checkbox:SetShown(applies[field] == true)
		if applies[field] then
			local column = position % 2
			local row = math.floor(position / 2)
			checkbox:ClearAllPoints()
			checkbox:SetPoint("TOPLEFT", column * frame.columnWidth, -(frame.checkboxTop + row * ROW_HEIGHT))
			position = position + 1
		end
	end
end

local function ShowCopyBox(shown)
	frame.preview:SetShown(not shown)
	frame.copyBox:SetShown(shown)
	if shown then
		frame.copyBox:SetFocus()
		frame.copyBox:HighlightText()
	else
		frame.copyBox:ClearFocus()
	end
end

local function UpdatePreview()
	local text, dropped = Links.ChatText(current.view, Fields(), GetServerTime(), Database.Get("excludeAfk"))
	frame.preview:SetText(text)
	frame.copyBox:SetText(text)
	frame.counter:SetText(L.SHARE_BYTES:format(#text))
	frame.dropped:SetText(dropped > 0 and L.SHARE_DROPPED:format(dropped) or "")
end

local function Build()
	frame = Window.New("SeshShareDialog", "share", WIDTH, HEIGHT)
	frame:SetFrameStrata("DIALOG")
	local content = frame.content
	local width = content:GetWidth()
	local y = 0

	local metrics = Widgets.SectionHeader(content, L.SHARE_METRICS)
	metrics:SetPoint("TOPLEFT", 0, -y)
	metrics:SetWidth(width)
	y = y + 30
	frame.checkboxes = {}
	frame.checkboxTop = y
	frame.columnWidth = width / 2
	for _, field in ipairs(Links.FIELDS) do
		frame.checkboxes[field] = Widgets.Checkbox(content, L["FIELD_" .. field:upper()], function(checked)
			local fields = Fields()
			fields[field] = checked or nil
			Database.Set(SettingKey(), fields)
			UpdatePreview()
		end)
	end
	y = y + math.ceil(#Links.FIELDS / 2) * ROW_HEIGHT + 8

	local preview = Widgets.SectionHeader(content, L.SHARE_PREVIEW)
	preview:SetPoint("TOPLEFT", 0, -y)
	preview:SetWidth(width)
	y = y + 28
	local box = CreateFrame("Frame", nil, content)
	box:SetPoint("TOPLEFT", 0, -y)
	box:SetSize(width, PREVIEW_HEIGHT)
	Theme.Fill(box, Theme.COLORS.inset)
	Theme.Border(box)
	frame.preview = Widgets.Text(box, "body")
	frame.preview:SetPoint("TOPLEFT", 8, -6)
	frame.preview:SetPoint("BOTTOMRIGHT", -8, 6)
	frame.preview:SetWordWrap(true)
	frame.preview:SetJustifyV("TOP")

	-- The same text, selectable for copying. It takes the preview's place while shown.
	frame.copyBox = CreateFrame("EditBox", nil, box)
	frame.copyBox:SetFontObject(Theme.Font("body"))
	frame.copyBox:SetMultiLine(true)
	frame.copyBox:SetAutoFocus(false)
	frame.copyBox:SetPoint("TOPLEFT", 8, -6)
	frame.copyBox:SetSize(width - 16, PREVIEW_HEIGHT - 12)
	frame.copyBox:SetScript("OnEscapePressed", function()
		ShowCopyBox(false)
	end)
	frame.copyBox:SetScript("OnEditFocusLost", function()
		ShowCopyBox(false)
	end)
	frame.copyBox:SetScript("OnTextChanged", function(_, userInput)
		-- Read-only: typing restores the generated text.
		if userInput then
			UpdatePreview()
		end
	end)
	frame.copyBox:Hide()
	y = y + PREVIEW_HEIGHT + 4

	frame.dropped = Widgets.Text(content, "small", "dim")
	frame.dropped:SetPoint("TOPLEFT", 0, -y)
	frame.counter = Widgets.Text(content, "small", "faint")
	frame.counter:SetPoint("TOPRIGHT", 0, -y)
	y = y + 20

	frame.note = Widgets.Text(content, "small", "faint")
	frame.note:SetPoint("TOPLEFT", 0, -y)
	frame.note:SetWidth(width)
	frame.note:SetText(L.SHARE_NOTE)

	frame.insert = Widgets.Button(content, L.SHARE_INSERT, function()
		Links.Share(current.view, Fields())
		frame:Hide()
	end, { primary = true, height = 24 })
	frame.insert:SetPoint("BOTTOMRIGHT")
	frame.copy = Widgets.Button(content, L.SHARE_COPY, function()
		ShowCopyBox(true)
	end, { height = 24, tooltip = L.SHARE_COPY_TOOLTIP })
	frame.copy:SetPoint("RIGHT", frame.insert, "LEFT", -6, 0)
end

--- Opens the dialog for a session or a level, live or finished.
---@param view SeshView
---@param live boolean?
function ShareDialog.Open(view, live)
	if not frame then
		Build()
	end
	current = { view = view, live = live == true }
	frame.title:SetText(view.level and L.SHARE_LEVEL_TITLE or L.SHARE_TITLE)
	LayoutCheckboxes()
	local fields = Fields()
	for field, checkbox in pairs(frame.checkboxes) do
		checkbox:SetValue(fields[field] == true)
	end
	UpdatePreview()
	ShowCopyBox(false)
	frame:Show()
end
