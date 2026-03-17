-- ============================================================================
-- CharVault.lua  v9.1
-- MekTown Choppa'z — Per-character data engine
--
-- ARCHITECTURE (following BagSync best-practice, MekTown flavour)
-- ─────────────────────────────────────────────────────────────────
-- Storage (MekTownRecruitDB.charVault["Name-Realm"]):
--   meta        — name, realm, class, race, level, zone, gold, avgIlvl, lastSeen
--   items       — { [itemID] = {bags=N, bank=N, mail=N} }  ← compact, never stale
--   professions — array of { name, rank, max, primary }
--   gear        — { [slotID] = {link, ilvl} }
--
-- Storing itemID→counts (not bag/slot coords) means:
--   • Data never goes stale when items are moved between slots
--   • File stays small even across many alts
--   • Cross-alt totals are trivial to compute
--   • Tooltip lookup is O(1) via a flat itemID index
--
-- Events hooked:
--   PLAYER_LOGIN       — full scan 2s after login
--   BAG_UPDATE         — debounced 3s rescan (throttled, never fires in combat)
--   BANKFRAME_OPENED   — bank scan
--   MAIL_INBOX_OPENED  — mail scan
--   PLAYER_MONEY       — live gold update
--   ZONE_CHANGED*      — live zone update
--
-- Tooltip injection:
--   Hooks GameTooltip:SetBagItem, SetInventoryItem, SetHyperlink
--   Appends "|cffff2020WAAAGH!|r  Char: Nx  Char: Nx  Total: Nx" lines
-- ============================================================================
local MTR = MekTownRecruit

local CV = {}
MTR.CharVault = CV

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local PRIMARY_PROFS = {
    Alchemy=true, Blacksmithing=true, Enchanting=true, Engineering=true,
    Herbalism=true, Inscription=true, Jewelcrafting=true, Leatherworking=true,
    Mining=true, Skinning=true, Tailoring=true,
}
local SECONDARY_PROFS = {
    Cooking=true, ["First Aid"]=true, Fishing=true, Riding=true,
}
local ILVL_SLOTS = { 1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18 }

-- MekTown brand colour used in tooltips
local BRAND = "|cffff2020WAAAGH!|r"
-- Separator line shown between normal tooltip lines and our data
local TT_SEP = "|cff333333" .. string.rep("─", 28) .. "|r"

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

local function CharKey()
    local name  = UnitName("player")  or "Unknown"
    local realm = GetRealmName()      or "Unknown"
    return name .. "-" .. realm, name, realm
end

-- Extract itemID from any item link or direct integer
local function ToItemID(linkOrID)
    if type(linkOrID) == "number" then return linkOrID end
    if type(linkOrID) ~= "string" then return nil end
    local id = linkOrID:match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- Ensure the vault entry for this character exists and has all required tables
local function EnsureEntry(key, name, realm)
    if not MekTownRecruitDB.charVault then MekTownRecruitDB.charVault = {} end
    if not MekTownRecruitDB.charVault[key] then
        MekTownRecruitDB.charVault[key] = {
            key=key, name=name, realm=realm,
            meta={}, items={}, professions={}, gear={},
        }
    end
    local e = MekTownRecruitDB.charVault[key]
    if not e.items       then e.items       = {} end
    if not e.professions then e.professions = {} end
    if not e.gear        then e.gear        = {} end
    if not e.meta        then e.meta        = {} end
    return e
end

-- ============================================================================
-- GOLD FORMATTER  (public — used by UI)
-- ============================================================================
function CV.FormatGold(copper)
    if not copper or copper == 0 then return "0g" end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if     g > 0 then return string.format("%dg %02ds %02dc", g, s, c)
    elseif s > 0 then return string.format("%ds %02dc", s, c)
    else              return string.format("%dc", c) end
end

-- ============================================================================
-- SCANNERS
-- ============================================================================

local function ScanProfessions()
    local profs = {}
    local n = GetNumSkillLines()
    for i = 1, n do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if name and not isHeader and (PRIMARY_PROFS[name] or SECONDARY_PROFS[name]) then
            profs[#profs+1] = {
                name    = name,
                rank    = rank    or 0,
                max     = maxRank or 0,
                primary = PRIMARY_PROFS[name] and true or false,
            }
        end
    end
    return profs
end

local function ScanGear()
    local gear = {}
    local total, count = 0, 0
    for _, slot in ipairs(ILVL_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local _, _, _, ilvl = GetItemInfo(link)
            local iv = tonumber(ilvl) or 0
            gear[slot] = { link=link, ilvl=iv }
            total = total + iv; count = count + 1
        end
    end
    return gear, count > 0 and math.floor(total/count) or 0
end

-- Core bag scanner — returns { [itemID] = count } for bags 0-4
local function ScanBagItems()
    local counts = {}
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local _, qty, _, _, _, _, link = GetContainerItemInfo(bag, slot)
            local id = ToItemID(link)
            if id and qty and qty > 0 then
                counts[id] = (counts[id] or 0) + qty
            end
        end
    end
    return counts
end

-- Core bank scanner — returns { [itemID] = count }
-- Only valid when BANKFRAME_OPENED has fired (bank bags aren't loaded otherwise)
local function ScanBankItems()
    local counts = {}
    for bag = -1, 11 do
        for slot = 1, GetContainerNumSlots(bag) do
            local _, qty, _, _, _, _, link = GetContainerItemInfo(bag, slot)
            local id = ToItemID(link)
            if id and qty and qty > 0 then
                counts[id] = (counts[id] or 0) + qty
            end
        end
    end
    return counts
end

-- Core mail scanner — returns { [itemID] = count }
-- Only valid inside MAIL_INBOX_OPENED callback
local function ScanMailItems()
    local counts = {}
    local num = GetInboxNumItems()
    for i = 1, num do
        for att = 1, ATTACHMENTS_MAX_RECEIVE do
            local link = GetInboxItemLink(i, att)
            local _, _, _, qty = GetInboxItem(i, att)
            local id = ToItemID(link)
            if id and qty and qty > 0 then
                counts[id] = (counts[id] or 0) + qty
            end
        end
    end
    return counts
end

-- Merge a partial scan (bags/bank/mail) into the entry's items table
-- slotKey is "bags", "bank", or "mail"
local function MergeItems(entry, slotKey, newCounts)
    -- First zero out all existing entries for this slot type
    for id, slots in pairs(entry.items) do
        slots[slotKey] = 0
    end
    -- Write new values
    for id, qty in pairs(newCounts) do
        if not entry.items[id] then
            entry.items[id] = { bags=0, bank=0, mail=0 }
        end
        entry.items[id][slotKey] = qty
    end
    -- Prune entries where everything is zero
    for id, slots in pairs(entry.items) do
        if (slots.bags or 0) == 0 and (slots.bank or 0) == 0 and (slots.mail or 0) == 0 then
            entry.items[id] = nil
        end
    end
end

-- ============================================================================
-- FULL CHARACTER SCAN  (called on login + manual rescan)
-- ============================================================================
function CV.ScanCharacter()
    local key, name, realm = CharKey()
    local entry = EnsureEntry(key, name, realm)

    local _, class = UnitClass("player")
    local _, race  = UnitRace("player")
    local gear, avgIlvl = ScanGear()

    entry.meta = {
        name      = name,
        realm     = realm,
        class     = class or "Unknown",
        race      = race  or "Unknown",
        level     = UnitLevel("player") or 1,
        zone      = GetRealZoneText() or GetZoneText() or "Unknown",
        gold      = GetMoney() or 0,
        avgIlvl   = avgIlvl,
        lastSeen  = date("%Y-%m-%d %H:%M"),
    }
    -- Carry convenience copies up to the entry root for backwards compat
    for k, v in pairs(entry.meta) do entry[k] = v end

    entry.gear        = gear
    entry.professions = ScanProfessions()
    MergeItems(entry, "bags", ScanBagItems())

    -- Rebuild tooltip index for instant lookups
    CV.RebuildIndex()

    MTR.dprint("CharVault: full scan — ", name,
        "| ilvl", avgIlvl, "| items", CV.ItemCount(key))
end

-- ============================================================================
-- BAG UPDATE SCAN  (debounced — at most once every 3s, never in combat)
-- ============================================================================
local bagDirty = false

local function DoBagScan()
    if not MTR.initialized then return end
    if UnitAffectingCombat("player") then
        -- Defer until out of combat
        MTR.TickAdd("cv_bag_postcombat", 1, function()
            if not UnitAffectingCombat("player") then
                MTR.TickRemove("cv_bag_postcombat")
                DoBagScan()
            end
        end)
        return
    end
    local key, name, realm = CharKey()
    local entry = EnsureEntry(key, name, realm)
    entry.meta.gold     = GetMoney() or 0
    entry.gold          = entry.meta.gold
    entry.meta.lastSeen = date("%Y-%m-%d %H:%M")
    entry.lastSeen      = entry.meta.lastSeen
    MergeItems(entry, "bags", ScanBagItems())
    CV.RebuildIndex()
    MTR.dprint("CharVault: bag rescan done")
end

local bagFrame = CreateFrame("Frame")
bagFrame:RegisterEvent("BAG_UPDATE")
bagFrame:RegisterEvent("ITEM_LOCK_CHANGED")
bagFrame:SetScript("OnEvent", function()
    if not MTR.initialized then return end
    -- Debounce: cancel any pending scan and reschedule for 3s from now
    MTR.TickRemove("cv_bag_debounce")
    MTR.TickAdd("cv_bag_debounce", 3, function()
        MTR.TickRemove("cv_bag_debounce")
        DoBagScan()
    end)
end)

-- ============================================================================
-- BANK SCAN
-- ============================================================================
local bankFrame = CreateFrame("Frame")
bankFrame:RegisterEvent("BANKFRAME_OPENED")
bankFrame:SetScript("OnEvent", function()
    if not MTR.initialized then return end
    local key, name, realm = CharKey()
    local entry = EnsureEntry(key, name, realm)
    MergeItems(entry, "bank", ScanBankItems())
    entry.meta.lastSeen = date("%Y-%m-%d %H:%M")
    entry.lastSeen      = entry.meta.lastSeen
    CV.RebuildIndex()
    MTR.dprint("CharVault: bank scanned")
end)

-- ============================================================================
-- MAIL SCAN
-- ============================================================================
local mailFrame = CreateFrame("Frame")
mailFrame:RegisterEvent("MAIL_INBOX_OPENED")
mailFrame:SetScript("OnEvent", function()
    if not MTR.initialized then return end
    -- Mail API needs a short delay to populate
    MTR.After(0.5, function()
        local key, name, realm = CharKey()
        local entry = EnsureEntry(key, name, realm)
        MergeItems(entry, "mail", ScanMailItems())
        entry.meta.lastSeen = date("%Y-%m-%d %H:%M")
        entry.lastSeen      = entry.meta.lastSeen
        CV.RebuildIndex()
        MTR.dprint("CharVault: mail scanned")
    end)
end)

-- ============================================================================
-- GUILD BANK SNAPSHOT SYSTEM
-- Any player who opens the guild bank triggers a scan of all visible tabs.
-- The snapshot is stored in MekTownRecruitDB.guildBank (account-wide) and
-- broadcast over the addon channel so all online members receive it without
-- needing to open the bank themselves.
--
-- This means once any officer or member visits the guild bank, everyone in
-- the guild can search its contents via /mek chars → Guild Bank tab until
-- the next person opens the bank and refreshes the snapshot.
--
-- Wire format (addon prefix "MekTownGB"):
--   GB:S:scannedBy          — snapshot start
--   GB:D:tab|name|qty,...   — data chunk (pipe-delimited tokens, comma-sep)
--   GB:E:timestamp          — end; receiver merges and saves
-- ============================================================================
local GB_PREFIX = "MekTownGB"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(GB_PREFIX) end

MTR.GuildBankScan = {}     -- public handle for the UI tab

-- Scan all visible guild bank tabs and return flat item list
local function ScanGuildBank()
    local items = {}
    local numTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
    for tab = 1, numTabs do
        -- GetGuildBankTabInfo returns: name, icon, isViewable, canDeposit, ...
        -- Skip the isViewable check — unreliable on Ascension. If a tab isn't
        -- accessible, GetGuildBankItemLink returns nil for every slot anyway.
        local tabName = GetGuildBankTabInfo(tab)
        tabName = tabName or ("Tab " .. tab)

        -- Each tab has up to 98 slots (7 columns × 14 rows)
        for slot = 1, 98 do
            local link = GetGuildBankItemLink(tab, slot)
            if link then
                -- GetGuildBankItemInfo returns: icon, count, locked, isFiltered
                -- count is the SECOND return value — was incorrectly reading the third
                local _, count = GetGuildBankItemInfo(tab, slot)
                count = tonumber(count) or 1
                local name = GetItemInfo(link)
                if name then
                    items[#items+1] = {
                        name    = name,
                        link    = link,
                        count   = count,
                        tab     = tab,
                        tabName = tabName,
                    }
                end
            end
        end
    end
    return items
end

-- Build chunk strings from item list for addon messaging
-- Token format: "tabNum|itemID|itemName|count"
-- itemID is included so receivers can call GetItemInfo(itemID) to resolve
-- the item texture. Without it, icons appear as question marks on other clients
-- because they have no link to look up.
local function BuildChunks(items)
    local chunks = {}
    local chunk  = ""
    for _, item in ipairs(items) do
        -- Extract itemID from the link so we can transmit it
        local itemID = item.link and (item.link:match("item:(%d+)") or "") or ""
        -- Sanitise name: strip pipes and commas that would break parsing
        local safeName = item.name:gsub("|",""):gsub(",","")
        local token = item.tab .. "|" .. itemID .. "|" .. safeName .. "|" .. (item.count or 1)
        if #chunk + #token + 1 > 200 then
            chunks[#chunks+1] = chunk
            chunk = token
        else
            chunk = chunk == "" and token or (chunk .. "," .. token)
        end
    end
    if chunk ~= "" then chunks[#chunks+1] = chunk end
    return chunks
end

-- Store a received (or locally-scanned) item list as the guild bank snapshot
local function MergeGuildBankSnapshot(items, scannedBy, timestamp)
    MekTownRecruitDB.guildBank = {}
    local ts = timestamp or date("%Y-%m-%d %H:%M")
    for _, item in ipairs(items) do
        item.updated  = ts
        item.scannedBy = scannedBy or "?"
        MekTownRecruitDB.guildBank[#MekTownRecruitDB.guildBank+1] = item
    end
    MTR.dprint("GuildBank snapshot stored:", #MekTownRecruitDB.guildBank,
        "items from", scannedBy, "at", ts)
    -- Notify any open vault window to refresh
    if MTR.vaultWin and MTR.vaultWin:IsShown() then
        local tf = MTR.vaultWin._showTab  -- noop refresh: just re-fire the tab
        -- Signal to the Guild Bank tab that data changed
        MTR.GuildBankScan.dirty = true
    end
end

-- Broadcast locally-scanned data to all guild members
local function BroadcastGuildBank(items, scannedBy)
    if not IsInGuild() then return end
    local chunks = BuildChunks(items)
    local ts     = date("%Y-%m-%d %H:%M")
    SendAddonMessage(GB_PREFIX, "GB:S:" .. (scannedBy or ""), "GUILD")
    for _, chunk in ipairs(chunks) do
        SendAddonMessage(GB_PREFIX, "GB:D:" .. chunk, "GUILD")
    end
    SendAddonMessage(GB_PREFIX, "GB:E:" .. ts, "GUILD")
    MTR.dprint("GuildBank broadcast:", #items, "items,", #chunks, "chunks")
end

-- ── Public scan trigger — callable by UI button ──────────────────────────────
-- This is the only entry point that actually performs a scan.
-- It can be called from the "Scan Bank" button in the Vault UI whenever the
-- guild bank frame is already open (no need to toggle it).
local function DoGuildBankScan(opts)
    opts = opts or {}
    local includeLedger = opts.includeLedger == true
    if not MTR.initialized then return end
    MTR.TickRemove("gb_scan_delay")
    MTR.TickAdd("gb_scan_delay", 1, function()
        MTR.TickRemove("gb_scan_delay")

        local items     = ScanGuildBank()
        local scannedBy = MTR.playerName or "?"
        local ts        = date("%Y-%m-%d %H:%M")

        MergeGuildBankSnapshot(items, scannedBy, ts)
        BroadcastGuildBank(items, scannedBy)
        if includeLedger and MTR.GuildBankLedger and MTR.GuildBankLedger.BeginLocalScan then
            MTR.GuildBankLedger.BeginLocalScan(scannedBy)
        end

        local numTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
        MTR.MP(string.format(
            "|cffd4af37[Vault]|r Guild bank snapshot: |cffffff00%d items|r across |cffffff00%d tab%s|r  "..
            "|cffaaaaaa(synced to all online guild members)|r",
            #items, numTabs, numTabs == 1 and "" or "s"))
    end)
end
MTR.GuildBankScan.DoScan = function()
    DoGuildBankScan({ includeLedger = true })
end   -- expose to UI

-- ── Event listeners ────────────────────────────────────────────────────────
-- GUILDBANKFRAME_OPENED  — fires when the bank window opens
-- GUILDBANKBAGSLOTS_CHANGED — fires when tab slot data finishes loading
-- Both trigger a scan so we catch: fresh opens AND tab switches
local gbScanFrame = CreateFrame("Frame")
gbScanFrame:RegisterEvent("GUILDBANKFRAME_OPENED")
gbScanFrame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
gbScanFrame:SetScript("OnEvent", function(self, event)
    if not MTR.initialized then return end
    -- Both events lead to the same debounced scan.
    -- DoGuildBankScan already debounces so rapid slot events collapse into one.
    DoGuildBankScan({ includeLedger = false })
end)

-- Receive guild bank snapshot from another player
local gbRecvBuf    = nil
local gbRecvSender = nil
local gbRecvFrame  = CreateFrame("Frame")
gbRecvFrame:RegisterEvent("CHAT_MSG_ADDON")
gbRecvFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= GB_PREFIX then return end
    if not MTR.initialized then return end

    -- Strip realm from sender
    local senderName = (sender or ""):match("^([^%-]+)") or sender or ""

    if message:sub(1, 5) == "GB:S:" then
        gbRecvBuf    = {}
        gbRecvSender = message:sub(6)
        if gbRecvSender == "" then gbRecvSender = senderName end

    elseif message:sub(1, 5) == "GB:D:" and gbRecvBuf then
        for token in message:sub(6):gmatch("[^,]+") do
            -- New format (v1.1.1+): "tab|itemID|name|count"
            -- Old format (pre v1.1.1): "tab|name|count"
            -- Try new format first; fall back to old so cross-version syncs still work.
            local tab, itemID, name, count = token:match("^(%d+)|(%d*)|([^|]+)|(%d+)$")
            if not tab then
                -- Old format fallback
                tab, name, count = token:match("^(%d+)|([^|]+)|(%d+)$")
                itemID = nil
            end
            if tab and name and count then
                local iid = itemID and itemID ~= "" and tonumber(itemID) or nil
                gbRecvBuf[#gbRecvBuf+1] = {
                    tab     = tonumber(tab),
                    itemID  = iid,
                    name    = name,
                    count   = tonumber(count),
                    tabName = "Tab " .. tab,
                    -- Reconstruct a minimal item link from the ID so IconSetItem
                    -- can call GetItemInfo(link) and resolve the icon texture.
                    link    = iid and ("|cffffffff|Hitem:"..iid..":0:0:0:0:0:0:0|h["..name.."]|h|r") or nil,
                }
            end
        end

    elseif message:sub(1, 5) == "GB:E:" and gbRecvBuf then
        local ts = message:sub(6)
        -- Don't overwrite with our own broadcast echo
        if senderName ~= MTR.playerName then
            MergeGuildBankSnapshot(gbRecvBuf, gbRecvSender, ts)
            MTR.dprint("GuildBank received from", gbRecvSender, "—", #gbRecvBuf, "items")
        end
        gbRecvBuf    = nil
        gbRecvSender = nil
    end
end)

-- ============================================================================
-- GUILD BANK LEDGER SYSTEM
-- Captures limited guild bank log data and syncs a deduplicated rolling history
-- to every online guild member. Keeps up to 30 days locally.
-- ============================================================================
local GBL_PREFIX = "MekTownGBL"
if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(GBL_PREFIX) end

MTR.GuildBankLedger = MTR.GuildBankLedger or {}
local GBL = MTR.GuildBankLedger
GBL.RETAIN_DAYS = 30
GBL.MAX_ENTRIES = 5000

local gblRecvBuf = nil

local function GBL_DB()
    MekTownRecruitDB.guildBankLedger = MekTownRecruitDB.guildBankLedger or { entries = {}, meta = {} }
    MekTownRecruitDB.guildBankLedger.entries = MekTownRecruitDB.guildBankLedger.entries or {}
    MekTownRecruitDB.guildBankLedger.meta = MekTownRecruitDB.guildBankLedger.meta or {}
    return MekTownRecruitDB.guildBankLedger
end

local function GBL_DebugEnabled()
    return MTR.IsDebugEnabled and MTR.IsDebugEnabled() or false
end

local function GBL_Debug(msg)
    if not GBL_DebugEnabled() then return end
    local db = GBL_DB()
    db.meta.debugLog = db.meta.debugLog or {}
    local line = string.format("%s | %s", date("%H:%M:%S"), tostring(msg or ""))
    db.meta.debugLog[#db.meta.debugLog + 1] = line
    while #db.meta.debugLog > 300 do
        table.remove(db.meta.debugLog, 1)
    end
    db.meta.lastDebugAt = date("%Y-%m-%d %H:%M:%S")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r " .. line)
    end
end

function GBL.DebugEnable(flag)
    if MTR.SetDebugEnabled then
        MTR.SetDebugEnabled(flag)
    end
    if GBL_DebugEnabled() then
        GBL_Debug("Debug enabled")
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r Debug disabled.")
    end
end

function GBL.DebugClear()
    local db = GBL_DB()
    db.meta.debugLog = {}
    db.meta.lastDebugAt = date("%Y-%m-%d %H:%M:%S")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r Debug log cleared.")
    end
end

function GBL.DebugDump(limit)
    if not GBL_DebugEnabled() then
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r Enable Debug first to capture ledger diagnostics.")
        end
        return
    end
    local db = GBL_DB()
    local log = db.meta.debugLog or {}
    local n = tonumber(limit) or 40
    local startAt = math.max(1, #log - n + 1)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r Debug dump (" .. (#log) .. " lines total):")
        for i = startAt, #log do
            DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r " .. tostring(log[i]))
        end
    end
end

function GBL.GetDebugLog()
    local db = GBL_DB()
    return db.meta.debugLog or {}
end

local function GBL_Strip(s)
    s = tostring(s or "")
    s = s:gsub("[|,;]", "")
    s = s:gsub("[%c]", " ")
    return s
end

local function GBL_NormalizeYear(y)
    y = tonumber(y) or 0
    if y < 100 then y = y + 2000 end
    return y
end

local function GBL_BuildEpoch(y, m, d, h)
    y = GBL_NormalizeYear(y)
    m = tonumber(m) or 1
    d = tonumber(d) or 1
    h = tonumber(h) or 0
    local ok, ts = pcall(time, { year = y, month = m, day = d, hour = h, min = 0, sec = 0 })
    if ok and ts then return ts end
    return time()
end

local function GBL_Fingerprint(e)
    return table.concat({
        tostring(e.kind or "item"),
        tostring(e.txType or "?"),
        tostring(e.actor or "?"),
        tostring(e.itemID or 0),
        tostring(e.itemName or "?"),
        tostring(e.count or 0),
        tostring(e.tab1 or 0),
        tostring(e.tab2 or 0),
        tostring(e.year or 0),
        tostring(e.month or 0),
        tostring(e.day or 0),
        tostring(e.hour or 0)
    }, "#")
end

local function GBL_DateText(e)
    local y = GBL_NormalizeYear(e.year)
    return string.format("%04d-%02d-%02d %02d:00", y, tonumber(e.month) or 1, tonumber(e.day) or 1, tonumber(e.hour) or 0)
end

local function GBL_Purge()
    local db = GBL_DB()
    local now = time()
    local cutoff = now - (GBL.RETAIN_DAYS * 86400)
    local keep = {}
    for _, e in ipairs(db.entries) do
        local ts = tonumber(e.epoch) or now
        if ts >= cutoff then
            keep[#keep + 1] = e
        end
    end
    table.sort(keep, function(a, b)
        return (tonumber(a.epoch) or 0) > (tonumber(b.epoch) or 0)
    end)
    while #keep > GBL.MAX_ENTRIES do
        table.remove(keep)
    end
    db.entries = keep
    db.meta.count = #keep
    db.meta.lastPurgeAt = date("%Y-%m-%d %H:%M")
end

local function GBL_MarkDirty()
    GBL.dirty = true
    if MTR.vaultWin and MTR.vaultWin:IsShown() then
        GBL.dirty = true
    end
end

local function GBL_MergeEntries(entries, source, scanTS)
    local db = GBL_DB()
    local existing = {}
    for _, e in ipairs(db.entries) do
        existing[e.fingerprint] = true
    end
    local added = 0
    for _, e in ipairs(entries or {}) do
        if e and e.fingerprint and not existing[e.fingerprint] then
            existing[e.fingerprint] = true
            e.syncedFrom = source or e.syncedFrom or "?"
            e.scanTS = e.scanTS or scanTS or date("%Y-%m-%d %H:%M")
            db.entries[#db.entries + 1] = e
            added = added + 1
        end
    end
    if added > 0 then
        GBL_Purge()
        db.meta.lastSyncFrom = source or db.meta.lastSyncFrom
        db.meta.lastSyncAt = scanTS or date("%Y-%m-%d %H:%M")
        db.meta.lastAdded = added
        GBL_MarkDirty()
    end
    return added
end

local function GBL_EntryToToken(e)
    return table.concat({
        GBL_Strip(e.kind or "item"),
        GBL_Strip(e.txType or "?"),
        GBL_Strip(e.actor or "?"),
        tostring(e.itemID or 0),
        GBL_Strip(e.itemName or "?"),
        tostring(e.count or 0),
        tostring(e.tab1 or 0),
        tostring(e.tab2 or 0),
        tostring(e.year or 0),
        tostring(e.month or 0),
        tostring(e.day or 0),
        tostring(e.hour or 0),
        GBL_Strip(e.scanBy or "?"),
        GBL_Strip(e.scanTS or ""),
        (e.hasExactDate and "1" or "0")
    }, "|")
end

local function GBL_TokenToEntry(token)
    local kind, txType, actor, itemID, itemName, count, tab1, tab2, y, m, d, h, scanBy, scanTS, hasExactDate = token:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not kind then
        kind, txType, actor, itemID, itemName, count, tab1, tab2, y, m, d, h, scanBy, scanTS = token:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
        if not kind then return nil end
    end
    local e = {
        kind = kind ~= "" and kind or "item",
        txType = txType ~= "" and txType or "?",
        actor = actor ~= "" and actor or "?",
        itemID = tonumber(itemID) or nil,
        itemName = itemName ~= "" and itemName or "?",
        count = tonumber(count) or 0,
        tab1 = tonumber(tab1) or 0,
        tab2 = tonumber(tab2) or 0,
        year = tonumber(y) or 0,
        month = tonumber(m) or 0,
        day = tonumber(d) or 0,
        hour = tonumber(h) or 0,
        scanBy = scanBy ~= "" and scanBy or "?",
        scanTS = scanTS ~= "" and scanTS or date("%Y-%m-%d %H:%M"),
        hasExactDate = tostring(hasExactDate or "0") == "1",
    }
    if e.itemID and e.itemID > 0 then
        e.itemLink = GetItemInfo(e.itemID)
        e.itemLink = select(2, GetItemInfo(e.itemID)) or ("|cffffffff|Hitem:" .. e.itemID .. ":0:0:0:0:0:0:0|h[" .. e.itemName .. "]|h|r")
    end
    e.epoch = e.hasExactDate and GBL_BuildEpoch(e.year, e.month, e.day, e.hour) or GBL_BuildEpoch(e.year, e.month, e.day, e.hour)
    e.dateText = e.hasExactDate and GBL_DateText(e) or (e.scanTS ~= "" and e.scanTS or date("%Y-%m-%d %H:%M", e.epoch))
    e.fingerprint = GBL_Fingerprint(e)
    return e
end

local function GBL_BuildChunks(entries)
    local chunks, chunk = {}, ""
    for _, e in ipairs(entries or {}) do
        local token = GBL_EntryToToken(e)
        if #chunk + #token + 1 > 220 then
            if chunk ~= "" then chunks[#chunks + 1] = chunk end
            chunk = token
        else
            chunk = (chunk == "" and token) or (chunk .. ";" .. token)
        end
    end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    return chunks
end

local function GBL_Broadcast(entries, sourceTag)
    if not IsInGuild() then return end
    entries = entries or GBL_DB().entries or {}
    GBL_Purge()
    local chunks = GBL_BuildChunks(entries)
    local who = MTR.playerName or "?"
    local ts = date("%Y-%m-%d %H:%M")
    SendAddonMessage(GBL_PREFIX, "GL:S:" .. who .. ":" .. tostring(#entries) .. ":" .. sourceTag .. ":" .. ts, "GUILD")
    for _, chunk in ipairs(chunks) do
        SendAddonMessage(GBL_PREFIX, "GL:D:" .. chunk, "GUILD")
    end
    SendAddonMessage(GBL_PREFIX, "GL:E:" .. ts, "GUILD")
end

local gblScanState = {
    active = false,
    scanBy = nil,
    tabs = nil,
    idx = 0,
    entries = nil,
    waitingTab = nil,
}

local function GBL_AgeTextToEpoch(ageText)
    local now = time()
    if type(ageText) ~= "string" or ageText == "" then return now end
    local s = string.lower(ageText)

    local n = tonumber(s:match("(%d+)%s+minute")) or tonumber(s:match("(%d+)%s+min"))
    if n then return now - (n * 60) end

    n = tonumber(s:match("(%d+)%s+hour"))
    if n then return now - (n * 3600) end

    n = tonumber(s:match("(%d+)%s+day"))
    if n then return now - (n * 86400) end

    n = tonumber(s:match("(%d+)%s+week"))
    if n then return now - (n * 7 * 86400) end

    if s:find("yesterday", 1, true) then
        return now - 86400
    end
    if s:find("today", 1, true) then
        return now
    end

    return now
end

local function GBL_ParseTextLogMessage(tab, rawMsg, scanBy)
    if type(rawMsg) ~= "string" or rawMsg == "" then return nil end

    local itemLink = rawMsg:match("(|Hitem:[^|]+|h%[[^%]]+%]|h)")
    local itemName = rawMsg:match("|Hitem:[^|]+|h%[([^%]]+)%]|h") or rawMsg:match("%[([^%]]+)%]")
    local itemID = itemLink and tonumber(itemLink:match("item:(%d+)")) or nil

    local plain = rawMsg
    plain = plain:gsub("|c%x%x%x%x%x%x%x%x", "")
    plain = plain:gsub("|r", "")
    plain = plain:gsub("|H.-|h(.-)|h", "%1")
    plain = plain:gsub("|T.-|t", "")
    plain = plain:gsub("%s+", " ")
    plain = plain:gsub("^%s+", ""):gsub("%s+$", "")

    local actor, txType
    actor = plain:match("^(.-) deposited ")
    if actor then
        txType = "deposit"
    else
        actor = plain:match("^(.-) withdrew ")
        if actor then
            txType = "withdraw"
        else
            actor = plain:match("^(.-) moved ")
            if actor then
                txType = "move"
            end
        end
    end
    if not actor or not txType then return nil end

    local count = tonumber(plain:match("%]x%s*(%d+)")) or tonumber(plain:match(" x%s*(%d+)")) or 1
    local ageText = plain:match("%((.-)%)%s*$") or ""
    ageText = ageText:gsub("^%s+", ""):gsub("%s+$", "")

    local e = {
        kind = "item",
        txType = txType,
        actor = actor or "?",
        itemID = itemID,
        itemLink = itemLink,
        itemName = itemName or "Unknown",
        count = count,
        tab1 = tonumber(tab) or 0,
        tab2 = 0,
        year = 0,
        month = 0,
        day = 0,
        hour = 0,
        scanBy = scanBy or MTR.playerName or "?",
        scanTS = date("%Y-%m-%d %H:%M"),
        source = "textlog",
        relativeText = ageText,
    }
    e.epoch = GBL_AgeTextToEpoch(ageText)
    e.dateText = ageText ~= "" and ageText or date("%Y-%m-%d %H:00")
    e.fingerprint = table.concat({
        e.txType or "?",
        e.actor or "?",
        tostring(e.itemID or 0),
        e.itemName or "?",
        tostring(e.count or 0),
        tostring(e.tab1 or 0),
        e.dateText or "",
    }, "|")
    return e
end

local function GBL_ScrapeVisibleLogFrame(tab, entries, scanBy)
    if not GuildBankMessageFrame then
        GBL_Debug("Tab " .. tostring(tab) .. " scrape: GuildBankMessageFrame missing")
        return 0
    end

    local added = 0
    local seen = {}

    GBL_Debug("Tab " .. tostring(tab) .. " scrape: frame present, mode=" .. tostring(GuildBankFrame and GuildBankFrame.mode or "nil"))

    if GuildBankFrame_UpdateLog then
        local ok = pcall(GuildBankFrame_UpdateLog)
        GBL_Debug("Tab " .. tostring(tab) .. " scrape: GuildBankFrame_UpdateLog() -> " .. tostring(ok))
    end

    if GuildBankMessageFrame.GetNumMessages and GuildBankMessageFrame.GetMessageInfo then
        local okN, n = pcall(GuildBankMessageFrame.GetNumMessages, GuildBankMessageFrame)
        GBL_Debug("Tab " .. tostring(tab) .. " scrape: GetNumMessages ok=" .. tostring(okN) .. " count=" .. tostring(n))
        if okN and type(n) == "number" and n > 0 then
            for i = 1, n do
                local okM, msg = pcall(GuildBankMessageFrame.GetMessageInfo, GuildBankMessageFrame, i)
                if i <= 3 then
                    GBL_Debug("Tab " .. tostring(tab) .. " scrape msg[" .. i .. "] ok=" .. tostring(okM) .. " text=" .. tostring(msg))
                end
                if okM and type(msg) == "string" and msg ~= "" and not seen[msg] then
                    seen[msg] = true
                    local e = GBL_ParseTextLogMessage(tab, msg, scanBy)
                    if e then
                        entries[#entries + 1] = e
                        added = added + 1
                    end
                end
            end
        end
    else
        GBL_Debug("Tab " .. tostring(tab) .. " scrape: message methods unavailable")
    end

    if added == 0 and GuildBankMessageFrame.GetRegions then
        local regions = { GuildBankMessageFrame:GetRegions() }
        GBL_Debug("Tab " .. tostring(tab) .. " scrape: regions=" .. tostring(#regions))
        local samples = 0
        for _, region in ipairs(regions) do
            if region and region.GetObjectType and region:GetObjectType() == "FontString" and region.GetText then
                local msg = region:GetText()
                if type(msg) == "string" and msg ~= "" then
                    samples = samples + 1
                    if samples <= 5 then
                        GBL_Debug("Tab " .. tostring(tab) .. " region text[" .. samples .. "]=" .. tostring(msg))
                    end
                end
                if type(msg) == "string" and msg ~= "" and not seen[msg] then
                    seen[msg] = true
                    local e = GBL_ParseTextLogMessage(tab, msg, scanBy)
                    if e then
                        entries[#entries + 1] = e
                        added = added + 1
                    end
                end
            end
        end
    end

    GBL_Debug("Tab " .. tostring(tab) .. " scrape: parsed entries added=" .. tostring(added))
    return added
end

local function GBL_ReadTabTransactions(tab, entries, scanBy)
    local count = 0
    if GetNumGuildBankTransactions then
        local ok, c = pcall(GetNumGuildBankTransactions, tab)
        if ok and type(c) == "number" then count = c end
        GBL_Debug("Tab " .. tostring(tab) .. " API count ok=" .. tostring(ok) .. " count=" .. tostring(c))
    else
        GBL_Debug("Tab " .. tostring(tab) .. " API count function missing")
    end

    local before = #entries

    for i = 1, count do
        local ok, txType, actor, itemLink, itemCount, tab1, tab2, y, m, d, h = pcall(GetGuildBankTransaction, tab, i)
        if i <= 3 then
            GBL_Debug("Tab " .. tostring(tab) .. " tx[" .. i .. "] ok=" .. tostring(ok) .. " type=" .. tostring(txType) .. " actor=" .. tostring(actor) .. " link=" .. tostring(itemLink) .. " count=" .. tostring(itemCount))
        end
        if ok and txType then
            local itemID = itemLink and tonumber(itemLink:match("item:(%d+)")) or nil
            local itemName = itemLink and GetItemInfo(itemLink) or nil
            itemName = itemName or (itemLink and itemLink:match("%[(.-)%]")) or actor or "Unknown"

            local nowDate = date("*t")
            local year = tonumber(y) or 0
            local month = tonumber(m) or 0
            local day = tonumber(d) or 0
            local hour = tonumber(h) or 0
            local hasValidDate = year > 0 and month > 0 and day > 0

            local e = {
                kind = "item",
                txType = txType,
                actor = actor or "?",
                itemID = itemID,
                itemLink = itemLink,
                itemName = itemName,
                count = tonumber(itemCount) or 0,
                tab1 = tonumber(tab1) or tab,
                tab2 = tonumber(tab2) or 0,
                year = hasValidDate and year or nowDate.year,
                month = hasValidDate and month or nowDate.month,
                day = hasValidDate and day or nowDate.day,
                hour = hasValidDate and hour or nowDate.hour,
                scanBy = scanBy or MTR.playerName or "?",
                scanTS = date("%Y-%m-%d %H:%M"),
                source = "api",
                hasExactDate = hasValidDate and true or false,
            }
            e.epoch = hasValidDate and GBL_BuildEpoch(e.year, e.month, e.day, e.hour) or time()
            e.relativeText = hasValidDate and nil or nil
            e.dateText = hasValidDate and GBL_DateText(e) or date("%Y-%m-%d %H:%M", e.epoch)
            e.fingerprint = GBL_Fingerprint(e)
            entries[#entries + 1] = e
        end
    end

    GBL_Debug("Tab " .. tostring(tab) .. " API entries added=" .. tostring(#entries - before))

    if #entries == before then
        GBL_Debug("Tab " .. tostring(tab) .. " API returned no entries, attempting text scrape fallback")
        GBL_ScrapeVisibleLogFrame(tab, entries, scanBy)
    end
end

local function GBL_FinalizeScan()
    local entries = gblScanState.entries or {}
    local scanBy = gblScanState.scanBy or MTR.playerName or "?"
    gblScanState.active = false
    gblScanState.waitingTab = nil
    MTR.TickRemove("gb_ledger_timeout")

    local added = GBL_MergeEntries(entries, scanBy, date("%Y-%m-%d %H:%M"))
    local db = GBL_DB()
    db.meta.lastScanBy = scanBy
    db.meta.lastScanAt = date("%Y-%m-%d %H:%M")
    db.meta.lastRawSeen = #entries

    GBL_Debug("Finalize scan: rawEntries=" .. tostring(#entries) .. " mergedNew=" .. tostring(added) .. " retained=" .. tostring(#(db.entries or {})))

    if added > 0 then
        GBL_Broadcast(db.entries, "scan")
        MTR.dprint("GuildBank ledger scan merged", added, "new entries")
    else
        MTR.dprint("GuildBank ledger scan found 0 new entries; raw visible entries =", #entries)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[MTR Ledger]|r Scan finished with 0 captured entries. Enable Debug and run |cffffff00/mek ledgerdebug show|r to dump the logic path.")
        end
    end
end

local function GBL_QueryNextTab()
    if not gblScanState.active then return end

    gblScanState.idx = gblScanState.idx + 1
    local tab = gblScanState.tabs and gblScanState.tabs[gblScanState.idx]
    if not tab then
        GBL_Debug("Finalize scan: no more tabs")
        GBL_FinalizeScan()
        return
    end

    gblScanState.waitingTab = tab
    GBL_Debug("Queue tab " .. tostring(tab) .. " of " .. tostring(gblScanState.tabs and #gblScanState.tabs or 0))

    if SetCurrentGuildBankTab then
        local ok, err = pcall(SetCurrentGuildBankTab, tab)
        GBL_Debug("SetCurrentGuildBankTab(" .. tostring(tab) .. ") ok=" .. tostring(ok) .. " err=" .. tostring(err))
    else
        GBL_Debug("SetCurrentGuildBankTab unavailable")
    end

    if GuildBankFrame then
        GuildBankFrame.mode = "log"
        GBL_Debug("GuildBankFrame.mode forced to " .. tostring(GuildBankFrame.mode))
    else
        GBL_Debug("GuildBankFrame missing")
    end

    if QueryGuildBankLog then
        local ok, err = pcall(QueryGuildBankLog, tab)
        GBL_Debug("QueryGuildBankLog(" .. tostring(tab) .. ") ok=" .. tostring(ok) .. " err=" .. tostring(err))
    else
        GBL_Debug("QueryGuildBankLog unavailable")
    end

    MTR.TickRemove("gb_ledger_timeout")
    MTR.TickAdd("gb_ledger_timeout", 1.5, function()
        if not gblScanState.active or gblScanState.waitingTab ~= tab then return end
        GBL_Debug("Timeout fallback fired for tab " .. tostring(tab))
        GBL_ReadTabTransactions(tab, gblScanState.entries, gblScanState.scanBy)
        gblScanState.waitingTab = nil
        GBL_QueryNextTab()
    end)
end

local function GBL_CollectTransactions(scanBy)
    if gblScanState.active then return end
    local numTabs = GetNumGuildBankTabs and (GetNumGuildBankTabs() or 0) or 0
    GBL_Debug("BeginLocalScan by=" .. tostring(scanBy or MTR.playerName or "?") .. " numTabs=" .. tostring(numTabs) .. " gbFrameShown=" .. tostring(GuildBankFrame and GuildBankFrame:IsShown()))
    if numTabs <= 0 then
        local db = GBL_DB()
        db.meta.lastScanBy = scanBy or MTR.playerName or "?"
        db.meta.lastScanAt = date("%Y-%m-%d %H:%M")
        db.meta.lastRawSeen = 0
        GBL_Debug("Abort scan: no guild bank tabs available")
        return
    end

    gblScanState.active = true
    gblScanState.scanBy = scanBy or MTR.playerName or "?"
    gblScanState.tabs = {}
    gblScanState.idx = 0
    gblScanState.entries = {}
    gblScanState.waitingTab = nil

    for tab = 1, numTabs do
        gblScanState.tabs[#gblScanState.tabs + 1] = tab
    end

    GBL_QueryNextTab()
end

local gblScanFrame = CreateFrame("Frame")
gblScanFrame:RegisterEvent("GUILDBANKLOG_UPDATE")
gblScanFrame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
gblScanFrame:RegisterEvent("GUILDBANK_UPDATE_TABS")
gblScanFrame:SetScript("OnEvent", function(_, event)
    GBL_Debug("Event fired: " .. tostring(event) .. " waitingTab=" .. tostring(gblScanState.waitingTab))
    if not gblScanState.active then return end
    local tab = gblScanState.waitingTab
    if not tab then return end

    MTR.TickRemove("gb_ledger_timeout")
    GBL_ReadTabTransactions(tab, gblScanState.entries, gblScanState.scanBy)
    gblScanState.waitingTab = nil
    GBL_QueryNextTab()
end)

function GBL.GetEntries()
    GBL_Purge()
    return GBL_DB().entries or {}
end

function GBL.GetMeta()
    GBL_Purge()
    return GBL_DB().meta or {}
end

function GBL.RequestSync()
    if not IsInGuild() then return end
    SendAddonMessage(GBL_PREFIX, "GL:R:" .. (MTR.playerName or "?"), "GUILD")
end

function GBL.BeginLocalScan(scanBy)
    GBL_CollectTransactions(scanBy)
end

local gblRecvFrame = CreateFrame("Frame")
gblRecvFrame:RegisterEvent("CHAT_MSG_ADDON")
gblRecvFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= GBL_PREFIX then return end
    if not MTR.initialized then return end
    local senderName = (sender or ""):match("^([^%-]+)") or sender or ""

    if message:sub(1, 5) == "GL:R:" then
        if senderName ~= MTR.playerName and MTR.isOfficer then
            GBL_Broadcast(GBL.GetEntries(), "reply")
        end
    elseif message:sub(1, 5) == "GL:S:" then
        gblRecvBuf = {}
    elseif message:sub(1, 5) == "GL:D:" and gblRecvBuf then
        for token in message:sub(6):gmatch("[^;]+") do
            local e = GBL_TokenToEntry(token)
            if e then gblRecvBuf[#gblRecvBuf + 1] = e end
        end
    elseif message:sub(1, 5) == "GL:E:" and gblRecvBuf then
        if senderName ~= MTR.playerName then
            GBL_MergeEntries(gblRecvBuf, senderName, message:sub(6))
        end
        gblRecvBuf = nil
    end
end)


-- ============================================================================
-- GOLD + ZONE  (live, lightweight)
-- ============================================================================
local liveFrame = CreateFrame("Frame")
liveFrame:RegisterEvent("PLAYER_MONEY")
liveFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
liveFrame:RegisterEvent("ZONE_CHANGED")
liveFrame:SetScript("OnEvent", function()
    if not MTR.initialized then return end
    local key = CharKey()
    local v = MekTownRecruitDB.charVault and MekTownRecruitDB.charVault[key]
    if not v then return end
    v.gold = GetMoney() or 0
    v.zone = GetRealZoneText() or GetZoneText() or "Unknown"
    if v.meta then v.meta.gold = v.gold; v.meta.zone = v.zone end
end)

-- ============================================================================
-- TOOLTIP INDEX
-- Flat lookup: tooltipIndex[itemID] = { {charName, bags, bank, mail} ... }
-- Rebuilt after every scan so tooltip lookups are O(1).
-- ============================================================================
CV.tooltipIndex = {}

function CV.RebuildIndex()
    local idx = {}
    for _, entry in pairs(MekTownRecruitDB.charVault or {}) do
        local name = entry.name or entry.meta and entry.meta.name or "?"
        for id, slots in pairs(entry.items or {}) do
            if not idx[id] then idx[id] = {} end
            local total = (slots.bags or 0) + (slots.bank or 0) + (slots.mail or 0)
            if total > 0 then
                idx[id][#idx[id]+1] = {
                    char  = name,
                    bags  = slots.bags or 0,
                    bank  = slots.bank or 0,
                    mail  = slots.mail or 0,
                    total = total,
                }
            end
        end
    end
    CV.tooltipIndex = idx
end

-- ============================================================================
-- TOOLTIP INJECTION
-- Hooks the three tooltip methods that cover every in-game item surface:
--   SetBagItem       — hovering items in bags / bank
--   SetInventoryItem — hovering equipped gear
--   SetHyperlink     — ctrl-clicking links in chat, AH, etc.
--
-- Each hook appends our cross-character count data below a MekTown separator.
-- Design principle: compact, readable, clan-flavoured.
-- Max 5 characters listed before truncating to "...and N more" to keep
-- the tooltip from overflowing long rows.
-- ============================================================================
local MAX_TT_CHARS = 5

local function AppendVaultLines(tooltip, itemID)
    if not itemID then return end
    local rows = CV.tooltipIndex[itemID]
    if not rows or #rows == 0 then return end

    -- Sort by total count descending
    table.sort(rows, function(a, b) return a.total > b.total end)

    local grand = 0
    for _, r in ipairs(rows) do grand = grand + r.total end

    tooltip:AddLine(TT_SEP)
    tooltip:AddLine(BRAND .. "  Item Tracker")

    local shown = 0
    for _, r in ipairs(rows) do
        if shown >= MAX_TT_CHARS then break end
        -- Build location string: "Bags: N" / "Bank: N" / "Mail: N" combined
        local locs = {}
        if r.bags > 0 then locs[#locs+1] = "|cff88ff88Bags: " .. r.bags .. "|r" end
        if r.bank > 0 then locs[#locs+1] = "|cff88ccffBank: " .. r.bank .. "|r" end
        if r.mail > 0 then locs[#locs+1] = "|cffffcc00Mail: " .. r.mail .. "|r" end
        local locStr = #locs > 0 and ("  " .. table.concat(locs, "  ")) or ""
        tooltip:AddDoubleLine(
            "|cffffd700" .. r.char .. "|r",
            "|cffffffff" .. r.total .. "x|r" .. locStr
        )
        shown = shown + 1
    end

    if #rows > MAX_TT_CHARS then
        local hidden = #rows - MAX_TT_CHARS
        local extra = 0
        for i = MAX_TT_CHARS + 1, #rows do extra = extra + rows[i].total end
        tooltip:AddLine(string.format(
            "|cffaaaaaa...and %d more alt%s (%dx)|r",
            hidden, hidden == 1 and "" or "s", extra))
    end

    tooltip:AddDoubleLine(
        "|cffaaaaaa Total across all alts:|r",
        "|cffd4af37" .. grand .. "x|r"
    )
    tooltip:Show()
end

-- Extract itemID from whatever the tooltip hook receives
local function IDFromBagSlot(bag, slot)
    local _, _, _, _, _, _, link = GetContainerItemInfo(bag, slot)
    return ToItemID(link)
end

local function IDFromInventorySlot(unit, slot)
    local link = GetInventoryItemLink(unit, slot)
    return ToItemID(link)
end

-- Hook tooltip methods without replacing Blizzard return values.
-- Replacing GameTooltip methods directly can swallow the original return from
-- SetInventoryItem, which causes the paper doll to fall back to slot names
-- instead of showing the equipped item tooltip.
hooksecurefunc(GameTooltip, "SetBagItem", function(self, bag, slot)
    AppendVaultLines(self, IDFromBagSlot(bag, slot))
end)

hooksecurefunc(GameTooltip, "SetInventoryItem", function(self, unit, slot)
    AppendVaultLines(self, IDFromInventorySlot(unit, slot))
end)

hooksecurefunc(GameTooltip, "SetHyperlink", function(self, link)
    AppendVaultLines(self, ToItemID(link))
end)

-- ============================================================================
-- ITEM COUNT HELPER
-- ============================================================================
function CV.ItemCount(key)
    local e = MekTownRecruitDB.charVault and MekTownRecruitDB.charVault[key]
    if not e or not e.items then return 0 end
    local n = 0
    for _ in pairs(e.items) do n = n + 1 end
    return n
end

-- ============================================================================
-- PUBLIC QUERY API
-- ============================================================================

-- All known characters sorted by name
function CV.GetAll()
    local out = {}
    for _, e in pairs(MekTownRecruitDB.charVault or {}) do
        -- Normalise: support both old (root fields) and new (meta sub-table) format
        local m = e.meta or e
        out[#out+1] = {
            key       = e.key or m.name,
            name      = m.name      or e.name     or "?",
            realm     = m.realm     or e.realm     or "?",
            class     = m.class     or e.class     or "Unknown",
            race      = m.race      or e.race      or "Unknown",
            level     = m.level     or e.level     or 0,
            zone      = m.zone      or e.zone      or "?",
            gold      = m.gold      or e.gold      or 0,
            avgIlvl   = m.avgIlvl   or e.avgIlvl   or 0,
            lastSeen  = m.lastSeen  or e.lastSeen  or "?",
            professions = e.professions or {},
            gear      = e.gear or {},
            items     = e.items or {},
        }
    end
    table.sort(out, function(a,b) return (a.name or "") < (b.name or "") end)
    return out
end

-- Search items across all characters.
-- Returns aggregate rows: { name, link, totalBags, totalBank, totalMail, total, chars[] }
function CV.SearchItem(query)
    if not query or query == "" then return {} end
    local q = query:lower()

    -- Build aggregated results keyed by itemID
    local byID = {}
    for _, entry in pairs(MekTownRecruitDB.charVault or {}) do
        local charName = (entry.meta and entry.meta.name) or entry.name or "?"
        for id, slots in pairs(entry.items or {}) do
            local name = CV._nameCache and CV._nameCache[id]
            if not name then
                name = GetItemInfo(id) or ""
                if not CV._nameCache then CV._nameCache = {} end
                CV._nameCache[id] = name
            end
            if name ~= "" and name:lower():find(q, 1, true) then
                if not byID[id] then
                    byID[id] = {
                        id         = id,
                        name       = name,
                        link       = nil,
                        totalBags  = 0,
                        totalBank  = 0,
                        totalMail  = 0,
                        total      = 0,
                        chars      = {},
                    }
                end
                local r = byID[id]
                local tb = slots.bags or 0
                local tk = slots.bank or 0
                local tm = slots.mail or 0
                r.totalBags = r.totalBags + tb
                r.totalBank = r.totalBank + tk
                r.totalMail = r.totalMail + tm
                r.total     = r.total + tb + tk + tm
                r.chars[#r.chars+1] = {
                    char = charName, bags=tb, bank=tk, mail=tm,
                    total = tb + tk + tm,
                }
            end
        end
    end

    -- Resolve item links for display
    local out = {}
    for id, r in pairs(byID) do
        local link = GetItemLink and GetItemLink(id)
        r.link = link or r.name
        out[#out+1] = r
    end
    -- Sort: highest total first, then alphabetically
    table.sort(out, function(a,b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    return out
end

-- Professions search (unchanged — data structure same as before)
function CV.SearchProfession(query)
    local q = (query or ""):lower()
    local out = {}
    for _, entry in pairs(MekTownRecruitDB.charVault or {}) do
        local charName = (entry.meta and entry.meta.name) or entry.name or "?"
        for _, prof in ipairs(entry.professions or {}) do
            if q == "" or prof.name:lower():find(q, 1, true) then
                out[#out+1] = {
                    char    = charName,
                    name    = prof.name,
                    rank    = prof.rank,
                    max     = prof.max,
                    primary = prof.primary,
                }
            end
        end
    end
    table.sort(out, function(a,b)
        if a.name ~= b.name then return a.name < b.name end
        return (a.rank or 0) > (b.rank or 0)
    end)
    return out
end

function CV.GetGoldSorted()
    local chars = CV.GetAll()
    table.sort(chars, function(a,b) return (a.gold or 0) > (b.gold or 0) end)
    return chars
end

-- Rebuild the tooltip index on load (data may exist from a previous session)
MTR.After(3, function()
    if MekTownRecruitDB and MekTownRecruitDB.charVault then
        CV.RebuildIndex()
        MTR.dprint("CharVault: tooltip index rebuilt on load —",
            (function() local n=0 for _ in pairs(CV.tooltipIndex) do n=n+1 end return n end)(),
            "unique item IDs")
    end
end)

print("|cff00c0ff[MekTown Recruit]|r CharVault v9.1 loaded.")
