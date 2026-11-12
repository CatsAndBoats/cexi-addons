addon.author   = 'Hokuten - Modified by Vekien'
addon.name     = 'cam'
addon.version  = '1.0.0'
addon.desc     = 'Modifies camera pan speed and jitter.'

local common = require('common')
local settings = require('settings')

local default_settings = T{
	horizontalPanSpeed = 5,
	verticalPanSpeed = 5,
}
local configs = settings.load(default_settings)

local horizontalPanSpeedPtr
local oringinalHorizontalPanSpeed
local verticalPanSpeedPtr
local oringinalVerticalPanSpeed
local jittersSig
local newJitterPtr
local originalJitterPtr

local verticalSpeedMap = {}
for i = 1, 10 do
    verticalSpeedMap[i] = math.floor(i * 3.3)
end

local function update_settings(s)
    if (s ~= nil) then
        configs = s
    end
    settings.save()
    set_values()
end

settings.register('settings', 'settings_update', update_settings)

function setHorizontalPanSpeed(newSpeed)
    configs.horizontalPanSpeed = newSpeed
    ashita.memory.write_float(horizontalPanSpeedPtr, newSpeed / 100.0)
end

function setVerticalPanSpeed(newSpeed)
    local mapped = verticalSpeedMap[newSpeed] or newSpeed
    configs.verticalPanSpeed = mapped
    ashita.memory.write_float(verticalPanSpeedPtr, mapped / 100.0)
end

function set_values()
    setHorizontalPanSpeed(configs.horizontalPanSpeed)
    setVerticalPanSpeed(configs.verticalPanSpeed)
end

ashita.events.register('load', 'camera_load', function()
    local hPanSpeedSig = ashita.memory.find('FFXiMain.dll', 0, 'D84C24208B068BCED80D', 0, 0)
    if (hPanSpeedSig == 0) then error('Failed to locate hPanSpeedSig!') end
    horizontalPanSpeedPtr = ashita.memory.read_uint32(hPanSpeedSig + 0x0A)
    oringinalHorizontalPanSpeed = ashita.memory.read_float(horizontalPanSpeedPtr)
    ashita.memory.unprotect(horizontalPanSpeedPtr, 4)

    local vPanSpeedSig = ashita.memory.find('FFXiMain.dll', 0, 'D84C24248B168BCED80D', 0, 0)
    if (vPanSpeedSig == 0) then error('Failed to locate vPanSpeedSig!') end
    verticalPanSpeedPtr = ashita.memory.read_uint32(vPanSpeedSig + 0x0A)
    oringinalVerticalPanSpeed = ashita.memory.read_float(verticalPanSpeedPtr)
    ashita.memory.unprotect(verticalPanSpeedPtr, 4)

    jittersSig = ashita.memory.find('FFXiMain.dll', 0, '8D54242C8D44242CD8C9525550', 0, 0)
    if (jittersSig == 0) then error('Failed to locate jittersSig!') end
    newJitterPtr = ashita.memory.alloc(4)
    ashita.memory.write_float(newJitterPtr, 1.0)
    originalJitterPtr = ashita.memory.read_uint32(jittersSig + 0x0F)
    ashita.memory.unprotect(jittersSig + 0x0F, 4)
    ashita.memory.unprotect(jittersSig + 0x1F, 4)
    ashita.memory.write_uint32(jittersSig + 0x0F, newJitterPtr)
    ashita.memory.write_uint32(jittersSig + 0x1F, newJitterPtr)

    set_values()
end)

ashita.events.register('command', 'camera_command', function(e)
    local command_args = e.command:lower():args()

    if command_args[1] == '/cam' then
        local sub = command_args[2]
        local speed = tonumber(command_args[3])

        if sub == 'h' and speed then
            setHorizontalPanSpeed(speed)
            settings.save()
            print("Horizontal pan speed changed to " .. speed)
        elseif sub == 'v' and speed then
            setVerticalPanSpeed(speed)
            settings.save()
            print("Vertical pan speed changed to " .. speed)
        elseif sub == 's' then
            local hSpeed = tonumber(command_args[3])
            local vSpeed = tonumber(command_args[4])
            if hSpeed and vSpeed then
                setHorizontalPanSpeed(hSpeed)
                setVerticalPanSpeed(vSpeed)
                settings.save()
                print("Horizontal pan speed changed to " .. hSpeed)
                print("Vertical pan speed changed to " .. vSpeed)
            else
                print("Usage: /cam s <horizontal> <vertical>")
            end
        elseif sub == 'help' then
            print("Set Horizontal Pan Speed: /cam h <###> (Default: 5)")
            print("Set Vertical Pan Speed: /cam v <###> (Default: 5)")
            print("Set Both: /cam s <horizontal> <vertical>")
            print("Status: /cam status")
        elseif sub == 'status' then
            print("- status")
            print("-  horizontalPanSpeed: " .. configs.horizontalPanSpeed)
            print("-  verticalPanSpeed: " .. configs.verticalPanSpeed)
        end
    end

    return false
end)

local restore_pointers = function()
    if (horizontalPanSpeedPtr ~= 0 and horizontalPanSpeedPtr ~= nil) then
        ashita.memory.write_float(horizontalPanSpeedPtr, oringinalHorizontalPanSpeed)
    end
    if (verticalPanSpeedPtr ~= 0 and verticalPanSpeedPtr ~= nil) then
        ashita.memory.write_float(verticalPanSpeedPtr, oringinalVerticalPanSpeed)
    end
    if (jittersSig ~= 0 and jittersSig ~= nil) then
        ashita.memory.write_uint32(jittersSig + 0x0F, originalJitterPtr)
        ashita.memory.write_uint32(jittersSig + 0x1F, originalJitterPtr)
        ashita.memory.dealloc(newJitterPtr, 4)
    end
end

ashita.events.register('unload', 'camera_unload', function()
    settings.save()
    restore_pointers()
end)