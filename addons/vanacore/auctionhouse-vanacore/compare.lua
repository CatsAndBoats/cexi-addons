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
    if (r.dmg or 0) > 0 then
        add('DMG', r.dmg)
        if (r.delay or 0) > 0 and r.delay < 999 then add('Delay', r.delay) end
    end
    s = s:gsub('DEF:%s*[%+%-]?%d+', ''):gsub('DMG:%s*[%+%-]?%d+', ''):gsub('Delay:%s*[%+%-]?%d+', '')
    local cond = false
    for raw in (s .. '\n'):gmatch('([^\n]*)\n') do
        local line = trim(raw)
        if line ~= '' and cond then
            out.notes[#out.notes + 1] = line
        elseif line ~= '' then
            local prefix = ''
            local head, rest = line:match('^([^:%+%-]+):%s*(.*)$')
            if head and companion(head) then
                prefix, line = trim(head) .. ': ', rest
            elseif head then
                cond = true
                out.notes[#out.notes + 1] = line
                line = nil
            end
            if line then
                local toks, pos, ok = {}, 1, true
                while true do
                    local a, b, sign, num, pct = line:find('([%+%-])(%d+)(%%?)', pos)
                    if a == nil then break end
                    local name = trim((line:sub(pos, a - 1):gsub('"', ''):gsub('%s+', ' ')))
                    if name == '' or name:find('%d') or name:find('^%l') or line:sub(b + 1, b + 1) == '~' then ok = false break end
                    toks[#toks + 1] = { prefix .. name .. pct, (sign == '-' and -1 or 1) * tonumber(num) }
                    pos = b + 1
                end
                local tail = trim(line:sub(pos))
                if not ok or #toks == 0 or (tail ~= '' and not tail:find('^%u')) then
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
    if (av.dmg or 0) > 0 and (av.delay or 0) > 0 then
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

local MAX_ROWS = 14
local anim = { id = nil, since = 0 }

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

    -- the verdict (gear you can't wear says so, whatever its numbers)
    local why = cannot(r, ctx.wearer)
    local verdict, vcol, vicon
    if same_item then verdict, vcol, vicon = 'WEARING', P.cyan, 'shirt'
    elseif why then verdict, vcol, vicon = "CAN'T WEAR", P.warn, 'ban'
    elseif df.up > 0 and df.down == 0 then verdict, vcol, vicon = 'UPGRADE', P.ok, 'caret-up'
    elseif df.down > 0 and df.up == 0 then verdict, vcol, vicon = 'DOWNGRADE', P.danger, 'caret-down'
    elseif df.up > 0 then verdict, vcol, vicon = 'TRADE-OFF', P.warn, 'scale-balanced'
    else verdict, vcol, vicon = 'SAME STATS', P.dim, 'scale-balanced' end

    -- the layout, measured first so the card can be placed whole
    local w, pad = S(350), S(16)
    local rows = df.rows
    local shown = math.min(#rows, MAX_ROWS)
    local inner = w - pad * 2
    local new_note = df.a.note or ''
    local old_note = df.b.note or ''
    if new_note == old_note and not same_item then new_note, old_note = '', '' end
    local function lines_of(s) return s ~= '' and wrap(s, F.text, T.tiny, inner) or {} end
    local nl, ol = lines_of(new_note), lines_of(same_item and '' or old_note)
    local function clip(ls)
        if #ls <= 3 then return ls end
        local keep = { ls[1], ls[2], fit(ls[3] .. ' …', F.text, T.tiny, inner) }
        if keep[3]:sub(-3) ~= '…' then keep[3] = fit(ls[3], F.text, T.tiny, inner - measure(' …', F.text, T.tiny)) .. ' …' end
        return keep
    end
    nl, ol = clip(nl), clip(ol)
    local row_h, line_h = S(23), S(15)
    local h = pad + S(46) + S(14) + S(26) + S(12) + S(34)
    h = h + (shown > 0 and (shown * row_h + S(6)) or S(26)) + (#rows > shown and S(18) or 0)
    if #nl > 0 then h = h + S(14) + S(18) + #nl * line_h end
    if #ol > 0 then h = h + S(14) + S(18) + #ol * line_h end
    if why then h = h + S(14) + S(28) end
    h = h + pad

    local okv, vw, vh = pcall(vana.ui.screen)
    if not okv or type(vw) ~= 'number' then vw, vh = 1920, 1080 end
    local x = mx + S(24)
    if x + w > vw - S(8) then x = mx - S(24) - w end
    local y = math.max(S(8), math.min(my - S(28), vh - h - S(8)))
    y = y + (1 - a) * S(8)

    -- the glass
    U.shadow(dl, x, y, w, h, S(16), 1.6 * a)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(P.glass, 0.985 * a), S(16))
    for i = 3, 1, -1 do
        dl:AddRect({ x - S(i), y - S(i) }, { x + w + S(i), y + h + S(i) }, u32(vcol, 0.05 * a), S(16) + S(i), 15, S(2))
    end
    dl:AddRect({ x, y }, { x + w, y + h }, u32(mix(P.line, vcol, 0.45), 0.95 * a), S(16), 15, 1)
    dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, u32('#FFFFFF', 0.04 * a), S(16), 15, 1)
    -- a wash of the verdict's colour down from the top; its first rows inset to the rounded corners, as the header's are
    do
        local rr, wh = math.floor(S(16)), S(76)
        local function col(f) return u32(vcol, 0.13 * a * (1 - f)) end
        for dy = 0, rr - 1 do
            local yc = rr - dy - 0.5
            local ins = rr - math.sqrt(rr * rr - yc * yc)
            dl:AddRectFilledMultiColor({ x + ins, y + dy }, { x + w - ins, y + dy + 1 }, col(dy / wh), col(dy / wh), col((dy + 1) / wh), col((dy + 1) / wh))
        end
        dl:AddRectFilledMultiColor({ x, y + rr }, { x + w, y + wh }, col(rr / wh), col(rr / wh), col(1), col(1))
    end

    -- the piece: its icon, name, slot and level, and the verdict
    local cx, cy = x + pad, y + pad
    item_icon(dl, id, cx, cy, S(46), a, vcol)
    local vtw = measure(verdict, F.dispb, T.tiny)
    local vpw, vph = vtw + S(30), S(22)
    local vx = x + w - pad - vpw
    dl:AddRectFilled({ vx, cy }, { vx + vpw, cy + vph }, u32(vcol, 0.18 * a), vph / 2)
    dl:AddRect({ vx, cy }, { vx + vpw, cy + vph }, u32(vcol, 0.7 * a), vph / 2, 15, 1)
    icon(dl, vx + S(12), cy + vph / 2, vicon, vcol, T.tiny, a)
    text(dl, vx + S(21), cy + (vph - S(T.tiny)) / 2 - S(1), verdict, vcol, F.dispb, T.tiny, a)
    local nx = cx + S(58)
    local name_col = why and mix(P.text, P.dim, 0.35) or mix(P.text, GOLD, 0.75)
    text(dl, nx, cy + S(1), fit(r.name, F.disp, T.h2, vx - nx - S(8)), name_col, F.disp, T.h2, a)
    local sub = SLOT[cmp.slot] or ''
    if (r.level or 0) > 0 then sub = sub .. '  ·  Lv ' .. r.level end
    if (r.ilevel or 0) > 0 then sub = sub .. '  ·  iLv ' .. r.ilevel end
    text(dl, nx, cy + S(27), fit(sub, F.text, T.tiny, x + w - pad - nx), P.dim, F.text, T.tiny, a)
    cy = cy + S(46) + S(14)

    -- the tally: better, worse, the same
    local function chip(px, label, col, ic)
        local tw = measure(label, F.semi, T.tiny)
        local cw, chh = tw + S(28), S(22)
        dl:AddRectFilled({ px, cy }, { px + cw, cy + chh }, u32(col, 0.12 * a), S(7))
        icon(dl, px + S(11), cy + chh / 2, ic, col, T.tiny, a)
        text(dl, px + S(20), cy + (chh - S(T.tiny)) / 2 - S(1), label, col, F.semi, T.tiny, a)
        return cw + S(6)
    end
    local px = cx
    if same_item then
        px = px + chip(px, "You're wearing this", P.cyan, 'shirt')
    else
        if df.up > 0 then px = px + chip(px, df.up .. ' better', P.ok, 'caret-up') end
        if df.down > 0 then px = px + chip(px, df.down .. ' worse', P.danger, 'caret-down') end
        if df.up == 0 and df.down == 0 then px = px + chip(px, 'No stat changes', P.dim, 'minus') end
    end
    cy = cy + S(26) + S(12)

    -- what it's set against: a hairline with VS, then the piece you wear there (or the empty slot)
    local vsw = S(30)
    local mid = x + w / 2
    dl:AddLine({ cx, cy + S(1) }, { mid - vsw / 2 - S(6), cy + S(1) }, u32(P.line, 0.9 * a), 1)
    dl:AddLine({ mid + vsw / 2 + S(6), cy + S(1) }, { x + w - pad, cy + S(1) }, u32(P.line, 0.9 * a), 1)
    U.text_center(dl, mid - vsw / 2, cy + S(1), vsw, 'VS', P.faint, F.dispb, T.tiny, a)
    cy = cy + S(10)
    if cmp.old then
        item_icon(dl, cmp.old, cx, cy, S(22), a)
        local ol_name = I.get(cmp.old).name
        text(dl, cx + S(30), cy + (S(22) - S(T.small)) / 2 - S(1), fit(ol_name, F.semi, T.small, inner - S(110)), P.text, F.semi, T.small, a * 0.9)
        local tag = 'in ' .. (SLOT[cmp.slot] or '')
        text(dl, x + w - pad - measure(tag, F.text, T.tiny), cy + (S(22) - S(T.tiny)) / 2, tag, P.faint, F.text, T.tiny, a)
    else
        dl:AddRect({ cx, cy }, { cx + S(22), cy + S(22) }, u32(P.line, 0.9 * a), S(7), 15, 1)
        icon(dl, cx + S(11), cy + S(11), 'plus', P.faint, T.tiny, a)
        text(dl, cx + S(30), cy + (S(22) - S(T.small)) / 2 - S(1), 'Nothing in ' .. (SLOT[cmp.slot] or 'that slot'), P.dim, F.semi, T.small, a)
    end
    cy = cy + S(34)

    -- the stats: name, what you have, what this gives, and the change
    local delta_r = x + w - pad
    local new_r = delta_r - S(62)
    local arrow_cx = new_r - S(46)
    local old_r = arrow_cx - S(10)
    local label_w = old_r - S(44) - (cx + S(10))
    if shown == 0 then
        text(dl, cx, cy + S(4), 'No stats to compare', P.dim, F.text, T.small, a)
        cy = cy + S(26)
    end
    for i = 1, shown do
        local row = rows[i]
        local ry = cy + (i - 1) * row_h
        local col = row.good > 0 and P.ok or (row.good < 0 and P.danger or P.faint)
        if i % 2 == 1 then dl:AddRectFilled({ cx - S(6), ry }, { x + w - pad + S(6), ry + row_h }, u32(P.well, 0.35 * a), S(6)) end
        if row.good ~= 0 then dl:AddRectFilled({ cx - S(6), ry + S(5) }, { cx - S(3), ry + row_h - S(5) }, u32(col, 0.9 * a), S(2)) end
        local mid_y = ry + row_h / 2
        local ts, tt = S(T.small), S(T.tiny)
        text(dl, cx + S(6), mid_y - ts / 2 - S(1), fit(row.label, F.text, T.small, label_w), row.d == 0 and P.dim or P.text, F.text, T.small, a)
        if not same_item then
            local os = fmt(row.old, row.key)
            text(dl, old_r - measure(os, F.semi, T.small), mid_y - ts / 2 - S(1), os, P.faint, F.semi, T.small, a)
            icon(dl, arrow_cx, mid_y, 'arrow-right', P.faint, T.tiny - 2, a * 0.8)
        end
        local ns = fmt(row.new, row.key)
        text(dl, new_r - measure(ns, F.semi, T.small), mid_y - ts / 2 - S(1), ns, row.d == 0 and P.dim or P.text, F.semi, T.small, a)
        if row.d ~= 0 and not same_item then
            local mag = math.abs(row.d)
            local ds = (row.key == 'dps') and string.format('%.1f', mag) or tostring(math.floor(mag + 0.5))
            if row.key:sub(-1) == '%' then ds = ds .. '%' end
            local dtw = measure(ds, F.semi, T.tiny)
            local pw = dtw + S(22)
            local pxl = delta_r - pw
            local ph = S(18)
            dl:AddRectFilled({ pxl, mid_y - ph / 2 }, { delta_r, mid_y + ph / 2 }, u32(col, 0.16 * a), ph / 2)
            icon(dl, pxl + S(9), mid_y, row.d > 0 and 'caret-up' or 'caret-down', col, T.tiny - 2, a)
            text(dl, pxl + S(16), mid_y - tt / 2 - S(1), ds, col, F.semi, T.tiny, a)
        elseif not same_item then
            local eq = '='
            text(dl, delta_r - S(14) - measure(eq, F.semi, T.tiny) / 2, mid_y - tt / 2 - S(1), eq, P.faint, F.semi, T.tiny, a)
        end
    end
    cy = cy + shown * row_h + (shown > 0 and S(6) or 0)
    if #rows > shown then
        text(dl, cx + S(6), cy, '+' .. (#rows - shown) .. ' more', P.faint, F.text, T.tiny, a)
        cy = cy + S(18)
    end

    -- what can't be put in numbers: latent effects, set bonuses, added effects
    local function notes(title, col, ic, lines)
        if #lines == 0 then return end
        cy = cy + S(14)
        dl:AddLine({ cx, cy - S(7) }, { x + w - pad, cy - S(7) }, u32(P.line, 0.6 * a), 1)
        icon(dl, cx + S(6), cy + S(7), ic, col, T.tiny - 1, a)
        text(dl, cx + S(16), cy, title, col, F.disp, T.tiny, a)
        cy = cy + S(18)
        for _, l in ipairs(lines) do
            text(dl, cx, cy, l, P.text, F.text, T.tiny, a * 0.82)
            cy = cy + line_h
        end
    end
    notes(same_item and 'EFFECTS' or 'IT ALSO HAS', P.accent, 'wand-magic-sparkles', nl)
    notes("YOU'D LOSE", P.warn, 'circle-minus', ol)

    -- whether you can wear it as you are
    if why then
        cy = cy + S(14)
        local bh = S(26)
        dl:AddRectFilled({ cx, cy }, { x + w - pad, cy + bh }, u32(P.warn, 0.12 * a), S(8))
        icon(dl, cx + S(14), cy + bh / 2, 'triangle-exclamation', P.warn, T.tiny, a)
        text(dl, cx + S(28), cy + (bh - S(T.tiny)) / 2 - S(1), why, P.warn, F.semi, T.tiny, a)
    end
end

-- nothing hovered this frame: the next card fades in afresh
function C.idle() anim.id = nil end

return C
