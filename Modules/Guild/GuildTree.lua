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
    if MTR.GetGuildStore then
        local gs = MTR.GetGuildStore(true)
        gs.familyTree = gs.familyTree or {}
        if MTR.db then MTR.db.familyTree = gs.familyTree end
        return gs.familyTree
    end
    if not MTR.db then return nil end
    if not MTR.db.familyTree then MTR.db.familyTree = {} end
    return MTR.db.familyTree
end

-- ============================================================================
-- SYNC
-- ============================================================================
local function GTBroadcast(msg)
    if MTR.SendGuildScoped then return MTR.SendGuildScoped(GT_PREFIX, msg) end
    if IsInGuild() then SendAddonMessage(GT_PREFIX, msg, "GUILD") end
end

local gtMuteTouch = false
local GTTouch

local function CanonName(name)
    name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then return "" end
    local short = name:match("^([^%-]+)") or name
    local want = string.lower(short)
    local num = GetNumGuildMembers() or 0
    for i = 1, num do
        local n = GetGuildRosterInfo(i)
        local sn = n and (n:match("^([^%-]+)") or n)
        if sn and string.lower(sn) == want then
            return sn
        end
    end
    return short
end

local function IsSelfName(name)
    local selfName = CanonName(MTR.playerName or "")
    local n = CanonName(name or "")
    return selfName ~= "" and n ~= "" and selfName == n
end

local function CanEditTreeLocal(charName)
    if MTR.isOfficer or MTR.isGM then return true end
    return IsSelfName(charName)
end

local function IsGTWriteAllowed(actorName, charName)
    if MTR.IsGuildOfficerName and MTR.IsGuildOfficerName(actorName) then return true end
    local actor = CanonName(actorName or "")
    local char = CanonName(charName or "")
    return actor ~= "" and char ~= "" and actor == char
end

local function GTSyncState()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return { revision = 0, hash = "0", lastSyncAt = 0 } end
    gs.syncState = gs.syncState or {}
    gs.syncState.guildTree = gs.syncState.guildTree or { revision = 0, hash = "0", lastSyncAt = 0, lastAckByPeer = {} }
    return gs.syncState.guildTree
end

local function GTApplySet(charName, mainName)
    charName = CanonName(charName)
    mainName = CanonName(mainName)
    if charName == "" or mainName == "" or charName == mainName then return end
    local ft = FT()
    if not ft then return end

    local prev = ft[charName]
    if prev and not prev.isMain and prev.main == mainName then
        local alts = ft[mainName] and ft[mainName].alts or nil
        if type(alts) == "table" then
            for _, a in ipairs(alts) do
                if a == charName then
                    return false
                end
            end
        end
    end

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
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("guildTree", "setAlt", tostring(charName or "") .. "|" .. tostring(mainName or "")) end
    if not gtMuteTouch then GTTouch() end
    return true
end

local function GTApplyMain(charName)
    charName = CanonName(charName)
    if charName == "" then return end
    local ft = FT()
    if not ft then return end
    local prev = ft[charName]
    if prev and prev.isMain then
        return false
    end
    if prev and not prev.isMain and prev.main and ft[prev.main] then
        local pAlts = ft[prev.main].alts or {}
        for i = #pAlts, 1, -1 do
            if pAlts[i] == charName then tremove(pAlts, i) end
        end
    end
    ft[charName] = { isMain = true, alts = (prev and prev.alts) or {} }
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("guildTree", "setMain", tostring(charName or "")) end
    if not gtMuteTouch then GTTouch() end
    return true
end

local function GTApplyDel(charName)
    charName = CanonName(charName)
    if charName == "" then return end
    local ft = FT()
    if not ft then return end
    local entry = ft[charName]
    if not entry then return false end
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
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("guildTree", "delete", tostring(charName or "")) end
    if not gtMuteTouch then GTTouch() end
    return true
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
    table.sort(parts)
    return table.concat(parts, ";")
end

GTTouch = function()
    local st = GTSyncState()
    st.revision = tonumber(st.revision or 0) + 1
    st.hash = (MTR.Hash and MTR.Hash(GTEncodeFull())) or "0"
    st.lastSyncAt = time()
    return st
end

local function GTBuildChunks(payload)
    local chunks, chunk = {}, ""
    payload = tostring(payload or "")
    for token in payload:gmatch("[^;]+") do
        if #chunk + #token + 1 > 200 then
            if chunk ~= "" then chunks[#chunks + 1] = chunk end
            chunk = token
        else
            chunk = (chunk == "" and token) or (chunk .. ";" .. token)
        end
    end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    return chunks
end

local function GTNormalizePayload(payload)
    local tokens, seen = {}, {}
    for pair in tostring(payload or ""):gmatch("([^;]+)") do
        local cn, mn = pair:match("^([^|]+)|(.+)$")
        if cn and mn then
            cn = CanonName(cn)
            mn = CanonName(mn)
            if cn ~= "" and mn ~= "" and cn ~= mn then
                local tok = cn .. "|" .. mn
                if not seen[tok] then
                    seen[tok] = true
                    tokens[#tokens + 1] = tok
                end
            end
        end
    end
    table.sort(tokens)
    return table.concat(tokens, ";")
end

local function GTApplyFull(payload)
    local ft = FT()
    if not ft then return 0 end
    for k in pairs(ft) do ft[k] = nil end
    local num = GetNumGuildMembers() or 0
    for i = 1, num do
        local name = GetGuildRosterInfo(i)
        if name then
            local shortName = name:match("^([^%-]+)") or name
            if not ft[shortName] then
                ft[shortName] = { isMain = true, alts = {} }
            end
        end
    end
    local added = 0
    for pair in tostring(payload or ""):gmatch("([^;]+)") do
        local cn, mn = pair:match("^([^|]+)|(.+)$")
        if cn and mn then
            cn = CanonName(cn)
            mn = CanonName(mn)
            if cn ~= "" and mn ~= "" and cn ~= mn then
            if not ft[mn] then ft[mn] = { isMain = true, alts = {} } end
            local old = ft[cn]
            if old and not old.isMain and old.main and ft[old.main] then
                local prev = ft[old.main].alts or {}
                for i = #prev, 1, -1 do
                    if prev[i] == cn then tremove(prev, i) end
                end
            end
            ft[cn] = { isMain = false, main = mn }
            ft[mn].alts = ft[mn].alts or {}
            local found = false
            for _, a in ipairs(ft[mn].alts) do
                if a == cn then found = true break end
            end
            if not found then ft[mn].alts[#ft[mn].alts + 1] = cn end
            added = added + 1
            end
        end
    end
    GTTouch()
    return added
end

local function GTSendFull(reason)
    if not (MTR.isOfficer or MTR.isGM) then return false end
    local payload = GTEncodeFull()
    local st = GTSyncState()
    local hash = (MTR.Hash and MTR.Hash(payload)) or "0"
    st.hash = hash
    st.lastBroadcastAt = time()
    st.lastBroadcastReason = reason or "sync"
    local chunks = GTBuildChunks(payload)
    GTBroadcast(string.format("GT:MET:%d:%s:%d", tonumber(st.revision or 0), tostring(hash), #chunks))
    for _, c in ipairs(chunks) do GTBroadcast("GT:D:" .. c) end
    if #chunks == 0 then GTBroadcast("GT:D:") end
    GTBroadcast("GT:END:" .. tostring(reason or "sync"))
    return true
end

-- ============================================================================
-- SCAN GUILD NOTES  (public + officer, both patterns)
-- Supported formats in either note field:
--   "Alt:MainName"       — classic colon-prefix format (officer note)
--   "alt:MainName"       — lowercase variant
--   "MainName ALT"       — suffix format used in public notes
--   "MainName alt"       — lowercase suffix variant
-- ============================================================================
local function ParseMainFromNote(note, shortName)
    if type(note) ~= "string" then return nil end
    note = (note:match("^%s*(.-)%s*$") or "")
    if note == "" then return nil end

    local cleaned = note:gsub("[\"']", "")
    cleaned = cleaned:gsub("%s+", " ")
    local lower = string.lower(cleaned)
    local mainName
    if lower:find("^alt%s*[|:/%-]") then
        mainName = cleaned:match("^[Aa][Ll][Tt]%s*[|:/%-]%s*(.+)$")
    elseif lower:find("^alt%s+of%s+") then
        mainName = cleaned:match("^[Aa][Ll][Tt]%s+[Oo][Ff]%s+(.+)$")
    elseif lower:find("^alt%s+or%s+") then
        mainName = cleaned:match("^[Aa][Ll][Tt]%s+[Oo][Rr]%s+(.+)$")
    elseif lower:find("^main%s*[:%-]") then
        mainName = cleaned:match("^[Mm][Aa][Ii][Nn]%s*[:%-]%s*(.+)$")
    elseif lower:find("^main%s+or%s+") then
        mainName = cleaned:match("^[Mm][Aa][Ii][Nn]%s+[Oo][Rr]%s+(.+)$")
    elseif lower:find("%s*[|:/%-]%s*alt%s*$") then
        mainName = cleaned:gsub("%s*[|:/%-]%s*[Aa][Ll][Tt]%s*$", "")
    elseif lower:find("%s+alt%s*$") then
        mainName = cleaned:gsub("%s+[Aa][Ll][Tt]%s*$", "")
    end

    if not mainName then
        local norm = lower
        norm = norm:gsub("[%-%|:/%(%)]", " ")
        norm = norm:gsub("%s+", " ")
        norm = norm:gsub("^%s+", ""):gsub("%s+$", "")
        if norm:find(" alt ", 1, true) or norm:match(" alt$") or norm:match("^alt ") then
            norm = norm:gsub("^alt%s+of%s+", "")
            norm = norm:gsub("^alt%s+or%s+", "")
            norm = norm:gsub("^alt%s+", "")
            norm = norm:gsub("%s+alt$", "")
            norm = norm:gsub("%s+main$", "")
            norm = norm:gsub("%s+", " ")
            norm = norm:gsub("^%s+", ""):gsub("%s+$", "")
            if norm ~= "" then mainName = norm end
        end
    end
    if not mainName then return nil end
    mainName = (mainName:match("^%s*(.-)%s*$") or "")
    if mainName == "" then return nil end
    local first = string.sub(mainName, 1, 1)
    local last = string.sub(mainName, -1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
        mainName = string.sub(mainName, 2, -2)
    end
    mainName = mainName:gsub("%s*[|:/%-]%s*[Aa][Ll][Tt]%s*$", "")
    mainName = mainName:gsub("%s+[Aa][Ll][Tt]%s*$", "")
    mainName = (mainName:match("^%s*(.-)%s*$") or "")
    if mainName == "" then return nil end

    local lowerMain = string.lower(mainName)
    local lowerSelf = string.lower(shortName or "")
    if lowerMain == lowerSelf then return nil end

    -- Resolve noisy free text to an actual guild character name.
    local num = GetNumGuildMembers() or 0
    local cleanedMain = lowerMain:gsub("[^%a%d]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local bestName, bestLen = nil, 0
    for i = 1, num do
        local n = GetGuildRosterInfo(i)
        local sn = n and (n:match("^([^%-]+)") or n)
        if sn and sn ~= "" then
            local ls = string.lower(sn)
            if ls ~= lowerSelf then
                if ls == lowerMain then return sn end
                local lsn = ls:gsub("[^%a%d]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                if lsn ~= "" then
                    if cleanedMain == lsn or cleanedMain:find("^" .. lsn .. " ") or cleanedMain:find(" " .. lsn .. " ") or cleanedMain:find(" " .. lsn .. "$") then
                        local ln = #lsn
                        if ln > bestLen then
                            bestLen = ln
                            bestName = sn
                        end
                    end
                end
            end
        end
    end
    return bestName
end

local function EnsureGuildMemberEntries()
    local ft = FT()
    if not ft then return 0 end
    local added = 0
    local num = GetNumGuildMembers() or 0
    for i = 1, num do
        local name = GetGuildRosterInfo(i)
        if name then
            local shortName = name:match("^([^%-]+)") or name
            if not ft[shortName] then
                ft[shortName] = { isMain = true, alts = {} }
                added = added + 1
            end
        end
    end
    return added
end

local function ScanGuildNotes()
    if not MTR.initialized or not MTR.db then return end
    local num = GetNumGuildMembers() or 0
    if num == 0 then return end

    local ft = FT()
    if not ft then return end
    local beforeHash = (MTR.Hash and MTR.Hash(GTEncodeFull())) or "0"

    -- Ensure every visible guild member appears as a standalone main unless linked as an alt.
    -- These placeholder main nodes are roster-derived and not part of the synced hash.
    EnsureGuildMemberEntries()

    local count = 0
    gtMuteTouch = true
    for i = 1, num do
        local name, _, _, _, _, _, publicNote, officerNote = GetGuildRosterInfo(i)
        if name then
            local shortName = name:match("^([^%-]+)") or name
            -- Public note is treated as authoritative for scan-based relinking.
            -- This allows members to self-correct outdated officer-note mappings
            -- by updating their public note and re-running Scan Notes.
            local mnPublic = ParseMainFromNote(publicNote, shortName)
            local mnOfficer = ParseMainFromNote(officerNote, shortName)
            local mn = mnPublic or mnOfficer
            if MTR.dprint and (officerNote and officerNote ~= "" or publicNote and publicNote ~= "") then
                MTR.dprint("[GT Scan]", shortName, "officer='" .. tostring(officerNote or "") .. "'", "public='" .. tostring(publicNote or "") .. "'", "parsedPublic='" .. tostring(mnPublic or "") .. "'", "parsedOfficer='" .. tostring(mnOfficer or "") .. "'", "applied='" .. tostring(mn or "") .. "'")
            end
            if mn and mn ~= shortName then
                mn = CanonName(mn)
                if GTApplySet(shortName, mn) then
                    count = count + 1
                end
            else
                local existing = ft[shortName]
                if not existing then
                    ft[shortName] = { isMain = true, alts = {} }
                end
            end
        end
    end
    gtMuteTouch = false
    local afterHash = (MTR.Hash and MTR.Hash(GTEncodeFull())) or "0"
    if tostring(afterHash) ~= tostring(beforeHash) then
        GTTouch()
    end
    return count
end

-- ============================================================================
-- EVENT LISTENERS
-- ============================================================================
local gtMsgFrame = CreateFrame("Frame")
gtMsgFrame:RegisterEvent("CHAT_MSG_ADDON")
local gtRecv = nil
gtMsgFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= GT_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end
    local unpacked, senderName = (MTR.UnpackGuildScoped and MTR.UnpackGuildScoped(message, sender, false)) or message, ((sender or ""):match("^([^%-]+)") or sender or "")
    if not unpacked then return end
    if senderName == MTR.playerName then return end

    local cmd, payload = unpacked:match("^GT:(%a+):?(.*)$")
    if not cmd then return end

    if cmd == "SET" then
        local cn, mn = payload:match("^([^|]+)|(.+)$")
        if cn and mn and IsGTWriteAllowed(senderName, cn) then GTApplySet(cn, mn) end
    elseif cmd == "MAIN" then
        if payload ~= "" and IsGTWriteAllowed(senderName, payload) then GTApplyMain(payload) end
    elseif cmd == "DEL" then
        if payload ~= "" and IsGTWriteAllowed(senderName, payload) then GTApplyDel(payload) end
    elseif cmd == "REQ" then
        if MTR.isOfficer or MTR.isGM then
            local st = GTSyncState()
            local peerHash = payload ~= "" and payload or nil
            if peerHash and peerHash == tostring(st.hash or "0") then
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
            end
            if not peerHash or peerHash ~= tostring(st.hash or "0") then
                GTSendFull("peer-request")
            end
        end
    elseif cmd == "MET" then
        if not (MTR.IsGuildOfficerName and MTR.IsGuildOfficerName(senderName)) then return end
        local rev, hash, expected = payload:match("^(%d+):([^:]+):([^:]+)")
        
        -- Auto-clear conflict if header hash matches local hash
        if hash then
            local st = GTSyncState()
            if tostring(hash) == tostring(st.hash or "0") then
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
                -- Adopt higher revision if hashes match
                if rev and tonumber(rev) > tonumber(st.revision or 0) then
                    st.revision = tonumber(rev)
                end
            end
        end

        gtRecv = { rev = tonumber(rev) or 0, hash = hash or "0", expected = tonumber(expected) or 0, chunks = {}, from = senderName }
    elseif cmd == "D" and gtRecv then
        if senderName ~= gtRecv.from then return end
        gtRecv.chunks[#gtRecv.chunks + 1] = payload
    elseif cmd == "END" and gtRecv then
        if senderName ~= gtRecv.from then return end
        local st = GTSyncState()
        local incomingRev = tonumber(gtRecv.rev) or 0
        local localRev = tonumber(st.revision or 0)
        if incomingRev >= localRev then
            if (tonumber(gtRecv.expected) or 0) > 0 and #gtRecv.chunks <= 0 then
                st.lastConflictAt = time()
                st.lastConflictFrom = tostring(gtRecv.from or "?")
                st.lastConflictReason = "incomplete-stream"
                gtRecv = nil
                return
            end
            local raw = table.concat(gtRecv.chunks, ";")
            local incomingHash = tostring(gtRecv.hash or "0")
            local h = (MTR.Hash and MTR.Hash(raw)) or "0"

            -- Guild addon chunks can arrive out of order under heavy traffic.
            -- Re-normalize by parsed tokens before declaring a mismatch.
            if h ~= incomingHash and #gtRecv.chunks > 0 then
                local normalized = GTNormalizePayload(raw)
                local hNorm = (MTR.Hash and MTR.Hash(normalized)) or "0"
                if hNorm == incomingHash then
                    raw = normalized
                    h = hNorm
                end
            end

            if h == incomingHash or #gtRecv.chunks == 0 then
                GTApplyFull(raw)
                st.revision = incomingRev
                st.hash = h
                st.lastSyncAt = time()
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
                GTBroadcast(string.format("GT:ACK:%s:%s:%d", tostring(MTR.playerName or "?"), tostring(st.hash or "0"), tonumber(st.revision or 0)))
            else
                st.lastConflictAt = time()
                st.lastConflictFrom = tostring(gtRecv.from or "?")
                st.lastConflictReason = "hash-mismatch"
                MTR.MPE("[GuildTree Sync] Snapshot hash mismatch from " .. tostring(gtRecv.from or "?"))
            end
        end
        gtRecv = nil
    elseif cmd == "ACK" then
        if not (MTR.IsGuildOfficerName and MTR.IsGuildOfficerName(senderName)) then return end
        local peer, hash, rev = payload:match("^([^:]+):([^:]+):([^:]+)$")
        local st = GTSyncState()
        if tostring(hash or "") == tostring(st.hash or "0") then
            local r = tonumber(rev) or 0
            if r > tonumber(st.revision or 0) then st.revision = r end
            st.lastAckByPeer = st.lastAckByPeer or {}
            st.lastAckByPeer[peer or senderName or "?"] = { revision = r, at = time() }
        end
    elseif cmd == "FULL" then
        if payload ~= "" then
            for pair in payload:gmatch("([^;]+)") do
                local cn, mn = pair:match("^([^|]+)|(.+)$")
                if cn and mn then GTApplySet(cn, mn) end
            end
            GTTouch()
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
                if MTR.isOfficer or MTR.isGM then
                    ScanGuildNotes()
                    local st = GTSyncState()
                    GTBroadcast("GT:REQ:" .. tostring(st.hash or "0"))
                end
            end)
        end
    end)
end)

-- ============================================================================
-- PUBLIC API
-- ============================================================================
function MTR.GTSetAlt(charName, mainName)
    if not CanEditTreeLocal(charName) then MTR.MPE("You can only set alt/main links for your own character.") return end
    charName = CanonName(charName)
    mainName = CanonName(mainName)
    if charName == "" or mainName == "" or charName == mainName then MTR.MPE("Invalid character/main pair.") return end
    GTApplySet(charName, mainName)
    GTBroadcast("GT:SET:" .. charName .. "|" .. mainName)
    -- Write officer note
    if MTR.isOfficer or MTR.isGM then
        local num = GetNumGuildMembers()
        for i = 1, num do
            local n = GetGuildRosterInfo(i)
            if CanonName(n) == charName then
                GuildRosterSetOfficerNote(i, "Alt:" .. mainName)
                break
            end
        end
    end
    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
    MTR.MP("Linked |cffffff00" .. charName .. "|r as alt of |cffd4af37" .. mainName .. "|r")
end

function MTR.GTSetMain(charName)
    if not CanEditTreeLocal(charName) then MTR.MPE("You can only set alt/main links for your own character.") return end
    charName = CanonName(charName)
    if charName == "" then MTR.MPE("Invalid character name.") return end
    GTApplyMain(charName)
    GTBroadcast("GT:MAIN:" .. charName)
    if MTR.isOfficer or MTR.isGM then
        local num = GetNumGuildMembers()
        for i = 1, num do
            local n, _, _, _, _, _, _, officerNote = GetGuildRosterInfo(i)
            if CanonName(n) == charName then
                if (officerNote or ""):match("^[Aa]lt:") then
                    GuildRosterSetOfficerNote(i, "")
                end
                break
            end
        end
    end
    if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
    MTR.MP("|cffffff00" .. charName .. "|r set as main character.")
end

function MTR.GTRemove(charName)
    if not CanEditTreeLocal(charName) then MTR.MPE("You can only unlink your own character.") return end
    charName = CanonName(charName)
    if charName == "" then MTR.MPE("Invalid character name.") return end
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

local _gtPopupInstalled = false
local function InstallGuildTreePopupMenu()
    if _gtPopupInstalled then return end
    _gtPopupInstalled = true
    if not UnitPopupButtons or not UnitPopupMenus then return end

    UnitPopupButtons["MTR_SET_MAIN"] = { text = "MekTown: Set as Main", dist = 0 }
    UnitPopupButtons["MTR_SET_ALT"]  = { text = "MekTown: Set as Alt", dist = 0 }

    local menus = { "SELF", "PLAYER", "FRIEND", "GUILD", "PARTY", "RAID_PLAYER" }
    for _, menu in ipairs(menus) do
        if UnitPopupMenus[menu] then
            local foundMain, foundAlt = false, false
            for _, v in ipairs(UnitPopupMenus[menu]) do
                if v == "MTR_SET_MAIN" then foundMain = true end
                if v == "MTR_SET_ALT" then foundAlt = true end
            end
            if not foundMain then table.insert(UnitPopupMenus[menu], 1, "MTR_SET_MAIN") end
            if not foundAlt then table.insert(UnitPopupMenus[menu], 2, "MTR_SET_ALT") end
        end
    end

    StaticPopupDialogs["MEKTOWN_GT_SET_ALT"] = StaticPopupDialogs["MEKTOWN_GT_SET_ALT"] or {
        text = "Set %s as alt of:",
        button1 = "Set Alt",
        button2 = "Cancel",
        hasEditBox = true,
        maxLetters = 64,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnShow = function(self)
            if self.editBox then
                self.editBox:SetText("")
                self.editBox:SetFocus()
            end
        end,
        OnAccept = function(self)
            local charName = self.data
            local mainName = self.editBox and self.editBox:GetText() or ""
            mainName = (mainName or ""):match("^%s*(.-)%s*$") or ""
            if charName and mainName ~= "" and MTR.GTSetAlt then
                MTR.GTSetAlt(charName, mainName)
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            if parent and parent.button1 then parent.button1:Click() end
        end,
    }

    if type(hooksecurefunc) == "function" then
        hooksecurefunc("UnitPopup_OnClick", function(self)
            if not self or not self.value then return end
            if self.value ~= "MTR_SET_MAIN" and self.value ~= "MTR_SET_ALT" then return end
            local unit = self.unit
            if (not unit) and UIDROPDOWNMENU_INIT_MENU then unit = UIDROPDOWNMENU_INIT_MENU.unit end
            local name = unit and UnitName(unit)
            if not name or name == "" then return end
            name = name:match("^([^%-]+)") or name
            if self.value == "MTR_SET_MAIN" then
                MTR.GTSetMain(name)
            else
                StaticPopup_Show("MEKTOWN_GT_SET_ALT", name, nil, name)
            end
        end)
    end
end

function MTR.BuildGuildTreeTab(t)
    if t._gtBuilt then return end
    t._gtBuilt = true
    InstallGuildTreePopupMenu()

    local canManage = (MTR.isOfficer or MTR.isGM)
    t._gtExpandedMains = t._gtExpandedMains or {}
    t._gtRankSelected = t._gtRankSelected or {}
    t._gtMultiRank = true
    t._gtSearch = ""

    local function MakeLabel(parent, text, font, x, y, w)
        local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        if w then fs:SetWidth(w) fs:SetJustifyH("LEFT") end
        fs:SetText(text or "")
        return fs
    end

    local function SetCheckLabel(cb, txt)
        if cb.text then cb.text:SetText(txt)
        elseif cb.Text then cb.Text:SetText(txt)
        elseif cb._label then cb._label:SetText(txt)
        else
            local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", cb, "RIGHT", 2, 1)
            lbl:SetText(txt)
            cb._label = lbl
        end
    end

    MakeLabel(t, "|cffd4af37Guild Tree|r", "GameFontNormalLarge", 10, -10, 900)
    MakeLabel(t,
        canManage and "Scalable rank-filtered guild tree with compact main/alt nesting. Officers can scan notes, link mains/alts, and use right-click profile menu actions."
                  or "Scalable rank-filtered guild tree with compact main/alt nesting. Members can set their own main/alt via right-click unit menu actions.",
        "GameFontNormalSmall", 10, -34, 980)

    local topY = -60
    if canManage then
        MakeLabel(t, "Character:", "GameFontNormal", 10, topY, 70)
        local charEB = CreateFrame("EditBox", "MekGTCharEB", t, "InputBoxTemplate")
        charEB:SetSize(140, 20) charEB:SetAutoFocus(false)
        charEB:SetPoint("TOPLEFT", t, "TOPLEFT", 76, topY + 4)

        MakeLabel(t, "Main:", "GameFontNormal", 228, topY, 40)
        local mainEB = CreateFrame("EditBox", "MekGTMainEB", t, "InputBoxTemplate")
        mainEB:SetSize(140, 20) mainEB:SetAutoFocus(false)
        mainEB:SetPoint("TOPLEFT", t, "TOPLEFT", 266, topY + 4)

        local setAltBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        setAltBtn:SetSize(84, 22) setAltBtn:SetPoint("TOPLEFT", t, "TOPLEFT", 422, topY + 2)
        setAltBtn:SetText("Set Alt")
        setAltBtn:SetScript("OnClick", function()
            local cn = (charEB:GetText() or ""):match("^%s*(.-)%s*$")
            local mn = (mainEB:GetText() or ""):match("^%s*(.-)%s*$")
            if cn == "" or mn == "" then if MTR.MPE then MTR.MPE("Enter both Character and Main.") end return end
            MTR.GTSetAlt(cn, mn)
        end)

        local setMainBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        setMainBtn:SetSize(84, 22) setMainBtn:SetPoint("LEFT", setAltBtn, "RIGHT", 6, 0)
        setMainBtn:SetText("Set Main")
        setMainBtn:SetScript("OnClick", function()
            local cn = (charEB:GetText() or ""):match("^%s*(.-)%s*$")
            if cn == "" then if MTR.MPE then MTR.MPE("Enter a Character.") end return end
            MTR.GTSetMain(cn)
        end)

        local unlinkBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        unlinkBtn:SetSize(72, 22) unlinkBtn:SetPoint("LEFT", setMainBtn, "RIGHT", 6, 0)
        unlinkBtn:SetText("Unlink")
        unlinkBtn:SetScript("OnClick", function()
            local cn = (charEB:GetText() or ""):match("^%s*(.-)%s*$")
            if cn == "" then if MTR.MPE then MTR.MPE("Enter a Character.") end return end
            MTR.GTRemove(cn)
        end)

        local scanBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
        scanBtn:SetSize(104, 22) scanBtn:SetPoint("LEFT", unlinkBtn, "RIGHT", 10, 0)
        scanBtn:SetText("Scan Notes")
        scanBtn:SetScript("OnClick", function()
            GuildRoster()
            MTR.After(0.2, function() GuildRoster() end)
            local function doScan()
                local count = ScanGuildNotes() or 0
                if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
                if MTR.MP then MTR.MP("Guild note scan complete — " .. count .. " link(s) found.") end
            end
            MTR.After(0.5, doScan)
            MTR.After(1.5, doScan)
            MTR.After(3.0, doScan)
        end)
        topY = -92
    end

    local searchEB = CreateFrame("EditBox", nil, t, "InputBoxTemplate")
    searchEB:SetSize(170, 20) searchEB:SetAutoFocus(false)
    searchEB:SetPoint("TOPLEFT", t, "TOPLEFT", 10, topY)
    searchEB:SetText("")
    MakeLabel(t, "Search", "GameFontNormalSmall", 14, topY + 16, 80)

    local multiCK = CreateFrame("CheckButton", nil, t, "UICheckButtonTemplate")
    multiCK:SetPoint("TOPLEFT", t, "TOPLEFT", 192, topY + 2)
    multiCK:SetChecked(true)
    SetCheckLabel(multiCK, "Multi-rank")

    local compactCK = CreateFrame("CheckButton", nil, t, "UICheckButtonTemplate")
    compactCK:SetPoint("TOPLEFT", t, "TOPLEFT", 306, topY + 2)
    compactCK:SetChecked(true)
    SetCheckLabel(compactCK, "Compact")
    t._gtCompact = true

    local expandBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
    expandBtn:SetSize(86, 22)
    expandBtn:SetPoint("TOPLEFT", t, "TOPLEFT", 420, topY)
    expandBtn:SetText("Expand All")

    local collapseBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
    collapseBtn:SetSize(90, 22)
    collapseBtn:SetPoint("LEFT", expandBtn, "RIGHT", 6, 0)
    collapseBtn:SetText("Collapse All")

    local refreshBtn = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
    refreshBtn:SetSize(76, 22)
    refreshBtn:SetPoint("TOPRIGHT", t, "TOPRIGHT", -8, topY)
    refreshBtn:SetText("Refresh")

    local statusLbl = MakeLabel(t, "", "GameFontNormalSmall", 640, topY + 2, 180)
    t._gtStatusLbl = statusLbl

    local sidebar = CreateFrame("Frame", nil, t)
    sidebar:SetWidth(132)
    sidebar:SetPoint("TOPLEFT", t, "TOPLEFT", 10, topY - 32)
    sidebar:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 10, 10)

    local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND")
    sidebarBg:SetAllPoints(sidebar)
    sidebarBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    sidebarBg:SetVertexColor(0.05, 0.05, 0.07, 0.55)
    MakeLabel(sidebar, "Ranks", "GameFontNormal", 8, -8, 100)

    local rankButtons = {}

    local sf = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", t, "TOPLEFT", 146, topY - 32)
    sf:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -28, 10)
    local content = CreateFrame("Frame", nil, sf)
    content:SetWidth(780)
    content:SetHeight(520)
    sf:SetScrollChild(content)
    t._treeContent = content

    local rows = {}
    local function acquireRow(i)
        if rows[i] then return rows[i] end
        local row = CreateFrame("Button", nil, content)
        row:SetHeight(16)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        row:SetPoint("RIGHT", content, "RIGHT", -4, 0)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)
        row.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
        row.bg:SetVertexColor(0, 0, 0, 0)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWidth(720)
        row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.meta:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.meta:SetJustifyH("RIGHT")
        rows[i] = row
        return row
    end

    local CLASS_COLOR = {
        WARRIOR = "ffc79c6e", PALADIN = "fff58cba", HUNTER = "ffabd473", ROGUE = "fffff569",
        PRIEST = "ffffffff", DEATHKNIGHT = "ffc41f3b", SHAMAN = "ff0070de", MAGE = "ff69ccf0",
        WARLOCK = "ff9482c9", DRUID = "ffff7d0a",
    }
    local function CC(class)
        return "|c" .. (CLASS_COLOR[(class or ""):upper()] or "ffffffff")
    end

    local function buildTreeData()
        local roster, ranks = {}, {}
        local num = GetNumGuildMembers() or 0
        for i = 1, num do
            local name, rankName, rankIndex, level, _, _, publicNote, officerNote, online, _, classFileName = GetGuildRosterInfo(i)
            if name then
                local shortName = name:match("^([^%-]+)") or name
                roster[shortName] = {
                    name = shortName,
                    rankName = rankName or "Unknown",
                    rankIndex = rankIndex or 99,
                    level = level or 0,
                    class = classFileName or "WARRIOR",
                    online = online and true or false,
                    publicNote = publicNote or "",
                    officerNote = officerNote or "",
                }
            end
        end
        local mainMap = {}
        for name, info in pairs(roster) do
            local main = MTR.GTGetMain(name) or name
            if not roster[main] then main = name end
            if not mainMap[main] then
                local owner = roster[main] or info
                mainMap[main] = { info = owner, alts = {}, rankIndex = owner.rankIndex or 99, rankName = owner.rankName or "Unknown" }
            end
            if name ~= main then table.insert(mainMap[main].alts, info) end
        end
        for mainName, node in pairs(mainMap) do
            local key = tostring(node.rankIndex) .. "|" .. node.rankName
            if not ranks[key] then
                ranks[key] = { rankIndex = node.rankIndex, rankName = node.rankName, mains = {} }
            end
            table.insert(ranks[key].mains, { name = mainName, info = node.info, alts = node.alts })
        end
        local ordered = {}
        for _, rank in pairs(ranks) do
            table.sort(rank.mains, function(a, b)
                local ao, bo = a.info.online and 1 or 0, b.info.online and 1 or 0
                if ao ~= bo then return ao > bo end
                return a.name:lower() < b.name:lower()
            end)
            for _, main in ipairs(rank.mains) do
                table.sort(main.alts, function(a, b) return a.name:lower() < b.name:lower() end)
            end
            table.insert(ordered, rank)
        end
        table.sort(ordered, function(a, b)
            if a.rankIndex ~= b.rankIndex then return a.rankIndex < b.rankIndex end
            return a.rankName:lower() < b.rankName:lower()
        end)
        return ordered
    end

    local function isRankShown(rankName)
        if t._gtMultiRank then
            local any = false
            for _ in pairs(t._gtRankSelected) do any = true break end
            if not any then return true end
            return t._gtRankSelected[rankName] == true
        end
        return t._gtSingleRank == nil or t._gtSingleRank == rankName
    end

    local function updateRankButtons(ranks)
        for _, b in ipairs(rankButtons) do b:Hide() end
        wipe(rankButtons)
        local y = -28
        local function isSelected(rankName)
            if t._gtMultiRank then
                local any = false
                for _ in pairs(t._gtRankSelected) do any = true break end
                if not any then return true end
                return t._gtRankSelected[rankName] == true
            end
            return t._gtSingleRank == nil or t._gtSingleRank == rankName
        end
        for _, rank in ipairs(ranks) do
            local b = CreateFrame("Button", nil, sidebar, "UIPanelButtonTemplate")
            b:SetSize(116, 20)
            b:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 8, y)
            b:SetText(rank.rankName)
            b._rankName = rank.rankName
            local selected = isSelected(rank.rankName)
            b:SetAlpha(selected and 1 or 0.55)
            b:SetScript("OnClick", function()
                if t._gtMultiRank then
                    t._gtRankSelected[rank.rankName] = not t._gtRankSelected[rank.rankName] or nil
                else
                    if t._gtSingleRank == rank.rankName then t._gtSingleRank = nil else t._gtSingleRank = rank.rankName end
                end
                if MTR.RefreshGuildTree then MTR.RefreshGuildTree() end
            end)
            table.insert(rankButtons, b)
            y = y - 24
        end
    end

    local function render()
        local ranks = buildTreeData()
        updateRankButtons(ranks)
        local query = string.lower((t._gtSearch or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        local rowH = t._gtCompact and 15 or 18
        local y = 0
        local idx = 0
        local shownMains, shownAlts = 0, 0

        local function showRow(kind, indent, text, meta, alpha)
            idx = idx + 1
            local row = acquireRow(idx)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", content, "RIGHT", -4, 0)
            row:SetHeight(rowH)
            row.label:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
            row.label:SetText(text or "")
            row.meta:SetText(meta or "")
            row:Show()
            row.label:SetAlpha(alpha or 1)
            row.meta:SetAlpha(alpha or 1)
            if kind == "rank" then row.bg:SetVertexColor(0.18, 0.05, 0.05, 0.50)
            elseif kind == "main" then row.bg:SetVertexColor(0.08, 0.08, 0.10, 0.35)
            else row.bg:SetVertexColor(0, 0, 0, 0) end
            y = y + rowH
            return row
        end

        for _, rank in ipairs(ranks) do
            if isRankShown(rank.rankName) then
                local mainsInRank = 0
                for _, main in ipairs(rank.mains) do
                    local textBlob = string.lower(main.name .. " " .. (main.info.rankName or ""))
                    for _, alt in ipairs(main.alts) do textBlob = textBlob .. " " .. string.lower(alt.name) end
                    if query == "" or string.find(textBlob, query, 1, true) then mainsInRank = mainsInRank + 1 end
                end
                if mainsInRank > 0 or query == "" then
                    local rankRow = showRow("rank", 0, string.format("|cffd4af37%s|r", rank.rankName), string.format("%d mains", mainsInRank), 1)
                    rankRow:SetScript("OnClick", function()
                        if t._gtMultiRank then
                            t._gtRankSelected[rank.rankName] = not t._gtRankSelected[rank.rankName] or nil
                        else
                            if t._gtSingleRank == rank.rankName then t._gtSingleRank = nil else t._gtSingleRank = rank.rankName end
                        end
                        render()
                    end)

                    for _, main in ipairs(rank.mains) do
                        local textBlob = string.lower(main.name .. " " .. (main.info.rankName or ""))
                        for _, alt in ipairs(main.alts) do textBlob = textBlob .. " " .. string.lower(alt.name) end
                        if query == "" or string.find(textBlob, query, 1, true) then
                            shownMains = shownMains + 1
                            local expanded = t._gtExpandedMains[main.name] == true
                            local arrow = expanded and "▼" or "▶"
                            local dot = main.info.online and "|cff00ff00•|r" or "|cff666666•|r"
                            local label = string.format("%s %s %s%s|r |cffaaaaaaLv%d|r", arrow, dot, CC(main.info.class), main.name, main.info.level or 0)
                            local meta = (#main.alts > 0) and string.format("%d alts", #main.alts) or (main.info.rankName or "")
                            local mainRow = showRow("main", 8, label, meta, 1)
                            mainRow:SetScript("OnClick", function()
                                t._gtExpandedMains[main.name] = not expanded or nil
                                render()
                            end)
                            mainRow:SetScript("OnDoubleClick", mainRow:GetScript("OnClick"))
                            if expanded then
                                for _, alt in ipairs(main.alts) do
                                    shownAlts = shownAlts + 1
                                    local adot = alt.online and "|cff00ff00•|r" or "|cff666666•|r"
                                    local altText = string.format("%s %s%s|r |cff888888Lv%d alt|r", adot, CC(alt.class), alt.name, alt.level or 0)
                                    showRow("alt", 28, altText, main.name, 1)
                                end
                            end
                        end
                    end
                    y = y + 4
                end
            end
        end

        for i = idx + 1, #rows do rows[i]:Hide() end
        content:SetHeight(math.max(y + 10, 520))
        if t._gtStatusLbl then
            local mode = t._gtMultiRank and "multi-rank" or (t._gtSingleRank or "all ranks")
            t._gtStatusLbl:SetText(string.format("|cffaaaaaa%d mains  %d alts  %s|r", shownMains, shownAlts, mode))
        end
    end

    searchEB:SetScript("OnTextChanged", function(self)
        t._gtSearch = self:GetText() or ""
        render()
    end)
    multiCK:SetScript("OnClick", function(self)
        t._gtMultiRank = self:GetChecked() and true or false
        if not t._gtMultiRank then wipe(t._gtRankSelected) end
        render()
    end)
    compactCK:SetScript("OnClick", function(self)
        t._gtCompact = self:GetChecked() and true or false
        render()
    end)
    expandBtn:SetScript("OnClick", function()
        local ranks = buildTreeData()
        for _, rank in ipairs(ranks) do
            for _, main in ipairs(rank.mains) do
                t._gtExpandedMains[main.name] = true
            end
        end
        render()
    end)
    collapseBtn:SetScript("OnClick", function()
        wipe(t._gtExpandedMains)
        render()
    end)
    refreshBtn:SetScript("OnClick", function()
        GuildRoster()
        MTR.After(0.5, function() ScanGuildNotes() render() end)
        MTR.After(1.5, function() ScanGuildNotes() render() end)
    end)

    t._renderTree = render
    MTR.RefreshGuildTree = function()
        if t and t:IsVisible() and t._renderTree then t._renderTree() end
    end

    GuildRoster()
    MTR.After(0.5, function() ScanGuildNotes() render() end)
    MTR.After(1.5, function() ScanGuildNotes() render() end)
end
