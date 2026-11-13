--[[
* trove/plugins/vnm.lua — VNM Armor plugin
*
* Floating window showing VNM armor collection progress.
* Monitors chat for Populox zone messages and Active Venture Seals.
* Highlights items dropping in announced zones.
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared functions (injected by trove.lua via plugin.init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;

------------------------------------------------------------
-- VNM Armor Data
------------------------------------------------------------
local SETS = {
    {
        name   = 'Ares',
        crest  = 'Mountain',
        color  = { 0.90, 0.55, 0.20, 1.0 },
        jobs   = 'WAR DRK PLD DRG RUN',
        final  = { head = 16084, body = 14546, hands = 14961, legs = 15625, feet = 15711 },
        tiers  = {
            { prefix = "Enyo's",   head = 16085, body = 14547, hands = 14962, legs = 15626, feet = 15712 },
            { prefix = "Phobos's", head = 16086, body = 14548, hands = 14963, legs = 15627, feet = 15713 },
            { prefix = "Deimos's", head = 16087, body = 14549, hands = 14964, legs = 15628, feet = 15714 },
        },
    },
    {
        name   = 'Skadi',
        crest  = 'Forest',
        color  = { 0.20, 0.75, 0.20, 1.0 },
        jobs   = 'THF RNG BST COR DNC',
        final  = { head = 16088, body = 14550, hands = 14965, legs = 15629, feet = 15715 },
        tiers  = {
            { prefix = "Njord's", head = 16089, body = 14551, hands = 14966, legs = 15630, feet = 15716 },
            { prefix = "Freyr's", head = 16090, body = 14552, hands = 14967, legs = 15631, feet = 15717 },
            { prefix = "Freya's", head = 16091, body = 14553, hands = 14968, legs = 15632, feet = 15718 },
        },
    },
    {
        name   = 'Usukane',
        crest  = 'Desert',
        color  = { 0.85, 0.75, 0.30, 1.0 },
        jobs   = 'MNK NIN SAM PUP',
        final  = { head = 16092, body = 14554, hands = 14969, legs = 15633, feet = 15719 },
        tiers  = {
            { prefix = 'Hoshikazu',  head = 16093, body = 14555, hands = 14970, legs = 15634, feet = 15720 },
            { prefix = 'Tsukikazu',  head = 16094, body = 14556, hands = 14971, legs = 15635, feet = 15721 },
            { prefix = 'Hikazu',     head = 16095, body = 14557, hands = 14972, legs = 15636, feet = 15722 },
        },
    },
    {
        name   = 'Marduk',
        crest  = 'Ocean',
        color  = { 0.30, 0.55, 0.90, 1.0 },
        jobs   = 'WHM BRD SMN SCH',
        final  = { head = 16096, body = 14558, hands = 14973, legs = 15637, feet = 15723 },
        tiers  = {
            { prefix = "Anu's",    head = 16097, body = 14559, hands = 14974, legs = 15638, feet = 15724 },
            { prefix = "Ea's",     head = 16098, body = 14560, hands = 14975, legs = 15639, feet = 15725 },
            { prefix = "Enlil's",  head = 16099, body = 14561, hands = 14976, legs = 15640, feet = 15726 },
        },
    },
    {
        name   = 'Morrigan',
        crest  = 'Tundra',
        color  = { 0.65, 0.45, 0.80, 1.0 },
        jobs   = 'BLM RDM BLU GEO',
        final  = { head = 16100, body = 14562, hands = 14977, legs = 15641, feet = 15727 },
        tiers  = {
            { prefix = "Nemain's", head = 16101, body = 14563, hands = 14978, legs = 15642, feet = 15728 },
            { prefix = "Bodb's",   head = 16102, body = 14564, hands = 14979, legs = 15643, feet = 15729 },
            { prefix = "Macha's",  head = 16103, body = 14565, hands = 14980, legs = 15644, feet = 15730 },
        },
    },
};

local SLOTS      = { 'head', 'body', 'hands', 'legs', 'feet' };
local SLOT_LABELS = { 'Head', 'Body', 'Hands', 'Legs', 'Feet' };
local TIER_LABELS = { 'T1', 'T2', 'T3' };

local HNM_DROPS = {
    [1] = { head = 'Cerberus',  body = 'Tiamat',      hands = 'Nidhogg',       legs = 'Medusa',                feet = 'Escha Suzaku' },
    [2] = { head = 'Hydra',     body = 'Jormungand',   hands = 'Aspidochelone', legs = 'Gulool Ja Ja',         feet = 'Escha Seiryu' },
    [3] = { head = 'Khimaira',  body = 'Vrtra',        hands = 'Escha Genbu',   legs = 'Gurfurlur the Menacing', feet = 'Escha Byakko' },
};

------------------------------------------------------------
-- Zone drop data
------------------------------------------------------------
local ZONE_DROPS = {
    { zone = 'Valkurm Dunes',            tier = 1, slot = 'head',  crest = 'Ocean'    },
    { zone = 'Buburimu Peninsula',        tier = 1, slot = 'body',  crest = 'Mountain' },
    { zone = 'Maze of Shakhrami',         tier = 1, slot = 'hands', crest = 'Tundra'   },
    { zone = 'Jugner Forest',             tier = 1, slot = 'legs',  crest = 'Forest'   },
    { zone = 'Pashhow Marshlands',        tier = 1, slot = 'feet',  crest = 'Ocean'    },
    { zone = 'Meriphataud Mountains',     tier = 1, slot = 'hands', crest = 'Mountain' },
    { zone = 'Korroloka Tunnel',          tier = 2, slot = 'body',  crest = 'Mountain' },
    { zone = 'Batallia Downs',            tier = 1, slot = 'legs',  crest = 'Desert'   },
    { zone = 'Rolanberry Fields',         tier = 1, slot = 'feet',  crest = 'Ocean'    },
    { zone = 'Sauromugue Champaign',      tier = 1, slot = 'head',  crest = 'Desert'   },
    { zone = 'Qufim Island',              tier = 1, slot = 'legs',  crest = 'Tundra'   },
    { zone = 'Yuhtunga Jungle',           tier = 1, slot = 'body',  crest = 'Forest'   },
    { zone = 'Yhoator Jungle',            tier = 2, slot = 'hands', crest = 'Forest'   },
    { zone = 'Sea Serpent Grotto',         tier = 2, slot = 'legs',  crest = 'Ocean'    },
    { zone = 'The Sanctuary of Zi\'Tah',  tier = 2, slot = 'head',  crest = 'Forest'   },
    { zone = 'Eastern Altepa Desert',     tier = 2, slot = 'body',  crest = 'Desert'   },
    { zone = 'Garlaige Citadel',          tier = 2, slot = 'feet',  crest = 'Mountain' },
    { zone = 'Crawler\'s Nest',           tier = 2, slot = 'legs',  crest = 'Desert'   },
    { zone = 'Western Altepa Desert',     tier = 2, slot = 'hands', crest = 'Desert'   },
    { zone = 'Labyrinth of Onzozo',       tier = 2, slot = 'head',  crest = 'Tundra'   },
    { zone = 'Gustav Tunnel',             tier = 3, slot = 'hands', crest = 'Desert'   },
    { zone = 'Toraimarai Canal',          tier = 2, slot = 'body',  crest = 'Ocean'    },
    { zone = 'Misareaux Coast',           tier = 2, slot = 'feet',  crest = 'Tundra'   },
    { zone = 'Bostaunieux Oubliette',     tier = 3, slot = 'feet',  crest = 'Tundra'   },
    { zone = 'Uleguerand Range',          tier = 3, slot = 'head',  crest = 'Tundra'   },
    { zone = 'Kuftal Tunnel',             tier = 3, slot = 'legs',  crest = 'Mountain' },
    { zone = 'The Boyahda Tree',          tier = 3, slot = 'head',  crest = 'Mountain' },
    { zone = 'Cape Teriggan',             tier = 3, slot = 'body',  crest = 'Desert'   },
    { zone = 'Ro\'Maeve',                 tier = 3, slot = 'hands', crest = 'Forest'   },
    { zone = 'Bibiki Bay',                tier = 3, slot = 'body',  crest = 'Ocean'    },
    { zone = 'East Ronfaure [S]',         tier = 1, slot = 'head',  crest = 'Forest',   loc = '(G-9)' },
    { zone = 'West Sarutabaruta [S]',     tier = 1, slot = 'hands', crest = 'Forest'   },
    { zone = 'North Gustaberg [S]',       tier = 1, slot = 'feet',  crest = 'Mountain' },
    { zone = 'Wajaom Woodlands',          tier = 1, slot = 'body',  crest = 'Tundra',  loc = '(I-6)' },
    { zone = 'Bhaflau Thickets',          tier = 1, slot = 'hands', crest = 'Desert',  loc = '(H-9)' },
    { zone = 'Alzadaal Undersea Ruins',   tier = 1, slot = 'legs',  crest = 'Ocean',   loc = 'Map 3 (I-8)' },
    { zone = 'Grauberg [S]',              tier = 2, slot = 'head',  crest = 'Mountain' },
    { zone = 'Vunkerl Inlet [S]',         tier = 2, slot = 'hands', crest = 'Ocean'    },
    { zone = 'Fort Karugo-Narugo [S]',    tier = 2, slot = 'feet',  crest = 'Forest'   },
    { zone = 'East Ronfaure [S]',         tier = 2, slot = 'body',  crest = 'Forest',  loc = '(H-9)' },
    { zone = 'Garlaige Citadel [S]',      tier = 3, slot = 'legs',  crest = 'Forest'   },
    { zone = 'Rolanberry Fields [S]',     tier = 3, slot = 'hands', crest = 'Ocean'    },
    { zone = 'Bhaflau Thickets',          tier = 3, slot = 'feet',  crest = 'Desert',  loc = '(H-7)' },
    { zone = 'Wajaom Woodlands',          tier = 3, slot = 'body',  crest = 'Tundra',  loc = '(I-8)' },
    { zone = 'Aydeewa Subterrane',        tier = 3, slot = 'legs',  crest = 'Mountain' },
    { zone = 'Caedarva Mire',             tier = 3, slot = 'legs',  crest = 'Tundra'   },
    { zone = 'Mount Zhayolm',             tier = 3, slot = 'feet',  crest = 'Desert'   },
    { zone = 'Alzadaal Undersea Ruins',   tier = 3, slot = 'head',  crest = 'Ocean',   loc = 'Map 2 (I-8)' },
};

local CREST_ZONES = {};
local ZONE_LOOKUP = {};
local ZONE_LOC_LOOKUP = {};  -- key: "zone|loc" for zones with duplicate entries
local ZONE_HAS_LOC = {};     -- zones that need loc disambiguation
local ITEM_ZONES  = {};

local function buildLookups()
    CREST_ZONES = {};
    ZONE_LOOKUP = {};
    ZONE_LOC_LOOKUP = {};
    ZONE_HAS_LOC = {};
    ITEM_ZONES  = {};

    -- First pass: identify zones that appear more than once
    local zoneCounts = {};
    for _, drop in ipairs(ZONE_DROPS) do
        local key = string.lower(drop.zone);
        zoneCounts[key] = (zoneCounts[key] or 0) + 1;
    end

    for _, drop in ipairs(ZONE_DROPS) do
        if not CREST_ZONES[drop.crest] then CREST_ZONES[drop.crest] = {}; end
        local found = false;
        for _, z in ipairs(CREST_ZONES[drop.crest]) do if z == drop.zone then found = true; break; end end
        if not found then table.insert(CREST_ZONES[drop.crest], drop.zone); end

        local key = string.lower(drop.zone);
        local entry = { tier = drop.tier, slot = drop.slot, crest = drop.crest };

        -- For duplicate zones with loc, use loc-specific lookup
        if zoneCounts[key] > 1 and drop.loc then
            ZONE_HAS_LOC[key] = true;
            local locKey = key .. '|' .. string.lower(drop.loc);
            if not ZONE_LOC_LOOKUP[locKey] then ZONE_LOC_LOOKUP[locKey] = {}; end
            table.insert(ZONE_LOC_LOOKUP[locKey], entry);
        else
            if not ZONE_LOOKUP[key] then ZONE_LOOKUP[key] = {}; end
            table.insert(ZONE_LOOKUP[key], entry);
        end

        for _, set in ipairs(SETS) do
            local itemId = set.tiers[drop.tier][drop.slot];
            if itemId then
                if not ITEM_ZONES[itemId] then ITEM_ZONES[itemId] = {}; end
                local dup = false;
                for _, z in ipairs(ITEM_ZONES[itemId]) do if z == drop.zone then dup = true; break; end end
                if not dup then table.insert(ITEM_ZONES[itemId], drop.zone); end
            end
        end
    end
end
buildLookups();

------------------------------------------------------------
-- Storage Slip 01
------------------------------------------------------------
local SLIP_ID = 29312;
local SLIP_ITEMS = {
    16084, 14546, 14961, 15625, 15711, 16085, 14547, 14962, 15626, 15712,
    16086, 14548, 14963, 15627, 15713, 16087, 14549, 14964, 15628, 15714,
    16088, 14550, 14965, 15629, 15715, 16089, 14551, 14966, 15630, 15716,
    16090, 14552, 14967, 15631, 15717, 16091, 14553, 14968, 15632, 15718,
    16092, 14554, 14969, 15633, 15719, 16093, 14555, 14970, 15634, 15720,
    16094, 14556, 14971, 15635, 15721, 16095, 14557, 14972, 15636, 15722,
    16096, 14558, 14973, 15637, 15723, 16097, 14559, 14974, 15638, 15724,
    16098, 14560, 14975, 15639, 15725, 16099, 14561, 14976, 15640, 15726,
    16100, 14562, 14977, 15641, 15727, 16101, 14563, 14978, 15642, 15728,
    16102, 14564, 14979, 15643, 15729, 16103, 14565, 14980, 15644, 15730,
};

------------------------------------------------------------
-- Containers
------------------------------------------------------------
local CONTAINERS = {
    { id = 0,  name = 'Inventory' },  { id = 1,  name = 'Safe' },
    { id = 2,  name = 'Storage' },    { id = 4,  name = 'Locker' },
    { id = 5,  name = 'Satchel' },    { id = 6,  name = 'Sack' },
    { id = 7,  name = 'Case' },       { id = 8,  name = 'Wardrobe' },
    { id = 9,  name = 'Safe 2' },     { id = 10, name = 'Wardrobe 2' },
    { id = 11, name = 'Wardrobe 3' }, { id = 12, name = 'Wardrobe 4' },
    { id = 13, name = 'Wardrobe 5' }, { id = 14, name = 'Wardrobe 6' },
    { id = 15, name = 'Wardrobe 7' }, { id = 16, name = 'Wardrobe 8' },
};

------------------------------------------------------------
-- Ownership tracking
------------------------------------------------------------
local owned     = {};
local lastScan  = 0;
local SCAN_INTERVAL = 2;

local function bitPow(p) return 2 ^ (p - 1); end
local function hasBit(x, p) return x % (p + p) >= p; end

local function scanInventory()
    local now = os.clock();
    if now - lastScan < SCAN_INTERVAL then return; end
    lastScan = now;

    local newOwned = {};
    local inventory = AshitaCore:GetMemoryManager():GetInventory();

    local watchIds = {};
    for _, set in ipairs(SETS) do
        for t = 1, 3 do
            for _, slot in ipairs(SLOTS) do watchIds[set.tiers[t][slot]] = true; end
        end
        for _, slot in ipairs(SLOTS) do watchIds[set.final[slot]] = true; end
    end

    if inventory == nil then return; end
    for _, container in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(container.id);
        if max ~= nil and max > 0 then
        for j = 0, max do
            local ok, item = pcall(function() return inventory:GetContainerItem(container.id, j); end);
            if not ok or item == nil then break; end
            if item.Id ~= 0 and item.Id ~= 65535 then
                if watchIds[item.Id] then newOwned[item.Id] = container.name; end
                if item.Id == SLIP_ID then
                    local extra = item.Extra;
                    for idx, slipItemId in ipairs(SLIP_ITEMS) do
                        if watchIds[slipItemId] then
                            local byteIndex = math.floor((idx - 1) / 8) + 1;
                            local bitIndex  = (idx - 1) % 8 + 1;
                            local byte = struct.unpack('B', extra, byteIndex);
                            if byte < 0 then byte = byte + 256; end
                            if hasBit(byte, bitPow(bitIndex)) then
                                newOwned[slipItemId] = 'Storage Slip 01';
                            end
                        end
                    end
                end
            end
        end
        end -- max check
    end
    owned = newOwned;
end

------------------------------------------------------------
-- Alert system
------------------------------------------------------------
local alertZones    = {};
local alertDisplay  = {};
local alertTime     = 0;
local ALERT_TIMEOUT = 300;
local alertItemIds  = {};
local alertCrests   = {};

local function clearAlerts()
    alertZones   = {};
    alertDisplay = {};
    alertItemIds = {};
    alertCrests  = {};
    alertTime    = 0;
end

local function processPopuloxMessage(msg)
    alertTime = os.clock();
    for zonePart in msg:gmatch('([^/]+)') do
        local trimmed = zonePart:gsub('^%s+',''):gsub('%s+$','');
        local locStr = trimmed:match('(%(?[Mm]ap%s*%d+%s*%)?%s*%([A-Z]%-[0-9]+%))') or trimmed:match('(%([A-Z]%-[0-9]+%))');
        local zoneName = trimmed:gsub('%s*%(?[Mm]ap%s*%d+%s*%)?%s*%([A-Z]%-[0-9]+%)',''):gsub('%s*%([A-Z]%-[0-9]+%)','');
        if #zoneName > 3 then
            local key = string.lower(zoneName);
            if not alertZones[trimmed] then
                alertZones[trimmed] = true;
                table.insert(alertDisplay, trimmed);
            end

            -- Use loc-specific lookup for zones with duplicates
            local drops = nil;
            if ZONE_HAS_LOC[key] and locStr then
                local locKey = key .. '|' .. string.lower(locStr);
                drops = ZONE_LOC_LOOKUP[locKey];
            end
            -- Fallback to general lookup
            if not drops then
                drops = ZONE_LOOKUP[key];
            end

            if drops then
                for _, drop in ipairs(drops) do
                    for _, set in ipairs(SETS) do
                        local itemId = set.tiers[drop.tier][drop.slot];
                        if itemId then alertItemIds[itemId] = true; end
                    end
                    alertCrests[drop.crest] = true;
                end
            end
        end
    end
end

local function hasAlertActive()
    return alertTime > 0;
end

------------------------------------------------------------
-- Layout constants
------------------------------------------------------------
local ICON_SIZE = 32;
local CELL_PAD  = 4;

local CREST_ITEM_IDS = {
    Mountain = 3047, Forest = 3045, Desert = 3049, Ocean = 3046, Tundra = 3050,
};

-- Cell background colors (cached, rebuilt on theme change)
local cellColorCache = nil;
local cellColorVersion = -1;

local function getCellColors()
    local v = ui.getThemeVersion();
    if cellColorCache and cellColorVersion == v then return cellColorCache; end
    local base = ui.color('childBg');
    cellColorCache = {
        ownedBg    = { 0.18, 0.38, 0.18, 1.0  },
        completeBg = { 0.18, 0.28, 0.48, 1.0  },
        cellBg     = { base[1], base[2], base[3], 1.0 },
    };
    cellColorVersion = v;
    return cellColorCache;
end

------------------------------------------------------------
-- Render helpers
------------------------------------------------------------
local function renderTooltip(itemId, setData, tierIdx, slotKey)
    local res = getItemRes(itemId);
    local name = res and res.Name[1] or '???';

    ui.tooltip(function()
        ui.colored(name, 'white');

        local isComplete = slotKey and owned[setData.final[slotKey]] ~= nil;
        if isComplete then
            local finalRes = getItemRes(setData.final[slotKey]);
            local finalName = finalRes and finalRes.Name[1] or '???';
            imgui.TextColored({ 0.40, 0.60, 1.0, 1.0 }, string.format('  Completed: %s', finalName));
        elseif owned[itemId] then
            ui.colored(string.format('  Owned (%s)', tostring(owned[itemId])), 'ownedTick');
        end

        imgui.Separator();
        ui.colored('Drop zones:', 'dimText');

        local zones = ITEM_ZONES[itemId];
        if zones then
            for _, z in ipairs(zones) do
                local key = string.lower(z);
                if alertZones[key] then
                    ui.colored('  >> ' .. z .. ' <<', 'alertGlow');
                else
                    imgui.Text('  ' .. z);
                end
            end
        else
            imgui.Text('  (unknown)');
        end

        if slotKey and tierIdx then
            local hnm = HNM_DROPS[tierIdx] and HNM_DROPS[tierIdx][slotKey];
            if hnm then
                imgui.Separator();
                ui.colored('Also drops from:', 'dimText');
                imgui.TextColored({ 0.90, 0.70, 0.50, 1.0 }, '  ' .. hnm);
            end
        end
    end);
end

local function renderCrestTooltip(setData)
    ui.tooltip(function()
        local crestId = CREST_ITEM_IDS[setData.crest];
        if crestId then renderIcon(crestId, 20); imgui.SameLine(0, 6); end
        imgui.TextColored(setData.color, setData.name .. ' (' .. setData.crest .. ' Crest)');
        ui.colored(setData.jobs, 'dimText');
        imgui.Separator();
        imgui.Text('Crest zones:');
        local zones = CREST_ZONES[setData.crest];
        if zones then
            for _, z in ipairs(zones) do
                local key = string.lower(z);
                if alertZones[key] then
                    ui.colored('  >> ' .. z .. ' <<', 'alertGlow');
                else
                    imgui.Text('  ' .. z);
                end
            end
        end
    end);
end

local function renderCell(itemId, setData, tierIdx, slotKey)
    local isOwned    = owned[itemId] ~= nil;
    local isAlert    = alertItemIds[itemId] ~= nil;
    local isComplete = owned[setData.final[slotKey]] ~= nil;

    local bgCol;
    local cc = getCellColors();
    if isComplete then bgCol = cc.completeBg;
    elseif isOwned then bgCol = cc.ownedBg;
    else bgCol = cc.cellBg; end

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
    local cellId = string.format('##vnm_cell_%d', itemId);
    imgui.BeginChild(cellId, { ICON_SIZE + CELL_PAD * 2, ICON_SIZE + CELL_PAD * 2 }, true, ImGuiWindowFlags_NoScrollbar);
    imgui.SetCursorPos({ CELL_PAD, CELL_PAD });
    if not renderIcon(itemId, ICON_SIZE) then
        imgui.PushStyleColor(ImGuiCol_Button, ui.color('notOwned'));
        imgui.Button('?', { ICON_SIZE, ICON_SIZE });
        imgui.PopStyleColor();
    end
    imgui.EndChild();
    imgui.PopStyleColor();

    if isAlert then
        local rx, ry = imgui.GetItemRectMin();
        local rx2, ry2 = imgui.GetItemRectMax();
        local drawList = imgui.GetWindowDrawList();
        local pulse = math.abs(math.sin(os.clock() * 3.0));
        local alertCol = { 1.0, 0.85 + pulse * 0.15, 0.20, 0.6 + pulse * 0.4 };
        drawList:AddRect({ rx, ry }, { rx2, ry2 }, imgui.GetColorU32(alertCol), 0, 0, 2);
    end

    if imgui.IsItemHovered() then
        renderTooltip(itemId, setData, tierIdx, slotKey);
    end
end

------------------------------------------------------------
-- Window state
------------------------------------------------------------
local isOpen = { false };

------------------------------------------------------------
-- Main render (floating window)
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    if alertTime > 0 and os.clock() - alertTime > ALERT_TIMEOUT then
        clearAlerts();
    end

    scanInventory();

    local totalOwned = 0;
    local totalItems = 0;
    for _, set in ipairs(SETS) do
        for t = 1, 3 do
            for _, slot in ipairs(SLOTS) do
                totalItems = totalItems + 1;
                if owned[set.tiers[t][slot]] then totalOwned = totalOwned + 1; end
            end
        end
    end

    local title;
    if alertTime > 0 and #alertDisplay > 0 then
        local zoneStr = table.concat(alertDisplay, ' / ');
        if #zoneStr > 60 then zoneStr = string.sub(zoneStr, 1, 57) .. '...'; end
        title = string.format('VNM [%d/%d] - %s###trove_vnm', totalOwned, totalItems, zoneStr);
    else
        title = string.format('VNM Armor [%d/%d]###trove_vnm', totalOwned, totalItems);
    end

    imgui.SetNextWindowSize({ 740, 300 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 700, 300 }, { 1000, 800 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin(title, isOpen, ImGuiWindowFlags_NoScrollbar) then
        local _bgPop = ui.renderBackground();
        local cellW  = ICON_SIZE + CELL_PAD * 2;
        local labelW = 56;
        local startX = labelW + 4;

        -- Clear button + set headers
        if alertTime > 0 then
            imgui.PushStyleColor(ImGuiCol_Button, { 0.35, 0.25, 0.10, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.50, 0.35, 0.15, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.25, 0.18, 0.08, 1.0 });
            ui.pushColor('alertGlow');
            if imgui.SmallButton('Clear') then clearAlerts(); end
            ui.popColor();
            imgui.PopStyleColor(3);
            imgui.SameLine(0, 0);
        end

        for si, set in ipairs(SETS) do
            local headerW = cellW * 3 + 8;
            local textW = imgui.CalcTextSize(set.name);
            local padX = (headerW - textW) / 2;
            if padX < 0 then padX = 0; end
            imgui.SetCursorPosX(startX + (si - 1) * (headerW + 8) + padX);
            imgui.TextColored(set.color, set.name);
            if imgui.IsItemHovered() then renderCrestTooltip(set); end
            imgui.SameLine(0, 0);
        end
        imgui.NewLine();
        imgui.Separator();

        -- Tier sub-headers
        imgui.SetCursorPosX(startX);
        for si = 1, #SETS do
            for ti = 1, 3 do
                if si > 1 or ti > 1 then imgui.SameLine(0, 0); end
                local x = startX + (si - 1) * (cellW * 3 + 8 + 8) + (ti - 1) * (cellW + 2);
                imgui.SetCursorPosX(x);
                ui.pushColor('accent');
                local tierTextW = imgui.CalcTextSize(TIER_LABELS[ti]);
                local tierPad = (cellW - tierTextW) / 2;
                if tierPad < 0 then tierPad = 0; end
                imgui.SetCursorPosX(x + tierPad);
                imgui.Text(TIER_LABELS[ti]);
                ui.popColor();
            end
        end

        -- Grid
        for slotIdx, slotKey in ipairs(SLOTS) do
            ui.colored(SLOT_LABELS[slotIdx], 'slotText');
            for si, set in ipairs(SETS) do
                for ti = 1, 3 do
                    imgui.SameLine(0, 0);
                    local x = startX + (si - 1) * (cellW * 3 + 8 + 8) + (ti - 1) * (cellW + 2);
                    imgui.SetCursorPosX(x);
                    renderCell(set.tiers[ti][slotKey], set, ti, slotKey);
                end
            end
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
    name        = 'VNM Armor',
    author      = 'Loxley',
    version     = '1.0',
    description = 'VNM armor collection tracker with zone alerts',

    -- Expose init for trove.lua to inject shared functions
    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
    end,

    -- Expose hasAlert for the burger button indicator
    hasAlert = hasAlertActive,

    commands = {
        vnm = function(state, args)
            isOpen[1] = not isOpen[1];
        end,
    },

    window = {
        category = 'Collections',
        isOpen  = isOpen,
        render  = renderWindow,
        -- Menu entry config for the hamburger popup
        label   = 'VNM Armor',
        icon    = 3045,
    },

    onPacketIn = function(e, state)
        -- Zone change: clear alerts
        if e.id == 0x0A or e.id == 0x0B then
            clearAlerts();
            return;
        end

        -- Chat monitoring for Populox and Active Venture Seals
        if e.id ~= 0x17 then return; end

        local chatType = struct.unpack('B', e.data_modified, 0x04 + 1);

        local sender = '';
        for i = 0x08, 0x16 do
            local b = struct.unpack('B', e.data_modified, i + 1);
            if b == 0 then break; end
            sender = sender .. string.char(b);
        end

        local msg = '';
        for i = 0x17, #e.data_modified - 1 do
            local b = struct.unpack('B', e.data_modified, i + 1);
            if b == 0 then break; end
            msg = msg .. string.char(b);
        end

        if sender == 'Populox' and chatType == 0x21 and msg:find('/') then
            processPopuloxMessage(msg);
            return;
        end

        local sealsMsg = msg:match('Active Venture Seals:%s*(.+)');
        if sealsMsg and sealsMsg:find('/') then
            processPopuloxMessage(sealsMsg);
        end
    end,
};
