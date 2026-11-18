--[[
* trove/plugins/profile.lua — Job levels, prestige, and crafting skills
*
* Shows all 22 jobs with levels, EXP bar for current job, prestige stars,
* and a separate Crafts tab with all 9 crafting skills.
*
* Uses the generic plugin data protocol (pluginId 1).
*
* Command: /trove profile
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon     = nil;
local getItemRes     = nil;
local ui             = nil;
local renderTooltip  = nil;
local renderFileIcon = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen  = { false };
local wasOpen = false;
local loaded  = false;
local loading = false;

-- Parsed data from server
local data = {
    prestige = {},    -- [1..22] = tier (0-5)
    crafts   = {},    -- [1..9] = skill level (0-110 with decimal)
    isCW     = false,
    exp      = {},    -- [1..22] = current EXP per job
};

-- EXP to next level (static, from exp_base table, levels 1-75)
-- Index = current level, value = EXP needed to reach next level
local TNL = {
    [1]  =   500, [2]  =   750, [3]  =  1000, [4]  =  1250, [5]  =  1500,
    [6]  =  1750, [7]  =  2000, [8]  =  2200, [9]  =  2400, [10] =  2600,
    [11] =  2800, [12] =  3000, [13] =  3200, [14] =  3400, [15] =  3600,
    [16] =  3800, [17] =  4000, [18] =  4200, [19] =  4400, [20] =  4600,
    [21] =  4800, [22] =  5000, [23] =  5100, [24] =  5200, [25] =  5300,
    [26] =  5400, [27] =  5500, [28] =  5600, [29] =  5700, [30] =  5800,
    [31] =  5900, [32] =  6000, [33] =  6100, [34] =  6200, [35] =  6300,
    [36] =  6400, [37] =  6500, [38] =  6600, [39] =  6700, [40] =  6800,
    [41] =  6900, [42] =  7000, [43] =  7100, [44] =  7200, [45] =  7300,
    [46] =  7400, [47] =  7500, [48] =  7600, [49] =  7700, [50] =  7800,
    [51] =  8000, [52] =  9200, [53] = 10400, [54] = 11600, [55] = 12800,
    [56] = 14000, [57] = 15200, [58] = 16400, [59] = 17600, [60] = 18800,
    [61] = 20000, [62] = 21500, [63] = 23000, [64] = 24500, [65] = 26000,
    [66] = 27500, [67] = 29000, [68] = 30500, [69] = 32000, [70] = 34000,
    [71] = 36000, [72] = 38000, [73] = 40000, [74] = 42000,
};

------------------------------------------------------------
-- Protocol
------------------------------------------------------------
local PACKET_ID       = 0x1A4;
local C2S_PLUGIN_DATA = 17;
local PLUGIN_ID       = 1;

local requestTime = 0;

local function requestData()
    if loading then return; end
    loading = true;
    requestTime = os.clock();
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    p[5] = C2S_PLUGIN_DATA;
    p[7] = PLUGIN_ID;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local JOB_ABBR = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM', [5]  = 'RDM',
    [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK', [9]  = 'BST', [10] = 'BRD',
    [11] = 'RNG', [12] = 'SAM', [13] = 'NIN', [14] = 'DRG', [15] = 'SMN',
    [16] = 'BLU', [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

local JOB_ICON_ITEMS = {
    [1]  = 12511, [2]  = 12512, [3]  = 13855, [4]  = 13856,
    [5]  = 12513, [6]  = 12514, [7]  = 12515, [8]  = 12516,
    [9]  = 12517, [10] = 13857, [11] = 12518, [12] = 13868,
    [13] = 13869, [14] = 12519, [15] = 12520, [16] = 11465,
    [17] = 15266, [18] = 11471, [19] = 11478, [20] = 16140,
    [21] = 27786, [22] = 27787,
};

-- Prestige bonus descriptions per job (matches server enum)
-- Format string: {} is replaced by the tier value
local PRESTIGE_DESC = {
    [1]  = { 'STR+{}',                    { 1, 2, 4, 6, 8 } },
    [2]  = { 'HP +{}%',                   { 3, 5, 8, 10, 12 } },
    [3]  = { 'Waltz / Cure Pot. II +{}%', { 1, 2, 4, 6, 8 } },
    [4]  = { 'Magic Atk. Bonus +{}',      { 1, 2, 4, 6, 8 } },
    [5]  = { 'Fast Cast +{}%',            { 1, 2, 3, 4, 5 } },
    [6]  = { 'TH+{} / Evasion+{}',        { {0,0}, {1,5}, {2,8}, {1,10}, {2,12} } },
    [7]  = { 'Phys. dmg. taken II -{}%',  { 1, 2, 3, 4, 5 } },
    [8]  = { 'Attack+{}',                 { 5, 10, 15, 20, 25 } },
    [9]  = { 'Killer Effects +{}',        { 3, 5, 8, 10, 12 } },
    [10] = { 'Enh/Song Duration +{}%',    { 3, 5, 8, 10, 12 } },
    [11] = { 'Ranged Attack+{}',          { 5, 10, 15, 20, 25 } },
    [12] = { 'Store TP +{}',              { 1, 2, 3, 4, 5 } },
    [13] = { 'Ranged Accuracy+{}',        { 5, 8, 10, 12, 15 } },
    [14] = { 'Accuracy+{}',              { 5, 8, 10, 12, 15 } },
    [15] = { 'MP +{}%',                   { 3, 5, 8, 10, 12 } },
    [16] = { 'Magic Accuracy +{}',        { 5, 8, 10, 12, 15 } },
    [17] = { 'EXP to Gil +{}%',           { 10, 20, 30, 40, 50 } },
    [18] = { 'DEX+{}',                    { 1, 2, 4, 6, 8 } },
    [19] = { 'AGI+{}',                    { 1, 2, 4, 6, 8 } },
    [20] = { 'INT+{}',                    { 1, 2, 4, 6, 8 } },
    [21] = { 'Conserve MP +{}',           { 1, 2, 3, 4, 5 } },
    [22] = { 'Magic dmg. taken II -{}%',  { 1, 2, 3, 4, 5 } },
};

-- Jobs required per prestige tier
local TIER_REQS = { 3, 5, 10, 15, 22 };

local CRAFT_NAMES = {
    'Fishing', 'Woodworking', 'Smithing', 'Goldsmithing',
    'Clothcraft', 'Leathercraft', 'Bonecraft', 'Alchemy', 'Cooking',
};

-- Craft rank thresholds
local CRAFT_RANKS = {
    { 0,   'Amateur' },
    { 10,  'Recruit' },
    { 20,  'Initiate' },
    { 30,  'Novice' },
    { 40,  'Apprentice' },
    { 50,  'Journeyman' },
    { 60,  'Craftsman' },
    { 70,  'Artisan' },
    { 80,  'Adept' },
    { 90,  'Veteran' },
    { 100, 'Expert' },
    { 110, 'Master' },
};

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function getPrestigeDesc(jobId, tier)
    local desc = PRESTIGE_DESC[jobId];
    if not desc or tier <= 0 then return nil; end
    local fmt = desc[1];
    local vals = desc[2];
    local v = vals[tier];
    if type(v) == 'table' then
        local idx = 0;
        return (string.gsub(fmt, '{}', function()
            idx = idx + 1;
            return tostring(v[idx] or 0);
        end));
    end
    return (string.gsub(fmt, '{}', tostring(v)));
end

local function getCraftRank(level)
    local rank = 'Amateur';
    for _, entry in ipairs(CRAFT_RANKS) do
        if level >= entry[1] then rank = entry[2]; end
    end
    return rank;
end

local function getPlayerData()
    local ok, result = pcall(function()
        local p = AshitaCore:GetMemoryManager():GetPlayer();
        local d = {
            mainJob     = p:GetMainJob(),
            mainLvl     = p:GetMainJobLevel(),
            subJob      = p:GetSubJob(),
            subLvl      = p:GetSubJobLevel(),
            currentExp  = 0,
            expNeeded   = 0,
            limitPoints = 0,
            meritPoints = 0,
            meritMax    = 0,
            isLimitMode = false,
            jobs        = {},
        };
        -- These may not exist in all Ashita builds
        pcall(function()
            d.currentExp  = p:GetExpCurrent();
            d.expNeeded   = p:GetExpNeeded();
            d.limitPoints = p:GetLimitPoints();
            d.meritPoints = p:GetMeritPoints();
            d.meritMax    = p:GetMeritPointsMax();
            d.isLimitMode = p:GetIsLimitModeEnabled() ~= 0;
        end);
        for id = 1, 22 do d.jobs[id] = p:GetJobLevel(id); end
        return d;
    end);
    return ok and result or nil;
end

------------------------------------------------------------
-- Render helpers
------------------------------------------------------------
local STAR_SIZE  = 12;
local ICON_SIZE  = 24;
local ROW_HEIGHT = 44;
local BAR_HEIGHT = 14;

local function renderExpBar(current, needed, width, barY, barColor, label)
    local pct = needed > 0 and math.min(current / needed, 1.0) or 1.0;
    local dl = imgui.GetWindowDrawList();
    local bx, by = imgui.GetCursorScreenPos();
    by = barY;

    -- Background
    dl:AddRectFilled({ bx, by }, { bx + width, by + BAR_HEIGHT },
        imgui.GetColorU32({ 0.06, 0.06, 0.09, 0.90 }), 3);

    -- Fill
    if pct > 0 then
        dl:AddRectFilled({ bx, by }, { bx + width * pct, by + BAR_HEIGHT },
            imgui.GetColorU32(barColor), 3);
    end

    -- Border
    dl:AddRect({ bx, by }, { bx + width, by + BAR_HEIGHT },
        imgui.GetColorU32({ 1, 1, 1, 0.06 }), 3);

    -- Text
    local fracStr = label or string.format('%d / %d', current, needed);
    local fracW = imgui.CalcTextSize(fracStr);
    local tx = bx + (width - fracW) / 2;
    dl:AddText({ tx + 1, by + 1 }, imgui.GetColorU32({ 0, 0, 0, 0.80 }), fracStr);
    dl:AddText({ tx, by },         imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.90 }), fracStr);
end

local function renderCraftBar(level, maxLevel, width)
    local pct = maxLevel > 0 and math.min(level / maxLevel, 1.0) or 0;
    local dl = imgui.GetWindowDrawList();
    local bx, by = imgui.GetCursorScreenPos();

    -- Background
    dl:AddRectFilled({ bx, by }, { bx + width, by + BAR_HEIGHT },
        imgui.GetColorU32({ 0.06, 0.06, 0.09, 0.90 }), 3);

    -- Fill (amber/gold for crafts)
    if pct > 0 then
        dl:AddRectFilled({ bx, by }, { bx + width * pct, by + BAR_HEIGHT },
            imgui.GetColorU32({ 0.65, 0.50, 0.15, 0.70 }), 3);
    end

    -- Border
    dl:AddRect({ bx, by }, { bx + width, by + BAR_HEIGHT },
        imgui.GetColorU32({ 1, 1, 1, 0.06 }), 3);

    -- Show decimal if fractional, integer if whole
    local fracStr;
    if level == math.floor(level) then
        fracStr = tostring(math.floor(level));
    else
        fracStr = string.format('%.1f', level);
    end
    local fracW = imgui.CalcTextSize(fracStr);
    local tx = bx + (width - fracW) / 2;
    dl:AddText({ tx + 1, by + 1 }, imgui.GetColorU32({ 0, 0, 0, 0.80 }), fracStr);
    dl:AddText({ tx, by },         imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.90 }), fracStr);

    imgui.Dummy({ width, BAR_HEIGHT + 2 });
end

------------------------------------------------------------
-- Render: Jobs tab
------------------------------------------------------------
local function renderJobsTab(player)
    local mainJob = player.mainJob;
    local mainLvl = player.mainLvl;
    local avail = imgui.GetContentRegionAvail();
    local colW = math.floor((avail - 12) / 2);

    -- Count 75s for tier requirements display
    local count75 = 0;
    for id = 1, 22 do
        if player.jobs[id] >= 75 then count75 = count75 + 1; end
    end

    -- Merit/Limit row (from Ashita memory, always available)
    imgui.Spacing();
    local meritStr = string.format('Merits: %d / %d', player.meritPoints, player.meritMax);
    local limitStr = string.format('Limit Points: %d / 10000', player.limitPoints);
    imgui.TextColored(ui.color('dimmed'), meritStr);
    imgui.SameLine(0, 20);
    imgui.TextColored(ui.color('dimmed'), limitStr);
    imgui.SameLine(0, 20);
    imgui.TextColored(ui.color('dimmed'), string.format('Jobs at 75: %d/22', count75));
    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();

    -- 2-column job grid
    for id = 1, 22 do
        local level = player.jobs[id];
        local abbr = JOB_ABBR[id];
        local tier = (loaded and data.prestige[id]) or 0;
        local isMain = (id == mainJob);
        local isMax = (level >= 75);

        -- Column layout
        if (id - 1) % 2 == 1 then
            imgui.SameLine(colW + 16);
        end

        -- Job row child
        local childId = string.format('##job_%d', id);
        imgui.BeginChild(childId, { colW, ROW_HEIGHT + 4 }, false);

        -- Job icon
        local iconId = JOB_ICON_ITEMS[id];
        if iconId then renderIcon(iconId, ICON_SIZE); end
        imgui.SameLine(0, 6);

        -- Job name + level
        local levelStr = string.format('%s %d', abbr, level);
        local nameColor;
        if isMain then
            nameColor = { 0.90, 0.90, 0.95, 1.0 };
        elseif isMax or tier > 0 then
            nameColor = { 0.90, 0.80, 0.30, 1.0 }; -- gold
        elseif level >= 37 then
            nameColor = { 0.40, 0.60, 0.90, 1.0 }; -- blue
        elseif level > 0 then
            nameColor = { 0.40, 0.80, 0.40, 1.0 }; -- green
        else
            nameColor = { 0.40, 0.40, 0.45, 0.60 }; -- gray
        end

        imgui.SetCursorPosY(imgui.GetCursorPosY() + 2);
        imgui.TextColored(nameColor, levelStr);

        -- Prestige stars
        if tier > 0 then
            imgui.SameLine(0, 4);
            for s = 1, tier do
                renderFileIcon('star.png', STAR_SIZE);
                if s < tier then imgui.SameLine(0, 1); end
            end
        end

        -- EXP bar (all leveled jobs, full gold bar at 75)
        if loaded and level > 0 then
            local barX = ICON_SIZE + 6;
            imgui.SetCursorPosX(barX);
            local barW = colW - barX - 4;
            if barW > 40 then
                local sx, sy = imgui.GetCursorScreenPos();
                -- Color matches the job name color scheme
                local barFill;
                if isMax or tier > 0 then
                    barFill = { 0.65, 0.55, 0.15, 0.70 }; -- gold
                elseif level >= 37 then
                    barFill = { 0.20, 0.40, 0.70, 0.70 }; -- blue
                else
                    barFill = { 0.20, 0.55, 0.25, 0.70 }; -- green
                end

                if level >= 75 then
                    local jobExp = data.exp[id] or 0;
                    renderExpBar(jobExp, jobExp, barW, sy, barFill,
                        string.format('%d / %d', jobExp, jobExp));
                else
                    local jobExp = data.exp[id] or 0;
                    local tnl = TNL[level] or 0;
                    if tnl > 0 then
                        renderExpBar(jobExp, tnl, barW, sy, barFill);
                    end
                end
                imgui.Dummy({ barW, BAR_HEIGHT });
            end
        end

        imgui.EndChild();

        -- Tooltip for the job row
        if imgui.IsItemHovered() then
            imgui.BeginTooltip();
            imgui.TextColored(ui.color('header'), string.format('%s  Lv%d', abbr, level));
            if isMain then
                local subAbbr = JOB_ABBR[player.subJob] or '---';
                imgui.TextColored(ui.color('dimmed'),
                    string.format('Sub: %s Lv%d', subAbbr, player.subLvl));
            end
            if loaded and level > 0 then
                if level < 75 then
                    local jobExp = data.exp[id] or 0;
                    local tnl = TNL[level] or 0;
                    imgui.TextColored(ui.color('dimmed'),
                        string.format('EXP: %d / %d', jobExp, tnl));
                else
                    imgui.TextColored({ 0.90, 0.80, 0.30, 1.0 }, 'Max Level');
                end
            end
            if tier > 0 then
                imgui.Separator();
                imgui.TextColored({ 0.90, 0.80, 0.30, 1.0 },
                    string.format('Prestige %d', tier));
                local desc = getPrestigeDesc(id, tier);
                if desc then
                    imgui.TextColored({ 0.70, 0.85, 0.70, 1.0 }, desc);
                end
                -- Show next tier requirement
                if tier < 5 then
                    local nextReq = TIER_REQS[tier + 1];
                    local canAdvance = count75 >= nextReq;
                    local reqColor = canAdvance
                        and { 0.40, 0.80, 0.40, 0.80 }
                        or  { 0.80, 0.40, 0.40, 0.80 };
                    imgui.TextColored(reqColor,
                        string.format('Next tier: %d/22 jobs at 75', nextReq));
                end
            elseif level >= 75 then
                imgui.Separator();
                local nextReq = TIER_REQS[1];
                local canAdvance = count75 >= nextReq;
                local reqColor = canAdvance
                    and { 0.40, 0.80, 0.40, 0.80 }
                    or  { 0.80, 0.40, 0.40, 0.80 };
                imgui.TextColored(ui.color('dimmed'), 'No prestige yet');
                imgui.TextColored(reqColor,
                    string.format('Requires: %d/22 jobs at 75', nextReq));
            end
            imgui.EndTooltip();
        end
    end
end

------------------------------------------------------------
-- Render: Crafts tab
------------------------------------------------------------
local function renderCraftsTab()
    local avail = imgui.GetContentRegionAvail();

    if not loaded then
        imgui.TextColored(ui.color('dimmed'), 'Loading...');
        return;
    end

    imgui.Spacing();

    for i, name in ipairs(CRAFT_NAMES) do
        local level = data.crafts[i] or 0;
        local rank = getCraftRank(level);

        -- Craft row
        local childId = string.format('##craft_%d', i);
        imgui.BeginChild(childId, { avail, 36 }, false);

        -- Name + rank
        local nameColor = level > 0
            and { 0.85, 0.75, 0.55, 1.0 }
            or  { 0.40, 0.40, 0.45, 0.60 };
        imgui.TextColored(nameColor, string.format('%-14s', name));
        imgui.SameLine(0, 8);

        -- Rank label
        imgui.TextColored(ui.color('dimmed'), string.format('%-12s', rank));
        imgui.SameLine(0, 8);

        -- Progress bar
        local barW = avail - imgui.GetCursorPosX() - 8;
        if barW > 40 then
            renderCraftBar(level, 110, barW);
        end

        imgui.EndChild();
    end
end

------------------------------------------------------------
-- Render: main window
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then
        wasOpen = false;
        return;
    end

    -- Request data on first open
    if not wasOpen then
        wasOpen = true;
        requestData();
    end

    -- Loading timeout
    if loading and os.clock() - requestTime > 5 then
        loading = false;
    end

    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 540, 580 }, ImGuiCond_FirstUseEver);

    if imgui.Begin('Profile##trove_profile', isOpen, ImGuiWindowFlags_NoCollapse) then
        local _bgPop = ui.renderBackground();
        local player = getPlayerData();
        if not player then
            imgui.TextColored(ui.color('dimmed'), 'Character data unavailable');
            imgui.End();
            ui.popWindowStyle(pushed);
            return;
        end

        if loading then
            imgui.TextColored(ui.color('dimmed'), 'Loading prestige data...');
        end

        if imgui.BeginTabBar('##profile_tabs') then
            if imgui.BeginTabItem('Jobs') then
                renderJobsTab(player);
                imgui.EndTabItem();
            end
            if imgui.BeginTabItem('Crafts') then
                renderCraftsTab();
                imgui.EndTabItem();
            end
            imgui.EndTabBar();
        end
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Profile',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Job levels, prestige stars, and crafting skills',
    pluginId    = PLUGIN_ID,

    init = function(iconFn, itemResFn, uiModule, tooltipFn, fileIconFn)
        renderIcon     = iconFn;
        getItemRes     = itemResFn;
        ui             = uiModule;
        renderTooltip  = tooltipFn;
        renderFileIcon = fileIconFn;
    end,

    commands = {
        profile = function(state) isOpen[1] = not isOpen[1]; end,
    },

    window = {
        category = 'Account',
        isOpen = isOpen,
        render = renderWindow,
        label  = 'Profile',
        icon   = 1601,
    },

    onRender = function(state)
        if not isOpen[1] then
            wasOpen = false;
        end
    end,

    onPluginData = function(rawData, state)
        local function u8(off)
            return struct.unpack('B', rawData, off + 1);
        end

        -- Prestige tiers (jobs 1-22) at offset 0x06..0x1B
        data.prestige = {};
        for i = 1, 22 do
            data.prestige[i] = u8(0x05 + i);
        end

        -- Craft skills as uint16 LE (9 crafts) at offset 0x1C..0x2D
        -- RealSkills value: 1000 = 100.0, 15 = 1.5
        data.crafts = {};
        for i = 0, 8 do
            local off = 0x1C + i * 2;
            local raw = u8(off) + u8(off + 1) * 256;
            data.crafts[i + 1] = raw / 10;
        end

        -- Is CW at offset 0x2E
        data.isCW = u8(0x2E) == 1;

        -- Per-job EXP (22 x uint16 LE) appended by C++ at offset 0x2F
        data.exp = {};
        for i = 0, 21 do
            local off = 0x2F + i * 2;
            data.exp[i + 1] = u8(off) + u8(off + 1) * 256;
        end

        loaded  = true;
        loading = false;
    end,
};
