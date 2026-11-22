-- The store's own look, over the family's kit (ui.lua): ffxiprivateservers.com's palette, its three faces (Press Start 2P
-- for a few headline words, Inter for what is read, JetBrains Mono for figures) and its stepped pixel frame, kept to the
-- featured card and the primary button. Everything else here is the kit's shapes in the site's colours.
local imgui = vana.imgui
local U = require('ui')
local P, F, T = U.P, U.fonts(), U.sizes()
local S, u32, mix = U.S, U.u32, U.mix

local L = { fonts = { loaded = false } }

-- the site's own colours (its stylesheet's :root)
local C = {
    bg0 = '#0A0F1F', bg1 = '#131C33', bg2 = '#1D2A47', panel = '#1A253F', panel2 = '#243456',
    ink = '#F6ECC6', dim = '#C9B97F', faint = '#7F7757',
    gold = '#F4C548', hot = '#FFD86B', amber = '#FF9E3B', teal = '#4DDBC0', teal_dim = '#2C8A7A',
    frame_light = '#C08B3B', frame_mid = '#3A2A16', frame_dark = '#06080F',
    red = '#E2484A', green = '#6CD05B', blue = '#6EA8FF',
    on_gold = '#140A00', on_teal = '#001A16', line = '#26324E',
}
L.C = C

-- the kit's palette, filled with the site's colours: its panels, sliders, toasts and focus ring follow
function L.apply()
    U.apply_theme('aurora')
    P.bg, P.glass, P.card, P.card_hi, P.well, P.line = C.bg0, C.bg1, C.panel, C.panel2, '#070B17', C.line
    P.accent, P.accent2, P.cyan = C.gold, C.amber, C.teal
    P.text, P.dim, P.faint = C.ink, C.dim, C.faint
    P.ok, P.warn, P.danger, P.gold, P.ink = C.teal, C.amber, C.red, C.hot, C.on_gold
end

function L.load_fonts()
    local dir = vana.paths.addon .. '\\fonts\\'
    local function try(file, size)
        if not vana.fs.exists(dir .. file) then return nil end
        local ok, font = pcall(imgui.AddFontFromFileTTF, dir .. file, size)
        return ok and font or nil
    end
    L.fonts.pix = try('PressStart2P-Regular.ttf', 16)
    L.fonts.mono = try('JetBrainsMono-Regular.ttf', 18) or F.text
    L.fonts.monom = try('JetBrainsMono-Medium.ttf', 18) or L.fonts.mono
    L.fonts.loaded = true
end

-------------------------------------------------------------------------------
-- Pixels
-------------------------------------------------------------------------------

local function round(v) return math.floor(v + 0.5) end
L.round = round

-- half of the site's 4px "pixel", in real pixels: the unit every stepped edge is drawn in
function L.px() return math.max(1, round(S(2))) end

-- Press Start 2P is drawn on an 8 by 8 grid: at a multiple of 8 real pixels and on whole pixels its squares stay sharp.
-- n is the size in eighths: 1 is the site's smallest label, 3 its headline here.
function L.pix_size(n) return math.max(8, round(S(8 * n) / 8) * 8) end
function L.pix_width(str, n, spacing)
    local px = L.pix_size(n)
    return #str * px + math.max(0, #str - 1) * round((spacing or 0) * px)
end
-- a few headline words; `shadow` is the colour of the site's hard drop under them (nil for none)
function L.pix(dl, x, y, str, color, n, alpha, shadow, spacing)
    local font = L.fonts.pix
    local px = L.pix_size(n)
    x, y = round(x), round(y)
    if font == nil then
        dl:AddText(F.bold, px, { x, y }, u32(color, alpha), str)
        return U.measure(str, F.bold, px / U.scale())
    end
    local step = px + round((spacing or 0) * px)
    local off = math.max(1, round(px / 8))
    local cs, cc = shadow and u32(shadow, alpha) or nil, u32(color, alpha)
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch ~= ' ' then
            local cx = x + (i - 1) * step
            if cs then dl:AddText(font, px, { cx + off, y + off }, cs, ch) end
            dl:AddText(font, px, { cx, y }, cc, ch)
        end
    end
    return L.pix_width(str, n, spacing), px
end

-- The same face set by its ink: each letter starts where its squares do and the gap between two is one square, so a
-- narrow letter (the T of VANASTORE sits a square in from its cell's edge) leaves no hole in a word. For the wordmark.
local TIGHT = { by = {} }
local function tight_layout(str, px)
    local key = px .. ':' .. str
    local lay = TIGHT.by[key]
    if lay ~= nil then return lay end
    lay = { at = {}, width = #str * px }
    local font = L.fonts.pix
    local ok, baked = pcall(function () return font:GetFontBaked(px) end)
    local unit, x, found = px / 8, 0, ok and baked ~= nil
    if found then
        for i = 1, #str do
            local ok2, g = pcall(baked.FindGlyph, baked, str:byte(i))
            if str:sub(i, i) == ' ' then
                lay.at[i] = x
                x = x + px / 2
            elseif ok2 and g and g.X1 > g.X0 then
                lay.at[i] = x - g.X0
                x = x + (g.X1 - g.X0) + unit
            else
                found = false
                break
            end
        end
    end
    if found then
        lay.width = x - unit
    else
        for i = 1, #str do lay.at[i] = (i - 1) * px end
    end
    TIGHT.by[key] = lay
    return lay
end
function L.pix_tight_width(str, n)
    if L.fonts.pix == nil then return L.pix_width(str, n) end
    return tight_layout(str, L.pix_size(n)).width
end
function L.pix_tight(dl, x, y, str, color, n, alpha, shadow)
    local font = L.fonts.pix
    if font == nil then return L.pix(dl, x, y, str, color, n, alpha, shadow) end
    local px = L.pix_size(n)
    local lay = tight_layout(str, px)
    x, y = round(x), round(y)
    local off = math.max(1, round(px / 8))
    local cs, cc = shadow and u32(shadow, alpha) or nil, u32(color, alpha)
    for i = 1, #str do
        local ch = str:sub(i, i)
        if ch ~= ' ' then
            local cx = x + round(lay.at[i])
            if cs then dl:AddText(font, px, { cx + off, y + off }, cs, ch) end
            dl:AddText(font, px, { cx, y }, cc, ch)
        end
    end
    return lay.width, px
end

-- The site's panel frame: a dark edge, a ring of light gold, a ring of brown, and a hard shadow down and to the right.
-- Returns how far the fill sits in from the edge. `hot` (0..1) turns the gold ring to the hover colour.
function L.frame(dl, x, y, w, h, fill, hot, alpha)
    local u = L.px()
    x, y, w, h = round(x), round(y), round(w), round(h)
    dl:AddRectFilled({ x + 2 * u, y + 2 * u }, { x + w + 2 * u, y + h + 2 * u }, u32(C.frame_dark, 0.85 * (alpha or 1)))
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(C.frame_dark, alpha))
    dl:AddRectFilled({ x + 2 * u, y + 2 * u }, { x + w - 2 * u, y + h - 2 * u }, u32(mix(C.frame_light, C.hot, hot or 0), alpha))
    dl:AddRectFilled({ x + 3 * u, y + 3 * u }, { x + w - 3 * u, y + h - 3 * u }, u32(C.frame_mid, alpha))
    dl:AddRectFilled({ x + 4 * u, y + 4 * u }, { x + w - 4 * u, y + h - 4 * u }, u32(fill or C.panel, alpha))
    return 4 * u
end

-- The site's button: a gold slab with a lit top-left edge and an amber bottom-right one, a dark edge and a hard shadow;
-- it steps up and left under the pointer and down into its shadow when pressed. `opts`: kind ('gold', 'teal', 'dark'),
-- disabled, progress (0..1: a bar grows across it), n (the label's size in eighths).
function L.pixel_button(dl, key, x, y, w, h, label, opts)
    opts = opts or {}
    x, y, w, h = round(x), round(y), round(w), round(h)
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = U.hit(key, w, h, 0)
    if opts.disabled then pressed, hv = false, 0 end
    local down = hovered and imgui.IsMouseDown(0) and not opts.disabled
    local u = L.px()
    local d = down and u or (hv > 0.5 and -math.max(1, round(u / 2)) or 0)
    local face, lit, shade, ink = C.gold, C.hot, C.amber, C.on_gold
    if opts.kind == 'teal' then face, lit, shade, ink = C.teal, '#8FF0DD', C.teal_dim, C.on_teal
    elseif opts.kind == 'dark' then face, lit, shade, ink = C.bg2, '#3D5685', '#0D172C', C.teal end
    if opts.ink then ink = opts.ink end
    local a = (opts.disabled and not opts.progress) and 0.45 or 1
    if not down then dl:AddRectFilled({ x + 2 * u, y + 2 * u }, { x + w + 2 * u, y + h + 2 * u }, u32(C.frame_dark, 0.9)) end
    local bx, by = x + d, y + d
    dl:AddRectFilled({ bx, by }, { bx + w, by + h }, u32(C.frame_dark))
    local ix, iy, iw, ih = bx + 2 * u, by + 2 * u, w - 4 * u, h - 4 * u
    dl:AddRectFilled({ ix, iy }, { ix + iw, iy + ih }, u32(face, a))
    local sweep = opts.progress and opts.progress < 0
    if sweep then
        -- how far isn't known: a block steps across the dark slab
        dl:AddRectFilled({ ix, iy }, { ix + iw, iy + ih }, u32(C.bg1))
        local cells = 12
        local cw = iw / cells
        local at = math.floor(U.clock() * 9) % (cells + 3) - 3
        for k = 0, 2 do
            local c = at + k
            if c >= 0 and c < cells then
                dl:AddRectFilled({ ix + round(c * cw), iy }, { ix + round((c + 1) * cw), iy + ih }, u32(face, 0.18 + 0.12 * k))
            end
        end
    elseif opts.progress then
        dl:AddRectFilled({ ix, iy }, { ix + iw, iy + ih }, u32(C.bg1))
        dl:AddRectFilled({ ix, iy }, { ix + round(iw * math.max(0, math.min(1, opts.progress))), iy + ih }, u32(face))
    end
    dl:AddRectFilled({ ix, iy }, { ix + iw, iy + u }, u32(lit, a))
    dl:AddRectFilled({ ix, iy }, { ix + u, iy + ih }, u32(lit, a))
    dl:AddRectFilled({ ix, iy + ih - u }, { ix + iw, iy + ih }, u32(shade, a))
    dl:AddRectFilled({ ix + iw - u, iy }, { ix + iw, iy + ih }, u32(shade, a))
    local n = opts.n or 1.5
    local tw, th = L.pix_width(label, n, 0.08), L.pix_size(n)
    local lx, ly = bx + (w - tw) / 2, by + (h - th) / 2 + (th >= 16 and round(th / 16) or 0)
    if sweep then
        L.pix(dl, lx, ly, label, face, n, 1, nil, 0.08)
    elseif opts.progress then
        local split = ix + round(iw * math.max(0, math.min(1, opts.progress)))
        dl:PushClipRect({ split, by }, { bx + w, by + h }, true)
        L.pix(dl, lx, ly, label, face, n, 1, nil, 0.08)
        dl:PopClipRect()
        dl:PushClipRect({ bx, by }, { split, by + h }, true)
        L.pix(dl, lx, ly, label, ink, n, 1, nil, 0.08)
        dl:PopClipRect()
    else
        L.pix(dl, lx, ly, label, ink, n, a, nil, 0.08)
    end
    if hovered and opts.tip then L.tip(opts.tip) end
    return pressed, hovered
end

-- The site's badge: a few pixel-font words on a flat colour with a dark edge. `kind`: 'teal' (installed / on),
-- 'quiet' (an outline: Trusted), 'faint' (an outline, dimmer: Pending review), 'red' (a refusal).
function L.chip_size(label) local u = L.px() return L.pix_width(label, 1, 0.08) + 6 * u, L.pix_size(1) + 5 * u end
function L.chip(dl, x, y, label, kind, alpha)
    local u = L.px()
    x, y = round(x), round(y)
    local w, h = L.chip_size(label)
    local tx, ty = x + 3 * u, y + round((h - L.pix_size(1)) / 2)
    if kind == 'teal' or kind == 'red' or kind == 'gold' then
        local bg = kind == 'teal' and C.teal or kind == 'red' and C.red or C.gold
        dl:AddRectFilled({ x + u, y + u }, { x + w + u, y + h + u }, u32(C.frame_dark, 0.9 * (alpha or 1)))
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(C.frame_dark, alpha))
        dl:AddRectFilled({ x + u, y + u }, { x + w - u, y + h - u }, u32(bg, alpha))
        L.pix(dl, tx, ty, label, kind == 'red' and '#FFFFFF' or kind == 'teal' and C.on_teal or C.on_gold, 1, alpha, nil, 0.08)
    else
        local col = kind == 'faint' and C.faint or C.dim
        dl:AddRect({ x + 0.5, y + 0.5 }, { x + w - 0.5, y + h - 0.5 }, u32(col, 0.55 * (alpha or 1)), 0, 0, 1)
        L.pix(dl, tx, ty, label, col, 1, alpha, nil, 0.08)
    end
    return w, h
end

-- a small heading over a block, as the site's "FFXI ADDONS"
function L.eyebrow(dl, x, y, label, color, alpha)
    return L.pix(dl, x, y, label, color or C.dim, 1, alpha, C.frame_dark, 0.16)
end

-------------------------------------------------------------------------------
-- Figures (JetBrains Mono)
-------------------------------------------------------------------------------

function L.mono(dl, x, y, str, color, size, alpha, medium)
    U.text(dl, x, y, str, color, medium and L.fonts.monom or L.fonts.mono, size or T.small, alpha)
end
function L.mono_width(str, size, medium) return U.measure(str, medium and L.fonts.monom or L.fonts.mono, size or T.small) end
function L.mono_mid(dl, x, cy, str, color, size, alpha, medium)
    U.text_mid(dl, x, cy, str, color, medium and L.fonts.monom or L.fonts.mono, size or T.small, alpha)
end

-------------------------------------------------------------------------------
-- Icons by code point, hints by the pointer (the family's, from vanamaps' gfx.lua)
-------------------------------------------------------------------------------

L.CP = {
    search = 0xF002, gear = 0xF013, xmark = 0xF00D, check = 0xF00C, rotate = 0xF2F9, back = 0xF060, forward = 0xF061,
    link = 0xF35D, download = 0xF019, shield = 0xF3ED, clock = 0xF017, box = 0xF466, cubes = 0xF1B3, globe = 0xF0AC,
    server = 0xF233, arrow_up = 0xF062, chev_left = 0xF053, chev_right = 0xF054, image = 0xF03E, warn = 0xF071,
    circle_up = 0xF0AA, layers = 0xF5FD, power = 0xF011, copy = 0xF0C5, user = 0xF007,
    star = 0xF005, cal_plus = 0xF271, az = 0xF15D, sort = 0xF160, chev_down = 0xF078, chev_up = 0xF077,
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

function L.icon(dl, cx, cy, cp, color, size, alpha)
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

local TIP = { text = nil, shown = nil, since = 0, alpha = 0 }
function L.tip(text) if not L.no_tips then TIP.text = text end end
function L.draw_tip(dt)
    local text = TIP.text
    TIP.text = nil
    if text ~= TIP.shown then TIP.shown, TIP.since = text, U.clock() end
    if text == nil then TIP.alpha = 0 return end
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
    dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(C.frame_light, P.line, 0.4), 0.95 * a), S(8), 240, 1)
    U.text(dl, x + S(10), y + S(6), text, P.text, F.text, T.small, a)
end

-- a round button with an icon, as the family's header buttons
function L.icon_button(dl, key, x, y, size, cp, color, tip, on)
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = U.hit(key, size, size, size / 2)
    local cx, cy = x + size / 2, y + size / 2
    dl:AddCircleFilled({ cx, cy }, size / 2, u32(color, (on and 0.2 or 0.07) + 0.14 * hv), 32)
    if hv > 0 or on then dl:AddCircle({ cx, cy }, size / 2, u32(color, on and 0.7 or 0.55 * hv), 32, 1) end
    L.icon(dl, cx, cy, cp, mix(color, C.hot, 0.6 * hv), T.body)
    if hovered and tip then L.tip(tip) end
    return pressed, hovered
end

-------------------------------------------------------------------------------
-- Quiet controls: the card's button, the switch, a text link
-------------------------------------------------------------------------------

-- the card's action: an outline in gold that fills under the pointer. `progress` 0..1 draws a bar in place of the fill.
function L.quiet_button(dl, key, x, y, w, h, label, opts)
    opts = opts or {}
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = U.hit(key, w, h, S(8))
    if opts.disabled then pressed, hv = false, 0 end
    local col = opts.color or C.gold
    local r = S(8)
    local a = (opts.disabled and not opts.progress) and 0.5 or 1
    if opts.progress then
        -- a bar that fills it from the left; the words are dark over the bar and gold past it
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(col, 0.10), r)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(col, 0.7), r, 240, 1)
        if opts.progress < 0 then
            -- how far isn't known: a band sweeps across it
            local at = (U.clock() * 0.9) % 1.4 - 0.2
            dl:PushClipRect({ x + w * math.max(0, at - 0.2), y }, { x + w * math.min(1, at + 0.2), y + h }, true)
            dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(col, 0.28), r)
            dl:PopClipRect()
            U.text_center(dl, x, y + h / 2, w, label, col, F.semi, T.small)
            return false, hovered
        end
        local split = x + w * math.max(0.03, math.min(1, opts.progress))
        dl:PushClipRect({ split, y }, { x + w, y + h }, true)
        U.text_center(dl, x, y + h / 2, w, label, col, F.semi, T.small)
        dl:PopClipRect()
        dl:PushClipRect({ x, y }, { split, y + h }, true)
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(col), r)
        U.text_center(dl, x, y + h / 2, w, label, C.on_gold, F.semi, T.small)
        dl:PopClipRect()
        return false, hovered
    else
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(col, (0.08 + 0.92 * hv) * a), r)
        dl:AddRect({ x, y }, { x + w, y + h }, u32(col, (0.55 + 0.45 * hv) * a), r, 240, 1)
    end
    U.draw_ripples(dl, key, x, y, w, h, '#FFFFFF')
    local fg = mix(col, C.on_gold, hv)
    U.text_center(dl, x, y + h / 2, w, label, fg, F.semi, T.small, a)
    if pressed then U.ripple_at(key) end
    if hovered and opts.tip then L.tip(opts.tip) end
    return pressed, hovered
end

-- on / off, in teal; returns the new value and whether it was pressed
local SW = {}
function L.switch(dl, key, x, cy, value, label, tip)
    local tw, th = S(38), S(20)
    local lw = label and (U.measure(label, F.semi, T.small) + S(8)) or 0
    imgui.SetCursorScreenPos({ x, cy - th / 2 })
    local pressed, hovered, hv = U.hit(key, tw + lw, th, th / 2, { x = x + lw, y = cy - th / 2, w = tw, h = th })
    if pressed then value = not value end
    local a = SW[key]
    if a == nil then a = value and 1 or 0 end
    a = U.lerp(a, value and 1 or 0, math.min(1, (imgui.GetIO().DeltaTime or 0.016) * 12))
    SW[key] = a
    if label then U.text_mid(dl, x, cy, label, mix(C.dim, C.teal, a), F.semi, T.small) end
    local sx = x + lw
    dl:AddRectFilled({ sx, cy - th / 2 }, { sx + tw, cy + th / 2 }, u32(mix('#0C1326', C.teal_dim, a)), th / 2)
    dl:AddRect({ sx, cy - th / 2 }, { sx + tw, cy + th / 2 }, u32(mix(C.line, C.teal, a), 0.9 + 0.1 * hv), th / 2, 240, 1)
    local kx = sx + th / 2 + (tw - th) * a
    dl:AddCircleFilled({ kx, cy + 1 }, th / 2 - S(3), u32('#000000', 0.4), 20)
    dl:AddCircleFilled({ kx, cy }, th / 2 - S(3), u32(mix('#8D93A6', '#F4FFFC', a)), 20)
    if hovered and tip then L.tip(tip) end
    return value, pressed, tw + lw
end

-- words that act as a link: dim, gold under the pointer, with a rule under them then
function L.link(dl, key, x, cy, label, opts)
    opts = opts or {}
    local font, size = opts.font or F.text, opts.size or T.small
    local tw, th = U.measure(label, font, size)
    local iw = opts.icon and (th + S(4)) or 0
    imgui.SetCursorScreenPos({ x, cy - th / 2 - S(3) })
    local pressed, hovered, hv = U.hit(key, tw + iw, th + S(6), S(4))
    local col = mix(opts.color or C.dim, C.hot, hv)
    local tx = x
    if opts.icon and not opts.icon_after then
        L.icon(dl, x + th / 2, cy, opts.icon, col, size * 0.85)
        tx = x + iw
    end
    U.text_mid(dl, tx, cy, label, col, font, size)
    if opts.icon and opts.icon_after then L.icon(dl, tx + tw + S(4) + th / 2, cy, opts.icon, col, size * 0.8) end
    if hv > 0.02 then dl:AddLine({ tx, cy + th / 2 + 1 }, { tx + tw * hv, cy + th / 2 + 1 }, u32(C.hot, 0.7 * hv), 1) end
    if hovered then
        imgui.SetMouseCursor(7)
        if opts.tip then L.tip(opts.tip) end
    end
    return pressed, hovered, tw + iw
end

-------------------------------------------------------------------------------
-- Pictures
-------------------------------------------------------------------------------

-- a picture filling a box, cropped to it about its top middle (a window's header is what tells it apart)
function L.cover(dl, tex, iw, ih, x, y, w, h, alpha, rounding, corners)
    local u0, v0, u1, v1 = 0, 0, 1, 1
    local ai, ab = iw / math.max(1, ih), w / math.max(1, h)
    if ai > ab then
        local f = ab / ai
        u0, u1 = (1 - f) / 2, (1 + f) / 2
    else
        v1 = ai / ab
    end
    local col = u32('#FFFFFF', alpha)
    if rounding and rounding > 0 and dl.AddImageRounded then
        dl:AddImageRounded(tex, { x, y }, { x + w, y + h }, { u0, v0 }, { u1, v1 }, col, rounding, corners or 240)
    else
        dl:AddImage(tex, { x, y }, { x + w, y + h }, { u0, v0 }, { u1, v1 }, col)
    end
end

-- a picture whole inside a box, on the site's darkest blue
function L.contain(dl, tex, iw, ih, x, y, w, h, alpha)
    local s = math.min(w / math.max(1, iw), h / math.max(1, ih))
    local dw, dh = iw * s, ih * s
    local dx, dy = x + (w - dw) / 2, y + (h - dh) / 2
    dl:AddImage(tex, { dx, dy }, { dx + dw, dy + dh }, { 0, 0 }, { 1, 1 }, u32('#FFFFFF', alpha))
    return dx, dy, dw, dh
end

-- what stands in for an addon with no picture: its initial in the headline face on the site's grid
function L.placeholder(dl, x, y, w, h, title, alpha, rounding, corners)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(C.bg1, alpha), rounding or 0, corners or 240)
    dl:PushClipRect({ x, y }, { x + w, y + h }, true)
    local g = math.max(8, L.px() * 8)
    local gx = x + g
    while gx < x + w do
        dl:AddLine({ round(gx) + 0.5, y }, { round(gx) + 0.5, y + h }, u32(C.teal, 0.05 * (alpha or 1)), 1)
        gx = gx + g
    end
    local gy = y + g
    while gy < y + h do
        dl:AddLine({ x, round(gy) + 0.5 }, { x + w, round(gy) + 0.5 }, u32(C.teal, 0.05 * (alpha or 1)), 1)
        gy = gy + g
    end
    local n = math.max(2, math.floor(h / S(8) / 3))
    local letter = (title or '?'):sub(1, 1):upper()
    local px = L.pix_size(n)
    -- (a lighter blue of the tile's own, not a third colour: the pictures beside it carry the colour)
    L.pix(dl, x + (w - px) / 2, y + (h - px) / 2, letter, '#3C5282', n, alpha, C.frame_dark)
    dl:PopClipRect()
end

-------------------------------------------------------------------------------
-- The text box (the family's: a gold ring, and a caret drawn here)
-------------------------------------------------------------------------------

local FIELD = { InputTextCursor = 33, TextDisabled = 1, TextSelectedBg = 53, active_frame = -10, state = {} }

-- returns changed, active, submitted (Enter)
function L.field(id, hint, buf, width, size, max)
    local im = imgui
    local fs = FIELD.state[id]
    if fs == nil then fs = { trust = false, last = buf[1] or '', edit_at = 0 } FIELD.state[id] = fs end
    im.SetNextItemWidth(width)
    im.PushStyleColor(FIELD.InputTextCursor, U.rgba(C.hot))
    im.PushStyleColor(FIELD.TextDisabled, U.rgba(C.faint))
    im.PushStyleColor(FIELD.TextSelectedBg, U.rgba(C.hot, 0.28))
    local caret_x, submitted
    local ok, err = pcall(U.with_font, F.text, size, function ()
        submitted = im.InputTextWithHint(id, hint, buf, max or 48, 64) -- 64: EnterReturnsTrue (ImGui 1.92)
        caret_x = im.CalcTextSize(buf[1] or '')
    end)
    im.PopStyleColor(3)
    if not ok then error(err, 0) end
    local x0, y0 = im.GetItemRectMin()
    local w, h = im.GetItemRectSize()
    local dl = im.GetWindowDrawList()
    local active, hovered = im.IsItemActive(), im.IsItemHovered()
    local now = U.clock()
    local text_now = buf[1] or ''
    local changed = text_now ~= fs.last
    if im.IsItemActivated() then
        fs.trust = text_now == ''
        fs.edit_at = now
    elseif active then
        for _, k in ipairs({ 513, 514, 519, 520 }) do -- Left, Right, Home, End
            if im.IsKeyPressed(k) then fs.trust = false end
        end
        if im.IsMouseClicked(0) and hovered then fs.trust = false end
    end
    if changed then fs.last, fs.edit_at = text_now, now end
    local r = S(9)
    if active then
        FIELD.active_frame = im.GetFrameCount()
        for i = 3, 1, -1 do
            local g = S(2) * i
            dl:AddRect({ x0 - g, y0 - g }, { x0 + w + g, y0 + h + g }, u32(C.hot, 0.06 * (4 - i)), r + g, 0, S(2))
        end
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(C.hot, 0.9), r, 0, math.max(1, S(1.5)))
        if fs.trust then
            local since = now - fs.edit_at
            if since < 0.5 or (since % 1.0) < 0.55 then
                local cx = x0 + S(12) + (tonumber(caret_x) or 0) + 1
                local fh = S(size)
                local cy = y0 + (h - fh) / 2
                dl:AddRectFilled({ cx, cy }, { cx + math.max(2, S(2)), cy + fh }, u32(C.hot, 0.95), 1)
            end
        end
    elseif hovered then
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(C.gold, 0.45), r, 0, math.max(1, S(1)))
        im.SetMouseCursor(1)
    else
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(P.line, 0.9), r, 0, 1)
    end
    return changed, active, submitted and active
end

-- whether a text box had the keyboard this frame or the last (Escape is the box's then)
function L.typing()
    return imgui.GetFrameCount() - FIELD.active_frame <= 1
end

return L
