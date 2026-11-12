# Hearthlog

A World of Warcraft addon that records your character's journey locally: the path you walk, and the things that happen along it (levels, quests, deaths, kills, dungeons, party changes, gold, loot, gear, hearths, taxis, jumps, gz on dings). Nothing leaves your machine. The data feeds a map replay, a personal year-end recap, and a group recap built from friends' files.

Runs on WoW Forever, Classic Era and Retail from one codebase (three TOC files). Written for Forever before Forever could be tested, so every game call is guarded and a probe records which events the client actually fires.


## Install

**Option 1: WowUp (updates itself).** Open WowUp, go to *Get Addons*, click *Install from URL*, paste
`https://github.com/ericalle/hearthlog`, and pick the game client (Classic Era, WoW Forever, Retail).
Hearthlog then shows up in your addon list and updates like everything else.

**Option 2: zip file.** Download `Hearthlog-x.y.z.zip` from
https://github.com/ericalle/hearthlog/releases/latest and extract it into your client's AddOns folder, the same
way you'd install any addon by hand:

- Windows: `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\`
- Mac: `/Applications/World of Warcraft/_forever_/Interface/AddOns/`

(For Classic Era use `_classic_era_`, for Retail `_retail_`.) You should end up with
`Interface\AddOns\Hearthlog\Hearthlog.toc`. If the `Interface` or `AddOns` folder doesn't exist yet, launch the
game once and it will.

To update by hand, extract the new zip over the old folder. Your recordings live in `WTF\`, not in the addon folder,
so updating never loses anything.

Type `/hl` in game to confirm it's running. The addon tells you in chat when a guildmate or party member is on a
newer version, and `/hl who` shows who has it.

## Commands

| Command | What it does |
| --- | --- |
| `/hl` | Opens the Hearthlog window (Overview, Journey, Combat, Loot, Friends, Settings) |
| `/hl status` | The same numbers printed to chat |
| `/hl events [n]` | The last n events (default 10) |
| `/hl top <group> [n]` | Top entries of a tally: `items`, `used`, `spells`, `skills`, `buffs`, `emotes`, `chat`, `gold` |
| `/hl who` | Who in the guild and group has Hearthlog, and their versions |
| `/hl version` | Your version and the releases page |
| `/hl probe` | Probe status. `on`, `off`, `list` (top events seen) |
| `/hl pause` | Stop recording until typed again or relog |
| `/hl export` | The character's data as one compressed string you can copy |
| `/hl debug` | Print handler errors to chat |
| `/hl errors` | Errors the addon caught this session |
| `/hl diag` | Which client this is, which files loaded and which game functions exist |
| `/hl meter` | What the game's damage meter holds for the last fight (Forever and Retail) |
| `/hl talents` | Which talent functions this client has and what they return |
| `/hl logging` | Turns the game's own combat log file on, and on again at every login |
| `/hl reset confirm` | Erase this character's journey |

## Where the data is

`World of Warcraft/<client>/WTF/Account/<ACCOUNT>/SavedVariables/Hearthlog.lua`, written when you log out or `/reload`. That file is the thing to send for the group recap.

## Data layout (schema 1)

See the comment block at the top of `Hearthlog/Core.lua` for the table layout, `Track.lua` for the packed position format, and `Events.lua` for every event kind and its fields.

## Development

`install.sh [era|forever|retail|all]` copies the addon folder into a client on a Mac (`WOW_DIR` overrides the default
`/Applications/World of Warcraft`).

`tools/load.py` reads one or more `Hearthlog.lua` files into pandas (samples, events, sessions, plus counters and
tallies), converting map positions to world coordinates with the bounds the addon records. `tools/plot_path.py`
draws a character's path as a PNG, colored by movement mode with event markers. Both need `pip install lupa pandas
matplotlib`. Put files under `data/` (gitignored).

```sh
python3 tools/load.py data/Hearthlog.lua
python3 tools/plot_path.py data/Hearthlog.lua --zone "Elwynn Forest"
```

`tools/smoke_test.py` loads the addon into a mock of the WoW API (`tools/mock_wow.lua`) and runs a scripted session: walk, mount, quest, kill, level, die, party, dungeon, loot, hearth, taxi. It prints what was recorded and fails if a handler raises. Needs `pip install lupa`.

```sh
python3 tools/smoke_test.py
```

`HL_CLIENT=forever python3 tools/smoke_test.py` runs the same session against a mock of the Forever client, and `tools/regress_test.py` runs short scenarios for bugs found later. A Lua 5.1 syntax check of every file is part of it. Real testing is in game with BugSack and BugGrabber installed so Lua errors are visible.
