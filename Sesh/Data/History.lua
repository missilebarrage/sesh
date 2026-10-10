local _, ns = ...

--- Finished sessions of this character, the lifetime rollup, and time-range queries.
--- Sessions are stored oldest first; ids increase with start time.
---@class SeshHistory
local History = ns.History
local Database = ns.Database
local Session = ns.Session
local Stats = ns.Stats
local Events = ns.Events
local Recorder = ns.Recorder

--- Range keys for History.Bounds / History.Query, in display order.
History.RANGES = { "today", "week", "month", "quarter", "all" }

local MAX_CACHED_RANGES = 16

local EMPTY = {}
local revision = 0
local rangeCache = {} ---@type table<string, SeshView>
local cachedRanges = 0
local lifetimeView ---@type SeshView?

local function Char()
	return Database.Char()
end

local function Changed()
	revision = revision + 1
	wipe(rangeCache)
	cachedRanges = 0
	lifetimeView = nil
	Events.Fire("SESH_HISTORY_CHANGED")
end

--- Increments whenever sessions are added or removed.
function History.Revision()
	return revision
end

--- Finished session records, oldest first. Treat as read-only.
---@return table[]
function History.Sessions()
	local char = Char()
	return char and char.sessions or EMPTY
end

--- Finds a finished session by id.
---@return table? record
---@return integer? index
function History.Get(id)
	local sessions = History.Sessions()
	local low, high = 1, #sessions
	while low <= high do
		local middle = math.floor((low + high) / 2)
		local middleID = sessions[middle].id
		if middleID == id then
			return sessions[middle], middle
		elseif middleID < id then
			low = middle + 1
		else
			high = middle - 1
		end
	end
end

--- All finished sessions merged together.
---@return SeshView
function History.Lifetime()
	if not lifetimeView then
		local char = Char()
		lifetimeView = (char and char.lifetime) and Session.View(char.lifetime) or Session.Seal(Session.NewAggregate())
	end
	return lifetimeView
end

local function StoreLifetime(aggregate)
	local char = Char()
	if char then
		char.lifetime = Session.ToRecord(Session.Seal(aggregate))
	end
end

---@param record table a record from Session.Finalize
function History.Add(record)
	local char = Char()
	if not char then
		return
	end
	char.sessions[#char.sessions + 1] = record
	local lifetime = Session.NewAggregate()
	Session.Accumulate(lifetime, History.Lifetime())
	Session.Accumulate(lifetime, Session.View(record))
	StoreLifetime(lifetime)
	Changed()
end

---@return boolean deleted
function History.Delete(id)
	local record, index = History.Get(id)
	if not record then
		return false
	end
	local char = Char()
	table.remove(char.sessions, index)
	local lifetime = Session.NewAggregate()
	Session.Accumulate(lifetime, History.Lifetime())
	Session.Accumulate(lifetime, Session.View(record), -1)
	StoreLifetime(lifetime)
	Changed()
	return true
end

function History.DeleteAll()
	local char = Char()
	if not char then
		return
	end
	char.sessions = {}
	char.lifetime = nil
	Changed()
end

--- Recomputes the lifetime rollup from every stored session.
function History.Rebuild()
	local lifetime = Session.NewAggregate()
	for _, record in ipairs(History.Sessions()) do
		Session.Accumulate(lifetime, Session.View(record))
	end
	StoreLifetime(lifetime)
	Changed()
end

local function LocalMidnight(year, month, day)
	return time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
end

--- Start (inclusive) and end (exclusive) of a range in local time; nil means unbounded.
--- Sessions belong to the range their start time falls in.
---@param range string|{day: integer} "today", "week", "month", "quarter", "all" or a day number
---@param now integer
---@return integer? from
---@return integer? to
function History.Bounds(range, now)
	if type(range) == "table" then
		return Stats.MidnightOf(range.day), Stats.MidnightOf(range.day + 1)
	end
	local today = date("*t", now)
	if range == "today" then
		return LocalMidnight(today.year, today.month, today.day)
	elseif range == "week" then
		local daysBack = (today.wday - Database.Get("weekStart")) % 7
		return LocalMidnight(today.year, today.month, today.day - daysBack)
	elseif range == "month" then
		return LocalMidnight(today.year, today.month, 1)
	elseif range == "quarter" then
		return LocalMidnight(today.year, today.month - 3, today.day)
	end
	return nil, nil
end

--- Index of the first session that started at or after `from`.
local function FirstIndexFrom(sessions, from)
	local low, high = 1, #sessions + 1
	while low < high do
		local middle = math.floor((low + high) / 2)
		if sessions[middle].startedAt < from then
			low = middle + 1
		else
			high = middle
		end
	end
	return low
end

--- Finished sessions that started within [from, to). nil bounds are open.
---@return table[]
function History.Between(from, to)
	local sessions = History.Sessions()
	local result = {}
	for index = from and FirstIndexFrom(sessions, from) or 1, #sessions do
		local record = sessions[index]
		if to and record.startedAt >= to then
			break
		end
		result[#result + 1] = record
	end
	return result
end

--- Finished sessions of a range combined into one view (no live session).
---@return SeshView
function History.RangeView(range, now)
	if range == "all" then
		return History.Lifetime()
	end
	local from, to = History.Bounds(range, now)
	local key = tostring(from) .. ":" .. tostring(to)
	local cached = rangeCache[key]
	if cached then
		return cached
	end
	local aggregate = Session.NewAggregate()
	for _, record in ipairs(History.Between(from, to)) do
		Session.Accumulate(aggregate, Session.View(record))
	end
	local view = Session.Seal(aggregate)
	if cachedRanges >= MAX_CACHED_RANGES then
		wipe(rangeCache)
		cachedRanges = 0
	end
	rangeCache[key] = view
	cachedRanges = cachedRanges + 1
	return view
end

--- A range including the live session when it started inside the range.
---@return SeshView
function History.Query(range, now)
	local base = History.RangeView(range, now)
	local active = Recorder.Current()
	if not active then
		return base
	end
	local from, to = History.Bounds(range, now)
	if (from and active.startedAt < from) or (to and active.startedAt >= to) then
		return base
	end
	local aggregate = Session.NewAggregate()
	Session.Accumulate(aggregate, base)
	Session.Accumulate(aggregate, Session.LiveView(active, now), 1, now)
	return Session.Seal(aggregate)
end
