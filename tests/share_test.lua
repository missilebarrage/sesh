local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

-- Two clients: "owner" shares a session, "viewer" requests it. Addon whispers are carried
-- between their fake worlds by Deliver().
local function TwoPlayers(ownerOptions)
	ownerOptions = ownerOptions or {}
	ownerOptions.configure = function(world)
		world.player.name = "Owner"
	end
	local owner, ownerNs = Harness.Boot(ownerOptions)
	local viewer, viewerNs = Harness.Boot({
		configure = function(world)
			world.player.name = "Viewer"
			world.player.guid = "Player-1-0000BBBB"
		end,
	})
	return owner, ownerNs, viewer, viewerNs
end

local function Deliver(from, to, fromName)
	local delivered = 0
	local messages = from.addonMessages
	from.addonMessages = {}
	for _, message in ipairs(messages) do
		if message.result == 0 then
			to:Fire("CHAT_MSG_ADDON", message.prefix, message.message, "WHISPER", fromName)
			delivered = delivered + 1
		end
	end
	return delivered
end

local function Listener()
	local listener = { progress = {} }
	listener.OnComplete = function(view)
		listener.view = view
	end
	listener.OnError = function(reason)
		listener.error = reason
	end
	listener.OnProgress = function(received, total)
		listener.progress[#listener.progress + 1] = { received, total }
	end
	return listener
end

local function Exchange(owner, viewer)
	-- Request travels to the owner, then every reply slice comes back.
	Deliver(viewer, owner, "Viewer-TestRealm")
	owner:Advance(10)
	Deliver(owner, viewer, "Owner-TestRealm")
end

describe("Payload", function()
	it("builds a compact table and reads it back", function()
		local world, ns = Harness.Boot()
		Helpers.Item(world, 2589, 13)
		Helpers.GainMoney(world, 5000)
		Helpers.Loot(world, 2589, 20)
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 69, "Timber Wolf", 1))
		world:Advance(600)
		local now = world.clock.server
		local data = ns.Payload.Build(ns.Recorder.LiveView(now), now)
		expect(data.live).toBe(true)
		expect(data.endedAt).toBe(now)
		local view = ns.Payload.Read(Harness.Wow.RoundTrip(data), now)
		expect(view.kind).toBe("shared")
		expect(view.money).toBe(5000)
		expect(view.items[1]).toEqual({ itemID = 2589, count = 20, unitValue = 13, value = 260 })
		expect(view.monsters[1]).toEqual({ name = "Timber Wolf", count = 1, npcID = 69, typeID = 1 })
		expect(ns.Session.Metrics(view, now, true).duration).toBe(600)
	end)

	it("carries used-up items and a negative item value", function()
		local world, ns = Harness.Boot()
		Helpers.Item(world, 5, 40)
		Helpers.Item(world, 6, 900)
		local session = ns.Recorder.Current()
		ns.Session.AddItem(session, 5, 1)
		ns.Session.ConsumeItem(session, 6, 1)
		local now = world.clock.server
		local view = ns.Payload.Read(Harness.Wow.RoundTrip(ns.Payload.Build(ns.Recorder.LiveView(now), now)), now)
		expect(view.itemValue).toBe(40 - 900)
		expect(view.consumed).toEqual({ { itemID = 6, count = 1, unitValue = 900, value = 900 } })
		expect(ns.Session.Metrics(view, now, true).itemsUsedValue).toBe(900)
	end)

	it("caps list lengths", function()
		local world, ns = Harness.Boot()
		local session = ns.Recorder.Current()
		for itemID = 1, 80 do
			Helpers.Item(world, itemID, itemID)
			ns.Session.AddItem(session, itemID, 1)
		end
		local data = ns.Payload.Build(ns.Recorder.LiveView(), world.clock.server)
		expect(#data.items).toBe(50)
		expect(data.items[1][1]).toBe(80)
	end)

	it("rejects malformed or out-of-range data", function()
		local world, ns = Harness.Boot()
		local now = world.clock.server
		local function Valid()
			return {
				v = 2,
				kind = "session",
				id = 3,
				startedAt = now - 100,
				endedAt = now,
				live = false,
				duration = 100,
				afkSeconds = 0,
				sessionCount = 1,
				startLevel = 10,
				endLevel = 11,
				completed = false,
				fromPercent = 0,
				progress = 0,
				xpMax = 0,
				xp = 1,
				money = 2,
				itemValue = 3,
				kills = 4,
				unidentifiedKills = 0,
				deaths = 0,
				legacy = 0,
				questCount = 0,
				dungeonCount = 0,
				items = {},
				monsters = {},
				quests = {},
				zones = {},
				dungeons = {},
				achievements = {},
			}
		end
		expect(ns.Payload.Read(Valid(), now)).toBeTruthy()
		local cases = {
			function(d)
				d.v = 1
			end,
			function(d)
				d.kind = "raid"
			end,
			function(d)
				d.duration = 101
			end,
			function(d)
				d.live = "yes"
			end,
			function(d)
				d.dungeons = { { "The Deadmines", now - 50, 30, 101 } }
			end,
			function(d)
				d.kind, d.id = "level", 256
			end,
			function(d)
				d.kind, d.fromPercent = "level", 100
			end,
			function(d)
				d.money = -1
			end,
			function(d)
				d.money = 1.5
			end,
			function(d)
				d.xp = "5"
			end,
			function(d)
				d.endedAt = d.startedAt - 1
			end,
			function(d)
				d.startedAt = now + 3 * 86400
			end,
			function(d)
				d.afkSeconds = 101
			end,
			function(d)
				d.endLevel = 9
			end,
			function(d)
				d.items = { { 1, 2 } }
			end,
			function(d)
				d.items = { { 1, 0, 5 } }
			end,
			function(d)
				d.items = { [2] = { 1, 1, 1 } }
			end,
			function(d)
				d.monsters = { { "", 1, 0, 0 } }
			end,
			function(d)
				d.monsters = { { {}, 1, 0, 0 } }
			end,
			function(d)
				for index = 1, 31 do
					d.monsters[index] = { "Wolf", 1, 0, 0 }
				end
			end,
			function(d)
				d.zones = { { "Elwynn", 9, 10 } }
			end,
		}
		for index, breakIt in ipairs(cases) do
			local data = Valid()
			breakIt(data)
			if ns.Payload.Read(data, now) then
				error("case " .. index .. " was accepted")
			end
		end
		expect(world.errors).toEqual({})
	end)

	it("sanitizes names so they can't inject escape sequences", function()
		local world, ns = Harness.Boot()
		local now = world.clock.server
		local view = ns.Payload.Read({
			v = 2,
			kind = "session",
			id = 3,
			startedAt = now - 100,
			endedAt = now,
			live = false,
			duration = 100,
			afkSeconds = 0,
			startLevel = 0,
			endLevel = 0,
			xp = 0,
			money = 0,
			itemValue = 0,
			kills = 1,
			unidentifiedKills = 0,
			deaths = 0,
			legacy = 0,
			questCount = 0,
			dungeonCount = 0,
			items = {},
			monsters = { { "|Hurl:evil|h[Click]|h", 1, 0, 0 } },
			quests = {},
			zones = {},
			dungeons = {},
			achievements = {},
		}, now)
		expect(view.monsters[1].name).toBe("Hurl:evilh[Click]h")
	end)

	it("never throws on random input", function()
		local world, ns = Harness.Boot()
		math.randomseed(11)
		local function Random(depth)
			local kind = math.random(1, depth > 2 and 4 or 6)
			if kind == 1 then
				return math.random(-5, 5) * 10 ^ math.random(0, 12)
			elseif kind == 2 then
				return string.rep("x", math.random(0, 50))
			elseif kind == 3 then
				return math.random() > 0.5
			elseif kind == 4 then
				return nil
			end
			local t = {}
			for _ = 1, math.random(0, 6) do
				t[math.random(1, 3) == 1 and "items" or math.random(1, 8)] = Random(depth + 1)
			end
			return t
		end
		for _ = 1, 400 do
			local data = Random(0)
			if type(data) == "table" then
				data.v = 2
				data.kind = math.random() > 0.5 and "level" or "session"
			end
			expect(function()
				ns.Payload.Read(data, world.clock.server)
			end).notToThrow()
		end
		expect(world.errors).toEqual({})
	end)
end)

describe("Comm", function()
	it("transfers a shared session to another player", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		Helpers.Item(owner, 2589, 13)
		Helpers.GainMoney(owner, 123456)
		for _ = 1, 30 do
			Helpers.Loot(owner, 2589, 3)
		end
		owner:Advance(3600)
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)

		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", id, listener)
		Exchange(owner, viewer)
		expect(listener.error).toBeNil()
		expect(listener.view).toBeTruthy()
		expect(listener.view.money).toBe(123456)
		expect(listener.view.items[1].count).toBe(90)
		expect(listener.view.live).toBe(true)
	end)

	it("accepts the transfer when chat and addon messages spell the owner differently", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		local listener = Listener()
		-- The link came from chat with the surname; addon whispers arrive without it.
		viewerNs.Comm.Request("Owner Smith-TestRealm", "session", id, listener)
		expect(viewer.addonMessages[1].target).toBe("Owner Smith-TestRealm")
		Exchange(owner, viewer)
		expect(listener.error).toBeNil()
		expect(listener.view).toBeTruthy()
	end)

	it("only serves sessions the owner shared", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", ownerNs.Recorder.Current().id, listener)
		Exchange(owner, viewer)
		expect(listener.error).toBe("NF")
	end)

	it("refuses when the owner turned link requests off", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		ownerNs.Database.Set("allowLinkRequests", false)
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", id, listener)
		Exchange(owner, viewer)
		expect(listener.error).toBe("OFF")
	end)

	it("rate-limits a sender and refuses at most once per minute", function()
		local owner, ownerNs = Harness.Boot()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		for token = 1, 6 do
			local request = "R\t2\ttoken" .. token .. "\tS\t" .. id
			owner:Fire("CHAT_MSG_ADDON", "Sesh", request, "WHISPER", "Spammer-TestRealm")
		end
		owner:Advance(30)
		local refusals, slices = 0, 0
		for _, message in ipairs(owner.addonMessages) do
			if message.message:find("^E") then
				refusals = refusals + 1
			elseif message.message:find("^D") then
				slices = slices + 1
			end
		end
		expect(refusals).toBe(1)
		expect(slices).toBeGreaterThan(0)
	end)

	it("ignores slices nobody asked for and slices from the wrong player", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", id, listener)
		local request = viewer.addonMessages[1].message
		local token = request:match("^R\t2\t(%w+)")
		viewer:Fire("CHAT_MSG_ADDON", "Sesh", "D\t2\t" .. token .. "\t1\t1\tAAAA", "WHISPER", "Mallory-TestRealm")
		viewer:Fire("CHAT_MSG_ADDON", "Sesh", "D\t2\tunknown\t1\t1\tAAAA", "WHISPER", "Owner-TestRealm")
		expect(listener.error).toBeNil()
		expect(listener.view).toBeNil()
		Exchange(owner, viewer)
		expect(listener.view).toBeTruthy()
	end)

	it("reassembles slices that arrive out of order and ignores duplicates", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		local session = ownerNs.Recorder.Current()
		for itemID = 1, 50 do
			Helpers.Item(owner, itemID, itemID * 7)
			ownerNs.Session.AddItem(session, itemID, itemID)
		end
		ownerNs.Shares.Mark("session", session.id, owner.clock.server)
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", session.id, listener)
		Deliver(viewer, owner, "Viewer-TestRealm")
		owner:Advance(10)
		local messages = owner.addonMessages
		expect(#messages).toBeGreaterThan(1)
		for index = #messages, 1, -1 do
			viewer:Fire("CHAT_MSG_ADDON", "Sesh", messages[index].message, "WHISPER", "Owner-TestRealm")
			if index == #messages then
				viewer:Fire("CHAT_MSG_ADDON", "Sesh", messages[index].message, "WHISPER", "Owner-TestRealm")
			end
		end
		expect(listener.view).toBeTruthy()
		expect(#listener.view.items).toBe(50)
		expect(#listener.progress).toBe(#messages - 1)
	end)

	it("times out when the owner never answers", function()
		local _, _, viewer, viewerNs = TwoPlayers()
		viewer:Advance(1) -- let start-up debounces settle
		local baseline = viewer:PendingTimers()
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", 1, listener)
		viewer:Advance(9)
		expect(listener.error).toBeNil()
		viewer:Advance(2)
		expect(listener.error).toBe("TIMEOUT")
		-- The send pump and the timeout watchdog are gone again.
		expect(viewer:PendingTimers()).toBe(baseline)
	end)

	it("backs off when throttled and gives up on offline players", function()
		local owner, ownerNs = Harness.Boot()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		owner.sendResults = { 3, 3 }
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t2\tabc123\tS\t" .. id, "WHISPER", "Viewer-TestRealm")
		owner:Advance(0.2)
		expect(owner.addonMessages[1].result).toBe(3)
		owner:Advance(10)
		local delivered = 0
		for _, message in ipairs(owner.addonMessages) do
			if message.result == 0 then
				delivered = delivered + 1
			end
		end
		expect(delivered).toBeGreaterThan(0)

		owner.addonMessages = {}
		owner.sendResults = { 12 }
		local baseline = owner:PendingTimers()
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t2\tdef456\tS\t" .. id, "WHISPER", "Other-TestRealm")
		owner:Advance(10)
		expect(#owner.addonMessages).toBe(1)
		expect(owner:PendingTimers()).toBe(baseline)
	end)

	it("drops only the failed transfer when a player is offline", function()
		local owner, ownerNs = Harness.Boot()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		-- Two requests arrive in the same moment; the first requester has gone offline.
		owner.sendResults = { 12 }
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t2\taaaaaa\tS\t" .. id, "WHISPER", "Gone-TestRealm")
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t2\tbbbbbb\tS\t" .. id, "WHISPER", "Here-TestRealm")
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t2\tcccccc\tS\t9999", "WHISPER", "Other-TestRealm")
		owner:Advance(10)
		local sent = { Gone = 0, Here = 0, Other = 0 }
		for _, message in ipairs(owner.addonMessages) do
			local name = message.target:match("^(%a+)")
			sent[name] = sent[name] + 1
		end
		expect(sent.Gone).toBe(1)
		expect(sent.Here).toBeGreaterThan(0)
		expect(sent.Other).toBe(1) -- its refusal still goes out
	end)

	it("doesn't answer requests while chat is locked down", function()
		local owner, ownerNs = Harness.Boot()
		local id = ownerNs.Recorder.Current().id
		ownerNs.Shares.Mark("session", id, owner.clock.server)
		owner.chatLockdown = true
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t2\tabcdef\tS\t" .. id, "WHISPER", "Viewer-TestRealm")
		owner:Advance(5)
		expect(#owner.addonMessages).toBe(0)
	end)

	it("doesn't request while chat is locked down", function()
		local _, _, viewer, viewerNs = TwoPlayers()
		viewer.chatLockdown = true
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", 1, listener)
		expect(listener.error).toBe("LOCK")
		expect(#viewer.addonMessages).toBe(0)
	end)

	it("never sends messages longer than 255 bytes", function()
		local owner, ownerNs, viewer, viewerNs = TwoPlayers()
		local session = ownerNs.Recorder.Current()
		for index = 1, 30 do
			ownerNs.Session.AddKill(session, string.rep("Ü", 12) .. index, index, 7)
			ownerNs.Session.AddQuest(session, index, string.rep("Title ", 4), 100, 100)
		end
		ownerNs.Shares.Mark("session", session.id, owner.clock.server)
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "session", session.id, listener)
		Exchange(owner, viewer)
		expect(listener.view).toBeTruthy()
		expect(#listener.view.monsters).toBe(30)
	end)
end)

describe("Links", function()
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
		expect(text).toBe("[Sesh #1] Current Session (1h 0m): 10g 33s 5c earned (10g/hour) · 1,000 XP (1,000/hour)")
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

	it("shares by allow-listing the session and opening chat with the text", function()
		local world, ns = Harness.Boot()
		local view = ns.Recorder.LiveView()
		ns.Links.Share(view, { goldEarned = true })
		expect(ns.Shares.IsShared("session", view.id, world.clock.server)).toBe(true)
		expect(world.openedChat[1]).toBe("[Sesh #1] Current Session: 0c earned")
		local editBox = world.env.CreateFrame("EditBox")
		editBox:SetText("hi ")
		world.activeEditBox = editBox
		ns.Links.Share(view, { kills = true })
		expect(editBox:GetText()).toBe("hi [Sesh #1] Current Session: 0 kills")
	end)

	it("shares an old session for the next 30 days, counted from the share", function()
		local world, ns = Harness.Boot()
		local now = world.clock.server
		ns.History.Add(Helpers.Record(ns, { id = 50, startedAt = now - 40 * 86400, money = 5 }))
		ns.Links.Share(ns.Session.View(ns.History.Get(50)), { goldEarned = true })
		expect(ns.Shares.IsShared("session", 50, now)).toBe(true)
		expect(ns.Shares.IsShared("session", 50, now + 29 * 86400)).toBe(true)
		expect(ns.Shares.IsShared("session", 50, now + 31 * 86400)).toBe(false)
		expect(world.openedChat[1]).toMatch("^%[Sesh #50%] Session ")
	end)

	it("turns tokens in chat into links that remember the sender", function()
		local world = Harness.Boot()
		local message = world:Chat("CHAT_MSG_GUILD", "look [Sesh #42] Current Session: 5g earned", "Friend-OtherRealm")
		expect(message).toBe(
			"look |cffdca77f|Haddon:Sesh:Friend-OtherRealm:42|h[Sesh #42]|h|r Current Session: 5g earned"
		)
		local untouched, _, args = world:Chat("CHAT_MSG_SAY", "no token here", "Friend", "Common", "", "x")
		expect(untouched).toBe("no token here")
		expect(args[3]).toBe("Common")
		local own = world:Chat("CHAT_MSG_WHISPER_INFORM", "[Sesh #7]", "Friend-OtherRealm")
		expect(own).toContain("Haddon:Sesh:Tester-TestRealm:7|h")
		local sameRealm = world:Chat("CHAT_MSG_PARTY", "[Sesh #8]", "Buddy")
		expect(sameRealm).toContain("Haddon:Sesh:Buddy:8|h")
	end)

	it("recognizes your own links whether or not chat includes your surname", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.player.surname = "Smith"
			end,
		})
		local opened = {}
		ns.MainWindow.OpenSession = function(id)
			opened[#opened + 1] = "local " .. id
		end
		ns.SharedSessionWindow.Open = function(owner, kind, id)
			opened[#opened + 1] = owner .. " " .. kind .. " " .. id
		end
		world:ClickLink("addon:Sesh:Tester Smith-TestRealm:1", "[Sesh #1]")
		world:ClickLink("addon:Sesh:Tester-TestRealm:2", "[Sesh #2]")
		world:ClickLink("addon:Sesh:Tester Jones-TestRealm:3", "[Sesh #3]")
		expect(opened).toEqual({ "local 1", "local 2", "Tester Jones-TestRealm session 3" })
		local own = world:Chat("CHAT_MSG_WHISPER_INFORM", "[Sesh #4]", "Friend-OtherRealm")
		expect(own).toContain("Haddon:Sesh:Tester Smith-TestRealm:4|h")
	end)

	it("opens your own sessions locally and asks others for theirs", function()
		local world, ns = Harness.Boot()
		local openedLocal, openedRemote
		ns.MainWindow.OpenSession = function(id)
			openedLocal = id
		end
		ns.SharedSessionWindow.Open = function(owner, kind, id)
			openedRemote = { owner, kind, id }
		end
		world:ClickLink("addon:Sesh:Tester-TestRealm:3", "[Sesh #3]")
		world:ClickLink("addon:Sesh:Friend-OtherRealm:9", "[Sesh #9]")
		world:ClickLink("addon:OtherAddon:whatever", "[x]")
		expect(openedLocal).toBe(3)
		expect(openedRemote).toEqual({ "Friend-OtherRealm", "session", 9 })
	end)
end)

describe("Shares", function()
	it("expires shares 30 days after sharing, separately for sessions and levels", function()
		local world, ns = Harness.Boot()
		local day = 86400
		ns.Shares.Mark("session", 1, 1000)
		expect(ns.Shares.IsShared("session", 1, 1000 + 29 * day)).toBe(true)
		expect(ns.Shares.IsShared("session", 1, 1000 + 31 * day)).toBe(false)
		expect(ns.Shares.IsShared("level", 1, 1000)).toBe(false)
		ns.Shares.Mark("level", 12, 1000 + 31 * day)
		expect(ns.Shares.IsShared("level", 12, 1000 + 31 * day)).toBe(true)
		ns.Shares.Mark("session", 2, 1000 + 31 * day)
		expect(world.env.SeshCharDB.shared[1]).toBeNil()
		expect(world.env.SeshCharDB.sharedLevels[12]).toBe(1000 + 31 * day)
	end)
end)

describe("Level sharing", function()
	-- A character that finished level 10 in an hour and is now 25% into level 11.
	local function LeveledOwner(name)
		local world, ns = Harness.Boot({
			configure = function(w)
				w.player.name = name or "Tester"
			end,
		})
		Helpers.GainMoney(world, 52000)
		Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 69, "Timber Wolf", 1))
		world:Fire("PLAYER_DEAD")
		world:Advance(3600)
		Helpers.SetXP(world, 11, 275, 1100)
		world:Advance(600)
		return world, ns
	end

	it("writes chat lines for finished and current levels", function()
		local world, ns = LeveledOwner()
		local now = world.clock.server
		local fields =
			{ duration = true, xpPerHour = true, goldEarned = true, goldPerHour = true, kills = true, deaths = true }
		local text = ns.Links.ChatText(ns.Leveling.View(10, now), fields, now, true)
		expect(text).toBe(
			"[Sesh Lv10] Level 10 from 10% (1h 0m): 900 XP/hour · 5g 20s earned (5g/hour) · 1 kills · 1 deaths"
		)
		local xpFields = { duration = true, xp = true, xpPerHour = true }
		local current = ns.Links.ChatText(ns.Leveling.View(11, now), xpFields, now, true)
		expect(current).toBe("[Sesh Lv11] Level 11, 25% so far (10m): 275 XP (1,650/hour)")
	end)

	it("turns level tokens into links, along with session tokens", function()
		local world = Harness.Boot()
		local message = world:Chat("CHAT_MSG_PARTY", "[Sesh Lv23] Level 23 (2h 0m) and [Sesh #4]", "Friend-OtherRealm")
		expect(message).toBe(
			"|cffdca77f|Haddon:Sesh:Friend-OtherRealm:L23|h[Sesh Lv23]|h|r Level 23 (2h 0m) and "
				.. "|cffdca77f|Haddon:Sesh:Friend-OtherRealm:4|h[Sesh #4]|h|r"
		)
		local capped = world:Chat("CHAT_MSG_SAY", "[Sesh #1] [Sesh #2] [Sesh #3] [Sesh Lv4]", "Friend")
		expect(capped).toContain("|h[Sesh #3]|h|r [Sesh Lv4]")
	end)

	it("opens your own levels locally and asks others for theirs", function()
		local world, ns = Harness.Boot()
		local opened = {}
		ns.MainWindow.OpenLevel = function(level)
			opened[#opened + 1] = "local " .. level
		end
		ns.SharedSessionWindow.Open = function(owner, kind, id)
			opened[#opened + 1] = owner .. " " .. kind .. " " .. id
		end
		world:ClickLink("addon:Sesh:Tester-TestRealm:L12", "[Sesh Lv12]")
		world:ClickLink("addon:Sesh:Friend-OtherRealm:L30", "[Sesh Lv30]")
		expect(opened).toEqual({ "local 12", "Friend-OtherRealm level 30" })
	end)

	it("shares a level by allow-listing it", function()
		local world, ns = LeveledOwner()
		ns.Links.Share(ns.Leveling.View(10, world.clock.server), { kills = true })
		expect(ns.Shares.IsShared("level", 10, world.clock.server)).toBe(true)
		expect(ns.Shares.IsShared("session", 1, world.clock.server)).toBe(false)
		expect(world.openedChat[1]).toBe("[Sesh Lv10] Level 10 from 10%: 1 kills")
	end)

	it("builds a level payload and reads it back", function()
		local world, ns = LeveledOwner()
		local now = world.clock.server
		local finished = ns.Payload.Read(Harness.Wow.RoundTrip(ns.Payload.Build(ns.Leveling.View(10, now), now)), now)
		expect(finished.level).toBe(10)
		expect(finished.completed).toBe(true)
		expect(finished.live).toBe(false)
		expect(finished.fromPercent).toBe(10)
		expect(finished.xpMax).toBe(1000)
		expect(ns.Session.Metrics(finished, now, true).duration).toBe(3600)
		expect(finished.money).toBe(52000)
		expect(finished.monsters[1].name).toBe("Timber Wolf")

		local current = ns.Payload.Read(ns.Payload.Build(ns.Leveling.View(11, now), now), now)
		expect(current.live).toBe(true)
		expect(current.progress).toBe(25)
		expect(ns.Session.Metrics(current, now, true).duration).toBe(600)
	end)

	it("transfers a shared level to another player", function()
		local owner, ownerNs = LeveledOwner("Owner")
		local viewer, viewerNs = Harness.Boot({
			configure = function(w)
				w.player.name = "Viewer"
				w.player.guid = "Player-1-0000BBBB"
			end,
		})
		ownerNs.Shares.Mark("level", 10, owner.clock.server)
		local listener = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "level", 10, listener)
		expect(viewer.addonMessages[1].message).toMatch("^R\t2\t%w+\tL\t10$")
		Exchange(owner, viewer)
		expect(listener.error).toBeNil()
		expect(listener.view.level).toBe(10)
		expect(listener.view.kills).toBe(1)

		-- Level 11 wasn't shared.
		local refused = Listener()
		viewerNs.Comm.Request("Owner-TestRealm", "level", 11, refused)
		viewer:Advance(1)
		Exchange(owner, viewer)
		expect(refused.error).toBe("NF")
	end)

	it("refuses requests from other versions of the protocol, and says so", function()
		local owner = Harness.Boot()
		owner:Fire("CHAT_MSG_ADDON", "Sesh", "R\t1\tabcdef\t1", "WHISPER", "Old-TestRealm")
		owner:Advance(1)
		expect(owner.addonMessages[1].message).toBe("E\t2\tabcdef\tVER")

		local viewer, viewerNs = Harness.Boot()
		local listener = Listener()
		viewerNs.Comm.Request("Newer-TestRealm", "level", 3, listener)
		local token = viewer.addonMessages[1].message:match("^R\t2\t(%w+)")
		viewer:Fire("CHAT_MSG_ADDON", "Sesh", "E\t3\t" .. token .. "\tVER", "WHISPER", "Newer-TestRealm")
		expect(listener.error).toBe("VER")
	end)

	it("opens a level someone shared in the shared window", function()
		local owner, ownerNs = LeveledOwner("Owner")
		ownerNs.Shares.Mark("level", 10, owner.clock.server)
		local viewer, viewerNs = Harness.Boot()
		viewer:ClickLink("addon:Sesh:Owner-TestRealm:L10", "[Sesh Lv10]")
		Exchange(owner, viewer)
		local window = viewer.env.SeshSharedSessionWindow
		expect(window.status:IsShown()).toBe(false)
		expect(window.info:GetText()).toMatch("^Level 10")
		expect(viewerNs.L.LEVEL_N:format(10)).toBe("Level 10")
		expect(viewer.errors).toEqual({})
	end)
end)
