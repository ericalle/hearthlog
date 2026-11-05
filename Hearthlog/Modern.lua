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
--   pvp kills    from the honorable kill chat line
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
    if guid then h.npc = ns.NpcId(guid) end
    local cls = ns.Str(UnitClassification("target"))
    if cls == "elite" or cls == "worldboss" or cls == "rareelite" then h.elite = true end
    if cls == "rare" or cls == "rareelite" then h.rare = true end
    lastHostile = h
end
ns.On("PLAYER_TARGET_CHANGED", NoteHostileTarget)
ns.On("UNIT_TARGET", function(unit) if unit == "player" then NoteHostileTarget() end end)

-- Called by the XP handler when a gain is not a quest or a discovery. Returns true if it was taken as a kill.
function ns.KillFromXP(gain)
    local inCombat = ns.InCombat() or ns.SinceCombat() <= 4
    if not inCombat then return false end
    local h = lastHostile
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

local HONOR_PATS = {
    Pat(COMBATLOG_HONORGAIN or "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)"),
    Pat(COMBATLOG_HONORGAIN_NO_RANK or "%s dies, honorable kill (Estimated Honor Points: %d)"),
}
ns.On("CHAT_MSG_COMBAT_HONOR_GAIN", function(msg)
    msg = ns.Str(msg)
    if not msg then return end
    for _, p in ipairs(HONOR_PATS) do
        local who = msg:match(p)
        if who then
            who = Short(who)
            Count("pvpKills")
            ns.Tally("pvpKills", who, who)
            Event("PVP_KILL", { who = who })
            return
        end
    end
end)

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
        if aura.isHelpful and not aura.isFromPlayerOrPlayerPet and src and (src:find("^party") or src:find("^raid")) then
            local who = Short(ns.Str(UnitName(src)))
            if who then
                local rec = ns.Tally("buffedBy", who, who)
                if rec then rec.f = (rec.f or 0) + 1 end
            end
        end
    end
end)

ns.LOADED.Modern = true
