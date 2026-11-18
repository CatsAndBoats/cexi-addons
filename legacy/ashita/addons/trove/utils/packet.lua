--[[
* trove/utils/packet.lua — Shared packet I/O helpers
*
* Protocol constants and binary read/write helpers for the custom 0x1A4
* packet used by Trove's server module. Plugins require this module to
* send requests and parse responses.
]]--

local packet = {};

------------------------------------------------------------
-- Packet ID
------------------------------------------------------------
packet.PACKET_ID = 0x1A4;

------------------------------------------------------------
-- Client-to-Server action codes
------------------------------------------------------------
packet.C2S = {
    WITHDRAW          = 2,
    WITHDRAW_PROMPT   = 3,
    GET_SUMMARY       = 4,
    GET_CATEGORY      = 5,
    SEARCH            = 6,
    GET_CURRENCY      = 7,
    GET_POINTS        = 8,
    GET_SQUIRE        = 9,
    GET_RECIPE        = 10,
    GET_TAB_SUMMARY   = 13,
    GET_TAB_CATEGORY  = 14,
    VAULT_WITHDRAW    = 15,
    VAULT_DEPOSIT     = 16,
    GET_PLUGIN_DATA   = 17,
    GET_QUEST_STATUS  = 18,
};

------------------------------------------------------------
-- Server-to-Client action codes
------------------------------------------------------------
packet.S2C = {
    CLEAR          = 0,
    ITEM           = 1,
    END_LIST       = 2,
    ACK            = 3,
    LOCKED         = 4,
    SUMMARY        = 5,
    CURRENCY_ENTRY = 6,
    POINTS_ENTRY   = 7,
    TAB_ENTRY      = 8,
    RECIPE         = 11,
    TAB_SUMMARY    = 12,
    PLUGIN_DATA    = 17,
    QUEST_STATUS_BATCH = 18,
};

------------------------------------------------------------
-- Packet construction (C2S)
------------------------------------------------------------
function packet.make()
    local p = {};
    for i = 1, 64 do p[i] = 0; end
    return p;
end

function packet.writeU16(p, offset, value)
    p[offset + 1] = bit.band(value, 0xFF);
    p[offset + 2] = bit.band(bit.rshift(value, 8), 0xFF);
end

function packet.writeU32(p, offset, value)
    p[offset + 1] = bit.band(value, 0xFF);
    p[offset + 2] = bit.band(bit.rshift(value, 8),  0xFF);
    p[offset + 3] = bit.band(bit.rshift(value, 16), 0xFF);
    p[offset + 4] = bit.band(bit.rshift(value, 24), 0xFF);
end

function packet.writeString(p, offset, str, maxLen)
    local len = math.min(#str, maxLen);
    for i = 1, len do
        p[offset + i] = str:byte(i);
    end
end

function packet.send(action)
    local p = packet.make();
    p[5] = action;
    AshitaCore:GetPacketManager():AddOutgoingPacket(packet.PACKET_ID, p);
end

function packet.sendRaw(p)
    AshitaCore:GetPacketManager():AddOutgoingPacket(packet.PACKET_ID, p);
end

------------------------------------------------------------
-- Packet parse helpers (S2C)
------------------------------------------------------------
function packet.readU16(data, offset)
    local lo = struct.unpack('B', data, offset + 1);
    local hi = struct.unpack('B', data, offset + 2);
    return lo + bit.lshift(hi, 8);
end

function packet.readU32(data, offset)
    local b0 = struct.unpack('B', data, offset + 1);
    local b1 = struct.unpack('B', data, offset + 2);
    local b2 = struct.unpack('B', data, offset + 3);
    local b3 = struct.unpack('B', data, offset + 4);
    return b0 + bit.lshift(b1, 8) + bit.lshift(b2, 16) + bit.lshift(b3, 24);
end

function packet.readI32(data, offset)
    local v = packet.readU32(data, offset);
    if v >= 0x80000000 then v = v - 0x100000000; end
    return v;
end

function packet.readString(data, offset, maxLen)
    local bytes = {};
    for i = 1, maxLen do
        local b = struct.unpack('B', data, offset + i);
        if b == 0 then break; end
        table.insert(bytes, string.char(b));
    end
    return table.concat(bytes);
end

------------------------------------------------------------
-- Utility
------------------------------------------------------------
function packet.addCommas(n)
    if n == nil or n == 0 then return tostring(n or 0); end
    return tostring(n):reverse():gsub('(%d%d%d)', '%1,'):gsub(',(%-?)$', '%1'):reverse();
end

return packet;
