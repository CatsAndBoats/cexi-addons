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
local ffi = require('ffi')
local bit = require('bit')

local X = { cache = {}, bytes = 0, budget = 56 * 1024 * 1024, clock = 0, loads = 0, last_ms = 0 }

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

local function load(path)
    local f = io.open(path, 'rb')
    if f == nil then return nil, "can't open the file" end
    local data = f:read('*a')
    f:close()
    if data == nil or #data < 128 then return nil, 'an empty file' end
    local pic, why = parse(data)
    if pic == nil then return nil, why end
    local p = ffi.cast('const uint8_t*', data)
    local tex, err, bytes
    if pic.kind == 'dxt3' then
        bytes = pic.size
        tex, err = make(pic.w, pic.h, FMT_DXT3, function (bits) ffi.copy(bits, p + pic.at, pic.size) end)
    else
        bytes = pic.w * pic.h * 4
        tex, err = make(pic.w, pic.h, FMT_A8R8G8B8, function (bits, pitch)
            local pal = ffi.new('uint32_t[256]')
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
                local row = ffi.cast('uint32_t*', ffi.cast('uint8_t*', bits) + y * pitch)
                local from = px + (h - 1 - y) * w
                for x = 0, w - 1 do row[x] = pal[from[x]] end
            end
        end)
    end
    if tex == nil then return nil, err end
    return { tex = tex, w = pic.w, h = pic.h, bytes = bytes, kind = pic.kind }
end

local function trim(keep)
    while X.bytes > X.budget do
        local oldest, key = nil, nil
        for k, e in pairs(X.cache) do
            if e.tex ~= nil and k ~= keep and (oldest == nil or e.used < oldest.used) then oldest, key = e, k end
        end
        if oldest == nil then return end
        release(oldest.tex)
        X.bytes = X.bytes - oldest.bytes
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
    for _, s in ipairs(sources) do
        local made, err = load(s.path)
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
    for k, e in pairs(X.cache) do
        if k ~= keep then
            if e.tex ~= nil then
                release(e.tex)
                X.bytes = X.bytes - e.bytes
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
