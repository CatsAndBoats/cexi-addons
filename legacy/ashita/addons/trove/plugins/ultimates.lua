--[[
* trove/plugins/ultimates.lua — Ultimate Weapon Progress Tracker
*
* Shows progress toward relic, mythic, and empyrean weapons based on
* dynamis currency. Completion detected via item ownership.
*
* Command: /trove ultimates
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;
local renderTooltip = nil;
local renderFileIcon = nil;

------------------------------------------------------------
-- Currency item IDs and denominations
------------------------------------------------------------
local CURRENCY = {
    -- Byne Bills (base unit = 1 One Byne Bill)
    BYNE = {
        name  = 'Byne Bills',
        icon  = 1455, -- One Byne Bill
        color = { 1.00, 0.78, 0.35, 1.00 }, -- amber
        barFill = { 0.70, 0.55, 0.20, 0.65 }, -- darker fill for readability
    },
    -- Whiteshells (base unit = 1 Tukuku Whiteshell)
    SHELL = {
        name  = 'Whiteshells',
        icon  = 1449, -- Tukuku Whiteshell
        color = { 0.55, 0.85, 1.00, 1.00 }, -- light blue
        barFill = { 0.25, 0.50, 0.65, 0.65 },
    },
    -- Bronzepieces (base unit = 1 Ordelle Bronzepiece)
    BRONZE = {
        name  = 'Bronzepieces',
        icon  = 1452, -- Ordelle Bronzepiece
        color = { 0.85, 0.60, 0.40, 1.00 }, -- bronze
        barFill = { 0.55, 0.35, 0.18, 0.65 },
    },
};

------------------------------------------------------------
-- Relic weapon definitions (16 weapons, 4 stages each)
-- Each stage: { weaponId, currencyType, currencyAmount (in base units) }
-- currencyAmount is already normalized to base denomination
------------------------------------------------------------
-- Stage weapon IDs verified against scripts/enum/item.lua
-- Pattern: base(+0), stage1(+1), stage2(+2), stage3(+3), penultimate(+3), final_75(+4)
-- Each relic: Relic(base) → Militant/etc(stage1) → Dynamis(stage2) → Penultimate(stage3) → Final_75
local RELICS = {
    {
        name = 'Spharai', finalId = 18264, job = 'MNK',
        stages = {
            { weaponId = 18261, currency = 'BYNE',   amount = 400 },   -- Militant Knuckles
            { weaponId = 18262, currency = 'BRONZE', amount = 1400 },  -- Dynamis Knuckles
            { weaponId = 18263, currency = 'SHELL',  amount = 6100 },  -- Caestus
            { weaponId = 18264, currency = 'BYNE',   amount = 10000 }, -- Spharai
        },
    },
    {
        name = 'Mandau', finalId = 18270, job = 'THF',
        stages = {
            { weaponId = 18267, currency = 'BYNE',   amount = 400 },   -- Malefic Dagger
            { weaponId = 18268, currency = 'BRONZE', amount = 1400 },  -- Dynamis Dagger
            { weaponId = 18269, currency = 'SHELL',  amount = 6100 },  -- Batardeau
            { weaponId = 18270, currency = 'BYNE',   amount = 10000 }, -- Mandau
        },
    },
    {
        name = 'Excalibur', finalId = 18276, job = 'PLD',
        stages = {
            { weaponId = 18273, currency = 'BRONZE', amount = 400 },   -- Glyptic Sword
            { weaponId = 18274, currency = 'BYNE',   amount = 1400 },  -- Dynamis Sword
            { weaponId = 18275, currency = 'SHELL',  amount = 6100 },  -- Caliburn
            { weaponId = 18276, currency = 'BRONZE', amount = 10000 }, -- Excalibur
        },
    },
    {
        name = 'Ragnarok', finalId = 18282, job = 'DRK',
        stages = {
            { weaponId = 18279, currency = 'BRONZE', amount = 400 },   -- Gilded Blade
            { weaponId = 18280, currency = 'SHELL',  amount = 1600 },  -- Dynamis Blade
            { weaponId = 18281, currency = 'BYNE',   amount = 6100 },  -- Valhalla
            { weaponId = 18282, currency = 'BRONZE', amount = 10000 }, -- Ragnarok
        },
    },
    {
        name = 'Guttler', finalId = 18288, job = 'BST',
        stages = {
            { weaponId = 18285, currency = 'SHELL',  amount = 300 },   -- Leonine Axe
            { weaponId = 18286, currency = 'BRONZE', amount = 1400 },  -- Dynamis Axe
            { weaponId = 18287, currency = 'BYNE',   amount = 6000 },  -- Ogre Killer
            { weaponId = 18288, currency = 'SHELL',  amount = 10000 }, -- Guttler
        },
    },
    {
        name = 'Bravura', finalId = 18294, job = 'WAR',
        stages = {
            { weaponId = 18291, currency = 'BYNE',   amount = 300 },   -- Agonal Bhuj
            { weaponId = 18292, currency = 'SHELL',  amount = 1600 },  -- Dynamis Bhuj
            { weaponId = 18293, currency = 'BRONZE', amount = 6000 },  -- Abaddon Killer
            { weaponId = 18294, currency = 'BYNE',   amount = 10000 }, -- Bravura
        },
    },
    {
        name = 'Gungnir', finalId = 18300, job = 'DRG',
        stages = {
            { weaponId = 18297, currency = 'SHELL',  amount = 400 },   -- Hotspur Lance
            { weaponId = 18298, currency = 'BYNE',   amount = 1600 },  -- Dynamis Lance
            { weaponId = 18299, currency = 'BRONZE', amount = 6100 },  -- Gae Assail
            { weaponId = 18300, currency = 'SHELL',  amount = 10000 }, -- Gungnir
        },
    },
    {
        name = 'Apocalypse', finalId = 18306, job = 'DRK',
        stages = {
            { weaponId = 18303, currency = 'SHELL',  amount = 500 },   -- Memento Scythe
            { weaponId = 18304, currency = 'BRONZE', amount = 1600 },  -- Dynamis Scythe
            { weaponId = 18305, currency = 'BYNE',   amount = 6200 },  -- Bec de Faucon
            { weaponId = 18306, currency = 'SHELL',  amount = 10000 }, -- Apocalypse
        },
    },
    {
        name = 'Kikoku', finalId = 18312, job = 'NIN',
        stages = {
            { weaponId = 18309, currency = 'BYNE',   amount = 400 },   -- Mimizuku
            { weaponId = 18310, currency = 'SHELL',  amount = 1600 },  -- Rogetsu
            { weaponId = 18311, currency = 'BRONZE', amount = 6100 },  -- Yoshimitsu
            { weaponId = 18312, currency = 'BYNE',   amount = 10000 }, -- Kikoku
        },
    },
    {
        name = 'Amanomurakumo', finalId = 18318, job = 'SAM',
        stages = {
            { weaponId = 18315, currency = 'BRONZE', amount = 300 },   -- Hayatemaru
            { weaponId = 18316, currency = 'SHELL',  amount = 1500 },  -- Oboromaru
            { weaponId = 18317, currency = 'BYNE',   amount = 6000 },  -- Totsukanotsurugi
            { weaponId = 18318, currency = 'BRONZE', amount = 10000 }, -- Amanomurakumo
        },
    },
    {
        name = 'Mjollnir', finalId = 18324, job = 'WHM',
        stages = {
            { weaponId = 18321, currency = 'BRONZE', amount = 500 },   -- Battering Maul
            { weaponId = 18322, currency = 'BYNE',   amount = 1600 },  -- Dynamis Maul
            { weaponId = 18323, currency = 'SHELL',  amount = 6200 },  -- Gullintani
            { weaponId = 18324, currency = 'BRONZE', amount = 10000 }, -- Mjollnir
        },
    },
    {
        name = 'Claustrum', finalId = 18330, job = 'BLM',
        stages = {
            { weaponId = 18327, currency = 'SHELL',  amount = 500 },   -- Sages Staff
            { weaponId = 18328, currency = 'BYNE',   amount = 1600 },  -- Dynamis Staff
            { weaponId = 18329, currency = 'BRONZE', amount = 6200 },  -- Thyrus
            { weaponId = 18330, currency = 'SHELL',  amount = 10000 }, -- Claustrum
        },
    },
    {
        name = 'Annihilator', finalId = 18336, job = 'RNG',
        stages = {
            { weaponId = 18333, currency = 'BYNE',   amount = 500 },   -- Marksmans Gun
            { weaponId = 18334, currency = 'SHELL',  amount = 1500 },  -- Dynamis Gun
            { weaponId = 18335, currency = 'BRONZE', amount = 6200 },  -- Ferdinand
            { weaponId = 18336, currency = 'BYNE',   amount = 10000 }, -- Annihilator
        },
    },
    {
        name = 'Gjallarhorn', finalId = 18342, job = 'BRD',
        stages = {
            { weaponId = 18339, currency = 'SHELL',  amount = 300 },   -- Pyrrhic Horn
            { weaponId = 18340, currency = 'BYNE',   amount = 1400 },  -- Dynamis Horn
            { weaponId = 18341, currency = 'BRONZE', amount = 6000 },  -- Millennium Horn
            { weaponId = 18342, currency = 'SHELL',  amount = 10000 }, -- Gjallarhorn
        },
    },
    {
        name = 'Yoichinoyumi', finalId = 18348, job = 'RNG',
        stages = {
            { weaponId = 18345, currency = 'BRONZE', amount = 400 },   -- Wolver Bow
            { weaponId = 18346, currency = 'BRONZE', amount = 1500 },  -- Dynamis Bow
            { weaponId = 18347, currency = 'SHELL',  amount = 6100 },  -- Futatokoroto
            { weaponId = 18348, currency = 'BRONZE', amount = 10000 }, -- Yoichinoyumi
        },
    },
    {
        name = 'Aegis', finalId = 15070, job = 'PLD',
        stages = {
            { weaponId = 15067, currency = 'BYNE',   amount = 100,  extraCurrency = { { 'BRONZE', 100 }, { 'SHELL', 100 } } },   -- Bulwark Shield
            { weaponId = 15068, currency = 'BYNE',   amount = 400,  extraCurrency = { { 'BRONZE', 400 }, { 'SHELL', 400 } } },   -- Dynamis Shield
            { weaponId = 15069, currency = 'BYNE',   amount = 2000, extraCurrency = { { 'BRONZE', 2000 }, { 'SHELL', 2000 } } }, -- Ancile
            { weaponId = 15070, currency = 'BRONZE', amount = 10000 }, -- Aegis
        },
    },
};

------------------------------------------------------------
-- Extra progression cards (fill the 3-column grid)
------------------------------------------------------------
local EXTRA_CARDS = {
    {
        name       = 'Mythic',
        icon       = 18993, -- Yagrush
        currency   = 'Alexandrite',
        target     = 30000,
        color      = { 0.70, 0.90, 0.50, 1.00 }, -- lime green
        barFill    = { 0.35, 0.50, 0.20, 0.65 },
        materials  = {
            { id = 3066, name = "Medusa's Brassard" },
            { id = 3067, name = "Gurfurlur's Morion" },
            { id = 3068, name = "Ja Ja's Plastron" },
        },
    },
    {
        name       = 'Ergon',
        icon       = 21685, -- Epeolatry
        currency   = 'H-P Bayld',
        target     = 10000,
        color      = { 0.80, 0.55, 0.90, 1.00 }, -- purple
        barFill    = { 0.40, 0.25, 0.50, 0.65 },
        materialRows = {
            {
                items = {
                    { id = 3980, name = 'Bztavian Stinger' },
                    { id = 3979, name = 'Rockfin Tooth' },
                    { id = 3977, name = 'Gabbrath Horn' },
                    { id = 4015, name = 'Yggdreant Root' },
                    { id = 4013, name = 'Waktza Crest' },
                    { id = 8754, name = 'Cehuetzi Pelt' },
                },
            },
            {
                items = {
                    { id = 3981, name = 'Bztavian Wing' },
                    { id = 3978, name = 'Rockfin Fin' },
                    { id = 6068, name = 'Gabbrath Meat' },
                    { id = 4014, name = 'Yggdreant Bole' },
                    { id = 4012, name = 'Waktza Rostrum' },
                    { id = 8752, name = 'Cehuetzi Claw' },
                },
            },
        },
        -- Extra column: Domain NM materials (displayed right of rows in L-shape)
        sideColumn = {
            { id = 9506, name = 'Amphisbaena Hide' },
            { id = 9510, name = 'Battosai Fang' },
            { id = 9511, name = 'Tortuga Shell' },
        },
    },
};

------------------------------------------------------------
-- Inventory containers to scan
-- Forward declaration (populated later, after CONTAINERS)
local INCURSION_ZONES;

------------------------------------------------------------
local CONTAINERS = {
    0,  -- Inventory
    1,  -- Safe
    2,  -- Storage
    4,  -- Locker
    5,  -- Satchel
    6,  -- Sack
    7,  -- Case
    8,  -- Wardrobe
    9,  -- Safe 2
    10, 11, 12, 13, 14, 15, 16, -- Wardrobes 2-8
};

------------------------------------------------------------
-- Currency name → internal type mapping
------------------------------------------------------------
local CURRENCY_NAME_MAP = {
    ['Byne Bills']   = 'BYNE',
    ['Whiteshells']  = 'SHELL',
    ['Bronzepieces'] = 'BRONZE',
};

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen       = { false };
local scanned      = false;
local currencyHave = { BYNE = 0, SHELL = 0, BRONZE = 0 };
local ownedItems   = {}; -- [itemId] = true
local itemCounts   = {}; -- [itemId] = count (for materials that need quantities)
local troveState   = nil; -- reference to main trove state (for currency data)

------------------------------------------------------------
-- Read currency totals from the Currency tab data (server-provided)
------------------------------------------------------------
local function readCurrencyFromState()
    currencyHave = { BYNE = 0, SHELL = 0, BRONZE = 0 };

    if not troveState or not troveState.currency then return; end

    for _, entry in ipairs(troveState.currency) do
        local cType = CURRENCY_NAME_MAP[entry.name];
        if cType then
            currencyHave[cType] = entry.total or 0;
        end
    end
end

------------------------------------------------------------
-- Scan inventory containers for relic weapon ownership
------------------------------------------------------------
local function scanWeapons()
    ownedItems = {};
    itemCounts = {};

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if not inventory then
        scanned = true;
        return;
    end

    -- Build lookup of all relic weapon IDs + extra material IDs + incursion IDs
    local weaponLookup = {};

    -- Incursion weapons (INCURSION_ZONES defined later, checked lazily)
    if INCURSION_ZONES then
        for _, zone in ipairs(INCURSION_ZONES) do
            for _, wpn in ipairs(zone.weapons) do
                weaponLookup[wpn.id] = true;
                weaponLookup[wpn.mat] = true; -- material item for quantity counting
                for _, phase in ipairs(wpn.phases) do
                    weaponLookup[phase.result] = true;
                    for _, reqId in ipairs(phase.reqs) do
                        weaponLookup[reqId] = true;
                    end
                end
            end
        end
    end
    for _, relic in ipairs(RELICS) do
        for _, stage in ipairs(relic.stages) do
            weaponLookup[stage.weaponId] = true;
        end
        weaponLookup[relic.finalId] = true;
    end
    for _, card in ipairs(EXTRA_CARDS) do
        if card.materials then
            for _, mat in ipairs(card.materials) do
                weaponLookup[mat.id] = true;
            end
        end
        if card.materialRows then
            for _, row in ipairs(card.materialRows) do
                for _, mat in ipairs(row.items) do
                    weaponLookup[mat.id] = true;
                end
            end
        end
        if card.sideColumn then
            for _, mat in ipairs(card.sideColumn) do
                weaponLookup[mat.id] = true;
            end
        end
    end

    for _, containerId in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(containerId);
        if max and max > 0 then
            for j = 0, max do
                local ok, item = pcall(function() return inventory:GetContainerItem(containerId, j); end);
                if ok and item and item.Id ~= 0 and item.Id ~= 65535 then
                    if weaponLookup[item.Id] then
                        ownedItems[item.Id] = true;
                        itemCounts[item.Id] = (itemCounts[item.Id] or 0) + (item.Count or 1);
                    end
                end
            end
        end
    end

    scanned = true;
end

------------------------------------------------------------
-- Full rescan: currency from server data + weapons from memory
------------------------------------------------------------
local function rescan()
    readCurrencyFromState();
    scanWeapons();
end

------------------------------------------------------------
-- Get completion stage for a relic (0 = none, 1-4 = stages)
------------------------------------------------------------
local function getCompletionStage(relic)
    -- Check final weapon first (the Lv75 relic itself)
    if ownedItems[relic.finalId] then
        return #relic.stages;
    end
    -- Check from highest stage down
    for s = #relic.stages, 1, -1 do
        if ownedItems[relic.stages[s].weaponId] then
            return s;
        end
    end
    return 0;
end

------------------------------------------------------------
-- Calculate total currency needed per type for a relic
------------------------------------------------------------
local function getTotalNeeded(relic)
    local needed = { BYNE = 0, SHELL = 0, BRONZE = 0 };
    for _, stage in ipairs(relic.stages) do
        needed[stage.currency] = needed[stage.currency] + stage.amount;
        if stage.extraCurrency then
            for _, extra in ipairs(stage.extraCurrency) do
                needed[extra[1]] = needed[extra[1]] + extra[2];
            end
        end
    end
    return needed;
end

------------------------------------------------------------
-- Render: progress bar
------------------------------------------------------------
local function renderProgressBar(cDef, have, need, width)
    local pct = need > 0 and math.min(have / need, 1.0) or 0;
    local barH = 16;
    local iconSize = 14;

    local dl = imgui.GetWindowDrawList();
    local cx, cy = imgui.GetCursorScreenPos();

    -- Icon left of bar
    imgui.SetCursorPosX(imgui.GetCursorPosX());
    renderIcon(cDef.icon, iconSize);
    imgui.SameLine(0, 4);
    local bx, by = imgui.GetCursorScreenPos();

    local barW = width - iconSize - 8;

    -- Background
    dl:AddRectFilled({ bx, by }, { bx + barW, by + barH },
        imgui.GetColorU32({ 0.06, 0.06, 0.09, 0.90 }), 3);

    -- Fill (darker tint for text readability)
    if pct > 0 then
        dl:AddRectFilled({ bx, by }, { bx + barW * pct, by + barH },
            imgui.GetColorU32(cDef.barFill), 3);
    end

    -- Border
    dl:AddRect({ bx, by }, { bx + barW, by + barH },
        imgui.GetColorU32({ 1, 1, 1, 0.06 }), 3);

    -- Fraction text centered in bar (shadow + foreground for readability)
    local fracStr = string.format('%s / %s', tostring(math.min(have, need)), tostring(need));
    local fracW = imgui.CalcTextSize(fracStr);
    local tx = bx + (barW - fracW) / 2;

    dl:AddText({ tx + 1, by + 2 }, imgui.GetColorU32({ 0, 0, 0, 0.80 }), fracStr);
    dl:AddText({ tx, by + 1 }, imgui.GetColorU32({ 1.0, 1.0, 1.0, 0.95 }), fracStr);

    imgui.Dummy({ width, barH + 2 });
end

------------------------------------------------------------
-- Render: single relic weapon card
------------------------------------------------------------
local function renderRelicCard(relic, index, cardW)
    local completion = getCompletionStage(relic);
    local isComplete = (completion >= #relic.stages);
    local needed = getTotalNeeded(relic);

    -- Calculate overall percentage
    local totalNeed = 0;
    local totalHave = 0;
    for cType, amt in pairs(needed) do
        if amt > 0 then
            totalNeed = totalNeed + amt;
            totalHave = totalHave + math.min(currencyHave[cType], amt);
        end
    end
    local overallPct = totalNeed > 0 and (totalHave / totalNeed) or 0;
    if isComplete then overallPct = 1.0; end

    -- Count how many currency types needed (for dynamic height)
    local numBars = 0;
    if not isComplete then
        for _, cType in ipairs({ 'BYNE', 'SHELL', 'BRONZE' }) do
            if needed[cType] and needed[cType] > 0 then numBars = numBars + 1; end
        end
    end
    local cardH = 38 + 3 * 20; -- fixed height (3 bar slots)
    local base = ui.color('childBg');
    local bgColor;
    if isComplete then
        bgColor = { 0.28, 0.22, 0.08, 0.85 }; -- gold for complete
    elseif completion > 0 then
        bgColor = { 0.10, 0.22, 0.12, 0.85 }; -- green tint for partial
    else
        bgColor = { base[1] + 0.03, base[2] + 0.03, base[3] + 0.05, 0.70 };
    end

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(string.format('##relic_%d', index), { cardW or -1, cardH }, false, ImGuiWindowFlags_NoScrollbar);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Accent bar (color by completion)
    local accentColor = isComplete and { 1.00, 0.85, 0.30, 1.00 }
        or completion > 0 and { 0.40, 0.90, 0.40, 1.00 }
        or ui.color('accent');
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + cardH }, imgui.GetColorU32(accentColor));

    -- Weapon icon
    imgui.SetCursorPos({ 8, 6 });
    renderIcon(relic.finalId, 24);

    -- Name + job + completion
    local nameX = 38;
    dl:AddText({ wx + nameX, wy + 6 }, imgui.GetColorU32(ui.color('white')), relic.name);

    -- Overall percentage on right
    local pctStr = string.format('%d%%', math.floor(overallPct * 100));
    local pctW = imgui.CalcTextSize(pctStr);
    local pctColor = isComplete and { 1.00, 0.85, 0.30, 1.00 }
        or overallPct >= 0.75 and { 0.40, 0.90, 0.40, 1.00 }
        or overallPct >= 0.25 and { 1.00, 0.85, 0.35, 1.00 }
        or { 0.70, 0.70, 0.70, 1.00 };
    dl:AddText({ wx + ww - pctW - 10, wy + 6 }, imgui.GetColorU32(pctColor), pctStr);

    -- Stage dots (4 circles)
    for s = 1, #relic.stages do
        local dotX = wx + nameX + (s - 1) * 14;
        local dotY = wy + 24;
        if s <= completion then
            local dotCol = isComplete and { 1.00, 0.85, 0.30, 1.00 } or { 0.40, 0.90, 0.40, 1.00 };
            dl:AddCircleFilled({ dotX + 4, dotY + 4 }, 4, imgui.GetColorU32(dotCol));
        else
            dl:AddCircle({ dotX + 4, dotY + 4 }, 4,
                imgui.GetColorU32({ 0.40, 0.40, 0.45, 1.00 }), 12);
        end
    end

    -- Progress bars per currency type
    local barY = 36;
    local barW = ww - nameX - 12;
    imgui.SetCursorPos({ nameX, barY });

    if not isComplete then
        -- Sort currency bars by required amount (smallest first)
        local sortedBars = {};
        for _, cType in ipairs({ 'BYNE', 'SHELL', 'BRONZE' }) do
            local amt = needed[cType];
            if amt and amt > 0 then
                sortedBars[#sortedBars + 1] = { type = cType, amount = amt };
            end
        end
        table.sort(sortedBars, function(a, b) return a.amount < b.amount; end);

        for _, bar in ipairs(sortedBars) do
            imgui.SetCursorPosX(nameX);
            renderProgressBar(CURRENCY[bar.type], currencyHave[bar.type], bar.amount, barW);
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);

    -- Tooltip showing the Lv75 weapon (reuses shared item tooltip)
    if imgui.IsItemHovered() and renderTooltip then
        renderTooltip({ id = relic.finalId, name = relic.name, qty = 0 });
    end
end

------------------------------------------------------------
-- Render: extra progression card (Mythic / Empyrean)
------------------------------------------------------------
-- Currency icon IDs for progress bars (distinct from card icon)
local CURRENCY_BAR_ICONS = {
    ['Alexandrite'] = 2488,
    ['H-P Bayld']   = 8798,
};

local function renderExtraCard(card, index, cardW)
    -- Get currency from state
    local have = 0;
    if troveState and troveState.currency then
        for _, entry in ipairs(troveState.currency) do
            if entry.name == card.currency then
                have = entry.total or 0;
                break;
            end
        end
    end

    local pct = card.target > 0 and math.min(have / card.target, 1.0) or 0;

    -- Collect all material IDs for ownership check
    local allMats = true;
    local matOwned = {};
    local matRows = card.materialRows or { { items = card.materials or {} } };
    for _, row in ipairs(matRows) do
        for _, mat in ipairs(row.items) do
            matOwned[mat.id] = ownedItems[mat.id] or false;
            if not matOwned[mat.id] then allMats = false; end
        end
    end
    if card.sideColumn then
        for _, mat in ipairs(card.sideColumn) do
            matOwned[mat.id] = ownedItems[mat.id] or false;
            if not matOwned[mat.id] then allMats = false; end
        end
    end

    local numRows = #matRows;
    local cardH = 38 + 3 * 20; -- match relic card height
    if numRows > 1 then
        cardH = 30 + 20 + numRows * 20; -- bar + rows
    end

    local base = ui.color('childBg');
    local bgColor;
    if pct >= 1.0 and allMats then
        bgColor = { 0.28, 0.22, 0.08, 0.85 }; -- gold
    elseif pct > 0 then
        bgColor = { 0.10, 0.22, 0.12, 0.85 };
    else
        bgColor = { base[1] + 0.03, base[2] + 0.03, base[3] + 0.05, 0.70 };
    end

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(string.format('##extra_%d', index), { cardW or -1, cardH }, false, ImGuiWindowFlags_NoScrollbar);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Accent bar
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + cardH }, imgui.GetColorU32(card.color));

    -- Icon
    imgui.SetCursorPos({ 8, 6 });
    renderIcon(card.icon, 24);

    -- Name + percentage
    local nameX = 38;
    dl:AddText({ wx + nameX, wy + 6 }, imgui.GetColorU32(ui.color('white')), card.name);
    local pctStr = string.format('%d%%', math.floor(pct * 100));
    local pctW = imgui.CalcTextSize(pctStr);
    local pctColor = pct >= 1.0 and { 1.00, 0.85, 0.30, 1.00 }
        or pct >= 0.75 and { 0.40, 0.90, 0.40, 1.00 }
        or pct >= 0.25 and { 1.00, 0.85, 0.35, 1.00 }
        or { 0.70, 0.70, 0.70, 1.00 };
    dl:AddText({ wx + ww - pctW - 10, wy + 6 }, imgui.GetColorU32(pctColor), pctStr);

    -- Currency progress bar (uses currency-specific icon, not card icon)
    local barW = ww - nameX - 12;
    imgui.SetCursorPos({ nameX, 26 });
    local barIcon = CURRENCY_BAR_ICONS[card.currency] or card.icon;
    local cDef = { icon = barIcon, name = card.currency, barFill = card.barFill };
    renderProgressBar(cDef, have, card.target, barW);

    -- Material rows
    local matY = 48;
    for ri, row in ipairs(matRows) do
        imgui.SetCursorPos({ nameX, matY });
        for mi, mat in ipairs(row.items) do
            if mi > 1 then imgui.SameLine(0, 2); end
            local owned = matOwned[mat.id];
            if not owned then
                imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.30);
            end
            renderIcon(mat.id, 18);
            if not owned then
                imgui.PopStyleVar();
            end
            if imgui.IsItemHovered() and renderTooltip then
                renderTooltip({ id = mat.id, name = mat.name, qty = 0 });
            end
        end
        matY = matY + 20;
    end

    -- Side column (L-shape, right of material rows)
    if card.sideColumn then
        local sideX = ww - (#card.sideColumn * 20) - 6;
        local sideY = 48;
        for si, mat in ipairs(card.sideColumn) do
            imgui.SetCursorPos({ sideX + (si - 1) * 20, sideY });
            local owned = matOwned[mat.id];
            if not owned then
                imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.30);
            end
            renderIcon(mat.id, 18);
            if not owned then
                imgui.PopStyleVar();
            end
            if imgui.IsItemHovered() and renderTooltip then
                renderTooltip({ id = mat.id, name = mat.name, qty = 0 });
            end
        end
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- CW Incursion Weapons (Mythrix ultimates)
-- 18 weapons across 3 zones, each requires 2 sub-weapons
------------------------------------------------------------
-- Each weapon has 3 phases:
--   Phase 1 (Smithnix): base weapon, needs materials + beastman currency
--   Phase 2 (Mythrix Trade): P1 weapon, needs base +1 weapon + 2 endgame weapons + hoards + gems
-- All IDs verified from cw_smithnix.lua, npc_mythrix.lua, enum/xi/item.lua
-- Phase 1 (Forge): 4 mats + 300 beastman currency
-- Phase 2 (Upgrade): 3 weapons + base weapon + 500 beastman currency + 10 chains
-- Phase 3 (Trade): +1 weapon + 2 endgame weapons + 99 hoards + 250 gems + 12 materials
-- W = { name, id(final), job, coin(beastman), chain, hoard, gem, material, phases }
-- phases[n] = { result, reqs = {itemId,...}, bars = { {name, icon, have_key, target}, ... } }
-- have_key = name to match in state.currency
INCURSION_ZONES = {
    {
        name  = 'Mamook',
        color = { 0.90, 0.45, 0.40, 1.00 },  -- red (Orcish)
        weapons = {
            { name = 'Ohrmazd', id = 20530, job = 'MNK/PUP', coin = 3951, chain = 3012, hoard = 3063, gem = 8964, mat = 1458, phases = {
                { result = 21510, reqs = { 16437, 16446, 17519, 2984 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 300 } } },
                { result = 20531, reqs = { 17472, 17503, 18350, 21510 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 500 }, { 'Chains', 3012, 'Orcish Chain', 10 } } },
                { result = 20530, reqs = { 20531, 18351, 16426 }, bars = { { 'Hoards', 3063, 'Mamook Steel', 9900 }, { 'Gems', 8964, 'Imperial Citrine', 250 }, { 'Mats', 1458, nil, 12 } } },
            }},
            { name = 'Claidheamh', id = 20718, job = 'PLD/BLU', coin = 3951, chain = 3012, hoard = 3063, gem = 8961, mat = 1409, phases = {
                { result = 22219, reqs = { 16628, 16634, 17692, 2985 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 300 } } },
                { result = 20719, reqs = { 16580, 16533, 17693, 22219 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 500 }, { 'Chains', 3012, 'Orcish Chain', 10 } } },
                { result = 20718, reqs = { 20719, 17695, 17649 }, bars = { { 'Hoards', 3063, 'Mamook Steel', 9900 }, { 'Gems', 8961, 'Imperial Opal', 250 }, { 'Mats', 1409, nil, 12 } } },
            }},
            { name = 'Kumbhakarna', id = 20809, job = 'WAR/BST', coin = 3951, chain = 3012, hoard = 3063, gem = 8962, mat = 1459, phases = {
                { result = 21712, reqs = { 16663, 16664, 16687, 2986 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 300 } } },
                { result = 20810, reqs = { 17969, 16676, 17936, 21712 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 500 }, { 'Chains', 3012, 'Orcish Chain', 10 } } },
                { result = 20809, reqs = { 20810, 17937, 17960 }, bars = { { 'Hoards', 3063, 'Mamook Steel', 9900 }, { 'Gems', 8962, 'Imperial Amethyst', 250 }, { 'Mats', 1459, nil, 12 } } },
            }},
            { name = 'Svarga', id = 20857, job = 'WAR', coin = 3951, chain = 3012, hoard = 3063, gem = 8964, mat = 1467, phases = {
                { result = 21769, reqs = { 16717, 18215, 18209, 2987 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 300 } } },
                { result = 20859, reqs = { 18507, 16727, 18210, 21769 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 500 }, { 'Chains', 3012, 'Orcish Chain', 10 } } },
                { result = 20857, reqs = { 20859, 18211, 18497 }, bars = { { 'Hoards', 3063, 'Mamook Steel', 9900 }, { 'Gems', 8964, 'Imperial Citrine', 250 }, { 'Mats', 1467, nil, 12 } } },
            }},
            { name = 'Olyndicus', id = 20946, job = 'DRG', coin = 3951, chain = 3012, hoard = 3063, gem = 8962, mat = 1462, phases = {
                { result = 21864, reqs = { 16864, 16876, 18085, 2988 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 300 } } },
                { result = 20947, reqs = { 16885, 16882, 18086, 21864 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 500 }, { 'Chains', 3012, 'Orcish Chain', 10 } } },
                { result = 20946, reqs = { 20947, 18088, 18125 }, bars = { { 'Hoards', 3063, 'Mamook Steel', 9900 }, { 'Gems', 8962, 'Imperial Amethyst', 250 }, { 'Mats', 1462, nil, 12 } } },
            }},
            { name = 'Svalinn', id = 27627, job = 'WAR', coin = 3951, chain = 3012, hoard = 3063, gem = 8960, mat = 1468, phases = {
                { result = 26413, reqs = { 12334, 12326, 18171, 2989 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 300 } } },
                { result = 27624, reqs = { 12348, 16187, 12405, 26413 }, bars = { { 'Orcish Steel', 3951, 'Orcish Steel', 500 }, { 'Chains', 3012, 'Orcish Chain', 10 } } },
                { result = 27627, reqs = { 27624, 12361, 12360 }, bars = { { 'Hoards', 3063, 'Mamook Steel', 9900 }, { 'Gems', 8960, 'Imperial Garnet', 250 }, { 'Mats', 1468, nil, 12 } } },
            }},
        },
    },
    {
        name  = 'Halvung',
        color = { 0.45, 0.65, 1.00, 1.00 },  -- blue (Quadav)
        weapons = {
            { name = 'Claritas', id = 18909, job = 'RDM', coin = 3952, chain = 3013, hoard = 3064, gem = 8965, mat = 1468, phases = {
                { result = 21622, reqs = { 16633, 16803, 17692, 2978 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 300 } } },
                { result = 18905, reqs = { 16822, 16821, 17696, 21622 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 500 }, { 'Chains', 3013, 'Quadav Chain', 10 } } },
                { result = 18909, reqs = { 18905, 17694, 17658 }, bars = { { 'Hoards', 3064, 'Halvung Brass', 9900 }, { 'Gems', 8965, 'Imperial Sapphire', 250 }, { 'Mats', 1468, nil, 12 } } },
            }},
            { name = 'Macbain', id = 20759, job = 'DRK/RUN', coin = 3952, chain = 3013, hoard = 3064, gem = 8960, mat = 1459, phases = {
                { result = 21665, reqs = { 16931, 16932, 16959, 2979 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 300 } } },
                { result = 20760, reqs = { 16942, 16945, 16937, 21665 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 500 }, { 'Chains', 3013, 'Quadav Chain', 10 } } },
                { result = 20759, reqs = { 20760, 18385, 19153 }, bars = { { 'Hoards', 3064, 'Halvung Brass', 9900 }, { 'Gems', 8960, 'Imperial Garnet', 250 }, { 'Mats', 1459, nil, 12 } } },
            }},
            { name = 'Inanna', id = 20901, job = 'BLM/DRK', coin = 3952, chain = 3013, hoard = 3064, gem = 8961, mat = 1458, phases = {
                { result = 21822, reqs = { 16779, 16782, 18045, 2980 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 300 } } },
                { result = 20903, reqs = { 16787, 18041, 18046, 21822 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 500 }, { 'Chains', 3013, 'Quadav Chain', 10 } } },
                { result = 20901, reqs = { 20903, 18047, 18948 }, bars = { { 'Hoards', 3064, 'Halvung Brass', 9900 }, { 'Gems', 8961, 'Imperial Opal', 250 }, { 'Mats', 1458, nil, 12 } } },
            }},
            { name = 'Nehushtan', id = 21105, job = 'WHM/GEO', coin = 3952, chain = 3013, hoard = 3064, gem = 8965, mat = 1409, phases = {
                { result = 22006, reqs = { 17115, 17121, 17462, 2981 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 300 } } },
                { result = 21109, reqs = { 17416, 17454, 17463, 22006 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 500 }, { 'Chains', 3013, 'Quadav Chain', 10 } } },
                { result = 21105, reqs = { 21109, 17464, 18857 }, bars = { { 'Hoards', 3064, 'Halvung Brass', 9900 }, { 'Gems', 8965, 'Imperial Sapphire', 250 }, { 'Mats', 1409, nil, 12 } } },
            }},
            { name = 'Providence', id = 18626, job = 'SMN', coin = 3952, chain = 3013, hoard = 3064, gem = 8965, mat = 1462, phases = {
                { result = 22291, reqs = { 17126, 17127, 17571, 2982 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 300 } } },
                { result = 21172, reqs = { 17108, 17563, 17573, 22291 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 500 }, { 'Chains', 3013, 'Quadav Chain', 10 } } },
                { result = 18626, reqs = { 21172, 17576, 17528 }, bars = { { 'Hoards', 3064, 'Halvung Brass', 9900 }, { 'Gems', 8965, 'Imperial Sapphire', 250 }, { 'Mats', 1462, nil, 12 } } },
            }},
            { name = 'Doomsday', id = 21476, job = 'RNG/COR', coin = 3952, chain = 3013, hoard = 3064, gem = 8960, mat = 1467, phases = {
                { result = 22144, reqs = { 17254, 17260, 17271, 2983 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 300 } } },
                { result = 21275, reqs = { 17232, 17244, 17215, 22144 }, bars = { { 'Quadav Brass', 3952, 'Quadav Brass', 500 }, { 'Chains', 3013, 'Quadav Chain', 10 } } },
                { result = 21476, reqs = { 21275, 17245, 18706 }, bars = { { 'Hoards', 3064, 'Halvung Brass', 9900 }, { 'Gems', 8960, 'Imperial Garnet', 250 }, { 'Mats', 1467, nil, 12 } } },
            }},
        },
    },
    {
        name  = 'Arrapago',
        color = { 0.50, 0.88, 0.50, 1.00 },  -- green (Yagudo)
        weapons = {
            { name = 'Ipetam', id = 20616, job = 'THF/DNC', coin = 3953, chain = 3014, hoard = 3065, gem = 8963, mat = 1459, phases = {
                { result = 21566, reqs = { 16742, 16739, 17993, 2990 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 300 } } },
                { result = 20617, reqs = { 16767, 19120, 17994, 21566 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 500 }, { 'Chains', 3014, 'Yagudo Chain', 10 } } },
                { result = 20616, reqs = { 20617, 17996, 17619 }, bars = { { 'Hoards', 3065, 'Arrapago Silver', 9900 }, { 'Gems', 8963, 'Imperial Peridot', 250 }, { 'Mats', 1459, nil, 12 } } },
            }},
            { name = 'Izuna', id = 20989, job = 'NIN', coin = 3953, chain = 3014, hoard = 3065, gem = 8963, mat = 1468, phases = {
                { result = 21912, reqs = { 16925, 16921, 17786, 2991 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 300 } } },
                { result = 20993, reqs = { 19280, 16911, 17787, 21912 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 500 }, { 'Chains', 3014, 'Yagudo Chain', 10 } } },
                { result = 20989, reqs = { 20993, 18429, 18430 }, bars = { { 'Hoards', 3065, 'Arrapago Silver', 9900 }, { 'Gems', 8963, 'Imperial Peridot', 250 }, { 'Mats', 1468, nil, 12 } } },
            }},
            { name = 'Nenekirimaru', id = 21037, job = 'SAM', coin = 3953, chain = 3014, hoard = 3065, gem = 8963, mat = 1467, phases = {
                { result = 21976, reqs = { 16983, 16986, 17820, 2992 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 300 } } },
                { result = 21038, reqs = { 17813, 16980, 17821, 21976 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 500 }, { 'Chains', 3014, 'Yagudo Chain', 10 } } },
                { result = 21037, reqs = { 21038, 17823, 18446 }, bars = { { 'Hoards', 3065, 'Arrapago Silver', 9900 }, { 'Gems', 8963, 'Imperial Peridot', 250 }, { 'Mats', 1467, nil, 12 } } },
            }},
            { name = 'Keraunos', id = 21169, job = 'BLM/SCH', coin = 3953, chain = 3014, hoard = 3065, gem = 8961, mat = 1458, phases = {
                { result = 22088, reqs = { 17124, 17119, 17571, 2993 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 300 } } },
                { result = 21171, reqs = { 17586, 17564, 17572, 22088 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 500 }, { 'Chains', 3014, 'Yagudo Chain', 10 } } },
                { result = 21169, reqs = { 21171, 17575, 17567 }, bars = { { 'Hoards', 3065, 'Arrapago Silver', 9900 }, { 'Gems', 8961, 'Imperial Opal', 250 }, { 'Mats', 1458, nil, 12 } } },
            }},
            { name = 'Phaosphaelia', id = 21224, job = 'RNG', coin = 3953, chain = 3014, hoard = 3065, gem = 8962, mat = 1462, phases = {
                { result = 22133, reqs = { 17178, 17180, 17202, 2994 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 300 } } },
                { result = 21226, reqs = { 17187, 17212, 17203, 22133 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 500 }, { 'Chains', 3014, 'Yagudo Chain', 10 } } },
                { result = 21224, reqs = { 21226, 17165, 17199 }, bars = { { 'Hoards', 3065, 'Arrapago Silver', 9900 }, { 'Gems', 8962, 'Imperial Amethyst', 250 }, { 'Mats', 1462, nil, 12 } } },
            }},
            { name = 'Linos', id = 21404, job = 'BRD', coin = 3953, chain = 3014, hoard = 3065, gem = 8964, mat = 1409, phases = {
                { result = 22296, reqs = { 17370, 17375, 18170, 2995 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 300 } } },
                { result = 21406, reqs = { 17346, 17982, 17995, 22296 }, bars = { { 'Yagudo Silver', 3953, 'Yagudo Silver', 500 }, { 'Chains', 3014, 'Yagudo Chain', 10 } } },
                { result = 21404, reqs = { 21406, 17838, 17365 }, bars = { { 'Hoards', 3065, 'Arrapago Silver', 9900 }, { 'Gems', 8964, 'Imperial Citrine', 250 }, { 'Mats', 1409, nil, 12 } } },
            }},
        },
    },
};


------------------------------------------------------------
-- Resolve item name from resource manager
local function itemName(itemId)
    local res = getItemRes(itemId);
    return (res and res.Name and res.Name[1]) or string.format('Item %d', itemId);
end

-- Read incursion currency from state.currency
------------------------------------------------------------
local function getIncursionCurrency(name)
    if not troveState or not troveState.currency then return nil; end
    for _, entry in ipairs(troveState.currency) do
        if entry.name == name then return entry.total or 0; end
    end
    return nil;
end

------------------------------------------------------------
-- Render: incursion progress bar (compact, fits in phase box)
------------------------------------------------------------
local function renderIncursionBar(icon, have, target, width)
    local pct = target > 0 and math.min(have / target, 1.0) or 0;
    local barH = 12;

    local dl = imgui.GetWindowDrawList();

    -- Icon
    renderIcon(icon, 12);
    imgui.SameLine(0, 3);
    local bx, by = imgui.GetCursorScreenPos();
    local barW = width - 18;

    -- Background
    dl:AddRectFilled({ bx, by + 1 }, { bx + barW, by + barH },
        imgui.GetColorU32({ 0.06, 0.06, 0.09, 0.90 }), 2);

    -- Fill
    if pct > 0 then
        local fillCol = pct >= 1.0 and { 0.40, 0.55, 0.20, 0.70 } or { 0.25, 0.35, 0.50, 0.60 };
        dl:AddRectFilled({ bx, by + 1 }, { bx + barW * pct, by + barH },
            imgui.GetColorU32(fillCol), 2);
    end

    -- Fraction text (centered, with shadow)
    local fracStr = string.format('%d/%d', math.min(have, target), target);
    local fracW = imgui.CalcTextSize(fracStr);
    local tx = bx + (barW - fracW) / 2;
    dl:AddText({ tx + 1, by + 1 }, imgui.GetColorU32({ 0, 0, 0, 0.80 }), fracStr);
    dl:AddText({ tx, by }, imgui.GetColorU32({ 1, 1, 1, 0.90 }), fracStr);

    imgui.Dummy({ width, barH + 1 });
end

------------------------------------------------------------
-- Render: single incursion weapon (3 phase boxes horizontal)
------------------------------------------------------------
local PHASE_LABELS = { 'Forge', 'Upgrade', 'Trade' };

local function renderIncursionWeapon(wpn, zoneColor, index)
    local hasFinal = ownedItems[wpn.id];
    local base = ui.color('childBg');

    -- Weapon name header with zone-colored background
    -- Weapon name header with zone-colored background
    imgui.Dummy({ 0, 3 }); -- top margin
    local dl = imgui.GetWindowDrawList();
    local hx, hy = imgui.GetCursorScreenPos();
    local hw = imgui.GetContentRegionAvail();
    local hdrH = 30;
    local headerBg = { zoneColor[1] * 0.20, zoneColor[2] * 0.20, zoneColor[3] * 0.20, 0.70 };
    dl:AddRectFilled({ hx, hy }, { hx + hw, hy + hdrH }, imgui.GetColorU32(headerBg), 3);
    dl:AddRectFilled({ hx, hy }, { hx + 3, hy + hdrH }, imgui.GetColorU32(zoneColor));

    imgui.SetCursorPosX(10);
    imgui.SetCursorPosY(imgui.GetCursorPosY() + 5);
    renderIcon(wpn.id, 20);
    imgui.SameLine(0, 4);
    local nameCol = hasFinal and { 1.00, 0.85, 0.30, 1.00 } or ui.color('white');
    imgui.TextColored(nameCol, wpn.name);
    imgui.SameLine(0, 6);
    imgui.TextColored(ui.color('dimmed'), wpn.job);
    imgui.Dummy({ 0, 8 });

    -- 3 phase boxes side by side
    local gap = 4;
    local boxW = math.floor((imgui.GetContentRegionAvail() - gap * 2) / 3);

    -- Calculate box height based on max bars across phases
    local maxBars = 0;
    for _, phase in ipairs(wpn.phases) do
        if phase.bars and #phase.bars > maxBars then maxBars = #phase.bars; end
    end
    local boxH = 32 + 24 + maxBars * 16 + 4; -- result icon + reqs row + bars + padding

    for pi, phase in ipairs(wpn.phases) do
        if pi > 1 then imgui.SameLine(0, gap); end

        local hasResult = ownedItems[phase.result];
        local bgColor;
        if hasResult then
            bgColor = { 0.28, 0.22, 0.08, 0.80 };
        else
            bgColor = { base[1] + 0.03, base[2] + 0.03, base[3] + 0.05, 0.60 };
        end

        imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
        imgui.BeginChild(string.format('##incph_%d_%d', index, pi), { boxW, boxH }, false, ImGuiWindowFlags_NoScrollbar);

        local pdl = imgui.GetWindowDrawList();
        local px, py = imgui.GetWindowPos();
        local pw = imgui.GetWindowWidth();

        -- Accent bar
        local accentCol = hasResult and { 1.00, 0.85, 0.30, 1.00 } or zoneColor;
        pdl:AddRectFilled({ px, py }, { px + 2, py + boxH }, imgui.GetColorU32(accentCol));

        -- Result weapon icon + name
        imgui.SetCursorPos({ 6, 2 });
        if not hasResult then imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.30); end
        renderIcon(phase.result, 24);
        if not hasResult then imgui.PopStyleVar(); end
        if imgui.IsItemHovered() and renderTooltip then
            renderTooltip({ id = phase.result, name = itemName(phase.result), qty = 0 });
        end
        imgui.SameLine(0, 3);
        local rNameCol = hasResult and { 1.00, 0.85, 0.30, 1.00 } or { 0.70, 0.70, 0.75, 1.00 };
        local rName = itemName(phase.result);
        -- Use weapon name as fallback for custom items without DAT entries
        if rName:find('^Item %d') and pi == #wpn.phases then rName = wpn.name; end
        -- Truncate if needed
        if imgui.CalcTextSize(rName) > pw - 36 then
            while #rName > 1 and imgui.CalcTextSize(rName .. '..') > pw - 36 do
                rName = rName:sub(1, -2);
            end
            rName = rName .. '..';
        end
        imgui.TextColored(rNameCol, rName);

        -- Required item icons (below result) with gold bg when owned
        imgui.SetCursorPos({ 6, 30 });
        local iconSz = 20;
        for ri, reqId in ipairs(phase.reqs) do
            if ri > 1 then imgui.SameLine(0, 2); end

            local owned = ownedItems[reqId];

            -- Gold background for owned items
            if owned then
                local ix, iy = imgui.GetCursorScreenPos();
                pdl:AddRectFilled({ ix - 1, iy - 1 }, { ix + iconSz + 1, iy + iconSz + 1 },
                    imgui.GetColorU32({ 0.45, 0.38, 0.10, 0.70 }), 3);
            end

            if not owned then imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.15); end
            renderIcon(reqId, iconSz);
            if not owned then imgui.PopStyleVar(); end

            if imgui.IsItemHovered() and renderTooltip then
                renderTooltip({ id = reqId, name = itemName(reqId), qty = 0 });
            end
        end

        -- Currency progress bars
        if phase.bars then
            local barY = 54;
            for _, bar in ipairs(phase.bars) do
                imgui.SetCursorPos({ 6, barY });
                local have = 0;
                if bar[3] then
                    have = getIncursionCurrency(bar[3]) or 0;
                else
                    have = itemCounts[bar[2]] or 0;
                end
                renderIncursionBar(bar[2], have, bar[4], pw - 12);
                -- Tooltip on the bar
                if imgui.IsItemHovered() and renderTooltip then
                    renderTooltip({ id = bar[2], name = itemName(bar[2]), qty = have });
                end
                barY = barY + 16;
            end
        end

        imgui.EndChild();
        imgui.PopStyleColor(1);
    end

    imgui.Spacing();
end

------------------------------------------------------------
-- Render: CW Incursion tab
------------------------------------------------------------
local function renderIncursionTab()
    imgui.PushStyleColor(ImGuiCol_ChildBg, ui.color('windowBg'));
    imgui.BeginChild('##incursion_list', { -1, -1 }, false);

    for zi, zone in ipairs(INCURSION_ZONES) do
        -- Zone header
        local accentDim = { zone.color[1] * 0.35, zone.color[2] * 0.35, zone.color[3] * 0.35, 0.85 };
        imgui.PushStyleColor(ImGuiCol_ChildBg, accentDim);
        imgui.BeginChild(string.format('##inczone_%d', zi), { -1, 24 }, false);
        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();
        local ww = imgui.GetWindowWidth();
        dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 24 }, imgui.GetColorU32(zone.color));
        dl:AddLine({ wx, wy + 23 }, { wx + ww, wy + 23 },
            imgui.GetColorU32({ zone.color[1], zone.color[2], zone.color[3], 0.15 }));
        imgui.SetCursorPosX(12);
        imgui.SetCursorPosY(4);
        imgui.TextColored(zone.color, zone.name);

        local owned = 0;
        for _, wpn in ipairs(zone.weapons) do
            if ownedItems[wpn.id] then owned = owned + 1; end
        end
        local countStr = string.format('%d/%d', owned, #zone.weapons);
        local cw = imgui.CalcTextSize(countStr);
        imgui.SameLine(ww - cw - 12);
        imgui.SetCursorPosY(4);
        imgui.TextColored({ zone.color[1], zone.color[2], zone.color[3], 0.50 }, countStr);

        imgui.EndChild();
        imgui.PopStyleColor(1);

        -- Weapon phase boxes
        for wi, wpn in ipairs(zone.weapons) do
            renderIncursionWeapon(wpn, zone.color, zi * 100 + wi);
        end
        imgui.Spacing();
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

------------------------------------------------------------
-- Render: main window
------------------------------------------------------------
local function renderWindow()
    if not isOpen[1] then return; end

    if not scanned then
        scanWeapons();
        scanned = true;
    end
    readCurrencyFromState();

    imgui.SetNextWindowSize({ 680, 480 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 600, 350 }, { 900, 800 });

    local winColors = ui.pushWindowStyle();

    if imgui.Begin('Ultimates###trove_relics', isOpen, ImGuiWindowFlags_None) then
        local _bgPop = ui.renderBackground();

        -- Header: currency totals with icons
        local currencyLoaded = troveState and troveState.currency and #troveState.currency > 0;
        for _, cType in ipairs({ 'BYNE', 'SHELL', 'BRONZE' }) do
            local cDef = CURRENCY[cType];
            renderIcon(cDef.icon, 16);
            imgui.SameLine(0, 4);
            if currencyLoaded then
                imgui.TextColored(cDef.color, tostring(currencyHave[cType]));
            else
                imgui.TextColored({ 0.50, 0.50, 0.55, 1.00 }, '?');
            end
            if imgui.IsItemHovered() and not currencyLoaded then
                imgui.SetTooltip('Open Currency tab once to load data');
            end
            imgui.SameLine(0, 14);
        end

        -- DVP converted to currency equivalent (500 DVP = 100 currency)
        local dvp = nil;
        if troveState and troveState.points and #troveState.points > 0 then
            for _, entry in ipairs(troveState.points) do
                if entry.label == 'Dynamis' and entry.group == 'Ventures' then
                    dvp = entry.value or 0;
                    break;
                end
            end
        end
        if renderFileIcon then
            renderFileIcon('cw.png', 16);
            imgui.SameLine(0, 4);
        end
        if dvp then
            local dvpCurrency = math.floor(dvp / 5);
            imgui.TextColored({ 0.65, 0.85, 1.00, 1.00 }, tostring(dvpCurrency));
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string.format('%d Dynamis Venture Points\n500 DVP = 100 currency', dvp));
            end
        else
            imgui.TextColored({ 0.50, 0.50, 0.55, 1.00 }, '?');
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Open Currency and Points tabs once to load data');
            end
        end

        imgui.Separator();
        imgui.Spacing();

        -- Tab bar: Relic / Incursion
        if imgui.BeginTabBar('##ult_tabs', ImGuiTabBarFlags_None) then
            if imgui.BeginTabItem('Relic') then
                imgui.BeginChild('##relic_list', { -1, -1 }, false);
                local gap = 4;
                local colW = math.floor((imgui.GetContentRegionAvail() - gap * 2) / 3);
                local totalItems = #RELICS + #EXTRA_CARDS;
                for i = 1, totalItems do
                    local col = ((i - 1) % 3);
                    if col > 0 then imgui.SameLine(0, gap); end
                    if i <= #RELICS then
                        renderRelicCard(RELICS[i], i, colW);
                    else
                        renderExtraCard(EXTRA_CARDS[i - #RELICS], i, colW);
                    end
                    if col == 2 then imgui.Spacing(); end
                end
                imgui.EndChild();
                imgui.EndTabItem();
            end

            if imgui.BeginTabItem('Incursion') then
                renderIncursionTab();
                imgui.EndTabItem();
            end

            imgui.EndTabBar();
        end
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(winColors);
end

------------------------------------------------------------
-- Plugin export
------------------------------------------------------------
return {
    name        = 'Ultimates',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Track dynamis currency progress toward relic weapons',

    init = function(sharedRenderIcon, sharedGetItemRes, sharedUi, sharedRenderTooltip, sharedRenderFileIcon)
        renderIcon = sharedRenderIcon;
        getItemRes = sharedGetItemRes;
        ui = sharedUi;
        renderTooltip = sharedRenderTooltip;
        renderFileIcon = sharedRenderFileIcon;
    end,

    -- Grab trove state on first render (for currency data)
    onRender = function(state)
        if not troveState and state then
            troveState = state;
        end
    end,

    commands = {
        ultimates = function(state, args)
            if state then troveState = state; end
            isOpen[1] = not isOpen[1];
            if isOpen[1] then
                scanned = false;
            end
        end,
    },

    window = {
        category = 'Collections',
        isOpen = isOpen,
        render = renderWindow,
        label  = 'Ultimates',
        icon   = 18270, -- Mandau
    },
};
