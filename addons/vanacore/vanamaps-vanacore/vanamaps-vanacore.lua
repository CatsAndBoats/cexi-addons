--[[
vanamaps-vanacore (VanaMaps): the game's maps as a window you can use. Drag to move the map, turn the wheel to zoom
about the pointer, double-click to centre; your arrow, your party and your target are on it; any zone's map opens from
anywhere through the zone browser; and you can drop pins with an icon, a colour, a title and a note, kept per
character, and share one in chat as a line anyone can read:

    [Map: West Ronfaure G-10 "Orcish camp" #8S00EMTFGT5]

A player with VanaMaps who sees that line gets a card offering to open it, and finds it in the map's Shared list.

In game (/vmap works as well as /vanamaps):
  /vmap                     the map on or off (the M key does the same while the chat line is closed)
  /vmap bare                the bare map on or off: the map alone on the screen, no window round it, following you
                            (Shift+M does the same; M from it goes to the whole window, and back)
  /vmap here                the zone and floor you are in, centred on you, following you
  /vmap zone <name or id>   any zone's map
  /vmap pin [title]         a pin where you stand
  /vmap share [channel]     the selected pin (or where you stand) to chat: s, p, l, l2, sh, or t <name>; no channel
                            copies the line instead
  /vmap open <code or line> opens a shared pin (what a chat addon runs when its link is clicked)
  /vmap last                opens the pin shared with you most lately
  /vmap key <key>           the key that opens the map, as /bind spells it: m, ^m (Ctrl+M), f9; none for no key
  /vmap barekey <key>       the same for the bare map (+m is Shift+M)
  /vmap scale <pct|auto>    the window's size, 50 to 250
  /vmap settings            the settings
  /vmap help                this list

The map: drag to pan, wheel to zoom, double-click to centre and zoom in, right-click for a menu (pin here, share this
spot, centre). Click a pin to open its card. A signpost marks each way into a neighbouring zone: click it and that zone's
map opens, with a ring where you would come out. The crosshair button on the map finds you again. With a controller: the left stick moves the pointer, the right stick the
map, the triggers zoom, Confirm drops or opens a pin, Cancel backs out, the bumpers change floors.

While your character moves, either map fades (to the strength set) so the world shows through it, and lets your clicks
and camera drags through to the game; it comes back as you stop. Your arrow, your party and your pins stay clear.

The maps themselves are read from the player's own files, never shipped: the XICombinedMaps pack's 2048 and 1024 pixel
maps when the launcher's Combined Maps is installed (RadialArcana, the FFXI Remapster Project, Moops' Remapster
Labeled), else the game's own. Which map a zone and floor has, and where a position lands on it, come from the game's
own map table, read from the client as it runs (found the way the Ashita Minimap plugin by atom0s finds it).

Settings: settings\addons\vanamaps-vanacore\settings.json; pins: settings\addons\vanamaps-vanacore\<Character>\pins.json.
--]]

addon.name    = 'vanamaps-vanacore'
addon.author  = 'Carver'
addon.version = '1.0'
addon.desc    = 'VanaMaps: interactive maps of every zone, with pins you can share in chat.'

local imgui = vana.imgui
if imgui == nil then
    print('vanamaps-vanacore needs a newer VanaCore.Core.dll (vana.imgui)')
    return
end

local U = require('ui') -- Party Finder's drawing kit (tools/make_ui.py)
local P, F, T = U.P, U.fonts(), U.sizes()
local S = U.S
local PAD = require('pad')
local G = require('gfx')
local DATA = require('mapdata')
local TEX = require('maptex')
local REG = require('regions')
local K = require('pins')

local DEFAULTS = {
    key = 'm', scale = 0, theme = 'aurora', opacity = 100, quality = 2048, w = 1030, h = 800, layout_rev = 0, sidebar = true, side_tab = 'zones',
    follow = true, party = true, target = true, rulers = true, names = true, cards = true, pin_size = 100,
    collapsed = {}, last = { zone = 0, floor = 0 }, layout_checked = false,
    -- the bare map (the map alone, for finding your way) and what moving does to either window
    exits = true,
    bare_key = '+m', bare_size = 82, bare_x = 0.5, bare_y = 0.5, bare_tip = false, move_alpha = 40, move_pass = true,
}
local config = vana.settings.register({ defaults = DEFAULTS })
local pins_store = vana.settings.register({ name = 'pins', scope = 'character', defaults = { pins = {}, shared = {}, next_id = 1 } })
-- (the floors of zones' ways out that the game was asked about on this PC: see the ways, below)
local learned = vana.settings.register({ name = 'floors', defaults = { exits = {} } })

-- what every part of the addon shares (canvas.lua, sidebar.lua)
local C = {
    U = U, G = G, PAD = PAD, DATA = DATA, TEX = TEX, REG = REG, K = K,
    cfg = config.data,
    st = {
        open = false, anim = 0, zone = nil, floor = 0, history = {}, hist_i = 0, follow = false, sel = nil,
        settings_open = false, pad_mode = 'map', query = { zones = { '' }, pins = { '' } }, ping = nil, cards = {},
        last_wheel = 0,
    },
    me = { ok = false }, party = {}, target = nil,
    zone_names = {},
}
local cfg, st = C.cfg, C.st
-- (the strip under the map came later: the window grows by its height once, so the map keeps its size)
if (cfg.layout_rev or 0) < 2 then
    cfg.h = (cfg.h or 800) + 34
    cfg.layout_rev = 2
end
VANAMAPS = C -- (this addon's own Lua state: for a test's eyes, through VanaCore's MCP)

local function clock() return vana.time.clock() end
local function say(text) vana.chat.write('[VanaMaps] ' .. text, 106) end
local function fail(where, err) vana.log('vanamaps-vanacore ' .. where .. ': ' .. tostring(err)) end
C.say, C.fail = say, fail

function C.save() config:save() end
function C.pins() return pins_store.data.pins end
function C.shared() return pins_store.data.shared end
function C.save_pins()
    C.pins_rev = (C.pins_rev or 0) + 1
    pins_store:save()
end

-------------------------------------------------------------------------------
-- Zones
-------------------------------------------------------------------------------

function C.zone_name(id)
    local n = C.zone_names[id]
    if n then return n end
    -- the game's own name first (it has the apostrophes: "Chateau d'Oraguille"), then VanaCore's table
    local ok, s = pcall(vana.ashita.string, 'zones.names', id)
    n = ok and type(s) == 'string' and s ~= '' and vana.encoding.from_shift_jis(s) or nil
    if n == nil or n == '' then
        local ok2, row = pcall(function () return vana.gamedata.zones[id] end)
        n = ok2 and type(row) == 'table' and row.name or nil
    end
    n = (n ~= nil and n ~= '') and n or ('Zone ' .. id)
    C.zone_names[id] = n
    return n
end

function C.region_name(zone)
    local r = REG.of_zone[zone]
    return r and REG.names[r] or nil
end

-- a zone by what a player types: its id, its name, or the start or a part of its name
function C.find_zone(text)
    text = tostring(text or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return nil end
    local id = tonumber(text)
    if id and DATA.zones[id] then return id end
    local starts, has = nil, nil
    for _, z in ipairs(DATA.order) do
        local name = C.zone_name(z):lower()
        if name == text then return z end
        if starts == nil and name:sub(1, #text) == text then starts = z end
        if has == nil and name:find(text, 1, true) then has = z end
    end
    return starts or has
end

-------------------------------------------------------------------------------
-- Where things are: you, your party, your target
-------------------------------------------------------------------------------

local function in_world()
    local ok, id, zone = pcall(vana.game.self)
    if not ok or id == nil then return false end
    return true, zone
end

local TRACK = { floors_at = 0, floors = {} }

-- the floor an entity of this zone is on, asked of the game now and then (it casts a line at the zone's collision)
-- (an answer that isn't one of the zone's floors, as over a gap in the collision or in mid-air, leaves the last good one)
local function floor_of(key, e, refresh)
    local hit = TRACK.floors[key]
    if hit ~= nil and not refresh then return hit end
    local f = DATA.floor_at(e.x, e.y, e.z)
    local z = DATA.zones[TRACK.zone or -1]
    if f ~= nil and (z == nil or z.by_floor[f] ~= nil) then TRACK.floors[key] = f end
    return TRACK.floors[key]
end

local function track(t)
    local me = C.me
    me.ok = false
    C.target = nil
    local here, zone = in_world()
    if not here or vana.game.zoning() then C.party = {} return end
    local okp, party = pcall(vana.game.party)
    if not okp or party == nil or party.members == nil then return end
    local m1 = party.members[1]
    if m1 == nil or (m1.target_index or 0) == 0 then return end
    local e = vana.game.entity(m1.target_index)
    if e == nil then return end
    local refresh = t - TRACK.floors_at > 0.3
    if refresh then TRACK.floors_at = t end
    if TRACK.zone ~= zone then TRACK.zone, TRACK.floors = zone, {} end
    me.ok, me.zone, me.x, me.y, me.z, me.heading, me.name = true, zone, e.x, e.y, e.z, e.heading or 0, m1.name
    -- moving: your place changed since the last frame, with a moment's grace so a pause between steps doesn't flicker
    -- (a jump of twenty yalms in one frame is a warp, not a walk)
    if TRACK.px ~= nil and TRACK.pzone == zone then
        local dx, dy = e.x - TRACK.px, e.y - TRACK.py
        local d2 = dx * dx + dy * dy
        if d2 > 0.0004 and d2 < 400 then TRACK.moved_at = t end
    end
    TRACK.px, TRACK.py, TRACK.pzone = e.x, e.y, zone
    -- (C.pretend_moving: a test's switch, for looking at the faded map without walking)
    me.moving = t - (TRACK.moved_at or -10) < 0.4 or C.pretend_moving == true
    local z = DATA.zones[zone]
    local f = floor_of('me', e, refresh)
    -- (a zone of one map has that map whatever the collision says; a floor the table hasn't got falls to the first)
    if z ~= nil then
        if #z.floors == 1 or f == nil or z.by_floor[f] == nil then
            -- between floors (a stair's own collision) the last floor known stands
            if #z.floors > 1 and me.floor ~= nil and z.by_floor[me.floor] ~= nil and me.floor_zone == zone then f = me.floor
            else f = z.floors[1].floor end
        end
    end
    me.floor, me.floor_zone = f or 0, zone
    if TRACK.floors.me ~= nil and C.learn_ways then C.learn_ways(zone) end

    if not st.open then return end
    local list = {}
    if cfg.party then
        for i = 2, 18 do
            local m = party.members[i]
            if m and m.active and m.zone == zone and (m.target_index or 0) ~= 0 then
                local pe = vana.game.entity(m.target_index)
                if pe ~= nil and not (pe.x == 0 and pe.y == 0) then
                    list[#list + 1] = { name = m.name or '?', job = m.main_job, x = pe.x, y = pe.y, group = math.floor((i - 1) / 6),
                        floor = floor_of('p' .. i, pe, refresh) or me.floor, hpp = m.hpp }
                end
            end
        end
    end
    C.party = list
    if cfg.target then
        local okt, tg = pcall(vana.game.target)
        if okt and tg and tg.active and (tg.index or 0) ~= 0 and tg.index ~= m1.target_index then
            local te = vana.game.entity(tg.index)
            if te ~= nil then
                C.target = { name = te.name and vana.encoding.from_shift_jis(te.name) or '', x = te.x, y = te.y,
                    floor = floor_of('t' .. tg.index, te, refresh) or me.floor }
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Showing a map
-------------------------------------------------------------------------------

-- Opens `zone`'s map at `floor` (its first with none). opts: at = { mx, my } to centre there, zoom (times the fit),
-- follow, keep_history (a step back or forward: nothing is added).
function C.show(zone, floor, opts)
    opts = opts or {}
    local z = DATA.zones[zone]
    if z == nil then return false end
    local f = (floor ~= nil and z.by_floor[floor]) or z.floors[1]
    local changed = st.zone ~= zone or st.floor ~= f.floor
    if changed and st.zone ~= nil and C.CV then C.CV.leave() end
    st.zone, st.floor = zone, f.floor
    st.follow = opts.follow == true
    if changed then
        if st.sel and (st.sel.zone ~= zone or st.sel.floor ~= f.floor) then st.sel = nil end
        if not opts.keep_history then
            for i = #st.history, st.hist_i + 1, -1 do st.history[i] = nil end
            st.history[#st.history + 1] = { zone = zone, floor = f.floor }
            if #st.history > 60 then table.remove(st.history, 1) end
            st.hist_i = #st.history
        end
    end
    if C.CV then C.CV.arrive(changed, opts) end
    cfg.last.zone, cfg.last.floor = zone, f.floor
    return true
end

function C.step_history(by)
    local i = st.hist_i + by
    local h = st.history[i]
    if h == nil then return false end
    st.hist_i = i
    return C.show(h.zone, h.floor, { keep_history = true, view = h.view })
end

-- the zone and floor you are in, centred on you
function C.here(zoom, follow)
    local me = C.me
    if not me.ok or DATA.zones[me.zone] == nil then
        U.toast('warn', 'No map here', 'The game has no map for this area', 4, 'triangle-exclamation')
        return false
    end
    local f = DATA.floor(me.zone, me.floor)
    local mx, my = DATA.to_map(f, me.x, me.y)
    return C.show(me.zone, me.floor, { at = { mx, my }, follow = follow == true or cfg.follow, zoom = zoom })
end

-- Opens or closes the map. `bare`: the map alone, no window round it (Shift+M), for finding your way: it starts on
-- you and follows you. Going from one to the other keeps what's shown.
function C.open(on, bare)
    if on == nil then on = not st.open end
    if on and not DATA.ready then
        local ok, why = DATA.load()
        if not ok then
            say("can't read the game's maps: " .. tostring(why))
            return
        end
    end
    if on then
        local was = st.open
        track(imgui.GetTime())
        st.open, st.bare = true, bare == true
        st.pad_mode = 'map'
        if not was then
            st.opened_at = clock()
            if not C.here(nil, st.bare) then
                local z = DATA.zones[cfg.last.zone] and cfg.last.zone or DATA.order[1]
                C.show(z, cfg.last.floor)
            end
        end
        if st.bare then
            st.settings_open = false
            if C.CV then C.CV.close_card() end
            if not cfg.bare_tip then
                cfg.bare_tip = true
                U.toast('accent', 'The bare map', 'Shift + drag moves it, Shift + wheel sizes it; its key again closes it', 9, 'circle-info')
            end
        end
    else
        st.open = false
        st.settings_open = false
        config:save()
    end
end

-- what the two keys do: each closes its own map, and turns the other's into its own
function C.toggle(bare)
    if st.open and (st.bare == true) == (bare == true) then C.open(false) else C.open(true, bare) end
end

-------------------------------------------------------------------------------
-- Pins
-------------------------------------------------------------------------------

function C.add_pin(zone, floor, mx, my, fields)
    local data = pins_store.data
    local pin = { id = data.next_id, zone = zone, floor = floor, mx = mx, my = my, icon = 'pin', color = 1, title = '', note = '',
        at = os.time() }
    for k, v in pairs(fields or {}) do pin[k] = v end
    data.next_id = data.next_id + 1
    data.pins[#data.pins + 1] = pin
    pin.born = clock() -- (the fall-in; not saved as anything that matters)
    C.save_pins()
    return pin
end

function C.remove_pin(pin)
    local list = C.pins()
    for i, p in ipairs(list) do
        if p == pin or (p.id == pin.id and pin.id ~= nil) then table.remove(list, i) break end
    end
    if st.sel == pin then st.sel = nil end
    C.save_pins()
end

-- the square a pin is in, as the game names it
function C.square(pin)
    local sq = DATA.grid_of_map(pin.mx, pin.my)
    return sq
end

function C.token(pin)
    return K.token(pin, C.zone_name(pin.zone), C.square(pin))
end

local CHANNELS = {
    { id = 's', name = 'Say', cmd = '/s ' }, { id = 'p', name = 'Party', cmd = '/p ' }, { id = 'l', name = 'Linkshell', cmd = '/l ' },
    { id = 'l2', name = 'Linkshell 2', cmd = '/l2 ' }, { id = 'sh', name = 'Shout', cmd = '/sh ' }, { id = 't', name = 'Tell', cmd = '/t ' },
}
C.CHANNELS = CHANNELS

-- Puts a pin on a chat line: channel 's', 'p', 'l', 'l2', 'sh', 't' (with a name), or nil for the clipboard.
function C.share(pin, channel, name)
    local token = C.token(pin)
    if channel == nil or channel == 'copy' then
        vana.system.set_clipboard(token)
        U.toast('ok', 'Copied', 'Paste the pin into any chat line', 3, 'circle-check')
        return true
    end
    for _, ch in ipairs(CHANNELS) do
        if ch.id == channel then
            if ch.id == 't' then
                name = tostring(name or ''):gsub('[^%a]', '')
                if name == '' then say('share by tell needs a name: /vmap share t <name>') return false end
                vana.chat.run(ch.cmd .. name .. ' ' .. token)
            else
                vana.chat.run(ch.cmd .. token)
            end
            U.toast('ok', 'Pin shared', ch.name .. (ch.id == 't' and (' to ' .. name) or ''), 3, 'paper-plane')
            -- (the game's own copy of what you say isn't a packet: your share is noted here)
            local sent = K.find(token)[1]
            if sent then C.receive(sent, C.me.name or 'You', true) end
            return true
        end
    end
    say('no such channel: ' .. tostring(channel) .. ' (s, p, l, l2, sh, t <name>)')
    return false
end

-- A pin that came through chat: kept in the Shared list (the newest first, the same code once), and offered on a card.
function C.receive(pin, from, own)
    if DATA.ready and DATA.zones[pin.zone] == nil then return end
    local list = C.shared()
    for i, s in ipairs(list) do
        if s.code == pin.code then table.remove(list, i) break end
    end
    local entry = { code = pin.code, zone = pin.zone, floor = pin.floor, mx = pin.mx, my = pin.my, icon = pin.icon, color = pin.color,
        title = pin.title or '', from = from or '', at = os.time(), seen = own == true, own = own == true }
    table.insert(list, 1, entry)
    while #list > 40 do table.remove(list) end
    C.save_pins()
    if not own and cfg.cards then
        st.cards[#st.cards + 1] = { entry = entry, at = clock() }
        if #st.cards > 3 then table.remove(st.cards, 1) end
    end
    return entry
end

-- Opens a shared pin on its map, with a ring spreading from it
function C.open_shared(entry)
    if not DATA.ready and not DATA.load() then return false end
    if DATA.zones[entry.zone] == nil then
        say('that pin is in a zone this client has no map for')
        return false
    end
    if not st.open then
        st.open, st.opened_at = true, clock()
        track(imgui.GetTime())
    end
    entry.seen = true
    C.show(entry.zone, entry.floor, { at = { entry.mx, entry.my }, zoom = 2.2 })
    if C.CV then C.CV.select(entry) else st.sel = entry end -- (with its card: Save pin, Share)
    st.pings = { { mx = entry.mx, my = entry.my, at = clock() } }
    return true
end

-------------------------------------------------------------------------------
-- Ways into the neighbouring zones
-------------------------------------------------------------------------------

-- exits.lua has each zone's ways out (where the server sets you down coming from the neighbour, which is just inside
-- the doorway). Which map of a zone with several one is on is the game's to say: exits.lua carries what it said when
-- the zones were visited, and one it hasn't got is asked of the game the first time you are in that zone, and kept.
local EXITS = require('exits')
local WAYS = { cache = {}, rev = 0, tried = {}, done = nil }
local function way_key(zone, e) return string.format('%d:%.1f:%.1f', zone, e[1], e[2]) end

-- a zone's ways out: { x, y, h, to, floor, zone, key, id }, floor nil while it isn't known
function C.ways(zone)
    local hit = WAYS.cache[zone]
    if hit and hit.rev == WAYS.rev then return hit.list end
    local z = DATA.zones[zone]
    local list = {}
    if z then
        for i, e in ipairs(EXITS[zone] or {}) do
            if DATA.zones[e[4]] then
                local key = way_key(zone, e)
                local floor = e[5]
                if floor == nil or z.by_floor[floor] == nil then floor = learned.data.exits[key] end
                if #z.floors == 1 then floor = z.floors[1].floor end
                if floor ~= nil and z.by_floor[floor] == nil then floor = nil end
                list[#list + 1] = { x = e[1], y = e[2], h = e[3], to = e[4], floor = floor, zone = zone, key = key, id = zone .. '/' .. i }
            end
        end
    end
    WAYS.cache[zone] = { rev = WAYS.rev, list = list }
    return list
end

-- In the zone you are in: the floor of one way out that isn't known yet, asked of the game (one a frame; the answer
-- is the collision's under that spot). Returns how many it has learnt this time round.
local function learn_ways(zone)
    local z = DATA.zones[zone]
    if z == nil or #z.floors < 2 or WAYS.done == zone then return 0 end
    for _, w in ipairs(C.ways(zone)) do
        if w.floor == nil and not WAYS.tried[w.key] then
            WAYS.tried[w.key] = true
            local f = DATA.floor_at(w.x, w.y, w.h)
            if f ~= nil and z.by_floor[f] ~= nil then
                learned.data.exits[w.key] = f
                WAYS.rev = WAYS.rev + 1
                WAYS.save = true
                return 1
            end
            return 0
        end
    end
    WAYS.done = zone
    if WAYS.save then WAYS.save = nil learned:save() end
    return 0
end
C.learn_ways = learn_ways

-- every way out of the zone you are in with its floor, as the game gives it now: { key = floor } (for the table the
-- addon ships: tools/vanamaps_exit_floors.json)
function C.ways_floors_here()
    local out = {}
    local ok, id, zone = pcall(vana.game.self)
    if not ok or id == nil or vana.game.zoning() then return out, nil end
    local z = DATA.zones[zone]
    for _, e in ipairs(EXITS[zone] or {}) do
        local f = DATA.floor_at(e[1], e[2], e[3])
        if f ~= nil and z and z.by_floor[f] ~= nil then out[way_key(zone, e)] = f end
    end
    return out, zone
end

-- Opens the neighbour a way leads to: its whole map, on the floor you would come out on, a ring spreading from each
-- place you could come out
function C.go_way(w)
    local out, floor = {}, nil
    for _, o in ipairs(C.ways(w.to)) do
        if o.to == w.zone then
            out[#out + 1] = o
            if floor == nil and o.floor ~= nil then floor = o.floor end
        end
    end
    if not C.show(w.to, floor, { follow = false }) then return false end
    local f = DATA.floor(w.to, st.floor)
    st.pings = {}
    for _, o in ipairs(out) do
        if o.floor == nil or o.floor == st.floor then
            local mx, my = DATA.to_map(f, o.x, o.y)
            st.pings[#st.pings + 1] = { mx = mx, my = my, at = clock() }
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- The key
-------------------------------------------------------------------------------

local KEYS = { capture = false, note = nil }
C.KEYS = KEYS

-- cfg.key is the key as /bind spells it, modifiers first ('m', '^m' for Ctrl+M, '!f5'); the bind adds '%': only while
-- the chat line is closed
local function split_key(key)
    key = tostring(key or ''):lower()
    local mods, name = key:match('^([%^!@#%+~]*)(.-)$')
    return mods or '', name or ''
end
local function spec_of(key) return '%' .. key end

function KEYS.label(key)
    local mods, name = split_key(key)
    if name == '' or name == 'none' then return 'No key' end
    local out = {}
    if mods:find('^', 1, true) then out[#out + 1] = 'Ctrl' end
    if mods:find('!', 1, true) then out[#out + 1] = 'Alt' end
    if mods:find('+', 1, true) or mods:find('~', 1, true) then out[#out + 1] = 'Shift' end
    if mods:find('@', 1, true) then out[#out + 1] = 'Win' end
    out[#out + 1] = name:upper()
    return table.concat(out, ' + ')
end

-- the two keys: the map's, and the bare map's
local SLOTS = { { id = 'main', cfg = 'key', cmd = '/vanamaps toggle' }, { id = 'bare', cfg = 'bare_key', cmd = '/vanamaps bare' } }
KEYS.bound, KEYS.notes = {}, {}

function KEYS.unbind()
    for _, key in pairs(KEYS.bound) do pcall(vana.binds.remove, spec_of(key)) end
    KEYS.bound = {}
end

function KEYS.bind()
    KEYS.unbind()
    KEYS.notes = {}
    local ok, list = pcall(vana.binds.list)
    for _, slot in ipairs(SLOTS) do
        local key = tostring(cfg[slot.cfg] or ''):lower()
        local mods, name = split_key(key)
        if name ~= '' and name ~= 'none' then
            local note = nil
            -- a key the player (or another addon) already gave a job keeps it
            if ok and type(list) == 'table' then
                local ctrl, alt, shift = mods:find('^', 1, true) ~= nil, mods:find('!', 1, true) ~= nil, (mods:find('+', 1, true) or mods:find('~', 1, true)) ~= nil
                for _, b in ipairs(list) do
                    local same = (b.ctrl == true) == ctrl and (b.alt == true) == alt and (b.shift == true) == shift and not b.win and not b.apps
                    if same and tostring(b.key):lower() == name and not tostring(b.command):find('/vanamaps', 1, true) then
                        note = KEYS.label(key) .. ' already runs ' .. tostring(b.command)
                    end
                end
            end
            for _, other in pairs(KEYS.bound) do
                if other == key then note = KEYS.label(key) .. ' is the other key already' end
            end
            if note == nil then
                local made, why = vana.binds.add(spec_of(key), slot.cmd)
                if made then KEYS.bound[slot.id] = key else note = tostring(why) end
            end
            KEYS.notes[slot.id] = note
        end
    end
    KEYS.note = KEYS.notes.main
end

-- While one of our text boxes has the keyboard, the keys type their letter instead of closing the map
function KEYS.frame()
    local typing = G.typing()
    if typing and next(KEYS.bound) ~= nil then
        KEYS.held = true
        KEYS.unbind()
    elseif not typing and KEYS.held then
        KEYS.held = nil
        KEYS.bind()
    end
end

-- A keyboard that types straight into the chat line (the game's full-keyboard layout: any letter opens the line with
-- that letter in it) would lose the letter M to a bare M bind. It can't be asked of the game, so it is watched for:
-- when plain letters keep opening the chat line (four different ones: a compact keyboard has only a shortcut or two
-- that do), the map's key becomes Ctrl+M, once, and the player is told. A key the player then picks is theirs.
local LAYOUT = { at = -1, letter = 0, seen = {}, count = 0 }
local ffi_ok, ffi = pcall(require, 'ffi')
if ffi_ok then pcall(ffi.cdef, 'short __stdcall GetKeyState(int key);') end
local function modifier_down()
    if not ffi_ok then return false end
    local ok, down = pcall(function ()
        local u = ffi.load('user32')
        return u.GetKeyState(0x11) < 0 or u.GetKeyState(0x12) < 0 or u.GetKeyState(0x5B) < 0
    end)
    return ok and down
end

vana.events.on('key', function (wparam, lparam, blocked)
    if cfg.layout_checked or blocked or wparam < 0x41 or wparam > 0x5A then return end
    if lparam < 0 or lparam >= 0x80000000 then return end -- a release
    -- only a letter on its own, or with Shift (a capital), can swallow typing
    local risky = false
    for _, field in ipairs({ 'key', 'bare_key' }) do
        local mods, name = split_key(cfg[field])
        if #name == 1 and not mods:find('[%^!@#]') then risky = true end
    end
    if not risky then return end
    local okw, world = pcall(vana.game.world)
    if okw and world and world.chat_open then return end
    if modifier_down() then return end
    LAYOUT.at, LAYOUT.letter = clock(), wparam
end)

vana.events.on('chat_input_open', function ()
    if cfg.layout_checked or clock() - LAYOUT.at > 0.15 then return end
    LAYOUT.at = -1
    if not LAYOUT.seen[LAYOUT.letter] then
        LAYOUT.seen[LAYOUT.letter] = true
        LAYOUT.count = LAYOUT.count + 1
    end
    if LAYOUT.count >= 4 then
        local was = KEYS.label(cfg.key)
        cfg.layout_checked = true
        for _, field in ipairs({ 'key', 'bare_key' }) do
            local mods, name = split_key(cfg[field])
            if #name == 1 and not mods:find('[%^!@#]') then cfg[field] = '^' .. mods .. name end
        end
        KEYS.bind()
        config:save()
        U.toast('accent', 'VanaMaps: the key is ' .. KEYS.label(cfg.key) .. ' now', 'Your keyboard types into chat, so ' .. was .. ' alone would swallow the letter', 9, 'circle-info')
        say('your keyboard types straight into the chat line, so the map now opens with ' .. KEYS.label(cfg.key) .. ' instead of ' .. was ..
            ' alone (change it in /vmap settings)')
    end
end)

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local W = { min_w = 760, min_h = 520 }

local function auto_scale()
    local _, sh = vana.ui.screen()
    return math.max(60, math.min(250, math.floor((sh or 1080) / 1080 * 100 / 5 + 0.5) * 5))
end
C.auto_scale = auto_scale

local function scale_now()
    return (cfg.scale and cfg.scale > 0) and cfg.scale or auto_scale()
end

local function draw_header(dl, x, y, w, t)
    local h = S(74)
    U.aurora(dl, x, y, w, h, t, S(16))
    -- the badge: a compass, its needle swinging to your heading
    local bx, by, br = x + S(42), y + S(37), S(22)
    for i = 3, 1, -1 do dl:AddCircleFilled({ bx, by }, br + S(3) * i, U.u32(P.accent, 0.05), 32) end
    dl:AddCircleFilled({ bx, by }, br, U.u32(U.mix(P.accent, P.ink, 0.72)), 32)
    dl:AddCircle({ bx, by }, br, U.u32(P.cyan, 0.9), 32, S(1.5))
    local a = (C.me.ok and C.me.heading or 0) + math.sin(t * 1.3) * 0.04
    local c, s = math.cos(a), math.sin(a)
    local function pt(px, py) return { bx + px * c - py * s, by + px * s + py * c } end
    dl:AddTriangleFilled(pt(br * 0.72, 0), pt(0, br * 0.24), pt(0, -br * 0.24), U.u32('#FF6B6B'))
    dl:AddTriangleFilled(pt(-br * 0.72, 0), pt(0, br * 0.24), pt(0, -br * 0.24), U.u32('#F1F3F9'))
    dl:AddCircleFilled({ bx, by }, S(2.5), U.u32(P.ink), 12)

    local zone = st.zone
    local name = zone and C.zone_name(zone) or 'VanaMaps'
    local right = x + w - S(22) - (S(32) + S(4)) * 7
    local title = U.fit(name:upper(), F.dispb, T.title, right - (x + S(78)) - S(8))
    U.gradient_text(dl, x + S(78), y + S(9), title, P.cyan, P.accent2, F.dispb, T.title)
    -- under the name: the region, the zone's floors (a button each, or a drop-down), and whether you are there
    if zone then
        local sx, cy = x + S(80), y + S(54)
        local region = C.region_name(zone) or 'Uncharted'
        U.text_mid(dl, sx, cy, region, P.dim, F.text, T.small)
        sx = sx + U.measure(region, F.text, T.small) + S(14)
        local z = DATA.zones[zone]
        if z and #z.floors > 1 and C.CV then
            local label = 'Map'
            U.text_mid(dl, sx, cy, label, P.faint, F.text, T.small)
            sx = sx + U.measure(label, F.text, T.small) + S(8)
            sx = sx + C.CV.floor_control(dl, sx, cy) + S(14)
        end
        if C.me.ok and C.me.zone == zone then
            local here = 'You are here'
            if sx + U.measure(here, F.text, T.small) + S(14) < right then
                dl:AddCircleFilled({ sx + S(3), cy }, S(3), U.u32(P.cyan), 12)
                U.text_mid(dl, sx + S(12), cy, here, P.dim, F.text, T.small)
            end
        end
    end
    local pulse = 0.55 + 0.45 * math.sin(t * 2)
    dl:AddRectFilledMultiColor({ x + S(16), y + h - 1 }, { x + w - S(16), y + h + 1 }, U.u32(P.cyan, 0), U.u32(P.cyan, 0.9 * pulse),
        U.u32(P.accent2, 0.9 * pulse), U.u32(P.accent, 0))

    local size = S(32)
    local ix, iy = x + w - S(22) - size, y + S(20)
    if G.icon_button(dl, '##vm_close', ix, iy, size, G.CP.xmark, P.dim, 'Close (Esc)') then C.open(false) end
    ix = ix - size - S(4)
    if G.icon_button(dl, '##vm_settings', ix, iy, size, G.CP.gear, st.settings_open and P.accent or P.dim, 'Settings', st.settings_open) then
        st.settings_open = not st.settings_open
    end
    ix = ix - size - S(4)
    if G.icon_button(dl, '##vm_side', ix, iy, size, G.CP.bars, cfg.sidebar and P.accent or P.dim, 'Zones, pins and shared pins', cfg.sidebar) then
        cfg.sidebar = not cfg.sidebar
        cfg.w = cfg.w + (cfg.sidebar and 298 or -298) -- the map keeps its size: the window grows by the lists' width
        st.settings_open = false
    end
    ix = ix - size - S(4)
    local unseen = 0
    for _, e in ipairs(C.shared()) do if not e.seen then unseen = unseen + 1 end end
    if G.icon_button(dl, '##vm_inbox', ix, iy, size, G.CP.inbox, unseen > 0 and '#FFD166' or P.dim, 'Pins shared with you') then
        cfg.sidebar, cfg.side_tab, st.settings_open = true, 'shared', false
    end
    if unseen > 0 then
        dl:AddCircleFilled({ ix + size - S(5), iy + S(5) }, S(7), U.u32('#FFD166'), 16)
        U.text_center(dl, ix + size - S(12), iy + S(5), S(14), tostring(unseen), P.ink, F.bold, T.tiny - 1)
    end
    ix = ix - size - S(4)
    local here = C.me.ok and st.zone == C.me.zone and st.floor == C.me.floor and st.follow
    if G.icon_button(dl, '##vm_here', ix, iy, size, G.CP.locate, here and P.ok or P.dim, 'Where am I?', here) then
        st.settings_open = false
        C.here()
    end
    ix = ix - size - S(4)
    local fwd = st.history[st.hist_i + 1] ~= nil
    if G.icon_button(dl, '##vm_fwd', ix, iy, size, G.CP.forward, fwd and P.text or P.faint, fwd and 'Forward' or nil) and fwd then C.step_history(1) end
    ix = ix - size - S(4)
    local back = st.history[st.hist_i - 1] ~= nil
    if G.icon_button(dl, '##vm_back', ix, iy, size, G.CP.back, back and P.text or P.faint, back and 'Back' or nil) and back then C.step_history(-1) end
    return h
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

local SET = { scale_edit = nil }

local function settings_body(dl, x, y, w, h, t)
    U.panel(dl, x, y, w, h, P.glass, 1, S(12), P.line)
    local changed = false
    local cx, cy = x + S(24), y + S(22)
    local col = (w - S(72)) / 2
    local rx = cx + col + S(24)

    -- left: the look
    local ly = U.section(dl, cx, cy, col, 'LOOK', 'sliders')
    U.text_mid(dl, cx, ly + S(14), 'Theme', P.dim, F.text, T.small)
    local themes = {}
    for _, th in ipairs(U.THEMES) do themes[#themes + 1] = { id = th.id, name = th.name } end
    local pick = U.dropdown(dl, '##vm_theme', cx + S(110), ly + S(14), col - S(110), themes, cfg.theme)
    if pick ~= cfg.theme then cfg.theme = pick U.apply_theme(pick) changed = true end
    ly = ly + S(42)
    U.text_mid(dl, cx, ly + S(12), 'Size', P.dim, F.text, T.small)
    local auto = cfg.scale == 0
    local shown = SET.scale_edit or scale_now()
    local v, moved, released = U.slider(dl, '##vm_scale', cx + S(110), ly + S(12), col - S(110) - S(120), shown, 50, 250, '%.0f%%')
    if moved then SET.scale_edit = math.floor(v / 5 + 0.5) * 5 end
    if released and SET.scale_edit then cfg.scale = SET.scale_edit SET.scale_edit = nil changed = true end
    local on = U.toggle(dl, '##vm_auto', cx + col - S(64), ly + S(12), 'Auto', auto)
    if on ~= auto then cfg.scale = on and 0 or scale_now() changed = true end
    ly = ly + S(38)
    U.text_mid(dl, cx, ly + S(12), 'Opacity', P.dim, F.text, T.small)
    local ov, omoved = U.slider(dl, '##vm_opacity', cx + S(110), ly + S(12), col - S(110) - S(56), cfg.opacity, 40, 100, '%.0f%%')
    if omoved then cfg.opacity = math.floor(ov + 0.5) changed = true end
    ly = ly + S(38)
    U.text_mid(dl, cx, ly + S(12), 'Pins', P.dim, F.text, T.small)
    local pv, pmoved = U.slider(dl, '##vm_pinsize', cx + S(110), ly + S(12), col - S(110) - S(56), cfg.pin_size, 60, 200, '%.0f%%')
    if pmoved then cfg.pin_size = math.floor(pv / 5 + 0.5) * 5 changed = true end
    ly = ly + S(44)

    ly = U.section(dl, cx, ly, col, 'MAPS', 'layer-group')
    local packs = DATA.packs()
    local opts = { { 2048, 'Best' }, { 1024, '1024' }, { 0, "Game's own" } }
    local q, _, clicked = U.segments(dl, '##vm_quality', cx, ly + S(2), S(30), opts, cfg.quality)
    if clicked ~= nil then cfg.quality = q TEX.release_all() changed = true end
    ly = ly + S(42)
    local have = #packs > 0 and ('Map pack found: ' .. table.concat(packs, ' and ') .. ' px') or 'No map pack: the game\'s own maps are shown'
    U.text(dl, cx, ly, have, #packs > 0 and P.ok or P.warn, F.text, T.tiny)
    ly = ly + S(18)
    for _, line in ipairs(U.wrap('The HD maps are the XICombinedMaps pack (RadialArcana, the FFXI Remapster Project, Moops\' Remapster Labeled), ' ..
        'installed by the launcher\'s Combined Maps. VanaMaps reads them from your own files.', F.text, T.tiny, col)) do
        U.text(dl, cx, ly, line, P.faint, F.text, T.tiny)
        ly = ly + S(15)
    end

    ly = ly + S(10)
    ly = U.section(dl, cx, ly, col, 'WHILE YOU MOVE', 'eye')
    U.text_mid(dl, cx, ly + S(12), 'The map fades to', P.dim, F.text, T.small)
    local mv, mmoved = U.slider(dl, '##vm_move', cx + S(130), ly + S(12), col - S(130) - S(56), cfg.move_alpha, 10, 100, '%.0f%%')
    if mmoved then cfg.move_alpha = math.floor(mv / 5 + 0.5) * 5 changed = true end
    ly = ly + S(32)
    local pass = U.toggle(dl, '##vm_pass', cx, ly + S(12), 'and lets clicks and camera drags through', cfg.move_pass)
    if pass ~= cfg.move_pass then cfg.move_pass = pass changed = true end
    ly = ly + S(30)

    -- right: the map's behaviour
    local ry = U.section(dl, rx, cy, col, 'ON THE MAP', 'location-dot')
    local function tog(key, label, field)
        local val = U.toggle(dl, key, rx, ry + S(12), label, cfg[field])
        if val ~= cfg[field] then cfg[field] = val changed = true end
        ry = ry + S(32)
    end
    tog('##vm_follow', 'Follow me when the map opens', 'follow')
    tog('##vm_party', 'Party and alliance members', 'party')
    tog('##vm_names', 'Their names', 'names')
    tog('##vm_target', 'My target', 'target')
    tog('##vm_rulers', 'Grid letters and numbers along the edges', 'rulers')
    tog('##vm_exits', 'Ways into neighbouring zones (click one to open its map)', 'exits')
    ry = ry + S(8)
    ry = U.section(dl, rx, ry, col, 'SHARED PINS', 'paper-plane')
    tog('##vm_cards', 'A card when someone shares a pin', 'cards')
    ry = ry + S(8)

    ry = U.section(dl, rx, ry, col, 'KEY AND CONTROLLER', 'gamepad')
    local function key_row(slot, field, label)
        U.text_mid(dl, rx, ry + S(15), label, P.dim, F.text, T.small)
        local capturing = KEYS.capture == slot
        local shown = capturing and 'Press a key…' or KEYS.label(cfg[field])
        if U.button(dl, '##vm_key_' .. slot, rx + S(150), ry, S(150), S(30), shown, capturing and '#FFD166' or P.accent, 'ghost', nil, F.semi, T.small) then
            if KEYS.capture then
                vana.binds.capture_end()
                KEYS.capture = false
                KEYS.bind()
            else
                KEYS.unbind()
                vana.binds.capture_begin()
                KEYS.capture = slot
            end
        end
        if U.button(dl, '##vm_nokey_' .. slot, rx + S(308), ry, S(64), S(30), 'None', P.dim, 'ghost', nil, F.semi, T.small) then
            if KEYS.capture then vana.binds.capture_end() KEYS.capture = false end
            cfg[field] = 'none'
            cfg.layout_checked = true
            KEYS.bind()
            changed = true
        end
        if capturing then
            local cap = vana.binds.capture()
            if cap and cap.done and cap.key then
                vana.binds.capture_end()
                KEYS.capture = false
                cfg[field] = (cap.ctrl and '^' or '') .. (cap.alt and '!' or '') .. (cap.shift and '+' or '') .. tostring(cap.key):lower()
                cfg.layout_checked = true -- (the player's own pick stands)
                KEYS.bind()
                changed = true
            elseif cap and (cap.cancelled or not cap.active) then
                vana.binds.capture_end()
                KEYS.capture = false
                KEYS.bind()
            end
        end
        ry = ry + S(36)
        if KEYS.notes[slot] then
            U.text(dl, rx, ry - S(2), 'Not bound: ' .. KEYS.notes[slot], P.warn, F.text, T.tiny)
            ry = ry + S(18)
        end
    end
    key_row('main', 'key', 'The map')
    key_row('bare', 'bare_key', 'The bare map')
    U.text(dl, rx, ry, 'Only while the chat line is closed. /vmap and /vmap bare open them too.', P.faint, F.text, T.tiny)
    ry = ry + S(24)
    local pad_on = PAD.enabled()
    local pv2 = U.toggle(dl, '##vm_pad', rx, ry + S(12), 'Controller in addon windows', pad_on)
    if pv2 ~= pad_on then PAD.set_enabled(pv2) end

    -- how the map is worked, across the bottom
    local hy = math.max(ly, ry) + S(18)
    if hy + S(185) < y + h - S(46) then
        hy = U.section(dl, cx, hy, w - S(48), 'HOW IT WORKS', 'circle-info')
        local tips = {
            { 'Drag', 'moves the map' }, { 'Wheel', 'zooms about the pointer' }, { 'Double-click', 'centres there and zooms in' },
            { 'Right-click', 'a menu: pin here, share this spot, centre' }, { 'Click a pin', 'its card: title, note, icon, colour, share' },
            { 'Click a signpost', 'opens the neighbouring zone\'s map; the crosshair finds you again' },
            { 'Left stick', 'the pointer; the right stick moves the map' }, { 'Triggers', 'zoom; the bumpers change floors' },
            { 'Confirm', 'drops a pin, or opens the one under the pointer' }, { 'Options', 'the lists: zones, pins, shared pins' },
            { '/vmap share p', 'the selected pin (or where you stand) to party chat' },
            { KEYS.label(cfg.bare_key), 'the bare map: the map alone, following you' },
            { 'Shift + drag', 'moves the bare map; Shift + wheel sizes it' },
        }
        local half = math.ceil(#tips / 2)
        for i, tip in ipairs(tips) do
            local tx = i <= half and cx or rx
            local ty = hy + ((i - 1) % half) * S(22)
            U.text(dl, tx, ty, tip[1], P.text, F.semi, T.small)
            U.text(dl, tx + S(128), ty, tip[2], P.dim, F.text, T.small)
        end
    end

    -- the foot
    local fy = y + h - S(46)
    dl:AddLine({ x + S(20), fy }, { x + w - S(20), fy }, U.u32(P.line), 1)
    U.text_mid(dl, x + S(24), fy + S(23), 'VanaMaps ' .. addon.version .. '   ·   /vmap help lists the commands', P.faint, F.text, T.tiny)
    if U.button(dl, '##vm_defaults', x + w - S(24) - S(116), fy + S(10), S(116), S(26), 'Defaults', P.dim, 'ghost', 'rotate-right', F.semi, T.tiny) then
        for k, val in pairs(DEFAULTS) do
            if k ~= 'last' and k ~= 'collapsed' and k ~= 'sidebar' and k ~= 'side_tab' and k ~= 'layout_checked' and k ~= 'bare_tip' then cfg[k] = val end
        end
        U.apply_theme(cfg.theme)
        TEX.release_all()
        KEYS.bind()
        changed = true
    end
    if changed then config:save() end
end

-------------------------------------------------------------------------------
-- The controller
-------------------------------------------------------------------------------

local LEGEND = {
    map = { { 'lstick', 'Pointer' }, { 'rstick', 'Map' }, { 'l2 r2', 'Zoom' }, { 'confirm', 'Pin' }, { 'l1 r1', 'Floor' }, { 'menu', 'Where am I' },
        { 'options', 'Lists' }, { 'cancel', 'Close' } },
    list = { { 'updown', 'Move' }, { 'confirm', 'Open' }, { 'l1 r1', 'Tab' }, { 'options', 'Map' }, { 'cancel', 'Back' } },
    card = { { 'updown left right', 'Move' }, { 'confirm', 'Choose' }, { 'cancel', 'Done' } },
}

local function draw_legend(dl, x, y, w)
    local items = LEGEND[st.pad_mode] or LEGEND.map
    local lw = PAD.legend(dl, -10000, -10000, items, 0)
    PAD.legend(dl, x + (w - lw) / 2, y + S(14), items, 1)
end

local function pad_buttons()
    if st.pad_mode == 'map' then
        if PAD.pressed('options') then
            cfg.sidebar = true
            st.pad_mode, st.pad_seat = 'list', true
        end
        if PAD.pressed('menu') then C.here() end
        if PAD.pressed('cancel') then
            if st.sel then st.sel = nil elseif st.settings_open then st.settings_open = false else C.open(false) end
        end
        if PAD.pressed('start') then st.settings_open = not st.settings_open end
    elseif st.pad_mode == 'list' then
        if PAD.pressed('options') or PAD.pressed('cancel') then st.pad_mode = 'map' end
        local turn = (PAD.pressed('r1') and 1 or 0) - (PAD.pressed('l1') and 1 or 0)
        if turn ~= 0 and C.SB then C.SB.turn(turn) end
    elseif st.pad_mode == 'card' then
        if PAD.pressed('cancel') then
            st.pad_mode = 'map'
            C.CV.close_card()
        end
    end
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

-- How solid the map is drawn this frame, and whether the mouse goes through it. While you move it fades to the
-- strength set (eased both ways) so the world shows behind it; what's on the map (your arrow, pins, the party) stays
-- nearly solid (C.mark_alpha). Clicks go through only once it has faded, and never in the middle of a drag of ours.
function C.fade_now(fade)
    local base = fade * math.max(0.4, math.min(1, (cfg.opacity or 100) / 100))
    local f = U.ease(st.move_f or 0)
    local alpha = base * U.lerp(1, math.max(0.1, math.min(1, (cfg.move_alpha or 40) / 100)), f)
    C.alpha, C.win_alpha = fade, alpha
    C.mark_alpha = math.max(alpha, fade * U.lerp(1, 0.92, f))
    C.pass = cfg.move_pass and (cfg.move_alpha or 40) < 100 and (st.move_f or 0) > 0.5 and not (C.CV and C.CV.busy())
    return alpha, C.pass
end

-- The bare map: the map alone on the screen, no window round it, no lists. A square, a share of the screen's height
-- across, where it was last put.
local function draw_bare(t, dt)
    local sw, sh = vana.ui.screen()
    cfg.bare_size = math.max(30, math.min(100, cfg.bare_size or 82))
    -- (room is kept above and below the picture for its strips: the floors over it, the controls under it)
    local strip = math.floor(S(40))
    local side = math.floor(math.min(sw, sh - strip * 2 - 8) * cfg.bare_size / 100)
    side = math.min(side, sh - strip * 2 - 8)
    local x = math.floor(math.max(0, math.min(sw - side, sw * (cfg.bare_x or 0.5) - side / 2)))
    local y = math.floor(math.max(strip + 4, math.min(sh - side - strip - 4, sh * (cfg.bare_y or 0.5) - side / 2)))
    imgui.SetNextWindowPos({ x, y - strip }, U.ALWAYS)
    imgui.SetNextWindowSize({ side, side + strip * 2 }, U.ALWAYS)
    local fade = U.ease(st.anim)
    local alpha, pass = C.fade_now(fade)
    U.set_window_alpha(alpha)
    U.push_theme()
    if imgui.Begin('##vanamaps_bare', nil, U.WINDOW_FLAGS + U.NO_SAVE + (pass and 512 or 0)) then
        local drew, err = pcall(function ()
            local dl = imgui.GetWindowDrawList()
            st.pad_focused = false
            C.pad_on = false -- (the controller stays the game's: the bare map is for walking by)
            C.CV.draw(dl, x, y, side, side, t, dt, true)
            -- its controls, off the picture and only while the pointer is here: the floors over the top edge, the rest
            -- under the bottom edge, each on a dark bar so it reads over the world behind
            local a = C.CV.ui_alpha(x, y - strip, side, side + strip * 2, dt)
            if a > 0.03 then
                U.set_window_alpha(alpha * a)
                local z = DATA.zones[st.zone or -1]
                if z and #z.floors > 1 then
                    local fw = (#z.floors > 6) and S(190) or (#z.floors * S(33) - S(3))
                    local bw2, bh2 = fw + S(64), S(34)
                    local bx2, by2 = x, y - bh2 - S(4)
                    dl:AddRectFilled({ bx2, by2 }, { bx2 + bw2, by2 + bh2 }, U.u32(P.bg, 0.9), S(10))
                    dl:AddRect({ bx2, by2 }, { bx2 + bw2, by2 + bh2 }, U.u32(P.line, 0.9), S(10), 15, 1)
                    U.text_mid(dl, bx2 + S(12), by2 + bh2 / 2, 'Map', P.dim, F.text, T.small)
                    C.CV.floor_control(dl, bx2 + S(48), by2 + bh2 / 2)
                end
                local ty, th = y + side + S(4), S(34)
                dl:AddRectFilled({ x, ty }, { x + side, ty + th }, U.u32(P.bg, 0.9), S(10))
                dl:AddRect({ x, ty }, { x + side, ty + th }, U.u32(P.line, 0.9), S(10), 15, 1)
                C.CV.toolbar(dl, x + S(8), ty + S(2), side - S(16), th - S(4), true)
                U.set_window_alpha(alpha)
            end
        end)
        if not drew then
            fail('bare map', err)
            st.errors = (st.errors or 0) + 1
            if st.errors > 30 then
                st.open = false
                say('the map had a problem and was closed; see logs\\vanacore.log')
            end
        end
    end
    imgui.End()
    U.pop_theme()
    U.set_window_alpha(1)
end

local function draw_main(t, dt)
    local sw, sh = vana.ui.screen()
    local legend_h = (PAD.shown() and st.pad_focused) and S(28) or 0
    cfg.w = math.max(W.min_w, math.min(cfg.w, sw / U.scale() - 8))
    cfg.h = math.max(W.min_h, math.min(cfg.h, sh / U.scale() - 8 - legend_h / U.scale()))
    local w, h = math.floor(S(cfg.w)), math.floor(S(cfg.h) + legend_h)
    imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
    imgui.SetNextWindowPos({ math.floor((sw - w) / 2), math.floor((sh - h) / 2) }, U.FIRST_USE_EVER)
    if st.focus_frames and st.focus_frames > 0 then
        imgui.SetNextWindowFocus()
        st.focus_frames = st.focus_frames - 1
    end
    local fade = U.ease(st.anim)
    local alpha, pass = C.fade_now(fade)
    U.set_window_alpha(alpha)
    U.push_theme()
    -- (512: no mouse input, while you move: your clicks and camera drags are the game's)
    if imgui.Begin('##vanamaps', nil, U.WINDOW_FLAGS + (pass and 512 or 0)) then
        -- drawn under pcall so an error can't skip End and the theme's pop
        local drew, err = pcall(function ()
            local dl = imgui.GetWindowDrawList()
            local x, y = imgui.GetWindowPos()
            local kx, ky = math.max(0, math.min(x, sw - w)), math.max(0, math.min(y, sh - h))
            if (kx ~= x or ky ~= y) and not imgui.IsMouseDown(0) then imgui.SetWindowPos({ kx, ky }) end
            y = y + (1 - fade) * S(14)
            local mg = S(40)
            dl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
            U.shadow(dl, x, y, w, h, S(16), fade)
            dl:PopClipRect()
            U.panel(dl, x, y, w, h, P.bg, 1, S(16), P.line)
            st.pad_focused = imgui.IsWindowFocused(3)
            C.pad_on = PAD.capturing() and st.pad_focused
            if C.pad_on then
                pad_buttons()
                PAD.claim()
                if st.pad_mode == 'map' and imgui.Shortcut then
                    -- Confirm and Cancel are the map's while the pointer is on it, not ImGui's "press the focused thing"
                    pcall(imgui.Shortcut, 637, 4096)
                    pcall(imgui.Shortcut, 635, 4096)
                end
            end
            if PAD.shown() and st.pad_focused and st.pad_mode ~= 'map' and imgui.SetNavCursorVisible then imgui.SetNavCursorVisible(true) end
            -- the header's buttons are the mouse's: the controller has buttons of its own for them
            local no_nav = C.pad_on and imgui.PushItemFlag ~= nil
            if no_nav then imgui.PushItemFlag(2, true) end
            local hy = draw_header(dl, x, y, w, t)
            if no_nav then imgui.PopItemFlag() end
            local by = y + hy + S(12)
            local bh = y + h - by - S(16) - legend_h
            local bx, bw = x + S(16), w - S(32)
            if legend_h > 0 then draw_legend(dl, x, y + h - legend_h - S(4), w) end
            if st.settings_open then
                settings_body(dl, bx, by, bw, bh, t)
            else
                if cfg.sidebar then
                    local sbw = S(286)
                    C.SB.draw(dl, bx, by, sbw, bh, t, dt)
                    bx, bw = bx + sbw + S(12), bw - sbw - S(12)
                end
                local strip = S(30)
                C.CV.draw(dl, bx, by, bw, bh - strip - S(6), t, dt, false)
                if no_nav then imgui.PushItemFlag(2, true) end
                C.CV.toolbar(dl, bx, by + bh - strip, bw, strip, false)
                if no_nav then imgui.PopItemFlag() end
            end
            -- the corner that sizes the window
            local gs = S(18)
            imgui.SetCursorScreenPos({ x + w - gs, y + h - gs })
            imgui.InvisibleButton('##vm_grip', { gs, gs })
            local hot = imgui.IsItemHovered() or imgui.IsItemActive()
            if hot then imgui.SetMouseCursor(6) end
            if imgui.IsItemActive() then
                local mx, my = imgui.GetMousePos()
                cfg.w = math.max(W.min_w, (mx - x + S(4)) / U.scale())
                cfg.h = math.max(W.min_h, (my - y + S(4) - legend_h) / U.scale())
            end
            for i = 1, 3 do
                local o = S(4) * i
                dl:AddLine({ x + w - S(5), y + h - S(5) - o }, { x + w - S(5) - o, y + h - S(5) }, U.u32(hot and P.accent or P.dim, hot and 0.9 or 0.5), 1)
            end
            if imgui.IsItemDeactivated() then config:save() end
            if imgui.IsWindowFocused(3) and imgui.IsKeyPressed(U.KEY_ESCAPE) and not G.typing() and not KEYS.capture then
                if st.sel then st.sel = nil elseif st.settings_open then st.settings_open = false else C.open(false) end
            end
        end)
        if not drew then
            fail('window', err)
            st.errors = (st.errors or 0) + 1
            if st.errors > 30 then
                st.open = false
                say('the map window had a problem and was closed; see logs\\vanacore.log')
            end
        end
    end
    imgui.End()
    U.pop_theme()
    U.set_window_alpha(1)
end

-- The cards for pins that came through chat: a small window of their own by the screen's right edge, so they can be
-- clicked whether or not the map is open
local function draw_cards(t, dt)
    local now = clock()
    for i = #st.cards, 1, -1 do
        if now - st.cards[i].at > 14 or st.cards[i].gone then table.remove(st.cards, i) end
    end
    if #st.cards == 0 then return end
    local sw, sh = vana.ui.screen()
    local w, ch = S(340), S(86)
    local h = (#st.cards) * (ch + S(10))
    local x, y = sw - w - S(24), math.floor(sh * 0.30)
    imgui.SetNextWindowPos({ x - S(10), y - S(10) }, U.ALWAYS)
    imgui.SetNextWindowSize({ w + S(20), h + S(20) }, U.ALWAYS)
    U.push_theme()
    if imgui.Begin('##vanamaps_cards', nil, U.WINDOW_FLAGS + U.NO_SAVE + U.NO_FOCUS) then
        local ok, err = pcall(function ()
            local dl = imgui.GetWindowDrawList()
            local mg = S(40)
            dl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
            local cy = y
            for i, card in ipairs(st.cards) do
                local e = card.entry
                local age = now - card.at
                local a = U.ease(math.min(1, age * 4)) * (age > 13 and math.max(0, 14 - age) or 1)
                local cx = x + (1 - U.ease(math.min(1, age * 4))) * S(60)
                local color = K.COLORS[e.color] or K.COLORS[1]
                U.shadow(dl, cx, cy, w, ch, S(14), a)
                U.panel(dl, cx, cy, w, ch, P.glass, 0.97 * a, S(14), U.mix(color, P.line, 0.3), true)
                G.pin(dl, cx + S(32), cy + S(58), S(13), (K.ICON_BY_ID[e.icon] or K.ICONS[1]).cp, color, 1, a, false, t)
                local who = (e.from ~= '' and e.from or 'Someone') .. ' shared a pin'
                U.text(dl, cx + S(60), cy + S(10), U.fit(who, F.disp, T.h2, w - S(100)), color, F.disp, T.h2, a)
                local where = C.zone_name(e.zone) .. ' (' .. C.square(e) .. ')'
                if e.title ~= '' then where = e.title .. '  ·  ' .. where end
                U.text(dl, cx + S(60), cy + S(34), U.fit(where, F.text, T.small, w - S(76)), P.dim, F.text, T.small, a)
                if U.button(dl, '##vm_card_open' .. i, cx + S(60), cy + S(54), S(112), S(24), 'Open map', color, 'ghost', nil, F.semi, T.tiny) then
                    card.gone = true
                    C.open_shared(e)
                    st.focus_frames = 2
                end
                imgui.SetCursorScreenPos({ cx + w - S(30), cy + S(6) })
                local closed, _, hv = U.hit('##vm_card_x' .. i, S(24), S(24), S(12))
                G.icon(dl, cx + w - S(18), cy + S(18), G.CP.xmark, U.mix(P.dim, P.text, hv), T.small, a)
                if closed then card.gone = true end
                local left = math.max(0, 1 - age / 14)
                dl:AddRectFilled({ cx + S(14), cy + ch - S(3) }, { cx + S(14) + (w - S(28)) * left, cy + ch - S(1) }, U.u32(color, 0.5 * a), S(1))
                cy = cy + ch + S(10)
            end
            dl:PopClipRect()
        end)
        if not ok then fail('cards', err) st.cards = {} end
    end
    imgui.End()
    U.pop_theme()
end

vana.events.on('present', function ()
    local t = imgui.GetTime()
    local dt = math.max(0.001, math.min(0.1, imgui.GetIO().DeltaTime or 0.016))
    st.anim = U.lerp(st.anim, st.open and 1 or 0, math.min(1, dt * (st.open and 9 or 14)))
    if st.anim < 0.02 and not st.open then st.anim = 0 end
    local busy = st.open or st.anim > 0 or #st.cards > 0 or #U.anim.toasts > 0
    if not busy then
        -- nothing of ours on the screen: the textures go after a while, and nothing else is done
        if st.idle_since == nil then st.idle_since = t end
        if st.idle_since and t - st.idle_since > 45 and TEX.bytes > 0 then TEX.release_all() end
        return
    end
    st.idle_since = nil
    local started = clock()
    st.kit = U.frame(dt, scale_now() / 100, t)
    if not st.kit then return end
    -- (the bare map leaves the controller to the game: it's for walking by)
    PAD.frame(t, { id = 'vanamaps', capture = function () return st.open and not st.bare end, hold = (st.open and st.pad_mode == 'map') and 'all' or false })
    U.anim.pad_shown = PAD.shown()
    G.no_tips = PAD.shown() -- (a hint by the mouse's pointer says nothing of what the controller is on)
    KEYS.frame()
    local ok, err = pcall(track, t)
    if not ok then fail('track', err) end
    if st.open or st.anim > 0 then
        if st.open and C.me.ok and st.follow and (C.me.zone ~= st.zone or C.me.floor ~= st.floor) and DATA.zones[C.me.zone] then
            -- following you onto another floor, or into another zone
            C.here()
        end
        local moving = st.open and C.me.ok and C.me.moving
        st.move_f = U.lerp(st.move_f or 0, moving and 1 or 0, math.min(1, dt * (moving and 6 or 4)))
        if st.move_f < 0.01 then st.move_f = 0 end
        if st.bare then draw_bare(t, dt) else draw_main(t, dt) end
    end
    draw_cards(t, dt)
    pcall(G.draw_tip, dt)
    local okt, errt = pcall(U.draw_toasts, t)
    if not okt then fail('toasts', errt) end
    -- what a frame of the map costs (/vmap stats)
    local ms = (clock() - started) * 1000
    st.cost = st.cost and (st.cost + (ms - st.cost) * 0.05) or ms
    st.cost_max = math.max((st.cost_max or 0) * 0.995, ms)
end)

-------------------------------------------------------------------------------
-- Chat: pins coming in
-------------------------------------------------------------------------------

-- The chat packet (0x017): its kind at 0x04, the sender's name at 0x08 (15 bytes), the line from 0x17. The game's own
-- copy of what you say isn't a packet, so your own shares are noted as they're sent (text_out).
vana.events.on('packet_in', function (e)
    if e.id ~= 0x017 then return end
    local data = e.data
    if data == nil or #data < 0x18 or not data:find('[Map:', 0x18, true) then return end
    local from = data:sub(0x09, 0x17):match('^[%a]+') or ''
    local line = data:sub(0x18):match('^[^%z]*') or ''
    local me = C.me.name or (vana.game.character())
    for _, pin in ipairs(K.find(line)) do
        local ok, err = pcall(C.receive, pin, from, from ~= '' and from == me)
        if not ok then fail('receive', err) end
    end
end)

vana.events.on('text_out', function (e)
    local line = e.message_modified or e.message
    if type(line) ~= 'string' or not line:find('[Map:', 1, true) then return end
    for _, pin in ipairs(K.find(line)) do pcall(C.receive, pin, C.me.name or 'You', true) end
end)

-------------------------------------------------------------------------------
-- Zoning
-------------------------------------------------------------------------------

vana.events.on('zone_change', function ()
    TRACK.floors = {}
    C.me.floor = nil
    WAYS.done = nil
end)

vana.events.on('logout', function ()
    st.open = false
    st.sel = nil
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local HELP = {
    '/vmap  ·  the map on or off (' .. 'the key in /vmap settings does the same)',
    '/vmap bare  ·  the map alone, no window round it, following you (' .. 'its own key does the same)',
    '/vmap here  ·  the zone and floor you are in, centred on you',
    '/vmap zone <name or id>  ·  any zone\'s map',
    '/vmap pin [title]  ·  a pin where you stand',
    '/vmap share [s|p|l|l2|sh|t <name>]  ·  the selected pin, or where you stand, to chat (no channel: copied)',
    '/vmap open <code or line>  ·  opens a shared pin;  /vmap last  ·  the newest one',
    '/vmap key <key|none>  ·  /vmap barekey <key|none>  ·  /vmap scale <pct|auto>  ·  /vmap settings',
}

local function pin_here(title)
    local me = C.me
    if not me.ok or DATA.zones[me.zone] == nil then return nil end
    local f = DATA.floor(me.zone, me.floor)
    local mx, my = DATA.to_map(f, me.x, me.y)
    return { zone = me.zone, floor = f.floor, mx = mx, my = my, icon = 'pin', color = 1, title = title or '', note = '' }
end
C.pin_here = pin_here

vana.events.on('command', function (e)
    local args = {}
    for word in e.command:gmatch('%S+') do args[#args + 1] = word end
    local cmd = (args[1] or ''):lower()
    if cmd ~= '/vanamaps' and cmd ~= '/vmap' and cmd ~= '/vmaps' then return end
    local what = (args[2] or 'toggle'):lower()
    local rest = e.command:match('^%S+%s+%S+%s+(.-)%s*$') or ''
    if not in_world() then
        say('log a character in first')
        return true
    end
    if not DATA.ready then
        local ok, why = DATA.load()
        if not ok then say("can't read the game's maps: " .. tostring(why)) return true end
    end
    pcall(track, imgui.GetTime())
    if what == 'toggle' then C.toggle(false)
    elseif what == 'bare' or what == 'plain' then C.toggle(true)
    elseif what == 'on' or what == 'show' then C.open(true)
    elseif what == 'off' or what == 'hide' or what == 'close' then C.open(false)
    elseif what == 'here' or what == 'where' then
        if not st.open then C.open(true) else C.here() end
    elseif what == 'zone' or what == 'z' then
        local z = C.find_zone(rest)
        if z == nil then say('no zone with a map matches "' .. rest .. '"') return true end
        if not st.open then st.open, st.opened_at = true, clock() end
        C.show(z)
    elseif what == 'pin' then
        local p = pin_here(rest)
        if p == nil then say('the game has no map for where you stand') return true end
        local pin = C.add_pin(p.zone, p.floor, p.mx, p.my, { title = rest })
        say('pinned ' .. C.zone_name(pin.zone) .. ' (' .. C.square(pin) .. ')' .. (rest ~= '' and (': ' .. rest) or ''))
        if st.open then st.sel = pin end
    elseif what == 'share' then
        local pin = (st.open and st.sel) or pin_here('')
        if pin == nil then say('nothing to share: the game has no map for where you stand') return true end
        C.share(pin, args[3] and args[3]:lower() or nil, args[4])
    elseif what == 'open' or what == 'link' then
        local pin = K.parse(rest)
        if pin == nil then say('that isn\'t a VanaMaps pin: ' .. rest) return true end
        local entry = nil
        for _, s in ipairs(C.shared()) do if s.code == pin.code then entry = s end end
        entry = entry or C.receive(pin, '', true)
        if entry then C.open_shared(entry) st.focus_frames = 2 end
    elseif what == 'last' then
        local entry = C.shared()[1]
        if entry == nil then say('nobody has shared a pin with you yet') return true end
        C.open_shared(entry)
        st.focus_frames = 2
    elseif what == 'key' then
        local key = (args[3] or ''):lower()
        if key == '' then say('the key is ' .. KEYS.label(cfg.key) .. (KEYS.note and (' (not bound: ' .. KEYS.note .. ')') or '')) return true end
        cfg.key = key
        cfg.layout_checked = true
        KEYS.bind()
        config:save()
        say(KEYS.bound.main and ('the map opens with ' .. KEYS.label(key)) or (key == 'none' and 'no key opens the map now' or ('not bound: ' .. tostring(KEYS.note))))
    elseif what == 'barekey' then
        local key = (args[3] or ''):lower()
        if key == '' then say('the bare map\'s key is ' .. KEYS.label(cfg.bare_key) .. (KEYS.notes.bare and (' (not bound: ' .. KEYS.notes.bare .. ')') or '')) return true end
        cfg.bare_key = key
        cfg.layout_checked = true
        KEYS.bind()
        config:save()
        say(KEYS.bound.bare and ('the bare map opens with ' .. KEYS.label(key)) or (key == 'none' and 'no key opens the bare map now' or ('not bound: ' .. tostring(KEYS.notes.bare))))
    elseif what == 'scale' then
        local v = (args[3] or ''):lower()
        if v == 'auto' or v == '0' then cfg.scale = 0
        elseif tonumber(v) then cfg.scale = math.max(50, math.min(250, math.floor(tonumber(v))))
        else say('/vmap scale <50 to 250, or auto>') return true end
        config:save()
    elseif what == 'settings' or what == 'config' then
        if not st.open then C.open(true) end
        st.settings_open = true
    elseif what == 'pad' then
        -- a controller's buttons, pretended (testing without one): /vmap pad a | lx=0.8 ly=-0.5 r2 ...
        local names, frames = {}, 4
        for i = 3, #args do
            local k, v = args[i]:match('^(%w+)=([%-%.%d]+)$')
            if k == 'frames' then frames = tonumber(v) or 4
            elseif k then names[k] = tonumber(v)
            else names[args[i]:lower()] = true end
        end
        if next(names) == nil then say(PAD.describe()) else PAD.inject(names, frames) end
    elseif what == 'stats' then
        local s = TEX.stats()
        say(string.format('%d zones with maps, %d maps; %d textures (%.1f MB), %d loaded, last in %.1f ms; a frame of the map takes %.2f ms (%.2f at most lately)',
            #DATA.order, DATA.count, s.textures, s.bytes / 1048576, s.loads, s.last_ms, st.cost or 0, st.cost_max or 0))
    else
        for _, line in ipairs(HELP) do vana.chat.write(line, 106) end
    end
    return true
end)

vana.events.on('load', function ()
    U.apply_theme(cfg.theme)
    PAD.setup('vanamaps', U)
    C.CV = require('canvas')(C)
    C.SB = require('sidebar')(C)
    KEYS.bind()
    if in_world() then pcall(DATA.load) end
end)

vana.events.on('unload', function ()
    KEYS.unbind()
    if KEYS.capture then pcall(vana.binds.capture_end) end
    pcall(PAD.teardown, 'vanamaps')
    pcall(TEX.release_all)
    pcall(U.release_textures)
end)
