-- A controller for an addon's window. VanaCore hands addons each XInput read ('xinput_state': the game's XINPUT_STATE,
-- changeable in place) and each DirectInput change ('dinput_button'); nothing reaches ImGui. This turns them into
-- ImGui's gamepad keys, so ImGui's own navigation moves the focus between a window's buttons (every hit() is one),
-- and takes the input away from the game while the window has it, so the character doesn't run and the game's menus
-- don't open under ours. The window draws the focus (the ring in draw_toasts), handles the buttons it gives meanings
-- to (PAD.pressed) and shows a legend (PAD.legend).
--
-- With a VanaCore that feeds ImGui itself (0.8.39+: vana.gamepad.nav, bindings, state), the feeding and the blocking
-- are VanaCore's: this says each frame that the window has the pad (vana.gamepad.nav), reads the buttons for their
-- meanings, and keeps the ring, the legend and the seating. A synthetic press (/ah pad) is still fed here, as VanaCore
-- never sees one.
-- Each addon runs in a Lua state of its own, so each carries its own copy of this, and each copy sees every read.
-- The game is kept from the controller by blocking its changes (VanaCore's 'xinput_button' / 'dinput_button':
-- presses and moves while a window has it, releases through), not by clearing the read, so every copy reads the real
-- state; ImGui drops the duplicate key events the copies feed. Which window acts is ImGui's focus: a window reads
-- PAD.pressed only while it is the focused one (its host checks), so two open windows never answer the same press.
-- The switch is one for all of them: vanacore.ini's [addons] gamepad (PAD.enabled, PAD.set_enabled).
--
-- Shared source: tools/pad.lua, copied into each addon by tools/make_ui.py. Edit there.
local imgui = vana.imgui
local bit = require('bit')
local ffi_ok, ffi = pcall(require, 'ffi')
local U = nil -- the drawing kit: the auction house's ui.lua, or what Party Finder hands PAD.setup

local PAD = {}

-- ImGui 1.92's gamepad keys
local KEY = {
    start = 632, back = 633, x = 634, b = 635, y = 636, a = 637, left = 638, right = 639, up = 640, down = 641,
    l1 = 642, r1 = 643, l2 = 644, r2 = 645, l3 = 646, r3 = 647,
    ls_left = 648, ls_right = 649, ls_up = 650, ls_down = 651, rs_left = 652, rs_right = 653, rs_up = 654, rs_down = 655,
    escape = 526, -- the keyboard's, for hosts short of locals
}
local NAV_ENABLE_GAMEPAD, HAS_GAMEPAD = 2, 1 -- ImGuiConfigFlags_NavEnableGamepad, ImGuiBackendFlags_HasGamepad

-- XINPUT_GAMEPAD.wButtons
local XBIT = { up = 0x0001, down = 0x0002, left = 0x0004, right = 0x0008, start = 0x0010, back = 0x0020, l3 = 0x0040,
    r3 = 0x0080, l1 = 0x0100, r1 = 0x0200, a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000 }
local BUTTONS = { 'a', 'b', 'x', 'y', 'up', 'down', 'left', 'right', 'l1', 'r1', 'l2', 'r2', 'l3', 'r3', 'start', 'back' }
local DEADZONE, TRIGGER = 0.24, 0.4
local XDEAD = { [16] = 30, [17] = 30, [18] = 7849, [19] = 7849, [20] = 8689, [21] = 8689 } -- XInput's own, by control

-- the game's own button map (padsin000, through vanacore.ini's [ffxi] gamepad.buttons when the launcher sets it):
-- slot 7 is Confirm, 5 Cancel, 6 the main menu, 8 the chat window / options. With XInput on (padmode000's sixth) the
-- numbers are the launcher's: 0 B, 1 X, 2 Y, 3 A, 4-7 Right, Left, Up, Down, 8 LB, 9 LT, 10 LS, 11 RB, 12 RT, 13 RS,
-- 14 Start, 15 Back; otherwise a DirectInput button's number.
local XNUM = { [0] = 'b', 'x', 'y', 'a', 'right', 'left', 'up', 'down', 'l1', 'l2', 'l3', 'r1', 'r2', 'r3', 'start', 'back' }
local SLOT = { confirm = 7, cancel = 5, menu = 6, options = 8 }
-- Ashita's numbers, every one keyed: a positional entry after [12] would count on from 10 and overwrite it (12 read as
-- Y, 13 as LT, so B never backed out)
local ABIT = { [0] = 'up', [1] = 'down', [2] = 'left', [3] = 'right', [4] = 'start', [5] = 'back', [6] = 'l3', [7] = 'r3',
    [8] = 'l1', [9] = 'r1', [12] = 'a', [13] = 'b', [14] = 'x', [15] = 'y', [16] = 'l2', [17] = 'r2' }
-- a DirectInput controller's buttons, as most come (an Xbox-style pad): 0 A, 1 B, 2 X, 3 Y, 4 LB, 5 RB, 6 Back, 7 Start,
-- 8 LS, 9 RS; its triggers are an axis (Z) on those
local DNUM = { [0] = 'a', 'b', 'x', 'y', 'l1', 'r1', 'back', 'start', 'l3', 'r3' }

if ffi_ok then
    pcall(ffi.cdef, [[
        typedef struct { uint16_t wButtons; uint8_t bLeftTrigger; uint8_t bRightTrigger;
                         int16_t sThumbLX; int16_t sThumbLY; int16_t sThumbRX; int16_t sThumbRY; } pad_XINPUT_GAMEPAD;
        typedef struct { uint32_t dwPacketNumber; pad_XINPUT_GAMEPAD Gamepad; } pad_XINPUT_STATE;
    ]])
end

local function clock() return U.clock() end

local st = {
    hosts = {},              -- id -> { capture = function, enabled = bool, hold_vertical = bool }
    frame_no = -1,           -- ImGui's frame the work was last done in
    native = false,          -- VanaCore feeds ImGui itself and keeps the game from the pad: only the reading is done here
    enabled = true,          -- the host's setting
    now = { }, was = { },    -- button name -> down, this read and the frame before
    edge = { },              -- pressed this frame
    held_since = { },        -- button name -> when it went down
    repeated_at = { },       -- button name -> when it last repeated
    lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0,
    seen_at = -1e9,          -- any input that wasn't neutral
    read_at = -1e9,          -- any read at all (XInput reads come every frame while a pad is plugged in)
    dinput_at = -1e9,        -- any DirectInput change
    mouse_at = 0, mouse_x = nil, mouse_y = nil,
    nav_on = false,
    fed = {},                -- ImGui keys as last fed
    map = { confirm = 'a', cancel = 'b', menu = 'y', options = 'x' },
    dmap = {},               -- DirectInput button number -> name
    xinput_mode = true,
    fake = nil,              -- a synthetic state (/ah pad): { raw, until }
    axis = {},               -- DirectInput axes seen: offset -> { lo, hi }
    glyphs = {},
    enabled_at = -1e9, enabled_cached = false, -- vanacore.ini's [addons] gamepad, read now and then
    seen_packet = nil,       -- the last XINPUT_STATE taken (its address and packet), should a read be raised twice
    bound = false,
}

-- the switch, one for every addon: vanacore.ini [addons] gamepad = 1
function PAD.enabled()
    local t = U and U.clock() or 0
    if t - st.enabled_at > 1.5 then
        st.enabled_at = t
        local ok, v = pcall(vana.config.get, 'addons', 'gamepad')
        v = ok and v or nil
        st.enabled_cached = v == '1' or v == 'true' or v == 'on' or v == 'yes'
    end
    return st.enabled_cached
end
function PAD.set_enabled(on)
    pcall(vana.config.set, 'addons', 'gamepad', on and '1' or '0')
    st.enabled_cached, st.enabled_at = on == true, U and U.clock() or 0
end

-- what the windows want, together
local function capturing_now()
    if not PAD.enabled() then return false end
    for _, h in pairs(st.hosts) do
        if h.capture and h.capture() then return true end
    end
    return false
end
local function any_enabled() return PAD.enabled() end
-- what a window keeps from ImGui's navigation: true, up and down (a price box stepping); 'all', the whole D-pad
-- (a price box being edited digit by digit)
local function hold_vertical()
    local r = false
    for _, h in pairs(st.hosts) do
        if h.hold == 'all' then return 'all' end
        if h.hold or h.hold_vertical then r = true end
    end
    return r
end

-------------------------------------------------------------------------------
-- The game's bindings
-------------------------------------------------------------------------------

local function fields(s)
    local out = {}
    for v in tostring(s or ''):gmatch('[^,]+') do out[#out + 1] = tonumber(v) end
    return out
end

local function read_bindings()
    for i, n in pairs(DNUM) do st.dmap[i] = n end
    local ok, mode = pcall(vana.config.game, 'padmode000')
    local m = ok and fields(mode) or {}
    if m[6] ~= nil then st.xinput_mode = m[6] ~= 0 end
    local ok2, sin = pcall(vana.config.game, 'padsin000')
    local s = ok2 and fields(sin) or {}
    for what, slot in pairs(SLOT) do
        local v = s[slot + 1]
        if v and v >= 0 then
            if st.xinput_mode then
                if XNUM[v] then st.map[what] = XNUM[v] end
            else
                -- a DirectInput button: it is this function; the name it takes is its slot in the default order
                local name = DNUM[v] or ('b' .. v)
                st.map[what] = name
                st.dmap[v] = name
            end
        end
    end
    -- VanaCore's own reading of the same map, by Ashita's control numbers (12 A, 13 B, 14 X, 15 Y, 0-3 the D-pad,
    -- 4 Start, 5 Back, 6 and 7 the sticks, 8 LB, 9 RB, 16 LT, 17 RT), when it has one
    if st.native then
        local ok3, b = pcall(vana.gamepad.bindings)
        if ok3 and type(b) == 'table' then
            if b.xinput ~= nil then st.xinput_mode = b.xinput == true end
            for what in pairs(SLOT) do
                local v = tonumber(b[what]) or -1
                if v >= 0 then
                    if st.xinput_mode then
                        if ABIT[v] then st.map[what] = ABIT[v] end
                    else
                        local name = DNUM[v] or ('b' .. v)
                        st.map[what] = name
                        st.dmap[v] = name
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Reads
-------------------------------------------------------------------------------

local function neutral(raw)
    if raw.buttons ~= 0 then return false end
    return math.abs(raw.lx) < DEADZONE and math.abs(raw.ly) < DEADZONE and math.abs(raw.rx) < DEADZONE
        and math.abs(raw.ry) < DEADZONE and raw.lt < TRIGGER and raw.rt < TRIGGER
end

-- raw: { buttons = wButtons, lx, ly, rx, ry (-1..1), lt, rt (0..1) }
local function take(raw)
    local t = clock()
    st.read_at = t
    for _, n in ipairs(BUTTONS) do
        local down
        if n == 'l2' then down = raw.lt >= TRIGGER
        elseif n == 'r2' then down = raw.rt >= TRIGGER
        else down = bit.band(raw.buttons, XBIT[n]) ~= 0 end
        st.now[n] = down
    end
    st.lx, st.ly, st.rx, st.ry, st.lt, st.rt = raw.lx, raw.ly, raw.rx, raw.ry, raw.lt, raw.rt
    if not neutral(raw) then st.seen_at = t end
end

local function axis(v) -- a thumb stick's SHORT to -1..1, past the dead zone
    local f = v / 32767
    if math.abs(f) < DEADZONE then return 0 end
    return math.max(-1, math.min(1, f))
end

-- VanaCore's 'xinput_state': e.user, e.state (XINPUT_STATE*, the game's)
function PAD.on_xinput(e)
    if not ffi_ok or e.state == nil then return end -- (native too: the read is the window's to know; VanaCore rests it after)
    local ok, p = pcall(ffi.cast, 'pad_XINPUT_STATE*', e.state)
    if not ok or p == nil then return end
    local g = p.Gamepad
    -- every read says the pad is there, changed or not: its packet number only moves when its state does, so an idle
    -- pad (or a D-pad held down) read as gone after 2 s, and each stick twitch brought it back, the window's capture
    -- flapping with it (a text box lost its focus every few seconds, the legend came and went)
    st.read_at = clock()
    local packet = tostring(e.state) .. '/' .. tostring(p.dwPacketNumber)
    if packet == st.seen_packet then return end
    st.seen_packet = packet
    take({ buttons = g.wButtons, lx = axis(g.sThumbLX), ly = axis(g.sThumbLY), rx = axis(g.sThumbRX), ry = axis(g.sThumbRY),
        lt = g.bLeftTrigger / 255, rt = g.bRightTrigger / 255 })
end

-- VanaCore's 'xinput_button': e.button (0-15 the buttons, 16-17 the triggers, 18-21 the sticks), e.state. Returns true
-- to keep a change from the game: a press, a pull or a move out of the dead zone while a window has the controller;
-- a release, or a stick coming to rest, always goes through, so the game never holds anything.
function PAD.on_xinput_button(e)
    if st.native or not capturing_now() then return false end
    local control, v = tonumber(e.button) or -1, tonumber(e.state) or 0
    local dead = XDEAD[control] or 0
    return math.abs(v) > dead
end

-- VanaCore's 'dinput_button': e.button (a DIJOYSTATE offset: axes 0-28 by 4, hats 32-44, buttons from 48), e.state.
-- Returns true to keep a change from the game: presses and moves while the window has the controller; a release
-- always goes through, so the game never thinks a button is held.
local dstate = { buttons = 0, lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0 }
function PAD.on_dinput(e)
    local off, v = tonumber(e.button) or -1, tonumber(e.state) or 0
    st.dinput_at = clock()
    if off >= 48 then
        local name = st.dmap[off - 48]
        local down = v ~= 0
        if name and XBIT[name] then
            dstate.buttons = down and bit.bor(dstate.buttons, XBIT[name]) or bit.band(dstate.buttons, bit.bnot(XBIT[name]))
        end
    elseif off == 32 then
        -- the hat: hundredths of a degree clockwise from up, or centred (-1 / 0xFFFFFFFF)
        dstate.buttons = bit.band(dstate.buttons, bit.bnot(bit.bor(XBIT.up, XBIT.down, XBIT.left, XBIT.right)))
        if v >= 0 and v < 36000 then
            local a = v / 100
            if a < 67.5 or a > 292.5 then dstate.buttons = bit.bor(dstate.buttons, XBIT.up) end
            if a > 22.5 and a < 157.5 then dstate.buttons = bit.bor(dstate.buttons, XBIT.right) end
            if a > 112.5 and a < 247.5 then dstate.buttons = bit.bor(dstate.buttons, XBIT.down) end
            if a > 202.5 and a < 337.5 then dstate.buttons = bit.bor(dstate.buttons, XBIT.left) end
        end
    elseif off < 32 then
        -- an axis, in whatever range the game set (0..65535 as a rule): its centre and span learnt from what's seen
        local ax = st.axis[off]
        if ax == nil then ax = { lo = v, hi = v } st.axis[off] = ax end
        if v < ax.lo then ax.lo = v end
        if v > ax.hi then ax.hi = v end
        local span = ax.hi - ax.lo
        local f = span >= 256 and ((v - ax.lo) / span * 2 - 1) or 0
        if math.abs(f) < DEADZONE then f = 0 end
        if off == 0 then dstate.lx = f
        elseif off == 4 then dstate.ly = -f
        elseif off == 8 then dstate.lt, dstate.rt = math.max(0, f), math.max(0, -f) -- the triggers share Z on Xbox pads
        elseif off == 12 then dstate.rx = f
        elseif off == 16 then dstate.ry = -f end
    end
    take(dstate)
    return not st.native and capturing_now() and v ~= 0 and v ~= -1 and v ~= 0xFFFFFFFF
end

-- a synthetic read, for testing with no controller plugged in: names = { a = true, down = true, ly = -1 ... }
function PAD.inject(names, frames)
    local raw = { buttons = 0, lx = names.lx or 0, ly = names.ly or 0, rx = names.rx or 0, ry = names.ry or 0, lt = names.lt or 0, rt = names.rt or 0 }
    for n, b in pairs(XBIT) do if names[n] then raw.buttons = bit.bor(raw.buttons, b) end end
    if names.l2 then raw.lt = 1 end
    if names.r2 then raw.rt = 1 end
    st.fake = { raw = raw, left = frames or 3 }
    st.fake_at = clock()
end

-------------------------------------------------------------------------------
-- Each frame
-------------------------------------------------------------------------------

local function feed(key, down, v)
    if v ~= nil then
        if st.fed[key] ~= v then imgui.GetIO():AddKeyAnalogEvent(key, down, v) st.fed[key] = v end
    elseif st.fed[key] ~= down then
        imgui.GetIO():AddKeyEvent(key, down)
        st.fed[key] = down
    end
end

local function release_all()
    for _, k in pairs(KEY) do
        if st.fed[k] then feed(k, false, (k >= KEY.ls_left) and 0 or nil) end
    end
end

-- whether a controller is there to be used
function PAD.present()
    local t = clock()
    return st.fake ~= nil or t - st.read_at < 2 or t - st.dinput_at < 300 or t - (st.fake_at or -1e9) < 10
end

-- whether it was used more lately than the mouse: the focus ring and the legend show
function PAD.shown()
    return any_enabled() and PAD.present() and st.seen_at > st.mouse_at
end

function PAD.capturing() return PAD.present() and capturing_now() end

-- host: { id = 'auctionhouse', capture = function () -> bool, hold_vertical = bool }; each window's,
-- every frame. The shared work runs once a frame, for whichever window calls first.
function PAD.frame(t, host)
    if host and host.id then st.hosts[host.id] = host end
    local frame_no = imgui.GetFrameCount()
    if frame_no == st.frame_no then return end
    st.frame_no = frame_no
    local now = clock()
    -- the game's button map (padsin000, or VanaCore's bindings) can change while this stays loaded
    if now - (st.bound_at or -1e9) > 2 then st.bound_at = now read_bindings() end
    -- a synthetic read stands in for the controller's
    if st.fake then
        take(st.fake.raw)
        st.fake.left = st.fake.left - 1
        if st.fake.left <= 0 then
            st.fake = nil
            take({ buttons = 0, lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0 })
        end
    end
    -- the mouse: moved or clicked, it is the thing in use again
    local mx, my = imgui.GetMousePos()
    if type(mx) == 'number' and type(my) == 'number' and mx > -1e5 then
        if st.mouse_x and (math.abs(mx - st.mouse_x) > 2 or math.abs(my - st.mouse_y) > 2) then st.mouse_at = now end
        st.mouse_x, st.mouse_y = mx, my
    end
    if imgui.IsMouseClicked(0) or imgui.IsMouseClicked(1) then st.mouse_at = now end
    -- edges and repeats
    for _, n in ipairs(BUTTONS) do
        local down, was = st.now[n] == true, st.was[n] == true
        st.edge[n] = down and not was
        if down and not was then st.held_since[n] = now st.repeated_at[n] = now end
        st.was[n] = down
    end
    local capturing = PAD.capturing()
    if st.native then
        -- VanaCore feeds ImGui and rests the game's reads while a window has the pad: told so each frame
        if capturing then pcall(vana.gamepad.nav, true) end
        st.nav_on = capturing
        -- a synthetic read (/ah pad) never reaches VanaCore: fed here, the way the bridge does below
        if capturing and st.fake then
            feed(KEY.a, st.now[st.map.confirm] == true)
            feed(KEY.b, st.now[st.map.cancel] == true and imgui.IsAnyItemActive())
            local hold = hold_vertical()
            feed(KEY.left, st.now.left == true and hold ~= 'all')
            feed(KEY.right, st.now.right == true and hold ~= 'all')
            feed(KEY.up, st.now.up == true and not hold)
            feed(KEY.down, st.now.down == true and not hold)
        elseif next(st.fed) then
            release_all()
            st.fed = {}
        end
        return
    end
    local io = imgui.GetIO()
    if capturing then
        -- every frame: another addon's copy may have given them back on its unload
        if bit.band(io.ConfigFlags, NAV_ENABLE_GAMEPAD) == 0 then io.ConfigFlags = bit.bor(io.ConfigFlags, NAV_ENABLE_GAMEPAD) end
        if bit.band(io.BackendFlags, HAS_GAMEPAD) == 0 then io.BackendFlags = bit.bor(io.BackendFlags, HAS_GAMEPAD) end
        st.nav_on = true
    end
    if not capturing then
        if next(st.fed) then release_all() st.fed = {} end
        return
    end
    -- ImGui gets: Confirm (activate) and the D-pad (move the focus); Cancel only while a text box
    -- is being typed in (ImGui leaves it), the window handling it otherwise. The rest is the window's.
    feed(KEY.a, st.now[st.map.confirm] == true)
    feed(KEY.b, st.now[st.map.cancel] == true and imgui.IsAnyItemActive())
    local hold = hold_vertical()
    feed(KEY.left, st.now.left == true and hold ~= 'all')
    feed(KEY.right, st.now.right == true and hold ~= 'all')
    feed(KEY.up, st.now.up == true and not hold)
    feed(KEY.down, st.now.down == true and not hold)
    -- the sticks stay the window's (PAD.stick): ImGui would scroll the window with the focus, the root, which has none
end

-- pressed this frame: a canonical button ('a', 'l1', 'up' ...) or a meaning ('confirm', 'cancel', 'menu', 'options')
function PAD.pressed(name)
    name = st.map[name] or name
    return st.edge[name] == true
end
function PAD.down(name)
    name = st.map[name] or name
    return st.now[name] == true
end
-- Called each frame inside the window while it has the pad: X and Y are the window's, not ImGui's. With VanaCore
-- feeding every button, ImGui read Y (FaceUp) as its "input" key, which activates the focused item like Confirm,
-- and X (FaceLeft) held as its window switcher. A global route makes the window the keys' owner at the next frame,
-- and ImGui's navigation only reads keys nobody owns.
local ROUTE_GLOBAL = 4096 -- ImGuiInputFlags_RouteGlobal
function PAD.claim()
    if not imgui.Shortcut then return end
    pcall(imgui.Shortcut, KEY.x, ROUTE_GLOBAL)
    pcall(imgui.Shortcut, KEY.y, ROUTE_GLOBAL)
end
-- pressed, or held past `delay` and repeating every `every`
function PAD.repeating(name, delay, every)
    name = st.map[name] or name
    if st.edge[name] then return true end
    if not st.now[name] then return false end
    local now = clock()
    if now - (st.held_since[name] or now) >= (delay or 0.4) and now - (st.repeated_at[name] or 0) >= (every or 0.08) then
        st.repeated_at[name] = now
        return true
    end
    return false
end
function PAD.stick() return st.lx, st.ly, st.rx, st.ry end
function PAD.button_of(meaning) return st.map[meaning] or meaning end

-------------------------------------------------------------------------------
-- The legend: glyphs for the buttons, in the controller's own colours
-------------------------------------------------------------------------------

local FACE = { a = { 'A', '#6CC24A' }, b = { 'B', '#E8453C' }, x = { 'X', '#3B8BEB' }, y = { 'Y', '#F2C035' } }
local PILL = { l1 = 'LB', r1 = 'RB', l2 = 'LT', r2 = 'RT', l3 = 'LS', r3 = 'RS', start = 'MENU', back = 'VIEW',
    up = '▲', down = '▼', left = '◀', right = '▶', updown = '▲▼', dpad = '✚', lstick = 'L', rstick = 'R' }

-- one glyph; returns its width
function PAD.glyph(dl, x, cy, name, size, alpha)
    local P, S, F, T = U.P, U.S, U.fonts(), U.sizes()
    alpha = alpha or 1
    name = st.map[name] or name
    local face = FACE[name]
    if face then
        local r = S(size or 9)
        dl:AddCircleFilled({ x + r, cy }, r, U.u32(face[2], 0.22 * alpha), 20)
        dl:AddCircle({ x + r, cy }, r, U.u32(face[2], 0.95 * alpha), 20, 1.2)
        -- (a capital's ink sits above the middle of its line box, the descender's room below: nudged down to centre it)
        U.text_center(dl, x, cy + S(1), r * 2, face[1], face[2], F.bold, T.tiny - 1, alpha)
        return r * 2
    end
    local label = PILL[name] or name:upper()
    local tw = U.measure(label, F.semi, T.tiny - 1)
    local w, h = tw + S(10), S((size or 9) * 2)
    dl:AddRectFilled({ x, cy - h / 2 }, { x + w, cy + h / 2 }, U.u32(P.text, 0.12 * alpha), S(5))
    dl:AddRect({ x, cy - h / 2 }, { x + w, cy + h / 2 }, U.u32(P.text, 0.5 * alpha), S(5), 15, 1)
    U.text_center(dl, x, cy + S(1), w, label, P.text, F.semi, T.tiny - 1, alpha)
    return w
end

-- a row of them: items = { { 'confirm', 'Select' }, { 'l1 r1', 'Tabs' }, ... }; returns the width used
function PAD.legend(dl, x, cy, items, alpha)
    local P, S, F, T = U.P, U.S, U.fonts(), U.sizes()
    alpha = alpha or 1
    local cx = x
    for _, it in ipairs(items) do
        for name in it[1]:gmatch('%S+') do
            cx = cx + PAD.glyph(dl, cx, cy, name, 9, alpha) + S(3)
        end
        cx = cx + S(3)
        U.text_mid(dl, cx, cy, it[2], P.dim, F.text, T.tiny, alpha)
        cx = cx + U.measure(it[2], F.text, T.tiny) + S(16)
    end
    return cx - x
end

-- for /ah pad, /pf pad
function PAD.describe()
    local t = clock()
    local held = {}
    for _, n in ipairs(BUTTONS) do if st.now[n] then held[#held + 1] = n end end
    return string.format('enabled %s, present %s, in use %s, capturing %s, native %s, xinput mode %s, confirm=%s cancel=%s, held [%s], sticks %.2f %.2f / %.2f %.2f, nav %s',
        tostring(PAD.enabled()), tostring(PAD.present()), tostring(PAD.shown()), tostring(PAD.capturing()), tostring(st.native), tostring(st.xinput_mode),
        st.map.confirm, st.map.cancel, table.concat(held, ' '), st.lx, st.ly, st.rx, st.ry, tostring(st.nav_on))
end

-- called once by each window's addon (id as in PAD.frame): registers with VanaCore
function PAD.setup(id, kit)
    U = U or kit or require('ui')
    if not st.bound then
        st.native = type(vana.gamepad) == 'table' and type(vana.gamepad.nav) == 'function'
        read_bindings()
        st.bound = true
    end
    st.hosts[id or 'host'] = st.hosts[id or 'host'] or {}
    -- the reads, native or not: the buttons' meanings, the ring and the legend come from them (the blocking is only
    -- the bridge's: the handlers return false when VanaCore rests the game's reads itself)
    pcall(vana.events.on, 'xinput_state', PAD.on_xinput)
    pcall(vana.events.on, 'xinput_button', PAD.on_xinput_button)
    pcall(vana.events.on, 'dinput_button', PAD.on_dinput)
end

function PAD.teardown(id)
    pcall(vana.events.off, 'xinput_state', PAD.on_xinput)
    pcall(vana.events.off, 'xinput_button', PAD.on_xinput_button)
    pcall(vana.events.off, 'dinput_button', PAD.on_dinput)
    st.hosts[id or 'host'] = nil
    if next(st.hosts) ~= nil then return end
    -- the last one out: the keys let go, the flags given back
    if next(st.fed) then pcall(release_all) end
    if st.nav_on and not st.native then
        local io = imgui.GetIO()
        io.ConfigFlags = bit.band(io.ConfigFlags, bit.bnot(NAV_ENABLE_GAMEPAD))
        io.BackendFlags = bit.band(io.BackendFlags, bit.bnot(HAS_GAMEPAD))
        st.nav_on = false
    end
    st.bound = false
end

PAD.KEY = KEY
return PAD
