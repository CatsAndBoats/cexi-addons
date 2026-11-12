--[[
* keyring - Goblin Keyring panel for Trove
*
* Shows chest and coffer key collection status read from item Extra data.
* Greyed out icons for missing keys, coloured for obtained.
* Tooltips show drop zone(s).
]]--

local imgui = require('imgui');

local panel = {};
panel.isOpen     = { false };
panel.renderIcon = nil;
panel.getItemRes = nil;

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
local CHEST_OFFSET  = 0;
local COFFER_OFFSET = 4;

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
-- Colors
------------------------------------------------------------
local COLORS = {
    ownedBg    = { 0.18, 0.38, 0.18, 1.0  },
    cellBg     = { 0.14, 0.12, 0.20, 1.0  },
    dimText    = { 0.60, 0.52, 0.70, 1.0  },
    white      = { 1.0,  1.0,  1.0,  1.0  },
    green      = { 0.40, 1.00, 0.40, 1.0  },
    sectionHdr = { 0.75, 0.65, 0.90, 1.0  },
    tooltipBg  = { 0.12, 0.10, 0.18, 0.95 },
};

local ICON_SIZE = 32;
local CELL_PAD  = 4;

------------------------------------------------------------
-- Render
------------------------------------------------------------
local function renderTooltip(entry, owned)
    imgui.PushStyleColor(ImGuiCol_PopupBg, COLORS.tooltipBg);
    imgui.BeginTooltip();

    panel.renderIcon(entry.id, 32);
    imgui.SameLine(0, 6);
    imgui.BeginGroup();
    imgui.PushStyleColor(ImGuiCol_Text, COLORS.white);
    imgui.Text(entry.name);
    imgui.PopStyleColor();
    if owned then
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.green);
        imgui.Text('  Obtained');
        imgui.PopStyleColor();
    end
    imgui.EndGroup();

    imgui.Separator();
    for _, drop in ipairs(entry.drops) do
        imgui.PushStyleColor(ImGuiCol_Text, COLORS.sectionHdr);
        imgui.Text(drop.zone);
        imgui.PopStyleColor();
        for _, mob in ipairs(drop.mobs) do
            imgui.PushStyleColor(ImGuiCol_Text, COLORS.dimText);
            imgui.Text('  ' .. mob);
            imgui.PopStyleColor();
        end
    end

    imgui.EndTooltip();
    imgui.PopStyleColor();
end

local ROW_H = ICON_SIZE + CELL_PAD + 2;

local function renderKeyRow(entry, bitIndex, mask, width)
    local owned = checkBit(mask, bitIndex);
    local bgCol = owned and COLORS.ownedBg or COLORS.cellBg;

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
    local cellId = string.format('##kr_%d', entry.id);
    imgui.BeginChild(cellId, { width, ROW_H }, true, bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

    imgui.SetCursorPos({ CELL_PAD, CELL_PAD });
    if not panel.renderIcon(entry.id, ICON_SIZE) then
        imgui.Dummy({ ICON_SIZE, ICON_SIZE });
    end

    imgui.SameLine(0, 6);
    imgui.SetCursorPosY(CELL_PAD + (ICON_SIZE - 14) / 2);
    if owned then
        imgui.TextColored(COLORS.green, entry.name);
    else
        imgui.TextColored(COLORS.dimText, entry.name);
    end

    imgui.EndChild();
    imgui.PopStyleColor();

    if imgui.IsItemHovered() then
        renderTooltip(entry, owned);
    end
end

function panel.render()
    if not panel.isOpen[1] then return; end

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

    imgui.SetNextWindowSize({ 560, 500 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 480, 300 }, { 700, 900 });

    imgui.PushStyleColor(ImGuiCol_TitleBg,         { 0.14, 0.10, 0.22, 0.95 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,    { 0.22, 0.16, 0.32, 0.95 });
    imgui.PushStyleColor(ImGuiCol_WindowBg,         { 0.10, 0.08, 0.14, 0.92 });
    imgui.PushStyleColor(ImGuiCol_Border,           { 0.35, 0.25, 0.50, 0.60 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg,        { 0.06, 0.05, 0.09, 0.50 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab,     { 0.30, 0.20, 0.45, 0.60 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabHovered, { 0.40, 0.30, 0.55, 0.80 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabActive,  { 0.50, 0.38, 0.65, 1.00 });

    if imgui.Begin(title, panel.isOpen, ImGuiWindowFlags_NoScrollbar) then
        if not hasKeyring then
            imgui.TextColored(COLORS.dimText, 'No Goblin Keyring found.');
        else
            local winW = imgui.GetWindowWidth();
            local colW = (winW - 24) / 2;

            -- Left column: Chest Keys
            imgui.BeginChild('##kr_chest', { colW, -1 }, false);
            imgui.TextColored(COLORS.sectionHdr, string.format('Chest Keys (%d/%d)', chestOwned, #CHEST_KEYS));
            imgui.Separator();
            imgui.Spacing();
            for i, entry in ipairs(CHEST_KEYS) do
                renderKeyRow(entry, i, chestMask, -1);
            end
            imgui.EndChild();

            imgui.SameLine(0, 8);

            -- Right column: Coffer Keys
            imgui.BeginChild('##kr_coffer', { colW, -1 }, false);
            imgui.TextColored(COLORS.sectionHdr, string.format('Coffer Keys (%d/%d)', cofferOwned, #COFFER_KEYS));
            imgui.Separator();
            imgui.Spacing();
            for i, entry in ipairs(COFFER_KEYS) do
                renderKeyRow(entry, i, cofferMask, -1);
            end
            imgui.EndChild();
        end
    end
    imgui.End();
    imgui.PopStyleColor(8);
end

return panel;
