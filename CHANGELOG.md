# Hearthlog changelog

## 0.3.19
Checked against the game's own combat log for one evening: 11 of 11 kills with the right names, and damage
done, damage taken and healing matched the log to the point in every fight that could be compared.
- A fight you ran through without hitting back was skipped entirely, so the damage you took in it was
  never counted (351 of the evening's 1,732). The read stopped when the meter had no damage dealt.
- Known limit, not fixed: the game's meter only covers combat. A heal cast after the fight ends, or a
  poison still ticking, is in the combat log but not in the meter, so it is not counted here either.

## 0.3.18
Found by checking every kind of entry against a real Forever data file, not just the ones that looked wrong.
- Dungeons on Forever: none of the 197 kills from two dungeon nights has a name, a level or a creature id,
  while every group kill outside is named. Inside an instance the game hides what you are targeting. The
  meter still works there, so when a fight has been read its list of enemies names the kills from that
  fight: by creature id when the kill event gave one, and otherwise when the fight had a single kind of
  enemy. Group fights also keep that list (name, creature id, damage taken, your part), which is the only
  record of what a dungeon pull was and shows which fights were the bosses.
- What the game hides inside an instance is counted in the saved file (`meta.inst`), so the next dungeon
  run answers it without guessing.
- Forever: learning a spell was never logged. The event has a new name on the modern client.
- Forever: buffs you give were never counted, only buffs you received. They are read from the aura list of
  group members and of your target.
- Forever: a death the recap explains now carries the killer's level when that kind of mob has been seen.

## 0.3.17
- Putting on a new piece of gear was never logged on Forever: 52 different items worn over 21 levels and
  not one gear entry. The equip event's second argument was read as "the slot now holds an item", which
  it does not reliably mean. The event is no longer trusted for anything: when equipment changes the worn
  slots are read, and an item is logged the first time it is worn. Nothing is lost from before, since
  every level-up already carries the full set that was worn, and those items are not logged a second time.

## 0.3.16
- Forever: a kill was marked gray whenever it gave no XP. That is also true of a mob someone else tagged,
  and at the level cap it would have been true of every kill. Gray now means what the game means by it:
  the game is asked when the mob is seen, with the level rule as the fallback. Kills that give no XP
  count exactly as before, they are just no longer all called gray.

## 0.3.15
Found by reading a real Forever data file after five days of play.
- Before 0.3.14, roll lines on Forever were read with the fields shifted, which left item links and history
  ids in the roll list as if they were players. They are removed at login, before names are folded.
- The log repeated "joined guild" on most logins. The guild is remembered between sessions now, and the
  repeats already in the log are removed once, along with roll wins that were named by a history id.
- New appearances are named from the collection itself. The chat line never matched (0 of 178 had a name).
- People who left the group before a fight was read are still filed under their first name.
- Forever: kills are named from the game's own kill event, which says who landed the blow and on which mob.
  Until now the name came from whatever you had targeted, so in a group about a quarter of kills had no
  name at all (197 of 751). Mobs are remembered from targets, mouseover and nameplates so the event can be
  turned into a name, and a mob never looked at is named from another of its kind.
- Forever: your own killing blow in a group is a kill again and a party member's is an assist, the way it
  works on Classic Era. A killing blow that gives no XP (a gray mob) counts without having to be targeted.
- Emotes were never counted, on any client. Your own emote arrives in chat as "You burst into dance.",
  which has no name in it to match. The emote call itself is counted now, under its command word. "read"
  is left out, because the game performs it for you when you open the map.
- Forever: the meter gives no target for your own damage. "Most damaged" is read from its enemy view
  instead, and "Hurt most by" from a second field the meter has for names. Both work now. "Healed you"
  and "you healed" are still empty: the meter's healing rows do not say who was healed, at least for a
  heal on yourself. `/hl meter` prints one row of each view with every field, and fields the game keeps
  secret after the fight are shown as SECRET.
- Talents on Forever and Retail (the old talent functions do not exist there): each point spent is logged,
  and a level-up carries the whole build by name. `/hl talents` shows which talent functions the client
  has and what they return.
- Auction house: buying a stackable item was counted when the price was requested, bought or not. It is
  counted on confirmation now, with what it cost.
- The version message to the group went out on every roster change, which in a raid is constant, and to
  the guild each time as well. The group hears it when it grows, at most once every 30 seconds, and the
  guild once at login. A `/hl who` asked in party chat is answered in party chat only.
- The game's meter has reached the Classic clients too. It is only read where the combat log is gone, so
  a client with both does not count everything twice.
- `tools/load.py` added each standing-still pause to the clock twice, which pushed every later point of a
  session late. Each row now also says how long you stood still before it (`idle`).

## 0.3.14
- The right-hand pane is laid out in two real columns: the count, date or time on the left, the text on the
  right, wrapping under itself. Numbers of different lengths no longer push the text around.
- Removed the "About this client" note from the Combat tab.
- Forever: looted items were never counted. Item links there are colored by a quality token, not a hex
  color, and the loot line did not match. Loot by quality and Items looted work from this version on.
- Forever: chat, whispers and mail carry surnames ("Cup Kekw") while trades and the party list give "Cup".
  Everything is kept under the first name now, and lists made before this version are folded together at
  login. This also fixes counting your own chat messages there.
- Loot rolls are matched on the wording of the chat line with the "[Loot]:" link stripped. On Forever that
  link carries a history id, which had been taken for the winner's name, and the rolls themselves were
  never matched. Rolls, wins and best roll per player work there now, including the one-line
  "(Need - 93, Main-Spec) Won:" form.

## 0.3.13
Fixes from a read-through of the whole addon. No new features.
- Forever: kills less than three seconds apart were dropped (three quick kills recorded as one).
- Forever: the game's meter uses display names ("Talenel Unbroken"). They are mapped back to plain character
  names, so "healed you" works and group members appear under one name everywhere.
- Forever: buffs from party members were never counted.
- Forever: two fights in a row with the same length and damage could be read as one. The meter's own
  session id is part of the check now.
- Forever characters were labeled `era` in the data. Corrected at next login.
- Gold by source stays "vendor", "mail", "auction house", "trainer" or "bank" for as long as that window is
  open, not just its first 8 seconds.
- Played time on a level-up was wrong from the second level-up of a session onward.
- The experience from whatever makes you level is counted.
- A loading screen while grouped no longer logs everyone as joining again.
- Pause stops the counters as well as the log.
- The Settings tab estimated the data size by building the whole export every two seconds. It now adds up
  what is stored, once a minute.
- release.json was invalid since 0.3.3 (several interface numbers where one belongs). Fixed and checked in
  the release workflow.
- `/hl meter` also prints healing rows, the meter's session id and how many fights were read.
- `tools/regress_test.py`: one small scenario per bug above, each on a freshly loaded addon.

## 0.3.12
- Forever: a kill is confirmed by UNIT_DIED on the mob you had targeted, then named by the XP that follows.
  A mob you tagged that gives no XP (gray) now counts too; one you only had targeted does not.
- Forever: the death recap, when the client lets addons read it, replaces the guessed killer on a death
  with the real one and the ability that did it.
- From the meter: avoidable damage taken, and who died in your groups each fight.
- Reputation is read as standing changes off the faction list on every client (the chat line is hidden on
  modern ones): totals per faction on the Journey tab, and a log line when a standing improves.
- Mounts, pets, toys and achievements earned are counted and logged; shown with appearances under
  "Collected" on the Loot tab.
- Forever uses the modern auction house, which the old hooks never saw. Posts, commodity purchases and bids
  are tracked there now; gold spent comes from the auction house gold total.
- `/hl meter` also prints each source's maxAmount.

## 0.3.11
- Forever: PvP kills count again. The honor chat line is hidden from addons there, so each honorable kill
  (PLAYER_PVP_KILLS_CHANGED) is a kill, named from the hostile player you last had targeted.
- Forever: the Combat tab drops the rows this client cannot fill (swings, misses, dodges, biggest hits,
  crits) and shows damage by ability instead; Friends hides "Buffs given" when there is nothing to show.
- Forever: healing received is read from the meter (who healed you) when the client fires no per-hit events.

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
