--[[
    Auction House for VanaCore

    The auction house as its own window: browse every category with live stock, search by name, read an item's
    sale history and buy from its card; sell from your bag with the fee shown before you commit; see and cancel what
    you have up. It speaks the game's own auction packets (0x04E / 0x04C) for buying, selling and your sales, and asks
    the search server directly, the way the game does, for categories, stock and history. Nothing server-side.

    /ah opens it. Talk to an auction clerk, as you would: whatever the clerk is called, in a city or an outpost, the
    server answers with the house's Open packet, and that is what lets you bid and sell (and where you stood is kept,
    so /ah there later can trade as well).
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
local PRICES = require('prices')
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

-- how far from a spot the house was opened at it still serves you (yalms), how long fetched lists and histories stay fresh (s),
-- how often the sales list may be asked for (the server says 5 s), how long to wait on the server before saying so
local LIMITS = { counter = 8, list = 90, history = 45, sales = 5.5, reply = 6, scan = 0.5, inventory = 2, retry = 8 }

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
    watch_at = 0, watch_state = {}, watch_buf = {}, sold = {}, hist_fail = {},
}

local settings = {
    scale = 100, opacity = 1.0, keybind = '^A', confirm_buy = true, near_counter = true, take_over = true, spots = {}, search_host = '', search_port = 54002,
    sort = 'name', in_stock = false, remember = {},
    chart = true, watch = {}, watch_poll = true, watch_every = 300, theme = 'aurora', usable = false,
}

local function copy(v)
    if type(v) ~= 'table' then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end
local DEFAULTS = copy(settings) -- what a character with no settings file starts from

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

-- your own entity: at your party slot's index (0x400 is only the first player who entered the zone, not you)
local function me()
    local okp, party = pcall(vana.game.party)
    local m = okp and type(party) == 'table' and type(party.members) == 'table' and party.members[1] or nil
    if m == nil or m.target_index == nil or m.target_index == 0 then return nil end
    local ok, e = pcall(vana.game.entity, m.target_index)
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

-- the character's own settings (read again when the character changes, or when its name is first known)
local function load_settings()
    for k in pairs(settings) do settings[k] = nil end
    for k, v in pairs(DEFAULTS) do settings[k] = copy(v) end
    st.settings_for = my_name()
    local path = settings_file()
    if not vana.fs.exists(path) then
        -- a first run: sized for the screen, since 100% is tiny on a 4K or Retina one
        local ok, _, sh = pcall(vana.ui.screen)
        if ok and type(sh) == 'number' and sh > 0 then
            settings.scale = math.max(100, math.min(250, math.floor(sh / 1080 * 10 + 0.5) * 10))
        end
        return
    end
    local ok, chunk = pcall(loadfile, path)
    if ok and chunk then
        local ok2, data = pcall(chunk)
        if ok2 and type(data) == 'table' then
            for k, v in pairs(data) do settings[k] = v end
        end
    end
end

-- one of Party Finder's themes (or a themes\\<id>.lua of the player's own), kept with the settings
local function set_theme(id)
    local theme = U.apply_theme(id)
    settings.theme = theme.id
    save_settings()
    return theme
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
    -- the price log is per server: what sells on the test server says nothing about live
    PRICES.save(true)
    PRICES.load(settings_dir() .. '\\prices-' .. (host:gsub('[^%w%.%-]', '_')) .. '.lua')
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
local remember_spot -- the same, with the counter below

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
        -- a clerk was talked to (or a GM's !ah): this is the house's own word that you may trade here
        st.zone_ok = true
        st.server_opened = true
        pcall(remember_spot)
        st.counter.at = 0 -- look again next frame, should the window be up already
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
            -- (the game says it in chat too: "You buy the ... for ... gil")
            U.toast('ok', 'Bought ' .. I.name(item), (qty > 1 and (qty .. ' for ') or '') .. gil(price) .. ' gil', 5, 'cart-shopping')
            forget_history(item)
            st.inv_at = 0 -- the gil changes a moment after this reply: read the bag again on the next frame or two
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

-------------------------------------------------------------------------------
-- The watch list: items you follow; their price and stock are checked, and you're told when they move
-------------------------------------------------------------------------------

local function watch_key(id, stack) return id .. '/' .. (stack and 1 or 0) end

local function watch_entry(id, stack)
    for i, e in ipairs(settings.watch) do
        if e.id == id and (e.stack or false) == (stack or false) then return e, i end
    end
    return nil
end

-- after a history reply for a watched item: an alert when it sold under your price, or came back in stock
local function check_watch(item, stack)
    local e = watch_entry(item, stack)
    if e == nil then return end
    local key = watch_key(item, stack)
    local hs = st.hist[key]
    if hs == nil then return end
    local state = st.watch_state[key]
    local name = I.name(item) .. (stack and ' (stack)' or '')
    local last = hs.stats and hs.stats.last or nil
    if state ~= nil then
        if e.under and last and last <= e.under and state.last ~= last then
            U.toast('ok', 'Price alert', name .. ' sold for ' .. gil(last) .. ', under your ' .. gil(e.under), 8, 'bell')
        end
        if (hs.stock or 0) > 0 and (state.stock or 0) == 0 then
            U.toast('info', 'Back in stock', name .. ': ' .. hs.stock .. ' up now', 6, 'box-open')
        end
    end
    st.watch_state[key] = { last = last, stock = hs.stock or 0, at = clock() }
end

local function fetch_list(cat, force)
    local have = st.lists[cat]
    if not force and have and clock() - have.at < LIMITS.list then return end
    if st.fetching['cat' .. cat] then return end
    -- after a failure, not again for a few seconds (rows on screen ask for their category's list every frame)
    if st.hist_fail['cat' .. cat] and clock() - st.hist_fail['cat' .. cat] < LIMITS.retry then return end
    st.fetching['cat' .. cat] = clock()
    SEARCH.list(cat, function (r, err)
        st.fetching['cat' .. cat] = nil
        if r == nil then fail('list', err) st.search_error = err st.hist_fail['cat' .. cat] = clock() return end
        st.hist_fail['cat' .. cat] = nil
        st.search_error = nil
        local items = {}
        -- the server sends -1 (0xFFFFFFFF) as the stack count of anything that doesn't stack: that is none, not many
        for _, it in ipairs(r.items) do items[it.id] = { single = it.single < 0x80000000 and it.single or 0, stack = it.stack < 0x80000000 and it.stack or 0 } end
        st.lists[cat] = { items = items, at = clock(), total = r.total }
        st.list_at = clock()
    end)
end

local function fetch_history(item, stack, force)
    local key = item .. '/' .. (stack and 1 or 0)
    local have = st.hist[key]
    if not force and have and clock() - have.at < LIMITS.history then return end
    if st.fetching[key] then return end
    -- after a failure, not again for a few seconds: an unreachable server would otherwise be asked every frame
    if st.hist_fail[key] and clock() - st.hist_fail[key] < LIMITS.retry then return end
    st.fetching[key] = clock()
    SEARCH.history(item, stack, function (r, err)
        st.fetching[key] = nil
        if r == nil then fail('history', err) st.search_error = err st.hist_fail[key] = clock() return end
        st.hist_fail[key] = nil
        st.search_error = nil
        table.sort(r.sales, function (a, b) return a.date > b.date end)
        local prices = {}
        for _, sale in ipairs(r.sales) do prices[#prices + 1] = sale.price end
        table.sort(prices)
        local stats = nil
        if #prices > 0 then
            local mid = math.floor((#prices + 1) / 2)
            stats = { n = #prices, low = prices[1], high = prices[#prices], median = #prices % 2 == 1 and prices[mid] or math.floor((prices[mid] + prices[mid + 1]) / 2), last = r.sales[1].price }
            -- the trend: the newest three sales against the ones before them, by their medians so that one odd sale
            -- (a stack sold for ten times the rest) doesn't swing it
            if #r.sales >= 4 then
                local function median(list)
                    table.sort(list)
                    local m = math.floor((#list + 1) / 2)
                    return #list % 2 == 1 and list[m] or (list[m] + list[m + 1]) / 2
                end
                local recent, older = {}, {}
                for i, sale in ipairs(r.sales) do
                    if i <= 3 then recent[#recent + 1] = sale.price else older[#older + 1] = sale.price end
                end
                local a, b = median(recent), median(older)
                if b > 0 then stats.trend = (a - b) / b end
            end
        end
        if r.stock >= 0x80000000 then r.stock = 0 end -- -1: doesn't stack
        st.hist[key] = { sales = r.sales, stock = r.stock, category = r.category, stats = stats, at = clock() }
        PRICES.add(item, stack, r.sales)
        check_watch(item, stack)
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
    local list = cat and st.lists[cat]
    local row = list and list.items[item]
    if row then return row.single, row.stack, true end
    -- the search server lists only what is up: once the category's list is in, an item missing from it has nothing up
    if list then return 0, 0, true end
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

-- search results span categories, and a category's list is where its stock comes from: the first few are asked for
local function fetch_result_lists()
    local seen, n = {}, 0
    for _, id in ipairs(st.results or {}) do
        local cat = I.category_of(id)
        if cat and not seen[cat] then
            seen[cat], n = true, n + 1
            fetch_list(cat)
            if n >= 6 then break end
        end
    end
end

-- who would wear it: your main job and its level (your party slot) and your race (your entity), read once a second
local function wearer()
    local w = st.wearer
    if w and clock() - w.at < 1 then return w end
    local okp, party = pcall(vana.game.party)
    local m = okp and type(party) == 'table' and type(party.members) == 'table' and party.members[1] or nil
    local e = me()
    w = { job = m and m.main_job or 0, level = m and m.main_job_level or 0, race = e and e.race or 0, at = clock() }
    st.wearer = w
    return w
end

-- whether you can wear it as you are: gear (it names jobs) for your main job, at or under your level, and for your race.
-- The game's own masks: jobs bit n for job n, races bit n for race n (1 Hume male ... 8 Galka; 0x1FE all of them)
local function can_equip(id)
    local r = I.get(id)
    if r.missing or (r.jobs or 0) == 0 then return false end
    local w = wearer()
    if w.job == 0 then return false end
    if bit.band(r.jobs, bit.lshift(1, w.job)) == 0 then return false end
    if (r.level or 0) > w.level then return false end
    if w.race > 0 and (r.races or 0) ~= 0 and bit.band(r.races, bit.lshift(1, w.race)) == 0 then return false end
    return true
end

-------------------------------------------------------------------------------
-- Where you are: the counter, the zone
--
-- No NPC names: clerks are called many things (Auction Counter in the cities, people in Jeuno, Rabao, Norg,
-- Tavnazia, Nashmau and the rest), but talking to any of them makes the server send 0x04C Open. Each time it does,
-- the spot you stand on is kept for that zone, and being within a few yalms of a kept spot is being at the counter.
-------------------------------------------------------------------------------

local function here()
    local e = me()
    if e == nil or type(e.x) ~= 'number' then return nil, nil end
    local okp, party = pcall(vana.game.party)
    local m = okp and type(party) == 'table' and type(party.members) == 'table' and party.members[1] or nil
    return e, m and tonumber(m.zone) or nil
end

remember_spot = function ()
    local e, zone = here()
    if e == nil or zone == nil then return end
    if type(settings.spots) ~= 'table' then settings.spots = {} end
    local list = type(settings.spots[zone]) == 'table' and settings.spots[zone] or {}
    local near = LIMITS.counter / 2
    for _, p in ipairs(list) do
        local dx, dy, dz = p[1] - e.x, p[2] - e.y, p[3] - e.z
        if dx * dx + dy * dy + dz * dz <= near * near then return end -- known already
    end
    if #list >= 16 then table.remove(list, 1) end
    local r = function (v) return math.floor(v * 10 + 0.5) / 10 end
    list[#list + 1] = { r(e.x), r(e.y), r(e.z) }
    settings.spots[zone] = list
    save_settings()
end

local function scan_counter()
    st.counter.at = clock()
    local e, zone = here()
    local list = e and zone and type(settings.spots) == 'table' and settings.spots[zone] or nil
    local best = nil
    if type(list) == 'table' then
        for _, p in ipairs(list) do
            local dx, dy, dz = p[1] - e.x, p[2] - e.y, p[3] - e.z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if best == nil or d < best then best = d end
        end
    end
    st.counter.dist = best
    -- where you are can't be read: the server's word alone
    if e == nil then st.counter.near = st.server_opened == true return end
    st.counter.near = best ~= nil and best <= LIMITS.counter
end

local function may_trade()
    return (not settings.near_counter) or st.counter.near
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------

local function do_buy(item, price, stack)
    if not may_trade() then say('Talk to an auction clerk to buy.') return end
    if price <= 0 then return end
    if price > 999999999 then U.toast('danger', 'Too high', 'The house takes bids up to 999,999,999 gil', 4, 'ban') return end
    if price > st.gil then U.toast('danger', 'Not enough gil', 'You have ' .. gil(st.gil) .. ' gil', 4, 'coins') return end
    st.buy.pending = { item = item, price = price, stack = stack, at = clock() }
    send_bid(item, price, stack)
end

local function do_ask(slot, item, price, stack)
    if not may_trade() then say('Talk to an auction clerk to sell.') return end
    if price > 999999999 then U.toast('danger', 'Too high', 'The house takes prices up to 999,999,999 gil', 4, 'ban') return end
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
    if not may_trade() then say('Talk to an auction clerk.') return end
    st.cancel_pending = slot
    st.cancel_at = clock()
    send_cancel(slot)
end

-- follow an item (singles or stacks), or stop
local function toggle_watch(id, stack)
    stack = stack or false
    local e, i = watch_entry(id, stack)
    if e then
        table.remove(settings.watch, i)
        st.watch_state[watch_key(id, stack)] = nil
        U.toast('dim', 'No longer watching', I.name(id) .. (stack and ' (stacks)' or ''), 3, 'star')
    else
        settings.watch[#settings.watch + 1] = { id = id, stack = stack, added = os.time() }
        fetch_history(id, stack)
        U.toast('ok', 'Watching', I.name(id) .. (stack and ' (stacks)' or '') .. '  ·  its price and stock are on the Watch tab', 4, 'star')
    end
    save_settings()
end

-- one of your listings sold (the server's AH announcement module says so, by the item's server name, the buyer and the
-- price): a notice, the sale marked on the My Sales tab, and the price kept on the item's record
local function on_sold(name, buyer, price)
    -- which listing: one of yours. The server names the item by its internal name (underscores as spaces), which can
    -- differ from the name the game shows, so your listings are matched by price first, then by name
    local lname = name:lower()
    local row = nil
    for _, r in pairs(st.sales) do
        if r.price == price and (row == nil or I.name(r.id):lower() == lname) then row = r end
    end
    if row == nil then
        for _, r in pairs(st.sales) do
            if I.name(r.id):lower() == lname then row = r break end
        end
    end
    local id = row and row.id or nil
    if id == nil then
        for _, cand in ipairs(I.search(name, 8)) do
            if I.name(cand):lower() == lname then id = cand break end
        end
    end
    local stack = row and row.stack or false
    -- the sales list is only ever what's still up: the sold one leaves it on the next refresh, so it's remembered here
    table.insert(st.sold, 1, { id = id, name = name, stack = stack, price = price, buyer = buyer, at = os.time() })
    while #st.sold > 10 do table.remove(st.sold) end
    if row then st.sales[row.slot + 1] = nil end
    st.sales_dirty = true
    -- the price record gets the sale from the house's own history, with its time (recording it here too would count it
    -- twice)
    if id then
        forget_history(id)
        fetch_history(id, stack, true)
    end
    local what = id and I.name(id) or name
    U.toast('ok', 'Sold!', what .. (stack and ' (stack)' or '') .. '  ·  ' .. gil(price) .. ' gil from ' .. buyer, 8, 'sack-dollar')
end

-- ask the house about every watched item
local function poll_watch()
    st.watch_at = clock()
    for _, e in ipairs(settings.watch) do fetch_history(e.id, e.stack, true) end
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
            -- spec is the bind as written ('^A'); key is only the letter ('A')
            local key = type(b) == 'table' and (b.spec or b[1]) or nil
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

-- A text box that shows it has the keyboard. The game draws at the screen's full resolution, so ImGui's own caret
-- is one physical pixel and all but vanishes on a Retina or 4K screen, and its active frame is barely lighter than
-- its idle one. This adds a gold ring with a soft glow while typing, a lighter edge on hover, a caret of a few pixels
-- that blinks (and holds still while you type), a dimmer placeholder so a hint never looks like a value, and, for
-- prices, the whole number selected on click so typing replaces it. Enter in a price box does what its button does
-- (asks the fee; a bid goes to its confirmation, never straight through).
-- ImGui keeps the real caret position to itself; ours sits at the end of the text, which is where it is after a click
-- that selects all, or after typing. Once the caret could have moved elsewhere (arrows, Home/End, a click inside the
-- box), ours steps aside and ImGui's, now gold, carries on.
-- ImGui 1.92's numbers (its input flags were renumbered in 1.91: AutoSelectAll is 1 << 12 now)
local FIELD = { CharsDecimal = 1, AutoSelectAll = 4096, InputTextCursor = 33, TextDisabled = 1, TextSelectedBg = 53, active_frame = -10 }
local field_state = {}
local function field(id, hint, buf, width, size, numeric)
    local im = imgui
    local fs = field_state[id]
    if fs == nil then fs = { trust = false, last = buf[1] or '', edit_at = 0 } field_state[id] = fs end
    im.SetNextItemWidth(width)
    im.PushStyleColor(FIELD.InputTextCursor, U.rgba(GOLD))
    im.PushStyleColor(FIELD.TextDisabled, U.rgba(P.faint))
    im.PushStyleColor(FIELD.TextSelectedBg, U.rgba(GOLD, 0.28))
    local changed, caret_x
    local ok, err = pcall(with_font, F.text, size, function ()
        changed = im.InputTextWithHint(id, hint, buf, numeric and 10 or 48, numeric and (FIELD.CharsDecimal + FIELD.AutoSelectAll) or 0)
        caret_x = im.CalcTextSize(buf[1] or '')
    end)
    im.PopStyleColor(3)
    if not ok then error(err, 0) end
    local x0, y0 = im.GetItemRectMin()
    local w, h = im.GetItemRectSize()
    local dl = im.GetWindowDrawList()
    local active, hovered = im.IsItemActive(), im.IsItemHovered()
    local now = clock()
    local text_now = buf[1] or ''
    if im.IsItemActivated() then
        -- a price is selected whole by the click, so the caret is at its end; an empty box has it there too
        fs.trust = numeric or text_now == ''
        fs.edit_at = now
    elseif active then
        for _, k in ipairs({ 513, 514, 519, 520 }) do -- Left, Right, Home, End
            if im.IsKeyPressed(k) then fs.trust = false end
        end
        if im.IsMouseClicked(0) and hovered then fs.trust = false end
    end
    if text_now ~= fs.last then
        fs.last, fs.edit_at = text_now, now
        -- typing at the end keeps the caret there (the box doesn't scroll for a number this short)
    end
    local r = S(9)
    if active then
        for i = 3, 1, -1 do
            local g = S(2) * i
            dl:AddRect({ x0 - g, y0 - g }, { x0 + w + g, y0 + h + g }, u32(GOLD, 0.07 * (4 - i)), r + g, 0, S(2))
        end
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(GOLD, 0.9), r, 0, math.max(1, S(1.5)))
        if fs.trust then
            local since = now - fs.edit_at
            if since < 0.5 or (since % 1.0) < 0.55 then
                local cx = x0 + S(12) + (tonumber(caret_x) or 0) + 1
                local fh = S(size)
                local cy = y0 + (h - fh) / 2
                dl:AddRectFilled({ cx, cy }, { cx + math.max(2, S(2)), cy + fh }, u32(GOLD, 0.95), 1)
            end
        end
    elseif hovered then
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(P.accent, 0.45), r, 0, math.max(1, S(1)))
        im.SetMouseCursor(1) -- the text beam
    else
        dl:AddRect({ x0, y0 }, { x0 + w, y0 + h }, u32(P.line, 0.9), r, 0, 1)
    end
    -- Enter leaves the box; tell the caller, so a price can go straight on to its button
    local submitted = im.IsItemDeactivated() and (im.IsKeyPressed(525) or im.IsKeyPressed(627))
    -- Esc in a box only leaves the box: the window's own Esc stands down while a box had the keyboard a frame ago
    if active then FIELD.active_frame = im.GetFrameCount() end
    return changed, active, submitted
end

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
    U.aurora(dl, x, y, w, h + S(24), t, S(16))
    glass_gil(dl, x + S(44), y + S(42), S(46), t, 1)
    U.gradient_text(dl, x + S(82), y + S(16), 'AUCTION HOUSE', GOLD, P.accent2, F.dispb, T.title)
    local where
    if not logged_in() then where = 'Not logged in'
    elseif st.counter.near then where = 'At the counter'
    elseif st.counter.dist then where = string.format('Counter %.0f yalms away', st.counter.dist)
    else where = 'Talk to an auction clerk to trade' end
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

-- a filter chip: a pill that's on or off, its icon and label; returns pressed and its width
local function chip_width(label)
    return S(22) + S(12) + S(6) + measure(label, F.disp, T.tiny)
end
local function filter_chip(dl, key, fx, fy, label, on, color, tip, icon_on, icon_off)
    local gs, ch = S(12), S(24)
    local lw = measure(label, F.disp, T.tiny)
    local cw = chip_width(label)
    imgui.SetCursorScreenPos({ fx, fy })
    local pressed, hovered, hv = hit(key, cw, ch)
    if hovered and tip then with_font(F.text, T.small, imgui.SetTooltip, tip) end
    if on then
        dl:AddRectFilled({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.28), S(9))
        dl:AddRect({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.95), S(9), 15, 1)
    else
        dl:AddRectFilled({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.05 + 0.1 * hv), S(9))
        dl:AddRect({ fx, fy }, { fx + cw, fy + ch }, u32(color, 0.22 + 0.4 * hv), S(9), 15, 1)
    end
    local fg = on and color or mix(color, P.dim, 0.45)
    icon(dl, fx + S(11) + gs / 2, fy + ch / 2, on and icon_on or icon_off, fg, T.tiny, on and 1 or 0.55 + 0.45 * hv) -- (a font size: icon() scales it)
    text_center(dl, fx + S(11) + gs + S(6), fy + ch / 2, lw, label, fg, F.disp, T.tiny)
    return pressed, cw
end

local function draw_tabs(dl, x, y, w)
    local h = S(40)
    local tabs = { { 'buy', 'BUY', 'cart-shopping' }, { 'sell', 'SELL', 'tag' }, { 'sales', 'MY SALES', 'receipt' }, { 'watch', 'WATCH', 'star' } }
    local tx = x + S(24)
    for _, tab in ipairs(tabs) do
        local on = st.tab == tab[1]
        local lw = measure(tab[2], F.disp, T.body)
        local count = tab[1] == 'watch' and #settings.watch > 0 and tostring(#settings.watch) or nil
        local cw = count and (measure(count, F.disp, T.tiny) + S(20)) or 0
        local tw = lw + S(44) + cw
        imgui.SetCursorScreenPos({ tx, y })
        local pressed, _, hv = hit('##tab' .. tab[1], tw, h)
        if pressed then st.tab = tab[1] end
        local col = on and GOLD or mix(P.dim, P.text, hv)
        icon(dl, tx + S(14), y + h / 2, tab[3], col, T.small)
        text_mid(dl, tx + S(30), y + h / 2, tab[2], col, F.disp, T.body)
        if count then pill(dl, tx + S(30) + lw + S(6), y + h / 2 - S(9), count, mix(col, P.ink, 0.75), col, F.disp, T.tiny, S(7)) end
        if on then
            dl:AddRectFilledMultiColor({ tx + S(4), y + h - S(4) }, { tx + tw - S(8), y + h - S(2) }, u32(GOLD, 0.2), u32(GOLD, 1), u32(P.accent2, 1), u32(P.accent2, 0.2))
        end
        tx = tx + tw + S(6)
    end
    -- the search box, on the buy tab, and the list's filters beside it (they filter search results too)
    if st.tab == 'buy' then
        local sw = S(300)
        local sx = x + w - S(24) - sw
        local fy = y + (h - S(24)) / 2
        local cx = sx - S(12) - chip_width('USABLE')
        local wr = wearer()
        local who = wr.job > 0 and ((U.JOBS[wr.job] or '?') .. wr.level) or 'you'
        local tip = settings.usable and ('Showing only gear your ' .. who .. ' can wear') or ('Show only gear your ' .. who .. ' can wear (job, level and race)')
        if filter_chip(dl, '##usable', cx, fy, 'USABLE', settings.usable, GOLD, tip, 'user-check', 'user') then
            settings.usable = not settings.usable
            save_settings()
        end
        cx = cx - S(8) - chip_width('IN STOCK')
        tip = settings.in_stock and 'Showing only what is up for sale' or 'Show only what is up for sale'
        if filter_chip(dl, '##instock', cx, fy, 'IN STOCK', settings.in_stock, P.ok, tip, 'square-check', 'filter') then
            settings.in_stock = not settings.in_stock
            save_settings()
        end
        imgui.SetCursorScreenPos({ sx, y + S(4) })
        local changed = field('##ahsearch', 'Search every item by name', st.query, sw, T.small, false)
        if changed then
            local q = st.query[1] or ''
            if #q >= 2 then st.results, st.result_total = I.search(q, 80) fetch_result_lists() else st.results = nil end
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
    -- a search result from a category not fetched yet: its list carries the stock (only rows on screen are drawn)
    local cat = I.category_of(id)
    if cat and st.lists[cat] == nil then fetch_list(cat) end
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = hit(key, w, h)
    local selected = st.selected == id
    local r = I.get(id)
    panel(dl, x, y, w, h, selected and P.card_hi or P.card, (selected and 1 or 0.9 + 0.1 * hv) * alpha, S(10), selected and GOLD or (hv > 0.01 and mix(P.line, P.accent, hv) or nil), selected)
    U.draw_ripples(dl, key, x, y, w, h, GOLD)
    item_icon(dl, id, x + S(10), y + S(8), S(40), alpha)
    local name = fit(r.name, F.disp, T.h2, w - S(250))
    -- gear you can wear as you are shows yellow; gear you can't, dimmed; anything else as it was
    local ncol = P.text
    if (r.jobs or 0) ~= 0 then ncol = can_equip(id) and mix(P.text, GOLD, 0.75) or mix(P.text, P.dim, 0.6) end
    text(dl, x + S(60), y + S(8), name, selected and GOLD or ncol, F.disp, T.h2, alpha)
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
        if selected then select_item(nil) else select_item(id) end
    end
    if hovered and imgui.IsMouseDoubleClicked(0) and not selected then select_item(id) end
    return h
end

-- each sort's own way round: names A to Z, level and stock highest first; clicking the sort again turns it round
local SORT_DESC = { name = false, level = true, stock = true }
local function sort_desc()
    if settings.sort_desc ~= nil then return settings.sort_desc == true end
    return SORT_DESC[settings.sort or 'name'] == true
end

local function draw_list(dl, x, y, w, h, t)
    local ids, title
    if st.results then
        ids, title = st.results, 'SEARCH  ·  ' .. #st.results .. (st.result_total > #st.results and (' of ' .. st.result_total) or '') .. ' results'
    else
        ids = I.category(st.category)
        title = (I.CATEGORY_NAME[st.category] or ''):upper() .. '  ·  ' .. #ids .. ' items'
    end
    -- the sort, for a category and for search results alike (NAME A to Z keeps a search's best matches first, and a
    -- category comes A to Z already); ties go A to Z by name
    do
        local desc = sort_desc()
        local function by(value)
            local copy = {}
            for i, id in ipairs(ids) do copy[i] = id end
            table.sort(copy, function (a, b)
                local va, vb = value(a), value(b)
                if va ~= vb then if desc then return va > vb else return va < vb end end
                local na, nb = I.name(a), I.name(b)
                if na ~= nb then return na < nb end
                return a < b
            end)
            ids = copy
        end
        if settings.sort == 'level' then
            by(function (id) return I.get(id).level or 0 end)
        elseif settings.sort == 'stock' then
            by(function (id) local s1, s2 = stock_of(id) return (s1 or 0) + (s2 or 0) end)
        elseif desc then
            by(function (id) return I.name(id) end)
        end
    end
    -- the filters: what's up right now (an item whose stock isn't known yet stays until it is), and what you can wear
    local total = #ids
    if settings.in_stock then
        local keep = {}
        for _, id in ipairs(ids) do
            local single, stack = stock_of(id)
            if (single == nil and stack == nil) or (single or 0) + (stack or 0) > 0 then keep[#keep + 1] = id end
        end
        ids = keep
    end
    if settings.usable then
        local keep = {}
        for _, id in ipairs(ids) do if can_equip(id) then keep[#keep + 1] = id end end
        ids = keep
    end
    local hidden = total - #ids
    if settings.in_stock or settings.usable then
        local what = settings.in_stock and settings.usable and 'usable, in stock' or settings.usable and 'usable' or 'in stock'
        if st.results then
            title = 'SEARCH  ·  ' .. #ids .. ' ' .. what
        else
            title = (I.CATEGORY_NAME[st.category] or ''):upper() .. '  ·  ' .. #ids .. ' ' .. what .. ' of ' .. total
        end
    end
    -- the sort, at the right; the title and the fetching note keep to the room left of it
    local current, desc = settings.sort or 'name', sort_desc()
    local WAYS = { name = { 'A to Z', 'Z to A' }, level = { 'lowest first', 'highest first' }, stock = { 'fewest first', 'most first' } }
    local sorts = {}
    for _, s in ipairs({ { 'name', 'NAME' }, { 'level', 'LEVEL' }, { 'stock', 'STOCK' } }) do
        local on = s[1] == current
        local d = SORT_DESC[s[1]] -- (not `on and desc or …`: a false desc would fall through to the default)
        if on then d = desc end
        local way = WAYS[s[1]]
        sorts[#sorts + 1] = { s[1], s[2],
            -- a small triangle: which way round, bright on the sort in use, faint on the others
            glyph = function (gdl, gx, gy, gs, a)
                local hw, hh = gs * 0.24, gs * 0.2
                local col = u32(on and P.accent or P.dim, on and 1 or 0.35 + 0.4 * (a - 0.55) / 0.45)
                if d then gdl:AddTriangleFilled({ gx - hw, gy - hh }, { gx + hw, gy - hh }, { gx, gy + hh }, col)
                else gdl:AddTriangleFilled({ gx - hw, gy + hh }, { gx + hw, gy + hh }, { gx, gy - hh }, col) end
            end,
            tip = on and ('Sorted ' .. way[d and 2 or 1] .. '; click for ' .. way[d and 1 or 2]) or ('Sort ' .. way[d and 2 or 1]) }
    end
    local gs = S(24) - S(8)
    local sw = 0
    for _, s in ipairs(sorts) do sw = sw + measure(s[2], F.disp, T.tiny) + S(22) + gs + S(6) + S(5) end
    local room = w - sw - S(12) - S(6)
    title = fit(title, F.disp, T.small, room)
    text(dl, x + S(6), y, title, P.dim, F.disp, T.small)
    -- the stock is still coming: said after the title, shorter or not at all when the line is full
    if st.fetching['cat' .. st.category] and st.results == nil then
        local left = room - measure(title, F.disp, T.small) - S(10)
        local note = nil
        if measure('fetching stock…', F.text, T.tiny) <= left then note = 'fetching stock…'
        elseif measure('fetching…', F.text, T.tiny) <= left then note = 'fetching…' end
        if note then text(dl, x + S(6) + measure(title, F.disp, T.small) + S(10), y + S(2), note, P.cyan, F.text, T.tiny) end
    end
    local _, _, clicked = U.segments(dl, '##sort', x + w - sw, y - S(6), S(24), sorts, current, nil, F.disp, T.tiny)
    if clicked == current then
        settings.sort_desc = not desc
        save_settings()
    elseif clicked then
        settings.sort, settings.sort_desc = clicked, SORT_DESC[clicked]
        save_settings()
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
        local why = hidden == 0 and (st.results and 'Nothing by that name' or 'Nothing here')
            or (settings.in_stock and settings.usable and 'Nothing up that you can wear')
            or (settings.usable and 'Nothing here you can wear') or 'Nothing in stock'
        text_center(cdl, x, ly + S(60), w, why, P.dim, F.disp, T.h1)
        if hidden > 0 then text_center(cdl, x, ly + S(90), w, hidden .. (hidden == 1 and ' item is' or ' items are') .. ' hidden by ' .. (settings.in_stock and settings.usable and 'the filters' or settings.usable and 'the Usable filter' or 'the In stock filter'), P.faint, F.text, T.small) end
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
    -- the star: follow this item (single or stack, whichever is picked) on the watch tab
    local watched = watch_entry(id, st.stack) ~= nil
    if icon_button(dl, '##star', x + w - S(44), y + S(10), S(28), 'star', watched and GOLD or P.dim, watched and 'Stop watching' or ('Watch this item' .. (r.stack > 1 and (st.stack and ' (stacks)' or ' (singles)') or ''))) then
        toggle_watch(id, st.stack)
    end
    text(dl, cx + S(68), cy, fit(r.name, F.disp, T.h1, w - S(130)), GOLD, F.disp, T.h1)
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
    -- gone after a purchase or a sale (it changed): asked for again (fetch_history waits out a failure)
    if hs == nil then fetch_history(id, st.stack) end
    text(dl, cx, cy, 'RECENT SALES', P.accent, F.disp, T.small)
    if st.fetching[id .. '/' .. (st.stack and 1 or 0)] then text(dl, x + w - S(48) - measure('fetching…', F.text, T.tiny), cy + S(2), 'fetching…', P.cyan, F.text, T.tiny) end
    if icon_button(dl, '##chart_toggle', x + w - S(42), cy - S(5), S(24), 'chart-line', settings.chart and P.cyan or P.faint, settings.chart and 'Hide the price graph' or 'Show the price graph') then
        settings.chart = not settings.chart save_settings()
    end
    local hy = cy
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
            -- shown up on the header line, beside the graph toggle
            icon(dl, x + w - S(56), hy + S(7), flat and 'minus' or (up and 'arrow-trend-up' or 'arrow-trend-down'), tcol, T.small)
            text(dl, x + w - S(68) - measure(tl, F.semi, T.tiny), hy + S(2), tl, tcol, F.semi, T.tiny)
        end
        cy = cy + S(38)
        -- the graph: every sale this character has seen, not only the house's last ten
        if settings.chart then
            local series = PRICES.series(id, st.stack)
            -- leaves room for at least three rows of sales under it
            local gh = math.max(S(64), math.min(S(112), bottom - cy - S(8) - S(19) * 3))
            panel(dl, cx, cy, w - S(32), gh, P.well, 0.6, S(8))
            PRICES.chart(dl, cx + S(4), cy + S(4), w - S(40), gh - S(8), series, { color = P.cyan, median = s.median, key = '##chart' .. id })
            local n = #series
            local note = n .. (n == 1 and ' sale' or ' sales') .. ' on record'
            text(dl, x + w - S(20) - measure(note, F.text, T.tiny - 1), cy + S(6), note, P.faint, F.text, T.tiny - 1)
            cy = cy + gh + S(8)
        end
        -- the rows: price, when, who, in an area of their own that scrolls (with the graph shown, ten don't fit)
        local rows_h = bottom - cy
        if rows_h > S(18) then
            imgui.SetCursorScreenPos({ cx, cy })
            imgui.BeginChild('##hist_rows', { w - S(24), rows_h }, false, 0)
            local cdl = imgui.GetWindowDrawList()
            local ry = cy - imgui.GetScrollY()
            for i, sale in ipairs(hs.sales) do
                text(cdl, cx, ry, gil(sale.price), i == 1 and GOLD or P.text, F.semi, T.small)
                text(cdl, cx + S(96), ry, ago(sale.date), P.dim, F.text, T.small)
                local who = fit(sale.seller .. ' → ' .. sale.buyer, F.text, T.tiny, w - S(190))
                text(cdl, x + w - S(16) - measure(who, F.text, T.tiny), ry + S(2), who, P.faint, F.text, T.tiny)
                ry = ry + S(19)
            end
            imgui.SetCursorScreenPos({ cx, ry })
            imgui.Dummy({ 1, 1 })
            imgui.EndChild()
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
    local _, _, entered = field('##bid', hs and hs.stats and ('last sold ' .. tostring(hs.stats.last)) or 'gil', st.buy.price, w - S(32) - S(110), T.body, true)
    local price = tonumber(st.buy.price[1]) or (hs and hs.stats and hs.stats.last) or 0
    local can = may_trade() and price > 0 and logged_in() and st.buy.pending == nil
    local label = st.buy.pending and 'Bidding…' or 'Bid'
    if entered and can and settings.confirm_buy then st.confirm = { kind = 'buy', item = id, price = price, stack = st.stack } end
    if button(dl, '##bid_btn', x + w - S(16) - S(104), by, S(104), S(34), label, can and GOLD or P.faint, can and 'solid' or 'ghost', 'gavel') and can then
        if settings.confirm_buy then
            st.confirm = { kind = 'buy', item = id, price = price, stack = st.stack }
        else
            do_buy(id, price, st.stack)
        end
    end
    if not may_trade() then
        text(dl, cx, by + S(40), 'Talk to an auction clerk to bid', P.warn, F.text, T.tiny)
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
    local edited, _, entered = field('##ask', hs and hs.stats and ('type a price · last sold ' .. tostring(hs.stats.last)) or 'type a price in gil', st.sell.price, pw - S(32), T.body, true)
    if edited then st.sell.fee, st.sell.asked = nil, nil end
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
        if (button(dl, '##ask_btn', sx, sy, pw - S(32), S(36), st.sell.pending and 'Asking…' or 'Ask the fee', can and P.accent or P.faint, can and 'solid' or 'ghost', 'receipt') or entered) and can then
            do_ask(st.sell.slot, id, price, st.sell.stack)
        end
    end
    if not may_trade() then text(dl, sx, sy + S(44), 'Talk to an auction clerk to sell', P.warn, F.text, T.tiny) end
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
    if #rows == 0 and #st.sold == 0 then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(30), w, st.sales_open and 'Nothing up for sale' or 'Ask the house', P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(54), w, st.sales_open and 'Sell something from your bag' or (may_trade() and 'Refresh lists what you have up' or 'Talk to an auction clerk'), P.dim, F.text, T.small)
        return
    end
    for _, row in ipairs(rows) do
        local rh = S(60)
        panel(dl, x + S(4), cy, w - S(8), rh, P.card, 0.95, S(10))
        item_icon(dl, row.id, x + S(14), cy + S(8), S(44), 1)
        local r = I.get(row.id)
        text(dl, x + S(68), cy + S(8), r.name .. (row.stack and ('  ·  stack of ' .. r.stack) or ''), P.text, F.disp, T.h2)
        local pl = gil(row.price) .. ' gil'
        text(dl, x + w - S(150) - measure(pl, F.disp, T.h2), cy + S(10), pl, GOLD, F.disp, T.h2)
        text(dl, x + S(68), cy + S(34), 'Slot ' .. (row.slot + 1) .. (row.at and row.at > 0 and ('  ·  listed ' .. ago(row.at)) or ''), P.dim, F.text, T.tiny)
        local can = may_trade() and st.cancel_pending == nil
        if button(dl, '##cancel' .. row.slot, x + w - S(130), cy + S(14), S(116), S(32), 'Take down', can and P.danger or P.faint, 'ghost', 'xmark', F.semi, T.small) and can then
            st.confirm = { kind = 'cancel', slot = row.slot, item = row.id }
        end
        cy = cy + rh + S(8)
    end
    -- what sold while you were on (the server's announcement), newest first
    if #st.sold > 0 then
        cy = cy + S(8)
        text(dl, x + S(6), cy, 'SOLD WHILE YOU WERE ON  ·  the gil is in your delivery box', P.ok, F.disp, T.small)
        cy = cy + S(24)
        for i, s in ipairs(st.sold) do
            local rh = S(48)
            if cy + rh > y + h - S(24) then break end
            panel(dl, x + S(4), cy, w - S(8), rh, P.card, 0.8, S(10))
            if s.id then item_icon(dl, s.id, x + S(14), cy + S(6), S(36), 1) end
            local what = s.id and I.name(s.id) or s.name
            text(dl, x + S(60), cy + S(6), what .. (s.stack and ('  ·  stack') or ''), P.text, F.disp, T.body)
            text(dl, x + S(60), cy + S(28), 'to ' .. s.buyer .. '  ·  ' .. ago(s.at), P.dim, F.text, T.tiny)
            local pl = gil(s.price) .. ' gil'
            text(dl, x + w - S(20) - measure(pl, F.disp, T.h2), cy + S(12), pl, P.ok, F.disp, T.h2)
            cy = cy + rh + S(6)
        end
    end
    text(dl, x + S(6), cy + S(4), 'Sold items pay out to your delivery box; the house holds unsold ones until you take them down.', P.faint, F.text, T.tiny)
end

-- WATCH: the items you follow, each with its stock, last price, how it moved, a sparkline, and a price to be told at
local function draw_watch(dl, x, y, w, h, t)
    local list = settings.watch
    text(dl, x + S(6), y, 'WATCHING  ·  ' .. #list .. (#list == 1 and ' item' or ' items'), P.dim, F.disp, T.small)
    local checked = st.watch_at > 0 and ('checked ' .. ago(os.time() - math.floor(clock() - st.watch_at))) or (settings.watch_poll and 'checks every ' .. math.floor((settings.watch_every or 300) / 60) .. ' min' or 'background checks are off')
    text(dl, x + w - S(142) - measure(checked, F.text, T.tiny), y + S(3), checked, P.faint, F.text, T.tiny)
    local busy = SEARCH.pending() > 0
    if button(dl, '##watch_refresh', x + w - S(130), y - S(6), S(124), S(26), busy and 'Asking…' or 'Check now', busy and P.faint or P.accent, 'ghost', 'rotate-right', F.semi, T.tiny) and not busy and #list > 0 then
        poll_watch()
    end
    local ly, lh = y + S(32), h - S(32)
    if #list == 0 then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(30), w, 'Nothing watched yet', P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(54), w, "Star an item on its card: its stock, price and trend show here, and you're told when it sells under your price", P.dim, F.text, T.small)
        return
    end
    -- their histories stay fresh while this is open
    for _, e in ipairs(list) do fetch_history(e.id, e.stack) end
    imgui.SetCursorScreenPos({ x, ly })
    imgui.BeginChild('##watch', { w, lh }, false, 0)
    local cdl = imgui.GetWindowDrawList()
    local cy = ly - imgui.GetScrollY()
    local remove = nil
    for i, e in ipairs(list) do
        local rh = S(78)
        local id, key = e.id, watch_key(e.id, e.stack)
        local r = I.get(id)
        local hs = st.hist[key]
        local series = PRICES.series(id, e.stack)
        panel(cdl, x + S(4), cy, w - S(12), rh, P.card, 0.95, S(10))
        -- the name takes you to its card
        imgui.SetCursorScreenPos({ x + S(4), cy })
        local pressed, hovered, hv = hit('##w' .. key, S(300), rh)
        if pressed then
            local cat = I.category_of(id)
            if cat then st.category, st.group = cat, I.group_of(cat).id st.group_open[st.group] = true fetch_list(cat) end
            st.tab = 'buy'
            st.stack = e.stack or false
            st.results = nil
            select_item(id)
        end
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, 'Open its card') end
        if hv > 0 then cdl:AddRectFilled({ x + S(4), cy }, { x + S(304), cy + rh }, u32(P.card_hi, 0.6 * hv), S(10)) end
        item_icon(cdl, id, x + S(14), cy + S(15), S(48), 1)
        local line = I.jobs_line(id)
        if line == '' then line = I.CATEGORY_NAME[I.category_of(id) or 0] or '' end
        text(cdl, x + S(72), cy + S(10), fit(r.name .. (e.stack and ('  ·  stack of ' .. r.stack) or ''), F.disp, T.h2, S(222)), mix(P.text, GOLD, hv), F.disp, T.h2)
        text(cdl, x + S(72), cy + S(34), fit(line, F.text, T.tiny, S(222)), P.dim, F.text, T.tiny)
        stock_pills(cdl, x + S(72), cy + S(52), id, 1, false)
        -- the sparkline: the last thirty sales on record
        local sx = x + S(314)
        PRICES.spark(cdl, sx, cy + S(16), S(150), S(46), series, P.cyan, 30)
        -- the last price, the median, and how it moved over a week (from the record) or lately (from the house)
        local px = sx + S(166)
        if hs and hs.stats then
            local s = hs.stats
            local pl = gil(s.last)
            text(cdl, px, cy + S(12), pl, GOLD, F.disp, T.h2)
            local change, label, tcol = PRICES.change(series, 7 * 86400), nil, nil
            if change then
                label = string.format('%s%.0f%% in 7d', change > 0 and '+' or '', change * 100)
                tcol = math.abs(change) <= 0.02 and P.dim or (change > 0 and P.danger or P.ok)
            elseif s.trend then
                label = math.abs(s.trend) <= 0.02 and 'steady' or string.format('%s%.0f%% lately', s.trend > 0 and '+' or '', s.trend * 100)
                tcol = math.abs(s.trend) <= 0.02 and P.dim or (s.trend > 0 and P.danger or P.ok)
            end
            if label then pill(cdl, px + measure(pl, F.disp, T.h2) + S(10), cy + S(13), label, mix(tcol, P.ink, 0.78), tcol, F.disp, T.tiny, S(7)) end
            text(cdl, px, cy + S(40), 'median ' .. gil(s.median) .. '  ·  sold ' .. ago(hs.sales[1].date), P.dim, F.text, T.tiny)
            text(cdl, px, cy + S(56), #series .. (#series == 1 and ' sale' or ' sales') .. ' on record', P.faint, F.text, T.tiny - 1)
        elseif hs then
            text(cdl, px, cy + S(14), 'No ' .. (e.stack and 'stacks' or 'singles') .. ' sold lately', P.dim, F.text, T.small)
        else
            text(cdl, px, cy + S(14), st.fetching[key] and 'Asking the house…' or (st.search_error and 'Search server: ' .. tostring(st.search_error) or '—'), st.search_error and P.danger or P.faint, F.text, T.small)
        end
        -- the price to be told at
        local ax = x + w - S(8) - S(40) - S(100)
        icon(cdl, ax + S(6), cy + S(16), 'bell', e.under and P.warn or P.faint, T.tiny)
        text(cdl, ax + S(16), cy + S(10), 'TELL ME UNDER', e.under and P.warn or P.faint, F.disp, T.tiny - 1)
        local buf = st.watch_buf[key]
        if buf == nil then buf = { e.under and tostring(e.under) or '' } st.watch_buf[key] = buf end
        imgui.SetCursorScreenPos({ ax, cy + S(28) })
        local changed = field('##under' .. key, 'any price', buf, S(100), T.small, true)
        if changed then
            local v = tonumber(buf[1])
            e.under = (v and v > 0) and math.floor(v) or nil
            save_settings()
        end
        if icon_button(cdl, '##unwatch' .. key, x + w - S(42), cy + S(25), S(28), 'xmark', P.dim, 'Stop watching') then remove = i end
        cy = cy + rh + S(8)
    end
    text(cdl, x + S(6), cy + S(2), (settings.watch_poll and 'Checked every ' .. math.floor((settings.watch_every or 300) / 60) .. ' minutes while you play, house open or not' or 'Background checks are off (settings)') .. '  ·  a sale under your price, or stock coming back, shows as a notice', P.faint, F.text, T.tiny)
    imgui.SetCursorScreenPos({ x, cy + S(22) })
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
    if remove then toggle_watch(list[remove].id, list[remove].stack) end
end

local function draw_settings(dl, x, y, w, h)
    panel(dl, x, y, w, h, P.glass, 0.98, S(14), P.accent2, true)
    local cx, cy = x + S(20), y + S(16)
    icon(dl, cx + S(8), cy + S(10), 'sliders', P.accent2, T.body)
    text(dl, cx + S(26), cy, 'SETTINGS', P.accent2, F.disp, T.h2)
    -- the theme, in the right-hand column: Party Finder's palettes, by the same names
    do
        local rx, ry = x + math.floor(w * 0.58), y + S(52)
        text(dl, rx, ry, 'THEME', P.dim, F.disp, T.small)
        local opts = {}
        for _, th in ipairs(U.THEMES) do opts[#opts + 1] = { id = th.id, name = th.name } end
        local current = settings.theme or 'aurora'
        local picked = U.dropdown(dl, '##ah_theme', rx, ry + S(40), S(170), opts, current)
        if picked ~= current then set_theme(picked) end
        local th = U.THEME_BY_ID[settings.theme or 'aurora'] or U.THEMES[1]
        for i, k in ipairs({ 'accent', 'accent2', 'cyan', 'card_hi' }) do
            dl:AddCircleFilled({ rx + S(170) + S(20) + (i - 1) * S(16), ry + S(40) }, S(6), u32(th.palette[k] or P[k]), 16)
        end
        text(dl, rx, ry + S(64), "The same themes as Party Finder  ·  /ah theme <name>", P.faint, F.text, T.tiny)
    end
    if icon_button(dl, '##settings_close', x + w - S(44), y + S(10), S(28), 'xmark', P.dim, 'Close') then st.settings_open = false end
    cy = cy + S(36)
    local changed = false
    local v, ch
    v, ch = U.toggle(dl, '##t_counter', cx, cy + S(10), 'Bid and sell only at an auction clerk', settings.near_counter) settings.near_counter = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_takeover', cx, cy + S(10), "Talking to a clerk opens this, not the game's menu", settings.take_over) settings.take_over = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_confirm', cx, cy + S(10), 'Confirm before bidding', settings.confirm_buy) settings.confirm_buy = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_chart', cx, cy + S(10), "Price graph on an item's card", settings.chart) settings.chart = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_watch', cx, cy + S(10), 'Check watched items every ' .. math.floor((settings.watch_every or 300) / 60) .. ' min, even with this closed', settings.watch_poll) settings.watch_poll = v changed = changed or ch
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
    local open = { st.open }
    if imgui.Begin('##auctionhouse', open, U.WINDOW_FLAGS) then
        -- drawn under pcall so an error can't skip End and the theme's pop: an unbalanced ImGui stack takes the game down
        local drew, err = pcall(function ()
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
        elseif st.tab == 'watch' then
            draw_watch(dl, x + S(16), by, w - S(32), bh, t)
        else
            draw_sales(dl, x + S(16), by, w - S(32), bh, t)
        end
        -- RootAndChildWindows (3): the lists, the bag and the sidebar are child windows, and a click there focuses them
        if imgui.IsWindowFocused(3) and imgui.IsKeyPressed(U.KEY_ESCAPE) and imgui.GetFrameCount() - FIELD.active_frame > 1 then
            if st.confirm then st.confirm = nil elseif st.settings_open then st.settings_open = false else st.open = false end
        end
        end)
        if not drew then fail('window', err) end
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
    PRICES.save()
    -- the watch list, checked in the background
    -- a character logged in (or switched to) since the settings were read: its own settings, search host and key
    local name = my_name()
    if name ~= '' and name ~= st.settings_for then
        load_settings()
        U.apply_theme(settings.theme or 'aurora')
        configure_search()
        ensure_bind()
    end
    if settings.watch_poll and #settings.watch > 0 and logged_in() and clock() - st.watch_at > (settings.watch_every or 300) then
        poll_watch()
    end
    -- replies that never came, noticed whether or not the window is open
    if st.buy.pending and clock() - st.buy.pending.at > LIMITS.reply then
        st.buy.pending = nil
        U.toast('danger', 'No answer', 'The house did not answer your bid', 5, 'hourglass-end')
    end
    if st.sell.pending and clock() - st.sell.at > LIMITS.reply then
        st.sell.pending = false
        U.toast('danger', 'No answer', 'The house did not answer', 5, 'hourglass-end')
    end
    if st.cancel_pending ~= nil and clock() - (st.cancel_at or 0) > LIMITS.reply then
        st.cancel_pending = nil
        U.toast('danger', 'No answer', 'The house did not answer the take-down: refresh My Sales to see where it stands', 6, 'hourglass-end')
    end
    if st.open then
        if clock() - st.counter.at > LIMITS.scan then scan_counter() end
        -- the bag and the gil, kept current (a purchase or a fee changes the gil a moment after the house replies)
        if clock() - st.inv_at > LIMITS.inventory then refresh_inventory() end
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
    U.load_theme_files()
    U.apply_theme(settings.theme or 'aurora')
    configure_search()
    ensure_bind()
    vana.log('auctionhouse-vanacore ' .. addon.version .. ' loaded; search server ' .. tostring(st.search_where))
end)

vana.events.on('unload', function ()
    save_settings()
    PRICES.save(true)
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
    elseif e.id == 0x017 then
        local d = bytes_of(e)
        local mes = d and d:sub(0x18) or ''
        local nul = mes:find('\0', 1, true)
        if nul then mes = mes:sub(1, nul - 1) end
        -- the server's AH announcement module tells a seller who's online that an item sold (a system line)
        local name, buyer, price = mes:match("^Your '(.-)' has sold to (%S+) for (%d+) gil!")
        if name then
            local ok, err = pcall(on_sold, name, buyer, tonumber(price))
            if not ok then fail('sold', err) end
        elseif st.sales_wait or clock() - st.sales_at < 2 then
            -- the server's AH pagination module narrates the sales list in chat; the window shows it instead
            if mes:find('items listed for sale', 1, true) or mes:find('No results for page', 1, true) or mes:find('Current page:', 1, true) then
                e.blocked = true
                return true
            end
        end
    elseif e.id == 0x00B then
        -- zoning: the house's state is gone with the zone
        st.open = false
        st.sales, st.sales_open, st.sales_wait = {}, false, false
        st.cancel_pending = nil -- the server drops a take-down with the zone, without a reply
        st.lists = {}
        st.counter.near = false
        st.server_opened = false
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
        fetch_result_lists()
    elseif what == 'server' then
        local arg = words[3] or ''
        if arg == '' then say('Search server: ' .. tostring(st.search_where))
        elseif arg == 'auto' then
            settings.search_host, settings.search_port = '', 54002
            save_settings()
            configure_search()
            st.lists, st.hist = {}, {} -- the old server's stock and sales
            say('Search server: ' .. st.search_where)
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
        if tab == 'buy' or tab == 'sell' or tab == 'sales' or tab == 'watch' then st.tab = tab end
    elseif what == 'watch' then
        if words[3] == nil then
            open_window()
            st.tab = 'watch'
        else
            local id = tonumber(words[3])
            if id == nil then
                local hits = I.search(table.concat(words, ' ', 3), 1)
                id = hits[1]
            end
            if id and I.rows[id] then toggle_watch(id, false) else say('No such item in the house') end
        end
    elseif what == 'theme' then
        local id = (words[3] or ''):lower()
        if U.THEME_BY_ID[id] then
            set_theme(id)
            say('Theme: ' .. U.THEME_BY_ID[id].name)
        else
            local names = {}
            for _, th in ipairs(U.THEMES) do names[#names + 1] = th.id end
            say('Themes: ' .. table.concat(names, ', '))
        end
    elseif what == 'opacity' and tonumber(words[3]) then
        settings.opacity = math.max(40, math.min(100, tonumber(words[3]))) / 100 save_settings()
    elseif what == 'scale' and tonumber(words[3]) then
        settings.scale = math.max(50, math.min(300, tonumber(words[3]))) save_settings()
    elseif what == 'refresh' then
        st.lists, st.hist = {}, {}
        if st.open then fetch_list(st.category) if st.selected then select_item(st.selected) end end
    elseif what == 'debug' then
        scan_counter() -- measured now, not when the window last looked
        say(string.format('in %d, out %d, search %s pending %d, counter %s (%s), zone ok %s, lists %d, gil %s',
            st.counts.pin, st.counts.pout, tostring(st.search_where), SEARCH.pending(), tostring(st.counter.near), tostring(st.counter.dist and string.format('%.1f', st.counter.dist)), tostring(st.zone_ok),
            (function () local n = 0 for _ in pairs(st.lists) do n = n + 1 end return n end)(), gil(st.gil)))
        say('last error: ' .. tostring(st.last_error))
        say('bid box: "' .. tostring(st.buy.price[1]) .. '"  query: "' .. tostring(st.query[1]) .. '"')
        -- keys ImGui believes are held: a stuck one (a key-up the game never saw) makes text boxes misbehave
        local held = {}
        for k = 512, 670 do if imgui.IsKeyDown(k) then held[#held + 1] = k end end
        say('keys ImGui holds down: ' .. (#held > 0 and table.concat(held, ', ') or 'none'))
        local ids = I.category(st.category)
        local zero, unknown, up, listed = 0, 0, 0, 0
        for _, id in ipairs(ids) do
            local s1, s2 = stock_of(id)
            if s1 == nil and s2 == nil then unknown = unknown + 1 elseif (s1 or 0) + (s2 or 0) > 0 then up = up + 1 else zero = zero + 1 end
        end
        if st.lists[st.category] then for _ in pairs(st.lists[st.category].items) do listed = listed + 1 end end
        say(string.format('category %d: %d items, %d up, %d known zero, %d unknown, %d rows in the list reply, in_stock %s', st.category, #ids, up, zero, unknown, listed, tostring(settings.in_stock)))
    else
        say('/ah [show|hide|buy|sell|sales|watch [<id or name>]|search <name>|pick <id or name>|settings|theme <name>|server <host[:port]|auto>|scale <percent>|opacity <percent>|refresh|debug]')
    end
    return true
end)
