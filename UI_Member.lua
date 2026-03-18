-- ============================================================================
-- UI_Member.lua  v8.1
-- Member panel for regular guild members (non-officer / non-GM).
-- Member-facing tabs only: Group Radar / Loot / DKP / Standings.
-- No guild-management controls of any kind.
-- ============================================================================
local MTR = MekTownRecruit

local memberWin = nil

local function SafeInvoke(func, label)
    if type(func) ~= "function" then
        if MTR.MPE then MTR.MPE((label or "Action").." is not available.") end
        return false
    end
    local ok, err = pcall(func)
    if not ok then
        if geterrorhandler then
            geterrorhandler()(err)
        elseif MTR.MPE then
            MTR.MPE(err)
        end
        if MTR.MPE then MTR.MPE((label or "Action").." failed to open.") end
        return false
    end
    return true
end

function MTR.OpenMemberWindow()
    if not memberWin then
        memberWin = CreateFrame("Frame","MekTownMemberWindow",UIParent)
        memberWin:SetSize(820,580)
        memberWin:SetPoint("CENTER")
        memberWin:SetFrameStrata("MEDIUM")
        memberWin:SetBackdrop({
            bgFile   = "",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=false, tileSize=0, edgeSize=32,
            insets={left=8,right=8,top=8,bottom=8},
        })
        memberWin:SetBackdropColor(0,0,0,0)
        do local bg = memberWin:CreateTexture(nil,"BACKGROUND")
            bg:SetTexture("Interface\\Buttons\\WHITE8x8")
            bg:SetAllPoints(memberWin)
            bg:SetVertexColor(0.04,0.01,0.01,0.97)
        end
        memberWin:EnableMouse(true)
        memberWin:SetMovable(true)
        memberWin:RegisterForDrag("LeftButton")
        memberWin:SetScript("OnDragStart",memberWin.StartMoving)
        memberWin:SetScript("OnDragStop", memberWin.StopMovingOrSizing)
        memberWin:Hide()

        local xBtn=CreateFrame("Button",nil,memberWin,"UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT",memberWin,"TOPRIGHT",-4,-4)
        xBtn:SetScript("OnClick",function() memberWin:Hide() end)

        local hdr=memberWin:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        hdr:SetPoint("TOPLEFT",memberWin,"TOPLEFT",16,-16)
        hdr:SetText("|cffff2020MekTown Choppa'z|r  |cffd4af37Member Panel|r  |cffaaaaaa v"..(MTR.VERSION or "8").."|r")

        local sep=memberWin:CreateTexture(nil,"ARTWORK")
        sep:SetColorTexture(0.3,0.3,0.5,0.5)
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT",memberWin,"TOPLEFT",10,-40)
        sep:SetPoint("TOPRIGHT",memberWin,"TOPRIGHT",-10,-40)

        local TAB_NAMES = {"Group Radar","Loot","DKP","Standings"}
        local tabBtns, tabFrames, tabBuilt, tabBuilders = {}, {}, {}, {}
        local TAB_BTN_W, TAB_BTN_H, TAB_BTN_GAP = 116, 24, 4

        local function CreateSectionText(parent, yOffset, text)
            local fs = parent:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yOffset)
            fs:SetWidth(780)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(true)
            fs:SetText(text)
            return fs
        end

        local function CreateActionButton(parent, text, col, row, onClick, tooltipTitle, tooltipText)
            local BTN_W, BTN_H = 170, 34
            local GAP_X, GAP_Y = 10, 10
            local START_X, START_Y = 8, -12
            local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
            btn:SetSize(BTN_W, BTN_H)
            btn:SetPoint("TOPLEFT", parent, "TOPLEFT", START_X + (col * (BTN_W + GAP_X)), START_Y - (row * (BTN_H + GAP_Y)))
            btn:SetText(text)
            btn:SetScript("OnClick", onClick)
            if MTR.AttachTooltip and tooltipTitle then
                MTR.AttachTooltip(btn, tooltipTitle, tooltipText or "")
            end
            return btn
        end

        local function ShowMemberTab(name)
            local frame = tabFrames[name]
            if not frame then return end
            for _, fr in pairs(tabFrames) do fr:Hide() end
            if tabBuilders[name] and not tabBuilt[name] then
                tabBuilders[name](frame)
                tabBuilt[name] = true
            end
            frame:Show()
        end

        for i, tname in ipairs(TAB_NAMES) do
            local f = CreateFrame("Frame",nil,memberWin)
            f:SetPoint("TOPLEFT",     memberWin,"TOPLEFT",    10,-72)
            f:SetPoint("BOTTOMRIGHT", memberWin,"BOTTOMRIGHT",-10,10)
            f:Hide()
            tabFrames[tname] = f

            local btn = CreateFrame("Button",nil,memberWin,"UIPanelButtonTemplate")
            btn:SetSize(TAB_BTN_W, TAB_BTN_H)
            if i == 1 then
                btn:SetPoint("TOPLEFT",memberWin,"TOPLEFT",10,-46)
            else
                btn:SetPoint("LEFT",tabBtns[i-1],"RIGHT",TAB_BTN_GAP,0)
            end
            btn:SetText(tname)
            btn:SetScript("OnClick", function() ShowMemberTab(tname) end)
            tabBtns[i] = btn
        end

        local function OpenMemberGroupRadarSettings()
            local GR = MTR.GroupRadar
            local defaults = (GR and GR.defaultConfig) or {}
            if not MTR.db then return end
            if not MTR.db.groupRadarConfig then
                if MTR.DeepCopy then MTR.db.groupRadarConfig = MTR.DeepCopy(defaults) else MTR.db.groupRadarConfig = {} end
            end
            local cfg = MTR.db.groupRadarConfig
            for k,v in pairs(defaults) do
                if cfg[k] == nil then cfg[k] = v end
            end

            local function ApplyRecommendedMemberRadarDefaults(force)
                local recommended = (GR and GR.memberRecommendedConfig) or {}
                local untouched = true
                local watchKeys = {
                    "alertLfmDps", "alertLfmTank", "alertLfmHeal",
                    "textAlertLfmDps", "textAlertLfmTank", "textAlertLfmHeal",
                    "alertMsGold", "alertMsLeveling", "alertBc",
                    "textAlertMsGold", "textAlertMsLeveling", "textAlertBc",
                    "messageMustContain", "messageMustNotContain",
                }
                for _, key in ipairs(watchKeys) do
                    local v = cfg[key]
                    if v == true then untouched = false break end
                    if type(v) == "string" and v ~= "" then untouched = false break end
                end

                if force or (cfg._memberPresetApplied ~= true and untouched) then
                    for key, val in pairs(recommended) do
                        cfg[key] = val
                    end
                    if cfg.messageMustContain == nil then cfg.messageMustContain = "" end
                    if cfg.messageMustNotContain == nil then cfg.messageMustNotContain = "" end
                    cfg._memberPresetApplied = true
                end
            end

            ApplyRecommendedMemberRadarDefaults(false)

            if memberWin._grSettingsFrame then
                if memberWin._grSettingsFrame:IsShown() then
                    memberWin._grSettingsFrame:Hide()
                else
                    memberWin._grSettingsFrame:Show()
                end
                return
            end

            local f = CreateFrame("Frame", "MekTownMemberGRSettings", UIParent)
            f:SetSize(560, 430)
            f:SetPoint("CENTER", 0, -20)
            f:SetFrameStrata("DIALOG")
            f:SetBackdrop({
                bgFile   = "",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile=false, tileSize=0, edgeSize=32,
                insets={left=8,right=8,top=8,bottom=8},
            })
            f:SetBackdropColor(0,0,0,0)
            do local bg=f:CreateTexture(nil,"BACKGROUND")
                bg:SetTexture("Interface\\Buttons\\WHITE8x8")
                bg:SetAllPoints(f)
                bg:SetVertexColor(0.04,0.01,0.01,0.97)
            end
            f:EnableMouse(true)
            f:SetMovable(true)
            f:RegisterForDrag("LeftButton")
            f:SetScript("OnDragStart", f.StartMoving)
            f:SetScript("OnDragStop", f.StopMovingOrSizing)

            local xBtn=CreateFrame("Button",nil,f,"UIPanelCloseButton")
            xBtn:SetPoint("TOPRIGHT",f,"TOPRIGHT", -4,-4)
            xBtn:SetScript("OnClick", function() f:Hide() end)

            local sh=f:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
            sh:SetPoint("TOPLEFT",f,"TOPLEFT",16,-16)
            sh:SetText("|cffffcc00Group Radar Settings|r")

            local sub=f:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            sub:SetPoint("TOPLEFT",sh,"BOTTOMLEFT",0,-6)
            sub:SetWidth(500)
            sub:SetJustifyH("LEFT")
            sub:SetText("|cffaaaaaaThese member controls only affect your own Group Radar alerts and LFG behavior.|r")

            local function MakeCK(parent, text, key, x, y)
                local ck = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
                ck:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
                ck:SetChecked(cfg[key] == true)
                local fs = parent:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
                fs:SetPoint("LEFT", ck, "RIGHT", 2, 1)
                fs:SetText(text)
                ck:SetScript("OnClick", function(self)
                    cfg[key] = self:GetChecked() and true or false
                end)
                return ck
            end

            local sec1=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
            sec1:SetPoint("TOPLEFT",f,"TOPLEFT",20,-64)
            sec1:SetText("Alerts")
            MakeCK(f, "LFM DPS popup",    "alertLfmDps",       20, -82)
            MakeCK(f, "LFM Tank popup",   "alertLfmTank",      20, -106)
            MakeCK(f, "LFM Heal popup",   "alertLfmHeal",      20, -130)
            MakeCK(f, "MS Gold popup",    "alertMsGold",       280,-82)
            MakeCK(f, "MS Leveling popup", "alertMsLeveling",  280,-106)
            MakeCK(f, "Bonus Coin popup", "alertBc",           280,-130)

            local sec2=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
            sec2:SetPoint("TOPLEFT",f,"TOPLEFT",20,-170)
            sec2:SetText("Chat Alerts")
            MakeCK(f, "LFM DPS text",     "textAlertLfmDps",    20, -188)
            MakeCK(f, "LFM Tank text",    "textAlertLfmTank",   20, -212)
            MakeCK(f, "LFM Heal text",    "textAlertLfmHeal",   20, -236)
            MakeCK(f, "MS Gold text",     "textAlertMsGold",    280,-188)
            MakeCK(f, "MS Leveling text", "textAlertMsLeveling",280,-212)
            MakeCK(f, "Bonus Coin text",  "textAlertBc",        280,-236)

            local sec3=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
            sec3:SetPoint("TOPLEFT",f,"TOPLEFT",20,-276)
            sec3:SetText("Suppress popups when")
            MakeCK(f, "In a group",       "doNotAlertInGroup",   20, -294)
            MakeCK(f, "In combat",        "doNotAlertInCombat",  20, -318)
            MakeCK(f, "In instance",      "dontAlertInInstance", 280,-294)
            MakeCK(f, "Silent mode",      "silentNotifications", 280,-318)

            local mustLbl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
            mustLbl:SetPoint("TOPLEFT",f,"TOPLEFT",20,-354)
            mustLbl:SetText("Must contain:")
            local mustEB=CreateFrame("EditBox",nil,f,"InputBoxTemplate")
            mustEB:SetSize(220,24)
            mustEB:SetPoint("TOPLEFT",mustLbl,"BOTTOMLEFT",0,-4)
            mustEB:SetAutoFocus(false)
            mustEB:SetText(cfg.messageMustContain or "")
            mustEB:SetScript("OnTextChanged", function(self)
                cfg.messageMustContain = self:GetText() or ""
            end)

            local blockLbl=f:CreateFontString(nil,"OVERLAY","GameFontNormal")
            blockLbl:SetPoint("TOPLEFT",f,"TOPLEFT",280,-354)
            blockLbl:SetText("Block phrases:")
            local blockEB=CreateFrame("EditBox",nil,f,"InputBoxTemplate")
            blockEB:SetSize(240,24)
            blockEB:SetPoint("TOPLEFT",blockLbl,"BOTTOMLEFT",0,-4)
            blockEB:SetAutoFocus(false)
            blockEB:SetText(cfg.messageMustNotContain or "")
            blockEB:SetScript("OnTextChanged", function(self)
                cfg.messageMustNotContain = self:GetText() or ""
            end)

            local lfgBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
            lfgBtn:SetSize(120,26)
            lfgBtn:SetPoint("BOTTOMLEFT",f,"BOTTOMLEFT",18,14)
            lfgBtn:SetText("Post LFG")
            lfgBtn:SetScript("OnClick", function()
                f:Hide()
                SafeInvoke(MTR.OpenFindGroup, "Post LFG")
            end)

            local presetBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
            presetBtn:SetSize(170,26)
            presetBtn:SetPoint("LEFT",lfgBtn,"RIGHT",8,0)
            presetBtn:SetText("Use LFG Defaults")
            presetBtn:SetScript("OnClick", function()
                ApplyRecommendedMemberRadarDefaults(true)
                f:Hide()
                memberWin._grSettingsFrame = nil
                OpenMemberGroupRadarSettings()
            end)
            if MTR.AttachTooltip then
                MTR.AttachTooltip(presetBtn, "Use LFG Defaults", "Applies the recommended member preset: LFM tank/heal/DPS popup and text alerts enabled.")
            end

            local closeBtn=CreateFrame("Button",nil,f,"UIPanelButtonTemplate")
            closeBtn:SetSize(90,26)
            closeBtn:SetPoint("BOTTOMRIGHT",f,"BOTTOMRIGHT",-18,14)
            closeBtn:SetText("Close")
            closeBtn:SetScript("OnClick", function() f:Hide() end)

            memberWin._grSettingsFrame = f
            f:Show()
        end

        tabBuilders["Group Radar"] = function(t)
            CreateActionButton(t, "Open Group Radar", 0, 0, function()
                if SafeInvoke(MTR.OpenGroupRadar, "Group Radar") then memberWin:Hide() end
            end, "Open Group Radar", "Opens the live Group Radar recruiter list and alert panel.")

            CreateActionButton(t, "|cff00ff00Post LFG|r", 1, 0, function()
                if SafeInvoke(MTR.OpenFindGroup, "Post LFG") then memberWin:Hide() end
            end, "Post LFG", "Opens the Group Radar LFG posting window.")

            CreateActionButton(t, "Radar Settings", 2, 0, function()
                OpenMemberGroupRadarSettings()
            end, "Group Radar Settings", "Lets regular guild members toggle their own Group Radar alerts and filters.")

            CreateActionButton(t, "|cffd4af37Open Vault|r", 0, 1, function()
                if MTR.OpenCharVaultToTab then
                    if SafeInvoke(function() MTR.OpenCharVaultToTab("Overview") end, "Character Vault") then memberWin:Hide() end
                else
                    if SafeInvoke(MTR.OpenCharVault, "Character Vault") then memberWin:Hide() end
                end
            end, "Character Vault", "Opens the shared vault and character storage tools.")

            CreateActionButton(t, "Open Guild Tree", 1, 1, function()
                if MTR.OpenCharVaultToTab then
                    if SafeInvoke(function() MTR.OpenCharVaultToTab("Guild Tree") end, "Guild Tree") then memberWin:Hide() end
                elseif MTR.OpenCharVault then
                    if SafeInvoke(function()
                        MTR.OpenCharVault()
                        if MTR.vaultWin and MTR.vaultWin._showTab then MTR.vaultWin._showTab("Guild Tree") end
                    end, "Guild Tree") then
                        memberWin:Hide()
                    end
                end
            end, "Guild Tree", "Opens the Guild Tree in view-only mode for regular members.")

            CreateSectionText(t, -102,
                "|cffaaaaaaOpen Group Radar shows the live recruiter list detected from chat. "..
                "Post LFG opens the Find Group panel so you can advertise yourself as LFG on a repeating timer. "..
                "Radar Settings controls your own alerts and filters. Open Guild Tree is view-only for members.\n\n"..
                "You can also use /mek radar or /mek lfg at any time.|r")
        end

        tabBuilders["Loot"] = function(t)
            local intro = CreateSectionText(t, -12,
                "|cffaaaaaaMembers can use the roll tool for raids, groups, and pug runs. Auction controls remain officer-only.|r")

            local rollLabel = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            rollLabel:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -16)
            rollLabel:SetText("Item name / link (Shift-click to fill):")

            local itemEB = CreateFrame("EditBox", nil, t, "InputBoxTemplate")
            itemEB:SetSize(330, 24)
            itemEB:SetPoint("TOPLEFT", rollLabel, "BOTTOMLEFT", 0, -6)
            itemEB:SetAutoFocus(false)
            itemEB:SetScript("OnMouseDown", function(self) self:SetFocus() end)
            if MTR.RegisterLinkEditBox then MTR.RegisterLinkEditBox(itemEB) end
            memberWin._memberRollItemEB = itemEB

            local typeLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            typeLbl:SetPoint("LEFT", itemEB, "RIGHT", 18, 0)
            typeLbl:SetText("Type:")

            local selRT = "MS"
            local rtDD = CreateFrame("Frame", "MekMemberRollTypeDD", t, "UIDropDownMenuTemplate")
            rtDD:SetPoint("TOPLEFT", typeLbl, "BOTTOMLEFT", -16, 10)
            UIDropDownMenu_SetWidth(rtDD, 120)
            UIDropDownMenu_Initialize(rtDD, function()
                for _, rt in ipairs(MTR.ROLL_TYPES or {"MS","OS","Transmog","Custom"}) do
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = rt
                    info.value = rt
                    info.func = function()
                        selRT = rt
                        UIDropDownMenu_SetSelectedValue(rtDD, rt)
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            UIDropDownMenu_SetSelectedValue(rtDD, selRT)

            local customLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            customLbl:SetPoint("TOPLEFT", itemEB, "BOTTOMLEFT", 0, -20)
            customLbl:SetText("Custom type:")
            local customEB = CreateFrame("EditBox", nil, t, "InputBoxTemplate")
            customEB:SetSize(150, 24)
            customEB:SetPoint("LEFT", customLbl, "RIGHT", 8, 0)
            customEB:SetAutoFocus(false)
            memberWin._memberRollCustomEB = customEB

            local timerLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            timerLbl:SetPoint("LEFT", customEB, "RIGHT", 28, 0)
            timerLbl:SetText("Timer (secs):")
            local timerEB = CreateFrame("EditBox", nil, t, "InputBoxTemplate")
            timerEB:SetSize(60, 24)
            timerEB:SetPoint("LEFT", timerLbl, "RIGHT", 8, 0)
            timerEB:SetAutoFocus(false)
            timerEB:SetText("60")
            memberWin._memberRollTimerEB = timerEB

            local rwCK = CreateFrame("CheckButton", nil, t, "UICheckButtonTemplate")
            rwCK:SetPoint("LEFT", timerEB, "RIGHT", 18, 0)
            local rwLbl = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            rwLbl:SetPoint("LEFT", rwCK, "RIGHT", 2, 1)
            rwLbl:SetText("Raid Warning")
            memberWin._memberRollRW = rwCK

            local openRoll = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
            openRoll:SetSize(140, 28)
            openRoll:SetPoint("TOPLEFT", customLbl, "BOTTOMLEFT", 0, -18)
            openRoll:SetText("Open Roll")
            openRoll:SetScript("OnClick", function()
                local item = (itemEB:GetText() or ""):match("^%s*(.-)%s*$")
                if item == "" then
                    if MTR.MPE then MTR.MPE("Enter an item name or paste a link.") end
                    return
                end
                local rt = selRT
                if rt == "Custom" then
                    rt = (customEB:GetText() or ""):match("^%s*(.-)%s*$")
                    if rt == "" then rt = "Custom" end
                end
                local timer = tonumber(timerEB:GetText() or "0") or 0
                SafeInvoke(function()
                    MTR.RollOpen(item, rt, timer > 0 and timer or nil, rwCK:GetChecked() and true or false)
                end, "Loot Roll")
            end)
            if MTR.AttachTooltip then
                MTR.AttachTooltip(openRoll, "Open Loot Roll", "Starts a shared /roll-based loot roll. Members can use this tool; auction controls remain officer-only.")
            end

            local viewActive = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
            viewActive:SetSize(140, 28)
            viewActive:SetPoint("LEFT", openRoll, "RIGHT", 8, 0)
            viewActive:SetText("Show Active Roll")
            viewActive:SetScript("OnClick", function()
                SafeInvoke(MTR.ShowRollFrame, "Active Roll")
            end)

            local histLbl = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            histLbl:SetPoint("TOPLEFT", openRoll, "BOTTOMLEFT", 0, -20)
            histLbl:SetText("Recent roll history")

            local histSF = CreateFrame("ScrollFrame", nil, t, "UIPanelScrollFrameTemplate")
            histSF:SetPoint("TOPLEFT", histLbl, "BOTTOMLEFT", -4, -6)
            histSF:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -20, 6)
            local histEB = CreateFrame("EditBox", nil, histSF)
            histEB:SetSize(760, 260)
            histEB:SetMultiLine(true)
            histEB:SetAutoFocus(false)
            histEB:SetFontObject(GameFontHighlightSmall)
            histEB:SetScript("OnTextChanged", function() end)
            histSF:SetScrollChild(histEB)
            memberWin._memberRollHistEB = histEB

            local function RefreshMemberRollHistory()
                if not memberWin._memberRollHistEB or not MTR.db or not MTR.db.dkpBidLog then return end
                local lines = {}
                for i = #MTR.db.dkpBidLog, math.max(1, #MTR.db.dkpBidLog - 99), -1 do
                    local e = MTR.db.dkpBidLog[i]
                    if e.type == "roll" then
                        local winVal = "?"
                        if e.allRolls then
                            for _, r in ipairs(e.allRolls) do
                                if r.name == e.winner then winVal = tostring(r.value) break end
                            end
                        end
                        lines[#lines+1] = string.format("[%s] [%s] (%s)  Winner: %s (rolled %s)", e.date or "?", e.item or "?", e.rollType or "?", e.winner or "?", winVal)
                    end
                end
                memberWin._memberRollHistEB:SetText(#lines > 0 and table.concat(lines, "\n") or "No roll history yet.")
            end
            memberWin._refreshMemberRollHistory = RefreshMemberRollHistory
            t:SetScript("OnShow", RefreshMemberRollHistory)
        end

        tabBuilders["DKP"] = function(t)
            local balLbl=t:CreateFontString(nil,"OVERLAY","GameFontHighlight")
            balLbl:SetPoint("TOP",t,"TOP",-50,-8)
            balLbl:SetText("Your DKP balance:")

            local balVal=t:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
            balVal:SetPoint("LEFT",balLbl,"RIGHT",8,0)
            balVal:SetText("|cffd4af370|r")
            memberWin._balVal = balVal

            local refBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            refBtn:SetSize(80,22)
            refBtn:SetPoint("LEFT",balVal,"RIGHT",14,0)
            refBtn:SetText("Refresh")
            refBtn:SetScript("OnClick",function() memberWin:RefreshDKP() end)

            local hLbl=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
            hLbl:SetPoint("TOP",t,"TOP",0,-38)
            hLbl:SetText("Your recent DKP transactions")

            local subLbl=t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            subLbl:SetPoint("TOP",hLbl,"BOTTOM",0,-4)
            subLbl:SetText("|cffaaaaaaRegular members can only view their own DKP history.|r")

            local hSF=CreateFrame("ScrollFrame",nil,t,"UIPanelScrollFrameTemplate")
            hSF:SetPoint("TOPLEFT",t,"TOPLEFT",4,-50)
            hSF:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",-20,4)
            local hEB=CreateFrame("EditBox",nil,hSF)
            hEB:SetSize(760,500)
            hEB:SetMultiLine(true)
            hEB:SetAutoFocus(false)
            hEB:SetFontObject(GameFontHighlightSmall)
            hEB:SetScript("OnTextChanged",function() end)
            hSF:SetScrollChild(hEB)
            memberWin._histEB = hEB

            t:SetScript("OnShow",function() memberWin:RefreshDKP() end)
        end

        tabBuilders["Standings"] = function(t)
            local stSF=CreateFrame("ScrollFrame",nil,t,"UIPanelScrollFrameTemplate")
            stSF:SetPoint("TOPLEFT",t,"TOPLEFT",0,-4)
            stSF:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",-20,34)
            local stContent=CreateFrame("Frame",nil,stSF)
            stContent:SetSize(780,600)
            stSF:SetScrollChild(stContent)
            memberWin._mStandContent = stContent
            memberWin._mStandRows    = {}

            local function BuildStandings()
                for _,row in ipairs(memberWin._mStandRows) do if row then row:Hide() end end
                memberWin._mStandRows = {}
                local standings = MTR.DKPStandings()
                stContent:SetHeight(math.max(500,#standings*24+10))
                for i,entry in ipairs(standings) do
                    local col
                    if entry.name == MTR.playerName then col = "|cffd4af37"
                    elseif i == 1 then col = "|cffffdd55"
                    elseif i <= 3 then col = "|cffaaaaff"
                    else col = "|cffffffff" end
                    local rowFrame=CreateFrame("Frame",nil,stContent)
                    rowFrame:SetSize(780,22)
                    rowFrame:SetPoint("TOPLEFT",stContent,"TOPLEFT",4,-(i-1)*24)
                    local lbl=rowFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                    lbl:SetPoint("LEFT",rowFrame,"LEFT",0,0)
                    lbl:SetWidth(600)
                    lbl:SetWordWrap(false)
                    lbl:SetText(string.format("%s%d.|r  %-24s  %d pts", col, i, MTR.Trunc(entry.name,24), entry.balance))
                    rowFrame:Show()
                    memberWin._mStandRows[#memberWin._mStandRows+1] = rowFrame
                end
            end
            memberWin._buildMemberStandings = BuildStandings

            local refBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            refBtn:SetSize(100,26)
            refBtn:SetPoint("BOTTOMLEFT",t,"BOTTOMLEFT",0,6)
            refBtn:SetText("Refresh")
            refBtn:SetScript("OnClick",BuildStandings)

            t:SetScript("OnShow",BuildStandings)
        end

        function memberWin:RefreshDKP()
            if not MTR.initialized or not MTR.db or not MTR.playerName then return end
            if self._balVal then
                self._balVal:SetText("|cffd4af37"..MTR.DKPBalance(MTR.playerName).." pts|r")
            end
            if self._histEB then
                local hist = MTR.db.dkpLedger[MTR.playerName] and MTR.db.dkpLedger[MTR.playerName].history or {}
                local lines = {}
                for i = #hist, math.max(1,#hist-99), -1 do
                    local e = hist[i]
                    lines[#lines+1] = string.format("[%s] %s%d pts  (%s)  Bal: %d", e.date, e.amount>=0 and "+" or "", e.amount, e.reason, e.balance)
                end
                self._histEB:SetText(#lines>0 and table.concat(lines,"\n") or "No DKP history yet.")
            end
            if self._refreshMemberRollHistory then self._refreshMemberRollHistory() end
        end

        tabBuilders["Group Radar"](tabFrames["Group Radar"])
        tabBuilt["Group Radar"] = true

        memberWin._showTab = ShowMemberTab
        MTR.memberWin = memberWin
    end

    if memberWin:IsShown() then memberWin:Hide() return end
    if MTR.initialized and MTR.db then memberWin:RefreshDKP() end
    memberWin._showTab("Group Radar")
    memberWin:Show()
end
