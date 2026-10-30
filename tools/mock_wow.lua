-- Minimal mock of the WoW API surface Hearthlog touches, enough to load the
-- addon and fire events outside the game. Run with tools/smoke_test.py.
local M = {}
_G.HearthlogDB = nil

local printed = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) printed[#printed + 1] = msg; print(msg) end }
M.printed = printed

-- Frames and events
local frames = {}
local events = {}
function _G.CreateFrame(kind, name, parent, template)
    local f = { kind = kind, name = name, scripts = {}, events = {}, all = false }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:RegisterAllEvents() self.all = true end
    function f:UnregisterAllEvents() self.all = false; self.events = {} end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:GetScript(k) return self.scripts[k] end
    local noop = function() end
    for _, m in ipairs({ "SetSize", "SetPoint", "SetFrameStrata", "SetMovable", "EnableMouse", "RegisterForDrag", "SetBackdrop",
        "Hide", "Show", "SetMultiLine", "SetFontObject", "SetWidth", "SetAutoFocus", "SetScrollChild", "SetText", "SetFocus",
        "HighlightText", "StartMoving", "StopMovingOrSizing", "GetFontString" }) do f[m] = noop end
    function f:CreateFontString() return { SetPoint = noop, SetText = noop } end
    tinsert(frames, f)
    if name then _G[name] = f end
    return f
end
function M.Fire(event, ...)
    for _, f in ipairs(frames) do
        if (f.events[event] or f.all) and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

-- Timers: collected, run manually with M.RunTimers(seconds)
local timers = {}
_G.C_Timer = {
    After = function(delay, fn) tinsert(timers, { at = M.clock + delay, fn = fn }) end,
    NewTicker = function(period, fn)
        local t = { period = period, fn = fn, at = M.clock + period, ticker = true }
        tinsert(timers, t)
        return t
    end,
}
M.clock = 1000
function M.Advance(seconds)
    local target = M.clock + seconds
    while true do
        local nextT = nil
        for _, t in ipairs(timers) do
            if t.at <= target and (not nextT or t.at < nextT.at) then nextT = t end
        end
        if not nextT then break end
        M.clock = nextT.at
        if nextT.ticker then
            nextT.at = nextT.at + nextT.period
            nextT.fn()
        else
            for i, t in ipairs(timers) do if t == nextT then table.remove(timers, i) break end end
            nextT.fn()
        end
    end
    M.clock = target
end

-- Globals
_G.tinsert = table.insert
_G.strsplit = function(sep, s, limit)
    local out = {}
    local pattern = "([^" .. sep .. "]*)"
    local count = 0
    local pos = 1
    while true do
        if limit and count == limit - 1 then tinsert(out, s:sub(pos)) break end
        local a, b = s:find(sep, pos, true)
        if not a then tinsert(out, s:sub(pos)) break end
        tinsert(out, s:sub(pos, a - 1))
        pos = b + 1
        count = count + 1
    end
    return unpack(out)
end
_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.time = function() return M.clock end
_G.date = function(fmt, t) return "12:00:00" end
_G.GetServerTime = function() return M.clock end
_G.UnitName = function(u) if u == "player" then return "Zinther" end return M.units[u] and M.units[u].name end
_G.GetRealmName = function() return "Test Realm" end
_G.GetNormalizedRealmName = function() return "TestRealm" end
_G.UnitClass = function(u) return "Druid", "DRUID" end
_G.UnitRace = function(u) return "Tauren", "Tauren" end
_G.UnitSex = function() return 2 end
_G.UnitFactionGroup = function() return "Horde" end
_G.UnitLevel = function() return M.level end
_G.UnitXP = function() return M.xp end
_G.UnitGUID = function(u)
    if u == "player" then return "Player-1-000001" end
    if u == "target" then return M.targetGUID end
    return M.units[u] and M.units[u].guid
end
_G.GetBuildInfo = function() return "1.15.9", "60000", "2026-10-01", 11509 end
_G.GetMoney = function() return M.money end
_G.GetGuildInfo = function() return M.guild end
_G.IsInRaid = function() return false end
_G.GetNumSubgroupMembers = function() return #M.party end
_G.GetNumGroupMembers = function() return #M.party + 1 end
_G.IsInInstance = function() return M.inInstance, M.inInstance and "party" or "none" end
_G.GetInstanceInfo = function() return M.instanceName end
_G.GetRealZoneText = function() return M.zone end
_G.GetSubZoneText = function() return M.subzone end
_G.UnitPosition = function() if M.hidden then return nil end return M.wy, M.wx, 0, M.inst end
_G.GetUnitSpeed = function() return M.speed end
_G.UnitOnTaxi = function() return M.onTaxi end
_G.UnitIsDeadOrGhost = function(u) if u == "player" then return M.dead end return M.units[u] and M.units[u].dead end
_G.UnitIsGhost = function() return M.ghost end
_G.IsSwimming = function() return false end
_G.IsMounted = function() return M.mounted end
_G.GetShapeshiftFormID = function() return M.form end
_G.GetInventoryItemLink = function(_, slot) return M.gear[slot] end
_G.GetSpellInfo = function(id) return "Spell" .. id end
_G.GetBindLocation = function() return "Thunder Bluff" end
_G.RequestTimePlayed = function() M.Fire("TIME_PLAYED_MSG", 3600, 600) end
_G.ChatFrame_AddMessageEventFilter = function() end
_G.IsInGuild = function() return true end
_G.IsInGroup = function() return #M.party > 0 end
_G.LE_PARTY_CATEGORY_INSTANCE = 2
M.sentAddon = {}
_G.C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, msg, chan) tinsert(M.sentAddon, { prefix = prefix, msg = msg, chan = chan }) end,
}
_G.GetCoinTextureString = function(c) return tostring(c) .. "c" end
_G.UnitClassification = function() return M.targetClass end
_G.Ambiguate = function(n) return n end
_G.JumpOrAscendStart = function() end
_G.hooksecurefunc = function(a, b, c)
    local tbl, name, fn = _G, a, b
    if type(a) == "table" then tbl, name, fn = a, b, c end
    local orig = tbl[name]
    tbl[name] = function(...) orig(...); fn(...) end
end
_G.UIParent = {}
_G.UISpecialFrames = {}
_G.SlashCmdList = {}
_G.CombatLogGetCurrentEventInfo = function() return unpack(M.cleu) end
_G.C_Map = {
    GetMapInfo = function(id) return { name = "Mulgore", parentMapID = 1414, mapType = 3 } end,
    GetBestMapForUnit = function() return M.hidden and nil or M.map end,
    GetPlayerMapPosition = function() if M.hidden then return nil end return { x = M.mx, y = M.my } end,
    GetWorldPosFromMapPos = function(id, pos) return 1, { x = -1000 + pos.x * 2000, y = 500 + pos.y * 3000 } end,
}
_G.C_QuestLog = { GetQuestInfo = function(id) return "Quest " .. id end }
_G.C_Container = {
    UseContainerItem = function(bag, slot) end,
    GetContainerItemLink = function(bag, slot) return M.bags[bag] and M.bags[bag][slot] end,
}
_G.UseAction = function(slot) end
_G.GetActionInfo = function(slot) return "item", 159 end
_G.GetItemInfo = function(id) return "Refreshing Spring Water", "|cffffffff|Hitem:159::::::::1:::::|h[Refreshing Spring Water]|h|r" end
_G.UseItemByName = function(name) end
M.bags = { [0] = { [1] = "|cffffffff|Hitem:117::::::::1:::::|h[Tough Jerky]|h|r", [2] = "|cffffffff|Hitem:1372::::::::1:::::|h[Ragged Cloak]|h|r" } }
M.buffs = {}
_G.UnitAura = function(unit, i, filter) return M.buffs[i] end
_G.IsEquippableItem = function(link) return link and link:find("Cloak") ~= nil end
_G.RepairAllItems = function() end
_G.ChatFrameUtil = { DisplayTimePlayed = function() print("PLAYED LINE LEAKED") end }
_G.MerchantFrame = { shown = false, IsShown = function(self) return self.shown end }
_G.GetQuestLogTitle = function(i) return "Quest at index " .. i end

-- World state
M.level, M.xp, M.money, M.guild = 5, 400, 1234, nil
M.party = {}
M.units = {}
M.inInstance, M.instanceName = false, nil
M.zone, M.subzone = "Mulgore", "Bloodhoof Village"
M.wx, M.wy, M.inst = -1000, 500, 1
M.map, M.mx, M.my = 1412, 0.5, 0.5
M.speed, M.onTaxi, M.dead, M.ghost, M.mounted, M.form = 7, false, false, false, false, 0
M.gear = { [1] = "|cff1eff00|Hitem:1234::::::::5:::::|h[Green Hat]|h|r" }
M.hidden = false
M.cleu = {}
M.targetGUID, M.targetClass = nil, "normal"

-- Load the addon files in TOC order, passing (addonName, ns) like the client does
function M.LoadAddon(dir, files)
    local ns = {}
    for _, f in ipairs(files) do
        local chunk, err = loadfile(dir .. "/" .. f)
        assert(chunk, err)
        chunk("Hearthlog", ns)
    end
    return ns
end

return M
