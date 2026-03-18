-- ============================================================================
-- GroupRadar.lua  v8.0
-- Direct port of RecruitRadar 2 WeakAura by Gordu/Kandy
-- Source: https://db.ascension.gg/?weakaura=735.rev:11
--
-- v8.0 changes:
--   • LFG post timer and detail-frame refresh both use MTR.TickAdd() instead
--     of individual CreateFrame()/OnUpdate — zero extra OnUpdate handlers
--   • Frame pooling: recruiter rows and feed rows are reused across refreshes
--     instead of being created fresh each second (eliminates frame accumulation)
--   • Event handler wrapped in pcall for error safety
--   • All GR.Cfg() reads write directly to MTR.db so settings persist without
--     requiring the config window to be open
-- ============================================================================
local MTR = MekTownRecruit

local GR = {}
MTR.GroupRadar = GR

-- ============================================================================
-- PATTERNS  (identical to RR2 WA)
-- ============================================================================
GR.patterns = {
    msLevelingPatterns = {"ms.*lvl","ms.*level","ms.*aura","mana.*lvl","mana.*level"},
    msGoldPatterns     = {"ms.*gold","lf.*gold","mana.*gold"},
    -- Bonus Coins (BC) patterns — matches groups specifically advertising BC runs.
    -- A message must contain a BC indicator AND NOT contain a no-BC indicator.
    -- The no-BC check is done in HandleChatMessage before this pattern fires.
    bcPatterns = {
        "lf.*%f[%a]bc%f[%A]","lf.*bonus.?coin","%f[%a]bc%f[%A].*lf",
        "need.*%f[%a]bc%f[%A]","%+%f[%a]bc%f[%A]","bonus.?coin.*run",
        "keystone.*%f[%a]bc%f[%A]","%f[%a]bc%f[%A].*keystone",
        "m%+.*%f[%a]bc%f[%A]","%f[%a]bc%f[%A].*m%+",
    },
    -- Phrases that explicitly exclude BC — if any match, it is NOT a BC run
    noBcPatterns = {
        "no%s*%f[%a]bc%f[%A]","without%s*%f[%a]bc%f[%A]","w/o%s*%f[%a]bc%f[%A]",
        "%-bc","0%s*%f[%a]bc%f[%A]","non%-bc","nobc",
        "no bonus coin","without bonus coin",
    },
    lfmDpsPatterns     = {
        "lf.*dps","lf.*%f[%a]dd%f[%A]","lf.*dmg",
        "need.*dps","need.*%f[%a]dd%f[%A]","need.*dmg",
        "need.*%f[%a]all%f[%A]",
        "keystone.*%d+%).*dps","keystone.*%d+%).*%f[%a]dd%f[%A]","keystone.*%d+%).*dmg",
    },
    lfmTankPatterns = {"lf.*tank","need.*tank","keystone.*%d+%).*tank"},
    lfmHealPatterns = {"lf.*heal","need.*heal","keystone.*%d+%).*heal"},
    lfmAllPatterns  = {
        "lf.*kara","lf.*%f[%a]kc%f[%A]",
        "keystone.*%d+%).*%f[%a]all%f[%A]",
        "lf.*keystone","need.*%f[%a]all%f[%A]",
        "keystone.*%d+%).*lf",
    },
}

-- ============================================================================
-- DEFAULT CONFIG
-- ============================================================================
GR.memberRecommendedConfig = {
    alertLfmDps       = true,
    alertLfmTank      = true,
    alertLfmHeal      = true,
    textAlertLfmDps   = true,
    textAlertLfmTank  = true,
    textAlertLfmHeal  = true,
    alertMsGold       = false,
    alertMsLeveling   = false,
    alertBc           = false,
    textAlertMsGold   = false,
    textAlertMsLeveling = false,
    textAlertBc       = false,
    doNotAlertInGroup = false,
    doNotAlertInCombat = false,
    dontAlertInInstance = false,
    silentNotifications = false,
    messageMustContain = "",
    messageMustNotContain = "recruit,lfg,>,http,wtb,wts,anal,sell,carry,need to,looking to join a group",
}

GR.defaultConfig = {
    -- Text alerts (chat line) — ALL false. Nothing printed to chat until opted in.
    textAlertMsLeveling   = false,
    textAlertMsGold       = false,
    textAlertLfmDps       = false,
    textAlertLfmTank      = false,
    textAlertLfmHeal      = false,
    -- Popup alerts — ALL false. Nothing pops on a fresh install.
    -- User must explicitly check each box to enable what they want.
    alertMsLeveling       = false,
    alertMsGold           = false,
    alertBc               = false,
    textAlertBc           = false,
    alertLfmDps           = false,
    alertLfmTank          = false,
    alertLfmHeal          = false,
    -- Suppression flags — all false by default so alerts actually fire.
    -- User can check these in the config to suppress in specific situations.
    silentNotifications   = false,
    doNotAlertInCombat    = false,
    doNotAlertInGroup     = false,
    dontAlertInInstance   = false,
    -- Durations (seconds)
    frameDuration               = 10,
    dontDisplayDeclinedDuration = 300,
    dontDisplaySpammers         = 180,
    hideFromDetailAfter         = 180,
    -- Filters
    messageMustContain    = "",
    messageMustNotContain = "recruit,lfg,>,http,wtb,wts,anal,sell,carry,need to,looking to join a group",
    myRole        = 4,
    lastLfgContent = "Mythic+",
    lfgRepeatMins = 10,
}

-- ============================================================================
-- CONFIG ACCESSOR  — reads & writes live to MTR.db
-- ============================================================================
local function Cfg()
    if not MTR.db then return GR.defaultConfig end
    if not MTR.db.groupRadarConfig then
        MTR.db.groupRadarConfig = MTR.DeepCopy(GR.defaultConfig)
    end
    local c = MTR.db.groupRadarConfig
    for k, v in pairs(GR.defaultConfig) do
        if c[k] == nil then c[k] = v end
    end
    return c
end

-- ============================================================================
-- ACTIVE SEARCH BUCKETS
-- ============================================================================
GR.activeSearches        = {}
GR.activeMsLevelSearches = {}
GR.activeMsGoldSearches  = {}
GR.activeBcSearches      = {}   -- Bonus Coins runs
GR.activeLfmDpsSearches  = {}
GR.activeLfmTankSearches = {}
GR.activeLfmHealSearches = {}

GR.ignoreList  = {}
GR.spammerList = {}
GR.lastDisplayedFrame = 0

-- Scan activity feed
GR.scanFeed = {}
GR.FEED_MAX = 60

-- UI references
GR.detailFrame      = nil
GR.findFrame        = nil
GR.currentSearchGroup = nil
GR.currentTabLabel  = "All"
GR.detailTabs       = {}
GR.minimapBtn       = nil

-- LFG auto-post state
GR.lfgActive   = false
GR.lfgMessage  = ""
GR.lfgInterval = 600
GR.lfgTimer    = 0
GR.minimapLFGBtn = nil

-- ============================================================================
-- FRAME POOL HELPERS
-- Reuse row frames across refreshes instead of creating new ones each second.
--
-- PoolGet(content, idx, w, h, yStep)
--   Returns the frame at position idx inside content, creating if needed.
--   Positions it at the correct y offset for the given row height + spacing.
--
-- PoolHideFrom(content, n)
--   Hides all pool frames from index n upward.
-- ============================================================================
local function PoolGet(content, idx, w, h, yStep)
    if not content._pool then content._pool = {} end
    local row = content._pool[idx]
    if not row then
        row = CreateFrame("Frame", nil, content)
        content._pool[idx] = row
    end
    row:SetSize(w, h)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(idx-1)*(yStep or h))
    row:Show()
    return row
end

local function PoolHideFrom(content, n)
    if not content._pool then return end
    for i = n, #content._pool do
        if content._pool[i] then content._pool[i]:Hide() end
    end
end

-- ============================================================================
-- LRE + INVITE MESSAGE  (WA Section 6)
-- ============================================================================
local function GetLRE()
    if not MysticEnchantUtil or not MysticEnchantUtil.GetAppliedEnchantCountByQuality then return "" end
    local ed = MysticEnchantUtil.GetAppliedEnchantCountByQuality("player")
    if ed then ed = ed[5] end
    if ed then
        for sid in pairs(ed) do
            local link = GetSpellLink and GetSpellLink(sid)
            if link and link ~= "" then
                return link
            end
            local n = GetSpellInfo and GetSpellInfo(sid)
            if n and n ~= "" then
                return "[" .. n .. "]"
            end
        end
    end
    return ""
end

local function BuildInviteMsg()
    local ilvl = math.floor(GetAverageItemLevel() + 0.5)
    local lre  = GetLRE()
    local cfg  = Cfg()
    local roleNames = {[2]="Tank",[3]="Healer",[4]="DPS",[5]="DPS (Ranged)",[6]="DPS (Melee)"}
    local role    = roleNames[cfg.myRole] or ""
    local roleStr = role ~= "" and (role .. " ") or ""
    local lreStr  = lre  ~= "" and (" (" .. lre .. ")") or ""
    return "inv " .. roleStr .. lreStr .. " " .. ilvl .. " ilvl"
end

-- ============================================================================
-- BUCKET HELPERS  (WA Section 8)
-- ============================================================================
local function RecordActiveSearch(sender, message, bucket)
    local now = GetTime()
    for _, rec in ipairs(bucket) do
        if rec.player == sender then rec.message=message rec.lastUpdate=now return end
    end
    bucket[#bucket+1] = {player=sender, message=message, lastUpdate=now}
    GR.UpdateDetailFrame()
end

local function CleanupActiveSearches()
    local now    = GetTime()
    local expiry = Cfg().hideFromDetailAfter or 180
    local function clean(list)
        for i = #list, 1, -1 do
            if now - list[i].lastUpdate > expiry then table.remove(list, i) end
        end
    end
    clean(GR.activeSearches)
    clean(GR.activeMsLevelSearches)
    clean(GR.activeMsGoldSearches)
    clean(GR.activeBcSearches)
    clean(GR.activeLfmDpsSearches)
    clean(GR.activeLfmTankSearches)
    clean(GR.activeLfmHealSearches)
end

-- ============================================================================
-- SCAN FEED
-- ============================================================================
local function FeedPush(sender, message, result, cats)
    table.insert(GR.scanFeed, 1, {ts=time(), sender=sender, message=message, result=result, cats=cats or ""})
    if #GR.scanFeed > GR.FEED_MAX then table.remove(GR.scanFeed) end
end

-- ============================================================================
-- TEXT ALERT  (WA Section 7 — ShowLFMTextAlert)
-- ============================================================================
local function ShowLFMTextAlert(sender, message)
    local link = "|Hplayer:"..sender.."|h|cff00ccff["..sender.."]|h|r"
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[GroupRadar]:|r " .. link .. ": " .. message)
end

-- ============================================================================
-- GROUP RADAR POPUP ALERT  (distinct from Recruit popup)
-- ============================================================================
local function ShowLFMAlert(sender, message, categoryText)
    local cfg = Cfg()
    if cfg.doNotAlertInCombat  and UnitAffectingCombat("player") then return end
    if cfg.doNotAlertInGroup   and IsInGroup()                   then return end
    if cfg.dontAlertInInstance and IsInInstance()                 then return end
    if cfg.silentNotifications                                   then return end

    local dur = cfg.frameDuration or 10
    if dur == 0 then PlaySound(8960) return end
    if GetTime() - GR.lastDisplayedFrame <= dur then return end
    GR.lastDisplayedFrame = GetTime()

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(330, 164)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 240)
    f:SetBackdrop({
        bgFile="",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=false,tileSize=0,edgeSize=32,insets={left=8,right=8,top=8,bottom=8},
    })
    f:SetBackdropColor(0,0,0,0)
    do
        local _bt=f:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\Buttons\WHITE8x8")
        _bt:SetAllPoints(f)
        _bt:SetVertexColor(0.02,0.03,0.05,0.97)
    end
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart",f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local titleBar=f:CreateTexture(nil,"OVERLAY")
    titleBar:SetTexture("Interface\DialogFrame\UI-DialogBox-Header")
    titleBar:SetTexCoord(0,1,0.2,0.8)
    titleBar:SetVertexColor(0.05,0.30,0.55,1.0)
    titleBar:SetHeight(26)
    titleBar:SetPoint("TOPLEFT",f,"TOPLEFT",9,-2)
    titleBar:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-2)

    local titleEdge=f:CreateTexture(nil,"OVERLAY")
    titleEdge:SetTexture("Interface\Buttons\WHITE8x8")
    titleEdge:SetVertexColor(0.30,0.75,1.0,1.0)
    titleEdge:SetHeight(2)
    titleEdge:SetPoint("TOPLEFT",f,"TOPLEFT",9,-26)
    titleEdge:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-26)

    local tag = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tag:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -7)
    tag:SetText("|cff66ccffMekTown|r |cffd4af37Group Radar|r")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    local hdr=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    hdr:SetPoint("TOP",f,"TOP",0,-12)
    hdr:SetText("|cff66ccff"..sender.."|r")

    local catFS=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    catFS:SetPoint("TOP",hdr,"BOTTOM",0,-4)
    catFS:SetText((categoryText and categoryText ~= "" and categoryText) or "|cffaaaaaaLFG match|r")

    local sep=f:CreateTexture(nil,"ARTWORK")
    sep:SetColorTexture(0.50,0.75,1.0,0.45)
    sep:SetSize(298,1)
    sep:SetPoint("TOP",catFS,"BOTTOM",0,-5)

    local msgFS=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    msgFS:SetPoint("TOPLEFT",f,"TOPLEFT",16,-64)
    msgFS:SetPoint("TOPRIGHT",f,"TOPRIGHT",-16,-64)
    msgFS:SetWordWrap(true)
    msgFS:SetJustifyH("LEFT")
    msgFS:SetText("|cffd8ecff"..MTR.Trunc(message,170).."|r")

    local applyBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    applyBtn:SetSize(134,28)
    applyBtn:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",12,10)
    applyBtn:SetText("|cff00ff00Send Apply Msg|r")
    applyBtn:SetScript("OnClick",function()
        local msg=BuildInviteMsg()
        MTR.SendChatSafe(msg, "WHISPER", nil, sender)
        MTR.MP("|cff66ccff[GroupRadar]|r Whispered "..sender.." — "..msg)
        f:Hide()
    end)

    local ignoreBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    ignoreBtn:SetSize(134,28)
    ignoreBtn:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-12,10)
    ignoreBtn:SetText("Ignore")
    ignoreBtn:SetScript("OnClick",function()
        GR.ignoreList[sender]=GetTime()
        f:Hide()
    end)

    f:Show()
    PlaySound(8960)

    local elapsed=0
    f:SetScript("OnUpdate",function(self,dt)
        elapsed=elapsed+dt
        if elapsed>=dur then
            self:SetScript("OnUpdate",nil)
            self:Hide()
        end
    end)
end

-- ============================================================================
-- MAIN MESSAGE HANDLER  (WA Section 9 — HandleChatMessage, exact port)
-- ============================================================================
local function HandleChatMessage(event, message, sender)
    message = message:gsub("{.-}","")
    CleanupActiveSearches()

    if sender == UnitName("player") then return end

    local cfg = Cfg()

    local isDeclined = GR.ignoreList[sender] and
        (GetTime()-GR.ignoreList[sender]  < (cfg.dontDisplayDeclinedDuration or 300))
    local isSpammer  = GR.spammerList[sender] and
        (GetTime()-GR.spammerList[sender] < (cfg.dontDisplaySpammers or 180))

    local msgLow = message:lower():gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")

    -- Must-NOT-contain
    for pat in (cfg.messageMustNotContain or ""):gmatch("([^,]+)") do
        local p=pat:match("^%s*(.-)%s*$")
        if p~="" and msgLow:match(p) then
            FeedPush(sender,message,"filtered","|cffff4444[blocked:"..p.."]|r") return
        end
    end

    -- Must-contain
    local mustContain=cfg.messageMustContain or ""
    if mustContain~="" then
        local found=false
        for pat in mustContain:gmatch("([^,]+)") do
            local p=pat:match("^%s*(.-)%s*$")
            if p~="" and msgLow:match(p) then found=true break end
        end
        if not found then
            FeedPush(sender,message,"filtered","|cffff4444[must-contain]|r") return
        end
    end

    -- Pattern matching (identical to RR2 WA logic)
    local msMsLeveling,matchesMsGold,matchesBc=false,false,false
    local matchesLfmDps,matchesLfmTank,matchesLfmHeal=false,false,false

    for _,p in ipairs(GR.patterns.msLevelingPatterns) do if msgLow:match(p) then msMsLeveling=true break end end
    for _,p in ipairs(GR.patterns.msGoldPatterns)     do if msgLow:match(p) then matchesMsGold=true break end end
    -- BC: must match a BC pattern AND must NOT match any no-BC phrase
    do
        local hasBC = false
        for _,p in ipairs(GR.patterns.bcPatterns) do if msgLow:match(p) then hasBC=true break end end
        if hasBC then
            local noBC = false
            for _,p in ipairs(GR.patterns.noBcPatterns) do if msgLow:match(p) then noBC=true break end end
            matchesBc = not noBC
        end
    end
    for _,p in ipairs(GR.patterns.lfmDpsPatterns)     do if msgLow:match(p) then matchesLfmDps=true break end end
    for _,p in ipairs(GR.patterns.lfmTankPatterns)    do if msgLow:match(p) then matchesLfmTank=true break end end
    for _,p in ipairs(GR.patterns.lfmHealPatterns)    do if msgLow:match(p) then matchesLfmHeal=true break end end

    if not matchesLfmHeal and not matchesLfmTank and not matchesLfmDps
       and not msMsLeveling and not matchesMsGold then
        for _,p in ipairs(GR.patterns.lfmAllPatterns) do
            if msgLow:match(p) then
                matchesLfmDps=true matchesLfmTank=true matchesLfmHeal=true break
            end
        end
    end

    local anyMatch = msMsLeveling or matchesMsGold or matchesBc or matchesLfmDps or matchesLfmTank or matchesLfmHeal
    if not anyMatch then FeedPush(sender,message,"noMatch","") return end

    -- Record in buckets
    RecordActiveSearch(sender,message,GR.activeSearches)
    if msMsLeveling then RecordActiveSearch(sender,message,GR.activeMsLevelSearches) end
    if matchesMsGold then RecordActiveSearch(sender,message,GR.activeMsGoldSearches) end
    if matchesBc     then RecordActiveSearch(sender,message,GR.activeBcSearches)     end
    if matchesLfmDps  and not(msMsLeveling or matchesMsGold) then RecordActiveSearch(sender,message,GR.activeLfmDpsSearches)  end
    if matchesLfmTank and not(msMsLeveling or matchesMsGold) then RecordActiveSearch(sender,message,GR.activeLfmTankSearches) end
    if matchesLfmHeal and not(msMsLeveling or matchesMsGold) then RecordActiveSearch(sender,message,GR.activeLfmHealSearches) end

    local cats={}
    if matchesLfmDps  and not(msMsLeveling or matchesMsGold) then cats[#cats+1]="|cffffaa00DPS|r"     end
    if matchesLfmTank and not(msMsLeveling or matchesMsGold) then cats[#cats+1]="|cffffaa00Tank|r"    end
    if matchesLfmHeal and not(msMsLeveling or matchesMsGold) then cats[#cats+1]="|cffffaa00Heal|r"    end
    if matchesBc     then cats[#cats+1]="|cff00ccffBC|r"       end
    if msMsLeveling  then cats[#cats+1]="|cff88ccffMS-Lvl|r"  end
    if matchesMsGold then cats[#cats+1]="|cffddcc00MS-Gold|r" end
    local catStr = #cats>0 and ("["..table.concat(cats,",").."]") or ""

    FeedPush(sender,message,"match",catStr)
    GR.UpdateMinimapIcon()

    if isDeclined or isSpammer then return end
    GR.spammerList[sender]=GetTime()

    local textOk =
        (cfg.textAlertMsLeveling and msMsLeveling) or
        (cfg.textAlertMsGold     and matchesMsGold) or
        (cfg.textAlertBc         and matchesBc) or
        (cfg.textAlertLfmDps  and matchesLfmDps  and not(msMsLeveling or matchesMsGold)) or
        (cfg.textAlertLfmTank and matchesLfmTank and not(msMsLeveling or matchesMsGold)) or
        (cfg.textAlertLfmHeal and matchesLfmHeal and not(msMsLeveling or matchesMsGold))
    if textOk then ShowLFMTextAlert(sender,message) end

    -- Popup alert — respects each alert checkbox independently.
    -- All types are opt-in. Fresh install has everything false until user enables.
    local popOk =
        (cfg.alertMsLeveling and msMsLeveling) or
        (cfg.alertMsGold     and matchesMsGold) or
        (cfg.alertBc         and matchesBc) or
        (cfg.alertLfmDps  and matchesLfmDps  and not(msMsLeveling or matchesMsGold)) or
        (cfg.alertLfmTank and matchesLfmTank and not(msMsLeveling or matchesMsGold)) or
        (cfg.alertLfmHeal and matchesLfmHeal and not(msMsLeveling or matchesMsGold))
    if popOk then ShowLFMAlert(sender,message,catStr) end
end

-- ============================================================================
-- CHAT LISTENER  — event handler wrapped in pcall for error safety
-- ============================================================================
local grListener = CreateFrame("Frame")
grListener:RegisterEvent("CHAT_MSG_CHANNEL")
grListener:RegisterEvent("CHAT_MSG_SAY")
grListener:SetScript("OnEvent", function(_, _, message, sender)
    if not MTR.initialized then return end
    local ok, err = pcall(HandleChatMessage, _, message, sender)
    if not ok then MTR.dprint("GroupRadar event error:", err) end
end)

-- ============================================================================
-- TAB DEFINITIONS
-- ============================================================================
local tabDefs = {
    {label="All",      group=function() return GR.activeSearches        end},
    {label="MS Level", group=function() return GR.activeMsLevelSearches end},
    {label="MS Gold",  group=function() return GR.activeMsGoldSearches  end},
    {label="LF DPS",   group=function() return GR.activeLfmDpsSearches  end},
    {label="LF Tank",  group=function() return GR.activeLfmTankSearches end},
    {label="LF Heal",  group=function() return GR.activeLfmHealSearches end},
    {label="Feed",     group=nil},
}

local function CreateDetailTabs(frame)
    for _, t in ipairs(GR.detailTabs) do if t and t.Hide then t:Hide() end end
    GR.detailTabs = {}
    GR.currentSearchGroup = GR.activeSearches
    GR.currentTabLabel    = "All"

    local tabW = 82
    for i, def in ipairs(tabDefs) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(tabW, 22)
        btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 10+(i-1)*(tabW+3), -32)
        local n = def.group and #def.group() or #GR.scanFeed
        btn:SetText(def.label..(n>0 and " ("..n..")" or ""))
        local d = def
        btn:SetScript("OnClick", function()
            GR.currentSearchGroup = d.group and d.group() or nil
            GR.currentTabLabel    = d.label
            GR.UpdateDetailFrame()
        end)
        GR.detailTabs[i] = btn
    end
end

-- ============================================================================
-- UPDATE DETAIL FRAME  — uses frame pool for zero allocation on refresh
-- ============================================================================
function GR.UpdateDetailFrame()
    local f = GR.detailFrame
    if not f or not f:IsShown() then return end

    -- Refresh tab labels
    for i, def in ipairs(tabDefs) do
        if GR.detailTabs[i] then
            local n = def.group and #def.group() or #GR.scanFeed
            GR.detailTabs[i]:SetText(def.label..(n>0 and " ("..n..")" or ""))
        end
    end

    local content = f._content
    local now     = GetTime()
    local rowCount = 0

    -- ── Feed tab ─────────────────────────────────────────────────────────────
    if GR.currentTabLabel == "Feed" then
        if #GR.scanFeed == 0 then
            PoolHideFrom(content, 1)
            local row = PoolGet(content, 1, 570, 22, 23)
            if not row._lineFS then
                row._lineFS = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
                row._lineFS:SetAllPoints(row)
            end
            row._lineFS:SetText("|cffaaaaaa Scan feed empty — waiting for channel messages...|r")
            content:SetHeight(40)
            return
        end
        for i, entry in ipairs(GR.scanFeed) do
            local row = PoolGet(content, i, 570, 21, 22)
            rowCount = i
            if not row._bg then
                row._bg = row:CreateTexture(nil,"BACKGROUND") row._bg:SetAllPoints(row)
            end
            -- _lineFS may be missing if this pool slot was previously a recruiter row
            if not row._lineFS then
                row._lineFS = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
                row._lineFS:SetAllPoints(row) row._lineFS:SetWordWrap(false)
            end
            if entry.result=="match"    then row._bg:SetColorTexture(0.05,0.18,0.05,0.5)
            elseif entry.result=="filtered" then row._bg:SetColorTexture(0.18,0.05,0.05,0.4)
            else row._bg:SetColorTexture(0.06,0.06,0.06,0.3) end

            local age=now-entry.ts
            local ageStr=age<60 and (math.floor(age).."s") or (math.floor(age/60).."m")
            local col=entry.result=="match" and "|cff00ff00" or
                      entry.result=="filtered" and "|cffff6644" or "|cff666666"
            row._lineFS:SetText(string.format(
                "|cffaaaaaa%s|r %s%-14s|r %s|cff888888%s|r",
                ageStr, col, MTR.Trunc(entry.sender,14), entry.cats, MTR.Trunc(entry.message,52)
            ))
        end
        PoolHideFrom(content, rowCount+1)
        content:SetHeight(math.max(300, rowCount*22+10))
        return
    end

    -- ── Recruiter bucket tab ──────────────────────────────────────────────────
    local group  = GR.currentSearchGroup or GR.activeSearches
    local sorted = {}
    for _, r in ipairs(group) do sorted[#sorted+1]=r end
    table.sort(sorted, function(a,b) return a.lastUpdate>b.lastUpdate end)

    if #sorted == 0 then
        PoolHideFrom(content, 1)
        local row = PoolGet(content, 1, 570, 30, 34)
        if not row._lineFS then
            row._lineFS = row:CreateFontString(nil,"OVERLAY","GameFontHighlight")
            row._lineFS:SetAllPoints(row)
        end
        row._lineFS:SetText("|cffaaaaaa No recruiters in this category.|r")
        content:SetHeight(40) return
    end

    local ROW_H, ROW_STEP = 52, 56   -- taller rows to fit wrapped message

    for i, rec in ipairs(sorted) do
        local row = PoolGet(content, i, 570, ROW_H, ROW_STEP)
        rowCount = i

        if not row._built then
            row._bg     = row:CreateTexture(nil,"BACKGROUND") row._bg:SetAllPoints(row)
            row._sep    = row:CreateTexture(nil,"OVERLAY")
            row._sep:SetPoint("BOTTOMLEFT",row,"BOTTOMLEFT",0,0)
            row._sep:SetPoint("BOTTOMRIGHT",row,"BOTTOMRIGHT",0,0)
            row._sep:SetHeight(1) row._sep:SetColorTexture(1,1,1,0.12)

            -- Top line: name + age
            row._nameFS = row:CreateFontString(nil,"OVERLAY","GameFontNormal")
            row._nameFS:SetPoint("TOPLEFT",row,"TOPLEFT",4,-4)
            row._nameFS:SetWidth(140) row._nameFS:SetWordWrap(false)

            row._ageFS = row:CreateFontString(nil,"OVERLAY","GameFontNormal")
            row._ageFS:SetPoint("LEFT",row._nameFS,"RIGHT",6,0)
            row._ageFS:SetWidth(36) row._ageFS:SetWordWrap(false)

            -- Apply button top-right
            row._applyBtn = CreateFrame("Button",nil,row,"UIPanelButtonTemplate")
            row._applyBtn:SetSize(68,22)
            row._applyBtn:SetPoint("TOPRIGHT",row,"TOPRIGHT",-4,-4)
            row._applyBtn:SetText("|cff00ff00Apply|r")

            -- Message: full width below, word wrap ON, shows up to 2 lines
            row._msgFS = row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            row._msgFS:SetPoint("TOPLEFT",row,"TOPLEFT",4,-26)
            row._msgFS:SetPoint("TOPRIGHT",row,"TOPRIGHT",-4,-26)
            row._msgFS:SetWordWrap(true)
            row._built = true
        end

        row._bg:SetColorTexture(i%2==0 and 0.08 or 0.05, 0.08, 0.12, 0.55)
        row._nameFS:SetText("|Hplayer:"..rec.player.."|h|cff00ccff"..MTR.Trunc(rec.player,18).."|h|r")
        local age = now - rec.lastUpdate
        row._ageFS:SetText("|cffaaaaaa"..(age<60 and math.floor(age).."s" or math.floor(age/60).."m").."|r")
        -- Full message, truncated at 180 chars (long enough for any LFM message)
        row._msgFS:SetText("|cffdddddd"..MTR.Trunc(rec.message, 180).."|r")

        do local rp = rec.player
            row._applyBtn:SetScript("OnClick",function()
                local msg = BuildInviteMsg()
                MTR.SendChatSafe(msg, "WHISPER", nil, rp)
                MTR.MP("|cffffcc00[GroupRadar]|r Applied to "..rp.." — "..msg)
            end)
        end
    end
    PoolHideFrom(content, rowCount+1)
    content:SetHeight(math.max(300, rowCount*ROW_STEP+20))
end

-- ============================================================================
-- SHOW / TOGGLE DETAIL FRAME
-- ============================================================================
function GR.ShowDetailFrame()
    if not GR.detailFrame then
        local f=CreateFrame("Frame","MekTownGRDetailFrame",UIParent)
        f:SetSize(620,440) f:SetPoint("CENTER",0,-40)
        f:SetToplevel(true)
        f:SetBackdrop({bgFile="",
            edgeFile="Interface\\\\DialogFrame\\\\UI-DialogBox-Border",
            tile=false,tileSize=0,edgeSize=32,insets={left=8,right=8,top=8,bottom=8}})
        f:SetBackdropColor(0,0,0,0)
        do local _bt=f:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(f) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
        f:SetFrameStrata("DIALOG") f:EnableMouse(true) f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart",f.StartMoving) f:SetScript("OnDragStop",f.StopMovingOrSizing)

        local xBtn=CreateFrame("Button",nil,f,"UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-2,-2)
        xBtn:SetScript("OnClick",function()
            f:Hide()
            MTR.TickRemove("gr_detail")
        end)

        -- Title bar
        local dTBar=f:CreateTexture(nil,"OVERLAY") dTBar:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
        dTBar:SetTexCoord(0,1,0.2,0.8) dTBar:SetVertexColor(0.55,0.03,0.03,1.0) dTBar:SetHeight(26)
        dTBar:SetPoint("TOPLEFT",f,"TOPLEFT",9,-2) dTBar:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-2)
        local dTEdge=f:CreateTexture(nil,"OVERLAY") dTEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
        dTEdge:SetVertexColor(0.80,0.12,0.02,1.0) dTEdge:SetHeight(2)
        dTEdge:SetPoint("TOPLEFT",f,"TOPLEFT",9,-26) dTEdge:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-26)
                local hdr=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        hdr:SetPoint("TOP",f,"TOP",0,-10)
        hdr:SetText("|cffffcc00[GroupRadar]|r  |cffaaaaaa— Active Recruiters|r")

        CreateDetailTabs(f)

        local sf=CreateFrame("ScrollFrame",nil,f,"UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",f,"TOPLEFT",8,-58)
        sf:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-28,46)
        local content=CreateFrame("Frame",nil,sf)
        content:SetSize(570,400) sf:SetScrollChild(content) f._content=content

        local lfgBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
        lfgBtn:SetSize(150,28) lfgBtn:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",10,10)
        lfgBtn:SetText("|cff00ff00Post LFG|r")
        lfgBtn:SetScript("OnClick",function() GR.ShowFindGroupFrame() end)

        local refBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
        refBtn:SetSize(80,28) refBtn:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-38,10)
        refBtn:SetText("Refresh")
        refBtn:SetScript("OnClick",function() GR.UpdateDetailFrame() end)

        -- Back to Config button
        local configBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
        configBtn:SetSize(120,28) configBtn:SetPoint("BOTTOMRIGHT",refBtn,"BOTTOMLEFT",-6,0)
        configBtn:SetText("|cffaaaaaa< Config|r")
        configBtn:SetScript("OnClick",function()
            f:Hide()
            MTR.TickRemove("gr_detail")
            if MTR.OpenConfig then MTR.OpenConfig() end
        end)

        f:Hide()
        GR.detailFrame = f
    end

    if GR.detailFrame:IsShown() then
        GR.detailFrame:Hide()
        MTR.TickRemove("gr_detail")
        return
    end

    GR.currentSearchGroup = GR.activeSearches
    GR.currentTabLabel    = "All"
    CreateDetailTabs(GR.detailFrame)
    GR.UpdateDetailFrame()
    GR.detailFrame:Show()

    -- 1-second refresh tick via master scheduler — zero OnUpdate on the frame itself
    MTR.TickAdd("gr_detail", 1, function()
        if not GR.detailFrame or not GR.detailFrame:IsShown() then
            MTR.TickRemove("gr_detail") return
        end
        GR.UpdateDetailFrame()
    end)
end

-- ============================================================================
-- MINIMAP BUTTON  (WA Section 10)
-- ============================================================================
function GR.UpdateMinimapIcon()
    if not GR.minimapBtn then return end
    GR.minimapBtn._icon:SetTexture(#GR.activeSearches > 0
        and "Interface\\Icons\\Achievement_BG_winWSG_3-0"
        or  "Interface\\Icons\\inv_misc_grouplooking")
end

function GR.CreateMinimapButton()
    if GR.minimapBtn then GR.minimapBtn:Show() return end
    local btn=CreateFrame("Button","MekTownGRMinimapBtn",Minimap)
    btn:SetSize(28,28) btn:SetFrameStrata("MEDIUM") btn:SetFrameLevel(8)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    btn:SetPoint("TOPRIGHT",Minimap,"TOPRIGHT",-2,-2)
    local icon=btn:CreateTexture(nil,"BACKGROUND")
    icon:SetTexture("Interface\\Icons\\inv_misc_grouplooking") icon:SetAllPoints(btn) btn._icon=icon
    btn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cffffcc00Group Radar|r")
        local c=#GR.activeSearches
        GameTooltip:AddLine(c>0 and ("|cff00ff00"..c.." recruiter"..(c>1 and "s" or "").."|r") or "|cffaaaaaa(no active recruiters)|r")
        GameTooltip:AddLine("|cffffffffLeft-click:|r Show recruiters")
        GameTooltip:AddLine("|cffffffffRight-click:|r Open config")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave",function() GameTooltip:Hide() end)
    btn:SetScript("OnClick",function(_,b)
        if b=="LeftButton" then GR.ShowDetailFrame()
        elseif b=="RightButton" then MTR.OpenConfig() end
    end)
    GR.minimapBtn=btn
end

-- ============================================================================
-- FIND GROUP PANEL  (WA CreateFindGroupPanel port)
-- ============================================================================
function GR.ShowFindGroupFrame()
    if GR.findFrame then
        if GR.findFrame:IsShown() then GR.findFrame:Hide() else GR.findFrame:Show() end
        return
    end

    local f=CreateFrame("Frame","MekTownGRFindGroup",UIParent)
    f:SetSize(350,255) f:SetPoint("CENTER")
    f:SetBackdrop({bgFile="",
        edgeFile="Interface\\\\DialogFrame\\\\UI-DialogBox-Border",
        tile=false,tileSize=0,edgeSize=32,insets={left=8,right=8,top=8,bottom=8}})
    f:SetBackdropColor(0,0,0,0)
    do local _bt=f:CreateTexture(nil,"BACKGROUND")
    _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(f) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
    f:SetFrameStrata("DIALOG") f:EnableMouse(true) f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart",f.StartMoving) f:SetScript("OnDragStop",f.StopMovingOrSizing)
    f:Hide()

    local xBtn=CreateFrame("Button",nil,f,"UIPanelCloseButton")
    xBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT",-4,-4)
    xBtn:SetScript("OnClick",function() f:Hide() end)

    -- Title bar (standard MekTown style)
    local fTBar=f:CreateTexture(nil,"OVERLAY")
    fTBar:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    fTBar:SetTexCoord(0,1,0.2,0.8) fTBar:SetVertexColor(0.55,0.03,0.03,1.0) fTBar:SetHeight(26)
    fTBar:SetPoint("TOPLEFT",f,"TOPLEFT",9,-2) fTBar:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-2)
    local fTEdge=f:CreateTexture(nil,"OVERLAY")
    fTEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
    fTEdge:SetVertexColor(0.80,0.12,0.02,1.0) fTEdge:SetHeight(2)
    fTEdge:SetPoint("TOPLEFT",f,"TOPLEFT",9,-26) fTEdge:SetPoint("TOPRIGHT",f,"TOPRIGHT",-9,-26)
    local title=f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    title:SetPoint("TOP",f,"TOP",0,-10) title:SetText("|cffffcc00Looking For Group|r")

    local cLbl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    cLbl:SetPoint("TOPLEFT",f,"TOPLEFT",20,-40) cLbl:SetText("Content:")
    local rLbl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    rLbl:SetPoint("TOPLEFT",f,"TOPLEFT",190,-40) rLbl:SetText("Role:")

    local contentOpts={"Mythic+","MS Leveling","MS Gold","Other"}
    local roleOpts={"TANK","HEALER","DPS"}
    local roleToCfg = { TANK = 2, HEALER = 3, DPS = 4 }
    local cfg = Cfg()
    local selContent = cfg.lastLfgContent or "Mythic+"
    local selRole = (cfg.myRole == 2 and "TANK") or (cfg.myRole == 3 and "HEALER") or "DPS"

    local cDD=CreateFrame("Frame","MekTownGRContentDD",f,"UIDropDownMenuTemplate")
    cDD:SetPoint("TOPLEFT",cLbl,"BOTTOMLEFT",0,-5) UIDropDownMenu_SetWidth(cDD,120) UIDropDownMenu_SetText(cDD,selContent)
    local rDD=CreateFrame("Frame","MekTownGRRoleDD",f,"UIDropDownMenuTemplate")
    rDD:SetPoint("TOPLEFT",rLbl,"BOTTOMLEFT",0,-5) UIDropDownMenu_SetWidth(rDD,100) UIDropDownMenu_SetText(rDD,selRole)

    local prevEB=CreateFrame("EditBox",nil,f,"InputBoxTemplate")
    prevEB:SetSize(300,25) prevEB:SetAutoFocus(false)

    local function UpdatePreview()
        local ilvl=math.floor(GetAverageItemLevel()+0.5)
        local lre=GetLRE() local lreStr=lre~="" and (" "..lre) or ""
        local msg
        if selContent=="MS Leveling" then
            msg="LFG: "..selContent.." as "..selRole..lreStr
        else
            msg="LFG: "..selContent.." as "..selRole.." "..ilvl.." ilvl"..lreStr
        end
        prevEB:SetText(msg) prevEB:SetCursorPosition(0)
    end

    UIDropDownMenu_Initialize(cDD,function()
        local info=UIDropDownMenu_CreateInfo()
        for _,opt in ipairs(contentOpts) do
            info.text=opt info.func=function(self) selContent=self:GetText() Cfg().lastLfgContent = selContent UIDropDownMenu_SetText(cDD,selContent) UpdatePreview() end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_Initialize(rDD,function()
        local info=UIDropDownMenu_CreateInfo()
        for _,opt in ipairs(roleOpts) do
            info.text=opt info.func=function(self) selRole=self:GetText() Cfg().myRole = roleToCfg[selRole] or 4 UIDropDownMenu_SetText(rDD,selRole) UpdatePreview() end
            UIDropDownMenu_AddButton(info)
        end
    end)

    local repLbl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    repLbl:SetPoint("TOPLEFT",f,"TOPLEFT",20,-120) repLbl:SetText("Post every:")
    local repMins=Cfg().lfgRepeatMins or 10
    local repIntervals={5,10,15,20,30}
    local repBtns={}
    local function UpdateRepBtns()
        for i,btn in ipairs(repBtns) do
            if repIntervals[i]==repMins then btn:LockHighlight() else btn:UnlockHighlight() end
        end
    end
    for i,mins in ipairs(repIntervals) do
        local btn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate") btn:SetSize(44,22)
        if i==1 then btn:SetPoint("TOPLEFT",f,"TOPLEFT",90,-116)
        else btn:SetPoint("LEFT",repBtns[i-1],"RIGHT",2,0) end
        btn:SetText(mins.."m") repBtns[i]=btn
        do local m=mins
            btn:SetScript("OnClick",function() repMins=m Cfg().lfgRepeatMins=m UpdateRepBtns() end)
        end
    end
    UpdateRepBtns()

    local prevLbl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
    prevLbl:SetPoint("TOPLEFT",f,"TOPLEFT",20,-150) prevLbl:SetText("Preview:")
    prevEB:SetPoint("TOPLEFT",prevLbl,"BOTTOMLEFT",0,-4)

    local statusLbl=f:CreateFontString(nil,"OVERLAY","GameFontHighlight")
    statusLbl:SetPoint("TOPLEFT",f,"TOPLEFT",20,-188)
    statusLbl:SetWidth(300) statusLbl:SetWordWrap(false)
    local function RefreshStatus()
        if GR.lfgActive then
            local m=math.floor(GR.lfgTimer/60) local s=math.floor(GR.lfgTimer%60)
            statusLbl:SetText("|cff00ff00● Active — next post in "..string.format("%d:%02d",m,s).."|r")
        else statusLbl:SetText("|cffff4444● Stopped|r") end
    end

    -- 1-second status refresh via master tick (only when panel is shown)
    f:SetScript("OnShow",  function() MTR.TickAdd("gr_lfg_panel",1,RefreshStatus) end)
    f:SetScript("OnHide",  function() MTR.TickRemove("gr_lfg_panel") end)

    -- Bottom button row: 4 equal buttons at 76px each with 6px gaps.
    -- Total: 4×76 + 3×6 = 322px = frame(350) - insets(14 each side). Pixel-perfect.
    local BTN_W = 76
    local BTN_H = 28
    local BTN_GAP = 6

    local startBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    startBtn:SetSize(BTN_W,BTN_H) startBtn:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",14,12)
    startBtn:SetText("|cff00ff00Start LFG|r")
    startBtn:SetScript("OnClick",function()
        local msg=prevEB:GetText()
        if not msg or msg=="" then return end
        msg=msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")
        Cfg().lastLfgContent = selContent
        Cfg().myRole = roleToCfg[selRole] or 4
        GR.StartLFG(msg,repMins)
        startBtn:SetText("Update LFG") RefreshStatus()
    end)

    local postNowBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    postNowBtn:SetSize(BTN_W,BTN_H) postNowBtn:SetPoint("LEFT",startBtn,"RIGHT",BTN_GAP,0)
    postNowBtn:SetText("Post Now")
    postNowBtn:SetScript("OnClick",function()
        -- Post immediately regardless of timer state, then restart the interval
        local msg=prevEB:GetText()
        if not msg or msg=="" then return end
        msg=msg:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")
        if not GR.lfgActive then
            -- Not running yet — start it so the timer is set up, then fire immediately
            Cfg().lastLfgContent = selContent
            Cfg().myRole = roleToCfg[selRole] or 4
            GR.StartLFG(msg,repMins)
            startBtn:SetText("Update LFG")
        end
        -- Fire the post immediately via the public-channel post logic.
        -- LFG adverts belong in the joined public channel, not /say, /party, or /raid.
        local ok = MTR.SendToGeneral(msg, true)
        if not ok then
            MTR.MPE("|cffffcc00[GroupRadar LFG]|r Could not post because no public channel was found.")
            return
        end
        -- Reset the countdown so we don't double-post right away
        GR.lfgTimer = (GR.lfgInterval or (repMins*60))
        MTR.MP("|cffffcc00[GroupRadar LFG]|r Posted now with build link.")
        RefreshStatus()
    end)

    local stopBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    stopBtn:SetSize(BTN_W,BTN_H) stopBtn:SetPoint("LEFT",postNowBtn,"RIGHT",BTN_GAP,0)
    stopBtn:SetText("|cffff4444Stop LFG|r")
    stopBtn:SetScript("OnClick",function() GR.StopLFG() startBtn:SetText("|cff00ff00Start LFG|r") RefreshStatus() end)

    local closeBtn2=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
    closeBtn2:SetSize(BTN_W,BTN_H) closeBtn2:SetPoint("LEFT",stopBtn,"RIGHT",BTN_GAP,0)
    closeBtn2:SetText("Close")
    closeBtn2:SetScript("OnClick",function() f:Hide() end)

    UpdatePreview()
    GR.findFrame=f
    f:Show()
end

-- ============================================================================
-- LFG AUTO-POST  — timer via MTR.Tick (no own OnUpdate frame)
-- ============================================================================
function GR.StartLFG(message, intervalMins)
    GR.lfgMessage  = message
    GR.lfgInterval = (intervalMins or 10) * 60
    GR.lfgTimer    = 0
    GR.lfgActive   = true
    Cfg().lfgRepeatMins = intervalMins or 10

    MTR.TickAdd("gr_lfg", 1, function()
        if not GR.lfgActive then MTR.TickRemove("gr_lfg") return end
        GR.lfgTimer = GR.lfgTimer - 1
        if GR.lfgTimer <= 0 then
            GR.lfgTimer = GR.lfgInterval
            local ok = MTR.SendToGeneral(GR.lfgMessage, true)
            if ok then
                local chanId, chanName = MTR.FindChannelIDByName("world","World","LookingForGroup","General","Ascension","Trade")
                local chanLabel = chanName or (chanId and ("/" .. tostring(chanId)) or "public channel")
                MTR.MP("|cffffcc00[GroupRadar LFG]|r Posted to "..chanLabel.." — next in "..math.floor(GR.lfgInterval/60).."m")
            else
                MTR.MPE("|cffffcc00[GroupRadar LFG]|r Could not post because no public channel was found.")
            end
        end
    end)

    if GR.minimapLFGBtn then GR.minimapLFGBtn:Show() else GR.CreateLFGMinimapButton() end
    MTR.MP("|cffffcc00[GroupRadar LFG]|r |cff00ff00Started.|r  Posting every "..(intervalMins or 10).."m.")
end

function GR.StopLFG()
    GR.lfgActive = false
    MTR.TickRemove("gr_lfg")
    if GR.minimapLFGBtn then GR.minimapLFGBtn:Hide() end
    MTR.MP("|cffffcc00[GroupRadar LFG]|r |cffff4444Stopped.|r")
end

-- ============================================================================
-- LFG MINIMAP BUTTON
-- ============================================================================
function GR.CreateLFGMinimapButton()
    if GR.minimapLFGBtn then GR.minimapLFGBtn:Show() return end
    local btn=CreateFrame("Button","MekTownLFGMinimapBtn",Minimap)
    btn:SetSize(28,28) btn:SetFrameStrata("MEDIUM") btn:SetFrameLevel(8)
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    btn:SetPoint("BOTTOMRIGHT",Minimap,"BOTTOMRIGHT",-2,2)
    local icon=btn:CreateTexture(nil,"BACKGROUND")
    icon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking") icon:SetAllPoints(btn)

    -- Pulse via master tick, not per-frame OnUpdate
    MTR.TickAdd("gr_lfg_pulse", 0.1, function()
        if not GR.minimapLFGBtn or not GR.minimapLFGBtn:IsShown() then
            MTR.TickRemove("gr_lfg_pulse") return
        end
        local alpha = 0.6 + 0.4 * math.abs(math.sin(GetTime() * 2))
        icon:SetAlpha(alpha)
    end)

    btn:SetScript("OnEnter",function(self)
        GameTooltip:SetOwner(self,"ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("|cffffcc00LFG Active|r")
        if GR.lfgTimer>0 then
            GameTooltip:AddLine(string.format("|cff00ff00Next post in %d:%02d|r",math.floor(GR.lfgTimer/60),math.floor(GR.lfgTimer%60)))
        end
        GameTooltip:AddLine("|cffffffffLeft-click:|r Open LFG panel")
        GameTooltip:AddLine("|cffffffffRight-click:|r Stop LFG")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave",function() GameTooltip:Hide() end)
    btn:SetScript("OnClick",function(_,b)
        if b=="LeftButton" then GR.ShowFindGroupFrame()
        elseif b=="RightButton" then GR.StopLFG() end
    end)
    GR.minimapLFGBtn=btn
end

-- ============================================================================
-- PUBLIC ENTRY POINTS
-- ============================================================================
function MTR.OpenGroupRadar()
    GR.CreateMinimapButton()
    if not GR.detailFrame then
        GR.ShowDetailFrame()
    else
        if not GR.detailFrame:IsShown() then GR.detailFrame:Show() end
        GR.currentSearchGroup = GR.activeSearches
        GR.currentTabLabel    = "All"
        CreateDetailTabs(GR.detailFrame)
        GR.UpdateDetailFrame()
        MTR.TickAdd("gr_detail", 1, function()
            if not GR.detailFrame or not GR.detailFrame:IsShown() then
                MTR.TickRemove("gr_detail") return
            end
            GR.UpdateDetailFrame()
        end)
    end
    if GR.detailFrame then
        GR.detailFrame:Raise()
        GR.detailFrame:SetFrameStrata("DIALOG")
    end
end

function MTR.OpenFindGroup()
    if not GR.findFrame then
        GR.ShowFindGroupFrame()
    else
        if not GR.findFrame:IsShown() then GR.findFrame:Show() end
        GR.findFrame:Raise()
        GR.findFrame:SetFrameStrata("DIALOG")
    end
    if GR.lfgActive and not GR.minimapLFGBtn then GR.CreateLFGMinimapButton() end
end

print("|cff00c0ff[MekTown Recruit]|r GroupRadar v8.0 loaded.")
