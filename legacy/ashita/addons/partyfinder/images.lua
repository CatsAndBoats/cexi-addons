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
    local path = string.format('%s/images/%s.png', addon.path, name):gsub('[\\/]+', '\\');
    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileA(d3d8dev, path, texture_ptr);
    if (res ~= C.S_OK) then
        error(('Failed to load image texture %s: %08X (%s)'):fmt(path, res, d3d.get_error(res)));
    end;
    textures[name] = ffi.new('IDirect3DTexture8*', texture_ptr[0]);
    d3d.gc_safe_release(textures[name]);
end

images.loadTextures = function()
    local textures = T{}

    loadTexture(textures, 'modes')
    loadTexture(textures, 'jobs')
    loadTexture(textures, 'icons')
    loadTexture(textures, 'LFG')
    loadTexture(textures, 'bell')
    loadTexture(textures, 'roles')
    loadTexture(textures, 'gear')

    return textures;
end

images.loadFromFile = function(filename)
    if (filename == nil or filename == '') then return nil, 'empty', ''; end
    local path = string.format('%s/images/%s', addon.path, filename):gsub('[\\/]+', '\\');
    local exists = ashita.fs.exists(path);
    local texture_ptr = ffi.new('IDirect3DTexture8*[1]');
    local res = C.D3DXCreateTextureFromFileA(d3d8dev, path, texture_ptr);
    if (res ~= C.S_OK) then
        return nil, string.format('%08X (%s)', res, d3d.get_error(res)), path, exists;
    end
    local tex = ffi.new('IDirect3DTexture8*', texture_ptr[0]);
    d3d.gc_safe_release(tex);
    return tex, nil, path, exists;
end

return images;
