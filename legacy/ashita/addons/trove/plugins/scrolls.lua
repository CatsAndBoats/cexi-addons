--[[
* trove/plugins/scrolls.lua — Scroll Ledger
*
* Displays all storable magic scrolls with owned/missing status.
* Data fetched as packed bitmasks via generic tab protocol.
* Crystal Warrior only.
*
* Command: /trove scrolls
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;
local renderTooltip = nil;

------------------------------------------------------------
-- Scroll Data (loaded from data/scroll_data.lua)
-- Order MUST match the server's page layout.
------------------------------------------------------------
local CATEGORIES = require('plugins/data/scroll_data');

------------------------------------------------------------
-- Protocol
------------------------------------------------------------
local PACKET_ID          = 0x1A4;
local C2S_TAB_SUMMARY   = 13;
local S2C_TAB_SUMMARY   = 12;
local TAB_SOURCE_SCROLLS = 2;

local function makePacket()
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    return p;
end

local function sendScrollRequest()
    local p = makePacket();
    p[5] = C2S_TAB_SUMMARY;
    p[7] = TAB_SOURCE_SCROLLS;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen      = { false };
local dataLoaded  = false;
local bitmasks    = {};
local selectedCat = nil;
local ROW_HEIGHT  = 26;

-- Representative icon per category
local CAT_ICONS = {
    ['White Magic'] = 4609,  -- Cure
    ['Black Magic'] = 4752,  -- Fire
    ['Summoning']   = 4896,  -- Fire Spirit
    ['Ninjutsu']    = 4928,  -- Katon: Ichi
    ['Songs']       = 4976,  -- Foe Requiem
    ['Dice']        = 5477,  -- Warrior Die
    ['Geomancy']    = 6073,  -- Indi-Regen
};

-- Spell name -> spell ID lookup (built on init, for "learned" detection)
local spellNameToId = {};
local spellMapBuilt = false;

local function normalize(name)
    return name:gsub("'", ''):lower();
end

local function buildSpellMap()
    if spellMapBuilt then return; end
    spellMapBuilt = true;
    local resMgr = AshitaCore:GetResourceManager();
    for i = 0, 1024 do
        local spell = resMgr:GetSpellById(i);
        if spell and spell.Name and spell.Name[1] and spell.Name[1] ~= '' then
            spellNameToId[normalize(spell.Name[1])] = i;
        end
    end
end

local function isSpellLearned(spellName)
    local spellId = spellNameToId[normalize(spellName)];
    if spellId == nil then return false; end
    return AshitaCore:GetMemoryManager():GetPlayer():HasSpell(spellId);
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function hasBit(mask, bitIndex)
    return bit.band(mask, bit.lshift(1, bitIndex)) ~= 0;
end

local function countOwned(catIdx)
    local cat = CATEGORIES[catIdx];
    local owned, total = 0, 0;
    local offset = 0;
    for i = 1, catIdx - 1 do
        offset = offset + #CATEGORIES[i].pages;
    end
    for pageIdx, page in ipairs(cat.pages) do
        local mask = bitmasks[offset + pageIdx] or 0;
        for i = 0, #page - 1 do
            total = total + 1;
            if hasBit(mask, i) then owned = owned + 1; end
        end
    end
    return owned, total;
end

local function getPageOffset(catIdx, pageIdx)
    local offset = 0;
    for i = 1, catIdx - 1 do
        offset = offset + #CATEGORIES[i].pages;
    end
    return offset + pageIdx;
end

------------------------------------------------------------
-- Render: Category list
------------------------------------------------------------
local function renderCategoryList()
    if not dataLoaded then
        ui.dim('Loading...');
        return;
    end

    if ui.button('Refresh', 60, 22) then
        dataLoaded = false;
        sendScrollRequest();
    end
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##scroll_cats', { -1, -1 }, false);
    for catIdx, cat in ipairs(CATEGORIES) do
        local owned, total = countOwned(catIdx);
        local pct = total > 0 and math.floor(owned / total * 100) or 0;
        local subtitle = string.format('%d / %d (%d%%)', owned, total, pct);
        local iconId = CAT_ICONS[cat.name];
        if iconId then renderIcon(iconId, 28); imgui.SameLine(0, 6); end
        if ui.categoryButton(cat.name, subtitle, catIdx) then
            selectedCat = catIdx;
        end
        imgui.Spacing();
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Render: Scroll list for a category
------------------------------------------------------------
local function renderScrollList()
    local cat = CATEGORIES[selectedCat];

    if ui.button('< Back', 55, 22) then
        selectedCat = nil;
        return;
    end
    imgui.SameLine();
    local owned, total = countOwned(selectedCat);
    ui.colored(cat.name, 'header');
    imgui.SameLine();
    ui.dim(string.format('(%d/%d)', owned, total));
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##scroll_list', { -1, -1 }, false);
    for pageIdx, page in ipairs(cat.pages) do
        local maskIdx = getPageOffset(selectedCat, pageIdx);
        local mask = bitmasks[maskIdx] or 0;
        local pageOwned = 0;
        for i = 0, #page - 1 do
            if hasBit(mask, i) then pageOwned = pageOwned + 1; end
        end

        ui.sectionHeader(string.format('Page %d', pageIdx), pageOwned);
        imgui.Spacing();

        for i, scroll in ipairs(page) do
            local spellName = scroll[1];
            local itemId    = scroll[2];
            local has       = hasBit(mask, i - 1);
            local learned   = isSpellLearned(spellName);
            local isAlt     = (i % 2 == 0);

            local base = ui.color('childBg');
            local bgColor;
            if learned then
                bgColor = { 0.12, 0.25, 0.12, 0.50 };
            elseif isAlt then
                bgColor = { base[1], base[2], base[3], 0.35 };
            else
                bgColor = { base[1], base[2], base[3], 0.20 };
            end

            local rowId = string.format('##sr_%d_%d_%d', selectedCat, pageIdx, i);
            imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
            imgui.BeginChild(rowId, { -1, ROW_HEIGHT }, false);

            imgui.SetCursorPos({ 4, 1 });
            renderIcon(itemId, 22);
            imgui.SameLine(0, 6);

            imgui.SetCursorPosY(0);
            imgui.Selectable(string.format('##ssel_%d_%d_%d', selectedCat, pageIdx, i), false,
                ImGuiSelectableFlags_SpanAllColumns, { 0, ROW_HEIGHT });
            local hovered = imgui.IsItemHovered();

            -- Draw name via drawlist
            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            local nameColor = has
                and (ui.color('green') or { 0.4, 0.9, 0.4, 1.0 })
                or  (ui.color('dimmed') or { 0.4, 0.4, 0.4, 1.0 });
            dl:AddText({ wx + 30, wy + 6 }, imgui.GetColorU32(nameColor), spellName);

            -- Status badges (right-aligned, drawn via drawlist)
            local ww = imgui.GetWindowWidth();
            local badgeX = wx + ww;
            local badgeY = wy + 4;
            local badgeH = 16;
            local badgePad = 4;

            local function drawBadge(text, fg, bg)
                local tw = imgui.CalcTextSize(text);
                local bw = tw + badgePad * 2;
                badgeX = badgeX - bw - 4;
                dl:AddRectFilled({ badgeX, badgeY }, { badgeX + bw, badgeY + badgeH }, imgui.GetColorU32(bg), 3);
                dl:AddText({ badgeX + badgePad, badgeY + 1 }, imgui.GetColorU32(fg), text);
            end

            if has then
                drawBadge('Stored', { 0.30, 0.85, 0.30, 1.0 }, { 0.15, 0.30, 0.15, 0.80 });
            end
            if learned then
                drawBadge('Learned', { 0.40, 0.75, 1.0, 1.0 }, { 0.12, 0.20, 0.35, 0.80 });
            end

            imgui.EndChild();

            if hovered then
                -- Use shared tooltip for full item details (description, jobs, level)
                if renderTooltip then
                    renderTooltip({ id = itemId, name = spellName });
                end
                -- Append status as a separate tooltip line
                -- (The shared tooltip handles BeginTooltip/EndTooltip,
                --  so we add status via the item row's right-side indicator instead)
            end

            imgui.PopStyleColor(1);
        end
        imgui.Spacing();
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Main render
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    if not dataLoaded and not bitmasks[1] then
        sendScrollRequest();
        bitmasks[1] = 0;
    end

    imgui.SetNextWindowSize({ 380, 500 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 320, 400 }, { 500, 800 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin('Scrolls###trove_scrolls', isOpen, ImGuiWindowFlags_None) then
        local _bgPop = ui.renderBackground();
        if selectedCat then
            renderScrollList();
        else
            renderCategoryList();
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
    name        = 'Scrolls',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Scroll collection tracker (Crystal Warrior)',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi, sharedRenderTooltip)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
        renderTooltip = sharedRenderTooltip;
        buildSpellMap();
    end,

    commands = {
        scrolls = function(state, args)
            isOpen[1] = not isOpen[1];
        end,
    },

    window = {
        category = 'Storage',
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Scrolls',
        icon    = 4609, -- Scroll of Cure
    },

    onPacketIn = function(e, state)
        if e.id ~= 0x1A4 then return; end

        local action = struct.unpack('B', e.data_modified, 0x04 + 1);
        if action ~= S2C_TAB_SUMMARY then return; end

        local source = struct.unpack('B', e.data_modified, 0x06 + 1);
        if source ~= TAB_SOURCE_SCROLLS then return; end

        local entryCount = struct.unpack('B', e.data_modified, 0x05 + 1);
        bitmasks = {};
        local offset = 0x08;
        for i = 1, entryCount do
            local b1 = struct.unpack('B', e.data_modified, offset + 1);
            local b2 = struct.unpack('B', e.data_modified, offset + 2);
            local b3 = struct.unpack('B', e.data_modified, offset + 3);
            local b4 = struct.unpack('B', e.data_modified, offset + 4);
            local mask = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216;
            table.insert(bitmasks, mask);
            offset = offset + 4;
        end
        dataLoaded = true;
    end,
};
