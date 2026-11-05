local ADDON_NAME, ns = ...

-- =========================================================
-- METER: the game's own damage meter (C_DamageMeter), read after each fight
-- =========================================================
-- Modern clients (Forever, Retail 12.0+) have a built-in damage meter whose data addons may
-- read once combat ends (it is "secret" while the fight runs). This gives back most of what
-- the combat log used to: your damage and healing by ability and by target, who hit you, who
-- healed you and whom you healed, interrupts, dispels, absorbs, and every group member's
-- damage and healing per fight. Classic Era has no meter and no need for one.
ns.HAS_METER = C_DamageMeter ~= nil and type(C_DamageMeter.GetCombatSessionFromType) == "function"
if not ns.HAS_METER then return end

local Count, Now, CallIn, Short = ns.Count, ns.Now, ns.CallIn, ns.ShortName
local Num, Str = ns.Num, ns.Str

local ST = (Enum and Enum.DamageMeterSessionType) or {}
local MT = (Enum and Enum.DamageMeterType) or {}
local CURRENT = ST.Current or 1
local T = {
    DamageDone = MT.DamageDone or 0, HealingDone = MT.HealingDone or 2, Absorbs = MT.Absorbs or 4,
    Interrupts = MT.Interrupts or 5, Dispels = MT.Dispels or 6, DamageTaken = MT.DamageTaken or 7,
}

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return CallIn(C_Spell, "GetSpellName", id) end
    return ns.Call("GetSpellInfo", id)
end

local function Session(kind)
    return CallIn(C_DamageMeter, "GetCombatSessionFromType", CURRENT, kind)
end
local function Source(kind, guid)
    return CallIn(C_DamageMeter, "GetCombatSessionSourceFromType", CURRENT, kind, guid)
end

-- Adds amount to a tally record's d field; returns false if the amount was secret
local function AddD(group, id, name, amt)
    amt = Num(amt)
    if amt == nil then return false end
    local rec = ns.Tally(group, id, name)
    if rec then rec.d = (rec.d or 0) + amt end
    return true
end

local lastKey = nil
local attempts = 0

-- Returns true when done (data read, or nothing to read), false to retry (still secret)
local function ReadFight(fightEvent, fightDur)
    local ok, avail = pcall(function()
        if C_DamageMeter.IsDamageMeterAvailable then return (CallIn(C_DamageMeter, "IsDamageMeterAvailable")) end
        return true
    end)
    if ok and avail == false then return true end

    local dmg = Session(T.DamageDone)
    if type(dmg) ~= "table" or type(dmg.combatSources) ~= "table" then return true end
    local dur = Num(dmg.durationSeconds)
    if dur == nil then return false end -- still secret
    if #dmg.combatSources == 0 then return true end -- nothing was recorded for this combat

    -- The same fight must not be counted twice: fingerprint it
    local me, meGUID = nil, nil
    local groupTotal = 0
    local sources = {}
    local myName, myGUID = Str(UnitName("player")), Str(UnitGUID("player"))
    for _, src in ipairs(dmg.combatSources) do
        local total = Num(src.totalAmount)
        if total == nil then return false end
        local name = Str(src.name)
        local guid = Str(src.sourceGUID)
        local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and Short(name) == myName)
        tinsert(sources, { name = name, guid = guid, total = total, me = isMe })
        groupTotal = groupTotal + total
        if isMe then me, meGUID = src, guid end
    end
    -- Alone with a single source and no way to tell: it is us
    if not me and #sources == 1 and not IsInGroup() then me, meGUID = dmg.combatSources[1], sources[1].guid; sources[1].me = true end
    if meGUID == nil then meGUID = myGUID end
    if ns.debug then ns.Print(string.format("meter: %d sources, me=%s, dur=%d", #sources, me and "yes" or "no", dur)) end
    local key = string.format("%d|%d|%d", math.floor(dur), math.floor(groupTotal), #sources)
    if key == lastKey then return true end
    lastKey = key

    local myDamage = me and Num(me.totalAmount) or 0
    Count("damageDone", myDamage)
    Count("meterFights")
    if fightEvent then
        fightEvent.done = myDamage
        if #sources > 1 and groupTotal > 0 then fightEvent.share = math.floor(myDamage * 100 / groupTotal + 0.5) end
    end

    -- Group members' damage this fight (every source that is not us)
    if #sources > 1 then
        for _, s in ipairs(sources) do
            if not s.me and s.name then
                local rec = ns.Tally("groupDmg", Short(s.name), Short(s.name))
                if rec then rec.d = (rec.d or 0) + s.total end
            end
        end
    end

    -- My damage by ability and by target
    local mine = meGUID and Source(T.DamageDone, meGUID)
    if type(mine) == "table" and type(mine.combatSpells) == "table" then
        for _, sp in ipairs(mine.combatSpells) do
            local id = Num(sp.spellID)
            local amt = Num(sp.totalAmount)
            local target = Str(sp.creatureName)
            if id and amt then
                AddD("damageBySpell", id, SpellName(id), amt)
                if target and target ~= "" then
                    AddD("damageTo", target, target, amt)
                    if ns.Engaged then ns.Engaged(target) end
                end
                local over = Num(sp.overkillAmount)
                if over and over > 0 then Count("overkill", over) end
            end
        end
    end

    -- Healing: mine by ability and target, others' healing on me
    local heal = Session(T.HealingDone)
    if type(heal) == "table" and type(heal.combatSources) == "table" then
        local myName = Str(UnitName("player"))
        for _, src in ipairs(heal.combatSources) do
            local total = Num(src.totalAmount) or 0
            local guid = Str(src.sourceGUID)
            local name = Str(src.name)
            local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and Short(name) == myName)
            if isMe then
                guid = guid or myGUID
                Count("healingDone", total)
                if fightEvent then fightEvent.healed = total end
                local det = guid and Source(T.HealingDone, guid)
                if type(det) == "table" and type(det.combatSpells) == "table" then
                    for _, sp in ipairs(det.combatSpells) do
                        local id, amt, target = Num(sp.spellID), Num(sp.totalAmount), Str(sp.creatureName)
                        if id and amt then
                            AddD("healBySpell", id, SpellName(id), amt)
                            if target and target ~= "" and target ~= myName then AddD("healedTo", Short(target), Short(target), amt) end
                        end
                    end
                end
            elseif name then
                local rec = ns.Tally("groupHeal", Short(name), Short(name))
                if rec then rec.d = (rec.d or 0) + total end
                -- Did they heal me? Their per-target breakdown says
                local det = guid and Source(T.HealingDone, guid)
                if type(det) == "table" and type(det.combatSpells) == "table" then
                    for _, sp in ipairs(det.combatSpells) do
                        local amt, target = Num(sp.totalAmount), Str(sp.creatureName)
                        if amt and target and myName and Short(target) == myName then AddD("healedBy", Short(name), Short(name), amt) end
                    end
                end
            end
        end
    end

    -- Damage taken: total and by attacker
    local taken = Session(T.DamageTaken)
    if type(taken) == "table" and type(taken.combatSources) == "table" then
        for _, src in ipairs(taken.combatSources) do
            local guid = Str(src.sourceGUID)
            local name = Str(src.name)
            local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and Short(name) == myName)
            if isMe then
                local total = Num(src.totalAmount) or 0
                Count("damageTaken", total)
                if fightEvent then fightEvent.taken = total end
                guid = guid or myGUID
                local det = guid and Source(T.DamageTaken, guid)
                if type(det) == "table" and type(det.combatSpells) == "table" then
                    for _, sp in ipairs(det.combatSpells) do
                        local amt, who = Num(sp.totalAmount), Str(sp.creatureName)
                        if amt and who and who ~= "" then AddD("hurtBy", who, who, amt) end
                    end
                end
            end
        end
    end

    -- Interrupts, dispels, absorbs: my totals
    for _, pair in ipairs({ { T.Interrupts, "interrupts" }, { T.Dispels, "dispels" }, { T.Absorbs, "absorbs" } }) do
        local s = Session(pair[1])
        if type(s) == "table" and type(s.combatSources) == "table" then
            for _, src in ipairs(s.combatSources) do
                local guid, name = Str(src.sourceGUID), Str(src.name)
                if src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and Short(name) == myName) then
                    Count(pair[2], Num(src.totalAmount) or 0)
                end
            end
        end
    end
    return true
end

local function Poll(fightEvent, fightDur)
    local ok, done = pcall(ReadFight, fightEvent, fightDur)
    if not ok and ns.debug then ns.Print("meter error: " .. tostring(done)) end
    if ok and done then return end
    attempts = attempts + 1
    if attempts >= 15 then return end -- about 9 seconds; the meter stayed secret (pvp, or a new fight started)
    C_Timer.After(0.6, function() Poll(fightEvent, fightDur) end)
end

-- /hl meter: what the game's meter holds right now, field by field, for the person reading the screenshot
function ns.MeterDump()
    local P = ns.Print
    local ok, avail, why = pcall(function() return CallIn(C_DamageMeter, "IsDamageMeterAvailable") end)
    P(string.format("meter available: %s %s", tostring(avail), tostring(why or "")))
    local s = Session(T.DamageDone)
    if type(s) ~= "table" then P("no DamageDone session: " .. tostring(s)) return end
    P(string.format("DamageDone: %d sources, duration %s, total %s", type(s.combatSources) == "table" and #s.combatSources or -1,
        tostring(s.durationSeconds), tostring(s.totalAmount)))
    for i, src in ipairs(s.combatSources or {}) do
        local secret = (type(issecretvalue) == "function" and issecretvalue(src.totalAmount)) and " (secret)" or ""
        P(string.format("  %d: name=%s local=%s total=%s%s guid=%s", i, tostring(src.name), tostring(src.isLocalPlayer), tostring(src.totalAmount), secret, tostring(src.sourceGUID)))
        local det = Source(T.DamageDone, Str(src.sourceGUID) or Str(UnitGUID("player")))
        if type(det) == "table" and type(det.combatSpells) == "table" then
            for j, sp in ipairs(det.combatSpells) do
                if j > 4 then break end
                P(string.format("     spell %s %s on %s", tostring(sp.spellID), tostring(sp.totalAmount), tostring(sp.creatureName)))
            end
        else
            P("     per-spell: " .. tostring(det))
        end
    end
    P(string.format("lastKey=%s attempts=%d", tostring(lastKey), attempts))
end

ns.On("PLAYER_REGEN_ENABLED", function()
    attempts = 0
    local e = ns.lastFightEvent
    ns.lastFightEvent = nil
    C_Timer.After(0.6, function() Poll(e) end)
end)
