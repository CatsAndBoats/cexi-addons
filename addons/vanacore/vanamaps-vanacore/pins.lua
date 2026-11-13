-- Pins: what one is, the icons and colours it can have, and the code that carries one through chat.
--
-- A pin is a point of one floor's map: { zone, floor, mx, my, icon, color, title, note }. mx and my are in the
-- map's own units (512 across, as mapdata has them), so a pin sits on the picture where it was put whatever the
-- picture's size, and reads as the same grid square for everyone.
--
-- In chat a pin is ordinary text anyone can read, with a short code at its end that this addon reads back:
--   [Map: West Ronfaure G-8 "Orcish camp" #1A2B3C4D5E6]
-- The words are for people (and for players without the addon); the code alone says where. It is 55 bits in 11
-- characters of Crockford's base 32 (no I, L, O or U, so nothing reads as something else):
--   version 2 bits | zone 10 | floor 8 | x 11 | y 11 (quarter units) | icon 5 | colour 3 | check 5
local bit = require('bit')

local K = {}

-- Font Awesome's code points (the icon font VanaCore merges into ImGui's); the order is the code's, so only add at
-- the end
K.ICONS = {
    { id = 'pin',      cp = 0xF3C5, name = 'Pin' },
    { id = 'star',     cp = 0xF005, name = 'Star' },
    { id = 'flag',     cp = 0xF024, name = 'Flag' },
    { id = 'skull',    cp = 0xF54C, name = 'Danger' },
    { id = 'gem',      cp = 0xF3A5, name = 'Treasure' },
    { id = 'crown',    cp = 0xF521, name = 'Notorious monster' },
    { id = 'heart',    cp = 0xF004, name = 'Favourite' },
    { id = 'house',    cp = 0xF015, name = 'Home' },
    { id = 'door',     cp = 0xF52B, name = 'Way through' },
    { id = 'key',      cp = 0xF084, name = 'Key or door' },
    { id = 'fish',     cp = 0xF578, name = 'Fishing' },
    { id = 'tree',     cp = 0xF1BB, name = 'Logging' },
    { id = 'mountain', cp = 0xF6FC, name = 'Mining' },
    { id = 'leaf',     cp = 0xF06C, name = 'Harvesting' },
    { id = 'paw',      cp = 0xF1B0, name = 'Monster' },
    { id = 'dragon',   cp = 0xF6D5, name = 'Boss' },
    { id = 'users',    cp = 0xF0C0, name = 'Meet here' },
    { id = 'camp',     cp = 0xF6BB, name = 'Camp' },
    { id = 'coins',    cp = 0xF51E, name = 'Shop or gil' },
    { id = 'scroll',   cp = 0xF70E, name = 'Quest' },
    { id = 'bolt',     cp = 0xF0E7, name = 'Warp' },
    { id = 'eye',      cp = 0xF06E, name = 'Look here' },
    { id = 'question', cp = 0xF128, name = 'Unknown' },
    { id = 'bang',     cp = 0xF12A, name = 'Important' },
}
K.ICON_BY_ID = {}
for i, ic in ipairs(K.ICONS) do ic.n = i - 1 K.ICON_BY_ID[ic.id] = ic end

K.COLORS = { '#FF6B6B', '#FF9F45', '#FFD166', '#5EE39A', '#5BE0FF', '#7C8CFF', '#C98BFF', '#F1F3F9' }
K.COLOR_NAMES = { 'Red', 'Orange', 'Gold', 'Green', 'Cyan', 'Blue', 'Violet', 'White' }

local ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
local VALUE = {}
for i = 1, #ALPHABET do VALUE[ALPHABET:sub(i, i)] = i - 1 end
-- (what a hand might type for them)
VALUE.I, VALUE.L, VALUE.O, VALUE.U = 1, 1, 0, VALUE.V

local FIELDS = { { 'version', 2 }, { 'zone', 10 }, { 'floor', 8 }, { 'x', 11 }, { 'y', 11 }, { 'icon', 5 }, { 'color', 3 } }
local VERSION = 1

local function check_of(groups)
    local c = 7
    for i = 1, 10 do c = (c * 31 + groups[i] * (i + 2) + 3) % 32 end
    return c
end

-- the 11 characters for a pin
function K.encode(pin)
    local icon = (K.ICON_BY_ID[pin.icon] or K.ICONS[1]).n
    local color = math.max(1, math.min(8, math.floor(tonumber(pin.color) or 1))) - 1
    local values = {
        version = VERSION,
        zone = math.max(0, math.min(1023, math.floor(pin.zone))),
        floor = bit.band(math.floor(pin.floor or 0), 0xFF),
        x = math.max(0, math.min(2047, math.floor((pin.mx or 0) * 4 + 0.5))),
        y = math.max(0, math.min(2047, math.floor((pin.my or 0) * 4 + 0.5))),
        icon = icon, color = color,
    }
    local bits = {}
    for _, f in ipairs(FIELDS) do
        local v = values[f[1]]
        for b = f[2] - 1, 0, -1 do bits[#bits + 1] = math.floor(v / 2 ^ b) % 2 end
    end
    local groups = {}
    for g = 0, 9 do
        local v = 0
        for b = 1, 5 do v = v * 2 + bits[g * 5 + b] end
        groups[g + 1] = v
    end
    groups[11] = check_of(groups)
    local out = {}
    for i = 1, 11 do out[i] = ALPHABET:sub(groups[i] + 1, groups[i] + 1) end
    return table.concat(out)
end

-- a pin's place from its code, or nil if it isn't one
function K.decode(code)
    if type(code) ~= 'string' then return nil end
    code = code:upper():gsub('[^%w]', '')
    if #code ~= 11 then return nil end
    local groups = {}
    for i = 1, 11 do
        local v = VALUE[code:sub(i, i)]
        if v == nil then return nil end
        groups[i] = v
    end
    if check_of(groups) ~= groups[11] then return nil end
    local bits = {}
    for g = 1, 10 do
        for b = 4, 0, -1 do bits[#bits + 1] = math.floor(groups[g] / 2 ^ b) % 2 end
    end
    local values, at = {}, 1
    for _, f in ipairs(FIELDS) do
        local v = 0
        for _ = 1, f[2] do v = v * 2 + bits[at] at = at + 1 end
        values[f[1]] = v
    end
    if values.version ~= VERSION then return nil end
    local floor = values.floor
    if floor >= 128 then floor = floor - 256 end
    local icon = K.ICONS[values.icon + 1] or K.ICONS[1]
    return { zone = values.zone, floor = floor, mx = values.x / 4, my = values.y / 4, icon = icon.id, color = values.color + 1,
        code = table.concat({ code }) }
end

-- what goes on the chat line: plain ASCII, so it passes through the game's Shift-JIS untouched
local function chat_safe(s, most)
    s = tostring(s or ''):gsub('[^\32-\126]', ''):gsub('["%[%]#]', ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
    if #s > most then s = s:sub(1, most):gsub(' $', '') end
    return s
end

function K.token(pin, zone_name, square)
    local words = 'Map: ' .. chat_safe(zone_name, 32)
    if square and square ~= '' and square ~= '?-?' then words = words .. ' ' .. square end
    local title = chat_safe(pin.title, 28)
    if title ~= '' then words = words .. ' "' .. title .. '"' end
    return '[' .. words .. ' #' .. K.encode(pin) .. ']'
end

-- every pin in a line of chat: { { code, zone, floor, mx, my, icon, color, title, words }, ... }
function K.find(text)
    local found = {}
    if type(text) ~= 'string' or not text:find('[Map:', 1, true) then return found end
    for words, code in text:gmatch('%[Map: ([^%[%]]-) ?#([%w]+)%]') do
        local pin = K.decode(code)
        if pin then
            pin.title = words:match('"([^"]*)"') or ''
            pin.words = words
            found[#found + 1] = pin
        end
    end
    return found
end

-- a bare code too (what a chat addon hands /vmap open): '#1A2B...', '1A2B...' or a whole token
function K.parse(text)
    local list = K.find(text)
    if list[1] then return list[1] end
    local code = tostring(text or ''):match('#?([%w]+)%s*$')
    local pin = code and K.decode(code)
    if pin then pin.title = '' end
    return pin
end

return K
