addon.author   = 'WinterSolstice8, atom0s for the patch';
addon.name     = 'nolock';
addon.version  = '1.0.0';

-- Credit to the original pattern & assembly patch is atom0s, thank you as always!
local engagePattern = "66FF81????????66C781????????0807C3"
local engageAddr = ashita.memory.find("FFXiMain.dll", 0, engagePattern, 0, 0)
local backupASM = 0

ashita.events.register("load", "load_cb", function()
    if engageAddr ~= 0 then
        backupASM = ashita.memory.read_array(engageAddr, 7)
        -- NOP it out
        ashita.memory.write_array(engageAddr, {0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90})
    else
        print("[nolock] Could not locate address to patch")
    end
end)

ashita.events.register("unload", "unload_cb", function()
    if engageAddr ~= 0 and backupASM ~= 0 then
        ashita.memory.write_array(engageAddr, backupASM)
    end
end)
