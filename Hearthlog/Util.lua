local ADDON_NAME, ns = ...

-- =========================================================
-- UTIL: small helpers shared by every file
-- =========================================================
-- Hearthlog runs on three clients (Classic Era, Forever, Retail) and was
-- written before Forever could be tested, so every game call that might
-- not exist, or might change shape, goes through Call() and comes back nil
-- instead of raising.
ns.VERSION = "0.3.0"
ns.SCHEMA = 1
ns.URL = "https://github.com/ericalle/hearthlog/releases"

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffd8a84cHearthlog|r: " .. tostring(msg))
end
ns.Print = Print

-- Call(fn, ...): protected call of a global function by name
function ns.Call(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if ok then return a, b, c, d, e, f end
    return nil
end

-- CallIn(tbl, fn, ...): protected call of C_Something.Function
function ns.CallIn(tbl, name, ...)
    if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then return nil end
    local ok, a, b, c, d, e, f = pcall(tbl[name], ...)
    if ok then return a, b, c, d, e, f end
    return nil
end

-- Server time (epoch seconds), the one clock every record uses so that two
-- players' files line up. Falls back to the local clock.
function ns.Now()
    local t = ns.Call("GetServerTime")
    if type(t) == "number" and t > 0 then return t end
    return time()
end

function ns.Round(n, places)
    local m = 10 ^ (places or 0)
    return math.floor(n * m + 0.5) / m
end

-- "Name-Realm" for the player
function ns.CharKey()
    local name = UnitName("player") or "Unknown"
    local realm = (ns.Call("GetNormalizedRealmName")) or (GetRealmName() or ""):gsub("[%s%-]", "")
    return name .. "-" .. realm
end

-- Creature id out of a GUID ("Creature-0-1234-0-5-299-000F1A2B" -> 299)
function ns.NpcId(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" or kind == "Pet" then return tonumber(id), kind end
    return nil, kind
end

-- Item quality from a link's color code (works without GetItemInfo cache)
local QUALITY_BY_COLOR = {
    ["9d9d9d"] = 0, ["ffffff"] = 1, ["1eff00"] = 2, ["0070dd"] = 3,
    ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6,
}
function ns.LinkQuality(link)
    if type(link) ~= "string" then return nil end
    local color = link:match("|cff(%x%x%x%x%x%x)")
    return color and QUALITY_BY_COLOR[color:lower()] or nil
end

function ns.LinkName(link)
    return type(link) == "string" and link:match("%[(.-)%]") or nil
end

function ns.ItemId(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Shallow copy of an array of strings/numbers
function ns.CopyArray(src)
    local out = {}
    for i, v in ipairs(src) do out[i] = v end
    return out
end

-- Seconds as "1d 2h 3m"
function ns.Duration(s)
    s = math.floor(s or 0)
    local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
    if d > 0 then return string.format("%dd %dh %dm", d, h, m) end
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm %ds", m, s % 60)
end

-- Current party or raid as a sorted list of "Name:CLASS"
function ns.PartyList()
    local list = {}
    local prefix, count = "party", GetNumSubgroupMembers()
    if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end
    for i = 1, count do
        local unit = prefix .. i
        local name = UnitName(unit)
        if name and name ~= UnitName("player") then
            local _, class = UnitClass(unit)
            tinsert(list, name .. ":" .. (class or "?"))
        end
    end
    table.sort(list)
    return list
end
