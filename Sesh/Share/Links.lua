local _, ns = ...

--- Chat text for sharing sessions and levels, and the level links in Sesh's own messages.
---
--- Shared messages are plain text, e.g. "Current Session (2h 41m): 10g earned (4g/hour)" or
--- "Level 23 (2h 41m): 212 kills". Links only appear in what Sesh prints for the player,
--- like the level-up summary, and open the level in Sesh.
---@class SeshLinks
local Links = ns.Links
local Database = ns.Database
local Session = ns.Session
local Format = ns.Format
local Names = ns.Names
local Theme = ns.Theme
local L = ns.L

local LINK_PATTERN = "^addon:Sesh:([^:|]+):L(%d+)$"
local MAX_CHAT_BYTES = 255
local SEPARATOR = " · "

--- Metrics a player can include in the chat text for a session, in display order.
Links.FIELDS = {
	"duration",
	"goldEarned",
	"goldPerHour",
	"rawGold",
	"itemValue",
	"xp",
	"xpPerHour",
	"levels",
	"kills",
	"quests",
	"dungeons",
	"deaths",
	"items",
	"zones",
	"achievements",
	"legacy",
}

--- The same for a level (a level doesn't gain levels).
Links.LEVEL_FIELDS = {}
for _, field in ipairs(Links.FIELDS) do
	if field ~= "levels" then
		Links.LEVEL_FIELDS[#Links.LEVEL_FIELDS + 1] = field
	end
end

-- Chat segments. Each one reads its fields and returns its text, or nil to leave it out.
local SEGMENTS = {
	gold = function(m, fields)
		if fields.goldEarned then
			local text = L.CHAT_GOLD_EARNED:format(Format.MoneyText(m.goldEarned))
			if fields.goldPerHour and m.goldPerHour then
				text = text .. " (" .. L.CHAT_PER_HOUR:format(Format.MoneyRough(m.goldPerHour)) .. ")"
			end
			return text
		elseif fields.goldPerHour and m.goldPerHour then
			return L.CHAT_GOLD_PER_HOUR:format(Format.MoneyRough(m.goldPerHour))
		end
	end,
	rawGold = function(m, fields)
		return fields.rawGold and L.CHAT_RAW_GOLD:format(Format.MoneyText(m.money)) or nil
	end,
	itemValue = function(m, fields)
		return fields.itemValue and L.CHAT_ITEM_VALUE:format(Format.MoneyText(m.itemValue)) or nil
	end,
	xp = function(m, fields)
		if fields.xp then
			local text = L.CHAT_XP:format(Format.Integer(m.xp))
			if fields.xpPerHour and m.xpPerHour then
				text = text .. " (" .. L.CHAT_PER_HOUR:format(Format.Compact(m.xpPerHour)) .. ")"
			end
			return text
		elseif fields.xpPerHour and m.xpPerHour then
			return L.CHAT_XP_PER_HOUR:format(Format.Compact(m.xpPerHour))
		end
	end,
	levels = function(m, fields)
		return fields.levels and m.levels > 0 and L.CHAT_LEVELS:format(m.levels) or nil
	end,
	kills = function(m, fields)
		return fields.kills and L.CHAT_KILLS:format(Format.Integer(m.kills)) or nil
	end,
	quests = function(m, fields)
		return fields.quests and L.CHAT_QUESTS:format(m.quests) or nil
	end,
	dungeons = function(m, fields)
		return fields.dungeons and L.CHAT_DUNGEONS:format(m.dungeons) or nil
	end,
	deaths = function(m, fields)
		return fields.deaths and L.CHAT_DEATHS:format(m.deaths) or nil
	end,
	items = function(m, fields)
		return fields.items and L.CHAT_ITEMS:format(Format.Integer(m.items)) or nil
	end,
	zones = function(m, fields)
		return fields.zones and L.CHAT_ZONES:format(m.zones) or nil
	end,
	achievements = function(m, fields)
		return fields.achievements and m.achievements > 0 and L.CHAT_ACHIEVEMENTS:format(m.achievements) or nil
	end,
	legacy = function(m, fields)
		return fields.legacy and m.legacy > 0 and L.CHAT_LEGACY:format(m.legacy) or nil
	end,
}

-- Segment order: what matters most comes first, since segments that don't fit are dropped
-- from the end.
local SESSION_ORDER = {
	"gold",
	"rawGold",
	"itemValue",
	"xp",
	"levels",
	"kills",
	"quests",
	"dungeons",
	"deaths",
	"items",
	"zones",
	"achievements",
	"legacy",
}
local LEVEL_ORDER = {
	"xp",
	"gold",
	"rawGold",
	"itemValue",
	"kills",
	"quests",
	"dungeons",
	"deaths",
	"items",
	"zones",
	"achievements",
	"legacy",
}

local function Label(view, metrics, fields)
	local label
	if view.level then
		if view.live and view.progress then
			label = L.CHAT_LEVEL_PROGRESS:format(view.level, view.progress)
		elseif view.fromPercent then
			-- Say so when Sesh saw only part of the level.
			label = L.CHAT_LEVEL_FROM:format(view.level, view.fromPercent)
		else
			label = L.CHAT_LEVEL:format(view.level)
		end
	else
		label = view.kind == "live" and L.CHAT_CURRENT_SESSION or L.CHAT_SESSION_ON:format(Format.Date(view.startedAt))
	end
	if fields.duration then
		label = label .. " (" .. Format.Duration(metrics.duration) .. ")"
	end
	return label
end

--- Builds the chat message for a session or level. Metrics that would push it past the
--- chat limit are dropped from the end.
---@param view SeshView a session or a level
---@param fields table<string, boolean> which metrics to include
---@return string text
---@return integer dropped how many metrics didn't fit
function Links.ChatText(view, fields, now, excludeAfk)
	local metrics = Session.Metrics(view, now, excludeAfk)
	local head = Label(view, metrics, fields) .. ":"
	local segments = {}
	for _, name in ipairs(view.level and LEVEL_ORDER or SESSION_ORDER) do
		segments[#segments + 1] = SEGMENTS[name](metrics, fields)
	end
	local dropped = 0
	while true do
		local text = #segments > 0 and (head .. " " .. table.concat(segments, SEPARATOR)) or head:sub(1, -2)
		if #text <= MAX_CHAT_BYTES then
			return text, dropped
		end
		table.remove(segments)
		dropped = dropped + 1
	end
end

--- Puts text into the chat input box: appended when the player is typing, otherwise a new
--- box opens. The player picks the channel and presses Enter.
---@param text string
function Links.Insert(text)
	local editBox = ChatFrameUtil.GetActiveWindow()
	if editBox then
		editBox:Insert(text)
	else
		ChatFrameUtil.OpenChat(text)
	end
end

--- Shares a session or level: writes its message into chat.
---@param view SeshView
---@param fields table<string, boolean>
---@return string text
---@return integer dropped
function Links.Share(view, fields)
	local text, dropped = Links.ChatText(view, fields, GetServerTime(), Database.Get("excludeAfk"))
	Links.Insert(text)
	return text, dropped
end

--- A link that opens one of the player's levels, for messages Sesh prints for the player.
--- It names the character, so a link left in chat from another character does nothing.
---@param level integer
---@return string
function Links.MakeLevelLink(level)
	local text = "[" .. L.LEVEL_N:format(level) .. "]"
	return ("|cff%s|Haddon:Sesh:%s:L%d|h%s|h|r"):format(Theme.AccentHex(), Names.PlayerFullName(), level, text)
end

local function OnLinkClicked(_, link)
	link = ns.Str(link)
	if not link then
		return
	end
	local owner, level = link:match(LINK_PATTERN)
	if owner and Names.IsPlayer(owner) then
		ns.MainWindow.OpenLevel(tonumber(level))
	end
end

--- Installs the link click handler. Called at PLAYER_LOGIN.
function Links.Init()
	EventRegistry:RegisterCallback("SetItemRef", OnLinkClicked, Links)
end
