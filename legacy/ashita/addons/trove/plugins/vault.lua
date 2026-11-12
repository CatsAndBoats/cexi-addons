--[[
* trove/plugins/vault.lua — Vault Browser
*
* Displays Mog Vault Deposit Boxes and Wardrobe contents.
* Uses the generic tab protocol (TAB_SOURCE = 1).
* Supports item withdrawal (action 15) and deposit (action 18).
*
* Command: /trove vault
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
-- State
------------------------------------------------------------
local isOpen          = { false };
local selectedCat     = nil;
local summary         = {};
local summaryLoaded   = false;
local items           = {};
local itemsLoaded     = false;
local searchBuf       = { '' };

-- Selection + withdraw state
local selectedItem     = nil;     -- index into items[]
local operationCooldown = 0;
local COOLDOWN_SEC     = 2.0;
local statusMsg        = '';
local statusTime       = 0;
local statusIsErr      = false;
local pendingOp        = nil;     -- 'withdraw' or 'deposit'

-- Deposit state
local depositItems       = {};
local depositItemsLoaded = false;
local depositSearchBuf   = { '' };
local depositPopupItem   = nil;   -- item for container picker popup

------------------------------------------------------------
-- Protocol
------------------------------------------------------------
local PACKET_ID            = 0x1A4;
local C2S_TAB_SUMMARY     = 13;
local C2S_TAB_CATEGORY     = 14;
local C2S_VAULT_WITHDRAW   = 15;
local C2S_VAULT_DEPOSIT    = 16;
local S2C_TAB_SUMMARY     = 12;
local S2C_TAB_ENTRY        = 8;
local S2C_END_LIST         = 2;
local S2C_ACK              = 3;
local TAB_SOURCE_VAULT     = 1;
local VAULT_MAX_SIZE       = 80;

-- Item flags (from item_basic)
local FLAG_CANEQUIP = 0x0800;
local FLAG_RARE     = 0x8000;

local function makePacket()
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    return p;
end

local function sendVaultSummary()
    local p = makePacket();
    p[5] = C2S_TAB_SUMMARY;
    p[7] = TAB_SOURCE_VAULT;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

local function sendVaultCategory(categoryName)
    local p = makePacket();
    p[5] = C2S_TAB_CATEGORY;
    p[7] = TAB_SOURCE_VAULT;
    local bytes = { string.byte(categoryName, 1, 20) };
    for i = 1, math.min(#bytes, 20) do p[8 + i] = bytes[i]; end
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

local function sendVaultWithdraw(locId, slotId)
    local p = makePacket();
    p[5] = C2S_VAULT_WITHDRAW;
    p[7] = locId;
    p[8] = slotId;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
    operationCooldown = os.clock() + COOLDOWN_SEC;
    pendingOp = 'withdraw';
end

local function sendVaultDeposit(locId, invSlot)
    local p = makePacket();
    p[5] = C2S_VAULT_DEPOSIT;
    p[7] = locId;
    p[8] = invSlot;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
    operationCooldown = os.clock() + COOLDOWN_SEC;
    pendingOp = 'deposit';
end

------------------------------------------------------------
-- Packet reading helpers
------------------------------------------------------------
local function readU16(data, offset)
    local lo = struct.unpack('B', data, offset + 1);
    local hi = struct.unpack('B', data, offset + 2);
    return lo + hi * 256;
end

local function readString(data, offset, maxLen)
    local s = '';
    for i = 0, maxLen - 1 do
        local b = struct.unpack('B', data, offset + i + 1);
        if b == 0 then break; end
        s = s .. string.char(b);
    end
    return s;
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function isOnCooldown()
    return os.clock() < operationCooldown;
end

local function parseSubtype(subtype)
    local locId, slotId = subtype:match('(%d+):(%d+)');
    return tonumber(locId), tonumber(slotId);
end

-- Town zones where vault operations are allowed (matches server VAULT_ZONES)
local TOWN_ZONES = {
    [232]=true, [231]=true, [230]=true, -- San d'Oria
    [236]=true, [234]=true, [235]=true, -- Bastok
    [238]=true, [240]=true, [239]=true, [241]=true, -- Windurst
    [80]=true, [87]=true, [94]=true,    -- [S] cities
    [248]=true, [247]=true, [252]=true, -- Selbina, Rabao, Norg
    [243]=true, [244]=true, [245]=true, [246]=true, -- Jeuno
    [237]=true,             -- Metalworks
    [249]=true, [250]=true, -- Mhaura, Kazham
    [48]=true, [50]=true, [53]=true,  -- Al Zahbi, Whitegate, Nashmau
    [26]=true,              -- Tavnazian Safehold
    [284]=true, [281]=true, [222]=true, -- Celennia, Leafallia, Provenance
};

-- Withdraw cost lookup (swap_cost / 5, indexed by numUpgrades = numContainers - 2)
local WITHDRAW_COSTS = {
    [0]=2000, 1700, 1400, 1100, 1000, 900, 800, 700,
    600, 500, 400, 300, 200, 150, 100, 50, 20, 10, 0,
};

local function isInTown()
    local zoneId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
    return TOWN_ZONES[zoneId] == true;
end

local function getWithdrawCost()
    local numContainers = #summary;
    local numUpgrades = math.max(0, math.min(numContainers - 2, 18));
    return WITHDRAW_COSTS[numUpgrades] or 2000;
end

-- Map summary category name to vault location ID
local function categoryToLocId(category)
    local letter = category:match('Deposit Box (%a)');
    if letter then
        -- VAULTSTORAGE_A = 19, B = 20, ...
        return 19 + (string.byte(letter) - string.byte('A'));
    end
    letter = category:match('Wardrobe (%a)');
    if letter then
        -- VAULTWARDROBE_A = 45, B = 46, ...
        return 45 + (string.byte(letter) - string.byte('A'));
    end
    return nil;
end

------------------------------------------------------------
-- Inventory scanning (for deposit tab)
------------------------------------------------------------
local function scanInventory()
    depositItems = {};
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    local resMgr = AshitaCore:GetResourceManager();
    if not inventory then
        depositItemsLoaded = true;
        return;
    end

    local max = inventory:GetContainerCountMax(0); -- container 0 = inventory
    if not max or max == 0 then
        depositItemsLoaded = true;
        return;
    end

    for i = 1, max - 1 do -- skip slot 0 (gil)
        local ok, item = pcall(function() return inventory:GetContainerItem(0, i); end);
        if ok and item and item.Id ~= 0 and item.Id ~= 65535 then
            local id = item.Id;
            -- Skip storage slips (29312-29339)
            if id < 29312 or id > 29339 then
                local res = resMgr:GetItemById(id);
                local name = (res and res.Name and res.Name[1]) or '???';
                local flags = (res and res.Flags) or 0;
                table.insert(depositItems, {
                    id      = id,
                    name    = name,
                    qty     = item.Count or 1,
                    slot    = i,
                    isEquip = bit.band(flags, FLAG_CANEQUIP) ~= 0,
                    isRare  = bit.band(flags, FLAG_RARE) ~= 0,
                });
            end
        end
    end

    -- Sort alphabetically by name
    table.sort(depositItems, function(a, b) return a.name:lower() < b.name:lower(); end);
    depositItemsLoaded = true;
end

------------------------------------------------------------
-- Render: Summary view (Withdraw tab)
------------------------------------------------------------
local function renderSummary()
    if summaryLoaded ~= true then
        ui.dim('Loading...');
        return;
    end

    if #summary == 0 then
        ui.dim('No vault containers unlocked.');
        return;
    end

    if ui.button('Refresh', 0, 22) then
        summaryLoaded = false;
        sendVaultSummary();
    end
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##vault_summary', { -1, -1 }, false);
    for i, entry in ipairs(summary) do
        local subtitle = string.format('%d / %d items', entry.count, VAULT_MAX_SIZE);
        local isWardrobe = entry.category:find('Wardrobe');
        local iconId = isWardrobe and 61 or 46; -- Armoire / Armor Box

        renderIcon(iconId, 28);
        imgui.SameLine(0, 6);

        if ui.categoryButton(entry.category, subtitle, i) then
            selectedCat = entry.category;
            selectedItem = nil;
            items = {};
            itemsLoaded = false;
            searchBuf = { '' };
            sendVaultCategory(entry.category);
        end
        imgui.Spacing();
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Render: Item list view (Withdraw tab)
------------------------------------------------------------
local function renderItems()
    if ui.button('< Back', 0, 22) then
        selectedCat = nil;
        selectedItem = nil;
        items = {};
        itemsLoaded = false;
        searchBuf = { '' };
        return;
    end
    imgui.SameLine();
    ui.colored(selectedCat, 'header');
    imgui.SameLine();
    ui.dim(string.format('(%d)', #items));

    -- Refresh
    imgui.SameLine(imgui.GetWindowWidth() - 72);
    if ui.button('Refresh', 0, 22) then
        items = {};
        itemsLoaded = false;
        selectedItem = nil;
        sendVaultCategory(selectedCat);
    end

    imgui.Separator();
    imgui.Spacing();

    if not itemsLoaded then
        ui.dim('Loading...');
        return;
    end

    if #items == 0 then
        ui.dim('Empty.');
        return;
    end

    -- Search filter
    imgui.PushItemWidth(-1);
    imgui.InputText('##vault_search', searchBuf, 256);
    imgui.PopItemWidth();
    imgui.Spacing();

    local filter = searchBuf[1]:lower();

    -- Bottom panel height for selection
    local bottomH = selectedItem and 50 or 0;

    imgui.BeginChild('##vault_items', { -1, -1 - bottomH }, false);
    local idx = 0;
    for i, item in ipairs(items) do
        local res = getItemRes(item.iconId);
        local name = (res and res.Name and res.Name[1]) or item.name or '???';
        if filter == '' or name:lower():find(filter, 1, true) then
            idx = idx + 1;
            local isSelected = (selectedItem == i);

            local base = ui.color('childBg');
            local bgColor;
            if isSelected then
                bgColor = { base[1] + 0.08, base[2] + 0.06, base[3] + 0.12, 0.90 };
            elseif idx % 2 == 0 then
                bgColor = { base[1], base[2], base[3], 0.35 };
            else
                bgColor = { base[1], base[2], base[3], 0.20 };
            end

            local rowId = string.format('##vr_%d', i);
            imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
            imgui.BeginChild(rowId, { -1, 28 }, false);

            imgui.SetCursorPos({ 4, 1 });
            renderIcon(item.iconId, 24);
            imgui.SameLine(32);

            imgui.SetCursorPosY(0);
            if imgui.Selectable(string.format('##vsel_%d', i), isSelected,
                ImGuiSelectableFlags_SpanAllColumns, { 0, 28 }) then
                selectedItem = isSelected and nil or i;
            end

            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddText({ wx + 32, wy + 7 }, imgui.GetColorU32(ui.color('white')), name);

            if item.tier and item.tier ~= '' and item.tier ~= '1' then
                local qtyStr = 'x' .. item.tier;
                local nameW = imgui.CalcTextSize(name);
                dl:AddText({ wx + 34 + nameW, wy + 7 }, imgui.GetColorU32(ui.color('dimmed')), ' ' .. qtyStr);
            end

            imgui.EndChild();
            imgui.PopStyleColor(1);

            if imgui.IsItemHovered() and renderTooltip then
                renderTooltip({ id = item.iconId, name = name, qty = tonumber(item.tier) or 1 });
            end
        end
    end
    imgui.EndChild();

    -- Bottom panel: selected item + withdraw button
    if selectedItem and items[selectedItem] then
        local item = items[selectedItem];
        local res = getItemRes(item.iconId);
        local name = (res and res.Name and res.Name[1]) or item.name or '???';
        local cooldown = isOnCooldown();
        local inTown = isInTown();
        local hasSlot = item.locId and item.slotId;
        local cost = getWithdrawCost();

        -- Determine withdraw state
        local canWithdraw = hasSlot and inTown and not cooldown;
        local reason = nil;
        if not hasSlot then
            reason = 'Item data unavailable.';
        elseif not inTown then
            reason = 'You must be in a town to withdraw.';
        elseif cooldown then
            reason = 'Please wait...';
        end

        imgui.Separator();
        imgui.Spacing();

        renderIcon(item.iconId, 24);
        imgui.SameLine(0, 6);
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 4);
        ui.colored(name, 'white');

        imgui.SameLine(imgui.GetWindowWidth() - 90);
        imgui.SetCursorPosY(imgui.GetCursorPosY() - 4);

        if not canWithdraw then
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35);
        end

        if ui.button('Withdraw', 0, 26) and canWithdraw then
            sendVaultWithdraw(item.locId, item.slotId);
        end

        if not canWithdraw then
            imgui.PopStyleVar();
        end

        -- Tooltip on withdraw button (always shows cost, shows reason if greyed)
        if imgui.IsItemHovered() then
            ui.tooltip(function()
                if reason then
                    imgui.TextColored({ 1, 0.5, 0.5, 1 }, reason);
                    imgui.Separator();
                end
                renderIcon(65535, 16);
                imgui.SameLine(0, 4);
                if cost > 0 then
                    imgui.TextColored({ 1.0, 0.85, 0.35, 1.0 }, string.format('Cost: %s gil', tostring(cost)));
                else
                    imgui.TextColored({ 0.4, 1.0, 0.4, 1.0 }, 'Free');
                end
            end);
        end

        -- Status message
        if statusMsg ~= '' and os.clock() < statusTime + 3 then
            imgui.SetCursorPosX(8);
            if statusIsErr then
                imgui.TextColored({ 1, 0.4, 0.4, 1 }, statusMsg);
            else
                imgui.TextColored({ 0.4, 1, 0.4, 1 }, statusMsg);
            end
        end
    end
end

------------------------------------------------------------
-- Render: Deposit tab
------------------------------------------------------------
local function renderDepositTab()
    if summaryLoaded ~= true then
        ui.dim('Loading...');
        return;
    end

    if #summary == 0 then
        ui.dim('No vault containers unlocked.');
        return;
    end

    if not depositItemsLoaded then
        scanInventory();
    end

    -- Header row: Refresh + zone warning
    if ui.button('Refresh', 0, 22) then
        scanInventory();
        summaryLoaded = false;
        sendVaultSummary();
    end

    if not isInTown() then
        imgui.SameLine(0, 8);
        imgui.TextColored({ 1, 0.5, 0.5, 1 }, 'Must be in a town.');
    end

    imgui.Separator();
    imgui.Spacing();

    if #depositItems == 0 then
        ui.dim('No items to deposit.');
        return;
    end

    -- Search filter
    imgui.PushItemWidth(-1);
    imgui.InputText('##deposit_search', depositSearchBuf, 256);
    imgui.PopItemWidth();
    imgui.Spacing();

    local filter = depositSearchBuf[1]:lower();

    -- Status message height
    local statusH = (statusMsg ~= '' and os.clock() < statusTime + 3) and 22 or 0;

    -- Item list
    local clickedItem = nil;

    imgui.BeginChild('##deposit_items', { -1, -1 - statusH }, false);
    local idx = 0;
    for i, item in ipairs(depositItems) do
        if filter == '' or item.name:lower():find(filter, 1, true) then
            idx = idx + 1;
            local isAlt = (idx % 2 == 0);

            local base = ui.color('childBg');
            local bgColor = isAlt
                and { base[1], base[2], base[3], 0.35 }
                or  { base[1], base[2], base[3], 0.20 };

            local rowId = string.format('##dr_%d', i);
            imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
            imgui.BeginChild(rowId, { -1, 28 }, false);

            imgui.SetCursorPos({ 4, 1 });
            renderIcon(item.id, 24);
            imgui.SameLine(32);

            imgui.SetCursorPosY(0);
            local rowClicked = imgui.Selectable(string.format('##dsel_%d', i), false,
                ImGuiSelectableFlags_SpanAllColumns, { 0, 28 });

            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddText({ wx + 32, wy + 7 }, imgui.GetColorU32(ui.color('white')), item.name);

            if item.qty > 1 then
                local nameW = imgui.CalcTextSize(item.name);
                dl:AddText({ wx + 34 + nameW, wy + 7 }, imgui.GetColorU32(ui.color('dimmed')),
                    ' x' .. item.qty);
            end

            imgui.EndChild();
            imgui.PopStyleColor(1);

            if imgui.IsItemHovered() and renderTooltip then
                renderTooltip({ id = item.id, name = item.name, qty = item.qty });
            end

            if rowClicked then
                clickedItem = item;
            end
        end
    end
    imgui.EndChild();

    -- Open popup after scroll child (so it's at window level)
    if clickedItem then
        depositPopupItem = clickedItem;
        imgui.OpenPopup('##container_picker');
    end

    -- Container picker popup
    if imgui.BeginPopup('##container_picker') then
        if depositPopupItem then
            local item = depositPopupItem;
            local inTown = isInTown();
            local cooldown = isOnCooldown();

            -- Header: item being deposited
            renderIcon(item.id, 22);
            imgui.SameLine(0, 6);
            ui.colored(item.name, 'white');
            if item.qty > 1 then
                imgui.SameLine(0, 4);
                ui.dim('x' .. item.qty);
            end
            imgui.Separator();
            imgui.Spacing();

            for ci, entry in ipairs(summary) do
                local locId = categoryToLocId(entry.category);
                local isWardrobe = entry.category:find('Wardrobe') ~= nil;
                local isFull = entry.count >= VAULT_MAX_SIZE;
                local cantEquip = isWardrobe and not item.isEquip;
                local disabled = isFull or cantEquip or not inTown or cooldown or not locId;

                local label = string.format('%s (%d/%d)', entry.category, entry.count, VAULT_MAX_SIZE);

                if disabled then
                    imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35);
                end

                if imgui.Selectable(label .. '###dep_' .. ci, false) then
                    if not disabled then
                        sendVaultDeposit(locId, item.slot);
                        imgui.CloseCurrentPopup();
                    end
                end

                if disabled and imgui.IsItemHovered() then
                    local reason = '';
                    if not inTown then reason = 'Must be in a town.';
                    elseif cooldown then reason = 'Please wait...';
                    elseif isFull then reason = 'Container full.';
                    elseif cantEquip then reason = 'Wardrobes only accept equipment.';
                    end
                    if reason ~= '' then
                        imgui.SetTooltip(reason);
                    end
                end

                if disabled then
                    imgui.PopStyleVar();
                end
            end
        end
        imgui.EndPopup();
    end

    -- Status message
    if statusMsg ~= '' and os.clock() < statusTime + 3 then
        imgui.SetCursorPosX(8);
        if statusIsErr then
            imgui.TextColored({ 1, 0.4, 0.4, 1 }, statusMsg);
        else
            imgui.TextColored({ 0.4, 1, 0.4, 1 }, statusMsg);
        end
    end
end

------------------------------------------------------------
-- Main render
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    if not summaryLoaded then
        sendVaultSummary();
        summaryLoaded = 'pending';
    end

    imgui.SetNextWindowSize({ 420, 500 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 350, 300 }, { 600, 800 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin('Vault###trove_vault', isOpen, ImGuiWindowFlags_None) then
        local _bgPop = ui.renderBackground();

        if imgui.BeginTabBar('##vault_tabs', ImGuiTabBarFlags_None) then

            if imgui.BeginTabItem('Withdraw') then
                if selectedCat then
                    renderItems();
                else
                    renderSummary();
                end
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Deposit') then
                renderDepositTab();
                imgui.EndTabItem();
            end

            imgui.EndTabBar();
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
    name        = 'Vault',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Browse Mog Vault deposit boxes and wardrobes',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi, sharedRenderTooltip)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
        renderTooltip = sharedRenderTooltip;
    end,

    commands = {
        vault = function(state, args)
            isOpen[1] = not isOpen[1];
            if isOpen[1] and not summaryLoaded then
                sendVaultSummary();
            end
        end,
    },

    window = {
        category = 'Storage',
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Vault',
        icon    = 26352,
    },

    onPacketIn = function(e, state)
        if e.id ~= PACKET_ID then return; end

        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        if action == S2C_TAB_SUMMARY then
            local source = struct.unpack('B', e.data_modified, 0x06 + 1);
            if source ~= TAB_SOURCE_VAULT then return; end

            local entryCount = struct.unpack('B', e.data_modified, 0x05 + 1);
            summary = {};
            local offset = 0x08;
            for i = 1, entryCount do
                local category = readString(e.data_modified, offset, 20);
                local count    = readU16(e.data_modified, offset + 20);
                table.insert(summary, { category = category, count = count });
                offset = offset + 22;
            end
            summaryLoaded = true;
            return;
        end

        if action == S2C_TAB_ENTRY then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            if source ~= TAB_SOURCE_VAULT then return; end

            local iconId   = readU16(e.data_modified, 0x06);
            local subtype  = readString(e.data_modified, 0x1C, 23);
            local name     = readString(e.data_modified, 0x34, 23);
            local tier     = readString(e.data_modified, 0x4C, 7);

            local locId, slotId = parseSubtype(subtype);

            table.insert(items, {
                iconId = iconId,
                name   = name,
                tier   = tier,
                locId  = locId,
                slotId = slotId,
            });
            return;
        end

        if action == S2C_END_LIST then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            if source ~= TAB_SOURCE_VAULT then return; end
            itemsLoaded = true;
            return;
        end

        if action == S2C_ACK and pendingOp ~= nil then
            local resultCode = struct.unpack('B', e.data_modified, 0x05 + 1);
            local opType     = struct.unpack('B', e.data_modified, 0x06 + 1);
            local msg = readString(e.data_modified, 0x10, 31);

            if pendingOp == 'deposit' or opType == 1 then
                -- Deposit ACK
                if resultCode == 0 then
                    if depositPopupItem then
                        print(string.format('\30\01Deposited: \30\02%s\30\01', depositPopupItem.name));
                    end
                    statusMsg = 'Deposited!';
                    statusIsErr = false;
                    statusTime = os.clock();

                    -- Refresh summary counts and inventory
                    summaryLoaded = false;
                    sendVaultSummary();
                    depositItemsLoaded = false;
                else
                    statusMsg = msg ~= '' and msg or 'Deposit failed.';
                    statusIsErr = true;
                    statusTime = os.clock();
                    operationCooldown = 0;
                end
                pendingOp = nil;
                return;
            end

            if pendingOp == 'withdraw' then
                -- Withdraw ACK
                if resultCode == 0 then
                    if selectedItem and items[selectedItem] then
                        local item = items[selectedItem];
                        local res = getItemRes(item.iconId);
                        local name = (res and res.Name and res.Name[1]) or item.name or '???';
                        print(string.format('\30\01Obtained: \30\02%s\30\01', name));
                    end

                    statusMsg = 'Withdrawn!';
                    statusIsErr = false;
                    statusTime = os.clock();
                    selectedItem = nil;
                    if selectedCat then
                        items = {};
                        itemsLoaded = false;
                        summaryLoaded = false;
                        sendVaultSummary();
                        sendVaultCategory(selectedCat);
                    end
                    -- Also invalidate deposit cache
                    depositItemsLoaded = false;
                else
                    statusMsg = msg ~= '' and msg or 'Withdraw failed.';
                    statusIsErr = true;
                    statusTime = os.clock();
                    operationCooldown = 0;
                end
                pendingOp = nil;
                return;
            end
        end
    end,
};
