--[[
* trove — Modular storage and progression tool
*
* Core UI framework with plugin-driven tabs and floating windows.
* Server-specific features are loaded from plugins/.
*
* Usage:
*     /trove              - Toggle window (also bound to Ctrl+Z)
*     /trove show         - Show window
*     /trove hide         - Hide window
*     /trove refresh      - Force-refresh all data
]]--

addon.name      = 'trove';
addon.author    = 'Loxley';
addon.version   = '1.0.0';
addon.desc      = 'Modular storage and progression tool';

require('common');
local ffi   = require('ffi');
local d3d   = require('d3d8');
local imgui = require('imgui');

local C       = ffi.C;
local d3d8dev = d3d.get_device();

ffi.cdef[[
    HRESULT __stdcall D3DXCreateTextureFromFileA(IDirect3DDevice8* pDevice, const char* pSrcFile, IDirect3DTexture8** ppTexture);
]];

local trove_plugins  = require('utils/plugins');
local trove_ui       = require('utils/ui');
local trove_pkt      = require('utils/packet');

------------------------------------------------------------
-- Theme (change to load a custom theme from themes/)
------------------------------------------------------------
local THEME = 'default';
trove_ui.applyTheme(THEME);

------------------------------------------------------------
-- Packet protocol (shared module)
------------------------------------------------------------
local PACKET_ID = trove_pkt.PACKET_ID;
local C2S       = trove_pkt.C2S;
local S2C       = trove_pkt.S2C;

-- Keybind. Ashita uses caret-prefix modifiers: ^ = ctrl, ! = alt, + = shift.
local KEYBIND = '^z';

------------------------------------------------------------
-- AH Category display names
------------------------------------------------------------
local AH_NAMES = {
    [1]  = 'H2H',           [2]  = 'Dagger',        [3]  = 'Sword',
    [4]  = 'Greatsword',    [5]  = 'Axe',           [6]  = 'Greataxe',
    [7]  = 'Scythe',        [8]  = 'Polearm',       [9]  = 'Katana',
    [10] = 'Greatkatana',   [11] = 'Club',          [12] = 'Staff',
    [13] = 'Bow',           [14] = 'Instruments',   [15] = 'Ammunition',
    [16] = 'Shield',        [17] = 'Head',          [18] = 'Body',
    [19] = 'Hands',         [20] = 'Legs',          [21] = 'Feet',
    [22] = 'Neck',          [23] = 'Waist',         [24] = 'Earrings',
    [25] = 'Rings',         [26] = 'Back',
    [28] = 'White Magic',   [29] = 'Black Magic',   [30] = 'Summoning',
    [31] = 'Ninjutsu',      [32] = 'Songs',         [33] = 'Medicines',
    [34] = 'Furnishings',   [35] = 'Crystals',      [36] = 'Cards',
    [37] = 'Cursed Items',  [38] = 'Smithing',      [39] = 'Goldsmithing',
    [40] = 'Clothcraft',    [41] = 'Leathercraft',  [42] = 'Bonecraft',
    [43] = 'Woodworking',   [44] = 'Alchemy',       [45] = 'Geomancy',
    [46] = 'Misc',          [47] = 'Fishing Gear',  [48] = 'Pet Items',
    [49] = 'Ninja Tools',   [50] = 'Beast-made',    [51] = 'Fish',
    [52] = 'Meat & Eggs',   [53] = 'Seafood',       [54] = 'Vegetables',
    [55] = 'Soups',         [56] = 'Breads & Rice', [57] = 'Sweets',
    [58] = 'Drinks',        [59] = 'Ingredients',   [60] = 'Dice',
    [61] = 'Automaton',     [62] = 'Grips',         [63] = 'Alchemy 2',
    [64] = 'Misc 2',        [65] = 'Misc 3',
    [100] = 'Incursion',    [101] = 'Spawners',     [102] = 'Abyssea',
    [103] = 'Limbus',       [104] = 'Ventures',
    [255] = 'Other',
};

local CUSTOM_ORDER = {
    [100] = 1, [101] = 2, [102] = 3, [103] = 4, [104] = 5,
};

------------------------------------------------------------
-- Colors (proxy to active theme — changes when theme switches)
-- Maps old key names to theme keys where they differ.
------------------------------------------------------------
local COLOR_ALIASES = {
    btnWithdraw = 'btnPrimary',
    btnHover    = 'btnPrimaryHover',
    btnActive   = 'btnPrimaryActive',
    btnFeatureH = 'btnFeatureHover',
    btnFeatureA = 'btnFeatureActive',
    btnStoreH   = 'btnPositiveHover',
    btnStoreA   = 'btnPositiveActive',
    btnStore    = 'btnPositive',
    btnBackH    = 'btnBackHover',
    btnBackA    = 'btnBackActive',
};

local COLORS = setmetatable({}, {
    __index = function(_, key)
        local themeKey = COLOR_ALIASES[key] or key;
        return trove_ui.color(themeKey);
    end,
});

-- Reusable tables for menu popup (avoid per-frame allocations)
local MENU_CATEGORY_ORDER = { 'Utility', 'Storage', 'Collections', 'Games', 'Account' };
local menuByCategory   = {};
local menuUncategorised = {};

-- renderPluginEntry defined after renderIcon/renderFileIcon (forward ref)

-- Cached alternating row backgrounds (rebuilt on theme change to avoid per-row allocations)
local rowBgCache = { version = -1, alt = nil, normal = nil };
local function getRowBg(isAlt)
    local v = trove_ui.getThemeVersion();
    if rowBgCache.version ~= v then
        local base = COLORS.childBg;
        rowBgCache.alt    = { base[1], base[2], base[3], 0.35 };
        rowBgCache.normal = { base[1], base[2], base[3], 0.20 };
        rowBgCache.version = v;
    end
    return isAlt and rowBgCache.alt or rowBgCache.normal;
end

------------------------------------------------------------
-- Item flag constants
------------------------------------------------------------
local FLAG_RARE = 0x8000;
local FLAG_EX   = 0x4000;

------------------------------------------------------------
-- Lookup tables
------------------------------------------------------------
local JOB_ABBR = {
    'WAR','MNK','WHM','BLM','RDM','THF','PLD','DRK','BST','BRD',
    'RNG','SAM','NIN','DRG','SMN','BLU','COR','PUP','DNC','SCH',
    'GEO','RUN',
};

-- AF headpiece item IDs per job (for job icon display)
local JOB_ICON_ITEMS = {
    [1]  = 12511, [2]  = 12512, [3]  = 13855, [4]  = 13856,
    [5]  = 12513, [6]  = 12514, [7]  = 12515, [8]  = 12516,
    [9]  = 12517, [10] = 13857, [11] = 12518, [12] = 13868,
    [13] = 13869, [14] = 12519, [15] = 12520, [16] = 11465,
    [17] = 15266, [18] = 11471, [19] = 11478, [20] = 16140,
    [21] = 27786, [22] = 27787,
};

local SLOT_NAMES = {
    [0x0001] = 'Main',  [0x0002] = 'Sub',    [0x0004] = 'Range',
    [0x0008] = 'Ammo',  [0x0010] = 'Head',   [0x0020] = 'Body',
    [0x0040] = 'Hands', [0x0080] = 'Legs',   [0x0100] = 'Feet',
    [0x0200] = 'Neck',  [0x0400] = 'Waist',  [0x0800] = 'L.Ear',
    [0x1000] = 'R.Ear', [0x2000] = 'L.Ring', [0x4000] = 'R.Ring',
    [0x8000] = 'Back',
};

local WEAPON_SKILLS = {
    [1] = 'Hand-to-Hand', [2] = 'Dagger',     [3] = 'Sword',
    [4] = 'Great Sword',  [5] = 'Axe',        [6] = 'Great Axe',
    [7] = 'Scythe',       [8] = 'Polearm',    [9] = 'Katana',
    [10] = 'Great Katana', [11] = 'Club',      [12] = 'Staff',
    [25] = 'Archery',     [26] = 'Marksmanship', [27] = 'Throwing',
};

local QTY_BUTTONS = {
    { label = 'x1',  qty = 1  },
    { label = 'x3',  qty = 3  },
    { label = 'x6',  qty = 6  },
    { label = 'x12', qty = 12 },
    { label = 'x99', qty = 99 },
    { label = '...',  qty = 0  },
};

------------------------------------------------------------
-- Item helpers
------------------------------------------------------------
local function getSlotName(slots)
    if slots == nil or slots == 0 then return nil; end
    for mask, name in pairs(SLOT_NAMES) do
        if bit.band(slots, mask) ~= 0 then return name; end
    end
    return nil;
end

local function getJobList(jobs)
    if jobs == nil or jobs == 0 then return nil; end
    -- Ashita's resource Jobs field follows the DAT convention: bit N = job N,
    -- i.e. bit 1 = WAR, bit 2 = MNK, ..., bit 22 = RUN (bit 0 is NONE). This
    -- differs from the server's packed form and from how `1 << (job-1)` is
    -- used server-side. All-jobs here is bits 1..22 = 0x7FFFFE.
    if bit.band(jobs, 0x7FFFFE) == 0x7FFFFE then return 'All Jobs'; end
    local list = {};
    for i = 1, 22 do
        if bit.band(jobs, bit.lshift(1, i)) ~= 0 then
            table.insert(list, JOB_ABBR[i]);
        end
    end
    return table.concat(list, '/');
end

local function getItemRes(itemId)
    if itemId == nil or itemId == 0 then return nil; end
    return AshitaCore:GetResourceManager():GetItemById(itemId);
end

ffi.cdef[[
    int MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
    int WideCharToMultiByte(uint32_t CodePage, uint32_t dwFlags, const wchar_t* lpWideCharStr, int cchWideChar, char* lpMultiByteStr, int cbMultiByte, const char* lpDefaultChar, int* lpUsedDefaultChar);
]]

-- FFXI item descriptions use a custom font that maps certain invalid-
-- ShiftJIS byte pairs to element icons. MultiByteToWideChar doesn't know
-- about them and emits "?". We translate each `0xEF <idx>` pair to a
-- sentinel `0x01 <idx>` so the description still encodes the element
-- position; the renderer later turns those into colored "●" glyphs.
-- `0x01` (ASCII SOH) is a control character that won't appear in normal
-- item text and survives the ShiftJIS → UTF-8 round-trip unchanged.
local ELEMENT_COLORS = {
    [0x1F] = { 1.00, 0.45, 0.25, 1.00 },  -- Fire: orange-red
    [0x20] = { 0.55, 0.85, 1.00, 1.00 },  -- Ice: light cyan
    [0x21] = { 0.55, 1.00, 0.55, 1.00 },  -- Wind: green
    [0x22] = { 0.90, 0.75, 0.45, 1.00 },  -- Earth: tan
    [0x23] = { 1.00, 0.90, 0.30, 1.00 },  -- Thunder: yellow
    [0x24] = { 0.45, 0.60, 1.00, 1.00 },  -- Water: blue
    [0x25] = { 1.00, 1.00, 0.85, 1.00 },  -- Light: pale
    [0x26] = { 0.75, 0.45, 1.00, 1.00 },  -- Dark: purple
};

local ELEMENT_MARK = 0x01;  -- sentinel byte before a colored-element index

local function replaceElementGlyphs(s)
    if s:find('\xEF', 1, true) == nil then return s; end
    local out, i, n = {}, 1, #s;
    while i <= n do
        local b = s:byte(i);
        if b == 0xEF and i < n and ELEMENT_COLORS[s:byte(i + 1)] ~= nil then
            out[#out + 1] = string.char(ELEMENT_MARK, s:byte(i + 1));
            i = i + 2;
        else
            out[#out + 1] = s:sub(i, i);
            i = i + 1;
        end
    end
    return table.concat(out);
end

-- Reusable FFI buffers for ShiftJIS → UTF-8 conversion. Previously these
-- were allocated inside shiftjis_to_utf8 (12 KB per call, every tooltip
-- frame at 60 fps → heavy GC pressure and eventual OOM after hours).
local sjis_buf  = ffi.new('char[4096]');
local sjis_wbuf = ffi.new('wchar_t[4096]');

local function shiftjis_to_utf8(input)
    if input == nil then return nil; end
    input = replaceElementGlyphs(input);
    ffi.copy(sjis_buf, input);
    ffi.C.MultiByteToWideChar(932, 0, sjis_buf, -1, sjis_wbuf, 4096);
    ffi.C.WideCharToMultiByte(65001, 0, sjis_wbuf, -1, sjis_buf, 4096, nil, nil);
    return ffi.string(sjis_buf);
end

local function getItemString(res, field, index)
    if res == nil then return nil; end
    local val = res[field][index or 1];
    if val == nil then return nil; end
    return shiftjis_to_utf8(val);
end

-- Render an item description that may contain ELEMENT_MARK sentinels for
-- per-element coloured dots. Text flows inline with `SameLine(0, 0)` and
-- wraps at segment boundaries when the accumulated line would exceed the
-- current content width. `\n` in the description forces a new line.
--
-- Element dots are drawn on the window's drawlist as filled circles
-- instead of using a Unicode glyph — the default imgui font doesn't
-- include U+25CF (BLACK CIRCLE) and falls back to "?" for it.
local DOT_WIDTH  = 10;  -- total horizontal slot reserved for a dot
local DOT_RADIUS = 3;

local function renderColoredDescription(desc, defaultColor)
    if desc == nil or #desc == 0 then return; end

    local wrapWidth = imgui.GetContentRegionAvail();
    local lineW    = 0;
    local rendered = false;

    local function preRender(w)
        if rendered and (lineW + w > wrapWidth) then
            -- The previous widget already advanced to the next row; skip
            -- SameLine so this segment starts fresh on that row.
            lineW = 0;
        elseif rendered then
            imgui.SameLine(0, 0);
        end
    end

    local function emitText(text, color, escape)
        local w = imgui.CalcTextSize(text);
        preRender(w);
        if escape then text = text:gsub('%%', '%%%%'); end
        imgui.TextColored(color, text);
        lineW = lineW + w;
        rendered = true;
    end

    local function emitDot(color)
        preRender(DOT_WIDTH);
        local dl = imgui.GetWindowDrawList();
        local sx, sy = imgui.GetCursorScreenPos();
        local lineH = imgui.GetTextLineHeight();
        dl:AddCircleFilled(
            { sx + DOT_WIDTH / 2, sy + lineH / 2 },
            DOT_RADIUS,
            imgui.GetColorU32(color));
        imgui.Dummy({ DOT_WIDTH, lineH });
        lineW = lineW + DOT_WIDTH;
        rendered = true;
    end

    local i, n = 1, #desc;
    while i <= n do
        local b = desc:byte(i);
        if b == 0x0A then
            if not rendered then imgui.Text(''); end
            lineW, rendered = 0, false;
            i = i + 1;
        elseif b == ELEMENT_MARK and i < n then
            local color = ELEMENT_COLORS[desc:byte(i + 1)];
            if color ~= nil then
                emitDot(color);
                i = i + 2;
            else
                i = i + 1;
            end
        else
            local start = i;
            while i <= n do
                local bb = desc:byte(i);
                if bb == 0x0A or bb == ELEMENT_MARK then break; end
                i = i + 1;
            end
            if i > start then
                emitText(desc:sub(start, i - 1), defaultColor, true);
            end
        end
    end
end

------------------------------------------------------------
-- Texture cache (game item icons + file-based images)
------------------------------------------------------------
local textureCache      = {};
local fileTextures      = {};  -- filename -> texture
local textureHandles    = {};  -- itemId|filename -> tonumber(uint32) for imgui.Image
local textureLRU        = {};  -- LRU queue of item IDs for eviction
local TEXTURE_CACHE_MAX = 512;

-- Explicitly release a D3D texture: disarm the GC-release first, then
-- call Release() ourselves so VRAM is freed immediately.
local function releaseTexture(tex)
    if tex == nil then return; end
    pcall(function()
        ffi.gc(tex, nil);   -- disarm GC Release
        tex:Release();      -- immediate D3D Release
    end);
end

local function loadItemTexture(itemId)
    if textureCache[itemId] ~= nil then return textureCache[itemId]; end
    if itemId == nil or itemId == 0 then textureCache[itemId] = false; return false; end

    local item = getItemRes(itemId);
    if item == nil or item.ImageSize == 0 then textureCache[itemId] = false; return false; end

    -- Evict oldest texture if cache is full — explicitly release D3D resource
    if #textureLRU >= TEXTURE_CACHE_MAX then
        local evict = table.remove(textureLRU, 1);
        releaseTexture(textureCache[evict]);
        textureCache[evict]   = nil;
        textureHandles[evict] = nil;
    end

    local ptr = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileInMemoryEx(
        d3d8dev, item.Bitmap, item.ImageSize,
        0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT,
        0xFF000000, nil, nil, ptr) ~= C.S_OK) then
        textureCache[itemId] = false; return false;
    end

    local tex = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
    textureCache[itemId] = tex;
    textureHandles[itemId] = tonumber(ffi.cast('uint32_t', tex));
    textureLRU[#textureLRU + 1] = itemId;
    return tex;
end

local function loadFileTexture(filename)
    if fileTextures[filename] ~= nil then return fileTextures[filename]; end
    -- Search: addon images/ first, then plugins/images/ fallback
    local path = string.format('%s/images/%s', addon.path, filename);
    local ptr = ffi.new('IDirect3DTexture8*[1]');
    if C.D3DXCreateTextureFromFileA(d3d8dev, path, ptr) ~= C.S_OK then
        -- Try plugins/images/
        path = string.format('%s/plugins/images/%s', addon.path, filename);
        if C.D3DXCreateTextureFromFileA(d3d8dev, path, ptr) ~= C.S_OK then
            fileTextures[filename] = false;
            return false;
        end
    end
    -- CRITICAL: store the gc_safe_release return value, not the raw pointer.
    -- Previously the wrapper was created then discarded — when GC collected
    -- it, Release() was called on the D3D texture while the addon still held
    -- a dangling raw pointer. Next render → use-after-free → crash.
    local tex = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
    fileTextures[filename] = tex;
    textureHandles[filename] = tonumber(ffi.cast('uint32_t', tex));
    return tex;
end

------------------------------------------------------------
-- Packet helpers (delegate to shared module)
------------------------------------------------------------
local addCommas = trove_pkt.addCommas;

------------------------------------------------------------
-- State
------------------------------------------------------------

-- State — core only. Plugin-specific state lives in each plugin.
local state = {
    -- Active tab (plugins set this when their tab activates)
    activeTab      = nil,
    pendingRequest = nil,

    -- Status (shared — plugins can call setStatus)
    statusMsg     = '',
    statusIsErr   = false,
    statusUntil   = 0,
};

local ui = {
    isOpen      = { false },
    keybindDone = false,
};

local function setStatus(msg, isErr)
    state.statusMsg   = msg or '';
    state.statusIsErr = isErr or false;
    state.statusUntil = os.clock() + 4;
end

-- View transitions, tab activation, and data fetching are now
-- handled by each plugin via ensureData/invalidate hooks.

------------------------------------------------------------
-- Event handlers
------------------------------------------------------------
ashita.events.register('text_in', 'trove_text_in', function(e)
    if trove_plugins and trove_plugins.onTextIn then
        trove_plugins.onTextIn(e, state);
    end
end);

ashita.events.register('packet_in', 'trove_plugin_packets', function(e)
    if trove_plugins and trove_plugins.onPacketIn then
        local ok, err = pcall(trove_plugins.onPacketIn, e, state);
        if not ok then
            print(string.format('[trove] Plugin packet error: %s', tostring(err)));
        end
    end
end);

ashita.events.register('packet_in', 'trove_packet_in', function(e)
    if e.id ~= PACKET_ID then return; end
    e.blocked = true;

    -- All action-specific handling is now in plugins (via onPacketIn).
    -- Core only handles PLUGIN_DATA routing by pluginId.
    local ok, err = pcall(function()

    local action = struct.unpack('B', e.data_modified, 0x04 + 1);

    if action == S2C.PLUGIN_DATA then
        local pluginId = struct.unpack('B', e.data_modified, 0x05 + 1);
        trove_plugins.onPluginData(pluginId, e.data_modified, state);
        return;
    end

    end); -- pcall
    if not ok then print('[trove] Packet error: ' .. tostring(err)); end
end);

------------------------------------------------------------
-- Groupings for display
------------------------------------------------------------
-- Render helpers (icons, badges, tooltips, item rows)
------------------------------------------------------------
local function renderIcon(itemId, size)
    local tex = loadItemTexture(itemId);
    local handle = textureHandles[itemId];
    if tex and tex ~= false and handle ~= nil then
        imgui.Image(handle, { size, size });
        return true;
    end
    return false;
end

-- Forward declaration (defined below, needed by initPlugins)
local renderTooltip;

-- Render a file-based texture from images/ directory
local function renderFileIcon(filename, size)
    local tex = loadFileTexture(filename);
    local handle = textureHandles[filename];
    if tex and tex ~= false and handle ~= nil then
        imgui.Image(handle, { size, size });
        return true;
    end
    return false;
end

-- Get raw texture handle for an item icon (for drawlist rendering)
local function getIconHandle(itemId)
    local tex = loadItemTexture(itemId);
    return textureHandles[itemId];
end

-- Render a file-based texture at arbitrary width/height
local function renderFileImage(filename, w, h)
    local tex = loadFileTexture(filename);
    local handle = textureHandles[filename];
    if tex and tex ~= false and handle ~= nil then
        imgui.Image(handle, { w, h });
        return true;
    end
    return false;
end

-- Plugin menu entry renderer (defined once, avoids per-frame closure)
local function renderPluginEntry(plugin)
    local win = plugin.window;
    if win.icon then
        if type(win.icon) == 'string' then
            renderFileIcon(win.icon, 16);
        else
            renderIcon(win.icon, 16);
        end
        imgui.SameLine(0, 6);
    end
    local label = win.label or plugin.name;
    if plugin.hasAlert and plugin.hasAlert() then label = label .. ' (!)'; end
    if imgui.Selectable(label, win.isOpen[1]) then
        win.isOpen[1] = not win.isOpen[1];
    end
end

-- Forward declarations for functions defined after pluginCtx
local renderBadges;
local renderItemDetail;

-- Shared context passed to all plugins via init. Contains every helper
-- function a plugin might need so the init signature doesn't keep growing.
local pluginCtx = {
    renderIcon    = function(...) return renderIcon(...); end,
    getItemRes    = getItemRes,
    renderTooltip = function(...) return renderTooltip(...); end,
    renderFileIcon  = function(...) return renderFileIcon(...); end,
    renderFileImage = function(...) return renderFileImage(...); end,
    getIconHandle   = getIconHandle,
    getItemString   = getItemString,
    getSlotName     = getSlotName,
    getJobList      = getJobList,
    addCommas       = addCommas,
    getRowBg        = getRowBg,
    setStatus       = setStatus,
    renderBadges    = function(...) return renderBadges(...); end,
    renderItemDetail = function(...) return renderItemDetail(...); end,
    renderColoredDescription = function(...) return renderColoredDescription(...); end,
    -- Constants
    AH_NAMES     = AH_NAMES,
    CUSTOM_ORDER = CUSTOM_ORDER,
    FLAG_RARE    = FLAG_RARE,
    FLAG_EX      = FLAG_EX,
    SLOT_NAMES   = SLOT_NAMES,
    WEAPON_SKILLS = WEAPON_SKILLS,
    QTY_BUTTONS  = QTY_BUTTONS,
};

local function initPlugins()
    -- Legacy init signature (renderIcon, getItemRes, renderTooltip, ...) for backward compat
    trove_plugins.initAll(renderIcon, getItemRes, renderTooltip, renderFileIcon, renderFileImage, getIconHandle);
    -- New: pass shared context to plugins that support it
    trove_plugins.setContext(pluginCtx);
end

renderBadges = function(flags)
    if flags == nil or flags == 0 then return; end
    local isRare = bit.band(flags, FLAG_RARE) ~= 0;
    local isEx   = bit.band(flags, FLAG_EX) ~= 0;
    if not isRare and not isEx then return; end

    if isRare then
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.rareBg);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.rareBg);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.rareBg);
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.rare);
        imgui.SmallButton('Rare');
        imgui.PopStyleColor(4);
    end
    if isEx then
        if isRare then imgui.SameLine(0, 4); end
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.exBg);
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, COLORS.exBg);
        imgui.PushStyleColor(ImGuiCol_ButtonActive, COLORS.exBg);
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.ex);
        imgui.SmallButton('Ex');
        imgui.PopStyleColor(4);
    end
end

renderItemDetail = function(res, storedQty)
    if res == nil then return; end

    local isEquip  = (res.Level > 0 or res.Jobs > 0 or res.Slots > 0);
    local isWeapon = (res.Damage > 0 and res.Delay > 0 and res.Skill > 0);

    if storedQty ~= nil then
        imgui.TextColored(COLORS.dimmed, 'Stored:');
        imgui.SameLine();
        local qc = (storedQty <= 5) and COLORS.qtyLow or COLORS.qty;
        imgui.TextColored(qc, tostring(storedQty));
    end

    renderBadges(res.Flags);

    if res.StackSize > 1 then
        imgui.TextColored(COLORS.dimmed, string.format('Stack: %d', res.StackSize));
    end

    if isEquip then
        if isWeapon then
            local skill = WEAPON_SKILLS[res.Skill] or 'Unknown';
            imgui.TextColored(COLORS.slotText, string.format('(%s)', skill));
        elseif res.Slots > 0 then
            local slot = getSlotName(res.Slots);
            if slot then imgui.TextColored(COLORS.slotText, string.format('[%s]', slot)); end
        end

        if isWeapon then
            imgui.TextColored(COLORS.yellow, string.format('DMG:%d  Delay:%d', res.Damage, res.Delay));
        end
    end

    local desc = getItemString(res, 'Description', 1);
    if desc ~= nil and #desc > 0 then
        -- Weapons have "DMG:N Delay:N" at the start of the description, which
        -- we already render in yellow above. Strip it so it's not duplicated.
        -- Hand-to-Hand weapons use "DMG:+N" / "Delay:+N" (signed), so allow
        -- a leading + or -. The trailing class stays whitespace-only so any
        -- other stats that share the line (e.g. "... HP+35 STR+4") survive.
        if isWeapon then
            desc = desc:gsub("^%s*DMG:%s*[%+%-]?%d+%s*Delay:%s*[%+%-]?%d+%s*[\r\n]*", "")
        end
        if #desc > 0 then
            imgui.Spacing();
            -- renderColoredDescription wraps at segment boundaries itself
            -- (it measures each piece against GetContentRegionAvail), and
            -- already escapes "%" so printf format specifiers don't crash
            -- imgui. The segment pipeline also turns the ELEMENT_MARK
            -- sentinels into coloured "●" glyphs inline with the text.
            renderColoredDescription(desc, COLORS.desc);
        end
    end

    -- Level / jobs line sits beneath the description on equipment so the
    -- requirement info reads as a footer rather than a header.
    if isEquip and (res.Level > 0 or res.Jobs > 0) then
        local jobStr = getJobList(res.Jobs) or '';
        local lvlStr = '';
        if res.Level > 0 then
            lvlStr = string.format('Lv%d ', res.Level);
        end
        imgui.Spacing();
        imgui.TextColored(COLORS.jobText, lvlStr .. jobStr);
    end
end

renderTooltip = function(item)
    imgui.SetNextWindowSize({ 400, -1 }, ImGuiCond_Always);
    imgui.BeginTooltip();
    imgui.PushTextWrapPos(380);

    local tex = loadItemTexture(item.id);
    local handle = textureHandles[item.id];
    if tex and tex ~= false and handle ~= nil then
        imgui.Image(handle, { 32, 32 });
        imgui.SameLine();
    end

    imgui.TextColored(COLORS.header, item.name);
    imgui.Separator();

    local res = getItemRes(item.id);
    renderItemDetail(res, item.qty);

    imgui.PopTextWrapPos();
    imgui.EndTooltip();
end


------------------------------------------------------------
-- Render: Main window (tab bar)
------------------------------------------------------------
-- Tab rendering is now fully plugin-driven

local function renderWindow()
    if not ui.isOpen[1] then return; end

    imgui.SetNextWindowSize({ 380, 560 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 320, 280 }, { 500, 900 });

    imgui.PushStyleColor(ImGuiCol_TitleBg,         COLORS.windowTitleBg);
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,    COLORS.windowTitleBgAct);
    imgui.PushStyleColor(ImGuiCol_WindowBg,         COLORS.windowBg);
    imgui.PushStyleColor(ImGuiCol_Border,           COLORS.windowBorder);
    imgui.PushStyleColor(ImGuiCol_FrameBg,          COLORS.frameBg);
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered,   COLORS.frameBgHovered);
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg,      COLORS.scrollbarBg);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab,    COLORS.scrollbarGrab);
    imgui.PushStyleColor(ImGuiCol_Tab,              COLORS.tab);
    imgui.PushStyleColor(ImGuiCol_TabHovered,       COLORS.tabHovered);
    imgui.PushStyleColor(ImGuiCol_TabActive,        COLORS.tabActive);
    -- Selectable / row hover colours
    imgui.PushStyleColor(ImGuiCol_Header,           COLORS.selectHeader);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered,    COLORS.selectHovered);
    imgui.PushStyleColor(ImGuiCol_HeaderActive,     COLORS.selectActive);

    if imgui.Begin('Trove', ui.isOpen, ImGuiWindowFlags_None) then

        -- Game menu background (if enabled in Settings)
        local bgStylePushed = trove_ui.renderBackground();

        -- Top bar: left = context info, right = burger + settings
        local ww = imgui.GetWindowWidth();
        local dl = imgui.GetWindowDrawList();

        -- VNM alert button (conditional — only shows when a VNM is active)
        local vnmPlugin = nil;
        local winPlugins = trove_plugins.getWindowPlugins();
        for _, plugin in ipairs(winPlugins) do
            if plugin.name and plugin.name:find('VNM') and plugin.hasAlert and plugin.hasAlert() then
                vnmPlugin = plugin;
                break;
            end
        end

        -- Right: top bar buttons + Menu button
        local menuW = imgui.CalcTextSize('Menu') + 18;
        local rightX = ww - menuW - 12;

        if vnmPlugin then
            local vnmW = imgui.CalcTextSize('VNM') + 18;
            rightX = rightX - vnmW - 4;
        end

        -- Plugin top bar buttons (rendered left of VNM/Menu)
        local topBarButtons = trove_plugins.getTopBarButtons();
        for bi = #topBarButtons, 1, -1 do
            local btn = topBarButtons[bi];
            local btnW = imgui.CalcTextSize(btn.label) + 18;
            rightX = rightX - btnW - 4;
        end

        -- Render plugin top bar buttons
        local btnX = rightX;
        for _, btn in ipairs(topBarButtons) do
            local btnW = imgui.CalcTextSize(btn.label) + 18;
            imgui.SameLine(btnX);
            imgui.PushStyleColor(ImGuiCol_Button, { 0.15, 0.25, 0.35, 0.90 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.22, 0.35, 0.48, 0.95 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.30, 0.42, 0.58, 1.00 });
            if imgui.Button(btn.label .. '##trove_tb_' .. btn.label, { btnW, 22 }) then
                btn.action();
            end
            imgui.PopStyleColor(3);
            btnX = btnX + btnW + 4;
        end

        if vnmPlugin then
            local vnmW = imgui.CalcTextSize('VNM') + 18;
            imgui.SameLine(btnX);
            imgui.PushStyleColor(ImGuiCol_Button, { 0.35, 0.25, 0.10, 0.90 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.48, 0.35, 0.15, 0.95 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.55, 0.42, 0.20, 1.00 });
            imgui.PushStyleColor(ImGuiCol_Text, { 1.00, 0.85, 0.30, 1.00 });
            if imgui.Button('VNM##trove_vnm_alert', { vnmW, 22 }) then
                vnmPlugin.window.isOpen[1] = not vnmPlugin.window.isOpen[1];
            end
            imgui.PopStyleColor(4);
        end

        imgui.SameLine(ww - menuW - 12);
        imgui.PushStyleColor(ImGuiCol_Button, { 0.25, 0.18, 0.35, 0.90 });
        imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.35, 0.26, 0.48, 0.95 });
        imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.42, 0.34, 0.58, 1.00 });
        if imgui.Button('Menu##trove_menu', { menuW, 22 }) then
            imgui.OpenPopup('##trove_plugins_menu');
        end
        imgui.PopStyleColor(3);

        -- Left side: PF status strip OR job/level
        imgui.SameLine(8);
        imgui.SetCursorPosY(imgui.GetCursorPosY());
        local strips = trove_plugins.getStatusStrips();
        if #strips > 0 then
            local status = strips[1];
            local text;
            if status.partySize then
                text = string.format('%s: %s (%d/6) - %s',
                    status.typeStr or 'LFM', status.catName or '', status.partySize, status.countLabel or '');
            else
                text = string.format('%s: %s - %s',
                    status.typeStr or 'LFG', status.catName or '', status.countLabel or '');
            end
            -- Green dot
            local cx, cy = imgui.GetCursorScreenPos();
            dl:AddCircleFilled({ cx + 2, cy + 7 }, 3,
                imgui.GetColorU32({ 0.40, 0.90, 0.40, 1.0 }));
            imgui.SetCursorPosX(18);
            imgui.TextColored({ 0.60, 0.90, 0.60, 1.0 }, text);
        else
            -- Show job icon + job/level when not registered
            local ok, jobId, jobInfo = pcall(function()
                local p = AshitaCore:GetMemoryManager():GetPlayer();
                local jId = p:GetMainJob();
                local jobLv = p:GetMainJobLevel();
                local subId = p:GetSubJob();
                local subLv = p:GetSubJobLevel();
                local jobStr = (JOB_ABBR[jId] or '???') .. jobLv;
                if subId and subId > 0 then
                    jobStr = jobStr .. '/' .. (JOB_ABBR[subId] or '???') .. subLv;
                end
                return jId, jobStr;
            end);
            if ok and jobInfo then
                local iconItemId = JOB_ICON_ITEMS[jobId];
                if iconItemId then
                    renderIcon(iconItemId, 32);
                    imgui.SameLine(0, 6);
                end
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 8);
                imgui.TextColored({ 0.55, 0.55, 0.60, 1.0 }, jobInfo);
            end
        end

        -- Burger menu popup (categorised)
        if imgui.BeginPopup('##trove_plugins_menu') then
            local winPlugins = trove_plugins.getWindowPlugins();

            -- Group by category (reuse tables to avoid per-frame allocs)
            local byCategory = menuByCategory;
            local uncategorised = menuUncategorised;
            -- Clear reused tables
            for k, v in pairs(byCategory) do
                if type(v) == 'table' then
                    for i = #v, 1, -1 do v[i] = nil; end
                else
                    byCategory[k] = nil;
                end
            end
            for i = #uncategorised, 1, -1 do uncategorised[i] = nil; end

            for _, plugin in ipairs(winPlugins) do
                local cat = plugin.window.category;
                if cat then
                    byCategory[cat] = byCategory[cat] or {};
                    byCategory[cat][#byCategory[cat] + 1] = plugin;
                else
                    uncategorised[#uncategorised + 1] = plugin;
                end
            end

            -- Also gather menu-action plugins
            local menuEntries = trove_plugins.getMenuEntries();
            local renderedAny = false;

            -- Render uncategorised first (if any)
            for _, plugin in ipairs(uncategorised) do
                renderPluginEntry(plugin);
                renderedAny = true;
            end

            -- Render each category
            for _, catName in ipairs(MENU_CATEGORY_ORDER) do
                local plugins = byCategory[catName];
                if plugins and #plugins > 0 then
                    if renderedAny then imgui.Separator(); end
                    imgui.TextColored(COLORS.dimmed, catName);
                    for _, plugin in ipairs(plugins) do
                        renderPluginEntry(plugin);
                    end
                    renderedAny = true;
                end
            end

            -- Menu action entries (non-window plugins with menu items)
            local hasActions = false;
            for _, entry in ipairs(menuEntries) do
                hasActions = true; break;
            end
            if hasActions then
                imgui.Separator();
                for _, entry in ipairs(menuEntries) do
                    if imgui.Selectable(entry.label) then
                        entry.action(state);
                    end
                end
            end

            imgui.EndPopup();
        end

        if imgui.BeginTabBar('##trove_tabs', bit.bor(ImGuiTabBarFlags_FittingPolicyScroll, ImGuiTabBarFlags_TabListPopupButton)) then
            -- Priority plugin tabs (e.g. E.Box — rendered first)
            trove_plugins.renderPriorityTabs(state);

            -- Normal plugin tabs (Currency, Points, Crafting, Squire, etc.)
            trove_plugins.renderTabs(state);

            imgui.EndTabBar();
        end

        -- (Menu bar is above the tab bar now)
        if bgStylePushed > 0 then imgui.PopStyleColor(bgStylePushed); end
    end
    imgui.End();
    imgui.PopStyleColor(14);

    -- Render plugin floating windows
    trove_plugins.renderWindows();
end

------------------------------------------------------------
-- Commands
------------------------------------------------------------
ashita.events.register('command', 'trove_command', function(e)
    local args = e.command:args();
    if #args == 0 then return; end
    local cmd = args[1]:lower();

    if cmd ~= '/trove' then return; end
    e.blocked = true;

    if #args == 1 then
        ui.isOpen[1] = not ui.isOpen[1];
        return;
    end

    local sub = args[2]:lower();
    if sub == 'show' then
        ui.isOpen[1] = true;
        return;
    elseif sub == 'hide' then
        ui.isOpen[1] = false;
        return;
    elseif sub == 'refresh' then
        trove_plugins.invalidateAll();
        return;
    elseif sub == 'dump' and args[3] ~= nil then
        local id = tonumber(args[3]);
        if id == nil then
            print('[trove] usage: /trove dump <itemid>');
            return;
        end
        local res = getItemRes(id);
        if res == nil or res.Description == nil or res.Description[1] == nil then
            print(string.format('[trove] no description for item %d', id));
            return;
        end
        local raw = res.Description[1];
        print(string.format('[trove] item %d description (%d bytes):', id, #raw));
        local line = {};
        for i = 1, #raw do
            line[#line + 1] = string.format('%02X', raw:byte(i));
            if #line == 16 then
                print('  ' .. table.concat(line, ' '));
                line = {};
            end
        end
        if #line > 0 then print('  ' .. table.concat(line, ' ')); end
        return;
    end

    -- Dispatch to plugins
    if (trove_plugins.handleCommand(sub, state, args)) then return; end
end);

------------------------------------------------------------
-- Events
------------------------------------------------------------
ashita.events.register('d3d_present', 'trove_render', function()
    -- Install keybind on first frame (ensures Ashita chat manager is ready)
    if not ui.keybindDone then
        ui.keybindDone = true;
        AshitaCore:GetChatManager():QueueCommand(1, string.format('/bind %s /trove', KEYBIND));
        trove_plugins.load();
        initPlugins();
        state.isOpen = ui.isOpen;  -- expose to plugins for login auto-open
    end

    trove_plugins.onRender(state);
    renderWindow();
end);

ashita.events.register('unload', 'trove_unload', function()
    trove_plugins.unload();
    AshitaCore:GetChatManager():QueueCommand(1, string.format('/unbind %s', KEYBIND));

    -- Explicitly release all D3D textures (don't rely on GC)
    for id, tex in pairs(textureCache) do
        if tex and tex ~= false then releaseTexture(tex); end
    end
    for name, tex in pairs(fileTextures) do
        if tex and tex ~= false then releaseTexture(tex); end
    end

    textureCache   = {};
    fileTextures   = {};
    textureHandles = {};
    textureLRU     = {};

    -- Unregister all event callbacks to prevent closure leaks on reload
    ashita.events.unregister('d3d_present', 'trove_render');
    ashita.events.unregister('command', 'trove_command');
    ashita.events.unregister('packet_in', 'trove_packet_in');
    ashita.events.unregister('packet_in', 'trove_plugin_packets');
    print('[trove] Unloaded.');
end);

print(string.format('[trove] Loaded. /trove to toggle, also bound to %s.', KEYBIND));
