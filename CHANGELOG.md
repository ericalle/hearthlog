# Hearthlog changelog

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
