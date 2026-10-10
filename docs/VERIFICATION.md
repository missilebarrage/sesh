# In-game verification

The test suite runs Sesh against a fake game API, so a few things can only be confirmed in the
real client. Install with `scripts/install.sh`, restart the game (a new addon needs a restart;
later changes only need `/reload`), then go through this list. `/sesh debug` prints counts and
capabilities only — never names.

Record results under **Results** with the date and client build.

## 1. Probes

- [ ] `/sesh debug` shows `PARTY_KILL: yes`.
- [ ] Kill a few monsters in the open world: the Monsters list shows their names and creature
      icons; `partyKills` in `/sesh debug` goes up.
- [ ] Kill a monster you never targeted or saw a nameplate for (e.g. with nameplates off):
      check whether `tooltipIdentified` in `/sesh debug` goes up (the tooltip fallback works)
      or `unknownKillsSkipped` does (it doesn't — only XP messages can name such kills).
- [ ] Kill a critter with an area attack: it isn't counted.
- [ ] Run part of a dungeon: kills still count. Note whether monsters show names or
      "Unidentified" (and whether an XP message named them while leveling).
- [ ] `/sesh debug` → `secret restrictions active` value in the open world and in a dungeon.
- [ ] `missing icons` in `/sesh debug` is `-` (otherwise note which keys are missing).
- [ ] The Sesh entry appears in the minimap's addon compartment.

## 2. Tracking

- [ ] Loot coins and items: raw gold and the Items list update; item values look right
      (with and without an Auctionator scan for the item).
- [ ] Sell to a vendor and collect mail: raw gold doesn't change.
- [ ] Buy from a vendor: the purchase doesn't appear in Items.
- [ ] Loot a bind-on-pickup item: its tooltip in Items says "vendor, soulbound" even if
      Auctionator has a price for it; a bind-on-equip item uses the auction price.
- [ ] Disenchant an item: the dust appears in Items, the item shows below as "used up" with a
      negative value, and Item value is the dust minus the item. Same for opening a clam or a
      lockbox (coins count as raw gold). `/sesh debug` shows `itemsUsedUp` and
      `conversionFromSource` (or `conversionFromLock` when the client doesn't name loot
      sources; `conversionUnknown` means the item couldn't be identified).
- [ ] Turn in a quest: it appears in Quests with its XP and gold.
- [ ] Gain experience across a level-up: XP total is continuous; the level card updates.
- [ ] Go AFK for a few minutes: Duration keeps running, the active time doesn't.
- [ ] Change zones and enter a dungeon: Zones lists both with times.
- [ ] In a dungeon, kill a boss: the Dungeons list shows the run "In progress" with 1 boss
      (this confirms `ENCOUNTER_END`/`BOSS_KILL` fire for dungeon bosses on Forever). Die,
      run back in: still the same run. Leave for 15 minutes: the run shows its duration.
- [ ] `/reload`: the same session continues (same #id, nothing counted twice).
- [ ] Log out and back in within 5 minutes: the session continues. Log out for longer: the
      old session appears in History and a new one starts.
- [ ] Delete a character that has Sesh history and create one with the same name: Sesh says
      it started a fresh history, and History and Leveling are empty.

## 3. Interface

- [ ] The window header shows your full name (first name and surname).
- [ ] The Options button shows a cog; card text has room around it and nothing is cut off mid-icon.
- [ ] Window drag, position after `/reload`, Escape closes it, scale option works.
- [ ] Lists scroll with the mouse wheel and the thin scrollbar; hover tooltips (item tooltip,
      monster 3D preview) look right; Shift-click on an item links it in chat.
- [ ] History ranges, opening a session, Back, Delete (with confirmation).
- [ ] Summary: activity grid hover/click, metric switch remembered, records open their sessions.
- [ ] With EllesmereUI: changing its accent colour recolours Sesh immediately; its font is used.
- [ ] Options > AddOns > Sesh: every option works and Defaults resets them.

## 4. Mini window

- [ ] After logging in, the mini window shows on the left with Session time, Gold earned,
      Gold / hour, XP / hour and Level up in; the numbers update while you play and the time
      ticks every second.
- [ ] Click it: Sesh opens and the mini window hides. Close Sesh (× or Escape): it's back.
      `/sesh mini` with Sesh open shrinks it into the mini window.
- [ ] Shift-drag moves it; a plain drag doesn't; the position survives `/reload`; adding or
      removing numbers keeps its top edge in place.
- [ ] No title bar: the first number sits at the top edge. Hover shows a short "how to use"
      tooltip. Right-click > Hide the mini window hides it and says to type `/sesh mini`.
- [ ] Options > AddOns > Sesh > Mini window opacity: at 0% only the numbers and icons show
      (still readable over the world), at 100% the full panel; the numbers never fade.
- [ ] Right-click opens a menu with a checkbox per number (leveling ones under "While
      leveling"); it stays open while toggling and the window resizes to fit. With nothing
      ticked, the window says to right-click. Options > AddOns > Sesh shows the same switches
      (and updates if you change them from the menu while it's open) plus a scale slider.
- [ ] With mini mode off, the Sesh header shows a minimize button that turns it on.
- [ ] Level progress shows a thin bar with rested experience; at max level the experience
      rows disappear.

## 5. Leveling

- [ ] Leveling tab: the panel shows your level, the percentage and experience matching the
      game's XP bar, rested experience as a lighter part of the bar, and the time at the level.
- [ ] Level up: the chat shows "[Level N] took …", and clicking `[Level N]` opens the level;
      the chart gains a bar; the finished level's XP equals the level's requirement and the
      new level starts at the experience that spilled over.
- [ ] Hover and click the chart's bars; switch the chart metric (remembered after `/reload`).
- [ ] `/reload` and a quick relog keep the current level's time going without jumps.

## 6. Sharing

- [ ] Share dialog: checkboxes change the preview; Insert puts the text in the chat box.
- [ ] Post in party/guild: the message is plain text, without a link.
- [ ] Share a level from the Leveling tab: the message starts with "Level N".
- [ ] After using a secure slash command (e.g. `/cast`) following an insert, no "action
      blocked" messages appear (no taint from inserting text).

## 7. Performance

- [ ] `/sesh debug perf` with a large history: the 3-month range and the summary each take a
      few milliseconds.

## Results

_Nothing recorded yet._
