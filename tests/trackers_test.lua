local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Income", function()
	it("counts money gained and ignores money spent", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 1500)
		Helpers.GainMoney(world, -400)
		Helpers.GainMoney(world, 100)
		expect(Helpers.Session(ns).money).toBe(1600)
	end)

	it("ignores money from vendors, mail and trades, including just after closing", function()
		local world, ns = Harness.Boot()
		world:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5) -- merchant
		Helpers.GainMoney(world, 1000)
		world:Fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 5)
		Helpers.GainMoney(world, 200)
		world:Advance(3)
		Helpers.GainMoney(world, 300)
		world:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 3) -- quest giver: counts
		Helpers.GainMoney(world, 50)
		expect(Helpers.Session(ns).money).toBe(350)
	end)

	it("records looted and pushed items but not crafted ones or other players' loot", function()
		local world, ns = Harness.Boot()
		Helpers.Loot(world, 2589, 3)
		Helpers.Loot(world, 2589)
		Helpers.Loot(world, 6948, 1, "pushed")
		Helpers.Loot(world, 2581, 5, "created")
		Helpers.Loot(world, 4306, 2, "loot", "Player-1-0000BBBB")
		expect(Helpers.Session(ns).items).toEqual({ [2589] = 4, [6948] = 1 })
	end)

	it("ignores purchases at a vendor", function()
		local world, ns = Harness.Boot()
		world:Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 5)
		Helpers.Loot(world, 159, 5, "pushed")
		Helpers.Loot(world, 2589, 1)
		expect(Helpers.Session(ns).items).toEqual({ [2589] = 1 })
	end)

	it("skips loot messages it can't read", function()
		local world, ns = Harness.Boot()
		world:Fire("CHAT_MSG_LOOT", Harness.SECRET)
		expect(Helpers.Session(ns).items).toEqual({})
		expect(world.errors).toEqual({})
	end)
end)

describe("Item conversions", function()
	local GREEN, BLUE, DUST, CLAM, MEAT, BOX = 2000, 2001, 10940, 5523, 5503, 4632

	local function Setup(options)
		options = options or {}
		options.auctionator = true
		local world, ns = Harness.Boot(options)
		Helpers.Item(world, GREEN, 30, { bindType = 1 })
		Helpers.Item(world, BLUE, 40, { bindType = 2 })
		Helpers.Item(world, DUST, 0)
		Helpers.Item(world, CLAM, 0)
		Helpers.Item(world, MEAT, 5)
		Helpers.Item(world, BOX, 0)
		world.auctionPrices[DUST] = 25
		world.auctionPrices[BLUE] = 900
		world.itemGUIDs["Item-1-0-0000000000AA"] = GREEN
		world.itemGUIDs["Item-1-0-0000000000BB"] = CLAM
		world.itemGUIDs["Item-1-0-0000000000CC"] = BOX
		world.itemGUIDs["Item-1-0-0000000000DD"] = BLUE
		return world, ns
	end

	-- A loot window from an item (a disenchant or a container), then what it held.
	local function LootFromItem(world, guid, loot)
		world.lootSources = { guid }
		world:Fire("LOOT_OPENED", true, true)
		for _, entry in ipairs(loot) do
			if entry.money then
				Helpers.GainMoney(world, entry.money)
			else
				Helpers.Loot(world, entry[1], entry[2])
			end
		end
		world:Fire("LOOT_CLOSED")
		world.lootSources = {}
	end

	local function Metrics(ns, world)
		return ns.Session.Metrics(ns.Recorder.LiveView(), world.clock.server, true)
	end

	it("counts what an item turned into and takes the item off as used up", function()
		local world, ns = Setup()
		Helpers.Loot(world, GREEN)
		Helpers.Loot(world, GREEN)
		LootFromItem(world, "Item-1-0-0000000000AA", { { DUST, 2 } })
		local session = Helpers.Session(ns)
		expect(session.items).toEqual({ [GREEN] = 2, [DUST] = 2 })
		expect(session.consumed).toEqual({ [GREEN] = 1 })
		local metrics = Metrics(ns, world)
		expect(metrics.itemsAcquiredValue).toBe(2 * 30 + 2 * 25)
		expect(metrics.itemsUsedValue).toBe(30)
		expect(metrics.itemValue).toBe(30 + 2 * 25)
		-- Loot from monsters counts as usual again.
		world:Fire("LOOT_OPENED", true, false)
		Helpers.Loot(world, DUST)
		expect(session.items[DUST]).toBe(3)
		expect(session.consumed).toEqual({ [GREEN] = 1 })
	end)

	it("shows what disenchanting earlier loot earned, minus that loot's value", function()
		local world, ns = Setup()
		-- Next morning: greens from yesterday's session (counted then) turn into dust today.
		for _ = 1, 3 do
			LootFromItem(world, "Item-1-0-0000000000AA", { { DUST, 2 } })
		end
		local metrics = Metrics(ns, world)
		expect(metrics.itemsAcquiredValue).toBe(6 * 25)
		expect(metrics.itemsUsed).toBe(3)
		expect(metrics.itemValue).toBe(6 * 25 - 3 * 30)
		expect(metrics.goldEarned).toBe(60)
	end)

	it("shows a loss when something worth more than its dust is used up", function()
		local world, ns = Setup()
		LootFromItem(world, "Item-1-0-0000000000DD", { { DUST, 2 } })
		local metrics = Metrics(ns, world)
		expect(metrics.itemValue).toBe(50 - 900)
		expect(ns.Format.MoneyText(metrics.goldEarned)).toBe("-8s 50c")
	end)

	it("counts a container's coins and items, with the container used up", function()
		local world, ns = Setup()
		Helpers.Loot(world, BOX)
		Helpers.Loot(world, CLAM, 2)
		LootFromItem(world, "Item-1-0-0000000000CC", { { money = 250 }, { MEAT, 1 } })
		LootFromItem(world, "Item-1-0-0000000000BB", { { MEAT, 1 } })
		local session = Helpers.Session(ns)
		expect(session.items).toEqual({ [BOX] = 1, [CLAM] = 2, [MEAT] = 2 })
		expect(session.consumed).toEqual({ [BOX] = 1, [CLAM] = 1 })
		expect(session.money).toBe(250)
	end)

	it("uses nothing up when the loot window closes without looting", function()
		local world, ns = Setup()
		Helpers.Loot(world, CLAM)
		LootFromItem(world, "Item-1-0-0000000000BB", {})
		expect(Helpers.Session(ns).consumed).toEqual({})
	end)

	it("treats loot arriving just after the window closed as part of it", function()
		local world, ns = Setup()
		LootFromItem(world, "Item-1-0-0000000000AA", {})
		world:Advance(0.5)
		Helpers.Loot(world, DUST)
		world:Advance(1)
		Helpers.Loot(world, DUST)
		local session = Helpers.Session(ns)
		expect(session.items).toEqual({ [DUST] = 2 })
		expect(session.consumed).toEqual({ [GREEN] = 1 })
	end)

	it("finds the item from its bag lock when the client doesn't name the loot source", function()
		local world, ns = Setup({ noLootSources = true })
		world.bags[0] = { [3] = { itemID = GREEN, locked = true } }
		world:Fire("ITEM_LOCK_CHANGED", 0, 3)
		world:Advance(3) -- the disenchant cast
		LootFromItem(world, nil, { { DUST, 1 } })
		expect(Helpers.Session(ns).consumed).toEqual({ [GREEN] = 1 })
	end)

	it("doesn't take an item that was only moved for the loot source", function()
		local world, ns = Setup({ noLootSources = true })
		world.bags[0] = { [3] = { itemID = GREEN, locked = true } }
		world:Fire("ITEM_LOCK_CHANGED", 0, 3)
		world.bags[0][3].locked = false
		world:Fire("ITEM_LOCK_CHANGED", 0, 3)
		LootFromItem(world, nil, { { DUST, 1 } })
		local session = Helpers.Session(ns)
		expect(session.items).toEqual({ [DUST] = 1 })
		expect(session.consumed).toEqual({})
	end)

	it("keeps used-up items in finished sessions, totals and levels", function()
		local world, ns = Setup()
		Helpers.Loot(world, GREEN)
		Helpers.SetXP(world, 11, 0, 1100)
		LootFromItem(world, "Item-1-0-0000000000AA", { { DUST, 2 } })
		world:Advance(600)
		-- The green counts at level 10, the dust minus the green at level 11: 50 in all.
		expect(ns.Leveling.Records()[10].itemValue).toBe(30)
		expect(ns.Leveling.View(11, world.clock.server).itemValue).toBe(50 - 30)

		local _, laterNs = Harness.Restart(world, { gap = 3600 })
		local record = laterNs.History.Get(1)
		expect(record.itemValue).toBe(30 + 50 - 30)
		local view = laterNs.Session.View(record)
		expect(view.consumed).toEqual({ { itemID = GREEN, count = 1, unitValue = 30, value = 30 } })
		expect(laterNs.History.Lifetime().itemValue).toBe(50)
		expect(laterNs.Session.Metrics(view, 0, true).itemsUsedValue).toBe(30)
	end)
end)

describe("Progress", function()
	it("counts experience within a level and across level-ups", function()
		local world, ns = Harness.Boot()
		Helpers.SetXP(world, 10, 400, 1000)
		Helpers.SetXP(world, 11, 150, 1200)
		local session = Helpers.Session(ns)
		expect(session.xp).toBe(300 + 600 + 150)
		expect(session.startLevel).toBe(10)
		expect(session.endLevel).toBe(11)
	end)

	it("counts a level-up once when experience updates before the level", function()
		local world, ns = Harness.Boot()
		Helpers.SetXP(world, 10, 900, 1000)
		-- The kill's 300 XP: experience wraps first, the level follows.
		world.player.xp, world.player.xpMax = 200, 1100
		world:Fire("PLAYER_XP_UPDATE", "player")
		world.player.level = 11
		world:Fire("PLAYER_LEVEL_UP", 11)
		world:Fire("PLAYER_XP_UPDATE", "player")
		expect(Helpers.Session(ns).xp).toBe(800 + 300)
	end)

	it("counts a level-up once when the level updates before experience", function()
		local world, ns = Harness.Boot()
		Helpers.SetXP(world, 10, 900, 1000)
		world.player.level = 11
		world:Fire("PLAYER_LEVEL_UP", 11)
		world.player.xp, world.player.xpMax = 200, 1100
		world:Fire("PLAYER_XP_UPDATE", "player")
		expect(Helpers.Session(ns).xp).toBe(800 + 300)
	end)

	it("ignores experience updates for other units", function()
		local world, ns = Harness.Boot()
		world.player.xp = 900
		world:Fire("PLAYER_XP_UPDATE", "party1")
		expect(Helpers.Session(ns).xp).toBe(0)
	end)

	it("records quests, deaths and achievements", function()
		local world, ns = Harness.Boot()
		world.quests[176] = "Wanted: Hogger"
		world:Fire("QUEST_TURNED_IN", 176, 450, 1200)
		world:Fire("PLAYER_DEAD")
		world:Fire("ACHIEVEMENT_EARNED", 5000, false)
		world:Fire("ACHIEVEMENT_EARNED", 5001, true)
		local session = Helpers.Session(ns)
		expect(session.quests).toEqual({ { questID = 176, title = "Wanted: Hogger", xp = 450, money = 1200 } })
		expect(session.deaths).toBe(1)
		expect(session.achievements).toEqual({ 5000 })
	end)

	it("counts Legacy Points earned from the shared pool", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.legacy = { quantity = 3, spent = 10 }
			end,
		})
		world.legacy.quantity = 1
		world.legacy.spent = 14 -- spending doesn't change the total
		world:Fire("TRAIT_TREE_CURRENCY_INFO_UPDATED", 1189)
		world:Advance(2)
		expect(Helpers.Session(ns).legacy).toBe(2)
	end)

	it("takes the Legacy Points baseline when trait data loads after login", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.legacy = { quantity = 4, spent = 6 }
				w.legacyConfigID = nil
			end,
		})
		world.legacyConfigID = 501
		world:Fire("TRAIT_CONFIG_LIST_UPDATED")
		world.legacy.quantity = 7
		world:Fire("TRAIT_TREE_CURRENCY_INFO_UPDATED", 1189)
		world:Advance(2)
		expect(Helpers.Session(ns).legacy).toBe(3)
	end)
end)

describe("Activity", function()
	it("retries reading the zone when it isn't known yet at login", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.zone = { name = "", instanceType = "none" }
			end,
		})
		expect(Helpers.Session(ns).zone).toBeNil()
		world.zone = { name = "Elwynn Forest", instanceType = "none" }
		world:Advance(1)
		expect(Helpers.Session(ns).zone).toBe("Elwynn Forest")
	end)

	it("times each zone and dungeon", function()
		local world, ns = Harness.Boot()
		world:Advance(600)
		world.zone = { name = "The Deadmines", instanceType = "party" }
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
		world:Advance(900)
		local view = ns.Recorder.LiveView()
		expect(view.zones[1]).toEqual({ name = "The Deadmines", kind = ns.Session.ZONE_DUNGEON, seconds = 900 })
		expect(view.zones[2]).toEqual({ name = "Elwynn Forest", kind = ns.Session.ZONE_WORLD, seconds = 600 })
	end)

	it("tracks AFK time and keeps the last state when it can't be read", function()
		local world, ns = Harness.Boot()
		world.player.afk = true
		world:Fire("PLAYER_FLAGS_CHANGED", "player")
		world:Advance(300)
		world.player.afk = Harness.SECRET
		world:Fire("PLAYER_FLAGS_CHANGED", "player")
		world:Advance(100)
		world.player.afk = false
		world:Fire("PLAYER_FLAGS_CHANGED", "player")
		expect(Helpers.Session(ns).afkSeconds).toBe(400)
	end)
end)

describe("Kills", function()
	it("names kills from units seen on nameplates", function()
		local world, ns = Harness.Boot()
		local wolf = Helpers.ShowMonster(world, "nameplate1", 69, "Timber Wolf", 1)
		local thug = Helpers.ShowMonster(world, "nameplate2", 38, "Defias Thug", 7)
		Helpers.Kill(world, wolf)
		Helpers.Kill(world, thug)
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate3", 69, "Timber Wolf", 1, 2))
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(3)
		expect(view.monsters[1]).toEqual({ name = "Timber Wolf", count = 2, npcID = 69, typeID = 1 })
		expect(view.monsters[2].name).toBe("Defias Thug")
	end)

	it("doesn't count critters, players or pets", function()
		local world, ns = Harness.Boot()
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 721, "Rabbit", 8))
		Helpers.Kill(world, "Player-1-0000CCCC")
		Helpers.Kill(world, "Pet-0-1-2-3-4-0000")
		expect(Helpers.Session(ns).kills).toBe(0)
	end)

	it("classifies kills", function()
		local _, ns = Harness.Load()
		local Classify = ns.Kills.Classify
		expect(Classify({ readable = true, unitType = "Creature", typeID = 7 })).toBe("monster")
		expect(Classify({ readable = true, unitType = "Vehicle" })).toBe("monster")
		expect(Classify({ readable = true, unitType = "Creature", typeID = 11 })).toBeNil()
		expect(Classify({ readable = true, unitType = "Player" })).toBeNil()
		expect(Classify({ readable = false, inPvP = false })).toBe("unidentified")
		expect(Classify({ readable = false, inPvP = true })).toBeNil()
	end)

	it("names a hidden kill from the experience message that follows it", function()
		local world, ns = Harness.Boot()
		world:Fire("PARTY_KILL", world.player.guid, Harness.SECRET)
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Pillager dies, you gain 120 experience.")
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(1)
		expect(view.monsters[1].name).toBe("Defias Pillager")
		expect(view.unidentifiedKills).toBe(0)
	end)

	it("names a hidden kill from an experience message that arrived first", function()
		local world, ns = Harness.Boot()
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Pillager dies, you gain 120 experience. (+60 exp Rested bonus)")
		world:Fire("PARTY_KILL", world.player.guid, Harness.SECRET)
		expect(ns.Recorder.LiveView().monsters[1].name).toBe("Defias Pillager")
	end)

	it("counts hidden kills without a matching message as unidentified", function()
		local world, ns = Harness.Boot()
		world:Fire("PARTY_KILL", world.player.guid, Harness.SECRET)
		expect(Helpers.Session(ns).kills).toBe(0)
		world:Advance(1.5)
		local session = Helpers.Session(ns)
		expect(session.kills).toBe(1)
		expect(session.unidentifiedKills).toBe(1)
	end)

	it("doesn't double count named kills that also give experience", function()
		local world, ns = Harness.Boot()
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 589, "Defias Pillager", 7))
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Pillager dies, you gain 120 experience.")
		world:Fire("PARTY_KILL", world.player.guid, Harness.SECRET)
		world:Advance(2)
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(2)
		expect(view.monsters[1].count).toBe(1)
		expect(view.unidentifiedKills).toBe(1)
	end)

	it("doesn't count an unknown visible creature without an experience message", function()
		local world, ns = Harness.Boot()
		Helpers.Kill(world, "Creature-0-1-2-3-721-000001")
		world:Advance(1.5)
		expect(Helpers.Session(ns).kills).toBe(0)
	end)

	it("counts an unknown visible creature that an experience message names", function()
		local world, ns = Harness.Boot()
		Helpers.Kill(world, "Creature-0-1-2-3-46-000001")
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Murloc Forager dies, you gain 60 experience.")
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(1)
		expect(view.monsters[1]).toEqual({ name = "Murloc Forager", count = 1, npcID = 46 })
	end)

	it("identifies creatures from their tooltip and still skips critters", function()
		local world, ns = Harness.Boot()
		local rabbit = "Creature-0-1-2-3-721-000002"
		local kobold = "Creature-0-1-2-3-40-000003"
		world.tooltips[rabbit] = { { leftText = "Rabbit" }, { leftText = "Level 1 Critter" } }
		world.tooltips[kobold] = { { leftText = "Kobold Miner" }, { leftText = "Level 5 Humanoid" } }
		Helpers.Kill(world, rabbit)
		Helpers.Kill(world, kobold)
		world:Advance(1.5)
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(1)
		expect(view.monsters[1]).toEqual({ name = "Kobold Miner", count = 1, npcID = 40, typeID = 7 })
		-- Later spawns of the same creature are known by their creature id.
		Helpers.Kill(world, "Creature-0-1-2-3-40-000004")
		expect(ns.Recorder.LiveView().monsters[1].count).toBe(2)
	end)

	it("ignores nameplate tokens the game refuses to look up", function()
		local world, ns = Harness.Boot()
		world.units.nameplate1 = { guid = "Creature-0-1-2-3-9-000001", name = "Guard", attackable = true }
		world.unitErrors.nameplate1 = true
		world:Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
		expect(world.errors).toEqual({})
		expect(Helpers.Session(ns).kills).toBe(0)
	end)

	it("doesn't give a late experience message to a kill that waited too long", function()
		local world, ns = Harness.Boot()
		world:Fire("PARTY_KILL", world.player.guid, Harness.SECRET)
		-- Time passes without the timers running (a busy frame).
		world.clock.uptime = world.clock.uptime + 2
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Pillager dies, you gain 120 experience.")
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(1)
		expect(view.unidentifiedKills).toBe(1)
		expect(#view.monsters).toBe(0)
	end)

	it("skips hidden targets in battlegrounds", function()
		local world, ns = Harness.Boot()
		world.zone = { name = "Warsong Gulch", instanceType = "pvp" }
		world:Fire("PARTY_KILL", world.player.guid, Harness.SECRET)
		world:Advance(2)
		expect(Helpers.Session(ns).kills).toBe(0)
	end)

	it("falls back to experience messages when PARTY_KILL doesn't exist", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.unknownEvents.PARTY_KILL = true
			end,
		})
		expect(ns.Kills.UsesPartyKill()).toBe(false)
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "Kobold Vermin dies, you gain 45 experience.")
		world:Fire("CHAT_MSG_COMBAT_XP_GAIN", "You gain 300 experience.")
		local view = ns.Recorder.LiveView()
		expect(view.kills).toBe(1)
		expect(view.monsters[1].name).toBe("Kobold Vermin")
	end)
end)

describe("Dungeons", function()
	local function Enter(world, name)
		world.zone = { name = name, instanceType = "party" }
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
	end

	local function Leave(world)
		world.zone = { name = "Westfall", instanceType = "none" }
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
	end

	it("records a run with its bosses, counting each boss once", function()
		local world, ns = Harness.Boot()
		Enter(world, "The Deadmines")
		world:Advance(600)
		world:Fire("ENCOUNTER_END", 2741, "Rhahk'Zor", 1, 5, 1)
		world:Fire("BOSS_KILL", 2741, "Rhahk'Zor")
		world:Fire("ENCOUNTER_END", 2742, "Sneed", 1, 5, 0) -- a wipe
		world:Fire("ENCOUNTER_END", 2742, "Sneed", 1, 5, 1)
		world:Advance(1200)
		Leave(world)
		local session = Helpers.Session(ns)
		expect(session.dungeon.bosses).toBe(2)
		expect(#session.dungeons).toBe(0)
		local live = ns.Recorder.LiveView()
		expect(live.currentDungeon.name).toBe("The Deadmines")
		-- The run ends once the player can't come back to it anymore.
		world:Advance(15 * 60 + 2)
		expect(session.dungeon).toBeNil()
		expect(session.dungeons).toEqual({
			{ name = "The Deadmines", startedAt = world.clock.server - 15 * 60 - 2 - 1800, seconds = 1800, bosses = 2 },
		})
	end)

	it("continues a run after a corpse run and a reload", function()
		local world = Harness.Boot()
		Enter(world, "Wailing Caverns")
		world:Fire("ENCOUNTER_END", 585, "Lady Anacondra", 1, 5, 1)
		world:Advance(900)
		Leave(world)
		world:Advance(300)
		Enter(world, "Wailing Caverns")
		world:Advance(300)
		local reloaded, reloadedNs = Harness.Restart(world, { reload = true })
		reloaded:Fire("ENCOUNTER_END", 586, "Lord Cobrahn", 1, 5, 1)
		local session = Helpers.Session(reloadedNs)
		expect(session.dungeon.bosses).toBe(2)
		expect(session.dungeon.leftAt).toBeNil()
		expect(#session.dungeons).toBe(0)
		expect(reloaded.errors).toEqual({})
	end)

	it("ends a run left before a reload once the player can't come back", function()
		local world = Harness.Boot()
		Enter(world, "The Deadmines")
		world:Fire("ENCOUNTER_END", 2741, "Rhahk'Zor", 1, 5, 1)
		world:Advance(600)
		Leave(world)
		world:Advance(60)
		local reloaded, reloadedNs = Harness.Restart(world, { reload = true })
		reloaded:Advance(15 * 60)
		local session = Helpers.Session(reloadedNs)
		expect(session.dungeon).toBeNil()
		expect(#session.dungeons).toBe(1)
		expect(session.dungeons[1].seconds).toBe(600)
	end)

	it("counts a reset and another clear as two runs", function()
		local world, ns = Harness.Boot()
		Enter(world, "The Deadmines")
		world:Fire("ENCOUNTER_END", 2741, "Rhahk'Zor", 1, 5, 1)
		world:Advance(1200)
		Leave(world)
		world:Advance(60)
		Enter(world, "The Deadmines")
		world:Fire("ENCOUNTER_END", 2741, "Rhahk'Zor", 1, 5, 1)
		world:Fire("BOSS_KILL", 2741, "Rhahk'Zor")
		local session = Helpers.Session(ns)
		expect(#session.dungeons).toBe(1)
		expect(session.dungeons[1].bosses).toBe(1)
		expect(session.dungeons[1].seconds).toBe(1200)
		expect(session.dungeon.bosses).toBe(1)
	end)

	it("forgets a quick visit without bosses", function()
		local world, ns = Harness.Boot()
		Enter(world, "Ragefire Chasm")
		world:Advance(90)
		Leave(world)
		world:Advance(16 * 60)
		local session = Helpers.Session(ns)
		expect(session.dungeon).toBeNil()
		expect(session.dungeons).toEqual({})
	end)

	it("ends the run when the session ends", function()
		local world = Harness.Boot()
		Enter(world, "The Deadmines")
		world:Fire("ENCOUNTER_END", 2741, "Rhahk'Zor", 1, 5, 1)
		world:Advance(600)
		local _, laterNs = Harness.Restart(world, { gap = 3600 })
		local finished = laterNs.Session.View(laterNs.History.Get(1))
		expect(finished.dungeons[1].name).toBe("The Deadmines")
		expect(finished.dungeons[1].seconds).toBe(600)
		expect(finished.dungeonCount).toBe(1)
	end)

	it("ignores boss kills it can't read and kills outside dungeons", function()
		local world, ns = Harness.Boot()
		world:Fire("BOSS_KILL", 99, "Lord Kazzak")
		Enter(world, "The Deadmines")
		world:Fire("ENCOUNTER_END", Harness.SECRET, "?", 1, 5, 1)
		world:Fire("ENCOUNTER_END", 2741, "?", 1, 5, Harness.SECRET)
		expect(Helpers.Session(ns).dungeon.bosses).toBe(0)
		expect(world.errors).toEqual({})
	end)
end)
