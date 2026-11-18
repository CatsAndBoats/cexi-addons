--[[
* Gainz - Displays FFXI recurring event time info.
* Author: Commandobill
* Version: 1.0
* License: GNU General Public License v3.0
--]]

addon.name    = 'gainz';
addon.author  = 'Commandobill';
addon.version = '1.1';
addon.desc    = 'Displays Gainz event timer info on demand.';

require('common');
local chat = require('chat');

-- Define UTC event windows (0 = Sunday)
local event_times = {
    { day = 0, start = 11 * 60, finish = 15 * 60 },   -- Sunday 11:00–15:00 UTC
    { day = 2, start = 3 * 60, finish = 7 * 60 },     -- Tuesday 03:00–07:00 UTC
    { day = 3, start = 19 * 60, finish = 23 * 60 },   -- Wednesday 19:00–23:00 UTC
}

-- Helper to format duration in h m
local function format_time(minutes)
    local h = math.floor(minutes / 60)
    local m = minutes % 60
    return string.format('%dh %dm', h, m)
end

-- Core logic
local function get_gainz_status()
    local now = os.date('!*t') -- UTC time
    local wday = now.wday - 1  -- Sunday=1, convert to 0-indexed
    local curr_min = now.hour * 60 + now.min
    local now_total = wday * 1440 + curr_min

    local soonest_start_diff = math.huge
    local next_msg = nil

    for _, event in ipairs(event_times) do
        local event_start_total = event.day * 1440 + event.start
        local event_end_total = event.day * 1440 + event.finish

        if now_total >= event_start_total and now_total < event_end_total then
            local minutes_left = event_end_total - now_total
            return chat.header(addon.name) .. chat.message('Gainz is active! Ends in ' .. format_time(minutes_left) .. '.')
        end

        -- Calculate how many minutes until this event starts, rolling into next week if necessary
        local time_until = event_start_total - now_total
        if time_until < 0 then
            time_until = time_until + 7 * 1440 -- add a week
        end

        if time_until < soonest_start_diff then
            soonest_start_diff = time_until
            next_msg = 'Gainz will start in ' .. format_time(time_until) .. '.'
        end
    end

    return chat.header(addon.name) .. chat.message(next_msg or 'Unable to determine gainz time.')
end


-- Register the /gainz command
ashita.events.register('command', 'gainz_command_cb', function(e)
    local args = e.command:args()
    if #args >= 1 and args[1]:lower() == '/gainz' then
        print(get_gainz_status())
        return true
    end
    return false
end)
