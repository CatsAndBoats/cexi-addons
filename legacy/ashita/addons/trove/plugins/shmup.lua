--[[
* trove/plugins/shmup.lua — Elemental Master-style vertical shmup
*
* Top-down vertical scroller with 4 FFXI-inspired classes.
* Uses D3D texture pixel buffer (same approach as Sand plugin).
* Enemies drop FFXI items (materials + equipment).
*
* Command: /trove shmup
]]--

local ffi   = require('ffi')
local d3d   = require('d3d8')
local imgui = require('imgui')
local C     = ffi.C

local d3d8dev = d3d.get_device()

-- Win32 key state
pcall(ffi.cdef, 'short __stdcall GetKeyState(int nVirtKey);')
local function keyDown(vk)
    return C.GetKeyState(vk) < 0
end

local VK = {
    UP = 0x26, DOWN = 0x28, LEFT = 0x25, RIGHT = 0x27,
    Z = 0x5A, X = 0x58, C = 0x43, SPACE = 0x20,
    SHIFT = 0x10, ENTER = 0x0D, ESCAPE = 0x1B,
    ['1'] = 0x31, ['2'] = 0x32, ['3'] = 0x33, ['4'] = 0x34,
}

------------------------------------------------------------
-- Shared
------------------------------------------------------------
local ui = nil
local renderIcon = nil
local getIconHandle = nil

------------------------------------------------------------
-- Display constants
------------------------------------------------------------
local VIEW_W  = 256
local VIEW_H  = 320
local SCALE   = 2
local TEX_W   = VIEW_W
local TEX_H   = VIEW_H
local TILE    = 16  -- tile size in pixels

------------------------------------------------------------
-- Game states
------------------------------------------------------------
local STATE_MENU     = 0
local STATE_PLAYING  = 1
local STATE_PAUSED   = 2
local STATE_GAMEOVER = 3
local STATE_EQUIP    = 4

local gameState = STATE_MENU

------------------------------------------------------------
-- Colors (A8R8G8B8: 0xAARRGGBB)
------------------------------------------------------------
local COL = {
    bg       = 0xFF101018,
    hud_bg   = 0xCC0A0A12,
    white    = 0xFFFFFFFF,
    black    = 0xFF000000,
    red      = 0xFFFF4444,
    green    = 0xFF44FF44,
    blue     = 0xFF4488FF,
    yellow   = 0xFFFFDD44,
    purple   = 0xFFAA44FF,
    cyan     = 0xFF44DDFF,
    orange   = 0xFFFF8822,
    gray     = 0xFF666666,
    darkgray = 0xFF333333,
    hp_bar   = 0xFF44CC44,
    hp_bg    = 0xFF222222,
    mp_bar   = 0xFF4488FF,
    xp_bar   = 0xFFFFDD44,
}

------------------------------------------------------------
-- Classes
------------------------------------------------------------
local CLASS_BLM = 1
local CLASS_WAR = 2
local CLASS_RNG = 3
local CLASS_NIN = 4

local CLASS_DEF = {
    [CLASS_BLM] = {
        name   = 'Black Mage',
        abbr   = 'BLM',
        icon   = 13856,  -- Wizard's Petasos
        color  = 0xFF6644CC,
        speed  = 1.5,
        hp     = 80,
        mp     = 100,
        projIcon   = 4896,   -- Fire Spirit
        projColor  = 0xFFFF6622,
        projSpeed  = 4,
        projSize   = 3,
        projDmg    = 12,
        projRate   = 12,
        chargeColor = 0xFFFF2200,
        chargeDmg   = 40,
        chargeSize  = 8,
        chargeTime  = 40,
        desc   = 'Fires fireballs. Charge: Firaga (big AoE)',
    },
    [CLASS_WAR] = {
        name   = 'Warrior',
        abbr   = 'WAR',
        icon   = 12511,  -- Fighter's Mask
        color  = 0xFFCC4444,
        speed  = 1.2,
        hp     = 150,
        mp     = 30,
        projIcon   = 16676,  -- Viking Axe
        projColor  = 0xFFCCCCCC,
        projSpeed  = 3.5,
        projSize   = 4,
        projDmg    = 15,
        projRate   = 16,
        chargeColor = 0xFFFFFFFF,
        chargeDmg   = 35,
        chargeSize  = 5,
        chargeTime  = 30,
        desc   = 'Throws axes. Charge: Spinning axe (pierces)',
    },
    [CLASS_RNG] = {
        name   = 'Ranger',
        abbr   = 'RNG',
        icon   = 12518,  -- Hunter's Beret
        color  = 0xFF44AA44,
        speed  = 1.8,
        hp     = 100,
        mp     = 50,
        projIcon   = 17318,  -- Wooden Arrow
        projColor  = 0xFFDDDD88,
        projSpeed  = 5,
        projSize   = 2,
        projDmg    = 7,
        projRate   = 10,
        chargeColor = 0xFFFFFF44,
        chargeDmg   = 5,
        chargeSize  = 2,
        chargeTime  = 35,
        desc   = 'Shoots arrows. Charge: Arrow rain (spread)',
    },
    [CLASS_NIN] = {
        name   = 'Ninja',
        abbr   = 'NIN',
        icon   = 13869,  -- Ninja Hatsuburi
        color  = 0xFF4444AA,
        speed  = 2.2,
        hp     = 90,
        mp     = 80,
        projIcon   = 17303,  -- Manji Shuriken
        projColor  = 0xFFCCCCFF,
        projSpeed  = 5,
        projSize   = 2,
        projDmg    = 10,
        projRate   = 8,
        chargeColor = 0xFF8888FF,
        chargeDmg   = 30,
        chargeSize  = 6,
        chargeTime  = 25,
        desc   = 'Throws shuriken. Charge: Ninjutsu + teleport',
    },
}

------------------------------------------------------------
-- Item system (branching upgrades — every pickup upgrades a slot)
-- T1→T2 automatic. T3+ the drop shows as the specific item.
-- Player chooses path by which drop they walk over.
------------------------------------------------------------
local EQUIP_SLOT = { WEAPON = 1, BODY = 2, ACCESSORY = 3 }

-- Each tier entry: { id, name, stats, rarity, from }
-- 'from' = which item ID this upgrades FROM (nil = root / any)
local SLOT_DATA = {
    [1] = { -- WEAPON
        name = 'Weapon',
        dropIcons = { 4096, 656, 4097, 4098 },
        tiers = {
            [1] = {
                { id = 16465, name = 'Bronze Knife',    stats = { dmg = 3 },                      rarity = 1 },
            },
            [2] = {
                { id = 16537, name = 'Mythril Sword',   stats = { dmg = 7 },                      rarity = 2, from = 16465 },
            },
            [3] = {  -- BRANCH: speed vs power vs balanced
                { id = 17652, name = 'Joyeuse',        stats = { dmg = 10, rate = 3 },            rarity = 3, from = 16537 },
                { id = 16555, name = 'Ridill',          stats = { dmg = 16 },                      rarity = 3, from = 16537 },
                { id = 17041, name = 'Holy Mace',       stats = { dmg = 12, hp = 20 },             rarity = 3, from = 16537 },
            },
            [4] = {  -- T4 depends on T3 choice
                { id = 18270, name = 'Mandau',          stats = { dmg = 18, rate = 5 },            rarity = 4, from = 17652 },
                { id = 18282, name = 'Ragnarok',        stats = { dmg = 28 },                      rarity = 4, from = 16555 },
                { id = 18276, name = 'Excalibur',       stats = { dmg = 22, hp = 40 },             rarity = 4, from = 17041 },
            },
        },
    },
    [2] = { -- BODY
        name = 'Body',
        dropIcons = { 643, 645, 852, 851 },
        tiers = {
            [1] = {
                { id = 12568, name = 'Leather Vest',     stats = { hp = 15 },                      rarity = 1 },
            },
            [2] = {
                { id = 12552, name = 'Chainmail',        stats = { hp = 30 },                      rarity = 2, from = 12568 },
            },
            [3] = {  -- BRANCH: tank vs speed vs damage
                { id = 12555, name = 'Haubergeon',       stats = { hp = 50, dmg = 5 },             rarity = 3, from = 12552 },
                { id = 12579, name = 'Scorpion Harness', stats = { hp = 30, speed = 0.5 },         rarity = 3, from = 12552 },
                { id = 13805, name = 'Assault Jerkin',   stats = { hp = 35, rate = 3 },            rarity = 3, from = 12552 },
            },
            [4] = {
                { id = 12562, name = 'Kirin\'s Osode',   stats = { hp = 80, dmg = 8 },             rarity = 4, from = 12555 },
                { id = 14387, name = 'Shura Togi',       stats = { hp = 50, dmg = 5, speed = 0.5 }, rarity = 4, from = 12579 },
                { id = 13748, name = 'Vermillion Cloak', stats = { hp = 60, rate = 4 },            rarity = 4, from = 13805 },
            },
        },
    },
    [3] = { -- ACCESSORY
        name = 'Accessory',
        dropIcons = { 640, 644, 4100, 4101 },
        tiers = {
            [1] = {
                { id = 13469, name = 'Leather Ring',   stats = { speed = 0.2 },                    rarity = 1 },
            },
            [2] = {
                { id = 13446, name = 'Mythril Ring',    stats = { speed = 0.3, rate = 1 },          rarity = 2, from = 13469 },
            },
            [3] = {  -- BRANCH: attack vs defence vs speed
                { id = 13280, name = 'Sniper Ring',     stats = { rate = 3, dmg = 4 },              rarity = 3, from = 13446 },
                { id = 15778, name = 'Unyielding Ring', stats = { hp = 40, speed = 0.3 },           rarity = 3, from = 13446 },
                { id = 14630, name = 'Flame Ring',      stats = { dmg = 8, rate = 1 },              rarity = 3, from = 13446 },
            },
            [4] = {
                { id = 15543, name = 'Rajas Ring',      stats = { dmg = 6, rate = 5, speed = 0.3 }, rarity = 4, from = 13280 },
                { id = 13566, name = 'Defending Ring',  stats = { hp = 60, speed = 0.5 },           rarity = 4, from = 15778 },
                { id = 14674, name = 'Toreador\'s Ring', stats = { dmg = 12, rate = 3 },            rarity = 4, from = 14630 },
            },
        },
    },
}

-- getUpgradeOptions defined after player state (needs player reference)

local RARITY_COL = {
    [1] = { 0.60, 0.60, 0.60, 1.0 },  -- common (gray)
    [2] = { 0.40, 0.70, 0.40, 1.0 },  -- uncommon (green)
    [3] = { 0.40, 0.55, 0.90, 1.0 },  -- rare (blue)
    [4] = { 0.75, 0.45, 0.90, 1.0 },  -- epic (purple)
}

------------------------------------------------------------
-- Player state
------------------------------------------------------------
local player = {
    class       = CLASS_BLM,
    x           = VIEW_W / 2,
    y           = VIEW_H - 40,
    w           = 12,
    h           = 16,
    hp          = 80,
    maxHp       = 80,
    mp          = 100,
    maxMp       = 100,
    xp          = 0,
    level       = 1,
    xpNext      = 100,
    score       = 0,
    fireTimer   = 0,
    chargeTimer = 0,
    charging    = false,
    iframes     = 0,
    slotTier    = { 0, 0, 0 },  -- current tier per slot (0 = empty, 1-4)
    slotChoice  = { nil, nil, nil },  -- chosen item ID per slot (for branching)
    combineMsg  = nil,          -- { text, timer, itemId, rarity } flash message
}

-- Lookup: given current equipped item ID for a slot, what can upgrade next?
local function getUpgradeOptions(slot)
    local sd = SLOT_DATA[slot]
    local tier = player.slotTier[slot]
    local nextTier = tier + 1
    if not sd.tiers[nextTier] then return nil end

    if tier == 0 then
        return sd.tiers[1]
    end

    local currentId = player.slotChoice[slot]
    if not currentId then
        -- Fallback: use first item at current tier
        local currentItems = sd.tiers[tier]
        if currentItems and #currentItems == 1 then
            currentId = currentItems[1].id
        end
    end

    if not currentId then return sd.tiers[nextTier] end

    local options = {}
    for _, item in ipairs(sd.tiers[nextTier]) do
        if not item.from or item.from == currentId then
            options[#options + 1] = item
        end
    end

    return #options > 0 and options or nil
end

-- Get the equipped item data for a slot (nil if empty)
local function getEquipped(slot)
    local tier = player.slotTier[slot]
    if tier <= 0 then return nil end
    local choiceId = player.slotChoice[slot]
    local tierItems = SLOT_DATA[slot].tiers[tier]
    if not tierItems then return nil end
    -- Find the chosen item in this tier
    if choiceId then
        for _, item in ipairs(tierItems) do
            if item.id == choiceId then return item end
        end
    end
    -- Fallback: first item in tier
    return tierItems[1]
end

-- Determine which game level the player is on (1-3) based on player level
local function getGameLevel()
    if player.level >= 7 then return 3 end
    if player.level >= 4 then return 2 end
    return 1
end

------------------------------------------------------------
-- Projectiles
------------------------------------------------------------
local playerProj = {}   -- { x, y, vx, vy, size, color, dmg, pierce }
local enemyProj  = {}   -- { x, y, vx, vy, size, color, dmg }

------------------------------------------------------------
-- Enemies
------------------------------------------------------------
local enemies     = {}
local spawnTimer  = 0
local waveNum     = 0
local scrollY     = 0
local scrollSpeed = 0.5

-- Enemy types organized by level tier
-- Level 1: Goblins
-- Level 2: Orcs, Yagudo, Quadav
-- Level 3: Lamia, Mamool Ja, Trolls
-- Undead (Magicked Skull) can appear at any level

local ENEMY_TYPES = {
    -- Level 1: Goblins
    { name = 'Goblin',       icon = 511,   color = 0xFF66AA44, level = 1, hp = 12,  speed = 0.8, score = 10,  shootRate = 70,  projSpeed = 2,   projDmg = 6,   dropChance = 0.3,  projIcon = 16465 },
    { name = 'Goblin Elite', icon = 508,   color = 0xFF88CC44, level = 1, hp = 22,  speed = 0.7, score = 15,  shootRate = 50,  projSpeed = 2.5, projDmg = 10,  dropChance = 0.4,  projIcon = 19220 },

    -- Level 2: Beastmen
    { name = 'Orc',          icon = 15200, color = 0xFF886644, level = 2, hp = 30,  speed = 0.6, score = 20,  shootRate = 45,  projSpeed = 2.5, projDmg = 12,  dropChance = 0.4,  projIcon = 17330 },
    { name = 'Yagudo',       icon = 15202, color = 0xFF669944, level = 2, hp = 25,  speed = 0.9, score = 20,  shootRate = 40,  projSpeed = 3,   projDmg = 10,  dropChance = 0.4,  projIcon = 17307 },
    { name = 'Quadav',       icon = 15201, color = 0xFF557788, level = 2, hp = 40,  speed = 0.5, score = 25,  shootRate = 55,  projSpeed = 2,   projDmg = 15,  dropChance = 0.45, projIcon = 17336 },

    -- Level 3: Aht Urhgan beastmen
    { name = 'Lamia',        icon = 16123, color = 0xFF8855AA, level = 3, hp = 50,  speed = 0.7, score = 35,  shootRate = 35,  projSpeed = 3.5, projDmg = 18,  dropChance = 0.5,  projIcon = 18157 },
    { name = 'Mamool Ja',    icon = 16121, color = 0xFF448866, level = 3, hp = 55,  speed = 0.6, score = 35,  shootRate = 40,  projSpeed = 3,   projDmg = 20,  dropChance = 0.5,  projIcon = 18148 },
    { name = 'Troll',        icon = 16122, color = 0xFFAA6633, level = 3, hp = 70,  speed = 0.4, score = 40,  shootRate = 50,  projSpeed = 2.5, projDmg = 22,  dropChance = 0.55, projIcon = 17316 },

    -- Undead (any level, rare spawn)
    { name = 'Skeleton',     icon = 538,   color = 0xFF9988AA, level = 0, hp = 20,  speed = 1.0, score = 25,  shootRate = 0,   projSpeed = 0,   projDmg = 0,   dropChance = 0.5 },
}

------------------------------------------------------------
-- Drops (items on the ground)
------------------------------------------------------------
local drops = {}  -- { x, y, item, timer }

------------------------------------------------------------
-- Particle system
------------------------------------------------------------
local particles = {}  -- { x, y, vx, vy, life, maxLife, color, size, gravity }

-- Particle presets
local PARTICLE = {
    -- Hit sparks: small fast white/yellow particles
    hit = function(x, y, color)
        local baseCol = color or 0xFFFFDD88
        for _ = 1, 4 do
            local angle = math.random() * math.pi * 2
            local speed = 1.5 + math.random() * 2
            table.insert(particles, {
                x = x, y = y,
                vx = math.cos(angle) * speed,
                vy = math.sin(angle) * speed,
                life = 8 + math.random(6),
                maxLife = 14,
                color = baseCol,
                size = 1 + math.random(1),
                gravity = 0,
            })
        end
    end,

    -- Death: burst of colored particles matching enemy
    death = function(x, y, color, count)
        count = count or 12
        local r = bit.band(bit.rshift(color, 16), 0xFF)
        local g = bit.band(bit.rshift(color, 8), 0xFF)
        local b = bit.band(color, 0xFF)
        for _ = 1, count do
            local angle = math.random() * math.pi * 2
            local speed = 0.5 + math.random() * 3
            -- Vary the color slightly per particle
            local dr = math.max(0, math.min(255, r + math.random(-30, 30)))
            local dg = math.max(0, math.min(255, g + math.random(-30, 30)))
            local db = math.max(0, math.min(255, b + math.random(-30, 30)))
            local col = 0xFF000000 + bit.lshift(dr, 16) + bit.lshift(dg, 8) + db
            table.insert(particles, {
                x = x + math.random(-4, 4), y = y + math.random(-4, 4),
                vx = math.cos(angle) * speed,
                vy = math.sin(angle) * speed - 0.5,
                life = 15 + math.random(15),
                maxLife = 30,
                color = col,
                size = 2 + math.random(2),
                gravity = 0.06,
            })
        end
    end,

    -- Skull death (undead): purple/dark burst with upward drift
    skull = function(x, y)
        for _ = 1, 16 do
            local angle = math.random() * math.pi * 2
            local speed = 0.3 + math.random() * 1.5
            local shade = math.random(40, 100)
            local col = 0xFF000000 + bit.lshift(shade, 16) + bit.lshift(shade / 3, 8) + shade
            table.insert(particles, {
                x = x + math.random(-6, 6), y = y + math.random(-6, 6),
                vx = math.cos(angle) * speed,
                vy = -0.5 - math.random() * 1.5,
                life = 20 + math.random(20),
                maxLife = 40,
                color = col,
                size = 2 + math.random(2),
                gravity = -0.02,  -- floats up
            })
        end
    end,

    -- Fire death (bomb-type): orange/red burst
    fire = function(x, y)
        for _ = 1, 18 do
            local angle = math.random() * math.pi * 2
            local speed = 1 + math.random() * 3
            local colors = { 0xFFFF6622, 0xFFFF4400, 0xFFFF8844, 0xFFFFAA22, 0xFFFFDD44 }
            table.insert(particles, {
                x = x, y = y,
                vx = math.cos(angle) * speed,
                vy = math.sin(angle) * speed - 1,
                life = 10 + math.random(15),
                maxLife = 25,
                color = colors[math.random(#colors)],
                size = 2 + math.random(3),
                gravity = -0.04,  -- fire rises
            })
        end
    end,
}

-- Get death effect for an enemy icon
local function getDeathEffect(icon)
    if icon == 538 then return PARTICLE.skull end       -- Magicked Skull
    if icon == 16122 then return PARTICLE.fire end      -- Troll (fire/forge theme)
    return nil  -- use default colored burst
end

local function updateParticles()
    local i = 1
    while i <= #particles do
        local p = particles[i]
        p.x = p.x + p.vx
        p.y = p.y + p.vy
        p.vy = p.vy + p.gravity
        p.vx = p.vx * 0.96  -- friction
        p.life = p.life - 1
        if p.life <= 0 then
            table.remove(particles, i)
        else
            i = i + 1
        end
    end
end

-- renderParticlePixels defined after putPixel (needs it in scope)

------------------------------------------------------------
-- Tile map (level-based procedural scrolling)
------------------------------------------------------------
local TILE_FLOOR  = 0  -- walkable
local TILE_WALL   = 1  -- solid
local TILE_DETAIL = 2  -- floor detail (walkable, visual only)
local TILE_WATER  = 3  -- obstacle

-- Level themes: each has floor/wall/detail colors and generation rules
local LEVEL_THEMES = {
    -- Level 1: Goblin Cave (blue-gray tones)
    [1] = {
        name = 'Goblin Cave',
        floor = {
            0xFF1C2530, 0xFF1E2733, 0xFF1A2330, 0xFF20292E,  -- dark blue-gray stone
        },
        detail = {
            0xFF222D3A, 0xFF252F3C, 0xFF202B38, 0xFF283340,  -- slightly lighter patches
        },
        wall = {
            0xFF0E1620, 0xFF101822, 0xFF0C141E, 0xFF121A24,  -- dark blue-black walls
        },
        wallTop = {
            0xFF1A2535, 0xFF1C2738, 0xFF182332, 0xFF1E2939,  -- wall face (lighter edge)
        },
        water = {
            0xFF0A1830, 0xFF0C1A34, 0xFF081628, 0xFF0E1C36,  -- dark blue pools
        },
    },
    -- Level 2: Beastmen Stronghold (brown/earth tones)
    [2] = {
        name = 'Stronghold',
        floor = {
            0xFF2A2218, 0xFF2C241A, 0xFF282016, 0xFF2E261C,
        },
        detail = {
            0xFF342C20, 0xFF362E22, 0xFF322A1E, 0xFF383024,
        },
        wall = {
            0xFF1A1410, 0xFF1C1612, 0xFF18120E, 0xFF1E1814,
        },
        wallTop = {
            0xFF2A221A, 0xFF2C241C, 0xFF282018, 0xFF2E261E,
        },
        water = {
            0xFF1A1208, 0xFF1C140A, 0xFF181006, 0xFF1E160C,
        },
    },
    -- Level 3: Aht Urhgan Ruins (warm sand/gold tones)
    [3] = {
        name = 'Ruins',
        floor = {
            0xFF2E2820, 0xFF302A22, 0xFF2C261E, 0xFF322C24,
        },
        detail = {
            0xFF3A3228, 0xFF3C342A, 0xFF383026, 0xFF3E362C,
        },
        wall = {
            0xFF1E1810, 0xFF201A12, 0xFF1C160E, 0xFF221C14,
        },
        wallTop = {
            0xFF2E2618, 0xFF30281A, 0xFF2C2416, 0xFF322A1C,
        },
        water = {
            0xFF142028, 0xFF16222A, 0xFF121E26, 0xFF18242C,
        },
    },
}

local MAP_COLS = math.ceil(VIEW_W / TILE)
local MAP_ROWS = math.ceil(VIEW_H / TILE) + 2
local tilemap  = {}

-- Cave generation state (persistent across rows for coherent corridors)
local caveState = {
    leftWall  = 3,    -- left wall edge (in tiles)
    rightWall = MAP_COLS - 2,  -- right wall edge
    targetL   = 3,
    targetR   = MAP_COLS - 2,
    changeTimer = 0,
    poolX     = 0,    -- water pool center
    poolTimer = 0,
}

-- Each row stores: { tiles = { tileType, ... }, colors = { 0xAARRGGBB, ... } }
local function genCaveRow(theme)
    local cs = caveState

    -- Gradually shift corridor shape
    cs.changeTimer = cs.changeTimer - 1
    if cs.changeTimer <= 0 then
        cs.changeTimer = math.random(4, 10)
        local minWidth = 6
        cs.targetL = math.random(1, math.floor(MAP_COLS / 2) - minWidth / 2)
        cs.targetR = math.random(math.ceil(MAP_COLS / 2) + minWidth / 2, MAP_COLS)
        if cs.targetR - cs.targetL < minWidth then
            cs.targetR = cs.targetL + minWidth
        end
    end

    if cs.leftWall < cs.targetL then cs.leftWall = cs.leftWall + 0.3
    elseif cs.leftWall > cs.targetL then cs.leftWall = cs.leftWall - 0.3 end
    if cs.rightWall < cs.targetR then cs.rightWall = cs.rightWall + 0.3
    elseif cs.rightWall > cs.targetR then cs.rightWall = cs.rightWall - 0.3 end

    local lw = math.floor(cs.leftWall)
    local rw = math.ceil(cs.rightWall)
    if rw - lw < 6 then rw = lw + 6 end

    cs.poolTimer = cs.poolTimer - 1
    local poolActive = false
    if cs.poolTimer <= 0 then
        if math.random(30) == 1 then
            cs.poolX = math.random(lw + 2, math.max(lw + 3, rw - 2))
            cs.poolTimer = math.random(2, 4)
        end
    end
    if cs.poolTimer > 0 then poolActive = true end

    local tiles  = {}
    local colors = {}
    for x = 1, MAP_COLS do
        local tileType
        if x <= lw or x >= rw then
            tileType = TILE_WALL
        elseif x == lw + 1 or x == rw - 1 then
            tileType = TILE_WALL + 100
        elseif poolActive and math.abs(x - cs.poolX) <= 1 then
            tileType = TILE_WATER
        elseif math.random(12) == 1 then
            tileType = TILE_DETAIL
        else
            tileType = TILE_FLOOR
        end
        tiles[x] = tileType

        -- Bake color at generation (no index-dependent flicker)
        local variants
        if tileType == TILE_FLOOR then    variants = theme.floor
        elseif tileType == TILE_DETAIL then variants = theme.detail
        elseif tileType == TILE_WALL then   variants = theme.wall
        elseif tileType == TILE_WALL + 100 then variants = theme.wallTop
        elseif tileType == TILE_WATER then  variants = theme.water
        else variants = theme.floor end
        colors[x] = variants[math.random(#variants)]
    end

    return { tiles = tiles, colors = colors }
end

local function initTilemap()
    tilemap = {}
    caveState.leftWall  = 3
    caveState.rightWall = MAP_COLS - 2
    caveState.targetL   = 3
    caveState.targetR   = MAP_COLS - 2
    caveState.changeTimer = 0
    caveState.poolTimer = 0

    local theme = LEVEL_THEMES[getGameLevel()] or LEVEL_THEMES[1]
    for r = 1, MAP_ROWS do
        tilemap[r] = genCaveRow(theme)
    end
end

-- Check if a pixel position is inside a wall tile
-- Tilemap row 1 is at screen y = -TILE + scrollY (just above viewport)
-- Screen y for row r: (r-1)*TILE - TILE + scrollY = (r-2)*TILE + scrollY
-- Inverse: r = floor((py - scrollY) / TILE) + 2
local function isWallAt(px, py)
    local tileX = math.floor(px / TILE) + 1
    local tileY = math.floor((py - scrollY) / TILE) + 2
    if tileX < 1 or tileX > MAP_COLS then return true end
    if tileY < 1 or tileY > #tilemap then return false end  -- off-map = passable
    local row = tilemap[tileY]
    if not row then return false end
    local t = row.tiles[tileX]
    if not t then return false end
    return t == TILE_WALL or t == TILE_WALL + 100
end

local function hitsWall(rx, ry, rw, rh)
    return isWallAt(rx, ry)
        or isWallAt(rx + rw - 1, ry)
        or isWallAt(rx, ry + rh - 1)
        or isWallAt(rx + rw - 1, ry + rh - 1)
end

------------------------------------------------------------
-- D3D texture
------------------------------------------------------------
local texture  = nil
local texHandle = nil
local pixels   = nil
local pitch4   = 0

local function createTexture()
    if texture then return true end
    local hr, tex = d3d8dev:CreateTexture(TEX_W, TEX_H, 1, 0, C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED)
    if hr ~= C.S_OK or tex == nil then return false end
    texture   = d3d.gc_safe_release(tex)
    texHandle = tonumber(ffi.cast('uint32_t', texture))
    return true
end

local function lockTexture()
    if not texture then return false end
    local hr, locked = texture:LockRect(0, nil, 0)
    if hr ~= C.S_OK then return false end
    pitch4 = locked.Pitch / 4
    pixels = ffi.cast('uint32_t*', locked.pBits)
    return true
end

local function unlockTexture()
    if texture then texture:UnlockRect(0) end
    pixels = nil
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
-- Pixel helpers
------------------------------------------------------------
local function putPixel(x, y, col)
    if x >= 0 and x < TEX_W and y >= 0 and y < TEX_H then
        pixels[y * pitch4 + x] = col
    end
end

local function fillRect(rx, ry, rw, rh, col)
    local x0 = math.max(0, math.floor(rx))
    local y0 = math.max(0, math.floor(ry))
    local x1 = math.min(TEX_W - 1, math.floor(rx + rw - 1))
    local y1 = math.min(TEX_H - 1, math.floor(ry + rh - 1))
    for y = y0, y1 do
        local row = y * pitch4
        for x = x0, x1 do
            pixels[row + x] = col
        end
    end
end

local function fillRectOutline(rx, ry, rw, rh, col)
    local x0 = math.floor(rx)
    local y0 = math.floor(ry)
    local x1 = x0 + rw - 1
    local y1 = y0 + rh - 1
    for x = x0, x1 do
        putPixel(x, y0, col)
        putPixel(x, y1, col)
    end
    for y = y0, y1 do
        putPixel(x0, y, col)
        putPixel(x1, y, col)
    end
end

------------------------------------------------------------
-- AABB collision
------------------------------------------------------------
-- Draw a soft circular glow at px,py with given radius and color
local function drawGlow(cx, cy, radius, r, g, b)
    local r2 = radius * radius
    for dy = -radius, radius do
        for dx = -radius, radius do
            local d2 = dx * dx + dy * dy
            if d2 <= r2 then
                local falloff = 1.0 - (d2 / r2)
                local pr = math.floor(r * falloff)
                local pg = math.floor(g * falloff)
                local pb = math.floor(b * falloff)
                putPixel(math.floor(cx) + dx, math.floor(cy) + dy,
                    bit.bor(0xFF000000, bit.lshift(pr, 16), bit.lshift(pg, 8), pb))
            end
        end
    end
end

local function renderParticlePixels()
    for _, p in ipairs(particles) do
        local fade = p.life / p.maxLife
        local baseCol = p.color
        local cr = math.floor(bit.band(bit.rshift(baseCol, 16), 0xFF) * fade)
        local cg = math.floor(bit.band(bit.rshift(baseCol, 8), 0xFF) * fade)
        local cb = math.floor(bit.band(baseCol, 0xFF) * fade)
        local col = bit.bor(0xFF000000, bit.lshift(cr, 16), bit.lshift(cg, 8), cb)

        local s = p.size
        local px = math.floor(p.x)
        local py = math.floor(p.y)
        for dy = 0, s - 1 do
            for dx = 0, s - 1 do
                putPixel(px + dx, py + dy, col)
            end
        end
    end
end

------------------------------------------------------------
-- AABB collision
------------------------------------------------------------
local function aabb(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

------------------------------------------------------------
-- Player helpers
------------------------------------------------------------
local function getPlayerStats()
    local def = CLASS_DEF[player.class]
    local dmg   = def.projDmg
    local speed = def.speed
    local rate  = def.projRate
    local hp    = def.hp

    for slot = 1, 3 do
        local eq = getEquipped(slot)
        if eq and eq.stats then
            dmg   = dmg + (eq.stats.dmg or 0)
            hp    = hp + (eq.stats.hp or 0)
            speed = speed + (eq.stats.speed or 0)
            rate  = rate - (eq.stats.rate or 0)
        end
    end
    rate = math.max(2, rate)

    return { dmg = dmg, speed = speed, rate = rate, hp = hp }
end

-- Spin speed per class (radians/sec): WAR axes spin, NIN shuriken spin fast
local CLASS_SPIN = {
    [CLASS_WAR] = 12,  -- moderate spin
    [CLASS_NIN] = 20,  -- fast spin
}

local function fireBLMProjectile(stats, def)
    local lvl = player.level
    -- Radius grows: 3 → 4 → 5 → 6
    local radius = math.min(6, 3 + math.floor(lvl / 3))

    local function addFireball(px, py, vx, vy)
        table.insert(playerProj, {
            x = px, y = py, vx = vx, vy = vy,
            size = radius * 2, color = def.projColor, dmg = stats.dmg,
            fire = true, fireRadius = radius, trailTimer = 0,
        })
    end

    if lvl >= 9 then
        -- Triple spread
        addFireball(player.x, player.y - 8, 0, -def.projSpeed)
        addFireball(player.x - 8, player.y - 4, -1.0, -def.projSpeed * 0.85)
        addFireball(player.x + 8, player.y - 4, 1.0, -def.projSpeed * 0.85)
    elseif lvl >= 6 then
        -- Twin fireballs
        addFireball(player.x - 6, player.y - 6, -0.4, -def.projSpeed)
        addFireball(player.x + 6, player.y - 6, 0.4, -def.projSpeed)
    elseif lvl >= 3 then
        -- Single bigger fireball, faster
        addFireball(player.x, player.y - 8, 0, -def.projSpeed * 1.15)
    else
        -- Basic fireball
        addFireball(player.x, player.y - 8, 0, -def.projSpeed)
    end
end

local function fireWARProjectile(stats, def)
    local lvl = player.level
    local icon = def.projIcon
    local spinSpeed = CLASS_SPIN[CLASS_WAR]

    local function addAxe(px, py, vx, vy, sz)
        table.insert(playerProj, {
            x = px, y = py, vx = vx, vy = vy,
            size = sz or 4, color = def.projColor, dmg = stats.dmg,
            icon = icon, spin = spinSpeed,
        })
    end

    if lvl >= 9 then
        -- Triple axes: center + wide flanks
        addAxe(player.x, player.y - 8, 0, -def.projSpeed, 5)
        addAxe(player.x - 10, player.y - 4, -1.2, -def.projSpeed * 0.8, 4)
        addAxe(player.x + 10, player.y - 4, 1.2, -def.projSpeed * 0.8, 4)
    elseif lvl >= 6 then
        -- Twin axes with slight spread
        addAxe(player.x - 6, player.y - 6, -0.5, -def.projSpeed, 5)
        addAxe(player.x + 6, player.y - 6, 0.5, -def.projSpeed, 5)
    elseif lvl >= 3 then
        -- Single bigger axe, faster spin
        addAxe(player.x, player.y - 8, 0, -def.projSpeed * 1.1, 5)
    else
        -- Basic axe
        addAxe(player.x, player.y - 8, 0, -def.projSpeed)
    end
end

local function fireRNGProjectile(stats, def)
    local lvl = player.level
    local icon = def.projIcon

    local function addArrow(px, py, vx, vy)
        table.insert(playerProj, {
            x = px, y = py, vx = vx, vy = vy,
            size = def.projSize, color = def.projColor, dmg = stats.dmg, icon = icon,
        })
    end

    if lvl >= 9 then
        -- 5-arrow fan
        addArrow(player.x, player.y - 8, 0, -def.projSpeed)
        addArrow(player.x - 4, player.y - 6, -0.5, -def.projSpeed)
        addArrow(player.x + 4, player.y - 6, 0.5, -def.projSpeed)
        addArrow(player.x - 8, player.y - 4, -1.0, -def.projSpeed * 0.9)
        addArrow(player.x + 8, player.y - 4, 1.0, -def.projSpeed * 0.9)
    elseif lvl >= 6 then
        -- Triple arrows
        addArrow(player.x, player.y - 8, 0, -def.projSpeed)
        addArrow(player.x - 5, player.y - 5, -0.6, -def.projSpeed * 0.95)
        addArrow(player.x + 5, player.y - 5, 0.6, -def.projSpeed * 0.95)
    elseif lvl >= 3 then
        -- Twin arrows, tighter spread
        addArrow(player.x - 3, player.y - 6, -0.2, -def.projSpeed)
        addArrow(player.x + 3, player.y - 6, 0.2, -def.projSpeed)
    else
        -- Basic twin arrows
        addArrow(player.x - 4, player.y - 6, -0.3, -def.projSpeed)
        addArrow(player.x + 4, player.y - 6, 0.3, -def.projSpeed)
    end
end

local function fireNINProjectile(stats, def)
    local lvl = player.level
    local icon = def.projIcon
    local spinSpeed = CLASS_SPIN[CLASS_NIN]

    local function addShuriken(px, py, vx, vy)
        table.insert(playerProj, {
            x = px, y = py, vx = vx, vy = vy,
            size = def.projSize, color = def.projColor, dmg = stats.dmg,
            icon = icon, spin = spinSpeed,
        })
    end

    if lvl >= 9 then
        -- 4 shuriken burst + center
        addShuriken(player.x, player.y - 8, 0, -def.projSpeed)
        addShuriken(player.x - 6, player.y - 5, -0.8, -def.projSpeed * 0.9)
        addShuriken(player.x + 6, player.y - 5, 0.8, -def.projSpeed * 0.9)
        addShuriken(player.x, player.y - 4, 0, -def.projSpeed * 1.3)
    elseif lvl >= 6 then
        -- Triple shuriken
        addShuriken(player.x, player.y - 8, 0, -def.projSpeed)
        addShuriken(player.x - 5, player.y - 5, -0.6, -def.projSpeed * 0.95)
        addShuriken(player.x + 5, player.y - 5, 0.6, -def.projSpeed * 0.95)
    elseif lvl >= 3 then
        -- Twin shuriken
        addShuriken(player.x - 4, player.y - 6, -0.3, -def.projSpeed)
        addShuriken(player.x + 4, player.y - 6, 0.3, -def.projSpeed)
    else
        -- Single fast shuriken
        addShuriken(player.x, player.y - 8, 0, -def.projSpeed)
    end
end

local function fireProjectile()
    local def = CLASS_DEF[player.class]
    local stats = getPlayerStats()

    if player.class == CLASS_BLM then
        fireBLMProjectile(stats, def)
    elseif player.class == CLASS_WAR then
        fireWARProjectile(stats, def)
    elseif player.class == CLASS_RNG then
        fireRNGProjectile(stats, def)
    elseif player.class == CLASS_NIN then
        fireNINProjectile(stats, def)
    end
end

local function fireChargedShot()
    local def = CLASS_DEF[player.class]
    local stats = getPlayerStats()

    local icon = def.projIcon

    if player.class == CLASS_BLM then
        -- Firaga: massive fireball that explodes on impact
        table.insert(playerProj, {
            x = player.x, y = player.y - 10,
            vx = 0, vy = -2.5,
            size = 14, color = def.chargeColor, dmg = stats.dmg + def.chargeDmg,
            fire = true, fireRadius = 7, trailTimer = 0, firaga = true,
        })
    elseif player.class == CLASS_WAR then
        -- Spinning axe: pierces through enemies (faster spin on charged)
        table.insert(playerProj, {
            x = player.x, y = player.y - 10,
            vx = 0, vy = -def.projSpeed * 0.8,
            size = def.chargeSize, color = def.chargeColor, dmg = stats.dmg + def.chargeDmg,
            pierce = true, icon = icon, spin = 18,
        })
    elseif player.class == CLASS_RNG then
        -- Arrow rain: 5-way spread (no spin)
        for angle = -2, 2 do
            table.insert(playerProj, {
                x = player.x, y = player.y - 6,
                vx = angle * 0.8, vy = -def.projSpeed,
                size = def.projSize, color = def.chargeColor, dmg = stats.dmg + def.chargeDmg,
                icon = icon,
            })
        end
    elseif player.class == CLASS_NIN then
        -- Ninjutsu: burst of shuriken + teleport forward (all spin)
        for angle = -3, 3 do
            table.insert(playerProj, {
                x = player.x, y = player.y - 6,
                vx = angle * 1.2, vy = -def.projSpeed * 0.8,
                size = def.projSize, color = def.chargeColor, dmg = stats.dmg + def.chargeDmg,
                icon = icon, spin = 25,
            })
        end
        -- Teleport forward
        player.y = math.max(20, player.y - 40)
        player.iframes = 30
    end
end

------------------------------------------------------------
-- Enemy spawning
-- getGameLevel moved earlier (before tilemap, after player state)

local function spawnEnemy()
    local gameLevel = getGameLevel()

    -- Build pool of eligible enemies
    local pool = {}
    for _, etype in ipairs(ENEMY_TYPES) do
        if etype.level == 0 then
            -- Undead: rare spawn at any level
            if math.random(8) == 1 then
                table.insert(pool, etype)
            end
        elseif etype.level <= gameLevel then
            table.insert(pool, etype)
        end
    end

    if #pool == 0 then return end
    local etype = pool[math.random(#pool)]

    -- Scale HP with player level
    local scaledHp = etype.hp + player.level * 3

    -- Spawn within corridor (use cave wall positions)
    local cs = caveState
    local spawnLeft  = math.floor(cs.leftWall + 1) * TILE + 10
    local spawnRight = math.ceil(cs.rightWall - 1) * TILE - 10
    if spawnLeft >= spawnRight then spawnLeft = 20; spawnRight = VIEW_W - 20 end

    local e = {
        icon       = etype.icon,
        color      = etype.color,
        x          = math.random(spawnLeft, spawnRight),
        y          = -20,
        w          = 16,
        h          = 16,
        hp         = scaledHp,
        maxHp      = scaledHp,
        speed      = etype.speed,
        score      = etype.score,
        shootRate  = etype.shootRate,
        shootTimer = math.random(0, etype.shootRate > 0 and etype.shootRate or 1),
        projSpeed  = etype.projSpeed,
        projDmg    = etype.projDmg,
        projIcon   = etype.projIcon,
        dropChance = etype.dropChance,
        movePattern = math.random(3),
        moveTimer  = 0,
    }
    table.insert(enemies, e)
end

------------------------------------------------------------
-- Drop system
------------------------------------------------------------
local function rollDrop(ex, ey, dropChance)
    if math.random() > dropChance then return end

    -- Pick a random slot that can still upgrade
    local candidates = {}
    for slot = 1, 3 do
        local options = getUpgradeOptions(slot)
        if options and #options > 0 then
            candidates[#candidates + 1] = slot
        end
    end

    -- All slots maxed: give XP instead
    if #candidates == 0 then
        player.xp = player.xp + 25
        return
    end

    local slot = candidates[math.random(#candidates)]
    local options = getUpgradeOptions(slot)

    -- At T1-T2 (no choice): show generic crystal/ore icon
    -- At T3+ (branching): show the ACTUAL item icon so player can choose
    local tier = player.slotTier[slot]
    local chosenOption = options[math.random(#options)]

    local dropIcon
    if #options > 1 then
        -- Branching tier: show the specific item icon
        dropIcon = chosenOption.id
    else
        -- Linear tier: show generic material icon
        local icons = SLOT_DATA[slot].dropIcons
        dropIcon = icons[math.random(#icons)]
    end

    table.insert(drops, {
        x = ex, y = ey,
        slot = slot,
        iconId = dropIcon,
        upgradeItem = chosenOption,  -- the specific item this drop upgrades to
        timer = 300,
    })
end

local function pickupDrop(drop)
    local slot = drop.slot
    local item = drop.upgradeItem

    if not item then
        player.xp = player.xp + 25
        return true
    end

    -- Upgrade
    player.slotTier[slot] = player.slotTier[slot] + 1
    player.slotChoice[slot] = item.id

    player.combineMsg = {
        text   = item.name .. '!',
        timer  = 90,
        itemId = item.id,
        rarity = item.rarity,
    }

    -- Update max HP
    local stats = getPlayerStats()
    player.maxHp = stats.hp
    if player.hp > player.maxHp then player.hp = player.maxHp end

    return true
end

------------------------------------------------------------
-- Game reset
------------------------------------------------------------
local function resetGame(classId)
    local def = CLASS_DEF[classId]
    player.class     = classId
    player.x         = VIEW_W / 2
    player.y         = VIEW_H - 40
    player.hp        = def.hp
    player.maxHp     = def.hp
    player.mp        = def.mp
    player.maxMp     = def.mp
    player.xp        = 0
    player.level     = 1
    player.xpNext    = 100
    player.score     = 0
    player.fireTimer = 0
    player.chargeTimer = 0
    player.charging  = false
    player.iframes   = 0
    player.slotTier   = { 0, 0, 0 }
    player.slotChoice = { nil, nil, nil }
    player.combineMsg = nil

    playerProj = {}
    enemyProj  = {}
    enemies    = {}
    drops      = {}
    particles  = {}
    spawnTimer = 0
    waveNum    = 0
    scrollY    = 0

    initTilemap()
    gameState = STATE_PLAYING
end

------------------------------------------------------------
-- Mouse state (set during render when cursor is over game)
------------------------------------------------------------
local mouseInGame = false
local mouseGameX  = 0
local mouseGameY  = 0

------------------------------------------------------------
-- Update: playing
------------------------------------------------------------
local function updatePlaying()
    local def   = CLASS_DEF[player.class]
    local stats = getPlayerStats()

    -- Player movement: chase mouse cursor with wall collision
    if mouseInGame then
        local dx = mouseGameX - player.x
        local dy = mouseGameY - player.y
        local dist = math.sqrt(dx * dx + dy * dy)
        local deadzone = 3
        if dist > deadzone then
            local move = math.min(stats.speed * 2, dist)
            local nx = player.x + dx / dist * move
            local ny = player.y + dy / dist * move

            -- Try X movement
            local hw, hh = player.w / 2, player.h / 2
            if not hitsWall(nx - hw, player.y - hh, player.w, player.h) then
                player.x = nx
            end
            -- Try Y movement
            if not hitsWall(player.x - hw, ny - hh, player.w, player.h) then
                player.y = ny
            end
        end
    end

    player.x = math.max(player.w / 2, math.min(VIEW_W - player.w / 2, player.x))
    player.y = math.max(player.h / 2, math.min(VIEW_H - 20, player.y))

    -- Charge attack (right mouse button)
    if mouseInGame and imgui.IsMouseDown(1) then
        player.charging = true
        player.chargeTimer = player.chargeTimer + 1
    elseif player.charging then
        -- Released right click
        if player.chargeTimer >= def.chargeTime then
            fireChargedShot()
        end
        player.charging = false
        player.chargeTimer = 0
    end

    -- Auto-fire while cursor is in game area (unless charging)
    if mouseInGame and not player.charging then
        player.fireTimer = player.fireTimer - 1
        if player.fireTimer <= 0 then
            fireProjectile()
            player.fireTimer = stats.rate
        end
    end

    -- Invincibility countdown
    if player.iframes > 0 then player.iframes = player.iframes - 1 end

    -- Scroll tilemap
    scrollY = scrollY + scrollSpeed
    if scrollY >= TILE then
        scrollY = scrollY - TILE
        table.remove(tilemap, #tilemap)
        local theme = LEVEL_THEMES[getGameLevel()] or LEVEL_THEMES[1]
        table.insert(tilemap, 1, genCaveRow(theme))
    end

    -- Spawn enemies
    spawnTimer = spawnTimer + 1
    local spawnRate = math.max(20, 80 - player.level * 3)
    if spawnTimer >= spawnRate then
        spawnTimer = 0
        spawnEnemy()
    end

    -- Update player projectiles (destroy on wall hit, fire trails)
    local i = 1
    while i <= #playerProj do
        local p = playerProj[i]
        p.x = p.x + p.vx
        p.y = p.y + p.vy

        local hitWall = isWallAt(p.x, p.y)
        local oob = p.y < -10 or p.y > VIEW_H + 10 or p.x < -10 or p.x > VIEW_W + 10

        if hitWall or oob then
            -- Fire projectiles explode on wall
            if p.fire and hitWall then
                local count = p.firaga and 24 or 8
                pcall(PARTICLE.fire, p.x, p.y)
                if p.firaga then pcall(PARTICLE.fire, p.x, p.y) end
            end
            table.remove(playerProj, i)
        else
            -- Fire trail particles (more particles for bigger fireballs)
            if p.fire then
                local r = p.fireRadius or 3
                local trailCount = p.firaga and 3 or math.max(1, math.floor(r / 2))
                local colors = { 0xFFFF6622, 0xFFFF4400, 0xFFFF8844, 0xFFFFAA22, 0xFFFFDD44 }
                for _ = 1, trailCount do
                    table.insert(particles, {
                        x = p.x + math.random(-r, r),
                        y = p.y + math.random(0, r + 2),
                        vx = math.random() * 0.8 - 0.4,
                        vy = 0.4 + math.random() * 0.8,
                        life = 6 + math.random(10),
                        maxLife = 16,
                        color = colors[math.random(#colors)],
                        size = 1 + math.random(math.min(3, r - 1)),
                        gravity = -0.03,
                    })
                end
            end
            i = i + 1
        end
    end

    -- Update enemy projectiles (destroy on wall hit)
    i = 1
    while i <= #enemyProj do
        local p = enemyProj[i]
        p.x = p.x + p.vx
        p.y = p.y + p.vy
        if p.y < -10 or p.y > VIEW_H + 10 or p.x < -10 or p.x > VIEW_W + 10 or isWallAt(p.x, p.y) then
            table.remove(enemyProj, i)
        else
            i = i + 1
        end
    end

    -- Update enemies
    i = 1
    while i <= #enemies do
        local e = enemies[i]
        e.moveTimer = e.moveTimer + 1

        -- Movement: always advance downward, navigate around walls
        local hw, hh = e.w / 2, e.h / 2
        local wantY = e.y + e.speed
        local wantX = e.x

        -- Desired lateral movement
        if e.movePattern == 2 then
            wantX = e.x + math.sin(e.moveTimer * 0.05) * 1.5
        elseif e.movePattern == 3 then
            if player.x > e.x + 2 then wantX = e.x + 0.5
            elseif player.x < e.x - 2 then wantX = e.x - 0.5 end
        end

        -- Try desired position
        if not hitsWall(wantX - hw, wantY - hh, e.w, e.h) then
            e.x = wantX
            e.y = wantY
        else
            -- Blocked: try just vertical
            if not hitsWall(e.x - hw, wantY - hh, e.w, e.h) then
                e.y = wantY
            else
                -- Blocked vertically: navigate sideways toward open space
                -- Try left and right, pick the one that's open
                local tryLeft  = not hitsWall(e.x - e.speed * 2 - hw, e.y - hh, e.w, e.h)
                local tryRight = not hitsWall(e.x + e.speed * 2 - hw, e.y - hh, e.w, e.h)

                if tryLeft and tryRight then
                    -- Both open: move toward corridor center
                    local center = VIEW_W / 2
                    if e.x > center then e.x = e.x - e.speed
                    else e.x = e.x + e.speed end
                elseif tryLeft then
                    e.x = e.x - e.speed
                elseif tryRight then
                    e.x = e.x + e.speed
                end

                -- Try vertical again after lateral adjustment
                if not hitsWall(e.x - hw, wantY - hh, e.w, e.h) then
                    e.y = wantY
                end
            end

            -- Try just lateral if vertical still blocked
            if not hitsWall(wantX - hw, e.y - hh, e.w, e.h) then
                e.x = wantX
            end
        end

        -- Enemy shooting
        if e.shootRate > 0 then
            e.shootTimer = e.shootTimer - 1
            if e.shootTimer <= 0 then
                e.shootTimer = e.shootRate
                -- Aim at player
                local dx2 = player.x - e.x
                local dy2 = player.y - e.y
                local dist = math.sqrt(dx2 * dx2 + dy2 * dy2)
                if dist > 0 then
                    local pvx = dx2 / dist * e.projSpeed
                    local pvy = dy2 / dist * e.projSpeed
                    table.insert(enemyProj, {
                        x = e.x, y = e.y + e.h / 2,
                        vx = pvx, vy = pvy,
                        angle = math.atan2(pvy, pvx),
                        size = 3, color = COL.red, dmg = e.projDmg,
                        icon = e.projIcon,
                        spin = e.projIcon and 10 or nil,  -- all icon projectiles spin
                    })
                end
            end
        end

        -- Remove if off screen
        if e.y > VIEW_H + 30 then
            table.remove(enemies, i)
        else
            i = i + 1
        end
    end

    -- Player projectile vs enemy collision
    i = 1
    while i <= #playerProj do
        local p = playerProj[i]
        local hit = false
        for j = #enemies, 1, -1 do
            local e = enemies[j]
            if aabb(p.x - p.size / 2, p.y - p.size / 2, p.size, p.size,
                    e.x - e.w / 2, e.y - e.h / 2, e.w, e.h) then
                e.hp = e.hp - p.dmg
                -- Hit effect: fire explosion for fireballs, sparks for others
                if p.fire then
                    pcall(PARTICLE.fire, p.x, p.y)
                    -- Firaga: damage nearby enemies too (AoE)
                    if p.firaga then
                        for k = #enemies, 1, -1 do
                            local other = enemies[k]
                            if k ~= j then
                                local ddx = other.x - p.x
                                local ddy = other.y - p.y
                                if ddx * ddx + ddy * ddy < 30 * 30 then
                                    other.hp = other.hp - math.floor(p.dmg * 0.6)
                                    if other.hp <= 0 then
                                        player.score = player.score + other.score
                                        player.xp   = player.xp + other.score
                                        pcall(PARTICLE.fire, other.x, other.y)
                                        rollDrop(other.x, other.y, other.dropChance)
                                        table.remove(enemies, k)
                                        if k < j then j = j - 1 end
                                    end
                                end
                            end
                        end
                    end
                else
                    pcall(PARTICLE.hit, p.x, p.y)
                end
                if e.hp <= 0 then
                    -- Death effect
                    local deathFx = getDeathEffect(e.icon)
                    if deathFx then
                        pcall(deathFx, e.x, e.y)
                    else
                        pcall(PARTICLE.death, e.x, e.y, e.color or 0xFF888888)
                    end
                    player.score = player.score + e.score
                    player.xp   = player.xp + e.score
                    rollDrop(e.x, e.y, e.dropChance)
                    table.remove(enemies, j)
                end
                if not p.pierce then
                    hit = true
                    break
                end
            end
        end
        if hit then
            table.remove(playerProj, i)
        else
            i = i + 1
        end
    end

    -- Enemy projectile vs player collision
    if player.iframes <= 0 then
        i = 1
        while i <= #enemyProj do
            local p = enemyProj[i]
            if aabb(p.x - p.size / 2, p.y - p.size / 2, p.size, p.size,
                    player.x - player.w / 2, player.y - player.h / 2, player.w, player.h) then
                player.hp = player.hp - p.dmg
                player.iframes = 45
                table.remove(enemyProj, i)
                if player.hp <= 0 then
                    gameState = STATE_GAMEOVER
                    return
                end
            else
                i = i + 1
            end
        end
    end

    -- Enemy vs player collision (bomb-type or touch damage)
    if player.iframes <= 0 then
        for j = #enemies, 1, -1 do
            local e = enemies[j]
            if aabb(player.x - player.w / 2, player.y - player.h / 2, player.w, player.h,
                    e.x - e.w / 2, e.y - e.h / 2, e.w, e.h) then
                player.hp = player.hp - 15
                player.iframes = 45
                e.hp = e.hp - 30
                pcall(PARTICLE.hit, e.x, e.y)
                if e.hp <= 0 then
                    local deathFx = getDeathEffect(e.icon)
                    if deathFx then
                        pcall(deathFx, e.x, e.y)
                    else
                        pcall(PARTICLE.death, e.x, e.y, e.color or 0xFF888888)
                    end
                    player.score = player.score + e.score
                    rollDrop(e.x, e.y, e.dropChance)
                    table.remove(enemies, j)
                end
                if player.hp <= 0 then
                    gameState = STATE_GAMEOVER
                    return
                end
            end
        end
    end

    -- Drop pickup (scroll with map, wider pickup radius)
    i = 1
    while i <= #drops do
        local d = drops[i]
        d.timer = d.timer - 1
        d.y = d.y + scrollSpeed  -- scroll with map
        if d.timer <= 0 or d.y > VIEW_H + 20 then
            table.remove(drops, i)
        elseif aabb(player.x - 10, player.y - 10, 20, 20,
                     d.x - 5, d.y - 5, 10, 10) then
            if pickupDrop(d) then
                table.remove(drops, i)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    -- Combine message countdown
    if player.combineMsg then
        player.combineMsg.timer = player.combineMsg.timer - 1
        if player.combineMsg.timer <= 0 then player.combineMsg = nil end
    end

    -- Update particles
    updateParticles()

    -- Level up
    if player.xp >= player.xpNext then
        player.level = player.level + 1
        player.xp    = player.xp - player.xpNext
        player.xpNext = math.floor(player.xpNext * 1.4)
        -- Heal on level up
        local newStats = getPlayerStats()
        player.maxHp = newStats.hp
        player.hp    = player.maxHp

        -- Ability unlock announcements at levels 3, 6, 9
        local ABILITY_UNLOCKS = {
            [CLASS_BLM] = { [3] = 'Fire II',      [6] = 'Fire III',       [9] = 'Firaga' },
            [CLASS_WAR] = { [3] = 'Power Axe',    [6] = 'Twin Axes',      [9] = 'Axe Storm' },
            [CLASS_RNG] = { [3] = 'Double Shot',   [6] = 'Triple Shot',    [9] = 'Barrage' },
            [CLASS_NIN] = { [3] = 'Ni Shuriken',  [6] = 'San Shuriken',   [9] = 'Mijin Gakure' },
        }
        local unlocks = ABILITY_UNLOCKS[player.class]
        if unlocks and unlocks[player.level] then
            player.combineMsg = {
                text = unlocks[player.level] .. ' unlocked!',
                timer = 120,
                itemId = CLASS_DEF[player.class].icon,
                rarity = player.level >= 9 and 4 or (player.level >= 6 and 3 or 2),
            }
        end
    end

    -- (mouse cursor leaving game area pauses shooting naturally)
end

------------------------------------------------------------
-- Render: tilemap
------------------------------------------------------------
local function renderTilemap()
    local offsetY = math.floor(scrollY)
    for r = 1, #tilemap do
        local row = tilemap[r]
        if row and row.colors then
            local ty = (r - 2) * TILE + offsetY
            -- Skip rows entirely off screen
            if ty > -TILE and ty < VIEW_H + TILE then
                for c = 1, MAP_COLS do
                    local col = row.colors[c]
                    if col then
                        local tx = (c - 1) * TILE
                        fillRect(tx, ty, TILE, TILE, col)
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- Render: game objects
------------------------------------------------------------
-- Player, enemies, and projectiles are rendered as icon overlays via imgui
-- (after the game texture). Only HP bars and charge indicators go in the pixel buffer.

local function renderPlayerPixels()
    -- Charge indicator bar in pixel buffer
    if player.charging then
        local def = CLASS_DEF[player.class]
        local px = math.floor(player.x - player.w / 2)
        local py = math.floor(player.y - player.h / 2)
        local pct = math.min(1.0, player.chargeTimer / def.chargeTime)
        local barW = math.floor(player.w * pct)
        fillRect(px, py - 4, barW, 2, COL.yellow)
    end
end

local function renderEnemyPixels()
    for _, e in ipairs(enemies) do
        -- HP bar only
        if e.hp < e.maxHp then
            local ex = math.floor(e.x - e.w / 2)
            local ey = math.floor(e.y - e.h / 2)
            local barW = e.w
            local filled = math.floor(barW * e.hp / e.maxHp)
            fillRect(ex, ey - 3, barW, 2, COL.hp_bg)
            fillRect(ex, ey - 3, filled, 2, COL.hp_bar)
        end
    end
end

local function renderProjectilePixels()
    for _, p in ipairs(playerProj) do
        if p.fire then
            -- Fireball: glowing circle with hot core
            local r = p.fireRadius or 3
            if p.firaga then
                -- Large firaga: outer orange glow + inner white core
                drawGlow(p.x, p.y, r, 255, 100, 20)
                drawGlow(p.x, p.y, math.max(2, r - 3), 255, 220, 120)
            else
                -- Normal fireball: orange glow + yellow core
                drawGlow(p.x, p.y, r, 255, 80, 10)
                drawGlow(p.x, p.y, math.max(1, r - 1), 255, 180, 50)
            end
        elseif not p.icon then
            local s = p.size
            fillRect(math.floor(p.x - s / 2), math.floor(p.y - s / 2), s, s, p.color)
        end
    end
end

-- Rotated icon drawing via AddImageQuad (drawlist)
-- texHandle must be the numeric D3D texture handle
-- cx, cy = screen-space center, size = icon size, angle = radians
local hasAddImageQuad = nil -- nil = untested, true/false after first attempt

local function drawRotatedIcon(dl, texId, cx, cy, size, angle, col)
    if hasAddImageQuad == false then return false end

    local half = size / 2
    local cosA = math.cos(angle)
    local sinA = math.sin(angle)

    -- Rotated corners (TL, TR, BR, BL)
    local p1 = { cx + (-half) * cosA - (-half) * sinA, cy + (-half) * sinA + (-half) * cosA }
    local p2 = { cx + ( half) * cosA - (-half) * sinA, cy + ( half) * sinA + (-half) * cosA }
    local p3 = { cx + ( half) * cosA - ( half) * sinA, cy + ( half) * sinA + ( half) * cosA }
    local p4 = { cx + (-half) * cosA - ( half) * sinA, cy + (-half) * sinA + ( half) * cosA }

    local ok, err = pcall(function()
        dl:AddImageQuad(texId, p1, p2, p3, p4, { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, col or 0xFFFFFFFF)
    end)

    if not ok then
        hasAddImageQuad = false
        return false
    end
    hasAddImageQuad = true
    return true
end

-- Icon overlay rendering (called after imgui.Image, positions relative to game area origin)
local ICON_SZ     = 20  -- player/enemy icon size
local PROJ_ICON_SZ = 12  -- projectile icon size

local function renderIconOverlays(ox, oy)
    if not renderIcon then return end
    local def = CLASS_DEF[player.class]
    local dl = imgui.GetWindowDrawList()
    local wx, wy = imgui.GetWindowPos()

    -- Player icon
    if player.iframes <= 0 or math.floor(player.iframes / 3) % 2 == 1 then
        imgui.SetCursorPos({ ox + player.x - ICON_SZ / 2, oy + player.y - ICON_SZ / 2 })
        renderIcon(def.icon, ICON_SZ)
    end

    -- Enemy icons
    for _, e in ipairs(enemies) do
        if e.y > -ICON_SZ and e.y < VIEW_H + ICON_SZ then
            imgui.SetCursorPos({ ox + e.x - ICON_SZ / 2, oy + e.y - ICON_SZ / 2 })
            renderIcon(e.icon, ICON_SZ)
        end
    end

    -- Player projectile icons
    for _, p in ipairs(playerProj) do
        if p.icon and p.y > -PROJ_ICON_SZ and p.y < VIEW_H + PROJ_ICON_SZ then
            local spin = p.spin
            if spin and getIconHandle then
                -- Spinning projectile (WAR axe, NIN shuriken) via drawlist
                local handle = getIconHandle(p.icon)
                if handle then
                    local screenX = wx + ox + p.x
                    local screenY = wy + oy + p.y
                    local angle = os.clock() * spin
                    drawRotatedIcon(dl, handle, screenX, screenY, PROJ_ICON_SZ, angle, 0xFFFFFFFF)
                else
                    imgui.SetCursorPos({ ox + p.x - PROJ_ICON_SZ / 2, oy + p.y - PROJ_ICON_SZ / 2 })
                    renderIcon(p.icon, PROJ_ICON_SZ)
                end
            else
                imgui.SetCursorPos({ ox + p.x - PROJ_ICON_SZ / 2, oy + p.y - PROJ_ICON_SZ / 2 })
                renderIcon(p.icon, PROJ_ICON_SZ)
            end
        end
    end

    -- Enemy projectile icons (rotated toward direction of travel)
    for _, p in ipairs(enemyProj) do
        if p.y > -PROJ_ICON_SZ and p.y < VIEW_H + PROJ_ICON_SZ then
            local screenX = wx + ox + p.x
            local screenY = wy + oy + p.y
            local drawn = false
            if p.icon and getIconHandle then
                local handle = getIconHandle(p.icon)
                if handle then
                    local angle
                    if p.spin then
                        angle = os.clock() * p.spin
                    else
                        angle = p.angle or math.atan2(p.vy, p.vx)
                    end
                    drawn = drawRotatedIcon(dl, handle, screenX, screenY, PROJ_ICON_SZ, angle, 0xFFFFFFFF)
                end
            end
            if not drawn then
                -- Fallback: colored square
                local half = p.size
                dl:AddRectFilled(
                    { screenX - half, screenY - half },
                    { screenX + half, screenY + half },
                    imgui.GetColorU32({ 1.0, 0.3, 0.3, 1.0 }))
            end
        end
    end
end

local function renderDrops()
    -- Slot-colored glow under each drop
    local SLOT_GLOW = {
        [1] = 0xFF443322,  -- weapon (warm)
        [2] = 0xFF223344,  -- body (blue)
        [3] = 0xFF334422,  -- accessory (green)
    }
    for _, d in ipairs(drops) do
        local col = SLOT_GLOW[d.slot] or 0xFF333333
        fillRect(math.floor(d.x - 5), math.floor(d.y - 5), 10, 10, col)
    end
end

-- Render item icons on top of drops
local function renderDropIcons(imgOriginX, imgOriginY)
    if not renderIcon then return end
    for _, d in ipairs(drops) do
        local ix = imgOriginX + d.x - 8
        local iy = imgOriginY + d.y - 8
        imgui.SetCursorPos({ ix, iy })
        renderIcon(d.iconId, 16)
    end
end

------------------------------------------------------------
-- Render: HUD (drawn over the game area)
------------------------------------------------------------
local function renderHUD()
    -- HP bar (top left)
    local barX, barY, barW, barH = 4, 4, 60, 6
    fillRect(barX, barY, barW, barH, COL.hp_bg)
    local hpFill = math.floor(barW * player.hp / player.maxHp)
    fillRect(barX, barY, hpFill, barH, COL.hp_bar)
    fillRectOutline(barX, barY, barW, barH, COL.gray)

    -- XP bar (below HP)
    fillRect(barX, barY + 8, barW, 3, COL.darkgray)
    local xpFill = math.floor(barW * player.xp / player.xpNext)
    fillRect(barX, barY + 8, xpFill, 3, COL.xp_bar)

    -- Score (top right, rendered via imgui text overlay later)
end

------------------------------------------------------------
-- Render: full frame
------------------------------------------------------------
local function renderGameFrame()
    if not lockTexture() then return end

    -- Clear
    for y = 0, TEX_H - 1 do
        local row = y * pitch4
        for x = 0, TEX_W - 1 do
            pixels[row + x] = COL.bg
        end
    end

    if gameState == STATE_PLAYING or gameState == STATE_PAUSED then
        renderTilemap()
        renderDrops()
        renderEnemyPixels()
        renderProjectilePixels()
        renderParticlePixels()
        renderPlayerPixels()
        renderHUD()
    end

    unlockTexture()
end

------------------------------------------------------------
-- ImGui rendering
------------------------------------------------------------
local isOpen = { false }
local menuSel = 1

local function renderMenuOverlay()
    -- Constrain menu to game area width
    imgui.BeginChild('##shmup_menu', { TEX_W + 4, -1 }, false)

    imgui.Spacing()
    imgui.Spacing()
    imgui.Spacing()

    -- Title
    local menuW = TEX_W
    imgui.SetCursorPosX((menuW - imgui.CalcTextSize('CRYSTAL WARS')) / 2)
    imgui.TextColored({ 0.90, 0.75, 0.30, 1.0 }, 'CRYSTAL WARS')
    imgui.Spacing()
    imgui.Spacing()

    local cardW = menuW - 24
    local cardH = 52

    for id, def in ipairs(CLASS_DEF) do
        local r = bit.band(bit.rshift(def.color, 16), 0xFF) / 255
        local g = bit.band(bit.rshift(def.color, 8), 0xFF) / 255
        local b = bit.band(def.color, 0xFF) / 255

        -- Card as a styled child window (acts as button)
        imgui.SetCursorPosX(12)
        imgui.PushStyleColor(ImGuiCol_ChildBg, { r * 0.15, g * 0.15, b * 0.15, 0.90 })
        imgui.PushStyleColor(ImGuiCol_Border, { r * 0.4, g * 0.4, b * 0.4, 0.50 })
        imgui.BeginChild(string.format('##class_%d', id), { cardW, cardH }, true,
            bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse))

        -- Icon on the left
        imgui.SetCursorPos({ 6, 6 })
        if renderIcon and def.icon then
            renderIcon(def.icon, 40)
        end

        -- Name + stats on the right
        imgui.SetCursorPos({ 52, 6 })
        imgui.TextColored({ r, g, b, 1.0 }, def.name)

        imgui.SetCursorPos({ 52, 22 })
        imgui.TextColored({ 0.55, 0.55, 0.60, 1.0 },
            string.format('HP:%d  SPD:%.1f  DMG:%d', def.hp, def.speed, def.projDmg))

        imgui.SetCursorPos({ 52, 36 })
        imgui.TextColored({ 0.45, 0.45, 0.50, 1.0 }, def.desc)

        imgui.EndChild()
        imgui.PopStyleColor(2)

        -- Click the card to select class
        if imgui.IsItemHovered() then
            -- Hover highlight
            local dl = imgui.GetWindowDrawList()
            local wx, wy = imgui.GetItemRectMin()
            local wx2, wy2 = imgui.GetItemRectMax()
            dl:AddRect({ wx, wy }, { wx2, wy2 },
                imgui.GetColorU32({ r, g, b, 0.60 }), 4, 0, 2)
        end
        if imgui.IsItemClicked() then
            resetGame(id)
        end

        imgui.Spacing()
    end

    imgui.EndChild()
end

local function renderGameOverOverlay()
    imgui.Spacing()
    imgui.Spacing()

    imgui.SetCursorPosX((imgui.GetWindowWidth() - imgui.CalcTextSize('GAME OVER')) / 2)
    imgui.TextColored({ 1.0, 0.3, 0.3, 1.0 }, 'GAME OVER')
    imgui.Spacing()

    local scoreText = string.format('Score: %d  Level: %d', player.score, player.level)
    imgui.SetCursorPosX((imgui.GetWindowWidth() - imgui.CalcTextSize(scoreText)) / 2)
    imgui.TextColored({ 0.90, 0.80, 0.30, 1.0 }, scoreText)
    imgui.Spacing()
    imgui.Spacing()

    local btnW = 120
    imgui.SetCursorPosX((imgui.GetWindowWidth() - btnW) / 2)
    if imgui.Button('Try Again##shmup', { btnW, 28 }) then
        gameState = STATE_MENU
    end
end

local function renderPausedOverlay()
    imgui.Spacing()
    imgui.Spacing()

    imgui.SetCursorPosX((imgui.GetWindowWidth() - imgui.CalcTextSize('PAUSED')) / 2)
    imgui.TextColored({ 0.80, 0.80, 0.80, 1.0 }, 'PAUSED')
    imgui.Spacing()

    local btnW = 100
    imgui.SetCursorPosX((imgui.GetWindowWidth() - btnW) / 2)
    if imgui.Button('Resume##shmup', { btnW, 28 }) then
        gameState = STATE_PLAYING
    end
end

------------------------------------------------------------
-- Side panel: equipment + inventory (imgui)
------------------------------------------------------------
local PANEL_W    = 160
local SLOT_NAMES = { 'Weapon', 'Body', 'Accessory' }
local RARITY_COL = {
    [1] = { 0.60, 0.60, 0.60, 1.0 },  -- common (gray)
    [2] = { 0.40, 0.70, 0.40, 1.0 },  -- uncommon (green)
    [3] = { 0.40, 0.55, 0.90, 1.0 },  -- rare (blue)
    [4] = { 0.75, 0.45, 0.90, 1.0 },  -- epic (purple)
}

local function renderSidePanel()
    imgui.BeginChild('##shmup_panel', { PANEL_W, -1 }, false)

    -- Class / Level / Score
    local def = CLASS_DEF[player.class]
    imgui.TextColored({ 0.90, 0.75, 0.30, 1.0 }, def.abbr)
    imgui.SameLine(0, 6)
    imgui.TextColored({ 0.70, 0.70, 0.75, 1.0 }, string.format('Lv%d', player.level))
    imgui.TextColored({ 0.50, 0.50, 0.55, 1.0 }, string.format('Score: %d', player.score))

    -- HP bar
    imgui.Spacing()
    imgui.TextColored({ 0.50, 0.80, 0.50, 1.0 },
        string.format('HP %d/%d', player.hp, player.maxHp))
    local hpPct = player.maxHp > 0 and player.hp / player.maxHp or 0
    local dl = imgui.GetWindowDrawList()
    local bx, by = imgui.GetCursorScreenPos()
    local barW = PANEL_W - 8
    dl:AddRectFilled({ bx, by }, { bx + barW, by + 6 }, imgui.GetColorU32({ 0.12, 0.12, 0.15, 1.0 }), 2)
    dl:AddRectFilled({ bx, by }, { bx + barW * hpPct, by + 6 }, imgui.GetColorU32({ 0.30, 0.75, 0.30, 1.0 }), 2)
    imgui.Dummy({ barW, 8 })

    -- XP bar
    local xpPct = player.xpNext > 0 and player.xp / player.xpNext or 0
    local xx, xy = imgui.GetCursorScreenPos()
    dl:AddRectFilled({ xx, xy }, { xx + barW, xy + 4 }, imgui.GetColorU32({ 0.12, 0.12, 0.15, 1.0 }), 2)
    dl:AddRectFilled({ xx, xy }, { xx + barW * xpPct, xy + 4 }, imgui.GetColorU32({ 0.75, 0.70, 0.20, 1.0 }), 2)
    imgui.Dummy({ barW, 6 })

    -- Equipment slots (linear tier display)
    imgui.Spacing()
    imgui.Separator()
    imgui.TextColored({ 0.70, 0.70, 0.75, 1.0 }, 'Equipment')
    imgui.Spacing()

    local SLOT_LABELS = { 'Weapon', 'Body', 'Accessory' }
    for slot = 1, 3 do
        local sd = SLOT_DATA[slot]
        local tier = player.slotTier[slot]
        local eq = getEquipped(slot)

        imgui.TextColored({ 0.45, 0.45, 0.50, 1.0 }, SLOT_LABELS[slot])
        if eq then
            if renderIcon then renderIcon(eq.id, 20) end
            imgui.SameLine(0, 4)
            local rc = RARITY_COL[eq.rarity] or RARITY_COL[1]
            imgui.TextColored(rc, eq.name)
            -- Stats
            local parts = {}
            if eq.stats.dmg   and eq.stats.dmg > 0   then parts[#parts+1] = string.format('+%d DMG', eq.stats.dmg) end
            if eq.stats.hp    and eq.stats.hp > 0     then parts[#parts+1] = string.format('+%d HP', eq.stats.hp) end
            if eq.stats.speed and eq.stats.speed > 0  then parts[#parts+1] = string.format('+%.1f SPD', eq.stats.speed) end
            if eq.stats.rate  and eq.stats.rate > 0   then parts[#parts+1] = string.format('-%d Rate', eq.stats.rate) end
            if #parts > 0 then
                imgui.TextColored({ 0.40, 0.70, 0.40, 0.80 }, table.concat(parts, '  '))
            end
            -- Tooltip: show upgrade tree
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                for t, tierItems in ipairs(sd.tiers) do
                    for _, tierItem in ipairs(tierItems) do
                        local trc = RARITY_COL[tierItem.rarity] or RARITY_COL[1]
                        local isCurrent = (player.slotChoice[slot] == tierItem.id)
                        local isOwned = false
                        -- Check if this item is in our upgrade path
                        if t < tier then
                            isOwned = true
                        elseif t == tier and tierItem.id == (player.slotChoice[slot] or tierItems[1].id) then
                            isOwned = true
                            isCurrent = true
                        end
                        local prefix = isCurrent and '> ' or '  '
                        local alpha = isOwned and 1.0 or 0.35
                        imgui.TextColored({ trc[1], trc[2], trc[3], alpha },
                            string.format('%sT%d: %s', prefix, t, tierItem.name))
                    end
                end
                imgui.EndTooltip()
            end
        else
            imgui.TextColored({ 0.30, 0.30, 0.35, 1.0 }, '  (empty)')
        end
    end

    -- Pause / Quit buttons
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    if gameState == STATE_PLAYING then
        if imgui.Button('Pause##shmup_pause', { PANEL_W - 8, 22 }) then
            gameState = STATE_PAUSED
        end
    elseif gameState == STATE_PAUSED then
        if imgui.Button('Resume##shmup_resume', { PANEL_W - 8, 22 }) then
            gameState = STATE_PLAYING
        end
    end
    if imgui.Button('Quit##shmup_quit', { PANEL_W - 8, 22 }) then
        gameState = STATE_MENU
    end

    imgui.EndChild()
end

------------------------------------------------------------
-- ImGui: game + side panel layout
------------------------------------------------------------
local function renderPlayingOverlay()
    -- (control hints removed — they were clipped by the panel)
end

local function renderWindow()
    if not isOpen[1] then return end

    if not texture then
        if not createTexture() then return end
        initTilemap()
    end

    local pushed = ui and ui.pushWindowStyle and ui.pushWindowStyle() or 0

    imgui.SetNextWindowSize({ TEX_W + PANEL_W + 28, TEX_H + 60 }, ImGuiCond_FirstUseEver)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 4, 4 })

    if imgui.Begin('Crystal Wars##trove_shmup', isOpen, ImGuiWindowFlags_NoScrollbar) then

        if gameState == STATE_MENU then
            renderMenuOverlay()
        elseif gameState == STATE_PLAYING then
            -- Game area (left)
            imgui.BeginChild('##shmup_game', { TEX_W + 4, -1 }, false, ImGuiWindowFlags_NoScrollbar)

            -- Track mouse over game area
            local imgPos = { imgui.GetCursorScreenPos() }
            mouseInGame = false
            if imgui.IsWindowHovered() then
                local mx, my = imgui.GetMousePos()
                if type(mx) == 'table' then my = mx[2]; mx = mx[1] end
                local gx = mx - imgPos[1]
                local gy = my - imgPos[2]
                if gx >= 0 and gx < TEX_W and gy >= 0 and gy < TEX_H then
                    mouseInGame = true
                    mouseGameX  = gx
                    mouseGameY  = gy
                end
            end

            updatePlaying()
            renderGameFrame()

            local gameOrigin = { imgui.GetCursorPos() }
            if texHandle then
                imgui.Image(texHandle, { TEX_W, TEX_H })
            end
            -- Overlay icons (player, enemies, projectiles, drops)
            renderIconOverlays(gameOrigin[1], gameOrigin[2])
            renderDropIcons(gameOrigin[1], gameOrigin[2])

            -- Combine message flash (icon + name in a centered box)
            if player.combineMsg then
                local msg = player.combineMsg
                local alpha = math.min(1.0, msg.timer / 30)
                local tw = imgui.CalcTextSize(msg.text)
                local boxW = tw + 36  -- icon + padding
                local boxH = 28
                local bx = gameOrigin[1] + (TEX_W - boxW) / 2
                local by = gameOrigin[2] + TEX_H / 2 - boxH / 2

                -- Background box
                local dl = imgui.GetWindowDrawList()
                local sx, sy = imgui.GetWindowPos()
                dl:AddRectFilled(
                    { sx + bx - 4, sy + by - 2 },
                    { sx + bx + boxW + 4, sy + by + boxH + 2 },
                    imgui.GetColorU32({ 0.0, 0.0, 0.0, 0.7 * alpha }), 4)

                -- Icon
                if msg.itemId and renderIcon then
                    imgui.SetCursorPos({ bx, by + 2 })
                    imgui.PushStyleVar(ImGuiStyleVar_Alpha, alpha)
                    renderIcon(msg.itemId, 24)
                    imgui.PopStyleVar()
                end

                -- Text
                imgui.SetCursorPos({ bx + 28, by + 6 })
                local rc = RARITY_COL[msg.rarity] or { 1.0, 0.85, 0.30, 1.0 }
                imgui.TextColored({ rc[1], rc[2], rc[3], alpha }, msg.text)
            end

            renderPlayingOverlay()
            imgui.EndChild()

            -- Side panel (right)
            imgui.SameLine(0, 4)
            renderSidePanel()

        elseif gameState == STATE_PAUSED then
            renderGameFrame()
            imgui.BeginChild('##shmup_game', { TEX_W + 4, -1 }, false, ImGuiWindowFlags_NoScrollbar)
            local pauseOrigin = { imgui.GetCursorPos() }
            if texHandle then
                imgui.Image(texHandle, { TEX_W, TEX_H })
            end
            renderIconOverlays(pauseOrigin[1], pauseOrigin[2])
            renderDropIcons(pauseOrigin[1], pauseOrigin[2])
            renderPausedOverlay()
            imgui.EndChild()
            imgui.SameLine(0, 4)
            renderSidePanel()

        elseif gameState == STATE_GAMEOVER then
            renderGameFrame()
            imgui.BeginChild('##shmup_game', { TEX_W + 4, -1 }, false, ImGuiWindowFlags_NoScrollbar)
            if texHandle then
                imgui.Image(texHandle, { TEX_W, TEX_H })
            end
            renderGameOverOverlay()
            imgui.EndChild()
            imgui.SameLine(0, 4)
            renderSidePanel()
        end
    end
    imgui.End()

    imgui.PopStyleVar()
    if ui and ui.popWindowStyle then ui.popWindowStyle(pushed) end
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Crystal Wars',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Elemental vertical shooter',

    init = function(iconFn, itemResFn, uiModule, tooltipFn, fileIconFn, fileImageFn, iconHandleFn)
        renderIcon = iconFn
        ui = uiModule
        getIconHandle = iconHandleFn
    end,

    onUnload = function()
        destroyTexture()
    end,

    commands = {
        shmup = function(state, args)
            isOpen[1] = not isOpen[1]
        end,
    },

    window = {
        category = 'Games',
        isOpen = isOpen,
        label  = 'Crystal Wars',
        icon   = 8919,  -- Ifrit's Ear
        render = renderWindow,
    },
}
