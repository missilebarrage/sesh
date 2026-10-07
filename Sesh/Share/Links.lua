local _, ns = ...

--- Sharing sessions and levels in chat.
---
--- The sender's message is plain text, e.g. "[Sesh #42] Current Session: 10g earned" or
--- "[Sesh Lv23] Level 23 (2h 41m): 212 kills". Every Sesh user's chat filter turns the
--- "[Sesh #42]" and "[Sesh Lv23]" tokens into local addon links that remember who sent
--- them; clicking one opens the session or level (requested over Comm when it belongs
--- to someone else). Players without Sesh just see the text.
---@class SeshLinks
local Links = ns.Links
local Database = ns.Database
local Session = ns.Session
local Shares = ns.Shares
local Format = ns.Format
local Names = ns.Names
local Theme = ns.Theme
local L = ns.L

local TOKEN = "[Sesh "
local SESSION_TOKEN_PATTERN = "%[Sesh #(%d%d?%d?%d?%d?%d?%d?)%]"
local LEVEL_TOKEN_PATTERN = "%[Sesh Lv(%d%d?%d?)%]"
local LINK_PATTERN = "^addon:Sesh:([^:|]+):(L?)(%d+)$"
local MAX_CHAT_BYTES = 255
local MAX_LINKS_PER_MESSAGE = 3
local SEPARATOR = " · "

-- Chat types whose messages may carry shared links. Battle.net and community channels
-- are left alone: their senders can't receive addon whispers.
local FILTER_EVENTS = {
	"CHAT_MSG_SAY",
	"CHAT_MSG_YELL",
	"CHAT_MSG_PARTY",
	"CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID",
	"CHAT_MSG_RAID_LEADER",
	"CHAT_MSG_INSTANCE_CHAT",
	"CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_GUILD",
	"CHAT_MSG_OFFICER",
	"CHAT_MSG_WHISPER",
	"CHAT_MSG_WHISPER_INFORM",
	"CHAT_MSG_CHANNEL",
}

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

--- The chat token for a view: "[Sesh #42]" for a session, "[Sesh Lv23]" for a level.
---@param view SeshView
---@return string
function Links.Token(view)
	if view.level then
		return TOKEN .. "Lv" .. view.level .. "]"
	end
	return TOKEN .. "#" .. view.id .. "]"
end

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
---@param view SeshView a session (it needs an id) or a level
---@param fields table<string, boolean> which metrics to include
---@return string text
---@return integer dropped how many metrics didn't fit
function Links.ChatText(view, fields, now, excludeAfk)
	local metrics = Session.Metrics(view, now, excludeAfk)
	local head = Links.Token(view) .. " " .. Label(view, metrics, fields) .. ":"
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

--- Shares a session or level: allows others to open it and writes the message into chat.
---@param view SeshView
---@param fields table<string, boolean>
---@return string text
---@return integer dropped
function Links.Share(view, fields)
	local now = GetServerTime()
	local text, dropped = Links.ChatText(view, fields, now, Database.Get("excludeAfk"))
	if view.level then
		Shares.Mark("level", view.level, now)
	else
		Shares.Mark("session", view.id, now)
	end
	Links.Insert(text)
	return text, dropped
end

--- The clickable link inserted in place of a "[Sesh #id]" token.
---@param owner string
---@param id string|integer
---@return string
function Links.MakeLink(owner, id)
	return "|cff" .. Theme.AccentHex() .. "|Haddon:Sesh:" .. owner .. ":" .. id .. "|h[Sesh #" .. id .. "]|h|r"
end

--- The clickable link inserted in place of a "[Sesh Lv23]" token.
---@param owner string
---@param level string|integer
---@return string
function Links.MakeLevelLink(owner, level)
	return "|cff" .. Theme.AccentHex() .. "|Haddon:Sesh:" .. owner .. ":L" .. level .. "|h[Sesh Lv" .. level .. "]|h|r"
end

local function Filter(_, event, message, author, ...)
	if type(message) ~= "string" or not message:find(TOKEN, 1, true) then
		return false
	end
	-- The sender's name exactly as chat has it: it's also the address to ask for the share.
	local owner = event == "CHAT_MSG_WHISPER_INFORM" and Names.PlayerFullName() or ns.Str(author)
	if not owner or owner == "" or owner:find("[:|]") then
		return false
	end
	local converted, sessions = message:gsub(SESSION_TOKEN_PATTERN, function(id)
		return Links.MakeLink(owner, id)
	end, MAX_LINKS_PER_MESSAGE)
	if sessions < MAX_LINKS_PER_MESSAGE then
		converted = converted:gsub(LEVEL_TOKEN_PATTERN, function(level)
			return Links.MakeLevelLink(owner, level)
		end, MAX_LINKS_PER_MESSAGE - sessions)
	end
	return false, converted, author, ...
end

local function OnLinkClicked(_, link)
	link = ns.Str(link)
	if not link then
		return
	end
	local owner, levelMark, id = link:match(LINK_PATTERN)
	if not owner then
		return
	end
	id = tonumber(id)
	local kind = levelMark == "L" and "level" or "session"
	if not Names.IsPlayer(owner) then
		ns.SharedSessionWindow.Open(owner, kind, id)
	elseif kind == "level" then
		ns.MainWindow.OpenLevel(id)
	else
		ns.MainWindow.OpenSession(id)
	end
end

--- Installs the chat filters and the link click handler. Called at PLAYER_LOGIN.
function Links.Init()
	for _, event in ipairs(FILTER_EVENTS) do
		ChatFrameUtil.AddMessageEventFilter(event, Filter)
	end
	EventRegistry:RegisterCallback("SetItemRef", OnLinkClicked, Links)
end
