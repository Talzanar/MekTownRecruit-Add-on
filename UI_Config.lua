-- ============================================================================
-- UI_Config.lua  v5.0
-- Officer / GM config window (900×680) with all management tabs.
-- Guild Master controls officer-rank assignment from the current guild rank names.
-- Opened via /mek config or the minimap button.
-- ============================================================================
local MTR = MekTownRecruit

-- Local aliases for readability inside this file
local function MP(m)  MTR.MP(m)  end
local function MPE(m) MTR.MPE(m) end

-- Forward declarations of helpers defined inside CreateMainWindow
-- (they need to be visible to the profile button callbacks)
local mainWin   = nil
local Settings  = MTR.Settings
local CommitGuildTabState = nil
local RefreshGuildTabState = nil

local function CfgDB()
    if type(MekTownRecruitDB) ~= "table" then MekTownRecruitDB = {} end
    if type(MekTownRecruitDB.profiles) ~= "table" then MekTownRecruitDB.profiles = {} end
    if type(MekTownRecruitDB.activeProfile) ~= "string" or MekTownRecruitDB.activeProfile == "" then
        MekTownRecruitDB.activeProfile = "Default"
    end
    if type(MekTownRecruitDB.profiles[MekTownRecruitDB.activeProfile]) ~= "table" then
        if MTR and MTR.GetActiveProfile then
            local profile = MTR.GetActiveProfile()
            if type(profile) == "table" then return profile end
        end
        MekTownRecruitDB.profiles[MekTownRecruitDB.activeProfile] = {}
    end
    local profile = MekTownRecruitDB.profiles[MekTownRecruitDB.activeProfile]
    MTR.db = profile
    return profile
end

local function DirectSetValue(path, value)
    local cfg = CfgDB()
    if MTR and MTR.SetPathOnTable then
        MTR.SetPathOnTable(cfg, path, value)
    else
        cfg[path] = value
    end
    MTR.db = cfg
    if mainWin and not mainWin._refreshing then mainWin._dirty = true end
    return value
end

local function SaveValue(path, value)
    return DirectSetValue(path, value)
end

local function SaveBool(path, value)
    local checked = (MTR.NormalizeChecked and MTR.NormalizeChecked(value)) or (value and true or false)
    return DirectSetValue(path, checked and true or false)
end

local function SaveTable(path, value)
    return DirectSetValue(path, value or {})
end

local function SaveText(path, value)
    return DirectSetValue(path, tostring(value or ""))
end

local function SaveSlider(path, value, step)
    local n = tonumber(value) or 0
    if step and step > 0 then
        n = math.floor(n / step) * step
    end
    return DirectSetValue(path, n)
end

local function ForcePersistGuildInviteWidgets()
    if not mainWin then return end
    if mainWin._guildInvEnable then SaveBool("enableGuildInvites", mainWin._guildInvEnable:GetChecked()) end
    if mainWin._guildInvAnnounce then SaveBool("inviteAnnounce", mainWin._guildInvAnnounce:GetChecked()) end
    if mainWin._guildWelcomeEB then SaveText("inviteWelcomeMsg", mainWin._guildWelcomeEB:GetText() or "") end
    if mainWin._guildInvCooldown then SaveSlider("inviteCooldown", mainWin._guildInvCooldown:GetValue() or 60, 10) end
    if mainWin._guildAutoReply then SaveBool("autoResponderEnabled", mainWin._guildAutoReply:GetChecked()) end
    MTR.db = CfgDB()
    if mainWin and not mainWin._refreshing then mainWin._dirty = true end
end


local function DirectSet(path, value)
    if MTR and MTR.SetProfilePath then
        MTR.SetProfilePath(path, value)
    end
end

local function SnapshotAllConfigWidgets()
    if not mainWin then return end
    if CommitGuildTabState then CommitGuildTabState() end
    if mainWin._chanChecks then
        local scanChannels = {}
        for _, ck in ipairs(mainWin._chanChecks) do
            if ck and ck.channel then
                scanChannels[ck.channel] = (MTR.NormalizeChecked and MTR.NormalizeChecked(ck:GetChecked())) or (ck:GetChecked() and true or false)
            end
        end
        DirectSet("scanChannels", scanChannels)
    end

    if mainWin._dkpChanDD then
        local selected = UIDropDownMenu_GetSelectedValue(mainWin._dkpChanDD)
        if selected and selected ~= "" then DirectSet("dkpPublishChannel", selected) end
    end

    if mainWin._adChanEB then
        local channelNum = tonumber((mainWin._adChanEB:GetText() or ""):match("%d+")) or 1
        DirectSet("guildAdConfig.channelNum", channelNum)
    end
end

-- ============================================================================
-- CREATE MAIN WINDOW  (called once, cached)
-- ============================================================================
local function CreateMainWindow()
    if mainWin then return end

    mainWin = CreateFrame("Frame", "MekTownMainWindow", UIParent)
    mainWin:SetSize(920, 680)
    mainWin:SetPoint("CENTER")
    mainWin:SetFrameStrata("MEDIUM")
    if mainWin.SetClipsChildren then mainWin:SetClipsChildren(true) end
    -- Window border only (no bgFile so our textures show through)
    mainWin:SetBackdrop({
        bgFile   = "",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=false, tileSize=0, edgeSize=32,
        insets={left=8,right=8,top=8,bottom=8},
    })
    mainWin:SetBackdropColor(0, 0, 0, 0)
    -- Dedicated background sub-frame at a lower frame level so wallpaper
    -- renders behind all child content without being overdrawn by them.
    local bgFrame = CreateFrame("Frame", nil, mainWin)
    bgFrame:SetAllPoints(mainWin)
    bgFrame:SetFrameLevel(mainWin:GetFrameLevel())
    -- Solid near-black dark-red base
    local baseTex = bgFrame:CreateTexture(nil, "BACKGROUND")
    baseTex:SetTexture("Interface\\Buttons\\WHITE8x8")
    baseTex:SetAllPoints(bgFrame)
    baseTex:SetVertexColor(0.04, 0.01, 0.01, 1.0)
    -- Guild wallpaper on top of base
    local bgTex = bgFrame:CreateTexture(nil, "ARTWORK")
    bgTex:SetTexture("Interface\\AddOns\\MekTownRecruit\\MTCWallpaper")
    bgTex:SetAllPoints(bgFrame)
    bgTex:SetAlpha(0.35)
    -- Flip V coordinates to correct upside-down orientation of the TGA file.
    -- SetTexCoord(left, right, top, bottom): swapping top/bottom flips vertically.
    bgTex:SetTexCoord(0, 1, 1, 0)
    mainWin:EnableMouse(true)
    mainWin:SetMovable(true)
    mainWin:SetResizable(true)
    mainWin:SetMinResize(700, 500)
    mainWin:RegisterForDrag("LeftButton")
    mainWin:SetScript("OnDragStart", mainWin.StartMoving)
    mainWin:SetScript("OnDragStop",  mainWin.StopMovingOrSizing)
    mainWin:Hide()

    -- Resize grip (bottom-right corner)
    local resizeGrip = CreateFrame("Button", nil, mainWin)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", mainWin, "BOTTOMRIGHT", -2, 2)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function() mainWin:StartSizing("BOTTOMRIGHT") end)
    resizeGrip:SetScript("OnMouseUp",   function() mainWin:StopMovingOrSizing() end)

    -- ---- TITLE BAR: UI-DialogBox-Header tinted blood-red for Orky look ----
    -- This texture is a natural parchment-banner shape built into WoW 3.3.5
    local titleBar = mainWin:CreateTexture(nil, "OVERLAY")
    titleBar:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    -- Stretch the centre strip only (avoid the rounded caps) via texcoord
    titleBar:SetTexCoord(0, 1, 0.2, 0.8)
    titleBar:SetVertexColor(0.55, 0.03, 0.03, 1.0)
    titleBar:SetHeight(26)
    titleBar:SetPoint("TOPLEFT",  mainWin, "TOPLEFT",  9, -2)
    titleBar:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", -9, -2)
    -- Thin bright-red rivet line below title bar
    local titleEdge = mainWin:CreateTexture(nil, "OVERLAY")
    titleEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
    titleEdge:SetVertexColor(0.80, 0.12, 0.02, 1.0)
    titleEdge:SetHeight(2)
    titleEdge:SetPoint("TOPLEFT",  mainWin, "TOPLEFT",  9, -26)
    titleEdge:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", -9, -26)

    -- Title text (left-anchored inside title bar)
    local titleText = mainWin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 10, -6)
    titleText:SetText("|cffff2020MekTown|r |cffd4af37Recruit Control|r |cffaaaaaa v"..(MTR.VERSION or "2.1.1-pre").."|r")

    -- Close button (standard WoW X, top-right)
    local closeBtn = CreateFrame("Button", nil, mainWin, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", 2, 2)
    closeBtn:SetScript("OnClick", function() mainWin:Hide() end)

    -- Store profile widget references (populated inside Profile tab builder)
    mainWin._profDD   = nil
    mainWin._profNew  = nil
    mainWin._profCopy = nil
    mainWin._profDel  = nil

    mainWin._settingBindings = {}

    -- =========================================================================
    -- WORKSPACE & TAB SYSTEM
    -- =========================================================================
    local WORKSPACES = {
        { name = "Utility", color = "|cff00ccff", tabs = {"Vault", "Radar", "Standings", "Roll"} },
        { name = "Guild",   color = "|cffff2020", tabs = {"Recruit", "Ads", "DKP", "Auction", "Inactive", "Guild"} },
        { name = "Admin",   color = "|cffd4af37", tabs = {"Profile", "Access"} },
    }

    local tabBtns   = {}
    local tabFrames = {}
    local wsDD      = nil

    -- Map display names to internal tab builder keys
    local TAB_MAP = {
        ["Vault"]     = "Vault",
        ["Radar"]     = "Group Radar",
        ["Standings"] = "Standings",
        ["Roll"]      = "Roll",
        ["Recruit"]   = "Recruit",
        ["Ads"]       = "Ads",
        ["DKP"]       = "DKP",
        ["Auction"]   = "Auction",
        ["Inactive"]  = "Inactive",
        ["Guild"]     = "Guild",
        ["Profile"]   = "Profile",
        ["Access"]    = "Access",
    }


    local TAB_Y       = -44
    local TAB_START_X = 10
    local TAB_GAP_X   = 6
    local TAB_BTN_W   = 104
    local TAB_BTN_H   = 24
    local HELP_COL_X  = 452
    local HELP_COL_W  = 418
    local HELP_SAFE_RIGHT = 870

    -- Declare BEFORE the loop so the OnClick closures can capture them.
    -- tabBuilders[name] = function(t) ... end  — builds content on first click
    -- tabBuilt[name]    = true                 — prevents rebuilding
    local tabBuilders = {}
    local tabBuilt    = {}

    local function FindWorkspace(wsName)
        for _, ws in ipairs(WORKSPACES) do
            if ws.name == wsName then return ws end
        end
        return nil
    end

    local function HasGuildAccess()
        if MTR.CanAccess then return MTR.CanAccess("Recruit") end
        return (MTR.isOfficer == true) or (MTR.isGM == true)
    end

    local function IsWorkspaceAllowed(wsName)
        if wsName == "Utility" then return true end
        return HasGuildAccess()
    end

    -- Function to show specific workspace
    local function ShowWS(wsName, preferredTab)
        if not IsWorkspaceAllowed(wsName) then
            wsName = "Utility"
            preferredTab = "Group Radar"
        elseif wsName == "Utility" and not preferredTab then
            preferredTab = "Group Radar"
        end
        local ws = FindWorkspace(wsName) or WORKSPACES[1]
        wsName = ws.name
        mainWin._activeWorkspace = wsName
        if wsDD then
            UIDropDownMenu_SetSelectedValue(wsDD, wsName)
            UIDropDownMenu_SetText(wsDD, ws.color..ws.name.."|r")
        end
        local firstTab = nil
        local showPreferred = false
        local x = TAB_START_X
        for _, b in ipairs(tabBtns) do
            local show = false
            for _, t in ipairs(ws.tabs) do
                if b._tabDisplayName == t then
                    show = true
                    break
                end
            end
            if show then
                b:Show()
                b:ClearAllPoints()
                b:SetPoint("LEFT", mainWin, "TOPLEFT", x, TAB_Y)
                if not firstTab then firstTab = b._tabInternalName end
                if preferredTab and b._tabInternalName == preferredTab then showPreferred = true end
                x = x + b:GetWidth() + TAB_GAP_X
            else
                b:Hide()
            end
        end
        if preferredTab and showPreferred then
            mainWin._showTab(preferredTab)
        elseif firstTab then
            mainWin._showTab(firstTab)
        end
    end
    mainWin._showWS = ShowWS

    local wsLabel = mainWin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    wsLabel:SetText("Workspace:")

    wsDD = CreateFrame("Frame", "MekTownMainWorkspaceDD", mainWin, "UIDropDownMenuTemplate")
    wsDD:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", 2, -14)
    UIDropDownMenu_SetWidth(wsDD, 120)
    wsLabel:SetPoint("RIGHT", wsDD, "LEFT", -8, -1)
    UIDropDownMenu_Initialize(wsDD, function(_, level)
        for _, ws in ipairs(WORKSPACES) do
            if IsWorkspaceAllowed(ws.name) then
                local info = UIDropDownMenu_CreateInfo()
                info.text = ws.color..ws.name.."|r"
                info.value = ws.name
                info.func = function(btn)
                    ShowWS(btn.value)
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end)

    -- Create ALL tab buttons and frames
    local ALL_TAB_NAMES = {}
    local seenTabs = {}
    for _, ws in ipairs(WORKSPACES) do
        for _, t in ipairs(ws.tabs) do
            if not seenTabs[t] then
                seenTabs[t] = true
                table.insert(ALL_TAB_NAMES, t)
            end
        end
    end

    for _, tname in ipairs(ALL_TAB_NAMES) do
        local internalKey = TAB_MAP[tname] or tname
        if not tabFrames[internalKey] then
            local f = CreateFrame("Frame", nil, mainWin)
            f:SetPoint("TOPLEFT",     mainWin, "TOPLEFT",    10, TAB_Y - 30)
            f:SetPoint("BOTTOMRIGHT", mainWin, "BOTTOMRIGHT", -10, 10)
            if f.SetClipsChildren then f:SetClipsChildren(true) end
            f:Hide()
            tabFrames[internalKey] = f
        end

        local btn = CreateFrame("Button", nil, mainWin, "UIPanelButtonTemplate")
        btn:SetSize(TAB_BTN_W, TAB_BTN_H)
        btn:SetText(tname)
        btn._tabDisplayName = tname
        btn._tabInternalName = internalKey
        btn:SetScript("OnClick", function()
            mainWin._showTab(internalKey)
        end)
        tabBtns[#tabBtns+1] = btn
    end

    do
        local navSep = mainWin:CreateTexture(nil, "ARTWORK")
        navSep:SetTexture("Interface\\Buttons\\WHITE8x8")
        navSep:SetVertexColor(0.65, 0.20, 0.08, 0.45)
        navSep:SetHeight(1)
        navSep:SetPoint("TOPLEFT", mainWin, "TOPLEFT", 10, TAB_Y - 28)
        navSep:SetPoint("TOPRIGHT", mainWin, "TOPRIGHT", -10, TAB_Y - 28)
    end

    mainWin._tabFrames = tabFrames
    mainWin._tabBtns   = tabBtns

    local function UpdateTabAccess()
        for _, btn in ipairs(tabBtns) do
            btn:Enable()
            btn:SetAlpha(1)
        end
        if not HasGuildAccess() then
            if wsDD and UIDropDownMenu_DisableDropDown then UIDropDownMenu_DisableDropDown(wsDD) end
            if mainWin._showWS then mainWin._showWS("Utility", "Group Radar") end
        else
            if wsDD and UIDropDownMenu_EnableDropDown then UIDropDownMenu_EnableDropDown(wsDD) end
        end
    end
    mainWin._updateTabAccess = UpdateTabAccess

    -- Vault tab button is a direct launcher: hides config, opens the vault window
    -- We'll handle this in ShowTab now for better consistency.

    local function ShowTab(name)
        if name == "Vault" then
            mainWin:Hide()
            if MTR.OpenCharVault then MTR.OpenCharVault() end
            return
        end

        -- Highlights the correct button(s) for the active tab
        for _, b in ipairs(tabBtns) do
            if b._tabInternalName == name and b:IsShown() then
                b:LockHighlight()
            else
                b:UnlockHighlight()
            end
        end

        for _, fr in pairs(tabFrames) do fr:Hide() end
        local builtNow = false
        if tabBuilders[name] and not tabBuilt[name] then
            tabBuilders[name](tabFrames[name])
            tabBuilt[name] = true
            builtNow = true
        end
        if tabFrames[name] then tabFrames[name]:Show() end
        -- Critical persistence/UI fix:
        if mainWin and mainWin.Refresh and (builtNow or (mainWin._settingsBindings and #mainWin._settingsBindings > 0)) then
            mainWin:Refresh()
        end
        if tabFrames[name] and MTR.ValidateFrameBounds then
            if builtNow or not tabFrames[name]._mtrBoundsChecked then
                tabFrames[name]._mtrBoundsChecked = true
                if MTR.ScheduleBoundsValidation then
                    MTR.ScheduleBoundsValidation(tabFrames[name], "Config/" .. tostring(name), 2, 0.05)
                else
                    MTR.ValidateFrameBounds(tabFrames[name], "Config/" .. tostring(name), 2)
                end
            end
        end
    end
    mainWin._showTab = ShowTab

    -- Convenience aliases to shared widget factories
    local MakeRO  = MTR.MakeRO
    local MakeIn  = MTR.MakeIn
    local MakeCK  = MTR.MakeCK
    local MakeSL  = MTR.MakeSL
    local MakeSep = MTR.MakeSep
    local MakeBT  = MTR.MakeBT
    local Lock    = MTR.LockDisplay
    local OpenEP  = MTR.OpenEditPopup
    local Trunc   = MTR.Trunc

    local BTN = {
        SM = {100, 22},
        MD = {120, 24},
        LG = {140, 28},
    }
    local function MakeBTStd(parent, label, sizeKey)
        local sz = BTN[sizeKey or "MD"] or BTN.MD
        return MakeBT(parent, label, sz[1], sz[2])
    end

    local function PlaceHelpText(parent, x, y, w, text)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        local maxW = HELP_SAFE_RIGHT - (x or 0)
        if maxW < 40 then maxW = 40 end
        fs:SetWidth(math.min(w or maxW, maxW))
        fs:SetWordWrap(true)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cff9a9a9a" .. tostring(text or "") .. "|r")
        return fs
    end

    -- =========================================================================
    -- PROFILE TAB  (lazy-built on first click)
    -- =========================================================================
    tabBuilders["Profile"] = function(t)
        local scroll = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", t, "TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -28, 8)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(820) content:SetHeight(400)
        scroll:SetScrollChild(content)

        local hdr = content:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        hdr:SetPoint("TOPLEFT",content,"TOPLEFT",10,-10)
        hdr:SetText("|cffff2020Profile Management|r")

        local desc = content:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        desc:SetPoint("TOPLEFT",content,"TOPLEFT",10,-34)
        desc:SetText("|cffaaaaaa Profiles store a complete snapshot of all addon settings. Switch profiles to use different keyword sets, templates, or DKP rules per guild rank.|r")
        desc:SetWidth(500) desc:SetWordWrap(true) desc:SetJustifyH("LEFT")

        local pLabel = content:CreateFontString(nil,"OVERLAY","GameFontNormal")
        pLabel:SetPoint("TOPLEFT",content,"TOPLEFT",10,-74)
        pLabel:SetText("Active Profile:")

        local profDD = CreateFrame("Frame","MekTownMainProfileDD",content,"UIDropDownMenuTemplate")
        profDD:SetPoint("LEFT",pLabel,"RIGHT",2,0)
        UIDropDownMenu_SetWidth(profDD,160)
        mainWin._profDD = profDD

        local profNew  = CreateFrame("Button",nil,content,"UIPanelButtonTemplate")
        local profCopy = CreateFrame("Button",nil,content,"UIPanelButtonTemplate")
        local profDel  = CreateFrame("Button",nil,content,"UIPanelButtonTemplate")
        profNew:SetSize(70,24)  profNew:SetText("New")
        profCopy:SetSize(70,24) profCopy:SetText("Copy")
        profDel:SetSize(80,24)  profDel:SetText("Delete")
        profNew:SetPoint("LEFT",  profDD, "RIGHT", 2, 0)
        profCopy:SetPoint("LEFT", profNew, "RIGHT", 4, 0)
        profDel:SetPoint("LEFT",  profCopy, "RIGHT", 4, 0)
        mainWin._profNew = profNew
        mainWin._profCopy = profCopy
        mainWin._profDel = profDel

        local noteLbl = content:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        noteLbl:SetPoint("TOPLEFT",pLabel,"BOTTOMLEFT",0,-32)
        noteLbl:SetWidth(600) noteLbl:SetWordWrap(true) noteLbl:SetJustifyH("LEFT")
        noteLbl:SetText("|cffd4af37Tip:|r Deleting the Default profile is not allowed. Create a new profile first, then switch to it before deleting others.")

        local function RebuildPDD()
            if not MekTownRecruitDB or not MekTownRecruitDB.profiles then return end
            UIDropDownMenu_Initialize(profDD, function()
                local active=MekTownRecruitDB.activeProfile
                for pname in pairs(MekTownRecruitDB.profiles) do
                    local info=UIDropDownMenu_CreateInfo()
                    info.text=pname info.value=pname
                    info.func=function()
                        MekTownRecruitDB.activeProfile=pname MTR.RefreshDB() mainWin:Refresh()
                    end
                    info.checked=(pname==active)
                    UIDropDownMenu_AddButton(info)
                end
            end)
            UIDropDownMenu_SetSelectedValue(profDD,MekTownRecruitDB.activeProfile)
        end
        mainWin._rebuildProfileDD = RebuildPDD

        profNew:SetScript("OnClick",function()
            StaticPopupDialogs["MEKTOWN_NEW_PROF2"]={text="New profile name:",button1="Create",button2="Cancel",hasEditBox=true,maxLetters=40,
                OnAccept=function(self) local n=self.editBox:GetText():match("^%s*(.-)%s*$") if n~="" then MTR.GetActiveProfile() MekTownRecruitDB.activeProfile=n MTR.RefreshDB() mainWin:Refresh() RebuildPDD() MP("Created: "..n) end end,
                timeout=0,whileDead=true,hideOnEscape=true}
            StaticPopup_Show("MEKTOWN_NEW_PROF2")
        end)
        profCopy:SetScript("OnClick",function()
            StaticPopupDialogs["MEKTOWN_COPY_PROF2"]={text="Copy as:",button1="Copy",button2="Cancel",hasEditBox=true,maxLetters=40,
                OnAccept=function(self) local n=self.editBox:GetText():match("^%s*(.-)%s*$") if n~="" then MekTownRecruitDB.profiles[n]=MTR.DeepCopy(CfgDB()) MekTownRecruitDB.activeProfile=n MTR.RefreshDB() mainWin:Refresh() RebuildPDD() MP("Copied to: "..n) end end,
                timeout=0,whileDead=true,hideOnEscape=true}
            StaticPopup_Show("MEKTOWN_COPY_PROF2")
        end)
        profDel:SetScript("OnClick",function()
            local active=MekTownRecruitDB.activeProfile
            if active=="Default" then MPE("Cannot delete Default profile.") return end
            StaticPopupDialogs["MEKTOWN_DEL_PROF2"]={text="Delete '"..active.."'?",button1="Delete",button2="Cancel",
                OnAccept=function() MekTownRecruitDB.profiles[active]=nil MekTownRecruitDB.activeProfile="Default" MTR.RefreshDB() mainWin:Refresh() RebuildPDD() MP("Deleted: "..active) end,
                timeout=0,whileDead=true,hideOnEscape=true}
            StaticPopup_Show("MEKTOWN_DEL_PROF2")
        end)

        RebuildPDD()
    end

    tabBuilders["Access"] = function(t)
        local scroll = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", t, "TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -28, 8)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(820) content:SetHeight(600)
        scroll:SetScrollChild(content)

        local accessHdr = content:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        accessHdr:SetPoint("TOPLEFT",content,"TOPLEFT",10,-10)
        accessHdr:SetText("|cffff2020Access & Permissions|r")

        local accessDesc = content:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        accessDesc:SetPoint("TOPLEFT",content,"TOPLEFT",10,-34)
        accessDesc:SetWidth(780) accessDesc:SetWordWrap(true) accessDesc:SetJustifyH("LEFT")
        accessDesc:SetText("|cffaaaaaaRelease access model: guild-management tools are officer-only. Guild Ads, Recruit, DKP write actions, Loot / auction administration, and Inactivity / kick controls are restricted to officers and the Guild Master. Member utility tools such as Group Radar and Vault remain available through the member panel.|r")

        local statusLbl = content:CreateFontString(nil,"OVERLAY","GameFontNormal")
        statusLbl:SetPoint("TOPLEFT",content,"TOPLEFT",10,-88)
        if MTR.isGM then
            statusLbl:SetText("|cff00ff00Current access: Guild Master|r")
        elseif MTR.isOfficer then
            statusLbl:SetText("|cff00ff00Current access: Officer|r")
        else
            local rankName = (MTR.GetPlayerGuildRank and MTR.GetPlayerGuildRank()) or "Member"
            statusLbl:SetText("|cffffff88Current access: Member|r  |cffaaaaaa(" .. tostring(rankName) .. ")|r")
        end

        local rulesLbl = content:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        rulesLbl:SetPoint("TOPLEFT",content,"TOPLEFT",10,-112)
        rulesLbl:SetWidth(780) rulesLbl:SetWordWrap(true) rulesLbl:SetJustifyH("LEFT")
        rulesLbl:SetText([[|cffd4af37Restricted actions:|r
• Recruit popups, guild invites, recruit management
• DKP award / deduct / set / sync actions
• Inactivity mass-kick and kick tools
• Guild advertisement auto-poster

|cffd4af37Open to everyone:|r
• Character Vault
• Group Radar
• Guild Tree / Standings / normal viewing tabs
]])

        local officerHdr = content:CreateFontString(nil,"OVERLAY","GameFontNormal")
        officerHdr:SetPoint("TOPLEFT",content,"TOPLEFT",10,-240)
        officerHdr:SetText("|cffd4af37Officer Ranks|r")

        local officerDesc = content:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        officerDesc:SetPoint("TOPLEFT",content,"TOPLEFT",10,-260)
        officerDesc:SetWidth(780) officerDesc:SetWordWrap(true) officerDesc:SetJustifyH("LEFT")
        officerDesc:SetText("|cffaaaaaaGuild Masters can choose which guild ranks count as officer access for MekTown guild-control tools. Changes apply immediately after Save/Refresh and affect access to the officer panel, Recruit, DKP write actions, Loot admin, and kick tools.|r")

        local rankContainer = CreateFrame("Frame", nil, content)
        rankContainer:SetSize(780, 200)
        rankContainer:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -310)

        local function RefreshOfficerRankUI()
            for _, v in ipairs({rankContainer:GetChildren()}) do v:Hide() v:SetParent(nil) end
            local ranks = (MTR.GetGuildRanks and MTR.GetGuildRanks()) or {}
            for i, info in ipairs(ranks) do
                local row = CreateFrame("CheckButton", nil, rankContainer, "UICheckButtonTemplate")
                local canEdit = (MTR.isGM == true and tonumber(info.index) ~= 0)
                if not canEdit then row:Disable() row:SetAlpha(0.6) end
                row:SetPoint("TOPLEFT", rankContainer, "TOPLEFT", (i-1)%3 * 250, -math.floor((i-1)/3)*30)
                row._label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row._label:SetPoint("LEFT", row, "RIGHT", 4, 1)
                row._label:SetText((tonumber(info.index) == 0 and "|cff00ff00[GM]|r " or "") .. tostring(info.name))
                row:SetChecked((MTR.IsConfiguredOfficerRank and MTR.IsConfiguredOfficerRank(info.name, info.index)) or tonumber(info.index) == 0)
                row:SetScript("OnClick", function(self)
                    if not MTR.isGM then
                        self:SetChecked((MTR.IsConfiguredOfficerRank and MTR.IsConfiguredOfficerRank(info.name, info.index)) or tonumber(info.index) == 0)
                        return
                    end
                    if MTR.SetOfficerRank then MTR.SetOfficerRank(info.name, self:GetChecked(), info.index) end
                    MTR.isGM = MTR.CheckIsGM()
                    MTR.isOfficer = MTR.CheckIsOfficer()
                    if statusLbl then
                        if MTR.isGM then
                            statusLbl:SetText("|cff00ff00Current access: Guild Master|r")
                        elseif MTR.isOfficer then
                            statusLbl:SetText("|cff00ff00Current access: Officer|r")
                        else
                            local rName = (MTR.GetPlayerGuildRank and MTR.GetPlayerGuildRank()) or "Member"
                            statusLbl:SetText("|cffffff88Current access: Member|r  |cffaaaaaa(" .. tostring(rName) .. ")|r")
                        end
                    end
                    RefreshOfficerRankUI()
                end)
            end
        end

        local guessBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        guessBtn:SetSize(180, 22)
        guessBtn:SetPoint("TOPLEFT", content, "TOPLEFT", 10, -520)
        guessBtn:SetText("Auto-detect Officer Ranks")
        guessBtn:SetScript("OnClick", function()
            if not MTR.isGM then MPE("GM only.") return end
            local count = MTR.ApplyOfficerRankSuggestions and MTR.ApplyOfficerRankSuggestions(true) or 0
            MTR.isGM = MTR.CheckIsGM()
            MTR.isOfficer = MTR.CheckIsOfficer()
            RefreshOfficerRankUI()
            MP("Officer ranks updated (" .. tostring(count) .. " detected).")
        end)

        mainWin._refreshOfficerRankUI = RefreshOfficerRankUI
        RefreshOfficerRankUI()
        content:SetHeight(600)
    end

    -- =========================================================================
    -- RECRUIT SCANNER TAB
    -- =========================================================================
    tabBuilders["Recruit"] = function(t)
        if t.SetClipsChildren then t:SetClipsChildren(true) end
        local LW = 380   -- left column usable width
        local RX = 410   -- right column x start
        local RW = 470   -- right column usable width

        local rcDiv = t:CreateTexture(nil,"ARTWORK")
        rcDiv:SetColorTexture(0.3,0.3,0.3,0.6) rcDiv:SetSize(1,570)
        rcDiv:SetPoint("TOPLEFT",t,"TOPLEFT",400,0)

        local LEFT_BTN_W = 120
        local LEFT_BTN_X = 256
        local DISP_W = LEFT_BTN_X - 8

        local function PlaceSummaryRow(title, sepY, txtY, btnY, btnText)
            MakeSep(t, title, sepY)
            local fs = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", t, "TOPLEFT", 0, txtY)
            fs:SetText("Loading...")
            Lock(fs, DISP_W)
            local btn = MakeBT(t, btnText, LEFT_BTN_W, 24)
            btn:SetPoint("TOPLEFT", t, "TOPLEFT", LEFT_BTN_X, btnY)
            return fs, btn
        end

        local kwDisplay, kwEditBtn = PlaceSummaryRow("Keywords", -2, -18, -30, "Edit Keywords")
        mainWin._kwDisplay = kwDisplay

        local wtDisplay, wtEditBtn = PlaceSummaryRow("Whisper Templates", -72, -88, -100, "Edit Templates")
        mainWin._wtDisplay = wtDisplay

        local adDisplay, adEditBtn = PlaceSummaryRow("Ad Detection Phrases", -142, -158, -170, "Edit Ad Phrases")
        mainWin._adDisplay = adDisplay

        MakeSep(t,"Recruit Whisper History",-212)
        local _, histEB = MakeRO(t, LW, 258, 0, -228)
        mainWin._recruitHistEB = histEB

        local historyActions = {
            { key = "view", label = "View All" },
            { key = "guild", label = "Guild" },
            { key = "officer", label = "Officer" },
            { key = "print", label = "Print" },
            { key = "clear", label = "Clear" },
        }
        local histBtns = {}
        local H_COLS, H_W, H_H, H_GX, H_GY = 3, 120, 22, 8, 6
        for i, item in ipairs(historyActions) do
            local col = (i - 1) % H_COLS
            local row = math.floor((i - 1) / H_COLS)
            local btn = MakeBT(t, item.label, H_W, H_H)
            btn:SetPoint("TOPLEFT", t, "TOPLEFT", col * (H_W + H_GX), -496 - row * (H_H + H_GY))
            histBtns[item.key] = btn
        end
        local viewAllBtn = histBtns.view
        local expG = histBtns.guild
        local expO = histBtns.officer
        local expP = histBtns.print
        local clrH = histBtns.clear
        viewAllBtn:SetScript("OnClick",function()
            if not CfgDB() then return end
            local hist = CfgDB().recruitHistory or {}
            local lines = { string.format("%-20s | %-16s | %s", "Recruit", "Sent By", "Date"), string.rep("-", 58) }
            for i = #hist, 1, -1 do
                local e = hist[i]
                local recruit = e.recruit or e.player or "?"
                local sentBy  = e.sentBy  or "?"
                lines[#lines+1] = string.format("%-20s | %-16s | %s", recruit, sentBy, e.time or "?")
            end
            OpenEP("Recruit Whisper History — " .. #hist .. " entries", #lines>0 and table.concat(lines,"\n") or "No history yet.", nil)
        end)
        expG:SetScript("OnClick",function() if CfgDB() then MTR.ExportHistory(MTR.FormatRecruitHistory(CfgDB().recruitHistory),"GUILD") end end)
        expO:SetScript("OnClick",function() if CfgDB() then MTR.ExportHistory(MTR.FormatRecruitHistory(CfgDB().recruitHistory),"OFFICER") end end)
        expP:SetScript("OnClick",function() if CfgDB() then MTR.ExportHistory(MTR.FormatRecruitHistory(CfgDB().recruitHistory),"PRINT") end end)
        clrH:SetScript("OnClick",function() if CfgDB() then CfgDB().recruitHistory={} end histEB:SetText("Cleared.") end)

        local rcHdr = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        rcHdr:SetPoint("TOPLEFT",t,"TOPLEFT",RX,-2)
        rcHdr:SetText("|cffd4af37— Scanner Settings —|r")

        mainWin._ckEnable  = MakeCK("RcEnable",  t,"Enable recruitment scanner",  RX,  -18)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckEnable, "enabled") end
        mainWin._ckGuild   = MakeCK("RcGuild",   t,"Require 'guild' in message",  RX,  -44)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckGuild, "requireGuildWord") end
        mainWin._ckSound   = MakeCK("RcSound",   t,"Sound alert on popup",        RX,  -72)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckSound, "soundAlert") end
        mainWin._ckMinimap = MakeCK("RcMinimap", t,"Show minimap button",         RX, -100)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckMinimap, "minimapButton") end
        mainWin._ckDebug   = MakeCK("RcDebug",   t,"Enable Debug",               RX, -128)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckDebug, "enableDebug") end
        mainWin._ckIgnAds  = MakeCK("RcIgnAds",  t,"Ignore recruitment ads",      RX, -156)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckIgnAds, "ignoreAds") end

        local lbl1 = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl1:SetPoint("TOPLEFT",t,"TOPLEFT",RX,-186) lbl1:SetText("Additional required words (comma-sep):")
        mainWin._addReqEB = MakeIn("AddReq",t,RW,RX,-202)
        if Settings then Settings.BindEdit(mainWin, mainWin._addReqEB, "additionalRequired") end

        local lbl2 = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl2:SetPoint("TOPLEFT",t,"TOPLEFT",RX,-232) lbl2:SetText("Ignore duration (seconds):")
        mainWin._slIgnore = MakeSL("Ignore",t,RW,RX,-248,60,3600,60)
        if Settings then Settings.BindSlider(mainWin, mainWin._slIgnore, "ignoreDuration", {default=300, step=60}) end
        mainWin._slIgnore:SetScript("OnValueChanged",function(s,v)
            local r=math.floor(v/60)*60
            _G["MekSLv_IgnoreText"]:SetText(r.."s")
            SaveValue("ignoreDuration", r)
        end)

        PlaceHelpText(t, RX, -286, RW, "Format: Keywords, templates, and ad phrases are one entry per line. Whisper uses a random template and supports {name} and {context}. Ignore Ads skips messages matching ad phrases.")

        MakeSep(t,"Scan Channels",-412)
        local chDefs = {
            {"CHAT_MSG_CHANNEL","Trade/General"}, {"CHAT_MSG_SAY","Say"},
            {"CHAT_MSG_YELL","Yell"},             {"CHAT_MSG_PARTY","Party"},
            {"CHAT_MSG_WHISPER","Whisper"},        {"CHAT_MSG_GUILD","Guild"},
            {"CHAT_MSG_RAID","Raid"},
        }
        mainWin._chanChecks = {}
        for i, cd in ipairs(chDefs) do
            local col = (i-1) % 2
            local row = math.floor((i-1) / 2)
            local cname = "RcCh"..i
            local ck = CreateFrame("CheckButton","MekCK_"..cname,t,"UICheckButtonTemplate")
            ck:SetPoint("TOPLEFT",t,"TOPLEFT", RX+col*220, -428-row*26)
            _G["MekCK_"..cname.."Text"]:SetText(cd[2])
            ck.channel = cd[1]
            ck:SetScript("OnClick",function(s) SaveBool("scanChannels."..s.channel, s:GetChecked()) end)
            mainWin._chanChecks[i] = ck
        end

        kwEditBtn:SetScript("OnClick",function()
            OpenEP("Edit Keywords\n|cffaaaaaaOne keyword per line. Matching any keyword qualifies a message for recruit scanning.|r", table.concat(CfgDB().keywords or {}, "\n"), function(text)
                local newKeywords = {}
                for line in text:gmatch("([^\n]+)") do
                    local s=line:match("^%s*(.-)%s*$") if s~="" then newKeywords[#newKeywords+1]=s end
                end
                local savedKeywords = SaveTable("keywords", newKeywords)
                kwDisplay:SetText(Trunc(#savedKeywords.." keywords saved.", 50))
            end)
        end)
        wtEditBtn:SetScript("OnClick",function()
            OpenEP("Edit Whisper Templates\n|cffaaaaaaOne template per line. Whisper button chooses a random template. Variables: {name}, {context}.|r", table.concat(CfgDB().whisperTemplates or {}, "\n"), function(text)
                local newTemplates = {}
                for line in text:gmatch("([^\n]+)") do
                    local s=line:match("^%s*(.-)%s*$") if s~="" then newTemplates[#newTemplates+1]=s end
                end
                local savedTemplates = SaveTable("whisperTemplates", newTemplates)
                wtDisplay:SetText(Trunc(#savedTemplates.." templates saved.", 50))
            end)
        end)
        adEditBtn:SetScript("OnClick",function()
            OpenEP("Edit Ad Detection Phrases\n|cffaaaaaaOne phrase per line. Used to classify recruiter spam / guild ads.|r", table.concat(CfgDB().adPatterns or {}, "\n"), function(text)
                local newPatterns = {}
                for line in text:gmatch("([^\n]+)") do
                    local s=line:match("^%s*(.-)%s*$") if s~="" then newPatterns[#newPatterns+1]=s end
                end
                local savedPatterns = SaveTable("adPatterns", newPatterns)
                adDisplay:SetText(Trunc(#savedPatterns.." phrases saved.", 50))
            end)
        end)

        mainWin._ckEnable:SetScript("OnClick",function(s)
            SaveBool("enabled", s:GetChecked())
            if CfgDB().enabled then MTR.MP("|cff00ff00Scanner enabled.|r") else MTR.MP("|cffff4444Scanner disabled.|r") end
        end)
        mainWin._ckGuild:SetScript("OnClick",   function(s) SaveBool("requireGuildWord", s:GetChecked()) end)
        mainWin._ckSound:SetScript("OnClick",   function(s) SaveBool("soundAlert", s:GetChecked()) end)
        mainWin._ckMinimap:SetScript("OnClick", function(s) SaveBool("minimapButton", s:GetChecked()) end)
        mainWin._ckDebug:SetScript("OnClick",   function(s) SaveBool("enableDebug", s:GetChecked()) end)
        mainWin._ckIgnAds:SetScript("OnClick",  function(s) SaveBool("ignoreAds", s:GetChecked()) end)
        mainWin._addReqEB:SetScript("OnTextChanged", function(s) SaveValue("additionalRequired", s:GetText() or "") end)
    end

    -- =========================================================================
    -- GUILD ADS TAB
    -- =========================================================================
    tabBuilders["Ads"] = function(t)
        if t.SetClipsChildren then t:SetClipsChildren(true) end
        local LW = 800
        MakeSep(t, "|cffff2020Guild Advertisement Auto-Poster|r", -2)

        PlaceHelpText(t, HELP_COL_X, -18, HELP_COL_W, "Format: one ad per line. Prefix a line with #DISABLED# to keep it saved but inactive. {star}, {skull}, etc. are sent as icons.")

        local adPostDisplay = t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        adPostDisplay:SetPoint("TOPLEFT",t,"TOPLEFT",10,-24)
        adPostDisplay:SetText("Loading...") Lock(adPostDisplay, 400)
        mainWin._adPostDisplay = adPostDisplay

        local adPostEditBtn = MakeBT(t,"Edit Messages",140,26)
        adPostEditBtn:SetPoint("TOPLEFT",t,"TOPLEFT",10,-44)
        adPostEditBtn:SetScript("OnClick",function()
            if not CfgDB() then return end
            local lines={}
            for _, m in ipairs(CfgDB().guildAdMessages or {}) do
                lines[#lines+1] = (m.enabled==false and "#DISABLED# " or "") .. (m.text or "")
            end
            OpenEP("Edit Guild Ad Messages\n|cffaaaaaaOne message per line. Prefix with #DISABLED# to keep a line saved but inactive.|r", table.concat(lines,"\n"), function(text)
                CfgDB().guildAdMessages = {}
                for line in text:gmatch("([^\n]+)") do
                    local enabled = true
                    local msg = line:match("^%s*(.-)%s*$")
                    if msg:sub(1,11) == "#DISABLED# " then
                        enabled = false
                        msg = msg:sub(12):match("^%s*(.-)%s*$")
                    end
                    if msg ~= "" then CfgDB().guildAdMessages[#CfgDB().guildAdMessages+1] = {text=msg, enabled=enabled} end
                end
                local en=0
                for _,m in ipairs(CfgDB().guildAdMessages) do if m.enabled~=false then en=en+1 end end
                adPostDisplay:SetText(#CfgDB().guildAdMessages.." messages ("..en.." enabled)")
            end)
        end)

        local adIntLbl = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        adIntLbl:SetPoint("TOPLEFT",t,"TOPLEFT",10,-120) adIntLbl:SetText("Post every:")
        local adIntervals = {5,10,15,20,30}
        local adIntBtns = {}
        for i, mins in ipairs(adIntervals) do
            local btn = MakeBT(t, mins.."m", 56, 24)
            btn:SetPoint("TOPLEFT", t, "TOPLEFT", 100 + (i-1) * 64, -116)
            adIntBtns[i]=btn
            do local m=mins
                btn:SetScript("OnClick",function()
                    if CfgDB() and CfgDB().guildAdConfig then CfgDB().guildAdConfig.intervalMins = m end
                    for _, b in ipairs(adIntBtns) do b:UnlockHighlight() end
                    btn:LockHighlight()
                    if MTR.GuildAds and MTR.GuildAds.active then MTR.GuildAds.timer = m * 60 end
                end)
            end
        end
        mainWin._adIntBtns = adIntBtns
        mainWin._adIntervals = adIntervals

        local adChanLbl = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        adChanLbl:SetPoint("TOPLEFT",t,"TOPLEFT",10,-156) adChanLbl:SetText("Public Channel #:")
        local adChanEB = MakeIn("AdChan",t,60,140,-152)
        adChanEB:SetText("1")
        adChanEB:SetScript("OnTextChanged",function(s)
            local n = tonumber(s:GetText() or "1") or 1
            if CfgDB() and CfgDB().guildAdConfig then CfgDB().guildAdConfig.channelNum = n end
        end)
        mainWin._adChanEB = adChanEB

        local adStatusLbl = t:CreateFontString(nil,"OVERLAY","GameFontHighlight")
        adStatusLbl:SetPoint("TOPLEFT",t,"TOPLEFT",10,-190)
        adStatusLbl:SetText("|cffff4444● Stopped|r")
        mainWin._adStatusLbl = adStatusLbl
        MTR.After(1, function() if MTR.GuildAds then MTR.GuildAds.statusLabel = adStatusLbl end end)

        local adToggleBtn = MakeBT(t,"|cff00ff00Start Posting|r",140,28)
        adToggleBtn:SetPoint("TOPLEFT",t,"TOPLEFT",10,-220)
        adToggleBtn:SetScript("OnClick",function()
            if not MTR.GuildAds then return end
            MTR.GuildAds.Toggle()
            adToggleBtn:SetText(MTR.GuildAds.active and "|cffff4444Stop Posting|r" or "|cff00ff00Start Posting|r")
        end)
        mainWin._adToggleBtn = adToggleBtn

        local adNowBtn = MakeBT(t,"Post Now",140,28)
        adNowBtn:SetPoint("LEFT",adToggleBtn,"RIGHT",10,0)
        adNowBtn:SetScript("OnClick",function() if MTR.GuildAds then MTR.GuildAds.PostNow() end end)
        mainWin._adNowBtn = adNowBtn
    end

    CommitGuildTabState = function()
        if not mainWin then return end
        ForcePersistGuildInviteWidgets()
        local cfg = CfgDB()
        if type(cfg) ~= "table" then return end
        if mainWin._ikDisplay then
            mainWin._ikDisplay:SetText(Trunc((#(cfg.inviteKeywords or {})).." keywords", 60))
        end
        if mainWin._arDisplay then
            mainWin._arDisplay:SetText(Trunc((#(cfg.autoResponses or {})).." responses", 60))
        end
        if mainWin._motdDisplay then
            local motdKeys = {}
            for k in pairs(cfg.motdTemplates or {}) do motdKeys[#motdKeys+1] = k end
            table.sort(motdKeys)
            mainWin._motdDisplay:SetText(Trunc(#motdKeys > 0 and table.concat(motdKeys, ", ") or "None", 60))
        end
    end

    RefreshGuildTabState = function()
        if not mainWin then return end
        local cfg = CfgDB()
        if type(cfg) ~= "table" then return end

        if mainWin._guildInvEnable then mainWin._guildInvEnable:SetChecked(cfg.enableGuildInvites == true) end
        if mainWin._guildInvAnnounce then mainWin._guildInvAnnounce:SetChecked(cfg.inviteAnnounce == true) end
        if mainWin._guildWelcomeEB then mainWin._guildWelcomeEB:SetText(cfg.inviteWelcomeMsg or "") end
        if mainWin._guildInvCooldown then mainWin._guildInvCooldown:SetValue(tonumber(cfg.inviteCooldown) or 60) end
        if mainWin._guildAutoReply then mainWin._guildAutoReply:SetChecked(cfg.autoResponderEnabled == true) end
        if mainWin._ikDisplay then
            mainWin._ikDisplay:SetText(Trunc((#(cfg.inviteKeywords or {})).." keywords", 60))
        end
        if mainWin._arDisplay then
            mainWin._arDisplay:SetText(Trunc((#(cfg.autoResponses or {})).." responses", 60))
        end
        if mainWin._motdDisplay then
            local motdKeys = {}
            for k in pairs(cfg.motdTemplates or {}) do motdKeys[#motdKeys+1] = k end
            table.sort(motdKeys)
            mainWin._motdDisplay:SetText(Trunc(#motdKeys > 0 and table.concat(motdKeys, ", ") or "None", 60))
        end
    end

    -- =========================================================================
    -- GUILD UTILS TAB
    -- =========================================================================
    tabBuilders["Guild"] = function(t)

        if t.SetClipsChildren then t:SetClipsChildren(true) end

        local scroll = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", t, "TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -28, 8)

        local content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(820)
        content:SetHeight(1040)
        if content.SetClipsChildren then content:SetClipsChildren(true) end
        scroll:SetScrollChild(content)

        local PANEL_W = 780
        local LEFT = 12
        local FIELD_X = LEFT + 16
        local FIELD_W = PANEL_W - 32
        local y = -10

        local function AddHeader(text, desc)
            local hdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            hdr:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
            hdr:SetWidth(PANEL_W)
            hdr:SetJustifyH("LEFT")
            hdr:SetText(text)
            y = y - 26

            if desc then
                local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                fs:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
                fs:SetWidth(PANEL_W)
                fs:SetJustifyH("LEFT")
                fs:SetWordWrap(true)
                fs:SetText(desc)
                y = y - 36
            end

            local sep = content:CreateTexture(nil, "ARTWORK")
            sep:SetColorTexture(0.3, 0.3, 0.5, 0.45)
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
            sep:SetPoint("TOPRIGHT", content, "TOPLEFT", LEFT + PANEL_W, y)
            y = y - 18
        end

        local function AddLabel(text)
            local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
            fs:SetWidth(PANEL_W)
            fs:SetJustifyH("LEFT")
            fs:SetText(text)
            y = y - 20
            return fs
        end

        AddHeader("|cffff2020Guild Settings|r", "Guild invite, messaging, and automation controls. This tab is rebuilt as a contained left-aligned scroll layout with direct profile-backed saves.")

        local guildFmtHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        guildFmtHint:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
        guildFmtHint:SetWidth(PANEL_W)
        guildFmtHint:SetJustifyH("LEFT")
        guildFmtHint:SetWordWrap(true)
        guildFmtHint:SetText("|cff9a9a9aFormat: Invite Keywords = one per line. Auto-Responses = trigger|response per line. MOTD Templates = key=value per line.|r")
        y = y - 30

        local inviteHdr = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        inviteHdr:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
        inviteHdr:SetWidth(PANEL_W)
        inviteHdr:SetJustifyH("LEFT")
        inviteHdr:SetText("|cffd4af37Guild Invite|r")
        y = y - 32

        mainWin._guildInvEnable = MakeCK("InvEn", content, "Enable auto-invite from guild chat", FIELD_X, y)
        mainWin._guildInvEnable:SetScript("OnClick", function(self) SaveBool("enableGuildInvites", self:GetChecked()) end)
        y = y - 28

        mainWin._guildInvAnnounce = MakeCK("InvAnn", content, "Announce invite in guild chat", FIELD_X, y)
        mainWin._guildInvAnnounce:SetScript("OnClick", function(self) SaveBool("inviteAnnounce", self:GetChecked()) end)
        y = y - 38

        AddLabel("Welcome whisper to new guild members (blank = off):")
        mainWin._guildWelcomeEB = MakeIn("InvWelcome", content, FIELD_W, FIELD_X, y)
        mainWin._guildWelcomeEB:SetScript("OnTextChanged", function(self) if not mainWin._refreshing then SaveText("inviteWelcomeMsg", self:GetText() or "") end end)
        mainWin._guildWelcomeEB:SetScript("OnEnterPressed", function(self) SaveText("inviteWelcomeMsg", self:GetText() or ""); self:ClearFocus() end)
        mainWin._guildWelcomeEB:SetScript("OnEscapePressed", function(self) SaveText("inviteWelcomeMsg", self:GetText() or ""); self:ClearFocus() end)
        mainWin._guildWelcomeEB:SetScript("OnEditFocusLost", function(self) SaveText("inviteWelcomeMsg", self:GetText() or "") end)
        y = y - 42

        AddLabel("Invite cooldown (seconds):")
        mainWin._guildInvCooldown = MakeSL("InvCD", content, 420, FIELD_X, y, 30, 600, 10)
        mainWin._guildInvCooldown:SetScript("OnValueChanged", function(self, value)
            local r = math.max(30, math.min(600, math.floor((tonumber(value) or 60) / 10) * 10))
            local label = _G["MekSLv_InvCDText"]
            if label then label:SetText(r.."s") end
            if not mainWin._refreshing then SaveSlider("inviteCooldown", r, 10) end
        end)
        y = y - 58

        MakeSep(content, "Invite Keywords", y)
        y = y - 20
        local ikDisplay = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        ikDisplay:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
        ikDisplay:SetWidth(PANEL_W)
        ikDisplay:SetWordWrap(true)
        ikDisplay:SetJustifyH("LEFT")
        ikDisplay:SetText("Loading...")
        mainWin._ikDisplay = ikDisplay
        y = y - 28

        local ikEditBtn = MakeBTStd(content, "Edit Keywords", "MD")
        ikEditBtn:SetPoint("TOPLEFT", content, "TOPLEFT", FIELD_X, y)
        ikEditBtn:SetScript("OnClick", function()
            OpenEP("Edit Invite Keywords\n|cffaaaaaaOne keyword per line. Any matching guild chat line can trigger auto-invite logic.|r", table.concat(CfgDB().inviteKeywords or {}, "\n"), function(text)
                local inviteKeywords = {}
                for line in text:gmatch("([^\n]+)") do
                    local s = line:match("^%s*(.-)%s*$")
                    if s ~= "" then inviteKeywords[#inviteKeywords + 1] = s end
                end
                CfgDB().inviteKeywords = inviteKeywords
                MTR.db = CfgDB()
                mainWin._dirty = true
                RefreshGuildTabState()
            end)
        end)
        y = y - 34

        local note = content:CreateFontString(nil, "OVERLAY", "GameFontGreen")
        note:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
        note:SetWidth(PANEL_W)
        note:SetJustifyH("LEFT")
        note:SetWordWrap(true)
        note:SetText("Digit-only messages (123, 1...) and short 'ready'/'rdy' are also matched automatically.")
        y = y - 44

        MakeSep(content, "Whisper Auto-Responder", y)
        y = y - 20
        mainWin._guildAutoReply = MakeCK("AutoRpy", content, "Enable whisper auto-responder", FIELD_X, y)
        mainWin._guildAutoReply:SetScript("OnClick", function(self) SaveBool("autoResponderEnabled", self:GetChecked()) end)
        y = y - 40

        MakeSep(content, "Auto-Responses (trigger|response per line)", y)
        y = y - 20
        local arDisplay = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        arDisplay:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
        arDisplay:SetWidth(PANEL_W)
        arDisplay:SetWordWrap(true)
        arDisplay:SetJustifyH("LEFT")
        arDisplay:SetText("Loading...")
        mainWin._arDisplay = arDisplay
        y = y - 28

        local arEditBtn = MakeBTStd(content, "Edit Responses", "MD")
        arEditBtn:SetPoint("TOPLEFT", content, "TOPLEFT", FIELD_X, y)
        arEditBtn:SetScript("OnClick", function()
            local lines = {}
            for _, rule in ipairs(CfgDB().autoResponses or {}) do
                if rule.trigger and rule.response then
                    lines[#lines + 1] = rule.trigger .. "|" .. rule.response
                end
            end
            OpenEP("Edit Auto-Responses\n|cffaaaaaaUse trigger|response, one rule per line. First matching trigger is used.|r", table.concat(lines, "\n"), function(text)
                local newResponses = {}
                for line in text:gmatch("([^\n]+)") do
                    local tr, resp = line:match("^(.-)%|(.+)$")
                    if tr and resp then
                        tr = tr:match("^%s*(.-)%s*$")
                        resp = resp:match("^%s*(.-)%s*$")
                        if tr ~= "" then
                            newResponses[#newResponses + 1] = { trigger = tr, response = resp }
                        end
                    end
                end
                CfgDB().autoResponses = newResponses
                MTR.db = CfgDB()
                mainWin._dirty = true
                RefreshGuildTabState()
            end)
        end)
        y = y - 42

        MakeSep(content, "MOTD Templates (key=value)", y)
        y = y - 20
        local motdDisplay = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        motdDisplay:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
        motdDisplay:SetWidth(PANEL_W)
        motdDisplay:SetWordWrap(true)
        motdDisplay:SetJustifyH("LEFT")
        motdDisplay:SetText("Loading...")
        mainWin._motdDisplay = motdDisplay
        y = y - 28

        local motdEditBtn = MakeBT(content, "Edit MOTD Templates", 170, 26)
        motdEditBtn:SetPoint("TOPLEFT", content, "TOPLEFT", FIELD_X, y)
        motdEditBtn:SetScript("OnClick", function()
            local lines = {}
            for k, v in pairs(CfgDB().motdTemplates or {}) do lines[#lines + 1] = k .. "=" .. v end
            table.sort(lines)
            OpenEP("Edit MOTD Templates\n|cffaaaaaaUse key=value per line. Keys are used in 'Set MOTD by key'.|r", table.concat(lines, "\n"), function(text)
                local newTemplates = {}
                for line in text:gmatch("([^\n]+)") do
                    local k, v = line:match("^(.-)=(.+)$")
                    if k and v then
                        k = k:match("^%s*(.-)%s*$")
                        v = v:match("^%s*(.-)%s*$")
                        if k ~= "" then newTemplates[k] = v end
                    end
                end
                CfgDB().motdTemplates = newTemplates
                MTR.db = CfgDB()
                mainWin._dirty = true
                RefreshGuildTabState()
            end)
        end)
        y = y - 38

        AddLabel("Set MOTD by key:")
        mainWin._motdKeyEB = MakeIn("MOTDKey", content, 180, FIELD_X, y)
        local setMotdBtn = MakeBTStd(content, "Set MOTD", "SM")
        setMotdBtn:SetPoint("LEFT", mainWin._motdKeyEB, "RIGHT", 8, 0)
        setMotdBtn:SetScript("OnClick", function()
            if not (MTR.isOfficer or MTR.isGM) then MPE("Officers only.") return end
            local k = (mainWin._motdKeyEB:GetText() or ""):match("^%s*(.-)%s*$")
            if k == "" then return end
            local tmpl = CfgDB().motdTemplates and CfgDB().motdTemplates[k]
            if not tmpl then MP("Unknown template key: " .. k) return end
            GuildSetMOTD(tmpl)
            MP("MOTD set to '" .. k .. "' template.")
        end)
        y = y - 60

        content:SetHeight(math.abs(y) + 40)
        mainWin._refreshGuildTab = RefreshGuildTabState

        if MTR.AttachTooltip then
            MTR.AttachTooltip(ikEditBtn, "Invite Keywords", "Edit guild-chat keywords that trigger auto-invite.")
            MTR.AttachTooltip(arEditBtn, "Auto Responses", "Edit whisper auto-response rules in trigger|response format.")
            MTR.AttachTooltip(motdEditBtn, "MOTD Templates", "Edit saved Message of the Day templates.")
            MTR.AttachTooltip(setMotdBtn, "Set MOTD", "Apply the template key entered to the live guild MOTD.")
        end

        RefreshGuildTabState()
    end

    -- =========================================================================
    -- DKP SETTINGS TAB  (lazy-built on first click)
    -- =========================================================================
    tabBuilders["DKP"] = function(t)
        if t.SetClipsChildren then t:SetClipsChildren(true) end
        PlaceHelpText(t, 330, -6, 540, "Writes are officer/GM-only. Raid and bulk awards apply only to current guild members; non-guild players are skipped.")

        mainWin._ckDKPEnable = MakeCK("DKPEn",t,"Enable DKP system",0,-4)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckDKPEnable, "dkpEnabled") end
        mainWin._ckDKPEnable:SetScript("OnClick",function(s) SaveBool("dkpEnabled", s:GetChecked()) end)

        local l1=t:CreateFontString(nil,"OVERLAY","GameFontNormal") l1:SetPoint("TOPLEFT",t,"TOPLEFT",0,-38) l1:SetText("DKP per raid attendance:")
        mainWin._slDKPRaid = MakeSL("DKPRaid",t,300,0,-54,0,200,5)
        if Settings then Settings.BindSlider(mainWin, mainWin._slDKPRaid, "dkpPerRaid", {default=10, step=5}) end
        mainWin._slDKPRaid:SetScript("OnValueChanged",function(s,v) _G["MekSLv_DKPRaidText"]:SetText(v) SaveValue("dkpPerRaid", math.floor(v)) end)

        local l2=t:CreateFontString(nil,"OVERLAY","GameFontNormal") l2:SetPoint("TOPLEFT",t,"TOPLEFT",0,-86) l2:SetText("DKP per boss kill:")
        mainWin._slDKPBoss = MakeSL("DKPBoss",t,300,0,-102,0,100,1)
        if Settings then Settings.BindSlider(mainWin, mainWin._slDKPBoss, "dkpPerBoss", {default=5, step=1}) end
        mainWin._slDKPBoss:SetScript("OnValueChanged",function(s,v) _G["MekSLv_DKPBossText"]:SetText(v) SaveValue("dkpPerBoss", math.floor(v)) end)

        local l3=t:CreateFontString(nil,"OVERLAY","GameFontNormal") l3:SetPoint("TOPLEFT",t,"TOPLEFT",0,-134) l3:SetText("Default publish channel:")
        local chanDD=CreateFrame("Frame","MekDKPChanDDv",t,"UIDropDownMenuTemplate")
        chanDD:SetPoint("TOPLEFT",t,"TOPLEFT",-4,-148) UIDropDownMenu_SetWidth(chanDD,130)
        mainWin._dkpChanDD=chanDD
        if Settings then
            Settings.BindCustom(mainWin, function()
                if mainWin._dkpChanDD then
                    UIDropDownMenu_SetSelectedValue(mainWin._dkpChanDD, Settings.Get("dkpPublishChannel", "GUILD"))
                end
            end, function()
                local selected = UIDropDownMenu_GetSelectedValue(mainWin._dkpChanDD)
                if selected and selected ~= "" then Settings.Set("dkpPublishChannel", selected) end
            end, "dkpPublishChannel")
        end
        UIDropDownMenu_Initialize(chanDD,function()
            for _,ch in ipairs({"GUILD","OFFICER","RAID","PARTY","SAY"}) do
                local info=UIDropDownMenu_CreateInfo()
                info.text=ch info.value=ch
                info.func=function() UIDropDownMenu_SetSelectedValue(chanDD,ch) SaveValue("dkpPublishChannel", ch) end
                UIDropDownMenu_AddButton(info)
            end
        end)

        mainWin._ckAttAuto = MakeCK("AttAuto",t,"Auto-snapshot attendance on raid zone entry",0,-182)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckAttAuto, "attendanceAutoSnapshot") end
        mainWin._ckAttAuto:SetScript("OnClick",function(s) SaveBool("attendanceAutoSnapshot", s:GetChecked()) end)

        MakeSep(t,"Actions",-212)
        PlaceHelpText(t, 626, -198, 240, "Sync sends balances and history to guild addon peers. Publish sends standings to the selected channel.")
        local syncBtn = MakeBTStd(t,"Sync DKP to Raid","LG") syncBtn:SetPoint("TOP",t,"TOP",-74,-228)
        syncBtn:SetScript("OnClick",function() MTR.DKPSyncToRaid() end)
        local pubBtn = MakeBTStd(t,"Publish Standings","LG") pubBtn:SetPoint("LEFT",syncBtn,"RIGHT",8,0)
        pubBtn:SetScript("OnClick",function() if CfgDB() then MTR.DKPPublish(CfgDB().dkpPublishChannel) end end)

        MakeSep(t,"Officer Actions",-270)
        local actLbl=t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        actLbl:SetPoint("TOP",t,"TOP",0,-288)
        actLbl:SetText("|cffaaaaaaMembers can only view their own history. Officers and above can manage and review all DKP entries.|r")

        local dl1=t:CreateFontString(nil,"OVERLAY","GameFontNormal") dl1:SetPoint("TOPLEFT",t,"TOPLEFT",120,-316) dl1:SetText("Player:")
        mainWin._ledgPlayerEB = MakeIn("LPly",t,160,170,-312)
        local dl2=t:CreateFontString(nil,"OVERLAY","GameFontNormal") dl2:SetPoint("TOPLEFT",t,"TOPLEFT",352,-316) dl2:SetText("Pts:")
        mainWin._ledgAmtEB = MakeIn("LAmt",t,70,380,-312)
        local dl3=t:CreateFontString(nil,"OVERLAY","GameFontNormal") dl3:SetPoint("TOPLEFT",t,"TOPLEFT",470,-316) dl3:SetText("Reason:")
        mainWin._ledgReasonEB = MakeIn("LRsn",t,220,530,-312)
        local awdBtn=MakeBTStd(t,"Award","MD") awdBtn:SetPoint("TOPLEFT",t,"TOPLEFT",170,-346)
        awdBtn:SetScript("OnClick",function()
            local n=(mainWin._ledgPlayerEB:GetText() or ""):match("^%s*(.-)%s*$")
            local a=tonumber(mainWin._ledgAmtEB:GetText() or "")
            local r=(mainWin._ledgReasonEB:GetText() or ""):match("^%s*(.-)%s*$")
            if n=="" or not a or a<=0 then MPE("Enter player name and positive amount.") return end
            MTR.DKPAdd(n,a,r~="" and r or "Officer award",MTR.playerName)
            MP("Awarded "..a.." to "..n..". Balance: "..MTR.DKPBalance(n))
        end)
        local dedBtn=MakeBTStd(t,"Deduct","MD") dedBtn:SetPoint("LEFT",awdBtn,"RIGHT",8,0)
        dedBtn:SetScript("OnClick",function()
            local n=(mainWin._ledgPlayerEB:GetText() or ""):match("^%s*(.-)%s*$")
            local a=tonumber(mainWin._ledgAmtEB:GetText() or "")
            local r=(mainWin._ledgReasonEB:GetText() or ""):match("^%s*(.-)%s*$")
            if n=="" or not a or a<=0 then MPE("Enter player name and positive amount.") return end
            MTR.DKPAdd(n,-a,r~="" and r or "Officer deduction",MTR.playerName)
            MP("Deducted "..a.." from "..n..". Balance: "..MTR.DKPBalance(n))
        end)
        local setBtn=MakeBTStd(t,"Set Balance (GM)","LG") setBtn:SetPoint("LEFT",dedBtn,"RIGHT",8,0)
        setBtn:SetScript("OnClick",function()
            if not MTR.isGM then MPE("GM only.") return end
            local n=(mainWin._ledgPlayerEB:GetText() or ""):match("^%s*(.-)%s*$")
            local a=tonumber(mainWin._ledgAmtEB:GetText() or "")
            if n=="" or not a then MPE("Enter player name and amount.") return end
            MTR.DKPSet(n,a,MTR.playerName) MP("Set "..n.."'s balance to "..a.." pts.")
        end)

        MakeSep(t,"Bulk Award",-388)
        PlaceHelpText(t, 0, -402, 210, "Applies only to current guild members in your party/raid roster.")
        local l4=t:CreateFontString(nil,"OVERLAY","GameFontNormal") l4:SetPoint("TOPLEFT",t,"TOPLEFT",220,-404) l4:SetText("Pts:")
        mainWin._bulkAmtEB = MakeIn("BAmt",t,70,252,-400)
        local l5=t:CreateFontString(nil,"OVERLAY","GameFontNormal") l5:SetPoint("TOPLEFT",t,"TOPLEFT",334,-404) l5:SetText("Reason:")
        mainWin._bulkReasonEB = MakeIn("BRsn",t,260,384,-400)
        local bkRaid=MakeBTStd(t,"Award Full Raid","LG") bkRaid:SetPoint("LEFT",mainWin._bulkReasonEB,"RIGHT",10,0)
        bkRaid:SetScript("OnClick",function()
            local a=tonumber(mainWin._bulkAmtEB:GetText() or "")
            if not a or a==0 then MPE("Enter an amount.") return end
            local r=(mainWin._bulkReasonEB:GetText() or ""):match("^%s*(.-)%s*$")
            MTR.DKPBulkAward(MTR.DKPGetRaidMembers(),a,r~="" and r or "Raid attendance award")
        end)

        MakeSep(t,"History",-442)
        local lh=t:CreateFontString(nil,"OVERLAY","GameFontNormal") lh:SetPoint("TOPLEFT",t,"TOPLEFT",200,-458) lh:SetText("Player name:")
        mainWin._ledgLookupEB = MakeIn("LLkp",t,180,282,-454)
        local lkBtn=MakeBTStd(t,"View","SM") lkBtn:SetPoint("LEFT",mainWin._ledgLookupEB,"RIGHT",6,0)
        local _,lkDisplay = MakeRO(t,520,205,180,-486)
        lkBtn:SetScript("OnClick",function()
            local n=(mainWin._ledgLookupEB:GetText() or ""):match("^%s*(.-)%s*$")
            if n=="" then return end
            local hist=CfgDB() and CfgDB().dkpLedger[n] and CfgDB().dkpLedger[n].history or {}
            if #hist==0 then lkDisplay:SetText(n..": No DKP history.") return end
            local lines={n.." — Balance: "..MTR.DKPBalance(n).." pts",""}
            for i=#hist,math.max(1,#hist-49),-1 do
                local e=hist[i]
                lines[#lines+1]=string.format("[%s] %s%d  (%s)",e.date or "?",e.amount>=0 and "+" or "",e.amount,e.reason or "?")
            end
            lkDisplay:SetText(table.concat(lines, "\n"))
        end)

        t:SetScript("OnShow", function()
            if not CfgDB() then return end
            local standings = MTR.DKPStandings()
            if #standings == 0 then
                lkDisplay:SetText("No DKP data yet.")
                return
            end
            local lines = {"— All Balances —", ""}
            for _, entry in ipairs(standings) do
                lines[#lines+1] = string.format("%-22s  %d pts", entry.name, entry.balance)
            end
            lkDisplay:SetText(table.concat(lines, "\n"))
        end)
    end

    -- =========================================================================
    -- AUCTION ADMIN TAB
    -- =========================================================================
    tabBuilders["Auction"] = function(t)
        if t.SetClipsChildren then t:SetClipsChildren(true) end
        MakeSep(t,"Open New Auction",-2)
        PlaceHelpText(t, HELP_COL_X, -18, HELP_COL_W, "Shift-click an item link, set optional minimum bid and timer, then open the auction. Timer 0 keeps it manual.")
        local l1=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        l1:SetPoint("TOPLEFT",t,"TOPLEFT",0,-36) l1:SetText("Item name / link  (Shift-click to fill):")
        mainWin._auctItemEB = MakeIn("AuctItem",t,560,0,-34)
        mainWin._auctItemEB:SetScript("OnMouseDown",function(self) self:SetFocus() end)
        MTR.RegisterLinkEditBox(mainWin._auctItemEB)
        local l2=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        l2:SetPoint("TOPLEFT",t,"TOPLEFT",0,-60) l2:SetText("Min bid (0=none):")
        mainWin._auctMinEB = MakeIn("AuctMin",t,70,120,-56) mainWin._auctMinEB:SetText("0")
        local l3=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        l3:SetPoint("TOPLEFT",t,"TOPLEFT",202,-60) l3:SetText("Timer (secs, 0=manual):")
        mainWin._auctTimerEB = MakeIn("AuctTimer",t,70,370,-56) mainWin._auctTimerEB:SetText("60")
        mainWin._ckAuctRW = MakeCK("AuctRW",t,"Raid Warning",450,-56)
        local openBtn = MakeBT(t,"Open Auction",140,28) openBtn:SetPoint("TOPLEFT",t,"TOPLEFT",630,-56)
        openBtn:SetScript("OnClick",function()
            local item=(mainWin._auctItemEB:GetText() or ""):match("^%s*(.-)%s*$")
            if item=="" then MPE("Enter an item name or paste a link.") return end
            local minB=tonumber(mainWin._auctMinEB:GetText() or "0") or 0
            local timer=tonumber(mainWin._auctTimerEB:GetText() or "0") or 0
            MTR.AuctionOpen(item,minB>0 and minB or nil,timer>0 and timer or nil,mainWin._ckAuctRW:GetChecked())
        end)
        MakeSep(t,"Auction History",-92)
        PlaceHelpText(t, HELP_COL_X, -106, HELP_COL_W, "Export to Guild, Officer, or Print. Refresh shows the latest 100 auction results.")
        local _,ahistEB = MakeRO(t,880,432,0,-124)
        mainWin._auctHistEB = ahistEB
        local aPrev=nil
        for i,ch in ipairs({"GUILD","OFFICER","PRINT"}) do
            local lbl=({"Guild","Officer","Print"})[i]
            local b=MakeBTStd(t,lbl,"SM")
            if aPrev then b:SetPoint("LEFT",aPrev,"RIGHT",4,0)
            else b:SetPoint("TOPLEFT",ahistEB:GetParent(),"BOTTOMLEFT",0,-4) end
            b:SetScript("OnClick",function() if CfgDB() then MTR.ExportHistory(MTR.FormatBidHistory(CfgDB().dkpBidLog),ch) end end)
            aPrev=b
        end
        local aRefBtn=MakeBTStd(t,"Refresh","SM") aRefBtn:SetPoint("LEFT",aPrev,"RIGHT",10,0)
        aRefBtn:SetScript("OnClick",function()
            if not CfgDB() then return end
            local lines={}
            for i=#(CfgDB().dkpBidLog or {}),math.max(1,#(CfgDB().dkpBidLog or {})-99),-1 do
                local e=CfgDB().dkpBidLog[i]
                if e.type=="auction" or not e.type then
                    lines[#lines+1]=string.format("[%s] [%s]  Winner: %s  %d pts",e.date or "?",e.item or "?",e.winner or "?",e.amount or 0)
                end
            end
            ahistEB:SetText(#lines>0 and table.concat(lines,"\n") or "No auction history yet.")
        end)
        t:SetScript("OnShow", function() aRefBtn:Click() end)
    end

    -- =========================================================================
    -- LOOT ROLL TAB
    -- =========================================================================
    tabBuilders["Roll"] = function(t)
        if t.SetClipsChildren then t:SetClipsChildren(true) end
        MakeSep(t,"Open New Roll",-2)
        PlaceHelpText(t, HELP_COL_X, -18, HELP_COL_W, "Set item, roll type, and timer, then open. If type is Custom, the custom type field is used. Timer 0 is manual.")
        local rl1=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        rl1:SetPoint("TOPLEFT",t,"TOPLEFT",0,-36) rl1:SetText("Item name / link  (Shift-click to fill):")
        mainWin._rollItemEB = MakeIn("RollItem",t,420,0,-34)
        mainWin._rollItemEB:SetScript("OnMouseDown",function(self) self:SetFocus() end)
        MTR.RegisterLinkEditBox(mainWin._rollItemEB)
        local rl2=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        rl2:SetPoint("TOPLEFT",t,"TOPLEFT",434,-18) rl2:SetText("Type:")
        local rtDD=CreateFrame("Frame","MekRollTypeDDv",t,"UIDropDownMenuTemplate")
        rtDD:SetPoint("TOPLEFT",t,"TOPLEFT",462,-28) UIDropDownMenu_SetWidth(rtDD,130)
        mainWin._rollTypeDD=rtDD
        local selRT="MS"
        UIDropDownMenu_Initialize(rtDD,function()
            for _,rt in ipairs(MTR.ROLL_TYPES or {"MS","OS","Transmog","Custom"}) do
                local info=UIDropDownMenu_CreateInfo() info.text=rt info.value=rt
                info.func=function() selRT=rt UIDropDownMenu_SetSelectedValue(rtDD,rt) end
                UIDropDownMenu_AddButton(info)
            end
        end)
        UIDropDownMenu_SetSelectedValue(rtDD,"MS")
        local rl3=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        rl3:SetPoint("TOPLEFT",t,"TOPLEFT",0,-60) rl3:SetText("Custom roll type:")
        mainWin._rollCustomEB = MakeIn("RollCustom",t,160,108,-56)
        local rl4=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        rl4:SetPoint("TOPLEFT",t,"TOPLEFT",280,-60) rl4:SetText("Timer (secs):")
        mainWin._rollTimerEB = MakeIn("RollTimer",t,70,370,-56) mainWin._rollTimerEB:SetText("60")
        mainWin._ckRollRW = MakeCK("RollRW",t,"Raid Warning",452,-56)
        local openRoll=MakeBT(t,"Open Roll",120,28) openRoll:SetPoint("TOPLEFT",t,"TOPLEFT",620,-56)
        openRoll:SetScript("OnClick",function()
            local item=(mainWin._rollItemEB:GetText() or ""):match("^%s*(.-)%s*$")
            if item=="" then MPE("Enter an item name or paste a link.") return end
            local rt=selRT
            if rt=="Custom" then rt=(mainWin._rollCustomEB:GetText() or ""):match("^%s*(.-)%s*$") if rt=="" then rt="Custom" end end
            local timer=tonumber(mainWin._rollTimerEB:GetText() or "0") or 0
            MTR.RollOpen(item,rt,timer>0 and timer or nil,mainWin._ckRollRW:GetChecked())
        end)
        MakeSep(t,"Roll History",-92)
        PlaceHelpText(t, HELP_COL_X, -106, HELP_COL_W, "Export to Guild, Officer, or Print. Refresh shows the latest 100 roll results.")
        local _,rhistEB = MakeRO(t,880,432,0,-124)
        mainWin._rollHistEB = rhistEB
        local rPrev=nil
        for i,ch in ipairs({"GUILD","OFFICER","PRINT"}) do
            local lbl=({"Guild","Officer","Print"})[i]
            local b=MakeBTStd(t,lbl,"SM")
            if rPrev then b:SetPoint("LEFT",rPrev,"RIGHT",4,0)
            else b:SetPoint("TOPLEFT",rhistEB:GetParent(),"BOTTOMLEFT",0,-4) end
            b:SetScript("OnClick",function()
                if CfgDB() then
                    local rollOnly={}
                    for _,e in ipairs(CfgDB().dkpBidLog or {}) do if e.type=="roll" then rollOnly[#rollOnly+1]=e end end
                    MTR.ExportHistory(MTR.FormatBidHistory(rollOnly),ch)
                end
            end)
            rPrev=b
        end
        local rRefBtn=MakeBTStd(t,"Refresh","SM") rRefBtn:SetPoint("LEFT",rPrev,"RIGHT",10,0)
        rRefBtn:SetScript("OnClick",function()
            if not CfgDB() then return end
            local lines={}
            for i=#(CfgDB().dkpBidLog or {}),math.max(1,#(CfgDB().dkpBidLog or {})-99),-1 do
                local e=CfgDB().dkpBidLog[i]
                if e.type=="roll" then
                    local winVal = "?"
                    if e.allRolls then
                        for _, r in ipairs(e.allRolls) do
                            if r.name == e.winner then winVal = tostring(r.value) break end
                        end
                    end
                    lines[#lines+1]=string.format("[%s] [%s] (%s)  Winner: %s (rolled %s)",e.date or "?",e.item or "?",e.rollType or "?",e.winner or "?",winVal)
                end
            end
            rhistEB:SetText(#lines>0 and table.concat(lines,"\n") or "No roll history.")
        end)
        t:SetScript("OnShow", function() rRefBtn:Click() end)
    end

    -- =========================================================================
    -- STANDINGS TAB  (lazy-built on first click)
    -- =========================================================================
    tabBuilders["Standings"] = function(t)
        local stSF=CreateFrame("ScrollFrame",nil,t,"UIPanelScrollFrameTemplate")
        stSF:SetPoint("TOPLEFT",t,"TOPLEFT",0,-4)
        stSF:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",-20,34)
        local stContent=CreateFrame("Frame",nil,stSF) stContent:SetSize(860,600)
        stSF:SetScrollChild(stContent)
        mainWin._standContent=stContent mainWin._standRows={}

        local refSt=MakeBTStd(t,"Refresh","MD") refSt:SetPoint("BOTTOMLEFT",t,"BOTTOMLEFT",0,6)
        refSt:SetScript("OnClick",function()
            if not CfgDB() then return end
            -- Hide and clear old row Frames (not FontStrings - they can't be re-hidden)
            for _,row in ipairs(mainWin._standRows) do
                if row.frame then row.frame:Hide() end
            end
            mainWin._standRows={}
            local standings=MTR.DKPStandings()
            local ROW_H = 24
            stContent:SetHeight(math.max(500,(#standings+1)*ROW_H+10))

            local hRow=CreateFrame("Frame",nil,stContent)
            hRow:SetSize(860,ROW_H)
            hRow:SetPoint("TOPLEFT",stContent,"TOPLEFT",4,0)
            local hBg=hRow:CreateTexture(nil,"BACKGROUND")
            hBg:SetAllPoints(hRow)
            hBg:SetColorTexture(0.16,0.06,0.06,0.90)

            local hRank=hRow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            hRank:SetPoint("LEFT",hRow,"LEFT",8,0)
            hRank:SetWidth(56) hRank:SetJustifyH("LEFT") hRank:SetText("Rank")
            local hName=hRow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            hName:SetPoint("LEFT",hRow,"LEFT",72,0)
            hName:SetWidth(520) hName:SetJustifyH("LEFT") hName:SetText("Player")
            local hPts=hRow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            hPts:SetPoint("LEFT",hRow,"LEFT",600,0)
            hPts:SetWidth(120) hPts:SetJustifyH("RIGHT") hPts:SetText("DKP")
            local hAct=hRow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            hAct:SetPoint("LEFT",hRow,"LEFT",732,0)
            hAct:SetWidth(80) hAct:SetJustifyH("LEFT") hAct:SetText("Actions")

            hRow:Show()
            mainWin._standRows[#mainWin._standRows+1]={frame=hRow}

            for i,entry in ipairs(standings) do
                local col=i==1 and "|cffd4af37" or (i<=3 and "|cffaaaaff" or "|cffffffff")
                -- Use a Frame wrapper so we can Hide() it cleanly on next refresh
                local rowFrame=CreateFrame("Frame",nil,stContent)
                rowFrame:SetSize(860,22)
                rowFrame:SetPoint("TOPLEFT",stContent,"TOPLEFT",4,-(i)*ROW_H)

                local rankFS=rowFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                rankFS:SetPoint("LEFT",rowFrame,"LEFT",8,0)
                rankFS:SetWidth(56) rankFS:SetJustifyH("LEFT")
                rankFS:SetText(string.format("%s%d.|r", col, i))

                local nameFS=rowFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                nameFS:SetPoint("LEFT",rowFrame,"LEFT",72,0)
                nameFS:SetWidth(520) nameFS:SetWordWrap(false) nameFS:SetJustifyH("LEFT")
                nameFS:SetText(string.format("%s%s|r", col, Trunc(entry.name, 28)))

                local ptsFS=rowFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                ptsFS:SetPoint("LEFT",rowFrame,"LEFT",600,0)
                ptsFS:SetWidth(120) ptsFS:SetJustifyH("RIGHT")
                ptsFS:SetText(string.format("%d pts", entry.balance or 0))

                local vBtn=MakeBTStd(rowFrame,"History","SM")
                vBtn:SetPoint("LEFT",rowFrame,"LEFT",724,0)
                local ename=entry.name
                vBtn:SetScript("OnClick",function()
                    local hist=CfgDB().dkpLedger[ename] and CfgDB().dkpLedger[ename].history or {}
                    if #hist==0 then MP(ename..": No history.") return end
                    MP(ename.." DKP history:")
                    for i2=#hist,math.max(1,#hist-14),-1 do
                        local e=hist[i2]
                        print(string.format("  [%s] %s%d (%s) Bal: %d",e.date,e.amount>=0 and "+" or "",e.amount,e.reason,e.balance))
                    end
                end)
                rowFrame:Show()
                mainWin._standRows[#mainWin._standRows+1]={frame=rowFrame}
            end
        end)
        local pubSt=MakeBTStd(t,"Publish","MD") pubSt:SetPoint("LEFT",refSt,"RIGHT",8,0)
        pubSt:SetScript("OnClick",function() if CfgDB() then MTR.DKPPublish(CfgDB().dkpPublishChannel) end end)

        -- Auto-refresh when the tab is shown
        t:SetScript("OnShow", function() refSt:Click() end)
    end

    -- =========================================================================
    -- INACTIVE TAB
    -- LEFT (x=0..409):  scan status + scrollable results + action buttons
    -- RIGHT (x=420..760): settings, whitelist, safe ranks, kick history
    -- A 1px divider at x=415 separates the two columns cleanly.
    -- =========================================================================
    tabBuilders["Inactive"] = function(t)

        -- ── Column geometry ────────────────────────────────────────────────
        local LX   = 2       -- left column x start
        local LW   = 388     -- left column usable width (scroll + rows)
        local DIV  = 410     -- divider x
        local RX   = 422     -- right column x start
        local RW   = 330     -- right column usable width

        -- ── Vertical divider ───────────────────────────────────────────────
        local divLine = t:CreateTexture(nil,"ARTWORK")
        divLine:SetSize(1, 540)
        divLine:SetPoint("TOPLEFT", t, "TOPLEFT", DIV, 4)
        divLine:SetColorTexture(0.3, 0.3, 0.3, 0.8)

        -- ════════════════════════════════════════════════════════════════════
        -- LEFT COLUMN — scan status, scrollable results, action buttons
        -- ════════════════════════════════════════════════════════════════════

        local statusLbl = t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        statusLbl:SetPoint("TOPLEFT", t, "TOPLEFT", LX, -2)
        statusLbl:SetWidth(LW) statusLbl:SetWordWrap(false)
        statusLbl:SetText("|cffaaaaaa Press Scan to populate.|r")
        mainWin._inactStatus = statusLbl

        -- Scroll frame — contained entirely within left column
        local rSF = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
        rSF:SetSize(LW - 16, 452)
        rSF:SetPoint("TOPLEFT", t, "TOPLEFT", LX, -18)
        local rContent = CreateFrame("Frame", nil, rSF)
        rContent:SetSize(LW - 18, 600)
        rSF:SetScrollChild(rContent)
        mainWin._inactResultsContent = rContent
        mainWin._inactScanRows = {}

        -- Scan button row — anchored below the scroll frame
        local scanBtn = MakeBTStd(t, "Scan", "MD")
        scanBtn:SetPoint("TOPLEFT", t, "TOPLEFT", LX, -478)
        scanBtn:SetScript("OnClick", function()
            statusLbl:SetText("|cffaaaaaa Scanning... please wait 5 seconds...|r")
            for _, row in ipairs(mainWin._inactScanRows) do
                if row.cb    then row.cb:Hide()    end
                if row.label then row.label:Hide() end
                if row.kBtn  then row.kBtn:Hide()  end
            end
            mainWin._inactScanRows = {}
            SetGuildRosterShowOffline(true)
            GuildRoster()
            MTR.After(5, function()
                local inactive = MTR.InactScan()
                if #inactive == 0 then
                    statusLbl:SetText("|cff00ff00No inactive members found.|r")
                    return
                end
                statusLbl:SetText(Trunc("|cffffaa00"..#inactive.." inactive found — check below|r", 60))
                rContent:SetHeight(math.max(452, #inactive * 28 + 10))
                for i, entry in ipairs(inactive) do
                    local y = -(i-1)*28
                    local cbName = "InR"..i
                    local cb = CreateFrame("CheckButton","MekCK_"..cbName, rContent,"UICheckButtonTemplate")
                    cb:SetPoint("TOPLEFT", rContent, "TOPLEFT", 2, y-2)
                    cb:SetSize(24,24) cb:SetChecked(false)
                    _G["MekCK_"..cbName.."Text"]:SetText("")
                    local dCol = entry.unknown and "|cffaaaaaa" or
                                 (entry.days >= entry.threshold*2 and "|cffff4444" or "|cffffaa00")
                    local daysStr = entry.unknown and "unseen" or MTR.FormatDays(entry.days)
                    local lbl = rContent:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
                    lbl:SetWidth(220) lbl:SetWordWrap(false)
                    lbl:SetText(string.format("|cffffff00%s|r [%s] %s%s|r",
                        Trunc(entry.name,16), Trunc(entry.rank,12), dCol, daysStr))
                    local kBtn = MakeBT(rContent,"Kick",52,20)
                    kBtn:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
                    if MTR.CanAccess and MTR.CanAccess("Inactive") then
                        local ename=entry.name local erank=entry.rank local edays=entry.days
                        kBtn:SetScript("OnClick",function()
                            StaticPopupDialogs["MEKTOWN_KICK_IND2"]={
                                text="Kick "..ename.."?\n["..erank.."] "..MTR.FormatDays(edays).." inactive.",
                                button1="Kick",button2="Cancel",
                                OnAccept=function()
                                    GuildUninvite(ename)
                                    table.insert(CfgDB().inactivityKickLog,{date=date("%Y-%m-%d %H:%M:%S"),player=ename,rank=erank,daysInactive=edays,kickedBy=MTR.playerName})
                                    cb:Hide() lbl:Hide() kBtn:Hide() MP("Kicked "..ename)
                                end,timeout=0,whileDead=true,hideOnEscape=true,
                            }
                            StaticPopup_Show("MEKTOWN_KICK_IND2")
                        end)
                    else kBtn:Hide() end
                    mainWin._inactScanRows[#mainWin._inactScanRows+1]={cb=cb,label=lbl,kBtn=kBtn,name=entry.name}
                end
            end)
        end)

        local wlSelBtn = MakeBTStd(t,"Whitelist Sel.","MD")
        wlSelBtn:SetPoint("LEFT", scanBtn, "RIGHT", 8, 0)
        wlSelBtn:SetScript("OnClick",function()
            local added=0
            local wl = (MTR.GetPathFromTable and MTR.GetPathFromTable(CfgDB(), "inactivityWhitelist", {})) or (CfgDB().inactivityWhitelist or {})
            for _,row in ipairs(mainWin._inactScanRows) do
                if row.cb and row.cb:GetChecked() then wl[row.name]=true added=added+1 end
            end
            if MTR.InactReplaceWhitelist then MTR.InactReplaceWhitelist(wl) else SaveTable("inactivityWhitelist", wl) end
            if added>0 then MP("Whitelisted "..added.." player(s).") mainWin._refreshInactiveConfig()
            else MP("No players selected.") end
        end)

        local kickSelBtn = MakeBTStd(t,"|cffff4444Kick Selected|r","MD")
        kickSelBtn:SetPoint("LEFT", wlSelBtn, "RIGHT", 8, 0)
        kickSelBtn:SetScript("OnClick",function()
            if not (MTR.CanAccess and MTR.CanAccess("Inactive")) then MPE("No permission.") return end
            local toKick={}
            for _,row in ipairs(mainWin._inactScanRows) do
                if row.cb and row.cb:GetChecked() then toKick[#toKick+1]=row end
            end
            if #toKick==0 then MP("No players selected.") return end
            StaticPopupDialogs["MEKTOWN_KICK_SEL2"]={
                text="Kick "..#toKick.." selected players?\nCannot be undone.",
                button1="Yes",button2="Cancel",
                OnAccept=function()
                    for _,row in ipairs(toKick) do
                        GuildUninvite(row.name)
                        table.insert(CfgDB().inactivityKickLog,{date=date("%Y-%m-%d %H:%M:%S"),player=row.name,rank="?",daysInactive=0,kickedBy=MTR.playerName})
                        if row.cb    then row.cb:Hide()    end
                        if row.label then row.label:Hide() end
                        if row.kBtn  then row.kBtn:Hide()  end
                    end MP("Kicked "..#toKick.." players.")
                end,timeout=0,whileDead=true,hideOnEscape=true,
            }
            StaticPopup_Show("MEKTOWN_KICK_SEL2")
        end)

        -- ════════════════════════════════════════════════════════════════════
        -- RIGHT COLUMN — settings, whitelist, safe ranks, kick history
        -- Everything is anchored to RX so nothing can cross the divider.
        -- ════════════════════════════════════════════════════════════════════

        local ry = 0  -- running y offset for right column, incremented as we go

        -- ── Settings ────────────────────────────────────────────────────────
        local inactHdr = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        inactHdr:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        inactHdr:SetText("|cffaaaaaa— Inactivity Settings —|r")
        ry = ry - 22

        mainWin._ckInactEnable = MakeCK("InactEn", t, "Enable inactivity scanning", RX, ry)
        if Settings then Settings.BindCheck(mainWin, mainWin._ckInactEnable, "inactivityEnabled") end
        mainWin._ckInactEnable:SetScript("OnClick",function(s) SaveBool("inactivityEnabled", s:GetChecked()) end)
        ry = ry - 28

        local li1 = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        li1:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        li1:SetText("Default threshold (days):")
        ry = ry - 16
        mainWin._slInactDays = MakeSL("InactDays", t, RW, RX, ry, 7, 180, 7)
        if Settings then Settings.BindSlider(mainWin, mainWin._slInactDays, "inactivityDefaultDays", {default=28, step=7}) end
        mainWin._slInactDays:SetScript("OnValueChanged",function(s,v)
            local r=math.floor(v/7)*7
            _G["MekSLv_InactDaysText"]:SetText(r.."d")
            SaveValue("inactivityDefaultDays", r)
        end)
        ry = ry - 34

        -- ── Whitelist ────────────────────────────────────────────────────────
        local wlSep = t:CreateTexture(nil,"ARTWORK")
        wlSep:SetColorTexture(0.2,0.2,0.35,0.7) wlSep:SetHeight(1)
        wlSep:SetPoint("TOPLEFT",  t, "TOPLEFT",  RX,  ry)
        wlSep:SetPoint("TOPRIGHT", t, "TOPRIGHT", -4,  ry)
        ry = ry - 4
        local wlHdr = t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        wlHdr:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        wlHdr:SetText("|cffd4af37Whitelist|r  |cffaaaaaa(never flagged as inactive)|r")
        ry = ry - 16

        local wlDisplay = t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        wlDisplay:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        wlDisplay:SetWidth(RW) wlDisplay:SetWordWrap(false)
        wlDisplay:SetText("Loading...")
        mainWin._inactWlDisplay = wlDisplay
        ry = ry - 18

        local li2 = t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        li2:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry) li2:SetText("Add player:")
        mainWin._inactAddWlEB = MakeIn("InactAddWl", t, 160, RX+74, ry+4)
        local addWlBtn = MakeBT(t,"Add",60,22)
        addWlBtn:SetPoint("LEFT", mainWin._inactAddWlEB, "RIGHT", 4, 0)
        addWlBtn:SetScript("OnClick",function()
            local n=(mainWin._inactAddWlEB:GetText() or ""):match("^%s*(.-)%s*$")
            if n=="" then return end
            if MTR.InactSetWhitelist then MTR.InactSetWhitelist(n, true) else
                local wl = (MTR.GetPathFromTable and MTR.GetPathFromTable(CfgDB(), "inactivityWhitelist", {})) or (CfgDB().inactivityWhitelist or {})
                wl[n]=true
                SaveTable("inactivityWhitelist", wl)
            end
            mainWin._inactAddWlEB:SetText("")
            mainWin._refreshInactiveConfig() MP("Whitelisted: "..n)
        end)
        ry = ry - 26

        local wlEditBtn = MakeBTStd(t,"Edit Whitelist","MD")
        wlEditBtn:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        wlEditBtn:SetScript("OnClick",function()
            local wl={} for n in pairs(CfgDB().inactivityWhitelist) do wl[#wl+1]=n end table.sort(wl)
            OpenEP("Edit Whitelist",table.concat(wl,"\n"),function(text)
                local newWhitelist={}
                for line in text:gmatch("([^\n]+)") do
                    local s=line:match("^%s*(.-)%s*$") if s~="" then newWhitelist[s]=true end
                end
                if MTR.InactReplaceWhitelist then MTR.InactReplaceWhitelist(newWhitelist) else SaveTable("inactivityWhitelist", newWhitelist) end
                mainWin._refreshInactiveConfig() MP("Whitelist updated.")
            end)
        end)
        ry = ry - 34

        -- ── Safe Ranks ───────────────────────────────────────────────────────
        local srSep = t:CreateTexture(nil,"ARTWORK")
        srSep:SetColorTexture(0.2,0.2,0.35,0.7) srSep:SetHeight(1)
        srSep:SetPoint("TOPLEFT",  t, "TOPLEFT",  RX, ry)
        srSep:SetPoint("TOPRIGHT", t, "TOPRIGHT", -4, ry)
        ry = ry - 4
        local srHdr = t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        srHdr:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        srHdr:SetText("|cffd4af37Safe Ranks|r  |cffaaaaaa(exempt from inactivity scans)|r")
        ry = ry - 16

        local srDisplay = t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
        srDisplay:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        srDisplay:SetWidth(RW) srDisplay:SetWordWrap(false)
        srDisplay:SetText("Loading...")
        mainWin._inactSrDisplay = srDisplay
        ry = ry - 18

        local srEditBtn = MakeBTStd(t,"Edit Safe Ranks","MD")
        srEditBtn:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        srEditBtn:SetScript("OnClick",function()
            OpenEP("Edit Safe Ranks",table.concat(CfgDB().inactivitySafeRanks or {},"\n"),function(text)
                local newSafeRanks={}
                for line in text:gmatch("([^\n]+)") do
                    local s=line:match("^%s*(.-)%s*$")
                    if s~="" then newSafeRanks[#newSafeRanks+1]=s end
                end
                SaveTable("inactivitySafeRanks", newSafeRanks)
                mainWin._refreshInactiveConfig() MP("Safe ranks updated.")
            end)
        end)
        ry = ry - 34

        -- ── Kick History ─────────────────────────────────────────────────────
        local khSep = t:CreateTexture(nil,"ARTWORK")
        khSep:SetColorTexture(0.2,0.2,0.35,0.7) khSep:SetHeight(1)
        khSep:SetPoint("TOPLEFT",  t, "TOPLEFT",  RX, ry)
        khSep:SetPoint("TOPRIGHT", t, "TOPRIGHT", -4, ry)
        ry = ry - 4
        local khHdr = t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        khHdr:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
        khHdr:SetText("|cffd4af37Kick History|r")
        ry = ry - 14

        -- Read-only edit box for kick log, height fills remaining space
        local khHeight = 540 + ry - 30  -- remaining vertical space minus export buttons
        local _, khEB = MakeRO(t, RW, math.max(80, khHeight), RX, ry)
        mainWin._kickHistEB = khEB
        ry = ry - math.max(80, khHeight) - 6

        -- Export buttons
        local prevBtnK = nil
        for i, ch in ipairs({"GUILD","OFFICER","PRINT"}) do
            local lbl = ({"Guild","Officer","Print"})[i]
            local b = MakeBT(t, lbl, 80, 22)
            if prevBtnK then
                b:SetPoint("LEFT", prevBtnK, "RIGHT", 4, 0)
            else
                b:SetPoint("TOPLEFT", t, "TOPLEFT", RX, ry)
            end
            b:SetScript("OnClick",function()
                if CfgDB() then MTR.ExportHistory(MTR.FormatKickHistory(CfgDB().inactivityKickLog), ch) end
            end)
            prevBtnK = b
        end

        -- ── Refresh helper ────────────────────────────────────────────────────
        mainWin._refreshInactiveConfig = function()
            if not CfgDB() then return end
            local wl={} for n in pairs(CfgDB().inactivityWhitelist) do wl[#wl+1]=n end table.sort(wl)
            wlDisplay:SetText(Trunc(#wl>0 and (#wl.." players: "..table.concat(wl,", ")) or "None", 55))
            srDisplay:SetText(Trunc(table.concat(CfgDB().inactivitySafeRanks or {},", "), 55))
            local kl={}
            for _,e in ipairs(CfgDB().inactivityKickLog or {}) do
                kl[#kl+1]=string.format("[%s] %s [%s] %s by %s",
                    e.date or "?",e.player or "?",e.rank or "?",
                    MTR.FormatDays(e.daysInactive or 0),e.kickedBy or "?")
            end
            khEB:SetText(#kl>0 and table.concat(kl,"\n") or "No kicks logged.")
        end
        MTR.RefreshInactiveConfig = mainWin._refreshInactiveConfig
    end


    -- =========================================================================
    -- GROUP RADAR TAB  — compact layout, all settings visible without scroll
    -- =========================================================================
    tabBuilders["Group Radar"] = function(t)
        -- local GR = MTR.GroupRadar -- unused

        -- ── Layout constants ──────────────────────────────────────────────────
        -- Tab frame is ~880px wide.  Two equal alert columns with a divider.
        local CA  = 0      -- Text Alerts column x
        local CB  = 450    -- Popup Alerts column x
        -- local CW  = 420    -- each column usable width (unused)
        local FW  = 870    -- full-width filter inputs

        -- ── Section separator helper ──────────────────────────────────────────
        local function Sec(y, text)
            local line = t:CreateTexture(nil,"ARTWORK")
            line:SetColorTexture(0.25,0.25,0.42,0.8) line:SetHeight(1)
            line:SetPoint("TOPLEFT",  t,"TOPLEFT",  0, y)
            line:SetPoint("TOPRIGHT", t,"TOPRIGHT", 0, y)
            if text then
                local lbl = t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
                lbl:SetPoint("TOPLEFT",t,"TOPLEFT",4,y+10)
                lbl:SetText(text)
            end
        end

        -- ── Checkbox helper ───────────────────────────────────────────────────
        -- Stores explicit true/false (not nil) so Cfg() never overwrites with defaults.
        local grAllCKs = {}
        local function CKAt(name,label,x,y,cfgKey)
            local ck=CreateFrame("CheckButton","MekCK_"..name,t,"UICheckButtonTemplate")
            ck:SetPoint("TOPLEFT",t,"TOPLEFT",x+2,y)
            ck:SetSize(24,24)
            _G["MekCK_"..name.."Text"]:SetText(label)
            ck:SetScript("OnClick",function(s)
                SaveBool("groupRadarConfig."..cfgKey, s:GetChecked())
            end)
            grAllCKs[#grAllCKs+1]={ck=ck,key=cfgKey}
            return ck
        end

        -- ┌─────────────────────────────────────────────────────────────────┐
        -- │  SECTION 1 — Alert types (two columns, y = 0 → -182)           │
        -- └─────────────────────────────────────────────────────────────────┘
        -- Vertical divider between the two alert columns
        local vdiv = t:CreateTexture(nil,"ARTWORK")
        vdiv:SetColorTexture(0.3,0.3,0.3,0.5) vdiv:SetSize(1,172)
        vdiv:SetPoint("TOPLEFT",t,"TOPLEFT",440,-10)

        -- Column A header
        Sec(0,"|cffd4af37TEXT Alerts|r  |cffaaaaaa(prints to chat)|r")
        -- Column B header
        local hdrB=t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        hdrB:SetPoint("TOPLEFT",t,"TOPLEFT",CB+4,10)
        hdrB:SetText("|cffd4af37POPUP Alerts|r  |cffaaaaaa(floating window)|r")

        -- 6 alert rows at 28px step starting at y=-16
        local alertRows = {
            {"Dps",  "LFM DPS",      "textAlertLfmDps",     "alertLfmDps"},
            {"Tank", "LFM Tank",     "textAlertLfmTank",    "alertLfmTank"},
            {"Heal", "LFM Healer",   "textAlertLfmHeal",    "alertLfmHeal"},
            {"MsLvl","MS Leveling",  "textAlertMsLeveling", "alertMsLeveling"},
            {"MsGld","MS Gold",      "textAlertMsGold",     "alertMsGold"},
            {"Bc",   "BC / World",   "textAlertBc",         "alertBc"},
        }
        for i,row in ipairs(alertRows) do
            local y = -(16 + (i-1)*28)
            CKAt("grTxt"..row[1], row[2], CA, y, row[3])
            CKAt("grPop"..row[1], row[2], CB, y, row[4])
        end
        -- Last row bottom: -(16+5*28) = -156, checkbox 24px → bottom at -180

        -- ┌─────────────────────────────────────────────────────────────────┐
        -- │  SECTION 2 — Suppression (horizontal row, y = -188 → -224)    │
        -- └─────────────────────────────────────────────────────────────────┘
        Sec(-188,"|cffaaaaaa Suppress popups when:|r")
        -- 4 checkboxes across full width at 220px intervals
        local supRows = {
            {"SupGrp",  "In a group",          "doNotAlertInGroup"},
            {"SupCbt",  "In combat",            "doNotAlertInCombat"},
            {"SupInst", "In instance/dungeon",  "dontAlertInInstance"},
            {"SupSil",  "Silent (no popups)",   "silentNotifications"},
        }
        for i,row in ipairs(supRows) do
            CKAt(row[1],row[2],(i-1)*220,-204,row[3])
        end

        -- ┌─────────────────────────────────────────────────────────────────┐
        -- │  SECTION 3 — Message filters (y = -238 → -320)                │
        -- └─────────────────────────────────────────────────────────────────┘
        Sec(-238,"|cffaaaaaa Message Filters|r")

        local lbl1=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl1:SetPoint("TOPLEFT",t,"TOPLEFT",4,-252) lbl1:SetText("Must contain (blank = any):")
        local mustEB=MakeIn("GRMustContain",t,FW,4,-268)
        if Settings then Settings.BindEdit(mainWin, mustEB, "groupRadarConfig.messageMustContain") end
        mustEB:SetScript("OnTextChanged",function(s) SaveValue("groupRadarConfig.messageMustContain", s:GetText() or "") end)

        local lbl2=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl2:SetPoint("TOPLEFT",t,"TOPLEFT",4,-298) lbl2:SetText("Must NOT contain (comma-separated):")
        local mustNotEB=MakeIn("GRMustNotContain",t,FW,4,-314)
        if Settings then Settings.BindEdit(mainWin, mustNotEB, "groupRadarConfig.messageMustNotContain") end
        mustNotEB:SetScript("OnTextChanged",function(s) SaveValue("groupRadarConfig.messageMustNotContain", s:GetText() or "") end)

        -- ┌─────────────────────────────────────────────────────────────────┐
        -- │  SECTION 4 — Timing sliders (y = -348 → -400)                 │
        -- └─────────────────────────────────────────────────────────────────┘
        Sec(-348,"|cffaaaaaa Timing|r")

        local lbl3=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl3:SetPoint("TOPLEFT",t,"TOPLEFT",4,-362) lbl3:SetText("Alert cooldown per player (s):")
        local spamSL=MakeSL("GRSpamCD",t,390,4,-380,30,600,30)
        if Settings then Settings.BindSlider(mainWin, spamSL, "groupRadarConfig.dontDisplaySpammers", {default=180, step=30}) end
        spamSL:SetScript("OnValueChanged",function(s,v)
            local r=math.floor(v/30)*30
            _G["MekSLv_GRSpamCDText"]:SetText(r.."s")
            SaveValue("groupRadarConfig.dontDisplaySpammers", r)
        end)

        local lbl4=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl4:SetPoint("TOPLEFT",t,"TOPLEFT",454,-362) lbl4:SetText("Hide recruiter from window after (s):")
        local expirySL=MakeSL("GRExpiry",t,390,454,-380,60,600,60)
        if Settings then Settings.BindSlider(mainWin, expirySL, "groupRadarConfig.hideFromDetailAfter", {default=180, step=60}) end
        expirySL:SetScript("OnValueChanged",function(s,v)
            local r=math.floor(v/60)*60
            _G["MekSLv_GRExpiryText"]:SetText(r.."s")
            SaveValue("groupRadarConfig.hideFromDetailAfter", r)
        end)

        -- ┌─────────────────────────────────────────────────────────────────┐
        -- │  SECTION 5 — Action buttons (y = -418 → -454)                 │
        -- └─────────────────────────────────────────────────────────────────┘
        Sec(-416,"|cffaaaaaa Actions|r")

        local openBtn=MakeBTStd(t,"Open Group Radar","LG")
        openBtn:SetPoint("TOPLEFT",t,"TOPLEFT",4,-432)
        openBtn:SetScript("OnClick",function()
            if MTR.OpenGroupRadar then MTR.OpenGroupRadar() end
        end)
        if MTR.AttachTooltip then MTR.AttachTooltip(openBtn, "Open Group Radar", "Opens the live recruiter list detected by Group Radar.") end

        local lfgBtn=MakeBTStd(t,"Post LFG","LG")
        lfgBtn:SetPoint("LEFT",openBtn,"RIGHT",10,0)
        lfgBtn:SetScript("OnClick",function()
            if MTR.OpenFindGroup then MTR.OpenFindGroup() end
        end)
        if MTR.AttachTooltip then MTR.AttachTooltip(lfgBtn, "Post LFG", "Opens the Group Radar LFG posting window.") end

        -- ── Refresh helper ────────────────────────────────────────────────────
        mainWin._refreshGroupRadarTab = function()
            if not CfgDB() or not CfgDB().groupRadarConfig then return end
            local cfg=CfgDB().groupRadarConfig
            for _,entry in ipairs(grAllCKs) do
                if entry.ck then
                    entry.ck:SetChecked(cfg[entry.key]==true)
                end
            end
            mustEB:SetText(cfg.messageMustContain or "")
            mustNotEB:SetText(cfg.messageMustNotContain or "")
            if cfg.dontDisplaySpammers then spamSL:SetValue(cfg.dontDisplaySpammers) end
            if cfg.hideFromDetailAfter then expirySL:SetValue(cfg.hideFromDetailAfter) end
        end
    end

    -- Build the default tab (Recruit) immediately so Refresh() works on first open
    tabBuilders["Recruit"](tabFrames["Recruit"])
    tabBuilt["Recruit"] = true

    -- =========================================================================
    -- REFRESH: populate all widgets from current config source
    -- =========================================================================

    local function CommitWidgetState()
        SnapshotAllConfigWidgets()
        if MTR.FlushActiveProfile then MTR.FlushActiveProfile() end
    end

    MTR.CommitConfigState = CommitWidgetState

    function mainWin:Refresh()
        if not MTR.initialized or not MTR.db then return end
        mainWin._refreshing = true
        if Settings and Settings.LoadWindow then Settings.LoadWindow(mainWin) end

        local cfg = CfgDB()

        -- Recruit tab ─────────────────────────────────────────
        if mainWin._kwDisplay then mainWin._kwDisplay:SetText(MTR.Trunc((#(cfg.keywords or {})).." keywords", 50)) end
        if mainWin._wtDisplay then mainWin._wtDisplay:SetText(MTR.Trunc((#(cfg.whisperTemplates or {})).." templates", 50)) end
        if mainWin._adDisplay then mainWin._adDisplay:SetText(MTR.Trunc((#(cfg.adPatterns or {})).." phrases", 50)) end

        if mainWin._recruitHistEB then
            local hl={}
            local rh = cfg.recruitHistory or {}
            for i = #rh, math.max(1, #rh - 7), -1 do
                local e = rh[i]
                hl[#hl+1] = string.format("[%s]  %-18s  %s", e.time or "?", e.recruit or e.player or "?", e.sentBy or "?")
            end
            mainWin._recruitHistEB:SetText(#hl>0 and table.concat(hl,"\n") or "No history yet.")
        end

        local ck_rcEn = _G["MekCK_RcEnable"]  if ck_rcEn  then ck_rcEn:SetChecked(cfg.enabled ~= false) end
        local ck_rcGld = _G["MekCK_RcGuild"]   if ck_rcGld  then ck_rcGld:SetChecked(cfg.requireGuildWord ~= false) end
        local ck_rcSnd = _G["MekCK_RcSound"]   if ck_rcSnd  then ck_rcSnd:SetChecked(cfg.soundAlert ~= false) end
        local ck_rcMini = _G["MekCK_RcMinimap"] if ck_rcMini then ck_rcMini:SetChecked(cfg.minimapButton ~= false) end
        local ck_rcDbg = _G["MekCK_RcDebug"]   if ck_rcDbg  then ck_rcDbg:SetChecked(cfg.enableDebug == true) end
        local ck_rcIgn = _G["MekCK_RcIgnAds"]  if ck_rcIgn  then ck_rcIgn:SetChecked(cfg.ignoreAds ~= false) end
        local eb_addReq = _G["MekIn_AddReq"]    if eb_addReq then eb_addReq:SetText(cfg.additionalRequired or "") end
        if mainWin._slIgnore then mainWin._slIgnore:SetValue(cfg.ignoreDuration or 300) end

        if mainWin._chanChecks then
            for _,ck in ipairs(mainWin._chanChecks) do
                ck:SetChecked((cfg.scanChannels or {})[ck.channel]==true)
            end
        end

        -- Guild Ads refresh ─────────────────────────────────────────
        if mainWin._adPostDisplay then
            local msgs = cfg.guildAdMessages or {}
            local en = 0
            for _, m in ipairs(msgs) do if m.enabled ~= false and m.text ~= "" then en=en+1 end end
            mainWin._adPostDisplay:SetText(#msgs .. " messages (" .. en .. " enabled)")
        end
        if mainWin._adToggleBtn and MTR.GuildAds then
            mainWin._adToggleBtn:SetText(MTR.GuildAds.active and "|cffff4444Stop Posting|r" or "|cff00ff00Start Posting|r")
        end
        if mainWin._adChanEB and cfg.guildAdConfig then
            mainWin._adChanEB:SetText(tostring(cfg.guildAdConfig.channelNum or 1))
        end
        if mainWin._adIntBtns and mainWin._adIntervals and cfg.guildAdConfig then
            local curMins = cfg.guildAdConfig.intervalMins or 5
            for i, btn in ipairs(mainWin._adIntBtns) do
                if mainWin._adIntervals[i] == curMins then btn:LockHighlight() else btn:UnlockHighlight() end
            end
        end
        if MTR.GuildAds and mainWin._adStatusLbl then
            MTR.GuildAds.statusLabel = mainWin._adStatusLbl
            if MTR.GuildAds.UpdateStatusLabel then MTR.GuildAds.UpdateStatusLabel() end
        end

        -- Guild Utils / Standings ─────────────────────────────────────────────
        if mainWin._refreshGuildTab then mainWin._refreshGuildTab() end
        if mainWin._standRows and mainWin._standContent then
            -- Note: Standings usually auto-refreshes OnShow, but we guard it here
        end

        -- DKP tab ──────────────────────────────────────────────────────
        local ck_dkpEn = _G["MekCK_DKPEn"]   if ck_dkpEn   then ck_dkpEn:SetChecked(cfg.dkpEnabled ~= false) end
        if mainWin._slDKPRaid then mainWin._slDKPRaid:SetValue(cfg.dkpPerRaid or 10) end
        if mainWin._slDKPBoss then mainWin._slDKPBoss:SetValue(cfg.dkpPerBoss or 5) end
        local ck_attAuto = _G["MekCK_AttAuto"] if ck_attAuto then ck_attAuto:SetChecked(cfg.attendanceAutoSnapshot ~= false) end
        if mainWin._dkpChanDD then UIDropDownMenu_SetSelectedValue(mainWin._dkpChanDD, cfg.dkpPublishChannel or "GUILD") end

        -- Inactive tab ─────────────────────────────────────────────────
        local ck_inactEn = _G["MekCK_InactEn"] if ck_inactEn then ck_inactEn:SetChecked(cfg.inactivityEnabled ~= false) end
        if mainWin._slInactDays then mainWin._slInactDays:SetValue(cfg.inactivityDefaultDays or 28) end
        if mainWin._refreshInactiveConfig then mainWin._refreshInactiveConfig() end

        -- Group Radar tab ──────────────────────────────────────────────
        if mainWin._refreshGroupRadarTab then mainWin._refreshGroupRadarTab() end

        -- Common Widgets ──────────────────────────────────────────────
        if mainWin._rebuildProfileDD then mainWin._rebuildProfileDD() end
        if mainWin._refreshOfficerRankUI then mainWin._refreshOfficerRankUI() end
        if mainWin._updateTabAccess then mainWin._updateTabAccess() end

        mainWin._refreshing = false
    end

    local function ApplyConfigDraft(stayOpen)
        if not mainWin then return end
        if CommitGuildTabState then CommitGuildTabState() end
        SnapshotAllConfigWidgets()
        if MTR.FlushActiveProfile then MTR.FlushActiveProfile() end
        mainWin._originalConfig = MTR.DeepCopy(CfgDB() or {})
        mainWin._dirty = false
        if mainWin._cfgStatus then mainWin._cfgStatus:SetText("|cff00ff00Settings saved.|r") end
        if MTR and MTR.MP then MTR.MP("Settings saved.") end
        if stayOpen then mainWin:Refresh() end
    end

    local saveBtn = CreateFrame("Button", nil, mainWin, "UIPanelButtonTemplate")
    saveBtn:SetSize(90, 24)
    saveBtn:SetPoint("BOTTOMRIGHT", mainWin, "BOTTOMRIGHT", -16, 12)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", function()
        ApplyConfigDraft(true)
    end)

    local cancelBtn = CreateFrame("Button", nil, mainWin, "UIPanelButtonTemplate")
    cancelBtn:SetSize(90, 24)
    cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        if mainWin._dirty and type(mainWin._originalConfig) == "table" and MTR.ReplaceActiveProfile then
            MTR.ReplaceActiveProfile(MTR.DeepCopy(mainWin._originalConfig))
            if MTR.FlushActiveProfile then MTR.FlushActiveProfile() end
        end
        mainWin._dirty = false
        mainWin:Hide()
    end)

    local cfgStatus = mainWin:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cfgStatus:SetPoint("BOTTOMLEFT", mainWin, "BOTTOMLEFT", 16, 18)
    cfgStatus:SetText("|cffaaaaaaClick Save to commit settings. Cancel restores values from when you opened this window.|r")
    mainWin._cfgStatus = cfgStatus

    mainWin:SetScript("OnHide", function()
        mainWin._dirty = false
        mainWin._originalConfig = nil
        mainWin._refreshing = false
        if mainWin._cfgStatus then
            mainWin._cfgStatus:SetText("|cffaaaaaaClick Save to commit settings. Cancel restores values from when you opened this window.|r")
        end
    end)

    ShowTab("Recruit")
    MTR.mainWin = mainWin
end

-- ============================================================================
-- RIGHT-CLICK BLACKLIST MENU ENTRY
-- ============================================================================
-- UnitPopup_ShowMenu is called by WoW not just on initial open but AGAIN each
-- time the cursor moves over any entry in the dropdown (sub-menu hover refresh).
-- Without a guard, UIDropDownMenu_AddButton fires multiple times per session,
-- adding a duplicate "Blacklist" entry on every hover.
--
-- Fix: stamp a unique session key on the dropdownMenu frame the first time we
-- add our button. If the key already matches this open session, skip.
-- The key is cleared when the dropdown closes (DROPDOWN_LIST_CLOSED or the
-- frame's OnHide), so the button is re-added correctly next time it opens.
-- ============================================================================
local _origUPS = UnitPopup_ShowMenu
function UnitPopup_ShowMenu(dropdownMenu,which,unit,name,...)
    _origUPS(dropdownMenu,which,unit,name,...)
    if not MTR.initialized or not MTR.db then return end
    if which=="SELF" or which=="PARTY" or which=="RAID" or which=="PLAYER" then
        local tgt=(unit and UnitName(unit)) or name
        if not tgt then return end

        -- Guard: only add our button ONCE per menu open.
        -- WoW re-calls ShowMenu on every hover; the stamp prevents duplicates.
        local stamp = "mtr_bl_" .. tostring(tgt)
        if dropdownMenu._mtrBlStamp == stamp then return end
        dropdownMenu._mtrBlStamp = stamp

        local info=UIDropDownMenu_CreateInfo()
        if MTR.db.blacklist[tgt] then
            info.text="|cffff9900MekTown|r Unblacklist"
            info.func=function() MTR.db.blacklist[tgt]=nil MP("Removed "..tgt.." from blacklist.") end
        else
            info.text="|cffff9900MekTown|r Blacklist"
            info.func=function() MTR.db.blacklist[tgt]=true MP("Blacklisted "..tgt) end
        end
        UIDropDownMenu_AddButton(info)
    end
end

-- Clear the stamp when any dropdown closes so the next right-click works fresh.
local _blCloseFrame = CreateFrame("Frame")
_blCloseFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
_blCloseFrame:SetScript("OnEvent", function()
    -- Belt-and-braces: clear stamps on all known dropdown frames
    if DropDownList1 then DropDownList1._mtrBlStamp = nil end
    if DropDownList2 then DropDownList2._mtrBlStamp = nil end
end)
-- Also hook CloseDropDownMenus so the stamp resets immediately on close
local _origCDDM = CloseDropDownMenus
function CloseDropDownMenus(...)
    if DropDownList1 then DropDownList1._mtrBlStamp = nil end
    if DropDownList2 then DropDownList2._mtrBlStamp = nil end
    return _origCDDM(...)
end

-- ============================================================================
-- PUBLIC ENTRY POINT
-- ============================================================================
function MTR.OpenConfig()
    if IsInGuild() then GuildRoster() end
    if MTR.CheckIsGM then MTR.isGM = MTR.CheckIsGM() end
    if MTR.CheckIsOfficer then MTR.isOfficer = MTR.CheckIsOfficer() end
    if not (MTR.CanAccess and MTR.CanAccess("Recruit")) then
        if MTR.OpenMemberWindow then
            MTR.OpenMemberWindow()
        end
        return
    end

    CreateMainWindow()
    if mainWin:IsShown() then mainWin:Hide() return end
    mainWin._originalConfig = MTR.DeepCopy(MTR.db or {})
    mainWin._dirty = false
    if mainWin._cfgStatus then mainWin._cfgStatus:SetText("|cffaaaaaaClick Save to commit settings. Cancel restores values from when you opened this window.|r") end
    if MTR.initialized and CfgDB() then mainWin:Refresh() end

    if mainWin._updateTabAccess then mainWin._updateTabAccess() end

    if MTR.vaultWin and MTR.vaultWin:IsShown() then MTR.vaultWin:Hide() end

    if mainWin._showWS then
        if (MTR.CanAccess and MTR.CanAccess("Recruit")) then
            mainWin._showWS("Guild", "Recruit")
        else
            mainWin._showWS("Utility", "Group Radar")
        end
    end
    mainWin:Show()
end
