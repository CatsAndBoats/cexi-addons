--[[
* trove/plugins/points.lua — Points tab
*
* Displays point balances grouped by category. Fully data-driven:
* the server sends group names, labels, and values via the 0x1A4 packet.
*
* Command: /trove points
]]--

local imgui  = require('imgui');
local pkt    = require('utils/packet');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local ui = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local points        = {};
local pointsLoaded  = false;
local fetchedAt     = 0;
local pendingRequest = false;
local TTL           = 120;

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function cacheFresh()
    return fetchedAt > 0 and (os.clock() - fetchedAt) < TTL;
end

local function requestPoints()
    points = {};
    pendingRequest = true;
    pkt.send(pkt.C2S.GET_POINTS);
end

------------------------------------------------------------
-- Row background (alternating)
------------------------------------------------------------
local rowBgCache = { version = -1, alt = nil, normal = nil };
local function getRowBg(isAlt)
    local v = ui and ui.getThemeVersion() or 0;
    if rowBgCache.version ~= v then
        local base = ui.color('childBg');
        rowBgCache.alt    = { base[1], base[2], base[3], 0.35 };
        rowBgCache.normal = { base[1], base[2], base[3], 0.20 };
        rowBgCache.version = v;
    end
    return isAlt and rowBgCache.alt or rowBgCache.normal;
end

------------------------------------------------------------
-- Group accent colors
------------------------------------------------------------
local GROUP_ACCENTS = {
    { 0.55, 0.75, 1.00, 1.00 },  -- blue
    { 0.65, 0.48, 0.92, 1.00 },  -- purple
    { 0.50, 0.88, 0.50, 1.00 },  -- green
    { 1.00, 0.78, 0.35, 1.00 },  -- amber
    { 0.90, 0.50, 0.50, 1.00 },  -- red
    { 0.50, 0.85, 0.85, 1.00 },  -- teal
    { 0.85, 0.65, 0.90, 1.00 },  -- pink
    { 0.75, 0.80, 0.50, 1.00 },  -- olive
};

------------------------------------------------------------
-- Render
------------------------------------------------------------
local function render(state)
    -- Auto-fetch on tab activation
    if not pointsLoaded and not pendingRequest then
        if not cacheFresh() then
            requestPoints();
        end
    end

    -- Group by group name
    local groups = {};
    local groupOrder = {};
    for _, entry in ipairs(points) do
        local g = entry.group;
        if groups[g] == nil then
            groups[g] = {};
            table.insert(groupOrder, g);
        end
        table.insert(groups[g], entry);
    end

    -- Refresh button
    local colors = {
        ui.color('btnFeature'),
        ui.color('btnFeatureHover'),
        ui.color('btnFeatureActive'),
    };
    imgui.PushStyleColor(ImGuiCol_Button, colors[1]);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, colors[2]);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, colors[3]);
    if imgui.Button('Refresh##points', { 70, 22 }) then
        requestPoints();
    end
    imgui.PopStyleColor(3);
    imgui.Separator();
    imgui.Spacing();

    imgui.PushStyleColor(ImGuiCol_ChildBg, ui.color('windowBg'));
    imgui.BeginChild('##points_scroll', { -1, -1 }, false);

    if #points == 0 then
        if pendingRequest then
            imgui.TextColored(ui.color('dimmed'), 'Loading...');
        else
            imgui.TextColored(ui.color('empty'), 'No points to display.');
        end
    else
        for gi, groupName in ipairs(groupOrder) do
            local accent = GROUP_ACCENTS[((gi - 1) % #GROUP_ACCENTS) + 1];
            local accentDim = { accent[1] * 0.35, accent[2] * 0.35, accent[3] * 0.35, 0.85 };

            -- Group header
            imgui.PushStyleColor(ImGuiCol_ChildBg, accentDim);
            local hdrId = string.format('##ptgrp_%s', groupName);
            imgui.BeginChild(hdrId, { -1, 24 }, false);
            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            local ww = imgui.GetWindowWidth();
            dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 24 }, imgui.GetColorU32(accent));
            dl:AddLine({ wx, wy + 23 }, { wx + ww, wy + 23 },
                imgui.GetColorU32({ accent[1], accent[2], accent[3], 0.15 }));
            imgui.SetCursorPosX(12);
            imgui.SetCursorPosY(4);
            imgui.TextColored(accent, groupName);

            -- Entry count on right
            local countStr = string.format('%d', #groups[groupName]);
            local cw = imgui.CalcTextSize(countStr);
            imgui.SameLine(ww - cw - 12);
            imgui.SetCursorPosY(4);
            imgui.TextColored({ accent[1], accent[2], accent[3], 0.50 }, countStr);

            imgui.EndChild();
            imgui.PopStyleColor(1);

            -- Value color tinted by group accent
            local valColor = { accent[1] * 0.7 + 0.3, accent[2] * 0.7 + 0.3, accent[3] * 0.7 + 0.3, 1.0 };

            for i, entry in ipairs(groups[groupName]) do
                local rowId = string.format('##ptrow_%s_%d', groupName, i);
                local isAlt = (i % 2 == 0);
                local bg = getRowBg(isAlt);

                imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
                imgui.BeginChild(rowId, { -1, 24 }, false);

                local dl2 = imgui.GetWindowDrawList();
                local wx2, wy2 = imgui.GetWindowPos();
                local ww2 = imgui.GetWindowWidth();

                dl2:AddText({ wx2 + 12, wy2 + 5 }, imgui.GetColorU32(ui.color('pointsLabel')), entry.label);

                local vstr = pkt.addCommas(entry.value);
                local tw2 = imgui.CalcTextSize(vstr);
                dl2:AddText({ wx2 + ww2 - tw2 - 12, wy2 + 5 },
                    imgui.GetColorU32(valColor), vstr);

                imgui.EndChild();
                imgui.PopStyleColor(1);
            end

            imgui.Spacing();
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1); -- points_scroll bg
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Points',
    icon        = 578,    -- Eagle Button
    author      = 'Loxley',
    version     = '1.0',
    description = 'Point balances',

    init = function(ri, gir, uimod, rt, rfi, rfimg, gih)
        ui = uimod;
    end,

    tab = {
        label  = 'Points',
        render = render,
    },

    onPacketIn = function(e, state)
        if e.id ~= pkt.PACKET_ID then return; end
        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        if action == pkt.S2C.POINTS_ENTRY then
            local group = pkt.readString(e.data_modified, 0x08, 19);
            local label = pkt.readString(e.data_modified, 0x1C, 23);
            local value = pkt.readI32(e.data_modified, 0x34);

            table.insert(points, { group = group, label = label, value = value });
            return;
        end

        if action == pkt.S2C.CLEAR and state.pendingRequest == 'points' then
            points = {};
            return;
        end

        if action == pkt.S2C.END_LIST and state.pendingRequest == 'points' then
            pointsLoaded    = true;
            fetchedAt       = os.clock();
            pendingRequest  = false;
            state.pendingRequest = nil;
            return;
        end
    end,

    ensureData = function()
        if cacheFresh() then return; end
        requestPoints();
    end,

    invalidate = function()
        fetchedAt = 0;
    end,

    commands = {
        points = function(state)
            state.isOpen[1] = true;
        end,
    },
};
