--[[
* trove/plugins/codex.lua — Odious Codex plugin
*
* Floating window showing dynamis pop item collection status.
* Reads item Extra data from the Odious Codex item in inventory.
* Main view shows zone categories; drill into a zone to see items.
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared functions (injected by trove.lua via plugin.init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;

------------------------------------------------------------
-- Zone data — each zone has pops (spawner items) and drops (odious loot)
-- mask: A = bytes 0-3, B = bytes 4-7, C = bytes 8-11
------------------------------------------------------------
local ZONES = {
    {
        name = "Dynamis-San d'Oria",
        tint = { 0.20, 0.12, 0.12 }, -- red
        pops = {
            { name = "Barbaric Bijou",  id = 3353, mask = 'A', bit = 1,  spawns = "Overlord's Tombstone" },
            { name = "Chapter 1",       id = 3404, mask = 'A', bit = 11, spawns = "Arch Overlord (1/5)" },
            { name = "Chapter 2",       id = 3405, mask = 'A', bit = 12, spawns = "Arch Overlord (2/5)" },
            { name = "Chapter 3",       id = 3406, mask = 'A', bit = 13, spawns = "Arch Overlord (3/5)" },
            { name = "Chapter 4",       id = 3407, mask = 'A', bit = 14, spawns = "Arch Overlord (4/5)" },
            { name = "Chapter 5",       id = 3408, mask = 'A', bit = 15, spawns = "Arch Overlord (5/5)" },
        },
        drops = {
            { name = "Odious Scale",       id = 3380, mask = 'C', bit = 9,  spawns = "Bladeburner Rokgevok" },
            { name = "Odious Leather",     id = 3381, mask = 'C', bit = 10, spawns = "Steelshank Kratzvatz" },
            { name = "Odious Cryptex",     id = 3382, mask = 'C', bit = 11, spawns = "Bloodfist Voshgrosh" },
            { name = "Odious Strongbox",   id = 3383, mask = 'C', bit = 12, spawns = "Spellspear Djokvukk" },
        },
    },
    {
        name = "Dynamis-Bastok",
        tint = { 0.12, 0.14, 0.22 }, -- blue
        pops = {
            { name = "Steelwall Bijou", id = 3354, mask = 'A', bit = 2,  spawns = "Gu'Dha Effigy" },
            { name = "Chapter 6",       id = 3409, mask = 'A', bit = 16, spawns = "Arch Gu'Dha (1/5)" },
            { name = "Chapter 7",       id = 3410, mask = 'A', bit = 17, spawns = "Arch Gu'Dha (2/5)" },
            { name = "Chapter 8",       id = 3411, mask = 'A', bit = 18, spawns = "Arch Gu'Dha (3/5)" },
            { name = "Chapter 9",       id = 3412, mask = 'A', bit = 19, spawns = "Arch Gu'Dha (4/5)" },
            { name = "Chapter 10",      id = 3413, mask = 'A', bit = 20, spawns = "Arch Gu'Dha (5/5)" },
        },
        drops = {
            { name = "Odious Charm",       id = 3384, mask = 'C', bit = 5,  spawns = "Zo'Pha Forgesoul" },
            { name = "Odious Backscale",   id = 3385, mask = 'C', bit = 6,  spawns = "Ra'Gho Darkfount" },
            { name = "Odious Engraving",   id = 3386, mask = 'C', bit = 7,  spawns = "Va'Zhe Pummelsong" },
            { name = "Odious Letterbox",   id = 3387, mask = 'C', bit = 8,  spawns = "Bu'Bho Truesteel" },
        },
    },
    {
        name = "Dynamis-Windurst",
        tint = { 0.12, 0.18, 0.12 }, -- green
        pops = {
            { name = "Divine Bijou",    id = 3355, mask = 'A', bit = 3,  spawns = "Tzee Xicu Idol" },
            { name = "Chapter 11",      id = 3414, mask = 'A', bit = 21, spawns = "Arch Tzee Xicu (1/5)" },
            { name = "Chapter 12",      id = 3415, mask = 'A', bit = 22, spawns = "Arch Tzee Xicu (2/5)" },
            { name = "Chapter 13",      id = 3416, mask = 'A', bit = 23, spawns = "Arch Tzee Xicu (3/5)" },
            { name = "Chapter 14",      id = 3417, mask = 'A', bit = 24, spawns = "Arch Tzee Xicu (4/5)" },
            { name = "Chapter 15",      id = 3418, mask = 'A', bit = 25, spawns = "Arch Tzee Xicu (5/5)" },
        },
        drops = {
            { name = "Odious Necklace",    id = 3388, mask = 'C', bit = 1,  spawns = "Xuu Bhoqa the Enigma" },
            { name = "Odious Feather",     id = 3389, mask = 'C', bit = 2,  spawns = "Fuu Tzapo the Blessed" },
            { name = "Odious Holy Water",  id = 3390, mask = 'C', bit = 3,  spawns = "Naa Yixo the Stillrage" },
            { name = "Odious Quipu",       id = 3391, mask = 'C', bit = 4,  spawns = "Tee Zaksa the Ceaseless" },
        },
    },
    {
        name = "Dynamis-Jeuno",
        tint = { 0.20, 0.18, 0.10 }, -- yellow
        pops = {
            { name = "Roving Bijou",    id = 3356, mask = 'A', bit = 4,  spawns = "Goblin Golem" },
            { name = "Chapter 16",      id = 3419, mask = 'A', bit = 26, spawns = "Arch Goblin Golem (1/5)" },
            { name = "Chapter 17",      id = 3420, mask = 'A', bit = 27, spawns = "Arch Goblin Golem (2/5)" },
            { name = "Chapter 18",      id = 3421, mask = 'A', bit = 28, spawns = "Arch Goblin Golem (3/5)" },
            { name = "Chapter 19",      id = 3422, mask = 'A', bit = 29, spawns = "Arch Goblin Golem (4/5)" },
            { name = "Chapter 20",      id = 3423, mask = 'A', bit = 30, spawns = "Arch Goblin Golem (5/5)" },
        },
        drops = {
            { name = "Odious Cup",         id = 3392, mask = 'C', bit = 23, spawns = "Quicktrix Hexhands" },
            { name = "Odious Die",         id = 3393, mask = 'C', bit = 24, spawns = "Feralox Honeylips" },
            { name = "Odious Mask",        id = 3394, mask = 'C', bit = 25, spawns = "Scourquix Scaleskin" },
            { name = "Odious Grenade",     id = 3395, mask = 'C', bit = 26, spawns = "Wilywox Tenderpalm" },
        },
    },
    {
        name = "Dynamis-Beaucedine",
        tint = { 0.12, 0.16, 0.22 }, -- light blue
        pops = {
            { name = "Leering Bijou",   id = 3357, mask = 'A', bit = 5,  spawns = "Angra Mainyu" },
            { name = "Chapter 21",      id = 3424, mask = 'A', bit = 31, spawns = "Arch Angra Mainyu (1/5)" },
            { name = "Chapter 22",      id = 3425, mask = 'A', bit = 32, spawns = "Arch Angra Mainyu (2/5)" },
            { name = "Chapter 23",      id = 3426, mask = 'B', bit = 1,  spawns = "Arch Angra Mainyu (3/5)" },
            { name = "Chapter 24",      id = 3427, mask = 'B', bit = 2,  spawns = "Arch Angra Mainyu (4/5)" },
            { name = "Chapter 25",      id = 3428, mask = 'B', bit = 3,  spawns = "Arch Angra Mainyu (5/5)" },
        },
        drops = {
            { name = "Odious Talisman",        id = 3396, mask = 'C', bit = 27, spawns = "Taquede" },
            { name = "Odious Bell",            id = 3397, mask = 'C', bit = 28, spawns = "Pignonpausard" },
            { name = "Odious Tree Root",       id = 3398, mask = 'C', bit = 29, spawns = "Hitaume" },
            { name = "Odious Mirror",          id = 3399, mask = 'C', bit = 30, spawns = "Cavanneche" },
            { name = "Despot's Parchment",     id = 3359, mask = 'C', bit = 31, spawns = "Goublefaupe" },
            { name = "Sadist's Parchment",     id = 3360, mask = 'C', bit = 32, spawns = "Quiebitiel" },
            { name = "Villain's Parchment",    id = 3361, mask = 'D', bit = 1,  spawns = "Mildaunegeux" },
            { name = "Deluder's Parchment",    id = 3362, mask = 'D', bit = 2,  spawns = "Velosareon" },
            { name = "Traitor's Parchment",    id = 3363, mask = 'D', bit = 3,  spawns = "Dagourmarche" },
        },
    },
    {
        name = "Dynamis-Xarcabard",
        tint = { 0.09, 0.10, 0.18 }, -- dark blue
        pops = {
            { name = "Shrouded Bijou",  id = 3358, mask = 'A', bit = 6,  spawns = "Dynamis Lord" },
            { name = "Chapter 26",      id = 3429, mask = 'B', bit = 4,  spawns = "Arch Dynamis Lord (1/5)" },
            { name = "Chapter 27",      id = 3430, mask = 'B', bit = 5,  spawns = "Arch Dynamis Lord (2/5)" },
            { name = "Chapter 28",      id = 3431, mask = 'B', bit = 6,  spawns = "Arch Dynamis Lord (3/5)" },
            { name = "Chapter 29",      id = 3432, mask = 'B', bit = 7,  spawns = "Arch Dynamis Lord (4/5)" },
            { name = "Chapter 30",      id = 3433, mask = 'B', bit = 8,  spawns = "Arch Dynamis Lord (5/5)" },
        },
        drops = {
            { name = "Odious Skull",       id = 3400, mask = 'D', bit = 4,  spawns = "Duke Haures" },
            { name = "Odious Horn",        id = 3401, mask = 'D', bit = 5,  spawns = "Marquis Caim" },
            { name = "Odious Blood",       id = 3402, mask = 'D', bit = 6,  spawns = "Baron Avnas" },
            { name = "Odious Pen",         id = 3403, mask = 'D', bit = 7,  spawns = "Count Haagenti" },
            { name = "Mystic Goad",        id = 3364, mask = 'D', bit = 8,  spawns = "Animated Knuckles" },
            { name = "Ornate Goad",        id = 3365, mask = 'D', bit = 9,  spawns = "Animated Dagger" },
            { name = "Holy Goad",          id = 3366, mask = 'D', bit = 10, spawns = "Animated Longsword" },
            { name = "Intricate Goad",     id = 3367, mask = 'D', bit = 11, spawns = "Animated Claymore" },
            { name = "Runaeic Goad",       id = 3368, mask = 'D', bit = 12, spawns = "Animated Tabar" },
            { name = "Seraphic Goad",      id = 3369, mask = 'D', bit = 13, spawns = "Animated Great Axe" },
            { name = "Tenebrous Goad",     id = 3370, mask = 'D', bit = 14, spawns = "Animated Scythe" },
            { name = "Stellar Goad",       id = 3371, mask = 'D', bit = 15, spawns = "Animated Spear" },
            { name = "Demoniac Goad",      id = 3372, mask = 'D', bit = 16, spawns = "Animated Kunai" },
            { name = "Divine Goad",        id = 3373, mask = 'D', bit = 17, spawns = "Animated Tachi" },
            { name = "Heavenly Goad",      id = 3374, mask = 'D', bit = 18, spawns = "Animated Hammer" },
            { name = "Celestial Goad",     id = 3375, mask = 'D', bit = 19, spawns = "Animated Staff" },
            { name = "Snarled Goad",       id = 3376, mask = 'D', bit = 20, spawns = "Animated Longbow" },
            { name = "Ethereal Goad",      id = 3377, mask = 'D', bit = 21, spawns = "Animated Gun" },
            { name = "Mysterial Goad",     id = 3378, mask = 'D', bit = 22, spawns = "Animated Horn" },
            { name = "Supernal Goad",      id = 3379, mask = 'D', bit = 23, spawns = "Animated Shield" },
        },
    },
    {
        name = "Dynamis-Valkurm",
        tint = { 0.16, 0.12, 0.20 }, -- purple
        pops = {
            { name = "Creepers Juju",   id = 3456, mask = 'A', bit = 7,  spawns = "Cirrate Christelle" },
            { name = "Tome II Ch.1",    id = 3470, mask = 'B', bit = 9,  spawns = "Arch Christelle (1/4)" },
            { name = "Tome II Ch.2",    id = 3471, mask = 'B', bit = 10, spawns = "Arch Christelle (2/4)" },
            { name = "Tome II Ch.3",    id = 3472, mask = 'B', bit = 11, spawns = "Arch Christelle (3/4)" },
            { name = "Tome II Ch.4",    id = 3473, mask = 'B', bit = 12, spawns = "Arch Christelle (4/4)" },
        },
        drops = {
            { name = "Nightmare Bud",     id = 3461, mask = 'C', bit = 13, spawns = "Lost Nant'ina" },
            { name = "Nightmare Log",     id = 3460, mask = 'C', bit = 14, spawns = "Lost Fairy Ring" },
            { name = "Nightmare Water",   id = 3462, mask = 'C', bit = 15, spawns = "Lost Stcemqestcint" },
        },
    },
    {
        name = "Dynamis-Buburimu",
        tint = { 0.16, 0.12, 0.20 }, -- purple
        pops = {
            { name = "Revelatory Juju", id = 3457, mask = 'A', bit = 8,  spawns = "Apocalyptic Beast" },
            { name = "Tome II Ch.5",    id = 3474, mask = 'B', bit = 13, spawns = "Arch Apoc. Beast (1/5)" },
            { name = "Tome II Ch.6",    id = 3475, mask = 'B', bit = 14, spawns = "Arch Apoc. Beast (2/5)" },
            { name = "Tome II Ch.7",    id = 3476, mask = 'B', bit = 15, spawns = "Arch Apoc. Beast (3/5)" },
            { name = "Tome II Ch.8",    id = 3477, mask = 'B', bit = 16, spawns = "Arch Apoc. Beast (4/5)" },
            { name = "Tome II Ch.9",    id = 3478, mask = 'B', bit = 17, spawns = "Arch Apoc. Beast (5/5)" },
        },
        drops = {
            { name = "Nightmare Shank",   id = 3463, mask = 'C', bit = 16, spawns = "Lost Stihi" },
            { name = "Nightmare Loin",    id = 3465, mask = 'C', bit = 17, spawns = "Lost Alklha" },
            { name = "Nightmare Roast",   id = 3464, mask = 'C', bit = 18, spawns = "Lost Barong" },
            { name = "Nightmare Chop",    id = 3466, mask = 'C', bit = 19, spawns = "Lost Aitvaras" },
        },
    },
    {
        name = "Dynamis-Qufim",
        tint = { 0.16, 0.12, 0.20 }, -- purple
        pops = {
            { name = "Undying Juju",    id = 3458, mask = 'A', bit = 9,  spawns = "Antaeus" },
            { name = "Tome II Ch.10",   id = 3479, mask = 'B', bit = 18, spawns = "Arch Antaeus (1/4)" },
            { name = "Tome II Ch.11",   id = 3480, mask = 'B', bit = 19, spawns = "Arch Antaeus (2/4)" },
            { name = "Tome II Ch.12",   id = 3481, mask = 'B', bit = 20, spawns = "Arch Antaeus (3/4)" },
            { name = "Tome II Ch.13",   id = 3482, mask = 'B', bit = 21, spawns = "Arch Antaeus (4/4)" },
        },
        drops = {
            { name = "Nightmare Shard",   id = 3469, mask = 'C', bit = 20, spawns = "Lost Suttung" },
            { name = "Nightmare Shell",   id = 3467, mask = 'C', bit = 21, spawns = "Lost Scolopendra" },
            { name = "Nightmare Blood",   id = 3468, mask = 'C', bit = 22, spawns = "Lost Stringes" },
        },
    },
    {
        name = "Dynamis-Tavnazia",
        tint = { 0.20, 0.15, 0.10 }, -- orange
        pops = {
            { name = "Heralds Juju",    id = 3459, mask = 'A', bit = 10, spawns = "Diabolos" },
            { name = "Tome II Ch.14",   id = 3483, mask = 'B', bit = 22, spawns = "Arch Diabolos (1/4)" },
            { name = "Tome II Ch.15",   id = 3484, mask = 'B', bit = 23, spawns = "Arch Diabolos (2/4)" },
            { name = "Tome II Ch.16",   id = 3485, mask = 'B', bit = 24, spawns = "Arch Diabolos (3/4)" },
            { name = "Tome II Ch.17",   id = 3486, mask = 'B', bit = 25, spawns = "Arch Diabolos (4/4)" },
        },
        drops = {},
    },
};

------------------------------------------------------------
-- Inventory scan
------------------------------------------------------------
local CODEX_ID = 30840;

local CONTAINERS = {
    { id = 0 }, { id = 1 }, { id = 2 }, { id = 4 }, { id = 5 },
    { id = 6 }, { id = 7 }, { id = 8 }, { id = 9 }, { id = 10 },
    { id = 11 }, { id = 12 }, { id = 13 }, { id = 14 }, { id = 15 }, { id = 16 },
};

local maskA    = 0;
local maskB    = 0;
local maskC    = 0;
local maskD    = 0;
local hasCodex = false;
local lastScan = 0;

local function checkBit(mask, pos)
    return bit.band(mask, bit.lshift(1, pos)) ~= 0;
end

local function getMask(key)
    if key == 'B' then return maskB; end
    if key == 'C' then return maskC; end
    if key == 'D' then return maskD; end
    return maskA;
end

local function readUint32(extra, offset)
    local b0 = struct.unpack('B', extra, offset + 1);
    local b1 = struct.unpack('B', extra, offset + 2);
    local b2 = struct.unpack('B', extra, offset + 3);
    local b3 = struct.unpack('B', extra, offset + 4);
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
end

local function scanCodex()
    local now = os.clock();
    if now - lastScan < 2 then return; end
    lastScan = now;

    maskA    = 0;
    maskB    = 0;
    maskC    = 0;
    maskD    = 0;
    hasCodex = false;

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return; end
    for _, c in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(c.id);
        if max ~= nil and max > 0 then
        for j = 0, max do
            local ok, item = pcall(function() return inventory:GetContainerItem(c.id, j); end);
            if not ok or item == nil then break; end
            if item.Id ~= 0 and item.Id ~= 65535 and item.Id == CODEX_ID then
                hasCodex = true;
                local extra = item.Extra;
                maskA = readUint32(extra, 0);
                maskB = readUint32(extra, 4);
                maskC = readUint32(extra, 8);
                maskD = readUint32(extra, 12);
                return;
            end
        end
        end
    end
end

------------------------------------------------------------
-- Layout
------------------------------------------------------------
local ICON_SIZE = 24;
local CELL_PAD  = 3;
local ROW_H     = ICON_SIZE + CELL_PAD + 2;

local cellColorCache = nil;
local cellColorVersion = -1;

local function getCellColors()
    local v = ui.getThemeVersion();
    if cellColorCache and cellColorVersion == v then return cellColorCache; end
    local base = ui.color('childBg');
    cellColorCache = {
        ownedBg = { 0.18, 0.38, 0.18, 1.0 },
        cellBg  = { base[1], base[2], base[3], 1.0 },
    };
    cellColorVersion = v;
    return cellColorCache;
end

------------------------------------------------------------
-- Render helpers
------------------------------------------------------------
local function renderTooltipFn(entry, isOwned)
    ui.tooltip(function()
        renderIcon(entry.id, 32);
        imgui.SameLine(0, 6);
        imgui.BeginGroup();
        ui.colored(entry.name, 'white');
        if isOwned then
            ui.colored('  Obtained', 'green');
        end
        imgui.EndGroup();
        if entry.spawns then
            imgui.Separator();
            ui.colored('Spawns: ' .. entry.spawns, 'header');
        end
    end);
end

local function renderRow(entry, showSpawns)
    local isOwned = checkBit(getMask(entry.mask), entry.bit);
    local cc = getCellColors();
    local bgCol = isOwned and cc.ownedBg or cc.cellBg;

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
    local cellId = string.format('##cd_%d', entry.id);
    imgui.BeginChild(cellId, { -1, ROW_H }, true, bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

    imgui.SetCursorPos({ CELL_PAD, CELL_PAD });
    if not renderIcon(entry.id, ICON_SIZE) then
        imgui.Dummy({ ICON_SIZE, ICON_SIZE });
    end

    imgui.SameLine(0, 6);
    imgui.SetCursorPosY(CELL_PAD + (ICON_SIZE - 14) / 2);
    if isOwned then
        ui.colored(entry.name, 'green');
    else
        ui.colored(entry.name, 'dimmed');
    end

    if showSpawns ~= false and entry.spawns then
        local spawnW = imgui.CalcTextSize(entry.spawns);
        imgui.SameLine(imgui.GetWindowWidth() - spawnW - 8);
        ui.dim(entry.spawns);
    end

    imgui.EndChild();
    imgui.PopStyleColor();

    if imgui.IsItemHovered() then
        renderTooltipFn(entry, isOwned);
    end
end

------------------------------------------------------------
-- Count helpers
------------------------------------------------------------
local function countItems(items)
    local owned = 0;
    for _, item in ipairs(items) do
        if checkBit(getMask(item.mask), item.bit) then owned = owned + 1; end
    end
    return owned;
end

local function countZoneOwned(zone)
    return countItems(zone.pops) + countItems(zone.drops or {});
end

local function countZoneTotal(zone)
    return #zone.pops + #(zone.drops or {});
end

local function countTotalOwned()
    local owned, total = 0, 0;
    for _, zone in ipairs(ZONES) do
        owned = owned + countZoneOwned(zone);
        total = total + countZoneTotal(zone);
    end
    return owned, total;
end

------------------------------------------------------------
-- Window state
------------------------------------------------------------
local isOpen       = { false };
local selectedZone = nil;

------------------------------------------------------------
-- Render: Zone list (main view)
------------------------------------------------------------
local function renderZoneList()
    imgui.BeginChild('##cd_zones', { -1, -1 }, false);
    for i, zone in ipairs(ZONES) do
        local zoneOwned = countZoneOwned(zone);
        local zoneTotal = countZoneTotal(zone);
        local subtitle  = string.format('%d/%d collected', zoneOwned, zoneTotal);
        local tint      = zone.tint or { 0.14, 0.12, 0.20 };

        local btnId    = string.format('##cdzone_%d', i);
        local rowWidth = imgui.GetContentRegionAvail();
        local bgColor  = { tint[1], tint[2], tint[3], 0.85 };
        local barColor = { tint[1] * 2.0, tint[2] * 2.0, tint[3] * 2.0, 1.0 };

        imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
        imgui.BeginChild(btnId, { rowWidth, 34 }, false);

        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();
        dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 34 }, imgui.GetColorU32(barColor));

        imgui.SetCursorPosY(0);
        local clicked = imgui.Selectable(string.format('##cdsel_%d', i), false,
            ImGuiSelectableFlags_SpanAllColumns, { 0, 34 });

        dl:AddText({ wx + 10, wy + 5 }, imgui.GetColorU32(ui.color('white')), zone.name);
        dl:AddText({ wx + 10, wy + 19 }, imgui.GetColorU32(ui.color('dimmed')), subtitle);

        imgui.EndChild();
        imgui.PopStyleColor(1);

        if clicked then
            selectedZone = i;
        end

        imgui.Spacing();
    end
    imgui.EndChild();
end

------------------------------------------------------------
-- Render: Zone detail (drill-down, 2-column)
------------------------------------------------------------
local function renderZoneDetail()
    local zone = ZONES[selectedZone];

    if ui.button('< Back', 55, 22) then
        selectedZone = nil;
        return;
    end
    imgui.SameLine();
    ui.colored(zone.name, 'header');
    imgui.SameLine();
    ui.dim(string.format('(%d/%d)', countZoneOwned(zone), countZoneTotal(zone)));
    imgui.Separator();
    imgui.Spacing();

    local drops = zone.drops or {};
    local hasTwoColumns = #drops > 0;

    if hasTwoColumns then
        local winW = imgui.GetWindowWidth();
        local colW = (winW - 24) / 2;

        -- Left column: Pop items (bijou/juju + chapters)
        imgui.BeginChild('##cd_left', { colW, -1 }, false);
        local popOwned = countItems(zone.pops);
        ui.colored(string.format('Pop Items (%d/%d)', popOwned, #zone.pops), 'header');
        imgui.Separator();
        imgui.Spacing();
        for _, pop in ipairs(zone.pops) do
            renderRow(pop, false);
        end
        imgui.EndChild();

        imgui.SameLine(0, 8);

        -- Right column: Zone drops (odious/nightmare)
        imgui.BeginChild('##cd_right', { colW, -1 }, false);
        local dropOwned = countItems(drops);
        ui.colored(string.format('Zone Drops (%d/%d)', dropOwned, #drops), 'header');
        imgui.Separator();
        imgui.Spacing();
        for _, drop in ipairs(drops) do
            renderRow(drop, false);
        end
        imgui.EndChild();
    else
        -- Single column: just pop items
        imgui.BeginChild('##cd_single', { -1, -1 }, false);
        local popOwned = countItems(zone.pops);
        ui.colored(string.format('Pop Items (%d/%d)', popOwned, #zone.pops), 'header');
        imgui.Separator();
        imgui.Spacing();
        for _, pop in ipairs(zone.pops) do
            renderRow(pop, false);
        end
        imgui.EndChild();
    end
end

------------------------------------------------------------
-- Main render
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    scanCodex();

    local totalOwned, totalItems = countTotalOwned();
    local title = string.format('Odious Codex [%d/%d]###trove_codex', totalOwned, totalItems);

    imgui.SetNextWindowSize({ 560, 450 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 460, 300 }, { 750, 900 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin(title, isOpen, ImGuiWindowFlags_NoScrollbar) then
        local _bgPop = ui.renderBackground();
        if not hasCodex then
            ui.dim('No Odious Codex found.');
        elseif selectedZone then
            renderZoneDetail();
        else
            renderZoneList();
        end
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(winColors);
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Odious Codex',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Dynamis pop item collection tracker',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
    end,

    window = {
        category = 'Utility',
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Odious Codex',
        icon    = 30840,
    },
};
