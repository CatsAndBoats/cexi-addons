--[[
    Auction House for VanaCore

    The auction house as its own window: browse every category with live stock, search by name, read an item's
    sale history and buy from its card; sell from your bag with the fee shown before you commit; see and cancel what
    you have up. It speaks the game's own auction packets (0x04E / 0x04C) for buying, selling and your sales, and asks
    the search server directly, the way the game does, for categories, stock and history. Nothing server-side.

    /ah opens it. Stand by an Auction Counter, as you would.
]]

addon.name    = 'auctionhouse-vanacore'
addon.author  = 'Carver'
addon.version = '1.0'
addon.desc    = "CatsEyeXI's Auction House: browse, buy, sell and watch your sales from one window."

local imgui = vana.imgui
if imgui == nil then
    print('auctionhouse-vanacore needs a newer VanaCore.Core.dll (vana.imgui)')
    return
end

local bit = require('bit')
local U = require('ui')
local I = require('items')
local SEARCH = require('search')
local P = U.P
local S = U.S
local T = U.sizes()
local F = U.fonts()

-------------------------------------------------------------------------------
-- The game's auction packets (map/packets/c2s/0x04e_auc.h, s2c/0x04c_auc.h)
-------------------------------------------------------------------------------

local PKT = { out = 0x04E, inc = 0x04C, size = 60 }
local CMD = { Open = 0x02, AskCommit = 0x04, Info = 0x05, WorkCheck = 0x0A, LotIn = 0x0B, LotCancel = 0x0C, LotCheck = 0x0D, Bid = 0x0E }
local RESULT = { Ok = 1, Fail = 197, Wait = 246, Unable = 0xC5, Full = 0xE5 }

-- how far from a counter the house still serves you (yalms), how long fetched lists and histories stay fresh (s),
-- how often the sales list may be asked for (the server says 5 s), how long to wait on the server before saying so
local LIMITS = { counter = 6, list = 90, history = 45, sales = 5.5, reply = 6, scan = 0.5, inventory = 2 }

-------------------------------------------------------------------------------
-- State and settings
-------------------------------------------------------------------------------

local st = {
    open = false, tab = 'buy', group = 'armor', category = 17, selected = nil, stack = false,
    query = { '' }, results = nil, result_total = 0,
    lists = {}, hist = {}, fetching = {},
    counter = { near = false, dist = nil, at = 0 }, zone_ok = nil, work_at = 0,
    sales = {}, sales_at = 0, sales_open = false, sales_wait = false,
    sell = { slot = nil, stack = false, price = { '' }, fee = nil, asked = nil, pending = false, at = 0 },
    buy = { price = { '' }, pending = nil },
    inventory = {}, inv_at = 0, gil = 0,
    main = nil, settings_open = false, confirm = nil, last_error = nil, counts = { pin = 0, pout = 0 },
    anim = {}, list_at = 0, opened_at = 0, group_open = {}, hover = {},
}

local settings = {
    scale = 100, opacity = 1.0, keybind = '^A', confirm_buy = true, near_counter = true, take_over = true, search_host = '', search_port = 54002,
    sort = 'name', in_stock = false, remember = {},
}

local function fail(where, err)
    st.last_error = where .. ': ' .. tostring(err)
    vana.log('auctionhouse-vanacore ' .. st.last_error)
end

local function say(text)
    vana.chat.write('[Auction] ' .. text, 29)
end

local function clock() return vana.time.clock() end
local now_t, dt = 0, 0.016 -- ImGui's time and the frame's length, set each frame

local function gil(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

local function ago(unix)
    local d = os.time() - (unix or 0)
    if d < 60 then return 'just now' end
    if d < 3600 then return math.floor(d / 60) .. 'm ago' end
    if d < 86400 then return math.floor(d / 3600) .. 'h ago' end
    if d < 86400 * 30 then return math.floor(d / 86400) .. 'd ago' end
    return math.floor(d / (86400 * 30)) .. 'mo ago'
end

local function me()
    local ok, e = pcall(vana.game.entity, 0x400)
    if ok and type(e) == 'table' and e.name and e.name ~= '' then return e end
    return nil
end

local function my_name()
    local e = me()
    return e and e.name or ''
end

local function logged_in() return my_name() ~= '' end

local function my_job()
    local ok, p = pcall(vana.game.player)
    if ok and type(p) == 'table' then return p.main_job, p.main_job_level end
    return nil, nil
end

-------------------------------------------------------------------------------
-- Settings: config\addons\auctionhouse-vanacore\<character>.lua
-------------------------------------------------------------------------------

local function settings_dir() return vana.paths.install .. '\\config\\addons\\auctionhouse-vanacore' end
local function settings_file() return settings_dir() .. '\\' .. (my_name() ~= '' and my_name() or 'default') .. '.lua' end

local function serialize(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'table' then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local out = { '{\n' }
        for _, k in ipairs(keys) do
            local key = type(k) == 'string' and ('[' .. string.format('%q', k) .. ']') or ('[' .. tostring(k) .. ']')
            out[#out + 1] = indent .. '  ' .. key .. ' = ' .. serialize(v[k], indent .. '  ') .. ',\n'
        end
        out[#out + 1] = indent .. '}'
        return table.concat(out)
    elseif t == 'string' then return string.format('%q', v)
    else return tostring(v) end
end

local function save_settings()
    pcall(vana.fs.create_dir, settings_dir())
    local f = io.open(settings_file(), 'w')
    if f == nil then return end
    f:write('return ' .. serialize(settings) .. '\n')
    f:close()
end

local function load_settings()
    local path = settings_file()
    if not vana.fs.exists(path) then return end
    local ok, chunk = pcall(loadfile, path)
    if ok and chunk then
        local ok2, data = pcall(chunk)
        if ok2 and type(data) == 'table' then
            for k, v in pairs(data) do settings[k] = v end
        end
    end
end

-------------------------------------------------------------------------------
-- The search server: where it is
-------------------------------------------------------------------------------

-- the host VanaCore logged in to, from its own log ("Game start: on <host> (lobby ...)"): the search server lives there
local function host_from_log()
    local path = vana.paths.install .. '\\logs\\vanacore.log'
    local f = io.open(path, 'rb')
    if f == nil then return nil end
    local size = f:seek('end') or 0
    f:seek('set', math.max(0, size - 400000))
    local tail = f:read('*a') or ''
    f:close()
    local host = nil
    for h in tail:gmatch('Game start: on ([%w%.%-]+) %(') do host = h end
    return host
end

local function configure_search()
    local host = settings.search_host
    if host == nil or host == '' then host = host_from_log() end
    if host == nil or host == '' then host = 'server.catseyexi.com' end
    SEARCH.host = host
    SEARCH.port = tonumber(settings.search_port) or 54002
    SEARCH.log = function (text) fail('search', text) end
    st.search_where = host .. ':' .. SEARCH.port
end

-------------------------------------------------------------------------------
-- Packets out
-------------------------------------------------------------------------------

local function wr32(b, off, v)
    v = math.max(0, math.floor(v or 0))
    b[off + 1], b[off + 2], b[off + 3], b[off + 4] = v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256
end
local function wr16(b, off, v)
    v = math.max(0, math.floor(v or 0))
    b[off + 1], b[off + 2] = v % 256, math.floor(v / 256) % 256
end

-- fields: a table of { offset = value } for the param block; AucWorkIndex as given (-1 means none)
local function send(cmd, work_index, params)
    local b = {}
    for i = 1, PKT.size do b[i] = 0 end
    b[1], b[2] = PKT.out % 256, PKT.size / 2 -- VanaCore writes the header; these are placeholders
    b[5] = cmd
    local wi = work_index or -1
    b[6] = wi < 0 and (256 + wi) or wi
    for _, p in ipairs(params or {}) do
        if p.u32 then wr32(b, p.at, p.u32) elseif p.u16 then wr16(b, p.at, p.u16) else b[p.at + 1] = p.u8 % 256 end
    end
    local out = {}
    for i = 1, PKT.size do out[i] = string.char(b[i]) end
    st.counts.pout = st.counts.pout + 1
    vana.packets.inject(false, PKT.out, table.concat(out))
end

-- the auction work slot a bid or a listing goes through: the first of the seven not holding one of yours
-- (the server wants 0..6 here; it picks the real slot itself)
local function free_slot()
    for i = 0, 6 do if st.sales[i + 1] == nil then return i end end
    return 0
end
local function send_work_check() send(CMD.WorkCheck, -1) st.work_at = clock() end
local function send_sales() send(CMD.Info, -1) st.sales_at = clock() st.sales_wait = true end
local function send_bid(item, price, stack)
    send(CMD.Bid, free_slot(), { { at = 0x08, u32 = price }, { at = 0x0C, u16 = item }, { at = 0x10, u32 = stack and 0 or 1 } })
end
local function send_ask_commit(slot, item, price, stack)
    send(CMD.AskCommit, -1, { { at = 0x08, u32 = price }, { at = 0x0C, u16 = slot }, { at = 0x0E, u16 = item }, { at = 0x10, u32 = stack and 0 or 1 } })
end
local function send_lot_in(slot, price, stack)
    send(CMD.LotIn, free_slot(), { { at = 0x08, u32 = price }, { at = 0x0C, u16 = slot }, { at = 0x10, u32 = stack and 0 or 1 } })
end
local function send_cancel(slot) send(CMD.LotCancel, slot) end

-------------------------------------------------------------------------------
-- Packets in
-------------------------------------------------------------------------------

local function bytes_of(e)
    local d = e.data_modified or e.data
    if type(d) == 'string' then return d end
    if type(d) == 'table' then
        local out = {}
        for i = 1, #d do out[i] = string.char(d[i] % 256) end
        return table.concat(out)
    end
    if (type(d) == 'cdata' or type(d) == 'userdata') and e.size then
        local ok, s = pcall(function () return require('ffi').string(d, e.size) end)
        if ok then return s end
    end
    return nil
end

local function u8(d, off) return d:byte(off + 1) or 0 end
local function u16(d, off) return u8(d, off) + u8(d, off + 1) * 256 end
local function rd32(d, off) return u16(d, off) + u16(d, off + 2) * 65536 end

local open_window -- defined with the actions below; the packet handler needs it first

local function refresh_inventory()
    local ok, inv = pcall(vana.game.container, 0)
    if not ok or type(inv) ~= 'table' then return end
    local list = {}
    for i = 0, 80 do
        local it = inv[i]
        if it and it.id and it.id ~= 0 then
            if it.id == 65535 then st.gil = it.count or 0
            else list[#list + 1] = { slot = it.index or i, id = it.id, count = it.count or 1, flags = it.flags or 0 } end
        end
    end
    st.inventory = list
    st.inv_at = clock()
end

local function forget_history(item)
    st.hist[item .. '/0'], st.hist[item .. '/1'] = nil, nil
end

local function on_sales_slot(d)
    if not (st.sales_wait or clock() - st.sales_at < 2) then return end -- not asked for: the server's cached copy may be stale
    local slot = u8(d, 0x05)
    local stat = u8(d, 0x14)
    if stat == 0 then return end -- an empty slot
    local item = u16(d, 0x28)
    local qty = u8(d, 0x2A)
    st.sales[slot + 1] = { slot = slot, id = item, stack = qty == 0, price = rd32(d, 0x2C), at = rd32(d, 0x38) }
end

local function on_packet(e)
    local d = bytes_of(e)
    if d == nil or #d < 0x08 then return end
    st.counts.pin = st.counts.pin + 1
    local cmd, work, result, status = u8(d, 0x04), u8(d, 0x05), u8(d, 0x06), u8(d, 0x07)
    if work >= 128 then work = work - 256 end
    if cmd == CMD.Open then
        st.zone_ok = true
        if settings.take_over then
            -- the counter was talked to: this window opens in place of the game's menu
            if not st.open then open_window() end
            st.settings_open = false
            return true
        end
    elseif cmd == CMD.WorkCheck then
        st.zone_ok = true
    elseif cmd == CMD.Info then
        if result == RESULT.Wait then
            st.sales_wait = false
            U.toast('warn', 'One moment', 'The house is still fetching your sales', 3, 'clock')
        else
            st.zone_ok = true
            st.sales = {}
            st.sales_wait = false
            st.sales_open = true
        end
    elseif cmd == CMD.LotCancel and result == 0 and work >= 0 and (#d < 0x14 or u8(d, 0x14) ~= 0) and st.cancel_pending == nil then
        -- a sales-status row (the server lists them with this command)
        on_sales_slot(d)
    elseif cmd == CMD.LotCancel then
        if st.cancel_pending ~= nil and result == 0 then
            local row = st.sales[st.cancel_pending + 1]
            st.sales[st.cancel_pending + 1] = nil
            st.cancel_pending = nil
            U.toast('ok', 'Taken down', row and (I.name(row.id) .. ' is back in your bag') or 'Returned to your bag', 4, 'box-open')
            refresh_inventory()
        elseif st.cancel_pending ~= nil then
            st.cancel_pending = nil
            U.toast('danger', "Couldn't take it down", result == RESULT.Full and 'Your inventory is full' or 'Try again in a moment', 5, 'triangle-exclamation')
        else
            on_sales_slot(d)
        end
    elseif cmd == CMD.LotCheck then
        on_sales_slot(d)
    elseif cmd == CMD.AskCommit then
        st.sell.pending = false
        if status == 2 and result == RESULT.Ok then
            st.sell.fee = rd32(d, 0x08)
            st.sell.asked = { item = u16(d, 0x0E), slot = u16(d, 0x0C), stack = rd32(d, 0x10) == 0, price = st.sell.ask_price }
        else
            st.sell.fee, st.sell.asked = nil, nil
            U.toast('danger', "Can't sell that", 'The house refused it (used, locked, or not for auction)', 5, 'ban')
        end
    elseif cmd == CMD.LotIn then
        st.sell.pending = false
        if result == RESULT.Ok then
            local a = st.sell.asked
            U.toast('ok', 'Up for sale', a and (I.name(a.item) .. (a.stack and ' (stack)' or '') .. '  ·  ' .. gil(a.price) .. ' gil') or 'Listed', 5, 'tag')
            if a then forget_history(a.item) end
            st.sell.asked, st.sell.fee, st.sell.slot = nil, nil, nil
            refresh_inventory()
            st.sales_dirty = true
        else
            U.toast('danger', "Couldn't list it", 'Not enough gil for the fee, the slots are full, or the item changed', 6, 'triangle-exclamation')
        end
    elseif cmd == CMD.Bid then
        local b = st.buy.pending
        st.buy.pending = nil
        local item, price, qty = u16(d, 0x0C), rd32(d, 0x08), rd32(d, 0x10)
        if result == RESULT.Ok then
            U.toast('ok', 'Bought ' .. I.name(item), (qty > 1 and (qty .. ' for ') or '') .. gil(price) .. ' gil', 5, 'cart-shopping')
            say('Bought ' .. I.name(item) .. (qty > 1 and (' x' .. qty) or '') .. ' for ' .. gil(price) .. ' gil.')
            forget_history(item)
            local cat = I.category_of(item)
            if cat and st.lists[cat] and st.lists[cat].items[item] then
                local row = st.lists[cat].items[item]
                if qty > 1 then row.stack = math.max(0, row.stack - 1) else row.single = math.max(0, row.single - 1) end
            end
            refresh_inventory()
        elseif result == RESULT.Full then
            U.toast('danger', "Couldn't buy", 'Your inventory is full, or you already hold that rare item', 6, 'triangle-exclamation')
        else
            U.toast('danger', 'Bid failed', 'Nobody is selling ' .. I.name(b and b.item or item) .. ' at that price', 6, 'hand-holding-dollar')
            forget_history(b and b.item or item)
        end
    end
end

-------------------------------------------------------------------------------
-- Fetching: category lists, histories
-------------------------------------------------------------------------------

local function fetch_list(cat, force)
    local have = st.lists[cat]
    if not force and have and clock() - have.at < LIMITS.list then return end
    if st.fetching['cat' .. cat] then return end
    st.fetching['cat' .. cat] = clock()
    SEARCH.list(cat, function (r, err)
        st.fetching['cat' .. cat] = nil
        if r == nil then fail('list', err) st.search_error = err return end
        st.search_error = nil
        local items = {}
        for _, it in ipairs(r.items) do items[it.id] = { single = it.single, stack = it.stack } end
        st.lists[cat] = { items = items, at = clock(), total = r.total }
        st.list_at = clock()
    end)
end

local function fetch_history(item, stack, force)
    local key = item .. '/' .. (stack and 1 or 0)
    local have = st.hist[key]
    if not force and have and clock() - have.at < LIMITS.history then return end
    if st.fetching[key] then return end
    st.fetching[key] = clock()
    SEARCH.history(item, stack, function (r, err)
        st.fetching[key] = nil
        if r == nil then fail('history', err) st.search_error = err return end
        st.search_error = nil
        table.sort(r.sales, function (a, b) return a.date > b.date end)
        local prices = {}
        for _, sale in ipairs(r.sales) do prices[#prices + 1] = sale.price end
        table.sort(prices)
        local stats = nil
        if #prices > 0 then
            local mid = math.floor((#prices + 1) / 2)
            stats = { n = #prices, low = prices[1], high = prices[#prices], median = #prices % 2 == 1 and prices[mid] or math.floor((prices[mid] + prices[mid + 1]) / 2), last = r.sales[1].price }
            -- the trend: the newest three against the three before them
            if #r.sales >= 4 then
                local recent, older, nr, no = 0, 0, 0, 0
                for i, sale in ipairs(r.sales) do
                    if i <= 3 then recent, nr = recent + sale.price, nr + 1 else older, no = older + sale.price, no + 1 end
                end
                local a, b = recent / nr, older / no
                stats.trend = (a - b) / b
            end
        end
        st.hist[key] = { sales = r.sales, stock = r.stock, category = r.category, stats = stats, at = clock() }
        -- stock we learnt here keeps the list fresh too
        local cat = I.category_of(item)
        if cat and st.lists[cat] and st.lists[cat].items[item] then
            if stack then st.lists[cat].items[item].stack = r.stock else st.lists[cat].items[item].single = r.stock end
        end
    end)
end

local function history_of(item, stack)
    return st.hist[item .. '/' .. (stack and 1 or 0)]
end

local function stock_of(item)
    local cat = I.category_of(item)
    local row = cat and st.lists[cat] and st.lists[cat].items[item]
    if row then return row.single, row.stack, true end
    local hs, hk = history_of(item, false), history_of(item, true)
    if hs or hk then return hs and hs.stock or nil, hk and hk.stock or nil, false end
    return nil, nil, false
end

local function select_item(id)
    if id == nil then st.selected = nil return end
    st.selected = id
    st.selected_at = clock()
    local r = I.get(id)
    if r.stack <= 1 then st.stack = false end
    st.buy.price[1] = ''
    fetch_history(id, false)
    if r.stack > 1 then fetch_history(id, true) end
end

-------------------------------------------------------------------------------
-- Where you are: the counter, the zone
-------------------------------------------------------------------------------

local function scan_counter()
    local e = me()
    if e == nil then st.counter.near = false return end
    local best = nil
    for i = 0, 1023 do
        local ok, ent = pcall(vana.game.entity, i)
        if ok and type(ent) == 'table' and ent.name == 'Auction Counter' and ent.x then
            local dx, dy, dz = ent.x - e.x, ent.y - e.y, ent.z - e.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if best == nil or d < best then best = d end
        end
    end
    st.counter.dist = best
    st.counter.near = best ~= nil and best <= LIMITS.counter
    st.counter.at = clock()
end

local function may_trade()
    return (not settings.near_counter) or st.counter.near
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function do_buy(item, price, stack)
    if not may_trade() then say('Stand by an Auction Counter to buy.') return end
    if price <= 0 then return end
    if price > st.gil then U.toast('danger', 'Not enough gil', 'You have ' .. gil(st.gil) .. ' gil', 4, 'coins') return end
    st.buy.pending = { item = item, price = price, stack = stack, at = clock() }
    send_bid(item, price, stack)
end

local function do_ask(slot, item, price, stack)
    if not may_trade() then say('Stand by an Auction Counter to sell.') return end
    st.sell.pending = true
    st.sell.at = clock()
    st.sell.ask_price = price
    st.sell.fee, st.sell.asked = nil, nil
    send_ask_commit(slot, item, price, stack)
end

local function do_list()
    local a = st.sell.asked
    if a == nil then return end
    st.sell.pending = true
    st.sell.at = clock()
    send_lot_in(a.slot, a.price, a.stack)
end

local function do_cancel(slot)
    if not may_trade() then say('Stand by an Auction Counter.') return end
    st.cancel_pending = slot
    send_cancel(slot)
end

open_window = function ()
    st.open = true
    st.opened_at = now_t -- ImGui's clock, the one the fade is measured against
    scan_counter()
    refresh_inventory()
    if logged_in() then
        send_work_check()
        fetch_list(st.category)
        if st.selected then select_item(st.selected) end
    end
end

local function ensure_bind()
    if settings.keybind == nil or settings.keybind == '' then return end
    local ok, list = pcall(vana.binds.list)
    if ok and type(list) == 'table' then
        for _, b in pairs(list) do
            local key = type(b) == 'table' and (b.key or b[1]) or nil
            local cmd = type(b) == 'table' and (b.command or b[2]) or nil
            if type(key) == 'string' and key:lower() == settings.keybind:lower() then
                if type(cmd) == 'string' and cmd:find('/ah', 1, true) then return end
                return -- taken by something else: left alone
            end
        end
    end
    vana.chat.run('/bind ' .. settings.keybind .. ' /ah', 1)
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local text, text_mid, text_center, fit, wrap, icon = U.text, U.text_mid, U.text_center, U.fit, U.wrap, U.icon
local pill, shadow, panel, button, icon_button, hit = U.pill, U.shadow, U.panel, U.button, U.icon_button, U.hit
local measure, with_font, u32, mix, lerp, ease = U.measure, U.with_font, U.u32, U.mix, U.lerp, U.ease
local W = { w = 980, h = 640 }
local GOLD, PALE = '#FFD166', '#FFF3C4'

-- the house's mark: a glass ball with a gil coin glowing inside, in the finder's style
local function glass_gil(dl, cx, cy, size, t, alpha)
    alpha = alpha or 1
    local r = size / 2
    local ri = r * 0.85
    local breathe = 0.5 + 0.5 * math.sin(t * 1.6)
    local segs = size > S(40) and 36 or 20
    for i = 0, segs - 1 do
        local a0 = (i / segs) * 2 * math.pi
        local a1 = ((i + 1.15) / segs) * 2 * math.pi
        local am = (a0 + a1) / 2
        local b = 0.42 + 0.5 * math.cos(am - math.pi * 1.25) + 0.9 * math.max(0, math.cos(am - math.pi * 0.15)) ^ 14
        b = math.max(0, math.min(1, b))
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, r - r * 0.075, a0, a1, 3)
        dl:PathStroke(u32(mix('#232A32', '#FAFCFE', b), alpha), 0, r * 0.15)
    end
    dl:AddCircleFilled({ cx, cy }, ri, u32('#04060A', alpha), 48)
    for i = 4, 1, -1 do
        dl:AddCircleFilled({ cx, cy + ri * 0.05 }, ri * (0.3 + 0.14 * i), u32(GOLD, (0.05 + 0.03 * breathe) * alpha), 32)
    end
    -- the coin: a gold disc with a rim and a lit edge, the G in its middle
    local cr = ri * 0.52
    dl:AddCircleFilled({ cx, cy + ri * 0.04 }, cr * 1.04, u32('#8A5A12', alpha), 40)
    dl:AddCircleFilled({ cx, cy + ri * 0.04 }, cr, u32(mix(GOLD, '#B87A1C', 0.35), alpha), 40)
    dl:AddCircleFilled({ cx - cr * 0.18, cy + ri * 0.04 - cr * 0.22 }, cr * 0.72, u32(mix(GOLD, PALE, 0.35), 0.55 * alpha), 32)
    dl:AddCircle({ cx, cy + ri * 0.04 }, cr * 0.86, u32('#8A5A12', 0.8 * alpha), 40, math.max(1, cr * 0.07))
    text_center(dl, cx - cr, cy + ri * 0.04 - cr * 0.62, cr * 2, 'G', '#7A4C0C', F.dispb, cr * 1.15, alpha)
    text_center(dl, cx - cr, cy + ri * 0.04 - cr * 0.66, cr * 2, 'G', PALE, F.dispb, cr * 1.15, 0.9 * alpha)
    -- the glass over it
    for i = 1, 5 do
        local k = i / 5
        dl:PathClear()
        dl:PathArcTo({ cx, cy }, ri * 0.985, math.pi * (0.95 + 0.12 * k), math.pi * (1.78 - 0.14 * k), 20)
        dl:PathLineTo({ cx + ri * (0.12 - 0.3 * k), cy - ri * (0.1 + 0.15 * k) })
        dl:PathLineTo({ cx - ri * (0.28 + 0.1 * k), cy + ri * (0.55 - 0.35 * k) })
        dl:PathFillConvex(u32(mix('#6F8498', '#E3ECF5', k * 0.5), (0.09 + 0.03 * k) * alpha))
    end
    for i = 5, 1, -1 do
        dl:AddEllipseFilled({ cx - ri * 0.4, cy - ri * 0.42 }, { ri * 0.06 * i, ri * 0.04 * i }, u32('#FFFFFF', 0.06 * alpha), -0.75, 24)
    end
    dl:AddCircleFilled({ cx + ri * 0.48, cy + ri * 0.42 }, ri * 0.05, u32('#FFFFFF', 0.5 * alpha), 12)
    dl:AddCircle({ cx, cy }, ri - 0.5, u32('#000000', 0.5 * alpha), 48, math.max(1, r * 0.03))
end

-- an item's icon in a rounded well, with a fallback letter
local function item_icon(dl, id, x, y, size, alpha)
    alpha = alpha or 1
    dl:AddRectFilled({ x, y }, { x + size, y + size }, u32(P.well, 0.9 * alpha), S(6))
    local tex = I.icon(id)
    if tex ~= nil then
        dl:AddImageRounded(tex, { x + S(2), y + S(2) }, { x + size - S(2), y + size - S(2) }, { 0, 0 }, { 1, 1 }, u32('#FFFFFF', alpha), S(5))
    else
        text_center(dl, x, y + size / 2, size, (I.name(id):sub(1, 1)), P.dim, F.dispb, size * 0.5, alpha)
    end
    dl:AddRect({ x, y }, { x + size, y + size }, u32(P.line, 0.8 * alpha), S(6), 15, 1)
end

local function stock_pills(dl, x, y, id, alpha, right_align)
    local single, stack, fresh = stock_of(id)
    local r = I.get(id)
    local parts = {}
    if single ~= nil and single > 0 then parts[#parts + 1] = { single .. ' single' .. (single == 1 and '' or 's'), P.ok } end
    if r.stack > 1 and stack ~= nil and stack > 0 then parts[#parts + 1] = { stack .. ' stack' .. (stack == 1 and '' or 's'), P.cyan } end
    if #parts == 0 then
        if single == nil and stack == nil then parts[1] = { 'stock…', P.faint } else parts[1] = { 'none up', P.faint } end
    end
    local total = 0
    local widths = {}
    for i, pt in ipairs(parts) do widths[i] = pill(dl, 0, -1000, pt[1], pt[2], pt[2], F.disp, T.tiny, S(7)) total = total + widths[i] + (i > 1 and S(5) or 0) end
    local cx = right_align and (x - total) or x
    for i, pt in ipairs(parts) do
        pill(dl, cx, y, pt[1], mix(pt[2], P.ink, 0.78), pt[2], F.disp, T.tiny, S(7))
        cx = cx + widths[i] + S(5)
    end
    return total
end

-- the header: the mark, the title, where you are, your gil, the buttons
local function draw_header(dl, x, y, w, t)
    local h = S(88)
    U.aurora(dl, x, y, w, h + S(24), t)
    glass_gil(dl, x + S(44), y + S(42), S(46), t, 1)
    U.gradient_text(dl, x + S(82), y + S(16), 'AUCTION HOUSE', GOLD, P.accent2, F.dispb, T.title)
    local where
    if not logged_in() then where = 'Not logged in'
    elseif st.counter.near then where = 'At the counter'
    elseif st.counter.dist then where = string.format('Counter %.0f yalms away', st.counter.dist)
    else where = 'No counter nearby' end
    local sub = where
    if st.lists[st.category] then
        local n = 0
        for _, row in pairs(st.lists[st.category].items) do if row.single > 0 or row.stack > 0 then n = n + 1 end end
        sub = sub .. '   ·   ' .. n .. ' listed in ' .. (I.CATEGORY_NAME[st.category] or 'this category')
    end
    text(dl, x + S(84), y + S(50), sub, (st.counter.near or not settings.near_counter) and P.dim or P.warn, F.text, T.small)
    local pulse = 0.55 + 0.45 * math.sin(t * 2)
    dl:AddRectFilledMultiColor({ x + S(16), y + h - 1 }, { x + w - S(16), y + h + 1 }, u32(GOLD, 0), u32(GOLD, 0.9 * pulse), u32(P.accent2, 0.9 * pulse), u32(P.accent, 0))
    -- right side
    local bx = x + w - S(22)
    local size = S(32)
    local by = y + S(16)
    bx = bx - size
    if icon_button(dl, '##close', bx, by, size, 'xmark', P.dim, 'Close (Esc)') then st.open = false end
    bx = bx - size - S(4)
    if icon_button(dl, '##settings', bx, by, size, 'gear', st.settings_open and P.accent or P.dim, 'Settings') then st.settings_open = not st.settings_open end
    bx = bx - size - S(4)
    local waiting = SEARCH.pending() > 0 or st.sales_wait
    if waiting then
        dl:PathClear()
        dl:PathArcTo({ bx + size / 2, by + size / 2 }, size / 2 - S(2), t * 5, t * 5 + math.pi * 1.4, 24)
        dl:PathStroke(u32(P.cyan, 0.9), 0, S(2))
    end
    if icon_button(dl, '##refresh', bx, by, size, 'rotate-right', waiting and P.cyan or P.dim, 'Refresh the list and the item') then
        fetch_list(st.category, true)
        if st.selected then fetch_history(st.selected, false, true) if I.get(st.selected).stack > 1 then fetch_history(st.selected, true, true) end end
        refresh_inventory()
    end
    bx = bx - size - S(4)
    local n_sales = 0
    for _ in pairs(st.sales) do n_sales = n_sales + 1 end
    if icon_button(dl, '##mysales', bx, by, size, 'receipt', st.tab == 'sales' and GOLD or P.dim, 'My sales') then st.tab = 'sales' end
    if n_sales > 0 then
        dl:AddCircleFilled({ bx + size - S(5), by + S(5) }, S(6), u32(GOLD), 16)
        text_center(dl, bx + size - S(11), by + S(5), S(12), tostring(n_sales), P.ink, F.bold, T.tiny - 2)
    end
    -- gil
    st.gil_shown = st.gil_shown and lerp(st.gil_shown, st.gil, math.min(1, dt * 5)) or st.gil
    if math.abs(st.gil_shown - st.gil) < 0.5 then st.gil_shown = st.gil end
    local label = gil(st.gil_shown) .. ' gil'
    local pw = pill(dl, 0, -1000, label, P.card, GOLD, F.disp, T.small, S(9), 'coins')
    pill(dl, bx - S(16) - pw, by + S(5), label, mix(GOLD, P.ink, 0.78), GOLD, F.disp, T.small, S(9), 'coins')
    return h
end

local function draw_tabs(dl, x, y, w)
    local h = S(40)
    local tabs = { { 'buy', 'BUY', 'cart-shopping' }, { 'sell', 'SELL', 'tag' }, { 'sales', 'MY SALES', 'receipt' } }
    local tx = x + S(24)
    for _, tab in ipairs(tabs) do
        local on = st.tab == tab[1]
        local lw = measure(tab[2], F.disp, T.body)
        local tw = lw + S(44)
        imgui.SetCursorScreenPos({ tx, y })
        local pressed, _, hv = hit('##tab' .. tab[1], tw, h)
        if pressed then st.tab = tab[1] end
        local col = on and GOLD or mix(P.dim, P.text, hv)
        icon(dl, tx + S(14), y + h / 2, tab[3], col, T.small)
        text_mid(dl, tx + S(30), y + h / 2, tab[2], col, F.disp, T.body)
        if on then
            dl:AddRectFilledMultiColor({ tx + S(4), y + h - S(4) }, { tx + tw - S(8), y + h - S(2) }, u32(GOLD, 0.2), u32(GOLD, 1), u32(P.accent2, 1), u32(P.accent2, 0.2))
        end
        tx = tx + tw + S(6)
    end
    -- the search box, on the buy tab
    if st.tab == 'buy' then
        local sw = S(300)
        local sx = x + w - S(24) - sw
        imgui.SetCursorScreenPos({ sx, y + S(4) })
        imgui.SetNextItemWidth(sw)
        local changed
        with_font(F.text, T.small, function ()
            changed = imgui.InputTextWithHint('##ahsearch', 'Search every item by name', st.query, 48)
        end)
        if changed then
            local q = st.query[1] or ''
            if #q >= 2 then st.results, st.result_total = I.search(q, 80) else st.results = nil end
            st.list_at = clock()
        end
        icon(dl, sx + sw - S(16), y + h / 2, (st.query[1] or '') ~= '' and 'xmark' or 'magnifying-glass', P.dim, T.small)
        if (st.query[1] or '') ~= '' then
            imgui.SetCursorScreenPos({ sx + sw - S(28), y + S(6) })
            if (hit('##clearq', S(24), S(24))) then st.query[1] = '' st.results = nil end
        end
    end
    dl:AddLine({ x + S(16), y + h }, { x + w - S(16), y + h }, u32(P.line), 1)
    return h
end

-- the categories, grouped
local function draw_sidebar(dl, x, y, w, h)
    panel(dl, x, y, w, h, P.glass, 0.92, S(12))
    imgui.SetCursorScreenPos({ x, y })
    imgui.BeginChild('##cats', { w, h }, false, 0)
    local cdl = imgui.GetWindowDrawList()
    local cy = y + S(8) - imgui.GetScrollY() -- drawn where the scroll puts it
    for _, g in ipairs(I.GROUPS) do
        local open = st.group_open[g.id]
        if open == nil then open = (g.id == st.group) st.group_open[g.id] = open end
        imgui.SetCursorScreenPos({ x, cy })
        local pressed, _, hv = hit('##grp' .. g.id, w, S(30))
        if pressed then st.group_open[g.id] = not open end
        local active = I.group_of(st.category).id == g.id
        cdl:AddRectFilled({ x + S(6), cy + S(2) }, { x + w - S(6), cy + S(28) }, u32(P.card_hi, (active and 0.5 or 0.15) + 0.3 * hv), S(8))
        icon(cdl, x + S(20), cy + S(15), g.icon, active and GOLD or mix(P.dim, P.text, hv), T.small)
        text_mid(cdl, x + S(36), cy + S(15), g.name:upper(), active and P.text or mix(P.dim, P.text, hv), F.disp, T.small)
        icon(cdl, x + w - S(18), cy + S(15), open and 'chevron-down' or 'chevron-right', P.faint, T.tiny)
        cy = cy + S(32)
        if open then
            for _, cat in ipairs(g.cats) do
                local n = #I.category(cat)
                if n > 0 then
                    imgui.SetCursorScreenPos({ x, cy })
                    local cp, _, chv = hit('##cat' .. cat, w, S(24))
                    local on = st.category == cat and st.results == nil
                    if cp then
                        st.category, st.group = cat, g.id
                        st.query[1], st.results = '', nil
                        st.list_at = clock()
                        fetch_list(cat)
                    end
                    if on then cdl:AddRectFilled({ x + S(12), cy + S(1) }, { x + w - S(6), cy + S(23) }, u32(GOLD, 0.14), S(7)) end
                    text_mid(cdl, x + S(26), cy + S(12), I.CATEGORY_NAME[cat] or ('Category ' .. cat), on and GOLD or mix(P.dim, P.text, 0.5 + 0.5 * chv), F.text, T.small)
                    -- how many are up, once known
                    local list = st.lists[cat]
                    if list then
                        local up = 0
                        for _, row in pairs(list.items) do if row.single > 0 or row.stack > 0 then up = up + 1 end end
                        local lbl = tostring(up)
                        text_mid(cdl, x + w - S(14) - measure(lbl, F.semi, T.tiny), cy + S(12), lbl, up > 0 and P.ok or P.faint, F.semi, T.tiny)
                    end
                    cy = cy + S(24)
                end
            end
            cy = cy + S(4)
        end
    end
    imgui.SetCursorScreenPos({ x, cy + S(4) }) -- the content's end, so the child knows how far it scrolls
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
end

-- one item row in the list
local function draw_item_row(dl, id, x, y, w, alpha)
    local h = S(56)
    local key = '##item' .. id
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = hit(key, w, h)
    local selected = st.selected == id
    local r = I.get(id)
    panel(dl, x, y, w, h, selected and P.card_hi or P.card, (selected and 1 or 0.9 + 0.1 * hv) * alpha, S(10), selected and GOLD or (hv > 0.01 and mix(P.line, P.accent, hv) or nil), selected)
    U.draw_ripples(dl, key, x, y, w, h, GOLD)
    item_icon(dl, id, x + S(10), y + S(8), S(40), alpha)
    local name = fit(r.name, F.disp, T.h2, w - S(250))
    text(dl, x + S(60), y + S(8), name, selected and GOLD or P.text, F.disp, T.h2, alpha)
    local line = I.jobs_line(id)
    if r.stack > 1 then line = (line ~= '' and (line .. '  ·  ') or '') .. 'Stacks of ' .. r.stack end
    text(dl, x + S(60), y + S(33), fit(line, F.text, T.tiny, w - S(250)), P.dim, F.text, T.tiny, alpha * 0.9)
    stock_pills(dl, x + w - S(14), y + S(10), id, alpha, true)
    -- the last sale, once known
    local hs = history_of(id, false)
    if hs and hs.stats then
        local lbl = gil(hs.stats.last) .. ' gil'
        text(dl, x + w - S(14) - measure(lbl, F.semi, T.small), y + S(34), lbl, GOLD, F.semi, T.small, alpha)
    end
    if pressed then
        U.ripple_at(key)
        select_item(selected and nil or id)
    end
    if hovered and imgui.IsMouseDoubleClicked(0) and not selected then select_item(id) end
    return h
end

local function draw_list(dl, x, y, w, h, t)
    local ids, title
    if st.results then
        ids, title = st.results, 'SEARCH  ·  ' .. #st.results .. (st.result_total > #st.results and (' of ' .. st.result_total) or '') .. ' results'
    else
        ids = I.category(st.category)
        title = (I.CATEGORY_NAME[st.category] or ''):upper() .. '  ·  ' .. #ids .. ' items'
        if settings.sort == 'level' then
            local copy = {}
            for i, id in ipairs(ids) do copy[i] = id end
            table.sort(copy, function (a, b)
                local la, lb = I.get(a).level, I.get(b).level
                if la ~= lb then return la > lb end
                return I.name(a) < I.name(b)
            end)
            ids = copy
        elseif settings.sort == 'stock' then
            local copy = {}
            for i, id in ipairs(ids) do copy[i] = id end
            table.sort(copy, function (a, b)
                local sa1, sa2 = stock_of(a) local sb1, sb2 = stock_of(b)
                local ta, tb = (sa1 or 0) + (sa2 or 0), (sb1 or 0) + (sb2 or 0)
                if ta ~= tb then return ta > tb end
                return I.name(a) < I.name(b)
            end)
            ids = copy
        end
    end
    -- the in-stock filter: only what is up right now; an item whose stock isn't known yet stays until it is
    local hidden = 0
    if settings.in_stock then
        local keep = {}
        for _, id in ipairs(ids) do
            local single, stack = stock_of(id)
            if (single == nil and stack == nil) or (single or 0) + (stack or 0) > 0 then keep[#keep + 1] = id end
        end
        hidden = #ids - #keep
        ids = keep
        if st.results then
            title = 'SEARCH  ·  ' .. #ids .. ' in stock'
        else
            title = (I.CATEGORY_NAME[st.category] or ''):upper() .. '  ·  ' .. #ids .. ' in stock of ' .. (#ids + hidden)
        end
    end
    text(dl, x + S(6), y, title, P.dim, F.disp, T.small)
    -- the sort, at the right
    local sorts = { { 'name', 'NAME' }, { 'level', 'LEVEL' }, { 'stock', 'STOCK' } }
    local sw = 0
    for _, s in ipairs(sorts) do sw = sw + measure(s[2], F.disp, T.tiny) + S(22) + S(5) end
    local picked = U.segments(dl, '##sort', x + w - sw, y - S(6), S(24), sorts, settings.sort or 'name', nil, F.disp, T.tiny)
    if picked ~= settings.sort then settings.sort = picked save_settings() end
    -- the in-stock chip, left of the sort
    do
        local label = 'IN STOCK'
        local gs = S(12)
        local lw = measure(label, F.disp, T.tiny)
        local cw, ch = S(22) + gs + S(6) + lw, S(24)
        local fx, fy = x + w - sw - cw - S(12), y - S(6)
        imgui.SetCursorScreenPos({ fx, fy })
        local pressed, hovered, hv = hit('##instock', cw, ch)
        if pressed then settings.in_stock = not settings.in_stock save_settings() end
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, settings.in_stock and 'Showing only what is up for sale' or 'Show only what is up for sale') end
        local on, color = settings.in_stock, P.ok
        if on then
            dl:AddRectFilled({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.28), S(9))
            dl:AddRect({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.95), S(9), 15, 1)
        else
            dl:AddRectFilled({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.05 + 0.1 * hv), S(9))
            dl:AddRect({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.22 + 0.4 * hv), S(9), 15, 1)
        end
        local fg = on and color or mix(color, P.dim, 0.45)
        icon(dl, fx + S(11) + gs / 2, fy + ch / 2, on and 'square-check' or 'filter', fg, gs, on and 1 or 0.55 + 0.45 * hv)
        text_center(dl, fx + S(11) + gs + S(6), fy + ch / 2, lw, label, fg, F.disp, T.tiny)
    end
    local ly = y + S(28)
    local lh = h - S(28)
    imgui.SetCursorScreenPos({ x, ly })
    imgui.BeginChild('##items', { w, lh }, false, 0)
    local cdl = imgui.GetWindowDrawList()
    local scroll_y = imgui.GetScrollY()
    local cy = ly - scroll_y
    local since = clock() - st.list_at
    local shown = 0
    if #ids == 0 then
        local why = hidden > 0 and 'Nothing in stock' or (st.results and 'Nothing by that name' or 'Nothing here')
        text_center(cdl, x, ly + S(60), w, why, P.dim, F.disp, T.h1)
        if hidden > 0 then text_center(cdl, x, ly + S(90), w, hidden .. (hidden == 1 and ' item is' or ' items are') .. ' hidden by the in-stock filter', P.faint, F.text, T.small) end
        if st.results == nil and st.search_error then text_center(cdl, x, ly + S(90), w, 'Search server: ' .. tostring(st.search_error), P.danger, F.text, T.small) end
    end
    local vis_top, vis_bot = ly - S(60), ly + lh + S(60)
    for i, id in ipairs(ids) do
        local rh = S(56)
        if cy + rh >= vis_top and cy <= vis_bot then
            local alpha = math.min(1, (since * 6 - i * 0.05) + 0.3)
            draw_item_row(cdl, id, x + S(4), cy, w - S(12), math.max(0.05, math.min(1, alpha)))
        end
        cy = cy + rh + S(6)
        shown = shown + 1
    end
    imgui.SetCursorScreenPos({ x, cy + S(2) })
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
    -- the stock is still coming
    if st.fetching['cat' .. st.category] and st.results == nil then
        text(dl, x + w - S(120), y, 'fetching stock…', P.cyan, F.text, T.tiny)
    end
end

-- the selected item: everything about it, its history, and the buy box
local function draw_detail(dl, x, y, w, h, t)
    local id = st.selected
    panel(dl, x, y, w, h, P.glass, 0.97, S(14), P.line)
    if id == nil then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(30), w, 'Pick an item', P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(54), w, 'Its stock, sale history and a buy box show here', P.dim, F.text, T.small)
        return
    end
    local r = I.get(id)
    local cx, cy = x + S(16), y + S(16)
    item_icon(dl, id, cx, cy, S(56), 1)
    text(dl, cx + S(68), cy, fit(r.name, F.disp, T.h1, w - S(100)), GOLD, F.disp, T.h1)
    local line = I.jobs_line(id)
    if r.stack > 1 then line = (line ~= '' and (line .. '  ·  ') or '') .. 'Stacks of ' .. r.stack end
    text(dl, cx + S(68), cy + S(28), fit(line ~= '' and line or (I.CATEGORY_NAME[I.category_of(id) or 0] or ''), F.text, T.small, w - S(100)), P.dim, F.text, T.small)
    cy = cy + S(66)
    -- the description, wrapped
    if r.desc ~= '' then
        local lines = {}
        for raw in (r.desc .. '\n'):gmatch('([^\n]*)\n') do
            for _, l in ipairs(wrap(raw, F.text, T.small, w - S(32))) do lines[#lines + 1] = l end
        end
        for i = 1, math.min(#lines, 5) do
            text(dl, cx, cy, lines[i], P.text, F.text, T.small)
            cy = cy + S(18)
        end
        cy = cy + S(6)
    end
    -- the jobs, as badges, when it's gear for some of them
    local jobs = I.jobs_of(r.jobs)
    if r.level > 0 and #jobs > 0 and #jobs < 22 and not I.all_jobs(r.jobs) then
        local bx = cx
        for _, j in ipairs(jobs) do
            if bx + S(24) > x + w - S(16) then break end
            U.job_badge(dl, bx + S(11), cy + S(11), S(10), j, 0, 1)
            bx = bx + S(26)
        end
        cy = cy + S(30)
    end
    dl:AddLine({ cx, cy }, { x + w - S(16), cy }, u32(P.line), 1)
    cy = cy + S(10)
    -- stock and the single/stack switch
    local single, stack = stock_of(id)
    text(dl, cx, cy, 'IN STOCK', P.accent, F.disp, T.small)
    stock_pills(dl, x + w - S(16), cy - S(2), id, 1, true)
    cy = cy + S(26)
    if r.stack > 1 then
        local picked = U.segments(dl, '##ss', cx, cy, S(26), { { false, 'SINGLE' }, { true, 'STACK of ' .. r.stack } }, st.stack, function () return GOLD end, F.disp, T.tiny)
        if picked ~= st.stack then st.stack = picked st.buy.price[1] = '' end
        cy = cy + S(34)
    end
    -- the history
    local hs = history_of(id, st.stack)
    text(dl, cx, cy, 'RECENT SALES', P.accent, F.disp, T.small)
    if st.fetching[id .. '/' .. (st.stack and 1 or 0)] then text(dl, x + w - S(16) - measure('fetching…', F.text, T.tiny), cy + S(2), 'fetching…', P.cyan, F.text, T.tiny) end
    cy = cy + S(22)
    local bottom = y + h - S(96)
    if hs == nil then
        text(dl, cx, cy, st.search_error and ('Search server: ' .. tostring(st.search_error)) or 'Asking the house…', st.search_error and P.danger or P.dim, F.text, T.small)
    elseif #hs.sales == 0 then
        text(dl, cx, cy, 'No ' .. (st.stack and 'stacks' or 'singles') .. ' sold lately', P.dim, F.text, T.small)
        cy = cy + S(20)
    else
        local s = hs.stats
        -- the summary: last, median, range, trend
        local function stat(label, value, col, at)
            text(dl, at, cy, label, P.faint, F.disp, T.tiny - 1)
            text(dl, at, cy + S(13), value, col or P.text, F.semi, T.small)
        end
        local colw = (w - S(32)) / 3
        stat('LAST', gil(s.last), GOLD, cx)
        stat('MEDIAN', gil(s.median), P.text, cx + colw)
        stat('RANGE', gil(s.low) .. ' – ' .. gil(s.high), P.dim, cx + colw * 2)
        if s.trend then
            local up = s.trend > 0.02
            local flat = math.abs(s.trend) <= 0.02
            local tcol = flat and P.dim or (up and P.danger or P.ok)
            local tl = flat and 'steady' or string.format('%s%.0f%%', up and '+' or '', s.trend * 100)
            icon(dl, x + w - S(28), cy + S(16), flat and 'minus' or (up and 'arrow-trend-up' or 'arrow-trend-down'), tcol, T.small)
            text(dl, x + w - S(40) - measure(tl, F.semi, T.tiny), cy + S(11), tl, tcol, F.semi, T.tiny)
        end
        cy = cy + S(38)
        -- the rows: price, when, who
        for i, sale in ipairs(hs.sales) do
            if cy + S(18) > bottom then break end
            local pl = gil(sale.price)
            text(dl, cx, cy, pl, i == 1 and GOLD or P.text, F.semi, T.small)
            local when = ago(sale.date)
            text(dl, cx + S(96), cy, when, P.dim, F.text, T.small)
            local who = fit(sale.seller .. ' → ' .. sale.buyer, F.text, T.tiny, w - S(190))
            text(dl, x + w - S(16) - measure(who, F.text, T.tiny), cy + S(2), who, P.faint, F.text, T.tiny)
            cy = cy + S(19)
        end
    end
    -- the buy box, at the bottom
    local by = y + h - S(86)
    dl:AddLine({ cx, by - S(8) }, { x + w - S(16), by - S(8) }, u32(P.line), 1)
    text(dl, cx, by, 'YOUR BID', GOLD, F.disp, T.small)
    local hint = hs and hs.stats and ('last sold ' .. gil(hs.stats.last)) or 'what you will pay'
    text(dl, x + w - S(16) - measure(hint, F.text, T.tiny), by + S(2), hint, P.faint, F.text, T.tiny)
    by = by + S(22)
    imgui.SetCursorScreenPos({ cx, by })
    imgui.SetNextItemWidth(w - S(32) - S(110))
    with_font(F.text, T.body, function ()
        imgui.InputTextWithHint('##bid', hs and hs.stats and tostring(hs.stats.last) or '0', st.buy.price, 10, 1)
    end)
    local price = tonumber(st.buy.price[1]) or (hs and hs.stats and hs.stats.last) or 0
    local can = may_trade() and price > 0 and logged_in() and st.buy.pending == nil
    local label = st.buy.pending and 'Bidding…' or 'Bid'
    if button(dl, '##bid_btn', x + w - S(16) - S(104), by, S(104), S(34), label, can and GOLD or P.faint, can and 'solid' or 'ghost', 'gavel') and can then
        if settings.confirm_buy then
            st.confirm = { kind = 'buy', item = id, price = price, stack = st.stack }
        else
            do_buy(id, price, st.stack)
        end
    end
    if not may_trade() then
        text(dl, cx, by + S(40), 'Stand by an Auction Counter to bid', P.warn, F.text, T.tiny)
    elseif price > st.gil then
        text(dl, cx, by + S(40), "That's more gil than you have", P.warn, F.text, T.tiny)
    elseif hs and hs.stats and price > 0 and price < hs.stats.low then
        text(dl, cx, by + S(40), 'Below every recent sale: the house may not fill it', P.faint, F.text, T.tiny)
    end
end

-- SELL: the bag, and the listing box
local function draw_sell(dl, x, y, w, h, t)
    if clock() - st.inv_at > LIMITS.inventory then refresh_inventory() end
    local bagw = w - S(340)
    text(dl, x + S(6), y, 'YOUR BAG  ·  ' .. #st.inventory .. ' items', P.dim, F.disp, T.small)
    local gy = y + S(28)
    local gh = h - S(28)
    imgui.SetCursorScreenPos({ x, gy })
    imgui.BeginChild('##bag', { bagw, gh }, false, 0)
    local cdl = imgui.GetWindowDrawList()
    local cell = S(52)
    local per = math.max(1, math.floor((bagw - S(16)) / (cell + S(6))))
    local cx, cy = x + S(4), gy - imgui.GetScrollY()
    local n = 0
    for _, it in ipairs(st.inventory) do
        local r = I.get(it.id)
        local sellable = I.rows[it.id] ~= nil and bit.band(r.flags, 0x40) == 0 -- the house lists it, and it isn't NOAUCTION-flagged by the DAT
        local key = '##bag' .. it.slot
        imgui.SetCursorScreenPos({ cx, cy })
        local pressed, hovered, hv = hit(key, cell, cell)
        local on = st.sell.slot == it.slot
        cdl:AddRectFilled({ cx, cy }, { cx + cell, cy + cell }, u32(on and GOLD or P.card, on and 0.22 or (0.6 + 0.3 * hv)), S(8))
        item_icon(cdl, it.id, cx + S(6), cy + S(6), cell - S(12), sellable and 1 or 0.35)
        if it.count > 1 then
            local cl = tostring(it.count)
            cdl:AddRectFilled({ cx + cell - S(8) - measure(cl, F.bold, T.tiny - 1), cy + cell - S(18) }, { cx + cell - S(4), cy + cell - S(4) }, u32(P.ink, 0.8), S(4))
            text(cdl, cx + cell - S(6) - measure(cl, F.bold, T.tiny - 1), cy + cell - S(17), cl, P.text, F.bold, T.tiny - 1)
        end
        if on then cdl:AddRect({ cx, cy }, { cx + cell, cy + cell }, u32(GOLD, 0.9), S(8), 15, S(1.5)) end
        if hovered then
            with_font(F.text, T.small, imgui.SetTooltip, r.name .. (it.count > 1 and (' x' .. it.count) or '') .. (sellable and '' or '\nThe house does not take this'))
        end
        if pressed and sellable then
            st.sell.slot, st.sell.item, st.sell.count = it.slot, it.id, it.count
            st.sell.stack = false
            st.sell.price[1] = ''
            st.sell.fee, st.sell.asked = nil, nil
            fetch_history(it.id, false)
            if r.stack > 1 then fetch_history(it.id, true) end
        end
        n = n + 1
        if n % per == 0 then cx = x + S(4) cy = cy + cell + S(6) else cx = cx + cell + S(6) end
    end
    if n % per ~= 0 then cy = cy + cell + S(6) end
    imgui.SetCursorScreenPos({ x, cy + S(2) })
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
    -- the listing box
    local px = x + bagw + S(12)
    local pw = w - bagw - S(12)
    panel(dl, px, y, pw, h, P.glass, 0.97, S(14), P.line)
    local sx, sy = px + S(16), y + S(16)
    if st.sell.slot == nil or st.sell.item == nil then
        icon(dl, px + pw / 2, y + h / 2 - S(24), 'tag', P.faint, T.title)
        text_center(dl, px, y + h / 2 + S(10), pw, 'Pick something from your bag', P.text, F.disp, T.h2)
        text_center(dl, px, y + h / 2 + S(34), pw, 'Greyed items are ones the house does not take', P.dim, F.text, T.small)
        return
    end
    local id = st.sell.item
    local r = I.get(id)
    item_icon(dl, id, sx, sy, S(48), 1)
    text(dl, sx + S(60), sy, fit(r.name, F.disp, T.h2, pw - S(90)), GOLD, F.disp, T.h2)
    text(dl, sx + S(60), sy + S(26), 'You have ' .. st.sell.count .. (r.stack > 1 and ('  ·  stacks of ' .. r.stack) or ''), P.dim, F.text, T.small)
    sy = sy + S(62)
    if r.stack > 1 then
        local can_stack = st.sell.count >= r.stack
        local picked = U.segments(dl, '##sellss', sx, sy, S(26), { { false, 'SINGLE' }, { true, 'FULL STACK' } }, st.sell.stack, function (o) return (o[1] and not can_stack) and P.faint or GOLD end, F.disp, T.tiny)
        if picked and not can_stack then picked = false end
        if picked ~= st.sell.stack then st.sell.stack = picked st.sell.price[1] = '' st.sell.fee, st.sell.asked = nil, nil end
        if not can_stack then text(dl, sx + S(200), sy + S(7), 'not a full stack', P.faint, F.text, T.tiny) end
        sy = sy + S(34)
    end
    -- what it has been selling for
    local hs = history_of(id, st.sell.stack)
    text(dl, sx, sy, 'RECENTLY SOLD FOR', P.accent, F.disp, T.small)
    sy = sy + S(20)
    if hs and hs.stats then
        text(dl, sx, sy, gil(hs.stats.last) .. ' last  ·  ' .. gil(hs.stats.median) .. ' median  ·  ' .. gil(hs.stats.low) .. ' – ' .. gil(hs.stats.high), P.text, F.text, T.small)
    elseif hs then
        text(dl, sx, sy, 'No ' .. (st.sell.stack and 'stacks' or 'singles') .. ' sold lately', P.dim, F.text, T.small)
    else
        text(dl, sx, sy, 'Asking the house…', P.dim, F.text, T.small)
    end
    sy = sy + S(30)
    text(dl, sx, sy, 'ASKING PRICE', GOLD, F.disp, T.small)
    sy = sy + S(20)
    imgui.SetCursorScreenPos({ sx, sy })
    imgui.SetNextItemWidth(pw - S(32))
    with_font(F.text, T.body, function ()
        if imgui.InputTextWithHint('##ask', hs and hs.stats and tostring(hs.stats.last) or 'gil', st.sell.price, 10, 1) then
            st.sell.fee, st.sell.asked = nil, nil
        end
    end)
    sy = sy + S(40)
    local price = tonumber(st.sell.price[1]) or 0
    local can = may_trade() and price > 0 and not st.sell.pending
    if st.sell.asked and st.sell.asked.price == price and st.sell.asked.stack == st.sell.stack then
        text(dl, sx, sy, 'Fee ' .. gil(st.sell.fee or 0) .. ' gil, paid now', st.sell.fee and st.sell.fee > st.gil and P.danger or P.dim, F.text, T.small)
        sy = sy + S(26)
        local ok = can and (st.sell.fee or 0) <= st.gil
        if button(dl, '##list_btn', sx, sy, pw - S(32), S(36), st.sell.pending and 'Listing…' or 'Put it up for sale', ok and GOLD or P.faint, ok and 'solid' or 'ghost', 'tag') and ok then
            st.confirm = { kind = 'sell' }
        end
    else
        text(dl, sx, sy, 'The house quotes its fee before you commit', P.faint, F.text, T.tiny)
        sy = sy + S(26)
        if button(dl, '##ask_btn', sx, sy, pw - S(32), S(36), st.sell.pending and 'Asking…' or 'Ask the fee', can and P.accent or P.faint, can and 'solid' or 'ghost', 'receipt') and can then
            do_ask(st.sell.slot, id, price, st.sell.stack)
        end
    end
    if not may_trade() then text(dl, sx, sy + S(44), 'Stand by an Auction Counter to sell', P.warn, F.text, T.tiny) end
end

-- MY SALES
local function draw_sales(dl, x, y, w, h, t)
    local rows = {}
    for _, row in pairs(st.sales) do rows[#rows + 1] = row end
    table.sort(rows, function (a, b) return a.slot < b.slot end)
    text(dl, x + S(6), y, 'UP FOR SALE  ·  ' .. #rows .. (#rows == 1 and ' item' or ' items'), P.dim, F.disp, T.small)
    local cooling = clock() - st.sales_at < LIMITS.sales
    if button(dl, '##sales_refresh', x + w - S(130), y - S(6), S(124), S(26), st.sales_wait and 'Asking…' or 'Refresh', cooling and P.faint or P.accent, 'ghost', 'rotate-right', F.semi, T.tiny) and not cooling and may_trade() then
        send_sales()
    end
    local cy = y + S(32)
    if #rows == 0 then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(30), w, st.sales_open and 'Nothing up for sale' or 'Ask the house', P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(54), w, st.sales_open and 'Sell something from your bag' or (may_trade() and 'Refresh lists what you have up' or 'Stand by an Auction Counter'), P.dim, F.text, T.small)
        return
    end
    for _, row in ipairs(rows) do
        local rh = S(60)
        panel(dl, x + S(4), cy, w - S(8), rh, P.card, 0.95, S(10))
        item_icon(dl, row.id, x + S(14), cy + S(8), S(44), 1)
        local r = I.get(row.id)
        text(dl, x + S(68), cy + S(8), r.name .. (row.stack and ('  ·  stack of ' .. r.stack) or ''), P.text, F.disp, T.h2)
        text(dl, x + S(68), cy + S(34), 'Slot ' .. (row.slot + 1) .. (row.at and row.at > 0 and ('  ·  listed ' .. ago(row.at)) or ''), P.dim, F.text, T.tiny)
        local pl = gil(row.price) .. ' gil'
        text(dl, x + w - S(150) - measure(pl, F.disp, T.h2), cy + S(10), pl, GOLD, F.disp, T.h2)
        local can = may_trade() and st.cancel_pending == nil
        if button(dl, '##cancel' .. row.slot, x + w - S(130), cy + S(14), S(116), S(32), 'Take down', can and P.danger or P.faint, 'ghost', 'xmark', F.semi, T.small) and can then
            st.confirm = { kind = 'cancel', slot = row.slot, item = row.id }
        end
        cy = cy + rh + S(8)
    end
    text(dl, x + S(6), cy + S(4), 'Sold items pay out to your delivery box; the house holds unsold ones until you take them down.', P.faint, F.text, T.tiny)
end

local function draw_settings(dl, x, y, w, h)
    panel(dl, x, y, w, h, P.glass, 0.98, S(14), P.accent2, true)
    local cx, cy = x + S(20), y + S(16)
    icon(dl, cx + S(8), cy + S(10), 'sliders', P.accent2, T.body)
    text(dl, cx + S(26), cy, 'SETTINGS', P.accent2, F.disp, T.h2)
    if icon_button(dl, '##settings_close', x + w - S(44), y + S(10), S(28), 'xmark', P.dim, 'Close') then st.settings_open = false end
    cy = cy + S(36)
    local changed = false
    local v, ch
    v, ch = U.toggle(dl, '##t_counter', cx, cy + S(10), 'Only at an Auction Counter', settings.near_counter) settings.near_counter = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_takeover', cx, cy + S(10), "Talking to the counter opens this, not the game's menu", settings.take_over) settings.take_over = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_confirm', cx, cy + S(10), 'Confirm before bidding', settings.confirm_buy) settings.confirm_buy = v changed = changed or ch
    cy = cy + S(40)
    text(dl, cx, cy, 'WINDOW', P.dim, F.disp, T.small)
    cy = cy + S(24)
    text_mid(dl, cx, cy, 'Opacity', P.dim, F.text, T.small)
    local op = U.slider(dl, '##s_op', cx + S(80), cy, S(200), (settings.opacity or 1) * 100, 40, 100, '%d%%')
    if math.abs(op / 100 - settings.opacity) > 0.001 then settings.opacity = op / 100 changed = true end
    cy = cy + S(30)
    text_mid(dl, cx, cy, 'Scale', P.dim, F.text, T.small)
    local sc, _, released = U.slider(dl, '##s_scale', cx + S(80), cy, S(200), st.scale_edit or settings.scale or 100, 50, 300, '%d%%', true)
    st.scale_edit = sc
    if released then settings.scale = math.floor(sc) st.scale_edit = nil changed = true end
    cy = cy + S(40)
    text(dl, cx, cy, 'SEARCH SERVER', P.dim, F.disp, T.small)
    cy = cy + S(20)
    text(dl, cx, cy, 'Talking to ' .. tostring(st.search_where) .. (settings.search_host ~= '' and '' or '  (from your login)'), P.text, F.text, T.small)
    cy = cy + S(20)
    text(dl, cx, cy, '/ah server <host[:port]> to point it elsewhere, /ah server auto to let it find out', P.faint, F.text, T.tiny)
    cy = cy + S(30)
    text(dl, cx, cy, 'KEYS', P.dim, F.disp, T.small)
    cy = cy + S(20)
    local bind = (settings.keybind or ''):gsub('^%^', 'Ctrl+'):gsub('^!', 'Alt+'):gsub('^%+', 'Shift+')
    text(dl, cx, cy, (bind ~= '' and (bind .. ' opens the house') or 'No key bound') .. '  ·  Esc closes it', P.text, F.text, T.small)
    if changed then save_settings() end
end

local function draw_confirm()
    local c = st.confirm
    if c == nil then return end
    local w, h = S(420), S(176)
    U.dialog('##ah_confirm', w, h, 0, function (dl, x, y)
        shadow(dl, x, y, w, h, S(16), 1.5)
        panel(dl, x, y, w, h, P.glass, 1, S(16), GOLD, true)
        local title, body, yes, ic, col
        if c.kind == 'buy' then
            local r = I.get(c.item)
            title = 'Bid ' .. gil(c.price) .. ' gil?'
            body = r.name .. (c.stack and ('  ·  stack of ' .. r.stack) or '  ·  one') .. '\nThe house fills the cheapest listing at or under your bid; you pay what you bid.'
            yes, ic, col = 'Bid', 'gavel', GOLD
            item_icon(dl, c.item, x + w - S(22) - S(48), y + S(16), S(48), 1)
        elseif c.kind == 'sell' then
            local a = st.sell.asked
            local r = I.get(a.item)
            title = 'List it for ' .. gil(a.price) .. ' gil?'
            body = r.name .. (a.stack and ('  ·  stack of ' .. r.stack) or '  ·  one') .. '\nFee ' .. gil(st.sell.fee or 0) .. ' gil now, kept whether or not it sells.'
            yes, ic, col = 'Put it up', 'tag', GOLD
            item_icon(dl, a.item, x + w - S(22) - S(48), y + S(16), S(48), 1)
        else
            title = 'Take it down?'
            body = I.name(c.item) .. ' comes back to your bag.\nThe listing fee is not returned.'
            yes, ic, col = 'Take down', 'xmark', P.danger
        end
        text(dl, x + S(22), y + S(18), title, P.text, F.disp, T.h1)
        local ly = y + S(50)
        for line in (body .. '\n'):gmatch('([^\n]*)\n') do
            for _, l in ipairs(wrap(line, F.text, T.small, w - S(110))) do
                text(dl, x + S(22), ly, l, P.dim, F.text, T.small)
                ly = ly + S(18)
            end
        end
        if button(dl, '##cyes', x + w - S(22) - S(136), y + h - S(50), S(136), S(34), yes, col, 'solid', ic) then
            if c.kind == 'buy' then do_buy(c.item, c.price, c.stack)
            elseif c.kind == 'sell' then do_list()
            else do_cancel(c.slot) end
            st.confirm = nil
        end
        if button(dl, '##cno', x + w - S(22) - S(136) - S(8) - S(96), y + h - S(50), S(96), S(34), 'Cancel', P.dim, 'ghost') then st.confirm = nil end
    end)
end

local function draw_main(t)
    local sw, sh = vana.ui.screen()
    local w, h = S(W.w), S(W.h)
    imgui.SetNextWindowSize({ w, h }, U.ALWAYS)
    imgui.SetNextWindowPos({ (sw - w) / 2, (sh - h) / 2 }, U.FIRST_USE_EVER)
    local alpha = settings.opacity or 1.0
    U.set_window_alpha(alpha)
    U.push_theme()
    imgui.SetWindowFontScale(U.scale())
    local open = { st.open }
    if imgui.Begin('##auctionhouse', open, U.WINDOW_FLAGS) then
        local dl = imgui.GetWindowDrawList()
        local x, y = imgui.GetWindowPos()
        local cx, cy = math.max(0, math.min(x, sw - w)), math.max(0, math.min(y, sh - h))
        if cx ~= x or cy ~= y then imgui.SetWindowPos({ cx, cy }) x, y = cx, cy end
        st.main = { x = x, y = y, w = w, h = h }
        local fade = math.min(1, (t - st.opened_at) * 4)
        shadow(dl, x, y, w, h, S(16), fade)
        panel(dl, x, y, w, h, P.bg, fade, S(16), P.line)
        local hy = draw_header(dl, x, y, w, t)
        local ty = y + hy + S(10)
        draw_tabs(dl, x, ty, w)
        local by = ty + S(50)
        local bh = y + h - by - S(16)
        if st.settings_open then
            draw_settings(dl, x + S(16), by, w - S(32), bh)
        elseif st.tab == 'buy' then
            local sbw = S(190)
            draw_sidebar(dl, x + S(16), by, sbw, bh)
            local dw = S(330)
            local lx = x + S(16) + sbw + S(12)
            local lw = w - S(32) - sbw - S(12) - dw - S(12)
            draw_list(dl, lx, by, lw, bh, t)
            draw_detail(dl, lx + lw + S(12), by, dw, bh, t)
        elseif st.tab == 'sell' then
            draw_sell(dl, x + S(16), by, w - S(32), bh, t)
        else
            draw_sales(dl, x + S(16), by, w - S(32), bh, t)
        end
        if imgui.IsWindowFocused() and imgui.IsKeyPressed(U.KEY_ESCAPE) then
            if st.confirm then st.confirm = nil elseif st.settings_open then st.settings_open = false else st.open = false end
        end
    end
    imgui.End()
    if not open[1] then st.open = false end
    draw_confirm()
    U.pop_theme()
    U.set_window_alpha(1)
end

-------------------------------------------------------------------------------
-- The frame
-------------------------------------------------------------------------------

local function tick()
    local io = imgui.GetIO()
    dt = math.max(0.001, math.min(0.1, io.DeltaTime or 0.016))
    local scale = math.max(0.5, math.min(3, (settings.scale or 100) / 100))
    local t = imgui.GetTime()
    now_t = t
    if not U.frame(dt, scale, t) then return end
    SEARCH.poll()
    if st.open then
        if clock() - st.counter.at > LIMITS.scan then scan_counter() end
        if st.buy.pending and clock() - st.buy.pending.at > LIMITS.reply then
            st.buy.pending = nil
            U.toast('danger', 'No answer', 'The house did not answer your bid', 5, 'hourglass-end')
        end
        if st.sell.pending and clock() - st.sell.at > LIMITS.reply then
            st.sell.pending = false
            U.toast('danger', 'No answer', 'The house did not answer', 5, 'hourglass-end')
        end
        if st.sales_dirty and clock() - st.sales_at > LIMITS.sales and may_trade() then
            st.sales_dirty = false
            send_sales()
        end
        if st.tab == 'sales' and not st.sales_open and not st.sales_wait and may_trade() and clock() - st.sales_at > LIMITS.sales and logged_in() then
            send_sales()
        end
        if st.sales_wait and clock() - st.sales_at > LIMITS.reply then st.sales_wait = false end
        draw_main(t)
    end
    U.draw_toasts(t)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

vana.events.on('load', function ()
    load_settings()
    configure_search()
    ensure_bind()
    vana.log('auctionhouse-vanacore ' .. addon.version .. ' loaded; search server ' .. tostring(st.search_where))
end)

vana.events.on('unload', function ()
    save_settings()
    SEARCH.cancel_all()
    I.release_icons()
    U.release_textures()
end)

vana.events.on('present', function ()
    local ok, err = pcall(tick)
    if not ok then fail('present', err) end
end)

vana.events.on('packet_in', function (e)
    if e.id == PKT.inc then
        local ok, block = pcall(on_packet, e)
        if not ok then fail('packet', block)
        elseif block then e.blocked = true return true end
    elseif e.id == 0x017 and (st.sales_wait or clock() - st.sales_at < 2) then
        -- the server's AH pagination module narrates the sales list in chat; the window shows it instead
        local d = bytes_of(e)
        if d and (d:find('items listed for sale', 1, true) or d:find('No results for page', 1, true) or d:find('Current page:', 1, true)) then
            e.blocked = true
            return true
        end
    elseif e.id == 0x00B then
        -- zoning: the house's state is gone with the zone
        st.open = false
        st.sales, st.sales_open = {}, false
        st.lists = {}
        st.counter.near = false
    end
end)

vana.events.on('command', function (e)
    local words = {}
    for word in e.command:gmatch('%S+') do words[#words + 1] = word end
    local cmd = (words[1] or ''):lower()
    if cmd ~= '/ah' and cmd ~= '//ah' then return false end
    local what = (words[2] or ''):lower()
    if what == '' or what == 'toggle' then
        if st.open then st.open = false else open_window() end
    elseif what == 'show' then open_window()
    elseif what == 'hide' then st.open = false
    elseif what == 'buy' then open_window() st.tab = 'buy'
    elseif what == 'sell' then open_window() st.tab = 'sell'
    elseif what == 'sales' then open_window() st.tab = 'sales'
    elseif what == 'settings' then open_window() st.settings_open = true
    elseif what == 'search' and words[3] then
        open_window()
        st.tab = 'buy'
        st.query[1] = table.concat(words, ' ', 3)
        st.results, st.result_total = I.search(st.query[1], 80)
    elseif what == 'server' then
        local arg = words[3] or ''
        if arg == '' then say('Search server: ' .. tostring(st.search_where))
        elseif arg == 'auto' then settings.search_host, settings.search_port = '', 54002 save_settings() configure_search() say('Search server: ' .. st.search_where)
        else
            local host, port = arg:match('^([^:]+):?(%d*)$')
            settings.search_host = host or arg
            settings.search_port = tonumber(port) or 54002
            save_settings()
            configure_search()
            st.lists, st.hist = {}, {}
            say('Search server: ' .. st.search_where)
        end
    elseif what == 'pick' and words[3] then
        open_window()
        st.tab = 'buy'
        local id = tonumber(words[3])
        if id == nil then
            local hits = I.search(table.concat(words, ' ', 3), 1)
            id = hits[1]
        end
        if id and I.rows[id] then
            local cat = I.category_of(id)
            st.category, st.group = cat, I.group_of(cat).id
            st.group_open[st.group] = true
            fetch_list(cat)
            select_item(id)
        else
            say('No such item in the house')
        end
    elseif what == 'sellpick' and tonumber(words[3]) then
        open_window()
        st.tab = 'sell'
        refresh_inventory()
        for _, it in ipairs(st.inventory) do
            if it.id == tonumber(words[3]) then
                st.sell.slot, st.sell.item, st.sell.count, st.sell.stack = it.slot, it.id, it.count, false
                st.sell.price[1] = ''
                st.sell.fee, st.sell.asked = nil, nil
                fetch_history(it.id, false)
                if I.get(it.id).stack > 1 then fetch_history(it.id, true) end
                break
            end
        end
    elseif what == 'tab' and words[3] then
        open_window()
        local tab = words[3]:lower()
        if tab == 'buy' or tab == 'sell' or tab == 'sales' then st.tab = tab end
    elseif what == 'opacity' and tonumber(words[3]) then
        settings.opacity = math.max(40, math.min(100, tonumber(words[3]))) / 100 save_settings()
    elseif what == 'scale' and tonumber(words[3]) then
        settings.scale = math.max(50, math.min(300, tonumber(words[3]))) save_settings()
    elseif what == 'refresh' then
        st.lists, st.hist = {}, {}
        if st.open then fetch_list(st.category) if st.selected then select_item(st.selected) end end
    elseif what == 'debug' then
        say(string.format('in %d, out %d, search %s pending %d, counter %s (%s), zone ok %s, lists %d, gil %s',
            st.counts.pin, st.counts.pout, tostring(st.search_where), SEARCH.pending(), tostring(st.counter.near), tostring(st.counter.dist and string.format('%.1f', st.counter.dist)), tostring(st.zone_ok),
            (function () local n = 0 for _ in pairs(st.lists) do n = n + 1 end return n end)(), gil(st.gil)))
        say('last error: ' .. tostring(st.last_error))
    else
        say('/ah [show|hide|buy|sell|sales|search <name>|settings|server <host[:port]>|scale <percent>|refresh|debug]')
    end
    return true
end)
