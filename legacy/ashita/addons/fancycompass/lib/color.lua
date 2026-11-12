-- ABGR uint32 <-> RGBA float[4] conversions (for ImGui.ColorEdit3/4).

local color = {}

function color.abgr_to_rgba(c)
    return {
        (c % 0x100) / 0xFF,
        (math.floor(c / 0x100)    % 0x100) / 0xFF,
        (math.floor(c / 0x10000)  % 0x100) / 0xFF,
        (math.floor(c / 0x1000000) % 0x100) / 0xFF,
    }
end

function color.rgba_to_abgr(t)
    return math.floor(t[4] * 0xFF) * 0x1000000
         + math.floor(t[3] * 0xFF) * 0x10000
         + math.floor(t[2] * 0xFF) * 0x100
         + math.floor(t[1] * 0xFF)
end

return color
