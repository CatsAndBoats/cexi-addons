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

-- Addon description
addon.name = 'xivbar'
addon.author = ' Tirem (Rework) Edeon (Original)'
addon.version = '1.0.0'

-- Libs
local settingsLib = require('settings');
images = require('libs/sprites')
texts  = require('libs/gdifonts/include')

local configMenu = require('config');

local bLoggedIn = false;
local playerIndex = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
if playerIndex ~= 0 then
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local flags = entity:GetRenderFlags0(playerIndex);
    if (bit.band(flags, 0x200) == 0x200) and (bit.band(flags, 0x4000) == 0) then
        bLoggedIn = true;
	end
end

--Thanks to Velyn for the event system and interface hidden signatures!
local pGameMenu = ashita.memory.find('FFXiMain.dll', 0, "8B480C85C974??8B510885D274??3B05", 16, 0);
local pEventSystem = ashita.memory.find('FFXiMain.dll', 0, "A0????????84C0741AA1????????85C0741166A1????????663B05????????0F94C0C3", 0, 0);
local pInterfaceHidden = ashita.memory.find('FFXiMain.dll', 0, "8B4424046A016A0050B9????????E8????????F6D81BC040C3", 0, 0);

local function GetMenuName()
    local subPointer = ashita.memory.read_uint32(pGameMenu);
    local subValue = ashita.memory.read_uint32(subPointer);
    if (subValue == 0) then
        return '';
    end
    local menuHeader = ashita.memory.read_uint32(subValue + 4);
    local menuName = ashita.memory.read_string(menuHeader + 0x46, 16);
    return string.gsub(tostring(menuName), '\x00', '');
end

local function GetEventSystemActive()
    if (pEventSystem == 0) then
        return false;
    end
    local ptr = ashita.memory.read_uint32(pEventSystem + 1);
    if (ptr == 0) then
        return false;
    end

    return (ashita.memory.read_uint8(ptr) == 1);

end

local function GetInterfaceHidden()
    if (pEventSystem == 0) then
        return false;
    end
    local ptr = ashita.memory.read_uint32(pInterfaceHidden + 10);
    if (ptr == 0) then
        return false;
    end

    return (ashita.memory.read_uint8(ptr + 0xB4) == 1);
end


local function GetGameInterfaceHidden()

	if (GetEventSystemActive()) then
		return true;
	end
	if (string.match(GetMenuName(), 'map')) then
		return true;
	end
    if (GetInterfaceHidden()) then
        return true;
    end
	if (bLoggedIn == false) then
		return true;
	end
    return false;
end

-- Load theme options according to settings
-- User settings
local defaults = require('defaults')
settings = settingsLib.load(defaults);
local theme = require('theme')

local xivbar = require('variables')

gTheme_options = theme.apply(settings)

-- Addon Dependencies
local ui = require('ui')
local player = require('player')


-- initialize addon
local function re_initialize()
    if xivbar.initialized == true then
        gTheme_options = theme.apply(settings)
        ui:reload(gTheme_options);
        xivbar.hp_bar_width = 0
        xivbar.mp_bar_width = 0
        xivbar.tp_bar_width = 0
        xivbar.update_hp = true
        xivbar.update_tp = true
        xivbar.update_mp = true
    end
end

local function initialize()
    if xivbar.initialized == true then return; end
    gTheme_options = theme.apply(settings)
    ui:load(gTheme_options)

    local ashitaParty = AshitaCore:GetMemoryManager():GetParty();
    local ashitaPlayer = AshitaCore:GetMemoryManager():GetPlayer();
	
    if ashitaPlayer ~= nil and ashitaParty ~= nil then
        player.hpp = math.clamp(ashitaParty:GetMemberHPPercent(0), 0, 100);
        player.mpp = math.clamp(ashitaParty:GetMemberMPPercent(0), 0, 100);
        player.current_hp = ashitaParty:GetMemberHP(0);
        player.current_mp = ashitaParty:GetMemberMP(0);
        player.current_tp = ashitaParty:GetMemberTP(0);

        player:calculate_tpp()

        xivbar.initialized = true
    end
end

function OnSettingsUpdated()
    if xivbar.initialized == true then
        re_initialize();
    else
        initialize();
    end
end

function UpdateSettings(s)
    if (s ~= nil) then
        settings = s;
    end
    OnSettingsUpdated();
    settingsLib.save();
end

settingsLib.register('settings', 'settings_update', function (s)
    UpdateSettings(s);
end);

local function GetHPTextColor(val)
    local color = { gTheme_options.font_color_red, gTheme_options.font_color_green, gTheme_options.font_color_blue }
    if val >= 0 then
        if val < 25 then
            color = { gTheme_options.critical_hp_color_red, gTheme_options.critical_hp_color_green, gTheme_options.critical_hp_color_blue }
        elseif val < 50 then
            color = { gTheme_options.low_hp_color_red, gTheme_options.low_hp_color_green, gTheme_options.low_hp_color_blue }
        elseif val < 75 then
            color = { gTheme_options.mid_hp_color_red, gTheme_options.mid_hp_color_green, gTheme_options.mid_hp_color_blue }
        end
    end
    return color;
end

-- update a bar
local function update_bar(bar, text, width, current, pp, flag)
    local old_width = width
    local new_width = math.floor((pp / 100) * gTheme_options.bar_width)

    if new_width ~= nil and new_width >= 0 then
        if old_width == new_width then
            if new_width == 0 then
                bar.visible = false
            end

            if flag == 1 then
                xivbar.update_hp = false
            elseif flag == 2 then
                xivbar.update_mp = false
            elseif flag == 3 then
                xivbar.update_tp = false
            end
        else
            local x = old_width

            if old_width < new_width then
                x = old_width + math.ceil((new_width - old_width) * 0.1)

                x = math.min(x, gTheme_options.bar_width)
            elseif old_width > new_width then
                x = old_width - math.ceil((old_width - new_width) * 0.1)

                x = math.max(x, 0)
            end

            if flag == 1 then
                xivbar.hp_bar_width = x
            elseif flag == 2 then
                xivbar.mp_bar_width = x
            elseif flag == 3 then
                xivbar.tp_bar_width = x
            end

            bar.width = x;
            bar.height = gTheme_options.total_height;
            bar.visible = true;
        end
    end

    -- figure out colors
    if flag == 3 and current > 1000 then
        text:set_font_color(tonumber(string.format('%02x%02x%02x%02x', 255, gTheme_options.full_tp_color_red, gTheme_options.full_tp_color_green, gTheme_options.full_tp_color_blue), 16));
    elseif (flag == 1 and gTheme_options.use_hp_colors) then
        local color = GetHPTextColor(player.hpp)
        text:set_font_color(tonumber(string.format('%02x%02x%02x%02x', 255, color[1], color[2], color[3]), 16))
    else
        text:set_font_color(tonumber(string.format('%02x%02x%02x%02x', (gTheme_options.dim_tp_bar and flag == 3 and 100) or 255, gTheme_options.font_color_red, gTheme_options.font_color_green, gTheme_options.font_color_blue), 16));
    end

    text:set_text(tostring(current))
end

-- hide the addon
local function hide()
    ui:hide()
    xivbar.ready = false
end

-- show the addon
local function show()

    initialize()

    ui:show()
    xivbar.ready = true
    xivbar.update_hp = true
    xivbar.update_mp = true
    xivbar.update_tp = true
end


-- Bind Events
-- ON LOAD
ashita.events.register('load', 'load_cb', function ()
    if GetGameInterfaceHidden() == false then
        show()
    end
end)


local function CheckVitals()
    local ashitaParty = AshitaCore:GetMemoryManager():GetParty();
	
    if ashitaParty ~= nil then

        local currentHpp = math.clamp(ashitaParty:GetMemberHPPercent(0), 0, 100);
        if (player.hpp ~= currentHpp) then
            player.hpp = currentHpp
            xivbar.update_hp = true
        end

        local currentMpp = math.clamp(ashitaParty:GetMemberMPPercent(0), 0, 100);
        if (player.mpp ~= currentMpp) then
            player.mpp = currentMpp
            xivbar.update_mp = true
        end

        local current_hp = ashitaParty:GetMemberHP(0);
        if (player.current_hp ~= current_hp) then
            player.current_hp = current_hp
            xivbar.update_hp = true
        end

        local current_mp = ashitaParty:GetMemberMP(0);
        if (player.current_mp ~= current_mp) then
            player.current_mp = current_mp
            xivbar.update_mp = true
        end

        local current_tp = ashitaParty:GetMemberTP(0);
        if (player.current_tp ~= current_tp) then
            player.current_tp = current_tp
            player:calculate_tpp()
            xivbar.update_tp = true
        end
    end
end

ashita.events.register('d3d_present', 'present_cb', function ()

    -- handle hiding bars
    if xivbar.hide_bars == false and GetGameInterfaceHidden() == true then
        xivbar.hide_bars = true
        hide()
    elseif xivbar.hide_bars == true and GetGameInterfaceHidden() == false then
        xivbar.hide_bars = false
        show()
    end

    CheckVitals();

    if xivbar.ready == false then
        return
    end

    if xivbar.update_hp then
        update_bar(ui.hp_bar, ui.hp_text, xivbar.hp_bar_width, player.current_hp, player.hpp, 1)
    end

    if xivbar.update_mp then
        update_bar(ui.mp_bar, ui.mp_text, xivbar.mp_bar_width, player.current_mp, player.mpp, 2)
    end

    if xivbar.update_tp then
        update_bar(ui.tp_bar, ui.tp_text, xivbar.tp_bar_width, player.current_tp, player.tpp, 3)
    end
end)

ashita.events.register('packet_in', '__xivbar_packet_in_cb', function (e)
    
    -- Track our logged in status
    if (e.id == 0x00A) then
        bLoggedIn = true;
	elseif (e.id == 0x00B) then
        bLoggedIn = false;
    end
end);

ashita.events.register('unload', 'load_cb', function ()
    texts:destroy_interface();
end)