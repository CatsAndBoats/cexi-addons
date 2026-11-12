--[[
* trove/plugins/stronghold.lua — Stronghold Artifacts
*
* Displays SCNM artifact collection status across 3 zones.
* Data fetched as a packed 24-bit bitmask via generic tab protocol.
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;

------------------------------------------------------------
-- Artifact data (bit order matches server STRONGHOLD_ORDER)
------------------------------------------------------------
local ZONES = {
    {
        name = "La Vaule [S]",
        tint = { 0.20, 0.12, 0.12 },
        artifacts = {
            { bit = 1,  name = "Coinbiter Cjaknokk",     artifact = "Purse of Counterfeit Beastcoins" },
            { bit = 2,  name = "Draketrader Zlodgodd",    artifact = "Pristine Sabertooth Pelt" },
            { bit = 3,  name = "Feeblescheme Bhogbigg",   artifact = "Cask of Stupefying Stondyng" },
            { bit = 4,  name = "All-seeing Onyx Eye",     artifact = "Mirror of Sycophantic Flattery" },
            { bit = 5,  name = "Cogtooth Skagnogg",       artifact = "Inviolate Girder of Bolstering" },
            { bit = 6,  name = "Agrios",                  artifact = "Mocking Effigy of Oreios" },
            { bit = 7,  name = "Falsespinner Bhudbrodd",  artifact = "Callais Scepter of Sooth" },
            { bit = 8,  name = "Rugaroo",                 artifact = "Pot of Wolfsbane Gumbo" },
        },
    },
    {
        name = "Beadeaux [S]",
        tint = { 0.12, 0.14, 0.22 },
        artifacts = {
            { bit = 9,  name = "Ga'Lhu Nevermolt",        artifact = "Perforator of Iniquity" },
            { bit = 10, name = "Bres",                    artifact = "Silver Prosthesis of the True King" },
            { bit = 11, name = "Di'Zho Spongeshell",      artifact = "Oathbreaker's Swift Rebuke" },
            { bit = 12, name = "Observant Zekka",         artifact = "Clarion-Prone Shatterpot" },
            { bit = 13, name = "Mu'Nhi Thimbletail",      artifact = "Hallucinogenic Spirit Toxin" },
            { bit = 14, name = "Blifnix Oilycheeks",      artifact = "Nostalgic Moval Woolen Blanket" },
            { bit = 15, name = "Va'Gho Bloodbasked",      artifact = "Whistling Fleshripper" },
            { bit = 16, name = "Ra'Dha Scarscute",        artifact = "Vicegrip Turtle-Drowners" },
        },
    },
    {
        name = "Castle Oztroja [S]",
        tint = { 0.12, 0.18, 0.12 },
        artifacts = {
            { bit = 17, name = "Dee Zelko the Esoteric",  artifact = "Credible Archaeological Hoax" },
            { bit = 18, name = "Marquis Forneus",         artifact = "Six-Headed Caprine Oblation" },
            { bit = 19, name = "Loo Kutto the Pensive",   artifact = "Insect-Incinerating Blade" },
            { bit = 20, name = "Fleshgnasher",            artifact = "Necromone-Drenched Bauble" },
            { bit = 21, name = "Vee Ladu the Titterer",   artifact = "Tsurutsuru Wakizashi" },
            { bit = 22, name = "Maa Illmu the Bestower",  artifact = "Vestment of Blatant Blasphemy" },
            { bit = 23, name = "Asterion",                artifact = "Cretian Tartine Platter" },
            { bit = 24, name = "Suu Xicu the Cantabile",  artifact = "Falsetto-Enhancing Codpiece" },
        },
    },
};

------------------------------------------------------------
-- Protocol
------------------------------------------------------------
local PACKET_ID             = 0x1A4;
local C2S_TAB_SUMMARY      = 13;
local S2C_TAB_SUMMARY      = 12;
local TAB_SOURCE_STRONGHOLD = 3;

local function makePacket()
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    return p;
end

local function sendRequest()
    local p = makePacket();
    p[5] = C2S_TAB_SUMMARY;
    p[7] = TAB_SOURCE_STRONGHOLD;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen      = { false };
local dataLoaded  = false;
local bitmask     = 0;
local selectedZone = nil;

local function hasBit(mask, pos)
    return bit.band(mask, bit.lshift(1, pos)) ~= 0;
end

------------------------------------------------------------
-- Layout
------------------------------------------------------------
local ROW_HEIGHT = 30;

local cellColorCache = nil;
local cellColorVersion = -1;

local function getCellColors()
    local v = ui.getThemeVersion();
    if cellColorCache and cellColorVersion == v then return cellColorCache; end
    local base = ui.color('childBg');
    cellColorCache = {
        ownedBg = { 0.18, 0.38, 0.18, 1.0 },
        cellBg  = { base[1], base[2], base[3], 1.0 },
    };
    cellColorVersion = v;
    return cellColorCache;
end

------------------------------------------------------------
-- Counting
------------------------------------------------------------
local function countZoneOwned(zone)
    local owned = 0;
    for _, a in ipairs(zone.artifacts) do
        if hasBit(bitmask, a.bit) then owned = owned + 1; end
    end
    return owned;
end

local function countTotalOwned()
    local owned = 0;
    for _, zone in ipairs(ZONES) do
        owned = owned + countZoneOwned(zone);
    end
    return owned;
end

------------------------------------------------------------
-- Render: Tooltip
------------------------------------------------------------
local function renderTooltipFn(entry, isOwned)
    ui.tooltip(function()
        ui.colored(entry.artifact, 'white');
        imgui.Separator();
        ui.colored('NM: ' .. entry.name, 'header');
        if isOwned then
            ui.colored('Obtained', 'green');
        else
            ui.dim('Not collected');
        end
    end);
end

------------------------------------------------------------
-- Render: Zone list (main view)
------------------------------------------------------------
local function renderZoneList()
    if not dataLoaded then
        ui.dim('Loading...');
        return;
    end

    if ui.button('Refresh', 60, 22) then
        dataLoaded = false;
        sendRequest();
    end
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##sh_zones', { -1, -1 }, false);
    for i, zone in ipairs(ZONES) do
        local zoneOwned = countZoneOwned(zone);
        local subtitle = string.format('%d/8 collected', zoneOwned);

        local tint     = zone.tint;
        local btnId    = string.format('##shzone_%d', i);
        local rowWidth = imgui.GetContentRegionAvail();
        local bgColor  = { tint[1], tint[2], tint[3], 0.85 };
        local barColor = { tint[1] * 2.0, tint[2] * 2.0, tint[3] * 2.0, 1.0 };

        imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
        imgui.BeginChild(btnId, { rowWidth, 34 }, false);

        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();
        dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 34 }, imgui.GetColorU32(barColor));

        imgui.SetCursorPosY(0);
        local clicked = imgui.Selectable(string.format('##shsel_%d', i), false,
            ImGuiSelectableFlags_SpanAllColumns, { 0, 34 });

        dl:AddText({ wx + 10, wy + 5 }, imgui.GetColorU32(ui.color('white')), zone.name);
        dl:AddText({ wx + 10, wy + 19 }, imgui.GetColorU32(ui.color('dimmed')), subtitle);

        imgui.EndChild();
        imgui.PopStyleColor(1);

        if clicked then selectedZone = i; end
        imgui.Spacing();
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Render: Zone detail (artifact list)
------------------------------------------------------------
local function renderZoneDetail()
    local zone = ZONES[selectedZone];

    if ui.button('< Back', 55, 22) then
        selectedZone = nil;
        return;
    end
    imgui.SameLine();
    ui.colored(zone.name, 'header');
    imgui.SameLine();
    ui.dim(string.format('(%d/8)', countZoneOwned(zone)));
    imgui.SameLine(imgui.GetWindowWidth() - 80);
    if ui.button('Refresh', 60, 22) then
        dataLoaded = false;
        sendRequest();
    end
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##sh_list', { -1, -1 }, false);
    for i, entry in ipairs(zone.artifacts) do
        local isOwned = hasBit(bitmask, entry.bit);
        local cc = getCellColors();
        local bgCol = isOwned and cc.ownedBg or cc.cellBg;

        imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
        local rowId = string.format('##sh_%d_%d', selectedZone, i);
        imgui.BeginChild(rowId, { -1, 42 }, true, bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

        imgui.SetCursorPos({ 8, 5 });
        if isOwned then
            ui.colored(entry.artifact, 'green');
        else
            ui.colored(entry.artifact, 'dimmed');
        end

        -- NM name as smaller subtitle
        imgui.SetCursorPos({ 8, 22 });
        if isOwned then
            imgui.TextColored({ 0.25, 0.55, 0.25, 0.80 }, entry.name);
        else
            local dim = ui.color('dimmed');
            imgui.TextColored({ dim[1] * 0.7, dim[2] * 0.7, dim[3] * 0.7, 0.7 }, entry.name);
        end

        imgui.EndChild();
        imgui.PopStyleColor();

        if imgui.IsItemHovered() then
            renderTooltipFn(entry, isOwned);
        end
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Main render
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    if not dataLoaded and bitmask == 0 then
        sendRequest();
        bitmask = -1; -- sentinel to prevent re-request
    end

    local totalOwned = countTotalOwned();
    local title = string.format('Stronghold [%d/24]###trove_stronghold', totalOwned);

    imgui.SetNextWindowSize({ 420, 400 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 350, 300 }, { 550, 700 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin(title, isOpen, ImGuiWindowFlags_NoScrollbar) then
        local _bgPop = ui.renderBackground();
        if selectedZone then
            renderZoneDetail();
        else
            renderZoneList();
        end
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(winColors);
end

------------------------------------------------------------
-- Plugin export
------------------------------------------------------------
return {
    name        = 'Stronghold',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Stronghold Invasion artifact tracker',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
    end,

    commands = {
        stronghold = function(state, args)
            isOpen[1] = not isOpen[1];
        end,
    },

    window = {
        category = 'Utility',
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Stronghold',
        icon    = 748, -- Gold Beastcoin
    },

    onPacketIn = function(e, state)
        if e.id ~= PACKET_ID then return; end

        local action = struct.unpack('B', e.data_modified, 0x04 + 1);
        if action ~= S2C_TAB_SUMMARY then return; end

        local source = struct.unpack('B', e.data_modified, 0x06 + 1);
        if source ~= TAB_SOURCE_STRONGHOLD then return; end

        local entryCount = struct.unpack('B', e.data_modified, 0x05 + 1);
        if entryCount >= 1 then
            local b1 = struct.unpack('B', e.data_modified, 0x08 + 1);
            local b2 = struct.unpack('B', e.data_modified, 0x09 + 1);
            local b3 = struct.unpack('B', e.data_modified, 0x0A + 1);
            local b4 = struct.unpack('B', e.data_modified, 0x0B + 1);
            bitmask = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216;
        else
            bitmask = 0;
        end
        dataLoaded = true;
    end,
};
