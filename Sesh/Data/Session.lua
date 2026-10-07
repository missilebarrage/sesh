local _, ns = ...

--- The session model.
---
--- * The *active* session is a plain table of counters and maps that trackers update in
---   O(1) (SeshCharDB.active).
--- * A *record* is a finished session: scalar totals plus row lists packed into strings
---   (SeshCharDB.sessions). The lifetime rollup and level records have the same shape.
--- * A *view* is what the UI renders: scalars plus sorted row arrays. Views come from the
---   active session, a record, an aggregate of several, or something shared in chat.
--- * A *mark* remembers the active session's totals at one moment, so the part of the
---   session after it can be told apart (Session.Mark / Session.Since).
---
--- Items that are disenchanted or opened are *used up*: what they turn into is counted like
--- any loot where it happens, and the item's value is taken off there too. Item value is
--- what was acquired minus what was used up, so an item's value is never counted twice,
--- whichever session (or character) uses it up. It can be negative.
---@class SeshSession
local Session = ns.Session
local Pack = ns.Pack
local Pricing = ns.Pricing
local Events = ns.Events

local max = math.max
local floor = math.floor

-- Zone kinds, stored as numbers.
Session.ZONE_WORLD = 0
Session.ZONE_DUNGEON = 1
Session.ZONE_RAID = 2
Session.ZONE_PVP = 3
Session.ZONE_OTHER = 4

-- Rates need at least this much active time to mean anything.
local MIN_RATE_SECONDS = 60
-- Aggregates keep only the most recent quests and dungeon runs as rows; their counts stay exact.
local MAX_AGGREGATE_ROWS = 500
-- A dungeon run counts when a boss died or it lasted at least this long.
local MIN_DUNGEON_SECONDS = 5 * 60

local EMPTY = {}

---@class SeshItemRow
---@field itemID integer
---@field count integer
---@field unitValue integer copper per item
---@field value integer copper for the whole stack

---@class SeshMonsterRow
---@field name string
---@field count integer
---@field npcID integer? 0/nil when unknown
---@field typeID integer? creature type (1 Beast, 7 Humanoid, ...)

---@class SeshQuestRow
---@field questID integer
---@field title string?
---@field xp integer
---@field money integer

---@class SeshZoneRow
---@field name string
---@field kind integer Session.ZONE_*
---@field seconds integer

---@class SeshDungeonRow
---@field name string
---@field startedAt integer
---@field seconds integer from entering the dungeon to leaving it for good
---@field bosses integer
---@field live boolean? the run is still going

---@class SeshView
---@field kind "live"|"session"|"aggregate"|"shared"
---@field id integer?
---@field startedAt integer?
---@field endedAt integer?
---@field duration integer? total seconds (aggregates; otherwise derived from start/end)
---@field openSince integer? start of a period still running, not included in duration yet
---@field afkSeconds integer
---@field afkSince integer? open AFK period (running views only)
---@field sessionCount integer
---@field startLevel integer?
---@field endLevel integer?
---@field levels integer levels gained
---@field xp integer
---@field money integer raw gold received, in copper
---@field itemValue integer copper value of the items acquired minus the items used up
---@field itemCount integer items acquired
---@field kills integer
---@field unidentifiedKills integer
---@field deaths integer
---@field legacy integer Legacy Points earned
---@field missed integer events skipped because their values were unreadable
---@field questCount integer
---@field dungeonCount integer
---@field items SeshItemRow[] items acquired, most valuable first
---@field consumed SeshItemRow[] items used up (disenchanted or opened), most valuable first
---@field monsters SeshMonsterRow[] most killed first
---@field quests SeshQuestRow[] in turn-in order
---@field zones SeshZoneRow[] longest first
---@field dungeons SeshDungeonRow[] finished runs, oldest first
---@field currentDungeon SeshDungeonRow? the run in progress (running views only)
---@field achievements {achievementID: integer}[]
---@field level integer? set on level views (see Leveling)

local revision = 0

local function Changed()
	revision = revision + 1
	Events.Debounce("sessionUpdated", 0.25, function()
		Events.Fire("SESH_SESSION_UPDATED")
	end)
end

--- Increments whenever the active session changes.
function Session.Revision()
	return revision
end

---@param id integer
---@param now integer
---@return table active session
function Session.New(id, now)
	return {
		id = id,
		startedAt = now,
		lastSeenAt = now,
		xp = 0,
		money = 0,
		kills = 0,
		unidentifiedKills = 0,
		deaths = 0,
		legacy = 0,
		afkSeconds = 0,
		missed = 0,
		items = {},
		consumed = {},
		unitValues = {},
		monsters = {},
		quests = {},
		zones = {},
		dungeons = {},
		achievements = {},
	}
end

--- Adds fields that newer versions of Sesh keep to an active session saved by an older one.
function Session.Upgrade(session)
	session.dungeons = session.dungeons or {}
	session.consumed = session.consumed or {}
end

-- Mutators. Trackers call these; each one marks the session as changed. ------------------

function Session.AddMoney(session, copper)
	session.money = session.money + copper
	Changed()
end

function Session.AddItem(session, itemID, count)
	session.items[itemID] = (session.items[itemID] or 0) + count
	Changed()
end

--- Records items used up: disenchanted or opened. What they turned into is counted as
--- loot, so their value is taken off here.
function Session.ConsumeItem(session, itemID, count)
	session.consumed[itemID] = (session.consumed[itemID] or 0) + count
	Changed()
end

function Session.AddXP(session, amount)
	session.xp = session.xp + amount
	Changed()
end

--- Records the character's current level; the first call fixes the starting level.
function Session.SetLevel(session, level)
	if not session.startLevel then
		session.startLevel = level
	end
	if session.endLevel ~= level then
		session.endLevel = level
		Changed()
	end
end

--- Counts a kill. Without a name the kill is counted as unidentified (restricted content).
---@param name string?
---@param npcID integer?
---@param typeID integer?
function Session.AddKill(session, name, npcID, typeID)
	session.kills = session.kills + 1
	if name then
		local monster = session.monsters[name]
		if not monster then
			monster = { count = 0 }
			session.monsters[name] = monster
		end
		monster.count = monster.count + 1
		monster.npcID = monster.npcID or npcID
		monster.typeID = monster.typeID or typeID
	else
		session.unidentifiedKills = session.unidentifiedKills + 1
	end
	Changed()
end

function Session.AddQuest(session, questID, title, xp, money)
	session.quests[#session.quests + 1] = { questID = questID, title = title, xp = xp, money = money }
	Changed()
end

function Session.AddDeath(session)
	session.deaths = session.deaths + 1
	Changed()
end

function Session.AddAchievement(session, achievementID)
	for _, existing in ipairs(session.achievements) do
		if existing == achievementID then
			return
		end
	end
	session.achievements[#session.achievements + 1] = achievementID
	Changed()
end

function Session.AddLegacy(session, points)
	session.legacy = session.legacy + points
	Changed()
end

--- Notes an event whose values couldn't be read (secret in restricted content).
function Session.NoteMissed(session)
	session.missed = session.missed + 1
end

local function AddZoneTime(session, name, kind, seconds)
	if seconds <= 0 then
		return
	end
	local zone = session.zones[name]
	if not zone then
		zone = { seconds = 0, kind = kind }
		session.zones[name] = zone
	end
	zone.seconds = zone.seconds + seconds
end

--- Starts timing a zone, closing the previous one.
---@param name string
---@param kind integer
---@param now integer
function Session.EnterZone(session, name, kind, now)
	if session.zone == name and session.zoneSince then
		return
	end
	if session.zone and session.zoneSince then
		AddZoneTime(session, session.zone, session.zoneKind or Session.ZONE_WORLD, now - session.zoneSince)
	end
	session.zone, session.zoneKind, session.zoneSince = name, kind, now
	Changed()
end

--- Opens or closes an AFK period.
function Session.SetAfk(session, isAfk, now)
	if isAfk and not session.afkSince then
		session.afkSince = now
		Changed()
	elseif not isAfk and session.afkSince then
		session.afkSeconds = session.afkSeconds + max(0, now - session.afkSince)
		session.afkSince = nil
		Changed()
	end
end

--- Adds time that doesn't count as active play (e.g. the gap of a resumed session).
function Session.AddAfk(session, seconds)
	session.afkSeconds = session.afkSeconds + max(0, seconds)
end

--- Closes the open zone and AFK periods at the given time.
function Session.CloseTimers(session, at)
	if session.zone and session.zoneSince then
		AddZoneTime(session, session.zone, session.zoneKind or Session.ZONE_WORLD, at - session.zoneSince)
		session.zoneSince = nil
	end
	Session.SetAfk(session, false, at)
end

-- Dungeon runs. The run in progress is session.dungeon; finished runs are appended to
-- session.dungeons. A run remembers when each of its bosses died and when the player last
-- came back inside (inSince), so a boss dying a second time shows the dungeon was reset.

--- Ends the run in progress. It's kept when a boss died or it lasted long enough; a run
--- the player left ends when they left.
---@param now integer
function Session.EndDungeon(session, now)
	local run = session.dungeon
	if not run then
		return
	end
	session.dungeon = nil
	local seconds = max(0, (run.leftAt or now) - run.startedAt)
	if run.bosses > 0 or seconds >= MIN_DUNGEON_SECONDS then
		session.dungeons[#session.dungeons + 1] =
			{ name = run.name, startedAt = run.startedAt, seconds = seconds, bosses = run.bosses }
	end
	Changed()
end

local function NewRun(name, now)
	return { name = name, startedAt = now, inSince = now, bosses = 0, encounters = {} }
end

--- The player is inside a dungeon. Coming back into the dungeon of the run in progress
--- continues it (after a corpse run or a reload); another dungeon starts a new run.
---@param name string
---@param now integer
function Session.EnterDungeon(session, name, now)
	local run = session.dungeon
	if run and run.name == name then
		if run.leftAt then
			run.lastLeftAt, run.leftAt, run.inSince = run.leftAt, nil, now
		end
		return
	end
	Session.EndDungeon(session, now)
	session.dungeon = NewRun(name, now)
	Changed()
end

--- The player left the dungeon of the run in progress; the run continues if they return.
function Session.LeaveDungeon(session, now)
	local run = session.dungeon
	if run and not run.leftAt then
		run.leftAt = now
	end
end

-- The dungeon was reset while the player was outside: the visits before the latest one
-- become a finished run, and the latest visit starts a new run with the bosses killed in it.
local function SplitRun(session, run)
	local earlier = { name = run.name, startedAt = run.startedAt, leftAt = run.lastLeftAt, bosses = 0 }
	local later = NewRun(run.name, run.inSince)
	for encounterID, killedAt in pairs(run.encounters) do
		if killedAt >= run.inSince then
			later.encounters[encounterID] = killedAt
			later.bosses = later.bosses + 1
		else
			earlier.bosses = earlier.bosses + 1
		end
	end
	session.dungeon = earlier
	Session.EndDungeon(session, run.inSince)
	session.dungeon = later
end

--- Counts a boss killed in the run in progress, once per encounter.
---@param encounterID integer
---@param now integer
function Session.AddBossKill(session, encounterID, now)
	local run = session.dungeon
	if not run or run.leftAt then
		return
	end
	local killedAt = run.encounters[encounterID]
	if killedAt then
		if killedAt >= run.inSince then
			return -- the same kill, reported by a second event
		end
		SplitRun(session, run)
		run = session.dungeon
	end
	run.encounters[encounterID] = now
	run.bosses = run.bosses + 1
	Changed()
end

--- Remembers current item prices, so a finished session keeps the values it had when
--- the player logged out.
function Session.SnapshotValues(session)
	for _, counts in ipairs({ session.items, session.consumed }) do
		for itemID in pairs(counts) do
			local unitValue = Pricing.UnitValue(itemID)
			if unitValue then
				session.unitValues[itemID] = unitValue
			end
		end
	end
end

--- True when nothing at all was recorded.
---@return boolean
function Session.IsEmpty(session)
	return session.xp == 0
		and session.money == 0
		and session.kills == 0
		and session.deaths == 0
		and session.legacy == 0
		and next(session.items) == nil
		and next(session.consumed) == nil
		and #session.quests == 0
		and #session.dungeons == 0
		and #session.achievements == 0
end

-- Views -----------------------------------------------------------------------------

local function ByValue(a, b)
	if a.value ~= b.value then
		return a.value > b.value
	end
	return a.itemID < b.itemID
end

local function ByCount(a, b)
	if a.count ~= b.count then
		return a.count > b.count
	end
	return a.name < b.name
end

local function BySeconds(a, b)
	if a.seconds ~= b.seconds then
		return a.seconds > b.seconds
	end
	return a.name < b.name
end

local function SumItems(items)
	local count, value = 0, 0
	for _, item in ipairs(items) do
		count = count + item.count
		value = value + item.value
	end
	return count, value
end

--- A view of the active session as of `now`, including the open zone period.
--- With preferSnapshot, prices snapshotted at logout win over live prices (used when a
--- session is finalized after the client restarted).
---@param now integer
---@param preferSnapshot boolean?
---@return SeshView
-- Rows for a map of item counts, priced live (or with the prices snapshotted at logout).
local function PricedRows(counts, unitValues, preferSnapshot)
	local rows = {}
	for itemID, count in pairs(counts) do
		local unitValue
		if preferSnapshot then
			unitValue = unitValues[itemID] or Pricing.UnitValue(itemID)
		else
			unitValue = Pricing.UnitValue(itemID) or unitValues[itemID]
		end
		unitValue = unitValue or 0
		rows[#rows + 1] = { itemID = itemID, count = count, unitValue = unitValue, value = unitValue * count }
	end
	table.sort(rows, ByValue)
	return rows
end

function Session.LiveView(session, now, preferSnapshot)
	local items = PricedRows(session.items, session.unitValues, preferSnapshot)
	local consumed = PricedRows(session.consumed or EMPTY, session.unitValues, preferSnapshot)

	local monsters = {}
	for name, monster in pairs(session.monsters) do
		monsters[#monsters + 1] = { name = name, count = monster.count, npcID = monster.npcID, typeID = monster.typeID }
	end
	table.sort(monsters, ByCount)

	local zones = {}
	for name, zone in pairs(session.zones) do
		zones[#zones + 1] = { name = name, kind = zone.kind, seconds = zone.seconds }
	end
	if session.zone and session.zoneSince then
		local open = max(0, now - session.zoneSince)
		local found = false
		for _, zone in ipairs(zones) do
			if zone.name == session.zone then
				zone.seconds = zone.seconds + open
				found = true
			end
		end
		if not found then
			zones[#zones + 1] = { name = session.zone, kind = session.zoneKind or Session.ZONE_WORLD, seconds = open }
		end
	end
	table.sort(zones, BySeconds)

	local quests = {}
	for index, quest in ipairs(session.quests) do
		quests[index] = { questID = quest.questID, title = quest.title, xp = quest.xp, money = quest.money }
	end

	local dungeons = {}
	for index, run in ipairs(session.dungeons or EMPTY) do
		dungeons[index] = { name = run.name, startedAt = run.startedAt, seconds = run.seconds, bosses = run.bosses }
	end
	local run = session.dungeon
	local currentDungeon = run
		and {
			name = run.name,
			startedAt = run.startedAt,
			seconds = max(0, (run.leftAt or now) - run.startedAt),
			bosses = run.bosses,
			live = true,
		}

	local achievements = {}
	for index, achievementID in ipairs(session.achievements) do
		achievements[index] = { achievementID = achievementID }
	end

	local itemCount, acquiredValue = SumItems(items)
	local _, consumedValue = SumItems(consumed)
	return {
		kind = "live",
		id = session.id,
		startedAt = session.startedAt,
		afkSeconds = session.afkSeconds,
		afkSince = session.afkSince,
		sessionCount = 1,
		startLevel = session.startLevel,
		endLevel = session.endLevel,
		levels = max(0, (session.endLevel or 0) - (session.startLevel or session.endLevel or 0)),
		xp = session.xp,
		money = session.money,
		itemValue = acquiredValue - consumedValue,
		itemCount = itemCount,
		kills = session.kills,
		unidentifiedKills = session.unidentifiedKills,
		deaths = session.deaths,
		legacy = session.legacy,
		missed = session.missed,
		questCount = #quests,
		dungeonCount = #dungeons,
		items = items,
		consumed = consumed,
		monsters = monsters,
		quests = quests,
		zones = zones,
		dungeons = dungeons,
		currentDungeon = currentDungeon,
		achievements = achievements,
	}
end

local function Number(value)
	return type(value) == "number" and value or 0
end

-- Item rows of a record: a finished session stores unit values, an aggregate total values.
local function DecodeItems(text, isAggregate)
	local rows = Pack.Decode(text, isAggregate and Pack.ITEM_TOTALS or Pack.ITEMS)
	for _, item in ipairs(rows) do
		if isAggregate then
			item.unitValue = item.count > 0 and floor(item.value / item.count) or 0
		else
			item.value = item.unitValue * item.count
		end
	end
	table.sort(rows, ByValue)
	return rows
end

--- The view of a finished session record or of an aggregate record (lifetime rollup,
--- level records). Decoded on demand and not kept: callers that reuse views (ranges, the
--- lifetime rollup) cache the results they build.
---@param record table
---@return SeshView
function Session.View(record)
	local isAggregate = record.sessionCount ~= nil

	local items = DecodeItems(record.items, isAggregate)

	local monsters = Pack.Decode(record.monsters, Pack.MONSTERS)
	for _, monster in ipairs(monsters) do
		if monster.npcID == 0 then
			monster.npcID = nil
		end
		if monster.typeID == 0 then
			monster.typeID = nil
		end
	end
	table.sort(monsters, ByCount)

	local zones = Pack.Decode(record.zones, Pack.ZONES)
	table.sort(zones, BySeconds)

	local quests = Pack.Decode(record.quests, Pack.QUESTS)
	for _, quest in ipairs(quests) do
		if quest.title == "" then
			quest.title = nil
		end
	end

	local itemCount = SumItems(items)
	local view = {
		kind = isAggregate and "aggregate" or "session",
		id = record.id,
		startedAt = record.startedAt,
		endedAt = record.endedAt,
		duration = isAggregate and Number(record.duration) or nil,
		afkSeconds = Number(record.afkSeconds),
		sessionCount = isAggregate and Number(record.sessionCount) or 1,
		startLevel = record.startLevel,
		endLevel = record.endLevel,
		levels = isAggregate and Number(record.levels)
			or max(0, Number(record.endLevel) - Number(record.startLevel or record.endLevel)),
		xp = Number(record.xp),
		money = Number(record.money),
		itemValue = Number(record.itemValue),
		itemCount = itemCount,
		kills = Number(record.kills),
		unidentifiedKills = Number(record.unidentifiedKills),
		deaths = Number(record.deaths),
		legacy = Number(record.legacy),
		missed = Number(record.missed),
		questCount = Number(record.questCount),
		dungeonCount = Number(record.dungeonCount),
		items = items,
		consumed = DecodeItems(record.consumed, isAggregate),
		monsters = monsters,
		quests = quests,
		zones = zones,
		dungeons = Pack.Decode(record.dungeons, Pack.DUNGEONS),
		achievements = Pack.Decode(record.achievements, Pack.ACHIEVEMENTS),
	}
	return view
end

--- Packs a finished view into the stored record shape.
---@param view SeshView
---@return table record
function Session.ToRecord(view)
	local isAggregate = view.kind == "aggregate"
	return {
		id = view.id,
		startedAt = view.startedAt,
		endedAt = view.endedAt,
		duration = isAggregate and view.duration or nil,
		sessionCount = isAggregate and view.sessionCount or nil,
		levels = isAggregate and view.levels or nil,
		afkSeconds = view.afkSeconds,
		startLevel = view.startLevel,
		endLevel = view.endLevel,
		xp = view.xp,
		money = view.money,
		itemValue = view.itemValue,
		kills = view.kills,
		unidentifiedKills = view.unidentifiedKills,
		deaths = view.deaths,
		legacy = view.legacy,
		missed = view.missed,
		questCount = view.questCount,
		dungeonCount = view.dungeonCount,
		items = Pack.Encode(view.items, isAggregate and Pack.ITEM_TOTALS or Pack.ITEMS),
		consumed = Pack.Encode(view.consumed, isAggregate and Pack.ITEM_TOTALS or Pack.ITEMS),
		monsters = Pack.Encode(view.monsters, Pack.MONSTERS),
		quests = Pack.Encode(view.quests, Pack.QUESTS),
		zones = Pack.Encode(view.zones, Pack.ZONES),
		dungeons = Pack.Encode(view.dungeons, Pack.DUNGEONS),
		achievements = Pack.Encode(view.achievements, Pack.ACHIEVEMENTS),
	}
end

--- Turns the active session into a finished record, ending at endedAt.
---@return table record
function Session.Finalize(session, endedAt)
	Session.CloseTimers(session, endedAt)
	Session.EndDungeon(session, endedAt)
	local record = Session.ToRecord(Session.LiveView(session, endedAt, true))
	record.endedAt = endedAt
	return record
end

-- Marks -----------------------------------------------------------------------------
-- A mark is the active session's totals at one moment. Session.Since takes a mark's
-- totals out of a later view of the session, leaving the part played after the mark
-- (Leveling uses this for the part played at each level).

local MARKED_SCALARS = { "xp", "money", "kills", "unidentifiedKills", "deaths", "legacy", "missed" }

--- The active session's totals at `at`. An open AFK period is split at the mark, so each
--- part of it counts on its own side.
---@param at integer
---@return table mark
function Session.Mark(session, at)
	if session.afkSince then
		Session.SetAfk(session, false, at)
		Session.SetAfk(session, true, at)
	end
	local mark = {
		at = at,
		afk = session.afkSeconds,
		quests = #session.quests,
		achievements = #session.achievements,
		dungeons = #session.dungeons,
		items = {},
		consumed = {},
		monsters = {},
		zones = {},
	}
	for _, key in ipairs(MARKED_SCALARS) do
		mark[key] = session[key]
	end
	for itemID, count in pairs(session.items) do
		mark.items[itemID] = count
	end
	for itemID, count in pairs(session.consumed) do
		mark.consumed[itemID] = count
	end
	for name, monster in pairs(session.monsters) do
		mark.monsters[name] = monster.count
	end
	for name, zone in pairs(session.zones) do
		mark.zones[name] = zone.seconds
	end
	if session.zone and session.zoneSince then
		mark.zones[session.zone] = (mark.zones[session.zone] or 0) + max(0, at - session.zoneSince)
	end
	return mark
end

-- Rows whose `field` is left above zero after taking away the marked amounts.
local function Remaining(rows, marked, key, field)
	if not marked then
		return rows
	end
	local kept = {}
	for _, row in ipairs(rows) do
		row[field] = row[field] - (marked[row[key]] or 0)
		if row[field] > 0 then
			kept[#kept + 1] = row
		end
	end
	return kept
end

-- Item rows left after taking away the marked counts, valued again.
local function RepricedRemaining(rows, marked)
	rows = Remaining(rows, marked, "itemID", "count")
	for _, item in ipairs(rows) do
		item.value = item.unitValue * item.count
	end
	table.sort(rows, ByValue)
	return rows
end

-- Rows after the first `count`.
local function After(rows, count)
	local kept = {}
	for index = (count or 0) + 1, #rows do
		kept[#kept + 1] = rows[index]
	end
	return kept
end

--- Trims a live view of the active session down to what was recorded after a mark. The
--- view keeps running (it has no end) unless the caller sets endedAt. A mark of just
--- { at = time } takes nothing away: everything since `at`.
---@param view SeshView from Session.LiveView; changed in place
---@param mark table from Session.Mark
---@return SeshView view
function Session.Since(view, mark)
	view.startedAt = mark.at
	view.afkSeconds = max(0, view.afkSeconds - (mark.afk or 0))
	for _, key in ipairs(MARKED_SCALARS) do
		view[key] = max(0, view[key] - (mark[key] or 0))
	end
	view.items = RepricedRemaining(view.items, mark.items)
	view.consumed = RepricedRemaining(view.consumed, mark.consumed)
	local acquiredValue, consumedValue
	view.itemCount, acquiredValue = SumItems(view.items)
	consumedValue = select(2, SumItems(view.consumed))
	view.itemValue = acquiredValue - consumedValue
	view.monsters = Remaining(view.monsters, mark.monsters, "name", "count")
	table.sort(view.monsters, ByCount)
	view.zones = Remaining(view.zones, mark.zones, "name", "seconds")
	table.sort(view.zones, BySeconds)
	view.quests = After(view.quests, mark.quests)
	view.questCount = #view.quests
	view.dungeons = After(view.dungeons, mark.dungeons)
	view.dungeonCount = #view.dungeons
	view.achievements = After(view.achievements, mark.achievements)
	view.levels = 0
	return view
end

-- Durations -------------------------------------------------------------------------

--- When a view is still running (the live session, or an aggregate that includes it):
--- the start of the period not yet counted in its totals.
---@param view SeshView
---@return integer?
local function RunningSince(view)
	if view.openSince then
		return view.openSince
	end
	if not view.endedAt and not view.duration then
		return view.startedAt
	end
end

--- Total seconds covered by a view (running views count until `now`).
---@param view SeshView
---@param now integer
---@return integer
function Session.Duration(view, now)
	if view.duration then
		return view.duration + (view.openSince and max(0, now - view.openSince) or 0)
	elseif view.endedAt then
		return max(0, view.endedAt - (view.startedAt or view.endedAt))
	end
	return max(0, now - (view.startedAt or now))
end

--- AFK seconds, including a still-open AFK period.
---@param view SeshView
---@param now integer
---@return integer
function Session.AfkSeconds(view, now)
	local afk = view.afkSeconds or 0
	if view.afkSince then
		afk = afk + max(0, now - view.afkSince)
	end
	return afk
end

-- Aggregates ------------------------------------------------------------------------

local SCALARS = {
	"xp",
	"money",
	"itemValue",
	"kills",
	"unidentifiedKills",
	"deaths",
	"legacy",
	"missed",
	"questCount",
	"dungeonCount",
}

--- An empty accumulator for combining views (ranges, lifetime, levels).
function Session.NewAggregate()
	local aggregate = {
		sessionCount = 0,
		duration = 0,
		afkSeconds = 0,
		levels = 0,
		items = {},
		consumed = {},
		monsters = {},
		zones = {},
		quests = {},
		dungeons = {},
		achievements = {},
	}
	for _, key in ipairs(SCALARS) do
		aggregate[key] = 0
	end
	return aggregate
end

local function RemoveFirst(list, predicate)
	for index, value in ipairs(list) do
		if predicate(value) then
			table.remove(list, index)
			return
		end
	end
end

local function AccumulateItems(totals, rows, sign)
	for _, item in ipairs(rows) do
		local entry = totals[item.itemID]
		if not entry then
			entry = { itemID = item.itemID, count = 0, value = 0 }
			totals[item.itemID] = entry
		end
		entry.count = entry.count + sign * item.count
		entry.value = entry.value + sign * item.value
	end
end

--- Adds a view to an accumulator, or subtracts it when sign is -1. A running view stays
--- running in the result, so its duration keeps counting after the aggregate is sealed.
---@param aggregate table from Session.NewAggregate
---@param view SeshView
---@param sign integer? 1 (default) or -1
---@param now integer? needed when the view is finished but has an open AFK period
function Session.Accumulate(aggregate, view, sign, now)
	sign = sign or 1
	now = now or 0
	aggregate.sessionCount = aggregate.sessionCount + sign * (view.sessionCount or 1)
	local runningSince = RunningSince(view)
	if runningSince then
		aggregate.duration = aggregate.duration + sign * (view.duration or 0)
		aggregate.afkSeconds = aggregate.afkSeconds + sign * (view.afkSeconds or 0)
		aggregate.openSince = runningSince
		aggregate.afkSince = view.afkSince
	else
		aggregate.duration = aggregate.duration + sign * Session.Duration(view, now)
		aggregate.afkSeconds = aggregate.afkSeconds + sign * Session.AfkSeconds(view, now)
	end
	aggregate.levels = aggregate.levels + sign * (view.levels or 0)
	for _, key in ipairs(SCALARS) do
		aggregate[key] = aggregate[key] + sign * (view[key] or 0)
	end

	AccumulateItems(aggregate.items, view.items, sign)
	AccumulateItems(aggregate.consumed, view.consumed or EMPTY, sign)
	for _, monster in ipairs(view.monsters) do
		local entry = aggregate.monsters[monster.name]
		if not entry then
			entry = { name = monster.name, count = 0 }
			aggregate.monsters[monster.name] = entry
		end
		entry.count = entry.count + sign * monster.count
		entry.npcID = entry.npcID or monster.npcID
		entry.typeID = entry.typeID or monster.typeID
	end
	for _, zone in ipairs(view.zones) do
		local entry = aggregate.zones[zone.name]
		if not entry then
			entry = { name = zone.name, kind = zone.kind, seconds = 0 }
			aggregate.zones[zone.name] = entry
		end
		entry.seconds = entry.seconds + sign * zone.seconds
	end
	for _, quest in ipairs(view.quests) do
		if sign > 0 then
			aggregate.quests[#aggregate.quests + 1] = quest
		else
			RemoveFirst(aggregate.quests, function(existing)
				return existing.questID == quest.questID
			end)
		end
	end
	for _, run in ipairs(view.dungeons) do
		if sign > 0 then
			aggregate.dungeons[#aggregate.dungeons + 1] = run
		else
			RemoveFirst(aggregate.dungeons, function(existing)
				return existing.startedAt == run.startedAt and existing.name == run.name
			end)
		end
	end
	for _, achievement in ipairs(view.achievements) do
		if sign > 0 then
			aggregate.achievements[#aggregate.achievements + 1] = achievement
		else
			RemoveFirst(aggregate.achievements, function(existing)
				return existing.achievementID == achievement.achievementID
			end)
		end
	end
end

-- The last `limit` rows of a list.
local function Recent(list, limit)
	if #list <= limit then
		return list
	end
	local recent = {}
	for index = #list - limit + 1, #list do
		recent[#recent + 1] = list[index]
	end
	return recent
end

local function SealItems(totals)
	local rows = {}
	for _, entry in pairs(totals) do
		if entry.count > 0 then
			rows[#rows + 1] = {
				itemID = entry.itemID,
				count = entry.count,
				value = max(0, entry.value),
				unitValue = floor(max(0, entry.value) / entry.count),
			}
		end
	end
	table.sort(rows, ByValue)
	return rows
end

--- Turns an accumulator into an aggregate view.
---@return SeshView
function Session.Seal(aggregate)
	local items, consumed, monsters, zones = SealItems(aggregate.items), SealItems(aggregate.consumed), {}, {}
	for _, entry in pairs(aggregate.monsters) do
		if entry.count > 0 then
			monsters[#monsters + 1] =
				{ name = entry.name, count = entry.count, npcID = entry.npcID, typeID = entry.typeID }
		end
	end
	for _, entry in pairs(aggregate.zones) do
		if entry.seconds > 0 then
			zones[#zones + 1] = { name = entry.name, kind = entry.kind, seconds = entry.seconds }
		end
	end
	table.sort(monsters, ByCount)
	table.sort(zones, BySeconds)

	local view = {
		kind = "aggregate",
		sessionCount = max(0, aggregate.sessionCount),
		duration = max(0, aggregate.duration),
		openSince = aggregate.openSince,
		afkSeconds = max(0, aggregate.afkSeconds),
		afkSince = aggregate.afkSince,
		levels = max(0, aggregate.levels),
		itemCount = (SumItems(items)),
		items = items,
		consumed = consumed,
		monsters = monsters,
		zones = zones,
		quests = Recent(aggregate.quests, MAX_AGGREGATE_ROWS),
		dungeons = Recent(aggregate.dungeons, MAX_AGGREGATE_ROWS),
		achievements = aggregate.achievements,
	}
	for _, key in ipairs(SCALARS) do
		view[key] = max(0, aggregate[key])
	end
	-- Using up items worth more than what they turned into is a real loss.
	view.itemValue = aggregate.itemValue
	return view
end

-- Metrics ---------------------------------------------------------------------------

--- Seconds that count for hourly rates.
---@param duration number
---@param afk number
---@param excludeAfk boolean
---@return number
function Session.ActiveSeconds(duration, afk, excludeAfk)
	return excludeAfk and (duration - math.min(afk, duration)) or duration
end

--- An amount per hour of active time, or nil while there's too little time for a rate.
---@return number?
function Session.PerHour(amount, activeSeconds)
	if activeSeconds >= MIN_RATE_SECONDS then
		return amount * 3600 / activeSeconds
	end
end

---@class SeshMetrics
---@field duration integer
---@field activeSeconds integer
---@field afkSeconds integer
---@field goldEarned integer raw gold + item value
---@field money integer
---@field itemValue integer items acquired minus items used up
---@field itemsAcquiredValue integer
---@field itemsUsed integer items used up (disenchanted or opened)
---@field itemsUsedValue integer
---@field goldPerHour number? nil until there is enough active time
---@field moneyPerHour number?
---@field xp integer
---@field xpPerHour number?
---@field levels integer
---@field kills integer
---@field kinds integer distinct monsters
---@field quests integer
---@field dungeons integer finished dungeon runs
---@field zones integer
---@field items integer total item count
---@field itemKinds integer
---@field deaths integer
---@field achievements integer
---@field legacy integer
---@field sessions integer

--- Every derived number the UI, chat text and data broker show, computed in one place.
---@param view SeshView
---@param now integer
---@param excludeAfk boolean
---@return SeshMetrics
function Session.Metrics(view, now, excludeAfk)
	local duration = Session.Duration(view, now)
	local afk = math.min(Session.AfkSeconds(view, now), duration)
	local active = Session.ActiveSeconds(duration, afk, excludeAfk)
	local goldEarned = view.money + view.itemValue
	local usedCount, usedValue = SumItems(view.consumed or EMPTY)
	return {
		duration = duration,
		activeSeconds = active,
		afkSeconds = afk,
		goldEarned = goldEarned,
		money = view.money,
		itemValue = view.itemValue,
		itemsAcquiredValue = view.itemValue + usedValue,
		itemsUsed = usedCount,
		itemsUsedValue = usedValue,
		goldPerHour = Session.PerHour(goldEarned, active),
		moneyPerHour = Session.PerHour(view.money, active),
		xp = view.xp,
		xpPerHour = Session.PerHour(view.xp, active),
		levels = view.levels or 0,
		kills = view.kills,
		kinds = #view.monsters,
		quests = view.questCount,
		dungeons = view.dungeonCount or 0,
		zones = #view.zones,
		items = view.itemCount or 0,
		itemKinds = #view.items,
		deaths = view.deaths,
		achievements = #view.achievements,
		legacy = view.legacy,
		sessions = view.sessionCount or 1,
	}
end
