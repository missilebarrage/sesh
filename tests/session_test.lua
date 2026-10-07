local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Session", function()
	it("starts empty and becomes non-empty with any activity", function()
		local _, ns = Harness.Load()
		local session = ns.Session.New(1, 1000)
		expect(ns.Session.IsEmpty(session)).toBe(true)
		ns.Session.AddDeath(session)
		expect(ns.Session.IsEmpty(session)).toBe(false)
	end)

	it("values items with live prices and sorts the most valuable first", function()
		local world, ns = Harness.Load()
		Helpers.Item(world, 1, 10)
		Helpers.Item(world, 2, 500)
		local session = ns.Session.New(1, 1000)
		ns.Session.AddItem(session, 1, 30)
		ns.Session.AddItem(session, 2, 1)
		ns.Session.AddItem(session, 1, 5)
		local view = ns.Session.LiveView(session, 1600)
		expect(view.items[1]).toEqual({ itemID = 2, count = 1, unitValue = 500, value = 500 })
		expect(view.items[2]).toEqual({ itemID = 1, count = 35, unitValue = 10, value = 350 })
		expect(view.itemValue).toBe(850)
		expect(view.itemCount).toBe(36)
	end)

	it("counts unidentified kills separately and merges named ones", function()
		local _, ns = Harness.Load()
		local session = ns.Session.New(1, 1000)
		ns.Session.AddKill(session, "Defias Thug", 38, 7)
		ns.Session.AddKill(session, "Defias Thug", 38, 7)
		ns.Session.AddKill(session, nil)
		local view = ns.Session.LiveView(session, 1000)
		expect(view.kills).toBe(3)
		expect(view.unidentifiedKills).toBe(1)
		expect(view.monsters).toEqual({ { name = "Defias Thug", count = 2, npcID = 38, typeID = 7 } })
	end)

	it("times zones, including the one the player is still in", function()
		local _, ns = Harness.Load()
		local session = ns.Session.New(1, 1000)
		ns.Session.EnterZone(session, "Elwynn Forest", ns.Session.ZONE_WORLD, 1000)
		ns.Session.EnterZone(session, "The Deadmines", ns.Session.ZONE_DUNGEON, 1600)
		local view = ns.Session.LiveView(session, 2800)
		expect(view.zones).toEqual({
			{ name = "The Deadmines", kind = ns.Session.ZONE_DUNGEON, seconds = 1200 },
			{ name = "Elwynn Forest", kind = ns.Session.ZONE_WORLD, seconds = 600 },
		})
	end)

	it("finalizes into a packed record whose view matches the live view", function()
		local world, ns = Harness.Load()
		Helpers.Item(world, 2589, 13)
		local session = ns.Session.New(4, 1000)
		ns.Session.SetLevel(session, 20)
		ns.Session.AddXP(session, 5000)
		ns.Session.SetLevel(session, 21)
		ns.Session.AddMoney(session, 12345)
		ns.Session.AddItem(session, 2589, 20)
		ns.Session.AddKill(session, "Kobold Miner", 40, 7)
		ns.Session.AddQuest(session, 176, "Wanted: Hogger", 450, 1200)
		ns.Session.AddAchievement(session, 9001)
		ns.Session.EnterZone(session, "Elwynn Forest", ns.Session.ZONE_WORLD, 1000)
		local record = ns.Session.Finalize(session, 4600)
		expect(record.endedAt).toBe(4600)
		expect(record.items).toBe("2589:20:13")
		expect(record.quests).toBe("176:450:1200:Wanted: Hogger")
		expect(record.zones).toBe("0:3600:Elwynn Forest")

		local view = ns.Session.View(Harness.Wow.RoundTrip(record))
		expect(view.kind).toBe("session")
		expect(view.levels).toBe(1)
		expect(view.itemValue).toBe(260)
		expect(view.monsters[1]).toEqual({ name = "Kobold Miner", count = 1, npcID = 40, typeID = 7 })
		expect(view.quests[1].title).toBe("Wanted: Hogger")
		expect(view.achievements[1].achievementID).toBe(9001)
		local metrics = ns.Session.Metrics(view, 99999, true)
		expect(metrics.duration).toBe(3600)
		expect(metrics.goldEarned).toBe(12345 + 260)
		expect(metrics.goldPerHour).toBe(12345 + 260)
		expect(metrics.xpPerHour).toBe(5000)
	end)

	it("prefers prices snapshotted at logout when finalizing later", function()
		local world, ns = Harness.Load()
		Helpers.Item(world, 7, 100)
		local session = ns.Session.New(1, 1000)
		ns.Session.AddItem(session, 7, 2)
		ns.Session.SnapshotValues(session)
		world.items[7].sellPrice = 999
		ns.Pricing.Invalidate()
		expect(ns.Session.Finalize(session, 2000).itemValue).toBe(200)
	end)

	it("withholds rates until there is a minute of active time and can exclude AFK", function()
		local _, ns = Harness.Load()
		local session = ns.Session.New(1, 1000)
		ns.Session.AddMoney(session, 3600)
		expect(ns.Session.Metrics(ns.Session.LiveView(session, 1030), 1030, true).goldPerHour).toBeNil()
		ns.Session.SetAfk(session, true, 1000 + 1800)
		local live = ns.Session.LiveView(session, 1000 + 3600)
		local excluding = ns.Session.Metrics(live, 1000 + 3600, true)
		expect(excluding.activeSeconds).toBe(1800)
		expect(excluding.goldPerHour).toBe(7200)
		local including = ns.Session.Metrics(live, 1000 + 3600, false)
		expect(including.goldPerHour).toBe(3600)
	end)

	it("aggregates views and subtracts them back out", function()
		local _, ns = Harness.Load()
		local a = Helpers.Record(ns, {
			id = 1,
			startedAt = 1000,
			money = 100,
			kills = 2,
			items = { { itemID = 5, count = 2, unitValue = 10, value = 20 } },
			monsters = { { name = "Wolf", count = 2, npcID = 69, typeID = 1 } },
			quests = { { questID = 1, xp = 10, money = 0, title = "A" } },
			zones = { { name = "Elwynn Forest", kind = 0, seconds = 3600 } },
		})
		local b = Helpers.Record(ns, {
			id = 2,
			startedAt = 9000,
			money = 50,
			kills = 1,
			items = { { itemID = 5, count = 1, unitValue = 12, value = 12 } },
			monsters = { { name = "Wolf", count = 1, npcID = 69, typeID = 1 } },
			quests = { { questID = 2, xp = 20, money = 5, title = "B" } },
			zones = { { name = "Westfall", kind = 0, seconds = 3600 } },
		})
		local total = ns.Session.NewAggregate()
		ns.Session.Accumulate(total, ns.Session.View(a))
		ns.Session.Accumulate(total, ns.Session.View(b))
		local view = ns.Session.Seal(total)
		expect(view.sessionCount).toBe(2)
		expect(view.duration).toBe(7200)
		expect(view.money).toBe(150)
		expect(view.items).toEqual({ { itemID = 5, count = 3, value = 32, unitValue = 10 } })
		expect(view.monsters[1].count).toBe(3)
		expect(#view.quests).toBe(2)

		local back = ns.Session.NewAggregate()
		ns.Session.Accumulate(back, view)
		ns.Session.Accumulate(back, ns.Session.View(b), -1)
		local onlyA = ns.Session.Seal(back)
		expect(onlyA.sessionCount).toBe(1)
		expect(onlyA.money).toBe(100)
		expect(onlyA.items).toEqual({ { itemID = 5, count = 2, value = 20, unitValue = 10 } })
		expect(onlyA.quests).toEqual({ { questID = 1, xp = 10, money = 0, title = "A" } })
		expect(#onlyA.zones).toBe(1)

		local stored = ns.Session.View(Harness.Wow.RoundTrip(ns.Session.ToRecord(view)))
		expect(stored.kind).toBe("aggregate")
		expect(stored.sessionCount).toBe(2)
		expect(stored.items[1].value).toBe(32)
	end)

	it("takes what came before a mark out of later views", function()
		local world, ns = Harness.Load()
		local Session = ns.Session
		Helpers.Item(world, 7, 10)
		local session = Session.New(1, 1000)
		Session.EnterZone(session, "Elwynn Forest", Session.ZONE_WORLD, 1000)
		Session.AddItem(session, 7, 3)
		Session.AddKill(session, "Kobold Vermin", 6, 7)
		Session.AddQuest(session, 1, "A", 100, 0)
		Session.AddAchievement(session, 500)
		Session.AddXP(session, 400)
		Session.SetAfk(session, true, 1100)
		local mark = Session.Mark(session, 1200)

		Session.SetAfk(session, false, 1300)
		Session.AddItem(session, 7, 2)
		Session.AddKill(session, "Kobold Vermin", 6, 7)
		Session.AddKill(session, "Defias Thug", 38, 7)
		Session.AddQuest(session, 2, "B", 250, 75)
		Session.AddXP(session, 600)
		Session.EnterZone(session, "Westfall", Session.ZONE_WORLD, 1500)
		local part = Session.Since(Session.LiveView(session, 1800), mark)

		expect(part.startedAt).toBe(1200)
		expect(part.xp).toBe(600)
		expect(part.kills).toBe(2)
		expect(part.items).toEqual({ { itemID = 7, count = 2, unitValue = 10, value = 20 } })
		expect(part.itemValue).toBe(20)
		expect(part.monsters).toEqual({
			{ name = "Defias Thug", count = 1, npcID = 38, typeID = 7 },
			{ name = "Kobold Vermin", count = 1, npcID = 6, typeID = 7 },
		})
		expect(part.quests).toEqual({ { questID = 2, title = "B", xp = 250, money = 75 } })
		expect(part.questCount).toBe(1)
		expect(part.achievements).toEqual({})
		expect(part.zones).toEqual({
			{ name = "Elwynn Forest", kind = Session.ZONE_WORLD, seconds = 300 },
			{ name = "Westfall", kind = Session.ZONE_WORLD, seconds = 300 },
		})
		-- The AFK period that was open at the mark counts only from the mark on.
		expect(Session.AfkSeconds(part, 1800)).toBe(100)
		expect(Session.Duration(part, 1800)).toBe(600)
		-- Splitting the AFK period didn't change the session's own total.
		expect(Session.AfkSeconds(Session.LiveView(session, 1800), 1800)).toBe(200)
	end)

	it("keeps running views running in aggregates", function()
		local _, ns = Harness.Load()
		local Session = ns.Session
		local finished = Helpers.Record(ns, { id = 1, startedAt = 1000, duration = 600, afkSeconds = 60 })
		local session = Session.New(2, 5000)
		Session.SetAfk(session, true, 5100)
		local aggregate = Session.NewAggregate()
		Session.Accumulate(aggregate, Session.View(finished))
		Session.Accumulate(aggregate, Session.LiveView(session, 5200), 1, 5200)
		local view = Session.Seal(aggregate)
		expect(Session.Duration(view, 5200)).toBe(600 + 200)
		expect(Session.Duration(view, 5500)).toBe(600 + 500)
		expect(Session.AfkSeconds(view, 5500)).toBe(60 + 400)
		expect(view.sessionCount).toBe(2)
	end)

	it("records dungeon runs that a boss died in or that lasted a while", function()
		local _, ns = Harness.Load()
		local Session = ns.Session
		local session = Session.New(1, 1000)
		Session.EnterDungeon(session, "The Deadmines", 1000)
		Session.AddBossKill(session, 1001, 1100)
		Session.AddBossKill(session, 1001, 1100) -- the same kill from a second event
		Session.LeaveDungeon(session, 1400)
		-- Back after a corpse run: the same run goes on.
		Session.EnterDungeon(session, "The Deadmines", 1500)
		Session.AddBossKill(session, 1002, 1600)
		Session.LeaveDungeon(session, 2000)
		Session.AddBossKill(session, 1003, 2050) -- outside: not part of the run
		-- Another dungeon ends the run when it was left.
		Session.EnterDungeon(session, "Wailing Caverns", 2100)
		Session.LeaveDungeon(session, 2200)
		Session.EndDungeon(session, 9000)
		expect(session.dungeons).toEqual({
			{ name = "The Deadmines", startedAt = 1000, seconds = 1000, bosses = 2 },
		})

		Session.EnterDungeon(session, "Wailing Caverns", 3000)
		Session.EndDungeon(session, 3000 + 300)
		expect(#session.dungeons).toBe(2)
		expect(Session.IsEmpty(Session.New(2, 1))).toBe(true)
	end)

	it("starts a new run when a boss of the run dies again after a reset", function()
		local _, ns = Harness.Load()
		local Session = ns.Session
		local session = Session.New(1, 1000)
		Session.EnterDungeon(session, "The Deadmines", 1000)
		Session.AddBossKill(session, 1, 1300)
		Session.AddBossKill(session, 2, 1900)
		Session.LeaveDungeon(session, 2400)
		-- Reset and straight back in: the first boss dies again.
		Session.EnterDungeon(session, "The Deadmines", 2500)
		Session.AddBossKill(session, 1, 2800)
		Session.AddBossKill(session, 1, 2800)
		Session.AddBossKill(session, 2, 3300)
		Session.LeaveDungeon(session, 3600)
		Session.EndDungeon(session, 9000)
		expect(session.dungeons).toEqual({
			{ name = "The Deadmines", startedAt = 1000, seconds = 1400, bosses = 2 },
			{ name = "The Deadmines", startedAt = 2500, seconds = 1100, bosses = 2 },
		})
	end)

	it("packs dungeon runs into records and aggregates", function()
		local _, ns = Harness.Load()
		local Session = ns.Session
		local session = Session.New(1, 1000)
		Session.EnterDungeon(session, "The Deadmines", 1000)
		Session.AddBossKill(session, 1, 1200)
		local record = Session.Finalize(session, 2800)
		expect(record.dungeons).toBe("1000:1800:1:The Deadmines")
		expect(record.dungeonCount).toBe(1)
		local view = Session.View(Harness.Wow.RoundTrip(record))
		expect(view.dungeons).toEqual({ { name = "The Deadmines", startedAt = 1000, seconds = 1800, bosses = 1 } })
		expect(Session.Metrics(view, 2800, true).dungeons).toBe(1)

		local aggregate = Session.NewAggregate()
		Session.Accumulate(aggregate, view)
		Session.Accumulate(aggregate, view)
		local total = Session.Seal(aggregate)
		expect(total.dungeonCount).toBe(2)
		Session.Accumulate(aggregate, view, -1)
		expect(Session.Seal(aggregate).dungeons).toEqual(view.dungeons)
	end)
end)
