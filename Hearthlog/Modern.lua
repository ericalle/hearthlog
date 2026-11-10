local ADDON_NAME, ns = ...

-- =========================================================
-- MODERN: combat without the combat log (Forever, Retail 12.0+)
-- =========================================================
-- These clients give addons no COMBAT_LOG_EVENT_UNFILTERED, so the combat side is rebuilt
-- from what is still allowed, with less detail:
--   kills        from XP gains in or right after combat, named from PARTY_KILL (who landed the blow, on which mob)
--                or failing that from your last hostile target. A kill that gives no XP still counts.
--   damage taken, healing received, crits taken  from UNIT_COMBAT on the player
--   damage done  from UNIT_COMBAT on your target, only while solo (the event does not say who hit it)
--   deaths       the killer is your current target at the moment you die, marked as a guess
--   pvp kills    from the honorable-kill counter, named from your last hostile player target
--   buffs        from the aura list, for group members only (strangers cannot be named)
-- World damage and pet stats are not available here.
ns.LOADED.Modern = true
if not ns.NO_CLEU then return end

local Count, Event, Now, Call, Short, Pat = ns.Count, ns.Event, ns.Now, ns.Call, ns.ShortName, ns.Pat

-- Kills. The experience chat line is hidden from addons here (it arrives as a KString), so a kill
-- is an XP gain during combat or just after it. Which mob it was comes from PARTY_KILL when that fired
-- (the game's own "you or someone in your party landed the killing blow", by GUID), and otherwise from
-- the hostile thing you last had targeted.

-- The kill events carry a GUID and nothing else, so every hostile creature we get a look at (target,
-- mouseover, nameplate) is remembered by GUID, and its name by creature id for others of its kind.
local seen, seenN = {}, 0 -- [guid] = { guid, npc, n, lvl, elite, rare, trivial, threat, blowT, t }
local npcNames = {}       -- [creature id] = name
local lastHostile = nil   -- the record of the hostile creature last targeted
local function Yes(v) return v ~= nil and not ns.IsSecret(v) and v and true or false end
local function See(unit)
    if not (UnitExists and Yes(UnitExists(unit))) then return nil end
    if not Yes(UnitCanAttack("player", unit)) or Yes(UnitIsPlayer(unit)) then return nil end
    local name, guid = ns.Str(UnitName(unit)), ns.Str(UnitGUID(unit))
    if not name or not guid then return nil end
    local h = seen[guid]
    if not h then
        if seenN >= 300 then seen, seenN = {}, 0 end
        h = (lastHostile and lastHostile.guid == guid) and lastHostile or { guid = guid, npc = ns.NpcId(guid) }
        seen[guid], seenN = h, seenN + 1
    end
    h.n, h.t = name, Now()
    if h.npc then npcNames[h.npc] = name end
    local lvl = ns.Num(UnitLevel(unit))
    if lvl and lvl > 0 then h.lvl = lvl end
    local cls = ns.Str(UnitClassification(unit))
    h.elite = (cls == "elite" or cls == "worldboss" or cls == "rareelite") or nil
    h.rare = (cls == "rare" or cls == "rareelite") or nil
    if UnitIsTrivial then
        local v = UnitIsTrivial(unit)
        if v ~= nil and not ns.IsSecret(v) then h.trivial = v and true or false end
    end
    return h
end
-- The record for a GUID, seen or not. An unseen creature is named from others of its kind, then from
-- the game's own tooltip for it; failing both it still carries its creature id.
local function Known(guid)
    local h = seen[guid]
    if h then return h end
    if lastHostile and lastHostile.guid == guid then return lastHostile end
    h = { guid = guid, npc = ns.NpcId(guid) }
    h.n = h.npc and npcNames[h.npc] or nil
    if not h.n and C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local data = ns.Tbl(ns.CallIn(C_TooltipInfo, "GetHyperlink", "unit:" .. guid))
        local line = data and ns.Tbl(data.lines) and ns.Tbl(data.lines[1])
        local name = line and ns.Str(line.leftText)
        if name and name ~= "" then h.n = name end
    end
    return h
end

-- Gray: too low to be worth XP to you. Not the same as "gave no XP": a mob someone else tagged gives none,
-- and at the level cap nothing does. The game is asked when the mob is seen. Where it has no answer the
-- level rule decides, and a mob whose level was never seen is not called gray.
local function GrayLevel(me)
    if me <= 5 then return 0 end
    if me <= 49 then return me - math.floor(me / 10) - 5 end
    if me == 50 then return 40 end
    if me <= 59 then return me - math.floor(me / 5) - 1 end
    return me - 9
end
local function IsGray(h)
    if h.trivial ~= nil then return h.trivial end
    local me = ns.Num(UnitLevel("player"))
    return (h.lvl ~= nil and me ~= nil and h.lvl <= GrayLevel(me)) or false
end

local function NoteHostileTarget()
    local h = See("target")
    if not h then return end
    -- On its threat list means we have tagged it (or it has us). Once seen it sticks for that mob:
    -- the list empties the moment it dies, which can be just before UNIT_DIED arrives.
    if UnitThreatSituation and ns.Num(ns.Call("UnitThreatSituation", "player", "target")) ~= nil then h.threat = true end
    lastHostile = h
end
ns.On("PLAYER_TARGET_CHANGED", NoteHostileTarget)
ns.On("UNIT_TARGET", function(unit) if unit == "player" then NoteHostileTarget() end end)
ns.On("UNIT_THREAT_LIST_UPDATE", function(unit) if unit == "player" or unit == "target" then NoteHostileTarget() end end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() See("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", function(unit)
    unit = ns.Str(unit)
    if unit then See(unit) end
end)

-- UNIT_DIED carries the GUID of whatever just died nearby. When it is the mob we had targeted, the kill is
-- confirmed on the spot; the XP gain (if any) that follows names it from here. A tagged mob that gives no
-- XP is still a kill.
local deadTarget = nil
local lastXPKillT = 0
local lastXPKill = nil -- the last kill taken from an XP gain: { e = its event, t, matched = a killing blow went with it }
local function NoXPKillCheck(stamp)
    if not deadTarget or deadTarget.t ~= stamp then return end -- consumed by the XP path
    local d = deadTarget
    deadTarget = nil
    if not d.threat then return end -- someone else's kill that we happened to target
    if not (ns.InCombat() or ns.SinceCombat() <= 4) then return end
    local e = { n = d.n, lvl = d.lvl, npc = d.npc, elite = d.elite, rare = d.rare, xp = 0 }
    if IsGray(d) then e.gray = true; Count("grayKills") end
    if IsInGroup() then e.group = true; e.assist = true; Count("assists") else Count("kills") end
    ns.NoteKill(e)
end
ns.On("UNIT_DIED", function(arg)
    local guid = ns.Str(arg)
    local h = lastHostile
    if not guid or not h or h.guid ~= guid then return end
    if h.blowT and Now() - h.blowT <= 3 then return end -- PARTY_KILL has this one already
    if Now() - lastXPKillT <= 2 then return end -- its XP already arrived and was counted
    local stamp = Now()
    deadTarget = { guid = guid, n = h.n, lvl = h.lvl, npc = h.npc, elite = h.elite, rare = h.rare, trivial = h.trivial,
        threat = h.threat, t = stamp }
    ns.After(1.5, function() NoXPKillCheck(stamp) end)
end)

-- PARTY_KILL: attackerGUID, targetGUID. Each one waits here for the XP gain that belongs to it. A blow
-- that gets no XP within two seconds still counts: a kill when the blow was ours, an assist when it was
-- a party member's and the mob had us on its threat list.
local blows = {} -- oldest first: { guid, mine }
local function NoXPBlow(b)
    for i, q in ipairs(blows) do
        if q == b then
            table.remove(blows, i)
            local h = Known(b.guid)
            if not (b.mine or h.threat) then return end
            local e = { n = h.n, lvl = h.lvl, npc = h.npc, elite = h.elite, rare = h.rare, xp = 0 }
            if IsGray(h) then e.gray = true; Count("grayKills") end
            if IsInGroup() then e.group = true end
            if b.mine then Count("kills") else e.assist = true; Count("assists") end
            ns.NoteKill(e)
            return
        end
    end
end
ns.On("PARTY_KILL", function(attacker, target)
    attacker, target = ns.Str(attacker), ns.Str(target)
    if not target or not ns.NpcId(target) then return end -- players are counted from the honor counter below
    local h = Known(target)
    h.blowT = Now()
    if deadTarget and deadTarget.guid == target then deadTarget = nil end
    -- Should the XP ever arrive first, that gain was already taken as a kill and named from the target.
    -- This blow is that kill, not a second one.
    local x = lastXPKill
    if x and x.e and not x.matched and Now() - x.t <= 2 then
        x.matched = true
        if not x.e.n then x.e.n, x.e.lvl, x.e.npc, x.e.elite, x.e.rare = h.n, h.lvl, h.npc, h.elite, h.rare end
        return
    end
    local mine = attacker ~= nil and (attacker == ns.Str(UnitGUID("player")) or attacker == ns.Str(UnitGUID("pet")))
    local b = { guid = target, mine = mine }
    tinsert(blows, b)
    ns.After(2, function() NoXPBlow(b) end)
end)

-- Called by the XP handler when a gain is not a quest or a discovery. Returns true if it was taken as a kill.
function ns.KillFromXP(gain)
    local b = table.remove(blows, 1)
    if not b and not (ns.InCombat() or ns.SinceCombat() <= 4) then return false end
    local h
    if b then
        h = Known(b.guid)
    else
        h = deadTarget or lastHostile
        deadTarget = nil
        if h and Now() - h.t > 60 then h = nil end
    end
    lastXPKillT = Now()
    local e = { xp = gain }
    if h then e.n, e.lvl, e.npc, e.elite, e.rare = h.n, h.lvl, h.npc, h.elite, h.rare end
    if IsInGroup() then e.group = true end
    if b and b.mine then
        Count("kills") -- our own killing blow, grouped or not
    elseif IsInGroup() then
        -- A party member's kill (or one with no blow reported): an assist when it had us on its threat
        -- list, the meter saw us damage it, or we are in the fight ourselves
        if (b and h.threat) or (e.n and ns.EngagedRecently(e.n)) or ns.InCombat() then
            e.assist = true
            Count("assists")
        else
            Count("partyKills")
            return true
        end
    else
        Count("kills")
    end
    lastXPKill = { e = ns.NoteKill(e), t = Now(), matched = b ~= nil }
    return true
end

-- UNIT_COMBAT: unit, action (WOUND, HEAL, DODGE, PARRY, BLOCK, MISS, ...), descriptor (CRITICAL, ...), amount
ns.On("UNIT_COMBAT", function(unit, action, descriptor, amount)
    ns.unitCombatSeen = true -- this client does deliver per-hit events
    action, descriptor = ns.Str(action), ns.Str(descriptor)
    local amt = ns.Num(amount) or 0
    if unit == "player" then
        if action == "WOUND" then
            if ns.HAS_METER then
                ns.Max("maxHitTaken", amt)
                if descriptor == "CRITICAL" then Count("critsTaken") end
            else
                ns.NoteDamageTaken(amt, descriptor == "CRITICAL")
            end
            local who = UnitExists and UnitExists("target") and UnitCanAttack("player", "target") and ns.Str(UnitName("target")) or nil
            ns.Record("hitTaken", amt, { who = who, crit = descriptor == "CRITICAL" or nil })
        elseif action == "HEAL" then
            Count("healingTaken", amt)
            ns.Record("healTaken", amt, {})
        end
    elseif unit == "target" and not IsInGroup() and UnitCanAttack("player", "target") then
        local who = ns.Str(UnitName("target"))
        if action == "WOUND" then
            if not ns.HAS_METER then Count("damageDone", amt) end
            ns.Max("maxHitDone", amt)
            ns.Record("hitDone", amt, { who = who, crit = descriptor == "CRITICAL" or nil })
            if descriptor == "CRITICAL" then Count("critsDone") end
        elseif action == "MISS" then Count("swingMisses")
        elseif action == "DODGE" then Count("dodged")
        elseif action == "PARRY" then Count("parried")
        end
    end
end)

-- PvP kills. The honor chat line is hidden here too, but the game fires PLAYER_PVP_KILLS_CHANGED for
-- each honorable kill; the victim is the hostile player you last had targeted.
local lastHostilePlayer = nil -- { n, t }
local function NotePlayerTarget()
    if not (UnitExists and UnitExists("target")) then return end
    if not UnitCanAttack("player", "target") or not UnitIsPlayer("target") then return end
    local name = ns.Str(UnitName("target"))
    if name then lastHostilePlayer = { n = Short(name), t = Now() } end
end
ns.On("PLAYER_TARGET_CHANGED", NotePlayerTarget)
ns.On("UNIT_TARGET", function(unit) if unit == "player" then NotePlayerTarget() end end)
ns.On("PLAYER_PVP_KILLS_CHANGED", function()
    local who = lastHostilePlayer and (Now() - lastHostilePlayer.t) <= 60 and lastHostilePlayer.n or nil
    Count("pvpKills")
    if who then ns.Tally("pvpKills", who, who) end
    Event("PVP_KILL", { who = who })
end)

-- Death recap: the game keeps the last hits that killed you. When readable, the guessed killer on the
-- DEATH event is replaced with the real one. The function moved between builds; all known homes are tried.
local function RecapEvents(recapID)
    if C_DeathRecap then
        for _, fname in ipairs({ "GetRecapEvents", "GetEvents" }) do
            if type(C_DeathRecap[fname]) == "function" then
                local ev = ns.Tbl(ns.CallIn(C_DeathRecap, fname, recapID))
                if ev and #ev > 0 then return ev end
            end
        end
    end
    if type(DeathRecap_GetEvents) == "function" then
        local ev = ns.Tbl(ns.Call("DeathRecap_GetEvents", recapID))
        if ev and #ev > 0 then return ev end
    end
end
local function Untally(group, id)
    local t = ns.char and ns.char.tallies[group]
    local rec = t and id ~= nil and t[id]
    if not rec then return end
    rec.n = (rec.n or 1) - 1
    if rec.n <= 0 then t[id] = nil end
end
function ns.ImproveDeath(e)
    if not e then return end
    local recapID = ns.MyDeathRecapID and ns.MyDeathRecapID()
    if not recapID then return end
    local events = RecapEvents(recapID)
    if not events then return end
    -- The killing blow is the newest entry; the list order is not relied on
    local last, lastT = nil, nil
    for _, ev in ipairs(events) do
        ev = ns.Tbl(ev)
        local ts = ev and ns.Num(ev.timestamp)
        if ev and (last == nil or (ts and lastT and ts > lastT)) then last, lastT = ev, ts end
    end
    if not last then return end
    local who = ns.Str(last.sourceName) or ns.Str(last.environmentalType)
    if not who then return end
    -- Take back what the guess tallied, then file the real killer
    if e.guess then
        if e.pvp then
            Count("pvpDeaths", -1)
            Untally("killedByPlayers", e.by and Short(e.by))
        elseif e.npc then
            Untally("killers", e.npc)
        end
    end
    local guid = ns.Str(last.sourceGUID)
    e.by, e.guess, e.recap = who, nil, true
    e.spell, e.amt = ns.Str(last.spellName), ns.Num(last.amount)
    e.npc, e.lvl, e.pvp = nil, nil, nil
    if guid and guid:sub(1, 6) == "Player" then
        e.pvp = true
        Count("pvpDeaths")
        ns.Tally("killedByPlayers", Short(who), Short(who))
    elseif ns.Str(last.sourceName) then
        e.npc = guid and ns.NpcId(guid) or nil
        ns.Tally("killers", e.npc or who, who)
    end
end

ns.On("RESURRECT_REQUEST", function(name)
    local who = Short(ns.Str(name))
    if not who then return end
    Count("rezzes")
    ns.Tally("rezBy", who, who)
end)

-- New helpful auras on the player, credited to group members when the source is a group unit
ns.On("UNIT_AURA", function(unit, info)
    if unit ~= "player" then return end
    info = ns.Tbl(info)
    local added = info and ns.Tbl(info.addedAuras)
    if not added then return end
    for _, aura in ipairs(added) do
        aura = ns.Tbl(aura)
        if not aura then break end
        local src = ns.Str(aura.sourceUnit)
        -- sourceUnit names who cast it; isFromPlayerOrPlayerPet is true for any player's cast, so it is no use here
        if aura.isHelpful and src and (src:find("^party") or src:find("^raid")) then
            local who = Short(ns.Str(UnitName(src)))
            if who then
                local rec = ns.Tally("buffedBy", who, who)
                if rec then rec.f = (rec.f or 0) + 1 end
            end
        end
    end
end)

ns.LOADED.Modern = true
