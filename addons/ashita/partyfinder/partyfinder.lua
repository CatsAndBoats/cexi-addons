--[[
* MIT License
*
* Copyright (c) 2023-2026 CatsEyeXI [https://github.com/CatsAndBoats]
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
]]--

addon.name      = 'partyfinder';
addon.author    = 'Carver';
addon.version   = '2.14';
addon.desc      = 'Party Finder for CatsEyeXI Private Server';
addon.link      = '[https://catseyexi.com]';

require('common');
local ffi    = require('ffi');
local images = require('images');
local imgui  = require('imgui');
local sounds = require('sounds');

local function pfprint(msg)
    AshitaCore:GetChatManager():AddChatMessage(142, false, '[PartyFinder] ' .. msg);
end

------------------------------------------------------------
-- Packet constants
------------------------------------------------------------
local PACKET_ID = 0x1A2;

local C2S = {
    REGISTER      = 1,
    WITHDRAW      = 2,
    REFRESH       = 3,
    ROULETTE_ROLL = 4,
    ROULETTE_GO   = 5,
    MISSION_START = 6,
    READY         = 7,
    JOIN_REQUEST  = 8,
    JOIN_RESPOND  = 9,
    DUTY_DECLINE  = 10,
};

local S2C = {
    CLEAR         = 0,
    ENTRY         = 1,
    END_LIST      = 2,
    ACK_REGISTER  = 3,
    ACK_WITHDRAW  = 4,
    ROULETTE_DUTY = 5,
    ROULETTE_ERR  = 6,
    ROULETTE_OK   = 7,
    MISSION_ENTRY = 8,
    MISSION_END   = 9,
    READY_UPDATE  = 10,
    JOIN_REQUEST      = 11,
    JOIN_RESULT       = 12,
    DUTY_DECLINE      = 13,
    LISTINGS_CHANGED  = 14,
    PARTY_MEMBER      = 15,
};

-- Server availability tracking (kill-switch detection)
-- If a REFRESH is sent and no S2C response arrives within PF_PING_TIMEOUT seconds,
-- the addon retries up to PF_PING_MAX_RETRIES times before giving up. If all
-- retries fail the server is assumed to have PARTYFINDER_ENABLED=false and the
-- UI is closed.
-- Uses os.time() (wall clock) so alt-tabbing the client doesn't spuriously trip it.
-- Retries exist because first-login / zone-in latency can exceed a single timeout
-- window (player session not yet fully established when the refresh fires).
local PF_PING_TIMEOUT     = 6;
local PF_PING_MAX_RETRIES = 3;
local pingPendingSince    = nil;
local pingRetryCount      = 0;
local serverDisabled      = false;

------------------------------------------------------------
-- Category definitions
------------------------------------------------------------
local CATEGORIES = {
    { id = 0, name = 'All',     color = { 0.80, 0.80, 0.80, 1.0 } },
    { id = 1, name = 'EXP',     color = { 0.40, 0.80, 0.40, 1.0 } },
    { id = 2, name = 'Mission', color = { 0.40, 0.60, 1.00, 1.0 } },
    { id = 3, name = 'BCNM',    color = { 1.00, 0.50, 0.30, 1.0 } },
    { id = 4, name = 'Mentor',  color = { 0.90, 0.70, 1.00, 1.0 } },
    { id = 5, name = 'Venture', color = { 1.00, 0.85, 0.40, 1.0 } },
};

local CATEGORY_NAMES = {};
for _, cat in ipairs(CATEGORIES) do
    CATEGORY_NAMES[cat.id] = cat.name;
end

------------------------------------------------------------
-- Job data
------------------------------------------------------------
local JOB_ABBR = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

------------------------------------------------------------
-- Role definitions
------------------------------------------------------------
local ROLES = {
    { id = 0, name = 'Any',     jobIcon = 1,  color = { 0.70, 0.70, 0.70, 1.0 } }, -- WAR icon placeholder
    { id = 1, name = 'Tank',    jobIcon = 7,  color = { 0.30, 0.50, 1.00, 1.0 } }, -- PLD icon
    { id = 2, name = 'Healer',  jobIcon = 3,  color = { 0.40, 1.00, 0.40, 1.0 } }, -- WHM icon
    { id = 3, name = 'Support', jobIcon = 10, color = { 1.00, 0.80, 0.30, 1.0 } }, -- BRD icon
    { id = 4, name = 'DPS',     jobIcon = 8,  color = { 1.00, 0.35, 0.35, 1.0 } }, -- DRK icon
};

local ROLE_NAMES = {};
for _, r in ipairs(ROLES) do
    ROLE_NAMES[r.id] = r.name;
end

------------------------------------------------------------
-- Settings (Ashita settings module, per-character)
------------------------------------------------------------
local ashitaSettings = require('settings');

local default_settings = T{
    lfmNotifications = true,
    tutorialComplete = false,
    tooltipsEnabled  = true,
    confirmWithdraw  = true,
    joinableOnly     = true,      -- hide full parties + incompatible game-mode listings
    miniMode         = false,     -- remember mini/full state across zones and reloads
    windowAlpha      = 1.0,
    bgImage          = 'bg.png',  -- filename inside images/ (empty string = disabled)
    bgAlpha          = 0.15,      -- background image opacity (0.0-1.0)
    keybind          = '^G',      -- Ashita bind string (^ = Ctrl, ! = Alt, @ = Win, # = Apps)
    soundVolume      = 100,       -- master sound effect volume (0-100, linear; converted to dB at play)
    soundMutes       = T{},       -- per-effect mute map: { register=true, ... }
    blacklist        = T{},
};

local pfSettings = ashitaSettings.load(default_settings);

local function update_settings(s)
    if (s ~= nil) then
        pfSettings = s;
    end
    ashitaSettings.save();
end

ashitaSettings.register('settings', 'pf_settings_update', update_settings);

------------------------------------------------------------
-- State
------------------------------------------------------------
local guiimages     = images.loadTextures();
local bgTexture     = nil;

-- DirectSound init (master volume + per-sound mute). Falls back to
-- ashita.misc.play_sound on any failure so audio feedback isn't lost.
do
    local ok, err = sounds.init(addon.path:append('\\sounds'), sounds.FILES);
    if (not ok) then
        pfprint('Audio init failed; falling back to PlaySound. ' .. tostring(err));
    elseif (err ~= nil) then
        pfprint('Audio init: ' .. err);
    end
end
local entries       = T{};
local partyMembers  = {}; -- keyed by charId, value = list of {name, job, level, subJob, subLevel}
local isRegistered    = false;
local selectedTab     = 0;
local selectedIndex   = 0;
local devMode         = false;
local devLog          = T{};
local DEV_LOG_MAX     = 50;
local autoRefreshInterval = 60;
local lastRefreshTime     = 0;
local hasShownLoginSummary = false;

-- Blacklist (from settings)
local blacklist = T(pfSettings.blacklist);

-- LFM notification toggle (from settings)
local lfmNotifications = pfSettings.lfmNotifications;

local tooltipsEnabled = pfSettings.tooltipsEnabled;
if (tooltipsEnabled == nil) then tooltipsEnabled = true; end

local confirmWithdraw = pfSettings.confirmWithdraw;
if (confirmWithdraw == nil) then confirmWithdraw = true; end


local windowAlpha = pfSettings.windowAlpha;
if (windowAlpha == nil) then windowAlpha = 1.0; end

local bgImage = pfSettings.bgImage or '';
local bgAlpha = pfSettings.bgAlpha;
if (bgAlpha == nil) then bgAlpha = 0.15; end

local keybind = pfSettings.keybind or '^G';

local function loadBgTexture()
    if (bgImage == '') then
        bgTexture = nil;
        pfprint('Background image disabled (filename is empty in settings).');
        return;
    end
    local tex, err, path, exists = images.loadFromFile(bgImage);
    bgTexture = tex;
    if (tex == nil) then
        pfprint(string.format('Background image FAILED to load: %s', bgImage));
        pfprint(string.format('  path:   %s', tostring(path)));
        pfprint(string.format('  exists: %s', tostring(exists)));
        pfprint(string.format('  error:  %s', tostring(err)));
        pfprint('Please report this error in Discord (#bug-reports).');
    end
end
loadBgTexture();

local function centerNextWindow()
    local res, vp = require('d3d8').get_device():GetViewport();
    if (res == 0 and vp ~= nil) then
        imgui.SetNextWindowPos({ vp.Width / 2, vp.Height / 2 }, ImGuiCond_Appearing, { 0.5, 0.5 });
    end
end

local function setTooltip(text)
    if (not tooltipsEnabled) then return; end
    imgui.BeginTooltip();
    imgui.TextUnformatted(text);
    imgui.EndTooltip();
end

-- Venture state cache populated by the 0x1A3 Venture Info packet.
-- Server broadcasts every ~90s and on zone-in. Used to show live venture
-- progress / star-bonus indicators in the Venture category LFM tooltip.
-- See modules/catseyexi/cpp/packets/venture_info.cpp for packet layout.
-- MUST be declared before renderVentureTooltipContent below — Lua resolves
-- bare-name references at lookup time to the most-recent local in scope at
-- declaration time, and a forward reference would otherwise resolve to the
-- (nil) global of the same name.
local ventureState = {
    lastReceived = 0,   -- os.time() of last received packet (0 = never)
    version      = 0,
    gameMode     = 0,   -- 0 = ACE/WEW, 1 = CW
    pools = {
        a = {},  -- [tier 1-6] = { aceZoneId, cwZoneId, progress, starBonus }
        b = {},
    },
    hvnm = {
        zoneId    = 0,
        progress  = 0,      -- 0-200
        maxProgress = 200,
        starBonus = false,
        spawned   = false,  -- progress >= maxProgress
    },
};

-- Parse the venture tier (1-6) from an entry's auto-generated comment like
-- "Lv30-39 - Jugner Forest". Returns nil if the comment doesn't match the
-- auto-comment format (leader may have typed a custom comment).
local function parseVentureTier(comment)
    if (not comment) then return nil; end
    local low = comment:match('Lv(%d+)');
    if (not low) then return nil; end
    local n = tonumber(low);
    if     n >= 60 then return 6;
    elseif n >= 50 then return 5;
    elseif n >= 40 then return 4;
    elseif n >= 30 then return 3;
    elseif n >= 20 then return 2;
    elseif n >= 10 then return 1;
    end
    return nil;
end

-- MUST be declared before renderVentureTooltipContent below - same forward-
-- reference quirk as ventureState above. The renderPoolRow closure inside
-- renderVentureTooltipContent calls getZoneName; if declared later in the
-- file, the closure would resolve the bare name to the (nil) global at call
-- time and crash on first hover of a Venture LFM entry.
local function getZoneName(zoneId)
    local zone = AshitaCore:GetResourceManager():GetString('zones.names', zoneId);
    if (zone == nil or zone == '') then
        return string.format('Zone %d', zoneId);
    end
    return zone;
end

-- Render compact venture state lines inside an open imgui.BeginTooltip().
-- If tier is nil, shows a summary across all 6 tiers. If tier is given,
-- shows only that tier's pool A + pool B rows. No-op if no venture
-- packet has been received yet this session.
local function renderVentureTooltipContent(tier)
    if (ventureState.lastReceived == 0) then return; end

    local function renderPoolRow(poolKey, tierIdx)
        local info = ventureState.pools[poolKey][tierIdx];
        if (not info or info.aceZoneId == 0) then return; end
        local zoneId = (ventureState.gameMode == 1) and info.cwZoneId or info.aceZoneId;
        if (zoneId == 0) then zoneId = info.aceZoneId; end
        local zoneName = getZoneName(zoneId);
        local progColor = info.progress >= 100 and { 0.3, 1.0, 0.3, 1.0 }
            or info.progress >= 50  and { 0.9, 0.9, 0.3, 1.0 }
            or { 0.75, 0.75, 0.75, 1.0 };
        local line = string.format('  T%d %s: %3d%%', tierIdx, zoneName, info.progress);
        if (info.starBonus) then line = line .. ' *'; end
        -- TextUnformatted because the line contains literal '%' and TextColored
        -- is printf-style - the '%' would re-trigger format interpretation.
        imgui.PushStyleColor(ImGuiCol_Text, progColor);
        imgui.TextUnformatted(line);
        imgui.PopStyleColor();
    end

    imgui.Spacing();
    imgui.Separator();
    imgui.TextColored({ 1.0, 0.75, 0.40, 1.0 }, 'Current Ventures');

    local tiers = tier and { tier } or { 1, 2, 3, 4, 5, 6 };
    imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, 'Pool A');
    for _, t in ipairs(tiers) do renderPoolRow('a', t); end
    imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, 'Pool B');
    for _, t in ipairs(tiers) do renderPoolRow('b', t); end
end

-- Helper: am I the party leader (or solo)?
-- Returns true if solo (party of 1) OR if my serverid matches the party leader's.
-- Defensively wrapped in pcall — if the Ashita API differs, defaults to true so
-- a detection failure doesn't lock the user out of registering.
local function isPartyLeaderOrSolo()
    local ok, result = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        local mySid = party:GetMemberServerId(0);
        -- Count OTHER valid members via the same triple-check as isInParty
        -- (sid/sid!=mine/name/mJob>0) — Ashita retains stale SID+name+etc.
        -- in slots for solo players after a past party disbands.
        local others = 0;
        for i = 1, 5 do
            local sid  = party:GetMemberServerId(i);
            local name = party:GetMemberName(i);
            local mJob = party:GetMemberMainJob(i);
            if (sid ~= nil and sid > 0 and sid ~= mySid
                and name ~= nil and name ~= ''
                and mJob ~= nil and mJob > 0) then
                others = others + 1;
            end
        end
        if (others == 0) then return true; end -- solo

        local leaderSid = party:GetAlliancePartyLeaderServerId(0);
        return mySid == leaderSid;
    end);
    if (not ok) then return true; end
    return result;
end

-- Settings window state
local settingsBuf = {
    isOpen       = false,
    tooltips     = { tooltipsEnabled },
    lfm          = { lfmNotifications },
    confirmWd    = { confirmWithdraw },
    joinable     = { pfSettings.joinableOnly ~= false },
    alpha        = { windowAlpha },
    bgAlpha      = { bgAlpha },
    bgImage      = { bgImage },
    bgImageSize  = 256,
    keybind      = { keybind },
    keybindSize  = 32,
    soundVolume  = { pfSettings.soundVolume or 100 },
    mutes        = {
        register      = { false },
        withdraw      = { false },
        join_request  = { false },
        join_accepted = { false },
        roulette_roll = { false },
    },
};
local isConfirmWithdrawOpen = false;


-- Activity log
local activityLog     = T{};
local ACTIVITY_LOG_MAX = 100;
-- Incoming join requests (for leaders without auto-accept)
local incomingRequests  = T{};
local REQUEST_TTL       = 60; -- seconds before a request expires

-- Mini mode (persisted in pfSettings so it survives zoning and reloads)
local miniMode = pfSettings.miniMode;
if (miniMode == nil) then miniMode = false; end

local slider = {
    anim  = 0,
    speed = 0.08,
    winX  = 0,
    winY  = 0,
    winW  = 0,
    winH  = 0,
};

-- Duty Roulette / Mission Help state
local roulette = {
    active      = false,   -- ready check flow is in progress
    source      = 'roulette', -- 'roulette' or 'mission'
    dutyName    = '',
    dutyId      = 0,
    dutyZone    = 0,
    dutyTier    = 0,
    dutyCap     = 0,
    partySize   = 0,
    readyCheck  = T{},     -- { name = ready_bool } for each party member
    readyCount  = 0,
    totalCount  = 0,
    timeout     = 0,       -- os.time() when ready check expires
};

-- Active duty state (persists from commence through BF completion)
local activeDuty = {
    name  = '',    -- duty name
    phase = 0,     -- 0=none, 1=teleporting to BF, 2=in BF
};

-- Mission selection state (when multiple eligible)
local missionSelect = {
    active  = false,
    entries = T{},
};

local ui = {
    isOpen = { true }, -- auto-open on addon load
    csHidden = false,          -- true while PF is hidden for a cutscene
    wasOpenBeforeCS = nil,     -- remembers ui.isOpen[1] so we can restore after the CS
    wasOpenBeforeZone = nil,   -- remembers ui.isOpen[1] across zone transitions
    expandedDuringDuty = false, -- set by the raid-frame expand button; suppresses the duty-start auto-switch-to-mini
};

-- Change miniMode and persist immediately. All explicit transitions (toggle
-- command, mini-icon click, X-close, raid-frame expand) and the duty-start
-- auto-switch route through here so settings stay in sync. Lives on the ui
-- table to avoid burning a file-scope upvalue slot (Lua 5.1 60 cap).
ui.setMiniMode = function(value)
    miniMode = value and true or false;
    pfSettings.miniMode = miniMode;
    ashitaSettings.save();
end

-- Play a PF sound effect honoring master volume + per-sound mute. Lives on
-- ui so the call sites don't each capture sounds as a file-scope upvalue.
ui.playSound = function(name)
    local mutes = pfSettings.soundMutes;
    if (mutes ~= nil and mutes[name]) then return; end
    sounds.play(name, pfSettings.soundVolume or 100);
end

-- True if the player is currently in a cutscene/event (entity status 4).
-- Wrapped in pcall so a missing-API build doesn't break the render loop —
-- on failure we assume "not in event" and proceed normally.
local function isInEvent()
    local ok, status = pcall(function()
        local party  = AshitaCore:GetMemoryManager():GetParty();
        local entity = AshitaCore:GetMemoryManager():GetEntity();
        local idx    = party:GetMemberTargetIndex(0);
        return entity:GetStatus(idx);
    end);
    return ok and status == 4;
end

local comment = {
    buffer = { '' },
    bufferSize = 64,
};

local tell = {
    buffer = { '[PartyFinder]: Would you like to join my party?' },
    bufferSize = 256,
};

local isTellWindowOpen      = false;
local isCommentWindowOpen   = false;
local isConfirmJoinOpen     = false;
local confirmJoinEntry      = nil;
local pendingJoinTarget     = nil; -- name of leader we sent a join request to
local pendingContextOpen    = false; -- flag to open context menu next frame

------------------------------------------------------------
-- Dev log helper
------------------------------------------------------------
local function devlog(fmt_str, ...)
    if (not devMode) then return; end
    local msg = string.format('[%s] ' .. fmt_str, os.date('%H:%M:%S'), ...);
    devLog:append(msg);
    while (#devLog > DEV_LOG_MAX) do
        devLog:remove(1);
    end
end

------------------------------------------------------------
-- Activity log (user-facing event feed)
------------------------------------------------------------
local function logActivity(fmt_str, ...)
    local msg = string.format(fmt_str, ...);
    local entry = {
        time = os.date('%H:%M'),
        text = msg,
    };
    activityLog:append(entry);
    while (#activityLog > ACTIVITY_LOG_MAX) do
        activityLog:remove(1);
    end
    -- Mark unread if not on the activity tab
    if (ui.activeTab ~= 3) then
            end
end

------------------------------------------------------------
-- Incoming request helpers
------------------------------------------------------------
local function addIncomingRequest(sender, job, level, role)
    -- Remove any existing request from this sender
    for i = #incomingRequests, 1, -1 do
        if (incomingRequests[i].name:lower() == sender:lower()) then
            table.remove(incomingRequests, i);
        end
    end
    incomingRequests:append({
        name     = sender,
        job      = job,
        level    = level,
        role     = role,
        jobName  = JOB_ABBR[job] or '???',
        roleName = ROLE_NAMES[role or 0] or 'Any',
        time     = os.time(),
    });
    end

local function pruneExpiredRequests()
    local now = os.time();
    for i = #incomingRequests, 1, -1 do
        if (now - incomingRequests[i].time > REQUEST_TTL) then
            table.remove(incomingRequests, i);
        end
    end
    if (#incomingRequests == 0) then
    end
end

------------------------------------------------------------
-- Packet helpers
------------------------------------------------------------
local function sendC2S(action, category, contentId, role, listingType, autoAccept, minLevel, commentStr)
    category    = category or 0;
    contentId   = contentId or 0;
    role        = role or 0;
    listingType = listingType or 1;
    autoAccept  = autoAccept or 0;
    minLevel    = minLevel or 0;
    commentStr  = commentStr or '';

    -- Build packet data as a raw byte table
    -- Layout:
    --   [0x00-0x03] header
    --   [0x04]      action
    --   [0x05]      category
    --   [0x06]      content_id (uint16 LE)
    --   [0x08]      role
    --   [0x09]      listing_type
    --   [0x0A]      auto_accept
    --   [0x0B]      min_level
    --   [0x0C]      comment (60 bytes)
    -- Total: 0x48 (72 bytes)

    local packet = {};
    packet[1] = 0xA2;
    packet[2] = 0x24;
    packet[3] = 0x00;
    packet[4] = 0x00;
    packet[5] = action;
    packet[6] = category;
    packet[7] = bit.band(contentId, 0xFF);
    packet[8] = bit.rshift(contentId, 8);
    packet[9]  = role;
    packet[10] = listingType;
    packet[11] = autoAccept;
    packet[12] = minLevel;
    -- Comment (60 bytes starting at index 13 = offset 0x0C)
    for i = 1, 60 do
        local c = commentStr:byte(i);
        packet[12 + i] = c or 0;
    end

    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, packet);

    devlog('C2S -> action=%d cat=%d role=%d type=%d auto=%d minlvl=%d', action, category, role, listingType, autoAccept, minLevel);
end

local function requestRefresh()
    pingPendingSince = os.time();
    pingRetryCount   = 0;
    sendC2S(C2S.REFRESH);
end

local function requestRegister(category, contentId, role, listingType, autoAccept, minLevel, commentStr)
    sendC2S(C2S.REGISTER, category, contentId, role, listingType, autoAccept, minLevel, commentStr);
end

local function requestWithdraw()
    sendC2S(C2S.WITHDRAW);
end

-- isReroll: true => Re-roll button (charges PFP, gates on cap), false/nil => fresh roll
local function requestRouletteRoll(isReroll)
    -- Reuse the `category` byte (0x05) as the isReroll flag for the ROULETTE_ROLL action.
    -- The cpp dispatcher reads it as isReroll only for this action.
    sendC2S(C2S.ROULETTE_ROLL, isReroll and 1 or 0);
end

local function requestRouletteGo()
    sendC2S(C2S.ROULETTE_GO);
end

local function requestMissionStart(contentId)
    sendC2S(C2S.MISSION_START, 2, contentId or 0);
end

local function requestReady()
    sendC2S(C2S.READY);
end

------------------------------------------------------------
-- Raw C2S packet builder for join-request flow.
-- The standard sendC2S() is fixed-layout for the register path. The join
-- flow needs to write string fields at custom offsets, so it builds its own
-- 72-byte packet.
------------------------------------------------------------
local function writeStringAt(packet, offset, str, maxLen)
    -- packet indices are 1-based; offset 0x04 -> packet[5].
    for i = 1, maxLen do
        local c = str:byte(i);
        packet[offset + i] = c or 0;
    end
end

local function makeEmptyC2SPacket(action)
    local packet = {};
    -- 0x1A2 packet header (action-agnostic)
    packet[1] = 0xA2;
    packet[2] = 0x24; -- size = 0x48 (72 bytes)
    packet[3] = 0x00;
    packet[4] = 0x00;
    packet[5] = action;
    for i = 6, 72 do
        packet[i] = 0;
    end
    return packet;
end

-- Send a join request to a leader's LFM party. The server pulls the
-- requester's actual main job + level from their character; we only send the
-- role they want to fill.
local function sendJoinRequestPacket(leaderName, role)
    local packet = makeEmptyC2SPacket(C2S.JOIN_REQUEST);
    packet[6] = role or 0;            -- 0x05
    writeStringAt(packet, 8, leaderName, 16); -- 0x08..0x17: leader name
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, packet);
    devlog('C2S -> JOIN_REQUEST leader=%s role=%d', leaderName, role or 0);
end

-- Send a response (accept=1/deny=0) for a pending join request back to the
-- requester. `reason` is a code (0=generic, 1=level too low, 2=blacklisted,
-- 3=other), `message` is an optional deny message displayed to the requester.
local function sendJoinRespond(requesterName, accept, reason, message)
    local packet = makeEmptyC2SPacket(C2S.JOIN_RESPOND);
    packet[6] = accept and 1 or 0;                 -- 0x05
    packet[7] = reason or 0;                       -- 0x06
    writeStringAt(packet, 8, requesterName, 16);   -- 0x08..0x17: requester name
    writeStringAt(packet, 24, message or '', 48);  -- 0x18..0x47: message
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, packet);
    devlog('C2S -> JOIN_RESPOND requester=%s result=%s reason=%d',
        requesterName, accept and 'ACCEPT' or 'DENY', reason or 0);
end

-- Follower declines the currently-pending duty. Server looks up the leader.
local function sendDutyDecline()
    sendC2S(C2S.DUTY_DECLINE);
    devlog('C2S -> DUTY_DECLINE');
end

------------------------------------------------------------
-- Drawing helpers
------------------------------------------------------------
local function drawJobIcon(jobID, size)
    size = size or 32;
    if (not guiimages.jobs or jobID < 1 or jobID > 22) then return; end
    local total = 22;
    local ratio = 1 / total;
    local iconID = jobID - 1;
    imgui.Image(
        tonumber(ffi.cast("uint32_t", guiimages.jobs)),
        { size, size },
        { ratio * iconID, 0 },
        { ratio * iconID + ratio, 1 },
        { 1, 1, 1, 1 },
        { 0, 0, 0, 0 }
    );
end

local MODE_NAMES = { [0] = 'ACE', [1] = 'CW', [2] = 'WEW' };

local function drawModeIcon(modeID, size)
    size = size or 22;
    if (not guiimages.modes or modeID < 0 or modeID > 2) then return; end
    local total = 4; -- modes.png has 4 slots (from v1 addon)
    local ratio = 1 / total;
    imgui.Image(
        tonumber(ffi.cast("uint32_t", guiimages.modes)),
        { size, size },
        { ratio * modeID, 0 },
        { ratio * modeID + ratio, 1 },
        { 1, 1, 1, 1 },
        { 0, 0, 0, 0 }
    );
end

local function getCategoryColor(catId)
    for _, cat in ipairs(CATEGORIES) do
        if (cat.id == catId) then
            return cat.color;
        end
    end
    return { 0.8, 0.8, 0.8, 1.0 };
end

------------------------------------------------------------
-- Theme
------------------------------------------------------------
-- Theme styles stored as table pairs (same pattern as v1 addon that works)
local themeStyles = {
    { ImGuiCol_Text,                 { 0.90, 0.90, 0.90, 1.00 } },
    { ImGuiCol_TextDisabled,         { 0.50, 0.50, 0.50, 1.00 } },
    { ImGuiCol_WindowBg,             { 0.06, 0.06, 0.08, 0.96 } },
    { ImGuiCol_ChildBg,              { 0.08, 0.08, 0.10, 1.00 } },
    { ImGuiCol_PopupBg,              { 0.08, 0.08, 0.10, 0.96 } },
    { ImGuiCol_Border,               { 0.30, 0.30, 0.35, 0.50 } },
    { ImGuiCol_FrameBg,              { 0.12, 0.12, 0.15, 1.00 } },
    { ImGuiCol_FrameBgHovered,       { 0.18, 0.18, 0.22, 1.00 } },
    { ImGuiCol_FrameBgActive,        { 0.22, 0.22, 0.28, 1.00 } },
    { ImGuiCol_TitleBg,              { 0.05, 0.05, 0.07, 1.00 } },
    { ImGuiCol_TitleBgActive,        { 0.10, 0.10, 0.14, 1.00 } },
    { ImGuiCol_ScrollbarBg,          { 0.05, 0.05, 0.07, 0.80 } },
    { ImGuiCol_ScrollbarGrab,        { 0.30, 0.30, 0.35, 1.00 } },
    { ImGuiCol_ScrollbarGrabHovered, { 0.40, 0.40, 0.45, 1.00 } },
    { ImGuiCol_ScrollbarGrabActive,  { 0.50, 0.50, 0.55, 1.00 } },
    { ImGuiCol_Button,               { 0.18, 0.18, 0.22, 1.00 } },
    { ImGuiCol_ButtonHovered,        { 0.28, 0.28, 0.35, 1.00 } },
    { ImGuiCol_ButtonActive,         { 0.35, 0.35, 0.42, 1.00 } },
    { ImGuiCol_Header,               { 0.18, 0.18, 0.24, 1.00 } },
    { ImGuiCol_HeaderHovered,        { 0.26, 0.26, 0.34, 1.00 } },
    { ImGuiCol_HeaderActive,         { 0.32, 0.32, 0.40, 1.00 } },
};

local function pushTheme()
    for _, s in pairs(themeStyles) do
        imgui.PushStyleColor(s[1], s[2]);
    end
end

local function popTheme()
    for _ in pairs(themeStyles) do
        imgui.PopStyleColor();
    end
end

------------------------------------------------------------
-- Helpers: Player info and join requests
------------------------------------------------------------
local function getMyInfo()
    local jobID    = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
    local jobLevel = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
    local jobName  = JOB_ABBR[jobID] or '???';
    return jobID, jobLevel, jobName;
end

-- Check game mode compatibility: CW (1) can only play with CW. ACE (0) and WEW (2) can play together.
local function isGameModeCompatible(myMode, theirMode)
    if (myMode == nil or theirMode == nil) then return true; end -- unknown, allow
    if (myMode == 1 or theirMode == 1) then
        return myMode == theirMode; -- CW only with CW
    end
    return true; -- ACE + WEW compatible
end

ui.isHiddenByFilter = function(entry)
    if (pfSettings.joinableOnly == false) then return false; end
    local entryType = entry.listingType or 1;
    local isFull = entryType == 2
        and entry.partySize ~= nil
        and entry.partySize >= (entry.maxPlayers or 6);
    local isIncompatibleMode = ui.myGameMode ~= nil
        and entry.gameMode ~= nil
        and not isGameModeCompatible(ui.myGameMode, entry.gameMode);
    return isFull or isIncompatibleMode;
end

local function sendJoinRequest(entry)
    local jobID, jobLevel, jobName = getMyInfo();
    local roleName = ROLE_NAMES[ui.selectedRole or 0] or 'Any';
    sendJoinRequestPacket(entry.name, ui.selectedRole or 0);
    -- Track that we have a pending join request so we can auto-accept the invite
    pendingJoinTarget = entry.name:lower();
    pfprint(string.format('Join request sent to %s (%s%d, %s)', entry.name, jobName, jobLevel, roleName));
    devlog('Join request -> %s (pending auto-accept)', entry.name);
end

------------------------------------------------------------
-- Render: Entry card
------------------------------------------------------------
local function renderEntryCard(i, entry)
    local jobName  = JOB_ABBR[entry.job] or '???';
    local zoneName = getZoneName(entry.zoneId);
    local catColor = getCategoryColor(entry.category);
    local catName  = CATEGORY_NAMES[entry.category] or '???';
    local isSelected = (selectedIndex == i);

    -- Card background (semi-transparent so the listings background image shows through)
    local cardHeight = 62;
    local cardBgAlpha = (bgTexture ~= nil) and 0.65 or 1.0;
    imgui.PushStyleColor(ImGuiCol_ChildBg, { 0.08, 0.08, 0.10, cardBgAlpha });
    imgui.BeginChild(string.format('##card_%d', i), { -1, cardHeight }, ImGuiChildFlags_Borders);

    -- Color accent bar on the left edge (category color)
    local drawList = imgui.GetWindowDrawList();
    local winX, winY = imgui.GetWindowPos();
    drawList:AddRectFilled(
        { winX, winY },
        { winX + 3, winY + cardHeight },
        imgui.GetColorU32(catColor)
    );

    -- Selectable overlay for click handling
    if (imgui.Selectable(string.format('##sel_%d', i), isSelected, ImGuiSelectableFlags_SpanAllColumns, { 0, cardHeight - 8 })) then
        selectedIndex = i;
    end

    -- Skip interactions with own listing
    local myName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    local isSelf = (entry.name == myName);

    -- Gate the LFG (invite) path: only a solo player or party leader can
    -- invite. The LFM (join) path is NOT gated client-side — Ashita's party
    -- memory is unreliable right after a RemoveMember during a zone change
    -- (the GP_SERV_GROUP_TBL clear packet can be dropped in session transit)
    -- which would falsely block the user from rejoining. The server-side
    -- defense-in-depth check in handleJoinRequest reads accounts_parties
    -- authoritatively and rejects true in-party requesters there.
    local isLfm = ((entry.listingType or 1) == 2);
    local actionAllowed    = true;
    local actionBlockedMsg = nil;
    if (not isLfm) then
        if (not isPartyLeaderOrSolo()) then
            actionAllowed    = false;
            actionBlockedMsg = 'Only the party leader can invite';
        end
    end
    local actionHint = actionAllowed
        and (isLfm and 'Double-click to join' or 'Double-click to invite')
        or actionBlockedMsg;

    -- Hover tooltip with party composition for LFM entries, plus live
    -- venture state for Venture-category entries.
    if (imgui.IsItemHovered() and not imgui.IsMouseDown(1)) then
        if (isSelf) then
            setTooltip('This is your listing');
        else
            local members     = partyMembers[entry.charId];
            local isVenture   = (entry.category == 5);
            local ventureTier = isVenture and parseVentureTier(entry.comment) or nil;

            imgui.BeginTooltip();

            if (isLfm and members and #members > 0) then
                imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 }, string.format('%s\'s Party (%d/6)', entry.name, #members));
                imgui.Separator();
                for _, m in ipairs(members) do
                    local jobStr = string.format('%s%d', JOB_ABBR[m.job] or '???', m.level);
                    if (m.subJob and m.subJob > 0) then
                        jobStr = jobStr .. string.format('/%s%d', JOB_ABBR[m.subJob] or '???', m.subLevel or 0);
                    end
                    local isLeader = (m.name == entry.name);
                    local nameColor = isLeader and { 1.0, 0.85, 0.4, 1.0 } or { 0.9, 0.9, 0.9, 1.0 };
                    imgui.TextColored(nameColor, m.name);
                    imgui.SameLine(120);
                    imgui.TextColored({ 0.6, 0.8, 0.6, 1.0 }, jobStr);
                end
            end

            if (isVenture) then
                renderVentureTooltipContent(ventureTier);
            end

            imgui.Spacing();
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, actionHint .. '  |  Right-click for options');
            imgui.EndTooltip();
        end
    end

    -- Double-click: open confirmation dialog (not for self, check game mode, action must be allowed)
    if (not isSelf and actionAllowed and imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0)) then
        if (not isGameModeCompatible(ui.myGameMode, entry.gameMode)) then
            pfprint('Cannot join: incompatible game mode.');
        else
            selectedIndex = i;
            confirmJoinEntry = entry;
            isConfirmJoinOpen = true;
        end
    end

    -- Right-click context menu (rendered inline, attached to the selectable)
    if (imgui.BeginPopupContextItem(string.format('##ctx_%d', i))) then
        selectedIndex = i;

        local entryJobName = JOB_ABBR[entry.job] or '???';
        imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 }, entry.name);
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('%s%d - %s', entryJobName, entry.level, getZoneName(entry.zoneId)));
        imgui.Separator();

        local modeCompat = isGameModeCompatible(ui.myGameMode, entry.gameMode);
        if (isSelf) then
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '(This is you)');
        elseif (not modeCompat) then
            imgui.TextColored({ 0.8, 0.3, 0.3, 1.0 }, '(Incompatible game mode)');
        elseif (not actionAllowed) then
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '(' .. actionBlockedMsg .. ')');
        elseif (isLfm) then
            if ((entry.autoAccept or 0) == 1) then
                if (imgui.MenuItem('Join Party')) then
                    sendJoinRequest(entry);
                end
            else
                if (imgui.MenuItem('Request to Join')) then
                    sendJoinRequest(entry);
                end
            end
        else
            if (imgui.MenuItem('Invite to Party')) then
                AshitaCore:GetChatManager():QueueCommand(1, string.format('/pcmd add %s', entry.name));
                logActivity('Invited %s (%s%d)', entry.name, entryJobName, entry.level);
            end
        end

        imgui.Separator();
        if (imgui.MenuItem('Send Tell')) then
            isTellWindowOpen = true;
        end
        if (imgui.MenuItem('Search')) then
            AshitaCore:GetChatManager():QueueCommand(1, string.format('/sea all %s', entry.name));
        end

        imgui.Separator();
        local isBlocked = blacklist[entry.name:lower()] or false;
        if (isBlocked) then
            if (imgui.MenuItem('Unblock Player')) then
                blacklist[entry.name:lower()] = nil;
                pfSettings.blacklist = blacklist;
                ashitaSettings.save();
                logActivity('Unblocked %s', entry.name);
                pfprint(string.format('Unblocked %s', entry.name));
            end
        else
            if (imgui.MenuItem('Block Player')) then
                blacklist[entry.name:lower()] = true;
                pfSettings.blacklist = blacklist;
                ashitaSettings.save();
                logActivity('Blocked %s', entry.name);
                pfprint(string.format('Blocked %s from join requests', entry.name));
            end
        end

        imgui.EndPopup();
    end

    -- Draw content on top of selectable (offset for accent bar)
    imgui.SetCursorPos({ 10, 4 });

    -- Game mode icon + compatibility check
    local modeCompat = isGameModeCompatible(ui.myGameMode, entry.gameMode);
    drawModeIcon(entry.gameMode or 0, 20);
    imgui.SameLine(0, 4);

    -- Job icon (dimmed if incompatible)
    if (not modeCompat) then
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.4);
    end
    drawJobIcon(entry.job, 32);
    imgui.SameLine();

    -- Name and job/level
    imgui.BeginGroup();
        imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 }, entry.name);
        imgui.SameLine();
        local subStr = '';
        if (entry.subJob and entry.subJob > 0) then
            local subName = JOB_ABBR[entry.subJob] or '???';
            subStr = string.format('/%s%d', subName, entry.subLevel or 0);
        end
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format(' %s%d%s', jobName, entry.level, subStr));
        -- Zone, category, and role
        imgui.TextColored({ 0.55, 0.55, 0.55, 1.0 }, zoneName);
        imgui.SameLine(0, 12);
        -- HVNM urgency cue: suffix the Venture category chip when HVNM is
        -- near spawn (progress >= 150/200) or spawned (>= 200). Tells LFM
        -- viewers at a glance that an HVNM window is open — partyfinder-
        -- specific context that the ventures addon (which tracks numbers)
        -- doesn't provide.
        local chipText = string.format('[%s]', catName);
        local chipColor = catColor;
        if (entry.category == 5 and ventureState.lastReceived > 0) then
            if (ventureState.hvnm.spawned) then
                chipText  = string.format('[%s  HVNM!]', catName);
                chipColor = { 0.3, 1.0, 0.3, 1.0 };
            elseif (ventureState.hvnm.progress >= 150) then
                chipText  = string.format('[%s *]', catName);
                chipColor = { 1.0, 0.6, 0.3, 1.0 };
            end
        end
        imgui.TextColored(chipColor, chipText);
        -- Show role text for LFG only (LFM shows role icons instead)
        if ((entry.listingType or 1) == 1) then
            local roleName = ROLE_NAMES[entry.role or 0];
            if (roleName and roleName ~= 'Any') then
                local roleColor = { 0.6, 0.6, 0.6, 1.0 };
                for _, r in ipairs(ROLES) do
                    if (r.id == entry.role) then roleColor = r.color; break; end
                end
                imgui.SameLine(0, 8);
                imgui.TextColored(roleColor, roleName);
            end
        end
        -- Show party size + role composition for LFM entries
        if ((entry.listingType or 1) == 2) then
            local size = entry.partySize or 1;
            if (size < 1) then size = 1; end
            imgui.SameLine(0, 8);
            local sizeColor = size < 6 and { 0.7, 0.9, 0.5, 1.0 } or { 0.5, 0.5, 0.5, 1.0 };
            imgui.TextColored(sizeColor, string.format('%d/6', size));

            -- Role composition icons (Tank, Healer, Support, DPS)
            local rolesTex = tonumber(ffi.cast("uint32_t", guiimages.roles));
            if (rolesTex) then
                local roleLabels = { 'Tank', 'Healer', 'Support', 'DPS' };
                local roleCounts = {
                    entry.tankCount or 0,
                    entry.healerCount or 0,
                    entry.supportCount or 0,
                    entry.dpsCount or 0,
                };
                for ri = 1, 4 do
                    if (roleCounts[ri] > 0) then
                        imgui.SameLine(0, 4);
                        local u0 = (ri - 1) / 4;
                        local u1 = ri / 4;
                        imgui.Image(rolesTex, { 14, 14 }, { u0, 0 }, { u1, 1 });
                        if (imgui.IsItemHovered()) then
                            setTooltip(string.format('%s: %d', roleLabels[ri], roleCounts[ri]));
                        end
                        imgui.SameLine(0, 1);
                        imgui.TextColored({ 0.8, 0.8, 0.8, 1.0 }, tostring(roleCounts[ri]));
                    end
                end
            end

            -- Auto-accept badge
            if ((entry.autoAccept or 0) == 1) then
                imgui.SameLine(0, 8);
                imgui.TextColored({ 0.3, 1.0, 0.3, 1.0 }, 'Join');
            end
        end
    imgui.EndGroup();

    -- Comment on the right side. Use TextUnformatted (via PushStyleColor)
    -- because TextColored is printf-style and would re-interpret '%'
    -- characters in the comment (auto-comment includes '%' for venture
    -- progress; users may also type '%' in custom comments).
    if (entry.comment ~= nil and entry.comment ~= '') then
        local commentMaxWidth = 220;
        local windowWidth = imgui.GetWindowWidth();
        imgui.SetCursorPos({ windowWidth - commentMaxWidth - 10, 6 });
        imgui.PushTextWrapPos(windowWidth - 10);
        imgui.PushStyleColor(ImGuiCol_Text, { 0.65, 0.75, 0.85, 1.0 });
        imgui.TextUnformatted(string.format('"%s"', entry.comment));
        imgui.PopStyleColor();
        imgui.PopTextWrapPos();
    end

    if (not modeCompat) then
        imgui.PopStyleVar();
    end

    imgui.EndChild();
    imgui.PopStyleColor(); -- cardBgAlpha
end

------------------------------------------------------------
-- Render: Role icon button (FFXIV-style)
------------------------------------------------------------
local function drawRoleButton(role, isSelected, btnSize)
    btnSize = btnSize or 64;
    local iconSize = btnSize - 16;

    -- Highlight selected role with colored border
    local bgColor  = isSelected and { role.color[1] * 0.3, role.color[2] * 0.3, role.color[3] * 0.3, 1.0 } or { 0.0, 0.0, 0.0, 0.0 };
    local tintColor = isSelected and { 1.0, 1.0, 1.0, 1.0 } or { 0.7, 0.7, 0.7, 0.8 };

    -- Draw the job icon as a button
    local jobIcon = role.jobIcon;
    local total = 22;
    local ratio = 1 / total;
    local iconID = jobIcon - 1;
    local texId = tonumber(ffi.cast("uint32_t", guiimages.jobs));

    imgui.PushID(string.format('role_%d', role.id));
    local clicked = imgui.ImageButton(
        texId,
        { iconSize, iconSize },
        { ratio * iconID, 0 },
        { ratio * iconID + ratio, 1 },
        -1,
        bgColor,
        tintColor
    );
    imgui.PopID();

    -- Draw selection indicator under the button
    if (isSelected) then
        local drawList = imgui.GetWindowDrawList();
        local posX, posY = imgui.GetItemRectMin();
        local maxX, maxY = imgui.GetItemRectMax();
        drawList:AddRectFilled(
            { posX, maxY + 1 },
            { maxX, maxY + 3 },
            imgui.GetColorU32(role.color)
        );
    end

    -- Role name centered under icon
    local textW = imgui.CalcTextSize(role.name);
    local iconW = iconSize;
    local offsetX = (iconW - textW) * 0.5;
    imgui.SetCursorPosX(imgui.GetCursorPosX() + offsetX);
    if (isSelected) then
        imgui.TextColored(role.color, role.name);
    else
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, role.name);
    end

    return clicked;
end

------------------------------------------------------------
-- Render: Register popup with role selection
------------------------------------------------------------
local function renderCommentWindow()
    if (not isCommentWindowOpen) then return; end

    if (not ui.selectedRole) then ui.selectedRole = 0; end
    if (not ui.selectedCat) then ui.selectedCat = 1; end
    if (not ui.selectedListingType) then ui.selectedListingType = 1; end

    imgui.SetNextWindowSize({ 460, 430 });
    centerNextWindow();
    local open = { true };
    if (imgui.Begin('Register - Party Finder', open, ImGuiWindowFlags_NoResize)) then

        -- Section: Listing type toggle (LFG / LFM)
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'I am...');
        imgui.Spacing();
        local lfgColor = ui.selectedListingType == 1 and { 0.4, 0.8, 1.0, 1.0 } or { 0.5, 0.5, 0.5, 1.0 };
        local lfmColor = ui.selectedListingType == 2 and { 1.0, 0.7, 0.3, 1.0 } or { 0.5, 0.5, 0.5, 1.0 };

        imgui.PushStyleColor(ImGuiCol_Text, lfgColor);
        if (imgui.Button('Looking for a Group', { 185, 28 })) then
            ui.selectedListingType = 1;
        end
        imgui.PopStyleColor();

        imgui.SameLine(0, 12);

        imgui.PushStyleColor(ImGuiCol_Text, lfmColor);
        if (imgui.Button('Recruiting Members', { 185, 28 })) then
            ui.selectedListingType = 2;
        end
        imgui.PopStyleColor();

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Section: Role selection
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Select Your Role');
        imgui.Separator();
        imgui.Spacing();

        -- Role buttons in a horizontal row
        local btnSize = 64;
        local spacing = 16;
        local totalWidth = #ROLES * btnSize + (#ROLES - 1) * spacing;
        local windowWidth = imgui.GetWindowWidth();
        local startX = (windowWidth - totalWidth) * 0.5;

        for i, role in ipairs(ROLES) do
            if (i > 1) then
                imgui.SameLine(0, spacing);
            else
                imgui.SetCursorPosX(startX);
            end

            imgui.BeginGroup();
            if (drawRoleButton(role, ui.selectedRole == role.id, btnSize)) then
                ui.selectedRole = role.id;
            end
            imgui.EndGroup();
        end

        imgui.Spacing();
        imgui.Spacing();

        -- Section: Category
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Category');
        imgui.SameLine();
        local currentCatName = CATEGORIES[ui.selectedCat + 1] and CATEGORIES[ui.selectedCat + 1].name or 'EXP';
        imgui.PushItemWidth(200);
        if (imgui.BeginCombo('##cat', currentCatName, ImGuiComboFlags_None)) then
            for i = 2, #CATEGORIES do
                local isSelected = (ui.selectedCat == (i - 1));
                if (imgui.Selectable(CATEGORIES[i].name, isSelected)) then
                    ui.selectedCat = i - 1;
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();

        -- Section: Auto-Accept (only for LFM)
        if (ui.selectedListingType == 2) then
            if (not ui.autoAccept) then ui.autoAccept = { false }; end
            if (not ui.minLevel) then ui.minLevel = { 1 }; end

            imgui.Spacing();
            imgui.Checkbox('Auto-Accept Join Requests', ui.autoAccept);
            if (ui.autoAccept[1]) then
                imgui.Spacing();
                imgui.Text('Minimum Level:');
                imgui.SameLine();
                imgui.PushItemWidth(80);
                imgui.InputInt('##minlvl', ui.minLevel, 1);
                imgui.PopItemWidth();
                ui.minLevel[1] = math.max(1, math.min(75, ui.minLevel[1]));
            end
        end

        -- Section: Comment
        local selectedCatId = CATEGORIES[ui.selectedCat + 1] and CATEGORIES[ui.selectedCat + 1].id or 0;
        local isVenture = (selectedCatId == 5);

        if (isVenture) then
            -- Show auto-detected venture tier preview
            local previewText = '';
            local myLevel = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
            if     (myLevel < 20) then previewText = 'Lv10-19';
            elseif (myLevel < 30) then previewText = 'Lv20-29';
            elseif (myLevel < 40) then previewText = 'Lv30-39';
            elseif (myLevel < 50) then previewText = 'Lv40-49';
            elseif (myLevel < 60) then previewText = 'Lv50-59';
            else                       previewText = 'Lv60-69';
            end
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Venture: ' .. previewText .. ' + zone (auto-detected)');
            imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Party Note');
            imgui.PushItemWidth(-1);
            imgui.InputText('##comment', comment.buffer, comment.bufferSize);
            imgui.PopItemWidth();
        else
            imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Comment');
            imgui.PushItemWidth(-1);
            imgui.InputText('##comment', comment.buffer, comment.bufferSize);
            imgui.PopItemWidth();
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Buttons centered
        local btnW = 110;
        local btnGap = 12;
        local btnsWidth = btnW * 2 + btnGap;
        imgui.SetCursorPosX((windowWidth - btnsWidth) * 0.5);

        if (imgui.Button('Register', { btnW, 30 })) then
            local catId = CATEGORIES[ui.selectedCat + 1].id;
            local aa = (ui.selectedListingType == 2 and ui.autoAccept and ui.autoAccept[1]) and 1 or 0;
            local ml = (aa == 1 and ui.minLevel) and ui.minLevel[1] or 0;

            -- Save registration state NOW before the window closes
            ui.registeredListingType = ui.selectedListingType or 1;
            ui.registeredCategory    = catId;
            ui.registeredAutoAccept  = (aa == 1);
            ui.registeredMinLevel    = ml;
            devlog('Register clicked: type=%d auto=%s minlvl=%d', ui.registeredListingType, ui.registeredAutoAccept and 'ON' or 'OFF', ml);

            requestRegister(catId, 0, ui.selectedRole or 0, ui.selectedListingType or 1, aa, ml, comment.buffer[1] or '');
            ui.playSound('register');
            isCommentWindowOpen = false;
        end
        imgui.SameLine(0, btnGap);
        if (imgui.Button('Cancel', { btnW, 30 })) then
            isCommentWindowOpen = false;
        end
    end
    imgui.End();

    -- X button on the title bar — sync the local open ref back to state
    if (not open[1]) then
        isCommentWindowOpen = false;
    end
end

------------------------------------------------------------
-- Render: Tell window
------------------------------------------------------------
local function renderTellWindow()
    if (not isTellWindowOpen) then return; end
    if (selectedIndex < 1 or selectedIndex > #entries) then
        isTellWindowOpen = false;
        return;
    end

    imgui.SetNextWindowSize({ 400, 120 });
    centerNextWindow();
    local open = { true };
    if (imgui.Begin('Send Tell', open, ImGuiWindowFlags_NoResize)) then
        local entry = entries[selectedIndex];
        imgui.Text(string.format('To: %s', entry.name));
        imgui.PushItemWidth(-1);
        imgui.InputText('##tellmsg', tell.buffer, tell.bufferSize);
        imgui.PopItemWidth();

        if (imgui.Button('Send', { 80, 28 })) then
            local msg = tell.buffer[1] or '';
            AshitaCore:GetChatManager():QueueCommand(1, string.format('/tell %s %s', entry.name, msg));
            ui.playSound('join_request');
            isTellWindowOpen = false;
        end
        imgui.SameLine();
        if (imgui.Button('Cancel', { 80, 28 })) then
            isTellWindowOpen = false;
        end
    end
    imgui.End();

    if (not open[1]) then
        isTellWindowOpen = false;
    end
end

------------------------------------------------------------
-- Render: Dev panel
------------------------------------------------------------
local function renderDevPanel()
    if (not devMode) then return; end

    imgui.Separator();
    imgui.TextColored({ 1.0, 0.8, 0.2, 1.0 }, 'Developer Mode');
    imgui.SameLine();
    imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, string.format('(%d entries loaded)', #entries));

    imgui.BeginChild('##devlog', { -1, 120 }, ImGuiChildFlags_Borders);
    for _, msg in ipairs(devLog) do
        imgui.TextColored({ 0.6, 0.8, 0.6, 1.0 }, msg);
    end
    -- Auto-scroll to bottom
    if (imgui.GetScrollY() >= imgui.GetScrollMaxY() - 10) then
        imgui.SetScrollHereY(1.0);
    end
    imgui.EndChild();

    if (imgui.SmallButton('Clear Log')) then
        devLog = T{};
    end
    imgui.SameLine();
    if (imgui.SmallButton('Copy Log')) then
        imgui.SetClipboardText(table.concat(devLog, '\n'));
    end
    imgui.SameLine();
    if (imgui.SmallButton('Dump Entries')) then
        for i, e in ipairs(entries) do
            devlog('  [%d] %s %s%d zone=%d cat=%d comment="%s"',
                i, e.name, JOB_ABBR[e.job] or '?', e.level, e.zoneId, e.category, e.comment or '');
        end
    end
end


------------------------------------------------------------
-- Render: Notification slider (floats beside main/mini window)
-- Shows incoming join requests with accept/deny, animated in/out.
------------------------------------------------------------
local function renderNotificationSlider()
    pruneExpiredRequests();

    -- Animate: slide in when requests exist, slide out when empty
    local target = (#incomingRequests > 0) and 1 or 0;
    slider.anim = slider.anim + (target - slider.anim) * slider.speed;
    -- Snap when close enough to avoid lingering renders
    if (target == 0 and slider.anim < 0.01) then slider.anim = 0; end
    if (target == 1 and slider.anim > 0.99) then slider.anim = 1; end
    if (slider.anim <= 0) then return; end

    local panelW   = 280;
    local rowH     = 26;
    local headerH  = 24;
    local padY     = 8;
    local panelH   = headerH + (#incomingRequests * rowH) + padY;

    -- Anchor to the right edge of the PF window (main or mini), slide in from off-screen right
    local anchorX = slider.winX + slider.winW + 4;
    local anchorY = slider.winY;
    -- Offset: starts shifted right by panelW, lerps to 0
    local offsetX = (1 - slider.anim) * (panelW + 8);

    imgui.SetNextWindowPos({ anchorX + offsetX, anchorY }, ImGuiCond_Always);
    imgui.SetNextWindowSize({ panelW, panelH });
    imgui.SetNextWindowBgAlpha(0.92 * slider.anim);

    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    );

    if (imgui.Begin('##pf_notif_slider', { true }, flags)) then
        -- Header
        imgui.TextColored({ 1.0, 0.8, 0.3, 1.0 }, string.format('Join Requests (%d)', #incomingRequests));
        imgui.Separator();

        for i = #incomingRequests, 1, -1 do
            local req = incomingRequests[i];
            local elapsed   = os.time() - req.time;
            local remaining = REQUEST_TTL - elapsed;

            imgui.PushID(string.format('slider_req_%d', i));

            -- Accept
            imgui.PushStyleColor(ImGuiCol_Button, { 0.2, 0.55, 0.2, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.3, 0.7, 0.3, 1.0 });
            if (imgui.SmallButton('Y')) then
                sendJoinRespond(req.name, true, 0, '');
                logActivity('Accepted %s (%s%d, %s)', req.name, req.jobName, req.level, req.roleName);
                pfprint(string.format('Accepted %s', req.name));
                table.remove(incomingRequests, i);
            end
            imgui.PopStyleColor(2);

            imgui.SameLine();

            -- Deny
            imgui.PushStyleColor(ImGuiCol_Button, { 0.55, 0.2, 0.2, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.7, 0.3, 0.3, 1.0 });
            if (imgui.SmallButton('N')) then
                sendJoinRespond(req.name, false, 0, 'Request denied');
                logActivity('Denied %s (%s%d)', req.name, req.jobName, req.level);
                pfprint(string.format('Denied %s', req.name));
                table.remove(incomingRequests, i);
            end
            imgui.PopStyleColor(2);

            imgui.SameLine();
            imgui.TextColored({ 0.95, 0.95, 0.95, 1.0 }, req.name);
            imgui.SameLine();
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('%s%d', req.jobName, req.level));
            imgui.SameLine();
            local timerColor = (remaining <= 10) and { 1.0, 0.4, 0.4, 1.0 } or { 0.4, 0.4, 0.4, 1.0 };
            imgui.TextColored(timerColor, string.format('%ds', remaining));

            imgui.PopID();
        end
    end
    imgui.End();
end

------------------------------------------------------------
-- Render: Activity log tab
------------------------------------------------------------
local function renderActivityTab()
    imgui.BeginChild('##actlog', { -1, -26 }, ImGuiChildFlags_None);

    if (#activityLog == 0) then
        imgui.Spacing();
        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '  No activity yet.');
    else
        for _, entry in ipairs(activityLog) do
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, entry.time);
            imgui.SameLine();
            imgui.TextColored({ 0.85, 0.85, 0.85, 1.0 }, entry.text);
        end
        -- Auto-scroll
        if (imgui.GetScrollY() >= imgui.GetScrollMaxY() - 10) then
            imgui.SetScrollHereY(1.0);
        end
    end

    imgui.EndChild();
end

------------------------------------------------------------
-- Render: Mini mode (collapsed badge or compact duty frame)
------------------------------------------------------------
local function renderMiniMode()
    if (not miniMode) then return false; end

    -- During active duty: show compact party frame instead of icon
    if (activeDuty.phase > 0) then
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.05, 0.05, 0.07, 0.94 });
        imgui.PushStyleColor(ImGuiCol_Border, { 0.25, 0.45, 0.25, 0.5 });
        imgui.PushStyleColor(ImGuiCol_TitleBg, { 0.08, 0.12, 0.08, 1.0 });
        imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0.10, 0.18, 0.10, 1.0 });
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 6 });
        imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 4, 2 });

        imgui.SetNextWindowSize({ 310, 0 }, ImGuiCond_Always);
        local flags = bit.bor(
            ImGuiWindowFlags_NoResize,
            ImGuiWindowFlags_NoScrollbar,
            ImGuiWindowFlags_AlwaysAutoResize
        );
        if (imgui.Begin('Active Duty##pf_duty_mini', ui.isOpen, flags)) then
            -- Duty header
            local phaseColor = (activeDuty.phase == 1) and { 1.0, 0.8, 0.3, 1.0 } or { 0.3, 1.0, 0.6, 1.0 };
            local phaseIcon  = (activeDuty.phase == 1) and '>>' or '>>';
            imgui.TextColored(phaseColor, phaseIcon);
            imgui.SameLine(0, 4);
            imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 }, activeDuty.name);

            -- Right-aligned "open Party Finder" button — lets the user get
            -- back to the main window mid-duty (e.g. to withdraw an LFM,
            -- invite a replacement, or check other listings) without losing
            -- the raid frame. Sets ui.expandedDuringDuty so the duty-start
            -- auto-switch below doesn't immediately force us back to mini.
            local btnSize = 16;
            imgui.SameLine(imgui.GetWindowContentRegionWidth() - btnSize);
            local texId = tonumber(ffi.cast("uint32_t", guiimages.LFG));
            if (texId) then
                imgui.PushID('pf_duty_expand');
                if (imgui.ImageButton(texId, { btnSize, btnSize }, { 0, 0 }, { 1, 1 }, -1, { 0, 0, 0, 0 }, { 0.9, 0.9, 0.9, 1.0 })) then
                    ui.setMiniMode(false);
                    ui.expandedDuringDuty = true;
                end
                imgui.PopID();
                if (imgui.IsItemHovered() and tooltipsEnabled) then
                    setTooltip('Open Party Finder');
                end
            end

            imgui.Spacing();

            -- Party members
            local party = AshitaCore:GetMemoryManager():GetParty();

            -- My zone — used to filter out-of-zone members. pcall-wrapped in
            -- case this Ashita build doesn't expose GetMemberZone; on failure
            -- myZone stays 0 and all members pass the zone check (pre-fix
            -- behavior).
            local myZone = 0;
            pcall(function() myZone = party:GetMemberZone(0); end);

            for i = 0, 5 do
                local name = party:GetMemberName(i);
                if (name ~= nil and name ~= '') then
                    local mJob = party:GetMemberMainJob(i);

                    -- Skip members who aren't in our zone. Their client-side
                    -- HP/job data is stale/zero, and drawJobIcon no-ops on
                    -- mJob==0 without advancing the cursor — the subsequent
                    -- SameLine then stacks their row on top of the previous
                    -- member's row ("strange character buried behind another
                    -- row"). mJob>0 is a belt-and-suspenders guard for the
                    -- case GetMemberZone isn't available.
                    local memberZone = myZone;
                    pcall(function() memberZone = party:GetMemberZone(i); end);
                    if (memberZone == myZone and mJob > 0) then
                        local mLvl = party:GetMemberMainJobLevel(i);
                        local sJob = party:GetMemberSubJob(i);
                        local sLvl = party:GetMemberSubJobLevel(i);
                        local hpp  = party:GetMemberHPPercent(i);

                        local jobStr = string.format('%s%d', JOB_ABBR[mJob] or '?', mLvl);
                        if (sJob > 0) then
                            jobStr = jobStr .. string.format('/%s%d', JOB_ABBR[sJob] or '?', sLvl);
                        end

                        local barColor = (hpp > 50) and { 0.15, 0.55, 0.15, 1.0 }
                            or (hpp > 25) and { 0.65, 0.55, 0.08, 1.0 }
                            or { 0.65, 0.15, 0.15, 1.0 };
                        local barBg = { 0.12, 0.12, 0.15, 1.0 };

                        drawJobIcon(mJob, 16);
                        imgui.SameLine(0, 4);
                        imgui.TextColored({ 0.85, 0.85, 0.85, 1.0 }, name);
                        imgui.SameLine(115);
                        imgui.TextColored({ 0.5, 0.7, 0.5, 1.0 }, jobStr);
                        imgui.SameLine(230);
                        imgui.PushStyleColor(ImGuiCol_PlotHistogram, barColor);
                        imgui.PushStyleColor(ImGuiCol_FrameBg, barBg);
                        imgui.ProgressBar(hpp / 100, { -1, 10 }, '');
                        imgui.PopStyleColor(2);
                    end
                end
            end

            slider.winX, slider.winY = imgui.GetWindowPos();
            slider.winW, slider.winH = imgui.GetWindowSize();
        end
        imgui.End();
        imgui.PopStyleVar(2);
        imgui.PopStyleColor(4);

        return true;
    end

    -- Normal mini mode: collapsed icon badge
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.06, 0.06, 0.08, 0.95 });

    imgui.SetNextWindowSize({ 48, 48 });
    if (imgui.Begin('##pf_mini', ui.isOpen, bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoScrollbar))) then
        local texId = tonumber(ffi.cast("uint32_t", guiimages.LFG));

        imgui.PushID('pf_mini_btn');
        if (imgui.ImageButton(texId, { 28, 28 }, { 0, 0 }, { 1, 1 }, -1, { 0, 0, 0, 0 }, { 1, 1, 1, 0.8 })) then
            ui.setMiniMode(false);
        end
        imgui.PopID();

        -- Badge: show relevant listing count
        local badgeCount = 0;
        if (isRegistered) then
            local targetType = (ui.registeredListingType == 2) and 1 or 2;
            for _, ent in ipairs(entries) do
                if ((ent.listingType or 1) == targetType and not ui.isHiddenByFilter(ent)) then
                    badgeCount = badgeCount + 1;
                end
            end
        else
            for _, ent in ipairs(entries) do
                if (not ui.isHiddenByFilter(ent)) then
                    badgeCount = badgeCount + 1;
                end
            end
        end

        if (badgeCount > 0) then
            local drawList = imgui.GetWindowDrawList();
            local posX, posY = imgui.GetItemRectMax();
            local badgeColor = isRegistered and imgui.GetColorU32({ 0.3, 0.8, 0.3, 1.0 }) or imgui.GetColorU32({ 0.3, 0.6, 1.0, 1.0 });
            drawList:AddCircleFilled({ posX - 4, posY - 4 }, 8, badgeColor);
            local badgeStr = tostring(badgeCount);
            local textW = imgui.CalcTextSize(badgeStr);
            drawList:AddText({ posX - 4 - textW * 0.5, posY - 12 }, imgui.GetColorU32({ 1, 1, 1, 1 }), badgeStr);
        end

        slider.winX, slider.winY = imgui.GetWindowPos();
        slider.winW, slider.winH = imgui.GetWindowSize();
    end
    imgui.End();
    imgui.PopStyleColor();

    return true;
end

------------------------------------------------------------
-- Render: Duty ready check popup (roulette or mission)
------------------------------------------------------------
local function renderRoulettePopup()
    if (not roulette.active) then return; end

    local isMission = (roulette.source == 'mission');
    local popupTitle = isMission and 'Mission Help' or 'Duty Roulette';

    -- Check timeout
    if (roulette.timeout > 0 and os.time() > roulette.timeout) then
        roulette.active = false;
        logActivity('%s timed out', popupTitle);
        pfprint(string.format('%s ready check timed out.', popupTitle));
        return;
    end

    imgui.SetNextWindowSize({ 460, 230 });
    centerNextWindow();
        local open = { true };
    if (imgui.Begin(popupTitle, open, ImGuiWindowFlags_NoResize)) then

        -- Duty name and info
        imgui.Spacing();
        local titleColor = isMission and { 0.40, 0.60, 1.00, 1.0 } or { 1.0, 0.85, 0.4, 1.0 };
        imgui.TextColored(titleColor, popupTitle);
        imgui.Separator();
        imgui.Spacing();

        imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, roulette.dutyName);
        if (roulette.dutyCap > 0 and roulette.dutyTier > 0) then
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('Level Cap: %d  |  Tier: %d', roulette.dutyCap, roulette.dutyTier));
        elseif (roulette.dutyCap > 0 and roulette.dutyCap < 99) then
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('Level Cap: %d', roulette.dutyCap));
        end
        if (roulette.dutyZone > 0) then
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('Zone: %s', getZoneName(roulette.dutyZone)));
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Ready status (only leader sees the count)
        if (roulette.isLeader) then
            local readyStr = string.format('%d / %d Ready', roulette.readyCount, roulette.totalCount);
            imgui.TextColored({ 0.7, 0.9, 0.7, 1.0 }, readyStr);
        else
            if (roulette.myReady) then
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Waiting for party leader...');
            else
                local actionStr = isMission and 'wants to start a mission duty.' or 'wants to start a duty.';
                imgui.TextColored({ 0.9, 0.9, 0.6, 1.0 }, string.format('%s %s', roulette.leaderName or 'Leader', actionStr));
            end
        end

        -- Timeout countdown
        if (roulette.timeout > 0) then
            local remaining = roulette.timeout - os.time();
            if (remaining > 0) then
                imgui.SameLine();
                imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, string.format('(%ds)', remaining));
            end
        end

        imgui.Spacing();

        -- Buttons
        local showReroll = (roulette.isLeader and roulette.source == 'roulette');
        local btnW = showReroll and 100 or 120;
        local gap = 8;
        local totalW = showReroll and (btnW * 3 + gap * 2) or (btnW * 2 + gap);
        imgui.SetCursorPosX((imgui.GetWindowWidth() - totalW) * 0.5);

        -- Leader sees "Go" when everyone is ready, members see "Ready"
        if (roulette.isLeader) then
            if (roulette.totalCount > 0 and roulette.readyCount >= roulette.totalCount) then
                imgui.PushStyleColor(ImGuiCol_Button, { 0.2, 0.5, 0.2, 1.0 });
                if (imgui.Button('Commence!', { btnW, 30 })) then
                    requestRouletteGo();
                    roulette.active = false;
                    logActivity('%s commenced: %s', popupTitle, roulette.dutyName);
                end
                imgui.PopStyleColor();
            else
                imgui.PushStyleColor(ImGuiCol_Button, { 0.3, 0.3, 0.3, 0.5 });
                imgui.Button('Waiting...', { btnW, 30 });
                imgui.PopStyleColor();
            end
        else
            if (not roulette.myReady) then
                imgui.PushStyleColor(ImGuiCol_Button, { 0.2, 0.5, 0.2, 1.0 });
                if (imgui.Button('Ready', { btnW, 30 })) then
                    roulette.myReady = true;
                    requestReady();
                    logActivity('Marked ready for %s', roulette.dutyName);
                end
                imgui.PopStyleColor();
            else
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Ready!');
            end
        end

        -- Re-roll button (leader only, roulette only, costs 25 PFP)
        if (showReroll) then
            imgui.SameLine(0, gap);
            imgui.PushStyleColor(ImGuiCol_Button,        { 0.55, 0.35, 0.10, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.70, 0.45, 0.15, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.80, 0.55, 0.20, 1.0 });
            if (imgui.Button('Re-roll', { btnW, 30 })) then
                requestRouletteRoll(true);
                logActivity('Re-rolling Duty Roulette (-25 PFP)...');
            end
            imgui.PopStyleColor(3);
            if (imgui.IsItemHovered()) then
                setTooltip('Costs 25 PFP');
            end
        end

        imgui.SameLine(0, gap);
        imgui.PushStyleColor(ImGuiCol_Button, { 0.5, 0.2, 0.2, 1.0 });
        if (imgui.Button('Decline', { btnW, 30 })) then
            roulette.active = false;
            if (roulette.leaderName and not roulette.isLeader) then
                sendDutyDecline();
            end
            logActivity('Declined %s', popupTitle);
            pfprint(string.format('You declined the %s.', popupTitle));
        end
        imgui.PopStyleColor();
    end
    imgui.End();

    -- Handle window close via X button
    if (not open[1]) then
        roulette.active = false;
    end
end

------------------------------------------------------------
-- Render: Main window
------------------------------------------------------------
------------------------------------------------------------
-- Render: Mission selection popup (when multiple eligible)
------------------------------------------------------------
------------------------------------------------------------
-- Render: First-time tutorial
------------------------------------------------------------
local tutorialStep = 1;
local tutorialPages = {
    {
        title = 'Welcome to Party Finder!',
        lines = {
            'Find and form groups for any content.',
            '',
            'Type /pf to open/close this window.',
            'Default hotkey: Ctrl+G (change in Settings).',
            '',
            'Click Next to learn the features.',
        },
    },
    {
        title = 'Finding a Group (LFG)',
        lines = {
            'The LFG tab shows players looking for a group.',
            '',
            'To register:',
            '  1. Click Register, pick a category + role',
            '  2. Add a comment (optional)',
            '  3. Others right-click your listing to invite',
        },
    },
    {
        title = 'Recruiting Members (LFM)',
        lines = {
            'The LFM tab shows leaders recruiting.',
            '',
            'Registering as LFM sends a server-wide alert.',
            'Enable Auto-Accept to let players join instantly,',
            'or review each request manually.',
            '',
            'The bell icon mutes LFM notifications.',
        },
    },
    {
        title = 'Duty Roulette',
        lines = {
            'As LFM, click Roulette for a random BCNM.',
            '',
            'A ready check is sent to your party.',
            'Once ready, everyone teleports to the duty.',
            'Entry requirements are waived.',
            '',
            'Earn PFP on completion (+100 bonus first daily).',
            'Re-roll: 25 PFP (max 3 per 24h, sticky).',
        },
    },
    {
        title = 'Mission Help',
        lines = {
            'As LFM in Mission, click Start Duty.',
            '',
            'Helpers teleport in, requirements waived.',
            'On win: helpers skip the cutscene, earn PFP,',
            'and return to their original position.',
            '',
            'No key items given to helpers.',
            'Home Points blocked during duty.',
        },
    },
    {
        title = 'Venture Parties',
        lines = {
            'Register as LFM in the Venture category.',
            '',
            'Your venture tier and zone are detected',
            'automatically from your current progress.',
            '',
            'Earn 10 PFP per completion with 3+ players.',
            'Daily cap: 100 PFP from ventures.',
        },
    },
    {
        title = 'Tips & Shortcuts',
        lines = {
            '/pf           Toggle window',
            '/pf notify    Mute LFM notifications',
            '/pf block     Block a player',
            '/pf tutorial  Show this again',
            '',
            'Right-click entries for options.',
            'X button = mini mode (not close).',
        },
    },
};

local function renderTutorial()
    if (pfSettings.tutorialComplete) then return; end

    local winW = 540;
    local winH = 300;
    imgui.SetNextWindowSize({ winW, winH });
    centerNextWindow();
    local open = { true };

    if (imgui.Begin('Party Finder - Getting Started', open, ImGuiWindowFlags_NoResize + ImGuiWindowFlags_NoCollapse)) then
        local page = tutorialPages[tutorialStep];

        -- Title
        imgui.Spacing();
        imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, page.title);
        imgui.Separator();
        imgui.Spacing();

        -- Content
        for _, line in ipairs(page.lines) do
            if (line == '') then
                imgui.Spacing();
            else
                imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, line);
            end
        end

        -- Step indicator
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, string.format('Step %d of %d', tutorialStep, #tutorialPages));

        -- Buttons
        imgui.SameLine();
        local btnW = 80;
        local gap = 8;
        imgui.SetCursorPosX(winW - btnW * 2 - gap - 16);

        if (tutorialStep > 1) then
            if (imgui.Button('Back', { btnW, 24 })) then
                tutorialStep = tutorialStep - 1;
            end
        else
            if (imgui.Button('Skip', { btnW, 24 })) then
                pfSettings.tutorialComplete = true;
                ashitaSettings.save();
            end
        end

        imgui.SameLine(0, gap);

        if (tutorialStep < #tutorialPages) then
            imgui.PushStyleColor(ImGuiCol_Button, { 0.2, 0.5, 0.2, 1.0 });
            if (imgui.Button('Next', { btnW, 24 })) then
                tutorialStep = tutorialStep + 1;
            end
            imgui.PopStyleColor();
        else
            imgui.PushStyleColor(ImGuiCol_Button, { 0.2, 0.5, 0.2, 1.0 });
            if (imgui.Button('Finish', { btnW, 24 })) then
                pfSettings.tutorialComplete = true;
                ashitaSettings.save();
            end
            imgui.PopStyleColor();
        end
    end
    imgui.End();

    -- Handle X button
    if (not open[1]) then
        pfSettings.tutorialComplete = true;
        ashitaSettings.save();
    end
end

------------------------------------------------------------
-- Render: Mission selection popup (when multiple eligible)
------------------------------------------------------------
local function renderMissionSelectPopup()
    if (not missionSelect.active or #missionSelect.entries == 0) then return; end

    local entryCount = #missionSelect.entries;
    local winH = 80 + (entryCount * 28);
    local winHClamped = math.min(winH, 300);
    imgui.SetNextWindowSize({ 360, winHClamped });
    centerNextWindow();
    local open = { true };
    if (imgui.Begin('Select Mission', open, ImGuiWindowFlags_NoResize)) then
        imgui.Spacing();
        imgui.TextColored({ 0.40, 0.60, 1.00, 1.0 }, 'Select a Mission Duty');
        imgui.Separator();
        imgui.Spacing();

        for i, entry in ipairs(missionSelect.entries) do
            local label = string.format('%s (Lv%d)', entry.name, entry.levelCap);
            imgui.PushStyleColor(ImGuiCol_Button, { 0.20, 0.35, 0.55, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.30, 0.45, 0.70, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.35, 0.55, 0.80, 1.0 });
            if (imgui.Button(label, { -1, 24 })) then
                requestMissionStart(entry.id);
                missionSelect.active = false;
                logActivity('Selected mission: %s', entry.name);
            end
            -- Full details on hover (handles labels that get clipped by the window).
            if (imgui.IsItemHovered() and tooltipsEnabled) then
                imgui.BeginTooltip();
                imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 }, entry.name);
                imgui.TextColored({ 0.6, 0.8, 0.6, 1.0 }, string.format('Zone: %s', getZoneName(entry.zone)));
                imgui.TextColored({ 0.7, 0.7, 0.9, 1.0 }, string.format('Level Cap: %d  |  Max Players: %d', entry.levelCap, entry.maxPlayers));
                imgui.EndTooltip();
            end
            imgui.PopStyleColor(3);
        end
    end
    imgui.End();

    if (not open[1]) then
        missionSelect.active = false;
    end
end

------------------------------------------------------------
-- Render: Settings window
------------------------------------------------------------
local function renderSettingsWindow()
    if (not settingsBuf.isOpen) then return; end

    imgui.SetNextWindowSize({ 420, 440 }, ImGuiCond_FirstUseEver);
    local open = { true };
    if (imgui.Begin('Party Finder - Settings', open, ImGuiWindowFlags_None)) then
        imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, 'Display');
        imgui.Separator();
        imgui.Spacing();

        -- Sync local buffer with current setting (in case it was toggled via /pf cmd)
        settingsBuf.tooltips[1] = tooltipsEnabled;
        if (imgui.Checkbox('Show tooltips', settingsBuf.tooltips)) then
            tooltipsEnabled            = settingsBuf.tooltips[1];
            pfSettings.tooltipsEnabled = tooltipsEnabled;
            ashitaSettings.save();
        end

        settingsBuf.lfm[1] = lfmNotifications;
        if (imgui.Checkbox('LFM notifications in chat', settingsBuf.lfm)) then
            lfmNotifications            = settingsBuf.lfm[1];
            pfSettings.lfmNotifications = lfmNotifications;
            ashitaSettings.save();
        end

        settingsBuf.confirmWd[1] = confirmWithdraw;
        if (imgui.Checkbox('Confirm before withdrawing', settingsBuf.confirmWd)) then
            confirmWithdraw            = settingsBuf.confirmWd[1];
            pfSettings.confirmWithdraw = confirmWithdraw;
            ashitaSettings.save();
        end

        settingsBuf.joinable[1] = (pfSettings.joinableOnly ~= false);
        if (imgui.Checkbox('Show only joinable listings', settingsBuf.joinable)) then
            pfSettings.joinableOnly = settingsBuf.joinable[1];
            ashitaSettings.save();
        end
        if (imgui.IsItemHovered() and tooltipsEnabled) then
            setTooltip('Hides full parties and listings from incompatible game modes (CW vs ACE/WEW).');
        end

        imgui.Spacing();
        imgui.Text('Window opacity');
        settingsBuf.alpha[1] = windowAlpha;
        if (imgui.SliderFloat('##wnd_alpha', settingsBuf.alpha, 0.20, 1.00, '%.2f')) then
            windowAlpha            = settingsBuf.alpha[1];
            pfSettings.windowAlpha = windowAlpha;
            ashitaSettings.save();
        end

        imgui.Spacing();
        imgui.Text('Background image');
        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, 'Filename in images/ folder (blank = none)');
        settingsBuf.bgImage[1] = bgImage;
        imgui.PushItemWidth(-60);
        imgui.InputText('##bg_path', settingsBuf.bgImage, settingsBuf.bgImageSize);
        imgui.PopItemWidth();
        imgui.SameLine();
        if (imgui.SmallButton('Apply')) then
            bgImage            = settingsBuf.bgImage[1] or '';
            pfSettings.bgImage = bgImage;
            ashitaSettings.save();
            loadBgTexture();
        end

        if (bgTexture ~= nil) then
            imgui.Text('Background opacity');
            settingsBuf.bgAlpha[1] = bgAlpha;
            if (imgui.SliderFloat('##bg_alpha', settingsBuf.bgAlpha, 0.0, 1.0, '%.2f')) then
                bgAlpha            = settingsBuf.bgAlpha[1];
                pfSettings.bgAlpha = bgAlpha;
                ashitaSettings.save();
            end
        end

        imgui.Spacing();
        imgui.Text('Toggle keybind');
        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '^ = Ctrl, ! = Alt (e.g. ^G, !F5)');
        settingsBuf.keybind[1] = keybind;
        imgui.PushItemWidth(-60);
        imgui.InputText('##keybind', settingsBuf.keybind, settingsBuf.keybindSize);
        imgui.PopItemWidth();
        imgui.SameLine();
        if (imgui.SmallButton('Set')) then
            local newBind = settingsBuf.keybind[1] or '';
            if (newBind ~= keybind) then
                -- Unbind old key
                if (keybind ~= '') then
                    AshitaCore:GetChatManager():QueueCommand(1, string.format('/unbind %s', keybind));
                end
                -- Bind new key
                keybind            = newBind;
                pfSettings.keybind = keybind;
                ashitaSettings.save();
                if (keybind ~= '') then
                    AshitaCore:GetChatManager():QueueCommand(1, string.format('/bind %s /pf toggle', keybind));
                    pfprint(string.format('Keybind set to %s', keybind));
                else
                    pfprint('Keybind cleared.');
                end
            end
        end

        imgui.Spacing();
        imgui.Spacing();
        imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, 'Audio');
        imgui.Separator();
        imgui.Spacing();

        -- Fresh settings files may not include the mute map yet; create on demand.
        if (pfSettings.soundMutes == nil) then pfSettings.soundMutes = T{}; end

        -- Master slider grays when every sound is individually muted (nothing left to control).
        local allMuted = true;
        for _, name in ipairs(sounds.NAMES) do
            if (not pfSettings.soundMutes[name]) then allMuted = false; break; end
        end

        imgui.Text('Master volume');
        settingsBuf.soundVolume[1] = pfSettings.soundVolume or 100;
        if (allMuted) then imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.4); end
        local volChanged = imgui.SliderInt('##sound_volume', settingsBuf.soundVolume, 0, 100, '%d%%');
        if (allMuted) then imgui.PopStyleVar(); end
        if (volChanged and not allMuted) then
            pfSettings.soundVolume = settingsBuf.soundVolume[1];
            ashitaSettings.save();
        end

        imgui.Spacing();
        imgui.Text('Mute');

        local MUTE_LABELS = {
            register      = 'Register',
            withdraw      = 'Withdraw',
            join_request  = 'Join request',
            join_accepted = 'Join accepted',
            roulette_roll = 'Roulette roll',
        };
        local MUTE_LAYOUT = {
            { 'register',      'join_request' },
            { 'join_accepted', 'withdraw' },
            { 'roulette_roll', nil },
        };
        for _, row in ipairs(MUTE_LAYOUT) do
            for col = 1, 2 do
                local key = row[col];
                if (key ~= nil) then
                    if (col == 2) then imgui.SameLine(180); end
                    local buf = settingsBuf.mutes[key];
                    buf[1] = pfSettings.soundMutes[key] and true or false;
                    if (imgui.Checkbox(MUTE_LABELS[key] .. '##mute_' .. key, buf)) then
                        pfSettings.soundMutes[key] = buf[1];
                        ashitaSettings.save();
                    end
                end
            end
        end

        imgui.Spacing();
        imgui.Spacing();
        imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, 'Actions');
        imgui.Separator();
        imgui.Spacing();

        if (imgui.Button('Reset Tutorial', { -1, 24 })) then
            pfSettings.tutorialComplete = false;
            tutorialStep                = 1;
            ashitaSettings.save();
            pfprint('Tutorial reset.');
        end

        if (imgui.Button('Print Blocklist', { -1, 24 })) then
            local names = T{};
            for name, _ in pairs(blacklist) do
                names:append(name);
            end
            if (#names > 0) then
                pfprint(string.format('Blocked: %s', table.concat(names, ', ')));
            else
                pfprint('Blocklist is empty.');
            end
        end

        imgui.Spacing();
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Use /pf block <name> to block.');
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, 'Use /pf unblock <name> to unblock.');
    end
    imgui.End();

    if (not open[1]) then
        settingsBuf.isOpen = false;
    end
end

------------------------------------------------------------
-- Render: Main window
------------------------------------------------------------
local function renderMain()
    -- Hide the UI during cutscenes. The server won't reply to refresh pings
    -- while the player is in an event — without this gate, the ping retry
    -- timer runs out mid-CS and shows "[PartyFinder] Currently unavailable."
    -- Also an ImGui window floating over a cutscene is distracting. We save
    -- the prior isOpen state and restore it once the CS ends.
    if (isInEvent()) then
        if (not ui.csHidden) then
            ui.csHidden          = true;
            ui.wasOpenBeforeCS   = ui.isOpen[1];
            ui.isOpen[1]         = false;
            pingPendingSince     = nil; -- drop any in-flight ping timer
            pingRetryCount       = 0;
            serverDisabled       = false;
        end
        return;
    elseif (ui.csHidden) then
        ui.csHidden = false;
        if (ui.wasOpenBeforeCS) then
            ui.isOpen[1] = true;
        end
        ui.wasOpenBeforeCS = nil;
    end

    if (not ui.isOpen[1]) then return; end

    -- Kill-switch detection: if a REFRESH was sent and no response came back in time,
    -- retry up to PF_PING_MAX_RETRIES times silently (handles slow first-login /
    -- zone-in). If all retries time out, the server is genuinely unavailable — close
    -- the UI and notify.
    if (pingPendingSince ~= nil and (os.time() - pingPendingSince) > PF_PING_TIMEOUT) then
        if (pingRetryCount < PF_PING_MAX_RETRIES) then
            pingRetryCount   = pingRetryCount + 1;
            pingPendingSince = os.time();
            sendC2S(C2S.REFRESH);
            devlog('Refresh timed out, retry %d/%d...', pingRetryCount, PF_PING_MAX_RETRIES);
            -- fall through to render this frame; next frame will check again
        else
            pingPendingSince = nil;
            pingRetryCount   = 0;
            if (not serverDisabled) then
                serverDisabled = true;
                pfprint('Currently unavailable.');
            end
            ui.isOpen[1] = false;
            return;
        end
    end

    pushTheme();

    -- Popups that must render in both full and mini mode (ready check, mission select, settings)
    renderRoulettePopup();
    renderMissionSelectPopup();
    renderSettingsWindow();

    -- Auto-switch to mini mode on duty start so the raid frame replaces the
    -- main window by default. Fires ONCE per duty — the raid-frame expand
    -- button sets ui.expandedDuringDuty=true to opt back into the main UI,
    -- and we don't want to immediately force the user back to mini.
    -- ui.expandedDuringDuty is cleared below when phase returns to 0.
    if (activeDuty.phase == 0 and ui.expandedDuringDuty) then
        ui.expandedDuringDuty = false;
    end
    if (activeDuty.phase > 0 and not miniMode and not ui.expandedDuringDuty) then
        ui.setMiniMode(true);
    end

    -- Mini mode
    if (miniMode) then
        renderMiniMode();
        renderNotificationSlider();
        popTheme();
        return;
    end

    -- Apply default size only on first use; subsequent frames let the user resize freely.
    imgui.SetNextWindowSize({ 700, 480 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 620, 400 }, { 960, 720 });
    imgui.SetNextWindowBgAlpha(windowAlpha);
    if (imgui.Begin('Party Finder', ui.isOpen, ImGuiWindowFlags_None)) then

        -- Track position for notification slider anchoring
        slider.winX, slider.winY = imgui.GetWindowPos();
        slider.winW, slider.winH       = imgui.GetWindowSize();

        -- Contextual action bar — changes based on duty/registration state
        if (activeDuty.phase > 0) then
            -- === ACTIVE DUTY STATE ===
            local phaseStr = (activeDuty.phase == 1) and 'Teleporting...' or 'In Progress';
            local phaseColor = (activeDuty.phase == 1) and { 1.0, 0.8, 0.3, 1.0 } or { 0.3, 1.0, 0.6, 1.0 };
            imgui.TextColored(phaseColor, '>>');
            imgui.SameLine(0, 6);
            imgui.TextColored(phaseColor, 'Active Duty:');
            imgui.SameLine(0, 4);
            imgui.TextColored({ 1.0, 1.0, 1.0, 1.0 }, activeDuty.name);
            imgui.SameLine(0, 8);
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, string.format('(%s)', phaseStr));
        elseif (isRegistered) then
            -- === REGISTERED STATE ===
            local typeStr = (ui.registeredListingType == 2) and 'Recruiting' or 'Looking for Group';
            local catName = CATEGORY_NAMES[ui.registeredCategory] or 'General';

            -- Status indicator (green dot + listing info)
            imgui.TextColored({ 0.3, 1.0, 0.3, 1.0 }, '>>');

            imgui.SameLine(0, 6);
            imgui.TextColored({ 0.9, 0.95, 0.8, 1.0 }, typeStr);
            imgui.SameLine(0, 4);
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('- %s', catName));

            -- Party size for LFM
            if (ui.registeredListingType == 2) then
                local myName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
                for _, ent in ipairs(entries) do
                    if (ent.name == myName) then
                        imgui.SameLine(0, 6);
                        imgui.TextColored({ 0.7, 0.9, 0.5, 1.0 }, string.format('(%d/6)', ent.partySize or 1));
                        break;
                    end
                end
            end

            imgui.SameLine(0, 10);

            -- Withdraw button
            imgui.PushStyleColor(ImGuiCol_Button,        { 0.45, 0.18, 0.18, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.60, 0.25, 0.25, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.70, 0.30, 0.30, 1.0 });
            if (imgui.SmallButton('Withdraw')) then
                if (confirmWithdraw) then
                    isConfirmWithdrawOpen = true;
                else
                    requestWithdraw();
                    ui.playSound('withdraw');
                end
            end
            imgui.PopStyleColor(3);

            -- Category-specific duty action (LFM only):
            --   1 EXP     -> no action (plain LFM for merit/capped EXP)
            --   2 Mission -> Start Duty (pick a mission BCNM)
            --   3 BCNM    -> Roulette (random level-capped BCNM from pool)
            --   4 Mentor, 5 Venture -> no action (LFG+manual / server-side)
            if (ui.registeredListingType == 2) then
                if (ui.registeredCategory == 3) then
                    imgui.SameLine(0, 6);
                    imgui.PushStyleColor(ImGuiCol_Button,        { 0.55, 0.35, 0.10, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.70, 0.45, 0.15, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.80, 0.55, 0.20, 1.0 });
                    if (imgui.SmallButton('Roulette')) then
                        requestRouletteRoll();
                        logActivity('Requesting Duty Roulette...');
                    end
                    imgui.PopStyleColor(3);
                elseif (ui.registeredCategory == 2) then
                    imgui.SameLine(0, 6);
                    imgui.PushStyleColor(ImGuiCol_Button,        { 0.20, 0.35, 0.55, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.30, 0.45, 0.70, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.35, 0.55, 0.80, 1.0 });
                    if (imgui.SmallButton('Start Duty')) then
                        missionSelect.entries = T{};
                        missionSelect.active = false;
                        requestMissionStart(0);
                        logActivity('Requesting Mission Duty...');
                    end
                    imgui.PopStyleColor(3);
                end
            end
        else
            -- === NOT REGISTERED STATE ===
            local canRegister = isPartyLeaderOrSolo();
            imgui.PushStyleColor(ImGuiCol_Button,        { 0.15, 0.40, 0.15, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.20, 0.55, 0.20, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.25, 0.65, 0.25, 1.0 });
            if (not canRegister) then
                imgui.PushStyleColor(ImGuiCol_Button,        { 0.30, 0.30, 0.30, 1.0 });
                imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.30, 0.30, 0.30, 1.0 });
                imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.30, 0.30, 0.30, 1.0 });
            end
            if (imgui.Button('Create Listing', { 0, 24 })) then
                if (canRegister) then
                    isCommentWindowOpen = true;
                end
            end
            if (not canRegister) then
                imgui.PopStyleColor(3);
                if (imgui.IsItemHovered()) then
                    setTooltip('Only the party leader can register.');
                end
            end
            imgui.PopStyleColor(3);
        end

        -- Right-aligned: refresh + settings + bell (always visible)
        imgui.SameLine();
        imgui.SetCursorPosX(imgui.GetWindowWidth() - 100);

        local iconsTex = tonumber(ffi.cast("uint32_t", guiimages.icons));
        imgui.PushID('refresh_btn');
        if (imgui.ImageButton(iconsTex, { 18, 18 }, { 0, 0 }, { 0.125, 1 }, -1, { 0, 0, 0, 0 }, { 1, 1, 1, 0.8 })) then
            requestRefresh();
        end
        imgui.PopID();
        if (imgui.IsItemHovered()) then
            setTooltip('Refresh');
        end

        imgui.SameLine(0, 4);
        local gearTex = tonumber(ffi.cast("uint32_t", guiimages.gear));
        imgui.PushID('settings_btn');
        if (imgui.ImageButton(gearTex, { 18, 18 }, { 0, 0 }, { 1, 1 }, -1, { 0, 0, 0, 0 }, { 1, 1, 1, 0.8 })) then
            settingsBuf.isOpen = not settingsBuf.isOpen;
        end
        imgui.PopID();
        if (imgui.IsItemHovered()) then
            setTooltip('Settings');
        end

        imgui.SameLine(0, 4);
        local bellTint = lfmNotifications and { 1, 0.9, 0.3, 1.0 } or { 0.4, 0.4, 0.4, 0.5 };
        local bellTex = tonumber(ffi.cast("uint32_t", guiimages.bell));
        imgui.PushID('notify_toggle');
        if (imgui.ImageButton(bellTex, { 18, 18 }, { 0, 0 }, { 1, 1 }, -1, { 0, 0, 0, 0 }, bellTint)) then
            lfmNotifications = not lfmNotifications;
            pfSettings.lfmNotifications = lfmNotifications;
            ashitaSettings.save();
            local state = lfmNotifications and 'ON' or 'OFF';
            logActivity('LFM notifications: %s', state);
            pfprint(string.format('LFM notifications %s', state));
        end
        imgui.PopID();
        if (imgui.IsItemHovered()) then
            setTooltip(lfmNotifications and 'LFM notifications: ON (click to mute)' or 'LFM notifications: OFF (click to unmute)');
        end

            local lfgCount = 0;
            local lfmCount = 0;
            for _, e in ipairs(entries) do
                if (not ui.isHiddenByFilter(e)) then
                    if (e.listingType == 2) then
                        lfmCount = lfmCount + 1;
                    else
                        lfgCount = lfgCount + 1;
                    end
                end
            end

            -- Tabs: LFG, LFM, Activity
            if (not ui.activeTab) then ui.activeTab = 1; end

            if (not ui.activeTab) then ui.activeTab = 1; end

            local lfgLabel = string.format('Looking for Group (%d)', lfgCount);
            local lfmLabel = string.format('Looking for Members (%d)', lfmCount);
            local actLabel = 'Activity';

            local tabs = { { 1, lfgLabel }, { 2, lfmLabel }, { 3, actLabel } };
            for _, tab in ipairs(tabs) do
                local id    = tab[1];
                local label = tab[2];
                local isActive = (ui.activeTab == id);

                if (isActive) then
                    imgui.PushStyleColor(ImGuiCol_Button, { 0.18, 0.18, 0.24, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.95, 0.80, 1.0 });
                else
                    imgui.PushStyleColor(ImGuiCol_Button, { 0.10, 0.10, 0.13, 1.0 });
                    imgui.PushStyleColor(ImGuiCol_Text, { 0.5, 0.5, 0.5, 1.0 });
                end
                if (imgui.SmallButton(label)) then
                    ui.activeTab = id;
                end
                imgui.PopStyleColor(2);
                if (id < 3) then imgui.SameLine(0, 4); end
            end

            imgui.Separator();

            -- Tab content
            if (ui.activeTab == 3) then
                renderActivityTab();
            else
                imgui.BeginChild('##entries', { -1, -26 }, ImGuiChildFlags_None);

                if (bgTexture ~= nil) then
                    local drawList = imgui.GetWindowDrawList();
                    local posX, posY   = imgui.GetCursorScreenPos();
                    local sizeW, sizeH = imgui.GetContentRegionAvail();
                    local pMin = { posX, posY };
                    local pMax = { posX + sizeW, posY + sizeH };
                    local a = math.max(0, math.min(1, bgAlpha));
                    local col = bit.bor(
                        bit.lshift(math.floor(a * 255), 24),
                        0x00FFFFFF
                    );
                    drawList:AddImage(
                        tonumber(ffi.cast("uint32_t", bgTexture)),
                        pMin, pMax,
                        { 0, 0 }, { 1, 1 },
                        col
                    );
                end

                local visibleIndex = 0;
                local hiddenByFilter = 0;
                for i, entry in ipairs(entries) do
                    local entryType = entry.listingType or 1;
                    if (entryType == ui.activeTab) then
                        if (ui.isHiddenByFilter(entry)) then
                            hiddenByFilter = hiddenByFilter + 1;
                        else
                            visibleIndex = visibleIndex + 1;
                            renderEntryCard(i, entry);
                        end
                    end
                end

                if (hiddenByFilter > 0 and visibleIndex > 0) then
                    imgui.Spacing();
                    imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 },
                        string.format('  %d listing%s hidden by Show only joinable. Toggle in Settings.',
                            hiddenByFilter, hiddenByFilter == 1 and '' or 's'));
                end

                if (visibleIndex == 0) then
                    imgui.Spacing();
                    imgui.Spacing();
                    if (hiddenByFilter > 0) then
                        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 },
                            string.format('  All %d listing%s hidden by Show only joinable. Toggle in Settings.',
                                hiddenByFilter, hiddenByFilter == 1 and '' or 's'));
                    elseif (ui.activeTab == 1) then
                        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '  No players looking for a group. Be the first to register!');
                    else
                        imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '  No groups recruiting. Start one by registering as LFM!');
                    end
                end

                imgui.EndChild();
            end

        -- Bottom status bar (thin, info only — like Notepad's status bar)
        imgui.Separator();
        local jobID    = AshitaCore:GetMemoryManager():GetPlayer():GetMainJob();
        if (jobID == 0) then
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, 'Loading...');
        else
            local subID    = AshitaCore:GetMemoryManager():GetPlayer():GetSubJob();
            local jobLevel = AshitaCore:GetMemoryManager():GetPlayer():GetMainJobLevel();
            local jobName  = JOB_ABBR[jobID] or '???';
            local jobStr   = string.format('%s%d', jobName, jobLevel);
            if (subID > 0) then
                local subName  = JOB_ABBR[subID] or '???';
                local subLevel = AshitaCore:GetMemoryManager():GetPlayer():GetSubJobLevel();
                jobStr = jobStr .. string.format('/%s%d', subName, subLevel);
            end

            drawJobIcon(jobID, 16);
            imgui.SameLine(0, 4);
            imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, jobStr);
        end

        if (isRegistered) then
            imgui.SameLine(0, 10);
            imgui.TextColored({ 0.4, 0.9, 0.4, 1.0 }, 'Registered');
        end

        if (ui.myPFP and ui.myPFP > 0) then
            imgui.SameLine(0, 10);
            imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, string.format('PFP: %d', ui.myPFP));
        end

        if (ui.myDailyCount) then
            imgui.SameLine(0, 6);
            local dailyColor = ui.myDailyCount >= 3 and { 0.5, 0.5, 0.5, 1.0 } or { 0.6, 0.8, 0.6, 1.0 };
            imgui.TextColored(dailyColor, string.format('Daily: %d/3', ui.myDailyCount));
        end

        -- Listing count (right-aligned)
        local listingStr = string.format('%d listings', #entries);
        local textWidth = imgui.CalcTextSize(listingStr);
        imgui.SameLine();
        imgui.SetCursorPosX(imgui.GetWindowWidth() - textWidth - 12);
        imgui.TextColored({ 0.50, 0.55, 0.65, 1.0 }, listingStr);

        -- Dev panel (only if enabled via /pf dev)
        renderDevPanel();
    end
    imgui.End();

    -- If user closed the window via X, go to mini mode instead of hiding
    if (not ui.isOpen[1]) then
        ui.setMiniMode(true);
        ui.isOpen[1] = true; -- keep the state "open" so mini mode renders
    end

    -- Sub-windows
    renderCommentWindow();
    renderTellWindow();
    renderTutorial();

    -- Confirmation dialog for join/invite
    if (isConfirmJoinOpen and confirmJoinEntry ~= nil) then
        imgui.SetNextWindowSize({ 340, 130 });
        centerNextWindow();
        local confirmOpen = { true };
        if (imgui.Begin('Confirm - Party Finder', confirmOpen, ImGuiWindowFlags_NoResize)) then
            local entry = confirmJoinEntry;
            local jobName = JOB_ABBR[entry.job] or '???';

            if ((entry.listingType or 1) == 2) then
                imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, string.format('Send join request to %s?', entry.name));
                -- TextUnformatted because the comment may contain '%' and
                -- TextColored is printf-style.
                imgui.PushStyleColor(ImGuiCol_Text, { 0.6, 0.6, 0.6, 1.0 });
                imgui.TextUnformatted(string.format('%s%d - %s', jobName, entry.level, entry.comment or ''));
                imgui.PopStyleColor();
            else
                imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, string.format('Invite %s to your party?', entry.name));
                imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('%s%d - %s', jobName, entry.level, getZoneName(entry.zoneId)));
            end

            imgui.Spacing();
            local btnW = 100;
            local gap = 12;
            imgui.SetCursorPosX((imgui.GetWindowWidth() - btnW * 2 - gap) * 0.5);

            if (imgui.Button('Yes', { btnW, 28 })) then
                if ((entry.listingType or 1) == 2) then
                    sendJoinRequest(entry);
                else
                    AshitaCore:GetChatManager():QueueCommand(1, string.format('/pcmd add %s', entry.name));
                    logActivity('Invited %s (%s%d)', entry.name, jobName, entry.level);
                end
                isConfirmJoinOpen = false;
                confirmJoinEntry = nil;
            end
            imgui.SameLine(0, gap);
            if (imgui.Button('No', { btnW, 28 })) then
                isConfirmJoinOpen = false;
                confirmJoinEntry = nil;
            end
        end
        imgui.End();

        if (not confirmOpen[1]) then
            isConfirmJoinOpen = false;
            confirmJoinEntry  = nil;
        end
    end

    -- Confirmation dialog for withdraw
    if (isConfirmWithdrawOpen) then
        imgui.SetNextWindowSize({ 360, 120 });
        centerNextWindow();
        imgui.SetNextWindowFocus();
        local wOpen = { true };
        if (imgui.Begin('Confirm Withdraw - Party Finder', wOpen, ImGuiWindowFlags_NoResize)) then
            imgui.TextColored({ 0.9, 0.9, 0.9, 1.0 }, 'Withdraw your Party Finder listing?');
            imgui.Spacing();

            local btnW = 100;
            local gap = 12;
            imgui.SetCursorPosX((imgui.GetWindowWidth() - btnW * 2 - gap) * 0.5);

            if (imgui.Button('Yes', { btnW, 28 })) then
                requestWithdraw();
                ui.playSound('withdraw');
                isConfirmWithdrawOpen = false;
            end
            imgui.SameLine(0, gap);
            if (imgui.Button('No', { btnW, 28 })) then
                isConfirmWithdrawOpen = false;
            end
        end
        imgui.End();

        if (not wOpen[1]) then
            isConfirmWithdrawOpen = false;
        end
    end

    renderNotificationSlider();

    popTheme();
end

------------------------------------------------------------
-- Events: Load — auto-open and refresh
------------------------------------------------------------
ashita.events.register('load', 'pf_load_cb', function()
    ui.isOpen[1] = false;
    if (keybind ~= '') then
        AshitaCore:GetChatManager():QueueCommand(1, string.format('/bind %s /pf toggle', keybind));
    end
end);

ashita.events.register('unload', 'pf_unload_cb', function()
    if (keybind ~= '') then
        AshitaCore:GetChatManager():QueueCommand(1, string.format('/unbind %s', keybind));
    end
    sounds.cleanup();
end);

------------------------------------------------------------
-- Events: Command
------------------------------------------------------------
ashita.events.register('command', 'pf_command_cb', function(e)
    local cmd = e.command:lower();
    if (cmd == '/pf toggle') then
        if (not ui.isOpen[1]) then
            ui.isOpen[1] = true;
            ui.setMiniMode(false);
            requestRefresh();
        else
            ui.setMiniMode(not miniMode);
            if (not miniMode) then
                requestRefresh();
            end
        end
        return;
    end
    if (cmd == '/pf' or cmd == '!pf') then
        ui.isOpen[1] = not ui.isOpen[1];
        if (ui.isOpen[1]) then
            requestRefresh();
        end
        return;
    end
    if (cmd == '/pf dev') then
        devMode = not devMode;
        pfprint(string.format('Dev mode: %s', devMode and 'ON' or 'OFF'));
        return;
    end
    if (cmd == '/pf tutorial') then
        pfSettings.tutorialComplete = false;
        tutorialStep = 1;
        ashitaSettings.save();
        pfprint('Tutorial reset.');
        return;
    end
    if (cmd == '/pf notify') then
        lfmNotifications = not lfmNotifications;
        pfSettings.lfmNotifications = lfmNotifications;
        ashitaSettings.save();
        local state = lfmNotifications and 'ON' or 'OFF';
        logActivity('LFM notifications: %s', state);
        pfprint(string.format('LFM notifications %s', state));
        return;
    end
    if (cmd == '/pf tooltips') then
        tooltipsEnabled = not tooltipsEnabled;
        pfSettings.tooltipsEnabled = tooltipsEnabled;
        ashitaSettings.save();
        pfprint(string.format('Tooltips %s', tooltipsEnabled and 'ON' or 'OFF'));
        return;
    end
    if (cmd == '/pf settings') then
        settingsBuf.isOpen = not settingsBuf.isOpen;
        return;
    end

    -- /pf block <name>
    local blockName = e.command:match('^/pf block%s+(%S+)');
    if (blockName) then
        blacklist[blockName:lower()] = true;
        pfSettings.blacklist = blacklist;
        ashitaSettings.save();
        pfprint(string.format('Blocked %s', blockName));
        return;
    end

    -- /pf unblock <name>
    local unblockName = e.command:match('^/pf unblock%s+(%S+)');
    if (unblockName) then
        blacklist[unblockName:lower()] = nil;
        pfSettings.blacklist = blacklist;
        ashitaSettings.save();
        pfprint(string.format('Unblocked %s', unblockName));
        return;
    end

    -- /pf blocklist
    if (cmd == '/pf blocklist') then
        local names = T{};
        for name, _ in pairs(blacklist) do
            names:append(name);
        end
        if (#names > 0) then
            pfprint(string.format('Blocked: %s', table.concat(names, ', ')));
        else
            pfprint('Blocklist is empty.');
        end
        return;
    end
end);

------------------------------------------------------------
-- Auto-accept party invite when we have a pending PF join request
------------------------------------------------------------
-- 0x1A3 Venture Info packet — server broadcast of current EXP venture state
-- (active pool A/B rolls + boss progress per tier, HVNM status). Arrives
-- every ~90s and on zone-in. The game client doesn't know this ID so we
-- block it. Parsed into ventureState for tooltip consumers.
-- Layout: modules/catseyexi/cpp/packets/venture_info.cpp
--   0x04 version, 0x05 gameMode, 0x06-0x07 reserved
--   0x08-0x2B Pool A (6 tiers × 6 bytes: aceZoneId u16, cwZoneId u16, progress u8, flags u8)
--   0x2C-0x4F Pool B (same shape)
--   0x50-0x53 HVNM (zoneId u16, progress u8, flags u8)
------------------------------------------------------------
ashita.events.register('packet_in', 'pf_venture_info_cb', function(e)
    if (e.id ~= 0x1A3) then return; end
    e.blocked = true;
    if (e.size < 0x54) then
        devlog('Venture packet too small: %d bytes', e.size);
        return;
    end

    ventureState.version  = struct.unpack('B', e.data_modified, 0x04 + 1);
    ventureState.gameMode = struct.unpack('B', e.data_modified, 0x05 + 1);

    local poolKeys = { 'a', 'b' };
    for poolIdx, poolKey in ipairs(poolKeys) do
        local baseOffset = 0x08 + (poolIdx - 1) * 0x24;
        for tier = 1, 6 do
            local off = baseOffset + (tier - 1) * 6;
            local flags = struct.unpack('B', e.data_modified, off + 5 + 1);
            ventureState.pools[poolKey][tier] = {
                aceZoneId = struct.unpack('H', e.data_modified, off + 0 + 1),
                cwZoneId  = struct.unpack('H', e.data_modified, off + 2 + 1),
                progress  = struct.unpack('B', e.data_modified, off + 4 + 1),
                starBonus = bit.band(flags, 0x01) ~= 0,
            };
        end
    end

    local hvnmFlags = struct.unpack('B', e.data_modified, 0x53 + 1);
    local hvnmProg  = struct.unpack('B', e.data_modified, 0x52 + 1);
    ventureState.hvnm = {
        zoneId      = struct.unpack('H', e.data_modified, 0x50 + 1),
        progress    = hvnmProg,
        maxProgress = 200,
        starBonus   = bit.band(hvnmFlags, 0x01) ~= 0,
        spawned     = hvnmProg >= 200,
    };

    ventureState.lastReceived = os.time();
end);

ashita.events.register('packet_in', 'pf_invite_accept_cb', function(e)
    -- Packet: Party Invite Request (0x00DC)
    if (e.id ~= 0x00DC) then return; end

    -- Play sound on any party invite if registered as LFG (alert tabbed-out players)
    if (isRegistered and ui.registeredListingType == 1) then
        ui.playSound('join_request');
    end

    if (pendingJoinTarget == nil) then return; end

    -- Extract inviter name
    local inviter = struct.unpack('c16', e.data_modified, 0x0C + 1);
    inviter = inviter:gsub('%z', '');

    devlog('Party invite from %s (pending target: %s)', inviter, pendingJoinTarget);

    -- Check if this invite is from the leader we sent a join request to
    if (inviter:lower() == pendingJoinTarget) then
        e.blocked = true; -- block the invite dialog

        -- Auto-accept by sending packet 0x74
        local packet = { 0x74, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
        AshitaCore:GetPacketManager():AddOutgoingPacket(0x74, packet);

        pfprint(string.format('Auto-accepted party invite from %s', inviter));
        devlog('Auto-accepted invite from %s', inviter);

        -- Clear pending state
        pendingJoinTarget = nil;
    end
end);

-- Mute LFM chat announcements when notifications are disabled.
-- Refresh is now handled by S2C_LISTINGS_CHANGED packet, not chat messages.
ashita.events.register('text_in', 'pf_tell_block_cb', function(e)
    -- Check both fields. customcolors runs as a text_in handler too and
    -- may have rewritten e.message_modified with color-code bytes
    -- interspersed. Use literal-substring searches so stray color bytes
    -- between characters don't defeat the match.
    local msg = e.message_modified or e.message or '';
    local raw = e.message or '';

    -- Both filters below target ONLY the server-broadcast LFM announcement
    -- ("X is looking for members: ..."). Addon-local pfprint() messages
    -- (registration confirmations, errors, tutorial output, etc.) share
    -- the [PartyFinder] prefix but must NEVER be filtered by mode or mute -
    -- doing so caused CW players to see no confirmation when registering
    -- because their own pfprint messages lack the [CW] tag.
    local isLFMBroadcast = string.find(msg, 'is looking for members', 1, true)
                        or string.find(raw, 'is looking for members', 1, true);
    if (not isLFMBroadcast) then return; end

    -- Mute toggle suppresses LFM announcements.
    if (not lfmNotifications) then
        e.blocked = true;
        return;
    end

    -- Cross-mode filter: server tags CW broadcasts with "[CW]" between
    -- the [PartyFinder] prefix and the player name. Suppress incompatible-
    -- mode notifications (CW only with CW; ACE+WEW with each other).
    -- Fail open when ui.myGameMode is nil (END packet hasn't arrived yet).
    if (ui.myGameMode ~= nil) then
        local hasCWTag = string.find(msg, '[CW]', 1, true)
                      or string.find(raw, '[CW]', 1, true);
        if (ui.myGameMode == 1 and not hasCWTag) then
            -- I'm CW; this is an ACE/WEW broadcast.
            e.blocked = true;
            return;
        end
        if (ui.myGameMode ~= 1 and hasCWTag) then
            -- I'm ACE/WEW; this is a CW broadcast.
            e.blocked = true;
            return;
        end
    end
end);

------------------------------------------------------------
-- Events: Incoming packets (S2C)
------------------------------------------------------------
ashita.events.register('packet_in', 'pf_packet_in_cb', function(e)
    if (e.id ~= PACKET_ID) then return; end

    -- Block the packet from reaching the game client (it doesn't know this ID)
    e.blocked = true;

    -- Server responded -> clear pending ping, mark available
    pingPendingSince = nil;
    pingRetryCount   = 0;
    serverDisabled   = false;

    local action = struct.unpack('B', e.data_modified, 0x04 + 1);

    devlog('S2C <- action=%d size=%d', action, e.size);

    if (action == S2C.CLEAR) then
        ui.pendingEntries      = T{};
        ui.pendingPartyMembers = {};
        devlog('  Clear list (pending)');
        return;
    end

    if (action == S2C.ENTRY) then
        local category  = struct.unpack('B', e.data_modified, 0x05 + 1);
        local job       = struct.unpack('B', e.data_modified, 0x06 + 1);
        local level     = struct.unpack('B', e.data_modified, 0x07 + 1);
        local zoneId    = struct.unpack('H', e.data_modified, 0x08 + 1);
        local contentId = struct.unpack('H', e.data_modified, 0x0A + 1);
        local charId    = struct.unpack('L', e.data_modified, 0x0C + 1);

        -- Read name (16 bytes at 0x10)
        local name = struct.unpack('c16', e.data_modified, 0x10 + 1);
        name = name:gsub('%z', ''); -- strip null bytes

        -- Read comment (64 bytes at 0x20)
        local entryComment = struct.unpack('c64', e.data_modified, 0x20 + 1);
        entryComment = entryComment:gsub('%z', ''); -- strip null bytes

        -- Read extended fields
        local entryRole        = struct.unpack('B', e.data_modified, 0x60 + 1);
        local entryListingType = struct.unpack('B', e.data_modified, 0x61 + 1);
        local entryPartySize   = struct.unpack('B', e.data_modified, 0x62 + 1);
        local entryAutoAccept  = struct.unpack('B', e.data_modified, 0x63 + 1);
        local entryMinLevel    = struct.unpack('B', e.data_modified, 0x64 + 1);
        local entrySubJob      = struct.unpack('B', e.data_modified, 0x65 + 1);
        local entrySubLevel    = struct.unpack('B', e.data_modified, 0x66 + 1);
        local entryGameMode    = struct.unpack('B', e.data_modified, 0x67 + 1);
        local entryTanks       = struct.unpack('B', e.data_modified, 0x68 + 1);
        local entryHealers     = struct.unpack('B', e.data_modified, 0x69 + 1);
        local entrySupports    = struct.unpack('B', e.data_modified, 0x6A + 1);
        local entryDPS         = struct.unpack('B', e.data_modified, 0x6B + 1);

        local target = ui.pendingEntries or entries;
        local dupeIndex = nil;
        for idx, existing in ipairs(target) do
            if (existing.charId == charId) then
                dupeIndex = idx;
                break;
            end
        end
        local entryRecord = {
            name         = name,
            job          = job,
            level        = level,
            subJob       = entrySubJob,
            subLevel     = entrySubLevel,
            gameMode     = entryGameMode,
            zoneId       = zoneId,
            category     = category,
            contentId    = contentId,
            charId       = charId,
            comment      = entryComment,
            role         = entryRole,
            listingType  = entryListingType,
            partySize    = entryPartySize,
            autoAccept   = entryAutoAccept,
            minLevel     = entryMinLevel,
            tankCount    = entryTanks,
            healerCount  = entryHealers,
            supportCount = entrySupports,
            dpsCount     = entryDPS,
        };
        if (dupeIndex ~= nil) then
            target[dupeIndex] = entryRecord;
            devlog('  Entry dedup: replaced existing charId=%d at idx=%d', charId, dupeIndex);
        else
            target:append(entryRecord);
        end

        local typeStr = entryListingType == 2 and 'LFM' or 'LFG';
        local autoStr = entryAutoAccept == 1 and ' [AUTO]' or '';
        devlog('  Entry: %s %s%d %s(%d)%s', name, JOB_ABBR[job] or '?', level, typeStr, entryPartySize, autoStr);
        return;
    end

    if (action == S2C.END_LIST) then
        if (ui.pendingEntries ~= nil) then
            entries        = ui.pendingEntries;
            partyMembers   = ui.pendingPartyMembers or {};
            ui.pendingEntries      = nil;
            ui.pendingPartyMembers = nil;
            selectedIndex = 0;
        end

        -- Read player's PFP, daily count, and game mode from the END packet
        local ok_pfp, myPfp = pcall(function() return struct.unpack('L', e.data_modified, 0x08 + 1); end);
        local ok_daily, myDaily = pcall(function() return struct.unpack('B', e.data_modified, 0x0C + 1); end);
        local ok_mode, myMode = pcall(function() return struct.unpack('B', e.data_modified, 0x0D + 1); end);
        if (ok_pfp) then ui.myPFP = myPfp; end
        if (ok_daily) then ui.myDailyCount = myDaily; end
        if (ok_mode) then ui.myGameMode = myMode; end

        -- Sync isRegistered from the listing data: if our name appears in the
        -- entries, we're registered on the server even if the addon missed the
        -- original ACK (e.g. addon reloaded while already registered).
        local myName = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
        local foundSelf = false;
        for _, ent in ipairs(entries) do
            if (ent.name == myName) then
                foundSelf = true;
                -- Restore registration state from the listing
                if (not isRegistered) then
                    isRegistered = true;
                    ui.registeredListingType = ent.listingType or 1;
                    ui.registeredCategory    = ent.category or 0;
                    ui.registeredAutoAccept  = (ent.autoAccept or 0) == 1;
                    ui.registeredMinLevel    = ent.minLevel or 0;
                    devlog('  Restored isRegistered from listing (type=%d)', ui.registeredListingType);
                end
                break;
            end
        end
        if (not foundSelf and isRegistered) then
            -- We thought we were registered but we're not in the list anymore
            isRegistered = false;
            devlog('  Cleared stale isRegistered (not found in listing)');
        end

        -- Login summary: show LFG/LFM counts once on first login (not zone changes)
        if (not hasShownLoginSummary and lfmNotifications) then
            hasShownLoginSummary = true;
            local lfgCount = 0;
            local lfmCount = 0;
            for _, ent in ipairs(entries) do
                if ((ent.listingType or 1) == 1) then
                    lfgCount = lfgCount + 1;
                else
                    lfmCount = lfmCount + 1;
                end
            end
            if (lfgCount > 0 or lfmCount > 0) then
                pfprint(string.format('%d player%s looking for group, %d group%s recruiting. Press Ctrl+%s to open.',
                    lfgCount, lfgCount == 1 and '' or 's',
                    lfmCount, lfmCount == 1 and '' or 's',
                    keybind:gsub('%^', '')));
            end
        end

        devlog('  End of list (%d entries) PFP=%d daily=%d/3 mode=%d', #entries, ui.myPFP or 0, ui.myDailyCount or 0, ui.myGameMode or 0);
        return;
    end

    if (action == S2C.ACK_REGISTER) then
        isRegistered = true;
        -- Save registration settings so the JOIN_REQUEST handler can check them
        ui.registeredListingType = ui.selectedListingType or 1;
        ui.registeredCategory    = CATEGORIES[(ui.selectedCat or 0) + 1] and CATEGORIES[(ui.selectedCat or 0) + 1].id or 0;
        ui.registeredAutoAccept  = (ui.autoAccept and ui.autoAccept[1]) or false;
        ui.registeredMinLevel    = (ui.minLevel and ui.minLevel[1]) or 0;
        devlog('  Ack: Registered (type=%d auto=%s minlvl=%d)',
            ui.registeredListingType,
            ui.registeredAutoAccept and 'ON' or 'OFF',
            ui.registeredMinLevel);
        local typeStr = ui.registeredListingType == 2 and 'LFM' or 'LFG';
        local autoStr = ui.registeredAutoAccept and ', Auto-Accept' or '';
        logActivity('Registered as %s (%s%s)', typeStr, CATEGORY_NAMES[ui.selectedCat] or 'General', autoStr);
        pfprint('You are now registered.');
        -- Auto-switch to the opposite tab so you see what you're looking for
        ui.activeTab = (ui.registeredListingType == 2) and 1 or 2;
        ui.tabSwitchFrames = 3;
        devlog('  Tab switch -> %d', ui.activeTab);
        requestRefresh();
        return;
    end

    if (action == S2C.ACK_WITHDRAW) then
        isRegistered = false;
        ui.registeredListingType = nil;
        ui.registeredCategory    = nil;
        ui.registeredAutoAccept  = false;
        ui.registeredMinLevel    = 0;
        devlog('  Ack: Withdrawn');
        logActivity('Registration withdrawn');
        pfprint('Registration withdrawn.');
        requestRefresh();
        return;
    end

    -- ---- Handle ROULETTE_DUTY: server picked a duty (roulette or mission) ----
    if (action == S2C.ROULETTE_DUTY) then
        local tier       = struct.unpack('B', e.data_modified, 0x05 + 1);
        local levelCap   = struct.unpack('B', e.data_modified, 0x06 + 1);
        local dutySource = struct.unpack('B', e.data_modified, 0x07 + 1); -- 0=roulette, 1=mission
        local dutyId     = struct.unpack('H', e.data_modified, 0x08 + 1);
        local dutyZone   = struct.unpack('H', e.data_modified, 0x0A + 1);
        local pSize      = struct.unpack('B', e.data_modified, 0x0C + 1);
        local isFollower = struct.unpack('B', e.data_modified, 0x0D + 1) == 1;
        local dutyName   = struct.unpack('c48', e.data_modified, 0x10 + 1);
        dutyName = dutyName:gsub('%z', '');

        local isMission = (dutySource == 1);

        -- Follower path: server-broadcast ready check
        if (isFollower) then
            -- Dedup: ignore re-broadcasts of the same duty
            if (roulette.active and roulette.dutyId == dutyId) then
                devlog('  ROULETTE_DUTY (follower) dedup: already active for dutyId=%d', dutyId);
                return;
            end

            local leaderName = struct.unpack('c16', e.data_modified, 0x40 + 1);
            leaderName = leaderName:gsub('%z', '');

            roulette.active     = true;
            roulette.source     = isMission and 'mission' or 'roulette';
            roulette.isLeader   = false;
            roulette.myReady    = false;
            roulette.dutyName   = dutyName;
            roulette.dutyId     = dutyId;
            roulette.dutyZone   = dutyZone;
            roulette.dutyTier   = tier;
            roulette.dutyCap    = levelCap;
            roulette.readyCount = 0;
            roulette.totalCount = 0;
            roulette.timeout    = os.time() + 60;
            roulette.leaderName = (leaderName ~= '') and leaderName or 'Leader';

            local label = isMission and 'Mission Help' or 'Duty Roulette';
            logActivity('%s from %s: %s', label, roulette.leaderName, dutyName);
            pfprint(string.format('%s started %s: %s', roulette.leaderName, label, dutyName));
            ui.playSound('roulette_roll');
            devlog('ROULETTE_DUTY (follower) <- %s id=%d src=%s', roulette.leaderName, dutyId, roulette.source);
            return;
        end

        -- Leader path: we rolled the roulette
        -- Dedup: if we already initiated this same duty, skip
        if (roulette.active and roulette.isLeader and roulette.dutyId == dutyId) then
            devlog('  ROULETTE_DUTY (leader) dedup: already active for dutyId=%d', dutyId);
            return;
        end

        roulette.active     = true;
        roulette.source     = isMission and 'mission' or 'roulette';
        roulette.isLeader   = true;
        roulette.myReady    = true;
        roulette.dutyName   = dutyName;
        roulette.dutyId     = dutyId;
        roulette.dutyZone   = dutyZone;
        roulette.dutyTier   = tier;
        roulette.dutyCap    = levelCap;
        roulette.readyCheck = T{};
        roulette.readyCount = 1; -- leader counts as ready
        roulette.timeout    = os.time() + 60;
        roulette.leaderName = nil;

        -- Use server-provided party size (client memory can be stale)
        roulette.totalCount = pSize;
        roulette.partySize  = pSize;

        local label = isMission and 'Mission Help' or 'Duty Roulette';
        logActivity('%s: %s (Lv%d cap)', label, dutyName, levelCap);
        pfprint(string.format('%s: %s (Level %d cap)', label, dutyName, levelCap));
        ui.playSound('roulette_roll');

        -- Server pushes ROULETTE_DUTY (isFollower=1) to every other party member
        -- directly via the cexi admin gateway. No /tell broadcast needed.

        devlog('Roulette duty received: %s id=%d zone=%d tier=%d cap=%d members=%d', dutyName, dutyId, dutyZone, tier, levelCap, memberCount);
        return;
    end

    -- ---- Handle ROULETTE_ERR: error message ----
    if (action == S2C.ROULETTE_ERR) then
        local errMsg = struct.unpack('c56', e.data_modified, 0x08 + 1);
        errMsg = errMsg:gsub('%z', '');
        logActivity('Duty Roulette error: %s', errMsg);
        pfprint(errMsg);
        devlog('Roulette error: %s', errMsg);
        return;
    end

    -- ---- Handle ROULETTE_OK: teleporting ----
    if (action == S2C.ROULETTE_OK) then
        local label = (roulette.source == 'mission') and 'Mission Help' or 'Duty Roulette';
        activeDuty.name  = roulette.dutyName;
        activeDuty.phase = 1;
        roulette.active = false;
        logActivity('%s commenced! Teleporting...', label);
        pfprint(string.format('%s commenced! Teleporting to the battlefield...', label));
        ui.playSound('join_accepted');
        devlog('Roulette GO confirmed');
        return;
    end

    -- ---- Handle MISSION_ENTRY: eligible mission for selection ----
    if (action == S2C.MISSION_ENTRY) then
        local levelCap  = struct.unpack('B', e.data_modified, 0x06 + 1);
        local maxPlayers = struct.unpack('B', e.data_modified, 0x07 + 1);
        local dutyId    = struct.unpack('H', e.data_modified, 0x08 + 1);
        local dutyZone  = struct.unpack('H', e.data_modified, 0x0A + 1);
        local dutyName  = struct.unpack('c48', e.data_modified, 0x10 + 1);
        dutyName = dutyName:gsub('%z', '');

        missionSelect.entries:append({
            id         = dutyId,
            name       = dutyName,
            zone       = dutyZone,
            levelCap   = levelCap,
            maxPlayers = maxPlayers,
        });

        devlog('Mission entry: %s id=%d zone=%d cap=%d', dutyName, dutyId, dutyZone, levelCap);
        return;
    end

    -- ---- Handle MISSION_END: show selection popup ----
    if (action == S2C.MISSION_END) then
        missionSelect.active = true;
        logActivity('Select from %d eligible missions', #missionSelect.entries);
        devlog('Mission list complete: %d entries', #missionSelect.entries);
        return;
    end

    -- ---- Handle READY_UPDATE: a party member confirmed ready (leader only) ----
    if (action == S2C.READY_UPDATE) then
        if (not roulette.active or not roulette.isLeader) then
            devlog('  READY_UPDATE ignored (not active leader)');
            return;
        end
        local memberName = struct.unpack('c16', e.data_modified, 0x05 + 1);
        memberName = memberName:gsub('%z', '');
        if (memberName == '') then return; end

        -- Dedup by lowercase name in case the packet arrives twice
        local key = memberName:lower();
        if (not roulette.readyCheck[key]) then
            roulette.readyCheck[key] = true;
            roulette.readyCount = roulette.readyCount + 1;
            logActivity('%s is ready', memberName);
            pfprint(string.format('%s is ready! (%d/%d)',
                memberName, roulette.readyCount, roulette.totalCount));
            devlog('READY_UPDATE <- %s (%d/%d)', memberName, roulette.readyCount, roulette.totalCount);
        end
        return;
    end

    -- ---- Handle JOIN_REQUEST: someone wants to join our LFM party (leader) ----
    -- Server-validated job/level — addon no longer trusts requester-supplied
    -- values. Layout: 0x05 job, 0x06 level, 0x07 role, 0x08 requester name (16).
    if (action == S2C.JOIN_REQUEST) then
        local reqJob   = struct.unpack('B', e.data_modified, 0x05 + 1);
        local reqLevel = struct.unpack('B', e.data_modified, 0x06 + 1);
        local reqRole  = struct.unpack('B', e.data_modified, 0x07 + 1);
        local sender   = struct.unpack('c16', e.data_modified, 0x08 + 1);
        sender = sender:gsub('%z', '');
        if (sender == '') then return; end

        local reqJobName  = JOB_ABBR[reqJob] or '???';
        local reqRoleName = ROLE_NAMES[reqRole] or 'Any';

        devlog('JOIN_REQUEST <- %s - %s%d (%s)', sender, reqJobName, reqLevel, reqRoleName);
        devlog('  Check: isReg=%s type=%s auto=%s minlvl=%s',
            tostring(isRegistered),
            tostring(ui.registeredListingType),
            tostring(ui.registeredAutoAccept),
            tostring(ui.registeredMinLevel));

        -- Blacklist
        if (blacklist[sender:lower()]) then
            sendJoinRespond(sender, false, 2, 'You are blocked.');
            devlog('JOIN_REQUEST from %s BLOCKED (blacklisted)', sender);
            return;
        end

        -- Auto-accept path: registered as LFM with auto-accept enabled
        if (isRegistered and ui.registeredListingType == 2 and ui.registeredAutoAccept) then
            local minLvl = ui.registeredMinLevel or 0;

            -- Level requirement
            if (minLvl > 0 and reqLevel < minLvl) then
                local denyMsg = string.format('Level too low (minimum: %d)', minLvl);
                sendJoinRespond(sender, false, 1, denyMsg);
                logActivity('Denied %s (%s%d): level below minimum %d', sender, reqJobName, reqLevel, minLvl);
                pfprint(string.format('Denied %s: level %d below minimum %d', sender, reqLevel, minLvl));
                return;
            end

            sendJoinRespond(sender, true, 0, '');
            devlog('JOIN_RESPOND ACCEPT -> %s', sender);

            logActivity('%s (%s%d, %s) auto-joined your party', sender, reqJobName, reqLevel, reqRoleName);
            pfprint(string.format('%s (%s%d, %s) joined via Party Finder', sender, reqJobName, reqLevel, reqRoleName));
            ui.playSound('join_accepted');
        else
            -- Manual: queue as incoming request for the user to accept/deny via UI
            addIncomingRequest(sender, reqJob, reqLevel, reqRole);
            logActivity('%s (%s%d, %s) requested to join', sender, reqJobName, reqLevel, reqRoleName);
            pfprint(string.format('%s (%s%d, %s) wants to join your party.', sender, reqJobName, reqLevel, reqRoleName));
            ui.playSound('join_request');
        end
        return;
    end

    -- ---- Handle JOIN_RESULT: leader accepted/denied our request (requester) ----
    -- Layout: 0x05 result (0=deny,1=accept), 0x06 reason (0 generic, 1 lvl,
    -- 2 blacklist, 3 other), 0x08 leader name (16), 0x18 message (48).
    if (action == S2C.JOIN_RESULT) then
        local result  = struct.unpack('B', e.data_modified, 0x05 + 1);
        local reason  = struct.unpack('B', e.data_modified, 0x06 + 1);
        local leader  = struct.unpack('c16', e.data_modified, 0x08 + 1);
        leader = leader:gsub('%z', '');
        local message = struct.unpack('c48', e.data_modified, 0x18 + 1);
        message = message:gsub('%z', '');

        if (result == 1) then
            logActivity('%s accepted your join request', leader);
            pfprint(string.format('%s accepted your join request!', leader));
            devlog('JOIN_RESULT ACCEPT <- %s', leader);
            -- Don't clear pendingJoinTarget here — pf_invite_accept_cb needs
            -- it set so the actual party invite gets auto-accepted. The S2C
            -- packet may arrive before the 0x00DC invite, so clearing here
            -- would race the auto-accept and break the join flow.
        else
            local reasonText = (message ~= '' and message) or 'No reason given';
            logActivity('%s denied your request: %s', leader, reasonText);
            pfprint(string.format('%s denied your request: %s', leader, reasonText));
            devlog('JOIN_RESULT DENY <- %s (reason=%d %s)', leader, reason, reasonText);
            pendingJoinTarget = nil;
        end
        return;
    end

    -- ---- Handle DUTY_DECLINE: a follower declined the duty (leader) ----
    -- Layout: 0x05 member name (16).
    if (action == S2C.DUTY_DECLINE) then
        local member = struct.unpack('c16', e.data_modified, 0x05 + 1);
        member = member:gsub('%z', '');
        if (member == '') then return; end

        if (roulette.active and roulette.isLeader) then
            local label = (roulette.source == 'mission') and 'Mission Help' or 'Duty Roulette';
            roulette.active = false;
            logActivity('%s declined %s', member, label);
            pfprint(string.format('%s declined. %s cancelled.', member, label));
            devlog('DUTY_DECLINE <- %s', member);
        end
        return;
    end

    if (action == S2C.LISTINGS_CHANGED) then
        requestRefresh();
        devlog('LISTINGS_CHANGED <- refreshing');
        return;
    end

    if (action == S2C.PARTY_MEMBER) then
        local memberJob   = struct.unpack('B', e.data_modified, 0x05 + 1);
        local memberLevel = struct.unpack('B', e.data_modified, 0x06 + 1);
        local memberSub   = struct.unpack('B', e.data_modified, 0x07 + 1);
        local memberSubLv = struct.unpack('B', e.data_modified, 0x08 + 1);
        local leaderCharId = struct.unpack('L', e.data_modified, 0x0C + 1);
        local memberName  = struct.unpack('c16', e.data_modified, 0x10 + 1);
        memberName = memberName:gsub('%z', '');

        local pmTarget = ui.pendingPartyMembers or partyMembers;
        if (not pmTarget[leaderCharId]) then
            pmTarget[leaderCharId] = {};
        end
        table.insert(pmTarget[leaderCharId], {
            name    = memberName,
            job     = memberJob,
            level   = memberLevel,
            subJob  = memberSub,
            subLevel = memberSubLv,
        });
        devlog('  Party member: %s %s%d for leader %d', memberName, JOB_ABBR[memberJob] or '?', memberLevel, leaderCharId);
        return;
    end

    devlog('  Unknown action: %d', action);
end);

------------------------------------------------------------
-- Events: Zone in / logout
------------------------------------------------------------
ashita.events.register('packet_in', 'pf_zone_cb', function(e)
    if (e.id == 0x000A) then
        -- Dismiss roulette popup on zone-in (we teleported to duty zone)
        if (roulette.active) then
            -- Activate the compact duty frame for all party members (not just leader)
            if (activeDuty.phase == 0) then
                activeDuty.name  = roulette.dutyName;
                activeDuty.phase = 1;
            end
            roulette.active = false;
            logActivity('Arrived at duty zone');
        end

        -- Track active duty phase
        if (activeDuty.phase == 1) then
            activeDuty.phase = 2; -- arrived at BF zone
        elseif (activeDuty.phase == 2) then
            activeDuty.phase = 0; -- returned from BF
            activeDuty.name  = '';
            logActivity('Duty complete');
        end

        -- Zone in: restore prior open state and refresh
        ashita.tasks.oncef(3, function()
            ui.hasZonedIn = true;
            if (ui.wasOpenBeforeZone ~= false) then
                ui.isOpen[1] = true;
            end
            requestRefresh();
        end);
    end

    -- Logout/zone-out: hide PF during zoning and on logout
    if (e.id == 0x000B) then
        local logoutState = struct.unpack('B', e.data_modified, 0x04 + 1);
        ui.wasOpenBeforeZone = ui.isOpen[1];
        ui.isOpen[1] = false;
        -- Drop any in-flight ping so the post-zone-in refresh starts fresh
        pingPendingSince = nil;
        serverDisabled   = false;
        -- Close any transient sub-windows so they don't reappear on zone-in
        isCommentWindowOpen   = false;
        isTellWindowOpen      = false;
        isConfirmJoinOpen     = false;
        confirmJoinEntry      = nil;
        isConfirmWithdrawOpen = false;
        settingsBuf.isOpen        = false;
        missionSelect.active  = false;
        if (logoutState ~= 2) then -- not a zone change — full logout
            ui.hasZonedIn = false;
            activeDuty.phase = 0;
            activeDuty.name  = '';
        end
    end
end);

------------------------------------------------------------
-- Events: Render
------------------------------------------------------------
ashita.events.register('d3d_present', 'pf_render_cb', function()
    -- Auto-refresh while window is open (full or mini mode — mini badge counts need it too)
    if (ui.isOpen[1]) then
        local now = os.time();
        if (now - lastRefreshTime >= autoRefreshInterval) then
            lastRefreshTime = now;
            requestRefresh();
        end
    end

    renderMain();
end);
