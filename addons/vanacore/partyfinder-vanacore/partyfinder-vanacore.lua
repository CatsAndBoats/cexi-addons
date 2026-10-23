--[[
partyfinder-vanacore: CatsEyeXI's Party Finder, drawn fresh for VanaCore (the Ashita addon is partyfinder; this one
unloads it if it's running, since both would answer the same packets and the same command). Speaks the server's 0x1A2 protocol
(listings, join requests, Duty Roulette, Mission Help) with a window of its own: glass cards,
the job sprites, role icons, live badges and a floating beacon when it's tucked away.

In game:
  /pf                 the window, or tucked into the beacon (Ctrl+G too, unless the key is taken)
  /pf hide            hides both; /pf show brings the window back
  /pf mini            tucks the window into the beacon, or brings it back (drag the beacon to move it)
  /pf reset           puts the beacon back at the right edge, with the default scale and opacity
  /pf theme <name>    a theme: its colours and its art (aurora, gems, banner, ember, ranger, inferno, ninja, harvest, gunslinger, rose, bard, jade,
                       and any themes\\<id>.lua)
  /pf export          copies your look (theme, art, icon, opacities) as one line to share; /pf import <line> applies one
  /pf create          opens the listing sheet
  /pf refresh         asks the server for the listings again
  /pf notify          LFM announcements in the chat on or off
  /pf scale <pct>     the window's size, 50 to 300
  /pf block <name>    refuses that player's join requests (unblock, blocklist)
  /pf settings [art]  the settings panel (art: the artwork page)
  /pf tour            the three-step tour again
  /pf handheld <auto|on|off>  Handheld mode: a narrow panel at the screen's edge for small screens (auto: at 1280x800 or less)
  /pf debug           the last error and the packet counters

Fonts: Inter (text) and Rajdhani (display), in fonts\ beside this file, both under the SIL Open Font License.
Images: the original Party Finder's sprite sheets, in images\. Sounds: the original's, in sounds\.
Settings and the block list are kept per character in config\addons\partyfinder-vanacore\<name>.lua.
--]]

addon.name    = 'partyfinder-vanacore'
addon.author  = 'Carver'
addon.version = '2.2'
addon.desc    = "CatsEyeXI's Party Finder: listings, join requests, Duty Roulette and Mission Help."

local imgui = vana.imgui
local PAD = require('pad') -- a controller (pad.lua, shared with the auction house)
if imgui == nil then
    print('partyfinder-vanacore needs a newer VanaCore.Core.dll (vana.imgui)')
    return
end

-------------------------------------------------------------------------------
-- The protocol (modules/cpp/party_finder.cpp)
-------------------------------------------------------------------------------

local PACKET_ID = 0x1A2
local VENTURE_ID = 0x1A3

local C2S = {
    REGISTER = 1, WITHDRAW = 2, REFRESH = 3, ROULETTE_ROLL = 4, ROULETTE_GO = 5, MISSION_START = 6,
    READY = 7, JOIN_REQUEST = 8, JOIN_RESPOND = 9, DUTY_DECLINE = 10,
    PING = 11, BLOCK = 12, JOIN_SEEN = 13, SET_SLOTS = 14, -- v2
}
local S2C = {
    CLEAR = 0, ENTRY = 1, END_LIST = 2, ACK_REGISTER = 3, ACK_WITHDRAW = 4, ROULETTE_DUTY = 5, ROULETTE_ERR = 6,
    ROULETTE_OK = 7, MISSION_ENTRY = 8, MISSION_END = 9, READY_UPDATE = 10, JOIN_REQUEST = 11, JOIN_RESULT = 12,
    DUTY_DECLINE = 13, LISTINGS_CHANGED = 14, PARTY_MEMBER = 15,
    ENTRY_REMOVE = 16, PONG = 17, ANNOUNCE = 18, JOIN_SEEN = 19, -- v2
}

local CATEGORIES = {
    { id = 1, name = 'EXP',     color = '#6FD58F', icon = 'bolt' },
    { id = 2, name = 'Mission', color = '#6FA2FF', icon = 'flag' },
    { id = 3, name = 'BCNM',    color = '#FF8A5B', icon = 'dice' },
    { id = 4, name = 'Mentor',  color = '#D9A6FF', icon = 'hat-wizard' },
    { id = 5, name = 'Venture', color = '#FFD166', icon = 'compass' },
}
local CATEGORY = {}
for _, c in ipairs(CATEGORIES) do CATEGORY[c.id] = c end

-- roles: drawn as glass discs (role_icon); the colours mark them everywhere else
local ROLES = {
    [0] = { name = 'Any',     color = '#B9BFCC', short = 'ANY', about = 'any role is welcome' },
    [1] = { name = 'Tank',    color = '#5B8CFF', short = 'TNK', about = 'holds the enemy: PLD, NIN, RUN' },
    [2] = { name = 'Healer',  color = '#5EE39A', short = 'HLR', about = 'keeps the party standing: WHM' },
    [3] = { name = 'Support', color = '#FFCC5B', short = 'SUP', about = 'buffs, debuffs, refresh: RDM, BRD, SMN, COR, DNC, SCH, GEO' },
    [4] = { name = 'DPS',     color = '#FF6B6B', short = 'DPS', about = 'damage: every other job' },
}

local JOBS = {
    [1] = 'WAR', [2] = 'MNK', [3] = 'WHM', [4] = 'BLM', [5] = 'RDM', [6] = 'THF', [7] = 'PLD', [8] = 'DRK',
    [9] = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM', [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH', [21] = 'GEO', [22] = 'RUN',
}
local JOB_COLOR = {
    WAR = '#E0613A', MNK = '#D9A35C', WHM = '#F2F2F2', BLM = '#8E6BFF', RDM = '#E05A6E', THF = '#9BD35A',
    PLD = '#6FA7FF', DRK = '#A35DD9', BST = '#C98D52', BRD = '#F0C96A', RNG = '#7FC97F', SAM = '#E88A5A',
    NIN = '#6E7BD9', DRG = '#5BA8D9', SMN = '#5CD6C8', BLU = '#5BB7FF', COR = '#F0A35C', PUP = '#B9B9B9',
    DNC = '#F27FB2', SCH = '#8FB3FF', GEO = '#B5D96E', RUN = '#7A8FFF',
}
local MODES = { [0] = 'ACE', [1] = 'CW', [2] = 'WEW' }

-- seconds: the server's reply before a retry and how many, a join request's life, the listings' refresh, a ready check
local LIMITS = { ping = 6, retries = 3, request = 60, refresh = 60, ready = 60, wait = 90, version = 2 }
-- JOIN_RESULT reasons and END flags the v2 server adds
local V2 = { timeout = 4, rate = 5, unchanged = 1, delta = 2, rate_error = 14 }

-------------------------------------------------------------------------------
-- Look
-------------------------------------------------------------------------------

-- the palette in use: filled from the theme (apply_theme); every colour below is looked up as it's drawn
local P = {}

-- A recruiting leader can say what each open slot wants: a job mask per slot (bit j = job j fits, 0 = any),
-- five at most, sent with SET_SLOTS right after REGISTER. The server matches members to slots and tells
-- everyone which are filled, so cards show what is really still needed. Roles are shortcuts to job sets, in
-- the server's own mapping. All of this lives in one table to spare top-level locals (LuaJIT allows 200).
local SLOTS = { n = 5, bit = require('bit'), ALL = 0x7FFFFE }
function SLOTS.mask(jobs)
    local m = 0
    for _, j in ipairs(jobs) do m = SLOTS.bit.bor(m, SLOTS.bit.lshift(1, j)) end
    return m
end
SLOTS.ROLE = { [0] = 0, [1] = SLOTS.mask({ 7, 13, 22 }), [2] = SLOTS.mask({ 3 }), [3] = SLOTS.mask({ 5, 10, 15, 17, 19, 20, 21 }) }
SLOTS.ROLE[4] = SLOTS.bit.band(SLOTS.ALL, SLOTS.bit.bnot(SLOTS.bit.bor(SLOTS.ROLE[1], SLOTS.ROLE[2], SLOTS.ROLE[3])))
SLOTS.PRESETS = {
    { name = 'Standard', masks = { SLOTS.ROLE[1], SLOTS.ROLE[2], SLOTS.ROLE[3], SLOTS.ROLE[4], SLOTS.ROLE[4] } },
    { name = 'Manaburn', masks = { SLOTS.mask({ 4, 20, 5, 21 }), SLOTS.mask({ 4, 20, 5, 21 }), SLOTS.mask({ 4, 20, 5, 21 }), SLOTS.mask({ 4, 20, 5, 21 }), SLOTS.mask({ 4, 20, 5, 21 }) } },
    { name = 'TP burn', masks = { SLOTS.mask({ 1, 2, 6, 8, 12, 14, 16, 18 }), SLOTS.mask({ 1, 2, 6, 8, 12, 14, 16, 18 }), SLOTS.mask({ 1, 2, 6, 8, 12, 14, 16, 18 }), SLOTS.mask({ 1, 2, 6, 8, 12, 14, 16, 18 }), SLOTS.mask({ 10, 17, 21, 5 }) } },
}
function SLOTS.fits(mask, job) return mask == 0 or mask == SLOTS.ALL or (job ~= nil and SLOTS.bit.band(mask, SLOTS.bit.lshift(1, job)) ~= 0) end
function SLOTS.has(mask, job) return SLOTS.bit.band(mask, SLOTS.bit.lshift(1, job)) ~= 0 end
function SLOTS.toggle(mask, job) return SLOTS.bit.bxor(mask, SLOTS.bit.lshift(1, job)) end
function SLOTS.jobs(mask)
    local list = {}
    for j = 1, 22 do if SLOTS.has(mask, j) then list[#list + 1] = j end end
    return list
end
-- the role a mask is exactly, or nil
function SLOTS.role_of(mask)
    if mask == 0 or mask == SLOTS.ALL then return 0 end
    for r = 1, 4 do if SLOTS.ROLE[r] == mask then return r end end
    return nil
end
-- a mask's colour: its role's, or the text colour for a custom job list
function SLOTS.color(mask)
    local r = SLOTS.role_of(mask)
    return r and ROLES[r].color or P.text
end
-- a mask as words: ANY, a role, or the jobs (up to `max`, then +n)
function SLOTS.label(mask, short, max)
    local r = SLOTS.role_of(mask)
    if r then return short and ROLES[r].short or ROLES[r].name:upper() end
    local jobs = SLOTS.jobs(mask)
    max = max or 3
    local parts = {}
    for i = 1, math.min(#jobs, max) do parts[#parts + 1] = JOBS[jobs[i]] end
    local out = table.concat(parts, '/')
    if #jobs > max then out = out .. '+' .. (#jobs - max) end
    return out
end
-- the open (unfilled) slots of an entry: a list of { i = index, mask = mask }
function SLOTS.open(entry)
    local out = {}
    if not entry.has_slots then return out end
    for i = 1, SLOTS.n do
        if SLOTS.bit.band(entry.filled or 0, SLOTS.bit.lshift(1, i - 1)) == 0 and (i <= (entry.max_players or 6) - 1) then
            out[#out + 1] = { i = i, mask = entry.slots[i] }
        end
    end
    -- never more than the party has room for
    local room = math.max(0, (entry.max_players or 6) - (entry.party_size or 1))
    while #out > room do table.remove(out) end
    return out
end
-- the first open slot a job fits, or nil
function SLOTS.fit(entry, job)
    for _, sl in ipairs(SLOTS.open(entry)) do if SLOTS.fits(sl.mask, job) then return sl end end
    return nil
end
-- the open slots, one group per distinct mask, in slot order: { mask, count, role (or nil), color }
function SLOTS.groups(entry)
    local groups, by = {}, {}
    for _, sl in ipairs(SLOTS.open(entry)) do
        local m = (sl.mask == SLOTS.ALL) and 0 or sl.mask
        local g = by[m]
        if g == nil then
            g = { mask = m, count = 0, role = SLOTS.role_of(m), color = SLOTS.color(m) }
            by[m] = g
            groups[#groups + 1] = g
        end
        g.count = g.count + 1
    end
    return groups
end
-- what the open slots amount to, grouped: "BLM/SCH x2 · GEO"; returns text, colour
function SLOTS.needs(entry, short)
    local open = SLOTS.open(entry)
    if #open == 0 then return 'FULL', P.faint end
    local groups, order = {}, {}
    for _, sl in ipairs(open) do
        if groups[sl.mask] == nil then groups[sl.mask] = 0 order[#order + 1] = sl.mask end
        groups[sl.mask] = groups[sl.mask] + 1
    end
    local parts = {}
    for _, m in ipairs(order) do
        local lbl = SLOTS.label(m, short, short and 2 or 3)
        parts[#parts + 1] = lbl .. (groups[m] > 1 and (' x' .. groups[m]) or '')
    end
    local text_out = table.concat(parts, short and ' · ' or '  ·  ')
    if #order == 1 and SLOTS.role_of(order[1]) == 0 then return (#open .. ' OPEN'), P.ok end
    return (short and '' or 'NEEDS ') .. text_out, SLOTS.color(order[1])
end
-- a 20-byte string of the five masks, little-endian, for SET_SLOTS
function SLOTS.bytes(masks)
    local out = {}
    for i = 1, SLOTS.n do
        local m = masks[i] or 0
        out[#out + 1] = string.char(m % 256, math.floor(m / 256) % 256, math.floor(m / 65536) % 256, math.floor(m / 16777216) % 256)
    end
    return table.concat(out)
end
function SLOTS.any(masks)
    for i = 1, SLOTS.n do if (masks[i] or 0) ~= 0 then return true end end
    return false
end

-- the themes: a palette each, and the art it comes with (its file in bg\\, and a share of the art's height to centre on)
local THEMES = {
    { id = 'aurora', name = 'Aurora', art = 'none', focus = 0.5, palette = {
        bg = '#0B0D14', glass = '#12151F', card = '#171B29', card_hi = '#1F2538', line = '#262C3F', well = '#090B11',
        accent = '#7C8CFF', accent2 = '#B07CFF', cyan = '#5BE0FF' } },
    { id = 'gems', name = 'Gems', art = 'cexi_gems', focus = 0.55, palette = {
        bg = '#07100B', glass = '#0C1912', card = '#102118', card_hi = '#162C20', line = '#1F3A2B', well = '#050B08',
        accent = '#35E08C', accent2 = '#B07CFF', cyan = '#7CFFC4' } },
    { id = 'banner', name = 'Banner', art = 'cexi_banner', focus = 0.5, palette = {
        bg = '#07100B', glass = '#0C1912', card = '#102118', card_hi = '#162C20', line = '#1F3A2B', well = '#050B08',
        accent = '#4ADE80', accent2 = '#C9A6FF', cyan = '#9FFFD6' } },
    { id = 'ember', name = 'Ember', art = 'cexi_ember', focus = 0.4, palette = {
        bg = '#140B08', glass = '#1C110C', card = '#231510', card_hi = '#2E1C15', line = '#3A241B', well = '#0E0705',
        accent = '#FF7A45', accent2 = '#FFB36B', cyan = '#FFD166' } },
    { id = 'ranger', name = 'Ranger', art = 'cexi_ranger', focus = 0.4, palette = {
        bg = '#0B1110', glass = '#111A18', card = '#15211F', card_hi = '#1D2C29', line = '#28393A', well = '#070C0B',
        accent = '#5CC8B0', accent2 = '#9A7BFF', cyan = '#7FE0C9' } },
    { id = 'inferno', name = 'Inferno', art = 'cexi_inferno', focus = 0.4, palette = {
        bg = '#140707', glass = '#1C0B0B', card = '#241010', card_hi = '#301616', line = '#40201F', well = '#0D0404',
        accent = '#FF4A2A', accent2 = '#FF8C42', cyan = '#FFC65B' } },
    { id = 'ninja', name = 'Ninja', art = 'cexi_ninja', focus = 0.45, palette = {
        bg = '#0A0C12', glass = '#10131C', card = '#151A26', card_hi = '#1C2333', line = '#28304A', well = '#06080D',
        accent = '#5B8CFF', accent2 = '#5EC4D9', cyan = '#8FE3FF' } },
    { id = 'harvest', name = 'Harvest', art = 'cexi_harvest', focus = 0.45, palette = {
        bg = '#0F0A16', glass = '#160F21', card = '#1C142B', card_hi = '#261B3A', line = '#352A4C', well = '#09060E',
        accent = '#9D7BFF', accent2 = '#FFB347', cyan = '#FFD166' } },
    { id = 'gunslinger', name = 'Gunslinger', art = 'cexi_gunslinger', focus = 0.4, palette = {
        bg = '#0D0E10', glass = '#141618', card = '#1A1D21', card_hi = '#23272C', line = '#30353B', well = '#08090B',
        accent = '#B9C4CC', accent2 = '#D7B46A', cyan = '#E8EEF2' } },
    { id = 'rose', name = 'Rose', art = 'cexi_rose', focus = 0.4, palette = {
        bg = '#150A10', glass = '#1D0F17', card = '#26141E', card_hi = '#321B28', line = '#43263A', well = '#0D060A',
        accent = '#FF6FA5', accent2 = '#FFA3C7', cyan = '#FFC2DB' } },
    { id = 'bard', name = 'Bard', art = 'cexi_bard', focus = 0.35, palette = {
        bg = '#130D1A', glass = '#1B1326', card = '#221931', card_hi = '#2E2240', line = '#3E3055', well = '#0C0812',
        accent = '#C98BFF', accent2 = '#FF8AD6', cyan = '#E9C6FF' } },
    { id = 'jade', name = 'Jade', art = 'cexi_jade', focus = 0.4, palette = {
        bg = '#081412', glass = '#0E1C1A', card = '#122422', card_hi = '#192F2C', line = '#254240', well = '#050D0C',
        accent = '#4FD1C5', accent2 = '#FF8FB8', cyan = '#A8F0E6' } },
}
-- who drew what: a signature in the art's corner
local ARTISTS = {
    cexi_ember = 'Redkat', cexi_ranger = 'Redkat', cexi_inferno = 'Redkat', cexi_ninja = 'Redkat', cexi_harvest = 'Redkat',
    cexi_gunslinger = 'Redkat', cexi_rose = 'Redkat', cexi_bard = 'Redkat', cexi_jade = 'Redkat',
}
local THEME_BY_ID = {}
for _, t in ipairs(THEMES) do THEME_BY_ID[t.id] = t end

-- the colours every theme shares
local SHARED = { text = '#F1F3F9', dim = '#8F97AD', faint = '#5A627C', ok = '#5EE39A', warn = '#FFCC5B', danger = '#FF6B6B', gold = '#FFD166', ink = '#0B0D14' }

-- themes\\<id>.lua: each returns { name = 'Midnight', art = 'cexi_ninja', focus = 0.4, artist = 'Redkat',
-- palette = { bg = '#...', glass, card, card_hi, line, well, accent, accent2, cyan } }. Files add to the built-in
-- themes, or replace one with the same id.
local BUILTIN_THEME_COUNT = #THEMES
local function load_theme_files()
    local dir = vana.paths.addon .. '\\themes'
    for i = #THEMES, BUILTIN_THEME_COUNT + 1, -1 do THEME_BY_ID[THEMES[i].id] = nil table.remove(THEMES, i) end
    for _, t in ipairs(THEMES) do THEME_BY_ID[t.id] = t end
    if not vana.fs.exists(dir) then return end
    local ok, names = pcall(vana.fs.list, dir, '.+\\.[lL][uU][aA]', 'files')
    if not ok or names == nil then return end
    table.sort(names)
    for _, file in ipairs(names) do
        local f = io.open(dir .. '\\' .. file, 'rb')
        if f then
            local text = f:read('*a')
            f:close()
            local chunk = loadstring(text, '=' .. file)
            if chunk then
                setfenv(chunk, {})
                local good, theme = pcall(chunk)
                if good and type(theme) == 'table' and type(theme.palette) == 'table' then
                    local id = file:gsub('%.[lL][uU][aA]$', ''):lower()
                    theme.id = id
                    theme.name = theme.name or id
                    theme.art = theme.art or 'none'
                    theme.focus = tonumber(theme.focus) or 0.5
                    theme.file = file
                    if THEME_BY_ID[id] then
                        for i, t in ipairs(THEMES) do if t.id == id then THEMES[i] = theme end end
                    else
                        THEMES[#THEMES + 1] = theme
                    end
                    THEME_BY_ID[id] = theme
                    if theme.artist and theme.art ~= 'none' then ARTISTS[theme.art] = theme.artist end
                else
                    vana.log('partyfinder-vanacore: themes\\' .. file .. (good and ' is not a theme table' or (': ' .. tostring(theme))))
                end
            else
                vana.log('partyfinder-vanacore: themes\\' .. file .. " didn't parse")
            end
        end
    end
end

local function apply_theme(id)
    local theme = THEME_BY_ID[id] or THEMES[1]
    for k, v in pairs(SHARED) do P[k] = v end
    for k, v in pairs(THEMES[1].palette) do P[k] = v end
    for k, v in pairs(theme.palette) do if type(v) == 'string' and v:match('^#%x%x%x%x%x%x') then P[k] = v end end
    return theme
end
apply_theme('aurora')

-- '#RRGGBB' or '#RRGGBBAA'; `a` scales the alpha
local function rgba(hex, a)
    local alpha = #hex >= 9 and tonumber(hex:sub(8, 9), 16) / 255 or 1
    return { tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255, alpha * (a or 1) }
end

local WINDOW_ALPHA = 1 -- settings.opacity while the main window draws; everything drawn in it fades with it

local function u32(hex, a)
    local c = rgba(hex, (a or 1) * WINDOW_ALPHA)
    local function b(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return b(c[4]) * 16777216 + b(c[3]) * 65536 + b(c[2]) * 256 + b(c[1])
end

local function mix(a, b, t)
    local ca, cb = rgba(a), rgba(b)
    local function h(v) return string.format('%02X', math.floor(math.max(0, math.min(1, v)) * 255 + 0.5)) end
    return '#' .. h(ca[1] + (cb[1] - ca[1]) * t) .. h(ca[2] + (cb[2] - ca[2]) * t) .. h(ca[3] + (cb[3] - ca[3]) * t)
end

local COL = {
    Text = 0, TextDisabled = 1, WindowBg = 2, ChildBg = 3, PopupBg = 4, Border = 5, FrameBg = 7, FrameBgHovered = 8,
    FrameBgActive = 9, TitleBg = 10, TitleBgActive = 11, ScrollbarBg = 14, ScrollbarGrab = 15, ScrollbarGrabHovered = 16,
    ScrollbarGrabActive = 17, CheckMark = 18, SliderGrab = 19, SliderGrabActive = 20, Button = 21, ButtonHovered = 22,
    ButtonActive = 23, Header = 24, HeaderHovered = 25, HeaderActive = 26, Separator = 27,
}
local VAR = {
    WindowPadding = 2, WindowRounding = 3, WindowBorderSize = 4, ChildRounding = 7, PopupRounding = 9, FramePadding = 11,
    FrameRounding = 12, FrameBorderSize = 13, ItemSpacing = 14, ScrollbarSize = 18, ScrollbarRounding = 19, GrabRounding = 22,
}
local function theme_colors()
    return {
    { COL.Text, P.text }, { COL.TextDisabled, P.dim }, { COL.WindowBg, P.bg }, { COL.ChildBg, '#00000000' },
    { COL.PopupBg, P.glass }, { COL.Border, P.line }, { COL.FrameBg, P.well }, { COL.FrameBgHovered, '#0F121B' },
    { COL.FrameBgActive, '#131726' }, { COL.TitleBg, P.bg }, { COL.TitleBgActive, P.bg }, { COL.ScrollbarBg, '#00000000' },
    { COL.ScrollbarGrab, '#2A3147' }, { COL.ScrollbarGrabHovered, '#3A4361' }, { COL.ScrollbarGrabActive, P.accent },
    { COL.CheckMark, P.cyan }, { COL.SliderGrab, P.accent }, { COL.SliderGrabActive, P.cyan }, { COL.Button, P.card },
    { COL.ButtonHovered, P.card_hi }, { COL.ButtonActive, '#2A3150' }, { COL.Header, '#252D4A' },
    { COL.HeaderHovered, '#2F3A62' }, { COL.HeaderActive, '#394778' }, { COL.Separator, P.line },
    }
end
local THEME_COUNT = 25
-- NoTitleBar, NoResize, NoScrollbar, NoScrollWithMouse, NoCollapse, NoBackground
local WINDOW_FLAGS = 1 + 2 + 8 + 16 + 32 + 128
local NO_SAVE, NO_FOCUS = 256, 4096
local FIRST_USE_EVER = 4
local ALWAYS = 1
-- (ImGui's Escape is PAD.KEY.escape: this file is at LuaJIT's limit of 200 locals in a chunk)

local scale = 1
local function S(n) return n * scale end

-- the text sizes, at scale 1
local T = { title = 30, h1 = 22, h2 = 17, body = 15, small = 13, tiny = 11 }

-------------------------------------------------------------------------------
-- Fonts and icons
-------------------------------------------------------------------------------

-- Inter for the text, Rajdhani for the display sizes, ImGui's own (Agave with Font Awesome merged in) for the icons.
-- Added in the first frame the window draws, used from the next: ImGui takes a new font up between frames.
local F = { loaded = false, text = nil, semi = nil, bold = nil, disp = nil, dispb = nil, icons = nil }

local function load_fonts()
    local dir = vana.paths.addon .. '\\fonts\\'
    F.icons = imgui.GetFont()
    local function try(file, size)
        if not vana.fs.exists(dir .. file) then return nil end
        local ok, font = pcall(imgui.AddFontFromFileTTF, dir .. file, size)
        return ok and font or nil
    end
    F.text = try('Inter-Regular.ttf', 18) or F.icons
    F.semi = try('Inter-SemiBold.ttf', 18) or F.text
    F.bold = try('Inter-Bold.ttf', 18) or F.semi
    F.disp = try('Rajdhani-SemiBold.ttf', 24) or F.semi
    F.dispb = try('Rajdhani-Bold.ttf', 24) or F.disp
    F.loaded = true
end

-- Font Awesome 6 (the glyphs VanaCore's font carries), by name
local FA = {
    ['rotate-right'] = 0xF2F9, gear = 0xF013, bell = 0xF0A2, ['bell-slash'] = 0xF1F6, xmark = 0xF00D,
    ['window-minimize'] = 0xF2D1, ['magnifying-glass'] = 0xF002, ['user-plus'] = 0xF234, users = 0xF0C0,
    ['user-group'] = 0xF500, crown = 0xF521, dice = 0xF522, check = 0xF00C, ban = 0xF05E, comment = 0xF075,
    ['paper-plane'] = 0xF1D8, ['shield-halved'] = 0xF3ED, ['heart-pulse'] = 0xF21E, wand = 0xE2CA, bolt = 0xF0E7,
    star = 0xF005, ['chevron-down'] = 0xF078, ['chevron-right'] = 0xF054, ['circle-check'] = 0xF058,
    ['location-dot'] = 0xF3C5, ['hourglass-half'] = 0xF252, flag = 0xF024, compass = 0xF14E, sliders = 0xF1DE,
    ['volume-high'] = 0xF028, ['volume-xmark'] = 0xF6A9, filter = 0xF0B0, skull = 0xF54C, ['hat-wizard'] = 0xF6E8,
    ['people-group'] = 0xE533, ['right-to-bracket'] = 0xF2F6, ['user-check'] = 0xF4FC, ['user-xmark'] = 0xF235,
    clock = 0xF017, ['circle-info'] = 0xF05A, ['triangle-exclamation'] = 0xF071, trophy = 0xF091, gem = 0xF3A5,
    gamepad = 0xF11B, fire = 0xF7E4, ['circle-xmark'] = 0xF057, ['arrow-right'] = 0xF061, ellipsis = 0xF141,
    user = 0xF007, question = 0xF128, eye = 0xF06E, ['hourglass-end'] = 0xF253, bullhorn = 0xF0A1, coins = 0xF51E,
}
local fa_cache = {}
local function fa(name)
    local s = fa_cache[name]
    if s == nil then
        local c = FA[name] or FA.question
        s = string.char(224 + math.floor(c / 4096), 128 + math.floor(c / 64) % 64, 128 + c % 64)
        fa_cache[name] = s
    end
    return s
end

-- a string's size by font and size, cached (the window measures the same labels every frame)
local mcache = { by = {}, glyph = {}, scale = nil, n = 0 }
local function measure(str, font, size)
    font = font or F.text
    size = size or T.body
    if mcache.scale ~= scale or mcache.n > 4000 then mcache.by, mcache.glyph, mcache.scale, mcache.n = {}, {}, scale, 0 end
    local by_font = mcache.by[font]
    if by_font == nil then by_font = {} mcache.by[font] = by_font end
    local by_size = by_font[size]
    if by_size == nil then by_size = {} by_font[size] = by_size end
    local hit = by_size[str]
    if hit == nil then
        imgui.PushFont(font, S(size))
        local ok, w, h = pcall(imgui.CalcTextSize, str)
        imgui.PopFont()
        if not ok then w, h = 0, S(size) end
        hit = { w, h }
        by_size[str] = hit
        mcache.n = mcache.n + 1
    end
    return hit[1], hit[2]
end

-- runs fn with a font pushed, popping it whatever happens (an unbalanced font stack would stop the game)
local function with_font(font, size, fn, ...)
    imgui.PushFont(font or F.text, S(size or T.body))
    local results = { pcall(fn, ...) }
    imgui.PopFont()
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2)
end

-------------------------------------------------------------------------------
-- Textures: the original Party Finder's sheets, through VanaCore's D3DX on the game's device
-------------------------------------------------------------------------------

local TEX = { jobs = nil, modes = nil, beacon = nil, gem = nil, holders = {}, custom = {} }
-- the CatsEyeXI gem (images\gem.png): every frame of the server's animated avatar, 128 px cells in an 11x11 grid
local GEM = { cols = 11, rows = 11, frames = 118, fps = 50 }
local ffi_ok, ffi = pcall(require, 'ffi')
local device = nil

-- a texture from a file on the game's device: the pointer, or nil
local function load_texture(key, path)
    if not ffi_ok or ffi == nil or device == nil or not vana.fs.exists(path) then return nil end
    local holder = ffi.new('void*[1]')
    local made, hr = pcall(function () return ffi.C.D3DXCreateTextureFromFileA(ffi.cast('void*', device), path, holder) end)
    if made and hr == 0 and holder[0] ~= nil then
        TEX.holders[key] = holder
        return holder[0]
    end
    return nil
end

local function load_textures()
    if not ffi_ok or ffi == nil or vana.ashita == nil or vana.ashita.object == nil then return end
    pcall(ffi.cdef, 'long __stdcall D3DXCreateTextureFromFileA(void* device, const char* file, void** texture);')
    device = vana.ashita.object('device')
    if device == nil then return end
    local function load(name, file)
        TEX[name] = load_texture(name, vana.paths.addon .. '\\images\\' .. file)
    end
    load('jobs', 'jobs.png')
    load('modes', 'modes.png')
    load('beacon', 'lfg.png')
    load('gem', 'gem.png')
end

local function release_textures()
    if not ffi_ok then return end
    for name, holder in pairs(TEX.holders) do
        pcall(function ()
            local vtable = ffi.cast('void**', holder[0])[0]
            ffi.cast('long(__stdcall**)(void*)', vtable)[2](holder[0]) -- IUnknown::Release
        end)
        TEX[name] = nil
    end
    TEX.holders = {}
    TEX.custom = {}
end

-- a cell of a horizontal sheet
local function sprite(dl, tex, cells, cell, x, y, w, h, alpha)
    if tex == nil or cell == nil then return false end
    local u0, u1 = cell / cells, (cell + 1) / cells
    dl:AddImage(tex, { x, y }, { x + w, y + h }, { u0, 0 }, { u1, 1 }, u32('#FFFFFF', alpha or 1))
    return true
end

-- a round picture: a cell of a grid texture, clipped to a circle
local function round_cell(dl, tex, cols, rows, cell, cx, cy, size, alpha)
    local col, row = cell % cols, math.floor(cell / cols)
    local u0, v0 = col / cols, row / rows
    dl:AddImageRounded(tex, { cx - size / 2, cy - size / 2 }, { cx + size / 2, cy + size / 2 },
        { u0, v0 }, { u0 + 1 / cols, v0 + 1 / rows }, u32('#FFFFFF', alpha or 1), size / 2)
end

-- the gem, turning: the frame for the moment, with the next one faded in over it so slow play stays smooth.
-- speed 1 is the avatar's own pace; 0 holds the first frame.
local function gem(dl, cx, cy, size, t, speed, alpha)
    if TEX.gem == nil then return false end
    alpha = alpha or 1
    local f = t * GEM.fps * (speed or 1)
    local i = math.floor(f)
    local frac = f - i
    if alpha >= 0.99 then
        round_cell(dl, TEX.gem, GEM.cols, GEM.rows, i % GEM.frames, cx, cy, size, alpha)
        if frac > 0.02 and (speed or 1) > 0 then
            round_cell(dl, TEX.gem, GEM.cols, GEM.rows, (i + 1) % GEM.frames, cx, cy, size, frac)
        end
    else
        round_cell(dl, TEX.gem, GEM.cols, GEM.rows, math.floor(f + 0.5) % GEM.frames, cx, cy, size, alpha)
    end
    return true
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local st = {
    open = false, mini = false, tab = 2, filter = 0, search = { '' },
    entries = {}, members = {}, pending = nil, pending_members = nil,
    registered = false, reg = { type = 1, category = 1, auto = false, min = 0 },
    pfp = nil, daily = nil, mode = nil,
    ping_since = nil, ping_retries = 0, disabled = false, last_refresh = 0,
    gen = 0, server_version = nil, features = nil, blocks_synced = false,
    requests = {}, pending_join = nil,
    roulette = nil, mission_select = nil, duty = { name = '', phase = 0 },
    venture = nil,
    create = nil, confirm = nil, tell = nil, settings_open = false,
    hover = {}, toasts = {}, anim = {}, ripples = {}, pops = {}, counts_seen = {}, bell_at = -10, list_at = 0, toggle_anim = {}, icons = nil, backgrounds = nil, card_alpha = 1, settings_page = 'general', tour = nil, tour_anchor = {}, compact = false,
    summary_shown = false, cs_hidden = false, was_open = nil,
    last_error = nil, counts = { pin = 0, pout = 0 },
    orb = { x = nil, y = nil }, main = nil, bound = false, opened_at = 0, was_shown = false,
}

local settings = {
    notify = true, confirm_withdraw = true, joinable_only = false, sounds = true, opacity = 0.96, scale = 100,
    keybind = '^G', blacklist = {}, mini = false, icon = 'flag', sound_pack = 'classic', logo_motion = 'slow', background = 'none', bg_opacity = 0.35, theme = 'aurora', pins = {}, tour_done = false, start_mini = false, handheld = 'auto',
}
local LOGO_SPEED = { off = 0, slow = 0.35, full = 1 }

local function fail(where, err)
    st.last_error = where .. ': ' .. tostring(err)
    vana.log('partyfinder-vanacore ' .. st.last_error)
end

local function say(text)
    vana.chat.write('[PartyFinder] ' .. text, 29)
end

local function clock() return vana.time.clock() end

-------------------------------------------------------------------------------
-- The character and the party
-------------------------------------------------------------------------------

local function me()
    local ok, party = pcall(vana.game.party)
    if not ok or party == nil then return nil end
    return party.members and party.members[1] or nil
end

local function my_name()
    local m = me()
    return m and m.name or ''
end

local function logged_in()
    local m = me()
    return m ~= nil and m.name ~= nil and m.name ~= '' and (m.zone or 0) > 0
end

local function party_info()
    local ok, party = pcall(vana.game.party)
    if not ok or party == nil then return 1, true end
    local count = party.party_counts and party.party_counts[1] or 1
    local mine = party.members and party.members[1]
    local leader_id = party.party_leaders and party.party_leaders[1] or 0
    if count <= 1 then return 1, true end
    return count, mine ~= nil and (leader_id == 0 or leader_id == mine.id)
end

local function leader_or_solo()
    local _, leader = party_info()
    return leader
end

local function in_event()
    local m = me()
    if m == nil then return false end
    local ok, e = pcall(vana.game.entity, m.target_index)
    return ok and e ~= nil and e.status == 4
end

local function zone_name(id)
    if id == nil or id == 0 then return '' end
    local ok, name = pcall(vana.ashita.string, 'zones.names', id)
    return ok and name or ('Zone ' .. id)
end

local function job_str(job, level, sub, slevel)
    local s = (JOBS[job or 0] or '???') .. (level or 0)
    if sub and sub > 0 then s = s .. '/' .. (JOBS[sub] or '???') .. (slevel or 0) end
    return s
end

-- the addon's own sounds\, or the original Party Finder's beside it
-- the sound packs: each folder under sounds\ (classic = the original set, glass = a synthesized one)
local function sound_packs()
    local list = {}
    local ok, names = pcall(vana.fs.list, vana.paths.addon .. '\\sounds', '.*', 'dirs')
    if ok and type(names) == 'table' then
        table.sort(names, function (a, b) return a:lower() < b:lower() end)
        for _, n in ipairs(names) do list[#list + 1] = { id = n:lower(), name = n:sub(1, 1):upper() .. n:sub(2) } end
    end
    if #list == 0 then list[1] = { id = 'classic', name = 'Classic' } end
    return list
end

local function play(name, force)
    if not settings.sounds and not force then return end
    local pack = settings.sound_pack or 'classic'
    local dirs = { vana.paths.addon .. '\\sounds\\' .. pack .. '\\', vana.paths.addon .. '\\sounds\\classic\\',
        vana.paths.addon .. '\\sounds\\', vana.paths.addons .. '\\ashita\\partyfinder\\sounds\\' }
    -- a pack without the newer sounds plays its nearest older one
    local alt = ({ announce = 'join_request', join_denied = 'withdraw', ready = 'register' })[name]
    for _, n in ipairs({ name, alt }) do
        for _, dir in ipairs(dirs) do
            local path = dir .. n .. '.wav'
            if vana.fs.exists(path) then
                pcall(vana.system.play_sound, path)
                return true
            end
        end
    end
    return false
end

-------------------------------------------------------------------------------
-- Settings: config\addons\lfg\<character>.lua
-------------------------------------------------------------------------------

local function settings_dir() return vana.paths.install .. '\\config\\addons\\partyfinder-vanacore' end
local function settings_file() return settings_dir() .. '\\' .. (my_name() ~= '' and my_name() or 'default') .. '.lua' end
-- where the lfg builds kept them
local function old_settings_file() return vana.paths.install .. '\\config\\addons\\lfg\\' .. (my_name() ~= '' and my_name() or 'default') .. '.lua' end

local function serialize(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then return string.format('%q', v) end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if t == 'table' then
        local parts = {}
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = indent .. '  [' .. serialize(k) .. '] = ' .. serialize(v[k], indent .. '  ') .. ','
        end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

local function save_settings()
    if not vana.fs.exists(settings_dir()) then vana.fs.create_dir(settings_dir()) end
    local f = io.open(settings_file(), 'wb')
    if f == nil then return end
    f:write('-- lfg settings; written by the addon\nreturn ' .. serialize(settings) .. '\n')
    f:close()
end

local function load_settings()
    st.settings_for = my_name()
    local f = io.open(settings_file(), 'rb') or io.open(old_settings_file(), 'rb')
    if f == nil then
        -- a first run: sized for the screen, since 100% is tiny on a 4K or Retina one
        local okscr, _, sh = pcall(vana.ui.screen)
        if okscr and type(sh) == 'number' and sh > 0 then
            settings.scale = math.max(100, math.min(250, math.floor(sh / 1080 * 10 + 0.5) * 10))
        end
        return
    end
    local text = f:read('*a')
    f:close()
    local chunk = loadstring(text)
    if chunk == nil then return end
    local ok, saved = pcall(chunk)
    if ok and type(saved) == 'table' then
        for k, v in pairs(saved) do settings[k] = v end
    end
    -- the beacon or the window as it was left (kept in settings.mini), or the beacon when "Start as the beacon" says so
    st.mini = settings.start_mini == true or settings.mini == true
    load_theme_files()
    apply_theme(settings.theme or 'aurora')
end

-- the look as one line, for sharing: lfg1|theme=ember|art=cexi_ember|icon=gem|artop=35|win=96|logo=slow
local function look_string()
    return string.format('lfg1|theme=%s|art=%s|icon=%s|artop=%d|win=%d|logo=%s', settings.theme or 'aurora', settings.background or 'none',
        settings.icon or 'beacon', math.floor((settings.bg_opacity or 0.35) * 100 + 0.5), math.floor((settings.opacity or 0.96) * 100 + 0.5), settings.logo_motion or 'slow')
end

local function apply_look(text)
    text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if text:sub(1, 5) ~= 'lfg1|' then return false, "that isn't a look string (it starts with lfg1|)" end
    local got = {}
    for pair in text:sub(6):gmatch('[^|]+') do
        local k, v = pair:match('^(%w+)=(.*)$')
        if k then got[k] = v end
    end
    if got.theme and THEME_BY_ID[got.theme] then apply_theme(got.theme) settings.theme = got.theme end
    if got.art then settings.background = got.art end
    if got.icon then settings.icon = got.icon end
    if tonumber(got.artop) then settings.bg_opacity = math.max(0, math.min(1, tonumber(got.artop) / 100)) end
    if tonumber(got.win) then settings.opacity = math.max(0.3, math.min(1, tonumber(got.win) / 100)) end
    if got.logo and LOGO_SPEED[got.logo] then settings.logo_motion = got.logo end
    save_settings()
    return true
end

-- picks a theme: its palette, and its art (with the art opacity it looks best at) unless told to keep the art
local function set_theme(id, keep_art)
    local theme = apply_theme(id)
    settings.theme = theme.id
    if not keep_art then
        settings.background = theme.art
        if theme.art ~= 'none' and (settings.bg_opacity or 0) < 0.2 then settings.bg_opacity = 0.35 end
    end
    save_settings()
end

-------------------------------------------------------------------------------
-- Bytes
-------------------------------------------------------------------------------

local function bytes_of(e)
    local d = e.data_modified or e.data
    local t = type(d)
    if t == 'string' then return d end
    if t == 'table' then
        local out = {}
        for i = 1, #d do out[i] = string.char(d[i] % 256) end
        return table.concat(out)
    end
    if (t == 'cdata' or t == 'userdata') and e.size then
        local ok, s = pcall(function () return require('ffi').string(d, e.size) end)
        if ok then return s end
    end
    return nil
end

local function u8(d, off) return d:byte(off + 1) or 0 end
local function u16(d, off) return u8(d, off) + u8(d, off + 1) * 256 end
local function rd32(d, off) return u16(d, off) + u16(d, off + 2) * 65536 end
local function str(d, off, len)
    local s = d:sub(off + 1, off + len)
    local z = s:find('\0', 1, true)
    if z then s = s:sub(1, z - 1) end
    return s
end

local function packet(action, fields)
    local b = {}
    for i = 1, 72 do b[i] = 0 end
    b[1], b[2] = 0xA2, 0x25
    b[5] = action
    for off, v in pairs(fields or {}) do
        if type(v) == 'string' then
            for i = 1, #v do b[off + i] = v:byte(i) end
        else
            b[off + 1] = v % 256
        end
    end
    local out = {}
    for i = 1, 72 do out[i] = string.char(b[i]) end
    st.counts.pout = st.counts.pout + 1
    vana.packets.inject(false, PACKET_ID, table.concat(out))
end

local function send(action, category, content_id, role, listing_type, auto, min_level, comment)
    comment = (comment or ''):sub(1, 60)
    packet(action, {
        [0x05] = category or 0, [0x06] = (content_id or 0) % 256, [0x07] = math.floor((content_id or 0) / 256),
        [0x08] = role or 0, [0x09] = listing_type or 1, [0x0A] = auto or 0, [0x0B] = min_level or 0, [0x0C] = comment,
    })
end

-- a REFRESH says what we speak and the generation we hold; a v1 server ignores the extra bytes
local function send_refresh(retry)
    if not logged_in() then return end
    st.ping_since = clock()
    if not retry then st.ping_retries = 0 end
    st.last_refresh = clock()
    local g = st.gen or 0
    packet(C2S.REFRESH, {
        [0x06] = LIMITS.version, [0x07] = settings.notify and 1 or 0,
        [0x08] = g % 256, [0x09] = math.floor(g / 256) % 256, [0x0A] = math.floor(g / 65536) % 256, [0x0B] = math.floor(g / 16777216) % 256,
    })
end

-- presence: a PONG carries the server's generation, and we refresh only if it moved
local function send_ping()
    if not logged_in() then return end
    st.ping_since = clock()
    st.ping_retries = 0
    st.last_refresh = clock()
    packet(C2S.PING)
end

local function send_join_request(name, role)
    packet(C2S.JOIN_REQUEST, { [0x05] = role or 0, [0x08] = name:sub(1, 16) })
end

local function send_join_respond(name, accept, reason, message)
    packet(C2S.JOIN_RESPOND, { [0x05] = accept and 1 or 0, [0x06] = reason or 0, [0x08] = name:sub(1, 16), [0x18] = (message or ''):sub(1, 48) })
end

-------------------------------------------------------------------------------
-- Listings
-------------------------------------------------------------------------------

local function toast(kind, title, body, seconds, icon)
    st.toasts[#st.toasts + 1] = { kind = kind, title = title, body = body, at = clock(), life = seconds or 4, anim = 0, icon = icon }
end

local function visible(entry)
    if entry.type == st.tab or st.tab == 0 then
        if st.filter ~= 0 and entry.category ~= st.filter then return false end
        if settings.joinable_only and entry.name ~= my_name() then -- never my own listing
            if entry.type == 2 and (entry.party_size or 1) >= 6 then return false end
            if entry.type == 2 and entry.has_slots then
                local m = me()
                if m and SLOTS.fit(entry, m.main_job) == nil then return false end
            end
            if st.mode ~= nil and entry.mode ~= nil and (st.mode == 1 or entry.mode == 1) and st.mode ~= entry.mode then return false end
        end
        local q = (st.search[1] or ''):lower()
        if q ~= '' then
            local hay = (entry.name .. ' ' .. (entry.comment or '') .. ' ' .. (JOBS[entry.job] or '') .. ' ' .. zone_name(entry.zone)):lower()
            if not hay:find(q, 1, true) then return false end
        end
        return true
    end
    return false
end

local function count_type(t)
    local n = 0
    for _, e in ipairs(st.entries) do if e.type == t then n = n + 1 end end
    return n
end

local function compatible(mode)
    if st.mode == nil or mode == nil then return true end
    if st.mode == 1 or mode == 1 then return st.mode == mode end
    return true
end

-------------------------------------------------------------------------------
-- Incoming
-------------------------------------------------------------------------------

local function on_entry(d)
    local entry = {
        category = u8(d, 0x05), job = u8(d, 0x06), level = u8(d, 0x07), zone = u16(d, 0x08), content = u16(d, 0x0A),
        id = rd32(d, 0x0C), name = str(d, 0x10, 16), comment = str(d, 0x20, 64), role = u8(d, 0x60) <= 4 and u8(d, 0x60) or 0, -- (0 to 4: another client can send anything)
        type = u8(d, 0x61), party_size = u8(d, 0x62), auto = u8(d, 0x63), min_level = u8(d, 0x64),
        sub = u8(d, 0x65), sub_level = u8(d, 0x66), mode = u8(d, 0x67),
        tanks = u8(d, 0x68), healers = u8(d, 0x69), supports = u8(d, 0x6A), dps = u8(d, 0x6B),
    }
    if #d >= 0x78 then -- v2
        entry.max_players, entry.wanted, entry.registered_at, entry.expires_at = u8(d, 0x6C), u8(d, 0x6D), rd32(d, 0x70), rd32(d, 0x74)
    end
    if #d >= 0x90 then -- v2: the open slots and which are filled
        entry.slots, entry.filled, entry.has_slots = {}, u8(d, 0x8C), false
        for i = 1, SLOTS.n do
            entry.slots[i] = rd32(d, 0x78 + (i - 1) * 4)
            if entry.slots[i] ~= 0 then entry.has_slots = true end
        end
    end
    if entry.type == 0 then entry.type = 1 end
    local list = st.pending or st.entries
    -- the members that follow replace the old set
    local members = st.pending_members or st.members
    members[entry.id] = nil
    for i, e in ipairs(list) do
        if e.id == entry.id then list[i] = entry return end
    end
    list[#list + 1] = entry
end

local function on_party_member(d)
    local leader = rd32(d, 0x0C)
    local members = st.pending_members or st.members
    members[leader] = members[leader] or {}
    local m = members[leader]
    m[#m + 1] = { job = u8(d, 0x05), level = u8(d, 0x06), sub = u8(d, 0x07), sub_level = u8(d, 0x08), name = str(d, 0x10, 16) }
end

local function on_end_list(d)
    if st.pending then
        st.entries, st.members = st.pending, st.pending_members or {}
        st.pending, st.pending_members = nil, nil
        st.list_at = clock()
    end
    -- a pinned party with a slot that just opened
    st.pin_sizes = st.pin_sizes or {}
    for _, e in ipairs(st.entries) do
        local key = e.name:lower()
        if settings.pins[key] and e.type == 2 then
            local was = st.pin_sizes[key]
            if was ~= nil and (e.party_size or 1) < was and (e.party_size or 1) < 6 then
                st.pin_alert_at = clock()
                toast('accent', 'Slot open', string.format("%s's party is %d/6", e.name, e.party_size or 1), 8, 'star')
                say(string.format("A slot opened in %s's party (%d/6).", e.name, e.party_size or 1))
                play('announce')
            end
            st.pin_sizes[key] = e.party_size or 1
        end
    end
    if #d >= 0x0E then
        st.pfp, st.daily, st.mode = rd32(d, 0x08), u8(d, 0x0C), u8(d, 0x0D)
    end
    if #d >= 0x14 then -- v2: the server's version and the generation we now hold
        st.server_version, st.gen = u8(d, 0x0E), rd32(d, 0x10)
        st.counts.last_flags = u8(d, 0x0F)
        if not st.blocks_synced then
            -- the blocklist lives on the server too, so blocked players never reach us
            st.blocks_synced = true
            for n in pairs(settings.blacklist or {}) do packet(C2S.BLOCK, { [0x05] = 1, [0x08] = n:sub(1, 16) }) end
        end
    end
    local name = my_name()
    local mine = nil
    for _, e in ipairs(st.entries) do if e.name == name then mine = e end end
    if mine then
        st.registered = true
        st.reg = { type = mine.type, category = mine.category, auto = mine.auto == 1, min = mine.min_level }
    elseif st.registered and mine == nil then
        st.registered = false
    end
    -- a request waiting on a party whose listing is gone (withdrawn, or the party filled): it won't be answered
    -- (a few seconds' grace, for a list that was on its way when the request went out)
    local pj = st.pending_join
    if pj and clock() - pj.at > 5 then
        local still = false
        for _, e in ipairs(st.entries) do if e.name:lower() == pj.name then still = true break end end
        if not still then
            toast('dim', pj.display .. "'s listing is gone", 'Your request ends with it. Try another party', 6, 'hourglass-end')
            st.pending_join = nil
        end
    end
    if not st.summary_shown and settings.notify and #st.entries > 0 then
        st.summary_shown = true
        local lfg, lfm = count_type(1), count_type(2)
        say(string.format('%d player%s looking for group, %d group%s recruiting. /pf opens the finder.',
            lfg, lfg == 1 and '' or 's', lfm, lfm == 1 and '' or 's'))
    end
end

local function on_join_request(d)
    local req = { job = u8(d, 0x05), level = u8(d, 0x06), role = u8(d, 0x07) <= 4 and u8(d, 0x07) or 0, name = str(d, 0x08, 16), at = clock() }
    if settings.blacklist[req.name:lower()] then
        send_join_respond(req.name, false, 2, 'You are blocked.')
        return
    end
    -- my own listing, for its slots
    local mine = nil
    for _, e in ipairs(st.entries) do if e.name == my_name() then mine = e end end
    if mine and mine.has_slots then
        local sl = SLOTS.fit(mine, req.job)
        req.fit = sl and ('fits slot ' .. sl.i .. '  ·  ' .. SLOTS.label(sl.mask, false, 3)) or ('no open slot for ' .. (JOBS[req.job] or '?'))
        req.fits = sl ~= nil
    end
    if st.registered and st.reg.type == 2 and st.reg.auto then
        if st.reg.min > 0 and req.level < st.reg.min then
            send_join_respond(req.name, false, 1, string.format('Level too low (minimum: %d)', st.reg.min))
            say(string.format('Denied %s: level %d below minimum %d', req.name, req.level, st.reg.min))
        elseif req.fits == false then
            send_join_respond(req.name, false, 3, 'No open slot for ' .. (JOBS[req.job] or 'your job'))
            say(string.format('Denied %s: no open slot for %s', req.name, JOBS[req.job] or '?'))
        else
            send_join_respond(req.name, true, 0, '')
            say(string.format('%s (%s, %s) joined via Party Finder', req.name, job_str(req.job, req.level), ROLES[req.role].name))
            toast('ok', req.name .. ' joined', job_str(req.job, req.level) .. '  ·  ' .. ROLES[req.role].name, 5, 'user-check')
            play('join_accepted')
        end
        return
    end
    for i = #st.requests, 1, -1 do
        if st.requests[i].name:lower() == req.name:lower() then table.remove(st.requests, i) end
    end
    req.anim = 0
    st.requests[#st.requests + 1] = req
    st.bell_at = clock()
    packet(C2S.JOIN_SEEN, { [0x08] = req.name:sub(1, 16) })
    say(string.format('%s (%s, %s) wants to join your party.', req.name, job_str(req.job, req.level), ROLES[req.role].name))
    play('join_request')
end

local function on_roulette_duty(d)
    local follower = u8(d, 0x0D) == 1
    local duty = {
        tier = u8(d, 0x05), cap = u8(d, 0x06), source = u8(d, 0x07) == 1 and 'mission' or 'roulette', id = u16(d, 0x08),
        zone = u16(d, 0x0A), size = u8(d, 0x0C), name = str(d, 0x10, 48), leader = follower and str(d, 0x40, 16) or nil,
        is_leader = not follower, ready = {}, ready_count = follower and 0 or 1, total = u8(d, 0x0C),
        my_ready = not follower, timeout = clock() + LIMITS.ready, at = clock(),
    }
    if st.roulette and st.roulette.id == duty.id then return end
    duty.label = duty.source == 'mission' and 'Mission Help' or 'Duty Roulette'
    st.roulette = duty
    st.mission_select = nil
    if follower then
        say(string.format('%s started %s: %s', duty.leader, duty.label, duty.name))
    else
        say(string.format('%s: %s (Level %d cap)', duty.label, duty.name, duty.cap))
    end
    play('roulette_roll')
end

-- a new LFM listing, as a packet (v2) instead of the server's chat line
local function on_announce(d)
    if not settings.notify then return end
    local a = { category = u8(d, 0x05), level = u8(d, 0x06), mode = u8(d, 0x07), name = str(d, 0x08, 16), comment = str(d, 0x18, 48) }
    if a.name:lower() == my_name():lower() then return end
    local cat = CATEGORY[a.category]
    local what = cat and cat.name or 'party'
    toast('accent', a.name .. ' is recruiting', string.format('%s  ·  Lv %d%s', what, a.level, a.comment ~= '' and ('  ·  ' .. a.comment) or ''), 6, 'bullhorn')
    play('announce')
    say(string.format('%s is recruiting: %s Lv%d%s%s', a.name, what, a.level, a.mode == 1 and ' [CW]' or '', a.comment ~= '' and (' - ' .. a.comment) or ''))
end

local function on_packet(e)
    local d = bytes_of(e)
    if d == nil then return end
    st.counts.pin = st.counts.pin + 1
    st.ping_since, st.ping_retries, st.disabled = nil, 0, false
    local action = u8(d, 0x04)
    if action == S2C.CLEAR then
        st.pending, st.pending_members = {}, {}
    elseif action == S2C.ENTRY then
        on_entry(d)
    elseif action == S2C.PARTY_MEMBER then
        on_party_member(d)
    elseif action == S2C.ENTRY_REMOVE then
        st.counts.removes = (st.counts.removes or 0) + 1
        local id = rd32(d, 0x08)
        local list = st.pending or st.entries
        for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
        local members = st.pending_members or st.members
        members[id] = nil
    elseif action == S2C.PONG then
        st.server_version, st.features = u8(d, 0x05), u8(d, 0x06)
        if rd32(d, 0x08) ~= st.gen then send_refresh() end
    elseif action == S2C.ANNOUNCE then
        on_announce(d)
    elseif action == S2C.JOIN_SEEN then
        local leader = str(d, 0x08, 16)
        local pj = st.pending_join
        if pj and pj.name == leader:lower() and not pj.seen then
            pj.seen = clock()
            toast('accent', leader .. ' saw your request', 'Waiting on their answer', 4, 'eye')
        end
    elseif action == S2C.END_LIST then
        on_end_list(d)
    elseif action == S2C.ACK_REGISTER then
        st.registered = true
        say('You are now registered.')
        toast('ok', 'Registered', st.reg.type == 2 and 'Recruiting members' or 'Looking for a group', 4, 'circle-check')
        st.tab = st.reg.type == 2 and 1 or 2
        send_refresh()
    elseif action == S2C.ACK_WITHDRAW then
        st.registered = false
        say('Registration withdrawn.')
        toast('dim', 'Withdrawn', 'Your listing is gone', 4, 'circle-xmark')
        send_refresh()
    elseif action == S2C.LISTINGS_CHANGED then
        send_refresh()
    elseif action == S2C.ROULETTE_DUTY then
        on_roulette_duty(d)
    elseif action == S2C.ROULETTE_ERR then
        local code, msg = u8(d, 0x05), str(d, 0x08, 56)
        say(msg)
        if code == V2.rate_error then
            toast('warn', 'Not so fast', msg, 4, 'clock')
        else
            toast('danger', 'Party Finder', msg, 6, 'triangle-exclamation')
        end
    elseif action == S2C.ROULETTE_OK then
        if st.roulette then
            st.duty = { name = st.roulette.name, phase = 1 }
            say(st.roulette.label .. ' commenced! Teleporting to the battlefield...')
            toast('ok', 'Commencing', st.roulette.name, 6, 'dice')
            st.roulette = nil
            play('join_accepted')
        end
    elseif action == S2C.MISSION_ENTRY then
        st.mission_select = st.mission_select or { entries = {}, open = false }
        local m = st.mission_select.entries
        m[#m + 1] = { cap = u8(d, 0x06), max = u8(d, 0x07), id = u16(d, 0x08), zone = u16(d, 0x0A), name = str(d, 0x10, 48) }
    elseif action == S2C.MISSION_END then
        st.mission_select = st.mission_select or { entries = {} }
        st.mission_select.open = true
    elseif action == S2C.READY_UPDATE then
        local name = str(d, 0x05, 16)
        if st.roulette and not st.roulette.ready[name:lower()] then
            st.roulette.ready[name:lower()] = true
            st.roulette.ready_count = st.roulette.ready_count + 1
            say(string.format('%s is ready! (%d/%d)', name, st.roulette.ready_count, st.roulette.total))
            play('ready')
        end
    elseif action == S2C.JOIN_REQUEST then
        on_join_request(d)
    elseif action == S2C.JOIN_RESULT then
        local accepted, reason, leader, msg = u8(d, 0x05) == 1, u8(d, 0x06), str(d, 0x08, 16), str(d, 0x18, 48)
        if accepted then
            say(leader .. ' accepted your join request!')
            toast('ok', 'Accepted', leader .. ' is inviting you', 5, 'user-check')
            play('join_accepted')
        elseif reason == V2.timeout then
            if st.pending_join then
                say(leader .. " didn't answer your request.")
                toast('dim', 'No answer from ' .. leader, 'They may be away. Try another party', 6, 'hourglass-end')
                play('join_denied')
            end
            st.pending_join = nil
        elseif reason == V2.rate then
            toast('warn', 'Not so fast', 'Give ' .. leader .. ' a moment before asking again', 5, 'clock')
            st.pending_join = nil
        else
            say(string.format('%s denied your request: %s', leader, msg ~= '' and msg or 'No reason given'))
            toast('danger', 'Denied by ' .. leader, msg ~= '' and msg or 'No reason given', 6, 'user-xmark')
            play('join_denied')
            st.pending_join = nil
        end
    elseif action == S2C.DUTY_DECLINE then
        local name = str(d, 0x05, 16)
        if st.roulette then
            say(string.format('%s declined. %s cancelled.', name, st.roulette.label))
            toast('danger', name .. ' declined', st.roulette.label .. ' cancelled', 5, 'user-xmark')
            st.roulette = nil
        end
    end
end

local function on_venture(e)
    local d = bytes_of(e)
    if d == nil or #d < 0x54 then return end
    local v = { version = u8(d, 0x04), mode = u8(d, 0x05), pools = { {}, {} }, at = clock() }
    for p = 1, 2 do
        local base = p == 1 and 0x08 or 0x2C
        for tier = 1, 6 do
            local off = base + (tier - 1) * 6
            v.pools[p][tier] = { ace = u16(d, off), cw = u16(d, off + 2), progress = u8(d, off + 4), star = u8(d, off + 5) % 2 == 1 }
        end
    end
    v.hvnm = { zone = u16(d, 0x50), progress = u8(d, 0x52), star = u8(d, 0x53) % 2 == 1 }
    v.hvnm.spawned = v.hvnm.progress >= 200
    st.venture = v
end

local function on_invite(e)
    if st.registered and st.reg.type == 1 then play('join_request') end
    if st.pending_join == nil then return end
    local d = bytes_of(e)
    if d == nil then return end
    local inviter = str(d, 0x0C, 16)
    if inviter:lower() == st.pending_join.name then
        vana.packets.inject(false, 0x074, '\x74\x04\0\0\x01\0\0\0')
        say('Auto-accepted party invite from ' .. inviter)
        toast('ok', 'Joined ' .. inviter, 'Invite accepted for you', 4, 'right-to-bracket')
        st.pending_join = nil
        e.blocked = true
        return true
    end
end

local function on_zone_in()
    if st.roulette then
        st.duty = { name = st.roulette.name, phase = 1 }
        st.roulette = nil
    end
    if st.duty.phase == 1 then
        st.duty.phase = 2
    elseif st.duty.phase == 2 then
        st.duty = { name = '', phase = 0 }
        toast('ok', 'Duty complete', 'Welcome back', 5, 'trophy')
    end
    if st.was_open ~= nil then
        st.open = st.was_open
        st.was_open = nil
    end
    vana.tasks.once(3, function () if st.open then send_refresh() end end)
end

local function on_zone_out(e)
    local d = bytes_of(e)
    local zoning = d ~= nil and u8(d, 0x04) == 2
    if st.open then st.was_open = true end
    st.open = false
    st.ping_since = nil
    st.gen = 0
    if not zoning then
        st.duty = { name = '', phase = 0 }
        st.roulette = nil
        st.requests = {}
    end
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function do_register(c)
    local auto = (c.type == 2 and c.auto) and 1 or 0
    local min = auto == 1 and math.max(1, math.min(75, c.min)) or 0
    st.reg = { type = c.type, category = c.category, auto = auto == 1, min = min }
    send(C2S.REGISTER, c.category, 0, c.role, c.type, auto, min, c.comment[1] or '')
    if c.type == 2 and c.slots then
        local masks = {}
        local party_n = party_info()
        for i = 1, SLOTS.n do masks[i] = (i <= 6 - party_n) and (c.slots[i] or 0) or 0 end
        st.reg.slots = masks
        if SLOTS.any(masks) then packet(C2S.SET_SLOTS, { [0x08] = SLOTS.bytes(masks) }) end
    end
    play('register')
end

local function do_withdraw()
    send(C2S.WITHDRAW)
    play('withdraw')
end

local function do_join(entry, role)
    send_join_request(entry.name, role or 0)
    st.pending_join = { name = entry.name:lower(), display = entry.name, at = clock(), seen = nil, anim = 0 }
    local m = me()
    say(string.format('Join request sent to %s (%s, %s)', entry.name, job_str(m and m.main_job, m and m.main_job_level), ROLES[role or 0].name))
    toast('accent', 'Request sent', 'Waiting on ' .. entry.name, 4, 'paper-plane')
end

local function do_invite(entry)
    vana.chat.run('/pcmd add ' .. entry.name, 1)
    toast('accent', 'Invited', entry.name, 4, 'user-plus')
end

local function respond(i, accept)
    local req = st.requests[i]
    if req == nil then return end
    send_join_respond(req.name, accept, 0, accept and '' or 'Request denied')
    say((accept and 'Accepted ' or 'Denied ') .. req.name)
    table.remove(st.requests, i)
end

local function set_block(name, on)
    settings.blacklist[name:lower()] = on and true or nil
    save_settings()
    if logged_in() then packet(C2S.BLOCK, { [0x05] = on and 1 or 0, [0x08] = name:sub(1, 16) }) end
    say(on and ('Blocked ' .. name .. ' from join requests') or ('Unblocked ' .. name))
end

-- the Ashita partyfinder answers the same packets and the same /pf: one of us has to go
local function unload_old_finder()
    local ok, list = pcall(vana.addons.loaded)
    if not ok or type(list) ~= 'table' then return end
    for _, entry in pairs(list) do
        local name = type(entry) == 'table' and (entry.name or entry[1]) or entry
        if type(name) == 'string' and name:lower() == 'partyfinder' then
            vana.chat.run('/addon unload partyfinder', 1)
            if not st.old_unloaded then
                st.old_unloaded = true
                say('The Ashita Party Finder was unloaded: this one takes its place (and its /pf).')
            end
            return
        end
    end
end

local function ensure_bind()
    if st.bound or settings.keybind == '' then return end
    local ok, list = pcall(vana.binds.list)
    if ok and list then
        for _, b in ipairs(list) do
            if b.spec == settings.keybind then
                -- someone else's key: left alone. Ours already: bound again all the same, because on a reload the
                -- unloading copy's /unbind is queued and runs after this load, which would leave the key unbound
                if not (type(b.command) == 'string' and b.command:find('/pf', 1, true)) then return end
                break
            end
        end
    end
    vana.chat.run('/bind ' .. settings.keybind .. ' /pf', 1)
    st.bound = true
end

-------------------------------------------------------------------------------
-- Drawing helpers
-------------------------------------------------------------------------------

local function lerp(a, b, t) return a + (b - a) * t end
local function ease(t) t = math.max(0, math.min(1, t)) return 1 - (1 - t) * (1 - t) * (1 - t) end
local function spring(t) t = math.max(0, math.min(1, t)) return 1 + 0.35 * math.sin(t * math.pi) * (1 - t) end
local dt = 0.016
local now_t = 0

local function text(dl, x, y, str, color, font, size, alpha)
    dl:AddText(font or F.text, S(size or T.body), { x, y }, u32(color, alpha), str)
end

-- text with its middle on cy
local function text_mid(dl, x, cy, str, color, font, size, alpha)
    local _, h = measure(str, font, size)
    text(dl, x, cy - h / 2, str, color, font, size, alpha)
end

local function text_center(dl, x, cy, w, str, color, font, size, alpha)
    local tw, th = measure(str, font, size)
    text(dl, x + (w - tw) / 2, cy - th / 2, str, color, font, size, alpha)
end

-- a line of text, cut with an ellipsis to fit
local function fit(str, font, size, max_w)
    if measure(str, font, size) <= max_w then return str end
    local n = #str
    while n > 1 and measure(str:sub(1, n) .. '…', font, size) > max_w do n = n - 1 end
    -- not in the middle of a character of several bytes ('·', '→'): half of one draws as garbage
    while n > 1 and (str:byte(n + 1) or 0) >= 0x80 and (str:byte(n + 1) or 0) < 0xC0 do n = n - 1 end
    return str:sub(1, n) .. '…'
end

-- a paragraph as lines that fit a width
local function wrap(str, font, size, max_w)
    local lines, line = {}, ''
    for word in str:gmatch('%S+') do
        local try = line == '' and word or (line .. ' ' .. word)
        if measure(try, font, size) > max_w and line ~= '' then
            lines[#lines + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= '' then lines[#lines + 1] = line end
    return lines
end

-- an icon centred on its ink, not its advance box: the icon font's glyphs sit left and high in theirs
local function icon(dl, cx, cy, name, color, size, alpha)
    local s = fa(name)
    local px = S(size)
    local key = name .. '@' .. px
    local c = mcache.glyph[key]
    if c == nil then
        local gx, gy
        local ok, baked = pcall(F.icons.GetFontBaked, F.icons, px)
        if ok and baked and FA[name] then
            local ok2, g = pcall(baked.FindGlyph, baked, FA[name])
            if ok2 and g and g.X1 > g.X0 then gx, gy = (g.X0 + g.X1) / 2, (g.Y0 + g.Y1) / 2 end
        end
        if gx == nil then
            local w, h = measure(s, F.icons, size)
            gx, gy = w / 2, h / 2
        end
        c = { gx, gy }
        mcache.glyph[key] = c
    end
    text(dl, cx - c[1], cy - c[2], s, color, F.icons, size, alpha)
end

-- letters shaded from one colour to another
local function gradient_text(dl, x, y, str, left, right, font, size)
    local n = #str
    for i = 1, n do
        local before = i > 1 and measure(str:sub(1, i - 1), font, size) or 0
        text(dl, x + before, y, str:sub(i, i), mix(left, right, (i - 0.5) / n), font, size)
    end
    return measure(str, font, size)
end

local function pill(dl, x, y, label, bg, fg, font, size, pad, icon_name)
    font = font or F.semi
    size = size or T.tiny
    pad = pad or S(8)
    local tw, th = measure(label, font, size)
    local iw = icon_name and (th + S(4)) or 0
    local w = tw + iw + pad * 2
    local h = th + S(7)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(bg), h / 2)
    if icon_name then icon(dl, x + pad + th / 2, y + h / 2, icon_name, fg, size) end
    text(dl, x + pad + iw, y + S(3.5), label, fg, font, size)
    return w, h
end

local function shadow(dl, x, y, w, h, radius, strength)
    strength = strength or 1
    for i = 4, 1, -1 do
        dl:AddRectFilled({ x - S(i), y + S(i) * 1.5 }, { x + w + S(i), y + h + S(i) * 1.5 }, u32('#000000', 0.09 * strength), radius + S(i))
    end
end

local function panel(dl, x, y, w, h, bg, alpha, radius, border, glow)
    radius = radius or S(12)
    alpha = alpha or 1
    if glow then
        for i = 3, 1, -1 do
            dl:AddRect({ x - S(i), y - S(i) }, { x + w + S(i), y + h + S(i) }, u32(border or P.accent, 0.05 * alpha), radius + S(i), 15, S(2))
        end
    end
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(bg, alpha), radius)
    dl:AddRect({ x, y }, { x + w, y + h }, u32(border or P.line, 0.9 * alpha), radius, 15, 1)
    dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, u32('#FFFFFF', 0.035 * alpha), radius, 15, 1)
end

local function ring(dl, cx, cy, r, t, color, bg, thick)
    thick = thick or S(3)
    dl:AddCircle({ cx, cy }, r, u32(bg or P.line), 48, thick)
    if t > 0 then
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, r, -math.pi / 2, -math.pi / 2 + math.pi * 2 * math.min(1, t), 48)
        dl:PathStroke(u32(color), 0, thick)
    end
end

-- the job sprite on a coloured disc, standing a little proud of it
local function job_badge(dl, cx, cy, r, job, glow, alpha)
    alpha = alpha or 1
    local jname = JOBS[job] or '???'
    local color = JOB_COLOR[jname] or P.dim
    if glow and glow > 0 then
        for i = 3, 1, -1 do dl:AddCircleFilled({ cx, cy }, r + S(3) * i, u32(color, 0.08 * glow * alpha), 32) end
    end
    dl:AddCircleFilled({ cx, cy }, r, u32(mix(color, P.ink, 0.72), alpha), 32)
    dl:AddCircleFilled({ cx, cy - r * 0.25 }, r * 0.7, u32(color, 0.08 * alpha), 32)
    dl:AddCircle({ cx, cy }, r, u32(color, 0.85 * alpha), 32, S(1.5))
    local size = r * 1.7
    local cell = (job and job >= 1 and job <= 22) and (job - 1) or nil
    if not sprite(dl, TEX.jobs, 22, cell, cx - size / 2, cy - size / 2 - r * 0.1, size, size, alpha) then
        text_center(dl, cx - r, cy, r * 2, jname, color, F.dispb, r * 0.8, alpha)
    end
end

-- a role as a small glass disc in the flag's style: the chrome rim, the dark glass, the role's mark glowing inside
local function role_icon(dl, cx, cy, role, size, alpha)
    alpha = alpha or 1
    local rl = ROLES[role] or ROLES[0]
    local col = rl.color
    local pale = mix(col, '#FFFFFF', 0.6)
    local r = size / 2
    local ri = r * 0.84
    local m = ri * 0.6 -- the mark's half-size
    -- the rim, lit from the upper left with a glint lower right
    local segs = size > S(40) and 36 or 20
    for i = 0, segs - 1 do
        local a0 = (i / segs) * 2 * math.pi
        local a1 = ((i + 1.2) / segs) * 2 * math.pi
        local am = (a0 + a1) / 2
        local b = 0.42 + 0.5 * math.cos(am - math.pi * 1.25) + 0.9 * math.max(0, math.cos(am - math.pi * 0.15)) ^ 14
        b = math.max(0, math.min(1, b))
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, r - r * 0.08, a0, a1, 2)
        dl:PathStroke(u32(mix('#232A32', '#FAFCFE', b), alpha), 0, r * 0.16)
    end
    dl:AddCircleFilled({ cx, cy }, ri, u32('#04060A', alpha), 32)
    -- the role's glow in the glass
    for i = 3, 1, -1 do
        dl:AddCircleFilled({ cx, cy + ri * 0.05 }, ri * (0.28 + 0.18 * i), u32(col, 0.07 * alpha), 24)
    end
    local function poly(points, c, a)
        dl:PathClear()
        for _, pt in ipairs(points) do dl:PathLineTo({ cx + pt[1] * m, cy + pt[2] * m }) end
        dl:PathFillConvex(u32(c, a * alpha))
    end
    local function quad(x0, y0, x1, y1, wdt, c, a)
        -- a bar from (x0,y0) to (x1,y1), wdt wide, in mark units
        local dx, dy = x1 - x0, y1 - y0
        local len = math.sqrt(dx * dx + dy * dy)
        local nx, ny = -dy / len * wdt / 2, dx / len * wdt / 2
        poly({ { x0 + nx, y0 + ny }, { x1 + nx, y1 + ny }, { x1 - nx, y1 - ny }, { x0 - nx, y0 - ny } }, c, a)
    end
    if role == 1 then
        -- the shield: a flat top, sides falling to a point
        local sh = { { -0.8, -0.9 }, { 0.8, -0.9 }, { 0.8, 0.05 }, { 0.5, 0.6 }, { 0, 1.0 }, { -0.5, 0.6 }, { -0.8, 0.05 } }
        poly(sh, col, 0.95)
        local inner = {}
        for i, pt in ipairs(sh) do inner[i] = { pt[1] * 0.68, pt[2] * 0.68 + 0.02 } end
        poly(inner, mix(col, '#07090D', 0.55), 0.9)
        quad(0, -0.55, 0, 0.6, 0.16, pale, 0.9)
        quad(-0.42, -0.1, 0.42, -0.1, 0.16, pale, 0.9)
    elseif role == 2 then
        -- the cross
        quad(-0.9, 0, 0.9, 0, 0.56, col, 0.95)
        quad(0, -0.9, 0, 0.9, 0.56, col, 0.95)
        quad(-0.75, 0, 0.75, 0, 0.2, pale, 0.85)
        quad(0, -0.75, 0, 0.75, 0.2, pale, 0.85)
    elseif role == 3 then
        -- the note: a head, a stem, a flag
        dl:AddEllipseFilled({ cx - 0.3 * m, cy + 0.6 * m }, { 0.46 * m, 0.32 * m }, u32(col, 0.95 * alpha), -0.45, 20)
        dl:AddEllipseFilled({ cx - 0.36 * m, cy + 0.54 * m }, { 0.2 * m, 0.12 * m }, u32(pale, 0.7 * alpha), -0.45, 12)
        quad(0.1, 0.55, 0.1, -0.95, 0.16, col, 0.95)
        poly({ { 0.1, -0.95 }, { 0.78, -0.5 }, { 0.78, -0.05 }, { 0.26, -0.45 } }, col, 0.95)
        quad(0.1, 0.5, 0.1, -0.85, 0.06, pale, 0.8)
    elseif role == 4 then
        -- crossed swords: two blades, hilts at the bottom
        for _, sgn in ipairs({ -1, 1 }) do
            poly({ { sgn * -0.95, -0.95 }, { sgn * -0.75, -1.0 }, { sgn * 0.62, 0.62 }, { sgn * 0.48, 0.78 } }, col, 0.95)
            quad(sgn * -0.88, -0.9, sgn * 0.55, 0.7, 0.06, pale, 0.85)
            quad(sgn * 0.3, 0.86, sgn * 0.82, 0.42, 0.14, mix(col, '#FFFFFF', 0.25), 0.95) -- the guard
            dl:AddCircleFilled({ cx + sgn * 0.9 * m, cy + 1.02 * m }, 0.11 * m, u32(pale, 0.95 * alpha), 10)
        end
    else
        -- any: the four roles as a ring of dots
        for i, rr in ipairs({ ROLES[1], ROLES[2], ROLES[4], ROLES[3] }) do
            local a = (i - 1) / 4 * 2 * math.pi - math.pi / 2
            local dx, dy = cx + math.cos(a) * 0.58 * m, cy + math.sin(a) * 0.58 * m
            dl:AddCircleFilled({ dx, dy }, 0.3 * m, u32(rr.color, 0.95 * alpha), 14)
            dl:AddCircleFilled({ dx - 0.08 * m, dy - 0.08 * m }, 0.12 * m, u32('#FFFFFF', 0.5 * alpha), 8)
        end
    end
    -- the glass over the mark: the reflection lens and a highlight
    for i = 1, 3 do
        local k = i / 3
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, ri * 0.97, math.pi * (0.95 + 0.12 * k), math.pi * (1.78 - 0.14 * k), 12)
        dl:PathLineTo({ cx + ri * (0.12 - 0.3 * k), cy - ri * (0.1 + 0.15 * k) })
        dl:PathLineTo({ cx - ri * (0.28 + 0.1 * k), cy + ri * (0.55 - 0.35 * k) })
        dl:PathFillConvex(u32(mix('#6F8498', '#E3ECF5', k * 0.5), (0.1 + 0.03 * k) * alpha))
    end
    dl:AddCircleFilled({ cx - ri * 0.4, cy - ri * 0.42 }, ri * 0.13, u32('#FFFFFF', 0.2 * alpha), 12)
    dl:AddCircle({ cx, cy }, ri - 0.5, u32('#000000', 0.5 * alpha), 32, math.max(1, r * 0.03))
    return true
end

local function mode_gem(dl, cx, cy, mode, size, alpha)
    if mode == nil or mode < 0 or mode > 2 then return end
    sprite(dl, TEX.modes, 4, mode, cx - size / 2, cy - size / 2, size, size, alpha)
end

-- an invisible button with a hover value that eases in and out
local function hit(key, w, h)
    -- 8: ImGuiButtonFlags_EnableNav, so a controller's focus can land on it (ImGui 1.90+ keeps invisible buttons out
    -- of navigation unless told otherwise)
    local pressed = imgui.InvisibleButton(key, { math.max(1, w), math.max(1, h) }, 8)
    local hovered = imgui.IsItemHovered()
    local v = st.hover[key] or 0
    v = lerp(v, hovered and 1 or 0, math.min(1, dt * 14))
    st.hover[key] = v
    -- the controller's focus (ImGui's navigation), drawn as a ring by draw_toasts while the controller is in use
    if st.pad_shown and imgui.IsItemFocused() then
        local fx, fy = imgui.GetItemRectMin()
        st.focus = { x = fx, y = fy, w = math.max(1, w), h = math.max(1, h), at = now_t, key = key }
    end
    return pressed, hovered, v
end

-- a ripple where a card or button was pressed
local function ripple_at(key)
    local mx, my = imgui.GetMousePos()
    st.ripples[#st.ripples + 1] = { key = key, x = mx, y = my, at = now_t }
end

local function draw_ripples(dl, key, x, y, w, h, color)
    for i = #st.ripples, 1, -1 do
        local r = st.ripples[i]
        local t = (now_t - r.at) / 0.55
        if t >= 1 then
            table.remove(st.ripples, i)
        elseif r.key == key then
            dl:PushClipRect({ x, y }, { x + w, y + h }, true)
            dl:AddCircleFilled({ r.x, r.y }, S(40) + ease(t) * math.max(w, h) * 1.1, u32(color, 0.22 * (1 - t)), 48)
            dl:PopClipRect()
        end
    end
end

local function button(dl, key, x, y, w, h, label, color, kind, icon_name, font, size)
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = hit(key, w, h)
    local down = hovered and imgui.IsMouseDown(0)
    font = font or F.semi
    size = size or T.body
    local lift = kind == 'solid' and S(1.5) * hv or 0
    y = y - lift
    local r = S(9)
    if kind == 'solid' then
        shadow(dl, x, y, w, h, r, 0.6 + 0.6 * hv)
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(color), r)
        dl:AddRectFilledMultiColor({ x + r / 2, y }, { x + w - r / 2, y + h }, u32('#FFFFFF', 0.14), u32('#FFFFFF', 0.08), u32(P.ink, 0.12), u32(P.ink, 0.06))
        if down then dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.ink, 0.2), r) end
        dl:AddRect({ x, y }, { x + w, y + h }, u32('#FFFFFF', 0.18 + 0.2 * hv), r, 15, 1)
        if hv > 0 then dl:AddRect({ x - S(2), y - S(2) }, { x + w + S(2), y + h + S(2) }, u32(color, 0.45 * hv), r + S(2), 15, S(2)) end
    elseif kind == 'ghost' then
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(color, 0.07 + 0.12 * hv), r)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(color, 0.35 + 0.5 * hv), r, 15, 1)
    else
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(P.card, P.card_hi, hv)), r)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(P.line), r, 15, 1)
    end
    draw_ripples(dl, key, x, y, w, h, kind == 'solid' and '#FFFFFF' or (color or P.accent))
    local fg = kind == 'solid' and P.ink or (color or P.text)
    local tw, th = measure(label, font, size)
    local iw = icon_name and (th + (label ~= '' and S(6) or 0)) or 0
    local sx = x + (w - tw - iw) / 2
    if icon_name then icon(dl, sx + th / 2, y + h / 2, icon_name, fg, size) end
    if label ~= '' then text(dl, sx + iw, y + (h - th) / 2, label, fg, font, size) end
    if pressed then ripple_at(key) end
    return pressed, hovered
end

local function icon_button(dl, key, x, y, size, name, color, tip, bounce)
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = hit(key, size, size)
    local cx, cy = x + size / 2, y + size / 2
    dl:AddCircleFilled({ cx, cy }, size / 2, u32(color, 0.08 + 0.16 * hv), 32)
    if hv > 0 then dl:AddCircle({ cx, cy }, size / 2, u32(color, 0.55 * hv), 32, 1) end
    icon(dl, cx, cy, name, mix(color, P.text, 0.35 * hv), T.body * (bounce or 1))
    if hovered and tip then with_font(F.text, T.small, imgui.SetTooltip, tip) end
    return pressed
end

-- the composition dots of an LFM party: filled per member, hollow up to 6
local function comp_dots(dl, x, y, entry)
    local counts = { { entry.tanks, ROLES[1].color }, { entry.healers, ROLES[2].color }, { entry.supports, ROLES[3].color }, { entry.dps, ROLES[4].color } }
    local n = 0
    local r = S(4.5)
    local step = S(13)
    for _, c in ipairs(counts) do
        for _ = 1, c[1] do
            if n < 6 then
                dl:AddCircleFilled({ x + n * step + r, y + r }, r, u32(c[2]), 16)
                dl:AddCircleFilled({ x + n * step + r - r * 0.3, y + r - r * 0.3 }, r * 0.35, u32('#FFFFFF', 0.5), 8)
                n = n + 1
            end
        end
    end
    local size = math.max(entry.party_size or 1, n)
    while n < size and n < 6 do
        dl:AddCircleFilled({ x + n * step + r, y + r }, r, u32(P.dim, 0.9), 16)
        n = n + 1
    end
    while n < 6 do
        dl:AddCircle({ x + n * step + r, y + r }, r, u32(P.faint, 0.8), 16, 1)
        n = n + 1
    end
    return 6 * step
end

-- what an LFM party still needs: the role it asked for, else its open slots. Returns label, colour.
local function needs(entry, short)
    if entry.has_slots then return SLOTS.needs(entry, short) end
    local open = math.max(0, (entry.max_players or 6) - (entry.party_size or 1))
    if open == 0 then return 'FULL', P.faint end
    if entry.role ~= 0 then
        local role = ROLES[entry.role]
        return 'NEEDS ' .. (short and role.short or role.name):upper(), role.color
    end
    return open .. ' OPEN', P.ok
end

-- a number that pops when it changes
local function pop_scale(key, value)
    if st.counts_seen[key] ~= value then
        if st.counts_seen[key] ~= nil then st.pops[key] = now_t end
        st.counts_seen[key] = value
    end
    local at = st.pops[key]
    if at == nil then return 1 end
    local t = (now_t - at) / 0.45
    if t >= 1 then st.pops[key] = nil return 1 end
    return spring(t)
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local W = { w = 800, h = 580, hh_w = 360 }

local function handheld_active()
    local mode = settings.handheld or 'auto'
    if mode == 'on' then return true end
    if mode == 'off' then return false end
    local sw, sh = vana.ui.screen()
    return (sw or 1920) <= 1280 and (sh or 1080) <= 800
end

local function push_theme()
    for _, entry in ipairs(theme_colors()) do imgui.PushStyleColor(entry[1], rgba(entry[2])) end
    imgui.PushStyleVar(VAR.WindowPadding, { 0, 0 })
    imgui.PushStyleVar(VAR.WindowRounding, S(16))
    imgui.PushStyleVar(VAR.WindowBorderSize, 0)
    imgui.PushStyleVar(VAR.ChildRounding, S(10))
    imgui.PushStyleVar(VAR.PopupRounding, S(10))
    imgui.PushStyleVar(VAR.FramePadding, { S(12), S(7) })
    imgui.PushStyleVar(VAR.FrameRounding, S(9))
    imgui.PushStyleVar(VAR.FrameBorderSize, 0)
    imgui.PushStyleVar(VAR.ItemSpacing, { S(8), S(6) })
    imgui.PushStyleVar(VAR.ScrollbarSize, S(8))
    imgui.PushStyleVar(VAR.ScrollbarRounding, S(8))
    imgui.PushStyleVar(VAR.GrabRounding, S(8))
end

local function pop_theme()
    imgui.PopStyleVar(12)
    imgui.PopStyleColor(THEME_COUNT)
end

-- the aurora behind the header: drifting colour, soft orbs, a faint grid. `radius` is the corner rounding of the panel
-- it sits on: ImGui's gradient fill (AddRectFilledMultiColor) has no rounding, in 1.81 or 1.92, so drawn whole it
-- squares off the panel's top corners. The top `radius` rows go down as one-pixel strips, each inset to the arc.
local function aurora(dl, x, y, w, h, t, radius)
    local a = 0.5 + 0.5 * math.sin(t * 0.6)
    local b = 0.5 + 0.5 * math.sin(t * 0.9 + 2)
    local c1, c2 = mix(P.accent, P.cyan, a), mix(P.accent2, P.accent, b)
    dl:PushClipRect({ x, y }, { x + w, y + h }, true)
    -- the colour f of the way down: c1 / c2 at the top fading to clear glass at the bottom, as the gradient would
    local function lc(f) return u32(mix(c1, P.glass, f), 0.32 * (1 - f)) end
    local function rc(f) return u32(mix(c2, P.glass, f), 0.18 * (1 - f)) end
    local r = math.floor(math.min(radius or 0, h, w / 2))
    for dy = 0, r - 1 do
        local yc = r - dy - 0.5 -- the strip's middle, above the arc's centre
        local ins = r - math.sqrt(r * r - yc * yc)
        local f0, f1 = dy / h, (dy + 1) / h
        dl:AddRectFilledMultiColor({ x + ins, y + dy }, { x + w - ins, y + dy + 1 }, lc(f0), rc(f0), rc(f1), lc(f1))
    end
    dl:AddRectFilledMultiColor({ x, y + r }, { x + w, y + h }, lc(r / h), rc(r / h), u32(P.glass, 0), u32(P.glass, 0))
    local gx = x + S(24)
    while gx < x + w do
        dl:AddLine({ gx, y }, { gx, y + h }, u32('#FFFFFF', 0.025), 1)
        gx = gx + S(28)
    end
    local gy = y + S(14)
    while gy < y + h do
        dl:AddLine({ x, gy }, { x + w, gy }, u32('#FFFFFF', 0.02), 1)
        gy = gy + S(28)
    end
    for i = 1, 3 do
        local ox = x + w * (0.25 + 0.28 * (i - 1)) + math.sin(t * 0.35 + i * 2) * w * 0.12
        local oy = y + h * 0.4 + math.cos(t * 0.5 + i) * h * 0.25
        local col = i == 1 and P.cyan or (i == 2 and P.accent2 or P.accent)
        for k = 5, 1, -1 do
            dl:AddCircleFilled({ ox, oy }, S(22) * k, u32(col, 0.022), 24)
        end
    end
    dl:PopClipRect()
end

-- the icons on offer: the two built in, then any PNG in images\icons (its file name is its name)
local BUILTIN_ICONS = { { id = 'flag', name = 'Updated flag' }, { id = 'beacon', name = 'Legacy flag' }, { id = 'crest', name = 'Social' }, { id = 'gem', name = 'CatsEyeXI gem' } }
local function icon_options()
    local list = {}
    for _, b in ipairs(BUILTIN_ICONS) do list[#list + 1] = b end
    local dir = vana.paths.addon .. '\\images\\icons'
    if vana.fs.exists(dir) then
        local ok, names = pcall(vana.fs.list, dir, '.+\\.[pP][nN][gG]', 'files')
        if ok and names then
            table.sort(names)
            for _, file in ipairs(names) do
                list[#list + 1] = { id = 'file:' .. file, name = file:gsub('%.[pP][nN][gG]$', ''):gsub('[_-]', ' '), file = file }
            end
        end
    end
    return list
end

local function custom_texture(id)
    local tex = TEX.custom[id]
    if tex == nil then
        tex = load_texture('custom:' .. id, vana.paths.addon .. '\\images\\icons\\' .. id:sub(6)) or false
        TEX.custom[id] = tex
    end
    return tex or nil
end

-- the crest: a dark disc, a ring swept from the theme's accent to its second colour, the party glyph, a lens badge.
-- Drawn, so it's crisp at any size and follows the theme; `speed` turns the sweep.
local function draw_crest(dl, cx, cy, size, t, speed, alpha)
    alpha = alpha or 1
    local r = size / 2
    -- the disc with a soft radial lift
    dl:AddCircleFilled({ cx, cy }, r, u32(P.ink, alpha), 48)
    for i = 6, 1, -1 do
        dl:AddCircleFilled({ cx, cy - r * 0.12 }, r * (0.15 + 0.12 * i), u32(P.accent, 0.035 * alpha), 32)
    end
    -- the swept ring: 36 arc pieces, the colour running round, turning slowly
    local n = 36
    local thick = math.max(1.5, r * 0.12)
    local spin = (speed or 0) * t * 0.6
    for i = 0, n - 1 do
        local a0 = spin + (i / n) * math.pi * 2
        local a1 = a0 + (math.pi * 2 / n) * 1.08
        local f = (i / n)
        local col = mix(P.accent, P.accent2, 0.5 + 0.5 * math.sin(f * math.pi * 2))
        local glow = 0.55 + 0.45 * math.sin(f * math.pi * 2 + math.pi / 2)
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, r - thick * 0.8, a0, a1, 4)
        dl:PathStroke(u32(col, alpha * (0.6 + 0.4 * glow)), 0, thick)
    end
    dl:AddCircle({ cx, cy }, r - thick * 1.6, u32(P.line, 0.6 * alpha), 48, 1)
    -- the party
    local gs = r * 0.78
    local g = fa('user-group')
    local gw, gh = measure(g, F.icons, gs)
    text(dl, cx - gw / 2 + 1, cy - gh / 2 - r * 0.06 + 2, g, P.ink, F.icons, gs, 0.6 * alpha)
    text(dl, cx - gw / 2, cy - gh / 2 - r * 0.06, g, '#FFFFFF', F.icons, gs, alpha)
    -- the lens badge
    local bx, by, br = cx + r * 0.58, cy + r * 0.58, r * 0.3
    dl:AddCircleFilled({ bx, by }, br + S(1.5), u32(P.ink, alpha), 24)
    dl:AddCircleFilled({ bx, by }, br, u32(P.cyan, alpha), 24)
    icon(dl, bx, by, 'magnifying-glass', P.ink, br * 1.15, alpha)
    return true
end

-- the seek flag: FFXI's own "seeking party" beacon, drawn: a chrome sphere holding a green exclamation mark, the
-- stroke a cone of light, the dot a glowing pool, with a thin ring in the theme's colour. `speed` is how fast it breathes.
local function draw_flag(dl, cx, cy, size, t, speed, alpha)
    -- the seek flag as a glass ball, after the original sprite: a chrome rim lit from the upper left, a soft
    -- grey-blue reflection across the upper left of the glass, the green cone of light widening to the top,
    -- and its glowing pool at the foot
    alpha = alpha or 1
    local GREEN, PALE = '#2EE86A', '#C8FFD9'
    local r = size / 2
    local breathe = 0.5 + 0.5 * math.sin(t * 2.4 * math.max(0.15, speed or 1))
    local ri = r * 0.85 -- the glass inside the rim
    local segs = 48
    -- the rim: brightness around it from two lights, the main one upper left, a glint lower right
    local function ring(radius, thick, dark, light, k1, k2, a)
        for i = 0, segs - 1 do
            local a0 = (i / segs) * 2 * math.pi
            local a1 = ((i + 1.15) / segs) * 2 * math.pi
            local am = (a0 + a1) / 2
            local b = 0.42 + k1 * math.cos(am - math.pi * 1.25) + k2 * math.max(0, math.cos(am - math.pi * 0.15)) ^ 14
            b = math.max(0, math.min(1, b))
            dl:PathClear()
            dl:PathArcTo({ cx, cy }, radius, a0, a1, 3)
            dl:PathStroke(u32(mix(dark, light, b), a * alpha), 0, thick)
        end
    end
    ring(r - r * 0.075, r * 0.15, '#232A32', '#FAFCFE', 0.5, 0.9, 1)
    ring(r - r * 0.02, r * 0.035, '#14181D', '#B8C3CE', 0.45, 0.6, 0.9) -- the rim's outer edge
    -- the glass: black, a thin dark edge, the reflection as nested lenses fading toward the top left
    dl:AddCircleFilled({ cx, cy }, ri, u32('#04060A', alpha), 64)
    for i = 1, 7 do
        local k = i / 7
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, ri * 0.985, math.pi * (0.95 + 0.12 * k), math.pi * (1.78 - 0.14 * k), 24)
        dl:PathLineTo({ cx + ri * (0.12 - 0.3 * k), cy - ri * (0.1 + 0.15 * k) })
        dl:PathLineTo({ cx - ri * (0.28 + 0.1 * k), cy + ri * (0.55 - 0.35 * k) })
        dl:PathFillConvex(u32(mix('#6F8498', '#E3ECF5', k * 0.5), (0.11 + 0.03 * k) * alpha))
    end
    -- a faint sheen along the lower right of the glass
    for i = 1, 4 do
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, ri * (1 - 0.03 * i), math.pi * 0.02, math.pi * 0.48, 20)
        dl:PathStroke(u32('#9FB3C8', 0.05 * alpha), 0, r * 0.05)
    end
    -- the cone: wide and soft at the top, narrowing to the foot, brighter toward the foot
    local top, foot = cy - ri * 0.72, cy + ri * 0.2
    local n = 16
    for i = 0, n - 1 do
        local f0, f1 = i / n, (i + 1) / n
        local y0, y1 = top + (foot - top) * f0, top + (foot - top) * f1
        local w0, w1 = ri * (0.84 - 0.72 * f0), ri * (0.84 - 0.72 * f1)
        local a = (0.55 + 0.45 * f0) * (0.9 + 0.1 * breathe)
        dl:AddQuadFilled({ cx - w0 / 2, y0 }, { cx + w0 / 2, y0 }, { cx + w1 / 2, y1 }, { cx - w1 / 2, y1 }, u32(mix(GREEN, PALE, 0.04 + 0.16 * f0), a * alpha))
    end
    -- the beam down the cone's middle, and its soft edges
    dl:AddQuadFilled({ cx - ri * 0.12, top + ri * 0.05 }, { cx + ri * 0.12, top + ri * 0.05 }, { cx + ri * 0.025, foot }, { cx - ri * 0.025, foot }, u32(PALE, 0.5 * alpha))
    dl:AddEllipseFilled({ cx, top }, { ri * 0.42, ri * 0.11 }, u32(mix(GREEN, PALE, 0.35), 0.6 * alpha), 0, 32) -- the mouth
    dl:AddEllipseFilled({ cx, top + ri * 0.01 }, { ri * 0.33, ri * 0.065 }, u32('#0E3D1C', 0.45 * alpha), 0, 28) -- its dark inside
    -- the pool: glowing green, lit at its centre, and the glow it throws on the glass
    local py = cy + ri * 0.5
    for i = 4, 1, -1 do
        dl:AddEllipseFilled({ cx, py }, { ri * (0.34 + 0.13 * i), ri * (0.14 + 0.06 * i) }, u32(GREEN, (0.06 + 0.04 * breathe) * alpha), 0, 32)
    end
    dl:AddEllipseFilled({ cx, py }, { ri * 0.46, ri * 0.18 }, u32(GREEN, (0.9 + 0.1 * breathe) * alpha), 0, 36)
    dl:AddEllipseFilled({ cx, py - ri * 0.02 }, { ri * 0.26, ri * 0.09 }, u32(PALE, 0.85 * alpha), 0, 28)
    dl:AddEllipseFilled({ cx, foot + ri * 0.01 }, { ri * 0.06, ri * 0.025 }, u32('#FFFFFF', 0.9 * alpha), 0, 12)
    -- the glass's own highlights: a soft spot top left, a pinpoint lower right, the edge catching light
    for i = 5, 1, -1 do
        dl:AddEllipseFilled({ cx - ri * 0.4, cy - ri * 0.42 }, { ri * 0.06 * i, ri * 0.04 * i }, u32('#FFFFFF', 0.06 * alpha), -0.75, 24)
    end
    dl:AddCircleFilled({ cx + ri * 0.48, cy + ri * 0.42 }, ri * 0.05, u32('#FFFFFF', 0.5 * alpha), 12)
    dl:AddCircle({ cx, cy }, ri - 0.5, u32('#000000', 0.5 * alpha), 64, math.max(1, r * 0.03))
    return true
end

-- one icon by id, in a circle of `size`
local function draw_icon_id(dl, id, cx, cy, size, t, speed, alpha)
    alpha = alpha or 1
    if id == 'flag' then return draw_flag(dl, cx, cy, size, t, speed, alpha) end
    if id == 'crest' then return draw_crest(dl, cx, cy, size, t, speed, alpha) end
    if id == 'gem' and gem(dl, cx, cy, size, t, speed or 1, alpha) then
        dl:AddCircle({ cx, cy }, size / 2, u32(P.accent, 0.4 * alpha), 48, 1)
        return true
    end
    if id:sub(1, 5) == 'file:' then
        local tex = custom_texture(id)
        if tex ~= nil then
            round_cell(dl, tex, 1, 1, 0, cx, cy, size, alpha)
            dl:AddCircle({ cx, cy }, size / 2, u32(P.line, alpha), 48, 1)
            return true
        end
    end
    if sprite(dl, TEX.beacon, 1, 0, cx - size / 2, cy - size / 2, size, size, alpha) then return true end
    dl:AddCircleFilled({ cx, cy }, size / 2, u32(P.glass, alpha), 48)
    icon(dl, cx, cy, 'compass', P.ok, size * 0.5, alpha)
    return false
end

-- the backgrounds on offer: none, then every PNG or JPG in bg\\ (its name is the file's, less the extension). A file
-- named like name.CxR@F.jpg (or name.CxRxN@F.jpg) is a grid of frames: C columns, R rows, N frames (C*R if left out),
-- F frames a second.
local function background_options()
    local list = { { id = 'none', name = 'None' } }
    local dir = vana.paths.addon .. '\\bg'
    if vana.fs.exists(dir) then
        local ok, names = pcall(vana.fs.list, dir, '.+\\.([pP][nN][gG]|[jJ][pP][gG])', 'files')
        if ok and names then
            table.sort(names, function (a, b) return a:lower() < b:lower() end)
            for _, file in ipairs(names) do
                local base = file:gsub('%.%w+$', '')
                local name, c, r, n, f = base:match('^(.-)%.(%d+)x(%d+)x?(%d*)@(%d+)$')
                local grid = nil
                if name then
                    c, r, f = tonumber(c), tonumber(r), tonumber(f)
                    grid = { cols = c, rows = r, frames = (n ~= '' and tonumber(n)) or c * r, fps = f }
                else
                    name = base
                end
                list[#list + 1] = { id = name:lower(), name = name, file = file, aspect = 16 / 9, grid = grid }
            end
        end
    end
    return list
end

local function background_by_id(id)
    if id == nil or id == 'none' then return nil end
    st.backgrounds = st.backgrounds or background_options()
    for _, b in ipairs(st.backgrounds) do if b.id == id then return b end end
    return nil
end

local function background_texture(b)
    local tex = TEX.custom['bg:' .. b.file]
    if tex == nil then
        tex = load_texture('bg:' .. b.file, vana.paths.addon .. '\\bg\\' .. b.file) or false
        TEX.custom['bg:' .. b.file] = tex
    end
    return tex or nil
end

-- the part of a background's frame that covers a w x h rect (cropped to fit, the crop centred on `focus` of the height)
local function background_uv(b, w, h, focus, t)
    local rect_aspect = w / h
    local cu, cv = 1, 1
    if rect_aspect > b.aspect then cv = b.aspect / rect_aspect else cu = rect_aspect / b.aspect end
    local cols, rows, cell = 1, 1, 0
    if b.grid then
        cols, rows = b.grid.cols, b.grid.rows
        -- one frame at a time: a second, translucent frame over it would change the coverage every frame (flicker)
        cell = math.floor(t * b.grid.fps + 0.5) % b.grid.frames
    end
    local col, row = cell % cols, math.floor(cell / cols)
    local fw, fh = 1 / cols, 1 / rows
    local u0 = col * fw + fw * (1 - cu) / 2
    local v0 = row * fh + fh * (1 - cv) * focus
    return { u0, v0 }, { u0 + fw * cu, v0 + fh * cv }
end

-- a frame of a background covering a rounded rect
local function draw_background(dl, x, y, w, h, radius, t, alpha)
    local b = background_by_id(settings.background or 'none')
    if b == nil or b.file == nil then return false end
    local tex = background_texture(b)
    if tex == nil then return false end
    local theme = THEME_BY_ID[settings.theme or 'aurora']
    local focus = (theme and theme.art == b.id) and theme.focus or 0.5
    local uv0, uv1 = background_uv(b, w, h, focus, t)
    dl:AddImageRounded(tex, { x, y }, { x + w, y + h }, uv0, uv1, u32('#FFFFFF', alpha), radius)
    -- a shade at the bottom so the last cards still read
    dl:AddRectFilledMultiColor({ x, y + h * 0.5 }, { x + w, y + h }, u32(P.bg, 0), u32(P.bg, 0), u32(P.bg, 0.55 * alpha), u32(P.bg, 0.55 * alpha))
    -- the signature
    local artist = ARTISTS[b.id]
    if artist then
        local sig = artist
        local sw_, sh_ = measure(sig, F.disp, T.h2)
        local sx, sy = x + w - sw_ - S(14), y + h - sh_ - S(8)
        text(dl, sx + 1, sy + 1, sig, P.ink, F.disp, T.h2, 0.6 * math.min(1, alpha + 0.3))
        text(dl, sx, sy, sig, P.text, F.disp, T.h2, 0.55 * math.min(1, alpha + 0.3))
        local lw = measure('art by', F.text, T.tiny)
        text(dl, sx - lw - S(6), y + h - S(8) - S(14), 'art by', P.dim, F.text, T.tiny, 0.5 * math.min(1, alpha + 0.3))
    end
    return true
end

-- the finder's icon (the one the settings pick), with its glow
local function beacon(dl, cx, cy, size, t, alpha, speed)
    alpha = alpha or 1
    local pulse = 0.5 + 0.5 * math.sin(t * 2.2)
    for i = 3, 1, -1 do
        dl:AddCircleFilled({ cx, cy }, size / 2 + S(4) * i * (0.6 + 0.4 * pulse), u32(P.accent, 0.06 * alpha), 32)
    end
    draw_icon_id(dl, settings.icon or 'beacon', cx, cy, size, t, speed, alpha)
end

-- what PFP are, how they're earned and spent (modules README)
local function pfp_tooltip()
    local w, h = S(380), S(236)
    imgui.SetNextWindowSize({ w, h }, ALWAYS)
    imgui.BeginTooltip()
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetWindowPos()
    imgui.Dummy({ w, h })
    local cy = y + S(12)
    icon(dl, x + S(24), cy + S(12), 'gem', P.gold, T.body)
    text(dl, x + S(40), cy, string.format('%d Party Finder Points', st.pfp or 0), P.gold, F.disp, T.h1)
    cy = cy + S(28)
    text(dl, x + S(14), cy, string.format('Duties today: %d / 3 count for the daily bonus', st.daily or 0), P.dim, F.text, T.small)
    cy = cy + S(24)
    local function head(label, col)
        dl:AddLine({ x + S(14), cy }, { x + w - S(14), cy }, u32(P.line), 1)
        cy = cy + S(8)
        text(dl, x + S(14), cy, label, col, F.disp, T.small)
        cy = cy + S(20)
    end
    local function row(label, value, col)
        text(dl, x + S(20), cy, label, P.text, F.text, T.small)
        text(dl, x + w - S(14) - measure(value, F.semi, T.small), cy, value, col or P.gold, F.semi, T.small)
        cy = cy + S(19)
    end
    head('EARN', P.ok)
    row('Duty Roulette, tier 1 → 5', '100 · 85 · 70 · 55 · 40')
    row('Mission Help', '150')
    row('First clear of each duty per day', '×3', P.ok)
    head('SPEND', P.accent)
    row('Re-roll a duty (up to 3 a day)', '25')
    row('Cerdoux, Upper Jeuno: items', '1,000')
    imgui.EndTooltip()
end

local function draw_header(dl, x, y, w, t)
    local h = S(84)
    aurora(dl, x, y, w, h + S(30), t, S(16))
    -- the beacon and the title
    imgui.SetCursorScreenPos({ x + S(18), y + S(16) })
    local _, _, logo_hv = hit('##logo', S(52), S(52))
    local base = LOGO_SPEED[settings.logo_motion or 'slow'] or 0.35
    beacon(dl, x + S(44), y + S(42), S(46), t, 1, base + (1 - base) * logo_hv)
    local tx = x + S(76)
    -- the title and the line under it, as one block centred on the logo (Rajdhani's capitals sit high in their box)
    gradient_text(dl, tx, y + S(17), 'PARTY FINDER', P.cyan, P.accent2, F.dispb, T.title)
    local sub = { 'CatsEyeXI' }
    if st.mode ~= nil then sub[#sub + 1] = MODES[st.mode] or '?' end
    sub[#sub + 1] = string.format('%d listing%s', #st.entries, #st.entries == 1 and '' or 's')
    local sub_y = y + S(49)
    text(dl, tx + S(2), sub_y, table.concat(sub, '   ·   '), P.dim, F.text, T.small)
    -- the glow line
    local pulse = 0.55 + 0.45 * math.sin(t * 2)
    dl:AddRectFilledMultiColor({ x + S(18), y + h - 1 }, { x + w - S(18), y + h + 1 },
        u32(P.accent, 0), u32(P.cyan, 0.9 * pulse), u32(P.accent2, 0.9 * pulse), u32(P.accent, 0))
    -- right side: buttons, then PFP
    local bx = x + w - S(22)
    local size = S(32)
    local by = y + S(16)
    bx = bx - size
    st.tour_anchor.close = { bx, by, size, size }
    if icon_button(dl, '##close', bx, by, size, 'xmark', P.dim, 'Tuck into the beacon (Esc). /pf hide hides it') then st.mini = true end
    bx = bx - size - S(4)
    if icon_button(dl, '##settings', bx, by, size, 'gear', st.settings_open and P.accent or P.dim, 'Settings') then st.settings_open = not st.settings_open st.icons, st.backgrounds = nil, nil end
    bx = bx - size - S(4)
    local waiting = st.ping_since ~= nil
    if waiting then
        dl:PathClear()
        dl:PathArcTo({ bx + size / 2, by + size / 2 }, size / 2 - S(2), t * 5, t * 5 + math.pi * 1.4, 24)
        dl:PathStroke(u32(P.cyan, 0.9), 0, S(2))
    end
    if icon_button(dl, '##refresh', bx, by, size, 'rotate-right', waiting and P.cyan or P.dim, 'Refresh the listings') then send_refresh() end
    bx = bx - size - S(4)
    local since_bell = now_t - st.bell_at
    local bounce = since_bell < 0.8 and (1 + 0.5 * math.abs(math.sin(since_bell * 14)) * (1 - since_bell / 0.8)) or 1
    if icon_button(dl, '##notify', bx, by, size, settings.notify and 'bell' or 'bell-slash', settings.notify and P.gold or P.faint,
        settings.notify and 'LFM announcements: on' or 'LFM announcements: off', bounce) then
        settings.notify = not settings.notify save_settings()
    end
    if #st.requests > 0 then
        dl:AddCircleFilled({ bx + size - S(5), by + S(5) }, S(6), u32(P.danger), 16)
        text_center(dl, bx + size - S(11), by + S(5), S(12), tostring(#st.requests), P.text, F.bold, T.tiny - 2)
    end
    if st.pfp ~= nil then
        st.pfp_shown = st.pfp_shown and lerp(st.pfp_shown, st.pfp, math.min(1, dt * 5)) or st.pfp
        if math.abs(st.pfp_shown - st.pfp) < 0.5 then st.pfp_shown = st.pfp end
        local label = string.format('%d PFP', math.floor(st.pfp_shown + 0.5))
        local pw = pill(dl, 0, -1000, label, P.card, P.gold, F.disp, T.small, S(9), 'gem')
        local px = bx - S(16) - pw
        pill(dl, px, by + S(5), label, mix(P.gold, P.ink, 0.78), P.gold, F.disp, T.small, S(9), 'gem')
        imgui.SetCursorScreenPos({ px, by + S(5) })
        local _, pfp_hovered = hit('##pfp', pw, S(26))
        if pfp_hovered then pfp_tooltip() end
        -- on the subtitle's line, centred under the pill
        local dtext = string.format('duty %d / 3', st.daily or 0)
        local dw = measure(dtext, F.text, T.small)
        text(dl, px + (pw - dw) / 2, sub_y, dtext, P.dim, F.text, T.small)
    end
    return h
end

-- a dropdown: a field showing the pick, a list of the options in a popup under it. Returns the value.
local function dropdown(dl, key, x, cy, w, options, value)
    local h = S(30)
    imgui.SetCursorScreenPos({ x, cy - h / 2 })
    local pressed, _, hv = hit(key, w, h)
    local name = '?'
    for _, o in ipairs(options) do if o.id == value then name = o.name end end
    dl:AddRectFilled({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(mix(P.well, P.card_hi, 0.4 * hv)), S(9))
    dl:AddRect({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(mix(P.line, P.accent, hv)), S(9), 15, 1)
    text_mid(dl, x + S(12), cy, fit(name, F.text, T.small, w - S(44)), P.text, F.text, T.small)
    icon(dl, x + w - S(16), cy, 'chevron-down', mix(P.dim, P.text, hv), T.tiny)
    if pressed then imgui.OpenPopup(key) end
    imgui.SetNextWindowPos({ x, cy + h / 2 + S(4) })
    imgui.SetNextWindowSize({ w, 0 })
    if imgui.BeginPopup(key) then
        with_font(F.text, T.small, function ()
            for i, o in ipairs(options) do
                if imgui.Selectable(o.name .. '##' .. key .. i, o.id == value) then value = o.id end
            end
        end)
        imgui.EndPopup()
    end
    return value
end

-- one group as a pill: the role glyph (if it is a role), its name or jobs, xN. measure_only: just the width.
function SLOTS.pill(dl, x, y, g, alpha, measure_only)
    local lbl = SLOTS.label(g.mask, false, 3) .. (g.count > 1 and (' x' .. g.count) or '')
    local tw, th = measure(lbl, F.disp, T.tiny)
    local h = th + S(7)
    local gs = g.role and (h - S(4)) or 0
    local w = S(8) + (g.role and (gs + S(4)) or 0) + tw + S(9)
    if measure_only then return w, h end
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(g.color, P.ink, 0.74), alpha), h / 2)
    local tx = x + S(8)
    if g.role then role_icon(dl, x + S(6) + gs / 2, y + h / 2, g.role, gs, alpha) tx = x + S(6) + gs + S(4) end
    text(dl, tx, y + S(3.5), lbl, g.color, F.disp, T.tiny, alpha)
    return w, h
end

-- a slot chip: what one open slot wants, click for the picker. Returns the width used.
function SLOTS.chip(dl, key, x, cy, i, masks, n_shown)
    local mask = masks[i] or 0
    local h = S(28)
    local lbl = SLOTS.label(mask, true, 3)
    local col = SLOTS.color(mask)
    local r = SLOTS.role_of(mask)
    local gs = r and S(20) or 0
    local lw = measure(lbl, F.disp, T.tiny)
    local w = S(18) + gs + (r and S(4) or 0) + lw
    imgui.SetCursorScreenPos({ x, cy - h / 2 })
    local pressed, hovered, hv = hit(key, w, h)
    dl:AddRectFilled({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(col, 0.08 + 0.1 * hv), S(8))
    dl:AddRect({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(col, 0.35 + 0.45 * hv), S(8), 15, 1)
    local tx = x + S(9)
    if r then role_icon(dl, tx + gs / 2, cy, r, gs, 1) tx = tx + gs + S(4) end
    text_mid(dl, tx, cy, lbl, col, F.disp, T.tiny)
    if hovered then
        local jobs = SLOTS.jobs(mask)
        local names = {}
        for _, j in ipairs(jobs) do names[#names + 1] = JOBS[j] end
        with_font(F.text, T.small, imgui.SetTooltip, 'Slot ' .. i .. ': ' .. ((mask == 0 or mask == SLOTS.ALL) and 'any job' or table.concat(names, ', ')) .. '\nClick to choose')
    end
    if pressed then imgui.OpenPopup(key) end
    imgui.SetNextWindowPos({ x, cy + h / 2 + S(4) })
    local pw, ph = S(330), S(204)
    imgui.SetNextWindowSize({ pw, ph })
    if imgui.BeginPopup(key) then
        local pdl = imgui.GetWindowDrawList()
        local px, py = imgui.GetWindowPos()
        imgui.Dummy({ pw, ph })
        text(pdl, px + S(12), py + S(8), 'SLOT ' .. i, P.dim, F.disp, T.tiny)
        -- the roles, as shortcuts, named underneath
        for rr = 0, 4 do
            local bx = px + S(60) + rr * S(40)
            imgui.SetCursorScreenPos({ bx, py + S(4) })
            local rp, rh, rhv = hit(key .. 'r' .. rr, S(32), S(44))
            local on = SLOTS.role_of(mask) == rr
            if on then pdl:AddCircle({ bx + S(16), py + S(20) }, S(15), u32(ROLES[rr].color, 0.9), 24, S(1.5)) end
            role_icon(pdl, bx + S(16), py + S(20), rr, S(26), on and 1 or 0.5 + 0.4 * rhv)
            text_center(pdl, bx, py + S(42), S(32), ROLES[rr].short, on and ROLES[rr].color or mix(P.dim, ROLES[rr].color, rhv), F.disp, T.tiny - 2)
            if rh then with_font(F.text, T.small, imgui.SetTooltip, ROLES[rr].name .. ' — ' .. ROLES[rr].about) end
            if rp then masks[i] = SLOTS.ROLE[rr] mask = masks[i] end
        end
        -- every job, toggled one by one, its name under the badge
        for j = 1, 22 do
            local colx, row = (j - 1) % 11, math.floor((j - 1) / 11)
            local bx, by = px + S(12) + colx * S(28), py + S(58) + row * S(44)
            imgui.SetCursorScreenPos({ bx, by })
            local jp, jh, jhv = hit(key .. 'j' .. j, S(26), S(40))
            local on = mask ~= 0 and mask ~= SLOTS.ALL and SLOTS.has(mask, j)
            job_badge(pdl, bx + S(13), by + S(13), S(11), j, on and 0.7 or 0.25 * jhv, on and 1 or 0.4 + 0.3 * jhv)
            text_center(pdl, bx, by + S(32), S(26), JOBS[j], on and (JOB_COLOR[JOBS[j]] or P.text) or mix(P.faint, P.text, 0.5 * jhv), F.disp, T.tiny - 2)
            if jp then
                local base = (mask == SLOTS.ALL) and 0 or mask
                masks[i] = SLOTS.toggle(base, j)
                mask = masks[i]
            end
        end
        -- the bottom row: apply to every slot, clear, done
        local by = py + ph - S(36)
        if button(pdl, key .. 'all', px + S(12), by, S(110), S(26), 'Apply to all', P.accent, 'ghost', 'users', F.semi, T.tiny) then
            for k = 1, (n_shown or SLOTS.n) do masks[k] = mask end
        end
        if button(pdl, key .. 'any', px + S(130), by, S(70), S(26), 'Any', P.dim, 'ghost', nil, F.semi, T.tiny) then masks[i] = 0 mask = 0 end
        if button(pdl, key .. 'done', px + pw - S(12) - S(70), by, S(70), S(26), 'Done', P.ok, 'solid', 'check', F.semi, T.tiny) then imgui.CloseCurrentPopup() end
        imgui.EndPopup()
    end
    return w
end

-- a section label with a hairline running to the right
local function section(dl, x, y, w, label, icon_name)
    local lx = x
    if icon_name then
        icon(dl, x + S(6), y + S(7), icon_name, P.accent2, T.tiny)
        lx = x + S(16)
    end
    text_mid(dl, lx, y + S(7), label, P.accent2, F.disp, T.tiny)
    local lw = measure(label, F.disp, T.tiny)
    dl:AddLine({ lx + lw + S(10), y + S(7) }, { x + w, y + S(7) }, u32(P.line), 1)
    return y + S(22)
end

-- the artwork page: every picture in bg\\ as a tile, the artist under it
-- a slider; returns the value, whether it moved, and whether it was just let go
local function slider(dl, key, x, cy, w, value, min, max, fmt, on_release)
    imgui.SetCursorScreenPos({ x - S(8), cy - S(12) })
    local _, _, hv = hit(key, w + S(16), S(24))
    local active = imgui.IsItemActive()
    local released = imgui.IsItemDeactivated()
    local moved = false
    if active then
        local mx = imgui.GetMousePos()
        local v = min + (max - min) * math.max(0, math.min(1, (mx - x) / w))
        if math.abs(v - value) > 1e-6 then value, moved = v, true end
    end
    local f = (value - min) / (max - min)
    local th = S(6)
    dl:AddRectFilled({ x, cy - th / 2 }, { x + w, cy + th / 2 }, u32(P.well), th / 2)
    dl:AddRect({ x, cy - th / 2 }, { x + w, cy + th / 2 }, u32(P.line), th / 2, 15, 1)
    if f > 0 then
        dl:AddRectFilledMultiColor({ x, cy - th / 2 }, { x + w * f, cy + th / 2 }, u32(P.accent), u32(P.cyan), u32(P.cyan), u32(P.accent))
    end
    local kx = x + w * f
    local kr = S(8) + S(1.5) * math.max(hv, active and 1 or 0)
    if active or hv > 0 then dl:AddCircleFilled({ kx, cy }, kr + S(5), u32(P.cyan, 0.18 * math.max(hv, active and 1 or 0)), 24) end
    dl:AddCircleFilled({ kx, cy + 1 }, kr, u32(P.ink, 0.5), 24)
    dl:AddCircleFilled({ kx, cy }, kr, u32(active and P.cyan or '#F4F6FB'), 24)
    local label = string.format(fmt, value)
    text_mid(dl, x + w + S(14), cy, label, active and P.cyan or P.dim, F.semi, T.small)
    return value, moved, released
end

local function draw_artwork(dl, x, y, w, t)
    st.backgrounds = st.backgrounds or background_options()
    local cols = 4
    local gap = S(12)
    local tw = (w - S(48) - gap * (cols - 1)) / cols
    local th = tw * 9 / 16
    local row_h = th + S(34)
    local n = #st.backgrounds
    local rows = math.ceil(n / cols)
    local top = y + S(52)
    local changed = false
    for i, b in ipairs(st.backgrounds) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local tx, ty = x + S(24) + col * (tw + gap), top + row * row_h
        imgui.SetCursorScreenPos({ tx, ty })
        local pressed, hovered, hv = hit('##art' .. i, tw, th + S(30))
        local on = (settings.background or 'none') == b.id
        local lift = S(2) * hv
        shadow(dl, tx, ty - lift, tw, th, S(10), 0.5 + hv)
        if b.file then
            local tex = background_texture(b)
            if tex then
                local uv0, uv1 = background_uv(b, tw, th, 0.5, t)
                dl:AddImageRounded(tex, { tx, ty - lift }, { tx + tw, ty - lift + th }, uv0, uv1, u32('#FFFFFF', on and 1 or 0.8 + 0.2 * hv), S(10))
            else
                dl:AddRectFilled({ tx, ty - lift }, { tx + tw, ty - lift + th }, u32(P.well), S(10))
                text_center(dl, tx, ty - lift + th / 2, tw, "didn't load", P.faint, F.text, T.tiny)
            end
        else
            dl:AddRectFilled({ tx, ty - lift }, { tx + tw, ty - lift + th }, u32(P.well), S(10))
            icon(dl, tx + tw / 2, ty - lift + th / 2, 'ban', P.faint, T.h1)
        end
        dl:AddRect({ tx, ty - lift }, { tx + tw, ty - lift + th }, u32(on and P.accent or mix(P.line, P.accent, hv), 1), S(10), 15, on and S(2) or 1)
        if on then
            dl:AddCircleFilled({ tx + tw - S(14), ty - lift + S(14) }, S(9), u32(P.accent), 20)
            icon(dl, tx + tw - S(14), ty - lift + S(14), 'check', P.ink, T.tiny)
        end
        if b.grid then pill(dl, tx + S(8), ty - lift + S(8), 'ANIMATED', mix(P.ink, '#000000', 0.2), P.text, F.disp, T.tiny - 2, S(6)) end
        text(dl, tx + S(2), ty + th + S(6), fit(b.name, F.semi, T.small, tw - S(4)), on and P.text or P.dim, F.semi, T.small)
        local artist = ARTISTS[b.id]
        if artist then
            local nw = measure(b.name, F.semi, T.small)
            text(dl, tx + S(2) + nw + S(8), ty + th + S(8), 'by ' .. artist, P.faint, F.text, T.tiny)
        end
        if pressed and not on then settings.background = b.id changed = true end
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, b.name .. (artist and (' · art by ' .. artist) or '') .. (b.grid and ' · animated' or '')) end
    end
    local cy = top + rows * row_h + S(6)
    text_mid(dl, x + S(24), cy, 'Opacity', P.dim, F.text, T.small)
    local v, _, released = slider(dl, '##s_bg2', x + S(24) + S(64), cy, S(220), (settings.bg_opacity or 0.35) * 100, 0, 100, '%d%%')
    settings.bg_opacity = v / 100
    if released then changed = true end
    if icon_button(dl, '##bgscan2', x + S(24) + S(64) + S(220) + S(60), cy - S(14), S(28), 'rotate-right', P.dim, 'Look in bg\\ again') then st.backgrounds = nil end
    text_mid(dl, x + S(24) + S(64) + S(220) + S(96), cy, 'drop PNG or JPG files into bg\\ and rescan', P.faint, F.text, T.tiny)
    if changed then save_settings() end
    return cy + S(30) - y
end

-- handheld: one row, the beacon and the title left, the buttons right
local function draw_header_compact(dl, x, y, w, t)
    local h = S(52)
    aurora(dl, x, y, w, h + S(20), t, S(12))
    imgui.SetCursorScreenPos({ x + S(10), y + S(10) })
    local _, _, logo_hv = hit('##logo', S(34), S(34))
    local base = LOGO_SPEED[settings.logo_motion or 'slow'] or 0.35
    beacon(dl, x + S(27), y + S(27), S(30), t, 1, base + (1 - base) * logo_hv)
    gradient_text(dl, x + S(50), y + S(8), 'PARTY FINDER', P.cyan, P.accent2, F.dispb, T.h2)
    local sub = string.format('%d · %d', count_type(1), count_type(2))
    if st.pfp ~= nil then sub = sub .. string.format('   %d PFP', st.pfp) end
    text(dl, x + S(50), y + S(30), sub, P.dim, F.text, T.tiny)
    if st.pfp ~= nil then
        imgui.SetCursorScreenPos({ x + S(50), y + S(28) })
        local _, pfp_hovered = hit('##pfpc', measure(sub, F.text, T.tiny), S(16))
        if pfp_hovered then pfp_tooltip() end
    end
    local pulse = 0.55 + 0.45 * math.sin(t * 2)
    dl:AddRectFilledMultiColor({ x + S(10), y + h - 1 }, { x + w - S(10), y + h + 1 },
        u32(P.accent, 0), u32(P.cyan, 0.9 * pulse), u32(P.accent2, 0.9 * pulse), u32(P.accent, 0))
    local size = S(26)
    local bx = x + w - S(10) - size
    local by = y + S(13)
    st.tour_anchor.close = { bx, by, size, size }
    if icon_button(dl, '##close', bx, by, size, 'xmark', P.dim, 'Tuck into the beacon (Esc). /pf hide hides it') then st.mini = true end
    bx = bx - size - S(2)
    if icon_button(dl, '##settings', bx, by, size, 'gear', st.settings_open and P.accent or P.dim, 'Settings') then st.settings_open = not st.settings_open st.icons, st.backgrounds = nil, nil end
    bx = bx - size - S(2)
    local waiting = st.ping_since ~= nil
    if icon_button(dl, '##refresh', bx, by, size, 'rotate-right', waiting and P.cyan or P.dim, 'Refresh the listings') then send_refresh() end
    bx = bx - size - S(2)
    local since_bell = now_t - st.bell_at
    local bounce = since_bell < 0.8 and (1 + 0.5 * math.abs(math.sin(since_bell * 14)) * (1 - since_bell / 0.8)) or 1
    if icon_button(dl, '##notify', bx, by, size, settings.notify and 'bell' or 'bell-slash', settings.notify and P.gold or P.faint,
        settings.notify and 'LFM announcements: on' or 'LFM announcements: off', bounce) then
        settings.notify = not settings.notify save_settings()
    end
    if #st.requests > 0 then
        dl:AddCircleFilled({ bx + size - S(4), by + S(4) }, S(5), u32(P.danger), 16)
    end
    return h
end

-- handheld: the two tabs, and the category as a dropdown
local function draw_tabs_compact(dl, x, y, w)
    local h = S(32)
    local tabs = { { 2, 'RECRUIT', count_type(2) }, { 1, 'LOOKING', count_type(1) } }
    local tx = x + S(10)
    for _, tab in ipairs(tabs) do
        local lw = measure(tab[2], F.disp, T.small)
        local tw = lw + S(36)
        imgui.SetCursorScreenPos({ tx, y })
        local pressed, _, hv = hit('##tab' .. tab[1], tw, h)
        local active = st.tab == tab[1]
        if pressed then st.tab = tab[1] end
        text_mid(dl, tx + S(6), y + h / 2, tab[2], active and P.text or mix(P.dim, P.text, hv * 0.6), F.disp, T.small)
        local cx = tx + S(6) + lw + S(14)
        dl:AddCircleFilled({ cx, y + h / 2 }, S(9) * pop_scale('tab' .. tab[1], tab[3]), u32(active and P.accent or P.faint, active and 0.95 or 0.5), 24)
        text_center(dl, cx - S(9), y + h / 2, S(18), tostring(tab[3]), active and P.ink or P.text, F.bold, T.tiny - 1)
        if active then
            dl:AddRectFilledMultiColor({ tx, y + h - S(2) }, { tx + tw, y + h }, u32(P.accent, 0), u32(P.cyan, 1), u32(P.accent2, 1), u32(P.accent, 0))
        end
        tx = tx + tw + S(4)
    end
    local opts = { { id = 0, name = 'All' } }
    for _, c in ipairs(CATEGORIES) do opts[#opts + 1] = { id = c.id, name = c.name } end
    local dw = S(104)
    st.filter = dropdown(dl, '##catfilter', x + w - S(10) - dw, y + h / 2, dw, opts, st.filter or 0)
    return h
end

local function draw_tabs(dl, x, y, w)
    local h = S(38)
    local tabs = { { 2, 'RECRUITING', count_type(2), 'people-group' }, { 1, 'LOOKING', count_type(1), 'magnifying-glass' } }
    local tx = x + S(22)
    for _, tab in ipairs(tabs) do
        local label = tab[2]
        local lw = measure(label, F.disp, T.h2)
        local tw = lw + S(58)
        imgui.SetCursorScreenPos({ tx, y })
        local pressed, _, hv = hit('##tab' .. tab[1], tw, h)
        local active = st.tab == tab[1]
        if pressed then st.tab = tab[1] end
        local col = active and P.text or mix(P.dim, P.text, hv * 0.6)
        icon(dl, tx + S(10), y + h / 2, tab[4], active and P.cyan or P.faint, T.small)
        text_mid(dl, tx + S(22), y + h / 2, label, col, F.disp, T.h2)
        local cx = tx + S(22) + lw + S(16)
        local ps = pop_scale('tab' .. tab[1], tab[3])
        local ccol = active and P.accent or P.faint
        dl:AddCircleFilled({ cx, y + h / 2 }, S(11) * ps, u32(ccol, active and 0.95 or 0.5), 24)
        text_center(dl, cx - S(11), y + h / 2, S(22), tostring(tab[3]), active and P.ink or P.text, F.bold, T.tiny)
        if active then
            dl:AddRectFilledMultiColor({ tx, y + h - S(3) }, { tx + tw, y + h },
                u32(P.accent, 0), u32(P.cyan, 1), u32(P.accent2, 1), u32(P.accent, 0))
        end
        tx = tx + tw + S(6)
    end
    -- the category chips on the right
    local cx = x + w - S(22)
    for i = #CATEGORIES, 0, -1 do
        local c = i == 0 and { id = 0, name = 'ALL', color = P.dim } or CATEGORIES[i]
        local label = c.name:upper()
        local lw = measure(label, F.disp, T.small)
        local cw = lw + S(20)
        cx = cx - cw
        imgui.SetCursorScreenPos({ cx, y + S(6) })
        local pressed, _, hv = hit('##cat' .. c.id, cw, h - S(12))
        if pressed then st.filter = c.id end
        local on = st.filter == c.id
        dl:AddRectFilled({ cx, y + S(6) }, { cx + cw, y + h - S(6) }, u32(c.color, on and 0.28 or 0.06 + 0.1 * hv), S(13))
        dl:AddRect({ cx, y + S(6) }, { cx + cw, y + h - S(6) }, u32(c.color, on and 0.95 or 0.22 + 0.4 * hv), S(13), 15, 1)
        text_mid(dl, cx + S(10), y + h / 2, label, on and c.color or mix(c.color, P.dim, 0.45), F.disp, T.small)
        cx = cx - S(5)
    end
    return h
end

local function venture_rows(entry)
    local v = st.venture
    if v == nil then return nil end
    local tier
    local low = (entry.comment or ''):match('Lv(%d+)')
    if low then
        local n = tonumber(low)
        tier = n >= 60 and 6 or n >= 50 and 5 or n >= 40 and 4 or n >= 30 and 3 or n >= 20 and 2 or n >= 10 and 1 or nil
    end
    local rows = {}
    for p = 1, 2 do
        for t = 1, 6 do
            if tier == nil or tier == t then
                local r = v.pools[p][t]
                local zone = (v.mode == 1 and r.cw ~= 0) and r.cw or r.ace
                if zone ~= 0 then
                    rows[#rows + 1] = string.format('Pool %s  T%d %s: %3d%%%s', p == 1 and 'A' or 'B', t, zone_name(zone), r.progress, r.star and ' *' or '')
                end
            end
        end
    end
    return rows
end

-- the tooltip of a listing, drawn by hand so it can carry the sprites
local function entry_tooltip(entry)
    local members = entry.type == 2 and (st.members[entry.id] or {}) or {}
    local rows = entry.category == 5 and venture_rows(entry) or nil
    local w = S(340)
    local h = S(16) + S(28) + S(22)
    if entry.type == 2 then h = h + S(28) + S(24) * (1 + #members) + (entry.auto == 1 and S(20) or 0) end
    local slot_rows = {}
    if entry.type == 2 and entry.has_slots then
        -- the server says which slots are filled; the member list, matched the same way it does
        -- (members other than the leader take the first open slot they fit), puts a name to each
        local taken = {}
        for _, m in ipairs(members) do
            if m.name ~= entry.name then
                for i = 1, SLOTS.n do
                    if not taken[i] and SLOTS.fits(entry.slots[i], m.job) then taken[i] = m break end
                end
            end
        end
        for i = 1, math.max(1, math.min(SLOTS.n, (entry.max_players or 6) - 1)) do
            local is_filled = SLOTS.bit.band(entry.filled or 0, SLOTS.bit.lshift(1, i - 1)) ~= 0
            slot_rows[#slot_rows + 1] = { i = i, mask = entry.slots[i], by = taken[i], filled = is_filled }
        end
        h = h + S(26) + S(20) * #slot_rows
    end
    if rows and #rows > 0 then h = h + S(28) + S(18) * #rows + (st.venture.hvnm.spawned and S(18) or 0) end
    local comment = entry.comment or ''
    if comment ~= '' then h = h + S(22) end
    h = h + S(30)
    imgui.SetNextWindowSize({ w, h }, ALWAYS)
    imgui.BeginTooltip()
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetWindowPos()
    imgui.Dummy({ w, h })
    local cy = y + S(12)
    text(dl, x + S(14), cy, entry.name .. (entry.type == 2 and "'s party" or ''), P.text, F.disp, T.h1)
    cy = cy + S(28)
    local line = job_str(entry.job, entry.level, entry.sub, entry.sub_level) .. '   ·   ' .. zone_name(entry.zone)
    if entry.registered_at and entry.registered_at > 0 and os and os.time then
        local age = math.max(0, os.time() - entry.registered_at)
        line = line .. '   ·   ' .. (age < 60 and 'just listed' or age < 3600 and string.format('listed %dm ago', math.floor(age / 60)) or string.format('listed %dh ago', math.floor(age / 3600)))
    end
    text(dl, x + S(14), cy, line, P.dim, F.text, T.small)
    cy = cy + S(22)
    if entry.type == 2 then
        dl:AddLine({ x + S(14), cy }, { x + w - S(14), cy }, u32(P.line), 1)
        cy = cy + S(8)
        text(dl, x + S(14), cy, string.format('MEMBERS  %d / %d', entry.party_size or 1, entry.max_players or 6), P.accent, F.disp, T.small)
        local nl, nc = needs(entry)
        if entry.has_slots then
            local open = #SLOTS.open(entry)
            nl, nc = open == 0 and 'FULL' or (open .. ' OPEN'), open == 0 and P.faint or P.ok
        end
        text(dl, x + w - S(14) - measure(nl, F.disp, T.small), cy, nl, nc, F.disp, T.small)
        cy = cy + S(20)
        local function member(name, job, level, sub, slevel, leader)
            job_badge(dl, x + S(26), cy + S(11), S(10), job, 0)
            text_mid(dl, x + S(44), cy + S(11), name, leader and P.gold or P.text, F.semi, T.small)
            local jl = job_str(job, level, sub, slevel)
            local jw = measure(jl, F.text, T.small)
            text_mid(dl, x + w - S(14) - jw, cy + S(11), jl, P.dim, F.text, T.small)
            if leader then icon(dl, x + S(44) + measure(name, F.semi, T.small) + S(10), cy + S(11), 'crown', P.gold, T.tiny) end
            cy = cy + S(24)
        end
        member(entry.name, entry.job, entry.level, entry.sub, entry.sub_level, true)
        for _, m in ipairs(members) do
            if m.name ~= entry.name then member(m.name, m.job, m.level, m.sub, m.sub_level, false) end
        end
        if entry.auto == 1 then
            icon(dl, x + S(20), cy + S(8), 'circle-check', P.ok, T.small)
            text_mid(dl, x + S(32), cy + S(8), entry.min_level > 0 and string.format('Auto-accept from level %d', entry.min_level) or 'Auto-accept', P.ok, F.text, T.small)
            cy = cy + S(20)
        end
        if #slot_rows > 0 then
            cy = cy + S(4)
            dl:AddLine({ x + S(14), cy }, { x + w - S(14), cy }, u32(P.line), 1)
            cy = cy + S(8)
            text(dl, x + S(14), cy, 'SLOTS', P.accent, F.disp, T.small)
            cy = cy + S(18)
            local my = me()
            for _, sr in ipairs(slot_rows) do
                local col = SLOTS.color(sr.mask)
                local rr = SLOTS.role_of(sr.mask)
                local done = sr.filled
                if rr then role_icon(dl, x + S(26), cy + S(9), rr, S(16), done and 0.5 or 1) end
                local lbl = SLOTS.label(sr.mask, false, 4)
                text_mid(dl, x + S(40), cy + S(9), lbl, done and P.faint or col, F.semi, T.small)
                local right = done and (sr.by and (sr.by.name .. '  ' .. job_str(sr.by.job, sr.by.level)) or 'filled') or (my and SLOTS.fits(sr.mask, my.main_job) and 'open · you fit' or 'open')
                local rc = done and P.faint or (my and SLOTS.fits(sr.mask, my.main_job) and P.ok or P.dim)
                text_mid(dl, x + w - S(14) - measure(right, F.text, T.small), cy + S(9), right, rc, F.text, T.small)
                cy = cy + S(20)
            end
        end
    end
    if rows and #rows > 0 then
        dl:AddLine({ x + S(14), cy }, { x + w - S(14), cy }, u32(P.line), 1)
        cy = cy + S(8)
        text(dl, x + S(14), cy, 'CURRENT VENTURES', P.gold, F.disp, T.small)
        cy = cy + S(20)
        for _, r in ipairs(rows) do
            text(dl, x + S(14), cy, r, P.text, F.text, T.small)
            cy = cy + S(18)
        end
        if st.venture.hvnm.spawned then
            text(dl, x + S(14), cy, 'HVNM is up!', P.ok, F.semi, T.small)
            cy = cy + S(18)
        end
    end
    if comment ~= '' then
        text(dl, x + S(14), cy, fit(comment, F.text, T.small, w - S(28)), P.text, F.text, T.small)
        cy = cy + S(22)
    end
    dl:AddLine({ x + S(14), cy + S(2) }, { x + w - S(14), cy + S(2) }, u32(P.line), 1)
    cy = cy + S(10)
    local hint, hcol = nil, P.faint
    if entry.name == my_name() then hint = 'This is your listing'
    elseif not compatible(entry.mode) then hint, hcol = 'Incompatible game mode', P.danger
    else hint = entry.type == 2 and 'Double-click to join   ·   right-click for more' or 'Double-click to invite   ·   right-click for more' end
    text(dl, x + S(14), cy, hint, hcol, F.text, T.tiny)
    imgui.EndTooltip()
end

local function entry_menu(entry)
    local self = entry.name == my_name()
    if imgui.BeginPopup('##menu' .. entry.id) then
        with_font(F.text, T.body, function ()
            imgui.TextColored(rgba(P.accent), entry.name)
            imgui.Separator()
            if not self then
                if not compatible(entry.mode) then
                    imgui.TextDisabled('(Incompatible game mode)')
                elseif entry.type == 2 then
                    if imgui.MenuItem(entry.auto == 1 and 'Join party' or 'Request to join') then do_join(entry, st.create and st.create.role or 0) end
                else
                    if leader_or_solo() then
                        if imgui.MenuItem('Invite to party') then do_invite(entry) end
                    else
                        imgui.TextDisabled('Only the party leader can invite')
                    end
                end
                imgui.Separator()
                if imgui.MenuItem('Send tell') then st.tell = { name = entry.name, text = { '[Party Finder] Would you like to join my party?' } } end
                if imgui.MenuItem('Search') then vana.chat.run('/sea all ' .. entry.name, 1) end
                imgui.Separator()
                if settings.blacklist[entry.name:lower()] then
                    if imgui.MenuItem('Unblock player') then set_block(entry.name, false) end
                else
                    if imgui.MenuItem('Block player') then set_block(entry.name, true) end
                end
            else
                if imgui.MenuItem('Withdraw my listing') then do_withdraw() end
            end
        end)
        imgui.EndPopup()
    end
end

local CARD_H, CARD_H_COMPACT = 72, 54

local function draw_card_compact(dl, entry, x, y, w, t, alpha, ghost)
    local h = S(CARD_H_COMPACT)
    local key = '##card' .. entry.id
    local hovered, hv = false, 0
    if ghost then
        hv = st.hover[key] or 0
    else
        imgui.SetCursorScreenPos({ x, y })
        _, hovered, hv = hit(key, w, h)
    end
    local self = entry.name == my_name()
    local cat = CATEGORY[entry.category] or CATEGORIES[1]
    local role = ROLES[entry.role] or ROLES[0]
    local pinned = (settings.pins or {})[entry.name:lower()] == true
    local body = mix(P.card, P.card_hi, hv)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(body, alpha * (st.card_alpha or 1)), S(10))
    dl:AddRect({ x, y }, { x + w, y + h }, u32(self and P.gold or mix(P.line, cat.color, hv * 0.7), alpha), S(10), 15, self and S(1.5) or 1)
    dl:AddRectFilled({ x, y + S(9) }, { x + S(3), y + h - S(9) }, u32(cat.color, alpha), S(2))
    draw_ripples(dl, key, x, y, w, h, cat.color)
    job_badge(dl, x + S(26), y + h / 2, S(15), entry.job, hv, alpha)
    local tx = x + S(48)
    local right_w = entry.type == 2 and 6 * S(11) + S(84) or S(56)
    local name = fit(entry.name, F.disp, T.h2, w - (tx - x) - right_w - S(60))
    text(dl, tx, y + S(5), name, self and P.gold or P.text, F.disp, T.h2, alpha)
    local nw = measure(name, F.disp, T.h2)
    text(dl, tx + nw + S(6), y + S(10), job_str(entry.job, entry.level), P.dim, F.text, T.tiny, alpha)
    if pinned then icon(dl, tx + nw + S(6) + measure(job_str(entry.job, entry.level), F.text, T.tiny) + S(9), y + S(15), 'star', P.gold, T.tiny - 2, alpha) end
    local line2 = zone_name(entry.zone)
    if (entry.comment or '') ~= '' then line2 = line2 .. '  ·  ' .. entry.comment end
    text(dl, tx, y + S(31), fit(line2, F.text, T.tiny, w - (tx - x) - right_w - S(10)), P.dim, F.text, T.tiny, alpha * 0.9)
    -- right: the category icon, then dots or the role
    icon(dl, x + w - S(14), y + S(13), cat.icon, cat.color, T.tiny, alpha)
    if entry.auto == 1 then icon(dl, x + w - S(30), y + S(13), 'circle-check', P.ok, T.tiny, alpha) end
    if entry.type == 2 then
        local r, step = S(3.5), S(11)
        local n = 0
        local dx = x + w - S(8) - 6 * step
        for _, c in ipairs({ { entry.tanks, ROLES[1].color }, { entry.healers, ROLES[2].color }, { entry.supports, ROLES[3].color }, { entry.dps, ROLES[4].color } }) do
            for _ = 1, c[1] do if n < 6 then dl:AddCircleFilled({ dx + n * step + r, y + S(38) }, r, u32(c[2], alpha), 12) n = n + 1 end end
        end
        local size = math.max(entry.party_size or 1, n)
        while n < size and n < 6 do dl:AddCircleFilled({ dx + n * step + r, y + S(38) }, r, u32(P.dim, 0.9 * alpha), 12) n = n + 1 end
        while n < 6 do dl:AddCircle({ dx + n * step + r, y + S(38) }, r, u32(P.faint, 0.8 * alpha), 12, 1) n = n + 1 end
        local nl, nc = needs(entry, true)
        local cg = entry.has_slots and SLOTS.groups(entry) or {}
        if #cg > 0 then
            local more = 0
            for k = 2, #cg do more = more + cg[k].count end
            nl = SLOTS.label(cg[1].mask, true, 2) .. (cg[1].count > 1 and (' x' .. cg[1].count) or '') .. (more > 0 and (' +' .. more) or '')
            nc = cg[1].color
        end
        local nw = measure(nl, F.disp, T.tiny - 1)
        text_mid(dl, dx - S(8) - nw, y + S(38), nl, nc, F.disp, T.tiny - 1, alpha)
    else
        local rw = measure(role.short, F.disp, T.tiny - 1)
        text(dl, x + w - S(10) - rw, y + S(31), role.short, role.color, F.disp, T.tiny - 1, alpha)
    end
    if hovered and not ghost then
        entry_tooltip(entry)
        if imgui.IsMouseClicked(0) then ripple_at(key) end
        if imgui.IsMouseDoubleClicked(0) and not self then
            if not compatible(entry.mode) then say('Cannot join: incompatible game mode.')
            elseif entry.type == 2 then st.confirm = { entry = entry, kind = 'join' }
            elseif leader_or_solo() then st.confirm = { entry = entry, kind = 'invite' }
            else say('Only the party leader can invite.') end
        end
        if imgui.IsMouseClicked(1) then imgui.OpenPopup('##menu' .. entry.id) end
    end
    if not ghost then entry_menu(entry) end
    return h
end

local function draw_card(dl, entry, x, y, w, t, alpha, ghost)
    if st.compact then return draw_card_compact(dl, entry, x, y, w, t, alpha, ghost) end
    local h = S(CARD_H)
    local key = '##card' .. entry.id
    local hovered, hv = false, 0
    if ghost then
        hv = st.hover[key] or 0
    else
        imgui.SetCursorScreenPos({ x, y })
        _, hovered, hv = hit(key, w, h)
    end
    local self = entry.name == my_name()
    local cat = CATEGORY[entry.category] or CATEGORIES[1]
    local role = ROLES[entry.role] or ROLES[0]
    local lift = S(2.5) * hv
    local cx, cy = x + lift * 0.6, y - lift
    -- shadow, glow and the body
    shadow(dl, cx, cy, w, h, S(14), (0.5 + 0.9 * hv) * alpha)
    if hv > 0 then
        for i = 2, 1, -1 do
            dl:AddRect({ cx - i * S(2), cy - i * S(2) }, { cx + w + i * S(2), cy + h + i * S(2) }, u32(cat.color, 0.07 * hv * alpha), S(14) + i * S(2), 15, S(2))
        end
    end
    local body = mix(P.card, P.card_hi, hv)
    dl:AddRectFilled({ cx, cy }, { cx + w, cy + h }, u32(body, alpha * (st.card_alpha or 1)), S(14))
    -- the category colour bleeding in from the left
    dl:PushClipRect({ cx, cy }, { cx + w, cy + h }, true)
    dl:AddRectFilledMultiColor({ cx, cy }, { cx + S(220), cy + h }, u32(cat.color, 0.14 * alpha), u32(cat.color, 0), u32(cat.color, 0), u32(cat.color, 0.14 * alpha))
    dl:PopClipRect()
    dl:AddRect({ cx, cy }, { cx + w, cy + h }, u32(self and P.gold or mix(P.line, cat.color, hv * 0.7), alpha), S(14), 15, self and S(1.5) or 1)
    dl:AddRect({ cx + 1, cy + 1 }, { cx + w - 1, cy + h - 1 }, u32('#FFFFFF', 0.03 * alpha), S(14), 15, 1)
    dl:AddRectFilled({ cx, cy + S(12) }, { cx + S(4), cy + h - S(12) }, u32(cat.color, alpha), S(2))
    draw_ripples(dl, key, cx, cy, w, h, cat.color)
    -- the job sprite on its disc
    job_badge(dl, cx + S(42), cy + h / 2, S(22), entry.job, hv, alpha)
    -- name, job, mode
    local tx = cx + S(78)
    text(dl, tx, cy + S(9), entry.name, self and P.gold or P.text, F.disp, T.h1, alpha)
    local nw = measure(entry.name, F.disp, T.h1)
    local lvl = job_str(entry.job, entry.level, entry.sub, entry.sub_level)
    text(dl, tx + nw + S(10), cy + S(17), lvl, P.dim, F.text, T.small, alpha)
    local after = tx + nw + S(10) + measure(lvl, F.text, T.small) + S(8)
    if entry.mode ~= nil then
        mode_gem(dl, after + S(8), cy + S(24), entry.mode, S(16), alpha)
        if st.mode ~= nil and entry.mode ~= st.mode then
            text_mid(dl, after + S(20), cy + S(24), MODES[entry.mode] or '?', compatible(entry.mode) and P.dim or P.danger, F.semi, T.tiny, alpha)
        end
    end
    if self then icon(dl, after + S(44), cy + S(24), 'crown', P.gold, T.tiny, alpha) end
    -- second line: zone, comment
    local right_w = S(200)
    local line2 = zone_name(entry.zone)
    icon(dl, tx + S(5), cy + S(50), 'location-dot', P.faint, T.tiny, alpha)
    local zx = tx + S(14)
    text_mid(dl, zx, cy + S(50), line2, P.dim, F.text, T.small, alpha)
    if (entry.comment or '') ~= '' then
        local zw = measure(line2, F.text, T.small)
        local cxx = zx + zw + S(12)
        text_mid(dl, cxx, cy + S(50), fit(entry.comment, F.text, T.small, w - (cxx - cx) - right_w), P.text, F.text, T.small, alpha * 0.85)
    end
    -- right side: category pill, then the roles
    local rx = cx + w - S(16)
    local pw = pill(dl, 0, -1000, cat.name:upper(), cat.color, cat.color, F.disp, T.tiny, S(8), cat.icon)
    rx = rx - pw
    pill(dl, rx, cy + S(11), cat.name:upper(), mix(cat.color, P.ink, 0.74), cat.color, F.disp, T.tiny, S(8), cat.icon)
    local pinned = (settings.pins or {})[entry.name:lower()] == true
    if not ghost and (pinned or hv > 0.2) then
        local sx, sy = rx - S(24), cy + S(12)
        imgui.SetCursorScreenPos({ sx, sy })
        local spressed, shovered, shv = hit(key .. 'pin', S(20), S(20))
        icon(dl, sx + S(10), sy + S(10), 'star', pinned and P.gold or mix(P.faint, P.gold, shv), T.small, pinned and alpha or alpha * (0.4 + 0.6 * math.max(hv, shv)))
        if shovered then with_font(F.text, T.small, imgui.SetTooltip, pinned and 'Unpin' or 'Pin: stays on top, and the beacon tells you when a slot opens') end
        if spressed then
            settings.pins[entry.name:lower()] = (not pinned) and true or nil
            st.pin_sizes = st.pin_sizes or {}
            st.pin_sizes[entry.name:lower()] = (not pinned) and (entry.party_size or 1) or nil
            save_settings()
        end
    end
    if entry.auto == 1 then
        icon(dl, rx - S(12), cy + S(21), 'circle-check', P.ok, T.tiny, alpha)
        local aw = measure('auto', F.semi, T.tiny)
        text_mid(dl, rx - S(22) - aw, cy + S(21), 'auto', P.ok, F.semi, T.tiny, alpha)
    end
    if entry.type == 2 then
        local dw = 6 * S(13)
        comp_dots(dl, cx + w - S(16) - dw, cy + S(45), entry)
        local sz = string.format('%d/%d', entry.party_size or 1, entry.max_players or 6)
        local sw = measure(sz, F.semi, T.small)
        text_mid(dl, cx + w - S(16) - dw - sw - S(10), cy + S(50), sz, P.dim, F.semi, T.small, alpha)
        local right = cx + w - S(16) - dw - sw - S(22)
        local groups = entry.has_slots and SLOTS.groups(entry) or {}
        if #groups > 0 then
            local shown = math.min(#groups, 3)
            local rest = 0
            for k = shown + 1, #groups do rest = rest + groups[k].count end
            if rest > 0 then
                local more = '+' .. rest
                local mw = pill(dl, 0, -1000, more, P.dim, P.dim, F.disp, T.tiny, S(7))
                right = right - mw
                pill(dl, right, cy + S(42), more, mix(P.dim, P.ink, 0.74), P.dim, F.disp, T.tiny, S(7))
                right = right - S(5)
            end
            for k = shown, 1, -1 do
                local gw = SLOTS.pill(dl, 0, 0, groups[k], alpha, true)
                right = right - gw
                SLOTS.pill(dl, right, cy + S(42), groups[k], alpha)
                right = right - S(5)
            end
        else
            local nl, nc = needs(entry)
            local nw = pill(dl, 0, -1000, nl, nc, nc, F.disp, T.tiny, S(8))
            pill(dl, right - nw, cy + S(42), nl, mix(nc, P.ink, 0.74), nc, F.disp, T.tiny, S(8))
        end
    else
        local rw = pill(dl, 0, -1000, role.name:upper(), role.color, role.color, F.disp, T.tiny, S(8))
        local px = cx + w - S(16) - rw
        pill(dl, px, cy + S(42), role.name:upper(), mix(role.color, P.ink, 0.74), role.color, F.disp, T.tiny, S(8))
        if role.cell ~= nil then role_icon(dl, px - S(12), cy + S(51), entry.role, S(18), alpha) end
    end
    -- interactions
    if hovered and not ghost then
        entry_tooltip(entry)
        if imgui.IsMouseClicked(0) then ripple_at(key) end
        if imgui.IsMouseDoubleClicked(0) and not self then
            if not compatible(entry.mode) then
                say('Cannot join: incompatible game mode.')
            elseif entry.type == 2 then
                st.confirm = { entry = entry, kind = 'join' }
            elseif leader_or_solo() then
                st.confirm = { entry = entry, kind = 'invite' }
            else
                say('Only the party leader can invite.')
            end
        end
        if imgui.IsMouseClicked(1) then imgui.OpenPopup('##menu' .. entry.id) end
    end
    if not ghost then entry_menu(entry) end
    return h
end

local function draw_empty(dl, x, y, w, h, t)
    local msg = #st.entries == 0 and (st.ping_since and 'Asking the server…' or 'Nobody here yet') or 'Nothing matches'
    local pulse = 0.7 + 0.3 * math.sin(t * 2)
    local cx, cy = x + w / 2, y + h / 2 - S(30)
    -- the icon as the header draws it, solid, on a soft shadow so it reads over the art
    local r = S(44)
    for i = 4, 1, -1 do
        dl:AddCircleFilled({ cx, cy - S(30) + S(3) }, r + S(5) * i, u32(P.ink, 0.10), 48)
    end
    beacon(dl, cx, cy - S(30), r * 2, t, 1, 0.3)
    text_center(dl, x, cy + S(30), w, msg, P.text, F.disp, T.h1, st.ping_since and pulse or 0.9)
    if #st.entries == 0 and not st.ping_since and not st.registered then
        text_center(dl, x, cy + S(54), w, 'Be the first: create a listing below', P.dim, F.text, T.small)
    end
end

local function draw_list(dl, x, y, w, h, t)
    local rows = {}
    for _, e in ipairs(st.entries) do if visible(e) then rows[#rows + 1] = e end end
    local mine = my_name()
    local pins = settings.pins or {}
    table.sort(rows, function (a, b)
        if (a.name == mine) ~= (b.name == mine) then return a.name == mine end
        local pa, pb = pins[a.name:lower()] == true, pins[b.name:lower()] == true
        if pa ~= pb then return pa end
        return a.name < b.name
    end)
    st.tour_anchor.list = { x, y, w, h }
    local art = (not st.compact) and draw_background(dl, x, y, w, h, S(12), t, settings.bg_opacity or 0.35)
    st.card_alpha = art and 0.9 or 1
    imgui.SetCursorScreenPos({ x, y })
    imgui.PushStyleVar(VAR.ItemSpacing, { 0, 0 })
    if imgui.BeginChild('##list', { w, h }, 256, 0) then -- NavFlattened: a controller's focus walks in from outside
        local cdl = imgui.GetWindowDrawList()
        if #rows == 0 then
            draw_empty(cdl, x, y, w, h, t)
        else
            local scroll = imgui.GetScrollY()
            local top = y + S(6) - scroll
            local step = S(st.compact and CARD_H_COMPACT or CARD_H) + S(st.compact and 6 or 10)
            local seen = {}
            for i, e in ipairs(rows) do
                local target = top + (i - 1) * step
                local a = st.anim[e.id]
                if a == nil then
                    a = { t = 0, y = target, stagger = math.min(0.5, (i - 1) * 0.045) }
                    st.anim[e.id] = a
                end
                a.entry, a.gone = e, nil
                seen[e.id] = true
                a.t = math.min(1, a.t + dt * 3.2)
                a.y = lerp(a.y, target, math.min(1, dt * 12))
                local life = math.max(0, (a.t - a.stagger) / (1 - a.stagger))
                local alpha = ease(life)
                local slide = (1 - alpha) * S(26)
                if alpha > 0.01 then
                    -- the controller's focus (re)starts on the first card, two frames after the tab turns
                    if st.pad_first == 1 and i == 1 and PAD.capturing() then imgui.SetKeyboardFocusHere() end
                    draw_card(cdl, e, x + S(4) + slide, a.y, w - S(st.compact and 10 or 18), t, alpha)
                end
            end
            -- the cards that went: they fade and drift off to the right
            for id, a in pairs(st.anim) do
                if not seen[id] then
                    a.gone = a.gone or now_t
                    local gt = (now_t - a.gone) / 0.4
                    if gt >= 1 or a.entry == nil then
                        st.anim[id] = nil
                    else
                        draw_card(cdl, a.entry, x + S(4) + ease(gt) * S(40), a.y, w - S(18), t, (1 - gt) * ease(a.t), true)
                    end
                end
            end
            imgui.SetCursorScreenPos({ x, y - scroll + S(6) + #rows * step })
            imgui.Dummy({ 1, 1 })
        end
    end
    imgui.EndChild()
    imgui.PopStyleVar(1)
end

-- the party, as badges with an HP ring each, fitted into the room given; returns the width used
local function roster(dl, x, cy, max_w, t)
    local ok, party = pcall(vana.game.party)
    if not ok or party == nil or (party.party_counts and party.party_counts[1] or 1) <= 1 then return 0 end
    local members = {}
    local my_zone = party.members[1] and party.members[1].zone or 0
    for i = 1, 6 do
        local m = party.members[i]
        if m and m.active and m.name ~= '' and (m.main_job or 0) > 0 then members[#members + 1] = m end
    end
    if #members == 0 then return 0 end
    local step = S(38)
    local n = math.min(#members, math.max(0, math.floor((max_w + S(8)) / step)))
    if n == 0 then return 0 end
    for i = 1, n do
        local m = members[i]
        local cx = x + (i - 1) * step + S(15)
        local hpp = m.hpp or 0
        local away = (m.zone or my_zone) ~= my_zone
        local col = hpp > 50 and P.ok or hpp > 25 and P.warn or P.danger
        ring(dl, cx, cy, S(16), away and 0 or hpp / 100, col, P.line, S(2.5))
        job_badge(dl, cx, cy, S(12), m.main_job, 0, away and 0.45 or 1)
        if i == 1 then icon(dl, cx + S(11), cy - S(11), 'crown', P.gold, T.tiny - 2) end
        imgui.SetCursorScreenPos({ cx - S(16), cy - S(16) })
        local _, hovered = hit('##roster' .. i, S(32), S(32))
        if hovered then
            with_font(F.text, T.small, imgui.SetTooltip, string.format('%s   %s   %s', m.name, job_str(m.main_job, m.main_job_level, m.sub_job, m.sub_job_level), away and 'elsewhere' or (hpp .. '% HP')))
        end
    end
    return n * step
end

local function draw_action_bar_compact(dl, x, y, w, t)
    local h = S(46)
    panel(dl, x, y, w, h, P.glass, 0.75, S(12))
    local bh = S(30)
    local by = y + S(8)
    if st.registered then
        local pulse = 0.7 + 0.3 * math.sin(t * 3)
        dl:AddCircleFilled({ x + S(16), y + h / 2 }, S(4), u32(P.ok, pulse), 16)
        local label = st.reg.type == 2 and 'RECRUITING' or 'LOOKING'
        local cat = CATEGORY[st.reg.category]
        text(dl, x + S(28), y + S(8), label, P.ok, F.disp, T.small)
        text(dl, x + S(28), y + S(26), cat and cat.name or '?', P.dim, F.text, T.tiny)
        local rx = x + w - S(10) - S(34)
        if button(dl, '##withdraw', rx, by, S(34), bh, '', P.danger, 'ghost', 'xmark') then
            if settings.confirm_withdraw then st.confirm = { kind = 'withdraw' } else do_withdraw() end
        end
        if st.reg.type == 2 and st.reg.category == 3 then
            rx = rx - S(6) - S(34)
            if button(dl, '##roulette', rx, by, S(34), bh, '', P.accent, 'solid', 'dice') then send(C2S.ROULETTE_ROLL, 0) toast('accent', 'Duty Roulette', 'Rolling…', 4, 'dice') end
        elseif st.reg.type == 2 and st.reg.category == 2 then
            rx = rx - S(6) - S(34)
            if button(dl, '##mission', rx, by, S(34), bh, '', P.accent, 'solid', 'flag') then st.mission_select = { entries = {}, open = false } send(C2S.MISSION_START, 2, 0) end
        end
    else
        local can = leader_or_solo()
        st.tour_anchor.create = { x + S(10), by, S(150), bh }
        local pressed, hovered = button(dl, '##create', x + S(10), by, S(150), bh, 'Create listing', can and P.accent or P.faint, can and 'solid' or 'ghost', 'user-plus', F.semi, T.small)
        if pressed and can then
            st.create = st.create or { type = 2, role = 0, category = 1, auto = false, min = 1, comment = { '' } }
            st.create.open = not st.create.open
        end
        if hovered and not can then with_font(F.text, T.small, imgui.SetTooltip, 'Only the party leader can register') end
        roster(dl, x + S(172), y + h / 2, w - S(182), t)
    end
    return h
end

local function draw_action_bar(dl, x, y, w, t)
    if st.compact then return draw_action_bar_compact(dl, x, y, w, t) end
    local h = S(58)
    panel(dl, x, y, w, h, P.glass, 0.75, S(14))
    local bx = x + S(16)
    local by = y + S(12)
    local bh = S(34)
    if st.registered then
        local label = st.reg.type == 2 and 'RECRUITING' or 'LOOKING FOR GROUP'
        local cat = CATEGORY[st.reg.category]
        local pulse = 0.7 + 0.3 * math.sin(t * 3)
        dl:AddCircleFilled({ bx + S(10), y + h / 2 }, S(5), u32(P.ok, pulse), 16)
        dl:AddCircle({ bx + S(10), y + h / 2 }, S(8) + S(4) * (0.5 + 0.5 * math.sin(t * 3)), u32(P.ok, 0.35 * pulse), 16, 1)
        text(dl, bx + S(26), y + S(11), label, P.ok, F.disp, T.h2)
        text(dl, bx + S(26), y + S(34), (cat and cat.name or '?') .. (st.reg.auto and '   ·   auto-accept' or ''), P.dim, F.text, T.small)
        local rx = x + w - S(16)
        local ww = S(118)
        rx = rx - ww
        if button(dl, '##withdraw', rx, by, ww, bh, 'Withdraw', P.danger, 'ghost', 'xmark') then
            if settings.confirm_withdraw then st.confirm = { kind = 'withdraw' } else do_withdraw() end
        end
        if st.reg.type == 2 and st.reg.category == 3 then
            rx = rx - S(8) - S(136)
            if button(dl, '##roulette', rx, by, S(136), bh, 'Roulette', P.accent, 'solid', 'dice') then send(C2S.ROULETTE_ROLL, 0) toast('accent', 'Duty Roulette', 'Rolling…', 4, 'dice') end
        elseif st.reg.type == 2 and st.reg.category == 2 then
            rx = rx - S(8) - S(136)
            if button(dl, '##mission', rx, by, S(136), bh, 'Start duty', P.accent, 'solid', 'flag') then st.mission_select = { entries = {}, open = false } send(C2S.MISSION_START, 2, 0) end
        end
        roster(dl, bx + S(236), y + h / 2, rx - S(16) - (bx + S(236)), t)
    else
        local can = leader_or_solo()
        st.tour_anchor.create = { bx, by, S(186), bh }
        local pressed, hovered = button(dl, '##create', bx, by, S(186), bh, 'Create listing', can and P.accent or P.faint, can and 'solid' or 'ghost', 'user-plus')
        if pressed and can then
            st.create = st.create or { type = 2, role = 0, category = 1, auto = false, min = 1, comment = { '' } }
            st.create.open = not st.create.open
        end
        if hovered and not can then with_font(F.text, T.small, imgui.SetTooltip, 'Only the party leader can register') end
        local lfg, lfm = count_type(1), count_type(2)
        text_mid(dl, bx + S(202), y + h / 2, string.format('%d looking   ·   %d recruiting', lfg, lfm), P.dim, F.text, T.small)
        roster(dl, x + w - S(16) - 6 * S(38) + S(8), y + h / 2, 6 * S(38), t)
    end
    return h
end

-- a segmented choice: returns the picked value and the width used
-- returns the picked value, the row's width, and the option clicked this frame (also when it was already the pick)
local function segments(dl, key, x, y, h, options, value, color_of, font, size)
    local cx = x
    local clicked = nil
    for i, opt in ipairs(options) do
        local label, glyph, tip = opt[2], opt.glyph, opt.tip
        local bare = glyph ~= nil and label == '' -- a glyph on its own: no pill around it, a ring marks the pick
        local gs = glyph and (h - (bare and S(4) or S(8))) or 0
        local lw = label ~= '' and measure(label, font or F.semi, size or T.small) or 0
        local tw = bare and (gs + S(10)) or (S(22) + lw + gs + ((glyph and label ~= '') and S(6) or 0))
        imgui.SetCursorScreenPos({ cx, y })
        local pressed, hovered, hv = hit(key .. i, tw, h)
        if pressed then value = opt[1] clicked = opt[1] end
        if hovered and tip then with_font(F.text, T.small, imgui.SetTooltip, tip) end
        local on = value == opt[1]
        local color = color_of and color_of(opt) or P.accent
        if bare then
            local gx, gy = cx + tw / 2, y + h / 2
            if on then
                for k = 3, 1, -1 do dl:AddCircleFilled({ gx, gy }, gs / 2 + S(2.5) * k, u32(color, 0.09), 28) end
                dl:AddCircle({ gx, gy }, gs / 2 + S(2.5), u32(color, 0.9), 32, S(1.5))
            end
            glyph(dl, gx, gy, gs, on and 1 or 0.45 + 0.45 * hv)
            cx = cx + tw + S(4)
        elseif on then
            dl:AddRectFilled({ cx, y }, { cx + tw, y + h }, u32(color, 0.28), S(9))
            dl:AddRect({ cx, y }, { cx + tw, y + h }, u32(color, 0.95), S(9), 15, 1)
        else
            dl:AddRectFilled({ cx, y }, { cx + tw, y + h }, u32(color, 0.05 + 0.1 * hv), S(9))
            dl:AddRect({ cx, y }, { cx + tw, y + h }, u32(color, 0.22 + 0.4 * hv), S(9), 15, 1)
        end
        if bare then
            -- drawn above
        elseif glyph then
            glyph(dl, cx + S(11) + gs / 2, y + h / 2, gs, on and 1 or 0.55 + 0.45 * hv)
            text_center(dl, cx + S(11) + gs + S(6), y + h / 2, lw, label, on and color or mix(color, P.dim, 0.45), font or F.semi, size or T.small)
            cx = cx + tw + S(5)
        else
            text_center(dl, cx, y + h / 2, tw, label, on and color or mix(color, P.dim, 0.45), font or F.semi, size or T.small)
            cx = cx + tw + S(5)
        end
    end
    return value, cx - x, clicked
end

-- the role picker's options: the role's glyph in a pill, its name and meaning on hover
function SLOTS.role_options()
    local roles = {}
    for i = 0, 4 do
        local r = ROLES[i]
        roles[#roles + 1] = { i, '', r, glyph = function (dl, gx, gy, gsz, a) role_icon(dl, gx, gy, i, gsz, a) end, tip = r.name .. ' — ' .. r.about }
    end
    return roles
end

-- the inline Create Listing sheet
local function draw_create(dl, x, y, w)
    local c = st.create
    if c == nil or not c.open then return 0 end
    c.slots = c.slots or { 0, 0, 0, 0, 0 }
    local party_n = party_info()
    local n_slots = math.max(1, math.min(SLOTS.n, 6 - party_n))
    local h = c.type == 2 and S(196) or S(160)
    panel(dl, x, y, w, h, P.glass, 0.98, S(14), P.accent, true)
    local cx, cy = x + S(16), y + S(12)
    text(dl, cx, cy, 'NEW LISTING', P.accent, F.disp, T.small)
    cy = cy + S(20)
    local picked, used = segments(dl, '##ctype', cx, cy, S(30), { { 2, 'Recruit members' }, { 1, 'Look for a group' } }, c.type, nil, F.semi, T.small)
    c.type = picked
    cx = cx + used + S(16)
    local cats = {}
    for _, cat in ipairs(CATEGORIES) do cats[#cats + 1] = { cat.id, cat.name:upper(), cat } end
    c.category = (segments(dl, '##ccat', cx, cy, S(30), cats, c.category, function (o) return o[3].color end, F.disp, T.small))
    -- roles
    cx, cy = x + S(16), y + S(72)
    text_mid(dl, cx, cy + S(15), 'ROLE', P.dim, F.disp, T.small)
    cx = cx + S(50)
    local rpicked, rused = segments(dl, '##crole', cx, cy, S(30), SLOTS.role_options(), c.role, function (o) return o[3].color end, F.disp, T.small)
    if rpicked ~= c.role then
        -- the role row sets every slot; the chips refine from there
        c.role = rpicked
        for i = 1, SLOTS.n do c.slots[i] = SLOTS.ROLE[rpicked] end
    end
    text_mid(dl, cx + rused + S(4), cy + S(15), ROLES[c.role].name, ROLES[c.role].color, F.semi, T.small)
    rused = rused + S(8) + measure(ROLES[c.role].name, F.semi, T.small)
    if c.type == 2 then
        -- what each open slot wants
        local sx, sy = x + S(16), y + S(106)
        text_mid(dl, sx, sy + S(14), 'SLOTS', P.dim, F.disp, T.small)
        sx = sx + S(50)
        for i = 1, n_slots do
            sx = sx + SLOTS.chip(dl, '##slot' .. i, sx, sy + S(14), i, c.slots, n_slots) + S(6)
        end
        sx = sx + S(10)
        for pi, preset in ipairs(SLOTS.PRESETS) do
            local pw = measure(preset.name, F.semi, T.tiny) + S(20)
            if button(dl, '##preset' .. pi, sx, sy, pw, S(28), preset.name, P.dim, 'ghost', nil, F.semi, T.tiny) then
                for i = 1, SLOTS.n do c.slots[i] = preset.masks[i] end
            end
            sx = sx + pw + S(6)
        end
        cx = cx + rused + S(18)
        imgui.SetCursorScreenPos({ cx, cy + S(3) })
        with_font(F.text, T.small, function ()
            local auto = { c.auto }
            if imgui.Checkbox('Auto-accept##cauto', auto) then c.auto = auto[1] end
            if c.auto then
                imgui.SameLine()
                imgui.TextColored(rgba(P.dim), 'from level')
                imgui.SameLine()
                imgui.SetNextItemWidth(S(96))
                local min = { c.min }
                if imgui.InputInt('##cmin', min, 1, 5) then c.min = math.max(1, math.min(75, min[1])) end
            end
        end)
    end
    -- comment + buttons
    cx, cy = x + S(16), y + (c.type == 2 and S(150) or S(114))
    imgui.SetCursorScreenPos({ cx, cy })
    imgui.SetNextItemWidth(w - S(16) - S(250))
    local hint = c.category == 5 and 'Party note (the venture tier and zone are filled in by the server)' or 'A note for your listing'
    with_font(F.text, T.body, imgui.InputTextWithHint, '##ccomment', hint, c.comment, 61)
    local bx = x + w - S(16) - S(116)
    if button(dl, '##cregister', bx, cy, S(116), S(34), 'Register', P.accent, 'solid', 'check') then
        do_register(c)
        c.open = false
    end
    if button(dl, '##ccancel', bx - S(8) - S(96), cy, S(96), S(34), 'Cancel', P.dim, 'ghost') then c.open = false end
    if c.category == 5 then
        local m = me()
        local lvl = m and m.main_job_level or 1
        local tier = lvl < 20 and 'Lv10-19' or lvl < 30 and 'Lv20-29' or lvl < 40 and 'Lv30-39' or lvl < 50 and 'Lv40-49' or lvl < 60 and 'Lv50-59' or 'Lv60-69'
        text(dl, cx + S(2), cy + S(36), 'Venture ' .. tier .. ' in your zone, filled in by the server', P.gold, F.text, T.tiny)
    end
    return h
end

-- a switch with a label; returns the value, and whether it changed
local function toggle(dl, key, x, cy, label, value)
    local tw, th = S(40), S(22)
    local lw = measure(label, F.text, T.small)
    imgui.SetCursorScreenPos({ x, cy - th / 2 })
    local pressed, _, hv = hit(key, tw + S(10) + lw, th)
    if pressed then value = not value end
    local a = st.toggle_anim[key]
    if a == nil then a = value and 1 or 0 end
    a = lerp(a, value and 1 or 0, math.min(1, dt * 12))
    st.toggle_anim[key] = a
    local track = mix(P.well, P.accent, a)
    dl:AddRectFilled({ x, cy - th / 2 }, { x + tw, cy + th / 2 }, u32(track), th / 2)
    dl:AddRect({ x, cy - th / 2 }, { x + tw, cy + th / 2 }, u32(mix(P.line, P.accent, a), 0.9 + 0.1 * hv), th / 2, 15, 1)
    if a > 0 then dl:AddRect({ x - 1, cy - th / 2 - 1 }, { x + tw + 1, cy + th / 2 + 1 }, u32(P.accent, 0.25 * a * (0.5 + 0.5 * hv)), th / 2 + 1, 15, S(2)) end
    local kx = x + th / 2 + (tw - th) * a
    dl:AddCircleFilled({ kx + 1, cy + 1 }, th / 2 - S(3), u32(P.ink, 0.5), 24)
    dl:AddCircleFilled({ kx, cy }, th / 2 - S(3), u32(mix('#C9CEDB', '#FFFFFF', a)), 24)
    text_mid(dl, x + tw + S(10), cy, label, mix(P.dim, P.text, 0.5 + 0.5 * math.max(a, hv)), F.text, T.small)
    return value, pressed
end

local function draw_settings(dl, x, y, w, t)
    if not st.settings_open then return 0 end
    local h = S(542)
    if st.settings_page == 'art' then
        st.backgrounds = st.backgrounds or background_options()
        local tw = (w - S(48) - S(12) * 3) / 4
        h = S(52) + math.ceil(#st.backgrounds / 4) * (tw * 9 / 16 + S(34)) + S(48)
    end
    st.settings_h = h
    panel(dl, x, y, w, h, P.glass, 0.98, S(14), P.accent2, true)
    dl:PushClipRect({ x, y }, { x + w, y + S(44) }, true)
    dl:AddRectFilledMultiColor({ x, y }, { x + w, y + S(44) }, u32(P.accent2, 0.12), u32(P.accent, 0.04), u32(P.glass, 0), u32(P.glass, 0))
    dl:PopClipRect()
    icon(dl, x + S(24), y + S(20), 'sliders', P.accent2, T.small)
    text_mid(dl, x + S(38), y + S(20), 'SETTINGS', P.accent2, F.disp, T.h2)
    local file = 'config\\addons\\lfg\\' .. (my_name() ~= '' and my_name() or 'default') .. '.lua'
    local fw = measure(file, F.text, T.tiny)
    text_mid(dl, x + w - S(60) - fw, y + S(20), file, P.faint, F.text, T.tiny)
    if icon_button(dl, '##sclose', x + w - S(44), y + S(6), S(28), 'xmark', P.dim, 'Close the settings') then st.settings_open = false end
    -- the pages
    local page = (segments(dl, '##spage', x + S(140), y + S(7), S(26), { { 'general', 'GENERAL' }, { 'art', 'ARTWORK' } }, st.settings_page or 'general', nil, F.disp, T.tiny))
    if page ~= st.settings_page then st.settings_page = page st.backgrounds = nil end
    if page == 'art' then
        draw_artwork(dl, x, y, w, t)
        return h
    end
    local changed = false
    local top = y + S(52)
    -- the three columns, with dividers between them
    local c1, c1w = x + S(24), S(216)
    local c2, c2w = x + S(262), w - S(262) - S(222)
    local c3, c3w = x + w - S(200), S(180)
    dl:AddLine({ c2 - S(18), top }, { c2 - S(18), y + h - S(18) }, u32(P.line), 1)
    dl:AddLine({ c3 - S(18), top }, { c3 - S(18), y + h - S(18) }, u32(P.line), 1)
    local v, ch
    -- column 1
    local cy = section(dl, c1, top, c1w, 'NOTIFICATIONS', 'bell')
    cy = cy + S(14)
    v, ch = toggle(dl, '##t_notify', c1, cy, 'LFM announcements in chat', settings.notify) settings.notify = v changed = changed or ch
    cy = cy + S(34)
    v, ch = toggle(dl, '##t_sounds', c1, cy, 'Sounds', settings.sounds) settings.sounds = v changed = changed or ch
    cy = cy + S(32)
    st.sound_packs = st.sound_packs or sound_packs()
    local pack_picked = dropdown(dl, '##sound_pack', c1, cy, S(130), st.sound_packs, settings.sound_pack or 'classic')
    if pack_picked ~= (settings.sound_pack or 'classic') then settings.sound_pack = pack_picked changed = true play('join_request', true) end
    if icon_button(dl, '##sound_test', c1 + S(130) + S(8), cy - S(13), S(26), 'volume-high', P.dim, 'Hear this pack') then play('join_request', true) end
    cy = cy + S(30)
    cy = section(dl, c1, cy, c1w, 'BEHAVIOUR', 'sliders')
    cy = cy + S(14)
    v, ch = toggle(dl, '##t_confirm', c1, cy, 'Confirm before withdrawing', settings.confirm_withdraw) settings.confirm_withdraw = v changed = changed or ch
    cy = cy + S(34)
    v, ch = toggle(dl, '##t_joinable', c1, cy, 'Only listings I can join', settings.joinable_only) settings.joinable_only = v changed = changed or ch
    cy = cy + S(34)
    v, ch = toggle(dl, '##t_startmini', c1, cy, 'Start as the beacon', settings.start_mini) settings.start_mini = v changed = changed or ch
    cy = cy + S(34)
    v, ch = toggle(dl, '##t_pad', c1, cy, 'Game pad support (XInput, experimental)', PAD.enabled()) if ch then PAD.set_enabled(v) end -- one switch for every addon (vanacore.ini)
    cy = cy + S(30)
    cy = section(dl, c1, cy, c1w, 'KEYS', 'gamepad')
    cy = cy + S(12)
    local bind = (settings.keybind or ''):gsub('^%^', 'Ctrl+'):gsub('^!', 'Alt+'):gsub('^%+', 'Shift+')
    text_mid(dl, c1 + S(6), cy, bind ~= '' and (bind .. ' opens the finder') or 'No key bound', P.dim, F.text, T.small)
    cy = cy + S(20)
    text_mid(dl, c1 + S(6), cy, 'Esc tucks it into the beacon', P.faint, F.text, T.tiny)
    -- column 2
    cy = section(dl, c2, top, c2w, 'THEME', 'wand')
    cy = cy + S(16)
    local theme_opts = {}
    for _, th in ipairs(THEMES) do theme_opts[#theme_opts + 1] = { id = th.id, name = th.name } end
    local theme_picked = dropdown(dl, '##theme', c2, cy, S(170), theme_opts, settings.theme or 'aurora')
    if theme_picked ~= (settings.theme or 'aurora') then set_theme(theme_picked) end
    do
        local th = THEME_BY_ID[settings.theme or 'aurora'] or THEMES[1]
        local sx = c2 + S(170) + S(14)
        for i, k in ipairs({ 'accent', 'accent2', 'cyan', 'card_hi' }) do
            dl:AddCircleFilled({ sx + (i - 1) * S(16), cy }, S(6), u32(th.palette[k] or P[k]), 16)
        end
    end
    cy = cy + S(32)
    if button(dl, '##lookcopy', c2, cy - S(12), S(100), S(24), 'Copy look', P.dim, 'ghost', 'paper-plane', F.semi, T.tiny) then
        local look = look_string()
        pcall(vana.system.set_clipboard, look)
        toast('accent', 'Look copied', 'Paste it anywhere to share', 4, 'paper-plane')
    end
    if button(dl, '##lookpaste', c2 + S(108), cy - S(12), S(100), S(24), 'Paste look', P.dim, 'ghost', 'right-to-bracket', F.semi, T.tiny) then
        local ok_, text_or_why = pcall(vana.system.clipboard)
        local applied, why = false, 'the clipboard is empty'
        if ok_ and type(text_or_why) == 'string' then applied, why = apply_look(text_or_why) end
        if applied then toast('ok', 'Look applied', settings.theme or '', 4, 'check') else toast('danger', 'No look there', why or '', 5, 'triangle-exclamation') end
    end
    cy = cy + S(26)
    cy = section(dl, c2, cy, c2w, 'ICON', 'gem')
    cy = cy + S(6)
    st.icons = st.icons or icon_options()
    local ix = c2
    local psize = S(36)
    for i, opt in ipairs(st.icons) do
        local ccx, ccy = ix + psize / 2, cy + S(20)
        imgui.SetCursorScreenPos({ ix - S(3), cy + S(2) })
        local pressed, hovered, hv = hit('##icon' .. i, psize + S(6), psize + S(6))
        local on = (settings.icon or 'beacon') == opt.id
        if pressed and not on then settings.icon = opt.id changed = true end
        if on or hv > 0 then
            dl:AddCircle({ ccx, ccy }, psize / 2 + S(4), u32(on and P.accent or P.line, on and 1 or hv), 32, on and S(2) or 1)
        end
        draw_icon_id(dl, opt.id, ccx, ccy, psize, t, (on or hv > 0.5) and 1 or 0.25, on and 1 or 0.55 + 0.45 * hv)
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, opt.name) end
        ix = ix + psize + S(12)
    end
    do
        local ccx, ccy = ix + psize / 2, cy + S(20)
        imgui.SetCursorScreenPos({ ix - S(3), cy + S(2) })
        local _, hovered, hv = hit('##iconadd', psize + S(6), psize + S(6))
        dl:AddCircle({ ccx, ccy }, psize / 2 - S(2), u32(P.faint, 0.6 + 0.4 * hv), 32, 1)
        icon(dl, ccx, ccy, 'user-plus', mix(P.faint, P.text, hv), T.small)
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, 'Drop a square PNG into images\\icons and reopen the settings: it shows up here') end
    end
    cy = cy + S(50)
    text_mid(dl, c2, cy + S(14), 'Logo', P.dim, F.text, T.small)
    local picked = (segments(dl, '##logo_motion', c2 + S(48), cy, S(28), { { 'off', 'STILL' }, { 'slow', 'SLOW' }, { 'full', 'FULL' } }, settings.logo_motion or 'slow', nil, F.disp, T.tiny))
    if picked ~= settings.logo_motion then settings.logo_motion = picked changed = true end
    cy = cy + S(40)
    cy = section(dl, c2, cy, c2w, 'ART', 'compass')
    cy = cy + S(16)
    st.backgrounds = st.backgrounds or background_options()
    local bg_picked = dropdown(dl, '##bg', c2, cy, S(170), st.backgrounds, settings.background or 'none')
    if bg_picked ~= settings.background then settings.background = bg_picked changed = true end
    if icon_button(dl, '##bgscan', c2 + S(170) + S(6), cy - S(14), S(28), 'rotate-right', P.dim, 'Look in bg\\ again') then st.backgrounds = nil end
    local released
    cy = cy + S(32)
    text_mid(dl, c2, cy, 'Opacity', P.dim, F.text, T.small)
    v, _, released = slider(dl, '##s_bg', c2 + S(64), cy, c2w - S(64) - S(56), (settings.bg_opacity or 0.35) * 100, 0, 100, '%d%%')
    settings.bg_opacity = v / 100
    if released then changed = true end
    cy = cy + S(30)
    cy = section(dl, c2, cy, c2w, 'WINDOW', 'sliders')
    cy = cy + S(16)
    text_mid(dl, c2, cy, 'Opacity', P.dim, F.text, T.small)
    v, _, released = slider(dl, '##s_opacity', c2 + S(64), cy, c2w - S(64) - S(56), (settings.opacity or 0.96) * 100, 30, 100, '%d%%')
    settings.opacity = v / 100
    if released then changed = true end
    cy = cy + S(32)
    text_mid(dl, c2, cy, 'Scale', P.dim, F.text, T.small)
    -- the scale is applied when the slider is let go: applying it mid-drag moves the slider under the mouse
    st.scale_edit = st.scale_edit or settings.scale
    v, _, released = slider(dl, '##s_scale', c2 + S(64), cy, c2w - S(64) - S(56), st.scale_edit, 50, 300, '%d%%')
    st.scale_edit = math.floor(v + 0.5)
    if released then settings.scale = st.scale_edit changed = true end
    if not imgui.IsItemActive() and not released then st.scale_edit = settings.scale end
    cy = cy + S(32)
    text_mid(dl, c2, cy + S(14), 'Handheld', P.dim, F.text, T.small)
    local hh = (segments(dl, '##handheld', c2 + S(64), cy, S(28), { { 'auto', 'AUTO' }, { 'on', 'ON' }, { 'off', 'OFF' } }, settings.handheld or 'auto', nil, F.disp, T.tiny))
    if hh ~= (settings.handheld or 'auto') then settings.handheld = hh changed = true end
    imgui.SetCursorScreenPos({ c2 + S(64) + S(150), cy })
    local _, hhov = hit('##handheldhelp', S(24), S(28))
    icon(dl, c2 + S(64) + S(162), cy + S(14), 'circle-info', P.faint, T.tiny)
    if hhov then with_font(F.text, T.small, imgui.SetTooltip, 'A narrow panel at the screen edge, for the Steam Deck and other small screens. Auto: on at 1280x800 or less.') end
    -- column 3: the block list
    local names = {}
    for n in pairs(settings.blacklist or {}) do names[#names + 1] = n end
    table.sort(names)
    cy = section(dl, c3, top, c3w, string.format('BLOCKED  %d', #names), 'ban')
    cy = cy + S(8)
    if #names == 0 then
        text(dl, c3 + S(4), cy + S(4), 'Nobody. Right-click a listing', P.faint, F.text, T.tiny)
        text(dl, c3 + S(4), cy + S(20), 'to block someone.', P.faint, F.text, T.tiny)
    else
        for i, n in ipairs(names) do
            if i > 8 then
                text(dl, c3, cy + S(4), string.format('and %d more (/pf blocklist)', #names - 8), P.faint, F.text, T.tiny)
                break
            end
            dl:AddRectFilled({ c3, cy }, { c3 + c3w, cy + S(26) }, u32(P.card, 0.8), S(7))
            icon(dl, c3 + S(14), cy + S(13), 'ban', P.danger, T.tiny)
            text_mid(dl, c3 + S(26), cy + S(13), n:sub(1, 1):upper() .. n:sub(2), P.text, F.text, T.small)
            if icon_button(dl, '##unblock' .. i, c3 + c3w - S(26), cy + S(1), S(24), 'xmark', P.dim, 'Unblock') then
                settings.blacklist[n] = nil
                changed = true
            end
            cy = cy + S(30)
        end
    end
    if changed then save_settings() end
    return h
end

-- the join requests: cards beside the window (or the beacon), sliding in
local function draw_requests(t)
    for i = #st.requests, 1, -1 do
        if clock() - st.requests[i].at > LIMITS.request then table.remove(st.requests, i) end
    end
    local pj = st.pending_join
    if (#st.requests == 0 and pj == nil) or not st.open then return end
    local cw, ch = S(320), S(84)
    local ax, ay
    if st.mini then
        ax, ay = (st.orb.x or S(40)) - cw - S(14), st.orb.y or S(40)
    else
        if st.main == nil then return end
        ax, ay = st.main.x - cw - S(16), st.main.y + S(12)
    end
    ax = math.max(S(4), ax)
    imgui.SetNextWindowPos({ ax, ay }, ALWAYS)
    imgui.SetNextWindowSize({ cw + S(44), (#st.requests + (pj and 1 or 0)) * (ch + S(10)) }, ALWAYS)
    if imgui.Begin('##lfg_requests', nil, WINDOW_FLAGS + NO_SAVE + NO_FOCUS) then
        local dl = imgui.GetWindowDrawList()
        local cy = ay
        local done = false
        if pj then
            -- the request we sent: sent → seen → answered, with the leader's clock running down
            pj.anim = math.min(1, (pj.anim or 0) + dt * 3)
            local cx = ax + (1 - ease(pj.anim)) * S(40)
            local left = math.max(0, LIMITS.request - (clock() - pj.at))
            local col = pj.seen and P.ok or P.cyan
            shadow(dl, cx, cy, cw, ch, S(14), pj.anim)
            panel(dl, cx, cy, cw, ch, P.glass, 0.98 * pj.anim, S(14), col, true)
            dl:AddCircleFilled({ cx + S(32), cy + ch / 2 }, S(18), u32(col, (0.12 + 0.08 * math.sin(t * 3)) * pj.anim), 24)
            icon(dl, cx + S(32), cy + ch / 2, pj.seen and 'eye' or 'paper-plane', col, T.h1, pj.anim)
            text(dl, cx + S(62), cy + S(10), pj.display, P.text, F.disp, T.h1, pj.anim)
            text(dl, cx + S(62), cy + S(36), pj.seen and 'saw your request' or 'request sent', col, F.semi, T.small, pj.anim)
            text(dl, cx + S(62), cy + S(58), pj.seen and 'waiting on their answer' or 'waiting for them to see it', P.faint, F.text, T.tiny, pj.anim)
            ring(dl, cx + cw - S(112), cy + ch / 2, S(13), left / LIMITS.request, col, P.line, S(2.5))
            text_center(dl, cx + cw - S(125), cy + ch / 2, S(26), tostring(math.floor(left)), P.dim, F.semi, T.tiny)
            if button(dl, '##stopwait', cx + cw - S(90), cy + S(28), S(78), S(28), 'stop', P.faint, 'ghost', 'xmark', F.semi, T.tiny) then
                st.pending_join = nil
                toast('dim', 'Stopped waiting', "An answer from " .. pj.display .. " will still show", 4, 'circle-xmark')
            end
            cy = cy + ch + S(10)
        end
        for i, r in ipairs(st.requests) do
            r.anim = math.min(1, (r.anim or 0) + dt * 3)
            local cx = ax + (1 - ease(r.anim)) * S(40)
            local left = LIMITS.request - (clock() - r.at)
            local urgent = left <= 10
            shadow(dl, cx, cy, cw, ch, S(14), r.anim)
            panel(dl, cx, cy, cw, ch, P.glass, 0.98 * r.anim, S(14), urgent and P.danger or P.accent, true)
            job_badge(dl, cx + S(32), cy + ch / 2, S(20), r.job, 0.4 + 0.3 * math.sin(t * 4), r.anim)
            text(dl, cx + S(62), cy + S(10), r.name, P.text, F.disp, T.h1, r.anim)
            local jl = job_str(r.job, r.level)
            text(dl, cx + S(62), cy + S(36), jl, P.dim, F.text, T.small, r.anim)
            local jw = measure(jl, F.text, T.small)
            role_icon(dl, cx + S(62) + jw + S(14), cy + S(44), r.role, S(16), r.anim)
            text_mid(dl, cx + S(62) + jw + S(26), cy + S(44), ROLES[r.role].name, ROLES[r.role].color, F.semi, T.small, r.anim)
            text(dl, cx + S(62), cy + S(58), r.fit and (r.fits and r.fit or r.fit) or 'wants to join', r.fit and (r.fits and P.ok or P.warn) or P.faint, F.text, T.tiny, r.anim)
            ring(dl, cx + cw - S(112), cy + ch / 2, S(13), left / LIMITS.request, urgent and P.danger or P.cyan, P.line, S(2.5))
            text_center(dl, cx + cw - S(125), cy + ch / 2, S(26), tostring(math.max(0, math.floor(left))), urgent and P.danger or P.dim, F.semi, T.tiny)
            if not done and button(dl, '##acc' .. i, cx + cw - S(90), cy + S(12), S(36), S(28), '', P.ok, 'solid', 'check') then respond(i, true) done = true end
            if not done and button(dl, '##den' .. i, cx + cw - S(48), cy + S(12), S(36), S(28), '', P.danger, 'solid', 'xmark') then respond(i, false) done = true end
            if not done and button(dl, '##blk' .. i, cx + cw - S(90), cy + S(46), S(78), S(24), 'block', P.faint, 'ghost', 'ban', F.semi, T.tiny) then set_block(r.name, true) respond(i, false) done = true end
            cy = cy + ch + S(10)
            if done then break end
        end
    end
    imgui.End()
end

local function dialog(name, w, h, dy, fn)
    local sw, sh = vana.ui.screen()
    local x, y = (sw - w) / 2, (sh - h) / 2 + (dy or 0)
    imgui.SetNextWindowPos({ x, y }, ALWAYS)
    imgui.SetNextWindowSize({ w, h }, ALWAYS)
    if imgui.Begin(name, nil, WINDOW_FLAGS + NO_SAVE) then
        local dl = imgui.GetWindowDrawList()
        local ok, err = pcall(fn, dl, x, y)
        if not ok then fail(name, err) end
    end
    imgui.End()
end

local function draw_confirm()
    local c = st.confirm
    if c == nil then return end
    local w, h = S(400), S(164)
    local fit_line, fit_col = nil, nil
    if c.kind == 'join' and c.entry.has_slots then
        local m = me()
        local sl = SLOTS.fit(c.entry, m and m.main_job)
        if sl then fit_line, fit_col = "You'd fill slot " .. sl.i .. ' (' .. SLOTS.label(sl.mask, false, 4) .. ')', P.ok
        else fit_line, fit_col = 'Your ' .. (m and JOBS[m.main_job] or 'job') .. " isn't on their list. You can still ask", P.warn end
        h = S(186)
    end
    dialog('##lfg_confirm', w, h, 0, function (dl, x, y)
        shadow(dl, x, y, w, h, S(16), 1.5)
        panel(dl, x, y, w, h, P.glass, 1, S(16), P.accent, true)
        local title, body, yes, ic
        if c.kind == 'withdraw' then
            title, body, yes, ic = 'Withdraw your listing?', "You'll drop off the finder.", 'Withdraw', 'xmark'
        elseif c.kind == 'join' then
            title = 'Join ' .. c.entry.name .. "'s party?"
            body = job_str(c.entry.job, c.entry.level) .. ((c.entry.comment or '') ~= '' and ('   ·   ' .. fit(c.entry.comment, F.text, T.small, S(250))) or '')
            yes, ic = 'Send request', 'paper-plane'
        else
            title = 'Invite ' .. c.entry.name .. '?'
            body = job_str(c.entry.job, c.entry.level) .. '   ·   ' .. zone_name(c.entry.zone)
            yes, ic = 'Invite', 'user-plus'
        end
        text(dl, x + S(22), y + S(18), title, P.text, F.disp, T.h1)
        text(dl, x + S(22), y + S(50), body, P.dim, F.text, T.small)
        if c.kind == 'join' then
            text_mid(dl, x + S(22), y + S(90), 'AS', P.dim, F.disp, T.small)
            c.role = c.role or (st.create and st.create.role) or 0
            local _, jused
            c.role, jused = segments(dl, '##jrole', x + S(50), y + S(77), S(26), SLOTS.role_options(), c.role, function (o) return o[3].color end, F.disp, T.tiny)
            text_mid(dl, x + S(50) + jused + S(4), y + S(90), ROLES[c.role].name, ROLES[c.role].color, F.semi, T.small)
            if fit_line then text(dl, x + S(22), y + S(110), fit_line, fit_col, F.text, T.small) end
        end
        if button(dl, '##cyes', x + w - S(22) - S(136), y + h - S(50), S(136), S(34), yes, c.kind == 'withdraw' and P.danger or P.accent, 'solid', ic) then
            if c.kind == 'withdraw' then do_withdraw()
            elseif c.kind == 'join' then do_join(c.entry, c.role)
            else do_invite(c.entry) end
            st.confirm = nil
        end
        if button(dl, '##cno', x + w - S(22) - S(136) - S(8) - S(90), y + h - S(50), S(90), S(34), 'Cancel', P.dim, 'ghost') then st.confirm = nil end
    end)
end

local function draw_tell()
    local tl = st.tell
    if tl == nil then return end
    local w, h = S(480), S(136)
    dialog('##lfg_tell', w, h, S(120), function (dl, x, y)
        shadow(dl, x, y, w, h, S(16), 1.5)
        panel(dl, x, y, w, h, P.glass, 1, S(16), P.cyan, true)
        icon(dl, x + S(32), y + S(28), 'comment', P.cyan, T.h2)
        text(dl, x + S(48), y + S(16), 'Tell ' .. tl.name, P.text, F.disp, T.h1)
        imgui.SetCursorScreenPos({ x + S(22), y + S(48) })
        imgui.SetNextItemWidth(w - S(44))
        local sent = with_font(F.text, T.body, imgui.InputText, '##tellmsg', tl.text, 200, 32) -- EnterReturnsTrue
        if sent then
            vana.chat.run('/tell ' .. tl.name .. ' ' .. (tl.text[1] or ''), 1)
            st.tell = nil
            return
        end
        if button(dl, '##tsend', x + w - S(22) - S(100), y + h - S(46), S(100), S(32), 'Send', P.cyan, 'solid', 'paper-plane') then
            vana.chat.run('/tell ' .. tl.name .. ' ' .. (tl.text[1] or ''), 1)
            play('sent_tell')
            st.tell = nil
        end
        if button(dl, '##tcancel', x + w - S(22) - S(100) - S(8) - S(86), y + h - S(46), S(86), S(32), 'Cancel', P.dim, 'ghost') then st.tell = nil end
    end)
end

local function draw_mission_select()
    local ms = st.mission_select
    if ms == nil or not ms.open then return end
    local n = #ms.entries
    local w, h = S(460), S(78) + S(44) * math.max(1, n) + S(54)
    dialog('##lfg_missions', w, h, 0, function (dl, x, y)
        shadow(dl, x, y, w, h, S(16), 1.5)
        panel(dl, x, y, w, h, P.glass, 1, S(16), CATEGORY[2].color, true)
        icon(dl, x + S(32), y + S(30), 'flag', CATEGORY[2].color, T.h1)
        text(dl, x + S(52), y + S(16), 'Mission Help', P.text, F.disp, T.title - 4)
        text(dl, x + S(22), y + S(52), n > 0 and 'Pick a duty for your party' or 'No eligible duties', P.dim, F.text, T.small)
        local by = y + S(80)
        for i, m in ipairs(ms.entries) do
            if button(dl, '##mis' .. i, x + S(22), by, w - S(44), S(36), string.format('%s   ·   Lv%d   ·   up to %d', m.name, m.cap, m.max), P.text, nil, 'chevron-right', F.text, T.small) then
                send(C2S.MISSION_START, 2, m.id)
                st.mission_select = nil
                return
            end
            by = by + S(44)
        end
        if button(dl, '##mcancel', x + w - S(22) - S(96), y + h - S(46), S(96), S(32), 'Cancel', P.dim, 'ghost') then st.mission_select = nil end
    end)
end

local function draw_ready_check(t)
    local r = st.roulette
    if r == nil then return end
    if clock() > r.timeout then
        say(r.label .. ' ready check timed out.')
        st.roulette = nil
        return
    end
    local w, h = S(470), S(250)
    dialog('##lfg_ready', w, h, 0, function (dl, x, y)
        local color = r.source == 'mission' and CATEGORY[2].color or CATEGORY[3].color
        shadow(dl, x, y, w, h, S(18), 2)
        panel(dl, x, y, w, h, P.glass, 1, S(18), color, true)
        aurora(dl, x, y, w, S(96), t, S(18))
        icon(dl, x + S(32), y + S(26), r.source == 'mission' and 'flag' or 'dice', color, T.h2)
        text(dl, x + S(48), y + S(14), r.label:upper() .. (r.leader and ('   ·   started by ' .. r.leader) or ''), P.dim, F.disp, T.small)
        text(dl, x + S(22), y + S(38), fit(r.name, F.dispb, T.title - 2, w - S(130)), P.text, F.dispb, T.title - 2)
        local info = {}
        if r.cap > 0 and r.tier > 0 then info[#info + 1] = string.format('Level cap %d   ·   Tier %d', r.cap, r.tier)
        elseif r.cap > 0 and r.cap < 99 then info[#info + 1] = string.format('Level cap %d', r.cap) end
        if r.zone > 0 then info[#info + 1] = zone_name(r.zone) end
        text(dl, x + S(22), y + S(82), table.concat(info, '   ·   '), P.dim, F.text, T.small)
        -- the ring
        local left = r.timeout - clock()
        local cx, cy = x + w - S(62), y + S(54)
        ring(dl, cx, cy, S(26), left / LIMITS.ready, left <= 10 and P.danger or P.cyan, P.line, S(4))
        text_center(dl, cx - S(20), cy, S(40), tostring(math.floor(left)), P.text, F.disp, T.h2)
        -- ready progress
        local ry = y + S(118)
        if r.is_leader then
            local frac = r.total > 0 and r.ready_count / r.total or 0
            dl:AddRectFilled({ x + S(22), ry }, { x + w - S(22), ry + S(10) }, u32(P.well), S(5))
            if frac > 0 then
                dl:AddRectFilledMultiColor({ x + S(22), ry }, { x + S(22) + (w - S(44)) * frac, ry + S(10) }, u32(P.accent), u32(P.cyan), u32(P.cyan), u32(P.accent))
            end
            text(dl, x + S(22), ry + S(18), string.format('%d / %d ready', r.ready_count, r.total), P.dim, F.text, T.small)
        else
            icon(dl, x + S(30), ry + S(8), r.my_ready and 'circle-check' or 'hourglass-half', r.my_ready and P.ok or P.dim, T.body)
            text_mid(dl, x + S(46), ry + S(8), r.my_ready and 'Ready! Waiting for the party leader…' or 'Ready up when you are.', r.my_ready and P.ok or P.dim, F.text, T.body)
        end
        local by = y + h - S(52)
        local bx = x + S(22)
        if r.is_leader then
            local can = r.total > 0 and r.ready_count >= r.total
            if button(dl, '##rgo', bx, by, S(146), S(36), can and 'Commence!' or 'Waiting…', can and P.ok or P.faint, can and 'solid' or 'ghost', can and 'bolt' or 'clock') and can then
                send(C2S.ROULETTE_GO)
                st.roulette = nil
                return
            end
            bx = bx + S(154)
            if r.source == 'roulette' then
                local pressed, hovered = button(dl, '##reroll', bx, by, S(110), S(36), 'Re-roll', P.gold, 'ghost', 'dice')
                if pressed then send(C2S.ROULETTE_ROLL, 1) st.roulette = nil return end
                if hovered then with_font(F.text, T.small, imgui.SetTooltip, 'Costs 25 PFP') end
            end
        elseif not r.my_ready then
            if button(dl, '##ready', bx, by, S(146), S(36), 'Ready', P.ok, 'solid', 'check') then
                r.my_ready = true
                send(C2S.READY)
            end
        end
        if button(dl, '##rdecline', x + w - S(22) - S(110), by, S(110), S(36), 'Decline', P.danger, 'ghost', 'xmark') then
            if r.leader and not r.is_leader then send(C2S.DUTY_DECLINE) end
            say('You declined the ' .. r.label .. '.')
            st.roulette = nil
        end
    end)
end

-- the first-run tour: three callouts, each pointing at a part of the window
local TOUR = {
    { anchor = 'create', title = 'Make yourself findable', icon = 'user-plus',
      body = 'Create a listing to recruit members or to look for a group. It shows to everyone on the server, with your job, zone and a note.' },
    { anchor = 'list', title = 'The listings', icon = 'people-group',
      body = 'Double-click a card to join a party or invite someone. Right-click for a tell, a search, pinning and blocking. Hover a card to see who is in the party.' },
    { anchor = 'close', title = 'It never really closes', icon = 'compass',
      body = 'The X tucks the finder into a beacon at the edge of the screen; click the beacon to bring it back, or press Ctrl+G. Themes, art and the rest live under the gear.' },
}

local function draw_tour(t)
    local step = st.tour
    if step == nil or not st.open or st.mini or st.main == nil then return end
    local info = TOUR[step]
    if info == nil then st.tour = nil settings.tour_done = true save_settings() return end
    local a = st.tour_anchor[info.anchor]
    if a == nil then return end
    local sw, sh = vana.ui.screen()
    local w = S(340)
    local lines = wrap(info.body, F.text, T.small, w - S(40))
    local h = S(58) + #lines * S(18) + S(48)
    -- beside the anchor: above it for the bottom bar, below for the rest; kept on screen
    local ax, ay, aw, ah = a[1], a[2], a[3], a[4]
    local x, y, point
    if info.anchor == 'create' then
        x, y = ax, ay - h - S(16)
        point = { ax + S(40), ay - S(4) }
    elseif info.anchor == 'close' then
        x, y = ax + aw - w, ay + ah + S(16)
        point = { ax + aw / 2, ay + ah + S(4) }
    else
        x, y = ax + aw / 2 - w / 2, ay + S(24)
        point = { ax + aw / 2, ay + S(20) }
    end
    x = math.max(S(8), math.min(sw - w - S(8), x))
    y = math.max(S(8), math.min(sh - h - S(8), y))
    st.tour_anim = math.min(1, (st.tour_anim or 0) + dt * 4)
    local appear = ease(st.tour_anim)
    imgui.SetNextWindowPos({ x, y - (1 - appear) * S(10) }, ALWAYS)
    imgui.SetNextWindowSize({ w, h }, ALWAYS)
    if imgui.Begin('##lfg_tour', nil, WINDOW_FLAGS + NO_SAVE) then
        local dl = imgui.GetWindowDrawList()
        local wx, wy = imgui.GetWindowPos()
        shadow(dl, wx, wy, w, h, S(14), 2 * appear)
        panel(dl, wx, wy, w, h, P.glass, appear, S(14), P.accent, true)
        -- the pointer
        local fdl = imgui.GetForegroundDrawList()
        local px, py = point[1], point[2]
        local tip_y = info.anchor == 'create' and (wy + h) or wy
        fdl:AddTriangleFilled({ px - S(8), tip_y }, { px + S(8), tip_y }, { px, py }, u32(P.accent, appear))
        -- the anchor, ringed
        fdl:AddRect({ ax - S(4), ay - S(4) }, { ax + aw + S(4), ay + ah + S(4) }, u32(P.accent, (0.6 + 0.4 * math.sin(t * 4)) * appear), S(10), 15, S(2))
        icon(dl, wx + S(26), wy + S(26), info.icon, P.accent, T.h2, appear)
        text(dl, wx + S(44), wy + S(14), info.title, P.text, F.disp, T.h1, appear)
        text(dl, wx + w - S(18) - measure(step .. ' / ' .. #TOUR, F.text, T.tiny), wy + S(18), step .. ' / ' .. #TOUR, P.faint, F.text, T.tiny, appear)
        local ly = wy + S(50)
        for _, line in ipairs(lines) do
            text(dl, wx + S(20), ly, line, P.dim, F.text, T.small, appear)
            ly = ly + S(18)
        end
        local last = step == #TOUR
        if button(dl, '##tournext', wx + w - S(20) - S(96), wy + h - S(42), S(96), S(30), last and 'Done' or 'Next', P.accent, 'solid', last and 'check' or 'arrow-right') then
            st.tour = last and nil or (step + 1)
            st.tour_anim = 0
            if last then settings.tour_done = true save_settings() end
        end
        if not last and button(dl, '##tourskip', wx + S(20), wy + h - S(42), S(80), S(30), 'Skip', P.dim, 'ghost') then
            st.tour = nil
            settings.tour_done = true
            save_settings()
        end
    end
    imgui.End()
end

local function draw_toasts(t)
    -- the controller's focus: a ring round the focused thing, with a soft glow and a slow pulse
    local fo = st.focus
    if fo and st.pad_shown and fo.at == now_t then
        local fdl = imgui.GetForegroundDrawList()
        local r = math.min(S(10), fo.h / 2)
        local pulse = 0.75 + 0.25 * math.sin(t * 4)
        for i = 3, 1, -1 do
            fdl:AddRect({ fo.x - S(i) - 1, fo.y - S(i) - 1 }, { fo.x + fo.w + S(i) + 1, fo.y + fo.h + S(i) + 1 }, u32(P.accent, 0.07 * pulse * (4 - i)), r + S(i), 15, S(2))
        end
        fdl:AddRect({ fo.x - 1, fo.y - 1 }, { fo.x + fo.w + 1, fo.y + fo.h + 1 }, u32(P.accent, 0.95), r, 15, math.max(1.5, S(1.5)))
        fdl:AddRect({ fo.x, fo.y }, { fo.x + fo.w, fo.y + fo.h }, u32('#FFFFFF', 0.25 * pulse), r, 15, 1)
    end
    if st.glyph_preview then -- /pf glyphs: the role glyphs drawn large, to look at them
        local sw, sh = vana.ui.screen()
        local fdl = imgui.GetForegroundDrawList()
        local sz = S(150)
        local x = sw / 2 - 2.5 * (sz + S(30)) + S(15)
        local y = sh / 2 - sz / 2
        fdl:AddRectFilled({ x - S(30), y - S(50) }, { x + 5 * (sz + S(30)), y + sz + S(60) }, u32(P.ink, 0.9), S(16))
        for i = 0, 4 do
            local gx = x + i * (sz + S(30)) + sz / 2
            role_icon(fdl, gx, y + sz / 2, i, sz, 1)
            text_center(fdl, gx - sz / 2, y + sz + S(30), sz, ROLES[i].name, ROLES[i].color, F.disp, T.h2)
            role_icon(fdl, gx, y - S(28), i, S(26), 1)
        end
    end
    local sw = vana.ui.screen()
    local y = S(96)
    for i = #st.toasts, 1, -1 do
        local tt = st.toasts[i]
        if clock() - tt.at > tt.life + 0.4 then table.remove(st.toasts, i) end
    end
    if #st.toasts == 0 then return end
    local dl = imgui.GetForegroundDrawList()
    for _, tt in ipairs(st.toasts) do
        tt.anim = math.min(1, (tt.anim or 0) + dt * 4)
        local age = clock() - tt.at
        local fade = age > tt.life and math.max(0, 1 - (age - tt.life) / 0.4) or 1
        local a = ease(tt.anim) * fade
        local col = tt.kind == 'ok' and P.ok or tt.kind == 'danger' and P.danger or tt.kind == 'warn' and P.warn or tt.kind == 'dim' and P.dim or P.accent
        local h = S(64)
        local w = math.max(S(300), measure(tt.title, F.disp, T.h2) + S(70), measure(tt.body, F.text, T.small) + S(70))
        local x = sw - w - S(24) + (1 - ease(tt.anim)) * S(60)
        shadow(dl, x, y, w, h, S(14), a)
        panel(dl, x, y, w, h, P.glass, 0.97 * a, S(14), mix(col, P.line, 0.3), true)
        dl:AddCircleFilled({ x + S(30), y + h / 2 }, S(16), u32(col, 0.15 * a), 24)
        icon(dl, x + S(30), y + h / 2, tt.icon or 'circle-info', col, T.body, a)
        text(dl, x + S(54), y + S(10), tt.title, col, F.disp, T.h2, a)
        text(dl, x + S(54), y + S(36), tt.body, P.dim, F.text, T.small, a)
        local lt = math.max(0, 1 - age / tt.life)
        dl:AddRectFilled({ x + S(14), y + h - S(3) }, { x + S(14) + (w - S(28)) * lt, y + h - S(1) }, u32(col, 0.5 * a), S(1))
        y = y + h + S(10)
    end
end

-- the beacon: mini mode
-- the beacon's place: the saved one, else the right edge; always kept on the screen
local function orb_place(size)
    local sw, sh = vana.ui.screen()
    local x = settings.orb_x or (sw - size - S(30))
    local y = settings.orb_y or (sh / 2 - size / 2)
    x = math.max(0, math.min(sw - size, x))
    y = math.max(0, math.min(sh - size, y))
    return x, y
end

local function draw_orb(t)
    local sw, sh = vana.ui.screen()
    local size = S(72)
    local x, y = orb_place(size)
    -- dragging: the beacon follows the mouse; a press that hardly moves is a click
    local drag = st.orb_drag
    if drag then
        if imgui.IsMouseDown(0) then
            local mx, my = imgui.GetMousePos()
            x = math.max(0, math.min(sw - size, drag.x + (mx - drag.mx)))
            y = math.max(0, math.min(sh - size, drag.y + (my - drag.my)))
            drag.cx, drag.cy = x, y
            if math.abs(mx - drag.mx) + math.abs(my - drag.my) > S(5) then drag.moved = true end
        else
            if drag.moved then
                x, y = drag.cx or x, drag.cy or y
                settings.orb_x, settings.orb_y = x, y
                save_settings()
            else
                st.mini = false
            end
            st.orb_drag = nil
        end
    end
    imgui.SetNextWindowPos({ x, y }, ALWAYS)
    imgui.SetNextWindowSize({ size, size }, ALWAYS)
    if imgui.Begin('##lfg_orb', nil, WINDOW_FLAGS + NO_FOCUS + 4) then -- + NoMove: the drag is ours
        local dl = imgui.GetWindowDrawList()
        local wx, wy = imgui.GetWindowPos()
        local cx, cy = wx + size / 2, wy + size / 2
        local r = size / 2 - S(6)
        local pulse = 0.5 + 0.5 * math.sin(t * 2.2)
        local hot = #st.requests > 0 or (now_t - (st.pin_alert_at or -100)) < 20
        for i = 3, 1, -1 do
            dl:AddCircleFilled({ cx, cy }, r + S(5) * i * (0.6 + 0.4 * pulse), u32(hot and P.gold or P.accent, 0.06), 32)
        end
        beacon(dl, cx, cy, r * 2, t)
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, r + S(2), t * 1.2, t * 1.2 + math.pi * 1.3, 32)
        dl:PathStroke(u32(mix(P.cyan, P.accent2, pulse), 0.9), 0, S(2))
        local n = st.registered and count_type(st.reg.type == 2 and 1 or 2) or #st.entries
        if n > 0 then
            local ps = pop_scale('orb', n)
            local bx, by = wx + size - S(14), wy + S(14)
            dl:AddCircleFilled({ bx, by }, S(12) * ps, u32(st.registered and P.ok or P.accent), 24)
            text_center(dl, bx - S(12), by, S(24), tostring(n), P.ink, F.bold, T.tiny)
        end
        if hot then
            dl:AddCircle({ cx, cy }, r + S(5), u32(P.gold, 0.6 + 0.4 * pulse), 48, S(2))
        end
        imgui.SetCursorScreenPos({ wx, wy })
        local _, hovered = hit('##orbhit', size, size)
        if hovered and imgui.IsMouseClicked(0) and st.orb_drag == nil then
            local mx, my = imgui.GetMousePos()
            st.orb_drag = { x = x, y = y, mx = mx, my = my, moved = false }
        end
        if hovered and st.orb_drag == nil then
            with_font(F.text, T.small, imgui.SetTooltip, string.format('%d looking   ·   %d recruiting   ·   click to open, drag to move', count_type(1), count_type(2)))
        end
        if st.orb_drag and st.orb_drag.moved then
            dl:AddCircle({ cx, cy }, r + S(8), u32(P.cyan, 0.5), 48, S(1.5))
        end
        st.orb.x, st.orb.y = wx, wy
        -- the duty frame under it
        if st.duty.phase > 0 then
            local fw = S(320)
            local okp, party = pcall(vana.game.party)
            if not okp or type(party) ~= 'table' or type(party.members) ~= 'table' then party = { members = {} } end
            local rows = {}
            local my_zone = party.members[1] and party.members[1].zone or 0
            for i = 1, 6 do
                local m = party.members[i]
                if m and m.active and m.name ~= '' and (m.main_job or 0) > 0 and (m.zone or my_zone) == my_zone then rows[#rows + 1] = m end
            end
            local fh = S(36) + S(26) * #rows + S(10)
            local fx, fy = wx + size / 2 - fw / 2, wy + size + S(12)
            if fx + fw > sw then fx = sw - fw - S(10) end
            local fdl = imgui.GetForegroundDrawList()
            shadow(fdl, fx, fy, fw, fh, S(14), 1)
            panel(fdl, fx, fy, fw, fh, P.glass, 0.97, S(14), CATEGORY[3].color, true)
            icon(fdl, fx + S(20), fy + S(18), 'dice', P.gold, T.small)
            text(fdl, fx + S(34), fy + S(9), 'ACTIVE DUTY   ·   ' .. fit(st.duty.name, F.disp, T.small, fw - S(60)), P.gold, F.disp, T.small)
            local ry = fy + S(36)
            for _, m in ipairs(rows) do
                job_badge(fdl, fx + S(22), ry + S(12), S(10), m.main_job, 0)
                text_mid(fdl, fx + S(40), ry + S(12), m.name, P.text, F.semi, T.small)
                text_mid(fdl, fx + S(130), ry + S(12), job_str(m.main_job, m.main_job_level, m.sub_job, m.sub_job_level), P.dim, F.text, T.tiny)
                local hpp = m.hpp or 0
                local col = hpp > 50 and P.ok or hpp > 25 and P.warn or P.danger
                fdl:AddRectFilled({ fx + S(226), ry + S(7) }, { fx + fw - S(14), ry + S(17) }, u32(P.well), S(5))
                if hpp > 0 then
                    fdl:AddRectFilledMultiColor({ fx + S(226), ry + S(7) }, { fx + S(226) + (fw - S(240)) * hpp / 100, ry + S(17) }, u32(mix(col, P.ink, 0.2)), u32(col), u32(col), u32(mix(col, P.ink, 0.2)))
                end
                ry = ry + S(26)
            end
        end
    end
    imgui.End()
end

-- handheld: a narrow panel docked at the right edge; the sheets open as dialogs instead
-- The controller's buttons with a meaning of their own (the D-pad and Confirm are ImGui's): Cancel tucks the window
-- into the beacon as Esc does, the bumpers turn the tabs, Menu is the settings. (On PAD, not a local: this file is
-- at LuaJIT's limit of 200 locals in a chunk.)
PAD.pf_buttons = function ()
    if PAD.pressed('cancel') and not imgui.IsAnyItemActive() then
        if st.create and st.create.open then st.create.open = false
        elseif st.settings_open then st.settings_open = false
        else st.mini = true end
        return
    end
    if PAD.pressed('l1') or PAD.pressed('r1') then st.tab = st.tab == 2 and 1 or 2 st.pad_first = 3 end
    if PAD.pressed('start') then st.settings_open = not st.settings_open end
end
PAD.pf_legend = { { 'confirm', 'Select' }, { 'cancel', 'Back' }, { 'l1 r1', 'Tabs' }, { 'start', 'Settings' } }

local function draw_main_compact(t)
    local sw, sh = vana.ui.screen()
    local w, h = math.min(S(W.hh_w), sw - 20), sh - S(24)
    imgui.SetNextWindowPos({ sw - w - S(10), S(12) }, FIRST_USE_EVER)
    imgui.SetNextWindowSize({ w, h }, ALWAYS)
    if imgui.Begin('##pf_main_hh', nil, WINDOW_FLAGS) then
        local dl = imgui.GetWindowDrawList()
        local x, y = imgui.GetWindowPos()
        st.pad_focused = imgui.IsWindowFocused(3)
        if PAD.capturing() and st.pad_focused then PAD.pf_buttons() end
        local appear = ease(math.min(1, (now_t - st.opened_at) / 0.35))
        WINDOW_ALPHA = math.max(0.3, math.min(1, settings.opacity or 0.96)) * appear
        shadow(dl, x, y, w, h, S(12), 1.5)
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.bg, 0.97), S(12))
        dl:AddRect({ x, y }, { x + w, y + h }, u32(P.line), S(12), 15, 1)
        local cy = y
        cy = cy + draw_header_compact(dl, x, y, w, t) + S(6)
        cy = cy + draw_tabs_compact(dl, x, cy, w) + S(6)
        local inner_x, inner_w = x + S(8), w - S(16)
        local bar_h = S(46)
        local list_y = cy
        local list_h = y + h - S(8) - bar_h - S(6) - list_y
        draw_list(dl, inner_x, list_y, inner_w, list_h, t)
        draw_action_bar(dl, inner_x, y + h - S(8) - bar_h, inner_w, t)
        st.main = { x = x, y = y, w = w, h = h }
        if imgui.IsWindowFocused() and imgui.IsKeyPressed(PAD.KEY.escape) then
            if st.create and st.create.open then st.create.open = false
            elseif st.settings_open then st.settings_open = false
            else st.mini = true end
        end
    end
    imgui.End()
    WINDOW_ALPHA = 1
    -- the sheets, as dialogs
    if st.create and st.create.open then
        local cw = math.min(S(760), sw - S(40))
        dialog('##pf_create_dlg', cw, S(160), -S(60), function (ddl, dx, dy) draw_create(ddl, dx, dy, cw) end)
    end
    if st.settings_open then
        local cw = math.min(S(800), sw - S(40))
        local ch = math.min((st.settings_h or S(508)), sh - S(40))
        dialog('##pf_settings_dlg', cw, ch, 0, function (ddl, dx, dy) draw_settings(ddl, dx, dy, cw, t) end)
    end
end

local function draw_main(t)
    st.compact = handheld_active()
    if st.compact then return draw_main_compact(t) end
    local sw, sh = vana.ui.screen()
    local legend_h = (PAD.shown() and st.pad_focused) and S(28) or 0 -- the window the controller is in shows the legend
    local extra = ((st.create and st.create.open) and S(168) or 0) + (st.settings_open and ((st.settings_h or S(542)) + S(8)) or 0) + legend_h
    local w, h = math.min(S(W.w), sw - 40), math.min(S(W.h) + extra, sh - 40)
    imgui.SetNextWindowPos({ sw / 2, sh / 2 }, FIRST_USE_EVER, { 0.5, 0.5 })
    imgui.SetNextWindowSize({ w, h }, ALWAYS)
    local open = { true }
    if imgui.Begin('##lfg_main', open, WINDOW_FLAGS) then
        -- drawn under pcall so an error can't skip End: an unbalanced ImGui stack takes the game down
        local drew, err = pcall(function ()
        local dl = imgui.GetWindowDrawList()
        local x, y = imgui.GetWindowPos()
        -- the controller's buttons are the focused window's: two open windows never both answer a press
        st.pad_focused = imgui.IsWindowFocused(3)
        if PAD.capturing() and st.pad_focused then PAD.pf_buttons() end
        -- kept on the screen (a larger scale grows the window past its edge): from the next frame, while this one
        -- draws where ImGui has the window, inside its clip rectangle; dragged past an edge it follows the mouse and
        -- comes back whole when let go (drawn at the clamped place at once, its far side was cut off by the clip)
        local cx, cy0 = math.max(0, math.min(x, sw - w)), math.max(0, math.min(y, sh - h))
        if cx ~= x or cy0 ~= y then imgui.SetWindowPos({ cx, cy0 }) end
        -- the glass body: shadow, fill, a vignette, the edge light; the window's opacity fades all of it
        local appear = ease(math.min(1, (now_t - st.opened_at) / 0.35))
        WINDOW_ALPHA = math.max(0.3, math.min(1, settings.opacity or 0.96)) * appear
        shadow(dl, x, y, w, h, S(16), 2)
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.bg, 0.97), S(16))
        dl:AddRectFilledMultiColor({ x + S(16), y + h * 0.55 }, { x + w - S(16), y + h - S(8) }, u32(P.ink, 0), u32(P.ink, 0), u32(P.ink, 0.35), u32(P.ink, 0.35))
        dl:AddRect({ x, y }, { x + w, y + h }, u32(P.line), S(16), 15, 1)
        dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, u32('#FFFFFF', 0.04), S(16), 15, 1)
        local cy = y
        cy = cy + draw_header(dl, x, y, w, t)
        cy = cy + S(8)
        cy = cy + draw_tabs(dl, x, cy, w) + S(10)
        local inner_x, inner_w = x + S(16), w - S(32)
        local sheet = draw_create(dl, inner_x, cy, inner_w)
        if sheet > 0 then cy = cy + sheet + S(8) end
        local sett = draw_settings(dl, inner_x, cy, inner_w, t)
        if sett > 0 then cy = cy + sett + S(8) end
        -- search
        imgui.SetCursorScreenPos({ inner_x, cy })
        imgui.SetNextItemWidth(S(340))
        with_font(F.text, T.body, imgui.InputTextWithHint, '##search', 'Search names, jobs, zones, notes', st.search, 64)
        icon(dl, inner_x + S(340) - S(16), cy + S(16), 'magnifying-glass', P.faint, T.small)
        local bar_h = S(58)
        local list_y = cy + S(40)
        local list_h = y + h - S(16) - bar_h - S(10) - list_y - legend_h
        draw_list(dl, inner_x, list_y, inner_w, list_h, t)
        draw_action_bar(dl, inner_x, y + h - S(16) - bar_h - legend_h, inner_w, t)
        if legend_h > 0 then
            dl:AddLine({ x + S(16), y + h - legend_h }, { x + w - S(16), y + h - legend_h }, u32(P.line, 0.8), 1)
            local lw = PAD.legend(dl, -10000, -10000, PAD.pf_legend, 0)
            PAD.legend(dl, x + (w - lw) / 2, y + h - legend_h + S(14), PAD.pf_legend, 1)
        end
        st.main = { x = x, y = y, w = w, h = h }
        -- RootAndChildWindows (3): the list is a child window, and a click there focuses it
        if imgui.IsWindowFocused(3) and imgui.IsKeyPressed(PAD.KEY.escape) then
            if st.create and st.create.open then st.create.open = false
            elseif st.settings_open then st.settings_open = false
            else st.mini = true end
        end
        end)
        if not drew then fail('window', err) end
    end
    imgui.End()
    WINDOW_ALPHA = 1
end

-------------------------------------------------------------------------------
-- Frame
-------------------------------------------------------------------------------

local function tick()
    local now = clock()
    local io = imgui.GetIO()
    dt = math.max(0.001, math.min(0.1, io.DeltaTime or 0.016))
    scale = math.max(0.5, math.min(3, (settings.scale or 100) / 100))
    local t = imgui.GetTime()
    now_t = t
    -- the controller: its reads since the last frame become ImGui's keys while the window has it
    PAD.frame(t, { id = 'partyfinder', capture = function () return st.open and not st.mini end })
    st.pad_shown = PAD.shown()
    if st.pad_first and st.open then st.pad_first = st.pad_first - 1 if st.pad_first <= 0 then st.pad_first = nil end end

    if not F.loaded then
        load_fonts()
        load_textures()
        return -- the fonts are ready from the next frame
    end
    if my_name() ~= '' and my_name() ~= st.settings_for then
        load_settings()
        st.bound = false
        ensure_bind()
    end
    -- the beacon or the window, kept with the settings, so a zone, a reload or the next session comes back the same
    if st.mini ~= nil and st.mini ~= settings.mini and not st.duty_minimized then
        settings.mini = st.mini
        save_settings()
    end

    -- in an event (a cutscene or an NPC's conversation), from its event packet to the server's release, or with the
    -- player's status saying so: the finder and its beacon step aside and come back as they were
    if st.event_on or in_event() then
        if not st.cs_hidden then
            st.cs_hidden, st.was_open = true, st.open
            st.open = false
            st.ping_since = nil
        end
        return
    elseif st.cs_hidden then
        st.cs_hidden = false
        if st.was_open then st.open = true end
        st.was_open = nil
    end

    if st.open and logged_in() and now - st.last_refresh >= LIMITS.refresh then
        if st.gen ~= 0 and (st.server_version or 0) >= 2 then send_ping() else send_refresh() end
    end
    if st.pending_join and now - st.pending_join.at > LIMITS.wait then
        toast('dim', 'No answer from ' .. st.pending_join.display, 'They may be away. Try another party', 6, 'hourglass-end')
        st.pending_join = nil
    end
    if now - (st.old_checked or 0) > 5 then
        st.old_checked = now
        pcall(unload_old_finder)
    end
    if st.ping_since ~= nil and now - st.ping_since > LIMITS.ping then
        if st.ping_retries < LIMITS.retries then
            st.ping_retries = st.ping_retries + 1
            send_refresh(true)
        else
            st.ping_since = nil
            st.ping_retries = 0
            if not st.disabled then
                st.disabled = true
                say('Currently unavailable.')
            end
            st.open = false
        end
    end
    if st.duty.phase > 0 and not st.mini and not st.duty_minimized then
        st.duty_minimized = true
        st.mini = true
    elseif st.duty.phase == 0 then
        st.duty_minimized = false
    end
    local shown = st.open and not st.mini
    if shown and not st.was_shown then st.opened_at = t end
    st.was_shown = shown
    if shown and st.tour == nil and not settings.tour_done and logged_in() and not st.tour_offered then
        st.tour_offered = true
        st.tour = 1
        st.tour_anim = 0
    end

    push_theme()
    if shown then draw_main(t) end
    if st.open and st.mini then draw_orb(t) end
    draw_requests(t)
    draw_confirm()
    draw_tell()
    draw_mission_select()
    draw_ready_check(t)
    draw_tour(t)
    draw_toasts(t)
    pop_theme()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

vana.events.on('load', function ()
    load_settings()
    PAD.setup('partyfinder', { P = P, S = S, fonts = function () return F end, sizes = function () return T end, u32 = u32,
        text_center = text_center, text_mid = text_mid, measure = measure, clock = clock })
    unload_old_finder()
    st.open = true
    ensure_bind()
    if logged_in() then send_refresh() end
end)

vana.events.on('present', function ()
    local ok, err = pcall(tick)
    if not ok then
        fail('present', err)
        WINDOW_ALPHA = 1
        pcall(pop_theme)
    end
end)

vana.events.on('packet_in', function (e)
    if e.id == PACKET_ID then
        local ok, err = pcall(on_packet, e)
        if not ok then fail('packet', err) end
        e.blocked = true
        return true
    elseif e.id == VENTURE_ID then
        pcall(on_venture, e)
        e.blocked = true
        return true
    elseif e.id == 0x0DC then
        local ok, blocked = pcall(on_invite, e)
        if ok and blocked then return true end
    elseif e.id == 0x017 then
        -- the server's LFM chat line, stopped here: a text_in block from an addon comes too late in VanaCore.
        -- A v2 server's ANNOUNCE packet shows it instead; notify off hides it; CW and non-CW don't mix.
        local d = bytes_of(e)
        if d and d:find('is looking for members', 1, true) and d:find('[PartyFinder]', 1, true) then
            local hide = (st.server_version or 0) >= 2 or not settings.notify
            if not hide and st.mode ~= nil then hide = (st.mode == 1) ~= (d:find('[CW]', 1, true) ~= nil) end
            if hide then e.blocked = true return true end
        end
    elseif e.id == 0x032 or e.id == 0x033 or e.id == 0x034 then
        st.event_on = true -- an event started (0x032/0x033/0x034); passed on to the game untouched
    elseif e.id == 0x052 then
        st.event_on = false -- the server released the player: the event is over
    elseif e.id == 0x00A then
        pcall(on_zone_in)
    elseif e.id == 0x00B then
        st.event_on = false -- an event doesn't outlive the zone
        pcall(on_zone_out, e)
    end
end)

vana.events.on('text_in', function (e)
    local msg = e.message_modified or e.modified or e.message or e.original or e.text or ''
    if type(msg) ~= 'string' or not msg:find('is looking for members', 1, true) then return end
    if not settings.notify then e.blocked = true return true end
    if (st.server_version or 0) >= 2 then e.blocked = true return true end -- the ANNOUNCE packet shows it instead
    if st.mode ~= nil then
        local cw = msg:find('[CW]', 1, true) ~= nil
        if (st.mode == 1) ~= cw then e.blocked = true return true end
    end
end)

vana.events.on('command', function (e)
    local words = {}
    for word in e.command:gmatch('%S+') do words[#words + 1] = word end
    local cmd = (words[1] or ''):lower()
    if cmd ~= '/pf' and cmd ~= '//pf' then return false end
    local what = (words[2] or ''):lower()
    if what == '' or what == 'toggle' then
        -- the window, or the beacon; never nothing (that's /pf hide)
        if not st.open then
            st.open, st.mini = true, false
            send_refresh()
        else
            st.mini = not st.mini
            if not st.mini then send_refresh() end
        end
    elseif what == 'hide' then
        st.open = false
    elseif what == 'reset' then
        settings.orb_x, settings.orb_y = nil, nil
        settings.scale, settings.opacity = 100, 0.96
        st.orb_drag = nil
        save_settings()
        say('The beacon is back at the right edge; scale and opacity are the defaults.')
    elseif what == 'show' then
        st.open, st.mini = true, false
        send_refresh()
    elseif what == 'mini' then
        st.open = true
        st.mini = not st.mini
    elseif what == 'create' then
        st.open, st.mini = true, false
        st.create = st.create or { type = 2, role = 0, category = 1, auto = false, min = 1, comment = { '' } }
        st.create.open = not st.create.open
    elseif what == 'refresh' then
        send_refresh()
    elseif what == 'notify' then
        settings.notify = not settings.notify
        save_settings()
        say('LFM announcements ' .. (settings.notify and 'on' or 'off'))
    elseif what == 'settings' then
        st.open, st.mini, st.settings_open = true, false, true
        st.icons, st.backgrounds = nil, nil
        if words[3] then st.settings_page = (words[3]:lower() == 'art' or words[3]:lower() == 'artwork') and 'art' or 'general' end
    elseif what == 'handheld' and words[3] and (words[3]:lower() == 'auto' or words[3]:lower() == 'on' or words[3]:lower() == 'off') then
        settings.handheld = words[3]:lower()
        save_settings()
        say('Handheld mode: ' .. settings.handheld)
    elseif what == 'icon' and words[3] then
        settings.icon = words[3]:lower()
        save_settings()
    elseif what == 'tour' then
        st.open, st.mini = true, false
        st.tour, st.tour_anim = 1, 0
    elseif what == 'export' then
        local look = look_string()
        pcall(vana.system.set_clipboard, look)
        say('Your look, copied to the clipboard: ' .. look)
    elseif what == 'import' and words[3] then
        local ok_, why = apply_look(words[3])
        say(ok_ and 'Look applied.' or ('Not applied: ' .. why))
    elseif what == 'theme' and words[3] then
        if THEME_BY_ID[words[3]:lower()] then set_theme(words[3]:lower()) else
            local names = {}
            for _, th in ipairs(THEMES) do names[#names + 1] = th.id end
            say('Themes: ' .. table.concat(names, ', '))
        end
    elseif what == 'background' and words[3] then
        settings.background = words[3]:lower()
        save_settings()
    elseif what == 'sounds' then
        local pick = (words[3] or ''):lower()
        local packs = sound_packs()
        local known = nil
        for _, pk in ipairs(packs) do if pk.id == pick then known = pk end end
        if pick == 'test' then
            play('join_request', true)
        elseif known then
            settings.sound_pack = known.id
            save_settings()
            say('Sound pack: ' .. known.name)
            play('join_request', true)
        else
            local names = {}
            for _, pk in ipairs(packs) do names[#names + 1] = pk.id .. (pk.id == (settings.sound_pack or 'classic') and ' (current)' or '') end
            say('Sound packs: ' .. table.concat(names, ', ') .. '. /pf sounds <pack>, or test')
        end
    elseif what == 'scale' and tonumber(words[3]) then
        settings.scale = math.max(50, math.min(300, tonumber(words[3])))
        save_settings()
    elseif what == 'block' and words[3] then
        set_block(words[3], true)
    elseif what == 'unblock' and words[3] then
        set_block(words[3], false)
    elseif what == 'blocklist' then
        local names = {}
        for n in pairs(settings.blacklist) do names[#names + 1] = n end
        table.sort(names)
        say(#names > 0 and ('Blocked: ' .. table.concat(names, ', ')) or 'Nobody is blocked.')
    elseif what == 'glyphs' then
        st.glyph_preview = not st.glyph_preview
    elseif what == 'pad' then
        -- /pf pad: the controller's state; /pf pad on|off; /pf pad <button> [frames] presses it as a controller would
        local arg = words[3] and words[3]:lower() or nil
        if arg == nil then say(PAD.describe())
        elseif arg == 'on' or arg == 'off' then PAD.set_enabled(arg == 'on') say('Game pad support ' .. arg .. ' (for every addon: vanacore.ini [addons] gamepad)')
        elseif arg == 'stick' then PAD.inject({ lx = tonumber(words[4]) or 0, ly = tonumber(words[5]) or 0 }, tonumber(words[6]) or 3)
        else PAD.inject({ [arg] = true }, tonumber(words[4]) or 3) end
    elseif what == 'debug' then
        say(string.format('in %d, out %d, listings %d, registered %s, pfp %s, mode %s, server v%s gen %s (end flags %s, removes %d), fonts %s, textures %s', st.counts.pin, st.counts.pout, #st.entries,
            tostring(st.registered), tostring(st.pfp), tostring(st.mode), tostring(st.server_version), tostring(st.gen), tostring(st.counts.last_flags), st.counts.removes or 0, tostring(F.text ~= F.icons), tostring(TEX.jobs ~= nil)))
        say(string.format('open %s, mini %s (kept %s, start %s), event %s, hidden for it %s, duty phase %s (tucked %s), name %q, settings for %q',
            tostring(st.open), tostring(st.mini), tostring(settings.mini), tostring(settings.start_mini), tostring(st.event_on), tostring(st.cs_hidden),
            tostring(st.duty and st.duty.phase), tostring(st.duty_minimized), my_name(), tostring(st.settings_for)))
        say('last error: ' .. tostring(st.last_error))
    else
        say('/pf [mini|hide|show|reset|create|refresh|notify|settings [art]|handheld auto|on|off|tour|theme <name>|sounds <pack>|icon <name>|glyphs|export|import <look>|scale <percent>|background <name>|block <name>|unblock <name>|blocklist|debug]')
    end
    return true
end)

vana.events.on('unload', function ()
    PAD.teardown('partyfinder')
    if st.bound then vana.chat.run('/unbind ' .. settings.keybind, 1) end
    release_textures()
end)
