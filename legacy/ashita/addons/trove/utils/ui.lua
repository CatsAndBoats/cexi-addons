--[[
* trove/utils/ui.lua — UI helper library for Trove plugins
*
* Provides themed helper functions for common imgui patterns.
* Plugins should use these instead of raw imgui + hardcoded colors.
*
* Usage:
*     local ui = require('utils/ui');
*     ui.header('Section Title');
*     ui.text('Normal text');
*     ui.colored('Important!', 'accent');
*     if ui.button('Click Me', 'primary') then ... end
*     ui.badge('Rare', 'rare', 'rareBg');
*     ui.kv('Level', '75', 'dimmed', 'white');
]]--

local imgui = require('imgui');

local ui = {};

-- Active theme (set via ui.setTheme)
local theme = nil;

------------------------------------------------------------
-- Theme management
------------------------------------------------------------

-- Load a theme by name from themes/ directory
ui.loadTheme = function(name)
    name = name or 'default';
    -- Clear require cache so themes can be switched at runtime
    local modKey = 'themes/' .. name;
    package.loaded[modKey] = nil;
    local ok, result = pcall(function()
        return require(modKey);
    end);
    if ok and type(result) == 'table' then
        theme = result;
        return true;
    else
        print(string.format('[trove] Failed to load theme "%s": %s', name, tostring(result)));
        return false;
    end
end

-- Get the name of the currently active theme
ui.getThemeName = function()
    return ui._themeName or 'default';
end

-- Theme version counter (increments on every theme change, plugins can use to invalidate caches)
ui._themeVersion = 0;

ui.getThemeVersion = function()
    return ui._themeVersion;
end

-- Load and track theme name
ui.applyTheme = function(name)
    name = name or 'default';
    if ui.loadTheme(name) then
        ui._themeName = name;
        ui._themeVersion = ui._themeVersion + 1;
        return true;
    end
    return false;
end

-- Set theme directly from a table
ui.setTheme = function(t)
    theme = t;
end

-- Get a color from the theme by name. Returns white if not found.
ui.color = function(name)
    if theme and theme[name] then return theme[name]; end
    return { 1.0, 1.0, 1.0, 1.0 };
end

-- Get the full theme table (for plugins that need direct access)
ui.getTheme = function()
    return theme;
end

------------------------------------------------------------
-- Text helpers
------------------------------------------------------------

-- Themed colored text
ui.colored = function(text, colorName)
    imgui.TextColored(ui.color(colorName), text);
end

-- Plain text (uses imgui default color)
ui.text = function(text)
    imgui.Text(text);
end

-- Header text (bold-colored, with optional separator after)
ui.header = function(text, separator)
    imgui.TextColored(ui.color('header'), text);
    if separator ~= false then
        imgui.Separator();
    end
end

-- Subheader (accent colored, no separator by default)
ui.subheader = function(text)
    imgui.TextColored(ui.color('accent'), text);
end

-- Dimmed text (secondary info)
ui.dim = function(text)
    imgui.TextColored(ui.color('dimmed'), text);
end

-- Key-value pair on one line: "Key: Value"
ui.kv = function(key, value, keyColor, valueColor)
    imgui.TextColored(ui.color(keyColor or 'dimmed'), key);
    imgui.SameLine(0, 4);
    imgui.TextColored(ui.color(valueColor or 'white'), tostring(value));
end

-- Status message (green for ok, red for error, yellow for warning)
ui.status = function(text, level)
    local color = 'statusOk';
    if level == 'error' or level == 'err' then color = 'statusErr'; end
    if level == 'warning' or level == 'warn' then color = 'statusWarn'; end
    imgui.TextColored(ui.color(color), text);
end

------------------------------------------------------------
-- Badge / tag helpers
------------------------------------------------------------

-- Colored badge: small colored text block (e.g. "Rare", "Ex", "Aug")
ui.badge = function(text, fgColor, bgColor)
    if bgColor then
        local pos = imgui.GetCursorScreenPos();
        local textSize = imgui.CalcTextSize(text);
        local padX = 5;
        local padY = 2;
        local dl = imgui.GetWindowDrawList();
        local bg = ui.color(bgColor);
        local bgU32 = imgui.ColorConvertFloat4ToU32(bg);
        dl:AddRectFilled(
            { pos[1] - padX + 2, pos[2] - padY },
            { pos[1] + textSize[1] + padX, pos[2] + textSize[2] + padY },
            bgU32, 3.0
        );
    end
    imgui.TextColored(ui.color(fgColor or 'white'), text);
end

-- Inline badge (SameLine before it, for use after other text)
ui.inlineBadge = function(text, fgColor, bgColor, spacing)
    imgui.SameLine(0, spacing or 6);
    ui.badge(text, fgColor, bgColor);
end

------------------------------------------------------------
-- Button helpers
------------------------------------------------------------

-- Themed button.
-- Calling conventions:
--   ui.button(label)                    — auto-sized, themed
--   ui.button(label, width, height)     — sized, themed (most common)
--   ui.button(label, 'primary')         — auto-sized, named style
--   ui.button(label, 'primary', {w,h})  — sized, named style
-- Named styles: 'primary', 'feature', 'positive', 'back'
-- Returns true if clicked.
ui.button = function(label, styleOrWidth, sizeOrHeight)
    local styleName = nil;
    local btnSize   = { 0, 0 };

    -- Detect calling convention
    if type(styleOrWidth) == 'number' then
        -- ui.button(label, width, height)
        btnSize = { styleOrWidth, sizeOrHeight or 0 };
    elseif type(styleOrWidth) == 'string' then
        -- ui.button(label, 'style', size)
        styleName = styleOrWidth;
        if type(sizeOrHeight) == 'table' then btnSize = sizeOrHeight; end
    end

    local styleMap = {
        primary  = { 'btnPrimary',  'btnPrimaryHover',  'btnPrimaryActive'  },
        feature  = { 'btnFeature',  'btnFeatureHover',  'btnFeatureActive'  },
        positive = { 'btnPositive', 'btnPositiveHover', 'btnPositiveActive' },
        back     = { 'btnBack',     'btnBackHover',     'btnBackActive'     },
    };

    -- Default to 'feature' when no named style — ensures all buttons are themed
    local colors = styleMap[styleName] or styleMap['feature'];

    imgui.PushStyleColor(ImGuiCol_Button, ui.color(colors[1]));
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, ui.color(colors[2]));
    imgui.PushStyleColor(ImGuiCol_ButtonActive, ui.color(colors[3]));

    local clicked = imgui.Button(label, btnSize);

    imgui.PopStyleColor(3);

    return clicked;
end

-- Disabled button (dimmed, not clickable)
ui.buttonDisabled = function(label, size)
    imgui.PushStyleColor(ImGuiCol_Button, ui.color('btnDimmed'));
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, ui.color('btnDimmed'));
    imgui.PushStyleColor(ImGuiCol_ButtonActive, ui.color('btnDimmed'));
    imgui.PushStyleColor(ImGuiCol_Text, ui.color('dimmed'));
    imgui.Button(label, size or { 0, 0 });
    imgui.PopStyleColor(4);
end

------------------------------------------------------------
-- Layout helpers
------------------------------------------------------------

-- Push window style colors + vars from theme
ui.pushWindowStyle = function()
    -- Colors (17)
    imgui.PushStyleColor(ImGuiCol_WindowBg, ui.color('windowBg'));
    imgui.PushStyleColor(ImGuiCol_TitleBg, ui.color('windowTitleBg'));
    imgui.PushStyleColor(ImGuiCol_TitleBgActive, ui.color('windowTitleBgAct'));
    imgui.PushStyleColor(ImGuiCol_Border, ui.color('windowBorder'));
    imgui.PushStyleColor(ImGuiCol_ChildBg, ui.color('childBg'));
    imgui.PushStyleColor(ImGuiCol_FrameBg, ui.color('frameBg'));
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, ui.color('frameBgHovered'));
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg, ui.color('scrollbarBg'));
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab, ui.color('scrollbarGrab'));
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabHovered, ui.color('scrollbarHover'));
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabActive, ui.color('scrollbarActive'));
    imgui.PushStyleColor(ImGuiCol_Tab, ui.color('tab'));
    imgui.PushStyleColor(ImGuiCol_TabHovered, ui.color('tabHovered'));
    imgui.PushStyleColor(ImGuiCol_TabActive, ui.color('tabActive'));
    imgui.PushStyleColor(ImGuiCol_Header, ui.color('selectHeader'));
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, ui.color('selectHovered'));
    imgui.PushStyleColor(ImGuiCol_HeaderActive, ui.color('selectActive'));

    -- Style vars for polish (7)
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6);
    imgui.PushStyleVar(ImGuiStyleVar_ChildRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_ScrollbarRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_TabRounding, 4);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 8, 8 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 4, 3 });

    return 17; -- color count (vars tracked separately)
end

-- Pop window style colors + vars
ui.popWindowStyle = function(count)
    imgui.PopStyleVar(7);
    imgui.PopStyleColor(count or 17);
end

-- Separator with spacing
ui.separator = function()
    imgui.Spacing();
    imgui.Separator();
    imgui.Spacing();
end

-- Indent block helper
ui.indent = function(fn, amount)
    imgui.Indent(amount or 8);
    fn();
    imgui.Unindent(amount or 8);
end

-- Tooltip wrapper: call inside IsItemHovered check
ui.tooltip = function(fn)
    imgui.PushStyleColor(ImGuiCol_PopupBg, ui.color('tooltipBg'));
    imgui.BeginTooltip();
    fn();
    imgui.EndTooltip();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Convenience: push/pop a single text color
------------------------------------------------------------
ui.pushColor = function(colorName)
    imgui.PushStyleColor(ImGuiCol_Text, ui.color(colorName));
end

ui.popColor = function(count)
    imgui.PopStyleColor(count or 1);
end

------------------------------------------------------------
-- Category button (reusable for any plugin showing category lists)
--
-- Usage:
--     if ui.categoryButton('Category Name', '12 items', index) then
--         -- selected
--     end
------------------------------------------------------------
ui.categoryButton = function(name, subtitle, index)
    index = index or 0;
    local btnId = string.format('##catbtn_p_%s_%d', name, index);
    local rowWidth = imgui.GetContentRegionAvail();

    local bg = ui.color('childBg');
    local bgColor = { bg[1] + 0.04, bg[2] + 0.04, bg[3] + 0.06, 0.70 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(btnId, { rowWidth, 38 }, false);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Accent bar
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 38 }, imgui.GetColorU32(ui.color('accent')));

    imgui.SetCursorPosY(0);
    local clicked = imgui.Selectable(string.format('##catsel_p_%s_%d', name, index), false,
        ImGuiSelectableFlags_SpanAllColumns, { 0, 38 });

    -- Hover highlight
    if imgui.IsItemHovered() then
        dl:AddRectFilled({ wx + 3, wy }, { wx + ww, wy + 38 },
            imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.04 }));
    end

    dl:AddText({ wx + 12, wy + 6 }, imgui.GetColorU32(ui.color('white')), name);
    dl:AddText({ wx + 12, wy + 21 }, imgui.GetColorU32(ui.color('dimmed')), subtitle);

    -- Chevron on right
    dl:AddText({ wx + ww - 16, wy + 11 }, imgui.GetColorU32(ui.color('dimmed')), '>');

    imgui.EndChild();
    imgui.PopStyleColor(1);

    return clicked;
end

------------------------------------------------------------
-- Section header (accent bar + label, like squire/ebox category headers)
--
-- Usage:
--     ui.sectionHeader('Category Name', 12)
------------------------------------------------------------
ui.sectionHeader = function(label, count)
    local hdrId = string.format('##shdr_%s', label);
    local bg = ui.color('childBg');
    local headerBg = { bg[1] + 0.06, bg[2] + 0.06, bg[3] + 0.09, 0.85 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, headerBg);
    imgui.BeginChild(hdrId, { -1, 24 }, false);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Accent bar + subtle bottom border
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 24 }, imgui.GetColorU32(ui.color('accent')));
    dl:AddLine({ wx, wy + 23 }, { wx + ww, wy + 23 },
        imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.06 }));

    imgui.SetCursorPosX(12);
    imgui.SetCursorPosY(4);
    imgui.TextColored(ui.color('accent'), label);

    if count then
        local countStr = string.format('(%d)', count);
        local ww = imgui.GetWindowWidth();
        imgui.SameLine(ww - imgui.CalcTextSize(countStr) - 12);
        imgui.SetCursorPosY(3);
        imgui.TextColored(ui.color('dimmed'), countStr);
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Item row rendering (reusable for any plugin showing item lists)
--
-- Usage:
--     ui.itemRow(renderIcon, getItemRes, {
--         id    = 12345,   -- item ID (for icon + resource lookup)
--         name  = 'Item',  -- display name (fallback if no resource)
--         qty   = 3,       -- quantity (omit or 0/1 to hide)
--     }, index)
------------------------------------------------------------
local FLAG_RARE = 0x8000;
local FLAG_EX   = 0x4000;

ui.itemRow = function(renderIconFn, getItemResFn, item, index, tooltipFn)
    index = index or 0;
    local itemId = item.id or item.iconId or 0;
    local res = getItemResFn(itemId);
    local name = (res and res.Name and res.Name[1]) or item.name or '???';
    local qty  = item.qty or (item.tier and tonumber(item.tier)) or item.count or 1;

    local flags  = (res and res.Flags) or 0;
    local isRare = bit.band(flags, FLAG_RARE) ~= 0;
    local isEx   = bit.band(flags, FLAG_EX)   ~= 0;

    local isAlt = (index % 2 == 0);
    local rowId = string.format('##irow_%d_%d', item.id or item.iconId or 0, index);

    local base = ui.color('childBg');
    local bgColor = isAlt
        and { base[1], base[2], base[3], 0.35 }
        or  { base[1], base[2], base[3], 0.20 };
    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(rowId, { -1, 28 }, false);

    imgui.SetCursorPos({ 6, 2 });
    if not renderIconFn(itemId, 24) then
        imgui.Dummy({ 24, 24 });
    end
    imgui.SameLine(34);

    -- Invisible selectable for hover/tooltip
    imgui.SetCursorPosY(0);
    imgui.Selectable(string.format('##isel_%d_%d', itemId, index), false,
        ImGuiSelectableFlags_SpanAllColumns, { 0, 28 });
    local hovered = imgui.IsItemHovered();

    -- Name + badges drawn via drawlist
    local dl  = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Right side: qty + badges
    local rightX = wx + ww - 8;
    local qtyStr = '';
    if qty > 1 then
        qtyStr = string.format('x%d', qty);
        local qtyW = imgui.CalcTextSize(qtyStr);
        rightX = rightX - qtyW;
        dl:AddText({ rightX, wy + 7 }, imgui.GetColorU32(ui.color('dimmed')), qtyStr);
        rightX = rightX - 6;
    end

    if isEx then
        local exBg = ui.color('exBg') or { 0.10, 0.35, 0.15, 0.80 };
        local exFg = ui.color('ex') or { 0.40, 0.90, 0.40, 1.0 };
        local tw = imgui.CalcTextSize('Ex') + 8;
        rightX = rightX - tw;
        dl:AddRectFilled({ rightX, wy + 6 }, { rightX + tw, wy + 22 }, imgui.GetColorU32(exBg));
        dl:AddText({ rightX + 4, wy + 7 }, imgui.GetColorU32(exFg), 'Ex');
        rightX = rightX - 4;
    end

    if isRare then
        local rareBg = ui.color('rareBg') or { 0.40, 0.35, 0.10, 0.80 };
        local rareFg = ui.color('rare') or { 1.0, 0.85, 0.30, 1.0 };
        local tw = imgui.CalcTextSize('R') + 8;
        rightX = rightX - tw;
        dl:AddRectFilled({ rightX, wy + 6 }, { rightX + tw, wy + 22 }, imgui.GetColorU32(rareBg));
        dl:AddText({ rightX + 4, wy + 7 }, imgui.GetColorU32(rareFg), 'R');
        rightX = rightX - 4;
    end

    -- Truncate name to fit
    local nameX = wx + 34;
    local nameMaxW = rightX - nameX - 4;
    local displayName = name;
    if imgui.CalcTextSize(displayName) > nameMaxW and nameMaxW > 20 then
        while #displayName > 1 and imgui.CalcTextSize(displayName .. '..') > nameMaxW do
            displayName = displayName:sub(1, -2);
        end
        displayName = displayName .. '..';
    end
    dl:AddText({ nameX, wy + 7 }, imgui.GetColorU32(ui.color('white')), displayName);

    imgui.EndChild();

    if tooltipFn and hovered then
        tooltipFn({ id = itemId, name = name, qty = qty });
    end

    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Window background (game menu textures)
-- Call after imgui.Begin inside a window. Returns the number
-- of style colors pushed (caller must pop them before End).
------------------------------------------------------------
ui.renderBackground = function()
    local settingsPlugin = nil;
    pcall(function() settingsPlugin = require('core/settings'); end);
    if not settingsPlugin or not settingsPlugin.getBackgroundTexture then return 0; end

    local bgTex = settingsPlugin.getBackgroundTexture();
    if not bgTex then return 0; end

    local wx, wy = imgui.GetWindowPos();
    local ww, wh = imgui.GetWindowSize();
    local dl     = imgui.GetWindowDrawList();
    local tw, th = 128, 128;
    for ty = 0, math.ceil(wh / th) - 1 do
        for tx = 0, math.ceil(ww / tw) - 1 do
            dl:AddImage(bgTex,
                { wx + tx * tw, wy + ty * th },
                { wx + math.min((tx+1) * tw, ww), wy + math.min((ty+1) * th, wh) },
                { 0, 0 },
                { math.min(1, (ww - tx*tw) / tw), math.min(1, (wh - ty*th) / th) },
                0xCCFFFFFF);
        end
    end
    imgui.PushStyleColor(ImGuiCol_ChildBg, { 0, 0, 0, 0 });
    imgui.PushStyleColor(ImGuiCol_FrameBg, { 0, 0, 0, 0 });
    return 2;
end

------------------------------------------------------------
-- Close button (drawn X with hover highlight)
------------------------------------------------------------
ui.closeButton = function(id, size)
    size = size or 22;
    local pad = 5;

    local clicked = imgui.InvisibleButton(id, { size, size });
    local hovered = imgui.IsItemHovered();

    local rx, ry = imgui.GetItemRectMin();
    local dl = imgui.GetWindowDrawList();

    local bg = hovered
        and { 0.55, 0.40, 0.15, 0.95 }
        or  { 0.15, 0.18, 0.28, 0.95 };
    dl:AddRectFilled({ rx, ry }, { rx + size, ry + size }, imgui.GetColorU32(bg), 3.0);
    dl:AddRect({ rx, ry }, { rx + size, ry + size },
        imgui.GetColorU32({ 0.30, 0.35, 0.50, 0.80 }), 3.0);

    local lineColor = imgui.GetColorU32({ 0.85, 0.88, 0.95, 1.00 });
    dl:AddLine({ rx + pad, ry + pad }, { rx + size - pad, ry + size - pad }, lineColor, 2.0);
    dl:AddLine({ rx + size - pad, ry + pad }, { rx + pad, ry + size - pad }, lineColor, 2.0);

    return clicked;
end

return ui;
