-- ============================================================================
-- Commands.lua  v5.0
-- PLAYER_LOGIN initialisation + all slash commands
-- This loads LAST, so every function it calls is already defined.
-- ============================================================================
local MTR = MekTownRecruit

-- ============================================================================
-- PLAYER_LOGIN
-- ============================================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent",function(self,event)
    if event ~= "PLAYER_LOGIN" then return end

    MTR.InitDB()
    MTR.playerName    = UnitName("player")
    MTR.initialized   = true
    MTR.recent        = {}
    MTR.recentInvites = {}
    MTR.ignoreList    = {}
    MTR.activeBid     = nil
    MTR.activeRoll    = nil
    MTR.currentSession= nil
    MTR.inInstance    = false

    if MTR.db.minimapButton then MTR.CreateMinimapButton() end

    GuildRoster()
    MTR.After(4,function()
        MTR.isGM      = MTR.CheckIsGM()
        MTR.isOfficer = MTR.CheckIsOfficer()
        MTR.dprint("GM:",MTR.isGM,"Officer:",MTR.isOfficer)
        if MTR.EnsureGuildIdentity then
            MTR.EnsureGuildIdentity()
        end

        -- Always enable offline member visibility for the whole session.
        SetGuildRosterShowOffline(true)
        GuildRoster()

        -- Restore GuildAds auto-posting if it was active last session
        if MTR.GuildAds then MTR.GuildAds.RestoreState() end

        -- Login sync:
        --   • Officers broadcast their current balances/history snapshot
        --   • Everyone requests the latest verified snapshot so fresh logins
        --     converge even if they were offline during the last award wave.
        MTR.After(8, function()
            if IsInGuild() and MTR.DKPRequestFullSync then
                MTR.DKPRequestFullSync()
            end
            if IsInGuild() then
                local gbHash = "0"
                if MTR.GetSyncAuditStatus then
                    local ss = MTR.GetSyncAuditStatus()
                    gbHash = (ss and ss.guildBankSnapshot and ss.guildBankSnapshot.hash) or "0"
                end
                if MTR.SendGuildScoped then
                    MTR.SendGuildScoped("MekTownGB", "GB:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(gbHash))
                else
                    SendAddonMessage("MekTownGB", "GB:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(gbHash), "GUILD")
                end
            end
            if IsInGuild() and MTR.GuildBankLedger and MTR.GuildBankLedger.RequestSync then
                MTR.GuildBankLedger.RequestSync()
            end
            if MTR.isOfficer and IsInGuild() then
                MTR.DKPSyncToRaidSafe()
            end
        end)
    end)

    -- CharVault: scan this character 2s after login (APIs settle by then)
    MTR.After(2, function()
        if MTR.CharVault and MTR.CharVault.ScanCharacter then
            MTR.CharVault.ScanCharacter()
        end
    end)

    print("|cff00c0ff[MekTown Recruit]|r v"..tostring(MTR.VERSION or "2.1.1-pre").." Ready — profile |cffffff00"..
        MekTownRecruitDB.activeProfile.."|r  |cffaaaaaa("..
        #MTR.db.keywords.." recruit keywords · "..
        #MTR.db.whisperTemplates.." whisper templates · /mek help)|r")

    self:UnregisterEvent("PLAYER_LOGIN")
end)

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================
SLASH_MEKTOWN1="/mek"
SLASH_MEKTOWN2="/mektown"
SLASH_MTRID1="/mtrid"
SlashCmdList["MEKTOWN"]=function(msg)
    if not MTR.initialized then MTR.MPE("Not ready yet.") return end
    local cmd,args=msg:match("^(%S*)%s*(.-)$")
    cmd=(cmd or ""):lower()

    if cmd=="" or cmd=="help" then
        MTR.MP("Commands:")
        print("  /mek config              - Open config window")
        print("  /mek on / off            - Enable/disable scanner")
        print("  /mek debug on/off        - Master debug toggle")
        print("  /mek debug chat on/off   - Debug chat spam toggle")
        print("  /mek debug module <m> on/off - Module debug toggle")
        print("  /mek debug status        - Show debug routing status")
        print("  /mek test                - Test popup")
        print("  /mek add <kw>            - Add keyword")
        print("  /mek list                - List keywords")
        print("  /mek invite on/off       - Guild auto-invite")
        print("  /mtrid                   - Show current guild name, realm, and guild key")
        print("  /mek dkp award <n> <pts> [reason]")
        print("  /mek dkp deduct <n> <pts> [reason]")
        print("  /mek dkp set <n> <pts>   - GM only")
        print("  /mek dkp balance <n>")
        print("  /mek dkp standings")
        print("  /mek dkp publish [chan]")
        print("  /mek dkp sync")
        print("  /mek dkp snapshot       - Officer full verified ledger snapshot")
        print("  /mek sync status         - Show sync health and revisions")
        print("  /mek sync verify         - Verify local event chain integrity")
        print("  /mek sync repair [dkp|guildtree|recruit|kick|inactivewl|gbank|ledger|all]")
        print("  /mek auction <item|link> [min] [secs] [rw]")
        print("  /mek roll <item|link> [MS/OS/Transmog/Legendary/Tier Token] [secs] [rw]")
        print("  /mek att start [zone]")
        print("  /mek att end")
        print("  /mek att boss <n>")
        print("  /mek att check <player>")
        print("  /mek chars               - Open Character Vault (all alts)")
  print("  /mek radar               - Open GroupRadar group finder")
        print("  /mek lfg                 - Open Find Group / post LFG")
        print("  /mek gads start          - Start guild ad auto-posting")
        print("  /mek gads stop           - Stop guild ad auto-posting")
        print("  /mek gads now            - Post next guild ad immediately")
        print("  /mek inactive kick       - Officer+ (Kick All = GM only)")
        print("  /mek inactive debug")
        print("  /mek inactive whitelist add/remove <n>")
        print("  /mek motd <key>")
        print("  /mek ledgerdebug [show|clear|on|off]")

    elseif cmd=="config" then
        MTR.OpenConfig()

    elseif cmd=="ledgerdebug" then
        local sub = (args or ""):lower()
        if not MTR.GuildBankLedger then
            MTR.MPE("Guild bank ledger system not loaded.")
        elseif sub=="clear" then
            MTR.GuildBankLedger.DebugClear()
        elseif sub=="on" then
            MTR.SetDebugEnabled(true)
            if MTR.SetDebugModuleEnabled then MTR.SetDebugModuleEnabled("ledger", true) end
            if MTR.GuildBankLedger and MTR.GuildBankLedger.DebugEnable then MTR.GuildBankLedger.DebugEnable(true) end
        elseif sub=="off" then
            if MTR.GuildBankLedger and MTR.GuildBankLedger.DebugEnable then MTR.GuildBankLedger.DebugEnable(false) end
            if MTR.SetDebugModuleEnabled then MTR.SetDebugModuleEnabled("ledger", false) end
        else
            MTR.GuildBankLedger.DebugDump(60)
        end

    elseif cmd=="on" then
        MTR.SetProfileBoolean("enabled", true)  MTR.MP("|cff00ff00Scanner enabled|r")

    elseif cmd=="off" then
        MTR.SetProfileBoolean("enabled", false) MTR.MP("|cffff4444Scanner disabled|r")

    elseif cmd=="debug" then
        local sub, rest = (args or ""):match("^(%S*)%s*(.-)$")
        sub = (sub or ""):lower()
        rest = rest or ""

        if sub=="" then
            local enabled = not MTR.IsDebugEnabled()
            MTR.SetDebugEnabled(enabled)
            MTR.MP("Debug master: "..(enabled and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        elseif sub=="on" or sub=="off" then
            local enabled = (sub == "on")
            MTR.SetDebugEnabled(enabled)
            MTR.MP("Debug master: "..(enabled and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        elseif sub=="chat" then
            local mode = (rest or ""):lower()
            if mode=="on" or mode=="off" then
                local flag = (mode == "on")
                if MTR.SetDebugChatEnabled then MTR.SetDebugChatEnabled(flag) end
                MTR.MP("Debug chat output: "..(flag and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
            else
                MTR.MP("/mek debug chat on|off")
            end
        elseif sub=="module" then
            local mod, mode = rest:match("^(%S+)%s*(%S*)$")
            mod = (mod or ""):lower()
            mode = (mode or ""):lower()
            if mod ~= "" and (mode == "on" or mode == "off") then
                if MTR.SetDebugModuleEnabled then MTR.SetDebugModuleEnabled(mod, mode == "on") end
                MTR.MP("Debug module '" .. mod .. "': " .. ((mode == "on") and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
            else
                MTR.MP("/mek debug module <name> on|off")
            end
        elseif sub=="status" then
            local master = MTR.IsDebugEnabled and MTR.IsDebugEnabled() or false
            local chat = MTR.IsDebugChatEnabled and MTR.IsDebugChatEnabled() or false
            MTR.MP("Debug master: " .. (master and "|cff00ff00ON|r" or "|cffff4444OFF|r") .. "  chat: " .. (chat and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
            local mods = MTR.GetDebugModules and MTR.GetDebugModules() or {}
            local enabledMods = {}
            for k, v in pairs(mods) do
                if v == true then enabledMods[#enabledMods + 1] = tostring(k) end
            end
            table.sort(enabledMods)
            MTR.MP("Debug modules: " .. (#enabledMods > 0 and table.concat(enabledMods, ", ") or "(none)"))
        else
            MTR.MP("/mek debug [on|off|chat on|off|module <name> on|off|status]")
        end

    elseif cmd=="test" then
        if MTR.ShowTestPopup then
            MTR.ShowTestPopup()
        else
            MTR.MPE("Test popup unavailable.")
        end

    elseif cmd=="add" and args~="" then
        local kw=args:lower()
        table.insert(MTR.db.keywords,kw)
        MTR.MP("Added keyword: |cffffff00"..kw.."|r")

    elseif cmd=="list" then
        MTR.MP("Keywords ("..#MTR.db.keywords.."):")
        for i,kw in ipairs(MTR.db.keywords) do print("  "..i..". "..kw) end

    elseif cmd=="invite" then
        local sub=args:lower()
        if sub=="on"  then MTR.SetGuildInviteEnabled(true)  MTR.MP("Auto-invite: |cff00ff00ON|r")
        elseif sub=="off" then MTR.SetGuildInviteEnabled(false) MTR.MP("Auto-invite: |cffff4444OFF|r")
        else MTR.MP("/mek invite [on|off]") end

    elseif cmd=="sync" then
        local sub, rest = args:match("^(%S+)%s*(.*)")
        sub = (sub or "status"):lower()
        if sub == "status" then
            local function PeerCount(t)
                local c = 0
                if type(t) ~= "table" then return 0 end
                for _ in pairs(t) do c = c + 1 end
                return c
            end
            local s = MTR.GetSyncAuditStatus and MTR.GetSyncAuditStatus() or {}
            local dkp = s.dkp or {}
            local rec = s.recruit or {}
            local kick = s.kick or {}
            local iwl = s.inactivityWhitelist or {}
            local gt = s.guildTree or {}
            local gb = s.guildBankSnapshot or {}
            local gbl = s.guildBankLedger or {}
            local ev = s.event or {}
            MTR.MP("Sync Status")
            print("  Guild Key: " .. tostring(s.guildKey or "?"))
            print("  Guild Id : " .. tostring(s.guildId or "(unset)"))
            print(string.format("  DKP     : rev=%s hash=%s from=%s ack=%d", tostring(dkp.revision or 0), tostring(dkp.hash or "0"), tostring(dkp.lastFullSyncFrom or "?"), PeerCount(dkp.lastAckByPeer)))
            print(string.format("  Recruit : rev=%s hash=%s ack=%d", tostring(rec.revision or 0), tostring(rec.hash or "0"), PeerCount(rec.lastAckByPeer)))
            print(string.format("  KickLog : rev=%s hash=%s ack=%d", tostring(kick.revision or 0), tostring(kick.hash or "0"), PeerCount(kick.lastAckByPeer)))
            print(string.format("  InactWL : rev=%s hash=%s ack=%d", tostring(iwl.revision or 0), tostring(iwl.hash or "0"), PeerCount(iwl.lastAckByPeer)))
            print(string.format("  GTree   : rev=%s hash=%s ack=%d", tostring(gt.revision or 0), tostring(gt.hash or "0"), PeerCount(gt.lastAckByPeer)))
            print(string.format("  GBank   : rev=%s hash=%s from=%s ack=%d", tostring(gb.revision or 0), tostring(gb.hash or "0"), tostring(gb.lastSyncFrom or "?"), PeerCount(gb.lastAckByPeer)))
            print(string.format("  Ledger  : rev=%s hash=%s from=%s ack=%d", tostring(gbl.revision or 0), tostring(gbl.hash or "0"), tostring(gbl.lastSyncFrom or "?"), PeerCount(gbl.lastAckByPeer)))
            if dkp.lastConflictReason then print(string.format("  DKP Conflict    : %s from %s", tostring(dkp.lastConflictReason), tostring(dkp.lastConflictFrom or "?"))) end
            if rec.lastConflictReason then print(string.format("  Recruit Conflict: %s from %s", tostring(rec.lastConflictReason), tostring(rec.lastConflictFrom or "?"))) end
            if kick.lastConflictReason then print(string.format("  Kick Conflict   : %s from %s", tostring(kick.lastConflictReason), tostring(kick.lastConflictFrom or "?"))) end
            if iwl.lastConflictReason then print(string.format("  InactWL Conflict: %s from %s", tostring(iwl.lastConflictReason), tostring(iwl.lastConflictFrom or "?"))) end
            if gt.lastConflictReason then print(string.format("  GTree Conflict  : %s from %s", tostring(gt.lastConflictReason), tostring(gt.lastConflictFrom or "?"))) end
            if gb.lastConflictReason then print(string.format("  GBank Conflict  : %s from %s", tostring(gb.lastConflictReason), tostring(gb.lastConflictFrom or "?"))) end
            if gbl.lastConflictReason then print(string.format("  Ledger Conflict : %s from %s", tostring(gbl.lastConflictReason), tostring(gbl.lastConflictFrom or "?"))) end
            local evState
            if ev.ok then
                evState = ev.truncated and "OK (truncated window)" or "OK"
            else
                evState = "BROKEN:" .. tostring(ev.reason or "?")
            end
            print(string.format("  EventLog: %s (%s entries checked)", evState, tostring(ev.checked or 0)))
        elseif sub == "verify" then
            local ev = MTR.VerifyGuildEventChain and MTR.VerifyGuildEventChain() or { ok = true, checked = 0 }
            if ev.ok then
                MTR.MP("Event chain verified: " .. tostring(ev.checked or 0) .. " entries.")
            else
                MTR.MPE("Event chain broken at entry " .. tostring(ev.brokenAt or 0) .. " (" .. tostring(ev.reason or "?") .. ")")
            end
        elseif sub == "repair" then
            local domain = (rest or "all"):lower()
            local did = false
            if domain == "all" or domain == "dkp" then
                if MTR.DKPRequestFullSync then MTR.DKPRequestFullSync() did = true end
            end
            if domain == "all" or domain == "gtree" or domain == "guildtree" then
                if IsInGuild() then
                    local gtHash = "0"
                    if MTR.GetSyncAuditStatus then
                        local ss = MTR.GetSyncAuditStatus()
                        gtHash = (ss and ss.guildTree and ss.guildTree.hash) or "0"
                    end
                    if MTR.SendGuildScoped then MTR.SendGuildScoped("MekTownGT", "GT:REQ:" .. tostring(gtHash)) else SendAddonMessage("MekTownGT", "GT:REQ:" .. tostring(gtHash), "GUILD") end
                    did = true
                end
            end
            if domain == "all" or domain == "recruit" then
                if IsInGuild() then
                    local rhHash = "0"
                    if MTR.GetSyncAuditStatus then
                        local ss = MTR.GetSyncAuditStatus()
                        rhHash = (ss and ss.recruit and ss.recruit.hash) or "0"
                    end
                    if MTR.SendGuildScoped then MTR.SendGuildScoped("MekTownRH", "RH:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(rhHash)) else SendAddonMessage("MekTownRH", "RH:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(rhHash), "GUILD") end
                    did = true
                end
            end
            if domain == "all" or domain == "kick" then
                if IsInGuild() then
                    local kkHash = "0"
                    if MTR.GetSyncAuditStatus then
                        local ss = MTR.GetSyncAuditStatus()
                        kkHash = (ss and ss.kick and ss.kick.hash) or "0"
                    end
                    if MTR.SendGuildScoped then MTR.SendGuildScoped("MekTownKK", "KK:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(kkHash)) else SendAddonMessage("MekTownKK", "KK:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(kkHash), "GUILD") end
                    did = true
                end
            end
            if domain == "all" or domain == "inactivewl" or domain == "whitelist" then
                if IsInGuild() then
                    local iwHash = "0"
                    if MTR.GetSyncAuditStatus then
                        local ss = MTR.GetSyncAuditStatus()
                        iwHash = (ss and ss.inactivityWhitelist and ss.inactivityWhitelist.hash) or "0"
                    end
                    if MTR.SendGuildScoped then MTR.SendGuildScoped("MekTownIW", "IW:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(iwHash)) else SendAddonMessage("MekTownIW", "IW:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(iwHash), "GUILD") end
                    did = true
                end
            end
            if domain == "all" or domain == "gbank" then
                if IsInGuild() then
                    local gbHash = "0"
                    if MTR.GetSyncAuditStatus then
                        local ss = MTR.GetSyncAuditStatus()
                        gbHash = (ss and ss.guildBankSnapshot and ss.guildBankSnapshot.hash) or "0"
                    end
                    if MTR.SendGuildScoped then MTR.SendGuildScoped("MekTownGB", "GB:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(gbHash)) else SendAddonMessage("MekTownGB", "GB:REQ:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(gbHash), "GUILD") end
                    did = true
                end
            end
            if domain == "all" or domain == "ledger" or domain == "gledger" then
                if IsInGuild() then
                    local glHash = "0"
                    if MTR.GetSyncAuditStatus then
                        local ss = MTR.GetSyncAuditStatus()
                        glHash = (ss and ss.guildBankLedger and ss.guildBankLedger.hash) or "0"
                    end
                    if MTR.GuildBankLedger and MTR.GuildBankLedger.RequestSync then
                        MTR.GuildBankLedger.RequestSync()
                    elseif MTR.SendGuildScoped then
                        MTR.SendGuildScoped("MekTownGBL", "GL:R:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(glHash))
                    else
                        SendAddonMessage("MekTownGBL", "GL:R:" .. tostring(MTR.playerName or "?") .. ":" .. tostring(glHash), "GUILD")
                    end
                    did = true
                end
            end
            if did then
                MTR.MP("Sync repair request sent for: " .. domain)
            else
                MTR.MPE("No sync repair action available.")
            end
        else
            MTR.MP("/mek sync [status|verify|repair [dkp|guildtree|recruit|kick|inactivewl|gbank|ledger|all]]")
        end

    elseif cmd=="dkp" then
        local sub,rest=args:match("^(%S+)%s*(.*)")
        sub=(sub or ""):lower()
        if sub=="award" then
            if not (MTR.CanAccess and MTR.CanAccess("DKP")) then MTR.MPE("No DKP write permission.") return end
            local n,pts,reason=rest:match("^(%S+)%s+(%d+)%s*(.*)")
            if not n then MTR.MPE("/mek dkp award <n> <pts> [reason]") return end
            MTR.DKPAdd(n,tonumber(pts),reason~="" and reason or "Officer award",MTR.playerName)
            MTR.MP("Awarded "..pts.." to "..n..". Balance: "..MTR.DKPBalance(n))
            if IsInGuild() and MTR.DKPSyncToRaidSafe then MTR.DKPSyncToRaidSafe() end
        elseif sub=="deduct" then
            if not (MTR.CanAccess and MTR.CanAccess("DKP")) then MTR.MPE("No DKP write permission.") return end
            local n,pts,reason=rest:match("^(%S+)%s+(%d+)%s*(.*)")
            if not n then MTR.MPE("/mek dkp deduct <n> <pts> [reason]") return end
            MTR.DKPAdd(n,-tonumber(pts),reason~="" and reason or "Officer deduction",MTR.playerName)
            MTR.MP("Deducted "..pts.." from "..n..". Balance: "..MTR.DKPBalance(n))
            if IsInGuild() and MTR.DKPSyncToRaidSafe then MTR.DKPSyncToRaidSafe() end
        elseif sub=="set" then
            if not MTR.isGM then MTR.MPE("GM only.") return end
            local n,pts=rest:match("^(%S+)%s+(%d+)")
            if not n then MTR.MPE("/mek dkp set <n> <pts>") return end
            MTR.DKPSet(n,tonumber(pts),MTR.playerName)
            MTR.MP("Set "..n.."'s balance to "..pts)
        elseif sub=="balance" then
            local n=rest:match("^(%S+)")
            if not n then MTR.MPE("/mek dkp balance <n>") return end
            MTR.MP(n.." has "..MTR.DKPBalance(n).." DKP.")
        elseif sub=="standings" then
            MTR.MP("DKP Standings:")
            for i,e in ipairs(MTR.DKPStandings()) do
                print(string.format("  %d. %s - %d pts",i,e.name,e.balance))
                if i>=25 then print("  ... use /mek config for full list") break end
            end
        elseif sub=="publish" then
            local chan,target=rest:match("^(%S*)%s*(%S*)")
            MTR.DKPPublish(chan~="" and chan:upper() or nil,target~="" and target or nil)
        elseif sub=="sync" then MTR.DKPSyncToRaid()
        elseif sub=="snapshot" then
            if not (MTR.CanAccess and MTR.CanAccess("DKP")) then MTR.MPE("No DKP snapshot permission.") return end
            if MTR.DKPSendFullSnapshot then MTR.DKPSendFullSnapshot("manual") end
        else MTR.MP("/mek dkp [award|deduct|set|balance|standings|publish|sync|snapshot]") end

    elseif cmd=="auction" then
        -- /mek auction <item or link> [min] [secs] [rw]
        local item=args:match("^%s*(.-)%s*$")
        if item=="" then MTR.MPE("/mek auction <item> [min] [secs] [rw]") return end
        local parts={} for p in item:gmatch("%S+") do parts[#parts+1]=p end
        local useRW=(parts[#parts]=="rw") if useRW then tremove(parts,#parts) end
        local timer=tonumber(parts[#parts]) and tonumber(tremove(parts,#parts)) or nil
        local minB =tonumber(parts[#parts]) and tonumber(tremove(parts,#parts)) or nil
        item=table.concat(parts," ")
        if item=="" then MTR.MPE("/mek auction <item> [min] [secs] [rw]") return end
        MTR.AuctionOpen(item,minB,timer,useRW)

    elseif cmd=="roll" then
        -- /mek roll <item or link> [type] [secs] [rw]
        local item=args:match("^%s*(.-)%s*$")
        if item=="" then MTR.MPE("/mek roll <item> [type] [secs] [rw]") return end
        local rt="MS"
        for _,rtype in ipairs(MTR.ROLL_TYPES) do
            local pos=item:find(rtype,1,true)
            if pos then rt=rtype item=item:sub(1,pos-1):match("^%s*(.-)%s*$") break end
        end
        local useRW=item:find(" rw$") and true or false
        item=item:gsub(" rw$",""):match("^%s*(.-)%s*$")
        local timer=item:match("(%d+)$")
        if timer then item=item:sub(1,#item-#timer):match("^%s*(.-)%s*$") timer=tonumber(timer) end
        if item=="" then MTR.MPE("/mek roll <item> [type] [secs] [rw]") return end
        MTR.RollOpen(item,rt,timer,useRW)

    elseif cmd=="att" then
        local sub,rest=args:match("^(%S+)%s*(.*)")
        sub=(sub or ""):lower()
        if sub=="start" then
            if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
            MTR.AttSnapshot(rest~="" and rest or nil)
        elseif sub=="end" then
            if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
            MTR.AttEnd()
        elseif sub=="boss"   then
            if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
            if rest=="" then MTR.MPE("/mek att boss <n>") return end
            MTR.AttBossKill(rest)
        elseif sub=="check"  then
            local pname=rest:match("^(%S+)")
            if not pname then MTR.MPE("/mek att check <player>") return end
            local log=MTR.db.attendanceLog[pname]
            if not log or #log==0 then MTR.MP("No attendance data for "..pname) return end
            local raids,bosses,dkpTotal=0,0,0
            for _,e in ipairs(log) do
                if e.type=="attendance" then raids=raids+1 end
                if e.type=="boss"       then bosses=bosses+1 end
                dkpTotal=dkpTotal+(e.dkp or 0)
            end
            MTR.MP(pname..": "..raids.." raids, "..bosses.." bosses, "..dkpTotal.." DKP earned")
        else MTR.MP("/mek att [start|end|boss|check]") end

    elseif cmd=="chars" then
        if MTR.OpenCharVault then MTR.OpenCharVault()
        else MTR.MPE("CharVault module not loaded.") end

    elseif cmd=="radar" then
        MTR.OpenGroupRadar()

    elseif cmd=="lfg" then
        if MTR.OpenFindGroup then MTR.OpenFindGroup() end

    elseif cmd=="gads" then
        local sub = args:lower():match("^%s*(.-)%s*$")
        if not MTR.GuildAds then MTR.MPE("GuildAds module not loaded.") return end
        if sub=="start" or sub=="stop" or sub=="now" then
            if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Guild Ads are officer-only.") return end
        end
        if sub=="start" then
            MTR.GuildAds.Start()
        elseif sub=="stop" then
            MTR.GuildAds.Stop()
        elseif sub=="now" then
            MTR.GuildAds.PostNow()
        else
            MTR.MP("Guild Ads: " .. (MTR.GuildAds.active and "|cff00ff00ACTIVE|r" or "|cffff4444STOPPED|r"))
            MTR.MP("  /mek gads start  —  begin auto-posting")
            MTR.MP("  /mek gads stop   —  cancel auto-posting")
            MTR.MP("  /mek gads now    —  post next message immediately")
        end

    elseif cmd=="inactive" then
        local sub,rest=args:match("^(%S+)%s*(.*)")
        sub=(sub or ""):lower()
        if sub=="scan" then MTR.InactRunScan(false)
        elseif sub=="kick" then
            if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then MTR.MPE("No permission for inactive kick tool.") return end
            MTR.InactRunScan(true)
        elseif sub=="debug" then MTR.InactDebugDump()
        elseif sub=="whitelist" then
            local action,name=rest:match("^(%S+)%s+(%S+)")
            action=(action or ""):lower()
            if not name then MTR.MPE("/mek inactive whitelist add/remove <n>") return end
            if action=="add" then
                if MTR.InactSetWhitelist and MTR.InactSetWhitelist(name, true) then MTR.MP("Whitelisted: "..name) end
            elseif action=="remove" then
                if MTR.InactSetWhitelist and MTR.InactSetWhitelist(name, false) then MTR.MP("Removed: "..name) end
            else MTR.MPE("Use: add or remove") end
        else MTR.MP("/mek inactive [scan|kick|debug|whitelist add/remove <n>]") end

    elseif cmd=="motd" then
        if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
        if args=="" then
            local keys={} for k in pairs(MTR.db.motdTemplates) do keys[#keys+1]=k end
            MTR.MP("MOTD templates: "..table.concat(keys,", "))
        else
            local tmpl=MTR.db.motdTemplates[args]
            if not tmpl then MTR.MPE("Unknown template: "..args) return end
            GuildSetMOTD(tmpl)
            MTR.MP("MOTD set to '"..args.."' template.")
        end
    else
        MTR.MPE("Unknown command - /mek help")
    end
end


SlashCmdList["MTRID"] = function()
    if not MTR then
        print("|cffff4040[MekTown]|r Addon not initialized.")
        return
    end
    if GuildRoster then pcall(GuildRoster) end
    local info
    if MTR.GetGuildIdentityInfo then
        info = MTR.GetGuildIdentityInfo()
    else
        local realm = (GetRealmName and GetRealmName()) or "UnknownRealm"
        local guild = (GetGuildInfo and GetGuildInfo("player")) or "LOADING..."
        info = { guildName = guild, realm = realm, guildKey = tostring(realm) .. "|" .. tostring(guild) }
    end
    print("|cff00c0ff[MekTown]|r Guild: |cffffff00" .. tostring(info.guildName or "LOADING...") .. "|r  Realm: |cffffff00" .. tostring(info.realm or "UnknownRealm") .. "|r")
    print("|cff00c0ff[MekTown]|r Guild Key: |cffaaaaaa" .. tostring(info.guildKey or "Unknown|LOADING...") .. "|r")
    print("|cff00c0ff[MekTown]|r Guild Id: |cffaaaaaa" .. tostring(info.guildId or "(unset)") .. "|r")
end
