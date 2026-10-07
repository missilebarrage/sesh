local _, ns = ...

--- A session or level another player shared: requested over addon whispers when its chat
--- link is clicked, then shown read-only with the same view as your own.
---@class SeshSharedSessionWindow
local SharedSessionWindow = ns.SharedSessionWindow
local Comm = ns.Comm
local Format = ns.Format
local Theme = ns.Theme
local Widgets = ns.Widgets
local Window = ns.Window
local SessionView = ns.SessionView
local Names = ns.Names
local L = ns.L

local WIDTH, HEIGHT = 680, 540
local TOOLBAR_HEIGHT = 30

local frame ---@type table?
local received = {} ---@type table<string, SeshView> views already fetched this play session
local currentKey ---@type string?

local function ShowStatus(text)
	frame.status:SetText(text)
	frame.status:Show()
	frame.view:Hide()
	frame.info:SetText("")
end

-- "Level 23 · Oct 4 – Oct 5", or "Level 31 · in progress, 62% (as of 2:04 PM)".
local function LevelInfo(view)
	local title = L.LEVEL_N:format(view.level)
	if view.live then
		local progress = view.progress and L.LEVEL_IN_PROGRESS_PERCENT:format(view.progress) or L.IN_PROGRESS
		return title .. "  ·  " .. L.SHARED_AS_OF:format(progress, Format.Time(view.endedAt))
	end
	return title .. "  ·  " .. Format.DateRange(view.startedAt, view.endedAt)
end

local function ShowView(view)
	frame.status:Hide()
	frame.view:Show()
	if view.level then
		frame.info:SetText(LevelInfo(view))
	else
		local started = Format.DateLong(view.startedAt) .. ", " .. Format.Time(view.startedAt)
		frame.info:SetText(
			view.live and L.SHARED_LIVE:format(started, Format.Time(view.endedAt))
				or (started .. " – " .. Format.Time(view.endedAt))
		)
	end
	frame.view:SetView(view, { now = view.endedAt })
end

local function Build()
	frame = Window.New("SeshSharedSessionWindow", "shared", WIDTH, HEIGHT)
	frame.title:SetText(L.ADDON_TITLE)
	frame.info = Widgets.Text(frame.content, "heading")
	frame.info:SetPoint("TOPLEFT", 0, -4)
	local body = CreateFrame("Frame", nil, frame.content)
	body:SetPoint("TOPLEFT", 0, -TOOLBAR_HEIGHT)
	body:SetSize(frame.content:GetWidth(), frame.content:GetHeight() - TOOLBAR_HEIGHT)
	frame.view = SessionView.New(body)
	frame.status = Widgets.Text(body, "body", "dim")
	frame.status:SetPoint("TOP", 0, -60)
	frame.status:SetWidth(body:GetWidth() - 40)
	frame.status:SetWordWrap(true)
	frame.status:SetJustifyH("CENTER")
	Theme.Tone(frame.status, "dim")
end

--- Opens (and if necessary requests) a session or level someone shared.
---@param owner string "Name-Realm"
---@param kind SeshShareKind
---@param id integer session id or level
function SharedSessionWindow.Open(owner, kind, id)
	if not frame then
		Build()
	end
	local key = owner .. ":" .. kind .. ":" .. id
	currentKey = key
	frame.subtitle:SetText(L.SHARED_BY:format(Names.WithoutRealm(owner)))
	frame:Show()
	if received[key] then
		ShowView(received[key])
		return
	end
	ShowStatus(L.SHARE_REQUESTING)
	Comm.Request(owner, kind, id, {
		OnProgress = function(count, total)
			if currentKey == key then
				ShowStatus(L.SHARE_RECEIVING:format(count, total))
			end
		end,
		OnComplete = function(view)
			received[key] = view
			if currentKey == key then
				ShowView(view)
			end
		end,
		OnError = function(reason)
			if currentKey == key then
				ShowStatus(L["SHARE_ERROR_" .. reason]:format(Names.WithoutRealm(owner)))
			end
		end,
	})
end
