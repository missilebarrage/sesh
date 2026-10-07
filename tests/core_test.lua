describe("Namespace", function()
	it("treats a packaged-version token as a dev build", function()
		local _, ns = Harness.Load()
		expect(ns.VERSION).toBe("dev")
		local _, packaged = Harness.Load({ version = "1.2.0" })
		expect(packaged.VERSION).toBe("1.2.0")
	end)

	it("gates secret and non-finite values", function()
		local _, ns = Harness.Load()
		local secret = Harness.SECRET
		expect(ns.Num(5)).toBe(5)
		expect(ns.Num(secret)).toBeNil()
		expect(ns.Num(0 / 0)).toBeNil()
		expect(ns.Num(math.huge)).toBeNil()
		expect(ns.Num("5")).toBeNil()
		expect(ns.Str("hi")).toBe("hi")
		expect(ns.Str(secret)).toBeNil()
		expect(ns.IsReadable(secret)).toBe(false)
		expect(ns.IsReadable(nil)).toBe(true)
	end)

	it("falls back to the key for missing strings", function()
		local _, ns = Harness.Load()
		expect(ns.L.SOMETHING_MISSING).toBe("SOMETHING_MISSING")
	end)
end)

describe("FormatPattern", function()
	it("captures %s and %d and escapes magic characters", function()
		local _, ns = Harness.Load()
		local pattern, order = ns.FormatPattern("You receive loot: %sx%d.")
		expect(pattern).toBe("^You receive loot: (.-)x(%d+)%.$")
		expect(order).toEqual({ 1, 2 })
		local link, count = ns.MatchFormat("You receive loot: [Linen Cloth]x12.", pattern, order)
		expect(link).toBe("[Linen Cloth]")
		expect(count).toBe("12")
	end)

	it("maps positional conversions back to argument order", function()
		local _, ns = Harness.Load()
		local pattern, order = ns.FormatPattern("Du erhaltet %2$d mal: %1$s.")
		expect(order).toEqual({ 2, 1 })
		local link, count = ns.MatchFormat("Du erhaltet 3 mal: [Leinenstoff].", pattern, order)
		expect(link).toBe("[Leinenstoff]")
		expect(count).toBe("3")
	end)

	it("can leave the end unanchored for messages with optional suffixes", function()
		local _, ns = Harness.Load()
		local pattern, order = ns.FormatPattern("%s dies, you gain %d experience.", false)
		local name, xp =
			ns.MatchFormat("Defias Thug dies, you gain 120 experience. (+60 exp Rested bonus)", pattern, order)
		expect(name).toBe("Defias Thug")
		expect(xp).toBe("120")
	end)

	it("keeps literal percent signs literal", function()
		local _, ns = Harness.Load()
		local pattern = ns.FormatPattern("100%% of %s")
		expect(("100% of things"):match(pattern)).toBe("things")
	end)
end)

describe("Events", function()
	it("dispatches game events and internal signals", function()
		local world, ns = Harness.Load()
		local received = {}
		ns.Events.On("PLAYER_MONEY", function(...)
			received[#received + 1] = { "money", ... }
		end)
		ns.Events.On("SESH_TEST", function(value)
			received[#received + 1] = { "signal", value }
		end)
		world:Fire("PLAYER_MONEY")
		ns.Events.Fire("SESH_TEST", 42)
		expect(received).toEqual({ { "money" }, { "signal", 42 } })
	end)

	it("reports unknown game events instead of failing", function()
		local world, ns = Harness.Load({
			configure = function(w)
				w.unknownEvents.MADE_UP_EVENT = true
			end,
		})
		expect(ns.Events.On("MADE_UP_EVENT", function() end)).toBe(false)
		expect(#world.errors).toBe(0)
	end)

	it("keeps other handlers running when one fails", function()
		local world, ns = Harness.Load()
		local ran = false
		ns.Events.On("SESH_TEST", function()
			error("boom")
		end)
		ns.Events.On("SESH_TEST", function()
			ran = true
		end)
		ns.Events.Fire("SESH_TEST")
		expect(ran).toBe(true)
		expect(#world.errors).toBe(1)
	end)

	it("lets a handler unsubscribe while its event dispatches", function()
		local _, ns = Harness.Load()
		local calls = 0
		local function Once()
			calls = calls + 1
			ns.Events.Off("SESH_TEST", Once)
		end
		ns.Events.On("SESH_TEST", Once)
		ns.Events.On("SESH_TEST", function() end)
		ns.Events.Fire("SESH_TEST")
		ns.Events.Fire("SESH_TEST")
		expect(calls).toBe(1)
	end)

	it("debounces bursts into one call", function()
		local world, ns = Harness.Load()
		local calls = 0
		for _ = 1, 5 do
			ns.Events.Debounce("burst", 0.5, function()
				calls = calls + 1
			end)
		end
		expect(calls).toBe(0)
		world:Advance(0.5)
		expect(calls).toBe(1)
		ns.Events.Debounce("burst", 0.5, function()
			calls = calls + 1
		end)
		world:Advance(1)
		expect(calls).toBe(2)
	end)
end)

describe("Database", function()
	it("creates defaults on first load", function()
		local world, ns = Harness.Load()
		world:Fire("ADDON_LOADED", "Sesh")
		ns.Database.Init()
		expect(ns.Database.Get("resumeMinutes")).toBe(5)
		expect(ns.Database.Char().nextId).toBe(1)
		expect(ns.Database.IsReadOnly()).toBe(false)
	end)

	it("never touches data from a newer version", function()
		local future = { schema = 99, sessions = { { id = 1 } }, nextId = 2 }
		local world, ns = Harness.Load({ saved = { SeshCharDB = future } })
		ns.Database.Init()
		expect(ns.Database.Char()).toBeNil()
		expect(ns.Database.IsReadOnly()).toBe(true)
		expect(world.env.SeshCharDB.schema).toBe(99)
		expect(world.printed[1]).toContain("newer version")
	end)

	it("repairs missing fields and settings of the wrong type", function()
		local saved = {
			SeshDB = { schema = 1, settings = { resumeMinutes = "five", excludeAfk = false } },
			SeshCharDB = { schema = 1, sessions = { { id = 7 } } },
		}
		local _, ns = Harness.Load({ saved = saved })
		ns.Database.Init()
		expect(ns.Database.Get("resumeMinutes")).toBe(5)
		expect(ns.Database.Get("excludeAfk")).toBe(false)
		expect(ns.Database.Char().nextId).toBe(8)
		expect(ns.Database.Char().shared).toEqual({})
	end)

	it("restores only valid window positions", function()
		local world, ns = Harness.Load()
		ns.Database.Init()
		local frame = world.env.CreateFrame("Frame")
		expect(ns.Database.RestorePosition("main", frame)).toBe(false)
		frame:SetPoint("TOPLEFT", nil, "TOPLEFT", 12, -30)
		ns.Database.SavePosition("main", frame)
		local other = world.env.CreateFrame("Frame")
		expect(ns.Database.RestorePosition("main", other)).toBe(true)
		world.env.SeshDB.windows.main.point = "NOWHERE"
		expect(ns.Database.RestorePosition("main", other)).toBe(false)
	end)
end)
