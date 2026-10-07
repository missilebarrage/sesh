local _, ns = ...

--- Compact text encoding for the row lists of finished sessions ("2589:45:120;4306:12:900").
--- Rows are separated by ";" and fields by ":". Only the last field of a row may be text,
--- so text may itself contain ":". Text is sanitized on the way in, so it can never
--- contain ";" or a "|" escape sequence. Decoding never throws; malformed rows are skipped.
---@class SeshPack
local Pack = ns.Pack

local TEXT_LIMIT = 40

---@class SeshPackSpec
---@field fields string[] field names in storage order
---@field text boolean whether the last field is text
---@field pattern string match pattern for one row

---@param fields string[]
---@param lastIsText boolean?
---@return SeshPackSpec
local function Spec(fields, lastIsText)
	local captures = {}
	for index = 1, #fields do
		captures[index] = (lastIsText and index == #fields) and "(.*)" or "(%d+)"
	end
	return { fields = fields, text = lastIsText == true, pattern = "^" .. table.concat(captures, ":") .. "$" }
end

Pack.ITEMS = Spec({ "itemID", "count", "unitValue" })
Pack.ITEM_TOTALS = Spec({ "itemID", "count", "value" })
Pack.MONSTERS = Spec({ "npcID", "typeID", "count", "name" }, true)
Pack.QUESTS = Spec({ "questID", "xp", "money", "title" }, true)
Pack.ZONES = Spec({ "kind", "seconds", "name" }, true)
Pack.DUNGEONS = Spec({ "startedAt", "seconds", "bosses", "name" }, true)
Pack.ACHIEVEMENTS = Spec({ "achievementID" })

--- Strips characters that would break the encoding or inject UI escape sequences, and
--- shortens text to at most maxBytes without splitting a UTF-8 character.
---@param text string
---@param maxBytes integer?
---@return string
function Pack.CleanText(text, maxBytes)
	maxBytes = maxBytes or TEXT_LIMIT
	text = text:gsub("[%c;|]", "")
	-- Trim spaces (other whitespace is control characters, already gone). This takes linear
	-- time: a pattern like "^%s*(.-)%s*$" is quadratic on long runs of spaces, which a
	-- payload from another player could use to freeze the client.
	local first = text:find("[^ ]")
	if not first then
		return ""
	end
	local last = #text
	while text:byte(last) == 32 do
		last = last - 1
	end
	text = text:sub(first, last)
	if #text <= maxBytes then
		return text
	end
	local cut = maxBytes
	-- Bytes 0x80-0xBF continue a multi-byte character; never start the remainder on one.
	while cut > 0 do
		local nextByte = text:byte(cut + 1)
		if not nextByte or nextByte < 0x80 or nextByte >= 0xC0 then
			break
		end
		cut = cut - 1
	end
	return text:sub(1, cut)
end

---@param rows table[] rows keyed by the spec's field names
---@param spec SeshPackSpec
---@return string
function Pack.Encode(rows, spec)
	local encoded = {}
	local fields = spec.fields
	local textIndex = spec.text and #fields or nil
	for rowIndex = 1, #rows do
		local row = rows[rowIndex]
		local values = {}
		for fieldIndex = 1, #fields do
			local value = row[fields[fieldIndex]]
			if fieldIndex == textIndex then
				values[fieldIndex] = type(value) == "string" and Pack.CleanText(value) or ""
			else
				values[fieldIndex] = string.format("%.0f", math.max(0, tonumber(value) or 0))
			end
		end
		encoded[rowIndex] = table.concat(values, ":")
	end
	return table.concat(encoded, ";")
end

---@param text string?
---@param spec SeshPackSpec
---@return table[] rows
function Pack.Decode(text, spec)
	local rows = {}
	if type(text) ~= "string" or text == "" then
		return rows
	end
	local fields = spec.fields
	local count = #fields
	local textIndex = spec.text and count or nil
	for chunk in text:gmatch("[^;]+") do
		local captures = { chunk:match(spec.pattern) }
		if #captures == count then
			local row = {}
			for index = 1, count do
				row[fields[index]] = index == textIndex and captures[index] or tonumber(captures[index])
			end
			rows[#rows + 1] = row
		end
	end
	return rows
end
