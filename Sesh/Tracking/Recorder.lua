local _, ns = ...

--- Session lifecycle.
---
--- PLAYER_LOGOUT also fires on /reload, so a session is never finalized there. Logout only
--- suspends: trackers close their timers, item values are snapshotted and lastSeenAt is
--- stamped. The decision happens at the next world entry: a reload (or a relog within the
--- resume window) continues the session; anything else finalizes it at lastSeenAt and
--- starts a new one.
---@class SeshRecorder
local Recorder = ns.Recorder
local Database = ns.Database
local Session = ns.Session
local History = ns.History
local Leveling = ns.Leveling
local Events = ns.Events

local HEARTBEAT_SECONDS = 60

---@class SeshTracker
---@field Start fun(session: table, now: integer) reads baselines when a session (re)starts
---@field Stop fun(session: table, now: integer)? flushes state when the session suspends
---@field WorldEntered fun(session: table, now: integer)? after portals and instance changes

local trackers = {} ---@type SeshTracker[]
local active ---@type table?
local begun = false
local heartbeat

--- Adds trackers; they're started and stopped with the session, in registration order.
---@param ... SeshTracker
function Recorder.Register(...)
	for index = 1, select("#", ...) do
		trackers[#trackers + 1] = select(index, ...)
	end
end

--- The active session, or nil before the first world entry (or while data is read-only).
---@return table?
function Recorder.Current()
	return active
end

local function StartTrackers(now)
	for _, tracker in ipairs(trackers) do
		tracker.Start(active, now)
	end
end

local function StopTrackers(now)
	for _, tracker in ipairs(trackers) do
		if tracker.Stop then
			tracker.Stop(active, now)
		end
	end
end

--- Moves a suspended session into history (and its last part into its level), unless
--- it's an empty blip.
local function Finalize(session, endedAt)
	local record = Session.Finalize(session, endedAt)
	local minimumSeconds = Database.Get("minSessionMinutes") * 60
	local duration = endedAt - session.startedAt
	if Session.IsEmpty(session) and duration < minimumSeconds then
		return
	end
	Leveling.Finish(session, endedAt)
	History.Add(record)
end

local function StartNew(char, now)
	active = Session.New(char.nextId, now)
	char.nextId = char.nextId + 1
	char.active = active
end

local function ShouldResume(previous, now, isReload)
	if isReload then
		return true
	end
	local gap = now - (previous.lastSeenAt or previous.startedAt)
	return gap >= 0 and gap <= Database.Get("resumeMinutes") * 60
end

--- Called on every PLAYER_ENTERING_WORLD.
---@param isInitialLogin boolean
---@param isReloadingUi boolean
function Recorder.Begin(isInitialLogin, isReloadingUi)
	local now = GetServerTime()
	if begun then
		if active then
			for _, tracker in ipairs(trackers) do
				if tracker.WorldEntered then
					tracker.WorldEntered(active, now)
				end
			end
		end
		return
	end
	begun = true

	local char = Database.Char()
	if not char then
		return
	end
	local previous = char.active
	if type(previous) == "table" and type(previous.startedAt) == "number" then
		Session.Upgrade(previous)
		if ShouldResume(previous, now, isReloadingUi and not isInitialLogin) then
			-- Time spent logged out isn't play time.
			Session.AddAfk(previous, now - (previous.lastSeenAt or now))
			active = previous
		else
			Finalize(previous, previous.lastSeenAt or previous.startedAt)
		end
	end
	if not active then
		StartNew(char, now)
	end
	active.lastSeenAt = now
	StartTrackers(now)

	-- Insurance for disconnects that save data without PLAYER_LOGOUT.
	heartbeat = C_Timer.NewTicker(HEARTBEAT_SECONDS, function()
		if active then
			active.lastSeenAt = GetServerTime()
		end
	end)
	Events.Fire("SESH_SESSION_STARTED", active)
end

--- Called at PLAYER_LOGOUT (logout or reload).
function Recorder.Suspend()
	if not active then
		return
	end
	local now = GetServerTime()
	StopTrackers(now)
	Session.CloseTimers(active, now)
	Session.SnapshotValues(active)
	active.lastSeenAt = now
	if heartbeat then
		heartbeat:Cancel()
		heartbeat = nil
	end
end

--- Ends the current session now and starts a fresh one (/sesh new).
function Recorder.Split()
	local char = Database.Char()
	if not (active and char) then
		return
	end
	local now = GetServerTime()
	StopTrackers(now)
	Session.SnapshotValues(active)
	Finalize(active, now)
	active = nil
	StartNew(char, now)
	StartTrackers(now)
	Events.Fire("SESH_SESSION_STARTED", active)
end

--- The live view of the active session.
---@return SeshView?
function Recorder.LiveView(now)
	return active and Session.LiveView(active, now or GetServerTime())
end
