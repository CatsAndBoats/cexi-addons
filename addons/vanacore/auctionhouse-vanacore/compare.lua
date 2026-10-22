-- Compare: what a piece of gear does, read from the game's own description of it, and the card that sets it against
-- what you're wearing in that slot. The stats are the description's (DEF:20 HP+10 STR+4 ...), with damage and delay
-- from the item's record; what isn't a plain number (latent effects, set bonuses, "Additional effect", prose) is kept
-- as notes and shown as words. Your equipment comes from vana.game.equipment(). Nothing here touches the network.
local imgui = vana.imgui
local bit = require('bit')
local U = require('ui')
local I = require('items')
local P, S = U.P, U.S
local T, F = U.sizes(), U.fonts()
local u32, text, measure, mix, fit, wrap, icon = U.u32, U.text, U.measure, U.mix, U.fit, U.wrap, U.icon
local GOLD = '#FFD166'

local C = {}

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

-------------------------------------------------------------------------------
-- Slots and what you wear in them
-------------------------------------------------------------------------------

-- the game's equipment slots, in its order; an item's Slots mask has bit n for slot n
local SLOT = { [0] = 'Main', 'Sub', 'Ranged', 'Ammo', 'Head', 'Body', 'Hands', 'Legs', 'Feet', 'Neck', 'Waist',
    'Ear 1', 'Ear 2', 'Ring 1', 'Ring 2', 'Back' }
C.SLOT = SLOT

-- the slots a piece could take: either of a pair for earrings and rings, otherwise the first slot it names
-- (a one-handed weapon names Main and Sub; it's set against your main hand)
local function slots_for(mask)
    mask = tonumber(mask) or 0
    if mask == 0 then return nil end
    if bit.band(mask, 0x1800) ~= 0 then return { 11, 12 } end
    if bit.band(mask, 0x6000) ~= 0 then return { 13, 14 } end
    for s = 0, 15 do if bit.band(mask, bit.lshift(1, s)) ~= 0 then return { s } end end
    return nil
end

-- what's in each slot: read at most twice a second, and only while a card is up
local worn = { at = -10, ids = {} }
local function wearing(slot)
    local now = U.clock()
    if now - worn.at > 0.5 then
        worn.at, worn.ids = now, {}
        local ok, eq = pcall(vana.game.equipment)
        if ok and type(eq) == 'table' then
            local bags = {}
            for s = 0, 15 do
                local e = eq[s]
                if type(e) == 'table' and (tonumber(e.index) or 0) > 0 then
                    local c = tonumber(e.container) or 0
                    if bags[c] == nil then
                        local okc, b = pcall(vana.game.container, c)
                        bags[c] = okc and type(b) == 'table' and b or false
                    end
                    local it = bags[c] and bags[c][e.index]
                    local iid = type(it) == 'table' and tonumber(it.id) or 0
                    if iid > 0 and iid < 65535 then worn.ids[s] = iid end
                end
            end
        end
    end
    return worn.ids[slot]
end
C.wearing = wearing

-------------------------------------------------------------------------------
-- Reading a description
-------------------------------------------------------------------------------

-- the game writes an element as a glyph, 0xEF then 0x1F (Fire) to 0x26 (Dark); on gear it's a resistance
local ELEMENTS = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' }
-- and a range ("HP+14～") with the Japanese wave dash, 0x81 0x60
function C.readable(desc)
    return ((desc or ''):gsub('\239([\31-\38])', function (c) return ELEMENTS[c:byte() - 30] .. ' res.' end):gsub('\129\96', '~'))
end

-- a line led by one of these ("Pet: Attack+10") is the companion's stats, kept apart from yours
local COMPANION = { Pet = true, Avatar = true, Wyvern = true, Automaton = true, Luopan = true }
local function companion(head)
    for w in head:gmatch('[^&]+') do if not COMPANION[trim(w)] then return false end end
    return true
end

local parsed = {}

-- { v = { [key] = n }, order = { key, ... }, label = { [key] = name }, notes = { line, ... } }. A key is the stat's
-- name in lower case (the game writes "Fire Elemental" and "Fire elemental"); one ending in % is a percentage
-- ("haste%"); "pet: attack" is the pet's. A stat given as a range ("HP+14~") is a note: it varies. Any other "Something:" (Latent effect, Set, Dynamis, In areas under own
-- nation's control, Additional effect ...) makes the rest of the description a note: it only holds sometimes.
-- A line whose numbers run on into a sentence ("attack +1 based on amount of MP consumed") is a note too.
function C.stats(id)
    local hit = parsed[id]
    if hit then return hit end
    local r = I.get(id)
    local s = C.readable(r.desc)
    local out = { v = {}, order = {}, label = {}, notes = {} }
    local function add(name, n)
        local k = name:lower()
        if out.v[k] == nil then out.v[k] = 0 out.order[#out.order + 1] = k out.label[k] = name end
        out.v[k] = out.v[k] + n
    end
    local def = s:match('DEF:%s*%+?(%d+)')
    if def then add('DEF', tonumber(def)) end
    -- damage and delay as the description gives them: CatsEyeXI's rebalanced weapons change the text ("DMG:45") and
    -- leave the record's own field at retail (71), and the server goes by the text. The field only when there's none.
    -- Hand-to-hand writes them as additions to the base ("DMG:+17 Delay:+84"): no damage a second from those.
    local dsign, dtext = s:match('DMG:%s*(%+?)(%d+)')
    local lsign, ltext = s:match('Delay:%s*(%+?)(%d+)')
    local dmg = tonumber(dtext) or ((r.dmg or 0) > 0 and r.dmg or nil)
    local delay = tonumber(ltext) or ((r.delay or 0) > 0 and r.delay < 999 and r.delay or nil)
    if dmg and dmg > 0 then
        add('DMG', dmg)
        if delay then add('Delay', delay) end
        out.added = dsign == '+' or lsign == '+'
    end
    s = s:gsub('DEF:%s*[%+%-]?%d+', ''):gsub('DMG:%s*[%+%-]?%d+', ''):gsub('Delay:%s*[%+%-]?%d+', '')
    local cond = false
    local pet = '' -- a companion's line wraps ("Pet: Accuracy+8" / "Ranged Accuracy+8"): what follows is still the pet's
    for raw in (s .. '\n'):gmatch('([^\n]*)\n') do
        local line = trim(raw)
        if line ~= '' and cond then
            out.notes[#out.notes + 1] = line
        elseif line ~= '' then
            local prefix = pet
            local head, rest = line:match('^([^:%+%-]+):%s*(.*)$')
            if head and companion(head) then
                prefix, line = trim(head) .. ': ', rest
                pet = prefix
            elseif head then
                cond = true
                out.notes[#out.notes + 1] = line
                line = nil
            end
            if line then
                -- phrases that carry a number or a capital but aren't stats: kept as notes, the stats around them read
                for _, pat in ipairs({ 'Cannot [Ee]quip %a+', 'Converts %d+ %u%u to %u%u', '^Lv%.? ?%d+' }) do
                    line = line:gsub(pat, function (m) out.notes[#out.notes + 1] = m return '' end)
                end
                line = trim(line:gsub('%s+', ' '))
                local toks, pos, ok = {}, 1, true
                while true do
                    local a, b, sign, num, pct = line:find('([%+%-])(%d+)(%%?)', pos)
                    if a == nil then break end
                    local name = trim((line:sub(pos, a - 1):gsub('"', ''):gsub('%s+', ' ')))
                    if name == '' or name:find('%d') or name:find('^%l') then ok = false break end
                    if line:sub(b + 1, b + 1) == '~' then
                        -- a range ("HP+14~"): it varies, so it's a note; the stats after it still read
                        out.notes[#out.notes + 1] = prefix .. name .. sign .. num .. pct .. '~'
                        b = b + 1
                    else
                        toks[#toks + 1] = { prefix .. name .. pct, (sign == '-' and -1 or 1) * tonumber(num) }
                    end
                    pos = b + 1
                end
                local tail = trim(line:sub(pos))
                if not ok or #toks == 0 or (tail ~= '' and not tail:find('^"?%u')) then
                    out.notes[#out.notes + 1] = prefix .. line
                else
                    for _, tk in ipairs(toks) do add(tk[1], tk[2]) end
                    if tail ~= '' then out.notes[#out.notes + 1] = prefix .. tail end
                end
            end
        end
    end
    out.note = table.concat(out.notes, ' ')
    parsed[id] = out
    return out
end

-------------------------------------------------------------------------------
-- Setting one against another
-------------------------------------------------------------------------------

-- the stats players read first, in this order; the rest follow as they come
local FIRST = { 'DEF', 'DMG', 'Delay', 'DPS', 'HP', 'HP%', 'MP', 'MP%', 'STR', 'DEX', 'VIT', 'AGI', 'INT', 'MND', 'CHR',
    'Accuracy', 'Attack', 'Ranged Accuracy', 'Ranged Attack', 'Evasion', 'Magic Accuracy', 'Magic Atk. Bonus',
    'Magic Evasion', 'Magic Def. Bonus', 'Haste%', 'Store TP', 'Double Attack%', 'Triple Attack%', 'Critical hit rate%' }
local RANK = {}
for i, k in ipairs(FIRST) do RANK[k:lower()] = i end

-- most stats are better higher; these are better lower, and Enmity is whatever your job wants
local function lower_better(k)
    local l = k:lower()
    return l == 'delay' or l:find('damage taken', 1, true) or l:find('interruption', 1, true) or l:find('recast', 1, true)
        or l:find('delay', 1, true) or l:find('casting time', 1, true) or l:find('consumed', 1, true)
        or l:find('enemy critical', 1, true) or l:find('receiving critical', 1, true)
end
local NEUTRAL = { enmity = true, ['pet: enmity'] = true }

local EMPTY = { v = {}, order = {}, label = {}, notes = {}, note = '' }

function C.diff(new_id, old_id)
    local a = C.stats(new_id)
    local b = old_id and C.stats(old_id) or EMPTY
    local keys, seen = {}, {}
    for _, src in ipairs({ a.order, b.order }) do
        for _, k in ipairs(src) do if not seen[k] then seen[k] = true keys[#keys + 1] = k end end
    end
    local met = {}
    for i, k in ipairs(keys) do met[k] = i end
    local av, bv = a.v, b.v
    -- weapons: what DMG and Delay come to, damage a second (60 delay is a second)
    if (av.dmg or 0) > 0 and (av.delay or 0) > 0 and not a.added and not b.added then
        keys[#keys + 1] = 'dps'
        met.dps = #keys
    end
    table.sort(keys, function (x, y) return (RANK[x] or (100 + met[x])) < (RANK[y] or (100 + met[y])) end)
    local function value(src, k)
        if k == 'dps' then
            if (src.dmg or 0) > 0 and (src.delay or 0) > 0 then return src.dmg * 60 / src.delay end
            return nil
        end
        return src[k]
    end
    local rows, up, down, same = {}, 0, 0, 0
    for _, k in ipairs(keys) do
        local nv, ov = value(av, k), value(bv, k)
        local d = (nv or 0) - (ov or 0)
        if math.abs(d) < 0.05 then d = 0 end
        local good = 0
        if d ~= 0 and not NEUTRAL[k] then
            good = d > 0 and 1 or -1
            if lower_better(k) then good = -good end
        end
        if good > 0 then up = up + 1 elseif good < 0 then down = down + 1 elseif d == 0 then same = same + 1 end
        rows[#rows + 1] = { key = k, label = k == 'dps' and 'Damage / sec' or (a.label[k] or b.label[k] or k):gsub('%%$', ''), new = nv, old = ov, d = d, good = good }
    end
    return { rows = rows, up = up, down = down, same = same, a = a, b = b }
end

-- the slot a piece would go in, what's there now, and the comparison: of a pair (earrings, rings), the one it would
-- do most for (an empty one first)
function C.against(id)
    local r = I.get(id)
    if r.missing or (r.jobs or 0) == 0 then return nil end
    local slots = slots_for(r.slots)
    if slots == nil then return nil end
    local best
    for _, s in ipairs(slots) do
        local old = wearing(s)
        local df = C.diff(id, old)
        local score = (old == nil and 1000 or 0) + df.up - df.down
        if best == nil or score > best.score then best = { score = score, df = df, old = old, slot = s } end
    end
    return best
end

-------------------------------------------------------------------------------
-- The card
-------------------------------------------------------------------------------

local function fmt(v, k)
    if v == nil then return '—' end
    if k == 'dps' then return string.format('%.1f', v) end
    local n = math.floor(v + 0.5)
    local s = n < 0 and ('−' .. -n) or tostring(n)
    if k:sub(-1) == '%' then s = s .. '%' end
    return s
end

-- why you can't wear it as you are, or nil
local function cannot(r, w)
    if w == nil or (w.job or 0) == 0 then return nil end
    local who = (U.JOBS[w.job] or '?') .. w.level
    if bit.band(r.jobs or 0, bit.lshift(1, w.job)) == 0 then return 'Your ' .. who .. " can't wear this" end
    if (w.race or 0) > 0 and (r.races or 0) ~= 0 and bit.band(r.races, bit.lshift(1, w.race)) == 0 then
        return "Your race can't wear this"
    end
    if (r.level or 0) > (w.level or 0) then return 'Needs level ' .. r.level .. ' (your ' .. who .. ')' end
    return nil
end

local function item_icon(dl, id, x, y, size, a, ring)
    dl:AddRectFilled({ x, y }, { x + size, y + size }, u32(P.well, 0.95 * a), S(7))
    local tex = I.icon(id)
    if tex ~= nil then
        dl:AddImageRounded(tex, { x + S(2), y + S(2) }, { x + size - S(2), y + size - S(2) }, { 0, 0 }, { 1, 1 }, u32('#FFFFFF', a), S(6))
    end
    dl:AddRect({ x, y }, { x + size, y + size }, u32(ring or P.line, 0.9 * a), S(7), 15, 1)
end

local MAX_ROWS = 12
local anim = { id = nil, since = 0 }

-- One card, measured (draw false) or drawn. c = {
--   id (nil: an empty slot, c.ghost says which), tag = { text, colour, icon } at the top right,
--   sub (the line under the name), chips = { { text, colour, icon } }, rows = { { label, value, badge = { text, colour,
--   icon }, good } }, lost = rows (YOU'D LOSE), notes = { { title, colour, icon, lines } }, warn, accent, quiet }
-- Returns the card's height.
local function card(dl, x, y, w, c, a, draw)
    local pad = S(14)
    local inner = w - pad * 2
    local cy = y + pad
    local accent = c.accent or P.line
    local h0 = 0
    -- the frame first, once the height is known: the caller draws in two passes
    if draw then
        local h = c.h
        U.shadow(dl, x, y, w, h, S(14), (c.quiet and 1.1 or 1.6) * a)
        dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(c.quiet and mix(P.glass, P.bg, 0.45) or P.glass, 0.985 * a), S(14))
        if not c.quiet then
            for i = 3, 1, -1 do
                dl:AddRect({ x - S(i), y - S(i) }, { x + w + S(i), y + h + S(i) }, u32(accent, 0.05 * a), S(14) + S(i), 15, S(2))
            end
            -- a wash of the accent down from the top, its first rows inset to the rounded corners
            local rr, wh = math.floor(S(14)), S(70)
            local function col(f) return u32(accent, 0.12 * a * (1 - f)) end
            for dy = 0, rr - 1 do
                local yc = rr - dy - 0.5
                local ins = rr - math.sqrt(rr * rr - yc * yc)
                dl:AddRectFilledMultiColor({ x + ins, y + dy }, { x + w - ins, y + dy + 1 }, col(dy / wh), col(dy / wh), col((dy + 1) / wh), col((dy + 1) / wh))
            end
            dl:AddRectFilledMultiColor({ x, y + rr }, { x + w, y + wh }, col(rr / wh), col(rr / wh), col(1), col(1))
        end
        dl:AddRect({ x, y }, { x + w, y + h }, u32(c.quiet and P.line or mix(P.line, accent, 0.45), 0.95 * a), S(14), 15, 1)
        dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, u32('#FFFFFF', 0.035 * a), S(14), 15, 1)
    end

    -- the tag: what this card is (EQUIPPED, REPLACES) or the verdict
    local tag = c.tag
    local tw = measure(tag[1], F.dispb, T.tiny - 1)
    local tpw, tph = tw + S(26), S(20)
    local tx = x + w - pad - tpw
    if draw then
        dl:AddRectFilled({ tx, cy }, { tx + tpw, cy + tph }, u32(tag[2], 0.16 * a), tph / 2)
        dl:AddRect({ tx, cy }, { tx + tpw, cy + tph }, u32(tag[2], 0.6 * a), tph / 2, 15, 1)
        icon(dl, tx + S(11), cy + tph / 2, tag[3], tag[2], T.tiny - 2, a)
        text(dl, tx + S(19), cy + (tph - S(T.tiny - 1)) / 2 - S(1), tag[1], tag[2], F.dispb, T.tiny - 1, a)
    end

    -- the piece: icon, name, the line under it
    local isz = S(40)
    if c.id then
        local r = I.get(c.id)
        if draw then
            item_icon(dl, c.id, x + pad, cy, isz, a, c.quiet and P.line or accent)
            local nx = x + pad + isz + S(12)
            text(dl, nx, cy + S(1), fit(r.name, F.disp, T.h2, tx - nx - S(6)), c.name_col or P.text, F.disp, T.h2, a)
            text(dl, nx, cy + S(24), fit(c.sub or '', F.text, T.tiny, x + w - pad - nx), P.dim, F.text, T.tiny, a)
        end
    elseif draw then
        dl:AddRect({ x + pad, cy }, { x + pad + isz, cy + isz }, u32(P.line, 0.9 * a), S(7), 15, 1)
        icon(dl, x + pad + isz / 2, cy + isz / 2, 'plus', P.faint, T.small, a)
        local nx = x + pad + isz + S(12)
        text(dl, nx, cy + S(3), c.ghost or 'Nothing equipped', P.dim, F.semi, T.small, a)
        text(dl, nx, cy + S(24), 'An empty slot', P.faint, F.text, T.tiny, a)
    end
    cy = cy + isz + S(12)

    -- the tally
    if c.chips and #c.chips > 0 then
        local px = x + pad
        for _, ch in ipairs(c.chips) do
            local lw = measure(ch[1], F.semi, T.tiny)
            local cw, chh = lw + S(28), S(22)
            if draw then
                dl:AddRectFilled({ px, cy }, { px + cw, cy + chh }, u32(ch[2], 0.12 * a), S(7))
                icon(dl, px + S(11), cy + chh / 2, ch[3], ch[2], T.tiny, a)
                text(dl, px + S(20), cy + (chh - S(T.tiny)) / 2 - S(1), ch[1], ch[2], F.semi, T.tiny, a)
            end
            px = px + cw + S(6)
        end
        cy = cy + S(22) + S(10)
    end

    -- the stats
    local row_h = S(22)
    local function rows(list, top_title, top_col, top_icon)
        if list == nil or #list == 0 then return end
        if top_title then
            cy = cy + S(6)
            if draw then
                dl:AddLine({ x + pad, cy - S(3) }, { x + w - pad, cy - S(3) }, u32(P.line, 0.6 * a), 1)
                icon(dl, x + pad + S(6), cy + S(9), top_icon, top_col, T.tiny - 1, a)
                text(dl, x + pad + S(16), cy + S(2), top_title, top_col, F.disp, T.tiny, a)
            end
            cy = cy + S(20)
        end
        local shown = math.min(#list, MAX_ROWS)
        local has_badge = false
        for i = 1, shown do if list[i].badge then has_badge = true end end
        local value_r = x + w - pad - (has_badge and S(60) or S(4))
        for i = 1, shown do
            local row = list[i]
            local ry = cy + (i - 1) * row_h
            if draw then
                local mid_y = ry + row_h / 2
                if i % 2 == 1 then dl:AddRectFilled({ x + pad - S(6), ry }, { x + w - pad + S(6), ry + row_h }, u32(P.well, 0.32 * a), S(6)) end
                if row.good and row.good ~= 0 then
                    local gc = row.good > 0 and P.ok or P.danger
                    dl:AddRectFilled({ x + pad - S(6), ry + S(5) }, { x + pad - S(3), ry + row_h - S(5) }, u32(gc, 0.9 * a), S(2))
                end
                local ts = S(T.small)
                local vs = row.value
                local vw = measure(vs, F.semi, T.small)
                text(dl, x + pad + S(4), mid_y - ts / 2 - S(1), fit(row.label, F.text, T.small, value_r - vw - S(10) - (x + pad + S(4))), row.dim and P.dim or P.text, F.text, T.small, a)
                text(dl, value_r - vw, mid_y - ts / 2 - S(1), vs, row.dim and P.dim or (row.vcol or P.text), F.semi, T.small, a)
                local b = row.badge
                if b then
                    local bw = measure(b[1], F.semi, T.tiny) + S(22)
                    local bx, bh = x + w - pad - bw, S(18)
                    dl:AddRectFilled({ bx, mid_y - bh / 2 }, { bx + bw, mid_y + bh / 2 }, u32(b[2], 0.16 * a), bh / 2)
                    icon(dl, bx + S(9), mid_y, b[3], b[2], T.tiny - 2, a)
                    text(dl, bx + S(16), mid_y - S(T.tiny) / 2 - S(1), b[1], b[2], F.semi, T.tiny, a)
                end
            end
        end
        cy = cy + shown * row_h
        if #list > shown then
            if draw then text(dl, x + pad + S(4), cy + S(2), '+' .. (#list - shown) .. ' more', P.faint, F.text, T.tiny, a) end
            cy = cy + S(18)
        end
    end
    if c.rows and #c.rows > 0 then rows(c.rows)
    elseif c.id then
        if draw then text(dl, x + pad, cy + S(2), c.empty_rows or 'No stats', P.dim, F.text, T.small, a) end
        cy = cy + S(22)
    end
    rows(c.lost, "YOU'D LOSE", P.warn, 'circle-minus')

    -- words: latent effects, set bonuses, added effects
    for _, n in ipairs(c.notes or {}) do
        if #n[4] > 0 then
            cy = cy + S(12)
            if draw then
                dl:AddLine({ x + pad, cy - S(6) }, { x + w - pad, cy - S(6) }, u32(P.line, 0.6 * a), 1)
                icon(dl, x + pad + S(6), cy + S(7), n[3], n[2], T.tiny - 1, a)
                text(dl, x + pad + S(16), cy, n[1], n[2], F.disp, T.tiny, a)
            end
            cy = cy + S(18)
            for _, l in ipairs(n[4]) do
                if draw then text(dl, x + pad, cy, l, P.text, F.text, T.tiny, a * 0.82) end
                cy = cy + S(15)
            end
        end
    end

    if c.warn then
        cy = cy + S(12)
        local bh = S(26)
        if draw then
            dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + bh }, u32(P.warn, 0.12 * a), S(8))
            icon(dl, x + pad + S(14), cy + bh / 2, 'triangle-exclamation', P.warn, T.tiny, a)
            text(dl, x + pad + S(28), cy + (bh - S(T.tiny)) / 2 - S(1), c.warn, P.warn, F.semi, T.tiny, a)
        end
        cy = cy + bh
    end
    return cy + pad - y
end

local function measure_card(c, w) c.h = card(nil, 0, 0, w, c, 1, false) return c.h end

-- words wrapped to a card, at most three lines
local function note_lines(s, inner)
    if s == nil or s == '' then return {} end
    local ls = wrap(s, F.text, T.tiny, inner)
    if #ls <= 3 then return ls end
    return { ls[1], ls[2], fit(ls[3], F.text, T.tiny, inner - measure(' …', F.text, T.tiny)) .. ' …' }
end

local function sub_of(id, slot)
    local r = I.get(id)
    local sub = SLOT[slot] or ''
    if (r.level or 0) > 0 then sub = sub .. '  ·  Lv ' .. r.level end
    if (r.ilevel or 0) > 0 then sub = sub .. '  ·  iLv ' .. r.ilevel end
    return sub
end

-- a piece's own stats as plain rows (the equipped card)
local function plain_rows(id)
    local df = C.diff(id, nil)
    local out = {}
    for _, row in ipairs(df.rows) do
        if row.new ~= nil then out[#out + 1] = { label = row.label, value = fmt(row.new, row.key) } end
    end
    return out
end

-- ctx: { t = ImGui time, wearer = { job, level, race } }
function C.card(id, mx, my, ctx)
    local cmp = C.against(id)
    if cmp == nil then anim.id = nil return end
    local t = ctx.t or 0
    if anim.id ~= id then anim.id, anim.since = id, t end
    local a = math.min(1, (t - anim.since) * 7)
    a = 1 - (1 - a) * (1 - a) * (1 - a)
    if a <= 0.01 then return end
    local dl = imgui.GetForegroundDrawList()
    local r = I.get(id)
    local df = cmp.df
    local same_item = cmp.old == id
    local why = cannot(r, ctx.wearer)
    local w = S(292)
    local inner = w - S(28)

    -- the piece under the mouse
    local verdict
    if same_item then verdict = { 'WEARING', P.cyan, 'shirt' }
    elseif why then verdict = { "CAN'T WEAR", P.warn, 'ban' }
    elseif df.up > 0 and df.down == 0 then verdict = { 'UPGRADE', P.ok, 'caret-up' }
    elseif df.down > 0 and df.up == 0 then verdict = { 'DOWNGRADE', P.danger, 'caret-down' }
    elseif df.up > 0 then verdict = { 'TRADE-OFF', P.warn, 'scale-balanced' }
    else verdict = { 'SAME STATS', P.dim, 'scale-balanced' } end
    local main = { id = id, tag = verdict, accent = verdict[2], sub = sub_of(id, cmp.slot), rows = {}, lost = {},
        name_col = why and mix(P.text, P.dim, 0.35) or mix(P.text, GOLD, 0.75), warn = why, notes = {} }
    if not same_item then
        main.chips = {}
        if df.up > 0 then main.chips[#main.chips + 1] = { df.up .. ' better', P.ok, 'caret-up' } end
        if df.down > 0 then main.chips[#main.chips + 1] = { df.down .. ' worse', P.danger, 'caret-down' } end
        if df.up == 0 and df.down == 0 then main.chips[#main.chips + 1] = { 'No stat changes', P.dim, 'minus' } end
    end
    for _, row in ipairs(df.rows) do
        local col = row.good > 0 and P.ok or (row.good < 0 and P.danger or P.faint)
        if row.new ~= nil then
            local badge = nil
            if not same_item and row.d ~= 0 then
                local mag = math.abs(row.d)
                local ds = row.key == 'dps' and string.format('%.1f', mag) or tostring(math.floor(mag + 0.5))
                if row.key:sub(-1) == '%' then ds = ds .. '%' end
                badge = { ds, col, row.d > 0 and 'caret-up' or 'caret-down' }
            end
            main.rows[#main.rows + 1] = { label = row.label, value = fmt(row.new, row.key), badge = badge, good = not same_item and row.good or 0 }
        elseif not same_item then
            -- only on what you wear: the swap takes it away
            main.lost[#main.lost + 1] = { label = row.label, value = fmt(row.old, row.key), vcol = col, good = row.good }
        end
    end
    local new_note, old_note = df.a.note or '', df.b.note or ''
    if new_note == old_note and not same_item then new_note, old_note = '', '' end
    main.notes[1] = { same_item and 'EFFECTS' or 'IT ALSO HAS', P.accent, 'wand-magic-sparkles', note_lines(new_note, inner) }
    main.empty_rows = 'No stats on this one'

    -- what you wear there: for a pair, both, the one it would replace marked
    local side = {}
    if not same_item then
        local pair = cmp.slot >= 11 and cmp.slot <= 14
        local slots = pair and ((cmp.slot <= 12) and { 11, 12 } or { 13, 14 }) or { cmp.slot }
        for _, s in ipairs(slots) do
            local wid = wearing(s)
            local replaced = s == cmp.slot
            local where = (SLOT[s] or ''):upper()
            local tag
            if wid == nil then tag = { 'EMPTY · ' .. where, P.faint, 'plus' }
            elseif replaced and pair then tag = { 'REPLACES · ' .. where, P.accent, 'arrow-right' }
            else tag = { 'EQUIPPED · ' .. where, replaced and P.accent or P.dim, 'shirt' } end
            local c = { id = wid, tag = tag,
                quiet = true, accent = P.accent, ghost = 'Nothing in ' .. (SLOT[s] or 'that slot') }
            if wid then
                c.sub = sub_of(wid, s)
                c.rows = plain_rows(wid)
                c.empty_rows = 'No stats'
                local st = C.stats(wid)
                c.notes = { { 'EFFECTS', P.dim, 'wand-magic-sparkles', note_lines(st.note, inner) } }
            end
            if wid or replaced then side[#side + 1] = c end
        end
    end

    -- placed whole: under the mouse's side, the piece; beyond it, what you wear (stacked below when there's no room)
    local okv, vw, vh = pcall(vana.ui.screen)
    if not okv or type(vw) ~= 'number' then vw, vh = 1920, 1080 end
    local gap = S(10)
    local h1 = measure_card(main, w)
    local h2 = 0
    for i, c in ipairs(side) do h2 = h2 + measure_card(c, w) + (i > 1 and gap or 0) end
    local x1, x2, y1, y2
    local off = S(24)
    local both = w * 2 + gap
    y1 = math.max(S(8), math.min(my - S(28), vh - h1 - S(8)))
    if ctx.stack and #side > 0 then
        -- a controller: the cards stand beside the row, one under the other, where the mouse would have hovered
        x1 = math.max(S(8), math.min(mx + off, vw - w - S(8)))
        x2 = x1
        y1 = math.max(S(8), math.min(my - S(28), vh - h1 - gap - h2 - S(8)))
        y2 = y1 + h1 + gap
    elseif #side == 0 then
        x1 = mx + off
        if x1 + w > vw - S(8) then x1 = mx - off - w end
    elseif mx + off + both <= vw - S(8) then
        x1 = mx + off
        x2 = x1 + w + gap
    elseif mx - off - both >= S(8) then
        x1 = mx - off - w
        x2 = x1 - gap - w
    else
        x1 = math.max(S(8), math.min(mx + off, vw - w - S(8)))
        x2 = x1
        y1 = math.max(S(8), math.min(my - S(28), vh - h1 - gap - h2 - S(8)))
        y2 = y1 + h1 + gap
    end
    if y2 == nil then y2 = math.max(S(8), math.min(y1, vh - h2 - S(8))) end
    local rise = (1 - a) * S(8)
    card(dl, x1, y1 + rise, w, main, a, true)
    -- the equipped cards come in a beat later, sliding out from behind
    local a2 = math.max(0, math.min(1, (t - anim.since - 0.06) * 7))
    a2 = 1 - (1 - a2) * (1 - a2) * (1 - a2)
    if a2 > 0.01 then
        local slide = (1 - a2) * S(14) * ((x2 or x1) >= x1 and -1 or 1)
        local cy = y2
        for _, c in ipairs(side) do
            card(dl, (x2 or x1) + slide, cy + rise, w, c, a2, true)
            cy = cy + c.h + gap
        end
    end
end

-- nothing hovered this frame: the next card fades in afresh
function C.idle() anim.id = nil end

return C
