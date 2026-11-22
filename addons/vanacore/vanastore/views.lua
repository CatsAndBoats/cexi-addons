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

    local FOREIGN = "Installed by the launcher or by hand, so it's updated there, not by the store."
    local FOREIGN_TAKE = 'Installed by the launcher or by hand. VanaStore can take it over and keep it updated.'
    local function switch_tip(a)
        if a.foreign then return a.takeover and FOREIGN_TAKE or FOREIGN end
        return a.loaded and 'Loaded, and at every start' or 'Installed, not loaded'
    end

    -- a job's progress for a button: how far, or -1 while that isn't known (a band sweeps across it)
    local function progress_of(job) return job.progress or -1 end

    -- what an addon's control says and does now
    local function state_of(a)
        local job = C.jobs[a.slug]
        if job and JOB_LABEL[job.state] then return 'busy', job end
        -- (an addon the store doesn't install: its page on the site for a new one, the switch alone for one that's here)
        if a.have == nil then return a.locked and 'locked' or 'install', job end
        if a.update and not a.locked then return 'update', job end
        -- (a copy the store didn't install, behind the site's: taking it over is how it's brought up to date)
        if a.takeover and a.behind then return 'takeover', job end
        return 'switch', job
    end

    -- why the store doesn't install an addon: a chip's words (none where the card says it another way), and a sentence
    local LOCKED = {
        denied = { 'NOT APPROVED', "FFXIPS reviewed this addon and did not approve it, so the store doesn't install it." },
        hosted = { 'ON THE SITE ONLY', "FFXIPS doesn't host this file itself, so the store can't check it. Its page on the site has the link." },
        package = { 'ON THE SITE ONLY', "The catalog gives no checksum for this file, so the store can't check it. Its page on the site has the link." },
        plugin = { 'NATIVE CODE', "It holds a native program (a plugin, a DLL or the like), which the store doesn't install. Its page on the site has the file." },
        reserved = { nil, "It carries the name of one of VanaCore's own addons or libraries, which no package may replace." },
        scan = { 'NOT SCANNED', "The site's virus scan hasn't passed this file, so the store doesn't install it." },
        framework = { nil, "This VanaCore can't install this kind of addon. Its page on the site has the file." },
    }
    local UNREVIEWED = "FFXIPS hasn't reviewed this addon. Install it only if you trust its author."

    -- a copy of the same name in another framework's folder (the launcher keeps some addons under another framework
    -- than the site lists them for): said, so a second copy is never installed unawares
    local function elsewhere_of(a)
        if a.have ~= nil or a.elsewhere == nil or #a.elsewhere == 0 then return nil end
        return 'addons\\' .. table.concat(a.elsewhere, ', addons\\')
    end
    local function elsewhere_text(a)
        local where = elsewhere_of(a)
        if where == nil then return nil end
        return 'A copy of this addon is already in ' .. where .. '. The site lists it for ' .. a.framework_name
            .. ', so installing puts a second copy in addons\\' .. tostring(a.dir) .. '.'
    end
    V.elsewhere_text = elsewhere_text

    -- "View on FFXIPS", its right edge at `right`: where an addon the store doesn't install is had
    local function page_link(dl, a, key, right, cy, tip)
        if a.page == nil then return end
        local label = 'View on FFXIPS'
        local tw, th = U.measure(label, F.semi, T.small)
        local x = right - tw - th - S(4)
        if L.link(dl, key, x, cy, label, { icon = L.CP.link, icon_after = true, size = T.small, font = F.semi, tip = tip }) then
            C.open_page(a.page)
        end
        return x
    end

    -- the card's: a quiet button or the switch, its right edge at `right`. An addon the site hasn't reviewed has the
    -- same button in dim ink, not gold: it can be had, and isn't offered as the reviewed ones are. Returns its left edge.
    local function card_action(dl, a, key, right, cy)
        local kind, job = state_of(a)
        local bw, bh = S(88), S(28)
        local col = (a.trusted and elsewhere_of(a) == nil) and K.gold or K.dim
        if kind == 'locked' then
            if a.locked ~= 'denied' and a.locked ~= 'scan' and a.page then return page_link(dl, a, key, right, cy, LOCKED[a.locked][2]) end
            return right
        elseif kind == 'busy' then
            L.quiet_button(dl, key, right - S(112), cy - bh / 2, S(112), bh, JOB_LABEL[job.state], { progress = progress_of(job), disabled = true })
            return right - S(112)
        elseif kind == 'install' then
            if L.quiet_button(dl, key, right - bw, cy - bh / 2, bw, bh, 'Install', { color = col }) then C.install(a) end
        elseif kind == 'update' then
            if L.quiet_button(dl, key, right - bw, cy - bh / 2, bw, bh, 'Update', { color = col, tip = 'You have ' .. tostring(a.have) }) then C.install(a) end
        elseif kind == 'takeover' then
            if L.quiet_button(dl, key, right - S(104), cy - bh / 2, S(104), bh, 'Take over', { color = col, tip = FOREIGN_TAKE }) then C.ask_takeover(a) end
            return right - S(104)
        else
            local label = a.loaded and 'On' or 'Off'
            local lw = U.measure(label, F.semi, T.small) + S(8)
            local _, pressed = L.switch(dl, key, right - S(38) - lw, cy, a.loaded, label, switch_tip(a))
            if pressed then C.switch(a, not a.loaded) end
            return right - S(38) - lw
        end
        return right - bw
    end

    -- the primary one, in the site's button (gold for a reviewed addon, the dark slab for one that isn't); returns the
    -- width it took
    local function primary_action(dl, a, key, x, y)
        local kind, job = state_of(a)
        local w, h = S(184), S(44)
        local look = (not a.trusted or elsewhere_of(a) ~= nil) and { kind = 'dark', ink = K.ink } or nil
        if kind == 'locked' then
            return 0 -- (nothing to press: the page says why in a sentence)
        elseif kind == 'busy' then
            L.pixel_button(dl, key, x, y, w, h, JOB_PIX[job.state], { progress = progress_of(job), disabled = true })
        elseif kind == 'install' then
            if L.pixel_button(dl, key, x, y, w, h, 'INSTALL', look) then C.install(a) end
        elseif kind == 'update' then
            if L.pixel_button(dl, key, x, y, w, h, 'UPDATE', look) then C.install(a) end
        elseif kind == 'takeover' then
            if L.pixel_button(dl, key, x, y, w, h, 'TAKE OVER', look) then C.ask_takeover(a) end
        else
            local cw, ch = L.chip_size('INSTALLED')
            L.chip(dl, x, y + (h - ch) / 2, 'INSTALLED', 'teal')
            local label = a.loaded and 'On' or 'Off'
            local _, pressed, sw = L.switch(dl, key, x + cw + S(18), y + h / 2, a.loaded, label, switch_tip(a))
            if pressed then C.switch(a, not a.loaded) end
            return cw + S(18) + sw
        end
        return w
    end

    -- an addon made for another server than the one the game is on, said in a sentence
    local function other_text(a)
        return 'Made for ' .. tostring(a.server) .. ". You're playing on " .. tostring(D.here and D.here.name or 'another server')
            .. ', so it may not work here.'
    end

    -- How it stands on the site, as a chip. A card marks only what isn't the usual: not approved, a native plugin, on
    -- the site only, not reviewed, or updated elsewhere (a reviewed addon has its small shield by its name instead). An
    -- addon's own page says Trusted as well. Returns the chip's width, 0 for none.
    local function status_chip(dl, x, y, a, on_card, key)
        local label, tip
        if a.locked and LOCKED[a.locked][1] then
            label, tip = LOCKED[a.locked][1], LOCKED[a.locked][2]
        elseif not a.trusted and a.locked ~= 'denied' then
            label, tip = 'NOT REVIEWED', UNREVIEWED
        elseif on_card and a.fit == 'other' and a.have == nil then
            label, tip = 'OTHER SERVER', other_text(a)
        elseif on_card and a.behind and not a.takeover then
            label, tip = 'UPDATES ELSEWHERE', FOREIGN
        end
        if label == nil then
            if on_card or not a.trusted then return 0 end
            return (L.chip(dl, x, y, 'TRUSTED', 'quiet'))
        end
        local w, h = L.chip(dl, x, y, label, 'faint')
        if key then
            imgui.SetCursorScreenPos({ x, y })
            local _, hovered = U.hit(key, w, h, 0)
            if hovered then L.tip(tip) end
        end
        return w
    end

    -- a reviewed addon's mark on a card: a small shield after its name
    local function shield(dl, a, x, cy, alpha)
        if not a.trusted then return end
        L.icon(dl, x + S(11), cy, L.CP.shield, K.frame_light, T.small * 0.95, alpha)
    end

    -- who made it, and which framework it is for
    local function by_line(a)
        local by = a.author ~= '' and ('by ' .. a.author) or ''
        if a.framework_name ~= '' then by = by .. (by ~= '' and '  ·  ' or '') .. a.framework_name end
        return by
    end

    -- The server an addon is made for, as its by-line ends: the one the game is on in teal, another's faint, and
    -- one named while VanaCore can't say where the game is in the by-line's own ink. Nil for an addon for any server.
    local function server_tag(a)
        if a.server == nil then return nil end
        if a.fit == 'here' then return (D.here and D.here.name) or a.server, K.teal, F.semi end
        if a.fit == 'other' then return a.server, K.faint, F.text end
        return a.server, K.dim, F.text
    end

    -- who made it, which framework, and which server: drawn in at most `w`, the server's name kept whole; returns the
    -- width drawn
    local function by_row(dl, a, x, y, w, size)
        local by = by_line(a)
        local tag, col, font = server_tag(a)
        if tag == nil then
            local fitted = U.fit(by, F.text, size, w)
            U.text(dl, x, y, fitted, K.dim, F.text, size)
            return U.measure(fitted, F.text, size)
        end
        local sep = by ~= '' and '  ·  ' or ''
        local sw, tw = U.measure(sep, F.text, size), U.measure(tag, font, size)
        local fitted = U.fit(by, F.text, size, math.max(0, w - sw - tw))
        U.text(dl, x, y, fitted, K.dim, F.text, size)
        local tx = x + U.measure(fitted, F.text, size)
        U.text(dl, tx, y, sep, K.dim, F.text, size)
        U.text(dl, tx + sw, y, tag, col, font, size)
        return tx + sw + tw - x
    end

    -- text in at most `max` lines; a longer one ends at a whole word, with an ellipsis
    local function clamp(text, font, size, w, max)
        local lines = U.wrap(text, font, size, w)
        if #lines <= max then return lines end
        local out = {}
        for i = 1, max do out[i] = lines[i] end
        local last = out[max]
        while last ~= '' and U.measure(last .. '…', font, size) > w do last = last:match('^(.*)%s+%S+$') or '' end
        out[max] = (last:gsub('[%s,;:%.]+$', '')) .. '…'
        return out
    end

    -- v1.0.2, and what you have when it's older: in gold when the store can update it, dim when it's another's to update
    local function version_text(a)
        local ver = a.version ~= '' and ('v' .. a.version) or ''
        if a.update then
            -- (the same version, another file: the site's copy changed since the store installed it)
            if a.have == '?' or D.compare_versions(a.have, a.version) >= 0 then return ver, 'changed on the site', K.gold end
            return ver, 'you have ' .. tostring(a.have), K.gold
        end
        if a.behind then return ver, 'you have ' .. tostring(a.have), a.takeover and K.gold or K.faint end
        local where = elsewhere_of(a)
        if where then return ver, 'in ' .. where, K.faint end
        return ver, nil, K.gold
    end

    -- What a card says on its bottom row, after any chip: how many downloads, and, when the list is in that order, when
    -- the addon was added or last updated. The figure the list is ordered by is lit (its icon in gold). Words are
    -- shortened (12 downloads, 12; 12,345, 12k) before anything is left out, and the order's own figure is the last to
    -- go. Returns the width drawn.
    local function meta(dl, a, x, cy, room)
        local by = C.sort_now()
        local items = {}
        if a.downloads then
            items[#items + 1] = { cp = L.CP.download, full = D.downloads_text(a.downloads), short = D.count_text(a.downloads),
                tiny = D.compact_count(a.downloads), lit = by == 'downloads' }
        end
        local when = (by == 'newest' and a.created_at) or (by == 'updated' and a.updated_at) or nil
        local day = when and D.short_date(when)
        if day then
            items[#items + 1] = { cp = by == 'newest' and L.CP.cal_plus or L.CP.clock, full = (by == 'newest' and 'Added ' or 'Updated ') .. day,
                short = day, tiny = day, lit = true }
        end
        if #items == 0 or room <= 0 then return 0 end
        local size, iw, gap = T.small, S(17), S(14)
        local function width(list, form)
            local w = 0
            for i, it in ipairs(list) do w = w + (i > 1 and gap or 0) + iw + U.measure(it[form], F.text, size) end
            return w
        end
        local key_item = items[#items].lit and items[#items] or items[1]
        local tries = { { items, 'full' }, { items, 'short' }, { items, 'tiny' }, { { key_item }, 'full' }, { { key_item }, 'short' },
            { { key_item }, 'tiny' } }
        for _, try in ipairs(tries) do
            local list, form = try[1], try[2]
            local w = width(list, form)
            if w <= room then
                local cx = x
                for _, it in ipairs(list) do
                    L.icon(dl, cx + S(6), cy, it.cp, it.lit and K.gold or K.faint, T.small * 0.85, it.lit and 0.95 or 0.9)
                    U.text_mid(dl, cx + iw, cy, it[form], it.lit and mix(K.dim, K.ink, 0.35) or K.faint, F.text, size)
                    cx = cx + iw + U.measure(it[form], F.text, size) + gap
                end
                return w
            end
        end
        return 0
    end

    -- an addon's picture (its nth), or the stand-in; fades in as its texture arrives
    local function picture(dl, a, n, x, y, w, h, thumb, alpha, rounding, corners)
        local shot = a.shots[n or 1]
        local tex, at = nil, nil
        local iw, ih
        if shot then tex, at, iw, ih = D.picture(thumb and shot.thumb or shot.url, shot.stamp) end
        if tex then
            local fade = U.ease((U.clock() - at) / 0.25)
            if fade < 1 then L.placeholder(dl, x, y, w, h, a.title, alpha, rounding, corners) end
            L.cover(dl, tex, iw or shot.w, ih or shot.h, x, y, w, h, (alpha or 1) * fade, rounding, corners)
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

    -- The server the game is on, as a card heading the rail's server filters: its name as its lobby gives it, a dot
    -- that breathes once the lobby has given it (an open ring while it's last time's name, at the title screen), and
    -- how many addons are made for it. Pressed, the page shows those alone.
    local function server_card(dl, x, y, w, here, count, on)
        local h, r = S(72), S(10)
        imgui.SetCursorScreenPos({ x, y })
        local pressed, hovered, hv = U.hit('##vs_r_here', w, h, r)
        local lit = on and 1 or hv
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(K.bg1, K.teal, 0.05 + 0.06 * lit)), r)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(on and K.teal or mix(K.line, K.teal, 0.35 + 0.45 * hv), on and 0.95 or 0.85), r, 240, 1)
        local dx, dy = x + S(17), y + S(19)
        if here.live then
            local p = (math.sin(U.clock() * 2.2) + 1) / 2
            dl:AddCircleFilled({ dx, dy }, S(4) + S(5) * p, u32(K.teal, 0.25 * (1 - p)), 24)
            dl:AddCircleFilled({ dx, dy }, S(3.5), u32(K.teal), 16)
        else
            dl:AddCircle({ dx, dy }, S(3.3), u32(K.teal_dim), 16, math.max(1, S(1.4)))
        end
        L.eyebrow(dl, dx + S(13), dy - L.pix_size(1) / 2, 'PLAYING ON', here.live and K.teal or K.teal_dim)
        local name = U.fit(here.name, F.bold, T.body + 2, w - S(28))
        U.text(dl, x + S(13), y + S(31), name, on and K.hot or mix(K.ink, K.hot, hv), F.bold, T.body + 2)
        local sub = count == 0 and 'Nothing made for it yet' or count == 1 and '1 addon made for it' or (count .. ' addons made for it')
        U.text(dl, x + S(13), y + S(51), U.fit(sub, F.text, T.small, w - S(26)), on and K.dim or K.faint, F.text, T.small)
        if hovered then
            L.tip(here.live and ('The addons made for ' .. here.name .. ', the server you are on')
                or (here.name .. ' was the server at ' .. tostring(here.host) .. ' last time. Its lobby says so again when you log in.'))
        end
        return pressed, h
    end

    function V.rail(dl, x, y, w)
        local counts = D.counts or { all = 0, installed = 0, updates = 0, bundled = 0 }
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
        cy = cy + h + S(2)
        -- (VanaCore's own addons: not the site's, only switched on and off here)
        pressed, h = rail_item(dl, '##vs_r_bund', x, cy, w, 'Bundled', L.CP.box, st.view == 'bundled', counts.bundled)
        if pressed then set_view('bundled', st.compat) end
        cy = cy + h + S(22)
        local here = D.here
        if here then
            -- (the server the game is on: its card, then any server's addons, then other servers' where there are any)
            L.eyebrow(dl, x + S(10), cy, 'SERVER', K.dim)
            cy = cy + S(22)
            pressed, h = server_card(dl, x, cy, w, here, counts.here or 0, st.compat == 'here')
            if pressed then set_view(st.view, st.compat ~= 'here' and 'here' or nil) end
            cy = cy + h + S(6)
            pressed, h = rail_item(dl, '##vs_r_gen', x, cy, w, 'Any server', L.CP.globe, st.compat == 'general', counts.any)
            if pressed then set_view(st.view, st.compat ~= 'general' and 'general' or nil) end
            cy = cy + h + S(2)
            if (counts.other or 0) > 0 or st.compat == 'other' then
                pressed, h = rail_item(dl, '##vs_r_oth', x, cy, w, 'Other servers', L.CP.server, st.compat == 'other', counts.other)
                if pressed then set_view(st.view, st.compat ~= 'other' and 'other' or nil) end
                cy = cy + h + S(2)
            end
            cy = cy + S(20)
        else
            -- (a VanaCore that can't say which server the game is on)
            L.eyebrow(dl, x + S(10), cy, 'COMPATIBILITY', K.dim)
            cy = cy + S(22)
            pressed, h = rail_item(dl, '##vs_r_gen', x, cy, w, 'General', L.CP.globe, st.compat == 'general')
            if pressed then set_view(st.view, st.compat ~= 'general' and 'general' or nil) end
            cy = cy + h + S(2)
            pressed, h = rail_item(dl, '##vs_r_srv', x, cy, w, 'Server-specific', L.CP.server, st.compat == 'server')
            if pressed then set_view(st.view, st.compat ~= 'server' and 'server' or nil) end
            cy = cy + h + S(22)
        end
        L.eyebrow(dl, x + S(10), cy, 'FRAMEWORK', K.dim)
        cy = cy + S(22)
        for _, f in ipairs({ { 'vanacore', 'VanaCore' }, { 'ashita', 'Ashita' }, { 'windower', 'Windower' } }) do
            pressed, h = rail_item(dl, '##vs_r_f_' .. f[1], x, cy, w, f[2], L.CP.layers, st.framework == f[1])
            if pressed then
                st.framework = st.framework ~= f[1] and f[1] or nil
                st.detail, st.settings_open = nil, false
                st.grid_at = U.clock()
                st.scroll_top = true
            end
            cy = cy + h + S(2)
        end
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
        local ftitle = U.fit(a.title, F.bold, T.h1, tw - S(26))
        U.text(dl, tx, cy, ftitle, K.ink, F.bold, T.h1)
        shield(dl, a, tx + U.measure(ftitle, F.bold, T.h1), cy + S(15))
        cy = cy + S(30)
        local ver, have, have_col = version_text(a)
        local bw = by_row(dl, a, tx, cy, tw - L.mono_width(ver, T.small) - (have and (L.mono_width(have, T.small) + S(10)) or 0) - S(12), T.small)
        local vx = tx + (bw > 0 and (bw + S(12)) or 0)
        L.mono(dl, vx, cy, ver, K.dim, T.small)
        if have then L.mono(dl, vx + L.mono_width(ver, T.small) + S(10), cy, have, have_col, T.small) end
        cy = cy + S(26)
        for _, line in ipairs(clamp(a.summary, F.text, T.body, tw, 2)) do
            U.text(dl, tx, cy, line, mix(K.ink, K.dim, 0.25), F.text, T.body)
            cy = cy + S(22)
        end
        -- the bottom row: the button, then how it stands on the site
        local by2 = iy + ih - S(22) - S(44)
        local used = primary_action(dl, a, key .. '_act', tx, by2)
        local job = C.jobs[a.slug]
        if job and job.state == 'refused' then
            -- why it wasn't installed, beside the button
            U.text_mid(dl, tx + used + S(20), by2 + S(22), U.fit(job.why, F.text, T.small, tw - used - S(20)), K.red, F.text, T.small)
        else
            local mx = tx + (used > 0 and (used + S(22)) or 0)
            if a.locked then
                local _, chh = L.chip_size('TRUSTED')
                local cw = status_chip(dl, tx, by2 + (S(44) - chh) / 2, a, true)
                mx = tx + (cw > 0 and (cw + S(14)) or 0)
            end
            meta(dl, a, mx, by2 + S(22), tx + tw - mx)
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
        local ver, have, have_col = version_text(a)
        local vw = L.mono_width(ver, T.small)
        local ctitle = U.fit(a.title, F.semi, T.body, pw - vw - S(34))
        U.text(dl, px, cy, ctitle, mix(K.ink, K.hot, hv), F.semi, T.body)
        shield(dl, a, px + U.measure(ctitle, F.semi, T.body), cy + S(10))
        L.mono(dl, px + pw - vw, cy + S(2), ver, K.dim, T.small)
        cy = cy + S(22)
        by_row(dl, a, px, cy, pw - (have and (L.mono_width(have, T.small) + S(10)) or 0), T.small)
        if have then
            local hw = L.mono_width(have, T.small)
            L.mono(dl, px + pw - hw, cy, have, have_col, T.small)
        end
        cy = cy + S(24)
        for _, line in ipairs(clamp(a.summary, F.text, T.small, pw, 2)) do
            U.text(dl, px, cy, line, mix(K.ink, K.dim, 0.45), F.text, T.small)
            cy = cy + S(18)
        end
        -- the bottom row: a chip if it needs one and the downloads, then its control
        local by = y + h - S(14) - S(14)
        local job = C.jobs[a.slug]
        local left = card_action(dl, a, key .. '_act', x + w - S(14), by)
        if job and job.state == 'refused' then
            U.text_mid(dl, px, by, U.fit(job.why, F.text, T.small, pw - S(100)), K.red, F.text, T.small)
        else
            local _, chh = L.chip_size('TRUSTED')
            local cw = status_chip(dl, px, by - chh / 2, a, true, key .. '_why')
            local mx = px + (cw > 0 and (cw + S(9)) or 0)
            meta(dl, a, mx, by, left - S(10) - mx)
        end
        imgui.SetCursorScreenPos({ x, y + lift })
        if U.hit(key, w, h, r, { x = x, y = y, w = w, h = h }) then C.open_detail(a) end
    end

    -- A card laid on its side, as wide as the page: the picture on the left, the words beside it. For a short list
    -- (fewer addons than a row of cards holds), so two addons fill the page instead of sitting in its corner.
    local function wide_card(dl, a, x, y, w, h, i, t)
        local key = '##vs_card_' .. a.slug
        local hv = hover_of(key)
        local r = S(10)
        local lift = S(2) * hv
        y = y - lift
        if hv > 0.01 then U.shadow(dl, x, y, w, h, r, 0.9 * hv) end
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(K.panel, K.panel2, 0.35 * hv)), r)
        local pw = math.floor(math.min((h - 2) * 16 / 10, w * 0.38))
        picture(dl, a, 1, x + 1, y + 1, pw, h - 2, true, 1, r - 1, 80) -- (80: the left corners)
        dl:AddRectFilled({ x + 1, y + 1 }, { x + 1 + pw, y + h - 1 }, u32(K.bg0, 0.16 * (1 - hv)), r - 1, 80)
        dl:AddLine({ x + 1 + pw, y + 1 }, { x + 1 + pw, y + h - 1 }, u32(K.frame_dark, 0.6), 1)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(K.line, K.gold, hv), 0.95), r, 240, 1)
        local px, tw = x + pw + S(22), w - pw - S(44)
        local cy = y + S(18)
        local ver, have, have_col = version_text(a)
        local vw = L.mono_width(ver, T.small)
        local ctitle = U.fit(a.title, F.semi, T.body, tw - vw - S(34))
        U.text(dl, px, cy, ctitle, mix(K.ink, K.hot, hv), F.semi, T.body)
        shield(dl, a, px + U.measure(ctitle, F.semi, T.body), cy + S(10))
        L.mono(dl, px + tw - vw, cy + S(2), ver, K.dim, T.small)
        cy = cy + S(22)
        by_row(dl, a, px, cy, tw - (have and (L.mono_width(have, T.small) + S(10)) or 0), T.small)
        if have then L.mono(dl, px + tw - L.mono_width(have, T.small), cy, have, have_col, T.small) end
        cy = cy + S(26)
        for _, line in ipairs(clamp(a.summary, F.text, T.small, math.min(tw, S(560)), 3)) do
            U.text(dl, px, cy, line, mix(K.ink, K.dim, 0.45), F.text, T.small)
            cy = cy + S(18)
        end
        local by = y + h - S(16) - S(14)
        local job = C.jobs[a.slug]
        local left = card_action(dl, a, key .. '_act', x + w - S(22), by)
        if job and job.state == 'refused' then
            U.text_mid(dl, px, by, U.fit(job.why, F.text, T.small, tw - S(110)), K.red, F.text, T.small)
        else
            local _, chh = L.chip_size('TRUSTED')
            local cw = status_chip(dl, px, by - chh / 2, a, true, key .. '_why')
            local mx = px + (cw > 0 and (cw + S(12)) or 0)
            meta(dl, a, mx, by, left - S(14) - mx)
        end
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

    -- VanaCore's own addons, the ones it ships with: a plain list, each with what it says of itself and its switch.
    -- They aren't the site's: nothing here is fetched, installed or updated, and the catalog needn't have come.
    local function bundled_row(dl, b, x, y, w, h)
        local key = '##vs_bund_' .. b.name
        local hv = hover_of(key)
        local r = S(10)
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(K.panel, K.panel2, 0.35 * hv)), r)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(K.line, K.gold, hv), 0.95), r, 240, 1)
        local px, right = x + S(18), x + w - S(18)
        local room = w - S(36) - S(120)
        local title = U.fit(b.title, F.semi, T.body, room * 0.6)
        U.text(dl, px, y + S(13), title, mix(K.ink, K.hot, hv), F.semi, T.body)
        local tx = px + U.measure(title, F.semi, T.body) + S(12)
        if b.version ~= '' then
            L.mono(dl, tx, y + S(15), 'v' .. b.version, K.dim, T.small)
            tx = tx + L.mono_width('v' .. b.version, T.small) + S(10)
        end
        if b.author ~= '' then U.text(dl, tx, y + S(15), 'by ' .. b.author, K.faint, F.text, T.small) end
        local desc = clamp(b.desc, F.text, T.small, room, 1)[1] or ''
        U.text(dl, px, y + S(37), desc, mix(K.ink, K.dim, 0.45), F.text, T.small)
        -- the row is one thing to point at (its hint: the whole description); the switch sits on it
        imgui.SetCursorScreenPos({ x, y })
        local _, hovered = U.hit(key, w - S(130), h, r, { x = x, y = y, w = w, h = h })
        if hovered and desc ~= b.desc then L.tip(b.desc) end
        local cy = y + h / 2
        if b.fixed then
            local label = 'Always on'
            U.text_mid(dl, right - U.measure(label, F.semi, T.small), cy, label, K.faint, F.semi, T.small)
        else
            local label = b.loaded and 'On' or 'Off'
            local lw = U.measure(label, F.semi, T.small) + S(8)
            local _, pressed = L.switch(dl, key .. '_sw', right - S(38) - lw, cy, b.loaded, label, b.loaded and 'Loaded, and at every start' or 'Not loaded')
            if pressed then C.I.switch_bundled(b, not b.loaded) end
        end
    end

    local function bundled_page(dl, ox, oy, w)
        local at = 0
        local room = w - S(8)
        local words = {}
        for word in (st.query[1] or ''):lower():gmatch('%S+') do words[#words + 1] = word end
        local list = {}
        for _, b in ipairs(D.bundled or {}) do
            local keep = true
            for _, word in ipairs(words) do
                if not b.search:find(word, 1, true) then keep = false break end
            end
            if keep then list[#list + 1] = b end
        end
        L.eyebrow(dl, ox + S(2), oy + at + S(2), 'BUNDLED WITH VANACORE', K.dim)
        local count = #list == 1 and '1 addon' or (#list .. ' addons')
        U.text(dl, ox + w - S(8) - U.measure(count, F.text, T.small), oy + at - S(2), count, K.faint, F.text, T.small)
        at = at + S(26)
        U.text(dl, ox + S(2), oy + at, "These come with VanaCore and update with it. They aren't on FFXIPS: here they are only switched on and off.",
            K.dim, F.text, T.small)
        at = at + S(30)
        if #list == 0 then
            empty(dl, ox, oy + at + S(30), room, (#words > 0) and ('Nothing matches "' .. st.query[1] .. '".') or 'None of them is in this VanaCore.', nil)
            return at + S(200)
        end
        local row_h, gap = S(66), S(10)
        for i, b in ipairs(list) do
            local a_in = U.ease((U.clock() - (st.grid_at or 0) - 0.04 - (i - 1) * 0.03) / 0.3)
            C.fade(a_in)
            local ok, err = pcall(bundled_row, dl, b, ox + S(2), oy + at + (1 - a_in) * S(8), room, row_h)
            if not ok then C.fail('bundled', err) end
            C.fade(1)
            at = at + row_h + gap
        end
        return at
    end

    -- a heading over a block of cards (its icon before it, if any), and how many on the right (`reserve` short of the
    -- page's edge: the order's pill sits there on the page's first line); returns where the cards go
    local function section_heading(dl, ox, oy, at, w, label, count, color, icon, reserve)
        local x = ox + S(2)
        if icon then
            L.icon(dl, x + S(6), oy + at + S(2) + L.pix_size(1) / 2, icon, color, T.small * 0.9)
            x = x + S(18)
        end
        L.eyebrow(dl, x, oy + at + S(2), label, color or K.dim)
        local cw = U.measure(count, F.text, T.small)
        U.text(dl, ox + w - S(8) - (reserve or 0) - cw, oy + at - S(2), count, K.faint, F.text, T.small)
        return at + S(26)
    end

    -- the cards of a list, from `at` down: a grid, or a short list as rows as wide as the page; `i0`: how many came
    -- before them on the page (their fading in follows on). Returns where the page goes on.
    local function card_rows(dl, list, ox, oy, at, w, view_h, scroll, t, i0)
        local gap = S(CARD.gap)
        local room = w - S(8)
        local cols = math.max(1, math.floor((room + gap) / (S(CARD.min_w) + gap)))
        local card_w = math.floor((room - gap * (cols - 1)) / cols)
        local card_h = math.floor(card_w * 9 / 16) + S(CARD.text_h)
        if #list < cols then
            -- a short list: each addon a row as wide as the page
            local row_h = S(176)
            for i, a in ipairs(list) do
                local cy = oy + at + (i - 1) * (row_h + gap)
                local a_in = U.ease((U.clock() - (st.grid_at or 0) - 0.05 - (i0 + i - 1) * 0.05) / 0.3)
                C.fade(a_in)
                local ok, err = pcall(wide_card, dl, a, ox + S(2), cy + (1 - a_in) * S(10), room, row_h, i, t)
                if not ok then C.fail('card', err) end
                C.fade(1)
            end
            return at + #list * (row_h + gap)
        end
        for i, a in ipairs(list) do
            local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
            local cx, cy = ox + S(2) + col * (card_w + gap), oy + at + row * (card_h + gap)
            if cy + card_h >= oy + scroll - S(40) and cy <= oy + scroll + view_h + S(40) then
                local a_in = U.ease((U.clock() - (st.grid_at or 0) - 0.05 - (i0 + i - 1) * 0.035) / 0.3)
                C.fade(a_in)
                local ok, err = pcall(card, dl, a, cx, cy + (1 - a_in) * S(10), card_w, card_h, i, t)
                if not ok then C.fail('card', err) end
                C.fade(1)
            end
        end
        return at + math.ceil(#list / cols) * (card_h + gap)
    end

    ---------------------------------------------------------------------------
    -- The order: a pill at the top right of the list, and its menu
    ---------------------------------------------------------------------------

    local SORT = {
        recommended = { name = 'Recommended', cp = L.CP.star },
        downloads = { name = 'Most downloaded', cp = L.CP.download, hint = 'The most downloads on FFXIPS first' },
        newest = { name = 'Newest', cp = L.CP.cal_plus, hint = 'The latest added to FFXIPS first' },
        updated = { name = 'Recently updated', cp = L.CP.clock, hint = 'The latest new versions first' },
        name = { name = 'Name A–Z', cp = L.CP.az, hint = 'By name, in alphabetical order' },
    }
    local function sort_hint(id)
        if id ~= 'recommended' then return SORT[id].hint end
        local here = D.here
        return here and ('Reviewed first, then made for ' .. here.name) or "Reviewed first, in the site's order"
    end
    local SORT_MENU = '##vs_sort_menu'

    -- the menu: each order with its icon and a line on what it puts first, the one in use in gold with a check. Opened
    -- under the pill, its right edge on the pill's; a controller's focus starts on the order in use.
    local function sort_menu(right, y)
        local pw, row_h = S(344), S(50)
        local ph = S(40) + #D.SORTS * row_h + S(6)
        local e = U.ease((U.clock() - (st.sort_open_at or 0)) / 0.18)
        imgui.SetNextWindowPos({ right - pw, y - (1 - e) * S(6) }, U.ALWAYS)
        imgui.SetNextWindowSize({ pw, ph }, U.ALWAYS)
        local was = st.sort_open
        st.sort_open = false
        -- (8 + 16: no scroll bar, no scrolling)
        if imgui.BeginPopup(SORT_MENU, 8 + 16) then
            st.sort_open = true
            if not was then st.sort_open_at = U.clock() end
            local ok, err = pcall(function ()
                local pdl = imgui.GetWindowDrawList()
                local x0, y0 = imgui.GetWindowPos()
                pdl:AddRect({ x0, y0 }, { x0 + pw, y0 + ph }, u32(mix(K.frame_light, K.line, 0.45), 0.95), S(10), 240, 1)
                L.eyebrow(pdl, x0 + S(18), y0 + S(16), 'SORT BY', K.dim)
                local now = C.sort_now()
                for i, id in ipairs(D.SORTS) do
                    local o = SORT[id]
                    local on = id == now
                    local rx, ry, rw, rh = x0 + S(6), y0 + S(36) + (i - 1) * row_h, pw - S(12), row_h - S(2)
                    imgui.SetCursorScreenPos({ rx, ry })
                    local pressed, _, hv = U.hit('##vs_sort_' .. id, rw, rh, S(8))
                    if on then imgui.SetItemDefaultFocus() end
                    if on then
                        pdl:AddRectFilled({ rx, ry }, { rx + rw, ry + rh }, u32(K.gold, 0.09 + 0.05 * hv), S(8))
                    elseif hv > 0.01 then
                        pdl:AddRectFilled({ rx, ry }, { rx + rw, ry + rh }, u32(K.hot, 0.07 * hv), S(8))
                    end
                    L.icon(pdl, rx + S(22), ry + rh / 2, o.cp, on and K.gold or mix(K.dim, K.ink, hv), T.small)
                    U.text(pdl, rx + S(44), ry + S(8), o.name, on and K.gold or mix(K.ink, K.hot, hv), F.semi, T.body - 1)
                    U.text(pdl, rx + S(44), ry + S(28), U.fit(sort_hint(id), F.text, T.small, rw - S(80)), on and K.dim or K.faint, F.text, T.small)
                    if on then L.icon(pdl, rx + rw - S(20), ry + rh / 2, L.CP.check, K.gold, T.small) end
                    if pressed then
                        C.set_sort(id)
                        imgui.CloseCurrentPopup()
                    end
                end
                if st.sort_close or imgui.IsKeyPressed(U.KEY_ESCAPE) then imgui.CloseCurrentPopup() end
            end)
            if not ok then C.fail('sort', err) imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end
        st.sort_close = nil
    end

    -- the pill: "Sort by" and the order in use, its right edge at `right`; returns its width and height
    local function sort_control(dl, right, y)
        local s = SORT[C.sort_now()]
        local h = S(30)
        local lead = 'Sort by'
        local lw, vw = U.measure(lead, F.text, T.small), U.measure(s.name, F.semi, T.small)
        local w = S(14) + S(16) + S(8) + lw + S(6) + vw + S(10) + S(10) + S(14)
        local x = right - w
        imgui.SetCursorScreenPos({ x, y })
        local pressed, hovered, hv = U.hit('##vs_sort', w, h, h / 2)
        local lit = st.sort_open and 1 or hv
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(mix(K.panel, K.panel2, 0.6 * lit)), h / 2)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(K.line, K.gold, lit), 0.95), h / 2, 240, 1)
        local cy, cx = y + h / 2, x + S(14)
        L.icon(dl, cx + S(8), cy, L.CP.sort, mix(K.dim, K.gold, lit), T.small)
        cx = cx + S(16) + S(8)
        U.text_mid(dl, cx, cy, lead, K.faint, F.text, T.small)
        cx = cx + lw + S(6)
        U.text_mid(dl, cx, cy, s.name, mix(K.ink, K.hot, hv), F.semi, T.small)
        cx = cx + vw + S(10)
        L.icon(dl, cx + S(5), cy, st.sort_open and L.CP.chev_up or L.CP.chev_down, mix(K.dim, K.gold, lit), T.tiny)
        if hovered and not st.sort_open then L.tip('The order of the addons') end
        if pressed or st.sort_ask then
            st.sort_ask = nil
            imgui.OpenPopup(SORT_MENU)
        end
        sort_menu(right, y + h + S(6))
        return w, h
    end

    local function grid_page(dl, ox, oy, w, view_h, scroll, t)
        local at = 0
        local query = st.query[1] or ''
        if st.view == 'bundled' then return bundled_page(dl, ox, oy, w) end
        if D.state ~= 'ready' then
            -- no catalog yet: on its way, or it couldn't be had
            if D.fetching then empty(dl, ox, oy + S(90), w - S(8), 'Looking for addons...', D.origin:gsub('^%a+://', ''))
            else empty(dl, ox, oy + S(90), w - S(8), "The catalog couldn't be read.", tostring(D.why or D.fetch_why or '')) end
            return S(300)
        end
        local here = D.here
        -- (the rail's server filters follow what VanaCore can say: made for one server becomes made for this one once
        -- the lobby has named it, and this one's and other servers' go back to all when it can't say)
        if here and st.compat == 'server' then st.compat = 'here' end
        if not here and (st.compat == 'here' or st.compat == 'other') then st.compat = nil end
        local by = C.sort_now()
        local list = D.filter(st.view, st.compat, query, st.framework, by)
        local searching = query:gsub('%s', '') ~= ''
        local plain = st.view == 'all' and st.compat == nil and st.framework == nil and not searching
        -- (the store's front, the featured card and the server's own section, is the recommended order's: in another
        -- the list is one, in that order, the featured addon in its place among the rest)
        local front = plain and by == 'recommended'
        local feat = front and D.featured() or nil
        if feat then
            -- (the featured addon has the large card: it isn't shown again among the cards under it)
            for i = #list, 1, -1 do if list[i] == feat then table.remove(list, i) end end
        end
        local base = U.ease((U.clock() - (st.grid_at or 0)) / 0.3)
        -- the order, at the top right, where it stays whatever the page shows: on the first heading's line, or above
        -- the featured card
        C.fade(1)
        local sort_w, sort_h = sort_control(dl, ox + w - S(6), oy + at)
        local reserve = sort_w + S(16)
        if feat then
            at = at + sort_h + S(14)
            reserve = nil
        else
            at = at + S(9)
        end
        if feat then
            C.fade(base)
            at = at + S(4)
            local ok, h = pcall(featured, dl, feat, ox + S(2), oy + at - (1 - base) * S(8), w - S(8), t)
            if not ok then C.fail('featured', h) h = S(236) end
            at = at + h + S(30)
            C.fade(1)
        end
        local function count_of(n) return n == 1 and '1 addon' or (n .. ' addons') end
        -- All addons, on a server VanaCore can name: the addons made for it first, under its name, then those for any
        -- server, then other servers' with a word on why they're last
        if front and here and #list > 0 then
            local groups = { here = {}, any = {}, other = {} }
            for _, a in ipairs(list) do
                local g = groups[a.fit] or groups.any
                g[#g + 1] = a
            end
            local mine = #groups.here > 0
            local sections = {
                { groups.here, 'MADE FOR ' .. here.name:upper(), K.teal, L.CP.server },
                { groups.any, mine and 'FOR ANY SERVER' or (feat and 'MORE ADDONS' or 'ALL ADDONS'), K.dim },
                { groups.other, 'FOR OTHER SERVERS', K.faint, nil, 'Made for other servers than ' .. here.name .. ': they may not work here.' },
            }
            local n = 0
            for _, sec in ipairs(sections) do
                if #sec[1] > 0 then
                    at = section_heading(dl, ox, oy, at, w, sec[2], count_of(#sec[1]), sec[3], sec[4], reserve)
                    if reserve then at, reserve = at + S(6), nil end
                    if sec[5] then
                        U.text(dl, ox + S(2), oy + at - S(4), sec[5], K.faint, F.text, T.small)
                        at = at + S(22)
                    end
                    at = card_rows(dl, sec[1], ox, oy, at, w, view_h, scroll, t, n) + S(14)
                    n = n + #sec[1]
                end
            end
            return at
        end
        -- the heading over the cards: what is shown, and how many
        local heading = st.view == 'installed' and 'INSTALLED' or st.view == 'updates' and 'UPDATES' or (feat and 'MORE ADDONS' or 'ALL ADDONS')
        local heading_col, heading_icon = K.dim, nil
        if st.compat == 'here' and st.view == 'all' and here then heading, heading_col, heading_icon = 'MADE FOR ' .. here.name:upper(), K.teal, L.CP.server end
        if searching then heading, heading_col, heading_icon = 'SEARCH', K.dim, nil end
        local count = count_of(#list) -- (the cards under this heading)
        if st.compat == 'here' and here then count = count .. (heading_icon and '' or (', for ' .. here.name)) -- (said once: the heading names it)
        elseif st.compat == 'other' then count = count .. ', other servers'
        elseif st.compat == 'general' then count = count .. (here and ', any server' or ', general')
        elseif st.compat == 'server' then count = count .. ', server-specific' end
        if st.framework then count = count .. ', ' .. (st.framework == 'vanacore' and 'VanaCore' or st.framework == 'ashita' and 'Ashita' or 'Windower') end
        at = section_heading(dl, ox, oy, at, w, heading, count, heading_col, heading_icon, reserve)
        if reserve then at = at + S(6) end
        if #list == 0 and feat then return at end
        if #list == 0 then
            local line, sub = 'No addons here yet.', nil
            if searching then line, sub = 'Nothing matches "' .. query .. '".', 'Try a shorter word, or look in All addons.'
            elseif st.view == 'updates' then line, sub = 'Everything is up to date.', nil
            elseif st.view == 'installed' then line, sub = 'Nothing from the store is installed yet.', 'Addons you install show here, with their switches.'
            elseif st.compat == 'here' and here then line, sub = 'Nothing on FFXIPS is made for ' .. here.name .. ' yet.', 'Addons for any server work there too.'
            elseif st.compat == 'other' then line, sub = 'No addons for other servers.', nil end
            empty(dl, ox, oy + at + S(30), w - S(8), line, sub)
            return at + S(200)
        end
        return card_rows(dl, list, ox, oy, at, w, view_h, scroll, t, 0)
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
        local tex, tex_at, tex_w, tex_h = nil, nil, nil, nil
        if shot then tex, tex_at, tex_w, tex_h = D.picture(shot.url, shot.stamp) end
        if tex then
            local fade = U.ease((U.clock() - math.max(tex_at, st.shot_at or 0)) / 0.25)
            L.contain(dl, tex, tex_w or shot.w, tex_h or shot.h, px + S(1), py + S(1), pw - S(2), ph - S(2), fade)
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
                local ttex, _, sw2, sh2 = D.picture(s.thumb, s.stamp)
                if ttex then L.cover(dl, ttex, sw2 or s.w, sh2 or s.h, tx, ty, tw2, th2, i == n and 1 or 0.6 + 0.4 * hv, S(6), 240)
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
        -- which server it's for: the one the game is on in teal
        if a.fit == 'here' then
            L.icon(dl, sx + S(6), cy + L.pix_size(1) / 2, L.CP.server, K.teal, T.small * 0.9)
            L.eyebrow(dl, sx + S(18), cy, 'MADE FOR ' .. ((D.here and D.here.name) or a.server):upper(), K.teal)
        else
            L.eyebrow(dl, sx, cy, a.compatibility == 'server' and ('FOR ' .. (a.server or 'ONE SERVER'):upper()) or 'ANY SERVER')
        end
        cy = cy + S(22)
        for _, line in ipairs(U.wrap(a.title, F.bold, T.title - 2, sw)) do
            U.text(dl, sx, cy, line, K.ink, F.bold, T.title - 2)
            cy = cy + S(34)
        end
        if a.author ~= '' then
            U.text(dl, sx, cy, by_line(a), K.dim, F.text, T.body)
            cy = cy + S(30)
        end
        status_chip(dl, sx, cy, a, false)
        cy = cy + S(36)
        if a.locked and a.have == nil then
            -- why there is no button, said once
            for _, line in ipairs(U.wrap(LOCKED[a.locked][2], F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.dim, F.text, T.small)
                cy = cy + S(18)
            end
            cy = cy + S(2)
        else
            primary_action(dl, a, '##vs_detail_act', sx, cy)
            cy = cy + S(44) + S(14)
        end
        local job = C.jobs[a.slug]
        if job and job.state == 'refused' then
            for _, line in ipairs(U.wrap(job.why, F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.red, F.text, T.small)
                cy = cy + S(18)
            end
            cy = cy + S(6)
        elseif a.foreign then
            for _, line in ipairs(U.wrap(a.takeover and FOREIGN_TAKE or FOREIGN, F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.faint, F.text, T.small)
                cy = cy + S(18)
            end
            if a.takeover and not a.behind and not (job and job.state ~= 'refused') then
                -- (up to date already: the takeover is offered all the same, quietly; behind, it is the button above)
                cy = cy + S(8)
                if L.quiet_button(dl, '##vs_detail_take', sx, cy, S(110), S(28), 'Take over') then C.ask_takeover(a) end
                cy = cy + S(28)
            end
            cy = cy + S(16)
        else
            cy = cy + S(8)
        end
        local second = elsewhere_text(a)
        if second and not (job and job.state == 'refused') then
            for _, line in ipairs(U.wrap(second, F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.dim, F.text, T.small)
                cy = cy + S(18)
            end
            cy = cy + S(10)
        end
        if a.unreviewed and not (job and job.state == 'refused') then
            -- (said once here, plainly; the chip above names it, and the warning comes before any download)
            for _, line in ipairs(U.wrap(UNREVIEWED, F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.faint, F.text, T.small)
                cy = cy + S(18)
            end
            cy = cy + S(14)
        end
        if a.fit == 'other' and D.here and not (job and job.state == 'refused') then
            for _, line in ipairs(U.wrap(other_text(a), F.text, T.small, sw)) do
                U.text(dl, sx, cy, line, K.dim, F.text, T.small)
                cy = cy + S(18)
            end
            cy = cy + S(14)
        end
        if not a.trusted and a.locked ~= 'denied' and not (job and job.state == 'refused') then
            -- what the site's scan found in an addon nobody has reviewed: the one to notice in brighter ink
            local strong, rest = D.flag_lines(a)
            for i, text in ipairs({ strong or false, rest or false }) do
                if text then
                    for _, line in ipairs(U.wrap(text, F.text, T.small, sw)) do
                        U.text(dl, sx, cy, line, i == 1 and K.dim or K.faint, F.text, T.small)
                        cy = cy + S(18)
                    end
                    cy = cy + S(8)
                end
            end
            if strong or rest then cy = cy + S(6) end
        end
        cy = cy + fact(dl, sx, cy, sw, 'Version', a.version ~= '' and a.version or '-')
        if a.have then cy = cy + fact(dl, sx, cy, sw, 'You have', tostring(a.have), a.update and K.gold or K.teal) end
        if a.framework_name ~= '' then cy = cy + fact(dl, sx, cy, sw, 'Framework', a.framework_name) end
        if a.package.size > 0 then cy = cy + fact(dl, sx, cy, sw, 'Size', D.size_text(a.package.size)) end
        local added = a.created_at:sub(1, 10)
        if added ~= '' and added ~= a.updated then cy = cy + fact(dl, sx, cy, sw, 'Added', D.date_text(added)) end
        cy = cy + fact(dl, sx, cy, sw, 'Updated', D.date_text(a.updated))
        if a.github then
            -- where a mirrored listing came from: the repository, then its release and commit under it
            local g = a.github
            local second = (g.tag or '') .. ((g.tag and g.commit) and '  ' or '') .. (g.commit or '')
            U.text(dl, sx, cy, 'Source', K.faint, F.text, T.small)
            local first = U.fit(g.repo or second, L.fonts.mono, T.small, sw - S(70))
            L.mono(dl, sx + sw - L.mono_width(first, T.small), cy, first, K.dim, T.small)
            if g.repo and second ~= '' then
                cy = cy + S(19)
                second = U.fit(second, L.fonts.mono, T.small, sw)
                L.mono(dl, sx + sw - L.mono_width(second, T.small), cy, second, K.faint, T.small)
            end
            dl:AddLine({ sx, cy + S(22) }, { sx + sw, cy + S(22) }, u32(K.line, 0.7), 1)
            cy = cy + S(30)
        end
        if a.update_in_review then cy = cy + fact(dl, sx, cy, sw, 'In review', a.pending_version or 'a new version', K.dim) end
        if a.downloads then cy = cy + fact(dl, sx, cy, sw, 'Downloads', D.count_text(a.downloads)) end
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
        if D.fetching then status = 'Looking for addons...'
        elseif D.state ~= 'ready' then status = "Couldn't read the catalog"
        elseif D.source == 'kept' then status = 'Offline: catalog of ' .. D.date_text((D.generated or ''):sub(1, 10))
        else status = 'Catalog of ' .. D.date_text((D.generated or ''):sub(1, 10)) end
        local sw = L.mono_width(status, T.tiny)
        L.mono_mid(dl, x + w - sw - S(22), cy, status, (D.state ~= 'ready' and not D.fetching) and K.red or K.faint, T.tiny)
    end

    return V
end
