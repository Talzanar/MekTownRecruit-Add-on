-- ============================================================================
-- UI_Member.lua  v8.0
-- Member panel for regular guild members (non-officer / non-GM).
-- Four tabs: DKP (own balance + history) / Ledger / Standings / Group Radar
-- No guild management controls of any kind.
-- ============================================================================
local MTR = MekTownRecruit

local memberWin = nil

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
        do local _bt=memberWin:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(memberWin) _bt:SetVertexColor(0.04,0.01,0.01,0.97) end
        memberWin:EnableMouse(true) memberWin:SetMovable(true)
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
        sep:SetColorTexture(0.3,0.3,0.5,0.5) sep:SetHeight(1)
        sep:SetPoint("TOPLEFT",memberWin,"TOPLEFT",10,-40)
        sep:SetPoint("TOPRIGHT",memberWin,"TOPRIGHT",-10,-40)

        -- ── Tab system ────────────────────────────────────────────────────────
        -- Group Radar first — most immediately useful for a member joining a group.
        -- DKP second — most frequently checked. Ledger and Standings follow.
        local TABS = {"Group Radar","DKP","Standings"}
        local tabBtns     = {}
        local tabFrames   = {}
        local tabBuilt    = {}
        local tabBuilders = {}

        for i, tname in ipairs(TABS) do
            local f = CreateFrame("Frame",nil,memberWin)
            f:SetPoint("TOPLEFT",     memberWin,"TOPLEFT",    10,-70)
            f:SetPoint("BOTTOMRIGHT", memberWin,"BOTTOMRIGHT",-10,10)
            f:Hide()
            tabFrames[tname] = f

            local btn = CreateFrame("Button",nil,memberWin,"UIPanelButtonTemplate")
            btn:SetSize(100,24)
            if i==1 then btn:SetPoint("TOPLEFT",memberWin,"TOPLEFT",10,-46)
            else          btn:SetPoint("LEFT",tabBtns[i-1],"RIGHT",3,0) end
            btn:SetText(tname)
            local key = tname
            btn:SetScript("OnClick",function()
                for _,fr in pairs(tabFrames) do fr:Hide() end
                if tabBuilders[key] and not tabBuilt[key] then
                    tabBuilders[key](tabFrames[key])
                    tabBuilt[key] = true
                end
                tabFrames[key]:Show()
            end)
            tabBtns[i] = btn
        end

        local function ShowMemberTab(name)
            for _,fr in pairs(tabFrames) do fr:Hide() end
            if tabBuilders[name] and not tabBuilt[name] then
                tabBuilders[name](tabFrames[name])
                tabBuilt[name] = true
            end
            if tabFrames[name] then tabFrames[name]:Show() end
        end

        -- ── TAB: DKP ─────────────────────────────────────────────────────────
        tabBuilders["DKP"] = function(t)
            local balLbl=t:CreateFontString(nil,"OVERLAY","GameFontHighlight")
            balLbl:SetPoint("TOP",t,"TOP",-50,-8) balLbl:SetText("Your DKP balance:")
            local balVal=t:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
            balVal:SetPoint("LEFT",balLbl,"RIGHT",8,0) balVal:SetText("|cffd4af370|r")
            memberWin._balVal = balVal

            local refBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            refBtn:SetSize(70,22) refBtn:SetPoint("LEFT",balVal,"RIGHT",14,0) refBtn:SetText("Refresh")
            refBtn:SetScript("OnClick",function() memberWin:RefreshDKP() end)

            local hLbl=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
            hLbl:SetPoint("TOP",t,"TOP",0,-38) hLbl:SetText("Your recent DKP transactions")
            local subLbl=t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            subLbl:SetPoint("TOP",hLbl,"BOTTOM",0,-4) subLbl:SetText("|cffaaaaaaRegular members can only view their own DKP history.|r")

            local hSF=CreateFrame("ScrollFrame",nil,t,"UIPanelScrollFrameTemplate")
            hSF:SetPoint("TOPLEFT",t,"TOPLEFT",4,-50)
            hSF:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",-20,4)
            local hEB=CreateFrame("EditBox",nil,hSF)
            hEB:SetSize(760,500) hEB:SetMultiLine(true) hEB:SetAutoFocus(false)
            hEB:SetFontObject(GameFontHighlightSmall)
            hEB:SetScript("OnTextChanged",function() end)
            hSF:SetScrollChild(hEB)
            memberWin._histEB = hEB

            t:SetScript("OnShow",function() memberWin:RefreshDKP() end)
        end

        -- ── TAB: Standings ────────────────────────────────────────────────────
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
                    if entry.name==MTR.playerName then col="|cffd4af37"
                    elseif i==1  then col="|cffffdd55"
                    elseif i<=3  then col="|cffaaaaff"
                    else              col="|cffffffff" end
                    local rowFrame=CreateFrame("Frame",nil,stContent)
                    rowFrame:SetSize(780,22)
                    rowFrame:SetPoint("TOPLEFT",stContent,"TOPLEFT",4,-(i-1)*24)
                    local lbl=rowFrame:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                    lbl:SetPoint("LEFT",rowFrame,"LEFT",0,0)
                    lbl:SetWidth(600) lbl:SetWordWrap(false)
                    lbl:SetText(string.format("%s%d.|r  %-24s  %d pts",
                        col,i,MTR.Trunc(entry.name,24),entry.balance))
                    rowFrame:Show()
                    memberWin._mStandRows[#memberWin._mStandRows+1] = rowFrame
                end
            end
            memberWin._buildMemberStandings = BuildStandings

            local refBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            refBtn:SetSize(100,26) refBtn:SetPoint("BOTTOMLEFT",t,"BOTTOMLEFT",0,6)
            refBtn:SetText("Refresh") refBtn:SetScript("OnClick",BuildStandings)

            t:SetScript("OnShow",BuildStandings)
        end

        -- ── TAB: Group Radar ──────────────────────────────────────────────────
        tabBuilders["Group Radar"] = function(t)
            local openBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            openBtn:SetSize(200,36) openBtn:SetPoint("TOPLEFT",t,"TOPLEFT",4,-4)
            openBtn:SetText("|cffffcc00Open Group Radar|r")
            openBtn:SetScript("OnClick",function()
                memberWin:Hide()
                if MTR.OpenGroupRadar then MTR.OpenGroupRadar() end
            end)

            local lfgBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            lfgBtn:SetSize(130,36) lfgBtn:SetPoint("LEFT",openBtn,"RIGHT",8,0)
            lfgBtn:SetText("|cff00ff00Post LFG|r")
            lfgBtn:SetScript("OnClick",function()
                memberWin:Hide()
                if MTR.GroupRadar and MTR.GroupRadar.ShowFindGroupFrame then
                    MTR.GroupRadar.ShowFindGroupFrame()
                end
            end)

            local vaultBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            vaultBtn:SetSize(130,36) vaultBtn:SetPoint("LEFT",lfgBtn,"RIGHT",8,0)
            vaultBtn:SetText("|cffd4af37j[ Vault|r")
            vaultBtn:SetScript("OnClick",function()
                memberWin:Hide()
                if MTR.OpenCharVault then MTR.OpenCharVault() end
            end)

            local desc=t:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
            desc:SetPoint("TOPLEFT",t,"TOPLEFT",4,-52) desc:SetWidth(780) desc:SetWordWrap(true)
            desc:SetText(
                "|cffaaaaaa"..
                "Group Radar scans all channels for LFM messages — tanks, healers, DPS, MS Gold, "..
                "MS Leveling. When a match is found you get a chat alert and optionally a popup with "..
                "an Apply button that automatically whispers your item level and LRE to the recruiter.\n\n"..
                "Post LFG opens the Find Group panel where you can broadcast yourself as LFG on a "..
                "repeating timer. \n\nYou can also use /mek radar or /mek lfg at any time.|r"
            )
        end

        -- Build Group Radar tab immediately (default first tab)
        tabBuilders["Group Radar"](tabFrames["Group Radar"])
        tabBuilt["Group Radar"] = true

        -- ── Refresh helper ────────────────────────────────────────────────────
        function memberWin:RefreshDKP()
            if not MTR.initialized or not MTR.db or not MTR.playerName then return end
            if self._balVal then
                self._balVal:SetText("|cffd4af37"..MTR.DKPBalance(MTR.playerName).." pts|r")
            end
            if self._histEB then
                local hist = MTR.db.dkpLedger[MTR.playerName]
                    and MTR.db.dkpLedger[MTR.playerName].history or {}
                local lines = {}
                for i=#hist,math.max(1,#hist-99),-1 do
                    local e=hist[i]
                    lines[#lines+1]=string.format("[%s] %s%d pts  (%s)  Bal: %d",
                        e.date, e.amount>=0 and "+" or "", e.amount, e.reason, e.balance)
                end
                self._histEB:SetText(#lines>0 and table.concat(lines,"\n") or "No DKP history yet.")
            end
        end

        memberWin._showTab = ShowMemberTab
        MTR.memberWin = memberWin
    end

    if memberWin:IsShown() then memberWin:Hide() return end
    if MTR.initialized and MTR.db then memberWin:RefreshDKP() end
    memberWin._showTab("Group Radar")
    memberWin:Show()
end
