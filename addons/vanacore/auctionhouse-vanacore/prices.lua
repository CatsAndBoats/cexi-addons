-- Prices: every sale the house has told us about, kept per character and server so an item's history grows past the ten
-- rows the search server hands out, and the graphs drawn from it (the card's price chart, the watch list's sparklines).
local imgui = vana.imgui
local U = require('ui')
local P, S = U.P, U.S
local T, F = U.sizes(), U.fonts()
local u32, text, measure, mix = U.u32, U.text, U.measure, U.mix

local L = {}

local KEEP = 160            -- sales kept per item and kind
local FORGET = 120 * 86400  -- a series with no sale this long is dropped on load

local log = {}              -- [id] = { s = { {price,date,seller,buyer}, ... }, k = { ... } }, oldest first
local path = nil
local dirty, saved_at = false, 0

local function kind(stack) return stack and 'k' or 's' end

-------------------------------------------------------------------------------
-- The file
-------------------------------------------------------------------------------

local function q(s) return string.format('%q', s or '') end

function L.load(file)
    path = file
    log = {}
    if file == nil or not vana.fs.exists(file) then return end
    local ok, chunk = pcall(loadfile, file)
    if not ok or chunk == nil then return end
    local ok2, data = pcall(chunk)
    if not ok2 or type(data) ~= 'table' then return end
    local cutoff = os.time() - FORGET
    for id, kinds in pairs(data) do
        local keep = {}
        for k, rows in pairs(kinds) do
            if type(rows) == 'table' and #rows > 0 and (rows[#rows][2] or 0) > cutoff then keep[k] = rows end
        end
        if next(keep) then log[tonumber(id) or id] = keep end
    end
end

function L.save(force)
    if path == nil or not dirty then return end
    if not force and os.time() - saved_at < 10 then return end
    local dir = path:match('^(.*)\\[^\\]+$')
    if dir then pcall(vana.fs.create_dir, dir) end
    local f = io.open(path, 'w')
    if f == nil then return end
    f:write('return {\n')
    local ids = {}
    for id in pairs(log) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        f:write('[', tostring(id), ']={')
        for k, rows in pairs(log[id]) do
            f:write(k, '={')
            for _, r in ipairs(rows) do f:write('{', r[1], ',', r[2], ',', q(r[3]), ',', q(r[4]), '},') end
            f:write('},')
        end
        f:write('},\n')
    end
    f:write('}\n')
    f:close()
    dirty, saved_at = false, os.time()
end

-------------------------------------------------------------------------------
-- Adding what the house said, and reading it back
-------------------------------------------------------------------------------

-- merge a history reply's sales (any order) into the log; returns how many were new
function L.add(id, stack, sales)
    if sales == nil or #sales == 0 then return 0 end
    local kinds = log[id]
    if kinds == nil then kinds = {} log[id] = kinds end
    local rows = kinds[kind(stack)]
    if rows == nil then rows = {} kinds[kind(stack)] = rows end
    local seen = {}
    for _, r in ipairs(rows) do seen[r[2] .. '/' .. r[1] .. '/' .. r[3]] = true end
    local added = 0
    for _, s in ipairs(sales) do
        local key = s.date .. '/' .. s.price .. '/' .. (s.seller or '')
        if not seen[key] then
            rows[#rows + 1] = { s.price, s.date, s.seller or '', s.buyer or '' }
            seen[key] = true
            added = added + 1
        end
    end
    if added > 0 then
        table.sort(rows, function (a, b) return a[2] < b[2] end)
        while #rows > KEEP do table.remove(rows, 1) end
        dirty = true
    end
    return added
end

-- the sales kept for an item, oldest first: { price=, date=, seller=, buyer= }
function L.series(id, stack)
    local kinds = log[id]
    local rows = kinds and kinds[kind(stack)] or nil
    local out = {}
    if rows then
        for i, r in ipairs(rows) do out[i] = { price = r[1], date = r[2], seller = r[3], buyer = r[4] } end
    end
    return out
end

function L.count(id, stack)
    local kinds = log[id]
    local rows = kinds and kinds[kind(stack)] or nil
    return rows and #rows or 0
end

-- the newest price against the newest one at least `seconds` older: a fraction, or nil without enough history
function L.change(series, seconds)
    local n = #series
    if n < 2 then return nil end
    local last = series[n]
    for i = n - 1, 1, -1 do
        if last.date - series[i].date >= seconds then
            if series[i].price == 0 then return nil end
            return (last.price - series[i].price) / series[i].price, series[i]
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local function mouse_pos()
    local a, b = imgui.GetMousePos()
    if type(a) == 'table' then return a[1] or a.x or 0, a[2] or a.y or 0 end
    return a or 0, b or 0
end

local function short_gil(n)
    if n >= 1000000 then return string.format('%.1fM', n / 1000000):gsub('%.0M', 'M') end
    if n >= 10000 then return string.format('%.0fK', n / 1000) end
    if n >= 1000 then return string.format('%.1fK', n / 1000):gsub('%.0K', 'K') end
    return tostring(n)
end

local function gil(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

-- where each sale lands: by time across the width, or evenly when they all fall in the same minute
local function layout(series, x, y, w, h)
    local n = #series
    local lo, hi = math.huge, -math.huge
    for _, s in ipairs(series) do lo, hi = math.min(lo, s.price), math.max(hi, s.price) end
    if lo == hi then lo, hi = lo * 0.9, hi * 1.1 end
    if hi - lo < 1 then hi = lo + 1 end
    local t0, t1 = series[1].date, series[n].date
    local by_time = t1 - t0 >= 60
    local pts = {}
    for i, s in ipairs(series) do
        local fx = by_time and ((s.date - t0) / (t1 - t0)) or (n > 1 and ((i - 1) / (n - 1)) or 0.5)
        pts[i] = { x + fx * w, y + h - (s.price - lo) / (hi - lo) * h, s }
    end
    return pts, lo, hi
end

-- the price chart: the line, a soft fill under it, the points, a median line, gil marks, the dates, and the sale under the
-- mouse. `opts`: color, median (a price to mark), key (an id for the hover area)
function L.chart(dl, x, y, w, h, series, opts)
    opts = opts or {}
    local color = opts.color or P.cyan
    local n = #series
    if n == 0 then
        U.text_center(dl, x, y + h / 2 - S(8), w, 'No sales recorded yet', P.faint, F.text, T.small)
        return nil
    end
    local top = 0
    for _, s in ipairs(series) do top = math.max(top, s.price) end
    local padl = measure(short_gil(top * 1.1), F.text, T.tiny - 1) + S(10)
    local padr, padt, padb = S(10), S(10), S(18)
    local px, py, pw, ph = x + padl, y + padt, w - padl - padr, h - padt - padb
    local pts, lo, hi = layout(series, px, py, pw, ph)
    -- the grid: three marks
    for i = 0, 2 do
        local gy = py + ph - ph * i / 2
        local v = lo + (hi - lo) * i / 2
        dl:AddLine({ px, gy }, { px + pw, gy }, u32(P.line, 0.55), 1)
        local lbl = short_gil(v)
        text(dl, px - S(6) - measure(lbl, F.text, T.tiny - 1), gy - S(6), lbl, P.faint, F.text, T.tiny - 1)
    end
    -- the fill under the line
    local base = py + ph
    for i = 1, n - 1 do
        local a, b = pts[i], pts[i + 1]
        dl:AddQuadFilled({ a[1], a[2] }, { b[1], b[2] }, { b[1], base }, { a[1], base }, u32(color, 0.10))
    end
    -- the median, dashed
    if opts.median and opts.median >= lo and opts.median <= hi then
        local my = py + ph - (opts.median - lo) / (hi - lo) * ph
        local dx = px
        while dx < px + pw do
            dl:AddLine({ dx, my }, { math.min(dx + S(5), px + pw), my }, u32(P.gold, 0.5), 1)
            dx = dx + S(9)
        end
    end
    -- the line, with a glow
    for i = 1, n - 1 do
        local a, b = pts[i], pts[i + 1]
        dl:AddLine({ a[1], a[2] }, { b[1], b[2] }, u32(color, 0.18), S(5))
        dl:AddLine({ a[1], a[2] }, { b[1], b[2] }, u32(color, 0.95), S(2))
    end
    if n == 1 then dl:AddLine({ px, pts[1][2] }, { px + pw, pts[1][2] }, u32(color, 0.6), S(2)) end
    -- the points
    for i, p in ipairs(pts) do
        local last = i == n
        dl:AddCircleFilled({ p[1], p[2] }, last and S(4.5) or S(2.5), u32(P.ink), 16)
        dl:AddCircleFilled({ p[1], p[2] }, last and S(3) or S(1.5), u32(last and P.gold or color), 16)
        if last then dl:AddCircle({ p[1], p[2] }, S(6.5), u32(P.gold, 0.5), 20, 1) end
    end
    -- the dates
    local t0, t1 = series[1].date, series[n].date
    local l0 = os.date('%b %d', t0)
    local l1 = os.date('%b %d', t1)
    if l0 == l1 then l0, l1 = os.date('%b %d %H:%M', t0), os.date('%H:%M', t1) end
    text(dl, px, y + h - S(14), l0, P.faint, F.text, T.tiny - 1)
    text(dl, px + pw - measure(l1, F.text, T.tiny - 1), y + h - S(14), l1, P.faint, F.text, T.tiny - 1)
    -- the sale under the mouse
    imgui.SetCursorScreenPos({ x, y })
    local _, hovered = U.hit(opts.key or '##chart', w, h)
    if hovered then
        local mx = mouse_pos()
        local best, bd = nil, S(16)
        for _, p in ipairs(pts) do
            local d = math.abs(p[1] - mx)
            if d < bd then best, bd = p, d end
        end
        if best then
            dl:AddLine({ best[1], py }, { best[1], py + ph }, u32(P.text, 0.25), 1)
            dl:AddCircle({ best[1], best[2] }, S(6), u32(P.text, 0.9), 20, S(1.5))
            local s = best[3]
            U.with_font(F.text, T.small, imgui.SetTooltip, gil(s.price) .. ' gil  ·  ' .. os.date('%b %d, %H:%M', s.date) .. ((s.seller ~= '' or s.buyer ~= '') and ('\n' .. s.seller .. ' → ' .. s.buyer) or ''))
            return s
        end
    end
    return nil
end

-- a sparkline: the last `points` sales as a line with a fill, no marks
function L.spark(dl, x, y, w, h, series, color, points)
    local n = #series
    if n == 0 then
        dl:AddLine({ x, y + h / 2 }, { x + w, y + h / 2 }, u32(P.line), 1)
        return
    end
    local from = math.max(1, n - (points or 30) + 1)
    local part = {}
    for i = from, n do part[#part + 1] = series[i] end
    local pts = layout(part, x, y + S(2), w, h - S(4))
    local base = y + h
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        dl:AddQuadFilled({ a[1], a[2] }, { b[1], b[2] }, { b[1], base }, { a[1], base }, u32(color, 0.12))
        dl:AddLine({ a[1], a[2] }, { b[1], b[2] }, u32(color, 0.9), S(1.5))
    end
    if #pts == 1 then dl:AddLine({ x, pts[1][2] }, { x + w, pts[1][2] }, u32(color, 0.7), S(1.5)) end
    local last = pts[#pts]
    dl:AddCircleFilled({ last[1], last[2] }, S(3), u32(P.ink), 12)
    dl:AddCircleFilled({ last[1], last[2] }, S(2), u32(color), 12)
end

function L.dirty() return dirty end

return L
