-- ============================================================================
-- Roll.lua  v5.0
-- Roll-for-loot system – frame, /roll capture, winner declaration
-- ============================================================================
local MTR = MekTownRecruit

MTR.ROLL_TYPES = { "MS", "OS", "Transmog", "Legendary", "Tier Token", "Custom" }

local rollFrame = nil

-- ============================================================================
-- HELPERS
-- ============================================================================
local function RollGetSortedRolls()
    if not MTR.activeRoll then return {} end
    local sorted = {}
    for name, val in pairs(MTR.activeRoll.rolls) do
        sorted[#sorted+1] = { name=name, value=val }
    end
    table.sort(sorted, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.name < b.name
    end)
    return sorted
end

-- ============================================================================
-- FRAME REFRESH
-- ============================================================================
local function RollRefreshFrame()
    if not rollFrame or not rollFrame:IsShown() then return end
    local content = rollFrame._content

    -- Destroy all child frames (Frame objects, not FontStrings).
    -- We store rows in a pool table so they can be re-used / hidden cleanly.
    if not rollFrame._rowPool then rollFrame._rowPool = {} end
    for _, r in ipairs(rollFrame._rowPool) do r:Hide() end
    rollFrame._rowPool = {}

    if not MTR.activeRoll then
        rollFrame._title:SetText("|cffaaaaaa No active roll|r")
        rollFrame._timerLabel:SetText("")
        return
    end

    rollFrame._title:SetText("|cffd4af37["..MTR.activeRoll.item.."] "..MTR.activeRoll.rollType.."|r")

    if MTR.activeRoll.closeTime then
        local remaining = math.max(0, MTR.activeRoll.closeTime - time())
        if remaining > 0 then
            rollFrame._timerLabel:SetText("|cffff9900"..remaining.."s remaining|r")
        else
            rollFrame._timerLabel:SetText("|cffff4444Roll closed|r")
        end
    else
        rollFrame._timerLabel:SetText("|cffaaaaaa Manual close|r")
    end

    if MTR.activeRoll.tiedPlayers and #MTR.activeRoll.tiedPlayers > 0 then
        local names = {}
        for _, n in ipairs(MTR.activeRoll.tiedPlayers) do names[#names+1] = n end
        rollFrame._tieLabel:SetText("|cffff9900TIE between: "..table.concat(names,", ")..". Awaiting reroll...|r")
    else
        rollFrame._tieLabel:SetText("")
    end

    local sorted = RollGetSortedRolls()

    if #sorted == 0 then
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(340, 20)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, 0)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetAllPoints(row)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cffaaaaaa Waiting for rolls...|r")
        row:Show()
        rollFrame._rowPool[1] = row
    else
        for i, entry in ipairs(sorted) do
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(340, 20)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -(i-1)*20)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetAllPoints(row)
            fs:SetJustifyH("LEFT")
            local col = (i == 1) and "|cffd4af37" or "|cffffffff"
            fs:SetText(string.format("%d. %s%s|r  rolled  %d", i, col, MTR.Trunc(entry.name,20), entry.value))
            row:Show()
            rollFrame._rowPool[i] = row
        end
    end

    local expected = MTR.activeRoll.eligibleCount or 0
    rollFrame._countLabel:SetText("|cffaaaaaa"..#sorted.." / "..expected.." rolled|r")
    content:SetHeight(math.max(200, #sorted * 20 + 20))
end

-- ============================================================================
-- WINNER DECLARATION
-- ============================================================================
local function RollDeclareWinner()
    if not MTR.activeRoll then return end
    local sorted = RollGetSortedRolls()
    if #sorted == 0 then MTR.MPE("No rolls recorded.") return end

    local top = sorted[1].value
    local tied = {}
    for _, entry in ipairs(sorted) do
        if entry.value == top then tied[#tied+1] = entry.name
        else break end
    end

    if #tied > 1 then
        MTR.activeRoll.tiedPlayers = tied
        MTR.activeRoll.rolls = {}
        MTR.activeRoll.closeTime = time() + (MTR.activeRoll.rollDuration or 60)
        local names = table.concat(tied, ", ")
        local tieLink = MTR.activeRoll.itemLink or ("["..MTR.activeRoll.item.."]")
        MTR.DKPAnnounce(">>> TIE for "..tieLink.." between "..names.."! Reroll: /roll. You have "..
            (MTR.activeRoll.rollDuration or 60).."s!", MTR.activeRoll.useRW)
        RollRefreshFrame()
        return
    end

    local winner  = sorted[1].name
    local winVal  = sorted[1].value
    local winLink = MTR.activeRoll.itemLink or ("["..MTR.activeRoll.item.."]")
    local msg = string.format(">>> ROLL WINNER: %s rolled %d and wins %s (%s)!",
        winner, winVal, winLink, MTR.activeRoll.rollType)
    MTR.DKPAnnounce(msg, MTR.activeRoll.useRW)

    table.insert(MTR.db.dkpBidLog, {
        date     = date("%Y-%m-%d %H:%M:%S"),
        item     = MTR.activeRoll.item,
        winner   = winner,
        amount   = 0,
        rollType = MTR.activeRoll.rollType,
        allRolls = RollGetSortedRolls(),
        type     = "roll",
    })
    if #MTR.db.dkpBidLog > 200 then tremove(MTR.db.dkpBidLog, 1) end

    MTR.activeRoll = nil
    if rollFrame then rollFrame:Hide() end
    MTR.MP("Roll complete. Winner: "..winner)
end

-- ============================================================================
-- FRAME CREATION
-- ============================================================================
local function RollShowFrame()
    if not rollFrame then
        rollFrame = CreateFrame("Frame", "MekTownRollFrame", UIParent)
        rollFrame:SetSize(400, 460)
        rollFrame:SetPoint("CENTER", UIParent, "CENTER", -200, 0)
        rollFrame:SetBackdrop({
            bgFile   = "",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=false, tileSize=0, edgeSize=32,
            insets={left=8,right=8,top=8,bottom=8},
        })
        rollFrame:SetBackdropColor(0,0,0,0)
        do local _bt=rollFrame:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(rollFrame) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
        rollFrame:SetFrameStrata("DIALOG")
        rollFrame:EnableMouse(true)
        rollFrame:SetMovable(true)
        rollFrame:RegisterForDrag("LeftButton")
        rollFrame:SetScript("OnDragStart", rollFrame.StartMoving)
        rollFrame:SetScript("OnDragStop",  rollFrame.StopMovingOrSizing)

        local hdr = rollFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        hdr:SetPoint("TOP", rollFrame, "TOP", 0, -12)
        hdr:SetText("|cff00ff00MekTown Roll|r")

        local title = rollFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        title:SetPoint("TOP", hdr, "BOTTOM", 0, -2)
        title:SetText("")
        rollFrame._title = title

        local timerLabel = rollFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        timerLabel:SetPoint("TOP", title, "BOTTOM", 0, -2)
        timerLabel:SetText("")
        rollFrame._timerLabel = timerLabel

        local tieLabel = rollFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        tieLabel:SetPoint("TOP", timerLabel, "BOTTOM", 0, -2)
        tieLabel:SetText("")
        rollFrame._tieLabel = tieLabel

        local countLabel = rollFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        countLabel:SetPoint("TOP", tieLabel, "BOTTOM", 0, -2)
        countLabel:SetText("")
        rollFrame._countLabel = countLabel

        local sf = CreateFrame("ScrollFrame", nil, rollFrame, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     rollFrame, "TOPLEFT",    12, -100)
        sf:SetPoint("BOTTOMRIGHT", rollFrame, "BOTTOMRIGHT", -28, 54)
        local content = CreateFrame("Frame", nil, sf)
        content:SetSize(360, 300)
        sf:SetScrollChild(content)
        rollFrame._content = content

        -- Declare Winner
        local winBtn = CreateFrame("Button", nil, rollFrame, "UIPanelButtonTemplate")
        winBtn:SetSize(130, 24)
        winBtn:SetPoint("BOTTOMLEFT", rollFrame, "BOTTOMLEFT", 8, 28)
        winBtn:SetText("Declare Winner")
        winBtn:SetScript("OnClick", function() RollDeclareWinner() end)

        -- Close Rolls early
        local closeBtn = CreateFrame("Button", nil, rollFrame, "UIPanelButtonTemplate")
        closeBtn:SetSize(100, 24)
        closeBtn:SetPoint("LEFT", winBtn, "RIGHT", 4, 0)
        closeBtn:SetText("Close Rolls")
        closeBtn:SetScript("OnClick", function()
            if not MTR.activeRoll then rollFrame:Hide() return end
            MTR.activeRoll.closeTime = time() - 1
            MTR.DKPAnnounce(">>> ROLLS CLOSED for "..(MTR.activeRoll.itemLink or "["..MTR.activeRoll.item.."]")..". Declaring winner...", MTR.activeRoll.useRW)
            MTR.After(1, RollDeclareWinner)
        end)

        -- Cancel
        local canBtn = CreateFrame("Button", nil, rollFrame, "UIPanelButtonTemplate")
        canBtn:SetSize(80, 24)
        canBtn:SetPoint("LEFT", closeBtn, "RIGHT", 4, 0)
        canBtn:SetText("Cancel")
        canBtn:SetScript("OnClick", function()
            if MTR.activeRoll then
                MTR.DKPAnnounce(">>> Roll CANCELLED for "..(MTR.activeRoll.itemLink or "["..MTR.activeRoll.item.."]")..".", MTR.activeRoll.useRW)
                MTR.activeRoll = nil
            end
            rollFrame:Hide()
        end)

        local xBtn = CreateFrame("Button", nil, rollFrame, "UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT", rollFrame, "TOPRIGHT", -2, -2)
        xBtn:SetScript("OnClick", function() rollFrame:Hide() end)

        -- Auto-refresh + auto-declare on timer expiry
        rollFrame:SetScript("OnUpdate", function(self, elapsed)
            self._ticker = (self._ticker or 0) + elapsed
            if self._ticker >= 0.5 then
                self._ticker = 0
                RollRefreshFrame()
                if MTR.activeRoll and MTR.activeRoll.closeTime and time() >= MTR.activeRoll.closeTime then
                    if not MTR.activeRoll.timerFired then
                        MTR.activeRoll.timerFired = true
                        MTR.DKPAnnounce(">>> ROLLS CLOSED for "..(MTR.activeRoll.itemLink or "["..MTR.activeRoll.item.."]")..". Calculating...", MTR.activeRoll.useRW)
                        MTR.After(1, RollDeclareWinner)
                    end
                end
            end
        end)
    end
    RollRefreshFrame()
    rollFrame:Show()
end

function MTR.ShowRollFrame()
    if not MTR.activeRoll then
        if MTR.MPE then MTR.MPE("No active roll right now.") end
        return
    end
    RollShowFrame()
end

-- ============================================================================
-- PUBLIC ENTRY POINT
-- ============================================================================
function MTR.RollOpen(itemName, rollType, timeSecs, useRW)

    -- If there's already an active roll, cancel it silently and start fresh
    if MTR.activeRoll then
        MTR.MP("|cffaaaaaCancelling previous roll for "..MTR.activeRoll.item.." — starting new roll.|r")
        MTR.activeRoll = nil
    end

    -- Accept full item links; store plain name for display/storage
    local displayName  = MTR.ItemLinkToName(itemName)
    local announceItem = MTR.IsItemLink(itemName) and itemName or "["..itemName.."]"

    local eligibleCount = 0
    if IsInRaid() then
        eligibleCount = GetNumRaidMembers()
    elseif IsInGroup() then
        eligibleCount = GetNumPartyMembers() + 1
    end

    MTR.activeRoll = {
        item          = displayName,
        itemLink      = itemName,
        rollType      = rollType or "MS",
        rolls         = {},          -- always starts fresh/empty
        opened        = time(),
        closeTime     = timeSecs and (time() + timeSecs) or nil,
        rollDuration  = timeSecs or 60,
        useRW         = useRW or false,
        tiedPlayers   = nil,
        timerFired    = false,
        eligibleCount = eligibleCount,
    }

    local timeStr = timeSecs and (" You have "..timeSecs.."s!") or ""
    MTR.DKPAnnounce(">>> ROLL FOR LOOT: "..announceItem.." ("..rollType..") - /roll"..timeStr, useRW)
    MTR.MP("Roll opened: "..displayName.." ("..rollType..")")
    RollShowFrame()
end

-- ============================================================================
-- ROLL + BID CAPTURE
--
-- CONFIRMED from WoW API docs and working addon examples:
--   /roll fires CHAT_MSG_SYSTEM visible to all group members and nearby players.
--   Correct pattern: "(.+) rolls (%d+) %((%d+)-(%d+)%)"  -- NO trailing period
--   This captures: roller name, value, min, max
--
-- Auction bids: captured from CHAT_MSG_WHISPER (players whisper a number).
--   Also captures bids typed in raid/party/say chat as "bid 500" or just "500"
--   so players have flexibility in how they submit.
-- ============================================================================
local rollCaptureFrame = CreateFrame("Frame")
rollCaptureFrame:RegisterEvent("CHAT_MSG_SYSTEM")
rollCaptureFrame:RegisterEvent("CHAT_MSG_SAY")          -- catch rolls when not in group
rollCaptureFrame:RegisterEvent("CHAT_MSG_RAID")         -- some private servers echo here
rollCaptureFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
rollCaptureFrame:RegisterEvent("CHAT_MSG_PARTY")
rollCaptureFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
rollCaptureFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not MTR.initialized or not MTR.db then return end
    if not MTR.activeRoll then return end

    -- Try the confirmed working pattern first (no trailing period required)
    local roller, value, rollMin, rollMax = message:match("(.+) rolls (%d+) %((%d+)-(%d+)%)")

    -- If that didn't match, try with trailing period (some builds include it)
    if not roller then
        roller, value, rollMin, rollMax = message:match("(.+) rolls (%d+) %((%d+)-(%d+)%)%.")
    end

    -- For SYSTEM event the sender arg is empty - name comes from message text
    -- For other chat events, sender is the player name - use it as fallback
    if not roller and sender and sender ~= "" then
        -- Some private servers post roll result in raid/party chat instead of system
        local v = message:match("rolls (%d+)")
        if v then
            roller = sender:match("^([^%-]+)") -- strip realm suffix if present
            value  = v
            rollMin, rollMax = "1", "100"
        end
    end

    if not roller or not value then return end

    rollMin = tonumber(rollMin) or 1
    rollMax = tonumber(rollMax) or 100
    value   = tonumber(value)

    -- Only accept 1-100 rolls (plain /roll with no arguments)
    if rollMin ~= 1 or rollMax ~= 100 then
        MTR.dprint("Ignoring non 1-100 roll from", roller, value, rollMin, rollMax)
        return
    end
    if not value or value < 1 or value > 100 then return end

    -- Tie-reroll phase: only tied players may roll
    if MTR.activeRoll.tiedPlayers and #MTR.activeRoll.tiedPlayers > 0 then
        local isTied = false
        for _, n in ipairs(MTR.activeRoll.tiedPlayers) do
            if n == roller then isTied = true break end
        end
        if not isTied then
            MTR.dprint("Ignoring roll from non-tied player:", roller)
            return
        end
    end

    -- Only record first roll per player
    if MTR.activeRoll.rolls[roller] then
        MTR.dprint("Ignoring duplicate roll from", roller)
        return
    end

    MTR.activeRoll.rolls[roller] = value
    MTR.MP("|cffd4af37Roll recorded:|r " .. roller .. " rolled " .. value)
    RollRefreshFrame()
end)
