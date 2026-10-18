-- Items: what the game itself knows about them (names, descriptions, stats and icons, straight from its DATs through the
-- resource manager) and the house's catalogue (which items it lists, in which category; generated from the server's
-- item table). Nothing here touches the network.
local ffi = require('ffi')
local U = require('ui')
local CATALOGUE = require('catalogue')

local I = {}

pcall(ffi.cdef, [[
typedef struct { uint16_t AbilityId; int8_t Level; uint8_t Unknown0000; } ah_IMonAbility;
typedef struct {
    uint32_t Id; uint16_t Flags; uint16_t StackSize; uint16_t Type; uint16_t ResourceId; uint16_t Targets;
    uint16_t Level; uint16_t Slots; uint16_t Races; uint32_t Jobs; uint16_t SuperiorLevel; uint16_t ShieldSize;
    uint8_t MaxCharges; uint16_t CastTime; uint16_t CastDelay; uint32_t RecastDelay; uint16_t BaseItemId;
    uint16_t ItemLevel; uint16_t Damage; uint16_t Delay; uint16_t DPS; uint8_t Skill; uint8_t JugSize;
    uint32_t WeaponUnknown0000; uint8_t Range; uint8_t AreaRange; uint8_t AreaShapeType; uint8_t AreaCursorTargetType;
    uint16_t Element; uint32_t Storage; uint32_t AttachmentFlags;
    uint16_t InstinctCost;
    uint16_t MonstrosityId; char MonstrosityName[0x20]; uint8_t MonstrosityData[0x0A];
    ah_IMonAbility MonstrosityAbilities[0x10];
    uint16_t PuppetSlotId; uint32_t PuppetElements;
    uint8_t SlipData[0x46];
    uint16_t UsableData0000; uint32_t UsableData0001; uint32_t UsableData0002;
    uint32_t Article;
    const char* Name[3]; const char* Description[3]; const char* LogNameSingular[3]; const char* LogNamePlural[3];
    uint32_t ImageSize; uint8_t ImageType; uint8_t ImageName[0x10]; uint8_t Bitmap[0x980];
} ah_IItem;
]])

-- the resource manager's GetItemById (vtable slot 5), reached once
local get_item = nil
local function resources()
    if get_item ~= nil then return get_item end
    local res = vana.ashita.object('resources')
    if res == nil then return nil end
    local ptr = ffi.cast('void*', res)
    local vtable = ffi.cast('void***', ptr)[0]
    local fn = ffi.cast('void* (__thiscall *)(void*, uint32_t)', vtable[5])
    get_item = function (id)
        local p = fn(ptr, id)
        if p == nil then return nil end
        return ffi.cast('ah_IItem*', p)
    end
    return get_item
end

local function cstr(p) return p ~= nil and ffi.string(p) or '' end

-------------------------------------------------------------------------------
-- An item's record, read once and kept
-------------------------------------------------------------------------------

local records = {}

function I.get(id)
    local r = records[id]
    if r ~= nil then return r end
    local get = resources()
    local it = get and get(id) or nil
    if it == nil then
        r = { id = id, name = 'Item ' .. id, desc = '', level = 0, ilevel = 0, jobs = 0, slots = 0, races = 0, stack = 1, flags = 0, type = 0, dmg = 0, delay = 0, missing = true }
    else
        local name = cstr(it.Name[0])
        if name == '' then name = cstr(it.Name[2]) end
        local desc = cstr(it.Description[0])
        if desc == '' then desc = cstr(it.Description[2]) end
        desc = desc:gsub('\n+$', '')
        r = {
            id = id, name = name, desc = desc, level = it.Level, ilevel = it.ItemLevel, jobs = it.Jobs, slots = it.Slots,
            races = it.Races, stack = math.max(1, it.StackSize), flags = it.Flags, type = it.Type, dmg = it.Damage,
            delay = it.Delay, image_size = tonumber(it.ImageSize) or 0,
        }
    end
    records[id] = r
    return r
end

function I.name(id) return I.get(id).name end

-------------------------------------------------------------------------------
-- Icons: the game's own, made into textures as they're first drawn; the least recently used go when there are many
-------------------------------------------------------------------------------

local icons, icon_order, icon_count = {}, {}, 0
local ICON_LIMIT = 300
local tick = 0

function I.icon(id)
    tick = tick + 1
    local e = icons[id]
    if e ~= nil then
        e.used = tick
        return e.tex
    end
    local get = resources()
    local it = get and get(id) or nil
    local tex = nil
    if it ~= nil then
        local size = math.min(tonumber(it.ImageSize) or 0, 0x980)
        if size > 0 then
            tex = U.texture_from_memory('icon' .. id, ffi.string(it.Bitmap, size))
        end
    end
    icons[id] = { tex = tex, used = tick }
    icon_count = icon_count + 1
    if icon_count > ICON_LIMIT then
        -- drop the oldest third
        local list = {}
        for k, v in pairs(icons) do list[#list + 1] = { k, v.used } end
        table.sort(list, function (a, b) return a[2] < b[2] end)
        for i = 1, math.floor(#list / 3) do
            U.release_texture('icon' .. list[i][1])
            icons[list[i][1]] = nil
            icon_count = icon_count - 1
        end
    end
    return tex
end

function I.release_icons()
    for id in pairs(icons) do U.release_texture('icon' .. id) end
    icons, icon_count = {}, 0
end

-------------------------------------------------------------------------------
-- The catalogue: categories, their items, and a name search
-------------------------------------------------------------------------------

I.CATEGORY_NAME = {
    [1] = 'Hand-to-Hand', [2] = 'Daggers', [3] = 'Swords', [4] = 'Great Swords', [5] = 'Axes', [6] = 'Great Axes',
    [7] = 'Scythes', [8] = 'Polearms', [9] = 'Katana', [10] = 'Great Katana', [11] = 'Clubs', [12] = 'Staves',
    [13] = 'Ranged', [14] = 'Instruments', [15] = 'Ammo & Misc', [16] = 'Shields', [17] = 'Head', [18] = 'Body',
    [19] = 'Hands', [20] = 'Legs', [21] = 'Feet', [22] = 'Neck', [23] = 'Waist', [24] = 'Earrings', [25] = 'Rings',
    [26] = 'Back', [28] = 'White Magic', [29] = 'Black Magic', [30] = 'Summoning', [31] = 'Ninjutsu', [32] = 'Songs',
    [33] = 'Medicines', [34] = 'Furnishings', [35] = 'Crystals', [36] = 'Cards', [37] = 'Cursed Items',
    [38] = 'Smithing', [39] = 'Goldsmithing', [40] = 'Clothcraft', [41] = 'Leathercraft', [42] = 'Bonecraft',
    [43] = 'Woodworking', [44] = 'Alchemy', [45] = 'Geomancy', [46] = 'Misc.', [47] = 'Fishing Gear', [48] = 'Pet Items',
    [49] = 'Ninja Tools', [50] = 'Beast-made', [51] = 'Fish', [52] = 'Meat & Eggs', [53] = 'Seafood',
    [54] = 'Vegetables', [55] = 'Soups', [56] = 'Breads & Rice', [57] = 'Sweets', [58] = 'Drinks', [59] = 'Ingredients',
    [60] = 'Dice', [61] = 'Automaton', [62] = 'Grips', [63] = 'Alchemy 2', [64] = 'Misc. 2', [65] = 'Misc. 3',
    [99] = 'Special', [255] = 'Other',
}

-- the sidebar's groups, in the order the house shows them
I.GROUPS = {
    { id = 'weapons', name = 'Weapons', icon = 'khanda', cats = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
    { id = 'armor', name = 'Armor', icon = 'shield-halved', cats = { 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 } },
    { id = 'scrolls', name = 'Scrolls', icon = 'scroll', cats = { 28, 29, 30, 31, 32 } },
    { id = 'items', name = 'Items', icon = 'flask', cats = { 33, 34, 35, 36, 37, 47, 48, 49, 50, 60, 61, 62 } },
    { id = 'materials', name = 'Materials', icon = 'gem', cats = { 38, 39, 40, 41, 42, 43, 44, 45, 63 } },
    { id = 'food', name = 'Food', icon = 'utensils', cats = { 51, 52, 53, 54, 55, 56, 57, 58, 59 } },
    { id = 'others', name = 'Others', icon = 'box', cats = { 46, 64, 65, 99, 255 } },
}

I.rows = {}          -- id -> { id, category, stack, flags, level, jobs, slot }
local by_cat = {}    -- category -> ids
for _, row in ipairs(CATALOGUE) do
    local r = { id = row[1], category = row[2], stack = row[3], flags = row[4], level = row[5], jobs = row[6], slot = row[7] }
    I.rows[r.id] = r
    by_cat[r.category] = by_cat[r.category] or {}
    table.insert(by_cat[r.category], r.id)
end

local sorted_cats = {}
-- a category's items, by name
function I.category(cat)
    if sorted_cats[cat] then return sorted_cats[cat] end
    local ids = by_cat[cat] or {}
    table.sort(ids, function (a, b) return I.name(a) < I.name(b) end)
    sorted_cats[cat] = ids
    return ids
end

function I.category_of(id)
    local r = I.rows[id]
    return r and r.category or nil
end

function I.group_of(cat)
    for _, g in ipairs(I.GROUPS) do
        for _, c in ipairs(g.cats) do if c == cat then return g end end
    end
    return I.GROUPS[#I.GROUPS]
end

-- every listed item whose name contains the words, best matches first; built on the first search
local index = nil
function I.search(query, limit)
    query = (query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if query == '' then return {} end
    if index == nil then
        index = {}
        for id in pairs(I.rows) do index[#index + 1] = { id = id, name = I.name(id):lower() } end
    end
    local words = {}
    for w in query:gmatch('%S+') do words[#words + 1] = w end
    local hits = {}
    for _, e in ipairs(index) do
        local ok, rank = true, 0
        for _, w in ipairs(words) do
            local at = e.name:find(w, 1, true)
            if at == nil then ok = false break end
            rank = rank + (at == 1 and 0 or 1)
        end
        if ok then hits[#hits + 1] = { id = e.id, rank = rank, name = e.name } end
    end
    table.sort(hits, function (a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.name < b.name end)
    local out = {}
    for i = 1, math.min(#hits, limit or 60) do out[i] = hits[i].id end
    return out, #hits
end

-- the jobs a mask names, in job order
function I.jobs_of(mask)
    local bit = require('bit')
    local list = {}
    for j = 1, 22 do if bit.band(mask, bit.lshift(1, j)) ~= 0 then list[#list + 1] = j end end
    return list
end

function I.all_jobs(mask)
    return mask == 0x7FFFFE or mask == 0xFFFFFFFE or mask == 0xFFFE
end

-- a short line of what equips it: "Lv 75 · PLD NIN RUN" / "All jobs" / ""
function I.jobs_line(id)
    local r = I.get(id)
    if r.level == 0 and r.jobs == 0 then return '' end
    local jobs = I.jobs_of(r.jobs)
    local who
    if #jobs == 0 then who = ''
    elseif #jobs >= 22 or I.all_jobs(r.jobs) then who = 'All jobs'
    elseif #jobs > 8 then who = #jobs .. ' jobs'
    else
        local names = {}
        for _, j in ipairs(jobs) do names[#names + 1] = U.JOBS[j] end
        who = table.concat(names, ' ')
    end
    if r.level > 0 then return 'Lv ' .. r.level .. (who ~= '' and ('  ·  ' .. who) or '') end
    return who
end

return I
