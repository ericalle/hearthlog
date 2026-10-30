local ADDON_NAME, ns = ...
local Now, Event, Count, Call, CallIn = ns.Now, ns.Event, ns.Count, ns.Call, ns.CallIn

-- =========================================================
-- EVENTS: everything that happens to the character
-- =========================================================
-- Every handler is small and defensive. Event kinds (e.k) and their fields:
--   LEVEL      v=new level, since=seconds since last level, gear={slot links}
--   XP         v=amount, src=discover|other (kill and quest XP ride on the KILL and QUEST_DONE events as xp=)
--   DISCOVER   n=area name
--   QUEST_ACC  q=questID, n=name
--   QUEST_DONE q=questID, n=name, xp=, gold=copper, dur=seconds since accept (if seen)
--   QUEST_DROP q=questID, n=name
--   DEATH      by=killer name, npc=id, spell=, amt=, party={..}, inst=instance name
--   ALIVE      ghost=true when released to ghost, res=name of who resurrected (if offered), dur=seconds dead
--   KILL       n=mob name, npc=id, elite=true, rare=true, assist=true when a party member got the credit
--   FIGHT      dur=seconds, taken=damage taken, healed=healing done, party={..}
--   ZONE       n=zone, sub=subzone
--   INST_IN    n=instance name, kind=party|raid|pvp, party={..}
--   INST_OUT   n=, dur=seconds inside, kills=, deaths=
--   PARTY      add={..}, rem={..}, n=size
--   GOLD       v=copper (signed), ctx=vendor|loot|quest|mail|trade|ah|taxi|trainer|repair|other
--   LOOT       i=itemID, n=name, q=quality
--   GEAR       slot=, i=itemID, n=name, q=quality
--   SPELL      i=spellID, n=name
--   SKILL      n=skill name, v=new value (only every 25 points; every skill-up updates tallies.skills)
--   REP        txt=chat line
--   HEARTH     to=bind location
--   TAXI       from=zone, to=zone, dur=, gold=copper
--   DUEL       who=, won=true|false|nil
--   GUILD      n=guild name or nil when left
--   GZ         who=, chan=
--   WIPE       inst=name, party={..}
-- All carry t (server time) and, when known, m/x/y (map and position) and z (zone name).

local playerGUID
local lastLevelT
local lastHit = nil            -- Last damage taken: { src, npc, spell, amt, t }
local lastKillT, lastQuestT = 0, 0
local questNames = {}          -- [questID] = { n, t }  accepted this session
local turnedIn = {}            -- [questID] = true, to tell abandons from completions
local deadSince = nil
local resOffer = nil
local fight = nil              -- { t0, taken, healed }
local instance = nil           -- { n, t0, kills, deaths }
local party = {}               -- sorted list of "Name:CLASS"
local goldCtx, goldCtxT = "other", 0
local money = nil
local taxi = nil               -- { from, t0, gold }
local lastDuel = nil
local guildName = nil

local function SetCtx(ctx) goldCtx, goldCtxT = ctx, Now() end
local function Ctx()
    if Now() - goldCtxT <= 8 then return goldCtx end
    return "other"
end

local function QuestName(questID, index)
    local info = CallIn(C_QuestLog, "GetQuestInfo", questID)
    if type(info) == "string" and info ~= "" then return info end
    if index and GetQuestLogTitle then
        local title = Call("GetQuestLogTitle", index)
        if type(title) == "string" then return title end
    end
    local t = CallIn(C_QuestLog, "GetTitleForQuestID", questID)
    if type(t) == "string" then return t end
    return nil
end

-- ---------------------------------------------------------
-- Levels and XP
-- ---------------------------------------------------------
local function GearSnapshot()
    local gear = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink("player", slot)
        if link then gear[slot] = ns.ItemId(link) end
    end
    return gear
end

ns.On("PLAYER_LEVEL_UP", function(level)
    local now = Now()
    ns.level = level
    Event("LEVEL", { v = level, since = lastLevelT and (now - lastLevelT) or nil, gear = GearSnapshot() })
    lastLevelT = now
    Count("levels")
    ns.lastLevelUpT = now -- Gz detection
    if ns.RequestPlayed then C_Timer.After(2, ns.RequestPlayed) end
end)

local lastXP = nil
local lastDiscoverT = 0
local lastKillEvent, lastQuestEvent = nil, nil

-- Last event of a kind within `window` seconds, or nil
local function Recent(e, window)
    if e and Now() - e.t <= window then return e end
    return nil
end

ns.On("PLAYER_XP_UPDATE", function()
    local xp = UnitXP("player")
    if lastXP == nil then lastXP = xp return end
    local gain = xp - lastXP
    lastXP = xp
    if gain <= 0 then return end -- Level rollover: the LEVEL event covers it
    Count("xp", gain)
    local quest = Recent(lastQuestEvent, 2)
    local kill = Recent(lastKillEvent, 3)
    if quest then
        Count("xpQuest", gain)
        quest.xp = quest.xp or gain
    elseif kill then
        Count("xpKill", gain)
        kill.xp = (kill.xp or 0) + gain
    else
        Count("xpOther", gain)
        Event("XP", { v = gain, src = (Now() - lastDiscoverT <= 3) and "discover" or "other" })
    end
end)

-- "Discovered: Northshire Abbey"
ns.On("UI_INFO_MESSAGE", function(_, msg)
    local area = type(msg) == "string" and msg:match("^Discovered: (.+)$")
    if not area then return end
    lastDiscoverT = Now()
    Count("discoveries")
    Event("DISCOVER", { n = area })
end)

-- ---------------------------------------------------------
-- Quests
-- ---------------------------------------------------------
ns.On("QUEST_ACCEPTED", function(a, b)
    -- Classic: (questLogIndex, questID). Retail: (questID)
    local index, questID = nil, a
    if b then index, questID = a, b end
    local name = QuestName(questID, index)
    questNames[questID] = { n = name, t = Now() }
    Count("questsAccepted")
    Event("QUEST_ACC", { q = questID, n = name })
end)

ns.On("QUEST_TURNED_IN", function(questID, xp, gold)
    local known = questNames[questID]
    turnedIn[questID] = true
    lastQuestT = Now()
    Count("questsDone")
    SetCtx("quest")
    lastQuestEvent = Event("QUEST_DONE", { q = questID, n = known and known.n or QuestName(questID), xp = xp, gold = gold,
        dur = known and (Now() - known.t) or nil })
end)

ns.On("QUEST_REMOVED", function(questID)
    C_Timer.After(1, function()
        if turnedIn[questID] then
            turnedIn[questID] = nil
            return
        end
        local known = questNames[questID]
        Count("questsAbandoned")
        Event("QUEST_DROP", { q = questID, n = known and known.n })
    end)
end)

-- ---------------------------------------------------------
-- Combat log: damage taken, kills, healing
-- ---------------------------------------------------------
local DAMAGE = { SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
    ENVIRONMENTAL_DAMAGE = true, DAMAGE_SHIELD = true }
local HEAL = { SPELL_HEAL = true, SPELL_PERIODIC_HEAL = true }

-- Food and Drink: watched on the buff bar (UNIT_AURA), see further down
local FOOD_AURAS = { Food = "food", Drink = "drink", ["Refreshment"] = "food" }

local function IsPlayerGUID(guid) return type(guid) == "string" and guid:sub(1, 7) == "Player-" end

local function InParty(name)
    if not name then return false end
    local short = name:match("^([^%-]+)") or name
    for _, m in ipairs(party) do
        if m:match("^([^:]+)") == short then return true end
    end
    return false
end

local function OnCombatLog(...)
    local _, sub, _, srcGUID, srcName, _, _, dstGUID, dstName, _, _, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = ...
    -- Damage suffix: amount, overkill, school, resisted, blocked, absorbed, critical. Spells and
    -- ranged carry a 3-field prefix (id, name, school) before it, swings none, environmental one.
    if dstGUID == playerGUID and DAMAGE[sub] then
        local spell, amt, crit
        if sub == "SWING_DAMAGE" then amt = a1; crit = a7
        elseif sub == "ENVIRONMENTAL_DAMAGE" then spell = a1; amt = a2; crit = a8; srcName = srcName or a1
        else spell = a2; amt = a4; crit = a10 end
        if type(amt) ~= "number" then amt = tonumber(amt) or 0 end
        lastHit = { src = srcName, npc = ns.NpcId(srcGUID), spell = spell, amt = amt, t = Now() }
        if fight then fight.taken = fight.taken + amt end
        ns.Max("maxHitTaken", amt)
        if crit == true then Count("critsTaken") end
    elseif srcGUID == playerGUID and DAMAGE[sub] then
        local amt, crit
        if sub == "SWING_DAMAGE" then amt = a1; crit = a7; Count("swings")
        elseif sub == "RANGE_DAMAGE" then amt = a4; crit = a10; Count("shots")
        else amt = a4; crit = a10 end
        if type(amt) ~= "number" then amt = tonumber(amt) or 0 end
        ns.Max("maxHitDone", amt)
        if crit == true then Count("critsDone") end
    elseif srcGUID == playerGUID and sub == "SWING_MISSED" then
        Count("swings")
        Count("swingMisses")
        if a1 == "DODGE" then Count("dodged") elseif a1 == "PARRY" then Count("parried") end
    elseif srcGUID == playerGUID and sub == "RANGE_MISSED" then
        Count("shots")
    elseif srcGUID == playerGUID and HEAL[sub] and fight then
        fight.healed = fight.healed + (tonumber(a4) or 0) - (tonumber(a5 or 0) or 0)
    elseif dstGUID == playerGUID and sub == "SPELL_AURA_APPLIED" then
        if IsPlayerGUID(srcGUID) and srcGUID ~= playerGUID and a4 == "BUFF" and not InParty(srcName) then
            Count("strangerBuffs")
            ns.Tally("buffs", a1, a2)
        end
    elseif sub == "PARTY_KILL" then
        local mine = srcGUID == playerGUID or (UnitGUID("pet") and srcGUID == UnitGUID("pet"))
        local npc = ns.NpcId(dstGUID)
        if not npc then return end -- Players and pets are not kills for this count
        local e = { n = dstName, npc = npc }
        if UnitGUID("target") == dstGUID then
            local cls = UnitClassification("target")
            if cls == "elite" or cls == "worldboss" or cls == "rareelite" then e.elite = true end
            if cls == "rare" or cls == "rareelite" then e.rare = true end
        end
        if not mine then e.assist = true end
        lastKillT = Now()
        Count(mine and "kills" or "assists")
        if instance then instance.kills = instance.kills + 1 end
        lastKillEvent = Event("KILL", e)
    end
end

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    if CombatLogGetCurrentEventInfo then OnCombatLog(CombatLogGetCurrentEventInfo()) end
end)

-- ---------------------------------------------------------
-- Fights
-- ---------------------------------------------------------
ns.On("PLAYER_REGEN_DISABLED", function()
    fight = { t0 = Now(), taken = 0, healed = 0 }
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    if not fight then return end
    local dur = Now() - fight.t0
    Count("fights")
    Count("fightSeconds", dur)
    Count("damageTaken", fight.taken)
    Count("healingDone", fight.healed)
    -- Short solo fights are noise for the replay; keep them in counters only
    if dur >= 20 or fight.healed > 0 or #party > 0 then
        Event("FIGHT", { dur = dur, taken = fight.taken, healed = fight.healed, party = #party > 0 and ns.CopyArray(party) or nil })
    end
    fight = nil
end)

-- ---------------------------------------------------------
-- Death and life
-- ---------------------------------------------------------
ns.On("PLAYER_DEAD", function()
    deadSince = Now()
    Count("deaths")
    if instance then instance.deaths = instance.deaths + 1 end
    local e = { party = #party > 0 and ns.CopyArray(party) or nil, inst = instance and instance.n or nil }
    if lastHit and Now() - lastHit.t <= 15 then
        e.by, e.npc, e.spell, e.amt = lastHit.src, lastHit.npc, lastHit.spell, lastHit.amt
    end
    Event("DEATH", e)
    -- Wipe: everyone in the party dead a moment later
    if instance and #party > 0 then
        C_Timer.After(3, function()
            local prefix, count = "party", GetNumSubgroupMembers()
            if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
            for i = 1, count do
                if not UnitIsDeadOrGhost(prefix .. i) then return end
            end
            Event("WIPE", { inst = instance and instance.n, party = ns.CopyArray(party) })
        end)
    end
end)

ns.On("RESURRECT_REQUEST", function(name)
    resOffer = { who = name, t = Now() }
end)

ns.On("PLAYER_UNGHOST", function()
    if not deadSince then return end
    Event("ALIVE", { dur = Now() - deadSince, res = resOffer and (Now() - resOffer.t <= 60) and resOffer.who or nil })
    deadSince, resOffer = nil, nil
end)

ns.On("PLAYER_ALIVE", function()
    if not deadSince then return end
    if UnitIsGhost("player") then
        Event("ALIVE", { ghost = true })
    else
        Event("ALIVE", { dur = Now() - deadSince, res = resOffer and (Now() - resOffer.t <= 60) and resOffer.who or nil })
        deadSince, resOffer = nil, nil
    end
end)

-- ---------------------------------------------------------
-- Zones and instances
-- ---------------------------------------------------------
local lastZone = nil
local function ZoneCheck()
    local zone = GetRealZoneText()
    if not zone or zone == "" or zone == lastZone then return end
    lastZone = zone
    local sub = GetSubZoneText()
    Event("ZONE", { n = zone, sub = sub ~= "" and sub or nil, taxi = UnitOnTaxi("player") and true or nil })
end
ns.On("ZONE_CHANGED_NEW_AREA", ZoneCheck)

local function InstanceCheck()
    local inInst, kind = IsInInstance()
    local name = inInst and (GetInstanceInfo()) or nil
    if inInst and (not instance or instance.n ~= name) then
        if instance then
            Event("INST_OUT", { n = instance.n, dur = Now() - instance.t0, kills = instance.kills, deaths = instance.deaths })
        end
        instance = { n = name, kind = kind, t0 = Now(), kills = 0, deaths = 0 }
        Event("INST_IN", { n = name, kind = kind, party = #party > 0 and ns.CopyArray(party) or nil })
    elseif not inInst and instance then
        Event("INST_OUT", { n = instance.n, dur = Now() - instance.t0, kills = instance.kills, deaths = instance.deaths })
        instance = nil
    end
end

function ns.OnEnterWorld()
    playerGUID = UnitGUID("player")
    money = GetMoney()
    lastXP = UnitXP("player")
    guildName = GetGuildInfo("player")
    party = ns.PartyList()
    C_Timer.After(2, function()
        ZoneCheck()
        InstanceCheck()
    end)
end

-- ---------------------------------------------------------
-- Party
-- ---------------------------------------------------------
ns.On("GROUP_ROSTER_UPDATE", function()
    local new = ns.PartyList()
    local old = {}
    for _, m in ipairs(party) do old[m] = true end
    local add, rem = {}, {}
    local seen = {}
    for _, m in ipairs(new) do
        seen[m] = true
        if not old[m] then tinsert(add, m) end
    end
    for _, m in ipairs(party) do
        if not seen[m] then tinsert(rem, m) end
    end
    party = new
    if #add == 0 and #rem == 0 then return end
    Event("PARTY", { add = #add > 0 and add or nil, rem = #rem > 0 and rem or nil, n = #new })
end)

-- ---------------------------------------------------------
-- Gold
-- ---------------------------------------------------------
ns.On("MERCHANT_SHOW", function() SetCtx("vendor") end)
ns.On("LOOT_OPENED", function() SetCtx("loot") end)
ns.On("MAIL_SHOW", function() SetCtx("mail") end)
ns.On("TRADE_SHOW", function() SetCtx("trade") end)
ns.On("AUCTION_HOUSE_SHOW", function() SetCtx("ah") end)
ns.On("TRAINER_SHOW", function() SetCtx("trainer") end)
ns.On("TAXIMAP_OPENED", function() SetCtx("taxi") end)
ns.On("BANKFRAME_OPENED", function() SetCtx("bank") end)
if hooksecurefunc and RepairAllItems then
    hooksecurefunc("RepairAllItems", function() SetCtx("repair") end)
end
local pendingFare = nil -- Copper paid at the flight master, picked up when the taxi starts

ns.On("PLAYER_MONEY", function()
    local now = GetMoney()
    if money == nil then money = now return end
    local delta = now - money
    money = now
    if delta == 0 then return end
    local ctx = Ctx()
    if delta > 0 then Count("goldIn", delta) else Count("goldOut", -delta) end
    local rec = ns.Tally("gold", ctx, ctx)
    if rec then
        if delta > 0 then rec.i = (rec.i or 0) + delta else rec.o = (rec.o or 0) - delta end
    end
    if ctx == "taxi" and delta < 0 then pendingFare = -delta end
    -- Every change counts; only changes of a silver or more get their own event
    if math.abs(delta) >= 100 then Event("GOLD", { v = delta, ctx = ctx }) end
end)

-- ---------------------------------------------------------
-- Loot and gear
-- ---------------------------------------------------------
ns.On("CHAT_MSG_LOOT", function(msg)
    if not msg then return end
    -- "You receive loot: [link]x3." / "You receive item: [link]." / "You create: [link]."
    if not (msg:find("^You receive") or msg:find("^You create")) then return end
    local link = msg:match("|c%x+|Hitem:.-|h%[.-%]|h|r")
    if not link then return end
    local count = tonumber(msg:match("|h|rx(%d+)")) or 1
    local q = ns.LinkQuality(link) or 0
    local id, name = ns.ItemId(link), ns.LinkName(link)
    Count("lootItems", count)
    if q == 0 then Count("lootGray", count) elseif q == 1 then Count("lootWhite", count) end
    local rec = ns.Tally("items", id, name, { q = q })
    if rec and count > 1 then rec.n = rec.n + count - 1 end
    if q >= 2 then
        Count(q == 2 and "lootGreen" or q == 3 and "lootBlue" or "lootEpic")
        Event("LOOT", { i = id, n = name, q = q })
    end
end)

ns.On("PLAYER_EQUIPMENT_CHANGED", function(slot, hasItem)
    if not hasItem then return end
    local link = GetInventoryItemLink("player", slot)
    if not link then return end
    Event("GEAR", { slot = slot, i = ns.ItemId(link), n = ns.LinkName(link), q = ns.LinkQuality(link) })
end)

-- ---------------------------------------------------------
-- Spells, skills, reputation
-- ---------------------------------------------------------
ns.On("LEARNED_SPELL_IN_TAB", function(spellID)
    local name = Call("GetSpellInfo", spellID)
    if not name and C_Spell and C_Spell.GetSpellName then name = CallIn(C_Spell, "GetSpellName", spellID) end
    Event("SPELL", { i = spellID, n = name })
end)

ns.On("CHAT_MSG_SKILL", function(msg)
    -- "Your skill in Two-Handed Maces has increased to 14."
    if type(msg) ~= "string" then return end
    local name, value = msg:match("^Your skill in (.-) has increased to (%d+)")
    if not name then return end
    value = tonumber(value)
    local rec = ns.Tally("skills", name, name)
    if rec then rec.v = value end
    if value % 25 == 0 then Event("SKILL", { n = name, v = value }) end
end)

ns.On("CHAT_MSG_COMBAT_FACTION_CHANGE", function(msg)
    if msg then Event("REP", { txt = msg }) end
end)

-- ---------------------------------------------------------
-- Hearthstone, taxi
-- ---------------------------------------------------------
local HEARTH_SPELLS = { [8690] = true, [556] = true } -- Hearthstone, Astral Recall
local AUTO_SPELLS = { [6603] = true, [75] = true, [5019] = true } -- Attack, Auto Shot, Shoot: counted from the combat log instead
local function SpellName(spellID)
    local name = Call("GetSpellInfo", spellID)
    if not name and C_Spell and C_Spell.GetSpellName then name = CallIn(C_Spell, "GetSpellName", spellID) end
    return name
end
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spellID)
    if unit ~= "player" then return end
    if type(spellID) ~= "number" then spellID = tonumber(spellID) end
    if not spellID then return end
    if HEARTH_SPELLS[spellID] then
        Count("hearths")
        Event("HEARTH", { to = GetBindLocation and GetBindLocation() or nil })
    end
    if not AUTO_SPELLS[spellID] then
        Count("casts")
        ns.Tally("spells", spellID, SpellName(spellID))
    end
end)

-- Items used: bags (C_Container / UseContainerItem), action bars (UseAction), by name
-- Right-clicking a bag item also equips, sells, mails, trades and banks it.
-- Only count it as a use when none of those windows are open and the item
-- is not gear.
local function TradingWindowOpen()
    for _, name in ipairs({ "MerchantFrame", "MailFrame", "TradeFrame", "AuctionFrame", "AuctionHouseFrame",
        "BankFrame", "GuildBankFrame" }) do
        local f = _G[name]
        if f and f.IsShown and f:IsShown() then return true end
    end
    return false
end
local function UsedItem(link)
    if not link or TradingWindowOpen() then return end
    local equippable = Call("IsEquippableItem", link)
    if equippable then return end
    ns.Tally("used", ns.ItemId(link), ns.LinkName(link), { q = ns.LinkQuality(link) })
end
if hooksecurefunc then
    if C_Container and C_Container.UseContainerItem then
        hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
            UsedItem(CallIn(C_Container, "GetContainerItemLink", bag, slot))
        end)
    elseif UseContainerItem then
        hooksecurefunc("UseContainerItem", function(bag, slot)
            UsedItem(Call("GetContainerItemLink", bag, slot))
        end)
    end
    if UseAction then
        hooksecurefunc("UseAction", function(slot)
            local kind, id = Call("GetActionInfo", slot)
            if kind == "item" and id then
                local _, link = Call("GetItemInfo", id)
                if link then UsedItem(link) else ns.Tally("used", id, nil) end
            end
        end)
    end
    if UseItemByName then
        hooksecurefunc("UseItemByName", function(name)
            local _, link = Call("GetItemInfo", name)
            UsedItem(link)
        end)
    end
end

-- Taxi start and end are noticed by polling, since Classic has no clean event for the landing
local wasOnTaxi = false
C_Timer.NewTicker(2, function()
    if not ns.char then return end
    local on = UnitOnTaxi("player") and true or false
    if on and not wasOnTaxi then
        taxi = { from = GetRealZoneText(), t0 = Now(), gold = pendingFare }
        pendingFare = nil
    elseif not on and wasOnTaxi and taxi then
        Count("taxis")
        Count("taxiGold", taxi.gold or 0)
        Event("TAXI", { from = taxi.from, to = GetRealZoneText(), dur = Now() - taxi.t0, gold = taxi.gold })
        taxi = nil
    end
    wasOnTaxi = on
end)

-- ---------------------------------------------------------
-- Duels, guild, jumps, gz
-- ---------------------------------------------------------
ns.On("DUEL_REQUESTED", function(name) lastDuel = { who = name, t = Now() } end)
ns.On("DUEL_FINISHED", function()
    Count("duels")
    Event("DUEL", { who = lastDuel and lastDuel.who or nil })
    lastDuel = nil
end)
ns.On("CHAT_MSG_SYSTEM", function(msg)
    -- "X has defeated Y in a duel"
    if type(msg) ~= "string" then return end
    local winner, loser = msg:match("^(.-) has defeated (.-) in a duel")
    if not winner then return end
    local me = UnitName("player")
    local events = ns.char and ns.char.events
    local lastE = events and events[#events]
    if lastE and lastE.k == "DUEL" and Now() - lastE.t <= 5 then
        lastE.won = (winner == me)
        lastE.who = lastE.who or (winner == me and loser or winner)
    end
end)

ns.On("PLAYER_GUILD_UPDATE", function(unit)
    if unit and unit ~= "player" then return end
    local name = GetGuildInfo("player")
    if name == guildName then return end
    guildName = name
    Event("GUILD", { n = name })
end)

if JumpOrAscendStart and hooksecurefunc then
    hooksecurefunc("JumpOrAscendStart", function()
        if ns.char and not ns.paused then Count("jumps") end
    end)
end

local GZ = { "^gz", "%f[%a]gz%f[%A]", "grats", "gratz", "congrat", "ding!", "^dinggg" }
local function OnChat(chan)
    return function(msg, sender)
        if not ns.lastLevelUpT or Now() - ns.lastLevelUpT > 90 then return end
        if not msg then return end
        local low = msg:lower()
        for _, pat in ipairs(GZ) do
            if low:find(pat) then
                local name = sender and Ambiguate and Ambiguate(sender, "short") or sender
                if name == UnitName("player") then return end
                Count("gz")
                Event("GZ", { who = name, chan = chan })
                return
            end
        end
    end
end
-- Emotes you perform: "Zinther dances." -> "dances"
ns.On("CHAT_MSG_TEXT_EMOTE", function(msg, sender)
    local me = UnitName("player")
    local short = sender and (sender:match("^([^%-]+)") or sender)
    if short ~= me or not msg then return end
    local verb = msg:match("^" .. me .. " (%a+)")
    if not verb then return end
    Count("emotes")
    ns.Tally("emotes", verb:lower(), verb:lower())
end)

-- Messages you send, counted per channel (the text is never stored)
local function SentBy(sender)
    local short = sender and (sender:match("^([^%-]+)") or sender)
    return short == UnitName("player")
end
local function CountChat(chan)
    return function(msg, sender)
        if SentBy(sender) then
            Count("messages")
            ns.Tally("chat", chan, chan)
        end
    end
end
ns.On("CHAT_MSG_SAY", CountChat("say"))
ns.On("CHAT_MSG_YELL", CountChat("yell"))
ns.On("CHAT_MSG_PARTY", CountChat("party"))
ns.On("CHAT_MSG_PARTY_LEADER", CountChat("party"))
ns.On("CHAT_MSG_RAID", CountChat("raid"))
ns.On("CHAT_MSG_GUILD", CountChat("guild"))
ns.On("CHAT_MSG_WHISPER_INFORM", CountChat("whisper"))
ns.On("CHAT_MSG_CHANNEL", CountChat("channel"))

ns.On("CHAT_MSG_GUILD", OnChat("guild"))
ns.On("CHAT_MSG_PARTY", OnChat("party"))
ns.On("CHAT_MSG_PARTY_LEADER", OnChat("party"))
ns.On("CHAT_MSG_RAID", OnChat("raid"))
ns.On("CHAT_MSG_WHISPER", OnChat("whisper"))
ns.On("CHAT_MSG_SAY", OnChat("say"))

-- ---------------------------------------------------------
-- Eating and drinking: the Food / Drink buffs on the player
-- ---------------------------------------------------------
local eatingSince, drinkingSince = nil, nil
local function HasBuff(wanted)
    -- UnitAura by index works on every client; AuraUtil is a bonus
    for i = 1, 40 do
        local name = Call("UnitAura", "player", i, "HELPFUL")
        if not name then break end
        if FOOD_AURAS[name] == wanted then return true end
    end
    return false
end
local function CheckFoodDrink()
    if not ns.char then return end
    local food, drink = HasBuff("food"), HasBuff("drink")
    local now = Now()
    if food and not eatingSince then eatingSince = now; Count("meals")
    elseif not food and eatingSince then Count("foodSeconds", now - eatingSince); eatingSince = nil end
    if drink and not drinkingSince then drinkingSince = now; Count("drinks")
    elseif not drink and drinkingSince then Count("drinkSeconds", now - drinkingSince); drinkingSince = nil end
end
ns.On("UNIT_AURA", function(unit)
    if unit == "player" then CheckFoodDrink() end
end)

-- Instance tracking needs the world to be loaded each time we zone
ns.On("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(2, InstanceCheck)
end)
