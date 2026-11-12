-- UDP-loopback receiver for chat window anchor broadcasts.
-- Listens on a per-PID port (49152..65535 range) for "x,y,w,h,v,e"
-- (single-window) or 12-field (dual-window) packets sent by
-- fancychat. Values are cached per window; stale data older than 2s
-- makes get() return nil so the compass can fall back gracefully.

local M = {}
local socket = require('socket')

-- Per-process port derived from the FFXI process's PID. Both
-- fancychat (sender) and fancycompass (receiver) live in the same
-- process, so they hash the SAME PID to the SAME port. Different
-- game instances get different PIDs -> different ports -> no bind
-- conflict + no cross-instance packet bleed. Hash uses two
-- murmur-style rounds to break Windows's multiple-of-4 PID bias;
-- mod 0x3FFF lands in the 16384-slot dynamic port range. Collision
-- probability at 10 simultaneous instances is ~0.27%.
local function pid_to_port()
    local ok, ffi = pcall(require, 'ffi')
    if not ok then return 47180 end
    pcall(ffi.cdef, 'unsigned long GetCurrentProcessId();')
    local pid = tonumber(ffi.C.GetCurrentProcessId())
    local x = bit.bxor(bit.rshift(pid, 16), pid)
    x = bit.band(x * 0x85ebca6b, 0xFFFFFFFF)
    x = bit.bxor(bit.rshift(x, 13), x)
    x = bit.band(x * 0xc2b2ae35, 0xFFFFFFFF)
    x = bit.bxor(bit.rshift(x, 16), x)
    return 49152 + bit.band(x, 0x3FFF)
end

local PORT  = pid_to_port()
local udp   = nil
-- Per-window cache. Index 1 = primary chat, 2 = secondary chat.
local cache = {
    [1] = { x = 0, y = 0, w = 0, h = 0, visible = 1, extra = 0 },
    [2] = { x = 0, y = 0, w = 0, h = 0, visible = 0, extra = 0 },
}
local last_recv = -math.huge

function M.init()
    udp = socket.udp()
    local ok = udp:setsockname('127.0.0.1', PORT)
    if not ok then
        udp:close()
        udp = nil
        return false
    end
    udp:settimeout(0)
    return true
end

function M.status()
    if udp == nil then return 'Socket error' end
    if os.clock() - last_recv > 2 then return 'FC Offline' end
    return 'Connected'
end

local function set_window(w_idx, x, y, w, h, v, e)
    local c = cache[w_idx]
    c.x, c.y, c.w, c.h = x, y, w, h
    c.visible, c.extra = v, e
end

function M.poll()
    if udp == nil then return end
    while true do
        local data = udp:receive()
        if not data then break end
        -- Try 12-field (both windows).
        local n = {}
        local cnt = 0
        for tok in data:gmatch('(%-?%d+)') do
            cnt = cnt + 1
            n[cnt] = tonumber(tok)
        end
        if cnt >= 12 then
            set_window(1, n[1], n[2], n[3], n[4], n[5],  n[6])
            set_window(2, n[7], n[8], n[9], n[10], n[11], n[12])
            last_recv = os.clock()
        elseif cnt >= 6 then
            set_window(1, n[1], n[2], n[3], n[4], n[5], n[6])
            -- Old sender doesn't know about window 2 -> mark invisible.
            cache[2].visible = 0
            last_recv = os.clock()
        elseif cnt >= 5 then
            set_window(1, n[1], n[2], n[3], n[4], n[5], 0)
            cache[2].visible = 0
            last_recv = os.clock()
        end
    end
end

-- get(w_idx) returns the cache for window 1 or 2, or nil when stale.
function M.get(w_idx)
    if os.clock() - last_recv > 2 then return nil end
    return cache[w_idx or 1]
end

function M.shutdown()
    if udp then
        udp:close()
        udp = nil
    end
end

return M
