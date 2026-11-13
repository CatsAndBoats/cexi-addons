--[[
* trove/quest/textures.lua — Game menu background texture loader
*
* Extracts window style textures from FFXI DAT files (ROM/0/14-19.DAT),
* decodes DXT1, and creates D3D8 textures for imgui rendering.
* No redistribution needed — reads directly from the player's game install.
]]--

local ffi   = require('ffi');
local d3d   = require('d3d8');
local struct = struct;

local C       = ffi.C;
local d3d8dev = d3d.get_device();

ffi.cdef[[
    HRESULT __stdcall D3DXCreateTextureFromFileInMemoryEx(
        IDirect3DDevice8* pDevice,
        const void* pSrcData, unsigned int SrcDataSize,
        unsigned int Width, unsigned int Height,
        unsigned int MipLevels, unsigned int Usage,
        int Format, int Pool,
        unsigned int Filter, unsigned int MipFilter,
        unsigned int ColorKey,
        void* pSrcInfo, void* pPalette,
        IDirect3DTexture8** ppTexture);
]];

local textures = {};

-- Cached texture handles: style_num -> imgui handle (number)
local textureCache   = {};
local textureObjects = {};  -- prevent GC

-- Game path (resolved once)
local gamePath = nil;

local function getGamePath()
    if gamePath then return gamePath; end
    local ashitaPath = AshitaCore:GetInstallPath();
    -- Ashita is at .../Ashita/, Game is at .../Game/FINAL FANTASY XI/
    gamePath = ashitaPath .. '..\\Game\\FINAL FANTASY XI\\';
    return gamePath;
end

------------------------------------------------------------
-- DXT1 decoder (pure Lua)
------------------------------------------------------------
local function decode_rgb565(val)
    local r = bit.rshift(bit.band(val, 0xF800), 8);
    local g = bit.rshift(bit.band(val, 0x07E0), 3);
    local b = bit.lshift(bit.band(val, 0x001F), 3);
    return r, g, b;
end

local function decodeDXT1(data, offset, w, h)
    -- Decode DXT1 to RGBA8888 bitmap (BMP-compatible, bottom-up)
    local blocks_x = math.floor((w + 3) / 4);
    local blocks_y = math.floor((h + 3) / 4);
    local pixels = {};  -- [y][x] = {r,g,b,a}

    for y = 0, h - 1 do pixels[y] = {}; end

    for by = 0, blocks_y - 1 do
        for bx = 0, blocks_x - 1 do
            local boff = offset + (by * blocks_x + bx) * 8;
            if boff + 8 > #data then break; end

            local b1 = data:byte(boff + 1);
            local b2 = data:byte(boff + 2);
            local b3 = data:byte(boff + 3);
            local b4 = data:byte(boff + 4);

            local c0 = b1 + b2 * 256;
            local c1 = b3 + b4 * 256;

            local r0, g0, b0_ = decode_rgb565(c0);
            local r1, g1, b1_ = decode_rgb565(c1);

            local colors = {};
            colors[0] = { r0, g0, b0_, 255 };
            colors[1] = { r1, g1, b1_, 255 };

            if c0 > c1 then
                colors[2] = {
                    math.floor((2*r0+r1+1)/3),
                    math.floor((2*g0+g1+1)/3),
                    math.floor((2*b0_+b1_+1)/3), 255 };
                colors[3] = {
                    math.floor((r0+2*r1+1)/3),
                    math.floor((g0+2*g1+1)/3),
                    math.floor((b0_+2*b1_+1)/3), 255 };
            else
                colors[2] = {
                    math.floor((r0+r1)/2),
                    math.floor((g0+g1)/2),
                    math.floor((b0_+b1_)/2), 255 };
                colors[3] = { 0, 0, 0, 0 };
            end

            -- Read 4 bytes of 2-bit indices
            local idx_bytes = {
                data:byte(boff + 5),
                data:byte(boff + 6),
                data:byte(boff + 7),
                data:byte(boff + 8),
            };

            for py = 0, 3 do
                local row_byte = idx_bytes[py + 1];
                for px = 0, 3 do
                    local ci = bit.band(bit.rshift(row_byte, px * 2), 3);
                    local x = bx * 4 + px;
                    local y = by * 4 + py;
                    if x < w and y < h then
                        pixels[y][x] = colors[ci];
                    end
                end
            end
        end
    end

    return pixels;
end

------------------------------------------------------------
-- Create D3D8 texture from decoded RGBA pixels
------------------------------------------------------------
local function createTextureFromPixels(pixels, w, h)
    -- Build a raw 32-bit ARGB bitmap in memory
    local bmpSize = w * h * 4;
    local bmpData = ffi.new('uint8_t[?]', bmpSize);

    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local p = pixels[y] and pixels[y][x] or { 0, 0, 0, 255 };
            local off = (y * w + x) * 4;
            bmpData[off + 0] = p[3];  -- B (ARGB format)
            bmpData[off + 1] = p[1];  -- G
            bmpData[off + 2] = p[2];  -- R
            bmpData[off + 3] = p[4] or 255;  -- A
        end
    end

    -- Wait — D3DXCreateTextureFromFileInMemoryEx expects a file format (BMP/PNG/DDS)
    -- not raw pixels. Let me build a minimal BMP in memory instead.

    -- BMP header (54 bytes) + pixel data
    local fileSize = 54 + bmpSize;
    local bmp = ffi.new('uint8_t[?]', fileSize);

    -- BMP file header (14 bytes)
    bmp[0] = 0x42; bmp[1] = 0x4D;  -- 'BM'
    local fs = fileSize;
    bmp[2] = bit.band(fs, 0xFF);
    bmp[3] = bit.band(bit.rshift(fs, 8), 0xFF);
    bmp[4] = bit.band(bit.rshift(fs, 16), 0xFF);
    bmp[5] = bit.band(bit.rshift(fs, 24), 0xFF);
    bmp[6] = 0; bmp[7] = 0; bmp[8] = 0; bmp[9] = 0;  -- reserved
    bmp[10] = 54; bmp[11] = 0; bmp[12] = 0; bmp[13] = 0;  -- pixel offset

    -- DIB header (40 bytes)
    bmp[14] = 40; bmp[15] = 0; bmp[16] = 0; bmp[17] = 0;  -- header size
    -- Width
    bmp[18] = bit.band(w, 0xFF); bmp[19] = bit.band(bit.rshift(w, 8), 0xFF);
    bmp[20] = 0; bmp[21] = 0;
    -- Height (negative for top-down)
    local nh = -h;
    bmp[22] = bit.band(nh, 0xFF); bmp[23] = bit.band(bit.rshift(nh, 8), 0xFF);
    bmp[24] = bit.band(bit.rshift(nh, 16), 0xFF); bmp[25] = bit.band(bit.rshift(nh, 24), 0xFF);
    -- Planes
    bmp[26] = 1; bmp[27] = 0;
    -- Bits per pixel
    bmp[28] = 32; bmp[29] = 0;
    -- Compression (BI_RGB = 0)
    bmp[30] = 0; bmp[31] = 0; bmp[32] = 0; bmp[33] = 0;
    -- Image size, resolution, colors (all 0)
    for i = 34, 53 do bmp[i] = 0; end

    -- Pixel data (BGRA)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local p = pixels[y] and pixels[y][x] or { 0, 0, 0, 255 };
            local off = 54 + (y * w + x) * 4;
            bmp[off + 0] = p[3] or 0;    -- B
            bmp[off + 1] = p[2] or 0;    -- G
            bmp[off + 2] = p[1] or 0;    -- R
            bmp[off + 3] = p[4] or 255;  -- A
        end
    end

    local ptr = ffi.new('IDirect3DTexture8*[1]');
    local hr = C.D3DXCreateTextureFromFileInMemoryEx(
        d3d8dev, bmp, fileSize,
        0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
        C.D3DFMT_A8R8G8B8, C.D3DPOOL_MANAGED,
        C.D3DX_DEFAULT, C.D3DX_DEFAULT,
        0x00000000, nil, nil, ptr);

    if hr ~= C.S_OK then return nil; end

    local tex = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', ptr[0]));
    return tex, tonumber(ffi.cast('uint32_t', tex));
end

------------------------------------------------------------
-- Find newtex texture in a DAT file
------------------------------------------------------------
local function findNewtexInDAT(data)
    -- Scan for 0xA1 records with id = "newtex"
    for i = 1, #data - 0x50 do
        if data:byte(i) == 0xA1 then
            -- Check bihSize = 40
            local b1 = data:byte(i + 0x11);
            local b2 = data:byte(i + 0x12);
            if b1 == 40 and b2 == 0 then
                local tid = data:sub(i + 9, i + 16):gsub('%z', ''):gsub(' +$', '');
                if tid == 'newtex' then
                    -- Read width/height
                    local w = data:byte(i + 0x15) + data:byte(i + 0x16) * 256;
                    local h = data:byte(i + 0x19) + data:byte(i + 0x1A) * 256;
                    if w >= 32 and w <= 512 and h >= 32 and h <= 512 then
                        local pixel_start = i + 0x44;  -- 0-indexed: i-1 + 0x45
                        return pixel_start, w, h;
                    end
                end
            end
        end
    end
    return nil;
end

------------------------------------------------------------
-- Load a window style texture
------------------------------------------------------------
textures.loadStyle = function(styleNum)
    if textureCache[styleNum] then
        return textureCache[styleNum];
    end

    local datNum = styleNum + 13;  -- style 1 = ROM/0/14.DAT
    local datPath = getGamePath() .. 'ROM\\0\\' .. datNum .. '.DAT';

    local f = io.open(datPath, 'rb');
    if f == nil then return nil; end
    local data = f:read('*a');
    f:close();

    local pixelStart, w, h = findNewtexInDAT(data);
    if pixelStart == nil then return nil; end

    local pixels = decodeDXT1(data, pixelStart, w, h);
    local tex, handle = createTextureFromPixels(pixels, w, h);

    if tex and handle then
        textureObjects[styleNum] = tex;
        textureCache[styleNum] = handle;
        return handle;
    end
    return nil;
end

------------------------------------------------------------
-- Get background handle for the current style (or a specific one)
------------------------------------------------------------
textures.getMenuBackground = function(styleNum)
    styleNum = styleNum or 1;
    return textures.loadStyle(styleNum);
end

-- Preload all styles
textures.preloadAll = function()
    for i = 1, 6 do
        textures.loadStyle(i);
    end
end

return textures;
