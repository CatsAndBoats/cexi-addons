--[[
* trove/plugins/settings.lua — Settings panel
*
* Floating window for configuring Trove preferences.
* Currently supports theme selection with persistence.
*
* Settings are saved to config/addons/trove/settings.lua
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared functions (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen = { false };
local themes = {};          -- array of { name = 'default', label = 'Default' }
local currentTheme = 'default';
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
        -- Tab visibility
        if troveState and troveState.tabVisibility then
            f:write('    tabs = {\n');
            for k, v in pairs(troveState.tabVisibility) do
                f:write(string.format("        %s = %s,\n", k, tostring(v)));
            end
            f:write('    },\n');
        end
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
    imgui.SetNextWindowSize({ 320, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('Trove Settings##trove_settings', isOpen, ImGuiWindowFlags_AlwaysAutoResize) then
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

        -- Tab visibility section
        if troveState and troveState.tabVisibility then
            imgui.Spacing();
            imgui.Spacing();
            ui.header('Visible Tabs');
            imgui.Spacing();

            local tabs = {
                { key = 'ebox',     label = 'E.Box' },
                { key = 'currency', label = 'Currency' },
                { key = 'points',   label = 'Points' },
                { key = 'squire',   label = 'Squire' },
                { key = 'crafting', label = 'Crafting' },
            };

            local changed = false;
            for _, t in ipairs(tabs) do
                local val = { troveState.tabVisibility[t.key] };
                if imgui.Checkbox(t.label, val) then
                    troveState.tabVisibility[t.key] = val[1];
                    changed = true;
                end
            end

            if changed then saveSettings(); end
        end

        -- Plugins section
        imgui.Spacing();
        imgui.Spacing();
        local trove_plugins = require('utils/plugins');
        local pluginList = trove_plugins.list();
        if #pluginList > 0 then
            ui.header('Plugins');
            imgui.Spacing();
            for _, p in ipairs(pluginList) do
                ui.colored(p.name, 'accent');
                if p.description ~= '' then
                    imgui.SameLine(0, 8);
                    ui.dim(p.description);
                end
                if #p.commands > 0 then
                    imgui.SameLine(0, 8);
                    ui.dim('(/trove ' .. table.concat(p.commands, ', ') .. ')');
                end
            end
            imgui.Spacing();
        end
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Plugin definition
------------------------------------------------------------
local plugin = {
    name        = 'Settings',
    description = 'Theme selection and preferences',

    init = function(iconFn, itemResFn, uiModule)
        renderIcon = iconFn;
        getItemRes = itemResFn;
        ui = uiModule;

        -- Discover available themes
        discoverThemes();

        -- Load saved settings and apply
        local saved = loadSettings();
        if saved.theme then
            applyTheme(saved.theme);
        end
    end,

    -- Called after state is available (plugins.initAll passes state indirectly,
    -- but we need it for tab visibility — grab it from first command/render call)
    onRender = function(state)
        if troveState == nil and state then
            troveState = state;
            -- Apply saved tab visibility
            local saved = loadSettings();
            if saved.tabs and troveState.tabVisibility then
                for k, v in pairs(saved.tabs) do
                    if troveState.tabVisibility[k] ~= nil then
                        troveState.tabVisibility[k] = v;
                    end
                end
            end
        end
    end,

    -- Floating window (shown via burger menu toggle)
    window = {
        isOpen = isOpen,
        label  = 'Settings',
        icon   = 46,       -- Armor Box icon
        render = renderWindow,
        bottom = true,
    },
};

return plugin;
