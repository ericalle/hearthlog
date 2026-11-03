local ADDON_NAME, ns = ...
local Print = ns.Print

-- =========================================================
-- EXPORT: the character's data as a paste-able string
-- =========================================================
-- The character's data serialized, compressed and base64-encoded into one
-- string, shown in a window with the text selected. The SavedVariables file
-- (WTF/Account/<ACCOUNT>/SavedVariables/Hearthlog.lua) holds the same data.

local function Serialize(v, out, depth)
    local t = type(v)
    if t == "number" then
        tinsert(out, (math.floor(v) == v) and tostring(v) or string.format("%.4f", v))
    elseif t == "boolean" then
        tinsert(out, v and "true" or "false")
    elseif t == "string" then
        tinsert(out, string.format("%q", v))
    elseif t == "table" then
        if depth > 12 then tinsert(out, "nil") return end
        tinsert(out, "{")
        local n = #v
        for i = 1, n do
            Serialize(v[i], out, depth + 1)
            tinsert(out, ",")
        end
        for k, val in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= n and math.floor(k) == k) then
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    tinsert(out, k .. "=")
                else
                    tinsert(out, "[")
                    Serialize(k, out, depth + 1)
                    tinsert(out, "]=")
                end
                Serialize(val, out, depth + 1)
                tinsert(out, ",")
            end
        end
        tinsert(out, "}")
    else
        tinsert(out, "nil")
    end
end

-- ---------------------------------------------------------
-- LZW + base64: one dense string, like other addons' export strings.
-- Header "HL2:". tools/load.py decodes it. (HL1: was the raw table literal.)
-- ---------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function Base64(bytes)
    local out = {}
    for i = 1, #bytes, 3 do
        local a, b, c = bytes:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        tinsert(out, B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "="))
    end
    return table.concat(out)
end

-- LZW with 16-bit codes, written as two bytes each. The dictionary resets at 65535 entries.
local function LZW(input)
    local dict, size = {}, 256
    for i = 0, 255 do dict[string.char(i)] = i end
    local out, w = {}, ""
    local function emit(code) tinsert(out, string.char(math.floor(code / 256), code % 256)) end
    for i = 1, #input do
        local c = input:sub(i, i)
        local wc = w .. c
        if dict[wc] then
            w = wc
        else
            emit(dict[w])
            if size < 65535 then
                dict[wc] = size
                size = size + 1
            else
                dict, size = {}, 256
                for j = 0, 255 do dict[string.char(j)] = j end
            end
            w = c
        end
    end
    if w ~= "" then emit(dict[w]) end
    return table.concat(out)
end

function ns.ExportString()
    local out = {}
    Serialize({ key = ns.key, maps = ns.db.maps, char = ns.char }, out, 0)
    local raw = table.concat(out)
    return "HL2:" .. Base64(LZW(raw))
end

local frame
local function Window()
    if frame then return frame end
    frame = CreateFrame("Frame", "HearthlogExportFrame", UIParent, "BackdropTemplate")
    frame:SetSize(520, 360)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    tinsert(UISpecialFrames, "HearthlogExportFrame")

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Hearthlog export (Ctrl+C to copy)")

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 20, -40)
    scroll:SetPoint("BOTTOMRIGHT", -40, 44)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetFontObject("ChatFontSmall")
    box:SetWidth(440)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function() frame:Hide() end)
    scroll:SetScrollChild(box)
    frame.box = box

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(90, 22)
    close:SetPoint("BOTTOM", 0, 16)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)
    return frame
end

function ns.ShowExport()
    if ns.Track then ns.Track.Flush() end
    local text = ns.ExportString()
    local f = Window()
    f.box:SetText(text)
    f:Show()
    f.box:SetFocus()
    f.box:HighlightText()
    Print(string.format("export string: %d KB", math.floor(#text / 1024)))
end
