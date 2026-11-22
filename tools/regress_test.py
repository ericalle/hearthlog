#!/usr/bin/env python3
"""Small scenarios, each on a freshly loaded addon, for bugs the long smoke test session did not catch.
Run after smoke_test.py. Requires: pip install lupa"""
import os, re, sys
from lupa import lua51 as L

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["Util.lua", "Compat.lua", "Core.lua", "Track.lua", "Events.lua", "Modern.lua", "Meter.lua", "Probe.lua",
         "Export.lua", "Version.lua", "UI.lua"]


def boot(forever=False, pre=None):
    rt = L.LuaRuntime(unpack_returned_tuples=True)
    src = re.sub(r"\nreturn M\s*$", "\n_G.MOCK = M\n", open(os.path.join(HERE, "mock_wow.lua")).read())
    rt.execute(src)
    M = rt.globals().MOCK
    if forever:
        M.ForeverMode()
    if pre:
        rt.execute("local M = MOCK\n" + pre)  # client differences that must exist before the addon loads
    ns = M.LoadAddon(os.path.join(HERE, "..", "Hearthlog"), rt.table(*FILES))
    rt.execute('local M = MOCK; M.Fire("ADDON_LOADED", "Hearthlog"); M.Fire("PLAYER_LOGIN"); '
               'M.Fire("PLAYER_ENTERING_WORLD", true, false); M.Advance(6)')
    return rt, ns


def run(forever, lua, pre=None):
    rt, ns = boot(forever, pre)
    out = rt.execute("local M, ns = MOCK, ...\n" + lua, ns)
    assert ns.errorCount == 0, "addon errors: %s" % list(ns.errors.values())
    return out


# Forever: three mobs dying a second apart are three kills, and the client is named correctly
kills, xp_kill, client = run(True, '''
M.units.target = { name = "Duskbat", guid = "Creature-0-1-0-1-1512-0001", hostile = true, threat = 1 }
M.targetGUID = "Creature-0-1-0-1-1512-0001"
M.Fire("PLAYER_TARGET_CHANGED"); M.Fire("PLAYER_REGEN_DISABLED")
for i = 1, 3 do M.xp = M.xp + 50; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1) end
M.Advance(2); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
return ns.char.counters.kills, ns.char.counters.xpKill, ns.char.meta.client''')
assert (kills, xp_kill, client) == (3, 150, "forever"), (kills, xp_kill, client)

# Forever: a buff from a party member counts even though the client flags it as cast by "a player"
buffs = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
M.Fire("UNIT_AURA", "player", { addedAuras = { { name = "Fortitude", isHelpful = true, isFromPlayerOrPlayerPet = true, sourceUnit = "party1" } } })
return ns.char.tallies.buffedBy.Danwar and ns.char.tallies.buffedBy.Danwar.n or 0''')
assert buffs == 1, buffs

# Forever: the meter's display names ("Zinther Unbroken") map back to plain names; two identical fights both count
done, healed_by, healed_to_self, group, fights = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
local function fight(id)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(9)
    M.meter = { dur = 9,
        [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 56, me = true, spells = { { id = 6603, total = 56, creature = "Duskbat" } } },
                { guid = "Player-1-000002", name = "Danwar the Bold", total = 40 } },
        [2] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 5, me = true, spells = { { id = 635, total = 5, creature = "Zinther Unbroken" } } },
                { guid = "Player-1-000002", name = "Danwar the Bold", total = 30, spells = { { id = 2050, total = 30, creature = "Zinther Unbroken" } } } } }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, id)
    M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
fight(1); fight(2)
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(2); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3) -- nothing new on the meter: no third read
local t, c = ns.char.tallies, ns.char.counters
return c.damageDone, t.healedBy.Danwar and t.healedBy.Danwar.d, t.healedTo["Zinther Unbroken"] or t.healedTo.Zinther,
    t.groupDmg.Danwar and t.groupDmg.Danwar.d, c.meterFights''')
assert (done, healed_by, healed_to_self, group, fights) == (112, 60, None, 80, 2), (done, healed_by, healed_to_self, group, fights)

# Forever: item links are colored by quality token, chat and mail carry surnames, and older lists get folded
loot, green, whisper, mail_to, roll_names = run(True, '''
M.Fire("CHAT_MSG_LOOT", "You receive loot: |cnIQ2:|Hitem:2140::::::::20:::::|h[Carving Knife]|h|rx2.")
M.Fire("CHAT_MSG_WHISPER", "hi", "Cup Kekw-CAMWOWUS2Realm4PvP")
M.Fire("CHAT_MSG_WHISPER_INFORM", "hey", "Cup Kekw")
SendMail("Vayden Ravenheart", "x", "")
local L, item = "|HlootHistory:237553411|h[Loot]|h: ", "|cnIQ2:|Hitem:2140::::::::20:::::|h[Carving Knife]|h|r"
M.Fire("CHAT_MSG_LOOT", L .. "You have selected Greed for: " .. item)
M.Fire("CHAT_MSG_LOOT", L .. "Greed Roll - 86 for " .. item .. " by Zinther Unbroken")
M.Fire("CHAT_MSG_LOOT", L .. "Greed Roll - 12 for " .. item .. " by Tonka Trukk")
M.Fire("CHAT_MSG_LOOT", L .. "You won: " .. item)
M.Fire("CHAT_MSG_LOOT", L .. "Tonka Trukk (Need - 93, Main-Spec) Won: " .. item)
local t, c = ns.char.tallies, ns.char.counters
local names = {}
for k in pairs(t.rolls) do names[#names + 1] = k end
table.sort(names)
local me, tonka, won = t.rolls.Zinther, t.rolls.Tonka, nil
for _, e in ipairs(ns.char.events) do if e.k == "WON" then won = e end end
assert(c.rolls == 1 and c.rollsWon == 1 and me.n == 1 and me.w == 1 and me.hi == 86, "my roll and win")
assert(tonka.n == 2 and tonka.w == 1 and tonka.hi == 93, "Tonka: two rolls, one win, best 93")
assert(won and won.n == "Carving Knife" and won.q == 2 and won.roll == 86, "WON event names the item and the roll")
return c.lootItems, c.lootGreen, t.whispers.Cup and (t.whispers.Cup.i * 10 + t.whispers.Cup.o), t.mailTo.Vayden and t.mailTo.Vayden.n, table.concat(names, ",")''')
assert (loot, green, whisper, mail_to, roll_names) == (2, 1, 11, 1, "Tonka,Zinther"), (loot, green, whisper, mail_to, roll_names)

rt, ns = boot(True)
folded = rt.execute('''
local M, ns = MOCK, ...
local t = ns.char.tallies
-- what 0.3.13 and earlier left behind: shifted roll fields, a WON named by an id, a guild entry per login
t.rolls["|cnIQ2:|Hitem:2632::::::::14:1486|h[Curved Dagger of Magic]|h|r"] = { n = 5, s = 1173557765, hi = 234711553 }
t.rolls["|cnIQ2:|Hitem:2632::::::::14:1486|h[Curved"] = { n = 5, s = 1, hi = 2 }
local ev = ns.char.events
ev[#ev + 1] = { t = 1, k = "WON", n = "237536769" }
for i = 1, 3 do ev[#ev + 1] = { t = 1 + i, k = "GUILD", n = "Bloodsabers" } end
ns.char.meta.cleaned, ns.char.meta.guild = nil, nil
_G.GetGuildInfo = function() return "Bloodsabers" end
_G.IsInGuild = function() return true end
t.groupDmg["Tonka Trukk"] = { n = 118, d = 88214, nm = "Tonka Trukk" }
t.groupDmg["Tonka"] = { n = 2, d = 100, nm = "Tonka" }
t.whispers["Krek Bank"] = { n = 1, o = 1, nm = "Krek Bank" }
t.healedTo["Zinther Unbroken"] = { n = 4, d = 40 }
t.rolls["237553411"] = { n = 0, w = 1 }
t.rolls["Zinther"] = { n = 0, w = 16 }
M.Fire("PLAYER_LOGIN")
M.Fire("PLAYER_GUILD_UPDATE", "player"); M.Fire("PLAYER_GUILD_UPDATE", "player")
local guilds, wonName, rollKeys = 0, "unset", 0
for _, e in ipairs(ns.char.events) do
    if e.k == "GUILD" then guilds = guilds + 1 end
    if e.k == "WON" then wonName = e.n end
end
for _ in pairs(t.rolls) do rollKeys = rollKeys + 1 end
assert(guilds == 1 and wonName == nil and rollKeys == 1, "cleanup: guilds=" .. guilds .. " won=" .. tostring(wonName) .. " rollKeys=" .. rollKeys)
M.Fire("TRANSMOG_COLLECTION_SOURCE_ADDED", 156468)
local look = ns.char.events[#ns.char.events]
assert(look.k == "LOOK" and look.n == "Frayed Robe" and look.i == 2491, "LOOK is named from the collection")
return t.groupDmg.Tonka.d * 1000 + t.groupDmg.Tonka.n, t.groupDmg["Tonka Trukk"], t.whispers.Krek and t.whispers.Krek.nm,
    t.healedTo["Zinther Unbroken"] or t.healedTo.Zinther, t.rolls["237553411"], t.rolls.Zinther.w''', ns)
assert tuple(folded) == (88314120, None, "Krek", None, None, 16), tuple(folded)

# ---- 0.3.15 ----
KILLS = """
local ME, DAN = "Player-1-000001", "Player-1-000002"
local function mob(unit, name, id, n, more)
    M.units[unit] = { name = name, guid = "Creature-0-1-0-1-" .. id .. "-000" .. n, hostile = true }
    for k, v in pairs(more or {}) do M.units[unit][k] = v end
    return M.units[unit].guid
end
local function plate(unit, name, id, n, more) local g = mob(unit, name, id, n, more); M.Fire("NAME_PLATE_UNIT_ADDED", unit); return g end
local function target(name, id, n, more) local g = mob("target", name, id, n, more); M.targetGUID = g; M.Fire("PLAYER_TARGET_CHANGED"); return g end
local function xp(v) M.xp = M.xp + v; M.Fire("PLAYER_XP_UPDATE") end
local function kills() local out = {} for _, e in ipairs(ns.char.events) do if e.k == "KILL" then out[#out + 1] = e end end return out end
local c = ns.char.counters
"""

# Forever: the mob that died is named from PARTY_KILL, not from whatever is targeted, and two at once stay two
names, n_kills, npc = run(True, KILLS + '''
target("Duskbat", 1512, 1)
local a = plate("nameplate1", "Rotting Dead", 1525, 2)
local b = plate("nameplate2", "Ravaged Corpse", 1526, 3)
M.Fire("PLAYER_REGEN_DISABLED")
M.Fire("PARTY_KILL", ME, a); M.Fire("UNIT_DIED", a); M.Fire("PARTY_KILL", ME, b); M.Fire("UNIT_DIED", b)
xp(40); xp(45); M.Advance(4)
local k = kills()
return k[1].n .. "," .. k[2].n, c.kills, k[1].npc''')
assert (names, n_kills, npc) == ("Rotting Dead,Ravaged Corpse", 2, 1525), (names, n_kills, npc)

# Forever, grouped: your own killing blow is a kill, a party member's is an assist, and both carry the mob's name
mine, assists, first, second, assist_flag = run(True, KILLS + '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = DAN }
local a = plate("nameplate1", "Rotting Dead", 1525, 2)
local b = plate("nameplate2", "Ravaged Corpse", 1526, 3)
M.Fire("PLAYER_REGEN_DISABLED")
M.Fire("PARTY_KILL", ME, a); xp(40); M.Advance(3)
M.Fire("PARTY_KILL", DAN, b); xp(20); M.Advance(3)
local k = kills()
return c.kills, c.assists, k[1].n, k[2].n, k[2].assist''')
assert (mine, assists, first, second, assist_flag) == (1, 1, "Rotting Dead", "Ravaged Corpse", True), (mine, assists, first, second, assist_flag)

# Forever: a killing blow with no XP (a gray mob) is one kill, whichever of the two death events comes first,
# and a party member's blow on a mob we never touched is nothing
n_kills, gray, n_events = run(True, KILLS + '''
local a = target("Young Scavenger", 1508, 1, { trivial = true })
M.Fire("PLAYER_REGEN_DISABLED")
M.Fire("UNIT_DIED", a); M.Fire("PARTY_KILL", ME, a); M.Advance(5)
local b = target("Young Scavenger", 1508, 2, { trivial = true })
M.Fire("PARTY_KILL", ME, b); M.Fire("UNIT_DIED", b); M.Advance(5)
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = DAN }
local x = plate("nameplate1", "Duskbat", 1512, 3)
M.Fire("PARTY_KILL", DAN, x); M.Advance(5)
return c.kills, c.grayKills, #kills()''')
assert (n_kills, gray, n_events) == (2, 2, 2), (n_kills, gray, n_events)

# ---- 0.3.21 ----
# Forever, grouped: the meter's session belongs to the group. Your own combat can stop and start while it runs
# on, and a second read shows totals since the session began. Only what is new counts, the second fight's own
# numbers are its own, and the next real session counts in full. The session is known by its id in the
# meter's list (0.3.23).
done, danwar, second, cont, foes, total3 = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
local function read(dur, mine, his, foes, id)
    M.meter = { id = id, dur = dur,
        [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = mine, me = true }, { guid = "Player-1-000002", name = "Danwar the Bold", total = his } },
        [10] = foes }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 0); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(31)
read(31, 1502, 6000, { { creatureID = 657, name = "Defias Pirate", total = 5378 }, { creatureID = 3947, name = "Goblin Shipbuilder", total = 1716 } }, "a")
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(19)
read(53, 2447, 9500, { { creatureID = 657, name = "Defias Pirate", total = 5378 }, { creatureID = 3947, name = "Goblin Shipbuilder", total = 3432 },
    { creatureID = 1732, name = "Defias Squallshaper", total = 1716 } }, "a")
local c, t = ns.char.counters, ns.char.tallies
local done, danwar = c.damageDone, t.groupDmg.Danwar.d
local fight
for _, e in ipairs(ns.char.events) do if e.k == "FIGHT" then fight = e end end
local names = {}
for _, f in ipairs(fight.foes) do names[#names + 1] = f.n .. " " .. f.d end
table.sort(names)
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(26)
read(26, 1570, 4000, { { creatureID = 657, name = "Defias Pirate", total = 3432 } }, "b")
return done, danwar, fight.done, fight.cont, table.concat(names, ", "), c.damageDone''')
assert (done, danwar, second, cont, foes, total3) == (2447, 9500, 945, True, "Defias Squallshaper 1716, Goblin Shipbuilder 1716", 4017), \
    (done, danwar, second, cont, foes, total3)

# The same on a client whose meter has no list of sessions: there a read is taken for the same session when the
# session is older than the time since the last read and nothing in it has gone down.
done, danwar, second, cont, foes, total3 = run(True, '''
C_DamageMeter.GetAvailableCombatSessions = nil
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
local function read(dur, mine, his, foes)
    M.meter = { dur = dur,
        [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = mine, me = true }, { guid = "Player-1-000002", name = "Danwar the Bold", total = his } },
        [10] = foes }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 0); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(31)
read(31, 1502, 6000, { { creatureID = 657, name = "Defias Pirate", total = 5378 }, { creatureID = 3947, name = "Goblin Shipbuilder", total = 1716 } })
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(19)
read(53, 2447, 9500, { { creatureID = 657, name = "Defias Pirate", total = 5378 }, { creatureID = 3947, name = "Goblin Shipbuilder", total = 3432 },
    { creatureID = 1732, name = "Defias Squallshaper", total = 1716 } })
local c, t = ns.char.counters, ns.char.tallies
local done, danwar = c.damageDone, t.groupDmg.Danwar.d
local fight
for _, e in ipairs(ns.char.events) do if e.k == "FIGHT" then fight = e end end
local names = {}
for _, f in ipairs(fight.foes) do names[#names + 1] = f.n .. " " .. f.d end
table.sort(names)
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(26)
read(26, 1570, 4000, { { creatureID = 657, name = "Defias Pirate", total = 3432 } })
return done, danwar, fight.done, fight.cont, table.concat(names, ", "), c.damageDone''')
assert (done, danwar, second, cont, foes, total3) == (2447, 9500, 945, True, "Defias Squallshaper 1716, Goblin Shipbuilder 1716", 4017), \
    (done, danwar, second, cont, foes, total3)

# Forever: kills in a dungeon are counted from the meter when you leave. Two pulls of pirates (one, then three),
# a boss that wipes the group once and then dies, a companion pack: 6 kills by the count, of which XP showed 2.
kills, by_xp, mobs, assists, line = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
M.inInstance, M.instanceName = true, "Deadmines"
M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(3)
local session = 0
local function pull(seconds, foes, xp)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(seconds)
    for i = 1, xp or 0 do M.xp = M.xp + 82; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1) end
    session = session + 1
    M.meter = { dur = seconds + (xp or 0),
        [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 400 + session, me = true }, { guid = "Player-1-000002", name = "Danwar the Bold", total = 900 } },
        [10] = foes }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 0); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(20)
end
local function pirates(d) return { creatureID = 657, name = "Defias Pirate", total = d, extra = { classification = "elite" } } end
pull(20, { pirates(1716) }, 1)
pull(40, { pirates(5274), { creatureID = 3450, name = "Defias Companion", total = 425 } }, 1)
M.Fire("ENCOUNTER_START", 2746, "Cookie", 1, 5)
pull(25, { { creatureID = 645, name = "Cookie", total = 900, extra = { classification = "elite" } } })
M.Fire("ENCOUNTER_END", 2746, "Cookie", 1, 5, 0)
M.Fire("ENCOUNTER_START", 2746, "Cookie", 1, 5)
pull(30, { { creatureID = 645, name = "Cookie", total = 3804, extra = { classification = "elite" } } })
M.Fire("ENCOUNTER_END", 2746, "Cookie", 1, 5, 1)
local before = ns.char.counters.assists
M.inInstance, M.instanceName = false, nil
M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(3)
local out
for _, e in ipairs(ns.char.events) do if e.k == "INST_OUT" then out = e end end
local mobs = {}
for n, k in pairs(out.mobs) do mobs[#mobs + 1] = n .. " " .. k end
table.sort(mobs)
ns.ToggleUI(); ns.ShowTab("combat"); M.Advance(3)
return out.kills, out.xpk, table.concat(mobs, ", "), ns.char.counters.assists - before, ns.EventLine and ns.EventLine(out) or ""''')
assert (kills, by_xp, mobs, assists) == (6, 2, "Cookie 1, Defias Companion 1, Defias Pirate 4", 4), (kills, by_xp, mobs, assists, line)

# Forever: inside a dungeon the game hides what died but reports every death. Those reports are the kill count
# of the run (7 here: the count by kind would have said 6, XP showed 2). A death that is not hidden is a
# player's (your own) and is no kill. The count survives a reload and is gone once the run is closed.
# (and its length is the whole run's, not the part since the reload)
kills, died, by_xp, named, assists, left = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
M.inInstance, M.instanceName = true, "Deadmines"
M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(8)
local session = 0
local function pull(seconds, foes, xp, deaths)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(seconds)
    for i = 1, deaths or 0 do M.Fire("UNIT_DIED", M.SECRET) end
    for i = 1, xp or 0 do M.xp = M.xp + 82; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1) end
    session = session + 1
    M.meter = { dur = seconds + (xp or 0),
        [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 400 + session, me = true }, { guid = "Player-1-000002", name = "Danwar the Bold", total = 900 } },
        [10] = foes }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 41 + session); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(20)
end
local function pirates(d) return { creatureID = 657, name = "Defias Pirate", total = d, extra = { classification = "elite" } } end
pull(20, { pirates(1716) }, 1, 1)
M.Fire("UNIT_DIED", "Player-1-000001") -- my own death is not hidden
M.Fire("PLAYER_ENTERING_WORLD", false, true); M.Advance(8) -- a reload inside
pull(40, { pirates(5274), { creatureID = 3450, name = "Defias Companion", total = 425 } }, 1, 5)
M.Fire("ENCOUNTER_START", 2746, "Cookie", 1, 5)
pull(30, { { creatureID = 645, name = "Cookie", total = 3804, extra = { classification = "elite" } } }, 0, 1)
M.Fire("ENCOUNTER_END", 2746, "Cookie", 1, 5, 1)
local before = ns.char.counters.assists
M.inInstance, M.instanceName = false, nil
M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(8)
local out
for _, e in ipairs(ns.char.events) do
    if e.k == "INST_OUT" then out = e end
end
local named = 0
for _, k in pairs(out.mobs) do named = named + k end
return out.kills, out.died, out.xpk, named, ns.char.counters.assists - before, tostring(ns.char.meta.died) .. (out.dur >= out.t - out.from - 1 and "" or " short")''')
assert (kills, died, by_xp, named, assists, left) == (7, 7, 2, 6, 5, "nil"), (kills, died, by_xp, named, assists, left)

# Forever: a meter session read in four stretches holds four pulls. Twelve elites of a kind in it used to fit
# nothing (the limit was six, for one pull) and were counted as one. And a recount of a saved run never lowers it.
first, again, assists = run(True, '''
local t = time() - 5000
local function fight(at, d, cont) return { k = "FIGHT", t = at, dur = 30, mdur = cont and 120 or 30, cont = cont or nil, party = { "Danwar:MAGE" }, done = 100,
    foes = { { id = 3853, n = "Shadowfang Moonwalker", c = "elite", d = d } } } end
local ev = ns.char.events
ev[#ev + 1] = { k = "INST_IN", t = t, n = "Shadowfang Keep", kind = "party" }
ev[#ev + 1] = fight(t + 100, 1716)                       -- one, alone: its health
ev[#ev + 1] = fight(t + 200, 3432); ev[#ev + 1] = fight(t + 240, 5148, true)
ev[#ev + 1] = fight(t + 280, 5148, true); ev[#ev + 1] = fight(t + 320, 6864, true) -- twelve over four stretches
local out = { k = "INST_OUT", t = t + 400, n = "Shadowfang Keep", dur = 400, kills = 0, deaths = 0 }
ev[#ev + 1] = out
local before = ns.char.counters.assists
ns.char.meta.runs = nil; M.Fire("PLAYER_LOGIN")
local first = out.kills
out.kills, out.mobs["Shadowfang Moonwalker"] = 20, 20     -- as if an earlier count had said more
ns.char.meta.runs = nil; M.Fire("PLAYER_LOGIN")
return first, out.kills, ns.char.counters.assists - before''')
assert (first, again, assists) == (13, 20, 13), (first, again, assists)

# ---- 0.3.23 ----
# Forever: the meter does not keep to your fights. Here the session read after the first fight ("a") runs on
# without you, a whole session ("b") comes and goes inside your second fight, and a third ("c") is on show
# when that fight ends. All three are read by their ids: what "a" gained, and "b" and "c" in full.
done2, healed2, cont, sn, share, total, danwar, foes = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
local function session(id, dur, mine, his, heal, foes)
    return { id = id, dur = dur,
        [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = mine, me = true }, { guid = "Player-1-000002", name = "Danwar the Bold", total = his } },
        [2] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = heal, me = true } },
        [10] = foes }
end
local function fight(seconds, m)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(seconds)
    M.meter = m
    M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
local function pirates(d) return { creatureID = 657, name = "Defias Pirate", total = d } end
fight(20, session("a", 20, 500, 1000, 300, { pirates(1716) }))
M.AddSession(session("a", 50, 500, 2500, 300, { pirates(3432) }))
M.AddSession(session("b", 40, 700, 900, 2500, { pirates(1716), { creatureID = 3450, name = "Defias Companion", total = 425 } }))
fight(49, session("c", 11, 100, 200, 357, { { creatureID = 645, name = "Cookie", total = 900 } }))
local f
for _, e in ipairs(ns.char.events) do if e.k == "FIGHT" then f = e end end
local names = {}
for _, x in ipairs(f.foes) do names[#names + 1] = x.n .. " " .. x.d end
return f.done, f.healed, f.cont, f.sn, f.share, ns.char.counters.damageDone, ns.char.tallies.groupDmg.Danwar.d, table.concat(names, ", ")''')
assert (done2, healed2, cont, sn, share, total, danwar) == (800, 2857, True, 3, 24, 1300, 3600), (done2, healed2, cont, sn, share, total, danwar)
assert foes == "Defias Pirate 3432, Cookie 900, Defias Companion 425", foes

# Forever: a reload must not read sessions a second time. Where the last read stopped is kept in the saved file:
# of four sessions in the list, the two up to that point stay unread, the one after it and the new one are read.
# At login there is nothing to go by (the list may hold another character's fights): the newest only.
after_reload, at_login = run(True, '''
local function session(id, mine) return { id = id, dur = 20, [0] = { { guid = "Player-1-000001", name = "Zinther", total = mine, me = true } } } end
local function fight(m)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(20)
    M.meter = m
    M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
M.AddSession(session("old1", 1000)); M.AddSession(session("old2", 2000))
fight(session("first", 30))
local at_login = ns.char.counters.damageDone
return 0, at_login''')
assert at_login == 30, at_login
after_reload = run(True, '''
local function session(id, mine) return { id = id, dur = 20, [0] = { { guid = "Player-1-000001", name = "Zinther", total = mine, me = true } } } end
M.AddSession(session("read1", 1000)); local stopped = M.AddSession(session("read2", 2000)); M.AddSession(session("missed", 400))
ns.char.meta.msid = stopped
M.Fire("PLAYER_ENTERING_WORLD", false, true); M.Advance(6) -- a reload keeps the mark
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(20)
M.meter = session("new", 30)
M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
return ns.char.counters.damageDone''')
assert after_reload == 430, after_reload

# Forever: an error while the meter is read is kept with the other errors (it used to vanish), and what was
# read of that session is not read again
noted, counted = run(True, '''
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(10)
M.meter = { dur = 10, [0] = { { guid = "Player-1-000001", name = "Zinther", total = 250, me = true, spells = { { id = 20271, total = 250 } } } } }
local real = ns.Tally
ns.Tally = function() error("boom") end
M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(12)
ns.Tally = real
local n = ns.errorCount
ns.errorCount, ns.errors = 0, {}
return n, ns.char.counters.damageDone''')
assert noted >= 1 and counted == 250, (noted, counted)

# ---- 0.3.24 ----
# A character whose realm name was missing at one login got a second record under "Name-". At the next login
# the two are joined: events and sessions in order of time, paths still beside their sessions, counts added,
# "largest ever" counters and best rolls kept as the larger, a skill's standing from the newer record.
SPLIT = '''
HearthlogDB = { chars = {
    ["Zinther-TestRealm"] = { meta = { class = "DRUID", race = "Tauren", created = 100, played = 500 },
        events = { { k = "ZONE", t = 100, n = "A" }, { k = "ZONE", t = 300, n = "C" } },
        sessions = { { t0 = 100, t1 = 150 }, { t0 = 300, t1 = 350 } }, pos = { { "a" }, { "c" } },
        counters = { kills = 5, maxHitDone = 40, miles = { f = 10 } },
        tallies = { items = { [2589] = { n = 2, nm = "Linen Cloth", q = 1 } }, skills = { Herbalism = { n = 1, nm = "Herbalism", v = 10 } },
            rolls = { Danwar = { n = 1, nm = "Danwar", hi = 80, s = 80 } } },
        gearSeen = { [10] = true } },
    ["Zinther-"] = { meta = { class = "DRUID", race = "Tauren", created = 200, played = 900, guild = "Bloodsabers" },
        events = { { k = "ZONE", t = 200, n = "B" }, { k = "ZONE", t = 400, n = "D" } },
        sessions = { { t0 = 200, t1 = 250 } }, pos = { { "b" } },
        counters = { kills = 3, maxHitDone = 55, miles = { f = 5 } },
        tallies = { items = { [2589] = { n = 3, nm = "Linen Cloth", q = 1 }, [4306] = { n = 1, nm = "Silk Cloth", q = 1 } },
            skills = { Herbalism = { n = 2, nm = "Herbalism", v = 25 } }, rolls = { Danwar = { n = 2, nm = "Danwar", hi = 60, s = 100 } } },
        gearSeen = { [11] = true } },
} }
'''
res = run(True, '''
local c = ns.char
local order = {}
for i = 1, 4 do order[i] = c.events[i].n end
local t = c.tallies
return ns.key, tostring(HearthlogDB.chars["Zinther-"]), table.concat(order), c.pos[1][1] .. c.pos[2][1] .. c.pos[3][1], #c.sessions, c.counters.kills, c.counters.maxHitDone,
    c.counters.miles.f, t.items[2589].n, t.items[2589].q, t.items[4306].n, t.skills.Herbalism.v, t.skills.Herbalism.n, t.rolls.Danwar.hi, t.rolls.Danwar.s,
    c.meta.created, c.meta.played, c.meta.guild, (c.gearSeen[10] and c.gearSeen[11]) and "both" or "no"''', pre=SPLIT)
assert tuple(res)[:4] == ("Zinther-TestRealm", "nil", "ABCD", "abc"), tuple(res)[:4]
assert tuple(res)[4:16] == (4, 8, 55, 15, 5, 1, 1, 25, 3, 80, 180, 100) and res[16] >= 900 and tuple(res)[17:] == ("Bloodsabers", "both"), tuple(res)[4:]

# The realm name missing at login: the one record under this name is used, no second one is started. A record
# of the same name that is another character's (another class) is left alone, and so is a stray one then.
key, bare, n = run(True, 'return ns.key, tostring(HearthlogDB.chars["Zinther-"]), #ns.char.events >= 1 and ns.char.events[1].k or "none"',
    pre='''GetNormalizedRealmName = function() return nil end
GetRealmName = function() return "" end
HearthlogDB = { chars = { ["Zinther-TestRealm"] = { meta = { class = "DRUID", race = "Tauren", realm = "Test Realm" }, events = { { k = "MARK", t = 5 } } } } }''')
assert (key, bare, n) == ("Zinther-TestRealm", "nil", "MARK"), (key, bare, n)
key, other, stray = run(True, 'return ns.key, #HearthlogDB.chars["Zinther-OtherRealm"].events, #HearthlogDB.chars["Zinther-"].events',
    pre='''HearthlogDB = { chars = {
    ["Zinther-OtherRealm"] = { meta = { class = "MAGE", race = "Troll" }, events = { { k = "MARK", t = 5 } } },
    ["Zinther-"] = { meta = { class = "MAGE", race = "Troll" }, events = { { k = "MARK", t = 6 }, { k = "MARK", t = 7 } } } } }''')
assert (key, other, stray) == ("Zinther-TestRealm", 1, 2), (key, other, stray)

# Forever: a target that dies while we fight it, with no killing blow of ours and no XP, is someone else's kill
# (a guard's, another player's). Our own blow on a mob that gives no XP is still a kill.
kills, events = run(True, '''
M.units.target = { name = "Wretched Zombie", guid = "Creature-0-1-0-1-1501-0001", hostile = true, threat = 1 }
M.targetGUID = "Creature-0-1-0-1-1501-0001"
M.Fire("PLAYER_TARGET_CHANGED"); M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(2)
M.Fire("UNIT_DIED", "Creature-0-1-0-1-1501-0001"); M.Advance(3)
local first = ns.char.counters.kills
M.units.target = { name = "Gray Rat", guid = "Creature-0-1-0-1-4075-0002", hostile = true, threat = 1, trivial = true }
M.targetGUID = "Creature-0-1-0-1-4075-0002"
M.Fire("PLAYER_TARGET_CHANGED"); M.Advance(1)
M.Fire("PARTY_KILL", "Player-1-000001", "Creature-0-1-0-1-4075-0002"); M.Fire("UNIT_DIED", "Creature-0-1-0-1-4075-0002"); M.Advance(3)
M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(2)
local n = 0
for _, e in ipairs(ns.char.events) do if e.k == "KILL" then n = n + 1 end end
return first .. ">" .. ns.char.counters.kills, n''')
assert (kills, events) == ("0>1", 1), (kills, events)

# ---- 0.3.25 ----
# /hl linktest: two copies measure how fast they can talk. Sending side: a hello, and once it is answered the
# batch goes out by whisper, a refused send (the game's throttle) is sent again, and the other side's report
# is printed and kept. Receiving side: answers the hello, counts what arrives and reports it.
sent, refused, got, kept, answer, report = run(True, '''
local n = 0
M.addonSendResult = function() n = n + 1; if n == 3 then return 3 end return 0 end -- the third send is refused once
ns.LinkTest("danwar 5 0.1")
local hello = M.sentAddon[#M.sentAddon]
local id = hello.msg:match("^H:(%d+)$")
M.Fire("CHAT_MSG_ADDON", "HLNK1", "A:" .. id .. ":0.3.25", "WHISPER", "Danwar-TestRealm"); M.Advance(3)
local batch, to = 0, nil
for _, m in ipairs(M.sentAddon) do
    if m.prefix == "HLNK1" and m.msg:sub(1, 2) == "T:" then batch = batch + 1; to = m.target .. "/" .. m.chan .. "/" .. #m.msg end
end
M.Fire("CHAT_MSG_ADDON", "HLNK1", "R:" .. id .. ":5:1000:1250", "WHISPER", "Danwar-TestRealm"); M.Advance(1)
local rec = HearthlogDB.linkTests[#HearthlogDB.linkTests]
-- and the other way round: someone tests us
M.addonSendResult = nil
M.Fire("CHAT_MSG_ADDON", "HLNK1", "H:77", "WHISPER", "Rhonrir-TestRealm")
local answer = M.sentAddon[#M.sentAddon].msg:match("^A:77:") and M.sentAddon[#M.sentAddon].target
for i = 1, 4 do M.Fire("CHAT_MSG_ADDON", "HLNK1", "T:77:" .. i .. ":4:" .. string.rep("x", 190), "WHISPER", "Rhonrir-TestRealm"); M.Advance(0.2) end
M.Advance(3)
local last = M.sentAddon[#M.sentAddon]
return batch .. " " .. to, rec.results, rec.got, rec.role .. " " .. rec.to .. " " .. rec.gotBytes, answer, last.msg:match("^(R:77:4:%d+):") .. " " .. last.target''')
assert (sent, got, kept, answer, report) == ("6 Danwar/WHISPER/200", 5, "send Danwar 1000", "Rhonrir-TestRealm", "R:77:4:796 Rhonrir-TestRealm"), (sent, refused, got, kept, answer, report)
assert "3 x1" in refused and "0 x5" in refused, refused

# Forever: chat the game hides (text, sender or both) is no error, your own messages are counted where they are
# sent, and a whisper counts too
errors, messages, chans = run(True, '''
M.Fire("CHAT_MSG_PARTY", M.SECRET, M.SECRET, "", "", M.SECRET)
M.Fire("CHAT_MSG_SKILL", M.SECRET)
M.Fire("CHAT_MSG_LOOT", M.SECRET, M.SECRET)
M.Fire("CHAT_MSG_SYSTEM", M.SECRET)
M.Fire("CHAT_MSG_WHISPER", M.SECRET, M.SECRET)
SendChatMessage("pull", "PARTY"); M.Advance(1)
SendChatMessage("omw", "WHISPER", nil, "Danwar"); M.Advance(1)
SendChatMessage("hello"); M.Advance(1)
M.Fire("CHAT_MSG_PARTY", "pull", "Zinther Unbroken") -- the line that comes back must not count again
local chans = {}
for k, v in pairs(ns.char.tallies.chat) do chans[#chans + 1] = k .. "=" .. v.n end
table.sort(chans)
return ns.errorCount, ns.char.counters.messages, table.concat(chans, " ")''')
assert (errors, messages, chans) == (0, 3, "party=1 say=1 whisper=1"), (errors, messages, chans)

for forever in (False, True):
    # The game sends the honorable-kill event twice for one kill
    honor, events = run(forever, '''
M.Fire("PLAYER_PVP_KILLS_CHANGED"); M.Fire("PLAYER_PVP_KILLS_CHANGED"); M.Advance(5)
M.Fire("PLAYER_PVP_KILLS_CHANGED"); M.Fire("PLAYER_PVP_KILLS_CHANGED")
local n = 0
for _, e in ipairs(ns.char.events) do if e.k == "PVP_KILL" then n = n + 1 end end
return ns.char.counters.honorKills, n''')
    assert (honor, events) == (2, 2 if forever else 0), (honor, events)

# Forever: a creature whose name has not loaded is "Unknown" to the game. It is kept by its id, never under that name.
named, has_id, kill = run(True, '''
M.inInstance = true
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(30)
M.xp = M.xp + 332; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1)
M.meter = { dur = 31, [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 300, me = true } },
    [10] = { { creatureID = 643, name = "Unknown", total = 3087 } } }
M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 0); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
local fight, kill
for _, e in ipairs(ns.char.events) do if e.k == "FIGHT" then fight = e end if e.k == "KILL" then kill = e end end
return fight.foes[1].n, fight.foes[1].id, kill.n''')
assert (named, has_id, kill) == (None, 643, None), (named, has_id, kill)

# ---- 0.3.20 ----
# Forever, grouped: the last mob of a pull dies as combat ends. It is an assist with an entry in the log, not a
# kill you had no part in, and when the fight had one kind of enemy it gets that name even though it is logged
# just after the fight is read.
assists, party_kills, names = run(True, '''
M.inInstance = true
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(30)
M.meter = { dur = 30,
    [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 300, me = true }, { guid = "Player-1-000002", name = "Danwar the Bold", total = 900 } },
    [10] = { { creatureID = 3887, name = "Baron Silverlaine", total = 4230 } } }
M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 1); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(0.3)
M.xp = M.xp + 131; M.Fire("PLAYER_XP_UPDATE"); M.Advance(3)
local names = {}
for _, e in ipairs(ns.char.events) do if e.k == "KILL" then names[#names + 1] = tostring(e.n) .. (e.assist and " (assist)" or "") end end
return ns.char.counters.assists, ns.char.counters.partyKills, table.concat(names, ",")''')
assert (assists, party_kills, names) == (1, 0, "Baron Silverlaine (assist)"), (assists, party_kills, names)

# Forever: a boss that turns a player on the group appears among the damage dealers and the player among the
# enemies. Neither is what it looks like, and dying to that player is not a PvP death.
group, share, foes, hit, death, pvp = run(True, '''
M.inInstance = true
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }; M.Fire("GROUP_ROSTER_UPDATE")
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(30)
M.meter = { dur = 30,
    [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 100, me = true },
            { guid = "Player-1-000002", name = "Danwar the Bold", total = 300 },
            { guid = "Creature-0-1-0-1-4275-0001", creatureID = 4275, name = "Archmage Arugal", total = 600 } },
    [9] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 1, me = true, recap = 90 } },
    [10] = { { creatureID = 4275, name = "Archmage Arugal", total = 400, spells = { { id = 1, total = 100, unit = "Zinther Unbroken" } } },
             { name = "Danwar the Bold", total = 55 } } }
M.recaps[90] = { { timestamp = 3, sourceName = "Danwar the Bold", sourceGUID = "Player-1-000002", spellName = "Cleave", amount = 38 } }
M.Fire("PLAYER_DEAD"); M.Advance(1)
M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 2); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(4)
local fight, death
for _, e in ipairs(ns.char.events) do if e.k == "FIGHT" then fight = e end if e.k == "DEATH" then death = e end end
local group = {}
for name in pairs(ns.char.tallies.groupDmg) do group[#group + 1] = name end
local hit = {}
for name in pairs(ns.char.tallies.damageTo) do hit[#hit + 1] = name end
return table.concat(group, ","), fight.share, #fight.foes, table.concat(hit, ","), death.by .. (death.friendly and " (friendly)" or ""), ns.char.counters.pvpDeaths''')
assert (group, share, foes, hit, death, pvp) == ("Danwar", 25, 1, "Archmage Arugal", "Danwar (friendly)", 0), (group, share, foes, hit, death, pvp)

for forever in (False, True):
    # Boss fights are logged by name, won or lost
    bosses, kills = run(forever, '''
M.Fire("ENCOUNTER_START", 1069, "Baron Silverlaine", 1, 5); M.Advance(35)
M.Fire("ENCOUNTER_END", 1069, "Baron Silverlaine", 1, 5, 1)
M.Fire("ENCOUNTER_START", 1073, "Archmage Arugal", 1, 5); M.Advance(100)
M.Fire("ENCOUNTER_END", 1073, "Archmage Arugal", 1, 5, 0)
local out = {}
for _, e in ipairs(ns.char.events) do if e.k == "BOSS" then out[#out + 1] = e.n .. ":" .. tostring(e.win) .. ":" .. tostring(e.dur) end end
return table.concat(out, ","), ns.char.counters.bossKills''')
    assert (bosses, kills) == ("Baron Silverlaine:true:35,Archmage Arugal:nil:100", 1), (bosses, kills)

    # An error the addon catches is kept in the saved file, counted, under the version that had it
    n, count = run(forever, '''
ns.On("PLAYER_STARTED_MOVING", function() error("boom") end)
M.Fire("PLAYER_STARTED_MOVING"); M.Fire("PLAYER_STARTED_MOVING")
local n, count = 0, 0
for key, rec in pairs(HearthlogDB.errors or {}) do
    if key:find(ns.VERSION, 1, true) == 1 and key:find("boom", 1, true) then n = n + 1; count = rec.n end
end
ns.errorCount, ns.errors = 0, {} -- the two errors were the point; the harness would stop on them
return n, count''')
    assert (n, count) == (1, 2), (n, count)

    # /hl logging turns the game's combat log file on, and keeps turning it on at login
    now, saved, at_login = run(forever, '''
for _, slash in pairs(SlashCmdList) do slash("logging") end
local now, saved = M.logging, HearthlogDB.settings.combatLog
M.logging = false
M.Fire("PLAYER_ENTERING_WORLD", true, false)
return now, saved, M.logging''')
    assert (now, saved, at_login) == (True, True, True), (now, saved, at_login)

# Forever: XP that cannot be read for a moment is not an error, and nothing is lost when it can be read again
errors, kills, xp = run(True, '''
M.Fire("PLAYER_REGEN_DISABLED")
local real = UnitXP
_G.UnitXP = function() return M.SECRET end
M.xp = M.xp + 40; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1)
_G.UnitXP = real
M.xp = M.xp + 60; M.Fire("PLAYER_XP_UPDATE"); M.Advance(2)
local n, last = 0, nil
for _, e in ipairs(ns.char.events) do if e.k == "KILL" then n = n + 1; last = e end end
return ns.errorCount, n, last.xp''')
assert (errors, kills, xp) == (0, 1, 100), (errors, kills, xp)

# ---- 0.3.19 ----
# Forever: a fight with damage taken and none dealt is still read, and two of them in a row both count
taken, hurt, fights_read = run(True, '''
local function runThrough(id, amount)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(26)
    M.meter = { dur = 26, [0] = {},
        [7] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = amount, me = true,
                  spells = { { id = 6603, total = amount, unit = "Vile Fin Oracle" } } } } }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 0); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
local before = ns.char.counters.meterFights
runThrough(0, 351); runThrough(0, 351)
local fight
for _, e in ipairs(ns.char.events) do if e.k == "FIGHT" then fight = e end end
return ns.char.counters.damageTaken, ns.char.tallies.hurtBy["Vile Fin Oracle"].d, ns.char.counters.meterFights - before''')
assert (taken, hurt, fights_read) == (702, 702, 2), (taken, hurt, fights_read)

# ---- 0.3.18 ----
# Inside an instance the game hides what you target and who died. The kills are still counted; the names come
# from the meter when the fight has been read, the fight keeps its list of enemies, and what was hidden is noted.
INSTANCE = '''
M.inInstance = true
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
M.Fire("GROUP_ROSTER_UPDATE")
M.units.target = { name = HIDDEN, hostile = true }; M.targetGUID = HIDDEN
M.Fire("PLAYER_TARGET_CHANGED")
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(8)
BLOWS
M.xp = M.xp + 40; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1)
M.xp = M.xp + 40; M.Fire("PLAYER_XP_UPDATE"); M.Advance(1)
M.meter = { dur = 10,
    [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 300, me = true, spells = { { id = 6603, total = 300 } } },
            { guid = "Player-1-000002", name = "Danwar the Bold", total = 500 } },
    [10] = { FOES } }
M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 3); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
local names, fight = {}, nil
for _, e in ipairs(ns.char.events) do
    if e.k == "KILL" then names[#names + 1] = tostring(e.n) .. ":" .. tostring(e.npc) end
    if e.k == "FIGHT" then fight = e end
end
local i = ns.char.meta.inst or {}
return table.concat(names, ","), fight.foes and #fight.foes, fight.foes and fight.foes[1].n, i.targetNameSecret, i.blowTargetSecret, i.foeName'''
ELEMENTAL = '{ creatureID = 11321, name = "Molten Elemental", total = 800, spells = { { id = 6603, total = 300, unit = "Zinther Unbroken" } } }'
SLIME = '{ creatureID = 11322, name = "Searing Blade Cultist", total = 200 }'
# Everything hidden, one kind of enemy: both kills take its name
out = run(True, INSTANCE.replace("HIDDEN", "M.SECRET").replace("BLOWS", 'M.Fire("PARTY_KILL", M.SECRET, M.SECRET); M.Fire("PARTY_KILL", M.SECRET, M.SECRET)').replace("FOES", ELEMENTAL))
assert tuple(out) == ("Molten Elemental:11321,Molten Elemental:11321", 1, "Molten Elemental", 1, 2, 1), tuple(out)
# Everything hidden, two kinds: the kills stay unnamed (which was which is not known) but the fight has both
out = run(True, INSTANCE.replace("HIDDEN", "M.SECRET").replace("BLOWS", "").replace("FOES", ELEMENTAL + ", " + SLIME))
assert tuple(out)[:3] == ("nil:nil,nil:nil", 2, "Molten Elemental"), tuple(out)
# The kill event readable, names not: each kill is named by its creature id
out = run(True, INSTANCE.replace("HIDDEN", "M.SECRET").replace("FOES", ELEMENTAL + ", " + SLIME).replace("BLOWS",
    'M.Fire("PARTY_KILL", "Player-1-000002", "Creature-0-1-0-1-11322-0001"); M.Fire("PARTY_KILL", "Player-1-000001", "Creature-0-1-0-1-11321-0002")'))
assert tuple(out)[:2] == ("Searing Blade Cultist:11322,Molten Elemental:11321", 2), tuple(out)

# Forever: a buff you put on someone counts once, however many unit names report it, and a spell learned is
# logged under the event's new name
given, friend, stranger, spells = run(True, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
M.units.target = { name = "Danwar", guid = "Player-1-000002" }
local might = { addedAuras = { { isHelpful = true, sourceUnit = "player", auraInstanceID = 5, spellId = 19740 } } }
M.Fire("UNIT_AURA", "target", might); M.Fire("UNIT_AURA", "party1", might)
M.Fire("UNIT_AURA", "party1", { addedAuras = { { isHelpful = true, sourceUnit = "party1", auraInstanceID = 6 } } }) -- his own buff
M.units.target = { name = "Passerby", guid = "Player-1-000009" }
M.Fire("UNIT_AURA", "target", { addedAuras = { { isHelpful = true, sourceUnit = "player", auraInstanceID = 7, spellId = 19740 } } })
M.Fire("LEARNED_SPELL_IN_SKILL_LINE", 19740, 2, false); M.Fire("LEARNED_SPELL_IN_TAB", 19740)
local t, spells = ns.char.tallies.buffedTo, 0
for _, e in ipairs(ns.char.events) do if e.k == "SPELL" then spells = spells + 1 end end
return t.Danwar.n, t.Danwar.f, t.Passerby.n .. ":" .. tostring(t.Passerby.f), spells''')
assert (given, friend, stranger, spells) == (1, 1, "1:nil", 1), (given, friend, stranger, spells)

# Forever: a death the recap explains carries the killer's level when that kind of mob has been seen
lvl = run(True, '''
M.units.nameplate1 = { name = "Rabid Dog", guid = "Creature-0-1-0-1-565-0007", hostile = true, level = 19 }
M.Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(5)
M.meter = { dur = 5, [0] = { { guid = "Player-1-000001", name = "Zinther", total = 10, me = true } },
    [9] = { { guid = "Player-1-000001", name = "Zinther", total = 1, me = true, recap = 81 } } }
M.recaps[81] = { { timestamp = 9, sourceName = "Rabid Dog", sourceGUID = "Creature-0-1-0-1-565-0007", spellName = "Bite", amount = 30 } }
M.Fire("PLAYER_DEAD"); M.Advance(1)
M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 4); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(4)
local d
for _, e in ipairs(ns.char.events) do if e.k == "DEATH" then d = e end end
return d.by .. ":" .. tostring(d.lvl)''')
assert lvl == "Rabid Dog:19", lvl

# ---- 0.3.17 ----
# Gear is logged the first time an item is worn, whatever the equip event's flag says. What an earlier level-up
# already recorded is not logged again, and neither is swapping back to something worn before.
VEST, AXE = '"|cff1eff00|Hitem:2345::::::::6:::::|h[Green Vest]|h|r"', '"|cffffffff|Hitem:3456::::::::6:::::|h[Plain Axe]|h|r"'
for forever in (False, True):
    n, names, base = run(forever, '''
-- as if this character had been recording before this version: no gear entries, the hat on record at level 5
ns.char.gearSeen = nil
for i = #ns.char.events, 1, -1 do if ns.char.events[i].k == "GEAR" then table.remove(ns.char.events, i) end end
tinsert(ns.char.events, { k = "LEVEL", v = 5, t = 1, gear = { [1] = 1234 } })
M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(8)
M.gear[5] = VEST; M.Fire("PLAYER_EQUIPMENT_CHANGED", 5, false); M.Advance(2)
M.gear[16] = AXE; M.Fire("UNIT_INVENTORY_CHANGED", "player"); M.Advance(2)
M.gear[16] = nil; M.Fire("PLAYER_EQUIPMENT_CHANGED", 16, true); M.Advance(2)
M.gear[16] = AXE; M.Fire("PLAYER_EQUIPMENT_CHANGED", 16, false); M.Advance(2)
local names, base = {}, false
for _, e in ipairs(ns.char.events) do
    if e.k == "GEAR" then names[#names + 1] = e.n; base = base or e.base == true end
end
return #names, table.concat(names, ","), base'''.replace("VEST", VEST).replace("AXE", AXE))
    assert (n, names, base) == (2, "Green Vest,Plain Axe", False), (n, names, base)
    # A character with nothing on record: what is worn when recording begins is the starting set
    n, base = run(forever, '''
M.Advance(8)
local n, base = 0, true
for _, e in ipairs(ns.char.events) do if e.k == "GEAR" then n = n + 1; base = base and e.base == true end end
return n, base''')
    assert (n, base) == (1, True), (n, base)

# ---- 0.3.16 ----
# Forever: no XP is not the same as gray. A mob someone else tagged and anything killed at the level cap count
# as kills without the gray mark; a mob the game calls trivial has it.
GRAY = KILLS + '''
M.level = LEVEL
M.Fire("PLAYER_REGEN_DISABLED")
local function blow(name, id, n, more) local g = plate("nameplate" .. n, name, id, n, more); M.Fire("PARTY_KILL", ME, g); M.Advance(4) end
blow("Rot Hide Brute", 1939, 1, { level = HIGH })
blow("Worg", 1765, 2, { level = LOW, trivial = true })
local marks = {}
for _, e in ipairs(kills()) do marks[#marks + 1] = e.gray and "gray" or "plain" end
return c.kills, c.grayKills, table.concat(marks, ",")'''
for level, high, low in ((20, 17, 10), (60, 58, 40)):
    code = GRAY.replace("LEVEL", str(level)).replace("HIGH", str(high)).replace("LOW", str(low))
    assert tuple(run(True, code)) == (2, 1, "plain,gray"), (level, tuple(run(True, code)))
# The same from levels alone, on a client that cannot be asked: 13 and below is gray at 20, 51 and below at 60
for level, high, low in ((20, 14, 13), (60, 52, 51)):
    code = GRAY.replace("LEVEL", str(level)).replace("HIGH", str(high)).replace("LOW", str(low)).replace(", trivial = true", "")
    assert tuple(run(True, code, pre="_G.UnitIsTrivial = nil")) == (2, 1, "plain,gray"), (level, tuple(run(True, code, pre="_G.UnitIsTrivial = nil")))

# Forever: a mob never looked at is named from another of its kind, or from the game's tooltip for it
by_kind, by_tip, no_blow = run(True, KILLS + '''
plate("nameplate1", "Rotting Dead", 1525, 2)
M.Fire("PLAYER_REGEN_DISABLED")
M.Fire("PARTY_KILL", ME, "Creature-0-1-0-1-1525-0009"); xp(40); M.Advance(3)
_G.C_TooltipInfo = { GetHyperlink = function(link) if link == "unit:Creature-0-1-0-1-1530-0001" then return { lines = { { leftText = "Wretched Zombie" } } } end end }
M.Fire("PARTY_KILL", ME, "Creature-0-1-0-1-1530-0001"); xp(40); M.Advance(3)
target("Duskbat", 1512, 1); xp(30); M.Advance(3) -- no blow reported: named from the target, as before
local k = kills()
return k[1].n, k[2].n, k[3].n''')
assert (by_kind, by_tip, no_blow) == ("Rotting Dead", "Wretched Zombie", "Duskbat"), (by_kind, by_tip, no_blow)

# Forever: the meter's rows for your own damage carry no target (as on the real client). Targets come from
# its enemy view: all of it when alone, your part when grouped.
solo_a, solo_b, grouped = run(True, '''
local function fight(id, group)
    M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(9)
    local dmg = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 300, me = true, spells = { { id = 6603, total = 300 } } } }
    local foes = { { guid = "Creature-0-1-0-1-1525-0002", creatureID = 1525, name = "Rotting Dead", total = 200 },
                   { guid = "Creature-0-1-0-1-1526-0003", creatureID = 1526, name = "Ravaged Corpse", total = 100 } }
    if group then
        dmg[2] = { guid = "Player-1-000002", name = "Danwar the Bold", total = 500 }
        foes = { { creatureID = 1530, name = "Wretched Zombie", total = 800, spells = {
            { id = 6603, total = 300, unit = "Zinther Unbroken" }, { id = 133, total = 500, unit = "Danwar the Bold" } } } }
    end
    M.meter = { dur = 9, [0] = dmg, [10] = foes }
    M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, id)
    M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
end
fight(1, false)
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
fight(2, true)
local t = ns.char.tallies.damageTo
return t["Rotting Dead"].d, t["Ravaged Corpse"].d, t["Wretched Zombie"].d''')
assert (solo_a, solo_b, grouped) == (200, 100, 300), (solo_a, solo_b, grouped)

# Forever: a field that stays secret after the fight neither breaks the read nor stops /hl meter
taken, printed_all, stopped, marked = run(True, '''
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(9)
M.meter = { dur = 9,
    [0] = { { guid = "Player-1-000001", name = "Zinther Unbroken", total = 300, me = true, spells = { { id = 6603, total = 300 } } } },
    [7] = { { guid = "Player-1-000001", total = 90, me = true, extra = { name = M.SECRET, sourceGUID = M.SECRET, amountPerSecond = M.SECRET },
              spells = { { id = 1, total = 90 } } } },
    [10] = { { guid = "Creature-0-1-0-1-1525-0002", creatureID = 1525, name = "Rotting Dead", total = 300 } } }
M.Fire("DAMAGE_METER_COMBAT_SESSION_UPDATED", 0, 5); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(3)
local from = #M.printed
for _, slash in pairs(SlashCmdList) do slash("meter") end
local text = table.concat(M.printed, "\\n", from + 1)
return ns.char.counters.damageTaken, text:find("EnemyDamageTaken: 1 sources", 1, true) ~= nil and text:find("row 1 of 1", 1, true) ~= nil,
    text:find("could not be printed", 1, true) ~= nil, text:find("name=SECRET", 1, true) ~= nil''')
assert (taken, printed_all, stopped, marked) == (90, True, False, True), (taken, printed_all, stopped, marked)

# The emote the game performs by itself when the map opens is not yours, and one counted earlier is taken back
for forever in (False, True):
    emotes, names = run(forever, '''
ns.char.tallies.emotes.read = { n = 2, nm = "read" }; ns.char.counters.emotes = 2
M.Fire("PLAYER_LOGIN")
DoEmote("READ", nil, true); DoEmote("WAVE"); M.Advance(1); DoEmote("WAVE")
local names = {}
for k in pairs(ns.char.tallies.emotes) do names[#names + 1] = k end
return ns.char.counters.emotes, table.concat(names, ",")''')
    assert (emotes, names) == (2, "wave"), (emotes, names)

# A Classic client that has both the combat log and the meter keeps using the log alone
has_meter, no_cleu = run(False, "return ns.HAS_METER, ns.NO_CLEU",
                         pre="_G.C_DamageMeter = { GetCombatSessionFromType = function() return { combatSources = {} } end }")
assert (has_meter, no_cleu) == (False, False), (has_meter, no_cleu)

# Trait clients: the first look sets the baseline, a point spent afterwards is a TALENT event, and a level-up
# carries the whole build by name
TRAITS = """
M.ranks = { [11] = 2, [12] = 0 }
_G.C_ClassTalents = { GetActiveConfigID = function() return 7 end }
_G.C_Traits = {
    GetConfigInfo = function(id) return { treeIDs = { 1 } } end,
    GetTreeNodes = function(tree) return { 11, 12 } end,
    GetNodeInfo = function(config, node) return { ranksPurchased = M.ranks[node], activeRank = M.ranks[node], activeEntry = { entryID = node * 10 } } end,
    GetEntryInfo = function(config, entry) return { definitionID = entry * 10 } end,
    GetDefinitionInfo = function(def) return { spellID = def == 1100 and 20101 or 20205 } end,
}
_G.C_Spell = { GetSpellName = function(id) return id == 20101 and "Benediction" or "Improved Judgement" end }
"""
talent_events, name, rank, at_level = run(True, '''
M.Fire("TRAIT_CONFIG_UPDATED", 7); M.Advance(2)
M.ranks[12] = 1; M.Fire("TRAIT_CONFIG_UPDATED", 7); M.Fire("TRAIT_CONFIG_UPDATED", 7); M.Advance(2)
M.level = 6; M.Fire("PLAYER_LEVEL_UP", 6); M.Advance(3)
local n, last, lvl = 0, nil, nil
for _, e in ipairs(ns.char.events) do
    if e.k == "TALENT" then n = n + 1; last = e end
    if e.k == "LEVEL" then lvl = e end
end
return n, last.n, last.v, lvl.talents''', pre=TRAITS)
assert (talent_events, name, rank, at_level) == (1, "Improved Judgement", 1, "Benediction 2/Improved Judgement 1"), (talent_events, name, rank, at_level)

for forever in (False, True):
    # A raid's roster churn sends the version to the group once, never to the guild again, and a question
    # asked in party chat is answered in party chat only
    group_sends, guild_sends, answers = run(forever, '''
M.Advance(20) -- the login announce has gone out
local before = #M.sentAddon
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
for i = 1, 40 do M.Fire("GROUP_ROSTER_UPDATE"); M.Advance(0.2) end
M.Advance(40)
local group, guild = 0, 0
for i = before + 1, #M.sentAddon do
    if M.sentAddon[i].chan == "GUILD" then guild = guild + 1 else group = group + 1 end
end
before = #M.sentAddon
M.Fire("CHAT_MSG_ADDON", "HLOG1", "Q", "PARTY", "Danwar")
local chans = {}
for i = before + 1, #M.sentAddon do chans[#chans + 1] = M.sentAddon[i].chan end
return group, guild, table.concat(chans, ",")''')
    assert (group_sends, guild_sends, answers) == (1, 0, "PARTY"), (group_sends, guild_sends, answers)

for forever in (False, True):
    # Played time on the second level-up of a session
    first, second, true_second = run(forever, '''
local start = M.clock
_G.RequestTimePlayed = function() M.Fire("TIME_PLAYED_MSG", 3600 + (M.clock - start), 600) end
M.Advance(1000); M.level = 6; M.Fire("PLAYER_LEVEL_UP", 6); M.Advance(1000)
local truth = 3600 + (M.clock - start)
M.level = 7; M.Fire("PLAYER_LEVEL_UP", 7); M.Advance(5)
local out = {}
for _, e in ipairs(ns.char.events) do if e.k == "LEVEL" then out[#out + 1] = e.played end end
return out[1], out[2], truth''')
    assert abs(second - true_second) <= 10, (first, second, true_second)

    # One join, three loading screens: one PARTY event
    n = run(forever, '''
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
M.Fire("GROUP_ROSTER_UPDATE"); M.Advance(5)
for i = 1, 3 do M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(6) end
local n = 0
for _, e in ipairs(ns.char.events) do if e.k == "PARTY" then n = n + 1 end end
return n''')
    assert n == 1, n

    # Gold stays "vendor" while the window is open, a sale after repairing is not "repair", and it ends on close
    vendor, repair_in, other = run(forever, '''
M.Fire("MERCHANT_SHOW"); M.Advance(30); M.money = M.money + 70; M.Fire("PLAYER_MONEY")
RepairAllItems(); M.money = M.money - 20; M.Fire("PLAYER_MONEY"); M.Advance(1); M.money = M.money + 5; M.Fire("PLAYER_MONEY")
M.Fire("MERCHANT_CLOSED"); M.Advance(30); M.money = M.money + 9; M.Fire("PLAYER_MONEY")
local g = ns.char.tallies.gold
return g.vendor.i, g.repair.i, g.other and g.other.i''')
    assert (vendor, repair_in, other) == (75, None, 9), (vendor, repair_in, other)

    # The gain that levels you is counted: 80 left on the old bar plus 30 into the new one
    xp = run(forever, '''
_G.UnitXPMax = function() return M.xpMax or 500 end
M.xp = 420; M.Fire("PLAYER_ENTERING_WORLD", false, false); M.Advance(6)
M.level = 6; M.Fire("PLAYER_LEVEL_UP", 6); M.xpMax = 900; M.xp = 30; M.Fire("PLAYER_XP_UPDATE"); M.Advance(2)
return ns.char.counters.xp''')
    assert xp == 110, xp

    # Paused means counters stop too
    fights, jumps = run(forever, '''
ns.paused = true
JumpOrAscendStart()
M.Fire("PLAYER_REGEN_DISABLED"); M.Advance(3); M.Fire("PLAYER_REGEN_ENABLED"); M.Advance(2)
return ns.char.counters.fights, ns.char.counters.jumps''')
    assert (fights, jumps) == (0, 0), (fights, jumps)

    # The settings tab does not build the export string
    built = run(forever, '''
local n, real = 0, ns.ExportString
ns.ExportString = function(...) n = n + 1; return real(...) end
ns.ToggleUI(); ns.ShowTab("settings"); M.Advance(10)
return n''')
    assert built == 0, built

print("regress OK")
