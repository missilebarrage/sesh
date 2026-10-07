local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

-- Timings are printed for information. The limits are generous so the test only fails on
-- a real regression (a few times slower), not on a slow machine.
describe("Performance", function()
	it("handles 2,000 realistic sessions", function()
		local now = Helpers.LocalTime(2026, 10, 8, 15)
		local world, ns = Harness.Boot({ now = now })
		local sessions = world.env.SeshCharDB.sessions
		local function Rows(count, build)
			local rows = {}
			for index = 1, count do
				rows[index] = build(index)
			end
			return rows
		end
		for index = 1, 2000 do
			local record = Helpers.Record(ns, {
				id = index,
				startedAt = now - (2001 - index) * 5 * 3600,
				duration = 5400,
				money = index * 37,
				xp = index * 11,
				kills = 100,
				items = Rows(20, function(item)
					return { itemID = 2000 + (index + item) % 400, count = item, unitValue = 50, value = 50 * item }
				end),
				monsters = Rows(10, function(monster)
					return {
						name = "Monster " .. ((index + monster) % 300),
						count = 10,
						npcID = 100 + monster,
						typeID = 7,
					}
				end),
				quests = Rows(5, function(quest)
					return { questID = index * 10 + quest, xp = 100, money = 50, title = "Quest " .. quest }
				end),
				zones = Rows(3, function(zone)
					return { name = "Zone " .. ((index + zone) % 40), kind = 0, seconds = 1800 }
				end),
			})
			sessions[#sessions + 1] = record
		end

		local function Time(label, limit, fn)
			local started = os.clock()
			fn()
			local elapsed = (os.clock() - started) * 1000
			io.write(string.format("    %-36s %7.1f ms\n", label, elapsed))
			expect(elapsed).toBeLessThan(limit)
		end

		Time("rebuild lifetime (2,000 sessions)", 5000, function()
			ns.History.Rebuild()
		end)

		-- Log in again: everything below starts from freshly loaded saved variables.
		local fresh, freshNs = Harness.Restart(world, { reload = true })
		collectgarbage("collect")
		local memoryBefore = collectgarbage("count")
		Time("summary computations (cold)", 300, function()
			freshNs.SummaryView.Measure(fresh.clock.server)
		end)
		Time("summary computations (cached)", 100, function()
			freshNs.SummaryView.Measure(fresh.clock.server)
		end)
		collectgarbage("collect")
		local retainedKB = collectgarbage("count") - memoryBefore
		io.write(string.format("    %-36s %7.0f KB\n", "memory kept by the summary", retainedKB))
		expect(retainedKB).toBeLessThan(2048)

		Time("past 3 months (cold)", 1500, function()
			freshNs.History.Query("quarter", fresh.clock.server)
		end)
		Time("past 3 months (cached)", 200, function()
			freshNs.History.Query("quarter", fresh.clock.server)
		end)
		Time("finalize a session", 100, function()
			freshNs.Recorder.Split()
		end)
		expect(world.errors).toEqual({})
		expect(fresh.errors).toEqual({})
	end)
end)
