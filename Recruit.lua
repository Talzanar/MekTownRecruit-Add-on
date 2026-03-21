-- ============================================================================
-- Recruit.lua  v8.0
-- Recruitment scanner, guild auto-invite, auto-responder,
-- recruit whisper popup and test popup
-- ============================================================================
local MTR = MekTownRecruit

-- ============================================================================
-- RECRUIT HISTORY SYNC
-- When any officer whispers a recruit, the record is broadcast to the guild
-- via addon messaging. All online officers with the addon merge it into their
-- shared log, giving a single unified history of every player contacted.
--
-- Message format: "RECRUIT_INV:recruitName|sentBy|YYYY-MM-DD HH:MM"
-- ============================================================================
local RH_PREFIX = "MekTownRH"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(RH_PREFIX) end

local function RHSanitize(s)
    s = tostring(s or "")
    s = s:gsub("[|,;]", " ")
    s = s:gsub("[%c]", " ")
    return s
end

local function RHState()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return { revision = 0, hash = "0", lastSyncAt = 0 } end
    gs.syncState = gs.syncState or {}
    gs.syncState.recruit = gs.syncState.recruit or { revision = 0, hash = "0", lastSyncAt = 0, lastAckByPeer = {} }
    return gs.syncState.recruit
end

local function RHMakeId(recruit, sentBy, timestamp)
    local seed = table.concat({ tostring(recruit or ""), tostring(sentBy or ""), tostring(timestamp or ""), tostring(MTR.playerName or "?") }, "|")
    return (MTR.Hash and MTR.Hash(seed)) or seed
end

local function RHRehash()
    local hist = (MTR.GetGuildStore and MTR.GetGuildStore(true).recruitHistory) or MTR.db.recruitHistory or {}
    local parts = {}
    for i, e in ipairs(hist) do
        parts[i] = table.concat({ RHSanitize(e.recruit), RHSanitize(e.sentBy), RHSanitize(e.time), RHSanitize(e.id or "") }, "|")
    end
    local st = RHState()
    st.hash = (MTR.Hash and MTR.Hash(table.concat(parts, ";"))) or tostring(#parts)
    st.revision = tonumber(st.revision or 0) + 1
    st.lastSyncAt = time()
    return st
end

local function RHBuildChunks()
    local hist = (MTR.GetGuildStore and MTR.GetGuildStore(true).recruitHistory) or MTR.db.recruitHistory or {}
    local chunks, chunk = {}, ""
    for _, e in ipairs(hist) do
        local token = table.concat({ RHSanitize(e.recruit), RHSanitize(e.sentBy), RHSanitize(e.time), RHSanitize(e.id or "") }, "|")
        if #chunk + #token + 1 > 200 then
            if chunk ~= "" then chunks[#chunks + 1] = chunk end
            chunk = token
        else
            chunk = (chunk == "" and token) or (chunk .. ";" .. token)
        end
    end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    return chunks, #hist
end

local function RHSend(msg)
    if not IsInGuild() then return false end
    if MTR.SendGuildScoped then return MTR.SendGuildScoped(RH_PREFIX, msg) end
    SendAddonMessage(RH_PREFIX, msg, "GUILD")
    return true
end

local function RHBroadcast(recruit, sentBy, timestamp)
    local rid = RHMakeId(recruit, sentBy, timestamp)
    local msg = "RECRUIT_INV:" .. recruit .. "|" .. sentBy .. "|" .. timestamp .. "|" .. rid
    -- Send to GUILD so all online officers receive it regardless of raid status
    RHSend(msg)
end

local function RHMerge(recruit, sentBy, timestamp, rid)
    if not MTR.db then return end
    -- Avoid duplicates: skip if exact same recruit+sentBy+time already stored
    local hist = (MTR.GetGuildStore and MTR.GetGuildStore(true).recruitHistory) or MTR.db.recruitHistory
    rid = rid and tostring(rid) or ""
    for _, e in ipairs(hist) do
        if rid ~= "" and e.id and e.id == rid then
            return
        end
        if e.recruit == recruit and e.sentBy == sentBy and e.time == timestamp then
            return
        end
    end
    table.insert(hist, { recruit=recruit, sentBy=sentBy, time=timestamp, id=(rid ~= "" and rid or RHMakeId(recruit, sentBy, timestamp)) })
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("recruit", "contact", table.concat({recruit or "", sentBy or "", timestamp or ""}, "|")) end
    -- Keep newest at end; cap at 500 entries
    if #hist > 500 then tremove(hist, 1) end
    RHRehash()
end

local function RHSendSnapshot(reason)
    if not (MTR.isOfficer or MTR.isGM) then return false end
    local st = RHState()
    local chunks, count = RHBuildChunks()
    local payloadRaw = table.concat(chunks, ";")
    local payloadHash = (MTR.Hash and MTR.Hash(payloadRaw)) or tostring(#payloadRaw)
    st.hash = payloadHash
    st.lastBroadcastAt = time()
    st.lastBroadcastReason = reason or "sync"
    RHSend(string.format("RH:MET:%s:%s:%d", tostring(st.revision or 0), tostring(payloadHash), count or 0))
    for _, c in ipairs(chunks) do RHSend("RH:D:" .. c) end
    if #chunks == 0 then RHSend("RH:D:") end
    RHSend("RH:END:" .. RHSanitize(reason or "sync"))
    return true
end

local rhFrame = CreateFrame("Frame")
rhFrame:RegisterEvent("CHAT_MSG_ADDON")
local rhRecv = nil
rhFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= RH_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end
    local unpacked, senderName = (MTR.UnpackGuildScoped and MTR.UnpackGuildScoped(message, sender, false)) or message, ((sender or ""):match("^([^%-]+)") or sender or "")
    if not unpacked then return end
    -- Ignore our own broadcast (we already inserted locally).
    -- sender arrives as "Name-Realm" on Ascension; strip realm before comparing.
    if senderName == MTR.playerName then return end

    if unpacked:sub(1, 7) == "RH:REQ:" then
        local _, knownHash = unpacked:match("^RH:REQ:([^:]*):?(.*)$")
        if knownHash and knownHash ~= "" then
            local st = RHState()
            if tostring(knownHash) == tostring(st.hash or "0") then return end
        end
        if MTR.isOfficer or MTR.isGM then RHSendSnapshot("peer-request") end
        return
    elseif unpacked:sub(1, 7) == "RH:MET:" then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local rev, hash = unpacked:match("^RH:MET:([^:]+):([^:]+):")
        
        -- Auto-clear conflict if header hash matches local hash
        if hash then
            local st = RHState()
            if tostring(hash) == tostring(st.hash or "0") then
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
                -- Adopt higher revision if hashes match
                if rev and tonumber(rev) > tonumber(st.revision or 0) then
                    st.revision = tonumber(rev)
                end
            end
        end

        rhRecv = { rev = tonumber(rev) or 0, hash = hash or "0", chunks = {}, from = senderName }
        return
    elseif unpacked:sub(1, 5) == "RH:D:" and rhRecv then
        rhRecv.chunks[#rhRecv.chunks + 1] = unpacked:sub(6)
        return
    elseif unpacked:sub(1, 7) == "RH:END:" and rhRecv then
        local st = RHState()
        if tonumber(rhRecv.rev or 0) < tonumber(st.revision or 0) then rhRecv = nil return end
        local merged = 0
        for _, chunk in ipairs(rhRecv.chunks) do
            for token in tostring(chunk or ""):gmatch("[^;]+") do
                local recruit, sentBy, timestamp = token:match("^([^|]+)|([^|]+)|(.+)$")
                local rid
                if not recruit then
                    recruit, sentBy, timestamp, rid = token:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
                else
                    local r2, s2, t2, id2 = token:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
                    if r2 and s2 and t2 and id2 then recruit, sentBy, timestamp, rid = r2, s2, t2, id2 end
                end
                if recruit and sentBy and timestamp then
                    local before = #(((MTR.GetGuildStore and MTR.GetGuildStore(true).recruitHistory) or MTR.db.recruitHistory) or {})
                    RHMerge(recruit, sentBy, timestamp, rid)
                    local after = #(((MTR.GetGuildStore and MTR.GetGuildStore(true).recruitHistory) or MTR.db.recruitHistory) or {})
                    if after > before then merged = merged + 1 end
                end
            end
        end
        local localChunks = table.concat(rhRecv.chunks, ";")
        local localHash = (MTR.Hash and MTR.Hash(localChunks)) or tostring(#localChunks)
        if localHash ~= tostring(rhRecv.hash or "") and #rhRecv.chunks > 0 then
            local stc = RHState()
            stc.lastConflictAt = time()
            stc.lastConflictFrom = tostring(rhRecv.from or "?")
            stc.lastConflictReason = "hash-mismatch"
            MTR.MPE("[Recruit Sync] Hash mismatch from " .. tostring(rhRecv.from or "?") .. "; keeping local state.")
        else
            local st2 = RHState()
            st2.revision = math.max(tonumber(st2.revision or 0), tonumber(rhRecv.rev or 0))
            st2.hash = tostring(rhRecv.hash or st2.hash or "0")
            st2.lastSyncAt = time()
            RHSend(string.format("RH:ACK:%s:%s:%d", RHSanitize(MTR.playerName or "?"), tostring(st2.hash or "0"), tonumber(st2.revision or 0)))
        end
        rhRecv = nil
        return
    elseif unpacked:sub(1, 7) == "RH:ACK:" then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local peer, hash, rev = unpacked:match("^RH:ACK:([^:]+):([^:]+):([^:]+)$")
        local st = RHState()
        if tostring(hash or "") == tostring(st.hash or "0") then
            local r = tonumber(rev) or 0
            if r > tonumber(st.revision or 0) then st.revision = r end
            st.lastAckByPeer = st.lastAckByPeer or {}
            st.lastAckByPeer[peer or senderName or "?"] = { revision = r, at = time() }
        end
        return
    end

    if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
    local recruit, sentBy, timestamp, rid = unpacked:match("^RECRUIT_INV:([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not recruit then recruit, sentBy, timestamp = unpacked:match("^RECRUIT_INV:([^|]+)|([^|]+)|(.+)$") end
    if recruit and sentBy and timestamp then
        RHMerge(recruit, sentBy, timestamp, rid)
        -- Suppress further popups on our client for this recruit now that
        -- another officer has already acted. Uses ignoreDuration so the
        -- recruit won't trigger a new popup on any officer's screen.
        if MTR.recent then
            MTR.recent[recruit] = GetTime()
        end
    end
end)

local rhInit = CreateFrame("Frame")
rhInit:RegisterEvent("PLAYER_LOGIN")
rhInit:SetScript("OnEvent", function()
    MTR.After(12, function()
        if not IsInGuild() then return end
        local st = RHState()
        RHSend("RH:REQ:" .. RHSanitize(MTR.playerName or "?") .. ":" .. tostring(st.hash or "0"))
    end)
end)

-- ============================================================================
-- HELPERS
-- ============================================================================
local function MatchKeywords(msg, keywords)
    for _, kw in ipairs(keywords) do
        if msg:find(kw, 1, true) then return true end
    end
    return false
end

local function IsRecruitmentAd(msg)
    if not MTR.db.ignoreAds then return false end
    local adPats = MTR.db.adPatterns or {}
    for _, pat in ipairs(adPats) do
        if msg:find(pat, 1, true) then return true end
    end
    return false
end

-- ============================================================================
-- RECRUIT POPUP
-- ============================================================================
-- ============================================================================
-- CLASS COLOUR HELPER
-- ============================================================================
local CLASS_COLOR_HEX = {
    WARRIOR="ffc79c6e", PALADIN="fff58cba", HUNTER="ffabd473",
    ROGUE="fffff569",   PRIEST="ffffffff", DEATHKNIGHT="ffc41f3b",
    SHAMAN="ff0070de",  MAGE="ff69ccf0",  WARLOCK="ff9482c9",
    DRUID="ffff7d0a",
}
local function ClassHex(class)
    return "|c" .. (CLASS_COLOR_HEX[(class or ""):upper()] or "ffffffff")
end

-- ============================================================================
-- RECRUIT POPUP  (rich info panel matching best addon standards)
-- ============================================================================
function MTR.ShowRecruitPopup(sender, message)
    MTR.dprint("Popup for", sender)

    -- Try to gather target info: if sender is in range and targetable, inspect them
    local level, class, race = "?", "?", "?"
    -- SetTarget is not available but we can check if the player is in our party/raid
    for i = 1, GetNumRaidMembers() do
        local n,_,_,lv,_,c,_,_,_,r = GetRaidRosterInfo(i)
        if n == sender then level=lv or "?" class=c or "?" race=r or "?" break end
    end
    if level == "?" then
        for i = 1, GetNumPartyMembers() do
            local n = UnitName("party"..i)
            if n == sender then
                level = UnitLevel("party"..i) or "?"
                _,class = UnitClass("party"..i)
                _,race  = UnitRace("party"..i)
                class = class or "?"
                race  = race  or "?"
                break
            end
        end
    end

    -- Build info line
    local classCol = ClassHex(class)
    local infoLine
    if level ~= "?" then
        infoLine = string.format("Level %s %s%s|r %s", tostring(level), classCol, class, race)
    else
        infoLine = "|cffaaaaaa(not in your party/raid — inspect manually)|r"
    end

    -- Check recruit history: find the most recent contact entry for this person
    local alreadyContacted = nil
    if MTR.db and MTR.db.recruitHistory then
        for _, e in ipairs(MTR.db.recruitHistory) do
            if e.recruit == sender then
                alreadyContacted = e  -- last match = most recent (list grows at end)
            end
        end
    end

    -- Check if this sender is a known alt in the guild tree
    local knownMainName = MTR.GTGetMain and MTR.GTGetMain(sender)
    local isKnownAlt = knownMainName and knownMainName ~= sender

    local W = math.max(MTR.db.popupWidth  or 460, 460)
    local extraH = (alreadyContacted and 30 or 0) + (isKnownAlt and 24 or 0)
    local H = math.max(MTR.db.popupHeight or 260, 260 + extraH)

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetBackdrop({
        bgFile   = "",
        edgeFile = "Interface\\\\DialogFrame\\\\UI-DialogBox-Border",
        tile=false, tileSize=0, edgeSize=32,
        insets={left=8,right=8,top=8,bottom=8},
    })
    f:SetBackdropColor(0,0,0,0)
    do local _bt=f:CreateTexture(nil,"BACKGROUND")
    _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(f) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true) f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)

    -- Close button (top-right)
    local xBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    xBtn:SetScript("OnClick", function() f:Hide() end)

    -- Title bar (standard MekTown style)
    local titleBar=f:CreateTexture(nil,"OVERLAY")
    titleBar:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    titleBar:SetTexCoord(0,1,0.2,0.8) titleBar:SetVertexColor(0.55,0.03,0.03,1.0) titleBar:SetHeight(26)
    titleBar:SetPoint("TOPLEFT",f,"TOPLEFT",9,-2) titleBar:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-2)
    local titleEdge=f:CreateTexture(nil,"OVERLAY")
    titleEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
    titleEdge:SetVertexColor(0.80,0.12,0.02,1.0) titleEdge:SetHeight(2)
    titleEdge:SetPoint("TOPLEFT",f,"TOPLEFT",9,-26) titleEdge:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-26)

    -- Guild icon / indicator
    local tag = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -7)
    tag:SetText("|cffff2020MekTown|r |cffd4af37Recruit|r")

    -- Player name (large, class-coloured)
    local nameFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameFS:SetPoint("TOP", f, "TOP", 0, -12)
    nameFS:SetText(classCol .. sender .. "|r")

    -- Separator
    local sep1 = f:CreateTexture(nil, "ARTWORK")
    sep1:SetColorTexture(0.4, 0.35, 0.1, 0.6) sep1:SetHeight(1)
    sep1:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -32)
    sep1:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -32)

    -- Character info line (level / class / race)
    local infoFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoFS:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -38)
    infoFS:SetWidth(W-20) infoFS:SetWordWrap(false)
    infoFS:SetText(infoLine)

    -- "Their message" label
    local msgLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    msgLbl:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -56)
    msgLbl:SetText("|cffaaaaaa Their message:|r")

    -- Message body (word-wrapped, colour-coded)
    local msgFS = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    msgFS:SetPoint("TOPLEFT",  f, "TOPLEFT",  10, -70)
    msgFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -70)
    msgFS:SetWordWrap(true) msgFS:SetJustifyH("LEFT")
    msgFS:SetText("|cffffff88" .. message:sub(1, 220) .. "|r")

    -- Already-contacted warning banner (shown only if this recruit has a history entry)
    if alreadyContacted then
        local warnBg = f:CreateTexture(nil, "ARTWORK")
        warnBg:SetColorTexture(0.55, 0.10, 0.05, 0.75)
        warnBg:SetHeight(20)
        warnBg:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  1, 68)
        warnBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 68)

        local warnFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        warnFS:SetPoint("BOTTOM", f, "BOTTOM", 0, 74)
        warnFS:SetText(
            "|cffffcc00\226\154\160 Already contacted|r  " ..
            "|cffff6666" .. alreadyContacted.sentBy .. "|r" ..
            "|cffaaaaaa  @  |r" ..
            "|cffffff88" .. alreadyContacted.time .. "|r"
        )
    end

    -- Alt hint banner (shown if sender is a known alt)
    if isKnownAlt then
        local altBg = f:CreateTexture(nil, "ARTWORK")
        altBg:SetColorTexture(0.05, 0.30, 0.10, 0.75)
        altBg:SetHeight(20)
        altBg:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  1, alreadyContacted and 90 or 68)
        altBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, alreadyContacted and 90 or 68)
        local altFS = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        altFS:SetPoint("BOTTOM", f, "BOTTOM", 0, alreadyContacted and 96 or 74)
        altFS:SetText(
            "|cff00ff44>> Known alt|r  " ..
            "|cffffff88" .. sender .. "|r" ..
            "|cffaaaaaa  is an alt of  |r" ..
            "|cffd4af37" .. knownMainName .. "|r"
        )
    end

    -- Separator above buttons
    local sep2 = f:CreateTexture(nil, "ARTWORK")
    sep2:SetColorTexture(0.3, 0.3, 0.4, 0.4) sep2:SetHeight(1)
    sep2:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  8, 46)
    sep2:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 46)

    -- Buttons row (bottom)
    -- Whisper: sends random template
    local wBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    wBtn:SetSize(120, 28) wBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 10)
    wBtn:SetText("|cff00ff00Whisper|r")
    wBtn:SetScript("OnClick", function()
        local tmpls = MTR.db.whisperTemplates
        if not tmpls or #tmpls == 0 then MTR.MPE("No whisper templates set!") return end
        local tpl = tmpls[math.random(#tmpls)]
        local ctx = message:lower():match("(%a[%a%s]-guild)") or "looking for a guild"
        local w = tpl:gsub("{name}", sender):gsub("{context}", ctx)
        MTR.SendChatSafe(w, "WHISPER", nil, sender)
        local ts = date("%Y-%m-%d %H:%M")
        RHMerge(sender, MTR.playerName or "Unknown", ts)
        RHBroadcast(sender, MTR.playerName or "Unknown", ts)
        f:Hide()
        MTR.MP("Whispered " .. sender)
    end)

    -- Invite: invites the player to the guild (requires officer rank)
    local invBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    invBtn:SetSize(110, 28) invBtn:SetPoint("LEFT", wBtn, "RIGHT", 8, 0)
    invBtn:SetText("Guild Invite")
    invBtn:SetScript("OnClick", function()
        if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
        GuildInvite(sender)
        local ts = date("%Y-%m-%d %H:%M")
        RHMerge(sender, MTR.playerName or "Unknown", ts)
        RHBroadcast(sender, MTR.playerName or "Unknown", ts)
        f:Hide()
        MTR.MP("Guild invite sent to " .. sender)
    end)

    -- Open chat: open a whisper box to the player
    local chatBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    chatBtn:SetSize(100, 28) chatBtn:SetPoint("LEFT", invBtn, "RIGHT", 8, 0)
    chatBtn:SetText("Open Chat")
    chatBtn:SetScript("OnClick", function()
        ChatFrame_SendTell(sender)
        f:Hide()
    end)

    -- Ignore: suppress this sender for the configured duration
    local ignBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    ignBtn:SetSize(90, 28) ignBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 10)
    ignBtn:SetText("|cffff4444Ignore|r")
    ignBtn:SetScript("OnClick", function()
        MTR.ignoreList[sender] = GetTime()
        f:Hide()
    end)

    f:Show()
    if MTR.db.soundAlert then PlaySound(8960) end
end

-- (Test popup removed — /mek test now triggers a real example popup)
function MTR.ShowTestPopup()
    MTR.ShowRecruitPopup("Testplayer",
        "Hey anyone know a good guild? LF raiding guild fresh 70 havnt played since vanilla lol")
end

-- ============================================================================
-- GROUP-RADAR MESSAGE EXCLUSION
-- Keep group-finding traffic completely separate from recruit detection.
-- ============================================================================
local function LooksLikeGroupSearch(lower)
    if not lower or lower == "" then return false end
    if lower:find("lfm", 1, true) or lower:find("lfg", 1, true) then return true end
    if lower:find("looking for", 1, true) then
        if lower:find("looking for guild", 1, true) or lower:find("looking for a guild", 1, true) or lower:find("looking for raiding guild", 1, true) or lower:find("looking for social guild", 1, true) then
            return false
        end
        return true
    end
    if lower:find("need tank", 1, true) or lower:find("need healer", 1, true) or lower:find("need heal", 1, true) or lower:find("need dps", 1, true) then return true end
    if lower:find("looking for more", 1, true) or lower:find("looking for tank", 1, true) or lower:find("looking for healer", 1, true) or lower:find("looking for heal", 1, true) or lower:find("looking for dps", 1, true) then return true end
    if lower:find("group radar", 1, true) or lower:find("mythic+", 1, true) or lower:find("m+", 1, true) then return true end
    return false
end

-- ============================================================================
-- SCANNER LISTENER
-- ============================================================================
local scanFrame = CreateFrame("Frame")
do
    local events = {
        "CHAT_MSG_CHANNEL","CHAT_MSG_SAY","CHAT_MSG_YELL",
        "CHAT_MSG_PARTY","CHAT_MSG_PARTY_LEADER",
        "CHAT_MSG_WHISPER","CHAT_MSG_GUILD","CHAT_MSG_OFFICER",
        "CHAT_MSG_RAID","CHAT_MSG_RAID_LEADER",
    }
    for _, e in ipairs(events) do scanFrame:RegisterEvent(e) end
end
scanFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not MTR.initialized or not MTR.db then return end
    if not MTR.db.enabled then return end
    if not MTR.db.scanChannels[event] then return end

    -- Skip messages from self
    if sender == MTR.playerName then return end

    -- Skip guild members
    if IsInGuild() and GetGuildInfo("player") then
        for i = 1, GetNumGuildMembers() do
            local n = GetGuildRosterInfo(i)
            if n == sender then return end
        end
    end

    -- Skip blacklisted senders
    if MTR.db.blacklist[sender] then return end

    -- Skip senders on ignore timer
    if MTR.ignoreList[sender] and (GetTime() - MTR.ignoreList[sender]) < MTR.db.ignoreDuration then return end

    -- Skip recently contacted senders
    if MTR.recent[sender] and (GetTime() - MTR.recent[sender]) < MTR.db.ignoreDuration then return end

    local lower = message:lower()

    -- Skip recruitment ads from guilds
    if IsRecruitmentAd(lower) then
        MTR.dprint("Skipping ad from", sender)
        return
    end

    -- Do not hijack LFG/LFM traffic. Those belong to Group Radar, not Recruit.
    if LooksLikeGroupSearch(lower) then
        MTR.dprint("Skipping group-search style message from", sender)
        return
    end

    -- Additional required words filter
    if MTR.db.additionalRequired ~= "" then
        local found = false
        for word in MTR.db.additionalRequired:gmatch("[^,]+") do
            word = word:match("^%s*(.-)%s*$"):lower()
            if word ~= "" and lower:find(word, 1, true) then found = true break end
        end
        if not found then return end
    end

    -- Require 'guild' in message if setting enabled
    if MTR.db.requireGuildWord and not lower:find("guild", 1, true) then
        local matched = false
        for _, kw in ipairs(MTR.db.keywords) do
            if not kw:find("guild", 1, true) and lower:find(kw, 1, true) then matched = true break end
        end
        if not matched then return end
    end

    -- Keyword match
    if not MatchKeywords(lower, MTR.db.keywords) then return end

    -- Passed all filters
    MTR.recent[sender] = GetTime()
    MTR.dprint("Match:", sender, event)
    MTR.ShowRecruitPopup(sender, message)

    -- Log application
    table.insert(MTR.db.applicationLog, { player=sender, message=message, time=date("%Y-%m-%d %H:%M:%S"), event=event })
    if #MTR.db.applicationLog > 100 then tremove(MTR.db.applicationLog, 1) end
end)

-- ============================================================================
-- GUILD AUTO-INVITE
-- ============================================================================
local function IsGuildInviteEnabled()
    return MTR.GetGuildInviteEnabled and MTR.GetGuildInviteEnabled() == true
end

local function IsGuildInviteAnnounceEnabled()
    return MTR.GetGuildInviteAnnounceEnabled and MTR.GetGuildInviteAnnounceEnabled() == true
end

local inviteFrame = CreateFrame("Frame")
inviteFrame:RegisterEvent("CHAT_MSG_GUILD")
inviteFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not MTR.initialized or not MTR.db then return end
    if IsGuildInviteEnabled() ~= true then return end
    if type(sender) ~= "string" or sender == "" or sender == MTR.playerName then return end
    if type(message) ~= "string" or message == "" then return end
    if not MTR.CanInvite() then return end

    local cooldown = tonumber(MTR.db.inviteCooldown) or 60
    if cooldown < 0 then cooldown = 0 end
    if MTR.recentInvites[sender] and (GetTime() - MTR.recentInvites[sender]) < cooldown then return end

    local lower = string.lower(message)

    -- Only proceed if message matches configured invite keywords.
    -- No bypass for short messages — the bypass was causing invites to fire
    -- for any number or "rd"/"ry" typed in guild chat regardless of settings.
    if not MatchKeywords(lower, MTR.db.inviteKeywords) then return end

    MTR.recentInvites[sender] = GetTime()
    InviteUnit(sender)
    if IsGuildInviteAnnounceEnabled() == true then
        local announceMsg = sender .. " has been invited to the raid/party."
        MTR.After(0.2, function()
            if IsGuildInviteAnnounceEnabled() == true then
                MTR.SendChatSafe(announceMsg, "GUILD")
            end
        end)
    end
    MTR.dprint("Auto-invited:", sender, "enabled=", tostring(MTR.db and MTR.db.enableGuildInvites), "announce=", tostring(MTR.db and MTR.db.inviteAnnounce))
end)


-- ============================================================================
-- GUILD JOIN WELCOME WHISPER
-- ============================================================================
local guildWelcomeRecent = {}

local function ExtractGuildJoinName(message)
    if type(message) ~= "string" or message == "" then return nil end

    local patterns = {
        "^(.+) has joined the guild%.$",
        "^(.+) has joined the guild$",
        "^(.+) joins the guild%.$",
        "^(.+) joins the guild$",
    }

    local lower = string.lower(message)
    if lower:find("joined the party", 1, true) or lower:find("joins the party", 1, true)
        or lower:find("joined the raid", 1, true) or lower:find("joins the raid", 1, true)
        or lower:find("joined your group", 1, true) or lower:find("joins your group", 1, true) then
        return nil
    end

    for _, pat in ipairs(patterns) do
        local name = message:match(pat)
        if name and name ~= "" then
            return name
        end
    end
    return nil
end

local function SendGuildJoinWelcome(name)
    if not MTR.initialized or not MTR.db then return end
    if not (MTR.isOfficer or MTR.isGM) then return end
    if not name or name == "" then return end
    if name == MTR.playerName then return end

    local msg = MTR.db.inviteWelcomeMsg
    if type(msg) ~= "string" then return end
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then return end

    local key = string.lower(name)
    local now = GetTime() or 0
    if guildWelcomeRecent[key] and (now - guildWelcomeRecent[key]) < 10 then return end
    guildWelcomeRecent[key] = now

    MTR.After(2, function()
        MTR.SendChatSafe(msg:gsub("{name}", name), "WHISPER", nil, name)
    end)
end

local guildWelcomeFrame = CreateFrame("Frame")
guildWelcomeFrame:RegisterEvent("CHAT_MSG_SYSTEM")
guildWelcomeFrame:SetScript("OnEvent", function(self, event, message)
    local name = ExtractGuildJoinName(message)
    if name then
        SendGuildJoinWelcome(name)
    end
end)

-- ============================================================================
-- AUTO-RESPONDER
-- ============================================================================
local autoRespFrame = CreateFrame("Frame")
autoRespFrame:RegisterEvent("CHAT_MSG_WHISPER")
autoRespFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not MTR.initialized or not MTR.db then return end
    if not MTR.db.autoResponderEnabled then return end
    if sender == MTR.playerName then return end
    local lower = message:lower()
    for _, rule in ipairs(MTR.db.autoResponses or {}) do
        if rule.trigger and lower:find(rule.trigger:lower(), 1, true) then
            MTR.SendChatSafe(rule.response:gsub("{name}", sender), "WHISPER", nil, sender)
            MTR.dprint("Auto-responded to", sender, "trigger:", rule.trigger)
            break
        end
    end
end)

-- Track seen times for inactivity log
local seenFrame = CreateFrame("Frame")
seenFrame:RegisterEvent("CHAT_MSG_GUILD")
seenFrame:RegisterEvent("CHAT_MSG_OFFICER")
seenFrame:SetScript("OnEvent", function(self, event, message, sender)
    if not MTR.initialized or not MTR.db then return end
    if sender and sender ~= "" then
        MTR.db.inactivitySeenLog[sender] = time()
    end
end)
