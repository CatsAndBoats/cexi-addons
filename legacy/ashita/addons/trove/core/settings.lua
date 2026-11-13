--[[
* trove/plugins/settings.lua — Settings panel
*
* Floating window for configuring Trove preferences.
* Currently supports theme selection with persistence.
*
* Settings are saved to config/addons/trove/settings.lua
]]--

local imgui    = require('imgui');
local textures = require('utils/textures');

------------------------------------------------------------
-- Shared functions (injected via init)
------------------------------------------------------------
local renderIcon     = nil;
local renderFileIcon = nil;
local getItemRes     = nil;
local ui = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen = { false };
local themes = {};          -- array of { name = 'default', label = 'Default' }
local currentTheme = 'default';
local backgroundStyle = 0;  -- 0 = off, 1-6 = game menu style
local troveState = nil;     -- reference to trove's state table (set during init)

------------------------------------------------------------
-- Config path
------------------------------------------------------------
local function getConfigDir()
    return string.format('%sconfig\\addons\\trove\\', AshitaCore:GetInstallPath());
end

local function getConfigPath()
    return getConfigDir() .. 'settings.lua';
end

------------------------------------------------------------
-- Save / Load settings
------------------------------------------------------------
local function saveSettings()
    local dir = getConfigDir();
    os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"');
    local f = io.open(getConfigPath(), 'w');
    if f then
        f:write('return {\n');
        f:write(string.format("    theme = '%s',\n", currentTheme));
        f:write(string.format("    backgroundStyle = %d,\n", backgroundStyle));
        f:write('};\n');
        f:close();
    end
end

local function loadSettings()
    local fn = loadfile(getConfigPath());
    if fn then
        local ok, result = pcall(fn);
        if ok and type(result) == 'table' then
            return result;
        end
    end
    return {};
end

------------------------------------------------------------
-- Theme discovery
------------------------------------------------------------
local function discoverThemes()
    local dir = string.format('%saddons\\trove\\themes\\', AshitaCore:GetInstallPath());
    local handle = io.popen('dir /b "' .. dir .. '*.lua" 2>nul');
    if handle == nil then return; end

    themes = {};
    for line in handle:lines() do
        if line:match('%.lua$') then
            local name = line:gsub('%.lua$', '');
            -- Capitalize first letter for display label
            local label = name:sub(1, 1):upper() .. name:sub(2);
            themes[#themes + 1] = { name = name, label = label };
        end
    end
    handle:close();

    -- Sort alphabetically but keep 'default' first
    table.sort(themes, function(a, b)
        if a.name == 'default' then return true; end
        if b.name == 'default' then return false; end
        return a.name < b.name;
    end);
end

------------------------------------------------------------
-- Apply theme
------------------------------------------------------------
local function applyTheme(name)
    if ui and ui.applyTheme then
        if ui.applyTheme(name) then
            currentTheme = name;
            saveSettings();
            return true;
        end
    end
    return false;
end

------------------------------------------------------------
-- Window rendering
------------------------------------------------------------
local function renderWindow()
    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 520, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('Trove Settings##trove_settings', isOpen, ImGuiWindowFlags_AlwaysAutoResize) then
        local _bgPop = ui.renderBackground();

        -- Theme section
        ui.header('Theme');
        imgui.Spacing();

        for _, t in ipairs(themes) do
            local selected = (t.name == currentTheme);
            if imgui.RadioButton(t.label, selected) then
                if not selected then
                    applyTheme(t.name);
                end
            end
        end

        imgui.Spacing();
        ui.dim('Themes are loaded from addons/trove/themes/');
        ui.dim('Copy default.lua and modify to create your own.');

        -- Background style section
        imgui.Spacing();
        imgui.Spacing();
        ui.header('Window Background');
        imgui.Spacing();

        local bgLabels = { [0] = 'Off', 'Style 1', 'Style 2', 'Style 3', 'Style 4', 'Style 5', 'Style 6' };
        for i = 0, 6 do
            local selected = (backgroundStyle == i);
            if imgui.RadioButton(bgLabels[i] .. '##bg', selected) then
                if not selected then
                    backgroundStyle = i;
                    saveSettings();
                end
            end
            if i < 6 then imgui.SameLine(0, 8); end
        end

        imgui.Spacing();
        ui.dim('Extracts menu textures from your game files.');

        -- Plugins section
        imgui.Spacing();
        imgui.Spacing();
        local trove_plugins = require('utils/plugins');
        local pluginList = trove_plugins.list();
        if #pluginList > 0 then
            ui.header('Plugins');
            imgui.Spacing();

            -- Column positions
            local COL_ICON    = 8;
            local COL_NAME    = 30;
            local COL_VER     = 150;
            local COL_AUTHOR  = 200;
            local COL_DESC    = 275;

            -- Header row
            imgui.SetCursorPosX(COL_NAME);
            imgui.TextColored(ui.color('dimmed'), 'Name');
            imgui.SameLine(COL_VER);
            imgui.TextColored(ui.color('dimmed'), 'Ver.');
            imgui.SameLine(COL_AUTHOR);
            imgui.TextColored(ui.color('dimmed'), 'Author');
            imgui.SameLine(COL_DESC);
            imgui.TextColored(ui.color('dimmed'), 'Description');
            imgui.Separator();

            -- Scrollable list
            imgui.BeginChild('##plugin_list', { -1, 160 }, false);
            for i, p in ipairs(pluginList) do
                -- Use a child window per row for full-row hover detection
                local rowId = string.format('##plugrow_%d', i);
                imgui.BeginChild(rowId, { -1, 20 }, false);

                -- Icon
                imgui.SetCursorPos({ COL_ICON, 2 });
                if p.icon and type(p.icon) == 'number' and renderIcon then
                    if not renderIcon(p.icon, 16) then imgui.Dummy({ 16, 16 }); end
                elseif p.icon and type(p.icon) == 'string' and renderFileIcon then
                    if not renderFileIcon(p.icon, 16) then imgui.Dummy({ 16, 16 }); end
                else
                    imgui.Dummy({ 16, 16 });
                end
                imgui.SameLine(COL_NAME);
                imgui.TextColored(ui.color('accent'), p.name);
                imgui.SameLine(COL_VER);
                imgui.TextColored(ui.color('dimmed'), p.version ~= '' and p.version or '-');
                imgui.SameLine(COL_AUTHOR);
                imgui.TextColored(ui.color('white'), p.author ~= '' and p.author or '-');
                imgui.SameLine(COL_DESC);
                imgui.TextColored(ui.color('dimmed'), p.description);

                imgui.EndChild();
                if imgui.IsItemHovered() then
                    imgui.BeginTooltip();
                    imgui.PushTextWrapPos(300);
                    -- Name + version header
                    imgui.TextColored(ui.color('header'), p.name);
                    if p.version ~= '' then
                        imgui.SameLine(0, 6);
                        imgui.TextColored(ui.color('dimmed'), 'v' .. p.version);
                    end
                    -- Author
                    if p.author ~= '' then
                        imgui.TextColored(ui.color('dimmed'), 'Author:');
                        imgui.SameLine(0, 4);
                        imgui.TextColored(ui.color('white'), p.author);
                    end
                    -- Description
                    if p.description ~= '' then
                        imgui.Spacing();
                        imgui.TextColored(ui.color('white'), p.description);
                    end
                    -- Type
                    local types = {};
                    if p.hasTab then types[#types + 1] = 'Tab'; end
                    if p.hasWindow then types[#types + 1] = 'Window'; end
                    if p.hasMenu then types[#types + 1] = 'Menu'; end
                    if #types > 0 then
                        imgui.Spacing();
                        imgui.TextColored(ui.color('dimmed'), 'Type:');
                        imgui.SameLine(0, 4);
                        imgui.TextColored(ui.color('accent'), table.concat(types, ', '));
                    end
                    -- Commands
                    if #p.commands > 0 then
                        imgui.TextColored(ui.color('dimmed'), 'Commands:');
                        imgui.SameLine(0, 4);
                        local cmds = {};
                        for _, c in ipairs(p.commands) do cmds[#cmds + 1] = '/trove ' .. c; end
                        imgui.TextColored(ui.color('accent'), table.concat(cmds, ', '));
                    end
                    -- File
                    imgui.TextColored(ui.color('dimmed'), 'File:');
                    imgui.SameLine(0, 4);
                    imgui.TextColored(ui.color('dimmed'), p.file);
                    imgui.PopTextWrapPos();
                    imgui.EndTooltip();
                end
            end
            imgui.EndChild();
            imgui.Spacing();
        end
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Plugin definition
------------------------------------------------------------
local plugin = {
    name        = 'Settings',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Theme selection and preferences',

    -- Public: other modules can read the current background texture
    getBackgroundTexture = function()
        if backgroundStyle > 0 then
            return textures.getMenuBackground(backgroundStyle);
        end
        return nil;
    end,

    init = function(iconFn, itemResFn, uiModule, tooltipFn, fileIconFn)
        renderIcon     = iconFn;
        renderFileIcon = fileIconFn;
        getItemRes     = itemResFn;
        ui = uiModule;

        -- Discover available themes
        discoverThemes();

        -- Load saved settings and apply
        local saved = loadSettings();
        if saved.backgroundStyle then
            backgroundStyle = saved.backgroundStyle;
        end
        if saved.theme then
            applyTheme(saved.theme);
        end
    end,

    onRender = function(state)
        if troveState == nil and state then
            troveState = state;
        end
    end,

    -- Floating window (shown via burger menu toggle)
    window = {
        category = 'Account',
        isOpen = isOpen,
        label  = 'Settings',
        icon   = 46,       -- Armor Box icon
        render = renderWindow,
    },
};

return plugin;
