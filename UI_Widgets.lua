-- ============================================================================
-- UI_Widgets.lua  v5.0
-- Shared widget factory functions used by UI_Config.lua and UI_Member.lua.
-- Also owns the shared edit popup and the LockDisplay helper.
--
-- IMPORTANT FIX: LockDisplay no longer calls fs:SetMaxLines(1) because that
-- method does not exist on FontStrings in WoW client 3.3.5a. Clipping is
-- handled by SetWidth + SetWordWrap(false) which work on all 3.3.5a clients.
-- ============================================================================
local MTR = MekTownRecruit

-- ============================================================================
-- LOCK DISPLAY  (safe for 3.3.5a – no SetMaxLines call)
-- ============================================================================
function MTR.LockDisplay(fs, pixelWidth)
    fs:SetWidth(pixelWidth)
    fs:SetWordWrap(false)
    -- SetNonSpaceWrap added in later patches; guard it
    if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(false) end
    -- NOTE: SetMaxLines does NOT exist on 3.3.5a FontString objects.
    -- Do NOT call fs:SetMaxLines(1) here – it crashes the client.
end

-- ============================================================================
-- SHARED EDIT POPUP
-- A single reusable multi-line editor opened by every "Edit" button.
-- ============================================================================
local editPopup = nil

function MTR.OpenEditPopup(title, currentText, onSave)
    if not editPopup then
        editPopup = CreateFrame("Frame", "MekTownEditPopup", UIParent)
        editPopup:SetSize(620, 520)
        editPopup:SetPoint("CENTER")
        editPopup:SetBackdrop({
            bgFile   = "",
            edgeFile = "Interface\\\\DialogFrame\\\\UI-DialogBox-Border",
            tile=false, tileSize=0, edgeSize=32,
            insets={left=8,right=8,top=8,bottom=8},
        })
        editPopup:SetBackdropColor(0,0,0,0)
        do local _bt=editPopup:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(editPopup) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
        editPopup:SetFrameStrata("TOOLTIP")
        editPopup:EnableMouse(true)
        editPopup:SetMovable(true)
        editPopup:RegisterForDrag("LeftButton")
        editPopup:SetScript("OnDragStart", editPopup.StartMoving)
        editPopup:SetScript("OnDragStop",  editPopup.StopMovingOrSizing)

        editPopup._titleFS = editPopup:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        editPopup._titleFS:SetPoint("TOP", editPopup, "TOP", 0, -16)

        local sf = CreateFrame("ScrollFrame", nil, editPopup, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     editPopup, "TOPLEFT",    12, -44)
        sf:SetPoint("BOTTOMRIGHT", editPopup, "BOTTOMRIGHT", -28, 44)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetSize(570, 420)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(true)
        eb:SetFontObject(GameFontHighlightSmall)
        eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        sf:SetScrollChild(eb)
        editPopup._eb = eb

        local saveBtn = CreateFrame("Button", nil, editPopup, "UIPanelButtonTemplate")
        saveBtn:SetSize(100, 26)
        saveBtn:SetPoint("BOTTOMLEFT", editPopup, "BOTTOMLEFT", 12, 10)
        saveBtn:SetText("Save")
        saveBtn:SetScript("OnClick", function()
            if editPopup._onSave then editPopup._onSave(editPopup._eb:GetText()) end
            editPopup:Hide()
        end)

        local cancelBtn = CreateFrame("Button", nil, editPopup, "UIPanelButtonTemplate")
        cancelBtn:SetSize(100, 26)
        cancelBtn:SetPoint("LEFT", saveBtn, "RIGHT", 8, 0)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function() editPopup:Hide() end)

        local xBtn = CreateFrame("Button", nil, editPopup, "UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT", editPopup, "TOPRIGHT", -2, -2)
        xBtn:SetScript("OnClick", function() editPopup:Hide() end)
    end

    editPopup._titleFS:SetText("|cffd4af37" .. title .. "|r")
    editPopup._eb:SetText(currentText or "")
    editPopup._onSave = onSave
    editPopup:Show()
    editPopup._eb:SetFocus()
end

-- ============================================================================
-- WIDGET FACTORIES
-- All functions return the created widget(s).
-- 'parent' is always a Frame.  ax/ay are TOPLEFT offsets from the parent.
-- ============================================================================

-- Scrollable read-only text box
function MTR.MakeRO(parent, w, h, ax, ay)
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    sf:SetSize(w, h)
    if ax then sf:SetPoint("TOPLEFT", parent, "TOPLEFT", ax, ay) end
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetSize(w - 22, h)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetScript("OnTextChanged", function() end)
    sf:SetScrollChild(eb)
    return sf, eb
end

-- Single-line input box
function MTR.MakeIn(gname, parent, w, ax, ay)
    local eb = CreateFrame("EditBox", "MekIn_"..gname, parent, "InputBoxTemplate")
    eb:SetSize(w, 20)
    eb:SetPoint("TOPLEFT", parent, "TOPLEFT", ax or 0, ay or 0)
    eb:SetAutoFocus(false)
    return eb
end

-- Checkbox
function MTR.MakeCK(gname, parent, label, ax, ay)
    local cb = CreateFrame("CheckButton", "MekCK_"..gname, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", ax or 0, ay or 0)
    _G["MekCK_"..gname.."Text"]:SetText(label)
    return cb
end

-- Slider with optional value display text element
function MTR.MakeSL(gname, parent, w, ax, ay, mn, mx, step)
    local sl = CreateFrame("Slider", "MekSLv_"..gname, parent, "OptionsSliderTemplate")
    sl:SetSize(w, 16)
    sl:SetPoint("TOPLEFT", parent, "TOPLEFT", ax or 0, ay or 0)
    sl:SetMinMaxValues(mn, mx)
    sl:SetValueStep(step)
    _G["MekSLv_"..gname.."Low"]:SetText(tostring(mn))
    _G["MekSLv_"..gname.."High"]:SetText(tostring(mx))
    return sl
end

-- Section divider with optional label
function MTR.MakeSep(parent, label, ay)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(0.2, 0.2, 0.35, 0.6)
    t:SetHeight(1)
    t:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, ay)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, ay)
    if label then
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        -- For sections deep enough, put label ABOVE the line (classic style: ay+10).
        -- For sections near the top of the frame (ay > -12), ay+10 would be positive
        -- (above the frame) and bleed into the header/tab-button area.
        -- In that case render the label BELOW the line (ay-2) instead.
        local labelY = (ay + 10 > -2) and (ay - 2) or (ay + 10)
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, labelY)
        fs:SetText("|cffaaaaaa" .. label .. "|r")
    end
end

-- Plain button
function MTR.MakeBT(parent, label, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 100, h or 24)
    b:SetText(label)
    return b
end

-- ============================================================================
-- EXPORT HELPERS  (used by multiple tabs)
-- ============================================================================
function MTR.ExportHistory(lines, channel)
    if not lines or #lines == 0 then MTR.MP("Nothing to export.") return end
    if channel == "PRINT" then
        for _, l in ipairs(lines) do print(l) end
    else
        for _, l in ipairs(lines) do
            MTR.SendChatSafe(l, channel)
        end
    end
end

function MTR.FormatRecruitHistory(hist)
    local out = {}
    for i = #(hist or {}), 1, -1 do   -- newest first for exports
        local e = hist[i]
        local recruit = e.recruit or e.player or "?"
        local sentBy  = e.sentBy  or "?"
        out[#out+1] = string.format("[%s]  %-20s  %s", e.time or "?", recruit, sentBy)
    end
    return out
end

function MTR.FormatBidHistory(log)
    local out = {}
    for i = #(log or {}), math.max(1, #(log or {}) - 99), -1 do
        local e = log[i]
        if e.type == "auction" or not e.type then
            out[#out+1] = string.format("[%s] [%s]  Winner: %s  %d pts", e.date or "?", e.item or "?", e.winner or "?", e.amount or 0)
        elseif e.type == "roll" then
            out[#out+1] = string.format("[%s] [%s] (%s)  Winner: %s", e.date or "?", e.item or "?", e.rollType or "?", e.winner or "?")
        end
    end
    return out
end

function MTR.FormatKickHistory(log)
    local out = {}
    for _, e in ipairs(log or {}) do
        out[#out+1] = string.format("[%s] %s [%s] %s by %s",
            e.date or "?", e.player or "?", e.rank or "?",
            MTR.FormatDays(e.daysInactive or 0), e.kickedBy or "?")
    end
    return out
end

-- ============================================================================
-- SHIFT-CLICK ITEM LINK INSERTION
-- ============================================================================
-- In WoW 3.3.5a, shift-clicking any item, spell, achievement, etc. calls the
-- global ChatEdit_InsertLink(text).  Normally that inserts the coloured link
-- into whatever chat editbox currently has focus.
--
-- We hook that function so that if one of our registered item-input boxes has
-- keyboard focus at the time of the shift-click, the link goes there instead.
-- All other shift-clicks (into chat) are passed through unchanged.
--
-- Usage: call MTR.RegisterLinkEditBox(eb) after creating any EditBox that
-- should accept item links.  The Auction and Roll tab item boxes are wired up
-- in UI_Config.lua.
-- ============================================================================

function MTR.RegisterLinkEditBox(eb)
    if not eb then return end
    -- Guard against double-registration
    for _, existing in ipairs(MTR.linkEditBoxes) do
        if existing == eb then return end
    end
    MTR.linkEditBoxes[#MTR.linkEditBoxes + 1] = eb
end

-- Hook ChatEdit_InsertLink.
-- We use a late-binding wrapper so that the original function is captured
-- *after* all FrameXML has fully loaded (it is defined in ChatFrame.lua which
-- loads before addons, so it is always present by the time our code runs).
local _origInsertLink = ChatEdit_InsertLink
function ChatEdit_InsertLink(text)
    -- Walk our registered boxes; if any is visible AND focused, insert there.
    for _, eb in ipairs(MTR.linkEditBoxes) do
        if eb and eb:IsVisible() and eb:HasFocus() then
            -- Clear existing text first so the full link replaces whatever
            -- partial name the user may have typed, then re-focus.
            eb:SetText(text)
            eb:SetCursorPosition(#text)
            eb:SetFocus()
            return true   -- returning true suppresses chat insertion
        end
    end
    -- No MekTown box is focused – fall through to normal chat insertion.
    return _origInsertLink(text)
end


-- Tooltip helper
function MTR.AttachTooltip(frame, title, text)
    if not frame then return end
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if title and title ~= "" then
            GameTooltip:SetText(title, 1, 0.82, 0)
        end
        if text and text ~= "" then
            GameTooltip:AddLine(text, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Simple collapsible section helper for large config panels
function MTR.MakeCollapsibleSection(parent, title, width, ax, ay, defaultExpanded)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetWidth(width or 780)
    holder:SetPoint("TOPLEFT", parent, "TOPLEFT", ax or 0, ay or 0)

    local header = CreateFrame("Button", nil, holder)
    header:SetSize(width or 780, 20)
    header:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)

    local line = holder:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.2, 0.2, 0.35, 0.6)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -18)
    line:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, -18)

    local label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    label:SetJustifyH("LEFT")

    local content = CreateFrame("Frame", nil, holder)
    content:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -24)
    content:SetWidth((width or 780) - 4)
    content:SetHeight(1)
    if content.SetClipsChildren then content:SetClipsChildren(true) end

    holder.expanded = (defaultExpanded ~= false)

    local function RefreshHeader()
        local prefix = holder.expanded and "[-] " or "[+] "
        label:SetText("|cffd4af37" .. prefix .. title .. "|r")
        if holder.expanded then content:Show() else content:Hide() end
        holder:SetHeight((holder.expanded and (24 + (content._contentHeight or 1)) or 24))
    end

    function holder:SetContentHeight(h)
        h = math.max(1, tonumber(h) or 1)
        content._contentHeight = h
        content:SetHeight(h)
        RefreshHeader()
    end

    header:SetScript("OnClick", function()
        holder.expanded = not holder.expanded
        RefreshHeader()
    end)

    holder.header = header
    holder.label = label
    holder.content = content
    RefreshHeader()
    return holder, content
end
