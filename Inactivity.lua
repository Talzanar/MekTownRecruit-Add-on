-- ============================================================================
-- Inactivity.lua  v5.1
-- Guild inactivity scanner, GM kick popup, kick log sync
-- ============================================================================
local MTR = MekTownRecruit

-- ============================================================================
-- KICK LOG SYNC  (prefix "MekTownKK")
--
-- Previously kick log entries were written locally only. Officers who were
-- offline when a kick happened never saw it in their Kick History.
--
-- Design: every kick fires MTR.KickBroadcast() which sends a single compact
-- packet to all online guild members. Receivers merge using a composite dedup
-- key (player .. date) so replaying the same sync is always safe.
--
-- Wire format (GUILD channel, prefix "MekTownKK"):
--   "KK:date|player|rank|days|kickedBy"
--   Max length: 3 + 19 + 12 + 20 + 4 + 12 + 4 separators = 74 chars (< 255)
--   Single packet — no chunking required.
-- ============================================================================
local KK_PREFIX = "MekTownKK"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(KK_PREFIX) end

-- Composite dedup key for kick entries
local function KKKey(e)
    return (e.player or "") .. "|" .. (e.date or "")
end

-- Merge one kick entry into the local log (dedup + cap at 200)
local function KKMergeEntry(entry)
    if not MTR.db then return false end
    local log = MTR.db.inactivityKickLog
    local key = KKKey(entry)
    for _, existing in ipairs(log) do
        if KKKey(existing) == key then return false end
    end
    table.insert(log, entry)
    if #log > 200 then tremove(log, 1) end
    return true
end

-- Broadcast a kick entry to all online guild members and store it locally.
-- This is the single authoritative insertion point — all kick paths call this.
function MTR.KickBroadcast(playerName, rank, daysInactive, kickedBy)
    local entry = {
        date        = date("%Y-%m-%d %H:%M:%S"),
        player      = playerName,
        rank        = rank        or "?",
        daysInactive = daysInactive or 0,
        kickedBy    = kickedBy    or MTR.playerName or "?",
    }
    -- Store locally first (the kicker always has the record)
    KKMergeEntry(entry)
    -- Broadcast to all online guild members with the addon
    if IsInGuild() then
        local rank_s  = entry.rank:gsub("|", ""):gsub(",", "")
        local days_s  = tostring(math.floor(entry.daysInactive))
        local packet  = "KK:"
            .. entry.date        .. "|"
            .. entry.player      .. "|"
            .. rank_s            .. "|"
            .. days_s            .. "|"
            .. entry.kickedBy
        SendAddonMessage(KK_PREFIX, packet, "GUILD")
        MTR.dprint("[KK Sync] Broadcast kick:", entry.player)
    end
end

-- Receive handler
local kkAddonFrame = CreateFrame("Frame")
kkAddonFrame:RegisterEvent("CHAT_MSG_ADDON")
kkAddonFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= KK_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end

    local senderName = (sender or ""):match("^([^%-]+)") or ""
    if senderName == MTR.playerName then return end  -- ignore own echo

    -- Parse: "KK:date|player|rank|days|kickedBy"
    local payload = message:sub(4)   -- strip "KK:" prefix
    local dt, player, rank, days, kickedBy =
        payload:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not dt then return end

    local entry = {
        date         = dt,
        player       = player,
        rank         = rank,
        daysInactive = tonumber(days) or 0,
        kickedBy     = kickedBy,
    }
    if KKMergeEntry(entry) then
        MTR.dprint("[KK Sync] Merged kick entry for", player, "from", senderName)
    end
end)

-- ============================================================================
-- THRESHOLD LOOKUP
-- ============================================================================
local function InactGetThreshold(rankName)
    local rules = MTR.db.inactivityRankRules or {}
    for _, safe in ipairs(MTR.db.inactivitySafeRanks or {}) do
        if safe == rankName then return "never" end
    end
    if rules[rankName] ~= nil then return rules[rankName] end
    return MTR.db.inactivityDefaultDays or 28
end

-- ============================================================================
-- SCAN
-- ============================================================================
function MTR.InactScan()
    if not IsInGuild() then return {} end
    local inactive = {}
    local num      = GetNumGuildMembers()
    local seenLog  = MTR.db.inactivitySeenLog or {}
    local now      = time()

    for i = 1, num do
        local name, rankName, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)

        if not name or name == "" then
            -- skip empty slot

        elseif online then
            -- Currently online — record seen timestamp, skip inactivity check
            seenLog[name] = now

        else
            -- OFFLINE — always check for inactivity
            if not (MTR.db.inactivityWhitelist or {})[name] then
                local threshold = InactGetThreshold(rankName or "")
                if threshold ~= "never" then

                    local years, months, days, hours = GetGuildRosterLastOnline(i)
                    local totalDays = nil
                    local unknown   = false

                    if years ~= nil then
                        -- Server returned real last-online data
                        totalDays = (years  or 0) * 365
                                  + (months or 0) * 30
                                  + (days   or 0)
                                  + math.floor((hours or 0) / 24)
                    elseif seenLog[name] then
                        -- Use addon's own seen-log as fallback
                        totalDays = math.floor((now - seenLog[name]) / 86400)
                    else
                        -- Ascension returns nil for all LastOnline fields — member
                        -- is offline and we have zero data on when they were last on.
                        -- Flag as unknown and include them regardless of threshold.
                        totalDays = 999
                        unknown   = true
                    end

                    -- Include if: data shows >= threshold days, OR completely unknown
                    if unknown or (totalDays and totalDays >= threshold) then
                        inactive[#inactive+1] = {
                            name      = name,
                            rank      = rankName or "Unknown",
                            rankIndex = rankIndex or 0,
                            days      = totalDays,
                            threshold = threshold,
                            unknown   = unknown,
                        }
                    end
                end
            end
        end
    end

    MTR.db.inactivitySeenLog = seenLog
    table.sort(inactive, function(a, b) return a.days > b.days end)
    return inactive
end

-- ============================================================================
-- DEBUG DUMP
-- ============================================================================
function MTR.InactDebugDump()
    if not IsInGuild() then MTR.MP("Not in a guild.") return end
    SetGuildRosterShowOffline(true)
    GuildRoster()
    MTR.MP("Scanning... results in 5 seconds.")
    MTR.After(5, function()
        local inactive = MTR.InactScan()
        if #inactive == 0 then
            MTR.MP("Scan complete - no members meet the inactivity threshold.")
            MTR.MP("(Safe ranks, whitelisted players, and DA BACKUP alts are excluded.)")
            return
        end
        MTR.MP("Scan complete - " .. #inactive .. " members flagged as inactive:")
        for _, entry in ipairs(inactive) do
            local daysStr = entry.unknown and "unseen by addon" or MTR.FormatDays(entry.days)
            print(string.format("  |cffffff00%s|r [%s] - %s inactive (threshold: %s)",
                entry.name, entry.rank, daysStr, MTR.FormatDays(entry.threshold)))
        end
        MTR.MP("Use /mek config > Inactive tab to whitelist or kick.")
    end)
end

-- ============================================================================
-- KICK POPUP  (GM only)
-- ============================================================================
local kickPopup = nil

function MTR.InactShowKickPopup(inactiveList)
    if not MTR.isGM then MTR.MPE("Only the Guild Master can use auto-kick.") return end
    if #inactiveList == 0 then MTR.MP("No inactive members found.") return end

    if kickPopup then kickPopup:Hide() end
    kickPopup = CreateFrame("Frame", "MekTownKickPopup", UIParent)
    kickPopup:SetSize(460, 480)
    kickPopup:SetPoint("CENTER")
    kickPopup:SetBackdrop({
        bgFile   = "",
        edgeFile = "Interface\\\\DialogFrame\\\\UI-DialogBox-Border",
        tile=false, tileSize=0, edgeSize=32,
        insets={left=8,right=8,top=8,bottom=8},
    })
    kickPopup:SetBackdropColor(0,0,0,0)
    do local _bt=kickPopup:CreateTexture(nil,"BACKGROUND")
    _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(kickPopup) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
    kickPopup:SetFrameStrata("DIALOG")
    kickPopup:EnableMouse(true)
    kickPopup:SetMovable(true)
    kickPopup:RegisterForDrag("LeftButton")
    kickPopup:SetScript("OnDragStart", kickPopup.StartMoving)
    kickPopup:SetScript("OnDragStop",  kickPopup.StopMovingOrSizing)

    local title = kickPopup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", kickPopup, "TOP", 0, -14)
    title:SetText("|cffff4444Inactive Members - " .. #inactiveList .. " Found|r")

    local sub = kickPopup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("|cffaaaaaa GM authorisation required to kick.|r")

    local sf = CreateFrame("ScrollFrame", nil, kickPopup, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     kickPopup, "TOPLEFT",    12, -52)
    sf:SetPoint("BOTTOMRIGHT", kickPopup, "BOTTOMRIGHT", -28, 52)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(410, math.max(300, #inactiveList * 22))
    sf:SetScrollChild(content)

    for i, entry in ipairs(inactiveList) do
        local row = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -(i-1)*22)
        local col = (entry.days >= (entry.threshold * 2)) and "|cffff4444" or "|cffffaa00"
        row:SetWidth(420)
        row:SetWordWrap(false)
        row:SetText(string.format("%s%s|r  [%s]  %s inactive",
            col, MTR.Trunc(entry.name,22), MTR.Trunc(entry.rank,18), MTR.FormatDays(entry.days)))
    end

    -- Kick All button
    local kaBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    kaBtn:SetSize(120, 26)
    kaBtn:SetPoint("BOTTOMLEFT", kickPopup, "BOTTOMLEFT", 12, 14)
    kaBtn:SetText("|cffff4444Kick All|r")
    kaBtn:SetScript("OnClick", function()
        StaticPopupDialogs["MEKTOWN_KICK_ALL"] = {
            text = "Kick ALL " .. #inactiveList .. " inactive members?\nThis cannot be undone.",
            button1 = "Yes, kick all", button2 = "Cancel",
            OnAccept = function()
                for _, entry in ipairs(inactiveList) do
                    GuildUninvite(entry.name)
                    MTR.KickBroadcast(entry.name, entry.rank, entry.days, MTR.playerName)
                end
                MTR.MP("Kicked " .. #inactiveList .. " inactive members.")
                kickPopup:Hide()
            end,
            timeout=0, whileDead=true, hideOnEscape=true,
        }
        StaticPopup_Show("MEKTOWN_KICK_ALL")
    end)

    -- Review One by One button
    local reviewIdx = 1
    local rvBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    rvBtn:SetSize(140, 26)
    rvBtn:SetPoint("BOTTOM", kickPopup, "BOTTOM", 0, 14)
    rvBtn:SetText("Review One by One")
    rvBtn:SetScript("OnClick", function()
        local function ReviewNext()
            if reviewIdx > #inactiveList then MTR.MP("Review complete.") kickPopup:Hide() return end
            local entry = inactiveList[reviewIdx]
            StaticPopupDialogs["MEKTOWN_KICK_ONE"] = {
                text = string.format("Kick %s?\nRank: %s\nInactive: %s\n(%d/%d)", entry.name, entry.rank, MTR.FormatDays(entry.days), reviewIdx, #inactiveList),
                button1 = "Kick", button2 = "Skip", button3 = "Stop",
                OnAccept = function()
                    GuildUninvite(entry.name)
                    MTR.KickBroadcast(entry.name, entry.rank, entry.days, MTR.playerName)
                    MTR.MP("Kicked " .. entry.name)
                    reviewIdx = reviewIdx + 1
                    ReviewNext()
                end,
                OnCancel = function() reviewIdx = reviewIdx + 1 ReviewNext() end,
                OnAlt    = function() kickPopup:Hide() end,
                timeout=0, whileDead=true, hideOnEscape=false,
            }
            StaticPopup_Show("MEKTOWN_KICK_ONE")
        end
        ReviewNext()
    end)

    -- Dismiss button
    local dimBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    dimBtn:SetSize(100, 26)
    dimBtn:SetPoint("BOTTOMRIGHT", kickPopup, "BOTTOMRIGHT", -12, 14)
    dimBtn:SetText("Dismiss")
    dimBtn:SetScript("OnClick", function() kickPopup:Hide() end)

    kickPopup:Show()
end

-- ============================================================================
-- RUN SCAN (view or kick mode)
-- The correct API on 3.3.5 is SetGuildRosterShowOffline (no "Members" suffix).
-- SetGuildRosterShowOffline fires GUILD_ROSTER_UPDATE if the flag changed,
-- then we call GuildRoster() and wait for the data to arrive before scanning.
-- ============================================================================
function MTR.InactRunScan(kickMode)
    MTR.MP("|cffaaaaaaRefreshing guild roster... please wait 5 seconds.|r")

    -- Set the correct flag - this is the actual 3.3.5 API function name
    SetGuildRosterShowOffline(true)
    GuildRoster()

    MTR.After(5, function()
        local inactive = MTR.InactScan()
        if kickMode then
            MTR.InactShowKickPopup(inactive)
        else
            if #inactive == 0 then MTR.MP("No inactive members found.") return end
            MTR.MP("|cffff9900" .. #inactive .. " inactive members:|r")
            for _, entry in ipairs(inactive) do
                local daysStr = entry.unknown and "|cffaaaaaunseen by addon|r" or MTR.FormatDays(entry.days)
                MTR.MP(string.format("  |cffffff00%s|r [%s] - %s offline", entry.name, entry.rank, daysStr))
            end
            if not MTR.isGM then MTR.MP("|cffaaaaaa(Only the GM can kick)|r") end
        end
    end)
end
