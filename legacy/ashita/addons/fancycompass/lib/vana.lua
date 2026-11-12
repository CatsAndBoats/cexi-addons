-- Vana'diel time helper (signature from GlamourUI/environment.lua).
-- Provides current time HH:MM string and day index (0..7 = Firesday..Darksday).

local vana = {}

local TIME_SIG = 'B0015EC390518B4C24088D4424005068'
local time_sig_addr = 0

function vana.init()
    time_sig_addr = ashita.memory.find('FFXiMain.dll', 0, TIME_SIG, 0, 0)
end

function vana.get_time()
    if time_sig_addr == 0 then return '??:??', 0 end
    local ptr = ashita.memory.read_uint32(time_sig_addr + 0x34)
    if ptr == 0 then return '??:??', 0 end
    local t   = ashita.memory.read_uint32(ptr + 0x0C) + 92514960
    local hr  = math.floor(t / 144) % 24
    local mn  = math.floor((t % 144) / 2.4)
    local day = math.floor(t / 3456) % 8
    return ('%02d:%02d'):format(hr, mn), day
end

vana.DAY_NAMES = {
    [0] = 'Firesday',
    [1] = 'Earthsday',
    [2] = 'Watersday',
    [3] = 'Windsday',
    [4] = 'Iceday',
    [5] = 'Lightningday',
    [6] = 'Lightsday',
    [7] = 'Darksday',
}

-- Elemental day colors (ABGR). Index matches the day value returned above.
vana.DAY_COLORS = {
    [0] = 0xFF3344EE,  -- Firesday      (red)
    [1] = 0xFF22DDEE,  -- Earthsday     (yellow)
    [2] = 0xFFEE5522,  -- Watersday     (azure)
    [3] = 0xFF44CC44,  -- Windsday      (green)
    [4] = 0xFFF5D8A0,  -- Iceday        (pale icy blue)
    [5] = 0xFFCC44FF,  -- Lightningday  (pink)
    [6] = 0xFFEEEEEE,  -- Lightsday     (white)
    [7] = 0xFF333333,  -- Darksday      (near black)
}

return vana
