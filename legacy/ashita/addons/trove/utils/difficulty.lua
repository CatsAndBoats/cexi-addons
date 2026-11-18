--[[
* lqs/utils/difficulty.lua — Universal difficulty ranking
*
* Shared across all plugins for consistent difficulty display.
*
* Usage:
*     local diff = require('utils/difficulty');
*     diff.getLabel(3)  -- "Advanced"
*     diff.getColor(3)  -- { 1.00, 0.92, 0.60, 1.0 }
*     diff.render(3)    -- renders colored label via imgui
]]--

local imgui = require('imgui');

local difficulty = {};

local RANKS = {
    [1] = { label = 'Novice',       color = { 0.55, 0.90, 0.55, 1.0 } },
    [2] = { label = 'Intermediate', color = { 0.55, 0.85, 1.00, 1.0 } },
    [3] = { label = 'Advanced',     color = { 1.00, 0.92, 0.60, 1.0 } },
    [4] = { label = 'Expert',       color = { 1.00, 0.65, 0.40, 1.0 } },
    [5] = { label = 'Master',       color = { 1.00, 0.45, 0.45, 1.0 } },
    [6] = { label = 'Legendary',    color = { 0.75, 0.45, 1.00, 1.0 } },
};

difficulty.getLabel = function(rank)
    local r = RANKS[rank];
    return r and r.label or '?';
end

difficulty.getColor = function(rank)
    local r = RANKS[rank];
    return r and r.color or { 1.0, 1.0, 1.0, 1.0 };
end

-- Render as colored text (inline)
difficulty.render = function(rank)
    local r = RANKS[rank];
    if r then
        imgui.TextColored(r.color, r.label);
    end
end

-- Render as key-value pair
difficulty.renderKV = function(rank, ui)
    if ui then
        imgui.TextColored(ui.color('dimmed'), 'Difficulty:');
        imgui.SameLine(0, 4);
    end
    difficulty.render(rank);
end

-- For drawlist rendering (returns label string + color table)
difficulty.get = function(rank)
    local r = RANKS[rank];
    if r then
        return r.label, r.color;
    end
    return '?', { 1.0, 1.0, 1.0, 1.0 };
end

return difficulty;
