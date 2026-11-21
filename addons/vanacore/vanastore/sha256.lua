-- SHA-256 (FIPS 180-4), in LuaJIT's own bit operations: the store must know a download is the file the catalog names
-- before the package is read. A VanaCore with a hash of its own (vana.fs.sha256, vana.addons.package_sha256) does this
-- itself and far faster; this is for the ones without (0.8.285 and older). Fed in pieces, so install.lua hashes a file
-- a few milliseconds a frame and the game never waits on it.
--
--   local h = SHA.new()    h:update(bytes) ...    h:hex() -> 64 lower-case hex digits
--   SHA.hex_of(bytes)      the same in one call
local bit = require('bit')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift, ror, tobit = bit.rshift, bit.lshift, bit.ror, bit.tobit

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
for i = 1, 64 do K[i] = tobit(K[i]) end

local W = {}

-- the 64 bytes of `s` from `at` folded into the state H
local function block(H, s, at)
    for i = 0, 15 do
        local a, b, c, d = s:byte(at + i * 4, at + i * 4 + 3)
        W[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for i = 16, 63 do
        local w15, w2 = W[i - 15], W[i - 2]
        local s0 = bxor(ror(w15, 7), ror(w15, 18), rshift(w15, 3))
        local s1 = bxor(ror(w2, 17), ror(w2, 19), rshift(w2, 10))
        W[i] = tobit(W[i - 16] + s0 + W[i - 7] + s1)
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for i = 0, 63 do
        local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = tobit(h + s1 + ch + K[i + 1] + W[i])
        local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = tobit(s0 + maj)
        h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
    end
    H[1], H[2], H[3], H[4] = tobit(H[1] + a), tobit(H[2] + b), tobit(H[3] + c), tobit(H[4] + d)
    H[5], H[6], H[7], H[8] = tobit(H[5] + e), tobit(H[6] + f), tobit(H[7] + g), tobit(H[8] + h)
end

local SHA = {}
SHA.__index = SHA

function SHA.new()
    return setmetatable({
        H = { tobit(0x6a09e667), tobit(0xbb67ae85), tobit(0x3c6ef372), tobit(0xa54ff53a),
              tobit(0x510e527f), tobit(0x9b05688c), tobit(0x1f83d9ab), tobit(0x5be0cd19) },
        rest = '', bytes = 0,
    }, SHA)
end

function SHA:update(s)
    self.bytes = self.bytes + #s
    if self.rest ~= '' then s = self.rest .. s end
    local whole = #s - #s % 64
    for at = 1, whole, 64 do block(self.H, s, at) end
    self.rest = s:sub(whole + 1)
    return self
end

function SHA:hex()
    if self.done == nil then
        -- the padding: a 1 bit, zeros to 56 of 64, then the length in bits as 64 bits
        local bits_hi = math.floor(self.bytes / 0x20000000)
        local bits_lo = (self.bytes % 0x20000000) * 8
        local tail = self.rest .. '\128'
        tail = tail .. string.rep('\0', (56 - #tail % 64) % 64)
        local function word(v)
            return string.char(band(rshift(v, 24), 255), band(rshift(v, 16), 255), band(rshift(v, 8), 255), band(v, 255))
        end
        tail = tail .. word(bits_hi) .. word(bits_lo)
        for at = 1, #tail, 64 do block(self.H, tail, at) end
        local out = {}
        for i = 1, 8 do out[i] = bit.tohex(self.H[i], 8) end
        self.done = table.concat(out)
    end
    return self.done
end

function SHA.hex_of(s) return SHA.new():update(s):hex() end

return SHA
