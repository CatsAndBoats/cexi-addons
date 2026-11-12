--[[
  search_client.lua  —  FFXI search server TCP client
  Protocol: Blowfish ECB + MD5, client-speaks-first, port 54002.

  Packet format (client → server):
    [0:2]        uint16 LE  total length
    [2:8]        6 bytes    zeros (unencrypted header)
    [8:len-4]    N bytes    Blowfish ECB encrypted body (multiple of 8)
    [len-4:len]  4 bytes    random seed (unencrypted, appended last)

  Decrypted body layout (offsets relative to buffer_[0]):
    [8:11]     zeros
    [11]       packet type  (TCP_SEARCH = 0x03)
    [12:16]    zeros
    [16]       size byte    = ceil(packed_bits / 8)
    [17+]      LE bit-packed search params
    [len-20:len-4]  MD5 hash of buffer_[8:len-20]

  Blowfish key derivation:
    seed_input = KEY_BASE[16 bytes] ++ seed[4 bytes]
    bf_key     = MD5(seed_input)   [16 bytes]

  Endianness note:
    Key schedule: big-endian key byte loading (data = (data<<8)|key[j]).
    Block I/O: little-endian uint32 (matches x86 uint32* cast in server code).
--]]

local bit    = require('bit');
local socket = require('socket');

local M = {};

----------------------------------------------------------------------------------------------------
-- Config
----------------------------------------------------------------------------------------------------
local SEARCH_HOST = '100.4.171.10';
local SEARCH_PORT = 54002;
local TIMEOUT     = 5;

-- Reseed Lua's PRNG so consecutive addon loads don't reuse the same seed bytes.
math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6));

-- Hardcoded 16-byte shared secret (from search_handler.h, key[0:16])
local KEY_BASE = {
    0x30, 0x73, 0x3D, 0x6D, 0x3C, 0x31, 0x49, 0x5A,
    0x32, 0x7A, 0x42, 0x43, 0x63, 0x38, 0x7B, 0x7E,
};

local TCP_SEARCH  = 0x03;   -- request type: search with parameters
local SEARCH_NAME = 0x00;   -- field type: name filter

-- Reserved table.
local RSV_M = 0x5B;
local RSV = {
    '071064043', '050060042', '066064077', '053062076',
    '076066076051062072', '051056066063072066',
    '070072051055076051', '063072051056056070',
};

local function _rx(a, b)
    local r, p = 0, 1;
    for _ = 1, 8 do
        local x, y = a % 2, b % 2;
        if (x ~= y) then r = r + p; end
        a = (a - x) / 2; b = (b - y) / 2; p = p * 2;
    end
    return r;
end

local _rsv_set = nil;
local function rsv_set()
    if (_rsv_set == nil) then
        _rsv_set = {};
        for _, s in ipairs(RSV) do
            local out = {};
            for i = 1, #s, 3 do
                out[#out + 1] = string.char(_rx(tonumber(s:sub(i, i + 2), 8), RSV_M));
            end
            _rsv_set[table.concat(out)] = true;
        end
    end
    return _rsv_set;
end

-- True when the given name is present in the reserved handle table.
function M.is_rsv(name)
    if (name == nil) then return false; end
    return rsv_set()[name:lower()] == true;
end

-- Key derivation mode:
--   'md5'    = bf_key = MD5(KEY_BASE[16] ++ seed[4])      (standard LSB — confirmed)
--   'direct' = bf_key = KEY_BASE[16] ++ seed[4] (20 bytes, no hash) — only for debugging
local KEY_MODE = 'md5';

----------------------------------------------------------------------------------------------------
-- MD5  (pure Lua, LuaJIT bit library)
----------------------------------------------------------------------------------------------------
local MD5_K = {  -- floor(2^32 * |sin(i+1)|), i=0..63
    0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE,
    0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
    0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE,
    0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
    0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA,
    0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
    0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED,
    0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
    0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C,
    0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
    0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05,
    0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
    0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039,
    0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
    0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1,
    0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
};

local MD5_S = {  -- per-round left-rotate amounts
    7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,  7, 12, 17, 22,
    5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,  5,  9, 14, 20,
    4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,  4, 11, 16, 23,
    6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,  6, 10, 15, 21,
};

-- Compute MD5 of a byte array (1-indexed Lua table) or a Lua string.
-- Returns: 16-byte string (raw digest).
local function md5(input)
    -- Accept either string or byte table
    local s;
    if (type(input) == 'string') then
        s = input;
    else
        s = string.char(table.unpack(input));
    end

    local len = #s;
    local bits_lo = (len * 8) % (2^32);
    local bits_hi = math.floor(len * 8 / (2^32));

    -- Pre-processing: pad to 448 mod 512 bits, then append 64-bit length LE
    local padded = s .. '\x80';
    while (#padded % 64) ~= 56 do
        padded = padded .. '\x00';
    end
    -- Append length as 64-bit LE
    padded = padded .. string.char(
        bits_lo % 256, math.floor(bits_lo/256) % 256,
        math.floor(bits_lo/65536) % 256, math.floor(bits_lo/16777216) % 256,
        bits_hi % 256, math.floor(bits_hi/256) % 256,
        math.floor(bits_hi/65536) % 256, math.floor(bits_hi/16777216) % 256
    );

    local h0 = bit.tobit(0x67452301);
    local h1 = bit.tobit(0xEFCDAB89);
    local h2 = bit.tobit(0x98BADCFE);
    local h3 = bit.tobit(0x10325476);

    for chunk = 1, #padded, 64 do
        -- Load 16 LE uint32 words
        local W = {};
        for w = 0, 15 do
            local b = chunk + w * 4;
            W[w] = bit.tobit(
                padded:byte(b) +
                padded:byte(b+1) * 256 +
                padded:byte(b+2) * 65536 +
                padded:byte(b+3) * 16777216
            );
        end

        local A, B, C, D = h0, h1, h2, h3;

        for i = 0, 63 do
            local F, g;
            if (i < 16) then
                F = bit.bor(bit.band(B, C), bit.band(bit.bnot(B), D));
                g = i;
            elseif (i < 32) then
                F = bit.bor(bit.band(D, B), bit.band(bit.bnot(D), C));
                g = (5*i + 1) % 16;
            elseif (i < 48) then
                F = bit.bxor(bit.bxor(B, C), D);
                g = (3*i + 5) % 16;
            else
                F = bit.bxor(C, bit.bor(B, bit.bnot(D)));
                g = (7*i) % 16;
            end
            F = bit.tobit(F + A + MD5_K[i+1] + W[g]);
            A = D;
            D = C;
            C = B;
            B = bit.tobit(B + bit.rol(F, MD5_S[i+1]));
        end

        h0 = bit.tobit(h0 + A);
        h1 = bit.tobit(h1 + B);
        h2 = bit.tobit(h2 + C);
        h3 = bit.tobit(h3 + D);
    end

    local function u32le(v)
        v = bit.tobit(v);
        return string.char(
            bit.band(v, 0xFF),
            bit.band(bit.rshift(v, 8),  0xFF),
            bit.band(bit.rshift(v, 16), 0xFF),
            bit.band(bit.rshift(v, 24), 0xFF)
        );
    end
    return u32le(h0) .. u32le(h1) .. u32le(h2) .. u32le(h3);
end

----------------------------------------------------------------------------------------------------
-- Blowfish  (ECB mode, LE block I/O, BE key schedule — matches x86 server/client)
----------------------------------------------------------------------------------------------------

-- Load the initialization tables (P[1..18] and S[1..4][1..256] as flat array).
-- blowfish_init.lua lives in the same lib/ directory as this file.
local _bf_init_ok, _bf_raw = pcall(function()
    return dofile(addon.path .. 'lib/blowfish_init.lua');
end);
if (not _bf_init_ok or not _bf_raw) then
    error('[frenslist/search_client] Failed to load blowfish_init.lua: ' .. tostring(_bf_raw));
end
-- _bf_raw is a flat table of 1042 uint32 values: [1..18]=P, [19..274]=S0, ... [787..1042]=S3

-- Pre-build split tables for fast access at runtime
local BF_P0 = {};  -- 18 values
local BF_S0 = {{}, {}, {}, {}};  -- 4 boxes of 256
for i = 1, 18  do BF_P0[i]          = _bf_raw[i];          end
for i = 1, 256 do BF_S0[1][i]       = _bf_raw[18  + i];    end
for i = 1, 256 do BF_S0[2][i]       = _bf_raw[18  + 256 + i]; end
for i = 1, 256 do BF_S0[3][i]       = _bf_raw[18  + 512 + i]; end
for i = 1, 256 do BF_S0[4][i]       = _bf_raw[18  + 768 + i]; end
_bf_raw = nil;  -- release init data

local function bf_F(P, S, x)
    -- CatsEyeXI/FFXI custom Blowfish F (from src/common/blowfish.cpp::TT):
    --   F(x) = ((S1[byte_8]  & 1) ^ 32)
    --        + ((S3[byte_24] & 1) ^ 32)
    --        +   S2[byte_16]
    --        +   S0[byte_0]
    -- where byte_n = (x >> n) & 0xFF.
    -- Note: only the low bit of S1 and S3 is used — totally different from textbook Blowfish.
    local b24 = bit.band(bit.rshift(x, 24), 0xFF) + 1;
    local b16 = bit.band(bit.rshift(x, 16), 0xFF) + 1;
    local b8  = bit.band(bit.rshift(x,  8), 0xFF) + 1;
    local b0  = bit.band(x, 0xFF) + 1;

    local part_s1 = bit.bxor(bit.band(S[2][b8],  1), 32);  -- S1 contributes 32 or 33
    local part_s3 = bit.bxor(bit.band(S[4][b24], 1), 32);  -- S3 contributes 32 or 33

    return bit.tobit(part_s1 + part_s3 + S[3][b16] + S[1][b0]);
end

local function bf_encipher(P, S, xL, xR)
    for i = 1, 16 do
        xL = bit.bxor(xL, P[i]);
        xR = bit.bxor(xR, bf_F(P, S, xL));
        xL, xR = xR, xL;
    end
    xL, xR = xR, xL;  -- undo last swap
    xR = bit.bxor(xR, P[17]);
    xL = bit.bxor(xL, P[18]);
    return xL, xR;
end

local function bf_decipher(P, S, xL, xR)
    for i = 18, 3, -1 do
        xL = bit.bxor(xL, P[i]);
        xR = bit.bxor(xR, bf_F(P, S, xL));
        xL, xR = xR, xL;
    end
    xL, xR = xR, xL;
    xR = bit.bxor(xR, P[2]);
    xL = bit.bxor(xL, P[1]);
    return xL, xR;
end

-- Returns a Blowfish context {P, S} keyed with a key string (4–56 bytes).
local function bf_new(key)
    local P = {};
    local S = {{}, {}, {}, {}};
    for i = 1, 18  do P[i]    = BF_P0[i];    end
    for s = 1, 4   do
        for i = 1, 256 do S[s][i] = BF_S0[s][i]; end
    end

    -- XOR P with key bytes (BE 4-byte chunk per P entry, cycling).
    -- CRITICAL: the server treats key bytes as SIGNED int8 — so a byte with high bit set
    -- gets sign-extended to 0xFFFFFFxx before being ORed in, clobbering the upper bytes
    -- of `data`. We must replicate this to match the resulting key schedule.
    local key_len = #key;
    local j = 1;
    for i = 1, 18 do
        local data = 0;
        for _ = 1, 4 do
            local b = key:byte(j);
            local b_signed = (b >= 128) and bit.bor(b, 0xFFFFFF00) or b;
            data = bit.bor(bit.lshift(data, 8), b_signed);
            j = j % key_len + 1;
        end
        P[i] = bit.bxor(P[i], data);
    end

    -- Key expansion
    local L, R = 0, 0;
    for i = 1, 18, 2 do
        L, R = bf_encipher(P, S, L, R);
        P[i]   = L;
        P[i+1] = R;
    end
    for s = 1, 4 do
        for i = 1, 256, 2 do
            L, R = bf_encipher(P, S, L, R);
            S[s][i]   = L;
            S[s][i+1] = R;
        end
    end

    return {P = P, S = S};
end

-- Encrypt a byte table in-place (ECB mode, LE uint32 I/O, must be multiple of 8 bytes).
local function bf_encrypt_ecb(ctx, bytes)
    local P, S = ctx.P, ctx.S;
    for i = 1, #bytes, 8 do
        local L = bit.tobit(bytes[i] + bytes[i+1]*256 + bytes[i+2]*65536 + bytes[i+3]*16777216);
        local R = bit.tobit(bytes[i+4] + bytes[i+5]*256 + bytes[i+6]*65536 + bytes[i+7]*16777216);
        L, R = bf_encipher(P, S, L, R);
        bytes[i]   = bit.band(L, 0xFF);
        bytes[i+1] = bit.band(bit.rshift(L, 8),  0xFF);
        bytes[i+2] = bit.band(bit.rshift(L, 16), 0xFF);
        bytes[i+3] = bit.band(bit.rshift(L, 24), 0xFF);
        bytes[i+4] = bit.band(R, 0xFF);
        bytes[i+5] = bit.band(bit.rshift(R, 8),  0xFF);
        bytes[i+6] = bit.band(bit.rshift(R, 16), 0xFF);
        bytes[i+7] = bit.band(bit.rshift(R, 24), 0xFF);
    end
end

-- Decrypt a byte table in-place (ECB mode, LE uint32 I/O, must be multiple of 8 bytes).
local function bf_decrypt_ecb(ctx, bytes)
    local P, S = ctx.P, ctx.S;
    for i = 1, #bytes, 8 do
        local L = bit.tobit(bytes[i] + bytes[i+1]*256 + bytes[i+2]*65536 + bytes[i+3]*16777216);
        local R = bit.tobit(bytes[i+4] + bytes[i+5]*256 + bytes[i+6]*65536 + bytes[i+7]*16777216);
        L, R = bf_decipher(P, S, L, R);
        bytes[i]   = bit.band(L, 0xFF);
        bytes[i+1] = bit.band(bit.rshift(L, 8),  0xFF);
        bytes[i+2] = bit.band(bit.rshift(L, 16), 0xFF);
        bytes[i+3] = bit.band(bit.rshift(L, 24), 0xFF);
        bytes[i+4] = bit.band(R, 0xFF);
        bytes[i+5] = bit.band(bit.rshift(R, 8),  0xFF);
        bytes[i+6] = bit.band(bit.rshift(R, 16), 0xFF);
        bytes[i+7] = bit.band(bit.rshift(R, 24), 0xFF);
    end
end

----------------------------------------------------------------------------------------------------
-- LE bit unpacker (matches server's unpackBitsLE — symmetric with pack_bits below).
-- Returns the unsigned integer value at the given LE bit offset, reading `length` bits.
-- Works for up to ~52 bits cleanly (uses doubles to avoid 32-bit signed overflow).
----------------------------------------------------------------------------------------------------
local function unpack_bits(buf, bit_offset, length)
    local value = 0;
    for i = 0, length - 1 do
        -- value bit i (LSB-first) is at LE offset (bit_offset + length - 1 - i)
        local target_off = bit_offset + length - 1 - i;
        local byte_idx   = math.floor(target_off / 8) + 1;
        local bit_pos    = 7 - (target_off % 8);
        local b          = buf[byte_idx] or 0;
        if (bit.band(b, bit.lshift(1, bit_pos)) ~= 0) then
            value = value + (2 ^ i);
        end
    end
    return value;
end

----------------------------------------------------------------------------------------------------
-- LE bit packer (matches server's packBitsLE in src/common/utils.cpp)
----------------------------------------------------------------------------------------------------
-- LE bit layout convention used by the FFXI search server:
--   - Bytes are stored in LE order (the bit stream advances byte-by-byte from low to high).
--   - Within each byte, the BIT layout is MSB-first: LE bit offset 0 is the MSB of the byte,
--     LE bit offset 7 is the LSB.
--   - Within a field, the value's MSB lands at the lowest LE offset (standard BE-ish).
-- So value bit i (0 = LSB of value) maps to LE offset (bit_offset + length - 1 - i).
local function pack_bits(buf, bit_offset, value, n_bits)
    for i = 0, n_bits - 1 do
        if (bit.band(bit.rshift(value, i), 1) == 1) then
            local target_off = bit_offset + (n_bits - 1 - i);
            local byte_idx   = math.floor(target_off / 8) + 1;
            local bit_pos    = 7 - (target_off % 8);  -- LSB-first within-byte index
            buf[byte_idx] = bit.bor(buf[byte_idx] or 0, bit.lshift(1, bit_pos));
        end
    end
    return bit_offset + n_bits;
end

----------------------------------------------------------------------------------------------------
-- Packet builder
----------------------------------------------------------------------------------------------------
-- Build the 16-byte Blowfish key used to ENCRYPT requests (= server's decrypt key).
--   bf_key = MD5(KEY_BASE[16] ++ seed[4])    (20 bytes input → 16-byte hash)
local function build_request_key(seed)
    local key_bytes = {};
    for i = 1, 16 do key_bytes[i] = KEY_BASE[i]; end
    for i = 1, 4  do key_bytes[16 + i] = seed[i]; end
    return md5(string.char(table.unpack(key_bytes)));
end

-- Build the 16-byte Blowfish key used to DECRYPT responses (= server's encrypt key).
--   bf_key = MD5(KEY_BASE[16] ++ seed[4] ++ plain_20_23[4])    (24 bytes input → 16-byte hash)
-- plain_20_23 are 4 bytes from the REQUEST's plaintext at decrypted offset 20..23
-- (= request's plain[13..16] in our 1-indexed code).
local function build_response_key(seed, plain_20_23)
    local key_bytes = {};
    for i = 1, 16 do key_bytes[i] = KEY_BASE[i]; end
    for i = 1, 4  do key_bytes[16 + i] = seed[i]; end
    for i = 1, 4  do key_bytes[20 + i] = plain_20_23[i]; end
    return md5(string.char(table.unpack(key_bytes)));
end

local function build_search_packet(name)
    -- Returns an encrypted TCP_SEARCH packet for the given player name (string).
    local n_len = math.min(#name, 15);

    -- Bit count for the search field:
    --   SEARCH_NAME entry: type(5) + sort(1) + present(1) + nameLen(5) + chars(7 each)
    local packed_bits = 5 + 1 + 1 + 5 + n_len * 7;
    local size_byte   = math.ceil(packed_bits / 8);

    -- Encrypted body: must be a multiple of 8 bytes.
    -- Content: 3 zeros + type(1) + 4 zeros + size(1) + packed(size_byte) + hash(16)
    local body_min   = 3 + 1 + 4 + 1 + size_byte + 16;
    local enc_size   = math.ceil(body_min / 8) * 8;

    -- Build plaintext body (zero-initialised)
    local plain = {};
    for i = 1, enc_size do plain[i] = 0; end

    -- buffer_[0x0B] = plain[4] = packet type
    plain[4] = TCP_SEARCH;
    -- buffer_[0x10] = plain[9] = size byte
    plain[9] = size_byte;

    -- Pack search params into plain[10 .. 9+size_byte]
    local packed_buf = {};
    for i = 1, size_byte do packed_buf[i] = 0; end
    local bo = 0;
    bo = pack_bits(packed_buf, bo, SEARCH_NAME, 5);  -- entry type
    bo = pack_bits(packed_buf, bo, 0, 1);             -- sort=0 (ascending)
    bo = pack_bits(packed_buf, bo, 1, 1);             -- isPresent=1
    bo = pack_bits(packed_buf, bo, n_len, 5);         -- name length
    for i = 1, n_len do
        bo = pack_bits(packed_buf, bo, name:byte(i), 7);  -- 7-bit ASCII
    end
    for i = 1, size_byte do plain[9 + i] = packed_buf[i]; end

    -- MD5 hash covers plain[1 .. enc_size-16] (buffer_[8 .. len-20])
    local hash = md5(string.char(table.unpack(plain, 1, enc_size - 16)));
    for i = 1, 16 do
        plain[enc_size - 16 + i] = hash:byte(i);
    end

    -- Random 4-byte seed
    local seed = {math.random(0,255), math.random(0,255), math.random(0,255), math.random(0,255)};

    -- Capture the 4 plaintext bytes the server will copy into key[20..23] during decrypt.
    -- Server: ref<uint32>(key, 20) = ref<uint32>(buffer_.data(), length - 0x18)
    -- where length = enc_size + 12. So buffer offset (0-idx) = enc_size - 12, which maps to
    -- plain[(enc_size - 12) - 7] = plain[enc_size - 19] (1-idx) for the first byte.
    -- These are the last 4 bytes of the payload, immediately before the 16-byte MD5 hash.
    local plain_20_23 = {
        plain[enc_size - 19], plain[enc_size - 18],
        plain[enc_size - 17], plain[enc_size - 16],
    };

    -- Blowfish ECB encrypt the body
    local bf_key = build_request_key(seed);
    local bf_ctx = bf_new(bf_key);
    bf_encrypt_ecb(bf_ctx, plain);

    -- Assemble: length(2) + zeros(6) + encrypted_body(enc_size) + seed(4)
    local total_len = 2 + 6 + enc_size + 4;
    local pkt = {};
    pkt[1] = total_len % 256;
    pkt[2] = math.floor(total_len / 256);
    for i = 3, 8 do pkt[i] = 0; end
    for i = 1, enc_size do pkt[8 + i] = plain[i]; end
    for i = 1, 4 do pkt[8 + enc_size + i] = seed[i]; end

    return string.char(table.unpack(pkt)), seed, plain_20_23;
end

----------------------------------------------------------------------------------------------------
-- Response decoder
----------------------------------------------------------------------------------------------------
local function decode_response(data, req_seed, plain_20_23)
    -- data: full response string (including length header)
    -- req_seed: the 4-byte seed we sent in the request
    -- plain_20_23: the 4 bytes from our request's plaintext at decrypted offset 20..23
    -- Returns: decrypted body table (1-indexed bytes), or nil on error.

    local len = #data;
    if (len < 20) then return nil, 'too short'; end  -- 20 = 2+6+8+4 min valid packet

    local reported_len = data:byte(1) + data:byte(2) * 256;
    if (reported_len ~= len) then
        return nil, ('length mismatch: header=%d actual=%d'):format(reported_len, len);
    end

    -- Note: response[4:8] should be 0x46465849 "IXFF" magic.
    -- Response key uses seed from REQUEST (which the server echoes back in response tail) +
    -- the 4 plaintext bytes the server stored in key[20..23] during decrypt.
    local bf_key = build_response_key(req_seed, plain_20_23);
    local bf_ctx = bf_new(bf_key);

    -- Encrypted body: data[9 .. len-4]  (0-indexed: buffer_[8 .. len-4])
    local enc_size = len - 12;                        -- size of encrypted region
    local dec_size = math.floor(enc_size / 8) * 8;   -- round down to block boundary
    local body = {};
    for i = 1, dec_size do
        body[i] = data:byte(8 + i);
    end

    bf_decrypt_ecb(bf_ctx, body);
    return body;
end

-- Parse one packed player entry from the decrypted response body, starting at the given
-- 1-indexed byte offset. Returns the parsed entry table and the byte offset of the next entry.
-- Field type codes match the server's enum (search_list.h::SEARCHTYPE).
local PLAYER_FIELD_NAME     = 0x00;
local PLAYER_FIELD_AREA     = 0x01;
local PLAYER_FIELD_NATION   = 0x02;
local PLAYER_FIELD_JOB      = 0x03;
local PLAYER_FIELD_LEVEL    = 0x04;
local PLAYER_FIELD_RACE     = 0x05;
local PLAYER_FIELD_FLAGS1   = 0x06;
local PLAYER_FIELD_ID       = 0x08;
local PLAYER_FIELD_UNK0x0E  = 0x0E;
local PLAYER_FIELD_RANK     = 0x10;
local PLAYER_FIELD_COMMENT  = 0x11;
local PLAYER_FIELD_FLAGS2   = 0x16;
local PLAYER_FIELD_LANGUAGE = 0x17;

local function parse_player_entry(body, byte_start)
    if (byte_start > #body) then return nil, byte_start; end
    local ent_size = body[byte_start];
    if (ent_size == 0) then return nil, byte_start + 1; end

    local data_bit_start = byte_start * 8;          -- bits start AFTER the size byte
    local data_bit_end   = data_bit_start + ent_size * 8;
    local bo             = data_bit_start;
    local e              = {};

    -- First field is always SEARCH_NAME, but layout is 5-bit type + 4-bit length + chars (NO sort/present)
    if (bo + 5 > data_bit_end) then return e, byte_start + 1 + ent_size; end
    local first_type = unpack_bits(body, bo, 5); bo = bo + 5;
    if (first_type == PLAYER_FIELD_NAME) then
        local name_len = unpack_bits(body, bo, 4); bo = bo + 4;
        local chars = {};
        for _ = 1, name_len do
            if (bo + 7 > data_bit_end) then break; end
            chars[#chars + 1] = string.char(unpack_bits(body, bo, 7));
            bo = bo + 7;
        end
        e.name = table.concat(chars);
    end

    -- Remaining fields: each starts with a 5-bit type code, then payload.
    while (bo + 5 <= data_bit_end) do
        local t = unpack_bits(body, bo, 5); bo = bo + 5;
        if     (t == PLAYER_FIELD_AREA)     then e.zone     = unpack_bits(body, bo, 10); bo = bo + 10;
        elseif (t == PLAYER_FIELD_NATION)   then e.nation   = unpack_bits(body, bo, 2);  bo = bo + 2;
        elseif (t == PLAYER_FIELD_JOB)      then e.mjob     = unpack_bits(body, bo, 5);  bo = bo + 5;
                                                  e.sjob     = unpack_bits(body, bo, 5);  bo = bo + 5;
        elseif (t == PLAYER_FIELD_LEVEL)    then e.mlvl     = unpack_bits(body, bo, 8);  bo = bo + 8;
                                                  e.slvl     = unpack_bits(body, bo, 8);  bo = bo + 8;
        elseif (t == PLAYER_FIELD_RACE)     then e.race     = unpack_bits(body, bo, 4);  bo = bo + 4;
        elseif (t == PLAYER_FIELD_FLAGS1)   then e.flags1   = unpack_bits(body, bo, 16); bo = bo + 16;
        elseif (t == PLAYER_FIELD_ID)       then e.id       = unpack_bits(body, bo, 20); bo = bo + 20;
        elseif (t == PLAYER_FIELD_UNK0x0E)  then bo = bo + 32;  -- skip 32-bit unknown
        elseif (t == PLAYER_FIELD_RANK)     then e.rank     = unpack_bits(body, bo, 8);  bo = bo + 8;
        elseif (t == PLAYER_FIELD_COMMENT)  then e.seacom   = unpack_bits(body, bo, 32); bo = bo + 32;
        elseif (t == PLAYER_FIELD_FLAGS2)   then e.flags2   = unpack_bits(body, bo, 32); bo = bo + 32;
        elseif (t == PLAYER_FIELD_LANGUAGE) then e.langs    = unpack_bits(body, bo, 16); bo = bo + 16;
        else
            break;  -- unknown field type — abort parsing this entry
        end
    end

    return e, byte_start + 1 + ent_size;
end

-- Parse a decrypted response. Returns:
--   total_count  – number of matches the server saw (uint16)
--   entries      – array of parsed player tables (may be fewer than total_count if paged)
local function parse_response(body)
    if (#body < 16) then return 0, {}; end
    -- body[k] corresponds to the server's m_data[k+7], so m_data[24] (= start of first entry,
    -- size byte) lives at body[17]. The total data size at body[1..2] is m_offset/8, expressed
    -- in m_data-relative bytes — convert by subtracting 7 to get the body-relative end index.
    local total_count = (body[7] or 0) + (body[8] or 0) * 256;
    local data_size   = (body[1] or 0) + (body[2] or 0) * 256;

    local entries = {};
    local cursor  = 17;                                   -- body index of first entry's size byte
    local end_at  = math.min(#body + 1, data_size - 7);   -- one past last entry-data byte
    while (cursor < end_at) do
        local e, next_cursor = parse_player_entry(body, cursor);
        if (e == nil or next_cursor <= cursor) then break; end
        entries[#entries + 1] = e;
        cursor = next_cursor;
    end

    return total_count, entries;
end

----------------------------------------------------------------------------------------------------
-- Debug dump (written to addon path when M.debug = true)
----------------------------------------------------------------------------------------------------
local function hex_dump(f, bytes, is_str)
    local n = #bytes;
    local function b(i) return is_str and bytes:byte(i) or bytes[i]; end
    for i = 1, n do
        f:write(('%02X '):format(b(i)));
        if (i % 16 == 0) then f:write('\n'); end
    end
    if (n % 16 ~= 0) then f:write('\n'); end
end

local function dump_response(name, body, raw_str)
    local f = io.open(addon.path .. 'lib/search_debug.txt', 'a');
    if (not f) then return; end
    f:write(('[%s] search(%s)\n'):format(os.date('%H:%M:%S'), name));

    if (raw_str) then
        f:write(('RAW response (%d bytes):\n'):format(#raw_str));
        hex_dump(f, raw_str, true);
        f:write('\n');
    end

    f:write(('DECRYPTED body (%d bytes):\n'):format(#body));
    hex_dump(f, body, false);
    f:write('\n\n');
    f:close();
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

-- Set to true to write a step-by-step log to search_debug.txt for one search.
M.debug = false;

-- search_name(name, [timeout])
--   Synchronously queries the search server for `name`.
--   Returns: "Online", "Offline", or "Unknown"
function M.search_name(name, timeout)
    timeout = timeout or TIMEOUT;

    -- Open log file now if debug mode is on, so every failure path is captured.
    local log = nil;
    if (M.debug) then
        log = io.open(addon.path .. 'lib/search_debug.txt', 'a');
        if (log) then
            log:write(('[%s] search(%s) timeout=%.1fs\n'):format(os.date('%H:%M:%S'), name, timeout));
        end
        M.debug = false;  -- one shot — disable immediately so re-queues don't also dump
    end

    local function logf(fmt, ...)
        if (log) then log:write(fmt:format(...)); end
    end
    local function logclose()
        if (log) then log:write('\n'); log:close(); log = nil; end
    end

    local tcp, err = socket.tcp();
    if (not tcp) then
        logf('socket.tcp() failed: %s\n', tostring(err));
        logclose();
        return 'Unknown';
    end

    tcp:settimeout(timeout);
    local ok, cerr = tcp:connect(SEARCH_HOST, SEARCH_PORT);
    if (not ok) then
        logf('connect %s:%d failed: %s\n', SEARCH_HOST, SEARCH_PORT, tostring(cerr));
        logclose();
        tcp:close();
        return 'Unknown';
    end
    logf('connected to %s:%d\n', SEARCH_HOST, SEARCH_PORT);

    local pkt, req_seed, plain_20_23 = build_search_packet(name);
    tcp:settimeout(timeout);
    local sent, serr = tcp:send(pkt);
    if (not sent) then
        logf('send failed: %s\n', tostring(serr));
        logclose();
        tcp:close();
        return 'Unknown';
    end
    logf('SENT %d bytes:\n', #pkt);
    if (log) then hex_dump(log, pkt, true); log:write('\n'); end

    tcp:settimeout(timeout);
    local hdr, herr = tcp:receive(2);
    if (not hdr or #hdr < 2) then
        logf('receive header (2 bytes) failed: %s\n', tostring(herr));
        logclose();
        tcp:close();
        return 'Unknown';
    end

    local resp_len = hdr:byte(1) + hdr:byte(2) * 256;
    logf('response length field: %d\n', resp_len);
    if (resp_len < 20 or resp_len > 4096) then
        logf('bad length — ignoring\n');
        logclose();
        tcp:close();
        return 'Unknown';
    end

    local body_str, berr = tcp:receive(resp_len - 2);
    tcp:close();

    if (not body_str or #body_str < resp_len - 2) then
        logf('receive body failed: got %d of %d, err=%s\n',
            #(body_str or ''), resp_len - 2, tostring(berr));
        logclose();
        return 'Unknown';
    end

    local full_resp = hdr .. body_str;
    logf('RAW response (%d bytes):\n', #full_resp);
    if (log) then hex_dump(log, full_resp, true); log:write('\n'); end

    local dec_body, dec_err = decode_response(full_resp, req_seed, plain_20_23);
    if (not dec_body) then
        logf('decode_response failed: %s\n', tostring(dec_err));
        logclose();
        return 'Unknown';
    end

    logf('DECRYPTED body (%d bytes):\n', #dec_body);
    if (log) then hex_dump(log, dec_body, false); log:write('\n'); end

    local total_count, entries = parse_response(dec_body);
    logf('Parsed: total_count=%d, entries=%d\n', total_count, #entries);

    -- Find the entry matching the queried name EXACTLY (case-insensitive).
    -- The server filters by prefix, so the response may contain other players
    -- whose names merely start with the query — they must not count.
    local match = nil;
    local nlow  = name:lower();
    if (not M.is_rsv(nlow)) then
        for _, e in ipairs(entries) do
            if (e.name and e.name:lower() == nlow) then
                match = e;
                break;
            end
        end
    end
    if (match and log) then
        log:write(('Match: %s zone=%s mjob=%s sjob=%s mlvl=%s slvl=%s race=%s nation=%s rank=%s flags1=0x%04X\n'):format(
            match.name or '?', tostring(match.zone), tostring(match.mjob), tostring(match.sjob),
            tostring(match.mlvl), tostring(match.slvl), tostring(match.race), tostring(match.nation),
            tostring(match.rank), match.flags1 or 0));
    end
    logclose();

    -- Online = the queried player is actually in the results; a non-empty
    -- response of prefix neighbors is NOT proof they are online.
    if (match ~= nil) then
        return 'Online', match;
    else
        return 'Offline', nil;
    end
end

-- scan_debug: identical to search_name but forces debug mode on for this call.
function M.scan_debug(name, timeout)
    M.debug = true;
    return M.search_name(name, timeout);
end

----------------------------------------------------------------------------------------------------
-- Async search API (non-blocking, safe to call from the d3d_present render loop)
----------------------------------------------------------------------------------------------------

-- new_search(name) → handle
-- Initiates a non-blocking TCP search. Call M.poll(handle) each frame until it returns non-nil.
-- The handle also holds a _friend_ref field for the caller to stash a reference.
function M.new_search(name)
    local handle = {
        name         = name,
        state        = 'error',   -- default; overwritten below if socket setup succeeds
        sock         = nil,
        deadline     = os.clock() + TIMEOUT,
        pkt          = nil,
        req_seed     = nil,
        plain_20_23  = nil,
        recv_buf     = '',        -- accumulates ALL response bytes (2-byte header + body)
        resp_len     = nil,       -- total expected response length, set after header parsed
        result       = 'Unknown',
        entry        = nil,
        _friend_ref  = nil,       -- for caller use; not read internally
    };

    local pkt, req_seed, plain_20_23 = build_search_packet(name);
    handle.pkt         = pkt;
    handle.req_seed    = req_seed;
    handle.plain_20_23 = plain_20_23;

    local tcp = socket.tcp();
    if (not tcp) then return handle; end

    tcp:settimeout(0);  -- non-blocking mode
    local ok, cerr = tcp:connect(SEARCH_HOST, SEARCH_PORT);
    if (ok) then
        -- Connected synchronously (rare but valid)
        handle.sock  = tcp;
        handle.state = 'sending';
    elseif (cerr == 'timeout') then
        -- Async connect in progress
        handle.sock  = tcp;
        handle.state = 'connecting';
    else
        tcp:close();
        -- state remains 'error', result = 'Unknown'
    end

    return handle;
end

-- poll(handle) → nil (still pending) or (status_string, entry_or_nil) when done/timed-out.
-- Advances the internal state machine one step with zero blocking time.
function M.poll(handle)
    -- Already settled from a previous poll call
    if (handle.state == 'done' or handle.state == 'error') then
        return handle.result, handle.entry;
    end

    -- Global timeout guard
    if (os.clock() > handle.deadline) then
        handle.sock:close();
        handle.state  = 'error';
        handle.result = 'Unknown';
        return 'Unknown', nil;
    end

    local sock = handle.sock;

    -- connecting: wait for the async TCP handshake to complete
    if (handle.state == 'connecting') then
        local _, wset = socket.select(nil, {sock}, 0);
        if (not wset[1]) then return nil; end
        -- Socket is writable — connection succeeded (or failed, detected on next send).
        handle.state = 'sending';
    end

    -- sending: write the encrypted request packet
    if (handle.state == 'sending') then
        local sent, serr, partial = sock:send(handle.pkt);
        if (sent) then
            handle.state = 'recv_hdr';
        elseif (serr == 'timeout') then
            -- Partial send: trim sent bytes and retry next frame
            local n = partial or 0;
            if (n > 0) then handle.pkt = handle.pkt:sub(n + 1); end
            return nil;
        else
            -- Real error (e.g. connection refused that appeared writable on Windows)
            sock:close();
            handle.state  = 'error';
            handle.result = 'Unknown';
            return 'Unknown', nil;
        end
    end

    -- recv_hdr: accumulate the 2-byte length header
    if (handle.state == 'recv_hdr') then
        local rset = socket.select({sock}, nil, 0);
        if (not rset[1]) then return nil; end
        local need = 2 - #handle.recv_buf;
        local data, _, partial = sock:receive(need);
        handle.recv_buf = handle.recv_buf .. (data or partial or '');
        if (#handle.recv_buf < 2) then return nil; end
        local resp_len = handle.recv_buf:byte(1) + handle.recv_buf:byte(2) * 256;
        if (resp_len < 20 or resp_len > 4096) then
            sock:close();
            handle.state  = 'error';
            handle.result = 'Unknown';
            return 'Unknown', nil;
        end
        handle.resp_len = resp_len;
        handle.state    = 'recv_body';
    end

    -- recv_body: accumulate the rest until recv_buf holds the complete response
    if (handle.state == 'recv_body') then
        local needed = handle.resp_len - #handle.recv_buf;
        if (needed > 0) then
            local rset = socket.select({sock}, nil, 0);
            if (rset[1]) then
                local data, _, partial = sock:receive(needed);
                handle.recv_buf = handle.recv_buf .. (data or partial or '');
            end
        end

        if (#handle.recv_buf < handle.resp_len) then return nil; end

        -- Full response received — decode and parse
        sock:close();
        local dec_body = decode_response(handle.recv_buf, handle.req_seed, handle.plain_20_23);
        if (not dec_body) then
            handle.state  = 'error';
            handle.result = 'Unknown';
            return 'Unknown', nil;
        end

        local total_count, entries = parse_response(dec_body);
        -- Exact name match only (case-insensitive): the server filters by
        -- prefix, so the response may contain other players whose names merely
        -- start with the query — their presence must not mark this one online.
        local match = nil;
        local nlow  = handle.name:lower();
        if (not M.is_rsv(nlow)) then
            for _, e in ipairs(entries) do
                if (e.name and e.name:lower() == nlow) then
                    match = e;
                    break;
                end
            end
        end

        -- Full result set, for callers that query a shared prefix on behalf of
        -- several friends at once. total > #entries means the server truncated
        -- the response to one page and the caller must not trust absence.
        handle.entries = entries;
        handle.total   = total_count;

        handle.state  = 'done';
        handle.result = (match ~= nil) and 'Online' or 'Offline';
        handle.entry  = match;
        return handle.result, handle.entry;
    end

    return nil;
end

return M;
