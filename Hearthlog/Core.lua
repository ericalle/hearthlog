local ADDON_NAME, ns = ...
local Print, Now = ns.Print, ns.Now

-- =========================================================
-- CORE: database, sessions, event bus, slash commands
-- =========================================================
-- Layout of HearthlogDB (schema 1):
--   schema   = 1
--   maps     = { [uiMapID] = { name, parent, kind, inst, l, t, r, b } }  -- zone -> world bounds, filled on first sight
--   chars    = { ["Name-Realm"] = char }
-- char:
--   meta     = { name, realm, class, race, sex, faction, created, probeLeft }
--   sessions = { { t0, t1, lvl0, lvl1, played, reload } ... }
--   pos      = { [sessionIndex] = { chunk, chunk, ... } }  -- Track.lua, packed samples
--   events   = { { t=, k=, ... } ... }                      -- Events.lua
--   counters = { ... }                                      -- running totals
--   tallies  = { items={}, used={}, spells={}, skills={}, buffs={}, emotes={}, chat={}, gold={} }
--              per-id or per-name counts: [id] = { n = count, nm = name, q = quality }
--              gold: [context] = { n = changes, i = copper in, o = copper out }
--   probe    = { events = { [name] = { n, args, sample } } } -- Probe.lua

ns.db = nil     -- HearthlogDB
ns.char = nil   -- HearthlogDB.chars[key]
ns.session = nil
ns.sessionIndex = nil
ns.paused = false

local DEFAULT_COUNTERS = {
    kills = 0, assists = 0, deaths = 0, questsAccepted = 0, questsDone = 0, questsAbandoned = 0,
    goldIn = 0, goldOut = 0, jumps = 0, hearths = 0, taxis = 0, taxiGold = 0, levels = 0,
    xp = 0, xpKill = 0, xpQuest = 0, xpOther = 0, lootGreen = 0, lootBlue = 0, lootEpic = 0,
    fights = 0, fightSeconds = 0, damageTaken = 0, healingDone = 0, gz = 0, duels = 0,
    samples = 0, idleSeconds = 0, teleports = 0, discoveries = 0,
    swings = 0, swingMisses = 0, shots = 0, casts = 0, critsDone = 0, critsTaken = 0,
    maxHitDone = 0, maxHitTaken = 0, dodged = 0, parried = 0,
    meals = 0, drinks = 0, foodSeconds = 0, drinkSeconds = 0, strangerBuffs = 0,
    lootItems = 0, lootGray = 0, lootWhite = 0, emotes = 0, messages = 0,
    miles = { f = 0, m = 0, t = 0, s = 0, g = 0, v = 0, b = 0 },
}
local TALLIES = { "items", "used", "spells", "skills", "buffs", "emotes", "chat", "gold" }

local function Fill(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            Fill(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end
ns.Fill = Fill

-- ---------------------------------------------------------
-- Event bus: files register handlers with ns.On(event, fn)
-- ---------------------------------------------------------
local handlers = {}
local frame = CreateFrame("Frame")

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        -- A client without this event refuses the registration; that is fine
        pcall(frame.RegisterEvent, frame, event)
    end
    tinsert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok and ns.debug then Print(event .. " handler error: " .. tostring(err)) end
    end
end)

-- ---------------------------------------------------------
-- Database
-- ---------------------------------------------------------
local function InitDB()
    HearthlogDB = HearthlogDB or {}
    local db = HearthlogDB
    db.schema = db.schema or ns.SCHEMA
    db.maps = db.maps or {}
    db.chars = db.chars or {}
    ns.db = db
end

local function InitChar()
    local key = ns.CharKey()
    local char = ns.db.chars[key]
    if not char then
        char = { sessions = {}, pos = {}, events = {}, counters = {}, probe = { events = {} } }
        ns.db.chars[key] = char
    end
    char.sessions = char.sessions or {}
    char.pos = char.pos or {}
    char.events = char.events or {}
    char.counters = Fill(char.counters or {}, DEFAULT_COUNTERS)
    char.tallies = char.tallies or {}
    for _, name in ipairs(TALLIES) do char.tallies[name] = char.tallies[name] or {} end
    char.probe = char.probe or { events = {} }
    ns.level = UnitLevel("player")

    local _, class = UnitClass("player")
    local _, race = UnitRace("player")
    char.meta = char.meta or {}
    local meta = char.meta
    meta.name = UnitName("player")
    meta.realm = GetRealmName()
    meta.class = class
    meta.race = race
    meta.sex = UnitSex("player")
    meta.faction = UnitFactionGroup("player")
    meta.created = meta.created or Now()
    if meta.probeLeft == nil then meta.probeLeft = 3 end -- Sessions the probe stays on after install
    meta.version = ns.VERSION
    meta.client = ns.ClientName()

    ns.char = char
    ns.key = key
end

-- Which client we are on, for the record and for the viewer
function ns.ClientName()
    local _, build, _, toc = GetBuildInfo()
    toc = tonumber(toc) or 0
    if toc >= 160000 and toc < 170000 then return "forever" end
    if toc >= 100000 then return "retail" end
    if toc < 20000 then return "era" end
    return "classic" .. toc
end

-- ---------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------
local function OpenSession(isReload)
    local char = ns.char
    local s = { t0 = Now(), lvl0 = UnitLevel("player"), reload = isReload and true or nil }
    tinsert(char.sessions, s)
    ns.session = s
    ns.sessionIndex = #char.sessions
    char.pos[ns.sessionIndex] = char.pos[ns.sessionIndex] or {}
    if ns.OnSessionOpen then ns.OnSessionOpen(s) end
end

local function CloseSession()
    local s = ns.session
    if not s then return end
    s.t1 = Now()
    s.lvl1 = ns.level or UnitLevel("player")
    if ns.OnSessionClose then ns.OnSessionClose(s) end
end

-- /played: ask once at login, swallow the chat lines it prints
local waitingPlayed = false
ns.On("TIME_PLAYED_MSG", function(total, level)
    if ns.session then
        ns.session.played = total
        ns.session.playedLevel = level
    end
    if ns.char then ns.char.meta.played = total end
    waitingPlayed = false
end)

-- The chat frame prints /played through ChatFrame_DisplayTimePlayed, not as a
-- CHAT_MSG_SYSTEM, so a message filter does not catch it. While a request we
-- made is in flight, that function is swapped for a no-op, then put back.
-- Classic Era 1.15 prints through ChatFrameUtil.DisplayTimePlayed; older
-- clients through the global ChatFrame_DisplayTimePlayed. Both are swapped.
local swapped = nil
local function Silence()
    if swapped then return end
    swapped = {}
    if type(ChatFrame_DisplayTimePlayed) == "function" then
        swapped.global = ChatFrame_DisplayTimePlayed
        ChatFrame_DisplayTimePlayed = function() end
    end
    if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.DisplayTimePlayed) == "function" then
        swapped.util = ChatFrameUtil.DisplayTimePlayed
        ChatFrameUtil.DisplayTimePlayed = function() end
    end
end
local function Unsilence()
    if not swapped then return end
    if swapped.global then ChatFrame_DisplayTimePlayed = swapped.global end
    if swapped.util then ChatFrameUtil.DisplayTimePlayed = swapped.util end
    swapped = nil
end
local function RequestPlayed()
    if not RequestTimePlayed then return end
    waitingPlayed = true
    Silence()
    pcall(RequestTimePlayed)
    C_Timer.After(3, function()
        waitingPlayed = false
        Unsilence()
    end)
end
ns.RequestPlayed = RequestPlayed

-- ---------------------------------------------------------
-- Recording helpers used by Track.lua and Events.lua
-- ---------------------------------------------------------
-- Add an event to the stream. Position fields are added by Track.Stamp.
function ns.Event(kind, fields)
    if ns.paused or not ns.char then return nil end
    local e = fields or {}
    e.t = Now()
    e.k = kind
    if ns.Stamp then ns.Stamp(e) end
    tinsert(ns.char.events, e)
    return e
end

function ns.Count(key, n)
    local c = ns.char and ns.char.counters
    if not c then return end
    c[key] = (c[key] or 0) + (n or 1)
end

-- Keep the largest value seen
function ns.Max(key, v)
    local c = ns.char and ns.char.counters
    if not c or type(v) ~= "number" then return end
    if v > (c[key] or 0) then c[key] = v end
end

-- Per-id tally: ns.Tally("items", 2589, "Linen Cloth", { q = 1 })
function ns.Tally(group, id, name, extra)
    if ns.paused or not ns.char or id == nil then return end
    local t = ns.char.tallies[group]
    if not t then
        t = {}
        ns.char.tallies[group] = t
    end
    local rec = t[id]
    if not rec then
        rec = { n = 0, nm = name }
        if extra then for k, v in pairs(extra) do rec[k] = v end end
        t[id] = rec
    end
    rec.n = rec.n + 1
    if name and not rec.nm then rec.nm = name end
    return rec
end

-- ---------------------------------------------------------
-- Status
-- ---------------------------------------------------------
local function Status()
    local char, c = ns.char, ns.char.counters
    Print(string.format("v%s on %s  ·  %s  ·  schema %d", ns.VERSION, ns.ClientName(), ns.key, ns.db.schema))
    local samplesNow = ns.Track and ns.Track.Buffered() or 0
    for _, chunk in ipairs(char.pos[ns.sessionIndex] or {}) do
        local _, n = chunk:gsub(";", "")
        samplesNow = samplesNow + n + 1
    end
    Print(string.format("session %d started %s ago  ·  %s  ·  %d samples this session, %d events total",
        ns.sessionIndex, ns.Duration(Now() - ns.session.t0), ns.paused and "|cffff5555PAUSED|r" or "recording",
        samplesNow, #char.events))
    Print(string.format("kills %d  deaths %d  quests %d/%d  levels +%d  jumps %d  gold +%s/-%s",
        c.kills, c.deaths, c.questsDone, c.questsAccepted, c.levels, c.jumps,
        GetCoinTextureString and GetCoinTextureString(c.goldIn) or c.goldIn,
        GetCoinTextureString and GetCoinTextureString(c.goldOut) or c.goldOut))
    local m = c.miles
    Print(string.format("yards: foot %d  mount %d  taxi %d  swim %d  ghost %d  form %d  boat %d  ·  idle %s",
        m.f, m.m, m.t, m.s, m.g, m.v, m.b, ns.Duration(c.idleSeconds)))
    local function n(group) local k = 0 for _ in pairs(char.tallies[group] or {}) do k = k + 1 end return k end
    Print(string.format("swings %d (missed %d)  shots %d  casts %d  ·  biggest hit %d / taken %d  ·  meals %d (%s) drinks %d (%s)",
        c.swings, c.swingMisses, c.shots, c.casts, c.maxHitDone, c.maxHitTaken, c.meals, ns.Duration(c.foodSeconds),
        c.drinks, ns.Duration(c.drinkSeconds)))
    Print(string.format("tallies: %d items looted (%d kinds)  %d item kinds used  %d spells  %d skills  %d stranger buffs  %d emotes  %d messages",
        c.lootItems, n("items"), n("used"), n("spells"), n("skills"), c.strangerBuffs, c.emotes, c.messages))
    local maps = 0
    for _ in pairs(ns.db.maps) do maps = maps + 1 end
    Print(string.format("%d sessions  ·  %d maps known  ·  probe %s (%d sessions left)",
        #char.sessions, maps, ns.ProbeActive and ns.ProbeActive() and "on" or "off", char.meta.probeLeft or 0))
    if ns.TrackDebug then ns.TrackDebug(Print) end
end

-- ---------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------
SLASH_HEARTHLOG1 = "/hl"
SLASH_HEARTHLOG2 = "/hearthlog"
SlashCmdList.HEARTHLOG = function(msg)
    local cmd, arg = strsplit(" ", strtrim((msg or ""):lower()), 2)
    if cmd == "" or cmd == "status" then
        Status()
    elseif cmd == "pause" then
        ns.paused = not ns.paused
        Print(ns.paused and "paused: nothing is recorded until /hl pause again or relog" or "recording again")
    elseif cmd == "probe" then
        if ns.ProbeCommand then ns.ProbeCommand(arg) end
    elseif cmd == "export" then
        if ns.ShowExport then ns.ShowExport() end
    elseif cmd == "events" then
        local n = tonumber(arg) or 10
        local list = ns.char.events
        Print(string.format("last %d of %d events:", math.min(n, #list), #list))
        for i = math.max(1, #list - n + 1), #list do
            local e = list[i]
            local parts = {}
            for k, v in pairs(e) do
                if k ~= "t" and k ~= "k" then tinsert(parts, k .. "=" .. tostring(type(v) == "table" and ("{" .. #v .. "}") or v)) end
            end
            table.sort(parts)
            Print(string.format("  %s %s %s", date("%H:%M:%S", e.t), e.k, table.concat(parts, " ")))
        end
    elseif cmd == "top" then
        -- /hl top items|used|spells|skills|buffs|emotes|chat [n]
        local group, count = strsplit(" ", arg or "", 2)
        local t = ns.char.tallies[group or ""]
        if not t then
            Print("/hl top items|used|spells|skills|buffs|emotes|chat|gold [n]")
            return
        end
        count = tonumber(count) or 15
        local list = {}
        for id, rec in pairs(t) do tinsert(list, { id = id, rec = rec }) end
        table.sort(list, function(a, b) return (a.rec.n or 0) > (b.rec.n or 0) end)
        Print(string.format("top %d of %d %s:", math.min(count, #list), #list, group))
        local coin = GetCoinTextureString or tostring
        for i = 1, math.min(count, #list) do
            local r = list[i].rec
            if group == "gold" then
                Print(string.format("  %-8s  in %s  out %s  (%d changes)", tostring(list[i].id), coin(r.i or 0), coin(r.o or 0), r.n))
            else
                Print(string.format("  %6d  %s%s", r.n, tostring(r.nm or list[i].id), r.v and ("  (now " .. r.v .. ")") or ""))
            end
        end
    elseif cmd == "who" then
        if ns.WhoHasAddon then ns.WhoHasAddon() end
    elseif cmd == "version" then
        Print(string.format("v%s  ·  %s", ns.VERSION, ns.URL))
    elseif cmd == "debug" then
        ns.debug = not ns.debug
        Print("debug " .. (ns.debug and "on" or "off"))
    elseif cmd == "reset" and arg == "confirm" then
        ns.db.chars[ns.key] = nil
        InitChar()
        OpenSession(false)
        Print("this character's journey was erased")
    else
        Print("/hl status · /hl events [n] · /hl top <items|used|spells|skills|buffs|emotes|chat|gold> · /hl who · /hl probe [on|off|list] · /hl pause · /hl export · /hl reset confirm")
    end
end

-- ---------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------
local loaded, entered = false, false
ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON_NAME or loaded then return end
    loaded = true
    InitDB()
end)

ns.On("PLAYER_LOGIN", function()
    InitChar()
    if ns.OnLogin then ns.OnLogin() end
end)

ns.On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if not entered then
        entered = true
        OpenSession(isReload)
        C_Timer.After(3, RequestPlayed)
        Print(string.format("recording %s (session %d). /hl for status.", ns.key, ns.sessionIndex))
    end
    if ns.OnEnterWorld then ns.OnEnterWorld(isLogin, isReload) end
end)

ns.On("PLAYER_LOGOUT", function()
    CloseSession()
end)
