-- Activity: what this character did at the house (bought, listed, took down, sold), kept per character across restarts
-- so the window has a running record, newest first, in pages, with the gil in and out.
local L = {}

local KEEP = 2000 -- entries kept per character (a page is 20, so a hundred pages)

local rows = {}  -- newest first: { kind, id, stack, price, fee, who, name, at }
local path = nil
local dirty, saved_at = false, 0

L.KINDS = { 'bought', 'listed', 'taken', 'sold' }

-------------------------------------------------------------------------------
-- The file
-------------------------------------------------------------------------------

local function q(s) return string.format('%q', s or '') end

-- the previous character's record is written first: a switch never loses an entry
function L.load(file)
    L.save(true)
    path = file
    rows = {}
    if file == nil or not vana.fs.exists(file) then return end
    local ok, chunk = pcall(loadfile, file)
    if not ok or chunk == nil then return end
    local ok2, data = pcall(chunk)
    if not ok2 or type(data) ~= 'table' then return end
    for _, r in ipairs(data) do
        if type(r) == 'table' and r.k and r.t then
            rows[#rows + 1] = { kind = r.k, id = r.i, stack = r.s == 1, price = r.p or 0, fee = r.f, who = r.w, name = r.n, at = r.t }
            if #rows >= KEEP then break end
        end
    end
end

function L.save(force)
    if path == nil or not dirty then return end
    if not force and os.time() - saved_at < 10 then return end
    saved_at = os.time() -- tried now: a folder that can't be written isn't tried again every frame
    local dir = path:match('^(.*)\\[^\\]+$')
    if dir then pcall(vana.fs.create_dir, dir) end
    local f = io.open(path, 'w')
    if f == nil then return end
    f:write('return {\n')
    for _, r in ipairs(rows) do
        f:write('{k=', q(r.kind), ',t=', r.at, ',p=', r.price)
        if r.id then f:write(',i=', r.id) end
        if r.stack then f:write(',s=1') end
        if r.fee then f:write(',f=', r.fee) end
        if r.who then f:write(',w=', q(r.who)) end
        if r.name then f:write(',n=', q(r.name)) end
        f:write('},\n')
    end
    f:write('}\n')
    f:close()
    dirty = false
end

-------------------------------------------------------------------------------
-- The record
-------------------------------------------------------------------------------

-- e: { kind = 'bought'|'listed'|'taken'|'sold', id, stack, price, fee, who, name }; goes in at the top
function L.add(e)
    table.insert(rows, 1, {
        kind = e.kind, id = e.id, stack = e.stack and true or false, price = e.price or 0,
        fee = e.fee, who = e.who, name = e.name, at = e.at or os.time(),
    })
    while #rows > KEEP do table.remove(rows) end
    dirty = true
    L.save()
end

function L.count() return #rows end

-- the entries a filter keeps ('all', or one of the kinds), newest first
function L.filtered(filter)
    if filter == nil or filter == 'all' then return rows end
    local out = {}
    for _, r in ipairs(rows) do if r.kind == filter then out[#out + 1] = r end end
    return out
end

-- one page of them: the rows, the page shown (clamped) and how many pages there are
function L.page(filter, page, per)
    local all = L.filtered(filter)
    per = per or 20
    local pages = math.max(1, math.ceil(#all / per))
    page = math.max(1, math.min(pages, page or 1))
    local out = {}
    for i = (page - 1) * per + 1, math.min(#all, page * per) do out[#out + 1] = all[i] end
    return out, page, pages, #all
end

-- the gil: paid for purchases, paid in listing fees, taken in from sales, and what that nets, over the whole record
function L.totals(filter)
    local t = { spent = 0, fees = 0, earned = 0, bought = 0, sold = 0, listed = 0, taken = 0 }
    for _, r in ipairs(L.filtered(filter)) do
        if r.kind == 'bought' then t.spent = t.spent + r.price t.bought = t.bought + 1
        elseif r.kind == 'sold' then t.earned = t.earned + r.price t.sold = t.sold + 1
        elseif r.kind == 'listed' then t.fees = t.fees + (r.fee or 0) t.listed = t.listed + 1
        elseif r.kind == 'taken' then t.taken = t.taken + 1 end
    end
    t.net = t.earned - t.spent - t.fees
    return t
end

function L.clear()
    rows = {}
    dirty = true
    L.save(true)
end

return L
