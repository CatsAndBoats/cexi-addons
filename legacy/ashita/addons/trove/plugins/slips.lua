--[[
* trove/plugins/slips.lua — Storage Slip browser
*
* Pure client-side plugin. Reads slip Extra data from inventory to show
* which items are stored on each Mog Storage Slip.
*
* Category view: all 28 slips with stored/total counts, lit up if owned
* Detail view: all items on a slip, green if stored
*
* Command: /trove slips
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;

------------------------------------------------------------
-- Data
------------------------------------------------------------
local SLIP_DATA = require('data/slip_data');

-- Build ordered list of slips
local SLIPS = {};
for i = 1, 28 do
    local slipId = 29312 + i - 1;
    if SLIP_DATA[slipId] then
        SLIPS[#SLIPS + 1] = {
            id    = slipId,
            num   = i,
            label = string.format('Storage Slip %02d', i),
            items = SLIP_DATA[slipId],
        };
    end
end

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen       = { false };
local wasOpen      = false;
local selectedSlip = nil;     -- index into SLIPS
local scanned      = false;
local slipOwned    = {};      -- [slipId] = true if player has the slip
local slipStored   = {};      -- [slipId] = { [itemId] = true }
local slipCounts   = {};      -- [slipId] = number of items stored

------------------------------------------------------------
-- Containers to scan
------------------------------------------------------------
local CONTAINERS = {
    { id = 0,  name = 'Inventory' },
    { id = 1,  name = 'Safe' },
    { id = 2,  name = 'Storage' },
    { id = 4,  name = 'Locker' },
    { id = 5,  name = 'Satchel' },
    { id = 6,  name = 'Sack' },
    { id = 7,  name = 'Case' },
    { id = 8,  name = 'Wardrobe' },
    { id = 9,  name = 'Safe 2' },
    { id = 10, name = 'Wardrobe 2' },
    { id = 11, name = 'Wardrobe 3' },
    { id = 12, name = 'Wardrobe 4' },
    { id = 13, name = 'Wardrobe 5' },
    { id = 14, name = 'Wardrobe 6' },
    { id = 15, name = 'Wardrobe 7' },
    { id = 16, name = 'Wardrobe 8' },
};

------------------------------------------------------------
-- Scan inventory for slips and their stored items
------------------------------------------------------------
local function scanSlips()
    slipOwned  = {};
    slipStored = {};
    slipCounts = {};

    -- Init
    for _, slip in ipairs(SLIPS) do
        slipStored[slip.id] = {};
        slipCounts[slip.id] = 0;
    end

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then
        scanned = true;
        return;
    end

    for _, container in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(container.id);
        if max ~= nil and max > 0 then
            for j = 0, max do
                local ok, item = pcall(function() return inventory:GetContainerItem(container.id, j); end);
                if ok and item ~= nil and item.Id ~= 0 and item.Id ~= 65535 then
                    -- Check if this is a storage slip
                    if SLIP_DATA[item.Id] then
                        slipOwned[item.Id] = true;

                        -- Parse Extra bitmask
                        local extra = item.Extra;
                        if extra ~= nil then
                            local items = SLIP_DATA[item.Id];
                            for idx, itemId in ipairs(items) do
                                local byteIndex = math.floor((idx - 1) / 8) + 1;
                                local bitPos    = (idx - 1) % 8;
                                local byte = struct.unpack('B', extra, byteIndex);
                                if bit.band(bit.rshift(byte, bitPos), 1) ~= 0 then
                                    slipStored[item.Id][itemId] = true;
                                    slipCounts[item.Id] = slipCounts[item.Id] + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    scanned = true;
end

------------------------------------------------------------
-- Colors
------------------------------------------------------------
local COL = {
    owned   = { 0.55, 0.90, 0.55, 1.00 },
    unowned = { 0.45, 0.45, 0.50, 0.70 },
    stored  = { 0.18, 0.32, 0.18, 0.50 },
};

------------------------------------------------------------
-- Render: category list (all slips)
------------------------------------------------------------
local COLS = 3;

local function renderSlipList()
    local totalStored = 0;
    local totalItems  = 0;
    for _, slip in ipairs(SLIPS) do
        totalStored = totalStored + (slipCounts[slip.id] or 0);
        totalItems  = totalItems + #slip.items;
    end

    ui.header(string.format('Mog Storage Slips  %d/%d', totalStored, totalItems));
    imgui.Spacing();

    local fullW = imgui.GetContentRegionAvail();
    local gap   = 6;
    local cardW = math.floor((fullW - gap * (COLS - 1)) / COLS);
    local cardH = 48;

    for i, slip in ipairs(SLIPS) do
        local owned = slipOwned[slip.id];
        local count = slipCounts[slip.id] or 0;
        local total = #slip.items;
        local full  = (count >= total);

        -- Grid layout
        local col = (i - 1) % COLS;
        if col > 0 then imgui.SameLine(0, gap); end

        local base = ui.color('childBg');
        local bgColor;
        if full then
            bgColor = { 0.15, 0.28, 0.15, 0.90 };
        elseif owned then
            bgColor = { base[1] + 0.04, base[2] + 0.04, base[3] + 0.06, 0.90 };
        else
            bgColor = { base[1], base[2], base[3], 0.50 };
        end

        local btnId = string.format('##slip_cat_%d', i);
        imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
        imgui.BeginChild(btnId, { cardW, cardH }, false, ImGuiWindowFlags_NoScrollbar);

        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();

        -- Accent bar
        local barCol = full and COL.owned or (owned and ui.color('accent') or COL.unowned);
        dl:AddRectFilled({ wx, wy }, { wx + 3, wy + cardH }, imgui.GetColorU32(barCol));

        -- Icon
        imgui.SetCursorPos({ 7, 12 });
        renderIcon(slip.id, 24);

        -- Selectable overlay
        imgui.SetCursorPos({ 0, 0 });
        local clicked = imgui.Selectable(string.format('##slipsel_%d', i), false,
            ImGuiSelectableFlags_SpanAllColumns, { 0, cardH });

        -- Short label
        local shortLabel = string.format('Slip %02d', slip.num);
        local nameCol = owned and ui.color('white') or COL.unowned;
        dl:AddText({ wx + 34, wy + 6 }, imgui.GetColorU32(nameCol), shortLabel);

        -- Count
        local countStr = string.format('%d/%d', count, total);
        local countCol = full and COL.owned or (count > 0 and ui.color('white') or ui.color('dimmed'));
        dl:AddText({ wx + 34, wy + 22 }, imgui.GetColorU32(countCol), countStr);

        imgui.EndChild();
        imgui.PopStyleColor(1);

        if clicked then
            selectedSlip = i;
        end
    end
end

------------------------------------------------------------
-- Render: detail view (items on one slip)
------------------------------------------------------------
local function renderSlipDetail()
    local slip = SLIPS[selectedSlip];
    if slip == nil then
        selectedSlip = nil;
        return;
    end

    local stored = slipStored[slip.id] or {};
    local count  = slipCounts[slip.id] or 0;
    local total  = #slip.items;

    -- Breadcrumb
    imgui.PushStyleColor(ImGuiCol_Button, { 0, 0, 0, 0 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.3, 0.2, 0.4, 0.3 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.3, 0.2, 0.4, 0.5 });
    if imgui.SmallButton('Slips##bc') then
        selectedSlip = nil;
    end
    imgui.PopStyleColor(3);
    imgui.SameLine(0, 4);
    ui.dim('>');
    imgui.SameLine(0, 4);
    imgui.TextColored(ui.color('white'), string.format('%s  (%d/%d)', slip.label, count, total));
    imgui.Separator();
    imgui.Spacing();

    -- Item list — text-only rows, no D3D textures per row.
    -- Icons are shown only in the tooltip (one at a time) to avoid
    -- bulk texture creation that crashes on slips with 200+ items.
    local ROW_H = 22;
    local hoveredItem = nil;

    imgui.BeginChild('##slip_detail_list', { -1, -1 }, false);

    local scrollY  = imgui.GetScrollY();
    local visibleH = imgui.GetWindowHeight();
    local dl = imgui.GetWindowDrawList();

    for idx, itemId in ipairs(slip.items) do
        local rowTop = (idx - 1) * ROW_H;
        local isVisible = (rowTop + ROW_H > scrollY) and (rowTop < scrollY + visibleH);

        -- Selectable sizes the row and handles hover
        imgui.SetCursorPosY(rowTop);
        imgui.Selectable(string.format('##slipsel_%d_%d', slip.id, idx), false,
            ImGuiSelectableFlags_SpanAllColumns, { 0, ROW_H });

        if isVisible then
            local isStored = stored[itemId] or false;
            local res = getItemRes(itemId);
            local name = (res and res.Name and res.Name[1]) or string.format('Item %d', itemId);
            local hovered = imgui.IsItemHovered();

            local rx, ry = imgui.GetItemRectMin();
            local rx2, ry2 = imgui.GetItemRectMax();

            -- Row background
            local base = ui.color('childBg');
            local bgColor = isStored
                and COL.stored
                or  { base[1], base[2], base[3], (idx % 2 == 0) and 0.35 or 0.20 };
            dl:AddRectFilled({ rx, ry }, { rx2, ry2 }, imgui.GetColorU32(bgColor));

            -- Stored dot on left
            if isStored then
                dl:AddCircleFilled({ rx + 10, ry + ROW_H / 2 }, 4,
                    imgui.GetColorU32(COL.owned));
            else
                dl:AddCircle({ rx + 10, ry + ROW_H / 2 }, 4,
                    imgui.GetColorU32(COL.unowned), 12);
            end

            -- Name
            local nameCol = isStored and COL.owned or COL.unowned;
            dl:AddText({ rx + 22, ry + 4 }, imgui.GetColorU32(nameCol), name);

            -- Stored badge on right
            if isStored then
                local badgeText = 'Stored';
                local badgeW = imgui.CalcTextSize(badgeText) + 8;
                local badgeX = rx2 - badgeW - 6;
                local badgeY = ry + 3;
                dl:AddRectFilled({ badgeX, badgeY }, { badgeX + badgeW, badgeY + 16 },
                    imgui.GetColorU32({ 0.10, 0.30, 0.10, 0.80 }), 3);
                dl:AddText({ badgeX + 4, badgeY + 1 }, imgui.GetColorU32(COL.owned), badgeText);
            end

            if hovered and res then
                hoveredItem = { id = itemId, stored = isStored, res = res, name = name };
            end
        end
    end

    imgui.EndChild();

    -- Tooltip rendered outside scroll child
    if hoveredItem then
        local hi = hoveredItem;
        imgui.BeginTooltip();
        imgui.PushTextWrapPos(300);

        if renderIcon(hi.id, 32) then
            imgui.SameLine();
        end
        imgui.TextColored(ui.color('header'), hi.name);
        imgui.Separator();

        local flags = hi.res.Flags or 0;
        if bit.band(flags, 0x8000) ~= 0 then
            imgui.TextColored({ 1.00, 0.85, 0.30, 1.00 }, 'Rare');
            imgui.SameLine();
        end
        if bit.band(flags, 0x4000) ~= 0 then
            imgui.TextColored({ 0.40, 0.90, 0.40, 1.00 }, 'Ex');
        end

        if hi.res.Description and hi.res.Description[1] and hi.res.Description[1] ~= '' then
            imgui.Spacing();
            imgui.TextColored(ui.color('dimmed'), hi.res.Description[1]);
        end

        if hi.res.Level and hi.res.Level > 0 then
            imgui.Spacing();
            imgui.TextColored({ 0.55, 0.75, 0.55, 1.00 }, string.format('Lv.%d', hi.res.Level));
        end

        imgui.Spacing();
        if hi.stored then
            imgui.TextColored(COL.owned, 'Stored on ' .. slip.label);
        else
            imgui.TextColored(COL.unowned, 'Not stored');
        end

        imgui.PopTextWrapPos();
        imgui.EndTooltip();
    end
end

------------------------------------------------------------
-- Main window
------------------------------------------------------------
local function renderWindow()
    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 480, 520 }, ImGuiCond_FirstUseEver);

    if imgui.Begin('Storage Slips##trove_slips', isOpen, 0) then

        -- Rescan on open transition
        if not wasOpen then
            wasOpen = true;
            scanned = false;
        end

        if not scanned then
            scanSlips();
        end

        imgui.BeginChild('##slips_scroll', { 0, 0 }, false);

        if selectedSlip then
            renderSlipDetail();
        else
            renderSlipList();
        end

        imgui.EndChild();
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Storage Slips',
    description = 'Browse Mog Storage Slip contents',

    init = function(iconFn, itemResFn, uiModule)
        renderIcon = iconFn;
        getItemRes = itemResFn;
        ui         = uiModule;
    end,

    commands = {
        slips = function(state) isOpen[1] = not isOpen[1]; end,
    },

    onRender = function(state)
        if not isOpen[1] then
            wasOpen = false;
        end
    end,

    window = {
        isOpen = isOpen,
        label  = 'Storage Slips',
        icon   = 29312,  -- Slip 01
        render = renderWindow,
    },
};
