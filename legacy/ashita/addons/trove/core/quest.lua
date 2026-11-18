--[[
* trove/plugins/quest.lua — Quest browser, tracker, and content guide
*
* Provides a tab in the trove window with a quest browser, plus floating
* HUD elements (tracker overlay, toast notifications).
*
* Quest data is loaded from data/questdata.lua in the server-specific
* plugins/ directory. If no quest data is available, the tab
* shows a message instead.
*
* Uses trove's 0x1A4 plugin data protocol (pluginId 10) for quest
* status updates from the server.
*
* Command: /trove quest
]]--

local imgui    = require('imgui');
local pkt      = require('utils/packet');

-- Sub-modules (loaded from trove/quest/)
local browser  = require('quest/browser');
local toast    = require('quest/toast');
local tracker  = require('quest/tracker');
local textures = require('utils/textures');

------------------------------------------------------------
-- Shared (injected via init / setContext)
------------------------------------------------------------
local renderIcon    = nil;
local getItemRes    = nil;
local ui            = nil;
local renderTooltip = nil;

------------------------------------------------------------
-- Quest status protocol constants
------------------------------------------------------------
local QUEST_NAME_LEN  = 20;
local QUEST_ENTRY_SIZE = 22;  -- name[20] + status(1) + step(1)
local QUEST_BATCH_OFFSET = 0x06;

------------------------------------------------------------
-- Config (simple key-value, persisted to file)
------------------------------------------------------------
local configData = {
    theme               = 'default',
    backgroundStyle     = '0',
    showDailiesInTracker = true,
    showCompass          = true,
};

local configPath = nil;

local configAdapter = {
    get = function(key)
        return configData[key];
    end,
    set = function(key, value)
        configData[key] = value;
        -- Save to file
        if configPath then
            local f = io.open(configPath, 'w');
            if f then
                f:write('return {\n');
                for k, v in pairs(configData) do
                    if type(v) == 'string' then
                        f:write(string.format("    %s = '%s',\n", k, v));
                    elseif type(v) == 'boolean' then
                        f:write(string.format("    %s = %s,\n", k, tostring(v)));
                    end
                end
                f:write('}\n');
                f:close();
            end
        end
    end,
};

local function loadConfig()
    local dir = string.format('%sconfig\\addons\\trove\\', AshitaCore:GetInstallPath());
    configPath = dir .. 'quest_settings.lua';

    -- Try loading saved config
    local ok, saved = pcall(dofile, configPath);
    if ok and type(saved) == 'table' then
        for k, v in pairs(saved) do
            configData[k] = v;
        end
    end
end

------------------------------------------------------------
-- Items adapter (wraps trove's injected helpers)
------------------------------------------------------------
local itemsAdapter = {
    renderIcon = function(itemId, size)
        if renderIcon then return renderIcon(itemId, size); end
        return false;
    end,
    getName = function(itemId)
        if getItemRes then
            local res = getItemRes(itemId);
            if res and res.Name and res.Name[1] then
                return res.Name[1];
            end
        end
        return tostring(itemId);
    end,
    renderTooltip = function(itemId, qty)
        if renderTooltip then
            local res = getItemRes(itemId);
            local name = (res and res.Name and res.Name[1]) or tostring(itemId);
            renderTooltip({ id = itemId, name = name, qty = qty or 0 });
        end
    end,
};

------------------------------------------------------------
-- State
------------------------------------------------------------
local questList       = {};
local questListLoaded = false;
local selectedQuest   = nil;
local trackedQuest    = nil;
local lastStatusPoll  = 0;
local connected       = false;

-- Try loading quest data from server-specific directory
local questdata = nil;

local function loadQuestData()
    -- Try plugins/data/questdata first, then data/questdata
    local ok, data = pcall(require, 'plugins/data/questdata');
    if ok and type(data) == 'table' then
        questdata = data;
        return;
    end
    -- Try core data directory
    ok, data = pcall(require, 'data/questdata');
    if ok and type(data) == 'table' then
        questdata = data;
        return;
    end
    -- No quest data available
    questdata = nil;
end

local function buildQuestList()
    if questdata == nil then return; end
    questList = {};
    for _, q in pairs(questdata) do
        table.insert(questList, {
            name        = q.name,
            author      = q.author or '',
            status      = 0,
            step        = 0,
            total       = q.total or 1,
            hint        = '',
            category    = q.category or 'quest',
            subcategory = q.subcategory or '',
            region      = q.region or '',
            var         = q.var or '',
            reward      = q.reward,
            required    = q.required,
            steps       = q.steps,
            feature     = '',
        });
    end
    questListLoaded = true;
end

------------------------------------------------------------
-- Packet: request quest status (batched)
------------------------------------------------------------
local function requestQuestList()
    pkt.send(pkt.C2S.GET_QUEST_STATUS);
end

------------------------------------------------------------
-- Sub-tab registry (server plugins register here)
------------------------------------------------------------
local subTabs = {};

local function registerSubTab(name, renderFn, order)
    subTabs[#subTabs + 1] = { name = name, render = renderFn, order = order or 50 };
    table.sort(subTabs, function(a, b) return a.order < b.order; end);
end

------------------------------------------------------------
-- Window state
------------------------------------------------------------
local isOpen = { false };

local lqs_ui = require('utils/ui');

------------------------------------------------------------
-- Render: floating window content
------------------------------------------------------------
local function renderWindowContent(state)
    if questdata == nil and #subTabs == 0 then
        imgui.Spacing(); imgui.Spacing();
        imgui.TextColored(ui.color('dimmed'), 'No quest data available for this server.');
        return;
    end

    if questdata and not questListLoaded then
        buildQuestList();
        requestQuestList();
    end

    -- Build the state object expected by browser.render()
    local questState = {
        questList       = questList,
        questListLoaded = questListLoaded,
        selectedQuest   = selectedQuest,
        trackedQuest    = trackedQuest,
    };

    local bgTex = nil;
    local bgStyle = tonumber(configAdapter.get('backgroundStyle') or '0') or 0;
    if bgStyle > 0 then
        bgTex = textures.getMenuBackground(bgStyle);
    end

    -- Tab bar: Quests + server-specific sub-tabs
    if imgui.BeginTabBar('##quest_tabs') then
        -- Quests tab (only if quest data exists)
        if questdata and imgui.BeginTabItem('Quests') then
            browser.render(questState, bgTex, {
                requestList = function() requestQuestList(); end,
            }, {});
            imgui.EndTabItem();
        end

        -- Server-specific sub-tabs
        for _, sub in ipairs(subTabs) do
            if imgui.BeginTabItem(sub.name) then
                local ok, err = pcall(sub.render, state);
                if not ok then
                    imgui.TextColored({ 1, 0.3, 0.3, 1 }, 'Error: ' .. tostring(err));
                end
                imgui.EndTabItem();
            end
        end

        imgui.EndTabBar();
    end

    -- Sync state back
    selectedQuest = questState.selectedQuest;
    trackedQuest  = questState.trackedQuest;
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
local questPlugin = {
    name        = 'Quests',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Quest browser with tracker and notifications',

    -- Public: other plugins call this to add sub-tabs
    registerSubTab = registerSubTab,

    init = function(ri, gir, uimod, rt, rfi, rfimg, gih)
        renderIcon    = ri;
        getItemRes    = gir;
        ui            = uimod;
        renderTooltip = rt;

        loadConfig();
        loadQuestData();

        browser.setContext(itemsAdapter, configAdapter);
        tracker.setConfig(configAdapter);
        tracker.init();

        toast.onQuestEvent = function() end;
    end,

    -- Floating window (toggled from top bar button or Menu)
    window = {
        category = 'Utility',
        label  = 'Quests',
        icon   = 634,    -- Poetic Parchment
        isOpen = isOpen,
        render = function()
            local styleCount = lqs_ui.pushWindowStyle();
            imgui.SetNextWindowSize({ 400, 500 }, ImGuiCond_FirstUseEver);
            imgui.SetNextWindowSizeConstraints({ 340, 280 }, { 520, 900 });
            if imgui.Begin('Quests###trove_quests', isOpen, ImGuiWindowFlags_None) then
                local bgPushed = lqs_ui.renderBackground();
                renderWindowContent({});
                if bgPushed > 0 then imgui.PopStyleColor(bgPushed); end
            end
            imgui.End();
            lqs_ui.popWindowStyle(styleCount);
        end,
    },

    -- Top bar button for quick access
    topBarButton = {
        label  = 'Quest',
        action = function()
            isOpen[1] = not isOpen[1];
        end,
    },

    onPacketIn = function(e, state)
        toast.checkChat(e);

        if e.id ~= pkt.PACKET_ID then return; end
        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        if action == pkt.S2C.QUEST_STATUS_BATCH then
            -- Parse batched quest status entries
            -- 0x05: flags (bit 0 = final batch)
            -- 0x06+: entries × { name[20] + status(1) + step(1) }
            local offset = QUEST_BATCH_OFFSET;

            while offset + QUEST_ENTRY_SIZE <= 256 do
                local questName = pkt.readString(e.data_modified, offset, QUEST_NAME_LEN);
                if questName == '' then break; end -- no more entries in this batch

                local questStatus = struct.unpack('B', e.data_modified, offset + QUEST_NAME_LEN + 1);
                local questStep   = struct.unpack('B', e.data_modified, offset + QUEST_NAME_LEN + 1 + 1);

                local nameLower = questName:lower();
                for _, q in ipairs(questList) do
                    if q.name:lower() == nameLower then
                        q.status = questStatus;
                        q.step   = questStep;
                        break;
                    end
                end
                if selectedQuest and selectedQuest.name:lower() == nameLower then
                    selectedQuest.status = questStatus;
                    selectedQuest.step   = questStep;
                end

                offset = offset + QUEST_ENTRY_SIZE;
            end
            return;
        end
    end,

    onRender = function(state)
        toast.render();

        if trackedQuest then
            local now = os.clock();
            if now - lastStatusPoll > 5 then
                lastStatusPoll = now;
                requestQuestList();
            end
        end
        tracker.update(questList, nil, trackedQuest);
        tracker.render();
    end,

    onUnload = function()
        toast.cleanup();
        tracker.cleanup();
    end,

    commands = {
        quest = function(state)
            isOpen[1] = not isOpen[1];
        end,
    },
};

return questPlugin;
