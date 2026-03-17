-- ============================================================================
-- Core.lua  v8.0
-- MekTownRecruit — WoW 3.3.5a / Ascension (Area 52)
--
-- Loads FIRST. Sets up the shared namespace (MTR), all defaults,
-- runtime state, utility helpers, profile management, and the
-- Master Tick Scheduler.
--
-- MASTER TICK SCHEDULER
--   All periodic subsystems (GuildAds, GroupRadar LFG, minimap dot, etc.)
--   register through MTR.TickAdd() rather than creating their own OnUpdate
--   frames. One single frame fires; subscribers run at their own intervals.
--   MTR.After() is also routed through this frame — zero per-call allocations.
-- ============================================================================

MekTownRecruit = MekTownRecruit or {}
local MTR = MekTownRecruit

MTR.VERSION = "2.0.0-beta"


-- ============================================================================
-- CHAT / CHANNEL HELPERS
-- ============================================================================
function MTR.StripChatEscapes(msg, allowLinks)
    if msg == nil then return "" end
    msg = tostring(msg)
    msg = msg:gsub("[\r\n]+", " ")
    local keptLinks = {}
    if allowLinks then
        msg = msg:gsub("|H[^|]+|h.-|h", function(link)
            keptLinks[#keptLinks + 1] = link
            return "MTRLINK" .. #keptLinks .. ""
        end)
    end

    msg = msg:gsub("|c%x%x%x%x%x%x%x%x", "")
    msg = msg:gsub("|r", "")
    if not allowLinks then
        msg = msg:gsub("|H.-|h(.-)|h", "%1")
    end
    msg = msg:gsub("||", "|")

    if allowLinks then
        msg = msg:gsub("MTRLINK(%d+)", function(i)
            return keptLinks[tonumber(i)] or ""
        end)
    end

    return msg
end

function MTR.FindChannelIDByName(...)
    local wantedNames = {...}
    local function matches(name)
        if type(name) ~= "string" then return false end
        local lname = string.lower(name)
        for _, wanted in ipairs(wantedNames) do
            if wanted and wanted ~= "" then
                local lwanted = string.lower(wanted)
                if lname == lwanted or string.find(lname, lwanted, 1, true) then
                    return true
                end
            end
        end
        return false
    end

    if GetChannelList then
        local list = { GetChannelList() }
        for i = 1, #list, 3 do
            local id, name = list[i], list[i+1]
            if type(id) == "number" and id > 0 and matches(name) then
                return id, name
            end
        end
    end

    if GetNumDisplayChannels and GetChannelName then
        local total = GetNumDisplayChannels()
        for i = 1, total do
            local id, name = GetChannelName(i)
            if type(id) == "number" and id > 0 and matches(name) then
                return id, name
            end
        end
    end

    for _, wanted in ipairs(wantedNames) do
        if wanted and wanted ~= "" and JoinChannelByName and GetChannelName then
            pcall(JoinChannelByName, wanted)
            local id, name = GetChannelName(wanted)
            if type(id) == "number" and id > 0 then
                return id, name
            end
        end
    end

    return nil, nil
end

function MTR.GetBestLFGChannelID()
    local id = MTR.FindChannelIDByName(
        "world",
        "World",
        "LookingForGroup",
        "General",
        "Ascension",
        "Trade"
    )
    return id
end

function MTR.SendChatSafe(msg, chatType, language, target, allowLinks)
    local safeMsg = MTR.StripChatEscapes(msg, allowLinks)
    chatType = chatType or "SAY"
    if chatType == "CHANNEL" then
        local channelID = target
        if type(channelID) ~= "number" or channelID <= 0 then
            channelID = MTR.GetBestLFGChannelID()
        end
        if not channelID or channelID <= 0 then
            MTR.MPE("|cffff4444[Chat]|r Unable to find a joined public channel for posting.")
            return false
        end
        SendChatMessage(safeMsg, "CHANNEL", language, channelID)
        return true
    end
    SendChatMessage(safeMsg, chatType, language, target)
    return true
end

function MTR.SendToGeneral(msg, allowLinks)
    return MTR.SendChatSafe(msg, "CHANNEL", nil, MTR.GetBestLFGChannelID(), allowLinks)
end

-- ============================================================================
-- DEFAULTS
-- ============================================================================
MTR.DEFAULTS = {
    -- Recruitment
    keywords = {
        "looking for guild","lf guild","lfguild","need guild","guild lf",
        "guild needed","want guild","guild wanted","guild recruit me",
        "guild please","guild inv","guild invite","guild inv pls",
        "guild inv please","guild inv?","lf raiding guild",
        "looking for raiding guild","want raiding guild","need raiding guild",
        "raiding guild lf","lf raid guild","looking raid guild",
        "raiding guild needed","raid guild lf","looking for social guild",
        "lf social guild","social guild","casual guild","friendly guild",
        "chill guild","social guild needed","guild for fun",
        "casual raiding guild","social raiding guild",
        "new player looking for guild","new to game looking for guild",
        "returning player looking for guild","came back looking for guild",
        "new here looking for guild","newbie looking for guild",
        "noob looking for guild","starting out looking for guild",
        "leveling guild","new character looking for guild",
        "alt looking for guild","fresh 70 looking for guild",
        "fresh 80 looking for guild","just dinged looking for guild",
        "new max level looking for guild","looking for mentor guild",
        "need a guild to help","learning the game guild",
        "want to improve guild","looking for people to play with guild",
        "want a community guild","lf community guild",
        "looking for active guild","active guild lf","want to join a guild",
        "lf g","guild lfg","guild lfm","recruit me guild",
        "inv me to guild","guild inv me","guild pls","guild?",
        "mektown","choppaz","mek","choppa",
    },
    whisperTemplates = {
        "Oi {name}! Saw you lookin' for {context} - perfect! MekTown Choppa'z is a WAAAGH! of friendly ork-lovers on Area 52. We raid Tue/Thu eve and Fri/Sat arvo, 9/9 BT heroic, pushin' Sunwell heroic. Fancy a chat? FOR GORK N MORK!",
        "Hey {name}! Noticed you mentioned {context}. We're MekTown Choppa'z - biker boyz who love raiding an' socializin'. Need more DPS (20k+) an' tanks. Come join the WAAAGH!?",
        "Hi {name}! MekTown Choppa'z here - ork-themed guild (40k lore) on Area 52. BT 9/9H, MH, Sunwell normal, pushin' Sunwell heroic. Raids: Tue/Thu 19:30, Fri/Sat 14:00 server. Wanna roll with us?",
        "Greetin's {name}! Still seekin' a guild? MekTown Choppa'z is a social mob with good people an' a Discord full o' chat. Bring your choppa!",
        "Oi {name}! Caught ya lookin' for {context}. MekTown Choppa'z is recruitin' - 40k-inspired biker clan on Area 52. We raid twice a week, after DPS (20k+) an' tanks. RED IZ FASTEST!",
    },
    ignoreDuration     = 300,
    enabled            = true,
    requireGuildWord   = true,
    additionalRequired = "",
    ignoreAds          = true,
    adPatterns = {
        "is recruiting","guild recruitment","we are a guild",
        "recruiting members","guild is looking for",
        "we are recruiting","guild advertisement",
    },
    enableDebug   = false,
    soundAlert    = true,
    minimapButton = true,
    popupWidth    = 350,
    popupHeight   = 180,
    popupColor    = { r=0.1, g=0.1, b=0.1, a=0.97 },
    scanChannels  = {
        ["CHAT_MSG_CHANNEL"]      = true,
        ["CHAT_MSG_PARTY"]        = true,
        ["CHAT_MSG_PARTY_LEADER"] = true,
        ["CHAT_MSG_SAY"]          = true,
        ["CHAT_MSG_YELL"]         = true,
        ["CHAT_MSG_WHISPER"]      = false,
        ["CHAT_MSG_GUILD"]        = false,
        ["CHAT_MSG_OFFICER"]      = false,
        ["CHAT_MSG_RAID"]         = false,
        ["CHAT_MSG_RAID_LEADER"]  = false,
    },
    blacklist      = {},
    recruitHistory = {},
    familyTree     = {},

    -- Guild invite
    enableGuildInvites = false,
    inviteKeywords = {
        "inv me","invite me","inv pls","invite pls",
        "need inv","want inv","can i get inv","can i get invite",
        "lf inv","ready for inv","ready inv","inv when ready",
        "inv for raid","inv to raid","need invite","gimme inv",
    },
    inviteCooldown   = 60,
    inviteWelcomeMsg = "",
    inviteAnnounce   = false,

    -- Attendance + DKP awards
    attendanceEnabled      = true,
    attendanceAutoSnapshot = true,
    dkpPerRaid             = 10,
    dkpPerBoss             = 5,
    attendanceLog          = {},
    bossKillLog            = {},

    -- DKP
    dkpEnabled        = true,
    dkpLedger         = {},
    dkpPublishChannel = "GUILD",
    dkpBidLog         = {},

    -- Permissions
    permissionOfficerRanks = {},

    -- Inactivity
    inactivityEnabled     = true,
    inactivityDefaultDays = 28,
    inactivityWhitelist   = {},
    inactivityRankRules   = {
        ["DA WARBOSS"]     = "never",
        ["MEKBOY"]         = "never",
        ["SPAREBOY MEK'Z"] = "never",
        ["DA BACKUP"]      = "never",
    },
    inactivitySafeRanks = { "DA WARBOSS", "MEKBOY", "SPAREBOY MEK'Z", "DA BACKUP" },
    inactivityKickLog   = {},
    inactivitySeenLog   = {},

    -- Group Radar (mirrors RecruitRadar 2 WA defaults)
    groupRadarConfig = {
        -- All alerts off by default — nothing fires until user explicitly opts in
        textAlertMsLeveling   = false,
        textAlertMsGold       = false,
        textAlertBc           = false,
        textAlertLfmDps       = false,
        textAlertLfmTank      = false,
        textAlertLfmHeal      = false,
        alertMsLeveling       = false,
        alertMsGold           = false,
        alertBc               = false,
        alertLfmDps           = false,
        alertLfmTank          = false,
        alertLfmHeal          = false,
        silentNotifications   = false,
        doNotAlertInCombat    = false,
        doNotAlertInGroup     = false,
        dontAlertInInstance   = false,
        frameDuration               = 10,
        dontDisplayDeclinedDuration = 300,
        dontDisplaySpammers         = 180,
        hideFromDetailAfter         = 180,
        messageMustContain    = "",
        messageMustNotContain = "recruit,lfg,>,http,wtb,wts,anal,sell,carry,need to,looking to join a group",
        myRole        = 1,
        lfgRepeatMins = 10,
    },

    -- Auto-responder
    autoResponderEnabled = false,
    autoResponses        = {},
    motdTemplates = {
        raid    = "RAID NIGHT - Invites at 19:15, first pull 19:30. Check Discord for assignments. FOR GORK N MORK!",
        social  = "No raid tonight - just vibin'. Dungeons, PvP, whatever. Hop in Discord!",
        recruit = "MekTown Choppa'z is RECRUITING! DPS (20k+) and tanks wanted. Whisper an officer to apply.",
    },
    applicationLog = {},

    -- Guild Advertisement Auto-Poster
    guildAdMessages = {
        { text="[Enter your first recruitment message here. Supports {star} {skull} {triangle} icon codes.]", enabled=false },
    },
    guildAdConfig = {
        intervalMins = 10,
        channelNum   = 1,
        active       = false,
    },
}

-- ============================================================================
-- RUNTIME STATE
-- ============================================================================
MTR.db            = nil
MTR.recent        = {}
MTR.recentInvites = {}
MTR.ignoreList    = {}
MTR.initialized   = false
MTR.playerName    = nil
MTR.isGM          = false
MTR.isOfficer     = false
MTR.activeBid     = nil
MTR.activeRoll    = nil
MTR.currentSession= nil
MTR.inInstance    = false

MTR.mainWin       = nil
MTR.memberWin     = nil
MTR.panel         = { _tempDB = {} }
MTR.linkEditBoxes = {}

-- ============================================================================
-- MASTER TICK SCHEDULER
--
-- All periodic work in the addon flows through this single OnUpdate frame.
-- One frame, one callback per game frame — all subsystems subscribe at their
-- own interval rather than creating individual OnUpdate frames.
--
-- Architecture:
--   _subs[key] = { interval, elapsed, fn, once }
--   Each game frame: elapsed += dt; if elapsed >= interval → call fn + reset
--   `once=true` entries (MTR.After) are removed after firing
--
-- Thread-safety: iterating a key snapshot before calling fn so that
-- callbacks can safely call MTR.TickRemove(key) on themselves.
-- ============================================================================
do
    local _subs  = {}
    local _frame = CreateFrame("Frame")

    _frame:SetScript("OnUpdate", function(_, dt)
        local keys = {}
        for k in pairs(_subs) do keys[#keys+1] = k end
        for _, k in ipairs(keys) do
            local s = _subs[k]
            if s then
                s.elapsed = s.elapsed + dt
                if s.elapsed >= s.interval then
                    -- Carry over remainder so drift doesn't accumulate
                    s.elapsed = s.elapsed - s.interval
                    local ok, err = pcall(s.fn)
                    if not ok and MTR.IsDebugEnabled() then
                        print("|cffff4444[MekTown Tick " .. k .. "]|r " .. tostring(err))
                    end
                    if s.once then _subs[k] = nil end
                end
            end
        end
    end)

    -- Register a recurring tick. Overwrites any existing entry with the same key.
    function MTR.TickAdd(key, interval, fn)
        _subs[key] = { interval=interval, elapsed=0, fn=fn, once=false }
    end

    -- Remove a tick by key. Safe to call from within the tick callback itself.
    function MTR.TickRemove(key)
        _subs[key] = nil
    end

    -- One-shot delayed call. Zero frame allocation — uses the master tick.
    -- Unique key prevents collisions when called many times in quick succession.
    local _uid = 0
    function MTR.After(delay, fn)
        _uid = _uid + 1
        _subs["_after_" .. _uid] = { interval=delay, elapsed=0, fn=fn, once=true }
    end
end

-- ============================================================================
-- UTILITIES
-- ============================================================================
function MTR.DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do copy[k] = MTR.DeepCopy(v) end
    return copy
end

function MTR.Hash(str)
    local h = 0
    for i = 1, #str do h = (h * 31 + str:byte(i)) % 1048576 end
    return tostring(h)
end

function MTR.MP(msg)  print("|cff00c0ff[MekTown]|r " .. tostring(msg)) end
function MTR.MPE(msg) print("|cffff4444[MekTown]|r " .. tostring(msg)) end

function MTR.IsDebugEnabled()
    return MTR.db and MTR.db.enableDebug == true
end

function MTR.SetDebugEnabled(flag)
    if not MTR.db then return end
    local enabled = flag and true or false
    MTR.db.enableDebug = enabled
    MTR.db.debug = enabled -- legacy compatibility for older code / saved vars
end

function MTR.dprint(...)
    if MTR.IsDebugEnabled() then
        local t = {}
        for i = 1, select("#", ...) do t[i] = tostring(select(i, ...)) end
        print("|cff888888[MekTown DBG]|r " .. table.concat(t, " "))
    end
end

function MTR.Trunc(text, maxChars)
    if not text then return "" end
    maxChars = maxChars or 60
    if #text <= maxChars then return text end
    return text:sub(1, maxChars - 3) .. "..."
end

function MTR.FormatDays(days)
    if days >= 999 then return "unknown (not seen by addon)" end
    if days < 7    then return days .. " days" end
    local w = math.floor(days / 7)
    local d = days % 7
    if d == 0 then return w .. " week" .. (w > 1 and "s" or "") end
    return w .. "w " .. d .. "d"
end

function MTR.ItemLinkToName(link)
    if not link then return "" end
    return link:match("|h%[(.-)%]|h") or link
end

function MTR.IsItemLink(str)
    return str ~= nil and str:find("|Hitem:") ~= nil
end

-- ============================================================================
-- PROFILE SYSTEM
-- ============================================================================
local function EnsureProfile(name)
    if not MekTownRecruitDB.profiles[name] then
        MekTownRecruitDB.profiles[name] = MTR.DeepCopy(MTR.DEFAULTS)
    else
        local p = MekTownRecruitDB.profiles[name]
        for k, v in pairs(MTR.DEFAULTS) do
            if p[k] == nil then p[k] = MTR.DeepCopy(v) end
        end
        for _, key in ipairs({"scanChannels","popupColor","inactivityRankRules"}) do
            if type(p[key]) == "table" and type(MTR.DEFAULTS[key]) == "table" then
                for k2, v2 in pairs(MTR.DEFAULTS[key]) do
                    if p[key][k2] == nil then p[key][k2] = v2 end
                end
            end
        end
        for _, key in ipairs({"keywords","whisperTemplates","adPatterns","inviteKeywords","inactivitySafeRanks"}) do
            if type(p[key]) == "table" and #p[key] == 0 then
                p[key] = MTR.DeepCopy(MTR.DEFAULTS[key])
            end
        end
    end
    return MekTownRecruitDB.profiles[name]
end

function MTR.GetActiveProfile()
    local name = MekTownRecruitDB.activeProfile or "Default"
    return EnsureProfile(name), name
end

function MTR.RefreshDB()  MTR.db = MTR.GetActiveProfile() end

function MTR.InitDB()
    if type(MekTownRecruitDB) ~= "table"          then MekTownRecruitDB = {} end
    if type(MekTownRecruitDB.profiles) ~= "table" then MekTownRecruitDB.profiles = {} end
    if type(MekTownRecruitDB.activeProfile) ~= "string"
       or MekTownRecruitDB.activeProfile == ""    then MekTownRecruitDB.activeProfile = "Default" end
    EnsureProfile("Default")
    MTR.RefreshDB()

    for _, profile in pairs(MekTownRecruitDB.profiles) do
        if type(profile) == "table" then
            if profile.enableDebug == nil then
                profile.enableDebug = profile.debug == true
            end
            profile.debug = nil
        end
    end
    MTR.RefreshDB()

    -- Ensure account-wide storage exists
    if type(MekTownRecruitDB.charVault) ~= "table" then
        MekTownRecruitDB.charVault = {}
    end
    if type(MekTownRecruitDB.guildBank) ~= "table" then
        MekTownRecruitDB.guildBank = {}
    end
    if type(MekTownRecruitDB.guildBankLedger) ~= "table" then
        MekTownRecruitDB.guildBankLedger = { entries = {}, meta = {} }
    else
        MekTownRecruitDB.guildBankLedger.entries = MekTownRecruitDB.guildBankLedger.entries or {}
        MekTownRecruitDB.guildBankLedger.meta = MekTownRecruitDB.guildBankLedger.meta or {}
    end

    -- Migration: clear any stale alert values from pre-8.0 saves so the user
    -- starts clean and can opt in to exactly what they want.
    -- We nil out all alert/text keys so the defaults (all false) take effect.
    for _, profile in pairs(MekTownRecruitDB.profiles) do
        if type(profile.groupRadarConfig) == "table" then
            local gr = profile.groupRadarConfig
            -- Only wipe if this looks like a pre-8.0 config (had true values)
            -- Check for the old default: alertLfmDps was true in v7 and earlier
            if gr.alertLfmDps == true or gr.alertLfmTank == true or gr.alertLfmHeal == true
               or gr.alertMsLeveling == true or gr.alertMsGold == true
               or gr.textAlertLfmDps == true or gr.textAlertLfmTank == true or gr.textAlertLfmHeal == true then
                -- Wipe all alert keys so defaults (false) apply fresh
                gr.textAlertMsLeveling = nil
                gr.textAlertMsGold     = nil
                gr.textAlertBc         = nil
                gr.textAlertLfmDps     = nil
                gr.textAlertLfmTank    = nil
                gr.textAlertLfmHeal    = nil
                gr.alertMsLeveling     = nil
                gr.alertMsGold         = nil
                gr.alertBc             = nil
                gr.alertLfmDps         = nil
                gr.alertLfmTank        = nil
                gr.alertLfmHeal        = nil
                -- Also reset stale suppression defaults (were true, now false)
                gr.doNotAlertInCombat  = nil
                gr.doNotAlertInGroup   = nil
                gr.dontAlertInInstance = nil
            end
        end
    end
end

-- ============================================================================
-- PERMISSION CHECKS
-- ============================================================================
function MTR.CheckIsGM()
    if not IsInGuild() then return false end
    if IsGuildLeader() then return true end
    local num = GetNumGuildMembers()
    for i = 1, num do
        local n, rankName, rankIndex = GetGuildRosterInfo(i)
        if n == MTR.playerName then
            -- Rank index 0 = Guild Master, OR rank name is "DA WARBOSS"
            if rankIndex == 0 then return true end
            if (rankName or ""):upper() == "DA WARBOSS" then return true end
        end
    end
    return false
end

local function NormalizeRankName(rankName)
    return tostring(rankName or ""):gsub("^%s+", ""):gsub("%s+$", ""):upper()
end

function MTR.GetGuildRanks()
    local ranksByIndex = {}

    if type(GuildControlGetNumRanks) == "function" and type(GuildControlGetRankName) == "function" then
        local okNum, numRanks = pcall(GuildControlGetNumRanks)
        if okNum and type(numRanks) == "number" and numRanks > 0 then
            for i = 1, numRanks do
                local okName, rankName = pcall(GuildControlGetRankName, i)
                if okName and rankName and rankName ~= "" then
                    ranksByIndex[i - 1] = rankName
                end
            end
        end
    end

    if next(ranksByIndex) == nil and IsInGuild() then
        local num = GetNumGuildMembers() or 0
        for i = 1, num do
            local _, rankName, rankIndex = GetGuildRosterInfo(i)
            if type(rankIndex) == "number" and rankName and rankName ~= "" and ranksByIndex[rankIndex] == nil then
                ranksByIndex[rankIndex] = rankName
            end
        end
    end

    local ordered = {}
    local maxIndex = -1
    for idx in pairs(ranksByIndex) do
        if type(idx) == "number" and idx > maxIndex then maxIndex = idx end
    end
    for i = 0, maxIndex do
        if ranksByIndex[i] then
            ordered[#ordered + 1] = { index = i, name = ranksByIndex[i] }
        end
    end
    return ordered
end


local function _mtrBool(v)
    return v and v ~= 0 and v ~= false
end

function MTR.GetOfficerRankSuggestions()
    local ordered = {}
    local ranks = MTR.GetGuildRanks and MTR.GetGuildRanks() or {}
    if type(ranks) ~= "table" or #ranks == 0 then return ordered, "none" end

    local suggested = {}
    local usedPermissionProbe = false

    if type(GuildControlSetRank) == "function" and type(GuildControlGetRankFlags) == "function" then
        for _, info in ipairs(ranks) do
            if info.index ~= 0 then
                local okSet = pcall(GuildControlSetRank, (tonumber(info.index) or 0) + 1)
                if okSet then
                    local okFlags, guildchat_listen, guildchat_speak, officerchat_listen, officerchat_speak, promote, demote, invite_member, remove_member, set_motd, edit_public_note, view_officer_note, edit_officer_note, modify_guild_info, unknown_flag, withdraw_repair, withdraw_gold, create_guild_event = pcall(GuildControlGetRankFlags)
                    if okFlags then
                        usedPermissionProbe = true
                        local score = 0
                        if _mtrBool(officerchat_listen) then score = score + 4 end
                        if _mtrBool(officerchat_speak) then score = score + 5 end
                        if _mtrBool(invite_member) then score = score + 2 end
                        if _mtrBool(remove_member) then score = score + 3 end
                        if _mtrBool(promote) then score = score + 3 end
                        if _mtrBool(demote) then score = score + 3 end
                        if _mtrBool(view_officer_note) then score = score + 2 end
                        if _mtrBool(edit_officer_note) then score = score + 3 end
                        if _mtrBool(set_motd) then score = score + 1 end
                        if _mtrBool(modify_guild_info) then score = score + 1 end
                        if _mtrBool(withdraw_gold) then score = score + 1 end
                        if _mtrBool(create_guild_event) then score = score + 1 end
                        if score >= 5 then
                            suggested[NormalizeRankName(info.name)] = true
                        end
                    end
                end
            end
        end
    end

    if next(suggested) == nil then
        for _, info in ipairs(ranks) do
            if info.index ~= 0 then
                local nameKey = NormalizeRankName(info.name)
                if info.index == 1 then
                    suggested[nameKey] = true
                elseif nameKey:find("OFFIC", 1, true) or nameKey:find("ADMIN", 1, true) or nameKey:find("LEAD", 1, true) or nameKey:find("CO%-GM") or nameKey:find("COGM", 1, true) then
                    suggested[nameKey] = true
                end
            end
        end
    end

    for _, info in ipairs(ranks) do
        if info.index ~= 0 and suggested[NormalizeRankName(info.name)] then
            ordered[#ordered + 1] = { index = info.index, name = info.name }
        end
    end

    return ordered, usedPermissionProbe and "guild_permissions" or "heuristic"
end

function MTR.ApplyOfficerRankSuggestions(clearExisting)
    if not MTR.db then return 0 end
    MTR.db.permissionOfficerRanks = MTR.db.permissionOfficerRanks or {}
    if clearExisting then
        for k in pairs(MTR.db.permissionOfficerRanks) do
            MTR.db.permissionOfficerRanks[k] = nil
        end
    end
    local suggested = MTR.GetOfficerRankSuggestions()
    local count = 0
    for _, info in ipairs(suggested) do
        local key = NormalizeRankName(info.name)
        if key ~= "" then
            MTR.db.permissionOfficerRanks[key] = true
            count = count + 1
        end
    end
    MTR.isGM = MTR.CheckIsGM()
    MTR.isOfficer = MTR.CheckIsOfficer()
    return count
end

function MTR.IsConfiguredOfficerRank(rankName)
    local db = MTR.db
    local map = db and db.permissionOfficerRanks
    if type(map) ~= "table" then return false end
    return map[NormalizeRankName(rankName)] == true
end

function MTR.SetOfficerRank(rankName, isEnabled)
    if not MTR.db then return false end
    MTR.db.permissionOfficerRanks = MTR.db.permissionOfficerRanks or {}
    local key = NormalizeRankName(rankName)
    if key == "" then return false end
    if isEnabled then
        MTR.db.permissionOfficerRanks[key] = true
    else
        MTR.db.permissionOfficerRanks[key] = nil
    end
    MTR.isGM = MTR.CheckIsGM()
    MTR.isOfficer = MTR.CheckIsOfficer()
    return true
end

function MTR.CheckIsOfficer()
    if not IsInGuild() then return false end
    if MTR.isGM then return true end
    local num = GetNumGuildMembers()
    for i = 1, num do
        local n, rankName = GetGuildRosterInfo(i)
        if n == MTR.playerName then
            return MTR.IsConfiguredOfficerRank(rankName)
        end
    end
    return false
end

function MTR.CanInvite()
    if IsInRaid()  then return IsRaidLeader() or UnitIsGroupAssistant("player") end
    if IsInGroup() then return IsPartyLeader() end
    return true
end

print("|cff00c0ff[MekTown Recruit]|r Core v" .. MTR.VERSION .. " loaded.")
