-- ============================================
-- PROPERTIES — Server Module
-- ============================================
--
-- A property is a unit: a space inside an interior, with its doors, its sign and its garage, at one
-- placement of that interior in the world. One interior can hold several (a Mega premium half-floor
-- is four flats).
--
-- Three things:
--
--   TEMPLATE   one per interior archetype. Its UNITS are described in the interior's own space:
--              where each flat's floor is, where its front door stands, where its sign goes.
--   UNIT       one flat of a template: { space, doors, sign, visit, garage }, all interior-local.
--   PROPERTY   one unit at one placement { hash, x, y, z, yaw }. Everything a player can own.
--
-- Because units are local, every placement of an interior shares them: describe a Mega floor's
-- four flats once and all 36 floors have them. shared/property_math.lua turns a unit into world
-- space, and does it identically here and on every client.
--
-- Layers: a unit's parts can be changed at three levels, and the highest wins, part by part:
--
--   property.overrides   this one property only
--   unit.overlay         an admin's change to a pack's unit, for every property using it
--   unit.base            what the pack (or the admin who built it) said
--
-- What a property does not do, because whip already does it:
--
--   Access    is the door's. A property MANAGES its doors (server/doors.lua, "Managed doors")
--             and writes `requirements = { charIds = owner + keyholders }` on each one. The door
--             system enforces it; there is no second permission system here.
--   Streaming is the client's. This file answers where things are and who may use them.
--
-- Not zones: a property's space is containment maths (shared/shapes.lua), never a registered zone
-- (the server caps zones at 500 per player).

Properties = {}

local _templates = {}   -- [templateId] = template, with .units = { [unitKey] = unit }
local _records   = {}   -- [propertyId] = the live record (row fields + resolved unit + world)
local _keys      = {}   -- [propertyId] = { charId, ... }

--- The door system's name for this module as a manager. See Doors.adoptOrCreate.
local DOOR_SYSTEM = 'property'

--- A unit's parts, in the order the layers are resolved.
local UNIT_PARTS = { 'space', 'doors', 'sign', 'manager', 'visit', 'garage' }

--- Which door roles the property locks. An 'interior' door is left alone unless it is marked
--- `lock`: every managed door starts locked at every server start, which a bedroom door shouldn't.
local MANAGED_ROLES = { entrance = true, garage = true }

-- ============================================
-- Helpers
-- ============================================

local function decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, v = pcall(json.decode, s)
    return ok and v or nil
end

local function encode(v)
    if v == nil then return nil end
    return json.encode(v)
end

local function finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function log(msg, ...)
    print(('[whip_core:properties] ' .. msg):format(...))
end

--- A database failure: the raw error to the console, and the one sentence (DB_ERROR) to the caller,
--- never the raw SQL text.
---@param what string  what was being done, for the console line
---@param err any
---@return string DB_ERROR
local function dbFail(what, err)
    log('database error %s: %s', what, tostring(err))
    return DB_ERROR
end

-- ============================================
-- Database
-- ============================================

---@return boolean ok
function Properties.ensureTables()
    -- In this order: each table's foreign keys point at the ones above it (and at `characters`).
    local statements = {
        { 'property_templates', [[CREATE TABLE IF NOT EXISTS `property_templates` (
            `templateId`    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
            `templateKey`   VARCHAR(120)  NOT NULL,
            `source`        VARCHAR(64)   NOT NULL DEFAULT 'admin',
            `label`         VARCHAR(100)  NOT NULL DEFAULT 'Interior',
            `archetype`     VARCHAR(100)  NULL,
            `archetypeHash` INT           NOT NULL DEFAULT 0,
            `fingerprint`   JSON          NULL,
            `rooms`         JSON          NULL,
            `settings`      JSON          NULL,
            `packVersion`   VARCHAR(32)   NULL,
            `createdAt`     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`templateId`),
            UNIQUE KEY `uq_template_key` (`templateKey`),
            KEY `idx_template_hash` (`archetypeHash`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },

        { 'property_template_units', [[CREATE TABLE IF NOT EXISTS `property_template_units` (
            `templateId` INT UNSIGNED NOT NULL,
            `unitKey`    VARCHAR(64)  NOT NULL,
            `label`      VARCHAR(100) NOT NULL DEFAULT 'Unit',
            `sortOrder`  INT          NOT NULL DEFAULT 0,
            `base`       JSON         NOT NULL,
            `overlay`    JSON         NULL,
            PRIMARY KEY (`templateId`, `unitKey`),
            CONSTRAINT `fk_ptu_template` FOREIGN KEY (`templateId`)
                REFERENCES `property_templates` (`templateId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },

        -- propertyKey is NULL for an admin's property and '<packId>:<key>' for a pack's: a UNIQUE
        -- key allows any number of NULLs, and only packs need to find their properties by name.
        -- A template in use cannot be deleted (RESTRICT); a deleted character's property becomes
        -- unowned (SET NULL) and keeps its row.
        { 'properties', [[CREATE TABLE IF NOT EXISTS `properties` (
            `propertyId`    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
            `propertyKey`   VARCHAR(120)  NULL,
            `source`        VARCHAR(64)   NOT NULL DEFAULT 'admin',
            `name`          VARCHAR(100)  NOT NULL DEFAULT 'Property',
            `label`         VARCHAR(60)   NULL,
            `building`      VARCHAR(100)  NULL,
            `templateId`    INT UNSIGNED  NOT NULL,
            `unitKey`       VARCHAR(64)   NOT NULL,
            `archetypeHash` INT           NOT NULL DEFAULT 0,
            `px`            DOUBLE        NOT NULL DEFAULT 0,
            `py`            DOUBLE        NOT NULL DEFAULT 0,
            `pz`            DOUBLE        NOT NULL DEFAULT 0,
            `yaw`           DOUBLE        NOT NULL DEFAULT 0,
            `overrides`     JSON          NULL,
            `settings`      JSON          NULL,
            -- Its look, from the resource that built its interior (server/property_themes.lua;
            -- migration 033 adds it to an existing table). NULL: its first.
            `theme`         TINYINT UNSIGNED NULL,
            `ownerCharId`   INT UNSIGNED  NULL,
            `status`        VARCHAR(16)   NOT NULL DEFAULT 'unverified',
            `statusReason`  VARCHAR(255)  NULL,
            `verifiedAt`    TIMESTAMP     NULL,
            `deletedAt`     TIMESTAMP     NULL,
            `createdAt`     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy`     INT UNSIGNED  NULL,
            PRIMARY KEY (`propertyId`),
            UNIQUE KEY `uq_property_key` (`propertyKey`),
            KEY `idx_prop_owner` (`ownerCharId`),
            KEY `idx_prop_template` (`templateId`, `unitKey`),
            KEY `idx_prop_hash` (`archetypeHash`),
            CONSTRAINT `fk_prop_template` FOREIGN KEY (`templateId`)
                REFERENCES `property_templates` (`templateId`) ON DELETE RESTRICT,
            CONSTRAINT `fk_prop_owner` FOREIGN KEY (`ownerCharId`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL,
            CONSTRAINT `fk_prop_createdBy` FOREIGN KEY (`createdBy`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },

        -- A key goes with its property, and with the character holding it.
        { 'property_keys', [[CREATE TABLE IF NOT EXISTS `property_keys` (
            `propertyId` INT UNSIGNED NOT NULL,
            `charId`     INT UNSIGNED NOT NULL,
            `grantedBy`  INT UNSIGNED NULL,
            `grantedAt`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`propertyId`, `charId`),
            KEY `idx_pkey_char` (`charId`),
            CONSTRAINT `fk_pkey_property` FOREIGN KEY (`propertyId`)
                REFERENCES `properties` (`propertyId`) ON DELETE CASCADE,
            CONSTRAINT `fk_pkey_char` FOREIGN KEY (`charId`)
                REFERENCES `characters` (`charId`) ON DELETE CASCADE,
            CONSTRAINT `fk_pkey_grantedBy` FOREIGN KEY (`grantedBy`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]] },
    }
    local allOk = true
    for _, t in ipairs(statements) do
        if not CreateTable(t[1], t[2]) then allOk = false end
    end
    return allOk
end

-- ============================================
-- Templates and units
-- ============================================

local function rowToTemplate(row)
    return {
        templateId    = row.templateId,
        templateKey   = row.templateKey,
        source        = row.source or 'admin',
        label         = row.label or 'Interior',
        archetype     = row.archetype,
        archetypeHash = tonumber(row.archetypeHash) or 0,
        fingerprint   = decode(row.fingerprint),
        rooms         = decode(row.rooms),
        settings      = decode(row.settings) or {},
        packVersion   = row.packVersion,
        units         = {},
    }
end

local function rowToUnit(row)
    return {
        unitKey   = row.unitKey,
        label     = row.label or row.unitKey,
        sortOrder = tonumber(row.sortOrder) or 0,
        base      = decode(row.base) or {},
        overlay   = decode(row.overlay),
    }
end

---@return table|nil
function Properties.getTemplate(templateId)
    return _templates[tonumber(templateId) or -1]
end

--- Every template, by id. Internal callers only: treat it as read-only.
function Properties.getTemplates()
    return _templates
end

---@return table|nil
function Properties.getTemplateByKey(templateKey)
    for _, t in pairs(_templates) do
        if t.templateKey == templateKey then return t end
    end
    return nil
end

--- Every template for one archetype — what "you are standing in a known interior" asks.
---@param hash number  signed archetype hash
---@return table[]
function Properties.templatesFor(hash)
    local out = {}
    for _, t in pairs(_templates) do
        if t.archetypeHash == hash then out[#out + 1] = t end
    end
    table.sort(out, function(a, b) return a.templateId < b.templateId end)
    return out
end

--- A new, unique key for an admin-made template.
local function newTemplateKey(hash)
    return ('admin:%s:%d%03d'):format(hash ~= 0 and tostring(hash) or 'world', os.time(), math.random(0, 999))
end

--- Create or replace a template, by templateKey.
---
--- `data` = { templateKey?, source?, label?, archetype?, archetypeHash, fingerprint?, rooms?,
---            settings?, packVersion? }. The units are saved separately (saveUnit).
---
--- `opts.quiet` skips re-resolving the properties built on it: a pack saving a template and all
--- its units resolves them once, at the end, rather than once per unit.
---@return table|nil template, string|nil err
function Properties.saveTemplate(data, opts)
    if type(data) ~= 'table' then return nil, 'Expected a table' end
    local hash = PropertyMath.signedHash(data.archetypeHash or data.archetype or 0) or 0
    local existing = data.templateKey and Properties.getTemplateByKey(data.templateKey) or nil

    local t = {
        templateId    = existing and existing.templateId or nil,
        templateKey   = data.templateKey or newTemplateKey(hash),
        source        = data.source or 'admin',
        label         = tostring(data.label or 'Interior'):sub(1, 100),
        archetype     = data.archetype and tostring(data.archetype):sub(1, 100) or nil,
        archetypeHash = hash,
        fingerprint   = data.fingerprint,
        rooms         = data.rooms,
        settings      = data.settings or {},
        packVersion   = data.packVersion and tostring(data.packVersion):sub(1, 32) or nil,
        units         = existing and existing.units or {},
    }
    local values = {
        t.templateKey, t.source, t.label, t.archetype, t.archetypeHash,
        encode(t.fingerprint), encode(t.rooms), encode(t.settings), t.packVersion,
    }

    if existing then
        -- The id goes in slot 10 by number, not at `#values + 1`: `#` on a list with nils in it
        -- (no archetype, no packVersion) can stop short.
        values[10] = existing.templateId
        local ok, err = pcall(MySQL.query.await,
            'UPDATE `property_templates` SET `templateKey`=?, `source`=?, `label`=?, `archetype`=?, '
            .. '`archetypeHash`=?, `fingerprint`=?, `rooms`=?, `settings`=?, `packVersion`=? '
            .. 'WHERE `templateId`=?', values)
        if not ok then return nil, dbFail('saving the template', err) end
    else
        local ok, id = pcall(MySQL.insert.await,
            'INSERT INTO `property_templates` (`templateKey`,`source`,`label`,`archetype`,`archetypeHash`,'
            .. '`fingerprint`,`rooms`,`settings`,`packVersion`) VALUES (?,?,?,?,?,?,?,?,?)', values)
        if not ok or not id then return nil, dbFail('creating the template', id) end
        t.templateId = id
    end

    _templates[t.templateId] = t

    -- New rooms or settings reach every property built on it.
    if existing and not (opts and opts.quiet) then
        for id, rec in pairs(_records) do
            if rec.templateId == t.templateId then Properties.resync(id) end
        end
    end
    return t
end

--- Create or replace one unit of a template.
---
--- `data` = { label?, sortOrder?, base, overlay? }. `overlay = false` clears the overlay.
--- Every property using the unit is re-resolved: its space, doors and sign move with it — unless
--- `opts.quiet`, when the caller resolves them itself.
---@return table|nil unit, string|nil err
function Properties.saveUnit(templateId, unitKey, data, opts)
    local t = Properties.getTemplate(templateId)
    if not t then return nil, 'Unknown template' end
    if type(unitKey) ~= 'string' or unitKey == '' or #unitKey > 64 then return nil, 'Bad unit key' end
    if type(data) ~= 'table' or type(data.base) ~= 'table' then return nil, 'A unit needs a base' end

    local prev = t.units[unitKey]
    local overlay = data.overlay
    if overlay == nil and prev then overlay = prev.overlay end
    if overlay == false then overlay = nil end

    local label = tostring(data.label or (prev and prev.label) or unitKey):sub(1, 100)
    local sortOrder = tonumber(data.sortOrder) or (prev and prev.sortOrder) or 0

    local ok, err = pcall(MySQL.query.await,
        'INSERT INTO `property_template_units` (`templateId`,`unitKey`,`label`,`sortOrder`,`base`,`overlay`) '
        .. 'VALUES (?,?,?,?,?,?) ON DUPLICATE KEY UPDATE `label`=VALUES(`label`), `sortOrder`=VALUES(`sortOrder`), '
        .. '`base`=VALUES(`base`), `overlay`=VALUES(`overlay`)',
        { t.templateId, unitKey, label, sortOrder, encode(data.base), encode(overlay) })
    if not ok then return nil, dbFail('saving the unit', err) end

    local unit = { unitKey = unitKey, label = label, sortOrder = sortOrder, base = data.base, overlay = overlay }
    t.units[unitKey] = unit

    if not (opts and opts.quiet) then
        for id, rec in pairs(_records) do
            if rec.templateId == t.templateId and rec.unitKey == unitKey then
                -- A runtime lookup: markChanged is defined further down, with the status helpers.
                Properties.markChanged(id)
                Properties.resync(id)
            end
        end
    end
    return unit
end

--- Remove a unit from its template. Refused while any property (live or deleted) uses it.
---@return boolean ok, string|nil err
function Properties.deleteUnit(templateId, unitKey)
    local t = Properties.getTemplate(templateId)
    if not t or not t.units[unitKey] then return true end
    local ok, n = pcall(MySQL.scalar.await,
        'SELECT COUNT(*) FROM `properties` WHERE `templateId`=? AND `unitKey`=?', { t.templateId, unitKey })
    if not ok then return false, dbFail('checking the unit is unused', n) end
    if (tonumber(n) or 0) > 0 then return false, 'properties still use it' end
    local dok, err = pcall(MySQL.query.await,
        'DELETE FROM `property_template_units` WHERE `templateId`=? AND `unitKey`=?', { t.templateId, unitKey })
    if not dok then return false, dbFail('deleting the unit', err) end
    t.units[unitKey] = nil
    return true
end

--- Remove a template that has no units left: what a first save that failed half-way made.
---@return boolean ok, string|nil err
function Properties.deleteTemplate(templateId)
    local t = Properties.getTemplate(templateId)
    if not t then return true end
    if next(t.units) ~= nil then return false, 'it still has units' end
    local ok, err = pcall(MySQL.query.await, 'DELETE FROM `property_templates` WHERE `templateId`=?', { t.templateId })
    if not ok then return false, dbFail('deleting the template', err) end
    _templates[t.templateId] = nil
    return true
end

--- Every template (and its units) from one source, gone. For a test pack's teardown; the caller
--- deletes the properties first.
function Properties.dropTemplatesBySource(source)
    for id, t in pairs(_templates) do
        if t.source == source then
            -- The template only after its units are gone; either failing leaves it listed, and said.
            local ok, err = pcall(MySQL.query.await, 'DELETE FROM `property_template_units` WHERE `templateId`=?', { id })
            if ok then
                ok, err = pcall(MySQL.query.await, 'DELETE FROM `property_templates` WHERE `templateId`=?', { id })
            end
            if ok then
                _templates[id] = nil
            else
                log('could not drop template #%d of %s: %s', id, tostring(source), tostring(err))
            end
        end
    end
end

-- ============================================
-- Resolving a property: layers, then world space
-- ============================================

--- The unit as this property sees it: each part from the highest layer that says anything.
--- `false` at any layer means "none" (a garage turned off for one property).
local function resolveUnit(template, unitKey, overrides)
    local u = template and template.units[unitKey]
    if not u then return nil end
    local out = {}
    for _, part in ipairs(UNIT_PARTS) do
        local v
        if overrides and overrides[part] ~= nil then v = overrides[part]
        elseif u.overlay and u.overlay[part] ~= nil then v = u.overlay[part]
        else v = u.base and u.base[part] end
        if v ~= false then out[part] = v end
    end
    return out
end

--- Defaults, then the template's, then the property's own.
local function resolveSettings(template, own)
    local s = {
        price         = 0,
        maxObjects    = Config.PropertyMaxObjects or 150,
        autolock      = false,
        autolockDelay = 10,
    }
    for k, v in pairs((template and template.settings) or {}) do s[k] = v end
    for k, v in pairs(own or {}) do s[k] = v end
    return s
end

--- How many rooms it has, for its for-sale sign: the interior's rooms its space takes (the whole
--- interior's, or the ones picked), counted as PropertyMath.expandSpace takes them, limbo never one.
--- nil when not known: the interior's rooms not read yet, or any of its space drawn by hand.
---@return integer|nil
local function roomCount(unit, rooms)
    if type(rooms) ~= 'table' or #rooms == 0 or not unit or not unit.space then return nil end
    local counted = {}
    local n = 0
    for _, s in ipairs(unit.space) do
        if s.type ~= 'interior' and s.type ~= 'rooms' then return nil end
        local want = nil
        if s.type == 'rooms' then
            want = {}
            for _, name in ipairs(s.rooms or {}) do want[tostring(name):lower()] = true end
        end
        for _, r in ipairs(rooms) do
            local name = tostring(r.name or ''):lower()
            if name ~= 'limbo' and not counted[name] and (not want or want[name]) then
                counted[name] = true
                n = n + 1
            end
        end
    end
    return n > 0 and n or nil
end

--- Recompute a record's derived fields from its row fields. No I/O.
local function derive(rec)
    local t = _templates[rec.templateId]
    rec.unit = resolveUnit(t, rec.unitKey, rec.overrides)
    rec.roomCount = roomCount(rec.unit, t and t.rooms)
    rec.effective = resolveSettings(t, rec.settings)
    if rec.unit then
        rec.world = PropertyMath.unitToWorld(rec.place, rec.unit, t and t.rooms)
    else
        rec.world = { shapes = {}, doors = {}, bays = {}, unresolved = true,
                      anchor = { x = rec.place.x, y = rec.place.y, z = rec.place.z, r = 2.0 } }
    end
    rec._wire = nil
end

local function rowToRecord(row)
    return {
        propertyId    = row.propertyId,
        propertyKey   = row.propertyKey,
        source        = row.source or 'admin',
        name          = row.name or 'Property',
        label         = row.label,
        building      = row.building,
        templateId    = row.templateId,
        unitKey       = row.unitKey,
        place         = {
            hash = tonumber(row.archetypeHash) or 0,
            x = tonumber(row.px) or 0.0, y = tonumber(row.py) or 0.0,
            z = tonumber(row.pz) or 0.0, yaw = tonumber(row.yaw) or 0.0,
        },
        overrides     = decode(row.overrides),
        settings      = decode(row.settings) or {},
        theme         = tonumber(row.theme),
        ownerCharId   = row.ownerCharId,
        status        = row.status or 'unverified',
        statusReason  = row.statusReason,
        createdBy     = row.createdBy,
        -- A pack property whose resource is not running is inactive.
        active        = true,
    }
end

-- ============================================
-- "Which property is this?" — a grid over their bounds
-- ============================================
--
-- Properties.at answers it for the server: furniture bounds, the garage, anything that has a point
-- and wants the property holding it. A cell grid over each property's anchor sphere, so a lookup
-- walks the handful of properties near the point rather than all of them.

local CELL = 64.0
local _grid = {}      -- [cellKey] = { [propertyId] = true }
local _cellsOf = {}   -- [propertyId] = { cellKey, ... }

local function cellKey(cx, cy) return cx .. ':' .. cy end

local function gridRemove(id)
    for _, k in ipairs(_cellsOf[id] or {}) do
        local bucket = _grid[k]
        if bucket then
            bucket[id] = nil
            if next(bucket) == nil then _grid[k] = nil end
        end
    end
    _cellsOf[id] = nil
end

local function gridInsert(rec)
    gridRemove(rec.propertyId)
    local a = rec.world and rec.world.anchor
    if not a then return end
    local keys = {}
    for cx = math.floor((a.x - a.r) / CELL), math.floor((a.x + a.r) / CELL) do
        for cy = math.floor((a.y - a.r) / CELL), math.floor((a.y + a.r) / CELL) do
            local k = cellKey(cx, cy)
            local bucket = _grid[k]
            if not bucket then bucket = {}; _grid[k] = bucket end
            bucket[rec.propertyId] = true
            keys[#keys + 1] = k
        end
    end
    _cellsOf[rec.propertyId] = keys
end

--- The property whose space holds this point, or nil.
---@param slack number|nil  metres of give on every side (furniture pushed against a wall)
---@return table|nil record
function Properties.at(x, y, z, slack)
    local bucket = _grid[cellKey(math.floor(x / CELL), math.floor(y / CELL))]
    if not bucket then return nil end
    for id in pairs(bucket) do
        local rec = _records[id]
        if rec and rec.world and Shapes.containsAny(rec.world.shapes, x, y, z, slack) then return rec end
    end
    return nil
end

-- ============================================
-- Reads
-- ============================================

--- The live record. Internal callers only: treat it as read-only.
---@return table|nil
function Properties.get(propertyId)
    return _records[tonumber(propertyId) or -1]
end

function Properties.getAll()
    return _records
end

--- A property by its pack key ('<packId>:<key>'), or nil. Admin properties have none.
---@return table|nil
function Properties.getByKey(propertyKey)
    if not propertyKey then return nil end
    for _, rec in pairs(_records) do
        if rec.propertyKey == propertyKey then return rec end
    end
    return nil
end

--- The keys of a source's deleted (tombstoned) properties, as a set: what a pack must not make again.
---@return table<string, boolean>
function Properties.tombstonedKeys(source)
    local out = {}
    local ok, rows = pcall(MySQL.query.await,
        'SELECT `propertyKey` FROM `properties` WHERE `source`=? AND `deletedAt` IS NOT NULL AND `propertyKey` IS NOT NULL',
        { source })
    if ok then for _, r in ipairs(rows or {}) do out[r.propertyKey] = true end end
    return out
end

--- Every charId holding a key. Never nil.
---@return number[]
function Properties.keysFor(propertyId)
    return _keys[tonumber(propertyId) or -1] or {}
end

---@return boolean
function Properties.hasKey(propertyId, charId)
    for _, c in ipairs(Properties.keysFor(propertyId)) do
        if c == charId then return true end
    end
    return false
end

--- What a character holds: the properties they own, and the ones they have a key to. Ids, sorted.
---@return { owned: number[], keys: number[] }
function Properties.forCharacter(charId)
    charId = tonumber(charId)
    local owned, keyed = {}, {}
    for id, rec in pairs(_records) do
        if rec.ownerCharId == charId then owned[#owned + 1] = id
        elseif Properties.hasKey(id, charId) then keyed[#keyed + 1] = id end
    end
    table.sort(owned); table.sort(keyed)
    return { owned = owned, keys = keyed }
end

--- May this character use the property — its owner or a keyholder?
---@return boolean
function Properties.hasAccess(propertyId, charId)
    local rec = Properties.get(propertyId)
    if not rec or not charId then return false end
    if rec.ownerCharId == charId then return true end
    return Properties.hasKey(propertyId, charId)
end

--- The shapes a client re-prepares: the plain fields only, never the prepared caches.
local function wireShapes(shapes)
    local out = {}
    for i, s in ipairs(shapes or {}) do
        if s.type == 'box' then
            out[i] = { type = 'box', pos = s.pos, size = s.size, heading = s.heading }
        else
            out[i] = { type = 'poly', points = s.points, minZ = s.minZ, maxZ = s.maxZ }
        end
    end
    return out
end

--- One property as every client receives it.
---
--- A projection, not the record: the client needs where the space and the sign are, what to call
--- the place and whose it is. Not the keyholders (private), not the doors (the door system sends
--- those), not who made it or when.
---@return table
function Properties.wireOne(rec)
    if rec._wire then return rec._wire end
    local w = rec.world or {}
    rec._wire = {
        id          = rec.propertyId,
        name        = rec.name,
        label       = rec.label,
        building    = rec.building,
        ownerCharId = rec.ownerCharId,
        active      = rec.active ~= false,
        place       = rec.place,
        anchor      = w.anchor,
        sign        = w.sign,      -- outside, while it is for sale
        manager     = w.manager,   -- inside, once it is somebody's
        visit       = w.visit,
        shapes      = wireShapes(w.shapes),
        maxObjects  = rec.effective and rec.effective.maxObjects or nil,
        price       = rec.effective and rec.effective.price or 0,
        -- For its for-sale sign: how many garage bays, and how many rooms (nil when not known: roomCount).
        bays        = #(w.bays or {}),
        rooms       = rec.roomCount,
        -- Its private garage, when its unit has bays ('property:<id>'). Who may use it is the
        -- garage system's per-player garageAccess, not this.
        garageKey   = rec.garageKey,
        -- Its interior's resource offers it looks (server/property_themes.lua): the sign has Theme.
        themes      = (PropertyThemes and PropertyThemes.offered(rec)) or nil,
    }
    return rec._wire
end

---@return table[]
function Properties.wire()
    local out = {}
    for _, rec in pairs(_records) do out[#out + 1] = Properties.wireOne(rec) end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- The full set, at a player (or everyone with -1).
function Properties.sync(target)
    TriggerClientEvent('whip_core:client:propertiesSync', target or -1, Properties.wire())
end

local function announce(propertyId)
    local rec = _records[propertyId]
    if rec then
        TriggerClientEvent('whip_core:client:propertyUpdated', -1, Properties.wireOne(rec))
    else
        TriggerClientEvent('whip_core:client:propertyDeleted', -1, propertyId)
    end
    -- And to any admin with the Properties panel open, who sees more than the wire carries.
    -- A runtime lookup: server/property_admin.lua loads after this file.
    if PropertyAdmin then PropertyAdmin.changed(propertyId) end
end

--- Send a property to every client again: something its wire reads from outside the record changed
--- (a theme resource came or went: server/property_themes.lua).
function Properties.reannounce(propertyId)
    local rec = _records[tonumber(propertyId) or -1]
    if not rec then return end
    rec._wire = nil
    announce(rec.propertyId)
end

--- Its look (server/property_themes.lua checks which): the row, then the record. Nothing else moves, so
--- nothing is announced but to the admin panel.
---@param themeId integer|nil  nil: its first look
---@return boolean ok, string|nil err
function Properties.setTheme(propertyId, themeId)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local ok, err = pcall(MySQL.update.await, 'UPDATE `properties` SET `theme`=? WHERE `propertyId`=?',
        { themeId, rec.propertyId })
    if not ok then return false, dbFail('saving its theme', err) end
    rec.theme = themeId
    if PropertyAdmin then PropertyAdmin.changed(rec.propertyId) end
    return true
end

-- ============================================
-- Doors and access
-- ============================================

local function managerFor(rec, key)
    return {
        system = DOOR_SYSTEM,
        id     = rec.propertyId,
        key    = key,
        label  = ('Property #%d · %s'):format(rec.propertyId, rec.name or 'Property'),
    }
end

--- Who opens this property's doors: the owner, then the keyholders in id order.
---
--- Ordered, so the door system can compare it with what the door has and write nothing on a match.
---
--- Unowned is `{ charIds = {} }`, which matches nobody. An EMPTY requirements table would mean
--- "no requirements", and a vacant property would stand open to everyone.
local function accessFor(rec)
    local ids = {}
    if rec.ownerCharId then ids[1] = rec.ownerCharId end
    local keyed = {}
    for _, c in ipairs(Properties.keysFor(rec.propertyId)) do
        if c ~= rec.ownerCharId then keyed[#keyed + 1] = c end
    end
    table.sort(keyed)
    for _, c in ipairs(keyed) do ids[#ids + 1] = c end
    return { charIds = ids }
end

local ROLE_LABEL = { entrance = 'Entrance', garage = 'Garage', interior = 'Door' }

--- Put this property's doors in step with its unit, owner and keys.
---
--- Every step is "make it so", so running it twice changes nothing the second time: boot runs it
--- for every property, and any change calls it again:
---
---   a door the unit no longer has     released FIRST: deleted if it was made, restored if adopted
---   each managed door of the unit     adopted or made, named, filed, given the access list
---   `pair`                            the two leaves linked
---   the autolock setting              written onto the entrance and garage doors
---
--- The old doors go before the new ones are made (an MLO update can move its doors). A door this
--- property holds counts as one of the unit's only where the unit still wants a door of its model
--- (within the half metre the door system adopts in); every other door is let go first, so it can't
--- stand in the way of a new one.
---
---@return string[] problems  sentences for the admin; empty when all is well
local function syncDoors(rec)
    local problems = {}
    local want, byKey = {}, {}
    local req = accessFor(rec)
    local folder = 'Properties/' .. (rec.building and rec.building ~= '' and rec.building or 'Other')

    for _, d in ipairs((rec.world and rec.world.doors) or {}) do
        if d.key and (MANAGED_ROLES[d.role] or d.lock) then want[d.key] = d end
    end

    local function stillWanted(door)
        local model = PropertyMath.signedHash(door.model)
        for _, d in pairs(want) do
            local dx, dy, dz = door.x - d.x, door.y - d.y, door.z - d.z
            if dx * dx + dy * dy + dz * dz < 0.25 and PropertyMath.signedHash(d.model) == model then return true end
        end
        return false
    end
    for _, door in ipairs(Doors.listManaged(DOOR_SYSTEM, rec.propertyId)) do
        if not stillWanted(door) then
            local ok, err = Doors.release(door.doorId, managerFor(rec))
            if not ok then problems[#problems + 1] = ('releasing door #%d: %s'):format(door.doorId, tostring(err)) end
        end
    end

    for key, d in pairs(want) do
        local door, how = Doors.adoptOrCreate({
            model = d.model, x = d.x, y = d.y, z = d.z, heading = d.heading,
            label = ('%s — %s'):format(rec.name or 'Property', ROLE_LABEL[d.role] or key),
            folder = folder,
            requirements = req,
        }, managerFor(rec, key))
        if door then
            byKey[key] = door
        else
            -- Another property's door, or a different model, standing where this one should be.
            problems[#problems + 1] = ('door "%s": %s'):format(key, tostring(how))
        end
    end

    -- Doors this property still holds that no key took, though one stands where a wanted door is:
    -- a second door on the same spot (adoptOrCreate takes the nearer), or one it gave up on. The
    -- first pass let everything else go.
    for _, door in ipairs(Doors.listManaged(DOOR_SYSTEM, rec.propertyId)) do
        local mb = Doors.managerOf(door)
        local keep = mb and byKey[mb.key] and byKey[mb.key].doorId == door.doorId
        if not keep then
            local ok, err = Doors.release(door.doorId, managerFor(rec))
            if not ok then problems[#problems + 1] = ('releasing door #%d: %s'):format(door.doorId, tostring(err)) end
        end
    end

    for key, d in pairs(want) do
        local a, b = byKey[key], d.pair and byKey[d.pair]
        if a and b and a.linkedDoorId ~= b.doorId then
            local ok, err = Doors.linkDoors(a.doorId, b.doorId, managerFor(rec))
            if not ok then problems[#problems + 1] = ('pairing "%s" and "%s": %s'):format(key, d.pair, tostring(err)) end
        end
    end

    local s = rec.effective or {}
    local autolock, delay = s.autolock == true, math.floor(tonumber(s.autolockDelay) or 10)
    for key, door in pairs(byKey) do
        local role = want[key].role
        if (role == 'entrance' or role == 'garage')
            and (door.autolock ~= autolock or (autolock and door.autolockDelay ~= delay)) then
            Doors.update(door.doorId, { autolock = autolock, autolockDelay = delay }, managerFor(rec))
        end
    end

    rec.doorIds = {}
    for key, door in pairs(byKey) do rec.doorIds[key] = door.doorId end
    return problems
end

--- Lock every door the property locks. For the moments its access changes hands: the list is
--- rewritten, but a door left open stays open, to everyone.
local function lockDoors(rec)
    for _, doorId in pairs(rec.doorIds or {}) do
        -- Only the ones that are open: locking a locked door re-announces it (a red flash for every
        -- onlooker) and moves its autolock number on.
        local door = Doors.getDef(doorId)
        if not door or not door.locked then Doors.updateState(doorId, true) end
    end
end

-- ============================================
-- The private garage
-- ============================================
--
-- A unit may have bays (garage.bays, interior-local like the rest of it). Every property built on
-- it then has a garage of its own, 'property:<id>', PRIVATE to its owner and keyholders — see
-- "Private garages" in server/garages.lua. Its bays are ordinary GarageSpots, so the prompts, the
-- car list and the Store option are the garage system's own; this file only keeps the garage and
-- its bays where the unit says, and answers who may use it.
--
-- Who may use it changes with the keys, so every change of owner or key ends in accessChanged:
-- the cars of anybody who has lost access are moved to a public garage, and the clients of
-- everybody whose access changed are told which bays are theirs now.

local GARAGE_PREFIX = 'property:'

local function garageKeyOf(propertyId)
    return GARAGE_PREFIX .. tostring(propertyId)
end

-- Registered at file scope: server/garages.lua loads first, and Vehicles.loadAll asks at boot
-- which garages are private before any property is loaded.
Garages.registerAccess(GARAGE_PREFIX, function(key, charId)
    local id = tonumber(key:sub(#GARAGE_PREFIX + 1))
    return id ~= nil and Properties.hasAccess(id, charId)
end, function(key)
    local id = tonumber(key:sub(#GARAGE_PREFIX + 1))
    local rec = id and _records[id]
    return rec and ('Property #%d · %s'):format(id, rec.name or 'Property') or ('Property #%s'):format(tostring(id))
end)

local function sameSpot(s, b)
    local dx, dy, dz = s.x - b.x, s.y - b.y, s.z - b.z
    return dx * dx + dy * dy + dz * dz < 0.05 * 0.05
        and math.abs(PropertyMath.angleDelta(s.heading or 0.0, b.heading or 0.0)) < 0.5
end

--- Put this property's garage in step with its unit: made, named and its bays placed as the unit
--- says, or gone — its cars moved to a public garage first — when the unit has no bays.
---
--- Make it so, like syncDoors: a garage that already matches writes nothing. A bay that moved is
--- moved (its spot keeps its id); only the difference is created or deleted.
---@return string[] problems
local function syncGarage(rec)
    local problems = {}
    -- A unit that cannot be found says nothing about its garage. Taking the garage away because a
    -- pack is half-applied would move every car in it across town.
    if not rec.unit then return problems end

    local key = garageKeyOf(rec.propertyId)
    local bays = (rec.world and rec.world.bays) or {}
    local g = Garages.get(key)

    if #bays == 0 then
        if g then
            Garages.evict(key, true)
            local ok, err = Garages.delete(key)
            if not ok then problems[#problems + 1] = 'removing its garage: ' .. tostring(err) end
        end
        rec.garageKey = nil
        return problems
    end

    local first = bays[1]
    local fields = {
        name = ((rec.name or 'Property') .. ' Garage'):sub(1, 100),
        x = first.x, y = first.y, z = first.z, heading = first.heading,
        spawnX = first.x, spawnY = first.y, spawnZ = first.z, spawnHeading = first.heading,
    }
    if not g then
        fields.key = key
        local made, err = Garages.create(fields)
        if not made then
            problems[#problems + 1] = 'making its garage: ' .. tostring(err)
            return problems
        end
        -- The owner and keyholders can use it from now: their clients show its bays.
        local who = {}
        if rec.ownerCharId then who[1] = rec.ownerCharId end
        for _, c in ipairs(Properties.keysFor(rec.propertyId)) do who[#who + 1] = c end
        Garages.pushAccessFor(who)
    elseif g.name ~= fields.name or not sameSpot(g, first) then
        local ok, err = Garages.update(key, fields)
        if not ok then problems[#problems + 1] = 'updating its garage: ' .. tostring(err) end
    end
    rec.garageKey = key

    -- The bays. Exact matches stay; a bay that moved takes a spot that no longer matches anything
    -- (so a spot id survives an edit); whatever is left over is made or deleted.
    local have, used = {}, {}
    for _, s in ipairs(GarageSpots.all()) do
        if s.garageKey == key then have[#have + 1] = s end
    end
    table.sort(have, function(a, b) return a.spotId < b.spotId end)
    local unmatched = {}
    for _, b in ipairs(bays) do
        local match = nil
        for _, s in ipairs(have) do
            if not used[s.spotId] and sameSpot(s, b) then match = s break end
        end
        if match then used[match.spotId] = true else unmatched[#unmatched + 1] = b end
    end
    for _, b in ipairs(unmatched) do
        local spare = nil
        for _, s in ipairs(have) do
            if not used[s.spotId] then spare = s break end
        end
        if spare then
            used[spare.spotId] = true
            local moved, err = GarageSpots.update(spare.spotId, b.x, b.y, b.z, b.heading)
            if not moved then problems[#problems + 1] = 'moving a garage bay: ' .. tostring(err) end
        else
            local made, err = GarageSpots.create(key, b.x, b.y, b.z, b.heading, 'property')
            if not made then problems[#problems + 1] = 'making a garage bay: ' .. tostring(err) end
        end
    end
    for _, s in ipairs(have) do
        if not used[s.spotId] then GarageSpots.delete(s.spotId) end
    end
    return problems
end

--- After a change of who may use a property: cars of anybody who lost access leave its garage,
--- and every client whose access changed is told.
---@param charIds number[]  everyone whose access may have changed
local function accessChanged(rec, charIds)
    local key = garageKeyOf(rec.propertyId)
    if Garages.get(key) then Garages.evict(key) end
    Garages.pushAccessFor(charIds)
end

-- ============================================
-- Status
-- ============================================
--
-- ok          checked in the world by Verify, and nothing has changed since
-- unverified  never checked, or changed since it was
-- attention   something needs an admin: the reason says what
--
-- Reconcile's reasons start 'reconcile:', so a problem it finds is cleared when it goes away
-- without touching what Verify said.

local function setStatus(rec, status, reason)
    if reason then reason = tostring(reason):sub(1, 255) end
    if rec.status == status and rec.statusReason == reason then return end
    local ok = pcall(MySQL.query.await,
        'UPDATE `properties` SET `status`=?, `statusReason`=? WHERE `propertyId`=?',
        { status, reason, rec.propertyId })
    if ok then
        rec.status, rec.statusReason = status, reason
    end
end

local function applyProblems(rec, problems)
    if not rec.unit then
        problems[#problems + 1] = ('its unit "%s" is missing from template #%s')
            :format(tostring(rec.unitKey), tostring(rec.templateId))
    end
    if #problems > 0 then
        setStatus(rec, 'attention', 'reconcile: ' .. table.concat(problems, '; '))
    elseif rec.status == 'attention' and tostring(rec.statusReason or ''):sub(1, 10) == 'reconcile:' then
        setStatus(rec, 'unverified', nil)
    end
end

--- A property's parts changed (its placement, its unit, its own changes): what Verify said about
--- it no longer holds. 'ok' and Verify's own 'attention' go back to 'unverified'; a problem the
--- reconcile found stays until the reconcile clears it.
function Properties.markChanged(propertyId)
    local rec = _records[tonumber(propertyId) or -1]
    if not rec then return end
    local reason = tostring(rec.statusReason or '')
    if rec.status == 'ok' or (rec.status == 'attention' and reason:sub(1, 7) == 'verify:') then
        setStatus(rec, 'unverified', nil)
    end
end

--- What Verify found, standing in the property: nothing (it is 'ok', and when) or the problems.
--- A problem the reconcile is holding is not overwritten by a clean Verify.
---@param problems string[]
---@return boolean ok, string|nil err
function Properties.setVerified(propertyId, problems)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    if #problems == 0 then
        if rec.status == 'attention' and tostring(rec.statusReason or ''):sub(1, 10) == 'reconcile:' then
            return true
        end
        local ok, err = pcall(MySQL.query.await,
            'UPDATE `properties` SET `status`=\'ok\', `statusReason`=NULL, `verifiedAt`=CURRENT_TIMESTAMP WHERE `propertyId`=?',
            { rec.propertyId })
        if not ok then return false, dbFail('marking the property ok', err) end
        rec.status, rec.statusReason = 'ok', nil
    else
        setStatus(rec, 'attention', 'verify: ' .. table.concat(problems, '; '))
    end
    rec._wire = nil
    announce(rec.propertyId)
    return true
end

--- A unit as its properties see it with no per-property changes: base, with the admin's overlay
--- over it. What Register here and Stamp mode place, and what Export writes.
---@return table|nil unit
function Properties.resolvedUnit(templateId, unitKey)
    return resolveUnit(_templates[tonumber(templateId) or -1], unitKey, nil)
end

--- Give a template the rooms (and fingerprint) of its interior, read by Verify standing in it: the
--- "whole interior" and "these rooms" spaces of every property on it then resolve.
---@return boolean ok, string|nil err
function Properties.setTemplateRooms(templateId, rooms, fingerprint)
    local t = Properties.getTemplate(templateId)
    if not t then return false, 'Unknown template' end
    local saved, err = Properties.saveTemplate({
        templateKey = t.templateKey, source = t.source, label = t.label, archetype = t.archetype,
        archetypeHash = t.archetypeHash, fingerprint = t.fingerprint or fingerprint, rooms = rooms,
        settings = t.settings, packVersion = t.packVersion,
    })
    if not saved then return false, err end
    return true
end

--- Give a template its interior's layout AS IT IS NOW, the rooms and the fingerprint both, over what
--- it had (Re-bind, after an MLO update changed its rooms; setTemplateRooms only fills a template that
--- has none). Every property on the template is re-resolved and goes back to unverified.
---@return boolean ok, string|nil err, number|nil properties  how many are built on it
function Properties.setTemplateLayout(templateId, rooms, fingerprint)
    local t = Properties.getTemplate(templateId)
    if not t then return false, 'Unknown template' end
    local saved, err = Properties.saveTemplate({
        templateKey = t.templateKey, source = t.source, label = t.label, archetype = t.archetype,
        archetypeHash = t.archetypeHash, fingerprint = fingerprint, rooms = rooms,
        settings = t.settings, packVersion = t.packVersion,
    }, { quiet = true })
    if not saved then return false, err end
    local n = 0
    for id, rec in pairs(_records) do
        if rec.templateId == t.templateId then
            Properties.markChanged(id)
            Properties.resync(id)
            n = n + 1
        end
    end
    return true, nil, n
end

--- Re-resolve one property and put everything that follows from it right: its world data, its
--- place in the grid, its doors, its status, and every client's copy.
---@return string[] problems
function Properties.resync(propertyId)
    local rec = _records[tonumber(propertyId) or -1]
    if not rec then return { 'unknown property' } end
    derive(rec)
    gridInsert(rec)
    local problems = syncDoors(rec)
    for _, p in ipairs(syncGarage(rec)) do problems[#problems + 1] = p end
    applyProblems(rec, problems)
    announce(rec.propertyId)
    -- Its stashes where its furniture is (a placement that moved moves them); writes only what moved.
    -- In a thread: a resync must not wait on a stash's write.
    if PropertyStashes and PropertyObjects then
        CreateThread(function() PropertyStashes.follow(Properties.get(rec.propertyId)) end)
    end
    return problems
end

-- ============================================
-- Loading and the boot reconcile
-- ============================================

function Properties.loadAll()
    Properties.ensureTables()

    _templates, _records, _keys, _grid, _cellsOf = {}, {}, {}, {}, {}

    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `property_templates`', {})
    -- Every failure answers false and start-up halts BEFORE reconcile, which reads an empty
    -- `_records` as "every property is gone" and deletes their garages.
    if not ok then log('ERROR loading templates: %s', tostring(rows)); return false end
    for _, row in ipairs(rows or {}) do _templates[row.templateId] = rowToTemplate(row) end

    ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `property_template_units`', {})
    if not ok then log('ERROR loading units: %s', tostring(rows)); return false end
    for _, row in ipairs(rows or {}) do
        local t = _templates[row.templateId]
        if t then t.units[row.unitKey] = rowToUnit(row) end
    end

    -- Keys before properties: the access list a property writes on its doors reads them.
    ok, rows = pcall(MySQL.query.await, 'SELECT `propertyId`, `charId` FROM `property_keys`', {})
    if not ok then log('ERROR loading keys: %s', tostring(rows)); return false end
    for _, r in ipairs(rows or {}) do
        local list = _keys[r.propertyId]
        if not list then list = {}; _keys[r.propertyId] = list end
        list[#list + 1] = r.charId
    end

    ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `properties` WHERE `deletedAt` IS NULL', {})
    if not ok then log('ERROR loading properties: %s', tostring(rows)); return false end
    local n = 0
    for _, row in ipairs(rows or {}) do
        local rec = rowToRecord(row)
        derive(rec)
        _records[rec.propertyId] = rec
        gridInsert(rec)
        n = n + 1
    end

    local tn = 0
    for _ in pairs(_templates) do tn = tn + 1 end
    log('%d propert%s from %d template%s', n, n == 1 and 'y' or 'ies', tn, tn == 1 and '' or 's')
end

--- Put every property's doors in step with it, once, at boot. After Doors.loadAll.
---
--- Idempotent: a property whose doors already say the right thing writes nothing. Anything it
--- cannot put right becomes 'attention' with the reason, rather than a line in the console.
---
--- Also releases orphans: a door still marked as a property's after that property has gone (a
--- delete that failed half-way) is given back, so it cannot stay locked to nobody forever.
function Properties.reconcile()
    local attention = 0
    for _, rec in pairs(_records) do
        local problems = syncDoors(rec)
        for _, p in ipairs(syncGarage(rec)) do problems[#problems + 1] = p end
        applyProblems(rec, problems)
        if rec.status == 'attention' then attention = attention + 1 end
    end
    -- A property garage whose property is gone (a delete that failed half-way): its cars go to a
    -- public garage, and the garage with its bays is removed.
    for key in pairs(Garages.getAll()) do
        local id = key:sub(1, #GARAGE_PREFIX) == GARAGE_PREFIX and tonumber(key:sub(#GARAGE_PREFIX + 1))
        if id and not _records[id] then
            Garages.evict(key, true)
            Garages.delete(key)
            log('removed garage "%s": its property no longer exists', key)
        end
    end
    for _, door in ipairs(Doors.listManaged(DOOR_SYSTEM)) do
        local mb = Doors.managerOf(door)
        if mb and not _records[tonumber(mb.id) or -1] then
            local released, err = Doors.release(door.doorId, mb)
            if released then
                log('released door #%d: its property #%s no longer exists', door.doorId, tostring(mb.id))
            else
                log('could not release orphaned door #%d: %s', door.doorId, tostring(err))
            end
        end
    end
    if attention > 0 then
        log('%d propert%s need attention — see the Properties panel', attention, attention == 1 and 'y' or 'ies')
    end
end

-- ============================================
-- Writes
-- ============================================

local function validPlace(p)
    return type(p) == 'table' and finite(tonumber(p.x)) and finite(tonumber(p.y))
        and finite(tonumber(p.z)) and finite(tonumber(p.yaw or 0))
end

--- Create one property.
---
--- `spec` = { templateId, unitKey, place = { hash?, x, y, z, yaw }, name?, label?, building?,
---            settings?, overrides?, ownerCharId?, propertyKey?, source? }
---@return table|nil record, string|nil err
function Properties.create(spec, byCharId)
    if type(spec) ~= 'table' then return nil, 'Expected a table' end
    local t = Properties.getTemplate(spec.templateId)
    if not t then return nil, 'Unknown template' end
    if not t.units[spec.unitKey] then return nil, ('Template #%d has no unit "%s"'):format(t.templateId, tostring(spec.unitKey)) end
    if not validPlace(spec.place) then return nil, 'A property needs a placement { x, y, z, yaw }' end

    local p = spec.place
    local place = {
        hash = PropertyMath.signedHash(p.hash or t.archetypeHash) or 0,
        x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z), yaw = tonumber(p.yaw or 0) % 360.0,
    }
    local name = tostring(spec.name or t.units[spec.unitKey].label or 'Property'):sub(1, 100)

    local ok, id = pcall(MySQL.insert.await,
        'INSERT INTO `properties` (`propertyKey`,`source`,`name`,`label`,`building`,`templateId`,`unitKey`,'
        .. '`archetypeHash`,`px`,`py`,`pz`,`yaw`,`overrides`,`settings`,`ownerCharId`,`createdBy`) '
        .. 'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        {
            spec.propertyKey, spec.source or 'admin', name,
            spec.label and tostring(spec.label):sub(1, 60) or nil,
            spec.building and tostring(spec.building):sub(1, 100) or nil,
            t.templateId, spec.unitKey, place.hash, place.x, place.y, place.z, place.yaw,
            encode(spec.overrides), encode(spec.settings or {}), spec.ownerCharId, byCharId,
        })
    if not ok or not id then return nil, dbFail('creating the property', id) end

    local rec = rowToRecord({
        propertyId = id, propertyKey = spec.propertyKey, source = spec.source or 'admin', name = name,
        label = spec.label, building = spec.building, templateId = t.templateId, unitKey = spec.unitKey,
        archetypeHash = place.hash, px = place.x, py = place.y, pz = place.z, yaw = place.yaw,
        overrides = encode(spec.overrides), settings = encode(spec.settings or {}),
        ownerCharId = spec.ownerCharId, createdBy = byCharId,
    })
    _records[id] = rec
    Properties.resync(id)
    return rec
end

--- The row fields update() may change, and how each is written.
local UPDATABLE = {
    name      = function(v) return 'name', tostring(v):sub(1, 100) end,
    label     = function(v) return 'label', v ~= false and tostring(v):sub(1, 60) or nil end,
    building  = function(v) return 'building', v ~= false and tostring(v):sub(1, 100) or nil end,
    settings  = function(v) return 'settings', encode(v) end,
    overrides = function(v) return 'overrides', v ~= false and encode(v) or nil end,
}

--- Change a property's name, label, building, settings or overrides; `place` moves it (Re-bind).
---
--- Row first, memory second: the write lands, then the record believes it. `false` clears a
--- label, building or the overrides. `settings` replaces the property's own settings whole.
---@return boolean ok, string|nil err
function Properties.update(propertyId, fields)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    if type(fields) ~= 'table' then return false, 'Expected a table' end

    local sets, values, staged = {}, {}, {}
    for k, v in pairs(fields) do
        if UPDATABLE[k] then
            local col, val = UPDATABLE[k](v)
            -- A cleared field is written as a literal NULL, as Vehicles.persist does: `values[#values
            -- + 1] = nil` adds nothing, and every value after it would slide one place left.
            if val == nil then
                sets[#sets + 1] = ('`%s`=NULL'):format(col)
            else
                sets[#sets + 1] = ('`%s`=?'):format(col)
                values[#values + 1] = val
            end
            staged[k] = v ~= false and v or nil
        elseif k == 'place' then
            if not validPlace(v) then return false, 'Bad placement' end
            local hash = PropertyMath.signedHash(v.hash or rec.place.hash) or 0
            local place = { hash = hash, x = tonumber(v.x), y = tonumber(v.y), z = tonumber(v.z),
                            yaw = tonumber(v.yaw or 0) % 360.0 }
            for _, pair in ipairs({ { 'archetypeHash', hash }, { 'px', place.x }, { 'py', place.y },
                                    { 'pz', place.z }, { 'yaw', place.yaw } }) do
                sets[#sets + 1] = ('`%s`=?'):format(pair[1])
                values[#values + 1] = pair[2]
            end
            staged.place = place
        elseif k == 'unit' then
            -- Which unit of which template this property is: a pack moving it, or Re-bind onto a
            -- different template.
            local t = type(v) == 'table' and Properties.getTemplate(v.templateId)
            if not t or not t.units[v.unitKey] then return false, 'Unknown template or unit' end
            sets[#sets + 1] = '`templateId`=?'; values[#values + 1] = t.templateId
            sets[#sets + 1] = '`unitKey`=?';    values[#values + 1] = v.unitKey
            staged.templateId, staged.unitKey = t.templateId, v.unitKey
        else
            return false, ('"%s" is not a property field that can be changed'):format(tostring(k))
        end
    end
    if #sets == 0 then return true end

    values[#values + 1] = rec.propertyId
    local ok, err = pcall(MySQL.query.await,
        ('UPDATE `properties` SET %s WHERE `propertyId`=?'):format(table.concat(sets, ', ')), values)
    if not ok then return false, dbFail('updating the property', err) end

    for k, v in pairs(staged) do rec[k] = v end
    if fields.label == false then rec.label = nil end
    if fields.building == false then rec.building = nil end
    if fields.overrides == false then rec.overrides = nil end
    if fields.settings ~= nil and type(rec.settings) ~= 'table' then rec.settings = {} end

    -- Moved, or its parts changed: Verify has to look again.
    if fields.place ~= nil or fields.unit ~= nil or fields.overrides ~= nil then Properties.markChanged(rec.propertyId) end
    Properties.resync(rec.propertyId)
    return true
end

--- A pack takes over an admin's property: same interior, same placement, same flat. It becomes
--- the pack's (its key and source), on the pack's template and unit, and keeps everything that
--- was its own — owner, keys, furniture, settings. See PropertyPacks, "CLAIMED".
---@return boolean ok, string|nil err
function Properties.claim(propertyId, propertyKey, source, templateId, unitKey, place)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local t = Properties.getTemplate(templateId)
    if not t or not t.units[unitKey] then return false, 'Unknown template or unit' end
    local ok, err = pcall(MySQL.query.await,
        'UPDATE `properties` SET `propertyKey`=?, `source`=?, `templateId`=?, `unitKey`=?, `archetypeHash`=?, '
        .. '`px`=?, `py`=?, `pz`=?, `yaw`=? WHERE `propertyId`=?',
        { propertyKey, source, t.templateId, unitKey, place.hash or t.archetypeHash, place.x, place.y, place.z,
          (place.yaw or 0) % 360.0, rec.propertyId })
    if not ok then return false, dbFail('moving the property', err) end
    rec.propertyKey, rec.source, rec.templateId, rec.unitKey = propertyKey, source, t.templateId, unitKey
    rec.place = { hash = place.hash or t.archetypeHash, x = place.x, y = place.y, z = place.z, yaw = (place.yaw or 0) % 360.0 }
    Properties.resync(rec.propertyId)
    return true
end

--- A pack property's state: open or closed (its resource running or not), and what an admin
--- should know about it ('orphaned: ...', 'conflict: ...'). Worked out at every pack apply, so it
--- is held in memory rather than written.
function Properties.setPackState(propertyId, active, issue)
    local rec = Properties.get(propertyId)
    if not rec then return end
    local changed = rec.active ~= (active ~= false) or rec.packIssue ~= issue
    rec.active = active ~= false
    rec.packIssue = issue
    if changed then
        rec._wire = nil
        announce(rec.propertyId)
    end
end

--- Make a pack's property an admin's: it stops following its pack (which had dropped it, or which
--- the admin no longer wants in charge of it). Owner, keys, furniture and its template all stay.
---@return boolean ok, string|nil err
function Properties.adopt(propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    if rec.source == 'admin' then return true end
    local ok, err = pcall(MySQL.query.await,
        'UPDATE `properties` SET `source`=\'admin\', `propertyKey`=NULL WHERE `propertyId`=?', { rec.propertyId })
    if not ok then return false, dbFail('adopting the property', err) end
    rec.source, rec.propertyKey = 'admin', nil
    Properties.setPackState(rec.propertyId, true, nil)
    announce(rec.propertyId)
    return true
end

--- Settle a conflict between a pack's update and an admin's change to the same unit part.
---
---   'keep'  the admin's version stays in force; the flag goes
---   'pack'  the admin's change to those parts is dropped, so the pack's new base applies
---
--- Per UNIT, so it settles it for every property built on that unit at once.
---@return boolean ok, string|nil err
function Properties.resolveConflict(templateId, unitKey, mode)
    local t = Properties.getTemplate(templateId)
    local u = t and t.units[unitKey]
    if not t or not u then return false, 'Unknown unit' end
    local overlay = u.overlay
    local conflicts = overlay and overlay._conflicts
    if not conflicts then return true end
    local new = {}
    for k, v in pairs(overlay) do
        if k ~= '_conflicts' and not (mode == 'pack' and conflicts[k]) then new[k] = v end
    end
    local saved, err = Properties.saveUnit(t.templateId, unitKey,
        { label = u.label, sortOrder = u.sortOrder, base = u.base, overlay = next(new) and new or false })
    if not saved then return false, err end
    for id, rec in pairs(_records) do
        if rec.templateId == t.templateId and rec.unitKey == unitKey then
            Properties.setPackState(id, rec.active, nil)
        end
    end
    return true
end

--- How many properties are built on one unit — the "all N" of a shared unit's edit.
---@return number
function Properties.unitUses(templateId, unitKey)
    local n = 0
    for _, rec in pairs(_records) do
        if rec.templateId == templateId and rec.unitKey == unitKey then n = n + 1 end
    end
    return n
end

--- The parts setPart may change.
local SETTABLE_PARTS = { space = true, doors = true, sign = true, manager = true, visit = true, garage = true }

--- Set one part of a property — its space, doors, either sign, where to stand inside, or its
--- garage — for this property alone ('property': an override), or for every property built on the
--- same unit ('unit': the unit's admin overlay). Either way it wins over what a pack said, and a
--- pack update does not move it.
---
--- Setting it for the unit also takes this property's own override for that part away, so it
--- follows the unit like the rest.
---@param part string        'space' | 'doors' | 'sign' | 'manager' | 'visit' | 'garage'
---@param value table|false  the part, checked (PropertyValidate.partOf), in the interior's own
---                          space; false for none (a garage taken away)
---@param scope string       'property' | 'unit'
---@return boolean ok, string|nil err
function Properties.setPart(propertyId, part, value, scope)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    if not SETTABLE_PARTS[part] then return false, 'That part cannot be set here' end

    local function copy(t)
        local out = {}
        for k, v in pairs(t or {}) do out[k] = v end
        return out
    end

    if scope == 'unit' then
        local t = Properties.getTemplate(rec.templateId)
        local u = t and t.units[rec.unitKey]
        if not t or not u then return false, 'Its unit is missing from its template' end
        if rec.overrides and rec.overrides[part] ~= nil then
            local o = copy(rec.overrides)
            o[part] = nil
            local ok, err = Properties.update(rec.propertyId, { overrides = next(o) and o or false })
            if not ok then return false, err end
        end
        local overlay = copy(u.overlay)
        overlay[part] = value
        local saved, err = Properties.saveUnit(t.templateId, rec.unitKey,
            { label = u.label, sortOrder = u.sortOrder, base = u.base, overlay = overlay })
        if not saved then return false, err end
        return true
    end

    local o = copy(rec.overrides)
    o[part] = value
    return Properties.update(rec.propertyId, { overrides = o })
end

--- Open or close every property from one source (a pack whose resource started or stopped).
function Properties.setPackStateBySource(source, active)
    for id, rec in pairs(_records) do
        if rec.source == source then Properties.setPackState(id, active, rec.packIssue) end
    end
end

--- Delete a property: its doors released, its keys gone, every client told. (Properties.delete, below, runs it in
--- the property's turn.)
---
--- A pack's property is tombstoned, not deleted: the pack would otherwise make it again at the
--- next start. An admin's is deleted outright, and its keys go with it (the foreign key).
---@return boolean ok, string|nil err
local function deleteNow(propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end

    -- The keys and the furniture go in the same transaction as the row (the foreign keys would
    -- take them too, but a tombstone deletes nothing for a foreign key to follow).
    local queries = {
        { query = 'DELETE FROM `property_keys` WHERE `propertyId`=?',    values = { rec.propertyId } },
        { query = 'DELETE FROM `property_objects` WHERE `propertyId`=?', values = { rec.propertyId } },
    }
    if rec.source == 'admin' then
        queries[#queries + 1] = { query = 'DELETE FROM `properties` WHERE `propertyId`=?', values = { rec.propertyId } }
    else
        queries[#queries + 1] = {
            query = 'UPDATE `properties` SET `deletedAt`=CURRENT_TIMESTAMP, `ownerCharId`=NULL WHERE `propertyId`=?',
            values = { rec.propertyId },
        }
    end
    local ok, err = Stores.runTransaction(queries, 'property_delete')
    if not ok then return false, dbFail('deleting the property', err) end
    if PropertyObjects then PropertyObjects.forget(rec.propertyId) end
    -- Its stashes go with their furniture, what they held written down as lost (server/property_stashes.lua).
    if PropertyStashes then PropertyStashes.removeAll(rec.propertyId) end

    -- Doors after the row: a door released for a property that then failed to delete would be a
    -- property with no way in. The boot reconcile releases anything this misses.
    for _, door in ipairs(Doors.listManaged(DOOR_SYSTEM, rec.propertyId)) do
        Doors.release(door.doorId, managerFor(rec))
    end
    -- Its garage too, the cars in it moved to a public garage first. (The boot reconcile removes a
    -- garage this misses.)
    local garageKey = garageKeyOf(rec.propertyId)
    if Garages.get(garageKey) then
        Garages.evict(garageKey, true)
        Garages.delete(garageKey)
    end

    _records[rec.propertyId] = nil
    _keys[rec.propertyId] = nil
    gridRemove(rec.propertyId)
    announce(rec.propertyId)
    return true
end

-- ============================================
-- Ownership and keys
-- ============================================
--
-- A key is the owner's to give, face to face, and it is "the same as me" for everything the doors
-- govern. It is not ownership: a keyholder cannot hand out keys, sell or furnish. And a key cannot
-- outlive the owner who gave it — a change of owner takes every key back.

--- The properties a character holds a key to.
local function keyedBy(charId)
    local ids = {}
    for id, list in pairs(_keys) do
        for _, c in ipairs(list) do
            if c == charId then ids[#ids + 1] = id break end
        end
    end
    table.sort(ids)
    return ids
end

--- Tell a character's client which properties it holds a key to — the only per-player thing a
--- property sends, because it decides whether they see a property's manager sign (owners are on
--- the wire already). Sent at login and whenever one of their keys comes or goes.
function Properties.pushKeys(charId)
    local p = charId and PlayersByCharId and PlayersByCharId[charId]
    if p and p.source then
        TriggerClientEvent('whip_core:client:propertyKeysMine', p.source, keyedBy(charId))
    end
end

--- The same, at login, by server id.
function Properties.syncKeys(source)
    local p = Players[source]
    if p and p.charId then
        TriggerClientEvent('whip_core:client:propertyKeysMine', source, keyedBy(p.charId))
    end
end

--- Is this a character that exists and has not been deleted? Online is asked of memory; anyone else
--- of the database. The one check for every way a property or key is handed over (panel and
--- exports alike), so a stale charId can't give a home to a deleted character.
---@param charId number
---@return boolean
function Properties.characterLive(charId)
    if PlayersByCharId and PlayersByCharId[charId] then return true end
    local ok, n = pcall(MySQL.scalar.await,
        'SELECT COUNT(*) FROM `characters` WHERE `charId`=? AND `deleted` IS NULL', { charId })
    return ok and (tonumber(n) or 0) > 0
end

--- Give a property to a character, or take it away (charId nil).
---
--- A new owner starts with no guests, and a locked door: the keys were the last owner's to give, and
--- a door the last owner left open would otherwise stay open to everyone.
---
--- Written with the action it is part of: `src`, the player whose action this is (a purchase), so a
--- payment held on it lands in the same transaction. Outside any action, alone.
---@param src number|nil
---@return boolean ok, string|nil err
local function setOwnerNow(propertyId, charId, byCharId, src, ownerAtCall)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    -- Still the owner the caller saw: the turn only queues, so whoever was the owner when setOwner was
    -- called must still be the owner now, or nothing is written.
    if rec.ownerCharId ~= ownerAtCall then
        return false, 'The property changed hands while this was waiting. Try again.'
    end
    charId = tonumber(charId)
    if charId and charId <= 0 then charId = nil end
    local previous = rec.ownerCharId
    if previous == charId then return true end
    if charId and not Properties.characterLive(charId) then
        return false, ('There is no character #%d'):format(charId)
    end
    if Properties.get(propertyId) ~= rec then return false, 'Unknown property' end   -- (the check waited)
    -- And still the owner it was: characterLive can wait on the database, and another hand-over in that
    -- wait would leave `previous` wrong. Refused, as a changed grant is.
    if rec.ownerCharId ~= previous then
        return false, 'The property changed hands while this was being checked. Try again.'
    end
    local formerKeys = Properties.keysFor(rec.propertyId)

    local ok, err = Stores.commitWithAction({
        { query = 'UPDATE `properties` SET `ownerCharId`=? WHERE `propertyId`=?', values = { charId, rec.propertyId } },
        { query = 'DELETE FROM `property_keys` WHERE `propertyId`=?', values = { rec.propertyId } },
    }, 'property_owner', nil, src)
    if not ok then return false, dbFail('changing the owner', err) end

    rec.ownerCharId = charId
    _keys[rec.propertyId] = nil

    -- Written, so it happened. What follows tells the world (doors, garages, keys, the event), and an
    -- error in it must not read as a failed hand-over (a purchase would refund). Each step in its own
    -- pcall, said in the console; the answer is true.
    local function tail(what, fn, ...)
        local ran, failure = pcall(fn, ...)
        if not ran then
            print(('[whip_core:properties] property %d changed hands, but %s failed: %s')
                :format(rec.propertyId, what, tostring(failure)))
        end
    end
    tail('the resync', Properties.resync, rec.propertyId)
    tail('locking its doors', lockDoors, rec)
    for _, c in ipairs(formerKeys) do tail('pushing a former keyholder\'s keys', Properties.pushKeys, c) end
    -- The old owner and every former keyholder lose the garage; the new owner gains it.
    local changed = {}
    if previous then changed[#changed + 1] = previous end
    if charId then changed[#changed + 1] = charId end
    for _, c in ipairs(formerKeys) do changed[#changed + 1] = c end
    tail('the garage access change', accessChanged, rec, changed)

    tail('the ownerChanged event', WhipEmit, 'whip_core:property:ownerChanged', {
        propertyId = rec.propertyId, ownerCharId = charId, previousOwnerCharId = previous, by = byCharId,
    })
    return true
end

--- Give a character a key.
---@return boolean ok, string|nil err
local function grantKeyNow(propertyId, charId, byCharId, ownerAtCall)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    -- The owner as the caller saw it, read BEFORE the turn's wait (the caller passes it in).
    -- characterLive below can wait on the database too; the check after the INSERT compares against
    -- the same owner.
    local ownerAtStart = ownerAtCall
    if rec.ownerCharId ~= ownerAtStart then return false, 'The property changed hands — nothing was given' end
    charId = tonumber(charId)
    if not charId then return false, 'Unknown character' end
    if rec.ownerCharId == charId then return false, 'They already own this property' end
    if Properties.hasKey(propertyId, charId) then return false, 'They already have a key' end
    if not Properties.characterLive(charId) then   -- see Properties.characterLive
        return false, ('There is no character #%d'):format(charId)
    end

    local ok, err = pcall(MySQL.insert.await,
        'INSERT INTO `property_keys` (`propertyId`, `charId`, `grantedBy`) VALUES (?, ?, ?)',
        { rec.propertyId, charId, byCharId })
    if not ok then return false, dbFail('giving the key', err) end

    -- Sold during those waits? setOwner deletes every key, and the INSERT above can land after its
    -- DELETE: the row just written goes again, and the grant is refused. Or deleted (a delete only
    -- drops the record, never touching rec.ownerCharId).
    if rec.ownerCharId ~= ownerAtStart or Properties.get(rec.propertyId) ~= rec then
        pcall(MySQL.query.await, 'DELETE FROM `property_keys` WHERE `propertyId`=? AND `charId`=?',
            { rec.propertyId, charId })
        return false, Properties.get(rec.propertyId) ~= rec and 'The property is gone — nothing was given'
            or 'The property changed hands — nothing was given'
    end

    local list = _keys[rec.propertyId]
    if not list then list = {}; _keys[rec.propertyId] = list end
    list[#list + 1] = charId

    local problems = syncDoors(rec)
    applyProblems(rec, problems)
    Properties.pushKeys(charId)
    accessChanged(rec, { charId })
    if PropertyAdmin then PropertyAdmin.changed(rec.propertyId) end
    WhipEmit('whip_core:property:keyGranted', { propertyId = rec.propertyId, charId = charId, by = byCharId })
    -- The key is given, so the answer is true. A door that did not update is the property's problem
    -- (applyProblems marked it 'attention' for the admin panel), not a failed grant.
    if #problems > 0 then
        log('key given to %s for property #%d, but a door did not update: %s', tostring(charId), rec.propertyId, problems[1])
    end
    return true
end

--- Take a key back.
---@return boolean ok, string|nil err
local function revokeKeyNow(propertyId, charId, ownerAtCall)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    -- The owner the caller saw: a revoke queued behind a hand-over is not the new owner's.
    if rec.ownerCharId ~= ownerAtCall then return false, 'The property changed hands — nothing was taken back' end
    charId = tonumber(charId)
    -- A key they never had is not taken back (no relock, no keyRevoked, no message).
    if not charId or not Properties.hasKey(propertyId, charId) then
        return false, 'They do not have a key'
    end

    local ok, err = pcall(MySQL.query.await,
        'DELETE FROM `property_keys` WHERE `propertyId`=? AND `charId`=?', { rec.propertyId, charId })
    if not ok then return false, dbFail('taking the key back', err) end

    local list = _keys[rec.propertyId]
    if list then
        for i = #list, 1, -1 do if list[i] == charId then table.remove(list, i) end end
    end

    -- The one that matters: a door still carrying the key would let them in.
    local problems = syncDoors(rec)
    applyProblems(rec, problems)
    -- And locked, as a change of owner locks them: rewriting who may open a door does not close one
    -- left open.
    lockDoors(rec)
    Properties.pushKeys(charId)
    -- Their car in its garage goes to a public one: they could never take it out again.
    accessChanged(rec, { charId })
    if PropertyAdmin then PropertyAdmin.changed(rec.propertyId) end
    WhipEmit('whip_core:property:keyRevoked', { propertyId = rec.propertyId, charId = charId })
    -- Taken back, so true (as grantKey). The door that has not caught up is marked for the admin.
    if #problems > 0 then
        log('key taken from %s for property #%d, but a door did not update yet: %s', tostring(charId), rec.propertyId, problems[1])
    end
    return true
end

-- One change of who may use a property at a time: owner and key changes take a turn per property
-- (Shops.update's rule), so a sale at the sign and an admin's hand-over can't both write. A second
-- waits for the first, a few seconds at most.
--
-- The turn only queues; the owner is compared. Each of these reads the owner when it is CALLED,
-- before waiting, and refuses inside the turn if it changed: the caller's checks ("for sale", "you
-- own it") were made against that owner. A delete takes the same turn.
local propertyTurn = {}   -- [propertyId] = true while one of these runs for it
local PROPERTY_TURN_MS = 5000

local function inPropertyTurn(propertyId, fn, ...)
    local key = tonumber(propertyId) or propertyId
    local deadline = GetGameTimer() + PROPERTY_TURN_MS
    while propertyTurn[key] do
        if GetGameTimer() > deadline then return false, 'That property is being changed — try again in a moment' end
        Wait(20)
    end
    propertyTurn[key] = true
    local ran, ok, why = pcall(fn, ...)
    propertyTurn[key] = nil
    if not ran then error(ok, 0) end
    return ok, why
end

--- The owner now, read before the turn's wait (see above). nil: no owner, or no such property.
local function ownerNow(propertyId)
    local rec = Properties.get(propertyId)
    return rec and rec.ownerCharId or nil
end

--- Give a property to a character, or take it away (charId nil): see setOwnerNow. In the property's turn,
--- and refused if the owner changes while it waits for it.
---@param src number|nil  the player whose action this is (a purchase: its held payment rides the write)
---@return boolean ok, string|nil err
function Properties.setOwner(propertyId, charId, byCharId, src)
    return inPropertyTurn(propertyId, setOwnerNow, propertyId, charId, byCharId, src, ownerNow(propertyId))
end

--- Give a character a key: see grantKeyNow. In the property's turn, refused if the owner changes meanwhile.
---@return boolean ok, string|nil err
function Properties.grantKey(propertyId, charId, byCharId)
    return inPropertyTurn(propertyId, grantKeyNow, propertyId, charId, byCharId, ownerNow(propertyId))
end

--- Take a key back: see revokeKeyNow. In the property's turn, refused if the owner changes meanwhile.
---@return boolean ok, string|nil err
function Properties.revokeKey(propertyId, charId)
    return inPropertyTurn(propertyId, revokeKeyNow, propertyId, charId, ownerNow(propertyId))
end

--- Delete a property: see deleteNow. In the property's turn, so a sale or a hand-over waiting
--- on it finds the property gone, not half deleted.
---@return boolean ok, string|nil err
function Properties.delete(propertyId)
    return inPropertyTurn(propertyId, deleteNow, propertyId)
end

--- A deleted character loses every key and every property it held — and a property it OWNED loses
--- every key anyone held to it, since only an owner hands keys out.
---
--- All of it in the database, not just memory: characters are soft-deleted, so the foreign keys
--- never fire and these statements are the only thing that removes the rows.
---
--- A hook, not a handler: the delete runs it, so firing the public `whip_core:character:deleted`
--- event can't strip a live character of their home.
Character.onLife('deleted', function(payload)
    local charId = type(payload) == 'table' and tonumber(payload.charId) or nil
    if not charId then return end

    -- Keys to its properties first — the join needs `ownerCharId` before it is cleared.
    -- One transaction, and memory only once it lands: a failure changes nothing, and
    -- Character.reconcileDeleted runs this again at the next start.
    local ok, err = Stores.runTransaction({
        { query = [[
            DELETE pk FROM `property_keys` pk
            JOIN `properties` p ON p.`propertyId` = pk.`propertyId`
            WHERE p.`ownerCharId` = ?
        ]], values = { charId } },
        { query = 'DELETE FROM `property_keys` WHERE `charId`=?', values = { charId } },
        { query = 'UPDATE `properties` SET `ownerCharId`=NULL WHERE `ownerCharId`=?', values = { charId } },
    }, 'property_release')
    if not ok then
        log('ERROR releasing deleted character %d\'s homes and keys (%s) — nothing changed; retried at the next start',
            charId, tostring(err))
        return
    end

    for id, rec in pairs(_records) do
        local touched = false
        local lost = { charId }   -- everyone whose access changes, for accessChanged
        local list = _keys[id]
        if list then
            for i = #list, 1, -1 do
                if list[i] == charId then table.remove(list, i); touched = true end
            end
        end
        if rec.ownerCharId == charId then
            rec.ownerCharId = nil
            for _, holder in ipairs(_keys[id] or {}) do lost[#lost + 1] = holder end
            _keys[id] = nil
            touched = true
        end
        if touched then
            Properties.resync(id)
            lockDoors(rec)
            accessChanged(rec, lost)
        end
    end
end)

-- ============================================
-- Key events
-- ============================================
--
-- Owner-only, checked here: a key is full access to somebody's home, so only the person whose
-- home it is may hand one out. There is no admin bypass on these; admins grant from the panel.

--- Who can get in, and who is standing here to be let in, for the owner's key menu.
SecureCallback('whip_core:property:keyInfo', {
    rateLimit = 500,
    params = { {'propertyId', 'id'} },
}, function(source, player, propertyId)
    local rec = Properties.get(propertyId)
    -- `false, why`, whip's refusal
    if not rec then return false, 'Unknown property' end
    if rec.ownerCharId ~= player.charId then return false, 'That is not your property' end

    local range = Config.PropertyKeyGrantRange or 5.0
    local pc = GetEntityCoords(GetPlayerPed(source))
    local myBucket = GetPlayerRoutingBucket(source)

    -- Who is standing here, by the name rule every other lookup follows: same bucket, not in the
    -- creator, a server id to grant to, and a name only when the one name rule gives one
    -- (MayKnowName, server/helpers.lua).
    local nearby, nearbyChar = {}, {}
    for src, p in pairs(Players) do
        if src ~= source and p.charId and p.charId ~= rec.ownerCharId and not p._inCreator and not p.closing
            and GetPlayerRoutingBucket(src) == myBucket
            and not Properties.hasKey(propertyId, p.charId) then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                local dx, dy, dz = c.x - pc.x, c.y - pc.y, c.z - pc.z
                if (dx * dx + dy * dy + dz * dz) <= range * range then
                    nearby[#nearby + 1] = { serverId = src }
                    nearbyChar[#nearby] = p
                end
            end
        end
    end

    local keyIds = Properties.keysFor(propertyId)
    local names = ResolveCharNames(keyIds) or {}

    local holders = {}
    for _, c in ipairs(keyIds) do
        holders[#holders + 1] = { charId = c, name = names[c] or ('Character #' .. tostring(c)) }
    end
    for i, n in ipairs(nearby) do
        n.name = (MayKnowName(source, n.serverId) and nearbyChar[i].fullName) or ('the person nearby (#%d)'):format(n.serverId)
    end

    return { holders = holders, nearby = nearby }
end)

--- Give the player with this SERVER id a key. A server id names somebody connected; the range
--- check then confirms they are standing here. The client cannot name anyone it could not point at.
SecureEvent('whip_core:server:propertyKeyGrant', {
    rateLimit = 1000,
    params = { {'propertyId', 'id'}, {'targetId', 'id'} },
}, function(source, player, propertyId, targetId)
    -- Refusals are `return false, 'why'`: shown to the player, recorded as a refusal.
    local rec = Properties.get(propertyId)
    if not rec or rec.ownerCharId ~= player.charId then
        return false, 'That is not your property'
    end

    local target = Players[targetId]
    if not target or not target.charId or target._inCreator
        or GetPlayerRoutingBucket(targetId) ~= GetPlayerRoutingBucket(source) then
        return false, 'They are not here'   -- the same "here" the menu uses
    end

    -- Re-checked now, not trusted from the list the menu was drawn with.
    local range = Config.PropertyKeyGrantRange or 5.0
    local pc = GetEntityCoords(GetPlayerPed(source))
    local tc = GetEntityCoords(GetPlayerPed(targetId))
    local dx, dy, dz = tc.x - pc.x, tc.y - pc.y, tc.z - pc.z
    if (dx * dx + dy * dy + dz * dz) > range * range then
        return false, 'They are too far away'
    end

    local ok, err = Properties.grantKey(propertyId, target.charId, player.charId)
    if not ok then
        return false, err or 'Could not give them a key'
    end
    ShowSuccess(source, 'Key given')
    ShowSuccess(targetId,
        ('You have been given a key to %s'):format(rec.name or 'a property'))
end)

--- Take a key back. By charId: a keyholder does not have to be online to lose one.
SecureEvent('whip_core:server:propertyKeyRevoke', {
    rateLimit = 1000,
    params = { {'propertyId', 'id'}, {'charId', 'id'} },
}, function(source, player, propertyId, charId)
    local rec = Properties.get(propertyId)
    if not rec or rec.ownerCharId ~= player.charId then
        return false, 'That is not your property'
    end

    local ok, err = Properties.revokeKey(propertyId, charId)
    if not ok then
        return false, err or 'Could not take the key back'
    end
    ShowSuccess(source, 'Key taken back')
    local target = PlayersByCharId and PlayersByCharId[charId]
    if target and target.source then
        ShowError(target.source,
            ('Your key to %s no longer works'):format(rec.name or 'a property'))
    end
end)

-- ============================================
-- Buying
-- ============================================
--
-- At the outside sign: its name, bays, rooms and price; the price turns into "Purchase?", which asks
-- how to pay: cash, or an account the buyer can pay from (Bank.CanUse withdraw). The server sells it
-- when it can: still for sale, open, priced, the buyer at the sign, the money taken (Money.charge),
-- then theirs (Properties.setOwner: keys cleared, doors locked, the garage theirs). Not enough money:
-- refused, in Money's words. One sale at a time a property.
--
-- The money and the hand-over are one write: the payment is HELD (Money.charge's 'held': taken in
-- memory, not written) and rides setOwner's own transaction (Stores.commitWithAction), so a crash
-- can't keep one without the other. A hand-over that fails lets the held payment go (Money.refund
-- knows which). Once written it is a sale whatever happens after.
--
-- A property with no price (0) is not for sale: its sign names it and offers nothing to buy.

local BUY_RANGE = 6.0   -- metres from the sign the buyer must stand
local buying = {}       -- [propertyId] = true while a sale is under way

--- Its price if it can be bought now, else false and why.
---@return number|false price
---@return string|nil why
local function forSale(rec)
    if not rec then return false, 'Unknown property' end
    if rec.ownerCharId then return false, 'This property has been sold' end
    if rec.active == false then return false, 'This property is closed right now' end
    local price = math.floor(tonumber(rec.effective and rec.effective.price) or 0)
    if price <= 0 then return false, 'This property is not for sale' end
    return price
end

--- Is the player standing at the property's outside sign?
local function atSign(source, rec)
    local s = rec.world and rec.world.sign
    if type(s) ~= 'table' or not s.x then return false end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)
    local dx, dy, dz = c.x - s.x, c.y - s.y, c.z - s.z
    return dx * dx + dy * dy + dz * dz <= BUY_RANGE * BUY_RANGE
end

--- How the buyer could pay, for the sign's menu: the price, the cash on them, and every account they can
--- pay from with its balance. Every one is checked again when they pick it.
SecureCallback('whip_core:property:payOptions', {
    rateLimit = 500,
    params = { {'propertyId', 'id'} },
}, function(source, player, propertyId)
    local rec = Properties.get(propertyId)
    local price, why = forSale(rec)
    -- `false, why`, whip's refusal
    if not price then return false, why or 'Not for sale' end
    if not atSign(source, rec) then return false, 'Stand at the sign to buy it' end
    local cash = player.inventory and Inventory.getItemCountAcrossContainers(player.inventory, 'cash') or 0
    local accounts = {}
    for _, a in ipairs(Bank.GetCharacterAccounts(player.charId) or {}) do
        if not DbBool(a.frozen) and Bank.CanUse(player.charId, a.accountId, 'withdraw') then
            accounts[#accounts + 1] = { accountId = a.accountId, label = a.label, balance = tonumber(a.balance) or 0 }
        end
    end
    return { price = price, cash = cash, accounts = accounts }
end)

--- The sale itself, under the property's lock (below). Answers true, or false and why.
local function sell(source, player, rec, price, method, accountId)
    local name = rec.name or 'a property'
    -- 'held': written with the hand-over below, in one transaction (see "Buying" above)
    local receipt, err = Money.charge(source, price, {
        method = method, accountId = method == 'bank' and accountId or nil, reason = ('Bought %s'):format(name),
    }, GetCurrentResourceName(), nil, 'held')
    if not receipt then return false, err or 'The payment did not go through' end

    -- Taken: still the same property, still for sale (an admin may have handed it over meanwhile)? A
    -- hand-over that throws BEFORE its write is a failed one too, and the money goes back; after it, it
    -- is a sale and the money stays.
    local ok, why
    if Properties.get(rec.propertyId) ~= rec or rec.ownerCharId then
        ok, why = false, 'This property has been sold'
    else
        local ran, a, b = pcall(Properties.setOwner, rec.propertyId, player.charId, player.charId, source)
        if ran then ok, why = a, b else ok, why = false, 'The sale did not go through' end
        if not ran then
            print(('[whip_core:properties] handing over property %d failed: %s'):format(rec.propertyId, tostring(a)))
            if rec.ownerCharId == player.charId then ok, why = true, nil end
        end
    end
    if not ok then
        local back, backErr = Money.refund(receipt, nil, GetCurrentResourceName())
        if not back then
            print(('[whip_core:properties] charId %s paid $%d for property %d, the hand-over failed (%s), and the refund too: %s')
                :format(tostring(player.charId), price, rec.propertyId, tostring(why), tostring(backErr)))
        end
        return false, why or 'The sale did not go through'
    end
    Log.write(player.charId, 'property_bought', {
        amount = price, detail = ('%s (#%d) · %s'):format(name, rec.propertyId, method == 'bank' and ('account ' .. tostring(accountId)) or 'cash'),
    })
    return true
end

--- Buy it: method 'cash', or 'bank' with the account to pay from. Answers { ok } or { ok = false, why }; the
--- buyer is told either way.
SecureCallback('whip_core:property:purchase', {
    rateLimit = 2000,
    params = { {'propertyId', 'id'}, {'method', 'enum', { 'cash', 'bank' }}, {'accountId', 'id', 0} },
}, function(source, player, propertyId, method, accountId)
    local function deny(why)
        ShowError(source, why)
        return { ok = false, why = why }
    end
    local rec = Properties.get(propertyId)
    local price, why = forSale(rec)
    if not price then return deny(why) end
    -- (forSale answers no price for no property.)
    ---@cast rec -nil
    if not atSign(source, rec) then return deny('Stand at the sign to buy it') end
    if method == 'bank' and accountId == 0 then return deny('Pick an account to pay from') end
    if buying[propertyId] then return deny('Someone is buying this property right now') end

    buying[propertyId] = true
    local ran, ok, err = pcall(sell, source, player, rec, price, method, accountId)
    buying[propertyId] = nil
    if not ran then
        print(('[whip_core:properties] buying property %d failed: %s'):format(propertyId, tostring(ok)))
        return deny('The sale did not go through')
    end
    if not ok then return deny(err) end
    ShowSuccess(source, ('%s is yours'):format(rec.name or 'The property'))
    return { ok = true }
end)

-- ============================================
-- Exports
-- ============================================
--
-- Reads hand back COPIES (an export copies anyway, but internal callers get the live record and
-- the wire is what other resources should see). Writes are the ones a satellite legitimately
-- needs: a real-estate script sets owners, a phone app gives keys.

--- A property as a satellite sees it: the wire record, plus the parts only the server knows.
local function exportView(rec)
    if not rec then return nil end
    local w = Properties.wireOne(rec)
    local out = {}
    for k, v in pairs(w) do out[k] = v end
    out.templateId, out.unitKey, out.source = rec.templateId, rec.unitKey, rec.source
    out.propertyKey, out.packIssue = rec.propertyKey, rec.packIssue
    out.status, out.statusReason = rec.status, rec.statusReason
    out.settings = rec.effective
    out.keys = Properties.keysFor(rec.propertyId)
    out.doorIds = rec.doorIds
    return out
end

exports('GetProperty', function(propertyId) return exportView(Properties.get(propertyId)) end)
exports('GetProperties', function() return Properties.wire() end)
exports('GetPropertyAt', function(x, y, z)
    if type(x) == 'table' or type(x) == 'vector3' then x, y, z = x.x, x.y, x.z end
    return exportView(Properties.at(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0))
end)
exports('GetCharacterProperties', function(charId) return Properties.forCharacter(charId) end)
-- The person is `source` or `{ charId = n }` (WhoIs): a bare number is a server id everywhere in whip.

--- May they go in? `true`, or `false, why`, as every access check answers.
exports('HasPropertyAccess', function(propertyId, who)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    if not Properties.get(propertyId) then return false, 'No such property' end
    if Properties.hasAccess(propertyId, charId) then return true end
    return false, 'No key to that property'
end)
--- The owner, or `nil` / `false` for nobody.
exports('SetPropertyOwner', function(propertyId, who)
    if who == nil or who == false then return Properties.setOwner(propertyId, nil) end
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    return Properties.setOwner(propertyId, charId)
end)
exports('GivePropertyKey', function(propertyId, who)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    return Properties.grantKey(propertyId, charId)
end)
exports('RemovePropertyKey', function(propertyId, who)
    local charId, why = WhoIs(who)
    if not charId then return false, why end
    return Properties.revokeKey(propertyId, charId)
end)

-- ============================================
-- Test seams
-- ============================================
--
-- These let whip_test build a fixture in world space and take it down again. Inert unless
-- Config.EnableTestSeams, like every seam in server/testseams.lua.

exports('__TestPropertyFixture', function(spec)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    if type(spec) ~= 'table' then return false, 'spec must be a table' end
    local t, err = Properties.saveTemplate({
        templateKey = spec.templateKey, source = 'test', label = spec.label or '_test template',
        archetypeHash = spec.archetypeHash or 0, rooms = spec.rooms, settings = spec.templateSettings,
    })
    if not t then return false, err end
    for key, unit in pairs(spec.units or {}) do
        local u, uerr = Properties.saveUnit(t.templateId, key, { label = unit.label, base = unit.base })
        if not u then return false, uerr end
    end
    local ids = {}
    for i, p in ipairs(spec.properties or {}) do
        p.templateId = t.templateId
        local rec, perr = Properties.create(p)
        if not rec then return false, perr end
        ids[i] = rec.propertyId
    end
    return { templateId = t.templateId, propertyIds = ids }
end)

exports('__TestPropertyTeardown', function(templateId)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    local t = Properties.getTemplate(templateId)
    if not t then return true end
    for id, rec in pairs(_records) do
        if rec.templateId == t.templateId then Properties.delete(id) end
    end
    -- Tombstoned rows (a non-admin source) still reference the template; take them too.
    pcall(MySQL.query.await, 'DELETE FROM `properties` WHERE `templateId`=?', { t.templateId })
    local ok = pcall(MySQL.query.await, 'DELETE FROM `property_template_units` WHERE `templateId`=?', { t.templateId })
    ok = ok and pcall(MySQL.query.await, 'DELETE FROM `property_templates` WHERE `templateId`=?', { t.templateId })
    if ok then _templates[t.templateId] = nil end
    return ok
end)

exports('__TestPropertyUpdate', function(propertyId, fields)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    return Properties.update(propertyId, fields)
end)

exports('__TestPropertyDelete', function(propertyId)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    return Properties.delete(propertyId)
end)

--- Everything a test run left behind: every template keyed '_test:', made by a '_test' pack, or
--- made by the wizard for a '_test' property (it is labelled after it), and every property on one.
--- A run that crashed never reached its teardown, and its fixture would otherwise sit in the
--- Properties panel and be in the way of the next run's.
exports('__TestPropertySweep', function()
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    local swept = 0
    for tid, t in pairs(_templates) do
        local key, src = tostring(t.templateKey or ''), tostring(t.source or '')
        if key:sub(1, 6) == '_test:' or src:sub(1, 10) == 'pack:_test' or src == 'test'
            or (src == 'admin' and tostring(t.label or ''):sub(1, 5) == '_test') then
            for id, rec in pairs(_records) do
                if rec.templateId == tid then
                    if Properties.delete(id) then swept = swept + 1 end
                end
            end
            pcall(MySQL.query.await, 'DELETE FROM `properties` WHERE `templateId`=?', { tid })
            pcall(MySQL.query.await, 'DELETE FROM `property_template_units` WHERE `templateId`=?', { tid })
            if pcall(MySQL.query.await, 'DELETE FROM `property_templates` WHERE `templateId`=?', { tid }) then
                _templates[tid] = nil
            end
        end
    end
    pcall(MySQL.query.await, "DELETE FROM `property_packs` WHERE `packId` LIKE '\\_test%'")
    return true, swept
end)
