--[[
vanastore (VanaStore): the addons ffxiprivateservers.com lists for VanaCore, in a window in the game. Browse them, read
about one, install it, update it, and switch it on or off, without leaving the game.

In game (/store works as well as /vanastore):
  /store                  the store on or off
  /store open | close
  /store search <words>   opens it on a search
  /store scale <pct|auto> the window's size, 60 to 250
  /store settings         size, opacity, controller
  /store help             this list

A sibling of the Auction House, VanaMaps and Party Finder windows (their drawing kit, ui.lua, and their controller
module, pad.lua), in ffxiprivateservers.com's colours and faces: Press Start 2P for a few headline words, Inter for
what is read, JetBrains Mono for figures, and the site's stepped pixel frame on the featured card and the primary
button only (look.lua).

Settings: settings\addons\vanastore\<Character>\settings.json.
--]]

addon.name    = 'vanastore'
addon.author  = 'Carver'
addon.version = '0.1.0'
addon.desc    = 'VanaStore: browse, install and update VanaCore addons from ffxiprivateservers.com.'
addon.link    = 'https://ffxiprivateservers.com/addons'

local imgui = vana.imgui
if imgui == nil then
    print('vanastore needs a newer VanaCore.Core.dll (vana.imgui)')
    return
end

local U = require('ui') -- the family's drawing kit (tools/make_ui.py)
local P, F, T = U.P, U.fonts(), U.sizes()
local S = U.S
local L = require('look')
local D = require('catalog')
local PAD = require('pad')
local K = L.C

local DEFAULTS = { scale = 0, opacity = 100, w = 1100, h = 760, view = 'all' }
local config = vana.settings.register({ scope = 'character', defaults = DEFAULTS })

-- what every part of the addon shares (views.lua)
local C = {
    U = U, L = L, D = D, PAD = PAD,
    cfg = config.data,
    st = { open = false, anim = 0, view = 'all', compat = nil, detail = nil, query = { '' }, settings_open = false, grid_at = 0 },
    jobs = {},        -- slug -> { state = 'download' | 'verify' | 'install' | 'refused', progress, why }
    version = addon.version,
    alpha = 1,
}
local cfg, st = C.cfg, C.st
VANASTORE = C -- (this addon's own Lua state: for a test's eyes, through VanaCore's MCP)

local function clock() return vana.time.clock() end
local function say(text) vana.chat.write('[VanaStore] ' .. text, 106) end
local function fail(where, err) vana.log('vanastore ' .. where .. ': ' .. tostring(err)) end
C.say, C.fail = say, fail

function C.save() config:save() end
-- everything drawn after this is that much fainter (a card coming in), over the window's own opacity
function C.fade(a) U.set_window_alpha(C.alpha * math.max(0, math.min(1, a))) end

local function auto_scale()
    local _, sh = vana.ui.screen()
    return math.max(60, math.min(250, math.floor((sh or 1080) / 1080 * 100 / 5 + 0.5) * 5))
end
function C.scale_now() return (cfg.scale and cfg.scale > 0) and cfg.scale or auto_scale() end

-------------------------------------------------------------------------------
-- What the window does
-------------------------------------------------------------------------------

function C.open(on)
    if on == st.open then return end
    st.open = on
    if on then
        st.focus_frames = 2
        st.grid_at = clock()
        if D.state ~= 'ready' then D.load_stub() end
        D.look(true)
    else
        st.settings_open = false
    end
end
function C.toggle() C.open(not st.open) end

function C.open_detail(a)
    st.detail, st.detail_at, st.shot, st.shot_at = a.slug, clock(), 1, 0
    st.scroll_top = true
    st.settings_open = false
end
function C.close_detail()
    st.detail = nil
    st.grid_at = clock() - 0.2
    st.scroll_top = true
end

-- an addon's page on the site, in the player's browser; the link copied where no browser opens
function C.open_page(url)
    local ok, opened = pcall(vana.system.open_url, url)
    if ok and opened then
        U.toast('info', 'Opened in your browser', url:gsub('^https?://', ''), 3, 'arrow-right')
    else
        pcall(vana.system.set_clipboard, url)
        U.toast('info', 'Link copied', url:gsub('^https?://', ''), 4, 'circle-check')
    end
end

-- Install or update. (This build draws the steps only: the download, the checksum and the install are the next step.)
function C.install(a)
    local job = C.jobs[a.slug]
    if job and job.state ~= 'refused' then return end
    C.jobs[a.slug] = { state = 'download', progress = 0, at = clock(), preview = true }
end

-- On or off: loaded now, and at every start
function C.switch(a, on)
    if on then
        vana.chat.run('/addon load ' .. a.name .. ' vanacore', 1)
        pcall(vana.addons.load_at_start, a.name)
    else
        vana.chat.run('/addon unload ' .. a.name, 1)
    end
    a.loaded = on
    D.looked_at = clock() - 2 -- (looked at again in a second, once the command has run)
end

local function tick_jobs()
    local now = clock()
    for _, job in pairs(C.jobs) do
        if job.preview and job.state ~= 'refused' then
            local e = now - job.at
            if e < 1.8 then job.state, job.progress = 'download', e / 1.8
            elseif e < 2.4 then job.state, job.progress = 'verify', 1
            elseif e < 3.0 then job.state, job.progress = 'install', 1
            else job.state, job.why = 'refused', 'Preview catalog: nothing was installed.' end
        end
    end
end

-------------------------------------------------------------------------------
-- The window
-------------------------------------------------------------------------------

local W = { min_w = 900, min_h = 580, rail = 176 }
local V = nil

local function draw_header(dl, x, y, w, t)
    local h = S(80)
    U.aurora(dl, x, y, w, h, t, S(16))
    L.eyebrow(dl, x + S(26), y + S(16), 'FFXI ADDONS', K.gold)
    L.pix(dl, x + S(26), y + S(34), 'VANASTORE', K.hot, 3, 1, '#1A0F00')
    local pulse = 0.55 + 0.45 * math.sin(t * 2)
    dl:AddRectFilledMultiColor({ x + S(16), y + h - 1 }, { x + w - S(16), y + h + 1 }, U.u32(K.teal, 0), U.u32(K.teal, 0.7 * pulse),
        U.u32(K.gold, 0.8 * pulse), U.u32(K.gold, 0))

    local size = S(32)
    local ix, iy = x + w - S(22) - size, y + S(24)
    if L.icon_button(dl, '##vs_close', ix, iy, size, L.CP.xmark, K.dim, 'Close (Esc)') then C.open(false) end
    ix = ix - size - S(4)
    if L.icon_button(dl, '##vs_settings', ix, iy, size, L.CP.gear, st.settings_open and K.gold or K.dim, 'Settings', st.settings_open) then
        st.settings_open = not st.settings_open
    end
    ix = ix - size - S(4)
    if L.icon_button(dl, '##vs_refresh', ix, iy, size, L.CP.rotate, K.dim, 'Look for new addons and updates') then
        D.load_stub()
        D.look(true)
        st.grid_at = clock()
    end
    -- the search box
    local fw = math.min(S(280), w - S(26) - L.pix_width('VANASTORE', 3) - S(40) - (size + S(4)) * 3 - S(40))
    if fw > S(120) then
        local fx = ix - S(14) - fw
        imgui.SetCursorScreenPos({ fx, iy })
        local changed = L.field('##vs_search', 'Search addons', st.query, fw, T.small, 48)
        if (st.query[1] or '') == '' then L.icon(dl, fx + fw - S(18), iy + size / 2, L.CP.search, K.faint, T.small) end
        if changed then
            st.detail, st.settings_open = nil, false
            st.grid_at = clock() - 0.15
            st.scroll_top = true
        end
    end
    return h
end

local function draw_legend(dl, x, y, w)
    local items = { { 'confirm', 'Select' }, { 'cancel', st.detail and 'Back' or 'Close' }, { 'l1 r1', 'Lists' }, { 'rstick', 'Scroll' } }
    local lw = PAD.legend(dl, -10000, -10000, items, 0)
    PAD.legend(dl, x + (w - lw) / 2, y + S(14), items, 1)
end

local VIEWS = { 'all', 'installed', 'updates' }
local function pad_buttons()
    if PAD.pressed('cancel') then
        if st.settings_open then st.settings_open = false
        elseif st.detail then C.close_detail()
        else C.open(false) end
    end
    local turn = (PAD.pressed('r1') and 1 or 0) - (PAD.pressed('l1') and 1 or 0)
    if turn ~= 0 then
        local i = 1
        for n, v in ipairs(VIEWS) do if v == st.view then i = n end end
        V.set_view(VIEWS[(i - 1 + turn) % #VIEWS + 1], st.compat)
    end
    if PAD.pressed('start') then st.settings_open = not st.settings_open end
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
    C.alpha = fade * math.max(0.4, math.min(1, (cfg.opacity or 100) / 100))
    U.set_window_alpha(C.alpha)
    U.push_theme()
    if imgui.Begin('##vanastore', nil, U.WINDOW_FLAGS) then
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
            end
            if PAD.shown() and st.pad_focused and imgui.SetNavCursorVisible then imgui.SetNavCursorVisible(true) end
            -- the header's buttons are the mouse's: the controller has buttons of its own for them
            local no_nav = C.pad_on and imgui.PushItemFlag ~= nil
            if no_nav then imgui.PushItemFlag(2, true) end
            local hy = draw_header(dl, x, y, w, t)
            if no_nav then imgui.PopItemFlag() end
            local foot = S(36)
            local by = y + hy + S(16)
            local bh = y + h - by - foot - legend_h
            local bx, bw = x + S(16), w - S(32)
            if legend_h > 0 then draw_legend(dl, x, y + h - legend_h - S(4), w) end
            local rail_w = S(W.rail)
            V.rail(dl, bx, by, rail_w)
            dl:AddLine({ bx + rail_w + S(12), by }, { bx + rail_w + S(12), by + bh - S(4) }, U.u32(K.line, 0.7), 1)
            local mx, mw = bx + rail_w + S(26), bw - rail_w - S(26)
            if st.settings_open then
                V.settings(dl, mx, by, mw - S(6), bh - S(8))
            else
                V.main(dl, mx, by, mw, bh, t, dt)
            end
            C.fade(1)
            -- the footer, over a hairline
            local fy = y + h - foot - legend_h
            dl:AddLine({ x + S(16), fy }, { x + w - S(16), fy }, U.u32(K.line, 0.7), 1)
            if no_nav then imgui.PushItemFlag(2, true) end
            V.footer(dl, x + S(26), fy, w - S(52), foot)
            if no_nav then imgui.PopItemFlag() end
            -- the corner that sizes the window
            local gs = S(18)
            imgui.SetCursorScreenPos({ x + w - gs, y + h - gs })
            imgui.InvisibleButton('##vs_grip', { gs, gs })
            local hot = imgui.IsItemHovered() or imgui.IsItemActive()
            if hot then imgui.SetMouseCursor(6) end
            if imgui.IsItemActive() then
                local px, py = imgui.GetMousePos()
                cfg.w = math.max(W.min_w, (px - x + S(4)) / U.scale())
                cfg.h = math.max(W.min_h, (py - y + S(4) - legend_h) / U.scale())
            end
            for i = 1, 3 do
                local o = S(4) * i
                dl:AddLine({ x + w - S(5), y + h - S(5) - o }, { x + w - S(5) - o, y + h - S(5) }, U.u32(hot and K.gold or K.dim, hot and 0.9 or 0.4), 1)
            end
            if imgui.IsItemDeactivated() then config:save() end
            if imgui.IsWindowFocused(3) and imgui.IsKeyPressed(U.KEY_ESCAPE) and not L.typing() then
                if st.settings_open then st.settings_open = false
                elseif st.detail then C.close_detail()
                else C.open(false) end
            end
        end)
        if not drew then
            fail('window', err)
            st.errors = (st.errors or 0) + 1
            if st.errors > 30 then
                st.open = false
                say('the store window had a problem and was closed; see logs\\vanacore.log')
            end
        end
    end
    imgui.End()
    U.pop_theme()
    U.set_window_alpha(1)
end

vana.events.on('present', function ()
    local t = imgui.GetTime()
    local dt = math.max(0.001, math.min(0.1, imgui.GetIO().DeltaTime or 0.016))
    st.anim = U.lerp(st.anim, st.open and 1 or 0, math.min(1, dt * (st.open and 9 or 14)))
    if st.anim < 0.02 and not st.open then st.anim = 0 end
    local busy = st.open or st.anim > 0 or #U.anim.toasts > 0
    if not busy then
        -- nothing of ours on the screen: the pictures go after a while, and nothing else is done
        if st.idle_since == nil then st.idle_since = t end
        if t - st.idle_since > 45 and D.PIC.count > 0 then D.release_pictures() end
        return
    end
    st.idle_since = nil
    if not U.frame(dt, C.scale_now() / 100, t) then return end
    if not L.fonts.loaded then
        L.load_fonts() -- (ready from the next frame, as the kit's own)
        return
    end
    PAD.frame(t, { id = 'vanastore', capture = function () return st.open end })
    U.anim.pad_shown = PAD.shown()
    L.no_tips = PAD.shown()
    tick_jobs()
    if st.open then D.look() end
    if st.open or st.anim > 0 then draw_main(t, dt) end
    pcall(L.draw_tip, dt)
    local okt, errt = pcall(U.draw_toasts, t)
    if not okt then fail('toasts', errt) end
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local HELP = {
    '/store: the addon store on or off (/vanastore is the same)',
    '/store search <words>: opens it on a search',
    '/store scale <pct|auto>: the window\'s size, 60 to 250',
    '/store settings: size, opacity, controller',
}

vana.events.on('command', function (e)
    local args = {}
    for word in e.command:gmatch('%S+') do args[#args + 1] = word end
    local cmd = (args[1] or ''):lower()
    if cmd ~= '/vanastore' and cmd ~= '/store' then return end
    local what = (args[2] or 'toggle'):lower()
    local rest = e.command:match('^%S+%s+%S+%s+(.-)%s*$') or ''
    if what == 'toggle' then C.toggle()
    elseif what == 'open' or what == 'on' or what == 'show' then C.open(true)
    elseif what == 'close' or what == 'off' or what == 'hide' then C.open(false)
    elseif what == 'search' or what == 'find' then
        C.open(true)
        st.query[1], st.detail, st.settings_open = rest, nil, false
        st.grid_at = clock()
    elseif what == 'settings' then
        C.open(true)
        st.settings_open = true
    elseif what == 'scale' or what == 'size' then
        local n = tonumber((rest:gsub('%%', '')))
        if rest:lower() == 'auto' then cfg.scale = 0
        elseif n then cfg.scale = math.max(60, math.min(250, math.floor(n + 0.5)))
        else say('the size is ' .. C.scale_now() .. '%' .. (cfg.scale == 0 and ' (fits the screen)' or '')) return true end
        config:save()
    elseif what == 'pad' then
        -- a controller's buttons, for a test without one: /store pad down a
        local names, frames = {}, nil
        for i = 3, #args do
            if tonumber(args[i]) then frames = tonumber(args[i]) else names[args[i]:lower()] = true end
        end
        if next(names) == nil then say(PAD.describe()) else PAD.inject(names, frames) end
    else
        for _, line in ipairs(HELP) do vana.chat.write(line, 106) end
    end
    return true
end)

vana.events.on('load', function ()
    L.apply()
    PAD.setup('vanastore', U)
    V = require('views')(C)
    C.V = V
    st.view = (cfg.view == 'installed' or cfg.view == 'updates') and cfg.view or 'all'
    D.load_stub()
end)

vana.events.on('unload', function ()
    pcall(PAD.teardown, 'vanastore')
    pcall(D.release_pictures)
    pcall(U.release_textures)
end)
