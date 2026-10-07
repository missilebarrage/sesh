local _, ns = ...

--- Visual tokens and shared drawing helpers. The look follows EllesmereUI: warm near-black
--- flat panels, 1-pixel hairline borders, white text graded by alpha, and one accent
--- colour used sparingly. When EllesmereUI is loaded, its live accent colour and font are
--- used; otherwise Forever's bronze default and Arial Narrow.
---@class SeshTheme
local Theme = ns.Theme
local Events = ns.Events
local Format = ns.Format

Theme.COLORS = {
	panel = { 0.069, 0.058, 0.047, 0.95 },
	header = { 0, 0, 0, 0.45 },
	inset = { 0, 0, 0, 0.22 },
	border = { 1, 1, 1, 0.08 },
	divider = { 1, 1, 1, 0.06 },
	rowOdd = { 0, 0, 0, 0.10 },
	rowEven = { 0, 0, 0, 0.20 },
	hover = { 1, 1, 1, 0.06 },
	control = { 0.089, 0.080, 0.072, 0.60 },
	controlBorder = { 1, 1, 1, 0.22 },
	track = { 1, 1, 1, 0.07 },
	empty = { 1, 1, 1, 0.06 },
	positive = { 0.45, 0.85, 0.45, 1 },
	warning = { 1, 0.45, 0.35, 1 },
}

--- Text colours are white at different strengths.
Theme.TEXT = { primary = 1, dim = 0.53, muted = 0.41, faint = 0.3 }

-- EllesmereUI's default accent on the Forever client.
Theme.DEFAULT_ACCENT = { 0.863, 0.655, 0.498 }

local DEFAULT_FONT = "Fonts\\ARIALN.TTF"

-- Fonts --------------------------------------------------------------------------------

-- Text shadows only render when they come from a font object on this client, so every
-- Sesh string uses one of these.
local FONT_ROLES = {
	title = { name = "SeshFontTitle", size = 14 },
	heading = { name = "SeshFontHeading", size = 13 },
	body = { name = "SeshFontBody", size = 12 },
	small = { name = "SeshFontSmall", size = 11 },
	label = { name = "SeshFontLabel", size = 10 },
	value = { name = "SeshFontValue", size = 17 },
	large = { name = "SeshFontLarge", size = 22 },
}

local fonts = {}
for role, spec in pairs(FONT_ROLES) do
	local font = CreateFont(spec.name)
	font:SetShadowColor(0, 0, 0, 1)
	font:SetShadowOffset(1, -1)
	fonts[role] = font
end

-- Font:SetFont returns nothing and raises for a font file the client can't load.
local function TrySetFont(font, path, size)
	return pcall(font.SetFont, font, path, size, "") and font:GetFont() ~= nil
end

local function ApplyFont(path)
	for role, spec in pairs(FONT_ROLES) do
		if not TrySetFont(fonts[role], path, spec.size) then
			TrySetFont(fonts[role], STANDARD_TEXT_FONT, spec.size)
		end
	end
end
ApplyFont(DEFAULT_FONT)

---@param role "title"|"heading"|"body"|"small"|"label"|"value"|"large"
---@return table fontObject
function Theme.Font(role)
	return fonts[role]
end

-- Accent -------------------------------------------------------------------------------

local accent = { r = Theme.DEFAULT_ACCENT[1], g = Theme.DEFAULT_ACCENT[2], b = Theme.DEFAULT_ACCENT[3] }
local accentHex = nil
-- Regions painted with the accent, repainted when it changes. Weak keys: regions may go away.
local accentRegions = setmetatable({}, { __mode = "k" })

local function Paint(region, paint)
	if paint.kind == "text" then
		region:SetTextColor(accent.r, accent.g, accent.b, paint.alpha)
	elseif paint.kind == "vertex" then
		region:SetVertexColor(accent.r, accent.g, accent.b, paint.alpha)
	else
		region:SetColorTexture(accent.r, accent.g, accent.b, paint.alpha)
	end
end

---@return number r
---@return number g
---@return number b
function Theme.Accent()
	return accent.r, accent.g, accent.b
end

--- The accent as "rrggbb" for |c colour escapes.
---@return string
function Theme.AccentHex()
	if not accentHex then
		accentHex = string.format(
			"%02x%02x%02x",
			math.floor(accent.r * 255 + 0.5),
			math.floor(accent.g * 255 + 0.5),
			math.floor(accent.b * 255 + 0.5)
		)
	end
	return accentHex
end

--- Wraps text in the accent colour.
function Theme.AccentText(text)
	return Format.Color(text, accent.r, accent.g, accent.b)
end

--- Colours a region with the accent and keeps it in sync when the accent changes.
---@param region table texture or font string
---@param alpha number?
---@param kind "texture"|"text"|"vertex"|nil default "texture"
function Theme.PaintAccent(region, alpha, kind)
	local paint = { alpha = alpha or 1, kind = kind or "texture" }
	accentRegions[region] = paint
	Paint(region, paint)
end

--- Stops repainting a region with the accent.
function Theme.ForgetAccent(region)
	accentRegions[region] = nil
end

function Theme.SetAccent(r, g, b)
	if not (ns.Num(r) and ns.Num(g) and ns.Num(b)) then
		return
	end
	accent.r, accent.g, accent.b = r, g, b
	accentHex = nil
	for region, paint in pairs(accentRegions) do
		Paint(region, paint)
	end
	Events.Fire("SESH_ACCENT_CHANGED")
end

-- Drawing helpers ------------------------------------------------------------------------

---@param frame table
---@param color number[]? defaults to the panel colour
---@param layer string? draw layer, default BACKGROUND
---@return table texture
function Theme.Fill(frame, color, layer)
	local texture = frame:CreateTexture(nil, layer or "BACKGROUND")
	texture:SetAllPoints()
	texture:SetColorTexture(unpack(color or Theme.COLORS.panel))
	return texture
end

--- Sets text colour to white at one of the Theme.TEXT strengths.
---@param fontString table
---@param strength "primary"|"dim"|"muted"|"faint"
function Theme.Tone(fontString, strength)
	fontString:SetTextColor(1, 1, 1, Theme.TEXT[strength])
end

local borders = setmetatable({}, { __mode = "k" })

local function LayoutBorder(frame, edges)
	-- One physical pixel, whatever the UI scale.
	local pixel = PixelUtil.GetPixelToUIUnitFactor() / frame:GetEffectiveScale()
	local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
	top:SetHeight(pixel)
	bottom:SetHeight(pixel)
	left:SetWidth(pixel)
	right:SetWidth(pixel)
end

--- Draws a hairline border inside the frame's edges.
---@param frame table
---@param color number[]? defaults to Theme.COLORS.border
---@return table[] edges top, bottom, left, right textures
function Theme.Border(frame, color)
	color = color or Theme.COLORS.border
	local edges = {}
	for index = 1, 4 do
		local edge = frame:CreateTexture(nil, "BORDER")
		edge:SetColorTexture(unpack(color))
		edge:SetSnapToPixelGrid(false)
		edge:SetTexelSnappingBias(0)
		edges[index] = edge
	end
	edges[1]:SetPoint("TOPLEFT")
	edges[1]:SetPoint("TOPRIGHT")
	edges[2]:SetPoint("BOTTOMLEFT")
	edges[2]:SetPoint("BOTTOMRIGHT")
	edges[3]:SetPoint("TOPLEFT")
	edges[3]:SetPoint("BOTTOMLEFT")
	edges[4]:SetPoint("TOPRIGHT")
	edges[4]:SetPoint("BOTTOMRIGHT")
	borders[frame] = edges
	LayoutBorder(frame, edges)
	return edges
end

local dividers = setmetatable({}, { __mode = "k" })

local function LayoutDivider(line, parent)
	line:SetHeight(PixelUtil.GetPixelToUIUnitFactor() / parent:GetEffectiveScale())
end

--- A 1-pixel horizontal rule.
---@return table texture
function Theme.Divider(parent, color)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(unpack(color or Theme.COLORS.divider))
	line:SetSnapToPixelGrid(false)
	line:SetTexelSnappingBias(0)
	dividers[line] = parent
	LayoutDivider(line, parent)
	return line
end

--- Re-fits every border and divider to one physical pixel (after UI or window scale changes).
function Theme.RefreshPixels()
	for frame, edges in pairs(borders) do
		LayoutBorder(frame, edges)
	end
	for line, parent in pairs(dividers) do
		LayoutDivider(line, parent)
	end
end

-- Icons --------------------------------------------------------------------------------

local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

-- Candidates in order of preference; the first file the client has wins.
local ICON_CANDIDATES = {
	goldEarned = { "Interface\\Icons\\INV_Misc_Coin_02", "Interface\\Icons\\INV_Misc_Coin_01" },
	goldPerHour = { "Interface\\Icons\\INV_Misc_Coin_01", "Interface\\Icons\\INV_Misc_Coin_02" },
	rawGold = { "Interface\\Icons\\INV_Misc_Coin_03", "Interface\\Icons\\INV_Misc_Coin_01" },
	itemValue = { "Interface\\Icons\\INV_Misc_Bag_10", "Interface\\Icons\\INV_Misc_Bag_07" },
	xp = { "Interface\\Icons\\INV_Misc_Book_11", "Interface\\Icons\\INV_Misc_Book_09" },
	xpPerHour = { "Interface\\Icons\\Spell_Holy_BorrowedTime", "Interface\\Icons\\INV_Misc_Book_09" },
	duration = { "Interface\\Icons\\INV_Misc_PocketWatch_01" },
	levelTime = { "Interface\\Icons\\Spell_Holy_BorrowedTime", "Interface\\Icons\\INV_Misc_PocketWatch_01" },
	sessions = { "Interface\\Icons\\INV_Misc_PocketWatch_02", "Interface\\Icons\\INV_Misc_PocketWatch_01" },
	kills = { "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", "Interface\\Icons\\Ability_Warrior_Rampage" },
	quests = { "Interface\\Icons\\INV_Misc_Note_01", "Interface\\Icons\\INV_Scroll_03" },
	zones = { "Interface\\Icons\\INV_Misc_Map_01" },
	items = { "Interface\\Icons\\INV_Misc_Bag_08", "Interface\\Icons\\INV_Misc_Bag_10" },
	deaths = { "Interface\\Icons\\Ability_Rogue_FeignDeath", "Interface\\Icons\\Spell_Shadow_DeathScream" },
	achievements = { "Interface\\Icons\\INV_Misc_Ribbon_01", "Interface\\Icons\\INV_Misc_Note_02" },
	legacy = { "Interface\\Icons\\INV_Misc_Token_ArgentDawn3", "Interface\\Icons\\INV_Misc_Gem_Pearl_05" },
	streak = { "Interface\\Icons\\Spell_Fire_Fire", "Interface\\Icons\\Spell_Fire_FlameBolt" },
	record = { "Interface\\Icons\\INV_Misc_Gem_Diamond_01", "Interface\\Icons\\INV_Misc_Gem_Diamond_02" },
	average = { "Interface\\Icons\\Spell_Nature_TimeStop", "Interface\\Icons\\INV_Misc_PocketWatch_02" },
	levelUp = { "Interface\\Icons\\Spell_Holy_HolyBolt", "Interface\\Icons\\INV_Misc_Book_09" },
	unknown = { QUESTION_MARK },
	-- Zone kinds.
	zoneWorld = { "Interface\\Icons\\INV_Misc_Map_01" },
	zoneDungeon = { "Interface\\Icons\\INV_Misc_Key_13", "Interface\\Icons\\INV_Misc_Key_03" },
	zoneRaid = { "Interface\\Icons\\INV_Misc_Head_Dragon_Black", "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
	zonePvP = { "Interface\\Icons\\INV_Sword_27", "Interface\\Icons\\Ability_DualWield" },
	quest = { "Interface\\GossipFrame\\ActiveQuestIcon", "Interface\\Icons\\INV_Misc_Note_01" },
	-- Creature types (by type ID).
	creature1 = { "Interface\\Icons\\Ability_Hunter_Pet_Wolf" },
	creature2 = { "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
	creature3 = { "Interface\\Icons\\Spell_Shadow_SummonFelHunter" },
	creature4 = { "Interface\\Icons\\Spell_Frost_SummonWaterElemental", "Interface\\Icons\\Spell_Fire_Fire" },
	creature5 = { "Interface\\Icons\\Ability_Racial_Avatar", "Interface\\Icons\\INV_Stone_15" },
	creature6 = { "Interface\\Icons\\Spell_Shadow_RaiseDead" },
	creature7 = { "Interface\\Icons\\INV_Misc_Head_Human_01", "Interface\\Icons\\INV_Misc_Head_Orc_01" },
	creature9 = { "Interface\\Icons\\INV_Misc_Gear_01" },
	creature15 = { "Interface\\Icons\\Spell_Shadow_ShadowWordDominate" },
}

local resolvedIcons = {}
local missingIcons = {}
local canProbeFiles ---@type boolean?

-- GetFileIDFromPath tells whether the client has an icon. If it can't even find the
-- question mark, probing doesn't work on this client: trust the first candidate instead.
local function FileExists(path)
	if canProbeFiles == nil then
		canProbeFiles = GetFileIDFromPath ~= nil and GetFileIDFromPath(QUESTION_MARK) ~= nil
	end
	return not canProbeFiles or GetFileIDFromPath(path) ~= nil
end

--- Path of a themed icon, falling back to a question mark when the client lacks the art.
---@param key string
---@return string
function Theme.Icon(key)
	local resolved = resolvedIcons[key]
	if resolved then
		return resolved
	end
	for _, path in ipairs(ICON_CANDIDATES[key] or {}) do
		if FileExists(path) then
			resolved = path
			break
		end
	end
	if not resolved then
		missingIcons[key] = true
		resolved = (key:find("^creature") and Theme.Icon("kills")) or QUESTION_MARK
	end
	resolvedIcons[key] = resolved
	return resolved
end

--- Icon for a creature type ID (skull when unknown).
function Theme.CreatureIcon(typeID)
	if typeID and ICON_CANDIDATES["creature" .. typeID] then
		return Theme.Icon("creature" .. typeID)
	end
	return Theme.Icon("kills")
end

local ZONE_ICONS = { [0] = "zoneWorld", "zoneDungeon", "zoneRaid", "zonePvP", "zoneWorld" }

function Theme.ZoneIcon(kind)
	return Theme.Icon(ZONE_ICONS[kind] or "zoneWorld")
end

--- Whether the client has a texture atlas (some retail atlases are missing on Forever).
function Theme.HasAtlas(atlas)
	return C_Texture.GetAtlasInfo(atlas) ~= nil
end

--- Icon keys whose art was missing, for /sesh debug.
---@return string[]
function Theme.MissingIcons()
	local keys = {}
	for key in pairs(missingIcons) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	return keys
end

--- Adopts EllesmereUI's accent colour and font when it's loaded. Called at PLAYER_LOGIN.
function Theme.Init()
	local ellesmere = EllesmereUI
	if type(ellesmere) == "table" then
		if type(ellesmere.GetAccentColor) == "function" then
			local ok, r, g, b = pcall(ellesmere.GetAccentColor)
			if ok then
				Theme.SetAccent(r, g, b)
			end
		end
		if type(ellesmere.RegAccent) == "function" then
			pcall(ellesmere.RegAccent, {
				type = "callback",
				fn = function(r, g, b)
					Theme.SetAccent(r, g, b)
				end,
			})
		end
		if type(ellesmere.GetFontPath) == "function" then
			local ok, path = pcall(ellesmere.GetFontPath)
			if ok and type(path) == "string" and path ~= "" then
				ApplyFont(path)
			end
		end
	end
	Events.On("UI_SCALE_CHANGED", Theme.RefreshPixels)
	Events.On("DISPLAY_SIZE_CHANGED", Theme.RefreshPixels)
end
