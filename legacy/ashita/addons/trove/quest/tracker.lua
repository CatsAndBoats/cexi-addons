--[[
* trove/quest/tracker.lua — Quest/Daily objective tracker
*
* Floating HUD showing active quest objectives and daily progress.
* Uses Ashita's fonts library for outlined text (same as toasts).
* Draggable — position persists via settings.
* Adapted from LQS panels/tracker.lua for trove plugin system.
]]--

local fonts    = require('fonts');
local imgui    = require('imgui');
local d3d8     = require('d3d8');

-- Injected by quest plugin via tracker.setConfig()
local config   = nil;

local tracker = {};
tracker.enabled = true;

tracker.setConfig = function(configAdapter)
    config = configAdapter;
end

-- Screen dimensions
local d3d8dev = d3d8.get_device();
local _, viewport = d3d8dev:GetViewport();
local screenW = viewport and viewport.Width or 1024;

-- Position (not using settings module to avoid conflicts with dailies)
local pos = {
    x = screenW - 600,
    y = 200,
};

-- Max tracked entries
local MAX_LINES = 12;

-- Font pool (pre-created, reused each frame)
local headerFont = nil;
local linePool = {};

local HEADER_COLOR   = 0xFFFFD700;  -- Gold
local ACTIVE_COLOR   = 0xFFFFD080;  -- Light gold
local COMPLETE_COLOR = 0xFF55E855;  -- Green
local DIMMED_COLOR   = 0xFFA0A0A8;  -- Grey
local DAILY_COLOR    = 0xFF88DDFF;  -- Cyan

local LINE_HEIGHT = 18;
local HEADER_HEIGHT = 22;
local INDENT = 12;

------------------------------------------------------------
-- Tracked entries
-- Each: { header, color, objectives = { { text, color, done } } }
------------------------------------------------------------
local tracked = {};

------------------------------------------------------------
-- Initialize fonts
------------------------------------------------------------
tracker.init = function()
    local baseFontSettings = {
        visible       = false,
        font_family   = 'Century Schoolbook',
        font_height   = 14,
        color         = HEADER_COLOR,
        color_outline = 0xFF000000,
        draw_flags    = 0x10,  -- FontDrawFlags.Outlined
        bold          = true,
        italic        = false,
        position_x    = 0,
        position_y    = 0,
        background    = { visible = false },
    };

    -- Header font (draggable anchor)
    headerFont = fonts.new({
        visible       = false,
        font_family   = 'Century Schoolbook',
        font_height   = 15,
        color         = HEADER_COLOR,
        color_outline = 0xFF000000,
        draw_flags    = 0x10,
        bold          = true,
        italic        = false,
        can_focus     = true,
        locked        = false,
        position_x    = pos.x,
        position_y    = pos.y,
        background    = { visible = false },
    });

    -- Line pool
    for i = 1, MAX_LINES do
        linePool[i] = {
            font = fonts.new(baseFontSettings),
            active = false,
        };
    end
end

------------------------------------------------------------
-- Compass state
------------------------------------------------------------
tracker.compassAngle = nil;  -- radians, nil = don't show
tracker.compassDist  = nil;

------------------------------------------------------------
-- Update tracked entries from external state
------------------------------------------------------------
tracker.update = function(questList, dailyState, trackedQuestName)
    tracked = {};
    tracker.compassAngle = nil;
    tracker.compassDist  = nil;

    -- Tracked quest (priority display)
    if trackedQuestName and questList then
        for _, q in ipairs(questList) do
            if q.name == trackedQuestName and q.steps then
                -- charvar 0 = steps[1], charvar 1 = steps[2], etc.
                local stepIdx = (q.step or 0) + 1;
                local step = q.steps[stepIdx] or q.steps[1];
                if step then
                    local entry = {
                        header = q.name,
                        color = HEADER_COLOR,
                        objectives = {},
                    };

                    -- Current step objective
                    local text = (step.action or 'Speak to') .. ' ' .. (step.entity or '?');
                    if step.zone and step.zone ~= '' then
                        text = text .. ' in ' .. step.zone;
                    end
                    table.insert(entry.objectives, {
                        text  = text,
                        color = ACTIVE_COLOR,
                        done  = false,
                    });

                    -- Compass: check if target is in current zone
                    if step.pos and step.zone then
                        local playerZoneId = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
                        local playerZoneName = AshitaCore:GetResourceManager():GetString('zones.names', playerZoneId) or '';
                        local stepZone = step.zone:lower():gsub("'", ""):gsub(" ", "");
                        local curZone = playerZoneName:lower():gsub("'", ""):gsub(" ", "");

                        if stepZone == curZone then
                            local entity = GetPlayerEntity();
                            if entity then
                                -- FFXI memory: X = east/west, Y = north/south (horizontal), Z = height
                                local px = entity.Movement.LocalPosition.X;
                                local py = entity.Movement.LocalPosition.Y;
                                -- Quest pos format: { x, height, z } where x=east/west, z=north/south
                                local tx = step.pos[1];
                                local tz = step.pos[3];
                                local dx = tx - px;
                                local dz = tz - py;
                                tracker.compassAngle = math.atan2(dx, dz);
                                tracker.compassDist = math.sqrt(dx * dx + dz * dz);

                                -- Add distance to objective text
                                entry.objectives[1].text = entry.objectives[1].text
                                    .. string.format(' (%.0fm)', tracker.compassDist);
                            end
                        end
                    end

                    table.insert(tracked, entry);
                end
                break;
            end
        end
    end


    -- Goblin Dailies (if enabled in settings)
    if config and config.get('showDailiesInTracker') and dailyState and dailyState.goblins then
        local hasAny = false;
        for _, _ in pairs(dailyState.goblins) do hasAny = true; break; end

        if hasAny then
            local entry = {
                header = 'Goblin Dailies',
                color = DAILY_COLOR,
                objectives = {},
            };
            local goblinOrder = { 'Fishstix', 'Murdox', 'Mistrix', 'Saltlix', 'Beetrix' };
            for _, name in ipairs(goblinOrder) do
                local g = dailyState.goblins[name];
                if g then
                    local isDone = (g.status == 'complete');
                    local isReturn = (g.status == 'return');
                    local color = isDone and COMPLETE_COLOR or (isReturn and DAILY_COLOR or ACTIVE_COLOR);
                    local text = name .. ': ' .. (g.objective or '?');
                    if isDone then text = name .. ': Complete'; end
                    if isReturn then text = name .. ': Return'; end
                    table.insert(entry.objectives, {
                        text  = text,
                        color = color,
                        done  = isDone,
                    });
                end
            end
            table.insert(tracked, entry);
        end
    end

    -- Storming Sea (if enabled in settings)
    if config and config.get('showDailiesInTracker') and dailyState and dailyState.sea then
        local hasAny = false;
        for _, _ in pairs(dailyState.sea) do hasAny = true; break; end

        if hasAny then
            local entry = {
                header = 'Storming Sea',
                color = DAILY_COLOR,
                objectives = {},
            };
            local seaOrder = { 'Item request', 'Find flux', 'Defeat mobs' };
            for _, quest in ipairs(seaOrder) do
                local s = dailyState.sea[quest];
                if s then
                    table.insert(entry.objectives, {
                        text  = s.objective or quest,
                        color = ACTIVE_COLOR,
                        done  = false,
                    });
                end
            end
            table.insert(tracked, entry);
        end
    end
end

------------------------------------------------------------
-- Render (call from d3d_present)
------------------------------------------------------------
tracker.render = function()
    if not tracker.enabled or headerFont == nil then return; end

    -- Read position from header font (draggable)
    local baseX = headerFont.position_x;
    local baseY = headerFont.position_y;

    -- Hide everything first
    headerFont.visible = false;
    for i = 1, MAX_LINES do
        linePool[i].font.visible = false;
        linePool[i].active = false;
    end

    if #tracked == 0 then return; end

    -- Show header anchor (invisible but draggable)
    headerFont.text = '';
    headerFont.visible = true;

    local lineIdx = 0;
    local yOffset = 0;

    for _, entry in ipairs(tracked) do
        -- Section header
        lineIdx = lineIdx + 1;
        if lineIdx > MAX_LINES then break; end

        local hf = linePool[lineIdx].font;
        hf.visible = true;
        hf.text = entry.header;
        hf.color = entry.color;
        hf.font_height = 14;
        hf.bold = true;
        hf.position_x = baseX;
        hf.position_y = baseY + yOffset;
        linePool[lineIdx].active = true;
        yOffset = yOffset + HEADER_HEIGHT;

        -- Objectives
        for _, obj in ipairs(entry.objectives) do
            lineIdx = lineIdx + 1;
            if lineIdx > MAX_LINES then break; end

            local text = obj.text;
            if #text > 50 then text = text:sub(1, 47) .. '...'; end
            if obj.done then text = '  ' .. text; end

            local lf = linePool[lineIdx].font;
            lf.visible = true;
            lf.text = text;
            lf.color = obj.color;
            lf.font_height = 12;
            lf.bold = false;
            lf.position_x = baseX + INDENT;
            lf.position_y = baseY + yOffset;
            linePool[lineIdx].active = true;
            yOffset = yOffset + LINE_HEIGHT;
        end

        yOffset = yOffset + 4; -- gap between sections
    end

    -- Compass arrow for tracked quest (rendered via imgui drawlist)
    if tracker.compassAngle ~= nil and config and config.get('showCompass') then
        yOffset = yOffset + 8;

        -- Get player facing direction (Yaw in radians)
        local entity = GetPlayerEntity();
        local playerFacing = 0;
        if entity then
            playerFacing = entity.Movement.LocalPosition.Yaw or 0;
        end

        -- Relative angle: target angle minus player facing
        local relAngle = tracker.compassAngle - playerFacing - math.pi / 2;

        -- Arrow center position
        local cx = baseX + INDENT + 20;
        local cy = baseY + yOffset + 20;
        local radius = 16;

        -- Triangle points rotated by relAngle
        local function rotPoint(ox, oy, angle)
            local c = math.cos(angle);
            local s = math.sin(angle);
            return cx + ox * c - oy * s, cy + ox * s + oy * c;
        end

        -- Arrow triangle (pointing up = forward, rotated by relAngle)
        local tipX, tipY = rotPoint(0, -radius, relAngle);
        local leftX, leftY = rotPoint(-8, radius * 0.6, relAngle);
        local rightX, rightY = rotPoint(8, radius * 0.6, relAngle);

        -- Draw arrow using the LQS panel's drawlist (rendered on top of everything)
        -- We need a drawlist that renders over the game. Use a minimal imgui window.
        imgui.SetNextWindowPos({ cx - 40, cy - 40 }, ImGuiCond_Always);
        imgui.SetNextWindowSize({ 80, 80 }, ImGuiCond_Always);

        -- Fully invisible window just for the drawlist
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 });
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowMinSize, { 1, 1 });
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_Border, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_TitleBg, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_TitleBgActive, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_Button, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_Text, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_ResizeGrip, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_ResizeGripHovered, { 0, 0, 0, 0 });
        imgui.PushStyleColor(ImGuiCol_ResizeGripActive, { 0, 0, 0, 0 });

        imgui.Begin('##lqs_compass', nil,
            ImGuiWindowFlags_NoTitleBar
            + ImGuiWindowFlags_NoResize
            + ImGuiWindowFlags_NoMove
            + ImGuiWindowFlags_NoScrollbar
            + ImGuiWindowFlags_NoCollapse
            + ImGuiWindowFlags_NoSavedSettings
            + ImGuiWindowFlags_NoInputs
            + ImGuiWindowFlags_NoFocusOnAppearing
            + ImGuiWindowFlags_NoBringToFrontOnFocus
            + ImGuiWindowFlags_NoNav
        );

        local dl = imgui.GetWindowDrawList();
        if dl then
            local arrowColor = imgui.ColorConvertFloat4ToU32({ 1.0, 0.85, 0.20, 1.0 });
            local outlineColor = imgui.ColorConvertFloat4ToU32({ 0.0, 0.0, 0.0, 0.9 });

            -- Black outline
            dl:AddTriangleFilled(
                { tipX, tipY },
                { leftX, leftY },
                { rightX, rightY },
                outlineColor
            );

            -- Slightly smaller gold fill
            local tipX2, tipY2 = rotPoint(0, -radius + 2, relAngle);
            local leftX2, leftY2 = rotPoint(-6, radius * 0.5, relAngle);
            local rightX2, rightY2 = rotPoint(6, radius * 0.5, relAngle);

            dl:AddTriangleFilled(
                { tipX2, tipY2 },
                { leftX2, leftY2 },
                { rightX2, rightY2 },
                arrowColor
            );
        end

        imgui.End();
        imgui.PopStyleColor(12);
        imgui.PopStyleVar(4);

        -- Distance text next to arrow
        lineIdx = lineIdx + 1;
        if lineIdx <= MAX_LINES then
            local distText = '';
            if tracker.compassDist then
                distText = string.format('%.0fm', tracker.compassDist);
            end
            local df = linePool[lineIdx].font;
            df.visible = true;
            df.text = distText;
            df.color = 0xFFFFD700;
            df.font_height = 12;
            df.bold = true;
            df.position_x = cx + 28;
            df.position_y = cy - 6;
            linePool[lineIdx].active = true;
        end
    end
end

------------------------------------------------------------
-- Cleanup
------------------------------------------------------------
tracker.cleanup = function()
    if headerFont then
        headerFont.visible = false;
    end
    for i = 1, MAX_LINES do
        if linePool[i] and linePool[i].font then
            linePool[i].font.visible = false;
        end
    end
end

return tracker;
