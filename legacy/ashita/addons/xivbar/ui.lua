--[[
        Copyright © 2017, SirEdeonX
        All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:

            * Redistributions of source code must retain the above copyright
              notice, this list of conditions and the following disclaimer.
            * Redistributions in binary form must reproduce the above copyright
              notice, this list of conditions and the following disclaimer in the
              documentation and/or other materials provided with the distribution.
            * Neither the name of xivbar nor the
              names of its contributors may be used to endorse or promote products
              derived from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL SirEdeonX BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
        LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
        ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
        (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
        SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]


local ui = {}

-- setup images
function setup_image(image, path)
    if (image) then
        image:SetPath(path);
        image.visible = true;
    end
end

-- setup text
local function get_text_settings(theme_options)
    local font_settings = {
        box_height = 0,
        box_width = 0,
        font_alignment = texts.Alignment.Center;
        font_color = tonumber(string.format('%02x%02x%02x%02x', 255, theme_options.font_color_red, theme_options.font_color_green, theme_options.font_color_blue), 16),
        font_family = texts:get_font_available(theme_options.font) and theme_options.font or 'Arial',
        font_flags = texts.FontFlags.Bold,
        font_height = theme_options.font_size,
        gradient_color = 0x00000000,
        gradient_style = 0,

        outline_color = tonumber(string.format('%02x%02x%02x%02x', 255, theme_options.font_stroke_color_red, theme_options.font_stroke_color_green, theme_options.font_stroke_color_blue), 16),
        outline_width = theme_options.font_stroke_width,
    
        position_x = 0,
        position_y = 0,
        text = '',
    };
    return font_settings;
end

function update_text(textObject, theme_options)
    if (textObject == nil) then return; end

    textObject:set_font_height(theme_options.font_size);
    textObject:set_outline_width(theme_options.font_stroke_width);
    textObject:set_font_color(tonumber(string.format('%02x%02x%02x%02x', 255, theme_options.font_color_red, theme_options.font_color_green, theme_options.font_color_blue), 16))
    textObject:set_font_family(texts:get_font_available(theme_options.font) and theme_options.font or 'Arial');
    textObject:set_outline_color(tonumber(string.format('%02x%02x%02x%02x', 255, theme_options.font_stroke_color_red, theme_options.font_stroke_color_green, theme_options.font_stroke_color_blue), 16))
end

-- load the images and text
function ui:load(theme_options)
    ui.background = images:new()
    ui.hp_bar = images:new()
    ui.mp_bar = images:new()
    ui.tp_bar = images:new()

    setup_image(self.background, theme_options.bar_background)
    setup_image(self.hp_bar, theme_options.bar_hp)
    setup_image(self.mp_bar, theme_options.bar_mp)
    setup_image(self.tp_bar, theme_options.bar_tp)

    local textSettings = get_text_settings(theme_options);
    ui.hp_text = texts:create_object(textSettings, false);
    ui.mp_text = texts:create_object(textSettings, false)
    ui.tp_text = texts:create_object(textSettings, false)

    self:position(theme_options)
end

function ui:reload(theme_options)
    setup_image(self.background, theme_options.bar_background)
    setup_image(self.hp_bar, theme_options.bar_hp)
    setup_image(self.mp_bar, theme_options.bar_mp)
    setup_image(self.tp_bar, theme_options.bar_tp)
    update_text(self.hp_text, theme_options)
    update_text(self.mp_text, theme_options)
    update_text(self.tp_text, theme_options)

    ui:position(theme_options);
end

-- position the images and text
function ui:position(theme_options)
    local x = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0001', 1024) / 2 - (theme_options.total_width / 2) + theme_options.offset_x
    local y = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0002', 768) - 60 + theme_options.offset_y

    self.background.position_x = x
    self.background.position_y = y

    self.hp_bar.position_x = x + 15 + theme_options.bar_offset
    self.hp_bar.position_y = y + 2
    self.mp_bar.position_x = x + 25 + theme_options.bar_offset + theme_options.bar_width + theme_options.bar_spacing
    self.mp_bar.position_y = y + 2
    self.tp_bar.position_x = x + 35 + theme_options.bar_offset + (theme_options.bar_width*2) + (theme_options.bar_spacing*2)
    self.tp_bar.position_y = y + 2

    self.hp_text:set_position_x(x + 80 + theme_options.text_offset)
    self.hp_text:set_position_y(self.background.position_y + 5)
    self.mp_text:set_position_x(x + 95 + theme_options.text_offset + theme_options.bar_width + theme_options.bar_spacing)
    self.mp_text:set_position_y(self.background.position_y + 5)
    self.tp_text:set_position_x(x + 105 + theme_options.text_offset + (theme_options.bar_width*2) + (theme_options.bar_spacing*2))
    self.tp_text:set_position_y(self.background.position_y + 5)
end

-- hide ui
function ui:hide()
    if (self.background == nil) then return; end;
    self.background.visible = false
    self.hp_bar.visible = false
    self.hp_text:set_visible(false);
    self.mp_bar.visible = false
    self.mp_text:set_visible(false);
    self.tp_bar.visible = false
    self.tp_text:set_visible(false);
end

-- show ui
function ui:show()
    if (self.background == nil) then return; end;
    self.background.visible = true
    self.hp_bar.visible = true
    self.hp_text:set_visible(true);
    self.mp_bar.visible = true
    self.mp_text:set_visible(true);
    self.tp_bar.visible = true
    self.tp_text:set_visible(true);
end

return ui