addon.name    = 'FancyCompass'
addon.author  = 'Arielfy'
addon.version = '1.0'
addon.desc    = 'Compass and clock replacement'
addon.link    = ''

require 'common'

local imgui    = require('imgui')
local settings = require('settings')
local pi       = math.pi

-- Helper modules
local camera  = require('lib.camera')
local vana    = require('lib.vana')
local grid    = require('lib.grid')
local weather = require('lib.weather')
local color   = require('lib.color')
local chat_anchor = require('lib.chat_anchor')
local menu        = require('lib.menu')

-- Forward declaration so functions defined here can close over the
-- local `cfg` that's populated below from settings.load().
local cfg

-- In-game compass HUD patch. The signature is part of a function's
-- opcodes; the byte at +0x24 controls whether the in-game compass is
-- drawn. Writing 0 over it hides the HUD compass; we cache the
-- original byte so we can restore it later or on unload.
local INGAME_COMPASS_SIG  = '33C0668B81????????483DE3000000'
local ingame_compass_addr = 0
local ingame_compass_orig = nil
local patch_done = false
local login_time = 0

local function init_ingame_compass_patch()
    ingame_compass_addr = ashita.memory.find('FFXiMain.dll', 0, INGAME_COMPASS_SIG, 0, 0)
    if ingame_compass_addr ~= 0 then
        ashita.memory.unprotect(ingame_compass_addr + 0x24, 1)
        local b = ashita.memory.read_uint8(ingame_compass_addr + 0x24)
        -- If we read 0, the byte was likely already patched by a previous
        -- run that didn't get to restore. The known enable value is 1.
        ingame_compass_orig = (b ~= 0) and b or 1
    end
end

local function apply_ingame_compass_patch(hide)
    if ingame_compass_addr == 0 or ingame_compass_orig == nil then return end
    ashita.memory.write_uint8(ingame_compass_addr + 0x24,
        hide and 0 or ingame_compass_orig)
end

-- In-game clock toggle. FFXI's /clock off persists in the player's
-- per-character settings file, but the setting is reset (or at least
-- needs to be re-issued) at every login. We only fire /clock off when
-- the player comes back to the lobby (login status 0) and then logs
-- back in, NOT on plain zone changes (which transition through
-- status 1 but never through 0). saw_lobby starts true so a fresh
-- addon load while already logged in still hides the clock once.
local last_login_status = -1
local saw_lobby         = true

local function apply_clock_command(hide)
    if AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus() ~= 2 then
        return
    end
    AshitaCore:GetChatManager():QueueCommand(-1,
        hide and '/clock off' or '/clock on')
end

local function check_login_for_clock()
    local s = AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus()
    if s == 0 then
        saw_lobby = true
    end
    if login_time ~= 0 and os.clock() - login_time > 3 then
        AshitaCore:GetChatManager():QueueCommand(-1, '/clock off')
        apply_ingame_compass_patch(true)
        login_time = 0
    end
    if s == 2 and last_login_status ~= 2 and saw_lobby and cfg.hide_ingame then
        login_time = os.clock()
        saw_lobby = false
    end
    last_login_status = s
end

-- -------------------------------------------------------------------------
-- Config
-- -------------------------------------------------------------------------
local default_cfg = T{
    x         = 42,
    y         = 562,
    radius    = 100,
    range     = 40,    -- yalms; entities beyond this are not rendered
    dot_size  = 3,     -- base dot radius (multiplied by size_scale)
    show_pets     = true,  -- false hides pet/trust markers entirely
    hide_ingame   = true,  -- hide both the in-game compass AND clock UI
    -- Anchor the compass to fancychat's window via UDP loopback
    -- (port 47180). Fancychat must be patched to broadcast its
    -- position for this to do anything.
    anchor_to_chat   = true,
    anchor_window    = 1,    -- 1 = primary chat window, 2 = secondary
    anchor_offset_x  = 0,    -- pixel offset from chat anchor
    anchor_offset_y  = -10,  -- negative = above the chat top edge
    -- Hide the entire compass overlay (and the clock/coords/weather
    -- it contains) while any FFXI menu fancychat tracks for its own
    -- chat reposition is open, OR while an NPC dialog box is up.
    hide_on_menu     = true,
    tilt          = 0.45,  -- vertical squash for 3d-on-a-table look
    -- Colors (ABGR uint32: 0xAABBGGRR)
    color_fill  = 0x98555555,
    color_ring  = 0x999A9A9A,
    color_tick  = 0x7FC2C2C2,
    color_cross = 0x66E6E6E6,
    color_card  = 0x7FBFBFBF,
    color_n     = 0xE62E2EE6,
    color_npc   = 0x1944DD44,
    color_pc    = 0x19FF8844,
    color_mob   = 0x193344FF,
    color_pet   = 0x1944DDDD,
    color_stamp = 0xE5FFFFFF,
}

cfg = settings.load(default_cfg)

-- Defensive defaults for keys that may be missing from an older
-- saved settings file (settings.load doesn't always merge new
-- defaults into pre-existing configs).
if cfg.hide_on_menu     == nil then cfg.hide_on_menu     = true end
-- Strip dead keys from older settings.
cfg.dodge_cat7_menus = nil
cfg.cat7_detect_w    = nil
cfg.cat7_landing_h   = nil
cfg.cat7_margin_w    = nil
cfg.cat7_margin_h    = nil

settings.register('settings', 'compass_settings_update', function(s)
    if s ~= nil then cfg = s end
    settings.save()
end)

local visible          = { true }
local debug_mode       = false
local force_pos        = true   -- true => apply cfg.x/y to the window on next frame
local settings_visible = { false }

-- Throttled scans, framerate-independent (seconds). At ~60 Hz, 50 ms
-- ≈ 3 frames, same as before; at 120 Hz it stays at 50 ms instead of
-- becoming 25 ms.
local SCAN_INTERVAL_S = 0.05

-- Pet-index detection: rebuilt every SCAN_INTERVAL_S seconds. Reuses the
-- same table to avoid GC churn.
local pets_cache       = {}
local pets_last_rebuild = -math.huge   -- forces an initial rebuild

-- Entity scan: the full 2304-slot sweep + classification is the
-- expensive part. We cache per-visible-entity (dx, dy, rgb, edge_a)
-- every interval and re-render from that cache (with the live camera
-- heading) every frame in between.
local entity_cache           = {}   -- pre-allocated; reused entries
local entity_cache_n         = 0
local entity_last_rebuild    = -math.huge

-- Per-frame dot list. Reused across frames so we don't allocate a
-- fresh table + n inner tables every frame. dots_n tracks the live
-- prefix; entries beyond it are stale but kept around for reuse.
local dots                   = {}
local dots_n                 = 0
local function _dot_sort_cmp(a, b)
    if a.y ~= b.y then return a.y < b.y end
    return a.x < b.x
end

-- Sparse "active" slot list: ~99% of the 2304 entity slots are empty,
-- so iterating all of them every 50 ms just to call GetServerId is
-- pure C++<->Lua call overhead. Instead, we walk a small CHUNK of
-- the full slot range each tick (rescan_cursor advances and wraps),
-- adding newly seen entities to active_slots. The per-tick
-- classification walk handles the reverse direction: any active
-- entity whose ServerId has gone to 0 (de-spawned / left range)
-- gets compacted out in the same pass that classifies the rest.
-- A full 2304-slot cycle completes in (2304 / CHUNK_SIZE) ticks,
-- so new-spawn discovery latency = that many * SCAN_INTERVAL_S.
local active_slots   = {}
local active_n       = 0
local active_set     = {}    -- active_set[idx] = true iff idx is in active_slots
local CHUNK_SIZE     = 192   -- 2304 / 192 = 12 ticks * 50ms = ~600ms full cycle
local rescan_cursor  = 0     -- next start index, walks 0..2303 forever

-- Cardinal world angles (0=N, pi/2=E, pi=S, 3pi/2=W)
local CARDINALS = {
    { label = 'S', angle = 0           },
    { label = 'W', angle = pi / 2      },
    { label = 'N', angle = pi          },
    { label = 'E', angle = 3 * pi / 2  },
}

local C_DEBUG = 0xFF00FF00   -- debug overlay (not user-configurable)

-- -------------------------------------------------------------------------
-- Events
-- -------------------------------------------------------------------------
ashita.events.register('load', 'compass_load', function()
    camera.init()
    vana.init()
    grid.init()
    weather.init()
    chat_anchor.init()
    menu.init()
	init_ingame_compass_patch()
    -- If the addon is relaunched while the player is already logged in,
    -- re-fire /clock off (or /clock on) right away. Seed last_login_status
    -- so the watcher in d3d_present doesn't immediately double-fire.
    last_login_status = AshitaCore:GetMemoryManager():GetPlayer():GetLoginStatus()
end)

ashita.events.register('d3d_present', 'compass_present', function()
    check_login_for_clock()
    -- Only render once the player is fully logged in. check_login_for_clock
    -- already polled GetLoginStatus this frame and cached it in
    -- last_login_status, so we just reuse that here.
    if last_login_status ~= 2 then return end
	if not patch_done then
		apply_ingame_compass_patch(cfg.hide_ingame)
		patch_done = true
		apply_clock_command(cfg.hide_ingame)
	end
    if not visible[1] then return end

    local heading     = camera.get_heading()
    local r           = cfg.radius
    local size_scale  = r / 66          -- everything scales relative to base 66
    local pad         = 22 * size_scale
    -- Window must fit dots at the max render distance (cfg.range yalms).
    -- Ring radius is fixed at 25 yalms = compass edge.
    local outer_reach = r * cfg.range / 25
    local sz          = (outer_reach + pad) * 2

    chat_anchor.poll()
    local raw = cfg.anchor_to_chat and chat_anchor.get(cfg.anchor_window) or nil
    local anchor
    if raw then
        if raw.visible == 1 then
            -- Chat visible: use BG plate top-left as anchor, then push
            -- up by the height of anything currently stacked above the
            -- chat (docked guideme/notepad, or live item preview row
            -- on window 1 only).
            anchor = { x = raw.x, y = raw.y - (raw.extra or 0) }
        else
            -- Chat hidden (shortcut / auto-hide / window 2 disabled):
            -- shift the anchor to the BG plate's bottom-left so the
            -- compass moves down.
            anchor = { x = raw.x, y = raw.y + raw.h }
        end
    end

    local effective_x, effective_y
    if anchor then
        -- Anchor the day-circle's bottom-left bounding-box corner to
        -- (anchor + offset). We compute that point in window-local
        -- coordinates (where the window's top-left is 0,0) and subtract
        -- it from the desired world position to get the window's TL.
        local _, font_h    = imgui.CalcTextSize('M')
        local sh_est       = font_h * size_scale
        local day_r_est    = (sh_est * 0.5 - 0.5 * size_scale) * 0.8 - 1 * size_scale
        local day_bl_x_loc = sz * 0.5 - r - 16 * size_scale
        local day_bl_y_loc = sz * 0.5 + r * cfg.tilt + 11 * size_scale
                           + sh_est * 0.5 - 1 * size_scale + day_r_est
        effective_x = anchor.x + cfg.anchor_offset_x - day_bl_x_loc
        effective_y = anchor.y + cfg.anchor_offset_y - day_bl_y_loc
    else
        effective_x = cfg.x
        effective_y = cfg.y
    end

    -- Hide the whole overlay whenever any FFXI menu fancychat would
    -- have moved chat around is open. Same patterns fancychat uses
    -- for Menu1..Menu7 — no shifting, no rect math, just hide.
    if cfg.hide_on_menu and menu.is_menu_open() then return end

    -- While anchored we force the position every frame so live changes
    -- (chat moving, offset edits) follow immediately. Otherwise only
    -- force on explicit requests (e.g. /compass move), and use
    -- FirstUseEver so the user can still drag the window manually.
    if anchor or force_pos then
        imgui.SetNextWindowPos({ effective_x, effective_y }, ImGuiCond_Always)
        if not anchor then force_pos = false end
    else
        imgui.SetNextWindowPos({ effective_x, effective_y }, ImGuiCond_FirstUseEver)
    end
    imgui.SetNextWindowSize({ sz, sz }, ImGuiCond_Always)
    imgui.SetNextWindowBgAlpha(0.0)

    local wflags = ImGuiWindowFlags_NoDecoration
                 + ImGuiWindowFlags_NoNav
                 + ImGuiWindowFlags_NoBringToFrontOnFocus

    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    if imgui.Begin('##compass', visible, wflags) then
        imgui.SetWindowFontScale(size_scale)
        local dl       = imgui.GetWindowDrawList()
        local wpx, wpy = imgui.GetWindowPos()
        -- Only persist position back to cfg when the compass is in its
        -- natural (un-anchored) state — otherwise chat-following would
        -- overwrite the user's manual cfg.
        if not anchor then
            cfg.x = math.floor(wpx)
            cfg.y = math.floor(wpy)
        end
        local cx       = wpx + sz * 0.5
        local cy       = wpy + sz * 0.5
        local tilt     = cfg.tilt
        local C_RING   = cfg.color_ring
        local C_TICK   = cfg.color_tick
        local C_CROSS  = cfg.color_cross
        local C_CARD   = cfg.color_card
        local C_N      = cfg.color_n

        -- Fill the disc (drawn first so everything else layers on top).
        -- Ellipse approximated via stacked horizontal AddRectFilled strips,
        -- since Ashita's imgui binding lacks PathFillConvex.
        local disc_fill = cfg.color_fill
        local disc_h    = r * tilt
        local strips    = math.max(16, math.ceil(disc_h * 2))
        local strip_h   = (2 * disc_h) / strips
        for j = 0, strips - 1 do
            local y_top = -disc_h + j * strip_h
            local y_mid = y_top + strip_h * 0.5
            local norm  = y_mid / disc_h
            local dx    = r * math.sqrt(math.max(0, 1 - norm * norm))
            dl:AddRectFilled(
                { cx - dx, cy + y_top },
                { cx + dx, cy + y_top + strip_h },
                disc_fill
            )
        end

        -- Ring: draw as an ellipse polyline so it reads as a tilted disk.
        local segs = 64
        local px, py = cx + r, cy
        for i = 1, segs do
            local theta = (i / segs) * 2 * pi
            local nx = cx + r * math.cos(theta)
            local ny = cy + r * math.sin(theta) * tilt
            dl:AddLine({ px, py }, { nx, ny }, C_RING, 1.5)
            px, py = nx, ny
        end

        -- Crosslines: 4 diameters connecting opposite cardinal/sub-cardinal points.
        for i = 0, 3 do
            local world_a  = i * (pi / 4)
            local screen_a = world_a - heading - (pi / 2)
            local dx = r * math.cos(screen_a)
            local dy = r * math.sin(screen_a) * tilt
            dl:AddLine({ cx - dx, cy - dy }, { cx + dx, cy + dy }, C_CROSS, 1.0)
        end

        -- T-shaped markers at the 8 cardinal/sub-cardinal points.
        -- Crossbar sits just inside the ring (tangent to circle but inset so the
        -- whole T stays contained); stem points from the crossbar toward center.
        -- Tangent + inward vectors get the same vertical squash as the ring so
        -- the Ts read as if lying flat on the same surface.
        local t_inset = 2 * size_scale
        local t_bar   = 4 * size_scale
        local t_stem  = 6 * size_scale
        local t_r     = r - t_inset
        for i = 0, 7 do
            local world_a  = i * (pi / 4)
            local screen_a = world_a - heading - (pi / 2)
            local ca = math.cos(screen_a)
            local sa = math.sin(screen_a)
            local mx = cx + t_r * ca
            local my = cy + t_r * sa * tilt
            local tx = -sa            -- tangent (perpendicular to radial)
            local ty = ca * tilt
            local ix = -ca            -- inward (toward center)
            local iy = -sa * tilt
            dl:AddLine(
                { mx - t_bar * tx, my - t_bar * ty },
                { mx + t_bar * tx, my + t_bar * ty },
                C_TICK, 2.5
            )
            dl:AddLine(
                { mx, my },
                { mx + t_stem * ix, my + t_stem * iy },
                C_TICK, 2.5
            )
        end

        -- Central hub: small ellipse around the center, plus 8 short spokes
        -- toward the cardinal/sub-cardinal directions. Same perspective squash.
        local hub_r       = 5 * size_scale
        local spoke_outer = r / 3
        local hub_segs    = 32
        local hp_x, hp_y  = cx + hub_r, cy
        for i = 1, hub_segs do
            local theta = (i / hub_segs) * 2 * pi
            local hn_x  = cx + hub_r * math.cos(theta)
            local hn_y  = cy + hub_r * math.sin(theta) * tilt
            dl:AddLine({ hp_x, hp_y }, { hn_x, hn_y }, C_TICK, 2.5)
            hp_x, hp_y = hn_x, hn_y
        end
        for i = 0, 7 do
            local world_a  = i * (pi / 4)
            local screen_a = world_a - heading - (pi / 2)
            local ca = math.cos(screen_a)
            local sa = math.sin(screen_a)
            dl:AddLine(
                { cx + hub_r * ca,       cy + hub_r * sa * tilt       },
                { cx + spoke_outer * ca, cy + spoke_outer * sa * tilt },
                C_TICK, 2.5
            )
        end

        for _, card in ipairs(CARDINALS) do
            local screen_a = card.angle - heading - (pi / 2)
            local lr       = r + 10 * size_scale       -- outside the ring
            local lx       = cx + lr * math.cos(screen_a)
            local ly       = cy + lr * math.sin(screen_a) * tilt
            local tsw, tsh = imgui.CalcTextSize(card.label)
            local col      = (card.label == 'N') and C_N or C_CARD
            local tx, ty   = lx - tsw * 0.5, ly - tsh * 0.5
            -- 2px outline: stamp dark text at every offset in the 5x5 ring
            -- around the main position, then draw the fake-bold text on top.
            local outline = 0xCC000000
            for ox = -2, 2 do
                for oy = -2, 2 do
                    if ox ~= 0 or oy ~= 0 then
                        dl:AddText({ tx + ox, ty + oy }, outline, card.label)
                    end
                end
            end
            dl:AddText({ tx,     ty     }, col, card.label)
            dl:AddText({ tx + 1, ty     }, col, card.label)
            dl:AddText({ tx,     ty + 1 }, col, card.label)
            dl:AddText({ tx + 1, ty + 1 }, col, card.label)
        end

        -- NPC dots: drawn LAST so they layer on top of letters and everything
        -- else. Position math mirrors the heading derivation: same atan2 sign
        -- convention so dots line up with the (label-swapped) cardinals.
        local mm = AshitaCore:GetMemoryManager()
        local em = mm:GetEntity()
        local party = mm:GetParty()
        local p_idx = party:GetMemberTargetIndex(0)
        if p_idx ~= 0 then
            local p_x     = em:GetLocalPositionX(p_idx)
            local p_y     = em:GetLocalPositionY(p_idx)
            local range     = cfg.range         -- cutoff + fade endpoint
            local r_sq      = range * range
            local pos_scale = r / 25            -- yalms-to-pixels (ring = 25 yalms)
            local rgb_npc = cfg.color_npc % 0x1000000
            local rgb_pc  = cfg.color_pc  % 0x1000000
            local rgb_mob = cfg.color_mob % 0x1000000
            local rgb_pet = cfg.color_pet % 0x1000000
            -- The alpha stored in cfg.color_* is "transparency at max range":
            -- dots fade from fully opaque at the center to this alpha at the
            -- max render distance.
            local ea_npc  = math.floor(cfg.color_npc / 0x1000000) % 0x100
            local ea_pc   = math.floor(cfg.color_pc  / 0x1000000) % 0x100
            local ea_mob  = math.floor(cfg.color_mob / 0x1000000) % 0x100
            local ea_pet  = math.floor(cfg.color_pet / 0x1000000) % 0x100

            -- Rebuild the entity cache only every SCAN_INTERVAL_S
            -- seconds (framerate-independent). In between frames we
            -- re-transform the cached deltas with the current
            -- heading/cx/cy so camera rotation stays smooth.
            local _now = os.clock()
            if _now - entity_last_rebuild >= SCAN_INTERVAL_S then
                entity_last_rebuild = _now
                pets_last_rebuild   = _now

                -- Incremental discovery: scan CHUNK_SIZE slots starting
                -- at rescan_cursor and wrap around. We only ADD newly
                -- seen entities here (deduped via active_set). De-spawn
                -- detection happens for free in the classification walk
                -- below, so this pass doesn't need a "moment of truth".
                local last = rescan_cursor + CHUNK_SIZE - 1
                if last > 2303 then last = 2303 end
                for idx = rescan_cursor, last do
                    if idx ~= p_idx and not active_set[idx]
                       and em:GetServerId(idx) ~= 0 then
                        active_n = active_n + 1
                        active_slots[active_n] = idx
                        active_set[idx] = true
                    end
                end
                rescan_cursor = last + 1
                if rescan_cursor > 2303 then rescan_cursor = 0 end

                -- Pet set: scan owner PetTargetIndex over the active list.
                for k in pairs(pets_cache) do pets_cache[k] = nil end
                for ai = 1, active_n do
                    local owner_idx = active_slots[ai]
                    local pet_idx = em:GetPetTargetIndex(owner_idx)
                    if pet_idx ~= 0 then pets_cache[pet_idx] = true end
                end

                -- Classification + de-spawn compaction in one walk.
                entity_cache_n = 0
                local write_back = 0
                for ai = 1, active_n do
                    local idx = active_slots[ai]
                    if em:GetServerId(idx) == 0 then
                        -- De-spawned: drop from set so the chunked walk
                        -- can re-discover this slot if it gets reused.
                        active_set[idx] = nil
                    else
                        -- Keep this slot in the active list.
                        write_back = write_back + 1
                        active_slots[write_back] = idx

                        local rf = em:GetRenderFlags0(idx)
                        if bit.band(rf, 0x200) == 0x200 and bit.band(rf, 0x4000) == 0
                           and em:GetName(idx) ~= '' then
                            local et = em:GetType(idx)
                            local rgb, edge_a
                            local is_pet = pets_cache[idx]
                                        or em:GetTrustOwnerTargetIndex(idx) ~= 0
                            if is_pet then
                                if cfg.show_pets then
                                    rgb, edge_a = rgb_pet, ea_pet
                                end
                            elseif et == 0 or et == 1 or et == 2 then
                                local sf = em:GetSpawnFlags(idx)
                                if bit.band(sf, 0x10) ~= 0 then
                                    rgb, edge_a = rgb_mob, ea_mob
                                elseif et == 0 and bit.band(sf, 0x01) ~= 0 then
                                    rgb, edge_a = rgb_pc, ea_pc
                                elseif bit.band(sf, 0x02) ~= 0 then
                                    rgb, edge_a = rgb_npc, ea_npc
                                end
                            end
                            if rgb ~= nil then
                                local dx = em:GetLocalPositionX(idx) - p_x
                                local dy = em:GetLocalPositionY(idx) - p_y
                                entity_cache_n = entity_cache_n + 1
                                local e = entity_cache[entity_cache_n] or {}
                                e.dx, e.dy = dx, dy
                                e.rgb      = rgb
                                e.edge_a   = edge_a
                                entity_cache[entity_cache_n] = e
                            end
                        end
                    end
                end
                -- Trim tail if anyone de-spawned.
                for k = write_back + 1, active_n do active_slots[k] = nil end
                active_n = write_back

                -- Trim entity_cache too — stale slots beyond
                -- entity_cache_n aren't iterated by anything below,
                -- but they hold tables alive past their useful life.
                for k = entity_cache_n + 1, #entity_cache do
                    entity_cache[k] = nil
                end
            end

            -- Build the per-frame dots[] from the cached entities. We
            -- redo the heading/distance/alpha transform every frame so
            -- camera rotation and tilt changes follow live. dots[] is
            -- file-scope and reused — we just overwrite up to dots_n
            -- and ignore the stale tail.
            dots_n = 0
            local dot_radius = cfg.dot_size * size_scale
            for i = 1, entity_cache_n do
                local e = entity_cache[i]
                local d_sq = e.dx * e.dx + e.dy * e.dy
                if d_sq <= r_sq then
                    local dist  = math.sqrt(d_sq)
                    local sa    = math.atan2(-e.dx, -e.dy) - heading - (pi / 2)
                    local pd    = dist * pos_scale
                    local alpha = math.floor(0xFF - (0xFF - e.edge_a) * (dist / range))
                    dots_n = dots_n + 1
                    local d = dots[dots_n] or {}
                    d.x     = cx + pd * math.cos(sa)
                    d.y     = cy + pd * math.sin(sa) * tilt
                    d.color = alpha * 0x1000000 + e.rgb
                    dots[dots_n] = d
                end
            end
            -- table.sort sorts the WHOLE array part of `dots`, so we
            -- need to nil out any stale tail entries first (otherwise
            -- a dot from a previous frame with smaller y could float
            -- in front of this frame's live dots).
            for k = dots_n + 1, #dots do dots[k] = nil end
            -- Sort: top-to-bottom by y, left-to-right by x on ties.
            table.sort(dots, _dot_sort_cmp)
            for i = 1, dots_n do
                local d = dots[i]
                dl:AddCircleFilled({ d.x, d.y }, dot_radius, d.color)
            end
        end

        -- Live weather icon(s) at the top-left of the compass.
        -- Reads "raw weather" from FFXi memory (same sig luashitacast uses).
        -- Single weather = 1 icon, double weather = 2 icons of the same kind.
        local wx_left = cx - r - 16 * size_scale
        do
            local elem, count = weather.get_current()
            local tex = elem and weather.get_texture(elem) or nil
            if tex ~= nil and count > 0 then
                local icon_sz    = 18 * size_scale
                local double_gap = 1 * size_scale
                local row_y      = cy - r * tilt - icon_sz - 9 * size_scale
                local x          = wx_left
                for j = 1, count do
                    dl:AddImage(tex,
                        { x,           row_y           },
                        { x + icon_sz, row_y + icon_sz },
                        { 0, 0 }, { 1, 1 }, 0xCCFFFFFF)
                    x = x + icon_sz + double_gap
                end
            end
        end

        -- Day circle + time + grid coords, anchored to the LEFT edge of the
        -- compass ellipse (not the window) and placed just BELOW the ellipse.
        local vana_time, vana_day = vana.get_time()
        local stamp     = ('%s (%s)'):format(vana_time, grid.get_coords())
        -- Stamp font at the same scale as the rest of the window
        -- (no extra shrink), so the section is 1 px bigger on each side
        -- compared to the prior 2-px-smaller variant.
        local sw, sh    = imgui.CalcTextSize(stamp)
        local day_r     = (sh * 0.5 - 0.5 * size_scale) * 0.8 - 1 * size_scale
        local gap       = 5 * size_scale
        local left_edge = cx - r - 16 * size_scale
        local row_top   = cy + r * tilt + 11 * size_scale   -- 6 + 5 below ring
        local day_cx    = left_edge + day_r
        local day_cy    = row_top + sh * 0.5 - 1 * size_scale
        local stamp_x   = left_edge + 2 * day_r + gap
        local stamp_y   = row_top
        local sout      = 0xCC000000
        dl:AddCircleFilled({ day_cx, day_cy }, day_r,
            vana.DAY_COLORS[vana_day] or 0xFFEEEEEE, 24)
        dl:AddCircle({ day_cx, day_cy }, day_r, sout, 24, 1.0)
        -- Tooltip with the day name when the mouse is inside the circle.
        local mx, my = imgui.GetMousePos()
        local mdx, mdy = mx - day_cx, my - day_cy
        if mdx * mdx + mdy * mdy <= day_r * day_r then
            imgui.SetTooltip(vana.DAY_NAMES[vana_day] or 'Unknown')
        end
        for ox = -1, 1 do
            for oy = -1, 1 do
                if ox ~= 0 or oy ~= 0 then
                    dl:AddText({ stamp_x + ox, stamp_y + oy }, sout, stamp)
                end
            end
        end
        dl:AddText({ stamp_x, stamp_y }, cfg.color_stamp, stamp)

        if debug_mode then
            local base = camera.get_base()
            if base ~= nil then
                local c44 = ashita.memory.read_float(base + 0x44)
                local c48 = ashita.memory.read_float(base + 0x48)
                local c4c = ashita.memory.read_float(base + 0x4C)
                local f50 = ashita.memory.read_float(base + 0x50)
                local f54 = ashita.memory.read_float(base + 0x54)
                local f58 = ashita.memory.read_float(base + 0x58)
                local lines = {
                    ('cam  44=%.2f 48=%.2f 4C=%.2f'):format(c44, c48, c4c),
                    ('foc  50=%.2f 54=%.2f 58=%.2f'):format(f50, f54, f58),
                    ('dlt  X=%.2f Z=%.2f Y=%.2f'):format(c44-f50, c48-f54, c4c-f58),
                    ('hdg  %.4f rad'):format(heading),
                }
                local dy = 4
                for _, txt in ipairs(lines) do
                    dl:AddText({ cx - r, cy + r + dy }, C_DEBUG, txt)
                    dy = dy + 14
                end
            else
                dl:AddText({ cx - r, cy + r + 4 }, C_N, 'cam sig not found')
            end
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
end)

-- -------------------------------------------------------------------------
-- Settings window  (toggled with bare /compass)
-- -------------------------------------------------------------------------
ashita.events.register('d3d_present', 'compass_settings_ui', function()
    if not settings_visible[1] then return end

    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 12, 10 })
    if imgui.Begin('Compass Settings', settings_visible, ImGuiWindowFlags_AlwaysAutoResize) then

        local changed   = false
        local col_x     = 220  -- left edge of widgets (right of labels)
        local widget_w  = 370

        -- Compass Layout
        imgui.Text('Compass Layout')
        imgui.Separator()

        imgui.Text('Size')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_size = { cfg.radius }
        if imgui.SliderInt('##size', v_size, 15, 200) then
            cfg.radius = v_size[1]; changed = true
        end

        imgui.Text('Tilt')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_tilt = { cfg.tilt }
        if imgui.SliderFloat('##tilt', v_tilt, 0.1, 1.0, '%.2f') then
            cfg.tilt = v_tilt[1]; changed = true
        end

        imgui.Text('Entity Dot size')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_dot = { cfg.dot_size }
        if imgui.SliderFloat('##dotsize', v_dot, 1, 12, '%.1f') then
            cfg.dot_size = v_dot[1]; changed = true
        end

        if imgui.Checkbox('Show pets and trusts', { cfg.show_pets }) then
            cfg.show_pets = not cfg.show_pets; changed = true
        end

        if imgui.Checkbox('Hide compass/clock UI', { cfg.hide_ingame }) then
            cfg.hide_ingame = not cfg.hide_ingame
            apply_ingame_compass_patch(cfg.hide_ingame)
            apply_clock_command(cfg.hide_ingame)
            changed = true
        end

        imgui.Spacing()
        if imgui.Checkbox('Anchor to FancyChat', { cfg.anchor_to_chat }) then
            cfg.anchor_to_chat = not cfg.anchor_to_chat; changed = true
        end
        imgui.SameLine()
        imgui.TextDisabled('[' .. chat_anchor.status() .. ']')

        if imgui.Checkbox('Hide while FFXI menu is open',
                          { cfg.hide_on_menu }) then
            cfg.hide_on_menu = not cfg.hide_on_menu; changed = true
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Hides the entire compass overlay (ring, dots,\n'
              ..'clock, weather, coords) while any FFXI menu\n'
              ..'fancychat watches for its chat-shift is open.\n'
              ..'Matches fancychat\'s Menu1..Menu7 patterns:\n'
              ..'inventory, magic, abilities, mount, emote,\n'
              ..'shops, mog house, mog post, job change, etc.')
        end

        imgui.Text('Chat window')
        imgui.SameLine(); imgui.SetCursorPosX(col_x)
        if imgui.RadioButton('Window 1##aw1', cfg.anchor_window == 1) then
            cfg.anchor_window = 1; changed = true
        end
        imgui.SameLine()
        if imgui.RadioButton('Window 2##aw2', cfg.anchor_window == 2) then
            cfg.anchor_window = 2; changed = true
        end

        imgui.Text('Anchor offset X')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_aox = { cfg.anchor_offset_x }
        if imgui.SliderInt('##anchorox', v_aox, -400, 400) then
            cfg.anchor_offset_x = v_aox[1]; changed = true
        end

        -- The Y slider is biased by +10 so the default actual value of
        -- -10 reads as 0 on screen. Internally cfg.anchor_offset_y still
        -- holds the real pixel offset.
        imgui.Text('Anchor offset Y')
        imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
        local v_aoy = { cfg.anchor_offset_y + 10 }
        if imgui.SliderInt('##anchoroy', v_aoy, -400, 400) then
            cfg.anchor_offset_y = v_aoy[1] - 10; changed = true
        end


        local function color_row(label, key_or_keys)
            local keys = type(key_or_keys) == 'string'
                and { key_or_keys } or key_or_keys
            local id   = label:gsub('[%s/]', '_'):lower()
            local abgr = cfg[keys[1]]
            local rgb  = {
                (abgr                       % 0x100) / 0xFF,
                (math.floor(abgr / 0x100)   % 0x100) / 0xFF,
                (math.floor(abgr / 0x10000) % 0x100) / 0xFF,
            }
            local alpha = { math.floor(abgr / 0x1000000) % 0x100 / 0xFF }
            local row_changed = false

            -- Alpha row: label + 0..1 slider on its own line.
            imgui.Text(label .. ' alpha')
            imgui.SameLine(); imgui.SetCursorPosX(col_x); imgui.SetNextItemWidth(widget_w)
            if imgui.SliderFloat('##' .. id .. '_a', alpha, 0, 1, '%.2f',
                bit.bor(ImGuiSliderFlags_AlwaysClamp,
                        ImGuiSliderFlags_NoRoundToFormat)) then
                row_changed = true
            end

            -- Color row: label + swatch button that opens a popup picker.
            imgui.Text(label .. ' color')
            imgui.SameLine(); imgui.SetCursorPosX(col_x)
            local swatch = { rgb[1], rgb[2], rgb[3], 1.0 }
            if imgui.ColorButton('##' .. id .. '_sw', swatch,
                ImGuiColorEditFlags_NoAlpha, { widget_w, 18 }) then
                imgui.OpenPopup('##' .. id .. '_pop')
            end
            if imgui.BeginPopup('##' .. id .. '_pop') then
                if imgui.ColorPicker3('##' .. id .. '_pick', rgb,
                    bit.bor(ImGuiColorEditFlags_NoLabel,
                            ImGuiColorEditFlags_NoAlpha)) then
                    row_changed = true
                end
                imgui.Separator()
                if imgui.Button('Confirm##' .. id .. '_done', { -1, 0 }) then
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end

            if row_changed then
                local new_abgr = math.floor(alpha[1] * 0xFF) * 0x1000000
                               + math.floor(rgb[3]   * 0xFF) * 0x10000
                               + math.floor(rgb[2]   * 0xFF) * 0x100
                               + math.floor(rgb[1]   * 0xFF)
                for _, k in ipairs(keys) do
                    cfg[k] = new_abgr
                end
                changed = true
            end
            imgui.Spacing()  -- gap between pairs
        end

        imgui.Spacing()
        imgui.Text('Compass Colors')
        imgui.Separator()
        color_row('All compass', { 'color_fill', 'color_ring', 'color_tick', 'color_cross' })
        if imgui.CollapsingHeader('Individual elements##compass_indiv') then
            color_row('Disc fill',  'color_fill')
            color_row('Ring',       'color_ring')
            color_row('Ticks/Hub',  'color_tick')
            color_row('Crosslines', 'color_cross')
        end
        color_row('Letters',    'color_card')
        color_row('N accent',   'color_n')
        color_row('Clock text', 'color_stamp')

        imgui.Spacing()
        imgui.Text('Entity Dot Colors')
        imgui.Separator()
        color_row('NPCs',    'color_npc')
        color_row('Players', 'color_pc')
        color_row('Mobs',    'color_mob')
        color_row('Pets',    'color_pet')

        if changed then settings.save() end
    end
    imgui.End()
    imgui.PopStyleVar(1)
end)

ashita.events.register('unload', 'compass_unload', function()
    settings.save()
    apply_ingame_compass_patch(false)   -- always restore compass byte
    apply_clock_command(false)          -- always restore in-game clock
    chat_anchor.shutdown()
end)

ashita.events.register('command', 'compass_command', function(e)
    local args = e.command:lower():args()
    if args[1] ~= '/fancycompass' and args[1] ~= '/fcompass' then return end

    local sub = args[2]

    if sub == nil then
        settings_visible[1] = not settings_visible[1]
        e.blocked = true
        return
    end

    if sub == 'toggle' then
        visible[1] = not visible[1]
        print(('[compass] %s'):format(visible[1] and 'Shown' or 'Hidden'))
        e.blocked = true

    elseif sub == 'move' and args[3] and args[4] then
        local x, y = tonumber(args[3]), tonumber(args[4])
        if x and y then
            cfg.x, cfg.y = math.floor(x), math.floor(y)
            force_pos    = true
            settings.save()
            print(('[compass] Position set to %d, %d'):format(cfg.x, cfg.y))
        end
        e.blocked = true

    elseif sub == 'size' and args[3] then
        local rv = tonumber(args[3])
        if rv and rv >= 15 and rv <= 200 then
            cfg.radius = math.floor(rv)
            settings.save()
            print(('[compass] Radius set to %d'):format(cfg.radius))
        end
        e.blocked = true

    elseif sub == 'range' and args[3] then
        local rv = tonumber(args[3])
        if rv and rv >= 5 and rv <= 500 then
            cfg.range = math.floor(rv)
            settings.save()
            print(('[compass] NPC range set to %d yalms'):format(cfg.range))
        end
        e.blocked = true

    elseif sub == 'tilt' and args[3] then
        local tv = tonumber(args[3])
        if tv and tv >= 0.1 and tv <= 1.0 then
            cfg.tilt = tv
            settings.save()
            print(('[compass] Tilt set to %.2f'):format(cfg.tilt))
        end
        e.blocked = true

    elseif sub == 'debug' then
        debug_mode = not debug_mode
        print(('[compass] Debug %s'):format(debug_mode and 'ON' or 'OFF'))
        e.blocked = true

    else
        print('[fancycompass] /fancycompass (or /fcompass) opens settings')
        print('[fancycompass] /fcompass toggle          - show/hide')
        print('[fancycompass] /fcompass move <x> <y>    - reposition')
        print('[fancycompass] /fcompass size <px>       - set radius (15-200)')
        print('[fancycompass] /fcompass range <yalms>   - set NPC radar range (5-500)')
        print('[fancycompass] /fcompass tilt <0.1-1.0>  - 3d perspective (0.5=flat-ish)')
        print('[fancycompass] /fcompass debug           - show camera/focal coords')
        e.blocked = true
    end
end)
