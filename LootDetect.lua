-- ============================================================================
-- LootDetect.lua  v5.0  (NEW FEATURE)
--
-- When the addon is active and the player is the raid leader (or assist),
-- this module watches for epic-quality (or better) items appearing in the
-- loot window and pops up a prompt asking whether to start a Roll or Auction.
--
-- Quality thresholds:
--   0 Poor | 1 Common | 2 Uncommon | 3 Rare | 4 Epic | 5 Legendary
-- We fire for quality >= 4 (Epic+) unless the item is already being rolled.
-- ============================================================================
local MTR = MekTownRecruit

local QUALITY_THRESHOLD = 4  -- Epic and above

-- ============================================================================
-- PROMPT FRAME  (created once, reused)
-- ============================================================================
local lootPrompt = nil
local pendingLink = nil   -- item link waiting for a decision

local function HideLootPrompt()
    if lootPrompt then lootPrompt:Hide() end
    pendingLink = nil
end

local function ShowLootPrompt(itemLink, itemName)
    -- Don't stack prompts - queue the most recent item
    pendingLink = itemLink

    if not lootPrompt then
        lootPrompt = CreateFrame("Frame", "MekTownLootPrompt", UIParent)
        lootPrompt:SetSize(380, 140)
        lootPrompt:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        lootPrompt:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true, tileSize=16, edgeSize=16,
            insets={left=5,right=5,top=5,bottom=5},
        })
        lootPrompt:SetBackdropColor(0.05, 0.05, 0.15, 0.97)
        lootPrompt:SetFrameStrata("DIALOG")
        lootPrompt:EnableMouse(true)
        lootPrompt:SetMovable(true)
        lootPrompt:RegisterForDrag("LeftButton")
        lootPrompt:SetScript("OnDragStart", lootPrompt.StartMoving)
        lootPrompt:SetScript("OnDragStop",  lootPrompt.StopMovingOrSizing)

        -- Header
        local hdr = lootPrompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        hdr:SetPoint("TOP", lootPrompt, "TOP", 0, -12)
        hdr:SetText("|cffd4af37Epic Loot Detected!|r")
        lootPrompt._hdr = hdr

        -- Item label
        local itemLbl = lootPrompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        itemLbl:SetPoint("TOP", hdr, "BOTTOM", 0, -4)
        itemLbl:SetWidth(350)
        itemLbl:SetWordWrap(false)
        itemLbl:SetText("")
        lootPrompt._itemLbl = itemLbl

        local subLbl = lootPrompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        subLbl:SetPoint("TOP", itemLbl, "BOTTOM", 0, -4)
        subLbl:SetText("|cffaaaaaa What would you like to do?|r")

        -- ROLL button
        local rollBtn = CreateFrame("Button", nil, lootPrompt, "UIPanelButtonTemplate")
        rollBtn:SetSize(110, 28)
        rollBtn:SetPoint("BOTTOMLEFT", lootPrompt, "BOTTOMLEFT", 12, 12)
        rollBtn:SetText("|cff00ff00Roll (MS)|r")
        rollBtn:SetScript("OnClick", function()
            if pendingLink then
                MTR.RollOpen(pendingLink, "MS", 60, IsRaidLeader())
            end
            HideLootPrompt()
        end)

        -- AUCTION button
        local auctBtn = CreateFrame("Button", nil, lootPrompt, "UIPanelButtonTemplate")
        auctBtn:SetSize(110, 28)
        auctBtn:SetPoint("LEFT", rollBtn, "RIGHT", 6, 0)
        auctBtn:SetText("|cffd4af37Auction|r")
        auctBtn:SetScript("OnClick", function()
            if pendingLink then
                MTR.AuctionOpen(pendingLink, nil, 60, IsRaidLeader())
            end
            HideLootPrompt()
        end)

        -- OS button
        local osBtn = CreateFrame("Button", nil, lootPrompt, "UIPanelButtonTemplate")
        osBtn:SetSize(80, 28)
        osBtn:SetPoint("LEFT", auctBtn, "RIGHT", 6, 0)
        osBtn:SetText("Roll (OS)")
        osBtn:SetScript("OnClick", function()
            if pendingLink then
                MTR.RollOpen(pendingLink, "OS", 60, IsRaidLeader())
            end
            HideLootPrompt()
        end)

        -- Dismiss button
        local dimBtn = CreateFrame("Button", nil, lootPrompt, "UIPanelButtonTemplate")
        dimBtn:SetSize(70, 28)
        dimBtn:SetPoint("BOTTOMRIGHT", lootPrompt, "BOTTOMRIGHT", -12, 12)
        dimBtn:SetText("Ignore")
        dimBtn:SetScript("OnClick", HideLootPrompt)

        -- X close
        local xBtn = CreateFrame("Button", nil, lootPrompt, "UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT", lootPrompt, "TOPRIGHT", -2, -2)
        xBtn:SetScript("OnClick", HideLootPrompt)
    end

    lootPrompt._itemLbl:SetText(itemLink)
    lootPrompt:Show()

    -- Auto-dismiss after 30 seconds if no action taken
    lootPrompt._autoDismissTimer = 30
    lootPrompt:SetScript("OnUpdate", function(self, elapsed)
        self._autoDismissTimer = (self._autoDismissTimer or 30) - elapsed
        if self._autoDismissTimer <= 0 then
            self:SetScript("OnUpdate", nil)
            HideLootPrompt()
        end
    end)
end

-- ============================================================================
-- LOOT EVENT LISTENER
-- ============================================================================
local lootFrame = CreateFrame("Frame")
lootFrame:RegisterEvent("LOOT_OPENED")
lootFrame:SetScript("OnEvent", function(self, event)
    if not MTR.initialized or not MTR.db then return end
    if not MTR.db.enabled then return end

    -- Only prompt if we can lead the loot decision
    if not IsInRaid() then return end
    if not (IsRaidLeader() or UnitIsGroupAssistant("player")) then return end

    -- No point prompting if a roll or auction is already running
    if MTR.activeRoll or MTR.activeBid then return end

    local numSlots = GetNumLootItems()
    for i = 1, numSlots do
        local _, _, _, quality, locked = GetLootSlotInfo(i)
        if quality and quality >= QUALITY_THRESHOLD and not locked then
            local itemLink = GetLootSlotLink(i)
            if itemLink then
                local itemName = MTR.ItemLinkToName(itemLink)
                MTR.dprint("Epic loot detected:", itemName, "quality:", quality)
                ShowLootPrompt(itemLink, itemName)
                break  -- show prompt for the first epic+ item
            end
        end
    end
end)

-- Hide prompt when loot window closes
lootFrame:RegisterEvent("LOOT_CLOSED")
lootFrame:SetScript("OnEvent", function(self, event)
    if event == "LOOT_CLOSED" then
        -- Only auto-hide if no roll/auction was started
        if not MTR.activeRoll and not MTR.activeBid then
            HideLootPrompt()
        end
    end
end)
-- Re-register both events properly (SetScript overwrote the first one above)
lootFrame:SetScript("OnEvent", function(self, event)
    if event == "LOOT_OPENED" then
        if not MTR.initialized or not MTR.db or not MTR.db.enabled then return end
        if not IsInRaid() then return end
        if not (IsRaidLeader() or UnitIsGroupAssistant("player")) then return end
        if MTR.activeRoll or MTR.activeBid then return end

        local numSlots = GetNumLootItems()
        for i = 1, numSlots do
            local _, _, _, quality, locked = GetLootSlotInfo(i)
            if quality and quality >= QUALITY_THRESHOLD and not locked then
                local itemLink = GetLootSlotLink(i)
                if itemLink then
                    ShowLootPrompt(itemLink, MTR.ItemLinkToName(itemLink))
                    break
                end
            end
        end
    elseif event == "LOOT_CLOSED" then
        if not MTR.activeRoll and not MTR.activeBid then
            HideLootPrompt()
        end
    end
end)
