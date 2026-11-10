local ADDON_NAME, ns = ...

-- =========================================================
-- MODERN: combat without the combat log (Forever, Retail 12.0+)
-- =========================================================
-- These clients give addons no COMBAT_LOG_EVENT_UNFILTERED, so the combat side is rebuilt
-- from what is still allowed, with less detail:
--   kills        from XP gains in or right after combat, named from your last hostile target (gray mobs give no XP)
--   damage taken, healing received, crits taken  from UNIT_COMBAT on the player
--   damage done  from UNIT_COMBAT on your target, only while solo (the event does not say who hit it)
--   deaths       the killer is your current target at the moment you die, marked as a guess
--   pvp kills    from the honorable-kill counter, named from your last hostile player target
--   buffs        from the aura list, for group members only (strangers cannot be named)
-- Killing blows vs assists, who healed whom, world damage and pet stats are not available here.
ns.LOADED.Modern = true
if not ns.NO_CLEU then return end

local Count, Event, Now, Call, Short, Pat = ns.Count, ns.Event, ns.Now, ns.Call, ns.ShortName, ns.Pat

-- Kills. The experience chat line is hidden from addons here (it arrives as a KString), so a kill
-- is an XP gain during combat or just after it, and the mob is the hostile thing you last had targeted.
local lastHostile = nil -- { n, lvl, npc, elite, rare, t }
local function NoteHostileTarget()
    if not (UnitExists and UnitExists("target")) then return end
    if not UnitCanAttack("player", "target") or UnitIsPlayer("target") then return end
    local name = ns.Str(UnitName("target"))
    if not name then return end
    local h = { n = name, t = Now() }
    local lvl = ns.Num(UnitLevel("target"))
    if lvl and lvl > 0 then h.lvl = lvl end
    local guid = ns.Str(UnitGUID("target"))
    if guid then h.npc = ns.NpcId(guid); h.guid = guid end
    if UnitThreatSituation then
        -- On its threat list means we have tagged it (or it has us). Once seen it sticks for that mob:
        -- the list empties the moment it dies, which can be just before UNIT_DIED arrives.
        local th = ns.Num(ns.Call("UnitThreatSituation", "player", "target"))
        h.threat = th ~= nil or (lastHostile ~= nil and lastHostile.guid == guid and lastHostile.threat == true)
    end
    local cls = ns.Str(UnitClassification("target"))
    if cls == "elite" or cls == "worldboss" or cls == "rareelite" then h.elite = true end
    if cls == "rare" or cls == "rareelite" then h.rare = true end
    lastHostile = h
end
ns.On("PLAYER_TARGET_CHANGED", NoteHostileTarget)
ns.On("UNIT_TARGET", function(unit) if unit == "player" then NoteHostileTarget() end end)
ns.On("UNIT_THREAT_LIST_UPDATE", function(unit) if unit == "player" or unit == "target" then NoteHostileTarget() end end)

-- UNIT_DIED carries the GUID of whatever just died nearby. When it is the mob we had targeted, the kill is
-- confirmed on the spot; the XP gain (if any) that follows names it from here. A tagged mob that gives no
-- XP (gray) is still a kill.
local deadTarget = nil
local lastXPKillT = 0
local function GrayKillCheck(stamp)
    if not deadTarget or deadTarget.t ~= stamp then return end -- consumed by the XP path
    local d = deadTarget
    deadTarget = nil
    if not d.threat then return end -- someone else's kill that we happened to target
    if not (ns.InCombat() or ns.SinceCombat() <= 4) then return end
    local e = { n = d.n, lvl = d.lvl, npc = d.npc, elite = d.elite, rare = d.rare, xp = 0, gray = true }
    if IsInGroup() then e.group = true; e.assist = true; Count("assists") else Count("kills") end
    Count("grayKills")
    ns.NoteKill(e)
end
ns.On("UNIT_DIED", function(arg)
    local guid = ns.Str(arg)
    local h = lastHostile
    if not guid or not h or h.guid ~= guid then return end
    if Now() - lastXPKillT <= 2 then return end -- its XP already arrived and was counted
    local stamp = Now()
    deadTarget = { n = h.n, lvl = h.lvl, npc = h.npc, elite = h.elite, rare = h.rare, threat = h.threat, t = stamp }
    ns.After(1.5, function() GrayKillCheck(stamp) end)
end)

-- Called by the XP handler when a gain is not a quest or a discovery. Returns true if it was taken as a kill.
function ns.KillFromXP(gain)
    local inCombat = ns.InCombat() or ns.SinceCombat() <= 4
    if not inCombat then return false end
    local h = deadTarget or lastHostile
    deadTarget = nil
    lastXPKillT = Now()
    local e = { xp = gain }
    if h and Now() - h.t <= 60 then
        e.n, e.lvl, e.npc, e.elite, e.rare = h.n, h.lvl, h.npc, h.elite, h.rare
    end
    if IsInGroup() then
        e.group = true
        -- Grouped: an assist when the meter saw you damage this mob, or you are in the fight yourself
        if (e.n and ns.EngagedRecently(e.n)) or ns.InCombat() then
            e.assist = true
            Count("assists")
        else
            Count("partyKills")
            return true
        end
    else
        Count("kills")
    end
    ns.NoteKill(e)
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
