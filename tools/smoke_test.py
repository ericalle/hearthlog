#!/usr/bin/env python3
"""Loads Hearthlog into a mock WoW API and runs a scripted session.
Prints the addon's chat output and a summary of what got recorded. Exits
non-zero if any handler raised. Requires: pip install lupa"""
import os, sys
from lupa import lua51 as L

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "Hearthlog")
FILES = ["Util.lua", "Core.lua", "Track.lua", "Events.lua", "Probe.lua", "Export.lua", "Version.lua"]

rt = L.LuaRuntime(unpack_returned_tuples=True)
import re
mock_src = re.sub(r"\nreturn M\s*$", "\n_G.MOCK = M\n", open(os.path.join(HERE, "mock_wow.lua")).read())
rt.execute(mock_src)
M = rt.globals().MOCK
ns = M.LoadAddon(ADDON, rt.table(*FILES))

script = rt.execute(r'''
local M, ns = MOCK, ...
local function fire(...) M.Fire(...) end
fire("ADDON_LOADED", "Hearthlog")
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD", true, false)
ns.debug = true -- handler errors print to chat; the Python side fails the run on them
M.Advance(5)

-- Walk north for 20 seconds, then stand still 30s, then walk again
for i = 1, 10 do M.wy = M.wy + 14; M.my = M.my + 0.01; M.Advance(2) end
M.Advance(30)
for i = 1, 5 do M.wx = M.wx + 14; M.mx = M.mx + 0.01; M.Advance(2) end

-- Mount and ride
M.mounted = true
for i = 1, 5 do M.wx = M.wx + 28; M.mx = M.mx + 0.02; M.Advance(2) end
M.mounted = false

-- Quest accept, kill, xp, turn in
fire("QUEST_ACCEPTED", 3, 777)
M.cleu = { 0, "PARTY_KILL", false, "Player-1-000001", "Zinther", 0, 0, "Creature-0-1-0-1-2955-0001", "Plainstrider", 0, 0 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.xp = M.xp + 50
fire("PLAYER_XP_UPDATE")
fire("QUEST_TURNED_IN", 777, 300, 1500)
M.xp = M.xp + 300
fire("PLAYER_XP_UPDATE")
M.money = M.money + 1500
fire("PLAYER_MONEY")

-- Level up with a gz
M.level = 6
fire("PLAYER_LEVEL_UP", 6)
fire("CHAT_MSG_GUILD", "gz!", "Reidoo")
fire("CHAT_MSG_GUILD", "what are you doing", "Tinga")

-- Take damage and die, release, get resurrected
fire("PLAYER_REGEN_DISABLED")
M.cleu = { 0, "SWING_DAMAGE", false, "Creature-0-1-0-1-3566-0002", "Bristleback Quilboar", 0, 0, "Player-1-000001", "Zinther", 0, 0, 120 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.Advance(25)
fire("PLAYER_REGEN_ENABLED")
M.dead = true
fire("PLAYER_DEAD")
M.ghost = true
fire("PLAYER_ALIVE")
M.Advance(40)
fire("RESURRECT_REQUEST", "Meredith")
M.dead, M.ghost = false, false
fire("PLAYER_UNGHOST")

-- Party forms, enter a dungeon (positions hidden), leave
M.party = { "party1" }
M.units.party1 = { name = "Reidoo", guid = "Player-1-000002" }
fire("GROUP_ROSTER_UPDATE")
M.inInstance, M.instanceName, M.hidden = true, "Ragefire Chasm", true
fire("PLAYER_ENTERING_WORLD", false, false)
M.Advance(10)
M.inInstance, M.instanceName, M.hidden = false, nil, false
fire("PLAYER_ENTERING_WORLD", false, false)
M.Advance(5)

-- Loot, gear, hearth, taxi
fire("CHAT_MSG_LOOT", "You receive loot: |cff0070dd|Hitem:5555::::::::6:::::|h[Blue Thing]|h|r.")
fire("PLAYER_EQUIPMENT_CHANGED", 1, true)
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 8690)
fire("TAXIMAP_OPENED")
M.money = M.money - 500
fire("PLAYER_MONEY")
M.onTaxi = true
M.Advance(4)
M.onTaxi = false
M.zone = "The Barrens"
M.Advance(4)
fire("ZONE_CHANGED_NEW_AREA")
JumpOrAscendStart(); JumpOrAscendStart()

-- Loot of everything, skills, discovery, spells, swings, food, item use, emotes, chat
fire("CHAT_MSG_LOOT", "You receive loot: |cff9d9d9d|Hitem:755::::::::1:::::|h[Broken Tooth]|h|r.")
fire("CHAT_MSG_LOOT", "You receive loot: |cffffffff|Hitem:2589::::::::1:::::|h[Linen Cloth]|h|rx3.")
fire("CHAT_MSG_SKILL", "Your skill in Two-Handed Maces has increased to 24.")
fire("CHAT_MSG_SKILL", "Your skill in Two-Handed Maces has increased to 25.")
fire("UI_INFO_MESSAGE", 396, "Discovered: Northshire Abbey")
M.xp = M.xp + 25
fire("PLAYER_XP_UPDATE")
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 635)
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-3", 635)
M.cleu = { 0, "SWING_DAMAGE", false, "Player-1-000001", "Zinther", 0, 0, "Creature-0-1-0-1-6-0003", "Kobold Vermin", 0, 0, 14, 0, 1, 0, 0, 0, true }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.cleu = { 0, "SWING_MISSED", false, "Player-1-000001", "Zinther", 0, 0, "Creature-0-1-0-1-6-0003", "Kobold Vermin", 0, 0, "DODGE" }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.buffs = { "Food" }
fire("UNIT_AURA", "player")
M.Advance(18)
M.buffs = {}
fire("UNIT_AURA", "player")
M.cleu = { 0, "SPELL_AURA_APPLIED", false, "Player-1-000099", "Stranger", 0, 0, "Player-1-000001", "Zinther", 0, 0, 1243, "Power Word: Fortitude", 2, "BUFF" }
fire("COMBAT_LOG_EVENT_UNFILTERED")
C_Container.UseContainerItem(0, 1)   -- Tough Jerky: a use
C_Container.UseContainerItem(0, 2)   -- Ragged Cloak: an equip, not a use
MerchantFrame.shown = true
C_Container.UseContainerItem(0, 1)   -- a sale, not a use
MerchantFrame.shown = false
UseAction(5)
RepairAllItems()
M.money = M.money - 37
fire("PLAYER_MONEY")
fire("CHAT_MSG_TEXT_EMOTE", "Zinther dances.", "Zinther")
fire("CHAT_MSG_SAY", "hello", "Zinther")
fire("CHAT_MSG_SAY", "hi back", "Reidoo")

-- Version exchange: a friend on a newer build announces, we get nudged once
M.Advance(10)
fire("CHAT_MSG_ADDON", "HLOG1", "V:9.9.9", "GUILD", "Reidoo-TestRealm")
fire("CHAT_MSG_ADDON", "HLOG1", "V:9.9.9", "GUILD", "Reidoo-TestRealm")
fire("CHAT_MSG_ADDON", "HLOG1", "Q", "GUILD", "Tinga-TestRealm")
SlashCmdList.HEARTHLOG("who")
fire("CHAT_MSG_ADDON", "HLOG1", "A:0.1.0", "GUILD", "Tinga-TestRealm")
M.Advance(3)

-- Slash commands
SlashCmdList.HEARTHLOG("status")
SlashCmdList.HEARTHLOG("top items")
SlashCmdList.HEARTHLOG("top used")
SlashCmdList.HEARTHLOG("top spells")
SlashCmdList.HEARTHLOG("top gold")
SlashCmdList.HEARTHLOG("events 30")
SlashCmdList.HEARTHLOG("probe")
SlashCmdList.HEARTHLOG("export")
fire("PLAYER_LOGOUT")

local char = HearthlogDB.chars["Zinther-TestRealm"]
local kinds = {}
for _, e in ipairs(char.events) do kinds[e.k] = (kinds[e.k] or 0) + 1 end
return char, kinds, #ns.ExportString()
''', ns)
char, kinds, export_len = script
errors = [line for line in M.printed.values() if "handler error" in line]
if errors:
    print("\nHANDLER ERRORS:")
    for e in errors: print(" ", e)
    sys.exit(1)
print("\n=== recorded ===")
print("sessions:", len(char.sessions), "session1 played:", char.sessions[1].played, "t0/t1:", char.sessions[1].t0, char.sessions[1].t1)
print("pos chunks:", len(char.pos[1]))
for i in range(1, len(char.pos[1]) + 1):
    print("  chunk", i, ":", char.pos[1][i][:200], "..." if len(char.pos[1][i]) > 200 else "")
print("event kinds:", dict(kinds.items()))
c = char.counters
print("counters: kills", c.kills, "deaths", c.deaths, "quests", c.questsDone, "levels", c.levels, "jumps", c.jumps,
      "goldIn", c.goldIn, "goldOut", c.goldOut, "xp", c.xp, "gz", c.gz, "hearths", c.hearths, "taxis", c.taxis, "taxiGold", c.taxiGold)
print("miles:", dict(c.miles.items()))
print("maps:", {k: dict(v.items()) for k, v in rt.globals().HearthlogDB.maps.items()})
print("export bytes:", export_len)
t = char.tallies
print("tallies:", {g: {k: dict(v.items()) for k, v in t[g].items()} for g in ["items", "used", "spells", "skills", "buffs", "emotes", "chat", "gold"]})
leaked = [l for l in M.printed.values() if "LEAKED" in l]
nudges = [l for l in M.printed.values() if "is out" in l]
assert len(nudges) == 1, "version nudge should print exactly once"
assert any(m.msg.startswith("V:") for m in M.sentAddon.values()), "no version announce sent"
assert any(m.msg.startswith("A:") for m in M.sentAddon.values()), "no answer to Q sent"
assert t["used"][117].n == 1 and 1372 not in t["used"], "used filter broken"
assert c.meals == 1 and c.foodSeconds == 18, "food tracking broken"
assert t["gold"]["repair"].o == 37, "repair gold tally broken"
print("extra counters: swings", c.swings, "misses", c.swingMisses, "dodged", c.dodged, "casts", c.casts, "maxHitDone", c.maxHitDone,
      "crits", c.critsDone, "meals", c.meals, "foodSeconds", c.foodSeconds, "strangerBuffs", c.strangerBuffs, "discoveries", c.discoveries,
      "lootItems", c.lootItems, "emotes", c.emotes, "messages", c.messages, "teleports", c.teleports)
