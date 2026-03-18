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

    print("|cff00c0ff[MekTown Recruit]|r v2.0.0-beta Ready — profile |cffffff00"..
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
SlashCmdList["MEKTOWN"]=function(msg)
    if not MTR.initialized then MTR.MPE("Not ready yet.") return end
    local cmd,args=msg:match("^(%S*)%s*(.-)$")
    cmd=(cmd or ""):lower()

    if cmd=="" or cmd=="help" then
        MTR.MP("Commands:")
        print("  /mek config              - Open config window")
        print("  /mek on / off            - Enable/disable scanner")
        print("  /mek debug               - Toggle Enable Debug")
        print("  /mek test                - Test popup")
        print("  /mek add <kw>            - Add keyword")
        print("  /mek list                - List keywords")
        print("  /mek invite on/off       - Guild auto-invite")
        print("  /mek dkp award <n> <pts> [reason]")
        print("  /mek dkp deduct <n> <pts> [reason]")
        print("  /mek dkp set <n> <pts>   - GM only")
        print("  /mek dkp balance <n>")
        print("  /mek dkp standings")
        print("  /mek dkp publish [chan]")
        print("  /mek dkp sync")
        print("  /mek dkp snapshot       - Officer full verified ledger snapshot")
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
        print("  /mek ledgerdebug [show|clear|on|off] (requires Enable Debug)")

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
            if MTR.GuildBankLedger and MTR.GuildBankLedger.DebugEnable then MTR.GuildBankLedger.DebugEnable(true) end
        elseif sub=="off" then
            if MTR.GuildBankLedger and MTR.GuildBankLedger.DebugEnable then MTR.GuildBankLedger.DebugEnable(false) end
            MTR.SetDebugEnabled(false)
        else
            MTR.GuildBankLedger.DebugDump(60)
        end

    elseif cmd=="on" then
        MTR.db.enabled=true  MTR.MP("|cff00ff00Scanner enabled|r")

    elseif cmd=="off" then
        MTR.db.enabled=false MTR.MP("|cffff4444Scanner disabled|r")

    elseif cmd=="debug" then
        local enabled = not MTR.IsDebugEnabled()
        MTR.SetDebugEnabled(enabled)
        MTR.MP("Enable Debug: "..(enabled and "|cff00ff00ON|r" or "|cffff4444OFF|r"))

    elseif cmd=="test" then

    elseif cmd=="add" and args~="" then
        local kw=args:lower()
        table.insert(MTR.db.keywords,kw)
        MTR.MP("Added keyword: |cffffff00"..kw.."|r")

    elseif cmd=="list" then
        MTR.MP("Keywords ("..#MTR.db.keywords.."):")
        for i,kw in ipairs(MTR.db.keywords) do print("  "..i..". "..kw) end

    elseif cmd=="invite" then
        local sub=args:lower()
        if sub=="on"  then MTR.db.enableGuildInvites=true  MTR.MP("Auto-invite: |cff00ff00ON|r")
        elseif sub=="off" then MTR.db.enableGuildInvites=false MTR.MP("Auto-invite: |cffff4444OFF|r")
        else MTR.MP("/mek invite [on|off]") end

    elseif cmd=="dkp" then
        local sub,rest=args:match("^(%S+)%s*(.*)")
        sub=(sub or ""):lower()
        if sub=="award" then
            local n,pts,reason=rest:match("^(%S+)%s+(%d+)%s*(.*)")
            if not n then MTR.MPE("/mek dkp award <n> <pts> [reason]") return end
            MTR.DKPAdd(n,tonumber(pts),reason~="" and reason or "Officer award",MTR.playerName)
            MTR.MP("Awarded "..pts.." to "..n..". Balance: "..MTR.DKPBalance(n))
        elseif sub=="deduct" then
            local n,pts,reason=rest:match("^(%S+)%s+(%d+)%s*(.*)")
            if not n then MTR.MPE("/mek dkp deduct <n> <pts> [reason]") return end
            MTR.DKPAdd(n,-tonumber(pts),reason~="" and reason or "Officer deduction",MTR.playerName)
            MTR.MP("Deducted "..pts.." from "..n..". Balance: "..MTR.DKPBalance(n))
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
            if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers only.") return end
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
            if not (MTR.isOfficer or MTR.isGM) then MTR.MPE("Officers and above can use the kick tool.") return end
            MTR.InactRunScan(true)
        elseif sub=="debug" then MTR.InactDebugDump()
        elseif sub=="whitelist" then
            local action,name=rest:match("^(%S+)%s+(%S+)")
            action=(action or ""):lower()
            if not name then MTR.MPE("/mek inactive whitelist add/remove <n>") return end
            if action=="add"    then MTR.db.inactivityWhitelist[name]=true  MTR.MP("Whitelisted: "..name)
            elseif action=="remove" then MTR.db.inactivityWhitelist[name]=nil MTR.MP("Removed: "..name)
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
