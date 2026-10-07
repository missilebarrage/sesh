-- Loads the addon into a fresh sandbox the way the client does: files in TOC order,
-- each called with (addonName, namespace).

local Wow = dofile(HARNESS_DIR .. "/wow.lua")

local Loader = {}
Loader.Wow = Wow
Loader.SECRET = Wow.SECRET

local ADDON_DIR = ROOT_DIR .. "/Sesh"

-- Globals the addon is allowed to create.
local ALLOWED_GLOBALS = {
	SeshDB = true,
	SeshCharDB = true,
	SLASH_SESH1 = true,
	SeshMainWindow = true,
	SeshMiniWindow = true,
	SeshSharedSessionWindow = true,
	SeshShareDialog = true,
	SeshModelPreview = true,
	SeshFontTitle = true,
	SeshFontHeading = true,
	SeshFontBody = true,
	SeshFontSmall = true,
	SeshFontLabel = true,
	SeshFontValue = true,
	SeshFontLarge = true,
}
Loader.ALLOWED_GLOBALS = ALLOWED_GLOBALS

--- The addon's files, in load order, as listed in Sesh.toc.
function Loader.TocFiles()
	local files = {}
	for line in io.lines(ADDON_DIR .. "/Sesh.toc") do
		line = line:gsub("\r$", "")
		if line ~= "" and not line:match("^#") then
			files[#files + 1] = (line:gsub("\\", "/"))
		end
	end
	return files
end

--- The TOC's "## Key: Value" metadata.
function Loader.TocMetadata()
	local metadata = {}
	for line in io.lines(ADDON_DIR .. "/Sesh.toc") do
		local key, value = line:match("^##%s*([%w%-_]+)%s*:%s*(.-)%s*$")
		if key then
			metadata[key] = value
		end
	end
	return metadata
end

--- Creates a world, loads every addon file into it and returns world, ns.
---@param options table? world options (auctionator, ellesmere, ldb, compartment, saved, ...)
function Loader.Load(options)
	options = options or {}
	local world = Wow.NewWorld(options)
	if options.configure then
		options.configure(world)
	end
	local env = Wow.CreateEnvironment(world)
	if options.saved then
		env.SeshDB = Wow.RoundTrip(options.saved.SeshDB)
		env.SeshCharDB = Wow.RoundTrip(options.saved.SeshCharDB)
	end
	local ns = {}
	for _, file in ipairs(Loader.TocFiles()) do
		local chunk = assert(loadfile(ADDON_DIR .. "/" .. file))
		setfenv(chunk, env)
		chunk("Sesh", ns)
	end
	world.ns = ns
	return world, ns
end

--- Loads the addon and plays the login sequence through the first world entry.
function Loader.Boot(options)
	options = options or {}
	local world, ns = Loader.Load(options)
	world:Fire("ADDON_LOADED", "Sesh")
	world:Fire("PLAYER_LOGIN")
	local isReload = options.reload == true
	world:Fire("PLAYER_ENTERING_WORLD", not isReload, isReload)
	return world, ns
end

--- Logs out (or reloads), writes saved variables through a serialization round trip,
--- then starts a new client session from them. gap = seconds spent logged out.
function Loader.Restart(world, restartOptions)
	restartOptions = restartOptions or {}
	world:Fire("PLAYER_LEAVING_WORLD")
	world:Fire("PLAYER_LOGOUT")
	local saved = { SeshDB = world.env.SeshDB, SeshCharDB = world.env.SeshCharDB }
	local options = {}
	for key, value in pairs(world.options) do
		options[key] = value
	end
	options.saved = saved
	options.reload = restartOptions.reload == true
	options.now = world.clock.server + (restartOptions.gap or 0)
	local previousPlayer = world.player
	options.configure = function(newWorld)
		for key, value in pairs(previousPlayer) do
			newWorld.player[key] = value
		end
		newWorld.items = world.items
		newWorld.auctionPrices = world.auctionPrices
		newWorld.quests = world.quests
		newWorld.zone = world.zone
		if restartOptions.configure then
			restartOptions.configure(newWorld)
		end
	end
	return Loader.Boot(options)
end

function Loader.LeakedGlobals(world)
	return world:LeakedGlobals(ALLOWED_GLOBALS)
end

return Loader
