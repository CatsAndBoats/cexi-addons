--[[
* trove/plugins/ebox.lua — Ephemeral Box tab
*
* Storage browser with category navigation, item search, item detail
* with withdrawal buttons, and Crystal Warrior gating. Extracted from
* the core trove.lua into a self-contained plugin.
*
* Commands: /trove box, /box
* Chat passthrough: !box → auto-refresh
]]--

local imgui = require('imgui');
local pkt   = require('utils/packet');

------------------------------------------------------------
-- Shared (injected via init / setContext)
------------------------------------------------------------
local renderIcon             = nil;
local getItemRes             = nil;
local ui                     = nil;  -- utils/ui module
local renderTooltip          = nil;
local renderFileIcon         = nil;
local renderFileImage        = nil;
local getIconHandle          = nil;
local getItemString          = nil;
local getSlotName            = nil;
local getJobList             = nil;
local addCommas              = nil;
local getRowBg               = nil;
local setStatus              = nil;
local renderBadges           = nil;
local renderItemDetail       = nil;
local renderColoredDescription = nil;
local AH_NAMES               = nil;
local CUSTOM_ORDER           = nil;
local FLAG_RARE              = 0x8000;
local FLAG_EX                = 0x4000;
local SLOT_NAMES             = {
    [0x0001] = 'Main',  [0x0002] = 'Sub',    [0x0004] = 'Range',
    [0x0008] = 'Ammo',  [0x0010] = 'Head',   [0x0020] = 'Body',
    [0x0040] = 'Hands', [0x0080] = 'Legs',   [0x0100] = 'Feet',
    [0x0200] = 'Neck',  [0x0400] = 'Waist',  [0x0800] = 'L.Ear',
    [0x1000] = 'R.Ear', [0x2000] = 'L.Ring', [0x4000] = 'R.Ring',
    [0x8000] = 'Back',
};
local WEAPON_SKILLS          = {
    [1] = 'Hand-to-Hand', [2] = 'Dagger',     [3] = 'Sword',
    [4] = 'Great Sword',  [5] = 'Axe',        [6] = 'Great Axe',
    [7] = 'Scythe',       [8] = 'Polearm',    [9] = 'Katana',
    [10] = 'Great Katana', [11] = 'Club',      [12] = 'Staff',
    [25] = 'Archery',     [26] = 'Marksmanship', [27] = 'Throwing',
};
local QTY_BUTTONS            = {
    { label = 'x1',  qty = 1  },
    { label = 'x3',  qty = 3  },
    { label = 'x6',  qty = 6  },
    { label = 'x12', qty = 12 },
    { label = 'x99', qty = 99 },
    { label = '...',  qty = 0  },
};

------------------------------------------------------------
-- Color proxy (maps key → theme color via ui.color)
------------------------------------------------------------
local COLOR_ALIASES = {
    btnWithdraw = 'btnPrimary',
    btnHover    = 'btnPrimaryHover',
    btnActive   = 'btnPrimaryActive',
    btnFeatureH = 'btnFeatureHover',
    btnFeatureA = 'btnFeatureActive',
    btnStoreH   = 'btnPositiveHover',
    btnStoreA   = 'btnPositiveActive',
    btnStore    = 'btnPositive',
    btnBackH    = 'btnBackHover',
    btnBackA    = 'btnBackActive',
};

local COLORS = setmetatable({}, {
    __index = function(_, key)
        if ui == nil then return { 1, 1, 1, 1 }; end
        local themeKey = COLOR_ALIASES[key] or key;
        return ui.color(themeKey);
    end,
});

------------------------------------------------------------
-- LOCKED reason codes (server → client)
------------------------------------------------------------
local LOCK_REASON_NOT_CW       = 1;
local LOCK_REASON_NOT_UNLOCKED = 2;

------------------------------------------------------------
-- State (all plugin-local)
------------------------------------------------------------
local isCrystalWarrior = true;   -- assume until proven otherwise
local cwChecked        = false;

local summary         = {};
local summaryTotal    = 0;
local summaryQty      = 0;
local items           = {};
local viewTotal       = 0;
local viewQty         = 0;
local currentCategory = nil;
local searchActive    = false;
local isLocked        = false;
local lockMsg         = '';

local categoryCache   = {};  -- [ahCat] = { fetchedAt, items, viewTotal, viewQty }
local fetchedAt       = { summary = 0 };

local withdrawInFlight = false;
local withdrawUntil    = 0;

local searchBuf       = { '' };
local searchSize      = 32;
local selectedItem    = nil;
local coreState       = {};  -- reference to trove state, set each frame

local searchDebounce = {
    lastBuf = '', changedAt = 0, delay = 0.3, pending = false,
};

------------------------------------------------------------
-- Cache TTLs (seconds)
------------------------------------------------------------
local TTL = {
    summary  = 60,
    category = 60,
};

------------------------------------------------------------
-- Cache helpers
------------------------------------------------------------
local function cacheFresh(ts, ttl)
    return ts > 0 and (os.clock() - ts) < ttl;
end

local function invalidateSummary()     fetchedAt.summary = 0; end
local function invalidateCategories()  categoryCache     = {}; end

local function invalidateEbox()
    invalidateSummary();
    invalidateCategories();
end

------------------------------------------------------------
-- Packet sending
------------------------------------------------------------
local function sendGetSummary()
    pkt.send(pkt.C2S.GET_SUMMARY);
end

local function sendGetCategory(ahCat)
    local p = pkt.make();
    p[5]  = pkt.C2S.GET_CATEGORY;
    p[11] = ahCat;
    pkt.sendRaw(p);
end

local function sendSearch(search)
    local p = pkt.make();
    p[5] = pkt.C2S.SEARCH;
    pkt.writeString(p, 0x10, search, 31);
    pkt.sendRaw(p);
end

local function sendWithdraw(itemId, qty)
    local p = pkt.make();
    p[5] = pkt.C2S.WITHDRAW;
    pkt.writeU16(p, 0x08, itemId);
    pkt.writeU32(p, 0x0C, qty);
    pkt.sendRaw(p);
end

------------------------------------------------------------
-- View transitions
------------------------------------------------------------
local function goToSummary()
    currentCategory       = nil;
    searchActive          = false;
    items                 = {};
    selectedItem          = nil;
    searchBuf[1]          = '';
    searchDebounce.lastBuf = '';
    searchDebounce.pending = false;

    if cacheFresh(fetchedAt.summary, TTL.summary) then
        coreState.pendingRequest = nil;
        return;
    end

    coreState.pendingRequest = 'ebox_summary';
    sendGetSummary();
end

local function goToCategory(ahCat)
    currentCategory = ahCat;
    searchActive    = false;
    selectedItem    = nil;

    local cached = categoryCache[ahCat];
    if cached and cacheFresh(cached.fetchedAt, TTL.category) then
        items     = cached.items;
        viewTotal = cached.viewTotal;
        viewQty   = cached.viewQty;
        coreState.pendingRequest = nil;
        return;
    end

    items = {};
    coreState.pendingRequest = 'ebox_category';
    sendGetCategory(ahCat);
end

local function applySearch(str)
    if str == '' then
        if searchActive then
            searchActive = false;
            items = {};
            if currentCategory ~= nil then
                coreState.pendingRequest = 'ebox_category';
                sendGetCategory(currentCategory);
            else
                coreState.pendingRequest = 'ebox_summary';
                sendGetSummary();
            end
        end
    else
        searchActive = true;
        items        = {};
        selectedItem = nil;
        coreState.pendingRequest = 'ebox_search';
        sendSearch(str);
    end
end

------------------------------------------------------------
-- Refresh (called after mutations)
------------------------------------------------------------
local function refreshCurrentView(state)
    if searchActive and searchBuf[1] ~= '' then
        state.pendingRequest = 'ebox_search';
        sendSearch(searchBuf[1]);
    elseif currentCategory ~= nil then
        state.pendingRequest = 'ebox_category';
        sendGetCategory(currentCategory);
    else
        state.pendingRequest = 'ebox_summary';
        sendGetSummary();
    end
end

local function ensureCurrentView(state)
    if searchActive and searchBuf[1] ~= '' then
        state.pendingRequest = 'ebox_search';
        sendSearch(searchBuf[1]);
    elseif currentCategory ~= nil then
        local cached = categoryCache[currentCategory];
        if cached and cacheFresh(cached.fetchedAt, TTL.category) then
            items     = cached.items;
            viewTotal = cached.viewTotal;
            viewQty   = cached.viewQty;
            state.pendingRequest = nil;
            return;
        end
        items = {};
        state.pendingRequest = 'ebox_category';
        sendGetCategory(currentCategory);
    else
        if cacheFresh(fetchedAt.summary, TTL.summary) then
            state.pendingRequest = nil;
            return;
        end
        state.pendingRequest = 'ebox_summary';
        sendGetSummary();
    end
end

local function scheduleRefresh(state)
    invalidateEbox();
    ashita.tasks.once(1.0, function()
        if state.isOpen and state.isOpen[1] then
            refreshCurrentView(state);
            if currentCategory ~= nil or searchActive then
                sendGetSummary();
            end
        end
    end);
end

------------------------------------------------------------
-- Groupings for display
------------------------------------------------------------
local function getFilteredGroups()
    local groups     = {};
    local totalItems = 0;
    local totalQty   = 0;

    for _, item in pairs(items) do
        if item.qty > 0 then
            local cat = AH_NAMES[item.ahCat] or 'Other';
            if groups[cat] == nil then groups[cat] = {}; end
            table.insert(groups[cat], item);
            totalItems = totalItems + 1;
            totalQty   = totalQty + item.qty;
        end
    end

    local groupAhCat = {};
    for _, item in pairs(items) do
        if item.qty > 0 then
            local catName = AH_NAMES[item.ahCat] or 'Other';
            groupAhCat[catName] = item.ahCat;
        end
    end

    local ordered = {};
    for catName, catItems in pairs(groups) do
        table.sort(catItems, function(a, b) return a.name < b.name end);
        table.insert(ordered, { category = catName, items = catItems, ahCat = groupAhCat[catName] or 0 });
    end
    table.sort(ordered, function(a, b)
        local ac, bc = CUSTOM_ORDER[a.ahCat], CUSTOM_ORDER[b.ahCat];
        if ac and bc then return ac < bc;
        elseif ac then return false;
        elseif bc then return true;
        else return a.category < b.category; end
    end);

    return ordered, totalItems, totalQty;
end

local function getFlatItems()
    local list = {};
    for _, item in pairs(items) do
        if item.qty > 0 then table.insert(list, item); end
    end
    table.sort(list, function(a, b) return a.name < b.name end);
    return list;
end

------------------------------------------------------------
-- Render helpers
------------------------------------------------------------
local function renderItemRow(item, index)
    local isSelected = (selectedItem ~= nil and selectedItem.id == item.id);
    local isAlt      = (index % 2 == 0);
    local rowId      = string.format('##row_%d_%d', item.id, index);

    local bgColor = isSelected and COLORS.selected or getRowBg(isAlt);

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(rowId, { -1, 28 }, false);

    if isSelected then
        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();
        dl:AddRectFilled({ wx, wy }, { wx + 2, wy + 28 }, imgui.GetColorU32(COLORS.accent));
    end

    imgui.SetCursorPos({ 6, 2 });
    if not renderIcon(item.id, 24) then imgui.Dummy({ 24, 24 }); end
    imgui.SameLine(34);

    imgui.SetCursorPosY(0);
    if imgui.Selectable(string.format('##sel_%d_%d', item.id, index), isSelected,
        ImGuiSelectableFlags_SpanAllColumns, { 0, 28 }) then
        selectedItem = isSelected and nil or item;
    end

    if imgui.IsItemHovered() then renderTooltip(item); end

    local dl  = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Compute right-edge layout first so the name can be clipped to fit.
    local res    = getItemRes(item.id);
    local isRare = res ~= nil and bit.band(res.Flags, FLAG_RARE) ~= 0;
    local isEx   = res ~= nil and bit.band(res.Flags, FLAG_EX)   ~= 0;

    local qtyStr   = string.format('x%d', item.qty);
    local qtyW     = imgui.CalcTextSize(qtyStr);
    local qtyColor = (item.qty <= 5) and COLORS.qtyLow or COLORS.qty;
    local qtyX     = wx + ww - qtyW - 8;

    local GAP         = 6;
    local BADGE_H     = 16;
    local BADGE_PAD_X = 4;
    local EX_TEXT_W   = imgui.CalcTextSize('Ex');
    local R_TEXT_W    = imgui.CalcTextSize('R');
    local EX_W        = EX_TEXT_W + BADGE_PAD_X * 2;
    local R_W         = R_TEXT_W  + BADGE_PAD_X * 2;
    local badgeTop    = wy + 6;

    local exX    = isEx   and (qtyX - GAP - EX_W) or qtyX;
    local rareX  = isRare and (exX  - (isEx and GAP or 0) - R_W) or exX;

    -- Truncate the name if it would run into the tag column.
    local nameX    = wx + 34;
    local nameMaxW = (isRare and rareX or (isEx and exX or qtyX)) - GAP - nameX;
    local displayName = item.name or '';
    if imgui.CalcTextSize(displayName) > nameMaxW then
        while #displayName > 1 and imgui.CalcTextSize(displayName .. '...') > nameMaxW do
            displayName = displayName:sub(1, -2);
        end
        displayName = displayName .. '...';
    end

    dl:AddText({ nameX, wy + 7 }, imgui.GetColorU32(COLORS.white), displayName);

    if isRare then
        dl:AddRectFilled({ rareX, badgeTop }, { rareX + R_W, badgeTop + BADGE_H },
            imgui.GetColorU32(COLORS.rareBg));
        dl:AddText({ rareX + BADGE_PAD_X, wy + 7 },
            imgui.GetColorU32(COLORS.rare), 'R');
    end
    if isEx then
        dl:AddRectFilled({ exX, badgeTop }, { exX + EX_W, badgeTop + BADGE_H },
            imgui.GetColorU32(COLORS.exBg));
        dl:AddText({ exX + BADGE_PAD_X, wy + 7 },
            imgui.GetColorU32(COLORS.ex), 'Ex');
    end
    dl:AddText({ qtyX, wy + 7 }, imgui.GetColorU32(qtyColor), qtyStr);

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

local function renderCategoryHeader(cat, catIndex)
    local catId = string.format('##cathdr_%s_%d', cat.category, catIndex);

    imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.headerBg);
    imgui.BeginChild(catId, { -1, 22 }, false);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 22 }, imgui.GetColorU32(COLORS.accent));

    imgui.SetCursorPosX(10);
    imgui.SetCursorPosY(3);
    imgui.TextColored(COLORS.category, cat.category);

    local countStr = string.format('(%d)', #cat.items);
    local ww = imgui.GetWindowWidth();
    imgui.SameLine(ww - imgui.CalcTextSize(countStr) - 12);
    imgui.SetCursorPosY(3);
    imgui.TextColored(COLORS.dimmed, countStr);

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

local function renderCategoryButton(entry, col)
    local name = AH_NAMES[entry.ahCat] or string.format('Cat %d', entry.ahCat);
    local btnId = string.format('##catbtn_%d', entry.ahCat);
    local rowWidth = imgui.GetContentRegionAvail();
    local btnW = (rowWidth - 6) / 2;
    local btnH = 42;

    if col == 2 then imgui.SameLine(0, 6); end

    local bg = COLORS.catBtnBg;
    local bgColor = { bg[1], bg[2], bg[3], 0.65 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(btnId, { btnW, btnH }, false);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Accent bar
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + btnH }, imgui.GetColorU32(COLORS.accent));

    imgui.SetCursorPosY(0);
    if imgui.Selectable(string.format('##catsel_%d', entry.ahCat), false,
        ImGuiSelectableFlags_SpanAllColumns, { 0, btnH }) then
        goToCategory(entry.ahCat);
    end

    -- Hover highlight
    if imgui.IsItemHovered() then
        dl:AddRectFilled({ wx + 3, wy }, { wx + ww, wy + btnH },
            imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.04 }));
    end

    -- Category name
    dl:AddText({ wx + 12, wy + 6 }, imgui.GetColorU32(COLORS.category), name);

    -- Item count + qty on second line
    local countStr = string.format('%d items', entry.count);
    dl:AddText({ wx + 12, wy + 22 }, imgui.GetColorU32(COLORS.dimmed), countStr);

    -- Total qty badge on right
    local qtyStr = addCommas(entry.totalQty);
    local qtyW = imgui.CalcTextSize(qtyStr);
    dl:AddText({ wx + ww - qtyW - 10, wy + 14 },
        imgui.GetColorU32(COLORS.qty), qtyStr);

    imgui.EndChild();
    imgui.PopStyleColor(1);
    if col == 2 then imgui.Spacing(); end
end

local function renderSelectionPanel()
    local item = selectedItem;
    if item == nil then return 0; end

    local live = items[item.id];
    if live == nil then selectedItem = nil; return 0; end
    item = live;
    selectedItem = live;

    local res = getItemRes(item.id);
    local isEquip = (res ~= nil and (res.Level > 0 or res.Jobs > 0 or res.Slots > 0));
    local panelH = isEquip and 86 or 70;

    imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.panelBg);
    imgui.PushStyleColor(ImGuiCol_Border, COLORS.accent);
    imgui.BeginChild('##sel_panel', { -1, panelH }, true);

    imgui.SetCursorPos({ 6, 6 });
    renderIcon(item.id, 28);
    imgui.SameLine(40);
    imgui.SetCursorPosY(4);
    imgui.TextColored(COLORS.header, item.name);
    imgui.SameLine();

    local qtyColor = (item.qty <= 5) and COLORS.qtyLow or COLORS.qty;
    imgui.TextColored(qtyColor, string.format('x%d', item.qty));

    if res ~= nil then
        imgui.SameLine(0, 8);
        renderBadges(res.Flags);
    end

    if isEquip and res ~= nil then
        imgui.SetCursorPosX(40);
        local parts = {};
        if res.Damage and res.Delay and res.Skill and res.Damage > 0 and res.Delay > 0 and res.Skill > 0 then
            local skill = WEAPON_SKILLS[res.Skill] or '';
            table.insert(parts, string.format('%s DMG:%d Dly:%d', skill, res.Damage, res.Delay));
        elseif res.Slots and res.Slots > 0 then
            local slot = nil;
            for mask, name in pairs(SLOT_NAMES) do
                if bit.band(res.Slots, mask) ~= 0 then slot = name; break; end
            end
            if slot then table.insert(parts, string.format('[%s]', slot)); end
        end
        if res.Level and res.Level > 0 then table.insert(parts, string.format('Lv%d', res.Level)); end
        if res.Jobs then
            local jobStr = nil;
            if getJobList then
                jobStr = getJobList(res.Jobs);
            end
            if jobStr then table.insert(parts, jobStr); end
        end
        if #parts > 0 then
            imgui.TextColored(COLORS.slotText, table.concat(parts, '  '));
        end
    end

    local btnY = panelH - 28;
    imgui.SetCursorPos({ 6, btnY });

    imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnWithdraw);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnHover);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnActive);

    -- Safety timeout: clear the in-flight flag if the ACK never comes
    if withdrawInFlight and os.clock() > withdrawUntil then
        withdrawInFlight = false;
    end

    for i, btn in ipairs(QTY_BUTTONS) do
        if i > 1 then imgui.SameLine(0, 4); end

        local canAfford = (btn.qty == 0 or btn.qty <= item.qty);
        local blocked   = (withdrawInFlight and btn.qty ~= 0);
        local disabled  = (not canAfford) or blocked;

        if disabled then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnDimmed);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnDimmed);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnDimmed);
            imgui.PushStyleColor(ImGuiCol_Text, { 0.40, 0.38, 0.45, 0.60 });
        end

        imgui.PushID(string.format('qty_%d_%d', item.id, i));
        if imgui.Button(btn.label, { 38, 22 }) and not disabled then
            if btn.qty == 0 then
                AshitaCore:GetChatManager():QueueCommand(1, string.format('!box %s', item.name));
            else
                sendWithdraw(item.id, btn.qty);
                withdrawInFlight = true;
                withdrawUntil    = os.clock() + 3.0;
            end
        end
        imgui.PopID();

        if disabled then imgui.PopStyleColor(4); end

        if imgui.IsItemHovered() then
            imgui.BeginTooltip();
            if btn.qty == 0 then
                imgui.Text('Open in-game withdraw menu');
            else
                imgui.Text(string.format('Withdraw %d', btn.qty));
            end
            imgui.EndTooltip();
        end
    end

    imgui.PopStyleColor(3);
    imgui.EndChild();
    imgui.PopStyleColor(2);

    return panelH + 4;
end

local function renderQuickActions()
    imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnStore);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnStoreH);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnStoreA);
    if imgui.Button('Store All', { 0, 24 }) then
        AshitaCore:GetChatManager():QueueCommand(1, '!box store');
    end
    if imgui.IsItemHovered() then
        imgui.BeginTooltip(); imgui.Text('Store all storable items'); imgui.EndTooltip();
    end
    imgui.PopStyleColor(3);

    imgui.SameLine();
    imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnFeature);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnFeatureH);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnFeatureA);

    if imgui.Button('Clusters', { 0, 24 }) then
        AshitaCore:GetChatManager():QueueCommand(1, '!box cluster');
    end
    if imgui.IsItemHovered() then
        imgui.BeginTooltip(); imgui.Text('Withdraw crystal clusters'); imgui.EndTooltip();
    end

    imgui.SameLine();
    if imgui.Button('Ammo', { 0, 24 }) then
        AshitaCore:GetChatManager():QueueCommand(1, '!box ammo');
    end
    if imgui.IsItemHovered() then
        imgui.BeginTooltip(); imgui.Text('Withdraw ammo bundles'); imgui.EndTooltip();
    end

    imgui.PopStyleColor(3);
end

local function renderBreadcrumb()
    imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnBack);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnBackH);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnBackA);
    if imgui.Button('< Back', { 0, 24 }) then goToSummary(); end
    imgui.PopStyleColor(3);

    imgui.SameLine();

    local label;
    if searchActive then
        label = string.format('Search: "%s"', searchBuf[1]);
    elseif currentCategory ~= nil then
        label = AH_NAMES[currentCategory] or 'Unknown';
    else
        label = '';
    end
    imgui.TextColored(COLORS.breadcrumb, label);
end

local function renderViewFooter()
    if searchActive then
        local label;
        if viewTotal >= 20 then
            label = string.format('Showing first 20 matches (%s qty). Refine your search to see more.', addCommas(viewQty));
        else
            label = string.format('%d results  |  %s qty', viewTotal, addCommas(viewQty));
        end
        imgui.Spacing();
        imgui.TextColored(COLORS.dimmed, '  ' .. label);
    elseif currentCategory ~= nil then
        imgui.Spacing();
        imgui.TextColored(COLORS.dimmed, string.format('  %d items  |  %s qty',
            viewTotal, addCommas(viewQty)));
    else
        -- Summary view
        if #summary > 0 then
            imgui.Spacing();
            imgui.TextColored(COLORS.dimmed, string.format(
                '  %d items  |  %s qty',
                summaryTotal, addCommas(summaryQty)));
        end
    end
end

local function renderStatus(state)
    if state.statusMsg == '' then return; end
    if os.clock() > state.statusUntil then state.statusMsg = ''; return; end
    local color = state.statusIsErr and COLORS.statusErr or COLORS.statusOk;
    imgui.TextColored(color, state.statusMsg);
end

------------------------------------------------------------
-- E.Box tab content
------------------------------------------------------------
local function render(state)
    coreState = state;

    -- Trigger initial data load if needed
    if not cwChecked then
        cwChecked = true;
        ensureCurrentView(state);
    elseif #summary == 0 and not searchActive and currentCategory == nil and state.pendingRequest == nil then
        ensureCurrentView(state);
    end

    if isLocked then
        imgui.Spacing(); imgui.Spacing();
        local msg = (lockMsg ~= '') and lockMsg or 'Ephemeral Box is locked.';
        local tw  = imgui.CalcTextSize(msg);
        imgui.SetCursorPosX((imgui.GetWindowWidth() - tw) * 0.5);
        imgui.TextColored(COLORS.statusErr, msg);
        return;
    end

    -- Crystal Warrior insignia in the top-left, inline with the action buttons
    if renderFileIcon then
        local shown = renderFileIcon('cw.png', 20);
        if shown then imgui.SameLine(0, 6); end
    end

    renderQuickActions();
    imgui.Spacing();

    imgui.PushItemWidth(-1);
    imgui.InputText('##search', searchBuf, searchSize, ImGuiInputTextFlags_None);
    imgui.PopItemWidth();

    if searchBuf[1] == '' then
        local px, py = imgui.GetItemRectMin();
        imgui.GetWindowDrawList():AddText({ px + 8, py + 4 },
            imgui.GetColorU32(COLORS.searchHint), 'Search items...');
    end

    imgui.Spacing();

    local inSummary = (not searchActive and currentCategory == nil);

    if not inSummary then
        renderBreadcrumb();
    end
    renderStatus(state);
    imgui.Separator();
    imgui.Spacing();

    local panelH = 0;
    if selectedItem ~= nil then
        local r = getItemRes(selectedItem.id);
        panelH = (r ~= nil and (r.Level > 0 or r.Jobs > 0 or r.Slots > 0)) and 90 or 74;
    end

    imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.windowBg);
    imgui.BeginChild('##ebox_scroll', { -1, -panelH }, false);

    if inSummary then
        if #summary == 0 then
            imgui.Spacing(); imgui.Spacing(); imgui.Spacing();
            local msg = 'Your Ephemeral Box is empty.';
            local tw = imgui.CalcTextSize(msg);
            imgui.SetCursorPosX((imgui.GetWindowWidth() - tw) * 0.5);
            imgui.TextColored(COLORS.empty, msg);
        else
            for i, entry in ipairs(summary) do
                local col = ((i - 1) % 2) + 1;
                renderCategoryButton(entry, col);
            end
            renderViewFooter();
        end
    elseif searchActive then
        local groups, totalItems = getFilteredGroups();
        if totalItems == 0 then
            imgui.Spacing(); imgui.Spacing(); imgui.Spacing();
            local msg = string.format('No items matching "%s"', searchBuf[1]);
            local tw = imgui.CalcTextSize(msg);
            imgui.SetCursorPosX((imgui.GetWindowWidth() - tw) * 0.5);
            imgui.TextColored(COLORS.empty, msg);
        else
            for i, cat in ipairs(groups) do
                renderCategoryHeader(cat, i);
                for j, item in ipairs(cat.items) do
                    renderItemRow(item, i * 100 + j);
                end
                imgui.Spacing();
            end
            renderViewFooter();
        end
    else
        local flatItems = getFlatItems();
        if #flatItems == 0 then
            imgui.Spacing(); imgui.Spacing(); imgui.Spacing();
            local msg = 'No items in this category.';
            local tw = imgui.CalcTextSize(msg);
            imgui.SetCursorPosX((imgui.GetWindowWidth() - tw) * 0.5);
            imgui.TextColored(COLORS.empty, msg);
        else
            for i, item in ipairs(flatItems) do
                renderItemRow(item, i);
            end
            renderViewFooter();
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1); -- ebox_scroll bg
    renderSelectionPanel();
end

------------------------------------------------------------
-- Search debounce (called per frame by onRender)
------------------------------------------------------------
local function processSearchDebounce(state)
    if searchBuf[1] ~= searchDebounce.lastBuf then
        searchDebounce.lastBuf   = searchBuf[1];
        searchDebounce.changedAt = os.clock();
        searchDebounce.pending   = true;
    end
    if searchDebounce.pending and (os.clock() - searchDebounce.changedAt) >= searchDebounce.delay then
        searchDebounce.pending = false;
        applySearch(searchBuf[1]);
    end
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'E.Box',
    icon        = 43,     -- Wicker Box
    author      = 'Loxley',
    version     = '1.0',
    description = 'Ephemeral Box storage browser',

    init = function(ri, gir, uimod, rt, rfi, rfimg, gih)
        renderIcon    = ri;
        getItemRes    = gir;
        ui            = uimod;
        renderTooltip = rt;
        renderFileIcon = rfi;
        renderFileImage = rfimg;
        getIconHandle  = gih;
    end,

    setContext = function(ctx)
        renderIcon             = ctx.renderIcon;
        getItemRes             = ctx.getItemRes;
        renderTooltip          = ctx.renderTooltip;
        renderFileIcon         = ctx.renderFileIcon;
        renderFileImage        = ctx.renderFileImage;
        getIconHandle          = ctx.getIconHandle;
        getItemString          = ctx.getItemString;
        getSlotName            = ctx.getSlotName;
        getJobList             = ctx.getJobList;
        addCommas              = ctx.addCommas;
        getRowBg               = ctx.getRowBg;
        setStatus              = ctx.setStatus;
        renderBadges           = ctx.renderBadges;
        renderItemDetail       = ctx.renderItemDetail;
        renderColoredDescription = ctx.renderColoredDescription;
        AH_NAMES               = ctx.AH_NAMES;
        CUSTOM_ORDER           = ctx.CUSTOM_ORDER;
        FLAG_RARE              = ctx.FLAG_RARE;
        FLAG_EX                = ctx.FLAG_EX;
        SLOT_NAMES             = ctx.SLOT_NAMES;
        WEAPON_SKILLS          = ctx.WEAPON_SKILLS;
        QTY_BUTTONS            = ctx.QTY_BUTTONS;
    end,

    tab = {
        label    = 'Box',
        priority = true,
        render   = render,
    },

    onRender = function(state)
        -- Drive search debounce when the ebox tab is active and window is open
        if state.isOpen and state.isOpen[1] and isCrystalWarrior then
            processSearchDebounce(state);
        end
    end,

    onPacketIn = function(e, state)
        if e.id ~= pkt.PACKET_ID then return; end
        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        -- CLEAR — reset item list when ebox is the pending context
        if action == pkt.S2C.CLEAR then
            if state.pendingRequest == 'ebox_summary'
            or state.pendingRequest == 'ebox_category'
            or state.pendingRequest == 'ebox_search' then
                items     = {};
                viewTotal = 0;
                viewQty   = 0;
            end
            return;
        end

        -- ITEM — accumulate into items table
        if action == pkt.S2C.ITEM then
            if state.pendingRequest == 'ebox_summary'
            or state.pendingRequest == 'ebox_category'
            or state.pendingRequest == 'ebox_search' then
                local itemId = pkt.readU16(e.data_modified, 0x08);
                local ahCat  = struct.unpack('B', e.data_modified, 0x0A + 1);
                local qty    = pkt.readU32(e.data_modified, 0x0C);
                local name   = pkt.readString(e.data_modified, 0x10, 31);

                items[itemId] = { id = itemId, name = name, qty = qty, ahCat = ahCat };
            end
            return;
        end

        -- END_LIST — finalise category/search view
        if action == pkt.S2C.END_LIST then
            local source = struct.unpack('B', e.data_modified, 0x05 + 1);
            -- Only handle source=0 (ebox); other sources belong to other plugins
            if source ~= 0 then return; end

            if state.pendingRequest == 'ebox_summary'
            or state.pendingRequest == 'ebox_category'
            or state.pendingRequest == 'ebox_search' then
                local now = os.clock();
                viewTotal = pkt.readU16(e.data_modified, 0x08);
                viewQty   = pkt.readU32(e.data_modified, 0x0C);

                -- Cache the newly-streamed items for this category
                if state.pendingRequest == 'ebox_category' and currentCategory ~= nil then
                    categoryCache[currentCategory] = {
                        fetchedAt = now,
                        items     = items,
                        viewTotal = viewTotal,
                        viewQty   = viewQty,
                    };
                end
                state.pendingRequest = nil;
            end
            return;
        end

        -- SUMMARY — category summary with counts
        if action == pkt.S2C.SUMMARY then
            local entryCount = struct.unpack('B', e.data_modified, 0x05 + 1);
            local entries    = {};
            local totalItems = 0;
            local totalQty   = 0;

            for i = 0, entryCount - 1 do
                local off   = 0x08 + i * 7;
                local ahCat = struct.unpack('B', e.data_modified, off + 1);
                local count = pkt.readU16(e.data_modified, off + 1);
                local qty   = pkt.readU32(e.data_modified, off + 3);
                table.insert(entries, { ahCat = ahCat, count = count, totalQty = qty });
                totalItems = totalItems + count;
                totalQty   = totalQty + qty;
            end

            table.sort(entries, function(a, b)
                local ac, bc = CUSTOM_ORDER[a.ahCat], CUSTOM_ORDER[b.ahCat];
                if ac and bc then return ac < bc;
                elseif ac then return false;
                elseif bc then return true;
                else
                    local na = AH_NAMES[a.ahCat] or 'zzz';
                    local nb = AH_NAMES[b.ahCat] or 'zzz';
                    return na < nb;
                end
            end);

            summary              = entries;
            summaryTotal         = totalItems;
            summaryQty           = totalQty;
            isLocked             = false;
            state.pendingRequest = nil;
            fetchedAt.summary    = os.clock();
            -- Confirmed CW since we got a summary back
            isCrystalWarrior     = true;
            cwChecked            = true;
            -- Expose CW status to core for tab visibility
            state.isCrystalWarrior = true;
            state.cwChecked        = true;
            return;
        end

        -- ACK — withdraw result
        if action == pkt.S2C.ACK then
            local requestAction = struct.unpack('B', e.data_modified, 0x05 + 1);
            local success       = struct.unpack('B', e.data_modified, 0x06 + 1);
            local message       = pkt.readString(e.data_modified, 0x10, 31);

            if requestAction == pkt.C2S.WITHDRAW then
                withdrawInFlight = false;

                if success == 0 and message ~= '' then
                    setStatus(message, true);
                end

                if success == 1 then
                    invalidateEbox();
                    ashita.tasks.once(0.8, function()
                        refreshCurrentView(state);
                        if currentCategory ~= nil or searchActive then
                            sendGetSummary();
                        end
                    end);
                end
            end
            return;
        end

        -- LOCKED — Crystal Warrior / feature gating
        if action == pkt.S2C.LOCKED then
            local reason = struct.unpack('B', e.data_modified, 0x05 + 1);
            local msg    = pkt.readString(e.data_modified, 0x10, 31);

            if reason == LOCK_REASON_NOT_CW then
                isCrystalWarrior       = false;
                cwChecked              = true;
                state.isCrystalWarrior = false;
                state.cwChecked        = true;
            else
                isLocked  = true;
                lockMsg   = msg;
                cwChecked = true;
                state.cwChecked = true;
            end
            state.pendingRequest = nil;
            return;
        end
    end,

    -- Called when the tab activates (cache-respecting data fetch)
    ensureData = function(state)
        if not isCrystalWarrior then return; end
        ensureCurrentView(state);
    end,

    -- Crystal Warrior visibility check for tab rendering
    isVisible = function(state)
        return isCrystalWarrior;
    end,

    invalidate = function()
        invalidateEbox();
    end,

    -- Called by core on !box chat command
    onCommand = function(cmd, state, args)
        if cmd == '!box' then
            scheduleRefresh(state);
            return true;
        end
        return false;
    end,

    commands = {
        box = function(state, args)
            -- /trove box with no sub-args toggles the window
            if args == nil or #args <= 2 then
                state.isOpen[1] = true;
                return;
            end
            -- /trove box <something> → passthrough to !box
            local parts = {};
            for i = 3, #args do table.insert(parts, args[i]); end
            AshitaCore:GetChatManager():QueueCommand(1, string.format('!box %s', table.concat(parts, ' ')));
            scheduleRefresh(state);
        end,
    },

    -- Exposed for core to check CW status
    isCrystalWarrior = function() return isCrystalWarrior; end,
    cwChecked        = function() return cwChecked; end,
};
