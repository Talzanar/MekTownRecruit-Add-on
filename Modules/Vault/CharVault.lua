-- ============================================================================
-- CharVault.lua  v9.1
-- MekTown Choppa'z — Per-character data engine
--
-- ARCHITECTURE (following BagSync best-practice, MekTown flavour)
-- ─────────────────────────────────────────────────────────────────
-- Storage (MekTownRecruitDB.charVault["Name-Realm"]):
--   meta        — name, realm, class, race, level, zone, gold, avgIlvl, lastSeen
--   items       — { [itemID] = {bags=N, bank=N, mail=N} }  ← compact, never stale
--   itemLinks   — { [itemID] = itemLink }                     ← preserves exact hyperlink for UI
--   itemTextures— { [itemID] = texturePath }                  ← avoids ? icons on uncached clients
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
            meta={}, items={}, itemLinks={}, itemTextures={}, professions={}, gear={},
        }
    end
    local e = MekTownRecruitDB.charVault[key]
    if not e.items       then e.items       = {} end
    if not e.itemLinks   then e.itemLinks   = {} end
    if not e.itemTextures then e.itemTextures = {} end
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
    local counts, links, textures = {}, {}, {}
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local texture, qty, _, _, _, _, link = GetContainerItemInfo(bag, slot)
            local id = ToItemID(link)
            if id and qty and qty > 0 then
                counts[id] = (counts[id] or 0) + qty
                if link and not links[id] then links[id] = link end
                if texture and not textures[id] then textures[id] = texture end
            end
        end
    end
    return { counts = counts, links = links, textures = textures }
end

-- Core bank scanner — returns item counts plus link/texture metadata
-- Only valid when BANKFRAME_OPENED has fired (bank bags aren't loaded otherwise)
local function ScanBankItems()
    local counts, links, textures = {}, {}, {}
    for bag = -1, 11 do
        for slot = 1, GetContainerNumSlots(bag) do
            local texture, qty, _, _, _, _, link = GetContainerItemInfo(bag, slot)
            local id = ToItemID(link)
            if id and qty and qty > 0 then
                counts[id] = (counts[id] or 0) + qty
                if link and not links[id] then links[id] = link end
                if texture and not textures[id] then textures[id] = texture end
            end
        end
    end
    return { counts = counts, links = links, textures = textures }
end

-- Core mail scanner — returns item counts plus link/texture metadata
-- Only valid inside MAIL_INBOX_OPENED callback
local function ScanMailItems()
    local counts, links, textures = {}, {}, {}
    local num = GetInboxNumItems()
    for i = 1, num do
        for att = 1, ATTACHMENTS_MAX_RECEIVE do
            local link = GetInboxItemLink(i, att)
            local _, _, texture, qty = GetInboxItem(i, att)
            local id = ToItemID(link)
            if id and qty and qty > 0 then
                counts[id] = (counts[id] or 0) + qty
                if link and not links[id] then links[id] = link end
                if texture and not textures[id] then textures[id] = texture end
            end
        end
    end
    return { counts = counts, links = links, textures = textures }
end

-- Merge a partial scan (bags/bank/mail) into the entry's items table
-- slotKey is "bags", "bank", or "mail"
local function MergeItems(entry, slotKey, payload)
    local newCounts = payload
    local newLinks, newTextures = nil, nil
    if type(payload) == "table" and payload.counts then
        newCounts = payload.counts or {}
        newLinks = payload.links or {}
        newTextures = payload.textures or {}
    end
    entry.itemLinks = entry.itemLinks or {}
    entry.itemTextures = entry.itemTextures or {}
    -- First zero out all existing entries for this slot type
    for _, slots in pairs(entry.items) do
        slots[slotKey] = 0
    end
    -- Write new values
    for id, qty in pairs(newCounts or {}) do
        if not entry.items[id] then
            entry.items[id] = { bags=0, bank=0, mail=0 }
        end
        entry.items[id][slotKey] = qty
        if newLinks and newLinks[id] then entry.itemLinks[id] = newLinks[id] end
        if newTextures and newTextures[id] then entry.itemTextures[id] = newTextures[id] end
    end
    -- Prune entries where everything is zero
    for id, slots in pairs(entry.items) do
        if (slots.bags or 0) == 0 and (slots.bank or 0) == 0 and (slots.mail or 0) == 0 then
            entry.items[id] = nil
            if entry.itemLinks then entry.itemLinks[id] = nil end
            if entry.itemTextures then entry.itemTextures[id] = nil end
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
                local name = GetItemInfo(link) or (link:match("%[(.-)%]") or "Unknown")
                local texture = select(10, GetItemInfo(link))
                items[#items+1] = {
                    name    = name,
                    link    = link,
                    texture = texture,
                    count   = count,
                    tab     = tab,
                    tabName = tabName,
                }
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

local function GBSyncState()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return { revision = 0, hash = "0", lastSyncAt = 0, lastSyncFrom = "" } end
    gs.syncState = gs.syncState or {}
    gs.syncState.guildBankSnapshot = gs.syncState.guildBankSnapshot or { revision = 0, hash = "0", lastSyncAt = 0, lastSyncFrom = "", lastAckByPeer = {} }
    return gs.syncState.guildBankSnapshot
end

local function GBHashFromItems(items)
    local parts = {}
    for _, item in ipairs(items or {}) do
        local iid = item.itemID or (item.link and tonumber((item.link or ""):match("item:(%d+)"))) or 0
        -- Do not hash by item display name because GetItemInfo/local cache timing
        -- can differ across clients and cause false hash mismatches.
        parts[#parts + 1] = table.concat({
            tostring(tonumber(item.tab) or 0),
            tostring(tonumber(iid) or 0),
            tostring(tonumber(item.count) or 0)
        }, "|")
    end
    table.sort(parts)
    local raw = table.concat(parts, ";")
    return (MTR.Hash and MTR.Hash(raw)) or tostring(#raw)
end

-- Store a received (or locally-scanned) item list as the guild bank snapshot
local function MergeGuildBankSnapshot(items, scannedBy, timestamp)
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or MekTownRecruitDB
    gs.guildBank = {}
    MekTownRecruitDB.guildBank = gs.guildBank
    local ts = timestamp or date("%Y-%m-%d %H:%M")
    for _, item in ipairs(items) do
        item.updated  = ts
        item.scannedBy = scannedBy or "?"
        gs.guildBank[#gs.guildBank+1] = item
    end
    MTR.dprint("GuildBank snapshot stored:", #gs.guildBank,
        "items from", scannedBy, "at", ts)
    -- Notify any open vault window to refresh
    if MTR.vaultWin and MTR.vaultWin:IsShown() then
        -- Signal to the Guild Bank tab that data changed
        MTR.GuildBankScan.dirty = true
    end
    local st = GBSyncState()
    st.lastSyncAt = time()
    st.lastSyncFrom = scannedBy or st.lastSyncFrom or "?"
end

function MTR.GetGuildBankSnapshot()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or MekTownRecruitDB
    gs.guildBank = gs.guildBank or {}
    MekTownRecruitDB.guildBank = MekTownRecruitDB.guildBank or {}
    if #gs.guildBank == 0 and #MekTownRecruitDB.guildBank > 0 then
        gs.guildBank = MekTownRecruitDB.guildBank
    elseif #MekTownRecruitDB.guildBank == 0 and #gs.guildBank > 0 then
        MekTownRecruitDB.guildBank = gs.guildBank
    end
    return gs.guildBank
end

-- Broadcast locally-scanned data to all guild members
local function BroadcastGuildBank(items, scannedBy)
    if not IsInGuild() then return end
    local chunks = BuildChunks(items)
    local hash = GBHashFromItems(items)
    local st = GBSyncState()
    local now = time()
    if tostring(st.lastBroadcastHash or "") == tostring(hash) and (now - tonumber(st.lastBroadcastAt or 0)) < 8 then
        return false
    end
    st.revision = tonumber(st.revision or 0) + 1
    st.hash = hash
    st.lastSyncAt = time()
    st.lastSyncFrom = scannedBy or "?"
    st.lastBroadcastAt = now
    st.lastBroadcastHash = hash
    local ts     = date("%Y-%m-%d %H:%M")
    if MTR.SendGuildScoped then MTR.SendGuildScoped(GB_PREFIX, "GB:S:" .. (scannedBy or "") .. ":" .. tostring(st.revision or 0) .. ":" .. tostring(hash) .. ":" .. tostring(#items or 0)) else SendAddonMessage(GB_PREFIX, "GB:S:" .. (scannedBy or "") .. ":" .. tostring(st.revision or 0) .. ":" .. tostring(hash) .. ":" .. tostring(#items or 0), "GUILD") end
    for _, chunk in ipairs(chunks) do
        if MTR.SendGuildScoped then MTR.SendGuildScoped(GB_PREFIX, "GB:D:" .. chunk) else SendAddonMessage(GB_PREFIX, "GB:D:" .. chunk, "GUILD") end
    end
    if MTR.SendGuildScoped then MTR.SendGuildScoped(GB_PREFIX, "GB:E:" .. ts) else SendAddonMessage(GB_PREFIX, "GB:E:" .. ts, "GUILD") end
    MTR.dprint("GuildBank broadcast:", #items, "items,", #chunks, "chunks")
    return true
end

local function BroadcastStoredGuildBank(reason)
    if not IsInGuild() then return false end
    local items = MekTownRecruitDB.guildBank or {}
    local by = (items[1] and items[1].scannedBy) or (MTR.playerName or "?")
    BroadcastGuildBank(items, by)
    MTR.dprint("GuildBank snapshot rebroadcast:", reason or "manual", #items, "items")
    return true
end

-- ── Public scan trigger — callable by UI button ──────────────────────────────
-- This is the only entry point that actually performs a scan.
-- It can be called from the "Scan Bank" button in the Vault UI whenever the
-- guild bank frame is already open (no need to toggle it).
local function DoGuildBankScan(opts)
    opts = opts or {}
    local includeLedger = opts.includeLedger == true
    local retry = tonumber(opts._retry or 0) or 0
    if not MTR.initialized then return end
    MTR.TickRemove("gb_scan_delay")
    MTR.TickAdd("gb_scan_delay", 1, function()
        MTR.TickRemove("gb_scan_delay")

        if not (GuildBankFrame and GuildBankFrame:IsShown()) then
            return
        end

        local numTabsReady = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
        if numTabsReady <= 0 and retry < 3 then
            local nextOpts = {
                includeLedger = includeLedger,
                interactiveSweep = opts.interactiveSweep == true,
                endAtTab1 = opts.endAtTab1 == true,
                _retry = retry + 1,
            }
            DoGuildBankScan(nextOpts)
            return
        end

        local items     = ScanGuildBank()
        local scannedBy = MTR.playerName or "?"
        local ts        = date("%Y-%m-%d %H:%M")

        MergeGuildBankSnapshot(items, scannedBy, ts)
        local sent = BroadcastGuildBank(items, scannedBy)
        if includeLedger and MTR.GuildBankLedger and MTR.GuildBankLedger.BeginLocalScan then
            MTR.GuildBankLedger.BeginLocalScan(scannedBy, { forceBroadcast = true, interactiveSweep = (opts.interactiveSweep == true) })
        end

        local numTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0
        if sent then
            MTR.MP(string.format(
                "|cffd4af37[Vault]|r Guild bank snapshot: |cffffff00%d items|r across |cffffff00%d tab%s|r  "..
                "|cffaaaaaa(synced to all online guild members)|r",
                #items, numTabs, numTabs == 1 and "" or "s"))
        else
            MTR.dprint("GuildBank scan unchanged; skipped duplicate broadcast")
        end
    end)
end
MTR.GuildBankScan.DoScan = function()
    DoGuildBankScan({ includeLedger = true, interactiveSweep = true })
end   -- expose to UI

-- ── Event listeners ────────────────────────────────────────────────────────
-- GUILDBANKFRAME_OPENED  — fires when the bank window opens
-- GUILDBANKBAGSLOTS_CHANGED — fires when tab slot data finishes loading
-- Both trigger a scan so we catch: fresh opens AND tab switches
local gbScanFrame = CreateFrame("Frame")
gbScanFrame:RegisterEvent("GUILDBANKFRAME_OPENED")
gbScanFrame:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED")
local gbOpenedAt = 0
gbScanFrame:SetScript("OnEvent", function(self, event)
    if not MTR.initialized then return end
    if event == "GUILDBANKFRAME_OPENED" then
        gbOpenedAt = time()
        DoGuildBankScan({ includeLedger = true, interactiveSweep = true, endAtTab1 = true })
        MTR.TickAdd("gb_open_rescan_1", 1.5, function()
            MTR.TickRemove("gb_open_rescan_1")
            if GuildBankFrame and GuildBankFrame:IsShown() then
                DoGuildBankScan({ includeLedger = true, interactiveSweep = true, endAtTab1 = true })
            end
        end)
        MTR.TickAdd("gb_open_rescan_2", 3.0, function()
            MTR.TickRemove("gb_open_rescan_2")
            if GuildBankFrame and GuildBankFrame:IsShown() then
                DoGuildBankScan({ includeLedger = true, interactiveSweep = true, endAtTab1 = true })
            end
        end)
        return
    end

    -- Avoid replacing the open-event interactive sweep with a plain bag scan.
    if (time() - (gbOpenedAt or 0)) < 4 then return end
    DoGuildBankScan({ includeLedger = false })
end)

-- Receive guild bank snapshot from another player
local gbRecvBuf    = nil
local gbRecvSender = nil
local gbRecvFrom   = nil
local gbRecvRev    = nil
local gbRecvHash   = nil
local gbRecvExpected = nil
local gbRecvFrame  = CreateFrame("Frame")
gbRecvFrame:RegisterEvent("CHAT_MSG_ADDON")
gbRecvFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= GB_PREFIX then return end
    if not MTR.initialized then return end

    local unpacked, senderName = (MTR.UnpackGuildScoped and MTR.UnpackGuildScoped(message, sender, false)) or message, ((sender or ""):match("^([^%-]+)") or sender or "")
    if not unpacked then return end

    if unpacked:sub(1, 5) == "GB:S:" then
        gbRecvBuf    = {}
        local by, rev, hash, expected = unpacked:match("^GB:S:([^:]*):([^:]*):([^:]*):([^:]*)")
        gbRecvSender = by or unpacked:sub(6)
        gbRecvFrom = senderName
        gbRecvRev = tonumber(rev) or nil
        gbRecvHash = (hash and hash ~= "") and hash or nil
        gbRecvExpected = tonumber(expected) or nil
        if gbRecvSender == "" then gbRecvSender = senderName end

        -- Auto-clear conflict if header hash matches local hash
        if gbRecvHash then
            local st = GBSyncState()
            if tostring(gbRecvHash) == tostring(st.hash or "0") then
                st.lastConflictReason = nil
                st.lastConflictFrom = nil
                -- Adopt higher revision if hashes match
                if gbRecvRev and gbRecvRev > tonumber(st.revision or 0) then
                    st.revision = gbRecvRev
                end
            end
        end

    elseif unpacked:sub(1, 7) == "GB:REQ:" then
        local _, peerHash = unpacked:match("^GB:REQ:([^:]*):?(.*)$")
        local st = GBSyncState()
        if tostring(peerHash or "") ~= tostring(st.hash or "0") then
            BroadcastStoredGuildBank("peer-request")
        end

    elseif unpacked:sub(1, 7) == "GB:ACK:" then
        local peer, hash, rev = unpacked:match("^GB:ACK:([^:]+):([^:]+):([^:]+)$")
        local st = GBSyncState()
        if tostring(hash or "") == tostring(st.hash or "0") then
            local r = tonumber(rev) or 0
            if r > tonumber(st.revision or 0) then st.revision = r end
            st.lastAckByPeer = st.lastAckByPeer or {}
            st.lastAckByPeer[peer or senderName or "?"] = { revision = r, at = time() }
            st.lastConflictReason = nil
            st.lastConflictFrom = nil
        end

    elseif unpacked:sub(1, 5) == "GB:D:" and gbRecvBuf then
        if gbRecvFrom and senderName ~= gbRecvFrom then return end
        local d = unpacked:sub(6)
        for token in d:gmatch("[^,]+") do
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
                    texture = nil,
                }
            end
        end

    elseif unpacked:sub(1, 5) == "GB:E:" and gbRecvBuf then
        if gbRecvFrom and senderName ~= gbRecvFrom then return end
        local ts = unpacked:sub(6)
        -- Don't overwrite with our own broadcast echo
        if senderName ~= MTR.playerName then
            local st = GBSyncState()
            if (tonumber(gbRecvExpected) or 0) > 0 and #gbRecvBuf <= 0 then
                st.lastConflictAt = time()
                st.lastConflictFrom = tostring(gbRecvSender or senderName or "?")
                st.lastConflictReason = "incomplete-stream"
                gbRecvBuf, gbRecvSender, gbRecvFrom, gbRecvRev, gbRecvHash, gbRecvExpected = nil, nil, nil, nil, nil, nil
                return
            end
            local ok = true
            st.lastRevByPeer = st.lastRevByPeer or {}
            local hashMismatch = false
            if gbRecvHash then
                local h = GBHashFromItems(gbRecvBuf)
                if h ~= gbRecvHash then hashMismatch = true end
            end
            local peerKey = tostring(senderName or gbRecvSender or "?")
            local peerPrevRev = tonumber(st.lastRevByPeer[peerKey] or 0)
            if ok and hashMismatch then
                st.lastConflictAt = time()
                st.lastConflictFrom = peerKey
                st.lastConflictReason = "hash-mismatch-accepted"
                MTR.dprint("GuildBank hash mismatch accepted from", peerKey, "(using officer payload)")
            end
            if ok then
                MergeGuildBankSnapshot(gbRecvBuf, gbRecvSender, ts)
                if gbRecvRev then st.revision = math.max(tonumber(st.revision or 0), tonumber(gbRecvRev or 0)) end
                st.hash = GBHashFromItems(gbRecvBuf)
                if gbRecvRev then st.lastRevByPeer[peerKey] = tonumber(gbRecvRev) or peerPrevRev end
                st.lastSyncAt = time()
                st.lastSyncFrom = gbRecvSender or senderName or "?"
                st.lastConflictReason = nil
                if MTR.SendGuildScoped then MTR.SendGuildScoped(GB_PREFIX, string.format("GB:ACK:%s:%s:%d", tostring(MTR.playerName or "?"), tostring(st.hash or "0"), tonumber(st.revision or 0))) else SendAddonMessage(GB_PREFIX, string.format("GB:ACK:%s:%s:%d", tostring(MTR.playerName or "?"), tostring(st.hash or "0"), tonumber(st.revision or 0)), "GUILD") end
                MTR.dprint("GuildBank received from", gbRecvSender, "—", #gbRecvBuf, "items")
            else
                st.lastConflictAt = time()
                st.lastConflictFrom = tostring(gbRecvSender or senderName or "?")
                if not st.lastConflictReason then st.lastConflictReason = "hash-mismatch" end
                MTR.MPE("[GuildBank Sync] Rejected snapshot from " .. tostring(gbRecvSender or senderName or "?") .. " (stale or hash mismatch).")
            end
        end
        gbRecvBuf    = nil
        gbRecvSender = nil
        gbRecvFrom   = nil
        gbRecvRev    = nil
        gbRecvHash   = nil
        gbRecvExpected = nil
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
local gblRecvFrom = nil
local gblRecvRev = nil
local gblRecvHash = nil
local gblRecvExpected = nil

local function GBL_DB()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or MekTownRecruitDB
    gs.guildBankLedger = gs.guildBankLedger or { entries = {}, meta = {} }
    gs.guildBankLedger.entries = gs.guildBankLedger.entries or {}
    gs.guildBankLedger.meta = gs.guildBankLedger.meta or {}
    MekTownRecruitDB.guildBankLedger = gs.guildBankLedger
    return gs.guildBankLedger
end

local function GBL_SyncState()
    local gs = MTR.GetGuildStore and MTR.GetGuildStore(true) or nil
    if not gs then return { revision = 0, hash = "0", lastSyncAt = 0, lastSyncFrom = "", lastAckByPeer = {} } end
    gs.syncState = gs.syncState or {}
    gs.syncState.guildBankLedger = gs.syncState.guildBankLedger or { revision = 0, hash = "0", lastSyncAt = 0, lastSyncFrom = "", lastAckByPeer = {} }
    return gs.syncState.guildBankLedger
end

local function GBL_DebugEnabled()
    return MTR.IsDebugEnabled and MTR.IsDebugEnabled("ledger") or false
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
    if (MTR.IsDebugChatEnabled and MTR.IsDebugChatEnabled()) and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[MTR Ledger]|r " .. line)
    end
end

function GBL.DebugEnable(flag)
    if flag then
        if MTR.SetDebugEnabled then MTR.SetDebugEnabled(true) end
        if MTR.SetDebugModuleEnabled then MTR.SetDebugModuleEnabled("ledger", true) end
    else
        if MTR.SetDebugModuleEnabled then MTR.SetDebugModuleEnabled("ledger", false) end
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

local function GBL_AgePartsToSeconds(y, m, d, h)
    local yy = tonumber(y) or 0
    local mm = tonumber(m) or 0
    local dd = tonumber(d) or 0
    local hh = tonumber(h) or 0
    return (yy * 365 * 86400) + (mm * 30 * 86400) + (dd * 86400) + (hh * 3600)
end

local function GBL_AgePartsToText(y, m, d, h)
    local yy = tonumber(y) or 0
    local mm = tonumber(m) or 0
    local dd = tonumber(d) or 0
    local hh = tonumber(h) or 0
    if yy <= 0 and mm <= 0 and dd <= 0 and hh <= 0 then return "just now" end
    if yy > 0 then return tostring(yy) .. "y ago" end
    if mm > 0 then return tostring(mm) .. "mo ago" end
    if dd > 0 then return tostring(dd) .. "d ago" end
    return tostring(hh) .. "h ago"
end

local function GBL_ParseRelativeAgeSeconds(ageText)
    if type(ageText) ~= "string" then return nil, nil end
    local s = string.lower(ageText)
    if s == "" then return nil, nil end

    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|4([^:;]+):([^;]+);", "%1")
    s = s:gsub("[%(%)]", " ")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")

    if s:find("just now", 1, true) then return 0, "minute" end
    if s:find("today", 1, true) then return 0, "day" end
    if s:find("yesterday", 1, true) then return 86400, "day" end
    if s:find("< an hour", 1, true) then return 1800, "hour" end
    if s:find("an hour ago", 1, true) then return 3600, "hour" end

    local n = tonumber(s:match("(%d+)%s*min"))
    if n then return n * 60, "minute" end

    n = tonumber(s:match("(%d+)%s*hour"))
    if n then return n * 3600, "hour" end

    n = tonumber(s:match("(%d+)%s*day"))
    if n then return n * 86400, "day" end

    n = tonumber(s:match("(%d+)%s*week"))
    if n then return n * 7 * 86400, "week" end

    n = tonumber(s:match("(%d+)%s*month"))
    if n then return n * 30 * 86400, "month" end

    n = tonumber(s:match("(%d+)%s*year"))
    if n then return n * 365 * 86400, "year" end

    n = tonumber(s:match("(%d+)%s*y"))
    if n then return n * 365 * 86400, "year" end

    n = tonumber(s:match("(%d+)%s*mo"))
    if n then return n * 30 * 86400, "month" end

    n = tonumber(s:match("(%d+)%s*w"))
    if n then return n * 7 * 86400, "week" end

    n = tonumber(s:match("(%d+)%s*d"))
    if n then return n * 86400, "day" end

    n = tonumber(s:match("(%d+)%s*h"))
    if n then return n * 3600, "hour" end

    return nil, nil
end

local function GBL_DeriveEpochFromAgeParts(y, m, d, h, baseEpoch)
    local yy = tonumber(y) or 0
    local mm = tonumber(m) or 0
    local dd = tonumber(d) or 0
    local hh = tonumber(h) or 0
    local base = tonumber(baseEpoch) or time()
    local ageSec = GBL_AgePartsToSeconds(yy, mm, dd, hh)
    if ageSec <= 0 then return 0 end

    if yy > 0 or mm > 0 or dd > 0 then
        local dayBase = math.floor(base / 86400) * 86400
        return math.max(0, dayBase - ageSec)
    end

    local hourBase = math.floor(base / 3600) * 3600
    return math.max(0, hourBase - ageSec)
end

local function GBL_DeriveEpochFromRelative(ageText, baseEpoch)
    local base = tonumber(baseEpoch) or time()
    local sec, unit = GBL_ParseRelativeAgeSeconds(ageText)
    if sec == nil then return 0, nil end

    if unit == "day" or unit == "week" or unit == "month" or unit == "year" then
        local dayBase = math.floor(base / 86400) * 86400
        return math.max(0, dayBase - sec), unit
    end
    if unit == "hour" then
        local hourBase = math.floor(base / 3600) * 3600
        return math.max(0, hourBase - sec), unit
    end
    if unit == "minute" then
        local minBase = math.floor(base / 60) * 60
        return math.max(0, minBase - sec), unit
    end
    return math.max(0, base - sec), unit
end

local function GBL_Signature(e)
    return table.concat({
        tostring(e.kind or "item"),
        tostring(e.txType or "?"),
        tostring(e.actor or "?"),
        tostring(e.itemID or 0),
        tostring(e.itemName or "?"),
        tostring(e.count or 0),
        tostring(e.tab1 or 0),
        tostring(e.tab2 or 0)
    }, "#")
end

local function GBL_Fingerprint(e)
    local txid = tostring(e.txid or "")
    if txid ~= "" then
        return "txid#" .. txid
    end
    local rough = tostring(e.relativeText or "")
    local epochHour = math.floor((tonumber(e.epoch) or 0) / 3600)
    return table.concat({
        GBL_Signature(e),
        tostring(epochHour),
        rough
    }, "#")
end

local function GBL_EnsureTxId(e)
    if not e then return "" end
    if e.txid and e.txid ~= "" then return e.txid end
    local epochBase = tonumber(e.epoch) or 0
    if epochBase <= 0 then epochBase = tonumber(e.scanEpoch) or 0 end
    local epochHour = math.floor(epochBase / 3600)
    local seed = table.concat({
        GBL_Signature(e),
        tostring(epochHour),
        tostring(e.relativeText or "")
    }, "|")
    e.txid = (MTR.Hash and MTR.Hash(seed)) or seed
    return e.txid
end

local function GBL_EffectiveEpoch(e)
    if not e then return 0 end
    local exact = (e.hasExactDate == true or e.hasExactDate == 1 or e.hasExactDate == "1")
    if exact then
        local ts = tonumber(e.epoch) or 0
        if ts > 0 then return ts end
    end
    local conf = tostring(e.timeConfidence or "")
    local ep = tonumber(e.epoch) or 0
    local fs = tonumber(e.firstSeenEpoch) or 0
    if conf ~= "first_seen" and ep > 0 then return ep end
    if fs > 0 then return fs end
    if ep > 0 then return ep end
    return tonumber(e.scanEpoch) or 0
end

local function GBL_EnsureCanonicalTime(e)
    if not e then return end
    local exact = (e.hasExactDate == true or e.hasExactDate == 1 or e.hasExactDate == "1")
    local now = time()
    local scanEpoch = tonumber(e.scanEpoch) or now

    if exact then
        e.timeConfidence = "exact_game"
        if (tonumber(e.firstSeenEpoch) or 0) <= 0 then
            e.firstSeenEpoch = tonumber(e.epoch) or scanEpoch
        end
    else
        if e.timeConfidence ~= "derived_game" and e.timeConfidence ~= "first_seen" then
            if (tonumber(e.epoch) or 0) > 0 then
                e.timeConfidence = "derived_game"
            else
                e.timeConfidence = "first_seen"
            end
        end
        if (tonumber(e.firstSeenEpoch) or 0) <= 0 then
            if (tonumber(e.epoch) or 0) > 0 then
                e.firstSeenEpoch = tonumber(e.epoch) or scanEpoch
            else
                e.firstSeenEpoch = scanEpoch
            end
        elseif e.timeConfidence ~= "first_seen" and (tonumber(e.epoch) or 0) > 0 and math.abs((tonumber(e.firstSeenEpoch) or 0) - (tonumber(e.epoch) or 0)) > (12 * 3600) then
            e.firstSeenEpoch = tonumber(e.epoch) or e.firstSeenEpoch
        end
    end

    if (e.firstSeenBy or "") == "" then
        e.firstSeenBy = e.scanBy or MTR.playerName or "?"
    end
end

local function GBL_DateText(e)
    local y = GBL_NormalizeYear(e.year)
    return string.format("%02d/%02d/%04d %02d:00", tonumber(e.day) or 1, tonumber(e.month) or 1, y, tonumber(e.hour) or 0)
end

local function GBL_EntryQualityScore(e)
    if type(e) ~= "table" then return 0 end
    local score = 0
    local hasExact = (e.hasExactDate == true or e.hasExactDate == 1 or e.hasExactDate == "1")
    if hasExact then score = score + 1000 end
    if (tonumber(e.firstSeenEpoch) or 0) > 0 then score = score + 200 end
    if (tonumber(e.epoch) or 0) > 0 then score = score + 100 end
    if (e.relativeText or "") ~= "" then score = score + 50 end
    if (e.scanBy or "") ~= "" then score = score + 10 end
    return score
end

local function GBL_PickBetterEntry(a, b)
    if not a then return b end
    if not b then return a end
    local sa = GBL_EntryQualityScore(a)
    local sb = GBL_EntryQualityScore(b)
    if sb > sa then return b end
    if sa > sb then return a end
    local ta = GBL_EffectiveEpoch(a)
    local tb = GBL_EffectiveEpoch(b)
    if tb > ta then return b end
    return a
end

local function GBL_Purge()
    local db = GBL_DB()
    local now = time()
    local cutoff = now - (GBL.RETAIN_DAYS * 86400)
    local keep = {}
    for _, e in ipairs(db.entries) do
        local ts = tonumber(e.epoch) or 0
        if e.hasExactDate then
            e.dateText = GBL_DateText(e)
        else
            if ((tonumber(e.year) or 0) > 0 or (tonumber(e.month) or 0) > 0 or (tonumber(e.day) or 0) > 0 or (tonumber(e.hour) or 0) > 0) then
                local scanEpoch = tonumber(e.scanEpoch) or time()
                local agePartEpoch = GBL_DeriveEpochFromAgeParts(e.year, e.month, e.day, e.hour, scanEpoch)
                if agePartEpoch > 0 and (ts <= 0 or tostring(e.timeConfidence or "") == "first_seen") then
                    ts = agePartEpoch
                    e.epoch = agePartEpoch
                    e.timeConfidence = "derived_game"
                end
                if agePartEpoch > 0 and ts > 0 and math.abs(ts - agePartEpoch) > (18 * 3600) then
                    ts = agePartEpoch
                    e.epoch = agePartEpoch
                    e.timeConfidence = "derived_game"
                end
            elseif ts <= 0 then
                local scanEpoch = tonumber(e.scanEpoch) or time()
                ts = scanEpoch
                e.epoch = ts
            end
            local relEpoch, relUnit = GBL_DeriveEpochFromRelative(e.relativeText, tonumber(e.scanEpoch) or time())
            if relEpoch > 0 then
                local scanEpoch = tonumber(e.scanEpoch) or time()
                local conf = tostring(e.timeConfidence or "")
                local likelyPoisonedRecent = (relUnit == "day" or relUnit == "week" or relUnit == "month" or relUnit == "year") and ts > 0 and ts >= (scanEpoch - (6 * 3600))
                if ts <= 0 or conf == "first_seen" or likelyPoisonedRecent then
                    ts = relEpoch
                    e.epoch = relEpoch
                    e.timeConfidence = "derived_game"
                end
            end
            if (e.relativeText or "") == "" and ((tonumber(e.year) or 0) > 0 or (tonumber(e.month) or 0) > 0 or (tonumber(e.day) or 0) > 0 or (tonumber(e.hour) or 0) > 0) then
                e.relativeText = GBL_AgePartsToText(e.year, e.month, e.day, e.hour)
            end
            GBL_EnsureCanonicalTime(e)
            ts = GBL_EffectiveEpoch(e)
            if ts > 0 then
                e.dateText = date("%d/%m/%Y %H:%M", ts)
            else
                e.dateText = e.relativeText and e.relativeText ~= "" and e.relativeText or "Unknown (game log timestamp unavailable)"
            end
        end
        if e.hasExactDate then
            GBL_EnsureCanonicalTime(e)
            ts = GBL_EffectiveEpoch(e)
        end
        if ts <= 0 or ts >= cutoff then
            keep[#keep + 1] = e
        end
    end

    local unique = {}
    local duplicatesRemoved = 0
    for _, e in ipairs(keep) do
        GBL_EnsureTxId(e)
        local key = (e.txid and e.txid ~= "") and ("txid#" .. tostring(e.txid)) or ("fp#" .. tostring(GBL_Fingerprint(e)))
        local prev = unique[key]
        if prev then
            local chosen = GBL_PickBetterEntry(prev, e)
            unique[key] = chosen
            if chosen ~= e then
                duplicatesRemoved = duplicatesRemoved + 1
            else
                duplicatesRemoved = duplicatesRemoved + 1
            end
        else
            unique[key] = e
        end
    end

    keep = {}
    for _, e in pairs(unique) do
        keep[#keep + 1] = e
    end

    table.sort(keep, function(a, b)
        return GBL_EffectiveEpoch(a) > GBL_EffectiveEpoch(b)
    end)
    while #keep > GBL.MAX_ENTRIES do
        table.remove(keep)
    end
    db.entries = keep
    db.meta.count = #keep
    db.meta.lastDuplicatesRemoved = duplicatesRemoved
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
        GBL_EnsureTxId(e)
        e.fingerprint = GBL_Fingerprint(e)
        existing[e.fingerprint] = e
    end
    local added = 0
    local updated = 0
    for _, e in ipairs(entries or {}) do
        if e then
            e.scanTS = e.scanTS or scanTS or date("%Y-%m-%d %H:%M")
            e.scanEpoch = tonumber(e.scanEpoch) or time()
            GBL_EnsureCanonicalTime(e)
            GBL_EnsureTxId(e)
            e.fingerprint = GBL_Fingerprint(e)

            local dup = existing[e.fingerprint]
            if not dup then
                local sig = GBL_Signature(e)
                local eEpoch = tonumber(e.epoch) or 0
                for _, old in ipairs(db.entries) do
                    if GBL_Signature(old) == sig then
                        local oEpoch = tonumber(old.epoch) or 0
                        -- Prefer enriching older unknown-time rows with newer rough/exact time.
                        if oEpoch <= 0 and eEpoch > 0 then
                            dup = old
                            break
                        end
                        if oEpoch > 0 and eEpoch <= 0 then
                            dup = old
                            break
                        end
                        if eEpoch > 0 and oEpoch > 0 and math.abs(eEpoch - oEpoch) <= (18 * 3600) then
                            dup = old
                            break
                        end
                    end
                end
            end

            if dup then
                local changed = false
                local dupEpoch = tonumber(dup.epoch) or 0
                local eEpoch = tonumber(e.epoch) or 0
                local dupDateText = string.lower(tostring(dup.dateText or ""))
                local eDateText = string.lower(tostring(e.dateText or ""))

                if dupEpoch <= 0 and eEpoch > 0 then
                    dup.epoch = e.epoch
                    changed = true
                end
                if not dup.hasExactDate and e.hasExactDate then
                    dup.hasExactDate = true
                    dup.year, dup.month, dup.day, dup.hour = e.year, e.month, e.day, e.hour
                    changed = true
                end
                if (dup.relativeText or "") == "" and (e.relativeText or "") ~= "" then
                    dup.relativeText = e.relativeText
                    changed = true
                end
                if ((dup.dateText or "") == "" or dupDateText:find("unknown", 1, true)) and (e.dateText or "") ~= "" and not eDateText:find("unknown", 1, true) then
                    dup.dateText = e.dateText
                    changed = true
                end
                if (tonumber(dup.scanEpoch) or 0) <= 0 and (tonumber(e.scanEpoch) or 0) > 0 then
                    dup.scanEpoch = e.scanEpoch
                    changed = true
                end
                if (dup.scanTS or "") == "" and (e.scanTS or "") ~= "" then
                    dup.scanTS = e.scanTS
                    changed = true
                end
                if (dup.txid or "") == "" and (e.txid or "") ~= "" then
                    dup.txid = e.txid
                    changed = true
                end
                local dFirst = tonumber(dup.firstSeenEpoch) or 0
                local eFirst = tonumber(e.firstSeenEpoch) or 0
                if eFirst > 0 and (dFirst <= 0 or eFirst < dFirst) then
                    dup.firstSeenEpoch = eFirst
                    dup.firstSeenBy = e.firstSeenBy or dup.firstSeenBy
                    changed = true
                end
                if (dup.timeConfidence or "") == "" and (e.timeConfidence or "") ~= "" then
                    dup.timeConfidence = e.timeConfidence
                    changed = true
                end
                if changed then
                    GBL_EnsureCanonicalTime(dup)
                    dup.fingerprint = GBL_Fingerprint(dup)
                    existing[dup.fingerprint] = dup
                    updated = updated + 1
                end
            else
                existing[e.fingerprint] = e
                e.syncedFrom = source or e.syncedFrom or "?"
                GBL_EnsureCanonicalTime(e)
                db.entries[#db.entries + 1] = e
                added = added + 1
            end
        end
    end
    if added > 0 or updated > 0 then
        GBL_Purge()
        db.meta.lastSyncFrom = source or db.meta.lastSyncFrom
        db.meta.lastSyncAt = scanTS or date("%Y-%m-%d %H:%M")
        db.meta.lastAdded = added
        db.meta.lastUpdated = updated
        GBL_MarkDirty()
    end
    return added, updated
end

local function GBL_EntryToToken(e)
    GBL_EnsureCanonicalTime(e)
    GBL_EnsureTxId(e)
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
        tostring(tonumber(e.epoch) or 0),
        GBL_Strip(e.scanBy or "?"),
        GBL_Strip(e.scanTS or ""),
        tostring(tonumber(e.scanEpoch) or 0),
        (e.hasExactDate and "1" or "0"),
        GBL_Strip(e.relativeText or ""),
        GBL_Strip(e.txid or ""),
        tostring(tonumber(e.firstSeenEpoch) or 0),
        GBL_Strip(e.firstSeenBy or ""),
        GBL_Strip(e.timeConfidence or "")
    }, "|")
end

local function GBL_TokenToEntry(token)
    local kind, txType, actor, itemID, itemName, count, tab1, tab2, y, m, d, h, epoch, scanBy, scanTS, scanEpoch, hasExactDate, relativeText, txid, firstSeenEpoch, firstSeenBy, timeConfidence = token:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    if not kind then
        kind, txType, actor, itemID, itemName, count, tab1, tab2, y, m, d, h, epoch, scanBy, scanTS, scanEpoch, hasExactDate, relativeText, txid = token:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    end
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
        epoch = tonumber(epoch) or 0,
        scanBy = scanBy ~= "" and scanBy or "?",
        scanTS = scanTS ~= "" and scanTS or date("%Y-%m-%d %H:%M"),
        scanEpoch = tonumber(scanEpoch) or 0,
        hasExactDate = tostring(hasExactDate or "0") == "1",
        relativeText = relativeText ~= "" and relativeText or nil,
        txid = txid ~= "" and txid or nil,
        firstSeenEpoch = tonumber(firstSeenEpoch) or 0,
        firstSeenBy = firstSeenBy ~= "" and firstSeenBy or nil,
        timeConfidence = timeConfidence ~= "" and timeConfidence or nil,
    }
    if e.itemID and e.itemID > 0 then
        e.itemLink = GetItemInfo(e.itemID)
        e.itemLink = select(2, GetItemInfo(e.itemID)) or ("|cffffffff|Hitem:" .. e.itemID .. ":0:0:0:0:0:0:0|h[" .. e.itemName .. "]|h|r")
    end
    if e.epoch <= 0 then
        e.epoch = e.hasExactDate and GBL_BuildEpoch(e.year, e.month, e.day, e.hour) or 0
    end
    if e.hasExactDate then
        e.dateText = GBL_DateText(e)
    elseif e.epoch > 0 then
        local shownEpoch = (tonumber(e.firstSeenEpoch) or 0) > 0 and tonumber(e.firstSeenEpoch) or tonumber(e.epoch)
        e.dateText = date("%d/%m/%Y %H:%M", shownEpoch)
    else
        e.dateText = (e.relativeText and e.relativeText ~= "" and e.relativeText) or "Unknown (game log timestamp unavailable)"
    end
    if not e.scanEpoch or e.scanEpoch <= 0 then e.scanEpoch = time() end
    GBL_EnsureCanonicalTime(e)
    GBL_EnsureTxId(e)
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

local function GBL_HashEntries(entries)
    local tokens = {}
    for _, e in ipairs(entries or {}) do
        local txid = GBL_EnsureTxId(e)
        if txid ~= "" then
            tokens[#tokens + 1] = "txid#" .. tostring(txid)
        else
            tokens[#tokens + 1] = "fp#" .. tostring(GBL_Fingerprint(e))
        end
    end
    table.sort(tokens)
    local raw = table.concat(tokens, ";")
    return (MTR.Hash and MTR.Hash(raw)) or tostring(#raw)
end

local function GBL_Broadcast(entries, sourceTag)
    if not IsInGuild() then return end
    entries = entries or GBL_DB().entries or {}
    GBL_Purge()
    local chunks = GBL_BuildChunks(entries)
    local hash = GBL_HashEntries(entries)
    local ss = GBL_SyncState()
    ss.revision = tonumber(ss.revision or 0) + 1
    ss.hash = hash
    ss.lastSyncAt = time()
    ss.lastSyncFrom = MTR.playerName or "?"
    local who = MTR.playerName or "?"
    local ts = date("%Y-%m-%d %H:%M")
    if MTR.SendGuildScoped then MTR.SendGuildScoped(GBL_PREFIX, "GL:S:" .. who .. ":" .. tostring(#entries) .. ":" .. sourceTag .. ":" .. ts .. ":" .. tostring(ss.revision or 0) .. ":" .. tostring(hash)) else SendAddonMessage(GBL_PREFIX, "GL:S:" .. who .. ":" .. tostring(#entries) .. ":" .. sourceTag .. ":" .. ts .. ":" .. tostring(ss.revision or 0) .. ":" .. tostring(hash), "GUILD") end
    for _, chunk in ipairs(chunks) do
        if MTR.SendGuildScoped then MTR.SendGuildScoped(GBL_PREFIX, "GL:D:" .. chunk) else SendAddonMessage(GBL_PREFIX, "GL:D:" .. chunk, "GUILD") end
    end
    if MTR.SendGuildScoped then MTR.SendGuildScoped(GBL_PREFIX, "GL:E:" .. ts) else SendAddonMessage(GBL_PREFIX, "GL:E:" .. ts, "GUILD") end
end

local gblScanState = {
    active = false,
    scanBy = nil,
    tabs = nil,
    idx = 0,
    entries = nil,
    waitingTab = nil,
    forceBroadcast = false,
    interactiveSweep = false,
    endAtTab1 = false,
    origMode = nil,
    origTab = nil,
}

local function GBL_AgeTextToEpoch(ageText, baseEpoch)
    local derived = GBL_DeriveEpochFromRelative(ageText, baseEpoch)
    return tonumber(derived) or 0
end

-- Legacy compatibility shim. The old implementation scraped the visible guild
-- bank log frame text. That scraper was removed during cleanup, but fallback
-- callsites remain; keep a safe no-op so the module never hard-errors.
local function GBL_ScrapeVisibleLogFrame(tab, entries, scanBy)
    if not entries then return 0 end
    GBL_Debug("Visible log scraper unavailable (noop) tab=" .. tostring(tab) .. " scanBy=" .. tostring(scanBy or "?"))
    return 0
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

            local year = tonumber(y) or 0
            local month = tonumber(m) or 0
            local day = tonumber(d) or 0
            local hour = tonumber(h) or 0
            local hasExactDate = year > 1900 and month > 0 and day > 0
            local scanEpoch = time()
            local derivedEpoch = hasExactDate and GBL_BuildEpoch(year, month, day, hour) or GBL_DeriveEpochFromAgeParts(year, month, day, hour, scanEpoch)

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
                year = year,
                month = month,
                day = day,
                hour = hour,
                scanBy = scanBy or MTR.playerName or "?",
                scanTS = date("%Y-%m-%d %H:%M"),
                scanEpoch = scanEpoch,
                source = "api",
                hasExactDate = hasExactDate and true or false,
            }
            e.epoch = derivedEpoch
            e.relativeText = hasExactDate and nil or GBL_AgePartsToText(year, month, day, hour)
            GBL_EnsureCanonicalTime(e)
            e.dateText = hasExactDate and GBL_DateText(e) or (GBL_EffectiveEpoch(e) > 0 and date("%d/%m/%Y %H:%M", GBL_EffectiveEpoch(e)) or "Unknown (game log timestamp unavailable)")
            GBL_EnsureTxId(e)
            e.fingerprint = GBL_Fingerprint(e)
            entries[#entries + 1] = e
        end
    end

    GBL_Debug("Tab " .. tostring(tab) .. " API entries added=" .. tostring(#entries - before))

    if gblScanState and gblScanState.interactiveSweep then
        local beforeScrape = #entries
        local scraped = GBL_ScrapeVisibleLogFrame(tab, entries, scanBy)
        GBL_Debug("Tab " .. tostring(tab) .. " interactive scrape added=" .. tostring((#entries - beforeScrape)) .. " raw=" .. tostring(scraped or 0))
    end

    if #entries == before then
        local canScrapeVisible = (GuildBankFrame and GuildBankFrame.mode == "log") and (GetCurrentGuildBankTab and (tonumber(GetCurrentGuildBankTab()) or 0) == tonumber(tab))
        if canScrapeVisible then
            GBL_Debug("Tab " .. tostring(tab) .. " API returned no entries; using visible log text fallback")
            GBL_ScrapeVisibleLogFrame(tab, entries, scanBy)
        else
            GBL_Debug("Tab " .. tostring(tab) .. " API returned no entries; passive mode (no visible fallback)")
        end
    end
end

local function GBL_ReadMoneyTransactions(entries, scanBy)
    if not entries then return end
    if not GetNumGuildBankMoneyTransactions or not GetGuildBankMoneyTransaction then
        GBL_Debug("Money log API unavailable")
        return
    end
    local okN, n = pcall(GetNumGuildBankMoneyTransactions)
    if not okN or type(n) ~= "number" or n <= 0 then
        GBL_Debug("Money log count unavailable or empty")
        return
    end

    GBL_Debug("Money log entries count=" .. tostring(n))
    for i = 1, n do
        local ok, txType, actor, amount, y, m, d, h = pcall(GetGuildBankMoneyTransaction, i)
        if ok and txType then
            local yy = tonumber(y) or 0
            local mm = tonumber(m) or 0
            local dd = tonumber(d) or 0
            local hh = tonumber(h) or 0
            local hasExactDate = yy > 1900 and mm > 0 and dd > 0
            local scanEpoch = time()
            local derivedEpoch = hasExactDate and GBL_BuildEpoch(yy, mm, dd, hh) or GBL_DeriveEpochFromAgeParts(yy, mm, dd, hh, scanEpoch)
            local e = {
                kind = "money",
                txType = txType,
                actor = actor or "?",
                itemID = 0,
                itemLink = nil,
                itemName = "Gold",
                count = tonumber(amount) or 0,
                tab1 = 0,
                tab2 = 0,
                year = yy,
                month = mm,
                day = dd,
                hour = hh,
                scanBy = scanBy or MTR.playerName or "?",
                scanTS = date("%Y-%m-%d %H:%M"),
                scanEpoch = scanEpoch,
                source = "api-money",
                hasExactDate = hasExactDate and true or false,
            }
            e.epoch = derivedEpoch
            e.relativeText = hasExactDate and nil or GBL_AgePartsToText(yy, mm, dd, hh)
            GBL_EnsureCanonicalTime(e)
            e.dateText = hasExactDate and GBL_DateText(e) or (GBL_EffectiveEpoch(e) > 0 and date("%d/%m/%Y %H:%M", GBL_EffectiveEpoch(e)) or "Unknown (game money-log timestamp unavailable)")
            GBL_EnsureTxId(e)
            e.fingerprint = GBL_Fingerprint(e)
            entries[#entries + 1] = e
        end
    end
end

local function GBL_RestoreGuildBankView(endAtTab1, origMode, origTab)
    if not (GuildBankFrame and GuildBankFrame:IsShown()) then return end

    local targetMode = endAtTab1 and "bank" or (origMode or "bank")
    local targetTab = endAtTab1 and 1 or (tonumber(origTab) or 1)
    if targetTab <= 0 then targetTab = 1 end

    local function applyNow()
        if not (GuildBankFrame and GuildBankFrame:IsShown()) then return end

        GuildBankFrame.mode = targetMode
        if targetMode == "bank" and SetCurrentGuildBankTab then
            pcall(SetCurrentGuildBankTab, targetTab)
        end

        if GuildBankFrame_Update then
            pcall(GuildBankFrame_Update)
        end
    end

    MTR.TickRemove("gb_restore_view_1")
    MTR.TickRemove("gb_restore_view_2")
    applyNow()
    MTR.TickAdd("gb_restore_view_1", 0.25, function()
        MTR.TickRemove("gb_restore_view_1")
        applyNow()
    end)
    MTR.TickAdd("gb_restore_view_2", 0.75, function()
        MTR.TickRemove("gb_restore_view_2")
        applyNow()
    end)
end

local function GBL_FinalizeScan()
    local entries = gblScanState.entries or {}
    local scanBy = gblScanState.scanBy or MTR.playerName or "?"
    gblScanState.active = false
    gblScanState.waitingTab = nil
    MTR.TickRemove("gb_ledger_timeout")

    if gblScanState.interactiveSweep then
        GBL_RestoreGuildBankView(gblScanState.endAtTab1, gblScanState.origMode, gblScanState.origTab)
    end

    local added, updated = GBL_MergeEntries(entries, scanBy, date("%Y-%m-%d %H:%M"))
    local db = GBL_DB()
    db.meta.lastScanBy = scanBy
    db.meta.lastScanAt = date("%Y-%m-%d %H:%M")
    db.meta.lastRawSeen = #entries

    GBL_Debug("Finalize scan: rawEntries=" .. tostring(#entries) .. " mergedNew=" .. tostring(added) .. " mergedUpdated=" .. tostring(updated or 0) .. " retained=" .. tostring(#(db.entries or {})))

    if added > 0 or (tonumber(updated) or 0) > 0 or gblScanState.forceBroadcast then
        GBL_Broadcast(db.entries, "scan")
        MTR.dprint("GuildBank ledger scan merged", added, "new and", tostring(updated or 0), "updated entries")
    else
        MTR.dprint("GuildBank ledger scan found 0 new entries; raw visible entries =", #entries)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[MTR Ledger]|r Scan finished with 0 captured entries. Enable Debug and run |cffffff00/mek ledgerdebug show|r to dump the logic path.")
        end
    end
    gblScanState.forceBroadcast = false
    gblScanState.interactiveSweep = false
    gblScanState.endAtTab1 = false
    gblScanState.origMode = nil
    gblScanState.origTab = nil
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

    if gblScanState.interactiveSweep then
        if SetCurrentGuildBankTab then pcall(SetCurrentGuildBankTab, tab) end
        if GuildBankFrame then GuildBankFrame.mode = "log" end
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

local function GBL_CollectTransactions(scanBy, opts)
    opts = opts or {}
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
    gblScanState.forceBroadcast = (opts.forceBroadcast == true)
    gblScanState.interactiveSweep = (opts.interactiveSweep == true)
    gblScanState.endAtTab1 = (opts.endAtTab1 == true)
    gblScanState.origMode = (GuildBankFrame and GuildBankFrame.mode) or nil
    gblScanState.origTab = (GetCurrentGuildBankTab and tonumber(GetCurrentGuildBankTab()) or 0)

    for tab = 1, numTabs do
        gblScanState.tabs[#gblScanState.tabs + 1] = tab
    end

    if QueryGuildBankLog then pcall(QueryGuildBankLog, 0) end
    GBL_ReadMoneyTransactions(gblScanState.entries, gblScanState.scanBy)

    GBL_QueryNextTab()
end

local gblScanFrame = CreateFrame("Frame")
gblScanFrame:RegisterEvent("GUILDBANKLOG_UPDATE")
gblScanFrame:SetScript("OnEvent", function(_, event)
    GBL_Debug("Event fired: " .. tostring(event) .. " waitingTab=" .. tostring(gblScanState.waitingTab))
    if not gblScanState.active then
        local canCapture = GuildBankFrame and GuildBankFrame:IsShown() and GuildBankFrame.mode == "log" and GetCurrentGuildBankTab
        if canCapture then
            local tab = tonumber(GetCurrentGuildBankTab()) or 0
            if tab > 0 then
                local temp = {}
                local addedRaw = GBL_ScrapeVisibleLogFrame(tab, temp, MTR.playerName or "?")
                local merged = GBL_MergeEntries(temp, MTR.playerName or "?", date("%Y-%m-%d %H:%M"))
                if merged > 0 then
                    GBL_Broadcast(GBL_DB().entries, "passive-log")
                end
                GBL_Debug("Passive visible-log capture tab=" .. tostring(tab) .. " raw=" .. tostring(addedRaw) .. " merged=" .. tostring(merged))
            end
        end
        return
    end
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
    local ss = GBL_SyncState()
    if MTR.SendGuildScoped then MTR.SendGuildScoped(GBL_PREFIX, "GL:R:" .. (MTR.playerName or "?") .. ":" .. tostring(ss.hash or "0")) else SendAddonMessage(GBL_PREFIX, "GL:R:" .. (MTR.playerName or "?") .. ":" .. tostring(ss.hash or "0"), "GUILD") end
end

function GBL.BeginLocalScan(scanBy, opts)
    GBL_CollectTransactions(scanBy, opts)
end

local gblRecvFrame = CreateFrame("Frame")
gblRecvFrame:RegisterEvent("CHAT_MSG_ADDON")
gblRecvFrame:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= GBL_PREFIX then return end
    if not MTR.initialized then return end
    local unpacked, senderName = (MTR.UnpackGuildScoped and MTR.UnpackGuildScoped(message, sender, false)) or message, ((sender or ""):match("^([^%-]+)") or sender or "")
    if not unpacked then return end

    if unpacked:sub(1, 5) == "GL:R:" then
        local _, peerHash = unpacked:match("^GL:R:([^:]*):?(.*)$")
        if senderName ~= MTR.playerName then
            local ss = GBL_SyncState()
            if tostring(peerHash or "") ~= tostring(ss.hash or "0") then
                GBL_Broadcast(GBL.GetEntries(), "reply")
            end
        end
    elseif unpacked:sub(1, 7) == "GL:ACK:" then
        local peer, hash, rev = unpacked:match("^GL:ACK:([^:]+):([^:]+):([^:]+)$")
        local ss = GBL_SyncState()
        if tostring(hash or "") == tostring(ss.hash or "0") then
            local r = tonumber(rev) or 0
            if r > tonumber(ss.revision or 0) then ss.revision = r end
            ss.lastAckByPeer = ss.lastAckByPeer or {}
            ss.lastAckByPeer[peer or senderName or "?"] = { revision = r, at = time() }
            ss.lastConflictReason = nil
            ss.lastConflictFrom = nil
        end
    elseif unpacked:sub(1, 5) == "GL:S:" then
        gblRecvBuf = {}
        local _, count, _, _, rev, hash = unpacked:match("^GL:S:([^:]*):([^:]*):([^:]*):([^:]*):?([^:]*):?(.*)$")
        gblRecvFrom = senderName
        gblRecvRev = tonumber(rev) or nil
        gblRecvHash = (hash and hash ~= "") and hash or nil
        gblRecvExpected = tonumber(count) or nil

        -- Auto-clear conflict if header hash matches local hash
        if gblRecvHash then
            local ss = GBL_SyncState()
            if tostring(gblRecvHash) == tostring(ss.hash or "0") then
                ss.lastConflictReason = nil
                ss.lastConflictFrom = nil
                -- Adopt higher revision if hashes match
                if gblRecvRev and gblRecvRev > tonumber(ss.revision or 0) then
                    ss.revision = gblRecvRev
                end
            end
        end
    elseif unpacked:sub(1, 5) == "GL:D:" and gblRecvBuf then
        if gblRecvFrom and senderName ~= gblRecvFrom then return end
        local d = unpacked:sub(6)
        for token in d:gmatch("[^;]+") do
            local e = GBL_TokenToEntry(token)
            if e then gblRecvBuf[#gblRecvBuf + 1] = e end
        end
    elseif unpacked:sub(1, 5) == "GL:E:" and gblRecvBuf then
        if gblRecvFrom and senderName ~= gblRecvFrom then return end
        if senderName ~= MTR.playerName then
            local ok = true
            local ss = GBL_SyncState()
            if (tonumber(gblRecvExpected) or 0) > 0 and #gblRecvBuf <= 0 then
                ss.lastConflictAt = time()
                ss.lastConflictFrom = tostring(senderName or "?")
                ss.lastConflictReason = "incomplete-stream"
                gblRecvBuf, gblRecvFrom, gblRecvRev, gblRecvHash, gblRecvExpected = nil, nil, nil, nil, nil
                return
            end
            ss.lastRevByPeer = ss.lastRevByPeer or {}
            local hashMismatch = false
            if gblRecvHash then
                local rh = GBL_HashEntries(gblRecvBuf)
                if rh ~= gblRecvHash then hashMismatch = true end
            end
            local peerKey = tostring(senderName or "?")
            local peerPrevRev = tonumber(ss.lastRevByPeer[peerKey] or 0)
            if ok and hashMismatch then
                ss.lastConflictAt = time()
                ss.lastConflictFrom = peerKey
                ss.lastConflictReason = "hash-mismatch-accepted"
                MTR.dprint("Ledger hash mismatch accepted from", peerKey, "(using officer payload)")
            end
            if ok then
                GBL_MergeEntries(gblRecvBuf, senderName, unpacked:sub(6))
                if gblRecvRev then ss.revision = math.max(tonumber(ss.revision or 0), tonumber(gblRecvRev or 0)) end
                ss.hash = GBL_HashEntries(gblRecvBuf)
                if gblRecvRev then ss.lastRevByPeer[peerKey] = tonumber(gblRecvRev) or peerPrevRev end
                ss.lastSyncAt = time()
                ss.lastSyncFrom = senderName or ss.lastSyncFrom or "?"
                ss.lastConflictReason = nil
                if MTR.SendGuildScoped then MTR.SendGuildScoped(GBL_PREFIX, string.format("GL:ACK:%s:%s:%d", tostring(MTR.playerName or "?"), tostring(ss.hash or "0"), tonumber(ss.revision or 0))) else SendAddonMessage(GBL_PREFIX, string.format("GL:ACK:%s:%s:%d", tostring(MTR.playerName or "?"), tostring(ss.hash or "0"), tonumber(ss.revision or 0)), "GUILD") end
            else
                ss.lastConflictAt = time()
                ss.lastConflictFrom = tostring(senderName or "?")
                ss.lastConflictReason = "hash-mismatch"
                MTR.MPE("[Ledger Sync] Rejected ledger snapshot from " .. tostring(senderName or "?") .. " (stale or hash mismatch).")
            end
        end
        gblRecvBuf = nil
        gblRecvFrom = nil
        gblRecvRev = nil
        gblRecvHash = nil
        gblRecvExpected = nil
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
local function SafeHookTooltip(methodName, fn)
    if type(hooksecurefunc) ~= "function" then return end
    if type(GameTooltip) ~= "table" then return end
    if type(GameTooltip[methodName]) ~= "function" then return end
    local ok = pcall(hooksecurefunc, GameTooltip, methodName, fn)
    if not ok then
        GBL_Debug("hooksecurefunc failed for GameTooltip:" .. tostring(methodName))
    end
end

SafeHookTooltip("SetBagItem", function(self, bag, slot)
    AppendVaultLines(self, IDFromBagSlot(bag, slot))
end)

SafeHookTooltip("SetInventoryItem", function(self, unit, slot)
    AppendVaultLines(self, IDFromInventorySlot(unit, slot))
end)

SafeHookTooltip("SetHyperlink", function(self, link)
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
