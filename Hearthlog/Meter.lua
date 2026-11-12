local ADDON_NAME, ns = ...

-- =========================================================
-- METER: the game's own damage meter (C_DamageMeter), read after each fight
-- =========================================================
-- Modern clients (Forever, Retail 12.0+) have a built-in damage meter whose data addons may
-- read once combat ends (it is "secret" while the fight runs). This gives back most of what
-- the combat log used to: your damage and healing by ability and by target, who hit you, who
-- healed you and whom you healed, interrupts, dispels, absorbs, and every group member's
-- damage and healing per fight. It is only read where the combat log is gone: a client that has
-- both (the meter reached the Classic clients too) keeps using the log, or everything would count twice.
ns.HAS_METER = ns.NO_CLEU == true and C_DamageMeter ~= nil and type(C_DamageMeter.GetCombatSessionFromType) == "function"
ns.LOADED.Meter = true
if not ns.HAS_METER then return end

local Count, Now, CallIn, Short = ns.Count, ns.Now, ns.CallIn, ns.ShortName
local Num, Str = ns.Num, ns.Str

local ST = (Enum and Enum.DamageMeterSessionType) or {}
local MT = (Enum and Enum.DamageMeterType) or {}
local CURRENT = ST.Current or 1
local T = {
    DamageDone = MT.DamageDone or 0, HealingDone = MT.HealingDone or 2, Absorbs = MT.Absorbs or 4,
    Interrupts = MT.Interrupts or 5, Dispels = MT.Dispels or 6, DamageTaken = MT.DamageTaken or 7,
    Avoidable = MT.AvoidableDamageTaken or 8, Deaths = MT.Deaths or 9, EnemyTaken = MT.EnemyDamageTaken or 10,
}

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return CallIn(C_Spell, "GetSpellName", id) end
    return ns.Call("GetSpellInfo", id)
end

local function Session(kind)
    return CallIn(C_DamageMeter, "GetCombatSessionFromType", CURRENT, kind)
end
local function Source(kind, guid, creatureID)
    return CallIn(C_DamageMeter, "GetCombatSessionSourceFromType", CURRENT, kind, guid, creatureID)
end
-- Who a per-ability row is about. Depending on the view the meter puts that in creatureName or in the
-- row's unit details, and for your own damage done it gives neither.
local function RowUnit(sp)
    local n = Str(sp.creatureName)
    if n and n ~= "" then return n end
    local d = ns.Tbl(sp.combatSpellDetails)
    n = d and Str(d.unitName)
    if n and n ~= "" then return n end
    return nil
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

-- The meter's own id for the fight it is showing, taken from its update event (type, sessionID). It goes
-- into the fingerprint below so that two fights with the same length and damage are still two fights.
local sessionID = nil
ns.On("DAMAGE_METER_COMBAT_SESSION_UPDATED", function(_, id)
    id = Num(id)
    if id then sessionID = id end
end)

-- The meter shows display names ("Talenel Unbroken"); every other list uses the plain character name.
-- A meter name is mapped back to you or a group member by GUID when there is one, else by whole word.
local function Roster()
    local r = { byGuid = {}, names = {} }
    local function add(unit)
        local name = Str(UnitName(unit))
        if not name then return end
        local guid = Str(UnitGUID(unit))
        if guid then r.byGuid[guid] = name end
        tinsert(r.names, name)
    end
    add("player")
    local prefix, count = "party", Num(GetNumSubgroupMembers()) or 0
    if IsInRaid() then prefix, count = "raid", Num(GetNumGroupMembers()) or 0 end
    for i = 1, count do add(prefix .. i) end
    return r
end
local function Plain(roster, name, guid)
    if guid and roster.byGuid[guid] then return roster.byGuid[guid] end
    if not name then return nil end
    local short = Short(name)
    for _, n in ipairs(roster.names) do
        if short == n then return n end
    end
    local padded = " " .. short .. " "
    for _, n in ipairs(roster.names) do
        if padded:find(" " .. n .. " ", 1, true) then return n end
    end
    return ns.PlayerName(short) -- not in the group any more: still filed under the first name
end
-- Is this meter name you or someone in your group?
local function InGroup(roster, name, guid)
    if guid and roster.byGuid[guid] then return true end
    local plain = Plain(roster, name)
    for _, n in ipairs(roster.names) do
        if n == plain then return true end
    end
    return false
end

-- Returns true when done (data read, or nothing to read), false to retry (still secret)
local function ReadFight(fightEvent, fightDur)
    local ok, avail = pcall(function()
        if C_DamageMeter.IsDamageMeterAvailable then return (CallIn(C_DamageMeter, "IsDamageMeterAvailable")) end
        return true
    end)
    if ok and avail == false then return true end

    local dmg = ns.Tbl(Session(T.DamageDone))
    if not dmg then return false end -- secret or missing: try again
    if not ns.Tbl(dmg.combatSources) then return false end
    local dur = Num(dmg.durationSeconds)
    if dur == nil then return false end -- still secret
    -- No damage sources does not mean nothing happened: a fight you ran through without hitting back still
    -- has damage taken and healing, and those are read below.

    -- The same fight must not be counted twice: fingerprint it
    local me, meGUID = nil, nil
    local groupTotal = 0
    local sources = {}
    local myName, myGUID = Str(UnitName("player")), Str(UnitGUID("player"))
    local roster = Roster()
    for _, src in ipairs(dmg.combatSources) do
        local total = Num(src.totalAmount)
        if total == nil then return false end
        local guid = Str(src.sourceGUID)
        -- A boss that turns a player on the group is listed among the damage dealers. It is not one of us:
        -- it stays out of the group's total, the shares and the group list.
        local creature = (Num(src.sourceCreatureID) or 0) > 0 or (guid ~= nil and guid:sub(1, 6) ~= "Player")
        if not creature then
            local name = Plain(roster, Str(src.name), guid)
            local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and name == myName)
            tinsert(sources, { name = name, guid = guid, total = total, me = isMe, src = src })
            groupTotal = groupTotal + total
            if isMe then me, meGUID = src, guid end
        end
    end
    -- Alone with a single source and no way to tell: it is us
    if not me and #sources == 1 and not IsInGroup() then me, meGUID = sources[1].src, sources[1].guid; sources[1].me = true end
    if meGUID == nil then meGUID = myGUID end
    if ns.debug then ns.Print(string.format("meter: %d sources, me=%s, dur=%d", #sources, me and "yes" or "no", dur)) end
    local key = string.format("%s|%d|%d|%d", tostring(sessionID or "?"), math.floor(dur), math.floor(groupTotal), #sources)
    -- With no damage dealt there is nothing in the fingerprint to tell two fights apart, so the time goes in
    if #sources == 0 then key = key .. "|" .. tostring(fightEvent and fightEvent.t or Now()) end
    if key == lastKey then return true end
    lastKey = key

    local myDamage = me and Num(me.totalAmount) or 0
    local gotSomething = #sources > 0 -- a fight counts as read once any view had something in it
    Count("damageDone", myDamage)
    if fightEvent and gotSomething then
        fightEvent.done = myDamage
        if #sources > 1 and groupTotal > 0 then fightEvent.share = math.floor(myDamage * 100 / groupTotal + 0.5) end
    end

    -- Group members' damage this fight (every source that is not us)
    if #sources > 1 then
        for _, s in ipairs(sources) do
            if not s.me and s.name then
                local rec = ns.Tally("groupDmg", s.name, s.name)
                if rec then rec.d = (rec.d or 0) + s.total end
            end
        end
    end

    -- My damage by ability and by target
    local mine = meGUID and Source(T.DamageDone, meGUID)
    mine = ns.Tbl(mine)
    local gotTargets = false
    if mine and ns.Tbl(mine.combatSpells) then
        for _, sp in ipairs(mine.combatSpells) do
            local id = Num(sp.spellID)
            local amt = Num(sp.totalAmount)
            local target = RowUnit(sp)
            if id and amt then
                AddD("damageBySpell", id, SpellName(id), amt)
                if target then
                    gotTargets = true
                    AddD("damageTo", target, target, amt)
                    if ns.Engaged then ns.Engaged(target) end
                end
                local over = Num(sp.overkillAmount)
                if over and over > 0 then Count("overkill", over) end
            end
        end
    end

    -- Who took the damage. The rows above carry no target, but the meter's "enemy damage taken" view has
    -- one source per kind of enemy. Alone, what an enemy took is what we dealt; in a group each enemy is
    -- broken down by who hit it and only our part is ours.
    local foes = {}
    local view = ns.Tbl(Session(T.EnemyTaken))
    for _, src in ipairs(view and ns.Tbl(view.combatSources) or {}) do
        if ns.InstNote then ns.InstNote("foeName", src.name); ns.InstNote("foeId", src.sourceCreatureID) end
        local foe, id, total = Str(src.name), Num(src.sourceCreatureID), Num(src.totalAmount)
        if foe == "" then foe = nil end
        -- The same boss trick from the other side: the player it turned is listed among the enemies
        local ours = id == nil and foe ~= nil and InGroup(roster, foe, Str(src.sourceGUID))
        if total and total > 0 and (foe or id) and not ours then
            local part = nil
            if #sources == 1 and not IsInGroup() then
                part = total
            else
                local det = ns.Tbl(Source(T.EnemyTaken, Str(src.sourceGUID), id))
                for _, sp in ipairs(det and ns.Tbl(det.combatSpells) or {}) do
                    local d = ns.Tbl(sp.combatSpellDetails)
                    if d and Plain(roster, Str(d.unitName)) == myName then
                        local amt = Num(d.amount)
                        if not amt or amt <= 0 then amt = Num(sp.totalAmount) end
                        if amt then part = (part or 0) + amt end
                    end
                end
            end
            local cls = Str(src.classification)
            tinsert(foes, { n = foe, id = id, d = total, m = part, c = (cls ~= nil and cls ~= "" and cls ~= "normal") and cls or nil })
        end
    end
    if not gotTargets and myDamage > 0 then
        for _, f in ipairs(foes) do
            if f.n and f.m and f.m > 0 then
                AddD("damageTo", f.n, f.n, math.min(f.m, myDamage))
                if ns.Engaged then ns.Engaged(f.n) end
            end
        end
    end
    if #foes > 0 then
        -- Kills logged during this fight without a name get one from this list
        if ns.NameKills then ns.NameKills(foes, fightEvent and fightEvent.t and (fightEvent.t - dur - 3) or nil) end
        -- A group fight keeps the list (the six biggest): in a dungeon it is the only record of what was
        -- fought, and it says which fights were the bosses
        if fightEvent and (IsInGroup() or (IsInInstance and (IsInInstance()) == true)) then
            table.sort(foes, function(x, y) return x.d > y.d end)
            fightEvent.foes = {}
            for i = 1, math.min(#foes, 6) do fightEvent.foes[i] = foes[i] end
        end
    end

    -- Healing: mine by ability and target, others' healing on me
    local heal = ns.Tbl(Session(T.HealingDone))
    if heal and ns.Tbl(heal.combatSources) then
        for _, src in ipairs(heal.combatSources) do
            local total = Num(src.totalAmount) or 0
            local guid = Str(src.sourceGUID)
            local name = Plain(roster, Str(src.name), guid)
            local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and name == myName)
            if isMe then
                guid = guid or myGUID
                Count("healingDone", total)
                if total > 0 then gotSomething = true end
                if fightEvent then fightEvent.healed = total end
                local det = ns.Tbl(guid and Source(T.HealingDone, guid))
                if det and ns.Tbl(det.combatSpells) then
                    for _, sp in ipairs(det.combatSpells) do
                        local id, amt, target = Num(sp.spellID), Num(sp.totalAmount), Plain(roster, RowUnit(sp))
                        if id and amt then
                            AddD("healBySpell", id, SpellName(id), amt)
                            if target and target ~= "" and target ~= myName then AddD("healedTo", target, target, amt) end
                        end
                    end
                end
            elseif name then
                local rec = ns.Tally("groupHeal", name, name)
                if rec then rec.d = (rec.d or 0) + total end
                -- Did they heal me? Their per-target breakdown says
                local det = ns.Tbl(guid and Source(T.HealingDone, guid))
                if det and ns.Tbl(det.combatSpells) then
                    for _, sp in ipairs(det.combatSpells) do
                        local amt, target = Num(sp.totalAmount), Plain(roster, RowUnit(sp))
                        if amt and target and myName and target == myName then
                            AddD("healedBy", name, name, amt)
                            -- Without per-hit events, the meter is the only source for healing received
                            if not ns.unitCombatSeen then Count("healingTaken", amt) end
                        end
                    end
                end
            end
        end
    end

    -- Damage taken: total and by attacker
    local taken = ns.Tbl(Session(T.DamageTaken))
    if taken and ns.Tbl(taken.combatSources) then
        for _, src in ipairs(taken.combatSources) do
            local guid = Str(src.sourceGUID)
            local name = Plain(roster, Str(src.name), guid)
            local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and name == myName)
            if isMe then
                local total = Num(src.totalAmount) or 0
                Count("damageTaken", total)
                if total > 0 then gotSomething = true end
                if fightEvent then fightEvent.taken = total end
                guid = guid or myGUID
                local det = ns.Tbl(guid and Source(T.DamageTaken, guid))
                if det and ns.Tbl(det.combatSpells) then
                    for _, sp in ipairs(det.combatSpells) do
                        local amt, who = Num(sp.totalAmount), RowUnit(sp)
                        if amt and who then AddD("hurtBy", who, who, amt) end
                    end
                end
            end
        end
    end

    -- Avoidable damage taken: the "standing in it" number
    local avoid = ns.Tbl(Session(T.Avoidable))
    if avoid and ns.Tbl(avoid.combatSources) then
        for _, src in ipairs(avoid.combatSources) do
            local guid = Str(src.sourceGUID)
            local name = Plain(roster, Str(src.name), guid)
            if src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and name == myName) then
                local total = Num(src.totalAmount) or 0
                Count("avoidableTaken", total)
                if fightEvent and total > 0 then fightEvent.avoid = total end
            end
        end
    end

    -- Deaths in the group this fight (ours are logged by PLAYER_DEAD already)
    local deaths = ns.Tbl(Session(T.Deaths))
    if deaths and ns.Tbl(deaths.combatSources) then
        local n = 0
        for _, src in ipairs(deaths.combatSources) do
            local guid = Str(src.sourceGUID)
            local name = Plain(roster, Str(src.name), guid)
            local died = Num(src.deathTimeSeconds) ~= nil or Num(src.deathRecapID) ~= nil or (Num(src.totalAmount) or 0) > 0
            if died and name then
                n = n + 1
                local isMe = src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or name == myName
                if not isMe then ns.Tally("groupDeaths", name, name) end
            end
        end
        if fightEvent and n > 0 then fightEvent.deaths = n end
    end

    -- Interrupts, dispels, absorbs: my totals
    for _, pair in ipairs({ { T.Interrupts, "interrupts" }, { T.Dispels, "dispels" }, { T.Absorbs, "absorbs" } }) do
        local s = ns.Tbl(Session(pair[1]))
        if s and ns.Tbl(s.combatSources) then
            for _, src in ipairs(s.combatSources) do
                local guid = Str(src.sourceGUID)
                local name = Plain(roster, Str(src.name), guid)
                if src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and name == myName) then
                    Count(pair[2], Num(src.totalAmount) or 0)
                end
            end
        end
    end
    if gotSomething then Count("meterFights") end
    return true
end

local function Poll(fightEvent, fightDur)
    local ok, done = pcall(ReadFight, fightEvent, fightDur)
    if not ok and ns.debug then ns.Print("meter error: " .. tostring(done)) end
    if ok and done then return end
    attempts = attempts + 1
    if attempts >= 15 then return end -- about 9 seconds; the meter stayed secret (pvp, or a new fight started)
    ns.After(0.6, function() Poll(fightEvent, fightDur) end)
end

-- The recap id of our most recent death, from the meter's Deaths view (nil if unknown)
function ns.MyDeathRecapID()
    local deaths = ns.Tbl(Session(T.Deaths))
    if not deaths or not ns.Tbl(deaths.combatSources) then return nil end
    local myName, myGUID = Str(UnitName("player")), Str(UnitGUID("player"))
    for _, src in ipairs(deaths.combatSources) do
        local guid = Str(src.sourceGUID)
        local name = Plain(Roster(), Str(src.name), guid)
        if src.isLocalPlayer == true or (guid ~= nil and guid == myGUID) or (name ~= nil and name == myName) then
            return Num(src.deathRecapID)
        end
    end
end

-- /hl meter: what the game's meter holds right now, field by field, for the person reading the screenshot.
-- Some fields stay secret after the fight. A secret may not be compared, sorted or joined to other text,
-- so each one is named and shown as SECRET without being touched.
local function Shape(t)
    local rows = {}
    for k, v in pairs(t) do
        local text
        if ns.IsSecret(v) then text = "SECRET"
        elseif type(v) == "table" then text = "{..}"
        else text = tostring(v) end
        rows[#rows + 1] = { key = tostring(k), text = text }
    end
    table.sort(rows, function(x, y) return x.key < y.key end)
    local parts = {}
    for i, r in ipairs(rows) do parts[i] = r.key .. "=" .. r.text end
    return table.concat(parts, " ")
end
function ns.MeterDump()
    local P = ns.Print
    local _, avail, why = pcall(function() return CallIn(C_DamageMeter, "IsDamageMeterAvailable") end)
    P(string.format("meter available: %s %s", tostring(avail), tostring(why or "")))
    -- One source and one row of each view, with every field: this is how their layout is learned. Each view
    -- is on its own, so one that cannot be read does not hide the others.
    local views = { { "DamageDone", T.DamageDone }, { "DamageTaken", T.DamageTaken }, { "HealingDone", T.HealingDone },
        { "EnemyDamageTaken", T.EnemyTaken } }
    for _, v in ipairs(views) do
        local ok, err = pcall(function()
            local ses = ns.Tbl(Session(v[2]))
            local srcs = ses and ns.Tbl(ses.combatSources)
            if not srcs then P(v[1] .. ": no session") return end
            P(string.format("%s: %d sources, duration %s", v[1], #srcs, ns.IsSecret(ses.durationSeconds) and "SECRET" or tostring(ses.durationSeconds)))
            for i, src in ipairs(srcs) do
                if i > 2 then break end
                P(string.format("  %d: %s", i, Shape(src)))
                local det = ns.Tbl(Source(v[2], Str(src.sourceGUID) or (src.isLocalPlayer == true and Str(UnitGUID("player")) or nil), Num(src.sourceCreatureID)))
                local rows = det and ns.Tbl(det.combatSpells) or {}
                local sp = ns.Tbl(rows[1])
                if sp then
                    P(string.format("     row 1 of %d: %s", #rows, Shape(sp)))
                    local d = ns.Tbl(sp.combatSpellDetails)
                    if d then P("     details: " .. Shape(d)) end
                else
                    P("     no rows")
                end
            end
        end)
        if not ok then P(v[1] .. " could not be printed: " .. tostring(err)) end
    end
    P(string.format("session id=%s lastKey=%s attempts=%d fights read=%d of %d", tostring(sessionID), tostring(lastKey), attempts,
        ns.char and ns.char.counters.meterFights or 0, ns.char and ns.char.counters.fights or 0))
end

ns.On("PLAYER_REGEN_ENABLED", function()
    attempts = 0
    local e = ns.lastFightEvent
    ns.lastFightEvent = nil
    ns.After(0.6, function() Poll(e) end)
end)

ns.LOADED.Meter = true
