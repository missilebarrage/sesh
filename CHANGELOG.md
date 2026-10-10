# Changelog

## 0.2.0 — 2026-10-10

- Sharing posts plain text: messages no longer start with a `[Sesh #42]` link, and other
  players can't open your sessions or levels. The "Let other Sesh users open what I share"
  option is gone, and Sesh no longer sends addon messages.
- The level-up summary links the level itself: click `[Level 23]` to open it. Links only
  appear in Sesh's own messages to you.
- A new character with the name of a deleted one starts with a fresh history instead of the
  deleted character's. Sesh now remembers which character its data belongs to; data saved
  by 0.1.0 is kept unless it has seen a higher level than the character has.

## 0.1.0 — 2026-10-07

First version.

- Mini window: a compact panel with only the current session's numbers you choose, shown
  while the main window is closed, with adjustable size and background opacity. Click to open
  Sesh, Shift-drag to move, right-click to configure.
- Session tracking per character: raw gold, item value (Auctionator auction prices with a
  vendor-price fallback; soulbound items at vendor price; disenchanted or opened items count as
  used up where that happens, so their value is never counted twice), experience and levels, monsters slain, quests, zones, deaths,
  achievements and Legacy Points, with AFK time left out of hourly rates.
- Sessions continue across /reload and quick relogs; empty blips aren't kept.
- History by day, week, month, past 3 months and all time, with a full view of every session.
- Summary with all-time totals, an activity grid, personal records, streaks and top lists.
- Leveling tab: progress through the current level with rested experience and an estimate
  of when you'll level up, a chart comparing levels (time, XP per hour, gold, kills, quests,
  deaths), and each level's full stats. A summary of every finished level in chat.
- Dungeon runs with the bosses killed, for sessions and levels.
- Sharing in chat with clickable links that open the full session or level for other Sesh
  users.
- Options in Options > AddOns > Sesh, a data broker text and an addon compartment entry.
- Follows EllesmereUI's accent colour and font when it's installed.
