-- ============================================
-- PROP CATALOG — Server Module
-- ============================================
--
-- WHAT THE FURNISHER LETS YOU PLACE, and the picture beside each entry: a table keyed by model, a
-- `hasImage` flag, a `status` that remembers which models are not placeable, and the images
-- themselves on disk rather than in the database, because NUI can load a URL and cannot load a
-- BLOB out of MariaDB.
--
-- EVERY PROP IN THE GAME, FILED. About 16,500 rows: 1,361 hand-picked (server/prop_catalog_seed.lua),
-- the rest of the game's props filed by category (server/prop_catalog_seed_world.lua), and a server's
-- own (Config.PropSeeds). `/prop add <category>` while looking at a prop files one in game, `/prop
-- remove` takes one out, and /propcheck hides the ones that will not spawn.
--
-- SEEDED ONCE, NEVER RE-ASSERTED. The seed inserts only models the table has never had, so a prop
-- an admin removed, or moved to another category, stays as the admin left it — the same rule
-- Garages.seedFromConfig follows, and for the same reason: a seed that fights the operator is a
-- seed that gets deleted from the config instead. The one thing it does fill in on a row that
-- exists is a missing display name.
--
-- Removed is a row, not an absence: `/prop remove` marks the model unavailable rather than deleting
-- it. A deleted row is a model the table has never had, and the seed would put it straight back at
-- the next restart.
--
-- MODELS THE GAME DOES NOT HAVE are hidden by every client (client/property_furnish.lua checks each
-- name against its own archives) and marked unavailable here when an admin's client reports them
-- (propCatalogMissing), and listed by name in whip_core/missing_props.txt (the console says how many). A wrong
-- name costs nothing but a line there.

PropCatalog = {}

--- [model] = row. PRIVATE — the live authority, not a copy. Readers go through getAll/wire.
PropCatalog._rows = {}

--- The whole catalog as it goes on the wire (PropCatalog.wire), built once and kept until a row or the rail changes:
--- every login sends it, some 16,500 rows to build and sort. Whatever changes a row sets it back to nil.
local wireCache = nil

-- THE PICTURES LIVE IN A MEDIA PACK, not in whip_core: players download a resource again
-- in full whenever anything in it changes, and these hardly ever do (its fxmanifest.lua). Which one
-- holds a model's is WhipAssets.resourceFor (shared/assets.lua); html/js/assets.js loads them from the
-- same place. They are rendered outside the game and come with the packs; whip only reads them.
local IMG_DIR = 'img/props/'
local IMG_EXT = '.webp'

--- A TINYINT arrives from oxmysql as a number or a boolean depending on driver settings, so both
--- are accepted. Getting this wrong would not error — it would quietly report every prop as
--- imageless, or none of them.
---@param row table|nil
---@return boolean
local function hasImage(row)
    if row and row.addonImage then return true end   -- an add-on pack's own picture (RegisterProps)
    local v = row and row.hasImage
    return v == 1 or v == true
end

local categorySet = nil   -- [key] = true, from Config.PropCategories (worked out again when it changes)

--- Is this a category anybody declared? An unknown one would produce a shelf in the furnisher that
--- no tab leads to, which is worse than a refusal.
---@param key string
---@return boolean
local function isCategory(key)
    if not categorySet then
        categorySet = {}
        for _, c in ipairs(Config.PropCategories or {}) do
            if type(c) == 'table' and c.key then categorySet[c.key] = true end
        end
    end
    return categorySet[key] == true
end

-- ============================================
-- Database
-- ============================================

function PropCatalog.ensureTable()
    local ok, err = pcall(MySQL.query.await, WithTableCollation [[
        CREATE TABLE IF NOT EXISTS `prop_catalog` (
            `model`       VARCHAR(80)  NOT NULL,
            `displayName` VARCHAR(64)  DEFAULT NULL,
            `category`    VARCHAR(32)  NOT NULL DEFAULT 'misc',
            `hasImage`    TINYINT      NOT NULL DEFAULT 0,
            `status`      ENUM('pending','ok','unavailable') NOT NULL DEFAULT 'pending',
            `addedBy`     VARCHAR(64)  DEFAULT NULL,
            `createdAt`   TIMESTAMP    NOT NULL DEFAULT current_timestamp(),
            PRIMARY KEY (`model`),
            KEY `idx_category` (`category`),
            KEY `idx_status` (`status`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {})

    if not ok then
        print(('[whip_core:props] ERROR creating prop_catalog table: %s'):format(tostring(err)))
    end
    return ok
end

function PropCatalog.loadAll()
    PropCatalog.ensureTable()

    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `prop_catalog`', {})
    if not ok then
        print(('[whip_core:props] ERROR loading catalog: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    PropCatalog._rows = {}
    wireCache = nil
    local n, withImage = 0, 0
    for _, row in ipairs(rows or {}) do
        PropCatalog._rows[row.model] = row
        n = n + 1
        if hasImage(row) then withImage = withImage + 1 end
    end

    print(('[whip_core:props] catalog loaded: %d prop(s), %d with images'):format(n, withImage))
end

--- Every seed, as { model = { category, name } }: the built-in list, then Config.PropSeeds (a
--- server's own additions) over it. Where both name a model the config wins, but like any seed only
--- for a model the table has not had yet.
local function seeds()
    local out = {}
    for _, e in ipairs(PropCatalogSeed or {}) do
        out[tostring(e[1]):lower()] = { category = e[2], name = e[3] }
    end
    for model, v in pairs(Config.PropSeeds or {}) do
        local category, name = v, nil
        if type(v) == 'table' then category, name = v.category or v[1], v.name or v[2] end
        out[tostring(model):lower()] = { category = category, name = name }
    end
    return out
end

--- Put the seed into the table: models it has never had, and a name for rows that have none.
---
--- NEVER RE-ASSERTED. A seed row that exists keeps its category and status whatever the seed says
--- now — an admin's removal or re-categorisation stands. Only an empty display name is filled.
---
--- A FEW STATEMENTS, NOT ONE PER PROP: the seed is every prop in the game (about 16,500) on a first
--- boot, and that many sequential awaits would hold the boot open. They go SEED_CHUNK rows to a
--- statement, so no one statement nears a placeholder or packet limit. After the first boot nothing
--- is missing and this issues no query at all.
---
--- Runs after loadAll so the in-memory set can be topped up without a second SELECT.
local SEED_CHUNK = 1000

function PropCatalog.seedFromConfig()
    local todo = {}
    for model, s in pairs(seeds()) do
        local row = PropCatalog._rows[model]
        local name = type(s.name) == 'string' and s.name ~= '' and s.name:sub(1, 64) or nil
        if model ~= '' and (not row or (name and not row.displayName)) then
            todo[#todo + 1] = { model = model, row = row, name = name,
                                category = isCategory(s.category) and s.category or 'misc' }
        end
    end
    if #todo == 0 then return end
    wireCache = nil   -- (rows added and named below)

    local added, named, failed = 0, 0, 0
    for first = 1, #todo, SEED_CHUNK do
        local pending, values, undo = {}, {}, {}
        local a, n = 0, 0
        for i = first, math.min(first + SEED_CHUNK - 1, #todo) do
            local t = todo[i]
            -- NO NAME GOES AS '' AND NULLIF MAKES IT NULL. A nil appended to `values` is no
            -- append at all, and every row after it would shift one column along.
            pending[#pending + 1] = '(?,?,?,NULLIF(?,\'\'))'
            values[#values + 1] = t.model
            values[#values + 1] = t.category
            values[#values + 1] = 'pending'
            values[#values + 1] = t.name or ''
            -- Into memory here rather than after the query, so the two cannot disagree about which
            -- rows were attempted; a failed statement is undone below.
            if t.row then
                n = n + 1
                t.row.displayName = t.name
                undo[#undo + 1] = function() t.row.displayName = nil end
            else
                a = a + 1
                PropCatalog._rows[t.model] = { model = t.model, category = t.category, hasImage = 0,
                                               status = 'pending', displayName = t.name }
                undo[#undo + 1] = function() PropCatalog._rows[t.model] = nil end
            end
        end

        local ok, err = pcall(MySQL.query.await,
            'INSERT INTO `prop_catalog` (`model`,`category`,`status`,`displayName`) VALUES '
            .. table.concat(pending, ',')
            .. ' ON DUPLICATE KEY UPDATE `displayName` = COALESCE(`displayName`, VALUES(`displayName`))', values)

        if ok then
            added, named = added + a, named + n
        else
            print(('[whip_core:props] ERROR seeding catalog (rows %d-%d): %s'):format(first, first + #pending - 1, tostring(err)))
            -- The statement did not land, so what this chunk wrote into memory is not real. Left there,
            -- the furnisher would offer props the database has never heard of, and
            -- PropertyObjects.replace would accept them. The next boot tries them again.
            for _, fn in ipairs(undo) do fn() end
            failed = failed + #pending
        end
    end
    if failed > 0 then
        print(('[whip_core:props] %d seed row(s) did not land: they are tried again next boot'):format(failed))
    end
    if added == 0 and named == 0 then return end

    print(('[whip_core:props] seeded %d new prop(s), named %d'):format(added, named))
end

local syncing = false   -- syncImages is running (it waits between batches)

--- Make every row's picture flag match the disk: img/props/<model>.webp in its media pack there and
--- not empty means it has a picture.
---
--- THE DISK IS THE ANSWER. The pictures arrive as files in the packs, so the flag follows the folder: a
--- picture copied in turns it on, a deleted one turns it off (rather than leave a tile whose image 404s).
---
--- An EMPTY file is no picture.
---
--- Opened, never read — one open and seek per catalog row, so a thousand icons cost a thousand
--- opens at boot rather than a thousand files loaded into memory. Runs after loadAll and the seed.
---
--- WITHOUT THE PROPS' MEDIA PACK, WHIP'S CDN SAYS (server/media.lua): its list of pictures, read at start.
--- NO PACK AND NO CDN, NO SYNC. Every picture would read as missing, and the flags of all of them would be
--- switched off, to come back one by one only after the folder is restored and whip_core restarted. So a server
--- with neither keeps the flags as they are and says why.
--- The folders are read whether or not their resources have started yet (start order does not matter); one
--- missing or never started is the setup report's to say (server/setup_report.lua).
local function syncNow()
    WhipMedia.firstRead()
    local roots = {}
    for _, res in ipairs(WhipAssets.resources()) do
        local root = GetResourceState(res) ~= 'missing' and GetResourcePath(res) or nil
        if root and root ~= '' then roots[res] = root end
    end
    for _, c in ipairs(WhipAssets.chunks) do
        if c.dir .. '/' == IMG_DIR and not roots[c.resource] and not WhipMedia.version(c.resource) then
            print(('[whip_core:props] WARNING: no %s, nor the CDN (Config.MediaBase), so the furniture catalog has'
                .. ' no pictures. Picture flags were left as they were.'):format(c.resource))
            return
        end
    end

    -- A pause every OPENS_A_TICK opens: some 15,000 at once held the server's main thread for over a minute when the
    -- disk was slow (31 Oct: txAdmin took it for hung and restarted the server). The models are listed first, so the
    -- walk is not upset by a change to the catalog during a pause.
    local OPENS_A_TICK = 500
    local models = {}
    for model in pairs(PropCatalog._rows) do models[#models + 1] = model end
    local gained, lost = {}, {}
    for i, model in ipairs(models) do
        if i % OPENS_A_TICK == 0 then Wait(0) end
        local row = PropCatalog._rows[model]
        local path = IMG_DIR .. model .. IMG_EXT
        local root = roots[WhipAssets.resourceFor(path) or '']
        local f = row and root and io.open(root .. '/' .. path, 'rb')
        local onDisk = false
        if f then
            onDisk = (f:seek('end') or 0) > 0
            f:close()
        end
        -- Not in its pack (none installed, or one older than whip_core): the CDN's, if it has it
        if row and not onDisk then onDisk = WhipMedia.onCdn(path) end
        if row and onDisk ~= hasImage(row) then
            if onDisk then gained[#gained + 1] = model else lost[#lost + 1] = model end
        end
    end

    -- SEED_CHUNK models to a statement: an icon pack for the whole game is some 16,000 at once.
    for _, set in ipairs({ { list = gained, value = 1 }, { list = lost, value = 0 } }) do
        for first = 1, #set.list, SEED_CHUNK do
            local chunk, marks = {}, {}
            for i = first, math.min(first + SEED_CHUNK - 1, #set.list) do
                chunk[#chunk + 1] = set.list[i]
                marks[#marks + 1] = '?'
            end
            local ok, err = pcall(MySQL.query.await,
                ('UPDATE `prop_catalog` SET `hasImage` = %d WHERE `model` IN (%s)')
                    :format(set.value, table.concat(marks, ',')), chunk)
            if ok then
                for _, model in ipairs(chunk) do PropCatalog._rows[model].hasImage = set.value end
                wireCache = nil
            else
                print(('[whip_core:props] ERROR updating picture flags: %s'):format(tostring(err)))
            end
        end
    end

    if #gained > 0 or #lost > 0 then
        print(('[whip_core:props] pictures: %d found, %d missing'):format(#gained, #lost))
    end
end

function PropCatalog.syncImages()
    syncing = true
    local ok, err = pcall(syncNow)
    syncing = false
    if not ok then print(('[whip_core:props] ERROR syncing picture flags: %s'):format(tostring(err))) end
end

-- The CDN's list of pictures changed (a picture pack's release): look again, once a look under way has ended.
WhipMedia.onChange(function()
    while syncing do Wait(100) end
    PropCatalog.syncImages()
end)

-- ============================================
-- Telling the clients
-- ============================================
--
-- THE WHOLE CATALOG ONCE, THEN ONLY WHAT CHANGED. A player gets every row at login (sync); after
-- that a change reaches every player — a furnisher open anywhere should show a new prop or picture
-- straight away — as just the rows that moved. The catalog is some 16,500 rows, and /propcheck bins
-- props by the hundred: resending all of it per change would be the whole catalog to every player
-- hundreds of times over.
--
-- ONE PUSH FOR A BURST. Changes inside two seconds of each other go out together.

local dirty = {}          -- [model] = true, changed since the last push
local pushQueued = false

--- Counts the pushes. The full catalog says which push it already includes, and each push says its
--- own number, so a client can put them in order: the full catalog is a LATENT event (below) and
--- can arrive after a push that was sent later.
PropCatalog._version = 0

--- How fast the full catalog streams to a player: about 1.5 MB, so some 3 s at this rate (it was 6 s at 250 KB/s).
--- LATENT, off the reliable channel; it goes at login, so a furnisher or world builder opened in the first seconds
--- after can have none yet.
local CATALOG_BPS = 500000

--- What one row looks like on the wire.
local function wireRow(model, row)
    return {
        model    = model,
        name     = row.displayName,
        -- A category no longer in the list (taken out in /whip → Settings) files its props in misc,
        -- where they can still be found, rather than in a tab that does not exist.
        category = (row.category and isCategory(row.category)) and row.category or 'misc',
        hasImage = hasImage(row),
        -- An add-on pack's picture (RegisterProps), loaded from its own resource; otherwise the media packs' by model.
        image    = row.addonImage,
        -- A stash (Config.PropertyStashProps): { label, slots, weight }. It stays in its category and
        -- shows under the furnisher's Containers as well (server/property_stashes.lua).
        stash    = PropertyStashes.spec(model),
    }
end

--- Tell every client this row changed, soon. A row now 'unavailable' goes out as removed.
---@param model string  already lowercased
function PropCatalog.changed(model)
    wireCache = nil
    dirty[model] = true
    if pushQueued then return end
    pushQueued = true
    SetTimeout(2000, function()
        pushQueued = false
        local props, removed = {}, {}
        for m in pairs(dirty) do
            local row = PropCatalog._rows[m]
            if row and row.status ~= 'unavailable' then props[#props + 1] = wireRow(m, row)
            else removed[#removed + 1] = m end
        end
        dirty = {}
        PropCatalog._version = PropCatalog._version + 1
        TriggerClientEvent('whip_core:client:propCatalogChanged', -1,
            { props = props, removed = removed, version = PropCatalog._version })
    end)
end

--- Merge fields into a row and persist it. Creates the row if it is new. Memory changes only once the database has
--- it: a failed write leaves the row as it was (false), not changed till a restart.
---@param model string  already lowercased
---@param fields table
---@return boolean
local function upsert(model, fields)
    local was = PropCatalog._rows[model]
    local row = {}
    for k, v in pairs(was or { model = model, category = 'misc', hasImage = 0, status = 'pending' }) do row[k] = v end
    for k, v in pairs(fields) do row[k] = v end

    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO `prop_catalog` (`model`,`displayName`,`category`,`hasImage`,`status`,`addedBy`)
        VALUES (?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            `displayName` = COALESCE(VALUES(`displayName`), `displayName`),
            `category`    = VALUES(`category`),
            `hasImage`    = VALUES(`hasImage`),
            `status`      = VALUES(`status`),
            `addedBy`     = COALESCE(VALUES(`addedBy`), `addedBy`)
    ]], {
        row.model, row.displayName, row.category or 'misc',
        row.hasImage or 0, row.status or 'pending', row.addedBy,
    })

    if not ok then
        print(('[whip_core:props] ERROR saving catalog row %s: %s'):format(model, tostring(err)))
        return false
    end
    -- (The same table, changed in place, for anyone holding it: only now)
    if was then
        for k in pairs(was) do if row[k] == nil then was[k] = nil end end
        for k, v in pairs(row) do was[k] = v end
    else
        PropCatalog._rows[model] = row
    end
    wireCache = nil
    return true
end

-- ============================================
-- Reads
-- ============================================

---@param model string
---@return table|nil
function PropCatalog.get(model)
    if type(model) ~= 'string' then return nil end
    return PropCatalog._rows[model:lower()]
end

--- Every row. Internal callers only.
function PropCatalog.getAll()
    return PropCatalog._rows
end

--- What crosses to a client: the placeable props, grouped nowhere and flagged for their image.
---
--- 'unavailable' ROWS ARE WITHHELD. A model that would not stream is not something the furnisher
--- can place — offering it would produce a tile that does nothing when clicked, and the player has
--- no way to know the difference between that and their own mistake.
---
--- The CATEGORIES AND CLUSTERS travel with it rather than being read from Config on the client, so
--- a category added to the config reaches the furnisher without the client needing its own copy of
--- the list — and the rail's top row rebuilds itself from the same push.
function PropCatalog.wire()
    -- Built again only after a change (wireCache); its version is read fresh, as a push may have gone since
    if not wireCache then
        local props = {}
        for model, row in pairs(PropCatalog._rows) do
            if row.status ~= 'unavailable' then props[#props + 1] = wireRow(model, row) end
        end
        table.sort(props, function(a, b) return a.model < b.model end)
        wireCache = props
    end

    return {
        clusters   = Config.PropClusters or {},
        categories = Config.PropCategories or {},
        props      = wireCache,
        version    = PropCatalog._version,   -- every push up to this one is already in it
    }
end

--- Push the whole catalog at a player, or at everyone when `target` is -1. Changes after that go
--- out through PropCatalog.changed.
function PropCatalog.sync(target)
    TriggerLatentClientEvent('whip_core:client:propCatalogSync', target or -1, CATALOG_BPS, PropCatalog.wire())
end

-- The furnisher's clusters or categories changed in /whip → Settings: the whole catalog goes to
-- everyone again (they travel with it), and an open furnisher rebuilds its rail from it. ONCE when
-- one Apply changes both: queued for the next tick, as PropCatalog.changed queues its pushes.
local railQueued = false
local function railChanged()
    categorySet, wireCache = nil, nil   -- (rows file under the categories, and carry their stash)
    if railQueued then return end
    railQueued = true
    SetTimeout(0, function()
        railQueued = false
        PropCatalog.sync(-1)
    end)
end
Settings.onChange('PropClusters', railChanged)
Settings.onChange('PropCategories', railChanged)
-- Which props are stashes travels on each row too.
Settings.onChange('PropertyStashProps', railChanged)

-- ============================================
-- Editor events
-- ============================================

--- Add the prop an admin is looking at.
---
--- THE MODEL COMES FROM THE CLIENT AND THAT IS UNAVOIDABLE — only the client can raycast from a
--- camera and read GetEntityArchetypeName off what it hit. So it is validated as a `key` (letters,
--- digits, underscores) and a purely numeric name is refused: that is the degradation case where a
--- real name could not be resolved and a hash got stringified, and a catalog row called
--- `-1651067813` would be a tile nobody could ever fix.
---
--- Nothing worse than a junk row can come of a lie here. The model still has to stream and still
--- has to be a real archetype before it renders, and the ACE gate means only a dev can try.
SecureEvent('whip_core:server:propAdd', {
    ace       = 'whip.devtools',
    rateLimit = 250,
    params = {
        {'model',    'key',    80},
        {'category', 'string', 32, 'misc'},
        {'name',     'string', 64, ''},
    },
}, function(source, _, model, category, name)
    model = model:lower()
    if model == '' or tonumber(model) or model:match('^%-?%d+$') then
        return false, 'That is not a usable model name'
    end
    if not isCategory(category) then category = 'misc' end

    local existing = PropCatalog._rows[model]
    if not upsert(model, {
        category    = category,
        displayName = name ~= '' and name or nil,
        addedBy     = GetPlayerName(source),
        -- A prop being re-added after it was marked unavailable is an admin saying "yes it does
        -- exist" — so the status goes back to pending, and the furnisher offers it again.
        status      = 'pending',
    }) then
        return false, DB_ERROR
    end

    PropCatalog.changed(model)
    ShowSuccess(source, ('%s %s to %s')
        :format(model, existing and 'moved' or 'added', category))
end)

--- Take a prop out of the furnisher.
---
--- Marked unavailable, not deleted: a deleted row is a model the table has never had, and the seed
--- would put it back at the next restart. `/prop add` brings it back. Furniture already placed with
--- it stays where it is (server/property_objects.lua lets a room keep what it has).
SecureEvent('whip_core:server:propRemove', {
    ace       = 'whip.devtools',
    rateLimit = 250,
    params    = { {'model', 'key', 80} },
}, function(source, _, model)
    model = model:lower()
    local row = PropCatalog._rows[model]
    if not row or row.status == 'unavailable' then
        return false, 'That prop is not in the catalog'
    end

    if not upsert(model, { status = 'unavailable' }) then
        return false, DB_ERROR
    end

    PropCatalog.changed(model)
    ShowSuccess(source, model .. ' removed from the catalog')
end)

--- The props hidden because a game could not have them, by name, in whip_core's own folder: each once, with why,
--- added to as more are found (an admin's game reports them 500 at a time, and a later start only the new ones). The
--- console says only how many: a list of hundreds was a wall of text in it.
local MISSING_FILE = 'missing_props.txt'

--- `models` written into MISSING_FILE, those not in it yet, each with `why`. False when it could not be written.
local function listMissing(models, why)
    local res = GetCurrentResourceName()
    local text = LoadResourceFile(res, MISSING_FILE) or ''
    local listed = {}
    for line in text:gmatch('[^\r\n]+') do
        local model = line:match('^([%w_%-]+)')
        if model then listed[model] = true end
    end
    if text == '' then
        text = ('# Props hidden from selection in game: whip_core found them missing from this game (GTA V %s).\n'
            .. '# Each is marked unavailable in the prop catalog, so the furnisher never offers it. Added to as more\n'
            .. '# are found.\n\n'):format(GamePlatform.enhanced and 'Enhanced' or 'Legacy')
    end
    local add = {}
    for _, model in ipairs(models) do
        if not listed[model] then add[#add + 1] = ('%-48s %s'):format(model, why) end
    end
    if #add == 0 then return true end
    return SaveResourceFile(res, MISSING_FILE, text .. table.concat(add, '\n') .. '\n', -1)
end

--- Mark these catalog models unavailable, list them in MISSING_FILE, and say how many in the console. `why`: what
--- happened to them ("are missing from this game version").
local function binModels(models, why)
    local marked = {}
    for _, model in ipairs(models) do
        model = model:lower()
        local row = PropCatalog._rows[model]
        if row and row.status ~= 'unavailable' and upsert(model, { status = 'unavailable' }) then
            marked[#marked + 1] = model
            PropCatalog.changed(model)
        end
    end
    if #marked == 0 then return end
    local written = listMissing(marked, why)
    print(('[whip_core:props] props system detected %d prop(s) %s. %s, and they have been removed from selection in game.')
        :format(#marked, why, written and ('A list of all their names is in %s/%s'):format(GetCurrentResourceName(), MISSING_FILE)
            or ('Their names could not be written to %s/%s'):format(GetCurrentResourceName(), MISSING_FILE)))
end

--- Models an admin's game does not have (client/property_furnish.lua checks every catalog name
--- against its own archives at login). Marked unavailable, so no furnisher offers them.
---
--- AN ADMIN'S WORD ONLY: a player's client could name any model and hide the whole catalog. Every
--- client hides what it is missing anyway; this is what makes it stick for everyone.
SecureEvent('whip_core:server:propCatalogMissing', {
    ace       = 'whip.devtools',
    rateLimit = 5000,
    params    = { {'models', 'list', {'model', 'key', 80}, 500} },
}, function(_, _, models)
    binModels(models, 'are missing from this game version')
end)

--- Models /propcheck could not make on an admin's game (tools/propcheck.lua): loaded, created and
--- deleted one by one, and these did not come into being. Binned the same way.
SecureEvent('whip_core:server:propCatalogBroken', {
    ace       = 'whip.devtools',
    rateLimit = 500,
    burst     = 4,
    params    = { {'models', 'list', {'model', 'key', 80}, 200} },
}, function(_, _, models)
    binModels(models, 'would not spawn on this game version (/propcheck)')
end)

-- ============================================
-- Exports
-- ============================================

---@param model string
---@return boolean
exports('__HasPropImage', function(model)
    if type(model) ~= 'string' then return false end
    return hasImage(PropCatalog._rows[model:lower()])
end)

--- Is this model something a player is allowed to place? The furnisher's save path asks, because a
--- client naming a model is a client naming ANY model — a police cruiser, a locked door, a whole
--- building — and "it was in the grid" is not a check.
---@param model string
---@return boolean
exports('IsPlaceableProp', function(model)
    if type(model) ~= 'string' then return false end
    local row = PropCatalog._rows[model:lower()]
    return row ~= nil and row.status ~= 'unavailable'
end)

exports('__GetPropCatalog', function() return PropCatalog.wire() end)

-- ============================================
-- Add-on props from other resources (RegisterProps)
-- ============================================
--
-- A prop or MLO pack's props, in the furnisher while the pack runs, under a category whip has, with the pack's own
-- pictures: no edit to config.lua or the media packs. A model whip already lists keeps its row (and an admin's choices on
-- it) and takes the pack's picture. Gone when the pack stops.
local addonProps = Registry.new('AddonProp', {
    label = 'add-on prop',
    onAdd = function(model, a)
        local row = PropCatalog._rows[model]
        if not row then
            row = { model = model, category = a.category, displayName = a.displayName, hasImage = 0, status = 'available',
                    addonOnly = true }
            PropCatalog._rows[model] = row
        end
        row.displayName = row.displayName or a.displayName
        row.addonImage = a.image
        PropCatalog.changed(model)
    end,
    onRemove = function(model)
        local row = PropCatalog._rows[model]
        if not row then return end
        if row.addonOnly then PropCatalog._rows[model] = nil else row.addonImage = nil end
        PropCatalog.changed(model)
    end,
})

--- Your resource's props: the whole list (one you gave before and not now goes). Each { model, name?, category,
--- image? }: category is one of the furnisher's (Config.PropCategories keys); image a picture in your resource
--- ('img/mychair.webp', listed in your files {}), or '@another/img/x.webp'. true, or false and why.
exports('RegisterProps', function(list)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(list) ~= 'table' then return false, 'RegisterProps({ { model, name?, category, image? }, ... })' end
    local read = {}
    for i, e in ipairs(list) do
        if type(e) ~= 'table' or type(e.model) ~= 'string' or e.model == '' or #e.model > 80 then
            return false, ('prop %d needs a model'):format(i)
        end
        if type(e.category) ~= 'string' or not isCategory(e.category) then
            return false, ('prop "%s": category is one of the furnisher\'s (Config.PropCategories)'):format(e.model)
        end
        local image
        if e.image ~= nil then
            local why
            image, why = ResourceFileUrl(owner, e.image)
            if not image then return false, ('prop "%s": %s'):format(e.model, why) end
        end
        read[#read + 1] = { model = e.model:lower(), category = e.category, image = image,
                            displayName = type(e.name) == 'string' and e.name:sub(1, 64) or nil }
    end
    if not WaitForCoreReady() then return false, NOT_READY end
    -- Every model's owner first, so a clash changes nothing: not this list, not the one given before.
    for _, a in ipairs(read) do
        local by = addonProps:get(a.model) ~= nil and addonProps:ownerOf(a.model) or nil
        if by and by ~= owner and Registry.alive(by) then
            local why = ('add-on prop "%s" belongs to %s'):format(a.model, by)
            Registry.sayRefused(owner, why)
            return false, why
        end
    end
    local keep = {}
    for _, a in ipairs(read) do keep[a.model] = true end
    for _, key in ipairs(addonProps:keysOf(owner)) do
        if not keep[key] then addonProps:remove(owner, key) end
    end
    for _, a in ipairs(read) do
        local ok, why = addonProps:add(owner, a.model, a)
        if not ok then return false, why end
    end
    return true
end)
