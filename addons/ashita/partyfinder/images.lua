------------------------------------------------------------------
----- All credit to atom0s for providing texture loading code ----
------------------------------------------------------------------
require 'common';
local ffi       = require('ffi');
local d3d       = require('d3d8');
local C         = ffi.C;
local d3d8dev   = d3d.get_device();

ffi.cdef[[
    // Exported from Addons.dll
    HRESULT __stdcall D3DXCreateTextureFromFileA(IDirect3DDevice8* pDevice, const char* pSrcFile, IDirect3DTexture8** ppTexture);
]];

local images = {}

local function loadTexture(textures, name)
    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileA(d3d8dev, string.format('%s/images/%s.png', addon.path, name), texture_ptr);
    if (res ~= C.S_OK) then
        error(('Failed to load image texture: %08X (%s)'):fmt(res, d3d.get_error(res)));
    end;
    textures[name] = ffi.new('IDirect3DTexture8*', texture_ptr[0]);
    d3d.gc_safe_release(textures[name]);
end

images.loadTextures = function()
    local textures = T{}

    loadTexture(textures, 'modes')
    loadTexture(textures, 'icons')
    loadTexture(textures, 'jobs')
    loadTexture(textures, 'comments')

    return textures;
end

return images;
