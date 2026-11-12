-- Camera heading via XICamera's pointer chain.
-- Sig in FFXiMain.dll → +0x10 = address of a global that holds the camera
-- struct pointer. Three pairs of floats follow at +0x44..+0x58:
--   +0x44 / +0x50  east-west axis  (X in FFXI)
--   +0x48 / +0x54  vertical axis   (height — XICamera labels this "Z")
--   +0x4C / +0x58  north-south axis (XICamera labels this "Y")
--
-- The horizontal heading uses the X and north-south pair, NOT the
-- vertical one — the height delta is nearly constant as you orbit.

local camera = {}

local CAM_SIG = '83C40485C974118B116A01FF5218C705'
local cam_ptr_addr = 0

function camera.init()
    local sig = ashita.memory.find('FFXiMain.dll', 0, CAM_SIG, 0, 0)
    if sig ~= 0 then
        cam_ptr_addr = ashita.memory.read_uint32(sig + 0x10)
    end
end

function camera.get_base()
    if cam_ptr_addr == 0 then return nil end
    local base = ashita.memory.read_uint32(cam_ptr_addr)
    if base == 0 then return nil end
    return base
end

function camera.get_heading()
    local base = camera.get_base()
    if base ~= nil then
        local cam_x    = ashita.memory.read_float(base + 0x44)
        local cam_ns   = ashita.memory.read_float(base + 0x4C)
        local focal_x  = ashita.memory.read_float(base + 0x50)
        local focal_ns = ashita.memory.read_float(base + 0x58)
        if cam_x == cam_x and focal_x == focal_x
        and cam_x > -10000 and cam_x < 10000 then
            return math.atan2(cam_x - focal_x, cam_ns - focal_ns)
        end
    end
    local entity = GetPlayerEntity()
    return entity and entity.Heading or 0
end

return camera
