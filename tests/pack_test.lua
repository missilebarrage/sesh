describe("Pack", function()
	local function Load()
		local _, ns = Harness.Load()
		return ns.Pack
	end

	it("round-trips numeric rows", function()
		local Pack = Load()
		local rows = { { itemID = 2589, count = 45, unitValue = 120 }, { itemID = 4306, count = 12, unitValue = 900 } }
		local text = Pack.Encode(rows, Pack.ITEMS)
		expect(text).toBe("2589:45:120;4306:12:900")
		expect(Pack.Decode(text, Pack.ITEMS)).toEqual(rows)
	end)

	it("keeps colons inside the trailing text field", function()
		local Pack = Load()
		local rows = { { questID = 176, xp = 450, money = 1200, title = "Wanted: Hogger" } }
		local text = Pack.Encode(rows, Pack.QUESTS)
		expect(text).toBe("176:450:1200:Wanted: Hogger")
		expect(Pack.Decode(text, Pack.QUESTS)).toEqual(rows)
	end)

	it("sanitizes text so it can't break rows or inject escape sequences", function()
		local Pack = Load()
		local text =
			Pack.Encode({ { npcID = 1, typeID = 7, count = 2, name = "Bad;|cffff0000Name|r\n" } }, Pack.MONSTERS)
		expect(text).toBe("1:7:2:Badcffff0000Namer")
		expect(#Pack.Decode(text, Pack.MONSTERS)).toBe(1)
	end)

	it("never splits a UTF-8 character when shortening", function()
		local Pack = Load()
		local name = string.rep("é", 30) -- 60 bytes
		local cleaned = Pack.CleanText(name, 41)
		expect(#cleaned).toBe(40)
		expect(cleaned).toBe(string.rep("é", 20))
	end)

	it("trims spaces in linear time, even on huge input", function()
		local Pack = Load()
		expect(Pack.CleanText("  Kobold \t Miner  ")).toBe("Kobold  Miner")
		expect(Pack.CleanText("   ")).toBe("")
		local started = os.clock()
		local hostile = string.rep(" ", 60000) .. "x" .. string.rep(" ", 60000) .. "y" .. string.rep(" ", 60000)
		expect(Pack.CleanText(hostile)).toBe("x" .. string.rep(" ", 39))
		expect(os.clock() - started).toBeLessThan(0.5)
	end)

	it("handles empty input and skips malformed rows without throwing", function()
		local Pack = Load()
		expect(Pack.Decode(nil, Pack.ITEMS)).toEqual({})
		expect(Pack.Decode("", Pack.ITEMS)).toEqual({})
		expect(Pack.Decode("1:2:3;x:y:z;4:5", Pack.ITEMS)).toEqual({ { itemID = 1, count = 2, unitValue = 3 } })
	end)

	it("survives random garbage", function()
		local Pack = Load()
		local alphabet = "0123456789:;abc|\0\255 "
		math.randomseed(7)
		for _ = 1, 500 do
			local chars = {}
			for index = 1, math.random(0, 40) do
				local position = math.random(1, #alphabet)
				chars[index] = alphabet:sub(position, position)
			end
			local garbage = table.concat(chars)
			local specs = { Pack.ITEMS, Pack.MONSTERS, Pack.QUESTS, Pack.ZONES, Pack.DUNGEONS, Pack.ACHIEVEMENTS }
			for _, spec in ipairs(specs) do
				expect(function()
					Pack.Decode(garbage, spec)
				end).notToThrow()
			end
		end
	end)

	it("writes large values without scientific notation", function()
		local Pack = Load()
		expect(Pack.Encode({ { itemID = 1, count = 1, unitValue = 12345678901 } }, Pack.ITEMS)).toBe("1:1:12345678901")
	end)
end)
