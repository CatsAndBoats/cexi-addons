-- Installing and updating: the catalog's file fetched, checked against the catalog's checksum before anything reads it,
-- handed to VanaCore's own package installer (which checks every entry of it and writes only the addon's folder), and
-- loaded. Nothing here unpacks or writes an addon itself.
--
-- The steps, each a state the window draws (C.jobs[slug].state):
--   download   the file comes from the site into <VanaCore>\cache\vanastore\
--   verify     its SHA-256 is worked out, a piece a frame, and compared with the catalog's: a different file is deleted
--              unopened, and the job ends 'refused'
--   install    VanaCore reads the package (vana.addons.package_info: its name must be the one the catalog gives, and
--              VanaCore must find nothing wrong with it), the addon is unloaded if it's loaded, and VanaCore installs it
--   refused    why it wasn't installed, said in the window (job.why); the addon is as it was
-- A job that ends well is taken off the list: the addon then shows as installed, with its switch.
local SHA = require('sha256')
local ffi = require('ffi')

return function (C)
    local D, U = C.D, C.U
    local I = {}

    local function clock() return vana.time.clock() end

    -- a file's size without opening it (the download's .part file is held open by the engine while it's written)
    pcall(ffi.cdef, [[
        typedef struct { uint32_t attributes; uint32_t created[2]; uint32_t accessed[2]; uint32_t written[2];
                         uint32_t size_high; uint32_t size_low; } vanastore_FILE_ATTRIBUTE_DATA;
        int __stdcall GetFileAttributesExA(const char* name, int level, void* data);
    ]])
    local function file_size(path)
        local ok, size = pcall(function ()
            local data = ffi.new('vanastore_FILE_ATTRIBUTE_DATA')
            if ffi.C.GetFileAttributesExA(path, 0, data) == 0 then return nil end
            return data.size_high * 4294967296 + data.size_low
        end)
        return ok and size or nil
    end

    -- whether the addon `name` of a framework's folder (vanacore unless said) is loaded
    local function is_loaded(name, dir)
        dir = dir or 'vanacore'
        local ok, list = pcall(vana.addons.loaded)
        if ok and type(list) == 'table' then
            for _, a in ipairs(list) do
                if tostring(a.name):lower() == name and (a.source or 'vanacore') == dir then return true end
            end
        end
        return false
    end

    -- at every start: VanaCore's own by its name alone (as every VanaCore takes it), another framework's with it
    local function at_start(a)
        if a.framework == 'vanacore' then return pcall(vana.addons.load_at_start, a.name) end
        return pcall(vana.addons.load_at_start, a.name, a.framework)
    end
    I.is_loaded = is_loaded

    -- inside a task: waits, a frame at a time, until fn() is true or the seconds are up; what fn() says then
    local function wait_until(fn, seconds)
        local till = clock() + seconds
        while clock() < till do
            if fn() then return true end
            coroutine.yield()
        end
        return fn() and true or false
    end

    -- Whether this VanaCore can put a package in place of a folder no package installed (the takeover). The engine
    -- says so with vana.addons.can_adopt (true, or a function that answers true); one without it has no takeover, and
    -- the store goes on saying such an addon is updated elsewhere.
    function I.can_adopt()
        if I.assume_adopt ~= nil then return I.assume_adopt == true end -- (a test's: the sheet without the engine)
        local v = vana.addons.can_adopt
        if type(v) == 'function' then
            local ok, yes = pcall(v)
            return ok and yes == true
        end
        return v == true
    end
    D.engine_adopts = I.can_adopt

    local function sentence(text)
        text = tostring(text or ''):gsub('%s+$', '')
        if text == '' then return 'No reason was given.' end
        return text:match('[%.!?]$') and text or (text .. '.')
    end

    local function refuse(job, why)
        job.state, job.why, job.progress, job.part = 'refused', sentence(why), nil, nil
        vana.log(tostring(job.slug) .. ' not installed: ' .. job.why)
    end

    local function tidy(path)
        pcall(vana.fs.remove, path)
        pcall(vana.fs.remove, path .. '.from')
    end

    ---------------------------------------------------------------------------
    -- scripts\boot.txt: an addon switched off no longer loads at the start (as /vana's own switch takes it out; a
    -- command an addon runs isn't "typed", so VanaCore leaves the file alone)
    ---------------------------------------------------------------------------

    local KINDS = { vanacore = true, ashita = true, windower = true }
    function I.boot_off(name)
        local path = vana.paths.install .. '\\scripts\\boot.txt'
        local file = io.open(path, 'rb')
        if file == nil then return end
        local text = file:read('*a')
        file:close()
        local eol = text:find('\r\n', 1, true) and '\r\n' or '\n'
        local lines = {}
        for line in (text:gsub('\r\n', '\n') .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end
        if lines[#lines] == '' then lines[#lines] = nil end
        local changed = false
        for i = #lines, 1, -1 do
            local rest = lines[i]:match('^%s*//?addon%s+load%s+(.-)%s*$')
            if rest ~= nil then
                local words, found = {}, false
                for word in rest:gmatch('%S+') do
                    if word:lower() == name then found = true else words[#words + 1] = word end
                end
                if found then
                    if #words == 0 or (#words == 1 and KINDS[words[1]:lower()]) then
                        table.remove(lines, i)
                    else
                        lines[i] = '/addon load ' .. table.concat(words, ' ')
                    end
                    changed = true
                end
            end
        end
        if changed then
            local out = io.open(path, 'wb')
            if out then
                out:write(table.concat(lines, eol), eol)
                out:close()
            end
        end
    end

    -- On or off: loaded now, and at every start (or not)
    function I.switch(a, on)
        if a.name == nil then return end
        if on then
            vana.chat.run('/addon load ' .. a.name .. ' ' .. (a.dir or 'vanacore'), 1)
            at_start(a)
        else
            vana.chat.run('/addon unload ' .. a.name, 1)
            pcall(I.boot_off, a.name)
        end
        a.loaded = on
        D.looked_at = clock() - 2 -- (looked at again in a second, once the command has run)
    end

    ---------------------------------------------------------------------------
    -- The job
    ---------------------------------------------------------------------------

    local function run(a, job)
        -- (checked again here: nothing reaches the network or the installer that the catalog's rules don't allow)
        if a.locked or not D.on_site(a.package.url) or #a.package.sha256 ~= 64 then
            return refuse(job, 'The catalog gives no checked file for it')
        end
        local dir = D.cache_dir()
        vana.fs.create_dir(dir)
        -- (VanaCore's own come as packages; Ashita's and Windower's as the zip their author published, which the engine
        -- is told the framework, the folder's name and the zip's folder for)
        local plain = a.framework ~= 'vanacore' and { framework = a.framework, name = a.name, root = a.root } or nil
        if plain and (a.name == nil or not D.installs(a.framework)) then return refuse(job, "This VanaCore can't install it") end
        local path = dir .. '\\' .. a.slug .. (plain and '.zip' or '.vcaddon')
        tidy(path)

        -- 1. the download
        job.part = path .. '.part'
        local started, request = pcall(vana.http.download, a.package.url, path, { timeout = 30, max_time = 1800, max_redirects = 3 })
        if not started or type(request) ~= 'table' then return refuse(job, "The download couldn't start: " .. tostring(request)) end
        job.request = request
        local ok, res = pcall(function () return request:await() end)
        job.request, job.part = nil, nil
        if not ok then
            local why = type(res) == 'table' and (res.status and ('the site answered ' .. tostring(res.status)) or res.message) or tostring(res)
            tidy(path)
            return refuse(job, "The download didn't finish: " .. tostring(why))
        end
        if type(res) == 'table' and type(res.url) == 'string' and not D.on_site(res.url) then
            tidy(path)
            return refuse(job, 'The site sent the download to another address (' .. (res.url:match('^%a+://[^/]+') or '?') .. '), so it was not used')
        end

        -- 2. the checksum, before anything opens the file as a package
        job.state, job.progress = 'verify', 0
        local file = io.open(path, 'rb')
        if file == nil then return refuse(job, "The downloaded file can't be read") end
        local hash, bytes, size = SHA.new(), 0, a.package.size
        while true do
            local piece = file:read(262144)
            if piece == nil then break end
            hash:update(piece)
            bytes = bytes + #piece
            job.progress = (size and size > 0) and math.min(1, bytes / size) or nil
            coroutine.yield()
        end
        file:close()
        local got = hash:hex()
        if got ~= a.package.sha256 then
            tidy(path)
            vana.log(string.format('%s: the download is %d bytes, sha256 %s; the catalog says %d bytes, sha256 %s', a.slug, bytes, got,
                size or 0, a.package.sha256))
            D.fetch() -- (the addon may have been updated on the site since the catalog was read: look again)
            return refuse(job, "The download doesn't match the catalog's checksum, so it wasn't opened. Nothing was installed")
        end

        -- 3. VanaCore reads the package
        job.state, job.progress = 'install', nil
        pcall(vana.fs.write, path .. '.from', a.package.url) -- (where it came from, for VanaCore's own record of the install)
        local info, why
        if plain then info, why = vana.addons.package_info(path, plain) else info, why = vana.addons.package_info(path) end
        if info == nil then
            tidy(path)
            return refuse(job, why or "It isn't an addon package")
        end
        local name = tostring(info.name):lower()
        if a.name ~= nil and name ~= a.name then
            tidy(path)
            return refuse(job, 'The package holds an addon named ' .. name .. ', not ' .. a.name .. ' as the catalog says. Nothing was installed')
        end
        if name == C.name and not plain then
            tidy(path)
            return refuse(job, "The store can't replace itself while it's open: install its update from /vana > Addons")
        end
        -- (a copy of that name in another framework's folder, which this install wouldn't touch: never a second one
        -- without the player having been told)
        if type(info.elsewhere) == 'table' and #info.elsewhere > 0 and info.installed_version == nil and not job.elsewhere_ok then
            tidy(path)
            return refuse(job, 'A copy of it is already in addons\\' .. table.concat(info.elsewhere, ', addons\\') .. '. Nothing was installed')
        end
        -- (a takeover: the one thing in its way may be that no package installed the folder there, and VanaCore says
        -- so itself with `adoptable`; anything else it finds wrong still ends the job)
        local adopting = job.adopt == true and info.adoptable == true
        if info.problem ~= nil and not adopting then
            tidy(path)
            return refuse(job, info.problem)
        end

        -- 4. the addon out of the way, VanaCore's installer, the addon back
        local folder = a.dir or 'vanacore'
        local was_loaded = is_loaded(name, folder)
        if was_loaded then
            vana.chat.run('/addon unload ' .. name, 1)
            if not wait_until(function () return not is_loaded(name, folder) end, 6) then
                tidy(path)
                return refuse(job, name .. " didn't unload, so it wasn't replaced")
            end
        end
        local done, bad
        if plain or adopting then
            local how = {}
            if plain then how.framework, how.name, how.root = plain.framework, plain.name, plain.root end
            if adopting then how.adopt = true end -- (the old folder goes to backups\addons)
            done, bad = vana.addons.package_install(path, how)
        else
            done, bad = vana.addons.package_install(path)
        end
        if not done then
            if was_loaded then vana.chat.run('/addon load ' .. name .. ' ' .. folder, 1) end
            tidy(path)
            return refuse(job, 'VanaCore could not install it: ' .. tostring(bad))
        end
        local fresh = info.installed_version == nil -- (a takeover isn't: the addon stays loaded or not, as it was)
        a.name = a.name or name
        -- (a plain zip may carry no version of its own: the catalog's then, until D.look reads the main file's)
        local version = tostring(info.version or '')
        if version == '' or version == '?' then version = a.version end
        local now_there = D.version_of(name, folder) -- (what the installed main file says: what D.look will read)
        if now_there ~= nil and now_there ~= '?' then version = now_there end
        C.records[D.record_key(a)] = { slug = a.slug, version = version, sha256 = a.package.sha256, at = os.time(), framework = a.framework }
        C.save_records()
        if fresh or was_loaded then
            vana.chat.run('/addon load ' .. name .. ' ' .. folder, 1)
            if fresh then at_start(a) end
            wait_until(function () return is_loaded(name, folder) end, 4)
        end
        tidy(path)
        vana.log(string.format('%s %s (%s) %s from %s (sha256 %s)', adopting and 'took over' or (fresh and 'installed' or 'updated'), name, folder, tostring(info.version), a.package.url, got))
        C.jobs[a.slug] = nil
        D.look(true)
        U.toast('ok', adopting and 'Taken over' or (fresh and 'Installed' or 'Updated'), a.title .. ' ' .. tostring(info.version or ''), 4, 'circle-check')
    end

    -- Install or update the catalog's addon `a`; the window shows the job as it goes. `opts.adopt`: a takeover of a
    -- copy no package installed, which the player has just agreed to (the store's confirmation). `opts.accept_unreviewed`:
    -- the player has just agreed to an addon the site hasn't reviewed.
    function I.start(a, opts)
        local job = C.jobs[a.slug]
        if job and job.state ~= 'refused' then return end
        local adopt = opts ~= nil and opts.adopt == true
        if a.locked then return end
        -- (an addon the site hasn't reviewed goes ahead only from the window's warning, answered yes)
        if not a.trusted and not (opts ~= nil and opts.accept_unreviewed == true) then return end
        if a.foreign and not (adopt and a.takeover) then return end
        -- (a copy of that name in another framework's folder: only from the window's question about it, answered yes)
        local elsewhere_ok = opts ~= nil and opts.elsewhere_ok == true
        if a.have == nil and a.elsewhere ~= nil and #a.elsewhere > 0 and not elsewhere_ok then return end
        job = { slug = a.slug, state = 'download', progress = nil, at = clock(), adopt = adopt and a.foreign or nil, elsewhere_ok = elsewhere_ok or nil }
        C.jobs[a.slug] = job
        vana.async(function ()
            local ok, err = pcall(run, a, job)
            if not ok then refuse(job, 'Something went wrong: ' .. tostring(err)) end
        end)
    end

    -- each frame: how far a download has come, from its part file's size
    function I.tick()
        for _, job in pairs(C.jobs) do
            if job.state == 'download' and job.part then
                local a = D.by_slug[job.slug]
                local size = file_size(job.part)
                if a and a.package.size > 0 and size and size > 0 then job.progress = math.min(1, size / a.package.size) end
            end
        end
    end

    return I
end
