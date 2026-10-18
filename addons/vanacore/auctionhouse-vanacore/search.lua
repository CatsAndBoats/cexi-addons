-- The search server, from an addon: what the game asks it for the auction house (a category's items and their stock,
-- an item's sale history), spoken directly over TCP. LandSandBoat's search protocol: a length-prefixed packet, Blowfish
-- over most of it with a key made from a fixed 16 bytes plus 4 random bytes the packet carries in the clear, an MD5 of
-- the payload inside. The reply uses the same key plus 4 bytes from the request. Sockets are non-blocking and driven
-- from the frame, so the game never waits on the network.
local ffi = require('ffi')
local bit = require('bit')
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local TABLES = require('bf_tables')

local M = { host = nil, port = 54002, timeout = 6, log = nil }

local function u32(v) return v % 4294967296 end

-------------------------------------------------------------------------------
-- MD5
-------------------------------------------------------------------------------

local MD5_K, MD5_S = {}, {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}
for i = 1, 64 do MD5_K[i] = math.floor(math.abs(math.sin(i)) * 4294967296) end

local function rol(x, n) return u32(bor(lshift(x, n), rshift(x, 32 - n))) end

local function md5(s)
    local len = #s
    s = s .. '\128' .. string.rep('\0', (55 - len) % 64)
    local bits = len * 8
    s = s .. string.char(bits % 256, math.floor(bits / 256) % 256, math.floor(bits / 65536) % 256, math.floor(bits / 16777216) % 256, 0, 0, 0, 0)
    local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for chunk = 1, #s, 64 do
        local m = {}
        for i = 0, 15 do
            local p = chunk + i * 4
            m[i] = s:byte(p) + s:byte(p + 1) * 256 + s:byte(p + 2) * 65536 + s:byte(p + 3) * 16777216
        end
        local a, b, c, d = a0, b0, c0, d0
        for i = 0, 63 do
            local f, g
            if i < 16 then f = bor(band(b, c), band(bit.bnot(b), d)) g = i
            elseif i < 32 then f = bor(band(d, b), band(bit.bnot(d), c)) g = (5 * i + 1) % 16
            elseif i < 48 then f = bxor(b, bxor(c, d)) g = (3 * i + 5) % 16
            else f = bxor(c, bor(b, bit.bnot(d))) g = (7 * i) % 16 end
            local tmp = d
            d = c
            c = b
            b = u32(b + rol(u32(a + u32(f) + MD5_K[i + 1] + m[g]), MD5_S[i + 1]))
            a = tmp
        end
        a0, b0, c0, d0 = u32(a0 + a), u32(b0 + b), u32(c0 + c), u32(d0 + d)
    end
    local function le(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
    return le(a0) .. le(b0) .. le(c0) .. le(d0)
end
M.md5 = md5

-------------------------------------------------------------------------------
-- Blowfish, as LandSandBoat's: the round function is its own (TT in blowfish.cpp), not the textbook one
-------------------------------------------------------------------------------

local function TT(x, S)
    local a = bxor(band(S[256 + band(rshift(x, 8), 0xff)], 1), 32)
    local b = bxor(band(S[768 + band(rshift(x, 24), 0xff)], 1), 32)
    return u32(a + b + S[512 + band(rshift(x, 16), 0xff)] + S[band(x, 0xff)])
end

local function encipher(xl, xr, P, S)
    for i = 0, 15 do
        xl = u32(bxor(xl, P[i]))
        xr = u32(bxor(TT(xl, S), xr))
        xl, xr = xr, xl
    end
    xl, xr = xr, xl
    xr = u32(bxor(xr, P[16]))
    xl = u32(bxor(xl, P[17]))
    return xl, xr
end

local function decipher(xl, xr, P, S)
    for i = 17, 2, -1 do
        xl = u32(bxor(xl, P[i]))
        xr = u32(bxor(TT(xl, S), xr))
        xl, xr = xr, xl
    end
    xl, xr = xr, xl
    xr = u32(bxor(xr, P[1]))
    xl = u32(bxor(xl, P[0]))
    return xl, xr
end

-- the key schedule: the boxes XORed with the key, then run through the cipher
local function blowfish_init(key)
    local P, S = {}, {}
    for i = 0, 17 do P[i] = TABLES[i + 1] end
    for i = 0, 1023 do S[i] = TABLES[19 + i] end
    local j = 0
    for i = 0, 17 do
        local data = 0
        for _ = 1, 4 do
            -- the server reads the key as signed bytes: one of 0x80 or more sign-extends over the word (a quirk kept)
            local b = key:byte(j + 1)
            data = u32(bor(lshift(data, 8), b >= 128 and (b - 256) or b))
            j = (j + 1) % #key
        end
        P[i] = u32(bxor(P[i], data))
    end
    local l, r = 0, 0
    for i = 0, 17, 2 do
        l, r = encipher(l, r, P, S)
        P[i], P[i + 1] = l, r
    end
    for i = 0, 1023, 2 do
        l, r = encipher(l, r, P, S)
        S[i], S[i + 1] = l, r
    end
    return P, S
end

local function rd32(s, off) return s:byte(off + 1) + s:byte(off + 2) * 256 + s:byte(off + 3) * 65536 + s:byte(off + 4) * 16777216 end
local function rd16(s, off) return s:byte(off + 1) + s:byte(off + 2) * 256 end
local function wr32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function wr16(v) return string.char(v % 256, math.floor(v / 256) % 256) end

-- the words from byte 8 on, as many whole pairs as (length - 12) / 4 holds, through the cipher
local function crypt(buf, P, S, fn)
    local len = #buf
    local n = math.floor((len - 12) / 4)
    n = n - n % 2
    local out = { buf:sub(1, 8) }
    for i = 0, n - 1, 2 do
        local off = 8 + i * 4
        local l, r = fn(rd32(buf, off), rd32(buf, off + 4), P, S)
        out[#out + 1] = wr32(l) .. wr32(r)
    end
    out[#out + 1] = buf:sub(8 + n * 4 + 1)
    return table.concat(out)
end

-- the 16 bytes every search packet's key starts with (search_handler.h)
local KEY = string.char(0x30, 0x73, 0x3D, 0x6D, 0x3C, 0x31, 0x49, 0x5A, 0x32, 0x7A, 0x42, 0x43, 0x63, 0x38, 0x7B, 0x7E)

-- a request, sealed: `payload` is the bytes from 8 to the tail. Returns the bytes to send and the 8 key bytes the
-- reply will be keyed with.
local function seal(payload)
    local tail = wr32(math.random(0, 0xFFFFFFFF))   -- the 4 bytes the reply's key also takes, sent enciphered
    local nonce = wr32(math.random(0, 0xFFFFFFFF)) -- the 4 bytes at the end, sent in the clear
    local len = 8 + #payload + 0x18
    local body = payload .. tail
    local head = wr16(len) .. wr16(0) .. 'IXFF'
    local hash = md5(body)
    local buf = head .. body .. hash .. nonce
    local P, S = blowfish_init(md5(KEY .. nonce)) -- the cipher's key is the MD5 of the 20 key bytes
    buf = crypt(buf, P, S, encipher)
    return buf:sub(1, len - 4) .. nonce, nonce .. tail
end

-- a reply, opened: the plaintext, or nil and why
local function open(buf, keytail)
    local P, S = blowfish_init(md5(KEY .. keytail)) -- all 24 key bytes this time
    local plain = crypt(buf, P, S, decipher)
    local len = #plain
    if len < 0x20 then return nil, 'short' end
    local hash = md5(plain:sub(9, len - 0x14))
    if hash ~= plain:sub(len - 0x13, len - 4) then return nil, 'bad hash' end
    return plain
end

-------------------------------------------------------------------------------
-- The requests the auction house makes
-------------------------------------------------------------------------------

local TYPE = { AH_LIST = 0x15, AH_MORE = 0x10, HISTORY_SINGLE = 0x05, HISTORY_STACK = 0x06 }

-- a category's items: every item the house lists in it, with how many singles and stacks are up
local function list_payload(category)
    local p = {}
    for _ = 1, 0x20 - 8 do p[#p + 1] = 0 end
    p[0x0B - 8 + 1] = TYPE.AH_LIST
    p[0x12 - 8 + 1] = 1 -- one sort parameter
    p[0x16 - 8 + 1] = category
    p[0x18 - 8 + 1] = 9 -- by name
    local out = {}
    for i = 1, #p do out[i] = string.char(p[i]) end
    return table.concat(out)
end

-- an item's last ten sales (singles or stacks), with its stock
local function history_payload(item, stack)
    local p = {}
    for _ = 1, 0x18 - 8 do p[#p + 1] = 0 end
    p[0x0B - 8 + 1] = stack and TYPE.HISTORY_STACK or TYPE.HISTORY_SINGLE
    p[0x12 - 8 + 1] = item % 256
    p[0x13 - 8 + 1] = math.floor(item / 256)
    p[0x15 - 8 + 1] = stack and 1 or 0
    local out = {}
    for i = 1, #p do out[i] = string.char(p[i]) end
    return table.concat(out)
end

local function parse_list(plain)
    local size = rd16(plain, 0x08)
    local total = rd16(plain, 0x0E)
    local last = band(plain:byte(0x0B), 0x80) ~= 0
    local n = math.max(0, math.floor((size - 0x18) / 10))
    local items = {}
    for i = 0, n - 1 do
        local off = 0x18 + 10 * i
        items[#items + 1] = { id = rd16(plain, off), single = rd32(plain, off + 2), stack = rd32(plain, off + 6) }
    end
    return items, total, last
end

local function parse_history(plain)
    local size = rd16(plain, 0x08)
    local n = size >= 0x20 and math.floor((size - 0x20) / 40) or 0
    local sales = {}
    for i = 0, n - 1 do
        local off = 0x20 + 40 * i
        local function name(at)
            local s = plain:sub(at + 1, at + 15)
            local z = s:find('\0', 1, true)
            return z and s:sub(1, z - 1) or s
        end
        sales[#sales + 1] = { price = rd32(plain, off), date = rd32(plain, off + 4), seller = name(off + 8), buyer = name(off + 0x18) }
    end
    return { item = rd16(plain, 0x18), stock = rd32(plain, 0x1A), category = rd16(plain, 0x1E), sales = sales }
end

-------------------------------------------------------------------------------
-- Winsock, without blocking
-------------------------------------------------------------------------------

pcall(ffi.cdef, [[
typedef uintptr_t ah_SOCKET;
typedef struct { unsigned short wVersion; unsigned short wHighVersion; char szDescription[257]; char szSystemStatus[129]; unsigned short iMaxSockets; unsigned short iMaxUdpDg; char* lpVendorInfo; } ah_WSADATA;
struct ah_sockaddr_in { short sin_family; unsigned short sin_port; unsigned long s_addr; char sin_zero[8]; };
struct ah_fd_set { unsigned int fd_count; ah_SOCKET fd_array[64]; };
struct ah_timeval { long tv_sec; long tv_usec; };
struct ah_hostent { char* h_name; char** h_aliases; short h_addrtype; short h_length; char** h_addr_list; };
int WSAStartup(unsigned short v, void* d);
ah_SOCKET socket(int af, int type, int proto);
int connect(ah_SOCKET s, const void* name, int namelen);
int send(ah_SOCKET s, const char* buf, int len, int flags);
int recv(ah_SOCKET s, char* buf, int len, int flags);
int closesocket(ah_SOCKET s);
int WSAGetLastError(void);
unsigned long inet_addr(const char* cp);
unsigned short htons(unsigned short v);
int ioctlsocket(ah_SOCKET s, long cmd, void* argp);
int select(int n, void* r, void* w, void* e, void* t);
void* gethostbyname(const char* name);
]])
-- (pointer parameters are void* and the structs are cast at the call: another addon state may have declared these
-- functions with its own struct types, and a redeclaration is refused)
local function vp(x) return ffi.cast('void*', x) end
local has_ws, ws = pcall(ffi.load, 'ws2_32') -- absent off Windows (tests on the Mac)
if has_ws then
    local wsa = ffi.new('ah_WSADATA')
    ws.WSAStartup(0x0202, vp(wsa))
end
local INVALID = has_ws and ffi.cast('ah_SOCKET', -1) or nil
local FIONBIO = -2147195266 -- 0x8004667E as a signed long
local WOULDBLOCK = 10035

local function resolve(host)
    local addr = ws.inet_addr(host)
    if addr ~= 0xFFFFFFFF then return addr end
    local he = ffi.cast('struct ah_hostent*', ws.gethostbyname(host)) -- blocks for a DNS lookup; Windows caches it after the first
    if he == nil or he.h_addr_list == nil or he.h_addr_list[0] == nil then return nil end
    return ffi.cast('unsigned long*', he.h_addr_list[0])[0]
end

local function ready(sock, write)
    local set = ffi.new('struct ah_fd_set')
    set.fd_count = 1
    set.fd_array[0] = sock
    local tv = ffi.new('struct ah_timeval', 0, 0)
    local n = write and ws.select(0, nil, vp(set), nil, vp(tv)) or ws.select(0, vp(set), nil, nil, vp(tv))
    return n > 0
end

-------------------------------------------------------------------------------
-- The queue: one request at a time, each a small state machine stepped from the frame
-------------------------------------------------------------------------------

local queue, current = {}, nil
local recvbuf = ffi.new('char[8192]')
local addr_cache = {}

local function log(text)
    if M.log then M.log(text) end
end

local function finish(result, err)
    local req = current
    current = nil
    if req.sock then ws.closesocket(req.sock) end
    if req.cb then
        local ok, e = pcall(req.cb, result, err)
        if not ok then log('callback: ' .. tostring(e)) end
    end
end

local function start(req)
    if not has_ws then finish(nil, 'no winsock') return end
    if not M.host then finish(nil, 'no search server set') return end
    local addr = addr_cache[M.host]
    if addr == nil then
        addr = resolve(M.host)
        if addr == nil then finish(nil, 'cannot resolve ' .. M.host) return end
        addr_cache[M.host] = addr
    end
    local sock = ws.socket(2, 1, 6)
    if sock == INVALID then finish(nil, 'no socket') return end
    local nb = ffi.new('unsigned long[1]', 1)
    ws.ioctlsocket(sock, FIONBIO, vp(nb))
    local sa = ffi.new('struct ah_sockaddr_in')
    sa.sin_family, sa.sin_port, sa.s_addr = 2, ws.htons(M.port), addr
    local r = ws.connect(sock, vp(sa), ffi.sizeof(sa))
    if r ~= 0 and ws.WSAGetLastError() ~= WOULDBLOCK then
        ws.closesocket(sock)
        finish(nil, 'connect failed (' .. ws.WSAGetLastError() .. ')')
        return
    end
    req.sock, req.state, req.started, req.data = sock, 'connecting', os.clock(), ''
    req.wire, req.keytail = seal(req.payload)
end

local function step()
    local req = current
    if req == nil then
        if #queue == 0 then return end
        current = table.remove(queue, 1)
        start(current)
        return
    end
    if os.clock() - req.started > M.timeout then finish(nil, 'timed out') return end
    if req.state == 'connecting' then
        if ready(req.sock, true) then req.state = 'send' end
    end
    if req.state == 'send' then
        local n = ws.send(req.sock, req.wire, #req.wire, 0)
        if n == #req.wire then req.state = 'read' req.data = ''
        elseif n < 0 and ws.WSAGetLastError() ~= WOULDBLOCK then finish(nil, 'send failed') return end
    end
    if req.state == 'read' then
        while ready(req.sock, false) do
            local n = ws.recv(req.sock, recvbuf, 8192, 0)
            if n == 0 then finish(nil, 'closed') return end
            if n < 0 then
                if ws.WSAGetLastError() ~= WOULDBLOCK then finish(nil, 'recv failed') return end
                break
            end
            req.data = req.data .. ffi.string(recvbuf, n)
        end
        -- whole packets, as they complete
        while #req.data >= 2 do
            local len = rd16(req.data, 0)
            if len < 0x20 or #req.data < len then break end
            local packet = req.data:sub(1, len)
            req.data = req.data:sub(len + 1)
            local plain, err = open(packet, req.keytail)
            if plain == nil then finish(nil, err) return end
            if req.kind == 'list' then
                local items, total, last = parse_list(plain)
                req.items = req.items or {}
                for _, it in ipairs(items) do req.items[#req.items + 1] = it end
                if last or #req.items >= total then finish({ items = req.items, total = total }) return end
                ws.send(req.sock, req.wire, #req.wire, 0) -- the next page: the server answers any packet with it
            else
                finish(parse_history(plain))
                return
            end
        end
    end
end

-- every frame
function M.poll()
    local ok, err = pcall(step)
    if not ok then
        log('poll: ' .. tostring(err))
        if current then finish(nil, 'error') end
    end
end

function M.list(category, cb)
    queue[#queue + 1] = { kind = 'list', payload = list_payload(category), cb = cb }
end

function M.history(item, stack, cb)
    queue[#queue + 1] = { kind = 'history', payload = history_payload(item, stack), cb = cb }
end

function M.pending()
    return #queue + (current and 1 or 0)
end

function M.cancel_all()
    queue = {}
    if current then finish(nil, 'cancelled') end
end

-- for tests: run the queue to completion, waiting on the socket (never from the game's frame)
function M.drain(max_seconds)
    local t0 = os.clock()
    while (current or #queue > 0) and os.clock() - t0 < (max_seconds or 5) do step() end
end

M._blowfish_init, M._encipher, M._decipher, M._seal, M._open, M._crypt = blowfish_init, encipher, decipher, seal, open, crypt
M._list_payload, M._history_payload = list_payload, history_payload

return M
