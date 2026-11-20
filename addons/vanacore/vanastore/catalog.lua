-- What the store knows: the catalog (the addons ffxiprivateservers.com lists), what of it is on this PC
-- (installed, at which version, loaded or not), and the pictures.
--
-- The catalog (schema 1), in the site's own field names: { schema, generatedAt, addons = { ... } }, an addon being
--   slug, name (its title), packageName (the package's own name: its folder under addons\vanacore), version, author,
--   framework, targetServer (nil: any server), summary, description, trusted (reviewed, and the file is the one
--   reviewed), reviewStatus, scanStatus, hosted (the site serves the file itself), sizeBytes, sha256, downloadUrl,
--   pageUrl, screenshots { { url, thumbUrl, width, height } or a plain url }, featured, downloads, createdAt, updatedAt,
--   updateInReview and pendingVersion (a newer file waiting for review), source { type 'upload' | 'github', repo, tag, commit },
--   virusScanned (the site's virus scanner passed the file it serves), luaFlags (what its scan of the Lua noticed),
--   nativeCode (it holds a DLL or the like), layout (where its files sit in the zip: the engine's business, not read here)
-- It is asked of the site (GET /api/addons: every framework) and kept, so a start with no network still has one.
--
-- What may be installed is decided here, once (entry's `locked`): an addon of a framework this VanaCore can install
-- packages of (D.INSTALLS: the one place that says which), whose file the site hosts itself, with a whole sha256 and
-- a download address on the site. Trusted or not: one the site hasn't reviewed is `unreviewed`, and the window asks
-- before it is fetched. Never native code, never a file the site's virus scan hasn't passed, never one the site's
-- review turned down, never the store itself
-- (it ships and updates with VanaCore, and isn't listed at all).
local U = require('ui')

local D = {
    addons = {}, by_slug = {}, by_name = {}, state = 'empty', source = nil, why = nil, loaded_at = 0,
    local_rev = 0, looked_at = -1e9,
}

local function clock() return vana.time.clock() end

local function read_file(path, limit)
    local f = io.open(path, 'rb')
    if f == nil then return nil end
    local text = f:read(limit or '*a')
    f:close()
    return text
end
D.read_file = read_file

-------------------------------------------------------------------------------
-- Words for figures
-------------------------------------------------------------------------------

function D.size_text(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then return string.format('%.1f MB', bytes / (1024 * 1024)) end
    return string.format('%d KB', math.max(1, math.floor((bytes + 1023) / 1024)))
end

local MONTHS = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
function D.date_text(iso)
    local y, m, d = tostring(iso or ''):match('^(%d%d%d%d)-(%d%d)-(%d%d)')
    if y == nil then return tostring(iso or '') end
    return string.format('%s %d, %s', MONTHS[tonumber(m)] or m, tonumber(d), y)
end

-- 1.10 is newer than 1.9, 1.0.1 than 1.0; anything that isn't a number sorts as text after the numbers
function D.compare_versions(a, b)
    local pa, pb = {}, {}
    for part in tostring(a or ''):gmatch('[^%.%-%+%s]+') do pa[#pa + 1] = part end
    for part in tostring(b or ''):gmatch('[^%.%-%+%s]+') do pb[#pb + 1] = part end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or '0', pb[i] or '0'
        local nx, ny = tonumber(x), tonumber(y)
        if nx and ny then
            if nx ~= ny then return nx < ny and -1 or 1 end
        elseif x ~= y then
            if nx then return -1 elseif ny then return 1 end
            return x < y and -1 or 1
        end
    end
    return 0
end

-------------------------------------------------------------------------------
-- The catalog
-------------------------------------------------------------------------------

local function text_of(v, fallback) return type(v) == 'string' and v or fallback end

-- The frameworks the site lists, as a card says them, and the rail's group each is under. VanaCore runs Ashita and
-- Windower addons too, but its packages install VanaCore addons only so far: D.INSTALLS is the switch, and an entry
-- of a framework not in it sends the player to its page on the site.
D.FRAMEWORKS = {
    vanacore = { name = 'VanaCore', family = 'vanacore' },
    ['ashita-addon'] = { name = 'Ashita', family = 'ashita' },
    ['ashita-plugin'] = { name = 'Ashita plugin', family = 'ashita', plugin = true },
    windower = { name = 'Windower', family = 'windower' },
}
D.INSTALLS = { vanacore = true }
D.SELF = 'vanastore'

-- Where the catalog comes from, and the only place a package, a picture or a page may be: the site. (A developer's own
-- copy of the site for testing is named in settings.json's "origin": https anywhere, plain http on this PC only.)
local HOME = 'https://ffxiprivateservers.com'
D.origin = HOME
function D.set_origin(url)
    url = type(url) == 'string' and url:gsub('/+$', '') or ''
    local ok = url:match('^https://[%w%.%-]+:?%d*$') or url:match('^http://127%.0%.0%.1:?%d*$') or url:match('^http://localhost:?%d*$')
    D.origin = ok and url or HOME
    return D.origin
end
local function on_site(url) return type(url) == 'string' and url:sub(1, #D.origin + 1) == D.origin .. '/' end
D.on_site = on_site

-- a description as plain lines: the marks of markdown that would show as clutter are taken off ("- " lists stay)
local function plain(text)
    text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
    text = text:gsub('%*%*(.-)%*%*', '%1'):gsub('__(.-)__', '%1'):gsub('`([^`\n]*)`', '%1')
    text = text:gsub('%[([^%]\n]+)%]%(([^%)\n]+)%)', '%1')
    local lines = {}
    for line in (text .. '\n'):gmatch('(.-)\n') do
        lines[#lines + 1] = (line:gsub('^%s*#+%s*', ''):gsub('%s+$', ''))
    end
    return (table.concat(lines, '\n'):gsub('\n\n\n+', '\n\n'):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- a card's two lines, where the site gives none: the description's first sentences
local function summary_of(description, title)
    local first = description:match('^([^\n]+)') or ''
    -- (a first line that is only a heading - the addon's name again, no full stop - is passed over for what follows)
    if title and #first < 90 and first:lower():sub(1, #title) == title:lower() and not first:match('[%.!?]$') then
        local rest = description:sub(#first + 1):match('^%s*([^\n]+)')
        if rest then first = rest end
    end
    if #first <= 170 then return first end
    local cut = first:sub(1, 170):match('^(.*[%.!?])%s') or first:sub(1, 160):match('^(.*)%s') or first:sub(1, 160)
    return cut
end

-- one entry, checked: nil and why if it can't be shown
-- What the site's scan of an addon's Lua noticed, in plain words (its `luaFlags`), for the warning before an addon
-- nobody has reviewed is installed. A flag this store hasn't a phrase for is said by its own name.
D.FLAG_WORDS = {
    ['file-access'] = 'reads and writes files', ['http-lib'] = 'makes web requests', ['socket-lib'] = 'opens network connections',
    ['os-execute'] = 'runs other programs', ['ffi'] = 'calls native code', ['memory-access'] = "reads or changes the game's memory",
    ['dynamic-code'] = 'builds code as it runs', ['clipboard'] = 'reads the clipboard',
}

-- (`scan_gate`: this catalog says of each entry whether the virus scanner passed it; one it didn't isn't installed)
local function entry(raw, scan_gate)
    if type(raw) ~= 'table' then return nil, 'not an entry' end
    local slug = text_of(raw.slug)
    if slug == nil or not slug:match('^[%w_.%-]+$') then return nil, 'no slug' end
    local framework = text_of(raw.framework, 'unknown'):lower()
    local kind = D.FRAMEWORKS[framework]
    -- (the store ships and updates with VanaCore: it never lists itself)
    if slug:lower() == D.SELF or text_of(raw.packageName, ''):lower() == D.SELF then return nil, nil end
    -- (the package's own name is the folder it installs into: the same rule VanaCore holds a name to)
    local name = text_of(raw.packageName)
    if name ~= nil and (not name:match('^[%w_.%-]+$') or #name > 64 or name:find('..', 1, true)) then name = nil end
    local server = text_of(raw.targetServer)
    if server == '' then server = nil end
    local description = plain(text_of(raw.description, ''))
    local a = {
        slug = slug, name = name and name:lower() or nil, title = text_of(raw.name, slug), author = text_of(raw.author, ''),
        version = text_of(raw.version, tostring(raw.version or '')),
        framework = framework, framework_name = kind and kind.name or '', family = kind and kind.family or 'other',
        trusted = raw.trusted == true, hosted = raw.hosted ~= false,
        review = text_of(raw.reviewStatus, ''):lower(), scan = text_of(raw.scanStatus, ''):lower(),
        compatibility = server and 'server' or 'general', server = server,
        summary = text_of(raw.summary, ''), description = description,
        updated = text_of(raw.updatedAt, text_of(raw.createdAt, '')):sub(1, 10),
        downloads = tonumber(raw.downloads), featured = raw.featured == true, page = text_of(raw.pageUrl),
        package = { url = text_of(raw.downloadUrl), size = tonumber(raw.sizeBytes) or 0, sha256 = text_of(raw.sha256, ''):lower() },
        shots = {},
    }
    a.status = a.trusted and 'trusted' or 'pending'
    -- native code (a plugin, or a package holding a DLL or the like): never installed from the store
    local layout = type(raw.layout) == 'table' and raw.layout or nil
    a.native = raw.nativeCode == true or (layout ~= nil and layout.hasNativeCode == true) or (kind ~= nil and kind.plugin == true)
    a.virus_scanned = raw.virusScanned == true
    a.flags = {}
    if type(raw.luaFlags) == 'table' then
        for _, flag in ipairs(raw.luaFlags) do
            if type(flag) == 'string' and flag:match('^[%w_%-]+$') and #flag <= 40 and #a.flags < 12 then a.flags[#a.flags + 1] = flag:lower() end
        end
    end
    -- a listing mirrored from GitHub onto the site: its repository (owner/name), release tag and short commit, for
    -- the page (the file and its checksum are the site's either way)
    local src = type(raw.source) == 'table' and raw.source or nil
    if src and text_of(src.type, ''):lower() == 'github' then
        local repo = text_of(src.repo, ''):gsub('%.git$', ''):gsub('/+$', ''):match('^https://github%.com/([%w%._%-]+/[%w%._%-]+)$')
        local commit = text_of(src.commit, ''):lower()
        local tag = text_of(src.tag)
        if tag == '' then tag = nil end
        if tag and #tag > 40 then tag = tag:sub(1, 40) end
        commit = (#commit == 40 and commit:match('^%x+$')) and commit:sub(1, 7) or nil
        if repo or tag or commit then a.github = { repo = repo, tag = tag, commit = commit } end
    end
    -- a newer file waiting for review on the site (the catalog goes on describing the approved one until it passes);
    -- it may come with no version of its own
    a.update_in_review = raw.updateInReview == true
    a.pending_version = text_of(raw.pendingVersion)
    if a.pending_version == '' then a.pending_version = nil end
    if a.summary == '' then a.summary = summary_of(description, a.title) end
    if not on_site(a.page) then a.page = nil end
    -- why it can't be installed from here, if it can't (see the top of this file)
    -- (from `trusted`, not from the review's word alone: an approval of a file since replaced comes as trusted = false)
    if not a.trusted and a.review == 'denied' then a.locked = 'denied'
    elseif a.native then a.locked = 'plugin'
    elseif scan_gate and not a.virus_scanned then a.locked = 'scan'
    elseif not D.INSTALLS[framework] then a.locked = 'framework'
    elseif not a.hosted then a.locked = 'hosted'
    elseif not on_site(a.package.url) or not a.package.sha256:match('^%x+$') or #a.package.sha256 ~= 64 then
        a.locked = 'package'
    end
    a.unreviewed = not a.trusted and a.locked == nil -- (installable, once the window's warning is answered)
    if type(raw.screenshots) == 'table' then
        for _, s in ipairs(raw.screenshots) do
            if type(s) == 'string' then s = { url = s } end
            if type(s) == 'table' and text_of(s.url) then
                a.shots[#a.shots + 1] = { url = s.url, thumb = text_of(s.thumbUrl, s.url), w = tonumber(s.width) or 16, h = tonumber(s.height) or 10,
                    stamp = a.updated }
            end
        end
    end
    a.search = (a.title .. ' ' .. a.author .. ' ' .. a.summary .. ' ' .. (a.name or '') .. ' ' .. a.framework_name):lower()
    return a
end

local function take(doc, source)
    if type(doc) ~= 'table' or type(doc.addons) ~= 'table' then return false, 'not a catalog' end
    if tonumber(doc.schema) ~= 1 then return false, 'a newer catalog than this store reads: update VanaStore' end
    local list, by_slug, by_name = {}, {}, {}
    -- (the site says of each entry whether its virus scan passed, once its catalog carries the field at all: then an
    -- entry without a pass is one the store doesn't install)
    local scan_gate = false
    for _, raw in ipairs(doc.addons) do
        if type(raw) == 'table' and type(raw.virusScanned) == 'boolean' then scan_gate = true break end
    end
    D.scan_gate = scan_gate
    for _, raw in ipairs(doc.addons) do
        local a, why = entry(raw, scan_gate)
        -- (listed as the site lists them: two entries may hold the same package name, and both are shown)
        if a and by_slug[a.slug] == nil then
            list[#list + 1] = a
            by_slug[a.slug] = a
            if a.name and by_name[a.name] == nil then by_name[a.name] = a end
        elseif why then
            vana.log('catalog: left out ' .. tostring(why))
        end
    end
    D.addons, D.by_slug, D.by_name = list, by_slug, by_name
    D.generated = text_of(doc.generatedAt)
    D.state, D.source, D.why, D.loaded_at = 'ready', source, nil, clock()
    D.local_rev = D.local_rev + 1
    D.looked_at = -1e9
    return true
end

-- The catalog as it was last fetched, kept for a start with no network (the site's own only: a test origin's isn't)
local KEPT = 'catalog.json'

-- no catalog from the site: the one in hand stays; else the kept copy; else the window says it couldn't be had
local function fall_back(why)
    D.fetch_why = tostring(why)
    vana.log('no catalog from ' .. D.origin .. ': ' .. D.fetch_why)
    if D.state == 'ready' then return end
    if D.origin == HOME then
        local ok, text = pcall(vana.settings.read, KEPT)
        local doc = ok and type(text) == 'string' and vana.json.decode(text) or nil
        if doc and take(doc, 'kept') then return end
    end
    D.state, D.why = 'failed', D.fetch_why
end

-- Asks the site for the catalog; nothing waits on it. D.fetching while it is out; D.on_catalog() when one is taken.
function D.fetch()
    if D.fetching then return end
    D.fetching, D.fetch_at, D.fetch_why = true, clock(), nil
    local function done()
        D.fetching = false
        if D.on_catalog then pcall(D.on_catalog) end
    end
    local ok, request = pcall(vana.http.json, D.origin .. '/api/addons', {
        timeout = 15, max_time = 40, max_size = 4 * 1024 * 1024, max_redirects = 2,
    })
    if not ok or type(request) ~= 'table' then
        fall_back(request)
        return done()
    end
    request:next(function (doc)
        local good, why = take(doc, 'site')
        if good then
            if D.origin == HOME then
                local text = vana.json.encode(doc, true)
                if text then pcall(vana.settings.write, KEPT, text) end
            end
        else
            fall_back(why)
        end
        done()
    end, function (err)
        local why = type(err) == 'table' and (err.status and ('the site answered ' .. tostring(err.status)) or err.message) or err
        fall_back(why)
        done()
    end)
end

-------------------------------------------------------------------------------
-- This PC: what is installed, at which version, and what is loaded
-------------------------------------------------------------------------------

-- VanaCore's own addons, and CatsEyeXI's required one: no package may replace them (the engine's own list)
D.RESERVED = { vana = true, keybinds = true, freecam = true, mcp = true, hello = true, libs = true, apiexplorer = true, plates = true,
    sendkey = true, minparty = true, loadscreen = true, customcolors = true, vanastore = true }

local function installed_version(name)
    if name == nil then return nil end -- (the catalog didn't say which folder it is: known once its package is read)
    local path = vana.paths.addons .. '\\vanacore\\' .. name .. '\\' .. name .. '.lua'
    if not vana.fs.exists(path) then return nil end
    -- (the addon's header: its version line comes after an opening comment that can run long)
    local text = read_file(path, 24 * 1024) or ''
    return text:match('addon%.version%s*=%s*[\'"]([^\'"]+)[\'"]') or '?'
end

-- looked at again every few seconds while the window is open, and at once after the store changes something
function D.look(force)
    local now = clock()
    if not force and now - D.looked_at < 3 then return end
    D.looked_at = now
    local loaded = {}
    local ok, list = pcall(vana.addons.loaded)
    if ok and type(list) == 'table' then
        for _, a in ipairs(list) do
            if a.source == nil or a.source == 'vanacore' then loaded[tostring(a.name):lower()] = a.version or true end
        end
    end
    local updates, installed = 0, 0
    for _, a in ipairs(D.addons) do
        -- (what is installed is looked for only where the store installs: addons\\vanacore)
        local have = D.INSTALLS[a.framework] and installed_version(a.name) or nil
        a.have = have
        a.loaded = a.name ~= nil and loaded[a.name] ~= nil
        -- VanaCore lets a package replace only what a package installed (the folder's .vcaddon.json): an addon the
        -- launcher keeps, or one copied in by hand, is another's to update, and the store offers its switch alone
        a.packaged = have ~= nil and vana.fs.exists(vana.paths.addons .. '\\vanacore\\' .. a.name .. '\\.vcaddon.json')
        a.foreign = have ~= nil and not a.packaged
        -- an update: a newer version, or this listing's file changed on the site since the store installed it from
        -- there (the site keeps a listing's address and swaps its file when a new one is approved; the version's words
        -- are the uploader's, so the checksum is what tells). The store's record counts only while it is of what is
        -- installed now, and only for the listing it came from.
        local rec = D.records and D.records[a.name] or nil
        local newer = have ~= nil and have ~= '?' and a.version ~= '' and D.compare_versions(have, a.version) < 0
        local changed = rec ~= nil and rec.version == have and rec.slug == a.slug and type(rec.sha256) == 'string'
            and rec.sha256 ~= a.package.sha256
        a.update = a.packaged and not a.locked and (newer or changed)
        -- (a newer version the store can't put in: the card says so, in place of an Update it would be refused)
        a.behind = a.foreign and not a.locked and newer
        -- the takeover: the store may put the site's reviewed package in place of a copy the launcher or a hand
        -- installed, where this VanaCore can do that (install.lua asks it). Never VanaCore's own addons, never an
        -- entry the store wouldn't install anyway.
        a.takeover = a.foreign and not a.locked and not D.RESERVED[a.name] and D.engine_adopts ~= nil and D.engine_adopts() == true
        if have then installed = installed + 1 end
        if a.update then updates = updates + 1 end
    end
    D.counts = { all = #D.addons, installed = installed, updates = updates }
    D.local_rev = D.local_rev + 1
end

-- the addons a view shows: view 'all' | 'installed' | 'updates', compat nil | 'general' | 'server', and the search words
-- (`family`: the rail's framework group, nil for all.) Trusted addons come first, each kind in the site's order.
function D.filter(view, compat, query, family)
    local out, later = {}, {}
    local words = {}
    for word in tostring(query or ''):lower():gmatch('%S+') do words[#words + 1] = word end
    for _, a in ipairs(D.addons) do
        local keep = (view == 'all') or (view == 'installed' and a.have ~= nil) or (view == 'updates' and a.update)
        if keep and compat then keep = a.compatibility == compat end
        if keep and family then keep = a.family == family end
        if keep then
            for _, word in ipairs(words) do
                if not a.search:find(word, 1, true) then keep = false break end
            end
        end
        if keep then
            if a.trusted then out[#out + 1] = a else later[#later + 1] = a end
        end
    end
    for _, a in ipairs(later) do out[#out + 1] = a end
    return out
end

function D.featured()
    for _, a in ipairs(D.addons) do if a.featured then return a end end
    return nil
end

-------------------------------------------------------------------------------
-- Pictures: fetched from the site into <VanaCore>\cache\vanastore once, textures made as they're first drawn (one a
-- frame), let go when the window has been shut a while
-------------------------------------------------------------------------------

local PIC = { by = {}, frame = -1, count = 0, fetching = 0 }
D.PIC = PIC

function D.cache_dir() return vana.paths.install .. '\\cache\\vanastore' end

-- a file name for a url (and the day its addon last changed, so a changed picture is fetched again)
local function cache_name(url, stamp)
    local h1, h2 = 5381, 52711
    local key = url .. '|' .. tostring(stamp or '')
    for i = 1, #key do
        local c = key:byte(i)
        h1 = (h1 * 33 + c) % 4294967296
        h2 = (h2 * 31 + c) % 4294967296
    end
    local ext = url:gsub('[?#].*$', ''):match('%.([%a]+)$')
    ext = ext and ext:lower() or 'jpg'
    if ext ~= 'png' and ext ~= 'jpg' and ext ~= 'jpeg' then ext = 'jpg' end
    return string.format('%08x%08x.%s', h1, h2, ext)
end

-- a JPG's or a PNG's width and height, read from its first bytes; nil if they aren't found
local function image_size(path)
    local data = read_file(path, 256 * 1024)
    if data == nil or #data < 24 then return nil end
    local function be16(at) local a, b = data:byte(at, at + 1) return a and b and a * 256 + b or nil end
    if data:sub(1, 8) == '\137PNG\r\n\26\n' then
        local w, h = be16(19), be16(23)
        return w, h
    end
    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        local at = 3
        while at + 9 <= #data do
            if data:byte(at) ~= 0xFF then return nil end
            local marker = data:byte(at + 1)
            if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                return be16(at + 7), be16(at + 5)
            end
            local len = be16(at + 2)
            if len == nil or len < 2 then return nil end
            at = at + 2 + len
        end
    end
    return nil
end

-- where a picture's file is, or will be; nil for one the store won't fetch
local function file_of(url, stamp)
    if not url:match('^https?://') then
        -- the preview catalog's, beside it in the addon's folder
        if url:find('..', 1, true) or url:match('^[/\\]') or url:find(':', 1, true) then return nil end
        return vana.paths.addon .. '\\' .. url:gsub('/', '\\'), true
    end
    if not on_site(url) then return nil end
    return D.cache_dir() .. '\\' .. cache_name(url, stamp), false
end

-- a picture's texture, when it was made, and its width and height; nil while it isn't there (yet, or ever)
function D.picture(url, stamp)
    if url == nil then return nil end
    local p = PIC.by[url]
    if p == nil then
        p = { state = 'new' }
        PIC.by[url] = p
    end
    if p.state == 'new' then
        local path, here = file_of(url, stamp)
        p.path = path
        if path == nil then
            p.state = 'none'
        elseif here or vana.fs.exists(path) then
            p.state = 'file'
        elseif PIC.fetching < 4 then
            p.state = 'fetching'
            PIC.fetching = PIC.fetching + 1
            vana.fs.create_dir(D.cache_dir())
            local ok, request = pcall(vana.http.download, url, path, { timeout = 20, max_time = 90, max_redirects = 2 })
            if ok and type(request) == 'table' then
                request:next(function () p.state = 'file' PIC.fetching = PIC.fetching - 1 end,
                    function () p.state = 'none' PIC.fetching = PIC.fetching - 1 end)
            else
                p.state = 'none'
                PIC.fetching = PIC.fetching - 1
            end
        end
    end
    if p.state == 'file' then
        local frame = vana.imgui.GetFrameCount()
        if PIC.frame == frame then return nil end -- one a frame: a screenful of them never stalls the game
        PIC.frame = frame
        local tex = U.load_image('pic:' .. url, p.path)
        p.state = tex and 'ready' or 'none'
        p.tex = tex
        p.at = clock()
        if tex then
            PIC.count = PIC.count + 1
            p.w, p.h = image_size(p.path)
        end
    end
    return p.tex, p.at, p.w, p.h
end

function D.release_pictures()
    for url, p in pairs(PIC.by) do
        if p.tex then U.release_texture('pic:' .. url) end
    end
    -- (one still being fetched keeps its entry: its answer comes to it)
    local keep = {}
    for url, p in pairs(PIC.by) do if p.state == 'fetching' then keep[url] = p end end
    PIC.by, PIC.count = keep, 0
end

return D
