# Client API notes

Facts about the WoW Forever client that Sesh's design depends on. Verified against Blizzard's
exported UI source for the matching build: GitHub `Gethe/wow-ui-source`, branch `forever`,
revision `966519cf0ad2c10301ea011a88c14b25697c9687` (build 1.60.1.70124). Re-check these
files when the client updates.

## Client

- TOC `## Interface: 16001`; Blizzard game type `camelot`; the UI code is the Mainline family
  (modern `C_*` namespaces, Settings, ScrollBox, `C_EncodingUtil`).
- A plain `Sesh.toc` (no flavor suffix) loads.
- Deprecated globals (`GetItemInfo`, `ChatFrame_*`, `ChatEdit_*`, `SendChatMessage`,
  `InterfaceOptions_*`, `CombatLogGetCurrentEventInfo`) only exist when the
  `loadDeprecationFallbacks` CVar is on. Sesh uses only the modern names.
- `ReloadUI()` is blocked for addon code.

## Secret values

- `issecretvalue(v)` and friends exist (`Blizzard_APIDocumentationGenerated/FrameScriptDocumentation.lua`).
  Secret values may be passed around but not compared, used in arithmetic or as table keys.
  `ns.Num` / `ns.Str` gate every value Sesh reads from the game.
- Unit identity (`UnitGUID`, `UnitName`, `UnitCreatureType`, `PARTY_KILL` GUIDs) is
  `SecretWhenUnitIdentityRestricted` (`UnitDocumentation.lua`).
- Chat text events (say, party, guild, whisper, channel...) are `SecretInChatMessagingLockdown`
  (`ChatInfoDocumentation.lua`). `CHAT_MSG_LOOT`, `CHAT_MSG_MONEY`, `CHAT_MSG_COMBAT_XP_GAIN`
  and `CHAT_MSG_ADDON` are not flagged.

## Kills

- `COMBAT_LOG_EVENT_UNFILTERED` is restricted for addons (`CombatLogDocumentation.lua`).
- `PARTY_KILL(attackerGUID, targetGUID)` and `UNIT_DIED(unitGUID)` are standalone events
  (`UnitDocumentation.lua`). Sesh counts `PARTY_KILL`.
- `UnitTokenFromGUID` exists and accepts secret arguments.

## Levels and dungeons

- Max level: `GameRulesUtil.IsPlayerAtEffectiveMaxLevel()` (shared `Blizzard_SharedXML/GameRulesUtil.lua`,
  loaded on every game type) compares `UnitLevel` with
  `min(GetMaxLevelForPlayerExpansion(), GetMaxPlayerLevel())`. The XP bar also uses
  `GetXPExhaustion()` for rested experience (`Blizzard_StatusTrackingBar/Shared/ExpBar.lua`).
- `PLAYER_LEVEL_UP(level, ...)`; level and experience update separately, in either order
  (see `Tracking/Progress.lua`). `TIME_PLAYED_MSG(total, thisLevel)` exists but needs
  `RequestTimePlayed()`, which prints to chat; Sesh doesn't use it.
- No dungeon finder on this client: `Blizzard_GroupFinder` has `ExcludeLoadGameType: camelot`
  (only the premade `Blizzard_GroupFinder_VanillaStyle` loads), so `LFG_COMPLETION_REWARD`
  can't mark dungeons complete. The encounter journal's files don't load for camelot either.
- `ENCOUNTER_END(encounterID, encounterName, difficultyID, groupSize, success)` and
  `BOSS_KILL(encounterID, encounterName)` (`EncounterInfoDocumentation.lua`) carry no
  secret-value flags. `GetInstanceInfo()` returns name, instanceType ("party" for dungeons),
  ..., instanceID (`InstanceDocumentation.lua`).
- Event payloads that can be secret are flagged in the generated docs with
  `SecretWhenUnitIdentityRestricted`, `SecretInChatMessagingLockdown` or `SecretPayloads`.

## Money and items

- `PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE(type)` with `Enum.PlayerInteractionType`
  (TradePartner 1, Merchant 5, Banker 8, GuildBanker 10, Vendor 12, MailInfo 17,
  Auctioneer 21, CharacterBanker 67, AccountBanker 68).
- `C_Item.GetItemInfo` returns the vendor sell price as its 11th value and the bind type as its
  14th (`Enum.ItemBind`: OnAcquire 1 = bind on pickup, OnEquip 2, OnUse 3, Quest 4,
  ToWoWAccount 7, ToBnetAccount 8; `ItemConstantsDocumentation.lua`).
- `LOOT_OPENED(autoLoot, isFromItem)` says when a loot window comes from an item (disenchant,
  container, lockbox); `LOOT_CLOSED`. `GetNumLootItems()` and `GetLootSlotInfo` are used by
  Blizzard's `LootFrame.lua`; `GetLootSourceInfo(slot)` (source GUIDs) isn't in the generated
  docs, so Sesh guards it and falls back to `ITEM_LOCK_CHANGED(bag, slot)` +
  `C_Container.GetContainerItemInfo(bag, slot).isLocked/itemID` (the item being disenchanted or
  opened is locked). `C_Item.GetItemIDByGUID(itemGUID)` (`ItemDocumentation.lua`).
- `QUEST_TURNED_IN(questID, xpReward, moneyReward)`.
- Auctionator v340 API (installed addon source, `Source/API/v1`):
  `Auctionator.API.v1.GetAuctionPriceByItemID(callerID, itemID)` returns per-unit copper (may
  be fractional) or nil; the price database exists after `PLAYER_LOGIN`;
  `RegisterForDBUpdate(callerID, callback)` calls back synchronously inside Auctionator.

## Legacy Points

- `Constants.LegacyConsts` (`LegacyConstantsDocumentation.lua`): currency 4225, trees
  1187–1189. `Blizzard_LegacySystemUtil.lua` reads
  `C_Traits.GetTreeCurrencyInfo(C_Traits.GetConfigIDByTreeID(treeID), treeID, true)`.
  The pool is shared: points earned = change in (quantity + spent).

## Chat links and sharing

- `LinkTypes.AddOn = "addon"`; clicks on `|Haddon:...|h` links trigger
  `EventRegistry:TriggerEvent("SetItemRef", link, text, button, frame)`
  (`Blizzard_UIPanels_Game/Shared/ItemRefHandlersShared.lua`).
- `ChatFrameUtil.AddMessageEventFilter(event, filter)`; filters are skipped for secret text
  (`Blizzard_ChatFrameBase/Shared/ChatFrameFilters.lua`).
- `ChatFrameUtil.GetActiveWindow()` / `ChatFrameUtil.OpenChat(text)` to put text in the chat box.
- `C_ChatInfo.SendAddonMessage` returns `Enum.SendAddonMessageResult` (3 and 8 throttled,
  11 lockdown, 12 target offline); `C_ChatInfo.InChatMessagingLockdown()`.
- `C_EncodingUtil` has SerializeCBOR/DeserializeCBOR, CompressString/DecompressString
  (Deflate) and EncodeBase64/DecodeBase64; decompression is capped at 100 MB.

## UI

- `WowScrollBoxList` + `CreateScrollBoxListLinearView` + `CreateDataProvider`; `scrollBox:Init(view)`;
  `BaseScrollBoxEvents.OnScroll(scrollPercentage, visibleExtentPercentage, panExtentPercentage)`.
- Settings: `Settings.RegisterVerticalLayoutCategory`, `RegisterAddOnSetting(category, variable,
  variableKey, variableTbl, type, name, default)`, `CreateCheckbox/CreateSlider/CreateDropdown`,
  `CreateSettingsListSectionHeaderInitializer`, `CreateSettingsButtonInitializer`,
  `Settings.OpenToCategory(category:GetID())`.
- `AddonCompartmentFrame:RegisterAddon({text, icon, func, funcOnEnter, funcOnLeave})`.
- `PixelUtil.GetPixelToUIUnitFactor()`; `Frame:SetDontSavePosition`.
- Text shadows only render when they come from a font object (observed in EllesmereUI's
  source: `EllesmereUI_Fonts.lua`), so Sesh uses `CreateFont` objects for all text.
- EllesmereUI runtime API (installed addon source): `EllesmereUI.GetAccentColor()`,
  `EllesmereUI.RegAccent({type = "callback", fn = function(r, g, b) end})`,
  `EllesmereUI.GetFontPath()`.
