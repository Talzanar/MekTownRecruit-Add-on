-- ============================================================================
-- DKP.lua  v5.0
-- Ledger core, bulk award, DKP sync, chat announce helper
-- ============================================================================
local MTR = MekTownRecruit

local DKP_ADDON_PREFIX = "MekTownDKP"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(DKP_ADDON_PREFIX) end
MTR.DKP_ADDON_PREFIX = DKP_ADDON_PREFIX

-- Queue of pending history entries — declared here so DKPAdd/DKPSet can push
-- to it immediately. Drained by DKPSyncToRaidSafe via DHFlushQueue().
local dhQueue = {}

-- ============================================================================
-- LEDGER CORE
-- ============================================================================
function MTR.DKPEnsure(name)
    if not MTR.db.dkpLedger[name] then
        MTR.db.dkpLedger[name] = { balance = 0, history = {} }
    end
end

function MTR.DKPAdd(name, amount, reason, officer)
    MTR.DKPEnsure(name)
    local e = MTR.db.dkpLedger[name]
    e.balance = e.balance + amount
    local entry = {
        date    = date("%Y-%m-%d %H:%M:%S"),
        amount  = amount,
        balance = e.balance,
        reason  = reason or "Manual",
        officer = officer or MTR.playerName or "System",
    }
    table.insert(e.history, entry)
    if #e.history > 200 then tremove(e.history, 1) end
    if MTR.DKPTouchLedger then MTR.DKPTouchLedger() end
    -- Queue for history broadcast (flushed by the debounced sync below)
    dhQueue[#dhQueue + 1] = { playerName = name, entry = entry }
    -- Debounced auto-sync: coalesces rapid bulk awards into one sync 3s after last change
    MTR.TickRemove("dkp_autosync")
    MTR.TickAdd("dkp_autosync", 3, function()
        MTR.TickRemove("dkp_autosync")
        if MTR.isOfficer and IsInGuild() then MTR.DKPSyncToRaidSafe() end
    end)
end

function MTR.DKPSet(name, amount, officer)
    MTR.DKPEnsure(name)
    local e   = MTR.db.dkpLedger[name]
    local old = e.balance
    e.balance = amount
    local entry = {
        date    = date("%Y-%m-%d %H:%M:%S"),
        amount  = amount - old,
        balance = e.balance,
        reason  = "Balance set by officer (was " .. old .. ")",
        officer = officer or MTR.playerName or "System",
    }
    table.insert(e.history, entry)
    if #e.history > 200 then tremove(e.history, 1) end
    if MTR.DKPTouchLedger then MTR.DKPTouchLedger() end
    -- Queue for history broadcast (flushed next time DKPSyncToRaidSafe fires)
    dhQueue[#dhQueue + 1] = { playerName = name, entry = entry }
end

function MTR.DKPBalance(name)
    MTR.DKPEnsure(name)
    return MTR.db.dkpLedger[name].balance
end

-- Standings sorted by balance desc, ties broken alphabetically
function MTR.DKPStandings()
    local list = {}
    for name, data in pairs(MTR.db.dkpLedger) do
        list[#list+1] = { name = name, balance = data.balance }
    end
    table.sort(list, function(a, b)
        if a.balance ~= b.balance then return a.balance > b.balance end
        return a.name < b.name
    end)
    return list
end

function MTR.DKPPublish(channel, target)
    if not MTR.isOfficer then MTR.MPE("Officers only.") return end
    local chan = (channel or MTR.db.dkpPublishChannel):upper()
    local standings = MTR.DKPStandings()
    local function Send(msg)
        if chan == "WHISPER" then
            if not target then MTR.MPE("Specify: /mek dkp publish whisper Name") return end
            MTR.SendChatSafe(msg, "WHISPER", nil, target)
        else
            MTR.SendChatSafe(msg, chan)
        end
    end
    Send("=== MekTown DKP Standings ===")
    for i, entry in ipairs(standings) do
        Send(string.format("%d. %s - %d pts", i, entry.name, entry.balance))
        if i >= 20 then Send("... (" .. #standings .. " total - see /mek config for full list)") break end
    end
end

-- ============================================================================
-- BULK AWARD
-- ============================================================================
function MTR.DKPBulkAward(names, amount, reason)
    if not MTR.isOfficer then MTR.MPE("Officers only.") return end
    local count = 0
    for _, name in ipairs(names) do
        MTR.DKPAdd(name, amount, reason or "Bulk award", MTR.playerName)
        count = count + 1
    end
    MTR.MP("Awarded " .. amount .. " DKP to " .. count .. " players: " .. (reason or "Bulk award"))
end

function MTR.DKPGetRaidMembers()
    local members = {}
    if IsInRaid() then
        for i = 1, GetNumRaidMembers() do
            local n = UnitName("raid"..i)
            if n then members[#members+1] = n end
        end
    elseif IsInGroup() then
        members[#members+1] = MTR.playerName
        for i = 1, GetNumPartyMembers() do
            local n = UnitName("party"..i)
            if n then members[#members+1] = n end
        end
    end
    return members
end

-- ============================================================================
-- CHAT ANNOUNCE HELPER
-- Posts to RAID when in a raid, PARTY in a party, GUILD as fallback.
-- Optional raid warning fires additionally for raid leaders / assistants.
-- ============================================================================
function MTR.DKPAnnounce(msg, useRW)
    local chan
    if IsInRaid() then
        chan = "RAID"
    elseif IsInGroup() then
        chan = "PARTY"
    else
        chan = "GUILD"
    end
    MTR.SendChatSafe(msg, chan)
    if useRW and IsInRaid() and (IsRaidLeader() or UnitIsGroupAssistant("player")) then
        MTR.SendChatSafe(msg, "RAID_WARNING")
    end
end

-- ============================================================================
-- DKP HISTORY SYNC  (prefix "MekTownDH")
--
-- Previously only balances were broadcast. Transaction history (date, amount,
-- reason, officer) never left the awarding client, so "History" buttons on
-- other officers' screens showed incomplete records.
--
-- Design:
--   • DKPAdd / DKPSet push every new history entry into dhQueue[].
--   • DKPSyncToRaidSafe flushes dhQueue immediately after the balance
--     broadcast so bulk awards coalesce into ONE history flush, not N.
--   • Receivers merge entries using a composite dedup key
--     (playerName .. date .. amount) — safe to receive the same sync twice.
--
-- Wire format (GUILD channel, prefix "MekTownDH"):
--   DH:S:senderName      — batch start; identifies the broadcasting officer
--   DH:D:entry,entry,…   — data chunk; entries are pipe-delimited fields
--   DH:E                 — commit; receiver merges buffered entries
--
-- Entry format: "playerName|date|amount|balance|reason|officer"
--   Pipes and commas inside reason are stripped on encode.
--   Reason is capped at 60 chars.  Max encoded entry = 121 chars.
--   Chunks are capped at 200 chars → full packet always under 255.
-- ============================================================================
local DH_PREFIX = "MekTownDH"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(DH_PREFIX) end

-- Queue of pending history entries; drained by DKPSyncToRaidSafe.
-- (declared at top of file)

-- Utility: strip realm suffix "Name-Realm" → "Name"
local function StripRealm(s) return (s or ""):match("^([^%-]+)") or (s or "") end

local function EnsureDKPSyncState()
    MekTownRecruitDB = MekTownRecruitDB or {}
    MekTownRecruitDB.syncState = MekTownRecruitDB.syncState or {}
    MekTownRecruitDB.syncState.dkp = MekTownRecruitDB.syncState.dkp or {
        revision = 0,
        hash = "0",
        lastFullSyncAt = 0,
        lastFullSyncFrom = "",
        lastAckByPeer = {},
    }
    return MekTownRecruitDB.syncState.dkp
end

local function SanitizeField(v)
    v = tostring(v or "")
    v = v:gsub("[\r\n]", " ")
    v = v:gsub("[|;,~^]", " ")
    return v
end

local function BuildSnapshotRecords()
    local players = {}
    for name in pairs(MTR.db.dkpLedger or {}) do
        players[#players + 1] = name
    end
    table.sort(players)

    local records, entryCount = {}, 0
    for _, name in ipairs(players) do
        local node = MTR.db.dkpLedger[name] or { balance = 0, history = {} }
        local hist = {}
        for i, entry in ipairs(node.history or {}) do
            hist[i] = table.concat({
                SanitizeField(entry.date),
                tostring(tonumber(entry.amount) or 0),
                tostring(tonumber(entry.balance) or 0),
                SanitizeField(entry.reason),
                SanitizeField(entry.officer),
            }, "~")
            entryCount = entryCount + 1
        end
        records[#records + 1] = table.concat({
            SanitizeField(name),
            tostring(tonumber(node.balance) or 0),
            table.concat(hist, "!")
        }, "^")
    end
    return records, #players, entryCount
end

local function SnapshotPayloadFromRecords(records)
    return table.concat(records, ";")
end

local function SnapshotHashFromRecords(records)
    return MTR.Hash(SnapshotPayloadFromRecords(records))
end

function MTR.DKPTouchLedger()
    local st = EnsureDKPSyncState()
    st.revision = (st.revision or 0) + 1
    local records, playerCount, entryCount = BuildSnapshotRecords()
    st.hash = SnapshotHashFromRecords(records)
    st.playerCount = playerCount
    st.entryCount = entryCount
    st.lastMutationAt = time()
    return st
end

function MTR.DKPGetSyncState()
    return EnsureDKPSyncState()
end

local function EnsureSyncStateFresh()
    local st = EnsureDKPSyncState()
    if not st.hash or st.hash == "0" then
        MTR.DKPTouchLedger()
    end
    return st
end

local function DecodeSnapshotPayload(raw)
    local ledger = {}
    if not raw or raw == "" then return ledger end
    for playerRec in raw:gmatch("[^;]+") do
        local name, bal, histBlob = playerRec:match("^([^%^]+)%^([^%^]+)%^(.*)$")
        if name and bal then
            ledger[name] = { balance = tonumber(bal) or 0, history = {} }
            if histBlob and histBlob ~= "" then
                for histRec in histBlob:gmatch("[^!]+") do
                    local dt, amt, hbal, reason, officer =
                        histRec:match("^([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
                    ledger[name].history[#ledger[name].history + 1] = {
                        date = dt or "",
                        amount = tonumber(amt) or 0,
                        balance = tonumber(hbal) or 0,
                        reason = reason or "",
                        officer = officer or "",
                    }
                end
            end
        end
    end
    return ledger
end

local function ApplyFullSnapshot(ledger, senderName)
    if not ledger or type(ledger) ~= "table" then return 0, 0 end
    local players, entries = 0, 0
    MTR.db.dkpLedger = {}
    for name, node in pairs(ledger) do
        local hist = node.history or {}
        if #hist > 200 then
            local trimmed = {}
            for i = math.max(1, #hist - 199), #hist do
                trimmed[#trimmed + 1] = hist[i]
            end
            hist = trimmed
        end
        MTR.db.dkpLedger[name] = {
            balance = tonumber(node.balance) or 0,
            history = hist,
        }
        players = players + 1
        entries = entries + #hist
    end
    local st = MTR.DKPTouchLedger()
    st.lastFullSyncAt = time()
    st.lastFullSyncFrom = senderName or ""
    return players, entries
end

-- Encode one entry into a pipe-delimited token safe for addon messaging.
local function DHEncodeEntry(playerName, entry)
    local reason = (entry.reason or ""):gsub("|", ""):gsub(",", "")
    if #reason > 60 then reason = reason:sub(1, 60) end
    return playerName
        .. "|" .. (entry.date    or "")
        .. "|" .. tostring(entry.amount  or 0)
        .. "|" .. tostring(entry.balance or 0)
        .. "|" .. reason
        .. "|" .. (entry.officer or "")
end

-- Decode a pipe-delimited token back into { playerName, entry }.
-- Returns nil if the token is malformed.
local function DHDecodeEntry(str)
    local player, dt, amt, bal, reason, officer =
        str:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]*)|([^|]*)$")
    if not player then return nil end
    return {
        playerName = player,
        entry = {
            date    = dt,
            amount  = tonumber(amt)  or 0,
            balance = tonumber(bal)  or 0,
            reason  = reason  or "",
            officer = officer or "",
        }
    }
end

-- Composite dedup key: same transaction from two syncs must not double-insert.
local function DHKey(playerName, entry)
    return playerName .. "|" .. (entry.date or "") .. "|" .. tostring(entry.amount or 0)
end

-- Merge one decoded entry into the local ledger (dedup + cap at 200).
local function DHMergeEntry(playerName, entry)
    if not MTR.db or not playerName or not entry then return false end
    MTR.DKPEnsure(playerName)
    local hist = MTR.db.dkpLedger[playerName].history
    local key  = DHKey(playerName, entry)
    for _, existing in ipairs(hist) do
        if DHKey(playerName, existing) == key then
            return false  -- already present
        end
    end
    table.insert(hist, entry)
    if #hist > 200 then tremove(hist, 1) end
    return true
end

-- Flush dhQueue as a chunked DH:S/D/E broadcast.
-- Called by DKPSyncToRaidSafe after the balance broadcast.
local function DHFlushQueue()
    if #dhQueue == 0 then return end
    if not MTR.isOfficer then dhQueue = {} return end
    if not IsInGuild()    then dhQueue = {} return end

    SendAddonMessage(DH_PREFIX, "DH:S:" .. (MTR.playerName or ""), "GUILD")

    local chunk = ""
    for _, item in ipairs(dhQueue) do
        local encoded = DHEncodeEntry(item.playerName, item.entry)
        if #chunk + #encoded + 1 > 200 then
            SendAddonMessage(DH_PREFIX, "DH:D:" .. chunk, "GUILD")
            chunk = encoded
        else
            chunk = chunk == "" and encoded or (chunk .. "," .. encoded)
        end
    end
    if chunk ~= "" then
        SendAddonMessage(DH_PREFIX, "DH:D:" .. chunk, "GUILD")
    end
    SendAddonMessage(DH_PREFIX, "DH:E", "GUILD")

    MTR.dprint("[DH Sync] Flushed", #dhQueue, "history entries to guild.")
    dhQueue = {}
end

-- DH receive handler
local dhRecvBuf    = nil
local dhRecvSender = nil
local dhAddonFrame = CreateFrame("Frame")
dhAddonFrame:RegisterEvent("CHAT_MSG_ADDON")
dhAddonFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= DH_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end

    local senderName = StripRealm(sender)
    if senderName == MTR.playerName then return end  -- ignore own echo

    if message:sub(1, 5) == "DH:S:" then
        dhRecvBuf    = {}
        dhRecvSender = message:sub(6)
        if dhRecvSender == "" then dhRecvSender = senderName end

    elseif message:sub(1, 5) == "DH:D:" and dhRecvBuf then
        for token in message:sub(6):gmatch("[^,]+") do
            local decoded = DHDecodeEntry(token)
            if decoded then
                dhRecvBuf[#dhRecvBuf + 1] = decoded
            end
        end

    elseif message == "DH:E" and dhRecvBuf then
        local merged = 0
        for _, item in ipairs(dhRecvBuf) do
            if DHMergeEntry(item.playerName, item.entry) then
                merged = merged + 1
            end
        end
        if merged > 0 then
            MTR.MP(string.format(
                "[DKP History] Received %d new transaction(s) from %s.",
                merged, dhRecvSender or "?"))
        end
        dhRecvBuf    = nil
        dhRecvSender = nil
    end
end)

-- ============================================================================
-- DKP BALANCE SYNC  (prefix "MekTownDKP")
-- Sends current balances to all online guild members with the addon.
-- Uses GUILD channel so it works whether in a raid or not.
--
-- Wire format:
--   DKP:S             → sync start
--   DKP:D:name:bal,…  → data chunk (comma-separated name:balance pairs)
--   DKP:E:senderName  → sync end, sender without realm suffix
--
-- DHFlushQueue() is called immediately after so balances and history always
-- travel together in the same sync cycle.
-- ============================================================================
local syncBuf    = nil
local syncSender = nil

MTR.DKPSyncToRaidSafe = function()
    if not MTR.isOfficer then return end
    if not IsInGuild()    then return end

    local standings = MTR.DKPStandings()
    if #standings == 0 then
        MTR.MP("[DKP Sync] Nothing to sync — ledger is empty.")
        return
    end

    -- ── Balance broadcast ──────────────────────────────────────────────────
    SendAddonMessage(DKP_ADDON_PREFIX, "DKP:S", "GUILD")
    local chunk = ""
    for _, entry in ipairs(standings) do
        local token = entry.name .. ":" .. entry.balance
        if #chunk + #token + 1 > 200 then
            SendAddonMessage(DKP_ADDON_PREFIX, "DKP:D:" .. chunk, "GUILD")
            chunk = token
        else
            chunk = chunk == "" and token or (chunk .. "," .. token)
        end
    end
    if chunk ~= "" then
        SendAddonMessage(DKP_ADDON_PREFIX, "DKP:D:" .. chunk, "GUILD")
    end
    SendAddonMessage(DKP_ADDON_PREFIX, "DKP:E:" .. (MTR.playerName or ""), "GUILD")
    MTR.MP("[DKP Sync] Sent " .. #standings .. " balances to online guild members.")

    -- ── History broadcast (flush queued new entries) ───────────────────────
    DHFlushQueue()

    -- ── Full snapshot broadcast (hash-verified convergence) ─────────────────
    if MTR.MaybeBroadcastSnapshot then MTR.MaybeBroadcastSnapshot("balance-sync") end
end

function MTR.DKPSyncToRaid() MTR.DKPSyncToRaidSafe() end

-- ── Balance receive ────────────────────────────────────────────────────────
local syncAddonFrame = CreateFrame("Frame")
syncAddonFrame:RegisterEvent("CHAT_MSG_ADDON")
syncAddonFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= DKP_ADDON_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end

    local senderName = StripRealm(sender)
    if senderName == MTR.playerName then return end  -- ignore own echo

    if message == "DKP:S" then
        syncBuf    = {}
        syncSender = senderName

    elseif message:sub(1, 6) == "DKP:D:" and syncBuf then
        for token in message:sub(7):gmatch("[^,]+") do
            local n, b = token:match("^(.+):(-?%d+)$")
            if n and b then syncBuf[n] = tonumber(b) end
        end

    elseif message:sub(1, 6) == "DKP:E:" and syncBuf then
        local from = message:sub(7)
        if from ~= "" then syncSender = from end

        -- Merge: update balances only; never delete local entries.
        local count = 0
        for name, balance in pairs(syncBuf) do
            if not MTR.db.dkpLedger[name] then
                MTR.db.dkpLedger[name] = { balance = 0, history = {} }
            end
            local old = MTR.db.dkpLedger[name].balance or 0
            if old ~= balance then
                MTR.db.dkpLedger[name].balance = balance
                count = count + 1
            end
        end
        MTR.MP(string.format("[DKP Sync] Received from %s — %d balance(s) updated.",
            syncSender or "?", count))
        syncBuf    = nil
        syncSender = nil
    end
end)


-- ============================================================================
-- FULL LEDGER SNAPSHOT SYNC  (prefix "MekTownLS")
-- Provides an append-only, hash-verified copy of the full ledger history so
-- every officer converges on the same state. Receivers only apply a snapshot
-- after the advertised hash matches the reconstructed payload, then send an ACK.
-- Wire format:
--   LS:REQ:<player>:<knownHash>          request latest snapshot if peer differs
--   LS:MET:<sender>:<rev>:<hash>:<players>:<entries>
--   LS:D:<payload chunk>
--   LS:END
--   LS:ACK:<player>:<hash>:<rev>
-- ============================================================================
local LS_PREFIX = "MekTownLS"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(LS_PREFIX) end

local lsRecv = nil
local lsFrame = CreateFrame("Frame")
lsFrame:RegisterEvent("CHAT_MSG_ADDON")

local function SendChunked(prefix, header, payload)
    if header then
        SendAddonMessage(prefix, header, "GUILD")
    end
    payload = payload or ""
    local maxChunk = 200
    local idx = 1
    while idx <= #payload do
        SendAddonMessage(prefix, "LS:D:" .. payload:sub(idx, idx + maxChunk - 1), "GUILD")
        idx = idx + maxChunk
    end
    if payload == "" then
        SendAddonMessage(prefix, "LS:D:", "GUILD")
    end
    SendAddonMessage(prefix, "LS:END", "GUILD")
end

function MTR.DKPSendFullSnapshot(reason)
    if not MTR.initialized or not MTR.db or not MTR.isOfficer or not IsInGuild() then return false end
    local st = EnsureSyncStateFresh()
    local records, playerCount, entryCount = BuildSnapshotRecords()
    local payload = SnapshotPayloadFromRecords(records)
    st.hash = SnapshotHashFromRecords(records)
    st.playerCount = playerCount
    st.entryCount = entryCount
    st.lastFullSyncAt = time()
    st.lastBroadcastReason = reason or "manual"
    local header = string.format("LS:MET:%s:%d:%s:%d:%d",
        SanitizeField(MTR.playerName or ""),
        tonumber(st.revision) or 0,
        st.hash or "0",
        playerCount or 0,
        entryCount or 0)
    SendChunked(LS_PREFIX, header, payload)
    MTR.MP(string.format("[DKP Snapshot] Broadcast rev %d (%d player(s), %d history entries).",
        tonumber(st.revision) or 0, playerCount or 0, entryCount or 0))
    return true
end

function MTR.DKPRequestFullSync()
    if not MTR.initialized or not IsInGuild() then return false end
    local st = EnsureSyncStateFresh()
    SendAddonMessage(LS_PREFIX, string.format("LS:REQ:%s:%s",
        SanitizeField(MTR.playerName or ""),
        SanitizeField(st.hash or "0")), "GUILD")
    MTR.dprint("[DKP Snapshot] Requested full sync. Known hash:", st.hash or "0")
    return true
end

function MTR.MaybeBroadcastSnapshot(reason)
    local st = EnsureSyncStateFresh()
    local now = time()
    if not MTR.isOfficer then return end
    if st.lastBroadcastRevision == st.revision and (now - (st.lastFullSyncAt or 0) < 30) then
        return
    end
    st.lastBroadcastRevision = st.revision
    MTR.DKPSendFullSnapshot(reason or "auto")
end

lsFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= LS_PREFIX then return end
    if not MTR.initialized or not MTR.db then return end

    local senderName = StripRealm(sender)
    if senderName == MTR.playerName then return end

    if message:sub(1, 7) == "LS:REQ:" then
        local requester, peerHash = message:match("^LS:REQ:([^:]+):(.+)$")
        requester = requester or senderName
        local st = EnsureSyncStateFresh()
        if MTR.isOfficer and requester ~= (MTR.playerName or "") and (peerHash or "0") ~= (st.hash or "0") then
            MTR.dprint("[DKP Snapshot] Responding to sync request from", requester)
            MTR.DKPSendFullSnapshot("peer-request")
        end

    elseif message:sub(1, 7) == "LS:MET:" then
        local src, rev, hash, playerCount, entryCount =
            message:match("^LS:MET:([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)$")
        lsRecv = {
            sender = src ~= "" and src or senderName,
            revision = tonumber(rev) or 0,
            hash = hash or "0",
            playerCount = tonumber(playerCount) or 0,
            entryCount = tonumber(entryCount) or 0,
            chunks = {},
        }

    elseif message:sub(1, 5) == "LS:D:" and lsRecv then
        lsRecv.chunks[#lsRecv.chunks + 1] = message:sub(6)

    elseif message == "LS:END" and lsRecv then
        local raw = table.concat(lsRecv.chunks, "")
        local receivedHash = MTR.Hash(raw)
        if receivedHash ~= (lsRecv.hash or "0") then
            MTR.MPE(string.format(
                "[DKP Snapshot] Rejected snapshot from %s (hash mismatch %s ~= %s).",
                lsRecv.sender or "?", receivedHash, lsRecv.hash or "0"))
            lsRecv = nil
            return
        end

        local ledger = DecodeSnapshotPayload(raw)
        local players, entries = ApplyFullSnapshot(ledger, lsRecv.sender)
        local st = EnsureDKPSyncState()
        st.revision = math.max(tonumber(st.revision) or 0, tonumber(lsRecv.revision) or 0)
        st.hash = receivedHash
        st.playerCount = players
        st.entryCount = entries
        st.lastFullSyncAt = time()
        st.lastFullSyncFrom = lsRecv.sender or ""
        SendAddonMessage(LS_PREFIX, string.format("LS:ACK:%s:%s:%d",
            SanitizeField(MTR.playerName or ""),
            receivedHash,
            tonumber(st.revision) or 0), "GUILD")
        MTR.MP(string.format(
            "[DKP Snapshot] Applied rev %d from %s (%d player(s), %d history entries).",
            tonumber(lsRecv.revision) or 0, lsRecv.sender or "?", players, entries))
        lsRecv = nil

    elseif message:sub(1, 7) == "LS:ACK:" then
        local peer, hash, rev = message:match("^LS:ACK:([^:]+):([^:]+):([^:]+)$")
        local st = EnsureSyncStateFresh()
        if hash == (st.hash or "0") then
            st.lastAckByPeer = st.lastAckByPeer or {}
            st.lastAckByPeer[peer or senderName or "?"] = {
                revision = tonumber(rev) or 0,
                at = time(),
            }
            MTR.dprint("[DKP Snapshot] ACK from", peer or senderName or "?", "rev", rev or "?")
        end
    end
end)
