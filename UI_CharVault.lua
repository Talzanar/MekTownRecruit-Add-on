-- ============================================================================
-- UI_CharVault.lua  v9.1
-- VAULT — the complete cross-character item and resource window
-- /mek chars  |  ★ Vault button
--
-- Tabs:
--   Overview     — all scanned alts: class/level/ilvl/gold/zone
--   Browse Bags  — visual icon grid of any alt's bags, bank and mail
--   Item Search  — find items across ALL alts; icon grid, hover tooltips
--   Professions  — profession skill browser across all alts
--   Gold         — wealth per alt, total, visual bars
--   Equipment    — per-alt gear with slot browser and avg ilvl
--   Guild Bank   — officer-gated; icon grid search of guild bank tabs
-- ============================================================================
local MTR = MekTownRecruit

local vaultWin  = nil
local VAULT_W   = 960
local VAULT_H   = 640

-- ============================================================================
-- QUALITY COLOURS  (matches Blizzard's ITEM_QUALITY_COLORS)
-- ============================================================================
local QUALITY_COLORS = {
    [0] = {0.62, 0.62, 0.62},   -- Poor       (grey)
    [1] = {1.00, 1.00, 1.00},   -- Common     (white)
    [2] = {0.12, 1.00, 0.00},   -- Uncommon   (green)
    [3] = {0.00, 0.44, 0.87},   -- Rare       (blue)
    [4] = {0.64, 0.21, 0.93},   -- Epic       (purple)
    [5] = {1.00, 0.50, 0.00},   -- Legendary  (orange)
    [6] = {0.90, 0.80, 0.50},   -- Artifact   (pale gold)
}
local QUALITY_HEX = {
    [0]="|cff9f9f9f",[1]="|cffffffff",[2]="|cff1eff00",
    [3]="|cff0070dd",[4]="|cffa335ee",[5]="|cffff8000",
    [6]="|cffe6cc80",
}
local EMPTY_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- ============================================================================
-- SHARED HELPERS
-- ============================================================================
local CLASS_COLOR_HEX = {
    WARRIOR="ffc79c6e",PALADIN="fff58cba",HUNTER="ffabd473",
    ROGUE="fffff569",  PRIEST="ffffffff",DEATHKNIGHT="ffc41f3b",
    SHAMAN="ff0070de", MAGE="ff69ccf0", WARLOCK="ff9482c9",
    DRUID="ffff7d0a",
}
local function ClassCol(class)
    return "|c"..(CLASS_COLOR_HEX[(class or ""):upper()] or "ffffffff")
end

-- Row pool (text rows)
local function PoolGet(c,idx,w,h,step)
    if not c._pool then c._pool={} end
    if not c._pool[idx] then c._pool[idx]=CreateFrame("Frame",nil,c) end
    local r=c._pool[idx]
    r:SetSize(w,h) r:SetPoint("TOPLEFT",c,"TOPLEFT",0,-(idx-1)*(step or h)) r:Show()
    return r
end
local function PoolHide(c,n)
    if not c._pool then return end
    for i=n,#c._pool do if c._pool[i] then c._pool[i]:Hide() end end
end
local function FS(row,key,font)
    if not row[key] then row[key]=row:CreateFontString(nil,"OVERLAY",font or "GameFontHighlightSmall") end
    return row[key]
end
local function RowBG(row,i)
    if not row._bg then row._bg=row:CreateTexture(nil,"BACKGROUND") row._bg:SetAllPoints(row) end
    if i%2==0 then row._bg:SetColorTexture(0.08,0.08,0.14,0.55)
    else            row._bg:SetColorTexture(0.04,0.04,0.10,0.35) end
end
local function MakeSF(parent,yt,yb)
    local sf=CreateFrame("ScrollFrame",nil,parent,"UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT",    parent,"TOPLEFT",    0,yt or -4)
    sf:SetPoint("BOTTOMRIGHT",parent,"BOTTOMRIGHT",-20,yb or 4)
    local c=CreateFrame("Frame",nil,sf) c:SetSize(890,600) sf:SetScrollChild(c)
    return sf,c
end
local function MakeSearchBar(parent,label,y)
    local lbl=parent:CreateFontString(nil,"OVERLAY","GameFontNormal")
    lbl:SetPoint("TOPLEFT",parent,"TOPLEFT",4,y or -4) lbl:SetText(label or "Search:")
    local eb=CreateFrame("EditBox",nil,parent,"InputBoxTemplate")
    eb:SetSize(320,22) eb:SetPoint("LEFT",lbl,"RIGHT",6,0) eb:SetAutoFocus(false)
    local clr=CreateFrame("Button",nil,parent,"UIPanelButtonTemplate")
    clr:SetSize(56,22) clr:SetPoint("LEFT",eb,"RIGHT",4,0)
    clr:SetText("Clear") clr:SetScript("OnClick",function() eb:SetText("") end)
    return eb,clr
end

-- ============================================================================
-- ICON BUTTON SYSTEM
-- Each icon is a 36×36 Button with quality-coloured border, item texture,
-- count badge, tooltip-on-hover, shift-click-to-link, and MekTown flair.
-- ============================================================================
local ICON_SIZE = 36
local ICON_GAP  = 3
local ICON_STEP = ICON_SIZE + ICON_GAP
local ICON_COLS = math.floor(890 / ICON_STEP)   -- how many icons fit per row

-- Get or create the idx-th icon button inside a content frame
local function IconGet(content, idx)
    if not content._icons then content._icons = {} end
    if not content._icons[idx] then
        local btn = CreateFrame("Button", nil, content)
        btn:SetSize(ICON_SIZE, ICON_SIZE)

        -- Quality border via simple backdrop
        btn:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
            insets   = {left=1,right=1,top=1,bottom=1},
        })
        btn:SetBackdropColor(0, 0, 0, 0.85)
        btn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

        -- Item icon texture (crops default icon edge padding)
        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("TOPLEFT",     btn, "TOPLEFT",     1, -1)
        tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1,  1)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        btn._tex = tex

        -- Count badge (bottom-right, matches Blizzard bag style)
        local cnt = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        cnt:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 1)
        btn._cnt = cnt

        -- Tooltip: show native tooltip (CharVault hook adds WAAAGH lines)
        btn:SetScript("OnEnter", function(self)
            if self._link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self._link)
                GameTooltip:Show()
            end
            if self._onHover then self._onHover(self) end
        end)
        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            if self._onLeave then self._onLeave(self) end
        end)

        -- Shift-click to link item in the active chat editbox
        btn:SetScript("OnClick", function(self)
            if IsShiftKeyDown() and self._link then
                local ae = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
                if ae then ChatEdit_InsertLink(self._link) end
            end
        end)

        content._icons[idx] = btn
    end
    local btn = content._icons[idx]
    btn:Show()
    return btn
end

local function IconHideFrom(content, n)
    if not content._icons then return end
    for i = n, #content._icons do
        if content._icons[i] then content._icons[i]:Hide() end
    end
end

-- Populate an icon button with item data
local function IconSetItem(btn, itemID, qty, link)
    if not itemID and not link then
        btn._tex:SetTexture(EMPTY_ICON)
        btn:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
        btn._cnt:SetText("")
        btn._link = nil
        return
    end

    local name, ilink, quality, _, _, _, _, _, _, texture = GetItemInfo(itemID or link or 0)

    -- Texture: use item icon, fall back to question mark while client fetches
    btn._tex:SetTexture(texture or EMPTY_ICON)

    -- Quality border
    local qc = QUALITY_COLORS[quality or 1] or QUALITY_COLORS[1]
    btn:SetBackdropBorderColor(qc[1], qc[2], qc[3], 1)

    -- Count badge: only show if > 1
    btn._cnt:SetText((qty and qty > 1) and qty or "")

    -- Store link for tooltip + shift-click
    btn._link = ilink or link
    btn._itemID = itemID
    btn._qty = qty
end

-- Position icon at grid slot (1-based)
local function IconPlace(btn, content, gridIdx)
    local col = (gridIdx - 1) % ICON_COLS
    local row = math.floor((gridIdx - 1) / ICON_COLS)
    btn:SetPoint("TOPLEFT", content, "TOPLEFT", col * ICON_STEP, -(row * ICON_STEP))
end

-- ============================================================================
-- DETAIL STRIP  (shown below icon grid; updates on hover)
-- A fixed-height panel that shows per-character breakdown for the hovered item.
-- ============================================================================
local function MakeDetailStrip(parent, yBottom)
    local strip = parent:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    strip:SetPoint("BOTTOMLEFT",  parent,"BOTTOMLEFT",  4, yBottom or 4)
    strip:SetPoint("BOTTOMRIGHT", parent,"BOTTOMRIGHT", -4, yBottom or 4)
    strip:SetWordWrap(false)
    strip:SetJustifyH("LEFT")
    strip:SetText("|cffaaaaaa Hover over an item to see who has it and where.|r")
    return strip
end

-- Update the detail strip from tooltip index data
local function DetailUpdate(strip, itemID, itemName)
    if not strip or not itemID then return end
    local rows = MTR.CharVault and MTR.CharVault.tooltipIndex and
                 MTR.CharVault.tooltipIndex[itemID]
    if not rows or #rows == 0 then
        strip:SetText("|cffaaaaaa " .. (itemName or "?") .. " — not found on any alt.|r")
        return
    end
    local parts = {}
    local grand = 0
    table.sort(rows, function(a,b) return a.total > b.total end)
    for _, r in ipairs(rows) do
        grand = grand + r.total
        local locs = {}
        if r.bags > 0 then locs[#locs+1]="|cff88ff88"..r.bags.."B|r"  end
        if r.bank > 0 then locs[#locs+1]="|cff88ccff"..r.bank.."K|r"  end
        if r.mail > 0 then locs[#locs+1]="|cffffcc00"..r.mail.."M|r"  end
        parts[#parts+1] = "|cffffd700"..r.char.."|r "..r.total.."x ("..table.concat(locs,"+")..")"
    end
    strip:SetText("|cffd4af37".. (itemName or "?") .."|r  —  "..
        table.concat(parts, "   |cff333333|   ")..
        "   |cffaaaaaa Total: |cffffff00"..grand.."x|r")
end

-- ============================================================================
-- TAB: OVERVIEW
-- ============================================================================
local function BuildOverview(t)
    if not t._sf then
        local hdr=t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        hdr:SetPoint("TOPLEFT",t,"TOPLEFT",0,-2)
        hdr:SetPoint("TOPRIGHT",t,"TOPRIGHT",0,-2)
        hdr:SetJustifyH("CENTER")
        hdr:SetText(string.format("|cffaaaaaa %-16s  %-12s  Lv  ilvl  %-16s  %-20s  Last Seen|r",
            "Name","Class","Gold","Zone"))
        t._hdr=hdr
        local _,c=MakeSF(t,-18,34)
        t._content=c
        local refBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
        refBtn:SetSize(80,26) refBtn:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",0,4)
        refBtn:SetText("Refresh") refBtn:SetScript("OnClick",function() t:GetScript("OnShow")(t) end)
        local scanBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
        scanBtn:SetSize(110,26) scanBtn:SetPoint("RIGHT",refBtn,"LEFT",-4,0)
        scanBtn:SetText("Scan This Alt")
        scanBtn:SetScript("OnClick",function()
            if MTR.CharVault then MTR.CharVault.ScanCharacter() end
            t:GetScript("OnShow")(t)
        end)
        local clearBtn=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
        clearBtn:SetSize(120,26) clearBtn:SetPoint("RIGHT",scanBtn,"LEFT",-4,0)
        clearBtn:SetText("Remove This Alt")
        clearBtn:SetScript("OnClick",function()
            if not MekTownRecruitDB.charVault then return end
            local key=(UnitName("player") or "?").."-"..(GetRealmName() or "?")
            MekTownRecruitDB.charVault[key]=nil
            t:GetScript("OnShow")(t)
        end)
    end
    local c=t._content
    local chars=MTR.CharVault and MTR.CharVault.GetAll() or {}
    local ROW_H=22
    if #chars==0 then
        PoolHide(c,1)
        local row=PoolGet(c,1,890,ROW_H,ROW_H) RowBG(row,1)
        local fs=FS(row,"_msg","GameFontHighlight") fs:SetAllPoints(row) fs:SetJustifyH("CENTER")
        fs:SetText("|cffaaaaaa No characters scanned yet. Log in on each alt to populate.|r")
        c:SetHeight(50) return
    end
    for i,ch in ipairs(chars) do
        local row=PoolGet(c,i,890,ROW_H,ROW_H) RowBG(row,i)
        local cc=ClassCol(ch.class)
        local gold=MTR.CharVault and MTR.CharVault.FormatGold(ch.gold or 0) or "0g"
        local fs=FS(row,"_line","GameFontHighlightSmall")
        fs:SetPoint("LEFT",row,"LEFT",4,0) fs:SetWidth(890) fs:SetWordWrap(false)
        fs:SetText(string.format("%s%-16s|r  %-12s  %2d  %4d  %-16s  %-20s  %s",
            cc,MTR.Trunc(ch.name or "?",16),MTR.Trunc(ch.class or "?",12),
            ch.level or 0,ch.avgIlvl or 0,MTR.Trunc(gold,16),
            MTR.Trunc(ch.zone or "?",20),ch.lastSeen or "?"))
    end
    PoolHide(c,#chars+1)
    c:SetHeight(math.max(500,#chars*ROW_H+10))
end

-- ============================================================================
-- TAB: BROWSE BAGS  (visual icon grid of any alt's inventory)
-- ============================================================================
local function BuildBrowseBags(t)
    if not t._dd then
        -- Character selector
        local lbl=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl:SetPoint("TOPLEFT",t,"TOPLEFT",4,-4) lbl:SetText("Character:")
        local dd=CreateFrame("Frame","MekVaultBrowseDD",t,"UIDropDownMenuTemplate")
        dd:SetPoint("LEFT",lbl,"RIGHT",2,0) UIDropDownMenu_SetWidth(dd,160)
        t._dd=dd

        -- Location filter buttons
        local filterBtns={}
        local filterLabels={"All","Bags","Bank","Mail"}
        t._filter="All"
        for i,fl in ipairs(filterLabels) do
            local fb=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            fb:SetSize(56,22)
            if i==1 then fb:SetPoint("TOPLEFT",t,"TOPLEFT",340,-5)
            else         fb:SetPoint("LEFT",filterBtns[i-1],"RIGHT",3,0) end
            fb:SetText(fl)
            filterBtns[i]=fb
            local f2=fl
            fb:SetScript("OnClick",function()
                t._filter=f2
                for _,b in ipairs(filterBtns) do b:UnlockHighlight() end
                fb:LockHighlight()
                if t._show then t._show() end
            end)
        end
        filterBtns[1]:LockHighlight()

        -- Status label
        local statusFS=t:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        statusFS:SetPoint("TOPLEFT",t,"TOPLEFT",570,-8)
        statusFS:SetWidth(320) statusFS:SetWordWrap(false)
        t._statusFS=statusFS

        -- Detail strip at very bottom
        local detail=MakeDetailStrip(t,6)
        t._detail=detail

        -- Scroll frame for icon grid (leaves 70px at bottom for detail + separator)
        local _,c=MakeSF(t,-32,72)
        t._content=c

        -- Separator above detail
        local sep=t:CreateTexture(nil,"ARTWORK")
        sep:SetColorTexture(0.25,0.25,0.4,0.5) sep:SetHeight(1)
        sep:SetPoint("BOTTOMLEFT",t,"BOTTOMLEFT",0,68)
        sep:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",0,68)

        -- Populate character dropdown
        local function PopDD()
            local chars=MTR.CharVault and MTR.CharVault.GetAll() or {}
            UIDropDownMenu_Initialize(dd,function()
                for _,ch in ipairs(chars) do
                    local info=UIDropDownMenu_CreateInfo()
                    info.text=ch.name info.value=ch.key
                    info.func=function(self)
                        UIDropDownMenu_SetSelectedValue(dd,self.value)
                        t._selectedKey=self.value
                        if t._show then t._show() end
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            if chars[1] then
                UIDropDownMenu_SetSelectedValue(dd,chars[1].key)
                t._selectedKey=chars[1].key
            end
        end
        t._popDD=PopDD

        -- Show function: render icon grid for selected char + filter
        t._show=function()
            local key=t._selectedKey
            local entry=key and MekTownRecruitDB.charVault and MekTownRecruitDB.charVault[key]
            local c2=t._content
            local filter=t._filter or "All"

            -- Support both storage formats:
            --   New: entry.items = {[itemID]={bags=N,bank=N,mail=N}}
            --   Old: entry.bags  = [{link,name,count}] + entry.bank = [...]
            -- Normalise old format into items table on-the-fly (non-destructive)
            local itemsSource = entry.items
            if not itemsSource or not next(itemsSource) then
                -- Try to build from old flat arrays
                local oldBags = entry.bags or {}
                local oldBank = entry.bank or {}
                if #oldBags > 0 or #oldBank > 0 then
                    itemsSource = {}
                    for _,item in ipairs(oldBags) do
                        local id = item.link and tonumber(item.link:match("item:(%d+)"))
                        if id then
                            itemsSource[id] = itemsSource[id] or {bags=0,bank=0,mail=0}
                            itemsSource[id].bags = (itemsSource[id].bags or 0) + (item.count or 1)
                        end
                    end
                    for _,item in ipairs(oldBank) do
                        local id = item.link and tonumber(item.link:match("item:(%d+)"))
                        if id then
                            itemsSource[id] = itemsSource[id] or {bags=0,bank=0,mail=0}
                            itemsSource[id].bank = (itemsSource[id].bank or 0) + (item.count or 1)
                        end
                    end
                end
            end

            if not itemsSource or not next(itemsSource) then
                IconHideFrom(c2,1)
                t._statusFS:SetText("|cffaaaaaa No data. Log in on this alt first, then open your bank.|r")
                c2:SetHeight(50) return
            end

            -- Collect items for this filter
            local items={}
            for id,slots in pairs(itemsSource) do
                local show=false
                if filter=="All"  then show=(slots.bags or 0)+(slots.bank or 0)+(slots.mail or 0)>0
                elseif filter=="Bags"  then show=(slots.bags or 0)>0
                elseif filter=="Bank"  then show=(slots.bank or 0)>0
                elseif filter=="Mail"  then show=(slots.mail or 0)>0 end
                if show then
                    local qty=0
                    if filter=="All"  then qty=(slots.bags or 0)+(slots.bank or 0)+(slots.mail or 0)
                    elseif filter=="Bags"  then qty=slots.bags or 0
                    elseif filter=="Bank"  then qty=slots.bank or 0
                    elseif filter=="Mail"  then qty=slots.mail or 0 end
                    local name,link,quality,_,_,_,_,_,_,tex = GetItemInfo(id)
                    items[#items+1]={id=id,qty=qty,name=name or "",link=link,quality=quality,tex=tex}
                end
            end

            -- Sort by quality desc, then name
            table.sort(items,function(a,b)
                if (a.quality or 1)~=(b.quality or 1) then return (a.quality or 1)>(b.quality or 1) end
                return (a.name or "")< (b.name or "")
            end)

            if #items==0 then
                IconHideFrom(c2,1)
                t._statusFS:SetText("|cffaaaaaa No "..filter:lower().." items for this alt.|r")
                c2:SetHeight(50) return
            end

            local totalCopper=0
            local charName=(entry.meta and entry.meta.name) or entry.name or "?"
            t._statusFS:SetText(string.format(
                "|cffaaaaaa%s — %d unique item%s in %s|r",
                charName,#items,#items==1 and "" or "s",filter))

            for i,item in ipairs(items) do
                local btn=IconGet(c2,i)
                IconPlace(btn,c2,i)
                IconSetItem(btn,item.id,item.qty,item.link)
                -- Detail strip update on hover
                local id2,name2=item.id,item.name
                btn._onHover=function(self)
                    DetailUpdate(t._detail,id2,name2)
                end
                btn._onLeave=function()
                    t._detail:SetText("|cffaaaaaa Hover over an item to see who has it and where.|r")
                end
            end
            IconHideFrom(c2,#items+1)

            local rows=math.ceil(#items/ICON_COLS)
            c2:SetHeight(math.max(200, rows*ICON_STEP+10))
        end
    end

    if t._popDD then t._popDD() end
    if t._show  then t._show()  end
end

-- ============================================================================
-- TAB: ITEM SEARCH  (icon grid with aggregate totals + detail strip)
-- ============================================================================
local function BuildItemSearch(t)
    if not t._eb then
        -- Row 1 (y=-4): Search bar label + editbox + clear button
        t._eb,_ = MakeSearchBar(t,"Search (2+ chars):",-4)
        t._eb:SetScript("OnTextChanged",function(s)
            t._query=s:GetText()
            if t._refresh then t._refresh() end
        end)

        -- Row 2 (y=-32): Quality tier filter buttons on their own line
        local qLabel=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        qLabel:SetPoint("TOPLEFT",t,"TOPLEFT",4,-32) qLabel:SetText("Quality:")
        local qFilters={"All","Uncommon+","Rare+","Epic+"}
        t._qFilter="All"
        local qBtns={}
        for i,ql in ipairs(qFilters) do
            local qb=CreateFrame("Button",nil,t,"UIPanelButtonTemplate")
            qb:SetSize(88,22)
            if i==1 then qb:SetPoint("LEFT",qLabel,"RIGHT",6,0)
            else         qb:SetPoint("LEFT",qBtns[i-1],"RIGHT",4,0) end
            local qc = i==3 and "|cff0070dd" or i==4 and "|cffa335ee" or i==2 and "|cff1eff00" or nil
            qb:SetText((qc or "")..ql..(qc and "|r" or ""))
            qBtns[i]=qb
            local ql2=ql
            qb:SetScript("OnClick",function()
                t._qFilter=ql2
                for _,b in ipairs(qBtns) do b:UnlockHighlight() end
                qb:LockHighlight()
                if t._refresh then t._refresh() end
            end)
        end
        qBtns[1]:LockHighlight()
        t._qBtns=qBtns

        -- Detail strip (fixed at bottom, above separator)
        local sep=t:CreateTexture(nil,"ARTWORK")
        sep:SetColorTexture(0.25,0.25,0.4,0.5) sep:SetHeight(1)
        sep:SetPoint("BOTTOMLEFT",t,"BOTTOMLEFT",0,36)
        sep:SetPoint("BOTTOMRIGHT",t,"BOTTOMRIGHT",0,36)
        local detail=MakeDetailStrip(t,8)
        t._detail=detail

        -- Scroll frame starts below both rows (row1 ~26px + row2 ~22px + 10px gap = 58px)
        local _,c=MakeSF(t,-60,50)
        t._content=c
    end

    local MIN_Q = {["All"]=0,["Uncommon+"]=2,["Rare+"]=3,["Epic+"]=4}

    local function Refresh()
        local q   = t._query or ""
        local c   = t._content
        local mqf = MIN_Q[t._qFilter or "All"] or 0

        if #q < 2 then
            IconHideFrom(c,1)
            local row=PoolGet(c,1,890,30,30) RowBG(row,1)
            local fs=FS(row,"_msg","GameFontHighlight") fs:SetAllPoints(row) fs:SetJustifyH("CENTER")
            fs:SetText("|cffaaaaaa Type at least 2 characters to search all bags, banks and mail across every alt.|r")
            c:SetHeight(50) return
        end

        local results=MTR.CharVault and MTR.CharVault.SearchItem(q) or {}

        -- Apply quality filter
        if mqf > 0 then
            local filtered={}
            for _,r in ipairs(results) do
                local _,_,quality=GetItemInfo(r.id or 0)
                if (quality or 0) >= mqf then filtered[#filtered+1]=r end
            end
            results=filtered
        end

        if #results==0 then
            IconHideFrom(c,1)
            local row=PoolGet(c,1,890,30,30) RowBG(row,1)
            local fs=FS(row,"_msg","GameFontHighlight") fs:SetAllPoints(row) fs:SetJustifyH("CENTER")
            local qname = t._qFilter~="All" and (" ("..t._qFilter..")") or ""
            fs:SetText("|cffaaaaaa No items matching \""..q.."\""..qname.." across any character.|r")
            c:SetHeight(50) return
        end

        for i,r in ipairs(results) do
            local btn=IconGet(c,i)
            IconPlace(btn,c,i)
            IconSetItem(btn,r.id,r.total,r.link)

            -- Show aggregate count in badge (overrides per-char count)
            btn._cnt:SetText(r.total > 1 and r.total or "")

            local id2,name2=r.id,r.name
            btn._onHover=function(self)
                DetailUpdate(t._detail,id2,name2)
            end
            btn._onLeave=function()
                t._detail:SetText("|cffaaaaaa Hover over an item to see who has it and where.|r")
            end
        end
        IconHideFrom(c,#results+1)

        -- Content height: enough rows for all results
        local rows=math.ceil(#results/ICON_COLS)
        c:SetHeight(math.max(200, rows*ICON_STEP+10))
    end
    t._refresh=Refresh
    Refresh()
end

-- ============================================================================
-- TAB: PROFESSIONS
-- ============================================================================


-- ============================================================================
-- TAB: GOLD
-- ============================================================================
local function BuildGold(t)
    if not t._sf then
        local _,c=MakeSF(t,-4,4) t._content=c t._sf=true
    end
    local chars=MTR.CharVault and MTR.CharVault.GetGoldSorted() or {}
    local c=t._content
    local ROW_H=26
    if #chars==0 then
        PoolHide(c,1)
        local row=PoolGet(c,1,890,ROW_H,ROW_H) RowBG(row,1)
        local fs=FS(row,"_msg","GameFontHighlight") fs:SetAllPoints(row) fs:SetJustifyH("CENTER")
        fs:SetText("|cffaaaaaa No character data yet.|r") c:SetHeight(50) return
    end
    local total=0 for _,ch in ipairs(chars) do total=total+(ch.gold or 0) end
    local richest=(chars[1] and chars[1].gold) or 1
    local hrow=PoolGet(c,1,890,ROW_H,ROW_H)
    if not hrow._bg then hrow._bg=hrow:CreateTexture(nil,"BACKGROUND") hrow._bg:SetAllPoints(hrow) end
    hrow._bg:SetColorTexture(0.14,0.11,0.03,0.9)
    local hfs=FS(hrow,"_line","GameFontNormal")
    hfs:SetPoint("LEFT",hrow,"LEFT",4,0) hfs:SetWidth(890) hfs:SetWordWrap(false)
    hfs:SetText(string.format("|cffd4af37TOTAL ACROSS %d ALTS|r   |cffd4af37%s|r",
        #chars,MTR.CharVault and MTR.CharVault.FormatGold(total) or "0g"))
    for i,ch in ipairs(chars) do
        local row=PoolGet(c,i+1,890,ROW_H,ROW_H) RowBG(row,i)
        local cc=ClassCol(ch.class)
        local bar=richest>0 and math.floor(((ch.gold or 0)/richest)*36) or 0
        local fs=FS(row,"_line","GameFontHighlightSmall")
        fs:SetPoint("LEFT",row,"LEFT",4,0) fs:SetWidth(890) fs:SetWordWrap(false)
        fs:SetText(string.format("%s%-16s|r  %-12s  Lv%2d  |cffd4af37%16s|r  |cff554400%s|r",
            cc,MTR.Trunc(ch.name or "?",16),MTR.Trunc(ch.class or "?",12),
            ch.level or 0,MTR.CharVault and MTR.CharVault.FormatGold(ch.gold or 0) or "0g",
            string.rep("█",bar)))
    end
    PoolHide(c,#chars+2)
    c:SetHeight(math.max(500,(#chars+1)*ROW_H+10))
end

-- ============================================================================
-- TAB: EQUIPMENT
-- ============================================================================
local GEAR_SLOTS={
    {1,"Head"},{2,"Neck"},{3,"Shoulders"},{5,"Chest"},
    {6,"Waist"},{7,"Legs"},{8,"Feet"},{9,"Wrists"},
    {10,"Hands"},{11,"Ring 1"},{12,"Ring 2"},{13,"Trinket 1"},
    {14,"Trinket 2"},{15,"Back"},{16,"Main Hand"},{17,"Off Hand"},{18,"Ranged"},
}
local function BuildEquipment(t)
    if not t._charDD then
        local lbl=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        lbl:SetPoint("TOPLEFT",t,"TOPLEFT",4,-4) lbl:SetText("Character:")
        local dd=CreateFrame("Frame","MekVaultEquipDD",t,"UIDropDownMenuTemplate")
        dd:SetPoint("LEFT",lbl,"RIGHT",2,0) UIDropDownMenu_SetWidth(dd,180) t._charDD=dd
        local avgFS=t:CreateFontString(nil,"OVERLAY","GameFontNormal")
        avgFS:SetPoint("LEFT",dd,"RIGHT",16,0) t._avgFS=avgFS
        local _,c=MakeSF(t,-30,4) t._content=c
        local function PopDD()
            local chars=MTR.CharVault and MTR.CharVault.GetAll() or {}
            UIDropDownMenu_Initialize(dd,function()
                for _,ch in ipairs(chars) do
                    local info=UIDropDownMenu_CreateInfo()
                    info.text=ch.name info.value=ch.key
                    info.func=function(self)
                        UIDropDownMenu_SetSelectedValue(dd,self.value)
                        t._selectedKey=self.value
                        if t._show then t._show() end
                    end
                    UIDropDownMenu_AddButton(info)
                end
            end)
            if chars[1] then UIDropDownMenu_SetSelectedValue(dd,chars[1].key) t._selectedKey=chars[1].key end
        end
        t._populateDD=PopDD
        t._show=function()
            local key=t._selectedKey
            local entry=key and MekTownRecruitDB.charVault and MekTownRecruitDB.charVault[key]
            local c2=t._content
            if not entry then
                PoolHide(c2,1)
                local row=PoolGet(c2,1,890,22,22) RowBG(row,1)
                local fs=FS(row,"_msg","GameFontHighlight") fs:SetAllPoints(row) fs:SetJustifyH("CENTER")
                fs:SetText("|cffaaaaaa No data for this character.|r") c2:SetHeight(50) t._avgFS:SetText("") return
            end
            t._avgFS:SetText("  Avg ilvl: |cffd4af37"..(entry.avgIlvl or 0).."|r")
            local gear=entry.gear or {}
            local idx=0
            for _,sd in ipairs(GEAR_SLOTS) do
                local sid,sname=sd[1],sd[2]
                local item=gear[sid]
                idx=idx+1
                local row=PoolGet(c2,idx,890,22,22) RowBG(row,idx)
                row:EnableMouse(true)   -- required for OnEnter to fire
                local fs=FS(row,"_line","GameFontHighlightSmall")
                fs:SetPoint("LEFT",row,"LEFT",4,0) fs:SetWidth(890) fs:SetWordWrap(false)
                if item and item.link then
                    local name=MTR.ItemLinkToName(item.link)
                    local qualColor="|cffffffff"
                    local _,_,rarity=GetItemInfo(item.link)
                    if rarity then
                        local qc=ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[rarity]
                        if qc then qualColor=string.format("|cff%02x%02x%02x",qc.r*255,qc.g*255,qc.b*255) end
                    end
                    fs:SetText(string.format("  %-14s  %s%s|r  |cffaaaaaa(%d ilvl)|r",
                        sname,qualColor,MTR.Trunc(name,40),item.ilvl or 0))
                    -- Native item tooltip on hover (our WAAAGH injection appends vault lines)
                    do local lnk=item.link
                        row:SetScript("OnEnter",function(self)
                            GameTooltip:SetOwner(self,"ANCHOR_RIGHT")
                            GameTooltip:SetHyperlink(lnk)
                            GameTooltip:Show()
                        end)
                        row:SetScript("OnLeave",function() GameTooltip:Hide() end)
                    end
                else
                    fs:SetText(string.format("  %-14s  |cff444444(empty)|r",sname))
                    row:SetScript("OnEnter",nil)
                    row:SetScript("OnLeave",nil)
                end
            end
            PoolHide(c2,idx+1) c2:SetHeight(math.max(500,idx*22+10))
        end
    end
    if t._populateDD then t._populateDD() end
    if t._show then t._show() end
end

-- ============================================================================
-- Shared: ledger date display helper
-- ============================================================================
local function LedgerRelativeAge(ts)
    ts = tonumber(ts) or 0
    if ts <= 0 then return "?" end
    local age = math.max(0, time() - ts)
    if age < 60 then
        return "just now"
    elseif age < 3600 then
        return tostring(math.max(1, math.floor(age / 60))) .. "m ago"
    elseif age < 86400 then
        local h = math.max(1, math.floor(age / 3600))
        local m = math.floor((age % 3600) / 60)
        if h < 6 and m > 0 then
            return tostring(h) .. "h " .. tostring(m) .. "m ago"
        end
        return tostring(h) .. "h ago"
    else
        local d = math.max(1, math.floor(age / 86400))
        local h = math.floor((age % 86400) / 3600)
        if d < 3 and h > 0 then
            return tostring(d) .. "d " .. tostring(h) .. "h ago"
        end
        return tostring(d) .. "d ago"
    end
end

local function LedgerDisplayDate(e)
    if type(e) ~= "table" then return "?" end

    local hasExactDate = e.hasExactDate == true or e.hasExactDate == 1 or e.hasExactDate == "1"
    if hasExactDate then
        return tostring(e.dateText or "?")
    end

    local dateText = tostring(e.dateText or "")
    local ts = tonumber(e.epoch) or 0
    if ts > 0 then
        return LedgerRelativeAge(ts)
    end

    if dateText ~= "" and string.lower(dateText) ~= "recent" then
        return dateText
    end
    if e.scanTS and e.scanTS ~= "" then
        return tostring(e.scanTS)
    end
    return "?"
end

local function LedgerTypeColor(txType)
    txType = string.lower(tostring(txType or ""))
    if txType == "deposit" then return 0.35, 0.90, 0.35 end
    if txType == "withdraw" then return 0.95, 0.35, 0.35 end
    if txType == "move" then return 0.90, 0.75, 0.30 end
    return 0.85, 0.85, 0.85
end

local function LedgerSafeText(s)
    return tostring(s or "?"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
end

-- ============================================================================
-- TAB: GUILD BANK  (officer-gated icon grid with search)
-- ============================================================================

local function BuildGuildBank(t)
    local function GetBankCategory(e)
        local itemID = e and (e.itemID or (e.link and tonumber(e.link:match("item:(%d+)"))))
        local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemID or (e and e.link) or 0)
        itemType = string.lower(tostring(itemType or ""))
        itemSubType = string.lower(tostring(itemSubType or ""))
        if itemType:find("weapon", 1, true) or itemType:find("armor", 1, true) then return "Equipment" end
        if itemType:find("consumable", 1, true) then return "Consumables" end
        if itemType:find("trade goods", 1, true) or itemType:find("tradegoods", 1, true) then return "Reagents" end
        if itemType:find("recipe", 1, true) then return "Recipes" end
        if itemType:find("gem", 1, true) then return "Gems" end
        if itemType:find("quest", 1, true) then return "Quest" end
        if itemSubType:find("parts", 1, true) or itemSubType:find("herb", 1, true) or itemSubType:find("cloth", 1, true) then return "Reagents" end
        return "Other"
    end

    if not t._built then
        t._built = true
        t._mode = t._mode or "Inventory"
        t._query = t._query or ""
        t._category = t._category or "All"
        t._range = t._range or ((MekTownRecruitDB.guildBankLedger and MekTownRecruitDB.guildBankLedger.meta and MekTownRecruitDB.guildBankLedger.meta.uiRange) or "1d")

        local top = CreateFrame("Frame", nil, t)
        top:SetPoint("TOPLEFT", t, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, 0)
        top:SetHeight(104)
        t._top = top

        local infoFS = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        infoFS:SetPoint("TOPLEFT", top, "TOPLEFT", 6, -4)
        infoFS:SetPoint("TOPRIGHT", top, "TOPRIGHT", -6, -4)
        infoFS:SetJustifyH("LEFT")
        infoFS:SetWordWrap(false)
        t._infoFS = infoFS

        local summaryFS = top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        summaryFS:SetPoint("TOPLEFT", top, "TOPLEFT", 6, -20)
        summaryFS:SetPoint("TOPRIGHT", top, "TOPRIGHT", -6, -20)
        summaryFS:SetJustifyH("LEFT")
        summaryFS:SetWordWrap(false)
        t._summaryFS = summaryFS

        local modeInv = CreateFrame("Button", nil, top, "UIPanelButtonTemplate")
        modeInv:SetSize(88, 22)
        modeInv:SetPoint("TOPLEFT", top, "TOPLEFT", 4, -42)
        modeInv:SetText("Inventory")
        modeInv:SetScript("OnClick", function()
            t._mode = "Inventory"
            if t._refresh then t._refresh() end
        end)
        t._modeInv = modeInv

        local modeLedger = CreateFrame("Button", nil, top, "UIPanelButtonTemplate")
        modeLedger:SetSize(72, 22)
        modeLedger:SetPoint("LEFT", modeInv, "RIGHT", 4, 0)
        modeLedger:SetText("Ledger")
        modeLedger:SetScript("OnClick", function()
            t._mode = "Ledger"
            if t._refresh then t._refresh() end
        end)
        t._modeLedger = modeLedger

        local searchLabel = top:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        searchLabel:SetPoint("LEFT", modeLedger, "RIGHT", 10, 0)
        searchLabel:SetText("Search:")

        local eb = CreateFrame("EditBox", nil, top, "InputBoxTemplate")
        eb:SetSize(220, 22)
        eb:SetPoint("LEFT", searchLabel, "RIGHT", 6, 0)
        eb:SetAutoFocus(false)
        eb:SetScript("OnTextChanged", function(s)
            t._query = s:GetText() or ""
            if t._refresh then t._refresh() end
        end)
        t._eb = eb

        local clr = CreateFrame("Button", nil, top, "UIPanelButtonTemplate")
        clr:SetSize(48, 22)
        clr:SetPoint("LEFT", eb, "RIGHT", 4, 0)
        clr:SetText("Clear")
        clr:SetScript("OnClick", function() eb:SetText("") end)

        local dd = CreateFrame("Frame", "MekVaultGBFilterDD", top, "UIDropDownMenuTemplate")
        dd:SetPoint("LEFT", clr, "RIGHT", -10, -2)
        UIDropDownMenu_SetWidth(dd, 118)
        UIDropDownMenu_Initialize(dd, function(self, level)
            local list = (t._mode == "Ledger") and {
                { text = "Last 24 hours", value = "1d" },
                { text = "Last 3 days", value = "3d" },
                { text = "Last 7 days", value = "7d" },
                { text = "Last 14 days", value = "14d" },
                { text = "Last 30 days", value = "30d" },
                { text = "All stored", value = "all" },
            } or {
                { text = "All categories", value = "All" },
                { text = "Consumables", value = "Consumables" },
                { text = "Equipment", value = "Equipment" },
                { text = "Reagents", value = "Reagents" },
                { text = "Recipes", value = "Recipes" },
                { text = "Gems", value = "Gems" },
                { text = "Other", value = "Other" },
            }
            for _, opt in ipairs(list) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = opt.text
                info.func = function()
                    if t._mode == "Ledger" then
                        t._range = opt.value
                        MekTownRecruitDB.guildBankLedger = MekTownRecruitDB.guildBankLedger or { entries = {}, meta = {} }
                        MekTownRecruitDB.guildBankLedger.meta = MekTownRecruitDB.guildBankLedger.meta or {}
                        MekTownRecruitDB.guildBankLedger.meta.uiRange = t._range
                    else
                        t._category = opt.value
                    end
                    UIDropDownMenu_SetSelectedValue(dd, opt.value)
                    UIDropDownMenu_SetText(dd, opt.text)
                    if t._refresh then t._refresh() end
                end
                info.value = opt.value
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        t._dd = dd

        local quickValues = {
            { key = "1d", text = "1D" },
            { key = "3d", text = "3D" },
            { key = "7d", text = "7D" },
            { key = "14d", text = "14D" },
            { key = "30d", text = "30D" },
            { key = "all", text = "ALL" },
        }
        t._quickBtns = {}
        local prevBtn = nil
        for i, opt in ipairs(quickValues) do
            local b = CreateFrame("Button", nil, top, "UIPanelButtonTemplate")
            b:SetSize(i == 6 and 40 or 34, 20)
            if prevBtn then
                b:SetPoint("LEFT", prevBtn, "RIGHT", 3, 0)
            else
                b:SetPoint("TOPLEFT", top, "TOPLEFT", 252, -72)
            end
            b._plainText = opt.text
            b:SetText(opt.text)
            b:SetScript("OnClick", function()
                t._range = opt.key
                MekTownRecruitDB.guildBankLedger = MekTownRecruitDB.guildBankLedger or { entries = {}, meta = {} }
                MekTownRecruitDB.guildBankLedger.meta = MekTownRecruitDB.guildBankLedger.meta or {}
                MekTownRecruitDB.guildBankLedger.meta.uiRange = t._range
                UIDropDownMenu_SetSelectedValue(dd, opt.key)
                UIDropDownMenu_SetText(dd, ({ ["1d"]="Last 24 hours", ["3d"]="Last 3 days", ["7d"]="Last 7 days", ["14d"]="Last 14 days", ["30d"]="Last 30 days", ["all"]="All stored" })[opt.key] or opt.text)
                if t._refresh then t._refresh() end
            end)
            t._quickBtns[#t._quickBtns + 1] = b
            prevBtn = b
        end

        local exportBtn = CreateFrame("Button", nil, top, "UIPanelButtonTemplate")
        exportBtn:SetSize(88, 22)
        exportBtn:SetPoint("TOPRIGHT", top, "TOPRIGHT", -114, -42)
        exportBtn:SetText("Export Txt")
        exportBtn:SetScript("OnClick", function()
            if t._exportLedger then t._exportLedger() end
        end)
        exportBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:AddLine("Export Current Ledger View")
            GameTooltip:AddLine("|cffaaaaaaOpens a copy-ready plain text export for the current filters and search.|r", 1, 1, 1)
            GameTooltip:Show()
        end)
        exportBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        t._exportBtn = exportBtn

        if MTR.isOfficer then
            local scanBtn = CreateFrame("Button", nil, top, "UIPanelButtonTemplate")
            scanBtn:SetSize(110, 22)
            scanBtn:SetPoint("TOPRIGHT", top, "TOPRIGHT", 0, -42)
            scanBtn:SetText("|cffd4af37Scan Now|r")
            scanBtn:SetScript("OnClick", function()
                if MTR.GuildBankScan and MTR.GuildBankScan.DoScan then
                    MTR.GuildBankScan.DoScan()
                    if t._infoFS then
                        t._infoFS:SetText("|cffaaaaaaScanning bank inventory + ledger... open each tab once for best results.|r")
                    end
                end
            end)
            scanBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
                GameTooltip:AddLine("Scan Guild Bank + Ledger")
                GameTooltip:AddLine("|cffaaaaaaRequires the guild bank to already be open.|r", 1, 1, 1)
                GameTooltip:AddLine("|cffaaaaaaReads current item tabs and limited transaction logs, then syncs them.|r", 1, 1, 1)
                GameTooltip:Show()
            end)
            scanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        local sep = t:CreateTexture(nil, "ARTWORK")
        sep:SetColorTexture(0.25, 0.25, 0.4, 0.5)
        sep:SetHeight(1)
        sep:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 0, 36)
        sep:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, 36)
        local detail = MakeDetailStrip(t, 8)
        t._detail = detail
        local _, c = MakeSF(t, -112, 50)
        t._content = c
    end

    local bank = MekTownRecruitDB.guildBank or {}
    local ledger = (MekTownRecruitDB.guildBankLedger and MekTownRecruitDB.guildBankLedger.entries) or {}
    local meta = MTR.GuildBankLedger and MTR.GuildBankLedger.GetMeta and MTR.GuildBankLedger.GetMeta() or {}

    if t._mode == "Ledger" then
        UIDropDownMenu_SetText(t._dd, ({ ["1d"]="Last 24 hours", ["3d"]="Last 3 days", ["7d"]="Last 7 days", ["14d"]="Last 14 days", ["30d"]="Last 30 days", ["all"]="All stored" })[t._range or "1d"] or "Last 24 hours")
        t._infoFS:SetText(string.format("|cffaaaaaa Ledger: |cffd4af37%d entries|r  |cffaaaaaaretained up to 30 days • search matches actor/item/action/tab/scanner • last sync %s by %s|r", #ledger, meta.lastSyncAt or meta.lastScanAt or "never", meta.lastSyncFrom or meta.lastScanBy or "?"))
    else
        if t._summaryFS then t._summaryFS:SetText("|cffaaaaaaUse search + category filtering to browse the current guild bank snapshot.|r") end
        UIDropDownMenu_SetText(t._dd, t._category == "All" and "All categories" or (t._category or "All categories"))
        if #bank > 0 then
            local sample = bank[1]
            t._infoFS:SetText(string.format("|cffaaaaaa Snapshot: |cffd4af37%d items|r  |cffaaaaaa— scanned by |r|cffffd700%s|r |cffaaaaaaat %s|r  |cff444444(auto-updates when anyone opens the bank)|r", #bank, sample and sample.scannedBy or "?", sample and sample.updated or "?"))
        else
            t._infoFS:SetText("|cffaaaaaaNo snapshot yet — an officer needs to open the guild bank once.|r")
        end
    end

    local function Refresh()
        if MTR.GuildBankScan then MTR.GuildBankScan.dirty = false end
        if MTR.GuildBankLedger then MTR.GuildBankLedger.dirty = false end
        local q = string.lower(t._query or "")
        local c = t._content
        local detail = t._detail
        IconHideFrom(c, 1)
        PoolHide(c, 1)

        if t._mode == "Ledger" then
            local rangeMap = { ["1d"] = 1, ["3d"] = 3, ["7d"] = 7, ["14d"] = 14, ["30d"] = 30, ["all"] = 9999 }
            local days = rangeMap[t._range or "1d"] or 1
            local cutoff = time() - (days * 86400)
            local rows = {}
            for _, e in ipairs((MTR.GuildBankLedger and MTR.GuildBankLedger.GetEntries and MTR.GuildBankLedger.GetEntries()) or ledger) do
                local hay = string.lower(table.concat({
                    tostring(e.dateText or ""), tostring(e.actor or ""), tostring(e.txType or ""),
                    tostring(e.itemName or ""), tostring(e.tab1 or ""), tostring(e.tab2 or ""), tostring(e.scanBy or ""), tostring(e.count or "")
                }, " "))
                if (days >= 9999 or (tonumber(e.epoch) or 0) >= cutoff) and (q == "" or hay:find(q, 1, true)) then
                    rows[#rows + 1] = e
                end
            end
            table.sort(rows, function(a, b) return (tonumber(a.epoch) or 0) > (tonumber(b.epoch) or 0) end)
            t._ledgerRows = rows
            do
                local deposits, withdrawals, moved, actors = 0, 0, 0, {}
                for _, e in ipairs(rows) do
                    local tx = string.lower(tostring(e.txType or ""))
                    if tx == "deposit" then deposits = deposits + 1 elseif tx == "withdraw" then withdrawals = withdrawals + 1 else moved = moved + 1 end
                    local actor = tostring(e.actor or "?")
                    actors[actor] = (actors[actor] or 0) + 1
                end
                local topActor, topCount = "-", 0
                for actor, n in pairs(actors) do if n > topCount then topActor, topCount = actor, n end end
                if t._summaryFS then
                    t._summaryFS:SetText(string.format("|cffaaaaaaView:|r |cffd4af37%d rows|r  |cff55cc55%d deposits|r  |cffff6666%d withdrawals|r  |cffd4af37%d other|r  |cffaaaaaatop actor:|r |cffffd700%s|r", #rows, deposits, withdrawals, moved, topActor))
                end
            end
            if #rows == 0 then
                local row = PoolGet(c, 1, 890, 30, 30)
                RowBG(row, 1)
                local fs = FS(row, "_msg", "GameFontHighlight")
                fs:SetAllPoints(row)
                fs:SetJustifyH("CENTER")
                fs:SetText("|cffaaaaaaNo ledger entries match the current search/range.|r\n|cff666666Try 3D / 7D, clear search, or run Scan Now.|r")
                c:SetHeight(50)
                if detail then detail:SetText("|cffaaaaaaNo rows for the current view. Try a wider range, clear search, or run a fresh ledger scan.|r") end
                return
            end
            local header = PoolGet(c, 1, 890, 22, 24)
            if not header._bg then header._bg = header:CreateTexture(nil, "BACKGROUND") header._bg:SetAllPoints(header) end
            header._bg:SetColorTexture(0.16, 0.06, 0.06, 0.90)
            local h1 = FS(header, "_h1", "GameFontNormalSmall") h1:SetPoint("LEFT", header, "LEFT", 8, 0) h1:SetWidth(120) h1:SetJustifyH("LEFT") h1:SetText("Date")
            local h2 = FS(header, "_h2", "GameFontNormalSmall") h2:SetPoint("LEFT", header, "LEFT", 134, 0) h2:SetWidth(110) h2:SetJustifyH("LEFT") h2:SetText("Player")
            local h3 = FS(header, "_h3", "GameFontNormalSmall") h3:SetPoint("LEFT", header, "LEFT", 248, 0) h3:SetWidth(90) h3:SetJustifyH("LEFT") h3:SetText("Action")
            local h4 = FS(header, "_h4", "GameFontNormalSmall") h4:SetPoint("LEFT", header, "LEFT", 340, 0) h4:SetWidth(300) h4:SetJustifyH("LEFT") h4:SetText("Item")
            local h5 = FS(header, "_h5", "GameFontNormalSmall") h5:SetPoint("LEFT", header, "LEFT", 646, 0) h5:SetWidth(55) h5:SetJustifyH("CENTER") h5:SetText("Qty")
            local h6 = FS(header, "_h6", "GameFontNormalSmall") h6:SetPoint("LEFT", header, "LEFT", 706, 0) h6:SetWidth(120) h6:SetJustifyH("LEFT") h6:SetText("Tab")
            local h7 = FS(header, "_h7", "GameFontNormalSmall") h7:SetPoint("LEFT", header, "LEFT", 824, 0) h7:SetWidth(60) h7:SetJustifyH("LEFT") h7:SetText("By")
            for i, e in ipairs(rows) do
                local row = PoolGet(c, i + 1, 890, 24, 24)
                RowBG(row, i)
                local dateFS = FS(row, "_date", "GameFontHighlightSmall")
                dateFS:SetPoint("LEFT", row, "LEFT", 8, 0)
                dateFS:SetWidth(120)
                dateFS:SetTextColor(0.82, 0.82, 0.82)
                dateFS:SetJustifyH("LEFT")
                dateFS:SetText(LedgerDisplayDate(e))
                local actorFS = FS(row, "_actor", "GameFontHighlightSmall")
                actorFS:SetPoint("LEFT", row, "LEFT", 134, 0)
                actorFS:SetWidth(110)
                actorFS:SetTextColor(1.00, 0.96, 0.88)
                actorFS:SetJustifyH("LEFT")
                actorFS:SetText(e.actor or "?")
                local typeFS = FS(row, "_type", "GameFontHighlightSmall")
                typeFS:SetPoint("LEFT", row, "LEFT", 248, 0)
                typeFS:SetWidth(90)
                do local r, g, b = LedgerTypeColor(e.txType) typeFS:SetTextColor(r, g, b) end
                typeFS:SetJustifyH("LEFT")
                typeFS:SetText(tostring(e.txType or "?"))
                local itemFS = FS(row, "_item", "GameFontNormalSmall")
                itemFS:SetPoint("LEFT", row, "LEFT", 340, 0)
                itemFS:SetWidth(300)
                itemFS:SetJustifyH("LEFT")
                itemFS:SetText((e.itemLink and e.itemLink) or (e.itemName or "?"))
                local countFS = FS(row, "_count", "GameFontHighlightSmall")
                countFS:SetPoint("LEFT", row, "LEFT", 646, 0)
                countFS:SetWidth(55)
                countFS:SetTextColor(0.92, 0.92, 0.92)
                countFS:SetJustifyH("CENTER")
                countFS:SetText(e.count or 0)
                local tabFS = FS(row, "_tab", "GameFontHighlightSmall")
                tabFS:SetPoint("LEFT", row, "LEFT", 706, 0)
                tabFS:SetWidth(120)
                tabFS:SetTextColor(0.75, 0.75, 0.75)
                tabFS:SetJustifyH("LEFT")
                tabFS:SetText((e.tab2 and e.tab2 > 0) and ("T" .. e.tab1 .. " → T" .. e.tab2) or ("Tab " .. tostring(e.tab1 or "?")))
                local byFS = FS(row, "_by", "GameFontHighlightSmall")
                byFS:SetPoint("LEFT", row, "LEFT", 824, 0)
                byFS:SetWidth(60)
                byFS:SetTextColor(0.68, 0.68, 0.68)
                byFS:SetJustifyH("LEFT")
                byFS:SetText(e.scanBy or "?")
                row:SetScript("OnEnter", function(self)
                    if self._bg then self._bg:SetColorTexture(0.24, 0.12, 0.04, 0.55) end
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(LedgerSafeText(e.itemName or "?"), 1, 0.82, 0)
                    do local r, g, b = LedgerTypeColor(e.txType) GameTooltip:AddDoubleLine("Action", LedgerSafeText(e.txType or "?"), 0.8, 0.8, 0.8, r, g, b) end
                    GameTooltip:AddDoubleLine("Player", LedgerSafeText(e.actor or "?"), 0.8, 0.8, 0.8, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Quantity", tostring(e.count or 0), 0.8, 0.8, 0.8, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Tab", LedgerSafeText(((e.tab2 and e.tab2 > 0) and ("T" .. e.tab1 .. " -> T" .. e.tab2) or ("Tab " .. tostring(e.tab1 or "?")))), 0.8, 0.8, 0.8, 1, 1, 1)
                    GameTooltip:AddDoubleLine("Shown as", LedgerDisplayDate(e), 0.8, 0.8, 0.8, 1, 0.96, 0.88)
                    if tonumber(e.epoch) and tonumber(e.epoch) > 0 then
                        GameTooltip:AddDoubleLine("Captured", date("%Y-%m-%d %H:%M", tonumber(e.epoch)), 0.8, 0.8, 0.8, 1, 1, 1)
                    end
                    GameTooltip:AddDoubleLine("Scanner", LedgerSafeText(e.scanBy or "?"), 0.8, 0.8, 0.8, 1, 1, 1)
                    if e.scanTS and e.scanTS ~= "" then
                        GameTooltip:AddDoubleLine("Synced at", LedgerSafeText(e.scanTS), 0.8, 0.8, 0.8, 1, 1, 1)
                    end
                    GameTooltip:Show()
                    if detail then
                        detail:SetText(string.format("|cffd4af37%s|r  |cffaaaaaa%s by|r %s  |cffaaaaaaqty|r %s  |cffaaaaaatab|r %s  |cffaaaaaashown as|r %s", LedgerSafeText(e.itemName or "?"), LedgerSafeText(e.txType or "?"), LedgerSafeText(e.actor or "?"), tostring(e.count or 0), LedgerSafeText(((e.tab2 and e.tab2 > 0) and ("T" .. e.tab1 .. " -> T" .. e.tab2) or ("Tab " .. tostring(e.tab1 or "?")))), LedgerDisplayDate(e)))
                    end
                end)
                row:SetScript("OnLeave", function(self)
                    RowBG(self, i + 1)
                    GameTooltip:Hide()
                    if detail then detail:SetText("|cffaaaaaaHover a ledger row to inspect the synced guild-bank moderation history.|r") end
                end)
            end
            c:SetHeight(math.max(220, (#rows + 1) * 24 + 8))
            if detail then detail:SetText("|cffaaaaaaHover a ledger row to inspect the synced guild-bank moderation history.|r") end
            return
        end

        local matches = {}
        local category = t._category or "All"
        for _, e in ipairs(bank) do
            local nameMatch = (q == "") or (e.name and string.lower(e.name):find(q, 1, true))
            local catMatch = (category == "All") or (GetBankCategory(e) == category)
            if nameMatch and catMatch then
                matches[#matches + 1] = e
            end
        end
        table.sort(matches, function(a, b)
            if a.tab ~= b.tab then return (a.tab or 0) < (b.tab or 0) end
            return (a.name or "") < (b.name or "")
        end)
        if #matches == 0 then
            local row = PoolGet(c, 1, 890, 30, 30)
            RowBG(row, 1)
            local fs = FS(row, "_msg", "GameFontHighlight")
            fs:SetAllPoints(row)
            fs:SetJustifyH("CENTER")
            fs:SetText("|cffaaaaaaNo bank items match the current search/filter.|r")
            c:SetHeight(50)
            if detail then detail:SetText("|cffaaaaaaUse search + category filter to find consumables, equipment, reagents and more.|r") end
            return
        end
        for i, r in ipairs(matches) do
            local btn = IconGet(c, i)
            IconPlace(btn, c, i)
            local id = r.itemID or (r.link and tonumber(r.link:match("item:(%d+)"))) or nil
            IconSetItem(btn, id, r.count, r.link)
            btn._cnt:SetText(r.count and r.count > 1 and r.count or "")
            local n2 = r.name
            local tab2 = r.tabName or ("Tab " .. (r.tab or "?"))
            local categoryName = GetBankCategory(r)
            btn._onHover = function(self)
                if detail then
                    detail:SetText(string.format("|cffd4af37%s|r  —  |cffffd700%s|r  |cff88ff88%dx|r  |cffaaaaaa%s • scanned by %s on %s|r", n2 or "?", tab2, r.count or 0, categoryName, r.scannedBy or "?", r.updated or "?"))
                end
            end
            btn._onLeave = function()
                if detail then detail:SetText("|cffaaaaaaHover an item to see its guild bank location and category.|r") end
            end
        end
        IconHideFrom(c, #matches + 1)
        local rows = math.ceil(#matches / ICON_COLS)
        c:SetHeight(math.max(220, rows * ICON_STEP + 10))
        if detail then detail:SetText("|cffaaaaaaHover an item to see its guild bank location and category.|r") end
    end

    t._exportLedger = function()
        if t._mode ~= "Ledger" then
            MTR.MP("Open the Ledger view first to export the current filtered results.")
            return
        end
        local rows = t._ledgerRows or {}
        if not rows or #rows == 0 then
            MTR.MP("No ledger rows match the current filters.")
            return
        end
        local lines = {}
        lines[#lines + 1] = "MekTown Guild Bank Ledger Export"
        lines[#lines + 1] = string.format("Generated: %s", date("%Y-%m-%d %H:%M"))
        lines[#lines + 1] = string.format("Filter: %s", ({ ["1d"]="Last 24 hours", ["3d"]="Last 3 days", ["7d"]="Last 7 days", ["14d"]="Last 14 days", ["30d"]="Last 30 days", ["all"]="All stored" })[t._range or "1d"] or "Last 24 hours")
        lines[#lines + 1] = string.format("Search: %s", (t._query and t._query ~= "") and t._query or "(none)")
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Date	Player	Action	Item	Qty	Tab	Scanner"
        for _, e in ipairs(rows) do
            lines[#lines + 1] = table.concat({
                LedgerSafeText(LedgerDisplayDate(e)),
                LedgerSafeText(e.actor or "?"),
                LedgerSafeText(e.txType or "?"),
                LedgerSafeText(e.itemName or "?"),
                tostring(e.count or 0),
                LedgerSafeText(((e.tab2 and e.tab2 > 0) and ("T" .. e.tab1 .. " -> T" .. e.tab2) or ("Tab " .. tostring(e.tab1 or "?")))),
                LedgerSafeText(e.scanBy or "?")
            }, "	")
        end
        if MTR.OpenEditPopup then
            MTR.OpenEditPopup("Ledger Export (.txt copy)", table.concat(lines, "\n"), function() end)
        end
        MTR.MP(string.format("Prepared ledger export for %d visible row%s.", #rows, #rows == 1 and "" or "s"))
    end

    t._refresh = function()
        Refresh()
        local modeIsLedger = t._mode == "Ledger"
        if t._exportBtn then
            if modeIsLedger then t._exportBtn:Show() else t._exportBtn:Hide() end
        end
        if t._quickBtns then
            for _, b in ipairs(t._quickBtns) do
                if modeIsLedger then b:Show() else b:Hide() end
                local txt = b._plainText or b:GetText()
                if modeIsLedger and t._range == ((txt == "ALL") and "all" or string.lower(txt)) then
                    b:SetText("|cffd4af37" .. txt .. "|r")
                else
                    b:SetText(txt)
                end
            end
        end
    end

    MTR.TickAdd("gb_ui_poll", 2, function()
        local tf = _tabFrames and _tabFrames["Guild Bank"]
        if tf and tf:IsShown() and ((MTR.GuildBankScan and MTR.GuildBankScan.dirty) or (MTR.GuildBankLedger and MTR.GuildBankLedger.dirty)) then
            if tf._refresh then tf._refresh() end
        end
    end)

    t._refresh()
end

-- ============================================================================
-- GET_ITEM_INFO_RECEIVED  — refresh any open icon tab when new data arrives
-- ============================================================================
local infoFrame=CreateFrame("Frame")
infoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
infoFrame:SetScript("OnEvent",function(_,_,itemID)
    if not MTR.initialized then return end
    -- Debounce: batch refreshes triggered by the same scan
    MTR.TickRemove("cv_info_refresh")
    MTR.TickAdd("cv_info_refresh",0.5,function()
        MTR.TickRemove("cv_info_refresh")
        -- Update name cache in CharVault
        if MTR.CharVault and MTR.CharVault._nameCache then
            local name=GetItemInfo(itemID)
            if name then MTR.CharVault._nameCache[itemID]=name end
        end
        -- Rebuild tooltip index with any newly available names
        if MTR.CharVault then MTR.CharVault.RebuildIndex() end
        -- Re-render whichever icon tab is currently visible
        local win = MTR.vaultWin
        if not win or not win:IsShown() then return end
        for _, tname in ipairs({"Browse Bags","Item Search","Guild Bank"}) do
            local fr = _tabFrames[tname]
            if fr and fr:IsShown() then
                if fr._show   then fr._show() end
                if fr._refresh then fr._refresh() end
            end
        end
    end)
end)

-- ============================================================================
-- TAB REGISTRY  (module-level so event handler can reference them)
-- ============================================================================
local _tabFrames   = {}
local _tabBuilders = {}
local _tabBuilt    = {}

-- ============================================================================
-- WINDOW
-- ============================================================================
function MTR.OpenCharVault()
    if not vaultWin then
        vaultWin=CreateFrame("Frame","MekTownVaultWindow",UIParent)
        vaultWin:SetSize(VAULT_W,VAULT_H)
        vaultWin:SetPoint("CENTER")
        vaultWin:SetFrameStrata("MEDIUM")
        vaultWin:SetBackdrop({
            bgFile="",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=false,tileSize=0,edgeSize=32,
            insets={left=8,right=8,top=8,bottom=8},
        })
        vaultWin:SetBackdropColor(0,0,0,0)
        -- Background: solid base + wallpaper directly on the frame
        do local _bt=vaultWin:CreateTexture(nil,"BACKGROUND")
        _bt:SetTexture("Interface\\Buttons\\WHITE8x8") _bt:SetAllPoints(vaultWin) _bt:SetVertexColor(0.04,0.01,0.01,1.0) end
        do local _wp=vaultWin:CreateTexture(nil,"ARTWORK")
        _wp:SetTexture("Interface\\AddOns\\MekTownRecruit\\MTCWallpaper") _wp:SetAllPoints(vaultWin) _wp:SetAlpha(0.35)
        -- Flip V coordinates to correct upside-down orientation of the TGA file.
        _wp:SetTexCoord(0, 1, 1, 0) end
        vaultWin:EnableMouse(true) vaultWin:SetMovable(true)
        vaultWin:RegisterForDrag("LeftButton")
        vaultWin:SetScript("OnDragStart",vaultWin.StartMoving)
        vaultWin:SetScript("OnDragStop", vaultWin.StopMovingOrSizing)
        vaultWin:Hide()

        local xBtn=CreateFrame("Button",nil,vaultWin,"UIPanelCloseButton")
        xBtn:SetPoint("TOPRIGHT",vaultWin,"TOPRIGHT",-4,-4)
        xBtn:SetScript("OnClick",function() vaultWin:Hide() end)

        -- Back to Config button — closes vault and reopens the config window
        local backBtn=CreateFrame("Button",nil,vaultWin,"UIPanelButtonTemplate")
        backBtn:SetSize(136,24)
        backBtn:SetPoint("TOPRIGHT",vaultWin,"TOPRIGHT",-44,-6)
        backBtn:SetText("|cffaaaaaaBack to Config|r")
        backBtn:SetScript("OnClick",function()
            vaultWin:Hide()
            if MTR.OpenConfig then MTR.OpenConfig() end
        end)

        -- Vault title bar: standard UI-DialogBox-Header tinted blood-red
        local vTitleBar = vaultWin:CreateTexture(nil, "OVERLAY")
        vTitleBar:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
        vTitleBar:SetTexCoord(0,1,0.2,0.8)
        vTitleBar:SetVertexColor(0.55, 0.03, 0.03, 1.0)
        vTitleBar:SetHeight(26)
        vTitleBar:SetPoint("TOPLEFT",  vaultWin, "TOPLEFT",  9, -2)
        vTitleBar:SetPoint("TOPRIGHT", vaultWin, "TOPRIGHT", -9, -2)
        local vTitleEdge = vaultWin:CreateTexture(nil, "OVERLAY")
        vTitleEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
        vTitleEdge:SetVertexColor(0.80, 0.12, 0.02, 1.0)
        vTitleEdge:SetHeight(2)
        vTitleEdge:SetPoint("TOPLEFT",  vaultWin, "TOPLEFT",  9, -26)
        vTitleEdge:SetPoint("TOPRIGHT", vaultWin, "TOPRIGHT", -9, -26)
        local hdr=vaultWin:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
        hdr:SetPoint("TOPLEFT",vaultWin,"TOPLEFT",12,-7)
        hdr:SetText("|cffff2020MekTown|r  |cffd4af37\226\152\133 Vault|r  |cffaaaaaa v"..(MTR.VERSION or "2.0.0-beta").."|r")

        local sub=vaultWin:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        sub:SetPoint("TOPLEFT",vaultWin,"TOPLEFT",10,-32)
        sub:SetText(
            "|cffaaaaaa Log in on each alt to populate  •  Open bank on each alt for bank data  "..
            "•  Hover any icon for details  •  Shift-click any icon to link in chat|r")

        local sep=vaultWin:CreateTexture(nil,"ARTWORK")
        sep:SetColorTexture(0.3,0.3,0.5,0.5) sep:SetHeight(1)
        sep:SetPoint("TOPLEFT",vaultWin,"TOPLEFT",10,-50)
        sep:SetPoint("TOPRIGHT",vaultWin,"TOPRIGHT",-10,-52)

        -- ── Tabs ───────────────────────────────────────────────────────────
        local TABS={"Overview","Browse Bags","Item Search",
                    "Gold","Equipment","Guild Bank","Guild Tree"}
        local tabBtns={}
        for i,tname in ipairs(TABS) do
            local f=CreateFrame("Frame",nil,vaultWin)
            f:SetPoint("TOPLEFT",    vaultWin,"TOPLEFT",    10,-80)
            f:SetPoint("BOTTOMRIGHT",vaultWin,"BOTTOMRIGHT",-10,10)
            f:Hide()
            _tabFrames[tname]=f

            local bw = tname=="Guild Tree" and 84 or tname=="Guild Bank" and 96 or tname=="Browse Bags" and 96 or 90
            local btn=CreateFrame("Button",nil,vaultWin,"UIPanelButtonTemplate")
            btn:SetSize(bw,24)
            if i==1 then btn:SetPoint("TOPLEFT",vaultWin,"TOPLEFT",10,-56)
            else          btn:SetPoint("LEFT",tabBtns[i-1],"RIGHT",3,0) end
            if tname=="Guild Bank" then
                btn:SetText("|cffd4af37Guild Bank|r")
            else
                btn:SetText(tname)
            end
            local key=tname
            btn:SetScript("OnClick",function()
                for _,fr in pairs(_tabFrames) do fr:Hide() end
                if _tabBuilders[key] and not _tabBuilt[key] then
                    _tabBuilders[key](_tabFrames[key])
                    _tabBuilt[key]=true
                end
                _tabFrames[key]:Show()
            end)
            tabBtns[i]=btn
        end

        -- Auto-refresh live tabs
        _tabFrames["Overview"]:SetScript("OnShow",    function(s) BuildOverview(s)  end)
        _tabFrames["Gold"]:SetScript("OnShow",         function(s) BuildGold(s)      end)
        _tabFrames["Equipment"]:SetScript("OnShow",    function(s) BuildEquipment(s) end)
        _tabFrames["Browse Bags"]:SetScript("OnShow",  function(s)
            if s._show then s._show() end
        end)
        _tabFrames["Item Search"]:SetScript("OnShow",  function(s)
            if s._refresh then s._refresh() end
        end)

        _tabBuilders["Overview"]    = BuildOverview
        _tabBuilders["Browse Bags"] = BuildBrowseBags
        _tabBuilders["Item Search"] = BuildItemSearch
        _tabBuilders["Gold"]        = BuildGold
        _tabBuilders["Equipment"]   = BuildEquipment
        _tabBuilders["Guild Bank"]  = BuildGuildBank
        _tabBuilders["Guild Tree"] = MTR.BuildGuildTreeTab

        -- Build Overview immediately (default tab)
        BuildOverview(_tabFrames["Overview"])
        _tabBuilt["Overview"]=true
        _tabFrames["Overview"]:Show()

        vaultWin._showTab=function(name)
            for _,fr in pairs(_tabFrames) do fr:Hide() end
            if _tabBuilders[name] and not _tabBuilt[name] then
                _tabBuilders[name](_tabFrames[name])
                _tabBuilt[name]=true
            end
            if _tabFrames[name] then _tabFrames[name]:Show() end
        end

        MTR.vaultWin=vaultWin
    end

    if vaultWin:IsShown() then vaultWin:Hide() return end
    vaultWin._showTab("Overview")
    vaultWin:Show()
end
