-- The game's own map data, read from the client as it runs: which map each zone and floor has, the DAT file it is
-- in, and how a position in the world lands on it. Nothing here is shipped with the addon: the table is the one the
-- game's Map menu uses (so it covers every zone, not only the one you stand in), and the DAT paths come from the
-- game's file tables (VTABLE / FTABLE), read through the same overlays the game reads them through.
--
-- The table (found by the signature the Ashita Minimap plugin uses for it) is rows of 14 bytes:
--   +0  int16  zone            +2  int8  floor (the game's sub-map number)     +3  uint8  the floor's place in the list
--   +4  uint8  flags: the low four bits pick the map files' base id, the high four the key items' base id
--   +5  int8   scale (0 ends the table)             +6  int8  the map's key item, from its base
--   +8  int16  the map's DAT, from its base         +10 int16 x offset         +12 int16 y offset
-- A map is 512 units across whatever its picture's size, with a 32-unit grid that starts 16 units in:
--   map x = x * scale / 5 - x offset        map y = -(y * scale / 5) - y offset
-- (the game rounds x * scale / 5 + 0.5 towards zero before taking the offset off; M.grid does the same, so the square
-- it names is the one <pos> gives).
local ffi = require('ffi')
local bit = require('bit')

local M = { ready = false, why = nil, zones = {}, order = {}, count = 0 }

local TABLE_SIG = '8A 0D ?? ?? ?? ?? 53 33 C0 56 84 C9 57 74 ?? 8A 54 24 18 8B 74 24 14 8B 7C 24 10 B9'
local FLOOR_SIG = '8B 54 24 08 56 8D 44 24 10 8B F1 8B 4C 24 10 50 8B 44 24 0C' -- int __thiscall floor_at(this, x, h, y)
local ZONE_SIG  = '8B 74 24 14 8B 44 24 10 8B 7C 24 0C 8B 0D'                   -- then the address of floor_at's `this`
local FILE_BASE = { [0] = 0x14C0, [1] = 0xD02F, [2] = 0xD417 }
local KEY_BASE  = { [0x00] = 0x180, [0x10] = 0x73F, [0x20] = 0x8FD }
local SIZE = 512 -- a map's own units across

local mem = vana.memory

local function s8(v) return v >= 128 and v - 256 or v end
local function s16(v) return v >= 32768 and v - 65536 or v end

-- Reads the table. True once it has; false and why if the client isn't the one this was written for.
function M.load()
    if M.ready then return true end
    local at = mem.find('FFXiMain.dll', 0, TABLE_SIG, 0, 0)
    if at == nil or at == 0 then
        M.why = "the game's map table wasn't found"
        return false, M.why
    end
    local rows = mem.read_uint32(at + 28)
    if rows == 0 then
        M.why = "the game's map table is empty"
        return false, M.why
    end
    local zones, order, n = {}, {}, 0
    while n < 4000 do
        local raw = mem.read_bytes(rows + n * 14, 14)
        if raw == nil or #raw < 14 then break end
        local b = { raw:byte(1, 14) }
        local scale = s8(b[6])
        if scale == 0 then break end
        local zone, flags = s16(b[1] + b[2] * 256), b[5]
        local key = s8(b[7])
        local floor = {
            zone = zone, floor = s8(b[3]), place = b[4], scale = math.abs(scale),
            ox = s16(b[11] + b[12] * 256), oy = s16(b[13] + b[14] * 256),
            file = s16(b[9] + b[10] * 256) + (FILE_BASE[bit.band(flags, 0x0F)] or 0x1592),
            key_item = key > 0 and (key + (KEY_BASE[bit.band(flags, 0xF0)] or 0x180)) or nil,
        }
        local z = zones[zone]
        if z == nil then
            z = { id = zone, floors = {}, by_floor = {} }
            zones[zone] = z
            order[#order + 1] = zone
        end
        if z.by_floor[floor.floor] == nil then
            z.floors[#z.floors + 1] = floor
            z.by_floor[floor.floor] = floor
        end
        n = n + 1
    end
    for _, z in pairs(zones) do
        table.sort(z.floors, function (a, b2) return a.place < b2.place end)
    end
    table.sort(order)
    M.zones, M.order, M.count, M.ready = zones, order, n, n > 0
    if not M.ready then M.why = "the game's map table is empty" end

    -- the game's own "which floor is this position on" (it asks the zone's collision under the position), for the
    -- zone you are in
    local fn = mem.find('FFXiMain.dll', 0, FLOOR_SIG, 0, 0)
    local zp = mem.find('FFXiMain.dll', 0, ZONE_SIG, 0, 0)
    if fn ~= nil and fn ~= 0 and zp ~= nil and zp ~= 0 then
        local ok, f = pcall(ffi.cast, 'int (__thiscall *)(void*, float, float, float)', fn)
        if ok then M.floor_fn, M.floor_this = f, mem.read_uint32(zp + 14) end
    end
    return M.ready, M.why
end

function M.zone(id) return M.zones[id] end

-- the zone's floor of that number, or its first
function M.floor(zone, floor)
    local z = M.zones[zone]
    if z == nil then return nil end
    return (floor ~= nil and z.by_floor[floor]) or z.floors[1]
end

-- The floor a position of the zone you are in is on (the game's own answer), or nil if it can't say: x, y the map
-- plane and z the height, as vana.game.entity has them.
function M.floor_at(x, y, z)
    if M.floor_fn == nil or M.floor_this == nil or M.floor_this == 0 then return nil end
    local this = mem.read_uint32(M.floor_this)
    if this == 0 then return nil end
    local ok, floor = pcall(M.floor_fn, ffi.cast('void*', this), x, z, y)
    if not ok then return nil end
    return floor
end

-- a position of the world on a floor's map, in the map's own 512 units (fractions kept, for drawing)
function M.to_map(f, x, y)
    local k = f.scale / 5
    return x * k - f.ox, -(y * k) - f.oy
end

-- and back
function M.to_world(f, mx, my)
    local k = f.scale / 5
    return (mx + f.ox) / k, -(my + f.oy) / k
end

local function trunc(v) return v >= 0 and math.floor(v) or math.ceil(v) end

-- the grid square of a position, as the game names it: 'G-10', its column (0 = A) and its row (1 up)
function M.grid(f, x, y)
    local k = f.scale / 5
    local px = trunc(x * k + 0.5) - f.ox
    local py = -trunc(y * k + 0.5) - f.oy
    local col = math.floor((px - 16) / 32)
    local row = math.floor((py - 16) / 32) + 1
    if col < 0 or col > 25 or row < 1 or row > 99 then return '?-?', col, row end
    return string.char(65 + col) .. '-' .. row, col, row
end

-- the square of a point of the map itself (512 units)
function M.grid_of_map(mx, my)
    local col = math.floor((mx - 16) / 32)
    local row = math.floor((my - 16) / 32) + 1
    if col < 0 or col > 25 or row < 1 or row > 99 then return '?-?', col, row end
    return string.char(65 + col) .. '-' .. row, col, row
end

M.SIZE = SIZE

-------------------------------------------------------------------------------
-- Where the map DATs are
-------------------------------------------------------------------------------

local FILES = { roots = nil, tables = {}, rel = {}, found = {} }

local function read_file(path)
    local f = io.open(path, 'rb')
    if f == nil then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

-- The folders a game file is looked for in, first to last: the overlays VanaCore lays over the game's folder, in its
-- order ([pivot] rootfolder and [pivot.order]), then the game's folder. The map pack's folders are found among the
-- overlay root's own (ffxi-maps\2048x2048, ffxi-maps\1024x1024) whether or not the player has them in the order: a
-- player who has the files has the pack.
local function roots()
    if FILES.roots then return FILES.roots end
    local r = { overlays = {}, packs = {}, game = vana.paths.game }
    local root = nil
    local ok, on = pcall(vana.config.get, 'pivot', 'enabled', '0')
    local ok2, folder = pcall(vana.config.get, 'pivot', 'rootfolder', '')
    if ok2 and folder ~= nil and folder ~= '' then root = folder:gsub('[\\/]+$', '') end
    if root == nil or not vana.fs.is_dir(root) then
        -- the launcher's layout: ...\catseyexi-client\Game\FINAL FANTASY XI beside ...\catseyexi-client\Ashita
        local guess = (vana.paths.game or ''):gsub('[\\/][^\\/]+[\\/][^\\/]+$', '') .. '\\Ashita\\polplugins\\DATs'
        root = vana.fs.is_dir(guess) and guess or nil
    end
    if root then
        if ok and (on == '1' or on == 'true') then
            for i = 0, 31 do
                local ok3, name = pcall(vana.config.get, 'pivot.order', tostring(i), '')
                if ok3 and name ~= nil and name ~= '' and vana.fs.is_dir(root .. '\\' .. name) then
                    r.overlays[#r.overlays + 1] = root .. '\\' .. name
                end
            end
        end
        for _, size in ipairs({ '2048x2048', '1024x1024' }) do
            local p = root .. '\\ffxi-maps\\' .. size
            if vana.fs.is_dir(p) then r.packs[#r.packs + 1] = { path = p, size = tonumber(size:match('^%d+')) } end
        end
    end
    r.root = root
    FILES.roots = r
    return r
end
M.roots = roots

-- a file of the game's folder as the game would read it: from the first overlay that has it
local function game_file(rel)
    local r = roots()
    for _, o in ipairs(r.overlays) do
        local data = read_file(o .. '\\' .. rel)
        if data then return data end
    end
    return read_file(r.game .. '\\' .. rel)
end

-- 'ROM\17\24.DAT' for a file id, or nil: VTABLE says which ROM folder has the id, FTABLE where in it
local function rel_of(id)
    local hit = FILES.rel[id]
    if hit ~= nil then return hit or nil end
    local found = false
    for n = 1, 12 do
        local t = FILES.tables[n]
        if t == nil then
            local sfx = n == 1 and '' or tostring(n)
            local dir = n == 1 and '' or ('ROM' .. sfx .. '\\')
            local v, f = game_file(dir .. 'VTABLE' .. sfx .. '.DAT'), game_file(dir .. 'FTABLE' .. sfx .. '.DAT')
            t = (v and f) and { v = v, f = f } or false
            FILES.tables[n] = t
        end
        if t and id < #t.v and t.v:byte(id + 1) == n and id * 2 + 2 <= #t.f then
            local lo, hi = t.f:byte(id * 2 + 1, id * 2 + 2)
            local w = lo + hi * 256
            found = string.format('ROM%s\\%d\\%d.DAT', n == 1 and '' or tostring(n), math.floor(w / 128), w % 128)
            break
        end
    end
    FILES.rel[id] = found
    return found or nil
end

-- The file tables are only needed while paths are being worked out; a megabyte or three of strings otherwise.
function M.forget_tables() FILES.tables = {} end

-- Where a floor's map is, best first: { { path, from = 'pack 2048' | 'pack 1024' | 'overlay' | 'game' }, ... }.
-- `most`: the largest pack size wanted (2048, 1024, or 0 for the game's own maps alone).
function M.sources(f, most)
    most = most or 2048
    local key = f.file .. ':' .. most
    local hit = FILES.found[key]
    if hit then return hit end
    local list = {}
    local rel = rel_of(f.file)
    if rel then
        local r = roots()
        for _, p in ipairs(r.packs) do
            if p.size <= most and vana.fs.exists(p.path .. '\\' .. rel) then
                list[#list + 1] = { path = p.path .. '\\' .. rel, from = 'pack ' .. p.size }
            end
        end
        for _, o in ipairs(r.overlays) do
            -- (the pack's own folders are above, by size)
            if not o:lower():find('\\ffxi%-maps\\', 1) and vana.fs.exists(o .. '\\' .. rel) then
                list[#list + 1] = { path = o .. '\\' .. rel, from = 'overlay' }
            end
        end
        if vana.fs.exists(r.game .. '\\' .. rel) then list[#list + 1] = { path = r.game .. '\\' .. rel, from = 'game' } end
    end
    list.rel = rel
    FILES.found[key] = list
    return list
end

-- whether the player has the map pack at all (for the about text and the quality setting)
function M.packs()
    local out = {}
    for _, p in ipairs(roots().packs) do out[#out + 1] = p.size end
    return out
end

return M
