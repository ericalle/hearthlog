# Hearthlog changelog

## 0.3.10
- Boats, zeppelins and the tram are detected with IsPlayerMoving (carried while not moving yourself) instead of
  the speed value, which works on every client and no longer needs the secret speed on Forever.

## 0.3.9
- Forever keeps the player's movement speed secret; the sampler compared it every tick and errored every tick.
  Speed is now optional (the boat test falls back to distance). Aura update payloads and meter tables are
  checked for secrecy before being iterated.

## 0.3.8
- Fixes the "this addon has had a lot of errors" popup on Forever. The event probe's handler was the one piece of
  code not protected against errors; an event it could not describe (secret values) threw on every occurrence,
  and spell casts fire several such events. Every timer, ticker and hook is now guarded too, errors are kept
  in a short list instead of reaching the game, and `/hl errors` prints them.

## 0.3.7
- The event probe no longer keeps a sample of chat events (it kept the first line seen per chat event type).
  Existing samples are cleared on login.

## 0.3.6
- Util.lua was aborting during load on Forever at the client-detection line (the interface number read through
  `select` while addons load), which left the combat fallbacks off and the login line warning that Util was
  missing. The read is now guarded and cannot stop the file.

## 0.3.5
- On Forever the helpers in Compat.lua came up missing at runtime (the file did not load, cause unknown), which
  left kills and the meter read at zero with "attempt to call a nil value" errors. All shims now live in
  Util.lua, the first file; Compat.lua only reports whether it loaded. Each file marks itself loaded, the
  login line warns if any did not, and `/hl diag` prints client, files, helpers and API presence.

## 0.3.4
- Forever: kills are taken from XP gains in or right after combat, named from your last hostile target. The
  experience chat line turned out to be hidden from addons on that client (it arrives as a KString).
- Forever: the damage meter read now finds you by name and GUID as well as the isLocalPlayer flag, and a
  lone source while solo is taken as you. `/hl meter` prints what the game's meter holds right now, and
  `/hl debug` shows meter read errors.
- Appearance collection: each new appearance is counted and logged ("New appearance: Frayed Robe."), with
  the count on the Loot tab.

## 0.3.3
- WoW Forever support. Forever runs on the modern client (Mainline family, interface 16001), not the Classic
  one, so the addon now ships a `Hearthlog_Camelot.toc` (Forever's internal name) and the Mainline TOC lists
  16001. Moved APIs (C_Item, C_UnitAuras, C_CurrencyInfo) are used when present.
- Modern clients give addons no combat log, so on Forever and Retail the combat side is rebuilt from what
  remains. Kills come from the experience chat line (a group kill is an assist when the meter saw you damage
  that creature), hits and crits from UNIT_COMBAT, the killer on a death is guessed from your target, PvP
  kills from the honor line, buffs from group members from the aura list.
- The game's own damage meter (C_DamageMeter) is read after every fight on those clients: damage done and
  healing done by ability and by target, who healed you, damage taken by attacker, interrupts, dispels,
  absorbs, overkill, and each group member's damage and healing per fight. Grouped fights log your share of
  the group's damage. Still unavailable there: swings and misses, killing blow vs assist, world damage, pet
  stats, who buffed you outside your group. The Combat tab says so.
- Both clients now tally damage by ability and by target, and count interrupts and dispels. The Friends tab
  lists damage and healing by your group members.

## 0.3.2
- Friends tab: whispers per person (counts only, never the text), who healed you and who you healed, who
  resurrected you, who buffed you, players you killed and players who killed you.
- PvP: killing blows on players, deaths to players, honorable kills. Player kills stay out of the mob kill count.
- Damage from the world itself (falling, drowning, lava, fire, fatigue) is tallied; deaths to it read "a fall".
- Red-text mishaps counted by message ("Inventory is full.", "Spell is not ready yet.") on the Combat tab.
- Vendor purchases and sales by item, on the Loot tab.
- Hearthstone binds are logged ("Home is now Goldshire.").
- Level-ups record gold on hand, total time played and talent points per tree alongside the gear snapshot.
- Screenshots counted.
- Loot rolls: every roll and win per player (luckiest rollers on the Friends tab); your wins are logged with the roll.
- Trades: who, what changed hands and gold each way, logged on completion.
- Mail: items taken from the inbox by sender, mail you sent by recipient with item and gold counts.
- Auction house: bids, buyouts and gold spent by item, posts by item, sales and gold earned (read off the
  "Auction successful" mail). Classic auction house only.
- Buffs you gave to other players. Buffs each way are split into party and guild versus strangers.
- Hunter and warlock pets: pet deaths and pet damage.
- Gz is still counted but no longer shown on the Overview.
- Window is a little taller so the Overview fits.

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
