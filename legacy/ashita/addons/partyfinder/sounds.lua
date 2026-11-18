--[[
* MIT License
*
* Copyright (c) 2023-2026 CatsEyeXI [https://github.com/CatsAndBoats]
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
]]--

-- ashita.misc.play_sound wraps PlaySoundA, which has no volume parameter.
-- This module loads PCM WAVs into IDirectSoundBuffer8 objects so SetVolume
-- can attenuate per-buffer. Falls back to ashita.misc.play_sound on any
-- failure so audio feedback is never silently lost.

local ffi = require('ffi');
local bit = require('bit');

ffi.cdef[[
typedef unsigned long DWORD;
typedef long          LONG;
typedef long          HRESULT;
typedef unsigned short WORD;
typedef void*         HWND;

typedef struct {
    DWORD         Data1;
    WORD          Data2;
    WORD          Data3;
    unsigned char Data4[8];
} GUID;

typedef struct {
    WORD  wFormatTag;
    WORD  nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD  nBlockAlign;
    WORD  wBitsPerSample;
    WORD  cbSize;
} WAVEFORMATEX;

typedef struct {
    DWORD         dwSize;
    DWORD         dwFlags;
    DWORD         dwBufferBytes;
    DWORD         dwReserved;
    WAVEFORMATEX* lpwfxFormat;
    GUID          guid3DAlgorithm;
} DSBUFFERDESC;

typedef struct IDirectSoundBuffer IDirectSoundBuffer;

typedef struct {
    HRESULT       (__stdcall *QueryInterface)(void*, const GUID*, void**);
    unsigned long (__stdcall *AddRef)(void*);
    unsigned long (__stdcall *Release)(void*);
    HRESULT       (__stdcall *GetCaps)(void*, void*);
    HRESULT       (__stdcall *GetCurrentPosition)(void*, DWORD*, DWORD*);
    HRESULT       (__stdcall *GetFormat)(void*, void*, DWORD, DWORD*);
    HRESULT       (__stdcall *GetVolume)(void*, LONG*);
    HRESULT       (__stdcall *GetPan)(void*, LONG*);
    HRESULT       (__stdcall *GetFrequency)(void*, DWORD*);
    HRESULT       (__stdcall *GetStatus)(void*, DWORD*);
    HRESULT       (__stdcall *Initialize)(void*, void*, const DSBUFFERDESC*);
    HRESULT       (__stdcall *Lock)(void*, DWORD, DWORD, void**, DWORD*, void**, DWORD*, DWORD);
    HRESULT       (__stdcall *Play)(void*, DWORD, DWORD, DWORD);
    HRESULT       (__stdcall *SetCurrentPosition)(void*, DWORD);
    HRESULT       (__stdcall *SetFormat)(void*, const WAVEFORMATEX*);
    HRESULT       (__stdcall *SetVolume)(void*, LONG);
    HRESULT       (__stdcall *SetPan)(void*, LONG);
    HRESULT       (__stdcall *SetFrequency)(void*, DWORD);
    HRESULT       (__stdcall *Stop)(void*);
    HRESULT       (__stdcall *Unlock)(void*, void*, DWORD, void*, DWORD);
    HRESULT       (__stdcall *Restore)(void*);
} IDirectSoundBufferVtbl;

struct IDirectSoundBuffer {
    IDirectSoundBufferVtbl* lpVtbl;
};

typedef struct IDirectSound8 IDirectSound8;

typedef struct {
    HRESULT       (__stdcall *QueryInterface)(void*, const GUID*, void**);
    unsigned long (__stdcall *AddRef)(void*);
    unsigned long (__stdcall *Release)(void*);
    HRESULT       (__stdcall *CreateSoundBuffer)(void*, const DSBUFFERDESC*, IDirectSoundBuffer**, void*);
    HRESULT       (__stdcall *GetCaps)(void*, void*);
    HRESULT       (__stdcall *DuplicateSoundBuffer)(void*, void*, void**);
    HRESULT       (__stdcall *SetCooperativeLevel)(void*, HWND, DWORD);
    HRESULT       (__stdcall *Compact)(void*);
    HRESULT       (__stdcall *GetSpeakerConfig)(void*, DWORD*);
    HRESULT       (__stdcall *SetSpeakerConfig)(void*, DWORD);
    HRESULT       (__stdcall *Initialize)(void*, const GUID*);
} IDirectSound8Vtbl;

struct IDirectSound8 {
    IDirectSound8Vtbl* lpVtbl;
};

HRESULT __stdcall DirectSoundCreate8(const GUID*, IDirectSound8**, void*);
HWND    __stdcall GetDesktopWindow();
HWND    __stdcall GetForegroundWindow();
HWND    __stdcall FindWindowA(const char*, const char*);
]]

local DSSCL_NORMAL         = 0x1;
local DSBCAPS_STATIC       = 0x4;
local DSBCAPS_LOCSOFTWARE  = 0x8;
local DSBCAPS_CTRLVOLUME   = 0x80;
local DSBCAPS_GLOBALFOCUS  = 0x8000;
local DSBVOLUME_MIN        = -10000;
local WAVE_FORMAT_PCM      = 0x0001;

-- DirectSound (especially the Win10/11 emulated shim) rejects some flag
-- combinations with DSERR_UNSUPPORTED (E_NOTIMPL, 0x80004001). Try several
-- in decreasing order of features and use the first the system accepts.
local FLAG_TRIES = {
    { 'CTRLVOLUME|STATIC|GLOBALFOCUS|LOCSOFTWARE', DSBCAPS_CTRLVOLUME + DSBCAPS_STATIC + DSBCAPS_GLOBALFOCUS + DSBCAPS_LOCSOFTWARE },
    { 'CTRLVOLUME|STATIC|LOCSOFTWARE',             DSBCAPS_CTRLVOLUME + DSBCAPS_STATIC + DSBCAPS_LOCSOFTWARE },
    { 'CTRLVOLUME|LOCSOFTWARE',                    DSBCAPS_CTRLVOLUME + DSBCAPS_LOCSOFTWARE },
    { 'CTRLVOLUME|STATIC',                         DSBCAPS_CTRLVOLUME + DSBCAPS_STATIC },
    { 'CTRLVOLUME',                                DSBCAPS_CTRLVOLUME },
};

local dsound, user32;
do
    local ok, mod = pcall(ffi.load, 'dsound');
    if (ok) then dsound = mod; end
    ok, mod = pcall(ffi.load, 'user32');
    if (ok) then user32 = mod; end
end

local function read_u16(s, i)
    return s:byte(i) + s:byte(i + 1) * 256;
end

local function read_u32(s, i)
    return s:byte(i)
         + s:byte(i + 1) * 256
         + s:byte(i + 2) * 65536
         + s:byte(i + 3) * 16777216;
end

-- Walk RIFF/WAVE chunks. Returns fmt-fields table, data byte offset, data length.
-- On failure returns nil, errMessage.
local function parseWav(data)
    if (#data < 44) then return nil, 'file too short'; end
    if (data:sub(1, 4) ~= 'RIFF' or data:sub(9, 12) ~= 'WAVE') then
        return nil, 'not a RIFF/WAVE file';
    end

    local fmt, dataOffset, dataLen;
    local pos = 13;
    while (pos + 8 <= #data) do
        local chunkId   = data:sub(pos, pos + 3);
        local chunkSize = read_u32(data, pos + 4);
        local bodyStart = pos + 8;

        if (chunkId == 'fmt ') then
            if (chunkSize < 16) then return nil, 'fmt chunk too small'; end
            fmt = {
                wFormatTag      = read_u16(data, bodyStart),
                nChannels       = read_u16(data, bodyStart + 2),
                nSamplesPerSec  = read_u32(data, bodyStart + 4),
                nAvgBytesPerSec = read_u32(data, bodyStart + 8),
                nBlockAlign     = read_u16(data, bodyStart + 12),
                wBitsPerSample  = read_u16(data, bodyStart + 14),
            };
        elseif (chunkId == 'data') then
            dataOffset = bodyStart;
            dataLen    = chunkSize;
            break;
        end

        -- RIFF chunk bodies are padded to an even byte boundary.
        pos = bodyStart + chunkSize + (chunkSize % 2);
    end

    if (fmt == nil)                          then return nil, 'no fmt chunk'; end
    if (dataOffset == nil)                   then return nil, 'no data chunk'; end
    if (fmt.wFormatTag ~= WAVE_FORMAT_PCM)   then return nil, string.format('not PCM (format %d)', fmt.wFormatTag); end

    return fmt, dataOffset, dataLen;
end

-- Linear 0..100 to DirectSound attenuation in 100ths of a dB (DSBVOLUME_MIN..0).
local function volumeToDb(linear)
    if (linear <= 0)   then return DSBVOLUME_MIN; end
    if (linear >= 100) then return 0; end
    local db = 2000 * math.log10(linear / 100);
    if (db < DSBVOLUME_MIN) then return DSBVOLUME_MIN; end
    return math.floor(db);
end

local sounds = {
    enabled  = false,
    ds8      = nil,    -- IDirectSound8*
    buffers  = {},     -- name -> IDirectSoundBuffer*
    fallback = {},     -- name -> filesystem path, used when DS load fails

    -- Canonical sound table for partyfinder. Consumers iterate sounds.NAMES
    -- for stable display order; sounds.FILES maps name -> WAV filename.
    FILES = {
        register      = 'register.wav',
        withdraw      = 'withdraw.wav',
        join_request  = 'join_request.wav',
        join_accepted = 'join_accepted.wav',
        roulette_roll = 'roulette_roll.wav',
    },
    NAMES = { 'register', 'withdraw', 'join_request', 'join_accepted', 'roulette_roll' },
};

local function release(obj)
    if (obj ~= nil) then obj.lpVtbl.Release(obj); end
end

local function loadBuffer(path)
    local f, ferr = io.open(path, 'rb');
    if (f == nil) then return nil, 'open failed: ' .. tostring(ferr); end
    local data = f:read('*all');
    f:close();
    if (data == nil or #data == 0) then return nil, 'empty file'; end

    local fmt, dataOffset, dataLen = parseWav(data);
    if (fmt == nil) then return nil, dataOffset; end -- 2nd return is the error message

    local wfx = ffi.new('WAVEFORMATEX');
    wfx.wFormatTag      = fmt.wFormatTag;
    wfx.nChannels       = fmt.nChannels;
    wfx.nSamplesPerSec  = fmt.nSamplesPerSec;
    wfx.nAvgBytesPerSec = fmt.nAvgBytesPerSec;
    wfx.nBlockAlign     = fmt.nBlockAlign;
    wfx.wBitsPerSample  = fmt.wBitsPerSample;
    wfx.cbSize          = 0;

    local desc = ffi.new('DSBUFFERDESC');
    desc.dwSize        = ffi.sizeof('DSBUFFERDESC');
    desc.dwBufferBytes = dataLen;
    desc.dwReserved    = 0;
    desc.lpwfxFormat   = wfx;

    local bufOut = ffi.new('IDirectSoundBuffer*[1]');
    local hr, attempt;
    for _, try in ipairs(FLAG_TRIES) do
        desc.dwFlags = try[2];
        hr = sounds.ds8.lpVtbl.CreateSoundBuffer(sounds.ds8, desc, bufOut, nil);
        if (hr == 0) then attempt = try[1]; break; end
    end
    if (hr ~= 0) then return nil, string.format('CreateSoundBuffer hr=0x%08X (all flag combos)', hr); end
    local buf = bufOut[0];

    -- Copy PCM bytes into a stable FFI buffer first. Casting a Lua string
    -- straight to const char* and doing pointer arithmetic across an ffi.copy
    -- isn't documented as safe for the cdata lifetime, and empirically the
    -- buffer ends up zeroed (silent playback) on at least some LuaJIT builds.
    local pcmStr = data:sub(dataOffset, dataOffset + dataLen - 1);
    local pcmBuf = ffi.new('uint8_t[?]', dataLen);
    ffi.copy(pcmBuf, pcmStr, dataLen);

    local p1   = ffi.new('void*[1]');
    local len1 = ffi.new('DWORD[1]');
    local p2   = ffi.new('void*[1]');
    local len2 = ffi.new('DWORD[1]');
    hr = buf.lpVtbl.Lock(buf, 0, dataLen, p1, len1, p2, len2, 0);
    if (hr ~= 0) then
        release(buf);
        return nil, string.format('Lock hr=0x%08X', hr);
    end

    local n1 = tonumber(len1[0]);
    local n2 = tonumber(len2[0]);
    if (n1 > 0) then
        ffi.copy(p1[0], pcmBuf, n1);
    end
    if (n2 > 0 and p2[0] ~= nil) then
        ffi.copy(p2[0], pcmBuf + n1, n2);
    end
    buf.lpVtbl.Unlock(buf, p1[0], len1[0], p2[0], len2[0]);

    return buf;
end

-- soundsDir: absolute path containing the WAVs (no trailing separator).
-- soundFiles: { name = 'file.wav', ... }
-- Returns ok, errMessage. ok=true with errMessage means partial-success.
function sounds.init(soundsDir, soundFiles)
    -- Always record fallback paths so sounds.play degrades gracefully on later errors.
    for name, file in pairs(soundFiles) do
        sounds.fallback[name] = soundsDir .. '\\' .. file;
    end

    if (dsound == nil) then return false, 'dsound.dll not loaded'; end
    if (user32 == nil) then return false, 'user32.dll not loaded'; end

    local dsOut = ffi.new('IDirectSound8*[1]');
    local hr = dsound.DirectSoundCreate8(nil, dsOut, nil);
    if (hr ~= 0) then return false, string.format('DirectSoundCreate8 hr=0x%08X', hr); end
    local ds = dsOut[0];

    -- Modern Windows audio sessions inherit muting/visibility from the HWND
    -- they're tied to. The desktop window gets treated as background and
    -- the buffer plays inaudibly. Try the FFXI window first, then foreground,
    -- and only fall back to desktop.
    local hwnd = user32.FindWindowA('FFXiClass', nil);
    if (hwnd == nil) then hwnd = user32.GetForegroundWindow(); end
    if (hwnd == nil) then hwnd = user32.GetDesktopWindow(); end
    hr = ds.lpVtbl.SetCooperativeLevel(ds, hwnd, DSSCL_NORMAL);
    if (hr ~= 0) then
        release(ds);
        return false, string.format('SetCooperativeLevel hr=0x%08X', hr);
    end
    sounds.ds8 = ds;

    local failed = {};
    for name, file in pairs(soundFiles) do
        local path = soundsDir .. '\\' .. file;
        local buf, err = loadBuffer(path);
        if (buf == nil) then
            failed[#failed + 1] = string.format('%s (%s)', name, err);
        else
            sounds.buffers[name] = buf;
        end
    end

    sounds.enabled = true;
    if (#failed > 0) then
        return true, 'partial load failures: ' .. table.concat(failed, ', ');
    end
    return true, nil;
end

-- Play a sound at linear volume 0..100. volume<=0 mutes (no playback).
-- Returns true if played via DirectSound, false otherwise (fallback or skip).
function sounds.play(name, volume)
    volume = volume or 100;
    if (volume <= 0) then return false; end

    if (sounds.enabled) then
        local buf = sounds.buffers[name];
        if (buf ~= nil) then
            local ok = pcall(function()
                buf.lpVtbl.SetVolume(buf, volumeToDb(volume));
                buf.lpVtbl.SetCurrentPosition(buf, 0);
                buf.lpVtbl.Play(buf, 0, 0, 0);
            end);
            if (ok) then return true; end
        end
    end

    local path = sounds.fallback[name];
    if (path ~= nil) then
        ashita.misc.play_sound(path);
    end
    return false;
end

function sounds.cleanup()
    for name, buf in pairs(sounds.buffers) do
        release(buf);
        sounds.buffers[name] = nil;
    end
    if (sounds.ds8 ~= nil) then
        release(sounds.ds8);
        sounds.ds8 = nil;
    end
    sounds.enabled = false;
end

return sounds;
