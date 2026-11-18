--[[
* trove/utils/plugins.lua — Plugin manager
*
* Auto-discovers and loads .lua files from core/ and plugins/.
* Server/user plugins go in plugins/ (separate git repo or drop-in).
*
*   return {
*       name        = 'My Plugin',              -- display name (required)
*       description = 'What it does',           -- short description
*       commands    = { cmd = function(state, args) end },  -- /trove cmd
*       menu        = { label = 'Do Thing', action = function(state) end },
*       onLoad      = function() end,           -- called once on load
*       onUnload    = function() end,           -- called on addon unload
*       onPacketIn  = function(e, state) end,   -- called on every incoming packet
*       onRender    = function(state) end,      -- called every frame
*       invalidate  = function() end,           -- called on /trove refresh
*       tab         = {                         -- adds a tab to the main trove window
*           label  = 'Tab Name',
*           render = function(state) end,
*       },
*       window      = {                         -- adds a separate floating window
*           isOpen = { false },
*           render = function() end,
*       },
*   }
]]--

local imgui = require('imgui');

local plugins = {};

local loaded = {};  -- array of { plugin, path }

------------------------------------------------------------
-- Discovery: scan core/ and plugins/ directories
------------------------------------------------------------
local function scanDir(dir)
    local handle = io.popen('dir /b "' .. dir .. '*.lua" 2>nul');
    if handle == nil then return {}; end

    local files = {};
    for line in handle:lines() do
        if line:match('%.lua$') then
            files[#files + 1] = line;
        end
    end
    handle:close();
    return files;
end

local function discoverPlugins()
    local base = string.format('%saddons\\trove\\', AshitaCore:GetInstallPath());
    local results = {};

    -- Built-in plugins
    for _, f in ipairs(scanDir(base .. 'core\\')) do
        results[#results + 1] = { file = f, prefix = 'core/' };
    end

    -- User / server-specific plugins (optional)
    for _, f in ipairs(scanDir(base .. 'plugins\\')) do
        results[#results + 1] = { file = f, prefix = 'plugins/' };
    end

    return results;
end

------------------------------------------------------------
-- Cached results (rebuilt only on plugin load/unload)
------------------------------------------------------------
local cachedMenuEntries   = nil;
local cachedWindowPlugins = nil;
local cachedTopBarButtons = nil;
local cacheVersion        = 0;

local function invalidateCache()
    cachedMenuEntries   = nil;
    cachedWindowPlugins = nil;
    cachedTopBarButtons = nil;
    cacheVersion = cacheVersion + 1;
end

------------------------------------------------------------
-- Load all plugins
------------------------------------------------------------
plugins.load = function()
    local entries = discoverPlugins();
    local names = {};
    for _, entry in ipairs(entries) do
        local name = entry.file:gsub('%.lua$', '');
        local requirePath = entry.prefix .. name;
        local ok, result = pcall(function()
            return require(requirePath);
        end);

        if ok and type(result) == 'table' and result.name then
            loaded[#loaded + 1] = { plugin = result, file = entry.file };
            names[#names + 1] = result.name;
            if result.onLoad then
                local lok, lerr = pcall(result.onLoad);
                if not lok then
                    print(string.format('[trove] Plugin %s onLoad error: %s', result.name, tostring(lerr)));
                end
            end
        elseif ok then
            print(string.format('[trove] Plugin %s: invalid (must return table with .name)', entry.file));
        else
            print(string.format('[trove] Plugin %s failed to load: %s', entry.file, tostring(result)));
        end
    end

    if #names > 0 then
        print(string.format('[trove] Plugins: %s', table.concat(names, ', ')));
    end
    invalidateCache();
end

------------------------------------------------------------
-- Initialize all plugins with shared functions
-- Passes: renderIcon, getItemRes, ui (theme helper module)
------------------------------------------------------------
plugins.initAll = function(renderIcon, getItemRes, renderTooltip, renderFileIcon, renderFileImage, getIconHandle)
    local ui = require('utils/ui');
    for _, entry in ipairs(loaded) do
        if entry.plugin.init then
            local ok, err = pcall(entry.plugin.init, renderIcon, getItemRes, ui, renderTooltip, renderFileIcon, renderFileImage, getIconHandle);
            if not ok then
                print(string.format('[trove] Plugin %s init error: %s', entry.plugin.name, tostring(err)));
            end
        end
    end
end

------------------------------------------------------------
-- Unload all plugins
------------------------------------------------------------
plugins.unload = function()
    for _, entry in ipairs(loaded) do
        if entry.plugin.onUnload then
            pcall(entry.plugin.onUnload);
        end
    end
    loaded = {};
    invalidateCache();
end

------------------------------------------------------------
-- Pass shared context to plugins that support it
------------------------------------------------------------
plugins.setContext = function(ctx)
    for _, entry in ipairs(loaded) do
        if entry.plugin.setContext then
            local ok, err = pcall(entry.plugin.setContext, ctx);
            if not ok then
                print(string.format('[trove] Plugin %s setContext error: %s', entry.plugin.name, tostring(err)));
            end
        end
    end
end

------------------------------------------------------------
-- Invalidate all plugin caches (called on /trove refresh)
------------------------------------------------------------
plugins.invalidateAll = function()
    for _, entry in ipairs(loaded) do
        if entry.plugin.invalidate then
            pcall(entry.plugin.invalidate);
        end
    end
end

------------------------------------------------------------
-- Try to handle a command. Returns true if a plugin handled it.
------------------------------------------------------------
plugins.handleCommand = function(cmd, state, args)
    for _, entry in ipairs(loaded) do
        if entry.plugin.commands and entry.plugin.commands[cmd] then
            local ok, err = pcall(entry.plugin.commands[cmd], state, args);
            if not ok then
                print(string.format('[trove] Plugin %s command error: %s', entry.plugin.name, tostring(err)));
            end
            return true;
        end
    end
    return false;
end

------------------------------------------------------------
-- Dispatch packet_in to all plugins
------------------------------------------------------------
plugins.onPacketIn = function(e, state)
    for _, entry in ipairs(loaded) do
        if entry.plugin.onPacketIn then
            pcall(entry.plugin.onPacketIn, e, state);
        end
    end
end

------------------------------------------------------------
-- Dispatch plugin data to the plugin that registered for
-- a given pluginId. Each plugin can set pluginId = N in
-- its interface table to receive PLUGIN_DATA responses.
------------------------------------------------------------
plugins.onPluginData = function(pluginId, data, state)
    for _, entry in ipairs(loaded) do
        if entry.plugin.pluginId == pluginId and entry.plugin.onPluginData then
            pcall(entry.plugin.onPluginData, data, state);
            return;
        end
    end
end

------------------------------------------------------------
-- Dispatch render to all plugins
------------------------------------------------------------
plugins.onRender = function(state)
    for _, entry in ipairs(loaded) do
        if entry.plugin.onRender then
            pcall(entry.plugin.onRender, state);
        end
    end
end

------------------------------------------------------------
-- Dispatch text_in to plugins that handle it
------------------------------------------------------------
plugins.onTextIn = function(e, state)
    for _, entry in ipairs(loaded) do
        if entry.plugin.onTextIn then
            pcall(entry.plugin.onTextIn, e, state);
            if e.blocked then return; end
        end
    end
end

------------------------------------------------------------
-- Get menu entries for UI (includes both menu actions and
-- window toggles from plugins with windows)
------------------------------------------------------------
plugins.getMenuEntries = function()
    if cachedMenuEntries then return cachedMenuEntries; end
    local entries = {};
    for _, entry in ipairs(loaded) do
        if entry.plugin.menu then
            entries[#entries + 1] = {
                label     = entry.plugin.menu.label or entry.plugin.name,
                action    = entry.plugin.menu.action,
                separator = entry.plugin.menu.separator or false,
                bottom    = entry.plugin.menu.bottom or false,
                plugin    = entry.plugin,
            };
        end
    end
    cachedMenuEntries = entries;
    return entries;
end

------------------------------------------------------------
-- Query status strips from plugins (for persistent status bar)
------------------------------------------------------------
-- Status strips are dynamic (depend on registration state etc), but we can
-- reuse the same table each frame instead of allocating new ones
local statusStripBuf = {};

plugins.getStatusStrips = function()
    -- Clear and reuse same table
    for i = #statusStripBuf, 1, -1 do statusStripBuf[i] = nil; end
    for _, entry in ipairs(loaded) do
        if entry.plugin.getStatus then
            local ok, status = pcall(entry.plugin.getStatus);
            if ok and status then
                statusStripBuf[#statusStripBuf + 1] = status;
            end
        end
    end
    return statusStripBuf;
end

------------------------------------------------------------
-- Render plugin tabs inside the main tab bar.
-- Called from trove.lua after built-in tabs.
------------------------------------------------------------
-- Render priority plugin tabs (tab.priority = true) — called early in tab order
plugins.renderPriorityTabs = function(state)
    for _, entry in ipairs(loaded) do
        if entry.plugin.tab and entry.plugin.tab.priority then
            local tab = entry.plugin.tab;
            local label = (tab.getLabel and tab.getLabel()) or tab.label;
            if imgui.BeginTabItem(label) then
                local ok, err = pcall(tab.render, state);
                if not ok then
                    imgui.TextColored({ 1, 0.3, 0.3, 1 }, 'Plugin error: ' .. tostring(err));
                end
                imgui.EndTabItem();
            end
        end
    end
end

-- Render normal plugin tabs (non-priority) — called after built-in tabs
plugins.renderTabs = function(state)
    for _, entry in ipairs(loaded) do
        if entry.plugin.tab and not entry.plugin.tab.priority then
            local tab = entry.plugin.tab;
            local label = (tab.getLabel and tab.getLabel()) or tab.label;
            if imgui.BeginTabItem(label) then
                local ok, err = pcall(tab.render, state);
                if not ok then
                    imgui.TextColored({ 1, 0.3, 0.3, 1 }, 'Plugin error: ' .. tostring(err));
                end
                imgui.EndTabItem();
            end
        end
    end
end

------------------------------------------------------------
-- Render plugin floating windows.
-- Called from trove.lua in the render loop.
------------------------------------------------------------
plugins.renderWindows = function()
    for _, entry in ipairs(loaded) do
        if entry.plugin.window then
            local win = entry.plugin.window;
            if win.isOpen[1] then
                local ok, err = pcall(win.render);
                if not ok then
                    print(string.format('[trove] Plugin %s window error: %s', entry.plugin.name, tostring(err)));
                end
            end
        end
    end
end

------------------------------------------------------------
-- Get plugins that have windows (for menu toggles)
------------------------------------------------------------
plugins.getWindowPlugins = function()
    if cachedWindowPlugins then return cachedWindowPlugins; end
    local top = {};
    local bottom = {};
    for _, entry in ipairs(loaded) do
        if entry.plugin.window then
            if entry.plugin.window.bottom then
                bottom[#bottom + 1] = entry.plugin;
            else
                top[#top + 1] = entry.plugin;
            end
        end
    end
    if #bottom > 0 and #top > 0 then
        bottom[1]._menuSeparator = true;
    end
    for _, p in ipairs(bottom) do top[#top + 1] = p; end
    cachedWindowPlugins = top;
    return top;
end

------------------------------------------------------------
-- Get top bar buttons from plugins
------------------------------------------------------------
-- Top bar buttons: cached but also depend on isVisible() which is dynamic.
-- Rebuild each frame but reuse the same table.
local topBarBuf = {};

plugins.getTopBarButtons = function()
    for i = #topBarBuf, 1, -1 do topBarBuf[i] = nil; end
    for _, entry in ipairs(loaded) do
        local btn = entry.plugin.topBarButton;
        if btn and (not btn.isVisible or btn.isVisible()) then
            topBarBuf[#topBarBuf + 1] = btn;
        end
    end
    return topBarBuf;
end

------------------------------------------------------------
-- Check if any plugin has an active alert (for burger btn)
------------------------------------------------------------
plugins.hasAlert = function()
    for _, entry in ipairs(loaded) do
        if entry.plugin.hasAlert and entry.plugin.hasAlert() then
            return true;
        end
    end
    return false;
end

------------------------------------------------------------
-- Get list of loaded plugins (for display)
------------------------------------------------------------
plugins.list = function()
    local result = {};
    for _, entry in ipairs(loaded) do
        result[#result + 1] = {
            name        = entry.plugin.name,
            author      = entry.plugin.author or '',
            version     = entry.plugin.version or '',
            description = entry.plugin.description or '',
            icon        = entry.plugin.icon or (entry.plugin.window and entry.plugin.window.icon) or (entry.plugin.tab and entry.plugin.tab.icon) or nil,
            file        = entry.file,
            hasMenu     = entry.plugin.menu ~= nil,
            hasTab      = entry.plugin.tab ~= nil,
            hasWindow   = entry.plugin.window ~= nil,
            commands    = {},
        };
        if entry.plugin.commands then
            for cmd in pairs(entry.plugin.commands) do
                result[#result].commands[#result[#result].commands + 1] = cmd;
            end
        end
    end
    return result;
end

return plugins;
