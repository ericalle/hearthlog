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
-- Any method not listed is a no-op; getters return something sensible
local function Widget(kind)
    local w = { kind = kind, scripts = {}, events = {}, all = false, shown = true, checked = false, text = "" }
    function w:RegisterEvent(e)
        if M.forever and (e == "COMBAT_LOG_EVENT_UNFILTERED" or e == "COMBAT_LOG_EVENT") then
            error("Hearthlog has been blocked from an action only available to the Blizzard UI")
        end
        self.events[e] = true
    end
    function w:UnregisterEvent(e) self.events[e] = nil end
    function w:RegisterAllEvents() self.all = true end
    function w:UnregisterAllEvents() self.all = false; self.events = {} end
    function w:SetScript(k, fn) self.scripts[k] = fn end
    function w:GetScript(k) return self.scripts[k] end
    function w:HookScript(k, fn) self.scripts[k] = fn end
    function w:Show() self.shown = true end
    function w:Hide() self.shown = false end
    function w:SetShown(v) self.shown = v and true or false end
    function w:IsShown() return self.shown end
    function w:SetText(t) self.text = t end
    function w:GetText() return self.text end
    function w:SetChecked(v) self.checked = v and true or false end
    function w:GetChecked() return self.checked end
    function w:GetWidth() return 300 end
    function w:GetHeight() return 200 end
    function w:GetStringHeight() return 120 end
    function w:GetFontString() return Widget("FontString") end
    function w:CreateFontString() return Widget("FontString") end
    function w:CreateTexture() return Widget("Texture") end
    function w:IsEnabled() return true end
    function w:HasFocus() return false end
    setmetatable(w, { __index = function(_, k) return function() end end })
    return w
end
function _G.CreateFrame(kind, name, parent, template)
    local f = Widget(kind)
    f.name = name
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
_G.UnitLevel = function(u) local unit = u and M.units[u]; return unit and unit.level or M.level end
_G.UnitIsTrivial = function(u) local unit = u and M.units[u]; return unit and unit.trivial or false end
_G.UnitXP = function() return M.xp end
_G.UnitGUID = function(u)
    if u == "player" then return "Player-1-000001" end
    if u == "target" then return M.targetGUID end
    return M.units[u] and M.units[u].guid
end
_G.GetBuildInfo = function() return "1.15.9", "60000", "2026-10-01", 11509 end
M.forever = false -- set by M.ForeverMode() before the addon loads
function M.ForeverMode()
    -- The Forever client: interface 16001, the modern API, no combat log for addons
    M.forever = true
    _G.GetBuildInfo = function() return "1.60.1", "70205", "2026-11-04", 16001 end
    _G.WOW_PROJECT_ID = 18
    -- A secret value: anything done to it other than passing it along or asking issecretvalue raises
    local function forbidden() error("attempt to use a secret value (execution tainted by 'Hearthlog')") end
    M.SECRET = setmetatable({}, { __tostring = forbidden, __concat = forbidden, __lt = forbidden, __le = forbidden,
        __index = forbidden, __add = forbidden, __sub = forbidden, __len = forbidden, __call = forbidden })
    _G.issecretvalue = function(v) return rawequal(v, M.SECRET) end
    _G.C_Secrets = {}
    _G.UnitAura, _G.GetItemInfo, _G.IsEquippableItem, _G.GetTalentTabTnfo, _G.GetCoinTextureString = nil, nil, nil, nil, nil
    _G.GetSpellInfo = nil
    _G.C_Item = { GetItemInfo = function(id) return "Refreshing Spring Water", "|cffffffff|Hitem:159::::::::1:::::|h[Refreshing Spring Water]|h|r" end,
                  IsEquippableItem = function(link) return link and link:find("Cloak") ~= nil end }
    _G.C_UnitAuras = { GetAuraDataByIndex = function(unit, i, filter) local n = M.buffs[i]; if n then return { name = n, isHelpful = true } end end }
    _G.C_CurrencyInfo = { GetCoinTextureString = function(c) return tostring(c) .. "c" end }
    _G.UnitExists = function(u) return M.units[u] ~= nil end
    _G.UnitCanAttack = function(a, b) return M.units[b] and M.units[b].hostile or false end
    _G.UnitIsPlayer = function(u) return M.units[u] and M.units[u].guid and M.units[u].guid:sub(1, 6) == "Player" or false end
    _G.UnitThreatSituation = function(a, b) return M.units[b] and M.units[b].threat end
    _G.GetNumFactions, _G.GetFactionInfo = nil, nil
    _G.C_Reputation = {
        GetNumFactions = function() return #M.factions end,
        GetFactionDataByIndex = function(i) local f = M.factions[i]
            if f then return { name = f.name, currentStanding = f.v, reaction = f.s, isHeader = false } end end,
    }
    _G.C_MountJournal = { GetMountInfoByID = function(id) return "Brown Kodo" end }
    _G.C_TransmogCollection = { GetSourceInfo = function(id) return { name = "Frayed Robe", itemID = 2491 } end }
    _G.C_DeathRecap = { GetRecapEvents = function(id) return M.recaps[id] end }
    C_Item.GetItemLink = function(loc) return M.bags[loc.bag] and M.bags[loc.bag][loc.slot] end
    _G.C_AuctionHouse = {
        PostItem = function() end, PostCommodity = function() end,
        StartCommoditiesPurchase = function() end, ConfirmCommoditiesPurchase = function() end, PlaceBid = function() end,
    }
    -- The emote call moved; the old global still exists and passes the call along
    C_ChatInfo.PerformEmote = function(token) end
    _G.DoEmote = function(token) C_ChatInfo.PerformEmote(token) end
    -- The built-in damage meter. M.meter[kind] = { { guid, creatureID, name, total, me,
    --     spells = { { id, total, creature, overkill, unit, amount } } } }
    -- Fields the meter leaves out arrive as "" and 0, as on the real client.
    _G.Enum = _G.Enum or {}
    Enum.DamageMeterSessionType = { Overall = 0, Current = 1, Expired = 2 }
    Enum.DamageMeterType = { DamageDone = 0, Dps = 1, HealingDone = 2, Hps = 3, Absorbs = 4, Interrupts = 5, Dispels = 6,
        DamageTaken = 7, AvoidableDamageTaken = 8, Deaths = 9, EnemyDamageTaken = 10 }
    M.meter = nil
    _G.C_DamageMeter = {
        IsDamageMeterAvailable = function() return true end,
        GetCombatSessionFromType = function(st, kind)
            local m = M.meter
            if not m then return { combatSources = {}, durationSeconds = 0, totalAmount = 0 } end
            local srcs = {}
            for _, s in ipairs(m[kind] or {}) do
                local src = { sourceGUID = s.guid, sourceCreatureID = s.creatureID, name = s.name, totalAmount = s.total,
                    isLocalPlayer = s.me or false, deathRecapID = s.recap, deathTimeSeconds = s.recap and 10 or nil }
                for k, v in pairs(s.extra or {}) do src[k] = v end -- extra or overriding fields, M.SECRET among them
                tinsert(srcs, src)
            end
            return { combatSources = srcs, durationSeconds = m.dur, totalAmount = 0 }
        end,
        GetCombatSessionSourceFromType = function(st, kind, guid, creatureID)
            local m = M.meter
            if not m then return nil end
            for _, s in ipairs(m[kind] or {}) do
                if (guid ~= nil and s.guid == guid) or (creatureID ~= nil and s.creatureID == creatureID) then
                    local spells = {}
                    for _, sp in ipairs(s.spells or {}) do
                        tinsert(spells, { spellID = sp.id, totalAmount = sp.total, creatureName = sp.creature or "", overkillAmount = sp.overkill or 0,
                            combatSpellDetails = { unitName = sp.unit or "", amount = sp.amount or 0, classification = "",
                                unitClassFilename = "", isMob = false, isPet = false } })
                    end
                    return { combatSpells = spells, totalAmount = s.total }
                end
            end
        end,
    }
end
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
_G.DoEmote = function(token) end
_G.hooksecurefunc = function(a, b, c)
    local tbl, name, fn = _G, a, b
    if type(a) == "table" then tbl, name, fn = a, b, c end
    local orig = tbl[name]
    tbl[name] = function(...) orig(...); fn(...) end
end
_G.UIParent = {}
_G.UNKNOWNOBJECT = "Unknown"
_G.SetPortraitTexture = function() end
_G.BreakUpLargeNumbers = function(n) return tostring(n) end
_G.UISpecialFrames = {}
_G.SlashCmdList = {}
_G.CombatLogGetCurrentEventInfo = function() return unpack(M.cleu) end
_G.bit = _G.bit or { band = function(a, b)
    local r, p = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end }
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
M.merchant = {}
-- Trade, mail and auction house stubs (hooked by Events.lua at load)
M.trade = { gave = {}, got = {}, goldOut = 0, goldIn = 0 }
_G.GetTradePlayerItemLink = function(i) return M.trade.gave[i] end
_G.GetTradeTargetItemLink = function(i) return M.trade.got[i] end
_G.GetPlayerTradeMoney = function() return M.trade.goldOut end
_G.GetTargetTradeMoney = function() return M.trade.goldIn end
M.inbox = {}
_G.GetInboxHeaderInfo = function(i) local m = M.inbox[i]; if m then return nil, nil, m.sender, m.subject, m.money end end
_G.GetInboxItemLink = function(i, j) return M.inbox[i] and M.inbox[i].items[j] end
_G.TakeInboxItem = function(i, j) end
_G.TakeInboxMoney = function(i) end
_G.AutoLootMailItem = function(i) end
M.sendMail = { items = {}, money = 0 }
_G.GetSendMailItemLink = function(i) return M.sendMail.items[i] end
_G.GetSendMailMoney = function() return M.sendMail.money end
_G.SendMail = function(to, subject, body) end
M.auctions = {}
_G.GetAuctionItemInfo = function(kind, i) local a = M.auctions[i]
    if a then return a.name, nil, a.count, a.quality, true, 0, nil, a.minBid, 0, a.buyout, 0, false, nil, nil, nil, nil, a.itemId, true end end
_G.PlaceAuctionBid = function(kind, i, bid) end
M.sellItem = nil
_G.GetAuctionSellItemInfo = function() local s = M.sellItem; if s then return s.name, nil, s.count, s.quality, true, 0 end end
_G.PostAuction = function(minBid, buyout, runTime, stackSize, numStacks) end
_G.GetMerchantItemLink = function(i) return M.merchant[i] end
_G.BuyMerchantItem = function(i, qty) end
_G.GetQuestLogTitle = function(i) return "Quest at index " .. i end

-- World state
M.level, M.xp, M.money, M.guild = 5, 400, 1234, nil
M.party = {}
M.units = {}
M.recaps = {}
M.factions = { { name = "Undercity", v = 100, s = 4 } }
_G.GetNumFactions = function() return #M.factions end
_G.GetFactionInfo = function(i) local f = M.factions[i]
    if f then return f.name, "", f.s, 0, 3000, f.v, false, true, false, false, false end end
_G.GetAchievementInfo = function(id) return id, "Level 10" end
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
