local ADDON_NAME, ns = ...
local Print = ns.Print

-- =========================================================
-- VERSION: tell friends when a newer Hearthlog is out
-- =========================================================
-- An addon cannot look a version up anywhere, so players' copies tell each other. On login
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

-- =========================================================
-- LINK TEST: how fast can two copies of the addon talk to each other?
-- =========================================================
-- /hl linktest <name> [count] [seconds between] sends a batch of hidden addon messages to one player by
-- whisper and asks their copy how many arrived and over how long. It is a measurement and nothing else:
-- the messages are filler. Both players need this version.
-- The result is printed and kept in the saved file (linkTests, the last 20), on both sides.
-- Messages (prefix HLNK1): "H:<id>" hello, "A:<id>:<version>" answer, "T:<id>:<n>:<of>:<filler>" one of
-- the batch, "R:<id>:<count>:<bytes>:<milliseconds>" what the receiver counted.
local LINK = "HLNK1"
local SIZE = 200        -- bytes per message (the game's limit is 255)
local out = nil         -- the test we are sending: { id, to, total, gap, n, tries, results, t0, sendSecs, done }
local incoming = {}     -- tests others are sending us: [sender .. id] = { n, bytes, first, last, total, reported }

local function Clock() return (GetTime and GetTime()) or ns.Now() end
local function Whisper(message, target)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false, "no such function" end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, LINK, message, "WHISPER", target)
    if not ok then return false, "error" end
    -- Newer clients answer with a result code (0 is sent), older ones with true or nothing
    return res == nil or res == true or res == 0, tostring(res)
end
local function Keep(rec)
    if not ns.db then return end
    ns.db.linkTests = ns.db.linkTests or {}
    local list = ns.db.linkTests
    rec.t, rec.v = ns.Now(), ns.VERSION
    tinsert(list, rec)
    while #list > 20 do table.remove(list, 1) end
end

local function Finish(reason)
    local o = out
    if not o or o.done then return end
    o.done = true
    local parts = {}
    for k, n in pairs(o.results) do parts[#parts + 1] = k .. " x" .. n end
    table.sort(parts)
    Keep({ role = "send", to = o.to, total = o.total, size = SIZE, gap = o.gap, sent = o.n, sendSecs = o.sendSecs,
        got = o.got, gotBytes = o.gotBytes, recvSecs = o.recvSecs, results = table.concat(parts, ", "), note = reason })
    if not o.got then
        Print(string.format("link test with %s: %s (%d of %d sent)", o.to, reason or "no report came back", o.n, o.total))
        return
    end
    local secs = math.max(o.recvSecs or 0, 0.001)
    Print(string.format("link test with %s: %d of %d arrived (%d bytes) over %.1fs, about %d bytes a second. Sending took %.1fs.",
        o.to, o.got, o.total, o.gotBytes or 0, o.recvSecs or 0, (o.gotBytes or 0) / secs, o.sendSecs or 0))
    Print("  the game answered each send with: " .. table.concat(parts, ", "))
end

local function SendNext()
    local o = out
    if not o or o.done then return end
    if o.n >= o.total then
        o.sendSecs = Clock() - o.t0
        ns.After(15, function() if out == o then Finish("everything was sent but no report came back") end end)
        return
    end
    local head = string.format("T:%d:%d:%d:", o.id, o.n + 1, o.total)
    local ok, res = Whisper(head .. string.rep("x", SIZE - #head), o.to)
    o.results[res] = (o.results[res] or 0) + 1
    if ok then
        o.n, o.tries = o.n + 1, 0
    else
        o.tries = o.tries + 1 -- refused (throttled): the same one again on the next turn
        if o.tries > 200 then Finish("the game kept refusing to send") return end
    end
    ns.After(o.gap, SendNext)
end

function ns.LinkTest(arg)
    local name, count, gap = strsplit(" ", strtrim(arg or ""))
    if not name or name == "" then
        Print("/hl linktest <name> [count] [seconds between]: measures how fast this addon can talk to another player's copy. Both need this version.")
        return
    end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then Print("this client cannot send addon messages") return end
    if out and not out.done then Print("a link test is already running") return end
    if name:byte(1) and name:byte(1) >= 97 and name:byte(1) <= 122 then name = name:sub(1, 1):upper() .. name:sub(2) end
    count = math.max(1, math.min(tonumber(count) or 40, 300))
    gap = math.max(0.05, math.min(tonumber(gap) or 0.25, 5))
    out = { id = math.random(1000, 9999), to = name, total = count, gap = gap, n = 0, tries = 0, results = {} }
    local o = out
    Print(string.format("link test: asking %s's copy (%d messages of %d bytes, one every %.2fs)...", name, count, SIZE, gap))
    Whisper("H:" .. o.id, name)
    ns.After(6, function()
        if out == o and not o.t0 then Finish("no answer (is that player online, on this realm, with this version?)") end
    end)
end

local function OnLink(message, sender)
    local kind, rest = message:match("^(%a):(.*)$")
    if not kind then return end
    local who = (Ambiguate and Ambiguate(sender, "none")) or sender
    if kind == "H" then
        local id = rest:match("^(%d+)$")
        if id then Whisper("A:" .. id .. ":" .. ns.VERSION, who) end
    elseif kind == "A" then
        local o = out
        local id = tonumber(rest:match("^(%d+)"))
        if o and not o.done and not o.t0 and id == o.id then
            o.t0 = Clock()
            SendNext()
        end
    elseif kind == "T" then
        local id, n, total = rest:match("^(%d+):(%d+):(%d+):")
        if not id then return end
        total = math.min(tonumber(total) or 0, 300)
        local key = sender .. ":" .. id
        local rec = incoming[key]
        if not rec then
            rec = { n = 0, bytes = 0, first = Clock(), total = total }
            incoming[key] = rec
        end
        if rec.reported then return end
        rec.n, rec.bytes, rec.last = rec.n + 1, rec.bytes + #message, Clock()
        local seen = rec.n
        local function Report()
            if rec.reported then return end
            rec.reported = true
            local ms = math.floor((rec.last - rec.first) * 1000 + 0.5)
            Whisper(string.format("R:%s:%d:%d:%d", id, rec.n, rec.bytes, ms), who)
            Keep({ role = "recv", from = ns.PlayerName(who) or who, total = rec.total, got = rec.n, gotBytes = rec.bytes, recvSecs = ms / 1000 })
        end
        if tonumber(n) == total then
            ns.After(1.5, Report) -- the last one: a moment for any that are still on their way
        else
            ns.After(8, function() if rec.n == seen then Report() end end) -- or the batch has stopped coming
        end
    elseif kind == "R" then
        local o = out
        local id, got, bytes, ms = rest:match("^(%d+):(%d+):(%d+):(%d+)$")
        if o and not o.done and tonumber(id) == o.id then
            o.got, o.gotBytes, o.recvSecs = tonumber(got), tonumber(bytes), (tonumber(ms) or 0) / 1000
            o.sendSecs = o.sendSecs or (Clock() - (o.t0 or Clock()))
            Finish()
        end
    end
end

ns.On("PLAYER_LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, LINK)
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
    if prefix == LINK and type(message) == "string" and type(sender) == "string" then OnLink(message, sender) end
end)

ns.LOADED.Version = true
