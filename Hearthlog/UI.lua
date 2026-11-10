local ADDON_NAME, ns = ...
local Print = ns.Print

-- =========================================================
-- UI: the Hearthlog window. /hl opens it.
-- =========================================================
-- Styled like the game's own dialogs: dark background, bronze border, portrait, tabs along the bottom.
-- (SKINS is a table so a second look can be added later without touching the layout code.)
-- Left pane: stat rows (label, value, note). Right pane: a scrolling log. Settings tab: checkboxes.

local W, H = 720, 640
local LEFT_W = 300
local ROW_H = 22

local SKINS = {
    b = {
        bg = "Interface\\DialogFrame\\UI-DialogBox-Background", bgTile = true,
        border = "Interface\\DialogFrame\\UI-DialogBox-Border", edge = 32,
        bgColor = { 1, 1, 1, 1 }, borderColor = { 1, 1, 1, 1 },
        font = "Fonts\\FRIZQT__.TTF", bodyFont = "Fonts\\FRIZQT__.TTF",
        title = { 1, 0.82, 0 }, label = { 0.90, 0.86, 0.78 }, value = { 1, 1, 1 },
        note = { 0.60, 0.56, 0.50 }, header = { 1, 0.82, 0 }, red = { 1, 0.35, 0.35 }, green = { 0.25, 1, 0.5 },
        paneBg = { 0.04, 0.05, 0.07, 0.9 }, paneBorder = { 0.36, 0.29, 0.12, 1 },
        tabs = "bottom", ruled = false, portrait = true,
        tabNames = { "Overview", "Journey", "Combat", "Loot", "Friends", "Settings" },
    },
}

local TABS = { "overview", "journey", "combat", "loot", "friends", "settings" }

local frame, skin, current = nil, nil, "overview"
local widgets = {}

local function Coin(c)
    if ns.CoinString then return ns.CoinString(c or 0) end
    return tostring(c or 0) .. "c"
end
local function Yards(y) return string.format("%s yd", BreakUpLargeNumbers and BreakUpLargeNumbers(math.floor(y or 0)) or math.floor(y or 0)) end
local function Pct(a, b) if not b or b == 0 then return "" end return string.format("%d%%", a / b * 100) end
local function Top(group, n)
    local t = ns.char and ns.char.tallies[group] or {}
    local list = {}
    for id, rec in pairs(t) do tinsert(list, { id = id, rec = rec }) end
    table.sort(list, function(a, b) return (a.rec.n or 0) > (b.rec.n or 0) end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end
-- Sort a tally by a field other than n (d for damage or healing amounts)
local function TopBy(group, field, n)
    local t = ns.char and ns.char.tallies[group] or {}
    local list = {}
    for id, rec in pairs(t) do tinsert(list, { id = id, rec = rec }) end
    table.sort(list, function(a, b) return (a.rec[field] or 0) > (b.rec[field] or 0) end)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end
local function Clock(t) return date("%I:%M %p", t):gsub("^0", ""):lower() end
local function Day(t) return date("%b %d", t):gsub(" 0", " ") end

-- ---------------------------------------------------------
-- Content: each tab returns rows for the left pane and lines for the right
-- rows: { label, value, note, color }    lines: { stamp, text, color }
-- ---------------------------------------------------------
local ENV_NAMES = { FALLING = "a fall", DROWNING = "drowning", LAVA = "lava", FIRE = "fire", SLIME = "slime", FATIGUE = "fatigue" }
local function Killer(by)
    if not by then return "something" end
    return ENV_NAMES[by] or by
end

local function EventLine(e)
    local k = e.k
    if k == "LEVEL" then return string.format("Reached level %d.", e.v or 0), "green"
    elseif k == "DEATH" then return string.format("%s %s.", e.pvp and "Killed by" or "Died to", Killer(e.by)), "red"
    elseif k == "PVP_KILL" then return string.format("Killed %s (player).", e.who or "?")
    elseif k == "BIND" then return string.format("Home is now %s.", e.n or "?")
    elseif k == "LOOK" then return string.format("New appearance: %s.", e.n or "an item")
    elseif k == "MOUNT" then return string.format("New mount: %s.", e.n or "?")
    elseif k == "TOY" then return string.format("New toy: %s.", e.n or "?")
    elseif k == "ACHIEVE" then return string.format("Achievement: %s.", e.n or "?"), "green"
    elseif k == "STANDING" then return string.format("Reputation with %s improved.", e.f or "?"), "green"
    elseif k == "WON" then return string.format("Won the roll for %s%s.", e.n or "?", e.roll and (" with a " .. e.roll) or "")
    elseif k == "TRADE" then return string.format("Traded with %s%s%s.", e.who or "?",
        e.got and (": got " .. table.concat(e.got, ", ")) or "", e.gave and ((e.got and ", gave " or ": gave ") .. table.concat(e.gave, ", ")) or "")
    elseif k == "MAIL" then return string.format("Mailed %s%s%s.", e.to or "?", e.items and (" " .. e.items .. " items") or "", e.gold and (" " .. Coin(e.gold)) or "")
    elseif k == "ALIVE" then return e.ghost and "Released spirit." or string.format("Back among the living after %ds.", e.dur or 0)
    elseif k == "KILL" then return string.format("Killed %s%s.", e.n or "?", e.xp and (" (+" .. e.xp .. " xp)") or "")
    elseif k == "QUEST_ACC" then return string.format("Took quest: %s.", e.n or e.q)
    elseif k == "QUEST_DONE" then return string.format("Finished %s%s.", e.n or e.q, e.dur and string.format(" in %dm %ds", e.dur / 60, e.dur % 60) or "")
    elseif k == "QUEST_DROP" then return string.format("Abandoned %s.", e.n or e.q)
    elseif k == "ZONE" then return string.format("Entered %s.", e.n or "?")
    elseif k == "DISCOVER" then return string.format("Discovered %s.", e.n or "?")
    elseif k == "INST_IN" then return string.format("Entered %s.", e.n or "an instance")
    elseif k == "INST_OUT" then return string.format("Left %s after %dm.", e.n or "the instance", (e.dur or 0) / 60)
    elseif k == "PARTY" then
        local parts = {}
        if e.add then for _, m in ipairs(e.add) do tinsert(parts, (m:match("^([^:]+)")) .. " joined") end end
        if e.rem then for _, m in ipairs(e.rem) do tinsert(parts, (m:match("^([^:]+)")) .. " left") end end
        return table.concat(parts, ", ") .. "."
    elseif k == "HEARTH" then return string.format("Hearthstone to %s.", e.to or "home")
    elseif k == "TAXI" then return string.format("Flew %s to %s, %dm %ds%s.", e.from or "?", e.to or "?", (e.dur or 0) / 60, (e.dur or 0) % 60, e.gold and (", " .. Coin(e.gold)) or "")
    elseif k == "LOOT" then return string.format("Looted %s.", e.n or "?")
    elseif k == "GOLD" then return string.format("%s %s (%s).", e.v > 0 and "Gained" or "Spent", Coin(math.abs(e.v)), e.ctx or "")
    elseif k == "GZ" then return string.format("%s said gz.", e.who or "someone")
    elseif k == "DUEL" then return string.format("Duel with %s%s.", e.who or "?", e.won == true and ": won" or e.won == false and ": lost" or "")
    elseif k == "SKILL" then return string.format("%s reached %d.", e.n or "?", e.v or 0)
    elseif k == "TALENT" then return string.format("Talent: %s%s.", e.n or "?", (e.v or 1) > 1 and (" (rank " .. e.v .. ")") or "")
    elseif k == "XP" then return string.format("+%d xp (%s).", e.v or 0, e.src or "")
    elseif k == "FIGHT" then
        if e.share then return string.format("Fight of %ds: %d damage, %d%% of the group's%s.", e.dur or 0, e.done or 0, e.share,
            e.deaths and (", " .. e.deaths .. " died") or "") end
        return nil
    end
    return nil
end

local CONTENT = {}

local function DuelNote(events)
    local won, lost = 0, 0
    for _, e in ipairs(events) do
        if e.k == "DUEL" then
            if e.won == true then won = won + 1 elseif e.won == false then lost = lost + 1 end
        end
    end
    if won + lost == 0 then return "" end
    return string.format("%d won · %d lost", won, lost)
end

function CONTENT.overview()
    local c, char = ns.char.counters, ns.char
    local played = char.meta.played or 0
    local rows = {
        { header = "GENERAL" },
        { "Level", tostring(ns.level or UnitLevel("player")) },
        { "Kills", tostring(c.kills + c.assists), c.assists > 0 and string.format("%d killing blows · %d assists", c.kills, c.assists) or "" },
        { "Deaths", tostring(c.deaths), "", c.deaths > 0 and "red" or nil },
        { "Quests", string.format("%d / %d", c.questsDone, c.questsAccepted) },
        { "Jumps", tostring(c.jumps) },
        { "Discoveries", tostring(c.discoveries) },
        { header = "TRAVEL" },
        { "Distance", string.format("%.1f mi", (c.miles.f + c.miles.m + c.miles.t + c.miles.s + c.miles.g + c.miles.v + c.miles.b) / 1760) },
        { "Flights", tostring(c.taxis) },
        { "Hearthstones", tostring(c.hearths) },
        { header = "GOLD" },
        { "Earned", Coin(c.goldIn), "", "green" },
        { "Spent", Coin(c.goldOut), "", "red" },
        { "In purse", Coin(GetMoney()) },
        { header = "SOCIAL" },
        { "Duels", tostring(c.duels), DuelNote(char.events) },
        { "Invites", tostring(c.duelRequests + c.partyInvites), string.format("%d duel · %d party", c.duelRequests, c.partyInvites) },
        { "PvP", tostring(c.pvpKills), string.format("%d kills · %d deaths · %d honorable", c.pvpKills, c.pvpDeaths, c.honorKills) },
        { header = "TIME" },
        { "Played", ns.Duration(played), string.format("%d sessions", #char.sessions) },
        { "This session", ns.Duration(ns.Now() - (ns.session and ns.session.t0 or ns.Now())), ns.paused and "paused" or "recording" },
    }
    local lines = { { title = "THIS SESSION" } }
    local t0 = ns.session and ns.session.t0 or 0
    local events = char.events
    local count = 0
    for i = #events, 1, -1 do
        local e = events[i]
        if e.t < t0 or count >= 40 then break end
        local text, color = EventLine(e)
        if text then
            tinsert(lines, 2, { Clock(e.t), text, color })
            count = count + 1
        end
    end
    if count == 0 then tinsert(lines, { "", "Nothing yet this session." }) end
    return rows, lines
end

function CONTENT.journey()
    local c, char = ns.char.counters, ns.char
    local m = c.miles
    local rows = {
        { header = "DISTANCE BY MODE" },
        { "On foot", Yards(m.f) }, { "Mounted", Yards(m.m) }, { "Flight path", Yards(m.t) },
        { "Swimming", Yards(m.s) }, { "As a ghost", Yards(m.g) }, { "Travel form", Yards(m.v) }, { "Boat / tram", Yards(m.b) },
        { header = "IDLE" },
        { "Standing still", ns.Duration(c.idleSeconds) },
    }
    local lines = { { title = "TRAVEL LOG" } }
    local n = 0
    for i = #char.events, 1, -1 do
        local e = char.events[i]
        if e.k == "TAXI" or e.k == "HEARTH" or e.k == "DISCOVER" or e.k == "INST_IN" or e.k == "BIND" then
            local text, color = EventLine(e)
            if text then tinsert(lines, { Day(e.t), text, color }); n = n + 1 end
            if n >= 14 then break end
        end
    end
    local rep = TopBy("rep", "d", 6)
    if #rep > 0 then
        tinsert(lines, { title = "REPUTATION EARNED" })
        for _, s in ipairs(rep) do tinsert(lines, { tostring(s.rec.d or 0), s.rec.nm or tostring(s.id) }) end
    end
    tinsert(lines, { title = "SESSIONS" })
    for i = #char.sessions, math.max(1, #char.sessions - 8), -1 do
        local s = char.sessions[i]
        local mins = s.t1 and math.floor((s.t1 - s.t0) / 60) or math.floor((ns.Now() - s.t0) / 60)
        tinsert(lines, { Day(s.t0), string.format("%dm, level %d%s", mins, s.lvl0 or 0, (s.lvl1 and s.lvl1 ~= s.lvl0) and (" to " .. s.lvl1) or "") })
    end
    return rows, lines
end

-- "Holy Light on Kobold Worker" / "Melee by Defias Thug" / "biggest 43, Holy Light on Zinther"
local function RecordNote(rec, prep, prefix)
    if not rec then return "" end
    local what = rec.spell or "Melee"
    local s = rec.who and string.format("%s %s %s", what, prep, rec.who) or what
    if rec.crit then s = s .. " (crit)" end
    if prefix then s = string.format("%s %d, %s", prefix, rec.v or 0, s) end
    return s
end

function CONTENT.combat()
    local c, r = ns.char.counters, ns.char.records or {}
    local rows = {}
    if ns.NO_CLEU then
        -- No per-hit data on this client: totals from the game's meter only
        tinsert(rows, { header = "DAMAGE" })
        tinsert(rows, { "Damage done", tostring(c.damageDone) })
        if c.overkill > 0 then tinsert(rows, { "Overkill", tostring(c.overkill) }) end
        for _, s in ipairs(TopBy("damageBySpell", "d", 3)) do tinsert(rows, { s.rec.nm or tostring(s.id), tostring(s.rec.d or 0) }) end
    else
        tinsert(rows, { header = "MELEE" })
        tinsert(rows, { "Swings", tostring(c.swings) })
        tinsert(rows, { "Misses", tostring(c.swingMisses) })
        tinsert(rows, { "Dodged / parried", c.dodged .. " / " .. c.parried })
        tinsert(rows, { "Damage done", tostring(c.damageDone) })
        tinsert(rows, { "Biggest hit", tostring(c.maxHitDone), RecordNote(r.hitDone, "on") })
        tinsert(rows, { "Critical hits", tostring(c.critsDone) })
        if c.shots > 0 then tinsert(rows, { "Ranged shots", tostring(c.shots) }) end
    end
    tinsert(rows, { header = "SPELLS" })
    tinsert(rows, { "Casts", tostring(c.casts) })
    for _, s in ipairs(Top("spells", 3)) do tinsert(rows, { s.rec.nm or tostring(s.id), tostring(s.rec.n) }) end
    tinsert(rows, { header = "TAKEN" })
    tinsert(rows, { "Fights", tostring(c.fights), ns.Duration(c.fightSeconds) .. " in combat" })
    tinsert(rows, { "Damage taken", tostring(c.damageTaken) })
    if not ns.NO_CLEU then tinsert(rows, { "Biggest hit taken", tostring(c.maxHitTaken), RecordNote(r.hitTaken, "by") }) end
    if c.avoidableTaken > 0 then tinsert(rows, { "Avoidable damage", tostring(c.avoidableTaken), "stood in it" }) end
    if c.interrupts + c.dispels > 0 then tinsert(rows, { "Interrupts / dispels", c.interrupts .. " / " .. c.dispels }) end
    tinsert(rows, { header = "HEALING" })
    tinsert(rows, { "Healing done", tostring(c.healingDone), RecordNote(r.healDone, "on", "biggest") })
    tinsert(rows, { "Healing received", tostring(c.healingTaken), RecordNote(r.healTaken, "from", "biggest") })
    if c.absorbs > 0 then tinsert(rows, { "Absorbs", tostring(c.absorbs) }) end

    local lines = { { title = "MOST KILLED" } }
    local kills = {}
    for _, e in ipairs(ns.char.events) do
        if e.k == "KILL" and e.n then kills[e.n] = (kills[e.n] or 0) + 1 end
    end
    local list = {}
    for n, k in pairs(kills) do tinsert(list, { n = n, k = k }) end
    table.sort(list, function(a, b) return a.k > b.k end)
    for i = 1, math.min(8, #list) do tinsert(lines, { tostring(list[i].k), list[i].n }) end
    tinsert(lines, { title = "DEATHS" })
    local d = 0
    for i = #ns.char.events, 1, -1 do
        local e = ns.char.events[i]
        if e.k == "DEATH" then
            local who = Killer(e.by)
            if e.lvl then who = string.format("%s (%d)", who, e.lvl) end
            tinsert(lines, { Day(e.t), string.format("%s%s, %s.", e.l and ("Lvl " .. e.l .. " · ") or "", who, e.z or "?"), "red" })
            d = d + 1
            if d >= 6 then break end
        end
    end
    if d == 0 then tinsert(lines, { "", "None yet." }) end
    local killers = Top("killers", 4)
    if #killers > 0 then
        tinsert(lines, { title = "KILLED BY" })
        for _, s in ipairs(killers) do tinsert(lines, { tostring(s.rec.n), s.rec.nm or tostring(s.id) }) end
    end
    local hurt = {}
    for id, rec in pairs(ns.char.tallies.hurtBy or {}) do tinsert(hurt, { id = id, rec = rec }) end
    table.sort(hurt, function(a, b) return (a.rec.d or 0) > (b.rec.d or 0) end)
    if #hurt > 0 then
        tinsert(lines, { title = "HURT MOST BY" })
        for i = 1, math.min(4, #hurt) do
            tinsert(lines, { tostring(hurt[i].rec.d or 0), string.format("%s, %d hits", hurt[i].rec.nm or tostring(hurt[i].id), hurt[i].rec.n or 0) })
        end
    end
    tinsert(lines, { title = "WEAPON SKILLS" })
    for _, s in ipairs(Top("skills", 6)) do tinsert(lines, { tostring(s.rec.v or s.rec.n), s.rec.nm or tostring(s.id) }) end
    local bySpell = TopBy("damageBySpell", "d", 6)
    if #bySpell > 0 then
        tinsert(lines, { title = "DAMAGE BY ABILITY" })
        for _, s in ipairs(bySpell) do tinsert(lines, { tostring(s.rec.d or 0), s.rec.nm or tostring(s.id) }) end
    end
    local to = TopBy("damageTo", "d", 6)
    if #to > 0 then
        tinsert(lines, { title = "MOST DAMAGED" })
        for _, s in ipairs(to) do tinsert(lines, { tostring(s.rec.d or 0), s.rec.nm or tostring(s.id) }) end
    end
    local healSp = TopBy("healBySpell", "d", 4)
    if #healSp > 0 then
        tinsert(lines, { title = "HEALING BY ABILITY" })
        for _, s in ipairs(healSp) do tinsert(lines, { tostring(s.rec.d or 0), s.rec.nm or tostring(s.id) }) end
    end
    local env = Top("env", 6)
    if #env > 0 then
        tinsert(lines, { title = "THE WORLD ITSELF" })
        for _, s in ipairs(env) do
            local name = ENV_NAMES[s.id] or tostring(s.id):lower()
            tinsert(lines, { tostring(s.rec.d or 0), string.format("damage from %s, %d times", name, s.rec.n or 0) })
        end
    end
    local errs = Top("errors", 6)
    if #errs > 0 then
        tinsert(lines, { title = "MISHAPS" })
        for _, s in ipairs(errs) do tinsert(lines, { tostring(s.rec.n), s.rec.nm or tostring(s.id) }) end
    end
    return rows, lines
end

function CONTENT.loot()
    local c = ns.char.counters
    local rows = {
        { header = "LOOT BY QUALITY" },
        { "|cff9d9d9dPoor|r", tostring(c.lootGray) }, { "|cffffffffCommon|r", tostring(c.lootWhite) },
        { "|cff1eff00Uncommon|r", tostring(c.lootGreen) }, { "|cff0070ddRare|r", tostring(c.lootBlue) }, { "|cffa335eeEpic|r", tostring(c.lootEpic) },
        { header = "CONSUMED" },
        { "Meals", tostring(c.meals), ns.Duration(c.foodSeconds) .. " eating" }, { "Drinks", tostring(c.drinks), ns.Duration(c.drinkSeconds) .. " drinking" },
        { header = "GOLD BY SOURCE" },
    }
    local gold = ns.char.tallies.gold or {}
    local ctxs = {}
    for ctx in pairs(gold) do tinsert(ctxs, ctx) end
    table.sort(ctxs)
    table.sort(ctxs, function(a, b)
        local ga, gb = gold[a], gold[b]
        return math.abs((ga.i or 0) - (ga.o or 0)) > math.abs((gb.i or 0) - (gb.o or 0))
    end)
    for i = 1, math.min(8, #ctxs) do
        local ctx = ctxs[i]
        local g = gold[ctx]
        local v = (g.i or 0) - (g.o or 0)
        tinsert(rows, { ctx:sub(1, 1):upper() .. ctx:sub(2), (v >= 0 and "+" or "-") .. Coin(math.abs(v)), "", v >= 0 and "green" or "red" })
    end

    tinsert(rows, { header = "AUCTION HOUSE" })
    local ahSpent = c.ahSpent
    if C_AuctionHouse and gold.ah then ahSpent = math.max(ahSpent, gold.ah.o or 0) end -- commodity prices are not handed to addons
    tinsert(rows, { "Bought", tostring(c.ahBids + c.ahBuyouts), Coin(ahSpent) .. " spent" })
    tinsert(rows, { "Posted", tostring(c.ahPosted) })
    tinsert(rows, { "Sold", tostring(c.ahSold), Coin(c.ahSoldGold) .. " earned", "green" })
    local lines = {}
    if c.appearances + c.mounts + c.pets + c.toys + c.achievements > 0 then
        tinsert(lines, { title = "COLLECTED" })
        if c.appearances > 0 then tinsert(lines, { tostring(c.appearances), "Appearances" }) end
        if c.mounts > 0 then tinsert(lines, { tostring(c.mounts), "Mounts" }) end
        if c.pets > 0 then tinsert(lines, { tostring(c.pets), "Pets" }) end
        if c.toys > 0 then tinsert(lines, { tostring(c.toys), "Toys" }) end
        if c.achievements > 0 then tinsert(lines, { tostring(c.achievements), "Achievements" }) end
    end
    tinsert(lines, { title = "ITEMS LOOTED" })
    for _, it in ipairs(Top("items", 10)) do tinsert(lines, { tostring(it.rec.n), it.rec.nm or tostring(it.id) }) end
    tinsert(lines, { title = "ITEMS USED" })
    for _, it in ipairs(Top("used", 6)) do tinsert(lines, { tostring(it.rec.n), it.rec.nm or tostring(it.id) }) end
    tinsert(lines, { title = "BOUGHT" })
    local bought = Top("bought", 6)
    if #bought == 0 then tinsert(lines, { "", "Nothing yet." }) end
    for _, it in ipairs(bought) do tinsert(lines, { tostring(it.rec.n), it.rec.nm or tostring(it.id) }) end
    tinsert(lines, { title = "SOLD" })
    local sold = Top("sold", 6)
    if #sold == 0 then tinsert(lines, { "", "Nothing yet." }) end
    for _, it in ipairs(sold) do tinsert(lines, { tostring(it.rec.n), it.rec.nm or tostring(it.id) }) end
    tinsert(lines, { title = "BUFFS FROM STRANGERS" })
    for _, it in ipairs(Top("buffs", 6)) do tinsert(lines, { tostring(it.rec.n), it.rec.nm or tostring(it.id) }) end
    local ah = Top("ahBought", 5)
    if #ah > 0 then
        tinsert(lines, { title = "AUCTION BUYS" })
        for _, it in ipairs(ah) do tinsert(lines, { tostring(it.rec.n), string.format("%s, %s", it.rec.nm or tostring(it.id), Coin(it.rec.c or 0)) }) end
    end
    local posted = Top("ahPosted", 5)
    if #posted > 0 then
        tinsert(lines, { title = "AUCTION POSTS" })
        for _, it in ipairs(posted) do tinsert(lines, { tostring(it.rec.n), it.rec.nm or tostring(it.id) }) end
    end
    return rows, lines
end

function CONTENT.friends()
    local c, t = ns.char.counters, ns.char.tallies
    local sent, got = 0, 0
    for _, rec in pairs(t.whispers or {}) do sent = sent + (rec.o or 0); got = got + (rec.i or 0) end
    local function SumN(group)
        local n, friends = 0, 0
        for _, rec in pairs(t[group] or {}) do n = n + (rec.n or 0); friends = friends + (rec.f or 0) end
        return n, friends
    end
    local buffsIn, buffsInF = SumN("buffedBy")
    local buffsOut, buffsOutF = SumN("buffedTo")
    local rows = {
        { header = "WHISPERS" },
        { "Sent", tostring(sent) }, { "Received", tostring(got) },
        { header = "HELP" },
        { "Healing received", tostring(c.healingTaken) },
        { "Resurrections", tostring(c.rezzes) },
        { "Buffs received", tostring(buffsIn), string.format("%d party and guild · %d strangers", buffsInF, buffsIn - buffsInF) },
        (not ns.NO_CLEU or buffsOut > 0) and { "Buffs given", tostring(buffsOut), string.format("%d party and guild · %d strangers", buffsOutF, buffsOut - buffsOutF) } or nil,
        { "Party invites", tostring(c.partyInvites) },
        { header = "TRADING" },
        { "Trades", tostring(c.trades) },
        { "Mail sent", tostring(c.mailSent) },
        c.rolls > 0 and { "Rolls", tostring(c.rolls), string.format("%d won", c.rollsWon) } or { "Rolls won", tostring(c.rollsWon) },
        { header = "PVP" },
        { "Player kills", tostring(c.pvpKills) },
        { "Deaths to players", tostring(c.pvpDeaths), "", c.pvpDeaths > 0 and "red" or nil },
        { "Honorable kills", tostring(c.honorKills) },
    }
    local packed = {}
    for i = 1, 20 do if rows[i] then tinsert(packed, rows[i]) end end
    rows = packed
    local lines = { { title = "WHISPERED MOST" } }
    local w = Top("whispers", 6)
    if #w == 0 then tinsert(lines, { "", "Nobody yet." }) end
    for _, s in ipairs(w) do tinsert(lines, { tostring(s.rec.n), string.format("%s, %d sent · %d received", s.rec.nm or s.id, s.rec.o or 0, s.rec.i or 0) }) end
    local function Section(title, list, fmt)
        if #list == 0 then return end
        tinsert(lines, { title = title })
        for _, s in ipairs(list) do tinsert(lines, fmt(s)) end
    end
    Section("HEALED YOU", TopBy("healedBy", "d", 5), function(s) return { tostring(s.rec.d or 0), string.format("%s, %d heals", s.rec.nm or s.id, s.rec.n or 0) } end)
    Section("YOU HEALED", TopBy("healedTo", "d", 5), function(s) return { tostring(s.rec.d or 0), string.format("%s, %d heals", s.rec.nm or s.id, s.rec.n or 0) } end)
    Section("RESURRECTED YOU", Top("rezBy", 5), function(s) return { tostring(s.rec.n), s.rec.nm or tostring(s.id) } end)
    Section("BUFFED YOU", Top("buffedBy", 6), function(s) return { tostring(s.rec.n), s.rec.nm or tostring(s.id) } end)
    Section("YOU BUFFED", Top("buffedTo", 6), function(s) return { tostring(s.rec.n), s.rec.nm or tostring(s.id) } end)
    Section("TRADED WITH", Top("trades", 5), function(s)
        return { tostring(s.rec.n), string.format("%s, got %d items · gave %d", s.rec.nm or s.id, s.rec.i or 0, s.rec.o or 0) } end)
    Section("MAIL", Top("mailTo", 5), function(s)
        return { tostring(s.rec.n), string.format("sent to %s, %d items", s.rec.nm or s.id, s.rec.i or 0) } end)
    Section("DIED MOST IN YOUR GROUPS", Top("groupDeaths", 5), function(s) return { tostring(s.rec.n), s.rec.nm or tostring(s.id), "red" } end)
    Section("DAMAGE IN YOUR GROUPS", TopBy("groupDmg", "d", 6), function(s)
        return { tostring(s.rec.d or 0), string.format("%s, %d fights", s.rec.nm or s.id, s.rec.n or 0) } end)
    Section("HEALING IN YOUR GROUPS", TopBy("groupHeal", "d", 6), function(s)
        return { tostring(s.rec.d or 0), string.format("%s, %d fights", s.rec.nm or s.id, s.rec.n or 0) } end)
    Section("LUCKIEST ROLLERS", TopBy("rolls", "w", 6), function(s)
        -- Some clients only announce the winner, not each roll
        if (s.rec.hi or 0) == 0 then return { tostring(s.rec.w or 0), string.format("%s", s.rec.nm or s.id) } end
        return { tostring(s.rec.w or 0), string.format("%s, won %d of %d rolls, best %d", s.rec.nm or s.id, s.rec.w or 0, (s.rec.n or 0) + (s.rec.w or 0), s.rec.hi) } end)
    Section("PLAYERS YOU KILLED", Top("pvpKills", 5), function(s) return { tostring(s.rec.n), s.rec.nm or tostring(s.id) } end)
    Section("PLAYERS WHO KILLED YOU", Top("killedByPlayers", 5), function(s) return { tostring(s.rec.n), s.rec.nm or tostring(s.id), "red" } end)
    return rows, lines
end

local SETTINGS = {
    { header = "CHAT" },
    { key = "loginLine", label = "Login message" },
    { key = "versionNotice", label = "New version notice" },
    { key = "levelSummary", label = "Level-up summary in chat" },
    { header = "TOOLS" },
}

-- A rough size of the recording, worked out at most once a minute. (Building the real export string to
-- measure it took seconds on a long journey, and this tab refreshes every two.)
local sizeKB, sizeAt = 0, nil
local function DataSize()
    if sizeAt and ns.Now() - sizeAt < 60 then return sizeKB end
    local bytes = #ns.char.events * 70
    for _, chunks in pairs(ns.char.pos) do
        for _, chunk in ipairs(chunks) do bytes = bytes + #chunk end
    end
    sizeKB, sizeAt = bytes / 1024, ns.Now()
    return sizeKB
end

function CONTENT.settings()
    local rows = {}
    for _, s in ipairs(SETTINGS) do tinsert(rows, s) end
    local size = DataSize()
    local lines = { { title = "DATA" },
        { "Size", string.format("about %s, %d sessions", size >= 1024 and string.format("%.1f MB", size / 1024) or string.format("%d KB", size), #ns.char.sessions) },
        { "Oldest", ns.char.sessions[1] and Day(ns.char.sessions[1].t0) or "" },
        { "File", "WTF\\Account\\<account>\\SavedVariables\\Hearthlog.lua" },
        { title = "TOOLS" },
        { "Pause", "Stops recording until you press Resume or log in again." },
        { "Versions", "Lists who in your group and guild has Hearthlog, and which version." },
        { "Export", "Your character's data as one string to copy." },
        { title = "RESET" },
        { "", "Erases this character's journey. Asks twice. Type /hl reset confirm." },
    }
    return rows, lines
end

-- ---------------------------------------------------------
-- Frame
-- ---------------------------------------------------------
local function Font(fs, path, size, color, flags)
    fs:SetFont(path, size, flags or "")
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
end

local function Build()
    frame = CreateFrame("Frame", "HearthlogFrame", UIParent, "BackdropTemplate")
    frame:SetSize(W, H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()
    tinsert(UISpecialFrames, "HearthlogFrame")

    widgets.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widgets.title:SetPoint("TOPLEFT", 28, -18)
    widgets.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widgets.sub:SetPoint("LEFT", widgets.title, "RIGHT", 10, -1)
    widgets.right = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widgets.right:SetPoint("TOPRIGHT", -44, -20)

    widgets.plate = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    widgets.plate:SetSize(180, 30)
    widgets.plate:SetPoint("TOP", 0, 12)
    widgets.plateText = widgets.plate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widgets.plateText:SetPoint("CENTER")
    widgets.plateText:SetText("HEARTHLOG")

    widgets.grain = frame:CreateTexture(nil, "BORDER")
    widgets.grain:SetPoint("TOPLEFT", 4, -4)
    widgets.grain:SetPoint("BOTTOMRIGHT", -4, 4)
    widgets.grain:SetAlpha(0.28)

    -- Portrait: the game's square portrait cut to a circle by our own mask texture, a gold ring on top.
    -- Textures/mask.tga and ring.tga ship with the addon so this looks the same on every client.
    local TEX = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\"
    widgets.portrait = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    widgets.portrait:SetSize(60, 60)
    widgets.portrait:SetPoint("TOPLEFT", -16, 16)
    local masked = false
    if frame.CreateMaskTexture and widgets.portrait.AddMaskTexture then
        masked = pcall(function()
            local mask = frame:CreateMaskTexture()
            mask:SetTexture(TEX .. "mask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(widgets.portrait)
            widgets.portrait:AddMaskTexture(mask)
            widgets.portraitMask = mask
        end)
    end
    if not masked and widgets.portrait.SetMask then pcall(widgets.portrait.SetMask, widgets.portrait, TEX .. "mask") end
    widgets.portraitRing = frame:CreateTexture(nil, "ARTWORK", nil, 2)
    widgets.portraitRing:SetSize(64, 64)
    widgets.portraitRing:SetPoint("CENTER", widgets.portrait, "CENTER", 0, 0)
    widgets.portraitRing:SetTexture(TEX .. "ring")
    widgets.portraitRing:SetVertexColor(0.78, 0.62, 0.26, 1)

    widgets.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    widgets.close:SetPoint("TOPRIGHT", 2, 2)

    widgets.divider = frame:CreateTexture(nil, "ARTWORK")
    widgets.divider:SetHeight(1)
    widgets.divider:SetPoint("TOPLEFT", 26, -46)
    widgets.divider:SetPoint("TOPRIGHT", -26, -46)

    -- Left pane: rows
    widgets.left = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    widgets.left:SetPoint("TOPLEFT", 24, -56)
    widgets.left:SetSize(LEFT_W, H - 56 - 52)
    widgets.rows = {}
    for i = 1, 23 do
        local r = CreateFrame("Button", nil, widgets.left)
        r:SetSize(LEFT_W - 12, ROW_H)
        r:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_H)
        r.bg = r:CreateTexture(nil, "BACKGROUND")
        r.bg:SetAllPoints()
        r.bg:SetColorTexture(1, 1, 1, 0.03)
        r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.label:SetPoint("LEFT", 6, 0)
        r.label:SetJustifyH("LEFT")
        r.value = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.value:SetPoint("RIGHT", -6, 0)
        r.value:SetJustifyH("RIGHT")
        r.note = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.note:SetPoint("LEFT", r.label, "RIGHT", 6, 0)
        r.leader = r:CreateTexture(nil, "ARTWORK")
        r.leader:SetHeight(1)
        r.leader:SetPoint("BOTTOMLEFT", 6, 4)
        r.leader:SetPoint("BOTTOMRIGHT", -6, 4)
        r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.check:SetSize(22, 22)
        r.check:SetPoint("LEFT", 2, 0)
        r.check:Hide()
        r.check:SetScript("OnClick", function(self)
            local s = self.setting
            if not s then return end
            if s.skin then
                ns.SetSkin(s.skin)
            else
                ns.db.settings[s.key] = self:GetChecked() and true or false
            end
            ns.RefreshUI()
        end)
        widgets.rows[i] = r
    end

    -- Right pane: scrolling log
    widgets.rightPane = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    widgets.rightPane:SetPoint("TOPLEFT", widgets.left, "TOPRIGHT", 10, 0)
    widgets.rightPane:SetPoint("BOTTOMRIGHT", -24, 52)
    widgets.scroll = CreateFrame("ScrollFrame", "HearthlogScroll", widgets.rightPane, "UIPanelScrollFrameTemplate")
    widgets.scroll:SetPoint("TOPLEFT", 8, -8)
    widgets.scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    widgets.logChild = CreateFrame("Frame", nil, widgets.scroll)
    widgets.logChild:SetSize(1, 1)
    widgets.scroll:SetScrollChild(widgets.logChild)
    widgets.lines = {} -- one stamp + text pair per line, made as needed (see LogLine)

    -- Tabs
    widgets.tabs = {}
    for i, id in ipairs(TABS) do
        local b = CreateFrame("Button", nil, frame, "BackdropTemplate")
        b.id = id
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER")
        b:SetScript("OnClick", function() ns.ShowTab(id) end)
        widgets.tabs[i] = b
    end

    -- Buttons: live on the Settings tab, under the TOOLS header
    widgets.buttons = {}
    local defs = { { "Pause", function() ns.paused = not ns.paused; ns.RefreshUI() end },
                   { "Versions", function() if ns.WhoHasAddon then ns.WhoHasAddon() end end },
                   { "Export", function() if ns.ShowExport then ns.ShowExport() end end } }
    local toolsRow = #SETTINGS -- the TOOLS header is the last settings row
    for i, d in ipairs(defs) do
        local b = CreateFrame("Button", nil, widgets.left, "UIPanelButtonTemplate")
        b:SetSize(88, 22)
        b:SetText(d[1])
        b:SetScript("OnClick", d[2])
        b:SetPoint("TOPLEFT", widgets.left, "TOPLEFT", 8 + (i - 1) * 94, -6 - toolsRow * ROW_H - 4)
        b:Hide()
        widgets.buttons[i] = b
    end
end

local STAMP_W = 60
local function LogLine(i)
    local l = widgets.lines[i]
    if l then return l end
    l = {}
    l.stamp = widgets.logChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.stamp:SetJustifyH("LEFT")
    if l.stamp.SetWordWrap then l.stamp:SetWordWrap(false) end
    l.text = widgets.logChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.text:SetJustifyH("LEFT")
    l.text:SetJustifyV("TOP")
    widgets.lines[i] = l
    return l
end

local function ApplySkin(id)
    skin = SKINS[id] or SKINS.b
    frame:SetBackdrop({ bgFile = skin.bg, edgeFile = skin.border, tile = skin.bgTile, tileSize = 32, edgeSize = skin.edge,
        insets = { left = skin.edge / 4, right = skin.edge / 4, top = skin.edge / 4, bottom = skin.edge / 4 } })
    frame:SetBackdropColor(unpack(skin.bgColor))
    frame:SetBackdropBorderColor(unpack(skin.borderColor))

    Font(widgets.title, skin.font, 20, skin.title)
    Font(widgets.sub, skin.bodyFont, 12, skin.note)
    Font(widgets.right, skin.bodyFont, 11, skin.note)
    Font(widgets.plateText, skin.font, 14, skin.title)
    widgets.divider:SetColorTexture(skin.paneBorder[1], skin.paneBorder[2], skin.paneBorder[3], 0.8)

    local pane = { bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } }
    for _, p in ipairs({ widgets.left, widgets.rightPane }) do
        p:SetBackdrop(pane)
        p:SetBackdropColor(unpack(skin.paneBg))
        p:SetBackdropBorderColor(unpack(skin.paneBorder))
    end

    if skin.grain then
        widgets.grain:SetTexture(skin.grain)
        widgets.grain:Show()
    else
        widgets.grain:Hide()
    end
    if id == "b" then
        widgets.plate:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", edgeSize = 16, tile = true, tileSize = 16 })
        widgets.plate:Show()
        if SetPortraitTexture then SetPortraitTexture(widgets.portrait, "player") end
        widgets.portrait:Show()
        widgets.portraitRing:Show()
        widgets.title:ClearAllPoints()
        widgets.title:SetPoint("TOPLEFT", 50, -22)
    else
        widgets.plate:Hide()
        widgets.portrait:Hide()
        widgets.portraitRing:Hide()
        widgets.title:ClearAllPoints()
        widgets.title:SetPoint("TOPLEFT", 28, -18)
    end

    for i, r in ipairs(widgets.rows) do
        Font(r.label, skin.bodyFont, 12, skin.label)
        Font(r.value, skin.bodyFont, 12, skin.value)
        Font(r.note, skin.bodyFont, 10, skin.note)
        r.bg:SetShown(id == "b" and i % 2 == 0)
        r.leader:SetColorTexture(skin.note[1], skin.note[2], skin.note[3], skin.ruled and 0.35 or 0)
    end

    -- Tabs: right edge for the journal, hanging below for the game style
    for i, b in ipairs(widgets.tabs) do
        b:ClearAllPoints()
        b.text:SetText(skin.tabNames[i])
        if skin.tabs == "right" then
            b:SetSize(26, 80)
            b:SetPoint("TOPLEFT", frame, "TOPRIGHT", -4, -60 - (i - 1) * 86)
            Font(b.text, skin.font, 11, skin.label)
            if b.text.SetRotation then b.text:SetRotation(-math.pi / 2) end
        else
            b:SetSize(96, 28)
            b:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 20 + (i - 1) * 100, 6)
            Font(b.text, skin.font, 11, skin.label)
            if b.text.SetRotation then b.text:SetRotation(0) end
        end
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    end
end

function ns.SetSkin(id)
    if not SKINS[id] then return end
    ns.db.settings.ui = id
    if frame then ApplySkin(id); ns.RefreshUI() end
end

local function RefreshTabs()
    for _, b in ipairs(widgets.tabs) do
        local active = b.id == current
        if skin.tabs == "right" then
            b:SetBackdropColor(active and 0.91 or 0.80, active and 0.86 or 0.73, active and 0.74 or 0.58, 1)
            b:SetBackdropBorderColor(0.55, 0.45, 0.28, 1)
        else
            b:SetBackdropColor(active and 0.16 or 0.08, active and 0.14 or 0.09, active and 0.06 or 0.12, 1)
            b:SetBackdropBorderColor(active and 0.83 or 0.48, active and 0.66 or 0.38, active and 0.29 or 0.19, 1)
        end
        b.text:SetTextColor(active and skin.title[1] or skin.note[1], active and skin.title[2] or skin.note[2], active and skin.title[3] or skin.note[3])
    end
end

function ns.RefreshUI()
    if not frame or not frame:IsShown() or not ns.char then return end
    local meta = ns.char.meta
    widgets.title:SetText(meta.name or "")
    widgets.sub:SetText(string.format("Level %d %s %s", ns.level or UnitLevel("player"), meta.race or "", (meta.class or ""):sub(1, 1) .. (meta.class or ""):sub(2):lower()))
    widgets.right:SetText(string.format("%s  ·  %d sessions  ·  %s", meta.realm or "", #ns.char.sessions, ns.paused and "|cffff5555paused|r" or "recording"))
    widgets.buttons[1]:SetText(ns.paused and "Resume" or "Pause")
    for _, b in ipairs(widgets.buttons) do b:SetShown(current == "settings") end

    local rows, lines = CONTENT[current]()
    for i, r in ipairs(widgets.rows) do
        local d = rows[i]
        r.check:Hide()
        r.check.setting = nil
        if not d then
            r:Hide()
        else
            r:Show()
            if d.header then
                r.label:ClearAllPoints()
                r.label:SetPoint("LEFT", 6, 0)
                r.label:SetText(d.header)
                Font(r.label, skin.font, 11, skin.header)
                r.value:SetText("")
                r.note:SetText("")
                r.leader:Hide()
            elseif d.key then
                r.label:SetText(d.label)
                Font(r.label, skin.bodyFont, 12, skin.label)
                r.label:ClearAllPoints()
                r.label:SetPoint("LEFT", 28, 0)
                r.value:SetText("")
                r.note:SetText("")
                r.leader:Hide()
                r.check:Show()
                r.check.setting = d
                if d.skin then r.check:SetChecked(ns.db.settings.ui == d.skin) else r.check:SetChecked(ns.db.settings[d.key] and true or false) end
            else
                r.label:ClearAllPoints()
                r.label:SetPoint("LEFT", 6, 0)
                r.label:SetText(d[1])
                Font(r.label, skin.bodyFont, 12, skin.label)
                r.value:SetText(d[2] or "")
                local color = d[4] and skin[d[4]] or skin.value
                r.value:SetTextColor(color[1], color[2], color[3])
                r.note:SetText(d[3] or "")
                r.leader:SetShown(skin.ruled)
            end
        end
    end

    -- Right pane: a narrow column for the count, date or time, and a text column that wraps under itself
    local width = (widgets.scroll:GetWidth() or 0) - 4
    if width < 100 then width = W - LEFT_W - 96 end -- not laid out yet on the very first frame
    local y = 0
    for i, l in ipairs(lines) do
        local w = LogLine(i)
        w.stamp:ClearAllPoints()
        w.text:ClearAllPoints()
        local stamp = (not l.title) and l[1] or ""
        if l.title then
            if i > 1 then y = y + 6 end
            Font(w.text, skin.font, 12, skin.header)
        else
            Font(w.text, skin.bodyFont, 12, l[3] and skin[l[3]] or skin.label)
        end
        if stamp == "" then
            w.stamp:Hide()
            w.text:SetPoint("TOPLEFT", 0, -y)
            w.text:SetWidth(width)
        else
            Font(w.stamp, skin.bodyFont, 12, skin.note)
            w.stamp:SetPoint("TOPLEFT", 0, -y)
            w.stamp:SetWidth(STAMP_W)
            w.stamp:SetText(stamp)
            w.stamp:Show()
            w.text:SetPoint("TOPLEFT", STAMP_W + 8, -y)
            w.text:SetWidth(width - STAMP_W - 8)
        end
        w.text:SetText(l.title or l[2] or "")
        w.text:Show()
        y = y + math.max(w.text:GetStringHeight() or 0, 12) + 5
    end
    for i = #lines + 1, #widgets.lines do
        widgets.lines[i].stamp:Hide()
        widgets.lines[i].text:Hide()
    end
    widgets.logChild:SetSize(width, y + 8)
    RefreshTabs()
end

function ns.ShowTab(id)
    current = id
    ns.RefreshUI()
end

function ns.ToggleUI(skinId)
    if not ns.char then return end
    if not frame then Build() end
    if skinId and SKINS[skinId] then ns.db.settings.ui = skinId end
    if frame:IsShown() and not skinId then
        frame:Hide()
        return
    end
    ApplySkin(ns.db.settings.ui or "a")
    frame:Show()
    ns.RefreshUI()
end

-- Keep the window fresh while open
ns.Ticker(2, function() if frame and frame:IsShown() then ns.RefreshUI() end end)

ns.LOADED.UI = true
