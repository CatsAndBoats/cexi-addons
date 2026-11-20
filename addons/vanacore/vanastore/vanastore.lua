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

Installing: the catalog's file is downloaded, its SHA-256 compared with the catalog's before anything opens it, and
VanaCore's own package installer does the rest (install.lua). Only an addon the site marks trusted, hosts itself and
gives a checksum for can be installed (catalog.lua).

Settings: settings\addons\vanastore\<Character>\settings.json. What the store installed: settings\addons\vanastore\
installed.json. The catalog as last fetched: settings\addons\vanastore\catalog.json. Downloads and pictures:
cache\vanastore\ in VanaCore's folder.
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
-- what the store installed on this PC (name -> { slug, version, sha256, at }): the same for every character.
-- (`origin` is a developer's: a copy of the site to test against; empty is ffxiprivateservers.com.)
local ledger = vana.settings.register({ name = 'installed', defaults = { installed = {}, origin = '' } })

-- what every part of the addon shares (views.lua)
local C = {
    U = U, L = L, D = D, PAD = PAD,
    cfg = config.data,
    st = { open = false, anim = 0, view = 'all', compat = nil, detail = nil, query = { '' }, settings_open = false, grid_at = 0 },
    jobs = {},        -- slug -> { state = 'download' | 'verify' | 'install' | 'refused', progress, why }: install.lua
    version = addon.version, name = addon.name,
    alpha = 1,
}
local cfg, st = C.cfg, C.st
VANASTORE = C -- (this addon's own Lua state: for a test's eyes, through VanaCore's MCP)

local function clock() return vana.time.clock() end
local function say(text) vana.chat.write('[VanaStore] ' .. text, 106) end
local function fail(where, err) vana.log(where .. ': ' .. tostring(err)) end
C.say, C.fail = say, fail

function C.save() config:save() end
function C.save_records() ledger:save() end
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
        -- the catalog: asked for when the store is first opened, and again when it's opened ten minutes on
        if D.state ~= 'ready' or clock() - (D.fetch_at or -1e9) > 600 then D.fetch() end
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

-- Install or update, and on or off: install.lua
-- (an addon the site hasn't reviewed is asked about first: draw_confirm)
function C.install(a)
    if a.locked then return end
    -- (a copy of the same name under another framework is asked about too: never a second one unawares)
    local second = a.have == nil and a.elsewhere ~= nil and #a.elsewhere > 0
    if a.trusted and not second then
        C.I.start(a)
    else
        st.confirm = { slug = a.slug, kind = 'install', anim = 0 }
    end
end
function C.switch(a, on) C.I.switch(a, on) end

-- A takeover is asked about first: nothing is fetched or written until the player says yes (draw_confirm)
function C.ask_takeover(a)
    if not a.takeover then return end
    st.confirm = { slug = a.slug, kind = 'takeover', anim = 0 }
end

-- the catalog asked for again (the header's button)
function C.refresh()
    D.fetch()
    D.look(true)
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
    L.pix_tight(dl, x + S(26), y + S(34), 'VANASTORE', K.hot, 3, 1, '#1A0F00')
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
    local busy = D.fetching
    if L.icon_button(dl, '##vs_refresh', ix, iy, size, L.CP.rotate, busy and K.gold or K.dim, busy and 'Looking...' or 'Look for new addons and updates', busy)
        and not busy then
        C.refresh()
    end
    -- the search box
    local fw = math.min(S(280), w - S(26) - L.pix_tight_width('VANASTORE', 3) - S(40) - (size + S(4)) * 3 - S(40))
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
            st.rect = { x = x, y = y, w = w, h = h }
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
            if imgui.IsWindowFocused(3) and imgui.IsKeyPressed(U.KEY_ESCAPE) and not L.typing() and not st.confirm then
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

-- A question over the store's window, before anything is fetched or written. Two things are asked this way: a takeover
-- (what this copy is, what the store will do, that nothing of the player's is lost), and an addon the site hasn't
-- reviewed (that it hasn't been, that an addon is a program, to install it only on trust in its author). A takeover
-- of an unreviewed addon says both. One button does it, one leaves things as they are.
local CONFIRM = {
    takeover = {
        'This copy came from the launcher, or was copied in by hand.',
        'VanaStore will replace it with the package from ffxiprivateservers.com, and keep it updated from now on.',
        'Your settings are kept.',
        'The old copy goes to backups\\addons in VanaCore\'s folder.',
    },
    unreviewed = {
        "FFXIPS hasn't reviewed this addon.",
        'An addon is a program: it runs inside the game and can do anything you can on this computer.',
    },
}
local function draw_confirm(t, dt)
    local c = st.confirm
    if c == nil then return end
    local a = D.by_slug[c.slug]
    local r = st.rect
    local taking = c.kind == 'takeover'
    if a == nil or r == nil or not st.open or a.locked or (taking and not a.takeover) then
        st.confirm = nil
        return
    end
    c.anim = math.min(1, (c.anim or 0) + dt * 7)
    local e = U.ease(c.anim)
    imgui.SetNextWindowPos({ r.x, r.y }, U.ALWAYS)
    imgui.SetNextWindowSize({ r.w, r.h }, U.ALWAYS)
    imgui.SetNextWindowFocus()
    U.set_window_alpha(C.alpha)
    U.push_theme()
    -- (4: it doesn't move; it sits on the store's window and takes its clicks while it is up)
    if imgui.Begin('##vanastore_confirm', nil, U.WINDOW_FLAGS + U.NO_SAVE + 4) then
        local drew, err = pcall(function ()
            local dl = imgui.GetWindowDrawList()
            dl:AddRectFilled({ r.x, r.y }, { r.x + r.w, r.y + r.h }, U.u32(K.bg0, 0.78 * e), S(16))
            local w = math.min(S(560), r.w - S(60))
            local tw = w - S(64)
            -- what is asked, in its words
            local eyebrow, heading, yes_label, no_label
            local texts = {}
            if taking then
                eyebrow = a.trusted and 'TAKE OVER' or 'TAKE OVER, NOT REVIEWED'
                heading = 'Let VanaStore take over ' .. a.title .. '?'
                yes_label, no_label = a.trusted and 'TAKE OVER' or 'TAKE OVER ANYWAY', 'Not now'
                for _, text in ipairs(CONFIRM.takeover) do texts[#texts + 1] = text end
            else
                local second = V.elsewhere_text(a)
                if second then
                    -- a copy is already here under another framework: said first
                    eyebrow = a.trusted and 'ALREADY INSTALLED' or 'ALREADY INSTALLED, NOT REVIEWED'
                    heading = 'Install a second copy of ' .. a.title .. '?'
                    yes_label, no_label = 'INSTALL A COPY', 'Cancel'
                    texts[#texts + 1] = second
                    texts[#texts + 1] = 'VanaCore loads the copy it finds first, so two of the same addon can get in each other\'s way.'
                else
                    eyebrow = 'NOT REVIEWED'
                    heading = (a.have and 'Update ' or 'Install ') .. a.title .. ' anyway?'
                    yes_label, no_label = a.have and 'UPDATE ANYWAY' or 'INSTALL ANYWAY', 'Cancel'
                end
            end
            if not a.trusted then
                for _, text in ipairs(CONFIRM.unreviewed) do texts[#texts + 1] = text end
                -- what the site's scan of its Lua found (nothing a reviewer has weighed yet)
                local strong, rest = D.flag_lines(a)
                if strong then texts[#texts + 1] = strong end
                if rest then texts[#texts + 1] = rest end
                texts[#texts + 1] = 'Install it only if you trust its author' .. (a.author ~= '' and (', ' .. a.author) or '') .. '.'
            end
            local title = U.wrap(heading, F.bold, T.h1, tw)
            local version = nil
            if a.version ~= '' then
                local over = (a.have and a.have ~= '?' and a.have ~= a.version) and (' in place of ' .. a.have) or ''
                version = 'Version ' .. a.version .. ' will be installed' .. over .. '.'
            end
            local points = {}
            for _, text in ipairs(texts) do points[#points + 1] = U.wrap(text, F.text, T.body, tw - S(18)) end
            local h = S(30) + S(22) + #title * S(30) + S(12) + S(22) + S(44) + S(30)
            for _, lines in ipairs(points) do h = h + #lines * S(22) + S(6) end
            if version then h = h + S(26) end
            local x, y = math.floor(r.x + (r.w - w) / 2), math.floor(r.y + (r.h - h) / 2 + (1 - e) * S(12))
            C.fade(e)
            U.shadow(dl, x, y, w, h, S(14), 1.4)
            U.panel(dl, x, y, w, h, P.glass, 1, S(14), U.mix(K.frame_light, K.line, 0.45))
            local cx, cy = x + S(32), y + S(30)
            L.eyebrow(dl, cx, cy, eyebrow, a.trusted and K.gold or K.dim)
            cy = cy + S(22)
            for _, line in ipairs(title) do
                U.text(dl, cx, cy, line, K.ink, F.bold, T.h1)
                cy = cy + S(30)
            end
            cy = cy + S(12)
            local u = L.px()
            for _, lines in ipairs(points) do
                dl:AddRectFilled({ L.round(cx + S(2)), L.round(cy + S(8)) }, { L.round(cx + S(2)) + 2 * u, L.round(cy + S(8)) + 2 * u },
                    U.u32(a.trusted and K.gold or K.dim))
                for _, line in ipairs(lines) do
                    U.text(dl, cx + S(18), cy, line, U.mix(K.ink, K.dim, 0.25), F.text, T.body)
                    cy = cy + S(22)
                end
                cy = cy + S(6)
            end
            if version then
                L.mono(dl, cx + S(18), cy + S(2), version, K.dim, T.small)
                cy = cy + S(26)
            end
            cy = cy + S(22) - S(6)
            -- the button that does it: the site's gold for a reviewed addon, the dark slab for one that isn't
            local bw = math.max(S(184), L.pix_width(yes_label, 1.5, 0.08) + S(44))
            local quiet = (not a.trusted) or (not taking and V.elsewhere_text(a) ~= nil)
            local yes = L.pixel_button(dl, '##vs_confirm_yes', cx, cy, bw, S(44), yes_label, quiet and { kind = 'dark', ink = K.ink } or nil)
            local no = L.quiet_button(dl, '##vs_confirm_no', cx + bw + S(22), cy + S(8), S(96), S(28), no_label, { color = K.dim })
            if PAD.capturing() then
                PAD.claim()
                if PAD.pressed('cancel') then no = true end
            end
            if imgui.IsKeyPressed(U.KEY_ESCAPE) then no = true end
            if yes then
                st.confirm = nil
                C.I.start(a, { adopt = taking or nil, accept_unreviewed = (not a.trusted) or nil, elsewhere_ok = true })
            elseif no then
                st.confirm = nil
            end
        end)
        if not drew then
            fail('confirm', err)
            st.confirm = nil
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
    C.I.tick()
    if st.open then D.look() end
    if st.open or st.anim > 0 then draw_main(t, dt) end
    if st.confirm then draw_confirm(t, dt) end
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
    elseif what == 'origin' then
        -- a developer's: the store pointed at a copy of the site (https, or http on this PC); "default" puts it back
        ledger.data.origin = (rest == '' or rest:lower() == 'default') and '' or rest
        local now = D.set_origin(ledger.data.origin)
        if ledger.data.origin ~= '' and now ~= ledger.data.origin:gsub('/+$', '') then ledger.data.origin = '' end
        ledger:save()
        D.state = 'empty'
        D.fetch()
        say('the catalog comes from ' .. now)
    else
        for _, line in ipairs(HELP) do vana.chat.write(line, 106) end
    end
    return true
end)

vana.events.on('load', function ()
    L.apply()
    PAD.setup('vanastore', U)
    if type(ledger.data.installed) ~= 'table' then ledger.data.installed = {} end
    C.records = ledger.data.installed
    D.records = C.records
    D.set_origin(ledger.data.origin)
    D.on_catalog = function ()
        D.look(true)
        st.grid_at = clock()
    end
    C.I = require('install')(C)
    V = require('views')(C)
    C.V = V
    st.view = (cfg.view == 'installed' or cfg.view == 'updates') and cfg.view or 'all'
end)

vana.events.on('unload', function ()
    pcall(PAD.teardown, 'vanastore')
    pcall(D.release_pictures)
    pcall(U.release_textures)
end)
