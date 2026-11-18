--[[
* trove/plugins/lumoria.lua — Sea / Lumoria collection tracker
*
* Tracks Homam/Nashira armor sets with augment tiers, Omega/Ultima
* upgrade materials, Sea Torques, Jailer Weapons, Sea Organs, and
* active Storming Sea buffs.
*
* Uses the generic plugin data protocol (pluginId 0).
*
* Command: /trove lumoria  (or /trove sea)
]]--

local imgui = require('imgui');

------------------------------------------------------------
-- Shared (injected via init)
------------------------------------------------------------
local renderIcon = nil;
local getItemRes = nil;
local ui = nil;
local renderTooltip = nil;

------------------------------------------------------------
-- State
------------------------------------------------------------
local isOpen   = { false };
local wasOpen  = false;
local loaded   = false;
local loading  = false;

-- Parsed data from server
local data = {
    buffs        = 0,       -- uint16 bitmask
    torques      = 0,       -- uint8 bitmask (7 bits)
    weapons      = 0,       -- uint8 bitmask (7 bits)
    homamTiers   = {},      -- [1..5] = tier (0=none, 1-4)
    nashiraTiers = {},      -- [1..5]
    omegaCounts  = {},      -- [1..5]
    ultimaCounts = {},      -- [1..5]
    organInv     = {},      -- [1..6] inventory counts
    organVision  = {},      -- [1..6] vision storage counts
    torqueLoc    = 0,       -- bitmask (bit set = squire)
    weaponLoc    = 0,
    homamLoc     = 0,
    nashiraLoc   = 0,
};

------------------------------------------------------------
-- Protocol
------------------------------------------------------------
local PACKET_ID        = 0x1A4;
local C2S_PLUGIN_DATA  = 17;
local PLUGIN_ID        = 0; -- Lumoria

local requestTime = 0;

local function requestData()
    if loading then return; end
    loading = true;
    requestTime = os.clock();
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    p[5] = C2S_PLUGIN_DATA;
    p[7] = PLUGIN_ID;
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_ID, p);
end

------------------------------------------------------------
-- Item definitions
------------------------------------------------------------
local TORQUES = {
    { id = 15508, name = 'Justice Torque',     nm = 'Jailer of Justice' },
    { id = 15509, name = 'Hope Torque',        nm = 'Jailer of Hope' },
    { id = 15510, name = 'Prudence Torque',    nm = 'Jailer of Prudence' },
    { id = 15511, name = 'Fortitude Torque',   nm = 'Jailer of Fortitude' },
    { id = 15512, name = 'Faith Torque',       nm = 'Jailer of Faith' },
    { id = 15513, name = 'Temperance Torque',  nm = 'Jailer of Temperance' },
    { id = 15514, name = 'Love Torque',        nm = 'Jailer of Love' },
};

local WEAPONS = {
    { id = 17595, name = 'Hope Staff',       nm = 'Jailer of Hope' },
    { id = 17710, name = 'Justice Sword',    nm = 'Jailer of Justice' },
    { id = 17948, name = 'Temperance Axe',   nm = 'Jailer of Temperance' },
    { id = 18100, name = 'Love Halberd',     nm = 'Jailer of Love' },
    { id = 18222, name = 'Fortitude Axe',    nm = 'Jailer of Fortitude' },
    { id = 18360, name = 'Faith Baghnakhs',  nm = 'Jailer of Faith' },
    { id = 18397, name = 'Prudence Rod',     nm = 'Jailer of Prudence' },
};

local HOMAM = {
    { id = 15240, name = 'Homam Zucchetto', slot = 'Head',
      augs = {
          { 'Dual Wield+1, Mag.Acc.+1, Triple Atk.+1%' },
          { 'Dual Wield+2, Mag.Acc.+2, Triple Atk.+2%' },
          { 'Dual Wield+3, Mag.Acc.+3, Triple Atk.+3%' },
      },
    },
    { id = 14488, name = 'Homam Corazza', slot = 'Body',
      augs = {
          { 'Haste+1%, Great Sword Skill+3, Desperate Blows+2' },
          { 'Haste+2%, Great Sword Skill+4, Desperate Blows+3' },
          { 'Haste+3%, Great Sword Skill+5, Desperate Blows+4' },
      },
    },
    { id = 14905, name = 'Homam Manopolas', slot = 'Hands',
      augs = {
          { 'HP+15, Parrying Skill+3, Phys. Dmg. Taken-1%' },
          { 'HP+20, Parrying Skill+4, Phys. Dmg. Taken-2%' },
          { 'HP+25, Parrying Skill+5, Phys. Dmg. Taken-3%' },
      },
    },
    { id = 15576, name = 'Homam Cosciales', slot = 'Legs',
      augs = {
          { 'Conserve MP+3, Blue Magic Skill+3, Enh. Magic Duration+3' },
          { 'Conserve MP+4, Blue Magic Skill+4, Enh. Magic Duration+4' },
          { 'Conserve MP+5, Blue Magic Skill+5, Enh. Magic Duration+5' },
      },
    },
    { id = 15661, name = 'Homam Gambieras', slot = 'Feet',
      augs = {
          { 'STR+3, Polearm Skill+4, Meditate Duration+1' },
          { 'STR+4, Polearm Skill+5, Meditate Duration+2' },
          { 'STR+5, Polearm Skill+6, Meditate Duration+3' },
      },
    },
};

local NASHIRA = {
    { id = 15241, name = 'Nashira Turban', slot = 'Head',
      augs = {
          { 'MP+10, Fast Cast+1%, Conserve MP+1' },
          { 'MP+15, Fast Cast+2%, Conserve MP+2' },
          { 'MP+20, Fast Cast+3%, Conserve MP+3' },
      },
    },
    { id = 14489, name = 'Nashira Manteel', slot = 'Body',
      augs = {
          { 'Enh. Mag. Skill+3, Conserve MP+1, Enh. Magic Duration+3' },
          { 'Enh. Mag. Skill+4, Conserve MP+2, Enh. Magic Duration+4' },
          { 'Enh. Mag. Skill+5, Conserve MP+3, Enh. Magic Duration+5' },
      },
    },
    { id = 14906, name = 'Nashira Gages', slot = 'Hands',
      augs = {
          { 'MP+8, Blood Boon+3, B.P. Ability Delay-1' },
          { 'MP+10, Blood Boon+4, B.P. Ability Delay-2' },
          { 'MP+12, Blood Boon+5, B.P. Ability Delay-3' },
      },
    },
    { id = 15577, name = 'Nashira Seraweels', slot = 'Legs',
      augs = {
          { 'INT+1, MND+1, Enfeebling Magic Duration+3' },
          { 'INT+2, MND+2, Enfeebling Magic Duration+4' },
          { 'INT+3, MND+3, Enfeebling Magic Duration+5' },
      },
    },
    { id = 15662, name = 'Nashira Crackows', slot = 'Feet',
      augs = {
          { 'MP+8, INT+2, Mag. Atk. Bonus+1' },
          { 'MP+10, INT+3, Mag. Atk. Bonus+2' },
          { 'MP+12, INT+4, Mag. Atk. Bonus+3' },
      },
    },
};

local OMEGA_PIECES = {
    { id = 1925, name = "Omega's Eye" },
    { id = 1926, name = "Omega's Heart" },
    { id = 1927, name = "Omega's Foreleg" },
    { id = 1928, name = "Omega's Hind Leg" },
    { id = 1929, name = "Omega's Tail" },
};

local ULTIMA_PIECES = {
    { id = 1920, name = "Ultima's Cerebrum" },
    { id = 1921, name = "Ultima's Heart" },
    { id = 1922, name = "Ultima's Claw" },
    { id = 1923, name = "Ultima's Leg" },
    { id = 1924, name = "Ultima's Tail" },
};

local ORGANS = {
    { id = 1784, name = 'Phuabo Organ' },
    { id = 1785, name = 'Xzomit Organ' },
    { id = 1786, name = 'Aern Organ' },
    { id = 1787, name = 'Hpemde Organ' },
    { id = 1788, name = 'Yovra Organ' },
    { id = 1818, name = 'Euvhi Organ' },
    { id = 1852, name = 'H.Q. Phuabo Organ', hq = true },
    { id = 1855, name = 'H.Q. Xzomit Organ', hq = true },
    { id = 1900, name = 'H.Q. Aern Organ',   hq = true },
    { id = 1871, name = 'H.Q. Hpemde Organ', hq = true },
    { id = 1899, name = 'H.Q. Euvhi Organ',  hq = true },
    { id = 1819, name = 'Luminion Chip' },
};

local BUFFS = {
    { name = "Sniper's Salvo",        desc = 'Ranged Accuracy+15, Ranged Attack+15',       nm = "Al'Xzomit",       zone = "Al'Taieu",                pos = '(J-13)', chip = 1906, chipName = 'Emerald Chip', jobs = 'RNG, NIN, COR' },
    { name = "Rogue's Retribution",   desc = 'DEX+5, Critical Hit Rate+10%',               nm = "Al'Ghrah",        zone = "Garden of Ru'Hmet",       pos = '(I-8)',  chip = 1905, chipName = 'Scarlet Chip', jobs = 'THF, DRG, BST' },
    { name = "Warlord's Wrath",       desc = 'Enmity+5, Double Attack+10%',                nm = "Al'Euvhi",        zone = "Garden of Ru'Hmet",       pos = '(H-10)', chip = 1905, chipName = 'Scarlet Chip', jobs = 'WAR, SAM' },
    { name = "Scholar's Swiftness",   desc = 'Fast Cast+10%, Movement Speed+10%',          nm = "Al'Hpemde",       zone = "Al'Taieu",                pos = '(D-9)',  chip = 1906, chipName = 'Emerald Chip', jobs = 'RDM, SMN, SCH' },
    { name = "Rambler's Respite",     desc = 'HP/MP Rec. +10, Mag. Def.+15',               nm = "Al'Zdei",         zone = "Grand Palace of Hu'Xzoi", pos = '(L-8)',  chip = 1904, chipName = 'Ivory Chip',   jobs = 'MNK, BRD, PUP' },
    { name = "Cleric's Clarity",      desc = 'MND+5, Cure Potency+10%',                    nm = "Al'Aern",         zone = "Grand Palace of Hu'Xzoi", pos = '(I-7)',  chip = 1904, chipName = 'Ivory Chip',   jobs = 'WHM, PLD, DNC' },
    { name = "Thaumaturge's Tempest", desc = 'INT+5, Mag. Atk. Bonus+10',                  nm = "Al'Phuabo",       zone = "Al'Taieu",                pos = '(M-9)',  chip = 1906, chipName = 'Emerald Chip', jobs = 'BLM, DRK, BLU' },
    { name = "Ronin's Revenge",       desc = 'WS Accuracy+10, Store TP+8',                 nm = 'Justice Warden',  zone = "Al'Taieu",                pos = '(D-11)', chip = 2127, chipName = 'Metal Chip',   jobs = 'All Jobs' },
    { name = "Trickster's Tenacity",  desc = 'AGI+5, Evasion+15, Mag. Dmg. Taken-8%',     nm = 'Prudence Warden', zone = "Al'Taieu",                pos = '(L-9)',  chip = 2127, chipName = 'Metal Chip',   jobs = 'All Jobs' },
    { name = "Braver's Bulwark",      desc = 'DEF+15, Phys. Dmg. Taken-8%',                nm = 'Hope Warden',     zone = "Al'Taieu",                pos = '(E-9)',  chip = 2127, chipName = 'Metal Chip',   jobs = 'All Jobs' },
};

------------------------------------------------------------
-- Colors
------------------------------------------------------------
local COL = {
    pink     = { 1.00, 0.55, 0.75, 1.00 },
    owned    = { 0.55, 0.90, 0.55, 1.00 },
    unowned  = { 0.45, 0.45, 0.50, 0.70 },
    starOn   = { 1.00, 0.85, 0.30, 1.00 },
    starOff  = { 0.30, 0.30, 0.35, 0.60 },
    buffOn   = { 0.45, 0.85, 1.00, 1.00 },
    buffOff  = { 0.45, 0.45, 0.50, 0.60 },
    sea      = { 0.15, 0.18, 0.28 },  -- section tint (deep ocean blue)
};

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function hasBit(mask, pos)
    return bit.band(mask, bit.lshift(1, pos)) ~= 0;
end

-- Draw tier stars via drawlist (avoids encoding issues).
-- Draws filled/empty circles at the given screen position.
-- Returns total width drawn.
local function drawTierDots(dl, x, y, tier, maxTier)
    maxTier = maxTier or 4;
    local radius = 4;
    local gap    = 12;
    for i = 1, maxTier do
        local cx = x + (i - 1) * gap + radius;
        local cy = y + radius;
        if i <= tier then
            dl:AddCircleFilled({ cx, cy }, radius, imgui.GetColorU32(COL.starOn), 12);
        else
            dl:AddCircle({ cx, cy }, radius, imgui.GetColorU32(COL.starOff), 12, 1);
        end
    end
    return maxTier * gap;
end

------------------------------------------------------------
-- Tooltip rendering (matches LQS dragonslaying pattern)
------------------------------------------------------------
local function renderItemTooltip(itemId, augStrings, location)
    local res = getItemRes(itemId);
    if res == nil then return; end

    local name = (res.Name and res.Name[1]) or '???';

    imgui.BeginTooltip();
    imgui.PushTextWrapPos(300);

    if renderIcon(itemId, 32) then
        imgui.SameLine();
    end
    imgui.TextColored(ui.color('header'), name);

    imgui.Separator();

    local flags = res.Flags or 0;
    if bit.band(flags, 0x8000) ~= 0 then
        imgui.TextColored({ 1.00, 0.85, 0.30, 1.00 }, 'Rare');
        imgui.SameLine();
    end
    if bit.band(flags, 0x4000) ~= 0 then
        imgui.TextColored({ 0.40, 0.90, 0.40, 1.00 }, 'Ex');
    end

    if res.Description and res.Description[1] and res.Description[1] ~= '' then
        imgui.Spacing();
        imgui.TextColored(ui.color('dimmed'), res.Description[1]);
    end

    -- Augments in pink
    if augStrings and #augStrings > 0 then
        imgui.Spacing();
        for _, aug in ipairs(augStrings) do
            imgui.TextColored(COL.pink, aug);
        end
    end

    -- Level + Jobs
    if res.Level and res.Level > 0 then
        imgui.Spacing();
        local infoStr = string.format('Lv.%d', res.Level);
        imgui.TextColored({ 0.55, 0.75, 0.55, 1.00 }, infoStr);
    end

    -- Location
    if location then
        imgui.Spacing();
        imgui.TextColored(COL.owned, location);
    end

    imgui.PopTextWrapPos();
    imgui.EndTooltip();
end

------------------------------------------------------------
-- Section rendering helpers
------------------------------------------------------------
local function sectionHeader(label, count, total)
    local tint = COL.sea;
    local bgColor = { tint[1], tint[2], tint[3], 0.85 };
    local barColor = { tint[1] * 2.5, tint[2] * 2.5, tint[3] * 2.5, 1.0 };

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(string.format('##lum_hdr_%s', label), { -1, 24 }, false);

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    dl:AddRectFilled({ wx, wy }, { wx + 3, wy + 24 }, imgui.GetColorU32(barColor));

    imgui.SetCursorPos({ 10, 4 });
    imgui.TextColored(ui.color('accent'), label);

    if count ~= nil then
        local countStr = total and string.format('%d/%d', count, total)
                               or  string.format('(%d)', count);
        local ww = imgui.GetWindowWidth();
        imgui.SameLine(ww - imgui.CalcTextSize(countStr) - 12);
        imgui.SetCursorPosY(4);
        local col = (total and count >= total) and COL.owned or ui.color('dimmed');
        imgui.TextColored(col, countStr);
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);
end

-- Render an armor set (Homam or Nashira) with icons and star tiers
local function renderArmorSet(setName, pieces, tiers)
    local ownedCount = 0;
    for i = 1, 5 do
        if tiers[i] and tiers[i] > 0 then ownedCount = ownedCount + 1; end
    end

    sectionHeader(setName, ownedCount, 5);
    imgui.Spacing();

    for i, piece in ipairs(pieces) do
        local tier = (tiers[i] or 0);
        local owned = tier > 0;
        local augTier = tier - 1; -- 0 = base, 1-3 = augment tiers

        local base = ui.color('childBg');
        local bgColor = owned
            and { 0.12, 0.22, 0.12, 0.50 }
            or  { base[1], base[2], base[3], (i % 2 == 0) and 0.35 or 0.20 };

        local rowId = string.format('##lum_arm_%s_%d', setName, i);
        imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
        imgui.BeginChild(rowId, { -1, 32 }, false);

        -- Icon
        imgui.SetCursorPos({ 6, 4 });
        if not renderIcon(piece.id, 24) then
            imgui.Dummy({ 24, 24 });
        end

        -- Invisible selectable for hover
        imgui.SameLine(34);
        imgui.SetCursorPosY(0);
        imgui.Selectable(string.format('##lsel_%s_%d', setName, i), false,
            ImGuiSelectableFlags_SpanAllColumns, { 0, 32 });
        local hovered = imgui.IsItemHovered();

        -- Drawlist overlay
        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();
        local ww = imgui.GetWindowWidth();

        -- Stars on right
        local stars = tierStars(augTier, 3);
        local starsW = imgui.CalcTextSize(stars);
        local starsX = wx + ww - starsW - 8;
        dl:AddText({ starsX, wy + 9 },
            imgui.GetColorU32(owned and COL.starOn or COL.starOff), stars);

        -- Name
        local nameCol = owned and COL.owned or COL.unowned;
        dl:AddText({ wx + 36, wy + 3 }, imgui.GetColorU32(nameCol), piece.name);

        -- Slot subtitle
        dl:AddText({ wx + 36, wy + 17 }, imgui.GetColorU32(ui.color('dimmed')), piece.slot);

        imgui.EndChild();
        imgui.PopStyleColor(1);

        -- Tooltip with augments
        if hovered then
            local augStrings = nil;
            if augTier >= 1 and augTier <= 3 and piece.augs and piece.augs[augTier] then
                augStrings = piece.augs[augTier];
            end
            renderItemTooltip(piece.id, augStrings);
        end
    end

    imgui.Spacing();
end

-- Render a collection row (torque/weapon) with icon and owned state
local function renderCollectionItem(item, owned, index)
    local base = ui.color('childBg');
    local bgColor = owned
        and { 0.12, 0.22, 0.12, 0.50 }
        or  { base[1], base[2], base[3], (index % 2 == 0) and 0.35 or 0.20 };

    local rowId = string.format('##lum_col_%d_%d', item.id, index);
    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(rowId, { -1, 28 }, false);

    imgui.SetCursorPos({ 6, 2 });
    if not renderIcon(item.id, 24) then
        imgui.Dummy({ 24, 24 });
    end

    imgui.SameLine(34);
    imgui.SetCursorPosY(0);
    imgui.Selectable(string.format('##lcsel_%d_%d', item.id, index), false,
        ImGuiSelectableFlags_SpanAllColumns, { 0, 28 });
    local hovered = imgui.IsItemHovered();

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    -- Name
    local nameCol = owned and COL.owned or COL.unowned;
    dl:AddText({ wx + 36, wy + 7 }, imgui.GetColorU32(nameCol), item.name);

    -- Right side: tick if owned, NM source if not
    if owned then
        dl:AddText({ wx + ww - 16, wy + 7 },
            imgui.GetColorU32(COL.owned), '*');
    elseif item.nm then
        local nmW = imgui.CalcTextSize(item.nm);
        dl:AddText({ wx + ww - nmW - 8, wy + 7 },
            imgui.GetColorU32(ui.color('dimmed')), item.nm);
    end

    imgui.EndChild();
    imgui.PopStyleColor(1);

    if hovered then
        renderItemTooltip(item.id);
    end
end

-- Render material counts (Omega/Ultima pieces)
local function renderMaterialRow(item, count, index)
    local base = ui.color('childBg');
    local bgColor = { base[1], base[2], base[3], (index % 2 == 0) and 0.35 or 0.20 };

    local rowId = string.format('##lum_mat_%d_%d', item.id, index);
    imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
    imgui.BeginChild(rowId, { -1, 28 }, false);

    imgui.SetCursorPos({ 6, 2 });
    if not renderIcon(item.id, 24) then
        imgui.Dummy({ 24, 24 });
    end

    imgui.SameLine(34);
    imgui.SetCursorPosY(0);
    imgui.Selectable(string.format('##lmsel_%d_%d', item.id, index), false,
        ImGuiSelectableFlags_SpanAllColumns, { 0, 28 });
    local hovered = imgui.IsItemHovered();

    local dl = imgui.GetWindowDrawList();
    local wx, wy = imgui.GetWindowPos();
    local ww = imgui.GetWindowWidth();

    local nameCol = (count > 0) and ui.color('white') or COL.unowned;
    dl:AddText({ wx + 36, wy + 7 }, imgui.GetColorU32(nameCol), item.name);

    local countStr = string.format('x%d', count);
    local countCol = (count > 0) and ui.color('white') or COL.unowned;
    local countW = imgui.CalcTextSize(countStr);
    dl:AddText({ wx + ww - countW - 8, wy + 7 }, imgui.GetColorU32(countCol), countStr);

    imgui.EndChild();
    imgui.PopStyleColor(1);

    if hovered then renderItemTooltip(item.id); end
end

------------------------------------------------------------
-- Compact armor column (for side-by-side layout)
------------------------------------------------------------
local function renderArmorColumn(setName, pieces, tiers, matPieces, matCounts, locMask, colWidth)
    local ownedCount = 0;
    for i = 1, 5 do
        if tiers[i] and tiers[i] > 0 then ownedCount = ownedCount + 1; end
    end

    -- Mini header
    local headerCol = (ownedCount >= 5) and COL.owned or ui.color('accent');
    imgui.TextColored(headerCol, string.format('%s  %d/5', setName, ownedCount));
    imgui.Spacing();

    for i, piece in ipairs(pieces) do
        -- tier: 0=not owned, 1=base, 2=aug T1, 3=aug T2, 4=aug T3
        local tier = (tiers[i] or 0);
        local owned = tier > 0;
        local matCount = (matCounts and matCounts[i]) or 0;

        local base = ui.color('childBg');
        local bgColor = owned
            and { 0.12, 0.22, 0.12, 0.50 }
            or  { base[1], base[2], base[3], (i % 2 == 0) and 0.35 or 0.20 };

        local rowId = string.format('##lum_ac_%s_%d', setName, i);
        imgui.PushStyleColor(ImGuiCol_ChildBg, bgColor);
        imgui.BeginChild(rowId, { colWidth, 46 }, false, ImGuiWindowFlags_NoScrollbar);

        -- Armor icon
        imgui.SetCursorPos({ 4, 7 });
        if not renderIcon(piece.id, 24) then
            imgui.Dummy({ 24, 24 });
        end

        imgui.SameLine(30);
        imgui.SetCursorPosY(0);
        imgui.Selectable(string.format('##lacsel_%s_%d', setName, i), false,
            ImGuiSelectableFlags_SpanAllColumns, { 0, 46 });
        local hovered = imgui.IsItemHovered();

        local dl = imgui.GetWindowDrawList();
        local wx, wy = imgui.GetWindowPos();

        -- Right side: material icon + count
        local rightX = wx + colWidth - 6;
        local countStr = string.format('x%d', matCount);
        local countW = imgui.CalcTextSize(countStr);
        rightX = rightX - countW;
        local matCol = (matCount > 0) and ui.color('white') or COL.unowned;
        dl:AddText({ rightX, wy + 12 }, imgui.GetColorU32(matCol), countStr);

        -- Draw material icon to the left of count
        local mat = matPieces and matPieces[i];
        if mat then
            local savedX = imgui.GetCursorPosX();
            local savedY = imgui.GetCursorPosY();
            imgui.SetCursorScreenPos({ rightX - 22, wy + 8 });
            renderIcon(mat.id, 20);
            imgui.SetCursorPos({ savedX, savedY });
        end

        -- Name on top line
        local nameCol = owned and COL.owned or COL.unowned;
        local maxNameW = rightX - 24 - (wx + 32) - 8; -- account for mat icon
        local displayName = piece.name;
        if imgui.CalcTextSize(displayName) > maxNameW and maxNameW > 20 then
            while #displayName > 1 and imgui.CalcTextSize(displayName .. '..') > maxNameW do
                displayName = displayName:sub(1, -2);
            end
            displayName = displayName .. '..';
        end
        dl:AddText({ wx + 32, wy + 4 }, imgui.GetColorU32(nameCol), displayName);

        -- Augment dots on second line (0-3 filled, 3 max)
        local augTierDots = math.max(tier - 1, 0); -- tier 1=base=0 dots, tier 2=1, etc
        drawTierDots(dl, wx + 32, wy + 22, augTierDots, 3);

        imgui.EndChild();
        imgui.PopStyleColor(1);

        if hovered then
            local augStrings = {};
            local augTier = tier - 1; -- 0=base, 1-3=aug tiers
            if owned then
                if augTier >= 1 and augTier <= 3 and piece.augs and piece.augs[augTier] then
                    for _, a in ipairs(piece.augs[augTier]) do
                        augStrings[#augStrings + 1] = a;
                    end
                else
                    augStrings[#augStrings + 1] = 'Base (no augments)';
                end
            end
            local loc = nil;
            if owned then
                loc = hasBit(locMask, i - 1) and 'Squire' or 'Inventory';
            end
            renderItemTooltip(piece.id, augStrings, loc);
        end
    end
end

------------------------------------------------------------
-- Icon grid row (for torques/weapons)
------------------------------------------------------------
local function renderIconGrid(label, items, bitmask, total)
    local count = 0;
    for i = 0, total - 1 do
        if hasBit(bitmask, i) then count = count + 1; end
    end

    sectionHeader(label, count, total);
    imgui.Spacing();

    local iconSize = 32;
    local padding  = 4;

    for i, item in ipairs(items) do
        local owned = hasBit(bitmask, i - 1);

        if i > 1 then imgui.SameLine(0, padding); end

        -- Tint unowned icons
        if not owned then
            imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35);
        end

        imgui.BeginGroup();
        if not renderIcon(item.id, iconSize) then
            imgui.Dummy({ iconSize, iconSize });
        end
        imgui.EndGroup();

        if not owned then
            imgui.PopStyleVar(1);
        end

        -- Owned border
        if owned then
            local dl = imgui.GetWindowDrawList();
            local rx, ry = imgui.GetItemRectMin();
            local rx2, ry2 = imgui.GetItemRectMax();
            dl:AddRect({ rx, ry }, { rx2, ry2 }, imgui.GetColorU32(COL.owned), 2, 0, 2);
        end

        if imgui.IsItemHovered() then
            local status = owned and 'Collected' or item.nm;
            imgui.BeginTooltip();
            imgui.TextColored(ui.color('header'), item.name);
            if item.nm then
                imgui.TextColored(ui.color('dimmed'), item.nm);
            end
            imgui.Separator();
            if owned then
                imgui.TextColored(COL.owned, 'Collected');
            else
                imgui.TextColored(COL.unowned, 'Not collected');
            end
            imgui.EndTooltip();
        end
    end

    imgui.Spacing();
end

------------------------------------------------------------
-- Main window
------------------------------------------------------------
local function renderWindow()
    local pushed = ui.pushWindowStyle();
    imgui.SetNextWindowSize({ 680, 600 }, ImGuiCond_FirstUseEver);

    if imgui.Begin('Lumoria##trove_lumoria', isOpen, 0) then
        local _bgPop = ui.renderBackground();

        -- Refresh on open transition
        if not wasOpen then
            wasOpen = true;
            loaded  = false;
            loading = false;
        end

        if not loaded then
            if not loading then
                requestData();
            elseif os.clock() - requestTime > 3.0 then
                loading = false; -- timeout, allow retry on next open
                ui.dim('No response from server.');
            end
            if loading then ui.dim('Loading...'); end
            imgui.End();
            ui.popWindowStyle(pushed);
            return;
        end

        imgui.BeginChild('##lum_scroll', { 0, 0 }, false);

        local fullW = imgui.GetContentRegionAvail();

        -- ══════════════════════════════════════
        -- Buffs (compact 2-column grid)
        -- ══════════════════════════════════════
        local buffCount = 0;
        for i = 0, 9 do
            if hasBit(data.buffs, i) then buffCount = buffCount + 1; end
        end
        sectionHeader('Storming Sea Buffs', buffCount, 10);
        imgui.Spacing();

        local halfW = (fullW - 8) / 2;
        for i, b in ipairs(BUFFS) do
            local active = hasBit(data.buffs, i - 1);
            local col = active and COL.buffOn or COL.buffOff;

            if i > 1 and (i % 2 == 1) then
                -- odd = new row (already on new line)
            elseif i > 1 then
                imgui.SameLine(halfW + 12);
            end

            -- Chip icon + buff name
            if not active then imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.45); end
            renderIcon(b.chip, 16);
            if not active then imgui.PopStyleVar(1); end
            imgui.SameLine(0, 4);
            imgui.TextColored(col, b.name);

            if imgui.IsItemHovered() then
                imgui.BeginTooltip();
                imgui.TextColored(ui.color('header'), b.name);
                imgui.Separator();
                imgui.TextColored(COL.pink, b.desc);
                imgui.Spacing();
                imgui.TextColored(COL.starOn, string.format('%s  %s  %s', b.nm, b.zone, b.pos));
                imgui.TextColored(ui.color('dimmed'), b.chipName);
                imgui.TextColored({ 0.55, 0.75, 0.55, 1.00 }, 'Drops: ' .. b.jobs);
                if active then
                    imgui.Spacing();
                    imgui.TextColored(COL.owned, 'Active');
                end
                imgui.EndTooltip();
            end
        end
        imgui.Spacing();
        imgui.Spacing();

        -- ══════════════════════════════════════
        -- Homam | Nashira (side by side)
        -- ══════════════════════════════════════
        local colW = math.floor((fullW - 12) / 2);
        sectionHeader('Limbus Armor', nil, nil);
        imgui.Spacing();

        local armorH = 5 * 48 + 54; -- 5 rows + header + spacing
        imgui.BeginChild('##lum_homam_col', { colW, armorH }, false);
        renderArmorColumn('Homam', HOMAM, data.homamTiers, OMEGA_PIECES, data.omegaCounts, data.homamLoc, colW);
        imgui.EndChild();

        imgui.SameLine(0, 12);

        imgui.BeginChild('##lum_nashira_col', { colW, armorH }, false);
        renderArmorColumn('Nashira', NASHIRA, data.nashiraTiers, ULTIMA_PIECES, data.ultimaCounts, data.nashiraLoc, colW);
        imgui.EndChild();

        imgui.Spacing();

        -- ══════════════════════════════════════
        -- Torques | Weapons (side by side icon grids)
        -- ══════════════════════════════════════
        sectionHeader('Sea Collection', nil, nil);
        imgui.Spacing();

        -- Torques column
        imgui.BeginChild('##lum_torq_col', { colW, 68 }, false);
        local torqueCount = 0;
        for i = 0, 6 do if hasBit(data.torques, i) then torqueCount = torqueCount + 1; end end
        imgui.TextColored(ui.color('accent'), string.format('Torques  %d/7', torqueCount));
        imgui.Spacing();
        for i, item in ipairs(TORQUES) do
            local owned = hasBit(data.torques, i - 1);
            if i > 1 then imgui.SameLine(0, 3); end
            if not owned then imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35); end
            imgui.BeginGroup();
            if not renderIcon(item.id, 30) then imgui.Dummy({ 30, 30 }); end
            imgui.EndGroup();
            if not owned then imgui.PopStyleVar(1); end
            if owned then
                local dl = imgui.GetWindowDrawList();
                local rx, ry = imgui.GetItemRectMin();
                local rx2, ry2 = imgui.GetItemRectMax();
                dl:AddRect({ rx, ry }, { rx2, ry2 },
                    imgui.GetColorU32(COL.owned), 2, 0, 2);
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip();
                imgui.TextColored(ui.color('header'), item.name);
                if item.nm then imgui.TextColored(ui.color('dimmed'), item.nm); end
                imgui.Separator();
                if owned then
                    local loc = hasBit(data.torqueLoc, i - 1) and 'Squire' or 'Inventory';
                    imgui.TextColored(COL.owned, loc);
                else
                    imgui.TextColored(COL.unowned, 'Not collected');
                end
                imgui.EndTooltip();
            end
        end
        imgui.EndChild();

        imgui.SameLine(0, 12);

        -- Weapons column
        imgui.BeginChild('##lum_weap_col', { colW, 68 }, false);
        local weaponCount = 0;
        for i = 0, 6 do if hasBit(data.weapons, i) then weaponCount = weaponCount + 1; end end
        imgui.TextColored(ui.color('accent'), string.format('Weapons  %d/7', weaponCount));
        imgui.Spacing();
        for i, item in ipairs(WEAPONS) do
            local owned = hasBit(data.weapons, i - 1);
            if i > 1 then imgui.SameLine(0, 3); end
            if not owned then imgui.PushStyleVar(ImGuiStyleVar_Alpha, 0.35); end
            imgui.BeginGroup();
            if not renderIcon(item.id, 30) then imgui.Dummy({ 30, 30 }); end
            imgui.EndGroup();
            if not owned then imgui.PopStyleVar(1); end
            if owned then
                local dl = imgui.GetWindowDrawList();
                local rx, ry = imgui.GetItemRectMin();
                local rx2, ry2 = imgui.GetItemRectMax();
                dl:AddRect({ rx, ry }, { rx2, ry2 },
                    imgui.GetColorU32(COL.owned), 2, 0, 2);
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip();
                imgui.TextColored(ui.color('header'), item.name);
                if item.nm then imgui.TextColored(ui.color('dimmed'), item.nm); end
                imgui.Separator();
                if owned then
                    local loc = hasBit(data.weaponLoc, i - 1) and 'Squire' or 'Inventory';
                    imgui.TextColored(COL.owned, loc);
                else
                    imgui.TextColored(COL.unowned, 'Not collected');
                end
                imgui.EndTooltip();
            end
        end
        imgui.EndChild();

        -- ══════════════════════════════════════
        -- Sea Organs (compact inline)
        -- ══════════════════════════════════════
        local organTotal = 0;
        for i = 1, #ORGANS do
            organTotal = organTotal + (data.organInv[i] or 0) + (data.organVision[i] or 0);
        end
        sectionHeader('Sea Organs', organTotal, nil);
        imgui.Spacing();

        for i, o in ipairs(ORGANS) do
            local inv = data.organInv[i] or 0;
            local vis = data.organVision[i] or 0;
            local total = inv + vis;

            if i > 1 then imgui.SameLine(0, 12); end

            imgui.BeginGroup();
            if not renderIcon(o.id, 26) then
                imgui.Dummy({ 26, 26 });
            end
            -- Gold border for HQ organs
            if o.hq then
                local dl = imgui.GetWindowDrawList();
                local rx, ry = imgui.GetItemRectMin();
                local rx2, ry2 = imgui.GetItemRectMax();
                dl:AddRect({ rx - 1, ry - 1 }, { rx2 + 1, ry2 + 1 },
                    imgui.GetColorU32(ui.color('white')), 2, 0, 2);
            end
            imgui.SameLine(0, 4);
            imgui.SetCursorPosY(imgui.GetCursorPosY() + 5);
            local numCol = (total > 0) and ui.color('white') or COL.unowned;
            imgui.TextColored(numCol, tostring(total));
            imgui.EndGroup();

            if imgui.IsItemHovered() then
                imgui.BeginTooltip();
                imgui.TextColored(ui.color('header'), o.name);
                imgui.Separator();
                imgui.TextColored(ui.color('dimmed'), string.format('Inventory: %d', inv));
                imgui.TextColored(ui.color('dimmed'), string.format('Vision:    %d', vis));
                imgui.Spacing();
                imgui.TextColored(ui.color('white'), string.format('Total: %d', total));
                imgui.EndTooltip();
            end
        end

        imgui.EndChild();
        if _bgPop > 0 then imgui.PopStyleColor(_bgPop); end
    end
    imgui.End();
    ui.popWindowStyle(pushed);
end

------------------------------------------------------------
-- Plugin interface
------------------------------------------------------------
return {
    name        = 'Lumoria',
    author      = 'Loxley',
    version     = '1.0',
    description = 'Sea collection tracker with augment tiers',
    pluginId    = PLUGIN_ID,

    init = function(iconFn, itemResFn, uiModule, tooltipFn)
        renderIcon    = iconFn;
        getItemRes    = itemResFn;
        ui            = uiModule;
        renderTooltip = tooltipFn;
    end,

    commands = {
        lumoria = function(state) isOpen[1] = not isOpen[1]; end,
        sea     = function(state) isOpen[1] = not isOpen[1]; end,
    },

    onRender = function(state)
        -- Track close so next open triggers refresh
        if not isOpen[1] then
            wasOpen = false;
        end
    end,

    onPluginData = function(rawData, state)
        -- Parse Lumoria payload starting at offset 0x06
        local function u8(off)
            return struct.unpack('B', rawData, off + 1);
        end

        data.buffs = u8(0x06) + u8(0x07) * 256;
        data.torques = u8(0x08);
        data.weapons = u8(0x09);

        data.homamTiers = {};
        for i = 1, 5 do data.homamTiers[i] = u8(0x09 + i); end

        data.nashiraTiers = {};
        for i = 1, 5 do data.nashiraTiers[i] = u8(0x0E + i); end

        data.omegaCounts = {};
        for i = 1, 5 do data.omegaCounts[i] = u8(0x13 + i); end

        data.ultimaCounts = {};
        for i = 1, 5 do data.ultimaCounts[i] = u8(0x18 + i); end

        local organCount = 12;
        data.organInv = {};
        for i = 1, organCount do data.organInv[i] = u8(0x1D + i); end

        data.organVision = {};
        for i = 1, organCount do data.organVision[i] = u8(0x1D + organCount + i); end

        local locBase = 0x1D + organCount * 2 + 1;
        data.torqueLoc  = u8(locBase);
        data.weaponLoc  = u8(locBase + 1);
        data.homamLoc   = u8(locBase + 2);
        data.nashiraLoc = u8(locBase + 3);

        loaded  = true;
        loading = false;
    end,

    window = {
        category = 'Collections',
        isOpen = isOpen,
        label  = 'Lumoria',
        icon   = 15514,  -- Love Torque
        render = renderWindow,
    },
};
