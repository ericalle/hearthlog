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
--   DEATH      by=killer name, npc=id, spell=, amt=, lvl=killer level, l=my level, pvp=true, party={..}, inst=instance name
--   PVP_KILL   who=player name
--   BIND       n=inn name (hearthstone set here)
--   WON        n=item name, q=quality, roll=your roll (a loot roll you won)
--   TRADE      who=, gave={item names}, got={item names}, gi=copper received, go=copper given
--   MAIL       to=, items=count, gold=copper (mail you sent)
--   LOOK       n=item name, id=appearance source id (added to the appearance collection)
--   ALIVE      ghost=true when released to ghost, res=name of who resurrected (if offered), dur=seconds dead
--   KILL       n=mob name, npc=id, lvl=mob level, elite=true, rare=true, assist=true when a party member got the credit
--   FIGHT      dur=seconds, taken=damage taken, healed=healing done, party={..}
--   ZONE       n=zone, sub=subzone
--   INST_IN    n=instance name, kind=party|raid|pvp, party={..}
--   INST_OUT   n=, dur=seconds inside, kills=, deaths=
--   PARTY      add={..}, rem={..}, n=size
--   GOLD       v=copper (signed), ctx=vendor|loot|quest|mail|trade|ah|taxi|trainer|repair|other
--   LOOT       i=itemID, n=name, q=quality
--   GEAR       slot=, i=itemID, n=name, q=quality
--   SPELL      i=spellID, n=name
--   TALENT     n=talent name, id=spellID, v=rank now (trait clients only; tab clients have talents= on LEVEL)
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
local lastHit = nil            -- Last damage taken: { src, npc, spell, amt, lvl, t }
local engaged = {}             -- mob GUID -> last time we hit it, it hit us, or we healed someone it was fighting
local engagedN = 0
local memberFoes = {}          -- party member GUID -> { mob GUID = last time they traded blows }
local PARTY_FLAGS = 0x7        -- COMBATLOG_OBJECT_AFFILIATION_MINE | PARTY | RAID
local function IsGroupFlag(flags) return type(flags) == "number" and bit.band(flags, PARTY_FLAGS) ~= 0 end
local levelOf = {}             -- GUID -> level, from whatever we target, mouse over or see on a nameplate
local levelN = 0

local Short, PlayerName = ns.ShortName, ns.PlayerName
local function IsPlayerOrPet(guid) return type(guid) == "string" and (guid:sub(1, 6) == "Player" or guid:sub(1, 3) == "Pet") end
local function IsPlayer(guid) return type(guid) == "string" and guid:sub(1, 6) == "Player" end
local Pat = ns.Pat

local function NoteLevel(unit)
    local guid = unit and ns.Str(UnitGUID(unit))
    if not guid then return end
    local lvl = ns.Num(UnitLevel(unit))
    if lvl and lvl > 0 then
        if not levelOf[guid] then
            levelN = levelN + 1
            if levelN > 400 then levelOf = {}; levelN = 1 end
        end
        levelOf[guid] = lvl
    end
end
ns.On("PLAYER_TARGET_CHANGED", function() NoteLevel("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() NoteLevel("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", function(unit) NoteLevel(unit) end)
local function LevelOf(guid)
    if not guid then return nil end
    if UnitGUID("target") == guid then NoteLevel("target") end
    return levelOf[guid]
end

local engagedNames = {} -- creature name -> last time we damaged it (meter clients only know names)
function ns.Engaged(name)
    if name then engagedNames[name] = Now() end
end
function ns.EngagedRecently(name)
    local t = name and engagedNames[name]
    return t ~= nil and (Now() - t) <= 120
end

local function Engage(guid)
    if not guid then return end
    if not engaged[guid] then
        engagedN = engagedN + 1
        if engagedN > 400 then engaged = {}; engagedN = 1 end
    end
    engaged[guid] = Now()
end
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

-- A context lasts 8 seconds from the thing that set it (loot, quest, taxi, repair). A window that stays
-- open (vendor, mail, auction house, trainer, bank, trade) keeps its context until it closes.
local openCtx = nil
local function SetCtx(ctx) goldCtx, goldCtxT = ctx, Now() end
local function OpenCtx(ctx) openCtx = ctx; SetCtx(ctx) end
local function CloseCtx(ctx) if openCtx == ctx then openCtx = nil end end
local function Ctx()
    if Now() - goldCtxT <= 8 then return goldCtx end
    return openCtx or "other"
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

-- Talents on clients built on the trait system (Retail; Forever if it is built the same way): every
-- talent with points in it, as { [spellID] = rank }. nil where that system or its data is not there.
local function TraitTalents()
    if not (C_ClassTalents and C_Traits) then return nil end
    local config = ns.Num(ns.CallIn(C_ClassTalents, "GetActiveConfigID"))
    local info = config and ns.Tbl(ns.CallIn(C_Traits, "GetConfigInfo", config))
    local trees = info and ns.Tbl(info.treeIDs)
    if not trees then return nil end
    local out = {}
    for _, tree in ipairs(trees) do
        for _, node in ipairs(ns.Tbl(ns.CallIn(C_Traits, "GetTreeNodes", tree)) or {}) do
            local ni = ns.Tbl(ns.CallIn(C_Traits, "GetNodeInfo", config, node))
            -- Points you put in, not ranks the class hands out for free
            local rank = ni and (ns.Num(ni.ranksPurchased) or ns.Num(ni.activeRank)) or 0
            local entry = ni and ns.Tbl(ni.activeEntry)
            local entryID = entry and ns.Num(entry.entryID)
            if rank > 0 and entryID then
                local ei = ns.Tbl(ns.CallIn(C_Traits, "GetEntryInfo", config, entryID))
                local def = ei and ns.Num(ei.definitionID) and ns.Tbl(ns.CallIn(C_Traits, "GetDefinitionInfo", ei.definitionID))
                local spell = def and ns.Num(def.spellID)
                if spell then out[spell] = rank end
            end
        end
    end
    return out
end
local function TalentName(spell)
    local name = C_Spell and C_Spell.GetSpellName and ns.Str(ns.CallIn(C_Spell, "GetSpellName", spell)) or ns.Str((Call("GetSpellInfo", spell)))
    return name or tostring(spell)
end
-- "Holy 0/Protection 5/Retribution 12" on clients with talent tabs, "Benediction 5/Improved Blessing of
-- Might 2" on trait clients, nil when neither answers
local function TalentSnapshot()
    local n = Call("GetNumTalentTabs")
    local parts = {}
    if type(n) == "number" and n > 0 then
        for i = 1, n do
            local name, _, spent = Call("GetTalentTabInfo", i)
            if name then tinsert(parts, string.format("%s %d", name, tonumber(spent) or 0)) end
        end
    else
        for spell, rank in pairs(TraitTalents() or {}) do tinsert(parts, string.format("%s %d", TalentName(spell), rank)) end
        table.sort(parts)
    end
    return #parts > 0 and table.concat(parts, "/") or nil
end
-- A TALENT event for each point spent on a trait client. The first look of a session only sets the baseline.
local lastTalents, talentCheckDue = nil, false
local function TalentCheck()
    talentCheckDue = false
    local now = TraitTalents()
    if not now then return end
    if lastTalents then
        for spell, rank in pairs(now) do
            if rank > (lastTalents[spell] or 0) then Event("TALENT", { n = TalentName(spell), id = spell, v = rank }) end
        end
    end
    lastTalents = now
end
for _, ev in ipairs({ "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_LIST_UPDATED", "PLAYER_TALENT_UPDATE" }) do
    ns.On(ev, function()
        if talentCheckDue or not (C_ClassTalents and C_Traits) then return end
        talentCheckDue = true
        ns.After(1, TalentCheck)
    end)
end
-- /hl talents: which talent functions this client has and what they return
function ns.TalentDump()
    local config = C_ClassTalents and ns.CallIn(C_ClassTalents, "GetActiveConfigID")
    local info = config and C_Traits and ns.Tbl(ns.CallIn(C_Traits, "GetConfigInfo", config))
    local trees = info and ns.Tbl(info.treeIDs)
    ns.Print(string.format("talent functions: GetNumTalentTabs=%s (%s) GetTalentInfo=%s C_SpecializationInfo.GetTalentInfo=%s C_ClassTalents=%s C_Traits=%s",
        type(GetNumTalentTabs), tostring((Call("GetNumTalentTabs"))), type(GetTalentInfo),
        type(C_SpecializationInfo and C_SpecializationInfo.GetTalentInfo), type(C_ClassTalents), type(C_Traits)))
    ns.Print(string.format("active config=%s trees=%s", tostring(config), trees and tostring(#trees) or "none"))
    ns.Print("read as: " .. tostring(TalentSnapshot()))
end
-- Total time played right now: the /played total at login plus this session so far
local function PlayedNow()
    local p = ns.playedAt
    if not p then return nil end
    return p.total + (Now() - p.t)
end

ns.On("PLAYER_LEVEL_UP", function(level)
    local now = Now()
    ns.level = level
    local since = lastLevelT and (now - lastLevelT) or nil
    Event("LEVEL", { v = level, since = since, gear = ns.Setting("gearSnapshot") and GearSnapshot() or nil,
        gold = GetMoney(), played = PlayedNow(), talents = TalentSnapshot() })
    lastLevelT = now
    Count("levels")
    ns.lastLevelUpT = now -- Gz detection
    if ns.RequestPlayed then ns.After(2, ns.RequestPlayed) end
    if ns.Setting("levelSummary") then
        local c = ns.char.counters
        ns.Print(string.format("level %d%s · %d kills, %d deaths so far", level, since and (" after " .. ns.Duration(since)) or "", c.kills, c.deaths))
    end
end)

local lastXP, lastXPMax, lastXPLevel = nil, nil, nil
local lastDiscoverT = 0
local lastKillEvent, lastQuestEvent = nil, nil
local fightEndedT = nil

-- Last event of a kind within `window` seconds, or nil
local function Recent(e, window)
    if e and Now() - e.t <= window then return e end
    return nil
end

ns.On("PLAYER_XP_UPDATE", function()
    local xp = UnitXP("player")
    local max = ns.Num(Call("UnitXPMax", "player"))
    local lvl = ns.level
    if lastXP == nil then lastXP, lastXPMax, lastXPLevel = xp, max, lvl return end
    local gain = xp - lastXP
    -- The gain that levels you: what was left of the old bar plus what spilled into the new one
    if gain < 0 and lastXPMax and lvl and lastXPLevel and lvl > lastXPLevel then gain = (lastXPMax - lastXP) + xp end
    lastXP, lastXPMax, lastXPLevel = xp, max, lvl
    if gain <= 0 then return end
    Count("xp", gain)
    local function classify()
        local quest = Recent(lastQuestEvent, 2)
        -- With the combat log the KILL event comes first and this gain belongs to it. Without it the gain
        -- is how a kill is noticed at all, so an earlier kill must not swallow it.
        local kill = (not ns.NO_CLEU) and Recent(lastKillEvent, 3) or nil
        if quest then
            Count("xpQuest", gain)
            quest.xp = quest.xp or gain
        elseif kill then
            if not kill.xp then Count("xpKill", gain) end -- Modern.lua counts it when the kill line carries the xp
            kill.xp = kill.xp or gain
        elseif Now() - lastDiscoverT <= 3 then
            Count("xpOther", gain)
            Event("XP", { v = gain, src = "discover" })
        elseif ns.KillFromXP and ns.KillFromXP(gain) then
            -- No combat log: a gain in or right after combat is a kill (Modern.lua names the mob from your target)
            Count("xpKill", gain)
        else
            Count("xpOther", gain)
            Event("XP", { v = gain, src = "other" })
        end
    end
    -- Without the combat log, a quest turn-in or discovery line may land just after this event
    if ns.NO_CLEU then ns.After(0.5, classify) else classify() end
end)

-- "Discovered: Northshire Abbey"
ns.On("UI_INFO_MESSAGE", function(_, msg)
    if type(msg) == "string" and ns.TradeComplete and msg == (ERR_TRADE_COMPLETE or "Trade complete.") then ns.TradeComplete() end
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
    ns.After(1, function()
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
    local short = PlayerName(name)
    for _, m in ipairs(party) do
        if m:match("^([^:]+)") == short then return true end
    end
    return false
end

-- Guild roster names, so a buff from a guildie counts as a friend's even outside a party
local guildNames = {}
local function RefreshGuild()
    local n = Call("GetNumGuildMembers")
    if type(n) ~= "number" then return end
    local names = {}
    for i = 1, n do
        local name = Call("GetGuildRosterInfo", i)
        if name then names[PlayerName(name)] = true end
    end
    guildNames = names
end
ns.On("GUILD_ROSTER_UPDATE", RefreshGuild)
ns.On("PLAYER_ENTERING_WORLD", function()
    ns.After(6, function()
        if not (IsInGuild and IsInGuild()) then return end
        if C_GuildInfo and C_GuildInfo.GuildRoster then CallIn(C_GuildInfo, "GuildRoster") elseif GuildRoster then Call("GuildRoster") end
    end)
end)
local function IsFriend(name)
    local short = PlayerName(name)
    return short ~= nil and (InParty(short) or guildNames[short] == true)
end

local function OnCombatLog(...)
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags, _, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = ...
    -- Who in the group is fighting which mob, so a heal on them counts as a hand in the kill
    if DAMAGE[sub] and srcGUID ~= playerGUID and dstGUID ~= playerGUID then
        if IsGroupFlag(srcFlags) and ns.NpcId(dstGUID) then
            local foes = memberFoes[srcGUID]
            if not foes then foes = {}; memberFoes[srcGUID] = foes end
            foes[dstGUID] = Now()
        elseif IsGroupFlag(dstFlags) and ns.NpcId(srcGUID) then
            local foes = memberFoes[dstGUID]
            if not foes then foes = {}; memberFoes[dstGUID] = foes end
            foes[srcGUID] = Now()
        end
    end
    -- Damage suffix: amount, overkill, school, resisted, blocked, absorbed, critical. Spells and
    -- ranged carry a 3-field prefix (id, name, school) before it, swings none, environmental one.
    if dstGUID == playerGUID and DAMAGE[sub] then
        local spell, amt, crit
        if sub == "SWING_DAMAGE" then amt = a1; crit = a7
        elseif sub == "ENVIRONMENTAL_DAMAGE" then spell = a1; amt = a2; crit = a8; srcName = srcName or a1
        else spell = a2; amt = a4; crit = a10 end
        if type(amt) ~= "number" then amt = tonumber(amt) or 0 end
        local npc = ns.NpcId(srcGUID)
        lastHit = { src = srcName, npc = npc, spell = spell, amt = amt, lvl = LevelOf(srcGUID), t = Now(),
            player = IsPlayerOrPet(srcGUID) and srcGUID ~= playerGUID or nil }
        if sub == "ENVIRONMENTAL_DAMAGE" and type(a1) == "string" then
            local rec = ns.Tally("env", a1, a1)
            if rec then rec.d = (rec.d or 0) + amt end
        end
        if fight then fight.taken = fight.taken + amt end
        ns.Max("maxHitTaken", amt)
        ns.Record("hitTaken", amt, { who = srcName, spell = spell, crit = crit == true or nil })
        if crit == true then Count("critsTaken") end
        if npc then
            Engage(srcGUID)
            local rec = ns.Tally("hurtBy", npc, srcName)
            if rec then rec.d = (rec.d or 0) + amt end
        end
    elseif DAMAGE[sub] and ns.NpcId(dstGUID) and UnitGUID("pet") and srcGUID == UnitGUID("pet") then
        Engage(dstGUID)
        local amt = (sub == "SWING_DAMAGE") and a1 or a4
        Count("petDamage", tonumber(amt) or 0)
    elseif sub == "UNIT_DIED" and UnitGUID("pet") and dstGUID == UnitGUID("pet") then
        Count("petDeaths")
    elseif srcGUID == playerGUID and sub == "SPELL_AURA_APPLIED" and a4 == "BUFF" and dstGUID ~= playerGUID and IsPlayer(dstGUID) and dstName then
        local rec = ns.Tally("buffedTo", Short(dstName), Short(dstName))
        if rec and IsFriend(dstName) then rec.f = (rec.f or 0) + 1 end
    elseif srcGUID == playerGUID and DAMAGE[sub] then
        local amt, crit, spell
        if sub == "SWING_DAMAGE" then amt = a1; crit = a7; Count("swings")
        elseif sub == "RANGE_DAMAGE" then amt = a4; crit = a10; spell = a2; Count("shots")
        else amt = a4; crit = a10; spell = a2 end
        if type(amt) ~= "number" then amt = tonumber(amt) or 0 end
        Count("damageDone", amt)
        ns.Max("maxHitDone", amt)
        ns.Record("hitDone", amt, { who = dstName, spell = spell, crit = crit == true or nil })
        local sid = (sub == "SWING_DAMAGE") and "melee" or a1
        if sid then
            local rec = ns.Tally("damageBySpell", sid, spell or "Melee")
            if rec then rec.d = (rec.d or 0) + amt end
        end
        if dstName and ns.NpcId(dstGUID) then
            local rec = ns.Tally("damageTo", dstName, dstName)
            if rec then rec.d = (rec.d or 0) + amt end
        end
        if crit == true then Count("critsDone") end
        if ns.NpcId(dstGUID) then Engage(dstGUID) end
    elseif srcGUID == playerGUID and sub == "SWING_MISSED" then
        Count("swings")
        Count("swingMisses")
        if a1 == "DODGE" then Count("dodged") elseif a1 == "PARRY" then Count("parried") end
    elseif srcGUID == playerGUID and sub == "RANGE_MISSED" then
        Count("shots")
    elseif HEAL[sub] and (srcGUID == playerGUID or dstGUID == playerGUID) then
        local amt = (tonumber(a4) or 0) - (tonumber(a5 or 0) or 0) -- minus overheal
        if srcGUID == playerGUID then
            if fight then fight.healed = fight.healed + amt end
            ns.Record("healDone", amt, { who = dstName, spell = a2 })
            if dstGUID ~= playerGUID and IsPlayerOrPet(dstGUID) and dstName then
                local rec = ns.Tally("healedTo", Short(dstName), Short(dstName))
                if rec then rec.d = (rec.d or 0) + amt end
            end
            -- Healing a group member counts as a hand in whatever they were fighting in the last half minute
            local foes = dstGUID ~= playerGUID and memberFoes[dstGUID]
            if foes then
                local now = Now()
                for mob, t in pairs(foes) do
                    if now - t <= 30 then Engage(mob) else foes[mob] = nil end
                end
            end
        end
        if dstGUID == playerGUID and srcGUID ~= playerGUID then
            Count("healingTaken", amt)
            ns.Record("healTaken", amt, { who = srcName, spell = a2 })
            if IsPlayerOrPet(srcGUID) and srcName then
                local rec = ns.Tally("healedBy", Short(srcName), Short(srcName))
                if rec then rec.d = (rec.d or 0) + amt end
            end
        end
    elseif srcGUID == playerGUID and sub == "SPELL_INTERRUPT" then
        Count("interrupts")
    elseif srcGUID == playerGUID and sub == "SPELL_DISPEL" then
        Count("dispels")
    elseif sub == "SPELL_RESURRECT" and dstGUID == playerGUID and srcName then
        Count("rezzes")
        ns.Tally("rezBy", Short(srcName), Short(srcName))
    elseif dstGUID == playerGUID and sub == "SPELL_AURA_APPLIED" then
        if IsPlayerGUID(srcGUID) and srcGUID ~= playerGUID and a4 == "BUFF" then
            if srcName then
                local rec = ns.Tally("buffedBy", Short(srcName), Short(srcName))
                if rec and IsFriend(srcName) then rec.f = (rec.f or 0) + 1 end
            end
            if not IsFriend(srcName) then
                Count("strangerBuffs")
                ns.Tally("buffs", a1, a2)
            end
        end
    elseif sub == "PARTY_KILL" then
        local mine = srcGUID == playerGUID or (UnitGUID("pet") and srcGUID == UnitGUID("pet"))
        local npc = ns.NpcId(dstGUID)
        if not npc then
            -- Players: our own killing blows on another player are PvP kills (pets are not)
            if mine and type(dstGUID) == "string" and dstGUID:sub(1, 6) == "Player" and dstName then
                Count("pvpKills")
                ns.Tally("pvpKills", Short(dstName), Short(dstName))
                Event("PVP_KILL", { who = Short(dstName) })
            end
            return
        end
        -- A party member's kill counts as an assist when we had a hand in it: we hit it, it hit us,
        -- or we healed someone it was fighting. Kills we had nothing to do with are only counted.
        if not mine then
            local touched = engaged[dstGUID] and (Now() - engaged[dstGUID]) <= 120
            if not touched then
                Count("partyKills")
                return
            end
        end
        if memberFoes[dstGUID] then memberFoes[dstGUID] = nil end
        local e = { n = dstName, npc = npc, lvl = LevelOf(dstGUID) }
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

-- The combat log is not available to addons on modern clients (Forever, Retail 12.0+); Modern.lua
-- feeds the two entry points below from the events that remain.
if not ns.NO_CLEU then
    ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
        if CombatLogGetCurrentEventInfo then OnCombatLog(CombatLogGetCurrentEventInfo()) end
    end)
end
function ns.NoteKill(e)
    lastKillT = Now()
    if instance then instance.kills = instance.kills + 1 end
    lastKillEvent = Event("KILL", e)
    return lastKillEvent
end
function ns.InCombat() return fight ~= nil end
function ns.SinceCombat() return fightEndedT and (Now() - fightEndedT) or 1e9 end
function ns.NoteDamageTaken(amt, crit)
    if fight then fight.taken = fight.taken + amt end
    ns.Max("maxHitTaken", amt)
    if crit then Count("critsTaken") end
end

-- ---------------------------------------------------------
-- Fights
-- ---------------------------------------------------------
ns.On("PLAYER_REGEN_DISABLED", function()
    fight = { t0 = Now(), taken = 0, healed = 0 }
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    fightEndedT = Now()
    if not fight then return end
    local dur = Now() - fight.t0
    Count("fights")
    Count("fightSeconds", dur)
    Count("damageTaken", fight.taken)
    Count("healingDone", fight.healed)
    -- Short solo fights are noise for the replay; keep them in counters only
    if dur >= 20 or fight.healed > 0 or #party > 0 then
        ns.lastFightEvent = Event("FIGHT", { dur = dur, taken = fight.taken, healed = fight.healed, party = #party > 0 and ns.CopyArray(party) or nil })
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
    e.l = ns.level
    if ns.NO_CLEU and not lastHit and UnitExists and UnitExists("target") and UnitCanAttack("player", "target") then
        -- No combat log here: whoever you had targeted is the best available guess
        local name = ns.Str(UnitName("target"))
        if name then
            e.by, e.guess = name, true
            e.lvl = ns.Num(UnitLevel("target"))
            if e.lvl and e.lvl <= 0 then e.lvl = nil end
            if UnitIsPlayer("target") then
                e.pvp = true
                Count("pvpDeaths")
                ns.Tally("killedByPlayers", ns.ShortName(name), ns.ShortName(name))
            else
                local guid = ns.Str(UnitGUID("target"))
                e.npc = guid and ns.NpcId(guid) or nil
                if e.npc then ns.Tally("killers", e.npc, name) end
            end
        end
    end
    if lastHit and Now() - lastHit.t <= 15 then
        e.by, e.npc, e.spell, e.amt, e.lvl = lastHit.src, lastHit.npc, lastHit.spell, lastHit.amt, lastHit.lvl
        if lastHit.npc then ns.Tally("killers", lastHit.npc, lastHit.src) end
        if lastHit.player and lastHit.src then
            e.pvp = true
            Count("pvpDeaths")
            ns.Tally("killedByPlayers", Short(lastHit.src), Short(lastHit.src))
        end
    end
    local deathEvent = Event("DEATH", e)
    if ns.NO_CLEU and ns.ImproveDeath then ns.After(1.5, function() ns.ImproveDeath(deathEvent) end) end
    -- Wipe: everyone in the party dead a moment later
    if instance and #party > 0 then
        ns.After(3, function()
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

local function RosterDiff()
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
end

function ns.OnEnterWorld()
    playerGUID = UnitGUID("player")
    money = GetMoney()
    lastXP, lastXPMax, lastXPLevel = UnitXP("player"), ns.Num(Call("UnitXPMax", "player")), ns.level
    guildName = GetGuildInfo("player")
    ns.After(2, function()
        ZoneCheck()
        InstanceCheck()
    end)
    -- Party names arrive a moment after login; the first diff records who was already there
    ns.After(4, RosterDiff)
end

-- ---------------------------------------------------------
-- Party
-- ---------------------------------------------------------
ns.On("GROUP_ROSTER_UPDATE", function()
    RosterDiff()
    -- Names can still be "Unknown" on the first update; look again shortly
    ns.After(3, RosterDiff)
end)

-- ---------------------------------------------------------
-- Gold
-- ---------------------------------------------------------
ns.On("LOOT_OPENED", function() SetCtx("loot") end)
ns.On("TAXIMAP_OPENED", function() SetCtx("taxi") end)
for ctx, ev in pairs({ vendor = { "MERCHANT_SHOW", "MERCHANT_CLOSED" }, mail = { "MAIL_SHOW", "MAIL_CLOSED" },
    ah = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }, trainer = { "TRAINER_SHOW", "TRAINER_CLOSED" },
    bank = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED" } }) do
    ns.On(ev[1], function() OpenCtx(ctx) end)
    ns.On(ev[2], function() CloseCtx(ctx) end)
end
-- Trade gold moves just after the window closes, so closing it starts the 8 seconds again
ns.On("TRADE_SHOW", function() OpenCtx("trade") end)
ns.On("TRADE_CLOSED", function() if openCtx == "trade" then CloseCtx("trade"); SetCtx("trade") end end)
if hooksecurefunc and RepairAllItems then
    ns.Hook("RepairAllItems", function() SetCtx("repair") end)
end
local pendingFare = nil -- Copper paid at the flight master, picked up when the taxi starts

ns.On("PLAYER_MONEY", function()
    local now = GetMoney()
    if money == nil then money = now return end
    local delta = now - money
    money = now
    if delta == 0 then return end
    local ctx = Ctx()
    if ctx == "repair" and delta > 0 then ctx = openCtx or "other" end -- a sale right after repairing
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
    local link = msg:match("|c[^|]*|Hitem:.-|h%[.-%]|h|r") -- "|cff1eff00|Hitem" or the modern "|cnIQ2:|Hitem"
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

-- Reputation: read as standing deltas off the faction list (the chat line is hidden on modern clients).
-- Tally per faction; an event only when the standing itself changes (Neutral to Friendly).
local repSnap = nil
local repPending = false
local function FactionList()
    local out = {}
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
        local n = ns.Num(CallIn(C_Reputation, "GetNumFactions")) or 0
        for i = 1, n do
            local d = ns.Tbl(CallIn(C_Reputation, "GetFactionDataByIndex", i))
            if d and not d.isHeader and ns.Str(d.name) then
                out[d.name] = { v = ns.Num(d.currentStanding) or 0, s = ns.Num(d.reaction) }
            end
        end
    elseif GetNumFactions and GetFactionInfo then
        local n = Call("GetNumFactions") or 0
        for i = 1, n do
            local name, _, standingID, _, _, barValue, _, _, isHeader, _, hasRep = Call("GetFactionInfo", i)
            if name and (not isHeader or hasRep) then out[name] = { v = tonumber(barValue) or 0, s = standingID } end
        end
    end
    return out
end
local function RepDiff()
    repPending = false
    local now = FactionList()
    if repSnap then
        for name, cur in pairs(now) do
            local old = repSnap[name]
            if old and cur.v > old.v then
                local gain = cur.v - old.v
                Count("rep", gain)
                local rec = ns.Tally("rep", name, name)
                if rec then rec.d = (rec.d or 0) + gain end
                if cur.s and old.s and cur.s > old.s then Event("STANDING", { f = name, s = cur.s }) end
            end
        end
    end
    repSnap = now
end
ns.On("UPDATE_FACTION", function()
    if repPending then return end
    repPending = true
    ns.After(1, RepDiff)
end)
ns.On("PLAYER_ENTERING_WORLD", function() ns.After(4, RepDiff) end)

-- Collections (clients that have them): mounts, pets, toys, achievements
ns.On("NEW_MOUNT_ADDED", function(mountID)
    Count("mounts")
    local name = C_MountJournal and C_MountJournal.GetMountInfoByID and ns.Str((CallIn(C_MountJournal, "GetMountInfoByID", mountID)))
    Event("MOUNT", { id = ns.Num(mountID), n = name })
end)
ns.On("NEW_PET_ADDED", function() Count("pets") end)
ns.On("NEW_TOY_ADDED", function(itemID)
    Count("toys")
    local name = ns.ItemInfo(itemID)
    Event("TOY", { id = ns.Num(itemID), n = ns.Str(name) })
end)
ns.On("ACHIEVEMENT_EARNED", function(id)
    Count("achievements")
    local _, name = Call("GetAchievementInfo", id)
    Event("ACHIEVE", { id = ns.Num(id), n = ns.Str(name) })
end)

-- ---------------------------------------------------------
-- Hearthstone, taxi
-- ---------------------------------------------------------
local HEARTH_SPELLS = { [8690] = true, [556] = true } -- Hearthstone, Astral Recall
-- Attack, Auto Shot, Shoot (counted from the combat log instead) and LOGINEFFECT, which the game casts on you at login
ns.AUTO_SPELLS = { [6603] = true, [75] = true, [5019] = true, [836] = true }
local AUTO_SPELLS = ns.AUTO_SPELLS
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
    if AUTO_SPELLS[spellID] then return end
    local name = SpellName(spellID)
    if name == "Food" or name == "Drink" then return end -- eating is tracked on its own
    Count("casts")
    ns.Tally("spells", spellID, name)
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
    if not link then return end
    if MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown() then
        -- Right-clicking a bag item at a vendor sells it
        ns.Tally("sold", ns.ItemId(link), ns.LinkName(link), { q = ns.LinkQuality(link) })
        return
    end
    if TradingWindowOpen() then return end
    local equippable = ns.Equippable(link)
    if equippable then return end
    ns.Tally("used", ns.ItemId(link), ns.LinkName(link), { q = ns.LinkQuality(link) })
end
if hooksecurefunc then
    if C_Container and C_Container.UseContainerItem then
        ns.Hook(C_Container, "UseContainerItem", function(bag, slot)
            UsedItem(CallIn(C_Container, "GetContainerItemLink", bag, slot))
        end)
    elseif UseContainerItem then
        ns.Hook("UseContainerItem", function(bag, slot)
            UsedItem(Call("GetContainerItemLink", bag, slot))
        end)
    end
    if UseAction then
        ns.Hook("UseAction", function(slot)
            local kind, id = Call("GetActionInfo", slot)
            if kind == "item" and id then
                local _, link = ns.ItemInfo(id)
                if link then UsedItem(link) else ns.Tally("used", id, nil) end
            end
        end)
    end
    if BuyMerchantItem then
        ns.Hook("BuyMerchantItem", function(index, quantity)
            local link = Call("GetMerchantItemLink", index)
            if not link then return end
            local rec = ns.Tally("bought", ns.ItemId(link), ns.LinkName(link), { q = ns.LinkQuality(link) })
            if rec and type(quantity) == "number" and quantity > 1 then rec.n = rec.n + quantity - 1 end
        end)
    end
    if UseItemByName then
        ns.Hook("UseItemByName", function(name)
            local _, link = ns.ItemInfo(name)
            UsedItem(link)
        end)
    end
end

-- Taxi start and end are noticed by polling, since Classic has no clean event for the landing
local wasOnTaxi = false
ns.Ticker(2, function()
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
-- DUEL_FINISHED fires for declined requests too, so a duel only counts once the
-- "X has defeated Y in a duel" line arrives. A request with no such line is a request.
local duelResultT = 0
ns.On("DUEL_REQUESTED", function(name) lastDuel = { who = name, t = Now() } end)
ns.On("DUEL_FINISHED", function()
    local requested = lastDuel
    lastDuel = nil
    ns.After(3, function()
        if Now() - duelResultT <= 6 then return end -- a real duel, already recorded
        if requested then Count("duelRequests") end -- someone asked, we did not fight
    end)
end)
ns.On("CHAT_MSG_SYSTEM", function(msg)
    if type(msg) ~= "string" then return end
    if ns.TradeComplete and msg == (ERR_TRADE_COMPLETE or "Trade complete.") then ns.TradeComplete() return end
    local home = msg:match("^(.-) is now your home%.?$")
    if home then
        Count("binds")
        Event("BIND", { n = home })
        return
    end
    local winner, loser = msg:match("^(.-) has defeated (.-) in a duel")
    if not winner then
        winner, loser = msg:match("^(.-) has fled from (.-) in a duel")
        if winner then winner, loser = loser, winner end
    end
    if not winner then return end
    local me = UnitName("player")
    winner, loser = PlayerName(winner), PlayerName(loser)
    if winner ~= me and loser ~= me then return end -- someone else's duel nearby
    duelResultT = Now()
    Count("duels")
    Event("DUEL", { who = winner == me and loser or winner, won = (winner == me) })
end)
ns.On("PARTY_INVITE_REQUEST", function(name)
    Count("partyInvites")
end)

ns.On("PLAYER_GUILD_UPDATE", function(unit)
    if unit and unit ~= "player" then return end
    local name = GetGuildInfo("player")
    if name == nil and IsInGuild and IsInGuild() then return end -- guild info has not loaded yet
    -- Compared with what was saved, not with what this login has seen: the name is always "new" after a login
    local meta = ns.char and ns.char.meta
    if not meta or (name or false) == meta.guild then return end
    local first = meta.guild == nil and name == nil -- never in a guild: nothing to log
    meta.guild = name or false
    guildName = name
    if not first then Event("GUILD", { n = name }) end
end)

if JumpOrAscendStart and hooksecurefunc then
    ns.Hook("JumpOrAscendStart", function()
        if ns.char and not ns.paused and ns.Setting("countJumps") then Count("jumps") end
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
                local name = PlayerName(sender and Ambiguate and Ambiguate(sender, "short") or sender)
                if name == UnitName("player") then return end
                Count("gz")
                Event("GZ", { who = name, chan = chan })
                return
            end
        end
    end
end
-- Emotes you perform, by command word ("dance", "wave"). In chat your own emote reads "You burst into
-- dance.", with no name to match and no command word, so the call that sends it is counted instead. The
-- function moved on the modern client; where the old name still exists it passes the call along, and one
-- emote must not count twice. "read" is left out: the game performs it for you when you open the map.
do
    local lastToken, lastAt = nil, nil
    local function OnEmote(token)
        token = ns.Str(token)
        if not token or token == "" or not ns.char then return end
        token = token:lower()
        if token == "read" then return end
        local at = GetTime and GetTime() or Now()
        if token == lastToken and at == lastAt then return end
        lastToken, lastAt = token, at
        Count("emotes")
        ns.Tally("emotes", token, token)
    end
    if DoEmote then ns.Hook("DoEmote", OnEmote) end
    if C_ChatInfo and C_ChatInfo.PerformEmote then ns.Hook(C_ChatInfo, "PerformEmote", OnEmote) end
end

-- Messages you send, counted per channel (the text is never stored)
local function SentBy(sender)
    return PlayerName(sender) == UnitName("player")
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

-- ---------------------------------------------------------
-- Loot rolls, matched on the visible wording (English clients). Lines seen in game:
--   Greed Roll - 86 for [item] by Talenel Unbroken        every roll, when the client lists them
--   You won: [item]   /   Danwar won: [item]              the winner
--   Danwar (Need - 93, Main-Spec) Won: [item]             winner and roll in one line, when rolls are not listed
-- Modern clients put a "[Loot]: " link carrying a history id in front, which is stripped first. (Building
-- patterns from the client's own templates took that id for the player's name.)
-- ---------------------------------------------------------
local myLastRoll = nil
local function RollBody(msg)
    msg = msg:gsub("^|c%x%x%x%x%x%x%x%x", "")
    local body = msg:match("^|H.-|h.-|h:%s*(.*)$") or msg
    return (body:gsub("^%[Loot%]:%s*", ""))
end
local function Roller(name)
    if not name or name == "" or name:find("[|:%[%]]") then return nil end
    if name:lower() == "you" then return UnitName("player") end
    return PlayerName(name)
end
local function NoteRoll(who, roll)
    local rec = ns.Tally("rolls", who, who)
    if rec then
        rec.s = (rec.s or 0) + roll
        if roll > (rec.hi or 0) then rec.hi = roll end
    end
    if who == UnitName("player") then Count("rolls"); myLastRoll = roll end
    return rec
end
local function NoteWin(who, item, rec)
    rec = rec or ns.Tally("rolls", who, who)
    if rec then rec.w = (rec.w or 0) + 1 end
    if who == UnitName("player") then
        Count("rollsWon")
        Event("WON", { n = ns.LinkName(item) or item, q = ns.LinkQuality(item), roll = myLastRoll })
        myLastRoll = nil
    end
end
ns.On("CHAT_MSG_LOOT", function(msg)
    msg = ns.Str(msg)
    if not msg then return end
    local body = RollBody(msg)
    -- A roll
    local kind, roll, item, who = body:match("^(%a+) Roll %- (%d+) for (.+) by (.+)$")
    if kind then
        who = Roller(who)
        if who then NoteRoll(who, tonumber(roll)) end
        return
    end
    -- Winner and roll in one line
    who, kind, roll, item = body:match("^(.-) %((%a+) %- (%d+)[^%)]*%) Won: (.+)$")
    if who then
        who = Roller(who)
        if who then NoteWin(who, item, NoteRoll(who, tonumber(roll))) end
        return
    end
    -- The winner of rolls that were listed one by one
    who, item = body:match("^(.-) won: (.+)$")
    who = Roller(who)
    if not who or not item then return end
    local rec = ns.Tally("rolls", who, who)
    if rec then rec.n = rec.n - 1 end -- a win is not another roll
    NoteWin(who, item, rec)
end)

-- ---------------------------------------------------------
-- Trades: snapshot the window as it changes, commit on "Trade complete."
-- ---------------------------------------------------------
local tradeSnap = nil
local function SnapTrade()
    local who = Short(UnitName("NPC"))
    if not who then return end
    local gave, got = {}, {}
    for i = 1, 6 do
        local l = Call("GetTradePlayerItemLink", i)
        if l then tinsert(gave, ns.LinkName(l) or "?") end
        l = Call("GetTradeTargetItemLink", i)
        if l then tinsert(got, ns.LinkName(l) or "?") end
    end
    tradeSnap = { who = who, gave = gave, got = got,
        go = tonumber(Call("GetPlayerTradeMoney")) or 0, gi = tonumber(Call("GetTargetTradeMoney")) or 0, t = Now() }
end
for _, ev in ipairs({ "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_MONEY_CHANGED" }) do
    ns.On(ev, SnapTrade)
end
ns.On("TRADE_CLOSED", function() ns.After(2, function() tradeSnap = nil end) end)
function ns.TradeComplete()
    local s = tradeSnap
    tradeSnap = nil
    if not s or Now() - s.t > 120 then return end
    Count("trades")
    local rec = ns.Tally("trades", s.who, s.who)
    if rec then
        rec.i = (rec.i or 0) + #s.got
        rec.o = (rec.o or 0) + #s.gave
        rec.gi = (rec.gi or 0) + s.gi
        rec.go = (rec.go or 0) + s.go
    end
    Event("TRADE", { who = s.who, gave = #s.gave > 0 and s.gave or nil, got = #s.got > 0 and s.got or nil,
        gi = s.gi > 0 and s.gi or nil, go = s.go > 0 and s.go or nil })
end

-- ---------------------------------------------------------
-- Mail: items taken from the inbox (by sender), mail sent (by recipient). Auction sales arrive as mail.
-- ---------------------------------------------------------
local AH_SOLD_PAT = Pat(AUCTION_SOLD_MAIL_SUBJECT or "Auction successful: %s")
-- Money from one mail must be credited once even if two hooks fire for it (auto-loot, then take money),
-- while five identical "Auction successful" mails from one lot sale must each count. The key includes the
-- inbox slot and the mail's own expiry, and the table is cleared whenever the inbox changes.
local seenMail = {}
ns.On("MAIL_INBOX_UPDATE", function() seenMail = {} end)
local function InboxItem(index, link)
    if not link then return end
    local _, _, sender, subject = Call("GetInboxHeaderInfo", index)
    sender = Short(sender) or "?"
    Count("mailItemsIn")
    local rec = ns.Tally("mailFrom", sender, sender)
    if rec and subject and subject:match(AH_SOLD_PAT) then rec.ah = (rec.ah or 0) + 1 end
end
local function InboxMoney(index)
    local _, _, sender, subject, money, _, daysLeft = Call("GetInboxHeaderInfo", index)
    if type(subject) ~= "string" or not subject:match(AH_SOLD_PAT) then return end
    local key = table.concat({ tostring(index), tostring(sender), subject, tostring(money), tostring(daysLeft) }, "|")
    if seenMail[key] then return end
    seenMail[key] = true
    Count("ahSold")
    Count("ahSoldGold", tonumber(money) or 0)
end
if hooksecurefunc then
    if TakeInboxItem then
        ns.Hook("TakeInboxItem", function(index, itemIndex) InboxItem(index, Call("GetInboxItemLink", index, itemIndex)) end)
    end
    if TakeInboxMoney then ns.Hook("TakeInboxMoney", function(index) InboxMoney(index) end) end
    if AutoLootMailItem then
        ns.Hook("AutoLootMailItem", function(index)
            for i = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do InboxItem(index, Call("GetInboxItemLink", index, i)) end
            InboxMoney(index)
        end)
    end
    if SendMail then
        ns.Hook("SendMail", function(recipient)
            local to = PlayerName(recipient)
            if not to or to == "" then return end
            local items = 0
            for i = 1, (ATTACHMENTS_MAX_SEND or 12) do
                if Call("GetSendMailItemLink", i) then items = items + 1 end
            end
            local gold = tonumber(Call("GetSendMailMoney")) or 0
            Count("mailSent")
            local rec = ns.Tally("mailTo", to, to)
            if rec then rec.i = (rec.i or 0) + items; rec.g = (rec.g or 0) + gold end
            Event("MAIL", { to = to, items = items > 0 and items or nil, gold = gold > 0 and gold or nil })
        end)
    end

    -- Auction house (the Classic API; Retail's C_AuctionHouse is not covered)
    if PlaceAuctionBid and GetAuctionItemInfo then
        ns.Hook("PlaceAuctionBid", function(kind, index, bid)
            local name, _, count, quality, _, _, _, _, _, buyout, _, _, _, _, _, _, itemId = Call("GetAuctionItemInfo", kind, index)
            if not name then return end
            bid = tonumber(bid) or 0
            Count("ahSpent", bid)
            if buyout and buyout > 0 and bid >= buyout then Count("ahBuyouts") else Count("ahBids") end
            local rec = ns.Tally("ahBought", itemId or name, name, { q = quality })
            if rec then rec.n = rec.n + (tonumber(count) or 1) - 1; rec.c = (rec.c or 0) + bid end
        end)
    end
    local function Posted(minBid, buyout, runTime, stackSize, numStacks)
        local name, _, count, quality = Call("GetAuctionSellItemInfo")
        if not name then return end
        local total = (tonumber(stackSize) or tonumber(count) or 1) * (tonumber(numStacks) or 1)
        Count("ahPosted")
        local rec = ns.Tally("ahPosted", name, name, { q = quality })
        if rec then rec.n = rec.n + total - 1 end
    end
    if PostAuction then ns.Hook("PostAuction", Posted) elseif StartAuction then ns.Hook("StartAuction", Posted) end

    -- Modern auction house (Forever, Retail): C_AuctionHouse
    if C_AuctionHouse then
        local function LocLink(loc)
            if type(loc) ~= "table" then return nil end
            if C_Item and C_Item.GetItemLink then return ns.CallIn(C_Item, "GetItemLink", loc) end
        end
        local function PostedModern(loc, duration, quantity)
            local link = LocLink(loc)
            local name = link and ns.LinkName(link) or "item"
            Count("ahPosted")
            local rec = ns.Tally("ahPosted", name, name, { q = link and ns.LinkQuality(link) or nil })
            if rec then rec.n = rec.n + (tonumber(quantity) or 1) - 1 end
        end
        if C_AuctionHouse.PostItem then ns.Hook(C_AuctionHouse, "PostItem", PostedModern) end
        if C_AuctionHouse.PostCommodity then ns.Hook(C_AuctionHouse, "PostCommodity", PostedModern) end
        -- Buying a stackable item is two calls: Start asks for a price, Confirm buys. Only Confirm is a
        -- purchase; the price is the quote the game sent back in between.
        local quote = nil -- { total, t }
        ns.On("COMMODITY_PRICE_UPDATED", function(_, total)
            total = ns.Num(total)
            quote = total and { total = total, t = Now() } or nil
        end)
        local function BoughtCommodity(itemID, quantity)
            local name = ns.ItemInfo(itemID)
            local cost = quote and (Now() - quote.t) <= 120 and quote.total or 0
            quote = nil
            Count("ahBuyouts")
            if cost > 0 then Count("ahSpent", cost) end
            local rec = ns.Tally("ahBought", itemID, name)
            if rec then
                rec.n = rec.n + (tonumber(quantity) or 1) - 1
                if cost > 0 then rec.c = (rec.c or 0) + cost end
            end
        end
        if C_AuctionHouse.ConfirmCommoditiesPurchase then
            ns.Hook(C_AuctionHouse, "ConfirmCommoditiesPurchase", BoughtCommodity)
        elseif C_AuctionHouse.StartCommoditiesPurchase then
            ns.Hook(C_AuctionHouse, "StartCommoditiesPurchase", BoughtCommodity)
        end
        if C_AuctionHouse.PlaceBid then
            ns.Hook(C_AuctionHouse, "PlaceBid", function(auctionID, bid)
                Count("ahBids")
                Count("ahSpent", tonumber(bid) or 0)
            end)
        end
    end
end

-- Whispers per person: who, how many each way. Never the text.
ns.On("CHAT_MSG_WHISPER", function(msg, sender)
    local who = PlayerName(ns.Str(sender))
    if not who or who == "" then return end
    local rec = ns.Tally("whispers", who, who)
    if rec then rec.i = (rec.i or 0) + 1 end
end)
ns.On("CHAT_MSG_WHISPER_INFORM", function(msg, target)
    local who = PlayerName(ns.Str(target))
    if not who or who == "" then return end
    local rec = ns.Tally("whispers", who, who)
    if rec then rec.o = (rec.o or 0) + 1 end
end)

-- "Inventory is full", "Spell is not ready yet", "Out of range": the game's red text, counted by message
ns.On("UI_ERROR_MESSAGE", function(a, b)
    local msg = type(b) == "string" and b or (type(a) == "string" and a) or nil
    if not msg or #msg == 0 or #msg > 60 then return end
    ns.Tally("errors", msg, msg)
end)
ns.On("SCREENSHOT_SUCCEEDED", function() Count("screenshots") end)

-- Appearance collection (clients that have one): the event counts, the chat line supplies the name
local lastLook = nil
ns.On("TRANSMOG_COLLECTION_SOURCE_ADDED", function(sourceID)
    Count("appearances")
    local id, name, item = ns.Num(sourceID), nil, nil
    if id and C_TransmogCollection and C_TransmogCollection.GetSourceInfo then
        local info = ns.Tbl(CallIn(C_TransmogCollection, "GetSourceInfo", id))
        if info then
            name, item = ns.Str(info.name), ns.Num(info.itemID)
            if not name and item then name = ns.Str((ns.ItemInfo(item))) end
        end
    end
    lastLook = Event("LOOK", { id = id, n = name, i = item })
end)
local function LookLine(msg)
    msg = ns.Str(msg)
    if not msg or not msg:find("has been added to your appearance collection", 1, true) then return end
    local name = ns.LinkName(msg)
    if not name then return end
    if lastLook and Now() - lastLook.t <= 3 and not lastLook.n then
        lastLook.n = name
    elseif not (lastLook and Now() - lastLook.t <= 3) then
        Count("appearances") -- no event on this client: the line is all we have
        lastLook = Event("LOOK", { n = name })
    end
end
ns.On("CHAT_MSG_SYSTEM", LookLine)
ns.On("CHAT_MSG_LOOT", LookLine)
ns.On("PLAYER_PVP_KILLS_CHANGED", function() Count("honorKills") end)

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
    for _, name in ipairs(ns.PlayerBuffNames()) do
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
    ns.After(2, InstanceCheck)
end)

ns.LOADED.Events = true
