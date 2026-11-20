-- What the store knows: the catalog (the addons ffxiprivateservers.com lists for VanaCore), what of it is on this PC
-- (installed, at which version, loaded or not), and the pictures.
--
-- The catalog (schema 1), in the site's own field names: { schema, generatedAt, addons = { ... } }, an addon being
--   slug, name (its title), packageName (the package's own name: its folder under addons\vanacore), version, author,
--   framework, targetServer (nil: any server), summary, description, trusted (reviewed, and the file is the one
--   reviewed), reviewStatus, scanStatus, hosted (the site serves the file itself), sizeBytes, sha256, downloadUrl,
--   pageUrl, screenshots { { url, thumbUrl, width, height } or a plain url }, featured, downloads, createdAt, updatedAt
-- Until the site serves it, the store reads stub\catalog.json, in the same format, with its pictures beside it.
--
-- What may be installed is decided here, once (entry's `locked`): only an addon the site marks trusted, whose file the
-- site hosts itself, with a whole sha256 and a download address on the site. Anything else is shown and can be read
-- about, never installed.
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

local SITE = 'https://ffxiprivateservers.com/'
D.SITE = SITE

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
local function summary_of(description)
    local first = description:match('^([^\n]+)') or ''
    if #first <= 170 then return first end
    local cut = first:sub(1, 170):match('^(.*[%.!?])%s') or first:sub(1, 160):match('^(.*)%s') or first:sub(1, 160)
    return cut
end

-- one entry, checked: nil and why if it can't be shown
local function entry(raw)
    if type(raw) ~= 'table' then return nil, 'not an entry' end
    local slug = text_of(raw.slug)
    if slug == nil or not slug:match('^[%w_.%-]+$') then return nil, 'no slug' end
    if text_of(raw.framework, 'vanacore'):lower() ~= 'vanacore' then return nil, slug .. ': not for VanaCore' end
    -- (the package's own name is the folder it installs into: the same rule VanaCore holds a name to)
    local name = text_of(raw.packageName)
    if name ~= nil and (not name:match('^[%w_.%-]+$') or #name > 64 or name:find('..', 1, true)) then name = nil end
    local server = text_of(raw.targetServer)
    if server == '' then server = nil end
    local description = plain(text_of(raw.description, ''))
    local a = {
        slug = slug, name = name and name:lower() or nil, title = text_of(raw.name, slug), author = text_of(raw.author, ''),
        version = text_of(raw.version, tostring(raw.version or '')),
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
    if a.summary == '' then a.summary = summary_of(description) end
    if a.page ~= nil and a.page:sub(1, #SITE) ~= SITE then a.page = nil end
    -- why it can't be installed from here, if it can't (see the top of this file)
    if not a.trusted then a.locked = 'review'
    elseif not a.hosted then a.locked = 'hosted'
    elseif a.package.url == nil or a.package.url:sub(1, #SITE) ~= SITE or not a.package.sha256:match('^%x+$') or #a.package.sha256 ~= 64 then
        a.locked = 'package'
    end
    if type(raw.screenshots) == 'table' then
        for _, s in ipairs(raw.screenshots) do
            if type(s) == 'string' then s = { url = s } end
            if type(s) == 'table' and text_of(s.url) then
                a.shots[#a.shots + 1] = { url = s.url, thumb = text_of(s.thumbUrl, s.url), w = tonumber(s.width) or 16, h = tonumber(s.height) or 10 }
            end
        end
    end
    a.search = (a.title .. ' ' .. a.author .. ' ' .. a.summary .. ' ' .. (a.name or '')):lower()
    return a
end

local function take(doc, source)
    if type(doc) ~= 'table' or type(doc.addons) ~= 'table' then return false, 'not a catalog' end
    if tonumber(doc.schema) ~= 1 then return false, 'a newer catalog than this store reads: update VanaStore' end
    local list, by_slug, by_name = {}, {}, {}
    for _, raw in ipairs(doc.addons) do
        local a, why = entry(raw)
        if a and by_slug[a.slug] == nil and (a.name == nil or by_name[a.name] == nil) then
            list[#list + 1] = a
            by_slug[a.slug] = a
            if a.name then by_name[a.name] = a end
        elseif why then
            vana.log('vanastore catalog: left out ' .. tostring(why))
        end
    end
    D.addons, D.by_slug, D.by_name = list, by_slug, by_name
    D.stub = doc.stub == true
    D.generated = text_of(doc.generatedAt)
    D.state, D.source, D.why, D.loaded_at = 'ready', source, nil, clock()
    D.local_rev = D.local_rev + 1
    D.looked_at = -1e9
    return true
end

function D.load_stub()
    local text = read_file(vana.paths.addon .. '\\stub\\catalog.json')
    if text == nil then
        D.state, D.why = 'failed', "the store's catalog file is missing"
        return false
    end
    local doc, why = vana.json.decode(text)
    local ok, bad = take(doc, 'stub')
    if not ok then
        D.state, D.why = 'failed', tostring(bad or why)
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- This PC: what is installed, at which version, and what is loaded
-------------------------------------------------------------------------------

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
        local have = installed_version(a.name)
        a.have = have
        a.loaded = a.name ~= nil and loaded[a.name] ~= nil
        a.update = have ~= nil and have ~= '?' and not a.locked and D.compare_versions(have, a.version) < 0
        if have then installed = installed + 1 end
        if a.update then updates = updates + 1 end
    end
    D.counts = { all = #D.addons, installed = installed, updates = updates }
    D.local_rev = D.local_rev + 1
end

-- the addons a view shows: view 'all' | 'installed' | 'updates', compat nil | 'general' | 'server', and the search words
function D.filter(view, compat, query)
    local out = {}
    local words = {}
    for word in tostring(query or ''):lower():gmatch('%S+') do words[#words + 1] = word end
    for _, a in ipairs(D.addons) do
        local keep = (view == 'all') or (view == 'installed' and a.have ~= nil) or (view == 'updates' and a.update)
        if keep and compat then keep = a.compatibility == compat end
        if keep then
            for _, word in ipairs(words) do
                if not a.search:find(word, 1, true) then keep = false break end
            end
        end
        if keep then out[#out + 1] = a end
    end
    return out
end

function D.featured()
    for _, a in ipairs(D.addons) do if a.featured then return a end end
    return nil
end

-------------------------------------------------------------------------------
-- Pictures: textures made as they're first drawn, one a frame, let go when the window has been shut a while
-------------------------------------------------------------------------------

local PIC = { by = {}, frame = -1, count = 0 }
D.PIC = PIC

local function local_path(url)
    -- the stub's pictures sit in the addon's folder; the site's will be fetched into the cache (catalog step)
    if url:match('^https?://') then return nil end
    return vana.paths.addon .. '\\' .. url:gsub('/', '\\')
end

-- a picture's texture, or nil while it isn't there (yet, or ever)
function D.picture(url)
    if url == nil then return nil end
    local p = PIC.by[url]
    if p == nil then
        p = { state = 'new' }
        PIC.by[url] = p
    end
    p.used = clock()
    if p.state == 'new' then
        local frame = vana.imgui.GetFrameCount()
        if PIC.frame == frame then return nil end -- one a frame: a screenful of them never stalls the game
        PIC.frame = frame
        local path = local_path(url)
        local tex = path and U.load_image('pic:' .. url, path) or nil
        p.state = tex and 'ready' or 'none'
        p.tex = tex
        p.at = clock()
        if tex then PIC.count = PIC.count + 1 end
    end
    return p.tex, p.at
end

function D.release_pictures()
    for url, p in pairs(PIC.by) do
        if p.tex then U.release_texture('pic:' .. url) end
    end
    PIC.by, PIC.count = {}, 0
end

return D
