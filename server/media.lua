-- ============================================
-- WHIP's pictures from its CDN (Config.MediaBase, media.whipfx.net)
-- ============================================
--
-- A media pack that is running serves its own pictures, as it always has (https://cfx-nui-<pack>/...). One that
-- isn't comes from the CDN: WHIPFX/txAdmin-recipe publishes the picture packs there (tools/media.py), each picture
-- once at media/<path>, asked for with ?v=<the pack's tag> so a release is a new address. Its media/index.json says
-- each pack's tag and files. It is read at start and every hour after (a pack's release reaches a running server),
-- and kept in data/media-index.json so a start without internet still knows it.
--
-- Everyone reads the result from GlobalState.whipMedia = { base = 'https://media.whipfx.net', packs = { [pack] =
-- 'local' | '<tag>' } }: WhipAssets.url (shared/assets.lua) and the pages (html/js/assets.js) build each address
-- from it. A pack with neither has no pictures (the setup report says so).

WhipMedia = {}

local RES = GetCurrentResourceName()
local CACHE = 'data/media-index.json'
local AGAIN_MS = 60 * 60 * 1000   -- the index is read again this often
local RETRY_MS = 60 * 1000        -- and this soon after a failed read
local ANSWER_MS = 30 * 1000       -- a read with no answer by then has failed

local index = nil        -- the index last read: { packs = { [pack] = { version, files = { [dir] = { names } } } } }
local raw = nil          -- and its text
local tried = false      -- the start's first read has been tried (read, failed or not needed)
local looked = false     -- the catalogs have looked for pictures: a change after that tells them to look again
local warned = false     -- a failed read is said once, until one works
local files = {}         -- [pack] = { ['img/props/x.webp'] = true }, from it
local hooks = {}

local function base()
    local b = type(Config.MediaBase) == 'string' and Config.MediaBase:gsub('/+$', '') or ''
    return b ~= '' and b or nil
end

local function running(pack)
    local s = GetResourceState(pack)
    return s == 'started' or s == 'starting'
end

local function use(idx)
    index, files = idx, {}
    for pack, e in pairs(idx.packs) do
        local set = {}
        for dir, names in pairs(type(e) == 'table' and type(e.files) == 'table' and e.files or {}) do
            for _, name in ipairs(names) do set[dir .. '/' .. name] = true end
        end
        files[pack] = set
    end
end

local function valid(idx)
    return type(idx) == 'table' and type(idx.packs) == 'table'
end

--- The tag the CDN serves `pack` at, or nil when it doesn't (or there is no CDN).
---@param pack string
---@return string|nil
function WhipMedia.version(pack)
    local e = base() and index and index.packs[pack]
    return type(e) == 'table' and e.version and tostring(e.version) or nil
end

--- Is there a picture at `path` ('img/props/x.webp') on the CDN? For a pack that isn't installed: one that is reads
--- its own folder.
---@param path string
---@return boolean
function WhipMedia.onCdn(path)
    local pack = WhipAssets.resourceFor(path)
    local set = pack and WhipMedia.version(pack) and files[pack]
    return set ~= nil and set ~= false and set[(tostring(path):gsub('^/+', ''))] == true
end

--- 'off' (no Config.MediaBase), 'read' (its list is known, from now or the last start) or 'unread'.
---@return string
function WhipMedia.status()
    if not base() then return 'off' end
    return index and 'read' or 'unread'
end

--- The catalogs call this before they look for pictures. With no copy from a last start, it waits for the start's first
--- read of the CDN's list to end (read, or failed: ANSWER_MS at most), so they look once, with the list, rather than
--- warning that there are none. Any change to the list after this tells them to look again (onChange).
function WhipMedia.firstRead()
    while not tried and not index do Wait(100) end
    looked = true
end

--- fn() when the CDN's list of pictures changes after the catalogs looked (a pack's release, or a read that worked
--- after one that failed). Called one after another on the media thread, so one may wait for its catalog's own look.
---@param fn function
function WhipMedia.onChange(fn)
    hooks[#hooks + 1] = fn
end

--- Say where each pack comes from (GlobalState.whipMedia), when that changed.
local function publish()
    local b, packs = base(), {}
    for _, pack in ipairs(WhipAssets.resources()) do
        if running(pack) then packs[pack] = 'local' else packs[pack] = WhipMedia.version(pack) end
    end
    local was = GlobalState.whipMedia
    local same = type(was) == 'table' and was.base == b and type(was.packs) == 'table'
    if same then
        for _, pack in ipairs(WhipAssets.resources()) do
            if was.packs[pack] ~= packs[pack] then same = false break end
        end
    end
    if not same then GlobalState.whipMedia = { base = b, packs = packs } end
end

-- The copy from the last start, so a start without internet still has it.
do
    local text = LoadResourceFile(RES, CACHE)
    local ok, idx = pcall(json.decode, text or '')
    if ok and valid(idx) then use(idx) raw = text end
end
publish()

--- Does any pack need the CDN (one not in the resources folder)?
local function needed()
    for _, pack in ipairs(WhipAssets.resources()) do
        if GetResourceState(pack) == 'missing' then return true end
    end
    return false
end

--- Read the index from the CDN: true once it is read (changed or not).
local function fetch()
    local b = base()
    if not b or not needed() then return true end
    local p, answered = promise.new(), false
    local function answer(status, body)
        if answered then return end   -- (an answer after the time is up is left: the next read gets it)
        answered = true
        p:resolve({ status, body })
    end
    PerformHttpRequest(b .. '/media/index.json', answer, 'GET', '', { ['User-Agent'] = 'WHIP ' .. RES })
    SetTimeout(ANSWER_MS, function() answer(0, nil) end)
    local status, body = table.unpack(Citizen.Await(p))
    local ok, idx = pcall(json.decode, body or '')
    if status ~= 200 or not ok or not valid(idx) then
        if not warned then
            warned = true
            print(('^3[whip_core:media] Could not read %s/media/index.json (HTTP %s), so the media packs that are not'
                .. ' installed have %s. Trying again every minute.^0'):format(b, tostring(status),
                index and 'the pictures of the last copy' or 'no pictures yet'))
        end
        return false
    end
    if warned then print(('[whip_core:media] Read %s/media/index.json'):format(b)) end
    warned = false
    if body == raw then return true end
    use(idx)
    raw = body
    SaveResourceFile(RES, CACHE, body, -1)
    publish()
    if looked then
        for _, fn in ipairs(hooks) do
            local ran, err = pcall(fn)
            if not ran then print(('[whip_core:media] %s'):format(tostring(err))) end
        end
    end
    return true
end

CreateThread(function()
    while true do
        local read = fetch()
        tried = true
        Wait(read and AGAIN_MS or RETRY_MS)
    end
end)

-- A pack started or stopped: its pictures come from it, or from the CDN.
AddEventHandler('onResourceStart', function(res) if WhipAssets.isAsset(res) then publish() end end)
AddEventHandler('onResourceStop', function(res) if WhipAssets.isAsset(res) then publish() end end)
