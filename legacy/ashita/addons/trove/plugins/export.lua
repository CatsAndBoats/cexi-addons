--[[
* trove/plugins/export.lua — Inventory export plugin
*
* Panel-based export with configurable options. Scans all inventory containers
* and optionally includes Squire storage, job levels, merits, equipment details.
*
* Writes a dated Lua file to config/addons/trove/CharName_ServerId/YYYY-MM-DD.lua
*
* Command: /trove export
* Menu:    "Export Inventory"
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen = { false };

-- Options (imgui checkbox tables)
local OPT = {
    items       = { true },   -- scan inventory containers
    squire      = { true },   -- include squire items (if cached)
    jobs        = { true },   -- include job levels
    merits      = { true },   -- include merit points
    gearOnly    = { false },  -- only export equippable gear
    slots       = { true },   -- include equipment slot info per item
    jobsPerItem = { false },  -- include equippable jobs per item
    level       = { true },   -- include equip level per item
};

-- Status
local lastExport = nil;   -- { path, count, time }

------------------------------------------------------------
-- Constants
------------------------------------------------------------
local CONTAINERS = {
    { id = 0,  name = 'Inventory' },
    { id = 1,  name = 'Safe' },
    { id = 2,  name = 'Storage' },
    { id = 4,  name = 'Locker' },
    { id = 5,  name = 'Satchel' },
    { id = 6,  name = 'Sack' },
    { id = 7,  name = 'Case' },
    { id = 8,  name = 'Wardrobe' },
    { id = 9,  name = 'Safe 2' },
    { id = 10, name = 'Wardrobe 2' },
    { id = 11, name = 'Wardrobe 3' },
    { id = 12, name = 'Wardrobe 4' },
    { id = 13, name = 'Wardrobe 5' },
    { id = 14, name = 'Wardrobe 6' },
    { id = 15, name = 'Wardrobe 7' },
    { id = 16, name = 'Wardrobe 8' },
};

local JOB_ABBR = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM', [5]  = 'RDM',
    [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK', [9]  = 'BST', [10] = 'BRD',
    [11] = 'RNG', [12] = 'SAM', [13] = 'NIN', [14] = 'DRG', [15] = 'SMN',
    [16] = 'BLU', [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
};

local SLOT_NAMES = {
    [0x0001] = 'Main',  [0x0002] = 'Sub',   [0x0004] = 'Range',
    [0x0008] = 'Ammo',  [0x0010] = 'Head',  [0x0020] = 'Body',
    [0x0040] = 'Hands', [0x0080] = 'Legs',  [0x0100] = 'Feet',
    [0x0200] = 'Neck',  [0x0400] = 'Waist', [0x0800] = 'Ear',
    [0x1000] = 'Ring',  [0x2000] = 'Back',
};

local MERIT_CATEGORIES = {
    { base = 0x040, name = 'HP / MP' },
    { base = 0x080, name = 'Attributes' },
    { base = 0x0C0, name = 'Combat Skills' },
    { base = 0x100, name = 'Magic Skills' },
    { base = 0x140, name = 'Others' },
    { base = 0x180, name = 'WAR' },   { base = 0x1C0, name = 'MNK' },
    { base = 0x200, name = 'WHM' },   { base = 0x240, name = 'BLM' },
    { base = 0x280, name = 'RDM' },   { base = 0x2C0, name = 'THF' },
    { base = 0x300, name = 'PLD' },   { base = 0x340, name = 'DRK' },
    { base = 0x380, name = 'BST' },   { base = 0x3C0, name = 'BRD' },
    { base = 0x400, name = 'RNG' },   { base = 0x440, name = 'SAM' },
    { base = 0x480, name = 'NIN' },   { base = 0x4C0, name = 'DRG' },
    { base = 0x500, name = 'SMN' },   { base = 0x540, name = 'BLU' },
    { base = 0x580, name = 'COR' },   { base = 0x5C0, name = 'PUP' },
    { base = 0x600, name = 'DNC' },   { base = 0x640, name = 'SCH' },
    { base = 0x680, name = 'Weapon Skills' },
    { base = 0x6C0, name = 'GEO' },   { base = 0x700, name = 'RUN' },
    { base = 0x800, name = 'WAR 2' },  { base = 0x840, name = 'MNK 2' },
    { base = 0x880, name = 'WHM 2' },  { base = 0x8C0, name = 'BLM 2' },
    { base = 0x900, name = 'RDM 2' },  { base = 0x940, name = 'THF 2' },
    { base = 0x980, name = 'PLD 2' },  { base = 0x9C0, name = 'DRK 2' },
    { base = 0xA00, name = 'BST 2' },  { base = 0xA40, name = 'BRD 2' },
    { base = 0xA80, name = 'RNG 2' },  { base = 0xAC0, name = 'SAM 2' },
    { base = 0xB00, name = 'NIN 2' },  { base = 0xB40, name = 'DRG 2' },
    { base = 0xB80, name = 'SMN 2' },  { base = 0xBC0, name = 'BLU 2' },
    { base = 0xC00, name = 'COR 2' },  { base = 0xC40, name = 'PUP 2' },
    { base = 0xC80, name = 'DNC 2' },  { base = 0xCC0, name = 'SCH 2' },
    { base = 0xD40, name = 'GEO 2' },  { base = 0xD80, name = 'RUN 2' },
};

-- Merit ID -> name (from merit.h)
local MERIT_NAMES = {
    [0x040] = 'Max HP',       [0x042] = 'Max MP',       [0x044] = 'Max Merits',
    [0x080] = 'STR',          [0x082] = 'DEX',          [0x084] = 'VIT',
    [0x086] = 'AGI',          [0x088] = 'INT',          [0x08A] = 'MND',
    [0x08C] = 'CHR',
    [0x0C0] = 'H2H',          [0x0C2] = 'Dagger',       [0x0C4] = 'Sword',
    [0x0C6] = 'Great Sword',  [0x0C8] = 'Axe',          [0x0CA] = 'Great Axe',
    [0x0CC] = 'Scythe',       [0x0CE] = 'Polearm',      [0x0D0] = 'Katana',
    [0x0D2] = 'Great Katana', [0x0D4] = 'Club',         [0x0D6] = 'Staff',
    [0x0D8] = 'Archery',      [0x0DA] = 'Marksmanship',  [0x0DC] = 'Throwing',
    [0x0DE] = 'Guarding',     [0x0E0] = 'Evasion',      [0x0E2] = 'Shield',
    [0x0E4] = 'Parrying',
    [0x100] = 'Divine',        [0x102] = 'Healing',      [0x104] = 'Enhancing',
    [0x106] = 'Enfeebling',    [0x108] = 'Elemental',    [0x10A] = 'Dark',
    [0x10C] = 'Summoning',     [0x10E] = 'Ninjutsu',     [0x110] = 'Singing',
    [0x112] = 'String',        [0x114] = 'Wind',         [0x116] = 'Blue Magic',
    [0x118] = 'Geomancy',      [0x11A] = 'Handbell',
    [0x140] = 'Enmity+',       [0x142] = 'Enmity-',      [0x144] = 'Crit Rate',
    [0x146] = 'Enemy Crit',    [0x148] = 'Spell Interruption',
    [0x180] = 'Berserk Recast',     [0x182] = 'Defender Recast',   [0x184] = 'Warcry Recast',
    [0x186] = 'Aggressor Recast',   [0x188] = 'Double Attack Rate',
    [0x1C0] = 'Focus Recast',       [0x1C2] = 'Dodge Recast',     [0x1C4] = 'Chakra Recast',
    [0x1C6] = 'Counter Rate',       [0x1C8] = 'Kick Attack Rate',
    [0x200] = 'Divine Seal Recast',  [0x202] = 'Cure Cast Time',   [0x204] = 'Bar Spell Effect',
    [0x206] = 'Banish Effect',       [0x208] = 'Regen Effect',
    [0x240] = 'Ele Seal Recast',     [0x242] = 'Fire Potency',     [0x244] = 'Ice Potency',
    [0x246] = 'Wind Potency',        [0x248] = 'Earth Potency',    [0x24A] = 'Lightning Potency',
    [0x24C] = 'Water Potency',
    [0x280] = 'Convert Recast',      [0x282] = 'Fire M.Acc',       [0x284] = 'Ice M.Acc',
    [0x286] = 'Wind M.Acc',          [0x288] = 'Earth M.Acc',      [0x28A] = 'Lightning M.Acc',
    [0x28C] = 'Water M.Acc',
    [0x2C0] = 'Flee Recast',         [0x2C2] = 'Hide Recast',      [0x2C4] = 'SA Recast',
    [0x2C6] = 'TA Recast',           [0x2C8] = 'Triple Attack Rate',
    [0x300] = 'Shield Bash Recast',  [0x302] = 'Holy Circle Recast', [0x304] = 'Sentinel Recast',
    [0x306] = 'Cover Duration',      [0x308] = 'Rampart Recast',
    [0x340] = 'Souleater Recast',    [0x342] = 'Arcane Circle Recast', [0x344] = 'Last Resort Recast',
    [0x346] = 'Last Resort Effect',  [0x348] = 'Weapon Bash Effect',
    [0x380] = 'Killer Effects',      [0x382] = 'Reward Recast',     [0x384] = 'Call Beast Recast',
    [0x386] = 'Sic Recast',          [0x388] = 'Tame Recast',
    [0x3C0] = 'Lullaby Recast',     [0x3C2] = 'Finale Recast',     [0x3C4] = 'Minne Effect',
    [0x3C6] = 'Minuet Effect',      [0x3C8] = 'Madrigal Effect',
    [0x400] = 'Scavenge Effect',     [0x402] = 'Camouflage Recast', [0x404] = 'Sharpshot Recast',
    [0x406] = 'Unlimited Shot Recast', [0x408] = 'Rapid Shot Rate',
    [0x440] = 'Third Eye Recast',    [0x442] = 'Warding Circle Recast', [0x444] = 'Store TP',
    [0x446] = 'Meditate Recast',     [0x448] = 'Zanshin Rate',
    [0x480] = 'Subtle Blow Effect',  [0x482] = 'Katon Effect',      [0x484] = 'Hyoton Effect',
    [0x486] = 'Huton Effect',        [0x488] = 'Doton Effect',      [0x48A] = 'Raiton Effect',
    [0x48C] = 'Suiton Effect',
    [0x4C0] = 'Ancient Circle Recast', [0x4C2] = 'Jump Recast',    [0x4C4] = 'High Jump Recast',
    [0x4C6] = 'Super Jump Recast',   [0x4C8] = 'Spirit Link Recast',
    [0x500] = 'Avatar Phys Acc',     [0x502] = 'Avatar Phys Atk',   [0x504] = 'Avatar Mag Acc',
    [0x506] = 'Avatar Mag Atk',      [0x508] = 'Summoning Cast Time',
    [0x540] = 'Chain Affinity Recast', [0x542] = 'Burst Affinity Recast',
    [0x544] = 'Monster Correlation',   [0x546] = 'Physical Potency',
    [0x548] = 'Magical Accuracy',
    [0x580] = 'Phantom Roll Recast', [0x582] = 'Quick Draw Recast', [0x584] = 'Quick Draw Acc',
    [0x586] = 'Random Deal Recast',  [0x588] = 'Bust Duration',
    [0x5C0] = 'Automaton Skills',    [0x5C2] = 'Maintenance Recast', [0x5C4] = 'Repair Effect',
    [0x5C6] = 'Activate Recast',     [0x5C8] = 'Repair Recast',
    [0x600] = 'Step Accuracy',       [0x602] = 'Haste Samba Effect', [0x604] = 'Reverse Flourish',
    [0x606] = 'Building Flourish',
    [0x640] = 'Grimoire Recast',     [0x642] = 'Modus Veritas Duration',
    [0x644] = 'Helix MAcc/MAtk',    [0x646] = 'Max Sublimation',
    [0x680] = 'Shijin Spiral',  [0x682] = 'Exenterator',  [0x684] = 'Requiescat',
    [0x686] = 'Resolution',     [0x688] = 'Ruinator',     [0x68A] = 'Upheaval',
    [0x68C] = 'Entropy',        [0x68E] = 'Stardiver',    [0x690] = 'Blade: Shun',
    [0x692] = 'Tachi: Shoha',   [0x694] = 'Realmrazer',   [0x696] = 'Shattersoul',
    [0x698] = 'Apex Arrow',     [0x69A] = 'Last Stand',   [0x69C] = 'Expiacion',
    [0x69E] = 'Leaden Salute',
    [0x700] = 'Rune Enhance',       [0x702] = 'Vallation Effect',   [0x704] = 'Lunge Effect',
    [0x706] = 'Pflug Effect',       [0x708] = 'Gambit Effect',
    [0x800] = "Warrior's Charge",   [0x802] = 'Tomahawk',           [0x804] = 'Savagery',
    [0x806] = 'Aggressive Aim',
    [0x840] = 'Mantra',             [0x842] = 'Formless Strikes',   [0x844] = 'Invigorate',
    [0x846] = 'Penance',
    [0x880] = 'Martyr',             [0x882] = 'Devotion',           [0x884] = 'Protectra V',
    [0x886] = 'Shellra V',          [0x888] = 'Animus Solace',      [0x88A] = 'Animus Misery',
    [0x8C0] = 'Flare II',           [0x8C2] = 'Freeze II',          [0x8C4] = 'Tornado II',
    [0x8C6] = 'Quake II',           [0x8C8] = 'Burst II',           [0x8CA] = 'Flood II',
    [0x8CC] = 'Ancient Magic ATK',  [0x8CE] = 'Ancient Magic MB',   [0x8D0] = 'Ele Magic Acc',
    [0x8D2] = 'Ele Debuff Duration', [0x8D4] = 'Ele Debuff Effect', [0x8D6] = 'Aspir Absorption',
    [0x900] = 'Dia III',            [0x902] = 'Slow II',            [0x904] = 'Paralyze II',
    [0x906] = 'Phalanx II',         [0x908] = 'Bio III',            [0x90A] = 'Blind II',
    [0x90C] = 'Enfeebling Duration', [0x90E] = 'Magic Accuracy',    [0x910] = 'Enhancing Duration',
    [0x912] = 'Immunobreak Chance',  [0x914] = 'Enspell Damage',    [0x916] = 'Accuracy',
    [0x940] = "Assassin's Charge",  [0x942] = 'Feint',              [0x944] = 'Aura Steal',
    [0x946] = 'Ambush',
    [0x980] = 'Fealty',             [0x982] = 'Chivalry',           [0x984] = 'Iron Will',
    [0x986] = 'Guardian',
    [0x9C0] = 'Dark Seal',          [0x9C2] = 'Diabolic Eye',      [0x9C4] = 'Muted Soul',
    [0x9C6] = 'Desperate Blows',
    [0xA00] = 'Feral Howl',         [0xA02] = 'Killer Instinct',   [0xA04] = 'Beast Affinity',
    [0xA06] = 'Beast Healer',
    [0xA40] = 'Nightingale',        [0xA42] = 'Troubadour',        [0xA44] = 'Foe Sirvente',
    [0xA46] = "Adventurer's Dirge", [0xA48] = 'Con Anima',         [0xA4A] = 'Con Brio',
    [0xA80] = 'Stealth Shot',       [0xA82] = 'Flashy Shot',       [0xA84] = 'Snapshot',
    [0xA86] = 'Recycle',
    [0xAC0] = 'Shikikoyo',          [0xAC2] = 'Blade Bash',        [0xAC4] = 'Ikishoten',
    [0xAC6] = 'Overwhelm',
    [0xB00] = 'Sange',              [0xB02] = 'Ninja Tool Expertise',
    [0xB04] = 'Katon: San',         [0xB06] = 'Hyoton: San',       [0xB08] = 'Huton: San',
    [0xB0A] = 'Doton: San',         [0xB0C] = 'Raiton: San',       [0xB0E] = 'Suiton: San',
    [0xB10] = 'Yonin Effect',       [0xB12] = 'Innin Effect',
    [0xB14] = 'NIN Magic Acc',      [0xB16] = 'NIN Magic Bonus',
    [0xB40] = 'Deep Breathing',     [0xB42] = 'Angon',             [0xB44] = 'Empathy',
    [0xB46] = 'Strafe Effect',
    [0xB80] = 'Meteor Strike',      [0xB82] = 'Heavenly Strike',   [0xB84] = 'Wind Blade',
    [0xB86] = 'Geocrush',           [0xB88] = 'Thunderstorm',      [0xB8A] = 'Grand Fall',
    [0xBC0] = 'Convergence',        [0xBC2] = 'Diffusion',         [0xBC4] = 'Enchainment',
    [0xBC6] = 'Assimilation',
    [0xC00] = 'Snake Eye',          [0xC02] = 'Fold',              [0xC04] = 'Winning Streak',
    [0xC06] = 'Loaded Deck',
    [0xC40] = 'Role Reversal',      [0xC42] = 'Ventriloquy',       [0xC44] = 'Fine Tuning',
    [0xC46] = 'Optimization',
    [0xC80] = 'Saber Dance',        [0xC82] = 'Fan Dance',         [0xC84] = 'No Foot Rise',
    [0xC86] = 'Closed Position',
    [0xCC0] = 'Altruism',           [0xCC2] = 'Focalization',      [0xCC4] = 'Tranquility',
    [0xCC6] = 'Equanimity',         [0xCC8] = 'Enlightenment',     [0xCCA] = 'Stormsurge',
    [0xD40] = 'Mending Halation',   [0xD42] = 'Radial Arcana',     [0xD44] = 'Curative Recantation',
    [0xD46] = 'Primeval Zeal',
    [0xD80] = 'Battuta',            [0xD82] = 'Rayke',             [0xD84] = 'Inspiration',
    [0xD86] = 'Sleight of Sword',
};

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local cachedMerits = {};

local function extraToHex(extra)
    if extra == nil then return nil; end
    local parts = {};
    for i = 1, 28 do
        local ok, b = pcall(function() return struct.unpack('B', extra, i); end);
        if not ok then break; end
        parts[#parts + 1] = string.format('%02X', b);
    end
    local hex = table.concat(parts);
    if hex:match('^0+$') then return nil; end
    return hex;
end

local function escapeLua(s)
    return s:gsub('\\', '\\\\'):gsub("'", "\\'"):gsub('\n', '\\n');
end

local function isGear(res)
    if res == nil then return false; end
    return ((res.Slots or 0) > 0) or (bit.band(res.Flags or 0, 0x800) ~= 0);
end

local function getSlots(slots)
    local values = {};
    slots = slots or 0;
    for mask, name in pairs(SLOT_NAMES) do
        if bit.band(slots, mask) ~= 0 then
            values[#values + 1] = name;
        end
    end
    table.sort(values);
    return table.concat(values, '/');
end

local function getJobs(jobs)
    local values = {};
    jobs = jobs or 0;
    for id = 1, 22 do
        if bit.band(jobs, math.pow(2, id)) ~= 0 then
            values[#values + 1] = JOB_ABBR[id];
        end
    end
    table.sort(values);
    return table.concat(values, '/');
end

------------------------------------------------------------
-- Scan inventory
------------------------------------------------------------
local function scanContainers()
    local result = {};
    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return result; end
    local resmgr = AshitaCore:GetResourceManager();

    for _, c in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(c.id);
        if max ~= nil and max > 0 then
            for j = 1, max do
                local ok, item = pcall(function() return inventory:GetContainerItem(c.id, j); end);
                if ok and item ~= nil and item.Id ~= 0 and item.Id ~= 65535 then
                    local res = resmgr:GetItemById(item.Id);
                    if res ~= nil then
                        if not OPT.gearOnly[1] or isGear(res) then
                            local entry = {
                                id        = item.Id,
                                name      = res.Name[1] or 'unknown',
                                count     = item.Count or 1,
                                container = c.name,
                                extra     = extraToHex(item.Extra),
                            };
                            if OPT.slots[1] then
                                entry.slots = getSlots(res.Slots);
                            end
                            if OPT.jobsPerItem[1] then
                                local allJobs = 0x3FFFFF;
                                local j = res.Jobs or 0;
                                if j > 0 and j ~= allJobs then
                                    entry.jobs = getJobs(j);
                                elseif j == allJobs then
                                    entry.jobs = 'All Jobs';
                                end
                            end
                            if OPT.level[1] and res.Level and res.Level > 0 then
                                entry.level = res.Level;
                            end
                            result[#result + 1] = entry;
                        end
                    end
                end
            end
        end
    end

    return result;
end

------------------------------------------------------------
-- Read player info
------------------------------------------------------------
local function readMerits()
    local merits = {};
    for id, count in pairs(cachedMerits) do
        local name = MERIT_NAMES[id] or string.format('0x%03X', id);
        merits[#merits + 1] = { id = id, name = name, count = count };
    end
    table.sort(merits, function(a, b) return a.id < b.id; end);
    return merits;
end

local function getPlayerInfo()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if player == nil then return nil; end

    local info = {};

    if OPT.jobs[1] then
        local jobs = {};
        for id = 1, 22 do
            local level = player:GetJobLevel(id);
            if level > 0 then
                jobs[JOB_ABBR[id]] = level;
            end
        end

        local mainJob = player:GetMainJob();
        local subJob  = player:GetSubJob();

        info.mainJob = JOB_ABBR[mainJob] or '???';
        info.mainLvl = player:GetMainJobLevel();
        info.subJob  = JOB_ABBR[subJob] or '???';
        info.subLvl  = player:GetSubJobLevel();
        info.jobs    = jobs;
    end

    if OPT.merits[1] then
        info.merits = readMerits();
    end

    return info;
end

------------------------------------------------------------
-- Write the Lua file
------------------------------------------------------------
local function writeFile(items, info)
    local party    = AshitaCore:GetMemoryManager():GetParty();
    local name     = party:GetMemberName(0);
    local id       = party:GetMemberServerId(0);
    local dirName  = string.format('%s_%u', name, id);
    local dirPath  = string.format('%sconfig\\addons\\trove\\%s', AshitaCore:GetInstallPath(), dirName);
    local date     = os.date('%Y-%m-%d');
    local filePath = dirPath .. '\\' .. date .. '.lua';

    os.execute('mkdir "' .. dirPath .. '" 2>nul');

    local f = io.open(filePath, 'w');
    if f == nil then
        print(string.format('[trove] \30\71Error: could not write %s', filePath));
        lastExport = { path = filePath, count = 0, time = os.date('%H:%M:%S'), err = true };
        return;
    end

    f:write('-- Trove inventory export for ' .. name .. '\n');
    f:write('-- Generated: ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n');
    f:write('-- Usage: local data = loadfile(path)()\n');
    f:write('local data = {};\n\n');

    -- Player info
    if info then
        if info.mainJob then
            f:write(string.format("data.currentJob = '%s/%s %d/%d';\n",
                info.mainJob, info.subJob, info.mainLvl, info.subLvl));

            f:write('data.jobs = {');
            local first = true;
            for jid = 1, 22 do
                local abbr = JOB_ABBR[jid];
                if abbr and info.jobs[abbr] then
                    if not first then f:write(','); end
                    f:write(string.format(' %s = %d', abbr, info.jobs[abbr]));
                    first = false;
                end
            end
            f:write(' };\n');
        end

        if info.merits and #info.merits > 0 then
            f:write(string.format('data.merits = { -- %d spent\n', #info.merits));
            local lastCat = nil;
            for _, m in ipairs(info.merits) do
                local cat = nil;
                for i = #MERIT_CATEGORIES, 1, -1 do
                    if m.id >= MERIT_CATEGORIES[i].base then
                        cat = MERIT_CATEGORIES[i].name;
                        break;
                    end
                end
                if cat ~= lastCat then
                    f:write(string.format('    -- %s\n', cat or 'Unknown'));
                    lastCat = cat;
                end
                f:write(string.format("    ['%s'] = %d,\n", escapeLua(m.name), m.count));
            end
            f:write('};\n');
        end

        f:write('\n');
    end

    -- Items grouped by container
    f:write('data.items = {\n');
    local containers = {};
    local order = {};
    for _, item in ipairs(items) do
        local c = item.container;
        if not containers[c] then
            containers[c] = {};
            order[#order + 1] = c;
        end
        table.insert(containers[c], item);
    end

    for _, cName in ipairs(order) do
        f:write(string.format("    ['%s'] = {\n", escapeLua(cName)));
        for _, item in ipairs(containers[cName]) do
            f:write('        { ');
            f:write(string.format("id = %d, name = '%s'", item.id, escapeLua(item.name)));
            if item.count > 1 then
                f:write(string.format(', count = %d', item.count));
            end
            if item.extra then
                f:write(string.format(", extra = '%s'", item.extra));
            end
            if item.slots and item.slots ~= '' then
                f:write(string.format(", slots = '%s'", item.slots));
            end
            if item.jobs and item.jobs ~= '' then
                f:write(string.format(", jobs = '%s'", item.jobs));
            end
            if item.level then
                f:write(string.format(', level = %d', item.level));
            end
            if item.squire then
                f:write(', squire = true');
                if item.category then
                    f:write(string.format(", category = '%s'", escapeLua(item.category)));
                end
                if item.tier then
                    f:write(string.format(", tier = '%s'", escapeLua(item.tier)));
                end
            end
            f:write(' },\n');
        end
        f:write('    },\n');
    end

    f:write('};\n\n');
    f:write('return data;\n');
    f:close();

    print(string.format('[trove] \30\02Exported %d items to %s', #items, filePath));
    lastExport = { path = filePath, count = #items, time = os.date('%H:%M:%S') };
end

------------------------------------------------------------
-- Main export
------------------------------------------------------------
local function doExport(state)
    print('[trove] Scanning containers...');
    local items = scanContainers();
    print(string.format('[trove] Found %d items in containers.', #items));

    -- Append squire items if cached
    if OPT.squire[1] and state.squireLoaded and #state.squire > 0 then
        local seen = {};
        for _, item in ipairs(items) do
            seen[item.name:lower()] = true;
        end

        local count = 0;
        for _, sq in ipairs(state.squire) do
            local key = sq.name:lower();
            if not seen[key] then
                seen[key] = true;
                local itemId = 0;
                local res = AshitaCore:GetResourceManager():GetItemByName(sq.name, 0);
                if res ~= nil then itemId = res.Id; end

                items[#items + 1] = {
                    id        = itemId,
                    name      = sq.name,
                    count     = 1,
                    container = 'Squire',
                    squire    = true,
                    category  = sq.category,
                    tier      = sq.tier,
                };
                count = count + 1;
            end
        end

        if count > 0 then
            print(string.format('[trove] \30\02Included %d items from Squire cache.', count));
        end
    elseif OPT.squire[1] then
        print('[trove] \30\76Squire data not cached. Browse the Squire tab first to include Squire items.');
    end

    writeFile(items, getPlayerInfo());
end

------------------------------------------------------------
-- Window rendering
------------------------------------------------------------
local _troveState = nil;

local function renderWindow()
    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 300, 0 }, ImGuiCond_FirstUseEver);
    if imgui.Begin('Trove Export##trove_export', isOpen, ImGuiWindowFlags_AlwaysAutoResize) then
        local _bgPop = ui.renderBackground();

        ui.header('Include');
        imgui.Spacing();

        imgui.Checkbox('Inventory Items', OPT.items);
        imgui.Checkbox('Squire Storage', OPT.squire);
        imgui.Checkbox('Job Levels', OPT.jobs);
        imgui.Checkbox('Merits', OPT.merits);
        if OPT.merits[1] and next(cachedMerits) == nil then
            imgui.SameLine(0, 8);
            ui.dim('(zone once to populate)');
        end

        imgui.Spacing();
        imgui.Spacing();
        ui.header('Item Details');
        imgui.Spacing();

        imgui.Checkbox('Equipment Slots', OPT.slots);
        imgui.Checkbox('Equip Level', OPT.level);
        imgui.Checkbox('Jobs Per Item', OPT.jobsPerItem);

        imgui.Spacing();
        imgui.Spacing();
        ui.header('Filter');
        imgui.Spacing();

        imgui.Checkbox('Gear Only', OPT.gearOnly);
        if OPT.gearOnly[1] then
            imgui.SameLine(0, 8);
            ui.dim('(equipment + weapons)');
        end

        -- Export button
        imgui.Spacing();
        imgui.Spacing();
        imgui.Separator();
        imgui.Spacing();

        local btnW = imgui.GetContentRegionAvail();
        if ui.button('Export', 'primary', { btnW, 28 }) then
            -- doExport needs trove state — stored on first render call
            if _troveState then
                doExport(_troveState);
            else
                print('[trove] \30\71Export not ready - open Trove first.');
            end
        end

        -- Last export status
        if lastExport then
            imgui.Spacing();
            if lastExport.err then
                ui.status('Failed to write file', 'error');
            else
                ui.dim(string.format('Exported %d items at %s', lastExport.count, lastExport.time));
            end
        end
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Export',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Export inventory, jobs, and merits to a Lua file',

    init = function(iconFn, itemResFn, uiModule)
        renderIcon = iconFn;
        getItemRes = itemResFn;
        ui = uiModule;
    end,

    commands = {
        export = function(state)
            _troveState = state;
            doExport(state);
        end,
    },


    onRender = function(state)
        _troveState = state;
    end,

    onPacketIn = function(e, state)
        if e.id == 0x08C then
            local meritCount = struct.unpack('B', e.data, 0x04 + 1);
            for i = 1, meritCount do
                local id    = struct.unpack('H', e.data, 0x04 + (4 * i) + 1);
                local count = struct.unpack('B', e.data, 0x04 + (4 * i) + 4);
                if count > 0 then
                    cachedMerits[id] = count;
                end
            end
        end
    end,

    window = {
        category = 'Account',
        isOpen = isOpen,
        label  = 'Export',
        icon   = 1686, -- Soiled Letter
        render = renderWindow,
        bottom = true,
    },
};
