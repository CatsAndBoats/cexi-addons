--[[
clawmark-vanacore (Clawmark): raid-style target marks and waymarks for CatsEyeXI. Put one of eight marks over a
monster (or anything you can target), or one of eight waymarks on the ground where people should stand, and everyone in
your party or alliance sees it there, in the same zone, through the CatsEyeXI server's target_marks module (packet
0x1A6). Each mark sits on one target at a time, and each target carries one mark; a waymark is one place.

In game (/claw works as well as /mark):
  /mark                     the mark bar on or off
  /mark <mark>              puts the mark on your target, or takes it off if it's already there
  /mark <mark> <index>      the same on that entity index (for macros that work it out)
  /mark clear <mark>        takes a mark off;  /mark clear  takes them all off
  /mark target <mark>       targets what carries the mark
  /mark settings            the settings: theme, scale, opacity, the marks' size, chat and the right-click menu
  /mark fold                folds the bar down to the marks in use, or opens it again
  /mark size <pct>          the marks' size over targets, 50 to 300
  /mark height <n>          how far over the name they float, in their own sizes, 0 to 3
  /mark chat                the chat lines about other players' marks on or off
  /mark rclick              the right-click menu on or off
  /mark theme <name>        the colours (Party Finder's themes)
  /mark help                this list
  /wp <waymark>             puts the waymark down at your feet (/way and /waymark work the same)
  /wp <waymark> target      at your target's feet;  /wp <waymark> <yalms>  so many yalms ahead of you
  /wp clear [<waymark>]     takes one waymark off, or all of them
  /wp bar                   the waymarks' row in the bar on or off
  /wp column <yalms>        how tall the column of light over a waymark is, 0 (none) to 15
  /wp width <yalms>         how wide a waymark is, 0.5 to 4

<mark> is 1 to 8 or a name: star, circle, diamond, triangle, moon, square, cross, skull. <waymark> is A, B, C, D (round)
or 1, 2, 3, 4 (square), as FFXIV has them: a ring of light on the ground, a column of light rising from it and its letter
or number glowing over the top.

The bar: click a free mark to put it on your target; click a mark that's out to target what carries it; click the
mark your target carries to take it off. Shift-click moves a mark that's out onto your target, right-click takes it
off, and the X held for a moment takes every mark off. A line under whatever the pointer is on says what a click
will do. Under the marks, the waymarks' row: click a free one to put it down at your feet, click one that's out to take
it off, Shift-click to move it to your feet. The X held takes the waymarks off with the marks. The gear opens the
settings. Click the grip at the left end to fold the bar down to the marks and waymarks in use; hold the grip and drag
to move the bar.

Right-click a target (or a mark over one) for a menu of the marks, Take its mark off, Target it and Take every mark off.
Right-click the ground for a menu of the waymarks: click one and it goes down on that spot (a VanaCore with
vana.world.pick, the zone's collision under the pointer; on an older one the waymarks go where you stand). A right-drag
still turns the camera. /mark rclick turns the menus off and on.

Without the server module (no answer to the first sync), marks are kept for you alone and the bar says so.
Settings: settings\addons\clawmark-vanacore\settings.json.
--]]

addon.name    = 'clawmark-vanacore'
addon.author  = 'Carver'
addon.version = '1.1'
addon.desc    = 'Clawmark: raid-style target marks and waymarks shared with your party and alliance.'

local imgui = vana.imgui
if imgui == nil then
    print('clawmark-vanacore needs a newer VanaCore.Core.dll (vana.imgui)')
    return
end

local ffi = require('ffi')
local bit = require('bit')
local U = require('ui') -- Party Finder's drawing kit, as the Auction House has it (tools/make_ui.py)
local P, F, T = U.P, U.fonts(), U.sizes()

local PACKET  = 0x1A6
local VERSION = 1

local C2S = { SET = 1, CLEAR = 2, CLEAR_ALL = 3, SYNC = 4, WAY_SET = 5, WAY_CLEAR = 6, WAY_CLEAR_ALL = 7 }
local S2C = { STATE = 1, WAYMARKS = 2 }
local REASON = { SYNC = 0, SET = 1, CLEARED = 2, ALL = 3, GONE = 4, REFUSED = 5 }

-------------------------------------------------------------------------------
-- The marks
-------------------------------------------------------------------------------

local MARKS = {
    { key = 'star',     name = 'Star',     color = { 1.00, 0.82, 0.25 } },
    { key = 'circle',   name = 'Circle',   color = { 1.00, 0.52, 0.20 } },
    { key = 'diamond',  name = 'Diamond',  color = { 0.78, 0.45, 1.00 } },
    { key = 'triangle', name = 'Triangle', color = { 0.36, 0.86, 0.40 } },
    { key = 'moon',     name = 'Moon',     color = { 0.78, 0.88, 1.00 } },
    { key = 'square',   name = 'Square',   color = { 0.24, 0.60, 1.00 } },
    { key = 'cross',    name = 'Cross',    color = { 1.00, 0.28, 0.26 } },
    { key = 'skull',    name = 'Skull',    color = { 0.96, 0.94, 0.88 } },
}
local BY_KEY = {}
for i, m in ipairs(MARKS) do
    BY_KEY[m.key] = i
    m.hex = string.format('#%02X%02X%02X', m.color[1] * 255 + 0.5, m.color[2] * 255 + 0.5, m.color[3] * 255 + 0.5)
end

-- The waymarks: places on the ground, A to D round and 1 to 4 square, in FFXIV's colours
local WAYS = {
    { key = 'a', name = 'A', color = { 1.00, 0.36, 0.44 } },
    { key = 'b', name = 'B', color = { 1.00, 0.84, 0.32 } },
    { key = 'c', name = 'C', color = { 0.36, 0.80, 1.00 } },
    { key = 'd', name = 'D', color = { 0.80, 0.52, 1.00 } },
    { key = '1', name = '1', color = { 1.00, 0.36, 0.44 }, square = true },
    { key = '2', name = '2', color = { 1.00, 0.84, 0.32 }, square = true },
    { key = '3', name = '3', color = { 0.36, 0.80, 1.00 }, square = true },
    { key = '4', name = '4', color = { 0.80, 0.52, 1.00 }, square = true },
}
local WAY_BY_KEY = {}
for i, w in ipairs(WAYS) do
    WAY_BY_KEY[w.key] = i
    w.hex = string.format('#%02X%02X%02X', w.color[1] * 255 + 0.5, w.color[2] * 255 + 0.5, w.color[3] * 255 + 0.5)
end

-- scale: the interface's, in percent (0 sizes it from the screen's height); opacity: the bar's, in percent; solid: the
-- bar at full opacity under the pointer; folded: the bar folded down to its paw; height: how far over a target's name
-- its mark floats, in the mark's own sizes (0 to 3); settings_dx, settings_dy: where the settings were dragged to, from their
-- place under the bar; ways: the waymarks' row in the bar; beam: the column of light over a waymark, in yalms (0 none);
-- way_radius: a waymark's radius (a square's half-width), in yalms
local DEFAULTS = { bar = true, size = 100, chat = true, right_click = true, theme = 'aurora', scale = 0, opacity = 100,
    solid = true, folded = false, glow = true, in_target = true, height = 0.3, settings_dx = 0, settings_dy = 0,
    ways = true, beam = 6, way_radius = 1.5 }
local config = vana.settings.register({ defaults = DEFAULTS })
local cfg = config.data
if U.apply_theme(cfg.theme) == nil then U.apply_theme('aurora') end -- the menu's colours: one of Party Finder's themes

-- marks[n] = { id, index, setter, at } for mark n, or nil; ways[n] = { x, y, z, setter, at } for waymark n, or nil
local st = {
    marks = {},
    ways = {},
    server = nil,          -- nil not known yet, true it answers, false it didn't (marks are yours alone)
    sync_task = nil,
    waiting_since = nil,   -- when the last sync went out with no answer yet
    last_send = 0,
    group = nil,           -- the party and alliance as last seen, to sync again when it changes
}

local function clock() return vana.time.clock() end

local function rgba(c, a)
    local function b(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return b(a or 1) * 16777216 + b(c[3]) * 65536 + b(c[2]) * 256 + b(c[1])
end

local function say(text)
    vana.chat.write('[Clawmark] ' .. text, 142)
end

local function parse_mark(word)
    if word == nil then return nil end
    word = word:lower()
    local n = tonumber(word)
    if n and n >= 1 and n <= #MARKS then return math.floor(n) end
    return BY_KEY[word]
end

local function parse_way(word)
    if word == nil then return nil end
    return WAY_BY_KEY[word:lower()]
end

-------------------------------------------------------------------------------
-- Talking to the server
-------------------------------------------------------------------------------

local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v) return u16(v % 65536) .. u16(math.floor(v / 65536) % 65536) end

local function f32(v) return ffi.string(ffi.new('float[1]', v or 0), 4) end

-- 28 bytes: the action, the mark, a target's index and id (SET), the protocol version, and a place (WAY_SET)
local function send(action, mark, index, id, x, y, z)
    vana.packets.inject(false, PACKET,
        string.char(0, 0, 0, 0, action, mark or 0) .. u16(index or 0) .. u32(id or 0) .. string.char(VERSION, 0, 0, 0)
        .. f32(x) .. f32(y) .. f32(z))
end

local function in_world()
    return vana.game.self() ~= nil
end

local function sync()
    if not in_world() then return end
    -- zoning can ask twice in a frame (the zone change and the party list both changing)
    local now = clock()
    if now - (st.last_sync or -1) < 0.5 then return end
    st.last_sync = now
    send(C2S.SYNC)
    if st.server ~= true then st.waiting_since = st.waiting_since or clock() end
end

local function sync_soon(delay)
    if st.sync_task then vana.tasks.cancel(st.sync_task) end
    st.sync_task = vana.tasks.once(delay or 1, function () st.sync_task = nil sync() end)
end

local function entity_name(index, id)
    local e = vana.game.entity(index)
    if e and (id == nil or e.id == id) and e.name and e.name ~= '' then return e.name end
    return 'something'
end

local function player_name(id)
    if id == 0 then return nil end
    local p = vana.game.party()
    if p and p.members then
        for _, m in pairs(p.members) do
            if m.id == id and m.name and m.name ~= '' then return m.name end
        end
    end
    return 'Someone'
end

local function target_index()
    local t = vana.game.target()
    return t and t.index or 0
end

local function my_id()
    local _, id = vana.game.character()
    return id
end

-- Puts mark n on the entity, or takes it off if it's there already. Without the server, locally.
local function put(n, index)
    local e = index and index > 0 and vana.game.entity(index) or nil
    if e == nil or e.id == 0 then
        say('Target something first.')
        return
    end
    local now = clock()
    if now - st.last_send < 0.1 then return end
    st.last_send = now

    local cur = st.marks[n]
    local off = cur and cur.id == e.id
    if st.server == false then
        if off then
            st.marks[n] = nil
        else
            for k, m in pairs(st.marks) do if m.id == e.id then st.marks[k] = nil end end
            st.marks[n] = { id = e.id, index = index, setter = my_id() or 0, at = now }
        end
        return
    end
    if off then send(C2S.CLEAR, n) else send(C2S.SET, n, index, e.id) end
end

local function clear(n)
    if st.server == false then
        if n then st.marks[n] = nil else st.marks = {} end
        return
    end
    if n then send(C2S.CLEAR, n) else send(C2S.CLEAR_ALL) end
end

local function target_mark(n)
    local m = st.marks[n]
    if m == nil then
        say(MARKS[n].name .. " isn't on anything.")
        return
    end
    local e = vana.game.entity(m.index)
    if e == nil or e.id ~= m.id or not vana.game.set_target(m.index) then
        say(MARKS[n].name .. ' is on ' .. entity_name(m.index, m.id) .. ", which can't be targeted from here.")
    end
end

-- Your own entity (its index found once by your id, among the players')
local ME = { index = nil }
local function my_entity()
    local id = my_id()
    if id == nil or id == 0 then return nil end
    if ME.index then
        local e = vana.game.entity(ME.index)
        if e and e.id == id then return e end
    end
    for i = 0x400, 0x7FF do
        local e = vana.game.entity(i)
        if e and e.id == id then
            ME.index = i
            return e
        end
    end
    return nil
end

-- Where a waymark goes: your feet, your target's feet ('target') or so many yalms ahead of you (a number). x, y, z,
-- or nil and why not.
local function way_spot(where)
    local me = my_entity()
    if me == nil then return nil, "Can't tell where you are." end
    if where == 'target' then
        local t = vana.game.target()
        local e = t and t.index and t.index > 0 and vana.game.entity(t.index) or nil
        if e == nil or e.id == 0 then return nil, 'Target something first.' end
        return e.x, e.y, e.z
    end
    local ahead = tonumber(where)
    if ahead and ahead > 0 then
        ahead = math.min(ahead, 50)
        return me.x + math.cos(me.heading) * ahead, me.y + math.sin(me.heading) * ahead, me.z
    end
    return me.x, me.y, me.z
end

-- Puts waymark n down at (x, y, z) (moving it if it's out), within 60 yalms of you (the server's reach). Without the
-- server, locally.
local WAY_REACH = 58
local function put_way_at(n, x, y, z)
    local now = clock()
    if now - st.last_send < 0.1 then return end
    st.last_send = now
    local me = my_entity()
    if me and (me.x - x) ^ 2 + (me.y - y) ^ 2 + (me.z - z) ^ 2 > WAY_REACH * WAY_REACH then
        say('Too far: a waymark goes within 60 yalms of you.')
        return
    end
    if st.server == false then
        st.ways[n] = { x = x, y = y, z = z, setter = my_id() or 0, at = now }
        return
    end
    send(C2S.WAY_SET, n, 0, 0, x, y, z)
end

local function put_way(n, where)
    local x, y, z = way_spot(where)
    if x == nil then
        say(y)
        return
    end
    put_way_at(n, x, y, z)
end

local function clear_way(n)
    if st.server == false then
        if n then st.ways[n] = nil else st.ways = {} end
        return
    end
    if n then send(C2S.WAY_CLEAR, n) else send(C2S.WAY_CLEAR_ALL) end
end

local function on_ways(p)
    local reason, changed, actor = p[0x06], p[0x07], ffi.cast('uint32_t*', p + 0x08)[0]
    st.server, st.waiting_since = true, nil
    local now = clock()
    local old = st.ways
    st.ways = {}
    for n = 1, #WAYS do
        local at = 0x0C + (n - 1) * 16
        local setter = ffi.cast('uint32_t*', p + at + 12)[0]
        if setter ~= 0 then
            local f = ffi.cast('float*', p + at)
            local o = old[n]
            local same = o and math.abs(o.x - f[0]) < 0.01 and math.abs(o.y - f[1]) < 0.01 and math.abs(o.z - f[2]) < 0.01
            st.ways[n] = { x = f[0], y = f[1], z = f[2], setter = setter, at = same and o.at or now }
        end
    end
    if reason == REASON.REFUSED then
        say("That waymark can't go there.")
        return
    end
    if not cfg.chat or actor == 0 or actor == my_id() then return end
    local who = player_name(actor)
    if reason == REASON.SET and st.ways[changed] then
        say(('%s put waymark %s down.'):format(who, WAYS[changed].name))
    elseif reason == REASON.ALL then
        say(who .. ' took the waymarks off.')
    end
end

local function on_state(p)
    local reason, changed, actor = p[0x06], p[0x07], ffi.cast('uint32_t*', p + 0x08)[0]
    if st.server == false then
        say('The server relays marks after all: they are shared again.')
    end
    st.server, st.waiting_since = true, nil

    local now = clock()
    local old = st.marks
    st.marks = {}
    for n = 1, #MARKS do
        local at = 0x0C + (n - 1) * 12
        local id = ffi.cast('uint32_t*', p + at)[0]
        if id ~= 0 then
            local index = ffi.cast('uint16_t*', p + at + 4)[0]
            local keep = old[n] and old[n].id == id
            st.marks[n] = { id = id, index = index, setter = ffi.cast('uint32_t*', p + at + 8)[0],
                at = keep and old[n].at or now }
        end
    end

    if reason == REASON.REFUSED then
        say("That can't be marked.")
        return
    end
    if not cfg.chat or actor == 0 or actor == my_id() then return end
    local who = player_name(actor)
    if reason == REASON.SET and st.marks[changed] then
        local m = st.marks[changed]
        say(('%s marked %s with %s.'):format(who, entity_name(m.index, m.id), MARKS[changed].name))
    elseif reason == REASON.ALL then
        say(who .. ' took every mark off.')
    end
end

-------------------------------------------------------------------------------
-- Where things are on screen
-------------------------------------------------------------------------------

pcall(ffi.cdef, [[
    typedef struct { float m[16]; } cmark_matrix;
    typedef long (__stdcall *cmark_gettransform)(void*, int, cmark_matrix*);
    typedef uint32_t (__thiscall *cmark_actor)(void*, uint32_t);
]])

local VIEW = { V = ffi.new('cmark_matrix'), P = ffi.new('cmark_matrix'), ok = false }

-- The game's camera, read from the device each frame (D3DTS_VIEW 2, D3DTS_PROJECTION 3).
local function read_camera()
    VIEW.ok = false
    local dev = vana.ashita.object('device')
    if dev == nil then return end
    local vt = ffi.cast('void***', dev)[0]
    local get = ffi.cast('cmark_gettransform', vt[38])
    VIEW.ok = get(dev, 2, VIEW.V) == 0 and get(dev, 3, VIEW.P) == 0
    VIEW.w, VIEW.h = vana.ui.screen()
    -- Ashita's IEntity, for GetActorPointer (its slot 32)
    VIEW.ent = vana.ashita.object('entity')
    if VIEW.ent ~= nil and VIEW.actor_of == nil then
        VIEW.actor_of = ffi.cast('cmark_actor', ffi.cast('void***', VIEW.ent)[0][32])
    end
    if VIEW.actor_of == nil then VIEW.ent = nil end
end

-- A point in the game's world (x and y the map plane, h the height, downwards) to the screen; nil behind the camera.
local function to_screen(x, h, y)
    local v, p = VIEW.V.m, VIEW.P.m
    local vx = x * v[0] + h * v[4] + y * v[8] + v[12]
    local vy = x * v[1] + h * v[5] + y * v[9] + v[13]
    local vz = x * v[2] + h * v[6] + y * v[10] + v[14]
    local cw = vx * p[3] + vy * p[7] + vz * p[11] + p[15]
    if cw < 0.05 then return nil end
    local cx = vx * p[0] + vy * p[4] + vz * p[8] + p[12]
    local cy = vx * p[1] + vy * p[5] + vz * p[9] + p[13]
    return (cx / cw + 1) * 0.5 * VIEW.w, (1 - cy / cw) * 0.5 * VIEW.h
end

-- How far in front of the camera a point of the world is (the same w as to_screen divides by)
local function depth_of(x, h, y)
    local v, p = VIEW.V.m, VIEW.P.m
    local vx = x * v[0] + h * v[4] + y * v[8] + v[12]
    local vy = x * v[1] + h * v[5] + y * v[9] + v[13]
    local vz = x * v[2] + h * v[6] + y * v[10] + v[14]
    return vx * p[3] + vy * p[7] + vz * p[11] + p[15]
end

-- The top of an entity: its actor's bounding box (8 corners from +0x918, the top four from +0x958) has it, so a mark
-- sits over a rabbit's head as well as a dragon's. Two yalms over the feet if that can't be read.
local function top_of(index, e)
    local ent = VIEW.ent
    if ent ~= nil then
        local actor = VIEW.actor_of(ent, index)
        if actor ~= 0 then
            local top = vana.memory.read_float(actor + 0x95C)
            local tall = e.z - top
            if top == top and tall > 0.2 and tall < 40 then return top end
        end
    end
    return e.z - 2
end

-------------------------------------------------------------------------------
-- Drawing the marks
-------------------------------------------------------------------------------

-- A crescent: a circle of radius R less a circle of radius ri at (ox, oy). Its outline runs the outer circle's arc
-- between the two circles' crossings (the side away from the bite), then the bite's arc back.
local MOON = {}
do
    local R, ox, oy, ri, steps = 0.86, 0.36, -0.3, 0.68, 24
    local d = math.sqrt(ox * ox + oy * oy)
    local a = (R * R - ri * ri + d * d) / (2 * d)
    local h = math.sqrt(R * R - a * a)
    local ux, uy = ox / d, oy / d
    local p1 = { ux * a - uy * h, uy * a + ux * h }
    local p2 = { ux * a + uy * h, uy * a - ux * h }
    local function arc(x0, y0, rad, from, to, away)
        -- from one crossing to the other the way that passes `away` (an angle)
        local t0, t1 = math.atan2(from[2] - y0, from[1] - x0), math.atan2(to[2] - y0, to[1] - x0)
        local span = (t1 - t0) % (2 * math.pi)
        if ((away - t0) % (2 * math.pi)) > span then span = span - 2 * math.pi end
        for k = 0, steps - 1 do -- the end is the next arc's start
            local t = t0 + span * k / steps
            MOON[#MOON + 1] = { x0 + rad * math.cos(t), y0 + rad * math.sin(t) }
        end
    end
    local back = math.atan2(-uy, -ux)
    arc(0, 0, R, p1, p2, back)    -- the outside, away from the bite
    arc(ox, oy, ri, p2, p1, back) -- the bite's edge, the part inside the moon
end

-- Each shape at unit size: polygons (point lists; `concave` for the star and the moon), circles { x, y, r } and rounded
-- boxes { x0, y0, x1, y1, rounding }. They're drawn in passes, so every shape gets the same outline: the outline is
-- the shape grown by a fixed width (polygons by a thick line along each edge and a disc at each corner, circles and
-- boxes by their radius), dark, and the fill goes over it.
local GEOM = {}
do
    local star = {}
    for k = 0, 9 do
        local a = -math.pi / 2 + k * math.pi / 5
        local rr = k % 2 == 0 and 1 or 0.46
        star[#star + 1] = { rr * math.cos(a), rr * math.sin(a) + 0.09 }
    end
    GEOM.star = { polys = { { pts = star, concave = true } } }
    GEOM.circle = { circles = { { 0, 0, 0.8 } } }
    GEOM.diamond = { polys = { { pts = { { 0, -1 }, { 0.7, 0 }, { 0, 1 }, { -0.7, 0 } } } } }
    GEOM.triangle = { polys = { { pts = { { 0, -0.86 }, { 0.94, 0.8 }, { -0.94, 0.8 } } } } }
    GEOM.moon = { polys = { { pts = MOON, concave = true } } }
    GEOM.square = { boxes = { { -0.7, -0.7, 0.7, 0.7, 0.16 } } }
    local cross = {}
    local w, l = 0.25, 0.9
    for _, sgn in ipairs({ 1, -1 }) do
        local dx, dy = l * 0.7071, l * 0.7071 * sgn
        local nx, ny = -w * 0.7071 * sgn, w * 0.7071
        cross[#cross + 1] = { pts = { { -dx + nx, -dy + ny }, { dx + nx, dy + ny }, { dx - nx, dy - ny }, { -dx - nx, -dy - ny } } }
    end
    GEOM.cross = { polys = cross }
    GEOM.skull = { circles = { { 0, -0.18, 0.7 } }, boxes = { { -0.42, 0.18, 0.42, 0.84, 0.16 } },
        detail = function (dl, cx, cy, r, dark)
            dl:AddCircleFilled({ cx - r * 0.27, cy - r * 0.1 }, r * 0.19, dark, 20)
            dl:AddCircleFilled({ cx + r * 0.27, cy - r * 0.1 }, r * 0.19, dark, 20)
            dl:AddTriangleFilled({ cx, cy + r * 0.13 }, { cx - r * 0.09, cy + r * 0.31 }, { cx + r * 0.09, cy + r * 0.31 }, dark)
            for k = -1, 1 do
                dl:AddLine({ cx + k * r * 0.15, cy + r * 0.56 }, { cx + k * r * 0.15, cy + r * 0.84 }, dark, math.max(1, r * 0.07))
            end
        end }
end

-- One pass of a shape: filled in `col`, grown past its edge by `grow` pixels (0: the shape itself)
local function shape_pass(dl, g, cx, cy, r, col, grow)
    for _, p in ipairs(g.polys or {}) do
        local pts = {}
        for i, pt in ipairs(p.pts) do pts[i] = { cx + pt[1] * r, cy + pt[2] * r } end
        if p.concave then
            dl:AddConcavePolyFilled(pts, col)
        else
            for _, q in ipairs(pts) do dl:PathLineTo(q) end
            dl:PathFillConvex(col)
        end
        if grow > 0 then
            for i = 1, #pts do
                dl:AddLine(pts[i], pts[i % #pts + 1], col, grow * 2)
                dl:AddCircleFilled(pts[i], grow, col, 12)
            end
        end
    end
    for _, c in ipairs(g.circles or {}) do
        dl:AddCircleFilled({ cx + c[1] * r, cy + c[2] * r }, c[3] * r + grow, col, 48)
    end
    for _, bx in ipairs(g.boxes or {}) do
        dl:AddRectFilled({ cx + bx[1] * r - grow, cy + bx[2] * r - grow }, { cx + bx[3] * r + grow, cy + bx[4] * r + grow }, col,
            bx[5] * r + grow)
    end
end

local function shade(c, k) -- towards white (k > 0) or black (k < 0)
    local t = k > 0 and 1 or 0
    k = math.abs(k)
    return { c[1] + (t - c[1]) * k, c[2] + (t - c[2]) * k, c[3] + (t - c[3]) * k }
end

-- A mark: a soft shadow under it, the outline, then the fill as a gradient from a lighter top to a deeper bottom (the
-- shape drawn in bands, each clipped to its strip of whole pixels so none overlap), and a skull's face over that.
-- `dim` (0..1) greys the colour, for a mark not in use: greyed rather than see-through, as the overlapping parts of a
-- see-through outline would show.
local BANDS = 7
local GREY = { 0.36, 0.38, 0.44 }
local function draw_mark(dl, n, cx, cy, r, alpha, dim)
    local m = MARKS[n]
    local g = GEOM[m.key]
    local color = m.color
    if dim and dim > 0 then
        color = { color[1] + (GREY[1] - color[1]) * dim, color[2] + (GREY[2] - color[2]) * dim, color[3] + (GREY[3] - color[3]) * dim }
    end
    local edge = math.max(1.2, r * 0.13)
    local dark = rgba({ 0.04, 0.04, 0.06 }, alpha)
    dl:AddCircleFilled({ cx, cy + r * 0.14 }, r * 1.18, rgba({ 0, 0, 0 }, 0.10 * alpha), 40)
    dl:AddCircleFilled({ cx, cy + r * 0.1 }, r * 0.98, rgba({ 0, 0, 0 }, 0.12 * alpha), 40)
    shape_pass(dl, g, cx, cy, r, dark, edge)
    local top, bottom = cy - r * 1.05, cy + r * 1.05
    local step = (bottom - top) / BANDS
    for i = 0, BANDS - 1 do
        local y0 = i == 0 and cy - r * 2 or math.floor(top + i * step + 0.5)
        local y1 = i == BANDS - 1 and cy + r * 2 or math.floor(top + (i + 1) * step + 0.5)
        if y1 > y0 then
            dl:PushClipRect({ cx - r * 1.4, y0 }, { cx + r * 1.4, y1 }, true)
            shape_pass(dl, g, cx, cy, r, rgba(shade(color, 0.3 - 0.5 * i / (BANDS - 1)), alpha), 0)
            dl:PopClipRect()
        end
    end
    if g.detail then g.detail(dl, cx, cy, r, dark) end
end

-- A waymark's glyph, its letter or number as a rune: strokes in a box 2 across and 2 high (y down), drawn thick and
-- angular with a dark outline, a light core and a glow round it in the waymark's colour, as FFXIV's hang over its column.
local GLYPHS = {
    a = { { { -0.8, 1 }, { 0, -1 }, { 0.8, 1 } }, { { -0.5, 0.3 }, { 0.5, 0.3 } } },
    b = { { { -0.65, 1 }, { -0.65, -1 }, { 0.25, -1 }, { 0.7, -0.6 }, { 0.7, -0.35 }, { 0.3, -0.05 }, { -0.65, -0.05 } },
          { { 0.3, -0.05 }, { 0.75, 0.3 }, { 0.75, 0.65 }, { 0.3, 1 }, { -0.65, 1 } } },
    c = { { { 0.75, -0.6 }, { 0.3, -1 }, { -0.35, -1 }, { -0.8, -0.55 }, { -0.8, 0.55 }, { -0.35, 1 }, { 0.3, 1 }, { 0.75, 0.6 } } },
    d = { { { -0.65, 1 }, { -0.65, -1 }, { 0.15, -1 }, { 0.8, -0.45 }, { 0.8, 0.45 }, { 0.15, 1 }, { -0.65, 1 } } },
    ['1'] = { { { -0.45, -0.55 }, { 0.1, -1 }, { 0.1, 1 } }, { { -0.5, 1 }, { 0.7, 1 } } },
    ['2'] = { { { -0.75, -0.6 }, { -0.35, -1 }, { 0.35, -1 }, { 0.75, -0.6 }, { 0.75, -0.2 }, { -0.75, 1 }, { 0.75, 1 } } },
    ['3'] = { { { -0.7, -1 }, { 0.7, -1 }, { 0.05, -0.15 }, { 0.4, -0.15 }, { 0.75, 0.2 }, { 0.75, 0.6 }, { 0.35, 1 }, { -0.35, 1 }, { -0.75, 0.65 } } },
    ['4'] = { { { 0.45, 1 }, { 0.45, -1 }, { -0.8, 0.45 }, { 0.8, 0.45 } } },
}
-- the glyph centred on (cx, cy), r half its height; glow 0 to 1 how much light round it (none in the bar)
local function draw_glyph(dl, n, cx, cy, r, alpha, dim, glow)
    local w = WAYS[n]
    local color = w.color
    if dim and dim > 0 then
        color = { color[1] + (GREY[1] - color[1]) * dim, color[2] + (GREY[2] - color[2]) * dim, color[3] + (GREY[3] - color[3]) * dim }
    end
    local sw = math.max(1.5, r * 0.22)
    local function stroke(col, width, grow)
        for _, line in ipairs(GLYPHS[w.key]) do
            dl:PathClear()
            for _, pt in ipairs(line) do dl:PathLineTo({ cx + pt[1] * r * 0.82, cy + pt[2] * r }) end
            dl:PathStroke(col, 0, width)
            -- round joints and ends: discs at the corners (left out when it's drawn thin: translucent, they'd show as dots)
            if alpha >= 0.95 then
                for _, pt in ipairs(line) do dl:AddCircleFilled({ cx + pt[1] * r * 0.82, cy + pt[2] * r }, width / 2 + (grow or 0), col, 16) end
            end
        end
    end
    if glow and glow > 0 then
        for k = 4, 1, -1 do
            stroke(rgba(color, 0.07 * glow * alpha), sw * (1 + k * 1.6))
        end
    end
    stroke(rgba({ 0.04, 0.04, 0.06 }, 0.9 * alpha), sw * 1.9)
    stroke(rgba(shade(color, 0.15), alpha), sw)
    stroke(rgba(shade(color, 0.6), 0.9 * alpha), sw * 0.42)
end

-- How wide a thing is on the ground: the game's hit box radius, else the farthest of its actor's bounding box corners from
-- its middle across the map plane, a little in. Most of a yalm if neither can be read.
local function ground_radius(index, e)
    -- the game's own hit box radius first: it's the size the game gives the thing (4.2 for Fafnir, 1.1 for a rabbit),
    -- where the actor's bounding box is its collision box and can be small on a huge model
    local hb = e.hitbox_size or 0
    if hb > 0.3 and hb < 30 then return math.max(0.6, hb * 0.8) end
    local ent = VIEW.ent
    if ent ~= nil then
        local actor = VIEW.actor_of(ent, index)
        if actor ~= 0 then
            local r = 0
            for c = 0, 7 do
                local at = actor + 0x918 + c * 16
                local dx, dy = vana.memory.read_float(at) - e.x, vana.memory.read_float(at + 8) - e.y
                r = math.max(r, math.sqrt(dx * dx + dy * dy))
            end
            if r == r and r > 0.2 and r < 15 then return math.max(0.6, r * 0.8) end
        end
    end
    return 0.8
end

-- A ring of light on the ground under a marked target, in its mark's colour: a soft pool, the ring with a glow round
-- it, breathing, and a ripple going out from it every 1.6 seconds. A circle on the ground at the target's feet, put on
-- the screen point by point, so it lies flat in the world whatever the camera does.
local RING_N = 56
local function draw_ground_ring(dl, col, x, h, y, R, alpha, now, d, square)
    local function ring(rad)
        local pts = {}
        for k = 0, RING_N - 1 do
            local a = k / RING_N * 2 * math.pi
            local ox, oy = math.cos(a), math.sin(a)
            if square then
                local m = math.max(math.abs(ox), math.abs(oy))
                ox, oy = ox / m, oy / m
            end
            local sx, sy = to_screen(x + rad * ox, h, y + rad * oy)
            if sx == nil then return nil end
            pts[k + 1] = { sx, sy }
        end
        return pts
    end
    local pts = ring(R)
    if pts == nil then return end
    local px = VIEW.h / 1080 * math.max(0.5, 1 - math.max(0, d - 8) / 60)
    local breath = 0.5 + 0.5 * math.sin(now * 2.6)
    local function path(p)
        for _, q in ipairs(p) do dl:PathLineTo(q) end
    end
    path(pts)
    dl:PathFillConvex(rgba(col, (0.10 + 0.06 * breath) * alpha))
    local inner = ring(R * 0.62)
    if inner then
        path(inner)
        dl:PathFillConvex(rgba(col, (0.06 + 0.04 * breath) * alpha))
    end
    for _, pass in ipairs({ { 10, 0.07 }, { 6, 0.14 }, { 3.5, 0.3 } }) do
        path(pts)
        dl:PathStroke(rgba(col, pass[2] * (0.8 + 0.4 * breath) * alpha), 1, pass[1] * px)
    end
    path(pts)
    dl:PathStroke(rgba(shade(col, 0.35), 0.95 * alpha), 1, 1.6 * px)
    local t = (now % 1.6) / 1.6
    local out = ring(R * (1 + 0.5 * t))
    if out then
        path(out)
        dl:PathStroke(rgba(col, 0.55 * (1 - t) * (1 - t) * alpha), 1, 2.2 * px)
    end
end
local function draw_ground_glow(dl, n, index, e, alpha, now, d)
    draw_ground_ring(dl, MARKS[n].color, e.x, e.z, e.y, ground_radius(index, e), alpha, now, d, false)
end

-- Your target's mark in the game's Target window: the window glowing in the mark's colour, the mark in its top corner
local function draw_target_badge()
    if not cfg.in_target or next(st.marks) == nil or not VIEW.ok then return end
    local tgt = target_index()
    if tgt == 0 then return end
    local n
    for k, m in pairs(st.marks) do if m.index == tgt then n = k end end
    if n == nil then return end
    local e = vana.game.entity(tgt)
    if e == nil or e.id ~= st.marks[n].id then return end
    -- where the game's Target window is (a VanaCore newer than 0.8.216; nothing drawn on an older one)
    if vana.gameui == nil or vana.gameui.rect == nil then return end
    local x0, y0, x1, y1 = vana.gameui.rect('target_window')
    if x0 == nil or x1 < 0 or y1 < 0 or x0 > VIEW.w or y0 > VIEW.h then return end
    local u = (y1 - y0) / 36 -- the window is 36 of the game's units tall: a unit's pixels
    local dl = imgui.GetBackgroundDrawList()
    local col = MARKS[n].color
    local breath = 0.5 + 0.5 * math.sin(clock() * 2.6)
    local rr = 5 * u
    for k = 4, 1, -1 do
        local g = k * 1.6 * u
        dl:AddRect({ x0 - g, y0 - g }, { x1 + g, y1 + g }, rgba(col, (0.05 + 0.04 * breath)), rr + g, 15, 2 * u)
    end
    dl:AddRect({ x0, y0 }, { x1, y1 }, rgba(col, 0.6 + 0.3 * breath), rr, 15, 1.3 * u)
    -- in the caption's row, at its right end: the name below starts at the left, and the caption is in the middle
    draw_mark(dl, n, x1 - 10 * u, y0 + 6.5 * u, 7.5 * u, 1)
end

-- VanaCore's rings of light (vana.world.marks, a VanaCore newer than 0.8.216, with the scene effects): laid onto the ground itself, so a
-- slope carries one and what stands in front of it hides it. The marked targets' rings go to it every frame they're
-- shown (they move); none when there's nothing to show. False when this VanaCore can't: the ring is drawn here then.
local RINGS = { able = nil, checked = -10, sent = false }
-- a VanaCore whose rings take a shape, a column and a glyph (the one with vana.world.pick: they came together)
local function rings_full()
    return vana.world ~= nil and vana.world.pick ~= nil
end
local function rings_able()
    local now = clock()
    if RINGS.able == nil or now - RINGS.checked > 5 then
        RINGS.checked = now
        local ok, g = pcall(function () return vana.graphics.info() end)
        RINGS.able = vana.world ~= nil and vana.world.marks ~= nil and ok and type(g) == 'table' and g.active == true
    end
    return RINGS.able
end
-- and the waymarks: a ring (a square for 1 to 4) with the column of light over it (a VanaCore with vana.world.marks's
-- shape and height; an older one draws the ring alone)
local function send_rings(shown, ways, now)
    if not rings_able() then return false end
    local list = {}
    for _, v in ipairs(shown) do
        local pop = math.max(0, 1 - (now - v.m.at) / 0.3)
        list[#list + 1] = { x = v.e.x, y = v.e.y, z = v.e.z, color = MARKS[v.n].hex,
            radius = ground_radius(v.m.index, v.e) * (1 + 0.35 * pop * pop) }
    end
    local full = rings_full()
    for _, v in ipairs(ways or {}) do
        local pop = math.max(0, 1 - (now - v.w.at) / 0.4)
        list[#list + 1] = { x = v.w.x, y = v.w.y, z = v.w.z, color = WAYS[v.n].hex, radius = cfg.way_radius,
            shape = WAYS[v.n].square and 'square' or 'round', height = cfg.beam * (1 - 0.6 * pop * pop), strength = 1.1,
            glyph = full and WAYS[v.n].name or nil, glyph_size = 0.8 * (1 + 0.5 * pop * pop) }
    end
    if #list > 0 or RINGS.sent then pcall(vana.world.marks, list) end
    RINGS.sent = #list > 0
    return true
end

-- where each mark was drawn this frame, by entity index: { x, y, r }, for right-clicks on the mark itself
local DRAWN = {}

local function draw_world()
    DRAWN = {}
    local _, _, _, _, _, _, _, status = vana.game.self()
    if (next(st.marks) == nil and next(st.ways) == nil) or status == 4 or not VIEW.ok or not VIEW.w or VIEW.w == 0 then -- (4: a cutscene)
        send_rings({}, {}, clock())
        return
    end

    local dl = imgui.GetBackgroundDrawList()
    local base = cfg.size / 100 * VIEW.h / 1080 * 22
    local now = clock()
    local shown = {}
    for n, m in pairs(st.marks) do
        local e = vana.game.entity(m.index)
        local mob = e and bit.band(e.spawn_flags or 0, 0x10) ~= 0
        if e and e.id == m.id and not (mob and e.hpp == 0) then
            local d = math.sqrt(e.distance or 0)
            -- over the name where the game draws it (vana.world.name_at, a VanaCore newer than 0.8.216: the right height
            -- for any model), else over the top of the model's box (a dragon's raised wings put that far over its head)
            -- across, over the thing itself (its name is centred on it; a player's name has an icon beside it). With the
            -- camera tilted, a thing's upright axis leans on the screen away from the middle, so its feet and its name
            -- aren't on one vertical: the axis is projected (feet and the top of the box) and followed up to the name
            local sx, sy
            if vana.world.name_at then
                local _, ntop, nbottom = vana.world.name_at(m.index)
                if ntop then
                    local fx, fy = to_screen(e.x, e.z, e.y)
                    local tx, ty = to_screen(e.x, top_of(m.index, e), e.y)
                    sy = ntop
                    if fx and tx and math.abs(ty - fy) > 1 then
                        local nmid = nbottom and (ntop + nbottom) / 2 or ntop
                        sx = fx + (tx - fx) * (nmid - fy) / (ty - fy)
                    else
                        sx = fx or tx
                    end
                end
            end
            if sx == nil then
                local top = top_of(m.index, e)
                sx, sy = to_screen(e.x, top - 0.4, e.y)
            end
            if sx and d < 60 then
                shown[#shown + 1] = { n = n, m = m, e = e, d = d, sx = sx, sy = sy }
            end
        end
    end
    -- the waymarks within sight, each with how far off it is and where its glyph goes: over the column's top (a yalm and
    -- a half over the ring when there's no column), the glyph's size from a yalm's length on the screen there
    local me = my_entity()
    local ways = {}
    for n, w in pairs(st.ways) do
        local d = me and math.sqrt((me.x - w.x) ^ 2 + (me.y - w.y) ^ 2 + (me.z - w.z) ^ 2) or 0
        if d < 60 then
            local top = w.z - (cfg.beam > 0 and cfg.beam + 1.2 or 1.5) - 0.12 * math.sin(now * 1.7 + n)
            local sx, sy = to_screen(w.x, top, w.y)
            local _, sy2 = to_screen(w.x, top - 1, w.y)
            ways[#ways + 1] = { n = n, w = w, d = d, sx = sx, sy = sy, top = top, unit = sx and sy2 and math.abs(sy2 - sy) or 0 }
        end
    end
    -- the ring of light on the ground under each: VanaCore's where it has them, else drawn here over the screen, first,
    -- the marks over all of them
    if not cfg.glow then
        send_rings({}, ways, now)
    elseif not send_rings(shown, ways, now) then
        for _, v in ipairs(shown) do
            draw_ground_glow(dl, v.n, v.m.index, v.e, v.d > 50 and (60 - v.d) / 10 or 1, now, v.d)
        end
    end
    if not rings_able() then
        for _, v in ipairs(ways) do
            draw_ground_ring(dl, WAYS[v.n].color, v.w.x, v.w.z, v.w.y, cfg.way_radius, v.d > 50 and (60 - v.d) / 10 or 1, now, v.d, WAYS[v.n].square)
        end
    end
    -- the glyph over each: VanaCore's where its rings carry one (cut by the scene's depth, so a character in front of it
    -- hides it), else drawn here over the screen
    local own_glyphs = not (rings_able() and rings_full())
    for _, v in ipairs(ways) do
        if v.sx and own_glyphs then
            local alpha = v.d > 50 and (60 - v.d) / 10 or 1
            local pop = math.max(0, 1 - (now - v.w.at) / 0.4)
            -- about a yalm and a half tall out in the world; no bigger than a twelfth of the screen, and thinner the
            -- nearer the camera is to it past that, so one right over you doesn't blot out the scene
            local want, cap = v.unit * 0.8, VIEW.h * 0.055
            local r = math.max(9, math.min(cap, want)) * (1 + 0.6 * pop * pop)
            if want > cap then alpha = alpha * math.max(0.3, math.min(1, 2 * cap / want)) end
            -- over the screen with no depth: thinned while your own character stands between the camera and it (their
            -- feet to their top on the screen, about a third as wide as tall)
            if me and ME.index then
                local fx, fy = to_screen(me.x, me.z, me.y)
                local _, ty = to_screen(me.x, top_of(ME.index, me), me.y)
                if fx and ty then
                    local hw = math.max(VIEW.h / 1080 * 30, (fy - ty) * 0.35)
                    if v.sx + r > fx - hw and v.sx - r < fx + hw and v.sy + r > ty and v.sy - r < fy
                        and depth_of(me.x, me.z, me.y) < depth_of(v.w.x, v.top, v.w.y) then
                        alpha = alpha * 0.22
                    end
                end
            end
            local breath = 0.75 + 0.25 * math.sin(now * 2.2 + v.n * 1.3)
            draw_glyph(dl, v.n, v.sx, v.sy, r, alpha, 0, breath)
        end
    end
    for _, v in ipairs(shown) do
        local far = math.max(0.55, 1 - math.max(0, v.d - 8) / 70)
        local pop = math.max(0, 1 - (now - v.m.at) / 0.3)
        local r = base * far * (1 + 0.5 * pop * pop)
        local alpha = v.d > 50 and (60 - v.d) / 10 or 1
        -- the mark's foot cfg.height of its sizes over the point (a shape reaches about r below its middle)
        local my = v.sy - r * (1 + cfg.height)
        draw_mark(dl, v.n, v.sx, my, r, alpha)
        DRAWN[v.m.index] = { v.sx, my, r }
    end
end

-------------------------------------------------------------------------------
-- The mark bar
-------------------------------------------------------------------------------

-- Drawn with the kit like the menu: a glass strip with a grip, the eight marks as tiles (a mark in use is tinted in its
-- colour, with a line under it), the X that takes them all off and the gear for the settings. A click on the grip folds
-- it down to the paw and the marks in use; holding the grip and dragging moves it.

-- the opacity the kit draws with just now (the bar's, the settings' fade); a tooltip is drawn whole and puts it back
local CUR_ALPHA = 1
local function set_alpha(a)
    CUR_ALPHA = a
    U.set_window_alpha(a)
end

-- the paw, Clawmark's own sign: four toes over a pad, centred on (cx, cy), about 2r across
local function draw_paw(dl, cx, cy, r, col)
    cy = cy - r * 0.06
    dl:AddCircleFilled({ cx, cy + r * 0.34 }, r * 0.40, col, 32)
    dl:AddCircleFilled({ cx - r * 0.24, cy + r * 0.46 }, r * 0.28, col, 24)
    dl:AddCircleFilled({ cx + r * 0.24, cy + r * 0.46 }, r * 0.28, col, 24)
    for _, t in ipairs({ { -0.6, -0.08, 0.19 }, { -0.23, -0.44, 0.2 }, { 0.23, -0.44, 0.2 }, { 0.6, -0.08, 0.19 } }) do
        dl:AddCircleFilled({ cx + t[1] * r, cy + t[2] * r }, t[3] * r, col, 20)
    end
end

-- a theme as a gem: its accent, second accent and cyan as three slices round a core of its glass
local function draw_theme_orb(dl, cx, cy, r, th)
    local u32, S = U.u32, U.S
    local pal = th.palette
    local cols = { pal.accent, pal.accent2, pal.cyan }
    for i = 1, 3 do
        local a0 = -math.pi / 2 + (i - 1) * 2 * math.pi / 3
        dl:PathClear()
        dl:PathLineTo({ cx, cy })
        dl:PathArcTo({ cx, cy }, r, a0, a0 + 2 * math.pi / 3, 16)
        dl:PathFillConvex(u32(cols[i] or P.accent))
    end
    dl:AddCircleFilled({ cx, cy }, r * 0.5, u32(pal.glass or P.glass), 24)
    dl:AddCircle({ cx, cy }, r * 0.5, u32('#FFFFFF', 0.14), 24, 1)
    dl:AddCircle({ cx, cy }, r, u32('#000000', 0.35), 32, 1)
    dl:PathClear()
    dl:PathArcTo({ cx, cy }, r - S(2.5), math.pi * 1.08, math.pi * 1.42, 10)
    dl:PathStroke(u32('#FFFFFF', 0.45), 0, S(1.5))
end

-- A one-line hint under whatever the pointer is on in the bar: the verb and its object ("Target Tunnel Worm · 48y"),
-- drawn over everything so the settings sheet under the bar doesn't cover it. Light on purpose: the bar is used in
-- fights, so a title and three lines on every tile was too much to have appearing all the time.
local function bar_hint(cx, top, text, color)
    local S = U.S
    local fg = imgui.GetForegroundDrawList()
    local tw = U.measure(text, F.semi, T.tiny)
    local w, h = tw + S(18), S(22)
    local sw = vana.ui.screen()
    local x = math.max(S(4), math.min(cx - w / 2, sw - w - S(4)))
    local y = top + S(7)
    for k = 2, 1, -1 do
        fg:AddRectFilled({ x - S(k), y - S(k) }, { x + w + S(k), y + h + S(k) }, U.u32(color, 0.05), S(7) + S(k))
    end
    fg:AddRectFilled({ x, y }, { x + w, y + h }, U.u32(P.ink, 0.94), S(7))
    fg:AddRect({ x, y }, { x + w, y + h }, U.u32(color, 0.45), S(7), 15, 1)
    -- a notch up to the thing it's about
    fg:AddTriangleFilled({ cx - S(4), y + 1 }, { cx + S(4), y + 1 }, { cx, y - S(4) }, U.u32(P.ink, 0.94))
    U.text_mid(fg, x + S(9), y + h / 2, text, U.mix(P.text, color, 0.25), F.semi, T.tiny)
end

local function auto_scale()
    local sh = VIEW.h or 1080
    return math.max(100, math.min(250, math.floor(sh / 1080 * 10 + 0.5) * 10))
end

-- the bar's state: anim 0 folded .. 1 open; drag while the grip is held; pos, the place to put it next frame; fade,
-- its opacity as drawn; rect, where it was drawn (the settings open under it); hold, how long the X has been held
local BAR = { anim = nil, drag = nil, pos = nil, fade = 1, hovered = false, rect = nil, hold = 0 }
-- the settings: open, and anim, 0 .. 1 as it fades in
local SET = { open = false, anim = 0, h = nil, scale_edit = nil, scale_drag = false, frames = 0 }

local function frame_dt() return math.max(0.001, math.min(0.1, imgui.GetIO().DeltaTime or 0.016)) end

-- what a click on mark n does, from the mark itself: a free one goes on your target (MARK); one that's out targets
-- what carries it (TARGET); the one your target carries comes off (OFF). The hint's words go with it.
local function act_of(n, tgt)
    local m = st.marks[n]
    if m == nil then
        local t = tgt > 0 and vana.game.entity(tgt) or nil
        if t and t.name and t.name ~= '' then return 'MARK', P.ok, 'Mark ' .. t.name end
        return 'MARK', P.dim, 'Target something to mark it'
    end
    local name = entity_name(m.index, m.id)
    if m.index == tgt then return 'OFF', P.danger, 'Unmark ' .. name end
    local e = vana.game.entity(m.index)
    local far = e and e.id == m.id and e.distance and (' · %.0fy'):format(math.sqrt(e.distance)) or ''
    return 'TARGET', MARKS[n].hex, 'Target ' .. name .. far
end

-- a click on a tile or a mini, left or right, Shift or not
local function click_mark(n, tgt, with_shift)
    local act = act_of(n, tgt)
    if act == 'TARGET' and not with_shift then target_mark(n)
    elseif act == 'OFF' and not with_shift then clear(n)
    else put(n, tgt) end
end

-- what a click on waymark n does: a free one goes down at your feet; one that's out comes off (Shift-click moves it here)
local function act_way(n)
    local w = st.ways[n]
    if w == nil then return 'PLACE', P.ok, 'Put ' .. WAYS[n].name .. ' down at your feet' end
    local me = my_entity()
    local far = me and (' · %.0fy'):format(math.sqrt((me.x - w.x) ^ 2 + (me.y - w.y) ^ 2)) or ''
    return 'OFF', P.danger, 'Take ' .. WAYS[n].name .. ' off' .. far .. '  ·  Shift-click: move it here'
end

local function click_way(n, with_shift)
    if st.ways[n] and not with_shift then clear_way(n) else put_way(n) end
end

local HOLD_CLEAR = 0.7 -- seconds the X is held before every mark comes off

local function draw_bar()
    if not cfg.bar or not st.kit then BAR.rect = nil return end
    local _, _, _, _, _, _, _, status = vana.game.self()
    if status == 4 then BAR.rect = nil return end

    local S, u32, mix = U.S, U.u32, U.mix
    local dt = frame_dt()
    local tile, gap, pad, grip = S(36), S(4), S(6), S(16)
    local small = tile * 0.9
    local wtile = S(26) -- the waymarks' row, under the marks
    local used, wused = {}, {}
    for n = 1, #MARKS do if st.marks[n] then used[#used + 1] = n end end
    for n = 1, #WAYS do if st.ways[n] then wused[#wused + 1] = n end end
    local mini = S(24)
    local full_w = pad + grip + gap + #MARKS * (tile + gap) + S(6) + small + pad
    local fold_w = pad + grip + gap + (#used + #wused > 0 and (#used + #wused) * mini or tile) + pad
    local goal = cfg.folded and 0 or 1
    BAR.anim = BAR.anim or goal
    BAR.anim = U.lerp(BAR.anim, goal, math.min(1, dt * 11))
    if math.abs(BAR.anim - goal) < 0.003 then BAR.anim = goal end
    local a = BAR.anim
    local w = fold_w + (full_w - fold_w) * a
    local h = pad * 2 + tile + (cfg.ways and (gap + wtile) * a or 0)
    local tgt = target_index()
    -- the opacity: the setting's, or whole under the pointer (and while it's dragged)
    local want = (cfg.solid and (BAR.hovered or BAR.drag ~= nil)) and 1 or cfg.opacity / 100
    BAR.fade = U.lerp(BAR.fade, want, math.min(1, dt * 10))
    local fade = BAR.fade

    if BAR.pos then
        imgui.SetNextWindowPos(BAR.pos, U.ALWAYS)
        BAR.pos = nil
    else
        imgui.SetNextWindowPos({ 40, 300 }, U.FIRST_USE_EVER)
    end
    imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
    if imgui.Begin('Clawmark###clawmark_bar', nil, U.WINDOW_FLAGS + U.NO_FOCUS) then
        local dl = imgui.GetWindowDrawList()
        local x, y = imgui.GetWindowPos()
        BAR.rect = { x, y, w, h }
        BAR.hovered = imgui.IsWindowHovered()
        set_alpha(fade)
        -- the window is the bar's own size and ImGui clips to it, which cut the outline, its glow and the shadow off
        -- at the edge (the corners looked chamfered): the drawing gets the room round it, clicks still go by the window
        local mg = S(24)
        dl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
        local ok, err = pcall(function ()
            local shift = imgui.GetIO().KeyShift
            local quiet = st.menu_up -- the right-click menu is up: no hints
            local rr = S(12)
            local hint = nil -- { cx, text, color }: the one hint this frame, drawn last
            U.shadow(dl, x, y, w, h, rr, 1.2)
            -- the edge: a soft glow in the theme's colour feathered out over several rings, so there's no hard line
            -- round the glass, breathing a little
            local breath = 0.5 + 0.5 * math.sin(imgui.GetTime() * 1.6)
            local glow = 0.75 + 0.15 * breath
            for k = 7, 1, -1 do
                local t = k / 7
                dl:AddRect({ x - S(k) * 1.1, y - S(k) * 1.1 }, { x + w + S(k) * 1.1, y + h + S(k) * 1.1 }, u32(P.accent, 0.11 * (1 - t) * (1 - t) * glow), rr + S(k) * 1.1, 15, S(2.6))
            end
            dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.glass, 0.94), rr)
            dl:AddRect({ x, y }, { x + w, y + h }, u32(P.accent, 0.45), rr, 15, S(1.2))
            dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, u32('#FFFFFF', 0.05), rr, 15, 1)
            -- a breath of the theme along the top edge
            local tm = x + w / 2
            dl:AddRectFilledMultiColor({ x + rr, y + 1 }, { tm, y + S(2) }, u32(P.accent, 0), u32(P.accent2, 0.55), u32(P.accent2, 0.55), u32(P.accent, 0))
            dl:AddRectFilledMultiColor({ tm, y + 1 }, { x + w - rr, y + S(2) }, u32(P.accent2, 0.55), u32(P.cyan, 0), u32(P.cyan, 0), u32(P.accent2, 0.55))

            -- the grip: a click folds the bar, holding it and dragging moves it
            local gx0 = x + pad - S(2)
            imgui.SetCursorScreenPos({ gx0, y })
            local gear_h = S(24) -- the settings' gear, under the grip
            imgui.InvisibleButton('##cm_grip', { grip + S(4), h - gear_h })
            local ghov, gact = imgui.IsItemHovered(), imgui.IsItemActive()
            local mx, my = imgui.GetMousePos()
            if gact then
                if BAR.drag == nil then BAR.drag = { mx = mx, my = my, x = x, y = y, moved = false } end
                local d = BAR.drag
                if not d.moved and math.abs(mx - d.mx) + math.abs(my - d.my) > S(4) then d.moved = true end
                if d.moved then
                    local sw, sh = vana.ui.screen()
                    BAR.pos = { math.max(0, math.min(sw - w, d.x + mx - d.mx)), math.max(0, math.min(sh - h, d.y + my - d.my)) }
                end
            end
            if imgui.IsItemDeactivated() then
                if BAR.drag and not BAR.drag.moved then
                    cfg.folded = not cfg.folded
                    config:save()
                    U.ripple_at('##cm_grip')
                end
                BAR.drag = nil
            end
            local gv = U.A.hover['##cm_grip'] or 0
            gv = U.lerp(gv, (ghov or gact) and 1 or 0, math.min(1, dt * 14))
            U.A.hover['##cm_grip'] = gv
            local dragging = BAR.drag ~= nil and BAR.drag.moved
            if gv > 0.01 then
                dl:AddRectFilled({ gx0 + S(1), y + pad }, { gx0 + grip + S(3), y + h - gear_h }, u32(P.accent, (dragging and 0.2 or 0.1) * gv), S(7))
            end
            U.draw_ripples(dl, '##cm_grip', gx0, y, grip + S(4), h - gear_h, P.accent)
            local dot = dragging and P.accent or mix(P.faint, P.accent, gv)
            local gcx = gx0 + (grip + S(4)) / 2
            local gmy = y + pad + (h - gear_h - pad) / 2
            for r_ = 0, 2 do
                for c = 0, 1 do
                    dl:AddCircleFilled({ gcx + (c - 0.5) * S(6), gmy + (r_ - 1) * S(5) }, S(1.6), u32(dot), 8)
                end
            end
            if ghov and not dragging and not quiet then
                hint = { gcx, cfg.folded and 'Open the bar  ·  hold to move it' or 'Fold the bar  ·  hold to move it', P.accent }
            end
            -- the gear: the settings
            imgui.SetCursorScreenPos({ gx0, y + h - gear_h })
            local gp, gh, ghv = U.hit('##cm_gear', grip + S(4), gear_h - S(2), S(7))
            if gp then
                U.ripple_at('##cm_gear')
                SET.open = not SET.open
            end
            local lit = SET.open and 1 or 0
            if ghv > 0 or lit > 0 then
                dl:AddCircleFilled({ gcx, y + h - gear_h / 2 - S(2) }, S(9), u32(P.accent, 0.16 * lit + 0.14 * ghv), 24)
            end
            U.icon(dl, gcx, y + h - gear_h / 2 - S(2), 'gear', mix(P.faint, P.accent, math.max(ghv, lit)), T.tiny)
            if gh and not quiet then hint = { gcx, SET.open and 'Close the settings' or 'Settings', P.accent } end

            local cx0 = x + pad + grip + gap
            dl:PushClipRect({ cx0 - S(2), y }, { x + w - S(2), y + h }, true)

            -- folded: the marks that are out, small, with the same clicks; the paw when none is
            local fa = 1 - a
            if fa > 0.01 then
                local ty = y + pad
                local live = fa > 0.5
                if #used + #wused == 0 then
                    draw_paw(dl, cx0 + tile / 2, y + h / 2, tile * 0.3, u32(mix(P.faint, P.accent, 0.4), fa * fade))
                    if live then
                        imgui.SetCursorScreenPos({ cx0, ty })
                        local _, hovered = U.hit('##cm_paw', tile, tile, S(9))
                        if hovered and not quiet then hint = { cx0 + tile / 2, 'No marks out', P.dim } end
                    end
                end
                -- the waymarks that are out, after the marks: a click takes one off, Shift-click moves it here
                for i, n in ipairs(wused) do
                    local key, hex = '##cm_wmini' .. n, WAYS[n].hex
                    local mx0 = cx0 + (#used + i - 1) * mini
                    local mhv = 0
                    if live then
                        imgui.SetCursorScreenPos({ mx0, ty })
                        imgui.InvisibleButton(key, { mini, tile }, 3)
                        local hovered = imgui.IsItemHovered()
                        if imgui.IsItemClicked(0) then
                            U.ripple_at(key)
                            click_way(n, shift)
                        elseif imgui.IsItemClicked(1) then
                            U.ripple_at(key)
                            clear_way(n)
                        end
                        mhv = U.lerp(U.A.hover[key] or 0, hovered and 1 or 0, math.min(1, dt * 14))
                        U.A.hover[key] = mhv
                        if hovered and not quiet then
                            local _, col, text = act_way(n)
                            hint = { mx0 + mini / 2, text, col }
                        end
                    end
                    if mhv > 0 then dl:AddRectFilled({ mx0, ty + S(3) }, { mx0 + mini, ty + tile - S(3) }, u32(hex, 0.16 * mhv * fa), S(6)) end
                    U.draw_ripples(dl, key, mx0, ty, mini, tile, hex)
                    draw_glyph(dl, n, mx0 + mini / 2, y + h / 2, mini * 0.3 * (1 + 0.12 * mhv), fa * fade, 0, 0)
                end
                for i, n in ipairs(used) do
                    local m, key, hex = st.marks[n], '##cm_mini' .. n, MARKS[n].hex
                    local mx0 = cx0 + (i - 1) * mini
                    local mhv = 0
                    if live then
                        imgui.SetCursorScreenPos({ mx0, ty })
                        imgui.InvisibleButton(key, { mini, tile }, 3) -- left and right buttons
                        local hovered = imgui.IsItemHovered()
                        if imgui.IsItemClicked(0) then
                            U.ripple_at(key)
                            click_mark(n, tgt, shift)
                        elseif imgui.IsItemClicked(1) then
                            U.ripple_at(key)
                            clear(n)
                        end
                        mhv = U.lerp(U.A.hover[key] or 0, hovered and 1 or 0, math.min(1, dt * 14))
                        U.A.hover[key] = mhv
                        if hovered and not quiet then
                            local _, col, text = act_of(n, tgt)
                            hint = { mx0 + mini / 2, text, col }
                        end
                    end
                    if mhv > 0 then dl:AddRectFilled({ mx0, ty + S(3) }, { mx0 + mini, ty + tile - S(3) }, u32(hex, 0.16 * mhv * fa), S(6)) end
                    U.draw_ripples(dl, key, mx0, ty, mini, tile, hex)
                    draw_mark(dl, n, mx0 + mini / 2, y + h / 2, mini * 0.32 * (1 + 0.12 * mhv), fa * fade)
                    -- the one your target carries, underlined
                    if m.index == tgt then
                        dl:AddRectFilled({ mx0 + mini * 0.25, ty + tile - S(5) }, { mx0 + mini * 0.75, ty + tile - S(3) }, u32(hex, fa), S(1))
                    end
                end
            end

            -- open: the tiles, sliding in from the grip
            if a > 0.01 then
                local tx, ty = cx0 - S(24) * (1 - a), y + pad
                local live = a > 0.5
                for n = 1, #MARKS do
                    local key, hex = '##cm_bar' .. n, MARKS[n].hex
                    local on = st.marks[n] ~= nil
                    local hovered = false
                    if live then
                        imgui.SetCursorScreenPos({ tx, ty })
                        imgui.InvisibleButton(key, { tile, tile }, 3) -- left and right buttons
                        hovered = imgui.IsItemHovered()
                        if imgui.IsItemClicked(0) then
                            U.ripple_at(key)
                            click_mark(n, tgt, shift)
                        elseif imgui.IsItemClicked(1) then
                            U.ripple_at(key)
                            clear(n)
                        end
                    end
                    local hv = U.A.hover[key] or 0
                    hv = U.lerp(hv, hovered and 1 or 0, math.min(1, dt * 14))
                    U.A.hover[key] = hv
                    local tr = S(10)
                    local mine = on and st.marks[n].index == tgt
                    if on then
                        -- a mark that's out glows softly in its colour; the one on your target, more
                        local g = 0.6 + (mine and 0.5 or 0) + 0.3 * hv
                        for k = 3, 1, -1 do
                            dl:AddRectFilled({ tx - S(k), ty - S(k) }, { tx + tile + S(k), ty + tile + S(k) }, u32(hex, 0.045 * g * a), tr + S(k))
                        end
                    end
                    dl:AddRectFilled({ tx, ty }, { tx + tile, ty + tile }, u32(on and hex or P.card, (on and 0.16 or 0.7) * a), tr)
                    dl:AddRectFilledMultiColor({ tx, ty }, { tx + tile, ty + tile / 2 }, u32('#FFFFFF', 0.045 * a), u32('#FFFFFF', 0.045 * a), u32('#FFFFFF', 0), u32('#FFFFFF', 0))
                    if hv > 0 then dl:AddRectFilled({ tx, ty }, { tx + tile, ty + tile }, u32(hex, 0.16 * hv * a), tr) end
                    dl:AddRect({ tx, ty }, { tx + tile, ty + tile }, u32(on and hex or mix(P.line, hex, 0.6 * hv), (on and (mine and 0.95 or 0.6) or 0.35 + 0.4 * hv) * a), tr, 15, mine and S(1.5) or 1)
                    U.draw_ripples(dl, key, tx, ty, tile, tile, hex)
                    draw_mark(dl, n, tx + tile / 2, ty + tile * 0.46, tile * 0.26 * (1 + 0.08 * hv), a * fade, on and 0 or 0.45 * (1 - hv))
                    if on then
                        dl:AddRectFilled({ tx + tile * 0.3, ty + tile - S(5) }, { tx + tile * 0.7, ty + tile - S(3) }, u32(hex, a), S(1))
                    end
                    if hovered and not quiet then
                        local _, col, text = act_of(n, tgt)
                        hint = { tx + tile / 2, text, col }
                    end
                    tx = tx + tile + gap
                end
                -- a divider, then the X: held for a moment, it takes every mark off (a click alone does nothing, so a
                -- slip in a fight can't wipe the raid's marks); a ring fills round it while it's held
                local xh, xmid = h - pad * 2, y + h / 2
                dl:AddLine({ tx + S(2), ty + S(7) }, { tx + S(2), ty + xh - S(7) }, u32(P.line, a), 1)
                tx = tx + S(6)
                local hv, holding = 0, false
                local anything = next(st.marks) ~= nil or next(st.ways) ~= nil
                if live then
                    imgui.SetCursorScreenPos({ tx, ty })
                    imgui.InvisibleButton('##cm_bar_clear', { small, xh })
                    local hovered, active = imgui.IsItemHovered(), imgui.IsItemActive()
                    hv = U.lerp(U.A.hover['##cm_bar_clear'] or 0, hovered and 1 or 0, math.min(1, dt * 14))
                    U.A.hover['##cm_bar_clear'] = hv
                    holding = active and hovered and anything
                    if holding then
                        BAR.hold = BAR.hold + dt
                        if BAR.hold >= HOLD_CLEAR then
                            U.ripple_at('##cm_bar_clear')
                            clear(nil)
                            if next(st.ways) ~= nil then clear_way(nil) end
                            BAR.hold = -1 -- done: nothing more until the button is let go
                        end
                    elseif not active then
                        BAR.hold = 0
                    end
                    if hovered and not quiet then
                        if not anything then hint = { tx + small / 2, 'Nothing to take off', P.dim }
                        elseif BAR.hold < 0 then hint = { tx + small / 2, 'Everything is off', P.danger }
                        elseif holding then hint = { tx + small / 2, 'Keep holding…', P.danger }
                        else hint = { tx + small / 2, 'Hold to take every mark and waymark off', P.danger } end
                    end
                end
                local t = math.max(0, math.min(1, BAR.hold / HOLD_CLEAR))
                if hv > 0 then dl:AddRectFilled({ tx, ty }, { tx + small, ty + xh }, u32(P.danger, 0.14 * hv * a), S(9)) end
                U.draw_ripples(dl, '##cm_bar_clear', tx, ty, small, xh, P.danger)
                if t > 0 then
                    dl:PathClear()
                    dl:PathArcTo({ tx + small / 2, xmid }, tile * 0.36, -math.pi / 2, -math.pi / 2 + math.pi * 2 * t, 40)
                    dl:PathStroke(u32(P.danger, a), 0, S(2.5))
                end
                U.icon(dl, tx + small / 2, xmid, 'xmark', mix(P.dim, P.danger, math.max(hv, t)), T.body, a)
                if st.server == false then
                    dl:AddCircleFilled({ tx + small - S(6), ty + S(6) }, S(3), u32(P.warn, a), 12)
                    if hv > 0.5 and not quiet and not holding then hint = { tx + small / 2, "This server doesn't relay marks: yours are seen by you alone", P.warn } end
                end
                -- the waymarks' row under the marks: A to D round, 1 to 4 square, each under a mark's tile. A free one
                -- goes down at your feet, one that's out comes off (Shift-click moves it here, right-click takes it off)
                if cfg.ways then
                    local wx, wy = cx0 - S(24) * (1 - a), y + pad + tile + gap
                    for n = 1, #WAYS do
                        local key, hex, sq = '##cm_way' .. n, WAYS[n].hex, WAYS[n].square
                        local on = st.ways[n] ~= nil
                        local hovered = false
                        if live then
                            imgui.SetCursorScreenPos({ wx, wy })
                            imgui.InvisibleButton(key, { tile, wtile }, 3)
                            hovered = imgui.IsItemHovered()
                            if imgui.IsItemClicked(0) then
                                U.ripple_at(key)
                                click_way(n, shift)
                            elseif imgui.IsItemClicked(1) then
                                U.ripple_at(key)
                                clear_way(n)
                            end
                        end
                        local hv = U.A.hover[key] or 0
                        hv = U.lerp(hv, hovered and 1 or 0, math.min(1, dt * 14))
                        U.A.hover[key] = hv
                        local tr = sq and S(4) or S(13)
                        if on then
                            local g = 0.6 + 0.3 * hv
                            for k = 3, 1, -1 do
                                dl:AddRectFilled({ wx - S(k), wy - S(k) }, { wx + tile + S(k), wy + wtile + S(k) }, u32(hex, 0.045 * g * a), tr + S(k))
                            end
                        end
                        dl:AddRectFilled({ wx, wy }, { wx + tile, wy + wtile }, u32(on and hex or P.card, (on and 0.16 or 0.7) * a), tr)
                        if hv > 0 then dl:AddRectFilled({ wx, wy }, { wx + tile, wy + wtile }, u32(hex, 0.16 * hv * a), tr) end
                        dl:AddRect({ wx, wy }, { wx + tile, wy + wtile }, u32(on and hex or mix(P.line, hex, 0.6 * hv), (on and 0.7 or 0.35 + 0.4 * hv) * a), tr, 15, 1)
                        U.draw_ripples(dl, key, wx, wy, tile, wtile, hex)
                        draw_glyph(dl, n, wx + tile / 2, wy + wtile / 2, wtile * 0.3 * (1 + 0.08 * hv), a * fade, on and 0 or 0.45 * (1 - hv), 0)
                        if hovered and not quiet then
                            local _, col, text = act_way(n)
                            hint = { wx + tile / 2, text, col }
                        end
                        wx = wx + tile + gap
                    end
                end
            end
            dl:PopClipRect()
            if hint then bar_hint(hint[1], y + h, hint[2], hint[3]) end
        end)
        dl:PopClipRect()
        set_alpha(1)
        if not ok then vana.log('clawmark-vanacore bar: ' .. tostring(err)) end
    end
    imgui.End()
end

-------------------------------------------------------------------------------
-- The settings
-------------------------------------------------------------------------------

-- A glass sheet under the bar (over it when there's no room below), in two columns: the theme and the look on the
-- left, the marks over targets and the behaviour on the right, and Defaults at the foot. It fades in and out.

-- a label, then a slider: the row's value back, and whether the slider was let go
local function slider_row(dl, key, x, cy, w, label, value, min, max, fmt)
    local S = U.S
    U.text_mid(dl, x, cy, label, P.dim, F.text, T.small)
    return U.slider(dl, key, x + S(66), cy, w - S(66) - S(78), value, min, max, fmt)
end

local function settings_body(dl, x, y, w, h, a)
    local S, u32, mix = U.S, U.u32, U.mix
    local now_t = imgui.GetTime()
    local changed = false
    local v, released

    U.shadow(dl, x, y, w, h, S(16), 1.6 * a)
    U.panel(dl, x, y, w, h, P.glass, 0.98, S(16), P.accent2, true)

    -- the head: the paw, the name, the version and the close button, over a line in the theme's colours
    local head = S(58)
    dl:AddRectFilled({ x + 1, y + 1 }, { x + w - 1, y + head }, u32(P.accent2, 0.08), S(15), 48) -- 48: the top corners
    -- the head is a handle: hold it and drag to move the sheet (kept as an offset from its place under the bar)
    imgui.SetCursorScreenPos({ x + S(8), y + S(4) })
    imgui.InvisibleButton('##cm_set_drag', { w - S(72), head - S(8) })
    if imgui.IsItemActive() then
        local mx, my = imgui.GetMousePos()
        if SET.drag == nil then SET.drag = { mx = mx, my = my, dx = cfg.settings_dx, dy = cfg.settings_dy } end
        cfg.settings_dx = SET.drag.dx + (mx - SET.drag.mx)
        cfg.settings_dy = SET.drag.dy + (my - SET.drag.my)
    elseif SET.drag then
        SET.drag = nil
        changed = true
    end
    local px, py = x + S(32), y + head / 2
    local breath = 0.5 + 0.5 * math.sin(now_t * 2.2)
    for k = 3, 1, -1 do dl:AddCircleFilled({ px, py }, S(12) + S(3.5) * k, u32(P.accent, 0.035 + 0.02 * breath), 32) end
    draw_paw(dl, px, py, S(13), u32(P.accent))
    local tw, th = U.measure('CLAWMARK', F.disp, T.h1)
    U.gradient_text(dl, x + S(56), py - th / 2, 'CLAWMARK', P.accent, P.accent2, F.disp, T.h1)
    U.text_mid(dl, x + S(56) + tw + S(10), py + S(1), 'SETTINGS', P.faint, F.disp, T.small)
    if U.icon_button(dl, '##cm_set_close', x + w - S(46), py - S(15), S(30), 'xmark', P.dim, 'Close (Esc)') then SET.open = false end
    local ver = 'v' .. addon.version
    local vw = U.measure(ver, F.semi, T.tiny)
    U.text_mid(dl, x + w - S(58) - vw, py, ver, P.faint, F.semi, T.tiny)
    local ly, mid = y + head, x + w / 2
    dl:AddRectFilledMultiColor({ x + S(16), ly }, { mid, ly + S(1.5) }, u32(P.accent, 0), u32(P.accent2, 0.85), u32(P.accent2, 0.85), u32(P.accent, 0))
    dl:AddRectFilledMultiColor({ mid, ly }, { x + w - S(16), ly + S(1.5) }, u32(P.accent2, 0.85), u32(P.cyan, 0), u32(P.cyan, 0), u32(P.accent2, 0.85))

    local top = ly + S(18)
    local cw = (w - S(24) * 2 - S(32)) / 2
    local c1, c2 = x + S(24), x + S(24) + cw + S(32)

    -- left: the theme, as gems
    local cy = U.section(dl, c1, top, cw, 'THEME', 'gem') + S(8)
    local per, d = 6, S(30)
    local gapx = (cw - per * d) / (per - 1)
    local hover_theme
    for i, thm in ipairs(U.THEMES) do
        local col, row = (i - 1) % per, math.floor((i - 1) / per)
        local ox, oy = c1 + col * (d + gapx), cy + row * (d + S(12))
        local key = '##cm_theme' .. i
        imgui.SetCursorScreenPos({ ox - S(3), oy - S(3) })
        local pressed, hovered, hv = U.hit(key, d + S(6), d + S(6), d / 2 + S(3))
        local on = cfg.theme == thm.id
        local ccx, ccy = ox + d / 2, oy + d / 2
        local acc = thm.palette.accent or P.accent
        if on then
            for k = 3, 1, -1 do dl:AddCircleFilled({ ccx, ccy }, d / 2 + S(2.5) * k, u32(acc, 0.08), 32) end
            dl:AddCircle({ ccx, ccy }, d / 2 + S(3.5), u32(acc), 32, S(2))
        elseif hv > 0 then
            dl:AddCircle({ ccx, ccy }, d / 2 + S(3.5), u32(acc, 0.6 * hv), 32, S(1.5))
        end
        draw_theme_orb(dl, ccx, ccy, d / 2 * (1 + 0.08 * hv), thm)
        if on then U.icon(dl, ccx, ccy, 'check', '#FFFFFF', T.tiny) end
        if hovered then hover_theme = thm end
        if pressed and not on then
            cfg.theme = thm.id
            U.apply_theme(thm.id)
            changed = true
        end
    end
    cy = cy + math.ceil(#U.THEMES / per) * (d + S(12)) + S(4)
    local shown = hover_theme or U.THEME_BY_ID[cfg.theme] or U.THEMES[1]
    U.text_mid(dl, c1, cy, shown.name, shown.palette.accent or P.accent, F.semi, T.small)
    local nw = U.measure(shown.name, F.semi, T.small)
    local note = hover_theme and (hover_theme.id == cfg.theme and 'in use' or 'click to use it') or "Party Finder's themes"
    U.text_mid(dl, c1 + nw + S(8), cy, '·  ' .. note, P.faint, F.text, T.tiny)
    cy = cy + S(26)

    -- left: the look
    cy = U.section(dl, c1, cy, cw, 'LOOK', 'sliders') + S(16)
    -- the interface's scale is applied when the slider is let go (applying it mid-drag moves the slider under the mouse)
    local auto = cfg.scale == 0
    local cur = auto and auto_scale() or cfg.scale
    SET.scale_edit = SET.scale_edit or cur
    v, _, released = slider_row(dl, '##cm_scale', c1, cy, cw, 'Scale', SET.scale_edit, 50, 300, (auto and not SET.scale_drag) and 'Auto' or '%d%%')
    SET.scale_drag = imgui.IsItemActive()
    SET.scale_edit = math.floor(v / 5 + 0.5) * 5
    if released then cfg.scale = SET.scale_edit changed = true end
    if not SET.scale_drag and not released then SET.scale_edit = cur end
    if not auto then
        if U.icon_button(dl, '##cm_auto', c1 + cw - S(24), cy - S(12), S(24), 'rotate-right', P.dim, 'Automatic: from the screen size') then
            cfg.scale = 0
            SET.scale_edit = nil
            changed = true
        end
    end
    cy = cy + S(34)
    v, _, released = slider_row(dl, '##cm_opacity', c1, cy, cw, 'Opacity', cfg.opacity, 20, 100, '%d%%')
    cfg.opacity = math.floor(v + 0.5)
    if released then changed = true end
    cy = cy + S(36)
    local tv, tch = U.toggle(dl, '##cm_solid', c1, cy, 'Solid under the pointer', cfg.solid)
    cfg.solid, changed = tv, changed or tch
    cy = cy + S(30)

    -- left: how the bar's clicks go, so the rules can be looked up without reading anything else
    cy = U.section(dl, c1, cy, cw, 'CLICKS', 'circle-info') + S(10)
    for _, l in ipairs({
        { 'A free mark', 'goes on your target' },
        { "A mark that's out", 'targets what carries it' },
        { 'The mark your target carries', 'comes off' },
        { 'Shift-click', 'moves a mark onto your target' },
        { 'Right-click', 'takes a mark off  ·  hold the X: all off' },
        { 'A free waymark', 'goes down at your feet' },
        { "A waymark that's out", 'comes off  ·  Shift-click: moves it here' },
        { 'Right-click the ground', 'a menu of the waymarks, to put one there' },
    }) do
        local lw = U.measure(l[1], F.semi, T.tiny)
        U.text_mid(dl, c1, cy, l[1], P.text, F.semi, T.tiny)
        U.text_mid(dl, c1 + lw + S(6), cy, l[2], P.dim, F.text, T.tiny)
        cy = cy + S(18)
    end
    cy = cy + S(6)

    -- left: the waymarks
    cy = U.section(dl, c1, cy, cw, 'WAYMARKS', 'flag') + S(16)
    tv, tch = U.toggle(dl, '##cm_ways', c1, cy, 'Their row in the bar', cfg.ways)
    cfg.ways, changed = tv, changed or tch
    cy = cy + S(34)
    v, _, released = slider_row(dl, '##cm_beam', c1, cy, cw, 'Column', cfg.beam, 0, 15, cfg.beam == 0 and 'none' or '%.0f yalms')
    cfg.beam = math.floor(v + 0.5)
    if released then changed = true end
    cy = cy + S(32)
    v, _, released = slider_row(dl, '##cm_wayr', c1, cy, cw, 'Width', cfg.way_radius, 0.5, 4, '%.1f yalms')
    cfg.way_radius = math.floor(v * 2 + 0.5) / 2
    if released then changed = true end
    cy = cy + S(26)
    local left_end = cy - S(4)

    -- right: the marks over targets, with a preview at their size there (the eight in turn)
    dl:AddLine({ c2 - S(16), top }, { c2 - S(16), left_end }, u32(P.line), 1)
    cy = U.section(dl, c2, top, cw, 'MARKS OVER TARGETS', 'eye') + S(8)
    local wh = S(118)
    dl:AddRectFilled({ c2, cy }, { c2 + cw, cy + wh }, u32(P.well), S(12))
    local n = math.floor(now_t / 1.4) % #MARKS + 1
    local since = now_t % 1.4
    local hex = MARKS[n].hex
    local pcx, pcy = c2 + cw / 2, cy + wh / 2 - S(6)
    dl:PushClipRect({ c2, cy }, { c2 + cw, cy + wh }, true)
    for k = 5, 1, -1 do dl:AddCircleFilled({ pcx, pcy }, S(13) * k, u32(hex, 0.03), 40) end
    local base = cfg.size / 100 * (VIEW.h or 1080) / 1080 * 22
    local r = math.min(base, wh * 0.34)
    local pop = math.max(0, 1 - since / 0.3)
    draw_mark(dl, n, pcx, pcy, r * (1 + 0.5 * pop * pop), a)
    dl:PopClipRect()
    dl:AddRect({ c2, cy }, { c2 + cw, cy + wh }, u32(P.line), S(12), 15, 1)
    U.text(dl, c2 + S(12), cy + wh - S(22), MARKS[n].name, hex, F.semi, T.tiny)
    local pnote = base > wh * 0.34 and 'shown smaller here' or 'as over a target'
    local pw = U.measure(pnote, F.text, T.tiny)
    U.text(dl, c2 + cw - S(12) - pw, cy + wh - S(22), pnote, P.faint, F.text, T.tiny)
    cy = cy + wh + S(22)
    v, _, released = slider_row(dl, '##cm_size', c2, cy, cw, 'Size', cfg.size, 50, 300, '%d%%')
    cfg.size = math.floor(v / 5 + 0.5) * 5
    if released then changed = true end
    cy = cy + S(32)
    v, _, released = slider_row(dl, '##cm_height', c2, cy, cw, 'Height', cfg.height, 0, 3, '%.1f sizes')
    cfg.height = math.floor(v * 10 + 0.5) / 10
    if released then changed = true end
    cy = cy + S(34)
    tv, tch = U.toggle(dl, '##cm_glow', c2, cy, 'A ring of light under them', cfg.glow)
    cfg.glow, changed = tv, changed or tch
    cy = cy + S(30)

    -- right: the behaviour
    cy = U.section(dl, c2, cy, cw, 'BEHAVIOUR', 'bell') + S(16)
    tv, tch = U.toggle(dl, '##cm_chat', c2, cy, "Others' marks said in chat", cfg.chat)
    cfg.chat, changed = tv, changed or tch
    cy = cy + S(34)
    tv, tch = U.toggle(dl, '##cm_rclick', c2, cy, 'Right-click a target for marks', cfg.right_click)
    cfg.right_click, changed = tv, changed or tch
    cy = cy + S(34)
    tv, tch = U.toggle(dl, '##cm_intarget', c2, cy, 'The mark in the Target window', cfg.in_target)
    cfg.in_target, changed = tv, changed or tch
    local right_end = cy + S(14)

    -- the foot
    local fy = math.max(left_end, right_end) + S(18)
    dl:AddLine({ x + S(16), fy }, { x + w - S(16), fy }, u32(P.line), 1)
    U.text_mid(dl, x + S(24), fy + S(25), '/mark help and /wp help list the commands   ·   /claw works too', P.faint, F.text, T.tiny)
    if U.button(dl, '##cm_defaults', x + w - S(24) - S(116), fy + S(12), S(116), S(26), 'Defaults', P.dim, 'ghost', 'rotate-right', F.semi, T.tiny) then
        for k, val in pairs(DEFAULTS) do
            if k ~= 'bar' and k ~= 'folded' and k ~= 'settings_dx' and k ~= 'settings_dy' then cfg[k] = val end
        end
        U.apply_theme(cfg.theme)
        SET.scale_edit = nil
        changed = true
    end
    SET.h = fy + S(50) - y

    if imgui.IsKeyPressed(U.KEY_ESCAPE) then SET.open = false end
    if changed then config:save() end
end

local function draw_settings()
    local dt = frame_dt()
    SET.anim = U.lerp(SET.anim, SET.open and 1 or 0, math.min(1, dt * (SET.open and 10 or 14)))
    if not SET.open and SET.anim < 0.02 then
        SET.anim, SET.frames = 0, 0
        return
    end
    if not st.kit then return end
    local S = U.S
    local a = U.ease(SET.anim)
    local w = S(640)
    local h = SET.h or S(470)
    local sw, sh = vana.ui.screen()
    local x, y
    if BAR.rect then
        local bx, by, _, bh = BAR.rect[1], BAR.rect[2], BAR.rect[3], BAR.rect[4]
        x = math.max(S(8), math.min(bx, sw - w - S(8)))
        local below = by + bh + S(10)
        if below + h <= sh - S(8) then
            y = below - S(10) * (1 - a)
        else
            y = math.max(S(8), by - h - S(10)) + S(10) * (1 - a)
        end
    else
        x, y = (sw - w) / 2, (sh - h) / 2 - S(10) * (1 - a)
    end
    -- where it was dragged to, kept on the screen
    x = math.max(S(8), math.min(x + cfg.settings_dx, sw - w - S(8)))
    y = math.max(S(8), math.min(y + cfg.settings_dy, sh - h - S(8)))
    imgui.SetNextWindowPos({ x, y }, U.ALWAYS)
    imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
    SET.frames = SET.frames + 1
    if SET.frames <= 2 then imgui.SetNextWindowFocus() end
    U.push_theme()
    if imgui.Begin('##clawmark_settings', nil, U.WINDOW_FLAGS + U.NO_SAVE) then
        local dl = imgui.GetWindowDrawList()
        local mg = S(40)
        dl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
        set_alpha(a)
        local ok, err = pcall(settings_body, dl, x, y, w, h, a)
        set_alpha(1)
        dl:PopClipRect()
        if not ok then
            vana.log('clawmark-vanacore settings: ' .. tostring(err))
            SET.open = false
        end
    end
    imgui.End()
    U.pop_theme()
end

-------------------------------------------------------------------------------
-- Right-click a target: the mark menu
-------------------------------------------------------------------------------

-- A right-click (not a drag: a drag still turns the camera) over something targetable opens a menu at the cursor.
local MENU = { down = nil, want = nil, open = nil }

-- An entity's bounding box (its actor's eight corners) on screen: x0, y0, x1, y1, or nil
local function box_on_screen(index)
    if VIEW.ent == nil then return nil end
    local actor = VIEW.actor_of(VIEW.ent, index)
    if actor == 0 then return nil end
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for c = 0, 7 do
        local at = actor + 0x918 + c * 16
        local sx, sy = to_screen(vana.memory.read_float(at), vana.memory.read_float(at + 4), vana.memory.read_float(at + 8))
        if sx == nil or sx ~= sx then return nil end
        x0, y0, x1, y1 = math.min(x0, sx), math.min(y0, sy), math.max(x1, sx), math.max(y1, sy)
    end
    if x1 - x0 > VIEW.w or y1 - y0 > VIEW.h then return nil end
    return x0, y0, x1, y1
end

-- The nearest targetable thing under the cursor (its box, or a mark over it), within 50 yalms; not you
local function entity_under(mx, my)
    if not VIEW.ok then return nil end
    local me = my_id()
    local best, best_d
    local function take(index, e)
        if best_d == nil or e.distance < best_d then best, best_d = index, e.distance end
    end
    for index, d in pairs(DRAWN) do
        local e = vana.game.entity(index)
        if e and math.abs(mx - d[1]) <= d[3] * 1.3 and math.abs(my - d[2]) <= d[3] * 1.3 then take(index, e) end
    end
    local pad = VIEW.h / 1080 * 12
    for index = 0, vana.game.entity_count() - 1 do
        local e = vana.game.entity(index)
        if e and e.valid_target and e.id ~= me and (e.distance or 1e9) < 2500 then
            local x0, y0, x1, y1 = box_on_screen(index)
            if x0 then
                local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                if math.abs(mx - cx) <= math.max((x1 - x0) / 2, pad) and math.abs(my - cy) <= math.max((y1 - y0) / 2, pad) then
                    take(index, e)
                end
            end
        end
    end
    return best
end

-- Right-click on the ground: a menu of the waymarks, to put one down on the spot under the pointer (m.ground, from
-- vana.world.pick). The spot is ringed on the ground while the menu is up, in the colour of the waymark under the pointer.
local function draw_ground_menu(m)
    local g = m.ground
    local S, u32, mix, now_t = U.S, U.u32, U.mix, imgui.GetTime()
    local dt = frame_dt()
    local rows = {}
    if next(st.ways) ~= nil then
        rows[#rows + 1] = { label = 'Take every waymark off', ic = 'trash-can', color = P.warn, run = function () clear_way(nil) end }
    end
    local pad, tile, tgap, head_h, row_h = S(8), S(56), S(6), S(50), S(32)
    local w = pad * 2 + tile * 4 + tgap * 3
    local grid_h = tile * 2 + tgap
    local h = head_h + pad + grid_h + pad + (#rows > 0 and pad + #rows * row_h or 0) + pad
    m.anim = math.min(1, m.anim + dt * 9)
    local a = U.ease(m.anim)
    local sw, sh = vana.ui.screen()
    local x = math.max(S(8), math.min(m.x, sw - w - S(8)))
    local y = math.max(S(8), math.min(m.y, sh - h - S(8))) - S(6) * (1 - a)
    local too_far = g.d > WAY_REACH
    local hover_n
    imgui.SetNextWindowPos({ x, y }, U.ALWAYS)
    imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
    m.frames = m.frames + 1
    if m.frames <= 3 then imgui.SetNextWindowFocus() end
    if imgui.Begin('##clawmark_ground_menu', nil, U.WINDOW_FLAGS + U.NO_SAVE) then
        local dl = imgui.GetWindowDrawList()
        local mg = S(40)
        dl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
        local ok, err = pcall(function ()
            U.shadow(dl, x, y, w, h, S(14), 1.5 * a)
            U.panel(dl, x, y, w, h, P.glass, a, S(14), P.line, false)
            dl:AddRectFilled({ x + 1, y + 1 }, { x + w - 1, y + head_h }, u32(P.accent, 0.10 * a), S(13), 48)
            local tag = ('%.0fy'):format(g.d)
            local tw = U.measure(tag, F.semi, T.tiny)
            U.text(dl, x + S(14), y + S(8), 'Waymark here', P.text, F.disp, T.body, a)
            U.text(dl, x + w - S(14) - tw, y + S(11), tag, too_far and P.danger or P.accent, F.semi, T.tiny, a)
            local sub = too_far and 'Too far: a waymark goes within 60 yalms of you' or 'Click one to put it down on this spot'

            -- the waymarks, four by two: A to D round, 1 to 4 square
            local gy = y + head_h + pad
            for n = 1, #WAYS do
                local wmk = st.ways[n]
                local col, row = (n - 1) % 4, math.floor((n - 1) / 4)
                local tx, ty = x + pad + col * (tile + tgap), gy + row * (tile + tgap)
                local key = '##cm_gtile' .. n
                imgui.SetCursorScreenPos({ tx, ty })
                local pressed, _, hv = U.hit(key, tile, tile, S(10))
                local hex, rr = WAYS[n].hex, WAYS[n].square and S(5) or S(10)
                dl:AddRectFilled({ tx, ty }, { tx + tile, ty + tile }, u32(wmk and hex or P.card, (wmk and 0.18 or 0.9) * a), rr)
                if hv > 0 then dl:AddRectFilled({ tx, ty }, { tx + tile, ty + tile }, u32(hex, 0.14 * hv * a), rr) end
                dl:AddRect({ tx, ty }, { tx + tile, ty + tile }, u32(wmk and hex or mix(P.line, hex, 0.6 * hv), (wmk and 0.8 or 1) * a), rr, 15, wmk and S(1.5) or 1)
                U.draw_ripples(dl, key, tx, ty, tile, tile, hex)
                draw_glyph(dl, n, tx + tile / 2, ty + tile * 0.42, tile * 0.24 * (1 + 0.1 * hv), a, 0, 0)
                U.text_center(dl, tx, ty + tile * 0.8, tile, wmk and 'out' or 'free', wmk and P.faint or mix(P.dim, P.text, hv), F.semi, T.tiny, a)
                if hv > 0.5 then
                    hover_n = n
                    if not too_far then
                        sub = wmk and (WAYS[n].name .. ' is out: click to move it here') or ('Click to put ' .. WAYS[n].name .. ' here')
                    end
                end
                if pressed and not too_far then
                    put_way_at(n, g.x, g.y, g.z)
                    MENU.open = nil
                end
            end
            U.text(dl, x + S(14), y + S(28), U.fit(sub, F.text, T.tiny, w - S(28)), P.dim, F.text, T.tiny, a)
            dl:AddLine({ x + 1, y + head_h }, { x + w - 1, y + head_h }, u32(P.line, a), 1)

            -- the rows
            if #rows > 0 then
                local cy = gy + grid_h + pad
                dl:AddLine({ x + S(14), cy }, { x + w - S(14), cy }, u32(P.line, 0.8 * a), 1)
                cy = cy + pad
                for i, r in ipairs(rows) do
                    local key, rx, rw = '##cm_grow' .. i, x + pad, w - pad * 2
                    imgui.SetCursorScreenPos({ rx, cy })
                    local pressed, _, hv = U.hit(key, rw, row_h, S(8))
                    if hv > 0 then
                        dl:AddRectFilled({ rx, cy }, { rx + rw, cy + row_h }, u32(r.color, (0.06 + 0.1 * hv) * a), S(8))
                        dl:AddRectFilled({ rx, cy + S(9) }, { rx + S(3), cy + row_h - S(9) }, u32(r.color, hv * a), S(1.5))
                    end
                    U.draw_ripples(dl, key, rx, cy, rw, row_h, r.color)
                    U.icon(dl, rx + S(18), cy + row_h / 2, r.ic, r.color, T.small, a)
                    U.text_mid(dl, rx + S(36), cy + row_h / 2, r.label, mix(P.text, r.color, 0.3 + 0.7 * hv), F.semi, T.small, a)
                    if pressed then
                        U.ripple_at(key)
                        r.run()
                        MENU.open = nil
                    end
                    cy = cy + row_h
                end
            end

            if now_t - m.at > 0.15 and (imgui.IsMouseClicked(0) or imgui.IsMouseClicked(1)) then
                local mx, my = imgui.GetMousePos()
                if mx < x or mx > x + w or my < y or my > y + h then MENU.open = nil end
            end
            if imgui.IsKeyPressed(U.KEY_ESCAPE) then MENU.open = nil end
        end)
        dl:PopClipRect()
        if not ok then vana.log('clawmark-vanacore waymark menu: ' .. tostring(err)) MENU.open = nil end
    end
    imgui.End()
    if MENU.open == m and VIEW.ok then
        local col = hover_n and WAYS[hover_n].color or { 0.85, 0.9, 1.0 }
        draw_ground_ring(imgui.GetBackgroundDrawList(), col, g.x, g.z, g.y, cfg.way_radius, too_far and 0.35 or 0.7, clock(), g.d,
            hover_n and WAYS[hover_n].square or false)
    end
end

-- The menu is a glass sheet at the pointer in Party Finder's and the Auction House's style (ui.lua, their shared kit):
-- a head with the target and its mark, the eight marks as tiles, then the rows. A click elsewhere or Esc closes it.
local function draw_menu()
    if MENU.want then
        local w = MENU.want
        MENU.want = nil
        -- under the pointer, so it has the hover from the start
        MENU.open = { index = w.index, id = w.id, ground = w.ground, x = w.x - U.S(10), y = w.y - U.S(10), at = imgui.GetTime(), anim = 0, frames = 0 }
    end
    local m = MENU.open
    if m == nil or not st.kit then return end
    if m.ground then return draw_ground_menu(m) end
    local e = vana.game.entity(m.index)
    if e == nil or e.id ~= m.id then MENU.open = nil return end

    local S, u32, mix, now_t = U.S, U.u32, U.mix, imgui.GetTime()
    local dt = math.max(0.001, math.min(0.1, imgui.GetIO().DeltaTime or 0.016))
    local has = nil
    for n, mk in pairs(st.marks) do if mk.id == m.id then has = n end end
    local rows = {}
    if has then
        rows[#rows + 1] = { label = 'Take its mark off', ic = 'xmark', color = P.danger, run = function () clear(has) end }
    end
    rows[#rows + 1] = { label = 'Target it', ic = 'location-dot', color = P.cyan, run = function () vana.game.set_target(m.index) end }
    if next(st.marks) ~= nil then
        rows[#rows + 1] = { label = 'Take every mark off', ic = 'trash-can', color = P.warn, run = function () clear(nil) end }
    end

    local pad, tile, tgap, head_h, row_h = S(8), S(56), S(6), S(50), S(32)
    local w = pad * 2 + tile * 4 + tgap * 3
    local grid_h = tile * 2 + tgap
    local h = head_h + pad + grid_h + pad * 2 + #rows * row_h + pad
    m.anim = math.min(1, m.anim + dt * 9)
    local a = U.ease(m.anim)
    local sw, sh = vana.ui.screen()
    local x = math.max(S(8), math.min(m.x, sw - w - S(8)))
    local y = math.max(S(8), math.min(m.y, sh - h - S(8))) - S(6) * (1 - a)
    imgui.SetNextWindowPos({ x, y }, U.ALWAYS)
    imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
    m.frames = m.frames + 1
    if m.frames <= 3 then imgui.SetNextWindowFocus() end -- in front, whatever the click that opened it did to the focus
    if imgui.Begin('##targecmark_menu', nil, U.WINDOW_FLAGS + U.NO_SAVE) then
        local dl = imgui.GetWindowDrawList()
        local mg = S(40)
        dl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
        local ok, err = pcall(function ()
            local tint = has and MARKS[has].hex or P.accent
            U.shadow(dl, x, y, w, h, S(14), 1.5 * a)
            U.panel(dl, x, y, w, h, P.glass, a, S(14), P.line, false)

            -- the head: what it is, how far, and its mark (or what the tile under the pointer would do)
            dl:AddRectFilled({ x + 1, y + 1 }, { x + w - 1, y + head_h }, u32(tint, 0.10 * a), S(13), 48) -- 48: the top corners
            local kind = bit.band(e.spawn_flags or 0, 0x10) ~= 0 and 'Monster' or (e.type == 0 and 'Player' or 'NPC')
            local tag = ('%s  ·  %.0fy'):format(kind, math.sqrt(e.distance or 0))
            local tw = U.measure(tag, F.semi, T.tiny)
            U.text(dl, x + S(14), y + S(8), U.fit(e.name ~= '' and e.name or 'Target', F.disp, T.body, w - tw - S(40)), P.text, F.disp, T.body, a)
            U.text(dl, x + w - S(14) - tw, y + S(11), tag, tint, F.semi, T.tiny, a)
            local sub
            if has then
                local who = player_name(st.marks[has].setter)
                sub = 'Marked with ' .. MARKS[has].name .. (who and (', by ' .. who) or '')
            else
                sub = 'Not marked'
            end

            -- the marks, four by two
            local gy = y + head_h + pad
            for n = 1, #MARKS do
                local mk, here = st.marks[n], has == n
                local col, row = (n - 1) % 4, math.floor((n - 1) / 4)
                local tx, ty = x + pad + col * (tile + tgap), gy + row * (tile + tgap)
                local key = '##tm_tile' .. n
                imgui.SetCursorScreenPos({ tx, ty })
                local pressed, _, hv = U.hit(key, tile, tile, S(10))
                local hex = MARKS[n].hex
                dl:AddRectFilled({ tx, ty }, { tx + tile, ty + tile }, u32(here and hex or P.card, (here and 0.18 or 0.9) * a), S(10))
                if hv > 0 then dl:AddRectFilled({ tx, ty }, { tx + tile, ty + tile }, u32(hex, 0.14 * hv * a), S(10)) end
                if here then
                    dl:AddRect({ tx, ty }, { tx + tile, ty + tile }, u32(hex, 0.95 * a), S(10), 15, S(2))
                else
                    dl:AddRect({ tx, ty }, { tx + tile, ty + tile }, u32(mix(P.line, hex, 0.6 * hv), a), S(10), 15, 1)
                end
                U.draw_ripples(dl, key, tx, ty, tile, tile, hex)
                local away = mk ~= nil and not here
                draw_mark(dl, n, tx + tile / 2, ty + tile * 0.4, tile * 0.22 * (1 + 0.1 * hv), a, away and 0.55 or 0)
                U.text_center(dl, tx, ty + tile * 0.8, tile, MARKS[n].name, away and P.faint or mix(P.dim, P.text, here and 1 or hv),
                    F.semi, T.tiny, a)
                if away then dl:AddCircleFilled({ tx + tile - S(8), ty + S(8) }, S(3), u32(hex, 0.9 * a), 12) end
                if hv > 0.5 then
                    if here then sub = 'Click to take the ' .. MARKS[n].name .. ' off'
                    elseif away then sub = MARKS[n].name .. ' is on ' .. entity_name(mk.index, mk.id) .. ': click to move it'
                    else sub = 'Click to put the ' .. MARKS[n].name .. ' here' end
                end
                if pressed then
                    put(n, m.index)
                    MENU.open = nil
                end
            end
            U.text(dl, x + S(14), y + S(28), U.fit(sub, F.text, T.tiny, w - S(28)), P.dim, F.text, T.tiny, a)
            dl:AddLine({ x + 1, y + head_h }, { x + w - 1, y + head_h }, u32(P.line, a), 1)

            -- the rows
            local cy = gy + grid_h + pad
            dl:AddLine({ x + S(14), cy }, { x + w - S(14), cy }, u32(P.line, 0.8 * a), 1)
            cy = cy + pad
            for i, r in ipairs(rows) do
                local key, rx, rw = '##tm_row' .. i, x + pad, w - pad * 2
                imgui.SetCursorScreenPos({ rx, cy })
                local pressed, _, hv = U.hit(key, rw, row_h, S(8))
                if hv > 0 then
                    dl:AddRectFilled({ rx, cy }, { rx + rw, cy + row_h }, u32(r.color, (0.06 + 0.1 * hv) * a), S(8))
                    dl:AddRectFilled({ rx, cy + S(9) }, { rx + S(3), cy + row_h - S(9) }, u32(r.color, hv * a), S(1.5))
                end
                U.draw_ripples(dl, key, rx, cy, rw, row_h, r.color)
                U.icon(dl, rx + S(18), cy + row_h / 2, r.ic, r.color, T.small, a)
                U.text_mid(dl, rx + S(36), cy + row_h / 2, r.label, mix(P.text, r.color, 0.3 + 0.7 * hv), F.semi, T.small, a)
                if pressed then
                    U.ripple_at(key)
                    r.run()
                    MENU.open = nil
                end
                cy = cy + row_h
            end

            -- a click anywhere else, or Escape, closes it (not just after it opened: the window isn't hovered yet)
            if now_t - m.at > 0.15 and (imgui.IsMouseClicked(0) or imgui.IsMouseClicked(1)) then
                local mx, my = imgui.GetMousePos()
                if mx < x or mx > x + w or my < y or my > y + h then MENU.open = nil end
            end
            if imgui.IsKeyPressed(U.KEY_ESCAPE) then MENU.open = nil end
        end)
        dl:PopClipRect()
        if not ok then vana.log('clawmark-vanacore menu: ' .. tostring(err)) MENU.open = nil end
    end
    imgui.End()
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

vana.events.on('mouse', function (kind, x, y, delta, blocked)
    if kind == 4 then -- right button down
        local _, _, _, _, _, _, _, status = vana.game.self()
        MENU.down = (not blocked and cfg.right_click and status ~= nil and status ~= 4) and { x, y, clock() } or nil
    elseif kind == 5 then -- right button up
        local d = MENU.down
        MENU.down = nil
        if d == nil or blocked or not VIEW.h then return end
        if math.abs(x - d[1]) + math.abs(y - d[2]) > VIEW.h / 1080 * 8 or clock() - d[3] > 0.45 then return end
        local index = entity_under(x, y)
        if index then
            MENU.want = { index = index, id = vana.game.entity(index).id, x = x, y = y }
            return true
        end
        -- the ground: the waymarks' menu, to put one on the spot (vana.world.pick, a VanaCore newer than 0.8.216: the zone's
        -- collision under the pointer)
        if cfg.ways and vana.world.pick then
            local gx, gy, gz = vana.world.pick(x, y)
            if gx then
                local me = my_entity()
                local far = me and math.sqrt((me.x - gx) ^ 2 + (me.y - gy) ^ 2 + (me.z - gz) ^ 2) or 0
                MENU.want = { ground = { x = gx, y = gy, z = gz, d = far }, x = x, y = y }
                return true
            end
        end
    end
end)

local function group_signature()
    local p = vana.game.party()
    if p == nil or p.members == nil then return '' end
    local ids = {}
    for i = 1, 18 do
        local m = p.members[i]
        if m and m.active and m.id ~= 0 then ids[#ids + 1] = m.id end
    end
    return table.concat(ids, ',')
end

vana.events.on('present', function ()
    if not in_world() then return end
    read_camera()
    draw_world()
    draw_target_badge()
    -- the kit: its scale (from the screen's height, unless set) and its fonts, loaded on the first frame and used from
    -- the next
    local pct = cfg.scale > 0 and cfg.scale or auto_scale()
    st.kit = U.frame(math.max(0.001, math.min(0.1, imgui.GetIO().DeltaTime or 0.016)), pct / 100, imgui.GetTime())
    draw_bar()
    draw_settings()
    draw_menu()
    st.menu_up = MENU.open ~= nil

    local now = clock()
    if st.waiting_since and st.server == nil and now - st.waiting_since > 6 then
        st.server, st.waiting_since = false, nil
        say("This server doesn't relay marks: yours are seen by you alone.")
    end
    if (st.group_check or 0) < now then
        st.group_check = now + 1
        -- (the list reads empty for a moment while zoning: that's not a change, and zone_change syncs anyway)
        local sig = group_signature()
        if sig ~= '' then
            if st.group ~= nil and sig ~= st.group and st.server ~= false then sync_soon(0.5) end
            st.group = sig
        end
    end
end)

vana.events.on('packet_in', function (e)
    if e.id == PACKET then
        local p = ffi.cast('uint8_t*', e.data_raw)
        if p[0x04] == S2C.STATE then on_state(p) elseif p[0x04] == S2C.WAYMARKS then on_ways(p) end
        return true
    end
end)

vana.events.on('zone_out', function ()
    st.marks, st.ways, ME.index = {}, {}, nil
end)

vana.events.on('zone_change', function ()
    st.marks, st.ways, ME.index = {}, {}, nil
    sync_soon(2)
end)

vana.events.on('login', function ()
    st.marks, st.ways, ME.index = {}, {}, nil
    sync_soon(3)
end)

local HELP = {
    '/mark: the mark bar on or off',
    '/mark <mark>: on your target, or off it if it is there',
    '/mark clear [<mark>]: one mark off, or all of them',
    '/mark target <mark>: target what carries it',
    '/mark settings: theme, scale, opacity, sizes;  /mark fold: fold the bar',
    '/mark size <pct>, /mark height <n>, /mark chat, /mark rclick (the right-click menu)',
    '/claw works the same as /mark;  /wp help: the waymarks',
    'Marks: 1-8 or star, circle, diamond, triangle, moon, square, cross, skull',
}

local WAY_HELP = {
    '/wp <waymark>: down at your feet (moves it if it is out);  /wp <waymark> target: at your target\'s feet',
    '/wp <waymark> <yalms>: so many yalms ahead of you',
    '/wp clear [<waymark>]: one waymark off, or all of them',
    '/wp bar: their row in the bar;  /wp column <yalms>: the column of light, 0 (none) to 15;  /wp width <yalms>: 0.5 to 4',
    '/way and /waymark work the same as /wp',
    'Waymarks: A, B, C, D (round) and 1, 2, 3, 4 (square)',
}

vana.events.on('command', function (e)
    local args = {}
    for w in e.command:gmatch('%S+') do args[#args + 1] = w end
    local cmd = (args[1] or ''):lower()
    if cmd ~= '/wp' and cmd ~= '/way' and cmd ~= '/waymark' and cmd ~= '/waymarks' then return end
    local sub = (args[2] or ''):lower()

    if sub == '' or sub == 'help' then
        for _, l in ipairs(WAY_HELP) do say(l) end
    elseif sub == 'bar' then
        cfg.ways = not cfg.ways
        config:save()
        say('The waymarks ' .. (cfg.ways and 'have' or "don't have") .. ' their row in the bar.')
    elseif sub == 'clear' or sub == 'off' then
        if args[3] then
            local n = parse_way(args[3])
            if n then clear_way(n) else say('No waymark called ' .. args[3] .. '.') end
        else
            clear_way(nil)
        end
    elseif sub == 'column' or sub == 'beam' or sub == 'height' then
        local v = tonumber(args[3])
        if v then
            cfg.beam = math.max(0, math.min(15, math.floor(v + 0.5)))
            config:save()
        end
        say(cfg.beam > 0 and ('The column of light over a waymark is %d yalms tall.'):format(cfg.beam) or 'Waymarks are rings alone, with no column.')
    elseif sub == 'width' or sub == 'radius' or sub == 'size' then
        local v = tonumber(args[3])
        if v then
            cfg.way_radius = math.max(0.5, math.min(4, math.floor(v * 2 + 0.5) / 2))
            config:save()
        end
        say(('Waymarks are %.1f yalms wide.'):format(cfg.way_radius))
    else
        local n = parse_way(sub)
        if n == nil then
            say('No waymark called ' .. sub .. '. /wp help lists them.')
            return true
        end
        local where = (args[3] or ''):lower()
        if where == 'off' or where == 'clear' then clear_way(n) else put_way(n, where) end
    end
    return true
end)

vana.events.on('command', function (e)
    local args = {}
    for w in e.command:gmatch('%S+') do args[#args + 1] = w end
    local cmd = (args[1] or ''):lower()
    if cmd ~= '/mark' and cmd ~= '/marks' and cmd ~= '/claw' and cmd ~= '/clawmark' then return end
    local sub = (args[2] or ''):lower()

    if sub == '' or sub == 'bar' then
        cfg.bar = not cfg.bar
        config:save()
    elseif sub == 'settings' or sub == 'config' or sub == 'options' then
        SET.open = not SET.open
    elseif sub == 'fold' then
        cfg.folded = not cfg.folded
        config:save()
    elseif sub == 'help' then
        for _, l in ipairs(HELP) do say(l) end
    elseif sub == 'clear' then
        if args[3] then
            local n = parse_mark(args[3])
            if n then clear(n) else say('No mark called ' .. args[3] .. '.') end
        else
            clear(nil)
        end
    elseif sub == 'target' then
        local n = parse_mark(args[3])
        if n then target_mark(n) else say('/mark target <mark>') end
    elseif sub == 'size' then
        local pct = tonumber(args[3])
        if pct then
            cfg.size = math.max(50, math.min(300, math.floor(pct)))
            config:save()
        end
        say('Marks at ' .. cfg.size .. '%.')
    elseif sub == 'height' then
        local y = tonumber(args[3])
        if y then
            cfg.height = math.max(0, math.min(3, math.floor(y * 10 + 0.5) / 10))
            config:save()
        end
        say(('Marks float %.1f of their size over the name.'):format(cfg.height))
    elseif sub == 'chat' then
        cfg.chat = not cfg.chat
        config:save()
        say("Other players' marks " .. (cfg.chat and 'are' or "aren't") .. ' said in chat.')
    elseif sub == 'theme' then
        local id = (args[3] or ''):lower()
        if U.THEME_BY_ID[id] then
            cfg.theme = id
            config:save()
            U.apply_theme(id)
            say('Clawmark in ' .. U.THEME_BY_ID[id].name .. '.')
        else
            local ids = {}
            for _, t in ipairs(U.THEMES) do ids[#ids + 1] = t.id end
            say('/mark theme <' .. table.concat(ids, '|') .. '>')
        end
    elseif sub == 'rclick' then
        cfg.right_click = not cfg.right_click
        config:save()
        say('Right-clicking a target ' .. (cfg.right_click and 'opens' or "doesn't open") .. ' the mark menu.')
    elseif sub == 'sync' then
        st.server = nil
        sync()
    else
        local n = parse_mark(sub)
        if n == nil then
            say('No mark called ' .. sub .. '. /mark help lists them.')
            return true
        end
        local index = tonumber(args[3])
        put(n, index or target_index())
    end
    return true
end)

vana.events.on('load', function ()
    if in_world() then sync() end
end)
