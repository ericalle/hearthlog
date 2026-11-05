local ADDON_NAME, ns = ...

-- =========================================================
-- UTIL: small helpers shared by every file
-- =========================================================
-- Hearthlog runs on three clients (Classic Era, Forever, Retail) and was
-- written before Forever could be tested, so every game call that might
-- not exist, or might change shape, goes through Call() and comes back nil
-- instead of raising.
ns.VERSION = "0.3.6"
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
    local function keep(ok, ...)
        if ok then return ... end
        return nil
    end
    return keep(pcall(fn, ...))
end

-- CallIn(tbl, fn, ...): protected call of C_Something.Function
function ns.CallIn(tbl, name, ...)
    if type(tbl) ~= "table" or type(tbl[name]) ~= "function" then return nil end
    local function keep(ok, ...)
        if ok then return ... end
        return nil
    end
    return keep(pcall(tbl[name], ...))
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
        if name and name ~= UnitName("player") and name ~= "Unknown" and name ~= UNKNOWNOBJECT then
            local _, class = UnitClass(unit)
            tinsert(list, name .. ":" .. (class or "?"))
        end
    end
    table.sort(list)
    return list
end

-- ---------------------------------------------------------
-- Small helpers every file relies on (kept here, in the first file, so they always exist)
-- ---------------------------------------------------------
-- A number, or nil if the client made it secret (arithmetic on a secret throws)
function ns.Num(v)
    if v == nil then return nil end
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    if type(v) == "number" then return v end
    return tonumber(v)
end

-- A string, or nil if it is secret
function ns.Str(v)
    if v == nil then return nil end
    if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
    if type(v) == "string" then return v end
    return nil
end

-- Turn one of the game's format strings ("%s won: %s") into a Lua pattern with captures
function ns.Pat(fmt)
    local s = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    s = s:gsub("%%d", "(%%d+)"):gsub("%%s", "(.-)")
    return "^" .. s .. "$"
end

function ns.ShortName(name)
    return name and (name:match("^([^%-]+)") or name) or nil
end

-- ---------------------------------------------------------
-- Which client this is, and shims for APIs that moved
-- ---------------------------------------------------------
-- Forever (1.60, interface 16001) is the modern client running vanilla content, so it has
-- the modern API and the modern addon rules: no COMBAT_LOG_EVENT_UNFILTERED for addons at all,
-- "secret" values in restricted content, and several globals moved into C_ namespaces.
-- Classic Era (11509) keeps the old API. Modern.lua carries the no-combat-log fallbacks.
-- Read defensively: on Forever this line, written as tonumber(select(4, GetBuildInfo())), threw during
-- addon load and took the rest of the file with it.
local iv = 0
pcall(function()
    local _, _, _, interface = GetBuildInfo()
    iv = tonumber(interface) or 0
end)
ns.INTERFACE = iv
local noCleu = false
pcall(function()
    noCleu = (iv >= 120000) or (iv >= 16000 and iv < 20000) or (WOW_PROJECT_ID == 18) or (C_Secrets ~= nil)
        or type(issecretvalue) == "function"
end)
ns.NO_CLEU = noCleu

function ns.ItemInfo(item)
    if C_Item and C_Item.GetItemInfo then return ns.CallIn(C_Item, "GetItemInfo", item) end
    return ns.Call("GetItemInfo", item)
end

function ns.Equippable(item)
    if C_Item and C_Item.IsEquippableItem then return ns.CallIn(C_Item, "IsEquippableItem", item) end
    return ns.Call("IsEquippableItem", item)
end

-- Names of the player's helpful auras, on whichever aura API the client has
function ns.PlayerBuffNames()
    local names = {}
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 60 do
            local aura = ns.CallIn(C_UnitAuras, "GetAuraDataByIndex", "player", i, "HELPFUL")
            if not aura then break end
            local name = ns.Str(aura.name)
            if name then tinsert(names, name) end
        end
        return names
    end
    for i = 1, 60 do
        local name = ns.Call("UnitAura", "player", i, "HELPFUL")
        if not name then break end
        tinsert(names, name)
    end
    return names
end

function ns.CoinString(copper)
    copper = copper or 0
    if C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString then
        local s = ns.CallIn(C_CurrencyInfo, "GetCoinTextureString", copper)
        if s then return s end
    end
    if GetCoinTextureString then
        local s = ns.Call("GetCoinTextureString", copper)
        if s then return s end
    end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, c) end
    if s > 0 then return string.format("%ds %dc", s, c) end
    return string.format("%dc", c)
end

ns.LOADED = { Util = true }
