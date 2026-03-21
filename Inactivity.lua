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
local IW_PREFIX = "MekTownIW"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(IW_PREFIX) end

local function KKSanitize(s)
    s = tostring(s or "")
    s = s:gsub("[|,;]", " ")
    s = s:gsub("[%c]", " ")
    return s
end

local function InactCanonName(name)
    name = tostring(name or "")
    name = name:match("^%s*(.-)%s*$") or ""
    if name == "" then return "" end
    return name:match("^([^%-]+)") or name
end

local function IWState()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return { revision = 0, hash = "0", lastSyncAt = 0 } end
    gs.syncState = gs.syncState or {}
    gs.syncState.inactivityWhitelist = gs.syncState.inactivityWhitelist or { revision = 0, hash = "0", lastSyncAt = 0, lastAckByPeer = {} }
    return gs.syncState.inactivityWhitelist
end

local function IWBuildList(tbl)
    local out = {}
    for n, v in pairs(tbl or {}) do
        if v then
            local cn = InactCanonName(n)
            if cn ~= "" then out[#out + 1] = cn end
        end
    end
    table.sort(out)
    return out
end

local function IWHashList(list)
    return (MTR.Hash and MTR.Hash(table.concat(list or {}, ";"))) or tostring(#(list or {}))
end

local function IWRehash(touch)
    local wl = MTR.db and MTR.db.inactivityWhitelist or {}
    local list = IWBuildList(wl)
    local st = IWState()
    st.hash = IWHashList(list)
    if touch ~= false then
        st.revision = tonumber(st.revision or 0) + 1
    end
    st.lastSyncAt = time()
    return st, list
end

local function IWSend(msg)
    if not IsInGuild() then return false end
    if MTR.SendGuildScoped then return MTR.SendGuildScoped(IW_PREFIX, msg) end
    SendAddonMessage(IW_PREFIX, msg, "GUILD")
    return true
end

local function IWBroadcastSnapshot(reason)
    if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then return false end
    local st, list = IWRehash(reason ~= "peer-request")
    st.lastBroadcastAt = time()
    st.lastBroadcastReason = reason or "sync"
    IWSend(string.format("IW:MET:%d:%s:%d", tonumber(st.revision or 0), tostring(st.hash or "0"), #list))
    local chunk = ""
    for _, n in ipairs(list) do
        if #chunk + #n + 1 > 200 then
            if chunk ~= "" then IWSend("IW:D:" .. chunk) end
            chunk = n
        else
            chunk = (chunk == "" and n) or (chunk .. ";" .. n)
        end
    end
    if chunk ~= "" then IWSend("IW:D:" .. chunk) else IWSend("IW:D:") end
    IWSend("IW:END:" .. tostring(reason or "sync"))
    return true
end

local function IWApplyList(list, from)
    local wl = {}
    for _, n in ipairs(list or {}) do
        local cn = InactCanonName(n)
        if cn ~= "" then wl[cn] = true end
    end
    MTR.db.inactivityWhitelist = wl
    local st = IWState()
    st.lastSyncAt = time()
    st.lastSyncFrom = from or "?"
end

function MTR.InactSetWhitelist(name, enabled)
    if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then
        MTR.MPE("Officers only.")
        return false
    end
    local cn = InactCanonName(name)
    if cn == "" then return false end
    MTR.db.inactivityWhitelist = MTR.db.inactivityWhitelist or {}
    if enabled then MTR.db.inactivityWhitelist[cn] = true else MTR.db.inactivityWhitelist[cn] = nil end
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("inactivity", enabled and "whitelistAdd" or "whitelistRemove", cn) end
    IWBroadcastSnapshot(enabled and "whitelist-add" or "whitelist-remove")
    return true
end

function MTR.InactReplaceWhitelist(newTable)
    if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then
        MTR.MPE("Officers only.")
        return false
    end
    local wl = {}
    for n, v in pairs(newTable or {}) do
        if v then
            local cn = InactCanonName(n)
            if cn ~= "" then wl[cn] = true end
        end
    end
    MTR.db.inactivityWhitelist = wl
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("inactivity", "whitelistReplace", tostring(#IWBuildList(wl))) end
    IWBroadcastSnapshot("whitelist-replace")
    return true
end

local function KKState()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return { revision = 0, hash = "0", lastSyncAt = 0 } end
    gs.syncState = gs.syncState or {}
    gs.syncState.kick = gs.syncState.kick or { revision = 0, hash = "0", lastSyncAt = 0, lastAckByPeer = {} }
    return gs.syncState.kick
end

local function KKRehash()
    local log = ((MTR.GetGuildStore and MTR.GetGuildStore(true).inactivityKickLog) or MTR.db.inactivityKickLog) or {}
    local parts = {}
    for i, e in ipairs(log) do
        parts[i] = table.concat({ KKSanitize(e.date), KKSanitize(e.player), KKSanitize(e.rank), tostring(e.daysInactive or 0), KKSanitize(e.kickedBy), KKSanitize(e.id or "") }, "|")
    end
    local st = KKState()
    st.hash = (MTR.Hash and MTR.Hash(table.concat(parts, ";"))) or tostring(#parts)
    st.revision = tonumber(st.revision or 0) + 1
    st.lastSyncAt = time()
    return st
end

local function KKSend(msg)
    if not IsInGuild() then return false end
    if MTR.SendGuildScoped then return MTR.SendGuildScoped(KK_PREFIX, msg) end
    SendAddonMessage(KK_PREFIX, msg, "GUILD")
    return true
end

local function KKMakeId(entry)
    local seed = table.concat({ tostring(entry.player or ""), tostring(entry.date or ""), tostring(entry.kickedBy or ""), tostring(entry.daysInactive or 0) }, "|")
    return (MTR.Hash and MTR.Hash(seed)) or seed
end

-- Composite dedup key for kick entries
local function KKKey(e)
    local id = tostring(e.id or "")
    if id ~= "" then return "id|" .. id end
    return (e.player or "") .. "|" .. (e.date or "")
end

-- Merge one kick entry into the local log (dedup + cap at 200)
local function KKMergeEntry(entry)
    if not MTR.db then return false end
    local log = ((MTR.GetGuildStore and MTR.GetGuildStore(true).inactivityKickLog) or MTR.db.inactivityKickLog)
    local key = KKKey(entry)
    for _, existing in ipairs(log) do
        if KKKey(existing) == key then return false end
    end
    table.insert(log, entry)
    if #log > 200 then tremove(log, 1) end
    KKRehash()
    return true
end

local function KKBuildChunks()
    local log = ((MTR.GetGuildStore and MTR.GetGuildStore(true).inactivityKickLog) or MTR.db.inactivityKickLog) or {}
    local chunks, chunk = {}, ""
    for _, e in ipairs(log) do
        local token = table.concat({ KKSanitize(e.date), KKSanitize(e.player), KKSanitize(e.rank), tostring(e.daysInactive or 0), KKSanitize(e.kickedBy), KKSanitize(e.id or "") }, "|")
        if #chunk + #token + 1 > 200 then
            if chunk ~= "" then chunks[#chunks + 1] = chunk end
            chunk = token
        else
            chunk = (chunk == "" and token) or (chunk .. ";" .. token)
        end
    end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    return chunks, #log
end

local function KKSendSnapshot(reason)
    if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then return false end
    local st = KKState()
    local chunks, count = KKBuildChunks()
    local raw = table.concat(chunks, ";")
    local hash = (MTR.Hash and MTR.Hash(raw)) or tostring(#raw)
    st.hash = hash
    st.lastBroadcastAt = time()
    st.lastBroadcastReason = reason or "sync"
    KKSend(string.format("KK:MET:%s:%s:%d", tostring(st.revision or 0), tostring(hash), count or 0))
    for _, c in ipairs(chunks) do KKSend("KK:D:" .. c) end
    if #chunks == 0 then KKSend("KK:D:") end
    KKSend("KK:END:" .. KKSanitize(reason or "sync"))
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
    entry.id = KKMakeId(entry)
    -- Store locally first (the kicker always has the record)
    KKMergeEntry(entry)
    if MTR.AppendGuildEvent then MTR.AppendGuildEvent("inactivity", "kick", table.concat({entry.player or "", tostring(entry.daysInactive or 0), entry.kickedBy or ""}, "|")) end
    -- Broadcast to all online guild members with the addon
    if IsInGuild() then
        local rank_s  = entry.rank:gsub("|", ""):gsub(",", "")
        local days_s  = tostring(math.floor(entry.daysInactive))
        local packet  = "KK:"
            .. entry.date        .. "|"
            .. entry.player      .. "|"
            .. rank_s            .. "|"
            .. days_s            .. "|"
            .. entry.kickedBy    .. "|"
            .. KKSanitize(entry.id or "")
        KKSend(packet)
        MTR.dprint("[KK Sync] Broadcast kick:", entry.player)
    end
end

-- Receive handler
local kkAddonFrame = CreateFrame("Frame")
kkAddonFrame:RegisterEvent("CHAT_MSG_ADDON")
local kkRecv = nil
kkAddonFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= KK_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end

    local unpacked, senderName = (MTR.UnpackGuildScoped and MTR.UnpackGuildScoped(message, sender, false)) or message, ((sender or ""):match("^([^%-]+)") or "")
    if not unpacked then return end
    if senderName == MTR.playerName then return end  -- ignore own echo

    if unpacked:sub(1, 7) == "KK:REQ:" then
        local _, knownHash = unpacked:match("^KK:REQ:([^:]*):?(.*)$")
        if knownHash and knownHash ~= "" then
            local st = KKState()
            if tostring(knownHash) == tostring(st.hash or "0") then return end
        end
        if MTR.CanAccess and MTR.CanAccess("Inactive") then KKSendSnapshot("peer-request") end
        return
    elseif unpacked:sub(1, 7) == "KK:MET:" then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local rev, hash = unpacked:match("^KK:MET:([^:]+):([^:]+):")
        
        -- Auto-clear conflict if header hash matches local hash
        if hash then
            local st = KKState()
            if tostring(hash) == tostring(st.hash or "0") then
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
                -- Adopt higher revision if hashes match
                if rev and tonumber(rev) > tonumber(st.revision or 0) then
                    st.revision = tonumber(rev)
                end
            end
        end

        kkRecv = { rev = tonumber(rev) or 0, hash = hash or "0", chunks = {}, from = senderName }
        return
    elseif unpacked:sub(1, 5) == "KK:D:" and kkRecv then
        kkRecv.chunks[#kkRecv.chunks + 1] = unpacked:sub(6)
        return
    elseif unpacked:sub(1, 7) == "KK:END:" and kkRecv then
        local st = KKState()
        if tonumber(kkRecv.rev or 0) < tonumber(st.revision or 0) then kkRecv = nil return end
        local raw = table.concat(kkRecv.chunks, ";")
        local hash = (MTR.Hash and MTR.Hash(raw)) or tostring(#raw)
        if hash ~= tostring(kkRecv.hash or "") and #kkRecv.chunks > 0 then
            local stc = KKState()
            stc.lastConflictAt = time()
            stc.lastConflictFrom = tostring(kkRecv.from or "?")
            stc.lastConflictReason = "hash-mismatch"
            MTR.MPE("[Kick Sync] Hash mismatch from " .. tostring(kkRecv.from or "?") .. "; keeping local state.")
            kkRecv = nil
            return
        end
        for _, chunk in ipairs(kkRecv.chunks) do
            for token in tostring(chunk or ""):gmatch("[^;]+") do
                local dt, player, rank, days, kickedBy, eid = token:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
                if not dt then
                    dt, player, rank, days, kickedBy = token:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
                end
                if dt and player then
                    KKMergeEntry({
                        date = dt,
                        player = player,
                        rank = rank,
                        daysInactive = tonumber(days) or 0,
                        kickedBy = kickedBy,
                        id = eid,
                    })
                end
            end
        end
        local st2 = KKState()
        st2.revision = math.max(tonumber(st2.revision or 0), tonumber(kkRecv.rev or 0))
        st2.hash = tostring(kkRecv.hash or st2.hash or "0")
        st2.lastSyncAt = time()
        KKSend(string.format("KK:ACK:%s:%s:%d", KKSanitize(MTR.playerName or "?"), tostring(st2.hash or "0"), tonumber(st2.revision or 0)))
        kkRecv = nil
        return
    elseif unpacked:sub(1, 7) == "KK:ACK:" then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local peer, hash, rev = unpacked:match("^KK:ACK:([^:]+):([^:]+):([^:]+)$")
        local st = KKState()
        if tostring(hash or "") == tostring(st.hash or "0") then
            local r = tonumber(rev) or 0
            if r > tonumber(st.revision or 0) then st.revision = r end
            st.lastAckByPeer = st.lastAckByPeer or {}
            st.lastAckByPeer[peer or senderName or "?"] = { revision = r, at = time() }
        end
        return
    end

    if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
    -- Parse: "KK:date|player|rank|days|kickedBy|id"
    local payload = unpacked:sub(4)   -- strip "KK:" prefix
    local dt, player, rank, days, kickedBy, eid =
        payload:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    if not dt then
        dt, player, rank, days, kickedBy = payload:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
    end
    if not dt then return end

    local entry = {
        date         = dt,
        player       = player,
        rank         = rank,
        daysInactive = tonumber(days) or 0,
        kickedBy     = kickedBy,
        id           = eid,
    }
    if KKMergeEntry(entry) then
        MTR.dprint("[KK Sync] Merged kick entry for", player, "from", senderName)
    end
end)

local kkInit = CreateFrame("Frame")
kkInit:RegisterEvent("PLAYER_LOGIN")
kkInit:SetScript("OnEvent", function()
    MTR.After(14, function()
        if not IsInGuild() then return end
        local st = KKState()
        KKSend("KK:REQ:" .. KKSanitize(MTR.playerName or "?") .. ":" .. tostring(st.hash or "0"))
    end)
end)

local iwRecv = nil
local iwFrame = CreateFrame("Frame")
iwFrame:RegisterEvent("CHAT_MSG_ADDON")
iwFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= IW_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end

    local unpacked, senderName = (MTR.UnpackGuildScoped and MTR.UnpackGuildScoped(message, sender, false)) or message, ((sender or ""):match("^([^%-]+)") or "")
    if not unpacked then return end
    if senderName == MTR.playerName then return end

    if unpacked:sub(1, 7) == "IW:REQ:" then
        local _, knownHash = unpacked:match("^IW:REQ:([^:]*):?(.*)$")
        if knownHash and knownHash ~= "" then
            local st = IWState()
            if tostring(knownHash) == tostring(st.hash or "0") then return end
        end
        if MTR.CanAccess and MTR.CanAccess("Inactive") then IWBroadcastSnapshot("peer-request") end
        return
    elseif unpacked:sub(1, 7) == "IW:MET:" then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local rev, hash = unpacked:match("^IW:MET:([^:]+):([^:]+):")
        
        -- Auto-clear conflict if header hash matches local hash
        if hash then
            local st = IWState()
            if tostring(hash) == tostring(st.hash or "0") then
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
                -- Adopt higher revision if hashes match
                if rev and tonumber(rev) > tonumber(st.revision or 0) then
                    st.revision = tonumber(rev)
                end
            end
        end

        iwRecv = { rev = tonumber(rev) or 0, hash = hash or "0", names = {}, from = senderName }
        return
    elseif unpacked:sub(1, 5) == "IW:D:" and iwRecv then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        for token in unpacked:sub(6):gmatch("[^;]+") do
            local cn = InactCanonName(token)
            if cn ~= "" then iwRecv.names[#iwRecv.names + 1] = cn end
        end
        return
    elseif unpacked:sub(1, 7) == "IW:END:" and iwRecv then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local st = IWState()
        local incomingRev = tonumber(iwRecv.rev) or 0
        if incomingRev < tonumber(st.revision or 0) then iwRecv = nil return end
        local sorted = IWBuildList((function()
            local t = {}
            for _, n in ipairs(iwRecv.names) do t[n] = true end
            return t
        end)())
        local hash = (MTR.Hash and MTR.Hash(table.concat(sorted, ";"))) or tostring(#sorted)
        if #sorted > 0 and hash ~= tostring(iwRecv.hash or "") then
            st.lastConflictAt = time()
            st.lastConflictFrom = tostring(iwRecv.from or "?")
            st.lastConflictReason = "hash-mismatch"
            MTR.MPE("[Inactivity WL Sync] Hash mismatch from " .. tostring(iwRecv.from or "?") .. "; keeping local state.")
            iwRecv = nil
            return
        end
        IWApplyList(sorted, iwRecv.from)
        st.revision = incomingRev
        st.hash = hash
        st.lastSyncAt = time()
        IWSend(string.format("IW:ACK:%s:%s:%d", KKSanitize(MTR.playerName or "?"), tostring(st.hash or "0"), tonumber(st.revision or 0)))
        if MTR.RefreshInactiveConfig then pcall(MTR.RefreshInactiveConfig) end
        iwRecv = nil
        return
    elseif unpacked:sub(1, 7) == "IW:ACK:" then
        if MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then return end
        local peer, hash, rev = unpacked:match("^IW:ACK:([^:]+):([^:]+):([^:]+)$")
        local st = IWState()
        if tostring(hash or "") == tostring(st.hash or "0") then
            local r = tonumber(rev) or 0
            if r > tonumber(st.revision or 0) then st.revision = r end
            st.lastAckByPeer = st.lastAckByPeer or {}
            st.lastAckByPeer[peer or senderName or "?"] = { revision = r, at = time() }
        end
    end
end)

local iwInit = CreateFrame("Frame")
iwInit:RegisterEvent("PLAYER_LOGIN")
iwInit:SetScript("OnEvent", function()
    MTR.After(15, function()
        if not IsInGuild() then return end
        local st = IWState()
        IWSend("IW:REQ:" .. KKSanitize(MTR.playerName or "?") .. ":" .. tostring(st.hash or "0"))
    end)
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

        if name and name ~= "" then
            if online then
                -- Currently online — record seen timestamp, skip inactivity check
                seenLog[name] = now
            else
                -- OFFLINE — always check for inactivity
                local cn = InactCanonName(name)
                if not (MTR.db.inactivityWhitelist or {})[cn] then
                    local threshold = InactGetThreshold(rankName or "")
                    if threshold ~= "never" then

                    local years, months, days, hours = GetGuildRosterLastOnline(i)
                    local totalDays = 0
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
-- KICK POPUP
-- ============================================================================
local kickPopup = nil

function MTR.InactShowKickPopup(inactiveList)
    if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then MTR.MPE("No permission for inactivity kick tools.") return end
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
    sub:SetText("|cffaaaaaa Requires Inactive tool permission to kick.|r")

    local xBtn = CreateFrame("Button", nil, kickPopup, "UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT", kickPopup, "TOPRIGHT", -6, -6)

    local sep = kickPopup:CreateTexture(nil, "ARTWORK")
    sep:SetTexture("Interface\\Buttons\\WHITE8x8")
    sep:SetVertexColor(0.65, 0.20, 0.08, 0.50)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", kickPopup, "TOPLEFT", 12, -48)
    sep:SetPoint("TOPRIGHT", kickPopup, "TOPRIGHT", -12, -48)

    local sf = CreateFrame("ScrollFrame", nil, kickPopup, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",     kickPopup, "TOPLEFT",    12, -68)
    sf:SetPoint("BOTTOMRIGHT", kickPopup, "BOTTOMRIGHT", -28, 52)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(410, math.max(300, #inactiveList * 24 + 22))
    sf:SetScrollChild(content)

    local hSel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hSel:SetPoint("TOPLEFT", content, "TOPLEFT", 4, 0)
    hSel:SetText("Sel")
    local hName = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hName:SetPoint("TOPLEFT", content, "TOPLEFT", 36, 0)
    hName:SetText("Character")
    local hRank = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hRank:SetPoint("TOPLEFT", content, "TOPLEFT", 182, 0)
    hRank:SetText("Rank")
    local hDays = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hDays:SetPoint("TOPLEFT", content, "TOPLEFT", 306, 0)
    hDays:SetText("Inactive")

    local rowChecks = {}
    for i, entry in ipairs(inactiveList) do
        local cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i-1)*24 - 16)
        cb:SetChecked(false)
        rowChecks[#rowChecks + 1] = { cb = cb, entry = entry }

        local nameFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameFS:SetPoint("TOPLEFT", content, "TOPLEFT", 36, -(i-1)*24 - 16)
        nameFS:SetWidth(138)
        nameFS:SetWordWrap(false)
        nameFS:SetText(MTR.Trunc(entry.name, 20))

        local rankFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        rankFS:SetPoint("TOPLEFT", content, "TOPLEFT", 182, -(i-1)*24 - 16)
        rankFS:SetWidth(116)
        rankFS:SetWordWrap(false)
        rankFS:SetText(MTR.Trunc(entry.rank, 16))

        local row = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 306, -(i-1)*24 - 16)
        local col = (entry.days >= (entry.threshold * 2)) and "|cffff4444" or "|cffffaa00"
        row:SetWidth(100)
        row:SetWordWrap(false)
        row:SetText(string.format("%s%s|r", col, MTR.FormatDays(entry.days)))
    end

    local selCount = kickPopup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    selCount:SetPoint("BOTTOMLEFT", kickPopup, "BOTTOMLEFT", 12, 72)
    selCount:SetText("Selected: 0")

    local function RefreshSelectedCount()
        local n = 0
        for _, row in ipairs(rowChecks) do if row.cb:GetChecked() then n = n + 1 end end
        selCount:SetText("Selected: " .. tostring(n))
    end
    for _, row in ipairs(rowChecks) do row.cb:SetScript("OnClick", RefreshSelectedCount) end

    local saBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    saBtn:SetSize(108, 22)
    saBtn:SetPoint("BOTTOMLEFT", kickPopup, "BOTTOMLEFT", 12, 44)
    saBtn:SetText("Select All")
    saBtn:SetScript("OnClick", function()
        for _, row in ipairs(rowChecks) do row.cb:SetChecked(true) end
        RefreshSelectedCount()
    end)

    local snBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    snBtn:SetSize(108, 22)
    snBtn:SetPoint("LEFT", saBtn, "RIGHT", 6, 0)
    snBtn:SetText("Select None")
    snBtn:SetScript("OnClick", function()
        for _, row in ipairs(rowChecks) do row.cb:SetChecked(false) end
        RefreshSelectedCount()
    end)

    local ksBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    ksBtn:SetSize(124, 24)
    ksBtn:SetPoint("BOTTOMLEFT", kickPopup, "BOTTOMLEFT", 12, 14)
    ksBtn:SetText("|cffff4444Kick Selected|r")
    ksBtn:SetScript("OnClick", function()
        local toKick = {}
        for _, row in ipairs(rowChecks) do
            if row.cb:GetChecked() then toKick[#toKick + 1] = row.entry end
        end
        if #toKick == 0 then
            MTR.MP("No players selected.")
            return
        end
        StaticPopupDialogs["MEKTOWN_KICK_SEL"] = {
            text = "Kick " .. #toKick .. " selected inactive members?\nThis cannot be undone.",
            button1 = "Yes, kick", button2 = "Cancel",
            OnAccept = function()
                for _, entry in ipairs(toKick) do
                    GuildUninvite(entry.name)
                    MTR.KickBroadcast(entry.name, entry.rank, entry.days, MTR.playerName)
                end
                MTR.MP("Kicked " .. #toKick .. " selected member(s).")
                kickPopup:Hide()
            end,
            timeout=0, whileDead=true, hideOnEscape=true,
        }
        StaticPopup_Show("MEKTOWN_KICK_SEL")
    end)

    -- Review One by One button
    local reviewIdx = 1
    local rvBtn = CreateFrame("Button", nil, kickPopup, "UIPanelButtonTemplate")
    rvBtn:SetSize(148, 24)
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
    dimBtn:SetSize(100, 24)
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
            if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then MTR.MP("|cffaaaaaa(No permission to kick)|r") end
        end
    end)
end
