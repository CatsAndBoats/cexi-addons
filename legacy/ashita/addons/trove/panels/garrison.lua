--[[
* garrison - Garrison Pass panel for Trove
*
* Shows garrison item collection status read from item Extra data.
* Greyed out icons for missing items, coloured for obtained.
* Tooltips show drop zone(s).
]]--

local imgui = require('imgui');

local panel = {};
panel.isOpen     = { false };
panel.renderIcon = nil;
panel.getItemRes = nil;

------------------------------------------------------------
-- Garrison data
------------------------------------------------------------
local GARRISONS = {
    { name = "Ronfaure",         id = 1528, drops = {{zone="Fort Ghelsba", mobs={"Orcish Fighter"}},{zone="Yughott Grotto", mobs={"Orcish Fighter"}}} },
    { name = "Gustaberg",        id = 1529, drops = {{zone="Palborough Mines", mobs={"Copper Quadav"}}} },
    { name = "Sarutabaruta",     id = 1530, drops = {{zone="Giddeus", mobs={"Yagudo Votary"}}} },
    { name = "Zulkheim",         id = 1531, drops = {{zone="Ordelle's Caves", mobs={"Goblin Furrier","Goblin Pathfinder"}}} },
    { name = "Norvallen",        id = 1532, drops = {{zone="Davoi", mobs={"Orcish Brawler","Orcish Impaler","Orcish Nightraider"}}} },
    { name = "Derfland",         id = 1533, drops = {{zone="Beadeaux", mobs={"Bronze Quadav","Silver Quadav","Zircon Quadav"}}} },
    { name = "Kolshushu",        id = 1534, drops = {{zone="Maze of Shakhrami", mobs={"Goblin Shaman","Goblin Smithy"}}} },
    { name = "Aragoneu",         id = 1535, drops = {{zone="Castle Oztroja", mobs={"Yagudo Drummer","Yagudo Herald","Yagudo Interrogator"}}} },
    { name = "Qufim",            id = 1538, drops = {{zone="Qufim Island", mobs={"Giant Ascetic","Giant Trapper"}},{zone="Lower Delkfutt's Tower", mobs={"Giant Gatekeeper","Giant Guard","Giant Sentry"}},{zone="Middle Delkfutt's Tower", mobs={"Giant Gatekeeper","Giant Guard","Giant Sentry"}}} },
    { name = "Fauregandi",       id = 1536, drops = {{zone="Beaucedine Glacier", mobs={"Cold Gigas","Rime Gigas","Sleet Gigas","Snow Gigas"}}} },
    { name = "Li'Telor",         id = 1539, drops = {{zone="The Sanctuary of Zi'Tah", mobs={"Goblin Poacher","Goblin Robber","Goblin Trader"}}} },
    { name = "Elshimo Lowlands", id = 1542, drops = {{zone="Sea Serpent Grotto", mobs={"Brook Sahagin","Riparian Sahagin"}}} },
    { name = "Valdeaunia",       id = 1537, drops = {{zone="Xarcabard", mobs={"Demon Knight","Demon Pawn","Demon Wizard"}},{zone="Castle Zvahl Baileys", mobs={"Demon Knight","Demon Pawn","Demon Wizard"}},{zone="Castle Zvahl Keep", mobs={"Demon Knight","Demon Pawn","Demon Wizard"}}} },
    { name = "Kuzotz",           id = 1540, drops = {{zone="Eastern Altepa Desert", mobs={"Antican Centurio","Antican Veles"}},{zone="Western Altepa Desert", mobs={"Antican Secutor"}},{zone="Quicksand Caves", mobs={"Antican Hastatus","Antican Princeps"}}} },
    { name = "Elshimo Uplands",  id = 1543, drops = {{zone="Temple of Uggalepih", mobs={"Tonberry Cutter","Tonberry Stalker"}}} },
    { name = "Vollbow",          id = 1541, drops = {{zone="Kuftal Tunnel", mobs={"Goblin Tamer"}}} },
};

------------------------------------------------------------
-- Inventory scan (reads Garrison Pass item Extra data)
------------------------------------------------------------
local PASS_ID       = 3002;
local EXTRA_OFFSET  = 0;

local CONTAINERS = {
    { id = 0 }, { id = 1 }, { id = 2 }, { id = 4 }, { id = 5 },
    { id = 6 }, { id = 7 }, { id = 8 }, { id = 9 }, { id = 10 },
    { id = 11 }, { id = 12 }, { id = 13 }, { id = 14 }, { id = 15 }, { id = 16 },
};

local garrisonMask = 0;
local hasPass      = false;
local lastScan     = 0;

local function checkBit(mask, pos)
    return bit.band(mask, bit.lshift(1, pos)) ~= 0;
end

local function scanPass()
    local now = os.clock();
    if now - lastScan < 2 then return; end
    lastScan = now;

    garrisonMask = 0;
    hasPass      = false;

    local inventory = AshitaCore:GetMemoryManager():GetInventory();
    if inventory == nil then return; end
    for _, c in ipairs(CONTAINERS) do
        local max = inventory:GetContainerCountMax(c.id);
        if max ~= nil and max > 0 then
        for j = 0, max do
            local ok, item = pcall(function() return inventory:GetContainerItem(c.id, j); end);
            if not ok or item == nil then break; end
            if item.Id ~= 0 and item.Id ~= 65535 and item.Id == PASS_ID then
                hasPass = true;
                local extra = item.Extra;
                local b0 = struct.unpack('B', extra, 1);
                local b1 = struct.unpack('B', extra, 2);
                local b2 = struct.unpack('B', extra, 3);
                local b3 = struct.unpack('B', extra, 4);
                garrisonMask = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
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

local function renderRow(entry, bitIndex)
    local owned = checkBit(garrisonMask, bitIndex);
    local bgCol = owned and COLORS.ownedBg or COLORS.cellBg;

    imgui.PushStyleColor(ImGuiCol_ChildBg, bgCol);
    local cellId = string.format('##gp_%d', entry.id);
    imgui.BeginChild(cellId, { -1, ICON_SIZE + CELL_PAD + 2 }, true, bit.bor(ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse));

    imgui.SetCursorPos({ CELL_PAD, CELL_PAD });
    if not panel.renderIcon(entry.id, ICON_SIZE) then
        imgui.Dummy({ ICON_SIZE, ICON_SIZE });
    end

    imgui.SameLine(0, 8);
    imgui.SetCursorPosY(CELL_PAD + (ICON_SIZE - 14) / 2);
    if owned then
        imgui.TextColored(COLORS.green, entry.name);
    else
        imgui.TextColored(COLORS.dimText, entry.name);
    end
    -- Item name right-aligned
    local res = panel.getItemRes(entry.id);
    local itemName = res and res.Name[1] or '';
    local nameW = imgui.CalcTextSize(itemName);
    imgui.SameLine(imgui.GetWindowWidth() - nameW - 8);
    imgui.TextColored({ 0.55, 0.48, 0.65, 0.80 }, itemName);

    imgui.EndChild();
    imgui.PopStyleColor();

    if imgui.IsItemHovered() then
        renderTooltip(entry, owned);
    end
end

function panel.render()
    if not panel.isOpen[1] then return; end

    scanPass();

    local totalOwned = 0;
    for i = 1, #GARRISONS do
        if checkBit(garrisonMask, i) then totalOwned = totalOwned + 1; end
    end

    local title = string.format('Garrison Pass [%d/%d]###trove_garrison', totalOwned, #GARRISONS);

    imgui.SetNextWindowSize({ 300, 450 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowSizeConstraints({ 250, 300 }, { 400, 700 });

    imgui.PushStyleColor(ImGuiCol_TitleBg,         { 0.14, 0.10, 0.22, 0.95 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,    { 0.22, 0.16, 0.32, 0.95 });
    imgui.PushStyleColor(ImGuiCol_WindowBg,         { 0.10, 0.08, 0.14, 0.92 });
    imgui.PushStyleColor(ImGuiCol_Border,           { 0.35, 0.25, 0.50, 0.60 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarBg,        { 0.06, 0.05, 0.09, 0.50 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrab,     { 0.30, 0.20, 0.45, 0.60 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabHovered, { 0.40, 0.30, 0.55, 0.80 });
    imgui.PushStyleColor(ImGuiCol_ScrollbarGrabActive,  { 0.50, 0.38, 0.65, 1.00 });

    if imgui.Begin(title, panel.isOpen, ImGuiWindowFlags_None) then
        if not hasPass then
            imgui.TextColored(COLORS.dimText, 'No Garrison Pass found.');
        else
            imgui.BeginChild('##gp_scroll', { -1, -1 }, false);

            imgui.TextColored(COLORS.sectionHdr, string.format('Garrison Items (%d/%d)', totalOwned, #GARRISONS));
            imgui.Separator();
            imgui.Spacing();

            for i, entry in ipairs(GARRISONS) do
                renderRow(entry, i);
            end

            imgui.EndChild();
        end
    end
    imgui.End();
    imgui.PopStyleColor(8);
end

return panel;
