-- FFXI menu visibility — lifted from fancychat (lib/render.lua).
-- The substring list below is the union of EVERY menu fancychat
-- watches when deciding whether to shift its chat window
-- (Menu1..Menu7). When any of these is on top of the menu stack,
-- the compass hides — same trigger as fancychat's MoveChat.

local M = {}

-- Pointer to the FFXI menu-stack head, resolved at .init() and
-- read each frame.
local menu_ptr = 0

-- Exact union of fancychat's Menu1..Menu7 patterns. Order matches
-- the source for easy cross-checking:
local MENU_PATTERNS = {
    -- Menu1
    'inventor', 'loot',  'comyn',    'comment',
    -- Menu2
    'magic',    'ability', 'mount',  'emote',
    -- Menu3
    'magselec',
    -- Menu4
    'jobcselu',
    -- Menu5
    'mogdoor',  'chatctrl', 'arealist', 'maplist',
    'gmtell',   'merityn',  'roomlist',
    -- Menu6 (auto-translate)
    'fep',
    -- Menu7
    'rmlo2',    'shopbuy',  'guildsho', 'shopmain',
    'shopsell', 'abiselec', 'mogext',   'myroom',
    'storage',  'mogpost',  'jobchang', 'playermo',
}

function M.init()
    local p = ashita.memory.find('FFXiMain.dll', 0,
        '8B480C85C974??8B510885D274??3B05', 16, 0)
    if p ~= 0 then menu_ptr = ashita.memory.read_uint32(p) end
end

-- Internal name of whatever menu is on top of the stack. Empty
-- string when nothing is open. Memory walk mirrors fancychat:
-- *menu_ptr -> MenuID, +4 -> name struct, +0x46 -> 16-byte ASCII.
function M.current_name()
    if menu_ptr == 0 then return '' end
    local id = ashita.memory.read_uint32(menu_ptr)
    if id == 0 then return '' end
    local s = ashita.memory.read_string(
        ashita.memory.read_uint32(id + 4) + 0x46, 16)
    s = s:gsub('\x00', '')
    return (s:match('^%s*(.-)%s*$')) or ''
end

-- True if the on-top menu is one fancychat would shift for.
function M.is_menu_open()
    local name = M.current_name()
    if name == '' then return false end
    for i = 1, #MENU_PATTERNS do
        if name:match('menu[%s]+' .. MENU_PATTERNS[i]) then return true end
    end
    return false
end

return M
