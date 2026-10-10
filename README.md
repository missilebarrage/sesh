# Sesh

Session and leveling stats for **World of Warcraft: Forever**. Sesh records every play
session of every character — from login to logout — and shows what it was worth: gold, the
value of the items you picked up, experience, monsters slain, quests, dungeon runs, zones and
more. It also keeps the same stats for every level: how long each level took and what you did
in it. Look back by day, week, month or all time, compare your levels on a chart, see your
best sessions and streaks on a summary page with an activity grid, and post the numbers of a
session or a level in chat.

## Features

- **Mini window** — a small panel with just the numbers you pick (session time, gold, gold
  per hour, XP per hour, time to level, level progress, kills and more) and nothing else; its
  background can be faded out completely. It shows whenever the full window is closed: click
  it to open Sesh, Shift-drag it to move it, right-click it to choose its numbers or hide it.
- **Current session at a glance** — gold earned and gold per hour, experience and XP per hour
  (with time to level), duration, monsters slain, quests and zones, plus lists of every item,
  monster, quest and zone with icons.
- **Item value** — every item you acquire is valued at its auction house price from
  [Auctionator](https://www.curseforge.com/wow/addons/auctionator), or its vendor price when
  there is no auction price. Without Auctionator, vendor prices are used.
- **History** — Today, This week, This month, Past 3 months and All time, each with totals and
  the list of sessions. Open any session to see it in full, share it or delete it.
- **Leveling** — your progress through the current level (with rested experience and when
  you'll level up), a chart comparing your levels by time, XP per hour, gold, kills, quests or
  deaths, and every level's full stats: time played, experience, gold, monsters, quests,
  dungeon runs, deaths and zones. When you level up, Sesh sums up the level in chat (only
  you see it).
- **Dungeon runs** — each visit to a dungeon with the bosses killed and how long it took.
- **Summary** — all-time totals, a GitHub-style activity grid coloured by gold, XP or time
  played, personal records, daily streaks and your top items, monsters and zones.
- **Sharing** — post a session or a level to chat as one message, with the numbers you
  choose.
- **Fits your UI** — a flat, minimal look inspired by EllesmereUI; when EllesmereUI is
  installed, Sesh follows its accent colour and font.
- **Light** — event-driven with no polling, virtualized lists, and compact storage that keeps
  years of history small.

## How the numbers are counted

- **Gold earned** = raw gold + item value. It's meant as "what did this session bring in",
  not accounting: spending is never subtracted.
- **Raw gold** is money you loot and get from quests. Money that arrives while a merchant,
  mailbox, trade, auction house or bank window is open isn't counted: it's a transfer or the
  sale of items whose value was already counted.
- **Items** are what you loot and receive (for example quest rewards). Crafted items and
  purchases aren't counted. Items you can trade are worth their auction price (or their vendor
  price when there is none); soulbound items can only go to a vendor, so they're worth their
  vendor price.
- **Nothing is counted twice.** Disenchanting an item or opening a container (a clam, a
  lockbox) counts what you get like any loot, and counts the item as *used up*: its value comes
  off in the session where that happens. So a disenchanting session the next morning (or on an
  alt you mailed the items to) shows what the dust is worth minus what the items were worth,
  and the items' value is never counted twice. Item value is what you acquired minus what you
  used up, so it can be negative when you disenchant something worth more than its dust.
  Selling to a vendor isn't counted: the item was counted when you got it.
- **Hourly rates** leave out AFK time (you can change this).
- **Monsters slain** counts killing blows by you and your group; critters don't count. In some
  instances the game hides which monster died; those kills still count, as "Unidentified".
- A **session** runs from login to logout. Logging back in on the same character within a
  few minutes continues it (configurable), so a disconnect doesn't split a dungeon run.
- A **level's time** is the time you played at that level, over all sessions. The experience
  that finishes a level counts toward it; whatever spills over counts toward the next one.
  Levels start being tracked when Sesh is installed: a level it saw only part of is marked
  "partly tracked" with how far into the level it started. Level stats are kept apart from
  History: deleting a single session doesn't change them.
- A **dungeon run** lasts from entering a dungeon until you've been out of it for 15 minutes,
  so a corpse run after a wipe doesn't split it. It counts once a boss dies or after 5 minutes
  inside. The game doesn't say when a dungeon is "complete", so runs show the bosses killed.
- **History belongs to its character.** A new character with the name of a deleted one gets
  the deleted character's saved data from the game; Sesh notices and starts it fresh.

## Commands

| Command | |
| --- | --- |
| `/sesh` | Open or close the window |
| `/sesh mini` | Turn the mini window on or off |
| `/sesh share` | Share the current session |
| `/sesh history` | Open History |
| `/sesh leveling` | Open Leveling |
| `/sesh summary` | Open the Summary |
| `/sesh options` | Open the options |
| `/sesh new` | End the current session and start a new one |
| `/sesh debug` | Diagnostics (counts and capabilities only) |

Options are in **Options > AddOns > Sesh**. Sesh also appears in the addon compartment on the
minimap and, if you use a data-bar addon, as a data text.

## Privacy

Everything is stored locally in your saved variables, and Sesh never sends anything on its
own. Sharing puts a message in your chat box; you choose where it goes.

## Development

Requirements: bash, curl, gcc/make and Python 3 (for unzipping). Everything else is pinned
and installed into the git-ignored `.tools/` folder.

```sh
scripts/bootstrap.sh   # Lua 5.1.5, luacheck and StyLua
scripts/test.sh        # lint, tests (in two time zones) and the distribution check
scripts/install.sh     # copy Sesh/ into your AddOns folder ($SESH_ADDONS_DIR or .tools/addons-path)
scripts/package.sh     # build a zip for manual installation
```

- `Sesh/` is the addon; only this folder ships. `tests/` runs the addon in a sandbox against a
  fake game API (`tests/harness/`). `docs/API-NOTES.md` records the verified client facts the
  code relies on; `docs/VERIFICATION.md` is the in-game checklist.
- Code is formatted with StyLua and must pass luacheck. Every bug fix gets a regression test.
- Releases: tag `vX.Y.Z` and push; the GitHub workflow packages with the BigWigs packager and
  uploads to CurseForge (needs the `CF_API_KEY` secret and `## X-Curse-Project-ID` in the TOC).

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Blizzard Entertainment or EllesmereUI.
