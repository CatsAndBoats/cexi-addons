--[[
* Copyright (c) 2023 tirem [github.com/tirem] under the GPL-3.0 license
]]--

require('common')
local d3d8 = require('d3d8');
local ffi = require('ffi');
local d3d8_device = d3d8.get_device();

local imageCache = {};

local renderInfo = T{};

local sprites = {};

-- Reference to manually rendered text so that we can render over these sprites
sprites.textRenderInfo = T{};

local sprite = nil;

local function create_sprite()
	local sprite_ptr = ffi.new('ID3DXSprite*[1]');
	if (ffi.C.D3DXCreateSprite(d3d8_device, sprite_ptr) ~= ffi.C.S_OK) then
		error('failed to make sprite obj');
	end
	return d3d8.gc_safe_release(ffi.cast('ID3DXSprite*', sprite_ptr[0]));
end	

local function load_image_from_path(path)

	-- retrieve cached image
	if (imageCache[path] ~= nil) then
		return imageCache[path][1], imageCache[path][2], imageCache[path][3];
	end

    if (path == nil or path == '' or not ashita.fs.exists(path)) then
        return nil, 0, 0;
    end

    local dx_texture_ptr = ffi.new('IDirect3DTexture8*[1]');
	local imageInfo = ffi.new('D3DXIMAGE_INFO');

	local returnImage = nil;
	-- use black as colour-key for transparency
	if (ffi.C.D3DXCreateTextureFromFileExA(d3d8_device, path, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0x00000000, imageInfo, nil, dx_texture_ptr) == ffi.C.S_OK) then
		returnImage = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', dx_texture_ptr[0]));
	end

	-- cache our image and return if it's valid
	if (returnImage ~= nil) then
		imageCache[path] = {returnImage, imageInfo.Width, imageInfo.Height};
		return returnImage, imageInfo.Width, imageInfo.Height
	else
    	return nil, 0, 0;
	end
end

-- reset the icon cache and release all resources
function sprites:SetPath(NewPath)
    self.texture, self.width, self.height = load_image_from_path(NewPath);
	if (self.texture ~= nil and sprite == nil) then
		sprite = create_sprite();
	end
end

local function hex2argb(hex)
	if (hex== nil) then
		return 255,255,255,255;
	end
    hex = hex:gsub("#","")
    return tonumber("0x"..hex:sub(1,2)), tonumber("0x"..hex:sub(3,4)), tonumber("0x"..hex:sub(5,6)), tonumber("0x"..hex:sub(7,8))
end

-- expected to extract A R G B from a hex color 0xFFFFFFFF
function sprites:SetColor(newColor)
	local a,r,g,b = hex2argb(newColor);
	self.color = d3d8.D3DCOLOR_ARGB(a or 255, r or 255, g or 255, b or 255);
end

function sprites:ClearTexture()
	self.texture = nil;
	self.height = nil;
	self.width = nil;
end

function sprites:new()

	local o = {};
    setmetatable(o, self);
    self.__index = self;

	-- setup our default values
	o.visible = true;
	o.repeat_x = 0;
	o.repeat_y = 0;
	o.scale_x = 1;
	o.scale_y = 1;
	o.position_x = 0;
	o.position_y = 0;
	o.height = 0;
	o.width = 0;
	o.color = d3d8.D3DCOLOR_ARGB(255, 255, 255, 255);
	o.texture = nil;
	o.rect = ffi.new('RECT', { 0, 0, 32, 32, });
	o.vec_position = ffi.new('D3DXVECTOR2', { 0, 0, });
	o.vec_scale = ffi.new('D3DXVECTOR2', { 1.0, 1.0, });
	o.renderKey = renderInfo:length() + 1;
	renderInfo[o.renderKey] = o;

    return o;
end

function sprites:destroy()
	renderInfo[self.renderKey] = nil;
end

-- Clear our cache so all images get reloaded
sprites.ClearCache = function()
	imageCache = T{};
end

-- Render everything that is in our renderinfo
ashita.events.register('d3d_present', '__sprites_present_cb', function ()
	if (sprite ~= nil) then
		sprite:Begin();
		for _,v in pairs(renderInfo) do
			if (v.visible and v.texture ~= nil) then

				-- collect our information for rendering
				v.rect.right = v.width;
				v.rect.bottom = v.height;
				v.vec_position.x = v.position_x;
				v.vec_position.y = v.position_y;
				v.vec_scale.x = v.scale_x;
				v.vec_scale.y = v.scale_y;
				sprite:Draw(v.texture, v.rect, v.vec_scale, nil, 0.0, v.vec_position, v.color);

			end
		end
		sprite:End();
	end
	for k,v in pairs(sprites.textRenderInfo) do
		v:render();
	end
end);

return sprites;