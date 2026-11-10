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

local function GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
end
local function Announce(message, groupOnly)
    if not groupOnly and IsInGuild() then Send(message, "GUILD") end
    local channel = GroupChannel()
    if channel then Send(message, channel) end
end

local ANSWERABLE = { GUILD = true, PARTY = true, RAID = true, INSTANCE_CHAT = true }
local function OnMessage(message, sender, channel)
    local name = ns.PlayerName(sender and (Ambiguate and Ambiguate(sender, "short") or sender))
    if not name or name == UnitName("player") then return end
    local kind, version = message:match("^(%a):?(.*)$")
    if kind == "Q" then
        -- Answer where the question was asked, not everywhere
        if ANSWERABLE[channel] then Send("A:" .. ns.VERSION, channel) else Announce("A:" .. ns.VERSION) end
        return
    end
    if (kind == "V" or kind == "A") and version ~= "" then
        peers[name] = version
        if Newer(version, ns.VERSION) and not nudged and ns.Setting("versionNotice") then
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
    ns.After(3, function()
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
    ns.After(10, function() Announce("V:" .. ns.VERSION) end)
end)

-- The roster event fires for every change in a group (joins, leaves, role and subgroup moves, people
-- going offline), which in a raid is constant. The version goes to the group only when the group has
-- grown, and then at most once every 30 seconds. The guild hears it once, at login.
local groupSize, lastGroupSend, sendDue = 0, 0, false
ns.On("GROUP_ROSTER_UPDATE", function()
    local size = IsInGroup() and (tonumber(GetNumGroupMembers()) or 0) or 0
    local grew = size > groupSize
    groupSize = size
    if not grew or sendDue then return end
    sendDue = true
    ns.After(math.max(2, 30 - (ns.Now() - lastGroupSend)), function()
        sendDue = false
        lastGroupSend = ns.Now()
        Announce("V:" .. ns.VERSION, true)
    end)
end)

ns.On("CHAT_MSG_ADDON", function(prefix, message, channel, sender)
    if prefix == PREFIX and type(message) == "string" then OnMessage(message, sender, channel) end
end)

ns.LOADED.Version = true
