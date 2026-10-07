local addonName, ns = ...

ns.NAME = addonName
ns.COMM_PREFIX = "Sesh"
ns.SCHEMA = 1

-- Every module table exists before any module file runs, so files can capture each other
-- as locals regardless of load order.
ns.Events = {}
ns.Database = {}
ns.Format = {}
ns.Names = {}
ns.Pack = {}
ns.Session = {}
ns.Pricing = {}
ns.History = {}
ns.Stats = {}
ns.Leveling = {}
ns.Recorder = {}
ns.Income = {}
ns.Progress = {}
ns.Activity = {}
ns.Kills = {}
ns.Dungeons = {}
ns.Shares = {}
ns.Payload = {}
ns.Comm = {}
ns.Links = {}
ns.Theme = {}
ns.Widgets = {}
ns.Window = {}
ns.Heatmap = {}
ns.LevelChart = {}
ns.SessionView = {}
ns.HistoryView = {}
ns.SummaryView = {}
ns.LevelingView = {}
ns.MainWindow = {}
ns.MiniWindow = {}
ns.ShareDialog = {}
ns.SharedSessionWindow = {}
ns.DataBroker = {}
ns.Options = {}

--- Localized strings. Locales/enUS.lua is the source of truth; a missing key shows the key itself.
ns.L = setmetatable({}, {
	__index = function(_, key)
		return key
	end,
})

do
	local version = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version")
	-- An unpackaged checkout still carries the packager token (e.g. "@project-version@").
	if type(version) ~= "string" or version == "" or version:find("^@") then
		version = "dev"
	end
	ns.VERSION = version
end

local issecretvalue = issecretvalue

--- Whether a value from the game API may be compared, used in arithmetic or stored.
--- Secret values (restricted content) may only be passed through, never inspected.
---@return boolean
function ns.IsReadable(value)
	return not (issecretvalue and issecretvalue(value))
end

--- Returns the value when it is a readable, finite number; otherwise nil.
---@return number?
function ns.Num(value)
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

--- Returns the value when it is a readable string; otherwise nil.
---@return string?
function ns.Str(value)
	if issecretvalue and issecretvalue(value) then
		return nil
	end
	if type(value) ~= "string" then
		return nil
	end
	return value
end

local PATTERN_MAGIC = "^$().[]*+-?%"

--- Converts a Blizzard format string (e.g. LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d.")
--- into a Lua pattern with one capture per conversion.
--- Returns the pattern and the format-argument index of each capture, so positional
--- conversions used by some locales ("%2$d ... %1$s") map back to argument order.
---@param format string
---@param anchorEnd boolean? anchor the pattern at the end of the message (default true)
---@return string pattern
---@return integer[] argumentOrder
function ns.FormatPattern(format, anchorEnd)
	local parts = { "^" }
	local order = {}
	local nextArgument = 0
	local position = 1
	while position <= #format do
		local char = format:sub(position, position)
		if char == "%" then
			local index, conversion, after = format:match("^%%(%d*)%$?([sdi%%])()", position)
			if conversion == "%" then
				parts[#parts + 1] = "%%"
			elseif conversion then
				nextArgument = nextArgument + 1
				order[#order + 1] = tonumber(index) or nextArgument
				parts[#parts + 1] = conversion == "s" and "(.-)" or "(%d+)"
			else
				parts[#parts + 1] = "%%"
				after = position + 1
			end
			position = after
		else
			parts[#parts + 1] = PATTERN_MAGIC:find(char, 1, true) and ("%" .. char) or char
			position = position + 1
		end
	end
	if anchorEnd ~= false then
		parts[#parts + 1] = "$"
	end
	return table.concat(parts), order
end

--- Matches a message against a pattern from FormatPattern and returns the captures in
--- format-argument order (first %s, then %d, ...), or nothing when it doesn't match.
---@param message string
---@param pattern string
---@param order integer[]
function ns.MatchFormat(message, pattern, order)
	local a, b, c = message:match(pattern)
	if a == nil then
		return
	end
	local captures = { a, b, c }
	local ordered = {}
	for captureIndex, argumentIndex in ipairs(order) do
		ordered[argumentIndex] = captures[captureIndex]
	end
	return ordered[1], ordered[2], ordered[3]
end

--- Debug counters, shown by /sesh debug. They hold numbers only — never names or text.
ns.Debug = { counters = {} }

---@param key string
function ns.Count(key)
	local counters = ns.Debug.counters
	counters[key] = (counters[key] or 0) + 1
end

function ns.Print(...)
	local hex = ns.Theme.AccentHex and ns.Theme.AccentHex() or "dca77f"
	print("|cff" .. hex .. "Sesh|r", ...)
end
