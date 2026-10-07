local _, ns = ...

--- The data sent when another player opens a shared session or level: a compact table
--- built from a view, and strict validation of tables received from other players.
--- Anything received is untrusted: every number is bounds-checked and every string
--- sanitized.
---@class SeshPayload
local Payload = ns.Payload
local Session = ns.Session
local Pack = ns.Pack

Payload.VERSION = 2

local LIST_LIMITS =
	{ items = 50, consumed = 30, monsters = 30, quests = 30, zones = 20, dungeons = 20, achievements = 20 }
local TEXT_BYTES = 40
-- How long the time span of a session, or of a level, can be.
local MAX_SPAN = { session = 7 * 86400, level = 5 * 365 * 86400 }
local EARLIEST = 1500000000

local floor = math.floor
local min = math.min

local function Take(list, limit, fromEnd)
	local result = {}
	local count = min(#list, limit)
	local offset = fromEnd and (#list - count) or 0
	for index = 1, count do
		result[index] = list[offset + index]
	end
	return result
end

--- Builds the table to send for a view: a session (live or finished) or a level.
---@param view SeshView
---@param now integer
---@return table
function Payload.Build(view, now)
	local isLevel = view.level ~= nil
	local data = {
		v = Payload.VERSION,
		kind = isLevel and "level" or "session",
		id = isLevel and view.level or view.id,
		startedAt = view.startedAt,
		endedAt = view.endedAt or now,
		live = view.kind == "live" or view.live == true,
		duration = floor(Session.Duration(view, now)),
		afkSeconds = floor(Session.AfkSeconds(view, now)),
		sessionCount = view.sessionCount or 1,
		startLevel = view.startLevel or 0,
		endLevel = view.endLevel or 0,
		completed = view.completed == true,
		fromPercent = view.fromPercent or 0,
		progress = view.progress or 0,
		xpMax = view.xpMax or 0,
		xp = view.xp,
		money = view.money,
		itemValue = view.itemValue,
		kills = view.kills,
		unidentifiedKills = view.unidentifiedKills,
		deaths = view.deaths,
		legacy = view.legacy,
		questCount = view.questCount,
		dungeonCount = view.dungeonCount,
		items = {},
		consumed = {},
		monsters = {},
		quests = {},
		zones = {},
		dungeons = {},
		achievements = {},
	}
	for index, item in ipairs(Take(view.items, LIST_LIMITS.items)) do
		data.items[index] = { item.itemID, item.count, item.unitValue }
	end
	for index, item in ipairs(Take(view.consumed or {}, LIST_LIMITS.consumed)) do
		data.consumed[index] = { item.itemID, item.count, item.unitValue }
	end
	for index, monster in ipairs(Take(view.monsters, LIST_LIMITS.monsters)) do
		data.monsters[index] = { monster.name, monster.count, monster.npcID or 0, monster.typeID or 0 }
	end
	-- The most recent quests and dungeon runs.
	for index, quest in ipairs(Take(view.quests, LIST_LIMITS.quests, true)) do
		data.quests[index] = { quest.questID, quest.xp, quest.money, quest.title or "" }
	end
	for index, run in ipairs(Take(view.dungeons, LIST_LIMITS.dungeons, true)) do
		data.dungeons[index] = { run.name, run.startedAt, run.seconds, run.bosses }
	end
	for index, zone in ipairs(Take(view.zones, LIST_LIMITS.zones)) do
		data.zones[index] = { zone.name, zone.kind, zone.seconds }
	end
	for index, achievement in ipairs(Take(view.achievements, LIST_LIMITS.achievements)) do
		data.achievements[index] = achievement.achievementID
	end
	return data
end

-- Validation ------------------------------------------------------------------------

local Invalid = {} -- unique error marker

local function Int(value, minimum, maximum)
	if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < minimum or value > maximum then
		error(Invalid)
	end
	return value
end

local function Bool(value)
	if type(value) ~= "boolean" then
		error(Invalid)
	end
	return value
end

local function Text(value, allowEmpty)
	if type(value) ~= "string" then
		error(Invalid)
	end
	local cleaned = Pack.CleanText(value, TEXT_BYTES)
	if cleaned == "" and not allowEmpty then
		error(Invalid)
	end
	return cleaned
end

local function List(value, limit)
	if type(value) ~= "table" or #value > limit then
		error(Invalid)
	end
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key > #value or key % 1 ~= 0 then
			error(Invalid)
		end
	end
	return value
end

local function Row(value, fields)
	if type(value) ~= "table" or #value ~= fields then
		error(Invalid)
	end
	return value
end

local function Optional(value)
	return value ~= 0 and value or nil
end

local function ByValue(a, b)
	return a.value > b.value
end

local function ReadItems(rows, limit)
	local items, count = {}, 0
	for index, row in ipairs(List(rows, limit)) do
		Row(row, 3)
		local itemCount, unitValue = Int(row[2], 1, 1e7), Int(row[3], 0, 1e10)
		items[index] =
			{ itemID = Int(row[1], 1, 1e7), count = itemCount, unitValue = unitValue, value = itemCount * unitValue }
		count = count + itemCount
	end
	table.sort(items, ByValue)
	return items, count
end

local function ReadLists(data, view, endedAt)
	local span = endedAt - view.startedAt
	view.items, view.itemCount = ReadItems(data.items, LIST_LIMITS.items)
	-- Shares from before items could be used up don't have the list.
	view.consumed = ReadItems(data.consumed or {}, LIST_LIMITS.consumed)
	for index, row in ipairs(List(data.monsters, LIST_LIMITS.monsters)) do
		Row(row, 4)
		view.monsters[index] = {
			name = Text(row[1]),
			count = Int(row[2], 1, 1e7),
			npcID = Optional(Int(row[3], 0, 1e7)),
			typeID = Optional(Int(row[4], 0, 100)),
		}
	end
	for index, row in ipairs(List(data.quests, LIST_LIMITS.quests)) do
		Row(row, 4)
		local title = Text(row[4], true)
		view.quests[index] = {
			questID = Int(row[1], 1, 1e7),
			xp = Int(row[2], 0, 1e8),
			money = Int(row[3], 0, 1e10),
			title = title ~= "" and title or nil,
		}
	end
	for index, row in ipairs(List(data.dungeons, LIST_LIMITS.dungeons)) do
		Row(row, 4)
		-- A run can begin before the level it ends in.
		view.dungeons[index] = {
			name = Text(row[1]),
			startedAt = Int(row[2], EARLIEST, endedAt),
			seconds = Int(row[3], 0, MAX_SPAN.session),
			bosses = Int(row[4], 0, 100),
		}
	end
	for index, row in ipairs(List(data.zones, LIST_LIMITS.zones)) do
		Row(row, 3)
		view.zones[index] = {
			name = Text(row[1]),
			kind = Int(row[2], 0, Session.ZONE_OTHER),
			seconds = Int(row[3], 0, span),
		}
	end
	for index, achievementID in ipairs(List(data.achievements, LIST_LIMITS.achievements)) do
		view.achievements[index] = { achievementID = Int(achievementID, 1, 1e7) }
	end
end

local function ReadView(data, now)
	if type(data) ~= "table" or data.v ~= Payload.VERSION then
		error(Invalid)
	end
	local kind = data.kind
	if kind ~= "session" and kind ~= "level" then
		error(Invalid)
	end
	local startedAt = Int(data.startedAt, EARLIEST, now + 86400)
	local endedAt = Int(data.endedAt, startedAt, startedAt + MAX_SPAN[kind])
	local duration = Int(data.duration, 0, endedAt - startedAt)
	local view = {
		kind = "shared",
		live = Bool(data.live),
		startedAt = startedAt,
		endedAt = endedAt,
		afkSeconds = Int(data.afkSeconds, 0, duration),
		missed = 0,
		xp = Int(data.xp, 0, 1e10),
		money = Int(data.money, 0, 1e12),
		-- Negative when items worth more than what they turned into were used up.
		itemValue = Int(data.itemValue, -1e13, 1e13),
		kills = Int(data.kills, 0, 1e7),
		unidentifiedKills = Int(data.unidentifiedKills, 0, 1e7),
		deaths = Int(data.deaths, 0, 1e6),
		legacy = Int(data.legacy, 0, 1e6),
		questCount = Int(data.questCount, 0, 1e6),
		dungeonCount = Int(data.dungeonCount, 0, 1e5),
		monsters = {},
		quests = {},
		zones = {},
		dungeons = {},
		achievements = {},
	}
	if kind == "level" then
		-- A level's time is the time played at it, which its span from first to last play
		-- only bounds.
		view.level = Int(data.id, 1, 255)
		view.duration = duration
		view.sessionCount = Int(data.sessionCount, 0, 1e5)
		view.levels = 0
		view.completed = Bool(data.completed)
		view.fromPercent = Optional(Int(data.fromPercent, 0, 99))
		view.progress = view.live and Int(data.progress, 0, 99) or nil
		view.xpMax = Optional(Int(data.xpMax, 0, 1e9))
	else
		local startLevel = Int(data.startLevel, 0, 255)
		local endLevel = Int(data.endLevel, startLevel, 255)
		view.id = Int(data.id, 1, 1e9)
		view.sessionCount = 1
		view.startLevel = startLevel > 0 and startLevel or nil
		view.endLevel = endLevel > 0 and endLevel or nil
		view.levels = startLevel > 0 and (endLevel - startLevel) or 0
	end
	ReadLists(data, view, endedAt)
	return view
end

--- Validates a table received from another player and turns it into a view.
---@param data any
---@param now integer
---@return SeshView? view nil when anything is malformed or out of bounds
function Payload.Read(data, now)
	local ok, view = pcall(ReadView, data, now)
	if ok then
		return view
	end
	if view ~= Invalid then
		-- Unexpected errors are bugs; surface them without trusting the payload.
		geterrorhandler()(view)
	end
	return nil
end
