-- The lists beside the map: every zone with a map, grouped by region (so any map opens from anywhere), your pins, and
-- the pins shared with you.
return function (C)
    local imgui = vana.imgui
    local U, G, PAD, DATA, REG, K = C.U, C.G, C.PAD, C.DATA, C.REG, C.K
    local P, F, T = U.P, U.fonts(), U.sizes()
    local S, u32, mix = U.S, U.u32, U.mix
    local cfg, st = C.cfg, C.st

    local SB = {}
    local TABS = { { 'zones', 'Zones' }, { 'pins', 'Pins' }, { 'shared', 'Shared' } }
    local L = { groups = nil, pin_counts = nil, pins_rev = nil }

    function SB.turn(by)
        local at = 1
        for i, tab in ipairs(TABS) do if tab[1] == cfg.side_tab then at = i end end
        cfg.side_tab = TABS[((at - 1 + by) % #TABS) + 1][1]
        st.pad_seat = true
    end

    -- the zones with maps, by group and region, each region's by name; built once
    local function groups()
        if L.groups then return L.groups end
        local by_region, loose = {}, {}
        for _, zone in ipairs(DATA.order) do
            local r = REG.of_zone[zone]
            local row = { id = zone, name = C.zone_name(zone), lower = C.zone_name(zone):lower(), floors = #DATA.zones[zone].floors }
            if r ~= nil and REG.names[r] then
                by_region[r] = by_region[r] or {}
                table.insert(by_region[r], row)
            else
                loose[#loose + 1] = row
            end
        end
        local out = {}
        local function by_name(a, b) return a.lower < b.lower end
        for _, g in ipairs(REG.groups) do
            local regions = {}
            for _, r in ipairs(g.regions) do
                if by_region[r] then
                    table.sort(by_region[r], by_name)
                    regions[#regions + 1] = { id = r, name = REG.names[r], lower = REG.names[r]:lower(), zones = by_region[r] }
                end
            end
            if #regions > 0 then out[#out + 1] = { name = g.name, regions = regions } end
        end
        if #loose > 0 then
            table.sort(loose, by_name)
            out[#out + 1] = { name = 'Elsewhere', regions = { { id = -1, name = 'Uncharted', lower = 'uncharted', zones = loose } } }
        end
        L.groups = out
        return out
    end

    local function pin_counts()
        if L.pins_rev ~= C.pins_rev or L.pin_counts == nil then
            L.pins_rev = C.pins_rev
            local counts = {}
            for _, p in ipairs(C.pins()) do counts[p.zone] = (counts[p.zone] or 0) + 1 end
            L.pin_counts = counts
        end
        return L.pin_counts
    end

    -- A scrolling list of rows of differing heights, only the ones in view drawn. rows: { { h = , draw = function (dl, x, y, w, h) }, ... }
    local function list(id, x, y, w, h, rows)
        imgui.SetCursorScreenPos({ x, y })
        -- 256: NavFlattened, so the controller's focus moves through the rows as through the window's own
        if imgui.BeginChild(id, { w, h }, 256, 0) then
            local ok, err = pcall(function ()
                local dl = imgui.GetWindowDrawList()
                local ox, oy = imgui.GetCursorScreenPos()
                local scroll = imgui.GetScrollY()
                local margin = S(90)
                local at = 0
                local inner = w - S(10)
                for _, row in ipairs(rows) do
                    if at + row.h >= scroll - margin and at <= scroll + h + margin then
                        row.draw(dl, ox, oy + at, inner, row.h)
                    end
                    at = at + row.h
                end
                imgui.SetCursorScreenPos({ ox, oy + at })
                imgui.Dummy({ 1, S(4) })
                -- the controller's stick scrolls the list
                if C.pad_on and st.pad_mode == 'list' then
                    local _, _, _, ry = PAD.stick()
                    if math.abs(ry) > 0 then imgui.SetScrollY(math.max(0, scroll - ry * S(900) * imgui.GetIO().DeltaTime)) end
                end
            end)
            if not ok then C.fail('list', err) end
        end
        imgui.EndChild()
    end

    local function seat_first()
        if st.pad_seat and C.pad_on then
            imgui.SetKeyboardFocusHere()
            st.pad_seat = nil
        end
    end

    ---------------------------------------------------------------------------
    -- Zones
    ---------------------------------------------------------------------------

    local function zone_row(row, counts, indent)
        return { h = S(30), draw = function (dl, x, y, w, h)
            local on = st.zone == row.id
            local mine = C.me.ok and C.me.zone == row.id
            imgui.SetCursorScreenPos({ x, y })
            if on and st.pad_seat then seat_first() end
            local pressed, _, hv = U.hit('##vm_z' .. row.id, w, h - S(2), S(7))
            if on then
                dl:AddRectFilled({ x, y }, { x + w, y + h - S(2) }, u32(P.accent, 0.22), S(7))
                dl:AddRectFilled({ x, y + S(5) }, { x + S(3), y + h - S(7) }, u32(P.cyan), S(2))
            elseif hv > 0.01 then
                dl:AddRectFilled({ x, y }, { x + w, y + h - S(2) }, u32(P.text, 0.07 * hv), S(7))
            end
            local tx = x + indent
            local right = x + w - S(8)
            if mine then
                G.icon(dl, right - S(6), y + h / 2 - 1, G.CP.locate, P.cyan, T.tiny)
                right = right - S(18)
            end
            local n = counts[row.id]
            if n then
                local label = tostring(n)
                local tw = U.measure(label, F.semi, T.tiny) + S(20)
                dl:AddRectFilled({ right - tw, y + S(6) }, { right, y + h - S(8) }, u32('#FFD166', 0.16), S(8))
                G.icon(dl, right - tw + S(9), y + h / 2 - 1, G.CP.pin, '#FFD166', T.tiny - 1)
                U.text_mid(dl, right - tw + S(15), y + h / 2 - 1, label, '#FFD166', F.semi, T.tiny)
                right = right - tw - S(6)
            end
            if row.floors > 1 then
                local label = tostring(row.floors)
                local tw = U.measure(label, F.semi, T.tiny) + S(22)
                G.icon(dl, right - tw + S(8), y + h / 2 - 1, G.CP.layers, P.faint, T.tiny - 1)
                U.text_mid(dl, right - tw + S(17), y + h / 2 - 1, label, P.faint, F.semi, T.tiny)
                right = right - tw - S(4)
            end
            U.text_mid(dl, tx, y + h / 2 - 1, U.fit(row.name, on and F.semi or F.text, T.small, right - tx - S(4)), on and P.text or mix(P.dim, P.text, 0.35 + 0.65 * hv),
                on and F.semi or F.text, T.small)
            if pressed then
                C.show(row.id, nil, { follow = false })
                if C.pad_on then st.pad_mode = 'map' end
            end
        end }
    end

    local function zones_tab(dl, x, y, w, h, t)
        imgui.SetCursorScreenPos({ x, y })
        local q = st.query.zones
        G.field('##vm_zsearch', 'Search zones and regions', q, w, T.small, 40)
        G.icon(dl, x + w - S(18), y + S(16), G.CP.search, P.faint, T.small)
        local text = (q[1] or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
        local counts = pin_counts()
        local rows = {}
        if text ~= '' then
            -- a flat list of what matches: zones by name, and every zone of a region that matches
            local n = 0
            for _, g in ipairs(groups()) do
                for _, r in ipairs(g.regions) do
                    local whole = r.lower:find(text, 1, true) ~= nil
                    local head = false
                    for _, z in ipairs(r.zones) do
                        if whole or z.lower:find(text, 1, true) then
                            if not head then
                                head = true
                                rows[#rows + 1] = { h = S(24), draw = function (rdl, rx, ry, rw)
                                    U.text_mid(rdl, rx + S(4), ry + S(14), r.name:upper(), P.accent2, F.disp, T.tiny)
                                end }
                            end
                            rows[#rows + 1] = zone_row(z, counts, S(12))
                            n = n + 1
                        end
                    end
                end
            end
            if n == 0 then
                rows[#rows + 1] = { h = S(60), draw = function (rdl, rx, ry, rw)
                    U.text_center(rdl, rx, ry + S(30), rw, 'No zone matches', P.faint, F.text, T.small)
                end }
            end
        else
            for gi, g in ipairs(groups()) do
                local shut = cfg.collapsed[g.name] == true
                rows[#rows + 1] = { h = S(34), draw = function (rdl, rx, ry, rw, rh)
                    imgui.SetCursorScreenPos({ rx, ry + S(4) })
                    local pressed, _, hv = U.hit('##vm_g' .. gi, rw, rh - S(6), S(7))
                    rdl:AddRectFilled({ rx, ry + S(4) }, { rx + rw, ry + rh - S(2) }, u32(P.card, 0.7 + 0.3 * hv), S(7))
                    G.icon(rdl, rx + S(14), ry + rh / 2 + 1, shut and G.CP.chev_right or G.CP.chev_down, mix(P.dim, P.text, hv), T.tiny)
                    U.text_mid(rdl, rx + S(28), ry + rh / 2 + 1, g.name:upper(), mix(P.text, '#FFFFFF', hv), F.disp, T.small)
                    local n = 0
                    for _, r in ipairs(g.regions) do n = n + #r.zones end
                    local label = tostring(n)
                    U.text_mid(rdl, rx + rw - U.measure(label, F.semi, T.tiny) - S(10), ry + rh / 2 + 1, label, P.faint, F.semi, T.tiny)
                    if pressed then
                        cfg.collapsed[g.name] = not shut or nil
                        C.save()
                    end
                end }
                if not shut then
                    for _, r in ipairs(g.regions) do
                        rows[#rows + 1] = { h = S(24), draw = function (rdl, rx, ry, rw)
                            U.text_mid(rdl, rx + S(12), ry + S(14), r.name:upper(), P.accent2, F.disp, T.tiny)
                            local lw = U.measure(r.name:upper(), F.disp, T.tiny)
                            rdl:AddLine({ rx + S(20) + lw, ry + S(14) }, { rx + rw - S(4), ry + S(14) }, u32(P.line), 1)
                        end }
                        for _, z in ipairs(r.zones) do rows[#rows + 1] = zone_row(z, counts, S(20)) end
                    end
                end
            end
        end
        list('##vm_zones', x, y + S(42), w, h - S(42), rows)
    end

    ---------------------------------------------------------------------------
    -- Pins
    ---------------------------------------------------------------------------

    local function ago(at)
        local d = os.time() - (at or 0)
        if d < 60 then return 'just now' end
        if d < 3600 then return math.floor(d / 60) .. ' min ago' end
        if d < 86400 then return math.floor(d / 3600) .. ' h ago' end
        return math.floor(d / 86400) .. ' d ago'
    end

    local function pin_row(pin, key, sub, on_click, unseen)
        return { h = S(48), draw = function (dl, x, y, w, h)
            local on = st.sel == pin
            imgui.SetCursorScreenPos({ x, y })
            local pressed, _, hv = U.hit(key, w, h - S(4), S(9))
            local color = K.COLORS[pin.color] or K.COLORS[1]
            dl:AddRectFilled({ x, y }, { x + w, y + h - S(4) }, u32(on and mix(P.card_hi, color, 0.18) or mix(P.card, P.card_hi, hv), 0.95), S(9))
            dl:AddRect({ x, y }, { x + w, y + h - S(4) }, u32(on and color or P.line, on and 0.9 or 0.8), S(9), 15, 1)
            G.pin(dl, x + S(22), y + S(36), S(9), (K.ICON_BY_ID[pin.icon] or K.ICONS[1]).cp, color, 1, 1, false, 0)
            local title = (pin.title or '') ~= '' and pin.title or 'Pin'
            U.text(dl, x + S(42), y + S(6), U.fit(title, F.semi, T.small, w - S(54)), P.text, F.semi, T.small)
            U.text(dl, x + S(42), y + S(24), U.fit(sub, F.text, T.tiny, w - S(54)), P.dim, F.text, T.tiny)
            if unseen then dl:AddCircleFilled({ x + w - S(12), y + S(12) }, S(4), u32('#FFD166'), 12) end
            if pressed then on_click() end
        end }
    end

    local function pins_tab(dl, x, y, w, h, t)
        imgui.SetCursorScreenPos({ x, y })
        local q = st.query.pins
        G.field('##vm_psearch', 'Search your pins', q, w, T.small, 40)
        G.icon(dl, x + w - S(18), y + S(16), G.CP.search, P.faint, T.small)
        local text = (q[1] or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
        local rows = {}
        local pins = C.pins()
        -- this map's first, then the rest by zone
        local order = {}
        for i, p in ipairs(pins) do order[i] = p end
        table.sort(order, function (a, b)
            local ah, bh = a.zone == st.zone and 0 or 1, b.zone == st.zone and 0 or 1
            if ah ~= bh then return ah < bh end
            if a.zone ~= b.zone then return C.zone_name(a.zone) < C.zone_name(b.zone) end
            return (a.id or 0) > (b.id or 0)
        end)
        local last_zone = nil
        for _, p in ipairs(order) do
            local zname = C.zone_name(p.zone)
            local hay = ((p.title or '') .. ' ' .. (p.note or '') .. ' ' .. zname):lower()
            if text == '' or hay:find(text, 1, true) then
                if p.zone ~= last_zone then
                    last_zone = p.zone
                    rows[#rows + 1] = { h = S(24), draw = function (rdl, rx, ry, rw)
                        U.text_mid(rdl, rx + S(4), ry + S(14), zname:upper(), p.zone == st.zone and P.cyan or P.accent2, F.disp, T.tiny)
                    end }
                end
                local sub = '(' .. C.square(p) .. ')'
                local z = DATA.zones[p.zone]
                if z and #z.floors > 1 then sub = sub .. '  ·  Map ' .. (DATA.floor(p.zone, p.floor).place) end
                if (p.note or '') ~= '' then sub = sub .. '  ·  ' .. p.note:gsub('%s+', ' ') end
                rows[#rows + 1] = pin_row(p, '##vm_p' .. tostring(p.id), sub, function ()
                    C.show(p.zone, p.floor, { at = { p.mx, p.my }, zoom = 2.0 })
                    C.CV.select(p)
                    if C.pad_on then st.pad_mode = 'map' end
                end)
            end
        end
        if #rows == 0 then
            rows[1] = { h = S(150), draw = function (rdl, rx, ry, rw)
                G.icon(rdl, rx + rw / 2, ry + S(46), G.CP.pin, P.faint, 26)
                U.text_center(rdl, rx, ry + S(84), rw, #pins == 0 and 'No pins yet' or 'No pin matches', P.dim, F.semi, T.small)
                if #pins == 0 then
                    U.text_center(rdl, rx, ry + S(106), rw, 'Right-click the map to drop one', P.faint, F.text, T.tiny)
                    U.text_center(rdl, rx, ry + S(122), rw, 'or type /vmap pin where you stand', P.faint, F.text, T.tiny)
                end
            end }
        end
        list('##vm_pins', x, y + S(42), w, h - S(42), rows)
    end

    local function shared_tab(dl, x, y, w, h, t)
        local rows = {}
        local shared = C.shared()
        for i, e in ipairs(shared) do
            local sub = (e.own and 'You shared' or (e.from ~= '' and e.from or 'Someone')) .. '  ·  ' .. C.zone_name(e.zone) .. ' (' .. C.square(e) .. ')  ·  ' .. ago(e.at)
            rows[#rows + 1] = pin_row(e, '##vm_s' .. i, sub, function ()
                C.open_shared(e)
                C.CV.select(e)
                if C.pad_on then st.pad_mode = 'map' end
            end, not e.seen)
        end
        if #rows == 0 then
            rows[1] = { h = S(170), draw = function (rdl, rx, ry, rw)
                G.icon(rdl, rx + rw / 2, ry + S(46), G.CP.inbox, P.faint, 26)
                U.text_center(rdl, rx, ry + S(84), rw, 'Nothing shared yet', P.dim, F.semi, T.small)
                U.text_center(rdl, rx, ry + S(106), rw, 'Pins that players share in chat', P.faint, F.text, T.tiny)
                U.text_center(rdl, rx, ry + S(122), rw, 'are kept here', P.faint, F.text, T.tiny)
            end }
        else
            rows[#rows + 1] = { h = S(40), draw = function (rdl, rx, ry, rw)
                if U.button(rdl, '##vm_shared_clear', rx + rw / 2 - S(60), ry + S(6), S(120), S(26), 'Clear the list', P.dim, 'ghost', nil, F.semi, T.tiny) then
                    for k = #shared, 1, -1 do shared[k] = nil end
                    if st.sel and st.sel.code then st.sel = nil end
                    C.save_pins()
                end
            end }
        end
        list('##vm_shared', x, y, w, h, rows)
    end

    function SB.draw(dl, x, y, w, h, t, dt)
        U.panel(dl, x, y, w, h, P.glass, 1, S(12), P.line)
        local ix, iy, iw = x + S(12), y + S(12), w - S(24)
        -- the tabs
        local unseen = 0
        for _, e in ipairs(C.shared()) do if not e.seen then unseen = unseen + 1 end end
        local no_nav = C.pad_on and imgui.PushItemFlag ~= nil
        if no_nav then imgui.PushItemFlag(2, true) end
        local tw = (iw - S(8)) / 3
        for i, tab in ipairs(TABS) do
            local tx = ix + (i - 1) * (tw + S(4))
            local on = cfg.side_tab == tab[1]
            imgui.SetCursorScreenPos({ tx, iy })
            local pressed, _, hv = U.hit('##vm_tab' .. i, tw, S(30), S(9))
            if on then
                dl:AddRectFilled({ tx, iy }, { tx + tw, iy + S(30) }, u32(P.accent, 0.28), S(9))
                dl:AddRect({ tx, iy }, { tx + tw, iy + S(30) }, u32(P.accent, 0.95), S(9), 15, 1)
            else
                dl:AddRectFilled({ tx, iy }, { tx + tw, iy + S(30) }, u32(P.accent, 0.05 + 0.1 * hv), S(9))
                dl:AddRect({ tx, iy }, { tx + tw, iy + S(30) }, u32(P.accent, 0.22 + 0.4 * hv), S(9), 15, 1)
            end
            local label = tab[2]
            U.text_center(dl, tx, iy + S(15), tw, label, on and P.text or mix(P.accent, P.dim, 0.45), F.semi, T.small)
            if tab[1] == 'shared' and unseen > 0 then
                dl:AddCircleFilled({ tx + tw - S(9), iy + S(8) }, S(4), u32('#FFD166'), 12)
            end
            if pressed then cfg.side_tab = tab[1] end
        end
        if no_nav then imgui.PopItemFlag() end
        local ly = iy + S(40)
        local lh = y + h - ly - S(10)
        if cfg.side_tab == 'pins' then pins_tab(dl, ix, ly, iw, lh, t)
        elseif cfg.side_tab == 'shared' then shared_tab(dl, ix, ly, iw, lh, t)
        else zones_tab(dl, ix, ly, iw, lh, t) end
    end

    return SB
end
