local Helpers = dofile(HARNESS_DIR .. "/helpers.lua")

describe("Pricing", function()
	it("uses vendor prices without Auctionator", function()
		local world, ns = Harness.Boot()
		Helpers.Item(world, 10, 25)
		expect(ns.Pricing.HasAuctionData()).toBe(false)
		local value, source = ns.Pricing.UnitValue(10)
		expect(value).toBe(25)
		expect(source).toBe("vendor")
	end)

	it("prefers floored auction prices and falls back to vendor prices", function()
		local world, ns = Harness.Boot({ auctionator = true })
		Helpers.Item(world, 10, 25)
		Helpers.Item(world, 11, 40)
		world.auctionPrices[10] = 1234.75
		expect(ns.Pricing.HasAuctionData()).toBe(true)
		expect(ns.Pricing.UnitValue(10)).toBe(1234)
		local value, source = ns.Pricing.UnitValue(11)
		expect(value).toBe(40)
		expect(source).toBe("vendor")
	end)

	it("values soulbound items at their vendor price, auction price or not", function()
		local world, ns = Harness.Boot({ auctionator = true })
		Helpers.Item(world, 20, 30, { bindType = 1 }) -- bind on pickup
		Helpers.Item(world, 21, 40, { bindType = 2 }) -- bind on equip
		Helpers.Item(world, 22, 5, { bindType = 4 }) -- quest item
		Helpers.Item(world, 23, 50, { bindType = 3 }) -- bind on use
		for itemID = 20, 23 do
			world.auctionPrices[itemID] = 9000
		end
		expect({ ns.Pricing.UnitValue(20) }).toEqual({ 30, "soulbound" })
		expect({ ns.Pricing.UnitValue(21) }).toEqual({ 9000, "auction" })
		expect({ ns.Pricing.UnitValue(22) }).toEqual({ 5, "soulbound" })
		expect({ ns.Pricing.UnitValue(23) }).toEqual({ 9000, "auction" })
	end)

	it("requests item data once and refreshes when it loads", function()
		local world, ns = Harness.Boot()
		local signals = 0
		ns.Events.On("SESH_VALUES_CHANGED", function()
			signals = signals + 1
		end)
		expect(ns.Pricing.UnitValue(99)).toBeNil()
		expect(ns.Pricing.UnitValue(99)).toBeNil()
		expect(world.requestedItems).toEqual({ 99 })
		Helpers.Item(world, 99, 7)
		local before = ns.Pricing.Revision()
		world:Fire("ITEM_DATA_LOAD_RESULT", 99, true)
		expect(ns.Pricing.Revision()).toBe(before + 1)
		world:Advance(1)
		expect(signals).toBe(1)
		expect(ns.Pricing.UnitValue(99)).toBe(7)
	end)

	it("treats items that fail to load as worthless instead of retrying forever", function()
		local world, ns = Harness.Boot()
		ns.Pricing.UnitValue(98)
		world:Fire("ITEM_DATA_LOAD_RESULT", 98, false)
		expect(ns.Pricing.UnitValue(98)).toBe(0)
		expect(#world.requestedItems).toBe(1)
	end)

	it("re-prices after an Auctionator scan without doing work inside Auctionator's callback", function()
		local world, ns = Harness.Boot({ auctionator = true })
		Helpers.Item(world, 10, 25)
		expect(ns.Pricing.UnitValue(10)).toBe(25)
		world.auctionPrices[10] = 900
		local callback = world.auctionatorCallbacks[1]
		expect(callback).toBeTruthy()
		callback()
		expect(ns.Pricing.UnitValue(10)).toBe(25)
		world:Advance(2)
		expect(ns.Pricing.UnitValue(10)).toBe(900)
	end)
end)
