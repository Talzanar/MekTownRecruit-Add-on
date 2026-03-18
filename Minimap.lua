-- ============================================================================
-- Minimap.lua  v8.0
-- Main MekTown minimap button.
--   Left-click  → open config window
--   Right-click → toggle recruit scanner (with chat feedback)
--
-- v8.0: dot state update moved from per-frame OnUpdate to MTR.TickAdd
--       (runs every 2 seconds instead of every rendered frame).
--       GroupRadar and LFG minimap buttons managed in GroupRadar.lua.
-- ============================================================================
local MTR = MekTownRecruit

local minimapButton = nil

function MTR.HideMinimapButton()
    if minimapButton then minimapButton:Hide() end
end

function MTR.CreateMinimapButton()
    if minimapButton then minimapButton:Show() return end

    minimapButton = CreateFrame("Button", "MekTownMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 2, -2)

    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\inv_misc_grouplooking")
    icon:SetAllPoints(minimapButton)

    -- Green/red dot shows live recruit scanner state
    local dot = minimapButton:CreateTexture(nil, "OVERLAY")
    dot:SetSize(8, 8)
    dot:SetPoint("BOTTOMRIGHT", minimapButton, "BOTTOMRIGHT", 0, 0)
    minimapButton._dot = dot

    local function UpdateDot()
        if not minimapButton._dot then return end
        if MTR.db and MTR.db.enabled then
            minimapButton._dot:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
        else
            minimapButton._dot:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
        end
    end

    -- Register dot refresh with master tick — 2s interval, not per-frame
    MTR.TickAdd("minimap_dot", 2, UpdateDot)

    minimapButton:SetScript("OnEnter", function()
        UpdateDot()
        GameTooltip:SetOwner(minimapButton, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cff00c0ffMekTown Recruit|r  v" .. (MTR.VERSION or "8"))
        GameTooltip:AddLine((MTR.isOfficer or MTR.isGM) and "|cffffffffLeft-click:|r Open officer panel" or "|cffffffffLeft-click:|r Open member panel")
        local scanState = (MTR.db and MTR.db.enabled) and "|cff00ff00ON|r" or "|cffff4444OFF|r"
        GameTooltip:AddLine("|cffffffffRight-click:|r Toggle recruit scanner " .. scanState)
        GameTooltip:AddLine("|cffaaaaaa/mek radar  — Group Radar|r")
        GameTooltip:AddLine("|cffaaaaaa/mek lfg    — Post Find Group|r")
        GameTooltip:AddLine("|cffaaaaaa/mek gads   — Guild Ad Poster|r")
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapButton:SetScript("OnClick", function(_, btn)
        if btn == "LeftButton" then
            MTR.OpenConfig()
        elseif btn == "RightButton" then
            if MTR.db then
                MTR.db.enabled = not MTR.db.enabled
                if MTR.db.enabled then
                    MTR.MP("|cff00ff00Recruitment scanner ENABLED.|r  Watching channels for LFG messages.")
                else
                    MTR.MP("|cffff4444Recruitment scanner DISABLED.|r")
                end
                UpdateDot()
            end
        end
    end)
end
