--[[
* frenslist - Persistent friend list with online-status tracking.
* SLOW variant (folder frenslistSLOW): the full-list sweep duration scales
* rate-limited to MAX_QPM queries per minute regardless of list size, so the
* sweep takes about #tasks * (60 / MAX_QPM) seconds. Addon name/file kept
* identical to frenslist on purpose.
* Author: CatsEyeXI
* Version: 1.0
--]]

addon.name    = 'frenslist';
addon.author  = 'Arielfy';
addon.version = '1.0';
addon.desc    = 'CatsEyeXI friend list';
addon.link    = ''

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
local socket   = require('socket');
local ffi      = require('ffi');
local d3d      = require('d3d8');

-- Load the search server client (Blowfish+MD5 TCP client).
-- Uses loadfile so addon.path resolves correctly at load time.
local sc = nil;
local _sc_ok, _sc_res = pcall(function()
    local loader = loadfile(addon.path .. 'lib/search_client.lua');
    if (loader) then return loader(); end
    return nil;
end);
if (_sc_ok and _sc_res) then
    sc = _sc_res;
else
    -- Non-fatal: search-based online detection is disabled, passive detection still works.
    sc = nil;
end

-- FFXI display-name lookup tables (zones, jobs, races, etc.)
local xi = nil;
local _xi_ok, _xi_res = pcall(function()
    return loadfile(addon.path .. 'lib/xi_data.lua')();
end);
if (_xi_ok and _xi_res) then xi = _xi_res; end

-- Texture helper: loads a PNG from img/ and stores a release-managed pointer.
local function _load_img_texture(filename)
    local out = nil;
    pcall(function()
        local C       = ffi.C;
        local d3d8dev = d3d.get_device();
        local tex_ptr = ffi.new('IDirect3DTexture8*[1]');
        local res = C.D3DXCreateTextureFromFileA(d3d8dev, addon.path .. 'img/' .. filename, tex_ptr);
        if (res == C.S_OK) then
            out = ffi.new('IDirect3DTexture8*', tex_ptr[0]);
            d3d.gc_safe_release(out);
        end
    end);
    return out;
end

local party_tex    = _load_img_texture('party_flag.png');     -- Flags column: in party
local away_tex     = _load_img_texture('away.png');           -- Flags column: AFK (takes priority)
local anon_tex     = _load_img_texture('anon.png');           -- Job column: anonymous (job hidden)
local delete_tex   = _load_img_texture('delete_button.png');  -- icon next to "Remove friend" in popup
local settings_tex = _load_img_texture('settings.png');       -- settings gear button
local info_tex     = _load_img_texture('info.png');           -- quick-reference help button
local jobs_tex     = _load_img_texture('jobs.png');           -- 22 job icons in a single horizontal row
local JOBS_COUNT = 22;

----------------------------------------------------------------------------------------------------
-- Color constants
--   Palette (window chrome): #20184A / #31305A / #364E78 / #97A0DF
--   Text colors (kept as-is per user request — high-contrast on the new palette).
----------------------------------------------------------------------------------------------------
local PAL_DARK    = { 0.192, 0.188, 0.353, 1.00 };  -- #31305A
local PAL_MID     = { 0.212, 0.306, 0.471, 1.00 };  -- #364E78
local PAL_LIGHT   = { 0.592, 0.627, 0.875, 1.00 };  -- #97A0DF

local COL_BG           = { 0.125, 0.094, 0.290, 0.95 };  -- DARKEST + slight transparency (window chrome)
local COL_LIST_BG      = { 0.071, 0.082, 0.149, 1.00 };  -- #121526 (friend table area)
local COL_TITLE_ACTIVE = PAL_DARK;
local COL_SCROLLBAR_BG = { 0.125, 0.094, 0.290, 0.80 };
local COL_BORDER       = { 0.212, 0.306, 0.471, 0.70 };  -- MID, slightly faded
local COL_FRAME_BG     = PAL_DARK;
local COL_FRAME_HOV    = PAL_MID;
local COL_ROW_SEL      = { 0.212, 0.306, 0.471, 0.80 };  -- MID
local COL_ROW_HOV      = { 0.592, 0.627, 0.875, 0.30 };  -- LIGHT translucent
local COL_BTN          = PAL_MID;
local COL_BTN_HOV      = { 0.592, 0.627, 0.875, 0.60 };  -- LIGHT, semi-opaque
local COL_BTN_ACT      = PAL_DARK;
local COL_SCROLL_GRAB  = PAL_LIGHT;
local COL_ACCENT       = { 1.000, 0.800, 0.200, 1.00 };  -- gold (text)
local COL_TEXT_MUTED   = { 0.700, 0.760, 0.900, 1.00 };  -- light periwinkle (text, contrast vs new BG)

-- Status bullet colors (rendered via imgui.Bullet() — no custom glyphs).
local COL_DOT_ONLINE   = { 0.200, 0.900, 0.300, 1.00 };  -- green: In Zone or Online
local COL_DOT_OFFLINE  = { 0.500, 0.500, 0.500, 1.00 };  -- gray:  Offline
local COL_DOT_UNKNOWN  = { 1.000, 0.800, 0.100, 1.00 };  -- yellow: Unknown

-- Sort priority: Online/In Zone → Away → Unknown → Offline.
-- Away is not a stored status; it is derived from flags1 at sort time.
local STATUS_ORDER = { Online = 1, ['In Zone'] = 1, Unknown = 3, Offline = 4 };



local function get_sort_priority(f)
    local p = STATUS_ORDER[f.status] or 3;
    if (p == 1 and f.flags1 ~= nil and bit.band(f.flags1, 0x0100) ~= 0) then
        return 2;  -- Away: online but flagged, sorts between Online and Unknown
    end
    return p;
end

----------------------------------------------------------------------------------------------------
-- Themeable color metadata. Each entry has the setting key, a display label, the category
-- shown in the settings panel, and the default RGBA used when the saved settings don't
-- already contain it. The settings panel uses this list to generate ColorEdit4 widgets.
----------------------------------------------------------------------------------------------------
local COLOR_KEYS = {
    -- Window chrome
    { key = 'bg',             label = 'Window Background',     cat = 'Window',   default = { 0.125, 0.094, 0.290, 0.95 } },
    { key = 'title',          label = 'Title Bar',             cat = 'Window',   default = { 0.192, 0.188, 0.353, 1.00 } },
    { key = 'border',         label = 'Border',                cat = 'Window',   default = { 0.212, 0.306, 0.471, 0.70 } },
    -- Table area
    { key = 'list_bg',        label = 'Table Background',      cat = 'Table',    default = { 0.071, 0.082, 0.149, 1.00 } },
    { key = 'row_sel',        label = 'Row Selected',          cat = 'Table',    default = { 0.212, 0.306, 0.471, 0.80 } },
    { key = 'row_hov',        label = 'Row Hover',             cat = 'Table',    default = { 0.592, 0.627, 0.875, 0.30 } },
    { key = 'scrollbar_bg',   label = 'Scrollbar Track',       cat = 'Table',    default = { 0.125, 0.094, 0.290, 0.80 } },
    { key = 'scrollbar_grab', label = 'Scrollbar Grip',        cat = 'Table',    default = { 0.592, 0.627, 0.875, 1.00 } },
    -- Controls
    { key = 'button',         label = 'Button',                cat = 'Controls', default = { 0.212, 0.306, 0.471, 1.00 } },
    { key = 'button_hov',     label = 'Button Hover',          cat = 'Controls', default = { 0.592, 0.627, 0.875, 0.60 } },
    { key = 'button_act',     label = 'Button Pressed',        cat = 'Controls', default = { 0.192, 0.188, 0.353, 1.00 } },
    { key = 'frame',          label = 'Input Field',           cat = 'Controls', default = { 0.192, 0.188, 0.353, 1.00 } },
    { key = 'frame_hov',      label = 'Input Field Hover',     cat = 'Controls', default = { 0.212, 0.306, 0.471, 1.00 } },
    -- Text
    { key = 'accent',         label = 'Headers & Max Warning', cat = 'Text',     default = { 1.000, 0.800, 0.200, 1.00 } },
    { key = 'text_muted',     label = 'Row Data & Counters',   cat = 'Text',     default = { 0.700, 0.760, 0.900, 1.00 } },
    -- Status dots
    { key = 'dot_online',     label = 'Status: Online',        cat = 'Status',   default = { 0.200, 0.900, 0.300, 1.00 } },
    { key = 'dot_offline',    label = 'Status: Offline',       cat = 'Status',   default = { 0.500, 0.500, 0.500, 1.00 } },
    { key = 'dot_unknown',    label = 'Status: Unknown',       cat = 'Status',   default = { 1.000, 0.800, 0.100, 1.00 } },
};

-- Named color presets. Each entry has: name, color (signature RGBA for the label), colors (key→RGBA).
-- Applying a preset mutates fl.settings.colors in-place so bind_colors() picks it up.
local COLOR_PRESETS = (function()
    local defaults = {};
    for _, e in ipairs(COLOR_KEYS) do
        defaults[e.key] = { e.default[1], e.default[2], e.default[3], e.default[4] };
    end
    return {
        -- FancyChat palette: dark charcoal bg, coral-red accent (CheckMark/SliderGrab color from its UI).
        { name = 'FancyChat', color = { 0.937, 0.349, 0.290, 1.00 }, colors = {
            bg             = { 0.100, 0.100, 0.100, 0.95 },
            title          = { 0.080, 0.080, 0.080, 1.00 },
            border         = { 0.937, 0.349, 0.290, 0.40 },
            list_bg        = { 0.050, 0.050, 0.050, 1.00 },
            row_sel        = { 0.937, 0.349, 0.290, 0.28 },
            row_hov        = { 0.937, 0.349, 0.290, 0.12 },
            scrollbar_bg   = { 0.000, 0.000, 0.000, 0.30 },
            scrollbar_grab = { 0.700, 0.700, 0.700, 0.50 },
            button         = { 0.400, 0.400, 0.400, 0.60 },
            button_hov     = { 0.700, 0.700, 0.700, 0.65 },
            button_act     = { 0.831, 0.329, 0.278, 1.00 },
            frame          = { 0.300, 0.300, 0.300, 0.60 },
            frame_hov      = { 0.400, 0.400, 0.400, 0.60 },
            accent         = { 0.937, 0.349, 0.290, 1.00 },
            text_muted     = { 0.800, 0.800, 0.800, 1.00 },
            dot_online     = { 0.200, 0.650, 0.300, 1.00 },
            dot_offline    = { 0.500, 0.500, 0.500, 1.00 },
            dot_unknown    = { 0.937, 0.749, 0.290, 1.00 },
        }},

        -- PartyFinder palette: near-black bg, gold accent, directly lifted from its ImGui style.
        { name = 'PartyFinder', color = { 1.000, 0.850, 0.400, 1.00 }, colors = {
            bg             = { 0.060, 0.060, 0.080, 0.96 },
            title          = { 0.050, 0.050, 0.070, 1.00 },
            border         = { 0.300, 0.300, 0.350, 0.50 },
            list_bg        = { 0.080, 0.080, 0.100, 1.00 },
            row_sel        = { 1.000, 0.850, 0.400, 0.25 },
            row_hov        = { 1.000, 0.850, 0.400, 0.10 },
            scrollbar_bg   = { 0.050, 0.050, 0.070, 0.80 },
            scrollbar_grab = { 0.300, 0.300, 0.350, 1.00 },
            button         = { 0.180, 0.180, 0.220, 1.00 },
            button_hov     = { 0.280, 0.280, 0.350, 1.00 },
            button_act     = { 0.350, 0.350, 0.420, 1.00 },
            frame          = { 0.120, 0.120, 0.150, 1.00 },
            frame_hov      = { 0.180, 0.180, 0.220, 1.00 },
            accent         = { 1.000, 0.850, 0.400, 1.00 },
            text_muted     = { 0.650, 0.750, 0.850, 1.00 },
            dot_online     = { 0.400, 1.000, 0.400, 1.00 },
            dot_offline    = { 0.500, 0.500, 0.500, 1.00 },
            dot_unknown    = { 0.900, 0.900, 0.300, 1.00 },
        }},

        { name = 'Default', color = { 0.592, 0.627, 0.875, 1.00 }, colors = defaults },

        -- Dracula-inspired: deep navy bg, pink accent, vivid status dots.
        { name = "Vampire's Den", color = { 1.000, 0.475, 0.776, 1.00 }, colors = {
            bg             = { 0.157, 0.165, 0.212, 0.95 },
            title          = { 0.129, 0.133, 0.173, 1.00 },
            border         = { 0.267, 0.278, 0.353, 0.70 },
            list_bg        = { 0.118, 0.122, 0.161, 1.00 },
            row_sel        = { 0.384, 0.447, 0.643, 0.45 },
            row_hov        = { 0.384, 0.447, 0.643, 0.20 },
            scrollbar_bg   = { 0.118, 0.122, 0.161, 0.80 },
            scrollbar_grab = { 0.267, 0.278, 0.353, 1.00 },
            button         = { 0.267, 0.278, 0.353, 1.00 },
            button_hov     = { 0.384, 0.447, 0.643, 0.70 },
            button_act     = { 0.129, 0.133, 0.173, 1.00 },
            frame          = { 0.129, 0.133, 0.173, 1.00 },
            frame_hov      = { 0.267, 0.278, 0.353, 1.00 },
            accent         = { 1.000, 0.475, 0.776, 1.00 },
            text_muted     = { 0.384, 0.447, 0.643, 1.00 },
            dot_online     = { 0.314, 0.980, 0.482, 1.00 },
            dot_offline    = { 0.267, 0.278, 0.353, 1.00 },
            dot_unknown    = { 0.945, 0.980, 0.549, 1.00 },
        }},

        -- Nord-inspired: cool arctic blues, frost cyan accent, muted naturals.
        { name = 'Arctic Fjord', color = { 0.533, 0.753, 0.816, 1.00 }, colors = {
            bg             = { 0.180, 0.204, 0.251, 0.95 },
            title          = { 0.133, 0.153, 0.188, 1.00 },
            border         = { 0.263, 0.298, 0.369, 0.70 },
            list_bg        = { 0.137, 0.157, 0.188, 1.00 },
            row_sel        = { 0.533, 0.753, 0.816, 0.35 },
            row_hov        = { 0.533, 0.753, 0.816, 0.15 },
            scrollbar_bg   = { 0.137, 0.157, 0.188, 0.80 },
            scrollbar_grab = { 0.263, 0.298, 0.369, 1.00 },
            button         = { 0.231, 0.259, 0.322, 1.00 },
            button_hov     = { 0.506, 0.631, 0.757, 0.65 },
            button_act     = { 0.137, 0.157, 0.188, 1.00 },
            frame          = { 0.137, 0.157, 0.188, 1.00 },
            frame_hov      = { 0.231, 0.259, 0.322, 1.00 },
            accent         = { 0.533, 0.753, 0.816, 1.00 },
            text_muted     = { 0.553, 0.616, 0.710, 1.00 },
            dot_online     = { 0.639, 0.745, 0.549, 1.00 },
            dot_offline    = { 0.298, 0.337, 0.416, 1.00 },
            dot_unknown    = { 0.922, 0.796, 0.545, 1.00 },
        }},

        -- Catppuccin Mocha-inspired: deep indigo bg, soft lavender accent, pastel dots.
        { name = 'Velvet Dusk', color = { 0.796, 0.651, 0.969, 1.00 }, colors = {
            bg             = { 0.118, 0.118, 0.180, 0.95 },
            title          = { 0.067, 0.067, 0.106, 1.00 },
            border         = { 0.271, 0.278, 0.353, 0.70 },
            list_bg        = { 0.094, 0.094, 0.145, 1.00 },
            row_sel        = { 0.796, 0.651, 0.969, 0.30 },
            row_hov        = { 0.796, 0.651, 0.969, 0.12 },
            scrollbar_bg   = { 0.094, 0.094, 0.145, 0.80 },
            scrollbar_grab = { 0.271, 0.278, 0.353, 1.00 },
            button         = { 0.192, 0.196, 0.267, 1.00 },
            button_hov     = { 0.796, 0.651, 0.969, 0.45 },
            button_act     = { 0.067, 0.067, 0.106, 1.00 },
            frame          = { 0.067, 0.067, 0.106, 1.00 },
            frame_hov      = { 0.192, 0.196, 0.267, 1.00 },
            accent         = { 0.796, 0.651, 0.969, 1.00 },
            text_muted     = { 0.651, 0.678, 0.784, 1.00 },
            dot_online     = { 0.651, 0.890, 0.631, 1.00 },
            dot_offline    = { 0.345, 0.357, 0.439, 1.00 },
            dot_unknown    = { 0.976, 0.886, 0.686, 1.00 },
        }},

        -- Tokyo Night-inspired: near-black bg, electric purple accent, neon status dots.
        { name = 'Neon Shogun', color = { 0.733, 0.604, 0.969, 1.00 }, colors = {
            bg             = { 0.102, 0.106, 0.149, 0.95 },
            title          = { 0.082, 0.086, 0.118, 1.00 },
            border         = { 0.231, 0.259, 0.380, 0.70 },
            list_bg        = { 0.075, 0.078, 0.110, 1.00 },
            row_sel        = { 0.478, 0.635, 0.969, 0.30 },
            row_hov        = { 0.478, 0.635, 0.969, 0.12 },
            scrollbar_bg   = { 0.075, 0.078, 0.110, 0.80 },
            scrollbar_grab = { 0.231, 0.259, 0.380, 1.00 },
            button         = { 0.141, 0.157, 0.231, 1.00 },
            button_hov     = { 0.478, 0.635, 0.969, 0.50 },
            button_act     = { 0.082, 0.086, 0.118, 1.00 },
            frame          = { 0.082, 0.086, 0.118, 1.00 },
            frame_hov      = { 0.141, 0.157, 0.231, 1.00 },
            accent         = { 0.733, 0.604, 0.969, 1.00 },
            text_muted     = { 0.604, 0.647, 0.808, 1.00 },
            dot_online     = { 0.620, 0.808, 0.416, 1.00 },
            dot_offline    = { 0.231, 0.259, 0.380, 1.00 },
            dot_unknown    = { 0.878, 0.686, 0.408, 1.00 },
        }},

        -- Gruvbox-inspired: warm charcoal bg, golden amber accent, earthy tones throughout.
        { name = 'Amber Forge', color = { 0.980, 0.741, 0.184, 1.00 }, colors = {
            bg             = { 0.157, 0.157, 0.157, 0.95 },
            title          = { 0.114, 0.125, 0.129, 1.00 },
            border         = { 0.314, 0.286, 0.271, 0.70 },
            list_bg        = { 0.114, 0.125, 0.129, 1.00 },
            row_sel        = { 0.980, 0.741, 0.184, 0.30 },
            row_hov        = { 0.980, 0.741, 0.184, 0.12 },
            scrollbar_bg   = { 0.114, 0.125, 0.129, 0.80 },
            scrollbar_grab = { 0.314, 0.286, 0.271, 1.00 },
            button         = { 0.235, 0.220, 0.212, 1.00 },
            button_hov     = { 0.980, 0.741, 0.184, 0.50 },
            button_act     = { 0.114, 0.125, 0.129, 1.00 },
            frame          = { 0.114, 0.125, 0.129, 1.00 },
            frame_hov      = { 0.235, 0.220, 0.212, 1.00 },
            accent         = { 0.980, 0.741, 0.184, 1.00 },
            text_muted     = { 0.659, 0.600, 0.518, 1.00 },
            dot_online     = { 0.722, 0.733, 0.149, 1.00 },
            dot_offline    = { 0.573, 0.514, 0.455, 1.00 },
            dot_unknown    = { 0.996, 0.502, 0.098, 1.00 },
        }},

        -- One Dark Pro-inspired: warm charcoal, cool blue accent, balanced warm/cool harmony.
        { name = 'Atom Drift', color = { 0.380, 0.686, 0.937, 1.00 }, colors = {
            bg             = { 0.157, 0.173, 0.204, 0.95 },
            title          = { 0.129, 0.145, 0.169, 1.00 },
            border         = { 0.329, 0.345, 0.384, 0.70 },
            list_bg        = { 0.114, 0.125, 0.149, 1.00 },
            row_sel        = { 0.380, 0.686, 0.937, 0.30 },
            row_hov        = { 0.380, 0.686, 0.937, 0.12 },
            scrollbar_bg   = { 0.114, 0.125, 0.149, 0.80 },
            scrollbar_grab = { 0.329, 0.345, 0.384, 1.00 },
            button         = { 0.208, 0.231, 0.271, 1.00 },
            button_hov     = { 0.380, 0.686, 0.937, 0.55 },
            button_act     = { 0.129, 0.145, 0.169, 1.00 },
            frame          = { 0.129, 0.145, 0.169, 1.00 },
            frame_hov      = { 0.208, 0.231, 0.271, 1.00 },
            accent         = { 0.380, 0.686, 0.937, 1.00 },
            text_muted     = { 0.671, 0.698, 0.749, 1.00 },
            dot_online     = { 0.596, 0.765, 0.475, 1.00 },
            dot_offline    = { 0.329, 0.345, 0.384, 1.00 },
            dot_unknown    = { 0.898, 0.753, 0.482, 1.00 },
        }},

        -- IBM Carbon-inspired: near-black neutrals, saturated blue accent, enterprise precision.
        { name = 'Iron Circuit', color = { 0.059, 0.384, 0.996, 1.00 }, colors = {
            bg             = { 0.086, 0.086, 0.086, 0.95 },
            title          = { 0.051, 0.051, 0.051, 1.00 },
            border         = { 0.322, 0.322, 0.322, 0.50 },
            list_bg        = { 0.051, 0.051, 0.051, 1.00 },
            row_sel        = { 0.059, 0.384, 0.996, 0.28 },
            row_hov        = { 0.059, 0.384, 0.996, 0.10 },
            scrollbar_bg   = { 0.051, 0.051, 0.051, 0.80 },
            scrollbar_grab = { 0.322, 0.322, 0.322, 1.00 },
            button         = { 0.149, 0.149, 0.149, 1.00 },
            button_hov     = { 0.059, 0.384, 0.996, 0.50 },
            button_act     = { 0.051, 0.051, 0.051, 1.00 },
            frame          = { 0.051, 0.051, 0.051, 1.00 },
            frame_hov      = { 0.149, 0.149, 0.149, 1.00 },
            accent         = { 0.059, 0.384, 0.996, 1.00 },
            text_muted     = { 0.776, 0.776, 0.776, 1.00 },
            dot_online     = { 0.141, 0.631, 0.282, 1.00 },
            dot_offline    = { 0.322, 0.322, 0.322, 1.00 },
            dot_unknown    = { 0.945, 0.761, 0.106, 1.00 },
        }},

        -- GitHub Dark-inspired: deep near-black, bright cyan-blue accent, high-chroma pop.
        { name = 'Dark Protocol', color = { 0.345, 0.651, 1.000, 1.00 }, colors = {
            bg             = { 0.051, 0.067, 0.090, 0.95 },
            title          = { 0.035, 0.047, 0.067, 1.00 },
            border         = { 0.188, 0.212, 0.239, 0.70 },
            list_bg        = { 0.035, 0.047, 0.067, 1.00 },
            row_sel        = { 0.345, 0.651, 1.000, 0.25 },
            row_hov        = { 0.345, 0.651, 1.000, 0.10 },
            scrollbar_bg   = { 0.035, 0.047, 0.067, 0.80 },
            scrollbar_grab = { 0.188, 0.212, 0.239, 1.00 },
            button         = { 0.129, 0.149, 0.176, 1.00 },
            button_hov     = { 0.345, 0.651, 1.000, 0.45 },
            button_act     = { 0.035, 0.047, 0.067, 1.00 },
            frame          = { 0.035, 0.047, 0.067, 1.00 },
            frame_hov      = { 0.129, 0.149, 0.176, 1.00 },
            accent         = { 0.345, 0.651, 1.000, 1.00 },
            text_muted     = { 0.545, 0.580, 0.620, 1.00 },
            dot_online     = { 0.247, 0.725, 0.314, 1.00 },
            dot_offline    = { 0.188, 0.212, 0.239, 1.00 },
            dot_unknown    = { 1.000, 0.651, 0.341, 1.00 },
        }},

        -- Everforest-inspired: warm forest greens, soft sage accent, earthy tranquility.
        { name = 'Verdant Vale', color = { 0.655, 0.753, 0.502, 1.00 }, colors = {
            bg             = { 0.176, 0.208, 0.231, 0.95 },
            title          = { 0.137, 0.165, 0.180, 1.00 },
            border         = { 0.239, 0.282, 0.255, 0.70 },
            list_bg        = { 0.137, 0.165, 0.180, 1.00 },
            row_sel        = { 0.655, 0.753, 0.502, 0.30 },
            row_hov        = { 0.655, 0.753, 0.502, 0.12 },
            scrollbar_bg   = { 0.137, 0.165, 0.180, 0.80 },
            scrollbar_grab = { 0.239, 0.282, 0.255, 1.00 },
            button         = { 0.239, 0.282, 0.255, 1.00 },
            button_hov     = { 0.655, 0.753, 0.502, 0.55 },
            button_act     = { 0.137, 0.165, 0.180, 1.00 },
            frame          = { 0.137, 0.165, 0.180, 1.00 },
            frame_hov      = { 0.239, 0.282, 0.255, 1.00 },
            accent         = { 0.655, 0.753, 0.502, 1.00 },
            text_muted     = { 0.616, 0.663, 0.627, 1.00 },
            dot_online     = { 0.655, 0.753, 0.502, 1.00 },
            dot_offline    = { 0.329, 0.373, 0.353, 1.00 },
            dot_unknown    = { 0.859, 0.737, 0.498, 1.00 },
        }},

        -- Rosé Pine-inspired: deep plum bg, blush rose accent, warm mauve tones throughout.
        { name = 'Petal Shroud', color = { 0.922, 0.737, 0.729, 1.00 }, colors = {
            bg             = { 0.098, 0.090, 0.141, 0.95 },
            title          = { 0.067, 0.059, 0.110, 1.00 },
            border         = { 0.251, 0.239, 0.322, 0.70 },
            list_bg        = { 0.067, 0.059, 0.110, 1.00 },
            row_sel        = { 0.922, 0.737, 0.729, 0.25 },
            row_hov        = { 0.922, 0.737, 0.729, 0.10 },
            scrollbar_bg   = { 0.067, 0.059, 0.110, 0.80 },
            scrollbar_grab = { 0.251, 0.239, 0.322, 1.00 },
            button         = { 0.149, 0.137, 0.227, 1.00 },
            button_hov     = { 0.922, 0.737, 0.729, 0.35 },
            button_act     = { 0.067, 0.059, 0.110, 1.00 },
            frame          = { 0.067, 0.059, 0.110, 1.00 },
            frame_hov      = { 0.149, 0.137, 0.227, 1.00 },
            accent         = { 0.922, 0.737, 0.729, 1.00 },
            text_muted     = { 0.565, 0.549, 0.667, 1.00 },
            dot_online     = { 0.612, 0.812, 0.847, 1.00 },
            dot_offline    = { 0.251, 0.239, 0.322, 1.00 },
            dot_unknown    = { 0.965, 0.757, 0.467, 1.00 },
        }},
    };
end)();

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------
local default_settings = T{
    is_open  = true;
    friends  = T{};
    window_x = 100;
    window_y = 100;
    mini_x   = 100;  -- FL button position is tracked independently from the main window
    mini_y   = 100;

    -- Notifications when a friend's online/offline state flips.
    notify_online      = true;   -- ping when a friend goes offline → online
    notify_offline     = true;   -- ping when a friend goes online → offline

    -- FL-button hover tooltip counts.
    show_unknown_count = true;   -- show the yellow (unknown) counter in the tooltip
    show_offline_count = true;   -- show the gray (offline) counter in the tooltip

    -- Themed colors (populated lazily by ensure_settings if missing).
    colors = T{};

};

----------------------------------------------------------------------------------------------------
-- Runtime state
----------------------------------------------------------------------------------------------------
local fl = T{
    settings         = settings.load(default_settings);
    selected_idx     = 0;
    preset_idx       = { 0 };  -- 0-based index into COLOR_PRESETS for the combo
    add_buf          = { '' };
    win_open         = { true };
    first_frame      = true;
    mini_first_frame = true;
    show_settings    = false;  -- toggled by the gear button in the bottom bar
    my_zone          = 0;      -- zone ID at time packet 0x000A was received (pre-zone snapshot)
    zone_check_until = 0;     -- os.clock() deadline: poll GetMemberZone(0) until zone changes or timeout

    -- Packet capture (one-shot diagnostic tool — /fl capture)
    capture_mode  = false;
    capture_until = 0;

    -- Search server query queue + automatic refresh cycle (SLOW variant).
    -- A "cycle" = one full sweep through every friend in the list. Pacing is
    -- rate-based, not size-based: dispatches are spaced query_spacing() apart
    -- so the query rate never exceeds MAX_QPM regardless of list size. Sweep
    -- duration (= each friend's refresh period) is whatever results, roughly
    -- #tasks * query_spacing().
    search_queue    = {};  -- array of pending tasks { prefix, members = {names} }
    cycle_tasks     = 0;   -- task count of the current cycle (informational)
    active_search   = nil; -- in-flight async search handle (sc.new_search), or nil
    -- Scheduler clock: os.clock(), not os.time(). On Windows os.clock() is
    -- wall-clock seconds since process start with ~1ms resolution, so sub-second
    -- dispatch spacing is honoured exactly instead of rounding up to whole
    -- seconds. It is also immune to system-clock adjustments. These four values
    -- are only ever compared against each other and are never persisted.
    last_search_at  = 0;   -- os.clock() when the last search was dispatched
    cycle_start_at  = 0;   -- os.clock() when the current cycle's first query fired (0 = idle)
    next_cycle_at   = 0;   -- os.clock() when the next cycle is allowed to start
    SEARCH_TIMEOUT  = 0.5; -- max seconds to wait for a search response (async deadline)
    MAX_QPM         = 30;  -- hard ceiling on search queries per minute
    POST_CYCLE_GAP  = 1;   -- min seconds between last query and next cycle start

    MAX_FRIENDS     = 30;  -- hard cap on friend list size

    -- Left-click /tell: name waiting for the chat input to open, and an
    -- os.clock() deadline to disarm if it never does.
    tell_pending = nil;
    tell_until   = 0;

    -- Previous frame's is_r0_active() value; starts true so the first login
    -- also runs the came-back-from-a-gap reset (harmlessly, on Unknowns).
    r0_was_active = true;
};

----------------------------------------------------------------------------------------------------
-- Fill in any missing settings entries with their defaults. Safe to call repeatedly.
----------------------------------------------------------------------------------------------------
local function ensure_settings()
    if (fl.settings.colors == nil) then fl.settings.colors = T{}; end
    for _, e in ipairs(COLOR_KEYS) do
        if (fl.settings.colors[e.key] == nil) then
            fl.settings.colors[e.key] = T{ e.default[1], e.default[2], e.default[3], e.default[4] };
        end
    end
    if (fl.settings.notify_online      == nil) then fl.settings.notify_online      = true;  end
    if (fl.settings.notify_offline     == nil) then fl.settings.notify_offline     = true;  end
    if (fl.settings.show_unknown_count == nil) then fl.settings.show_unknown_count = true;  end
    if (fl.settings.show_offline_count == nil) then fl.settings.show_offline_count = true;  end
    if (fl.settings.last_preset        == nil) then fl.settings.last_preset        = '';    end
end

local function restore_preset_idx()
    local name = fl.settings.last_preset;
    if (name and name ~= '') then
        for j, p in ipairs(COLOR_PRESETS) do
            if (p.name == name) then fl.preset_idx[1] = j - 1; return; end
        end
    end
    fl.preset_idx[1] = 0;
end

----------------------------------------------------------------------------------------------------
-- Re-aim the file-local COL_* references at the settings color tables. Because tables in
-- Lua are passed by reference, mutating a color via ColorEdit4 inside the settings panel
-- will instantly affect every render that reads from these COL_* names.
----------------------------------------------------------------------------------------------------
local function bind_colors()
    local c = fl.settings.colors;
    COL_BG           = c.bg             or COL_BG;
    COL_LIST_BG      = c.list_bg        or COL_LIST_BG;
    COL_TITLE_ACTIVE = c.title          or COL_TITLE_ACTIVE;
    COL_SCROLLBAR_BG = c.scrollbar_bg   or COL_SCROLLBAR_BG;
    COL_BORDER       = c.border         or COL_BORDER;
    COL_FRAME_BG     = c.frame          or COL_FRAME_BG;
    COL_FRAME_HOV    = c.frame_hov      or COL_FRAME_HOV;
    COL_ROW_SEL      = c.row_sel        or COL_ROW_SEL;
    COL_ROW_HOV      = c.row_hov        or COL_ROW_HOV;
    COL_BTN          = c.button         or COL_BTN;
    COL_BTN_HOV      = c.button_hov     or COL_BTN_HOV;
    COL_BTN_ACT      = c.button_act     or COL_BTN_ACT;
    COL_SCROLL_GRAB  = c.scrollbar_grab or COL_SCROLL_GRAB;
    COL_ACCENT       = c.accent         or COL_ACCENT;
    COL_TEXT_MUTED   = c.text_muted     or COL_TEXT_MUTED;
    COL_DOT_ONLINE   = c.dot_online     or COL_DOT_ONLINE;
    COL_DOT_OFFLINE  = c.dot_offline    or COL_DOT_OFFLINE;
    COL_DOT_UNKNOWN  = c.dot_unknown    or COL_DOT_UNKNOWN;
end

ensure_settings();
bind_colors();

----------------------------------------------------------------------------------------------------
-- Settings callback (handles character switches)
----------------------------------------------------------------------------------------------------
settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then
        fl.settings     = s;
        fl.selected_idx = 0;
        fl.add_buf[1]   = '';
        fl.win_open[1]  = fl.settings.is_open;
        ensure_settings();
        bind_colors();
        restore_preset_idx();
    end
    settings.save();
end);

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------
local function normalize_name(name)
    if (name == nil or name == '') then return nil; end
    return name:sub(1, 1):upper() .. name:sub(2):lower();
end

-- Apply a new status to a friend record and fire a chat notification on a real
-- online↔offline transition. "Unknown" is treated as a non-transition (used for the
-- initial-load reset), so going Unknown→Online or Offline→Unknown stays silent.
local function set_status(f, new_status)
    if (f == nil) then return; end
    if (sc ~= nil and sc.is_rsv ~= nil and sc.is_rsv(f.name)) then
        new_status = 'Offline';
        f.flags1 = nil; f.zone   = nil;
        f.mjob   = nil; f.sjob   = nil;
        f.mlvl   = nil; f.slvl   = nil;
        f.race   = nil; f.nation = nil; f.rank = nil;
    end
    local prev = f.status;
    if (prev == new_status) then return; end
    f.status = new_status;

    if (new_status == 'Offline' or new_status == 'Unknown') then
        f.flags1 = nil; f.zone = nil;
        f.mjob   = nil; f.sjob = nil;
        f.mlvl   = nil; f.slvl = nil;
    end

    if (prev == 'Unknown' or new_status == 'Unknown') then return; end

    local was_online = (prev == 'Online' or prev == 'In Zone');
    local is_online  = (new_status == 'Online' or new_status == 'In Zone');
    if (was_online == is_online) then return; end  -- e.g. Online ↔ In Zone

    if (is_online and fl.settings.notify_online) then
        print(chat.header('FrensList'):append(chat.message(f.name .. ' is now online.')));
    elseif (not is_online and fl.settings.notify_offline) then
        print(chat.header('FrensList'):append(chat.message(f.name .. ' is now offline.')));
    end
end

local function find_friend(name)
    local n = normalize_name(name);
    if (n == nil) then return nil, nil; end
    for i, f in ipairs(fl.settings.friends) do
        if (f.name == n) then
            return i, f;
        end
    end
    return nil, nil;
end

-- Minimum seconds between two dispatches. This is the ONE thing that governs
-- pacing: queries go out at a fixed rate, so the addon can never exceed
-- MAX_QPM per minute no matter how many friends are on the list. The sweep
-- duration (and hence each friend's refresh period) is whatever falls out of
-- it: roughly #tasks * query_spacing.
local function query_spacing()
    return 60 / math.max(1, fl.MAX_QPM);
end

----------------------------------------------------------------------------------------------------
-- Query batching.
-- The server filters by name prefix, so friends whose names share their first
-- two letters can be resolved by ONE query instead of one each. Build the
-- cycle's task list accordingly: shared 2-letter prefix -> grouped task,
-- otherwise a full-name task (identical to the old per-friend behaviour).
-- Each task = { prefix = <string sent to the server>, members = { names } }.
----------------------------------------------------------------------------------------------------
local function build_cycle_tasks()
    local groups, order = {}, {};
    for _, fri in ipairs(fl.settings.friends) do
        local key = fri.name:sub(1, 2):lower();
        if (groups[key] == nil) then
            groups[key] = {};
            order[#order + 1] = key;
        end
        local g = groups[key];
        g[#g + 1] = fri.name;
    end

    local tasks = {};
    for _, key in ipairs(order) do
        local members = groups[key];
        -- Group query uses the first member's capitalisation (names are
        -- normalised to Xxxx, so any member yields the same two letters).
        local prefix = (#members > 1) and members[1]:sub(1, 2) or members[1];
        tasks[#tasks + 1] = { prefix = prefix, members = members };
    end
    return tasks;
end

-- Write one search entry onto a friend record. A nil entry means the player was
-- not in the response, i.e. offline.
local function apply_entry(f, entry, my_zone)
    if (f == nil) then return; end
    if (entry == nil or sc == nil or sc.is_rsv(f.name)) then
        set_status(f, 'Offline');
        return;
    end
    set_status(f, entry.zone == my_zone and 'In Zone' or 'Online');
    f.zone   = entry.zone;
    f.mjob   = entry.mjob;
    f.sjob   = entry.sjob;
    f.mlvl   = entry.mlvl;
    f.slvl   = entry.slvl;
    f.race   = entry.race;
    f.nation = entry.nation;
    f.rank   = entry.rank;
    f.flags1 = entry.flags1;
end

----------------------------------------------------------------------------------------------------
-- R0 (server connection lost / not yet zoned in) detection — ported from fancychat.
-- When the client is connected and in-game, this memory location holds the current
-- zone ID; during an R0, or while the player is sitting at the title/select screen,
-- the engine zeroes it. We use that as a "no point talking to the search server right
-- now" signal and silently skip refresh cycles until it comes back.
----------------------------------------------------------------------------------------------------
-- Only the static pointer-variable address and field offset are cached; the
-- object pointer itself MUST be re-read on every check. The game recreates the
-- object across logout/login, so a one-shot snapshot (the old approach) goes
-- stale after the first relog and reads 0 forever — permanently suspending the
-- refresh cycle while the previous session's statuses stay on screen.
local r0_obj_ptr_addr = 0;  -- static address holding the game's object pointer
local r0_offset       = 0;  -- offset of the now-zone field within that object

local function init_r0_ptr()
    pcall(function()
        local patternAddr = ashita.memory.find('FFxiMain.dll', 0, '8935????????81C6????????56E8', 0, 0);
        if (patternAddr == nil or patternAddr == 0) then return; end
        r0_obj_ptr_addr = ashita.memory.read_uint32(patternAddr + 0x02);
        r0_offset       = ashita.memory.read_uint32(patternAddr + 0x08);
    end);
end

local function is_r0_active()
    if (r0_obj_ptr_addr == 0) then return false; end  -- pattern scan failed — fail open
    local ok, val = pcall(function()
        local obj = ashita.memory.read_uint32(r0_obj_ptr_addr);
        if (obj == 0) then return 0; end  -- object not created (title / char select)
        return ashita.memory.read_uint32(obj + r0_offset);
    end);
    if (not ok) then return false; end
    return val == 0;
end

local function add_friend(name)
    local n = normalize_name(name);
    if (n == nil) then return false, 'Invalid name.'; end
    if (n:match('[^%a]')) then return false, ('Invalid name "%s": names may only contain letters.'):format(n); end

    -- Reject the player's own character (party slot 0 = self).
    local self_name = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    if (self_name ~= nil and self_name ~= '' and normalize_name(self_name) == n) then
        return false, "Can't add your own character to the friend list.";
    end

    if (#fl.settings.friends >= fl.MAX_FRIENDS) then
        return false, ('Friend list is full (%d/%d). Remove someone first.'):format(
            #fl.settings.friends, fl.MAX_FRIENDS);
    end
    local i, _ = find_friend(n);
    if (i) then return false, (n .. ' is already on your friend list.'); end
    fl.settings.friends:append({ name = n, status = 'Unknown' });
    -- Queue an immediate search for this new friend (pushed to front so it's next)
    if (sc ~= nil) then
        table.insert(fl.search_queue, 1, { prefix = n, members = { n } });
    end
    settings.save();
    return true, ('Added: ' .. n .. ' to the friend list. Make sure the name is correct.');
end

local function remove_friend(name)
    local n = normalize_name(name);
    if (n == nil) then return false, 'Invalid name.'; end
    local i, _ = find_friend(n);
    if (not i) then return false, (n .. ' is not on your friend list.'); end
    fl.settings.friends:remove(i);
    if (fl.selected_idx >= i) then
        fl.selected_idx = math.max(0, fl.selected_idx - 1);
    end
    settings.save();
    return true, ('Removed friend: ' .. n .. ' from the friend list.');
end

local function get_dot_color(f)
    if (f.status == 'In Zone' or f.status == 'Online') then
        if (f.flags1 ~= nil and bit.band(f.flags1, 0x0100) ~= 0) then
            return COL_DOT_UNKNOWN;  -- Away: yellow bullet even though online
        end
        return COL_DOT_ONLINE;
    elseif (f.status == 'Offline') then return COL_DOT_OFFLINE;
    else                                return COL_DOT_UNKNOWN;
    end
end


local function print_help(is_error)
    if (is_error) then
        print(chat.header('FrensList'):append(chat.error('Invalid syntax for command: ')):append(chat.success('/fl')));
    else
        print(chat.header('FrensList'):append(chat.message('Available commands:')));
    end
    local cmds = T{
        { '/fl add <name>',    'Add a player to your friend list.' },
        { '/fl remove <name>', 'Remove a player. (aliases: del, rm)' },
        { '/fl help',          'Show this help.' },
    };
    cmds:ieach(function (v)
        print(chat.header('FrensList'):append(chat.error('  ')):append(chat.message(v[1])):append(' - '):append(chat.color1(6, v[2])));
    end);
end

----------------------------------------------------------------------------------------------------
-- ImGui rendering
----------------------------------------------------------------------------------------------------
-- Tiny "FL" relauncher window shown after the user clicks the main window's X.
-- Lives at its OWN saved position (mini_x / mini_y) — independent from the main
-- window so dragging one never moves the other.
local function render_mini_button()
    imgui.PushStyleColor(ImGuiCol_WindowBg,      COL_BG);
    imgui.PushStyleColor(ImGuiCol_Border,        COL_BORDER);
    imgui.PushStyleColor(ImGuiCol_Button,        COL_BTN);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, COL_BTN_HOV);
    imgui.PushStyleColor(ImGuiCol_ButtonActive,  COL_BTN_ACT);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding,  4.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding,  { 6.0, 6.0 });

    if (fl.mini_first_frame) then
        imgui.SetNextWindowPos({ fl.settings.mini_x, fl.settings.mini_y }, ImGuiCond_Always);
        fl.mini_first_frame = false;
    end

    -- Match the flag-set used by fancychat's zone-search popup, which renders
    -- with no title bar in this same ImGui binding.
    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_AlwaysAutoResize);

    -- Pass `true` (not nil) as p_open so Ashita's binding routes the third arg
    -- correctly into the flags slot.
    if (imgui.Begin('##fl_mini', true, flags)) then
        -- Save the mini-button's own position; do NOT touch window_x/y.
        local mx, my = imgui.GetWindowPos();
        fl.settings.mini_x = mx;
        fl.settings.mini_y = my;

        local clicked = imgui.Button('FL', { 30, 22 });

        -- Hover tooltip: colored bullets and counts of online / unknown / offline friends.
        -- The unknown and offline counters are individually toggleable via the settings panel.
        if (imgui.IsItemHovered()) then
            local on, unk, off = 0, 0, 0;
            for _, f in ipairs(fl.settings.friends) do
                if (f.status == 'Online' or f.status == 'In Zone') then on  = on  + 1;
                elseif (f.status == 'Unknown')                        then unk = unk + 1;
                else                                                       off = off + 1;
                end
            end
            imgui.BeginTooltip();
                imgui.PushStyleColor(ImGuiCol_Text, COL_DOT_ONLINE);
                imgui.Bullet();
                imgui.PopStyleColor(1);
                imgui.SameLine();
                imgui.Text(tostring(on) .. ' ');  -- extra trailing space before the next bullet
                if (fl.settings.show_unknown_count) then
                    imgui.SameLine();
                    imgui.PushStyleColor(ImGuiCol_Text, COL_DOT_UNKNOWN);
                    imgui.Bullet();
                    imgui.PopStyleColor(1);
                    imgui.SameLine();
                    imgui.Text(tostring(unk) .. ' ');
                end
                if (fl.settings.show_offline_count) then
                    imgui.SameLine();
                    imgui.PushStyleColor(ImGuiCol_Text, COL_DOT_OFFLINE);
                    imgui.Bullet();
                    imgui.PopStyleColor(1);
                    imgui.SameLine();
                    imgui.Text(tostring(off));
                end
            imgui.EndTooltip();
        end

        if (clicked) then
            fl.settings.is_open  = true;
            fl.win_open[1]       = true;
            fl.first_frame       = true;  -- main window repositions on its next render
            settings.save();
        end
    end
    imgui.End();

    imgui.PopStyleVar(3);
    imgui.PopStyleColor(5);
end

-- Settings panel: notifications, FL-button tooltip toggles, and a full color palette.
local function render_settings_window()
    imgui.PushStyleColor(ImGuiCol_WindowBg,         COL_BG);
    imgui.PushStyleColor(ImGuiCol_TitleBg,          COL_TITLE_ACTIVE);
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,    COL_TITLE_ACTIVE);
    imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed, COL_TITLE_ACTIVE);
    imgui.PushStyleColor(ImGuiCol_Border,           COL_BORDER);
    imgui.PushStyleColor(ImGuiCol_FrameBg,          COL_FRAME_BG);
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered,   COL_FRAME_HOV);
    imgui.PushStyleColor(ImGuiCol_Header,           COL_ROW_SEL);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered,    COL_ROW_HOV);
    imgui.PushStyleColor(ImGuiCol_HeaderActive,     COL_ROW_SEL);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding,  { 10.0, 8.0 });

    imgui.SetNextWindowSize({ 380, 520 }, ImGuiCond_FirstUseEver);

    local sflags   = ImGuiWindowFlags_NoCollapse;
    local open_ref = { true };
    if (imgui.Begin('FrensList Settings', open_ref, sflags)) then

        -- ---- Notifications ----
        imgui.PushStyleColor(ImGuiCol_Text, COL_ACCENT);
        imgui.Text('Notifications');
        imgui.PopStyleColor(1);
        imgui.Separator();

        local n_on = { fl.settings.notify_online };
        if (imgui.Checkbox('Notify when a friend comes online', n_on)) then
            fl.settings.notify_online = n_on[1];
            settings.save();
        end
        local n_off = { fl.settings.notify_offline };
        if (imgui.Checkbox('Notify when a friend goes offline', n_off)) then
            fl.settings.notify_offline = n_off[1];
            settings.save();
        end

        imgui.Spacing();

        -- ---- FL button tooltip ----
        imgui.PushStyleColor(ImGuiCol_Text, COL_ACCENT);
        imgui.Text('FL Button Tooltip');
        imgui.PopStyleColor(1);
        imgui.Separator();

        local s_unk = { fl.settings.show_unknown_count };
        if (imgui.Checkbox('Show unknown (yellow) count', s_unk)) then
            fl.settings.show_unknown_count = s_unk[1];
            settings.save();
        end
        local s_off = { fl.settings.show_offline_count };
        if (imgui.Checkbox('Show offline (gray) count', s_off)) then
            fl.settings.show_offline_count = s_off[1];
            settings.save();
        end

        imgui.Spacing();

        -- ---- Color Presets ----
        imgui.PushStyleColor(ImGuiCol_Text, COL_ACCENT);
        imgui.Text('Color Presets');
        imgui.PopStyleColor(1);
        imgui.Separator();
        imgui.Spacing();

        local sel = COLOR_PRESETS[fl.preset_idx[1] + 1];
        imgui.PushItemWidth(-1);
        imgui.PushStyleColor(ImGuiCol_Text, sel and sel.color or { 1, 1, 1, 1 });
        local combo_open = imgui.BeginCombo('##preset', sel and sel.name or '');
        imgui.PopStyleColor(1);
        if (combo_open) then
            for j, preset in ipairs(COLOR_PRESETS) do
                local is_sel = (fl.preset_idx[1] == j - 1);
                imgui.PushStyleColor(ImGuiCol_Text, preset.color);
                if (imgui.Selectable(preset.name, is_sel)) then
                    fl.preset_idx[1] = j - 1;
                    for _, e in ipairs(COLOR_KEYS) do
                        local src = preset.colors[e.key];
                        local dst = fl.settings.colors[e.key];
                        dst[1] = src[1]; dst[2] = src[2]; dst[3] = src[3]; dst[4] = src[4];
                    end
                    fl.settings.last_preset = preset.name;
                    bind_colors();
                    settings.save();
                end
                imgui.PopStyleColor(1);
                if (is_sel) then imgui.SetItemDefaultFocus(); end
            end
            imgui.EndCombo();
        end
        imgui.PopItemWidth();

        imgui.Spacing();

        -- ---- Customize Colors ----
        imgui.PushStyleColor(ImGuiCol_Text, COL_ACCENT);
        imgui.Text('Customize Colors');
        imgui.PopStyleColor(1);
        imgui.Separator();

        local current_cat = nil;
        for _, e in ipairs(COLOR_KEYS) do
            if (e.cat ~= current_cat) then
                current_cat = e.cat;
                imgui.Spacing();
                imgui.TextColored(COL_TEXT_MUTED, e.cat);
            end
            local arr = fl.settings.colors[e.key];
            if (imgui.ColorEdit4(e.label .. '##' .. e.key, arr, ImGuiColorEditFlags_NoInputs)) then
                -- The ColorEdit4 mutated the table in place; mirror it onto the COL_*
                -- shortcut so the rest of the UI picks it up this frame.
                bind_colors();
                settings.save();
            end
        end
    end
    imgui.End();
    if (not open_ref[1]) then
        fl.show_settings = false;
    end

    imgui.PopStyleVar(2);
    imgui.PopStyleColor(10);
end

local function render_window()
    if (not fl.settings.is_open) then
        render_mini_button();
        return;
    end

    if (fl.show_settings) then
        render_settings_window();
    end

    -- Push window style (15 colors + 4 vars — counts must be exact)
    -- All three title-bar states share the same color so collapsing or losing focus
    -- doesn't recolor the bar.
    imgui.PushStyleColor(ImGuiCol_WindowBg,          COL_BG);
    imgui.PushStyleColor(ImGuiCol_TitleBg,           COL_TITLE_ACTIVE);
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,     COL_TITLE_ACTIVE);
    imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed,  COL_TITLE_ACTIVE);
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg,       COL_SCROLLBAR_BG);
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab,  COL_SCROLL_GRAB);
    imgui.PushStyleColor(ImGuiCol_Border,         COL_BORDER);
    imgui.PushStyleColor(ImGuiCol_Button,         COL_BTN);
    imgui.PushStyleColor(ImGuiCol_ButtonHovered,  COL_BTN_HOV);
    imgui.PushStyleColor(ImGuiCol_ButtonActive,   COL_BTN_ACT);
    imgui.PushStyleColor(ImGuiCol_FrameBg,        COL_FRAME_BG);
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered, COL_FRAME_HOV);
    imgui.PushStyleColor(ImGuiCol_Header,         COL_ROW_SEL);
    imgui.PushStyleColor(ImGuiCol_HeaderHovered,  COL_ROW_HOV);
    imgui.PushStyleColor(ImGuiCol_HeaderActive,   COL_ROW_SEL);

    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 6.0);
    imgui.PushStyleVar(ImGuiStyleVar_FrameRounding,  4.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding,  { 10.0, 8.0 });
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing,    { 8.0, 7.0 });

    -- Restore saved position on first frame after load
    if (fl.first_frame) then
        imgui.SetNextWindowPos({ fl.settings.window_x, fl.settings.window_y }, ImGuiCond_Always);
        fl.first_frame = false;
    end
    imgui.SetNextWindowSize({ 560, 420 }, ImGuiCond_FirstUseEver);

    local flags = bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse);

    if (imgui.Begin('CatsEyeXI - FrensList', fl.win_open, flags)) then

        -- Save window position every frame so it persists
        local wx, wy = imgui.GetWindowPos();
        fl.settings.window_x = wx;
        fl.settings.window_y = wy;

        ------------------------------------------------------------------------------------
        -- Compute dynamic column widths from current content.
        -- Name = longest name + 1 space; Zone = longest zone name + 1 space.
        -- Status and Flags use their current widths +2px per side (4px extra each).
        ------------------------------------------------------------------------------------
        local space_w = imgui.CalcTextSize(' ');

        local REFRESHING_TEXT = 'Refreshing...';
        local refreshing_w    = imgui.CalcTextSize(REFRESHING_TEXT);

        local name_content_w = imgui.CalcTextSize('AAAA');  -- floor so an empty list still looks ok
        local zone_content_w = imgui.CalcTextSize('???');
        for _, f in ipairs(fl.settings.friends) do
            local nw = imgui.CalcTextSize(f.name);
            if (nw > name_content_w) then name_content_w = nw; end
            -- Zone column displays either the actual zone name (Online / In Zone),
            -- "Refreshing..." (Unknown), or nothing (Offline) — only Online & Unknown
            -- contribute to the column width.
            if (f.status == 'Online' or f.status == 'In Zone') then
                if (f.zone ~= nil and xi ~= nil) then
                    local zw = imgui.CalcTextSize(xi.zone_name(f.zone));
                    if (zw > zone_content_w) then zone_content_w = zw; end
                end
            elseif (f.status == 'Unknown') then
                if (refreshing_w > zone_content_w) then zone_content_w = refreshing_w; end
            end
        end

        local COL_NAME_W      = name_content_w + space_w;
        local COL_STATUS_W    = 29;                    -- bullet + ~4px padding each side
        local COL_STATUS_LPAD = 2;                     -- left inset for the bullet (3/5 of prior 4px)
        local COL_FLAGS_W     = 32;                    -- single 18px icon slot + ~7px padding each side
        local COL_ZONE_W      = zone_content_w + space_w;
        local COL_JOB_W       = 170;                   -- fits "WHM99/SCH49" + 32px icon
        local COL_PAD         = 5;                     -- extra padding between every column

        local COL_NAME_X   = COL_STATUS_W + COL_PAD;
        local COL_FLAGS_X  = COL_NAME_X   + COL_NAME_W  + COL_PAD;
        local COL_JOB_X    = COL_FLAGS_X  + COL_FLAGS_W + COL_PAD;
        local COL_ZONE_X   = COL_JOB_X    + COL_JOB_W   + COL_PAD;

        -- Scrollable list region. ChildBg gives the inner table its own background (#121526).
        imgui.PushStyleColor(ImGuiCol_ChildBg, COL_LIST_BG);
        imgui.BeginChild('##fl_list', { 0, -56 }, false);

        -- 2px top margin before the first row.
        imgui.Dummy({ 0, 2 });

        if (#fl.settings.friends == 0) then
            imgui.Spacing();
            imgui.TextColored(COL_TEXT_MUTED, 'No friends added yet.');
            imgui.TextColored(COL_TEXT_MUTED, 'Use the textbox and Add button or');
            imgui.TextColored(COL_TEXT_MUTED, 'use /fl add <name> to get started.');
        else
            local pending_remove = nil;  -- deferred so we don't mutate the array mid-iteration

            -- Build a sorted view: Online/In Zone → Away → Unknown → Offline, then A–Z within each group.
            local sorted_friends = {};
            for j = 1, #fl.settings.friends do sorted_friends[j] = fl.settings.friends[j]; end
            table.sort(sorted_friends, function(a, b)
                local pa = get_sort_priority(a);
                local pb = get_sort_priority(b);
                if (pa ~= pb) then return pa < pb; end
                return a.name:lower() < b.name:lower();
            end);

            for i, f in ipairs(sorted_friends) do
                -- Pre-compute row properties so row_h is known before the first element.
                local show_details = (f.status == 'Online' or f.status == 'In Zone');
                local is_unknown   = (f.status == 'Unknown');
                local is_anon      = show_details and (f.flags1 ~= nil) and (bit.band(f.flags1, 0x4000) ~= 0);
                local in_party     = (f.flags1 ~= nil) and (bit.band(f.flags1, 0x2000) ~= 0);
                local is_away      = (f.flags1 ~= nil) and (bit.band(f.flags1, 0x0100) ~= 0);
                local has_job_icon = show_details and (is_anon or (f.mjob ~= nil and xi ~= nil));
                local row_h        = has_job_icon and 32 or 18;
                local text_h       = imgui.GetTextLineHeight();
                local row_start_y  = imgui.GetCursorPosY();

                -- Status bullet (centered vertically in the row).
                imgui.SetCursorPosX(imgui.GetCursorPosX() + COL_STATUS_LPAD);
                imgui.SetCursorPosY(row_start_y + math.floor((row_h - text_h) * 0.5));
                imgui.PushStyleColor(ImGuiCol_Text, get_dot_color(f));
                imgui.Bullet();
                imgui.PopStyleColor(1);
                if (imgui.IsItemHovered()) then
                    local tip = (is_away and (f.status == 'Online' or f.status == 'In Zone'))
                                and 'Away' or (f.status or 'Unknown');
                    imgui.SetTooltip(tip);
                end

                -- Invisible selectable for click/hover/context-menu; name drawn separately so
                -- it can be vertically centered independent of the selectable's bounding box.
                imgui.SameLine(COL_NAME_X);
                imgui.SetCursorPosY(row_start_y);
                local is_selected = (fl.selected_idx == i);
                if (imgui.Selectable('##row' .. i, is_selected, 0, { COL_NAME_W, row_h })) then
                    fl.selected_idx = i;
                    -- Open the game chat input pre-filled with a /tell to this friend.
                    -- If the input is already open, fill it directly; otherwise open it
                    -- via sendkey (same trick fancychat uses) and let the present loop
                    -- fill it once IsInputOpen flips.
                    local cm = AshitaCore:GetChatManager();
                    if (cm:IsInputOpen() == 0x11) then
                        cm:SetInputText('/tell ' .. f.name .. ' ');
                        fl.selected_idx = 0;  -- deselect once the /tell is in place
                    else
                        fl.tell_pending = f.name;
                        fl.tell_until   = os.clock() + 2.0;
                        cm:QueueCommand(-1, '/sendkey space down');
                        cm:QueueCommand(-1, '/sendkey space up');
                    end
                end
                if (imgui.IsItemHovered()) then
                    -- Countdown to this friend's next query. With flat-rate pacing
                    -- the dispatcher fires one task every query_spacing() seconds,
                    -- so the wait is simply the task's position in the queue. If the
                    -- friend was already polled this cycle, project into the next one
                    -- (task order is stable, so their slot is known in advance).
                    -- A task may cover several friends, so scan its member list.
                    local function task_has(task)
                        if (task == nil) then return false; end
                        for _, mname in ipairs(task.members) do
                            if (mname == f.name) then return true; end
                        end
                        return false;
                    end
                    if (fl.active_search ~= nil and task_has(fl.active_search._task)) then
                        imgui.SetTooltip('Checking now...');
                    else
                        local spacing = query_spacing();
                        local now_c   = os.clock();
                        local eta     = nil;
                        for i, task in ipairs(fl.search_queue) do
                            if (task_has(task)) then
                                eta = (fl.last_search_at + i * spacing) - now_c;
                                break;
                            end
                        end
                        if (eta == nil) then
                            local start = math.max(fl.next_cycle_at, fl.last_search_at + spacing);
                            for i, task in ipairs(build_cycle_tasks()) do
                                if (task_has(task)) then
                                    eta = start + (i - 1) * spacing - now_c;
                                    break;
                                end
                            end
                        end
                        if (eta ~= nil) then
                            imgui.SetTooltip(('Refreshing in: %ds'):format(
                                math.max(0, math.floor(eta + 0.5))));
                        end
                    end
                end
                if (imgui.BeginPopupContextItem('##fl_ctx_' .. i)) then
                    local rm_str = 'Remove friend';
                    local txt_w = imgui.CalcTextSize(rm_str);
                    if (imgui.Selectable(rm_str .. '##fl_rm', false, 0, { txt_w, 0 })) then
                        pending_remove = f.name;
                        imgui.CloseCurrentPopup();
                    end
                    if (delete_tex ~= nil) then
                        imgui.SameLine();
                        imgui.Image(tonumber(ffi.cast('uint32_t', delete_tex)), { 20, 20 });
                    end
                    imgui.EndPopup();
                end
                imgui.SameLine(COL_NAME_X);
                imgui.SetCursorPosY(row_start_y + math.floor((row_h - text_h) * 0.5));
                imgui.Text(f.name);

                -- Flags column: centered vertically. Away wins over Party when both flags set.
                imgui.SameLine(COL_FLAGS_X);
                imgui.SetCursorPosY(row_start_y + math.floor((row_h - 18) * 0.5));
                if (is_away and away_tex ~= nil) then
                    imgui.Image(tonumber(ffi.cast('uint32_t', away_tex)), { 18, 18 });
                    if (imgui.IsItemHovered()) then imgui.SetTooltip('Away'); end
                elseif (in_party and party_tex ~= nil) then
                    imgui.Image(tonumber(ffi.cast('uint32_t', party_tex)), { 18, 18 });
                    if (imgui.IsItemHovered()) then imgui.SetTooltip('In party'); end
                else
                    imgui.Dummy({ 18, 18 });
                end

                -- Job column: icon at top of row; text centered alongside it.
                imgui.SameLine(COL_JOB_X);
                imgui.SetCursorPosY(row_start_y);
                if (show_details and is_anon) then
                    if (anon_tex ~= nil) then
                        imgui.Image(tonumber(ffi.cast('uint32_t', anon_tex)), { 32, 32 });
                        if (imgui.IsItemHovered()) then imgui.SetTooltip('Anonymous'); end
                        imgui.SameLine(0, 2);
                        imgui.SetCursorPosY(row_start_y + math.floor((32 - text_h) * 0.5));
                    end
                    imgui.TextColored(COL_TEXT_MUTED, '?????/?????');
                elseif (show_details and f.mjob ~= nil and xi ~= nil) then
                    if (jobs_tex ~= nil and f.mjob >= 1 and f.mjob <= JOBS_COUNT) then
                        local u0 = (f.mjob - 1) / JOBS_COUNT;
                        local u1 = f.mjob       / JOBS_COUNT;
                        imgui.Image(tonumber(ffi.cast('uint32_t', jobs_tex)),
                                    { 32, 32 }, { u0, 0 }, { u1, 1 });
                        imgui.SameLine(0, 2);
                        imgui.SetCursorPosY(row_start_y + math.floor((32 - text_h) * 0.5));
                    end
                    local job_str = xi.job_name(f.mjob) .. (f.mlvl and tostring(f.mlvl) or '');
                    if (f.sjob ~= nil and f.sjob > 0) then
                        job_str = job_str .. '/' .. xi.job_name(f.sjob)
                                            .. (f.slvl and tostring(f.slvl) or '');
                    end
                    imgui.TextColored(COL_TEXT_MUTED, job_str);
                elseif (is_unknown) then
                    imgui.SetCursorPosY(row_start_y + math.floor((row_h - text_h) * 0.5));
                    imgui.TextColored(COL_TEXT_MUTED, REFRESHING_TEXT);
                end

                -- Zone column: text centered in the row height.
                imgui.SameLine(COL_ZONE_X);
                imgui.SetCursorPosY(row_start_y + math.floor((row_h - text_h) * 0.5));
                local zone_str = '';
                local zone_col = COL_TEXT_MUTED;
                if (show_details and f.zone ~= nil and xi ~= nil) then
                    zone_str = xi.zone_name(f.zone);
                    if (f.status == 'In Zone') then zone_col = COL_DOT_ONLINE; end
                elseif (is_unknown) then
                    zone_str = REFRESHING_TEXT;
                end
                imgui.TextColored(zone_col, zone_str);
            end

            -- Apply the deferred deletion (if any) outside the iteration.
            if (pending_remove ~= nil) then
                local ok, msg = remove_friend(pending_remove);
                print(chat.header('FrensList'):append(ok and chat.message(msg) or chat.error(msg)));
            end
        end

        imgui.EndChild();
        imgui.PopStyleColor(1);  -- ChildBg

        imgui.Separator();

        -- Add/Remove bar
        imgui.PushItemWidth(280);
        if (imgui.InputText('##fl_input', fl.add_buf, 32, ImGuiInputTextFlags_EnterReturnsTrue)) then
            local name = fl.add_buf[1]:trim();
            if (name ~= '') then
                local ok, msg = add_friend(name);
                print(chat.header('FrensList'):append(ok and chat.message(msg) or chat.error(msg)));
                fl.add_buf[1] = '';
            end
        end
        imgui.PopItemWidth();

        imgui.SameLine();
        if (imgui.Button('Add', { 50, 0 })) then
            local name = fl.add_buf[1]:trim();
            if (name ~= '') then
                local ok, msg = add_friend(name);
                print(chat.header('FrensList'):append(ok and chat.message(msg) or chat.error(msg)));
                fl.add_buf[1] = '';
            end
        end

        -- Settings (gear) button — sized to match the Add button's auto height.
        if (settings_tex ~= nil) then
            imgui.SameLine();
            local h = imgui.GetFrameHeight();  -- = Button({_, 0}) height
            imgui.PushID('##fl_settings_btn');
            if (imgui.ImageButton(tonumber(ffi.cast('uint32_t', settings_tex)),
                                  { h, h }, { -0.1, -0.1 }, { 1.1, 1.1 }, 0)) then
                fl.show_settings = not fl.show_settings;
            end
            if (imgui.IsItemHovered()) then
                imgui.SetTooltip('Settings');
            end
            imgui.PopID();
        end

        -- Info (?) button — hover to show a quick-reference tooltip.
        if (info_tex ~= nil) then
            imgui.SameLine();
            local h = imgui.GetFrameHeight();
            imgui.PushID('##fl_info_btn');
            imgui.ImageButton(tonumber(ffi.cast('uint32_t', info_tex)),
                              { h, h }, { -0.2, -0.2 }, { 1.2, 1.2 }, 0);
            if (imgui.IsItemHovered()) then
                imgui.BeginTooltip();
                    imgui.TextColored(COL_ACCENT, 'FrensList - Quick Reference');
                    imgui.Separator();
                    imgui.Spacing();

                    local function cmd_row(cmd, desc)
                        imgui.TextColored(COL_ACCENT, cmd);
                        imgui.SameLine();
                        imgui.TextColored(COL_TEXT_MUTED, desc);
                    end

                    cmd_row('/fl add <name>',    '- Add a player to your friend list.');
                    cmd_row('/fl remove <name>', '- Remove a player. (aliases: del, rm)');
                    cmd_row('/fl help',          '- Print available commands to chat.');
                    imgui.Spacing();
                    imgui.Separator();
                    imgui.Spacing();
                    imgui.TextColored(COL_TEXT_MUTED, 'Gear button  - Open / close Settings.');
                    imgui.TextColored(COL_TEXT_MUTED, 'X button     - Minimize to FL button.');
                    imgui.TextColored(COL_TEXT_MUTED, 'Right-click  - Remove friend (in list).');
                imgui.EndTooltip();
            end
            imgui.PopID();
        end

        -- Friend-count indicator, right-aligned on the same row.
        -- Gold when full, muted otherwise.
        local count_str = ('%d / %d'):format(#fl.settings.friends, fl.MAX_FRIENDS);
        local cx        = imgui.CalcTextSize(count_str);
        local at_max    = (#fl.settings.friends >= fl.MAX_FRIENDS);
        imgui.SameLine();
        imgui.SetCursorPosX(imgui.GetCursorPosX() + imgui.GetColumnWidth() - cx - imgui.GetStyle().FramePadding.x);
        imgui.TextColored(at_max and COL_ACCENT or COL_TEXT_MUTED, count_str);
    end

    imgui.End();

    -- Detect X-button close (imgui sets win_open[1] = false when X is clicked).
    -- Hand control to the small FL relauncher window, which lives at its own
    -- independently-saved position (mini_x / mini_y).
    if (not fl.win_open[1]) then
        fl.settings.is_open  = false;
        fl.win_open[1]       = true;  -- reset so it's ready when window reopens
        fl.mini_first_frame  = true;  -- force-position the mini at its saved coords
        settings.save();
    end

    imgui.PopStyleVar(4);
    imgui.PopStyleColor(15);
end

----------------------------------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------------------------------
ashita.events.register('load', 'load_cb', function ()
    -- Resolve the R0-detection pointer once the game has loaded FFXiMain.dll.
    init_r0_ptr();

    -- All per-session data is ephemeral — reset it on every load.
    for _, f in ipairs(fl.settings.friends) do
        f.status      = 'Unknown';
        f.last_search = nil;
        f.flags1      = nil;
        f.zone        = nil;
        f.mjob        = nil;
        f.sjob        = nil;
        f.mlvl        = nil;
        f.slvl        = nil;
        f.race        = nil;
        f.nation      = nil;
        f.rank        = nil;
    end
    fl.search_queue   = {};
    fl.cycle_tasks    = 0;
    fl.active_search  = nil;
    fl.last_search_at = 0;
    fl.cycle_start_at = 0;
    fl.next_cycle_at  = 0;
    fl.win_open[1] = fl.settings.is_open;
    restore_preset_idx();
end);

ashita.events.register('unload', 'unload_cb', function ()
    settings.save();
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/fl', '/frenslist')) then return; end

    e.blocked = true;

    -- /fl help
    if (args[2]:any('help')) then
        print_help(false);
        return;
    end

    -- (Force-refresh has been disabled: the addon refreshes automatically every 30s.)

    -- /fl debug <name>  — synchronous one-shot search of a single player.
    -- Bypasses the regular cycle/cooldown and writes a full hex/decrypt dump.
    if (args[2]:any('debug')) then
        if (sc == nil) then
            print(chat.header('FrensList'):append(chat.error('Search client unavailable.')));
            return;
        end
        if (#args < 3) then
            print(chat.header('FrensList'):append(chat.error('Usage: /fl debug <playername>')));
            return;
        end
        local name = normalize_name(args[3]);
        if (name == nil) then
            print(chat.header('FrensList'):append(chat.error('Invalid name.')));
            return;
        end
        sc.debug = true;
        local result, _ = sc.search_name(name, 5.0);
        print(chat.header('FrensList'):append(chat.message(
            ('Debug search %s → %s. Output → lib/search_debug.txt'):format(name, tostring(result)))));
        return;
    end

    -- /fl add <name>
    if (args[2]:any('add') and #args >= 3) then
        local ok, msg = add_friend(args[3]);
        print(chat.header('FrensList'):append(ok and chat.message(msg) or chat.error(msg)));
        return;
    end

    -- /fl remove <name>  |  /fl del <name>  |  /fl rm <name>
    if (args[2]:any('remove', 'del', 'rm') and #args >= 3) then
        local ok, msg = remove_friend(args[3]);
        print(chat.header('FrensList'):append(ok and chat.message(msg) or chat.error(msg)));
        return;
    end

    print_help(true);
end);

ashita.events.register('packet_out', 'packet_out_cb', function (e)
    if (not fl.capture_mode) then return; end

    if (os.clock() > fl.capture_until) then
        fl.capture_mode = false;
        print(chat.header('FrensList'):append(chat.message('Capture complete. See: frenslist/lib/packet_capture.txt')));
        return;
    end

    local path = addon.path .. 'lib/packet_capture.txt';
    local f = io.open(path, 'a');
    if (f == nil) then return; end

    f:write(('=== OUT id=0x%04X  size=%d  time=%.3f ===\n'):format(e.id, e.size, os.clock()));

    -- Full hex + ASCII dump, 16 bytes per row
    local bytes = e.size;
    for row = 0, math.ceil(bytes / 16) - 1 do
        local offset = row * 16;
        local hex_col   = '';
        local ascii_col = '';

        for col = 0, 15 do
            local idx = offset + col + 1;
            if (idx <= bytes) then
                local b = e.data:byte(idx);
                hex_col   = hex_col   .. ('%02X '):format(b);
                ascii_col = ascii_col .. (b >= 32 and b <= 126 and string.char(b) or '.');
            else
                hex_col = hex_col .. '   ';
            end
            if (col == 7) then hex_col = hex_col .. ' '; end
        end

        f:write(('  %04X  %-49s  %s\n'):format(offset, hex_col, ascii_col));
    end

    f:write('\n');
    f:close();
end);

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    -- Zone-in packet: snapshot current zone and arm a 10s polling window.
    if (e.id == 0x000A) then
        fl.my_zone          = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        fl.zone_check_until = os.clock() + 10;
    end

    -- Capture mode: log all incoming packets (except 0x0015 noise) for packet analysis
    if (fl.capture_mode) then
        if (os.clock() > fl.capture_until) then
            fl.capture_mode = false;
            print(chat.header('FrensList'):append(chat.message('Capture complete. See: frenslist/lib/packet_capture.txt')));
        elseif (e.id ~= 0x0015) then
            local path = addon.path .. 'lib/packet_capture.txt';
            local cf = io.open(path, 'a');
            if (cf ~= nil) then
                cf:write(('=== IN  id=0x%04X  size=%d  time=%.3f ===\n'):format(e.id, e.size, os.clock()));
                local bytes = e.size;
                for row = 0, math.ceil(bytes / 16) - 1 do
                    local offset = row * 16;
                    local hex_col, ascii_col = '', '';
                    for col = 0, 15 do
                        local idx = offset + col + 1;
                        if (idx <= bytes) then
                            local b = e.data_modified:byte(idx);
                            hex_col   = hex_col   .. ('%02X '):format(b);
                            ascii_col = ascii_col .. (b >= 32 and b <= 126 and string.char(b) or '.');
                        else
                            hex_col = hex_col .. '   ';
                        end
                        if (col == 7) then hex_col = hex_col .. ' '; end
                    end
                    cf:write(('  %04X  %-49s  %s\n'):format(offset, hex_col, ascii_col));
                end
                cf:write('\n');
                cf:close();
            end
        end
    end

end);


ashita.events.register('d3d_present', 'present_cb', function ()
    -- Zone-change detection: only active during the 10s window armed by packet 0x000A.
    -- Polls GetMemberZone(0) until it differs from the pre-zone snapshot, then re-evaluates
    -- all stored friend zones and disarms the window.
    if (fl.zone_check_until > 0 and os.clock() <= fl.zone_check_until) then
        local cur_zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
        if (cur_zone ~= 0 and cur_zone ~= fl.my_zone) then
            fl.zone_check_until = 0;
            for _, f in ipairs(fl.settings.friends) do
                if (f.zone ~= nil) then
                    if (f.zone == cur_zone and f.status == 'Online') then
                        set_status(f, 'In Zone');
                    elseif (f.zone ~= cur_zone and f.status == 'In Zone') then
                        set_status(f, 'Online');
                    end
                end
            end
        end
    elseif (fl.zone_check_until > 0) then
        fl.zone_check_until = 0;  -- timed out, disarm
    end

    -- Automatic refresh cycle (SLOW variant).
    -- Tasks are dispatched one at a time, query_spacing() apart (60 / MAX_QPM),
    -- which is the only rate control: at MAX_QPM = 30 that is one query every
    -- 2s, no matter how many friends are listed. A sweep therefore takes about
    -- #tasks * 2s, and that is also how often each friend is refreshed. The
    -- cycle ends when the queue empties; next_cycle_at is then now +
    -- POST_CYCLE_GAP, and the spacing rule still applies across the boundary.
    -- Skip the whole block while an R0 is active (search server isn't reachable
    -- without the world server connection); silent — no chat notification.
    -- When the gate REOPENS (relogin, back from title, R0 recovery), everything
    -- we hold predates the gap: wipe session data and start a fresh cycle shortly,
    -- instead of showing the previous session's statuses as current.
    if (sc ~= nil) then
        local r0_now = is_r0_active();
        if (fl.r0_was_active and not r0_now) then
            for _, f in ipairs(fl.settings.friends) do
                set_status(f, 'Unknown');  -- silent; also clears zone/job fields
                f.last_search = nil;
                f.race        = nil;
                f.nation      = nil;
                f.rank        = nil;
            end
            fl.search_queue   = {};
            fl.cycle_tasks    = 0;
            fl.active_search  = nil;
            fl.cycle_start_at = 0;
            fl.next_cycle_at  = os.clock() + 5;  -- grace for the connection to settle
        end
        fl.r0_was_active = r0_now;
    end
    if (sc ~= nil and not is_r0_active()) then
        local now_t = os.clock();

        -- Start a new cycle if nothing is in-flight, the queue is empty, and interval has elapsed.
        if (fl.active_search == nil and #fl.search_queue == 0
                and now_t >= fl.next_cycle_at and #fl.settings.friends > 0) then
            fl.search_queue = build_cycle_tasks();
            fl.cycle_tasks  = #fl.search_queue;
        end

        -- Poll the in-flight async search (runs every frame, zero blocking).
        if (fl.active_search ~= nil) then
            local result = sc.poll(fl.active_search);
            if (result ~= nil) then
                local h    = fl.active_search;
                local task = h._task;
                if (task ~= nil) then
                    if (h.entries == nil) then
                        -- Query failed (timeout / decode error): a missing answer is
                        -- not an offline answer, so leave everyone in this task Unknown.
                        for _, mname in ipairs(task.members) do
                            local _, f = find_friend(mname);
                            set_status(f, 'Unknown');
                        end
                    elseif (#task.members > 1 and h.total ~= nil and h.total > #h.entries) then
                        -- The server truncated the page, so absence from the result
                        -- set proves nothing. Split the group into per-name queries
                        -- and run those first.
                        for i = #task.members, 1, -1 do
                            table.insert(fl.search_queue, 1,
                                { prefix = task.members[i], members = { task.members[i] } });
                        end
                        fl.cycle_tasks = fl.cycle_tasks + #task.members - 1;
                    else
                        local my_zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);
                        local by_name = {};
                        for _, e in ipairs(h.entries) do
                            if (e.name) then by_name[e.name:lower()] = e; end
                        end
                        for _, mname in ipairs(task.members) do
                            local _, f = find_friend(mname);
                            apply_entry(f, by_name[mname:lower()], my_zone);
                        end
                    end
                end
                fl.active_search = nil;
                -- Cycle done?
                if (#fl.search_queue == 0) then
                    fl.next_cycle_at = now_t + fl.POST_CYCLE_GAP;
                    fl.cycle_start_at = 0;
                end
            end
        end

        -- Dispatch the next queued task as a non-blocking async search.
        -- Spacing spreads the cycle's tasks evenly across the cycle length.
        local spacing = query_spacing();
        if (fl.active_search == nil and #fl.search_queue > 0
                and (now_t - fl.last_search_at) >= spacing) then
            fl.last_search_at = now_t;
            if (fl.cycle_start_at == 0) then fl.cycle_start_at = now_t; end

            local task = table.remove(fl.search_queue, 1);
            if (task ~= nil) then
                for _, mname in ipairs(task.members) do
                    local _, f = find_friend(mname);
                    if (f) then f.last_search = now_t; end
                end
                local handle = sc.new_search(task.prefix);
                handle._task = task;
                fl.active_search = handle;
            end
        end
    end

    -- Deferred /tell fill: the chat input opens a frame or two after the
    -- queued sendkey runs; write the text as soon as it reports open.
    if (fl.tell_pending ~= nil) then
        if (AshitaCore:GetChatManager():IsInputOpen() == 0x11) then
            AshitaCore:GetChatManager():SetInputText('/tell ' .. fl.tell_pending .. ' ');
            fl.tell_pending  = nil;
            fl.selected_idx  = 0;  -- deselect once the /tell is in place
        elseif (os.clock() > fl.tell_until) then
            fl.tell_pending = nil;  -- input never opened; disarm
        end
    end

    if (AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() == 2) then
        render_window();
    end
end);
