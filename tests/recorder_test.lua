local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Recorder", function()
	it("starts a session at login", function()
		local world, ns = Harness.Boot()
		local session = Helpers.Session(ns)
		expect(session.id).toBe(1)
		expect(session.startedAt).toBe(world.clock.server)
		expect(session.startLevel).toBe(10)
		expect(session.zone).toBe("Elwynn Forest")
		expect(world.env.SeshCharDB.active).toBe(session)
		expect(world.env.SeshCharDB.nextId).toBe(2)
	end)

	it("continues the same session across /reload", function()
		local world = Harness.Boot()
		Helpers.GainMoney(world, 500)
		world:Advance(120)
		local reloaded, ns2 = Harness.Restart(world, { reload = true, gap = 5 })
		local session = Helpers.Session(ns2)
		expect(session.id).toBe(1)
		expect(session.money).toBe(500)
		expect(session.afkSeconds).toBe(5)
		expect(#ns2.History.Sessions()).toBe(0)
		-- Money counted before the reload isn't counted again.
		Helpers.GainMoney(reloaded, 100)
		expect(Helpers.Session(ns2).money).toBe(600)
	end)

	it("resumes after a quick relog but finalizes after a long break", function()
		local world = Harness.Boot()
		Helpers.GainMoney(world, 500)
		world:Advance(600)
		local quick, quickNs = Harness.Restart(world, { gap = 120 })
		expect(Helpers.Session(quickNs).id).toBe(1)
		expect(Helpers.Session(quickNs).afkSeconds).toBe(120)

		quick:Advance(300)
		local later, laterNs = Harness.Restart(quick, { gap = 3600 })
		expect(Helpers.Session(laterNs).id).toBe(2)
		local finished = laterNs.History.Get(1)
		expect(finished).toBeTruthy()
		expect(finished.money).toBe(500)
		-- It ended when the player logged out, not when they came back.
		expect(finished.endedAt).toBe(later.clock.server - 3600)
		expect(finished.endedAt - finished.startedAt).toBe(600 + 120 + 300)
		expect(laterNs.Session.View(finished).zones[1].seconds).toBe(600 + 300)
	end)

	it("drops empty blips but keeps short sessions that recorded something", function()
		local world = Harness.Boot()
		world:Advance(60)
		local second, secondNs = Harness.Restart(world, { gap = 3600 })
		expect(#secondNs.History.Sessions()).toBe(0)
		Helpers.GainMoney(second, 1)
		second:Advance(60)
		local _, thirdNs = Harness.Restart(second, { gap = 3600 })
		expect(#thirdNs.History.Sessions()).toBe(1)
		expect(Helpers.Session(thirdNs).id).toBe(3)
	end)

	it("closes timers left open when the client never got to log out", function()
		local world, ns = Harness.Boot()
		local session = Helpers.Session(ns)
		Helpers.GainMoney(world, 10)
		world:Advance(180) -- three heartbeats
		expect(session.lastSeenAt).toBe(world.clock.server)
		expect(session.zoneSince).toBeTruthy()
		-- Saved without PLAYER_LOGOUT (a disconnect), then back an hour later.
		local saved = { SeshDB = world.env.SeshDB, SeshCharDB = world.env.SeshCharDB }
		local _, ns2 = Harness.Boot({ saved = saved, now = world.clock.server + 3600 })
		local finished = ns2.History.Get(1)
		expect(finished.endedAt - finished.startedAt).toBe(180)
		expect(ns2.Session.View(finished).zones[1].seconds).toBe(180)
	end)

	it("doesn't track anything while data from a newer version is loaded", function()
		local world, ns = Harness.Boot({ saved = { SeshCharDB = { schema = 99 } } })
		expect(ns.Recorder.Current()).toBeNil()
		Helpers.GainMoney(world, 100)
		expect(world.env.SeshCharDB.schema).toBe(99)
		expect(#world.errors).toBe(0)
	end)

	it("splits a session on request", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 70)
		world:Advance(600)
		ns.Recorder.Split()
		expect(Helpers.Session(ns).id).toBe(2)
		expect(ns.History.Get(1).money).toBe(70)
		Helpers.GainMoney(world, 30)
		expect(Helpers.Session(ns).money).toBe(30)
	end)

	it("creates no stray globals and raises no errors during a full login cycle", function()
		local world = Harness.Boot({ auctionator = true, ellesmere = true, ldb = true, compartment = true })
		world:Advance(65)
		local restarted = Harness.Restart(world, { reload = true })
		expect(Harness.LeakedGlobals(restarted)).toEqual({})
		expect(world.errors).toEqual({})
		expect(restarted.errors).toEqual({})
	end)
end)

describe("Character data", function()
	-- A character that finished a session and reached level 11.
	local function Played()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 500)
		Helpers.SetXP(world, 11, 50, 1100)
		world:Advance(600)
		ns.Recorder.Split()
		return world, ns
	end

	-- A new level 1 character that got the saved data of a deleted one with the same name.
	local function NewCharacter(w)
		w.player.guid = "Player-1-0000CCCC"
		w.player.level, w.player.xp, w.player.xpMax = 1, 0, 400
	end

	local function Printed(world, text)
		for _, line in ipairs(world.printed) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	it("remembers which character it belongs to", function()
		local world, ns = Played()
		expect(world.env.SeshCharDB.guid).toBe("Player-1-0000AAAA")
		local again, againNs = Harness.Restart(world, { gap = 86400 })
		expect(againNs.History.Get(1)).toBeTruthy()
		expect(Printed(again, ns.L.CHARACTER_REPLACED)).toBe(false)
	end)

	it("starts over for a new character with the name of a deleted one", function()
		local world = Played()
		local fresh, ns = Harness.Restart(world, { gap = 86400, configure = NewCharacter })
		expect(ns.History.Sessions()).toEqual({})
		expect(ns.Leveling.Records()).toEqual({})
		expect(ns.Recorder.Current().id).toBe(1)
		expect(ns.Recorder.Current().startLevel).toBe(1)
		expect(fresh.env.SeshCharDB.guid).toBe("Player-1-0000CCCC")
		expect(Printed(fresh, ns.L.CHARACTER_REPLACED)).toBe(true)
		expect(fresh.errors).toEqual({})
	end)

	it("keeps data saved before 0.2.0 unless it has seen a higher level", function()
		local world = Played()
		world.env.SeshCharDB.guid = nil
		local same, sameNs = Harness.Restart(world, { gap = 86400 })
		expect(sameNs.History.Get(1)).toBeTruthy()
		expect(same.env.SeshCharDB.guid).toBe("Player-1-0000AAAA")

		same.env.SeshCharDB.guid = nil
		local fresh, freshNs = Harness.Restart(same, { gap = 86400, configure = NewCharacter })
		expect(freshNs.History.Sessions()).toEqual({})
		expect(fresh.env.SeshCharDB.guid).toBe("Player-1-0000CCCC")
	end)

	it("leaves the data alone while the game hides who the player is", function()
		local world = Played()
		local hidden, ns = Harness.Restart(world, {
			gap = 86400,
			configure = function(w)
				NewCharacter(w)
				w.player.guid = Harness.Wow.SECRET
			end,
		})
		expect(ns.History.Get(1)).toBeTruthy()
		expect(hidden.env.SeshCharDB.guid).toBe("Player-1-0000AAAA")
	end)
end)
