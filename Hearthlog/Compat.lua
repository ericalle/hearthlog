local ADDON_NAME, ns = ...

-- =========================================================
-- COMPAT: which client this is, and shims for APIs that moved
-- =========================================================
-- Forever (1.60, interface 16001) is the modern client running vanilla content, so it has
-- the modern API and the modern addon rules: no COMBAT_LOG_EVENT_UNFILTERED for addons at all,
-- "secret" values in restricted content, and several globals moved into C_ namespaces.
-- Classic Era (11509) keeps the old API. Modern.lua carries the no-combat-log fallbacks.

local iv = tonumber(select(4, GetBuildInfo())) or 0
ns.INTERFACE = iv
ns.NO_CLEU = (iv >= 120000) or (iv >= 16000 and iv < 20000) or (WOW_PROJECT_ID == 18) or (C_Secrets ~= nil)
    or type(issecretvalue) == "function"

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

-- Turn one of the game's format strings ("%s won: %s") into a Lua pattern with captures
function ns.Pat(fmt)
    local s = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    s = s:gsub("%%d", "(%%d+)"):gsub("%%s", "(.-)")
    return "^" .. s .. "$"
end

function ns.ShortName(name)
    return name and (name:match("^([^%-]+)") or name) or nil
end
