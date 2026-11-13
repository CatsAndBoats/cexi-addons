-- Drawing that the kit (ui.lua) hasn't got: icons by code point, the map's markers (the player's arrow, pins, party
-- dots, the target's reticle), and the text box.
local imgui = vana.imgui
local U = require('ui')
local P, F, T = U.P, U.fonts(), U.sizes()
local S, u32, mix = U.S, U.u32, U.mix

local G = {}

-- Font Awesome code points the windows use (the pins' own are in pins.lua)
G.CP = {
    locate = 0xF601, crosshairs = 0xF05B, map = 0xF279, thumbtack = 0xF08D, share = 0xF1E0, copy = 0xF0C5, pen = 0xF304,
    trash = 0xF2ED, layers = 0xF5FD, back = 0xF060, forward = 0xF061, plus = 0xF067, minus = 0xF068, expand = 0xF065,
    compass = 0xF14E, search = 0xF002, bookmark = 0xF02E, bars = 0xF0C9, gear = 0xF013, xmark = 0xF00D, check = 0xF00C,
    save = 0xF0C7, plane = 0xF1D8, comment = 0xF075, gamepad = 0xF11B, info = 0xF05A, globe = 0xF0AC, pin = 0xF3C5,
    inbox = 0xF01C, chev_right = 0xF054, chev_down = 0xF078, chev_left = 0xF053, user = 0xF007, users = 0xF0C0,
    keyboard = 0xF11C, eye = 0xF06E, grip = 0xF58E, signs = 0xF277, image = 0xF03E, clock = 0xF017, bell = 0xF0F3,
    rotate = 0xF2F9, arrows = 0xF0B2, zoom_in = 0xF00E, zoom_out = 0xF010, link = 0xF0C1, bullhorn = 0xF0A1,
}

local glyphs = { str = {}, mid = {}, scale = nil }
local function utf8(c)
    local s = glyphs.str[c]
    if s == nil then
        s = string.char(224 + math.floor(c / 4096), 128 + math.floor(c / 64) % 64, 128 + c % 64)
        glyphs.str[c] = s
    end
    return s
end

-- an icon centred on (cx, cy); size in the kit's units
function G.icon(dl, cx, cy, cp, color, size, alpha)
    if glyphs.scale ~= U.scale() then glyphs.mid, glyphs.scale = {}, U.scale() end
    local px = S(size)
    local key = cp * 4096 + math.floor(px * 4 + 0.5)
    local c = glyphs.mid[key]
    if c == nil then
        local gx, gy
        local ok, baked = pcall(F.icons.GetFontBaked, F.icons, px)
        if ok and baked then
            local ok2, g = pcall(baked.FindGlyph, baked, cp)
            if ok2 and g and g.X1 > g.X0 then gx, gy = (g.X0 + g.X1) / 2, (g.Y0 + g.Y1) / 2 end
        end
        if gx == nil then
            local w, h = U.measure(utf8(cp), F.icons, size)
            gx, gy = w / 2, h / 2
        end
        c = { gx, gy }
        glyphs.mid[key] = c
    end
    dl:AddText(F.icons, px, { cx - c[1], cy - c[2] }, u32(color, alpha), utf8(cp))
end

-- A hint by the pointer for the thing it is on: said while drawing, drawn by G.draw_tip at the frame's end over
-- everything (ImGui's own tooltip comes without its background in this theme).
local TIP = { text = nil, shown = nil, since = 0, alpha = 0 }
function G.tip(text) TIP.text = text end
function G.draw_tip(dt)
    local text = TIP.text
    TIP.text = nil
    if text ~= TIP.shown then TIP.shown, TIP.since = text, U.clock() end
    if text == nil then TIP.alpha = 0 return end
    -- (a moment's rest on the thing first, so a pointer crossing the window doesn't trail hints)
    if U.clock() - TIP.since < 0.35 then return end
    TIP.alpha = math.min(1, TIP.alpha + dt * 8)
    local dl = imgui.GetForegroundDrawList()
    local mx, my = imgui.GetMousePos()
    local tw, th = U.measure(text, F.text, T.small)
    local w, h = tw + S(20), th + S(12)
    local sw, sh = vana.ui.screen()
    local x, y = mx + S(14), my + S(20)
    if x + w > sw - S(6) then x = mx - w - S(8) end
    if y + h > sh - S(6) then y = my - h - S(10) end
    local a = TIP.alpha
    dl:AddRectFilled({ x, y + S(2) }, { x + w, y + h + S(2) }, u32('#000000', 0.35 * a), S(8))
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.glass, 0.98 * a), S(8))
    dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(P.accent, P.line, 0.5), 0.95 * a), S(8), 15, 1)
    U.text(dl, x + S(10), y + S(6), text, P.text, F.text, T.small, a)
end

-- a round button with one of those icons (the kit's icon_button takes its own names only)
function G.icon_button(dl, key, x, y, size, cp, color, tip, on)
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = U.hit(key, size, size, size / 2)
    local cx, cy = x + size / 2, y + size / 2
    dl:AddCircleFilled({ cx, cy }, size / 2, u32(color, (on and 0.2 or 0.08) + 0.16 * hv), 32)
    if hv > 0 or on then dl:AddCircle({ cx, cy }, size / 2, u32(color, on and 0.7 or 0.55 * hv), 32, 1) end
    G.icon(dl, cx, cy, cp, mix(color, P.text, 0.35 * hv), T.body)
    if hovered and tip then G.tip(tip) end
    return pressed, hovered
end

-- a square glass button for the map's own controls (zoom, floors): dark, so it reads over any map
function G.map_button(dl, key, x, y, w, h, cp, label, on, tip)
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = U.hit(key, w, h, S(8))
    local col = on and P.accent or P.text
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.bg, 0.86), S(8))
    if on then dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.accent, 0.26), S(8)) end
    if hv > 0 then dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.text, 0.08 * hv), S(8)) end
    dl:AddRect({ x, y }, { x + w, y + h }, u32(on and P.accent or P.line, on and 0.95 or (0.9 + 0.1 * hv)), S(8), 15, 1)
    if cp then
        G.icon(dl, x + (label and S(14) or w / 2), y + h / 2, cp, mix(col, P.text, hv * 0.4), T.small)
    end
    if label then
        local lx = x + (cp and S(26) or 0)
        U.text_center(dl, lx, y + h / 2, w - (cp and S(30) or 0), label, on and P.text or mix(P.dim, P.text, hv), F.semi, T.small)
    end
    if hovered and tip then G.tip(tip) end
    return pressed, hovered
end

-- a point turned by an angle about (cx, cy)
local function turn(cx, cy, c, s, x, y) return { cx + x * c - y * s, cy + x * s + y * c } end

-- The player's arrow: a chevron pointing along `angle` (radians, 0 = the map's right, clockwise), over a soft pulse.
function G.arrow(dl, cx, cy, r, angle, color, t, alpha)
    alpha = alpha or 1
    local c, s = math.cos(angle), math.sin(angle)
    local pulse = (t * 0.7) % 1
    dl:AddCircle({ cx, cy }, r * (1.1 + 1.5 * pulse), u32(color, 0.5 * (1 - pulse) * alpha), 40, S(1.5))
    for i = 3, 1, -1 do dl:AddCircleFilled({ cx, cy }, r * (0.9 + 0.35 * i), u32(color, 0.07 * alpha), 32) end
    local tip, bl, notch, br = turn(cx, cy, c, s, r * 1.15, 0), turn(cx, cy, c, s, -r * 0.85, r * 0.78), turn(cx, cy, c, s, -r * 0.4, 0),
        turn(cx, cy, c, s, -r * 0.85, -r * 0.78)
    -- its shadow, a touch down
    local d = S(1.5)
    dl:AddTriangleFilled({ tip[1], tip[2] + d }, { bl[1], bl[2] + d }, { notch[1], notch[2] + d }, u32('#000000', 0.45 * alpha))
    dl:AddTriangleFilled({ tip[1], tip[2] + d }, { notch[1], notch[2] + d }, { br[1], br[2] + d }, u32('#000000', 0.45 * alpha))
    dl:AddTriangleFilled(tip, bl, notch, u32(mix(color, '#FFFFFF', 0.25), alpha))
    dl:AddTriangleFilled(tip, notch, br, u32(mix(color, '#000000', 0.12), alpha))
    local line = u32('#FFFFFF', 0.95 * alpha)
    local wdt = math.max(1.2, S(1.4))
    dl:AddLine(tip, bl, line, wdt) dl:AddLine(bl, notch, line, wdt) dl:AddLine(notch, br, line, wdt) dl:AddLine(br, tip, line, wdt)
end

-- A pin: a drop standing on (x, y), its icon in the head. `grow` 1 is its usual size; `lift` raises it (the fall-in).
function G.pin(dl, x, y, r, cp, color, grow, alpha, selected, t, lift)
    alpha = alpha or 1
    r = r * (grow or 1)
    local hy = y - r * 1.55 - (lift or 0)
    -- its shadow on the ground
    dl:AddEllipseFilled({ x, y + r * 0.08 }, { r * 0.62, r * 0.22 }, u32('#000000', 0.38 * alpha), 0, 20)
    if selected then
        local pulse = 0.6 + 0.4 * math.sin((t or 0) * 4)
        for i = 3, 1, -1 do dl:AddCircleFilled({ x, hy }, r + S(2.5) * i, u32(color, 0.10 * pulse * alpha), 32) end
    end
    local dark = mix(color, '#000000', 0.35)
    dl:AddTriangleFilled({ x - r * 0.78, hy + r * 0.62 }, { x + r * 0.78, hy + r * 0.62 }, { x, y - (lift or 0) }, u32(dark, alpha))
    dl:AddCircleFilled({ x, hy }, r, u32(color, alpha), 32)
    dl:AddCircleFilled({ x, hy }, r * 0.74, u32(mix(color, '#000000', 0.55), alpha), 28)
    dl:AddCircle({ x, hy }, r, u32('#FFFFFF', (selected and 0.95 or 0.55) * alpha), 32, selected and S(1.8) or S(1.1))
    -- (the icon's size in the kit's units: r is in pixels already)
    G.icon(dl, x, hy, cp, '#FFFFFF', r * 0.92 / math.max(0.01, U.scale()), alpha)
    return hy
end

-- a party member's dot with its job's letters
function G.member(dl, x, y, r, color, label, alpha)
    alpha = alpha or 1
    dl:AddCircleFilled({ x, y + S(1.5) }, r, u32('#000000', 0.45 * alpha), 24)
    dl:AddCircleFilled({ x, y }, r, u32(mix(color, P.ink, 0.55), alpha), 24)
    dl:AddCircle({ x, y }, r, u32(color, alpha), 24, S(1.6))
    if label then U.text_center(dl, x - r, y, r * 2, label, color, F.bold, (r * 0.78) / math.max(0.01, U.scale()), alpha) end
end

-- the target's reticle
function G.reticle(dl, x, y, r, color, t, alpha)
    alpha = alpha or 1
    local a = t * 1.2
    dl:AddCircle({ x, y }, r, u32('#000000', 0.5 * alpha), 32, S(3.2))
    dl:AddCircle({ x, y }, r, u32(color, alpha), 32, S(1.6))
    for i = 0, 3 do
        local c, s = math.cos(a + i * math.pi / 2), math.sin(a + i * math.pi / 2)
        dl:AddLine({ x + c * r * 0.55, y + s * r * 0.55 }, { x + c * r * 1.45, y + s * r * 1.45 }, u32(color, alpha), S(1.6))
    end
    dl:AddCircleFilled({ x, y }, S(2), u32(color, alpha), 12)
end

-- a name tag beside a marker: a dark pill, so it reads over a parchment map or a blue one
function G.tag(dl, x, cy, label, color, alpha, font, size)
    font, size = font or F.semi, size or T.tiny
    local tw, th = U.measure(label, font, size)
    local w, h = tw + S(12), th + S(6)
    dl:AddRectFilled({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(P.bg, 0.88 * (alpha or 1)), h / 2)
    dl:AddRect({ x, cy - h / 2 }, { x + w, cy + h / 2 }, u32(color or P.line, 0.7 * (alpha or 1)), h / 2, 15, 1)
    U.text(dl, x + S(6), cy - th / 2, label, color or P.text, font, size, alpha)
    return w, h
end

-------------------------------------------------------------------------------
-- The text box (the Auction House's: a gold ring, and a caret drawn here, since ImGui's is one pixel wide however
-- large the screen)
-------------------------------------------------------------------------------

local FIELD = { InputTextCursor = 33, TextDisabled = 1, TextSelectedBg = 53, active_frame = -10, state = {}, GOLD = '#FFD166' }
G.FIELD = FIELD

-- returns changed, active, submitted (Enter)
function G.field(id, hint, buf, width, size, max, height)
    local im = imgui
    local fs = FIELD.state[id]
    if fs == nil then fs = { trust = false, last = buf[1] or '', edit_at = 0 } FIELD.state[id] = fs end
    im.SetNextItemWidth(width)
    im.PushStyleColor(FIELD.InputTextCursor, U.rgba(FIELD.GOLD))
    im.PushStyleColor(FIELD.TextDisabled, U.rgba(P.faint))
    im.PushStyleColor(FIELD.TextSelectedBg, U.rgba(FIELD.GOLD, 0.28))
    local changed, caret_x, submitted
    local ok, err = pcall(U.with_font, F.text, size, function ()
        if height then
            changed = im.InputTextMultiline(id, buf, max or 200, { width, height }, 0)
        else
            changed = im.InputTextWithHint(id, hint, buf, max or 48, 64) -- 64: EnterReturnsTrue (ImGui 1.92)
            submitted = changed
            caret_x = im.CalcTextSize(buf[1] or '')
        end
    end)
    im.PopStyleColor(3)
    if not ok then error(err, 0) end
    local x0, y0 = im.GetItemRectMin()
    local w, h = im.GetItemRectSize()
    local dl = im.GetWindowDrawList()
    local active, hovered = im.IsItemActive(), im.IsItemHovered()
    local now = U.clock()
    local text_now = buf[1] or ''
    if height == nil then
        -- (with EnterReturnsTrue the box says "changed" only on Enter: the text is compared instead)
        changed = text_now ~= fs.last
    end
    if im.IsItemActivated() then
        fs.trust = text_now == ''
        fs.edit_at = now
    elseif active then
        for _, k in ipairs({ 513, 514, 519, 520 }) do -- Left, Right, Home, End
            if im.IsKeyPressed(k) then fs.trust = false end
        end
        if im.IsMouseClicked(0) and hovered then fs.trust = false end
    end
    if text_now ~= fs.last then fs.last, fs.edit_at = text_now, now end
    local r = S(9)
    if active then
        FIELD.active_frame = im.GetFrameCount()
        for i = 3, 1, -1 do
            local g = S(2) * i
            dl:AddRect({ x0 - g, y0 - g }, { x0 + w + g, y0 + h + g }, u32(FIELD.GOLD, 0.07 * (4 - i)), r + g, 0, S(2))
        end
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(FIELD.GOLD, 0.9), r, 0, math.max(1, S(1.5)))
        if fs.trust and height == nil then
            local since = now - fs.edit_at
            if since < 0.5 or (since % 1.0) < 0.55 then
                local cx = x0 + S(12) + (tonumber(caret_x) or 0) + 1
                local fh = S(size)
                local cy = y0 + (h - fh) / 2
                dl:AddRectFilled({ cx, cy }, { cx + math.max(2, S(2)), cy + fh }, u32(FIELD.GOLD, 0.95), 1)
            end
        end
    elseif hovered then
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(P.accent, 0.45), r, 0, math.max(1, S(1)))
        im.SetMouseCursor(1)
    else
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(P.line, 0.9), r, 0, 1)
    end
    if height and text_now == '' and not active and hint then
        U.text(dl, x0 + S(12), y0 + S(7), hint, P.faint, F.text, size)
    end
    return changed, active, submitted and active
end

-- whether a text box had the keyboard this frame or the last (Escape and the open key are the box's then)
function G.typing()
    return imgui.GetFrameCount() - FIELD.active_frame <= 1
end

return G
