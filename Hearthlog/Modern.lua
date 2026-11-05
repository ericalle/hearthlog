local ADDON_NAME, ns = ...

-- =========================================================
-- MODERN: combat without the combat log (Forever, Retail 12.0+)
-- =========================================================
-- These clients give addons no COMBAT_LOG_EVENT_UNFILTERED, so the combat side is rebuilt
-- from what is still allowed, with less detail:
--   kills        from the "X dies, you gain N experience." chat line (gray mobs give no line)
--   damage taken, healing received, crits taken  from UNIT_COMBAT on the player
--   damage done  from UNIT_COMBAT on your target, only while solo (the event does not say who hit it)
--   deaths       the killer is your current target at the moment you die, marked as a guess
--   pvp kills    from the honorable kill chat line
--   buffs        from the aura list, for group members only (strangers cannot be named)
-- Killing blows vs assists, who healed whom, world damage and pet stats are not available here.
if not ns.NO_CLEU then return end

local Count, Event, Now, Call, Short, Pat = ns.Count, ns.Event, ns.Now, ns.Call, ns.ShortName, ns.Pat

local KILL_PATS = {
    { Pat(COMBATLOG_XPGAIN_FIRSTPERSON_GROUP or "%s dies, you gain %d experience. (+%d group bonus)"), true },
    { Pat(COMBATLOG_XPGAIN_FIRSTPERSON_RAID or "%s dies, you gain %d experience. (-%d raid penalty)"), true },
    { Pat(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience."), false },
}

local function TargetIs(name)
    return UnitExists and UnitExists("target") and ns.Str(UnitName("target")) == name
end

ns.On("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    msg = ns.Str(msg)
    if not msg then return end
    for _, p in ipairs(KILL_PATS) do
        local name, xp = msg:match(p[1])
        if name then
            local e = { n = name, xp = tonumber(xp), group = p[2] or nil }
            if TargetIs(name) then
                e.lvl = ns.Num(UnitLevel("target"))
                if e.lvl and e.lvl <= 0 then e.lvl = nil end
                local guid = ns.Str(UnitGUID("target"))
                if guid then e.npc = ns.NpcId(guid) end
                local cls = ns.Str(UnitClassification("target"))
                if cls == "elite" or cls == "worldboss" or cls == "rareelite" then e.elite = true end
                if cls == "rare" or cls == "rareelite" then e.rare = true end
            end
            Count("xpKill", e.xp or 0)
            if e.group and ns.HAS_METER then
                -- A group kill: an assist if the meter saw us damage that creature recently, else only counted
                if not ns.EngagedRecently(name) then Count("partyKills") return end
                e.assist = true
                Count("assists")
            else
                Count("kills")
            end
            ns.NoteKill(e)
            return
        end
    end
end)

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
    if unit ~= "player" or type(info) ~= "table" or type(info.addedAuras) ~= "table" then return end
    for _, aura in ipairs(info.addedAuras) do
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
