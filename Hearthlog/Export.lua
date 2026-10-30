local ADDON_NAME, ns = ...
local Print = ns.Print

-- =========================================================
-- EXPORT: the character's data as a paste-able string
-- =========================================================
-- A plain serialization of char (same content as the SavedVariables file),
-- shown in a window with the text selected. Big journeys are better sent as
-- the file itself: WTF/Account/<ACCOUNT>/SavedVariables/Hearthlog.lua
-- Format: HL1 header, then the Lua table literal.

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

function ns.ExportString()
    local out = { "HL1:" }
    Serialize({ key = ns.key, maps = ns.db.maps, char = ns.char }, out, 0)
    return table.concat(out)
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
    title:SetText("Hearthlog export: Ctrl+C to copy, then paste to Eric")

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
    Print(string.format("export is %d KB. Over a few hundred KB, send the SavedVariables file instead.", math.floor(#text / 1024)))
end
