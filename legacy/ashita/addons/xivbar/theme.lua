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

local theme = {}

theme.apply = function (settings)
    local options = {}

    options.total_height = 8
    options.total_width = 472
    options.offset_x = settings.Bars.OffsetX
    options.offset_y = settings.Bars.OffsetY

    options.bar_background = addon.path .. 'themes/' .. settings.Theme.Name .. '/bar_bg.png'
    options.bar_hp = addon.path .. 'themes/' .. settings.Theme.Name .. '/hp_fg.png'
    options.bar_mp = addon.path .. 'themes/' .. settings.Theme.Name .. '/mp_fg.png'
    options.bar_tp = addon.path .. 'themes/' .. settings.Theme.Name .. '/tp_fg.png'

    options.font = settings.Texts.Font
    options.font_size = settings.Texts.Size
    options.font_color_red = settings.Texts.Color.Red
    options.font_color_green = settings.Texts.Color.Green
    options.font_color_blue = settings.Texts.Color.Blue
    options.font_stroke_width = settings.Texts.Stroke.Width
    options.font_stroke_color_red = settings.Texts.Stroke.Red
    options.font_stroke_color_green = settings.Texts.Stroke.Green
    options.font_stroke_color_blue = settings.Texts.Stroke.Blue
    options.full_tp_color_red = settings.Texts.FullTpColor.Red
    options.full_tp_color_green = settings.Texts.FullTpColor.Green
    options.full_tp_color_blue = settings.Texts.FullTpColor.Blue

    options.full_tp_color_red = settings.Texts.FullTpColor.Red
    options.full_tp_color_green = settings.Texts.FullTpColor.Green
    options.full_tp_color_blue = settings.Texts.FullTpColor.Blue

    options.mid_hp_color_red = settings.Texts.HpMid.Red
    options.mid_hp_color_green = settings.Texts.HpMid.Green
    options.mid_hp_color_blue = settings.Texts.HpMid.Blue

    options.low_hp_color_red = settings.Texts.HpLow.Red
    options.low_hp_color_green = settings.Texts.HpLow.Green
    options.low_hp_color_blue = settings.Texts.HpLow.Blue

    options.critical_hp_color_red = settings.Texts.HpCritical.Red
    options.critical_hp_color_green = settings.Texts.HpCritical.Green
    options.critical_hp_color_blue = settings.Texts.HpCritical.Blue

    options.text_offset = settings.Texts.Offset

    options.bar_width = settings.Theme.Bar.Width
    options.bar_spacing = settings.Theme.Bar.Spacing
    options.bar_offset = settings.Theme.Bar.Offset

    options.dim_tp_bar = settings.Theme.DimTpBar
    options.use_hp_colors = settings.Theme.ColorHpText

    if settings.Theme.Compact then
        options.bar_background = addon.path .. 'themes/' .. settings.Theme.Name .. '/bar_compact.png'
        options.total_width = 422
        options.bar_width = settings.Theme.Bar.Compact.Width
        options.bar_spacing = settings.Theme.Bar.Compact.Spacing
        options.bar_offset = settings.Theme.Bar.Compact.Offset
    end

    options.screen_x = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0001', 1024) / 2 - (options.total_width / 2)
    options.screen_y = AshitaCore:GetConfigurationManager():GetFloat('boot', 'ffxi.registry', '0002', 768) - 60

    return options
end

return theme