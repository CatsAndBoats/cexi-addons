--[[
* trove/plugins/crafting.lua — Crafting recipe browser
*
* Search for any item by name, view its crafting recipe (ingredients,
* skills, results), and withdraw materials from storage. Supports
* clicking ingredients to navigate to their recipe.
*
* Command: /trove craft
]]--

local imgui  = require('imgui');
local pkt    = require('utils/packet');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon    = nil;
local getItemRes    = nil;
local ui            = nil;
local renderTooltip = nil;
local getItemName   = nil;  -- function(itemId) → UTF-8 name string

------------------------------------------------------------
-- State
------------------------------------------------------------
local craftRecipes       = {};
local craftLoaded        = false;
local craftItemId        = 0;
local craftItemName      = '';
local craftHistory       = {};
local batchWithdrawCount = 0;
local craftFlashId       = 0;
local craftFlashUntil    = 0;
local synthCooldownUntil = 0;
local synthResultMsg     = '';
local synthResultIsErr   = false;
local synthResultUntil   = 0;

local searchBuf  = { '' };
local searchSize = 32;
local troveState = nil;  -- captured from first render/packet callback

-- Client-side item name index for instant search
local craftIndex     = nil;
local craftIndexSize = 0;

-- Debounce for search
local craftDebounce = {
    lastBuf = '', changedAt = 0, delay = 0.3, pending = false, results = {},
};

-- Debounce for auto-refresh on inventory change
local craftRefreshDebounce = { pending = false, at = 0, delay = 2.0, synthCooldownUntil = 0 };

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
-- Status (local to crafting tab)
------------------------------------------------------------
local statusMsg    = '';
local statusIsErr  = false;
local statusUntil  = 0;

local function setStatus(msg, isErr)
    statusMsg    = msg or '';
    statusIsErr  = isErr or false;
    statusUntil  = os.clock() + 4;
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function buildCraftIndex()
    if craftIndex ~= nil then return; end
    craftIndex = {};
    local rm = AshitaCore:GetResourceManager();
    for id = 1, 65535 do
        local res = rm:GetItemById(id);
        if res ~= nil then
            local n = res.Name[1];
            if n ~= nil and #n > 0 then
                craftIndex[#craftIndex + 1] = { id = id, name = n:lower() };
            end
        end
    end
    craftIndexSize = #craftIndex;
end

local function searchCraftItems(query)
    buildCraftIndex();
    local q = query:lower();
    if #q == 0 then return {}; end
    local results = {};
    for i = 1, craftIndexSize do
        if craftIndex[i].name:find(q, 1, true) ~= nil then
            results[#results + 1] = craftIndex[i];
            if #results >= 20 then break; end
        end
    end
    return results;
end

local function requestRecipe(itemId, pushHistory)
    if pushHistory ~= false and craftItemId > 0 then
        if #craftHistory >= 20 then
            table.remove(craftHistory, 1);
        end
        table.insert(craftHistory, { id = craftItemId, name = craftItemName });
    end
    craftItemName  = getItemName(itemId) or tostring(itemId);
    craftItemId    = itemId;
    craftRecipes   = {};
    craftLoaded    = false;

    if troveState then
        troveState.pendingRequest = 'crafting';
    end

    local p = pkt.make();
    p[5] = pkt.C2S.GET_RECIPE;
    pkt.writeU16(p, 0x08, itemId);
    pkt.sendRaw(p);
end

local function sendWithdraw(itemId, qty)
    local p = pkt.make();
    p[5] = pkt.C2S.WITHDRAW;
    pkt.writeU16(p, 0x08, itemId);
    pkt.writeU32(p, 0x0C, qty);
    pkt.sendRaw(p);
end

local function trySynth(recipe)
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local maxSlots = inv:GetContainerCountMax(0);

    local invMap = {};
    for slot = 1, maxSlots do
        local ci = inv:GetContainerItem(0, slot);
        if ci ~= nil and ci.Id > 0 and ci.Count > 0 then
            if not invMap[ci.Id] then invMap[ci.Id] = {}; end
            invMap[ci.Id][#invMap[ci.Id] + 1] = { slot = slot, avail = ci.Count };
        end
    end

    local cSlots = invMap[recipe.crystal.id];
    if not cSlots or #cSlots == 0 then return 'Crystal not in inventory'; end
    local crystalSlot = cSlots[1].slot;

    local itemNos  = {};
    local tableNos = {};
    local slotUsed = {};

    for _, ing in ipairs(recipe.ingredients) do
        local slots = invMap[ing.id];
        if not slots then return 'Missing: ' .. tostring(ing.id); end
        for _ = 1, ing.need do
            local found = false;
            for _, s in ipairs(slots) do
                local used = slotUsed[s.slot] or 0;
                if used < s.avail then
                    itemNos[#itemNos + 1]   = ing.id;
                    tableNos[#tableNos + 1] = s.slot;
                    slotUsed[s.slot] = used + 1;
                    found = true;
                    break;
                end
            end
            if not found then return 'Not enough in inventory'; end
        end
    end

    local p = {};
    for i = 1, 36 do p[i] = 0; end
    pkt.writeU16(p, 0x06, recipe.crystal.id);
    p[0x08 + 1] = crystalSlot;
    p[0x09 + 1] = #itemNos;
    for i = 1, #itemNos do
        pkt.writeU16(p, 0x0A + (i - 1) * 2, itemNos[i]);
    end
    for i = 1, #tableNos do
        p[0x1A + i] = tableNos[i];
    end

    AshitaCore:GetPacketManager():AddOutgoingPacket(0x96, p);
    return nil;
end

local function ingredientColor(inv, ebox, need)
    if inv >= need then return { 0.40, 1.00, 0.40, 1.00 }; end
    if (inv + ebox) >= need then return { 0.50, 0.70, 1.00, 1.00 }; end
    return { 1.00, 0.40, 0.40, 1.00 };
end

local SKILL_COLORS = {
    Wood     = { 0.45, 0.80, 0.45, 1.00 },
    Smith    = { 0.70, 0.70, 0.80, 1.00 },
    Gold     = { 1.00, 0.90, 0.40, 1.00 },
    Cloth    = { 1.00, 0.65, 0.85, 1.00 },
    Leather  = { 0.85, 0.65, 0.40, 1.00 },
    Bone     = { 0.80, 0.75, 0.70, 1.00 },
    Alchemy  = { 0.75, 0.55, 1.00, 1.00 },
    Cook     = { 1.00, 0.75, 0.40, 1.00 },
};

local PREPARE_COUNTS = { 1, 3, 6, 12 };

local function calcPrepare(recipe, count, mode)
    local pulls = {};
    local feasible = true;

    local crNeed = (mode == 'all') and count or math.max(0, count - recipe.crystal.inv);
    crNeed = math.min(crNeed, recipe.crystal.ebox);
    if (mode == 'all' and recipe.crystal.ebox < count)
       or (mode == 'missing' and recipe.crystal.inv < count and recipe.crystal.ebox < (count - recipe.crystal.inv)) then
        feasible = false;
    end
    if crNeed > 0 then
        pulls[#pulls + 1] = { id = recipe.crystal.id, qty = crNeed };
    end

    for _, ing in ipairs(recipe.ingredients) do
        local totalNeed = ing.need * count;
        local delta;
        if mode == 'all' then
            delta = totalNeed;
        else
            delta = math.max(0, totalNeed - ing.inv);
        end
        delta = math.min(delta, ing.ebox);

        if (mode == 'all' and ing.ebox < totalNeed)
           or (mode == 'missing' and ing.inv < totalNeed and ing.ebox < (totalNeed - ing.inv)) then
            feasible = false;
        end
        if delta > 0 then
            pulls[#pulls + 1] = { id = ing.id, qty = delta };
        end
    end

    return { pullList = pulls, feasible = feasible };
end

local function executePrepare(pullList)
    if #pullList == 0 then return; end
    batchWithdrawCount = #pullList;
    for _, pull in ipairs(pullList) do
        sendWithdraw(pull.id, pull.qty);
    end
end

------------------------------------------------------------
-- Render: recipe detail
------------------------------------------------------------
local function renderRecipe(recipe, index)
    local COLORS = {
        dimmed   = ui.color('dimmed'),
        header   = ui.color('header'),
        white    = ui.color('white'),
        rare     = ui.color('rare'),
        statusOk = ui.color('statusOk'),
        statusErr = ui.color('statusErr'),
        btnBack  = ui.color('btnBack'),
        btnBackH = ui.color('btnBackHover'),
        btnBackA = ui.color('btnBackActive'),
    };

    -- Skills line
    local skillParts = {};
    for name, level in pairs(recipe.skills) do
        table.insert(skillParts, string.format('%s %d', name, level));
    end
    if #skillParts > 0 then
        imgui.TextColored(COLORS.dimmed, table.concat(skillParts, ' / '));
    end
    if recipe.desynth then
        imgui.SameLine(0, 8);
        imgui.TextColored(COLORS.rare, '(Desynth)');
    end

    local craftLabel = string.format('Can craft: %d', recipe.craftable);
    imgui.SameLine(imgui.GetWindowWidth() - imgui.CalcTextSize(craftLabel) - 16);
    local craftColor = recipe.craftable > 0 and { 0.40, 1.00, 0.40, 1.00 } or { 1.00, 0.40, 0.40, 1.00 };
    imgui.TextColored(craftColor, craftLabel);

    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();

    -- Crystal
    local cr = recipe.crystal;
    local crColor = ingredientColor(cr.inv, cr.ebox, 1);
    if not renderIcon(cr.id, 20) then imgui.Dummy({ 20, 20 }); end
    imgui.SameLine(0, 4);
    local crName = getItemName(cr.id) or tostring(cr.id);
    imgui.TextColored(crColor, crName);
    imgui.SameLine(0, 8);
    imgui.TextColored(COLORS.dimmed, string.format('(%d/%d)', cr.inv + cr.ebox, 1));
    if imgui.IsItemHovered() then
        imgui.BeginTooltip();
        imgui.TextColored(COLORS.header, crName);
        imgui.TextColored(COLORS.dimmed, string.format('Inventory: %d  |  E.Box: %d', cr.inv, cr.ebox));
        imgui.EndTooltip();
    end

    imgui.Spacing();

    -- Ingredients
    for ingIdx, ing in ipairs(recipe.ingredients) do
        local color = ingredientColor(ing.inv, ing.ebox, ing.need);
        local isFlashing = craftFlashId == ing.id and os.clock() < craftFlashUntil;
        if isFlashing then color = { 1.0, 1.0, 1.0, 1.0 }; end

        if not renderIcon(ing.id, 20) then imgui.Dummy({ 20, 20 }); end
        imgui.SameLine(0, 4);
        local ingName = getItemName(ing.id) or tostring(ing.id);
        local label = ing.need > 1 and string.format('%s x%d', ingName, ing.need) or ingName;
        imgui.PushStyleColor(ImGuiCol_Text, color);
        local selId = string.format('%s##ing_%d_%d', label, index, ingIdx);
        if imgui.Selectable(selId, false, ImGuiSelectableFlags_None, { 0, 0 }) then
            requestRecipe(ing.id);
        end
        imgui.PopStyleColor();
        imgui.SameLine(0, 8);
        imgui.TextColored(COLORS.dimmed, string.format('(%d/%d)', ing.inv + ing.ebox, ing.need));
        if imgui.IsItemHovered() then
            imgui.BeginTooltip();
            renderIcon(ing.id, 32);
            imgui.SameLine(0, 6);
            imgui.BeginGroup();
            imgui.TextColored(COLORS.header, ingName);
            imgui.TextColored(COLORS.dimmed, string.format('Need: %d', ing.need));
            imgui.TextColored(COLORS.dimmed, string.format('Inventory: %d  |  E.Box: %d', ing.inv, ing.ebox));
            imgui.EndGroup();
            imgui.EndTooltip();
        end
    end

    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();

    -- Results
    local nq = recipe.results[0];
    if nq ~= nil then
        if not renderIcon(nq.id, 20) then imgui.Dummy({ 20, 20 }); end
        imgui.SameLine(0, 4);
        local nqName = getItemName(nq.id) or tostring(nq.id);
        local nqLabel = nq.qty > 1 and string.format('%s x%d', nqName, nq.qty) or nqName;
        imgui.TextColored({ 0.40, 1.00, 0.40, 1.00 }, nqLabel);
        if imgui.IsItemHovered() then renderTooltip({ id = nq.id, name = nqName, qty = 0 }); end

        local HQ_TIER_COLORS = {
            [1] = { 0.80, 0.80, 0.80, 1.00 },
            [2] = { 0.50, 0.70, 1.00, 1.00 },
            [3] = { 1.00, 0.90, 0.30, 1.00 },
        };
        for tier = 1, 3 do
            local hq = recipe.results[tier];
            if hq ~= nil and (hq.id ~= nq.id or hq.qty ~= nq.qty) then
                if not renderIcon(hq.id, 20) then imgui.Dummy({ 20, 20 }); end
                imgui.SameLine(0, 4);
                local hqName = getItemName(hq.id) or tostring(hq.id);
                local hqLabel = hq.qty > 1 and string.format('%s x%d', hqName, hq.qty) or hqName;
                imgui.TextColored(HQ_TIER_COLORS[tier], string.format('HQ%d: %s', tier, hqLabel));
                if imgui.IsItemHovered() then renderTooltip({ id = hq.id, name = hqName, qty = 0 }); end
            end
        end
    end

    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();

    -- Prepare buttons
    local inFlight = batchWithdrawCount > 0;
    local BTN_MISSING       = { 0.55, 0.40, 0.15, 0.80 };
    local BTN_MISSING_HOVER = { 0.65, 0.50, 0.20, 0.90 };
    local BTN_MISSING_ACT   = { 0.60, 0.45, 0.18, 1.00 };
    local BTN_ALL           = { 0.15, 0.40, 0.50, 0.80 };
    local BTN_ALL_HOVER     = { 0.20, 0.50, 0.60, 0.90 };
    local BTN_ALL_ACT       = { 0.18, 0.45, 0.55, 1.00 };
    local BTN_DISABLED      = { 0.20, 0.18, 0.25, 0.40 };
    local BTN_DISABLED_TEXT  = { 0.40, 0.40, 0.40, 0.50 };

    imgui.TextColored({ 0.90, 0.75, 0.40, 1.00 }, 'Withdraw missing:');
    imgui.SameLine(0, 6);
    for _, n in ipairs(PREPARE_COUNTS) do
        local prep = calcPrepare(recipe, n, 'missing');
        local enabled = prep.feasible and #prep.pullList > 0 and not inFlight;
        if not enabled then
            imgui.PushStyleColor(ImGuiCol_Button, BTN_DISABLED);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, BTN_DISABLED);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, BTN_DISABLED);
            imgui.PushStyleColor(ImGuiCol_Text, BTN_DISABLED_TEXT);
        else
            imgui.PushStyleColor(ImGuiCol_Button, BTN_MISSING);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, BTN_MISSING_HOVER);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, BTN_MISSING_ACT);
            imgui.PushStyleColor(ImGuiCol_Text, { 1, 1, 1, 1 });
        end
        local btnId = string.format('x%d##miss_%d_%d', n, index, n);
        if imgui.Button(btnId, { 0, 22 }) and enabled then
            executePrepare(prep.pullList);
        end
        imgui.PopStyleColor(4);
        imgui.SameLine(0, 4);
    end
    imgui.NewLine();

    imgui.TextColored({ 0.45, 0.80, 0.85, 1.00 }, 'Withdraw all:');
    imgui.SameLine(0, 24);
    for _, n in ipairs(PREPARE_COUNTS) do
        local prep = calcPrepare(recipe, n, 'all');
        local enabled = prep.feasible and #prep.pullList > 0 and not inFlight;
        if not enabled then
            imgui.PushStyleColor(ImGuiCol_Button, BTN_DISABLED);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, BTN_DISABLED);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, BTN_DISABLED);
            imgui.PushStyleColor(ImGuiCol_Text, BTN_DISABLED_TEXT);
        else
            imgui.PushStyleColor(ImGuiCol_Button, BTN_ALL);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, BTN_ALL_HOVER);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, BTN_ALL_ACT);
            imgui.PushStyleColor(ImGuiCol_Text, { 1, 1, 1, 1 });
        end
        local btnId = string.format('x%d##all_%d_%d', n, index, n);
        if imgui.Button(btnId, { 0, 22 }) and enabled then
            executePrepare(prep.pullList);
        end
        imgui.PopStyleColor(4);
        imgui.SameLine(0, 4);
    end
    imgui.NewLine();

    -- Craft button
    imgui.Spacing();
    local synthCooldown = os.clock() < synthCooldownUntil;
    local canCraft = not recipe.desynth and recipe.craftable > 0 and not inFlight and not synthCooldown;
    local BTN_CRAFT       = { 0.25, 0.55, 0.25, 0.80 };
    local BTN_CRAFT_HOVER = { 0.30, 0.65, 0.30, 0.90 };
    local BTN_CRAFT_ACT   = { 0.28, 0.60, 0.28, 1.00 };
    if not canCraft then
        imgui.PushStyleColor(ImGuiCol_Button, BTN_DISABLED);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, BTN_DISABLED);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, BTN_DISABLED);
        imgui.PushStyleColor(ImGuiCol_Text, BTN_DISABLED_TEXT);
    else
        imgui.PushStyleColor(ImGuiCol_Button, BTN_CRAFT);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, BTN_CRAFT_HOVER);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, BTN_CRAFT_ACT);
        imgui.PushStyleColor(ImGuiCol_Text, { 1, 1, 1, 1 });
    end
    local craftBtnId = string.format('Craft##craft_%d', index);
    if imgui.Button(craftBtnId, { -1, 26 }) and canCraft then
        local err = trySynth(recipe);
        if err then
            setStatus(err, true);
        else
            synthCooldownUntil = os.clock() + 15;
        end
    end
    imgui.PopStyleColor(4);
end

------------------------------------------------------------
-- Render: main crafting tab
------------------------------------------------------------
local function render(state)
    if not troveState and state then troveState = state; end
    local COLORS = {
        dimmed  = ui.color('dimmed'),
        header  = ui.color('header'),
        white   = ui.color('white'),
        windowBg = ui.color('windowBg'),
        empty   = ui.color('empty'),
        statusOk = ui.color('statusOk'),
        statusErr = ui.color('statusErr'),
        btnBack  = ui.color('btnBack'),
        btnBackH = ui.color('btnBackHover'),
        btnBackA = ui.color('btnBackActive'),
    };

    -- Search box
    imgui.TextColored(COLORS.dimmed, 'Search for any item to view its crafting recipe:');
    imgui.SetNextItemWidth(-1);
    imgui.InputText('##craft_search', searchBuf, searchSize, ImGuiInputTextFlags_None);

    -- Debounced client-side search
    local buf = searchBuf[1];
    if buf ~= craftDebounce.lastBuf then
        craftDebounce.lastBuf   = buf;
        craftDebounce.changedAt = os.clock();
        craftDebounce.pending   = true;
    end
    if craftDebounce.pending and os.clock() - craftDebounce.changedAt >= craftDebounce.delay then
        craftDebounce.pending = false;
        craftDebounce.results = searchCraftItems(buf);
    end

    imgui.Spacing();

    -- If we have a loaded recipe (or are refreshing one), show it
    if craftItemId > 0 and (craftLoaded or #craftRecipes > 0 or batchWithdrawCount > 0) then
        -- Back button
        if #craftHistory > 0 then
            imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnBack);
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnBackH);
            imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnBackA);
            if imgui.Button('<', { 24, 24 }) then
                local prev = table.remove(craftHistory);
                requestRecipe(prev.id, false);
            end
            imgui.PopStyleColor(3);
            imgui.SameLine(0, 4);
        end

        -- Close button
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.btnBack);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.btnBackH);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.btnBackA);
        if imgui.Button('x', { 24, 24 }) then
            craftItemId  = 0;
            craftRecipes = {};
            craftLoaded  = false;
            craftHistory = {};
        end
        imgui.PopStyleColor(3);
        imgui.SameLine(0, 6);

        -- Breadcrumbs
        for bi, crumb in ipairs(craftHistory) do
            imgui.PushStyleColor(ImGuiCol_Button,        { 0, 0, 0, 0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.30, 0.22, 0.42, 0.60 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.40, 0.30, 0.55, 0.80 });
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.dimmed);
            local crumbId = string.format('%s##crumb_%d', crumb.name, bi);
            if imgui.SmallButton(crumbId) then
                local targetId = crumb.id;
                for _ = bi, #craftHistory do
                    table.remove(craftHistory);
                end
                requestRecipe(targetId, false);
            end
            imgui.PopStyleColor(4);
            imgui.SameLine(0, 2);
            imgui.TextColored(COLORS.dimmed, '>');
            imgui.SameLine(0, 2);
        end

        -- Current item name (or synth result message)
        if #synthResultMsg > 0 and os.clock() < synthResultUntil then
            local color = synthResultIsErr and COLORS.statusErr or COLORS.statusOk;
            imgui.TextColored(color, synthResultMsg);
        else
            imgui.TextColored(COLORS.header, craftItemName);
        end

        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.windowBg);
        imgui.BeginChild('##craft_scroll', { -1, -1 }, false);

        if #craftRecipes == 0 then
            imgui.Spacing(); imgui.Spacing();
            imgui.TextColored(COLORS.dimmed, 'No crafting recipes found for this item.');
        else
            local shown = 0;
            for i, recipe in ipairs(craftRecipes) do
                if shown > 0 then imgui.Spacing(); imgui.Separator(); imgui.Spacing(); end
                renderRecipe(recipe, i);
                shown = shown + 1;
            end
        end

        imgui.EndChild();
        imgui.PopStyleColor(1);
        return;
    end

    -- Pending recipe request
    if state.pendingRequest == 'crafting' then
        imgui.TextColored(COLORS.dimmed, 'Loading recipe...');
        return;
    end

    -- Search results list
    imgui.PushStyleColor(ImGuiCol_ChildBg, COLORS.windowBg);
    imgui.BeginChild('##craft_results', { -1, -1 }, false);

    local results = craftDebounce.results;
    if #results == 0 and #buf > 0 then
        imgui.Spacing();
        imgui.TextColored(COLORS.dimmed, string.format('No items matching "%s"', buf));
    else
        for i, entry in ipairs(results) do
            local rowId = string.format('##craft_row_%d', entry.id);
            local isAlt = (i % 2 == 0);
            local bg = getRowBg(isAlt);

            imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
            imgui.BeginChild(rowId, { -1, 26 }, false,
                bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

            imgui.SetCursorPos({ 4, 1 });
            if not renderIcon(entry.id, 24) then imgui.Dummy({ 24, 24 }); end

            local displayName = getItemName(entry.id) or entry.name;
            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddText({ wx + 32, wy + 6 }, imgui.GetColorU32(COLORS.white), ((displayName or ''):gsub('%%', '%%%%')));

            imgui.EndChild();
            imgui.PopStyleColor(1);

            -- Click detection on the child itself (not a Selectable inside it)
            if imgui.IsItemClicked() then

                requestRecipe(entry.id);
            end
            if imgui.IsItemHovered() then
                renderTooltip({ id = entry.id, name = displayName or '', qty = 0 });
            end
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Synth result messages
------------------------------------------------------------
local SYNTH_RESULT_MSG = {
    [0x00] = 'Synthesis succeeded!',
    [0x01] = 'Synthesis failed. Crystal lost.',
    [0x02] = 'Synthesis interrupted! Materials lost.',
    [0x03] = 'Bad recipe combination.',
    [0x04] = 'Synthesis canceled.',
    [0x06] = 'Skill too low for this recipe.',
    [0x07] = 'Cannot hold another rare item.',
    [0x0C] = 'Desynthesis succeeded!',
    [0x0D] = 'Must wait longer.',
    [0x0E] = 'Synthesis interrupted! Materials lost.',
};

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Crafting',
    icon        = 4098,   -- Wind Crystal
    author      = 'Loxley',
    version     = '1.0',
    description = 'Recipe browser and crafting assistant',

    init = function(ri, gir, uimod, rt, rfi, rfimg, gih)
        renderIcon    = ri;
        getItemRes    = gir;
        ui            = uimod;
        renderTooltip = rt;
        -- Build a getItemName helper from getItemRes + the FFI shiftjis
        -- conversion that's available in the main trove.lua scope. We
        -- use the resource manager Name[1] field which is already ASCII
        -- for most item names in Ashita's resource table.
        getItemName = function(itemId)
            local res = gir(itemId);
            if res == nil or res.Name[1] == nil then return nil; end
            return res.Name[1];
        end;
    end,

    tab = {
        label  = 'Crafting',
        render = render,
    },

    onPacketIn = function(e, state)
        if not troveState and state then troveState = state; end
        -- Handle synth result (0x06F)
        if e.id == 0x06F then
            local result = struct.unpack('B', e.data_modified, 0x04 + 1);
            local qty    = struct.unpack('B', e.data_modified, 0x06 + 1);
            local itemId = pkt.readU16(e.data_modified, 0x08);

            local msg = SYNTH_RESULT_MSG[result];
            if msg == nil then msg = string.format('Synth result: %d', result); end

            local isSuccess = (result == 0x00 or result == 0x0C);
            if isSuccess and itemId > 0 then
                local name = getItemName(itemId) or tostring(itemId);
                msg = msg .. string.format(' %s x%d', name, qty);
            end

            synthResultMsg    = msg;
            synthResultIsErr  = not isSuccess;
            synthResultUntil  = os.clock() + 4;

            craftRefreshDebounce.pending            = false;
            craftRefreshDebounce.synthCooldownUntil = os.clock() + 4;

            ashita.tasks.once(4.5, function()
                if craftItemId > 0 and craftLoaded then
                    craftRecipes = {};
                    craftLoaded  = false;
                    state.pendingRequest = 'crafting';
                    local p = pkt.make();
                    p[5] = pkt.C2S.GET_RECIPE;
                    pkt.writeU16(p, 0x08, craftItemId);
                    pkt.sendRaw(p);
                end
            end);

            synthCooldownUntil = os.clock() + 1;
            return;
        end

        -- Handle inventory changes (auto-refresh recipe)
        if e.id == 0x01F or e.id == 0x020 then
            if craftItemId > 0 and craftLoaded then
                if os.clock() < craftRefreshDebounce.synthCooldownUntil then return; end
                craftRefreshDebounce.pending = true;
                craftRefreshDebounce.at      = os.clock();
            end
            return;
        end

        if e.id ~= pkt.PACKET_ID then return; end
        local action = struct.unpack('B', e.data_modified, 0x04 + 1);


        if action == pkt.S2C.RECIPE then
            local SKILL_NAMES = { 'Wood', 'Smith', 'Gold', 'Cloth', 'Leather', 'Bone', 'Alchemy', 'Cook' };
            local ingCount   = struct.unpack('B', e.data_modified, 0x05 + 1);
            local desynth    = struct.unpack('B', e.data_modified, 0x06 + 1);
            local craftable  = pkt.readU16(e.data_modified, 0x08);
            local crystalId  = pkt.readU16(e.data_modified, 0x0A);
            local crystalInv = pkt.readU16(e.data_modified, 0x0C);
            local crystalEbx = pkt.readU32(e.data_modified, 0x0E);

            local results = {};
            for r = 0, 3 do
                local off = 0x12 + r * 3;
                local id  = pkt.readU16(e.data_modified, off);
                local qty = struct.unpack('B', e.data_modified, off + 2 + 1);
                if id > 0 then
                    results[r] = { id = id, qty = qty };
                end
            end

            local skills = {};
            for s = 0, 7 do
                local v = struct.unpack('B', e.data_modified, 0x1E + s + 1);
                if v > 0 then
                    skills[SKILL_NAMES[s + 1]] = v;
                end
            end

            local ingredients = {};
            for i = 0, ingCount - 1 do
                local off  = 0x26 + i * 9;
                local iid  = pkt.readU16(e.data_modified, off);
                local need = struct.unpack('B', e.data_modified, off + 2 + 1);
                local inv  = pkt.readU16(e.data_modified, off + 3);
                local ebx  = pkt.readU32(e.data_modified, off + 5);
                if iid > 0 then
                    ingredients[#ingredients + 1] = { id = iid, need = need, inv = inv, ebox = ebx };
                end
            end

            craftRecipes[#craftRecipes + 1] = {
                crystal     = { id = crystalId, inv = crystalInv, ebox = crystalEbx },
                results     = results,
                skills      = skills,
                ingredients = ingredients,
                craftable   = craftable,
                desynth     = (desynth ~= 0),
            };
            return;
        end

        -- Handle ACK (batch withdraw counter)
        if action == pkt.S2C.ACK and batchWithdrawCount > 0 then
            batchWithdrawCount = batchWithdrawCount - 1;
            if batchWithdrawCount == 0 then
                -- Refresh the recipe to update ingredient counts
                ashita.tasks.once(0.8, function()
                    if craftItemId > 0 then
                        craftRecipes = {};
                        craftLoaded  = false;
                        state.pendingRequest = 'crafting';
                        local p = pkt.make();
                        p[5] = pkt.C2S.GET_RECIPE;
                        pkt.writeU16(p, 0x08, craftItemId);
                        pkt.sendRaw(p);
                    end
                end);
            end
            return;
        end

        if action == pkt.S2C.CLEAR and state.pendingRequest == 'crafting' then
            craftRecipes = {};
            craftLoaded  = false;
            return;
        end

        if action == pkt.S2C.END_LIST and state.pendingRequest == 'crafting' then
            craftLoaded = true;
            -- No recipes found: flash the item and pop back
            if #craftRecipes == 0 and #craftHistory > 0 then
                craftFlashId    = craftItemId;
                craftFlashUntil = os.clock() + 0.4;
                local prev = table.remove(craftHistory);
                requestRecipe(prev.id, false);
            end
            state.pendingRequest = nil;
            return;
        end
    end,

    onRender = function(state)
        -- Tick the craft-recipe auto-refresh debounce
        if craftRefreshDebounce.pending
           and os.clock() - craftRefreshDebounce.at >= craftRefreshDebounce.delay then
            craftRefreshDebounce.pending = false;
            if craftItemId > 0 and craftLoaded then
                craftRecipes = {};
                craftLoaded  = false;
                state.pendingRequest = 'crafting';
                local p = pkt.make();
                p[5] = pkt.C2S.GET_RECIPE;
                pkt.writeU16(p, 0x08, craftItemId);
                pkt.sendRaw(p);
            end
        end
    end,

    commands = {
        craft = function(state)
            state.isOpen[1] = true;
        end,
    },

    onUnload = function()
        craftIndex     = nil;
        craftIndexSize = 0;
    end,
};
