local _, ns = ...

--- The window shell shared by Sesh's windows: flat panel, hairline border, a darker header
--- strip with the accent-coloured title, drag-to-move with a remembered position,
--- Escape to close and the user's window scale.
---@class SeshWindow
local Window = ns.Window
local Theme = ns.Theme
local Widgets = ns.Widgets
local Database = ns.Database
local Events = ns.Events

Window.HEADER_HEIGHT = 30
Window.PADDING = 14

local windows = {}

---@param name string global frame name (needed for Escape-to-close)
---@param positionKey string key for the saved position
---@param width number
---@param height number
---@return table frame with .header, .title, .subtitle, .content and .close
function Window.New(name, positionKey, width, height)
	local frame = CreateFrame("Frame", name, UIParent)
	frame:SetSize(width, height)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	-- Sesh remembers positions itself; keep the client's layout cache out of it.
	frame:SetDontSavePosition(true)
	frame:SetScale(Database.Get("windowScale"))
	Theme.Fill(frame, Theme.COLORS.panel)
	Theme.Border(frame)

	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT")
	header:SetPoint("TOPRIGHT")
	header:SetHeight(Window.HEADER_HEIGHT)
	Theme.Fill(header, Theme.COLORS.header)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function()
		frame:StartMoving()
	end)
	header:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		Database.SavePosition(positionKey, frame)
	end)
	frame.header = header

	frame.title = Widgets.Text(header, "title")
	frame.title:SetPoint("LEFT", 12, 0)
	Theme.PaintAccent(frame.title, 1, "text")
	frame.subtitle = Widgets.Text(header, "small", "dim")
	frame.subtitle:SetPoint("LEFT", frame.title, "RIGHT", 10, 0)

	frame.close = Widgets.GlyphButton(header, "close", nil, function()
		frame:Hide()
	end)
	frame.close:SetPoint("RIGHT", -6, 0)

	frame.content = CreateFrame("Frame", nil, frame)
	frame.content:SetPoint("TOPLEFT", Window.PADDING, -(Window.HEADER_HEIGHT + 8))
	frame.content:SetPoint("BOTTOMRIGHT", -Window.PADDING, Window.PADDING)
	frame.content:SetSize(width - 2 * Window.PADDING, height - Window.HEADER_HEIGHT - 8 - Window.PADDING)

	UISpecialFrames[#UISpecialFrames + 1] = name
	if not Database.RestorePosition(positionKey, frame) then
		frame:SetPoint("CENTER")
	end
	frame:Hide()
	windows[#windows + 1] = frame
	return frame
end

Events.On("SESH_SETTINGS_CHANGED", function(key, value)
	if key == "windowScale" then
		for _, frame in ipairs(windows) do
			frame:SetScale(value)
		end
		Theme.RefreshPixels()
	end
end)
