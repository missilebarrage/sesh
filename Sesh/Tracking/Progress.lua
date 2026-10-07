local _, ns = ...

--- Experience and levels, quests turned in, deaths, achievements and Legacy Points.
---@class SeshProgress : SeshTracker
local Progress = ns.Progress
local Recorder = ns.Recorder
local Session = ns.Session
local Leveling = ns.Leveling
local Events = ns.Events

local level, xp, xpMax ---@type number?, number?, number?
local legacyPoints ---@type number?

--- The character's level, the experience into it and the experience it needs, as far as
--- they can be read.
---@return number? level
---@return number? xp
---@return number? xpMax
function Progress.Experience()
	return ns.Num(UnitLevel("player")), ns.Num(UnitXP("player")), ns.Num(UnitXPMax("player"))
end

--- Rested experience, or nil.
---@return number?
function Progress.Rested()
	return ns.Num(GetXPExhaustion())
end

--- Whether the character can still gain levels: false at the level cap.
---@param needed number? experience the current level needs
---@return boolean
function Progress.CanLevel(needed)
	if not (needed and needed > 0) then
		return false
	end
	local rules = GameRulesUtil
	if rules and rules.IsPlayerAtEffectiveMaxLevel then
		local ok, atCap = pcall(rules.IsPlayerAtEffectiveMaxLevel)
		if ok and atCap == true then
			return false
		end
	end
	return true
end

--- Experience still needed for the next level, or nil (max level / unreadable).
---@return number?
function Progress.XPToLevel()
	if xp and xpMax and xpMax > 0 then
		return math.max(0, xpMax - xp)
	end
end

--- Seconds until the next level at a pace of xpPerHour, or nil.
---@param xpPerHour number?
---@return number?
function Progress.TimeToLevel(xpPerHour)
	local remaining = Progress.XPToLevel()
	if remaining and xpPerHour and xpPerHour > 0 then
		return remaining / xpPerHour * 3600
	end
end

--- Legacy Points (available + spent) in the shared pool of Forever's Legacy trees, or nil
--- when the client doesn't have them.
---@return number?
function Progress.ReadLegacyPoints()
	local constants = Constants and Constants.LegacyConsts
	if not (constants and C_Traits and C_Traits.GetConfigIDByTreeID and C_Traits.GetTreeCurrencyInfo) then
		return nil
	end
	local currencyID = constants.LEGACY_POINTS_TRAIT_CURRENCY_ID
	local treeID = constants.LEGACY_TREE_PROGRESSION_ID
	local ok, configID = pcall(C_Traits.GetConfigIDByTreeID, treeID)
	if not (ok and ns.Num(configID)) then
		return nil
	end
	-- true excludes purchases the player has staged but not applied.
	local currencies
	ok, currencies = pcall(C_Traits.GetTreeCurrencyInfo, configID, treeID, true)
	if not (ok and type(currencies) == "table") then
		return nil
	end
	for _, currency in ipairs(currencies) do
		if currency.traitCurrencyID == currencyID then
			local quantity, spent = ns.Num(currency.quantity), ns.Num(currency.spent)
			if quantity and spent then
				-- The pool is shared by all trees: spent already covers them all.
				return quantity + spent
			end
		end
	end
end

local function UpdateLegacy()
	local session = Recorder.Current()
	local points = Progress.ReadLegacyPoints()
	if not (session and points) then
		return
	end
	if legacyPoints and points > legacyPoints then
		Session.AddLegacy(session, points - legacyPoints)
	end
	legacyPoints = points
end

function Progress.Start(session, now)
	level, xp, xpMax = Progress.Experience()
	if level then
		Session.SetLevel(session, level)
		if xp and xpMax then
			Leveling.Start(session, level, xp, xpMax, now)
		end
	end
	legacyPoints = Progress.ReadLegacyPoints()
end

function Progress.Stop()
	UpdateLegacy()
end

local function AddXP(session, amount)
	if amount > 0 then
		Session.AddXP(session, amount)
	end
end

local function UpdateExperience()
	local session = Recorder.Current()
	if not session then
		return
	end
	local newLevel, newXP, newMax = Progress.Experience()
	if not (newLevel and newXP and newMax) then
		Session.NoteMissed(session)
		return
	end
	if not (level and xp and xpMax) or newLevel < level then
		level, xp, xpMax = newLevel, newXP, newMax
		Session.SetLevel(session, newLevel)
		Leveling.Start(session, newLevel, newXP, newMax, GetServerTime())
		return
	end
	-- At a level-up the client updates level and experience separately, in either order.
	-- A half-updated state is skipped: counting from it would add most of a level twice.
	if newLevel == level then
		if newXP < xp then
			return -- the new level's experience arrived before the level
		end
		AddXP(session, newXP - xp)
	else
		if newMax == xpMax and newXP >= xp then
			return -- the level arrived before the experience reset
		end
		-- The rest of the old level counts toward it, the progress into the new level toward
		-- the new one. When several levels are gained at once, the levels in between can't
		-- be measured.
		AddXP(session, xpMax - xp)
		Session.SetLevel(session, newLevel)
		Leveling.LevelUp(session, newLevel, newMax, GetServerTime())
		AddXP(session, newXP)
	end
	level, xp, xpMax = newLevel, newXP, newMax
	Session.SetLevel(session, newLevel)
end

Events.On("PLAYER_XP_UPDATE", function(unit)
	if ns.Str(unit) == "player" then
		UpdateExperience()
	end
end)

Events.On("PLAYER_LEVEL_UP", UpdateExperience)
Events.On("PLAYER_LEVEL_CHANGED", UpdateExperience)

Events.On("QUEST_TURNED_IN", function(questID, xpReward, moneyReward)
	local session = Recorder.Current()
	questID = ns.Num(questID)
	if not (session and questID) then
		return
	end
	local title = ns.Str(C_QuestLog.GetTitleForQuestID(questID))
	Session.AddQuest(session, questID, title, ns.Num(xpReward) or 0, ns.Num(moneyReward) or 0)
end)

Events.On("PLAYER_DEAD", function()
	local session = Recorder.Current()
	if session then
		Session.AddDeath(session)
	end
end)

Events.On("ACHIEVEMENT_EARNED", function(achievementID, alreadyEarned)
	local session = Recorder.Current()
	achievementID = ns.Num(achievementID)
	if session and achievementID and alreadyEarned ~= true then
		Session.AddAchievement(session, achievementID)
	end
	-- Legacy Points come from Legacy Challenge achievements.
	Events.Debounce("legacy", 2, UpdateLegacy)
end)

Events.On("TRAIT_TREE_CURRENCY_INFO_UPDATED", function()
	Events.Debounce("legacy", 1, UpdateLegacy)
end)

-- Trait data can finish loading after login; take the baseline then.
Events.On("TRAIT_CONFIG_LIST_UPDATED", function()
	if not legacyPoints then
		legacyPoints = Progress.ReadLegacyPoints()
	end
end)
