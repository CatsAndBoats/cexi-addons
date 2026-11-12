-- Map grid coordinates (e.g. "G-9") from FFXI's internal map table.
-- Logic adapted from boussole/src/map.lua. Reads the per-zone Scale,
-- OffsetX, OffsetY from the FFXiMain.dll map table and converts world
-- (X, Y) to grid letter + number.

local grid = {}

local MAP_TABLE_SIG = '8A0D????????5333C05684C95774??8A5424188B7424148B7C2410B9'
local ENTRY_SIZE    = 0x0E
local map_table_addr = 0
local zone_cache = { id = -1, scale = nil, offX = 0, offY = 0 }

function grid.init()
    local m = ashita.memory.find('FFXiMain.dll', 0, MAP_TABLE_SIG, 0, 0)
    if m ~= 0 then
        map_table_addr = ashita.memory.read_uint32(m + 0x1C)
    end
end

local function get_zone_entry(zone_id)
    if zone_id == zone_cache.id then
        return zone_cache.scale, zone_cache.offX, zone_cache.offY
    end
    zone_cache.id, zone_cache.scale = zone_id, nil
    if map_table_addr == 0 then return nil end
    for i = 0, 999 do
        local base = map_table_addr + i * ENTRY_SIZE
        local z = ashita.memory.read_uint16(base + 0x00)
        if z == zone_id then
            local s_raw = ashita.memory.read_uint8(base + 0x05)
            local scale = (s_raw >= 0x80) and (s_raw - 0x100) or s_raw
            local x_raw = ashita.memory.read_uint16(base + 0x0A)
            local offX  = (x_raw >= 0x8000) and (x_raw - 0x10000) or x_raw
            local y_raw = ashita.memory.read_uint16(base + 0x0C)
            local offY  = (y_raw >= 0x8000) and (y_raw - 0x10000) or y_raw
            zone_cache.scale, zone_cache.offX, zone_cache.offY = scale, offX, offY
            return scale, offX, offY
        end
    end
    return nil
end

function grid.get_coords()
    local party = AshitaCore:GetMemoryManager():GetParty()
    local zid   = party:GetMemberZone(0)
    if zid == 0 then return '?-?' end
    local scale, offX, offY = get_zone_entry(zid)
    if not scale or scale == 0 then return '?-?' end
    local p = GetPlayerEntity()
    if p == nil then return '?-?' end
    local px = p.Movement.LocalPosition.X
    local py = p.Movement.LocalPosition.Y
    local v5 = math.abs(scale) / 2560.0
    local mapX = math.floor(px * v5 * 512 + 0.5)
    local mapY = -math.floor(py * v5 * 512 + 0.5)
    mapX = bit.band(mapX, 0xFFFF); if mapX >= 0x8000 then mapX = mapX - 0x10000 end
    mapY = bit.band(mapY, 0xFFFF); if mapY >= 0x8000 then mapY = mapY - 0x10000 end
    local gx = math.floor((mapX - offX - 16) / 32)
    local gy = math.floor((mapY - offY - 16) / 32) + 1
    if gx < 0 then gx = 0 end
    if gx > 25 then gx = 25 end
    return string.char(string.byte('A') + gx) .. '-' .. gy
end

return grid
