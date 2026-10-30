local ADDON_NAME, ns = ...
local Now, CallIn = ns.Now, ns.CallIn

-- =========================================================
-- TRACK: the path. One sample every TICK seconds while moving.
-- =========================================================
-- Sample format, one per entry, joined with ";" into chunks of CHUNK samples:
--   dt,map,x,y,m      dt = seconds since previous sample, map = uiMapID,
--                     x,y = map position * 1000, m = movement mode letter
--   P,seconds         a pause: the player stood still this long
--   M,map             the map changed to this id (also implied by a sample)
--   X                 position hidden (dungeon, battleground): no path until it comes back
--   T                 teleport: the next sample is far from the previous one (hearth, portal, summon, corpse release)
-- Modes: f foot · m mounted · t taxi · s swimming · g ghost · v druid travel/aquatic form · b transport (boat, zeppelin, tram)
-- World coordinates are not stored per sample. Each map's world bounds are
-- stored once in HearthlogDB.maps so the viewer can place any zone on the continent.

local TICK = 2            -- Seconds between samples while moving
local MOVE_MIN = 1.5      -- Yards: less than this between ticks counts as standing still
local TRANSPORT_MIN = 10  -- Yards in one tick with zero run speed: carried by a boat, zeppelin or tram
local CHUNK = 120         -- Samples per stored chunk
local TELEPORT = 300      -- Yards in one tick without taxi/transport: a teleport, not a walk

local Track = {}
ns.Track = Track

local last = { wx = nil, wy = nil, inst = nil, map = nil, t = 0, mode = nil }
local transportTicks = 0  -- Consecutive ticks that looked like a boat ride
local idle = 0
local buffer = {}         -- Samples waiting to be joined into a chunk
local hidden = false
local lastSampleT = nil
local ticker = nil

-- ---------------------------------------------------------
-- Maps registry: zone -> world bounds, recorded on first sight
-- ---------------------------------------------------------
local function RegisterMap(mapID)
    local maps = ns.db and ns.db.maps
    if not maps or not mapID or maps[mapID] then return end
    local info = CallIn(C_Map, "GetMapInfo", mapID)
    local entry = { name = info and info.name, parent = info and info.parentMapID, kind = info and info.mapType }
    -- World bounds: where the map's (0,0) and (1,1) corners sit in world space
    local inst0, tl = CallIn(C_Map, "GetWorldPosFromMapPos", mapID, { x = 0, y = 0 })
    local inst1, br = CallIn(C_Map, "GetWorldPosFromMapPos", mapID, { x = 1, y = 1 })
    if tl and br then
        entry.inst = inst0 or inst1
        -- GetWorldPosFromMapPos returns a vector whose .x is the north axis (UnitPosition's
        -- first return) and .y the east axis (its second). Stored as left/top/right/bottom
        -- so the viewer converts a map point with: east = l + (r - l) * mx, north = t + (b - t) * my
        entry.l, entry.t, entry.r, entry.b = ns.Round(tl.y, 1), ns.Round(tl.x, 1), ns.Round(br.y, 1), ns.Round(br.x, 1)
    end
    maps[mapID] = entry
end

-- ---------------------------------------------------------
-- Where am I, how am I moving
-- ---------------------------------------------------------
-- dist: yards moved since the last tick (nil when unknown), speed: run speed now
local function Mode(dist, speed)
    if UnitOnTaxi("player") then return "t" end
    if UnitIsDeadOrGhost("player") then return "g" end
    if IsSwimming and IsSwimming() then return "s" end
    if IsMounted() then return "m" end
    local formID = ns.Call("GetShapeshiftFormID")
    if formID == 3 or formID == 4 or formID == 27 or formID == 29 then return "v" end -- travel, aquatic, flight forms
    -- Carried by a boat, zeppelin or tram: the world moves under a standing player.
    -- A single tick can read speed 0 mid-run (a jump landing), so two in a row are needed.
    if dist and dist >= TRANSPORT_MIN and dist < TELEPORT and speed and speed < 0.1 then
        transportTicks = transportTicks + 1
        if transportTicks >= 2 then return "b" end
    else
        transportTicks = 0
    end
    return "f"
end

local function Position()
    -- UnitPosition returns y, x, z, instance
    local wy, wx, _, inst = UnitPosition("player")
    local mapID = CallIn(C_Map, "GetBestMapForUnit", "player")
    local mx, my
    if mapID then
        local pos = CallIn(C_Map, "GetPlayerMapPosition", mapID, "player")
        if pos then mx, my = pos.x, pos.y end
        if mx and (mx == 0 and my == 0) then mx, my = nil, nil end
    end
    return wx, wy, inst, mapID, mx, my
end

local function Push(sample)
    tinsert(buffer, sample)
    if #buffer >= CHUNK then Track.Flush() end
end

function Track.Buffered() return #buffer end

function Track.Flush()
    if #buffer == 0 or not ns.char or not ns.sessionIndex then return end
    local chunks = ns.char.pos[ns.sessionIndex]
    if not chunks then
        chunks = {}
        ns.char.pos[ns.sessionIndex] = chunks
    end
    tinsert(chunks, table.concat(buffer, ";"))
    buffer = {}
end

-- One tick: decide whether to store a sample
local function Tick()
    if ns.paused or not ns.char then return end
    local now = Now()
    local wx, wy, inst, mapID, mx, my = Position()

    -- Positions hidden (instance): note it once, keep ticking so we notice when they come back
    if not wx or not mx then
        if not hidden then
            hidden = true
            Push("X")
        end
        last.wx, last.wy = nil, nil
        return
    end
    if hidden then
        hidden = false
        last.wx, last.wy, last.t = nil, nil, now
    end

    if mapID ~= last.map then
        RegisterMap(mapID)
        last.map = mapID
    end

    local dist = 0
    local sameWorld = last.wx and last.inst == inst
    if sameWorld then dist = math.sqrt((wx - last.wx) ^ 2 + (wy - last.wy) ^ 2) end
    local speed = ns.Call("GetUnitSpeed", "player")
    local moved = (not sameWorld) or dist >= MOVE_MIN

    if not moved then
        idle = idle + TICK
        return
    end

    -- Resuming after standing still: record the pause first
    if idle >= 10 then
        Push("P," .. idle)
        ns.Count("idleSeconds", idle)
    end
    idle = 0

    local mode = Mode(sameWorld and dist or nil, speed)
    -- Distance credited to the mode, except teleports and continent changes.
    -- Taxis cover more ground per tick, so their teleport threshold is higher.
    local limit = (mode == "t") and TELEPORT * 3 or TELEPORT
    if sameWorld and dist < limit then
        local miles = ns.char.counters.miles
        miles[mode] = (miles[mode] or 0) + dist
    elseif sameWorld and mode ~= "t" then
        Push("T")
        ns.Count("teleports")
    end

    local dt = lastSampleT and (now - lastSampleT) or 0
    Push(string.format("%d,%d,%d,%d,%s", dt, mapID or 0, math.floor(mx * 1000 + 0.5), math.floor(my * 1000 + 0.5), mode))
    ns.Count("samples")
    lastSampleT = now
    last.wx, last.wy, last.inst, last.mode = wx, wy, inst, mode
end

-- Add the current position to an event (called by ns.Event)
function ns.Stamp(e)
    local _, _, _, mapID, mx, my = Position()
    if mapID and mx then
        e.m = mapID
        e.x = math.floor(mx * 1000 + 0.5)
        e.y = math.floor(my * 1000 + 0.5)
    end
    local zone = GetRealZoneText and GetRealZoneText()
    if zone and zone ~= "" then e.z = zone end
    return e
end

function ns.TrackDebug(print)
    local wx, wy, inst, mapID, mx, my = Position()
    local info = mapID and ns.db.maps[mapID]
    print(string.format("here: map %s (%s)  %.3f, %.3f  ·  world %s, %s on %s  ·  mode %s  ·  buffered %d  ·  idle %ds",
        tostring(mapID), info and info.name or "?", mx or -1, my or -1, wx and ns.Round(wx, 1) or "?",
        wy and ns.Round(wy, 1) or "?", tostring(inst), Mode(nil, 1), #buffer, idle))
end

-- ---------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------
function ns.OnSessionOpen()
    buffer, idle, hidden, lastSampleT = {}, 0, false, nil
    last.wx, last.wy, last.inst, last.map = nil, nil, nil, nil
    if not ticker then ticker = C_Timer.NewTicker(TICK, Tick) end
end

function ns.OnSessionClose()
    if idle >= 10 then Push("P," .. idle) end
    Track.Flush()
end
