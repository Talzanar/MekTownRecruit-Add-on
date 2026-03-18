-- ============================================================================
-- Auction.lua  v5.0
-- DKP auction system – frame, bid capture, award logic
-- ============================================================================
local MTR = MekTownRecruit

local auctionFrame = nil

-- ============================================================================
-- HELPERS
-- ============================================================================
local function AuctionGetSortedBids()
    if not MTR.activeBid then return {} end
    local sorted = {}
    for name, data in pairs(MTR.activeBid.bids) do
        sorted[#sorted+1] = { name=name, amount=data.amount, pending=data.pending }
    end
    table.sort(sorted, function(a, b)
        if a.amount ~= b.amount then return a.amount > b.amount end
        return a.name < b.name
    end)
    return sorted
end

-- ============================================================================
-- FRAME
-- ============================================================================
local function AuctionRefreshFrame()
    if not auctionFrame or not auctionFrame:IsShown() then return end
    local content = auctionFrame._content

    -- Hide and clear all pooled row frames
    if not auctionFrame._rowPool then auctionFrame._rowPool = {} end
    for _, r in ipairs(auctionFrame._rowPool) do r:Hide() end
    auctionFrame._rowPool = {}

    if not MTR.activeBid then
        auctionFrame._title:SetText("|cffaaaaaa No active auction|r")
        auctionFrame._timerLabel:SetText("")
        return
    end

    auctionFrame._title:SetText("|cffd4af37" .. MTR.activeBid.item .. "|r")

    if MTR.activeBid.closeTime then
        local remaining = math.max(0, MTR.activeBid.closeTime - time())
        auctionFrame._timerLabel:SetText(remaining > 0 and ("|cffff9900" .. remaining .. "s remaining|r") or "|cffff4444Closed|r")
    else
        auctionFrame._timerLabel:SetText("|cffaaaaaa Manual close|r")
    end

    local minStr = MTR.activeBid.minBid and ("Min: " .. MTR.activeBid.minBid .. " pts") or "No minimum"
    auctionFrame._minLabel:SetText("|cffaaaaaa" .. minStr .. "|r")

    local sorted = AuctionGetSortedBids()

    if #sorted == 0 then
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(360, 20)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, 0)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetAllPoints(row) fs:SetJustifyH("LEFT")
        fs:SetText("|cffaaaaaa Waiting for bids...|r")
        row:Show()
        auctionFrame._rowPool[1] = row
    else
        for i, entry in ipairs(sorted) do
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(360, 20)
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -(i-1)*20)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetAllPoints(row) fs:SetJustifyH("LEFT")
            local bal  = MTR.DKPBalance(entry.name)
            local col  = (bal >= entry.amount) and "|cff00ff00" or "|cffff4444"
            local pend = entry.pending and " |cffff9900[PENDING]|r" or ""
            fs:SetText(string.format("%d. %s%s|r  Bid: %d  (Bal: %d)%s",
                i, col, MTR.Trunc(entry.name,20), entry.amount, bal, pend))
            row:Show()
            auctionFrame._rowPool[i] = row
        end
    end

    content:SetHeight(math.max(200, #sorted * 20 + 20))
end

local function AuctionShowFrame()
    if not auctionFrame then
        auctionFrame = CreateFrame("Frame", "MekTownAuctionFrame", UIParent)
        auctionFrame:SetSize(420, 480)
        auctionFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
        auctionFrame:SetBackdrop({
            bgFile   = "",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=false, tileSize=0, edgeSize=32,
            insets={left=8,right=8,top=8,bottom=8},
        })
        auctionFrame:SetBackdropColor(0,0,0,0)
        do local _bt=auctionFrame:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(auctionFrame) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
        auctionFrame:SetFrameStrata("DIALOG")
        auctionFrame:EnableMouse(true)
        auctionFrame:SetMovable(true)
        auctionFrame:RegisterForDrag("LeftButton")
        auctionFrame:SetScript("OnDragStart", auctionFrame.StartMoving)
        auctionFrame:SetScript("OnDragStop",  auctionFrame.StopMovingOrSizing)

        local hdr = auctionFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        hdr:SetPoint("TOP", auctionFrame, "TOP", 0, -12)
        hdr:SetText("|cffd4af37MekTown Auction|r")

        local title = auctionFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        title:SetPoint("TOP", hdr, "BOTTOM", 0, -2)
        title:SetText("")
        auctionFrame._title = title

        local timerLabel = auctionFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        timerLabel:SetPoint("TOP", title, "BOTTOM", 0, -2)
        timerLabel:SetText("")
        auctionFrame._timerLabel = timerLabel

        local minLabel = auctionFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        minLabel:SetPoint("TOP", timerLabel, "BOTTOM", 0, -2)
        minLabel:SetText("")
        auctionFrame._minLabel = minLabel

        local sf = CreateFrame("ScrollFrame", nil, auctionFrame, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     auctionFrame, "TOPLEFT",    12, -90)
        sf:SetPoint("BOTTOMRIGHT", auctionFrame, "BOTTOMRIGHT", -28, 54)
        local content = CreateFrame("Frame", nil, sf)
        content:SetSize(370, 300)
        sf:SetScrollChild(content)
        auctionFrame._content = content

        -- Award highest valid bid
        local awBtn = CreateFrame("Button", nil, auctionFrame, "UIPanelButtonTemplate")
        awBtn:SetSize(130, 24)
        awBtn:SetPoint("BOTTOMLEFT", auctionFrame, "BOTTOMLEFT", 8, 28)
        awBtn:SetText("Award Highest")
        awBtn:SetScript("OnClick", function()
            if not MTR.activeBid then MTR.MPE("No active auction.") return end
            local sorted = AuctionGetSortedBids()
            for _, entry in ipairs(sorted) do
                if not entry.pending and MTR.DKPBalance(entry.name) >= entry.amount then
                    MTR.DKPAdd(entry.name, -entry.amount, "Won auction: "..MTR.activeBid.item, MTR.playerName)
                    table.insert(MTR.db.dkpBidLog, {
                        date=date("%Y-%m-%d %H:%M:%S"), item=MTR.activeBid.item,
                        winner=entry.name, amount=entry.amount,
                        allBids=MTR.DeepCopy(MTR.activeBid.bids), type="auction",
                    })
                    if #MTR.db.dkpBidLog > 200 then tremove(MTR.db.dkpBidLog, 1) end
                    local msg = string.format(">>> AUCTION WINNER: %s wins [%s] for %d DKP! New balance: %d pts.",
                        entry.name, MTR.activeBid.item, entry.amount, MTR.DKPBalance(entry.name))
                    MTR.DKPAnnounce(msg, MTR.activeBid.useRW)
                    MTR.activeBid = nil
                    auctionFrame:Hide()
                    MTR.DKPSyncToRaidSafe()
                    return
                end
            end
            MTR.MPE("No valid bids found.")
        end)

        -- Award specific player
        local awSpBtn = CreateFrame("Button", nil, auctionFrame, "UIPanelButtonTemplate")
        awSpBtn:SetSize(120, 24)
        awSpBtn:SetPoint("LEFT", awBtn, "RIGHT", 4, 0)
        awSpBtn:SetText("Award Player...")
        awSpBtn:SetScript("OnClick", function()
            if not MTR.activeBid then MTR.MPE("No active auction.") return end
            StaticPopupDialogs["MEKTOWN_AUCTION_AWARD"] = {
                text="Award to which player?\n(Overrides bid amount if needed)",
                button1="Award", button2="Cancel", hasEditBox=true, maxLetters=40,
                OnAccept=function(self)
                    local n = self.editBox:GetText():match("^%s*(.-)%s*$")
                    if not n or n=="" or not MTR.activeBid then return end
                    local amt = MTR.activeBid.bids[n] and MTR.activeBid.bids[n].amount or 0
                    MTR.DKPAdd(n, -amt, "Won auction: "..MTR.activeBid.item, MTR.playerName)
                    table.insert(MTR.db.dkpBidLog, {
                        date=date("%Y-%m-%d %H:%M:%S"), item=MTR.activeBid.item,
                        winner=n, amount=amt, allBids=MTR.DeepCopy(MTR.activeBid.bids), type="auction",
                    })
                    if #MTR.db.dkpBidLog > 200 then tremove(MTR.db.dkpBidLog, 1) end
                    local msg = string.format(">>> AUCTION WINNER: %s wins [%s] for %d DKP! New balance: %d pts.",
                        n, MTR.activeBid.item, amt, MTR.DKPBalance(n))
                    MTR.DKPAnnounce(msg, MTR.activeBid.useRW)
                    MTR.activeBid = nil
                    auctionFrame:Hide()
                    MTR.DKPSyncToRaidSafe()
                end,
                timeout=0, whileDead=true, hideOnEscape=true,
            }
            StaticPopup_Show("MEKTOWN_AUCTION_AWARD")
        end)

        -- Close bidding
        local clBtn = CreateFrame("Button", nil, auctionFrame, "UIPanelButtonTemplate")
        clBtn:SetSize(100, 24)
        clBtn:SetPoint("LEFT", awSpBtn, "RIGHT", 4, 0)
        clBtn:SetText("Close Bids")
        clBtn:SetScript("OnClick", function()
            if not MTR.activeBid then MTR.MPE("No active auction.") return end
            MTR.activeBid.closeTime = time() - 1
            MTR.DKPAnnounce(">>> BIDDING CLOSED for "..(MTR.activeBid.itemLink or "["..MTR.activeBid.item.."]")..". Awarding shortly...", MTR.activeBid.useRW)
            AuctionRefreshFrame()
        end)

        -- Cancel
        local canBtn = CreateFrame("Button", nil, auctionFrame, "UIPanelButtonTemplate")
        canBtn:SetSize(80, 24)
        canBtn:SetPoint("BOTTOMRIGHT", auctionFrame, "BOTTOMRIGHT", -8, 28)
        canBtn:SetText("Cancel")
        canBtn:SetScript("OnClick", function()
            if not MTR.activeBid then auctionFrame:Hide() return end
            MTR.DKPAnnounce(">>> Auction CANCELLED for "..(MTR.activeBid.itemLink or "["..MTR.activeBid.item.."]")..".", MTR.activeBid.useRW)
            MTR.activeBid = nil
            auctionFrame:Hide()
        end)

        local xBtn = CreateFrame("Button", nil, auctionFrame, "UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT", auctionFrame, "TOPRIGHT", -2, -2)
        xBtn:SetScript("OnClick", function() auctionFrame:Hide() end)

        -- Auto-refresh + auto-close ticker
        auctionFrame:SetScript("OnUpdate", function(self, elapsed)
            self._ticker = (self._ticker or 0) + elapsed
            if self._ticker >= 1 then
                self._ticker = 0
                AuctionRefreshFrame()
                if MTR.activeBid and MTR.activeBid.closeTime and time() >= MTR.activeBid.closeTime then
                    if not MTR.activeBid.announced then
                        MTR.activeBid.announced = true
                        MTR.DKPAnnounce(">>> BIDDING CLOSED for "..(MTR.activeBid.itemLink or "["..MTR.activeBid.item.."]")..". Awarding shortly...", MTR.activeBid.useRW)
                    end
                end
            end
        end)
    end
    AuctionRefreshFrame()
    auctionFrame:Show()
end

-- ============================================================================
-- PUBLIC ENTRY POINT
-- ============================================================================
function MTR.AuctionOpen(itemName, minBid, timeSecs, useRW)
    if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
    if MTR.activeBid then MTR.MPE("Auction already active: "..MTR.activeBid.item) return end

    local displayName  = MTR.ItemLinkToName(itemName)
    local announceItem = MTR.IsItemLink(itemName) and itemName or "["..itemName.."]"

    MTR.activeBid = {
        item      = displayName,
        itemLink  = itemName,
        bids      = {},
        opened    = time(),
        minBid    = minBid,
        closeTime = timeSecs and (time() + timeSecs) or nil,
        useRW     = useRW or false,
        announced = false,
    }
    local timeStr = timeSecs and (" You have "..timeSecs.."s!") or ""
    local minStr  = minBid and (" Min bid: "..minBid.." pts.") or ""
    MTR.DKPAnnounce(">>> AUCTION OPEN: "..announceItem..minStr.." Whisper "..MTR.playerName.." your bid OR type 'bid <amount>' in chat!"..timeStr, useRW)
    MTR.MP("Auction opened: "..displayName)
    AuctionShowFrame()
end

-- ============================================================================
-- BID CAPTURE
-- Whisper: player whispers a plain number  e.g. "500"
-- Raid/Party/Say: player types "bid 500" or "b 500" in group chat
-- ============================================================================
local bidChatFrame = CreateFrame("Frame")
bidChatFrame:RegisterEvent("CHAT_MSG_WHISPER")
bidChatFrame:RegisterEvent("CHAT_MSG_RAID")
bidChatFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
bidChatFrame:RegisterEvent("CHAT_MSG_PARTY")
bidChatFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
bidChatFrame:RegisterEvent("CHAT_MSG_SAY")
bidChatFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not MTR.initialized or not MTR.db then return end

    -- Auction bid capture
    if MTR.activeBid then
        local amount = nil

        if event == "CHAT_MSG_WHISPER" then
            -- Whisper: plain number only e.g. "500"
            amount = tonumber(message:match("^%s*(%d+)%s*$"))
        else
            -- Raid/Party/Say: must say "bid 500" or "b 500" to avoid false positives
            amount = tonumber(message:match("^%s*[Bb]id%s+(%d+)"))
                  or tonumber(message:match("^%s*[Bb]%s+(%d+)"))
        end

        if amount and amount > 0 then
            local bal = MTR.DKPBalance(sender)
            if MTR.activeBid.minBid and amount < MTR.activeBid.minBid then
                local popupKey = "MEKTOWN_LOW_BID_" .. sender:upper():gsub("[^%a%d]","_")
                StaticPopupDialogs[popupKey] = {
                    text = string.format("%s bid %d pts (minimum is %d).\nAllow this below-minimum bid?",
                        sender, amount, MTR.activeBid.minBid),
                    button1 = "Allow", button2 = "Deny",
                    OnAccept = function()
                        if not MTR.activeBid then return end
                        MTR.activeBid.bids[sender] = { amount=amount, pending=false }
                        if event == "CHAT_MSG_WHISPER" then
                            MTR.SendChatSafe("Your bid of "..amount.." pts for ["..MTR.activeBid.item.."] has been accepted.", "WHISPER", nil, sender)
                        end
                        AuctionRefreshFrame()
                    end,
                    OnCancel = function()
                        if event == "CHAT_MSG_WHISPER" then
                            MTR.SendChatSafe("Your bid of "..amount.." was below the minimum of "..MTR.activeBid.minBid.." pts. Please bid at least "..MTR.activeBid.minBid.." pts.", "WHISPER", nil, sender)
                        end
                    end,
                    timeout=0, whileDead=true, hideOnEscape=true,
                }
                MTR.activeBid.bids[sender] = { amount=amount, pending=true }
                AuctionRefreshFrame()
                StaticPopup_Show(popupKey)
                return
            end
            if amount > bal then
                if event == "CHAT_MSG_WHISPER" then
                    MTR.SendChatSafe("You cannot bid "..amount.." - your balance is "..bal.." pts.", "WHISPER", nil, sender)
                end
                return
            end
            MTR.activeBid.bids[sender] = { amount=amount, pending=false }
            if event == "CHAT_MSG_WHISPER" then
                MTR.SendChatSafe("Bid of "..amount.." pts registered for ["..MTR.activeBid.item.."]. Good luck!", "WHISPER", nil, sender)
            end
            AuctionRefreshFrame()
            MTR.dprint("Auction bid:", sender, amount)
            return
        end
    end

    -- DKP self-lookup via whisper only
    if event == "CHAT_MSG_WHISPER" then
        local cmd = message:lower():match("^%s*(.-)%s*$")
        if cmd == "!dkp" then
            MTR.SendChatSafe("Your DKP balance: "..MTR.DKPBalance(sender).." pts. Whisper !dkplog for history.", "WHISPER", nil, sender)
        elseif cmd == "!dkplog" then
            local hist = MTR.db.dkpLedger[sender] and MTR.db.dkpLedger[sender].history or {}
            MTR.SendChatSafe("=== Your last DKP transactions ===", "WHISPER", nil, sender)
            for i = math.max(1, #hist-4), #hist do
                local e = hist[i]
                MTR.SendChatSafe(string.format("[%s] %s%d (%s) Bal: %d",
                    e.date, e.amount>=0 and "+" or "", e.amount, e.reason, e.balance),
                    "WHISPER", nil, sender)
            end
        end
    end
end)
