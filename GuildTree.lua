-- ============================================================================
-- GuildTree.lua  v1.1
-- Guild family tree: tracks mains and alts for every guild member.
-- Officer / GM only.
--
-- familyTree table layout:
--   MTR.db.familyTree = {
--     ["Waaghskull"] = { isMain=true, alts={"Bankasaur","Kalanos"} },
--     ["Bankasaur"]  = { isMain=false, main="Waaghskull" },
--   }
--
-- Sync message format:
--   "GT:SET:charName|mainName"   link char as alt of main
--   "GT:MAIN:charName"           designate as standalone main
--   "GT:DEL:charName"            remove entry
--   "GT:REQ"                     request full sync from peers
--   "GT:FULL:charName|mainName;charName2|mainName2;..."
-- ============================================================================

local MTR = MekTownRecruit
local GT_PREFIX = "MekTownGT"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(GT_PREFIX) end

-- WoW 3.3.5 GetGuildRosterInfo return order:
-- 1=name 2=rankName 3=rankIndex 4=level 5=classDisplayName 6=zone
-- 7=publicNote 8=officerNote 9=online 10=status 11=classFileName 12=achievementPoints

-- ============================================================================
-- STORAGE
-- ============================================================================
local function FT()
    if not MTR.db then return nil end
    if not MTR.db.familyTree then MTR.db.familyTree = {} end
    return MTR.db.familyTree
end

local function GetAlts(mainName)
    local ft = FT()
    if not ft then return {} end
    local alts = {}
    for name, entry in pairs(ft) do
        if not entry.isMain and entry.main == mainName then
            alts[#alts + 1] = name
        end
    end
    table.sort(alts)
    return alts
end

-- ============================================================================
-- SYNC
-- ============================================================================
local function GTBroadcast(msg)
    if IsInGuild() then SendAddonMessage(GT_PREFIX, msg, "GUILD") end
end

local function GTApplySet(charName, mainName)
    local ft = FT()
    if not ft then return end
    if not ft[mainName] then
        ft[mainName] = { isMain = true, alts = {} }
    end
    -- Remove from any previous main
    local old = ft[charName]
    if old and not old.isMain and old.main and ft[old.main] then
        local prev = ft[old.main].alts or {}
        for i = #prev, 1, -1 do
            if prev[i] == charName then tremove(prev, i) end
        end
    end
    ft[charName] = { isMain = false, main = mainName }
    ft[mainName].alts = ft[mainName].alts or {}
    local found = false
    for _, a in ipairs(ft[mainName].alts) do
        if a == charName then found = true break end
    end
    if not found then
        ft[mainName].alts[#ft[mainName].alts + 1] = charName
    end
end

local function GTApplyMain(charName)
    local ft = FT()
    if not ft then return end
    local prev = ft[charName]
    if prev and not prev.isMain and prev.main and ft[prev.main] then
        local pAlts = ft[prev.main].alts or {}
        for i = #pAlts, 1, -1 do
            if pAlts[i] == charName then tremove(pAlts, i) end
        end
    end
    ft[charName] = { isMain = true, alts = (prev and prev.alts) or {} }
end

local function GTApplyDel(charName)
    local ft = FT()
    if not ft then return end
    local entry = ft[charName]
    if not entry then return end
    if entry.isMain and entry.alts then
        for _, alt in ipairs(entry.alts) do
            if ft[alt] then
                ft[alt].isMain = true
                ft[alt].main   = nil
                ft[alt].alts   = ft[alt].alts or {}
            end
        end
    end
    if not entry.isMain and entry.main and ft[entry.main] then
        local pAlts = ft[entry.main].alts or {}
        for i = #pAlts, 1, -1 do
            if pAlts[i] == charName then tremove(pAlts, i) end
        end
    end
    ft[charName] = nil
end

local function GTEncodeFull()
    local ft = FT()
    if not ft then return "" end
    local parts = {}
    for name, entry in pairs(ft) do
        if not entry.isMain and entry.main then
            parts[#parts + 1] = name .. "|" .. entry.main
        end
    end
    return table.concat(parts, ";")
end

-- ============================================================================
-- SCAN GUILD NOTES  (public + officer, both patterns)
-- Supported formats in either note field:
--   "Alt:MainName"       — classic colon-prefix format (officer note)
--   "alt:MainName"       — lowercase variant
--   "MainName ALT"       — suffix format used in public notes
--   "MainName alt"       — lowercase suffix variant
-- ============================================================================
local function ScanGuildNotes()
    if not MTR.initialized or not MTR.db then return end
    local num = GetNumGuildMembers()
    if num == 0 then return end
    local count = 0
    for i = 1, num do
        -- fields: name,rankName,rankIndex,level,classDisplay,zone,publicNote,officerNote,...
        local name, _, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(i)
        if name then
            -- Strip realm suffix if present
            local shortName = name:match("^([^%-]+)") or name
            -- Check both notes for any supported alt-link pattern
            for _, note in ipairs({ officerNote or "", publicNote or "" }) do
                if note ~= "" then
                    local mn = nil

                    -- Pattern 1: "Alt:MainName" or "alt:MainName" (colon-prefix)
                    mn = note:match("[Aa][Ll][Tt]:%s*(.+)$")
                    if mn then mn = mn:match("^%s*(.-)%s*$") end

                    -- Pattern 2: "MainName ALT" or "MainName alt" (space-suffix)
                    -- The main name is everything before the trailing ALT word
                    if not mn or mn == "" then
                        mn = note:match("^%s*(.-)%s+[Aa][Ll][Tt]%s*$")
                        if mn then mn = mn:match("^%s*(.-)%s*$") end
                    end

                    if mn and mn ~= "" and mn ~= shortName then
                        GTApplySet(shortName, mn)
                        count = count + 1
                        break
                    end
                end
            end
        end
    end
    return count
end

-- ============================================================================
-- EVENT LISTENERS
-- ============================================================================
local gtMsgFrame = CreateFrame("Frame")
gtMsgFrame:RegisterEvent("CHAT_MSG_ADDON")
gtMsgFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= GT_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end
    local senderName = (sender or ""):match("^([^%-]+)") or sender or ""
    if senderName == MTR.playerName then return end

    local cmd, payload = message:match("^GT:(%a+):?(.*)$")
    if not cmd then return end

    if cmd == "SET" then
        local cn, mn = payload:match("^([^|]+)|(.+)$")
        if cn and mn then GTApplySet(cn, mn) end
    elseif cmd == "MAIN" then
        if payload ~= "" then GTApplyMain(payload) end
    elseif cmd == "DEL" then
        if payload ~= "" then GTApplyDel(payload) end
    elseif cmd == "REQ" then
        if MTR.isOfficer or MTR.isGM then
            local encoded = GTEncodeFull()
            if encoded ~= "" then GTBroadcast("GT:FULL:" .. encoded) end
        end
    elseif cmd == "FULL" then
        if payload ~= "" then
            for pair in payload:gmatch("([^;]+)") do
                local cn, mn = pair:match("^([^|]+)|(.+)$")
                if cn and mn then GTApplySet(cn, mn) end
            end
        end
    end

    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
end)

-- Scan notes after roster update (delayed to let data populate)
local gtRosterFrame = CreateFrame("Frame")
gtRosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
gtRosterFrame:SetScript("OnEvent", function()
    if not MTR.initialized or not MTR.db then return end
    if MTR.isOfficer or MTR.isGM then
        ScanGuildNotes()
    end
    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
end)

-- Request peer sync on login (delayed to ensure everything is ready)
local gtInitFrame = CreateFrame("Frame")
gtInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
gtInitFrame:SetScript("OnEvent", function()
    MTR.After(10, function()
        if MTR.initialized and IsInGuild() then
            GuildRoster()  -- request fresh roster data
            MTR.After(2, function()
                ScanGuildNotes()
                GTBroadcast("GT:REQ")
            end)
        end
    end)
end)

-- ============================================================================
-- PUBLIC API
-- ============================================================================
function MTR.GTSetAlt(charName, mainName)
    if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
    GTApplySet(charName, mainName)
    GTBroadcast("GT:SET:" .. charName .. "|" .. mainName)
    -- Write officer note
    local num = GetNumGuildMembers()
    for i = 1, num do
        local n = GetGuildRosterInfo(i)
        if n == charName then
            GuildRosterSetOfficerNote(i, "Alt:" .. mainName)
            break
        end
    end
    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
    MTR.MP("Linked |cffffff00" .. charName .. "|r as alt of |cffd4af37" .. mainName .. "|r")
end

function MTR.GTSetMain(charName)
    if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
    GTApplyMain(charName)
    GTBroadcast("GT:MAIN:" .. charName)
    local num = GetNumGuildMembers()
    for i = 1, num do
        local n, _, _, _, _, _, _, officerNote = GetGuildRosterInfo(i)
        if n == charName then
            if (officerNote or ""):match("^[Aa]lt:") then
                GuildRosterSetOfficerNote(i, "")
            end
            break
        end
    end
    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
    MTR.MP("|cffffff00" .. charName .. "|r set as main character.")
end

function MTR.GTRemove(charName)
    if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
    GTApplyDel(charName)
    GTBroadcast("GT:DEL:" .. charName)
    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
    MTR.MP("|cffffff00" .. charName .. "|r removed from guild tree.")
end

function MTR.GTGetMain(name)
    local ft = FT()
    if not ft then return nil end
    local entry = ft[name]
    if not entry then return nil end
    if entry.isMain then return name end
    return entry.main
end

-- ============================================================================
-- BUILD GUILD TREE TAB
-- ============================================================================
function MTR.BuildGuildTreeTab(t)
    if t._gtBuilt then return end
    t._gtBuilt = true
    local canManage = (MTR.isOfficer or MTR.isGM)
    local treeTopY = -160

    -- ── Description ──────────────────────────────────────────────────────
    local desc = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    desc:SetPoint("TOPLEFT",  t, "TOPLEFT",  10, -8)
    desc:SetPoint("TOPRIGHT", t, "TOPRIGHT", -10, -8)
    desc:SetWordWrap(true) desc:SetJustifyH("LEFT")
    if canManage then
        desc:SetText(
            "|cffaaaaaa" ..
            "All guild members appear below. " ..
            "Use the form to link alts to their main. " ..
            "Characters with officer notes containing 'Alt:MainName' are linked automatically. " ..
            "Changes sync to all online officers instantly." ..
            "|r")

        -- ── Input form ───────────────────────────────────────────────────────
        local sep1 = t:CreateTexture(nil, "ARTWORK")
        sep1:SetColorTexture(0.3, 0.3, 0.5, 0.5) sep1:SetHeight(1)
        sep1:SetPoint("TOPLEFT",  t, "TOPLEFT",  0, -42)
        sep1:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, -42)

        local formHdr = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        formHdr:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -52)
        formHdr:SetText("|cffd4af37Link Characters|r")

        local charLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        charLbl:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -70)
        charLbl:SetText("Character:")

        local charEB = CreateFrame("EditBox", "MekGTCharEB", t, "InputBoxTemplate")
        charEB:SetSize(180, 20) charEB:SetAutoFocus(false)
        charEB:SetPoint("TOPLEFT", t, "TOPLEFT", 80, -66)

        local mainLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mainLbl:SetPoint("TOPLEFT", t, "TOPLEFT", 280, -70)
        mainLbl:SetText("Main:")

        local mainEB = CreateFrame("EditBox", "MekGTMainEB", t, "InputBoxTemplate")
        mainEB:SetSize(180, 20) mainEB:SetAutoFocus(false)
        mainEB:SetPoint("TOPLEFT", t, "TOPLEFT", 315, -66)

        local setAltBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        setAltBtn:SetSize(100, 24) setAltBtn:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -96)
        setAltBtn:SetText("Set as Alt")
        setAltBtn:SetScript("OnClick", function()
            local cn = charEB:GetText():match("^%s*(.-)%s*$")
            local mn = mainEB:GetText():match("^%s*(.-)%s*$")
            if cn == "" or mn == "" then MTR.MPE("Enter both Character and Main name.") return end
            MTR.GTSetAlt(cn, mn)
            charEB:SetText("") mainEB:SetText("")
        end)

        local setMainBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        setMainBtn:SetSize(110, 24) setMainBtn:SetPoint("LEFT", setAltBtn, "RIGHT", 6, 0)
        setMainBtn:SetText("Set as Main")
        setMainBtn:SetScript("OnClick", function()
            local cn = charEB:GetText():match("^%s*(.-)%s*$")
            if cn == "" then MTR.MPE("Enter the Character name.") return end
            MTR.GTSetMain(cn)
            charEB:SetText("") mainEB:SetText("")
        end)

        local delBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        delBtn:SetSize(80, 24) delBtn:SetPoint("LEFT", setMainBtn, "RIGHT", 6, 0)
        delBtn:SetText("|cffff4444Unlink|r")
        delBtn:SetScript("OnClick", function()
            local cn = charEB:GetText():match("^%s*(.-)%s*$")
            if cn == "" then MTR.MPE("Enter the Character name.") return end
            MTR.GTRemove(cn)
            charEB:SetText("") mainEB:SetText("")
        end)

        local scanBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        scanBtn:SetSize(140, 24) scanBtn:SetPoint("LEFT", delBtn, "RIGHT", 14, 0)
        scanBtn:SetText("Scan Guild Notes")
        scanBtn:SetScript("OnClick", function()
            GuildRoster()
            MTR.After(1.5, function()
                local count = ScanGuildNotes() or 0
                MTR.MP("Guild note scan complete — " .. count .. " alt link(s) found.")
                if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
            end)
        end)

        treeTopY = -160
    else
        desc:SetText(
            "|cffaaaaaa" ..
            "All guild members appear below. Regular members can view the full guild tree, but officer note editing and alt-link management stay officer-only." ..
            "|r")
        treeTopY = -72
    end

    -- ── Tree display ─────────────────────────────────────────────────────
    local sep2 = t:CreateTexture(nil, "ARTWORK")
    sep2:SetColorTexture(0.3, 0.3, 0.5, 0.5) sep2:SetHeight(1)
    sep2:SetPoint("TOPLEFT",  t, "TOPLEFT",  0, treeTopY + 30)
    sep2:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, treeTopY + 30)

    local treeHdr = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    treeHdr:SetPoint("TOPLEFT", t, "TOPLEFT", 10, treeTopY + 20)
    treeHdr:SetText("|cffd4af37Guild Family Tree|r")

    local refreshBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
    refreshBtn:SetSize(80, 22)
    refreshBtn:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, treeTopY + 24)
    refreshBtn:SetText("Refresh")

    -- Status label (shows counts / last scan info)
    local statusLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusLbl:SetPoint("RIGHT", refreshBtn, "LEFT", -8, 0)
    statusLbl:SetText("")
    t._gtStatusLbl = statusLbl

    -- Scroll frame
    local sf = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     t, "TOPLEFT",   8, treeTopY)
    sf:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -28, 8)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(sf:GetWidth() or 580)
    content:SetHeight(800)
    sf:SetScrollChild(content)
    t._treeContent = content

    -- ── Render function ──────────────────────────────────────────────────
    local LINE_H = 16

    local CLASS_COLOR = {
        WARRIOR = "ffc79c6e", PALADIN = "fff58cba", HUNTER  = "ffabd473",
        ROGUE   = "fffff569", PRIEST  = "ffffffff", DEATHKNIGHT = "ffc41f3b",
        SHAMAN  = "ff0070de", MAGE    = "ff69ccf0", WARLOCK = "ff9482c9",
        DRUID   = "ffff7d0a",
    }
    local function CC(class)
        return "|c" .. (CLASS_COLOR[(class or ""):upper()] or "ffffffff")
    end

    -- Pool of FontStrings reused across renders
    if not content._pool then content._pool = {} end

    local function GetLine(idx)
        if not content._pool[idx] then
            content._pool[idx] = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        end
        return content._pool[idx]
    end

    local function HideFrom(n)
        for i = n, #content._pool do
            if content._pool[i] then content._pool[i]:Hide() end
        end
    end

    local function RenderTree()
        local ft = FT()
        if not ft then HideFrom(1) return end

        -- Gather live roster info: field order confirmed as
        -- name(1) rankName(2) rankIndex(3) level(4) classDisplay(5) zone(6)
        -- publicNote(7) officerNote(8) online(9) status(10) classFileName(11)
        local roster = {}
        local num = GetNumGuildMembers()
        for i = 1, num do
            local name, rankName, rankIndex, level, _, _, _, _, online, _, classFileName = GetGuildRosterInfo(i)
            if name then
                -- strip realm suffix if present
                local shortName = name:match("^([^%-]+)") or name
                roster[shortName] = {
                    rankName  = rankName  or "Unknown",
                    rankIndex = rankIndex or 99,
                    level     = level     or 0,
                    class     = classFileName or "WARRIOR",
                    online    = online    or false,
                    fullName  = name,
                }
            end
        end

        -- Collect all mains + unlinked guild members
        local seen = {}
        local uniqueMains = {}

        -- 1. Explicitly registered mains
        for name, entry in pairs(ft) do
            if entry.isMain and not seen[name] then
                seen[name] = true
                uniqueMains[#uniqueMains + 1] = name
            end
        end

        -- 2. Guild members not in ft at all → show as unlinked
        for name in pairs(roster) do
            if not seen[name] and not ft[name] then
                seen[name] = true
                uniqueMains[#uniqueMains + 1] = name
            end
        end

        -- Sort by rankIndex then name
        table.sort(uniqueMains, function(a, b)
            local ra = roster[a] and roster[a].rankIndex or 99
            local rb = roster[b] and roster[b].rankIndex or 99
            if ra ~= rb then return ra < rb end
            return a < b
        end)

        local y       = 0
        local lineIdx = 0

        local function AddLine(text, indent)
            lineIdx = lineIdx + 1
            local fs = GetLine(lineIdx)
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", 6 + (indent or 0) * 16, -y)
            fs:SetText(text)
            fs:Show()
            y = y + LINE_H
        end

        local lastRank = nil
        local altCount = 0

        for _, mainName in ipairs(uniqueMains) do
            local ri = roster[mainName]
            local rankName  = ri and ri.rankName  or "Unknown"
            local rankIndex = ri and ri.rankIndex or 99

            -- Rank group header
            if rankName ~= lastRank then
                if lastRank ~= nil then y = y + 5 end
                AddLine(string.format("|cffd4af37[%s]|r", rankName), 0)
                lastRank = rankName
            end

            -- Is this an alt registered as a main? (unlikely but guard it)
            local ftEntry  = ft[mainName]
            local online   = ri and ri.online or false
            local dot      = online and "|cff00ff00\226\151\143|r " or "|cff555555\226\151\143|r "
            local lv       = ri and ri.level  or "?"
            local cl       = ri and ri.class  or "WARRIOR"
            local alts     = GetAlts(mainName)
            local hasAlts  = #alts > 0
            local prefix   = hasAlts and "|cffaaaaaa+|r " or "  "

            AddLine(string.format("%s%s%s%s|r  |cffaaaaaa(lv%s)%s|r",
                prefix, dot, CC(cl), mainName, tostring(lv),
                not ftEntry and "  |cff666666[unlinked]|r" or ""), 1)

            for _, altName in ipairs(alts) do
                altCount = altCount + 1
                local ai  = roster[altName]
                local aOn = ai and ai.online or false
                local aDot = aOn and "|cff00ff00\226\151\143|r " or "|cff555555\226\151\143|r "
                local aLv = ai and ai.level or "?"
                local aCl = ai and ai.class or "WARRIOR"
                AddLine(string.format("|cffaaaaaa\226\148\148|r %s%s%s|r  |cffaaaaaa(alt lv%s)|r",
                    aDot, CC(aCl), altName, tostring(aLv)), 2)
            end
        end

        -- Footer
        y = y + 6
        AddLine(string.format("|cffaaaaaa%d members shown  \226\128\162  %d alts linked|r",
            #uniqueMains, altCount), 0)

        HideFrom(lineIdx + 1)
        content:SetHeight(math.max(y + 20, 400))

        -- Update status label
        if t._gtStatusLbl then
            t._gtStatusLbl:SetText(
                string.format("|cffaaaaaa%d members  %d alts|r", #uniqueMains, altCount))
        end
    end

    t._renderTree = RenderTree
    refreshBtn:SetScript("OnClick", function()
        GuildRoster()
        MTR.After(0.5, RenderTree)
    end)

    MTR.RefreshGuildTree = function()
        if t:IsVisible() then RenderTree() end
    end

    -- Trigger note scan + render on first open
    GuildRoster()
    MTR.After(1, function()
        ScanGuildNotes()
        RenderTree()
    end)
end
