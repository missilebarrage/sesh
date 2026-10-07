local _, ns = ...

--- Monster kills.
---
--- The combat log is closed to addons on this client. PARTY_KILL(attackerGUID, targetGUID)
--- fires for every killing blow by you or your group. Who died is found, in order, from a
--- cache of units seen on nameplates, target and mouseover, from a unit token the corpse
--- still has, from earlier kills of the same creature, and from the client's tooltip for
--- the creature. Kills nobody can identify are resolved by the "X dies, you gain N
--- experience" message arriving within a second:
---  * a visible creature that stays unknown isn't counted (it's usually a critter caught in
---    an area attack), unless the experience message names it;
---  * a creature the game hides (restricted content) is always counted, named by the
---    experience message when there is one and "Unidentified" otherwise.
--- If PARTY_KILL can't be registered at all, experience messages are the kill signal.
---@class SeshKills
local Kills = ns.Kills
local Recorder = ns.Recorder
local Session = ns.Session
local Events = ns.Events

local IDENTITY_LIMIT = 300
local PAIRING_SECONDS = 1

-- Creature types that aren't monsters: critter, totem, non-combat pet, gas cloud, wild pet.
local IGNORED_CREATURE_TYPES = { [8] = true, [11] = true, [12] = true, [13] = true, [14] = true }

---@class SeshIdentity
---@field name string?
---@field npcID integer?
---@field typeID integer?

local identities = {} ---@type table<string, SeshIdentity>
local identityCount = 0
local npcIdentities = {} ---@type table<integer, SeshIdentity> by creature id, for later spawns
local awaitingNames = {} ---@type {at: number, npcID: integer?, hidden: boolean}[]
local unclaimedXpNames = {} ---@type {at: number, name: string}[]
local recentNamedKills = {} ---@type {at: number, name: string}[]
local partyKillAvailable = false
local creatureTypeNames ---@type table<string, integer>? localized type name -> type id

local xpPattern, xpOrder
if type(COMBATLOG_XPGAIN_FIRSTPERSON) == "string" then
	-- Unanchored at the end: rested and group bonuses append text to the message.
	xpPattern, xpOrder = ns.FormatPattern(COMBATLOG_XPGAIN_FIRSTPERSON, false)
end

--- "Creature-0-1-2-3-589-000ABC" -> 589; nil for players, pets and malformed GUIDs.
---@param guid string
---@return integer?
function Kills.NpcID(guid)
	local unitType, _, _, _, _, npcID = strsplit("-", guid)
	if unitType == "Creature" or unitType == "Vehicle" then
		return tonumber(npcID)
	end
end

--- Decides how a PARTY_KILL counts.
---@param evidence {readable: boolean, unitType: string?, typeID: integer?, inPvP: boolean}
---@return "monster"|"unidentified"|nil verdict nil when the kill isn't a monster
function Kills.Classify(evidence)
	if not evidence.readable then
		-- In battlegrounds and arenas an unreadable target is most likely a player.
		return not evidence.inPvP and "unidentified" or nil
	end
	if evidence.unitType ~= "Creature" and evidence.unitType ~= "Vehicle" then
		return nil
	end
	if evidence.typeID and IGNORED_CREATURE_TYPES[evidence.typeID] then
		return nil
	end
	return "monster"
end

-- Identities -------------------------------------------------------------------------------

---@return SeshIdentity
local function Store(guid, name, typeID)
	if identityCount >= IDENTITY_LIMIT then
		wipe(identities)
		identityCount = 0
	end
	local npcID = Kills.NpcID(guid)
	local identity = { name = name, npcID = npcID, typeID = typeID }
	identities[guid] = identity
	identityCount = identityCount + 1
	if npcID then
		npcIdentities[npcID] = identity
	end
	return identity
end

---@return SeshIdentity?
local function Capture(unit, guid)
	local name = ns.Str((UnitName(unit)))
	if not name then
		return nil
	end
	local _, typeID = UnitCreatureType(unit)
	return Store(guid, name, ns.Num(typeID))
end

--- Caches who a hostile unit is while its identity is readable.
---@param unit string
function Kills.Remember(unit)
	local guid = ns.Str(UnitGUID(unit))
	if not guid or identities[guid] then
		return
	end
	if UnitPlayerControlled(unit) or not UnitCanAttack("player", unit) then
		return
	end
	Capture(unit, guid)
end

-- Some unit functions reject nameplate tokens in PvP instances; a failed lookup only
-- means the unit isn't cached.
local function SafeRemember(unit)
	unit = ns.Str(unit)
	if unit then
		pcall(Kills.Remember, unit)
	end
end

local function CreatureTypeNames()
	if not creatureTypeNames then
		creatureTypeNames = {}
		local ids = C_CreatureInfo.GetCreatureTypeIDs and C_CreatureInfo.GetCreatureTypeIDs()
		for _, typeID in ipairs(ids or {}) do
			local info = C_CreatureInfo.GetCreatureTypeInfo(typeID)
			local name = info and ns.Str(info.name)
			if name and name ~= "" then
				creatureTypeNames[name] = typeID
			end
		end
	end
	return creatureTypeNames
end

local function TypeFromLines(lines)
	for index = 2, #lines do
		local text = type(lines[index]) == "table" and ns.Str(lines[index].leftText)
		if text then
			for typeName, typeID in pairs(CreatureTypeNames()) do
				if text:find(typeName, 1, true) then
					return typeID
				end
			end
		end
	end
end

--- Last resort for creatures never seen on a nameplate, target or mouseover: the client's
--- tooltip for the creature ("Name" / "Level 5 Beast").
---@return SeshIdentity?
local function TooltipIdentity(guid)
	if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then
		return nil
	end
	local ok, data = pcall(C_TooltipInfo.GetHyperlink, "unit:" .. guid)
	local lines = ok and type(data) == "table" and data.lines
	if type(lines) ~= "table" or type(lines[1]) ~= "table" then
		return nil
	end
	local name = ns.Str(lines[1].leftText)
	if not name or name == "" then
		return nil
	end
	ns.Count("tooltipIdentified")
	return Store(guid, name, TypeFromLines(lines))
end

---@param guid string
---@return SeshIdentity?
local function Identify(guid)
	local identity = identities[guid]
	if identity then
		return identity
	end
	-- The unit may still have a token (target, nameplate) at the moment it dies.
	local token = ns.Str(UnitTokenFromGUID(guid))
	if token then
		local ok, captured = pcall(Capture, token, guid)
		if ok and captured then
			return captured
		end
	end
	local npcID = Kills.NpcID(guid)
	return (npcID and npcIdentities[npcID]) or TooltipIdentity(guid)
end

-- Pairing with experience messages ----------------------------------------------------------

local function Prune(queue, now)
	while queue[1] and now - queue[1].at > PAIRING_SECONDS do
		table.remove(queue, 1)
	end
end

local function TakeIf(queue, now, name)
	Prune(queue, now)
	for index, entry in ipairs(queue) do
		if not name or entry.name == name then
			return table.remove(queue, index)
		end
	end
end

--- Settles kills whose wait for a name ran out.
local function FlushAwaitingNames()
	local now = GetTime()
	local session = Recorder.Current()
	while awaitingNames[1] and now - awaitingNames[1].at >= PAIRING_SECONDS do
		local kill = table.remove(awaitingNames, 1)
		if kill.hidden then
			if session then
				Session.AddKill(session, nil)
			end
		else
			ns.Count("unknownKillsSkipped")
		end
	end
end

local function RecordNamedKill(session, name, npcID, typeID)
	Session.AddKill(session, name, npcID, typeID)
	recentNamedKills[#recentNamedKills + 1] = { at = GetTime(), name = name }
	Prune(recentNamedKills, GetTime())
end

local function OnPartyKill(_, targetGUID)
	local session = Recorder.Current()
	if not session then
		return
	end
	ns.Count("partyKills")
	local guid = ns.Str(targetGUID)
	local identity = guid and Identify(guid)
	local _, instanceType = IsInInstance()
	local verdict = Kills.Classify({
		readable = guid ~= nil,
		unitType = guid and guid:match("^(%a+)%-"),
		typeID = identity and identity.typeID,
		inPvP = instanceType == "pvp" or instanceType == "arena",
	})
	if not verdict then
		return
	end
	local npcID = guid and Kills.NpcID(guid)
	if identity and identity.name then
		RecordNamedKill(session, identity.name, npcID, identity.typeID)
		return
	end
	ns.Count("unnamedKills")
	-- The experience message may already be here...
	local now = GetTime()
	local unclaimed = TakeIf(unclaimedXpNames, now)
	if unclaimed then
		RecordNamedKill(session, unclaimed.name, npcID, nil)
		return
	end
	-- ...or arrive in a moment.
	awaitingNames[#awaitingNames + 1] = { at = now, npcID = npcID, hidden = verdict == "unidentified" }
	C_Timer.After(PAIRING_SECONDS, FlushAwaitingNames)
end

--- Extracts the monster name from an "X dies, you gain N experience" message.
---@param message string
---@return string?
function Kills.ParseXpKill(message)
	if xpPattern then
		return (ns.MatchFormat(message, xpPattern, xpOrder))
	end
end

local function OnXpMessage(message)
	local session = Recorder.Current()
	message = ns.Str(message)
	if not (session and message) then
		return
	end
	local name = Kills.ParseXpKill(message)
	if not name or name == "" then
		return
	end
	ns.Count("xpKills")
	if not partyKillAvailable then
		Session.AddKill(session, name)
		return
	end
	-- Settle kills that waited too long, so a late message can't name an old kill.
	FlushAwaitingNames()
	local now = GetTime()
	local waiting = table.remove(awaitingNames, 1)
	if waiting then
		RecordNamedKill(session, name, waiting.npcID, nil)
	elseif not TakeIf(recentNamedKills, now, name) then
		-- No kill to attach the name to yet; its PARTY_KILL may still be on the way.
		unclaimedXpNames[#unclaimedXpNames + 1] = { at = now, name = name }
		Prune(unclaimedXpNames, now)
	end
end

--- Whether PARTY_KILL is available (otherwise kills come from experience messages).
---@return boolean
function Kills.UsesPartyKill()
	return partyKillAvailable
end

partyKillAvailable = Events.On("PARTY_KILL", OnPartyKill)
Events.On("CHAT_MSG_COMBAT_XP_GAIN", OnXpMessage)
Events.On("NAME_PLATE_UNIT_ADDED", SafeRemember)
Events.On("PLAYER_TARGET_CHANGED", function()
	SafeRemember("target")
end)
Events.On("UPDATE_MOUSEOVER_UNIT", function()
	SafeRemember("mouseover")
end)
