local _, ns = ...

--- Text formatting for numbers, money, durations and dates.
--- Copper amounts can exceed 2^31, so integers are formatted with "%.0f": "%d" goes
--- through a C long, which is 32-bit on Windows.
---@class SeshFormat
local Format = ns.Format
local L = ns.L

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local floor = math.floor

local function Whole(value)
	return string.format("%.0f", floor(value))
end

--- 1234567 -> "1,234,567" (uses the client's thousands separator when available).
---@param value number
---@return string
function Format.Integer(value)
	local digits = Whole(math.abs(value))
	local head = #digits % 3
	if head == 0 then
		head = 3
	end
	local groups = { digits:sub(1, head) }
	for index = head + 1, #digits, 3 do
		groups[#groups + 1] = digits:sub(index, index + 2)
	end
	local grouped = table.concat(groups, LARGE_NUMBER_SEPERATOR or ",")
	return value < 0 and ("-" .. grouped) or grouped
end

--- A counted noun: forms is a pair of formats, singular and plural ({ "%s boss", "%s bosses" }).
---@param count number
---@param forms string[]
---@return string
function Format.Count(count, forms)
	return (count == 1 and forms[1] or forms[2]):format(Format.Integer(count))
end

--- 0.624 -> "62%".
---@param fraction number
---@return string
function Format.Percent(fraction)
	return string.format("%d%%", floor(fraction * 100))
end

--- 950 -> "950", 9999 -> "9,999", 68240 -> "68.2k", 1240000 -> "1.24M".
---@param value number
---@return string
function Format.Compact(value)
	local magnitude = math.abs(value)
	if magnitude < 10000 then
		return Format.Integer(value)
	elseif magnitude < 100000 then
		return string.format("%.1fk", value / 1000)
	elseif magnitude < 1000000 then
		return string.format("%.0fk", floor(value / 1000))
	elseif magnitude < 1000000000 then
		return string.format("%.2fM", value / 1000000)
	end
	return string.format("%.2fB", value / 1000000000)
end

-- Splits copper into gold, silver and copper, plus the sign to show: a loss (item value can
-- be negative) reads "-12g 30s".
local function SplitMoney(copper)
	local sign = copper < 0 and "-" or ""
	copper = floor(math.abs(copper))
	if copper == 0 then
		sign = ""
	end
	local gold = floor(copper / COPPER_PER_GOLD)
	local silver = floor((copper % COPPER_PER_GOLD) / COPPER_PER_SILVER)
	return gold, silver, copper % COPPER_PER_SILVER, sign
end

--- Full amount with coin icons for the UI: "1,234[g] 5[s] 67[c]". Zero parts are omitted.
---@param copper number
---@return string
function Format.Money(copper)
	local gold, silver, rest, sign = SplitMoney(copper)
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = Format.Integer(gold) .. GOLD_ICON
	end
	if silver > 0 then
		parts[#parts + 1] = silver .. SILVER_ICON
	end
	if rest > 0 or #parts == 0 then
		parts[#parts + 1] = Whole(rest) .. COPPER_ICON
	end
	return sign .. table.concat(parts, " ")
end

--- Two most significant denominations with icons, for compact cells: "1,234[g]",
--- "12[g] 30[s]", "45[s] 6[c]".
---@param copper number
---@return string
function Format.MoneyShort(copper)
	local gold, silver, rest, sign = SplitMoney(copper)
	if gold >= 100 then
		return sign .. Format.Integer(gold) .. GOLD_ICON
	elseif gold > 0 then
		return sign .. gold .. GOLD_ICON .. (silver > 0 and (" " .. silver .. SILVER_ICON) or "")
	elseif silver > 0 then
		return sign .. silver .. SILVER_ICON .. (rest > 0 and (" " .. Whole(rest) .. COPPER_ICON) or "")
	end
	return sign .. Whole(rest) .. COPPER_ICON
end

--- Two most significant denominations as plain text, for lines that may be shortened with
--- an ellipsis (an icon cut in half would show its escape code): "1,234g", "12g 30s", "45s 6c".
---@param copper number
---@return string
function Format.MoneyShortText(copper)
	local gold, silver, rest, sign = SplitMoney(copper)
	local text
	if gold >= 100 then
		text = Format.Integer(gold) .. L.GOLD_ABBREVIATION
	elseif gold > 0 then
		text = gold .. L.GOLD_ABBREVIATION .. (silver > 0 and (" " .. silver .. L.SILVER_ABBREVIATION) or "")
	elseif silver > 0 then
		text = silver .. L.SILVER_ABBREVIATION .. (rest > 0 and (" " .. Whole(rest) .. L.COPPER_ABBREVIATION) or "")
	else
		text = Whole(rest) .. L.COPPER_ABBREVIATION
	end
	return sign .. text
end

--- "18s 54c / hour", or nil when there's no rate yet.
---@param rate number?
---@param formatter fun(value: number): string
---@return string?
function Format.PerHour(rate, formatter)
	return rate and L.CARD_PER_HOUR:format(formatter(rate)) or nil
end

--- Plain text for chat, where icons can't be sent: "10g 33s 5c".
---@param copper number
---@return string
function Format.MoneyText(copper)
	local gold, silver, rest, sign = SplitMoney(copper)
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = Format.Integer(gold) .. L.GOLD_ABBREVIATION
	end
	if silver > 0 then
		parts[#parts + 1] = silver .. L.SILVER_ABBREVIATION
	end
	if rest > 0 or #parts == 0 then
		parts[#parts + 1] = Whole(rest) .. L.COPPER_ABBREVIATION
	end
	return sign .. table.concat(parts, " ")
end

--- Largest denomination only, for rates in chat: "3g", "45s", "12c".
---@param copper number
---@return string
function Format.MoneyRough(copper)
	local gold, silver, rest, sign = SplitMoney(copper)
	if gold > 0 then
		return sign .. Format.Integer(gold) .. L.GOLD_ABBREVIATION
	elseif silver > 0 then
		return sign .. silver .. L.SILVER_ABBREVIATION
	end
	return sign .. Whole(rest) .. L.COPPER_ABBREVIATION
end

--- 45 -> "45s", 754 -> "12m", 8040 -> "2h 14m", 277200 -> "3d 5h".
---@param seconds number
---@return string
function Format.Duration(seconds)
	seconds = floor(math.max(seconds, 0))
	if seconds < 60 then
		return seconds .. L.SECONDS_ABBREVIATION
	end
	local minutes = floor(seconds / 60)
	if minutes < 60 then
		return minutes .. L.MINUTES_ABBREVIATION
	end
	local hours = floor(minutes / 60)
	if hours < 24 then
		return hours .. L.HOURS_ABBREVIATION .. " " .. (minutes % 60) .. L.MINUTES_ABBREVIATION
	end
	return floor(hours / 24) .. L.DAYS_ABBREVIATION .. " " .. (hours % 24) .. L.HOURS_ABBREVIATION
end

local function UseMilitaryTime()
	return GetCVarBool ~= nil and GetCVarBool("timeMgrUseMilitaryTime") == true
end

--- Local clock time: "2:04 PM", or "14:04" with the 24-hour clock option.
---@param timestamp number
---@return string
function Format.Time(timestamp)
	local t = date("*t", timestamp)
	if UseMilitaryTime() then
		return string.format("%d:%02d", t.hour, t.min)
	end
	local hour = t.hour % 12
	return string.format("%d:%02d %s", hour == 0 and 12 or hour, t.min, t.hour < 12 and L.AM or L.PM)
end

--- "Oct 6".
---@param timestamp number
---@return string
function Format.Date(timestamp)
	local t = date("*t", timestamp)
	return L.MONTHS_SHORT[t.month] .. " " .. t.day
end

--- "Tue, Oct 6, 2026".
---@param timestamp number
---@return string
function Format.DateLong(timestamp)
	local t = date("*t", timestamp)
	return string.format("%s, %s %d, %d", L.WEEKDAYS_SHORT[t.wday], L.MONTHS_SHORT[t.month], t.day, t.year)
end

--- "Oct 6, 2:04 PM".
---@param timestamp number
---@return string
function Format.DateTime(timestamp)
	return Format.Date(timestamp) .. ", " .. Format.Time(timestamp)
end

--- "Oct 4 – Oct 6", or "Oct 4" when both are on the same day.
---@param from number
---@param to number
---@return string
function Format.DateRange(from, to)
	local first, last = Format.Date(from), Format.Date(to)
	return first == last and first or (first .. " – " .. last)
end

--- Wraps text in a |c color escape. Expects channel values from 0 to 1.
---@return string
function Format.Color(text, r, g, b)
	return string.format("|cff%02x%02x%02x%s|r", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5), text)
end
