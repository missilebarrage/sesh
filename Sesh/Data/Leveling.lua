local _, ns = ...

--- Stats per character level: how long each level took and what happened during it.
---
--- A level's stats are the parts of sessions played at that level. The active session
--- carries a mark (Session.Mark) of its totals from when its part at the current level
--- began: the session's start or the last level-up. "The session now, minus the mark" is
--- the part played at the current level so far (Session.Since). When that part ends, at a
--- level-up or when the session ends, it's added to the level's record: an aggregate
--- stored like the lifetime rollup, in SeshCharDB.levels by level.
---
--- A level is complete when Sesh saw both level-ups around it. When tracking began
--- partway through a level (Sesh was installed then), its record remembers how far in.
---@class SeshLeveling
local Leveling = ns.Leveling
local Database = ns.Database
local Session = ns.Session
local Recorder = ns.Recorder
local Progress = ns.Progress
local Shares = ns.Shares
local Events = ns.Events

local EMPTY = {}

-- Fields of a level record besides the aggregate totals.
local LEVEL_FIELDS = { "level", "startedAt", "endedAt", "completed", "fromPercent", "xpMax" }

local revision = 0

local function Changed()
	revision = revision + 1
	Events.Fire("SESH_LEVELS_CHANGED")
end

--- Increments whenever level records change.
function Leveling.Revision()
	return revision
end

--- This character's level records by level. Treat as read-only.
---@return table<integer, table>
function Leveling.Records()
	local char = Database.Char()
	return char and char.levels or EMPTY
end

--- The level being tracked right now, or nil (no session yet, or at the level cap).
---@return integer?
function Leveling.Current()
	local active = Recorder.Current()
	local mark = active and active.levelMark
	return mark and mark.level
end

--- How far into a level an amount of experience is, in whole percent (0-99).
---@return integer?
function Leveling.Percent(xp, xpMax)
	if xp and xpMax and xpMax > 0 then
		return math.min(99, math.max(0, math.floor(xp / xpMax * 100)))
	end
end

-- Records ---------------------------------------------------------------------------

---@param fields table the level fields (LEVEL_FIELDS) to keep
local function Store(level, view, fields)
	local record = Session.ToRecord(view)
	for _, key in ipairs(LEVEL_FIELDS) do
		record[key] = fields[key]
	end
	Database.Char().levels[level] = record
	return record
end

--- The record of a level, created when the first part played at it is added: the mark
--- that began the part says where tracking of the level began.
local function EnsureRecord(mark)
	local record = Leveling.Records()[mark.level]
	if not record then
		record = Store(mark.level, Session.Seal(Session.NewAggregate()), {
			level = mark.level,
			startedAt = mark.at,
			endedAt = mark.at,
			fromPercent = mark.fromPercent,
			xpMax = mark.xpMax,
		})
	elseif mark.xpMax then
		record.xpMax = mark.xpMax
	end
	return record
end

--- Adds the part of the session played since the mark to the mark's level.
---@param final boolean? the session is ending (item prices snapshotted at logout win)
---@return table record
local function Fold(session, mark, at, final)
	local part = Session.Since(Session.LiveView(session, at, final), mark)
	part.endedAt = at
	local record = EnsureRecord(mark)
	local aggregate = Session.NewAggregate()
	Session.Accumulate(aggregate, Session.View(record))
	Session.Accumulate(aggregate, part, 1, at)
	local stored = Store(mark.level, Session.Seal(aggregate), record)
	stored.endedAt = at
	return stored
end

--- Starts counting the session's activity toward a level from a mark. `fromXP` is the
--- experience the level already had at the mark (none right after a level-up): a level
--- Sesh didn't see from its start remembers how far into it tracking began.
local function Begin(session, mark, level, fromXP, xpMax)
	local fromPercent = fromXP > 0 and Leveling.Percent(fromXP, xpMax) or 0
	mark.level = level
	mark.xpMax = xpMax
	mark.fromPercent = fromPercent > 0 and fromPercent or nil
	session.levelMark = mark
end

-- Tracking --------------------------------------------------------------------------
-- Progress calls these as it reads the character's level and experience.

--- Makes sure the session's activity counts toward the character's current level. Called
--- when a session starts or resumes, and when the level is read again without a level-up
--- having been seen.
---@param session table the active session
---@param level integer
---@param xp integer experience into the level
---@param xpMax integer experience the level needs
---@param now integer
function Leveling.Start(session, level, xp, xpMax, now)
	if not Database.Char() then
		return
	end
	local mark = session.levelMark
	if mark and mark.level == level then
		mark.xpMax = xpMax
		return
	end
	session.levelMark = nil
	if mark then
		-- The level changed without Sesh seeing the level-up: the old level's part ends here.
		Fold(session, mark, now)
	end
	if Progress.CanLevel(xpMax) then
		-- A session that hasn't changed level counts toward this level from its start, even
		-- when it was recorded before Sesh tracked levels.
		if not mark and session.startLevel == level then
			Begin(session, { at = session.startedAt }, level, xp - session.xp, xpMax)
		else
			Begin(session, Session.Mark(session, now), level, xp, xpMax)
		end
	end
	Changed()
end

--- Called at a level-up, after the experience that finished the old level was counted
--- and before any experience into the new one.
---@param session table the active session
---@param level integer the new level
---@param xpMax integer experience the new level needs
---@param now integer
function Leveling.LevelUp(session, level, xpMax, now)
	if not Database.Char() then
		return
	end
	local mark = session.levelMark
	session.levelMark = nil
	if mark then
		Fold(session, mark, now).completed = true
	end
	if Progress.CanLevel(xpMax) then
		Begin(session, Session.Mark(session, now), level, 0, xpMax)
	end
	Changed()
	if mark then
		Events.Fire("SESH_LEVEL_UP", mark.level, level)
	end
end

--- Called when a session is finalized: its last part goes to the level it was played at.
---@param session table
---@param at integer when the session ended
function Leveling.Finish(session, at)
	local mark = session.levelMark
	if not (mark and Database.Char()) then
		return
	end
	session.levelMark = nil
	Fold(session, mark, at, true)
	Changed()
end

--- Deletes every level record of this character. The current level starts over from now,
--- as if Sesh had just been installed.
---@param now integer
function Leveling.DeleteAll(now)
	local char = Database.Char()
	if not char then
		return
	end
	char.levels = {}
	Shares.ForgetAll("level")
	local active = Recorder.Current()
	local mark = active and active.levelMark
	if mark then
		local _, xp = Progress.Experience()
		Begin(active, Session.Mark(active, now), mark.level, xp or 0, mark.xpMax)
	end
	Changed()
end

-- Views -----------------------------------------------------------------------------

--- The view of a level: its record plus, for the current level, the part played so far
--- in the active session. The current level's view keeps running, so its time stays
--- current between refreshes.
---@param level integer
---@param now integer
---@return SeshView?
function Leveling.View(level, now)
	local record = Leveling.Records()[level]
	local active = Recorder.Current()
	local mark = active and active.levelMark
	local isCurrent = mark ~= nil and mark.level == level
	if not (record or isCurrent) then
		return nil
	end
	local aggregate = Session.NewAggregate()
	if record then
		Session.Accumulate(aggregate, Session.View(record))
	end
	local part
	if isCurrent then
		part = Session.Since(Session.LiveView(active, now), mark)
		Session.Accumulate(aggregate, part, 1, now)
	end
	local view = Session.Seal(aggregate)
	view.level = level
	view.live = isCurrent
	-- Until its first part is stored, the current level's start is known from the mark.
	view.startedAt = record and record.startedAt or mark.at
	view.endedAt = not isCurrent and record.endedAt or nil
	view.completed = record and record.completed or nil
	view.fromPercent = (record or mark).fromPercent
	view.xpMax = (isCurrent and mark.xpMax) or (record and record.xpMax)
	if part then
		view.currentDungeon = part.currentDungeon
		local _, xp, xpMax = Progress.Experience()
		view.progress = Leveling.Percent(xp, xpMax)
	end
	return view
end

---@class SeshLevelRow
---@field level integer
---@field current boolean? the level being played now
---@field partial boolean Sesh saw only part of the level
---@field fromPercent integer? how far into the level tracking began
---@field progress integer? how far into the level the character is (current level)
---@field startedAt integer?
---@field endedAt integer?
---@field duration integer
---@field activeSeconds integer
---@field xp integer
---@field xpPerHour number?
---@field goldEarned integer
---@field kills integer
---@field quests integer
---@field dungeons integer
---@field deaths integer
---@field sessions integer

---@param source table a level record or view (both have the totals under the same names)
local function Row(source, level, duration, afk, excludeAfk)
	local active = Session.ActiveSeconds(duration, afk, excludeAfk)
	local xp = source.xp or 0
	return {
		level = level,
		startedAt = source.startedAt,
		endedAt = source.endedAt,
		fromPercent = source.fromPercent,
		duration = duration,
		activeSeconds = active,
		xp = xp,
		xpPerHour = Session.PerHour(xp, active),
		goldEarned = (source.money or 0) + (source.itemValue or 0),
		kills = source.kills or 0,
		quests = source.questCount or 0,
		dungeons = source.dungeonCount or 0,
		deaths = source.deaths or 0,
		sessions = source.sessionCount or 0,
	}
end

--- One row per tracked level, lowest level first, with the numbers the level list and
--- chart show. Finished levels are read from their records' totals without decoding
--- their lists.
---@param now integer
---@param excludeAfk boolean
---@return SeshLevelRow[] rows
---@return SeshView? current the current level's view
function Leveling.Rows(now, excludeAfk)
	local rows = {}
	local currentLevel = Leveling.Current()
	for level, record in pairs(Leveling.Records()) do
		if level ~= currentLevel then
			local row = Row(record, level, record.duration or 0, record.afkSeconds or 0, excludeAfk)
			row.partial = record.fromPercent ~= nil or not record.completed
			rows[#rows + 1] = row
		end
	end
	local current = currentLevel and Leveling.View(currentLevel, now)
	if current then
		local duration = Session.Duration(current, now)
		local row = Row(current, currentLevel, duration, Session.AfkSeconds(current, now), excludeAfk)
		row.current = true
		row.partial = current.fromPercent ~= nil
		row.progress = current.progress
		rows[#rows + 1] = row
	end
	table.sort(rows, function(a, b)
		return a.level < b.level
	end)
	return rows, current
end
