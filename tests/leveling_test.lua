local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

-- The test character starts at level 10 with 100 / 1000 experience.

describe("Leveling", function()
	it("starts tracking the level the character is at, from how far into it they are", function()
		local world, ns = Harness.Boot()
		expect(ns.Leveling.Current()).toBe(10)
		local view = ns.Leveling.View(10, world.clock.server)
		expect(view.live).toBe(true)
		expect(view.level).toBe(10)
		expect(view.fromPercent).toBe(10)
		expect(view.startedAt).toBe(world.clock.server)
		expect(view.progress).toBe(10)
		expect(view.xpMax).toBe(1000)
		-- Nothing is stored until the first part played at the level ends.
		expect(ns.Leveling.Records()[10]).toBeNil()
	end)

	it("completes a level at level-up and tracks the next one from its start", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 500)
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 69, "Timber Wolf", 1))
		world.quests[176] = "Wanted: Hogger"
		world:Fire("QUEST_TURNED_IN", 176, 450, 1200)
		world:Advance(1800)
		Helpers.SetXP(world, 10, 900, 1000)
		world:Advance(600)
		-- 300 experience: 100 finish level 10, 200 go into level 11.
		Helpers.SetXP(world, 11, 200, 1100)
		local ten = ns.Leveling.Records()[10]
		expect(ten.completed).toBe(true)
		expect(ten.xp).toBe(800 + 100)
		expect(ten.duration).toBe(2400)
		expect(ten.kills).toBe(1)
		expect(ten.questCount).toBe(1)
		expect(ten.money).toBe(500)
		expect(ten.sessionCount).toBe(1)
		expect(ten.endedAt).toBe(world.clock.server)

		expect(ns.Leveling.Current()).toBe(11)
		local eleven = ns.Leveling.View(11, world.clock.server)
		expect(eleven.fromPercent).toBeNil()
		expect(eleven.xp).toBe(200)
		expect(eleven.kills).toBe(0)
		-- Splitting the experience between the levels leaves the session's total alone.
		expect(Helpers.Session(ns).xp).toBe(800 + 100 + 200)
	end)

	it("splits the experience of a level-up whichever update arrives first", function()
		local world, ns = Harness.Boot()
		Helpers.SetXP(world, 10, 900, 1000)
		world.player.level = 11
		world:Fire("PLAYER_LEVEL_UP", 11)
		world.player.xp, world.player.xpMax = 200, 1100
		world:Fire("PLAYER_XP_UPDATE", "player")
		expect(ns.Leveling.Records()[10].xp).toBe(800 + 100)
		expect(ns.Leveling.View(11, world.clock.server).xp).toBe(200)

		world.player.xp, world.player.xpMax = 1000, 1100
		world:Fire("PLAYER_XP_UPDATE", "player")
		world.player.xp, world.player.xpMax = 50, 1200
		world:Fire("PLAYER_XP_UPDATE", "player")
		world.player.level = 12
		world:Fire("PLAYER_LEVEL_UP", 12)
		expect(ns.Leveling.Records()[11].xp).toBe(1100)
		expect(ns.Leveling.View(12, world.clock.server).xp).toBe(50)
	end)

	it("sums up a finished level in chat, with a link that opens it", function()
		local world, ns = Harness.Boot()
		world:Advance(3000)
		Helpers.SetXP(world, 11, 50, 1100)
		local line = world.printed[#world.printed]
		expect(line).toContain("Level 10 took 50m from 10%: 0 kills, 0 quests, 0 deaths.")
		expect(line).toContain("|Haddon:Sesh:Tester-TestRealm:L10|h[Sesh Lv10]|h")
		local opened
		ns.MainWindow.OpenLevel = function(level)
			opened = level
		end
		world:ClickLink("addon:Sesh:Tester-TestRealm:L10", "[Sesh Lv10]")
		expect(opened).toBe(10)

		ns.Database.Set("announceLevels", false)
		local printed = #world.printed
		Helpers.SetXP(world, 12, 10, 1200)
		expect(#world.printed).toBe(printed)
	end)

	it("adds up a level over several sessions without counting reloads twice", function()
		local world = Harness.Boot()
		Helpers.GainMoney(world, 100)
		world:Advance(600)
		local reloaded = Harness.Restart(world, { reload = true })
		Helpers.GainMoney(reloaded, 50)
		reloaded:Advance(600)
		local later, laterNs = Harness.Restart(reloaded, { gap = 7200 })
		local record = laterNs.Leveling.Records()[10]
		expect(record.sessionCount).toBe(1)
		expect(record.money).toBe(150)
		expect(record.duration).toBe(1200)

		Helpers.GainMoney(later, 25)
		later:Advance(300)
		local view = laterNs.Leveling.View(10, later.clock.server)
		expect(view.money).toBe(175)
		expect(view.sessionCount).toBe(2)
		expect(laterNs.Session.Duration(view, later.clock.server)).toBe(1500)
		-- The level's time keeps running between refreshes.
		expect(laterNs.Session.Duration(view, later.clock.server + 120)).toBe(1620)
	end)

	it("counts a session recorded before Sesh tracked levels toward its level", function()
		local now = 1790000000
		local saved = {
			SeshDB = { schema = 1 },
			SeshCharDB = {
				schema = 1,
				nextId = 8,
				sessions = {},
				active = {
					id = 7,
					startedAt = now - 1200,
					lastSeenAt = now,
					startLevel = 10,
					endLevel = 10,
					xp = 50,
					money = 900,
					kills = 3,
					unidentifiedKills = 0,
					deaths = 0,
					legacy = 0,
					afkSeconds = 0,
					missed = 0,
					items = {},
					unitValues = {},
					monsters = {},
					quests = {},
					zones = {},
					achievements = {},
				},
			},
		}
		local world, ns = Harness.Boot({ saved = saved, now = now, reload = true })
		local view = ns.Leveling.View(10, now)
		expect(view.money).toBe(900)
		expect(view.kills).toBe(3)
		expect(view.startedAt).toBe(now - 1200)
		-- 100 experience now, 50 of it earned in the session: tracking began at 5%.
		expect(view.fromPercent).toBe(5)
		expect(ns.Recorder.Current().dungeons).toEqual({})
		expect(world.errors).toEqual({})
	end)

	it("ends a level whose level-up it didn't see without calling it complete", function()
		local world = Harness.Boot()
		world:Advance(600)
		local later, laterNs = Harness.Restart(world, {
			gap = 7200,
			configure = function(w)
				w.player.level, w.player.xp, w.player.xpMax = 12, 300, 1200
			end,
		})
		local ten = laterNs.Leveling.Records()[10]
		expect(ten.completed).toBeNil()
		expect(ten.duration).toBe(600)
		expect(laterNs.Leveling.Current()).toBe(12)
		expect(laterNs.Leveling.View(12, later.clock.server).fromPercent).toBe(25)
		local rows = laterNs.Leveling.Rows(later.clock.server, true)
		expect(#rows).toBe(2)
		expect(rows[1].partial).toBe(true)
		expect(rows[2].current).toBe(true)
	end)

	it("stops at the level cap", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.player.maxLevel = 11
			end,
		})
		world:Advance(600)
		Helpers.SetXP(world, 11, 0, 1100)
		expect(ns.Leveling.Records()[10].completed).toBe(true)
		expect(ns.Leveling.Records()[11]).toBeNil()
		expect(ns.Leveling.Current()).toBeNil()
		world:Advance(600)
		local _, laterNs = Harness.Restart(world, { gap = 7200 })
		expect(laterNs.Leveling.Records()[11]).toBeNil()
		expect(laterNs.Leveling.Records()[10].duration).toBe(600)
	end)

	it("counts a dungeon run toward the level it ends in", function()
		local world, ns = Harness.Boot()
		world.zone = { name = "The Deadmines", instanceType = "party" }
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
		world:Fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
		world:Advance(600)
		Helpers.SetXP(world, 11, 10, 1100)
		world:Fire("ENCOUNTER_END", 2, "Sneed", 1, 5, 1)
		world.zone = { name = "Westfall", instanceType = "none" }
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
		world:Advance(16 * 60)
		expect(ns.Leveling.Records()[10].dungeonCount).toBe(0)
		local eleven = ns.Leveling.View(11, world.clock.server)
		expect(eleven.dungeonCount).toBe(1)
		expect(eleven.dungeons[1].bosses).toBe(2)
	end)

	it("lists levels with the numbers the chart and list show", function()
		local world, ns = Harness.Boot()
		Helpers.SetXP(world, 10, 500, 1000)
		world:Advance(1800)
		Helpers.SetXP(world, 11, 0, 1100)
		world:Advance(3600)
		Helpers.SetXP(world, 11, 550, 1100)
		local rows, current = ns.Leveling.Rows(world.clock.server, true)
		expect(#rows).toBe(2)
		expect(rows[1].level).toBe(10)
		expect(rows[1].partial).toBe(true)
		expect(rows[1].duration).toBe(1800)
		expect(rows[1].xpPerHour).toBe(1800)
		expect(rows[2].current).toBe(true)
		expect(rows[2].progress).toBe(50)
		expect(rows[2].duration).toBe(3600)
		expect(current.level).toBe(11)
		expect(ns.LevelingView.JourneyText(rows)).toBe("2 levels  ·  1h 30m played")
	end)

	it("keeps no level for a session too short and empty to keep", function()
		local world = Harness.Boot()
		world:Advance(60)
		local later, laterNs = Harness.Restart(world, { gap = 7200 })
		expect(#laterNs.History.Sessions()).toBe(0)
		expect(laterNs.Leveling.Records()[10]).toBeNil()
		local rows = laterNs.Leveling.Rows(later.clock.server, true)
		expect(#rows).toBe(1)
		expect(rows[1].startedAt).toBe(later.clock.server)
	end)

	it("starts the current level over from now when the history is deleted", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 100)
		world:Advance(3600)
		world.env.StaticPopupDialogs.SESH_DELETE_HISTORY.OnAccept()
		local now = world.clock.server
		local view = ns.Leveling.View(10, now)
		expect(view.money).toBe(0)
		expect(ns.Session.Duration(view, now)).toBe(0)
		expect(view.startedAt).toBe(now)
		expect(view.fromPercent).toBe(10)
		Helpers.GainMoney(world, 7)
		world:Advance(60)
		expect(ns.Leveling.View(10, world.clock.server).money).toBe(7)
	end)

	it("deletes level stats with the history and starts the current level over", function()
		local world, ns = Harness.Boot()
		world:Advance(600)
		Helpers.SetXP(world, 11, 0, 1100)
		world:Advance(600)
		ns.Shares.Mark("level", 10, world.clock.server)
		world.env.StaticPopupDialogs.SESH_DELETE_HISTORY.OnAccept()
		expect(ns.Leveling.Records()[10]).toBeNil()
		expect(ns.Shares.IsShared("level", 10, world.clock.server)).toBe(false)
		expect(ns.Leveling.Current()).toBe(11)
		local view = ns.Leveling.View(11, world.clock.server)
		expect(ns.Session.Duration(view, world.clock.server)).toBe(0)
	end)

	it("keeps sessions and levels consistent when a session is split", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 40)
		world:Advance(600)
		ns.Recorder.Split()
		Helpers.GainMoney(world, 2)
		world:Advance(60)
		local view = ns.Leveling.View(10, world.clock.server)
		expect(view.money).toBe(42)
		expect(view.sessionCount).toBe(2)
		expect(ns.Session.Duration(view, world.clock.server)).toBe(660)
	end)
end)
