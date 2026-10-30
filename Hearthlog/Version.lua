local ADDON_NAME, ns = ...
local Print = ns.Print

-- =========================================================
-- VERSION: tell friends when a newer Hearthlog is out
-- =========================================================
-- The addon has no network access, so players tell each other. On login
-- the version goes to the guild; when a group forms, to the party. Anyone
-- who hears a newer version than their own gets one chat line per session
-- pointing at the releases page. /hl who lists who answered.
-- Message format: "V:<version>" (announce), "Q" (please answer), "A:<version>" (answer)

local PREFIX = "HLOG1"
local peers = {}        -- [name] = version
local nudged = false
ns.peers = peers

local function Parse(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)")
    return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

-- true when a is newer than b
local function Newer(a, b)
    local a1, a2, a3 = Parse(a)
    local b1, b2, b3 = Parse(b)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end
ns.VersionNewer = Newer

local function Send(message, channel)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, channel)
end

local function Announce(message)
    if IsInGuild() then Send(message, "GUILD") end
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then Send(message, "INSTANCE_CHAT")
    elseif IsInRaid() then Send(message, "RAID")
    elseif IsInGroup() then Send(message, "PARTY") end
end

local function OnMessage(message, sender)
    local name = sender and (Ambiguate and Ambiguate(sender, "short") or sender)
    if not name or name == UnitName("player") then return end
    local kind, version = message:match("^(%a):?(.*)$")
    if kind == "Q" then
        Announce("A:" .. ns.VERSION)
        return
    end
    if (kind == "V" or kind == "A") and version ~= "" then
        peers[name] = version
        if Newer(version, ns.VERSION) and not nudged then
            nudged = true
            Print(string.format("|cff33ff66Hearthlog %s is out|r (you have %s): %s", version, ns.VERSION, ns.URL))
        end
    end
end

function ns.WhoHasAddon()
    peers = {}
    ns.peers = peers
    Announce("Q")
    Print("asking guild and group who has Hearthlog...")
    C_Timer.After(3, function()
        local names = {}
        for n in pairs(peers) do tinsert(names, n) end
        table.sort(names)
        if #names == 0 then
            Print("nobody answered (or nobody else is online with it)")
            return
        end
        Print(string.format("%d with Hearthlog:", #names))
        for _, n in ipairs(names) do
            local v = peers[n]
            local tag = Newer(v, ns.VERSION) and "  |cff33ff66newer|r" or Newer(ns.VERSION, v) and "  |cffff8800old|r" or ""
            Print(string.format("  %s  v%s%s", n, v, tag))
        end
    end)
end

ns.On("PLAYER_LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    end
    C_Timer.After(10, function() Announce("V:" .. ns.VERSION) end)
end)

ns.On("GROUP_ROSTER_UPDATE", function()
    if IsInGroup() then C_Timer.After(2, function() Announce("V:" .. ns.VERSION) end) end
end)

ns.On("CHAT_MSG_ADDON", function(prefix, message, _, sender)
    if prefix == PREFIX and type(message) == "string" then OnMessage(message, sender) end
end)
