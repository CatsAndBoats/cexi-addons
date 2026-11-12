local sound = {};

-- Play a sound file
function sound.play(sound_file)
    local fullpath = string.format('%s\\sounds\\%s', addon.path, sound_file);
    ashita.misc.play_sound(fullpath);
end

return sound;