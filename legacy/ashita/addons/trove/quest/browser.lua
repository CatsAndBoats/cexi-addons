--[[
* trove/quest/browser.lua — Tabbed quest browser panel
*
* Tabs: Quests (+ server-specific tabs via plugins)
* Quests grouped by status. Click any entry for details.
* Adapted from LQS panels/quests.lua for trove plugin system.
]]--

local imgui  = require('imgui');
local lqs_ui = require('utils/ui');

-- Injected by quest plugin via browser.setContext()
local items  = nil;  -- { renderIcon, getName, renderTooltip }
local config = nil;  -- { get, set }

local quests = {};

-- Called by the quest plugin after init to inject dependencies
quests.setContext = function(itemsAdapter, configAdapter)
    items  = itemsAdapter;
    config = configAdapter;
end

local WINDOW_WIDTH  = 400;
local WINDOW_HEIGHT = 500;

-- Status labels and colors
local STATUS_LABELS = { [0] = 'Available', [1] = 'In Progress', [2] = 'Completed' };
local STATUS_COLORS = { [0] = 'yellow', [1] = 'accent', [2] = 'green' };
local STATUS_ORDER  = { 1, 0, 2 };

-- Built-in tabs (Dailies/Instances are plugins)
local TABS = {
    { id = 'quest', label = 'Quests' },
};

-- Track which tab a quest was selected from (for breadcrumb)
local activeTabLabel = nil;

------------------------------------------------------------
-- Quest detail sub-panel (shared across all tabs)
------------------------------------------------------------
local function renderDetail(state, bgTex)
    local q = state.selectedQuest;
    if q == nil then return; end

    -- Breadcrumb
    local tabName = activeTabLabel or 'LQS';
    imgui.PushStyleColor(ImGuiCol_Button, { 0, 0, 0, 0 });
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.3, 0.2, 0.4, 0.3 });
    imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.3, 0.2, 0.4, 0.5 });
    if imgui.SmallButton(tabName .. '##bc_tab') then
        state.selectedQuest = nil;
    end
    imgui.PopStyleColor(3);
    imgui.SameLine(0, 4);
    lqs_ui.dim('>');
    imgui.SameLine(0, 4);
    imgui.TextColored(lqs_ui.color('white'), q.name);
    imgui.Separator();
    imgui.Spacing();

    imgui.BeginChild('##quest_detail', { 0, -4 }, false);

    -- Quest name header + Track button
    lqs_ui.colored(q.name, 'header');
    imgui.SameLine();
    local isTracked = state.trackedQuest and state.trackedQuest == q.name;
    if isTracked then
        if lqs_ui.button('Untrack', 'back', { 70, 20 }) then
            state.trackedQuest = nil;
        end
    else
        if lqs_ui.button('Track', 'positive', { 70, 20 }) then
            state.trackedQuest = q.name;
        end
    end
    imgui.Spacing();

    -- Author
    if q.author and q.author ~= '' then
        lqs_ui.kv('Author:', q.author);
    end

    -- Subcategory
    if q.subcategory and q.subcategory ~= '' then
        lqs_ui.kv('Type:', q.subcategory, 'dimmed', 'blue');
    end

    -- Status badge
    local statusLabel = STATUS_LABELS[q.status] or 'Unknown';
    local statusColor = STATUS_COLORS[q.status] or 'white';
    lqs_ui.kv('Status:', statusLabel, 'dimmed', statusColor);

    -- Progress bar
    imgui.Spacing();
    local progress = 0;
    if q.total and q.total > 0 then
        progress = q.step / q.total;
        if progress > 1.0 then progress = 1.0; end
    end
    imgui.PushStyleColor(ImGuiCol_PlotHistogram, lqs_ui.color('accent'));
    imgui.ProgressBar(progress, { -1, 16 },
        string.format('%d / %d', q.step or 0, q.total or 0));
    imgui.PopStyleColor(1);

    -- Steps list
    if q.steps and #q.steps > 0 then
        imgui.Spacing();
        lqs_ui.sectionHeader('Objectives');
        imgui.Spacing();

        -- charvar 0 = steps[1], charvar 1 = steps[2], etc.
        local currentStep = (q.step or 0) + 1;

        -- Colors for entity types
        local NPC_COLOR = { 0.75, 0.55, 1.00, 1.0 };  -- purple
        local MOB_COLOR = { 1.00, 0.45, 0.45, 1.0 };  -- red
        local ZONE_COLOR = { 1.00, 0.70, 0.35, 1.0 }; -- orange

        -- Build key for merging
        local function stepKey(step)
            return (step.action or '') .. '|' .. (step.entity or '') .. '|' .. (step.zone or '');
        end

        -- Build display list, merging consecutive duplicates
        local displayed = {};
        for si, step in ipairs(q.steps) do
            local prev = displayed[#displayed];
            if prev and stepKey(step) == stepKey(prev) then
                table.insert(prev.indices, si);
            else
                local entry = {
                    action  = step.action or 'Speak to',
                    entity  = step.entity or '?',
                    mob     = step.mob,
                    zone    = step.zone,
                    trade   = step.trade,
                    indices = { si },
                };
                table.insert(displayed, entry);
            end
        end

        for _, entry in ipairs(displayed) do
            local isCurrent = false;
            local isDone = true;
            for _, idx in ipairs(entry.indices) do
                if idx == currentStep or (currentStep == 0 and idx == 1) then
                    isCurrent = true;
                end
                if idx >= currentStep and currentStep > 0 then
                    isDone = false;
                end
            end
            if isCurrent then isDone = false; end

            local stepColor = lqs_ui.color('dimmed');
            local entityColor = entry.mob and MOB_COLOR or NPC_COLOR;
            local zoneColor = ZONE_COLOR;
            if isCurrent then
                stepColor = lqs_ui.color('white');
            end
            -- Entity and zone keep their colors even when done/dimmed

            imgui.Indent(16);
            if isCurrent then
                imgui.TextColored(lqs_ui.color('yellow'), '>');
                imgui.SameLine(0, 4);
            end

            -- Render: "Action" + trade items + "Entity" + "in Zone"
            if entry.trade and #entry.trade > 0 then
                imgui.TextColored(stepColor, 'Trade');
                imgui.SameLine(0, 4);
                for ti, req in ipairs(entry.trade) do
                    if ti > 1 then
                        imgui.SameLine(0, 2);
                        imgui.TextColored(stepColor, ',');
                        imgui.SameLine(0, 4);
                    end
                    if items.renderIcon(req.id, 16) then
                        imgui.SameLine(0, 4);
                    end
                    local reqName = items.getName(req.id);
                    if req.qty and req.qty > 1 then
                        reqName = reqName .. ' x' .. req.qty;
                    end
                    imgui.TextColored({ 0.40, 0.90, 0.40, 1.0 }, reqName);
                    if imgui.IsItemHovered() then items.renderTooltip(req.id); end
                    imgui.SameLine(0, 4);
                end
                imgui.TextColored(stepColor, ' to ');
                imgui.SameLine(0, 0);
                imgui.TextColored(entityColor, entry.entity);
            else
                imgui.TextColored(stepColor, entry.action .. ' ');
                imgui.SameLine(0, 0);
                imgui.TextColored(entityColor, entry.entity);
            end

            if entry.zone and entry.zone ~= '' then
                imgui.SameLine(0, 0);
                imgui.TextColored(stepColor, ' in ');
                imgui.SameLine(0, 0);
                imgui.TextColored(zoneColor, entry.zone);
            end

            imgui.Unindent(16);
        end
    elseif q.hint and q.hint ~= '' then
        imgui.Spacing();
        lqs_ui.dim('Current objective:');
        imgui.PushTextWrapPos(0);
        imgui.TextColored(lqs_ui.color('white'), q.hint);
        imgui.PopTextWrapPos();
    end

    -- Feature unlocks (from reward cache)
    imgui.Spacing();
    if q.feature and q.feature ~= '' then
        local featureList = {};
        for f in q.feature:gmatch('[^,]+') do
            local trimmed = f:match('^%s*(.-)%s*$');
            if trimmed ~= '' then
                table.insert(featureList, trimmed);
            end
        end

        if #featureList > 0 then
            lqs_ui.sectionHeader('Unlocks', #featureList);
            imgui.Spacing();

            local base = lqs_ui.color('childBg');
            local boxBg = { base[1] + 0.04, base[2] + 0.03, base[3] + 0.08, 0.90 };
            local cyan = { 0.55, 0.85, 1.00, 1.00 };

            for fi, feat in ipairs(featureList) do
                local featId = string.format('##feat_%d', fi);
                imgui.PushStyleColor(ImGuiCol_ChildBg, boxBg);
                imgui.BeginChild(featId, { -1, 30 }, false);

                local dl = imgui.GetWindowDrawList();
                local wx, wy = imgui.GetWindowPos();
                dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 30 },
                    imgui.GetColorU32(cyan));

                imgui.SetCursorPos({ 10, 7 });
                imgui.TextColored(cyan, '\xE2\x98\x85');
                imgui.SameLine(0, 6);
                imgui.TextColored(lqs_ui.color('white'), feat);

                imgui.EndChild();
                imgui.PopStyleColor(1);
                imgui.Spacing();
            end
        end
    end

    -- Required items
    if q.required and #q.required > 0 then
        lqs_ui.sectionHeader('Required', #q.required);
        imgui.Spacing();
        for ri, req in ipairs(q.required) do
            if req.id and req.id > 0 then
                local reqId = string.format('##req_%d_%d', req.id, ri);
                local base = lqs_ui.color('childBg');
                local reqBg = { base[1] + 0.02, base[2] + 0.02, base[3] + 0.04, 0.70 };

                imgui.PushStyleColor(ImGuiCol_ChildBg, reqBg);
                imgui.BeginChild(reqId, { -1, 32 }, false);

                local dl = imgui.GetWindowDrawList();
                local wx, wy = imgui.GetWindowPos();
                dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 32 },
                    imgui.GetColorU32(lqs_ui.color('yellow')));

                imgui.SetCursorPos({ 6, 4 });
                if not items.renderIcon(req.id, 24) then imgui.Dummy({ 24, 24 }); end
                imgui.SameLine(0, 6);
                imgui.SetCursorPosY(8);
                imgui.TextColored(lqs_ui.color('white'), items.getName(req.id));

                if req.qty and req.qty > 1 then
                    local qtyStr = string.format('x%d', req.qty);
                    local ww = imgui.GetWindowWidth();
                    local qtyW = imgui.CalcTextSize(qtyStr);
                    local qdl = imgui.GetWindowDrawList();
                    qdl:AddText({ wx + ww - qtyW - 8, wy + 9 },
                        imgui.GetColorU32(lqs_ui.color('yellow')), qtyStr);
                end

                imgui.SetCursorPos({ 0, 0 });
                imgui.Selectable(string.format('##rqsel_%d_%d', req.id, ri), false,
                    ImGuiSelectableFlags_SpanAllColumns, { 0, 32 });
                if imgui.IsItemHovered() then items.renderTooltip(req.id); end

                imgui.EndChild();
                imgui.PopStyleColor(1);
            end
        end
        imgui.Spacing();
    end

    -- Rewards section
    lqs_ui.sectionHeader('Rewards');
    imgui.Spacing();

    local r = state.reward;
    if r then
        -- Gil
        if r.gil and r.gil > 0 then
            local gilId = string.format('##reward_gil_%d', r.gil);
            local base = lqs_ui.color('childBg');
            local boxBg = { base[1] + 0.04, base[2] + 0.04, base[3] + 0.06, 0.90 };

            imgui.PushStyleColor(ImGuiCol_ChildBg, boxBg);
            imgui.BeginChild(gilId, { -1, 36 }, false);

            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 36 },
                imgui.GetColorU32(lqs_ui.color('yellow')));

            imgui.SetCursorPos({ 10, 6 });
            if not items.renderIcon(65535, 24) then imgui.Dummy({ 24, 24 }); end
            imgui.SameLine(0, 8);
            imgui.SetCursorPosY(9);
            imgui.TextColored(lqs_ui.color('white'), 'Gil');

            local gilStr = tostring(r.gil);
            local ww = imgui.GetWindowWidth();
            local gilW = imgui.CalcTextSize(gilStr);
            imgui.SameLine(ww - gilW - 12);
            imgui.SetCursorPosY(9);
            imgui.TextColored(lqs_ui.color('yellow'), gilStr);

            imgui.EndChild();
            imgui.PopStyleColor(1);
            imgui.Spacing();
        end

        -- Exp
        if r.exp and r.exp > 0 then
            imgui.Indent(8);
            lqs_ui.kv('Exp:', tostring(r.exp), 'dimmed', 'blue');
            imgui.Unindent(8);
        end

        -- Items
        if r.items then
            for idx, itm in ipairs(r.items) do
                if itm.id and itm.id > 0 then
                    local rowId = string.format('##reward_item_%d_%d', itm.id, idx);
                    local base = lqs_ui.color('childBg');
                    local boxBg = { base[1] + 0.04, base[2] + 0.04, base[3] + 0.06, 0.90 };

                    imgui.PushStyleColor(ImGuiCol_ChildBg, boxBg);
                    imgui.BeginChild(rowId, { -1, 36 }, false);

                    local dl = imgui.GetWindowDrawList();
                    local wx, wy = imgui.GetWindowPos();
                    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 36 },
                        imgui.GetColorU32(lqs_ui.color('accent')));

                    imgui.SetCursorPos({ 10, 6 });
                    if not items.renderIcon(itm.id, 24) then imgui.Dummy({ 24, 24 }); end
                    imgui.SameLine(0, 8);

                    imgui.SetCursorPosY(9);
                    imgui.TextColored(lqs_ui.color('white'), items.getName(itm.id));

                    if itm.qty and itm.qty > 1 then
                        local qtyStr = string.format('x%d', itm.qty);
                        local ww = imgui.GetWindowWidth();
                        local qtyW = imgui.CalcTextSize(qtyStr);
                        imgui.SameLine(ww - qtyW - 12);
                        imgui.SetCursorPosY(9);
                        imgui.TextColored(lqs_ui.color('dimmed'), qtyStr);
                    end

                    imgui.SetCursorPos({ 0, 0 });
                    imgui.Selectable(string.format('##rsel_%d_%d', itm.id, idx), false,
                        ImGuiSelectableFlags_SpanAllColumns, { 0, 36 });
                    if imgui.IsItemHovered() then
                        items.renderTooltip(itm.id, itm.qty);
                    end

                    imgui.EndChild();
                    imgui.PopStyleColor(1);
                    imgui.Spacing();
                end
            end
        end
    elseif q.rewardText and q.rewardText ~= '' then
        imgui.Indent(8);
        imgui.TextWrapped(q.rewardText);
        imgui.Unindent(8);
    else
        imgui.Indent(8);
        lqs_ui.dim('None');
        imgui.Unindent(8);
    end

    imgui.EndChild();
end

------------------------------------------------------------
-- Render a single quest row (reused across tabs)
------------------------------------------------------------
local function renderQuestRow(q, index, state, callbacks)
    local statusColor = STATUS_COLORS[q.status] or 'white';
    local rowId = string.format('##qrow_%s_%d', q.name, index);

    local isTracked = state.trackedQuest and state.trackedQuest == q.name;

    local base = lqs_ui.color('childBg');
    local isAlt = (index % 2 == 0);
    local bgColor;
    if isTracked then
        bgColor = { 0.25, 0.20, 0.08, 0.60 };  -- warm gold tint
    elseif isAlt then
        bgColor = { base[1], base[2], base[3], 0.35 };
    else
        bgColor = { base[1], base[2], base[3], 0.20 };
    end

    -- Build hint from steps with correct offset
    local hintFromSteps = '';
    if q.steps and q.status ~= 2 then
        local stepIdx = (q.step or 0) + 1;
        local step = q.steps[stepIdx] or q.steps[1];
        if step then
            hintFromSteps = (step.action or 'Speak to') .. ' ' .. (step.entity or '');
            if step.zone and step.zone ~= '' then
                hintFromSteps = hintFromSteps .. ' in ' .. step.zone;
            end
        end
    end
    local hasHint = hintFromSteps ~= '' and q.status ~= 2;
    local rowHeight = hasHint and 50 or 34;

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(rowId, { -1, rowHeight }, false);

    imgui.SetCursorPosY(0);
    local clicked = imgui.Selectable(
        string.format('##qsel_%s_%d', q.name, index),
        false, ImGuiSelectableFlags_SpanAllColumns, { 0, rowHeight });

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Tracked quest border
    if isTracked then
        dl:AddRect({ wx, wy }, { wx + ww, wy + rowHeight },
            imgui.GetColorU32({ 1.0, 0.85, 0.20, 0.6 }), 0, 0, 2.0);
    end
    local nameX = wx + 8;
    if isTracked then
        dl:AddText({ nameX, wy + 4 },
            imgui.GetColorU32(lqs_ui.color('yellow')), '>');
        nameX = nameX + 12;
    end

    local nameStr = q.name;
    if q.status ~= 2 then
        nameStr = string.format('%s  (%d/%d)', q.name, q.step, q.total);
    end
    dl:AddText({ nameX, wy + 4 },
        imgui.GetColorU32(lqs_ui.color('white')), nameStr);

    -- Status badge on right
    local statusText = STATUS_LABELS[q.status] or '';
    local stW = imgui.CalcTextSize(statusText);
    dl:AddText({ wx + ww - stW - 8, wy + 4 },
        imgui.GetColorU32(lqs_ui.color(statusColor)), statusText);

    -- Hint on second line (full width)
    if hasHint then
        local hintText = hintFromSteps;
        -- Truncate only if really long
        local maxW = ww - 16;
        while imgui.CalcTextSize(hintText) > maxW and #hintText > 10 do
            hintText = hintText:sub(1, -4) .. '..';
        end
        dl:AddText({ wx + 8, wy + 22 },
            imgui.GetColorU32(lqs_ui.color('dimmed')), hintText);
    elseif q.status == 2 then
        dl:AddText({ wx + 8, wy + 18 },
            imgui.GetColorU32(lqs_ui.color('dimmed')), 'Completed');
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);

    if clicked then
        -- Build feature string from reward data
        local featureStr = '';
        if q.reward and q.reward.feature then
            if type(q.reward.feature) == 'table' then
                featureStr = table.concat(q.reward.feature, ', ');
            else
                featureStr = q.reward.feature;
            end
        end

        state.selectedQuest = {
            name        = q.name,
            author      = q.author,
            status      = q.status,
            step        = q.step,
            total       = q.total,
            hint        = q.hint,
            feature     = featureStr,
            subcategory = q.subcategory or '',
            required    = q.required,
            steps       = q.steps,
            rewardText  = '',
        };

        -- Build reward from local quest data
        if q.reward then
            local rewardItems = {};
            if q.reward.items then
                for _, itemId in ipairs(q.reward.items) do
                    table.insert(rewardItems, { id = itemId, qty = 1, icon = itemId });
                end
            end
            state.reward = {
                gil   = q.reward.gil or 0,
                exp   = q.reward.exp or 0,
                items = rewardItems,
            };
        else
            state.reward = nil;
        end
    end
end

------------------------------------------------------------
-- Region tints (colored category backgrounds)
------------------------------------------------------------
local REGION_TINTS = {
    ["Bastok"]       = { 0.12, 0.14, 0.22 },
    ["San d'Oria"]   = { 0.20, 0.12, 0.12 },
    ["Windurst"]     = { 0.12, 0.18, 0.12 },
    ["Jeuno"]        = { 0.20, 0.18, 0.10 },
    ["Aht Urhgan"]   = { 0.18, 0.15, 0.10 },
    ["Other Areas"]  = { 0.14, 0.14, 0.16 },
    ["Battle"]       = { 0.18, 0.10, 0.10 },
    ["Outlands"]     = { 0.14, 0.16, 0.14 },
};

local REGION_ORDER = { "Bastok", "San d'Oria", "Windurst", "Jeuno", "Aht Urhgan", "Other Areas", "Battle", "Outlands" };

------------------------------------------------------------
-- Quests tab: grouped by region with colored headers
------------------------------------------------------------
local function renderQuestsTab(filtered, state, callbacks)
    -- Group by region
    local regions = {};
    local regionOrder = {};

    for _, q in ipairs(filtered) do
        local region = q.region or 'Other Areas';
        if regions[region] == nil then
            regions[region] = {};
            table.insert(regionOrder, region);
        end
        table.insert(regions[region], q);
    end

    -- Sort regions by predefined order
    table.sort(regionOrder, function(a, b)
        local ai, bi = 99, 99;
        for i, r in ipairs(REGION_ORDER) do
            if r == a then ai = i; end
            if r == b then bi = i; end
        end
        return ai < bi;
    end);

    imgui.BeginChild('##quest_scroll', { 0, -4 }, false);

    for _, region in ipairs(regionOrder) do
        local group = regions[region];
        if group and #group > 0 then
            local tint = REGION_TINTS[region] or { 0.14, 0.12, 0.20 };
            local barColor = { tint[1] * 2.5, tint[2] * 2.5, tint[3] * 2.5, 1.0 };

            -- Colored region header
            local hdrId = string.format('##rhdr_%s', region);
            local headerBg = { tint[1] + 0.05, tint[2] + 0.05, tint[3] + 0.08, 0.90 };

            imgui.PushStyleColor(ImGuiCol_ChildBg, headerBg);
            imgui.BeginChild(hdrId, { -1, 24 }, false);

            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 24 }, imgui.GetColorU32(barColor));

            imgui.SetCursorPosX(10);
            imgui.SetCursorPosY(4);
            imgui.TextColored(barColor, region);

            local countStr = string.format('(%d)', #group);
            local ww = imgui.GetWindowWidth();
            local countW = imgui.CalcTextSize(countStr);
            imgui.SameLine(ww - countW - 12);
            imgui.TextColored(lqs_ui.color('dimmed'), countStr);

            imgui.EndChild();
            imgui.PopStyleColor(1);

            imgui.Spacing();

            for i, q in ipairs(group) do
                renderQuestRow(q, i, state, callbacks);
            end

            imgui.Spacing();
        end
    end

    imgui.EndChild();
end


------------------------------------------------------------
-- Main render
------------------------------------------------------------
-- Render inside a trove tab (no own window — trove handles the window chrome)
quests.render = function(state, bgTex, callbacks, plugins)
    -- Detail view (shared across tabs)
    if state.selectedQuest then
        renderDetail(state, bgTex);
    else
        if not state.questListLoaded then
            lqs_ui.dim('Loading...');
        elseif #state.questList == 0 then
            lqs_ui.dim('No content found.');
        else
            -- Filter quests
            local filtered = {};
            for _, q in ipairs(state.questList) do
                if (q.category or 'quest') == 'quest' then
                    table.insert(filtered, q);
                end
            end

            imgui.Spacing();
            renderQuestsTab(filtered, state, callbacks);
        end
    end
end

return quests;
