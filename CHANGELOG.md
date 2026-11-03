# Hearthlog changelog

## 0.3.1
- The window: `/hl` opens it instead of printing to chat. Overview, Journey, Combat, Loot and Settings tabs, with
  a scrolling log of what happened this session. Styled like the game's own dialogs, with a round portrait.
- Settings tab: chat checkboxes (login line, version notice, level-up summary), the Pause, Versions and Export
  buttons, and where the data file lives.
- Kills now include assists. A party member's kill is an assist when you had a hand in it: you or your pet hit
  the mob, it hit you, or you healed a group member while they were fighting it. Party kills you had no part in
  are only counted (`partyKills`). Killing blows are still kept separately.
- Combat tab: biggest hit given and taken show the ability and who; damage done, healing received, biggest heals;
  deaths show your level and the mob's; killed-by and hurt-most-by lists. Mob levels are recorded on kills and deaths.
- Duels only count when actually fought (the game fires its finished event for declined requests too). Declined duel
  requests and party invites are counted on the Overview.
- The hidden login-effect spell and Food/Drink no longer show up as casts.
- Quieter by default: the only chat line is the login line, and it can be turned off.
- Party: members whose names have not loaded yet are ignored; the roster is re-checked a few seconds after login
  and after each update, and the party you were already in at login is recorded.
- `/hl status` shows assists.
- `/hl export` gives one compressed string (`HL2:...`) instead of a raw dump, about a fifth the size. `tools/load.py`
  reads these strings as well as SavedVariables files.

## 0.3.0
- Version exchange over addon messages: login announces to the guild, grouping announces to the party, and anyone
  who hears a newer version gets one chat line pointing at the releases page.
- `/hl who` lists who has the addon and their versions. `/hl version` prints yours.
- GitHub release workflow (`.github/workflows/release.yml`): a `v*` tag builds the zip and `release.json` for WowUp.

## 0.2.1
- Eating and drinking are read off the buff bar (UNIT_AURA) instead of the combat log, which did not deliver the Food/Drink auras.
- "Used" ignores equips (IsEquippableItem) and anything right-clicked while a merchant, mailbox, trade, auction or bank window is open.
- Boat mode needs two consecutive transport-like ticks; single-tick flickers (jump landings) are gone.
- Taxi fares are captured directly, under the 1 silver event threshold too.
- Per-context gold totals in `tallies.gold` (vendor, repair, taxi, AH, mail, trade, quest, loot, trainer, bank, other); `/hl top gold`.
- Repairs get their own gold context via a hook on RepairAllItems.
- Zone changes during a flight carry `taxi=true` so overflights can be told from visits.
- /played lines: ChatFrameUtil.DisplayTimePlayed is silenced too (what Classic Era 1.15 uses).

## 0.2.0
- Transport (boat) detection no longer fires when you stop moving; it needs a transport-sized move with zero run speed.
- Teleports (hearth, portal, summon, corpse release) get a `T` marker in the path instead of a fake boat ride.
- Session end level comes from the addon's own level tracking (the client reported the old level at logout).
- Weapon and profession skill-ups no longer spam events: every skill-up updates `tallies.skills`, an event only every 25 points.
- XP from kills and quests rides on the `KILL` and `QUEST_DONE` events; `XP` events are only discoveries and oddities.
- New `DISCOVER` event from "Discovered: <area>".
- Tallies: every item looted (with counts), items used (bags, action bars, by name), spells cast, buffs from strangers, emotes performed, messages sent per channel.
- Counters: swings, swing misses, dodged, parried, shots, casts, crits done and taken, biggest hit done and taken, meals, drinks, seconds eating and drinking, teleports, discoveries, gray and white loot.
- `/hl top <group>` to look at a tally in game.
- Fixed: two-capture `match` results were lost behind `and` (skill parser, duel result).

## 0.1.0
- First recorder: path samples, sessions, events, counters, probe, export.
