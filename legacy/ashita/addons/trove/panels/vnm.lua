--[[
* trove_vnm - VNM Armor panel for Trove
*
* Loaded by trove.lua as a sub-panel. Renders its own imgui window.
* Reuses trove's texture cache via injected renderIcon/getItemRes functions.
]]--

local imgui = require('imgui');

local vnm = {};

------------------------------------------------------------
-- State (set by trove on init)
------------------------------------------------------------
vnm.isOpen      = { false };
vnm.renderIcon  = nil; -- function(itemId, size) injected by trove
vnm.getItemRes  = nil; -- function(itemId) injected by trove

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
    { zone = 'East Ronfaure [S]',         tier = 1, slot = 'head',  crest = 'Forest'   },
    { zone = 'West Sarutabaruta [S]',     tier = 1, slot = 'hands', crest = 'Forest'   },
    { zone = 'North Gustaberg [S]',       tier = 1, slot = 'feet',  crest = 'Mountain' },
    { zone = 'Wajaom Woodlands',          tier = 1, slot = 'body',  crest = 'Tundra'   },
    { zone = 'Bhaflau Thickets',          tier = 1, slot = 'hands', crest = 'Desert'   },
    { zone = 'Alzadaal Undersea Ruins',   tier = 1, slot = 'legs',  crest = 'Ocean'    },
    { zone = 'Grauberg [S]',              tier = 2, slot = 'head',  crest = 'Mountain' },
    { zone = 'Vunkerl Inlet [S]',         tier = 2, slot = 'hands', crest = 'Ocean'    },
    { zone = 'Fort Karugo-Narugo [S]',    tier = 2, slot = 'feet',  crest = 'Forest'   },
    { zone = 'East Ronfaure [S]',         tier = 2, slot = 'body',  crest = 'Forest'   },
    { zone = 'Garlaige Citadel [S]',      tier = 3, slot = 'legs',  crest = 'Forest'   },
    { zone = 'Rolanberry Fields [S]',     tier = 3, slot = 'hands', crest = 'Ocean'    },
    { zone = 'Bhaflau Thickets',          tier = 3, slot = 'feet',  crest = 'Desert'   },
    { zone = 'Wajaom Woodlands',          tier = 3, slot = 'body',  crest = 'Tundra'   },
    { zone = 'Aydeewa Subterrane',        tier = 3, slot = 'legs',  crest = 'Mountain' },
    { zone = 'Caedarva Mire',             tier = 3, slot = 'legs',  crest = 'Tundra'   },
    { zone = 'Mount Zhayolm',             tier = 3, slot = 'feet',  crest = 'Desert'   },
    { zone = 'Alzadaal Undersea Ruins',   tier = 3, slot = 'head',  crest = 'Ocean'    },
};

local CREST_ZONES = {};
local ZONE_LOOKUP = {};
local ITEM_ZONES  = {};

local function buildLookups()
    CREST_ZONES = {};
    ZONE_LOOKUP = {};
    ITEM_ZONES  = {};
    for _, drop in ipairs(ZONE_DROPS) do
        if not CREST_ZONES[drop.crest] then CREST_ZONES[drop.crest] = {}; end
        local found = false;
        for _, z in ipairs(CREST_ZONES[drop.crest]) do if z == drop.zone then found = true; break; end end
        if not found then table.insert(CREST_ZONES[drop.crest], drop.zone); end
        local key = string.lower(drop.zone);
        if not ZONE_LOOKUP[key] then ZONE_LOOKUP[key] = {}; end
        table.insert(ZONE_LOOKUP[key], { tier = drop.tier, slot = drop.slot, crest = drop.crest });
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

function vnm.clearAlerts()
    alertZones   = {};
    alertDisplay = {};
    alertItemIds = {};
    alertCrests  = {};
    alertTime    = 0;
end

function vnm.processPopuloxMessage(msg)
    alertTime = os.clock();
    for zonePart in msg:gmatch('([^/]+)') do
        local trimmed = zonePart:gsub('^%s+',''):gsub('%s+$','');
        local zoneName = trimmed:gsub('%s*%([A-Z]%-[0-9]+%)','');
        if #zoneName > 3 then
            local key = string.lower(zoneName);
            if not alertZones[key] then
                alertZones[key] = true;
                table.insert(alertDisplay, trimmed);
            end
            local drops = ZONE_LOOKUP[key];
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

function vnm.hasAlert()
    return alertTime > 0;
end

------------------------------------------------------------
-- Colors
------------------------------------------------------------
local COLORS = {
    ownedBg    = { 0.18, 0.38, 0.18, 1.0  },
    completeBg = { 0.18, 0.28, 0.48, 1.0  },
    ownedTick  = { 0.30, 0.85, 0.30, 1.0  },
    notOwned   = { 0.30, 0.25, 0.40, 1.0  },
    cellBg     = { 0.14, 0.12, 0.20, 1.0  },
    alertGlow  = { 1.00, 0.85, 0.20, 1.0  },
    tierLabel  = { 0.70, 0.62, 0.82, 1.0  },
    slotLabel  = { 0.82, 0.75, 0.92, 1.0  },
    dimText    = { 0.60, 0.52, 0.70, 1.0  },
    white      = { 1.0,  1.0,  1.0,  1.0  },
    tooltipBg  = { 0.12, 0.10, 0.18, 0.95 },
};

local ICON_SIZE = 32;
local CELL_PAD  = 4;

local CREST_ITEM_IDS = {
    Mountain = 3047, Forest = 3045, Desert = 3049, Ocean = 3046, Tundra = 3050,
};

------------------------------------------------------------
-- Render helpers
------------------------------------------------------------
local function renderTooltip(itemId, setData, tierIdx, slotKey)
    local res = vnm.getItemRes(itemId);
    local name = res and res.Name[1] or '???';

    imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.tooltipBg);
    imgui.BeginTooltip();
    imgui.PushStyleColor(ImGuiCol_Text, COLORS.white);
    imgui.Text(name);
    imgui.PopStyleColor();

    local isComplete = slotKey and owned[setData.final[slotKey]] ~= nil;
    if isComplete then
        local finalRes = vnm.getItemRes(setData.final[slotKey]);
        local finalName = finalRes and finalRes.Name[1] or '???';
        imgui.PushStyleColor(ImGuiCol_Text, { 0.40, 0.60, 1.0, 1.0 });
        imgui.Text(string.format('  Completed: %s', finalName));
        imgui.PopStyleColor();
    elseif owned[itemId] then
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.ownedTick);
        imgui.Text(string.format('  Owned (%s)', tostring(owned[itemId])));
        imgui.PopStyleColor();
    end

    imgui.Separator();
    imgui.PushStyleColor(ImGuiCol_Text, COLORS.dimText);
    imgui.Text('Drop zones:');
    imgui.PopStyleColor();

    local zones = ITEM_ZONES[itemId];
    if zones then
        for _, z in ipairs(zones) do
            local key = string.lower(z);
            if alertZones[key] then
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.alertGlow);
                imgui.Text('  >> ' .. z .. ' <<');
                imgui.PopStyleColor();
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
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.dimText);
            imgui.Text('Also drops from:');
            imgui.PopStyleColor();
            imgui.PushStyleColor(ImGuiCol_Text, { 0.90, 0.70, 0.50, 1.0 });
            imgui.Text('  ' .. hnm);
            imgui.PopStyleColor();
        end
    end

    imgui.EndTooltip();
    imgui.PopStyleColor(); -- PopupBg
end

local function renderCrestTooltip(setData)
    imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.tooltipBg);
    imgui.BeginTooltip();
    local crestId = CREST_ITEM_IDS[setData.crest];
    if crestId then vnm.renderIcon(crestId, 20); imgui.SameLine(0, 6); end
    imgui.PushStyleColor(ImGuiCol_Text, setData.color);
    imgui.Text(setData.name .. ' (' .. setData.crest .. ' Crest)');
    imgui.PopStyleColor();
    imgui.PushStyleColor(ImGuiCol_Text, COLORS.dimText);
    imgui.Text(setData.jobs);
    imgui.PopStyleColor();
    imgui.Separator();
    imgui.Text('Crest zones:');
    local zones = CREST_ZONES[setData.crest];
    if zones then
        for _, z in ipairs(zones) do
            local key = string.lower(z);
            if alertZones[key] then
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.alertGlow);
                imgui.Text('  >> ' .. z .. ' <<');
                imgui.PopStyleColor();
            else
                imgui.Text('  ' .. z);
            end
        end
    end
    imgui.EndTooltip();
    imgui.PopStyleColor(); -- PopupBg
end

local function renderCell(itemId, setData, tierIdx, slotKey)
    local isOwned    = owned[itemId] ~= nil;
    local isAlert    = alertItemIds[itemId] ~= nil;
    local isComplete = owned[setData.final[slotKey]] ~= nil;

    local bgCol;
    if isComplete then bgCol = COLORS.completeBg;
    elseif isOwned then bgCol = COLORS.ownedBg;
    else bgCol = COLORS.cellBg; end

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
    local cellId = string.format('##vnm_cell_%d', itemId);
    imgui.BeginChild(cellId, { ICON_SIZE + CELL_PAD * 2, ICON_SIZE + CELL_PAD * 2 }, true, ImGuiWindowFlags_NoScrollbar);
    imgui.SetCursorPos({ CELL_PAD, CELL_PAD });
    if not vnm.renderIcon(itemId, ICON_SIZE) then
        imgui.PushStyleColor(ImGuiCol_Button, COLORS.notOwned);
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
-- Main render (called by trove each frame)
------------------------------------------------------------
function vnm.render()
    if not vnm.isOpen[1] then return; end

    if alertTime > 0 and os.clock() - alertTime > ALERT_TIMEOUT then
        vnm.clearAlerts();
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

    imgui.PushStyleColor(ImGuiCol_TitleBg,         { 0.14, 0.10, 0.22, 0.95 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,    { 0.22, 0.16, 0.32, 0.95 });
    imgui.PushStyleColor(ImGuiCol_WindowBg,         { 0.10, 0.08, 0.14, 0.92 });
    imgui.PushStyleColor(ImGuiCol_Border,           { 0.35, 0.25, 0.50, 0.60 });
    imgui.PushStyleColor(ImGuiCol_ChildBg,          { 0.14, 0.12, 0.20, 0.80 });

    if imgui.Begin(title, vnm.isOpen, ImGuiWindowFlags_NoScrollbar) then
        local cellW  = ICON_SIZE + CELL_PAD * 2;
        local labelW = 56;
        local startX = labelW + 4;

        -- Clear button + set headers
        if alertTime > 0 then
            imgui.PushStyleColor(ImGuiCol_Button, { 0.35, 0.25, 0.10, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.50, 0.35, 0.15, 1.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonActive, { 0.25, 0.18, 0.08, 1.0 });
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.alertGlow);
            if imgui.SmallButton('Clear') then vnm.clearAlerts(); end
            imgui.PopStyleColor(4);
            imgui.SameLine(0, 0);
        end

        for si, set in ipairs(SETS) do
            local headerW = cellW * 3 + 8;
            imgui.PushStyleColor(ImGuiCol_Text, set.color);
            local textW = imgui.CalcTextSize(set.name);
            local padX = (headerW - textW) / 2;
            if padX < 0 then padX = 0; end
            imgui.SetCursorPosX(startX + (si - 1) * (headerW + 8) + padX);
            imgui.Text(set.name);
            if imgui.IsItemHovered() then renderCrestTooltip(set); end
            imgui.PopStyleColor();
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
                imgui.PushStyleColor(ImGuiCol_Text, COLORS.tierLabel);
                local tierTextW = imgui.CalcTextSize(TIER_LABELS[ti]);
                local tierPad = (cellW - tierTextW) / 2;
                if tierPad < 0 then tierPad = 0; end
                imgui.SetCursorPosX(x + tierPad);
                imgui.Text(TIER_LABELS[ti]);
                imgui.PopStyleColor();
            end
        end

        -- Grid
        for slotIdx, slotKey in ipairs(SLOTS) do
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.slotLabel);
            imgui.Text(SLOT_LABELS[slotIdx]);
            imgui.PopStyleColor();
            for si, set in ipairs(SETS) do
                for ti = 1, 3 do
                    imgui.SameLine(0, 0);
                    local x = startX + (si - 1) * (cellW * 3 + 8 + 8) + (ti - 1) * (cellW + 2);
                    imgui.SetCursorPosX(x);
                    renderCell(set.tiers[ti][slotKey], set, ti, slotKey);
                end
            end
        end
    end
    imgui.End();
    imgui.PopStyleColor(5);
end

return vnm;
