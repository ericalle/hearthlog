local ADDON_NAME, ns = ...
local Print = ns.Print

-- =========================================================
-- PROBE: what does this client actually fire?
-- =========================================================
-- Hearthlog was written before WoW Forever could be tested. For the first
-- few sessions after install, a frame registered for every event records
-- each event name, how often it fired, and the types of its arguments the
-- first time it was seen (plus a short sample of string and number values).
-- The result lives in char.probe.events and is read with /hl probe list,
-- or from the SavedVariables file.
--
-- Chatty events are counted but their samples are kept short.

local NOISY = {
    COMBAT_LOG_EVENT_UNFILTERED = true, UNIT_AURA = true, UNIT_HEALTH = true, UNIT_POWER_UPDATE = true,
    UNIT_POWER_FREQUENT = true, CURSOR_CHANGED = true, UPDATE_MOUSEOVER_UNIT = true, NAME_PLATE_UNIT_ADDED = true,
    NAME_PLATE_UNIT_REMOVED = true, UNIT_TARGET = true, SPELL_UPDATE_COOLDOWN = true, ACTIONBAR_UPDATE_COOLDOWN = true,
    BAG_UPDATE = true, BAG_UPDATE_COOLDOWN = true, UPDATE_INVENTORY_DURABILITY = true, UNIT_SPELLCAST_SENT = true,
    MODIFIER_STATE_CHANGED = true, UNIT_COMBAT = true, CHAT_MSG_ADDON = true, GUILD_ROSTER_UPDATE = true,
}

local frame = CreateFrame("Frame")
local active = false

local function Describe(...)
    local n = select("#", ...)
    local types, sample = {}, {}
    for i = 1, math.min(n, 8) do
        local v = select(i, ...)
        local t = type(v)
        types[i] = t:sub(1, 1) -- s n b t f n(il)
        if t == "string" then sample[i] = v:sub(1, 40):gsub("|", "/")
        elseif t == "number" or t == "boolean" then sample[i] = tostring(v)
        else sample[i] = t end
    end
    return table.concat(types, ""), table.concat(sample, " | ")
end

frame:SetScript("OnEvent", function(_, event, ...)
    local store = ns.char and ns.char.probe and ns.char.probe.events
    if not store then return end
    local rec = store[event]
    if not rec then
        local types, sample = Describe(...)
        rec = { n = 0, args = types, sample = NOISY[event] and nil or sample, first = ns.Now() }
        store[event] = rec
    end
    rec.n = rec.n + 1
end)

function ns.ProbeActive() return active end

local function Start()
    if active then return end
    active = true
    pcall(frame.RegisterAllEvents, frame)
end

local function Stop()
    if not active then return end
    active = false
    pcall(frame.UnregisterAllEvents, frame)
end

function ns.ProbeCommand(arg)
    if arg == "on" then
        Start()
        Print("probe on for this session")
    elseif arg == "off" then
        Stop()
        ns.char.meta.probeLeft = 0
        Print("probe off, and it stays off on later sessions")
    elseif arg == "list" then
        local store = ns.char.probe.events
        local names = {}
        for name in pairs(store) do tinsert(names, name) end
        table.sort(names, function(a, b) return store[a].n > store[b].n end)
        Print(string.format("%d distinct events seen (top 40 by count):", #names))
        for i = 1, math.min(40, #names) do
            local r = store[names[i]]
            Print(string.format("  %6d  %s (%s)%s", r.n, names[i], r.args, r.sample and ("  " .. r.sample) or ""))
        end
    else
        local store = ns.char.probe.events
        local count = 0
        for _ in pairs(store) do count = count + 1 end
        Print(string.format("probe %s · %d distinct events recorded · %d sessions left · /hl probe on|off|list",
            active and "on" or "off", count, ns.char.meta.probeLeft or 0))
    end
end

function ns.OnLogin()
    local meta = ns.char and ns.char.meta
    if not meta then return end
    if (meta.probeLeft or 0) > 0 then
        meta.probeLeft = meta.probeLeft - 1
        Start()
    end
end
