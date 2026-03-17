-- ============================================================================
-- Attendance.lua  v5.0
-- Raid attendance snapshots, boss kill DKP awards, session tracking
-- ============================================================================
local MTR = MekTownRecruit

MTR.RAID_ZONES = {
    ["Karazhan"]=true,         ["Gruul's Lair"]=true,
    ["Magtheridon's Lair"]=true, ["Serpentshrine Cavern"]=true,
    ["Tempest Keep"]=true,     ["Hyjal Summit"]=true,
    ["Black Temple"]=true,     ["Sunwell Plateau"]=true,
    ["Zul'Aman"]=true,         ["Molten Core"]=true,
    ["Blackwing Lair"]=true,   ["Ruins of Ahn'Qiraj"]=true,
    ["Ahn'Qiraj Temple"]=true, ["Naxxramas"]=true,
}

-- ============================================================================
-- HELPERS
-- ============================================================================
local function AttGetPlayers()
    local players = {}
    players[MTR.playerName] = true
    if IsInRaid() then
        for i = 1, GetNumRaidMembers() do
            local n = UnitName("raid"..i)
            if n then players[n] = true end
        end
    elseif IsInGroup() then
        for i = 1, GetNumPartyMembers() do
            local n = UnitName("party"..i)
            if n then players[n] = true end
        end
    end
    return players
end

-- ============================================================================
-- PUBLIC
-- ============================================================================
function MTR.AttSnapshot(zone)
    if not IsInRaid() and not IsInGroup() then
        MTR.MPE("Not in a group - cannot snapshot attendance.")
        return
    end
    zone = zone or GetRealZoneText() or "Unknown"
    local players = AttGetPlayers()
    MTR.currentSession = { zone=zone, startTime=date("%Y-%m-%d %H:%M:%S"), startTs=time(), players=players, bosses={} }
    local count = 0
    for pname in pairs(players) do
        count = count + 1
        MTR.DKPAdd(pname, MTR.db.dkpPerRaid, "Raid attendance: " .. zone, "System")
        if not MTR.db.attendanceLog[pname] then MTR.db.attendanceLog[pname] = {} end
        table.insert(MTR.db.attendanceLog[pname], { date=date("%Y-%m-%d %H:%M:%S"), zone=zone, type="attendance", dkp=MTR.db.dkpPerRaid })
    end
    MTR.inInstance = true
    MTR.MP("Attendance snapshot: " .. zone .. " - " .. count .. " players. +" .. MTR.db.dkpPerRaid .. " DKP each.")
end

function MTR.AttBossKill(bossName)
    local zone    = GetRealZoneText() or "Unknown"
    local players = AttGetPlayers()
    for pname in pairs(players) do
        MTR.DKPAdd(pname, MTR.db.dkpPerBoss, "Boss kill: " .. bossName, "System")
        if not MTR.db.attendanceLog[pname] then MTR.db.attendanceLog[pname] = {} end
        table.insert(MTR.db.attendanceLog[pname], { date=date("%Y-%m-%d %H:%M:%S"), zone=zone, type="boss", boss=bossName, dkp=MTR.db.dkpPerBoss })
    end
    if MTR.currentSession then table.insert(MTR.currentSession.bosses, bossName) end
    table.insert(MTR.db.bossKillLog, { date=date("%Y-%m-%d %H:%M:%S"), boss=bossName, zone=zone })
    if #MTR.db.bossKillLog > 200 then tremove(MTR.db.bossKillLog, 1) end
    local c = 0
    for _ in pairs(players) do c = c + 1 end
    MTR.MP(bossName .. " killed! +" .. MTR.db.dkpPerBoss .. " DKP to " .. c .. " players.")
end

function MTR.AttEnd()
    if not MTR.currentSession then MTR.MPE("No active session.") return end
    local dur = math.floor((time() - MTR.currentSession.startTs) / 60)
    MTR.MP("Session ended: " .. MTR.currentSession.zone .. " - " .. #MTR.currentSession.bosses .. " bosses - " .. dur .. "m")
    MTR.currentSession = nil
    MTR.inInstance     = false
end

-- ============================================================================
-- AUTO-SNAPSHOT on raid zone entry
-- ============================================================================
local attFrame = CreateFrame("Frame")
attFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
attFrame:SetScript("OnEvent", function()
    if not MTR.initialized or not MTR.db then return end
    if not MTR.db.attendanceEnabled or not MTR.db.attendanceAutoSnapshot then return end
    if not MTR.isOfficer then return end
    local zone = GetRealZoneText() or ""
    if MTR.RAID_ZONES[zone] and not MTR.inInstance then
        MTR.After(3, function()
            if IsInRaid() then
                MTR.AttSnapshot(zone)
            end
        end)
    elseif not MTR.RAID_ZONES[zone] and MTR.inInstance then
        MTR.AttEnd()
    end
end)
