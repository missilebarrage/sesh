local _, ns = ...

--- Renders any session view: the live session, a finished session, a range aggregate,
--- the lifetime rollup, a level, or a session or level someone shared. Eight metric cards
--- on top (a session set and a level set), a strip of extras (deaths, dungeon runs,
--- achievements, Legacy Points), and a list of items, monsters, quests, zones and dungeon
--- runs, plus the sessions themselves when the view is a range.
---@class SeshSessionView
local SessionView = ns.SessionView
local Session = ns.Session
local Pricing = ns.Pricing
local Progress = ns.Progress
local Database = ns.Database
local Format = ns.Format
local Theme = ns.Theme
local Widgets = ns.Widgets
local Links = ns.Links
local L = ns.L

local CARD_GAP = 10
local ROW_HEIGHT = 22
local TOOLTIP_RUNS = 6

local function AddLine(left, right)
	GameTooltip:AddDoubleLine(left, right, 0.75, 0.75, 0.75, 1, 1, 1)
end

local function AddNote(text)
	GameTooltip:AddLine(text, 0.6, 0.6, 0.6, true)
end

local function Sum(rows, field)
	local total = 0
	for _, row in ipairs(rows) do
		total = total + (row[field] or 0)
	end
	return total
end

-- Cards ---------------------------------------------------------------------------------

-- Detail lines use plain-text money: a coin icon cut off by truncation would print its
-- escape code instead.
local PerHour = Format.PerHour

local function PricingNote()
	AddNote(Pricing.HasAuctionData() and L.PRICES_FROM_AUCTIONATOR or L.PRICES_FROM_VENDOR)
	AddNote(L.CONVERSIONS_NOTE)
end

local function RatesNote()
	AddNote(Database.Get("excludeAfk") and L.RATES_EXCLUDE_AFK or L.RATES_INCLUDE_AFK)
end

---@class SeshCardSpec
---@field icon string Theme icon key
---@field label string
---@field value fun(m: SeshMetrics, view: SeshView, context: table): string
---@field sub fun(m: SeshMetrics, view: SeshView, context: table): string?
---@field tooltip fun(m: SeshMetrics, view: SeshView, context: table)

---@type table<string, SeshCardSpec>
local CARDS = {}

CARDS.goldEarned = {
	icon = "goldEarned",
	label = L.CARD_GOLD_EARNED,
	value = function(m)
		return Format.MoneyShort(m.goldEarned)
	end,
	sub = function(m)
		return PerHour(m.goldPerHour, Format.MoneyShortText)
	end,
	tooltip = function(m)
		GameTooltip:SetText(L.CARD_GOLD_EARNED, 1, 1, 1)
		AddLine(L.RAW_GOLD, Format.Money(m.money))
		AddLine(L.ITEM_VALUE, Format.Money(m.itemValue))
		AddLine(L.TOTAL, Format.Money(m.goldEarned))
		if m.goldPerHour then
			AddLine(L.PER_HOUR, Format.Money(m.goldPerHour))
		end
		PricingNote()
		RatesNote()
	end,
}

CARDS.rawGold = {
	icon = "rawGold",
	label = L.CARD_RAW_GOLD,
	value = function(m)
		return Format.MoneyShort(m.money)
	end,
	sub = function(m)
		return PerHour(m.moneyPerHour, Format.MoneyShortText)
	end,
	tooltip = function(m)
		GameTooltip:SetText(L.CARD_RAW_GOLD, 1, 1, 1)
		AddLine(L.TOTAL, Format.Money(m.money))
		if m.moneyPerHour then
			AddLine(L.PER_HOUR, Format.Money(m.moneyPerHour))
		end
		AddNote(L.GOLD_EARNED_NOTE)
	end,
}

CARDS.itemValue = {
	icon = "itemValue",
	label = L.CARD_ITEM_VALUE,
	value = function(m)
		return Format.MoneyShort(m.itemValue)
	end,
	sub = function(m)
		if m.itemsUsed > 0 then
			return L.CARD_ITEMS_USED:format(Format.MoneyShortText(-m.itemsUsedValue))
		end
		return L.CARD_ITEM_COUNT:format(Format.Integer(m.items))
	end,
	tooltip = function(m)
		GameTooltip:SetText(L.CARD_ITEM_VALUE, 1, 1, 1)
		AddLine(L.ITEMS_ACQUIRED, Format.Money(m.itemsAcquiredValue))
		if m.itemsUsed > 0 then
			AddLine(L.ITEMS_USED_UP, Format.Money(-m.itemsUsedValue))
		end
		AddLine(L.TOTAL, Format.Money(m.itemValue))
		AddLine(L.LIST_ITEMS, Format.Integer(m.items))
		PricingNote()
	end,
}

CARDS.xp = {
	icon = "xp",
	label = L.CARD_XP,
	value = function(m)
		return Format.Compact(m.xp)
	end,
	sub = function(m, view)
		if m.xpPerHour and m.xp > 0 then
			return PerHour(m.xpPerHour, Format.Compact)
		elseif m.levels > 0 then
			return L.CARD_LEVELS_GAINED:format(m.levels)
		elseif view.endLevel then
			return L.CARD_LEVEL:format(view.endLevel)
		end
	end,
	tooltip = function(m, view, context)
		GameTooltip:SetText(L.CARD_XP, 1, 1, 1)
		AddLine(L.XP_EARNED, Format.Integer(m.xp))
		if m.xpPerHour then
			AddLine(L.PER_HOUR, Format.Integer(m.xpPerHour))
		end
		if view.startLevel and view.endLevel then
			AddLine(L.LEVELS, view.startLevel .. " → " .. view.endLevel)
		elseif m.levels > 0 then
			AddLine(L.LEVELS_GAINED, m.levels)
		end
		if view.xpMax then
			AddLine(L.XP_FOR_LEVEL, Format.Integer(view.xpMax))
		end
		AddLine(L.XP_FROM_QUESTS, Format.Integer(Sum(view.quests, "xp")))
		local levelUpIn = context.live and Progress.TimeToLevel(m.xpPerHour)
		if levelUpIn then
			AddLine(L.XP_TO_LEVEL, Format.Integer(Progress.XPToLevel()))
			AddLine(L.LEVEL_UP_IN, Format.Duration(levelUpIn))
		end
		RatesNote()
	end,
}

CARDS.duration = {
	icon = "duration",
	label = L.CARD_DURATION,
	value = function(m)
		return Format.Duration(m.duration)
	end,
	sub = function(m, view)
		if view.kind == "aggregate" then
			return L.CARD_SESSIONS:format(m.sessions)
		end
		return L.CARD_ACTIVE:format(Format.Duration(m.activeSeconds))
	end,
	tooltip = function(m, view, context)
		GameTooltip:SetText(L.CARD_DURATION, 1, 1, 1)
		if view.kind ~= "aggregate" and view.startedAt then
			AddLine(L.STARTED, Format.DateTime(view.startedAt))
			AddLine(L.ENDED, context.live and L.STILL_PLAYING or Format.DateTime(view.endedAt))
		else
			AddLine(L.SESSIONS, Format.Integer(m.sessions))
		end
		AddLine(L.ACTIVE_TIME, Format.Duration(m.activeSeconds))
		AddLine(L.AFK_TIME, Format.Duration(m.afkSeconds))
	end,
}

-- How long a level took: the time played at it, over every session.
CARDS.levelTime = {
	icon = "levelTime",
	label = L.CARD_TIME_PLAYED,
	value = function(m)
		return Format.Duration(m.duration)
	end,
	sub = function(m, view)
		if view.fromPercent then
			return L.CARD_TRACKED_FROM:format(view.fromPercent)
		end
		return L.CARD_ACTIVE:format(Format.Duration(m.activeSeconds))
	end,
	tooltip = function(m, view, context)
		GameTooltip:SetText(L.CARD_TIME_PLAYED, 1, 1, 1)
		if view.startedAt then
			AddLine(view.fromPercent and L.TRACKED_SINCE or L.LEVEL_REACHED, Format.DateTime(view.startedAt))
		end
		if context.live then
			AddLine(L.LEVEL_FINISHED, L.STILL_LEVELING)
		elseif view.endedAt then
			AddLine(view.completed and L.LEVEL_FINISHED or L.LAST_PLAYED, Format.DateTime(view.endedAt))
		end
		AddLine(L.SESSIONS, Format.Integer(m.sessions))
		AddLine(L.ACTIVE_TIME, Format.Duration(m.activeSeconds))
		AddLine(L.AFK_TIME, Format.Duration(m.afkSeconds))
		AddNote(L.LEVEL_TIME_NOTE)
		if view.fromPercent then
			AddNote(L.LEVEL_PARTIAL_NOTE:format(view.fromPercent))
		end
	end,
}

CARDS.kills = {
	icon = "kills",
	label = L.CARD_KILLS,
	value = function(m)
		return Format.Integer(m.kills)
	end,
	sub = function(m)
		return L.CARD_KINDS:format(m.kinds)
	end,
	tooltip = function(m, view)
		GameTooltip:SetText(L.CARD_KILLS, 1, 1, 1)
		AddLine(L.KILLS, Format.Integer(m.kills))
		AddLine(L.KINDS, Format.Integer(m.kinds))
		if view.unidentifiedKills > 0 then
			AddLine(L.UNIDENTIFIED, Format.Integer(view.unidentifiedKills))
			AddNote(L.UNIDENTIFIED_NOTE)
		end
		AddNote(L.KILLS_NOTE)
	end,
}

CARDS.quests = {
	icon = "quests",
	label = L.CARD_QUESTS,
	value = function(m)
		return Format.Integer(m.quests)
	end,
	sub = function(_, view)
		local xp = Sum(view.quests, "xp")
		return xp > 0 and L.CARD_PLUS_XP:format(Format.Compact(xp)) or nil
	end,
	tooltip = function(m, view)
		GameTooltip:SetText(L.CARD_QUESTS, 1, 1, 1)
		AddLine(L.QUESTS_TURNED_IN, Format.Integer(m.quests))
		AddLine(L.XP_FROM_QUESTS, Format.Integer(Sum(view.quests, "xp")))
		AddLine(L.GOLD_FROM_QUESTS, Format.Money(Sum(view.quests, "money")))
	end,
}

CARDS.zones = {
	icon = "zones",
	label = L.CARD_ZONES,
	value = function(m)
		return Format.Integer(m.zones)
	end,
	sub = function(_, view)
		return view.zones[1] and view.zones[1].name
	end,
	tooltip = function(_, view)
		GameTooltip:SetText(L.CARD_ZONES, 1, 1, 1)
		for index = 1, math.min(5, #view.zones) do
			local zone = view.zones[index]
			AddLine(zone.name, Format.Duration(zone.seconds))
		end
	end,
}

CARDS.dungeons = {
	icon = "zoneDungeon",
	label = L.CARD_DUNGEONS,
	value = function(m)
		return Format.Integer(m.dungeons)
	end,
	sub = function(_, view)
		local bosses = Sum(view.dungeons, "bosses")
		return bosses > 0 and Format.Count(bosses, L.COUNT_BOSSES) or nil
	end,
	tooltip = function(m, view)
		GameTooltip:SetText(L.CARD_DUNGEONS, 1, 1, 1)
		AddLine(L.DUNGEON_RUNS, Format.Integer(m.dungeons))
		AddLine(L.BOSSES_KILLED, Format.Integer(Sum(view.dungeons, "bosses")))
		local runs = view.dungeons
		for index = #runs, math.max(1, #runs - TOOLTIP_RUNS + 1), -1 do
			local run = runs[index]
			AddLine(run.name, Format.Count(run.bosses, L.COUNT_BOSSES) .. " · " .. Format.Duration(run.seconds))
		end
		AddNote(L.DUNGEONS_NOTE)
	end,
}

CARDS.deaths = {
	icon = "deaths",
	label = L.CARD_DEATHS,
	value = function(m)
		return Format.Integer(m.deaths)
	end,
	sub = function(m)
		if m.deaths == 0 then
			return L.CARD_NO_DEATHS
		end
		return L.CARD_DEATH_EVERY:format(Format.Duration(m.activeSeconds / m.deaths))
	end,
	tooltip = function(m)
		GameTooltip:SetText(L.CARD_DEATHS, 1, 1, 1)
		AddLine(L.DEATHS, Format.Integer(m.deaths))
		if m.deaths > 0 then
			AddLine(L.ACTIVE_TIME_PER_DEATH, Format.Duration(m.activeSeconds / m.deaths))
		end
	end,
}

local SESSION_CARDS = { "goldEarned", "rawGold", "itemValue", "xp", "duration", "kills", "quests", "zones" }
local LEVEL_CARDS = { "levelTime", "xp", "goldEarned", "kills", "quests", "dungeons", "deaths", "zones" }

-- Levels have their own cards: time to level, dungeons and deaths matter more there.
local function CardSet(view)
	return view.level and LEVEL_CARDS or SESSION_CARDS
end

-- List rows ----------------------------------------------------------------------------

local SOURCE_TEXT = {
	auction = L.SOURCE_AUCTION,
	vendor = L.SOURCE_VENDOR,
	soulbound = L.SOURCE_SOULBOUND,
}

local ZONE_KIND_NAMES = {
	[Session.ZONE_WORLD] = L.ZONE_WORLD,
	[Session.ZONE_DUNGEON] = L.ZONE_DUNGEON,
	[Session.ZONE_RAID] = L.ZONE_RAID,
	[Session.ZONE_PVP] = L.ZONE_PVP,
	[Session.ZONE_OTHER] = L.ZONE_OTHER,
}

local modelPreview

local function ShowModel(npcID)
	if not npcID then
		return
	end
	if not modelPreview then
		modelPreview = CreateFrame("PlayerModel", "SeshModelPreview", UIParent)
		modelPreview:SetSize(140, 170)
		modelPreview:SetFrameStrata("TOOLTIP")
		Theme.Fill(modelPreview, Theme.COLORS.panel)
		Theme.Border(modelPreview)
	end
	modelPreview:ClearAllPoints()
	modelPreview:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 4, 0)
	modelPreview:SetCreature(npcID)
	modelPreview:Show()
end

local function HideModel()
	if modelPreview then
		modelPreview:Hide()
	end
end

local function ItemInfo(itemID)
	local name, link, quality = C_Item.GetItemInfo(itemID)
	if not name then
		Pricing.LoadItem(itemID)
	end
	return name, link, quality
end

local function AccentName(row)
	Theme.PaintAccent(row.name, 1, "text")
	row.accentName = true
end

-- Per-kind row behaviour: bind (fill the row), tooltip and click.
local ROWS = {}

-- Items used up (disenchanted or opened) are listed after the items acquired, as a loss.
ROWS.items = {
	bind = function(row, item)
		local name, _, quality = ItemInfo(item.itemID)
		row.icon:SetTexture(C_Item.GetItemIconByID(item.itemID))
		row.icon:SetDesaturated(item.used == true)
		row.name:SetText(name or L.ITEM_LOADING:format(item.itemID))
		if item.used then
			Theme.Tone(row.name, "dim")
		elseif quality then
			local r, g, b = C_Item.GetItemQualityColor(quality)
			row.name:SetTextColor(r, g, b)
		end
		local count = Format.Integer(item.count)
		row.detail:SetText(item.used and L.ITEM_USED_UP:format(count) or ("×" .. count))
		row.value:SetText(Format.MoneyShort(item.used and -item.value or item.value))
	end,
	tooltip = function(row, item)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(item.itemID)
		local _, source = Pricing.UnitValue(item.itemID)
		local sourceText = SOURCE_TEXT[source] or L.SOURCE_VENDOR
		GameTooltip:AddLine(" ")
		if item.used then
			AddNote(L.ITEM_USED_UP_NOTE)
		end
		AddLine(L.VALUE_EACH:format(sourceText), Format.Money(item.unitValue))
		AddLine(L.VALUE_TOTAL:format(Format.Integer(item.count)), Format.Money(item.used and -item.value or item.value))
		GameTooltip:Show()
	end,
	click = function(item)
		if IsShiftKeyDown() then
			local _, link = ItemInfo(item.itemID)
			if link then
				Links.Insert(link)
			end
		end
	end,
}

ROWS.monsters = {
	bind = function(row, monster)
		row.icon:SetTexture(monster.unidentified and Theme.Icon("unknown") or Theme.CreatureIcon(monster.typeID))
		row.name:SetText(monster.unidentified and L.UNIDENTIFIED or monster.name)
		if monster.unidentified then
			Theme.Tone(row.name, "dim")
		end
		row.detail:SetText("")
		row.value:SetText("×" .. Format.Integer(monster.count))
	end,
	tooltip = function(row, monster)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		if monster.unidentified then
			GameTooltip:SetText(L.UNIDENTIFIED, 1, 1, 1)
			AddNote(L.UNIDENTIFIED_NOTE)
		else
			GameTooltip:SetText(monster.name, 1, 1, 1)
			local typeInfo = monster.typeID
				and C_CreatureInfo.GetCreatureTypeInfo
				and C_CreatureInfo.GetCreatureTypeInfo(monster.typeID)
			if typeInfo and typeInfo.name then
				AddNote(typeInfo.name)
			end
			AddLine(L.KILLS, Format.Integer(monster.count))
		end
		GameTooltip:Show()
		ShowModel(monster.npcID)
	end,
}

ROWS.quests = {
	bind = function(row, quest)
		row.icon:SetTexture(Theme.Icon("quest"))
		row.name:SetText(quest.title or L.QUEST_FALLBACK:format(quest.questID))
		row.detail:SetText(quest.xp > 0 and L.CARD_PLUS_XP:format(Format.Integer(quest.xp)) or "")
		row.value:SetText(quest.money > 0 and Format.MoneyShort(quest.money) or "")
	end,
	tooltip = function(row, quest)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetText(quest.title or L.QUEST_FALLBACK:format(quest.questID), 1, 1, 1)
		AddLine(L.XP_EARNED, Format.Integer(quest.xp))
		AddLine(L.RAW_GOLD, Format.Money(quest.money))
		GameTooltip:Show()
	end,
}

ROWS.zones = {
	bind = function(row, zone, total)
		row.icon:SetTexture(Theme.ZoneIcon(zone.kind))
		row.name:SetText(zone.name)
		row.detail:SetText(total > 0 and string.format("%d%%", math.floor(zone.seconds / total * 100 + 0.5)) or "")
		row.value:SetText(Format.Duration(zone.seconds))
	end,
	tooltip = function(row, zone)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetText(zone.name, 1, 1, 1)
		AddNote(ZONE_KIND_NAMES[zone.kind] or L.ZONE_WORLD)
		AddLine(L.TIME_SPENT, Format.Duration(zone.seconds))
		GameTooltip:Show()
	end,
}

ROWS.dungeons = {
	bind = function(row, run)
		row.icon:SetTexture(Theme.ZoneIcon(Session.ZONE_DUNGEON))
		row.name:SetText(run.name)
		if run.live then
			AccentName(row)
		end
		row.detail:SetText(Format.Count(run.bosses, L.COUNT_BOSSES))
		row.value:SetText(run.live and L.IN_PROGRESS or Format.Duration(run.seconds))
	end,
	tooltip = function(row, run)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetText(run.name, 1, 1, 1)
		AddLine(L.STARTED, Format.DateLong(run.startedAt) .. ", " .. Format.Time(run.startedAt))
		AddLine(L.TIME_SPENT, Format.Duration(run.seconds))
		AddLine(L.BOSSES_KILLED, Format.Integer(run.bosses))
		AddNote(run.live and L.DUNGEON_IN_PROGRESS_NOTE or L.DUNGEONS_NOTE)
		GameTooltip:Show()
	end,
}

ROWS.sessions = {
	bind = function(row, session)
		row.icon:SetTexture(Theme.Icon(session.live and "duration" or "sessions"))
		row.name:SetText(Format.DateLong(session.startedAt) .. ", " .. Format.Time(session.startedAt))
		if session.live then
			AccentName(row)
		end
		row.detail:SetText(
			L.SESSION_ROW_DETAIL:format(
				Format.Duration(session.duration),
				Format.Compact(session.xp),
				Format.Integer(session.kills)
			)
		)
		row.value:SetText(Format.MoneyShort(session.goldEarned))
	end,
	tooltip = function(row, session)
		GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
		GameTooltip:SetText(session.live and L.CURRENT_SESSION or Format.DateLong(session.startedAt), 1, 1, 1)
		AddLine(L.CARD_DURATION, Format.Duration(session.duration))
		AddLine(L.CARD_GOLD_EARNED, Format.Money(session.goldEarned))
		AddLine(L.CARD_XP, Format.Integer(session.xp))
		AddLine(L.CARD_KILLS, Format.Integer(session.kills))
		AddNote(L.CLICK_TO_OPEN)
		GameTooltip:Show()
	end,
	click = function(session, owner)
		if owner.options.onSessionClick then
			owner.options.onSessionClick(session.id)
		end
	end,
}

-- Rows are recycled between views and kinds, so behaviour is looked up per click.
local function OnRowClick(row)
	local behaviour = row.entry and ROWS[row.entry.kind]
	if behaviour and behaviour.click then
		behaviour.click(row.entry.data, row.owner)
	end
end

local function BuildRow(row)
	Widgets.PrepareRow(row)
	row.iconFrame = CreateFrame("Frame", nil, row)
	row.iconFrame:SetSize(18, 18)
	row.iconFrame:SetPoint("LEFT", 4, 0)
	row.icon = Widgets.Icon(row.iconFrame, 18)
	row.icon:SetAllPoints()
	row.value = Widgets.Text(row, "body")
	row.value:SetPoint("RIGHT", -6, 0)
	row.value:SetJustifyH("RIGHT")
	row.value:SetWidth(120)
	row.detail = Widgets.Text(row, "small", "dim")
	row.detail:SetPoint("RIGHT", row.value, "LEFT", -10, 0)
	row.detail:SetJustifyH("RIGHT")
	row.detail:SetWidth(170)
	row.name = Widgets.Text(row, "body")
	row.name:SetPoint("LEFT", row.iconFrame, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row.detail, "LEFT", -8, 0)
	row:SetScript("OnEnter", function(self)
		self.highlight:Show()
		local behaviour = ROWS[self.entry.kind]
		if behaviour.tooltip then
			behaviour.tooltip(self, self.entry.data)
		end
	end)
	row:SetScript("OnLeave", function(self)
		self.highlight:Hide()
		GameTooltip:Hide()
		HideModel()
	end)
	row:SetScript("OnClick", OnRowClick)
end

-- The view --------------------------------------------------------------------------------

local SessionViewMixin = {}

local LIST_KINDS = { "items", "monsters", "quests", "zones", "dungeons" }
local IS_LIST_KIND = { items = true, monsters = true, quests = true, zones = true, dungeons = true }

function SessionViewMixin:Build()
	local width = self:GetWidth()
	self.cards = {}
	for index = 1, #SESSION_CARDS do
		self.cards[index] = Widgets.StatCard(self)
	end
	Widgets.LayoutGrid(self, self.cards, 4, 0, CARD_GAP)

	local cardsHeight = 2 * Widgets.CARD_HEIGHT + CARD_GAP
	self.extras = CreateFrame("Button", nil, self)
	self.extras:SetPoint("TOPLEFT", 0, -(cardsHeight + 8))
	self.extras:SetSize(width, 16)
	self.extras.text = Widgets.Text(self.extras, "small", "dim")
	self.extras.text:SetPoint("LEFT")
	self.extras:SetScript("OnEnter", function(button)
		self:ShowExtrasTooltip(button)
	end)
	self.extras:SetScript("OnLeave", Widgets.HideTooltip)

	local items = {}
	if self.options.showSessions then
		items[#items + 1] = { key = "sessions", label = L.LIST_SESSIONS }
	end
	for _, kind in ipairs(LIST_KINDS) do
		items[#items + 1] = { key = kind, label = L["LIST_" .. kind:upper()] }
	end
	self.listTabs = Widgets.Tabs(self, items, "segmented", function(kind)
		self:SetListKind(kind)
	end)
	self.listTabs:SetPoint("TOPLEFT", 0, -(cardsHeight + 30))

	self.list = Widgets.ScrollList(self, ROW_HEIGHT, BuildRow, function(row, entry)
		row.entry = entry
		row.owner = self
		Widgets.StripeRow(row, entry.index)
		Theme.Tone(row.name, "primary")
		if row.accentName then
			Theme.ForgetAccent(row.name)
			row.accentName = nil
		end
		ROWS[entry.kind].bind(row, entry.data, entry.total)
	end)
	self.list:SetPoint("TOPLEFT", 0, -(cardsHeight + 58))
	self.list:SetPoint("BOTTOMRIGHT")

	local saved = Database.Get("listKind")
	self.listKind = self.options.showSessions and "sessions" or (IS_LIST_KIND[saved] and saved or "items")
end

function SessionViewMixin:ShowExtrasTooltip(owner)
	local view = self.view
	if not view then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
	GameTooltip:SetText(L.MORE, 1, 1, 1)
	AddLine(L.DEATHS, Format.Integer(view.deaths))
	AddLine(L.DUNGEON_RUNS, Format.Integer(view.dungeonCount or 0))
	AddLine(L.LEGACY_POINTS, Format.Integer(view.legacy))
	for _, entry in ipairs(view.achievements) do
		local _, name, _, _, _, _, _, _, _, icon = GetAchievementInfo(entry.achievementID)
		if name then
			GameTooltip:AddLine("|T" .. (icon or 0) .. ":0|t " .. name, 1, 0.82, 0)
		end
	end
	GameTooltip:Show()
end

function SessionViewMixin:RefreshCards()
	local view, context = self.view, self.context
	local metrics = Session.Metrics(view, context.now, Database.Get("excludeAfk"))
	local set = CardSet(view)
	local shown = {}
	for index, key in ipairs(set) do
		local spec = CARDS[key]
		shown[key] = true
		self.cards[index]:SetContent(
			Theme.Icon(spec.icon),
			spec.label,
			spec.value(metrics, view, context),
			spec.sub(metrics, view, context),
			function()
				spec.tooltip(metrics, view, context)
			end
		)
	end

	local extras = {}
	local function Extra(icon, text)
		extras[#extras + 1] = "|T" .. icon .. ":0|t " .. text
	end
	if metrics.deaths > 0 and not shown.deaths then
		Extra(Theme.Icon("deaths"), Format.Count(metrics.deaths, L.COUNT_DEATHS))
	end
	if metrics.dungeons > 0 and not shown.dungeons then
		Extra(Theme.Icon("zoneDungeon"), Format.Count(metrics.dungeons, L.COUNT_DUNGEON_RUNS))
	end
	if metrics.achievements > 0 then
		Extra(Theme.Icon("achievements"), Format.Count(metrics.achievements, L.COUNT_ACHIEVEMENTS))
	end
	if metrics.legacy > 0 then
		Extra(Theme.Icon("legacy"), L.EXTRA_LEGACY:format(metrics.legacy))
	end
	self.extras.text:SetText(table.concat(extras, "    "))
	self.extras:SetShown(#extras > 0)
end

local function MonsterRows(view)
	local rows = {}
	for index, monster in ipairs(view.monsters) do
		rows[index] = monster
	end
	if view.unidentifiedKills > 0 then
		rows[#rows + 1] = { name = L.UNIDENTIFIED, count = view.unidentifiedKills, unidentified = true }
	end
	return rows
end

local function ItemRows(view)
	local rows = {}
	for index, item in ipairs(view.items) do
		rows[index] = item
	end
	for _, item in ipairs(view.consumed or {}) do
		rows[#rows + 1] =
			{ itemID = item.itemID, count = item.count, unitValue = item.unitValue, value = item.value, used = true }
	end
	return rows
end

local function DungeonRows(view)
	local rows = {}
	for index, run in ipairs(view.dungeons) do
		rows[index] = run
	end
	rows[#rows + 1] = view.currentDungeon
	return rows
end

--- Rows for the current list kind, wrapped as {kind, index, data, total} entries.
function SessionViewMixin:ListEntries(kind)
	local view = self.view
	local source
	if kind == "sessions" then
		source = self.context.sessions or {}
	elseif kind == "monsters" then
		source = MonsterRows(view)
	elseif kind == "dungeons" then
		source = DungeonRows(view)
	elseif kind == "items" then
		source = ItemRows(view)
	else
		source = view[kind]
	end
	local total = kind == "zones" and Sum(view.zones, "seconds") or nil
	local entries = {}
	for index, data in ipairs(source) do
		entries[index] = { kind = kind, index = index, data = data, total = total }
	end
	return entries
end

function SessionViewMixin:RefreshListTabs()
	local view = self.view
	local counts = {
		sessions = self.context.sessions and #self.context.sessions or 0,
		items = #view.items + #(view.consumed or {}),
		monsters = #view.monsters + (view.unidentifiedKills > 0 and 1 or 0),
		quests = #view.quests,
		zones = #view.zones,
		dungeons = #view.dungeons + (view.currentDungeon and 1 or 0),
	}
	local labels = {}
	for kind, count in pairs(counts) do
		if kind ~= "sessions" or self.options.showSessions then
			labels[kind] = L["LIST_" .. kind:upper()] .. "  " .. count
		end
	end
	self.listTabs:SetLabels(labels)
	self.listTabs:Select(self.listKind, true)
end

function SessionViewMixin:RefreshList(keepPosition)
	self:RefreshListTabs()
	self.list:SetEmptyText(L["EMPTY_" .. self.listKind:upper()])
	self.list:SetRows(self:ListEntries(self.listKind), keepPosition)
end

---@param kind string
function SessionViewMixin:SetListKind(kind)
	self.listKind = kind
	if kind ~= "sessions" then
		Database.Set("listKind", kind)
	end
	if self.view then
		self:RefreshList(false)
	end
end

---@class SeshViewContext
---@field now integer
---@field live boolean? the view is still running (the active session or the current level)
---@field sessions table[]? session rows for range views

--- Shows a view. keepPosition keeps list scroll positions (live refreshes).
---@param view SeshView
---@param context SeshViewContext
---@param keepPosition boolean?
function SessionViewMixin:SetView(view, context, keepPosition)
	self.view = view
	self.context = context
	self:RefreshCards()
	self:RefreshList(keepPosition)
end

--- Updates the time-dependent numbers (duration and rates) of a live view.
function SessionViewMixin:Tick(now)
	if self.view and self.context and self.context.live then
		self.context.now = now
		self:RefreshCards()
	end
end

--- Re-binds visible rows, e.g. when item names finished loading.
function SessionViewMixin:RefreshRows()
	self.list:Refresh()
end

---@class SeshSessionViewOptions
---@field showSessions boolean? add a Sessions list (range views)
---@field onSessionClick fun(id: integer)?

---@param parent table
---@param options SeshSessionViewOptions?
---@return table
function SessionView.New(parent, options)
	local frame = Mixin(CreateFrame("Frame", nil, parent), SessionViewMixin)
	frame:SetSize(parent:GetWidth(), parent:GetHeight())
	frame:SetPoint("TOPLEFT")
	frame.options = options or {}
	frame:Build()
	return frame
end

--- Turns history records (plus the live session) into rows for the Sessions list,
--- newest first.
---@param records table[]
---@param live SeshView?
---@param now integer
---@param excludeAfk boolean
function SessionView.SessionRows(records, live, now, excludeAfk)
	local rows = {}
	if live then
		local metrics = Session.Metrics(live, now, excludeAfk)
		rows[1] = {
			id = live.id,
			live = true,
			startedAt = live.startedAt,
			duration = metrics.duration,
			goldEarned = metrics.goldEarned,
			xp = live.xp,
			kills = live.kills,
		}
	end
	for index = #records, 1, -1 do
		local record = records[index]
		rows[#rows + 1] = {
			id = record.id,
			startedAt = record.startedAt,
			duration = (record.endedAt or record.startedAt) - record.startedAt,
			goldEarned = (record.money or 0) + (record.itemValue or 0),
			xp = record.xp or 0,
			kills = record.kills or 0,
		}
	end
	return rows
end
