-- luacheck configuration: Lua 5.1 (the game's Lua) plus an explicit list of the game
-- API Sesh is allowed to use, so typos and accidental globals fail the lint.
std = "lua51"
max_line_length = 120
codes = true
self = false
exclude_files = { ".tools/**", ".release/**" }

files["Sesh/**/*.lua"] = {
	globals = {
		-- Saved variables and slash command registration.
		"SeshDB",
		"SeshCharDB",
		"SLASH_SESH1",
		"SlashCmdList",
		"StaticPopupDialogs",
		"UISpecialFrames",
	},
	read_globals = {
		-- Lua extensions and helpers provided by the client.
		"date",
		"time",
		"wipe",
		"strsplit",
		"issecretvalue",
		"securecallfunction",
		"geterrorhandler",
		"debugprofilestop",
		-- Frames and UI framework.
		"CreateFrame",
		"CreateFont",
		"UIParent",
		"GameTooltip",
		"Mixin",
		"CreateFromMixins",
		"PixelUtil",
		"CreateDataProvider",
		"CreateScrollBoxListLinearView",
		"ScrollUtil",
		"ScrollBoxConstants",
		"Settings",
		"CreateSettingsListSectionHeaderInitializer",
		"CreateSettingsButtonInitializer",
		"MinimalSliderWithSteppersMixin",
		"StaticPopup_Show",
		"EventRegistry",
		"ChatFrameUtil",
		"GetCursorPosition",
		"InCombatLockdown",
		"GetCVarBool",
		"STANDARD_TEXT_FONT",
		"GetFileIDFromPath",
		"IsShiftKeyDown",
		"GetBuildInfo",
		"BaseScrollBoxEvents",
		-- Game API.
		"C_AddOns",
		"C_Container",
		"C_CreatureInfo",
		"C_Secrets",
		"C_TooltipInfo",
		"C_Item",
		"C_QuestLog",
		"C_Texture",
		"C_Timer",
		"C_Traits",
		"Constants",
		"Enum",
		"GameRulesUtil",
		"GetAchievementInfo",
		"GetInstanceInfo",
		"GetLootSourceInfo",
		"GetNumLootItems",
		"GetMoney",
		"GetNormalizedRealmName",
		"GetRealmName",
		"NameUtil",
		"GetRealZoneText",
		"GetServerTime",
		"GetTime",
		"GetXPExhaustion",
		"IsInInstance",
		"MenuUtil",
		"UnitCanAttack",
		"UnitCreatureType",
		"UnitGUID",
		"UnitIsAFK",
		"UnitLevel",
		"UnitName",
		"UnitPlayerControlled",
		"UnitTokenFromGUID",
		"UnitXP",
		"UnitXPMax",
		-- Global strings.
		"CALENDAR_FIRST_WEEKDAY",
		"COMBATLOG_XPGAIN_FIRSTPERSON",
		"LARGE_NUMBER_SEPERATOR",
		"YES",
		"NO",
		-- Optional addons.
		"AddonCompartmentFrame",
		"Auctionator",
		"EllesmereUI",
		"LibStub",
	},
}

files["tests/**/*.lua"] = {
	globals = { "ROOT_DIR", "HARNESS_DIR", "describe", "it", "expect", "Harness" },
	read_globals = { "newproxy" },
	ignore = { "631" }, -- long literal lines in fixtures are fine
}
