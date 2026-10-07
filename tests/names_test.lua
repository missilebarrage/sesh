describe("Names", function()
	it("splits full names into first name, surname and realm", function()
		local _, ns = Harness.Load()
		expect({ ns.Names.Parse("Tim Smith-Realm") }).toEqual({ "Tim", "Smith", "Realm" })
		expect({ ns.Names.Parse("Tim Smith") }).toEqual({ "Tim", "Smith" })
		expect({ ns.Names.Parse("Tim-Realm") }).toEqual({ "Tim", nil, "Realm" })
		expect({ ns.Names.Parse("Tim") }).toEqual({ "Tim" })
	end)

	it("compares names part by part, ignoring parts one side doesn't have", function()
		local _, ns = Harness.Load()
		local Same = ns.Names.Same
		expect(Same("Tim Smith-Realm", "Tim-Realm")).toBe(true)
		expect(Same("Tim Smith-Realm", "tim smith")).toBe(true)
		expect(Same("Tim Smith", "Tim Jones")).toBe(false)
		expect(Same("Tim-Realm", "Tim-OtherRealm")).toBe(false)
		expect(Same("Tim", "Tom")).toBe(false)
	end)

	it("shows the player's first name and surname", function()
		local world, ns = Harness.Boot({
			configure = function(w)
				w.player.surname = "Smith"
			end,
		})
		expect(ns.Names.PlayerDisplayName()).toBe("Tester Smith")
		expect(ns.Names.PlayerFullName()).toBe("Tester Smith-TestRealm")
		ns.MainWindow.Open()
		expect(world.env.SeshMainWindow.subtitle:GetText()).toMatch("^Tester Smith  ·  Session #1")
	end)

	it("doesn't mistake a realm for a surname outside Forever", function()
		local world, ns = Harness.Load({
			configure = function(w)
				w.player.surname = "TestRealm"
			end,
		})
		world.env.NameUtil = nil
		expect({ ns.Names.PlayerParts() }).toEqual({ "Tester" })
		expect(ns.Names.PlayerDisplayName()).toBe("Tester")
	end)
end)
