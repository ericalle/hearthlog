#!/usr/bin/env python3
"""Loads Hearthlog into a mock WoW API and runs a scripted session.
Prints the addon's chat output and a summary of what got recorded. Exits
non-zero if any handler raised. Requires: pip install lupa"""
import os, sys
from lupa import lua51 as L

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "Hearthlog")
FILES = ["Util.lua", "Compat.lua", "Core.lua", "Track.lua", "Events.lua", "Modern.lua", "Meter.lua", "Probe.lua", "Export.lua", "Version.lua", "UI.lua"]
FOREVER = os.environ.get("HL_CLIENT") == "forever"

rt = L.LuaRuntime(unpack_returned_tuples=True)
import re
mock_src = re.sub(r"\nreturn M\s*$", "\n_G.MOCK = M\n", open(os.path.join(HERE, "mock_wow.lua")).read())
rt.execute(mock_src)
M = rt.globals().MOCK
if FOREVER:
    M.ForeverMode()
    print("=== Forever client mode: modern API, no combat log ===")
ns = M.LoadAddon(ADDON, rt.table(*FILES))
assert bool(ns.NO_CLEU) == FOREVER, "client detection"

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
M.gear[5] = "|cff1eff00|Hitem:2345::::::::6:::::|h[Green Vest]|h|r" -- a new chest piece goes on
fire("PLAYER_EQUIPMENT_CHANGED", 5, false)
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

-- A duel request we decline, then a duel we fight and win, then a party invite
fire("DUEL_REQUESTED", "Novadasavage")
fire("DUEL_FINISHED")
M.Advance(5)
fire("DUEL_REQUESTED", "Novadasavage")
M.Advance(20)
fire("CHAT_MSG_SYSTEM", "Zinther has defeated Novadasavage in a duel")
fire("DUEL_FINISHED")
M.Advance(5)
fire("PARTY_INVITE_REQUEST", "Danwar")

-- 0.3.2 hooks: falling damage, rez, whispers, bind, red text, screenshot, vendor buy and sell, pvp
M.cleu = { 0, "ENVIRONMENTAL_DAMAGE", false, nil, nil, 0, 0, "Player-1-000001", "Zinther", 0x511, 0, "FALLING", 37, 0, 1, 0, 0, 0, false }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.cleu = { 0, "SPELL_RESURRECT", false, "Player-1-000002", "Danwar", 0x512, 0, "Player-1-000001", "Zinther", 0x511, 0, 2006, "Resurrection", 2 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.cleu = { 0, "SPELL_HEAL", false, "Player-1-000002", "Danwar-Atiesh", 0x512, 0, "Player-1-000001", "Zinther", 0x511, 0, 2050, "Lesser Heal", 2, 60, 10, false }
fire("COMBAT_LOG_EVENT_UNFILTERED")
fire("CHAT_MSG_WHISPER", "hey", "Danwar-Atiesh")
fire("CHAT_MSG_WHISPER", "u there", "Danwar-Atiesh")
fire("CHAT_MSG_WHISPER_INFORM", "yeah", "Danwar-Atiesh")
fire("CHAT_MSG_SYSTEM", "Goldshire is now your home.")
fire("UI_ERROR_MESSAGE", 1, "Inventory is full.")
fire("UI_ERROR_MESSAGE", 2, "Inventory is full.")
fire("UI_ERROR_MESSAGE", 3, "Spell is not ready yet.")
fire("SCREENSHOT_SUCCEEDED")
M.merchant[1] = "|cffffffff|Hitem:159::::::::1:::::|h[Refreshing Spring Water]|h|r"
BuyMerchantItem(1, 5)
MerchantFrame.shown = true
M.bags[0] = M.bags[0] or {}
M.bags[0][9] = "|cff9d9d9d|Hitem:755::::::::1:::::|h[Broken Tooth]|h|r"
C_Container.UseContainerItem(0, 9)
MerchantFrame.shown = false
M.cleu = { 0, "PARTY_KILL", false, "Player-1-000001", "Zinther", 0x511, 0, "Player-2-000077", "Stabbyjoe-Whitemane", 0x548, 0 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.cleu = { 0, "SWING_DAMAGE", false, "Player-2-000077", "Stabbyjoe-Whitemane", 0x548, 0, "Player-1-000001", "Zinther", 0x511, 0, 99 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.dead = true
fire("PLAYER_DEAD")
M.dead = false
fire("PLAYER_UNGHOST")
fire("PLAYER_ALIVE")

-- Medium set: buff given, loot rolls, a trade, mail in and out, auction house, pet death
M.cleu = { 0, "SPELL_AURA_APPLIED", false, "Player-1-000001", "Zinther", 0x511, 0, "Player-1-000002", "Danwar", 0x512, 0, 20217, "Blessing of Kings", 2, "BUFF" }
fire("COMBAT_LOG_EVENT_UNFILTERED")
local blue = "|cff0070dd|Hitem:5555::::::::1:::::|h[Blue Thing]|h|r"
fire("CHAT_MSG_LOOT", "Need Roll - 97 for " .. blue .. " by you")
fire("CHAT_MSG_LOOT", "Need Roll - 12 for " .. blue .. " by Danwar")
fire("CHAT_MSG_LOOT", "You won: " .. blue)
fire("CHAT_MSG_LOOT", "Greed Roll - 50 for " .. blue .. " by Danwar")
fire("CHAT_MSG_LOOT", "Danwar won: " .. blue)
M.units.NPC = { name = "Danwar-Atiesh", guid = "Player-1-000002" }
M.trade.gave = { "|cffffffff|Hitem:2589::::::::1:::::|h[Linen Cloth]|h|r" }
M.trade.got = { blue, "|cffffffff|Hitem:159::::::::1:::::|h[Refreshing Spring Water]|h|r" }
M.trade.goldIn = 250
fire("TRADE_SHOW")
fire("TRADE_ACCEPT_UPDATE", 1, 1)
fire("CHAT_MSG_SYSTEM", "Trade complete.")
fire("TRADE_CLOSED")
M.inbox[1] = { sender = "Danwar", subject = "stuff", money = 0, items = { blue } }
M.inbox[2] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1200, items = {} }
TakeInboxItem(1, 1)
AutoLootMailItem(2)
TakeInboxMoney(2)              -- same mail, second hook: must not count twice
fire("MAIL_INBOX_UPDATE")      -- mail gone, next one from the same lot slides into slot 2
M.inbox[2] = { sender = "Auction House", subject = "Auction successful: Linen Cloth", money = 1200, items = {} }
TakeInboxMoney(2)              -- identical mail, new take: must count
M.sendMail.items = { blue }
M.sendMail.money = 500
SendMail("Danwar", "hi", "")
M.auctions[3] = { name = "Light Leather", count = 5, quality = 1, minBid = 100, buyout = 400, itemId = 2318 }
PlaceAuctionBid("list", 3, 400)
PlaceAuctionBid("list", 3, 100)
M.sellItem = { name = "Linen Cloth", count = 20, quality = 1 }
PostAuction(50, 90, 2, 20, 2)
M.units.pet = { name = "Growl", guid = "Pet-0-1-0-1-5-0009" }
M.cleu = { 0, "UNIT_DIED", false, nil, nil, 0, 0, "Pet-0-1-0-1-5-0009", "Growl", 0x1111, 0 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.units.pet = nil

-- Reputation read as standing deltas, an achievement
M.factions[1].v = 350
fire("UPDATE_FACTION")
M.Advance(2)
M.factions[1].v, M.factions[1].s = 3100, 5
fire("UPDATE_FACTION")
M.Advance(2)
fire("ACHIEVEMENT_EARNED", 6)

-- Forever: the combat log never fired above, so feed the modern replacements
if M.forever then
    M.party = {} -- damage to the target only counts as yours while solo
    M.units.target = { name = "Kobold Vermin", guid = "Creature-0-1-0-1-6-0003", hostile = true }
    M.targetGUID = "Creature-0-1-0-1-6-0003"
    fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_REGEN_DISABLED")
    fire("UNIT_COMBAT", "target", "WOUND", "CRITICAL", 31, 1)
    fire("UNIT_COMBAT", "target", "DODGE", "", 0, 1)
    fire("UNIT_COMBAT", "player", "WOUND", "", 12, 1)
    fire("UNIT_COMBAT", "player", "HEAL", "", 40, 2)
    fire("UNIT_DIED", "Creature-0-1-0-1-6-0003") -- the target dies: confirmed, then named by the XP that follows
    M.xp = M.xp + 45
    fire("PLAYER_XP_UPDATE")      -- an XP gain in combat with a hostile target: a kill
    M.Advance(1)
    fire("PLAYER_REGEN_ENABLED")
    M.Advance(3)
    -- A gray mob we tagged: it dies, no XP follows, still a kill
    M.units.target = { name = "Gray Rat", guid = "Creature-0-1-0-1-4075-0030", hostile = true, threat = 1, trivial = true }
    M.targetGUID = "Creature-0-1-0-1-4075-0030"
    fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_REGEN_DISABLED")
    M.units.target.threat = nil   -- the threat list empties as it dies
    fire("UNIT_THREAT_LIST_UPDATE", "player")
    fire("UNIT_DIED", "Creature-0-1-0-1-4075-0030")
    M.Advance(2)
    fire("PLAYER_REGEN_ENABLED")
    M.Advance(1)
    -- A mob someone else killed that we only had targeted: not ours
    M.units.target = { name = "Bystander Boar", guid = "Creature-0-1-0-1-7-0031", hostile = true }
    M.targetGUID = "Creature-0-1-0-1-7-0031"
    fire("PLAYER_TARGET_CHANGED")
    fire("UNIT_DIED", "Creature-0-1-0-1-7-0031")
    M.Advance(2)
    M.units.target = { name = "Kobold Vermin", guid = "Creature-0-1-0-1-6-0003", hostile = true }
    M.targetGUID = "Creature-0-1-0-1-6-0003"
    fire("PLAYER_TARGET_CHANGED")
    fire("NEW_MOUNT_ADDED", 12)
    M.bags[0] = M.bags[0] or {}
    M.bags[0][3] = "|cffffffff|Hitem:2589::::::::1:::::|h[Linen Cloth]|h|r"
    C_AuctionHouse.PostCommodity({ bag = 0, slot = 3 }, 2, 20, 5)
    C_AuctionHouse.StartCommoditiesPurchase(2318, 5) -- a price check, not a purchase
    fire("COMMODITY_PRICE_UPDATED", 40, 200)
    C_AuctionHouse.ConfirmCommoditiesPurchase(2318, 5)
    C_AuctionHouse.PlaceBid(123, 250)
    M.units.target = { name = "Stabbyjoe-Whitemane", guid = "Player-2-000077", hostile = true }
    M.targetGUID = "Player-2-000077"
    fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_PVP_KILLS_CHANGED") -- an honorable kill: the hostile player we had targeted
    M.units.target = { name = "Kobold Vermin", guid = "Creature-0-1-0-1-6-0003", hostile = true }
    M.targetGUID = "Creature-0-1-0-1-6-0003"
    fire("PLAYER_TARGET_CHANGED")
    fire("RESURRECT_REQUEST", "Danwar")
    fire("UNIT_AURA", "player", { addedAuras = { { name = "Power Word: Fortitude", isHelpful = true, sourceUnit = "party1" } } })
    M.units.party1 = { name = "Danwar", guid = "Player-1-000002" }
    fire("UNIT_AURA", "player", { addedAuras = { { name = "Arcane Intellect", isHelpful = true, sourceUnit = "party1" } } })
    fire("TRANSMOG_COLLECTION_SOURCE_ADDED", 12345)
    fire("CHAT_MSG_SYSTEM", "|cff9d9d9d|Hitem:2491::::::::1:::::|h[Frayed Robe]|h|r has been added to your appearance collection.")
    M.units.target = { name = "Mangy Wolf", guid = "Creature-0-1-0-1-299-0020", hostile = true }
    M.targetGUID = "Creature-0-1-0-1-299-0020"
    M.dead = true
    fire("PLAYER_DEAD")
    M.dead = false
    fire("PLAYER_UNGHOST")
    fire("PLAYER_ALIVE")

    -- A grouped fight read back from the game's damage meter once combat ends
    M.party = { "party1" }
    M.units.target = { name = "Kobold Vermin", guid = "Creature-0-1-0-1-6-0003", hostile = true }
    M.targetGUID = "Creature-0-1-0-1-6-0003"
    fire("PLAYER_TARGET_CHANGED")
    fire("PLAYER_REGEN_DISABLED")
    M.Advance(25)
    M.meter = { dur = 25,
        [0] = { { guid = "Player-1-000001", name = "Zinther", total = 400, me = true,
                  spells = { { id = 20154, total = 300, creature = "Kobold Vermin", overkill = 12 }, { id = 6603, total = 100, creature = "Young Wolf" } } },
                { guid = "Player-1-000002", name = "Danwar", total = 600 } },
        [2] = { { guid = "Player-1-000001", name = "Zinther", total = 80, me = true, spells = { { id = 635, total = 80, creature = "Danwar" } } },
                { guid = "Player-1-000002", name = "Danwar", total = 120, spells = { { id = 2050, total = 120, creature = "Zinther" } } } },
        [7] = { { guid = "Player-1-000001", name = "Zinther", total = 150, me = true, spells = { { id = 6603, total = 150, creature = "Kobold Vermin" } } } },
        [5] = { { guid = "Player-1-000001", name = "Zinther", total = 2, me = true } },
        [8] = { { guid = "Player-1-000001", name = "Zinther", total = 60, me = true } },
        [9] = { { guid = "Player-1-000002", name = "Danwar", total = 1, recap = 76 },
                { guid = "Player-1-000001", name = "Zinther", total = 1, me = true, recap = 77 } },
    }
    M.recaps[77] = { { timestamp = 5, sourceName = "Kobold Vermin", amount = 3 },
                     { timestamp = 10, sourceName = "Rabid Dog", sourceGUID = "Creature-0-1-0-1-1766-0040", spellName = "Bite", amount = 30 } }
    fire("PLAYER_REGEN_ENABLED")
    M.Advance(2)
    fire("PLAYER_REGEN_ENABLED") -- a second read of the same fight must not double count
    M.Advance(1)
    M.xp = M.xp + 20
    fire("PLAYER_XP_UPDATE")      -- right after a grouped fight the meter saw us in: an assist
    M.Advance(1)
    M.Advance(10)
    M.xp = M.xp + 20
    fire("PLAYER_XP_UPDATE")      -- long after combat: not a kill
    M.Advance(1)
    -- A death the recap can explain: the guess (our target) is replaced by the real killer
    M.dead = true
    fire("PLAYER_DEAD")
    M.Advance(2)
    M.dead = false
    fire("PLAYER_UNGHOST")
    fire("PLAYER_ALIVE")
end

-- Assists: Danwar (party flag 0x2) fights a wolf, we heal him, he kills it -> assist.
-- Then he kills a boar we never touched and never healed him during -> partyKills only.
M.cleu = { 0, "SWING_DAMAGE", false, "Player-1-000002", "Danwar", 0x512, 0, "Creature-0-1-0-1-299-0010", "Young Wolf", 0xa48, 0, 9 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.cleu = { 0, "SPELL_HEAL", false, "Player-1-000001", "Zinther", 0x511, 0, "Player-1-000002", "Danwar", 0x512, 0, 635, "Holy Light", 2, 40, 0, false }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.cleu = { 0, "PARTY_KILL", false, "Player-1-000002", "Danwar", 0x512, 0, "Creature-0-1-0-1-299-0010", "Young Wolf", 0xa48, 0 }
fire("COMBAT_LOG_EVENT_UNFILTERED")
M.Advance(2)
M.cleu = { 0, "PARTY_KILL", false, "Player-1-000002", "Danwar", 0x512, 0, "Creature-0-1-0-1-7-0011", "Boar", 0xa48, 0 }
fire("COMBAT_LOG_EVENT_UNFILTERED")

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
DoEmote("DANCE") -- /dance; in chat it reads "You burst into dance."
fire("CHAT_MSG_TEXT_EMOTE", "You burst into dance.", "Zinther")
SendChatMessage("hello", "SAY") -- what you send is counted at the call; the line that comes back is not
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

-- The window, both skins, every tab
SlashCmdList.HEARTHLOG("")
SlashCmdList.HEARTHLOG("ui b")
for _, tab in ipairs({ "overview", "journey", "combat", "loot", "friends", "settings" }) do ns.ShowTab(tab) end
SlashCmdList.HEARTHLOG("ui a")
for _, tab in ipairs({ "overview", "journey", "combat", "loot", "friends", "settings" }) do ns.ShowTab(tab) end
assert(HearthlogFrame and HearthlogFrame:IsShown(), "window did not open")
SlashCmdList.HEARTHLOG("")
assert(not HearthlogFrame:IsShown(), "window did not close")

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
return char, kinds, ns.ExportString()
''', ns)
char, kinds, export_str = script
export_len = len(export_str)
errors = [line for line in M.printed.values() if ("handler error" in line or "error in " in line)]
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
# the export string must decode back to the same character in the Python loader
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from load import decode_export
dec = decode_export(export_str)
dchar = dec["chars"]["Zinther-TestRealm"]
assert dchar["counters"]["kills"] == c.kills, "export round-trip: kills differ"
assert len(dchar["events"]) == len(char.events), "export round-trip: event count differs"
assert len(dchar["pos"][0]) == len(char.pos[1]), "export round-trip: pos chunks differ"
assert dec["maps"][1412]["name"] == "Mulgore", "export round-trip: maps missing"
if not FOREVER:
    assert c.duels == 1, "duels should be 1 (the declined request is not a duel)"
    assert c.duelRequests == 1, "one declined duel request expected"
    assert c.partyInvites == 1, "one party invite expected"
    assert kinds["DUEL"] == 1, "one DUEL event expected"
    print("duels OK: 1 fought, 1 declined, 1 party invite")
    assert c.assists == 1, "healing Danwar mid-fight should make his wolf kill an assist (got %s)" % c.assists
    assert c.partyKills == 1, "the untouched boar should be a party kill only (got %s)" % c.partyKills
    assert c.healingTaken == 50 and c.damageDone > 0, "damageDone/healingTaken counters (got %s)" % c.healingTaken
    assert "Food" not in [r.nm for r in char.tallies.spells.values()], "Food must not be a cast"
    print("assists OK: 1 assist via heal, 1 party kill ignored")
    t = char.tallies
    assert t.env["FALLING"].d == 37, "falling damage tally"
    assert c.rezzes == 1 and t.rezBy["Danwar"].n == 1, "rez by Danwar"
    assert t.healedBy["Danwar"].d == 50, "healedBy minus overheal (got %s)" % t.healedBy["Danwar"].d
    assert t.whispers["Danwar"].i == 2 and t.whispers["Danwar"].o == 1, "whispers in/out"
    assert c.binds == 1 and kinds["BIND"] == 1, "bind event"
    assert t.errors["Inventory is full."].n == 2, "error tally"
    assert c.screenshots == 1, "screenshot"
    assert t.bought[159].n == 5, "bought x5 (got %s)" % t.bought[159].n
    assert t.sold[755].n == 1 and 755 not in t.used, "sold, not used"
    assert c.pvpKills == 1 and t.pvpKills["Stabbyjoe"].n == 1 and kinds["PVP_KILL"] == 1, "pvp kill"
    assert c.pvpDeaths == 1 and t.killedByPlayers["Stabbyjoe"].n == 1, "pvp death"
    lvl = [e for e in char.events.values() if e.k == "LEVEL"][0]
    assert lvl.gold is not None and lvl.played is not None, "LEVEL carries gold and played"
    print("0.3.2 hooks OK: env, rez, heals by player, whispers, bind, errors, screenshot, bought/sold, pvp, level snapshot")
    assert t.buffedTo["Danwar"].n == 1, "buff given"
    assert c.rolls == 1 and c.rollsWon == 1 and kinds["WON"] == 1, "my roll and win"
    assert t.rolls["Zinther"].w == 1 and t.rolls["Zinther"].hi == 97, "my roll record"
    assert t.rolls["Danwar"].n == 2 and t.rolls["Danwar"].w == 1 and t.rolls["Danwar"].hi == 50, "Danwar rolls (got n=%s w=%s)" % (t.rolls["Danwar"].n, t.rolls["Danwar"].w)
    assert c.trades == 1 and t.trades["Danwar"].i == 2 and t.trades["Danwar"].o == 1 and t.trades["Danwar"].gi == 250, "trade"
    assert kinds["TRADE"] == 1, "trade event"
    assert c.mailItemsIn == 1 and t.mailFrom["Danwar"].n == 1, "mail item in"
    assert c.ahSold == 2 and c.ahSoldGold == 2400, "two lot sales counted, same mail not doubled (got %s/%s)" % (c.ahSold, c.ahSoldGold)
    assert c.mailSent == 1 and t.mailTo["Danwar"].i == 1 and t.mailTo["Danwar"].g == 500 and kinds["MAIL"] == 1, "mail sent"
    assert c.ahBuyouts == 1 and c.ahBids == 1 and c.ahSpent == 500 and t.ahBought[2318].n == 10, "auction buys (got n=%s)" % t.ahBought[2318].n
    assert c.ahPosted == 1 and t.ahPosted["Linen Cloth"].n == 40, "auction post"
    assert c.petDeaths == 1, "pet death"
else:
    t = char.tallies
    assert c.kills == 2 and c.grayKills == 1 and c.assists == 1 and c.partyKills == 0 and kinds["KILL"] == 3, \
        "kills from xp gains and UNIT_DIED (kills=%s gray=%s assists=%s party=%s events=%s)" % (c.kills, c.grayKills, c.assists, c.partyKills, kinds["KILL"])
    gray = [e for e in char.events.values() if e.k == "KILL" and e.gray][0]
    assert gray.n == "Gray Rat" and gray.xp == 0, "gray kill named from the dead target"
    assert not [e for e in char.events.values() if e.k == "KILL" and e.n == "Bystander Boar"], "a mob we never tagged is not our kill"
    assert c.avoidableTaken == 60 and t.groupDeaths["Danwar"].n == 1 and "Zinther" not in t.groupDeaths, "avoidable damage and group deaths from the meter"
    assert c.mounts == 1 and [e for e in char.events.values() if e.k == "MOUNT"][0].n == "Brown Kodo", "mount learned"
    assert c.ahPosted == 2 and t.ahPosted["Linen Cloth"].n == 60 and c.ahBuyouts == 2 and t.ahBought[2318].n == 15 and c.ahBids == 2 and c.ahSpent == 950, \
        "modern auction house hooks (posted=%s buyouts=%s bids=%s spent=%s)" % (c.ahPosted, c.ahBuyouts, c.ahBids, c.ahSpent)
    assist = [e for e in char.events.values() if e.k == "KILL" and e.assist][0]
    assert assist.n == "Kobold Vermin" and assist.group == True and assist.xp == 20, "assist is the creature the meter saw us damage"
    assert c.appearances == 1 and [e for e in char.events.values() if e.k == "LOOK"][0].n == "Frayed Robe", "appearance learned, named from the line"
    kv = [e for e in char.events.values() if e.k == "KILL" and e.n == "Kobold Vermin"][0]
    assert kv.xp == 45 and kv.lvl is not None, "kill carries xp and target level"
    assert c.xpKill == 65, "xp classified as kill xp (kill=%s other=%s)" % (c.xpKill, c.xpOther)
    assert c.maxHitDone == 31 and c.critsDone == 1 and c.dodged == 1, "hits via UNIT_COMBAT"
    assert c.maxHitTaken == 12 and c.healingTaken == 40, "taken via UNIT_COMBAT"
    assert c.damageDone == 400 and c.damageTaken == 150 and c.healingDone == 80, "totals from the meter (done=%s taken=%s healed=%s)" % (c.damageDone, c.damageTaken, c.healingDone)
    assert c.meterFights == 1 and c.interrupts == 2 and c.overkill == 12, "meter fight read once (fights=%s)" % c.meterFights
    assert t.damageBySpell[20154].d == 300 and t.damageTo["Kobold Vermin"].d == 300, "damage by ability and target"
    assert t.healBySpell[635].d == 80 and t.healedTo["Danwar"].d == 80 and t.healedBy["Danwar"].d == 120, "healing both ways from the meter"
    assert c.healingTaken == 40, "healing received stays with UNIT_COMBAT when that event exists (got %s)" % c.healingTaken
    assert t.hurtBy["Kobold Vermin"].d == 150, "hurt by from the meter"
    assert t.groupDmg["Danwar"].d == 600 and t.groupHeal["Danwar"].d == 120, "group members' numbers"
    fights = [e for e in char.events.values() if e.k == "FIGHT" and e.share is not None]
    assert len(fights) == 1 and fights[0].share == 40 and fights[0].done == 400, "fight event carries share (got %s)" % [ (f.share, f.done) for f in fights]
    assert char.records.hitDone.who == "Kobold Vermin", "biggest hit names the target"
    assert c.pvpKills == 1 and c.honorKills == 1 and t.pvpKills["Stabbyjoe"].n == 1 and kinds["PVP_KILL"] == 1, "pvp kill via the honor counter (kills=%s hk=%s)" % (c.pvpKills, c.honorKills)
    assert c.rezzes == 2 and t.rezBy["Danwar"].n == 1 and t.rezBy["Meredith"].n == 1, "rez via RESURRECT_REQUEST"
    assert t.buffedBy["Danwar"].n == 1 and t.buffedBy["Danwar"].f == 1, "buff from party via UNIT_AURA"
    deaths = sorted([e for e in char.events.values() if e.k == "DEATH"], key=lambda e: e.t)
    assert deaths[-2].by == "Mangy Wolf" and deaths[-2].guess == True, "death killer guessed from target"
    assert t.killers[299].n == 1, "killers tally from guessed death"
    assert deaths[-1].by == "Rabid Dog" and deaths[-1].recap == True and deaths[-1].guess is None and deaths[-1].spell == "Bite", \
        "death recap replaces the guess (by=%s)" % deaths[-1].by
    assert t.killers[1766].n == 1 and 6 not in t.killers, "the guess's tally is taken back, the real killer filed"
    assert c.duels == 1 and c.binds == 1 and c.trades == 1 and c.ahSold == 2 and c.mailSent == 1, "non-combat features unaffected"
    assert "Food" not in [r.nm for r in char.tallies.spells.values()], "Food must not be a cast"
    print("forever OK: kills from xp lines, UNIT_COMBAT damage, honor, rez, party buffs, guessed death")
print("medium set OK: buffs given, rolls, trade, mail, auction house, pet")
assert c.rep == 3000 and char.tallies.rep["Undercity"].d == 3000 and kinds["STANDING"] == 1, "reputation deltas (got %s)" % c.rep
assert c.achievements == 1 and [e for e in char.events.values() if e.k == "ACHIEVE"][0].n == "Level 10", "achievement"
print("rep and achievements OK")
print("export round-trip: OK (%d events, %d maps)" % (len(dchar["events"]), len(dec["maps"])))
t = char.tallies
print("tallies:", {g: {k: dict(v.items()) for k, v in t[g].items()} for g in ["items", "used", "spells", "skills", "buffs", "emotes", "chat", "gold"]})
leaked = [l for l in M.printed.values() if "LEAKED" in l]
nudges = [l for l in M.printed.values() if "is out" in l]
assert len(nudges) == 1, "version nudge should print exactly once"
assert any(m.msg.startswith("V:") for m in M.sentAddon.values()), "no version announce sent"
assert any(m.msg.startswith("A:") for m in M.sentAddon.values()), "no answer to Q sent"
assert c.emotes == 1 and t["emotes"]["dance"].n == 1, "own emote should count once, under its command word (got %s)" % c.emotes
assert t["used"][117].n == 1 and 1372 not in t["used"], "used filter broken"
assert c.meals == 1 and c.foodSeconds == 18, "food tracking broken"
assert t["gold"]["repair"].o == 37, "repair gold tally broken"
print("extra counters: swings", c.swings, "misses", c.swingMisses, "dodged", c.dodged, "casts", c.casts, "maxHitDone", c.maxHitDone,
      "crits", c.critsDone, "meals", c.meals, "foodSeconds", c.foodSeconds, "strangerBuffs", c.strangerBuffs, "discoveries", c.discoveries,
      "lootItems", c.lootItems, "emotes", c.emotes, "messages", c.messages, "teleports", c.teleports)
