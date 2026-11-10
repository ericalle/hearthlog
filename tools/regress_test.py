#!/usr/bin/env python3
"""Small scenarios, each on a freshly loaded addon, for bugs the long smoke test session did not catch.
Run after smoke_test.py. Requires: pip install lupa"""
import os, re, sys
from lupa import lua51 as L

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ["Util.lua", "Compat.lua", "Core.lua", "Track.lua", "Events.lua", "Modern.lua", "Meter.lua", "Probe.lua",
         "Export.lua", "Version.lua", "UI.lua"]


def boot(forever=False):
    rt = L.LuaRuntime(unpack_returned_tuples=True)
    src = re.sub(r"\nreturn M\s*$", "\n_G.MOCK = M\n", open(os.path.join(HERE, "mock_wow.lua")).read())
    rt.execute(src)
    M = rt.globals().MOCK
    if forever:
        M.ForeverMode()
    ns = M.LoadAddon(os.path.join(HERE, "..", "Hearthlog"), rt.table(*FILES))
    rt.execute('local M = MOCK; M.Fire("ADDON_LOADED", "Hearthlog"); M.Fire("PLAYER_LOGIN"); '
               'M.Fire("PLAYER_ENTERING_WORLD", true, false); M.Advance(6)')
    return rt, ns


def run(forever, lua):
    rt, ns = boot(forever)
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
t.groupDmg["Tonka Trukk"] = { n = 118, d = 88214, nm = "Tonka Trukk" }
t.groupDmg["Tonka"] = { n = 2, d = 100, nm = "Tonka" }
t.whispers["Krek Bank"] = { n = 1, o = 1, nm = "Krek Bank" }
t.healedTo["Zinther Unbroken"] = { n = 4, d = 40 }
t.rolls["237553411"] = { n = 0, w = 1 }
t.rolls["Zinther"] = { n = 0, w = 16 }
M.Fire("PLAYER_LOGIN")
return t.groupDmg.Tonka.d * 1000 + t.groupDmg.Tonka.n, t.groupDmg["Tonka Trukk"], t.whispers.Krek and t.whispers.Krek.nm,
    t.healedTo["Zinther Unbroken"] or t.healedTo.Zinther, t.rolls["237553411"], t.rolls.Zinther.w''', ns)
assert tuple(folded) == (88314120, None, "Krek", None, None, 16), tuple(folded)

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
