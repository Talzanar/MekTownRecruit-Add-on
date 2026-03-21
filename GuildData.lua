
local MTR = MekTownRecruit

local function SafeKeyPart(v)
    v = tostring(v or "")
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    v = v:gsub("[|:;]", "")
    if v == "" then v = "Unknown" end
    return v
end

local function CurrentRealm()
    return SafeKeyPart((GetRealmName and GetRealmName()) or "UnknownRealm")
end

local function CurrentGuildName()
    local guild = (GetGuildInfo and GetGuildInfo("player")) or nil
    guild = tostring(guild or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if guild ~= "" then return guild end
    return nil
end

function MTR.GetLiveGuildName()
    return CurrentGuildName()
end

function MTR.GetGuildKey(strict)
    local guild = CurrentGuildName()
    local realm = CurrentRealm()
    if guild and guild ~= "" then
        return realm .. "|" .. SafeKeyPart(guild)
    end
    if strict then return nil end
    return realm .. "|LOADING..."
end

function MTR.GetGuildId(create)
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(create ~= false) or nil
    if not gs then
        local key = MTR.GetGuildKey and MTR.GetGuildKey(true) or nil
        if key then
            return "gid-" .. ((MTR.Hash and MTR.Hash(key)) or key)
        end
        return nil
    end
    gs.meta = gs.meta or {}
    if not gs.meta.guildId and create ~= false then
        local key = MTR.GetGuildKey(true)
        if key then
            gs.meta.guildId = "gid-" .. ((MTR.Hash and MTR.Hash(key)) or key)
        end
    end
    return gs.meta.guildId
end

function MTR.SetGuildId(guildId)
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return nil end
    gs.meta = gs.meta or {}
    gs.meta.guildId = SafeKeyPart(guildId)
    return gs.meta.guildId
end

function MTR.GetGuildIdentityInfo()
    local realm = CurrentRealm()
    local guild = CurrentGuildName()
    local guildId = MTR.GetGuildId and MTR.GetGuildId(true) or nil
    return {
        guildKey = guild and (realm .. "|" .. SafeKeyPart(guild)) or (realm .. "|LOADING..."),
        guildId = guildId,
        realm = realm,
        guildName = guild or "LOADING...",
    }
end

function MTR.RefreshGuildIdentityUI()
    if MTR.mainWin and MTR.mainWin._refreshGuildTab then pcall(MTR.mainWin._refreshGuildTab) end
end

function MTR.EnsureGuildIdentity()
    local key = MTR.GetGuildKey(true)
    return key
end

function MTR.GetGuildStore(create)
    if type(MekTownRecruitDB) ~= "table" then MekTownRecruitDB = {} end
    if type(MekTownRecruitDB.guilds) ~= "table" then MekTownRecruitDB.guilds = {} end
    local key = MTR.GetGuildKey(true)
    if not key then return nil end

    -- Migration safety: if data was written while guild name was still loading,
    -- move/merge it into the resolved guild key once identity is available.
    if key:find("|LOADING...", 1, true) == nil then
        local loadingKey = CurrentRealm() .. "|LOADING..."
        local loadingGs = MekTownRecruitDB.guilds[loadingKey]
        local realGs = MekTownRecruitDB.guilds[key]
        if type(loadingGs) == "table" and loadingGs ~= realGs then
            if not realGs then
                MekTownRecruitDB.guilds[key] = loadingGs
                MekTownRecruitDB.guilds[loadingKey] = nil
            else
                realGs.meta = realGs.meta or {}
                realGs.dkpLedger = realGs.dkpLedger or {}
                realGs.recruitHistory = realGs.recruitHistory or {}
                realGs.familyTree = realGs.familyTree or {}
                realGs.inactivityKickLog = realGs.inactivityKickLog or {}
                realGs.guildBank = realGs.guildBank or {}
                realGs.guildBankLedger = realGs.guildBankLedger or { entries = {}, meta = {} }
                realGs.guildBankLedger.entries = realGs.guildBankLedger.entries or {}
                realGs.guildBankLedger.meta = realGs.guildBankLedger.meta or {}
                realGs.syncState = realGs.syncState or {}
                realGs.eventLog = realGs.eventLog or {}

                if next(realGs.dkpLedger) == nil and type(loadingGs.dkpLedger) == "table" then realGs.dkpLedger = loadingGs.dkpLedger end
                if #realGs.recruitHistory == 0 and type(loadingGs.recruitHistory) == "table" then realGs.recruitHistory = loadingGs.recruitHistory end
                if next(realGs.familyTree) == nil and type(loadingGs.familyTree) == "table" then realGs.familyTree = loadingGs.familyTree end
                if #realGs.inactivityKickLog == 0 and type(loadingGs.inactivityKickLog) == "table" then realGs.inactivityKickLog = loadingGs.inactivityKickLog end
                if #realGs.guildBank == 0 and type(loadingGs.guildBank) == "table" then realGs.guildBank = loadingGs.guildBank end
                if #(realGs.guildBankLedger.entries or {}) == 0 and loadingGs.guildBankLedger and type(loadingGs.guildBankLedger.entries) == "table" then
                    realGs.guildBankLedger.entries = loadingGs.guildBankLedger.entries
                end
                if loadingGs.syncState and type(loadingGs.syncState) == "table" then
                    for k2, v2 in pairs(loadingGs.syncState) do
                        if realGs.syncState[k2] == nil then realGs.syncState[k2] = v2 end
                    end
                end
                if #(realGs.eventLog or {}) == 0 and type(loadingGs.eventLog) == "table" then realGs.eventLog = loadingGs.eventLog end
                MekTownRecruitDB.guilds[loadingKey] = nil
            end
        end
    end

    local gs = MekTownRecruitDB.guilds[key]
    if not gs and create ~= false then
        gs = {
            meta = {},
            dkpLedger = {},
            recruitHistory = {},
            familyTree = {},
            inactivityKickLog = {},
            guildBank = {},
            guildBankLedger = { entries = {}, meta = {} },
            syncState = {},
            eventLog = {},
        }
        MekTownRecruitDB.guilds[key] = gs
    end
    if gs then
        gs.meta = gs.meta or {}
        gs.meta.guildKey = key
        gs.meta.realm = CurrentRealm()
        gs.meta.guildName = CurrentGuildName() or ""
        gs.dkpLedger = gs.dkpLedger or {}
        gs.recruitHistory = gs.recruitHistory or {}
        gs.familyTree = gs.familyTree or {}
        gs.inactivityKickLog = gs.inactivityKickLog or {}
        gs.guildBank = gs.guildBank or {}
        gs.guildBankLedger = gs.guildBankLedger or { entries = {}, meta = {} }
        gs.guildBankLedger.entries = gs.guildBankLedger.entries or {}
        gs.guildBankLedger.meta = gs.guildBankLedger.meta or {}
        gs.syncState = gs.syncState or {}
        gs.eventLog = gs.eventLog or {}
    end
    return gs
end

function MTR.IsGuildOfficerName(name)
    if not name or name == "" or not IsInGuild() then return false end
    local short = tostring(name):match("^([^%-]+)") or tostring(name)
    local num = GetNumGuildMembers() or 0
    for i = 1, num do
        local n, rankName, rankIndex = GetGuildRosterInfo(i)
        local sn = n and (n:match("^([^%-]+)") or n)
        if sn == short then
            if MTR.IsOfficerRankIndex and MTR.IsOfficerRankIndex(rankIndex) then return true end
            if MTR.IsConfiguredOfficerRank and MTR.IsConfiguredOfficerRank(rankName, rankIndex) then return true end
            local rk = tostring(rankName or ""):upper()
            if rk:find("OFFIC", 1, true) or rk:find("LEAD", 1, true) or rk:find("ADMIN", 1, true) then
                return true
            end
            return false
        end
    end
    return false
end

local function ShortName(name)
    name = tostring(name or "")
    return name:match("^([^%-]+)") or name
end

local _mtrGuildMembersCache = nil
local _mtrGuildMembersCacheAt = 0

function MTR.BuildGuildMemberLookup()
    local now = time and time() or 0
    if _mtrGuildMembersCache and (now - _mtrGuildMembersCacheAt) < 10 then
        return _mtrGuildMembersCache
    end
    local members = {}
    if not IsInGuild() then return members end
    local num = GetNumGuildMembers() or 0
    if num <= 0 and GuildRoster then pcall(GuildRoster) end
    for i = 1, num do
        local n = GetGuildRosterInfo(i)
        local sn = ShortName(n)
        if sn and sn ~= "" then members[sn] = true end
    end
    _mtrGuildMembersCache = members
    _mtrGuildMembersCacheAt = now
    return members
end

function MTR.IsCurrentGuildMemberName(name)
    local short = ShortName(name)
    if short == "" then return false end
    if not IsInGuild() then return false end

    local members = MTR.BuildGuildMemberLookup and MTR.BuildGuildMemberLookup() or {}
    if members[short] then return true end

    local gs = MTR.GetGuildStore and MTR.GetGuildStore(false) or nil
    local tree = gs and gs.familyTree
    if type(tree) == "table" then
        if tree[short] and type(tree[short]) == "table" then return true end
        for mainName, node in pairs(tree) do
            if ShortName(mainName) == short then return true end
            local alts = node and node.alts
            if type(alts) == "table" then
                for _, altName in ipairs(alts) do
                    if ShortName(altName) == short then return true end
                end
            end
        end
    end
    return false
end

function MTR.SendGuildScoped(prefix, payload)
    if not IsInGuild() then return false end
    local key = MTR.GetGuildKey(true)
    if not key then return false end
    local packed = "MTRSYNC:" .. key .. ":" .. tostring(payload or "")
    SendAddonMessage(prefix, packed, "GUILD")
    return true
end

function MTR.SendScoped(prefix, protocol, msgType, payload)
    local p = SafeKeyPart(protocol)
    local t = SafeKeyPart(msgType)
    return MTR.SendGuildScoped(prefix, table.concat({"SYNCV1", p, t, tostring(payload or "")}, ":"))
end

function MTR.UnpackGuildScoped(message, sender, requireOfficer)
    if type(message) ~= "string" then return nil end
    local senderName = (sender or ""):match("^([^%-]+)") or (sender or "")
    local payload = message
    if message:sub(1, 8) == "MTRSYNC:" then
        local rest = message:sub(9)
        local guildKey, inner = rest:match("^(.-):(.*)$")
        if not guildKey or inner == nil then return nil end
        local localKey = MTR.GetGuildKey(true)
        if not localKey or guildKey ~= localKey then return nil end
        payload = inner
    end
    if requireOfficer and MTR.IsGuildOfficerName and not MTR.IsGuildOfficerName(senderName) then
        return nil
    end
    return payload, senderName
end

function MTR.UnpackScoped(message, sender, requireOfficer)
    local payload, senderName = MTR.UnpackGuildScoped(message, sender, requireOfficer)
    if not payload then return nil end
    local ver, protocol, msgType, body = payload:match("^(SYNCV1):([^:]+):([^:]+):?(.*)$")
    if not ver then
        return {
            protocol = nil,
            msgType = nil,
            payload = payload,
            sender = senderName,
            legacy = true,
        }
    end
    return {
        protocol = protocol,
        msgType = msgType,
        payload = body or "",
        sender = senderName,
        legacy = false,
    }
end

local _mtrGuildIdentityFrame = CreateFrame("Frame")
_mtrGuildIdentityFrame:RegisterEvent("PLAYER_LOGIN")
_mtrGuildIdentityFrame:RegisterEvent("PLAYER_GUILD_UPDATE")
_mtrGuildIdentityFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
_mtrGuildIdentityFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
_mtrGuildIdentityFrame:SetScript("OnEvent", function(self, event)
    _mtrGuildMembersCache = nil
    _mtrGuildMembersCacheAt = 0
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
        if GuildRoster then pcall(GuildRoster) end
    end
    if MTR.BindGuildScopedTables then MTR.BindGuildScopedTables() end
    MTR.RefreshGuildIdentityUI()
end)

function MTR.BindGuildScopedTables()
    local gs = MTR.GetGuildStore(true)
    if type(gs) ~= "table" then return nil end
    local profile = MTR.GetActiveProfile and MTR.GetActiveProfile() or MTR.db
    if type(profile) == "table" then
        profile.dkpLedger = gs.dkpLedger
        profile.recruitHistory = gs.recruitHistory
        profile.familyTree = gs.familyTree
        profile.inactivityKickLog = gs.inactivityKickLog
    end
    MekTownRecruitDB.guildBank = gs.guildBank
    MekTownRecruitDB.guildBankLedger = gs.guildBankLedger
    MekTownRecruitDB.syncState = gs.syncState
    MTR.guildStore = gs
    return gs
end

local function IsEmptyTable(t)
    return type(t) == "table" and next(t) == nil
end

function MTR.MigrateGuildScopedData()
    local gs = MTR.GetGuildStore(true)
    local profile = MTR.GetActiveProfile and MTR.GetActiveProfile() or MTR.db
    if type(gs) ~= "table" then return nil end

    if type(profile) == "table" then
        if not IsEmptyTable(profile.dkpLedger) and IsEmptyTable(gs.dkpLedger) then gs.dkpLedger = MTR.DeepCopy(profile.dkpLedger) end
        if not IsEmptyTable(profile.recruitHistory) and IsEmptyTable(gs.recruitHistory) then gs.recruitHistory = MTR.DeepCopy(profile.recruitHistory) end
        if not IsEmptyTable(profile.familyTree) and IsEmptyTable(gs.familyTree) then gs.familyTree = MTR.DeepCopy(profile.familyTree) end
        if not IsEmptyTable(profile.inactivityKickLog) and IsEmptyTable(gs.inactivityKickLog) then gs.inactivityKickLog = MTR.DeepCopy(profile.inactivityKickLog) end
    end
    if not IsEmptyTable(MekTownRecruitDB.guildBank) and IsEmptyTable(gs.guildBank) then gs.guildBank = MTR.DeepCopy(MekTownRecruitDB.guildBank) end
    local gbl = MekTownRecruitDB.guildBankLedger
    if type(gbl) == "table" and ((type(gbl.entries)=="table" and next(gbl.entries)) or (type(gbl.meta)=="table" and next(gbl.meta))) then
        if IsEmptyTable(gs.guildBankLedger.entries) and IsEmptyTable(gs.guildBankLedger.meta) then
            gs.guildBankLedger = MTR.DeepCopy(gbl)
        end
    end
    if type(MekTownRecruitDB.syncState) == "table" and next(MekTownRecruitDB.syncState) and IsEmptyTable(gs.syncState) then
        gs.syncState = MTR.DeepCopy(MekTownRecruitDB.syncState)
    end

    gs.guildBankLedger = gs.guildBankLedger or { entries = {}, meta = {} }
    gs.guildBankLedger.entries = gs.guildBankLedger.entries or {}
    gs.guildBankLedger.meta = gs.guildBankLedger.meta or {}
    gs.syncState = gs.syncState or {}
    gs.eventLog = gs.eventLog or {}

    if type(profile) == "table" then
        profile.dkpLedger = gs.dkpLedger
        profile.recruitHistory = gs.recruitHistory
        profile.familyTree = gs.familyTree
        profile.inactivityKickLog = gs.inactivityKickLog
    end
    MekTownRecruitDB.guildBank = gs.guildBank
    MekTownRecruitDB.guildBankLedger = gs.guildBankLedger
    MekTownRecruitDB.syncState = gs.syncState
    MTR.guildStore = gs
    return gs
end

function MTR.AppendGuildEvent(dataset, action, payload)
    local gs = MTR.GetGuildStore(true)
    if not gs then return end
    gs.syncState = gs.syncState or {}
    gs.syncState.eventLog = gs.syncState.eventLog or { seq = 0 }
    gs.syncState.eventLog.seq = tonumber(gs.syncState.eventLog.seq or 0) + 1
    local seq = gs.syncState.eventLog.seq
    local log = gs.eventLog or {}
    gs.eventLog = log
    local last = log[#log]
    local prevHash = last and last.hash or "0"
    local ts = time()
    local eventId = table.concat({ tostring(MTR.playerName or "?"), tostring(ts), tostring(seq), tostring(dataset or "?") }, "#")
    local body = table.concat({
        tostring(ts),
        tostring(MTR.playerName or "?"),
        tostring(eventId),
        tostring(dataset or "?"),
        tostring(action or "?"),
        tostring(prevHash),
        tostring(payload or "")
    }, "|")
    local hash = (MTR.Hash and MTR.Hash(body)) or body
    log[#log + 1] = {
        id = eventId,
        seq = seq,
        ts = ts,
        actor = MTR.playerName or "?",
        dataset = dataset or "?",
        action = action or "?",
        payload = payload,
        prevHash = prevHash,
        hash = hash,
    }
    if #log > 1500 then
        tremove(log, 1)
    end
end

function MTR.VerifyGuildEventChain()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(false) or nil
    local log = gs and gs.eventLog or nil
    if type(log) ~= "table" then
        return { ok = true, checked = 0, brokenAt = 0 }
    end
    local prev = nil
    local truncated = false
    for i, e in ipairs(log) do
        local body
        if e.id then
            body = table.concat({
                tostring(e.ts or 0),
                tostring(e.actor or "?"),
                tostring(e.id or ""),
                tostring(e.dataset or "?"),
                tostring(e.action or "?"),
                tostring(e.prevHash or "0"),
                tostring(e.payload or "")
            }, "|")
        else
            body = table.concat({
                tostring(e.ts or 0),
                tostring(e.actor or "?"),
                tostring(e.dataset or "?"),
                tostring(e.action or "?"),
                tostring(e.prevHash or "0"),
                tostring(e.payload or "")
            }, "|")
        end
        local hash = (MTR.Hash and MTR.Hash(body)) or body
        if i == 1 then
            if tostring(e.prevHash or "0") ~= "0" then
                truncated = true
            end
        elseif tostring(e.prevHash or "0") ~= tostring(prev or "0") then
            return { ok = false, checked = i, brokenAt = i, reason = "prev-hash-mismatch" }
        end
        if tostring(e.hash or "") ~= tostring(hash) then
            return { ok = false, checked = i, brokenAt = i, reason = "entry-hash-mismatch" }
        end
        prev = e.hash
    end
    return { ok = true, checked = #log, brokenAt = 0, truncated = truncated }
end

local function ScrubStaleConflict(state, maxAge)
    if type(state) ~= "table" then return state end
    local ageLimit = tonumber(maxAge) or 300
    local at = tonumber(state.lastConflictAt or 0) or 0
    if at > 0 and (time() - at) > ageLimit then
        state.lastConflictAt = nil
        state.lastConflictFrom = nil
        state.lastConflictReason = nil
    end
    return state
end

function MTR.GetSyncAuditStatus()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(false) or nil
    local out = {}
    local ss = gs and gs.syncState or {}
    local ev = MTR.VerifyGuildEventChain and MTR.VerifyGuildEventChain() or { ok = true, checked = 0 }
    out.guildKey = MTR.GetGuildKey and MTR.GetGuildKey(false) or "?"
    out.guildId = MTR.GetGuildId and MTR.GetGuildId(true) or nil
    out.dkp = ScrubStaleConflict(ss and ss.dkp or nil)
    out.recruit = ScrubStaleConflict(ss and ss.recruit or nil)
    out.kick = ScrubStaleConflict(ss and ss.kick or nil)
    out.inactivityWhitelist = ScrubStaleConflict(ss and ss.inactivityWhitelist or nil)
    out.guildTree = ScrubStaleConflict(ss and ss.guildTree or nil)
    out.guildBankSnapshot = ScrubStaleConflict(ss and ss.guildBankSnapshot or nil)
    out.guildBankLedger = ScrubStaleConflict(ss and ss.guildBankLedger or nil)
    out.event = ev
    return out
end
