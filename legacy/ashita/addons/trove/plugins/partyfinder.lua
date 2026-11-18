--[[
* trove/plugins/partyfinder.lua — Party Finder
*
* Browse LFG/LFM listings, register, join parties, duty roulette,
* mission help, and ventures. Phase 1: feature parity with standalone addon.
*
* Uses packet 0x1A2 (separate from Trove's 0x1A4).
* Job icons rendered via AF headpiece item textures (no pixel art IP).
*
* Command: /trove pf
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;
local renderTooltip = nil;
local renderFileIcon  = nil;
local renderFileImage = nil;

------------------------------------------------------------
-- Config persistence
------------------------------------------------------------
local function getConfigPath()
    return string.format('%sconfig\\addons\\trove\\pf_settings.lua', AshitaCore:GetInstallPath());
end

local function savePfConfig()
    local dir = string.format('%sconfig\\addons\\trove\\', AshitaCore:GetInstallPath());
    os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"');
    local f = io.open(getConfigPath(), 'w');
    if f then
        f:write('return {\n');
        f:write(string.format('    showHud = %s,\n', tostring(pfSettings.showHud)));
        f:write(string.format('    openOnLogin = %s,\n', tostring(pfSettings.openOnLogin)));
        f:write(string.format('    hudBackground = %s,\n', tostring(pfSettings.hudBackground)));
        f:write(string.format('    hudBgOpacity = %.2f,\n', pfSettings.hudBgOpacity));
        f:write(string.format('    showPartyButton = %s,\n', tostring(pfSettings.showPartyButton)));
        f:write(string.format('    lfmNotifications = %s,\n', tostring(pfSettings.lfmNotifications)));
        f:write(string.format('    tooltipsEnabled = %s,\n', tostring(pfSettings.tooltipsEnabled)));
        f:write('};\n');
        f:close();
    end
end

local function loadPfConfig()
    local fn = loadfile(getConfigPath());
    if fn then
        local ok, result = pcall(fn);
        if ok and type(result) == 'table' then
            if result.showHud ~= nil then pfSettings.showHud = result.showHud; end
            if result.openOnLogin ~= nil then pfSettings.openOnLogin = result.openOnLogin; end
            if result.hudBackground ~= nil then pfSettings.hudBackground = result.hudBackground; end
            if result.hudBgOpacity ~= nil then pfSettings.hudBgOpacity = result.hudBgOpacity; end
            if result.showPartyButton ~= nil then pfSettings.showPartyButton = result.showPartyButton; end
            if result.lfmNotifications ~= nil then pfSettings.lfmNotifications = result.lfmNotifications; end
            if result.tooltipsEnabled ~= nil then pfSettings.tooltipsEnabled = result.tooltipsEnabled; end
        end
    end
end

------------------------------------------------------------
-- Packet protocol (0x1A2)
------------------------------------------------------------
local PF_PACKET_ID = 0x1A2;

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
    CLEAR            = 0,
    ENTRY            = 1,
    END_LIST         = 2,
    ACK_REGISTER     = 3,
    ACK_WITHDRAW     = 4,
    ROULETTE_DUTY    = 5,
    ROULETTE_ERR     = 6,
    ROULETTE_OK      = 7,
    MISSION_ENTRY    = 8,
    MISSION_END      = 9,
    READY_UPDATE     = 10,
    JOIN_REQUEST     = 11,
    JOIN_RESULT      = 12,
    DUTY_DECLINE     = 13,
    LISTINGS_CHANGED = 14,
    PARTY_MEMBER     = 15,
};

-- Venture info packet (separate from PF, server broadcast)
local VENTURE_PACKET_ID = 0x1A3;

------------------------------------------------------------
-- Categories, roles, jobs
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

local JOB_ABBR = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

-- AF headpiece item IDs for job icons (one per job, 1-22)
local JOB_ICON_ITEMS = {
    [1]  = 12511, -- WAR: Fighter's Mask
    [2]  = 12512, -- MNK: Temple Crown
    [3]  = 13855, -- WHM: Healer's Cap
    [4]  = 13856, -- BLM: Wizard's Petasos
    [5]  = 12513, -- RDM: Warlock's Chapeau
    [6]  = 12514, -- THF: Rogue's Bonnet
    [7]  = 12515, -- PLD: Gallant Coronet
    [8]  = 12516, -- DRK: Chaos Burgeonet
    [9]  = 12517, -- BST: Beast Helm
    [10] = 13857, -- BRD: Choral Roundlet
    [11] = 12518, -- RNG: Hunter's Beret
    [12] = 13868, -- SAM: Myochin Kabuto
    [13] = 13869, -- NIN: Ninja Hatsuburi
    [14] = 12519, -- DRG: Drachen Armet
    [15] = 12520, -- SMN: Evoker's Horn
    [16] = 11465, -- BLU: Mirage Keffiyeh
    [17] = 15266, -- COR: Corsair's Tricorne
    [18] = 11471, -- PUP: Pantin Taj
    [19] = 11478, -- DNC: Etoile Tiara
    [20] = 16140, -- SCH: Scholar's Mortarboard
    [21] = 27786, -- GEO: Geomancy Galero
    [22] = 27787, -- RUN: Runeist Bandeau
};

local ROLES = {
    { id = 0, name = 'Any',     color = { 0.70, 0.70, 0.70, 1.0 } },
    { id = 1, name = 'Tank',    color = { 0.30, 0.50, 1.00, 1.0 } },
    { id = 2, name = 'Healer',  color = { 0.40, 1.00, 0.40, 1.0 } },
    { id = 3, name = 'Support', color = { 1.00, 0.80, 0.30, 1.0 } },
    { id = 4, name = 'DPS',     color = { 1.00, 0.35, 0.35, 1.0 } },
};

local ROLE_NAMES = {};
for _, r in ipairs(ROLES) do
    ROLE_NAMES[r.id] = r.name;
end

local MODE_NAMES = { [0] = 'ACE', [1] = 'CW', [2] = 'WEW' };

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen           = { false };
local entries          = {};
local partyMembers     = {};  -- [charId] = { {name, job, level, subJob, subLevel}, ... }
local pendingEntries   = nil;
local pendingMembers   = nil;
local isRegistered     = false;
local selectedIndex    = 0;
local activeTab        = 1;   -- 1=LFG, 2=LFM, 3=Activity

-- Registration state
local regListingType   = nil; -- 1=LFG, 2=LFM
local regCategory      = nil;
local regAutoAccept    = false;
local regMinLevel      = 0;

-- Player info from END_LIST packet
local myPFP            = 0;
local myDailyCount     = 0;
local myGameMode       = nil;

-- Server availability
local pingPendingSince = nil;
local pingRetryCount   = 0;
local PF_PING_TIMEOUT  = 6;
local PF_PING_RETRIES  = 3;
local serverDisabled   = false;

-- Activity log
local activityLog      = {};
local ACTIVITY_LOG_MAX = 100;

-- Join request state
local pendingJoinTarget  = nil;  -- lowercase name of leader we sent join to
local incomingRequests   = {};   -- for leaders: pending requests to accept/deny
local REQUEST_TTL        = 60;

-- Roulette / duty state
local roulette = {
    active     = false,
    source     = 'roulette',
    isLeader   = false,
    myReady    = false,
    dutyName   = '',
    dutyId     = 0,
    dutyZone   = 0,
    dutyTier   = 0,
    dutyCap    = 0,
    partySize  = 0,
    readyCheck = {},
    readyCount = 0,
    totalCount = 0,
    timeout    = 0,
    leaderName = nil,
};

local activeDuty = {
    name  = '',
    phase = 0,  -- 0=none, 1=teleporting, 2=in BF
};

local missionSelect = {
    active  = false,
    entries = {},
};

-- Venture state (from 0x1A3 packets)
local ventureState = {
    lastReceived = 0,
    version      = 0,
    gameMode     = 0,
    pools = { a = {}, b = {} },
    hvnm = { zoneId = 0, progress = 0, maxProgress = 200, starBonus = false, spawned = false },
};

-- UI input buffers
local commentBuf     = { '' };
local selectedCat    = 0;       -- category filter (0=All)
local selectedRole   = 0;
local selectedType   = 1;       -- 1=LFG, 2=LFM
local autoAcceptBuf  = { false };
local minLevelBuf    = { 0 };

-- Settings (persisted via settings.lua)
local pfSettings = {
    lfmNotifications = true,
    tooltipsEnabled  = true,
    confirmWithdraw  = true,
    joinableOnly     = true,
    showHud          = false,
    openOnLogin      = false,
    hudBackground    = false,
    hudBgOpacity     = 0.4,
    showPartyButton  = true,
    blacklist        = {},
};

local isPfSettingsOpen = false;
local loginAutoOpenDone = false;
local pfWindowOpen = { false };

-- Refresh state
local lastRefreshTime     = 0;
local autoRefreshInterval = 60;
local hasShownLoginSummary = false;

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function pfprint(msg)
    AshitaCore:GetChatManager():AddChatMessage(29, false, '[PartyFinder] ' .. msg);
end

local function getZoneName(zoneId)
    local zone = AshitaCore:GetResourceManager():GetString('zones.names', zoneId);
    if not zone or zone == '' then
        return string.format('Zone %d', zoneId);
    end
    return zone;
end

local function getMyName()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
end

local function getMyInfo()
    local p = AshitaCore:GetMemoryManager():GetPlayer();
    return p:GetMainJob(), p:GetMainJobLevel(), JOB_ABBR[p:GetMainJob()] or '???';
end

local function isPartyLeaderOrSolo()
    local ok, result = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty();
        local mySid = party:GetMemberServerId(0);
        local others = 0;
        for i = 1, 5 do
            local sid  = party:GetMemberServerId(i);
            local name = party:GetMemberName(i);
            local mJob = party:GetMemberMainJob(i);
            if sid and sid > 0 and sid ~= mySid
                and name and name ~= ''
                and mJob and mJob > 0 then
                others = others + 1;
            end
        end
        if others == 0 then return true; end
        return mySid == party:GetAlliancePartyLeaderServerId(0);
    end);
    return not ok or result;
end

local function isGameModeCompatible(a, b)
    if a == nil or b == nil then return true; end
    if a == 1 or b == 1 then return a == b; end
    return true;
end

local function isHiddenByFilter(entry)
    -- Game mode filtering always applies (CW only sees CW, non-CW never sees CW)
    local badMode = myGameMode ~= nil and entry.gameMode ~= nil
        and not isGameModeCompatible(myGameMode, entry.gameMode);
    if badMode then return true; end

    -- Full party filter is optional
    if pfSettings and pfSettings.joinableOnly ~= false then
        local isFull = (entry.listingType or 1) == 2
            and entry.partySize and entry.partySize >= 6;
        if isFull then return true; end
    end

    return false;
end

local function logActivity(fmt, ...)
    local msg = string.format(fmt, ...);
    table.insert(activityLog, { time = os.date('%H:%M'), text = msg });
    while #activityLog > ACTIVITY_LOG_MAX do
        table.remove(activityLog, 1);
    end
end

local function getCategoryColor(catId)
    for _, cat in ipairs(CATEGORIES) do
        if cat.id == catId then return cat.color; end
    end
    return { 0.8, 0.8, 0.8, 1.0 };
end

------------------------------------------------------------
-- Drawing helpers
------------------------------------------------------------
local function drawJobIcon(jobId, size)
    size = size or 24;
    local itemId = JOB_ICON_ITEMS[jobId];
    if itemId and renderIcon then
        if not renderIcon(itemId, size) then
            imgui.Dummy({ size, size });
        end
    else
        imgui.Dummy({ size, size });
    end
end

------------------------------------------------------------
-- Packet send helpers
------------------------------------------------------------
local function makePacket(action)
    local p = {};
    p[1] = 0xA2;
    p[2] = 0x24; -- size = 0x48 (72 bytes)
    p[3] = 0x00;
    p[4] = 0x00;
    p[5] = action;
    for i = 6, 72 do p[i] = 0; end
    return p;
end

local function writeStringAt(packet, offset, str, maxLen)
    for i = 1, maxLen do
        local c = str:byte(i);
        packet[offset + i] = c or 0;
    end
end

local function sendC2S(action, category, contentId, role, listingType, autoAccept, minLevel, commentStr)
    category    = category or 0;
    contentId   = contentId or 0;
    role        = role or 0;
    listingType = listingType or 1;
    autoAccept  = autoAccept or 0;
    minLevel    = minLevel or 0;
    commentStr  = commentStr or '';

    local p = makePacket(action);
    p[6]  = category;
    p[7]  = bit.band(contentId, 0xFF);
    p[8]  = bit.rshift(contentId, 8);
    p[9]  = role;
    p[10] = listingType;
    p[11] = autoAccept;
    p[12] = minLevel;
    for i = 1, 60 do
        local c = commentStr:byte(i);
        p[12 + i] = c or 0;
    end
    AshitaCore:GetPacketManager():AddOutgoingPacket(PF_PACKET_ID, p);
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

local function requestRouletteRoll(isReroll)
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

local function sendJoinRequestPacket(leaderName, role)
    local p = makePacket(C2S.JOIN_REQUEST);
    p[6] = role or 0;
    writeStringAt(p, 8, leaderName, 16);
    AshitaCore:GetPacketManager():AddOutgoingPacket(PF_PACKET_ID, p);
end

local function sendJoinRespond(requesterName, accept, reason, message)
    local p = makePacket(C2S.JOIN_RESPOND);
    p[6] = accept and 1 or 0;
    p[7] = reason or 0;
    writeStringAt(p, 8, requesterName, 16);
    writeStringAt(p, 24, message or '', 48);
    AshitaCore:GetPacketManager():AddOutgoingPacket(PF_PACKET_ID, p);
end

local function sendDutyDecline()
    sendC2S(C2S.DUTY_DECLINE);
end

------------------------------------------------------------
-- Render: Entry card
------------------------------------------------------------
local function renderEntryCard(i, entry)
    local jobName  = JOB_ABBR[entry.job] or '???';
    local zoneName = getZoneName(entry.zoneId);
    local catColor = getCategoryColor(entry.category);
    local catName  = CATEGORY_NAMES[entry.category] or '???';
    local isLfm    = (entry.listingType or 1) == 2;
    local myName   = getMyName();
    local isSelf   = (entry.name == myName);

    local hasComment = entry.comment and entry.comment ~= '';
    local cardH = hasComment and 66 or 52;
    local base = ui.color('childBg');
    local bgColor = { base[1] + 0.02, base[2] + 0.02, base[3] + 0.04, 0.90 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(string.format('##pf_card_%d', i), { -1, cardH }, false);

    -- Category accent bar
    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + cardH }, imgui.GetColorU32(catColor));

    -- Selectable overlay
    imgui.SetCursorPosY(0);
    if imgui.Selectable(string.format('##pfsel_%d', i), selectedIndex == i,
        ImGuiSelectableFlags_SpanAllColumns, { 0, cardH }) then
        selectedIndex = i;
    end

    -- Double-click to join/invite
    if not isSelf and imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then
        if isLfm then
            if isGameModeCompatible(myGameMode, entry.gameMode) then
                sendJoinRequestPacket(entry.name, selectedRole);
                pendingJoinTarget = entry.name:lower();
                local _, lvl, jn = getMyInfo();
                pfprint(string.format('Join request sent to %s (%s%d)', entry.name, jn, lvl));
                logActivity('Sent join request to %s', entry.name);
            else
                pfprint('Cannot join: incompatible game mode.');
            end
        else
            if isPartyLeaderOrSolo() then
                AshitaCore:GetChatManager():QueueCommand(1, string.format('/pcmd add %s', entry.name));
                logActivity('Invited %s (%s%d)', entry.name, jobName, entry.level);
            end
        end
    end

    -- Hover tooltip
    if imgui.IsItemHovered() then
        imgui.BeginTooltip();
        if isSelf then
            imgui.Text('This is your listing');
        else
            -- Party composition for LFM
            local members = partyMembers[entry.charId];
            if isLfm and members and #members > 0 then
                imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 },
                    string.format('%s\'s Party (%d/6)', entry.name, #members));
                imgui.Separator();
                for _, m in ipairs(members) do
                    local js = string.format('%s%d', JOB_ABBR[m.job] or '???', m.level);
                    if m.subJob and m.subJob > 0 then
                        js = js .. string.format('/%s%d', JOB_ABBR[m.subJob] or '???', m.subLevel or 0);
                    end
                    drawJobIcon(m.job, 16);
                    imgui.SameLine(0, 4);
                    local nc = (m.name == entry.name) and { 1.0, 0.85, 0.4, 1.0 } or { 0.9, 0.9, 0.9, 1.0 };
                    imgui.TextColored(nc, m.name);
                    imgui.SameLine(140);
                    imgui.TextColored({ 0.6, 0.8, 0.6, 1.0 }, js);
                end
            end

            imgui.Spacing();
            if entry.comment and entry.comment ~= '' then
                imgui.TextColored({ 0.7, 0.7, 0.7, 1.0 }, entry.comment);
                imgui.Spacing();
            end
            local hint = isLfm and 'Double-click to join' or 'Double-click to invite';
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, hint);
        end
        imgui.EndTooltip();
    end

    -- Right-click context menu
    if imgui.BeginPopupContextItem(string.format('##pfctx_%d', i)) then
        selectedIndex = i;
        imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 }, entry.name);
        imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 },
            string.format('%s%d - %s', jobName, entry.level, zoneName));
        imgui.Separator();

        if not isSelf then
            if isLfm then
                local label = (entry.autoAccept or 0) == 1 and 'Join Party' or 'Request to Join';
                if imgui.MenuItem(label) then
                    sendJoinRequestPacket(entry.name, selectedRole);
                    pendingJoinTarget = entry.name:lower();
                    pfprint('Join request sent to ' .. entry.name);
                end
            else
                if imgui.MenuItem('Invite to Party') then
                    AshitaCore:GetChatManager():QueueCommand(1, '/pcmd add ' .. entry.name);
                end
            end
            imgui.Separator();
            if imgui.MenuItem('Send Tell') then
                AshitaCore:GetChatManager():QueueCommand(1, '/tell ' .. entry.name .. ' ');
            end
            if imgui.MenuItem('Search') then
                AshitaCore:GetChatManager():QueueCommand(1, '/sea all ' .. entry.name);
            end
            imgui.Separator();
            local blocked = pfSettings and pfSettings.blacklist[entry.name:lower()];
            if blocked then
                if imgui.MenuItem('Unblock') then
                    pfSettings.blacklist[entry.name:lower()] = nil;
                    ashitaSettings.save();
                    pfprint('Unblocked ' .. entry.name);
                end
            else
                if imgui.MenuItem('Block') then
                    pfSettings.blacklist[entry.name:lower()] = true;
                    ashitaSettings.save();
                    pfprint('Blocked ' .. entry.name);
                end
            end
        else
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, '(This is you)');
        end
        imgui.EndPopup();
    end

    -- Draw content over selectable
    imgui.SetCursorPos({ 8, 6 });

    -- CW icon (left of job icon)
    local isCW = (entry.gameMode == 1);
    local nameX = 44;
    if isCW and renderFileIcon then
        imgui.SetCursorPos({ 8, 10 });
        renderFileIcon('cw.png', 18);
        imgui.SameLine(0, 4);
        imgui.SetCursorPosY(6);
        nameX = 34;
    end

    drawJobIcon(entry.job, 28);
    imgui.SameLine(0, 6);

    -- Adjust nameX for CW offset
    if isCW then nameX = nameX + 28; end

    -- Name + job/level
    dl:AddText({ wx + nameX, wy + 6 }, imgui.GetColorU32({ 1.0, 0.95, 0.80, 1.0 }), entry.name);
    local subStr = '';
    if entry.subJob and entry.subJob > 0 then
        subStr = string.format('/%s%d', JOB_ABBR[entry.subJob] or '???', entry.subLevel or 0);
    end
    local jobStr = string.format('%s%d%s', jobName, entry.level, subStr);
    local nameW = imgui.CalcTextSize(entry.name);
    dl:AddText({ wx + nameX + nameW + 6, wy + 6 }, imgui.GetColorU32({ 0.6, 0.6, 0.6, 1.0 }), jobStr);

    -- Zone + category + role (second line)
    dl:AddText({ wx + nameX, wy + 24 }, imgui.GetColorU32({ 0.55, 0.55, 0.55, 1.0 }), zoneName);
    local zoneW = imgui.CalcTextSize(zoneName);
    dl:AddText({ wx + nameX + zoneW + 8, wy + 24 }, imgui.GetColorU32(catColor), catName);

    -- Party size for LFM
    if isLfm then
        local sizeStr = string.format('%d/6', entry.partySize or 1);
        local sizeW = imgui.CalcTextSize(sizeStr);
        local ww = imgui.GetWindowWidth();
        dl:AddText({ wx + ww - sizeW - 8, wy + 6 }, imgui.GetColorU32({ 0.5, 0.5, 0.5, 1.0 }), sizeStr);
    end

    -- Role on right
    local roleName = ROLE_NAMES[entry.role or 0] or '';
    if roleName ~= '' and roleName ~= 'Any' then
        local roleW = imgui.CalcTextSize(roleName);
        local ww = imgui.GetWindowWidth();
        local roleColor = ROLES[(entry.role or 0) + 1] and ROLES[(entry.role or 0) + 1].color or { 0.7, 0.7, 0.7, 1.0 };
        dl:AddText({ wx + ww - roleW - 8, wy + 24 }, imgui.GetColorU32(roleColor), roleName);
    end

    -- Comment (third line, truncated to fit)
    if hasComment then
        local ww = imgui.GetWindowWidth();
        local maxW = ww - nameX - 12;
        local commentText = entry.comment;
        if imgui.CalcTextSize(commentText) > maxW and maxW > 20 then
            while #commentText > 1 and imgui.CalcTextSize(commentText .. '..') > maxW do
                commentText = commentText:sub(1, -2);
            end
            commentText = commentText .. '..';
        end
        dl:AddText({ wx + nameX, wy + 42 }, imgui.GetColorU32({ 0.6, 0.7, 0.6, 1.0 }), commentText);
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Render: Listing tab (LFG or LFM)
------------------------------------------------------------
local function renderListingTab(listingType)
    -- Filter entries by type and category
    local filtered = {};
    for i, entry in ipairs(entries) do
        local entryType = entry.listingType or 1;
        local matchesType = (entryType == listingType);
        local matchesCat = (selectedCat == 0 or entry.category == selectedCat);
        local blocked = pfSettings and pfSettings.blacklist[entry.name:lower()];
        local hidden = isHiddenByFilter(entry);

        if matchesType and matchesCat and not blocked and not hidden then
            table.insert(filtered, { idx = i, entry = entry });
        end
    end

    -- Category filter bar
    for ci, cat in ipairs(CATEGORIES) do
        local isSel = (cat.id == selectedCat);
        local cc = getCategoryColor(cat.id);
        if isSel then
            imgui.PushStyleColor(ImGuiCol_Button, { cc[1] * 0.35, cc[2] * 0.35, cc[3] * 0.35, 0.90 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { cc[1] * 0.45, cc[2] * 0.45, cc[3] * 0.45, 0.95 });
            imgui.PushStyleColor(ImGuiCol_Text, cc);
        else
            imgui.PushStyleColor(ImGuiCol_Button, { 0.12, 0.11, 0.18, 0.70 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.20, 0.18, 0.28, 0.80 });
            imgui.PushStyleColor(ImGuiCol_Text, { 0.50, 0.50, 0.55, 1.0 });
        end
        if imgui.SmallButton(cat.name .. '##pfcat') then
            selectedCat = cat.id;
        end
        imgui.PopStyleColor(3);
        if ci < #CATEGORIES then imgui.SameLine(0, 3); end
    end
    imgui.Spacing();

    -- Count display
    ui.dim(string.format('%d listing%s', #filtered, #filtered ~= 1 and 's' or ''));
    imgui.Separator();
    imgui.Spacing();

    -- Listings
    imgui.PushStyleColor(ImGuiCol_ChildBg, ui.color('windowBg'));
    imgui.BeginChild('##pf_listings', { -1, -1 }, false);

    -- Background image behind listings
    if pfSettings.hudBackground and renderFileImage then
        local bgAlpha = pfSettings.hudBgOpacity or 0.4;
        local savedCx, savedCy = imgui.GetCursorPos();
        local cw, ch = imgui.GetContentRegionAvail();
        imgui.SetCursorPos({ 0, 0 });
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, bgAlpha);
        renderFileImage('pf_bg.png', cw, ch);
        imgui.PopStyleVar();
        imgui.SetCursorPos({ savedCx, savedCy });
    end

    if #filtered == 0 then
        imgui.Spacing();
        ui.dim(listingType == 1 and 'No players looking for group.' or 'No groups recruiting.');
    else
        for _, f in ipairs(filtered) do
            renderEntryCard(f.idx, f.entry);
            imgui.Spacing();
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Render: Activity tab
------------------------------------------------------------
local function renderActivityTab()
    imgui.PushStyleColor(ImGuiCol_ChildBg, ui.color('windowBg'));
    imgui.BeginChild('##pf_activity', { -1, -1 }, false);

    -- Background image behind activity
    if pfSettings.hudBackground and renderFileImage then
        local bgAlpha = pfSettings.hudBgOpacity or 0.4;
        local savedCx, savedCy = imgui.GetCursorPos();
        local cw, ch = imgui.GetContentRegionAvail();
        imgui.SetCursorPos({ 0, 0 });
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, bgAlpha);
        renderFileImage('pf_bg.png', cw, ch);
        imgui.PopStyleVar();
        imgui.SetCursorPos({ savedCx, savedCy });
    end

    if #activityLog == 0 then
        ui.dim('No activity yet.');
    else
        for i = #activityLog, 1, -1 do
            local entry = activityLog[i];
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, entry.time);
            imgui.SameLine(0, 8);
            imgui.TextWrapped(entry.text);
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Render: Action bar (register/withdraw)
------------------------------------------------------------
local isRegisterOpen = false;

local function renderActionBar()
    if isRegistered then
        -- Registered: show status + withdraw
        local typeStr = regListingType == 2 and 'LFM' or 'LFG';
        local catName = CATEGORY_NAMES[regCategory] or '';
        imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 },
            string.format('Registered: %s %s', typeStr, catName));
        imgui.SameLine(imgui.GetWindowWidth() - 85);
        if ui.button('Withdraw', 75, 22) then
            requestWithdraw();
        end

        -- Roulette/Mission buttons for LFM leaders
        if regListingType == 2 and isPartyLeaderOrSolo() then
            if regCategory == 3 then -- BCNM
                imgui.SameLine(0, 8);
                if ui.button('Roulette', 70, 22) then
                    requestRouletteRoll(false);
                end
            elseif regCategory == 2 then -- Mission
                imgui.SameLine(0, 8);
                if ui.button('Start Duty', 80, 22) then
                    requestMissionStart();
                    missionSelect.entries = {};
                end
            end
        end
    else
        -- Not registered: two buttons that open register panel with type pre-selected
        if ui.button('Looking for Group##pf_lfg_reg', 0, 22) then
            selectedType = 1;
            isRegisterOpen = true;
        end
        imgui.SameLine(0, 6);
        if ui.button('Looking for Members##pf_lfm_reg', 0, 22) then
            selectedType = 2;
            isRegisterOpen = true;
        end
        imgui.SameLine(0, 6);
        if ui.button('Settings##pf_settings_btn', 0, 22) then
            isPfSettingsOpen = not isPfSettingsOpen;
        end
    end
end

------------------------------------------------------------
-- Render: Registration panel (separate window)
------------------------------------------------------------
local function renderRegisterPanel()
    if not isRegisterOpen then return; end

    imgui.SetNextWindowSize({ 440, 380 }, ImGuiCond_Appearing);
    local winColors = ui.pushWindowStyle();
    local open = { true };

    if imgui.Begin('Register - Party Finder###pf_register', open, ImGuiWindowFlags_NoCollapse) then

        -- Listing type
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'I am...');
        imgui.Spacing();

        local lfgSel = selectedType == 1;
        local lfmSel = selectedType == 2;
        local halfW = (imgui.GetContentRegionAvail() - 8) / 2;

        -- LFG button
        local lfgBg = lfgSel and { 0.15, 0.30, 0.45, 0.90 } or { 0.12, 0.12, 0.18, 0.80 };
        local lfgHv = lfgSel and { 0.20, 0.38, 0.55, 0.95 } or { 0.18, 0.18, 0.28, 0.85 };
        local lfgTx = lfgSel and { 0.50, 0.85, 1.00, 1.00 } or { 0.45, 0.45, 0.50, 1.00 };
        imgui.PushStyleColor(ImGuiCol_Button, lfgBg);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, lfgHv);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, lfgHv);
        imgui.PushStyleColor(ImGuiCol_Text, lfgTx);
        if imgui.Button('Looking for Group', { halfW, 28 }) then selectedType = 1; end
        imgui.PopStyleColor(4);

        imgui.SameLine(0, 8);

        -- LFM button
        local lfmBg = lfmSel and { 0.40, 0.25, 0.10, 0.90 } or { 0.12, 0.12, 0.18, 0.80 };
        local lfmHv = lfmSel and { 0.50, 0.32, 0.14, 0.95 } or { 0.18, 0.18, 0.28, 0.85 };
        local lfmTx = lfmSel and { 1.00, 0.80, 0.40, 1.00 } or { 0.45, 0.45, 0.50, 1.00 };
        imgui.PushStyleColor(ImGuiCol_Button, lfmBg);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, lfmHv);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, lfmHv);
        imgui.PushStyleColor(ImGuiCol_Text, lfmTx);
        if imgui.Button('Recruiting Members', { halfW, 28 }) then selectedType = 2; end
        imgui.PopStyleColor(4);

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Role selection
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Role');
        imgui.Spacing();
        local roleGap = 6;
        local roleW = math.floor((imgui.GetContentRegionAvail() - roleGap * (#ROLES - 1)) / #ROLES);
        for i, role in ipairs(ROLES) do
            if i > 1 then imgui.SameLine(0, roleGap); end
            local isSelected = (selectedRole == role.id);

            local rBg = isSelected
                and { role.color[1] * 0.3, role.color[2] * 0.3, role.color[3] * 0.3, 0.90 }
                or  { 0.12, 0.12, 0.18, 0.80 };
            local rHv = { role.color[1] * 0.4, role.color[2] * 0.4, role.color[3] * 0.4, 0.90 };
            local rTx = isSelected and role.color or { 0.50, 0.50, 0.55, 1.00 };

            imgui.PushStyleColor(ImGuiCol_Button, rBg);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, rHv);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, rHv);
            imgui.PushStyleColor(ImGuiCol_Text, rTx);
            if imgui.Button(role.name .. '##pfrole', { roleW, 26 }) then
                selectedRole = role.id;
            end
            imgui.PopStyleColor(4);

            if isSelected then
                local rx, ry = imgui.GetItemRectMin();
                local rx2, ry2 = imgui.GetItemRectMax();
                local dl = imgui.GetWindowDrawList();
                dl:AddRectFilled({ rx, ry2 }, { rx2, ry2 + 2 }, imgui.GetColorU32(role.color));
            end
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Category
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Category');
        imgui.SameLine(0, 12);
        local regCatDisplay = CATEGORY_NAMES[selectedCat] or 'EXP';
        if selectedCat == 0 then regCatDisplay = 'EXP'; end
        imgui.PushItemWidth(160);
        if imgui.BeginCombo('##pfregcat', regCatDisplay) then
            for _, cat in ipairs(CATEGORIES) do
                if cat.id > 0 then
                    if imgui.Selectable(cat.name, selectedCat == cat.id) then
                        selectedCat = cat.id;
                    end
                end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();

        -- Auto-accept (LFM only)
        if selectedType == 2 then
            imgui.Spacing();
            imgui.Checkbox('Auto-Accept Joins##pfaa', autoAcceptBuf);
            if autoAcceptBuf[1] then
                imgui.SameLine(0, 12);
                imgui.Text('Min Lv:');
                imgui.SameLine(0, 4);
                imgui.PushItemWidth(60);
                imgui.InputInt('##pfminlv', minLevelBuf, 1);
                imgui.PopItemWidth();
                minLevelBuf[1] = math.max(1, math.min(75, minLevelBuf[1]));
            end
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Comment
        imgui.TextColored({ 0.9, 0.85, 0.7, 1.0 }, 'Comment');
        imgui.PushItemWidth(-1);
        imgui.InputText('##pfcomment', commentBuf, 64);
        imgui.PopItemWidth();

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        -- Register / Cancel buttons
        local winW = imgui.GetWindowWidth();
        local btnW = 110;
        imgui.SetCursorPosX((winW - btnW * 2 - 12) * 0.5);

        imgui.PushStyleColor(ImGuiCol_Button, { 0.15, 0.35, 0.15, 1.0 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.20, 0.45, 0.20, 1.0 });
        if imgui.Button('Register', { btnW, 30 }) then
            local catId = selectedCat > 0 and selectedCat or 1;
            requestRegister(catId, 0, selectedRole, selectedType,
                autoAcceptBuf[1] and 1 or 0, minLevelBuf[1] or 0, commentBuf[1] or '');
            isRegisterOpen = false;
        end
        imgui.PopStyleColor(2);

        imgui.SameLine(0, 12);
        imgui.PushStyleColor(ImGuiCol_Button, { 0.18, 0.16, 0.24, 0.80 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.28, 0.24, 0.36, 0.85 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.35, 0.30, 0.44, 0.90 });
        if imgui.Button('Cancel', { btnW, 30 }) then
            isRegisterOpen = false;
        end
        imgui.PopStyleColor(3);
    end
    imgui.End();
    ui.popWindowStyle(winColors);

    if not open[1] then isRegisterOpen = false; end
end

------------------------------------------------------------
-- Render: Roulette ready check popup
------------------------------------------------------------
local function renderRoulettePopup()
    if not roulette.active then return; end

    local remaining = roulette.timeout - os.time();
    if remaining <= 0 then
        roulette.active = false;
        return;
    end

    imgui.SetNextWindowSize({ 300, 180 }, ImGuiCond_Appearing);
    local label = roulette.source == 'mission' and 'Mission Help' or 'Duty Roulette';
    local rouletteColors = ui.pushWindowStyle();

    if imgui.Begin(label .. '###pf_roulette', nil, ImGuiWindowFlags_NoCollapse) then
        imgui.TextColored({ 1.0, 0.85, 0.4, 1.0 }, roulette.dutyName);
        if roulette.dutyCap > 0 then
            imgui.SameLine();
            imgui.TextColored({ 0.6, 0.6, 0.6, 1.0 }, string.format('(Lv%d cap)', roulette.dutyCap));
        end
        imgui.Separator();
        imgui.Spacing();

        imgui.Text(string.format('Ready: %d / %d', roulette.readyCount, roulette.totalCount));
        imgui.Text(string.format('Time: %ds', remaining));
        imgui.Spacing();

        if roulette.isLeader then
            local allReady = roulette.readyCount >= roulette.totalCount;
            if not allReady then
                imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35);
            end
            if ui.button('Commence', 90, 26) and allReady then
                requestRouletteGo();
            end
            if not allReady then
                imgui.PopStyleVar();
            end
        else
            if not roulette.myReady then
                if ui.button('Ready', 70, 26) then
                    requestReady();
                    roulette.myReady = true;
                end
                imgui.SameLine(0, 8);
                if ui.button('Decline', 70, 26) then
                    sendDutyDecline();
                    roulette.active = false;
                end
            else
                imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Ready! Waiting for party...');
            end
        end
    end
    imgui.End();
    ui.popWindowStyle(rouletteColors);
end

------------------------------------------------------------
-- Render: Incoming join requests (for leaders)
------------------------------------------------------------
local function renderIncomingRequests()
    -- Prune expired
    local now = os.time();
    for i = #incomingRequests, 1, -1 do
        if now - incomingRequests[i].time > REQUEST_TTL then
            table.remove(incomingRequests, i);
        end
    end

    if #incomingRequests == 0 then return; end

    for i, req in ipairs(incomingRequests) do
        local remaining = REQUEST_TTL - (now - req.time);
        local jobName = JOB_ABBR[req.job] or '???';

        imgui.SetNextWindowSize({ 250, 90 }, ImGuiCond_Appearing);
        local jrColors = ui.pushWindowStyle();
        if imgui.Begin(string.format('Join Request##pf_jr_%d', i), nil, ImGuiWindowFlags_NoCollapse) then
            imgui.TextColored({ 1.0, 0.95, 0.80, 1.0 },
                string.format('%s (%s%d)', req.name, jobName, req.level));
            imgui.TextColored({ 0.5, 0.5, 0.5, 1.0 }, string.format('%ds', remaining));
            imgui.Spacing();

            imgui.PushStyleColor(ImGuiCol_Button, { 0.15, 0.38, 0.15, 0.90 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.20, 0.48, 0.20, 0.95 });
            if imgui.SmallButton('Accept##jr' .. i) then
                sendJoinRespond(req.name, true, 0, '');
                pfprint(req.name .. ' accepted.');
                table.remove(incomingRequests, i);
            end
            imgui.PopStyleColor(2);
            imgui.SameLine(0, 8);
            imgui.PushStyleColor(ImGuiCol_Button, { 0.38, 0.15, 0.15, 0.90 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.48, 0.20, 0.20, 0.95 });
            if imgui.SmallButton('Deny##jr' .. i) then
                sendJoinRespond(req.name, false, 0, '');
                pfprint(req.name .. ' denied.');
                table.remove(incomingRequests, i);
            end
            imgui.PopStyleColor(2);
        end
        imgui.End();
        ui.popWindowStyle(jrColors);
    end
end

------------------------------------------------------------
-- PF Settings panel (floating window)
------------------------------------------------------------
local function renderPfSettingsPanel()
    if not isPfSettingsOpen then return; end

    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 280, 0 }, ImGuiCond_FirstUseEver);

    local open = { true };
    if imgui.Begin('Party Finder Settings##pf_settings', open, ImGuiWindowFlags_AlwaysAutoResize) then
        local changed = false;

        ui.colored('Display', 'header');
        imgui.Spacing();

        local partyBtn = { pfSettings.showPartyButton };
        if imgui.Checkbox('Show Party button in top bar', partyBtn) then
            pfSettings.showPartyButton = partyBtn[1];
            changed = true;
        end

        local hud = { pfSettings.showHud };
        if imgui.Checkbox('Show HUD widget', hud) then
            pfSettings.showHud = hud[1];
            changed = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show LFG/LFM counts on screen');
        end

        local bg = { pfSettings.hudBackground };
        if imgui.Checkbox('Show background image', bg) then
            pfSettings.hudBackground = bg[1];
            changed = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show CatsEyeXI background on Party tab');
        end

        if pfSettings.hudBackground then
            local opacityPct = { math.floor(pfSettings.hudBgOpacity * 100) };
            imgui.PushItemWidth(140);
            if imgui.SliderInt('Background opacity', opacityPct, 10, 100, '%d%%') then
                pfSettings.hudBgOpacity = opacityPct[1] / 100;
                changed = true;
            end
            imgui.PopItemWidth();
        end

        local login = { pfSettings.openOnLogin };
        if imgui.Checkbox('Open Party Finder on login', login) then
            pfSettings.openOnLogin = login[1];
            changed = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Auto-open Trove with Party tab on login');
        end

        imgui.Spacing();
        imgui.Spacing();
        ui.colored('Notifications', 'header');
        imgui.Spacing();

        local lfm = { pfSettings.lfmNotifications };
        if imgui.Checkbox('LFM chat notifications', lfm) then
            pfSettings.lfmNotifications = lfm[1];
            changed = true;
        end

        local tips = { pfSettings.tooltipsEnabled };
        if imgui.Checkbox('Show tooltips', tips) then
            pfSettings.tooltipsEnabled = tips[1];
            changed = true;
        end

        if changed then savePfConfig(); end
    end
    imgui.End();
    ui.popWindowStyle(pushed);

    if not open[1] then isPfSettingsOpen = false; end
end

------------------------------------------------------------
-- HUD widget (persistent on-screen overlay)
------------------------------------------------------------
local function renderHudWidget()
    if not pfSettings.showHud then return; end

    local lfgCount = 0;
    local lfmCount = 0;
    for _, e in ipairs(entries) do
        if not isHiddenByFilter(e) then
            if (e.listingType or 1) == 1 then lfgCount = lfgCount + 1;
            else lfmCount = lfmCount + 1; end
        end
    end

    local total = lfgCount + lfmCount;

    imgui.SetNextWindowPos({ 10, 38 }, ImGuiCond_FirstUseEver);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 6 });
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6);
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.04, 0.04, 0.06, 0.85 });
    imgui.PushStyleColor(ImGuiCol_Border, { 1, 1, 1, 0.08 });

    local flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    );

    if imgui.Begin('##pf_hud', { true }, flags) then
        if renderFileIcon then
            renderFileIcon('lfp.png', 20);
            imgui.SameLine(0, 6);
        end
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 2);
        imgui.TextColored({ 0.55, 0.80, 0.55, 1.0 },
            string.format('LFM %d', lfmCount));
        imgui.SameLine(0, 10);
        imgui.TextColored({ 0.55, 0.70, 0.90, 1.0 },
            string.format('LFG %d', lfgCount));

        if isRegistered then
            imgui.SameLine(0, 10);
            imgui.TextColored({ 0.40, 1.0, 0.40, 1.0 }, '*');
        end
    end
    imgui.End();

    imgui.PopStyleColor(2);
    imgui.PopStyleVar(2);
end

------------------------------------------------------------
-- Tab content (rendered inside the main Trove tab bar)
------------------------------------------------------------
local pfTabActive = false;    -- true when tab rendered this frame
local pfDataRequested = false; -- true after first data request

local function renderTabContent(state)
    pfTabActive = true;  -- mark as rendered this frame

    -- Request initial data on first tab view
    if not pfDataRequested then
        pfDataRequested = true;
        if #entries == 0 then
            requestRefresh();
        end
    end

    -- PFP + Daily + Refresh header
    imgui.TextColored({ 0.55, 0.55, 0.60, 1.0 }, string.format('PFP: %d', myPFP));
    imgui.SameLine(0, 12);
    imgui.TextColored({ 0.55, 0.55, 0.60, 1.0 }, string.format('Daily: %d/3', myDailyCount));
    local refreshW = imgui.CalcTextSize('Refresh') + 16;
    imgui.SameLine(imgui.GetWindowWidth() - refreshW - 16);
    if ui.button('Refresh##pf', refreshW, 20) then
        requestRefresh();
    end
    imgui.Separator();

    -- Action bar
    renderActionBar();
    imgui.Separator();
    imgui.Spacing();

    -- Sub-tabs: LFG / LFM / Activity
    if imgui.BeginTabBar('##pf_tabs', ImGuiTabBarFlags_None) then
        local lfgCount = 0;
        local lfmCount = 0;
        for _, e in ipairs(entries) do
            if not isHiddenByFilter(e) then
                if (e.listingType or 1) == 1 then lfgCount = lfgCount + 1;
                else lfmCount = lfmCount + 1; end
            end
        end

        if imgui.BeginTabItem(string.format('LFM (%d)###pf_lfm', lfmCount)) then
            activeTab = 2;
            renderListingTab(2);
            imgui.EndTabItem();
        end

        if imgui.BeginTabItem(string.format('LFG (%d)###pf_lfg', lfgCount)) then
            activeTab = 1;
            renderListingTab(1);
            imgui.EndTabItem();
        end

        if imgui.BeginTabItem('Activity###pf_act') then
            activeTab = 3;
            renderActivityTab();
            imgui.EndTabItem();
        end

        imgui.EndTabBar();
    end
end

------------------------------------------------------------
-- Window render (standalone floating window)
------------------------------------------------------------
local function renderPfWindow()
    if not pfWindowOpen[1] then return; end

    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 520, 500 }, ImGuiCond_FirstUseEver);

    local count = 0;
    for _, e in ipairs(entries) do
        if not isHiddenByFilter(e) then count = count + 1; end
    end
    local title = count > 0
        and string.format('Party Finder (%d)###trove_pf_window', count)
        or 'Party Finder###trove_pf_window';

    if imgui.Begin(title, pfWindowOpen, ImGuiWindowFlags_None) then
        renderTabContent({ isOpen = pfWindowOpen });
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Status strip (shown above main tab bar when registered)
------------------------------------------------------------
local function getStatus()
    if not isRegistered then return nil; end

    local typeStr = regListingType == 2 and 'LFM' or 'LFG';
    local catName = CATEGORY_NAMES[regCategory] or '';

    -- Count opposite listings
    local targetType = regListingType == 2 and 1 or 2;
    local count = 0;
    for _, e in ipairs(entries) do
        if (e.listingType or 1) == targetType and not isHiddenByFilter(e) then
            count = count + 1;
        end
    end

    local countLabel;
    if regListingType == 2 then
        countLabel = string.format('%d player%s available', count, count ~= 1 and 's' or '');
    else
        countLabel = string.format('%d group%s recruiting', count, count ~= 1 and 's' or '');
    end

    return {
        registered = true,
        typeStr    = typeStr,
        catName    = catName,
        countLabel = countLabel,
        partySize  = regListingType == 2 and (function()
            local myName = getMyName();
            for _, e in ipairs(entries) do
                if e.name == myName then return e.partySize; end
            end
            return nil;
        end)() or nil,
    };
end

------------------------------------------------------------
-- Plugin export
------------------------------------------------------------
return {
    name        = 'Party Finder',
    description = 'Find groups, register LFG/LFM, duty roulette',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi, sharedRenderTooltip, sharedRenderFileIcon, sharedRenderFileImage)
        renderIcon     = sharedRenderIcon;
        getItemRes     = sharedGetItemRes;
        ui             = sharedUi;
        renderTooltip  = sharedRenderTooltip;
        renderFileIcon = sharedRenderFileIcon;
        renderFileImage = sharedRenderFileImage;
        loadPfConfig();
    end,

    commands = {
        pf = function(state, args)
            pfWindowOpen[1] = not pfWindowOpen[1];
            if pfWindowOpen[1] and #entries == 0 then requestRefresh(); end
        end,
    },

    -- Floating window (standalone Party Finder panel)
    window = {
        isOpen = pfWindowOpen,
        render = renderPfWindow,
        label  = 'Party Finder',
        icon   = 'lfp.png',
    },

    -- Top bar button (rendered left of Menu in trove.lua)
    topBarButton = {
        label = 'Party',
        isVisible = function() return pfSettings.showPartyButton; end,
        action = function()
            pfWindowOpen[1] = not pfWindowOpen[1];
            if pfWindowOpen[1] and #entries == 0 then requestRefresh(); end
        end,
    },

    -- Status strip data (called by trove.lua to render above tab bar)
    getStatus = getStatus,

    onPacketIn = function(e, state)
        -- Party Finder packets (0x1A2)
        if e.id == PF_PACKET_ID then
            e.blocked = true;

            -- Server responded: clear ping
            pingPendingSince = nil;
            pingRetryCount   = 0;
            serverDisabled   = false;

            local action = struct.unpack('B', e.data_modified, 0x04 + 1);

            --------------------------------------------------------
            -- CLEAR: start building new entry list
            --------------------------------------------------------
            if action == S2C.CLEAR then
                pendingEntries = {};
                pendingMembers = {};
                return;
            end

            --------------------------------------------------------
            -- ENTRY: one listing
            --------------------------------------------------------
            if action == S2C.ENTRY then
                local category  = struct.unpack('B', e.data_modified, 0x05 + 1);
                local job       = struct.unpack('B', e.data_modified, 0x06 + 1);
                local level     = struct.unpack('B', e.data_modified, 0x07 + 1);
                local zoneId    = struct.unpack('H', e.data_modified, 0x08 + 1);
                local contentId = struct.unpack('H', e.data_modified, 0x0A + 1);
                local charId    = struct.unpack('L', e.data_modified, 0x0C + 1);
                local name      = struct.unpack('c16', e.data_modified, 0x10 + 1):gsub('%z', '');
                local comment   = struct.unpack('c64', e.data_modified, 0x20 + 1):gsub('%z', '');

                local entryRole        = struct.unpack('B', e.data_modified, 0x60 + 1);
                local entryListingType = struct.unpack('B', e.data_modified, 0x61 + 1);
                local entryPartySize   = struct.unpack('B', e.data_modified, 0x62 + 1);
                local entryAutoAccept  = struct.unpack('B', e.data_modified, 0x63 + 1);
                local entryMinLevel    = struct.unpack('B', e.data_modified, 0x64 + 1);
                local entrySubJob      = struct.unpack('B', e.data_modified, 0x65 + 1);
                local entrySubLevel    = struct.unpack('B', e.data_modified, 0x66 + 1);
                local entryGameMode    = struct.unpack('B', e.data_modified, 0x67 + 1);

                local target = pendingEntries or entries;
                table.insert(target, {
                    name        = name,
                    job         = job,
                    level       = level,
                    subJob      = entrySubJob,
                    subLevel    = entrySubLevel,
                    gameMode    = entryGameMode,
                    zoneId      = zoneId,
                    category    = category,
                    contentId   = contentId,
                    charId      = charId,
                    comment     = comment,
                    role        = entryRole,
                    listingType = entryListingType,
                    partySize   = entryPartySize,
                    autoAccept  = entryAutoAccept,
                    minLevel    = entryMinLevel,
                });
                return;
            end

            --------------------------------------------------------
            -- END_LIST: swap pending → active
            --------------------------------------------------------
            if action == S2C.END_LIST then
                if pendingEntries then
                    entries = pendingEntries;
                    partyMembers = pendingMembers or {};
                    pendingEntries = nil;
                    pendingMembers = nil;
                    selectedIndex = 0;
                end

                -- Read PFP, daily count, game mode
                local ok1, v1 = pcall(function() return struct.unpack('L', e.data_modified, 0x08 + 1); end);
                local ok2, v2 = pcall(function() return struct.unpack('B', e.data_modified, 0x0C + 1); end);
                local ok3, v3 = pcall(function() return struct.unpack('B', e.data_modified, 0x0D + 1); end);
                if ok1 then myPFP = v1; end
                if ok2 then myDailyCount = v2; end
                if ok3 then myGameMode = v3; end

                -- Sync registration state from listings
                local myName = getMyName();
                local foundSelf = false;
                for _, ent in ipairs(entries) do
                    if ent.name == myName then
                        foundSelf = true;
                        if not isRegistered then
                            isRegistered = true;
                            regListingType = ent.listingType or 1;
                            regCategory    = ent.category or 0;
                            regAutoAccept  = (ent.autoAccept or 0) == 1;
                            regMinLevel    = ent.minLevel or 0;
                        end
                        break;
                    end
                end
                if not foundSelf and isRegistered then
                    isRegistered = false;
                end

                -- Login summary
                if not hasShownLoginSummary and pfSettings and pfSettings.lfmNotifications then
                    hasShownLoginSummary = true;
                    local lfgC, lfmC = 0, 0;
                    for _, ent in ipairs(entries) do
                        if (ent.listingType or 1) == 1 then lfgC = lfgC + 1; else lfmC = lfmC + 1; end
                    end
                    if lfgC > 0 or lfmC > 0 then
                        pfprint(string.format('%d player%s LFG, %d group%s recruiting.',
                            lfgC, lfgC == 1 and '' or 's', lfmC, lfmC == 1 and '' or 's'));
                    end
                end
                return;
            end

            --------------------------------------------------------
            -- PARTY_MEMBER: party comp for LFM entries
            --------------------------------------------------------
            if action == S2C.PARTY_MEMBER then
                local mJob   = struct.unpack('B', e.data_modified, 0x05 + 1);
                local mLvl   = struct.unpack('B', e.data_modified, 0x06 + 1);
                local mSub   = struct.unpack('B', e.data_modified, 0x07 + 1);
                local mSubLv = struct.unpack('B', e.data_modified, 0x08 + 1);
                local leadId = struct.unpack('L', e.data_modified, 0x0C + 1);
                local mName  = struct.unpack('c16', e.data_modified, 0x10 + 1):gsub('%z', '');

                local target = pendingMembers or partyMembers;
                if not target[leadId] then target[leadId] = {}; end
                table.insert(target[leadId], {
                    name = mName, job = mJob, level = mLvl,
                    subJob = mSub, subLevel = mSubLv,
                });
                return;
            end

            --------------------------------------------------------
            -- ACK_REGISTER / ACK_WITHDRAW
            --------------------------------------------------------
            if action == S2C.ACK_REGISTER then
                isRegistered   = true;
                regListingType = selectedType;
                regCategory    = selectedCat;
                regAutoAccept  = autoAcceptBuf[1] or false;
                regMinLevel    = minLevelBuf[1] or 0;
                local typeStr = regListingType == 2 and 'LFM' or 'LFG';
                logActivity('Registered as %s (%s)', typeStr, CATEGORY_NAMES[regCategory] or 'General');
                pfprint('You are now registered.');
                requestRefresh();
                return;
            end

            if action == S2C.ACK_WITHDRAW then
                isRegistered   = false;
                regListingType = nil;
                regCategory    = nil;
                logActivity('Registration withdrawn');
                pfprint('Registration withdrawn.');
                requestRefresh();
                return;
            end

            --------------------------------------------------------
            -- LISTINGS_CHANGED: server broadcast
            --------------------------------------------------------
            if action == S2C.LISTINGS_CHANGED then
                requestRefresh();
                return;
            end

            --------------------------------------------------------
            -- Roulette / Mission / Join flows
            --------------------------------------------------------
            if action == S2C.ROULETTE_DUTY then
                local tier       = struct.unpack('B', e.data_modified, 0x05 + 1);
                local levelCap   = struct.unpack('B', e.data_modified, 0x06 + 1);
                local dutySource = struct.unpack('B', e.data_modified, 0x07 + 1);
                local dutyId     = struct.unpack('H', e.data_modified, 0x08 + 1);
                local dutyZone   = struct.unpack('H', e.data_modified, 0x0A + 1);
                local pSize      = struct.unpack('B', e.data_modified, 0x0C + 1);
                local isFollower = struct.unpack('B', e.data_modified, 0x0D + 1) == 1;
                local dutyName   = struct.unpack('c48', e.data_modified, 0x10 + 1):gsub('%z', '');

                if roulette.active and roulette.dutyId == dutyId then return; end

                local isMission = (dutySource == 1);
                roulette.active     = true;
                roulette.source     = isMission and 'mission' or 'roulette';
                roulette.isLeader   = not isFollower;
                roulette.myReady    = not isFollower;
                roulette.dutyName   = dutyName;
                roulette.dutyId     = dutyId;
                roulette.dutyZone   = dutyZone;
                roulette.dutyTier   = tier;
                roulette.dutyCap    = levelCap;
                roulette.readyCheck = {};
                roulette.readyCount = isFollower and 0 or 1;
                roulette.totalCount = isFollower and 0 or pSize;
                roulette.timeout    = os.time() + 60;
                roulette.partySize  = pSize;

                if isFollower then
                    local leaderName = struct.unpack('c16', e.data_modified, 0x40 + 1):gsub('%z', '');
                    roulette.leaderName = (leaderName ~= '') and leaderName or 'Leader';
                end

                local label = isMission and 'Mission Help' or 'Duty Roulette';
                logActivity('%s: %s', label, dutyName);
                pfprint(string.format('%s: %s', label, dutyName));
                return;
            end

            if action == S2C.ROULETTE_ERR then
                local msg = struct.unpack('c56', e.data_modified, 0x08 + 1):gsub('%z', '');
                pfprint(msg);
                logActivity('Error: %s', msg);
                return;
            end

            if action == S2C.ROULETTE_OK then
                activeDuty.name  = roulette.dutyName;
                activeDuty.phase = 1;
                roulette.active = false;
                pfprint('Commenced! Teleporting...');
                logActivity('Duty commenced!');
                return;
            end

            if action == S2C.MISSION_ENTRY then
                local dutyId   = struct.unpack('H', e.data_modified, 0x08 + 1);
                local dutyZone = struct.unpack('H', e.data_modified, 0x0A + 1);
                local levelCap = struct.unpack('B', e.data_modified, 0x06 + 1);
                local dutyName = struct.unpack('c48', e.data_modified, 0x10 + 1):gsub('%z', '');
                table.insert(missionSelect.entries, {
                    id = dutyId, name = dutyName, zone = dutyZone, levelCap = levelCap,
                });
                return;
            end

            if action == S2C.MISSION_END then
                missionSelect.active = true;
                return;
            end

            if action == S2C.READY_UPDATE then
                if not roulette.active or not roulette.isLeader then return; end
                local memberName = struct.unpack('c16', e.data_modified, 0x05 + 1):gsub('%z', '');
                if memberName == '' then return; end
                local key = memberName:lower();
                if not roulette.readyCheck[key] then
                    roulette.readyCheck[key] = true;
                    roulette.readyCount = roulette.readyCount + 1;
                    pfprint(string.format('%s ready (%d/%d)', memberName, roulette.readyCount, roulette.totalCount));
                end
                return;
            end

            if action == S2C.JOIN_REQUEST then
                local reqJob   = struct.unpack('B', e.data_modified, 0x05 + 1);
                local reqLevel = struct.unpack('B', e.data_modified, 0x06 + 1);
                local reqRole  = struct.unpack('B', e.data_modified, 0x07 + 1);
                local sender   = struct.unpack('c16', e.data_modified, 0x08 + 1):gsub('%z', '');
                if sender == '' then return; end

                -- Blacklist check
                if pfSettings and pfSettings.blacklist[sender:lower()] then
                    sendJoinRespond(sender, false, 2, 'You are blocked.');
                    return;
                end

                -- Auto-accept
                if isRegistered and regListingType == 2 and regAutoAccept then
                    if regMinLevel > 0 and reqLevel < regMinLevel then
                        sendJoinRespond(sender, false, 1, string.format('Level too low (min %d)', regMinLevel));
                    else
                        sendJoinRespond(sender, true, 0, '');
                        pfprint(string.format('%s joined via Party Finder', sender));
                    end
                else
                    -- Queue for manual accept/deny
                    table.insert(incomingRequests, {
                        name = sender, job = reqJob, level = reqLevel, role = reqRole, time = os.time(),
                    });
                    pfprint(string.format('%s (%s%d) wants to join.', sender, JOB_ABBR[reqJob] or '???', reqLevel));
                end
                return;
            end

            if action == S2C.JOIN_RESULT then
                local result = struct.unpack('B', e.data_modified, 0x05 + 1);
                local leader = struct.unpack('c16', e.data_modified, 0x08 + 1):gsub('%z', '');
                local msg    = struct.unpack('c48', e.data_modified, 0x18 + 1):gsub('%z', '');

                if result == 1 then
                    pfprint(leader .. ' accepted your request!');
                    logActivity('%s accepted', leader);
                else
                    pfprint(string.format('%s denied: %s', leader, msg ~= '' and msg or 'No reason'));
                    logActivity('%s denied', leader);
                    pendingJoinTarget = nil;
                end
                return;
            end

            if action == S2C.DUTY_DECLINE then
                local member = struct.unpack('c16', e.data_modified, 0x05 + 1):gsub('%z', '');
                if roulette.active and roulette.isLeader then
                    roulette.active = false;
                    pfprint(member .. ' declined. Cancelled.');
                end
                return;
            end

            return;
        end

        -- Venture Info packets (0x1A3)
        if e.id == VENTURE_PACKET_ID then
            e.blocked = true;
            if e.size < 0x54 then return; end

            ventureState.version  = struct.unpack('B', e.data_modified, 0x04 + 1);
            ventureState.gameMode = struct.unpack('B', e.data_modified, 0x05 + 1);

            for poolIdx, poolKey in ipairs({ 'a', 'b' }) do
                local base = 0x08 + (poolIdx - 1) * 0x24;
                for tier = 1, 6 do
                    local off = base + (tier - 1) * 6;
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
            return;
        end

        -- Auto-accept party invites from pending PF join target
        if e.id == 0x00DC and pendingJoinTarget then
            local inviter = struct.unpack('c16', e.data_modified, 0x0C + 1):gsub('%z', '');
            if inviter:lower() == pendingJoinTarget then
                e.blocked = true;
                local accept = { 0x74, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
                AshitaCore:GetPacketManager():AddOutgoingPacket(0x74, accept);
                pfprint('Auto-accepted invite from ' .. inviter);
                pendingJoinTarget = nil;
            end
            return;
        end

        -- Zone in: refresh listings
        if e.id == 0x000A then
            -- Dismiss roulette on zone-in
            if roulette.active then
                if activeDuty.phase == 0 then
                    activeDuty.name  = roulette.dutyName;
                    activeDuty.phase = 1;
                end
                roulette.active = false;
            end
            if activeDuty.phase == 1 then
                activeDuty.phase = 2;
            elseif activeDuty.phase == 2 then
                activeDuty.phase = 0;
                activeDuty.name  = '';
            end
            -- Delayed refresh after zone-in
            lastRefreshTime = os.clock() + 3; -- delay 3s
            return;
        end
    end,

    -- Periodic: auto-refresh, ping timeout, floating windows
    onRender = function(state)
        -- Close floating panels when PF window is closed
        if isRegisterOpen and not pfWindowOpen[1] then
            isRegisterOpen = false;
        end

        -- Floating windows (register panel, roulette popup, join requests, settings)
        -- These render regardless of which tab is active
        renderRegisterPanel();
        renderRoulettePopup();
        renderIncomingRequests();
        renderPfSettingsPanel();

        -- HUD widget (always visible when enabled)
        renderHudWidget();

        -- Login auto-open: after first data load, open PF window
        if pfSettings.openOnLogin and not loginAutoOpenDone and #entries > 0 then
            loginAutoOpenDone = true;
            pfWindowOpen[1] = true;
        end

        -- Auto-refresh (always active, not gated on tab visibility)
        if os.clock() > lastRefreshTime + autoRefreshInterval then
            lastRefreshTime = os.clock();
            requestRefresh();
        end

        -- Ping timeout
        if pingPendingSince then
            if os.time() - pingPendingSince > PF_PING_TIMEOUT then
                pingRetryCount = pingRetryCount + 1;
                if pingRetryCount >= PF_PING_RETRIES then
                    serverDisabled = true;
                    pingPendingSince = nil;
                    pfprint('Party Finder unavailable.');
                else
                    pingPendingSince = os.time();
                    sendC2S(C2S.REFRESH);
                end
            end
        end
    end,

    -- Chat text filtering (mute LFM broadcasts when notifications off)
    onTextIn = function(e, state)
        if not pfSettings then return; end
        local msg = e.message_modified or e.message or '';
        local raw = e.message or '';
        local isLFM = string.find(msg, 'is looking for members', 1, true)
                   or string.find(raw, 'is looking for members', 1, true);
        if not isLFM then return; end

        if not pfSettings.lfmNotifications then
            e.blocked = true;
            return;
        end

        -- Cross-mode filter
        if myGameMode ~= nil then
            local hasCW = string.find(msg, '[CW]', 1, true)
                       or string.find(raw, '[CW]', 1, true);
            if myGameMode == 1 and not hasCW then e.blocked = true; return; end
            if myGameMode ~= 1 and hasCW then e.blocked = true; return; end
        end
    end,
};
