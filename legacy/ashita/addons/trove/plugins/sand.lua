--[[
* trove/plugins/sand.lua — Falling sand game
*
* Cellular automata physics sim inside Trove.
* Draw sand, water, stone, fire, plant, oil, lava, acid, and gunpowder.
* Right-click to erase, scroll wheel to change brush size.
]]--

local ffi   = require('ffi')
local d3d   = require('d3d8')
local imgui = require('imgui')
local C     = ffi.C

local d3d8dev = d3d.get_device()

-- Win32 key state for shift-to-move
pcall(ffi.cdef, 'short __stdcall GetKeyState(int nVirtKey);')
local VK_SHIFT = 0x10
local function isShiftHeld()
    return C.GetKeyState(VK_SHIFT) < 0
end

------------------------------------------------------------
-- Shared
------------------------------------------------------------
local ui = nil

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local GRID_W = 160
local GRID_H = 120
local SCALE  = 2
local TEX_W  = GRID_W * SCALE
local TEX_H  = GRID_H * SCALE

-- Particle types
local EMPTY   = 0
local SAND    = 1
local WATER   = 2
local STONE   = 3
local FIRE    = 4
local PLANT   = 5
local OIL     = 6
local LAVA    = 7
local ACID    = 8
local GUNPOW  = 9
local STEAM   = 10
local ICE     = 11
local WOOD    = 12
local GAS     = 13

-- Colors (A8R8G8B8 as uint32: 0xAARRGGBB)
local BG_COLOR = 0xFF181820

local COLOR_VARIANTS = {
    [SAND]   = { 0xFFD4B96A, 0xFFCCB060, 0xFFDCC070, 0xFFC0A858 },
    [WATER]  = { 0xFF4488CC, 0xFF3878BB, 0xFF5090DD, 0xFF4480C0 },
    [STONE]  = { 0xFF707070, 0xFF686868, 0xFF787878, 0xFF656565 },
    [FIRE]   = { 0xFFFF6622, 0xFFFF4400, 0xFFFF8844, 0xFFFFAA22 },
    [PLANT]  = { 0xFF44AA44, 0xFF389938, 0xFF50BB50, 0xFF40A040 },
    [OIL]    = { 0xFF443322, 0xFF3A2A1A, 0xFF4E3B2B, 0xFF382818 },
    [LAVA]   = { 0xFFFF4400, 0xFFEE3300, 0xFFFF5500, 0xFFCC2200 },
    [ACID]   = { 0xFF44FF44, 0xFF33EE33, 0xFF55FF33, 0xFF22DD22 },
    [GUNPOW] = { 0xFF555555, 0xFF4A4A4A, 0xFF606060, 0xFF3F3F3F },
    [STEAM]  = { 0x80AABBCC, 0x80B0C0D0, 0x8099AABB, 0x80C0D0E0 },
    [ICE]    = { 0xFFAADDEE, 0xFF99CCDD, 0xFFBBEEFF, 0xFF88BBCC },
    [WOOD]   = { 0xFF6B4226, 0xFF5C3820, 0xFF7A4D2E, 0xFF4E3018 },
    [GAS]    = { 0x60BBAA44, 0x60CCBB55, 0x60AA9933, 0x60DDCC66 },
}

-- Row 1: core elements
local ELEMENTS_ROW1 = {
    { type = SAND,  name = 'Sand',  col = { 0.83, 0.73, 0.42, 1.0 } },
    { type = WATER, name = 'Aqua',  col = { 0.27, 0.53, 0.80, 1.0 } },
    { type = STONE, name = 'Rock',  col = { 0.44, 0.44, 0.44, 1.0 } },
    { type = FIRE,  name = 'Fire',  col = { 1.00, 0.40, 0.13, 1.0 } },
    { type = PLANT, name = 'Vine',  col = { 0.27, 0.67, 0.27, 1.0 } },
    { type = OIL,   name = 'Oil',   col = { 0.27, 0.20, 0.13, 1.0 } },
}
-- Row 2: new elements
local ELEMENTS_ROW2 = {
    { type = LAVA,   name = 'Lava',  col = { 1.00, 0.27, 0.00, 1.0 } },
    { type = ACID,   name = 'Acid',  col = { 0.27, 1.00, 0.27, 1.0 } },
    { type = GUNPOW, name = 'TNT',   col = { 0.33, 0.33, 0.33, 1.0 } },
    { type = ICE,    name = 'Ice',   col = { 0.67, 0.87, 0.93, 1.0 } },
    { type = WOOD,   name = 'Wood',  col = { 0.42, 0.26, 0.15, 1.0 } },
    { type = GAS,    name = 'Gas',   col = { 0.73, 0.67, 0.27, 1.0 } },
}

local BRUSH_SIZES = { 1, 3, 5, 9 }

------------------------------------------------------------
-- State
------------------------------------------------------------
local grid     = {}
local fireLife = {}   -- remaining frames for fire/steam cells
local colors   = {}
local selected = SAND
local brushIdx = 2
local lastBrushX = nil
local lastBrushY = nil
local lastEraseX = nil
local lastEraseY = nil
local texture  = nil
local texHandle = nil
local paused   = false
local frame    = 0

------------------------------------------------------------
-- Grid helpers
------------------------------------------------------------
local function idx(x, y)
    return y * GRID_W + x
end

local function inBounds(x, y)
    return x >= 0 and x < GRID_W and y >= 0 and y < GRID_H
end

local function getCell(x, y)
    if not inBounds(x, y) then return STONE end
    return grid[idx(x, y)]
end

local function setCell(x, y, t)
    if not inBounds(x, y) then return end
    local i = idx(x, y)
    grid[i] = t
    if t == FIRE then
        fireLife[i] = 50 + math.random(50)
    elseif t == STEAM then
        fireLife[i] = 30 + math.random(40)
    else
        fireLife[i] = nil
    end
    if COLOR_VARIANTS[t] then
        local v = COLOR_VARIANTS[t]
        colors[i] = v[math.random(#v)]
    else
        colors[i] = BG_COLOR
    end
end

local function swapCells(x1, y1, x2, y2)
    if not inBounds(x2, y2) then return end
    local i1, i2 = idx(x1, y1), idx(x2, y2)
    grid[i1], grid[i2] = grid[i2], grid[i1]
    colors[i1], colors[i2] = colors[i2], colors[i1]
    fireLife[i1], fireLife[i2] = fireLife[i2], fireLife[i1]
end

local function clearGrid()
    for y = 0, GRID_H - 1 do
        for x = 0, GRID_W - 1 do
            local i = idx(x, y)
            grid[i]      = EMPTY
            colors[i]    = BG_COLOR
            fireLife[i]  = nil
        end
    end
end

------------------------------------------------------------
-- Particle update rules
------------------------------------------------------------
local FIRE_DIRS = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }

local function updateSand(x, y)
    local below = getCell(x, y + 1)
    if below == EMPTY or below == WATER or below == OIL or below == ACID then
        swapCells(x, y, x, y + 1)
        return
    end
    local dir = math.random(2) == 1 and 1 or -1
    local d1 = getCell(x + dir, y + 1)
    if d1 == EMPTY or d1 == WATER then
        swapCells(x, y, x + dir, y + 1)
        return
    end
    local d2 = getCell(x - dir, y + 1)
    if d2 == EMPTY or d2 == WATER then
        swapCells(x, y, x - dir, y + 1)
    end
end

local function updateWater(x, y)
    local below = getCell(x, y + 1)
    if below == EMPTY then
        swapCells(x, y, x, y + 1)
        return
    elseif below == OIL then
        swapCells(x, y, x, y + 1)
        return
    end
    local dir = math.random(2) == 1 and 1 or -1
    if getCell(x + dir, y + 1) == EMPTY then
        swapCells(x, y, x + dir, y + 1)
        return
    elseif getCell(x - dir, y + 1) == EMPTY then
        swapCells(x, y, x - dir, y + 1)
        return
    end
    local reach = math.random(1, 3)
    for s = 1, reach do
        if getCell(x + dir * s, y) ~= EMPTY then break end
        if s == reach or getCell(x + dir * (s + 1), y) ~= EMPTY then
            swapCells(x, y, x + dir * s, y)
            return
        end
    end
    if getCell(x + dir, y) == EMPTY then
        swapCells(x, y, x + dir, y)
    elseif getCell(x - dir, y) == EMPTY then
        swapCells(x, y, x - dir, y)
    end
end

local function updateOil(x, y)
    local below = getCell(x, y + 1)
    if below == EMPTY then
        swapCells(x, y, x, y + 1)
        return
    end
    local dir = math.random(2) == 1 and 1 or -1
    if getCell(x + dir, y + 1) == EMPTY then
        swapCells(x, y, x + dir, y + 1)
        return
    elseif getCell(x - dir, y + 1) == EMPTY then
        swapCells(x, y, x - dir, y + 1)
        return
    end
    if getCell(x + dir, y) == EMPTY then
        swapCells(x, y, x + dir, y)
    elseif getCell(x - dir, y) == EMPTY then
        swapCells(x, y, x - dir, y)
    end
end

local function updateFire(x, y)
    local i = idx(x, y)
    fireLife[i] = (fireLife[i] or 1) - 1
    if fireLife[i] <= 0 then
        setCell(x, y, EMPTY)
        return
    end
    -- Flicker
    local v = COLOR_VARIANTS[FIRE]
    colors[i] = v[math.random(#v)]
    -- Spread to flammable neighbours (more aggressive downward)
    for _, d in ipairs(FIRE_DIRS) do
        local nx, ny = x + d[1], y + d[2]
        local n = getCell(nx, ny)
        if n == PLANT or n == OIL then
            local chance = (d[2] == 1) and 3 or 8
            if math.random(chance) == 1 then
                setCell(nx, ny, FIRE)
            end
        elseif n == GUNPOW or n == GAS then
            setCell(nx, ny, FIRE)
        elseif n == ICE then
            setCell(nx, ny, WATER)
            fireLife[i] = math.max(0, (fireLife[i] or 0) - 10)
        end
    end
    -- Evaporate water -> steam
    for _, d in ipairs(FIRE_DIRS) do
        local nx, ny = x + d[1], y + d[2]
        if getCell(nx, ny) == WATER then
            setCell(nx, ny, STEAM)
            fireLife[i] = math.max(0, (fireLife[i] or 0) - 15)
            break
        end
    end
    -- Rise
    if math.random(3) == 1 then
        if getCell(x, y - 1) == EMPTY then
            swapCells(x, y, x, y - 1)
        else
            local dir = math.random(2) == 1 and 1 or -1
            if getCell(x + dir, y - 1) == EMPTY then
                swapCells(x, y, x + dir, y - 1)
            end
        end
    end
end

local function updatePlant(x, y)
    local wet = false
    for _, d in ipairs(FIRE_DIRS) do
        if getCell(x + d[1], y + d[2]) == WATER then
            wet = true
            break
        end
    end
    local chance = wet and 8 or 200
    if math.random(chance) == 1 then
        local d = FIRE_DIRS[math.random(#FIRE_DIRS)]
        local nx, ny = x + d[1], y + d[2]
        local n = getCell(nx, ny)
        if n == EMPTY or (wet and n == WATER) then
            setCell(nx, ny, PLANT)
        end
    end
end

local function updateLava(x, y)
    -- Check neighbours for reactions first
    for _, d in ipairs(FIRE_DIRS) do
        local nx, ny = x + d[1], y + d[2]
        local n = getCell(nx, ny)
        if n == WATER then
            -- Lava + water = stone + steam
            setCell(x, y, STONE)
            setCell(nx, ny, STEAM)
            return
        elseif n == ICE then
            -- Lava + ice = stone + water
            setCell(x, y, STONE)
            setCell(nx, ny, WATER)
            return
        elseif (n == PLANT or n == OIL or n == WOOD) and math.random(3) == 1 then
            setCell(nx, ny, FIRE)
        elseif n == GAS then
            setCell(nx, ny, FIRE)
        end
    end
    -- Flow like slow water
    if math.random(3) ~= 1 then return end  -- moves slower than water
    local below = getCell(x, y + 1)
    if below == EMPTY then
        swapCells(x, y, x, y + 1)
        return
    end
    local dir = math.random(2) == 1 and 1 or -1
    if getCell(x + dir, y + 1) == EMPTY then
        swapCells(x, y, x + dir, y + 1)
        return
    elseif getCell(x - dir, y + 1) == EMPTY then
        swapCells(x, y, x - dir, y + 1)
        return
    end
    if getCell(x + dir, y) == EMPTY then
        swapCells(x, y, x + dir, y)
    elseif getCell(x - dir, y) == EMPTY then
        swapCells(x, y, x - dir, y)
    end
end

local function updateAcid(x, y)
    -- Dissolve neighbours (not stone)
    for _, d in ipairs(FIRE_DIRS) do
        local nx, ny = x + d[1], y + d[2]
        local n = getCell(nx, ny)
        if n ~= EMPTY and n ~= STONE and n ~= ACID and n ~= LAVA and math.random(6) == 1 then
            setCell(nx, ny, EMPTY)
            -- Acid gets consumed too sometimes
            if math.random(3) == 1 then
                setCell(x, y, EMPTY)
                return
            end
        end
    end
    -- Fall like water
    local below = getCell(x, y + 1)
    if below == EMPTY then
        swapCells(x, y, x, y + 1)
        return
    end
    local dir = math.random(2) == 1 and 1 or -1
    if getCell(x + dir, y + 1) == EMPTY then
        swapCells(x, y, x + dir, y + 1)
        return
    elseif getCell(x - dir, y + 1) == EMPTY then
        swapCells(x, y, x - dir, y + 1)
        return
    end
    if getCell(x + dir, y) == EMPTY then
        swapCells(x, y, x + dir, y)
    elseif getCell(x - dir, y) == EMPTY then
        swapCells(x, y, x - dir, y)
    end
end

local function updateGunpowder(x, y)
    -- Falls like sand
    local below = getCell(x, y + 1)
    if below == EMPTY or below == WATER or below == OIL then
        swapCells(x, y, x, y + 1)
        return
    end
    local dir = math.random(2) == 1 and 1 or -1
    if getCell(x + dir, y + 1) == EMPTY then
        swapCells(x, y, x + dir, y + 1)
        return
    elseif getCell(x - dir, y + 1) == EMPTY then
        swapCells(x, y, x - dir, y + 1)
    end
    -- Check for fire/lava nearby -> explode
    for _, d in ipairs(FIRE_DIRS) do
        local n = getCell(x + d[1], y + d[2])
        if n == FIRE or n == LAVA then
            -- Explode: clear a radius and spawn fire
            local radius = 4
            for ey = -radius, radius do
                for ex = -radius, radius do
                    if ex * ex + ey * ey <= radius * radius then
                        local bx, by = x + ex, y + ey
                        if inBounds(bx, by) and getCell(bx, by) ~= STONE then
                            if math.random(3) == 1 then
                                setCell(bx, by, FIRE)
                            else
                                setCell(bx, by, EMPTY)
                            end
                        end
                    end
                end
            end
            return
        end
    end
end

local function updateSteam(x, y)
    local i = idx(x, y)
    fireLife[i] = (fireLife[i] or 1) - 1
    -- Flicker
    local v = COLOR_VARIANTS[STEAM]
    colors[i] = v[math.random(#v)]
    if fireLife[i] <= 0 then
        -- Condense back to water
        if math.random(2) == 1 then
            setCell(x, y, WATER)
        else
            setCell(x, y, EMPTY)
        end
        return
    end
    -- Rise
    if getCell(x, y - 1) == EMPTY then
        swapCells(x, y, x, y - 1)
    else
        local dir = math.random(2) == 1 and 1 or -1
        if getCell(x + dir, y) == EMPTY then
            swapCells(x, y, x + dir, y)
        elseif getCell(x - dir, y) == EMPTY then
            swapCells(x, y, x - dir, y)
        end
    end
end

local function updateIce(x, y)
    -- Freeze adjacent water
    for _, d in ipairs(FIRE_DIRS) do
        local nx, ny = x + d[1], y + d[2]
        if getCell(nx, ny) == WATER and math.random(15) == 1 then
            setCell(nx, ny, ICE)
        end
    end
    -- Melt from fire, lava, or acid
    for _, d in ipairs(FIRE_DIRS) do
        local nx, ny = x + d[1], y + d[2]
        local n = getCell(nx, ny)
        if n == FIRE or n == LAVA then
            setCell(x, y, WATER)
            return
        elseif n == ACID then
            setCell(x, y, WATER)
            setCell(nx, ny, EMPTY)
            return
        end
    end
end

local function updateWood(x, y)
    local i = idx(x, y)
    -- Check for adjacent fire/lava -> start burning
    for _, d in ipairs(FIRE_DIRS) do
        local n = getCell(x + d[1], y + d[2])
        if n == FIRE or n == LAVA then
            -- Slow burn: set a burn timer, wood smolders before catching
            if not fireLife[i] then
                fireLife[i] = 30 + math.random(40)
            end
            break
        end
    end
    -- If burning, count down and darken
    if fireLife[i] then
        fireLife[i] = fireLife[i] - 1
        -- Smoldering: darken the wood
        colors[i] = 0xFF2A1508
        if fireLife[i] <= 0 then
            setCell(x, y, FIRE)
        end
    end
end

local function updateGas(x, y)
    local i = idx(x, y)
    -- Dissipate over time
    if not fireLife[i] then
        fireLife[i] = 150 + math.random(100)
    end
    fireLife[i] = fireLife[i] - 1
    -- Flicker
    local v = COLOR_VARIANTS[GAS]
    colors[i] = v[math.random(#v)]
    if fireLife[i] <= 0 then
        setCell(x, y, EMPTY)
        return
    end
    -- Flash-ignite from fire or lava (chain reaction)
    for _, d in ipairs(FIRE_DIRS) do
        local n = getCell(x + d[1], y + d[2])
        if n == FIRE or n == LAVA then
            setCell(x, y, FIRE)
            return
        end
    end
    -- Movement: rise, spread under ceilings, drift randomly
    local above = getCell(x, y - 1)
    if above == EMPTY or above == WATER then
        swapCells(x, y, x, y - 1)
        return
    end
    -- Blocked above: try diagonal up
    local dir = math.random(2) == 1 and 1 or -1
    if getCell(x + dir, y - 1) == EMPTY then
        swapCells(x, y, x + dir, y - 1)
        return
    elseif getCell(x - dir, y - 1) == EMPTY then
        swapCells(x, y, x - dir, y - 1)
        return
    end
    -- Fully blocked above: spread sideways under ceiling
    local spread = math.random(1, 3)
    for s = 1, spread do
        if getCell(x + dir * s, y) == EMPTY then
            swapCells(x, y, x + dir * s, y)
            return
        elseif getCell(x + dir * s, y) ~= GAS then
            break
        end
    end
    if getCell(x - dir, y) == EMPTY then
        swapCells(x, y, x - dir, y)
    end
end

------------------------------------------------------------
-- Simulation step
------------------------------------------------------------
local function simulate()
    if paused then return end
    frame = frame + 1

    local xStart, xEnd, xStep
    if frame % 2 == 0 then
        xStart, xEnd, xStep = 0, GRID_W - 1, 1
    else
        xStart, xEnd, xStep = GRID_W - 1, 0, -1
    end

    for y = GRID_H - 1, 0, -1 do
        for x = xStart, xEnd, xStep do
            local t = grid[idx(x, y)]
            if t == SAND then
                updateSand(x, y)
            elseif t == WATER then
                updateWater(x, y)
            elseif t == OIL then
                updateOil(x, y)
            elseif t == FIRE then
                updateFire(x, y)
            elseif t == PLANT then
                updatePlant(x, y)
            elseif t == LAVA then
                updateLava(x, y)
            elseif t == ACID then
                updateAcid(x, y)
            elseif t == GUNPOW then
                updateGunpowder(x, y)
            elseif t == STEAM then
                updateSteam(x, y)
            elseif t == ICE then
                updateIce(x, y)
            elseif t == WOOD then
                updateWood(x, y)
            elseif t == GAS then
                updateGas(x, y)
            end
        end
    end
end

------------------------------------------------------------
-- D3D texture
------------------------------------------------------------
local function createTexture()
    if texture then return true end
    local hr, tex = d3d8dev:CreateTexture(TEX_W, TEX_H, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED)
    if hr ~= C.S_OK or tex == nil then
        print('[trove:sand] Failed to create texture')
        return false
    end
    texture   = d3d.gc_safe_release(tex)
    texHandle = tonumber(ffi.cast('uint32_t', texture))
    return true
end

local function updateTexture()
    if not texture then return end
    local hr, locked = texture:LockRect(0, nil, 0)
    if hr ~= C.S_OK then return end

    local pitch4 = locked.Pitch / 4
    local pixels = ffi.cast('uint32_t*', locked.pBits)

    for y = 0, GRID_H - 1 do
        local rowBase = y * GRID_W
        local py0 = y * SCALE
        for x = 0, GRID_W - 1 do
            local c = colors[rowBase + x] or BG_COLOR
            local px0 = x * SCALE
            for sy = 0, SCALE - 1 do
                local row = (py0 + sy) * pitch4 + px0
                for sx = 0, SCALE - 1 do
                    pixels[row + sx] = c
                end
            end
        end
    end

    texture:UnlockRect(0)
end

local function destroyTexture()
    if texture then
        pcall(function()
            ffi.gc(texture, nil)
            texture:Release()
        end)
    end
    texture   = nil
    texHandle = nil
end

------------------------------------------------------------
-- Brush
------------------------------------------------------------
local function applyBrushAt(gx, gy, t)
    local size = BRUSH_SIZES[brushIdx]
    local half = math.floor(size / 2)
    for dy = -half, half do
        for dx = -half, half do
            local bx, by = gx + dx, gy + dy
            if inBounds(bx, by) then
                setCell(bx, by, t)
            end
        end
    end
end

local function applyBrushLine(x0, y0, x1, y1, t)
    local dx = math.abs(x1 - x0)
    local dy = -math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        applyBrushAt(x0, y0, t)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

------------------------------------------------------------
-- Window rendering
------------------------------------------------------------
local isOpen = { false }

local function renderElementRow(elements, btnW, btnH)
    for i, elem in ipairs(elements) do
        if i > 1 then imgui.SameLine(0, 2) end
        local isSel = (selected == elem.type)
        local ec = elem.col
        if isSel then
            imgui.PushStyleColor(ImGuiCol_Button,        { ec[1], ec[2], ec[3], 1.0 })
            imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { math.min(ec[1] * 1.2, 1), math.min(ec[2] * 1.2, 1), math.min(ec[3] * 1.2, 1), 1.0 })
            imgui.PushStyleColor(ImGuiCol_ButtonActive,   { ec[1] * 0.8, ec[2] * 0.8, ec[3] * 0.8, 1.0 })
        else
            imgui.PushStyleColor(ImGuiCol_Button,        { ec[1] * 0.4, ec[2] * 0.4, ec[3] * 0.4, 0.7 })
            imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { ec[1] * 0.6, ec[2] * 0.6, ec[3] * 0.6, 0.9 })
            imgui.PushStyleColor(ImGuiCol_ButtonActive,   { ec[1] * 0.8, ec[2] * 0.8, ec[3] * 0.8, 1.0 })
        end
        if imgui.Button(elem.name .. '##sand', { btnW, btnH }) then
            selected = elem.type
        end
        imgui.PopStyleColor(3)
    end
end

local function renderContent()
    -- Create texture on first render
    if not texture then
        if not createTexture() then
            imgui.TextColored({ 1, 0.3, 0.3, 1 }, 'Failed to create D3D texture')
            return
        end
        clearGrid()
    end

    -- Clear button top-right
    local clearW = 38
    local btnH = 18
    imgui.SameLine(imgui.GetWindowWidth() - clearW - 12)
    imgui.PushStyleColor(ImGuiCol_Button,        { 0.30, 0.25, 0.25, 0.7 })
    imgui.PushStyleColor(ImGuiCol_ButtonHovered,  { 0.50, 0.30, 0.30, 0.9 })
    imgui.PushStyleColor(ImGuiCol_ButtonActive,   { 0.40, 0.20, 0.20, 1.0 })
    if imgui.Button('New##sand_c', { clearW, btnH }) then
        clearGrid()
    end
    imgui.PopStyleColor(3)

    -- Canvas
    simulate()
    updateTexture()

    if texHandle then
        local pos = imgui.GetCursorScreenPos()

        imgui.Image(texHandle, { TEX_W, TEX_H })

        if imgui.IsItemHovered() then
            local mx, my = imgui.GetMousePos()
            if type(mx) == 'table' then
                my = mx[2]
                mx = mx[1]
            end
            if type(pos) == 'table' then
                mx = mx - pos[1]
                my = my - pos[2]
            else
                local rx, ry = imgui.GetItemRectMin()
                mx = mx - rx
                my = my - ry
            end

            local gx = math.floor(mx / SCALE)
            local gy = math.floor(my / SCALE)

            -- Left-click: draw selected element
            if imgui.IsMouseDown(0) and inBounds(gx, gy) then
                if lastBrushX and lastBrushY then
                    applyBrushLine(lastBrushX, lastBrushY, gx, gy, selected)
                else
                    applyBrushAt(gx, gy, selected)
                end
                lastBrushX = gx
                lastBrushY = gy
            else
                lastBrushX = nil
                lastBrushY = nil
            end

            -- Right-click: always erase
            if imgui.IsMouseDown(1) and inBounds(gx, gy) then
                if lastEraseX and lastEraseY then
                    applyBrushLine(lastEraseX, lastEraseY, gx, gy, EMPTY)
                else
                    applyBrushAt(gx, gy, EMPTY)
                end
                lastEraseX = gx
                lastEraseY = gy
            else
                lastEraseX = nil
                lastEraseY = nil
            end

            -- Scroll wheel: change brush size
            local scroll = imgui.GetIO().MouseWheel
            if scroll and scroll > 0 then
                brushIdx = math.min(brushIdx + 1, #BRUSH_SIZES)
            elseif scroll and scroll < 0 then
                brushIdx = math.max(brushIdx - 1, 1)
            end

            -- Brush cursor preview
            local drawList = imgui.GetWindowDrawList()
            if drawList and type(pos) == 'table' then
                local size = BRUSH_SIZES[brushIdx] * SCALE
                local cx = pos[1] + (gx + 0.5) * SCALE
                local cy = pos[2] + (gy + 0.5) * SCALE
                local half = size / 2
                drawList:AddRect(
                    { cx - half, cy - half },
                    { cx + half, cy + half },
                    0x80FFFFFF, 0, 0, 1
                )
            end
        end
    end

    -- Element picker at bottom - two rows
    imgui.Spacing()
    local btnW = 44
    renderElementRow(ELEMENTS_ROW1, btnW, btnH)
    renderElementRow(ELEMENTS_ROW2, btnW, btnH)
end

local function renderWindow()
    local pushed = ui and ui.pushWindowStyle and ui.pushWindowStyle() or 0
    imgui.SetNextWindowSize({ TEX_W + 20, TEX_H + 100 }, ImGuiCond_FirstUseEver)
    local flags = ImGuiWindowFlags_NoScrollbar
    if not isShiftHeld() then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove)
    end
    if imgui.Begin('Sand##trove_sand', isOpen, flags) then
        renderContent()
    end
    imgui.End()
    if ui and ui.popWindowStyle then ui.popWindowStyle(pushed) end
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Sand',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Falling sand game',

    init = function(iconFn, itemResFn, uiModule)
        ui = uiModule
    end,

    onUnload = function()
        destroyTexture()
    end,

    commands = {
        sand = function(state, args)
            isOpen[1] = not isOpen[1]
        end,
    },

    window = {
        category = 'Games',
        isOpen    = isOpen,
        label     = 'Sand',
        icon      = 503,  -- Valkurm Sunsand
        render    = renderWindow,
    },
}
