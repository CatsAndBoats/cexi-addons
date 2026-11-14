-- Map DATs as textures. A map DAT is the game's own texture file: a chain of chunks (name, then a word whose low
-- seven bits are the kind and the next nineteen its length in 16-byte units), one of them a picture (kind 0x20):
--   a flag byte, a 16-byte name, a BITMAPINFOHEADER (40 bytes: width at +4, height at +8), then
--   flag 0xA1: 'DXT3' backwards, the data's size, a block size, and the DXT3 blocks, top row first
--   flag 0xB1 (and the other 8-bit kinds): 256 colours of four bytes (blue, green, red, and an alpha that is whole
--              at 0x80), then a byte a pixel
-- The DXT3 ones (the map pack's, 4 MB at 2048 x 2048) go to Direct3D as they are, which takes a few milliseconds; the
-- 8-bit ones (most of the game's own) are spread to 32 bits here. Textures are made through the device VanaCore hands
-- addons, which is the same call on its Direct3D 11 and 12 renderers as on the game's Direct3D 8.
--
-- A cache keeps what was shown lately, under a budget, and releases the rest: nothing is read from disk in a frame
-- that already has its texture.
--
-- Smaller copies. VanaCore draws an addon's texture from its top level alone (a texture's mip levels are never
-- sampled), so a 2048 map shown 700 pixels wide would be read one texel in three: thin lines break up and shimmer as
-- the map moves. So each large map gets a half-size and a quarter-size copy of its own, averaged from the full picture
-- (X.pick takes the one that fits the size it's drawn at). They are made over the frames after the map first shows,
-- a few milliseconds a frame, and the full picture is drawn until they are ready.
local ffi = require('ffi')
local bit = require('bit')

-- (epoch: counts the times textures were let go, for whoever holds one across frames)
local X = { cache = {}, bytes = 0, budget = 64 * 1024 * 1024, clock = 0, loads = 0, last_ms = 0, epoch = 0 }

local FMT_DXT3, FMT_A8R8G8B8, POOL_MANAGED = 0x33545844, 21, 1
local SLOT = { release = 2, create_texture = 20, lock = 16, unlock = 17 }

pcall(ffi.cdef, 'typedef struct { int pitch; void* bits; } vmaps_locked_rect;')

local device = nil
local function get_device()
    if device == nil then
        local d = vana.ashita.object('device')
        if d ~= nil then device = ffi.cast('void*', d) end
    end
    return device
end

local function vcall(obj, slot, sig)
    return ffi.cast(sig, ffi.cast('void***', obj)[0][slot])
end

local function release(tex)
    if tex == nil then return end
    pcall(function () vcall(tex, SLOT.release, 'unsigned long (__stdcall *)(void*)')(tex) end)
end

-- a texture of that size and format, filled by `fill(bits, pitch)`; nil and why
local function make(w, h, format, fill)
    local dev = get_device()
    if dev == nil then return nil, 'no Direct3D device' end
    local holder = ffi.new('void*[1]')
    local ok, hr = pcall(function ()
        return vcall(dev, SLOT.create_texture,
            'long (__stdcall *)(void*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void**)')(dev, w, h, 1, 0, format, POOL_MANAGED, holder)
    end)
    if not ok or hr ~= 0 or holder[0] == nil then return nil, 'CreateTexture failed (' .. tostring(hr) .. ')' end
    local tex = holder[0]
    local rect = ffi.new('vmaps_locked_rect')
    local ok2, hr2 = pcall(function ()
        return vcall(tex, SLOT.lock, 'long (__stdcall *)(void*, uint32_t, vmaps_locked_rect*, void*, uint32_t)')(tex, 0, rect, nil, 0)
    end)
    if not ok2 or hr2 ~= 0 or rect.bits == nil then
        release(tex)
        return nil, 'LockRect failed (' .. tostring(hr2) .. ')'
    end
    local ok3, err = pcall(fill, rect.bits, rect.pitch)
    pcall(function () vcall(tex, SLOT.unlock, 'long (__stdcall *)(void*, uint32_t)')(tex, 0) end)
    if not ok3 then
        release(tex)
        return nil, tostring(err)
    end
    return tex
end

-- The picture in a map DAT: { w, h, kind = 'dxt3' | 'indexed', at = offset of its data, size } or nil and why.
local function parse(data)
    local n = #data
    local p = ffi.cast('const uint8_t*', data)
    local function u32(o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
    local off = 0
    while true do
        if off + 16 + 17 + 40 + 12 > n then return nil, 'no picture in the file' end
        local word = u32(off + 4)
        local kind, size = word % 128, (math.floor(word / 128) % 0x80000) * 16
        if kind == 0x20 then break end
        if size == 0 then return nil, 'no picture in the file' end
        off = off + size
    end
    local head = off + 16
    local flag = p[head]
    local info = head + 17
    local w, h = u32(info + 4), u32(info + 8)
    local body = info + 40
    if w < 4 or h < 4 or w > 4096 or h > 4096 then return nil, 'an odd picture size' end
    if flag == 0xA1 then
        local tag = ffi.string(p + body, 4)
        if tag ~= '3TXD' then return nil, 'a compressed picture that is not DXT3 (' .. tag .. ')' end
        local size = u32(body + 4)
        if size ~= w * h or body + 12 + size > n then return nil, 'a short DXT3 picture' end
        return { w = w, h = h, kind = 'dxt3', at = body + 12, size = size }
    end
    if body + 1024 + w * h > n then return nil, 'a short picture' end
    return { w = w, h = h, kind = 'indexed', at = body, size = w * h }
end

-- A broken 8-bit copy. Twelve of the map pack's pictures (Ranguemont Pass 1, Toraimarai Canal 1-2, Ordelle's Caves
-- 1-4, Outer Horutoto Ruins 5-6, Fei'Yin 1-3; the same files in its 2048 and 1024 sets) are 512-pixel 8-bit copies
-- whose colours don't come out of their palette: they draw as a few posterised tones in streaks with a solid red,
-- white or grey band where the torn edge should be see-through. What gives them away: the picture's outermost ring of
-- pixels is mostly one opaque colour, where a map's torn edge is the palette's transparent entry. Such a copy is passed
-- over for the next place the map is (the game's own picture), never when it is the last.
local function broken_copy(p, pic)
    if pic.kind ~= 'indexed' then return false end
    local w, h = pic.w, pic.h
    local px = p + pic.at + 1024
    local counts, total = {}, 0
    local function add(i) counts[i] = (counts[i] or 0) + 1 total = total + 1 end
    for x = 0, w - 1 do add(px[x]) add(px[(h - 1) * w + x]) end
    for y = 1, h - 2 do add(px[y * w]) add(px[y * w + w - 1]) end
    local best, n = nil, 0
    for i, c in pairs(counts) do if c > n then best, n = i, c end end
    local alpha = p[pic.at + best * 4 + 3]
    return alpha ~= 0 and n / total > 0.4
end

local function load(path, strict)
    local f = io.open(path, 'rb')
    if f == nil then return nil, "can't open the file" end
    local data = f:read('*a')
    f:close()
    if data == nil or #data < 128 then return nil, 'an empty file' end
    local pic, why = parse(data)
    if pic == nil then return nil, why end
    if strict and broken_copy(ffi.cast('const uint8_t*', data), pic) then return nil, 'a broken 8-bit copy (passed over)' end
    local p = ffi.cast('const uint8_t*', data)
    local tex, err, bytes
    if pic.kind == 'dxt3' then
        bytes = pic.size
        tex, err = make(pic.w, pic.h, FMT_DXT3, function (bits) ffi.copy(bits, p + pic.at, pic.size) end)
    else
        bytes = pic.w * pic.h * 4
        tex, err = make(pic.w, pic.h, FMT_A8R8G8B8, function (bits, pitch)
            local pal = ffi.new('int32_t[256]') -- (signed: what the bit operations give)
            local src = p + pic.at
            for i = 0, 255 do
                local a = src[i * 4 + 3] * 2
                if a > 255 then a = 255 end
                pal[i] = bit.bor(src[i * 4], bit.lshift(src[i * 4 + 1], 8), bit.lshift(src[i * 4 + 2], 16), bit.lshift(a, 24))
            end
            local px = src + 1024
            local w, h = pic.w, pic.h
            for y = 0, h - 1 do
                -- (the 8-bit pictures are kept bottom row first, as a Windows bitmap is)
                local row = ffi.cast('int32_t*', ffi.cast('uint8_t*', bits) + y * pitch)
                local from = px + (h - 1 - y) * w
                for x = 0, w - 1 do row[x] = pal[from[x]] end
            end
        end)
    end
    if tex == nil then return nil, err end
    local e = { tex = tex, w = pic.w, h = pic.h, bytes = bytes, kind = pic.kind, levels = {} }
    -- (the file's bytes are kept until the smaller copies are made of them)
    if pic.w >= 1024 and pic.w == pic.h then e.source = { data = data, pic = pic } end
    return e
end

-------------------------------------------------------------------------------
-- The smaller copies
-------------------------------------------------------------------------------

local WORK = { queue = {}, running = false, budget_ms = 2.5 }

-- rows y0 .. y1-1 of the half-size picture (32 bits a pixel), from DXT3 blocks: each 4 x 4 block gives 2 x 2 pixels
local function half_from_dxt3(src, w, out, y0, y1)
    local hw = w / 2
    local bw = w / 4
    local pr, pg, pb = ffi.new('int[4]'), ffi.new('int[4]'), ffi.new('int[4]')
    local band, rshift, lshift, bor = bit.band, bit.rshift, bit.lshift, bit.bor
    for by = y0 / 2, y1 / 2 - 1 do
        local row = src + by * bw * 16
        local o0, o1 = out + (by * 2) * hw, out + (by * 2 + 1) * hw
        for bx = 0, bw - 1 do
            local b = row + bx * 16
            local c0, c1 = b[8] + b[9] * 256, b[10] + b[11] * 256
            local r0, g0, b0 = rshift(c0, 11) * 8 + rshift(c0, 13), band(rshift(c0, 5), 63) * 4 + band(rshift(c0, 9), 3), band(c0, 31) * 8 + band(rshift(c0, 2), 7)
            local r1, g1, b1 = rshift(c1, 11) * 8 + rshift(c1, 13), band(rshift(c1, 5), 63) * 4 + band(rshift(c1, 9), 3), band(c1, 31) * 8 + band(rshift(c1, 2), 7)
            pr[0], pg[0], pb[0] = r0, g0, b0
            pr[1], pg[1], pb[1] = r1, g1, b1
            pr[2], pg[2], pb[2] = (2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3
            pr[3], pg[3], pb[3] = (r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3
            -- the four rows of two-bit picks, and of four-bit alphas
            local i0, i1, i2, i3 = b[12], b[13], b[14], b[15]
            local a0, a1, a2, a3 = b[0] + b[1] * 256, b[2] + b[3] * 256, b[4] + b[5] * 256, b[6] + b[7] * 256
            -- top left: pixels (0,0) (1,0) (0,1) (1,1); top right: (2,0) (3,0) (2,1) (3,1); and the same below
            local k0, k1, k2, k3 = band(i0, 3), band(rshift(i0, 2), 3), band(i1, 3), band(rshift(i1, 2), 3)
            local al = band(a0, 15) + band(rshift(a0, 4), 15) + band(a1, 15) + band(rshift(a1, 4), 15)
            o0[bx * 2] = bor(rshift(pb[k0] + pb[k1] + pb[k2] + pb[k3], 2), lshift(rshift(pg[k0] + pg[k1] + pg[k2] + pg[k3], 2), 8),
                lshift(rshift(pr[k0] + pr[k1] + pr[k2] + pr[k3], 2), 16), lshift(rshift(al * 17, 2), 24))
            k0, k1, k2, k3 = band(rshift(i0, 4), 3), rshift(i0, 6), band(rshift(i1, 4), 3), rshift(i1, 6)
            al = band(rshift(a0, 8), 15) + rshift(a0, 12) + band(rshift(a1, 8), 15) + rshift(a1, 12)
            o0[bx * 2 + 1] = bor(rshift(pb[k0] + pb[k1] + pb[k2] + pb[k3], 2), lshift(rshift(pg[k0] + pg[k1] + pg[k2] + pg[k3], 2), 8),
                lshift(rshift(pr[k0] + pr[k1] + pr[k2] + pr[k3], 2), 16), lshift(rshift(al * 17, 2), 24))
            k0, k1, k2, k3 = band(i2, 3), band(rshift(i2, 2), 3), band(i3, 3), band(rshift(i3, 2), 3)
            al = band(a2, 15) + band(rshift(a2, 4), 15) + band(a3, 15) + band(rshift(a3, 4), 15)
            o1[bx * 2] = bor(rshift(pb[k0] + pb[k1] + pb[k2] + pb[k3], 2), lshift(rshift(pg[k0] + pg[k1] + pg[k2] + pg[k3], 2), 8),
                lshift(rshift(pr[k0] + pr[k1] + pr[k2] + pr[k3], 2), 16), lshift(rshift(al * 17, 2), 24))
            k0, k1, k2, k3 = band(rshift(i2, 4), 3), rshift(i2, 6), band(rshift(i3, 4), 3), rshift(i3, 6)
            al = band(rshift(a2, 8), 15) + rshift(a2, 12) + band(rshift(a3, 8), 15) + rshift(a3, 12)
            o1[bx * 2 + 1] = bor(rshift(pb[k0] + pb[k1] + pb[k2] + pb[k3], 2), lshift(rshift(pg[k0] + pg[k1] + pg[k2] + pg[k3], 2), 8),
                lshift(rshift(pr[k0] + pr[k1] + pr[k2] + pr[k3], 2), 16), lshift(rshift(al * 17, 2), 24))
        end
    end
end

-- the same rows from an 8-bit picture (kept bottom row first) and its colours
local function half_from_indexed(src, w, h, out, y0, y1)
    local hw = w / 2
    local px = src + 1024
    local band, rshift, lshift, bor = bit.band, bit.rshift, bit.lshift, bit.bor
    for y = y0, y1 - 1 do
        local ra, rb = px + (h - 1 - y * 2) * w, px + (h - 2 - y * 2) * w
        local o = out + y * hw
        for x = 0, hw - 1 do
            local p0, p1, p2, p3 = src + ra[x * 2] * 4, src + ra[x * 2 + 1] * 4, src + rb[x * 2] * 4, src + rb[x * 2 + 1] * 4
            local a = (p0[3] + p1[3] + p2[3] + p3[3]) / 2
            if a > 255 then a = 255 end
            o[x] = bor(rshift(p0[0] + p1[0] + p2[0] + p3[0], 2), lshift(rshift(p0[1] + p1[1] + p2[1] + p3[1], 2), 8),
                lshift(rshift(p0[2] + p1[2] + p2[2] + p3[2], 2), 16), lshift(a, 24))
        end
    end
end

-- a picture half the size of a 32-bit one
local function halve(from, w, out)
    local hw = w / 2
    local band, rshift, lshift, bor = bit.band, bit.rshift, bit.lshift, bit.bor
    for y = 0, hw - 1 do
        local ra, rb, o = from + y * 2 * w, from + (y * 2 + 1) * w, out + y * hw
        for x = 0, hw - 1 do
            local a, b, c, d = ra[x * 2], ra[x * 2 + 1], rb[x * 2], rb[x * 2 + 1]
            o[x] = bor(
                rshift(band(a, 0xFF) + band(b, 0xFF) + band(c, 0xFF) + band(d, 0xFF), 2),
                lshift(rshift(band(rshift(a, 8), 0xFF) + band(rshift(b, 8), 0xFF) + band(rshift(c, 8), 0xFF) + band(rshift(d, 8), 0xFF), 2), 8),
                lshift(rshift(band(rshift(a, 16), 0xFF) + band(rshift(b, 16), 0xFF) + band(rshift(c, 16), 0xFF) + band(rshift(d, 16), 0xFF), 2), 16),
                lshift(rshift(rshift(a, 24) + rshift(b, 24) + rshift(c, 24) + rshift(d, 24), 2), 24))
        end
    end
end

local function upload(buf, size)
    return make(size, size, FMT_A8R8G8B8, function (bits, pitch)
        if pitch == size * 4 then
            ffi.copy(bits, buf, size * size * 4)
        else
            for y = 0, size - 1 do ffi.copy(ffi.cast('uint8_t*', bits) + y * pitch, buf + y * size, size * 4) end
        end
    end)
end

-- one map's smaller copies, a slice of work a frame (run as a task: coroutine.sleepf between slices)
local function build_levels(e)
    local s = e.source
    local pic, w = s.pic, s.pic.w
    local src = ffi.cast('const uint8_t*', s.data) + pic.at
    local hw = w / 2
    local half = ffi.new('int32_t[?]', hw * hw)
    local y, rows = 0, 16
    while y < hw do
        if e.dead then return end
        local t0 = vana.time.clock()
        local y1 = math.min(hw, y + rows)
        if pic.kind == 'dxt3' then half_from_dxt3(src, w, half, y, y1) else half_from_indexed(src, w, pic.h, half, y, y1) end
        local ms = (vana.time.clock() - t0) * 1000
        y = y1
        -- as many rows a slice as fit the time a frame can spare
        if ms < WORK.budget_ms * 0.6 then rows = math.min(256, rows * 2) elseif ms > WORK.budget_ms * 1.3 then rows = math.max(4, rows / 2) end
        coroutine.sleepf(1)
    end
    if e.dead then return end
    local tex = upload(half, hw)
    if tex then
        e.levels[1] = { tex = tex, w = hw }
        e.bytes = e.bytes + hw * hw * 4
        X.bytes = X.bytes + hw * hw * 4
    end
    coroutine.sleepf(1)
    if e.dead then return end
    if hw >= 1024 then
        local qw = hw / 2
        local quarter = ffi.new('int32_t[?]', qw * qw)
        halve(half, hw, quarter)
        coroutine.sleepf(1)
        if e.dead then return end
        local qtex = upload(quarter, qw)
        if qtex then
            e.levels[2] = { tex = qtex, w = qw }
            e.bytes = e.bytes + qw * qw * 4
            X.bytes = X.bytes + qw * qw * 4
        end
    end
end

local function work()
    WORK.running = true
    while #WORK.queue > 0 do
        local e = table.remove(WORK.queue, 1)
        if not e.dead and e.source then
            local ok, err = pcall(build_levels, e)
            if not ok then vana.log('vanamaps smaller copies: ' .. tostring(err)) end
        end
        e.source, e.building = nil, nil
    end
    WORK.running = false
end

-- The texture of a map that suits `across` pixels of screen for the whole picture: the full one, or a smaller copy
-- once it's made (asked for here the first time one would help).
function X.pick(e, across)
    if e.source and not e.building and across < e.w * 0.72 then
        e.building = true
        WORK.queue[#WORK.queue + 1] = e
        if not WORK.running then vana.tasks.spawn(work) end
    end
    if across < e.w * 0.36 and e.levels[2] then return e.levels[2].tex end
    if across < e.w * 0.72 and e.levels[1] then return e.levels[1].tex end
    return e.tex
end

local function free(e)
    e.dead = true
    release(e.tex)
    for _, l in pairs(e.levels or {}) do release(l.tex) end
    e.tex, e.levels, e.source = nil, {}, nil
end

local function trim(keep)
    while X.bytes > X.budget do
        local oldest, key = nil, nil
        for k, e in pairs(X.cache) do
            if e.tex ~= nil and k ~= keep and X.clock - e.used > 120 and (oldest == nil or e.used < oldest.used) then oldest, key = e, k end
        end
        if oldest == nil then return end
        X.bytes = X.bytes - oldest.bytes
        free(oldest)
        X.epoch = X.epoch + 1
        X.cache[key] = nil
    end
end

-- The texture for a list of places a map may be (mapdata's sources, best first): the first that loads.
-- Returns { tex, w, h, from, path } or nil and why. Cached by the list's first path.
function X.get(sources)
    X.clock = X.clock + 1
    local first = sources[1]
    if first == nil then return nil, 'this map has no file' end
    local e = X.cache[first.path]
    if e ~= nil then
        e.used = X.clock
        if e.tex == nil then return nil, e.why end
        return e
    end
    local t0 = vana.time.clock()
    local why = nil
    for i, s in ipairs(sources) do
        local made, err = load(s.path, i < #sources)
        if made ~= nil then
            made.from, made.path, made.used = s.from, s.path, X.clock
            X.cache[first.path] = made
            X.bytes = X.bytes + made.bytes
            X.loads = X.loads + 1
            X.last_ms = (vana.time.clock() - t0) * 1000
            trim(first.path)
            return made
        end
        why = why or (s.path .. ': ' .. tostring(err))
    end
    -- (remembered, so a map that can't be read isn't read again every frame)
    X.cache[first.path] = { tex = nil, why = why or 'no file could be read', used = X.clock, bytes = 0 }
    return nil, why
end

-- everything but `keep` (a first path) let go: the viewer closed, the quality changed
function X.release_all(keep)
    X.epoch = X.epoch + 1
    for k, e in pairs(X.cache) do
        if k ~= keep then
            if e.tex ~= nil then
                X.bytes = X.bytes - e.bytes
                free(e)
            end
            X.cache[k] = nil
        end
    end
end

function X.stats()
    local n = 0
    for _, e in pairs(X.cache) do if e.tex ~= nil then n = n + 1 end end
    return { textures = n, bytes = X.bytes, loads = X.loads, last_ms = X.last_ms }
end

return X
