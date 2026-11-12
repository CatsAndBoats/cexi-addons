--[[
* trove/plugins/squire.lua — Squire storage tab
*
* Displays items stored with the Squire NPC, grouped by category
* and subtype. Uses the generic tab protocol (TAB_SOURCE = 0).
*
* Command: /trove squire
]]--

local imgui = require('imgui');
local pkt   = require('utils/packet');

------------------------------------------------------------
-- Shared (injected via init / setContext)
------------------------------------------------------------
local renderIcon    = nil;
local getItemRes    = nil;
local ui            = nil;
local renderTooltip = nil;
local getRowBg      = nil;

local TAB_SOURCE_SQUIRE = 0;

------------------------------------------------------------
-- Color proxy (resolves at render time via theme)
------------------------------------------------------------
local COLOR_ALIASES = {
    btnFeatureH = 'btnFeatureHover',
    btnFeatureA = 'btnFeatureActive',
};

local COLORS;
local function initColors()
    COLORS = setmetatable({}, {
        __index = function(_, key)
            local themeKey = COLOR_ALIASES[key] or key;
            return ui.color(themeKey);
        end,
    });
end

------------------------------------------------------------
-- State
------------------------------------------------------------
local squire              = {};
local squireLoaded        = false;
local squireSummary       = {};
local squireSummaryLoaded = false;
local squireCategory      = nil;
local fetchedAt           = 0;
local TTL                 = 300;

------------------------------------------------------------
-- Category ordering
------------------------------------------------------------
local SQUIRE_CATEGORY_ORDER = {
    'Relic +1',
    'AF +1',
    'Novice Trial',
    'Grand Trial',
    'Domain Invasion',
    'Endgame',
    'Crystal Warrior',
    'Yagudo Arena',
    'Incursion',
    'CW Misc.',
};

local function squireCategoryRank(name)
    for i, n in ipairs(SQUIRE_CATEGORY_ORDER) do
        if n == name then return i; end
    end
    return 99;
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function cacheFresh()
    return fetchedAt > 0 and (os.clock() - fetchedAt) < TTL;
end

local function sendGetTabSummary()
    local p = pkt.make();
    p[5] = pkt.C2S.GET_TAB_SUMMARY;
    p[7] = TAB_SOURCE_SQUIRE;
    pkt.sendRaw(p);
end

local function sendGetTabCategory(categoryName)
    local p = pkt.make();
    p[5] = pkt.C2S.GET_TAB_CATEGORY;
    p[7] = TAB_SOURCE_SQUIRE;
    local bytes = { string.byte(categoryName, 1, 20) };
    for i = 1, math.min(#bytes, 20) do p[8 + i] = bytes[i]; end
    pkt.sendRaw(p);
end

------------------------------------------------------------
-- Render
------------------------------------------------------------
local function render(state)
    if not COLORS then initColors(); end

    -- Category list view (summary)
    if not squireCategory then
        if not squireSummaryLoaded then
            if state.pendingRequest == 'squire_summary' then
                imgui.TextColored(COLORS.dimmed, 'Loading...');
            else
                state.pendingRequest = 'squire_summary';
                sendGetTabSummary();
            end
            return;
        end

        if #squireSummary == 0 then
            imgui.TextColored(ui.color('empty'), 'Nothing stored with the Squire.');
            return;
        end

        -- Refresh button
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnFeature);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnFeatureH);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnFeatureA);
        if imgui.Button('Refresh##squire', { 70, 22 }) then
            squireSummaryLoaded = false;
            state.pendingRequest = 'squire_summary';
            sendGetTabSummary();
        end
        imgui.PopStyleColor(3);
        imgui.Separator();
        imgui.Spacing();

        imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.windowBg);
        imgui.BeginChild('##squire_summary', { -1, -1 }, false);
        for i, entry in ipairs(squireSummary) do
            local subtitle = string.format('%d item%s stored', entry.count, entry.count ~= 1 and 's' or '');
            if ui.categoryButton(entry.category, subtitle, i) then
                squireCategory = entry.category;
                squire = {};
                squireLoaded = false;
                state.pendingRequest = 'squire';
                sendGetTabCategory(entry.category);
            end
            imgui.Spacing();
        end
        imgui.EndChild();
        imgui.PopStyleColor(1);
        return;
    end

    -- Item list view (within a category)
    imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnFeature);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnFeatureH);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnFeatureA);
    if imgui.Button('Back##squire', { 50, 22 }) then
        squireCategory = nil;
        squire = {};
        squireLoaded = false;
        return;
    end
    imgui.PopStyleColor(3);
    imgui.SameLine();
    imgui.TextColored(COLORS.dimmed, string.format('%s (%d items)', squireCategory, #squire));
    imgui.Separator();
    imgui.Spacing();

    -- Group entries by subtype
    local byCat  = {};
    local catOrder = {};

    for _, entry in ipairs(squire) do
        if byCat[entry.category] == nil then
            byCat[entry.category] = { subtypes = {}, subOrder = {} };
            table.insert(catOrder, entry.category);
        end
        local cat = byCat[entry.category];
        if cat.subtypes[entry.subtype] == nil then
            cat.subtypes[entry.subtype] = {};
            table.insert(cat.subOrder, entry.subtype);
        end
        table.insert(cat.subtypes[entry.subtype], entry);
    end

    table.sort(catOrder, function(a, b) return squireCategoryRank(a) < squireCategoryRank(b); end);

    imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.windowBg);
    imgui.BeginChild('##squire_scroll', { -1, -1 }, false);

    if #squire == 0 then
        if state.pendingRequest == 'squire' then
            imgui.TextColored(COLORS.dimmed, 'Loading...');
        else
            imgui.TextColored(ui.color('empty'), 'Nothing stored with the Squire.');
        end
    else
        for _, catName in ipairs(catOrder) do
            local cat = byCat[catName];
            table.sort(cat.subOrder);

            -- Category header
            imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.headerBg);
            local hdrId = string.format('##sqcat_%s', catName);
            imgui.BeginChild(hdrId, { -1, 22 }, false);
            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 22 }, imgui.GetColorU32(COLORS.accent));
            imgui.SetCursorPosX(10);
            imgui.SetCursorPosY(3);
            imgui.TextColored(COLORS.category, catName);

            local total = 0;
            for _, subName in ipairs(cat.subOrder) do
                total = total + #cat.subtypes[subName];
            end
            local countStr = string.format('(%d)', total);
            local ww = imgui.GetWindowWidth();
            imgui.SameLine(ww - imgui.CalcTextSize(countStr) - 12);
            imgui.SetCursorPosY(3);
            imgui.TextColored(COLORS.dimmed, countStr);
            imgui.EndChild();
            imgui.PopStyleColor(1);

            -- Subtype sections + items
            local rowIdx = 0;
            for _, subName in ipairs(cat.subOrder) do
                local items = cat.subtypes[subName];
                table.sort(items, function(a, b) return a.name < b.name; end);

                imgui.Indent(6);
                imgui.TextColored(COLORS.dimmed, string.format('%s (%d)', subName, #items));
                imgui.Unindent(6);

                for _, entry in ipairs(items) do
                    rowIdx = rowIdx + 1;
                    local rowId = string.format('##sqrow_%s_%d', catName, rowIdx);
                    local isAlt = (rowIdx % 2 == 0);
                    local bg = getRowBg(isAlt);

                    imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
                    imgui.BeginChild(rowId, { -1, 28 }, false);

                    imgui.SetCursorPos({ 16, 2 });
                    if entry.iconId ~= nil and entry.iconId > 0 then
                        if not renderIcon(entry.iconId, 24) then imgui.Dummy({ 24, 24 }); end
                    else
                        imgui.Dummy({ 24, 24 });
                    end
                    imgui.SameLine(44);

                    imgui.SetCursorPosY(0);
                    if imgui.Selectable(string.format('##sqsel_%d', rowIdx), false,
                        ImGuiSelectableFlags_SpanAllColumns, { 0, 28 }) then
                        -- no-op: informational
                    end
                    if imgui.IsItemHovered() and entry.iconId ~= nil and entry.iconId > 0 then
                        renderTooltip({ id = entry.iconId, name = entry.name, qty = 1 });
                    end

                    local dl2 = imgui.GetWindowDrawList();
                    local wx2, wy2 = imgui.GetWindowPos();
                    local ww2 = imgui.GetWindowWidth();
                    dl2:AddText({ wx2 + 44, wy2 + 7 }, imgui.GetColorU32(COLORS.white), entry.name);

                    if entry.tier ~= nil and entry.tier ~= '' then
                        local tw = imgui.CalcTextSize(entry.tier);
                        dl2:AddText({ wx2 + ww2 - tw - 12, wy2 + 7 },
                            imgui.GetColorU32(COLORS.yellow), entry.tier);
                    end

                    imgui.EndChild();
                    imgui.PopStyleColor(1);
                end
            end

            imgui.Spacing();
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Squire',
    icon        = 12306,  -- Kite Shield
    author      = 'Loxley',
    version     = '1.0',
    description = 'Squire storage browser',

    init = function(ri, gir, uimod, rt, rfi, rfimg, gih)
        renderIcon    = ri;
        getItemRes    = gir;
        ui            = uimod;
        renderTooltip = rt;
        initColors();
    end,

    setContext = function(ctx)
        getRowBg = ctx.getRowBg;
    end,

    tab = {
        label  = 'Squire',
        render = render,
    },

    onPacketIn = function(e, state)
        if e.id ~= pkt.PACKET_ID then return; end
        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        if action == pkt.S2C.TAB_SUMMARY then
            local source = struct.unpack('B', e.data_modified, 0x06 + 1);
            if source ~= TAB_SOURCE_SQUIRE then return; end

            local entryCount = struct.unpack('B', e.data_modified, 0x05 + 1);
            local entries = {};
            local offset = 0x08;
            for i = 1, entryCount do
                local category = pkt.readString(e.data_modified, offset, 20);
                local count    = pkt.readU16(e.data_modified, offset + 20);
                table.insert(entries, { category = category, count = count });
                offset = offset + 22;
            end
            squireSummary = entries;
            squireSummaryLoaded = true;
            state.pendingRequest = nil;
            return;
        end

        if action == pkt.S2C.TAB_ENTRY then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            if source ~= TAB_SOURCE_SQUIRE then return; end

            local iconId   = pkt.readU16(e.data_modified, 0x06);
            local category = pkt.readString(e.data_modified, 0x08, 19);
            local subtype  = pkt.readString(e.data_modified, 0x1C, 23);
            local name     = pkt.readString(e.data_modified, 0x34, 23);
            local tier     = pkt.readString(e.data_modified, 0x4C, 7);

            table.insert(squire, {
                iconId   = iconId,
                category = category,
                subtype  = subtype,
                name     = name,
                tier     = tier,
            });
            return;
        end

        if action == pkt.S2C.CLEAR and state.pendingRequest == 'squire' then
            squire = {};
            return;
        end

        if action == pkt.S2C.END_LIST then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            if source == TAB_SOURCE_SQUIRE then
                squireLoaded = true;
                fetchedAt    = os.clock();
                state.pendingRequest = nil;
            end
            return;
        end
    end,

    ensureData = function()
        if squireCategory then
            squire = {};
            sendGetTabCategory(squireCategory);
        else
            if cacheFresh() then return; end
            sendGetTabSummary();
        end
    end,

    invalidate = function()
        fetchedAt = 0;
    end,

    commands = {
        squire = function(state)
            state.isOpen[1] = true;
        end,
    },
};
