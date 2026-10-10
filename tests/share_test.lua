local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Share text", function()
	it("writes a chat line with the chosen metrics", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 103305)
		Helpers.SetXP(world, 10, 1100, 2000)
		world:Advance(3600)
		local view = ns.Recorder.LiveView()
		local text, dropped = ns.Links.ChatText(view, {
			duration = true,
			goldEarned = true,
			goldPerHour = true,
			xp = true,
			xpPerHour = true,
		}, world.clock.server, true)
		expect(text).toBe("Current Session (1h 0m): 10g 33s 5c earned (10g/hour) · 1,000 XP (1,000/hour)")
		expect(dropped).toBe(0)
	end)

	it("drops metrics from the end to fit the chat limit", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 98765432101)
		world:Advance(3600)
		local fields = {}
		for _, field in ipairs(ns.Links.FIELDS) do
			fields[field] = true
		end
		local session = ns.Recorder.Current()
		session.xp, session.kills, session.deaths, session.legacy = 9876543210, 9876543, 98765, 98765
		session.endLevel = 60
		for index = 1, 40 do
			ns.Session.AddQuest(session, index, "Q", 1, 1)
		end
		local text, dropped = ns.Links.ChatText(ns.Recorder.LiveView(), fields, world.clock.server, true)
		expect(#text <= 255).toBe(true)
		expect(dropped).toBeGreaterThan(0)
	end)

	it("shares by writing plain text into chat", function()
		local world, ns = Harness.Boot()
		local view = ns.Recorder.LiveView()
		ns.Links.Share(view, { goldEarned = true })
		expect(world.openedChat[1]).toBe("Current Session: 0c earned")
		local editBox = world.env.CreateFrame("EditBox")
		editBox:SetText("hi ")
		world.activeEditBox = editBox
		ns.Links.Share(view, { kills = true })
		expect(editBox:GetText()).toBe("hi Current Session: 0 kills")
	end)

	it("names a finished session by its date", function()
		local world, ns = Harness.Boot()
		local now = world.clock.server
		ns.History.Add(Helpers.Record(ns, { id = 50, startedAt = now - 40 * 86400, money = 5 }))
		ns.Links.Share(ns.Session.View(ns.History.Get(50)), { goldEarned = true })
		expect(world.openedChat[1]).toMatch("^Session .+: 5c earned$")
	end)

	it("leaves other players' chat alone", function()
		local world = Harness.Boot()
		expect(next(world.chatFilters)).toBeNil()
		local message = world:Chat("CHAT_MSG_GUILD", "look [Sesh #42] Current Session: 5g earned", "Friend-OtherRealm")
		expect(message).toBe("look [Sesh #42] Current Session: 5g earned")
	end)
end)

describe("Level links", function()
	-- A character that finished level 10 in an hour and is now 25% into level 11.
	local function Leveled()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 52000)
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 69, "Timber Wolf", 1))
		world:Fire("PLAYER_DEAD")
		world:Advance(3600)
		Helpers.SetXP(world, 11, 275, 1100)
		world:Advance(600)
		return world, ns
	end

	it("writes chat lines for finished and current levels", function()
		local world, ns = Leveled()
		local now = world.clock.server
		local fields =
			{ duration = true, xpPerHour = true, goldEarned = true, goldPerHour = true, kills = true, deaths = true }
		local text = ns.Links.ChatText(ns.Leveling.View(10, now), fields, now, true)
		expect(text).toBe("Level 10 from 10% (1h 0m): 900 XP/hour · 5g 20s earned (5g/hour) · 1 kills · 1 deaths")
		local xpFields = { duration = true, xp = true, xpPerHour = true }
		local current = ns.Links.ChatText(ns.Leveling.View(11, now), xpFields, now, true)
		expect(current).toBe("Level 11, 25% so far (10m): 275 XP (1,650/hour)")
	end)

	it("shares a level as plain text", function()
		local world, ns = Leveled()
		ns.Links.Share(ns.Leveling.View(10, world.clock.server), { kills = true })
		expect(world.openedChat[1]).toBe("Level 10 from 10%: 1 kills")
	end)

	it("opens only the player's own levels", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.player.surname = "Smith"
			end,
		})
		local opened = {}
		ns.MainWindow.OpenLevel = function(level)
			opened[#opened + 1] = level
		end
		expect(ns.Links.MakeLevelLink(12)).toBe("|cffdca77f|Haddon:Sesh:Tester Smith-TestRealm:L12|h[Level 12]|h|r")
		world:ClickLink("addon:Sesh:Tester Smith-TestRealm:L12", "[Level 12]")
		world:ClickLink("addon:Sesh:Tester-TestRealm:L13", "[Level 13]")
		-- Another character's link, a link from before 0.2.0 and another addon's link.
		world:ClickLink("addon:Sesh:Tester Jones-TestRealm:L14", "[Level 14]")
		world:ClickLink("addon:Sesh:Friend-OtherRealm:L30", "[Sesh Lv30]")
		world:ClickLink("addon:Sesh:Tester Smith-TestRealm:5", "[Sesh #5]")
		world:ClickLink("addon:OtherAddon:whatever", "[x]")
		expect(opened).toEqual({ 12, 13 })
		expect(world.errors).toEqual({})
	end)
end)
