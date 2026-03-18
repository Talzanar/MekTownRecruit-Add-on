-- ============================================================================
-- GuildAds.lua  v8.0
-- Guild Advertisement Auto-Poster
--
-- v8.0: Removed own tick frame — all timing goes through MTR.TickAdd().
--       Status label updates run at 1-second intervals instead of per-frame.
--       SubstituteIcons uses plain string.gsub instead of escaped pattern.
-- ============================================================================
local MTR = MekTownRecruit

-- ============================================================================
-- ICON SUBSTITUTION  ({star}, {skull}, etc.)
-- |T texture markup is rejected by SendChatMessage in public channels.
-- {rt1}-{rt8} are the WoW chat-safe raid marker codes — the chat engine
-- converts them to the actual icons exactly like typing them in a macro.
-- ============================================================================
local ICON_SUB = {
    star     = "{rt1}",
    circle   = "{rt2}",
    diamond  = "{rt3}",
    triangle = "{rt4}",
    moon     = "{rt5}",
    square   = "{rt6}",
    cross    = "{rt7}",
    skull    = "{rt8}",
}

local function SubstituteIcons(text)
    if not text then return "" end
    -- Strip any leading slash-command prefix the user may have included
    -- e.g. "/1 message" or "/2 message" — SendChatMessage handles routing
    text = text:gsub("^%s*/%d+%s+", "")
    text = text:gsub("^%s*", "")
    return (text:gsub("{(%a+)}", function(name)
        return ICON_SUB[name:lower()] or ("{" .. name .. "}")
    end))
end

-- ============================================================================
-- MODULE
-- ============================================================================
local GA = {}
MTR.GuildAds = GA

GA.active    = false
GA.timer     = 0
GA.msgIndex  = 1
GA.statusLabel = nil

-- ============================================================================
-- CONFIG / MESSAGE ACCESSORS
-- ============================================================================
local function Cfg()
    if not MTR.db then return MTR.DEFAULTS.guildAdConfig end
    if not MTR.db.guildAdConfig then
        MTR.db.guildAdConfig = MTR.DeepCopy(MTR.DEFAULTS.guildAdConfig)
    end
    return MTR.db.guildAdConfig
end

local function Msgs()
    if not MTR.db then return {} end
    if not MTR.db.guildAdMessages then
        MTR.db.guildAdMessages = MTR.DeepCopy(MTR.DEFAULTS.guildAdMessages)
    end
    return MTR.db.guildAdMessages
end

-- ============================================================================
-- SELECT NEXT MESSAGE
-- With one enabled message: always use it.
-- With multiple enabled messages: pick at random, avoiding the last one used
-- so the same message never posts twice in a row.
-- ============================================================================
local function NextMessage()
    local msgs = Msgs()
    if #msgs == 0 then return nil end

    -- Collect all enabled message indices
    local enabled = {}
    for i, m in ipairs(msgs) do
        if m.enabled ~= false and m.text and m.text ~= "" then
            enabled[#enabled+1] = i
        end
    end
    if #enabled == 0 then return nil end

    -- With only one choice, just use it
    if #enabled == 1 then
        GA.msgIndex = enabled[1]
        return SubstituteIcons(msgs[GA.msgIndex].text)
    end

    -- With multiple, pick randomly — exclude the last used index to avoid repeats
    local candidates = {}
    for _, idx in ipairs(enabled) do
        if idx ~= GA.msgIndex then candidates[#candidates+1] = idx end
    end
    -- Fallback: if all indices are the same as last (shouldn't happen), use full list
    if #candidates == 0 then candidates = enabled end

    GA.msgIndex = candidates[math.random(1, #candidates)]
    return SubstituteIcons(msgs[GA.msgIndex].text)
end

-- ============================================================================
-- POST
-- ============================================================================
function GA.PostNow()
    if not (MTR.isOfficer or MTR.isGM) then
        MTR.MPE("Guild Ads are restricted to officers and the Guild Master.")
        return false
    end
    local msg = NextMessage()
    if not msg then
        MTR.MP("|cffd4af37[Guild Ads]|r No enabled messages. Add some in the Recruit tab.")
        return false
    end
    local cfg = Cfg()
    local cid = cfg and cfg.channelNum or 1
    if not GetChannelDisplayInfo(cid) then
        cid = MTR.GetBestLFGChannelID() or cid
    end
    if not cid or cid <= 0 then
        MTR.MPE("|cffd4af37[Guild Ads]|r Could not find a joined channel to post to.")
        return false
    end
    MTR.SendChatSafe(msg, "CHANNEL", nil, cid)
    MTR.MP("|cffd4af37[Guild Ads]|r Posted to /" .. cid .. ": " .. MTR.Trunc(msg, 80))
    return true
end

-- ============================================================================
-- STATUS LABEL
-- ============================================================================
function GA.UpdateStatusLabel()
    if not GA.statusLabel then return end
    if GA.active then
        local secs = math.max(0, math.ceil(GA.timer))
        local mins, s = math.floor(secs/60), secs%60
        local msgs    = Msgs()
        local en      = 0
        for _, m in ipairs(msgs) do
            if m.enabled ~= false and (m.text or "") ~= "" then en = en + 1 end
        end
        GA.statusLabel:SetText(
            "|cff00ff00● Active|r  |cffaaaaaa" .. en .. " msgs — next post in " ..
            string.format("%d:%02d", mins, s) .. "|r"
        )
    else
        GA.statusLabel:SetText("|cffff4444● Stopped|r  |cffaaaaaa(press Start to begin)|r")
    end
end

-- ============================================================================
-- START
-- ============================================================================
function GA.Start()
    if not (MTR.isOfficer or MTR.isGM) then
        MTR.MPE("Guild Ads are restricted to officers and the Guild Master.")
        return
    end
    local msgs = Msgs()
    local hasEnabled = false
    for _, m in ipairs(msgs) do
        if m.enabled ~= false and (m.text or "") ~= "" then hasEnabled = true break end
    end
    if not hasEnabled then
        MTR.MPE("|cffd4af37[Guild Ads]|r No enabled messages. Add some in the Recruit tab first.")
        return
    end

    local cfg = Cfg()
    GA.active = true
    GA.timer  = (cfg and cfg.intervalMins or 10) * 60   -- wait full interval before first post
    if cfg then cfg.active = true end

    -- Register 1-second tick with master scheduler
    MTR.TickAdd("guildads", 1, function()
        if not GA.active then
            MTR.TickRemove("guildads")
            return
        end
        GA.timer = GA.timer - 1
        if GA.timer <= 0 then
            local c = Cfg()
            GA.timer = (c and c.intervalMins or 10) * 60
            GA.PostNow()
        end
        GA.UpdateStatusLabel()
    end)

    MTR.MP("|cffd4af37[Guild Ads]|r |cff00ff00Started.|r  Posting every " ..
        ((cfg and cfg.intervalMins) or 10) .. "m to /" ..
        ((cfg and cfg.channelNum) or 1) .. ".")
    GA.UpdateStatusLabel()
end

-- ============================================================================
-- STOP
-- ============================================================================
function GA.Stop()
    if not (MTR.isOfficer or MTR.isGM) then
        MTR.MPE("Guild Ads are restricted to officers and the Guild Master.")
        return
    end
    if not GA.active then return end
    GA.active = false
    MTR.TickRemove("guildads")
    local cfg = Cfg()
    if cfg then cfg.active = false end
    MTR.MP("|cffd4af37[Guild Ads]|r |cffff4444Stopped.|r")
    GA.UpdateStatusLabel()
end

function GA.Toggle()
    if GA.active then GA.Stop() else GA.Start() end
end

-- ============================================================================
-- RESTORE ON LOGIN
-- ============================================================================
function GA.RestoreState()
    local cfg = Cfg()
    if cfg and cfg.active then
        MTR.After(10, function()
            if not GA.active then
                MTR.MP("|cffd4af37[Guild Ads]|r Restoring from last session...")
                GA.Start()
            end
        end)
    end
end
