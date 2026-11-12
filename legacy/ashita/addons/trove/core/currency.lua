--[[
* trove/plugins/currency.lua — Currency tab
*
* Displays currency balances grouped by section. Fully data-driven:
* the server sends section names, labels, icons, and totals via the
* 0x1A4 packet. No client-side currency definitions needed.
*
* Command: /trove currency
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

------------------------------------------------------------
-- State
------------------------------------------------------------
local currency      = {};
local currencyLoaded = false;
local fetchedAt     = 0;
local pendingRequest = false;
local TTL           = 60;

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function cacheFresh()
    return fetchedAt > 0 and (os.clock() - fetchedAt) < TTL;
end

local function requestCurrency()
    currency = {};
    pendingRequest = true;
    pkt.send(pkt.C2S.GET_CURRENCY);
end

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
-- Section accent colors
------------------------------------------------------------
local SECTION_ACCENTS = {
    { 0.55, 0.75, 1.00, 1.00 },  -- blue
    { 0.65, 0.48, 0.92, 1.00 },  -- purple
    { 0.50, 0.88, 0.50, 1.00 },  -- green
    { 1.00, 0.78, 0.35, 1.00 },  -- amber
    { 0.90, 0.50, 0.50, 1.00 },  -- red
    { 0.50, 0.85, 0.85, 1.00 },  -- teal
    { 0.85, 0.65, 0.90, 1.00 },  -- pink
    { 0.75, 0.80, 0.50, 1.00 },  -- olive
};

------------------------------------------------------------
-- Render
------------------------------------------------------------
local function render(state)
    -- Auto-fetch on tab activation
    if not currencyLoaded and not pendingRequest then
        if not cacheFresh() then
            requestCurrency();
        end
    end

    -- Group by section
    local sections = {};
    local sectionOrder = {};
    for _, entry in ipairs(currency) do
        local s = entry.section;
        if sections[s] == nil then
            sections[s] = {};
            table.insert(sectionOrder, s);
        end
        table.insert(sections[s], entry);
    end

    -- Refresh button
    local colors = {
        ui.color('btnFeature'),
        ui.color('btnFeatureHover'),
        ui.color('btnFeatureActive'),
    };
    imgui.PushStyleColor(ImGuiCol_Button, colors[1]);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, colors[2]);
    imgui.PushStyleColor(ImGuiCol_ButtonActive, colors[3]);
    if imgui.Button('Refresh##currency', { 70, 22 }) then
        requestCurrency();
    end
    imgui.PopStyleColor(3);
    imgui.Separator();
    imgui.Spacing();

    imgui.PushStyleColor(ImGuiCol_ChildBg, ui.color('windowBg'));
    imgui.BeginChild('##currency_scroll', { -1, -1 }, false);

    if #currency == 0 then
        if pendingRequest then
            imgui.TextColored(ui.color('dimmed'), 'Loading...');
        else
            imgui.TextColored(ui.color('empty'), 'No currency to display.');
        end
    else
        for si, sectionName in ipairs(sectionOrder) do
            local accent = SECTION_ACCENTS[((si - 1) % #SECTION_ACCENTS) + 1];
            local accentDim = { accent[1] * 0.35, accent[2] * 0.35, accent[3] * 0.35, 0.85 };

            -- Section header
            imgui.PushStyleColor(ImGuiCol_ChildBg, accentDim);
            local hdrId = string.format('##cursec_%s', sectionName);
            imgui.BeginChild(hdrId, { -1, 24 }, false);
            local dl = imgui.GetWindowDrawList();
            local wx, wy = imgui.GetWindowPos();
            local ww = imgui.GetWindowWidth();
            dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 24 }, imgui.GetColorU32(accent));
            dl:AddLine({ wx, wy + 23 }, { wx + ww, wy + 23 },
                imgui.GetColorU32({ accent[1], accent[2], accent[3], 0.15 }));
            imgui.SetCursorPosX(12);
            imgui.SetCursorPosY(4);
            imgui.TextColored(accent, sectionName);

            local countStr = string.format('%d', #sections[sectionName]);
            local cw = imgui.CalcTextSize(countStr);
            imgui.SameLine(ww - cw - 12);
            imgui.SetCursorPosY(4);
            imgui.TextColored({ accent[1], accent[2], accent[3], 0.50 }, countStr);

            imgui.EndChild();
            imgui.PopStyleColor(1);

            -- Value color tinted by section accent
            local valColor = { accent[1] * 0.7 + 0.3, accent[2] * 0.7 + 0.3, accent[3] * 0.7 + 0.3, 1.0 };

            -- Entries
            for i, entry in ipairs(sections[sectionName]) do
                local rowId = string.format('##currow_%s_%d', sectionName, i);
                local isAlt = (i % 2 == 0);
                local bg = getRowBg(isAlt);

                imgui.PushStyleColor(ImGuiCol_ChildBg, bg);
                imgui.BeginChild(rowId, { -1, 36 }, false);

                -- Icon
                imgui.SetCursorPos({ 6, 6 });
                if entry.iconId ~= nil and entry.iconId > 0 then
                    if not renderIcon(entry.iconId, 24) then imgui.Dummy({ 24, 24 }); end
                else
                    imgui.Dummy({ 24, 24 });
                end

                -- Name + total on first line, breakdown on second
                local dl2 = imgui.GetWindowDrawList();
                local wx2, wy2 = imgui.GetWindowPos();
                local ww2 = imgui.GetWindowWidth();

                dl2:AddText({ wx2 + 36, wy2 + 4  }, imgui.GetColorU32(ui.color('currencyName')),  entry.name);
                dl2:AddText({ wx2 + 36, wy2 + 20 }, imgui.GetColorU32(ui.color('currencyBrk')),   entry.breakdown);

                local totalStr = pkt.addCommas(entry.total);
                local tw2 = imgui.CalcTextSize(totalStr);
                dl2:AddText({ wx2 + ww2 - tw2 - 10, wy2 + 8 },
                    imgui.GetColorU32(valColor), totalStr);

                imgui.EndChild();
                imgui.PopStyleColor(1);

                if imgui.IsItemHovered() and entry.iconId and entry.iconId > 0 then
                    renderTooltip({ id = entry.iconId, name = entry.name });
                end
            end

            imgui.Spacing();
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1); -- currency_scroll bg
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Currency',
    icon        = 1708,   -- Counterfeit Gil
    author      = 'Loxley',
    version     = '1.0',
    description = 'Currency balances',

    init = function(ri, gir, uimod, rt, rfi, rfimg, gih)
        renderIcon    = ri;
        getItemRes    = gir;
        ui            = uimod;
        renderTooltip = rt;
    end,

    tab = {
        label  = 'Currency',
        render = render,
    },

    onPacketIn = function(e, state)
        if e.id ~= pkt.PACKET_ID then return; end
        local action = struct.unpack('B', e.data_modified, 0x04 + 1);

        if action == pkt.S2C.CURRENCY_ENTRY then
            local iconId    = pkt.readU16(e.data_modified, 0x06);
            local section   = pkt.readString(e.data_modified, 0x08, 15);
            local name      = pkt.readString(e.data_modified, 0x18, 23);
            local total     = pkt.readI32(e.data_modified, 0x30);
            local breakdown = pkt.readString(e.data_modified, 0x34, 71);

            table.insert(currency, {
                iconId    = iconId,
                section   = section,
                name      = name,
                total     = total,
                breakdown = breakdown,
            });
            return;
        end

        if action == pkt.S2C.CLEAR and state.pendingRequest == 'currency' then
            currency = {};
            return;
        end

        if action == pkt.S2C.END_LIST and state.pendingRequest == 'currency' then
            currencyLoaded  = true;
            fetchedAt       = os.clock();
            pendingRequest  = false;
            state.pendingRequest = nil;
            return;
        end
    end,

    -- Called when the tab activates (via ensureCurrentView in core)
    ensureData = function()
        if cacheFresh() then return; end
        requestCurrency();
    end,

    invalidate = function()
        fetchedAt = 0;
    end,

    commands = {
        currency = function(state)
            -- Toggle to currency tab
            state.isOpen[1] = true;
        end,
    },
};
