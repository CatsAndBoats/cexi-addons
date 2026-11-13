--[[
* lqs/plugins/dailies.lua — Daily content tracker
*
* Tracks Goblin Dailies and Storming Sea objectives by intercepting
* NPC dialog and quest update messages. Replaces Goldilox addon.
*
* State resets at JST midnight automatically.
]]--

local imgui    = require('imgui');
local settings = require('settings');

local ui    = nil;
local items = nil;

------------------------------------------------------------
-- JST timer
------------------------------------------------------------
local JST_OFFSET = 9 * 60 * 60;

local function getJstDeadline()
    return 86400 + (math.floor((os.time() + JST_OFFSET) / 86400) * 86400) - JST_OFFSET;
end

local function getTimeUntilReset()
    local remaining = getJstDeadline() - os.time();
    if remaining < 0 then remaining = 0; end
    local hours = math.floor(remaining / 3600);
    local mins  = math.floor((remaining % 3600) / 60);
    return string.format('%dh %02dm', hours, mins);
end

------------------------------------------------------------
-- Persistent state (per character, resets daily)
------------------------------------------------------------
local defaults = T{
    deadline = 0,
    goblins  = {},
    sea      = {},
};

local state = nil;
local ZONE_LOWER_JEUNO = 245;
local ZONE_HUXZOI = 34;

local function ensureState()
    if state == nil then
        state = settings.load(defaults);
    end
    local deadline = getJstDeadline();
    if state.version ~= 1 or state.deadline ~= deadline then
        state.goblins = {};
        state.sea = {};
        state.deadline = deadline;
        state.version = 1;
        settings.save();
    end
end

------------------------------------------------------------
-- Goblin Dailies
------------------------------------------------------------
local GOBLIN_ORDER = { 'Fishstix', 'Murdox', 'Mistrix', 'Saltlix', 'Beetrix' };

local GOBLIN_ICONS = {
    Fishstix = '\xE2\x9C\xA6',  -- chest
    Murdox   = '\xE2\x9A\x94',  -- kill
    Mistrix  = '\xE2\x9A\x92',  -- craft
    Saltlix  = '\xE2\x9A\x94',  -- kill NM
    Beetrix  = '\xE2\x9C\xA6',  -- fetch
};

local goblinHandlers = {
    Fishstix = {
        parse = function(msg)
            local zone = msg:match('Go to (.-),');
            if zone then return 'Find chest at ' .. zone; end
        end,
    },
    Murdox = {
        parse = function(msg)
            local zone, count, target = msg:match('Go to (.+) and kill (%d+) (.+)!');
            if zone then return string.format('Kill %s %s at %s', count, target, zone); end
        end,
        updateKills = function(msg)
            local kills = msg:match('Daily Quest: (%d+) kills? remain');
            if kills then return string.format('%s kills remaining', kills); end
        end,
    },
    Mistrix = {
        parse = function(msg)
            local item = msg:match('Craft me up %a+ signed (.+) and trade it to me!');
            if item then return 'Trade signed ' .. item; end
        end,
    },
    Saltlix = {
        parse = function(msg)
            local zone, target = msg:match('Go to (.+) and kill (.+)!');
            if zone then return 'Kill ' .. target .. ' at ' .. zone; end
        end,
    },
    Beetrix = {
        parse = function(msg)
            local zone, item = msg:match('Go to (.+), get %a+ (.+) and trade it to me!');
            if zone then return 'Trade ' .. item .. ' from ' .. zone; end
        end,
    },
};

------------------------------------------------------------
-- Storming Sea (Palalumin)
------------------------------------------------------------
local SEA_ORDER = { 'Item request', 'Find flux', 'Defeat mobs' };

local SEA_ICONS = {
    ['Item request'] = '\xE2\x9C\xA6',
    ['Find flux']    = '\xE2\x98\x85',
    ['Defeat mobs']  = '\xE2\x9A\x94',
};

local seaHandlers = {
    ['Find flux'] = function(msg)
        return 'Find flux in ' .. msg;
    end,
    ['Item request'] = function(msg)
        return 'Trade ' .. msg;
    end,
    ['Defeat mobs'] = function(msg)
        local target, zone, killed, total = msg:match('(.+) %((.+)%) (%d+)/(%d+)');
        if target then
            local remaining = tonumber(total) - tonumber(killed);
            return string.format('Kill %d more %s at %s (%s total)', remaining, target, zone, total);
        end
        return msg;
    end,
};

------------------------------------------------------------
-- Text event handler (intercept NPC dialog + quest updates)
------------------------------------------------------------
local function onTextIn(e)
    if e.injected then return; end
    ensureState();

    local channel = e.mode % 256;

    -- Quest update messages (channel 121)
    if channel == 121 then
        local msg = e.message or '';

        -- "please return to X to claim your reward!"
        local npc = msg:match('.*, please return to (%a+) to claim your reward!');
        if npc and goblinHandlers[npc] then
            state.goblins[npc] = { status = 'return', objective = 'Return to ' .. npc };
            settings.save();
            return;
        end

        -- Kill counter update
        local kills = msg:match('Daily Quest: (%d+) kills? remain');
        if kills and state.goblins.Murdox then
            state.goblins.Murdox.objective = kills .. ' kills remaining';
            settings.save();
            return;
        end

        -- Goldilox dice roll
        if msg:match('Dice roll!') then
            state.goldilox = 'complete';
            settings.save();
            return;
        end
        return;
    end

    -- NPC dialog (channel 9)
    if channel == 9 then
        local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        local msg = e.message or '';

        -- Goblin Dailies (Lower Jeuno)
        if zone == ZONE_LOWER_JEUNO then
            local npc, message = msg:match('.-(%a+).-:.-(%a+.*)\n');
            if npc and goblinHandlers[npc] then
                if message:find('completed') then
                    state.goblins[npc] = { status = 'complete', objective = 'Complete!' };
                else
                    local obj = goblinHandlers[npc].parse(message);
                    state.goblins[npc] = { status = 'active', objective = obj or message };
                end
                settings.save();
            end
            return;
        end

        -- Storming Sea (Hu'Xzoi)
        if zone == ZONE_HUXZOI then
            local quest, objective = msg:match('\129\158 (.-): (.+)\n');
            if quest and seaHandlers[quest] then
                local obj = seaHandlers[quest](objective:match('^%s*(.-)%s*$'));
                state.sea[quest] = { status = 'active', objective = obj };
                settings.save();
            end
            return;
        end
    end
end

------------------------------------------------------------
-- Status colors
------------------------------------------------------------
local STATUS_COLORS = {
    none     = { 0.50, 0.50, 0.55, 1.0 },
    active   = { 1.00, 0.92, 0.60, 1.0 },
    ['return'] = { 0.55, 0.85, 1.00, 1.0 },
    complete = { 0.55, 0.90, 0.55, 1.0 },
};

local STATUS_LABELS = {
    none     = 'Not Started',
    active   = 'In Progress',
    ['return'] = 'Return',
    complete = 'Complete',
};

------------------------------------------------------------
-- Render a daily row
------------------------------------------------------------
local function renderDailyRow(name, icon, data, idx)
    local status = data and data.status or 'none';
    local objective = data and data.objective or 'Talk to ' .. name;
    local statusColor = STATUS_COLORS[status] or STATUS_COLORS.none;
    local statusLabel = STATUS_LABELS[status] or 'Not Started';

    local base = ui.color('childBg');
    local rowId = string.format('##daily_%s_%d', name, idx);
    local isAlt = (idx % 2 == 0);
    local bgColor = isAlt
        and { base[1] + 0.02, base[2] + 0.02, base[3] + 0.04, 0.50 }
        or  { base[1], base[2], base[3], 0.30 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(rowId, { -1, 38 }, false);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Status accent bar
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 38 }, imgui.GetColorU32(statusColor));

    -- Name
    dl:AddText({ wx + 10, wy + 4 }, imgui.GetColorU32(ui.color('white')), name);

    -- Objective
    local objStr = objective;
    if #objStr > 45 then objStr = objStr:sub(1, 42) .. '...'; end
    dl:AddText({ wx + 10, wy + 20 }, imgui.GetColorU32(ui.color('dimmed')), objStr);

    -- Status badge on right
    local badgeW = imgui.CalcTextSize(statusLabel);
    local badgeBg = imgui.GetColorU32({ statusColor[1] * 0.3, statusColor[2] * 0.3, statusColor[3] * 0.3, 0.5 });
    dl:AddRectFilled(
        { wx + ww - badgeW - 16, wy + 10 },
        { wx + ww - 4, wy + 26 },
        badgeBg, 3.0);
    dl:AddText(
        { wx + ww - badgeW - 10, wy + 12 },
        imgui.GetColorU32(statusColor), statusLabel);

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Render
------------------------------------------------------------
local function render(addonState, uiLib, itemsLib)
    ui    = uiLib or ui;
    items = itemsLib or items;
    ensureState();

    imgui.BeginChild('##dailies_scroll', { 0, -4 }, false);

    -- Reset timer
    local timerStr = getTimeUntilReset();
    local base = ui.color('childBg');
    local timerBg = { base[1] + 0.03, base[2] + 0.03, base[3] + 0.05, 0.80 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, timerBg);
    imgui.BeginChild('##reset_timer', { -1, 28 }, false);
    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();
    dl:AddText({ wx + 8, wy + 7 }, imgui.GetColorU32(ui.color('dimmed')), 'Daily Reset:');
    local tw = imgui.CalcTextSize(timerStr);
    dl:AddText({ wx + ww - tw - 8, wy + 7 }, imgui.GetColorU32(ui.color('yellow')), timerStr);
    imgui.EndChild();
    imgui.PopStyleColor(1);
    imgui.Spacing();

    -- Goblin Dailies
    local goblinComplete = 0;
    for _, name in ipairs(GOBLIN_ORDER) do
        if state.goblins[name] and state.goblins[name].status == 'complete' then
            goblinComplete = goblinComplete + 1;
        end
    end

    ui.sectionHeader(string.format('Goblin Dailies (%d/5)', goblinComplete));
    imgui.Spacing();

    for idx, name in ipairs(GOBLIN_ORDER) do
        renderDailyRow(name, GOBLIN_ICONS[name], state.goblins[name], idx);
    end

    -- Goldilox bonus
    if goblinComplete >= 5 then
        imgui.Spacing();
        local goldStatus = state.goldilox == 'complete' and 'complete' or 'return';
        local goldColor = STATUS_COLORS[goldStatus];
        local goldLabel = goldStatus == 'complete' and 'Collected!' or 'Bonus Ready!';

        local goldBg = { base[1] + 0.04, base[2] + 0.05, base[3] + 0.02, 0.80 };
        imgui.PushStyleColor(ImGuiCol_ChildBg, goldBg);
        imgui.BeginChild('##goldilox', { -1, 28 }, false);
        local gdl = imgui.GetWindowDrawList();
        local gwx, gwy = imgui.GetWindowPos();
        local gww = imgui.GetWindowWidth();
        gdl:AddRectFilled({ gwx, gwy }, { gwx + 3, gwy + 28 }, imgui.GetColorU32(goldColor));
        gdl:AddText({ gwx + 10, gwy + 7 }, imgui.GetColorU32(ui.color('yellow')), 'Goldilox Bonus');
        local glW = imgui.CalcTextSize(goldLabel);
        gdl:AddText({ gwx + gww - glW - 8, gwy + 7 }, imgui.GetColorU32(goldColor), goldLabel);
        imgui.EndChild();
        imgui.PopStyleColor(1);
    end

    imgui.Spacing();

    -- Storming Sea
    local seaComplete = 0;
    for _, quest in ipairs(SEA_ORDER) do
        if state.sea[quest] then seaComplete = seaComplete + 1; end
    end

    ui.sectionHeader(string.format('Storming Sea (%d/3)', seaComplete));
    imgui.Spacing();

    for idx, quest in ipairs(SEA_ORDER) do
        renderDailyRow(quest, SEA_ICONS[quest], state.sea[quest], 10 + idx);
    end

    imgui.EndChild();
end

------------------------------------------------------------
-- Plugin definition
------------------------------------------------------------
return {
    name        = 'Dailies',
    icon        = 511,    -- Goblin Mask
    version     = '1.0',
    author      = 'Loxley',
    description = 'Goblin Dailies and Storming Sea tracker',

    init = function(renderIcon, getItemRes, uiMod, renderTooltip)
        ui = uiMod;
        items = {
            renderIcon    = renderIcon,
            getName       = function(id)
                local res = getItemRes(id);
                return (res and res.Name and res.Name[1]) or tostring(id);
            end,
            renderTooltip = function(id, qty)
                if renderTooltip then
                    local res = getItemRes(id);
                    local name = (res and res.Name and res.Name[1]) or tostring(id);
                    renderTooltip({ id = id, name = name, qty = qty or 0 });
                end
            end,
        };
        ashita.events.register('text_in', 'lqs_dailies_text', onTextIn);

        -- Register as a sub-tab in the Quest window
        local ok, questPlugin = pcall(require, 'core/quest');
        if ok and questPlugin and questPlugin.registerSubTab then
            questPlugin.registerSubTab('Dailies', function()
                ensureState();
                render(state, ui, items);
            end, 5);
        end
    end,

    getState = function()
        ensureState();
        return state;
    end,

    onUnload = function()
        ashita.events.unregister('text_in', 'lqs_dailies_text');
    end,
};
