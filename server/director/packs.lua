-- Shipped scenarios: a resource brings its own as data, declared in its fxmanifest.lua:
--     whip_director_scenario 'scenarios/courier.json'
-- Each file is one scenario document (format 1, at most 512 KB) as the editor saves it, with two more fields:
--     "key":      its key on every server (letters, digits, _ and -); else one is made from the file
--     "requires": { "resources": [...], "items": [...], "models": [...], "format": 1 }
-- Life of one:
--   found     when the resource starts: read, never run, and checked (format, cards, requirements)
--   pending   until a Director admin accepts it in /whip (Director > Shipped); a changed file is pending again
--   accepted  a scenario like any other but read-only ("Duplicate to edit"), switched on and off by builders
--   stopped   its resource stopping switches it off; starting again brings it back on if it was on
--   deleted   tombstoned: not offered again
-- Export writes a scenario out as a pack file (pack_exports/<key>.director.json in whip_core, the one folder it may
-- write) with the fxmanifest lines to make a resource of it.
-- From code:
--   * RegisterDirectorScenario(key, doc): a scenario built in code, on the same path as a file.
--   * Trust: a Director admin may trust a resource once; its new and changed scenarios are then accepted by
--     themselves when they pass Check and have what they need.
--   * RegisterDirectorTemplate(name, doc): a starting point in the editor's New list; a gated card is refused in the copy.
--   * A pack whose cards come from its own resource is checked again when they register.

DirectorPacks = {}

local CORE = GetCurrentResourceName()
local META = 'whip_director_scenario'
local MAX_BYTES = 512 * 1024
local EXPORT_DIR = 'pack_exports/'

-- Every file found is a registration of the pack that ships it (shared/registry.lua):
-- owned by that resource, swept when it stops, listed by Registry.list like everything else a resource
-- brings. Scoped: two packs may both have a scenarios/courier.json. The owner is the resource whose
-- fxmanifest names the file (found by scanning it), never a caller.
--   entry: { resource, file, key, name, hash, doc, problems, requires } or { resource, file, broken }
local packFiles = Registry.new('directorPackFile', { label = 'shipped scenario file', scoped = true, same = false })
local rows = {}      -- [resource .. '\0' .. file] = the director_packs row
local trusted = {}   -- [resource] = the director_pack_trust row: its scenarios are accepted by themselves
local ready = false
local CODE = 'code:'   -- a scenario registered from code is the "file" code:<key> of its resource

-- Templates (RegisterDirectorTemplate): a starting point each, owned by the resource that brings it.
local templates = Registry.new('directorTemplate', { label = 'Director template', scoped = true, same = false })

local function say(fmt, ...) print(('[whip_core:director] ' .. fmt):format(...)) end
local function rowKey(res, file) return res .. '\0' .. file end

local q = DirectorKit.query

-- ============================================
-- The table
-- ============================================

function DirectorPacks.ensureTable()
    -- Who a Director admin trusts: their scenarios are accepted by themselves.
    local okTrust = CreateTable('director_pack_trust', [[
        CREATE TABLE IF NOT EXISTS `director_pack_trust` (
            `resource`      VARCHAR(64)  NOT NULL,
            `trustedBy`     INT UNSIGNED NULL,
            `trustedByName` VARCHAR(80)  NULL,
            `trustedAt`     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`resource`)
        )
    ]])
    return okTrust and CreateTable('director_packs', [[
        CREATE TABLE IF NOT EXISTS `director_packs` (
            `resource`      VARCHAR(64)  NOT NULL,
            `file`          VARCHAR(128) NOT NULL,
            `scenarioKey`   VARCHAR(64)  NOT NULL,
            `hash`          INT UNSIGNED NOT NULL,
            `status`        VARCHAR(10)  NOT NULL DEFAULT 'pending',
            `acceptedHash`  INT UNSIGNED NULL,
            `decidedBy`     INT UNSIGNED NULL,
            `decidedByName` VARCHAR(80)  NULL,
            `decidedAt`     TIMESTAMP    NULL,
            `seenAt`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`resource`, `file`)
        )
    ]])
end

function DirectorPacks.loadAll()
    local list, err = q('SELECT * FROM `director_packs`')
    if not list then return false, err end
    rows = {}
    for _, r in ipairs(list) do rows[rowKey(r.resource, r.file)] = r end
    local trust, terr = q('SELECT * FROM `director_pack_trust`')
    if not trust then return false, terr end
    trusted = {}
    for _, r in ipairs(trust) do trusted[r.resource] = r end
    return true
end

-- ============================================
-- Reading a file (data only, never run)
-- ============================================

--- A file's fingerprint: FNV-1a over its bytes. Not GetHashKey, which lowercases first, so an update
--- that only changed capitals (a line of dialog) would not be seen as a change.
local function hashOf(raw)
    local h, n = 2166136261, #raw
    for i = 1, n, 4096 do
        local bytes = { raw:byte(i, math.min(i + 4095, n)) }
        for j = 1, #bytes do h = ((h ~ bytes[j]) * 16777619) & 0xFFFFFFFF end
    end
    return h
end

--- The fingerprint rows made before that change carry (GetHashKey's): such a row is upgraded, not
--- taken for a changed file.
local function oldHashOf(raw) return GetHashKey(raw) % 4294967296 end

--- The key a shipped scenario goes by: its own `key`, or one made from the resource and file name.
local function keyFor(res, file, doc)
    if type(doc.key) == 'string' and #doc.key >= 2 and #doc.key <= 64 and doc.key:match('^[%w_%-]+$') then return doc.key end
    local base = file:gsub('^.*/', ''):gsub('%.json$', '')
    local k = (res .. '_' .. base):gsub('[^%w_%-]', '_'):sub(1, 64)
    return k
end

--- What a scenario needs that this server has not got: { resources = {...}, items = {...}, cards = {...},
--- format = n|nil }, and whether all is there. Models cannot be checked on the server (they are the
--- game's): they are listed, for the admin to see.
local function checkRequires(doc)
    local req = type(doc.requires) == 'table' and doc.requires or {}
    local missing = { resources = {}, items = {}, cards = {} }
    for _, res in ipairs(type(req.resources) == 'table' and req.resources or {}) do
        if type(res) ~= 'string' or GetResourceState(res) ~= 'started' then missing.resources[#missing.resources + 1] = tostring(res) end
    end
    local items = {}
    for _, it in ipairs(type(req.items) == 'table' and req.items or {}) do items[tostring(it)] = true end
    -- The items it names in its world and on its cards count too, listed or not (every variant's).
    local variants = DirectorGraph.variantsOf(doc)
    for _, vr in ipairs(variants) do
        for _, w in ipairs(type(vr.doc.world) == 'table' and vr.doc.world or {}) do
            if type(w) == 'table' and type(w.def) == 'table' and type(w.def.item) == 'string' and w.def.item ~= '' then items[w.def.item] = true end
        end
    end
    for it in pairs(items) do
        if not DirectorFields.isItem(it) then missing.items[#missing.items + 1] = it end
    end
    table.sort(missing.items)
    -- The cards it uses (as they are called now: another resource may have renamed one) and the ones it
    -- lists (requires.cards: the types; a provider's name is only a hint, as a folder may be renamed).
    local seenCard = {}
    local function needCard(t)
        if type(t) == 'string' and not seenCard[t] and not DirectorNodes.get(t) then
            seenCard[t] = true
            missing.cards[#missing.cards + 1] = t
        end
    end
    for _, vr in ipairs(variants) do
        local named = DirectorNodes.applyRenames(vr.doc)
        for _, n in ipairs(type(named) == 'table' and type(named.nodes) == 'table' and named.nodes or {}) do
            if type(n) == 'table' then needCard(n.type) end
        end
    end
    for _, t in ipairs(type(req.cards) == 'table' and req.cards or {}) do needCard(t) end
    table.sort(missing.cards)
    local fmt = tonumber(req.format or doc.format)
    local badFormat = fmt ~= DirectorDoc.FORMAT and fmt or nil
    local ok = #missing.resources == 0 and #missing.items == 0 and #missing.cards == 0 and not badFormat
    local models = {}
    for _, m in ipairs(type(req.models) == 'table' and req.models or {}) do models[#models + 1] = tostring(m) end
    return ok, { missing = missing, format = badFormat, models = models }
end

--- Check a scenario document a pack brings, a file's or one registered from code: the entry (with
--- its problems), or nil and why it cannot be offered. `hash` is its fingerprint.
local entryOf

--- Read and check one file. Answers the entry (with its problems), or nil and why it cannot be read.
local function readFile(res, file)
    if type(file) ~= 'string' or file == '' or file:find('%.%.') or not file:match('%.json$') then
        return nil, 'a scenario file is a .json file inside the resource'
    end
    local raw = LoadResourceFile(res, file)
    if not raw then return nil, 'the file is not there' end
    if #raw > MAX_BYTES then return nil, ('it is over %d KB'):format(MAX_BYTES // 1024) end
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= 'table' then return nil, 'it is not readable JSON' end
    return entryOf(res, file, doc, hashOf(raw), oldHashOf(raw))
end

entryOf = function(res, file, raw, hash, oldHash)
    -- Read the one way (doc.lua: its format, its lists): one bad file is refused, never stops the Director's start-up.
    local doc, why = DirectorDoc.load(raw)
    if not doc then return nil, why end
    if type(doc.name) ~= 'string' or doc.name == '' then return nil, 'it has no name' end
    local key = keyFor(res, file, doc)
    -- A file's "spot" means "place me": left unplaced, as the examples are (before the check, so an
    -- unplaced one is not taken for ready). Every variant's.
    for _, vr in ipairs(DirectorGraph.variantsOf(doc)) do
        for _, w in ipairs(type(vr.doc.world) == 'table' and vr.doc.world or {}) do
            if type(w) == 'table' and type(w.def) == 'table' and w.def.coords == 'spot' then w.def.coords = nil end
        end
    end
    doc.id, doc.rev = nil, nil
    local okReq, reqOk, req = pcall(checkRequires, doc)
    if not okReq then return nil, 'what it requires cannot be read: ' .. tostring(reqOk) end
    local okCheck, passes, problems = pcall(DirectorGraph.check, doc)
    if not okCheck then return nil, 'it cannot be checked: ' .. tostring(passes) end
    return { resource = res, file = file, key = key, name = DirectorKit.cut(doc.name, 80), hash = hash, oldHash = oldHash,
             doc = doc, requiresOk = reqOk, requires = req, passes = passes, problems = problems,
             fromCode = file:sub(1, #CODE) == CODE or nil }
end

--- A document's fingerprint as data: its keys sorted, so the same scenario built the same way every
--- boot is the same scenario (a table's order is not). FNV-1a over that text.
local function canonical(v, depth)
    depth = (depth or 0) + 1
    if depth > 32 then error('it is nested too deep', 0) end
    local t = type(v)
    if t == 'table' then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            if ta == 'string' or ta == 'number' then return a < b end
            return tostring(a) < tostring(b)
        end)
        local parts = {}
        for i, k in ipairs(keys) do parts[i] = canonical(k, depth) .. '=' .. canonical(v[k], depth) end
        return '{' .. table.concat(parts, ',') .. '}'
    elseif t == 'string' then
        return ('%q'):format(v)
    elseif t == 'number' then
        return math.type(v) == 'integer' and tostring(v) or ('%.17g'):format(v)
    elseif t == 'boolean' then
        return tostring(v)
    end
    return 'null'
end

-- ============================================
-- Finding them
-- ============================================

--- The row for a file found: made pending the first time, and pending again when it changed since it
--- was accepted or refused (a deleted one stays deleted). Waits on the database.
local function noteFound(e)
    local k = rowKey(e.resource, e.file)
    local r = rows[k]
    if not r then
        local res = q([[INSERT INTO `director_packs` (`resource`, `file`, `scenarioKey`, `hash`, `status`) VALUES (?, ?, ?, ?, 'pending')
                        ON DUPLICATE KEY UPDATE `hash` = VALUES(`hash`), `scenarioKey` = VALUES(`scenarioKey`), `seenAt` = NOW()]],
            { e.resource, e.file, e.key, e.hash })
        if res then rows[k] = { resource = e.resource, file = e.file, scenarioKey = e.key, hash = e.hash, status = 'pending' } end
        return
    end
    -- A row from before the fingerprint changed (hashOf): the same file, given its new fingerprint.
    local accepted = r.acceptedHash
    if accepted ~= nil and accepted == e.oldHash then accepted = e.hash end
    local same = r.hash == e.hash or r.hash == e.oldHash
    if not same or r.scenarioKey ~= e.key or accepted ~= r.acceptedHash then
        local status = r.status
        if (status == 'accepted' and accepted ~= e.hash) or (status == 'refused' and not same) then status = 'pending' end
        q('UPDATE `director_packs` SET `hash` = ?, `scenarioKey` = ?, `status` = ?, `acceptedHash` = ?, `seenAt` = NOW() WHERE `resource` = ? AND `file` = ?',
            { e.hash, e.key, status, accepted, e.resource, e.file })
        r.hash, r.scenarioKey, r.status, r.acceptedHash = e.hash, e.key, status, accepted
    end
end

--- One pack's files, as found by its latest scan (`mine` = { [file] = entry }): in the registry, and
--- any it no longer names out. All at the end of a scan, so the list never shows half of one.
local function holdFiles(res, mine)
    for _, key in ipairs(packFiles:keysOf(res)) do
        local e = packFiles.entries[key]
        -- (One registered from code is not its manifest's: RemoveDirectorScenario takes it away.)
        if e and mine[e.file] == nil and not e.fromCode then packFiles:remove(res, e.file) end
    end
    for file, e in pairs(mine) do
        local ok, why = packFiles:add(res, file, e)
        if not ok then say('^3%s/%s: %s^0', res, tostring(file), tostring(why)) end
    end
end

--- The entry for one of a pack's files, or nil (not found, or its pack is not running).
local function fileOf(res, file)
    if type(res) ~= 'string' or type(file) ~= 'string' then return nil end
    return packFiles:get(packFiles:keyOf(res, file))
end

--- A TRUSTED resource's scenario waiting to be accepted is accepted by itself, when it passes Check and
--- has what it needs (still read-only; switching it on stays a builder's). Waits on the database.
local function autoAccept(e)
    if not (e and trusted[e.resource]) or e.broken or not e.requiresOk or not e.passes then return end
    local r = rows[rowKey(e.resource, e.file)]
    if not r or r.status ~= 'pending' then return end
    local ok, why = DirectorPacks.accept(e.resource, e.file, nil)
    if ok then say('%s/%s accepted by itself: %s is trusted', e.resource, e.file, e.resource)
    else say('^3%s/%s: %s is trusted, but it could not be accepted: %s^0', e.resource, e.file, e.resource, tostring(why)) end
end

local function scan(res)
    local n = GetNumResourceMetadata(res, META) or 0
    if n == 0 then holdFiles(res, {}) return end
    local mine = {}
    for i = 0, n - 1 do
        local file = GetResourceMetadata(res, META, i)
        -- One file that throws is that file's problem, never the scan's (nor the Director's start-up).
        local okRead, e, why = pcall(readFile, res, file)
        if not okRead then e, why = nil, 'it could not be read: ' .. tostring(e) end
        if e then
            mine[file] = e
            noteFound(e)
        else
            mine[tostring(file)] = { resource = res, file = tostring(file), broken = why }
            say('^3%s/%s: not a scenario this can offer: %s^0', res, tostring(file), tostring(why))
        end
    end
    holdFiles(res, mine)
    for _, e in pairs(mine) do autoAccept(e) end
end

--- May a shipped scenario be switched on now? Only while its pack runs (Director.activateStored asks).
function DirectorPacks.mayActivate(key)
    local res = DirectorStore.packOf(key)
    if not res then return true end
    if GetResourceState(res) ~= 'started' then return false, ('its pack (%s) is not running'):format(res) end
    return true
end

--- Its pack started (or whip_core did): what was on before it stopped comes back on.
local function bringBack(res)
    for _, s in ipairs(DirectorStore.list()) do
        if DirectorStore.packOf(s.key) == res and s.status == 'active' and not Director.active[s.key] then
            local ok, why = Director.activateStored(s.key)
            if not ok then say('^3shipped scenario %s did not come back on: %s^0', s.key, Director.whyNotOn(why)) end
        end
    end
end

function DirectorPacks.scanAll()
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res and res ~= CORE and GetResourceState(res) == 'started' then
            local ok, err = pcall(scan, res)
            if not ok then say('^1%s: its scenarios could not be read: %s^0', res, tostring(err)) end
        end
    end
    ready = true
end

AddEventHandler('onResourceStart', function(res)
    if not ready or res == CORE then return end
    CreateThread(function()
        local ok, err = pcall(scan, res)
        if not ok then say('^1%s: its scenarios could not be read: %s^0', res, tostring(err)) return end
        bringBack(res)
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res == CORE then return end
    -- (Its files leave the list by the registry's own sweep.) Its scenarios go off (their runs end);
    -- their status stays, so they come back with it.
    local off = {}
    for key in pairs(Director.active) do
        if DirectorStore.packOf(key) == res then off[#off + 1] = key end
    end
    for _, key in ipairs(off) do Director.deactivate(key, 'its pack stopped') end
end)

-- ============================================
-- What the hub shows, and what an admin decides
-- ============================================

--- Every file found, and what is known about it: for /whip Director → Shipped.
function DirectorPacks.list()
    local out = {}
    for _, e in pairs(packFiles.entries) do
        local res, file = e.resource, e.file
        local r = rows[rowKey(res, file)] or {}
        local row = DirectorStore.get(e.key or '')
        out[#out + 1] = {
            resource = res, file = file, key = e.key, name = e.name, broken = e.broken,
            status = r.status or (e.broken and 'broken' or 'pending'),
            changed = r.status == 'pending' and r.acceptedHash ~= nil,
            decidedBy = r.decidedByName, decidedAt = r.decidedAt,
            requiresOk = e.requiresOk, requires = e.requires, passes = e.passes,
            problems = e.problems and #e.problems or 0,
            inStore = row ~= nil, mine = row ~= nil and DirectorStore.packOf(e.key) == res,
            fromCode = e.fromCode == true, trusted = trusted[res] ~= nil,
        }
    end
    table.sort(out, function(a, b) return (a.resource .. a.file) < (b.resource .. b.file) end)
    return out
end

--- Who is trusted: { [resource] = { by, at } }, for the Shipped tab.
function DirectorPacks.trustedList()
    local out = {}
    for res, r in pairs(trusted) do out[res] = { by = r.trustedByName, at = r.trustedAt } end
    return out
end

--- Trust a resource (its scenarios accepted by themselves), or stop. A Director admin's (hub.lua). Its
--- scenarios waiting now are accepted at once when they pass. Waits on the database.
---@return boolean ok
---@return string|nil why
function DirectorPacks.setTrust(res, on, by)
    if type(res) ~= 'string' or res == '' or #res > 64 then return false, 'That is not a resource' end
    if not on then
        if not q('DELETE FROM `director_pack_trust` WHERE `resource` = ?', { res }) then return false, DB_ERROR end
        trusted[res] = nil
        return true
    end
    local p = by and Players[by]
    local uid, uname = p and p.userId or nil, p and p.fullName or 'the server'
    if not q([[INSERT INTO `director_pack_trust` (`resource`, `trustedBy`, `trustedByName`) VALUES (?, ?, ?)
               ON DUPLICATE KEY UPDATE `trustedBy` = VALUES(`trustedBy`), `trustedByName` = VALUES(`trustedByName`)]],
            { res, uid, uname }) then
        return false, DB_ERROR
    end
    trusted[res] = { resource = res, trustedBy = uid, trustedByName = uname, trustedAt = os.time() }
    for _, key in ipairs(packFiles:keysOf(res)) do autoAccept(packFiles.entries[key]) end
    return true
end

--- Cards arrived (cards_api.lua): a pack that waits for its own resource's cards (they register after it
--- starts, so its first look found them missing) is checked again, and a trusted one accepted. Waits.
function DirectorPacks.recheck()
    local keys = {}
    for key, e in pairs(packFiles.entries) do
        if not e.broken and e.doc and (not e.requiresOk or not e.passes) then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local e = packFiles.entries[key]
        if e then
            local okReq, reqOk, req = pcall(checkRequires, e.doc)
            if okReq then e.requiresOk, e.requires = reqOk, req end
            local okCheck, passes, problems = pcall(DirectorGraph.check, e.doc)
            if okCheck then e.passes, e.problems = passes, problems end
            autoAccept(e)
        end
    end
end

local function setRow(res, file, status, by, acceptedHash)
    local p = by and Players[by]
    local uid, uname = p and p.userId or nil, p and p.fullName or 'the server'
    local okQ = q([[UPDATE `director_packs` SET `status` = ?, `acceptedHash` = COALESCE(?, `acceptedHash`), `decidedBy` = ?,
                    `decidedByName` = ?, `decidedAt` = NOW() WHERE `resource` = ? AND `file` = ?]],
        { status, acceptedHash, uid, uname, res, file })
    if not okQ then return false end
    local r = rows[rowKey(res, file)]
    if r then
        r.status, r.decidedByName = status, uname
        if acceptedHash then r.acceptedHash = acceptedHash end
    end
    return true
end

--- Accept a shipped scenario: it becomes (or updates) a read-only scenario in the store. Answers
--- the scenario row, or false and why. A third answer: accepted, but one that was on did not come back on at its new
--- revision (why; it is off now).
---@return table|false row
---@return string|nil why
---@return string|nil offWhy
function DirectorPacks.accept(res, file, by)
    local e = fileOf(res, file)
    if not e then return false, 'That pack is not running (start its resource first)' end
    if e.broken then return false, 'That file cannot be read: ' .. e.broken end
    if not e.requiresOk then return false, 'This server is missing what it needs (see Requires)' end
    -- Deleted here means never again (the hub hides the button; the server says so too).
    local r = rows[rowKey(res, file)]
    if r and r.status == 'deleted' then return false, 'That scenario was deleted here: it is not offered again' end
    local row = DirectorStore.get(e.key)
    if row then
        if DirectorStore.packOf(e.key) ~= res then
            return false, ('The key %s is already used by another scenario here'):format(e.key)
        end
        local rev, why = DirectorStore.save(e.key, row.draftRev, e.doc, by, ('from its pack (%s)'):format(res))
        if not rev then return false, why end
    else
        if DirectorStore.keyTaken(e.key) then
            return false, ('The key %s belongs to a deleted scenario here: it cannot be offered again'):format(e.key)
        end
        local made, why = DirectorStore.create(e.key, e.name, e.doc, by, 'pack:' .. res)
        if not made then return false, why end
    end
    if not setRow(res, file, 'accepted', by, e.hash) then return false, DB_ERROR end
    -- On already, at an older revision: the new one goes on in its place (it passed its check).
    local sc = Director.active[e.key]
    local offWhy = nil
    if sc and e.passes then
        local on, res2 = Director.activateStored(e.key, by, DirectorStore.get(e.key).draftRev)
        if not on then
            offWhy = Director.whyNotOn(res2)
            say('^3%s/%s: accepted, but it did not come back on: %s^0', res, file, offWhy)
        end
    end
    return DirectorStore.get(e.key), nil, offWhy
end

--- Refuse a shipped scenario (it is not offered again until its file changes: noteFound).
function DirectorPacks.refuse(res, file, by)
    if not (rows[rowKey(res, file)]) then return false, 'No such shipped scenario' end
    if not setRow(res, file, 'refused', by) then return false, DB_ERROR end
    return true
end

--- A shipped scenario deleted here: never offered again.
function DirectorPacks.forget(key, by)
    for _, r in pairs(rows) do
        if r.scenarioKey == key then setRow(r.resource, r.file, 'deleted', by) end
    end
end

-- ============================================
-- Export: a scenario as a pack file
-- ============================================

--- What a document needs, worked out from it: the cards it uses, the items and models it names.
function DirectorPacks.requiresOf(doc)
    local items, models = {}, {}
    local cards, providers = {}, {}
    -- (Every variant's.)
    for _, vr in ipairs(DirectorGraph.variantsOf(doc)) do
        local d = vr.doc
        for _, w in ipairs(type(d.world) == 'table' and d.world or {}) do
            local def = type(w) == 'table' and type(w.def) == 'table' and w.def or {}
            if type(def.item) == 'string' and def.item ~= '' then items[def.item] = true end
            if type(def.model) == 'string' and def.model ~= '' then models[def.model] = true end
            -- (A random vehicle's every model.)
            for _, m in ipairs(type(def.models) == 'table' and def.models or {}) do
                if type(m) == 'table' and type(m.model) == 'string' and m.model ~= '' then models[m.model] = true end
            end
            for _, it in ipairs(type(def.items) == 'table' and def.items or {}) do
                if type(it) == 'table' and type(it.item) == 'string' then items[it.item] = true end
            end
        end
        for _, n in ipairs(type(d.nodes) == 'table' and d.nodes or {}) do
            local p = type(n) == 'table' and type(n.props) == 'table' and n.props or {}
            if type(p.item) == 'string' and p.item ~= '' then items[p.item] = true end
            -- The other resources' cards it uses: their types, checked against the cards a server has;
            -- who provides each is a hint only (a folder may be renamed).
            local t = type(n) == 'table' and n.type or nil
            local owner = type(t) == 'string' and DirectorNodes.ownerOf(t) or nil
            if t and owner and owner ~= CORE then cards[t] = true providers[t] = owner end
        end
    end
    local function sorted(set) local l = {} for k in pairs(set) do l[#l + 1] = k end table.sort(l) return l end
    return { format = DirectorDoc.FORMAT, items = sorted(items), models = sorted(models), resources = {},
             cards = sorted(cards), providers = next(providers) and providers or nil }
end

--- Write a scenario out as a pack file. Answers { path, file, manifest } (the manifest lines to make a
--- resource of it), or false and why.
---@param rev number|nil  which revision (default: the one on, else the draft)
function DirectorPacks.export(key, rev)
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. tostring(key) end
    rev = rev or row.activeRev or row.draftRev
    local doc, why = DirectorStore.revision(key, rev)
    if not doc then return false, why end
    doc.key = key
    doc.requires = DirectorPacks.requiresOf(doc)
    doc.id, doc.rev = nil, nil
    local ok, text = pcall(json.encode, doc)
    if not ok or type(text) ~= 'string' then return false, 'That scenario cannot be written down' end
    if #text > MAX_BYTES then return false, ('It is over %d KB'):format(MAX_BYTES // 1024) end
    local path = ('%s%s.director.json'):format(EXPORT_DIR, key)
    if not SaveResourceFile(CORE, path, text, -1) then return false, 'The file could not be written (' .. path .. ')' end
    -- Read back the way a pack is read, so what was written is known to load.
    local back = LoadResourceFile(CORE, path)
    local okBack, parsed = pcall(json.decode, back or '')
    if not okBack or type(parsed) ~= 'table' or parsed.key ~= key or not DirectorDoc.load(parsed) then
        return false, 'The file was written but does not read back as a scenario'
    end
    local manifest = table.concat({
        "fx_version 'cerulean'",
        "game 'gta5'",
        '',
        -- Quotes, backslashes and line breaks out: they would end the string early, or start an escape.
        ("description 'Director scenario: %s'"):format((tostring(row.name or key):gsub("[%c'\\]", ' '))),
        '',
        '-- whip_core reads this file and offers it to a Director admin in /whip (Director > Shipped).',
        ("whip_director_scenario 'scenarios/%s.json'"):format(key),
        '',
    }, '\n')
    -- The manifest beside it (SaveResourceFile makes no folders, so both sit in pack_exports/).
    local manifestPath = ('%s%s.fxmanifest.lua'):format(EXPORT_DIR, key)
    local wroteManifest = SaveResourceFile(CORE, manifestPath, manifest, -1)
    return { path = CORE .. '/' .. path, manifestPath = wroteManifest and (CORE .. '/' .. manifestPath) or nil,
             file = ('scenarios/%s.json'):format(key), manifest = manifest, rev = rev }
end

-- ============================================
-- From code: scenarios and templates
-- ============================================

--- Plain data only (what another resource sends is a copy, but may carry its functions): 24 deep.
local function plainCopy(v) return DirectorKit.plain(v, { depth = 24 }) end

--- A document from another resource, as data: a copy, its size held to a file's. Answers it, or nil and why.
local function docFromCode(doc)
    if type(doc) ~= 'table' then return nil, 'a scenario is a document (a table), as the editor saves it' end
    local copy = plainCopy(doc)
    local okSize, text = pcall(json.encode, copy)
    if not okSize or type(text) ~= 'string' then return nil, 'it cannot be written down as data' end
    if #text > MAX_BYTES then return nil, ('it is over %d KB'):format(MAX_BYTES // 1024) end
    return copy
end

local function validKey(key) return type(key) == 'string' and #key >= 2 and #key <= 64 and key:match('^[%w_%-]+$') ~= nil end

--- A scenario a resource builds in code (RegisterDirectorScenario): offered as a shipped one is.
--- Answers its status ('pending', 'accepted', 'refused', 'deleted'), or false and why. WAITS.
function DirectorPacks.registerFromCode(res, key, doc)
    if not validKey(key) then return false, 'a key is 2 to 64 letters, digits, _ and -' end
    local copy, why = docFromCode(doc)
    if not copy then return false, why end
    copy.key = key
    local okHash, text = pcall(canonical, copy)
    if not okHash then return false, 'it cannot be read: ' .. tostring(text) end
    local file = CODE .. key
    local e, ewhy = entryOf(res, file, copy, hashOf(text), nil)
    if not e then return false, ewhy end
    noteFound(e)
    local ok, awhy = packFiles:add(res, file, e)
    if not ok then return false, awhy end
    autoAccept(e)
    local r = rows[rowKey(res, file)]
    return r and r.status or 'pending'
end

--- Take one of a resource's code scenarios off the Shipped list (what was accepted stays in the store,
--- as a file taken out of a manifest does). Answers true, or false and why.
function DirectorPacks.removeFromCode(res, key)
    if not validKey(key) then return false, 'a key is 2 to 64 letters, digits, _ and -' end
    return packFiles:remove(res, CODE .. key)
end

--- Templates for the editor's New list: { { id, name, resource } }, by name.
function DirectorPacks.templates()
    local out = {}
    for key, t in pairs(templates.entries) do out[#out + 1] = { id = key, name = t.name, resource = templates:ownerOf(key) } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- A template's document, a copy for a builder to make their own, or nil and why.
function DirectorPacks.template(id)
    local t = type(id) == 'string' and templates:get(id) or nil
    if not t then return nil, 'No template called ' .. tostring(id) end
    return plainCopy(t.doc)
end

--- RegisterDirectorScenario(key, doc) -> 'pending' | 'accepted' | ... | false, why. WAITS (call it from
--- Whip.register or a thread). Pending until a Director admin accepts it (or its resource is trusted).
exports('RegisterDirectorScenario', function(key, doc)
    local res = Registry.caller()
    if res == CORE then return false, 'whip_core\'s own scenarios are stored ones' end
    return DirectorPacks.registerFromCode(res, key, doc)
end)

--- RemoveDirectorScenario(key) -> true | false, why. Only your own.
exports('RemoveDirectorScenario', function(key)
    return DirectorPacks.removeFromCode(Registry.caller(), key)
end)

--- RegisterDirectorTemplate(name, doc) -> true | false, why: a starting point in the editor's New list
--- ("Bank alarm (police)"). A builder's copy is theirs.
exports('RegisterDirectorTemplate', function(name, doc)
    local res = Registry.caller()
    if type(name) ~= 'string' then return false, 'a template has a name' end
    name = DirectorKit.text(name, 60)
    if name:match('^%s*$') then return false, 'a template has a name' end
    local copy, why = docFromCode(doc)
    if not copy then return false, why end
    -- Read the one way (doc.lua): a template is a scenario document of this Director's format.
    local loaded, lwhy = DirectorDoc.load(copy)
    if not loaded then return false, 'a template is a scenario document: ' .. tostring(lwhy) end
    copy = loaded
    copy.id, copy.rev, copy.key = nil, nil, nil
    return templates:add(res, name, { name = name, doc = copy })
end)

--- RemoveDirectorTemplate(name) -> true | false, why. Only your own.
exports('RemoveDirectorTemplate', function(name)
    return templates:remove(Registry.caller(), name)
end)
