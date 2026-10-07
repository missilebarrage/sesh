local _, ns = ...

--- Dungeon runs. Entering a dungeon starts a run; leaving ends it, unless the player is
--- back within 15 minutes (a corpse run after a wipe, a reload, a quick relog). Bosses
--- come from encounter events. This client has no dungeon finder and no encounter
--- journal, so nothing says when a dungeon is "complete": runs are reported with the
--- bosses killed in them.
---@class SeshDungeons : SeshTracker
local Dungeons = ns.Dungeons
local Recorder = ns.Recorder
local Session = ns.Session
local Events = ns.Events

local REENTRY_SECONDS = 15 * 60

local expiry -- ends a run the player left, once they can't come back to it anymore

--- The name of the dungeon the player is in, or nil outside dungeons.
---@return string?
function Dungeons.Current()
	local name, instanceType = GetInstanceInfo()
	if ns.Str(instanceType) ~= "party" then
		return nil
	end
	name = ns.Str(name)
	return name ~= "" and name or nil
end

local Update

local function UpdateLater()
	local session = Recorder.Current()
	if session then
		Update(session, GetServerTime())
	end
end

function Update(session, now)
	local run = session.dungeon
	if run and run.leftAt and now - run.leftAt > REENTRY_SECONDS then
		Session.EndDungeon(session, now)
	end
	local name = Dungeons.Current()
	if name then
		Session.EnterDungeon(session, name, now)
	elseif session.dungeon then
		Session.LeaveDungeon(session, now)
		-- Timers don't survive a reload, so the wait is rescheduled from when the player left.
		if expiry then
			expiry:Cancel()
		end
		local wait = REENTRY_SECONDS - (now - session.dungeon.leftAt) + 1
		expiry = C_Timer.NewTimer(math.max(1, wait), UpdateLater)
	end
end

function Dungeons.Start(session, now)
	Update(session, now)
end

function Dungeons.WorldEntered(session, now)
	Update(session, now)
end

--- At logout or reload the run is left; coming back into the dungeon continues it.
function Dungeons.Stop(session, now)
	Session.LeaveDungeon(session, now)
end

local function OnBossKill(encounterID)
	local session = Recorder.Current()
	encounterID = ns.Num(encounterID)
	if session and encounterID then
		Session.AddBossKill(session, encounterID, GetServerTime())
	end
end

Events.On("ENCOUNTER_END", function(encounterID, _, _, _, success)
	if ns.IsReadable(success) and (success == 1 or success == true) then
		OnBossKill(encounterID)
	end
end)
Events.On("BOSS_KILL", OnBossKill)
Events.On("ZONE_CHANGED_NEW_AREA", UpdateLater)
