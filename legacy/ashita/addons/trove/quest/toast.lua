--[[
* lqs/panels/toast.lua — Quest notification toasts
*
* Uses Ashita's fonts library (same as zonename addon).
* Pre-creates font objects, shows/hides them as needed.
]]--

local fonts = require('fonts');
local d3d8  = require('d3d8');

local toast = {};
toast.enabled = true;
toast.onQuestEvent = nil;  -- callback: function() called when quest accepted/completed

-- Screen dimensions
local d3d8dev = d3d8.get_device();
local _, viewport = d3d8dev:GetViewport();
local screenW = viewport and viewport.Width or 1024;
local screenH = viewport and viewport.Height or 768;

-- Timing
local FADE_IN  = 0.4;
local VISIBLE  = 3.5;
local FADE_OUT = 1.0;
local TOAST_Y  = math.floor(screenH * 0.2);

-- Pre-create a pool of font objects (max 4 simultaneous toasts)
local MAX_TOASTS = 4;
local pool = {};

local fontSettings = {
    visible       = false,
    font_family   = 'Century Schoolbook',
    font_height   = 24,
    color         = 0xFFFFD700,
    color_outline = 0xFF000000,
    draw_flags    = 0x10,  -- FontDrawFlags.Outlined
    bold          = true,
    italic        = false,
    position_x    = 0,
    position_y    = 0,
    background    = { visible = false },
};

for i = 1, MAX_TOASTS do
    pool[i] = {
        font  = fonts.new(fontSettings),
        active = false,
        text   = '',
        baseColor = 0,
        startTime = 0,
    };
end

-- Queue for pending toasts
local queue = {};

-- Quest message patterns
local PATTERNS = {
    { pattern = '\129\158 Quest Accepted: (.+)',    color = 0xFFFFD700, prefix = 'Quest Accepted'    },
    { pattern = '\129\159 Quest Completed: (.+)',   color = 0xFF55E855, prefix = 'Quest Completed'   },
    { pattern = '\129\159 Mission Completed: (.+)', color = 0xFF88DDFF, prefix = 'Mission Completed' },
};

------------------------------------------------------------
-- Add a toast
------------------------------------------------------------
toast.add = function(text, color)
    table.insert(queue, { text = text, color = color or 0xFFFFD700 });
end

------------------------------------------------------------
-- Check incoming packets for quest messages
------------------------------------------------------------
toast.checkChat = function(e)
    if not toast.enabled then return; end

    local ok, pktByte = pcall(struct.unpack, 'B', e.data_modified, 0x02 + 1);
    if not ok then return; end
    local pktSize = pktByte * 2;
    if pktSize < 32 then return; end

    local searchEnd = pktSize - 20;
    if searchEnd < 0x04 then return; end

    for off = 0x04, searchEnd do
        local ok1, b1 = pcall(struct.unpack, 'B', e.data_modified, off + 1);
        local ok2, b2 = pcall(struct.unpack, 'B', e.data_modified, off + 2);
        if not ok1 or not ok2 then break; end

        if b1 == 0x81 and (b2 == 0x9E or b2 == 0x9F) then
            local bytes = {};
            for i = off, off + 100 do
                local okb, b = pcall(struct.unpack, 'B', e.data_modified, i + 1);
                if not okb or b == 0 then break; end
                table.insert(bytes, string.char(b));
            end
            local msg = table.concat(bytes);

            for _, p in ipairs(PATTERNS) do
                local questName = msg:match(p.pattern);
                if questName then
                    toast.add(string.format('%s: %s', p.prefix, questName), p.color);
                    if toast.onQuestEvent then toast.onQuestEvent(); end
                    return;
                end
            end
        end
    end
end

------------------------------------------------------------
-- Update toasts (call from d3d_present)
------------------------------------------------------------
toast.render = function()
    local now = os.clock();

    -- Activate queued toasts into free pool slots
    while #queue > 0 do
        local slot = nil;
        for i = 1, MAX_TOASTS do
            if not pool[i].active then
                slot = pool[i];
                break;
            end
        end
        if not slot then break; end  -- no free slots

        local q = table.remove(queue, 1);
        slot.active    = true;
        slot.text      = q.text;
        slot.baseColor = q.color;
        slot.startTime = now;

        -- Center text
        local approxWidth = #q.text * 12;
        slot.font.position_x = math.floor((screenW - approxWidth) / 2);
        slot.font.text    = q.text;
        slot.font.visible = true;
    end

    -- Update active toasts
    local visibleIdx = 0;
    for i = 1, MAX_TOASTS do
        local t = pool[i];
        if t.active then
            local elapsed = now - t.startTime;
            local totalDuration = FADE_IN + VISIBLE + FADE_OUT;

            if elapsed > totalDuration then
                t.active = false;
                t.font.visible = false;
            else
                -- Alpha
                local alpha = 255;
                if elapsed < FADE_IN then
                    alpha = (elapsed / FADE_IN) * 255;
                elseif elapsed > FADE_IN + VISIBLE then
                    alpha = (1.0 - (elapsed - FADE_IN - VISIBLE) / FADE_OUT) * 255;
                end
                if alpha < 0 then alpha = 0; end
                if alpha > 255 then alpha = 255; end
                alpha = math.floor(alpha);

                -- Update color with alpha
                local rgb = bit.band(t.baseColor, 0x00FFFFFF);
                t.font.color = bit.bor(bit.lshift(alpha, 24), rgb);
                t.font.color_outline = bit.bor(bit.lshift(alpha, 24), 0x000000);

                -- Stack vertically
                t.font.position_y = TOAST_Y + visibleIdx * 40;
                visibleIdx = visibleIdx + 1;
            end
        end
    end
end

------------------------------------------------------------
-- Cleanup
------------------------------------------------------------
toast.cleanup = function()
    for i = 1, MAX_TOASTS do
        pool[i].active = false;
        pool[i].font.visible = false;
    end
end

return toast;
