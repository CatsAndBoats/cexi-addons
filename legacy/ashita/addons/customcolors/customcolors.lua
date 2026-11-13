addon.name      = "CustomColors"
addon.author    = "Loxley"
addon.version   = "1.1"
addon.desc      = "Applies colors to chat messages for custom content"
addon.link      = "https://catseyexi.com/cw"

require('common')
local chat     = require('chat')
local messages = require('messages')

local function multicolor(msg, colors, start, parts)
    local out  = msg:sub(1, start - 1)
    local curr = start

    for i, part in pairs(parts) do
        if part ~= nil then
            local remain = msg:sub(curr, -1)
            local f1, f2 = remain:find(part, 1, true)

            out  = out .. remain:sub(1, f1 - 1) .. chat.color1(colors[i], part)
            curr = curr + f2
        end
    end

    return out .. msg:sub(curr, -1)
end

ashita.events.register('text_in', 'text_in_cb', function (e)
    local id = bit.band(e.mode_modified, 0x000000FF)

    -- NS_SAY (9) and SYSTEM_3 (29/121) from server
    if id ~= 9 and id ~= 29 and id ~= 121 then
        return
    end

    local msg = AshitaCore:GetChatManager():ParseAutoTranslate(e.message_modified, true)
    msg = msg:gsub("-", "_")

    for _, txt in pairs(messages) do
        if type(txt[2]) == "number" then
            local f1, f2 = msg:find(txt[1])

            if f1 ~= nil then
                msg = msg:sub(1, f1 - 1) .. chat.color1(txt[2], msg:sub(f1, -1))
                e.message_modified = msg:gsub("_", "-")

                return
            end
        else
            local start, _, a1, a2, a3, a4, a5, a6, a7, a8 = msg:find(txt[1])

            if start ~= nil then
                msg = multicolor(msg, txt[2], start, { a1, a2, a3, a4, a5, a6, a7, a8 })
                e.message_modified = msg:gsub("_", "-")

                return
            end
        end
    end
end)
