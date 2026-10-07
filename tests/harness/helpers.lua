-- Shortcuts for driving the fake game in tests.

local Helpers = {}

local LINK = "|cffffffff|Hitem:%d::::::::10:::::::|h[Item %d]|h|r"

function Helpers.ItemLink(itemID)
	return string.format(LINK, itemID, itemID)
end

--- Adds an item to the fake item database.
function Helpers.Item(world, itemID, sellPrice, extra)
	local item = { name = "Item " .. itemID, link = Helpers.ItemLink(itemID), sellPrice = sellPrice, quality = 1 }
	for key, value in pairs(extra or {}) do
		item[key] = value
	end
	world.items[itemID] = item
	return item
end

--- Fires a loot chat message. kind: "loot" (default), "pushed" or "created".
function Helpers.Loot(world, itemID, count, kind, looterGUID)
	local env = world.env
	local single, multiple = env.LOOT_ITEM_SELF, env.LOOT_ITEM_SELF_MULTIPLE
	if kind == "pushed" then
		single, multiple = env.LOOT_ITEM_PUSHED_SELF, env.LOOT_ITEM_PUSHED_SELF_MULTIPLE
	elseif kind == "created" then
		single, multiple = env.LOOT_ITEM_CREATED_SELF, env.LOOT_ITEM_CREATED_SELF_MULTIPLE
	end
	local link = Helpers.ItemLink(itemID)
	local message = (count and count > 1) and string.format(multiple, link, count) or string.format(single, link)
	world:Fire("CHAT_MSG_LOOT", message, "Tester", "", "", "", "", 0, 0, "", 0, 1, looterGUID or world.player.guid)
end

function Helpers.GainMoney(world, copper)
	world.player.money = world.player.money + copper
	world:Fire("PLAYER_MONEY")
end

function Helpers.SetXP(world, level, xp, xpMax)
	world.player.level = level
	world.player.xp = xp
	world.player.xpMax = xpMax or world.player.xpMax
	world:Fire("PLAYER_XP_UPDATE", "player")
end

--- Puts a hostile creature on a nameplate (so its identity is cached) and returns its GUID.
function Helpers.ShowMonster(world, token, npcID, name, typeID, spawn)
	local guid = string.format("Creature-0-1-2-3-%d-%08X", npcID, spawn or 1)
	world.units[token] = { guid = guid, name = name, typeID = typeID or 7, attackable = true }
	world:Fire("NAME_PLATE_UNIT_ADDED", token)
	return guid
end

--- Kills a creature by GUID (a group member's killing blow).
function Helpers.Kill(world, guid)
	world:Fire("PARTY_KILL", world.player.guid, guid)
end

function Helpers.Session(ns)
	return ns.Recorder.Current()
end

--- A finished-session record built from a few scalar fields.
function Helpers.Record(ns, fields)
	local view = {
		kind = "session",
		id = fields.id,
		startedAt = fields.startedAt,
		endedAt = fields.endedAt or (fields.startedAt + (fields.duration or 3600)),
		afkSeconds = fields.afkSeconds or 0,
		startLevel = fields.startLevel or 10,
		endLevel = fields.endLevel or 10,
		xp = fields.xp or 0,
		money = fields.money or 0,
		itemValue = fields.itemValue or 0,
		kills = fields.kills or 0,
		unidentifiedKills = 0,
		deaths = fields.deaths or 0,
		legacy = 0,
		missed = 0,
		questCount = #(fields.quests or {}),
		dungeonCount = #(fields.dungeons or {}),
		items = fields.items or {},
		consumed = fields.consumed or {},
		monsters = fields.monsters or {},
		quests = fields.quests or {},
		zones = fields.zones or {},
		dungeons = fields.dungeons or {},
		achievements = {},
	}
	return ns.Session.ToRecord(view)
end

--- Seconds since the epoch for a local date.
function Helpers.LocalTime(year, month, day, hour, minute)
	return os.time({ year = year, month = month, day = day, hour = hour or 12, min = minute or 0, sec = 0 })
end

return Helpers
