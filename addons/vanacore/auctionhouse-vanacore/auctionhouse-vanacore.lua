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
addon.version = '1.1'
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
local LEDGER = require('ledger')
local COMPARE = require('compare')
local PAD = require('pad')
local LANG = require('lang') -- the window's language (English, or Japanese on a Japanese client; Hando's strings)
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
local LIMITS = { counter = 5.5, list = 90, history = 45, sales = 5.5, reply = 6, scan = 0.5, inventory = 2, retry = 8 }

-------------------------------------------------------------------------------
-- State and settings
-------------------------------------------------------------------------------

local st = {
    open = false, tab = 'buy', group = 'armor', category = 17, selected = nil, stack = false,
    query = { '' }, results = nil, result_total = 0,
    lists = {}, hist = {}, fetching = {},
    counter = { near = false, dist = nil, at = 0 }, zone_ok = nil, work_at = 0,
    sales = {}, sales_at = 0, sales_open = false, sales_wait = false, -- rows keyed (page - 1) * 6 + slot + 1
    sweep = nil, server_page = nil, page_n = nil, reply_page = nil, sales_total = nil, -- the server's pages (its ah_pagination module)
    sell = { slot = nil, stack = false, price = { '' }, fee = nil, asked = nil, pending = false, at = 0 },
    buy = { price = { '' }, pending = nil },
    inventory = {}, inv_at = 0, gil = 0,
    main = nil, settings_open = false, confirm = nil, last_error = nil, counts = { pin = 0, pout = 0 },
    anim = {}, list_at = 0, opened_at = 0, group_open = {}, hover = {},
    watch_at = 0, watch_state = {}, watch_buf = {}, hist_fail = {},
    act_filter = 'all', act_page = 1,
}

local settings = {
    scale = 100, opacity = 1.0, keybind = '^A', confirm_buy = true, take_over = true, spots = {}, search_host = '', search_port = 54002,
    sort = 'name', in_stock = false, remember = {},
    chart = true, watch = {}, watch_poll = true, watch_every = 300, theme = 'aurora', usable = false, compare = false,
    sellable_only = false, -- the Sell tab hides what the house won't take
    open_sound = true, open_sound_id = 'small_bell', -- a bell as the window opens (sounds\<id>.wav)
    view_anywhere = false, -- the window opens away from a counter too (browsing; bids and sales still need one)
    language = 'auto', -- 'auto' (the client's), 'en' or 'ja'
    sell_view = 'grid', -- the Sell tab's bag: 'grid' (icons) or 'list' (rows with names)
    icon = 'cat', -- the header's badge: 'cat' (images\badge_cat.png) or 'coin' (the glass gil, drawn)
}

-- the bells the window can open with, in sounds\: the first is the default
local OPEN_SOUNDS = {
    { id = 'small_bell', name = 'Small bell' }, { id = 'counter_bell', name = 'Counter bell' },
    { id = 'door_chime', name = 'Door chime' }, { id = 'chapel_bell', name = 'Chapel bell' },
    { id = 'crystal_chime', name = 'Crystal chime' }, { id = 'tiny_bell', name = 'Tiny bell' },
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
local function ledger_file() return settings_dir() .. '\\' .. (my_name() ~= '' and my_name() or 'default') .. '-activity.lua' end

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
    LEDGER.load(ledger_file()) -- the character's activity, beside its settings
    st.act_page = 1
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

-- the language setting applied: lang.lua decides again, the fonts are chosen again (a Japanese face when wanted),
-- and the item names and descriptions are read again in the new language
local function apply_language()
    LANG.set(settings.language or 'auto')
    U.fonts().want_japanese = LANG.ja()
    U.reload_fonts()
    I.forget_records()
    st.said_no_jp_font = nil
end

-- a small flag for the language in use: Japan's, or the Stars and Stripes for English
local function draw_flag(dl, x, y, w, h, lang)
    local r = S(3)
    if lang == 'ja' then
        dl:AddRectFilled({ x, y }, { x + w, y + h }, U.u32('#F4F4F4'), r)
        dl:AddCircleFilled({ x + w / 2, y + h / 2 }, h * 0.3, U.u32('#BC002D'), 24)
    else
        dl:AddRectFilled({ x, y }, { x + w, y + h }, U.u32('#F4F4F4'), r)
        local sh = h / 13
        for i = 0, 12, 2 do dl:AddRectFilled({ x, y + i * sh }, { x + w, y + (i + 1) * sh }, U.u32('#B22234')) end
        dl:AddRectFilled({ x, y }, { x + w * 0.4, y + sh * 7 }, U.u32('#3C3B6E'), r, 1)
        for row = 0, 2 do
            for col = 0, 2 do
                dl:AddCircleFilled({ x + w * 0.08 + col * w * 0.12, y + sh * 1.3 + row * sh * 2.2 }, math.max(1, h * 0.04), U.u32('#FFFFFF'), 6)
            end
        end
    end
    dl:AddRect({ x, y }, { x + w, y + h }, U.u32(P.line, 0.9), r, 15, 1)
end

-------------------------------------------------------------------------------
-- The search server: where it is
-------------------------------------------------------------------------------

-- the host VanaCore logged in to, from its own log ("Game start: on <host> (lobby ...)"): the search server lives there
-- the server this client logged in to. VanaCore's log is shared by every client started from this folder, so the
-- newest "Game start: on" line can be another client's (a test client on 127.0.0.1 beside a live one): the line
-- that counts is the one after "game process <this process's id> started". Only when that isn't in the log (an
-- older VanaCore, a log that rotated) is the newest line taken
local function own_pid()
    local ok, pid = pcall(function ()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'unsigned long GetCurrentProcessId(void);')
        return tonumber(ffi.C.GetCurrentProcessId())
    end)
    return ok and pid or nil
end

local function host_from_log()
    local path = vana.paths.install .. '\\logs\\vanacore.log'
    local f = io.open(path, 'rb')
    if f == nil then return nil end
    local all = f:read('*a') or ''
    f:close()
    local pid = own_pid()
    local mine, newest = nil, nil
    local ours = false
    for line in all:gmatch('[^\r\n]+') do
        local started = line:match('game process (%d+) started')
        if started then ours = pid ~= nil and tonumber(started) == pid end
        local h = line:match('Game start: on ([%w%.%-]+) %(')
        if h then
            newest = h
            if ours then mine = h ours = false end
        end
    end
    return mine or newest
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
    -- what the house lists is per server too: its last answers, asked again as the window is used
    I.load_index(settings_dir() .. '\\index-' .. (host:gsub('[^%w%.%-]', '_')) .. '.lua')
    st.sweep_wanted, st.sweep_tries = false, nil
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
local function send_sales() send(CMD.Info, -1) st.sales_at = clock() st.sales_wait = true st.reply_page = nil end

-- CatsEyeXI's server (its ah_pagination module) hands your listings out six to a page: each Info request shows the
-- next page (and says which in a chat line, "Current page: P of T. Showing n items."), past the last it says "No
-- results" and starts over at page 1, and it answers at most once every 1.5 s. A sweep asks again and again until
-- every page has been seen, so the window lists all of them; a take-down must be sent while the house is showing the
-- listing's page (the server cancels by the slot of the page it last showed), so a sweep can also be after one page.
local SWEEP_GAP = 1.6
local function sweep_send() st.sweep.got, st.sweep.started = nil, true send_sales() end
local function start_sweep(want)
    st.sweep = { seen = {}, want = want, steps = 0 }
    -- asked too soon after the last request, the house only says "wait": the tick sends once the gap has passed
    if clock() - st.sales_at >= SWEEP_GAP then sweep_send() end
end
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
    if st.reply_page == nil then
        -- no page line came before the rows: a server without pages, whose one list is all there is
        st.sales, st.reply_page, st.server_page = {}, 1, nil
    end
    local page = st.reply_page
    if st.sweep then st.sweep.got = true end
    local key = (page - 1) * 6 + slot + 1
    st.sales[key] = { key = key, page = page, slot = slot, id = item, stack = qty == 0, price = rd32(d, 0x2C), at = rd32(d, 0x38) }
end

-- a sweep has seen everything once a page comes round again, or once a short page (the last) has every page before
-- it seen too; a server without pages has one list, seen at once
local function sweep_complete(sw)
    if sw.done or st.server_page == nil then return true end
    if (st.page_n or 0) >= 6 then return false end
    for p = 1, st.server_page do if not sw.seen[p] then return false end end
    return true
end

-- a sweep's next move, once the page asked for has had its 1.6 s: the next page, the take-down, or the end
local function sweep_step()
    local sw = st.sweep
    if sw == nil then return end
    sw.steps = sw.steps + 1
    if not sw.got then
        -- nothing came of the last request (the house said wait, or nothing): ask again, up to the cap
        if sw.steps > 24 then st.sweep = nil st.sales_open = true else sweep_send() end
        return
    end
    if sw.want then
        local w = sw.want
        if st.server_page == w.page then
            local row = st.sales[w.key]
            st.sweep = nil
            if row and row.id == w.id and row.price == w.price then
                st.cancel_pending, st.cancel_at = w.key, clock()
                send_cancel(w.slot)
            else
                U.toast('warn', 'The list changed', 'That listing is not where it was; look again', 5, 'triangle-exclamation')
                st.sales_dirty = true
            end
            return
        elseif sweep_complete(sw) or sw.steps > 24 then
            st.sweep = nil
            U.toast('warn', "Couldn't reach that page", 'The house never showed it; refresh and try again', 5, 'triangle-exclamation')
            return
        end
    elseif sweep_complete(sw) or sw.steps > 24 then
        -- every page seen (or the last one, short): pages not seen this time are stale
        if st.server_page ~= nil then
            for key, row in pairs(st.sales) do if not sw.seen[row.page] then st.sales[key] = nil end end
        end
        st.sweep = nil
        st.sales_open = true
        return
    end
    send_sales()
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
            if st.sweep == nil then
                U.toast('warn', 'One moment', 'The house is still fetching your sales', 3, 'clock')
            else
                return true -- a sweep that asked too soon asks again after its gap; the game needn't print the wait
            end
        else
            -- the rows follow, after the page line when the server has pages (that line clears the page; without one
            -- the first row clears the lot)
            st.zone_ok = true
            st.sales_wait = false
            st.reply_page = nil
            if st.sweep == nil then st.sales_open = true end
        end
    elseif cmd == CMD.LotCancel and result == 0 and work >= 0 and (#d < 0x14 or u8(d, 0x14) ~= 0) and st.cancel_pending == nil then
        -- a sales-status row (the server lists them with this command)
        on_sales_slot(d)
    elseif cmd == CMD.LotCancel then
        if st.cancel_pending ~= nil and result == 0 then
            local row = st.sales[st.cancel_pending]
            local rl = st.relist
            if rl and rl.stage == 'cancel' and rl.key == st.cancel_pending then rl.stage, rl.at = 'bag', clock() end
            st.sales[st.cancel_pending] = nil
            st.cancel_pending = nil
            if not (rl and rl.stage == 'bag') then
                U.toast('ok', 'Taken down', row and (I.name(row.id) .. ' is back in your bag') or 'Returned to your bag', 4, 'box-open')
            end
            if row then LEDGER.add({ kind = 'taken', id = row.id, stack = row.stack, price = row.price }) end
            refresh_inventory()
            st.sales_dirty = true -- the house closes the gap: the pages are read again once the cooldown passes
        elseif st.cancel_pending ~= nil then
            st.cancel_pending = nil
            st.relist = nil -- still up at its old price
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
            if st.sell.confirm_on_fee and st.open then st.confirm = { kind = 'sell' } end
            st.sell.confirm_on_fee = nil
        else
            st.sell.confirm_on_fee = nil
            st.sell.fee, st.sell.asked = nil, nil
            U.toast('danger', "Can't sell that", 'The house refused it (used, locked, or not for auction)' .. (st.relist and ' (it is in your bag)' or ''), 5, 'ban')
            st.relist = nil
        end
    elseif cmd == CMD.LotIn then
        st.sell.pending = false
        if result == RESULT.Ok then
            local a = st.sell.asked
            U.toast('ok', 'Up for sale', a and (I.name(a.item) .. (a.stack and ' (stack)' or '') .. '  ·  ' .. gil(a.price) .. ' gil') or 'Listed', 5, 'tag')
            if a then
                forget_history(a.item)
                LEDGER.add({ kind = 'listed', id = a.item, stack = a.stack, price = a.price, fee = st.sell.fee })
            end
            st.sell.asked, st.sell.fee, st.sell.slot = nil, nil, nil
            st.relist = nil
            refresh_inventory()
            st.sales_dirty = true
        else
            U.toast('danger', "Couldn't list it", 'Not enough gil for the fee, the slots are full, or the item changed' .. (st.relist and ' (it is in your bag)' or ''), 6, 'triangle-exclamation')
            st.relist = nil
        end
    elseif cmd == CMD.Bid then
        local b = st.buy.pending
        st.buy.pending = nil
        local item, price, qty = u16(d, 0x0C), rd32(d, 0x08), rd32(d, 0x10)
        if result == RESULT.Ok then
            -- (the game says it in chat too: "You buy the ... for ... gil")
            U.toast('ok', 'Bought ' .. I.name(item), (qty > 1 and (qty .. ' for ') or '') .. gil(price) .. ' gil', 5, 'cart-shopping')
            LEDGER.add({ kind = 'bought', id = item, stack = qty > 1, price = price })
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
        -- the house's answer is the category's list (items.lua keeps it, per server)
        local ids = {}
        for _, it in ipairs(r.items) do ids[#ids + 1] = it.id end
        I.set_served(cat, ids)
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
    w = { job = m and m.main_job or 0, level = m and m.main_job_level or 0, sub = m and m.sub_job or 0,
          sub_level = m and m.sub_job_level or 0, race = e and e.race or 0, at = clock() }
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

-- whether you can learn the spell a scroll teaches, as you are: your main job at its level, or your sub job at its
-- level, has it (the server's own check when the scroll is used). nil for anything that isn't a spell's scroll
local SCROLL_CATS = { [28] = true, [29] = true, [30] = true, [31] = true, [32] = true }
local function can_learn(id)
    if not SCROLL_CATS[I.category_of(id) or 0] then return nil end
    local lv = I.scroll_levels(id)
    if lv == nil then return nil end
    local w = wearer()
    local function by(job, level)
        local need = lv[job]
        return job > 0 and need ~= nil and need >= 0 and need <= 99 and level >= need
    end
    return by(w.job, w.level) or by(w.sub or 0, w.sub_level or 0)
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

-- bidding, listing and taking down need you at a clerk, always: the server only checks that the zone has an auction
-- house, so this is what keeps trading at the counter, as the game's own window does (browsing works anywhere)
local function may_trade()
    return st.counter.near
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

-- take a listing down: straight away while the house is showing its page, else by turning the pages to it first
local function do_cancel(c)
    if not may_trade() then say('Talk to an auction clerk.') return end
    if st.server_page == nil or st.server_page == c.page then
        st.cancel_pending = c.key
        st.cancel_at = clock()
        send_cancel(c.slot)
    else
        U.toast('info', 'Finding that listing', 'The house shows a few at a time; a moment', 4, 'clock')
        start_sweep({ page = c.page, slot = c.slot, key = c.key, id = c.item, price = c.price })
    end
end

-- RELIST: a listing taken down and put up again at a new price. Each step waits on the house: the take-down (turning
-- its pages to the listing first when needed), the item back in the bag, the new fee quoted; then the usual listing
-- confirmation opens with that fee, and saying yes lists it. Stopped anywhere after the take-down, the item is in the bag
local function relist_end(why)
    if st.relist and why then U.toast('warn', LANG.t('Not relisted'), why, 6, 'box-open') end
    st.relist = nil
end

local function relist_step()
    local rl = st.relist
    if rl == nil then return end
    if rl.stage == 'cancel' then
        -- the take-down ended without coming down (refused, the page never shown, no clerk): its own notice said why
        if st.cancel_pending == nil and st.sweep == nil and clock() - rl.at > 2 then st.relist = nil end
    elseif rl.stage == 'bag' then
        -- the house sends the bag's change a moment after its reply: look until the item (a whole stack, for a stack) is in
        if clock() - (rl.look or 0) < 0.3 then return end
        rl.look = clock()
        refresh_inventory()
        local need = rl.stack and I.get(rl.id).stack or 1
        local slot = nil
        for _, it in ipairs(st.inventory) do
            if it.id == rl.id and it.count >= need then slot = it.slot break end
        end
        if slot then
            rl.stage, rl.at = 'quote', clock()
            st.sell.confirm_on_fee = true
            do_ask(slot, rl.id, rl.price, rl.stack)
            if not st.sell.pending then relist_end(LANG.t('It is in your bag; list it from the Sell tab')) end
        elseif clock() - rl.at > 8 then
            relist_end(LANG.t('It is in your bag; list it from the Sell tab'))
        end
    elseif rl.stage == 'quote' then
        -- the fee came (the confirmation is up) or didn't; once the confirmation is gone without a listing, it's over
        if st.confirm and st.confirm.kind == 'sell' then rl.stage = 'confirm'
        elseif not st.sell.pending then relist_end(LANG.t('It is in your bag; list it from the Sell tab')) end
    elseif rl.stage == 'confirm' then
        if st.confirm == nil and not st.sell.pending then relist_end(LANG.t('It is in your bag; list it from the Sell tab')) end
    end
end

-- the new prices offered for a listing: cuts off its price, and the market's median and last sale when they're under
-- it; one is suggested (the median when the listing is above it, else a small cut)
local function relist_options(price, hs)
    local opts = {}
    local function add(label, p, kind)
        p = math.floor(p)
        if p < 1 or p >= price then return end
        for _, o in ipairs(opts) do if o.price == p then return end end
        opts[#opts + 1] = { label = label, price = p, kind = kind }
    end
    for _, pc in ipairs({ 1, 5, 10, 20 }) do add('-' .. pc .. '%', price * (1 - pc / 100), 'cut') end
    local s_ = hs and hs.stats
    if s_ then
        add(LANG.t('Median'), s_.median, 'median')
        add(LANG.t('Last sale'), s_.last, 'last')
    end
    table.sort(opts, function (a, b) return a.price > b.price end)
    local suggest = nil
    for _, o in ipairs(opts) do
        if s_ and price > s_.median then
            if o.kind == 'median' then suggest = o end
        elseif o.label == ((s_ and price <= s_.median) and '-1%' or '-5%') then suggest = o end
    end
    return opts, suggest or opts[1]
end

-- follow an item (singles or stacks), or stop
local function is_watched(id, stack)
    for _, e in ipairs(settings.watch) do if e.id == id and (e.stack or false) == (stack or false) then return true end end
    return false
end

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
-- price): a notice, the listing gone from the Listings tab, the sale on the Activity tab, and the price kept on the
-- item's record
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
    -- the listings are only ever what's still up: the sold one leaves them, and the sale goes on the record
    LEDGER.add({ kind = 'sold', id = id, name = id == nil and name or nil, stack = stack, price = price, who = buyer })
    if row then st.sales[row.key] = nil end
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

-- the bell the window opens with (force: a preview, played with the sound switched off too)
local function play_open_sound(force)
    if not settings.open_sound and not force then return end
    local id = settings.open_sound_id or OPEN_SOUNDS[1].id
    local path = vana.paths.addon .. '\\sounds\\' .. id .. '.wav'
    if not vana.fs.exists(path) then path = vana.paths.addon .. '\\sounds\\' .. OPEN_SOUNDS[1].id .. '.wav' end
    if vana.fs.exists(path) then pcall(vana.system.play_sound, path) end
end

open_window = function ()
    -- as the game's own, unless View anywhere is on: only at an auction counter (within 5.5 yalms of where a clerk
    -- was talked to), and the window closes on walking away from it (tick)
    scan_counter()
    if not st.counter.near and not settings.view_anywhere then
        if not st.open then U.toast('danger', LANG.t('Talk to an auction clerk'), LANG.t("The house opens at its counter, as the game's own does"), 5, 'gavel') end
        return
    end
    if not st.open then play_open_sound() end -- (not again for /ah buy and the like on a window already open)
    st.open = true
    -- the controller's focus starts on the category in the sidebar (on a search's first result when one is up)
    st.pad_first, st.pad_first_id, st.pad_cats = 3, nil, st.results == nil
    st.opened_at = now_t -- ImGui's clock, the one the fade is measured against
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

-- the key that opens the house, changed or taken away (Settings, /ah bind): the old one unbound, the new one bound
local function set_keybind(spec)
    local old = settings.keybind or ''
    if old ~= '' then pcall(vana.chat.run, '/unbind ' .. old, 1) end
    settings.keybind = spec or ''
    save_settings()
    if settings.keybind ~= '' then pcall(vana.chat.run, '/bind ' .. settings.keybind .. ' /ah', 1) end
    st.bind_capture = nil
end
-- the next key pressed becomes the bind, with its modifiers in VanaCore's spelling (^ Ctrl, ! Alt, + Shift): a
-- digit, a letter or an F key; Esc keeps what there was
local function capture_keybind()
    if imgui.IsKeyPressed(U.KEY_ESCAPE) then st.bind_capture = nil return end
    local io = imgui.GetIO()
    for k = 536, 583 do
        if imgui.IsKeyPressed(k) then
            local name
            if k <= 545 then name = tostring(k - 536)
            elseif k <= 571 then name = string.char(65 + k - 546)
            else name = 'F' .. (k - 571) end
            set_keybind((io.KeyCtrl and '^' or '') .. (io.KeyAlt and '!' or '') .. (io.KeyShift and '+' or '') .. name)
            return
        end
    end
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
-- (the List button; a bid goes to its confirmation, never straight through).
-- ImGui keeps the real caret position to itself; ours sits at the end of the text, which is where it is after a click
-- that selects all, or after typing. Once the caret could have moved elsewhere (arrows, Home/End, a click inside the
-- box), ours steps aside and ImGui's, now gold, carries on.
-- ImGui 1.92's numbers (its input flags were renumbered in 1.91: AutoSelectAll is 1 << 12 now)
-- inside a list's child window: a stick scrolls it (ImGui's own stick scrolling is of the window with the focus, the
-- root, which doesn't scroll)
-- A list's edge under a controller: its first row holds Up and its last holds Down, so the ring stops there instead
-- of leaving for whatever ImGui finds past the list (it found the header's close button past the bottom). Called
-- just before the row is drawn, for the row that had the ring last frame; the focus is asked for again, which
-- replaces ImGui's move for this frame.
local function edge_seat(key, first, last)
    if not (first or last) or not PAD.shown() then return end
    local fo = U.anim.focus
    if fo == nil or fo.key ~= key or now_t - fo.at > 0.1 then return end
    local want = (first and PAD.down('up')) or (last and PAD.down('down'))
    if want then st.edge_hold = { key = key, at = now_t } end
    -- (and a moment past the release: the pad's read says up a frame before ImGui's last repeat of the press has
    -- landed, and that frame alone was enough to let the ring out)
    if want or (st.edge_hold and st.edge_hold.key == key and now_t - st.edge_hold.at < 0.15) then imgui.SetKeyboardFocusHere() end
end

-- A stick in the item list walks the ring through the rows, faster the further it's pushed, and the list follows
-- it. (Scrolling the list under a ring that stayed put left the ring on a row past the list's edge, drawn there as
-- a ghost, and nothing picked on the way.) Called inside the list's child; the row is seated once it's drawn.
-- a Listings row from the focus key of any of its three buttons
local function sales_row_key(k)
    return k:match('^##hist(.+)$') or k:match('^##relist(.+)$') or k:match('^##cancel(.+)$')
end
-- a Watch row from the focus key of its name, its price box or its cross
local function watch_row_key(k)
    return k:match('^##under(.+)$') or k:match('^##unwatch(.+)$') or k:match('^##w(.+)$')
end

local function stick_walk(n, key_of, scroll_to, stride, cur_of)
    if not PAD.capturing() then st.stick_acc, st.walk_i = nil, nil return end
    local _, ly, _, ry = PAD.stick()
    local v = ly ~= 0 and ly or ry
    if v == 0 or n == 0 then st.stick_acc, st.walk_i = nil, nil return end
    -- the walk keeps its own place while the stick is held: the focus lands a frame after each seat, and steering
    -- by where the ring was would chase it (and lose it when the ring's row is out of view)
    local cur = st.walk_i
    if cur == nil then
        local fo = U.anim.focus
        local fkey = fo and fo.key and now_t - fo.at < 0.1 and fo.key or nil
        if cur_of then cur = cur_of(fkey) -- (a row with several buttons: any of them is the row)
        elseif fkey then for i = 1, n do if key_of(i) == fkey then cur = i break end end end
    end
    if cur == nil then cur = v > 0 and (n + 1) or 0 end -- the ring isn't in the list: it comes in from the near end
    if cur > n + 1 then cur = n + 1 end
    if st.stick_acc == nil then st.stick_acc, st.stick_since = 1, now_t end -- the first row at once
    -- up to 14 rows a second, and three times that once the stick has been held a second and a half
    local rate = 14 * (1 + 2 * math.min(1, (now_t - (st.stick_since or now_t)) / 1.5))
    st.stick_acc = st.stick_acc + math.abs(v) * rate * dt
    local step = math.floor(st.stick_acc)
    if step < 1 then return end
    st.stick_acc = st.stick_acc - step
    step = step * (stride or 1) -- (a grid: a row of it at a time)
    local target = math.max(1, math.min(n, cur + (v > 0 and -step or step))) -- the stick up is up the list
    if target == cur then return end
    st.walk_i = target
    st.stick_seat_key = key_of(target) -- the row takes the focus when it's drawn
    if scroll_to then scroll_to(target) end -- a list that only draws rows in view scrolls the row into it first
end

local function pad_scroll()
    if not PAD.capturing() then return end
    local lx, ly, rx, ry = PAD.stick()
    local sy = ly ~= 0 and ly or ry
    if sy == 0 then return end
    imgui.SetScrollY(math.max(0, math.min(imgui.GetScrollMaxY(), imgui.GetScrollY() - sy * S(1100) * dt)))
end

local FIELD = { CharsDecimal = 1, AutoSelectAll = 4096, InputTextCursor = 33, TextDisabled = 1, TextSelectedBg = 53, active_frame = -10 }
local field_state = {}
-- A price box under a controller. A text box would open for typing, which a pad can't do, so while the pad is in use
-- and the box has the focus it is a digit editor of its own instead, worked as the game's own bid box is: Confirm
-- takes it with the ones digit lit, Left moves the light up the columns (one past the top digit is a new column, a
-- 0 to raise), Right brings it back down, Up and Down change the lit digit (carrying over, never below 0), Confirm
-- keeps the number and moves on to the box's button (Bid, or List), Cancel puts the old number back. ImGui's own
-- navigation still moves on a D-pad press (VanaCore feeds it), so the box takes the focus back each frame while it
-- is being edited.
local function pad_price_box(id, hint, buf, width, size, fs)
    local im = imgui
    local h = fs.h or (S(size) + S(12))
    -- (or sent here from its button: Left from Bid, Up from List; asked again each frame until it has taken)
    local seated = st.pad_seat == 'price' or st.pad_seat == id -- (by name: a Watch row's price box among many)
    if fs.pad_on or seated then im.SetKeyboardFocusHere() end
    local pressed = im.InvisibleButton(id, { width, h }, 8)
    local x0, y0 = im.GetItemRectMin()
    local dl = im.GetWindowDrawList()
    local focused = im.IsItemFocused()
    if seated then
        fs.seat_tries = (fs.seat_tries or 0) + 1
        if focused or fs.seat_tries > 6 then st.pad_seat, fs.seat_tries = nil, nil end
    end
    fs.focused = focused or seated
    -- sent here to edit at once (X on a Watch row): the editor opens as a press would
    if focused and st.pad_edit_now == id and not fs.pad_on then
        st.pad_edit_now = nil
        fs.pad_on, fs.orig, fs.col, fs.armed = true, buf[1] or '', 0, false
        buf[1] = ''
    end
    local changed = false
    local v = tonumber(buf[1]) or 0
    -- while editing, Confirm is read from the pad itself: the focus taken back each frame is a navigation request,
    -- and ImGui drops any activation while one is under way, so the box's own press never came and Confirm did nothing
    -- (only once the Confirm that opened the editor has been let go: the pad's press and ImGui's can land a frame apart)
    if fs.pad_on and not PAD.down('confirm') then fs.armed = true end
    local keep = fs.pad_on and fs.armed and PAD.pressed('confirm')
    if fs.pad_on and (pressed or keep) then
        fs.pad_on = false
        -- on to the box's button; a Watch row's price box goes back to its row
        if id == '##bid' then st.pad_seat = 'bid'
        elseif id == '##ask' then st.pad_seat = 'list'
        elseif id:sub(1, 7) == '##under' then st.stick_seat_key = '##w' .. id:sub(8) end
        -- the same press, still held, must not also press the button the focus moves to (or open the box again)
        st.pad_mute = 'held'
    elseif pressed and focused and not st.pad_mute then
        -- from 0, the ones lit, as the game's box starts (Cancel brings back what was there)
        fs.pad_on, fs.orig, fs.col, fs.armed = true, buf[1] or '', 0, false
        v, buf[1] = 0, ''
        changed = buf[1] ~= fs.orig
    end
    -- the bid box, not being edited: Up is the singles/stacks switch above it (for an item that stacks)
    if focused and not fs.pad_on and id == '##bid' and st.selected and I.get(st.selected).stack > 1 then
        st.pad_hold = true
        if PAD.pressed('up') then st.pad_seat = 'stack' end
    end
    -- and Left from it is the pane to its left: the list on the picked row, or the bag on the picked item
    if focused and not fs.pad_on and PAD.pressed('left') then
        if id == '##bid' then st.pad_first, st.pad_first_id, st.pad_cats = 3, st.selected, false
        elseif id == '##ask' and st.sell.slot then st.stick_seat_key = '##bag' .. st.sell.slot end
    end
    if fs.pad_on then
        st.pad_editing, st.pad_hold = true, 'all'
        local n = v > 0 and #tostring(v) or 0 -- digits the number has; columns past n are zeros in front
        local step = 10 ^ fs.col
        local nv = v
        if PAD.repeating('up') and v + step <= 999999999 then nv = v + step end
        if PAD.repeating('down') then nv = v >= step and v - step or 0 end
        if PAD.repeating('left') and fs.col < 8 then fs.col = fs.col + 1 end -- past the top digit: another zero, up to nine digits
        if PAD.repeating('right') then
            if fs.col > 0 then fs.col = fs.col - 1 else nv = 0 end -- Right at the ones clears the number
        end
        if PAD.pressed('cancel') then
            fs.pad_on = false
            nv = tonumber(fs.orig) or 0
            buf[1] = fs.orig
        end
        if nv ~= v then
            buf[1] = nv > 0 and tostring(nv) or ''
            changed, v = true, nv
        end
    end
    if focused or fs.pad_on then U.anim.focus = { x = x0, y = y0, w = width, h = h, at = now_t, key = id } end -- the ring
    -- the box, as the text box looks: a gold ring and glow while editing, the plain line otherwise
    local r = S(9)
    if fs.pad_on then
        for i = 3, 1, -1 do
            local g = S(2) * i
            dl:AddRect({ x0 - g, y0 - g }, { x0 + width + g, y0 + h + g }, u32(GOLD, 0.07 * (4 - i)), r + g, 0, S(2))
        end
        dl:AddRect({ x0, y0 }, { x0 + width, y0 + h }, u32(GOLD, 0.9), r, 0, math.max(1, S(1.5)))
    else
        dl:AddRect({ x0, y0 }, { x0 + width, y0 + h }, u32(P.line, 0.9), r, 0, 1)
    end
    local ty = y0 + h / 2
    if fs.pad_on then
        -- the digits one by one, right-aligned as the game's bid box is (the ones column stays put, new columns grow
        -- to the left), the lit one on a gold tab; a lit column in front of the number is a 0 to raise
        local s = v > 0 and tostring(v) or ''
        if fs.col >= #s then s = string.rep('0', fs.col - #s + 1) .. s end
        local n = #s
        local total = 0
        for i = 1, n do total = total + measure(s:sub(i, i), F.text, size) + S(1) end
        local tx = x0 + width - S(12) - total
        for i = 1, n do
            local ch = s:sub(i, i)
            local cw = measure(ch, F.text, size)
            if n - i == fs.col then
                dl:AddRectFilled({ tx - S(2), ty - S(size) / 2 - S(2) }, { tx + cw + S(2), ty + S(size) / 2 + S(2) }, u32(GOLD, 0.95), S(4))
                text_mid(dl, tx, ty, ch, P.ink, F.semi, size)
            else
                text_mid(dl, tx, ty, ch, P.text, F.text, size)
            end
            tx = tx + cw + S(1)
        end
    elseif (buf[1] or '') ~= '' then
        text_mid(dl, x0 + width - S(12) - measure(buf[1], F.text, size), ty, buf[1], P.text, F.text, size)
    else
        text_mid(dl, x0 + S(12), ty, hint or '', P.faint, F.text, size)
    end
    return changed, false, false
end

local function field(id, hint, buf, width, size, numeric, overlap)
    local im = imgui
    local fs = field_state[id]
    if fs == nil then fs = { trust = false, last = buf[1] or '', edit_at = 0 } field_state[id] = fs end
    if numeric and PAD.shown() and (fs.pad_on or fs.focused or st.pad_seat == 'price' or st.pad_seat == id) then return pad_price_box(id, hint, buf, width, size, fs) end
    im.SetNextItemWidth(width)
    -- a button laid over the box (the search box's clear) needs this to get the click: ImGui gives it to the first item
    if overlap then im.SetNextItemAllowOverlap() end
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
    fs.h, fs.focused = h, im.IsItemFocused() and not active -- for the controller's digit editor, should it take over
    -- a controller, with the box focused but not being typed in: up and down step the price (a tenth of its size,
    -- at least 10 gil); an empty box starts from the hint's last sale
    if numeric and im.IsItemFocused() and not active then
        st.pad_hold = true -- whoever is using it: up and down are the box's, not ImGui's
        local v = tonumber(buf[1]) or tonumber((hint or ''):match('%d+')) or 0
        local step = math.max(10, 10 ^ math.max(1, math.floor(math.log10(math.max(v, 1)))) / 10)
        local nv = v
        if PAD.repeating('up') then nv = v + step end
        if PAD.repeating('down') then nv = math.max(0, v - step) end
        if nv ~= v then
            nv = math.floor(nv / step + 0.5) * step
            buf[1] = nv > 0 and tostring(math.floor(nv)) or ''
            changed = true
        end
    end
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
    -- (text_center takes the middle, not the top: the G sits on the coin's centre, its shadow a touch below)
    text_center(dl, cx - cr, cy + ri * 0.04 + cr * 0.06, cr * 2, 'G', '#7A4C0C', F.dispb, cr * 1.15, alpha)
    text_center(dl, cx - cr, cy + ri * 0.04 + cr * 0.02, cr * 2, 'G', PALE, F.dispb, cr * 1.15, 0.9 * alpha)
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

-- the header's cat badge, loaded on first use (false once it couldn't be: not asked again every frame)
local function badge_texture()
    if st.badge_tex == nil then
        st.badge_tex = U.load_image('badge', vana.paths.addon .. '\\images\\badge_cat.png') or false
    end
    return st.badge_tex or nil
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

-- how many the picked choice is (a stack's size), on the icon's bottom-right corner, the way the game marks a stack
local function stack_badge(dl, x, y, size, n)
    if (n or 1) <= 1 then return end
    local label = 'x' .. n
    local tw = measure(label, F.bold, T.tiny)
    local bw, bh = tw + S(10), S(17)
    local bx, by = x + size - bw + S(4), y + size - bh + S(4)
    dl:AddRectFilled({ bx, by }, { bx + bw, by + bh }, u32(GOLD, 0.95), S(6))
    dl:AddRect({ bx, by }, { bx + bw, by + bh }, u32(P.ink, 0.6), S(6), 15, 1)
    text(dl, bx + S(5), by + S(1), label, P.ink, F.bold, T.tiny)
end

local function stock_pills(dl, x, y, id, alpha, right_align)
    local single, stack, fresh = stock_of(id)
    local r = I.get(id)
    local parts = {}
    if single ~= nil and single > 0 then parts[#parts + 1] = { single .. ' ' .. (single == 1 and LANG.t('single') or LANG.t('singles')), P.ok } end
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
    -- the aurora ends on the header's own line: bleeding 24 under it, its faint tail was cut off across the tab row
    -- as a step (the glow rings and grid clipped there), which some themes showed as a line behind the tabs
    U.aurora(dl, x, y, w, h, t, S(16))
    -- the badge: the cat with its coin (images\badge_cat.png, a texture loaded once), or the glass gil drawn
    local cat = settings.icon ~= 'coin' and badge_texture()
    if cat then
        local bs = S(60)
        dl:AddImage(cat, { x + S(44) - bs / 2, y + S(42) - bs / 2 }, { x + S(44) + bs / 2, y + S(42) + bs / 2 }, { 0, 0 }, { 1, 1 }, u32('#FFFFFF'))
    else
        glass_gil(dl, x + S(44), y + S(42), S(46), t, 1)
    end
    U.gradient_text(dl, x + S(82), y + S(16), 'AUCTION HOUSE', GOLD, P.accent2, F.dispb, T.title)
    local where
    if not logged_in() then where = LANG.t('Not logged in')
    elseif st.counter.near then where = LANG.t('At the counter')
    elseif st.counter.dist then where = string.format('Counter %.0f yalms away', st.counter.dist)
    else where = LANG.t('Talk to an auction clerk to trade') end
    local sub = where
    if st.lists[st.category] then
        local n = 0
        for _, row in pairs(st.lists[st.category].items) do if row.single > 0 or row.stack > 0 then n = n + 1 end end
        sub = sub .. '   ·   ' .. n .. ' listed in ' .. (LANG.t(I.CATEGORY_NAME[st.category] or 'this category'))
    end
    text(dl, x + S(84), y + S(50), sub, st.counter.near and P.dim or P.warn, F.text, T.small)
    local pulse = 0.55 + 0.45 * math.sin(t * 2)
    dl:AddRectFilledMultiColor({ x + S(16), y + h - 1 }, { x + w - S(16), y + h + 1 }, u32(GOLD, 0), u32(GOLD, 0.9 * pulse), u32(P.accent2, 0.9 * pulse), u32(P.accent, 0))
    -- right side
    local bx = x + w - S(22)
    local size = S(32)
    local by = y + S(16)
    bx = bx - size
    if icon_button(dl, '##close', bx, by, size, 'xmark', P.dim, LANG.t('Close (Esc)')) then st.open = false end
    bx = bx - size - S(4)
    if icon_button(dl, '##settings', bx, by, size, 'gear', st.settings_open and P.accent or P.dim, LANG.t('Settings')) then st.settings_open = not st.settings_open end
    bx = bx - size - S(4)
    local waiting = SEARCH.pending() > 0 or st.sales_wait
    if waiting then
        dl:PathClear()
        dl:PathArcTo({ bx + size / 2, by + size / 2 }, size / 2 - S(2), t * 5, t * 5 + math.pi * 1.4, 24)
        dl:PathStroke(u32(P.cyan, 0.9), 0, S(2))
    end
    if icon_button(dl, '##refresh', bx, by, size, 'rotate-right', waiting and P.cyan or P.dim, LANG.t('Refresh the list and the item')) then
        fetch_list(st.category, true)
        if st.selected then fetch_history(st.selected, false, true) if I.get(st.selected).stack > 1 then fetch_history(st.selected, true, true) end end
        refresh_inventory()
    end
    bx = bx - size - S(4)
    local n_sales = 0
    for _ in pairs(st.sales) do n_sales = n_sales + 1 end
    if icon_button(dl, '##mysales', bx, by, size, 'receipt', st.tab == 'sales' and GOLD or P.dim, LANG.t('Listings')) then st.tab, st.settings_open = 'sales', false end
    if n_sales > 0 then
        dl:AddCircleFilled({ bx + size - S(5), by + S(5) }, S(6), u32(GOLD), 16)
        text_center(dl, bx + size - S(11), by + S(5), S(12), tostring(n_sales), P.ink, F.bold, T.tiny - 2)
    end
    -- gil
    st.gil_shown = st.gil_shown and lerp(st.gil_shown, st.gil, math.min(1, dt * 5)) or st.gil
    if math.abs(st.gil_shown - st.gil) < 0.5 then st.gil_shown = st.gil end
    local label = gil(st.gil_shown) .. ' gil'
    local pw = pill(dl, 0, -1000, label, P.card, GOLD, F.disp, T.small, S(9), 'coins')
    local px = bx - S(16) - pw
    pill(dl, px, by + S(5), label, mix(GOLD, P.ink, 0.78), GOLD, F.disp, T.small, S(9), 'coins')
    -- the search box, on the buy tab: up here, where there's room (the tab row holds the tabs and the list's filters)
    if st.tab == 'buy' then
        local sw = S(300)
        local sx = px - S(20) - sw
        imgui.SetCursorScreenPos({ sx, by })
        local changed = field('##ahsearch', LANG.t('Search every item by name'), st.query, sw, T.small, false, true)
        if changed then
            local q = st.query[1] or ''
            if #q >= 2 then st.results, st.result_total = I.search(q, 80) fetch_result_lists() else st.results = nil end
            st.list_at = clock()
        end
        if (st.query[1] or '') ~= '' then
            imgui.SetCursorScreenPos({ sx + sw - S(30), by + S(1) })
            local cleared, _, chv = hit('##clearq', S(26), S(26), S(13))
            if chv > 0.01 then dl:AddCircleFilled({ sx + sw - S(16), by + size / 2 }, S(11), u32(P.text, 0.10 * chv), 20) end
            icon(dl, sx + sw - S(16), by + size / 2, 'xmark', mix(P.dim, P.text, chv), T.small)
            if imgui.IsItemHovered() then imgui.SetMouseCursor(7) with_font(F.text, T.small, imgui.SetTooltip, LANG.t('Clear the search')) end
            if cleared then
                st.query[1] = ''
                st.results, st.result_total = nil, 0
                st.list_at = clock()
            end
        else
            icon(dl, sx + sw - S(16), by + size / 2, 'magnifying-glass', P.dim, T.small)
        end
    end
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
    local pressed, hovered, hv = hit(key, cw, ch, S(9))
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
    local tabs = { { 'buy', LANG.t('BUY'), 'cart-shopping' }, { 'sell', LANG.t('SELL'), 'tag' }, { 'sales', LANG.t('LISTINGS'), 'receipt' }, { 'activity', LANG.t('ACTIVITY'), 'clock-rotate-left' }, { 'watch', LANG.t('WATCH'), 'star' } }
    local tx = x + S(24)
    for _, tab in ipairs(tabs) do
        local on = st.tab == tab[1]
        local lw = measure(tab[2], F.disp, T.body)
        local count = tab[1] == 'watch' and #settings.watch > 0 and tostring(#settings.watch) or nil
        local cw = count and (measure(count, F.disp, T.tiny) + S(20)) or 0
        local tw = lw + S(44) + cw
        imgui.SetCursorScreenPos({ tx, y })
        local pressed, _, hv = hit('##tab' .. tab[1], tw, h)
        if pressed then st.tab, st.settings_open = tab[1], false end -- (a tab shows its page: settings close)
        local col = on and GOLD or mix(P.dim, P.text, hv)
        icon(dl, tx + S(14), y + h / 2, tab[3], col, T.small)
        text_mid(dl, tx + S(30), y + h / 2, tab[2], col, F.disp, T.body)
        if count then pill(dl, tx + S(30) + lw + S(6), y + h / 2 - S(9), count, mix(col, P.ink, 0.75), col, F.disp, T.tiny, S(7)) end
        if on then
            dl:AddRectFilledMultiColor({ tx + S(4), y + h - S(4) }, { tx + tw - S(8), y + h - S(2) }, u32(GOLD, 0.2), u32(GOLD, 1), u32(P.accent2, 1), u32(P.accent2, 0.2))
        end
        tx = tx + tw + S(6)
    end
    -- the list's filters, on the buy tab (they filter search results too; the search box is in the header)
    if st.tab == 'buy' then
        local fy = y + (h - S(24)) / 2
        local cx = x + w - S(24) - chip_width(LANG.t('USABLE'))
        local wr = wearer()
        local who = wr.job > 0 and ((U.JOBS[wr.job] or '?') .. wr.level) or 'you'
        local tip = settings.usable and ('Hiding gear your ' .. who .. " can't wear and scrolls it can't learn") or ('Hide gear your ' .. who .. " can't wear (job, level and race) and scrolls it can't learn (main or sub job at its level); everything else stays")
        if filter_chip(dl, '##usable', cx, fy, LANG.t('USABLE'), settings.usable, GOLD, tip, 'user-check', 'user') then
            settings.usable = not settings.usable
            save_settings()
        end
        cx = cx - S(8) - chip_width(LANG.t('IN STOCK'))
        tip = settings.in_stock and LANG.t('Showing only what is up for sale') or LANG.t('Show only what is up for sale')
        if filter_chip(dl, '##instock', cx, fy, LANG.t('IN STOCK'), settings.in_stock, P.ok, tip, 'square-check', 'filter') then
            settings.in_stock = not settings.in_stock
            save_settings()
        end
        cx = cx - S(8) - chip_width(LANG.t('COMPARE'))
        tip = settings.compare and LANG.t('Hovering gear sets it against what you wear') or LANG.t('Hover gear to set it against what you wear in that slot')
        if filter_chip(dl, '##compare', cx, fy, LANG.t('COMPARE'), settings.compare, P.cyan, tip, 'scale-balanced', 'scale-balanced') then
            settings.compare = not settings.compare
            save_settings()
        end
    end
    dl:AddLine({ x + S(16), y + h }, { x + w - S(16), y + h }, u32(P.line), 1)
    return h
end

-- the categories, grouped
local function draw_sidebar(dl, x, y, w, h)
    panel(dl, x, y, w, h, P.glass, 0.92, S(12))
    imgui.SetCursorScreenPos({ x, y })
    imgui.BeginChild('##cats', { w, h }, 256, 0) -- NavFlattened: a controller's focus walks in from outside
    local cdl = imgui.GetWindowDrawList()
    -- the controller's focus (re)starts here on the category in use (pad_cats): its group opened, the child made the
    -- focused window, then the row seated in it the frame after, as the list does
    local seating = st.pad_first and st.pad_cats and PAD.capturing()
    if seating then
        st.group_open[I.group_of(st.category).id] = true
        if st.pad_first == 2 then imgui.SetWindowFocus() end
    end
    local cy = y + S(8) - imgui.GetScrollY() -- drawn where the scroll puts it
    -- the sidebar's last row, for the ring to stop at: the last group, or its last listed category when it's open
    local last_key
    for _, g in ipairs(I.GROUPS) do
        last_key = '##grp' .. g.id
        local open = st.group_open[g.id]
        if open == nil then open = g.id == st.group end
        if open then for _, cat in ipairs(g.cats) do if #I.category(cat) > 0 then last_key = '##cat' .. cat end end end
    end
    -- a stick with the ring in the sidebar walks its rows (in last frame's order; the row scrolls into view itself)
    if st.pad_where == 'cats' and st.cat_keys then
        local ck = st.cat_keys
        stick_walk(#ck, function (i) return ck[i] end)
    end
    local keys = {}
    for _, g in ipairs(I.GROUPS) do
        local open = st.group_open[g.id]
        if open == nil then open = (g.id == st.group) st.group_open[g.id] = open end
        imgui.SetCursorScreenPos({ x, cy })
        keys[#keys + 1] = '##grp' .. g.id
        if st.stick_seat_key == keys[#keys] then imgui.SetKeyboardFocusHere() st.stick_seat_key = nil end
        edge_seat('##grp' .. g.id, g == I.GROUPS[1], '##grp' .. g.id == last_key)
        local pressed, _, hv = hit('##grp' .. g.id, w, S(30), S(8), { x = x + S(6), y = cy + S(2), w = w - S(12), h = S(26) })
        if imgui.IsItemFocused() then st.pad_where_now = 'cats' end
        if pressed then st.group_open[g.id] = not open end
        local active = I.group_of(st.category).id == g.id
        cdl:AddRectFilled({ x + S(6), cy + S(2) }, { x + w - S(6), cy + S(28) }, u32(P.card_hi, (active and 0.5 or 0.15) + 0.3 * hv), S(8))
        icon(cdl, x + S(20), cy + S(15), g.icon, active and GOLD or mix(P.dim, P.text, hv), T.small)
        text_mid(cdl, x + S(36), cy + S(15), LANG.t(g.name):upper(), active and P.text or mix(P.dim, P.text, hv), F.disp, T.small)
        icon(cdl, x + w - S(18), cy + S(15), open and 'chevron-down' or 'chevron-right', P.faint, T.tiny)
        cy = cy + S(32)
        if open then
            for _, cat in ipairs(g.cats) do
                local n = #I.category(cat)
                if n > 0 or not I.answered(cat) then -- (one the house hasn't answered for yet shows, empty)
                    imgui.SetCursorScreenPos({ x, cy })
                    local seat = seating and cat == st.category
                    if seat and st.pad_first == 1 then imgui.SetKeyboardFocusHere() end
                    keys[#keys + 1] = '##cat' .. cat
                    if st.stick_seat_key == keys[#keys] then imgui.SetKeyboardFocusHere() st.stick_seat_key = nil end
                    edge_seat('##cat' .. cat, false, '##cat' .. cat == last_key)
                    local cp, _, chv = hit('##cat' .. cat, w, S(24), S(7), { x = x + S(12), y = cy + S(1), w = w - S(18), h = S(22) })
                    if seat then imgui.SetItemDefaultFocus() end
                    if imgui.IsItemFocused() then st.pad_where_now = 'cats' end
                    local on = st.category == cat and st.results == nil
                    if cp then
                        st.category, st.group = cat, g.id
                        st.query[1], st.results = '', nil
                        st.list_at = clock()
                        fetch_list(cat)
                        -- a controller: Confirm on a category goes on to its list's first row
                        if PAD.shown() then st.pad_first, st.pad_first_id, st.pad_cats = 3, nil, false end
                    end
                    if on then cdl:AddRectFilled({ x + S(12), cy + S(1) }, { x + w - S(6), cy + S(23) }, u32(GOLD, 0.14), S(7)) end
                    text_mid(cdl, x + S(26), cy + S(12), LANG.t(I.CATEGORY_NAME[cat] or ('Category ' .. cat)), on and GOLD or mix(P.dim, P.text, 0.5 + 0.5 * chv), F.text, T.small)
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
    st.cat_keys = keys
    imgui.SetCursorScreenPos({ x, cy + S(4) }) -- the content's end, so the child knows how far it scrolls
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
end

-- the subtitle under an item's name. Japanese job marks are one character, so a long list wraps onto a second
-- line instead of collapsing to "16ジョブ". English stays one line ("16 jobs" when there are many).
local function item_sub_lines(id, max_w, size)
    size = size or T.tiny
    local r = I.get(id)
    local line = I.jobs_line(id)
    if r.stack > 1 then line = (line ~= '' and (line .. '  ·  ') or '') .. 'Stacks of ' .. r.stack end
    if LANG.lang() ~= 'ja' or line == '' or measure(line, F.text, size) <= max_w then return { line } end
    local lines = wrap(line, F.text, size, math.max(S(40), max_w))
    if #lines <= 2 then return lines end
    local jobs = I.jobs_of(r.jobs)
    local marks = {}
    for _, j in ipairs(jobs) do marks[#marks + 1] = LANG.job_label(j, U.JOBS[j]) end
    if #marks == 0 then return { fit(line, F.text, size, max_w) } end
    local prefix = (r.level or 0) > 0 and ('Lv ' .. r.level .. ' ') or ''
    local n1 = #marks
    while n1 > 1 and measure(prefix .. table.concat(marks, '', 1, n1), F.text, size) > max_w do n1 = n1 - 1 end
    local second = table.concat(marks, '', n1 + 1)
    if second == '' then return { prefix .. table.concat(marks, '', 1, n1) } end
    return { prefix .. table.concat(marks, '', 1, n1), second }
end

-- one item row in the list
local function draw_item_row(dl, id, x, y, w, alpha, lines)
    local multi = lines ~= nil and #lines > 1
    local h = S(56) + (multi and S(14) or 0)
    local key = '##item' .. id
    -- a search result from a category not fetched yet: its list carries the stock (only rows on screen are drawn)
    local cat = I.category_of(id)
    if cat and st.lists[cat] == nil then fetch_list(cat) end
    imgui.SetCursorScreenPos({ x, y })
    local pressed, hovered, hv = hit(key, w, h)
    -- (the controller first: ImGui counts the focused row as hovered while its cursor shows)
    if PAD.shown() and imgui.IsItemFocused() then st.hover_id = id st.hover_rect = { x = x, y = y, w = w, h = h }
    elseif hovered then st.hover_id = id st.hover_rect = nil end
    if imgui.IsItemFocused() then st.pad_where_now, st.pad_row = 'items', id end -- (the row Right from the sidebar comes back to)
    local selected = st.selected == id
    local r = I.get(id)
    panel(dl, x, y, w, h, selected and P.card_hi or P.card, (selected and 1 or 0.9 + 0.1 * hv) * alpha, S(10), selected and GOLD or (hv > 0.01 and mix(P.line, P.accent, hv) or nil), selected)
    U.draw_ripples(dl, key, x, y, w, h, GOLD)
    item_icon(dl, id, x + S(10), y + S(8), S(40), alpha)
    local name = fit(r.name, F.disp, T.h2, w - S(250))
    -- gear you can wear as you are shows yellow; gear you can't, dimmed; anything else as it was
    local ncol = P.text
    if (r.jobs or 0) ~= 0 then ncol = can_equip(id) and mix(P.text, GOLD, 0.75) or mix(P.text, P.dim, 0.6)
    else
        local learn = can_learn(id) -- a spell's scroll: yours to learn, or not
        if learn ~= nil then ncol = learn and mix(P.text, GOLD, 0.75) or mix(P.text, P.dim, 0.6) end
    end
    text(dl, x + S(60), y + S(8), name, selected and GOLD or ncol, F.disp, T.h2, alpha)
    local sub_w = w - S(60) - S(110)
    lines = lines or item_sub_lines(id, sub_w)
    local ly = y + S(32)
    for i, ln in ipairs(lines) do
        if i > 2 then break end
        text(dl, x + S(60), ly, fit(ln, F.text, T.tiny, sub_w), P.dim, F.text, T.tiny, alpha * 0.9)
        ly = ly + S(14)
    end
    stock_pills(dl, x + w - S(14), y + S(10), id, alpha, true)
    -- the last sale, once known
    local hs = history_of(id, false)
    if hs and hs.stats then
        local lbl = gil(hs.stats.last) .. ' gil'
        text(dl, x + w - S(14) - measure(lbl, F.semi, T.small), y + S(34), lbl, GOLD, F.semi, T.small, alpha)
    end
    if pressed then
        U.ripple_at(key)
        -- a controller: Confirm picks the item and goes on to its card's price box, ready for a bid
        if PAD.shown() then
            if not selected then select_item(id) end
            st.pad_seat = 'price'
        elseif not selected then select_item(id)
        else select_item(nil) end
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
-- under search results: the search covers the categories the house has answered for on this server (any opened,
-- now or before); the rest can be asked for, once
local function draw_search_reach(dl, x, y, w)
    local total, missing = 0, 0
    for _, cat in ipairs(I.all_categories()) do
        total = total + 1
        if not I.answered(cat) then missing = missing + 1 end
    end
    if missing == 0 then return 0 end
    if st.sweep_wanted then
        text_center(dl, x, y + S(14), w, string.format(LANG.t('Asking the house for the other categories…  %d left'), missing), P.cyan, F.text, T.small)
        return S(32)
    end
    text_center(dl, x, y + S(4), w, string.format(LANG.t('Searched the %d categories opened so far; %d never opened here'), total - missing, missing), P.faint, F.text, T.tiny)
    local bw = math.min(w - S(40), S(300))
    if button(dl, '##search_all', x + (w - bw) / 2, y + S(20), bw, S(30), LANG.t('Include the other categories'), P.accent, 'ghost', 'magnifying-glass', F.semi, T.small) then
        st.sweep_wanted, st.sweep_tries = true, nil
    end
    return S(58)
end

local function draw_list(dl, x, y, w, h, t)
    local ids, title
    if st.results then
        -- a result the house turns out not to list (its category answered without it) drops out
        ids = {}
        for _, id in ipairs(st.results) do if I.listed(id) then ids[#ids + 1] = id end end
        title = 'SEARCH  ·  ' .. #ids .. (st.result_total > #st.results and (' of ' .. st.result_total) or '') .. ' results'
    else
        ids = I.category(st.category)
        title = LANG.t(I.CATEGORY_NAME[st.category] or ''):upper() .. '  ·  ' .. #ids .. ' items'
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
        -- only gear is judged: food, medicines, materials and the rest (no jobs named) anyone can use
        for _, id in ipairs(ids) do
            -- gear you can wear, scrolls you can learn, and everything else (food, materials) as it is
            local ok
            if (I.get(id).jobs or 0) ~= 0 then ok = can_equip(id) else ok = can_learn(id) ~= false end
            if ok then keep[#keep + 1] = id end
        end
        ids = keep
    end
    local hidden = total - #ids
    if settings.in_stock or settings.usable then
        local what = settings.in_stock and settings.usable and 'usable, in stock' or settings.usable and 'usable' or 'in stock'
        if st.results then
            title = 'SEARCH  ·  ' .. #ids .. ' ' .. what
        else
            title = LANG.t(I.CATEGORY_NAME[st.category] or ''):upper() .. '  ·  ' .. #ids .. ' ' .. LANG.t(what) .. ' ' .. LANG.t('of') .. ' ' .. total
        end
    end
    -- the sort, at the right; the title and the fetching note keep to the room left of it
    local current, desc = settings.sort or 'name', sort_desc()
    local WAYS = { name = { 'A to Z', 'Z to A' }, level = { 'lowest first', 'highest first' }, stock = { 'fewest first', 'most first' } }
    local sorts = {}
    for _, s in ipairs({ { 'name', LANG.t('NAME') }, { 'level', LANG.t('LEVEL') }, { 'stock', LANG.t('STOCK') } }) do
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
    imgui.BeginChild('##items', { w, lh }, 256, 0) -- NavFlattened: a controller's focus walks in from outside
    local cdl = imgui.GetWindowDrawList()
    -- the stick walks the list while the ring is in it (or nowhere); in the sidebar it walks the categories
    if st.pad_where == 'items' or st.pad_where == nil then
        stick_walk(#ids, function (i) return '##item' .. ids[i] end, function (i)
            -- (the walk starts from the focused row, in view or not)
            -- (the row's place from its index: rows out of view aren't drawn, so it's scrolled into view first)
            local rh = S(56)
            local top = (i - 1) * (rh + S(6))
            -- the ring kept at the middle of the view, as a scrubber reads best (not nudged along an edge)
            imgui.SetScrollY(math.max(0, math.min(imgui.GetScrollMaxY(), top - (lh - rh) / 2)))
        end, 1, function () for i, id in ipairs(ids) do if id == st.pad_row then return i end end end)
    end
    local seating = st.pad_first and not st.pad_cats and PAD.capturing()
    -- a list the controller's focus (re)starts in shows its top
    if seating and st.pad_first_id == nil then imgui.SetScrollY(0) end
    -- from the card or the sidebar: ImGui won't tab the focus from another window into this (flattened) child, so
    -- the child is made the focused window first, and the row seated in it the frame after
    if seating and st.pad_first == 2 then imgui.SetWindowFocus() end
    local scroll_y = imgui.GetScrollY()
    -- while the stick walks, the rows are laid out from the scroll the walk wants (ImGui's own takes a frame to
    -- follow), with the walk's row at the middle of the view, and that row wears the ring at once: the ring stays
    -- put at the centre and the list flows under it, rather than hopping after the scroll
    local walk_row = st.walk_i and ids[st.walk_i] or nil
    if walk_row then
        local rh = S(56)
        scroll_y = math.max(0, math.min(imgui.GetScrollMaxY(), (st.walk_i - 1) * (rh + S(6)) - (lh - rh) / 2))
        imgui.SetScrollY(scroll_y)
    end
    local cy = ly - scroll_y
    local since = clock() - st.list_at
    local shown = 0
    local first_drawn = nil
    if #ids == 0 then
        local why = hidden == 0 and (st.results and 'Nothing by that name' or (I.answered(st.category) and 'Nothing here' or LANG.t('Asking the house…')))
            or (settings.in_stock and settings.usable and 'Nothing up that you can wear')
            or (settings.usable and 'Nothing here you can wear') or 'Nothing in stock'
        text_center(cdl, x, ly + S(60), w, why, P.dim, F.disp, T.h1)
        if hidden > 0 then text_center(cdl, x, ly + S(90), w, hidden .. (hidden == 1 and ' item is' or ' items are') .. ' hidden by ' .. (settings.in_stock and settings.usable and 'the filters' or settings.usable and 'the Usable filter' or 'the In stock filter'), P.faint, F.text, T.small) end
        if st.results == nil and st.search_error then text_center(cdl, x, ly + S(90), w, 'Search server: ' .. tostring(st.search_error), P.danger, F.text, T.small) end
        if st.results then draw_search_reach(cdl, x, ly + S(120), w) end
    end
    local vis_top, vis_bot = ly - S(60), ly + lh + S(60)
    st.list_ids = ids -- (for /ah pad: which row the ring is on)
    for i, id in ipairs(ids) do
        local rh = S(56)
        if cy + rh >= vis_top and cy <= vis_bot then
            local alpha = math.min(1, (since * 6 - i * 0.05) + 0.3)
            -- the controller's focus (re)starts on the first row shown: as the window appears (SetItemDefaultFocus
            -- works then), and two frames after a tab or category change, once ImGui has restored the window's old
            -- focus (SetKeyboardFocusHere, before the row)
            if first_drawn == nil then first_drawn = i end
            -- (or, back from the card, on the picked row: pad_first_id)
            local seat = seating and (st.pad_first_id and id == st.pad_first_id or (st.pad_first_id == nil and i == first_drawn))
            if seat and st.pad_first == 1 then imgui.SetKeyboardFocusHere() st.pad_seats = (st.pad_seats or 0) + 1 st.seated = true end
            if st.stick_seat_key and st.stick_seat_key == '##item' .. id then imgui.SetKeyboardFocusHere() st.stick_seat_key = nil end -- the stick's row, once drawn
            edge_seat('##item' .. id, i == 1, i == #ids)
            draw_item_row(cdl, id, x + S(4), cy, w - S(12), math.max(0.05, math.min(1, alpha)))
            if walk_row == id then
                U.anim.focus = { x = x + S(4), y = cy, w = w - S(12), h = rh, at = now_t, key = '##item' .. id, r = S(10) }
                st.hover_id, st.hover_rect = id, { x = x + S(4), y = cy, w = w - S(12), h = rh }
            end
            if seat then imgui.SetItemDefaultFocus() end
        end
        cy = cy + rh + S(6)
        shown = shown + 1
    end
    if st.results and #ids > 0 then cy = cy + draw_search_reach(cdl, x, cy + S(4), w - S(12)) end
    -- a remembered row that isn't in this list (another category, a filter): the first row instead
    if seating and st.pad_first == 1 and st.pad_first_id and not st.seated then st.pad_first, st.pad_first_id = 2, nil end
    st.seated = nil
    -- a ring on a row scrolled out of the list (the mouse wheel) would show past the list's edge: not drawn
    local fo = U.anim.focus
    if fo and fo.at == now_t and fo.key:sub(1, 6) == '##item' and (fo.y + fo.h < ly or fo.y > ly + lh) then U.anim.focus = nil end
    if st.stick_seat_key then -- a row that never came up (the list changed): let go
        st.stick_tries = (st.stick_tries or 0) + 1
        if st.stick_tries > 6 then st.stick_seat_key, st.stick_tries = nil, nil end
    else st.stick_tries = nil end
    imgui.SetCursorScreenPos({ x, cy + S(2) })
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
    -- the scrubber: with the stick held in the list, where the ring is by the sort in use (the letter, the level or
    -- the stock), large over the dimmed list as a phone's contact list shows it; it comes after a moment, so a flick
    -- never shows it, and fades out when the stick is let go
    local walking = st.stick_acc ~= nil and (st.pad_where == 'items' or st.pad_where == nil)
    if walking and st.scrub_since == nil then st.scrub_since = now_t end
    if not walking then st.scrub_since = nil end
    local want = (walking and now_t - st.scrub_since > 0.3) and 1 or 0
    st.scrub_a = lerp(st.scrub_a or 0, want, math.min(1, dt * (want > 0 and 10 or 6)))
    local row_id = (st.walk_i and ids[st.walk_i]) or st.pad_row -- the walk's row, before the ring has landed on it
    if st.scrub_a > 0.01 and row_id and I.rows[row_id] then
        local a = st.scrub_a
        local fdl = imgui.GetForegroundDrawList()
        fdl:AddRectFilled({ x, ly }, { x + w, ly + lh }, u32(P.bg, 0.5 * a), S(10))
        local r = I.get(row_id)
        local sort = settings.sort or 'name'
        local label, small
        if sort == 'level' then label, small = tostring(r.level or 0), LANG.t('LEVEL')
        elseif sort == 'stock' then
            local s1, s2 = stock_of(row_id)
            label, small = tostring((s1 or 0) + (s2 or 0)), LANG.t('UP NOW')
        else
            local ch = (r.name or ''):sub(1, 1):upper()
            label = ch:match('%a') and ch or '#'
        end
        local bw, bh = S(104), S(104)
        local bx, by = x + w - bw - S(28), ly + (lh - bh) / 2 -- at the right, over the stock pills, not the name it names
        shadow(fdl, bx, by, bw, bh, S(22), a)
        panel(fdl, bx, by, bw, bh, P.glass, 0.96 * a, S(22), P.line)
        text_center(fdl, bx, by + bh / 2 - (small and S(8) or 0), bw, label, P.text, F.disp, T.h1 * 2, a)
        if small then text_center(fdl, bx, by + bh - S(20), bw, small, P.dim, F.disp, T.tiny, a) end
    end
end

-- the selected item: everything about it, its history, and the buy box
local function draw_detail(dl, x, y, w, h, t)
    local id = st.selected
    panel(dl, x, y, w, h, P.glass, 0.97, S(14), P.line)
    st.card_focus = false
    if id == nil then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(30), w, LANG.t('Pick an item'), P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(54), w, LANG.t('Its stock, sale history and a buy box show here'), P.dim, F.text, T.small)
        return
    end
    local r = I.get(id)
    local cx, cy = x + S(16), y + S(16)
    item_icon(dl, id, cx, cy, S(56), 1)
    if st.stack then stack_badge(dl, cx, cy, S(56), r.stack) end
    -- the star: follow this item (single or stack, whichever is picked) on the watch tab
    local watched = watch_entry(id, st.stack) ~= nil
    if icon_button(dl, '##star', x + w - S(44), y + S(10), S(28), 'star', watched and GOLD or P.dim, watched and LANG.t('Stop watching') or (LANG.t('Watch this item') .. (r.stack > 1 and (st.stack and ' (stacks)' or ' (singles)') or ''))) then
        toggle_watch(id, st.stack)
    end
    text(dl, cx + S(68), cy, fit(r.name, F.disp, T.h1, w - S(130)), GOLD, F.disp, T.h1)
    local line = I.jobs_line(id)
    if r.stack > 1 then line = (line ~= '' and (line .. '  ·  ') or '') .. 'Stacks of ' .. r.stack end
    text(dl, cx + S(68), cy + S(28), fit(line ~= '' and line or (I.CATEGORY_NAME[I.category_of(id) or 0] or ''), F.text, T.small, w - S(100)), P.dim, F.text, T.small)
    cy = cy + S(66)
    -- the description, wrapped
    local desc = COMPARE.readable(r.desc)
    if desc ~= '' then
        local lines = {}
        for raw in (desc .. '\n'):gmatch('([^\n]*)\n') do
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
    text(dl, cx, cy, LANG.t('IN STOCK'), P.accent, F.disp, T.small)
    stock_pills(dl, x + w - S(16), cy - S(2), id, 1, true)
    cy = cy + S(26)
    if r.stack > 1 then
        -- a controller is sent here by Up from the price box (ImGui's own Up skipped it for the sidebar): the side in
        -- use takes the focus, asked again each frame until it has (VanaCore moves ImGui's focus on the same press)
        if st.pad_seat == 'stack' then
            imgui.SetKeyboardFocusHere(st.stack and 1 or 0) -- (the switch's two buttons are its next two items)
            st.stack_tries = (st.stack_tries or 0) + 1
        end
        local picked = U.segments(dl, '##ss', cx, cy, S(26), { { false, LANG.t('SINGLE') }, { true, 'STACK of ' .. r.stack } }, st.stack, function () return GOLD end, F.disp, T.tiny)
        if picked ~= st.stack then st.stack = picked st.buy.price[1] = '' end
        local fo = U.anim.focus
        local on_switch = PAD.shown() and fo ~= nil and fo.at == now_t and (fo.key == '##ss1' or fo.key == '##ss2')
        if st.pad_seat == 'stack' and (on_switch or st.stack_tries > 6) then st.pad_seat, st.stack_tries = nil, nil end
        -- on it: Left and Right pick singles or stacks, Down goes back to the price box
        if on_switch and st.pad_seat == nil then
            st.card_focus, st.pad_hold = true, 'all'
            local want = st.stack
            if PAD.pressed('left') then want = false end
            if PAD.pressed('right') then want = true end
            if want ~= st.stack then st.stack, st.buy.price[1] = want, '' end
            if PAD.pressed('left') or PAD.pressed('right') then st.pad_seat = 'stack' end -- (kept on the side picked)
            if PAD.pressed('down') then st.pad_seat = 'price' end
        end
        cy = cy + S(34)
    end
    -- the history
    local hs = history_of(id, st.stack)
    -- gone after a purchase or a sale (it changed): asked for again (fetch_history waits out a failure)
    if hs == nil then fetch_history(id, st.stack) end
    text(dl, cx, cy, LANG.t('RECENT SALES'), P.accent, F.disp, T.small)
    if st.fetching[id .. '/' .. (st.stack and 1 or 0)] then text(dl, x + w - S(48) - measure('fetching…', F.text, T.tiny), cy + S(2), 'fetching…', P.cyan, F.text, T.tiny) end
    if icon_button(dl, '##chart_toggle', x + w - S(42), cy - S(5), S(24), 'chart-line', settings.chart and P.cyan or P.faint, settings.chart and LANG.t('Hide the price graph') or LANG.t('Show the price graph')) then
        settings.chart = not settings.chart save_settings()
    end
    local hy = cy
    cy = cy + S(22)
    local bottom = y + h - S(96)
    if hs == nil then
        text(dl, cx, cy, st.search_error and ('Search server: ' .. tostring(st.search_error)) or LANG.t('Asking the house…'), st.search_error and P.danger or P.dim, F.text, T.small)
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
    st.card_focus = st.card_focus or imgui.IsItemFocused() -- a controller's focus is on the card: Cancel goes back to the list
    local price = tonumber(st.buy.price[1]) or (hs and hs.stats and hs.stats.last) or 0
    local can = may_trade() and price > 0 and logged_in() and st.buy.pending == nil
    local label = st.buy.pending and 'Bidding…' or 'Bid'
    if entered and can and settings.confirm_buy then st.confirm = { kind = 'buy', item = id, price = price, stack = st.stack } end
    -- a controller: Confirm on the picked row, or a closed confirmation, lands the focus here
    if st.pad_seat == 'bid' then imgui.SetKeyboardFocusHere() st.pad_seat = nil end
    local bid_pressed = button(dl, '##bid_btn', x + w - S(16) - S(104), by, S(104), S(34), label, can and GOLD or P.faint, can and 'solid' or 'ghost', 'gavel')
    if st.pad_mute then bid_pressed = false end -- the Confirm that kept the price, not a press of Bid
    if bid_pressed and PAD.shown() then st.pad_mute = 'held' end -- nor of the confirmation's Bid, which takes the focus
    if imgui.IsItemFocused() then
        st.card_focus = true
        st.pad_hold = 'all' -- the D-pad is the window's here: Left is the price box (ImGui's own Left wandered off to the sidebar)
        if PAD.pressed('left') then st.pad_seat = 'price' end
    end
    if bid_pressed and can then
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
-- SELL's market box: what's up now (singles and stacks), how it has sold (last, median, range, the trend), the
-- price graph of the record, and the latest sales, as many as fit. Last, median and each sale fill the asking price
-- when clicked. Returns nothing; draws in x..x+w, y..y+h
local function draw_sell_market(dl, x, y, w, h, id, hs)
    local stack = st.sell.stack
    local head = LANG.t('MARKET') .. '  ·  ' .. (stack and LANG.t('stacks') or LANG.t('singles'))
    text(dl, x, y, head, P.accent, F.disp, T.small)
    if hs and hs.stats and hs.stats.trend then
        local tr = hs.stats.trend
        local flat = math.abs(tr) <= 0.02
        local tl = flat and LANG.t('steady') or string.format('%s%.0f%%', tr > 0 and '+' or '', tr * 100)
        text(dl, x + measure(head, F.disp, T.small) + S(10), y + S(1), tl, flat and P.dim or (tr > 0 and P.ok or P.warn), F.semi, T.tiny)
    end
    stock_pills(dl, x + w, y - S(3), id, 1, true)
    local cy = y + S(22)
    local bottom = y + h
    local function ask(price)
        st.sell.price[1] = tostring(price)
        st.sell.fee, st.sell.asked = nil, nil
    end
    if hs == nil then
        text(dl, x, cy, st.search_error and ('Search server: ' .. tostring(st.search_error)) or LANG.t('Asking the house…'), st.search_error and P.danger or P.dim, F.text, T.small)
        return
    end
    if hs.stats == nil then
        text(dl, x, cy, LANG.t(stack and 'No stacks sold lately' or 'No singles sold lately'), P.dim, F.text, T.small)
        text(dl, x, cy + S(20), LANG.t('Nobody has bought one here lately: your price sets the market'), P.faint, F.text, T.tiny)
        return
    end
    local s = hs.stats
    -- last, median, range (last and median are prices to take)
    local cw = w / 3
    local cols = { { 'LAST', s.last, GOLD }, { 'MEDIAN', s.median, P.text }, { 'RANGE', nil, P.text } }
    for i, c in ipairs(cols) do
        local cx = x + (i - 1) * cw
        if c[2] then
            imgui.SetCursorScreenPos({ cx - S(6), cy - S(4) })
            local pressed, hovered, hv = hit('##mkt' .. i, cw - S(4), S(44), S(8), { x = cx - S(6), y = cy - S(4), w = cw - S(4), h = S(44) })
            if hv > 0.01 then dl:AddRectFilled({ cx - S(6), cy - S(4) }, { cx + cw - S(10), cy + S(40) }, u32(GOLD, 0.09 * hv), S(8)) end
            if hovered then with_font(F.text, T.small, imgui.SetTooltip, LANG.t('Ask this price')) end
            if pressed then ask(c[2]) end
        end
        text(dl, cx, cy, LANG.t(c[1]), P.faint, F.disp, T.tiny)
        if c[2] then
            text(dl, cx, cy + S(14), fit(gil(c[2]), F.disp, T.h2, cw - S(12)), c[3], F.disp, T.h2)
        else
            text(dl, cx, cy + S(18), fit(gil(s.low) .. ' – ' .. gil(s.high), F.semi, T.small, cw - S(4)), c[3], F.semi, T.small)
        end
    end
    cy = cy + S(40)
    -- the graph, as the Buy card draws it (every sale on record, the median dashed), when there's room for it and
    -- three sales under it; without the room, each sale says how far it was from the median instead
    local series = PRICES.series(id, stack)
    local rh = S(20)
    local room = bottom - cy - S(8) - rh * math.min(3, #hs.sales)
    local charted = settings.chart and #series >= 1 and room >= S(50)
    if charted then
        local gh = math.min(S(96), room)
        panel(dl, x - S(4), cy, w + S(8), gh, P.well, 0.6, S(8))
        PRICES.chart(dl, x, cy + S(4), w, gh - S(8), series, { color = P.cyan, median = s.median, key = '##sellchart' .. id })
        cy = cy + gh + S(8)
    else
        dl:AddLine({ x, cy }, { x + w, cy }, u32(P.line, 0.7), 1)
        cy = cy + S(6)
    end
    -- the latest sales, newest first, a flat list as on the Buy card: price, when, who sold to whom
    local n = math.min(#hs.sales, 8, math.max(0, math.floor((bottom - cy) / rh)))
    for i = 1, n do
        local sale = hs.sales[i]
        imgui.SetCursorScreenPos({ x - S(6), cy })
        local pressed, hovered, hv = hit('##mks' .. i, w + S(12), rh, S(6), { x = x - S(6), y = cy, w = w + S(12), h = rh })
        if hv > 0.01 then dl:AddRectFilled({ x - S(6), cy }, { x + w + S(6), cy + rh }, u32(GOLD, 0.08 * hv), S(6)) end
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, LANG.t('Ask this price')) end
        if pressed then ask(sale.price) end
        text_mid(dl, x, cy + rh / 2, gil(sale.price), i == 1 and GOLD or P.text, F.semi, T.small)
        text_mid(dl, x + S(96), cy + rh / 2, ago(sale.date), P.dim, F.text, T.tiny)
        local whow = w - S(190)
        if not charted and s.median > 0 then
            local d = (sale.price - s.median) / s.median
            local pct = math.abs(d) < 0.005 and '±0%' or string.format('%s%d%%', d > 0 and '+' or '−', math.floor(math.abs(d) * 100 + 0.5))
            text_mid(dl, x + S(170), cy + rh / 2, pct, math.abs(d) < 0.03 and P.dim or (d > 0 and P.warn or P.ok), F.semi, T.tiny)
            whow = w - S(230)
        end
        local who = fit((sale.seller or '?') .. ' → ' .. (sale.buyer or '?'), F.text, T.tiny, whow)
        text_mid(dl, x + w - measure(who, F.text, T.tiny), cy + rh / 2, who, P.faint, F.text, T.tiny)
        cy = cy + rh
    end
end

local function draw_sell(dl, x, y, w, h, t)
    if clock() - st.inv_at > LIMITS.inventory then refresh_inventory() end
    local bagw = w - S(340)
    -- what's shown: the whole bag, or only what the house takes (the SELLABLE chip, remembered)
    local items, hidden = {}, 0
    for _, it in ipairs(st.inventory) do
        local r = I.get(it.id)
        -- sellable as the game's own window judges it: not NOAUCTION-flagged in the client's item data. Not by the house's
        -- category lists: only the categories you've opened are asked for, so an item missing from them may still be
        -- one the house takes (the fee quote says so when it doesn't)
        local sellable = bit.band(r.flags, 0x40) == 0
        if settings.sellable_only and not sellable then hidden = hidden + 1
        else items[#items + 1] = { it = it, r = r, sellable = sellable } end
    end
    text(dl, x + S(6), y, LANG.t('YOUR BAG') .. '  ·  ' .. #st.inventory .. ' ' .. LANG.t('items') .. (hidden > 0 and ('  ·  ' .. hidden .. ' ' .. LANG.t('the house won\'t take, hidden')) or ''), P.dim, F.disp, T.small)
    local chip_x = x + bagw - S(8) - chip_width(LANG.t('SELLABLE'))
    if filter_chip(dl, '##sellable', chip_x, y - S(4), LANG.t('SELLABLE'), settings.sellable_only, GOLD,
        settings.sellable_only and LANG.t("Hiding what the house won't take") or LANG.t("Hide what the house won't take"), 'tag', 'tag') then
        settings.sellable_only = not settings.sellable_only
        save_settings()
    end
    -- the bag as icons or as a list (remembered)
    do
        local bs = S(26)
        local bx = chip_x - S(10) - bs * 2 - S(4)
        for i, v in ipairs({ { 'grid', 'table-cells', 'Show the bag as icons' }, { 'list', 'list-ul', 'Show the bag as a list' } }) do
            local on = (settings.sell_view or 'grid') == v[1]
            local px_ = bx + (i - 1) * (bs + S(4))
            if on then dl:AddRectFilled({ px_, y - S(5) }, { px_ + bs, y - S(5) + bs }, u32(GOLD, 0.16), S(7)) end
            if icon_button(dl, '##sellview' .. v[1], px_, y - S(5), bs, v[2], on and GOLD or P.dim, LANG.t(v[3])) and not on then
                settings.sell_view = v[1]
                save_settings()
            end
        end
    end
    local gy = y + S(28)
    local gh = h - S(28)
    imgui.SetCursorScreenPos({ x, gy })
    imgui.BeginChild('##bag', { bagw, gh }, 256, 0) -- NavFlattened: a controller's focus walks in from outside
    local cdl = imgui.GetWindowDrawList()
    pad_scroll()
    if st.pad_first and PAD.capturing() then imgui.SetScrollY(0) end
    local cell = S(52)
    local per = math.max(1, math.floor((bagw - S(16)) / (cell + S(6))))
    local listed_view = settings.sell_view == 'list'
    local rowh = S(46)
    local cx, cy = x + S(4), gy - imgui.GetScrollY()
    -- the stick walks the bag a row of cells at a time (one at a time in the list view), unless the price box has the ring
    local ask = field_state['##ask']
    if not (ask and (ask.focused or ask.pad_on)) then
        stick_walk(#items, function (i) return '##bag' .. items[i].it.slot end, nil, listed_view and 1 or per)
    end
    local n = 0
    if #items == 0 and hidden > 0 then
        text_center(cdl, x, gy + S(40), bagw, 'Nothing in your bag the house takes', P.dim, F.disp, T.body)
    end
    for _, entry in ipairs(items) do
        local it, r, sellable = entry.it, entry.r, entry.sellable
        local key = '##bag' .. it.slot
        imgui.SetCursorScreenPos({ cx, cy })
        local seat = st.pad_first and n == 0 and PAD.capturing()
        if seat and st.pad_first == 1 then imgui.SetKeyboardFocusHere() end
        if st.stick_seat_key == key then imgui.SetKeyboardFocusHere() st.stick_seat_key = nil end -- the stick's cell, or Left from the price box
        edge_seat(key, n == 0, n == #items - 1)
        local cw_, ch_ = cell, cell
        if listed_view then cw_, ch_ = bagw - S(16), rowh end
        local pressed, hovered, hv = hit(key, cw_, ch_, S(8))
        if seat then imgui.SetItemDefaultFocus() end
        local on = st.sell.slot == it.slot
        if listed_view then
            -- a row: the icon, the name and how many, its category (or that the house won't take it), and the last
            -- sale when it's known (asked for only when the item is picked)
            local a_ = sellable and 1 or 0.4
            panel(cdl, cx, cy, cw_, ch_, on and P.card_hi or P.card, (on and 1 or 0.85 + 0.15 * hv) * a_, S(9), on and GOLD or (hv > 0.01 and mix(P.line, P.accent, hv) or nil))
            item_icon(cdl, it.id, cx + S(7), cy + S(6), ch_ - S(12), a_)
            local nx = cx + ch_ + S(6)
            text(cdl, nx, cy + S(5), fit(r.name, F.disp, T.body, cw_ - ch_ - S(150)), sellable and P.text or P.faint, F.disp, T.body)
            local sub = it.count > 1 and ('x' .. it.count .. (r.stack > 1 and ('  ·  ' .. LANG.t('stacks of') .. ' ' .. r.stack) or '')) or ''
            local cat = I.category_of(it.id)
            local cn = sellable and (cat and LANG.t(I.CATEGORY_NAME[cat] or '') or '') or LANG.t('The house does not take this')
            if cn ~= '' then sub = sub ~= '' and (sub .. '  ·  ' .. cn) or cn end
            text(cdl, nx, cy + S(26), fit(sub, F.text, T.tiny, cw_ - ch_ - S(150)), P.dim, F.text, T.tiny, a_)
            local hs = sellable and history_of(it.id, false)
            if hs and hs.stats then
                local pl = gil(hs.stats.last) .. ' gil'
                text_mid(cdl, cx + cw_ - S(14) - measure(pl, F.semi, T.small), cy + ch_ / 2, pl, GOLD, F.semi, T.small)
            end
        else
        cdl:AddRectFilled({ cx, cy }, { cx + cell, cy + cell }, u32(on and GOLD or P.card, on and 0.22 or (0.6 + 0.3 * hv)), S(8))
        item_icon(cdl, it.id, cx + S(6), cy + S(6), cell - S(12), sellable and 1 or 0.35)
        if it.count > 1 then
            local cl = tostring(it.count)
            cdl:AddRectFilled({ cx + cell - S(8) - measure(cl, F.bold, T.tiny - 1), cy + cell - S(18) }, { cx + cell - S(4), cy + cell - S(4) }, u32(P.ink, 0.8), S(4))
            text(cdl, cx + cell - S(6) - measure(cl, F.bold, T.tiny - 1), cy + cell - S(17), cl, P.text, F.bold, T.tiny - 1)
        end
        if on then cdl:AddRect({ cx, cy }, { cx + cell, cy + cell }, u32(GOLD, 0.9), S(8), 15, S(1.5)) end
        end
        if hovered and not listed_view then
            with_font(F.text, T.small, imgui.SetTooltip, r.name .. (it.count > 1 and (' x' .. it.count) or '') .. (sellable and '' or ('\n' .. LANG.t('The house does not take this'))))
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
        if listed_view then cy = cy + rowh + S(5)
        elseif n % per == 0 then cx = x + S(4) cy = cy + cell + S(6) else cx = cx + cell + S(6) end
    end
    if not listed_view and n % per ~= 0 then cy = cy + cell + S(6) end
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
        text_center(dl, px, y + h / 2 + S(10), pw, LANG.t('Pick something from your bag'), P.text, F.disp, T.h2)
        text_center(dl, px, y + h / 2 + S(34), pw, LANG.t('Greyed items are ones the house does not take'), P.dim, F.text, T.small)
        return
    end
    local id = st.sell.item
    local r = I.get(id)
    item_icon(dl, id, sx, sy, S(48), 1)
    if st.sell.stack then stack_badge(dl, sx, sy, S(48), r.stack) end
    text(dl, sx + S(60), sy, fit(r.name, F.disp, T.h2, pw - S(90)), GOLD, F.disp, T.h2)
    text(dl, sx + S(60), sy + S(26), LANG.t('You have') .. ' ' .. st.sell.count .. (r.stack > 1 and ('  ·  ' .. LANG.t('stacks of') .. ' ' .. r.stack) or ''), P.dim, F.text, T.small)
    sy = sy + S(62)
    if r.stack > 1 then
        -- stacks can be picked with fewer than a stack in the slot: their prices show, only listing waits for a full one
        local can_stack = st.sell.count >= r.stack
        local picked = U.segments(dl, '##sellss', sx, sy, S(26), { { false, LANG.t('SINGLE') }, { true, LANG.t('FULL STACK') } }, st.sell.stack, function (o) return (o[1] and not can_stack) and P.dim or GOLD end, F.disp, T.tiny)
        if picked ~= st.sell.stack then st.sell.stack = picked st.sell.price[1] = '' st.sell.fee, st.sell.asked = nil, nil end
        if not can_stack then text(dl, sx + S(200), sy + S(7), string.format(LANG.t('%d of %d for a stack'), st.sell.count, r.stack), P.faint, F.text, T.tiny) end
        sy = sy + S(44)
    end
    -- the market for it, filling the room between the item and the asking price (anchored at the bottom)
    local hs = history_of(id, st.sell.stack)
    if hs == nil then fetch_history(id, st.sell.stack) end
    local cat = I.category_of(id)
    if cat then fetch_list(cat) end -- the stock of both kinds (cached; asked again only when stale)
    local by = y + h - S(138)
    panel(dl, sx - S(8), sy - S(8), pw - S(16), by - sy - S(2), P.well, 0.35, S(10))
    draw_sell_market(dl, sx, sy, pw - S(32), by - sy - S(18), id, hs)
    sy = by
    text(dl, sx, sy, LANG.t('ASKING PRICE'), GOLD, F.disp, T.small)
    local label_y = sy
    sy = sy + S(20)
    imgui.SetCursorScreenPos({ sx, sy })
    local edited, _, entered = field('##ask', hs and hs.stats and ('type a price · last sold ' .. tostring(hs.stats.last)) or LANG.t('type a price in gil'), st.sell.price, pw - S(32), T.body, true)
    if edited then st.sell.fee, st.sell.asked = nil, nil end
    sy = sy + S(38)
    local price = tonumber(st.sell.price[1]) or 0
    -- where your price stands against the median, beside the label
    if price > 0 and hs and hs.stats and hs.stats.median > 0 then
        local d = (price - hs.stats.median) / hs.stats.median
        local verdict, vcol
        if math.abs(d) < 0.03 then verdict, vcol = LANG.t('at the median'), P.dim
        elseif d > 0 then verdict, vcol = string.format(LANG.t('%d%% above the median'), math.floor(d * 100 + 0.5)), P.warn
        else verdict, vcol = string.format(LANG.t('%d%% under the median'), math.floor(-d * 100 + 0.5)), P.ok end
        text(dl, sx + pw - S(32) - measure(verdict, F.text, T.tiny), label_y + S(2), verdict, vcol, F.text, T.tiny)
    end
    local short = st.sell.stack and (st.sell.count or 0) < r.stack -- looking at stack prices without a full stack
    local can = may_trade() and price > 0 and not st.sell.pending and not short
    -- one button, named for the price: the house is asked its fee, and its answer opens the card with the whole
    -- transaction (the price, the fee paid now, the payout) to say yes to; a fee already known opens it at once
    local known = st.sell.asked and st.sell.asked.price == price and st.sell.asked.stack == st.sell.stack
    if not may_trade() then
        text(dl, sx, sy, LANG.t('Talk to an auction clerk to sell'), P.warn, F.text, T.small)
    elseif short then
        text(dl, sx, sy, string.format(LANG.t('You have %d of %d: a stack lists once you have a full one'), st.sell.count, r.stack), P.warn, F.text, T.small)
    elseif known then
        text(dl, sx, sy, 'Listing fee ' .. gil(st.sell.fee or 0) .. ' gil, paid now', st.sell.fee and st.sell.fee > st.gil and P.danger or P.dim, F.text, T.small)
    else
        text(dl, sx, sy, 'The house quotes its listing fee first; nothing is listed until you say so', P.faint, F.text, T.tiny)
    end
    sy = sy + S(26)
    local label = st.sell.pending and LANG.t('Asking the house…') or short and LANG.t('Not a full stack') or (price > 0 and ('List for ' .. gil(price) .. ' gil') or LANG.t('List it'))
    local ok = can and (not known or (st.sell.fee or 0) <= st.gil)
    if st.pad_seat == 'list' then imgui.SetKeyboardFocusHere() st.pad_seat = nil end -- a controller, from the price box
    local list_pressed = button(dl, '##list_btn', sx, sy, pw - S(32), S(36), label, ok and GOLD or P.faint, ok and 'solid' or 'ghost', 'tag')
    if st.pad_mute then list_pressed = false end -- the Confirm that kept the price, not a press of List
    if imgui.IsItemFocused() then
        st.pad_hold = true -- Up from List is the price box, the window's to do
        if PAD.pressed('up') then st.pad_seat = 'price' end
    end
    if (list_pressed or entered) and ok then
        if known then
            st.confirm = { kind = 'sell' }
        else
            st.sell.confirm_on_fee = true
            do_ask(st.sell.slot, id, price, st.sell.stack)
        end
    end
end

-- LISTINGS
local function draw_sales(dl, x, y, w, h, t)
    local rows = {}
    for _, row in pairs(st.sales) do rows[#rows + 1] = row end
    table.sort(rows, function (a, b) return a.key < b.key end)
    local head = LANG.t('UP FOR SALE') .. '  ·  ' .. #rows .. (#rows == 1 and (' ' .. LANG.t('item')) or (' ' .. LANG.t('items')))
    text(dl, x + S(6), y, head, P.dim, F.disp, T.small)
    local cooling = clock() - st.sales_at < LIMITS.sales or st.sweep ~= nil
    local label = (st.sweep or st.sales_wait) and LANG.t('Reading…') or LANG.t('Refresh')
    if button(dl, '##sales_refresh', x + w - S(130), y - S(6), S(124), S(26), label, cooling and P.faint or P.accent, 'ghost', 'rotate-right', F.semi, T.tiny) and not cooling and may_trade() then
        start_sweep()
    end
    local cy = y + S(32)
    if #rows == 0 then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        if st.sweep then
            text_center(dl, x, y + h / 2 + S(30), w, LANG.t('Reading your listings'), P.text, F.disp, T.h1)
            text_center(dl, x, y + h / 2 + S(54), w, 'The house hands them out a page at a time; a few seconds', P.dim, F.text, T.small)
        else
            text_center(dl, x, y + h / 2 + S(30), w, st.sales_open and LANG.t('Nothing up for sale') or LANG.t('Ask the house'), P.text, F.disp, T.h1)
            text_center(dl, x, y + h / 2 + S(54), w, st.sales_open and LANG.t('Sell something from your bag') or (may_trade() and LANG.t('Refresh lists what you have up') or LANG.t('Talk to an auction clerk')), P.dim, F.text, T.small)
        end
        return
    end
    -- the rows, in an area of their own that scrolls (seven up, one with its history open, don't fit)
    local bottom = y + h - S(22)
    imgui.SetCursorScreenPos({ x, cy })
    imgui.BeginChild('##sales_rows', { w, bottom - cy }, 256, 0) -- NavFlattened: a controller's focus walks in from outside
    local cdl = imgui.GetWindowDrawList()
    local child_top = cy
    cy = cy - imgui.GetScrollY()
    local top = cy
    -- while the pages are being read the rows are under a veil and their buttons do nothing: a take-down sent while
    -- the house is turning its pages could land on the wrong one
    local busy = st.sweep ~= nil
    -- the rows by key for Y (history) and X (relist), the first as the fallback; the stick walks them
    st.sales_rows = { rows[1] }
    for _, row in ipairs(rows) do st.sales_rows[row.key] = row end
    stick_walk(#rows, function (i) return '##hist' .. rows[i].key end, nil, 1, function (k)
        local rk = sales_row_key(k)
        for i, row in ipairs(rows) do if row.key == rk then return i end end
    end)
    for _, row in ipairs(rows) do
        local rh = S(60)
        local first, last = row == rows[1], row == rows[#rows]
        local key = row.id .. '/' .. (row.stack and 1 or 0)
        local open = st.sales_hist == row.key -- this listing's, not every listing of the same item
        -- open, the card grows to hold the history, outlined as one
        local hs, lines, eh = nil, 0, 0
        if open then
            hs = history_of(row.id, row.stack)
            lines = hs and math.min(5, #hs.sales) or 0
            eh = S(60) + lines * S(19) + (hs and #hs.sales == 0 and S(4) or 0)
        end
        panel(cdl, x + S(4), cy, w - S(8), rh + eh, P.card, 0.95, S(10))
        item_icon(cdl, row.id, x + S(14), cy + S(8), S(44), 1)
        local r = I.get(row.id)
        local pl = gil(row.price) .. ' gil'
        local plw = measure(pl, F.disp, T.h2)
        text(cdl, x + S(68), cy + S(8), fit(r.name .. (row.stack and ('  ·  ' .. LANG.t('stack of') .. ' ' .. r.stack) or ''), F.disp, T.h2, w - S(68) - S(386) - plw - S(12)), P.text, F.disp, T.h2)
        text_mid(cdl, x + w - S(366) - plw, cy + rh / 2, pl, GOLD, F.disp, T.h2) -- centred on the row, as the buttons are
        -- its category, and when it went up where the server says (its pages don't); the page and slot are the house's
        local sub = LANG.t(I.CATEGORY_NAME[I.category_of(row.id) or 0] or '')
        if row.at and row.at > 0 then sub = sub .. (sub ~= '' and '  ·  ' or '') .. 'listed ' .. ago(row.at) end
        text(cdl, x + S(68), cy + S(34), sub, P.dim, F.text, T.tiny)
        -- its recent sales, asked for only when wanted (the search server isn't asked for what nobody looks at)
        if st.stick_seat_key == '##hist' .. row.key then imgui.SetKeyboardFocusHere() st.stick_seat_key = nil end
        edge_seat('##hist' .. row.key, first, last)
        if button(cdl, '##hist' .. row.key, x + w - S(130) - S(8) - S(104), cy + S(14), S(104), S(32), open and LANG.t('Hide') or LANG.t('History'), busy and P.faint or (open and P.cyan or P.accent), 'ghost', 'clock-rotate-left', F.semi, T.small) and not busy then
            if open then
                st.sales_hist = nil -- (not `open and nil or key`: that is always key)
            else
                st.sales_hist = row.key
                fetch_history(row.id, row.stack)
            end
        end
        local can = may_trade() and st.cancel_pending == nil and not busy and st.relist == nil and not st.sell.pending
        -- relist: down, and up again at a new price (a new fee), after picking the price and confirming
        edge_seat('##relist' .. row.key, first, last)
        if button(cdl, '##relist' .. row.key, x + w - S(130) - S(8) - S(104) - S(8) - S(104), cy + S(14), S(104), S(32), LANG.t('Relist'), can and GOLD or P.faint, 'ghost', 'rotate-right', F.semi, T.small) and can then
            fetch_history(row.id, row.stack)
            st.confirm = { kind = 'relist', slot = row.slot, item = row.id, page = row.page, key = row.key, price = row.price, stack = row.stack }
        end
        edge_seat('##cancel' .. row.key, first, last)
        if button(cdl, '##cancel' .. row.key, x + w - S(130), cy + S(14), S(116), S(32), LANG.t('Take down'), can and P.danger or P.faint, 'ghost', 'xmark', F.semi, T.small) and can then
            st.confirm = { kind = 'cancel', slot = row.slot, item = row.id, page = row.page, key = row.key, price = row.price }
        end
        cy = cy + rh
        if open then
            -- under the row: last, median, range and the trend, where your price stands, then the latest sales
            cdl:AddRectFilled({ x + S(5), cy + S(2) }, { x + w - S(5), cy + eh - S(1) }, u32(P.well, 0.45), S(8))
            cdl:AddLine({ x + S(16), cy + S(2) }, { x + w - S(16), cy + S(2) }, u32(P.line, 0.6), 1)
            local ix = x + S(68)
            local ey = cy + S(10)
            text(cdl, ix, ey, 'RECENT SALES  ·  ' .. (row.stack and 'stacks' or 'singles'), P.accent, F.disp, T.tiny)
            if st.fetching[key] then text(cdl, ix + S(150), ey + S(1), 'fetching…', P.cyan, F.text, T.tiny) end
            if hs == nil then
                text(cdl, ix, ey + S(20), st.search_error and ('Search server: ' .. tostring(st.search_error)) or LANG.t('Asking the house…'), st.search_error and P.danger or P.dim, F.text, T.small)
            elseif #hs.sales == 0 then
                text(cdl, ix, ey + S(20), 'No ' .. (row.stack and 'stacks' or 'singles') .. ' sold lately', P.dim, F.text, T.small)
            else
                local st_ = hs.stats
                local summary = LANG.t('last') .. ' ' .. gil(st_.last) .. '  ·  ' .. LANG.t('median') .. ' ' .. gil(st_.median) .. '  ·  ' .. LANG.t('range') .. ' ' .. gil(st_.low) .. ' – ' .. gil(st_.high)
                if st_.trend then
                    local flat = math.abs(st_.trend) <= 0.02
                    summary = summary .. '  ·  ' .. (flat and 'steady' or string.format('%s%.0f%%', st_.trend > 0 and '+' or '', st_.trend * 100))
                end
                text(cdl, ix, ey + S(18), summary, P.text, F.semi, T.small)
                -- where yours stands against the median
                local d = st_.median > 0 and (row.price - st_.median) / st_.median or 0
                local verdict, vcol
                if math.abs(d) < 0.03 then verdict, vcol = 'yours is at the median', P.dim
                elseif d > 0 then verdict, vcol = string.format('yours is %.0f%% above the median', d * 100), P.warn
                else verdict, vcol = string.format('yours is %.0f%% under the median', -d * 100), P.ok end
                text(cdl, x + w - S(20) - measure(verdict, F.text, T.tiny), ey + S(20), verdict, vcol, F.text, T.tiny)
                local ry = ey + S(42)
                for i = 1, lines do
                    local sale = hs.sales[i]
                    text(cdl, ix, ry, gil(sale.price), i == 1 and GOLD or P.text, F.semi, T.small)
                    text(cdl, ix + S(96), ry, ago(sale.date), P.dim, F.text, T.small)
                    local who = fit(sale.seller .. ' → ' .. sale.buyer, F.text, T.tiny, w - S(300))
                    text(cdl, x + w - S(20) - measure(who, F.text, T.tiny), ry + S(2), who, P.faint, F.text, T.tiny)
                    ry = ry + S(19)
                end
            end
            cy = cy + eh
        end
        cy = cy + S(8)
    end
    imgui.SetCursorScreenPos({ x, cy + S(2) })
    imgui.Dummy({ 1, 1 })
    if busy then
        -- the veil, in the child's own list so it lies over the rows
        cdl:AddRectFilled({ x, child_top }, { x + w, bottom }, u32(P.ink, 0.62), S(10))
        local pulse = 0.7 + 0.3 * math.sin(t * 3)
        local my = child_top + math.min(S(120), (bottom - child_top) / 2)
        icon(cdl, x + w / 2 - measure(LANG.t('Reading your listings'), F.disp, T.h1) / 2 - S(18), my, 'rotate-right', P.cyan, T.h2, pulse)
        text_center(cdl, x + S(18), my, w, LANG.t('Reading your listings'), P.text, F.disp, T.h1)
        text_center(cdl, x, my + S(26), w, 'The house hands them out a page at a time; a few seconds', P.dim, F.text, T.small)
    end
    imgui.EndChild()
    cy = bottom
    text(dl, x + S(6), cy + S(4), 'Sold items pay out to your delivery box; the house holds unsold ones until you take them down. Sales are on the Activity tab.', P.faint, F.text, T.tiny)
end

-- ACTIVITY: the character's record of the house, bought, listed, taken down and sold, newest first, a page at a time,
-- with the gil in and out over the whole of it
local ACT_KIND = {
    bought = { label = LANG.t('BOUGHT'), color = P.cyan, icon = 'cart-shopping', sign = -1 },
    sold = { label = LANG.t('SOLD'), color = P.ok, icon = 'sack-dollar', sign = 1 },
    listed = { label = LANG.t('LISTED'), color = P.accent, icon = 'tag', sign = 0 },
    taken = { label = LANG.t('TAKEN DOWN'), color = P.dim, icon = 'xmark', sign = 0 },
}
local ACT_PER = 20
local function draw_activity(dl, x, y, w, h, t)
    local rows, page, pages, total = LEDGER.page(st.act_filter, st.act_page, ACT_PER)
    st.act_page = page
    text(dl, x + S(6), y, LANG.t('ACTIVITY') .. '  ·  ' .. total .. (total == 1 and (' ' .. LANG.t('entry')) or (' ' .. LANG.t('entries'))), P.dim, F.disp, T.small)
    -- the filters
    local fy = y - S(4)
    local fx = x + w - S(6)
    for _, f in ipairs({ { 'sold', LANG.t('SOLD'), P.ok, 'sack-dollar' }, { 'bought', LANG.t('BOUGHT'), P.cyan, 'cart-shopping' }, { 'all', LANG.t('ALL'), GOLD, 'clock-rotate-left' } }) do
        fx = fx - chip_width(f[2])
        if filter_chip(dl, '##act_' .. f[1], fx, fy, f[2], st.act_filter == f[1], f[3], nil, f[4], f[4]) then
            st.act_filter, st.act_page, st.act_top = f[1], 1, true
        end
        fx = fx - S(8)
    end
    -- clearing the record (all of it, whatever the filter), asked first
    if LEDGER.count() > 0 then
        local cw_ = S(84)
        if button(dl, '##act_clear', fx - cw_, fy - S(2), cw_, S(26), LANG.t('Clear'), P.dim, 'ghost', 'trash-can', F.semi, T.tiny) then
            st.confirm = { kind = 'clear', n = LEDGER.count() }
        end
    end
    -- the gil, over everything the filter keeps
    local tot = LEDGER.totals(st.act_filter)
    local ty = y + S(30)
    panel(dl, x + S(4), ty, w - S(8), S(50), P.well, 0.45, S(10))
    local cols = {}
    if st.act_filter ~= 'sold' then cols[#cols + 1] = { LANG.t('SPENT'), gil(tot.spent), P.cyan, tot.bought .. (tot.bought == 1 and (' ' .. LANG.t('purchase')) or (' ' .. LANG.t('purchases'))) } end
    if st.act_filter ~= 'bought' then cols[#cols + 1] = { LANG.t('EARNED'), gil(tot.earned), P.ok, tot.sold .. (tot.sold == 1 and (' ' .. LANG.t('sale')) or (' ' .. LANG.t('sales'))) } end
    if st.act_filter == 'all' then
        cols[#cols + 1] = { LANG.t('FEES'), gil(tot.fees), P.dim, tot.listed .. (tot.listed == 1 and (' ' .. LANG.t('listing')) or (' ' .. LANG.t('listings'))) }
        cols[#cols + 1] = { LANG.t('NET'), (tot.net < 0 and '−' or '') .. gil(math.abs(tot.net)), tot.net < 0 and P.danger or (tot.net > 0 and GOLD or P.text), LANG.t('sales less purchases and fees') }
    end
    local cw = (w - S(8)) / #cols
    for i, c in ipairs(cols) do
        local cx = x + S(4) + (i - 1) * cw
        text(dl, cx + S(16), ty + S(7), c[1], P.dim, F.disp, T.tiny)
        text(dl, cx + S(16), ty + S(21), c[2] .. ' gil', c[3], F.disp, T.h2)
        local sub = c[4]
        text(dl, cx + cw - S(16) - measure(sub, F.text, T.tiny), ty + S(26), sub, P.faint, F.text, T.tiny)
        if i > 1 then dl:AddLine({ cx, ty + S(10) }, { cx, ty + S(40) }, u32(P.line, 0.6), 1) end
    end
    local cy = ty + S(60)
    local bottom = y + h - S(30)
    if total == 0 then
        glass_gil(dl, x + w / 2, y + h / 2 - S(10), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(50), w, st.act_filter == 'all' and LANG.t('Nothing yet') or ('Nothing ' .. st.act_filter .. ' yet'), P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(74), w, LANG.t('What you buy, list, take down and sell here is kept, per character, across restarts'), P.dim, F.text, T.small)
        return
    end
    imgui.SetCursorScreenPos({ x, cy })
    imgui.BeginChild('##act_rows', { w, bottom - cy }, 256, 0) -- NavFlattened: a controller's focus walks in from outside
    local cdl = imgui.GetWindowDrawList()
    if st.act_top then imgui.SetScrollY(0) st.act_top = nil end -- a new page or filter starts at its top
    cy = cy - imgui.GetScrollY()
    for _, r in ipairs(rows) do
        local k = ACT_KIND[r.kind] or ACT_KIND.listed
        local rh = S(48)
        panel(cdl, x + S(4), cy, w - S(8), rh, P.card, 0.85, S(10))
        if r.id then item_icon(cdl, r.id, x + S(14), cy + S(6), S(36), 1) end
        local what = r.id and I.name(r.id) or (r.name or 'Unknown item')
        if r.stack then
            local n = r.id and I.get(r.id).stack or 0
            what = what .. (n > 1 and ('  ·  ' .. LANG.t('stack of') .. ' ' .. n) or '  ·  stack')
        end
        local pw = pill(cdl, x + S(60), cy + S(7), k.label, mix(k.color, P.ink, 0.72), k.color, F.disp, T.tiny - 1, S(7), k.icon)
        text(cdl, x + S(60) + pw + S(8), cy + S(6), fit(what, F.disp, T.body, w - S(300) - pw), P.text, F.disp, T.body)
        local when = ago(r.at)
        local line
        if r.kind == 'sold' then line = 'to ' .. (r.who or 'someone') .. '  ·  the gil went to your delivery box'
        elseif r.kind == 'bought' then line = 'from the house'
        elseif r.kind == 'listed' then line = 'fee ' .. gil(r.fee or 0) .. ' gil, paid then'
        else line = 'back to your bag' end
        text(cdl, x + S(60), cy + S(28), line .. '  ·  ' .. when, P.dim, F.text, T.tiny)
        local pl = (k.sign < 0 and '−' or (k.sign > 0 and '+' or '')) .. gil(r.price) .. ' gil'
        local pc = k.sign < 0 and P.cyan or (k.sign > 0 and P.ok or P.dim)
        text_mid(cdl, x + w - S(20) - measure(pl, F.disp, T.h2), cy + rh / 2, pl, pc, F.disp, T.h2)
        cy = cy + rh + S(6)
    end
    imgui.SetCursorScreenPos({ x, cy + S(2) })
    imgui.Dummy({ 1, 1 })
    imgui.EndChild()
    -- the pages
    cy = bottom
    local can_prev, can_next = page > 1, page < pages
    if button(dl, '##act_prev', x + S(4), cy + S(2), S(92), S(26), 'Newer', can_prev and P.accent or P.faint, 'ghost', 'chevron-left', F.semi, T.tiny) and can_prev then
        st.act_page, st.act_top = page - 1, true
    end
    if button(dl, '##act_next', x + w - S(4) - S(92), cy + S(2), S(92), S(26), 'Older', can_next and P.accent or P.faint, 'ghost', 'chevron-right', F.semi, T.tiny) and can_next then
        st.act_page, st.act_top = page + 1, true
    end
    local lo, hi = (page - 1) * ACT_PER + 1, math.min(total, page * ACT_PER)
    text_center(dl, x, cy + S(7), w, 'Page ' .. page .. ' of ' .. pages .. '  ·  ' .. lo .. '–' .. hi .. ' of ' .. total, P.dim, F.text, T.tiny)
end

-- WATCH: the items you follow, each with its stock, last price, how it moved, a sparkline, and a price to be told at
local function draw_watch(dl, x, y, w, h, t)
    local list = settings.watch
    text(dl, x + S(6), y, LANG.t('WATCHING') .. '  ·  ' .. #list .. (#list == 1 and (' ' .. LANG.t('item')) or (' ' .. LANG.t('items'))), P.dim, F.disp, T.small)
    local checked = st.watch_at > 0 and ('checked ' .. ago(os.time() - math.floor(clock() - st.watch_at))) or (settings.watch_poll and LANG.t('checks every') .. ' ' .. math.floor((settings.watch_every or 300) / 60) .. ' ' .. LANG.t('min') or 'background checks are off')
    text(dl, x + w - S(142) - measure(checked, F.text, T.tiny), y + S(3), checked, P.faint, F.text, T.tiny)
    local busy = SEARCH.pending() > 0
    if button(dl, '##watch_refresh', x + w - S(130), y - S(6), S(124), S(26), busy and 'Asking…' or LANG.t('Check now'), busy and P.faint or P.accent, 'ghost', 'rotate-right', F.semi, T.tiny) and not busy and #list > 0 then
        poll_watch()
    end
    local ly, lh = y + S(32), h - S(32)
    if #list == 0 then
        glass_gil(dl, x + w / 2, y + h / 2 - S(30), S(72), t, 0.9)
        text_center(dl, x, y + h / 2 + S(30), w, LANG.t('Nothing watched yet'), P.text, F.disp, T.h1)
        text_center(dl, x, y + h / 2 + S(54), w, "Star an item on its card: its stock, price and trend show here, and you're told when it sells under your price", P.dim, F.text, T.small)
        return
    end
    -- their histories stay fresh while this is open
    for _, e in ipairs(list) do fetch_history(e.id, e.stack) end
    imgui.SetCursorScreenPos({ x, ly })
    imgui.BeginChild('##watch', { w, lh }, 256, 0) -- NavFlattened: a controller's focus walks in from outside
    local cdl = imgui.GetWindowDrawList()
    local cy = ly - imgui.GetScrollY()
    local remove = nil
    -- the rows by key for Y (unwatch) and X (the price), the first as the fallback; the stick walks them unless a
    -- price box has the ring
    st.watch_rows = { list[1] }
    for _, e in ipairs(list) do st.watch_rows[watch_key(e.id, e.stack)] = e end
    local fo = U.anim.focus
    if not (fo and now_t - fo.at < 0.1 and fo.key:sub(1, 7) == '##under') then
        stick_walk(#list, function (i) return '##w' .. watch_key(list[i].id, list[i].stack) end, nil, 1, function (k)
            local wk = watch_row_key(k)
            for i, e in ipairs(list) do if watch_key(e.id, e.stack) == wk then return i end end
        end)
    end
    for i, e in ipairs(list) do
        local lines = item_sub_lines(e.id, S(230))
        local rh = S(78) + (#lines > 1 and S(14) or 0)
        local id, key = e.id, watch_key(e.id, e.stack)
        local r = I.get(id)
        local hs = st.hist[key]
        local series = PRICES.series(id, e.stack)
        panel(cdl, x + S(4), cy, w - S(12), rh, P.card, 0.95, S(10))
        -- the name takes you to its card
        imgui.SetCursorScreenPos({ x + S(4), cy })
        if st.stick_seat_key == '##w' .. key then imgui.SetKeyboardFocusHere() st.stick_seat_key = nil end
        edge_seat('##w' .. key, i == 1, i == #list)
        local pressed, hovered, hv = hit('##w' .. key, S(300), rh)
        if pressed then
            local cat = I.category_of(id)
            if cat then st.category, st.group = cat, I.group_of(cat).id st.group_open[st.group] = true fetch_list(cat) end
            st.tab = 'buy'
            st.stack = e.stack or false
            st.results = nil
            select_item(id)
        end
        if hovered then with_font(F.text, T.small, imgui.SetTooltip, LANG.t('Open its card')) end
        if hv > 0 then cdl:AddRectFilled({ x + S(4), cy }, { x + S(304), cy + rh }, u32(P.card_hi, 0.6 * hv), S(10)) end
        item_icon(cdl, id, x + S(14), cy + S(15), S(48), 1)
        if lines[1] == '' then lines[1] = LANG.t(I.CATEGORY_NAME[I.category_of(id) or 0] or '') end
        text(cdl, x + S(72), cy + S(10), fit(r.name .. (e.stack and ('  ·  ' .. LANG.t('stack of') .. ' ' .. r.stack) or ''), F.disp, T.h2, S(222)), mix(P.text, GOLD, hv), F.disp, T.h2)
        for li, ln in ipairs(lines) do
            if li > 2 then break end
            text(cdl, x + S(72), cy + S(34) + (li - 1) * S(13), fit(ln, F.text, T.tiny, S(230)), P.dim, F.text, T.tiny)
        end
        stock_pills(cdl, x + S(72), cy + S(52) + (#lines > 1 and S(14) or 0), id, 1, false)
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
            text(cdl, px, cy + S(14), st.fetching[key] and LANG.t('Asking the house…') or (st.search_error and 'Search server: ' .. tostring(st.search_error) or '—'), st.search_error and P.danger or P.faint, F.text, T.small)
        end
        -- the price to be told at
        local ax = x + w - S(8) - S(40) - S(100)
        icon(cdl, ax + S(6), cy + S(16), 'bell', e.under and P.warn or P.faint, T.tiny)
        text(cdl, ax + S(16), cy + S(10), LANG.t('TELL ME UNDER'), e.under and P.warn or P.faint, F.disp, T.tiny - 1)
        local buf = st.watch_buf[key]
        if buf == nil then buf = { e.under and tostring(e.under) or '' } st.watch_buf[key] = buf end
        imgui.SetCursorScreenPos({ ax, cy + S(28) })
        edge_seat('##under' .. key, i == 1, i == #list)
        local changed = field('##under' .. key, LANG.t('any price'), buf, S(100), T.small, true)
        if changed then
            local v = tonumber(buf[1])
            e.under = (v and v > 0) and math.floor(v) or nil
            save_settings()
        end
        edge_seat('##unwatch' .. key, i == 1, i == #list)
        if icon_button(cdl, '##unwatch' .. key, x + w - S(42), cy + S(25), S(28), 'xmark', P.dim, LANG.t('Stop watching')) then remove = i end
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
    text(dl, cx + S(26), cy, LANG.t('SETTINGS'), P.accent2, F.disp, T.h2)
    -- the theme, in the right-hand column: Party Finder's palettes, by the same names
    do
        local rx, ry = x + math.floor(w * 0.58), y + S(52)
        -- the header's badge
        local iy = ry
        text(dl, rx, iy, LANG.t('ICON'), P.dim, F.disp, T.small)
        local iopts = { { id = 'cat', name = 'CatsEyeXI' }, { id = 'coin', name = LANG.t('Gil') } }
        local icur = settings.icon or 'cat'
        local ipicked = U.dropdown(dl, '##ah_icon', rx, iy + S(40), S(170), iopts, icur)
        if ipicked ~= icur then settings.icon = ipicked save_settings() end
        -- a preview of the one chosen, beside the choice
        local pcx, pcy = rx + S(170) + S(16) + S(15), iy + S(40)
        local cat = settings.icon ~= 'coin' and badge_texture()
        if cat then
            local bs = S(32)
            dl:AddImage(cat, { pcx - bs / 2, pcy - bs / 2 }, { pcx + bs / 2, pcy + bs / 2 }, { 0, 0 }, { 1, 1 }, u32('#FFFFFF'))
        else
            glass_gil(dl, pcx, pcy, S(28), now_t, 1)
        end
        local ty = ry + S(88)
        text(dl, rx, ty, LANG.t('THEME'), P.dim, F.disp, T.small)
        local opts = {}
        for _, th in ipairs(U.THEMES) do opts[#opts + 1] = { id = th.id, name = th.name } end
        local current = settings.theme or 'aurora'
        local picked = U.dropdown(dl, '##ah_theme', rx, ty + S(40), S(170), opts, current)
        if picked ~= current then set_theme(picked) end
        local th = U.THEME_BY_ID[settings.theme or 'aurora'] or U.THEMES[1]
        for i, k in ipairs({ 'accent', 'accent2', 'cyan', 'card_hi' }) do
            dl:AddCircleFilled({ rx + S(170) + S(20) + (i - 1) * S(16), ty + S(40) }, S(6), u32(th.palette[k] or P[k]), 16)
        end
        text(dl, rx, ty + S(64), "The same themes as Party Finder  ·  /ah theme <name>", P.faint, F.text, T.tiny)
        -- the language: the client's own, or one picked; the flag beside it says which is in use
        local ly = ry + S(176)
        text(dl, rx, ly, LANG.t('LANGUAGE'), P.dim, F.disp, T.small)
        local lopts = { { id = 'auto', name = LANG.t('Auto (the client\'s)') }, { id = 'en', name = 'English' }, { id = 'ja', name = '日本語' } }
        local lcur = settings.language or 'auto'
        local lpicked = U.dropdown(dl, '##ah_lang', rx, ly + S(40), S(170), lopts, lcur)
        if lpicked ~= lcur then
            settings.language = lpicked
            apply_language()
            save_settings()
        end
        draw_flag(dl, rx + S(170) + S(16), ly + S(40) - S(9), S(26), S(18), LANG.lang())
        text(dl, rx, ly + S(64), LANG.t('Item names, the window and the help  ·  /ah lang auto|en|ja'), P.faint, F.text, T.tiny)
        -- the bell the window opens with: Off, or one of the bells (picking one plays it; the speaker plays it again)
        local sy = ry + S(264)
        text(dl, rx, sy, 'SOUND AS IT OPENS', P.dim, F.disp, T.small)
        local sopts = { { id = 'off', name = 'Off' } }
        for _, o in ipairs(OPEN_SOUNDS) do sopts[#sopts + 1] = o end
        local scur = settings.open_sound and (settings.open_sound_id or OPEN_SOUNDS[1].id) or 'off'
        local spicked = U.dropdown(dl, '##ah_sound', rx, sy + S(40), S(170), sopts, scur)
        if spicked ~= scur then
            if spicked == 'off' then settings.open_sound = false
            else settings.open_sound, settings.open_sound_id = true, spicked play_open_sound() end
            save_settings()
        end
        if settings.open_sound and icon_button(dl, '##ah_sound_play', rx + S(170) + S(10), sy + S(40) - S(14), S(28), 'volume-high', P.dim, 'Play it') then
            play_open_sound(true)
        end
        text(dl, rx, sy + S(64), '/ah sound <name>  ·  /ah sound off', P.faint, F.text, T.tiny)
    end
    if icon_button(dl, '##settings_close', x + w - S(44), y + S(10), S(28), 'xmark', P.dim, LANG.t('Close')) then st.settings_open = false end
    cy = cy + S(36)
    local changed = false
    local v, ch
    v, ch = U.toggle(dl, '##t_takeover', cx, cy + S(10), LANG.t("Talking to a clerk opens this, not the game's menu"), settings.take_over) settings.take_over = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_confirm', cx, cy + S(10), LANG.t('Confirm before bidding'), settings.confirm_buy) settings.confirm_buy = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_chart', cx, cy + S(10), LANG.t("Price graph on an item's card"), settings.chart) settings.chart = v changed = changed or ch
    cy = cy + S(34)
    v, ch = U.toggle(dl, '##t_watch', cx, cy + S(10), 'Check watched items every ' .. math.floor((settings.watch_every or 300) / 60) .. ' min, even with this closed', settings.watch_poll) settings.watch_poll = v changed = changed or ch
    cy = cy + S(40)
    text(dl, cx, cy, LANG.t('WINDOW'), P.dim, F.disp, T.small)
    cy = cy + S(24)
    text_mid(dl, cx, cy, LANG.t('Opacity'), P.dim, F.text, T.small)
    local op = U.slider(dl, '##s_op', cx + S(80), cy, S(200), (settings.opacity or 1) * 100, 40, 100, '%d%%')
    if math.abs(op / 100 - settings.opacity) > 0.001 then settings.opacity = op / 100 changed = true end
    cy = cy + S(30)
    text_mid(dl, cx, cy, LANG.t('Scale'), P.dim, F.text, T.small)
    local sc, _, released = U.slider(dl, '##s_scale', cx + S(80), cy, S(200), st.scale_edit or settings.scale or 100, 50, 300, '%d%%', true)
    st.scale_edit = sc
    if released then settings.scale = math.floor(sc) st.scale_edit = nil changed = true end
    cy = cy + S(40)
    -- (the search server isn't shown: it's the login server's address, found from the login; /ah debug and /ah server
    -- are there for anyone who needs to see or change it)
    text(dl, cx, cy, LANG.t('KEYS'), P.dim, F.disp, T.small)
    cy = cy + S(20)
    -- the bind in words: the modifiers, then the key (not a chain of gsubs: 'Ctrl+' would have its + read as Shift)
    local spec = settings.keybind or ''
    local bind = (spec:find('%^') and 'Ctrl+' or '') .. (spec:find('!') and 'Alt+' or '') .. (spec:find('%+') and 'Shift+' or '') .. spec:gsub('[%^!%+]', '')
    local what = st.bind_capture and LANG.t('Press a key to open the house with  ·  Esc keeps it as it is')
        or ((bind ~= '' and (bind .. ' ' .. LANG.t('opens the house')) or LANG.t('No key opens the house')) .. '  ·  ' .. LANG.t('Esc closes it'))
    text_mid(dl, cx, cy + S(15), what, st.bind_capture and GOLD or P.text, F.text, T.small)
    local bx = cx + math.floor(w * 0.58) - S(40) - S(96)
    if bind ~= '' and not st.bind_capture then
        bx = bx - S(80) - S(8)
        if button(dl, '##bind_off', bx + S(96) + S(8), cy, S(80), S(30), LANG.t('Off'), P.dim, 'ghost', 'ban', F.semi, T.small) then set_keybind('') end
    end
    if button(dl, '##bind_change', bx, cy, S(96), S(30), LANG.t(st.bind_capture and 'Cancel' or 'Change'), P.accent, 'ghost', nil, F.semi, T.small) then st.bind_capture = not st.bind_capture or nil end
    if st.bind_capture then capture_keybind() end
    -- browsing away from a counter: at the bottom, in a warning box that can't be missed
    do
        local bx, bw, bh = x + S(20), w - S(40), S(56)
        local by_ = y + h - S(12) - bh
        panel(dl, bx, by_, bw, bh, P.warn, settings.view_anywhere and 0.16 or 0.08, S(10), P.warn)
        icon(dl, bx + S(18), by_ + S(14), 'triangle-exclamation', P.warn, T.body)
        v, ch = U.toggle(dl, '##t_anywhere', bx + S(34), by_ + S(14), LANG.t('View the Auction House anywhere'), settings.view_anywhere) settings.view_anywhere = v changed = changed or ch
        local ty = by_ + S(28)
        for _, l in ipairs(wrap(LANG.t('Using the Auction House outside of normal areas is generally against the rules on most servers and can be easily tracked. Use at your own risk, you have been warned.'), F.text, T.tiny, bw - S(70))) do
            text(dl, bx + S(34), ty, l, P.warn, F.text, T.tiny)
            ty = ty + S(13)
        end
    end
    text(dl, cx, cy + S(30), LANG.t('Japanese localization: thanks to Hando'), P.faint, F.text, T.tiny)
    if changed then save_settings() end
end

local function draw_confirm()
    local c = st.confirm
    if c == nil then return end
    local w, h = S(420), (c.kind == 'sell' or c.kind == 'clear') and S(206) or S(176)
    if c.kind == 'relist' then w, h = S(470), S(338) end
    if c.kind == 'sell' and st.relist then h = h + S(18) end
    if c.kind == 'cancel' and st.server_page ~= nil and st.server_page ~= c.page then h = h + S(18) end -- a line about the wait
    U.dialog('##ah_confirm', w, h, 0, function (dl, x, y)
        shadow(dl, x, y, w, h, S(16), 1.5)
        panel(dl, x, y, w, h, P.glass, 1, S(16), GOLD, true)
        if c.kind == 'relist' then
            -- the new price: a cut, the median or the last sale, or typed; then down it comes and the fee is asked
            local r = I.get(c.item)
            local hs = history_of(c.item, c.stack)
            local opts, suggest = relist_options(c.price, hs)
            -- the box starts at the suggestion and follows it (the sales arrive a moment after the dialog opens) until a
            -- choice is clicked or a price typed
            local sp = suggest and tostring(suggest.price) or tostring(c.price)
            if c.buf == nil then c.buf, c.auto = { sp }, sp end
            if c.auto and c.buf[1] == c.auto and sp ~= c.auto then c.buf[1], c.auto = sp, sp end
            if c.auto and c.buf[1] ~= c.auto then c.auto = nil end
            text(dl, x + S(22), y + S(18), fit(LANG.t('Relist') .. ' ' .. r.name .. (c.stack and ('  ·  ' .. LANG.t('stack of') .. ' ' .. r.stack) or '') .. '?', F.disp, T.h1, w - S(110)), P.text, F.disp, T.h1)
            item_icon(dl, c.item, x + w - S(22) - S(48), y + S(16), S(48), 1)
            if c.stack then stack_badge(dl, x + w - S(22) - S(48), y + S(16), S(48), r.stack) end
            local now = LANG.t('Up now for') .. ' ' .. gil(c.price) .. ' gil'
            if hs and hs.stats then now = now .. '  ·  ' .. LANG.t('median') .. ' ' .. gil(hs.stats.median) .. '  ·  ' .. LANG.t('last') .. ' ' .. gil(hs.stats.last)
            elseif hs then now = now .. '  ·  ' .. LANG.t('none sold lately')
            else now = now .. '  ·  ' .. LANG.t('asking for its sales…') end
            text(dl, x + S(22), y + S(50), fit(now, F.text, T.small, w - S(110)), P.dim, F.text, T.small)
            text(dl, x + S(22), y + S(80), LANG.t('NEW PRICE'), GOLD, F.disp, T.small)
            -- the choices, three to a row, each with its price; the suggested one marked
            local per, gap = 3, S(8)
            local bw = (w - S(44) - gap * (per - 1)) / per
            local oy = y + S(100)
            local picked = tonumber(c.buf[1])
            for i, o in ipairs(opts) do
                local col_, row_ = (i - 1) % per, math.floor((i - 1) / per)
                local bx, by = x + S(22) + col_ * (bw + gap), oy + row_ * S(38)
                local on = picked == o.price
                local label = o.label .. '  ' .. gil(o.price) .. (o == suggest and ' ★' or '')
                if button(dl, '##rl' .. i, bx, by, bw, S(32), fit(label, F.semi, T.small, bw - S(14)), on and GOLD or (o == suggest and P.accent or P.dim), on and 'solid' or 'ghost', nil, F.semi, T.small) then
                    c.buf[1] = tostring(o.price)
                    c.auto = nil
                end
            end
            if #opts == 0 then text(dl, x + S(22), oy + S(8), LANG.t('Type the new price'), P.faint, F.text, T.small) end
            local fy = oy + math.max(1, math.ceil(#opts / per)) * S(38) + S(4)
            imgui.SetCursorScreenPos({ x + S(22), fy })
            field('##relist_price', LANG.t('type a price in gil'), c.buf, w - S(44), T.body, true)
            local np = tonumber(c.buf[1]) or 0
            local note
            if np > 0 and hs and hs.stats and hs.stats.median > 0 then
                local d = (np - hs.stats.median) / hs.stats.median
                if math.abs(d) < 0.03 then note = LANG.t('at the median')
                elseif d > 0 then note = string.format(LANG.t('%d%% above the median'), math.floor(d * 100 + 0.5))
                else note = string.format(LANG.t('%d%% under the median'), math.floor(-d * 100 + 0.5)) end
                text(dl, x + w - S(22) - measure(note, F.text, T.tiny), y + S(82), note, P.dim, F.text, T.tiny)
            end
            local ly = fy + S(42)
            for _, l in ipairs(wrap(LANG.t('It comes down now, and the house quotes the new fee before it goes back up: you confirm that as any listing. The old fee is not returned.'), F.text, T.tiny, w - S(44))) do
                text(dl, x + S(22), ly, l, P.faint, F.text, T.tiny)
                ly = ly + S(15)
            end
            local ok = np >= 1 and np <= 999999999 and may_trade() and st.cancel_pending == nil and st.relist == nil
            local yes_pressed = button(dl, '##cyes', x + w - S(22) - S(136), y + h - S(50), S(136), S(34), LANG.t('Relist'), ok and GOLD or P.faint, ok and 'solid' or 'ghost', 'rotate-right')
            if st.pad_mute then yes_pressed = false end
            if yes_pressed and ok then
                st.relist = { stage = 'cancel', id = c.item, stack = c.stack, old = c.price, price = np, key = c.key, at = clock() }
                st.confirm = nil
                do_cancel(c)
            end
            if button(dl, '##cno', x + w - S(22) - S(136) - S(8) - S(96), y + h - S(50), S(96), S(34), 'Cancel', P.dim, 'ghost') then
                st.confirm = nil
            end
            return
        end
        local title, body, yes, ic, col
        if c.kind == 'buy' then
            local r = I.get(c.item)
            title = 'Bid ' .. gil(c.price) .. ' gil?'
            body = r.name .. (c.stack and ('  ·  ' .. LANG.t('stack of') .. ' ' .. r.stack) or '  ·  one') .. '\nThe house fills the cheapest listing at or under your bid; you pay what you bid.'
            yes, ic, col = LANG.t('Bid'), 'gavel', GOLD
            item_icon(dl, c.item, x + w - S(22) - S(48), y + S(16), S(48), 1)
            if c.stack then stack_badge(dl, x + w - S(22) - S(48), y + S(16), S(48), r.stack) end
        elseif c.kind == 'sell' then
            local a = st.sell.asked
            local r = I.get(a.item)
            local what = r.name .. (a.stack and (' (a stack of ' .. r.stack .. ')') or '')
            title = (st.relist and LANG.t('Relist') or 'List') .. ' ' .. what .. ' for ' .. gil(a.price) .. ' gil?'
            body = (st.relist and (string.format(LANG.t('It was up for %s gil and is in your bag now.'), gil(st.relist.old)) .. '\n') or '') .. 'Listing fee: ' .. gil(st.sell.fee or 0) .. ' gil, paid now and kept whether or not it sells.'
                .. '\nWhen it sells, ' .. gil(a.price) .. ' gil goes to your delivery box.'
                .. '\nUnsold, it waits at the house until you take it down.'
            yes, ic, col = LANG.t('List it'), 'tag', GOLD
            item_icon(dl, a.item, x + w - S(22) - S(48), y + S(16), S(48), 1)
            if a.stack then stack_badge(dl, x + w - S(22) - S(48), y + S(16), S(48), r.stack) end
        elseif c.kind == 'clear' then
            title = LANG.t('Clear your activity?')
            body = string.format(LANG.t('All %d entries go, and the gil totals with them. This cannot be undone.'), c.n or 0)
                .. '\n' .. LANG.t('It only clears this record: nothing you have up at the house is touched.')
            yes, ic, col = LANG.t('Clear'), 'trash-can', P.danger
        else
            title = 'Take it down?'
            body = I.name(c.item) .. ' comes back to your bag.\nThe listing fee is not returned.'
            if st.server_page ~= nil and st.server_page ~= c.page then
                body = body .. '\nThe house needs a moment to find this one.'
            end
            yes, ic, col = LANG.t('Take down'), 'xmark', P.danger
        end
        text(dl, x + S(22), y + S(18), title, P.text, F.disp, T.h1)
        local ly = y + S(50)
        for line in (body .. '\n'):gmatch('([^\n]*)\n') do
            for _, l in ipairs(wrap(line, F.text, T.small, w - S(110))) do
                text(dl, x + S(22), ly, l, P.dim, F.text, T.small)
                ly = ly + S(18)
            end
        end
        local yes_pressed = button(dl, '##cyes', x + w - S(22) - S(136), y + h - S(50), S(136), S(34), yes, col, 'solid', ic)
        imgui.SetItemDefaultFocus() -- a controller: Confirm again goes through
        if st.pad_mute then yes_pressed = false end -- (a fresh Confirm: not the one that opened this)
        if yes_pressed then
            if c.kind == 'buy' then do_buy(c.item, c.price, c.stack)
            elseif c.kind == 'sell' then do_list()
            elseif c.kind == 'clear' then LEDGER.clear() st.act_page, st.act_top = 1, true
            else do_cancel(c) end
            st.confirm = nil
            if c.kind == 'buy' and PAD.shown() then st.pad_seat = 'bid' end -- the controller's focus comes back to the card
        end
        if button(dl, '##cno', x + w - S(22) - S(136) - S(8) - S(96), y + h - S(50), S(96), S(34), 'Cancel', P.dim, 'ghost') then
            st.confirm = nil
            if c.kind == 'buy' and PAD.shown() then st.pad_seat = 'bid' end
        end
    end)
end

-- The controller's buttons with a meaning of their own (the D-pad, the sticks and Confirm are ImGui's): Cancel backs
-- out as Esc does, the bumpers turn the tabs, the triggers walk the categories, X and Y are the In stock and Usable
-- chips, Menu is the settings, View the Compare chip.
local TAB_ORDER = { 'buy', 'sell', 'sales', 'activity', 'watch' }
local CAT_ORDER = {}
for _, g in ipairs(I.GROUPS) do for _, c in ipairs(g.cats) do CAT_ORDER[#CAT_ORDER + 1] = { cat = c, group = g.id } end end

local function pad_buttons()
    if st.pad_editing then return end -- a price box has the pad (pad_price_box)
    if PAD.pressed('cancel') and not imgui.IsAnyItemActive() then
        st.pad_cancels = (st.pad_cancels or 0) + 1
        if st.confirm then
            st.confirm = nil
            if st.confirm_kind_buy then st.pad_seat = 'bid' end
        elseif st.settings_open then st.settings_open = false
        elseif st.tab == 'buy' and st.card_focus then st.pad_first, st.pad_first_id, st.pad_cats = 3, st.selected, false -- from the card back to its row
        elseif st.tab == 'buy' and st.pad_where == 'items' then st.pad_first, st.pad_first_id, st.pad_cats = 3, nil, true -- from the list back to its category
        else st.open = false end
        return
    end
    st.confirm_kind_buy = st.confirm ~= nil and st.confirm.kind == 'buy'
    if st.confirm then return end
    local turn = (PAD.pressed('r1') and 1 or 0) - (PAD.pressed('l1') and 1 or 0)
    if turn ~= 0 then
        local i = 1
        for k, tab in ipairs(TAB_ORDER) do if tab == st.tab then i = k end end
        st.tab = TAB_ORDER[(i - 1 + turn) % #TAB_ORDER + 1]
        st.settings_open = false
        st.pad_first, st.pad_first_id, st.pad_cats = 3, nil, st.tab == 'buy' and st.results == nil -- Buy starts in the sidebar
    end
    if st.tab == 'buy' and not st.settings_open then
        -- Left and Right walk the three panes: the sidebar, the list (its last row) and the card (its price box);
        -- Confirm goes deeper and Cancel comes back the same way. (ImGui moves on the same press, by geometry; the
        -- seat asked for here lands a frame or two later and is what stays.)
        if st.pad_where == 'cats' and PAD.pressed('right') then
            st.pad_first, st.pad_first_id, st.pad_cats = 3, st.pad_row, false
        elseif st.pad_where == 'items' and PAD.pressed('left') then
            st.pad_first, st.pad_first_id, st.pad_cats = 3, nil, true
        elseif st.pad_where == 'items' and PAD.pressed('right') then
            local id = st.selected or st.pad_row -- no card yet: the highlighted item's
            if id then
                if id ~= st.selected then select_item(id) end
                st.pad_seat = 'price'
            end
        end
        local step = (PAD.repeating('r2', 0.45, 0.12) and 1 or 0) - (PAD.repeating('l2', 0.45, 0.12) and 1 or 0)
        if step ~= 0 then
            local i = 1
            for k, e in ipairs(CAT_ORDER) do if e.cat == st.category then i = k end end
            local e = CAT_ORDER[(i - 1 + step) % #CAT_ORDER + 1]
            st.category, st.group = e.cat, e.group
            st.group_open[e.group] = true
            st.query[1], st.results = '', nil
            st.list_at = clock()
            -- the focus follows: in the sidebar it moves to the new category, anywhere else to the list's first row
            st.pad_first, st.pad_first_id, st.pad_cats = 3, nil, st.pad_where == 'cats'
            fetch_list(e.cat)
        end
        -- X and Y go by the pane the ring is in: the list's filters there, the picked item's own switches on its card
        if st.pad_where == 'card' then
            if PAD.pressed('options') and st.selected then toggle_watch(st.selected, st.stack) end
            if PAD.pressed('menu') and st.selected and I.get(st.selected).stack > 1 then
                st.stack = not st.stack
                st.buy.price[1] = ''
            end
        else
            if PAD.pressed('options') then settings.in_stock = not settings.in_stock save_settings() end
            if PAD.pressed('menu') then settings.usable = not settings.usable save_settings() end
            -- the sort sits above the list, where the ring doesn't go: the stick buttons turn it and flip it
            if PAD.pressed('l3') then
                local next_sort = { name = 'level', level = 'stock', stock = 'name' }
                settings.sort = next_sort[settings.sort or 'name'] or 'name'
                settings.sort_desc = SORT_DESC[settings.sort]
                save_settings()
            end
            if PAD.pressed('r3') then settings.sort_desc = not sort_desc() save_settings() end
        end
        if PAD.pressed('back') then settings.compare = not settings.compare save_settings() end
    end
    if st.tab == 'sell' and not st.settings_open then
        if PAD.pressed('options') then settings.sellable_only = not settings.sellable_only save_settings() end
        if PAD.pressed('menu') and st.sell.item then
            local r = I.get(st.sell.item)
            if r.stack > 1 then -- stack prices show with any count; listing one waits for a full stack
                st.sell.stack = not st.sell.stack
                st.sell.price[1], st.sell.fee, st.sell.asked = '', nil, nil
            end
        end
        -- Right from the bag is the price box; Left from the price box is the picked item (pad_price_box)
        local fo = U.anim.focus
        if PAD.pressed('right') and st.sell.item and fo and fo.key:sub(1, 5) == '##bag' and now_t - fo.at < 0.1 then st.pad_seat = 'price' end
    end
    if st.tab == 'sales' and not st.settings_open then
        -- the row the ring is on (any of its three buttons), or the first
        local fo = U.anim.focus
        local k = fo and now_t - fo.at < 0.1 and sales_row_key(fo.key) or nil
        local row = k and st.sales_rows and st.sales_rows[k] or (st.sales_rows and st.sales_rows[1])
        if row and PAD.pressed('options') then
            if st.sales_hist == row.key then st.sales_hist = nil else st.sales_hist = row.key fetch_history(row.id, row.stack) end
        end
        if row and PAD.pressed('menu') and may_trade() and st.cancel_pending == nil and st.sweep == nil and st.relist == nil and not st.sell.pending then
            fetch_history(row.id, row.stack)
            st.confirm = { kind = 'relist', slot = row.slot, item = row.id, page = row.page, key = row.key, price = row.price, stack = row.stack }
        end
    end
    if st.tab == 'watch' and not st.settings_open then
        local fo = U.anim.focus
        local k = fo and now_t - fo.at < 0.1 and watch_row_key(fo.key) or nil
        local e = k and st.watch_rows and st.watch_rows[k] or (st.watch_rows and st.watch_rows[1])
        if e and PAD.pressed('options') then toggle_watch(e.id, e.stack) end
        if e and PAD.pressed('menu') then -- its price, straight into the digit editor
            local id = '##under' .. watch_key(e.id, e.stack)
            st.pad_seat, st.pad_edit_now = id, id
        end
    end
    if st.tab == 'activity' and not st.settings_open then
        local step = (PAD.repeating('r2', 0.45, 0.12) and 1 or 0) - (PAD.repeating('l2', 0.45, 0.12) and 1 or 0)
        if step ~= 0 then st.act_page, st.act_top, st.pad_first, st.pad_first_id = st.act_page + step, true, 3, nil end -- (clamped where it's drawn)
        if PAD.pressed('options') then
            local f = { all = 'bought', bought = 'sold', sold = 'all' }
            st.act_filter, st.act_page, st.act_top = f[st.act_filter] or 'all', 1, true
        end
        if PAD.pressed('menu') then st.act_page, st.act_top = 1, true end
    end
    if st.settings_open then
        -- Y the next theme, X the next bell (or none), the way the dropdowns go
        if PAD.pressed('options') then
            local i = 1
            for n, th in ipairs(U.THEMES) do if th.id == (settings.theme or 'aurora') then i = n end end
            set_theme(U.THEMES[i % #U.THEMES + 1].id)
        end
        if PAD.pressed('menu') then
            if not settings.open_sound then
                settings.open_sound, settings.open_sound_id = true, OPEN_SOUNDS[1].id
                play_open_sound()
            else
                local i = 0
                for n, o in ipairs(OPEN_SOUNDS) do if o.id == settings.open_sound_id then i = n end end
                if i >= #OPEN_SOUNDS then settings.open_sound = false
                else settings.open_sound_id = OPEN_SOUNDS[i + 1].id play_open_sound() end
            end
            save_settings()
        end
    end
    if PAD.pressed('start') then st.settings_open = not st.settings_open end
end

local LEGEND = {
    -- Buy: the list's pane and the card each have their own (built in draw_legend)
    buy_list = { { 'left right', 'Panes' }, { 'l1 r1', 'Tabs' }, { 'l2 r2', 'Category' }, { 'l3', 'Sort' }, { 'r3', 'Flip' },
        { 'options', 'In stock' }, { 'menu', 'Usable' }, { 'back', 'Compare' } },
    buy_card = { { 'left right', 'Panes' }, { 'l1 r1', 'Tabs' }, { 'updown', 'Price' },
        { 'options', 'Watch' }, { 'menu', 'Single / stack' }, { 'start', 'Settings' } },
    sell = { { 'confirm', 'Select' }, { 'cancel', 'Back' }, { 'left right', 'Panes' }, { 'l1 r1', 'Tabs' }, { 'updown', 'Price' },
        { 'options', 'Sellable only' }, { 'menu', 'Single / stack' }, { 'start', 'Settings' } },
    sales = { { 'confirm', 'Press' }, { 'cancel', 'Close' }, { 'l1 r1', 'Tabs' }, { 'options', 'History' }, { 'menu', 'Relist' }, { 'start', 'Settings' } },
    watch = { { 'confirm', 'Open' }, { 'cancel', 'Close' }, { 'l1 r1', 'Tabs' }, { 'options', 'Unwatch' }, { 'menu', 'Tell me under' }, { 'start', 'Settings' } },
    activity = { { 'cancel', 'Close' }, { 'l1 r1', 'Tabs' }, { 'l2 r2', 'Page' }, { 'options', 'Filter' }, { 'menu', 'Newest' }, { 'start', 'Settings' } },
    settings = { { 'confirm', 'Toggle' }, { 'cancel', 'Close' }, { 'options', 'Theme' }, { 'menu', 'Sound' }, { 'start', 'Close' } },
    other = { { 'confirm', 'Select' }, { 'cancel', 'Back' }, { 'l1 r1', 'Tabs' }, { 'start', 'Settings' } },
    edit = { { 'updown', 'Digit' }, { 'left right', 'Column' }, { 'confirm', 'Keep' }, { 'cancel', 'Undo' } },
}
local function draw_legend(dl, x, y, w)
    dl:AddLine({ x + S(16), y }, { x + w - S(16), y }, u32(P.line, 0.8), 1)
    local items
    if st.pad_editing then items = LEGEND.edit
    elseif st.settings_open then items = LEGEND.settings
    elseif st.tab == 'buy' then
        -- Confirm and Cancel say what they do in the pane the ring is in, and X and Y what they do there
        local where = st.pad_where -- (held over a move: 'cats', 'items' or 'card')
        items = { { 'confirm', where == 'cats' and 'Open category' or where == 'card' and 'Price, then Bid' or 'Pick item' },
            { 'cancel', where == 'cats' and 'Close' or 'Back' } }
        local rest = where == 'card' and LEGEND.buy_card or LEGEND.buy_list
        for _, it in ipairs(rest) do
            if where == 'card' and it[1] == 'options' and st.selected and is_watched(st.selected, st.stack) then items[#items + 1] = { 'options', 'Unwatch' }
            else items[#items + 1] = it end
        end
    else items = LEGEND[st.tab] or LEGEND.other end
    local shown = {}
    for _, it in ipairs(items) do shown[#shown + 1] = { it[1], LANG.t(it[2]) } end
    items = shown
    -- measured by drawing off screen once, then centred
    local lw = PAD.legend(dl, -10000, -10000, items, 0)
    PAD.legend(dl, x + (w - lw) / 2, y + S(14), items, 1)
end

local function draw_main(t)
    local sw, sh = vana.ui.screen()
    local legend_h = (PAD.shown() and st.pad_focused) and S(28) or 0 -- the window the controller is in shows the legend
    local w, h = S(W.w), S(W.h) + legend_h
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
        -- kept on the screen from the next frame; this one draws where ImGui has the window (dragged past an edge it
        -- follows the mouse, whole, and comes back when let go)
        local cx, cy = math.max(0, math.min(x, sw - w)), math.max(0, math.min(y, sh - h))
        if cx ~= x or cy ~= y then imgui.SetWindowPos({ cx, cy }) end
        st.main = { x = x, y = y, w = w, h = h }
        local fade = math.min(1, (t - st.opened_at) * 4)
        shadow(dl, x, y, w, h, S(16), fade)
        panel(dl, x, y, w, h, P.bg, fade, S(16), P.line)
        st.hover_id = nil
        -- the controller's buttons are the focused window's (RootAndChildWindows): two open windows never both answer
        st.pad_focused = imgui.IsWindowFocused(3)
        -- (or a confirmation's, a window of its own that takes the focus: Cancel there closes it)
        if PAD.capturing() and (st.pad_focused or st.confirm) then pad_buttons() end
        -- ImGui keeps its navigation cursor hidden after a focus it didn't move there itself (the window opening, a
        -- row or box seated by the window), and a hidden cursor takes no Confirm until a D-pad press shows it: kept
        -- shown while the pad is in use, Confirm works wherever the focus was put
        if PAD.shown() and st.pad_focused and imgui.SetNavCursorVisible then imgui.SetNavCursorVisible(true) end
        st.pad_editing = false -- set again by a price box being edited, drawn below
        st.pad_where_now = nil -- which Buy pane has the focus ('cats', 'items'), found as it's drawn below
        if PAD.capturing() then PAD.claim() end -- X and Y are the window's, never ImGui's activate or window switcher
        -- the header (search box, buttons) and the tab row are out of the pad's reach: the bumpers and buttons do
        -- their jobs, and the ring never wanders up there from a list's top (ImGuiItemFlags_NoNav)
        local pad_nav = PAD.shown() and imgui.PushItemFlag ~= nil
        if pad_nav then imgui.PushItemFlag(2, true) end
        local hy = draw_header(dl, x, y, w, t)
        local ty = y + hy + S(10)
        draw_tabs(dl, x, ty, w)
        if pad_nav then imgui.PopItemFlag() end
        local by = ty + S(50)
        local bh = y + h - by - S(16) - legend_h
        if legend_h > 0 then draw_legend(dl, x, y + h - legend_h, w) end
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
        elseif st.tab == 'activity' then
            draw_activity(dl, x + S(16), by, w - S(32), bh, t)
        else
            draw_sales(dl, x + S(16), by, w - S(32), bh, t)
        end
        -- Compare: the gear under the mouse against what you wear, over everything
        if settings.compare and st.tab == 'buy' and st.hover_id and not st.confirm and not st.settings_open then
            local mx, my = imgui.GetMousePos()
            local hr = st.hover_rect
            if hr then mx, my = hr.x + hr.w - S(16), hr.y - S(8) end -- the focused row, not the mouse
            COMPARE.card(st.hover_id, mx, my, { t = t, wearer = wearer(), stack = hr ~= nil })
        else
            COMPARE.idle()
        end
        -- a move between rows leaves nothing focused for a frame, and the legend's words (and width) followed it, so
        -- the row jittered on every press: the pane holds until nothing has had the focus for a moment
        local where = st.card_focus and 'card' or st.pad_where_now
        if where then st.pad_where, st.pad_where_at = where, now_t
        elseif now_t - (st.pad_where_at or -1) > 0.25 then st.pad_where = nil end
        -- RootAndChildWindows (3): the lists, the bag and the sidebar are child windows, and a click there focuses them
        if imgui.IsWindowFocused(3) and imgui.IsKeyPressed(U.KEY_ESCAPE) and imgui.GetFrameCount() - FIELD.active_frame > 1 and not st.bind_capture then
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
    -- Japanese wanted but no Japanese font on this PC (Meiryo, Yu Gothic, MS Gothic: Windows has them; Wine may not):
    -- the text would be boxes, so the window stays English this session, and says so once
    if LANG.ja() and not F.japanese_font and not st.said_no_jp_font then
        st.said_no_jp_font = true
        LANG.set('en')
        I.forget_records()
        U.toast('warn', 'No Japanese font', 'Meiryo, Yu Gothic or MS Gothic is needed in C:\\Windows\\Fonts; the window stays English', 8, 'triangle-exclamation')
    end
    -- the controller: its reads since the last frame become ImGui's keys, while the window has it
    PAD.frame(t, { id = 'auctionhouse', capture = function () return st.open end, hold = st.pad_hold or false })
    st.pad_hold = false
    -- a Confirm that already did its work stays muted until it's let go, and a couple of frames past that
    if st.pad_mute == 'held' then
        if not PAD.down('confirm') then st.pad_mute = 2 end
    elseif st.pad_mute then
        st.pad_mute = st.pad_mute > 1 and st.pad_mute - 1 or nil
    end
    U.anim.pad_shown = PAD.shown()
    local fo = U.anim.focus
    local boxes = {}
    for id, f in pairs(field_state) do if f.focused or f.pad_on then boxes[#boxes + 1] = id .. (f.pad_on and '*' or '') end end
    local rowdbg = ''
    if st.pad_row and st.list_ids then
        for i, id in ipairs(st.list_ids) do if id == st.pad_row then rowdbg = string.format('row %d/%d %s, walk %s; ', i, #st.list_ids, I.name(id), tostring(st.walk_i)) break end end
    end
    st.pad_dbg = rowdbg .. string.format('boxes [%s] ', table.concat(boxes, ' ')) .. string.format('text box active %s, focus on %s (%.1fs ago), card focus %s, seat %s, window focused %s, cancels %d',
        tostring(imgui.IsAnyItemActive()), tostring(fo and fo.key), fo and (t - fo.at) or -1, tostring(st.card_focus), tostring(st.pad_seat),
        tostring(st.pad_focused), st.pad_cancels or 0) .. string.format(', seats %d, first %s/%s%s, pane %s', st.pad_seats or 0, tostring(st.pad_first), tostring(st.pad_first_id), st.pad_cats and ' (cats)' or '', tostring(st.pad_where))
    if st.pad_first and st.open then st.pad_first = st.pad_first - 1 if st.pad_first <= 0 then st.pad_first, st.pad_first_id, st.pad_cats = nil, nil, nil end end
    SEARCH.poll()
    PRICES.save()
    LEDGER.save()
    I.save_index()
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
        U.toast('danger', 'No answer', LANG.t('The house did not answer'), 5, 'hourglass-end')
    end
    if st.cancel_pending ~= nil and clock() - (st.cancel_at or 0) > LIMITS.reply then
        st.cancel_pending = nil
        U.toast('danger', 'No answer', 'The house did not answer the take-down: refresh My Sales to see where it stands', 6, 'hourglass-end')
    end
    relist_step()
    if st.open then
        -- what the house lists is asked a category at a time as you open them, as the game's own window does. Only when
        -- you ask a search to include the categories never opened on this server (the button under the results) are
        -- those asked, one at a time and spaced out; the answers are kept, so that's once per server
        if st.sweep_wanted and logged_in() and clock() - (st.sweep_at or 0) > 0.25 then
            local busy = false
            for k in pairs(st.fetching) do if tostring(k):sub(1, 3) == 'cat' then busy = true break end end
            if not busy then
                st.sweep_at = clock()
                st.sweep_tries = st.sweep_tries or {}
                local next_cat = nil
                for _, cat in ipairs(I.all_categories()) do
                    if not I.answered(cat) and (st.sweep_tries[cat] or 0) < 2 then next_cat = cat break end
                end
                if next_cat then
                    st.sweep_tries[next_cat] = (st.sweep_tries[next_cat] or 0) + 1
                    fetch_list(next_cat)
                else
                    st.sweep_wanted = false
                    I.save_index(true)
                    -- the search again, over everything now
                    local q = st.query[1] or ''
                    if st.results and #q >= 2 then st.results, st.result_total = I.search(q, 80) fetch_result_lists() end
                end
            end
        end
        if clock() - st.counter.at > LIMITS.scan then scan_counter() end
        -- walked away from the counter: the house closes, as the game's menu would
        if st.open and not settings.view_anywhere and not st.counter.near and st.counter.dist ~= nil then
            st.open = false
            say(LANG.t('You have left the auction counter'))
        end
        -- the bag and the gil, kept current (a purchase or a fee changes the gil a moment after the house replies)
        if clock() - st.inv_at > LIMITS.inventory then refresh_inventory() end
        if st.sweep and not st.sales_wait and clock() - st.sales_at >= SWEEP_GAP then
            if st.sweep.started then sweep_step() else sweep_send() end
        end
        if st.sales_dirty and st.sweep == nil and clock() - st.sales_at > LIMITS.sales and may_trade() then
            st.sales_dirty = false
            start_sweep()
        end
        if st.tab == 'sales' and not st.sales_open and st.sweep == nil and not st.sales_wait and may_trade() and clock() - st.sales_at > LIMITS.sales and logged_in() then
            start_sweep()
        end
        if st.sales_wait and clock() - st.sales_at > LIMITS.reply then
            st.sales_wait = false
            if st.sweep then st.sweep = nil st.sales_open = true end -- no answer: the sweep ends with what it has
        end
        draw_main(t)
    end
    U.draw_toasts(t)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

vana.events.on('load', function ()
    load_settings()
    apply_language()
    U.load_theme_files()
    U.apply_theme(settings.theme or 'aurora')
    configure_search()
    ensure_bind()
    PAD.setup('auctionhouse')
    vana.log('auctionhouse-vanacore ' .. addon.version .. ' loaded; search server ' .. tostring(st.search_where))
end)

vana.events.on('unload', function ()
    PAD.teardown('auctionhouse')
    save_settings()
    PRICES.save(true)
    LEDGER.save(true)
    I.save_index(true)
    SEARCH.cancel_all()
    I.release_icons()
    U.release_texture('badge')
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
        elseif st.sales_wait or st.sweep or clock() - st.sales_at < 2 then
            -- the server's AH pagination module narrates the sales list in chat; the window reads it and shows it instead
            local total = mes:match('^You have (%d+) items? listed for sale')
            local page, n = mes:match('^Current page: (%d+) of %d+%. Showing (%d+) items?')
            if total then
                st.sales_total = tonumber(total)
            elseif page then
                -- the page the rows that follow belong to: its old rows go, and a sweep notes it
                page, n = tonumber(page), tonumber(n)
                st.server_page, st.page_n, st.reply_page = page, n, page
                for key, row in pairs(st.sales) do if row.page == page then st.sales[key] = nil end end
                if st.sweep then
                    st.sweep.got = true
                    if st.sweep.seen[page] then st.sweep.done = true else st.sweep.seen[page] = true end
                end
            end
            if total or page or mes:find('No results for page', 1, true) then
                e.blocked = true
                return true
            end
        end
    elseif e.id == 0x00B then
        -- zoning: the house's state is gone with the zone
        st.open = false
        st.sales, st.sales_open, st.sales_wait = {}, false, false
        st.sweep, st.server_page, st.page_n, st.reply_page = nil, nil, nil, nil -- the house starts at page 1 again
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
    elseif what == 'buy' then open_window() st.tab, st.settings_open = 'buy', false
    elseif what == 'sell' then open_window() st.tab, st.settings_open = 'sell', false
    elseif what == 'sales' or what == 'listings' then open_window() st.tab, st.settings_open = 'sales', false
    elseif what == 'activity' then open_window() st.tab, st.settings_open = 'activity', false
    elseif what == 'settings' then open_window() st.settings_open = true
    elseif (what == 'search' or what == 's') and words[3] then
        open_window()
        st.tab = 'buy'
        st.query[1] = I.client_text(table.concat(words, ' ', 3))
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
            local hits = I.search(I.client_text(table.concat(words, ' ', 3)), 1)
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
        if tab == 'listings' then tab = 'sales' end
        if tab == 'buy' or tab == 'sell' or tab == 'sales' or tab == 'activity' or tab == 'watch' then st.tab = tab end
    elseif what == 'watch' then
        if words[3] == nil then
            open_window()
            st.tab = 'watch'
        else
            local id = tonumber(words[3])
            if id == nil then
                local hits = I.search(I.client_text(table.concat(words, ' ', 3)), 1)
                id = hits[1]
            end
            if id and I.rows[id] then toggle_watch(id, false) else say('No such item in the house') end
        end
    elseif what == 'lang' or what == 'language' then
        local pick = (words[3] or ''):lower()
        if pick == 'auto' or pick == 'en' or pick == 'ja' then
            settings.language = pick
            apply_language()
            save_settings()
        end
        say('Language: ' .. (settings.language or 'auto') .. ' (in use: ' .. LANG.lang() .. ') - /ah lang auto|en|ja')
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
    elseif what == 'bind' then
        -- /ah bind: the key; /ah bind <key> sets it (^ Ctrl, ! Alt, + Shift, then a letter, digit or F key); /ah bind off
        local arg = words[3] or ''
        if arg:lower() == 'off' then set_keybind('') say('No key opens the house')
        elseif arg ~= '' then set_keybind(arg) say(arg .. ' opens the house')
        else say(((settings.keybind or '') ~= '' and (settings.keybind .. ' opens the house') or 'No key opens the house') .. '. /ah bind <key> (^ Ctrl, ! Alt, + Shift), or /ah bind off') end
    elseif what == 'sound' then
        -- /ah sound: which bell; /ah sound off|on; /ah sound <name> picks one ('small bell', small_bell or small) and plays it
        local arg = table.concat(words, ' ', 3):lower():gsub('[%s_]+', ' '):gsub('^ ', ''):gsub(' $', '')
        local found
        for _, o in ipairs(OPEN_SOUNDS) do
            local n = o.name:lower()
            if arg ~= '' and (n == arg or n:sub(1, #arg) == arg) then found = o break end
        end
        if arg == 'off' or arg == 'on' then
            settings.open_sound = arg == 'on' save_settings()
            say('Sound as it opens: ' .. arg)
        elseif found then
            settings.open_sound, settings.open_sound_id = true, found.id save_settings()
            play_open_sound()
            say('Sound as it opens: ' .. found.name)
        else
            local names = {}
            for _, o in ipairs(OPEN_SOUNDS) do names[#names + 1] = o.name end
            local cur = 'off'
            if settings.open_sound then
                for _, o in ipairs(OPEN_SOUNDS) do if o.id == settings.open_sound_id then cur = o.name end end
            end
            say('Sound as it opens: ' .. cur .. '. The bells: ' .. table.concat(names, ', ') .. ', or off')
        end
    elseif what == 'opacity' and tonumber(words[3]) then
        settings.opacity = math.max(40, math.min(100, tonumber(words[3]))) / 100 save_settings()
    elseif what == 'scale' and tonumber(words[3]) then
        settings.scale = math.max(50, math.min(300, tonumber(words[3]))) save_settings()
    elseif what == 'refresh' then
        st.lists, st.hist = {}, {}
        if st.open then fetch_list(st.category) if st.selected then select_item(st.selected) end end
    elseif what == 'pad' then
        -- /ah pad: the controller's state; /ah pad on|off; /ah pad <button> [frames] and /ah pad stick <lx> <ly> [frames]
        -- press it as a controller would (for testing without one)
        local arg = words[3] and words[3]:lower() or nil
        if arg == nil then say(PAD.describe()) say(tostring(st.pad_dbg))
        elseif arg == 'on' or arg == 'off' then PAD.set_enabled(arg == 'on') say('Game pad support ' .. arg .. ' (for every addon: vanacore.ini [addons] gamepad)')
        elseif arg == 'stick' then PAD.inject({ lx = tonumber(words[4]) or 0, ly = tonumber(words[5]) or 0 }, tonumber(words[6]) or 3)
        else PAD.inject({ [arg] = true }, tonumber(words[4]) or 3) end
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
        say('/ah [show|hide|buy|sell|listings|activity|watch [<id or name>]|search <name>|pick <id or name>|settings|theme <name>|server <host[:port]|auto>|scale <percent>|opacity <percent>|refresh|debug]')
    end
    return true
end)
