-- The map itself: the picture, moved and zoomed, with everything that sits on it (your arrow, your party, your
-- target, pins), its own controls (floors, zoom, the grid's letters along the edges), a pin's card, and the menus.
return function (C)
    local imgui = vana.imgui
    local U, G, PAD, DATA, TEX, K = C.U, C.G, C.PAD, C.DATA, C.TEX, C.K
    local P, F, T = U.P, U.fonts(), U.sizes()
    local S, u32, mix = U.S, U.u32, U.mix
    local cfg, st = C.cfg, C.st

    local CV = {}
    -- the view: the map point at the canvas's middle and the pixels a map unit takes, as shown now and as wanted
    local V = { cx = 256, cy = 256, z = 1, tx = 256, ty = 256, tz = 1, fit = 1, vx = 0, vy = 0, rect = nil, fresh = true }
    local M = { drag = false, moved = 0, hover_pin = nil, over_ui = false, ctx = nil, cursor = nil, old = nil, card_h = nil }
    local GROUP_COLOR = { [0] = '#5BE0FF', [1] = '#FFD166', [2] = '#C98BFF' }
    local SIZE = DATA.SIZE

    local function clock() return vana.time.clock() end
    local function to_screen(mx, my)
        local r = V.rect
        return r.x + r.w / 2 + (mx - V.cx) * V.z, r.y + r.h / 2 + (my - V.cy) * V.z
    end
    local function to_map(sx, sy)
        local r = V.rect
        return V.cx + (sx - r.x - r.w / 2) / V.z, V.cy + (sy - r.y - r.h / 2) / V.z
    end
    CV.to_screen, CV.to_map, CV.view, CV.state = to_screen, to_map, V, M

    local function limits() return V.fit * 0.8, math.max(V.fit * 10, 14) end

    -- The view stays on the map: an axis the whole map fits along is centred, and one it doesn't fit along stops with
    -- the map's edge a little inside the canvas's.
    local function clamp_target()
        local lo, hi = limits()
        V.tz = math.max(lo, math.min(hi, V.tz))
        local r = V.rect
        if r == nil then return end
        -- (the little way the map's edge may come inside the canvas's grows with the zoom: the whole map, at its fit,
        -- sits dead centre)
        local slack = 20 * math.max(0, math.min(1, (V.tz / V.fit - 1.05) / 0.3))
        local half_w, half_h = r.w / 2 / V.tz, r.h / 2 / V.tz
        if half_w * 2 >= SIZE + slack * 2 then V.tx = SIZE / 2
        else V.tx = math.max(half_w - slack, math.min(SIZE - half_w + slack, V.tx)) end
        if half_h * 2 >= SIZE + slack * 2 then V.ty = SIZE / 2
        else V.ty = math.max(half_h - slack, math.min(SIZE - half_h + slack, V.ty)) end
    end

    -- zoom by a factor, the map point under (sx, sy) staying under it
    local function zoom_about(factor, sx, sy)
        local r = V.rect
        if r == nil then return end
        local lo, hi = limits()
        local nz = math.max(lo, math.min(hi, V.tz * factor))
        local ox, oy = sx - r.x - r.w / 2, sy - r.y - r.h / 2
        local mx, my = V.tx + ox / V.tz, V.ty + oy / V.tz
        V.tx, V.ty, V.tz = mx - ox / nz, my - oy / nz, nz
        clamp_target()
        st.follow = false
    end

    local function centre_on(mx, my, times_fit)
        V.tx, V.ty = mx, my
        if times_fit then V.tz = V.fit * times_fit end
        clamp_target()
    end
    CV.centre_on = centre_on

    function CV.fit()
        V.tx, V.ty, V.tz = SIZE / 2, SIZE / 2, V.fit
        st.follow = false
    end

    -- the map is about to change: its picture is kept a moment, to fade out under the new one; the view goes into
    -- the history, so stepping back comes back to it
    function CV.leave()
        local h = st.history[st.hist_i]
        if h and h.zone == st.zone and h.floor == st.floor then h.view = { V.tx, V.ty, V.tz / math.max(0.001, V.fit) } end
        if M.tex then M.old = { tex = M.tex, cx = V.cx, cy = V.cy, z = V.z, at = clock() } end
    end

    function CV.arrive(changed, opts)
        M.want = opts
        if changed then M.shown_at = clock() M.hover_pin = nil end
    end

    local function apply_want()
        local o = M.want
        if o == nil then return end
        M.want = nil
        if o.view then
            V.tx, V.ty, V.tz = o.view[1], o.view[2], o.view[3] * V.fit
        elseif o.at then
            V.tx, V.ty = o.at[1], o.at[2]
            V.tz = V.fit * (o.zoom or 1)
        else
            V.tx, V.ty, V.tz = SIZE / 2, SIZE / 2, V.fit
        end
        clamp_target()
        -- a map that just opened is shown where it's wanted at once: the glide is for moves within a map
        if V.fresh or (clock() - (M.shown_at or 0)) < 0.05 then V.cx, V.cy, V.z = V.tx, V.ty, V.tz end
        V.fresh = false
    end

    ---------------------------------------------------------------------------
    -- The picture
    ---------------------------------------------------------------------------

    -- the picture's part that the canvas shows, rounded where it meets the canvas's own corners
    local function draw_picture(dl, tex, cx, cy, z, alpha)
        local r = V.rect
        local ix0, iy0 = r.x + r.w / 2 + (0 - cx) * z, r.y + r.h / 2 + (0 - cy) * z
        local span = SIZE * z
        local x0, y0 = math.max(ix0, r.x), math.max(iy0, r.y)
        local x1, y1 = math.min(ix0 + span, r.x + r.w), math.min(iy0 + span, r.y + r.h)
        if x1 <= x0 or y1 <= y0 then return end
        local u0, v0, u1, v1 = (x0 - ix0) / span, (y0 - iy0) / span, (x1 - ix0) / span, (y1 - iy0) / span
        local flags = 0
        if x0 <= r.x + 0.5 and y0 <= r.y + 0.5 then flags = flags + 16 end
        if x1 >= r.x + r.w - 0.5 and y0 <= r.y + 0.5 then flags = flags + 32 end
        if x0 <= r.x + 0.5 and y1 >= r.y + r.h - 0.5 then flags = flags + 64 end
        if x1 >= r.x + r.w - 0.5 and y1 >= r.y + r.h - 0.5 then flags = flags + 128 end
        local col = u32('#FFFFFF', alpha)
        if flags ~= 0 then
            dl:AddImageRounded(tex, { x0, y0 }, { x1, y1 }, { u0, v0 }, { u1, v1 }, col, r.radius, flags)
        else
            dl:AddImage(tex, { x0, y0 }, { x1, y1 }, { u0, v0 }, { u1, v1 }, col)
        end
    end

    ---------------------------------------------------------------------------
    -- Pins on the map
    ---------------------------------------------------------------------------

    local function pin_radius() return S(12) * (cfg.pin_size or 100) / 100 end

    -- this floor's pins, yours and (while it's selected) one that was shared; rebuilt when the pins change
    local function floor_pins()
        if M.pins_rev ~= C.pins_rev or M.pins_zone ~= st.zone or M.pins_floor ~= st.floor then
            M.pins_rev, M.pins_zone, M.pins_floor = C.pins_rev, st.zone, st.floor
            local list = {}
            for _, p in ipairs(C.pins()) do
                if p.zone == st.zone and p.floor == st.floor then list[#list + 1] = p end
            end
            M.pins = list
        end
        return M.pins
    end

    local function mine(pin) return pin ~= nil and pin.code == nil end

    function CV.close_card() M.card_open = false end
    -- in the middle of something of the mouse's (a drag of the map, a menu, typing in a card): the map keeps the mouse
    function CV.busy() return M.drag == true or M.ctx ~= nil or G.typing() end

    function CV.select(pin, card)
        st.sel = pin
        M.card_title, M.card_note = nil, nil
        if pin and card ~= false then M.card_open = true end
    end

    local function new_pin(mx, my)
        local pin = C.add_pin(st.zone, st.floor, mx, my, { icon = cfg.last_icon or 'pin', color = cfg.last_color or 1 })
        CV.select(pin)
        M.focus_title = 2
        return pin
    end

    ---------------------------------------------------------------------------
    -- The share menu and the right-click menu
    ---------------------------------------------------------------------------

    local function menu_row(dl, key, x, y, w, cp, label, color, hint)
        local h = S(30)
        imgui.SetCursorScreenPos({ x, y })
        local pressed, _, hv = U.hit(key, w, h, S(7))
        if hv > 0.01 then dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(color or P.accent, 0.16 * hv), S(7)) end
        G.icon(dl, x + S(16), y + h / 2, cp, mix(color or P.dim, P.text, hv * 0.5), T.small)
        U.text_mid(dl, x + S(34), y + h / 2, label, mix(P.text, '#FFFFFF', hv), F.text, T.small)
        if hint then
            local tw = U.measure(hint, F.text, T.tiny)
            U.text_mid(dl, x + w - tw - S(8), y + h / 2, hint, P.faint, F.text, T.tiny)
        end
        return pressed, y + h + S(2)
    end

    -- the popup's own window: sized by a Dummy, drawn on its draw list
    local function popup(id, w, h, body)
        imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
        if imgui.BeginPopup(id, 8 + 16) then
            local ok, err = pcall(function ()
                local dl = imgui.GetWindowDrawList()
                local x, y = imgui.GetWindowPos()
                dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(P.accent, P.line, 0.45), 0.95), S(10), 15, 1)
                body(dl, x, y)
            end)
            if not ok then C.fail('menu', err) imgui.CloseCurrentPopup() end
            imgui.EndPopup()
        end
    end

    -- Where a pin goes: a chat line, or the clipboard. Called in the window that called OpenPopup(id).
    function CV.share_popup(id, pin)
        local tname = nil
        local okt, tg = pcall(vana.game.target)
        if okt and tg and tg.active and (tg.index or 0) ~= 0 then
            local te = vana.game.entity(tg.index)
            if te and te.type == 0 and te.name and te.name ~= (C.me.name or '') then tname = te.name end
        end
        local rows = #C.CHANNELS + 1
        popup(id, S(236), S(48) + rows * S(32), function (dl, x, y)
            U.text(dl, x + S(14), y + S(10), 'SHARE THIS PIN', P.accent2, F.disp, T.tiny)
            dl:AddLine({ x + S(12), y + S(30) }, { x + S(224), y + S(30) }, u32(P.line), 1)
            local ry = y + S(36)
            for _, ch in ipairs(C.CHANNELS) do
                local label, hint, able = ch.name, ch.cmd:gsub('%s+$', ''), true
                if ch.id == 't' then
                    label = tname and ('Tell ' .. tname) or 'Tell (target a player)'
                    able = tname ~= nil
                end
                local pressed
                pressed, ry = menu_row(dl, '##sh_' .. ch.id, x + S(8), ry, S(220), ch.id == 't' and G.CP.user or G.CP.comment, label,
                    able and P.accent or P.faint, hint)
                if pressed and able then
                    C.share(pin, ch.id, tname)
                    imgui.CloseCurrentPopup()
                end
            end
            local pressed = menu_row(dl, '##sh_copy', x + S(8), ry, S(220), G.CP.copy, 'Copy the line', P.cyan)
            if pressed then
                C.share(pin, 'copy')
                imgui.CloseCurrentPopup()
            end
        end)
    end

    local function context_menu()
        local m = M.ctx
        if m == nil then return end
        if m.open then imgui.OpenPopup('##vm_ctx') m.open = false end
        local on_pin = m.pin ~= nil
        local rows = on_pin and 4 or 3
        local alive = false
        imgui.SetNextWindowSize({ S(230), S(16) + rows * S(32) }, U.ALWAYS)
        if imgui.BeginPopup('##vm_ctx', 8 + 16) then
            alive = true
            local ok, err = pcall(function ()
                local dl = imgui.GetWindowDrawList()
                local x, y = imgui.GetWindowPos()
                dl:AddRect({ x, y }, { x + S(230), y + S(16) + rows * S(32) }, u32(mix(P.accent, P.line, 0.45), 0.95), S(10), 15, 1)
                local ry, pressed = y + S(8), false
                if on_pin then
                    pressed, ry = menu_row(dl, '##cx_open', x + S(6), ry, S(218), G.CP.pen, mine(m.pin) and 'Edit this pin' or 'Open this pin', P.accent)
                    if pressed then CV.select(m.pin) imgui.CloseCurrentPopup() end
                    pressed, ry = menu_row(dl, '##cx_share', x + S(6), ry, S(218), G.CP.share, 'Share this pin', P.cyan)
                    if pressed then m.share = m.pin end
                    if mine(m.pin) then
                        pressed, ry = menu_row(dl, '##cx_del', x + S(6), ry, S(218), G.CP.trash, 'Remove this pin', P.danger)
                        if pressed then C.remove_pin(m.pin) imgui.CloseCurrentPopup() end
                    end
                else
                    pressed, ry = menu_row(dl, '##cx_pin', x + S(6), ry, S(218), G.CP.pin, 'Drop a pin here', P.accent, m.square)
                    if pressed then new_pin(m.mx, m.my) imgui.CloseCurrentPopup() end
                    pressed, ry = menu_row(dl, '##cx_share', x + S(6), ry, S(218), G.CP.share, 'Share this spot', P.cyan)
                    if pressed then m.share = { zone = st.zone, floor = st.floor, mx = m.mx, my = m.my, icon = 'pin', color = 1, title = '' } end
                end
                pressed, ry = menu_row(dl, '##cx_centre', x + S(6), ry, S(218), G.CP.crosshairs, 'Centre the map here', P.dim)
                if pressed then centre_on(m.mx, m.my) st.follow = false imgui.CloseCurrentPopup() end
                if m.share then
                    if not m.share_open then imgui.OpenPopup('##vm_ctx_share') m.share_open = true end
                    CV.share_popup('##vm_ctx_share', m.share)
                    if m.share_open and not imgui.IsPopupOpen('##vm_ctx_share') then imgui.CloseCurrentPopup() end
                end
            end)
            if not ok then C.fail('menu', err) end
            imgui.EndPopup()
        end
        if not alive and not m.open then M.ctx = nil end
    end

    ---------------------------------------------------------------------------
    -- A pin's card
    ---------------------------------------------------------------------------

    local function draw_card(dl, t)
        local pin = st.sel
        if pin == nil or not M.card_open or pin.zone ~= st.zone or pin.floor ~= st.floor then
            if st.pad_mode == 'card' then st.pad_mode = 'map' end
            return
        end
        local r = V.rect
        local own = mine(pin)
        local w = S(308)
        local h = own and S(356) or S(176)
        local sx, sy = to_screen(pin.mx, pin.my)
        local pr = pin_radius()
        -- beside the pin, on the side with the room, kept on the canvas
        local x = sx + pr + S(16)
        if x + w > r.x + r.w - S(8) then x = sx - pr - S(16) - w end
        x = math.max(r.x + S(8), math.min(x, r.x + r.w - w - S(8)))
        local y = math.max(r.y + S(8), math.min(sy - pr * 1.5 - h / 2, r.y + r.h - h - S(8)))
        local color = K.COLORS[pin.color] or K.COLORS[1]
        imgui.SetCursorScreenPos({ x, y })
        if imgui.BeginChild('##vm_card', { w, h }, 0, 8 + 16 + 128) then
            local ok, err = pcall(function ()
                local cdl = imgui.GetWindowDrawList()
                local mg = S(30)
                cdl:PushClipRect({ x - mg, y - mg }, { x + w + mg, y + h + mg }, false)
                U.shadow(cdl, x, y, w, h, S(14), 1)
                cdl:PopClipRect()
                U.panel(cdl, x, y, w, h, P.glass, 0.98, S(14), mix(color, P.line, 0.35), true)
                -- the head: the pin, its square, and where in the world that is
                local icon = K.ICON_BY_ID[pin.icon] or K.ICONS[1]
                G.pin(cdl, x + S(28), y + S(50), S(12), icon.cp, color, 1, 1, false, t)
                local f = DATA.floor(pin.zone, pin.floor)
                local wx, wy = DATA.to_world(f, pin.mx, pin.my)
                U.text(cdl, x + S(52), y + S(10), own and 'YOUR PIN' or (pin.own and 'YOU SHARED THIS' or ('FROM ' .. ((pin.from or '') ~= '' and pin.from:upper() or 'CHAT'))), color, F.disp, T.tiny)
                U.text(cdl, x + S(52), y + S(26), '(' .. C.square(pin) .. ')', P.text, F.dispb, T.h2)
                local sqw = U.measure('(' .. C.square(pin) .. ')', F.dispb, T.h2)
                U.text_mid(cdl, x + S(60) + sqw, y + S(37), string.format('X %.0f   Y %.0f', wx, wy), P.faint, F.text, T.tiny)
                imgui.SetCursorScreenPos({ x + w - S(34), y + S(8) })
                local closed, _, hv = U.hit('##vm_card_close', S(26), S(26), S(13))
                if hv > 0.01 then cdl:AddCircleFilled({ x + w - S(21), y + S(21) }, S(12), u32(P.text, 0.1 * hv), 20) end
                G.icon(cdl, x + w - S(21), y + S(21), G.CP.xmark, mix(P.dim, P.text, hv), T.small)
                if closed then M.card_open = false end
                local cy = y + S(62)
                local ix, iw = x + S(16), w - S(32)
                if own then
                    M.card_title = M.card_title or { pin.title or '' }
                    M.card_note = M.card_note or { pin.note or '' }
                    imgui.SetCursorScreenPos({ ix, cy })
                    if M.focus_title and M.focus_title > 0 then
                        M.focus_title = M.focus_title - 1
                        if M.focus_title == 0 then imgui.SetKeyboardFocusHere() M.focus_title = nil end
                    end
                    local changed, _, entered = G.field('##vm_pin_title', 'Title', M.card_title, iw, T.small, 40)
                    if changed then pin.title = M.card_title[1] C.save_pins() end
                    if entered then M.card_open = false end
                    cy = cy + S(40)
                    imgui.SetCursorScreenPos({ ix, cy })
                    local nchanged = G.field('##vm_pin_note', 'A note for yourself', M.card_note, iw, T.small, 240, S(58))
                    if nchanged then pin.note = M.card_note[1] C.save_pins() end
                    cy = cy + S(68)
                    -- the icons, eight to a row
                    local cell = iw / 8
                    for i, ic in ipairs(K.ICONS) do
                        local gx = ix + ((i - 1) % 8) * cell
                        local gy = cy + math.floor((i - 1) / 8) * cell
                        imgui.SetCursorScreenPos({ gx, gy })
                        if i == 1 and M.seat_card then
                            M.seat_card = M.seat_card - 1
                            imgui.SetKeyboardFocusHere()
                            if M.seat_card <= 0 then M.seat_card = nil end
                        end
                        local pressed, hovered, ihv = U.hit('##vm_ic' .. i, cell, cell, S(7))
                        local on = pin.icon == ic.id
                        if on then
                            cdl:AddRectFilled({ gx + S(2), gy + S(2) }, { gx + cell - S(2), gy + cell - S(2) }, u32(color, 0.24), S(7))
                            cdl:AddRect({ gx + S(2), gy + S(2) }, { gx + cell - S(2), gy + cell - S(2) }, u32(color, 0.95), S(7), 15, 1)
                        elseif ihv > 0.01 then
                            cdl:AddRectFilled({ gx + S(2), gy + S(2) }, { gx + cell - S(2), gy + cell - S(2) }, u32(P.text, 0.08 * ihv), S(7))
                        end
                        G.icon(cdl, gx + cell / 2, gy + cell / 2, ic.cp, on and color or mix(P.dim, P.text, ihv), T.body)
                        if hovered then G.tip(ic.name) end
                        if pressed then pin.icon = ic.id cfg.last_icon = ic.id C.save_pins() end
                    end
                    cy = cy + cell * math.ceil(#K.ICONS / 8) + S(8)
                    -- the colours
                    local sw8 = iw / 8
                    for i, hex in ipairs(K.COLORS) do
                        local gx, gy = ix + (i - 1) * sw8 + sw8 / 2, cy + S(12)
                        imgui.SetCursorScreenPos({ gx - S(13), gy - S(13) })
                        local pressed, hovered, chv = U.hit('##vm_col' .. i, S(26), S(26), S(13))
                        local on = pin.color == i
                        if on then for k = 2, 1, -1 do cdl:AddCircleFilled({ gx, gy }, S(9) + S(3) * k, u32(hex, 0.14), 24) end end
                        cdl:AddCircleFilled({ gx, gy }, S(9) + S(1.5) * chv, u32(hex), 24)
                        cdl:AddCircle({ gx, gy }, S(9) + S(1.5) * chv, u32('#FFFFFF', on and 0.95 or 0.25), 24, on and S(2) or 1)
                        if hovered then G.tip(K.COLOR_NAMES[i]) end
                        if pressed then pin.color = i cfg.last_color = i C.save_pins() end
                    end
                    cy = cy + S(34)
                    local bw = (iw - S(8)) / 2
                    if U.button(cdl, '##vm_pin_share', ix, cy, bw, S(32), 'Share', color, 'solid', 'paper-plane', F.semi, T.small) then
                        imgui.OpenPopup('##vm_card_share')
                    end
                    -- Remove asks once more (a pin with a note is a click away from gone)
                    local sure = M.sure_pin == pin and clock() - (M.sure_at or 0) < 3
                    if U.button(cdl, '##vm_pin_del', ix + bw + S(8), cy, bw, S(32), sure and 'Really?' or 'Remove', P.danger, sure and 'solid' or 'ghost', 'trash-can',
                            F.semi, T.small) then
                        if sure then
                            M.sure_pin = nil
                            C.remove_pin(pin)
                            return
                        end
                        M.sure_pin, M.sure_at = pin, clock()
                    end
                else
                    local title = (pin.title or '') ~= '' and pin.title or 'A pin shared in chat'
                    U.text(cdl, ix, cy, U.fit(title, F.semi, T.body, iw), P.text, F.semi, T.body)
                    U.text(cdl, ix, cy + S(22), C.zone_name(pin.zone), P.dim, F.text, T.small)
                    cy = cy + S(56)
                    local bw = (iw - S(8)) / 2
                    if M.seat_card then
                        M.seat_card = M.seat_card - 1
                        imgui.SetCursorScreenPos({ ix, cy })
                        imgui.SetKeyboardFocusHere()
                        if M.seat_card <= 0 then M.seat_card = nil end
                    end
                    if U.button(cdl, '##vm_pin_keep', ix, cy, bw, S(32), 'Save pin', color, 'solid', 'location-dot', F.semi, T.small) then
                        local kept = C.add_pin(pin.zone, pin.floor, pin.mx, pin.my, { icon = pin.icon, color = pin.color, title = pin.title or '',
                            note = (pin.from or '') ~= '' and ('From ' .. pin.from) or '' })
                        CV.select(kept)
                        return
                    end
                    if U.button(cdl, '##vm_pin_share', ix + bw + S(8), cy, bw, S(32), 'Share', P.cyan, 'ghost', 'paper-plane', F.semi, T.small) then
                        imgui.OpenPopup('##vm_card_share')
                    end
                end
                CV.share_popup('##vm_card_share', pin)
            end)
            if not ok then C.fail('card', err) M.card_open = false end
        end
        imgui.EndChild()
        M.card_rect = { x, y, w, h }
    end

    ---------------------------------------------------------------------------
    -- The controller on the map
    ---------------------------------------------------------------------------

    local function pad_map(dt, f)
        local r = V.rect
        local cur = M.cursor
        if cur == nil then cur = { x = r.x + r.w / 2, y = r.y + r.h / 2 } M.cursor = cur end
        local lx, ly, rx, ry = PAD.stick()
        local speed = S(620) * dt
        -- the left stick moves the pointer; at the canvas's edge it pushes the map along
        cur.x, cur.y = cur.x + lx * speed, cur.y - ly * speed
        local push = 0
        local inset = S(26)
        if cur.x < r.x + inset then V.tx = V.tx - (r.x + inset - cur.x) / V.z cur.x = r.x + inset push = 1 end
        if cur.x > r.x + r.w - inset then V.tx = V.tx + (cur.x - (r.x + r.w - inset)) / V.z cur.x = r.x + r.w - inset push = 1 end
        if cur.y < r.y + inset then V.ty = V.ty - (r.y + inset - cur.y) / V.z cur.y = r.y + inset push = 1 end
        if cur.y > r.y + r.h - inset then V.ty = V.ty + (cur.y - (r.y + r.h - inset)) / V.z cur.y = r.y + r.h - inset push = 1 end
        -- the right stick moves the map
        if math.abs(rx) + math.abs(ry) > 0 then
            V.tx, V.ty = V.tx + rx * speed * 1.1 / V.z, V.ty - ry * speed * 1.1 / V.z
            push = 1
        end
        if push == 1 then st.follow = false clamp_target() end
        -- the D-pad steps the pointer a grid square
        local step = 32 * V.z
        if PAD.repeating('left', 0.35, 0.09) then cur.x = cur.x - step end
        if PAD.repeating('right', 0.35, 0.09) then cur.x = cur.x + step end
        if PAD.repeating('up', 0.35, 0.09) then cur.y = cur.y - step end
        if PAD.repeating('down', 0.35, 0.09) then cur.y = cur.y + step end
        cur.x = math.max(r.x + S(4), math.min(r.x + r.w - S(4), cur.x))
        cur.y = math.max(r.y + S(4), math.min(r.y + r.h - S(4), cur.y))
        -- the triggers zoom about the pointer
        local zin = (PAD.down('r2') and 1 or 0) - (PAD.down('l2') and 1 or 0)
        if zin ~= 0 then zoom_about(math.exp(zin * dt * 1.5), cur.x, cur.y) end
        if PAD.pressed('r3') then CV.fit() end
        if PAD.pressed('l3') then C.here() end
        -- the bumpers change floors
        local z = DATA.zones[st.zone]
        local turn = (PAD.pressed('r1') and 1 or 0) - (PAD.pressed('l1') and 1 or 0)
        if turn ~= 0 and z and #z.floors > 1 then
            local at = 1
            for i, fl in ipairs(z.floors) do if fl.floor == st.floor then at = i end end
            local nf = z.floors[((at - 1 + turn) % #z.floors) + 1]
            C.show(st.zone, nf.floor)
        end
        if PAD.pressed('confirm') then
            local got = M.hover_pin
            if got then
                CV.select(got)
            elseif M.hover_way then
                C.go_way(M.hover_way)
            else
                local mx, my = to_map(cur.x, cur.y)
                if mx >= 0 and mx <= SIZE and my >= 0 and my <= SIZE then got = new_pin(mx, my) end
            end
            if got then
                -- the card is the controller's now: its icons, colours and buttons, with the D-pad (a title wants a
                -- keyboard, so the box isn't opened for typing)
                M.focus_title = nil
                st.pad_mode, M.seat_card = 'card', 3
            end
        end
        return cur
    end

    ---------------------------------------------------------------------------
    -- The canvas
    ---------------------------------------------------------------------------

    -- `bare`: the map alone (the bare map's window): no well round the picture, its buttons only while the pointer is on it
    function CV.draw(dl, x, y, w, h, t, dt, bare)
        local radius = bare and 0 or S(12)
        local rect = { x = x, y = y, w = w, h = h, radius = radius }
        local resized = V.rect == nil or V.rect.w ~= w or V.rect.h ~= h
        V.rect = rect
        local fit = math.min(w, h) / SIZE
        if resized and V.fit ~= fit then
            -- the window's size changed: the same part of the map stays in view
            local k = fit / math.max(0.0001, V.fit)
            V.tz, V.z = V.tz * k, V.z * k
        end
        V.fit = fit
        apply_want()

        -- the well the map lies in
        if not bare then dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.well), radius) end
        local zone = st.zone and DATA.zones[st.zone]
        local f = zone and DATA.floor(st.zone, st.floor)
        local entry, why = nil, nil
        if f then
            local sources = DATA.sources(f, cfg.quality)
            entry, why = TEX.get(sources)
        end
        -- (a picture let go while it was still fading out isn't drawn again)
        if M.tex_epoch ~= TEX.epoch then M.tex_epoch, M.old = TEX.epoch, nil end
        M.tex = entry and TEX.pick(entry, SIZE * V.z) or nil

        -- following you
        local me = C.me
        local me_here = me.ok and me.zone == st.zone and me.floor == st.floor and f ~= nil
        local mmx, mmy
        if me_here then
            mmx, mmy = DATA.to_map(f, me.x, me.y)
            if st.follow and not M.drag then V.tx, V.ty = mmx, mmy clamp_target() end
        end

        -- the glide
        local k = 1 - math.exp(-dt * 16)
        if not M.drag and (math.abs(V.vx) > 0.5 or math.abs(V.vy) > 0.5) then
            -- a thrown map slows to a stop
            V.tx, V.ty = V.tx + V.vx * dt, V.ty + V.vy * dt
            local decay = math.exp(-dt * 5)
            V.vx, V.vy = V.vx * decay, V.vy * decay
            clamp_target()
        end
        V.cx, V.cy = V.cx + (V.tx - V.cx) * k, V.cy + (V.ty - V.cy) * k
        V.z = V.z * (V.tz / V.z) ^ k

        -- the picture, and the one before it fading out
        local born = math.min(1, (clock() - (M.shown_at or 0)) / 0.22)
        if M.old then
            local age = (clock() - M.old.at) / 0.25
            if age >= 1 then M.old = nil
            else draw_picture(dl, M.old.tex, M.old.cx, M.old.cy, M.old.z, (1 - age)) end
        end
        if M.tex then
            draw_picture(dl, M.tex, V.cx, V.cy, V.z, M.old and born or 1)
        else
            G.icon(dl, x + w / 2, y + h / 2 - S(20), G.CP.map, P.faint, 34)
            U.text_center(dl, x, y + h / 2 + S(20), w, zone and "This map's file couldn't be read" or 'No map', P.dim, F.semi, T.body)
            if why then U.text_center(dl, x, y + h / 2 + S(42), w, U.fit(tostring(why), F.text, T.tiny, w - S(40)), P.faint, F.text, T.tiny) end
        end
        -- a soft edge inside the well, and its rim
        if not bare then
            dl:AddRect({ x, y }, { x + w, y + h }, u32('#000000', 0.35), radius, 15, S(3))
            dl:AddRect({ x, y }, { x + w, y + h }, u32(P.line, 0.95), radius, 15, 1)
        end

        -- the canvas takes the mouse (so a drag moves the map, not the window); the controls drawn after it lie over it
        imgui.SetCursorScreenPos({ x, y })
        imgui.SetNextItemAllowOverlap()
        imgui.InvisibleButton('##vm_canvas', { w, h }, 1 + 2) -- left and right buttons
        local hovered = imgui.IsItemHovered() and not M.over_ui
        local active = imgui.IsItemActive()
        local mx, my = imgui.GetMousePos()
        local io = imgui.GetIO()
        local pad_cursor = nil
        if C.pad_on and st.pad_mode == 'map' and f then
            pad_cursor = pad_map(dt, f)
        elseif not PAD.shown() then
            M.cursor = nil
        end
        local px, py = mx, my -- the pointer: the mouse's, or the controller's
        if pad_cursor and PAD.shown() then px, py = pad_cursor.x, pad_cursor.y end
        local pointing = (hovered and not PAD.shown()) or (pad_cursor ~= nil and PAD.shown())
        local hmx, hmy = to_map(px, py)

        -- the pin under the pointer
        local pr = pin_radius()
        local pins = f and floor_pins() or {}
        local over, best = nil, nil
        if pointing then
            local function try(p)
                local sx, sy = to_screen(p.mx, p.my)
                local dx, dy = px - sx, py - (sy - pr * 1.55)
                local d = dx * dx + dy * dy
                -- (the head, or the point under it)
                if (d <= (pr * 1.25) ^ 2 or (math.abs(px - sx) < pr * 0.7 and py <= sy + S(3) and py >= sy - pr * 1.55)) and (best == nil or d < best) then
                    over, best = p, d
                end
            end
            for _, p in ipairs(pins) do try(p) end
            if st.sel and not mine(st.sel) and st.sel.zone == st.zone and st.sel.floor == st.floor then try(st.sel) end
        end
        M.hover_pin = over
        -- the way into a neighbouring zone under the pointer (a pin there comes first)
        local ways = (f and cfg.exits) and C.ways(st.zone) or {}
        local over_way = nil
        if pointing and not over then
            local reach, nearest = (S(14)) ^ 2, nil
            for _, wy in ipairs(ways) do
                if wy.floor == st.floor then
                    local wmx, wmy = DATA.to_map(f, wy.x, wy.y)
                    local sx, sy = to_screen(wmx, wmy)
                    local d = (px - sx) ^ 2 + (py - sy) ^ 2
                    if d <= reach and (nearest == nil or d < nearest) then over_way, nearest = wy, d end
                end
            end
        end
        M.hover_way = over_way

        if hovered and not PAD.shown() then
            if io.MouseWheel ~= 0 then
                if bare and io.KeyShift then
                    cfg.bare_size = math.max(30, math.min(100, (cfg.bare_size or 82) + io.MouseWheel * 4))
                    M.save_soon = clock() + 1
                else
                    zoom_about(1.22 ^ io.MouseWheel, mx, my)
                end
            end
            if imgui.IsMouseDoubleClicked(0) and not over then
                local lo, hi = limits()
                local nz = math.min(hi, V.tz * 1.8)
                V.tx, V.ty, V.tz = hmx, hmy, nz
                clamp_target()
                st.follow = false
                M.skip_click = true
            end
            if imgui.IsMouseClicked(1) then
                M.ctx = { open = true, mx = hmx, my = hmy, pin = over, square = DATA.grid_of_map(hmx, hmy) }
            end
            if over or over_way then imgui.SetMouseCursor(7) end
        end
        if active and imgui.IsMouseDown(0) then
            local dx, dy = io.MouseDelta.x, io.MouseDelta.y
            if not M.drag then M.drag, M.moved = true, 0 end
            M.moved = M.moved + math.abs(dx) + math.abs(dy)
            if M.moved > S(4) and bare and (io.KeyShift or M.moving_window) then
                -- Shift + drag: the bare map itself goes with the hand
                local sw, sh = vana.ui.screen()
                cfg.bare_x = math.max(0, math.min(1, (cfg.bare_x or 0.5) + dx / sw))
                cfg.bare_y = math.max(0, math.min(1, (cfg.bare_y or 0.5) + dy / sh))
                M.moving_window, M.save_soon = true, clock() + 1
                imgui.SetMouseCursor(2)
            elseif M.moved > S(4) then
                V.tx, V.ty = V.tx - dx / V.z, V.ty - dy / V.z
                clamp_target()
                V.cx, V.cy = V.tx, V.ty -- the map under the hand, no glide
                if dt > 0 then
                    V.vx = U.lerp(V.vx, -dx / V.z / dt, 0.35)
                    V.vy = U.lerp(V.vy, -dy / V.z / dt, 0.35)
                end
                st.follow = false
                imgui.SetMouseCursor(2)
            end
        elseif M.drag then
            M.moving_window = nil
            -- let go: a click if it hardly moved
            if M.moved <= S(4) then
                V.vx, V.vy = 0, 0
                if M.skip_click then M.skip_click = false
                elseif M.press_pin then CV.select(M.press_pin)
                elseif M.press_way and M.press_way == over_way then C.go_way(M.press_way)
                elseif st.sel then st.sel = nil end
            elseif math.abs(V.vx) + math.abs(V.vy) < 40 then
                V.vx, V.vy = 0, 0
            end
            M.drag = false
        end
        if imgui.IsItemActivated() then M.press_pin, M.press_way = over, over_way end

        ---------------------------------------------------------------------
        -- what sits on the map
        ---------------------------------------------------------------------
        dl:PushClipRect({ x, y }, { x + w, y + h }, true)
        -- (what's on the map stays clear while the map itself is faded for walking)
        U.set_window_alpha(C.mark_alpha or 1)
        if f and M.tex then
            -- the ways into neighbouring zones
            for _, wy in ipairs(ways) do
                if wy.floor == st.floor then
                    local wmx, wmy = DATA.to_map(f, wy.x, wy.y)
                    local sx, sy = to_screen(wmx, wmy)
                    if sx > x - S(20) and sx < x + w + S(20) and sy > y - S(20) and sy < y + h + S(20) then
                        local hv = U.A.hover['way' .. wy.id] or 0
                        hv = U.lerp(hv, wy == over_way and 1 or 0, math.min(1, dt * 14))
                        U.A.hover['way' .. wy.id] = hv
                        G.way(dl, sx, sy, S(10), hv, t, 1)
                        if hv > 0.05 then
                            local label = 'To ' .. C.zone_name(wy.to)
                            local tw = U.measure(label, F.semi, T.small) + S(12)
                            G.tag(dl, sx - tw / 2, sy - S(26), label, P.cyan, hv, F.semi, T.small)
                        end
                    end
                end
            end
            -- pins, the hovered and the selected ones last
            local function draw_pin(p, sel)
                local sx, sy = to_screen(p.mx, p.my)
                if sx < x - pr * 3 or sx > x + w + pr * 3 or sy < y - pr or sy > y + h + pr * 4 then return end
                local key = p.id or p.code
                local hv = U.A.hover['pin' .. tostring(key)] or 0
                hv = U.lerp(hv, (p == over or sel) and 1 or 0, math.min(1, dt * 14))
                U.A.hover['pin' .. tostring(key)] = hv
                local lift, grow = 0, 1 + 0.22 * hv
                if p.born then
                    local age = (clock() - p.born) / 0.45
                    if age < 1 then
                        lift = (1 - U.ease(age)) * S(46)
                        grow = grow * U.spring(age)
                    else
                        p.born = nil
                    end
                end
                local icon = K.ICON_BY_ID[p.icon] or K.ICONS[1]
                local color = K.COLORS[p.color] or K.COLORS[1]
                local hy = G.pin(dl, sx, sy, pr, icon.cp, color, grow, 1, sel, t, lift)
                if (hv > 0.05 or sel) and (p.title or '') ~= '' and not (sel and M.card_open) then
                    local tw = U.measure(p.title, F.semi, T.small) + S(12)
                    G.tag(dl, sx - tw / 2, hy - pr * grow - S(14), p.title, color, math.max(hv, sel and 1 or 0), F.semi, T.small)
                end
            end
            for _, p in ipairs(pins) do if p ~= over and p ~= st.sel then draw_pin(p, false) end end
            if over and over ~= st.sel then draw_pin(over, false) end
            if st.sel and st.sel.zone == st.zone and st.sel.floor == st.floor then draw_pin(st.sel, true) end

            -- rings spreading from a place just opened: a shared pin, or where a way from the last map comes out
            if st.pings then
                local live = false
                for _, ping in ipairs(st.pings) do
                    local age = clock() - ping.at
                    if age <= 3.2 then
                        live = true
                        local sx, sy = to_screen(ping.mx, ping.my)
                        for i = 0, 2 do
                            local a = ((age * 0.9) + i / 3) % 1
                            -- (a dark ring under the gold one: gold alone is lost on a parchment map)
                            local fadeout = (1 - a) * math.min(1, 3.2 - age)
                            dl:AddCircle({ sx, sy }, S(10) + a * S(70), u32('#000000', 0.45 * fadeout), 48, S(5))
                            dl:AddCircle({ sx, sy }, S(10) + a * S(70), u32('#FFD166', 0.95 * fadeout), 48, S(2.5))
                        end
                    end
                end
                if not live then st.pings = nil end
            end

            -- your party and alliance
            for _, m in ipairs(C.party) do
                if m.floor == st.floor then
                    local pmx, pmy = DATA.to_map(f, m.x, m.y)
                    local sx, sy = to_screen(pmx, pmy)
                    local col = GROUP_COLOR[m.group] or GROUP_COLOR[0]
                    G.member(dl, sx, sy, S(10), col, U.JOBS[m.job], 1)
                    if cfg.names then G.tag(dl, sx + S(13), sy, m.name, col, 0.95) end
                end
            end
            -- your target
            local tg = C.target
            if tg and tg.floor == st.floor then
                local tmx, tmy = DATA.to_map(f, tg.x, tg.y)
                local sx, sy = to_screen(tmx, tmy)
                -- (a party member targeted has their own dot and name: the ring goes round it)
                local member = false
                for _, m in ipairs(C.party) do if m.name == tg.name then member = true end end
                G.reticle(dl, sx, sy, member and S(15) or S(9), P.danger, t, 1)
                if cfg.names and tg.name ~= '' and not member then G.tag(dl, sx + S(15), sy, tg.name, P.danger, 0.95) end
            end
            -- you; out of view, a small arrow at the edge points the way to you
            if me_here then
                local sx, sy = to_screen(mmx, mmy)
                local inset = S(20)
                if sx < x + inset or sx > x + w - inset or sy < y + inset or sy > y + h - inset then
                    local ex, ey = math.max(x + inset, math.min(x + w - inset, sx)), math.max(y + inset, math.min(y + h - inset, sy))
                    local ang = math.atan2(sy - ey, sx - ex)
                    dl:AddCircleFilled({ ex, ey }, S(14), u32(P.bg, 0.8), 24)
                    G.arrow(dl, ex, ey, S(8), ang, P.cyan, t, 1)
                else
                    G.arrow(dl, sx, sy, S(11), me.heading, P.cyan, t, 1)
                end
            end
        end
        -- the controller's pointer
        if pad_cursor and PAD.shown() then
            local cx, cy = pad_cursor.x, pad_cursor.y
            local col = over and '#FFD166' or '#FFFFFF'
            dl:AddCircle({ cx, cy }, S(11), u32('#000000', 0.6), 32, S(3.5))
            dl:AddCircle({ cx, cy }, S(11), u32(col, 0.95), 32, S(1.6))
            for i = 0, 3 do
                local c, s = math.cos(i * math.pi / 2), math.sin(i * math.pi / 2)
                dl:AddLine({ cx + c * S(5), cy + s * S(5) }, { cx + c * S(17), cy + s * S(17) }, u32(col, 0.95), S(1.6))
            end
        end

        U.set_window_alpha(C.win_alpha or 1)
        -- the grid's letters and numbers, along the edges while the map's own are out of view
        if cfg.rulers and f and M.tex and V.z > V.fit * 1.12 then
            local band = S(18)
            dl:AddRectFilledMultiColor({ x, y }, { x + w, y + band * 1.6 }, u32('#000000', 0.55), u32('#000000', 0.55), u32('#000000', 0), u32('#000000', 0))
            dl:AddRectFilledMultiColor({ x, y }, { x + band * 1.8, y + h }, u32('#000000', 0.55), u32('#000000', 0), u32('#000000', 0), u32('#000000', 0.55))
            for c = 0, 14 do
                local sx = to_screen(16 + 32 * c + 16, 0)
                if sx > x + band * 1.8 and sx < x + w - S(10) then
                    U.text_center(dl, sx - S(10), y + band / 2 + S(2), S(20), string.char(65 + c), '#FFFFFF', F.bold, T.tiny, 0.9)
                end
            end
            for rw = 1, 15 do
                local _, sy = to_screen(0, 16 + 32 * (rw - 1) + 16)
                if sy > y + band * 1.6 and sy < y + h - S(10) then
                    U.text_center(dl, x + S(2), sy, S(20), tostring(rw), '#FFFFFF', F.bold, T.tiny, 0.9)
                end
            end
        end
        dl:PopClipRect()

        ---------------------------------------------------------------------
        -- the map's own controls
        ---------------------------------------------------------------------
        local over_ui = false
        local function ui(pressed, hov) if hov then over_ui = true end return pressed end
        -- the bare map shows them only while the pointer is on it (and never while it's letting the mouse through)
        local inside = mx >= x and mx <= x + w and my >= y and my <= y + h and not C.pass
        M.ui_f = U.lerp(M.ui_f or 0, inside and 1 or 0, math.min(1, dt * 10))
        local show_ui = not bare or M.ui_f > 0.03
        if bare then U.set_window_alpha((C.win_alpha or 1) * M.ui_f) end
        if show_ui then
        local no_nav = C.pad_on and imgui.PushItemFlag ~= nil
        if no_nav then imgui.PushItemFlag(2, true) end
        -- the floors, top left
        if zone and #zone.floors > 1 then
            local fx, fy = x + S(12), y + S(12)
            if V.z > V.fit * 1.12 and cfg.rulers then fx, fy = x + S(40), y + S(34) end
            local bw = S(34)
            local per_row = math.max(1, math.floor((w - S(120)) / (bw + S(4))))
            for i, fl in ipairs(zone.floors) do
                local bx = fx + ((i - 1) % per_row) * (bw + S(4))
                local by2 = fy + math.floor((i - 1) / per_row) * (S(30) + S(4))
                local on = fl.floor == st.floor
                local mine_floor = me.ok and me.zone == st.zone and me.floor == fl.floor
                if ui(G.map_button(dl, '##vm_floor' .. i, bx, by2, bw, S(30), nil, tostring(i), on, 'Map ' .. i .. ' of ' .. #zone.floors ..
                        (mine_floor and ' (you are here)' or ''))) and not on then
                    C.show(st.zone, fl.floor)
                end
                if mine_floor then
                    dl:AddCircleFilled({ bx + bw - S(6), by2 + S(6) }, S(3.5), u32(P.cyan), 12)
                    dl:AddCircle({ bx + bw - S(6), by2 + S(6) }, S(3.5), u32(P.bg), 12, 1)
                end
            end
        end
        -- zoom, bottom right
        local zs = S(34)
        local zx, zy = x + w - zs - S(12), y + h - S(12) - zs * 3 - S(8)
        local on_me = me_here and st.follow
        if ui(G.map_button(dl, '##vm_findme', zx, zy - zs - S(12), zs, zs, G.CP.locate, nil, on_me, me.ok and 'Find me' or nil)) and me.ok then
            C.here(nil, bare == true)
        end
        if ui(G.map_button(dl, '##vm_zin', zx, zy, zs, zs, G.CP.plus, nil, false, 'Zoom in')) then zoom_about(1.5, x + w / 2, y + h / 2) end
        if ui(G.map_button(dl, '##vm_zout', zx, zy + zs + S(4), zs, zs, G.CP.minus, nil, false, 'Zoom out')) then zoom_about(1 / 1.5, x + w / 2, y + h / 2) end
        if ui(G.map_button(dl, '##vm_zfit', zx, zy + (zs + S(4)) * 2, zs, zs, G.CP.expand, nil, false, 'The whole map')) then CV.fit() end
        -- what the pointer is on, bottom left
        if f and pointing and hmx >= 16 and hmx < SIZE - 16 and hmy >= 16 and hmy < SIZE - 16 then
            local wx, wy = DATA.to_world(f, hmx, hmy)
            local label = string.format('(%s)    X %.0f   Y %.0f', DATA.grid_of_map(hmx, hmy), wx, wy)
            local tw, th = U.measure(label, F.semi, T.small)
            local bx, by2, bh = x + S(12), y + h - S(12) - th - S(12), th + S(12)
            dl:AddRectFilled({ bx, by2 }, { bx + tw + S(24), by2 + bh }, u32(P.bg, 0.86), bh / 2)
            dl:AddRect({ bx, by2 }, { bx + tw + S(24), by2 + bh }, u32(P.line, 0.9), bh / 2, 15, 1)
            U.text(dl, bx + S(12), by2 + S(6), label, P.text, F.semi, T.small)
        end
        -- which picture this is, top right
        if entry and not bare then
            local label = entry.from == 'game' and "Game's map" or (entry.w .. ' px')
            local tw, th = U.measure(label, F.semi, T.tiny)
            local bx, by2 = x + w - tw - S(30), y + S(12)
            dl:AddRectFilled({ bx, by2 }, { bx + tw + S(18), by2 + th + S(8) }, u32(P.bg, 0.7), (th + S(8)) / 2)
            U.text(dl, bx + S(9), by2 + S(4), label, entry.w >= 1024 and P.ok or P.dim, F.semi, T.tiny)
        end
        if no_nav then imgui.PopItemFlag() end
        end
        U.set_window_alpha(C.win_alpha or 1)
        if M.save_soon and clock() > M.save_soon then M.save_soon = nil C.save() end

        draw_card(dl, t)
        if M.card_rect and st.sel and M.card_open then
            local c = M.card_rect
            if mx >= c[1] and mx <= c[1] + c[3] and my >= c[2] and my <= c[2] + c[4] then over_ui = true end
        end
        M.over_ui = over_ui
        context_menu()
    end

    return CV
end
