local _, ns = ...

--- Time spent in each zone (dungeons count as their own zone) and AFK periods.
---@class SeshActivity : SeshTracker
local Activity = ns.Activity
local Recorder = ns.Recorder
local Session = ns.Session
local Events = ns.Events

local INSTANCE_KINDS = {
	party = Session.ZONE_DUNGEON,
	raid = Session.ZONE_RAID,
	pvp = Session.ZONE_PVP,
	arena = Session.ZONE_PVP,
}

--- The zone the player is in: its name and kind (Session.ZONE_*), or nil while loading.
---@return string? name
---@return integer kind
function Activity.CurrentZone()
	local name = ns.Str(GetRealZoneText())
	if not name or name == "" then
		return nil, Session.ZONE_WORLD
	end
	local inInstance, instanceType = IsInInstance()
	if not inInstance then
		return name, Session.ZONE_WORLD
	end
	return name, INSTANCE_KINDS[instanceType] or Session.ZONE_OTHER
end

local ZONE_RETRY_SECONDS = 1
local ZONE_RETRIES = 5

local function UpdateZone(session, now)
	local name, kind = Activity.CurrentZone()
	if name then
		Session.EnterZone(session, name, kind, now)
	end
	return name ~= nil
end

-- Right after logging in the zone name can still be empty, and no zone event follows
-- until the player moves to another zone: retry a few times.
local function UpdateZoneSoon(attempt)
	C_Timer.After(ZONE_RETRY_SECONDS, function()
		local session = ns.Recorder.Current()
		if
			session
			and not session.zoneSince
			and not UpdateZone(session, GetServerTime())
			and attempt < ZONE_RETRIES
		then
			UpdateZoneSoon(attempt + 1)
		end
	end)
end

local function UpdateAfk(session, now)
	local isAfk = UnitIsAFK("player")
	-- AFK state can be secret during chat lockdown; keep the last known state then.
	if not ns.IsReadable(isAfk) then
		return
	end
	Session.SetAfk(session, isAfk == true, now)
end

function Activity.Start(session, now)
	if not UpdateZone(session, now) then
		UpdateZoneSoon(1)
	end
	UpdateAfk(session, now)
end

function Activity.WorldEntered(session, now)
	UpdateZone(session, now)
end

Events.On("ZONE_CHANGED_NEW_AREA", function()
	local session = Recorder.Current()
	if session then
		UpdateZone(session, GetServerTime())
	end
end)

Events.On("PLAYER_FLAGS_CHANGED", function(unit)
	local session = Recorder.Current()
	if session and ns.Str(unit) == "player" then
		UpdateAfk(session, GetServerTime())
	end
end)
