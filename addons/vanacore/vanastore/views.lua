-- The store's pages: the rail, the grid with its featured card, an addon's own page, the settings and the footer.
-- Loaded by vanastore.lua with the table every part shares (C).
local imgui = vana.imgui

return function (C)
    local U, L, D, PAD = C.U, C.L, C.D, C.PAD
    local P, F, T = U.P, U.fonts(), U.sizes()
    local S, u32, mix = U.S, U.u32, U.mix
    local K = L.C -- the site's colours
    local cfg, st = C.cfg, C.st

    local V = {}

    local function hover_of(key) return U.anim.hover[key] or 0 end

    ---------------------------------------------------------------------------
    -- The one control an addon has: Install, Update, or its switch
    ---------------------------------------------------------------------------

    local JOB_LABEL = { download = 'Downloading', verify = 'Checking', install = 'Installing' }
    local JOB_PIX = { download = 'DOWNLOADING', verify = 'CHECKING', install = 'INSTALLING' }

    -- what an addon's control says and does now
    local function state_of(a)
        local job = C.jobs[a.slug]
        if job and JOB_LABEL[job.state] then return 'busy', job end
        if a.have == nil then return 'install', job end
        if a.update then return 'update', job end
        return 'switch', job
    end

    -- the card's: a quiet button or the switch, its right edge at `right`
    local function card_action(dl, a, key, right, cy)
        local kind, job = state_of(a)
        local bw, bh = S(88), S(28)
        if kind == 'busy' then
            L.quiet_button(dl, key, right - S(112), cy - bh / 2, S(112), bh, JOB_LABEL[job.state], { progress = job.progress, disabled = true })
        elseif kind == 'install' then
            if L.quiet_button(dl, key, right - bw, cy - bh / 2, bw, bh, 'Install') then C.install(a) end
        elseif kind == 'update' then
            if L.quiet_button(dl, key, right - bw, cy - bh / 2, bw, bh, 'Update', { tip = 'You have ' .. tostring(a.have) }) then C.install(a) end
        else
            local label = a.loaded and 'On' or 'Off'
            local lw = U.measure(label, F.semi, T.small) + S(8)
            local _, pressed = L.switch(dl, key, right - S(38) - lw, cy, a.loaded, label, a.loaded and 'Loaded, and at every start' or 'Installed, not loaded')
            if pressed then C.switch(a, not a.loaded) end
        end
    end

    -- the primary one, in the site's button; returns the width it took
    local function primary_action(dl, a, key, x, y)
        local kind, job = state_of(a)
        local w, h = S(184), S(44)
        if kind == 'busy' then
            L.pixel_button(dl, key, x, y, w, h, JOB_PIX[job.state], { progress = job.progress, disabled = true })
        elseif kind == 'install' then
            if L.pixel_button(dl, key, x, y, w, h, 'INSTALL') then C.install(a) end
        elseif kind == 'update' then
            if L.pixel_button(dl, key, x, y, w, h, 'UPDATE') then C.install(a) end
        else
            local cw, ch = L.chip_size('INSTALLED')
            L.chip(dl, x, y + (h - ch) / 2, 'INSTALLED', 'teal')
            local label = a.loaded and 'On' or 'Off'
            local _, pressed, sw = L.switch(dl, key, x + cw + S(18), y + h / 2, a.loaded, label, a.loaded and 'Loaded, and at every start' or 'Installed, not loaded')
            if pressed then C.switch(a, not a.loaded) end
            return cw + S(18) + sw
        end
        return w
    end

    -- "Trusted" or "Pending review", as the site says it
    local function status_chip(dl, x, y, a, alpha)
        if a.status == 'trusted' then return L.chip(dl, x, y, 'TRUSTED', 'quiet', alpha) end
        return L.chip(dl, x, y, 'PENDING REVIEW', 'faint', alpha)
    end

    -- v1.0.2, and what you have when it differs
    local function version_text(a)
        if a.update then return 'v' .. a.version, 'you have ' .. tostring(a.have) end
        return 'v' .. a.version, nil
    end

    -- an addon's picture (its nth), or the stand-in; fades in as its texture arrives
    local function picture(dl, a, n, x, y, w, h, thumb, alpha, rounding, corners)
        local shot = a.shots[n or 1]
        local tex, at = nil, nil
        if shot then tex, at = D.picture(thumb and shot.thumb or shot.url) end
        if tex then
            local fade = U.ease((U.clock() - at) / 0.25)
            if fade < 1 then L.placeholder(dl, x, y, w, h, a.title, alpha, rounding, corners) end
            L.cover(dl, tex, shot.w, shot.h, x, y, w, h, (alpha or 1) * fade, rounding, corners)
        else
            L.placeholder(dl, x, y, w, h, a.title, alpha, rounding, corners)
        end
    end

    ---------------------------------------------------------------------------
    -- The rail
    ---------------------------------------------------------------------------

    local function rail_item(dl, key, x, y, w, label, cp, on, count, strong)
        local h = S(34)
        imgui.SetCursorScreenPos({ x, y })
        local pressed, _, hv = U.hit(key, w, h, S(8))
        if on then
            dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(K.hot, 0.10), S(8))
            local u = L.px()
            dl:AddRectFilled({ L.round(x), L.round(y + S(9)) }, { L.round(x) + u, L.round(y + h - S(9)) }, u32(K.hot))
        elseif hv > 0.01 then
            dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(K.bg2, 0.6 * hv), S(8))
        end
        local col = on and K.hot or mix(K.dim, K.ink, hv)
        L.icon(dl, x + S(20), y + h / 2, cp, col, T.small, on and 1 or 0.8)
        U.text_mid(dl, x + S(38), y + h / 2, label, col, on and F.semi or F.text, T.body - 1)
        if count and count > 0 then
            local s = tostring(count)
            local cw = L.mono_width(s, T.tiny, true)
            if strong then
                local pw = cw + S(12)
                dl:AddRectFilled({ x + w - S(10) - pw, y + h / 2 - S(9) }, { x + w - S(10), y + h / 2 + S(9) }, u32(K.gold), S(9))
                L.mono_mid(dl, x + w - S(10) - pw + S(6), y + h / 2, s, K.on_gold, T.tiny, 1, true)
            else
                L.mono_mid(dl, x + w - S(14) - cw, y + h / 2, s, on and K.hot or K.faint, T.tiny, 1, true)
            end
        end
        return pressed, h
    end

    local function set_view(view, compat)
        if st.view ~= view or st.compat ~= compat or st.detail then
            st.view, st.compat, st.detail = view, compat, nil
            st.grid_at = U.clock()
            st.scroll_top = true
            cfg.view = view
        end
        st.settings_open = false
    end
    V.set_view = set_view

    function V.rail(dl, x, y, w)
        local counts = D.counts or { all = 0, installed = 0, updates = 0 }
        local cy = y + S(2)
        L.eyebrow(dl, x + S(10), cy, 'BROWSE', K.dim)
        cy = cy + S(22)
        local pressed, h
        pressed, h = rail_item(dl, '##vs_r_all', x, cy, w, 'All addons', L.CP.cubes, st.view == 'all', counts.all)
        if pressed then set_view('all', st.compat) end
        cy = cy + h + S(2)
        pressed, h = rail_item(dl, '##vs_r_inst', x, cy, w, 'Installed', L.CP.check, st.view == 'installed', counts.installed)
        if pressed then set_view('installed', st.compat) end
        cy = cy + h + S(2)
        pressed, h = rail_item(dl, '##vs_r_upd', x, cy, w, 'Updates', L.CP.circle_up, st.view == 'updates', counts.updates, true)
        if pressed then set_view('updates', st.compat) end
        cy = cy + h + S(22)
        L.eyebrow(dl, x + S(10), cy, 'COMPATIBILITY', K.dim)
        cy = cy + S(22)
        pressed, h = rail_item(dl, '##vs_r_gen', x, cy, w, 'General', L.CP.globe, st.compat == 'general')
        if pressed then set_view(st.view, st.compat ~= 'general' and 'general' or nil) end
        cy = cy + h + S(2)
        pressed, h = rail_item(dl, '##vs_r_srv', x, cy, w, 'Server-specific', L.CP.server, st.compat == 'server')
        if pressed then set_view(st.view, st.compat ~= 'server' and 'server' or nil) end
    end

    ---------------------------------------------------------------------------
    -- Cards
    ---------------------------------------------------------------------------

    local CARD = { min_w = 244, gap = 16, text_h = 150 }

    -- the featured card: the one thing in the window, with the primary button, that wears the site's pixel frame
    local function featured(dl, a, x, y, w, t)
        local h = S(236)
        local key = '##vs_feat_' .. a.slug
        local hv = hover_of(key)
        local inset = L.frame(dl, x, y, w, h, K.panel, hv)
        local ix, iy, iw, ih = x + inset, y + inset, w - inset * 2, h - inset * 2
        -- its picture, as wide as 16:10 of its height, a hair of dark between it and the words
        local pw = math.min(math.floor(ih * 1.6), math.floor(iw * 0.46))
        picture(dl, a, 1, ix, iy, pw, ih, false, 1)
        dl:AddRectFilled({ ix + pw, iy }, { ix + pw + L.px(), iy + ih }, u32(K.frame_mid))
        dl:AddRectFilled({ ix, iy }, { ix + pw, iy + ih }, u32(K.bg0, 0.10 * (1 - hv)))
        local tx, tw = ix + pw + S(24), iw - pw - S(48)
        local cy = iy + S(20)
        L.eyebrow(dl, tx, cy, 'FEATURED', K.gold)
        cy = cy + S(20)
        U.text(dl, tx, cy, U.fit(a.title, F.bold, T.h1, tw), K.ink, F.bold, T.h1)
        cy = cy + S(30)
        local by = 'by ' .. a.author
        U.text(dl, tx, cy, by, K.dim, F.text, T.small)
        local ver, have = version_text(a)
        local vx = tx + U.measure(by, F.text, T.small) + S(12)
        L.mono(dl, vx, cy, ver, K.dim, T.small)
        if have then L.mono(dl, vx + L.mono_width(ver, T.small) + S(10), cy, have, K.gold, T.small) end
        cy = cy + S(26)
        local lines = U.wrap(a.summary, F.text, T.body, tw)
        for i = 1, math.min(2, #lines) do
            local line = lines[i]
            if i == 2 and #lines > 2 then line = U.fit(line .. ' …', F.text, T.body, tw) end
            U.text(dl, tx, cy, line, mix(K.ink, K.dim, 0.25), F.text, T.body)
            cy = cy + S(22)
        end
        -- the bottom row: the button, then how it stands on the site
        local by2 = iy + ih - S(22) - S(44)
        local used = primary_action(dl, a, key .. '_act', tx, by2)
        local job = C.jobs[a.slug]
        if job and job.state == 'refused' then
            -- why it wasn't installed, where the chip was
            U.text_mid(dl, tx + used + S(20), by2 + S(22), U.fit(job.why, F.text, T.small, tw - used - S(20)), K.red, F.text, T.small)
        else
            local _, chh = L.chip_size('TRUSTED')
            status_chip(dl, tx + used + S(20), by2 + (S(44) - chh) / 2, a)
        end
        imgui.SetCursorScreenPos({ x, y })
        if U.hit(key, w, h, 0) then C.open_detail(a) end
        return h
    end

    local function card(dl, a, x, y, w, h, i, t)
        local key = '##vs_card_' .. a.slug
        local hv = hover_of(key)
        local r = S(10)
        local lift = S(2) * hv
        y = y - lift
        if hv > 0.01 then U.shadow(dl, x, y, w, h, r, 0.9 * hv) end
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(K.panel, K.panel2, 0.35 * hv)), r)
        local th = math.floor(w * 9 / 16)
        picture(dl, a, 1, x + 1, y + 1, w - 2, th, true, 1, r - 1, 48) -- (48: the top corners)
        dl:AddRectFilled({ x + 1, y + 1 }, { x + w - 1, y + th + 1 }, u32(K.bg0, 0.16 * (1 - hv)), r - 1, 48)
        dl:AddLine({ x + 1, y + th + 1 }, { x + w - 1, y + th + 1 }, u32(K.frame_dark, 0.6), 1)
        -- its quiet edge, gold under the pointer
        dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(K.line, K.gold, hv), 0.95), r, 240, 1)
        local px, pw = x + S(14), w - S(28)
        local cy = y + th + S(13)
        local ver, have = version_text(a)
        local vw = L.mono_width(ver, T.small)
        U.text(dl, px, cy, U.fit(a.title, F.semi, T.body, pw - vw - S(10)), mix(K.ink, K.hot, hv), F.semi, T.body)
        L.mono(dl, px + pw - vw, cy + S(2), ver, K.dim, T.small)
        cy = cy + S(22)
        U.text(dl, px, cy, U.fit('by ' .. a.author, F.text, T.small, pw), K.dim, F.text, T.small)
        if have then
            local hw = L.mono_width(have, T.small)
            L.mono(dl, px + pw - hw, cy, have, K.gold, T.small)
        end
        cy = cy + S(24)
        local lines = U.wrap(a.summary, F.text, T.small, pw)
        for n = 1, math.min(2, #lines) do
            local line = lines[n]
            if n == 2 and #lines > 2 then line = U.fit(line .. ' …', F.text, T.small, pw) end
            U.text(dl, px, cy, line, mix(K.ink, K.dim, 0.45), F.text, T.small)
            cy = cy + S(18)
        end
        -- the bottom row
        local by = y + h - S(14) - S(14)
        local job = C.jobs[a.slug]
        if job and job.state == 'refused' then
            U.text_mid(dl, px, by, U.fit(job.why, F.text, T.small, pw - S(100)), K.red, F.text, T.small)
        else
            local _, chh = L.chip_size('TRUSTED')
            status_chip(dl, px, by - chh / 2, a)
        end
        card_action(dl, a, key .. '_act', x + w - S(14), by)
        imgui.SetCursorScreenPos({ x, y + lift })
        if U.hit(key, w, h, r, { x = x, y = y, w = w, h = h }) then C.open_detail(a) end
    end

    -- nothing to show, said plainly
    local function empty(dl, x, y, w, line, sub)
        L.icon(dl, x + w / 2, y + S(34), L.CP.box, K.faint, 26, 0.7)
        U.text_center(dl, x, y + S(74), w, line, K.dim, F.semi, T.body)
        if sub then U.text_center(dl, x, y + S(98), w, sub, K.faint, F.text, T.small) end
    end

    ---------------------------------------------------------------------------
    -- The grid page
    ---------------------------------------------------------------------------

    local function grid_page(dl, ox, oy, w, view_h, scroll, t)
        local at = 0
        local query = st.query[1] or ''
        local list = D.filter(st.view, st.compat, query)
        local plain = st.view == 'all' and st.compat == nil and query:gsub('%s', '') == ''
        local feat = plain and D.featured() or nil
        local base = U.ease((U.clock() - (st.grid_at or 0)) / 0.3)
        if feat then
            C.fade(base)
            at = at + S(4)
            local ok, h = pcall(featured, dl, feat, ox + S(2), oy + at - (1 - base) * S(8), w - S(8), t)
            if not ok then C.fail('featured', h) h = S(236) end
            at = at + h + S(30)
            C.fade(1)
        end
        -- the heading over the cards: what is shown, and how many
        local heading = st.view == 'installed' and 'INSTALLED' or st.view == 'updates' and 'UPDATES' or 'ALL ADDONS'
        if query:gsub('%s', '') ~= '' then heading = 'SEARCH' end
        L.eyebrow(dl, ox + S(2), oy + at + S(2), heading, K.dim)
        local count = #list == 1 and '1 addon' or (#list .. ' addons')
        if st.compat then count = count .. (st.compat == 'general' and ', general' or ', server-specific') end
        local cw = U.measure(count, F.text, T.small)
        U.text(dl, ox + w - S(8) - cw, oy + at - S(2), count, K.faint, F.text, T.small)
        at = at + S(26)
        if #list == 0 then
            local line, sub = 'No addons here yet.', nil
            if query:gsub('%s', '') ~= '' then line, sub = 'Nothing matches "' .. query .. '".', 'Try a shorter word, or look in All addons.'
            elseif st.view == 'updates' then line, sub = 'Everything is up to date.', nil
            elseif st.view == 'installed' then line, sub = 'Nothing from the store is installed yet.', 'Addons you install show here, with their switches.' end
            empty(dl, ox, oy + at + S(30), w - S(8), line, sub)
            return at + S(200)
        end
        local gap = S(CARD.gap)
        local room = w - S(8)
        local cols = math.max(1, math.floor((room + gap) / (S(CARD.min_w) + gap)))
        local card_w = math.floor((room - gap * (cols - 1)) / cols)
        local card_h = math.floor(card_w * 9 / 16) + S(CARD.text_h)
        for i, a in ipairs(list) do
            local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
            local cx, cy = ox + S(2) + col * (card_w + gap), oy + at + row * (card_h + gap)
            if cy + card_h >= oy + scroll - S(40) and cy <= oy + scroll + view_h + S(40) then
                local a_in = U.ease((U.clock() - (st.grid_at or 0) - 0.05 - (i - 1) * 0.035) / 0.3)
                C.fade(a_in)
                local ok, err = pcall(card, dl, a, cx, cy + (1 - a_in) * S(10), card_w, card_h, i, t)
                if not ok then C.fail('card', err) end
                C.fade(1)
            end
        end
        local rows = math.ceil(#list / cols)
        return at + rows * (card_h + gap)
    end

    ---------------------------------------------------------------------------
    -- An addon's own page
    ---------------------------------------------------------------------------

    local function fact(dl, x, y, w, name, value, color)
        U.text(dl, x, y, name, K.faint, F.text, T.small)
        local vw = L.mono_width(value, T.small)
        L.mono(dl, x + w - vw, y, value, color or K.ink, T.small)
        dl:AddLine({ x, y + S(22) }, { x + w, y + S(22) }, u32(K.line, 0.7), 1)
        return S(30)
    end

    -- the description: paragraphs, and lines that start with "- " as a list with the site's square bullets
    local function description(dl, x, y, w, text)
        local cy = y
        for para in (text .. '\n'):gmatch('(.-)\n') do
            if para:match('^%s*$') then
                cy = cy + S(10)
            else
                local bullet = para:match('^%s*[-*]%s+(.*)$')
                local tx, tw = x, w
                if bullet then
                    local u = L.px()
                    tx, tw = x + S(18), w - S(18)
                    dl:AddRectFilled({ L.round(x + S(4)), L.round(cy + S(8)) }, { L.round(x + S(4)) + 2 * u, L.round(cy + S(8)) + 2 * u }, u32(K.gold))
                end
                for _, line in ipairs(U.wrap(bullet or para, F.text, T.body, tw)) do
                    U.text(dl, tx, cy, line, mix(K.ink, K.dim, 0.2), F.text, T.body)
                    cy = cy + S(23)
                end
                cy = cy + S(3)
            end
        end
        return cy - y
    end

    local function detail_page(dl, a, ox, oy, w, view_h, scroll, t)
        local room = w - S(8)
        local x = ox + S(2)
        local at = 0
        local back = st.view == 'installed' and 'Installed' or st.view == 'updates' and 'Updates' or 'All addons'
        if L.link(dl, '##vs_back', x, oy + at + S(12), back, { icon = L.CP.back, size = T.small, font = F.semi }) then C.close_detail() end
        at = at + S(34)
        -- the pictures on the left, the facts on the right
        local side = math.max(S(250), math.floor(room * 0.34))
        local pw = room - side - S(28)
        local ph = math.floor(pw * 10 / 16)
        local px, py = x, oy + at
        dl:AddRectFilled({ px, py }, { px + pw, py + ph }, u32(K.bg0), S(10))
        local n = math.max(1, math.min(st.shot or 1, math.max(1, #a.shots)))
        local shot = a.shots[n]
        local tex, tex_at = nil, nil
        if shot then tex, tex_at = D.picture(shot.url) end
        if tex then
            local fade = U.ease((U.clock() - math.max(tex_at, st.shot_at or 0)) / 0.25)
            L.contain(dl, tex, shot.w, shot.h, px + S(1), py + S(1), pw - S(2), ph - S(2), fade)
        else
            L.placeholder(dl, px, py, pw, ph, a.title, 1, S(10))
        end
        dl:AddRect({ px, py }, { px + pw, py + ph }, u32(K.line), S(10), 240, 1)
        local left_h = ph
        if #a.shots > 1 then
            -- its other pictures, small, under it
            local tw2, gap = S(92), S(10)
            local th2 = math.floor(tw2 * 10 / 16)
            local ty = py + ph + S(12)
            for i, s in ipairs(a.shots) do
                local tx = px + (i - 1) * (tw2 + gap)
                local key = '##vs_shot_' .. i
                local hv = hover_of(key)
                local ttex = D.picture(s.thumb)
                if ttex then L.cover(dl, ttex, s.w, s.h, tx, ty, tw2, th2, i == n and 1 or 0.6 + 0.4 * hv, S(6), 240)
                else L.placeholder(dl, tx, ty, tw2, th2, a.title, 1, S(6)) end
                dl:AddRect({ tx, ty }, { tx + tw2, ty + th2 }, u32(i == n and K.gold or mix(K.line, K.gold, hv)), S(6), 240, i == n and math.max(1, S(1.5)) or 1)
                imgui.SetCursorScreenPos({ tx, ty })
                if U.hit(key, tw2, th2, S(6)) and i ~= n then st.shot, st.shot_at = i, U.clock() end
            end
            left_h = ph + S(12) + th2
        end
        -- the right column
        local sx, sw = px + pw + S(28), side
        local cy = py + S(2)
        L.eyebrow(dl, sx, cy, a.compatibility == 'server' and ('FOR ' .. (a.server or 'ONE SERVER'):upper()) or 'ANY SERVER')
        cy = cy + S(22)
        for _, line in ipairs(U.wrap(a.title, F.bold, T.title - 2, sw)) do
            U.text(dl, sx, cy, line, K.ink, F.bold, T.title - 2)
            cy = cy + S(34)
        end
        U.text(dl, sx, cy, 'by ' .. a.author, K.dim, F.text, T.body)
        cy = cy + S(30)
        status_chip(dl, sx, cy, a)
        cy = cy + S(36)
        primary_action(dl, a, '##vs_detail_act', sx, cy)
        cy = cy + S(44) + S(14)
        local job = C.jobs[a.slug]
        if job and job.state == 'refused' then
            for _, line in ipairs(U.wrap(job.why, F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.red, F.text, T.small)
                cy = cy + S(18)
            end
            cy = cy + S(6)
        else
            cy = cy + S(8)
        end
        cy = cy + fact(dl, sx, cy, sw, 'Version', a.version)
        if a.have then cy = cy + fact(dl, sx, cy, sw, 'You have', tostring(a.have), a.update and K.gold or K.teal) end
        cy = cy + fact(dl, sx, cy, sw, 'Size', D.size_text(a.package.size))
        cy = cy + fact(dl, sx, cy, sw, 'Updated', D.date_text(a.updated))
        if a.downloads then cy = cy + fact(dl, sx, cy, sw, 'Downloads', tostring(a.downloads)) end
        cy = cy + S(6)
        if a.page and L.link(dl, '##vs_page', sx, cy + S(10), 'View on FFXIPS', { icon = L.CP.link, icon_after = true, size = T.small, font = F.semi,
            color = K.gold, tip = a.page }) then C.open_page(a.page) end
        cy = cy + S(28)
        at = at + math.max(left_h, cy - py) + S(30)
        -- about it
        L.eyebrow(dl, x, oy + at, 'ABOUT', K.dim)
        at = at + S(24)
        at = at + description(dl, x, oy + at, math.min(room, S(660)), a.description)
        return at + S(16)
    end

    ---------------------------------------------------------------------------
    -- The main area: one scrolling page
    ---------------------------------------------------------------------------

    function V.main(dl, x, y, w, h, t, dt)
        imgui.SetCursorScreenPos({ x, y })
        -- 256: NavFlattened, so the controller's focus moves through the cards as through the window's own
        if imgui.BeginChild('##vs_main', { w, h }, 256, 0) then
            local ok, err = pcall(function ()
                local cdl = imgui.GetWindowDrawList()
                local ox, oy = imgui.GetCursorScreenPos()
                if st.scroll_top then
                    imgui.SetScrollY(0)
                    st.scroll_top = nil
                elseif st.scroll_to then
                    imgui.SetScrollY(S(st.scroll_to)) -- (a test's: how far down the page, in the window's own units)
                    st.scroll_to = nil
                end
                local scroll = imgui.GetScrollY()
                local inner = w - S(12)
                local used
                local a = st.detail and D.by_slug[st.detail] or nil
                if a then
                    local in_a = U.ease((U.clock() - (st.detail_at or 0)) / 0.25)
                    C.fade(in_a)
                    used = detail_page(cdl, a, ox, oy + (1 - in_a) * S(10), inner, h, scroll, t)
                    C.fade(1)
                else
                    used = grid_page(cdl, ox, oy, inner, h, scroll, t)
                end
                imgui.SetCursorScreenPos({ ox, oy + used })
                imgui.Dummy({ 1, S(8) })
                -- the page slips under a soft edge at the top and the bottom, where there is more of it
                local top, edge = oy + scroll, S(18)
                local more = math.max(0, math.min(1, (used + S(8) - scroll - h) / edge))
                local over = math.max(0, math.min(1, scroll / edge))
                C.fade(1)
                if over > 0 then
                    cdl:AddRectFilledMultiColor({ x, top }, { x + inner + S(4), top + edge }, u32(P.bg, over), u32(P.bg, over), u32(P.bg, 0), u32(P.bg, 0))
                end
                if more > 0 then
                    cdl:AddRectFilledMultiColor({ x, top + h - edge }, { x + inner + S(4), top + h }, u32(P.bg, 0), u32(P.bg, 0), u32(P.bg, more), u32(P.bg, more))
                end
                if C.pad_on then
                    local _, _, _, ry = PAD.stick()
                    if math.abs(ry) > 0 then imgui.SetScrollY(math.max(0, scroll - ry * S(900) * dt)) end
                end
            end)
            if not ok then C.fail('page', err) end
        end
        imgui.EndChild()
        C.fade(1)
    end

    ---------------------------------------------------------------------------
    -- Settings
    ---------------------------------------------------------------------------

    function V.settings(dl, x, y, w, h)
        U.panel(dl, x, y, w, h, P.glass, 1, S(12), P.line)
        local cx, cy = x + S(28), y + S(26)
        L.eyebrow(dl, cx, cy, 'SETTINGS', K.dim)
        cy = cy + S(34)
        local label_w, track = S(130), math.min(S(320), w - S(260))
        U.text_mid(dl, cx, cy, 'Size', K.ink, F.text, T.body)
        local shown = st.scale_edit or C.scale_now()
        local v, moved, released = U.slider(dl, '##vs_scale', cx + label_w, cy, track, shown, 60, 250, '%.0f%%')
        if moved then st.scale_edit = math.floor(v / 5 + 0.5) * 5 end
        if released and st.scale_edit then
            cfg.scale = st.scale_edit
            st.scale_edit = nil
            C.save()
        end
        if cfg.scale ~= 0 then
            if L.link(dl, '##vs_scale_auto', cx + label_w + track + S(74), cy, 'Fit the screen', { size = T.small }) then
                cfg.scale = 0
                C.save()
            end
        else
            U.text_mid(dl, cx + label_w + track + S(74), cy, 'fits the screen', K.faint, F.text, T.small)
        end
        cy = cy + S(44)
        U.text_mid(dl, cx, cy, 'Opacity', K.ink, F.text, T.body)
        local ov, omoved, oreleased = U.slider(dl, '##vs_opacity', cx + label_w, cy, track, cfg.opacity, 40, 100, '%.0f%%')
        if omoved then cfg.opacity = math.floor(ov + 0.5) end
        if oreleased then C.save() end
        cy = cy + S(44)
        U.text_mid(dl, cx, cy, 'Controller', K.ink, F.text, T.body)
        local pad_on = PAD.enabled()
        local nv = L.switch(dl, '##vs_pad', cx + label_w, cy, pad_on, nil, 'Move through the store with a controller')
        if nv ~= pad_on then PAD.set_enabled(nv) end
        U.text_mid(dl, cx + label_w + S(50), cy, 'for every addon window', K.faint, F.text, T.small)
        cy = cy + S(56)
        dl:AddLine({ cx, cy }, { x + w - S(28), cy }, u32(K.line, 0.8), 1)
        cy = cy + S(20)
        local about = 'VanaStore ' .. tostring(C.version) .. '. Addons are listed, checked and hosted by ffxiprivateservers.com; '
            .. 'the store installs only what that list names, and only when the download matches its checksum.'
        for _, line in ipairs(U.wrap(about, F.text, T.small, w - S(56))) do
            U.text(dl, cx, cy, line, K.dim, F.text, T.small)
            cy = cy + S(19)
        end
        if D.stub then
            cy = cy + S(8)
            U.text(dl, cx, cy, 'Showing the preview catalog that ships with the store.', K.faint, F.text, T.small)
        end
    end

    ---------------------------------------------------------------------------
    -- The footer
    ---------------------------------------------------------------------------

    function V.footer(dl, x, y, w, h)
        local cy = y + h / 2
        local a = st.detail and D.by_slug[st.detail] or nil
        local url = (a and a.page) or 'https://ffxiprivateservers.com/addons'
        if L.link(dl, '##vs_powered', x, cy, 'Powered by FFXIPrivateServers.com', { size = T.small, tip = url }) then C.open_page(url) end
        local status
        if D.state == 'failed' then status = "Couldn't read the catalog"
        elseif D.stub then status = 'Preview catalog'
        else status = 'Catalog ' .. D.date_text((D.generated or ''):sub(1, 10)) end
        local sw = L.mono_width(status, T.tiny)
        L.mono_mid(dl, x + w - sw - S(22), cy, status, D.state == 'failed' and K.red or K.faint, T.tiny)
    end

    return V
end
