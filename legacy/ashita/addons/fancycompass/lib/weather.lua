-- Raw weather reader + icon texture loader.
-- Uses the same FFXiMain.dll signature LuAshitacast uses for current weather.

local weather = {}
local ffi = require('ffi')
local d3d = require('d3d8')

local WEATHER_SIG      = '66A1????????663D????72'
local weather_sig_addr = 0

local d3d8dev = d3d.get_device()
ffi.cdef[[
    HRESULT __stdcall D3DXCreateTextureFromFileA(IDirect3DDevice8* pDevice, const char* pSrcFile, IDirect3DTexture8** ppTexture);
]]
local D3DX = ffi.C

local WEATHER_ELEMENT = {
    [4]  = 'fire',    [5]  = 'fire',
    [6]  = 'water',   [7]  = 'water',
    [8]  = 'earth',   [9]  = 'earth',
    [10] = 'wind',    [11] = 'wind',
    [12] = 'ice',     [13] = 'ice',
    [14] = 'thunder', [15] = 'thunder',
    [16] = 'light',   [17] = 'light',
    [18] = 'dark',    [19] = 'dark',
}

local ELEMENT_FILES = {
    'dark', 'earth', 'fire', 'ice', 'light', 'thunder', 'water', 'wind',
}

-- AddImage takes a uint32 handle, but the FFI cdata pointer must be kept
-- alive so the GC doesn't free the texture. _keep stores the cdata, _tex
-- stores the numeric handle.
local _tex  = {}
local _keep = {}

function weather.init()
    weather_sig_addr = ashita.memory.find('FFXiMain.dll', 0, WEATHER_SIG, 0, 0)
    for _, e in ipairs(ELEMENT_FILES) do
        local ptr  = ffi.new('IDirect3DTexture8*[1]')
        local path = ('%s\\imgs\\weather\\%s.png'):format(addon.path, e)
        if D3DX.D3DXCreateTextureFromFileA(d3d8dev, path, ptr) == 0 then
            local tex = ffi.new('IDirect3DTexture8*', ptr[0])
            d3d.gc_safe_release(tex)
            _keep[e] = tex
            _tex[e]  = tonumber(ffi.cast('uint32_t', tex))
        end
    end
end

function weather.get_texture(name)
    return _tex[name]
end

local function read_weather_byte()
    if weather_sig_addr == 0 then return nil end
    local ptr = ashita.memory.read_uint32(weather_sig_addr + 0x02)
    if ptr == 0 then return nil end
    return ashita.memory.read_uint8(ptr)
end

-- Cached current weather. Re-read at most once per second.
local last_check   = 0
local cached_elem  = nil
local cached_count = 0

function weather.get_current()
    local now = os.clock()
    if now - last_check >= 1.0 then
        last_check = now
        local wnum = read_weather_byte()
        if wnum == nil then
            cached_elem = nil
        else
            cached_elem = WEATHER_ELEMENT[wnum]
            if cached_elem ~= nil then
                cached_count = (wnum % 2 == 1) and 2 or 1
            end
        end
    end
    return cached_elem, cached_count
end

return weather
