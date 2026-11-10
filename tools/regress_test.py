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
local function mob(unit, name, id, n) M.units[unit] = { name = name, guid = "Creature-0-1-0-1-" .. id .. "-000" .. n, hostile = true }; return M.units[unit].guid end
local function plate(unit, name, id, n) local g = mob(unit, name, id, n); M.Fire("NAME_PLATE_UNIT_ADDED", unit); return g end
local function target(name, id, n) local g = mob("target", name, id, n); M.targetGUID = g; M.Fire("PLAYER_TARGET_CHANGED"); return g end
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
local a = target("Young Scavenger", 1508, 1)
M.Fire("PLAYER_REGEN_DISABLED")
M.Fire("UNIT_DIED", a); M.Fire("PARTY_KILL", ME, a); M.Advance(5)
local b = target("Young Scavenger", 1508, 2)
M.Fire("PARTY_KILL", ME, b); M.Fire("UNIT_DIED", b); M.Advance(5)
M.party = { "party1" }; M.units.party1 = { name = "Danwar", guid = DAN }
local x = plate("nameplate1", "Duskbat", 1512, 3)
M.Fire("PARTY_KILL", DAN, x); M.Advance(5)
return c.kills, c.grayKills, #kills()''')
assert (n_kills, gray, n_events) == (2, 2, 2), (n_kills, gray, n_events)

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
