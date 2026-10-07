local _, ns = ...

--- Calendar math and summary statistics: daily totals for the heatmap, personal
--- records, play streaks and averages. Day numbers count days since 1970-01-01 and are
--- independent of time zones and daylight saving.
---@class SeshStats
local Stats = ns.Stats
local History = ns.History
local Session = ns.Session
local Recorder = ns.Recorder

local floor = math.floor

-- Per-hour records only consider sessions with at least this much active time.
Stats.RECORD_MIN_ACTIVE_SECONDS = 15 * 60

--- Days since 1970-01-01 for a calendar date (proleptic Gregorian calendar).
---@return integer
function Stats.DayNumber(year, month, day)
	local y = month <= 2 and year - 1 or year
	local era = floor(y / 400)
	local yearOfEra = y - era * 400
	local monthFromMarch = (month + 9) % 12
	local dayOfYear = floor((153 * monthFromMarch + 2) / 5) + day - 1
	local dayOfEra = yearOfEra * 365 + floor(yearOfEra / 4) - floor(yearOfEra / 100) + dayOfYear
	return era * 146097 + dayOfEra - 719468
end

--- The calendar date of a day number.
---@return integer year
---@return integer month
---@return integer day
function Stats.DateOf(dayNumber)
	local z = dayNumber + 719468
	local era = floor(z / 146097)
	local dayOfEra = z - era * 146097
	local yearOfEra =
		floor((dayOfEra - floor(dayOfEra / 1460) + floor(dayOfEra / 36524) - floor(dayOfEra / 146096)) / 365)
	local dayOfYear = dayOfEra - (365 * yearOfEra + floor(yearOfEra / 4) - floor(yearOfEra / 100))
	local monthFromMarch = floor((5 * dayOfYear + 2) / 153)
	local day = dayOfYear - floor((153 * monthFromMarch + 2) / 5) + 1
	local month = monthFromMarch < 10 and monthFromMarch + 3 or monthFromMarch - 9
	local year = yearOfEra + era * 400 + (month <= 2 and 1 or 0)
	return year, month, day
end

--- The local-time day number of a timestamp.
---@return integer
function Stats.DayOf(timestamp)
	local t = date("*t", timestamp)
	return Stats.DayNumber(t.year, t.month, t.day)
end

--- 1 = Sunday ... 7 = Saturday (the numbering of date("*t").wday).
---@return integer
function Stats.Weekday(dayNumber)
	return (dayNumber + 4) % 7 + 1
end

--- Timestamp of local midnight at the start of a day number.
---@return integer
function Stats.MidnightOf(dayNumber)
	local year, month, day = Stats.DateOf(dayNumber)
	return time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
end

-- Session values -----------------------------------------------------------------------
-- Finished sessions are read through their scalar fields only: decoding their packed lists
-- for every session would cost time and memory for nothing.

local function RecordDuration(record)
	return math.max(0, (record.endedAt or record.startedAt) - record.startedAt)
end

local function RecordActive(record, excludeAfk)
	local duration = RecordDuration(record)
	return excludeAfk and math.max(0, duration - (record.afkSeconds or 0)) or duration
end

local function RecordValue(record, metric, excludeAfk)
	if metric == "gold" then
		return (record.money or 0) + (record.itemValue or 0)
	elseif metric == "xp" then
		return record.xp or 0
	end
	return RecordActive(record, excludeAfk)
end

--- The value of a heatmap metric ("gold", "xp" or "time") for a view (e.g. the live one).
---@return number
function Stats.MetricValue(view, metric, now, excludeAfk)
	if metric == "gold" then
		return view.money + view.itemValue
	elseif metric == "xp" then
		return view.xp
	end
	local duration = Session.Duration(view, now)
	if excludeAfk then
		return math.max(0, duration - Session.AfkSeconds(view, now))
	end
	return duration
end

-- Finished-session results depend only on history, so they're cached per revision;
-- the live session is folded in on every call.
local finishedCache = {}

local function Cached(key, build)
	local stamp = History.Revision()
	local entry = finishedCache[key]
	if entry and entry.stamp == stamp then
		return entry.value
	end
	local value = build()
	finishedCache[key] = { stamp = stamp, value = value }
	return value
end

local function LiveView(now)
	local active = Recorder.Current()
	return active and Session.LiveView(active, now)
end

--- Totals per day number for a metric, including the live session.
---@param metric "gold"|"xp"|"time"
---@return table<integer, number>
function Stats.Daily(metric, now, excludeAfk)
	local finished = Cached("daily:" .. metric .. tostring(excludeAfk), function()
		local totals = {}
		for _, record in ipairs(History.Sessions()) do
			local day = Stats.DayOf(record.startedAt)
			totals[day] = (totals[day] or 0) + RecordValue(record, metric, excludeAfk)
		end
		return totals
	end)
	local totals = {}
	for day, value in pairs(finished) do
		totals[day] = value
	end
	local live = LiveView(now)
	if live then
		local day = Stats.DayOf(live.startedAt)
		totals[day] = (totals[day] or 0) + Stats.MetricValue(live, metric, now, excludeAfk)
	end
	return totals
end

--- Quartile thresholds of the non-zero values, for colouring heatmap cells.
---@param values number[]
---@return number[] thresholds three ascending values
function Stats.Thresholds(values)
	local nonZero = {}
	for _, value in ipairs(values) do
		if value > 0 then
			nonZero[#nonZero + 1] = value
		end
	end
	table.sort(nonZero)
	local count = #nonZero
	if count == 0 then
		return {}
	end
	local thresholds = {}
	for quarter = 1, 3 do
		thresholds[quarter] = nonZero[math.max(1, math.ceil(quarter * count / 4))]
	end
	return thresholds
end

--- Heatmap intensity from 0 (no activity) to 4.
---@return integer
function Stats.Bucket(value, thresholds)
	if not value or value <= 0 or #thresholds == 0 then
		return 0
	end
	if thresholds[1] == thresholds[3] and value >= thresholds[3] then
		return 4
	end
	local level = 1
	for _, threshold in ipairs(thresholds) do
		if value > threshold then
			level = level + 1
		end
	end
	return level
end

-- Records ---------------------------------------------------------------------------

---@class SeshRecord
---@field value number
---@field id integer session id

---@class SeshRecords
---@field goldPerHour SeshRecord?
---@field xpPerHour SeshRecord?
---@field longest SeshRecord?
---@field mostKills SeshRecord?
---@field mostGold SeshRecord?

local function Consider(records, key, value, id)
	local current = records[key]
	-- Strictly greater: on ties the earlier session keeps the record.
	if value and value > 0 and (not current or value > current.value) then
		records[key] = { value = value, id = id }
	end
end

local function ConsiderSession(records, id, duration, active, gold, xp, kills)
	Consider(records, "longest", duration, id)
	Consider(records, "mostKills", kills, id)
	Consider(records, "mostGold", gold, id)
	if active >= Stats.RECORD_MIN_ACTIVE_SECONDS then
		Consider(records, "goldPerHour", gold * 3600 / active, id)
		Consider(records, "xpPerHour", xp * 3600 / active, id)
	end
end

--- Best sessions, including the live one.
---@return SeshRecords
function Stats.Records(now, excludeAfk)
	local finished = Cached("records:" .. tostring(excludeAfk), function()
		local records = {}
		for _, record in ipairs(History.Sessions()) do
			ConsiderSession(
				records,
				record.id,
				RecordDuration(record),
				RecordActive(record, excludeAfk),
				(record.money or 0) + (record.itemValue or 0),
				record.xp or 0,
				record.kills or 0
			)
		end
		return records
	end)
	local records = {}
	for key, value in pairs(finished) do
		records[key] = value
	end
	local live = LiveView(now)
	if live then
		local metrics = Session.Metrics(live, now, excludeAfk)
		ConsiderSession(
			records,
			live.id,
			metrics.duration,
			metrics.activeSeconds,
			metrics.goldEarned,
			live.xp,
			live.kills
		)
	end
	return records
end

-- Streaks and averages --------------------------------------------------------------

local function PlayedDays(now)
	local finished = Cached("days", function()
		local days = {}
		for _, record in ipairs(History.Sessions()) do
			days[Stats.DayOf(record.startedAt)] = true
		end
		return days
	end)
	local live = Recorder.Current()
	if not live then
		return finished
	end
	local days = {}
	for day in pairs(finished) do
		days[day] = true
	end
	-- A live session counts for the day it started and for today.
	days[Stats.DayOf(live.startedAt)] = true
	days[Stats.DayOf(now)] = true
	return days
end

---@class SeshStreaks
---@field current integer consecutive days played, ending today (or yesterday)
---@field longest integer

--- Daily play streaks.
---@return SeshStreaks
function Stats.Streaks(now)
	local days = PlayedDays(now)
	local today = Stats.DayOf(now)
	local current = 0
	local day = days[today] and today or today - 1
	while days[day] do
		current = current + 1
		day = day - 1
	end

	local sorted = {}
	for playedDay in pairs(days) do
		sorted[#sorted + 1] = playedDay
	end
	table.sort(sorted)
	local longest, run = 0, 0
	for index, playedDay in ipairs(sorted) do
		run = (index > 1 and playedDay == sorted[index - 1] + 1) and run + 1 or 1
		longest = math.max(longest, run)
	end
	return { current = current, longest = longest }
end

---@class SeshOverview
---@field averageSeconds number average active time per session
---@field sessionsPerWeek number
---@field firstDay integer? day number of the first session

--- Averages over all sessions, including the live one.
---@param lifetime SeshView all sessions combined (finished + live)
---@return SeshOverview
function Stats.Overview(lifetime, now, excludeAfk)
	local count = lifetime.sessionCount or 0
	local metrics = Session.Metrics(lifetime, now, excludeAfk)
	local first = History.Sessions()[1]
	local live = Recorder.Current()
	local firstStart = (first and first.startedAt) or (live and live.startedAt)
	local firstDay = firstStart and Stats.DayOf(firstStart)
	local weeks = firstDay and math.max(1, (Stats.DayOf(now) - firstDay + 1) / 7) or 1
	return {
		averageSeconds = count > 0 and metrics.activeSeconds / count or 0,
		sessionsPerWeek = count / weeks,
		firstDay = firstDay,
	}
end
