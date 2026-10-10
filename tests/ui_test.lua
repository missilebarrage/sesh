local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

local function BusySession(world, ns)
	Helpers.Item(world, 2589, 13)
	Helpers.Item(world, 4306, 90)
	Helpers.GainMoney(world, 52310)
	Helpers.Loot(world, 2589, 20)
	Helpers.Loot(world, 4306, 3)
	Helpers.Kill(world, Helpers.ShowMonster(world, "nameplate1", 69, "Timber Wolf", 1))
	world.quests[176] = "Wanted: Hogger"
	world:Fire("QUEST_TURNED_IN", 176, 450, 1200)
	world:Fire("PLAYER_DEAD")
	Helpers.SetXP(world, 10, 600, 1000)
	world:Advance(1800)
	return ns.Recorder.Current()
end

local function AddHistory(ns, count, firstStart)
	for index = 1, count do
		ns.History.Add(Helpers.Record(ns, {
			id = 1000 + index,
			startedAt = firstStart + index * 6 * 3600,
			duration = 3600,
			money = index * 100,
			xp = index * 10,
			kills = index % 50,
			items = { { itemID = 2589, count = 2, unitValue = 13, value = 26 } },
			monsters = { { name = "Wolf " .. (index % 7), count = 3, npcID = 69, typeID = 1 } },
			zones = { { name = "Elwynn Forest", kind = 0, seconds = 3600 } },
		}))
	end
end

describe("Main window", function()
	it("opens on the current session and fills the cards and lists", function()
		local world, ns = Harness.Boot({ auctionator = true })
		BusySession(world, ns)
		world.env.SlashCmdList.SESH("")
		local frame = world.env.SeshMainWindow
		expect(frame:IsShown()).toBe(true)
		expect(frame.title:GetText()).toBe("SESH")
		world:Advance(0.2)
		expect(world.errors).toEqual({})
	end)

	it("keeps texture escapes out of card detail lines, which may be shortened", function()
		local world, ns = Harness.Boot({ auctionator = true })
		BusySession(world, ns)
		ns.MainWindow.Open("session")
		ns.MainWindow.Open("summary")
		world:Advance(0.2)
		local checked = 0
		local function Check(frame)
			for _, child in ipairs(frame.children or {}) do
				if child.sub and child.value and child.label then
					checked = checked + 1
					expect((child.sub:GetText() or ""):find("|T", 1, true)).toBeNil()
				end
				Check(child)
			end
		end
		Check(world.env.SeshMainWindow)
		expect(checked).toBe(16)
	end)

	it("shows a cog on the options button, drawn when the client lacks the atlas", function()
		local world, ns = Harness.Boot()
		ns.MainWindow.Open()
		local glyph = world.env.SeshMainWindow.optionsButton.strokes
		expect(#glyph).toBe(1)
		expect(glyph[1].atlas).toBe("questlog-icon-setting")

		local bare, bareNs = Harness.Boot({
			configure = function(w)
				w.missingAtlases["questlog-icon-setting"] = true
			end,
		})
		bareNs.MainWindow.Open()
		expect(#bare.env.SeshMainWindow.optionsButton.strokes).toBe(9) -- disc and eight teeth
		expect(bare.errors).toEqual({})
	end)

	it("runs its ticker only while open", function()
		local world, ns = Harness.Boot()
		ns.Database.Set("miniMode", false)
		world:Advance(1)
		local closed = world:PendingTimers()
		ns.MainWindow.Open()
		expect(world:PendingTimers()).toBe(closed + 1)
		ns.MainWindow.Toggle()
		world:Advance(2)
		expect(world:PendingTimers()).toBe(closed)

		-- In mini mode, one of the two windows (and its ticker) is always up.
		ns.Database.Set("miniMode", true)
		world:Advance(1)
		local mini = world:PendingTimers()
		expect(mini).toBe(closed + 1)
		ns.MainWindow.Open()
		expect(world:PendingTimers()).toBe(mini)
		ns.MainWindow.Toggle()
		expect(world:PendingTimers()).toBe(mini)
	end)

	it("shows every tab with no history and with 2,000 sessions", function()
		for _, count in ipairs({ 0, 2000 }) do
			local world, ns = Harness.Boot()
			BusySession(world, ns)
			AddHistory(ns, count, world.clock.server - 2001 * 6 * 3600)
			local started = os.clock()
			for _, tab in ipairs({ "session", "history", "leveling", "summary", "session" }) do
				ns.MainWindow.Open(tab)
				world:Advance(0.2)
			end
			expect(world.errors).toEqual({})
			expect(os.clock() - started).toBeLessThan(5)
		end
	end)

	it("drills into a finished session and deletes it after confirmation", function()
		local world, ns = Harness.Boot()
		AddHistory(ns, 3, world.clock.server - 3 * 86400)
		ns.MainWindow.OpenSession(1002)
		expect(world.errors).toEqual({})
		local dialog = world.env.StaticPopupDialogs.SESH_DELETE_SESSION
		expect(dialog).toBeTruthy()
		dialog.OnAccept(nil, 1002)
		world:Advance(0.2)
		expect(ns.History.Get(1002)).toBeNil()
		expect(world.errors).toEqual({})
	end)

	it("opens the running session on the Session tab", function()
		local world, ns = Harness.Boot()
		ns.MainWindow.OpenSession(ns.Recorder.Current().id)
		expect(world.env.SeshMainWindow:IsShown()).toBe(true)
		expect(world.errors).toEqual({})
	end)

	it("doesn't create new frames when the summary refreshes", function()
		local world, ns = Harness.Boot()
		BusySession(world, ns)
		AddHistory(ns, 50, world.clock.server - 60 * 86400)
		ns.MainWindow.Open("summary")
		world:Advance(0.2)
		local created = world.createdObjects
		ns.Session.AddMoney(ns.Recorder.Current(), 5)
		world:Advance(1)
		expect(world.createdObjects).toBe(created)
		expect(world.errors).toEqual({})
	end)

	it("filters History by a heatmap day", function()
		local world, ns = Harness.Boot()
		AddHistory(ns, 5, world.clock.server - 5 * 86400)
		ns.MainWindow.OpenDay(ns.Stats.DayOf(world.clock.server) - 2)
		world:Advance(0.2)
		expect(world.errors).toEqual({})
	end)
end)

describe("Theme", function()
	it("follows EllesmereUI's accent colour and font", function()
		local world, ns = Harness.Boot({ ellesmere = true })
		expect({ ns.Theme.Accent() }).toEqual({ 0.2, 0.4, 0.6 })
		expect(world.env.SeshFontBody.path).toBe("Fonts\\Expressway.ttf")
		ns.MainWindow.Open()
		local underline = world.env.SeshMainWindow.tabs.tabs[1].underline
		world.accentCallbacks[1](1, 0, 0)
		expect(underline.color).toEqual({ 1, 0, 0, 1 })
		expect(ns.Theme.AccentHex()).toBe("ff0000")
	end)

	it("uses Arial Narrow by default and the game font when a font can't load", function()
		local world = Harness.Boot()
		expect(world.env.SeshFontBody.path).toBe("Fonts\\ARIALN.TTF")
		local broken = Harness.Boot({
			ellesmere = true,
			configure = function(w)
				w.missingFonts["Fonts\\Expressway.ttf"] = true
			end,
		})
		expect(broken.env.SeshFontBody.path).toBe("Fonts\\FRIZQT__.TTF")
		expect(broken.errors).toEqual({})
	end)

	it("uses the Forever bronze accent without EllesmereUI", function()
		local _, ns = Harness.Boot()
		expect(ns.Theme.AccentHex()).toBe("dca77f")
	end)

	it("trusts the first candidate when the client can't probe files", function()
		local _, ns = Harness.Load({
			configure = function(world)
				world.missingFiles["Interface\\Icons\\INV_Misc_QuestionMark"] = true
				world.missingFiles["Interface\\Icons\\INV_Misc_PocketWatch_01"] = true
			end,
		})
		expect(ns.Theme.Icon("duration")).toBe("Interface\\Icons\\INV_Misc_PocketWatch_01")
		expect(ns.Theme.MissingIcons()).toEqual({})
	end)

	it("falls back to a question mark for missing icon art", function()
		local _, ns = Harness.Load({
			configure = function(world)
				world.missingFiles["Interface\\Icons\\INV_Misc_PocketWatch_01"] = true
			end,
		})
		expect(ns.Theme.Icon("duration")).toBe("Interface\\Icons\\INV_Misc_QuestionMark")
		expect(ns.Theme.MissingIcons()).toEqual({ "duration" })
	end)
end)

describe("Share dialog", function()
	it("previews the chat line, remembers choices and inserts into chat", function()
		local world, ns = Harness.Boot()
		BusySession(world, ns)
		ns.MainWindow.Open()
		ns.MainWindow.Share()
		local dialog = world.env.SeshShareDialog
		expect(dialog:IsShown()).toBe(true)
		expect(dialog.preview:GetText()).toMatch("^Current Session")
		expect(dialog.note:GetText()).toBe(ns.L.SHARE_NOTE)
		dialog.checkboxes.kills:Click()
		expect(ns.Database.Get("shareFields").kills).toBeNil()
		dialog.checkboxes.zones:Click()
		expect(ns.Database.Get("shareFields").zones).toBe(true)
		expect(dialog.preview:GetText()).toContain("1 zones")
		expect(#dialog.preview:GetText() <= 255).toBe(true)
		dialog.insert:Click()
		expect(world.openedChat[1]).toBe(dialog.preview:GetText())
		expect(dialog:IsShown()).toBe(false)
	end)
end)

describe("Options", function()
	it("registers native settings that update Sesh live", function()
		local world, ns = Harness.Boot({ ldb = true })
		local category = world.settingsCategories[1]
		expect(category.registered).toBe(true)
		for _, key in ipairs({
			"openOnLogin",
			"windowScale",
			"excludeAfk",
			"resumeMinutes",
			"minSessionMinutes",
			"weekStart",
			"heatmapMetric",
			"announceLevels",
			"miniMode",
			"miniScale",
			"miniOpacity",
			"levelChartMetric",
			"brokerMetric",
		}) do
			expect(category.settings[key]).toBeTruthy()
		end
		ns.MainWindow.Open()
		category.settings.windowScale:SetValue(1.2)
		expect(world.env.SeshMainWindow:GetScale()).toBe(1.2)
		category.settings.weekStart:SetValue(2)
		expect(world.env.SeshDB.settings.weekStartChosen).toBe(true)
		ns.Options.Open()
		expect(world.openedSettings).toEqual({ 77 })
		world.combat = true
		ns.Options.Open()
		expect(#world.openedSettings).toBe(1)
	end)

	it("leaves out the data text option without a data broker", function()
		local world = Harness.Boot()
		expect(world.settingsCategories[1].settings.brokerMetric).toBeNil()
	end)
end)

describe("Data broker and compartment", function()
	it("publishes the chosen metric and opens the window on click", function()
		local world, ns = Harness.Boot({ ldb = true, compartment = true })
		BusySession(world, ns)
		local object = world.ldbObjects.Sesh
		expect(object).toBeTruthy()
		world:Advance(30)
		expect(object.text).toMatch("/h$")
		ns.Database.Set("brokerMetric", "duration")
		expect(object.text).toBe("30m")
		object.OnClick(nil, "LeftButton")
		expect(world.env.SeshMainWindow:IsShown()).toBe(true)
		expect(world.compartment[1].text).toBe("Sesh")
		local tooltip = world.env.GameTooltip
		object.OnTooltipShow(tooltip)
		expect(#tooltip.lines).toBeGreaterThan(3)
	end)
end)

describe("Slash command", function()
	it("prints debug information without names", function()
		local world, ns = Harness.Boot()
		BusySession(world, ns)
		world.env.SlashCmdList.SESH("debug")
		world.env.SlashCmdList.SESH("debug perf")
		for _, line in ipairs(world.printed) do
			expect(line:find("Tester", 1, true)).toBeNil()
			expect(line:find("Timber Wolf", 1, true)).toBeNil()
		end
		expect(#world.printed).toBeGreaterThan(4)
	end)

	it("opens the Leveling tab", function()
		local world = Harness.Boot()
		world.env.SlashCmdList.SESH("leveling")
		expect(world.env.SeshMainWindow:IsShown()).toBe(true)
		expect(world.env.SeshMainWindow.tabs.selected).toBe("leveling")
	end)

	it("starts a new session and shows help for unknown commands", function()
		local world, ns = Harness.Boot()
		Helpers.GainMoney(world, 10)
		world.env.SlashCmdList.SESH("new")
		expect(ns.Recorder.Current().id).toBe(2)
		world.env.SlashCmdList.SESH("wat")
		expect(world.printed[#world.printed]).toContain("/sesh share")
	end)
end)

describe("Localization", function()
	it("defines every string the code uses", function()
		local _, ns = Harness.Load()
		local missing = {}
		local dynamic = {
			LIST_ = { "SESSIONS", "ITEMS", "MONSTERS", "QUESTS", "ZONES", "DUNGEONS" },
			EMPTY_ = { "SESSIONS", "ITEMS", "MONSTERS", "QUESTS", "ZONES", "DUNGEONS" },
			FIELD_ = {},
		}
		for _, field in ipairs(ns.Links.FIELDS) do
			table.insert(dynamic.FIELD_, field:upper())
		end
		local function Check(key)
			if rawget(ns.L, key) == nil then
				missing[#missing + 1] = key
			end
		end
		for _, file in ipairs(Harness.TocFiles()) do
			local source = io.open(ROOT_DIR .. "/Sesh/" .. file):read("*a")
			for key in source:gmatch("L%.([%u_][%u%d_]*)") do
				Check(key)
			end
		end
		for prefix, suffixes in pairs(dynamic) do
			for _, suffix in ipairs(suffixes) do
				Check(prefix .. suffix)
			end
		end
		expect(missing).toEqual({})
	end)
end)

-- Finds the first frame under `frame` (depth first) that has the given field.
local function FindWith(frame, field)
	for _, child in ipairs(frame.children or {}) do
		if rawget(child, field) ~= nil then
			return child
		end
		local found = FindWith(child, field)
		if found then
			return found
		end
	end
end

-- A busy session that went from level 10 to 12, now 25% into level 12.
local function LeveledSession(world, ns)
	BusySession(world, ns)
	Helpers.SetXP(world, 11, 100, 1100)
	world:Advance(2400)
	Helpers.SetXP(world, 12, 50, 1200)
	world:Advance(600)
	Helpers.SetXP(world, 12, 300, 1200)
end

describe("Leveling tab", function()
	it("shows the current level, a bar per level and the level list", function()
		local world, ns = Harness.Boot()
		LeveledSession(world, ns)
		world.player.rested = 600
		ns.MainWindow.Open("leveling")
		world:Advance(0.2)
		local view = FindWith(world.env.SeshMainWindow, "chart")
		local progress = view.progress
		expect(progress.level:GetText()).toBe("Level 12")
		expect(progress.percent:GetText()).toBe("25%")
		expect(progress.detail:GetText()).toBe("300 / 1,200 XP  ·  600 rested")
		expect(progress.time:GetText()).toMatch("^10m at this level  ·  level 13 in ")
		expect(progress.rested:IsShown()).toBe(true)
		local shownBars = 0
		for _, bar in ipairs(view.chart.bars) do
			shownBars = shownBars + (bar:IsShown() and 1 or 0)
		end
		expect(shownBars).toBe(3)
		expect(view.journey:GetText()).toMatch("^3 levels  ·  1h 20m played  ·  40m per level on average")
		expect(#view.list.rows).toBe(3)
		expect(view.list.scrollBox.rows[1].badge.text:GetText()).toBe("12")
		expect(view.list.scrollBox.rows[1].value:GetText()).toBe("10m")
		expect(world.errors).toEqual({})

		local before = progress.time:GetText()
		world:Advance(60)
		expect(progress.time:GetText()).toMatch("^11m at this level")
		expect(progress.time:GetText() ~= before).toBe(true)
	end)

	it("opens a level from the chart, the list and the progress panel", function()
		local world, ns = Harness.Boot()
		LeveledSession(world, ns)
		ns.MainWindow.Open("leveling")
		local view = FindWith(world.env.SeshMainWindow, "chart")
		local hit = view.chart.hit
		world.cursor.x = 30 -- over the second bar
		hit:GetScript("OnEnter")(hit)
		hit:GetScript("OnUpdate")(hit)
		expect(world.env.GameTooltip.lines[1][1]).toBe("Time played")
		hit:Click()
		expect(view.detail:IsShown()).toBe(true)
		expect(view.detailTitle:GetText()).toBe("Level 11")
		expect(view.detailInfo:GetText()).toMatch("1 session$")
		view.back:Click()
		expect(view.overview:IsShown()).toBe(true)

		local row = view.list.scrollBox.rows[3]
		row:Click()
		expect(view.detailTitle:GetText()).toBe("Level 10")
		expect(view.detailInfo:GetText()).toMatch("tracked from 10%%")
		view.back:Click()
		view.progress:Click()
		expect(view.detailTitle:GetText()).toBe("Level 12")
		expect(view.detailInfo:GetText()).toMatch("^In progress · 25%%")
		expect(world.errors).toEqual({})
	end)

	it("shares the level in view", function()
		local world, ns = Harness.Boot()
		LeveledSession(world, ns)
		ns.MainWindow.Open("leveling")
		ns.MainWindow.Share()
		local dialog = world.env.SeshShareDialog
		expect(dialog.title:GetText()).toBe("SHARE LEVEL")
		expect(dialog.preview:GetText()).toMatch("^Level 12, 25%% so far")
		expect(dialog.checkboxes.levels:IsShown()).toBe(false)
		expect(dialog.checkboxes.dungeons:IsShown()).toBe(true)
		dialog.checkboxes.zones:Click()
		expect(ns.Database.Get("levelShareFields").zones).toBe(true)
		expect(ns.Database.Get("shareFields").zones).toBeNil()

		local view = FindWith(world.env.SeshMainWindow, "chart")
		view:OpenLevel(10)
		view.shareButton:Click()
		expect(dialog.preview:GetText()).toMatch("^Level 10")
		dialog.insert:Click()
		expect(world.openedChat[1]).toMatch("^Level 10")

		-- Sessions still share as sessions, with their own choices.
		ns.MainWindow.Open("session")
		ns.MainWindow.Share()
		expect(dialog.title:GetText()).toBe("SHARE SESSION")
		expect(dialog.checkboxes.levels:IsShown()).toBe(true)
		expect(dialog.preview:GetText()).toMatch("^Current Session")
		expect(world.errors).toEqual({})
	end)

	it("shows the level cap without a level in progress", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.player.maxLevel = 10
			end,
		})
		ns.MainWindow.Open("leveling")
		local view = FindWith(world.env.SeshMainWindow, "chart")
		expect(view.progress.percent:GetText()).toBe("Max level")
		expect(view.progress.track:IsShown()).toBe(false)
		expect(view.chart.empty:IsShown()).toBe(true)
		expect(view.journey:GetText()).toBe(ns.L.LEVELING_EMPTY)
		ns.MainWindow.Share()
		expect(world.env.SeshShareDialog.preview:GetText()).toMatch("^Current Session")
		expect(world.errors).toEqual({})
	end)

	it("doesn't create new frames when it refreshes", function()
		local world, ns = Harness.Boot()
		LeveledSession(world, ns)
		ns.MainWindow.Open("leveling")
		world:Advance(0.2)
		local created = world.createdObjects
		ns.Session.AddMoney(ns.Recorder.Current(), 5)
		world:Advance(1)
		expect(world.createdObjects).toBe(created)
	end)
end)

describe("Session dungeons", function()
	it("lists dungeon runs and counts them in the extras", function()
		local world, ns = Harness.Boot()
		world.zone = { name = "The Deadmines", instanceType = "party" }
		world:Fire("PLAYER_ENTERING_WORLD", false, false)
		world:Fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
		world:Fire("PLAYER_DEAD")
		ns.MainWindow.Open("session")
		local view = FindWith(world.env.SeshMainWindow, "listTabs")
		view:SetListKind("dungeons")
		local row = view.list.scrollBox.rows[1]
		expect(row.name:GetText()).toBe("The Deadmines")
		expect(row.detail:GetText()).toBe("1 boss")
		expect(row.value:GetText()).toBe("In progress")
		expect(view.extras.text:GetText()).toContain("1 death")
		expect(world.errors).toEqual({})
	end)
end)

describe("Mini window", function()
	local function Mini(world)
		return world.env.SeshMiniWindow
	end

	local function ShownRows(world, labelsOnly)
		local labels = {}
		for _, row in ipairs(Mini(world).rows) do
			if row:IsShown() then
				labels[#labels + 1] = row.label:GetText() .. (labelsOnly and "" or ("=" .. row.value:GetText()))
			end
		end
		return labels
	end

	it("stands in for the closed Sesh window with the chosen numbers", function()
		local world, ns = Harness.Boot()
		expect(Mini(world):IsShown()).toBe(true)
		Helpers.GainMoney(world, 52000)
		Helpers.SetXP(world, 10, 400, 1000)
		world:Advance(3600)
		expect(ShownRows(world)).toEqual({
			"Session time=1h 0m",
			"Gold earned=" .. ns.Format.MoneyShort(52000),
			"Gold / hour=" .. ns.Format.MoneyShort(52000),
			"XP / hour=300",
			"Level up in=2h 0m",
		})
		-- Just the five rows: no title bar.
		expect(Mini(world):GetHeight()).toBe(4 + 5 * 18 + 4)
		-- The first row starts at the top edge (stored as SetPoint("TOPLEFT", 0, -4)).
		expect(Mini(world).rows[1].points[1]).toEqual({ "TOPLEFT", 0, -4 })
		expect(world.errors).toEqual({})
	end)

	it("opens Sesh on click and comes back when Sesh closes", function()
		local world, ns = Harness.Boot()
		Mini(world):Click()
		expect(world.env.SeshMainWindow:IsShown()).toBe(true)
		expect(Mini(world):IsShown()).toBe(false)
		world.env.SeshMainWindow.close:Click()
		expect(Mini(world):IsShown()).toBe(true)
		-- The minimize button collapses Sesh into the mini window.
		ns.MainWindow.Open("history")
		world.env.SeshMainWindow.minimizeButton:Click()
		expect(world.env.SeshMainWindow:IsShown()).toBe(false)
		expect(Mini(world):IsShown()).toBe(true)
	end)

	it("moves only with Shift held, and remembers where it was put", function()
		local world, ns = Harness.Boot()
		local mini = Mini(world)
		world.shiftDown = true
		mini:GetScript("OnMouseDown")(mini, "LeftButton")
		expect(mini.moving).toBe(true)
		mini:GetScript("OnMouseUp")(mini, "LeftButton")
		mini:Click()
		expect(ns.MainWindow.IsShown()).toBe(false)
		-- Kept by its top-left corner (the fake client puts every frame's left edge at 0).
		local height = mini:GetHeight()
		expect(world.env.SeshDB.windows.mini).toEqual({
			point = "TOPLEFT",
			relativePoint = "BOTTOMLEFT",
			x = 0,
			y = height,
		})

		world:Advance(0.5)
		world.shiftDown = false
		mini:GetScript("OnMouseDown")(mini, "LeftButton")
		expect(mini.moving).toBeNil()
		mini:Click()
		expect(ns.MainWindow.IsShown()).toBe(true)

		local reloaded = Harness.Restart(world, { reload = true })
		local point, _, relativePoint, x, y = Mini(reloaded):GetPoint(1)
		expect({ point, relativePoint, x, y }).toEqual({ "TOPLEFT", "BOTTOMLEFT", 0, height })
	end)

	it("hides from its menu until turned back on", function()
		local world, ns = Harness.Boot()
		local mini = Mini(world)
		mini:GetScript("OnEnter")(mini)
		expect(mini.hover:IsShown()).toBe(true)
		-- Just how to use it: the numbers are on the window.
		expect(#world.env.GameTooltip.lines).toBe(3)
		expect(world.env.GameTooltip.lines[3][1]).toBe(ns.L.MINI_HINT_MENU)
		mini:Click("RightButton")
		local hide
		for _, entry in ipairs(world.menus[1].entries) do
			if entry.text == ns.L.MINI_HIDE then
				hide = entry
			end
		end
		hide.callback()
		expect(mini:IsShown()).toBe(false)
		expect(ns.Database.Get("miniMode")).toBe(false)
		expect(world.printed[#world.printed]).toContain("/sesh mini")
		-- Closing Sesh no longer brings it back.
		ns.MainWindow.Open()
		ns.MainWindow.Close()
		expect(mini:IsShown()).toBe(false)
		world.env.SlashCmdList.SESH("mini")
		expect(mini:IsShown()).toBe(true)
		local reloaded = Harness.Restart(world, { reload = true })
		expect(Mini(reloaded):IsShown()).toBe(true)
	end)

	it("lets the player choose its numbers from a right-click menu", function()
		local world, ns = Harness.Boot()
		local mini = Mini(world)
		mini:Click("RightButton")
		local menu = world.menus[1]
		expect(menu.entries[1].text).toBe(ns.L.MINI_SHOWS)
		local kills, goldPerHour
		for _, entry in ipairs(menu.entries) do
			if entry.data == "kills" then
				kills = entry
			elseif entry.data == "goldPerHour" then
				goldPerHour = entry
			end
		end
		expect(kills.isSelected(kills.data)).toBe(false)
		kills.setSelected(kills.data)
		goldPerHour.setSelected(goldPerHour.data)
		world:Advance(0.2)
		local rows = ShownRows(world, true)
		expect(rows).toEqual({ "Session time", "Gold earned", "Monsters slain", "XP / hour", "Level up in" })
		expect(ns.Database.Get("miniFields").goldPerHour).toBe(false)
		-- The options panel shows the same switches, and is told about the change.
		local setting = world.settingsCategories[1].settings.kills
		expect(setting:GetValue()).toBe(true)
		expect(setting.notified).toBeGreaterThan(0)
		expect(ns.Database.Get("miniFields").kills).toBe(true)
	end)

	it("shows the level's progress, and no leveling numbers at the level cap", function()
		local world, ns = Harness.Boot()
		world.player.rested = 300
		local fields = ns.Database.Get("miniFields")
		fields.levelProgress = true
		ns.Database.Set("miniFields", fields)
		Helpers.SetXP(world, 10, 250, 1000)
		world:Advance(0.2)
		local row
		for index, metric in ipairs(ns.MiniWindow.METRICS) do
			if metric.key == "levelProgress" then
				row = Mini(world).rows[index]
			end
		end
		expect(row.label:GetText()).toBe("Level 10")
		expect(row.value:GetText()).toBe("25%")
		expect(row.fill:GetWidth()).toBe(180 * 0.25)
		expect(row.rested:GetWidth()).toBe(180 * 0.3)

		world.player.maxLevel = 11
		Helpers.SetXP(world, 11, 0, 1100)
		world:Advance(1.2)
		expect(ShownRows(world, true)).toEqual({ "Session time", "Gold earned", "Gold / hour" })
		expect(world.errors).toEqual({})
	end)

	it("shrinks Sesh into the mini window with /sesh mini", function()
		local world, ns = Harness.Boot()
		ns.MainWindow.Open()
		world.env.SlashCmdList.SESH("mini")
		expect(ns.MainWindow.IsShown()).toBe(false)
		expect(Mini(world):IsShown()).toBe(true)
		expect(ns.Database.Get("miniMode")).toBe(true)
		world.env.SlashCmdList.SESH("mini")
		expect(Mini(world):IsShown()).toBe(false)
		expect(ns.Database.Get("miniMode")).toBe(false)
	end)

	it("fades its background and border, never the numbers", function()
		local world, ns = Harness.Boot()
		local mini = Mini(world)
		local panelAlpha = ns.Theme.COLORS.panel[4]
		expect(mini.background.color[4]).toBe(panelAlpha)
		ns.Database.Set("miniOpacity", 40)
		expect(mini.background.color[4]).toBeCloseTo(panelAlpha * 0.4)
		expect(mini.edges[1].color[4]).toBeCloseTo(ns.Theme.COLORS.border[4] * 0.4)
		world.settingsCategories[1].settings.miniOpacity:SetValue(0)
		expect(mini.background.color[4]).toBe(0)
		expect(mini.edges[3].color[4]).toBe(0)
		expect(mini:GetAlpha()).toBe(1)
		-- Hovering still shows where it is.
		mini:GetScript("OnEnter")(mini)
		expect(mini.hover:IsShown()).toBe(true)
		local reloaded = Harness.Restart(world, { reload = true })
		expect(Mini(reloaded).background.color[4]).toBe(0)
	end)

	it("says how to choose numbers when it has none to show", function()
		local world, ns = Harness.Boot()
		local fields = ns.Database.Get("miniFields")
		for key in pairs(fields) do
			fields[key] = false
		end
		ns.Database.Set("miniFields", fields)
		world:Advance(0.2)
		expect(Mini(world).empty:IsShown()).toBe(true)
		expect(Mini(world):GetHeight()).toBe(4 + 18 + 4)
		fields.kills = true
		ns.Database.Set("miniFields", fields)
		world:Advance(0.2)
		expect(Mini(world).empty:IsShown()).toBe(false)
	end)

	it("shows the minimize button only while mini mode is off", function()
		local world, ns = Harness.Boot()
		ns.MainWindow.Open()
		local main = world.env.SeshMainWindow
		expect(main.minimizeButton:IsShown()).toBe(false)
		expect(main.close.tooltip).toBe(ns.L.CLOSE_TO_MINI)
		ns.Database.Set("miniMode", false)
		expect(main.minimizeButton:IsShown()).toBe(true)
		expect(main.close.tooltip).toBeNil()
		main.minimizeButton:Click()
		expect(main:IsShown()).toBe(false)
		expect(Mini(world):IsShown()).toBe(true)
		expect(world.settingsCategories[1].settings.miniMode:GetValue()).toBe(true)
	end)

	it("follows its scale option and doesn't create frames as it updates", function()
		local world, ns = Harness.Boot()
		ns.Database.Set("miniScale", 0.8)
		expect(Mini(world):GetScale()).toBe(0.8)
		local created = world.createdObjects
		Helpers.GainMoney(world, 5)
		world:Advance(3)
		expect(world.createdObjects).toBe(created)
	end)
end)
