--[[
* trove/plugins/keyring.lua — Goblin Keyring plugin
*
* Floating window showing chest and coffer key collection status.
* Reads item Extra data from the Goblin Keyring item in inventory.
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared functions (injected by trove.lua via plugin.init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;
local renderFileIcon = nil;

------------------------------------------------------------
-- Plugin data protocol (aether/prismatic key counts)
------------------------------------------------------------
local PACKET_ID       = 0x1A4;
local C2S_PLUGIN_DATA = 17;
local PLUGIN_ID       = 2;

local keyCounts = { prismatic = 0, aether = 0 };
local keyCountsLoaded = false;
local keyCountsLoading = false;
local keyCountsRequestTime = 0;

local REFRESH_INTERVAL = 5; -- re-request every 5 seconds while open

local function requestKeyCounts()
    if keyCountsLoading then return; end
    keyCountsLoading = true;
    keyCountsRequestTime = os.clock();
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    p[5] = C2S_PLUGIN_DATA;
    p[7] = PLUGIN_ID;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

------------------------------------------------------------
-- Key data
------------------------------------------------------------
local CHEST_KEYS = {
    { name = "Pso'Xja",                id = 1064, drops = {{zone="Pso'Xja", mobs={"Blubber Eyes","Camazotz","Cryptonberry Cutter","Cryptonberry Harrier","Cryptonberry Plaguer","Cryptonberry Stalker","Gargoyle","Labyrinth Lizard","Magic Millstone","Snowball"}}} },
    { name = "Oldton Movalpolos",      id = 1062, drops = {{zone="Oldton Movalpolos", mobs={"Bugbear Bondman","Goblin Doorman","Goblin Oilman","Goblin Shovelman","Goblin Tollman","Moblin Ashman","Moblin Coalman","Moblin Gasman","Moblin Pikeman"}}} },
    { name = "Sacrarium",              id = 1061, drops = {{zone="Sacrarium", mobs={"Fomor Bard","Fomor Black Mage","Fomor Dark Knight","Fomor Dragoon","Fomor Monk","Fomor Ninja","Fomor Paladin","Fomor Ranger","Fomor Red Mage","Fomor Samurai","Fomor Thief","Fomor Warrior","Gazer","Mummy"}}} },
    { name = "Fort Ghelsba",           id = 1024, drops = {{zone="Fort Ghelsba", mobs={"Orcish Cursemaker","Orcish Fighter","Orcish Serjeant"}},{zone="Yughott Grotto", mobs={"Orcish Cursemaker","Orcish Fighter","Orcish Serjeant"}}} },
    { name = "Palborough Mines",       id = 1025, drops = {{zone="Palborough Mines", mobs={"Brass Quadav","Copper Quadav","Old Quadav","Scimitar Scorpion"}}} },
    { name = "Giddeus",                id = 1026, drops = {{zone="Giddeus", mobs={"Yagudo Priest","Yagudo Theologist","Yagudo Votary"}}} },
    { name = "Beadeaux",               id = 1034, drops = {{zone="Beadeaux", mobs={"Broo","Elder Quadav","Emerald Quadav","Gloop","Iron Quadav","Spinel Quadav"}}} },
    { name = "Davoi",                  id = 1033, drops = {{zone="Davoi", mobs={"Orcish Bowshooter","Orcish Firebelcher","Orcish Footsoldier","Orcish Gladiator","Orcish Trooper"}},{zone="Monastic Cavern", mobs={"Orcish Footsoldier","Orcish Gladiator","Orcish Trooper"}}} },
    { name = "Castle Oztroja",         id = 1035, drops = {{zone="Castle Oztroja", mobs={"Ooze","Yagudo Conquistador","Yagudo Lutenist","Yagudo Parasite","Yagudo Prior","Yagudo Zealot"}}} },
    { name = "Delkfutt's Tower",       id = 1036, drops = {{zone="Lower Delkfutt's Tower", mobs={"Gigas Hallwatcher","Gigas Punisher","Gigas Sculptor","Magic Urn"}},{zone="Middle Delkfutt's Tower", mobs={"Evil Spirit"}},{zone="Upper Delkfutt's Tower", mobs={"Gigas Bonecutter","Gigas Spirekeeper","Gigas Stonemason","Gigas Torturer","Magic Urn"}}} },
    { name = "Castle Zvahl",           id = 1038, drops = {{zone="Castle Zvahl Baileys", mobs={"Demon Knight","Demon Pawn","Demon Warlock","Demon Wizard","Morbid Eye"}},{zone="Castle Zvahl Keep", mobs={"Demon Knight","Demon Pawn","Demon Warlock","Demon Wizard","Morbid Eye"}}} },
    { name = "Sea Serpent Grotto",     id = 1055, drops = {{zone="Sea Serpent Grotto", mobs={"Bigclaw","Brook Sahagin","Grotto Pugil","Ironshell","Ooze","Riparian Sahagin","Rivulet Sahagin","Vampire Bat"}}} },
    { name = "King Ranperre's Tomb",   id = 1027, drops = {{zone="King Ranperre's Tomb", mobs={"Crypt Ghost","Goblin Ambusher","Goblin Butcher","Goblin Tinkerer","Plague Bats","Rock Eater","Tomb Bat"}}} },
    { name = "Dangruf Wadi",           id = 1028, drops = {{zone="Dangruf Wadi", mobs={"Goblin Ambusher","Goblin Butcher","Goblin Tinkerer","Steam Lizard"}}} },
    { name = "Horutoto Ruins",         id = 1029, drops = {{zone="Inner Horutoto Ruins", mobs={"Battle Bat","Blob","Goblin Gambler","Goblin Leecher","Goblin Mugger"}},{zone="Outer Horutoto Ruins", mobs={"Combat","Five of Batons","Five of Coins","Rotten Jam","Six of Batons","Stink Bats"}}} },
    { name = "Ordelle's Caves",        id = 1030, drops = {{zone="Ordelle's Caves", mobs={"Goblin Furrier","Goblin Pathfinder","Goblin Shaman","Goblin Smithy","Goliath Beetle","Napalm","Stroper"}}} },
    { name = "The Eldieme Necropolis", id = 1039, drops = {{zone="The Eldieme Necropolis", mobs={"Azer","Blood Soul","Fallen Knight","Lich","Mummy","Utukku"}}} },
    { name = "Gusgen Mines",           id = 1031, drops = {{zone="Gusgen Mines", mobs={"Amphisbaena","Banshee","Gallinipper","Myconid","Rancid Ooze","Sadfly","Wendigo"}}} },
    { name = "Crawler's Nest",         id = 1040, drops = {{zone="Crawler's Nest", mobs={"Blazer Beetle","Dragonfly","Exoray","Hornfly","Labyrinth Lizard","Mushussu","Rumble Crawler","Soul Stinger","Wespe","Witch Hazel"}}} },
    { name = "Maze of Shakhrami",      id = 1032, drops = {{zone="Maze of Shakhrami", mobs={"Abyss Worm","Caterchipillar","Goblin Furrier","Goblin Pathfinder","Goblin Shaman","Goblin Smithy","Labyrinth Scorpion","Protozoan"}}} },
    { name = "Garlaige Citadel",       id = 1041, drops = {{zone="Garlaige Citadel", mobs={"Acid Grease","Droma","Explosure","Fallen Officer","Fetid Flesh","Funnel Bats"}}} },
    { name = "Fei'Yin",                id = 1037, drops = {{zone="Fei'Yin", mobs={"Ore Golem","Shadow","Underworld Bats"}}} },
    { name = "Labyrinth of Onzozo",    id = 1056, drops = {{zone="Labyrinth of Onzozo", mobs={"Cockatrice","Flying Manta","Goblin Bouncer","Goblin Enchanter","Goblin Hunter","Goblin Miner","Mushussu"}}} },
};

local COFFER_KEYS = {
    { name = "Newton Movalpolos",      id = 1063, drops = {{zone="Newton Movalpolos", mobs={"Bugbear Deathsman","Bugbear Watchman","Goblin Junkman","Mimic","Moblin Aidman"}}} },
    { name = "Ru'Aun Gardens",         id = 1058, drops = {{zone="Ru'Aun Gardens", mobs={"Flamingo","Groundskeeper","Mimic","Sprinkler"}}} },
    { name = "Beadeaux",               id = 1043, drops = {{zone="Beadeaux", mobs={"Ancient Quadav","Darksteel Quadav","Mimic","Platinum Quadav","Sapphire Quadav"}}} },
    { name = "Monastic Cavern",        id = 1042, drops = {{zone="Davoi", mobs={"Orcish Champion","Orcish Dragoon","Orcish Dreadnought","Orcish Farkiller"}},{zone="Monastic Cavern", mobs={"Mimic","Orcish Champion","Orcish Dragoon","Orcish Dreadnought","Orcish Farkiller"}}} },
    { name = "Castle Oztroja",         id = 1044, drops = {{zone="Castle Oztroja", mobs={"Mimic","Yagudo Assassin","Yagudo Conductor","Yagudo Flagellant","Yagudo Prelate"}}} },
    { name = "The Boyahda Tree",       id = 1052, drops = {{zone="The Boyahda Tree", mobs={"Bark Spider","Death Cap","Knight Crawler","Mimic","Moss Eater","Mourioche","Old Goobbue","Robber Crab"}}} },
    { name = "Temple of Uggalepih",    id = 1049, drops = {{zone="Temple of Uggalepih", mobs={"Hover Tank","Iron Maiden","Mimic","Temple Bee","Temple Guardian","Tonberry Dismayer","Tonberry Maledictor","Tonberry Pursuer","Tonberry Stabber"}}} },
    { name = "Den of Rancor",          id = 1050, drops = {{zone="Den of Rancor", mobs={"Bifrons","Cutlass Scorpion","Mimic","Mousse","Tonberry Beleaguerer","Tonberry Slasher","Tonberry Trailer"}}} },
    { name = "Castle Zvahl Baileys",   id = 1048, drops = {{zone="Castle Zvahl Baileys", mobs={"Abyssal Demon","Ahriman","Arch Demon","Blood Demon","Doom Demon","Mimic"}}} },
    { name = "Toraimarai Canal",       id = 1057, drops = {{zone="Toraimarai Canal", mobs={"Dire Bat","Doom Mage","Doom Soldier","Fleshcraver","Girtab","Mimic","Mindcraver","Mousse","Scavenger Crab","Starmite"}}} },
    { name = "Kuftal Tunnel",          id = 1051, drops = {{zone="Kuftal Tunnel", mobs={"Cave Worm","Deinonychus","Haunt","Mimic","Recluse Spider","Robber Crab","Sabotender Sediendo","Sand Lizard"}}} },
    { name = "Sea Serpent Grotto",     id = 1059, drops = {{zone="Sea Serpent Grotto", mobs={"Blubber Eyes","Bog Sahagin","Marsh Sahagin","Mimic","Razorjaw Pugil","Rock Crab","Swamp Sahagin"}}} },
    { name = "Velugannon Palace",      id = 1060, drops = {{zone="Velugannon Palace", mobs={"Detector","Dustbuster","Mimic","Mystic Weapon","Ornamental Weapon"}}} },
    { name = "The Eldieme Necropolis", id = 1046, drops = {{zone="The Eldieme Necropolis", mobs={"Haunt","Mimic","Spriggan","Tomb Mage","Tomb Warrior"}}} },
    { name = "Crawler's Nest",         id = 1045, drops = {{zone="Crawler's Nest", mobs={"Crawler Hunter","Helm Beetle","Knight Crawler","Mimic"}}} },
    { name = "Garlaige Citadel",       id = 1047, drops = {{zone="Garlaige Citadel", mobs={"Fallen Mage","Fallen Major","Hellmine","Magic Jug","Mimic","Over Weapon","Tainted Flesh","Vault Weapon","Wraith"}}} },
    { name = "Ifrit's Cauldron",       id = 1053, drops = {{zone="Ifrit's Cauldron", mobs={"Dire Bat","Dodomeki","Mimic","Old Opo-opo","Volcanic Gas","Volcano Wasp"}}} },
    { name = "Quicksand Caves",        id = 1054, drops = {{zone="Quicksand Caves", mobs={"Antican Hastatus","Antican Princeps","Antican Signifer","Helm Beetle","Mimic","Sabotender Bailaor","Sand Eater","Sand Lizard","Sand Spider"}}} },
};

------------------------------------------------------------
-- Inventory scan (reads Goblin Keyring item Extra data)
------------------------------------------------------------
local KEYRING_ID    = 3003;

local CONTAINERS = {
    { id = 0 }, { id = 1 }, { id = 2 }, { id = 4 }, { id = 5 },
    { id = 6 }, { id = 7 }, { id = 8 }, { id = 9 }, { id = 10 },
    { id = 11 }, { id = 12 }, { id = 13 }, { id = 14 }, { id = 15 }, { id = 16 },
};

local chestMask  = 0;
local cofferMask = 0;
local hasKeyring = false;
local lastScan   = 0;

local function checkBit(mask, pos)
    return bit.band(mask, bit.lshift(1, pos)) ~= 0;
end

local function scanKeyring()
    local now = os.clock();
    if now - lastScan < 2 then return; end
    lastScan = now;

    chestMask  = 0;
    cofferMask = 0;
    hasKeyring = false;

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return; end
    for _, c in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(c.id);
        if max ~= nil and max > 0 then
        for j = 0, max do
            local ok, item = pcall(function() return inventory:GetContainerItem(c.id, j); end);
            if not ok or item == nil then break; end
            if item.Id ~= 0 and item.Id ~= 65535 and item.Id == KEYRING_ID then
                hasKeyring = true;
                local extra = item.Extra;
                local b0 = struct.unpack('B', extra, 1);
                local b1 = struct.unpack('B', extra, 2);
                local b2 = struct.unpack('B', extra, 3);
                local b3 = struct.unpack('B', extra, 4);
                chestMask = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
                local c0 = struct.unpack('B', extra, 5);
                local c1 = struct.unpack('B', extra, 6);
                local c2 = struct.unpack('B', extra, 7);
                local c3 = struct.unpack('B', extra, 8);
                cofferMask = c0 + c1 * 256 + c2 * 65536 + c3 * 16777216;
                return;
            end
        end
        end -- max check
    end
end

------------------------------------------------------------
-- Layout constants
------------------------------------------------------------
local ICON_SIZE = 32;
local CELL_PAD  = 4;

-- Cell background colors (cached, rebuilt on theme change)
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
-- Render
------------------------------------------------------------
local function renderTooltip(entry, isOwned)
    ui.tooltip(function()
        renderIcon(entry.id, 32);
        imgui.SameLine(0, 6);
        imgui.BeginGroup();
        ui.colored(entry.name, 'white');
        if isOwned then
            ui.colored('  Obtained', 'green');
        end
        imgui.EndGroup();

        imgui.Separator();
        for _, drop in ipairs(entry.drops) do
            ui.colored(drop.zone, 'header');
            for _, mob in ipairs(drop.mobs) do
                ui.dim('  ' .. mob);
            end
        end
    end);
end

local ROW_H = ICON_SIZE + CELL_PAD + 2;

local function renderKeyRow(entry, bitIndex, mask, width)
    local isOwned = checkBit(mask, bitIndex);
    local cc = getCellColors();
    local bgCol = isOwned and cc.ownedBg or cc.cellBg;

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
    local cellId = string.format('##kr_%d', entry.id);
    imgui.BeginChild(cellId, { width, ROW_H }, true, bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

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

    imgui.EndChild();
    imgui.PopStyleColor();

    if imgui.IsItemHovered() then
        renderTooltip(entry, isOwned);
    end
end

------------------------------------------------------------
-- Window state
------------------------------------------------------------
local isOpen = { false };
local wasOpen = false;

------------------------------------------------------------
-- Main render (floating window)
------------------------------------------------------------
local PRISMATIC_KEY_ID = 9473;
local AETHER_KEY_ID   = 9472;

local function renderKeyCountHeader()
    -- Prismatic Key icon + count
    renderIcon(PRISMATIC_KEY_ID, 16);
    imgui.SameLine(0, 4);
    if keyCountsLoaded then
        imgui.TextColored({ 0.80, 0.55, 0.90, 1.0 }, tostring(keyCounts.prismatic));
    else
        imgui.TextColored({ 0.50, 0.50, 0.55, 1.0 }, '?');
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip(keyCountsLoaded
            and string.format('Prismatic Keys: %d\nUse at Aether Caskets (4 items)', keyCounts.prismatic)
            or 'Loading...');
    end

    imgui.SameLine(0, 14);

    -- Aether Key icon + count
    renderIcon(AETHER_KEY_ID, 16);
    imgui.SameLine(0, 4);
    if keyCountsLoaded then
        imgui.TextColored({ 0.55, 0.80, 0.90, 1.0 }, tostring(keyCounts.aether));
    else
        imgui.TextColored({ 0.50, 0.50, 0.55, 1.0 }, '?');
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip(keyCountsLoaded
            and string.format('Aether Keys: %d\nUse at Aether Caskets (3 items)', keyCounts.aether)
            or 'Loading...');
    end
end

local function renderWindow()
    if not isOpen[1] then
        wasOpen = false;
        return;
    end

    -- Request key counts on open and periodically while open
    if not wasOpen then
        wasOpen = true;
        requestKeyCounts();
    elseif keyCountsLoaded and not keyCountsLoading and os.clock() - keyCountsRequestTime > REFRESH_INTERVAL then
        requestKeyCounts();
    end

    -- Loading timeout
    if keyCountsLoading and os.clock() - keyCountsRequestTime > 5 then
        keyCountsLoading = false;
    end

    scanKeyring();

    local chestOwned  = 0;
    local cofferOwned = 0;
    for i = 1, #CHEST_KEYS do
        if checkBit(chestMask, i) then chestOwned = chestOwned + 1; end
    end
    for i = 1, #COFFER_KEYS do
        if checkBit(cofferMask, i) then cofferOwned = cofferOwned + 1; end
    end

    local title = string.format('Keyring [%d/%d]###trove_keyring',
        chestOwned + cofferOwned, #CHEST_KEYS + #COFFER_KEYS);

    imgui.SetNextWindowSize({ 560, 530 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 480, 300 }, { 700, 900 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin(title, isOpen, ImGuiWindowFlags_NoScrollbar) then
        local _bgPop = ui.renderBackground();
        if not hasKeyring then
            ui.dim('No Goblin Keyring found.');
        else
            -- Key count header (prismatic + aether)
            renderKeyCountHeader();
            imgui.Spacing();
            imgui.Separator();
            imgui.Spacing();
            local winW = imgui.GetWindowWidth();
            local colW = (winW - 24) / 2;

            -- Left column: Chest Keys
            imgui.BeginChild('##kr_chest', { colW, -1 }, false);
            ui.colored(string.format('Chest Keys (%d/%d)', chestOwned, #CHEST_KEYS), 'header');
            imgui.Separator();
            imgui.Spacing();
            for i, entry in ipairs(CHEST_KEYS) do
                renderKeyRow(entry, i, chestMask, -1);
            end
            imgui.EndChild();

            imgui.SameLine(0, 8);

            -- Right column: Coffer Keys
            imgui.BeginChild('##kr_coffer', { colW, -1 }, false);
            ui.colored(string.format('Coffer Keys (%d/%d)', cofferOwned, #COFFER_KEYS), 'header');
            imgui.Separator();
            imgui.Spacing();
            for i, entry in ipairs(COFFER_KEYS) do
                renderKeyRow(entry, i, cofferMask, -1);
            end
            imgui.EndChild();
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
    name        = 'Keyring',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Goblin Keyring chest/coffer key collection tracker',
    pluginId    = PLUGIN_ID,

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi, sharedRenderTooltip, sharedRenderFileIcon)
        renderIcon     = sharedRenderIcon;
        getItemRes     = sharedGetItemRes;
        ui             = sharedUi;
        renderFileIcon = sharedRenderFileIcon;
    end,

    window = {
        category = 'Utility',
        isOpen  = isOpen,
        render  = renderWindow,
        label   = 'Keyring',
        icon    = 3003,
        cwOnly  = true,
    },

    onRender = function(state)
        if not isOpen[1] then
            wasOpen = false;
        end
    end,

    onPluginData = function(rawData, state)
        local function u8(off)
            return struct.unpack('B', rawData, off + 1);
        end
        keyCounts.prismatic = u8(0x06) + u8(0x07) * 256;
        keyCounts.aether    = u8(0x08) + u8(0x09) * 256;
        keyCountsLoaded  = true;
        keyCountsLoading = false;
    end,
};
