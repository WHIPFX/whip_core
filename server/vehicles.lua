-- Vehicles: persistent ownership, storage, stats, garage and mod persistence (MySQL).

Vehicles = {}

local function heldBy(def)
    local by = def.reservation
    if by and Registry.alive(by) then return by end
    return nil
end

--- Every vehicle whip knows about, keyed by id. Private: read it through `Vehicles.context` (a
--- copy), write it through `Vehicles.persist` (the only database writer). Used directly only
--- inside this file.
Vehicles._records    = {}   -- [vehicleId] = vehicle record
Vehicles.invCache    = {}   -- [vehicleId] = { trunk = {}, glovebox = {} }  (on-demand)
-- Who has a compartment open lives in Stores._views ('vehicle:<id>:<compartment>').
Vehicles._transitionLocks = {}   -- [vehicleId] = true — prevents double retrieve/store
Vehicles.metaCache   = {}   -- [model] = { trunkSlots, trunkMaxWeight, gloveboxSlots, gloveboxMaxWeight, hasTrunk, hasGlovebox }
Vehicles.classMetaCache = {}   -- [GTA vehicle class] = the same, for every model of that category

-- Entities: the server creates each one (Vehicles.spawn), so it knows the handle on the same line.
Vehicles._entities        = {}   -- [vehicleId] = serverEntityHandle
Vehicles._byEntity        = {}   -- [serverEntityHandle] = vehicleId, the same bindings backwards; setTracked writes both — and getTrackedVehicleIdForEntity repairs a missed entry, loudly, when the fingerprint vouches for it
Vehicles._fingerprint     = {}   -- [vehicleId] = { netId, model } of that entity, set where it is bound; see getEntity
-- Synthetic ids for street cars whip adopts, counting up from here: a billion, far above any
-- auto-increment an owned car will reach, and still inside every column and param.
Vehicles._sessionVehicleCounter = 1000000000

-- The only ids a stamp may claim. A stamp is a statebag a client can write, and an absurd number (1e300, math.huge)
-- would hang the session-id allocation loop. An id is a whole number from 1 to VEHICLE_ID_MAX; a street car of a
-- previous run is within SESSION_ID_WINDOW of the start.
local VEHICLE_ID_MAX    = 2147483647                   -- the INT column every vehicle id fits
local SESSION_ID_FIRST  = Vehicles._sessionVehicleCounter
local SESSION_ID_WINDOW = 100000000                    -- far more street cars than any run adopts

-- Where each vehicle was last written, and what is waiting to be written. Write-behind, the same
-- shape VehicleStats uses — see Vehicles.flushPositions.
Vehicles._lastPos  = {}   -- [vehicleId] = { x, y, z, heading }  as last committed
Vehicles._dirtyPos = {}   -- [vehicleId] = { x, y, z, heading }  pending


-- entity <-> vehicleId index: _entities and _byEntity are one set of bindings kept both ways; setTracked is the only
-- writer. A binding is believed only while isOurEntity says the handle is still that car (its fingerprint: network
-- id, model, KeepEntity; or failing that its stamp). The engine reuses handles, a statebag read per lookup is
-- expensive, and a stamp can outlive its car (FiveM #3289).

-- VEHICLE_STATE_KEY and VEHICLE_SESSION_KEY come from shared/statebags.lua: client/vehicles.lua
-- reads what this file writes.

-- Lifecycle: core's bookkeeping is called, not heard (any resource can fire a public event), so whip_core runs its
-- own hooks where each step happens, then fires the event for everyone else.

local _lifeHooks = {}

--- Run `fn(payload)` whenever whip_core announces `kind` ('spawned', 'registered', 'despawned', 'released',
--- 'created', 'ownerChanged' or 'deleted'). For whip_core's own files; a satellite listens to `whip_core:vehicle:<kind>`.
---@param kind string
---@param fn fun(payload: table)
function Vehicles.onLife(kind, fn)
    local list = _lifeHooks[kind]
    if not list then list = {}; _lifeHooks[kind] = list end
    list[#list + 1] = fn
end

--- Announce a lifecycle step: core's hooks first, in the order added (a car has its stats before any satellite hears
--- it spawned), then `whip_core:vehicle:<kind>` for everyone.
---@param kind string
---@param payload table
function Vehicles.announce(kind, payload)
    for _, fn in ipairs(_lifeHooks[kind] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then print(('[whip_core:vehicles] a "%s" hook errored: %s'):format(kind, tostring(err))) end
    end
    WhipEmit('whip_core:vehicle:' .. kind, payload)
end

-- Persistence: every column this framework owns is declared once here, and one function turns fields into a
-- database write through Stores.runTransaction.

--- Every writable column, and what it is allowed to be. Absent on purpose: `vehicleId` (the key), `createdAt` (the
--- database owns it), `vehStats` and `vehData` (they own their write-behind and must not be raced).
local FIELDS = {
    ownerCharId       = 'int',
    model             = 'string',
    plate             = 'string',
    state             = { 'enum', { 'out', 'garaged', 'impounded' } },
    garage            = 'string',
    locked            = 'bool',
    vehType           = 'string',
    x                 = 'number',
    y                 = 'number',
    z                 = 'number',
    heading           = 'number',
    parkedReversed    = 'bool',
    properties        = 'appearance',
    trunkSlots        = 'int',
    trunkMaxWeight    = 'number',
    gloveboxSlots     = 'int',
    gloveboxMaxWeight = 'number',
    keyToken          = 'string',
    reservation       = 'string',
}

--- NULL, as a value you can pass: `fields.x = nil` is just an absent key in Lua, so it can't mean
--- "clear it". Garaging a car needs that.
Vehicles.NULL = setmetatable({}, { __tostring = function() return 'Vehicles.NULL' end })

--- Coerce one field, or reject it.
---@return boolean ok, any value
local function coerceField(name, value)
    local rule = FIELDS[name]
    if not rule then return false end
    if value == Vehicles.NULL then return true, nil end

    -- NaN and infinity are refused (a crafted NaN owner would throw in the owner index mid-persist).
    if rule == 'int' then
        local n = tonumber(value)
        if not n or n ~= n or n == math.huge or n == -math.huge then return false end
        return true, math.floor(n)

    elseif rule == 'number' then
        local n = tonumber(value)
        if not n or n ~= n or n == math.huge or n == -math.huge then return false end
        return true, n + 0.0

    elseif rule == 'string' then
        if type(value) ~= 'string' then return false end
        return true, value

    elseif rule == 'bool' then
        -- The column is TINYINT, so the truth has to arrive as 1 or 0 rather than as a Lua boolean.
        return true, (value and value ~= 0) and 1 or 0

    elseif rule == 'appearance' then
        if type(value) ~= 'table' then return false end
        return true, json.encode(Vehicles.sanitizeProperties(value))

    elseif type(rule) == 'table' and rule[1] == 'enum' then
        for _, allowed in ipairs(rule[2]) do
            if value == allowed then return true, value end
        end
        return false
    end

    return false
end

--- Write fields to a vehicle's row and to its record. The only writer of the `vehicles` table. Session vehicles
--- have no row (memory only). A failed write puts the record back (it is not retried, so memory must not stay ahead
--- of disk); `opts.keepOnFailure` is for a change that already happened in the world (spawn: the car is out).
---@param vehicleId number
---@param fields table   column -> value, or Vehicles.NULL to clear
---@param opts table|nil { keepOnFailure = boolean, with = stores that land in the same transaction }
---@return boolean ok, string|nil err
function Vehicles.persist(vehicleId, fields, opts)
    local def = Vehicles._records[vehicleId]
    if not def then return false, 'vehicle not found' end
    if type(fields) ~= 'table' then return false, 'fields must be a table' end

    local sets, values, applied = {}, {}, {}

    for name, value in pairs(fields) do
        local ok, coerced = coerceField(name, value)
        if not ok then
            -- Refused, not skipped: a field must never quietly go nowhere.
            return false, ('bad field "%s"'):format(tostring(name))
        end

        if value == Vehicles.NULL then
            -- Written as a literal, not a parameter: `values[#values + 1] = nil` appends nothing, so
            -- placeholders and values would no longer line up.
            -- Safe to interpolate: `name` is a key of FIELDS or coerceField already refused it.
            sets[#sets + 1] = ('`%s`=NULL'):format(name)
            applied[name] = { null = true }
        else
            sets[#sets + 1] = ('`%s`=?'):format(name)
            values[#values + 1] = coerced
            applied[name] = { value = coerced }
        end
    end

    if #sets == 0 then return true end

    -- The record moves first: it is what every read answers from, and a session vehicle has nothing
    -- else. `properties` is held as a table in memory and as JSON on disk, so it takes the
    -- sanitised table rather than the encoded string. What it held before is kept, for a failure.
    local before = {}
    for name in pairs(applied) do before[name] = def[name] end
    for name, a in pairs(applied) do
        if a.null then
            def[name] = nil
        elseif name == 'properties' then
            def.properties = Vehicles.sanitizeProperties(fields.properties)
        elseif name == 'locked' then
            def.locked = a.value == 1
        elseif name == 'parkedReversed' then
            def.parkedReversed = a.value == 1
        else
            def[name] = a.value
        end
    end
    if applied.plate or applied.ownerCharId then Vehicles.reindex(vehicleId, def) end

    -- The entity carries the appearance for clients to read: every caller that writes
    -- `properties` restamps it, here in the funnel.
    if applied.properties then
        Vehicles.stampAppearance(vehicleId, nil, def)
    end

    if def.session then return true end

    values[#values + 1] = vehicleId
    -- With what its action saved, and a payment it holds (Stores.commitWithAction): bought parts
    -- land with the money for them. About this car: its action, of several.
    local ok, err = Stores.commitWithAction({
        {
            query  = ('UPDATE `vehicles` SET %s WHERE `vehicleId`=?'):format(table.concat(sets, ',')),
            values = values,
        },
    }, 'vehicle_row', opts and opts.with, nil, vehicleId)

    if not ok then
        -- Say which vehicle and which fields.
        local names = {}
        for name in pairs(applied) do names[#names + 1] = name end
        table.sort(names)
        print(('[whip_core:vehicle] FAILED writing #%s (%s): %s')
            :format(tostring(vehicleId), table.concat(names, ', '), tostring(err)))

        if not (opts and opts.keepOnFailure) then
            for name in pairs(applied) do def[name] = before[name] end
            if applied.plate or applied.ownerCharId then Vehicles.reindex(vehicleId, def) end
            if applied.properties then Vehicles.stampAppearance(vehicleId, nil, def) end
        end
        return false, err
    end

    return true
end

-- ============================================
-- Database — Table Creation
-- ============================================

---@return boolean ok
function Vehicles.ensureTable()
    local ok = CreateTable('vehicles', [[
        CREATE TABLE IF NOT EXISTS `vehicles` (
            `vehicleId`    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
            `ownerCharId`  INT UNSIGNED  NOT NULL,
            `model`        VARCHAR(60)   NOT NULL,
            `plate`        VARCHAR(10)   NOT NULL,
            `state`        ENUM('out','garaged','impounded') NOT NULL DEFAULT 'garaged',
            `garage`       VARCHAR(60)   DEFAULT NULL,
            -- NO `fuel` COLUMN. Fuel is a key in `vehStats`, like every other vehicle stat.
            `vehStats`     JSON          DEFAULT NULL,
            -- Per-vehicle data that is NOT a stat: anything json-encodable a resource wants
            -- to persist with a car but which has no range, no gauge and no drain. See
            -- server/vehicle_data.lua.
            `vehData`      JSON          DEFAULT NULL,
            `properties`   JSON          DEFAULT NULL,
            `x`            FLOAT         DEFAULT NULL,
            `y`            FLOAT         DEFAULT NULL,
            `z`            FLOAT         DEFAULT NULL,
            `heading`      FLOAT         DEFAULT NULL,
            -- Garaged facing the other way from its bay (backed in): it comes out of a bay that way
            -- too (migration 034 adds it to an existing table).
            `parkedReversed` TINYINT      NOT NULL DEFAULT 0,
            `locked`             TINYINT          NOT NULL DEFAULT 1,
            `vehType`            VARCHAR(20)      NOT NULL DEFAULT 'automobile',
            `trunkSlots`         SMALLINT UNSIGNED DEFAULT NULL,
            `trunkMaxWeight`     FLOAT            DEFAULT NULL,
            `gloveboxSlots`      SMALLINT UNSIGNED DEFAULT NULL,
            `gloveboxMaxWeight`  FLOAT            DEFAULT NULL,
            -- The car's locks (Vehicles.changeLocks): set, only keys cut with it fit; NULL, every key of
            -- this car does (migration 044 adds it to an existing table).
            `keyToken`           VARCHAR(24)      DEFAULT NULL,
            `reservation`        VARCHAR(191)     DEFAULT NULL,
            `createdAt`    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`vehicleId`),
            UNIQUE KEY `uk_plate` (`plate`),
            KEY `idx_owner` (`ownerCharId`),
            KEY `idx_state` (`state`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- CASCADE: a car's boot, glovebox and ignition contents go with it.
    local ok2 = CreateTable('vehicle_inventory', [[
        CREATE TABLE IF NOT EXISTS `vehicle_inventory` (
            `vehicleId`   INT UNSIGNED     NOT NULL,
            `storageType` ENUM('trunk','glovebox','key') NOT NULL DEFAULT 'trunk',
            `slot`        SMALLINT UNSIGNED NOT NULL,
            `item`        VARCHAR(50)      NOT NULL,
            `amount`      INT UNSIGNED     NOT NULL DEFAULT 1,
            `metadata`    JSON             DEFAULT NULL,
            PRIMARY KEY (`vehicleId`, `storageType`, `slot`),
            CONSTRAINT `fk_vinv_vehicle` FOREIGN KEY (`vehicleId`)
                REFERENCES `vehicles` (`vehicleId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Vehicle meta table (per-model storage defaults). hasTrunk / hasGlovebox: 1 on, 0 off, NULL its category's.
    local ok3 = CreateTable('vehicle_meta', [[
        CREATE TABLE IF NOT EXISTS `vehicle_meta` (
            `model`             VARCHAR(60)      NOT NULL,
            `trunkSlots`        SMALLINT UNSIGNED DEFAULT NULL,
            `trunkMaxWeight`    FLOAT            DEFAULT NULL,
            `gloveboxSlots`     SMALLINT UNSIGNED DEFAULT NULL,
            `gloveboxMaxWeight` FLOAT            DEFAULT NULL,
            `hasTrunk`          TINYINT          DEFAULT NULL,
            `hasGlovebox`       TINYINT          DEFAULT NULL,
            PRIMARY KEY (`model`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- Per-category storage defaults: every model of one GTA vehicle class (8 motorcycles, 10 industrial...).
    -- hasTrunk / hasGlovebox: 0 off, NULL on.
    local ok4 = CreateTable('vehicle_class_meta', [[
        CREATE TABLE IF NOT EXISTS `vehicle_class_meta` (
            `class`             TINYINT UNSIGNED NOT NULL,
            `trunkSlots`        SMALLINT UNSIGNED DEFAULT NULL,
            `trunkMaxWeight`    FLOAT            DEFAULT NULL,
            `gloveboxSlots`     SMALLINT UNSIGNED DEFAULT NULL,
            `gloveboxMaxWeight` FLOAT            DEFAULT NULL,
            `hasTrunk`          TINYINT          DEFAULT NULL,
            `hasGlovebox`       TINYINT          DEFAULT NULL,
            PRIMARY KEY (`class`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    return ok and ok2 and ok3 and ok4
end

-- ============================================
-- Helpers
-- ============================================

--- The garage a vehicle with a NULL `garage` column is filed under: the oldest (lowest garageId), so the seeded
--- Config.Garages come before anything a resource creates later (an impound lot must not catch every car).
function Vehicles.getDefaultGarage()
    if not Garages or not Garages.getAll then return nil end
    local bestKey, bestId
    for key, def in pairs(Garages.getAll()) do
        -- Never somebody's private garage (a property's): a car with nowhere to go is not theirs.
        local private = Garages.isPrivate and Garages.isPrivate(key)
        local id = tonumber(def.garageId) or math.huge
        if not private and (not bestId or id < bestId or (id == bestId and tostring(key) < tostring(bestKey))) then
            bestKey, bestId = key, id
        end
    end
    return bestKey
end

--- The garage a car is filed under, checked: a key that names no garage is refused. No key means the default
--- garage (nil, no error, on a server with no garages).
---@param key string|nil
---@return string|nil garageKey
---@return string|nil err
function Vehicles.checkGarage(key)
    if key == nil or key == '' then
        return Vehicles.getDefaultGarage()
    end
    if type(key) ~= 'string' or not (Garages and Garages.get(key)) then
        return nil, ('No such garage: %s'):format(tostring(key))
    end
    return key
end

-- ============================================
-- Load All Definitions
-- ============================================

function Vehicles.loadAll()
    Vehicles.ensureTable()

    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `vehicles`', {})
    if not ok then
        print(('[whip_core:vehicle] ERROR loading vehicles: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    Vehicles._records = {}
    Vehicles._entities        = {}
    Vehicles._byEntity        = {}

    -- Reset the transition locks too: a lock must never be inherited ("Vehicle is busy" for good).
    Vehicles._transitionLocks = {}

    local count = 0

    if rows then
        for _, row in ipairs(rows) do
            local props = nil
            if row.properties and row.properties ~= '' and row.properties ~= 'null' then
                props = json.decode(row.properties)
            end
            -- Sanitised on the way in too: an old row may carry `plate`, which would override the
            -- column's. Rewritten clean on the next appearance save.
            props = type(props) == 'table' and Vehicles.sanitizeProperties(props) or nil

            -- Same guard shape as `properties` above: a JSON column arrives as nil, an empty
            -- string, or the literal text 'null' depending on how it was written.
            local stats = nil
            if row.vehStats and row.vehStats ~= '' and row.vehStats ~= 'null' then
                stats = json.decode(row.vehStats)
            end
            if type(stats) ~= 'table' then stats = {} end

            -- Same guard again for the data block. Absent on every row until something
            -- attaches data to that vehicle, which is the normal case.
            local vehData = nil
            if row.vehData and row.vehData ~= '' and row.vehData ~= 'null' then
                vehData = json.decode(row.vehData)
            end
            if type(vehData) ~= 'table' then vehData = {} end

            -- No defaults are seeded (fuel included): an absent key means "use the registered
            -- default", which VehicleStats.get falls back to, and it is how an installable stat
            -- says it is not installed.

            -- 'out' vehicles stay out and are rebuilt below; one with no saved position garages.
            local state = row.state or 'garaged'
            if state == 'out' and not (row.x and row.y and row.z) then
                state = 'garaged'
            end

            -- If vehicle has no garage (admin-created / legacy), assign a default
            local garage = row.garage
            if not garage or garage == '' then
                garage = Vehicles.getDefaultGarage()
            end

            Vehicles._records[row.vehicleId] = {
                vehicleId        = row.vehicleId,
                ownerCharId      = row.ownerCharId,
                reservation      = row.reservation,
                model            = row.model,
                plate            = row.plate,
                state            = state,
                garage           = garage,
                -- `vehStats` travels to clients (vehiclesSync, the Vehicle Manager) so the garage list
                -- and admin panel can show fuel for a car that isn't streamed in.
                vehStats         = stats,
                vehData          = vehData,
                properties       = props,
                x                = row.x,
                y                = row.y,
                z                = row.z,
                heading          = row.heading,
                -- Garaged backed into its bay: it comes out of a bay facing that way (events_vehicles.lua).
                parkedReversed   = DbBool(row.parkedReversed),
                trunkSlots       = row.trunkSlots,
                trunkMaxWeight   = row.trunkMaxWeight,
                gloveboxSlots    = row.gloveboxSlots,
                gloveboxMaxWeight = row.gloveboxMaxWeight,
                createdAt        = row.createdAt,
                -- As it was left. One locked with its own key in the ignition is unlocked once the world is back
                -- (below), or its owner would be locked out. Garage retrieve sets its own lock.
                locked           = DbBool(row.locked),
                vehType          = row.vehType or 'automobile',
                -- Its locks, once changed: only keys cut since fit (Vehicles.keyFits). Never sent to a client.
                keyToken         = type(row.keyToken) == 'string' and row.keyToken ~= '' and row.keyToken or nil,
            }
            count = count + 1
        end
    end
    Vehicles.reindexAll()

    -- Boot repairs: bulk fixes to the whole table, once, before anything spawns. A garaged car must not keep coordinates.
    local repairs = {
        {
            query  = 'UPDATE `vehicles` SET `state` = "garaged" WHERE `state` = "out" AND (`x` IS NULL OR `y` IS NULL OR `z` IS NULL)',
            values = {},
        },
        {
            query  = 'UPDATE `vehicles` SET `x`=NULL,`y`=NULL,`z`=NULL,`heading`=NULL WHERE `state` <> "out"',
            values = {},
        },
    }

    local defaultGarage = Vehicles.getDefaultGarage()
    if defaultGarage then
        repairs[#repairs + 1] = {
            query  = 'UPDATE `vehicles` SET `garage` = ? WHERE `garage` IS NULL',
            values = { defaultGarage },
        }
    end

    local repaired, repairErr = Stores.runTransaction(repairs, 'vehicle_boot_repair')
    if not repaired then
        print(('[whip_core:vehicle] boot repairs FAILED: %s'):format(tostring(repairErr)))
    end

    print(('[whip_core:vehicle] loaded %d vehicles'):format(count))

    -- Rebuild the world: nothing has been created yet, so there is no "lost or not made yet?"
    -- question. Deferred a second, off the startup path (creating entities in onResourceStart's
    -- first moment is unreliable). The cache is already correct, so nothing waits on this.
    CreateThread(function()
        Wait(1000)

        -- First, re-adopt cars still stamped as ours from before the restart, so the restore below
        -- doesn't build second copies.
        Vehicles.reconcileWorld()

        -- A car out in the world, locked, with its own key in the ignition (the server went down with its driver in
        -- it, so nothing took the key out): unlocked, as a garage retrieve does, or its owner is locked out of it.
        -- Every other car keeps the lock it was left with (audit 20, VEH-4).
        local lockedOut = {}
        for vehicleId, def in pairs(Vehicles._records) do
            if def.state == 'out' and not def.session and def.locked then lockedOut[#lockedOut + 1] = vehicleId end
        end
        for _, vehicleId in ipairs(lockedOut) do
            local asked, inside = pcall(Vehicles.hasKeyInIgnition, vehicleId)
            if asked and inside then Vehicles.setLocked(vehicleId, false) end
        end

        -- Snapshot the ids before the first yield: spawn yields, and new street cars add keys to
        -- _records meanwhile (adding keys during pairs() is undefined). Session vehicles are GTA's
        -- own street cars: nothing to rebuild.
        local ids = {}
        for vehicleId, def in pairs(Vehicles._records) do
            if def.state == 'out' and not def.session then
                ids[#ids + 1] = vehicleId
            end
        end

        local restored, failed = 0, 0
        for _, vehicleId in ipairs(ids) do
            -- Re-check: a minute is a long time in a startup, and something may have garaged or
            -- deleted this vehicle while we were writing the last one.
            local def = Vehicles._records[vehicleId]
            if def and def.state == 'out' and not def.session and not Vehicles.getEntity(vehicleId) then
                local entity = Vehicles.spawn(vehicleId, def.x, def.y, def.z, def.heading)
                if entity then restored = restored + 1 else failed = failed + 1 end
            end
        end

        if restored > 0 or failed > 0 then
            print(('[whip_core:vehicle] restored %d vehicles to the world%s')
                :format(restored, failed > 0 and (' (%d failed)'):format(failed) or ''))
        end
    end)
end

-- Storage defaults (/whip Vehicle Adjustments): a car's trunk and glovebox sizes come from the car's own sizes, then
-- its model's row (`vehicle_meta`), then its category's (`vehicle_class_meta`, the GTA vehicle class), then config.lua.
-- Either can be off (a model's word over its category's): an off trunk is not offered and not opened.

--- Each storage's columns.
Vehicles.STORAGE_KEYS = {
    trunk    = { slots = 'trunkSlots',    weight = 'trunkMaxWeight',    has = 'hasTrunk' },
    glovebox = { slots = 'gloveboxSlots', weight = 'gloveboxMaxWeight', has = 'hasGlovebox' },
}

--- A TINYINT on/off column: true, false, or nil (not said).
local function onOff(v)
    if v == nil then return nil end
    return v == true or tonumber(v) == 1
end

--- One row as the caches keep it.
local function metaRow(row)
    return {
        trunkSlots        = row.trunkSlots,
        trunkMaxWeight    = row.trunkMaxWeight,
        gloveboxSlots     = row.gloveboxSlots,
        gloveboxMaxWeight = row.gloveboxMaxWeight,
        hasTrunk          = onOff(row.hasTrunk),
        hasGlovebox       = onOff(row.hasGlovebox),
    }
end

--- An on/off for the database: 1, 0, or NULL.
local function onOffColumn(v)
    if v == nil then return nil end
    return v and 1 or 0
end

function Vehicles.loadMeta()
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `vehicle_meta`', {})
    if not ok then
        print(('[whip_core:vehicle] ERROR loading vehicle_meta: %s'):format(tostring(rows)))
        return false
    end
    local okC, classRows = pcall(MySQL.query.await, 'SELECT * FROM `vehicle_class_meta`', {})
    if not okC then
        print(('[whip_core:vehicle] ERROR loading vehicle_class_meta: %s'):format(tostring(classRows)))
        return false
    end

    Vehicles.metaCache = {}
    for _, row in ipairs(rows or {}) do Vehicles.metaCache[row.model] = metaRow(row) end
    Vehicles.classMetaCache = {}
    for _, row in ipairs(classRows or {}) do
        local class = tonumber(row.class)
        if class then Vehicles.classMetaCache[class] = metaRow(row) end
    end
    return true
end

--- Write one row (a model's or a category's) and keep it. `data` holds the four sizes and the two on/offs.
---@param tbl 'vehicle_meta'|'vehicle_class_meta'
---@param keyColumn 'model'|'class'
local function saveRow(tbl, keyColumn, key, data)
    local ok, err = pcall(MySQL.query.await, ([[
        INSERT INTO `%s` (`%s`,`trunkSlots`,`trunkMaxWeight`,`gloveboxSlots`,`gloveboxMaxWeight`,`hasTrunk`,`hasGlovebox`)
        VALUES (?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            `trunkSlots`=VALUES(`trunkSlots`),
            `trunkMaxWeight`=VALUES(`trunkMaxWeight`),
            `gloveboxSlots`=VALUES(`gloveboxSlots`),
            `gloveboxMaxWeight`=VALUES(`gloveboxMaxWeight`),
            `hasTrunk`=VALUES(`hasTrunk`),
            `hasGlovebox`=VALUES(`hasGlovebox`)
    ]]):format(tbl, keyColumn), {
        key,
        data.trunkSlots or nil,
        data.trunkMaxWeight or nil,
        data.gloveboxSlots or nil,
        data.gloveboxMaxWeight or nil,
        onOffColumn(data.hasTrunk),
        onOffColumn(data.hasGlovebox),
    })
    if not ok then
        print(('[whip_core:vehicle] ERROR saving %s for "%s": %s'):format(tbl, tostring(key), tostring(err)))
        return false
    end
    return true
end

local function deleteRow(tbl, keyColumn, key)
    local ok, err = pcall(MySQL.query.await, ('DELETE FROM `%s` WHERE `%s` = ?'):format(tbl, keyColumn), { key })
    if not ok then
        print(('[whip_core:vehicle] ERROR deleting %s for "%s": %s'):format(tbl, tostring(key), tostring(err)))
        return false
    end
    return true
end

function Vehicles.saveMeta(model, data)
    if not model or model == '' then return false end
    if not saveRow('vehicle_meta', 'model', model, data) then return false end
    Vehicles.metaCache[model] = metaRow(data)
    return true
end

function Vehicles.deleteMeta(model)
    if not model or model == '' then return false end
    if not deleteRow('vehicle_meta', 'model', model) then return false end
    Vehicles.metaCache[model] = nil
    return true
end

---@param class number  a GTA vehicle class, 0-22
function Vehicles.saveClassMeta(class, data)
    if not saveRow('vehicle_class_meta', 'class', class, data) then return false end
    Vehicles.classMetaCache[class] = metaRow(data)
    return true
end

function Vehicles.deleteClassMeta(class)
    if not deleteRow('vehicle_class_meta', 'class', class) then return false end
    Vehicles.classMetaCache[class] = nil
    return true
end

--- The number of slots a boot or glovebox of this category has in config.lua (a motorbike's glovebox has its own).
---@param class number|nil
---@param kind 'trunk'|'glovebox'
---@return number
function Vehicles.configSlots(class, kind)
    if kind == 'trunk' then return Config.VehicleTrunkSlots end
    if class == 8 then return Config.MotorbikeGloveboxSlots or 1 end
    return Config.VehicleGloveboxSlots
end

--- config.lua's slots for this model (its category's, as configSlots).
---@param model string|nil
---@param kind 'trunk'|'glovebox'
---@return number
function Vehicles.defaultSlots(model, kind)
    return Vehicles.configSlots(Vehicles.classForModel(model), kind)
end

--- One storage as the cars of a model get it without sizes of their own: the model's row over its category's over
--- config.lua. The rows are the caches' shape (nil: none), so the admin page can try one before saving it.
---@param kind 'trunk'|'glovebox'
---@param class number|nil
---@param classRow table|nil
---@param modelRow table|nil
---@return table  { slots, maxWeight, on }
function Vehicles.layeredStorage(kind, class, classRow, modelRow)
    local k = Vehicles.STORAGE_KEYS[kind]
    local out = {
        slots     = Vehicles.configSlots(class, kind),
        maxWeight = kind == 'trunk' and Config.VehicleTrunkMaxWeight or Config.VehicleGloveboxMaxWeight,
        on        = true,
    }
    for _, row in ipairs({ classRow or {}, modelRow or {} }) do
        if row[k.slots] then out.slots = row[k.slots] end
        if row[k.weight] then out.maxWeight = row[k.weight] end
        if row[k.has] ~= nil then out.on = row[k.has] end
    end
    return out
end

--- One storage as this model's cars get it without sizes of their own (layeredStorage, from the caches).
---@param model string|nil
---@param kind 'trunk'|'glovebox'
---@return table  { slots, maxWeight, on }
function Vehicles.modelStorage(model, kind)
    local class = Vehicles.classForModel(model)
    -- Model names are not case-sensitive in GTA; the page saves them lower-case.
    local m = model and (Vehicles.metaCache[model] or Vehicles.metaCache[tostring(model):lower()]) or nil
    return Vehicles.layeredStorage(kind, class, class and Vehicles.classMetaCache[class] or nil, m)
end

--- Has this vehicle a trunk (or glovebox) at all? Off by its model, or its category (Vehicle Adjustments).
---@param vehicleId number
---@param kind 'trunk'|'glovebox'
---@return boolean
---@diagnostic disable-next-line: duplicate-set-field -- the client's Vehicles is a different table
function Vehicles.hasStorage(vehicleId, kind)
    local def = Vehicles._records[vehicleId]
    return Vehicles.modelStorage(def and def.model, kind).on
end

--- Which trunks and gloveboxes are off, for the clients (whip_core:client:vehicleStorageSync): their prompt and F2
--- go by it, by the game's class of the car and its model, as here. Lists, not keyed tables, for the trip.
---@return table  { classes = { { class, trunk, glovebox } }, models = { { model, trunk, glovebox } } }
function Vehicles.storageWire()
    local classes, models = {}, {}
    for class, c in pairs(Vehicles.classMetaCache) do
        if c.hasTrunk == false or c.hasGlovebox == false then
            classes[#classes + 1] = { class = class, trunk = c.hasTrunk ~= false, glovebox = c.hasGlovebox ~= false }
        end
    end
    for model, m in pairs(Vehicles.metaCache) do
        if m.hasTrunk ~= nil or m.hasGlovebox ~= nil then
            models[#models + 1] = { model = model, trunk = m.hasTrunk, glovebox = m.hasGlovebox }
        end
    end
    return { classes = classes, models = models }
end

--- Resolve storage config with fallback: per-vehicle → model → category → config.lua (modelStorage)
function Vehicles.getStorageConfig(vehicleId, storageType)
    -- Key slot is always 1 slot (no per-vehicle or meta overrides)
    if storageType == 'key' then
        return { slots = Config.VehicleKeySlots or 1, maxWeight = Config.VehicleKeyMaxWeight or 1.0 }
    end

    local def = Vehicles._records[vehicleId]
    local k = Vehicles.STORAGE_KEYS[storageType] or Vehicles.STORAGE_KEYS.glovebox
    local base = Vehicles.modelStorage(def and def.model or nil, storageType == 'trunk' and 'trunk' or 'glovebox')

    return {
        slots     = (def and def[k.slots])  or base.slots,
        maxWeight = (def and def[k.weight]) or base.maxWeight,
    }
end

-- ============================================
-- Plate Generation
-- ============================================

function Vehicles.generatePlate()
    local chars  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    local digits = '0123456789'

    local function rc(s)
        local idx = math.random(1, #s)
        return s:sub(idx, idx)
    end

    -- Checked against the plate index (all vehicles are loaded at startup), not the database.
    for _ = 1, 20 do
        local plate = rc(chars)..rc(chars)..rc(digits)..rc(digits)..rc(digits)..rc(chars)..rc(chars)
        if not Vehicles.getByPlate(plate) then return plate end
    end

    -- Fallback (extremely unlikely with ~330k possible combinations)
    return rc(chars)..rc(chars)..rc(digits)..rc(digits)..rc(digits)..rc(chars)..rc(chars)
end

-- ============================================
-- CRUD
-- ============================================

--- Which entity type a GTA vehicle CLASS spawns as. Anything not listed is an 'automobile'.
--- Submarines and trailers share a class with things that are not, so they are left to the
--- self-correction in Vehicles.spawn.
local CLASS_VEHTYPE = {
    [8]  = 'bike',    -- motorcycles
    [13] = 'bike',    -- cycles
    [14] = 'boat',
    [15] = 'heli',
    [16] = 'plane',
}

--- GTA's vehicle class of a model (8 a motorbike, 13 a bicycle, 14 a boat...), from the vehicle catalog,
--- or nil when the catalog does not know the model.
---@param model string|nil
---@return number|nil
function Vehicles.classForModel(model)
    if type(model) ~= 'string' then return nil end
    local row = VehicleCatalog.rows[model:lower()]
    return row and tonumber(row.class) or nil
end

--- The entity type for a model, from the vehicle catalog's class, or nil when the catalog does not
--- know the model.
---@param model string
---@return string|nil
function Vehicles.typeForModel(model)
    local class = Vehicles.classForModel(model)
    if not class then return nil end
    return CLASS_VEHTYPE[class] or 'automobile'
end

--- Is this vehicle a bicycle? A bicycle has no ignition and no glovebox. By its model's class in
--- the vehicle catalog; a model the catalog does not know is not one (the client asks the game).
---@param vehicleId number
---@return boolean
function Vehicles.isBicycle(vehicleId)
    local def = Vehicles._records[vehicleId]
    return def ~= nil and Vehicles.classForModel(def.model) == 13
end

-- Which vehicles this game has. The server has no game files, so a model the game lacks would make a database
-- row with nothing in the world. Only a game can say: as whip_core comes up in a player's game the client sends
-- GetAllVehicleModels() (add-on cars included) and the server keeps every name any game reported.
-- Kept across restarts, per platform and game build (sv_enforceGameBuild), so a restart knows the cars before anyone
-- joins. A name no game has reported for MODELS_FORGET_DAYS is dropped; a new game build starts its own list.
-- A union on purpose: a lying client can only add names, never take a real car away.
-- Unknown is not no: until a game has reported the answer is nil and nothing is refused, so the boot respawn can't lose cars.
-- The gates are Vehicles.create, retrieve, spawn and spawnTemp. Exported as VehicleModelExists for a seller's stock.
local knownModels, knownModelCount = {}, 0

local MODELS_FORGET_DAYS = 14
local MODELS_SAVE_AFTER_MS = 5000
local modelsSeen = {}         -- [name] = the day (since 1970) a game last reported it
local modelsSaveDue = false

local function today() return math.floor(os.time() / 86400) end

--- The saved list's key: one per platform and game build.
local function modelsKey()
    return ('whip_core:knownModels:%s:%s'):format(GamePlatform.name, GetConvar('sv_enforceGameBuild', '0'))
end

--- Save what the games said, a few seconds after the last change (a report changes every name's day at once).
local function saveModelsSoon()
    if modelsSaveDue then return end
    modelsSaveDue = true
    SetTimeout(MODELS_SAVE_AFTER_MS, function()
        modelsSaveDue = false
        SetResourceKvp(modelsKey(), json.encode({ v = 1, seen = modelsSeen }))
    end)
end

-- A ceiling: the union only grows, and a modified client could flood it. GTA plus a big add-on
-- pack is a few thousand models. Once a name has been turned away, a model not on the list is
-- unknown (nil), never "no".
local MAX_KNOWN_MODELS = 20000
local capSaid = false
local modelListFull = false   -- a name was turned away by the ceiling: "not on the list" no longer means "no"

-- Names from a report too big to trust, known until the restart: kept apart, so they never count toward the ceiling
-- or fill it (audit 20, VEH-6: a few lying accounts in one run filled it, and then nothing was refused). Their own
-- ceiling only stops them being taken.
local sessionModels, sessionModelCount = {}, 0

--- How many of these names the list does not know yet (nothing is added).
---@param list string[]
---@return integer
function Vehicles.newModelCount(list)
    local n, seen = 0, {}
    for _, name in ipairs(list) do
        local m = type(name) == 'string' and name:lower() or nil
        if m and m ~= '' and not knownModels[m] and not seen[m] then seen[m] = true; n = n + 1 end
    end
    return n
end

--- Add a game's list of vehicle models (validated by the report's SecureEvent). Answers how many were new.
---@param list string[]
---@param day number|nil  the day it was reported; default today, and saved
---@param sessionOnly boolean|nil  known until the restart, never saved (a report too big to trust)
---@return integer added
function Vehicles.addKnownModels(list, day, sessionOnly)
    if sessionOnly then
        local added = 0
        for _, name in ipairs(list) do
            local m = type(name) == 'string' and name:lower() or nil
            if m and m ~= '' and not knownModels[m] and not sessionModels[m] and sessionModelCount < MAX_KNOWN_MODELS then
                sessionModels[m] = true
                sessionModelCount = sessionModelCount + 1
                added = added + 1
            end
        end
        return added
    end
    local fromSave = day ~= nil
    day = day or today()
    local added, changed = 0, false
    for _, name in ipairs(list) do
        local m = type(name) == 'string' and name:lower() or nil
        if m and m ~= '' and not knownModels[m] then
            if knownModelCount + added >= MAX_KNOWN_MODELS then
                -- Full: no new names, but the ones already on it still count as reported today.
                modelListFull = true
                if not capSaid then
                    capSaid = true
                    print(('[whip_core:vehicle] the list of known vehicle models is full (%d): no more are taken, and a model not on it is no longer refused')
                        :format(MAX_KNOWN_MODELS))
                end
                m = nil
            else
                knownModels[m] = true
                added = added + 1
            end
        end
        if m and m ~= '' then
            if (modelsSeen[m] or -1) < day then
                modelsSeen[m] = day
                changed = true
            end
        end
    end
    knownModelCount = knownModelCount + added
    if changed and not fromSave then saveModelsSoon() end
    return added
end

-- What the games said before this restart, less what none has reported for MODELS_FORGET_DAYS.
do
    local raw = GetResourceKvpString(modelsKey())
    local ok, saved = pcall(json.decode, raw or '')
    if ok and type(saved) == 'table' and type(saved.seen) == 'table' then
        local since = today() - MODELS_FORGET_DAYS
        local byDay, kept, gone = {}, 0, 0
        for name, d in pairs(saved.seen) do
            d = tonumber(d)
            if type(name) == 'string' and d and d >= since then
                byDay[d] = byDay[d] or {}
                byDay[d][#byDay[d] + 1] = name
                kept = kept + 1
            else
                gone = gone + 1
            end
        end
        for d, names in pairs(byDay) do Vehicles.addKnownModels(names, d) end
        if gone > 0 then saveModelsSoon() end
        print(('[whip_core:vehicle] %d vehicle models remembered from players\' games%s')
            :format(kept, gone > 0 and (' (%d not reported for %d days, dropped)'):format(gone, MODELS_FORGET_DAYS) or ''))
    end
end

--- How many vehicle models are known now (saved and reported).
---@return integer
function Vehicles.knownModelCount() return knownModelCount end

--- Is `model` a vehicle this game has? True or false; nil when no game has said yet, or the list is full and it is
--- not on it.
---@param model any
---@return boolean|nil
function Vehicles.modelExists(model)
    if knownModelCount == 0 and sessionModelCount == 0 then return nil end
    if type(model) ~= 'string' then return false end
    local m = model:lower()
    if knownModels[m] == true or sessionModels[m] == true then return true end
    if modelListFull then return nil end
    return false
end

--- Why a car of `model` cannot be made or brought out, or nil when it can (or nobody knows yet).
---@param model any
---@return string|nil why
function Vehicles.missingModel(model)
    if Vehicles.modelExists(model) == false then
        return ('There is no vehicle called "%s" in this game'):format(tostring(model))
    end
    return nil
end

--- A plate as whip stores it: up to 8 characters, trimmed, upper case; nil for "none given", or nil and why for one
--- that cannot be a plate. GTA shows 8 characters, so a longer plate would never match the car again.
---@param plate any
---@return string|nil plate
---@return string|nil why
function Vehicles.normalisePlate(plate)
    if type(plate) == 'number' then plate = tostring(math.floor(plate)) end
    if plate ~= nil and type(plate) ~= 'string' then return nil, 'A plate is text' end
    plate = plate and plate:gsub('^%s+', ''):gsub('%s+$', ''):upper() or nil
    if not plate or plate == '' then return nil end
    if #plate > 8 then return nil, 'A plate is 8 characters at most' end
    return plate
end

--- The plate as the car wears it: centred in the game's 8-character plate field. Enhanced draws a
--- short plate from the left edge (Legacy centres it), so the padding is put on here. Only the entity
--- gets it: records and the plate index keep the trimmed plate, and every match ignores spaces.
---@param plate string
---@return string
function Vehicles.displayPlate(plate)
    plate = tostring(plate):gsub('^%s+', ''):gsub('%s+$', '')
    local pad = math.max(0, 8 - #plate)
    return (' '):rep(pad // 2) .. plate .. (' '):rep(pad - pad // 2)
end

function Vehicles.create(data)
    -- A model the game has (Vehicles.modelExists), before anything is written: a dealership sale
    -- refunds on this answer, and /whip shows it.
    local missing = Vehicles.missingModel(data.model or 'adder')
    if missing then return nil, missing end

    -- The plate rule is Vehicles.normalisePlate. A taken plate is refused with the reason instead of
    -- a bare database error.
    local plate, plateErr = Vehicles.normalisePlate(data.plate)
    if plateErr then return nil, plateErr end
    if not plate then
        plate = Vehicles.generatePlate()
    elseif Vehicles.getByPlate(plate) then
        return nil, 'That plate is already taken'
    end

    -- Through the one appearance rule: raw GetVehicleProperties would carry `plate` over the column's.
    local props = data.properties ~= nil and Vehicles.sanitizeProperties(data.properties) or nil
    local propsJson = props and json.encode(props) or nil

    -- A garage that exists, or the default one when none is named.
    local garage, garageErr = Vehicles.checkGarage(data.garage)
    if garageErr then return nil, garageErr end

    -- vehType is written at creation, or the first spawn builds the wrong kind of thing. Callers
    -- that know it say so; otherwise the catalog's class decides, and only an unknown model falls
    -- back to 'automobile' (spawn's self-correction fixes that after the first attempt).
    local vehType = data.vehType
    if type(vehType) ~= 'string' or vehType == '' then
        vehType = Vehicles.typeForModel(data.model) or 'automobile'
    end

    -- The stats it starts with ({ fuel = 100 }, a resource's own): numbers under stat names. One left out reads its
    -- registered default until it is first written.
    local stats = {}
    if type(data.vehStats) == 'table' then
        for k, v in pairs(data.vehStats) do
            if type(k) == 'string' and k:match('^[%a_][%w_]*$') and tonumber(v) then stats[k] = tonumber(v) end
        end
    end

    -- Written with its action's saves: a car sold at the dealership lands in one transaction with
    -- the money for it (Money.charge 'held'). A transaction answers no insert id, so the id is read
    -- back by the plate (uk_plate). About its new owner: the buyer's action, with its payment.
    local buyer = data.ownerCharId and PlayersByCharId and PlayersByCharId[data.ownerCharId]
    local ok, writeErr = Stores.commitWithAction({ {
        query  = 'INSERT INTO `vehicles` (`ownerCharId`,`model`,`plate`,`state`,`garage`,`vehStats`,`properties`,`x`,`y`,`z`,`heading`,`trunkSlots`,`trunkMaxWeight`,`gloveboxSlots`,`gloveboxMaxWeight`,`vehType`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        values = {
            data.ownerCharId,
            data.model or 'adder',
            plate,
            data.state or 'garaged',
            garage,
            json.encode(stats),
            propsJson,
            data.x or nil,
            data.y or nil,
            data.z or nil,
            data.heading or nil,
            data.trunkSlots or nil,
            data.trunkMaxWeight or nil,
            data.gloveboxSlots or nil,
            data.gloveboxMaxWeight or nil,
            vehType,
        },
    } }, 'vehicle_create', nil, buyer and buyer.source or nil)

    if not ok then
        print(('[whip_core:vehicle] ERROR creating vehicle: %s'):format(tostring(writeErr)))
        return nil
    end

    -- The car is on disk now (with any payment it rode). A failed read is retried for a while; if it still fails the
    -- answer is "made, not loaded" (third value `saved`: a caller must not undo a payment that landed), and the read
    -- goes on in the background: when it answers, the record is loaded and `data.onLate(def)` runs.
    local function readId()
        local readOk, id = pcall(MySQL.scalar.await, 'SELECT `vehicleId` FROM `vehicles` WHERE `plate` = ?', { plate })
        return readOk and tonumber(id) or nil
    end
    local insertId
    for _, waitMs in ipairs({ 500, 1000, 2000, 3000, 4000, 5000, 0 }) do
        insertId = readId()
        if insertId or waitMs == 0 then break end
        Wait(waitMs)
    end

    local function load(id)
        return Vehicles.loadCreated(id, data, plate, garage, stats, props, vehType)
    end
    if not insertId then
        print(('[whip_core:vehicle] CRITICAL: vehicle %s was created, but its id could not be read back yet — still trying')
            :format(plate))
        CreateThread(function()
            for _ = 1, 60 do
                Wait(10000)
                local id = readId()
                if id then
                    local late = Vehicles._records[id] or load(id)
                    print(('[whip_core:vehicle] vehicle %s read back at last: #%d'):format(plate, id))
                    if type(data.onLate) == 'function' then pcall(data.onLate, late) end
                    return
                end
            end
            print(('[whip_core:vehicle] CRITICAL: vehicle %s never read back — it appears after a restart'):format(plate))
        end)
        return nil, 'The vehicle was registered but could not be brought out yet', true
    end

    return load(insertId)
end

--- The record of a car Vehicles.create has just written, loaded and announced. (Split out so a car whose id was read
--- back late is loaded the same way.)
function Vehicles.loadCreated(insertId, data, plate, garage, stats, props, vehType)
    local def = {
        vehicleId        = insertId,
        ownerCharId      = data.ownerCharId,
        model            = data.model or 'adder',
        plate            = plate,
        state            = data.state or 'garaged',
        garage           = garage,
        vehStats         = stats,
        properties       = props,
        x                = data.x,
        y                = data.y,
        z                = data.z,
        heading          = data.heading,
        trunkSlots       = data.trunkSlots,
        trunkMaxWeight   = data.trunkMaxWeight,
        gloveboxSlots    = data.gloveboxSlots,
        gloveboxMaxWeight = data.gloveboxMaxWeight,
        createdAt        = os.time(),
        locked           = true,
        vehType          = vehType,
    }

    Vehicles._records[insertId] = def
    Vehicles.reindex(insertId, def)

    -- Announce it (the owner's client list is resynced from this). Here, not in CreateOwnedVehicle,
    -- so every path that mints a vehicle is covered.
    Vehicles.announce('created', {
        vehicleId   = insertId,
        ownerCharId = def.ownerCharId,
    })

    return def
end

--- Move a vehicle to a different character. Writes the one column.
---@param vehicleId number
---@param newCharId number|string|nil
---@return boolean ok
---@return string|nil err
function Vehicles.transferOwner(vehicleId, newCharId, expectedOwner)
    if Vehicles._transitionLocks[vehicleId] then return false, 'Vehicle is busy' end
    local def = Vehicles._records[vehicleId]
    if not def then return false, 'Vehicle not found' end
    if heldBy(def) then return false, 'Vehicle is in custody' end
    if expectedOwner ~= nil and def.ownerCharId ~= tonumber(expectedOwner) then return false, 'Vehicle ownership changed' end

    -- A street car whip adopted has no row and nobody owns it.
    if def.session then return false, 'Session vehicles have no owner' end

    newCharId = tonumber(newCharId)
    if not newCharId or newCharId <= 0 then return false, 'Invalid character' end

    local from = def.ownerCharId
    if from == newCharId then return false, 'Already owned by that character' end

    Vehicles._transitionLocks[vehicleId] = true
    local called, ok, err = pcall(Vehicles.persist, vehicleId, { ownerCharId = newCharId })
    Vehicles._transitionLocks[vehicleId] = nil
    if not called then return false, 'Database write failed' end
    if not ok then return false, err or 'Database write failed' end

    Vehicles.announce('ownerChanged', {
        vehicleId = vehicleId,
        from      = from,
        to        = newCharId,
    })

    return true
end

-- Stats are not row fields and persist refuses them: set one with VehicleStats.set, the only
-- writer that honours a stat's min, max and persist flag.

--- Run `fn` holding this vehicle's transition lock, and always give it back (an error must not strand it). The
--- caller checks the lock is free first.
---@param what string  'store' | 'retrieve' | 'delete' | 'despawn', for the message
---@return any, any  whatever fn returns, or false and a reason if it errored
local function underTransitionLock(vehicleId, what, fn)
    Vehicles._transitionLocks[vehicleId] = true
    local okCall, a, b = pcall(fn)
    Vehicles._transitionLocks[vehicleId] = nil
    if not okCall then
        print(('[whip_core:vehicle] %s #%s errored: %s'):format(what, tostring(vehicleId), tostring(a)))
        return false, ('Could not %s the vehicle'):format(what)
    end
    return a, b
end

local deleteLocked

function Vehicles.delete(vehicleId)
    local delDef = Vehicles._records[vehicleId]
    if not delDef then return false, 'Vehicle not found' end
    if heldBy(delDef) then return false, 'Vehicle is in custody' end

    -- Not mid-transition, and the lock is held for the whole delete: it waits four times, and a
    -- spawn landing in one of those waits would bind a car to an id that no longer exists.
    if Vehicles._transitionLocks[vehicleId] then return false, 'Vehicle is busy' end
    return underTransitionLock(vehicleId, 'delete', function() return deleteLocked(vehicleId, delDef) end)
end

--- The body of Vehicles.delete, run while the transition lock is held. Never call it directly.
function deleteLocked(vehicleId, delDef)
    -- Read before anything is torn down: by the time the delete has succeeded there is no def
    -- left to ask who owned it or whether it was in the world.
    local ownerCharId = delDef.ownerCharId
    local wasOut      = delDef.state == 'out'

    -- A session vehicle has no database row to delete, and "delete" for a street car means
    -- forgetting it, not removing it from the world. (Session ids are ordinary integers, so any
    -- caller naming one reaches here: the admin panel, DeleteVehicle.)
    if delDef.session then
        Vehicles.cleanupSessionVehicle(vehicleId, 'deleted')
        return true
    end

    -- What is in it, read first: its contents leave the game with it and are logged. A car whose
    -- contents cannot be read is not deleted.
    if not Vehicles.invCache[vehicleId] and not Vehicles.loadInventory(vehicleId) then
        print(('[whip_core:vehicle] delete #%d refused: could not read what is in it'):format(vehicleId))
        return false, 'Could not read what is in it'
    end
    local where = delDef.x and vector3(delDef.x, delDef.y, delDef.z) or nil
    local plate = delDef.plate

    -- What is owed is written first (each compartment with its whole group), and forgotten only once
    -- the delete has landed, so a failed delete can't leave half a move on disk. A delete that can't
    -- settle is refused, with nothing changed.
    local inv = Vehicles.invCache[vehicleId]
    for storageType in pairs(inv or {}) do
        if not Stores.settle(('vehicle:%s:%s'):format(tostring(vehicleId), tostring(storageType))) then
            print(('[whip_core:vehicle] delete #%d refused: its %s still has a write owed'):format(vehicleId, tostring(storageType)))
            return false, ('Its %s could not be saved first'):format(tostring(storageType))
        end
    end

    Vehicles.deleteServerEntity(vehicleId)

    -- Trunk, glovebox and ignition contents go with the vehicle, in one transaction.
    local ok, err = Stores.runTransaction({
        { query = 'DELETE FROM `vehicle_inventory` WHERE `vehicleId` = ?', values = { vehicleId } },
        { query = 'DELETE FROM `vehicles` WHERE `vehicleId` = ?',          values = { vehicleId } },
    })

    if not ok then
        print(('[whip_core:vehicle] ERROR deleting vehicle #%d: %s'):format(vehicleId, tostring(err)))
        return false, 'Could not delete the vehicle'
    end

    -- Anything queued for it since (a move during the DELETE's wait) would write rows back under a
    -- vehicle that is gone — dropped now that the delete stands.
    for storageType in pairs(inv or {}) do
        Stores.forget(('vehicle:%s:%s'):format(tostring(vehicleId), tostring(storageType)))
    end

    -- Logged only once the rows are really gone, so a failed delete leaves no false loss behind.
    -- Against the owner's timeline: it was their property, whoever pressed the button.
    for storage, slots in pairs(inv or {}) do
        for _, slotData in pairs(slots) do
            if type(slotData) == 'table' and slotData.item then
                Log.write(ownerCharId, 'lost', {
                    itemKey = slotData.item, amount = slotData.amount or 1,
                    uid     = slotData.metadata and slotData.metadata.uid or nil,
                    detail  = ('in the %s of %s when the vehicle was deleted'):format(storage, tostring(plate)),
                    x = where and where.x, y = where and where.y, z = where and where.z,
                })
            end
        end
    end

    Vehicles._records[vehicleId] = nil
    Vehicles.reindex(vehicleId, nil)
    Vehicles.invCache[vehicleId] = nil
    -- Its position marks with it (the car's save unit is dropped by vehicle_stats.lua's 'deleted' hook).
    Vehicles._dirtyPos[vehicleId] = nil
    Vehicles._lastPos[vehicleId] = nil

    -- The vehicle is gone, so nobody can be looking into it.
    for _, st in ipairs({ 'trunk', 'glovebox', 'key' }) do
        Stores.forgetViews(('vehicle:%s:%s'):format(tostring(vehicleId), st))
    end

    -- Announce it: the entity is already gone for everyone, but the owner's list and anything
    -- keeping per-car state must learn the record is.
    Vehicles.announce('deleted', {
        vehicleId   = vehicleId,
        ownerCharId = ownerCharId,
        wasOut      = wasOut,
    })

    return true
end

-- Owner sync: a client keeps its own list of the vehicles it owns (`vehicleDefs`, from vehiclesSync). Resent on every
-- ownership change through the lifecycle hooks, so no mutation path has to remember.

---@param charId number|nil
local function syncOwnerVehicles(charId)
    if not charId then return end
    local owner = PlayersByCharId and PlayersByCharId[charId]
    if not owner then return end        -- offline: they get the list on their next login
    TriggerClientEvent('whip_core:client:vehiclesSync', owner.source, Vehicles.wireForOwner(charId))
end

Vehicles.onLife('created', function(data)
    syncOwnerVehicles(data.ownerCharId)
end)

Vehicles.onLife('ownerChanged', function(data)
    -- Both sides: the seller's list loses it, the buyer's gains it.
    syncOwnerVehicles(data.from)
    syncOwnerVehicles(data.to)
end)

Vehicles.onLife('deleted', function(data)
    syncOwnerVehicles(data.ownerCharId)
end)

-- Record accessors hand back the live record, for whip_core's own files only. Anything that wants to know about a
-- vehicle uses Vehicles.context, which copies.

function Vehicles.getAll()
    return Vehicles._records
end

-- The plate and owner indexes: find a car by plate, or list a character's, without walking every record. One
-- writer, Vehicles.reindex, called wherever a record comes, goes, or changes plate or owner. A hit is checked
-- against its record before it is believed.

Vehicles._byPlate = {}   -- [plate key] = { [vehicleId] = true }
Vehicles._byOwner = {}   -- [ownerCharId] = { [vehicleId] = true }
local _indexedAs  = {}   -- [vehicleId] = { plate = key, owner = charId }: what the indexes hold for it

--- A plate as the index and getByPlate compare it: upper case, no spaces.
---@param plate any
---@return string|nil
local function plateKey(plate)
    if not plate then return nil end
    return (tostring(plate):upper():gsub('%s+', ''))
end

local function indexAdd(index, key, vehicleId)
    if key == nil or key ~= key then return end   -- NaN cannot be a key; the one writer must not throw
    local set = index[key]
    if not set then set = {}; index[key] = set end
    set[vehicleId] = true
end

local function indexDrop(index, key, vehicleId)
    local set = key ~= nil and key == key and index[key]
    if not set then return end
    set[vehicleId] = nil
    if next(set) == nil then index[key] = nil end
end

--- Bring the indexes in line with a record: new, changed, or gone (`def` nil).
---@param vehicleId number
---@param def table|nil
function Vehicles.reindex(vehicleId, def)
    local plate = def and plateKey(def.plate) or nil
    local owner = def and def.ownerCharId or nil
    local was = _indexedAs[vehicleId]
    if was and def and was.plate == plate and was.owner == owner then return end
    if was then
        indexDrop(Vehicles._byPlate, was.plate, vehicleId)
        indexDrop(Vehicles._byOwner, was.owner, vehicleId)
        _indexedAs[vehicleId] = nil
    end
    if def then
        indexAdd(Vehicles._byPlate, plate, vehicleId)
        indexAdd(Vehicles._byOwner, owner, vehicleId)
        _indexedAs[vehicleId] = { plate = plate, owner = owner }
    end
end

--- Every record indexed afresh (loadAll).
function Vehicles.reindexAll()
    Vehicles._byPlate, Vehicles._byOwner, _indexedAs = {}, {}, {}
    for vehicleId, def in pairs(Vehicles._records) do Vehicles.reindex(vehicleId, def) end
end

-- A street car's setPlate writes def.plate itself (vehicle_claim.lua); an owned car's goes through
-- persist, which reindexes. Core's hooks run first, so nothing that hears the change finds it stale.
Vehicles.onLife('plateChanged', function(data)
    Vehicles.reindex(data.vehicleId, Vehicles._records[data.vehicleId])
end)

--- The ids of a character's cars, lowest first.
---@param charId number
---@return number[]
local function ownedIds(charId)
    local ids = {}
    if charId == nil then return ids end
    for id in pairs(Vehicles._byOwner[charId] or {}) do
        local v = Vehicles._records[id]
        if v and v.ownerCharId == charId then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end
Vehicles.ownedIds = ownedIds

--- The live record. Inside whip_core only, never exported; anything else uses Vehicles.context,
--- which copies.
---@param vehicleId number
---@return table|nil
function Vehicles.getDef(vehicleId)
    return Vehicles._records[vehicleId]
end

--- Every vehicle this character owns, AS LIVE RECORDS. Internal.
---
--- Anything crossing to a client wants Vehicles.wireForOwner instead.
function Vehicles.getByOwner(charId)
    local result = {}
    for i, id in ipairs(ownedIds(charId)) do result[i] = Vehicles._records[id] end
    return result
end

--- What a client is told about the vehicles it owns (the `vehiclesSync` payload): a declared projection, not the
--- record, so a new column doesn't silently reach every client. A car in the world is read off its entity.
---@param charId number
---@return table[]
function Vehicles.wireForOwner(charId)
    local out = {}
    for _, vehicleId in ipairs(ownedIds(charId)) do
        local v = Vehicles._records[vehicleId]
        out[#out + 1] = {
            vehicleId   = vehicleId,
            ownerCharId = v.ownerCharId,
            model       = v.model,
            plate       = v.plate,
            state       = v.state,
            garage      = v.garage,
            -- A copy (shallow is enough): never the record's own stat block.
            vehStats    = (function()
                local s = {}
                if type(v.vehStats) == 'table' then
                    for k, val in pairs(v.vehStats) do s[k] = val end
                end
                return s
            end)(),
        }
    end
    return out
end

--- The car wearing a plate (upper case, spaces ignored): its id and live record. Plates are kept
--- unique, but rows from before that rule may share one: the lowest id, so owned cars come before
--- street cars (ids from a billion).
function Vehicles.getByPlate(plate)
    if not plate then return nil end
    local key = plateKey(plate)
    local best
    for id in pairs(Vehicles._byPlate[key] or {}) do
        local v = Vehicles._records[id]
        if v and plateKey(v.plate) == key and (not best or id < best) then best = id end
    end
    if best then return best, Vehicles._records[best] end
    return nil
end

--- The vehicleId a vehicle reference names (the first argument of every vehicle, stat and data export). A
--- reference says which kind of number it is:
---     { id = vehicleId }   { entity = entity }   { plate = 'ABC123' }   { netId = netId }
--- The same four GetVehicle takes. A bare number on this side is a vehicleId. Anything with a `vehicleId` names
--- that car by id, ahead of its plate.
---@param ref any
---@return number|nil vehicleId
---@return string|nil err  'Invalid vehicleId' for a bad number, 'Vehicle not found' for a reference
---                        that names no car whip knows, 'Invalid vehicle reference' otherwise
function Vehicles.idFromRef(ref)
    local kind = type(ref)
    if kind == 'number' or kind == 'string' then
        local id = Sanitize.id(ref)   -- reject, never clamp
        if not id then return nil, 'Invalid vehicleId' end
        return id
    end
    if kind ~= 'table' then return nil, 'Invalid vehicle reference' end

    local vehicleId
    local byId = ref.id
    if byId == nil then byId = ref.vehicleId end
    if byId ~= nil then
        vehicleId = Sanitize.id(byId)
        if not vehicleId then return nil, 'Invalid vehicleId' end
        return vehicleId
    elseif ref.plate ~= nil then
        if type(ref.plate) ~= 'string' then return nil, 'Invalid vehicle reference' end
        vehicleId = (Vehicles.getByPlate(ref.plate))
    elseif ref.entity ~= nil or ref.netId ~= nil then
        local entity = ref.entity
        if entity == nil then
            local netId = Sanitize.id(ref.netId)
            if not netId then return nil, 'Invalid vehicle reference' end
            entity = NetworkGetEntityFromNetworkId(netId)
        end
        entity = tonumber(entity)
        if entity and entity ~= 0 and DoesEntityExist(entity) then
            vehicleId = Vehicles.getEntityVehicleId(entity)
        end
    else
        return nil, 'Invalid vehicle reference'
    end

    if not vehicleId then return nil, 'Vehicle not found' end
    return vehicleId
end

-- ============================================
-- Properties / Fuel / Position Save
-- ============================================

--- Fields a vehicle's stored appearance may contain, and what each must be. A whitelist (the block can arrive from
--- a client as a free-form table): anything not named is dropped. `plate` and `model` are absent: neither is
--- appearance (Vehicles.spawn sets the plate from `def.plate`).
local APPEARANCE_FIELDS = {
    color1 = 'number', color2 = 'number', pearlescent = 'number', wheelColor = 'number',
    wheelType = 'number', windowTint = 'number', livery = 'number', plateIndex = 'number',
    dirtLevel = 'number', headlightColor = 'number', interiorColor = 'number',
    dashboardColor = 'number',
    turbo = 'boolean', smokeEnabled = 'boolean', xenon = 'boolean',
    customColor1 = 'table', customColor2 = 'table', tyreSmoke = 'table',
    neonColor = 'table', neonEnabled = 'table', extras = 'table',
}

--- The stored appearance with anything unrecognised removed. Returns a new table (the caller's may be the live cache entry).
---@param props table|nil
---@return table
function Vehicles.sanitizeProperties(props)
    if type(props) ~= 'table' then return {} end

    local out = {}

    for key, kind in pairs(APPEARANCE_FIELDS) do
        local v = props[key]

        if type(v) == kind then
            out[key] = v

        -- A boolean field arriving as 0 or 1 is still an answer (natives marshal BOOL as a number).
        -- Anything that is neither a boolean nor 0/1 is still dropped.
        elseif kind == 'boolean' and (v == 0 or v == 1) then
            out[key] = (v == 1)
        end
    end

    -- Mods: keys are the mod slot as a string, values the index within that slot. Anything else is
    -- dropped (it would be saved and sent to every client that spawns the car).
    if type(props.mods) == 'table' then
        local mods = {}
        for slot, index in pairs(props.mods) do
            local n = tonumber(slot)
            if n and n >= 0 and n <= 49 and type(index) == 'number'
                -- 18, 20 and 22 are toggles (turbo, tyre smoke, xenons), stored as the booleans
                -- above. GetVehicleMod returns -1 for a toggle on or off, so a mods entry for one
                -- carries nothing. Dropped here too, so the next write cleans an old record.
                and n ~= 18 and n ~= 20 and n ~= 22
            then
                mods[tostring(math.floor(n))] = math.floor(index)
            end
        end
        out.mods = mods
    end

    -- Extras: keys "1" to "14", each on (true) or off (false), as GetVehicleProperties writes them. Anything else is
    -- dropped (whip_autos sells them one at a time now, so a table of anything was worth closing).
    if type(out.extras) == 'table' then
        local extras = {}
        for k, on in pairs(out.extras) do
            local n = math.tointeger(tonumber(k))
            if on == 0 or on == 1 then on = (on == 1) end
            if n and n >= 1 and n <= 14 and type(on) == 'boolean' then extras[tostring(n)] = on end
        end
        out.extras = extras
    end

    return out
end

--- Vehicles whose entity wears the appearance the record says. Keyed by vehicleId, holding the entity that was
--- dressed (not `true`) so a respawned car doesn't inherit the last entity's confirmation. See Vehicles.isDressed.
Vehicles._dressed = {}

--- Put the stored appearance on the entity, where clients can find it. Called when an entity is bound and whenever
--- the appearance is written.
---@param vehicleId number
---@param entity number|nil   defaults to the vehicle's current entity
---@param def table|nil        defaults to the vehicle's record
function Vehicles.stampAppearance(vehicleId, entity, def)
    def = def or Vehicles._records[vehicleId]
    if not def then return end

    -- getEntity, not the raw index: a reused handle must not be dressed as this car (see getEntity).
    entity = entity or Vehicles.getEntity(vehicleId)
    if not entity or not DoesEntityExist(entity) then return end

    local props = def.properties
    if type(props) ~= 'table' or next(props) == nil then
        -- Nothing stored. Clear rather than write an empty table: an absent key replicates
        -- nothing, and a car with no stored appearance is a stock car that is already correct.
        Sentinel.setEntityKey(entity, VEHICLE_APPEARANCE_KEY, nil)
        return
    end

    Sentinel.setEntityKey(entity, VEHICLE_APPEARANCE_KEY, props)   -- whip's own write
end

--- Record that a client has put the stored appearance onto the entity now in the world. Takes no entity: the one
--- that counts is whichever whip currently tracks.
---@param vehicleId number
---@return boolean marked
function Vehicles.markDressed(vehicleId)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return false end
    Vehicles._dressed[vehicleId] = entity
    return true
end

--- Has the entity in the world been dressed in this vehicle's stored appearance? Decides whether a client's report
--- is believed (a car not yet painted looks stock). True for a car with nothing stored and for session vehicles.
---@param vehicleId number
---@return boolean
function Vehicles.isDressed(vehicleId)
    local def = Vehicles._records[vehicleId]
    if not def then return false end
    if def.session then return true end

    local props = def.properties
    if type(props) ~= 'table' or next(props) == nil then return true end

    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return false end

    -- The entity has to match, not just the id: a car brought back out is a new, undressed entity.
    return Vehicles._dressed[vehicleId] == entity
end

--- The one place a vehicle's appearance is written (the client sync, the customisation export, an
--- admin tool): persist runs the whitelist on the way through.
---@param opts table|nil  Vehicles.persist's opts
function Vehicles.saveProperties(vehicleId, props, opts)
    if type(props) ~= 'table' then return false, 'props must be a table' end
    return Vehicles.persist(vehicleId, { properties = props }, opts)
end

-- Fuel is an ordinary stat (whip_fuel's), set with SetVehicleStat(vehicleId, 'fuel', value, 'refuel:pump') and
-- heard through OnVehicleStatChanged('fuel', function(vehicleId, value, previous) ... end).

-- Vehicle positions, write-behind like VehicleStats: the server reads its own vehicles' positions (no client is
-- trusted with where a car is after a restart), marks what moved, and each car's save unit writes it.

--- Note where a vehicle is, without writing it. Synchronous and database-free: Vehicles.despawn calls it and must
--- not yield between clearing _entities and deleting the entity.
---@param vehicleId number
---@param entity number|nil  defaults to the tracked entity
function Vehicles.markPosition(vehicleId, entity)
    local def = Vehicles._records[vehicleId]
    if not def or def.session then return end

    -- getEntity, not the raw index: a reused handle's coordinates are a stranger's car's.
    entity = entity or Vehicles.getEntity(vehicleId)
    if not entity or not DoesEntityExist(entity) then return end

    local c = GetEntityCoords(entity)
    local pos = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(entity) }

    def.x, def.y, def.z, def.heading = pos.x, pos.y, pos.z, pos.heading
    Vehicles._dirtyPos[vehicleId] = pos
    -- The car's save unit carries it (vehicle_stats.lua, `vehrow:<id>`). Marking does no I/O.
    local unit = Stores.unit('vehrow', vehicleId)
    if unit then Stores.markDirty(unit) end
end

--- The car's position write, for its save unit: the UPDATE and a confirm that clears only this mark and moves
--- _lastPos (what is on disk). Nothing for a car in a transition (the old spot could land after the spawn's write;
--- the mark stays), nor for a car not out on the road (a garaged car has no position; its mark goes).
---@param vehicleId number
---@return table|nil query
---@return function|nil confirm
function Vehicles.pendingPosition(vehicleId)
    local pos = Vehicles._dirtyPos[vehicleId]
    if not pos then return nil end
    if Vehicles._transitionLocks[vehicleId] and not Vehicles._stopping then return nil end
    local def = Vehicles._records[vehicleId]
    if not (def and not def.session and def.state == 'out') then
        Vehicles._dirtyPos[vehicleId] = nil
        return nil
    end
    return {
        query  = 'UPDATE `vehicles` SET `x`=?,`y`=?,`z`=?,`heading`=? WHERE `vehicleId`=?',
        values = { pos.x, pos.y, pos.z, pos.heading, vehicleId },
    }, function()
        if Vehicles._dirtyPos[vehicleId] == pos then Vehicles._dirtyPos[vehicleId] = nil end
        Vehicles._lastPos[vehicleId] = pos
    end
end

--- Write marked positions now, each in its car's save unit. For callers that need them on disk (the
--- final save, whip_test's flush seam); the save thread does this by itself.
---@return boolean ok
function Vehicles.flushPositions()
    local ids = {}
    for vehicleId in pairs(Vehicles._dirtyPos) do ids[#ids + 1] = vehicleId end
    local ok = true
    for _, vehicleId in ipairs(ids) do
        if not Stores.settle('vehrow:' .. tostring(vehicleId)) then ok = false end
    end
    return ok
end

--- Has this vehicle moved far enough since its last write to be worth another one?
local function positionMoved(vehicleId, entity, epsilon)
    local c = GetEntityCoords(entity)
    local last = Vehicles._lastPos[vehicleId]
    if not last then return true end
    return #(c - vector3(last.x, last.y, last.z)) > epsilon
end

do
    -- Both read at each pass, so a change in /whip → Settings takes effect from the next one.
    local function everyMs() return math.max(5000, (Config.VehiclePositionSaveInterval or 30) * 1000) end

    -- Every (lifecycle.lua): one error can't end position saving for the session.
    Every('vehicle position sweep', everyMs, function()
        local epsilon = Config.VehiclePositionEpsilon or 2.0
        -- _entities (whip's own cars, tens of entries), not GetAllVehicles. Each through getEntity:
        -- a reused handle is a stranger's car. (getEntity may clear an entry during pairs; Lua
        -- allows that.)
        for vehicleId in pairs(Vehicles._entities) do
            local def = Vehicles._records[vehicleId]
            local entity = def and not def.session and def.state == 'out' and Vehicles.getEntity(vehicleId)
            if entity then
                if positionMoved(vehicleId, entity, epsilon) then
                    Vehicles.markPosition(vehicleId, entity)
                end
                -- Its damage too, moved or not (a parked car can be shot): vehicle_damage.lua.
                VehicleDamage.sweep(vehicleId, entity)
            end
        end
        -- Marked, not written: each car's save unit writes it.
    end)
end

-- ============================================
-- What a client may say about how a vehicle looks
-- ============================================

--- Do these two describe the same fitted part? Absent and -1 are the same (GetVehicleMod returns -1 for an empty slot).
---@param a number|nil
---@param b number|nil
---@return boolean
local function sameMod(a, b)
    if a == nil or a == -1 then return b == nil or b == -1 end
    return a == b
end

--- The same question for a toggle: nil and false are the same answer.
---@param a boolean|nil
---@param b boolean|nil
---@return boolean
local function sameToggle(a, b)
    return (a or false) == (b or false)
end

--- Scalar appearance fields a client report is checked against, for the held-back log line only.
local REPORTED_SCALARS = {
    'color1', 'color2', 'pearlescent', 'wheelColor', 'wheelType', 'windowTint', 'livery',
    'plateIndex', 'headlightColor', 'interiorColor', 'dashboardColor',
}

--- Take a client's account of how a vehicle looks and keep only what a client can honestly say: dirt, nothing else
--- (every other change is made by trusted code with SetVehicleAppearance). Built from the stored record, not the
--- report, since saveProperties assigns rather than merges.
---@param vehicleId number|nil
---@param props table
---@return table props, table|nil heldBack  what the report disagreed with the record about
function Vehicles.mergeClientProperties(vehicleId, props)
    local reported = Vehicles.sanitizeProperties(props)

    local def    = Vehicles._records[vehicleId]
    local stored = Vehicles.sanitizeProperties((def and def.properties) or {})
    local held   = nil

    local function note(what)
        held = held or {}
        held[#held + 1] = what
    end

    -- Say what disagreed, with both values. Only fields the record stores: a colour nothing ever set
    -- isn't being defended. (For mods and the two toggles, nothing stored means "none".)
    for _, key in ipairs(REPORTED_SCALARS) do
        if reported[key] ~= nil and stored[key] ~= nil and reported[key] ~= stored[key] then
            note(('%s(reported %s, stored %s)'):format(key, tostring(reported[key]), tostring(stored[key])))
        end
    end
    if not sameToggle(stored.turbo, reported.turbo) then
        note(('turbo(reported %s, stored %s)'):format(tostring(reported.turbo), tostring(stored.turbo)))
    end
    if not sameToggle(stored.xenon, reported.xenon) then
        note(('xenon(reported %s, stored %s)'):format(tostring(reported.xenon), tostring(stored.xenon)))
    end
    if type(reported.mods) == 'table' then
        local storedMods = stored.mods or {}
        for slot, index in pairs(reported.mods) do
            if not sameMod(index, storedMods[slot]) then
                note(('mod %s(reported %s, stored %s)'):format(slot, tostring(index), tostring(storedMods[slot])))
            end
        end
    end

    -- The record, with the one field a report is allowed to move.
    local out = stored
    if reported.dirtLevel ~= nil then out.dirtLevel = reported.dirtLevel end

    return out, held
end

-- ============================================
-- Lock State (persisted to DB, applied via server-side native)
-- ============================================

--- Lock or unlock a car: saved, applied to the entity, and announced, only when the state changed:
--- `whip_core:vehicle:lockChanged` with `{ vehicleId, plate, locked, source }`, on lock and unlock.
---@param vehicleId number
---@param locked boolean
---@param source number|nil  the player who did it, when a player did
---@return boolean ok
---@return string|nil err
function Vehicles.setLocked(vehicleId, locked, source)
    locked = locked and true or false
    local wasLocked = Vehicles._records[vehicleId] and Vehicles.isLocked(vehicleId)

    local ok, err = Vehicles.persist(vehicleId, { locked = locked })
    if not ok then return false, err or 'Vehicle not found' end

    -- Apply server-side native (auto-syncs to all clients via OneSync). getEntity, so a reused
    -- handle does not lock a stranger's car.
    local entity = Vehicles.getEntity(vehicleId)
    if entity then
        SetVehicleDoorsLocked(entity, locked and 2 or 1)
    end

    if wasLocked ~= locked then
        local def = Vehicles._records[vehicleId]
        local payload = {
            vehicleId = vehicleId,
            plate     = def and def.plate or nil,
            locked    = locked,
            source    = source,
        }
        WhipEmit('whip_core:vehicle:lockChanged', payload)
    end

    -- A locked boot is shut on whoever is in it: moves are refused at Stores.fromWire, and the
    -- screens close here, in a thread (the close saves, and a lock must not wait on the database).
    if locked and not wasLocked then
        local storeId = ('vehicle:%s:trunk'):format(tostring(vehicleId))
        -- A copy of who is inside: the live set changes as each one is released, and the save yields.
        local inside = {}
        for src in pairs(Stores.viewersOf(storeId)) do inside[#inside + 1] = src end
        if #inside > 0 then
            CreateThread(function()
                for _, src in ipairs(inside) do
                    if Stores.isViewer(src, storeId) then
                        pcall(Vehicles.saveInventory, vehicleId, 'trunk')
                        Vehicles.releaseStorage(vehicleId, 'trunk', src)
                        TriggerClientEvent('whip_core:client:storeClosed', src, storeId)
                    end
                end
                Vehicles.unloadIfIdle(vehicleId)
            end)
        end
    end

    return true
end

---@diagnostic disable-next-line: duplicate-set-field -- the client's Vehicles is a different table
function Vehicles.isLocked(vehicleId)
    local def = Vehicles._records[vehicleId]
    if not def then return true end
    return def.locked ~= false
end

-- ============================================
-- Storage viewers: a boot or glovebox is SHARED, as a stash is (moves are atomic), never one player at a time
-- ============================================

--- Add this player to a compartment's viewer set (shared, as a stash: see Containers.tryOpen). Never refused, so it
--- answers nothing (audit 20, VEH-7: its "true" fed a "Someone else is using this storage" that could not happen).
---@param override string|nil  'lock' | 'admin' — what the open let them past (Stores.addViewer)
function Vehicles.tryOpenStorage(vehicleId, storageType, source, override)
    Stores.addViewer(source, ('vehicle:%s:%s'):format(tostring(vehicleId), storageType), nil, nil, nil, override)
    -- Removed automatically if the acquiring handler errors — see secure.lua.
    TrackInvocationLock(function() Vehicles.releaseStorage(vehicleId, storageType, source) end)
end

function Vehicles.releaseStorage(vehicleId, storageType, source)
    Stores.removeViewer(source, ('vehicle:%s:%s'):format(tostring(vehicleId), storageType))
end

-- ============================================
-- Vehicle Inventory — On-demand Loading
-- ============================================

--- Load a vehicle's storage into the cache.
--- Returns false if the contents could not be read — callers must not write in that case.
---@param vehicleId number
---@return boolean loaded
function Vehicles.loadInventory(vehicleId)
    -- Session vehicles already have invCache populated — no DB load
    local def = Vehicles._records[vehicleId]
    if def and def.session then
        if not Vehicles.invCache[vehicleId] then
            Vehicles.invCache[vehicleId] = { trunk = {}, glovebox = {}, key = {} }
        end
        return true
    end

    local ok, rows = pcall(MySQL.query.await,
        'SELECT * FROM `vehicle_inventory` WHERE `vehicleId` = ?',
        { vehicleId }
    )

    -- On read failure leave the cache UNPOPULATED. An empty-but-present cache makes
    -- buildSaveQueries emit `DELETE FROM vehicle_inventory WHERE vehicleId = ? AND storageType = ?`,
    -- so caching {} here would empty the vehicle on the next save.
    if not ok then
        print(('[whip_core:vehicle] ERROR loading inventory for vehicle #%d: %s'):format(vehicleId, tostring(rows)))
        return false
    end

    -- A cache that appeared while this load waited wins (see Containers.loadInventory).
    if Vehicles.invCache[vehicleId] then return true end

    local inv = { trunk = {}, glovebox = {}, key = {} }
    if rows then
        for _, row in ipairs(rows) do
            -- type-checked: one hand-edited row must not make the boot unopenable
            local meta = Inventory.readMetadata(row.metadata, ('vehicle #%s %s slot %s')
                :format(tostring(vehicleId), tostring(row.storageType or 'trunk'), tostring(row.slot)))

            local stype = row.storageType or 'trunk'
            if not inv[stype] then inv[stype] = {} end
            inv[stype][row.slot] = {
                item     = row.item,
                amount   = row.amount or 1,
                metadata = meta,
            }
        end
    end

    Vehicles.invCache[vehicleId] = inv
    -- The rows just read are what is on disk: each compartment's save snapshot, so the first save
    -- after opening a boot is a diff. A cache is only dropped with nothing owed, so a reload reads
    -- the last write.
    Vehicles.seedStorageSnapshots(inv)
    -- Retired items (RetireItem) come out as it opens, logged, and the flush deletes their rows.
    RetiredItems.sweepVehicle(vehicleId)
    return true
end

-- Snapshots of the last CONFIRMED-WRITTEN contents, weak-keyed on the storage table, so unloading a
-- vehicle takes its snapshots with it. See Inventory.buildSaveQueries.
local _storageSnapshots = setmetatable({}, { __mode = 'k' })

--- Record a vehicle's compartments just read from the database as written (see Vehicles.loadInventory).
---@param inv table  { trunk = {...}, glovebox = {...}, key = {...} }
function Vehicles.seedStorageSnapshots(inv)
    for storageType, store in pairs(inv) do
        if (storageType == 'trunk' or storageType == 'glovebox' or storageType == 'key') and type(store) == 'table' then
            local snap = {}
            for slot, data in pairs(store) do
                local slotNum = tonumber(slot)
                if data and data.item and slotNum then
                    snap[slotNum] = { item = data.item, amount = data.amount or 1, metadata = Stores.copyMetadata(data.metadata) }
                end
            end
            _storageSnapshots[store] = snap
        end
    end
end

--- Forget one storage's save snapshot, so its next save writes everything (the store kind's `invalidate`).
---@param vehicleId number
---@param storageType string
function Vehicles.invalidateStorageSnapshot(vehicleId, storageType)
    local inv = Vehicles.invCache[vehicleId]
    local store = inv and inv[storageType]
    if store then _storageSnapshots[store] = nil end
end

--- Build SQL queries for saving a vehicle storage inventory.
---@param vehicleId number
---@param storageType string  'trunk', 'glovebox', or 'key'
---@return table[]  Array of {query=string, values=table}
---@return function confirm  run once the queries have committed: the next save writes only what changed since
function Vehicles.buildSaveQueries(vehicleId, storageType)
    local noop = function() end
    local inv = Vehicles.invCache[vehicleId]
    if not inv or not inv[storageType] then return {}, noop end

    local def = Vehicles._records[vehicleId]
    if def and def.session then return {}, noop end

    -- `storageType` is ENUM('trunk','glovebox','key'); under STRICT_TRANS_TABLES anything
    -- else is a hard error that aborts the whole transaction.
    if storageType ~= 'trunk' and storageType ~= 'glovebox' and storageType ~= 'key' then
        print(('[whip_core:vehicle] REFUSED save for vehicle #%s — invalid storageType "%s"')
            :format(tostring(vehicleId), tostring(storageType)))
        return {}, noop
    end

    local store    = inv[storageType]
    local queries  = {}
    local values   = {}
    local prev     = _storageSnapshots[store]
    local nextSnap = {}
    local present  = {}

    for slot, data in pairs(store) do
        if data and data.item then
            local slotNum = tonumber(slot)
            if not slotNum or slotNum < 1 or slotNum > 65535 or slotNum % 1 ~= 0 then
                print(('[whip_core:vehicle] SKIPPED out-of-range slot %s in vehicle #%s/%s')
                    :format(tostring(slot), tostring(vehicleId), storageType))
            else
                present[slotNum] = true

                local prevSlot = prev and prev[slotNum]
                local unchanged = prevSlot
                    and prevSlot.item == data.item
                    and prevSlot.amount == (data.amount or 1)
                    and Stores.metadataEquivalent(prevSlot.metadata, data.metadata)

                -- Encoded first and guarded: a row that cannot be written is skipped (it keeps its
                -- last saved state, and is present so the diff won't delete it) rather than failing
                -- the whole save and everything linked to it.
                local okMeta, metaJson = true, '{}'
                if not unchanged and data.metadata then okMeta, metaJson = pcall(json.encode, data.metadata) end

                if unchanged then
                    nextSnap[slotNum] = prevSlot
                elseif not okMeta then
                    nextSnap[slotNum] = prevSlot
                    print(('[whip_core:vehicle] SKIPPED %s in slot %d of vehicle #%s/%s — its metadata cannot be saved: %s')
                        :format(tostring(data.item), slotNum, tostring(vehicleId), storageType, tostring(metaJson)))
                else
                    nextSnap[slotNum] = {
                        item     = data.item,
                        amount   = data.amount or 1,
                        -- A COPY: metadata is held by reference and mutated in place.
                        metadata = Stores.copyMetadata(data.metadata),
                    }
                    values[#values + 1] = {
                        vehicleId, storageType, slotNum, data.item,
                        data.amount or 1,
                        metaJson,
                    }
                end
            end
        end
    end

    if #values > 0 then
        local placeholders = {}
        local params = {}
        for _, v in ipairs(values) do
            placeholders[#placeholders + 1] = '(?,?,?,?,?,?)'
            for _, p in ipairs(v) do params[#params + 1] = p end
        end
        -- An upsert, not REPLACE INTO (a delete and an insert) — see Inventory.buildSaveQueries.
        queries[#queries + 1] = {
            query = 'INSERT INTO `vehicle_inventory` (`vehicleId`,`storageType`,`slot`,`item`,`amount`,`metadata`) VALUES '
                .. table.concat(placeholders, ', ')
                .. ' ON DUPLICATE KEY UPDATE `item` = VALUES(`item`), `amount` = VALUES(`amount`), `metadata` = VALUES(`metadata`)',
            values = params,
        }
    end

    if prev then
        -- Only the slots that were there and are not any more (smaller and safer than NOT IN).
        local goneKeys, goneParams = {}, { vehicleId, storageType }
        for slotNum in pairs(prev) do
            if not present[slotNum] then
                goneKeys[#goneKeys + 1] = '?'
                goneParams[#goneParams + 1] = slotNum
            end
        end
        if #goneKeys > 0 then
            queries[#queries + 1] = {
                query = 'DELETE FROM `vehicle_inventory` WHERE `vehicleId` = ? AND `storageType` = ? AND `slot` IN ('
                    .. table.concat(goneKeys, ', ') .. ')',
                values = goneParams,
            }
        end
    else
        -- First save for this storage: what is on disk is unknown, so write everything and prune
        -- anything else.
        local keepKeys, keepParams = {}, { vehicleId, storageType }
        for slotNum in pairs(present) do
            keepKeys[#keepKeys + 1] = '?'
            keepParams[#keepParams + 1] = slotNum
        end
        if #keepKeys > 0 then
            queries[#queries + 1] = {
                query = 'DELETE FROM `vehicle_inventory` WHERE `vehicleId` = ? AND `storageType` = ? AND `slot` NOT IN ('
                    .. table.concat(keepKeys, ', ') .. ')',
                values = keepParams,
            }
        else
            queries[#queries + 1] = {
                query = 'DELETE FROM `vehicle_inventory` WHERE `vehicleId` = ? AND `storageType` = ?',
                values = { vehicleId, storageType },
            }
        end
    end

    local deleteRows = 0
    for _, q in ipairs(queries) do
        if q.query:find('DELETE', 1, true) then
            deleteRows = deleteRows + math.max(0, #q.values - 2)   -- vehicleId, storageType
        end
    end
    local ifFull = 0
    for _ in pairs(present) do ifFull = ifFull + 1 end
    Stores.recordWrite(#values + deleteRows, ifFull)

    local function confirm()
        _storageSnapshots[store] = nextSnap
    end

    return queries, confirm
end

--- Save vehicle storage inventory to DB as an atomic transaction.
---@param vehicleId number
---@param storageType string
---@return boolean ok
---@return string|nil err
function Vehicles.saveInventory(vehicleId, storageType)
    -- "Not persistable" is asked directly: an unchanged trunk legitimately builds no queries.
    local def = Vehicles._records[vehicleId]
    if def and def.session then return false, 'not persistable' end
    local inv = Vehicles.invCache[vehicleId]
    if not inv or not inv[storageType] then return false, 'not persistable' end

    -- The kind's durability, only after the guards above (a session vehicle owns no rows).
    local store = Stores.vehicle(vehicleId, storageType)
    if store and Stores.isDeferred(store.kind) then
        Stores.markDirty(store)
        return true
    end

    local built, queries, confirm = pcall(Vehicles.buildSaveQueries, vehicleId, storageType)
    if not built then
        print(('[whip_core:vehicle] ERROR building save for vehicle #%s/%s: %s')
            :format(tostring(vehicleId), tostring(storageType), tostring(queries)))
        return false, tostring(queries)
    end

    -- Nothing changed. That is a success.
    if #queries == 0 then
        return true
    end

    local ok, err = Stores.runTransaction(queries)
    if not ok then
        print(('[whip_core:vehicle] ERROR saving vehicle #%s/%s: %s')
            :format(tostring(vehicleId), tostring(storageType), tostring(err)))
        return false, err
    end

    confirm()
    return true
end

--- Write out everything this vehicle still owes, across every cached storage type (dropping the cache drops up to
--- three units, and each must be written).
---@param vehicleId number
---@return boolean ok
---@return string|nil err
function Vehicles.flushStorage(vehicleId)
    local inv = Vehicles.invCache[vehicleId]
    if not inv then return true end

    for storageType in pairs(inv) do
        local store = Stores.vehicle(vehicleId, storageType)
        if store then
            local ok, err = Stores.teardown(store)
            if not ok then return false, err end
        end
    end

    return true
end

--- Drop a vehicle's storage from memory, writing anything still owed first (as Containers.unloadInventory).
---@param vehicleId number
---@return boolean unloaded
function Vehicles.unloadInventory(vehicleId)
    -- A session vehicle's cache is its only copy (no row; a reload builds empty compartments).
    -- Never dropped here; it goes when the vehicle is despawned, not when a panel closes.
    local def = Vehicles._records[vehicleId]
    if def and def.session then
        return false
    end

    local ok, err = Vehicles.flushStorage(vehicleId)
    if not ok then
        print(('[whip_core:vehicle] REFUSING to unload vehicle #%s storage — its pending write failed: %s')
            :format(tostring(vehicleId), tostring(err)))
        return false
    end

    -- Asked again after the flush's yield (as Containers.unloadInventory): someone may have reopened
    -- it, or a change may be owed. Either keeps the cache; the next close unloads it.
    for _, st in ipairs({ 'trunk', 'glovebox', 'key' }) do
        local unit = ('vehicle:%s:%s'):format(tostring(vehicleId), st)
        if Stores.viewerCount(unit) > 0 or Stores.owes(unit) then
            return false
        end
    end

    Vehicles.invCache[vehicleId] = nil
    return true
end

--- Drop a vehicle's storage cache only if no compartment of it is still open (the cache is per vehicle, viewers per compartment).
---@param vehicleId number
---@return boolean unloaded
function Vehicles.unloadIfIdle(vehicleId)
    for _, st in ipairs({ 'trunk', 'glovebox', 'key' }) do
        if Stores.viewerCount(('vehicle:%s:%s'):format(tostring(vehicleId), st)) > 0 then
            return false   -- still in use by someone
        end
    end

    return Vehicles.unloadInventory(vehicleId)
end

-- ============================================
-- Vehicle Inventory — Slot Operations
-- ============================================

function Vehicles.getSlot(vehicleId, storageType, slot)
    local inv = Vehicles.invCache[vehicleId]
    if not inv or not inv[storageType] then return nil end
    return inv[storageType][slot]
end

--- Write a storage slot. REFUSES if this vehicle's storage was never successfully loaded.
--- See Containers.setSlot for why auto-creating the cache here is a data-destruction path.
---@return boolean written
function Vehicles.setSlot(vehicleId, storageType, slot, item, amount, metadata)
    local inv = Vehicles.invCache[vehicleId]
    if not inv then
        print(('[whip_core:vehicle] REFUSED setSlot on vehicle #%s/%s slot %s — storage not loaded')
            :format(tostring(vehicleId), tostring(storageType), tostring(slot)))
        return false
    end
    if not inv[storageType] then
        inv[storageType] = {}
    end
    inv[storageType][slot] = {
        item     = item,
        amount   = amount or 1,
        metadata = metadata,
    }
    return true
end

function Vehicles.clearSlot(vehicleId, storageType, slot)
    local inv = Vehicles.invCache[vehicleId]
    if inv and inv[storageType] then
        inv[storageType][slot] = nil
    end
end

--- The weight shown for a trunk or glovebox: the same answer the movers use.
function Vehicles.getWeight(vehicleId, storageType)
    local store = Stores.vehicle(vehicleId, storageType)
    return store and Stores.weightOf(store) or 0
end

--- Serialize storage inventory for NUI (string keys)
function Vehicles.serializeStorage(vehicleId, storageType)
    local inv = Vehicles.invCache[vehicleId]
    if not inv or not inv[storageType] then return {} end
    local result = {}
    for slot, data in pairs(inv[storageType]) do
        result[tostring(slot)] = {
            item     = data.item,
            amount   = data.amount,
            metadata = data.metadata,
        }
    end
    return result
end

-- ============================================
-- Context — everything whip knows about a vehicle
-- ============================================

-- Seat questions: cheap (three natives, no yield, allocation or database), for questions asked many times a
-- second. GetVehicleContext answers these too but scans every player.

--- Is this player in the driver's seat of this vehicle?
---@param source number
---@param vehicleId number
---@return boolean
function Vehicles.isPlayerDriving(source, vehicleId)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return false end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end

    -- Seat -1 is the driver. Ask the seat: `GetVehiclePedIsIn` answers true for a passenger.
    return GetPedInVehicleSeat(entity, -1) == ped
end

--- Is this player anywhere inside this vehicle?
---@param source number
---@param vehicleId number
---@return boolean
function Vehicles.isPlayerIn(source, vehicleId)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return false end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end

    return GetVehiclePedIsIn(ped, false) == entity
end

--- Who is sitting in a vehicle, as far as the server can tell. Players only (ambient peds never reach the server),
--- so an empty list means nobody with a character in it, not an empty car.
---@param entity number
---@return table[]
local function serverOccupants(entity)
    local out = {}
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == entity then
            local player = Players and Players[src] or nil

            -- Seat is best-effort: GetVehicleMaxNumberOfPassengers is not a server native, so the
            -- bound is hard-coded and the probe is pcall'd.
            local seat = nil
            pcall(function()
                for s = -1, 15 do
                    if GetPedInVehicleSeat(entity, s) == ped then seat = s break end
                end
            end)

            out[#out + 1] = {
                serverId = src,
                charId   = player and player.charId or nil,
                name     = player and player.fullName or nil,
                seat     = seat,
            }
        end
    end
    return out
end

--- Everything whip knows about a vehicle, in one call. Always a copy. Storage (and keyInIgnition) is reported only
--- if already loaded (reading is not opening). Occupants are opt-in: the expensive part.
---@param vehicleId number
---@param opts table|nil  { occupants = true } to include who is sitting in it
---@return table|nil
function Vehicles.context(vehicleId, opts)
    local def = Vehicles._records[vehicleId]
    if not def then return nil end

    local wantOccupants = opts and opts.occupants and true or false

    local entity = Vehicles.getEntity(vehicleId)
    local cat = def.model and VehicleCatalog.rows[tostring(def.model):lower()] or nil

    local coords, heading
    if entity then
        coords  = GetEntityCoords(entity)
        heading = GetEntityHeading(entity)
    elseif def.x and def.y and def.z then
        coords  = vector3(def.x, def.y, def.z)
        heading = def.heading
    end

    local ownerName, ownerOnline = nil, false
    local ownerPlayer = def.ownerCharId and PlayersByCharId and PlayersByCharId[def.ownerCharId] or nil
    if ownerPlayer then
        ownerName   = ownerPlayer.fullName
        ownerOnline = true
    end

    -- Only touch storage if something else already loaded it.
    local storage, storageLoaded = nil, false
    if Vehicles.invCache[vehicleId] then
        storageLoaded = true
        storage = {}
        for _, st in ipairs({ 'trunk', 'glovebox' }) do
            -- getStorageConfig returns one table: { slots, maxWeight }.
            local cfg = Vehicles.getStorageConfig(vehicleId, st) or {}
            storage[st] = {
                slots     = cfg.slots,
                maxWeight = cfg.maxWeight,
                used      = Vehicles.getWeight(vehicleId, st),
            }
        end
    end

    local propsCopy = nil
    if type(def.properties) == 'table' then
        propsCopy = {}
        for k, v in pairs(def.properties) do propsCopy[k] = v end
    end

    return {
        -- identity
        vehicleId   = vehicleId,
        plate       = def.plate,
        model       = def.model,
        displayName = cat and cat.displayName or nil,
        class       = cat and cat.class or nil,
        vehType     = def.vehType or 'automobile',
        session     = def.session or false,
        -- A temporary car (SpawnTempVehicle: a rental, a job van) is a session car too, so
        -- `session` alone can't tell it from street traffic (a tow job must not take a rental).
        temp        = def.temp ~= nil,
        -- Cannot be lockpicked or its ignition hacked (SpawnTempVehicle opts.secure: a run's car).
        secure      = def.secure == true,

        -- ownership
        owner = {
            charId = def.ownerCharId,
            name   = ownerName,
            online = ownerOnline,
        },

        -- where it is
        state   = def.state,
        reservation = def.reservation,
        garage  = def.garage,
        coords  = coords,
        heading = heading,

        -- what it is doing
        spawned = entity ~= nil,
        entity  = entity,
        netId   = Vehicles.getNetId(vehicleId),
        locked  = def.locked ~= false,

        -- Who is in it. Absent unless asked for, and `nil` rather than `{}` on purpose: an empty
        -- list means the car is empty, and a caller that did not ask should not be told either.
        occupants            = (wantOccupants and entity) and serverOccupants(entity) or nil,
        occupantsPlayersOnly = wantOccupants or nil,

        -- what it carries
        stats         = VehicleStats and VehicleStats.getAll(vehicleId) or nil,

        -- Data a resource has attached to this car: not stats, not mods, not storage.
        -- Always a table, never nil.
        data          = VehicleData and VehicleData.getAll(vehicleId) or {},

        properties    = propsCopy,
        storage       = storage,
        storageLoaded = storageLoaded,

        -- Deliberately absent: keyInIgnition. Asking lazy-loads the vehicle's inventory, and this
        -- call must not have side effects. Use Vehicles.hasKeyInIgnition when you actually mean to.
    }
end

-- A vehicle has three shapes:
--   Vehicles._records[id]     the truth, server-only, never leaves
--   Vehicles.context(id)      the full snapshot for GetVehicle (a copy)
--   Vehicles.wireForOwner()   the owner's list for vehiclesSync (identity, state, cached stats)

-- Key validation + giveKey helper: see server/items/vehicle_key.lua

-- ============================================
-- Entity Persistence — Server-side tracking
-- ============================================

--- Bind (or, with nil, unbind) a vehicleId's entity. The only writer of Vehicles._entities and Vehicles._byEntity.
---@param vehicleId number
---@param entity number|nil
local function setTracked(vehicleId, entity)
    local old = Vehicles._entities[vehicleId]
    if old ~= nil and Vehicles._byEntity[old] == vehicleId then Vehicles._byEntity[old] = nil end
    Vehicles._entities[vehicleId] = entity
    if entity ~= nil then Vehicles._byEntity[entity] = vehicleId end
end

--- Bind an entity to a vehicleId and stamp its identity. Shared by Vehicles.spawn (built it) and Vehicles.adopt
--- (found it in the world).
---@param vehicleId number
---@param entity number
---@param def table
local function bindEntity(vehicleId, entity, def)
    SetEntityOrphanMode(entity, 2)      -- KeepEntity: survives its owner disconnecting or driving off
    -- At birth. The shared world, unless a temp car was asked for in another (def.bucket: the
    -- Director's test for a builder in a world of their own).
    SetEntityRoutingBucket(entity, def.bucket or 0)

    -- The index BEFORE the first statebag write: each write echoes into the Sentinel, whose truth
    -- functions resolve the entity through this index (stamping first would un-stamp the car).
    setTracked(vehicleId, entity)
    Vehicles._fingerprint[vehicleId] = { netId = NetworkGetNetworkIdFromEntity(entity), model = GetEntityModel(entity) }

    -- The identity, replicated: any client can answer "what vehicle is this?" from the entity.
    Sentinel.setEntityKey(entity, VEHICLE_STATE_KEY, vehicleId)   -- whip's own write

    -- Set only when true, never to `false`: an absent key replicates nothing.
    Sentinel.setEntityKey(entity, VEHICLE_SESSION_KEY, def.session or nil)

    -- How it should look, on the entity: paint and mods are client natives, so any client that
    -- streams it in dresses it (at boot there is nobody to send an event to).
    Vehicles.stampAppearance(vehicleId, entity, def)

    -- Owned and temporary cars are told their lock state; street cars are asked (their doors are as
    -- GTA left them). A just-created temp car would always answer "unlocked".
    if def.session and not def.temp then
        def.locked = (GetVehicleDoorLockStatus(entity) == 2)
    else
        SetVehicleDoorsLocked(entity, def.locked ~= false and 2 or 1)
    end
end

--- Is this entity handle, which the index holds for vehicleId, still that car? Handles are reused, and the stamp is
--- client-writable; the network id and model recorded at bind are not, so they decide.
---@param vehicleId number
---@param entity number
---@return boolean
local function isOurEntity(vehicleId, entity)
    if not entity or not DoesEntityExist(entity) then return false end
    -- The index answers first: a handle since bound to another vehicle is not this one's, whatever
    -- the fingerprint says (a same-model car can take a reused handle). nil (never indexed) falls through.
    local indexed = Vehicles._byEntity[entity]
    if indexed ~= nil and indexed ~= vehicleId then return false end
    -- Then the fingerprint: network id, model and KeepEntity (every car whip binds is orphan mode 2, an ambient car is
    -- not). Its "no" is final: the stamp can be orphaned onto the next car (FiveM #3289), so it is asked only for a
    -- handle with no fingerprint.
    local fp = Vehicles._fingerprint[vehicleId]
    if fp ~= nil then
        return NetworkGetNetworkIdFromEntity(entity) == fp.netId and GetEntityModel(entity) == fp.model
            and (not GetEntityOrphanMode or GetEntityOrphanMode(entity) == 2)
    end
    return Vehicles.readEntityStamp(entity) == vehicleId
end

--- The entity currently in the world for a vehicleId, or nil.
---@param vehicleId number
---@return number|nil
function Vehicles.getEntity(vehicleId)
    local entity = Vehicles._entities[vehicleId]
    if not entity then return nil end
    -- Exists and is still this car (isOurEntity). A handle that isn't is forgotten, so a car removed
    -- outside whip reads as lost (see the garage bays), not "out" forever.
    if isOurEntity(vehicleId, entity) then return entity end
    setTracked(vehicleId, nil)
    Vehicles._fingerprint[vehicleId] = nil
    return nil
end

--- Why a car cannot be brought out for this player just now, or nil. Asked by every spawn made for a player. A
--- builder in Isolate world (their own routing bucket) is refused: whip's cars are made in the shared world, and
--- leaving isolation moves only the player.
---@param source number|nil
---@return string|nil why
function Vehicles.cannotBringOutFor(source)
    if source and Director and Director.isolated and Director.isolated[source] then
        return 'Leave Isolate world first: cars come out in the shared world'
    end
    return nil
end

--- The same question for a seller to ask BEFORE charging: a dealership or a rental desk refuses
--- first instead of charging and refunding. CreateOwnedVehicle{spawnAt} still asks itself.
exports('CanBringOutVehicleFor', function(source)
    local why = Vehicles.cannotBringOutFor(source)
    if why then return false, why end
    return true
end)

--- Is this a vehicle the game has? For a seller to keep cars that do not exist out of its stock
--- (Vehicles.modelExists): true, false, or nil when no player's game has reported yet.
exports('VehicleModelExists', function(model)
    return Vehicles.modelExists(model)
end)

--- What is standing on a spot a car is about to be spawned on, if anything: a vehicle, or a player (GTA throws a car
--- spawned inside another out of it). One rule for every spawn a player or satellite asks for.
--- Only the same world counts: opts.bucket is the world the new car is born in (0, the shared world, by default).
--- A garage bay (opts.heading given) is asked by its outline (shared/garage_bay.lua): a car blocks it only when its
--- body would overlap; the server has no model sizes, so a car is taken as large.
---@param x number
---@param y number
---@param z number
---@param opts table|nil  { radius? (default Config.GarageSpotRadius or 3.5), heading? (a bay's), exceptSource?, exceptEntity?, bucket? (default 0) }
---@return string|nil why  nil when the spot is clear
function Vehicles.spotBlocked(x, y, z, opts)
    opts = opts or {}
    local centre = vector3(x + 0.0, y + 0.0, z + 0.0)
    local radius = opts.radius or Config.GarageSpotRadius or 3.5
    local bayHeading = tonumber(opts.heading)
    local bucket = tonumber(opts.bucket) or 0

    for _, veh in ipairs(GetAllVehicles() --[[@as integer[] ]]) do   -- the server native: a list
        if veh ~= opts.exceptEntity and DoesEntityExist(veh) and GetEntityRoutingBucket(veh) == bucket then
            local c = GetEntityCoords(veh)
            local inIt
            if bayHeading then
                inIt = GarageBay.overlaps(centre.x, centre.y, centre.z, bayHeading, c.x, c.y, c.z, GetEntityHeading(veh))
            else
                inIt = #(c - centre) < radius
            end
            if inIt then return 'Something is already parked in that spot' end
        end
    end

    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id) --[[@as integer]]   -- GetPlayers answers server ids as digits
        if src ~= opts.exceptSource and GetPlayerRoutingBucket(src) == bucket then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 and #(GetEntityCoords(ped) - centre) < 2.5 then
                return 'Someone is standing in that spot'
            end
        end
    end
    return nil
end

--- The vehicleIds whip has an entity for — the cars in the world — as a fresh list, safe to walk
--- while cars spawn and despawn. Not checked for existence: ask getEntity per id, which is.
---@return number[]
function Vehicles.spawnedIds()
    local ids = {}
    for vehicleId in pairs(Vehicles._entities) do ids[#ids + 1] = vehicleId end
    return ids
end

--- The entity handles of those same cars, as a fresh list, unconfirmed (a handle may no longer exist or have been
--- reused). For the Sentinel's sweep; anything wanting "this car's entity" asks getEntity.
---@return number[]
function Vehicles.spawnedEntities()
    local entities = {}
    for _, entity in pairs(Vehicles._entities) do entities[#entities + 1] = entity end
    return entities
end

--- The netId currently in the world for a vehicleId, or nil. Derived, not stored, so it can't go stale.
---@param vehicleId number
---@return number|nil
function Vehicles.getNetId(vehicleId)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return nil end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId <= 0 then return nil end
    return netId
end

--- Reverse lookup: entity handle to vehicleId, from the index and confirmed as this car (the forward map must agree
--- and isOurEntity confirms the fingerprint). Not the stamp alone: it can outlive its car (FiveM #3289) and a
--- statebag read is costly. Before Vehicles.reconcileWorld has run at boot the index is empty, so this answers nil
--- for a car from the previous run; reconcileWorld reads the raw stamp instead.
---@param entity number
---@return number|nil
function Vehicles.getEntityVehicleId(entity)
    if not entity or entity == 0 then return nil end
    local id = Vehicles._byEntity[entity]
    if id == nil or Vehicles._entities[id] ~= entity then return nil end
    if isOurEntity(id, entity) then return id end
    return nil
end

--- Read the identity stamp off the entity, ignoring the index. The raw stamp may be stale: use it only to confirm an
--- entity you already hold for a known id, or at boot before the index is populated. Otherwise use getEntityVehicleId.
---@param entity number
---@return number|nil
function Vehicles.readEntityStamp(entity)
    if not entity or entity == 0 then return nil end
    local id = Entity(entity).state[VEHICLE_STATE_KEY]
    -- A whole number whip could have made, or no stamp (see VEHICLE_ID_MAX): a client can write this bag.
    id = type(id) == 'number' and math.tointeger(id) or nil
    if not id or id < 1 or id > VEHICLE_ID_MAX then return nil end
    return id
end

--- Take an entity that already exists in the world (a street car) and make it whip's: identity and tracking only.
---@param vehicleId number
---@param entity number
---@return boolean
function Vehicles.adopt(vehicleId, entity)
    local def = Vehicles._records[vehicleId]
    if not def then return false end
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end

    -- Already bound to this same entity: nothing to do.
    if Vehicles._entities[vehicleId] == entity then return true end

    -- It must be a vehicle: the handle comes from a client-sent network id, which can address any entity.
    if GetEntityType(entity) ~= 2 then return false end

    -- Never take an entity that already belongs to another vehicle: the only caller reaches here
    -- from a client-sent net id, and everything downstream (glovebox, ignition, lock) trusts the
    -- binding. Asked of the index and fingerprint, never the client-writable stamp.
    local holder = Vehicles.getTrackedVehicleIdForEntity(entity)
    if holder and holder ~= vehicleId and isOurEntity(holder, entity) then return false end

    -- And never steal an identity still in use: if the vehicle's entity still exists and is still
    -- this car, a second entity with the same plate is a copy. (A street car whose entity is gone is
    -- not re-adopted by plate: registerSessionVehicle drops its record first.)
    local current = Vehicles._entities[vehicleId]
    if current and current ~= entity and isOurEntity(vehicleId, current) then
        return false
    end

    -- The plate on the entity has to be the plate this def was allocated for. A session def is
    -- created FROM a plate the client claimed; if the entity in front of us carries a different
    -- one, the two do not describe the same car and one of them is a lie.
    if def.plate then
        local entPlate = GetVehicleNumberPlateText(entity)
        if not entPlate or entPlate:upper():gsub('%s+', '') ~= def.plate:upper():gsub('%s+', '') then
            return false
        end
    end

    -- Let go of the old binding quietly (not Vehicles.despawn, which would announce `released` for
    -- an id being rebound): by here it is nothing, or an entity that is no longer this car.
    setTracked(vehicleId, nil)
    Vehicles._fingerprint[vehicleId] = nil
    Vehicles._dressed[vehicleId] = nil

    bindEntity(vehicleId, entity, def)
    return true
end

--- Put a vehicle into the world: where an owned car's entity is created (Vehicles.spawnTemp builds temp cars itself,
--- so a step added here for every spawned car must be added there too). Despawns whatever it had first, so a second
--- entity for one vehicleId can't exist.
---@param vehicleId number
---@param x number|nil
---@param y number|nil
---@param z number|nil
---@param heading number|nil
---@return number|nil entity
---@return number|string netIdOrError
--- The body of Vehicles.spawn, run while the transition lock is held. Never call it directly.
local function spawnLocked(vehicleId, def, x, y, z, heading)
    x = tonumber(x) or def.x
    y = tonumber(y) or def.y
    z = tonumber(z) or def.z
    heading = tonumber(heading) or def.heading or 0.0

    if not (x and y and z) then
        return nil, 'No position to spawn at'
    end

    Vehicles.despawn(vehicleId)

    local modelHash = GetHashKey(def.model)
    local vehType   = def.vehType or 'automobile'

    local entity = CreateVehicleServerSetter(modelHash, vehType, x + 0.0, y + 0.0, z + 0.0, heading + 0.0)
    if not entity or entity == 0 then
        print(('[whip_core:vehicle] spawn FAILED for #%d (model=%s, type=%s)')
            :format(vehicleId, tostring(def.model), tostring(vehType)))
        return nil, 'Could not create the vehicle'
    end

    -- Check the netId first: an entity no client can reach is litter (OrphanMode 2, forever). And a
    -- netId of 0 is truthy in Lua, so it must not be returned.
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId <= 0 then
        DeleteEntity(entity)
        print(('[whip_core:vehicle] spawn #%d produced no usable netId — deleted'):format(vehicleId))
        return nil, 'Vehicle did not network'
    end

    if def.plate then
        SetVehicleNumberPlateText(entity, Vehicles.displayPlate(def.plate))
    end

    bindEntity(vehicleId, entity, def)

    -- The vehicle is in the world: record that, and where (or the boot restore can't place it).
    -- Self-correct the type in the same write: a real entity says what it is, so the next spawn
    -- builds the right kind.
    local fields = {
        state   = 'out',
        x       = x + 0.0,
        y       = y + 0.0,
        z       = z + 0.0,
        heading = heading + 0.0,
    }

    local actualType = GetVehicleType(entity)
    if actualType and actualType ~= '' and actualType ~= vehType then
        fields.vehType = actualType
    end

    -- keepOnFailure: the car IS in the world, so the record says so whether or not the row follows.
    local ok, err = Vehicles.persist(vehicleId, fields, { keepOnFailure = true })
    if not ok then
        -- Not fatal — the car IS in the world and usable. But it will come back in the wrong place,
        -- or not at all, so it must not pass quietly.
        print(('[whip_core:vehicle] spawn #%d: could not record state/position: %s')
            :format(vehicleId, tostring(err)))
    end

    -- Seed the sweep's last position, and drop what the despawn above queued (where the car WAS,
    -- which would otherwise be written over the spot just saved).
    Vehicles._lastPos[vehicleId] = { x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = heading + 0.0 }
    Vehicles._dirtyPos[vehicleId] = nil

    Vehicles.announce('spawned', {
        vehicleId = vehicleId,
        entity    = entity,
        netId     = netId,
        plate     = def.plate,
        model     = def.model,
        session   = false,
    })

    return entity, netId
end

function Vehicles.spawn(vehicleId, x, y, z, heading)
    local def = Vehicles._records[vehicleId]
    if not def then return nil, 'Vehicle not found' end
    if heldBy(def) then return nil, 'Vehicle is in custody' end

    -- A session vehicle is a street car whip adopted (Vehicles.adopt), not one it built.
    if def.session then return nil, 'Session vehicles are adopted, not spawned' end

    -- A model the game has (Vehicles.modelExists): a car made before the check, or an add-on car whose
    -- resource is gone, says so instead of "coming out" as nothing.
    local missing = Vehicles.missingModel(def.model)
    if missing then return nil, missing end

    -- One spawn at a time per vehicle: despawn flushes storage and yields, and a second spawn in
    -- that gap would build a duplicate.
    if Vehicles._transitionLocks[vehicleId] then return nil, 'Vehicle is busy' end
    Vehicles._transitionLocks[vehicleId] = true

    -- pcall so an error inside can't strand the lock.
    local ok, entity, result = pcall(spawnLocked, vehicleId, def, x, y, z, heading)
    Vehicles._transitionLocks[vehicleId] = nil

    if not ok then
        print(('[whip_core:vehicle] spawn #%s errored: %s'):format(tostring(vehicleId), tostring(entity)))
        return nil, 'Spawn failed'
    end
    return entity, result
end

--- Every key whip writes onto a vehicle entity (shared/statebags.lua): one list for every place
--- that strips a car (release, reconcileWorld at boot, every delete).
local WHIP_ENTITY_KEYS = {
    VEHICLE_STATE_KEY, VEHICLE_SESSION_KEY, VEHICLE_STATS_KEY, VEHICLE_LIVE_KEY,
    VEHICLE_APPEARANCE_KEY, VEHICLE_DATA_KEY, VEHICLE_DOORS_KEY,
    -- Not a car's alone, but on one too: an engine held off, an admin's object-viewer hold. Left on, either comes
    -- back on whatever entity next has its network id.
    VEHICLE_ENGINE_HOLD_KEY, ENTITY_OV_HOLD_KEY,
}

-- Door masks: which doors of a car are open, as the bitmask VEHICLE_DOORS_KEY carries. The bag is client-writable,
-- so the server keeps its own copy, writes the bag from it, and the Sentinel holds the bag to it. Keyed by entity
-- (a street car nobody adopted still has doors); the model rides along so a reused handle doesn't inherit doors.
-- Entries for removed cars are swept once the table grows.
local doorMasks, doorMaskCount = {}, 0

---@param entity number
---@return integer|nil mask  nil for a car whose doors whip has not opened
function Vehicles.getDoorMask(entity)
    local e = doorMasks[entity]
    if not e then return nil end
    if not DoesEntityExist(entity) or GetEntityModel(entity) ~= e.model then
        doorMasks[entity], doorMaskCount = nil, doorMaskCount - 1
        return nil
    end
    return e.mask
end

---@param entity number
---@param mask integer
function Vehicles.setDoorMask(entity, mask)
    if not doorMasks[entity] then
        doorMaskCount = doorMaskCount + 1
        if doorMaskCount > 256 then
            for e in pairs(doorMasks) do
                if not DoesEntityExist(e) then doorMasks[e], doorMaskCount = nil, doorMaskCount - 1 end
            end
        end
    end
    doorMasks[entity] = { mask = mask, model = GetEntityModel(entity) }
    Sentinel.setEntityKey(entity, VEHICLE_DOORS_KEY, mask)
end

--- Take every whip key off an entity, before every delete (FiveM #3289: a statebag on a CreateVehicleServerSetter
--- car can orphan onto the next entity with that network id). The Sentinel lets these through: the car is already
--- out of the index, so its truth for each key is nil.
---@param entity number
local function stripWhipKeys(entity)
    if doorMasks[entity] then doorMasks[entity], doorMaskCount = nil, doorMaskCount - 1 end
    for _, key in ipairs(WHIP_ENTITY_KEYS) do Sentinel.setEntityKey(entity, key, nil) end
end

--- Take a vehicle out of the world: where an owned car's entity is destroyed. Not the only delete (Vehicles.release,
--- reconcileWorld, spawnLocked and spawnTemp also delete); each strips whip's keys first, and a new teardown step
--- belongs in each of them.
---@param vehicleId number
---@return boolean removed  true if there was an entity to remove
function Vehicles.despawn(vehicleId)
    -- Guards the primitive: any vehicleId can be a session id. cleanupSessionVehicle is a session car's one exit
    -- (let go or removed, contents logged as lost, record forgotten, `released` announced once), on stop too.
    local def = Vehicles._records[vehicleId]
    if def and def.session then
        Vehicles.cleanupSessionVehicle(vehicleId, 'despawned')
        return true
    end

    local entity = Vehicles._entities[vehicleId]

    -- Still this car? Handles are reused: a car removed outside whip (a cleanup script, txAdmin)
    -- can leave its handle on someone else's vehicle. Asked before the binding is cleared, because
    -- the fingerprint goes with it.
    local exists = entity ~= nil and isOurEntity(vehicleId, entity)
    local netId  = exists and NetworkGetNetworkIdFromEntity(entity) or nil

    setTracked(vehicleId, nil)
    Vehicles._fingerprint[vehicleId] = nil

    -- The confirmation belonged to that entity: the next one starts undressed.
    Vehicles._dressed[vehicleId] = nil

    if not entity then return false end

    -- Delete first, flush second: the flush yields, and a car left alive in that gap, tracked by
    -- nothing, would be duplicated by a spawn arriving meanwhile. DeleteEntity is synchronous; the
    -- storage flush is keyed on vehicleId, not the entity.
    if exists then
        -- Last chance to read where it is, and how damaged. Marked, not written: nothing may yield here.
        Vehicles.markPosition(vehicleId, entity)
        VehicleDamage.read(vehicleId, entity)
        stripWhipKeys(entity)   -- so an orphaned bag carries nothing to the next car (#3289)
        DeleteEntity(entity)
    end

    -- Not on whip_core's own stop: flushing yields, and a stop handler never comes back from a yield.
    -- The storage stays owed, and player_lifecycle's stop handler hands it over (Stores.dispatchOwed).
    if not Vehicles._stopping then
        local ok, err = Vehicles.flushStorage(vehicleId)
        if not ok then
            print(('[whip_core:vehicle] despawn #%s: storage flush failed: %s')
                :format(tostring(vehicleId), tostring(err)))
        else
            -- And let go of it, unless someone still has a compartment open (the ignition check
            -- loads a car's whole inventory). A later look loads it again.
            Vehicles.unloadIfIdle(vehicleId)
        end
    end

    -- Anything holding this netId (ropes, say) must be told: the next spawn gets a new one.
    Vehicles.announce('despawned', {
        vehicleId = vehicleId,
        netId     = netId,
    })

    return true
end

--- Vehicles.despawn for a caller outside a spawn, store or delete (DespawnVehicle, the Vehicle Manager). despawn
--- takes no lock, so an outside call takes its turn here or it could delete a car a spawn had just bound.
---@param vehicleId number
---@return boolean|nil removed  true if there was an entity to remove; nil when refused
---@return string|nil err       'Vehicle is busy' while another transition holds the car
function Vehicles.despawnWhenFree(vehicleId)
    if Vehicles._transitionLocks[vehicleId] then return nil, 'Vehicle is busy' end
    return underTransitionLock(vehicleId, 'despawn', function() return Vehicles.despawn(vehicleId) end)
end

--- Despawn puts the car away, filed in its garage as Store does it (out of the world, position cleared, state
--- 'garaged', record and storage kept), or it would come back at the next restart. Works with somebody inside (a
--- player's Store at a garage refuses). A street or temporary car has no garage: it goes (cleanupSessionVehicle).
--- A car already put away has only a stray entity, if any, to remove.
---@param vehicleId number
---@return boolean|nil ok  true when it was put away or removed; false when there was nothing to remove; nil refused
---@return string|nil err
function Vehicles.despawnToGarage(vehicleId)
    local def = Vehicles._records[vehicleId]
    if not def then return nil, 'Vehicle not found' end
    if def.session or def.state ~= 'out' then return Vehicles.despawnWhenFree(vehicleId) end
    local ok, err = Vehicles.store(vehicleId, nil, { occupied = true })
    if not ok then return nil, err end
    return true
end

--- Pin (or unpin) a street car on the client that owns it on the network. A street car stays GTA population and
--- the owning client culls it, boot and all, once the player walks away. SetEntityAsMissionEntity is a client
--- native, so the owner is asked. Undone when whip lets the car go (handBackToGta).
---@param entity number
---@param pin boolean
local function pinOnOwner(entity, pin)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    local owner = NetworkGetEntityOwner(entity)
    if owner and owner > 0 then
        TriggerClientEvent('whip_core:client:pinStreetCar', owner, NetworkGetNetworkIdFromEntity(entity), pin)
    end
end
Vehicles._pinOnOwner = pinOnOwner

--- Strip whip's identity and every block it wrote, and stop forcing the car to persist.
---@param entity number
local function handBackToGta(entity)
    stripWhipKeys(entity)
    SetEntityOrphanMode(entity, 0)
    pinOnOwner(entity, false)
end

--- Stop tracking a vehicle without deleting it from the world (session vehicles; owned vehicles use despawn).
--- `reason` travels in the `whip_core:vehicle:released` event:
---   'expired'   SpawnTempVehicle's despawnAfter ran out
---   'idle'      nobody near it for ten minutes (the sweep below)
---   'gone'      its entity had already left the world
---   'stopped'   the resource that spawned it stopped
---   'despawned' DespawnVehicle, or a despawn inside whip
---   'deleted'   DeleteVehicle
---   'failed'    SpawnTempVehicle could not finish (the key could not be given)
---@param vehicleId number
---@param reason string|nil  default 'released'
function Vehicles.release(vehicleId, reason)
    local entity = Vehicles._entities[vehicleId]
    local def = Vehicles._records[vehicleId]

    -- The released event fires every way out: per-vehicle bookkeeping belongs to the id, not the entity.
    local function announce()
        Vehicles.announce('released', {
            vehicleId = vehicleId,
            reason    = reason or 'released',
            temp      = def ~= nil and def.temp ~= nil,
        })
    end

    -- Only strip an entity that is still this car (handles are reused — see isOurEntity), asked
    -- before the binding and its fingerprint are cleared.
    local ours = entity ~= nil and isOurEntity(vehicleId, entity)
    setTracked(vehicleId, nil)
    Vehicles._fingerprint[vehicleId] = nil
    Vehicles._dressed[vehicleId] = nil
    if not ours then
        announce()
        return
    end

    -- A temporary car (SpawnTempVehicle) is not a street car: whip built it, so letting go removes it.
    if def and def.temp then
        stripWhipKeys(entity)   -- before the delete, see stripWhipKeys (#3289)
        DeleteEntity(entity)
        announce()
        return
    end

    -- Hand it back to GTA: drop the identity, every block whip wrote on it, and the forced persistence.
    handBackToGta(entity)

    -- Not `despawned` (the car is still there), but announced, so per-vehicle bookkeeping is dropped.
    announce()
end

--- Despawn, by another name: tracking and existence are the same fact.
function Vehicles.deleteServerEntity(vehicleId)
    Vehicles.despawn(vehicleId)
end

--- Reconcile what is in the world against what whip believes, once, at startup. Stamps outlive the Lua state that
--- issued them, so before restoring anything every stamped entity is decided: street cars from the previous run are
--- handed back to GTA (or their ids would collide), and a car whip left out is taken back rather than rebuilt
--- beside itself. Nothing watches bags while whip_core is down, so a client could stamp a same-model car with
--- someone's id: the candidate nearest the recorded position is taken, only within ADOPT_RANGE; the rest are
--- handed back. An occupied car is never deleted on a stamp alone.
local ADOPT_RANGE = 75.0

--- Somebody sitting in it? Server-side seat reads; any occupant counts.
local function occupied(entity)
    for seat = -1, 6 do
        if GetPedInVehicleSeat(entity, seat) ~= 0 then return true end
    end
    return false
end

function Vehicles.reconcileWorld()
    local adopted, cleared, deleted = 0, 0, 0
    local highestSession = Vehicles._sessionVehicleCounter
    local candidates = {}   -- [vehicleId] = { { entity, dist }, ... }

    --- Whip built it and no longer wants it (OrphanMode 2: nothing else would ever remove it). Keys
    --- first, like every delete. Somebody inside keeps it, as a street car.
    local function discard(entity)
        if occupied(entity) then
            handBackToGta(entity)
            cleared = cleared + 1
        else
            stripWhipKeys(entity)
            DeleteEntity(entity)
            deleted = deleted + 1
        end
    end

    for _, entity in ipairs(GetAllVehicles() --[[@as integer[] ]]) do   -- the server native: a list
        -- readEntityStamp, not getEntityVehicleId: the index is empty at boot, so the stamp is the
        -- only memory of the previous run.
        local stampedId = Vehicles.readEntityStamp(entity)
        if stampedId then
            local wasSession = Entity(entity).state[VEHICLE_SESSION_KEY] == true
            local def = Vehicles._records[stampedId]

            -- One entity per id, of the right model: two can carry the same stale stamp (#3289, a
            -- crash mid-respawn). Collected here, one chosen per id below.
            local claimable = def and def.state == 'out' and not def.session
                and Vehicles._entities[stampedId] == nil
                and GetEntityModel(entity) == GetHashKey(def.model)

            if claimable then
                local dist = 0.0
                if def.x and def.y and def.z then
                    dist = #(GetEntityCoords(entity) - vector3(def.x, def.y, def.z))
                end
                local list = candidates[stampedId]
                if not list then list = {}; candidates[stampedId] = list end
                list[#list + 1] = { entity = entity, dist = dist }
            elseif wasSession then
                -- A street car from a previous run: GTA's again, every whip block cleared.
                handBackToGta(entity)
                cleared = cleared + 1
                -- Only an id a previous run could have handed out moves the counter (a forged one
                -- near the top would leave no ids to take).
                if stampedId > highestSession and stampedId < SESSION_ID_FIRST + SESSION_ID_WINDOW then
                    highestSession = stampedId
                end
            else
                discard(entity)
            end
        end
    end

    for stampedId, list in pairs(candidates) do
        table.sort(list, function(a, b) return a.dist < b.dist end)
        for i, c in ipairs(list) do
            if i == 1 and c.dist <= ADOPT_RANGE then
                -- Whip built this one and still wants it where it is: take it back, with everything
                -- a spawn does (bindEntity, the sweep's starting point, `spawned`).
                local def = Vehicles._records[stampedId]
                bindEntity(stampedId, c.entity, def)
                -- What the row says, so the first sweep writes where the car really stands if the
                -- row is behind it (nil for no position: written on the first pass).
                Vehicles._lastPos[stampedId] = def.x and def.y and def.z
                    and { x = def.x, y = def.y, z = def.z, heading = def.heading or 0.0 } or nil
                Vehicles.announce('spawned', {
                    vehicleId = stampedId,
                    entity    = c.entity,
                    netId     = NetworkGetNetworkIdFromEntity(c.entity),
                    plate     = def.plate,
                    model     = def.model,
                    session   = false,
                })
                adopted = adopted + 1
            elseif c.dist > ADOPT_RANGE then
                -- Too far from where the record says the car is to be it on a stamp's word.
                print(('[whip_core:vehicle] reconcile: an entity stamped as vehicle %d is %.0fm from its record — not adopted, handed back'):format(stampedId, c.dist))
                handBackToGta(c.entity)
                cleared = cleared + 1
            else
                discard(c.entity)   -- a second copy
            end
        end
    end

    -- A car not streamed in right now could reappear with an old id, so the counter starts above
    -- the highest seen.
    if highestSession >= Vehicles._sessionVehicleCounter then
        Vehicles._sessionVehicleCounter = highestSession + 1
    end

    if adopted + cleared + deleted > 0 then
        print(('[whip_core:vehicle] reconciled world: %d re-adopted, %d released, %d removed')
            :format(adopted, cleared, deleted))
    end
end

-- ============================================
-- Teardown and External Removal
-- ============================================

--- Hand everything back before the Lua state disappears (cheaper and more certain than cleaning up on the way back
--- in, and satellites holding net ids get their despawn event). Runs before the stop's dispatch of owed storage
--- and each car's save unit.
CoreStop.add(40, 'vehicles: despawn and mark positions', function()
    -- Nothing below may wait (a stop handler never comes back from a yield). _stopping makes
    -- despawn skip its storage flush and lets a car's position go even mid-transition.
    Vehicles._stopping = true

    -- Snapshot: despawn and release both mutate Vehicles._entities.
    local ids = {}
    for vehicleId in pairs(Vehicles._entities) do ids[#ids + 1] = vehicleId end

    for _, vehicleId in ipairs(ids) do
        -- despawn ends session vehicles (cleanupSessionVehicle; Log.write only buffers, so nothing
        -- waits) and marks each owned car's position, the last moment it can be read.
        Vehicles.despawn(vehicleId)
    end
end)

-- STEP 40 of the final save (server/lifecycle.lua): where every car is now, waited for. The cars
-- stay out; the next boot puts them back here. Counted under 'vehicle stats and positions'.
FinalSave.add(40, 'vehicle positions', function()
    for vehicleId in pairs(Vehicles._entities) do
        Vehicles.markPosition(vehicleId)
        -- Its damage is a stat on the same save unit: written by step 52's last pass.
        VehicleDamage.read(vehicleId)
    end
    return Vehicles.flushPositions()
end)

-- No entityRemoved handler for cars, on purpose: it fires for every networked entity the server drops and the
-- dispatch alone is costly. Not needed: Vehicles.getEntity and getEntityVehicleId confirm a handle before returning
-- it, and despawn and release clear both tables on the normal path. The cost: `whip_core:vehicle:despawned`
-- doesn't fire when the engine removes a whip car (they are KeepEntity, so it shouldn't); if it does the car reads
-- as not spawned and the next spawn rebuilds it.

-- Session vehicles: NPC/AI vehicles get the full framework features (glovebox, trunk, ignition, lock) in memory only.

-- Declared here, defined just below registerSessionVehicle: a local used before its definition
-- would read a nil global instead. (`function newSessionRecord` below assigns to this local.)
local newSessionRecord

--- The record a plate names, if it still stands (a street car whose car has gone does not). "Will registering this
--- plate make a new street car?" is `getLiveByPlate(plate) == nil`.
---@param plate string
---@return number|nil vehicleId
function Vehicles.getLiveByPlate(plate)
    local id = Vehicles.getByPlate(plate)
    if not id then return nil end
    local def = id and Vehicles._records[id]
    if def and def.session and not Vehicles.getEntity(id) then return nil end
    return id
end

--- Register an NPC vehicle as a session vehicle in memory; if already registered, returns the existing ID. The
--- second answer says whether this call made the record (the per-player cap counts only street cars a player brought in).
---@param plate string
---@param model string
---@param netId number
---@param vehType string
---@param engineOn boolean  Whether engine was running when player entered
---@param charId number|nil  who found it, for the activity log when a key is minted
---@param reporter number|nil  the player whose client reported it, for the registered event
---@return number|nil vehicleId
---@return boolean|nil created  true when this call made a new session record
function Vehicles.registerSessionVehicle(plate, model, netId, vehType, engineOn, charId, reporter)
    if not plate or plate == '' then return nil end

    -- A key minted here is an item entering the game: logged, like CreateTempVehicle's.
    local function logMintedKey(slot, forPlate)
        Log.item(charId, 'gained', slot, {
            detail = ('key for %s, found in the ignition of a street car'):format(tostring(forPlate)),
        })
    end

    -- Already registered? (DB vehicle or previous session registration)
    local existingId = Vehicles.getByPlate(plate)

    -- A street car whose car has gone is not found again by plate (plate text is client-set: renaming your car must
    -- not collect a culled car's boot). The record goes, contents logged as lost, and this is a new street car.
    local existDefNow = existingId and Vehicles._records[existingId]
    if existingId and existDefNow and existDefNow.session and not Vehicles.getEntity(existingId) then
        Vehicles.cleanupSessionVehicle(existingId, 'gone')
        existingId = nil
    end

    if existingId then
        local existDef = Vehicles._records[existingId]

        -- Re-adopt first: after a restart or GTA recreating the entity the car may carry no stamp. adopt is
        -- idempotent and refuses an entity that belongs to something else; its "no" is the answer.
        -- Session defs only: the plate comes off the entity, which a client can rewrite, so nothing a client
        -- reports may rebind an owned vehicle (only Vehicles.spawn and reconcileWorld bind those).
        if existDef and existDef.session then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if not (entity and entity ~= 0 and DoesEntityExist(entity) and Vehicles.adopt(existingId, entity)) then
                return nil
            end
        end

        -- Re-entering with the engine on and no key yet: add the key it was found with, once per
        -- car (`keyMinted`), or every re-entry would print another.
        if existDef and existDef.session and engineOn and not existDef.keyMinted
            and not Vehicles.hasKeyInIgnition(existingId) then
            existDef.keyMinted = true
            if not Vehicles.invCache[existingId] then
                Vehicles.invCache[existingId] = { trunk = {}, glovebox = {}, key = {} }
            end
            if not Vehicles.invCache[existingId].key then
                Vehicles.invCache[existingId].key = {}
            end
            local keyModel = existDef.model
            if keyModel and (tonumber(keyModel) or keyModel:match('^%-?%d+$')) then
                keyModel = nil
            end
            Vehicles.invCache[existingId].key[1] = {
                item     = 'vehicle_key',
                amount   = 1,
                metadata = {
                    vehicleId = existingId,
                    plate     = existDef.plate,
                    model     = keyModel,
                },
            }
            logMintedKey(Vehicles.invCache[existingId].key[1], existDef.plate)
        end

        return existingId, false
    end

    local sessionId = newSessionRecord(plate, model, vehType)

    -- Adopt, don't spawn: GTA already put this car in the world. No retry loop: a street car has
    -- existed as long as the player has been looking at it. If it can't be adopted there is no new
    -- car: the record is dropped before any key is minted into it.
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not (entity and entity ~= 0 and DoesEntityExist(entity) and Vehicles.adopt(sessionId, entity)) then
        Vehicles.cleanupSessionVehicle(sessionId, 'not adopted')
        return nil
    end
    -- Kept in the world while whip holds it, on every adoption path.
    pinOnOwner(entity, true)

    -- If engine was running when player entered, auto-generate a key in ignition — once; see
    -- `keyMinted` in the existing-plate branch above.
    if engineOn then
        Vehicles._records[sessionId].keyMinted = true
        local keyModel = model or 'unknown' ---@type string|nil
        if keyModel and (tonumber(keyModel) or keyModel:match('^%-?%d+$')) then
            keyModel = nil
        end
        Vehicles.invCache[sessionId].key[1] = {
            item     = 'vehicle_key',
            amount   = 1,
            metadata = {
                vehicleId = sessionId,
                plate     = plate,
                model     = keyModel,
            },
        }
        logMintedKey(Vehicles.invCache[sessionId].key[1], plate)
    end

    -- Announced here, where every adoption path meets (the driver's report, ResolveVehicle, the pump,
    -- AdoptVehicle): whip's stats and data replicate onto the car from this. A new record only, once
    -- it has its entity.
    Vehicles.announce('registered', {
        vehicleId = sessionId,
        plate     = plate,
        model     = model,
        session   = true,
        source    = reporter,
    })

    return sessionId, true
end

--- A new in-memory record for a car with no database row: a street car whip adopted, or a temporary car it built.
---@param plate string
---@param model string|nil
---@param vehType string|nil
---@return number sessionId
function newSessionRecord(plate, model, vehType)
    -- A synthetic id that is actually free (session ids share the record table with owned cars,
    -- though they start a billion up). Bounded: nothing unbounded on the server thread, so a
    -- counter that can't find one is an error, never a hang.
    local tries = 0
    repeat
        Vehicles._sessionVehicleCounter = Vehicles._sessionVehicleCounter + 1
        tries = tries + 1
        if tries > 1000 or Vehicles._sessionVehicleCounter > VEHICLE_ID_MAX then
            error(('newSessionRecord: no free session vehicle id (counter %s after %d tries)')
                :format(tostring(Vehicles._sessionVehicleCounter), tries), 2)
        end
    until not Vehicles._records[Vehicles._sessionVehicleCounter]
    local sessionId = Vehicles._sessionVehicleCounter

    -- Create cache entry (mirrors DB vehicle structure)
    Vehicles._records[sessionId] = {
        vehicleId   = sessionId,
        ownerCharId = 0,
        model       = model or 'unknown',
        plate       = plate,
        state       = 'out',
        garage      = nil,
        -- Same shape as a database-backed def, so no stats path needs a session branch. Empty: an
        -- absent key resolves to the registered default everywhere.
        vehStats    = {},
        properties  = nil,
        x           = nil,
        y           = nil,
        z           = nil,
        heading     = nil,
        locked      = true,
        session     = true,  -- marks as session vehicle (no DB persistence)
    }

    Vehicles.reindex(sessionId, Vehicles._records[sessionId])

    -- Create inventory cache with empty storage
    Vehicles.invCache[sessionId] = { trunk = {}, glovebox = {}, key = {} }

    if vehType and vehType ~= '' then
        Vehicles._records[sessionId].vehType = vehType
    end

    return sessionId
end

--- Cleanup a session vehicle from memory.
---@param vehicleId number
---@param reason string|nil  why, for the released event — see Vehicles.release
function Vehicles.cleanupSessionVehicle(vehicleId, reason)
    if not vehicleId then return end
    local def = Vehicles._records[vehicleId]
    if not def or not def.session then return end

    -- Once: taking a temp car's key back waits, and a second caller in that wait must not log the
    -- contents twice. The record stays until the end (keyFits reads it to match the key).
    if def.releasing then return end
    def.releasing = true

    -- Whatever was left in it goes with it (it only lived in memory), logged as lost.
    local where = def.x and vector3(def.x, def.y, def.z) or nil
    local kind = def.temp and 'temporary car' or 'street car'
    for storage, slots in pairs(Vehicles.invCache[vehicleId] or {}) do
        for _, slotData in pairs(slots) do
            if type(slotData) == 'table' and slotData.item then
                Log.write(nil, 'lost', {
                    itemKey = slotData.item, amount = slotData.amount or 1,
                    uid     = slotData.metadata and slotData.metadata.uid or nil,
                    detail  = ('left in the %s of %s %s when it was released'):format(storage, kind, tostring(def.plate)),
                    x = where and where.x, y = where and where.y, z = where and where.z,
                })
            end
        end
    end

    -- A temporary car takes back the key it handed out, from the player it gave it to, if still here (a key passed
    -- on or stashed stays). Not on whip_core's own stop, where nothing may wait: the key names an id gone with the restart.
    if def.temp and def.tempKeyCharId and not Vehicles._stopping then
        local holder = PlayersByCharId[def.tempKeyCharId]
        if holder then pcall(Vehicles.removeKey, holder.source, holder, vehicleId) end
    end

    Vehicles.release(vehicleId, reason)
    Vehicles._records[vehicleId] = nil
    Vehicles.reindex(vehicleId, nil)
    Vehicles.invCache[vehicleId] = nil

    -- The vehicle is gone, so nobody can be looking into it.
    for _, st in ipairs({ 'trunk', 'glovebox', 'key' }) do
        Stores.forgetViews(('vehicle:%s:%s'):format(tostring(vehicleId), st))
    end

end

-- Temporary cars (rentals, job vans, test drives): a session vehicle whip builds itself, with no database row but a
-- vehicleId, stats, data, a trunk, a glovebox and keys. It belongs to the resource that asked for it and is removed
-- when that resource stops, its time runs out, or nobody has been near it for ten minutes.

--- Build a temporary car.
---@param model string
---@param x number
---@param y number
---@param z number
---@param heading number
---@param opts table   { plate?, vehType?, locked? (default true), idleDespawn? (default true),
---                      bucket? (its routing bucket, at birth: default 0, the shared world) }
---@param owner string the resource it belongs to
---@return number|nil vehicleId
---@return number|string netIdOrError
function Vehicles.spawnTemp(model, x, y, z, heading, opts, owner)
    local missing = Vehicles.missingModel(model)   -- a model the game has (Vehicles.modelExists)
    if missing then return nil, missing end

    local vehType = opts.vehType or Vehicles.typeForModel(model) or 'automobile'

    local plate = opts.plate
    if not plate or plate == '' then plate = Vehicles.generatePlate() end
    if Vehicles.getByPlate(plate) then return nil, ('plate %s is already on a vehicle'):format(plate) end

    local entity = CreateVehicleServerSetter(GetHashKey(model), vehType, x + 0.0, y + 0.0, z + 0.0, heading + 0.0)
    if not entity or entity == 0 then return nil, 'Could not create the vehicle' end

    -- Same rule as spawnLocked: no usable network id, no car anybody can use.
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId <= 0 then
        DeleteEntity(entity)
        return nil, 'Vehicle did not network'
    end
    SetVehicleNumberPlateText(entity, Vehicles.displayPlate(plate))

    local vehicleId = newSessionRecord(plate, model, vehType)
    local def = Vehicles._records[vehicleId]
    def.temp    = owner
    def.x, def.y, def.z, def.heading = x + 0.0, y + 0.0, z + 0.0, heading + 0.0

    -- Locked unless asked otherwise, like an owned car (bindEntity tells the doors).
    def.locked = opts.locked ~= false
    if opts.idleDespawn == false then def.tempKeepIdle = true end
    if opts.bucket and opts.bucket ~= 0 then def.bucket = opts.bucket end

    -- Bound directly, not adopted: whip built it, and a plate set a moment ago may not read back yet.
    bindEntity(vehicleId, entity, def)

    Vehicles.announce('spawned', {
        vehicleId = vehicleId,
        entity    = entity,
        netId     = netId,
        plate     = plate,
        model     = model,
        session   = true,
        temp      = true,
    })

    return vehicleId, netId
end

-- A resource's temporary cars go when it does.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    local doomed = {}
    for id, def in pairs(Vehicles._records) do
        if def.temp == res then doomed[#doomed + 1] = id end
    end
    for _, id in ipairs(doomed) do Vehicles.cleanupSessionVehicle(id, 'stopped') end
end)

-- ...and a run's go with its tag (SpawnTempVehicle opts.tag). After the NPCs (20), before the ground (50).
-- Each in a thread of its own: taking a car's key back waits, and a release must not. Started AT ONCE
-- (CreateThreadNow), so a car with no key to take back is gone before ReleaseTag answers.
local function taggedTemp(owner, tag)
    local ids = {}
    for id, def in pairs(Vehicles._records) do
        if def.temp == owner and def.tempTag == tag and not def.releasing then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end
Registry.onRelease('tempVehicle', 30, function(owner, tag)
    local ids = taggedTemp(owner, tag)
    for _, id in ipairs(ids) do
        Citizen.CreateThreadNow(function() Vehicles.cleanupSessionVehicle(id, 'released') end)
    end
    return #ids
end, function(owner, tag)
    local out = {}
    for _, id in ipairs(taggedTemp(owner, tag)) do out[#out + 1] = { key = id } end
    return out
end)

-- Letting street cars go: a session car is borrowed and given back. Once a minute, a session car whose entity is
-- gone is forgotten; one with no player within SESSION_NEAR metres (and nobody in its trunk or glovebox) for
-- SESSION_IDLE_MS is released to GTA and forgotten, its memory-only trunk and glovebox with it.
local SESSION_IDLE_MS = 10 * 60 * 1000
local SESSION_NEAR    = 300.0
local _sessionLastNear = {}   -- [vehicleId] = GetGameTimer() when a player was last near it

-- Every (lifecycle.lua), so one error can't end the sweep.
Every('session-car release sweep', 60000, function()
    local now = GetGameTimer()

    -- Where the players are, read once a pass.
    local playerAt = {}
    for _, s in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(s)
        if ped and ped ~= 0 then playerAt[#playerAt + 1] = GetEntityCoords(ped) end
    end

    -- The session ids first: releasing a temp car takes its key back (a wait), and pairs() over the
    -- live table across a wait is undefined.
    local sessionIds = {}
    for id, def in pairs(Vehicles._records) do
        if def.session then sessionIds[#sessionIds + 1] = id end
    end

    for _, id in ipairs(sessionIds) do
        local def = Vehicles._records[id]
        if def and def.session then
            local entity = Vehicles.getEntity(id)
            if not entity then
                Vehicles.cleanupSessionVehicle(id, 'gone')
                _sessionLastNear[id] = nil
            elseif def.tempKeepIdle then
                -- SpawnTempVehicle's `idleDespawn = false`: the resource that spawned it decides
                -- when it goes (despawnAfter, DespawnVehicle, or its own stop), not this sweep.
                _sessionLastNear[id] = nil
            else
                local near = Stores.viewerCount(('vehicle:%s:trunk'):format(id)) > 0
                    or Stores.viewerCount(('vehicle:%s:glovebox'):format(id)) > 0
                if not near then
                    local c = GetEntityCoords(entity)
                    for i = 1, #playerAt do
                        if #(playerAt[i] - c) < SESSION_NEAR then near = true break end
                    end
                end

                if near or not _sessionLastNear[id] then
                    _sessionLastNear[id] = now
                elseif now - _sessionLastNear[id] >= SESSION_IDLE_MS then
                    Vehicles.cleanupSessionVehicle(id, 'idle')
                    _sessionLastNear[id] = nil
                end
            end
        end
    end
end)

--- Adopt this street car, the entity in hand (never "the first car wearing its plate"), for a server path that
--- already holds the entity.
---@param entity number
---@param clientModel string|nil
---@return number|nil vehicleId
---@return string|nil why
function Vehicles.adoptEntity(entity, clientModel)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil, 'No vehicle there' end

    local stamped = Vehicles.getEntityVehicleId(entity)
    if stamped then return stamped end

    local plate = GetVehicleNumberPlateText(entity)
    if not plate or plate == '' then return nil, 'That vehicle has no plate' end
    -- An owned car, or a car whip holds on another live entity, is a DIFFERENT car wearing this plate.
    -- (A street car whip remembers with no entity left is this one come back; registering takes it.)
    local existingId = Vehicles.getByPlate(plate)
    if existingId then
        local existing = Vehicles.getDef(existingId)
        if (existing and not existing.session) or Vehicles.getEntity(existingId) then
            return nil, 'Another vehicle already has that plate'
        end
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId <= 0 then return nil, 'Could not identify that vehicle' end

    local model = clientModel or tostring(GetEntityModel(entity))
    -- One value: registerSessionVehicle's second answer (created) is not this function's `why`.
    return (Vehicles.registerSessionVehicle(plate, model, netId, GetVehicleType(entity) or 'automobile', false))
end

--- Find or auto-register a session vehicle by plate, so NPC vehicles gain full features on first interaction.
---@param plate string
---@return number|nil vehicleId
function Vehicles.ensureSessionVehicle(plate, clientModel)
    if not plate then return nil end

    local vehicleId = Vehicles.getByPlate(plate)
    if vehicleId then return vehicleId end

    -- Not registered — find entity by plate and auto-register
    local normPlate = plate:upper():gsub('%s+', '')
    local allVehicles = GetAllVehicles() --[[@as integer[] ]]   -- the server native: a list
    for _, entity in ipairs(allVehicles) do
        local entPlate = GetVehicleNumberPlateText(entity)
        if entPlate and entPlate:upper():gsub('%s+', '') == normPlate then
            local netId = NetworkGetNetworkIdFromEntity(entity)
            if netId and netId > 0 then
                local modelHash = GetEntityModel(entity)
                -- The client's name for the model if it sent one, else the hash as a string
                -- (GetDisplayNameFromVehicleModel is a client native).
                local model = clientModel or tostring(modelHash)

                local vehType = GetVehicleType(entity) or 'automobile'
                return (Vehicles.registerSessionVehicle(entPlate, model, netId, vehType, false))
            end
        end
    end
    return nil
end

-- ============================================
-- Garage — Store / Retrieve
-- ============================================

-- (underTransitionLock is above Vehicles.delete, which uses it too.)

---@param opts table|nil  { occupied = true }: put away even with somebody inside (a player's Store at a garage still
---                       cannot). { reversed = true }: it was parked facing the other way from its bay, and comes out
---                       of a bay that way (only a bay's Store knows)
function Vehicles.store(vehicleId, garageKey, opts)
    if Vehicles._transitionLocks[vehicleId] then return false, 'Vehicle is busy' end
    local def = Vehicles._records[vehicleId]
    if not def then return false, 'Vehicle not found' end
    -- Not a street car or a temporary one: neither has a row to be garaged in.
    if def.session then
        return false, def.temp and 'A temporary car cannot be put in a garage'
            or 'A street car cannot be put in a garage'
    end
    if def.state ~= 'out' then return false, 'Vehicle is already stored' end

    -- Nobody inside: storing deletes the car.
    local inWorld = Vehicles.getEntity(vehicleId)
    if inWorld and not (opts and opts.occupied) and #serverOccupants(inWorld) > 0 then
        return false, 'Somebody is still in that vehicle'
    end

    -- Into a garage that exists. No key means the garage it is filed under, or the default one.
    if (garageKey == nil or garageKey == '') and def.garage and Garages.get(def.garage) then
        garageKey = def.garage
    end
    local garageErr
    garageKey, garageErr = Vehicles.checkGarage(garageKey)
    if garageErr then return false, garageErr end

    -- The lock goes on first: deleteServerEntity yields (it flushes storage), and a second store or
    -- retrieve must not walk in meanwhile.
    local ok, err = underTransitionLock(vehicleId, 'store', function()
        Vehicles.deleteServerEntity(vehicleId)

        -- Its row write lands first: one in flight with the last position could commit after the
        -- coordinates are cleared below.
        Stores.settle('vehrow:' .. tostring(vehicleId))

        -- A garaged car has no position (Vehicles.NULL clears a column).
        local pOk, pErr = Vehicles.persist(vehicleId, {
            state   = 'garaged',
            garage  = garageKey,
            x       = Vehicles.NULL,
            y       = Vehicles.NULL,
            z       = Vehicles.NULL,
            heading = Vehicles.NULL,
            parkedReversed = opts ~= nil and opts.reversed == true,
        })

        -- Nothing pending, or the sweep would write coordinates back onto the cleared row.
        Vehicles._dirtyPos[vehicleId] = nil
        Vehicles._lastPos[vehicleId]  = nil

        return pOk, pErr
    end)

    if not ok then return false, err or 'Could not store the vehicle' end
    return true
end

function Vehicles.retrieve(vehicleId, garageKey)
    if Vehicles._transitionLocks[vehicleId] then return false, 'Vehicle is busy' end
    local def = Vehicles._records[vehicleId]
    if not def then return false, 'Vehicle not found' end
    if heldBy(def) then return false, 'Vehicle is in custody' end
    if def.state ~= 'garaged' then return false, 'Vehicle is not garaged' end
    -- Allow retrieval if garage matches OR if vehicle has no garage assigned (admin set state)
    if def.garage and def.garage ~= '' and def.garage ~= garageKey then return false, 'Wrong garage' end
    -- Before the row says "out": a car whose model the game does not have stays in its garage, saying
    -- why, rather than coming out as nothing and being lost (Vehicles.modelExists).
    local missing = Vehicles.missingModel(def.model)
    if missing then return false, missing end

    local ok, err = underTransitionLock(vehicleId, 'retrieve', function()
        local pOk, pErr = Vehicles.persist(vehicleId, { state = 'out' })
        if not pOk then return pOk, pErr end
        -- Out of a garage locked, through setLocked (so lockChanged fires), unless its own key is in
        -- the ignition: then unlocked, or the owner is locked out. A lock that fails to save is said,
        -- not a failed retrieve.
        local lOk, lErr = Vehicles.setLocked(vehicleId, not Vehicles.hasKeyInIgnition(vehicleId))
        if not lOk then
            print(('[whip_core:vehicle] retrieve #%s: could not set its lock: %s'):format(tostring(vehicleId), tostring(lErr)))
        end
        return true
    end)

    if not ok then return false, err or 'Could not retrieve the vehicle' end
    return true
end

--- Does a key's metadata fit this vehicle? The one place a key is matched to a car. For an owned car the id decides;
--- session ids restart on every clean start while keys persist, so a session car's key must also carry this car's plate.
---@param metadata table|nil
---@param vehicleId number
---@return boolean
function Vehicles.keyFits(metadata, vehicleId)
    if not metadata or tonumber(metadata.vehicleId) ~= vehicleId then return false end
    local def = Vehicles._records[vehicleId]
    -- A car with a token takes only keys cut with it: a SECURE car (SpawnTempVehicle opts.secure, a Director run's),
    -- whose plate can be fixed, so id + plate can be yesterday's too; and an owned car whose locks were changed
    -- (Vehicles.changeLocks), so every key cut before stops fitting.
    if def and def.keyToken and metadata.token ~= def.keyToken then return false end
    if def and def.session then
        local keyPlate = metadata.plate and tostring(metadata.plate):upper():gsub('%s+', '')
        local carPlate = def.plate and tostring(def.plate):upper():gsub('%s+', '')
        -- A plate changed this session (SetVehiclePlate, vehicle_claim.lua): keys cut before it
        -- carry the old one, and still fit.
        if keyPlate ~= nil and def.keyPlates and def.keyPlates[keyPlate] then return true end
        return keyPlate ~= nil and keyPlate == carPlate
    end
    return true
end

--- Is this a key of this car that its locks no longer take (cut before a change of locks, Vehicles.changeLocks, or
--- before a temporary car was made secure)? Another car's key is not.
---@param metadata table|nil
---@param vehicleId number
---@return boolean
function Vehicles.keyDeactivated(metadata, vehicleId)
    if type(metadata) ~= 'table' or tonumber(metadata.vehicleId) ~= vehicleId then return false end
    local def = Vehicles._records[vehicleId]
    return def ~= nil and def.keyToken ~= nil and metadata.token ~= def.keyToken
end

--- A key into this car's ignition: true when it fits, else false and the player's words when it is one of this car's
--- keys whose locks have been changed since (nil words: the store's own "That item does not go there").
---@return boolean ok
---@return string|nil why
local function keyGoesIn(metadata, vehicleId)
    if Vehicles.keyFits(metadata, vehicleId) then return true end
    if Vehicles.keyDeactivated(metadata, vehicleId) then return false, 'This key is deactivated.' end
    return false
end

--- Check if an item is allowed in vehicle storage. A refusal can carry the player's words (a deactivated key).
---@param vehicleId number
---@param storageType string
---@param itemKey string
---@param metadata table|nil
---@return boolean ok
---@return string|nil why
function Vehicles.isItemAllowed(vehicleId, storageType, itemKey, metadata)
    if storageType == 'key' then
        if itemKey == 'vehicle_key' then
            -- Regular key must match this vehicle
            return keyGoesIn(metadata, vehicleId)
        elseif itemKey == 'hacked_vehicle_key' then
            -- Unhacked (no vehicleId): allowed in any ignition
            if not metadata or not metadata.vehicleId then return true end
            -- Already hacked: only allowed in the vehicle it was hacked for
            return keyGoesIn(metadata, vehicleId)
        elseif Inventory.isIgnitionKey(itemKey) then
            -- A registered key type (RegisterIgnitionKey) follows the vehicle_key rule: cut for this car. A
            -- satellite wanting any-ignition behaviour models it in its own item logic.
            return keyGoesIn(metadata, vehicleId)
        end
        return false
    end
    return true
end

-- ============================================
-- Ignition Helpers
-- ============================================

--- Check if a matching key is currently in the vehicle's ignition
---@param vehicleId number
---@return boolean
function Vehicles.hasKeyInIgnition(vehicleId)
    if not Vehicles.invCache[vehicleId] then
        Vehicles.loadInventory(vehicleId)
    end
    local keyInv = Vehicles.invCache[vehicleId] and Vehicles.invCache[vehicleId].key
    if not keyInv then return false end
    for _, slotData in pairs(keyInv) do
        -- Registry, not a hardcoded pair — a RegisterIgnitionKey key genuinely starts cars.
        if Inventory.isIgnitionKey(slotData.item) then
            if Vehicles.keyFits(slotData.metadata, vehicleId) then
                return true
            end
        end
    end
    return false
end

--- May this vehicle run: a key that fits in its ignition, or always for a bicycle. Not the same as hasKeyInIgnition,
--- which is about the key itself (it unlocks a car out of a garage and lets whoever sits in it lock it or reach inside).
---@param vehicleId number
---@return boolean
function Vehicles.ignitionReady(vehicleId)
    if Vehicles.isBicycle(vehicleId) then return true end
    return Vehicles.hasKeyInIgnition(vehicleId)
end

--- Get the ignition slot data (or nil)
---@param vehicleId number
---@return table|nil
function Vehicles.getIgnitionSlot(vehicleId)
    if not Vehicles.invCache[vehicleId] then
        Vehicles.loadInventory(vehicleId)
    end
    local keyInv = Vehicles.invCache[vehicleId] and Vehicles.invCache[vehicleId].key
    if keyInv and keyInv[1] then return keyInv[1] end
    return nil
end

-- Public exports. The key exports forward to globals in server/items/vehicle_key.lua, resolved at call time.

--- Everything whip knows about a vehicle, in one call. By its id, or by a reference that says what you hold:
---     local v = exports.whip_core:GetVehicle(vehicleId)
---     local v = exports.whip_core:GetVehicle({ plate = 'ABC123' })   -- or { netId = }, { entity = }, { id = }
---     v.plate, v.model, v.owner.charId, v.state, v.garage, v.coords, v.locked, v.session
---     v.spawned, v.entity, v.netId
---     v.stats.fuel, v.data.myThing, v.properties, v.storage
--- Always a copy. Returns nil for a vehicle whip does not know. Occupants cost a scan of every player, so they are
--- opt-in: `GetVehicle(id, { occupants = true })`.
---@param vehicleId number|WhipVehicleRef|nil
---@param opts table|nil
---@return table|nil
exports('GetVehicle', function(vehicleId, opts)
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return nil end
    return Vehicles.context(vehicleId, opts)
end)

--- Every vehicle a person owns, as full snapshots. The person rule (WhoIs): a server id, or
--- `{ charId = n }` for a character online or not.
---@param who number|table
---@return table[]
---@return string|nil why  with {} when `who` names nobody
exports('GetVehiclesOf', function(who)
    local charId, why = WhoIs(who)
    if not charId then return {}, why --[[@as string]] end

    local out = {}
    for _, vehicleId in ipairs(Vehicles.ownedIds(charId)) do
        out[#out + 1] = Vehicles.context(vehicleId)
    end
    return out
end)

-- A vehicle's storage: StoreRead({ kind = 'vehicle', id = vehicle, sub = storageType }).

--- Put a vehicle into the world. Idempotent: on a vehicle already out it moves it. Returns `false` rather than nil
--- on failure (an export's return list stops at the first nil).
---@param vehicleId number|WhipVehicleRef|nil
---@param coords vector3|vector4|table|nil  defaults to the vehicle's saved position; a vector4's w (a table's w or
---                                         heading) is the heading
---@return number|false netId, string|nil err
exports('SpawnVehicle', function(vehicleId, coords)
    local x, y, z, heading
    if coords ~= nil then
        local kind = type(coords)
        if kind ~= 'vector3' and kind ~= 'vector4' and kind ~= 'table' then
            return false, 'SpawnVehicle(vehicleId, coords): coords is a vector3, or a vector4 with the heading in w'
        end
        x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
        -- (a vector3 has no w to read)
        if kind ~= 'vector3' then heading = tonumber(coords.w) or tonumber(coords.heading) end
    end
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end

    -- A spot that is taken is refused, not spawned into. The car itself doesn't count.
    if x and y and z then
        local blocked = Vehicles.spotBlocked(x, y, z, { exceptEntity = Vehicles.getEntity(vehicleId) })
        if blocked then return false, blocked end
    end

    local entity, netIdOrErr = Vehicles.spawn(vehicleId, x, y, z, heading)
    if not entity then return false, tostring(netIdOrErr) end
    return netIdOrErr
end)

--- Take a vehicle out of the world, its record and storage kept (Vehicles.despawnToGarage); storage is flushed
--- first. With no garage it goes where it belongs: someone's own car into its garage, a temporary car is forgotten,
--- a street car handed back to GTA. `opts.garage` puts an owned car that is out away in that garage, the
--- Vehicles.store rules: a street or temporary car is refused, as neither has a row to be garaged in.
--- `opts.refuseOccupied` refuses a car with somebody in it: on by default with a garage (as StoreVehicle always
--- refused), off without one. SpawnVehicle brings it out again. `(ok, err)` like every other verb.
---@param vehicleId number|WhipVehicleRef|nil
---@param opts { garage?: string, refuseOccupied?: boolean }|nil
---@return boolean ok, string|nil err
function Vehicles.despawnByRef(vehicleId, opts)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'Vehicle not found' end
    opts = type(opts) == 'table' and opts or {}
    -- With a garage, refused unless the caller says otherwise: StoreVehicle, which this took in, always refused an
    -- occupied car, and putting one away with people in it is not what "store it" means.
    local refuseOccupied
    if opts.refuseOccupied ~= nil then refuseOccupied = opts.refuseOccupied == true
    else refuseOccupied = opts.garage ~= nil end

    -- Into a garage named: an owned car that is out, into a garage that exists (a key that names none is refused)
    if opts.garage ~= nil then
        return Vehicles.store(vehicleId, opts.garage, { occupied = not refuseOccupied })
    end

    if refuseOccupied then
        local entity = Vehicles.getEntity(vehicleId)
        if entity and #serverOccupants(entity) > 0 then return false, 'Somebody is still in that vehicle' end
    end

    -- A temporary car (SpawnTempVehicle) has nowhere to be put away, so taking it out of the world
    -- is the end of it: removed, forgotten, and its key taken back.
    if def.temp then
        Vehicles.cleanupSessionVehicle(vehicleId, 'despawned')
        return true
    end

    -- A car already out of the world is in the state asked for: success. A car mid-spawn, -store
    -- or -delete is refused.
    local _, err = Vehicles.despawnToGarage(vehicleId)
    if err then return false, err end
    return true
end
exports('DespawnVehicle', function(vehicleId, opts) return Vehicles.despawnByRef(vehicleId, opts) end)

--- Take a car out of the world, whoever's it is: someone's own car goes into its garage, a temporary one is
--- forgotten, and a street car whip only noticed is deleted too (letting it go would hand it back to GTA where it
--- stands). Answers true, or false and why.
---@param vehicleId number
---@return boolean ok, string|nil err
function Vehicles.removeFromWorld(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'Vehicle not found' end
    local entity = Vehicles.getEntity(vehicleId)   -- (read first: once let go of, whip no longer knows it)
    local ok, err = Vehicles.despawnToGarage(vehicleId)
    if ok == nil then return false, err end
    if def.session and not def.temp and entity and DoesEntityExist(entity) then DeleteEntity(entity) end   -- (its keys were stripped)
    return true
end

--- Take a vehicle out of a garage. Marks it 'out' and locked; it still has to be spawned (retrieving decides the car
--- may come out, spawning decides where).
---@param vehicleId number|WhipVehicleRef|nil
---@param garageKey string|nil  defaults to the garage it is assigned to
---@return boolean ok, string|nil err
exports('RetrieveVehicle', function(vehicleId, garageKey)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end

    if garageKey == nil then
        local veh = Vehicles.context(vehicleId)
        garageKey = veh and veh.garage or nil
    end

    return Vehicles.retrieve(vehicleId, garageKey)
end)

-- GetVehicle(id) and GetVehicle({ entity = e }) stay apart: vehicleIds and entity handles are plain
-- integers in the same range, and guessing which one was meant would return a different car.

--- Is this player in the driver's seat of this vehicle? The cheap answer (three natives, no
--- allocation, no scan) for a question asked many times a second.
---@param source number|string|nil
---@param vehicleId number|WhipVehicleRef|nil
---@return boolean
exports('IsPlayerDrivingVehicle', function(source, vehicleId)
    source = Sanitize.id(source)
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not source or not vehicleId then return false end
    return Vehicles.isPlayerDriving(source, vehicleId)
end)

--- Is this player anywhere inside this vehicle? Passengers included: the check for "may they open the glovebox"
--- (IsPlayerDrivingVehicle is the one for "may they report fuel burn").
---@param source number|string|nil
---@param vehicleId number|WhipVehicleRef|nil
---@return boolean
exports('IsPlayerInVehicle', function(source, vehicleId)
    source = Sanitize.id(source)
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not source or not vehicleId then return false end
    return Vehicles.isPlayerIn(source, vehicleId)
end)

--- Which whip car is this player sitting in? The server's view, never the client's word. `opts.driver = true` wants
--- the driver's seat; without it any seat will do. Returns false (not nil) with the why.
---     local vehicleId, why = exports.whip_core:GetPlayerVehicle(source, { driver = true })
---@param source number|string|nil
---@param opts table|nil  { driver?: boolean }
---@return number|false vehicleId, string|nil why  a sentence you can show the player
exports('GetPlayerVehicle', function(source, opts)
    source = Sanitize.id(source)
    if not source then return false, 'Invalid source' end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'Player not found' end
    local entity = GetVehiclePedIsIn(ped, false)
    if not entity or entity == 0 then return false, 'You need to be in a vehicle' end
    if type(opts) == 'table' and opts.driver and GetPedInVehicleSeat(entity, -1) ~= ped then
        return false, 'You need to be driving'
    end
    local vehicleId = Vehicles.getEntityVehicleId(entity)
    if not vehicleId then return false, 'That vehicle is not one whip looks after' end
    return vehicleId
end)

--- Where is this vehicle? Three floats, in the shape `near.at` wants. Only a car in the world answers (a last
--- recorded spot would let someone act on a car nobody can see); for where a car was last seen, GetVehicle(id).coords.
---@param vehicleId number|WhipVehicleRef|nil
---@return number|nil x  nil when the car is not in the world
---@return number|nil y
---@return number|nil z
exports('GetVehiclePosition', function(vehicleId)
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return nil end

    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return nil end
    local c = GetEntityCoords(entity)
    return c.x, c.y, c.z
end)

--- A place to put a car, as the vehicle exports accept it: a vector4 (heading in `w`), a vector3,
--- or a table `{ x, y, z, heading }`. Shared by CreateOwnedVehicle and SpawnTempVehicle.
---@param s any
---@param name string  the argument's name, for the refusal
---@return table|nil place  { x, y, z, heading }
---@return string|nil err
local function placeArg(s, name)
    local kind = type(s)
    if kind ~= 'vector4' and kind ~= 'vector3' and kind ~= 'table' then
        return nil, ('%s must be a vector4 or { x, y, z, heading }'):format(name)
    end
    local x, y, z = tonumber(s.x), tonumber(s.y), tonumber(s.z)
    if not (x and y and z) then return nil, ('%s needs x, y and z'):format(name) end

    -- Only a vector4 has a `w`; asking a vector3 for one is an error, not a nil.
    local heading = 0.0
    if kind == 'vector4' then heading = s.w
    elseif kind == 'table' then heading = tonumber(s.w) or tonumber(s.heading) or 0.0 end

    return { x = x, y = y, z = z, heading = heading }
end

--- Create a vehicle owned by a player's character (a dealership, a heist reward, a job vehicle; a row written
--- straight to the database is invisible until a restart). ownerCharId comes from the player record, not `data`.
--- Returns `(vehicleId, err)`, with `false` rather than nil on failure. The plate is a field of the vehicle:
---     local vehicleId, err = exports.whip_core:CreateOwnedVehicle(source, { model = 'adder' })
---     local plate = exports.whip_core:GetVehicle(vehicleId).plate
--- One call for a whole sale, undo included:
---     exports.whip_core:CreateOwnedVehicle(source, { model = 'bati' }, {
---         giveKey = true,                                -- put a key in their pockets
---         spawnAt = vector4(-45.0, -1098.0, 26.4, 70.0), -- and bring it out here
---     })
--- All or nothing: if the spawn or the key fails the car is deleted again and you get `(false, reason)`. One
--- exception, a database fault: `(false, reason, true)` means the car was saved (with the payment that rode it)
--- but could not be read back yet; it is theirs and comes to their garage once it reads back, so do not refund.
--- Refund only on `false` with no third value. The type comes from the vehicle catalog when you do not pass
--- `vehType`. `stats`: what it starts with, by stat name (`{ fuel = 100 }`); one left out reads its registered default.
--- The answer is the vehicleId, not a table: every vehicle export and event names a car by id.
---@param source number         the buying/receiving player
---@param data table            { model, plate?, garage?, stats?, properties?, vehType?, trunkSlots?, trunkMaxWeight?, gloveboxSlots?, gloveboxMaxWeight? }
---@param opts table|nil        { giveKey?: boolean, spawnAt?: vector4|{x,y,z,heading} } — spawnAt makes it 'out' there; without it the car is garaged
---@return number|false vehicleId, string|nil err, boolean|nil saved  saved: made and kept although `false` (above)
function Vehicles.createOwned(source, data, opts)
    local player = Players[source]
    if not player then return false, 'Player not loaded' end
    if type(data) ~= 'table' then return false, 'Expected a table' end
    opts = type(opts) == 'table' and opts or {}

    local model = Sanitize.string(data.model, 60)
    if model == '' then return false, 'No model' end

    -- The only states a new vehicle can be created in.
    local state = Sanitize.enum(data.state, { 'garaged', 'out' }, 'garaged')

    -- Where it comes out, if at all: the row says 'out' from the start.
    local spawnAt
    if opts.spawnAt ~= nil then
        local where, whereErr = placeArg(opts.spawnAt, 'spawnAt')
        if not where then return false, whereErr end
        -- A taken spot is refused before any car is made (the last sale's car on the forecourt).
        local blocked = Vehicles.spotBlocked(where.x, where.y, where.z, { exceptSource = source })
        if blocked then return false, blocked end
        -- Nor for a builder in Isolate world: it would come out where they are not.
        local away = Vehicles.cannotBringOutFor(source)
        if away then return false, away end
        spawnAt = where
        state = 'out'
    end

    -- 'out' only with a place to be out: spawnAt is what puts it in the world.
    if state == 'out' and not spawnAt then
        return false, "state = 'out' needs opts.spawnAt: that is what puts the car in the world"
    end

    local def, createErr, saved = Vehicles.create({
        ownerCharId       = player.charId,
        model             = model,
        plate             = data.plate,
        state             = state,
        garage            = data.garage,
        vehStats          = type(data.stats) == 'table' and data.stats or nil,
        properties        = data.properties,
        -- From spawnAt only: a garaged car has no position.
        x                 = spawnAt and spawnAt.x,
        y                 = spawnAt and spawnAt.y,
        z                 = spawnAt and spawnAt.z,
        heading           = spawnAt and spawnAt.heading,
        -- Only the entity types CreateVehicleServerSetter knows; anything else is worked out from
        -- the catalog by Vehicles.create.
        vehType           = Sanitize.enum(data.vehType,
            { 'automobile', 'bike', 'boat', 'heli', 'plane', 'submarine', 'trailer', 'train' }, nil),
        trunkSlots        = data.trunkSlots,
        trunkMaxWeight    = data.trunkMaxWeight,
        gloveboxSlots     = data.gloveboxSlots,
        gloveboxMaxWeight = data.gloveboxMaxWeight,
        -- Read back late (see Vehicles.create): theirs, put away in their garage, with its key when they are still here
        onLate            = function(late)
            if late.state == 'out' then pcall(Vehicles.store, late.vehicleId, late.garage) end
            local now = Players[source]
            if now and now.charId == player.charId then
                if opts.giveKey then pcall(Vehicles.giveKey, source, now, late.vehicleId) end
                NotifyPlayer(source, 'Your vehicle is ready — it is waiting in your garage', 'success', 10000)
            end
        end,
    })

    -- Made but not loaded yet (`saved`): the car is theirs and on disk with whatever paid for it, so the third value
    -- tells the caller not to undo the sale (audit 20, VEH-5). It comes to their garage when its id reads back.
    if not def then
        if saved then
            NotifyPlayer(source, 'Your vehicle is yours, but could not be brought out — it will be waiting in your garage', 'warning', 10000)
        end
        return false, createErr or 'Database insert failed', saved == true
    end
    local vehicleId = def.vehicleId

    -- Undo everything, for a later step that failed. The car goes, or the sale stands: a delete that
    -- keeps failing leaves the car theirs, put away in their garage, and the answer is the car (so
    -- nothing is refunded for a car they have).
    local function undo(reason)
        for attempt = 1, 3 do
            if Vehicles.delete(vehicleId) then return false, reason end
            if attempt < 3 then Wait(500) end
        end
        print(('[whip_core:vehicle] CRITICAL: CreateOwnedVehicle could not remove vehicle #%d after: %s — it stays the buyer\'s, put away in their garage')
            :format(vehicleId, reason))
        pcall(Vehicles.store, vehicleId, def.garage)
        NotifyPlayer(source, 'Your vehicle is yours, but could not be brought out — it is waiting in your garage', 'warning', 10000)
        return vehicleId
    end

    -- Spawn BEFORE the key, so a failed spawn has no key to take back.
    if spawnAt then
        -- The spot asked again: the INSERT above waited, and a second buyer could pass the first
        -- check meanwhile. Nothing yields between this and the spawn.
        local blockedNow = Vehicles.spotBlocked(spawnAt.x, spawnAt.y, spawnAt.z, { exceptSource = source })
        if blockedNow then return undo(blockedNow) end
        local entity, spawnErr = Vehicles.spawn(vehicleId, spawnAt.x, spawnAt.y, spawnAt.z, spawnAt.heading)
        if not entity then return undo('could not spawn it: ' .. tostring(spawnErr)) end
    end

    if opts.giveKey then
        local keyOk, keyErr = Vehicles.giveKey(source, player, vehicleId)
        if not keyOk then return undo('could not give the key: ' .. tostring(keyErr)) end
    end

    return vehicleId
end
exports('CreateOwnedVehicle', Vehicles.createOwned)

--- Put a temporary car in the world (a rental, a job van, a test drive). Nobody owns it and it is never saved, but
--- it has a vehicleId, stats, data, a trunk and keys.
---     local vehicleId, err = exports.whip_core:SpawnTempVehicle('speedo', vector4(x, y, z, h), {
---         forSource    = source,   -- the player it is for; they get a key (giveKey = false to skip)
---         despawnAfter = 1800,     -- seconds; removed after half an hour
---     })
--- It belongs to your resource and is removed when it stops, after ten minutes with nobody near it
--- (`idleDespawn = false` turns that off), and when `despawnAfter` runs out even if somebody is driving. DespawnVehicle
--- removes it early. Each fires `whip_core:vehicle:released` with a `reason` ('expired', 'idle', 'stopped', 'despawned').
--- It spawns locked (`locked = false` for one that stands open). `keyInIgnition` puts a key in its ignition so the
--- driver can start it. All or nothing: if the key cannot be given the car is removed and you get `(false, reason)`.
--- GetVehicle(vehicleId) has `.plate`, `.netId` and `.temp = true`.
--- `tag = 'name'` files the car under one of your tags, so ReleaseTag('name') removes everything under it; spawning
--- under a released tag is refused. `secure = true`: its lock can't be picked or its ignition hacked, only its key works.
---@param model string
---@param coords vector4|vector3|table  where; `{ x, y, z, heading }` works too
--- `bucket = n` makes it in that routing bucket from its birth (default 0, the shared world).
--- `force = true` makes it even when the spot is not clear (GTA pushes whatever it lands on aside).
---@param opts table|nil  { plate?, vehType?, forSource?, giveKey?, despawnAfter?, locked?, keyInIgnition?, idleDespawn?, tag?, secure?, bucket?, force? }
---@return number|false vehicleId, string|nil err
exports('SpawnTempVehicle', function(model, coords, opts)
    return Vehicles.spawnTempFor(model, coords, opts, GetInvokingResource() or GetCurrentResourceName())   -- the caller first
end)

--- Make a temporary car secure (lock can't be picked, ignition can't be hacked: only its key works), or back to
--- any key of its. A secure car's keys carry a token of this car (Vehicles.keyFits), since session ids start again
--- after a restart. Made secure it gets a new token, so every key cut before stops fitting; cut its key after. On a
--- car that is out (not `fresh`), whoever holds or sits with a key of it is told again.
---@param vehicleId number
---@param on boolean
---@param fresh boolean|nil  the car is being made: nobody holds a key of it yet
---@return boolean ok
---@return string|nil err
function Vehicles.setSecure(vehicleId, on, fresh)
    local def = Vehicles._records[vehicleId]
    if not def or not def.temp then return false, 'Only a temporary car' end
    if on then
        def.secure = true
        def.keyToken = Vehicles.newKeyToken(vehicleId, def.keyToken)
    else
        def.secure, def.keyToken = nil, nil
    end
    if not fresh then
        Vehicles.resyncAllKeys()
        Vehicles.tellIgnition(vehicleId)
    end
    return true
end

--- A new token for a car's keys (at most 19 characters), never the one it has now.
---@param vehicleId number
---@param was string|nil  its token now
---@return string
function Vehicles.newKeyToken(vehicleId, was)
    local token
    repeat
        token = ('%x%x%x'):format(math.random(0x10000000, 0x7fffffff), os.time() % 0x10000000, vehicleId % 0x10000)
    until token ~= was
    return token
end

--- Change an owned car's locks: every key of it cut before stops fitting, wherever it is (pockets, a stash, a boot,
--- its own ignition, the ground, a character who is not playing), and the keys cut after fit. Saved with the car, so
--- it lasts through a restart. Whoever holds or sits with a key of it is told again; a car running on an old key in
--- its ignition stops.
---@param vehicleId number
---@return boolean ok
---@return string|nil err
function Vehicles.changeLocks(vehicleId)
    local def = Vehicles._records[vehicleId]
    if not def then return false, 'Vehicle not found' end
    -- A street car or a temporary one has no row to keep its locks in (a temporary car is made secure instead).
    if def.session or def.temp then return false, 'Only a car someone owns' end
    local ok, err = Vehicles.persist(vehicleId, { keyToken = Vehicles.newKeyToken(vehicleId, def.keyToken) })
    if not ok then return false, err or 'Could not save the new locks' end
    Vehicles.resyncAllKeys()
    Vehicles.tellIgnition(vehicleId)
    return true
end

--- SpawnTempVehicle's body, with the resource the car belongs to (swept when it stops). whip_core calls
--- this, never the export.
---@param owner string
function Vehicles.spawnTempFor(model, coords, opts, owner)
    opts = type(opts) == 'table' and opts or {}

    model = Sanitize.string(model, 60)
    if model == '' then return false, 'No model' end

    local where, whereErr = placeArg(coords, 'coords')
    if not where then return false, whereErr end

    -- The player it is for, if any. A key goes to them unless giveKey = false.
    local forSource, player = nil, nil
    if opts.forSource ~= nil then
        forSource = Sanitize.id(opts.forSource)
        player = forSource and Players[forSource]
        if not player then return false, 'forSource is not a loaded player' end
    end
    local giveKey = forSource ~= nil and opts.giveKey ~= false
    if opts.giveKey and not forSource then return false, 'giveKey needs forSource (who to give it to)' end

    -- The one plate rule (Vehicles.normalisePlate).
    local plate, plateErr = Vehicles.normalisePlate(opts.plate)
    if plateErr then return false, plateErr end
    local vehType = Sanitize.enum(opts.vehType,
        { 'automobile', 'bike', 'boat', 'heli', 'plane', 'submarine', 'trailer', 'train' }, nil)
    -- Another routing bucket than the shared world's, from its birth (the Director's isolated tests).
    local bucket = nil
    if opts.bucket ~= nil then
        bucket = math.tointeger(tonumber(opts.bucket))
        if not bucket or bucket < 0 or bucket > 0x7fffffff then return false, 'bucket is a routing bucket, a whole number 0 or more' end
    end

    -- The spot must be clear, as for every spawn (Vehicles.spotBlocked). The player it is for may
    -- stand there. `force`: made there whatever is on it.
    if opts.force ~= true then
        local blocked = Vehicles.spotBlocked(where.x, where.y, where.z, { exceptSource = forSource, bucket = bucket or 0 })
        if blocked then return false, blocked end
    end

    -- A run's car: opts.tag files it under the caller's tag, so ReleaseTag removes it with the rest,
    -- and a tag that has ended gets none. opts.secure: no lockpick or ignition hack
    -- (events_vehicles.lua); only its key opens it.
    if opts.tag ~= nil then
        local tagWhy = Registry.badTag(opts.tag)   -- the one tag rule, as every tagged thing
        if tagWhy then return false, tagWhy end
        if not Registry.claimTag(owner, opts.tag) then return false, opts.tag .. ' has ended' end
    end

    local vehicleId, err = Vehicles.spawnTemp(model, where.x, where.y, where.z, where.heading, {
        plate       = plate,
        vehType     = vehType,
        locked      = opts.locked ~= false,
        idleDespawn = opts.idleDespawn ~= false,
        bucket      = bucket,
    }, owner)
    if not vehicleId then return false, tostring(err) end
    Vehicles._records[vehicleId].tempTag = opts.tag
    if opts.secure == true then Vehicles.setSecure(vehicleId, true, true) end

    if giveKey then
        ---@cast forSource -nil   -- giveKey only with a loaded forSource (above)
        ---@cast player -nil
        local keyOk, keyErr = Vehicles.giveKey(forSource, player, vehicleId)
        if not keyOk then
            Vehicles.cleanupSessionVehicle(vehicleId, 'failed')
            return false, 'could not give the key: ' .. tostring(keyErr)
        end
        -- Giving it waits (the pockets are saved): a tag released meanwhile took the car away, with
        -- nothing yet to say whose key to take back. Take it back here.
        if not Vehicles._records[vehicleId] then
            pcall(Vehicles.removeKey, forSource, player, vehicleId)
            return false, 'the car went while its key was being given'
        end
        -- Remembered by CHARACTER, so the key can be taken back when the car goes (see
        -- cleanupSessionVehicle) — a key to a car that no longer exists is just clutter.
        Vehicles._records[vehicleId].tempKeyCharId = player.charId
    end

    -- A key in the ignition, made here. No client has seen the car yet, so nobody to tell: the first
    -- driver's seat check reads it (checkIgnition). Logged entering the game; cleanupSessionVehicle
    -- logs it leaving with the car.
    if opts.keyInIgnition then
        local def = Vehicles._records[vehicleId]
        local keyMeta = def and Vehicles.keyMetadata(vehicleId)   -- the one shape every key of a car is cut with
        if not keyMeta then return false, 'the car went while it was being made' end
        local slot = {
            item     = 'vehicle_key',
            amount   = 1,
            metadata = keyMeta,
        }
        Vehicles.invCache[vehicleId].key[1] = slot
        Log.item(nil, 'gained', slot, {
            detail = ('key for %s, in the ignition of a temporary car (%s)'):format(tostring(def.plate), owner),
        })
    end

    -- The rental clock, checked against the owner as well as the id.
    local after = tonumber(opts.despawnAfter)
    if after and after > 0 then
        SetTimeout(math.floor(after * 1000), function()
            local def = Vehicles._records[vehicleId]
            if def and def.temp == owner then Vehicles.cleanupSessionVehicle(vehicleId, 'expired') end
        end)
    end

    return vehicleId
end

--- Hand a vehicle to another character: an online server id, or { charId = n } online or offline.
--- A `vehicle_key` carries `metadata.vehicleId` and is not tied to the owner, so the seller's key still works.
--- `revokeOldKeys` removes keys from the previous owner's pockets when online; it can't reach a key offline, in a
--- stash, a boot or on the ground. Returns `false` rather than nil on failure.
---@param vehicleId number|WhipVehicleRef|nil
---@param newOwner number|table  an online server id, or { charId = n } online or offline
---@param opts table|nil  { giveKey = true, revokeOldKeys = true, expectedOwner?: number } Expected owner character id
---@return boolean ok
---@return string|nil err
exports('TransferVehicle', function(vehicleId, newOwner, opts)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end

    local newCharId, newSource = WhoIs(newOwner)
    if not newCharId then return false, newSource --[[@as string]] end
    local buyer = newSource and Players[newSource]
    if not buyer then
        local exists = MySQL.scalar.await('SELECT 1 FROM characters WHERE charId = ? AND deleted IS NULL', { newCharId })
        if not exists then return false, 'No such character' end
    end

    opts = type(opts) == 'table' and opts or {}

    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'Vehicle not found' end

    -- Captured before the write, because after it the def no longer remembers who had it.
    local oldCharId = def.ownerCharId

    local ok, err = Vehicles.transferOwner(vehicleId, newCharId, opts.expectedOwner)
    if not ok then return false, err end

    -- Best-effort, from the old owner's own pockets, after the transfer has stood.
    if opts.revokeOldKeys ~= false and oldCharId then
        local seller = PlayersByCharId[oldCharId]
        if seller then
            Vehicles.removeKey(seller.source, seller, vehicleId)
        end
    end

    if buyer and opts.giveKey ~= false then
        Vehicles.giveKey(newSource, buyer, vehicleId)
    end

    return true
end)

--- Destroy a vehicle and everything in it, permanently: the row, trunk, glovebox, ignition contents, entity, queued
--- writes and anybody's open view of its storage. A session vehicle is forgotten. Ungated like every satellite export.
---@param vehicleId number|WhipVehicleRef|nil
---@return boolean ok
---@return string|nil err
exports('DeleteVehicle', function(vehicleId)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if not Vehicles.getDef(vehicleId) then return false, 'Vehicle not found' end

    local ok, why = Vehicles.delete(vehicleId)
    if not ok then return false, why or 'Delete failed' end
    return true
end)

--- Lock or unlock a vehicle. Persists, and applies to the entity if it is in the world.
---@param vehicleId number|WhipVehicleRef|nil
---@param locked boolean
---@return boolean ok, string|nil err
exports('SetVehicleLocked', function(vehicleId, locked)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    return Vehicles.setLocked(vehicleId, locked)
end)

-- Reading a lock: `GetVehicle(id).locked`.

--- The online player a person names, for a key: a key is an item, so it goes into (or out of) pockets that are
--- loaded. A server id, or { charId = n } for a character who is playing now.
---@return number|nil source, table|string playerOrWhy
local function keyHolder(who)
    local charId, src = WhoIs(who)
    if not charId then return nil, src --[[@as string]] end
    ---@cast src number|nil   -- with a charId, WhoIs's second answer is their source
    local player = src and Players[src]
    if not player then return nil, 'They are not online: a key goes into their pockets, so give it when they are' end
    return src, player
end

--- Cut a key of a car into a person's pockets. Refused when they hold one already, unless `opts.spare = true`
--- (a second key, one to hand to a friend).
---@param who number|table  a server id, or { charId = n } while they play
---@param vehicleId number|WhipVehicleRef|nil
---@param opts table|nil  { spare?: boolean }
---@return boolean ok, string|nil err
exports('GiveVehicleKey', function(who, vehicleId, opts)
    local source, player = keyHolder(who)
    if not source then return false, player --[[@as string]] end
    ---@cast player table   -- with a source, keyHolder's second answer is the player
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    local ok, err = Vehicles.giveKey(source, player, vehicleId, { spare = type(opts) == 'table' and opts.spare == true })
    if not ok then return false, err end
    -- Just true: a second value from an export is always a reason (giveKey's is a message).
    return true
end)

--- Change an owned car's locks: every key of it cut so far stops fitting, wherever it is, and keys cut after fit
--- (Vehicles.changeLocks). A street or temporary car is refused.
---@param vehicleId number|WhipVehicleRef|nil
---@return boolean ok, string|nil err
exports('ChangeVehicleLocks', function(vehicleId)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    return Vehicles.changeLocks(vehicleId)
end)

--- How many keys fit this car now, wherever they are (Vehicles.countKeys): a number, or false and why.
---@param vehicleId number|WhipVehicleRef|nil
---@return number|false count, string|nil err
exports('CountVehicleKeys', function(vehicleId)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if not Vehicles.getDef(vehicleId) then return false, 'Vehicle not found' end
    return Vehicles.countKeys(vehicleId)
end)

--- The pockets a person's keys are in: an online player's live ones, or an offline character's keys read from the
--- database (their pockets are in memory only while they play; only the key items, read and never written).
--- A table with `inventory`, as Vehicles.playerHasKey takes it, or nil and why.
---@param who any  a server id, or { charId = n }
---@return table|nil holder
---@return string|nil why
local function keyPockets(who)
    local charId, src = WhoIs(who)
    if not charId then return nil, src --[[@as string]] end
    ---@cast src number|nil   -- with a charId, WhoIs's second answer is their source
    local player = src and Players[src]
    if player then return player end
    -- Their last session's save first (its pockets are `player:<charId>`): read before it lands, and these are the
    -- keys they had before that session.
    if not Stores.settle('player:' .. tostring(charId)) then
        return nil, 'Their last save has not landed yet — try again in a moment'
    end
    -- A charId with no character (never made, or deleted) is said so, not answered as one with no keys.
    local found, exists = pcall(MySQL.scalar.await,
        'SELECT 1 FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL', { charId })
    if not found then return nil, 'The database could not be reached — try again' end
    if not exists then return nil, 'No such character' end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT `container`, `slot`, `item`, `metadata` FROM `character_inventory` WHERE `charId` = ?', { charId })
    if not ok then return nil, 'The database could not be reached — try again' end
    local inventory = {}
    for _, row in ipairs(rows or {}) do
        if Inventory.isIgnitionKey(row.item) then
            inventory[row.container] = inventory[row.container] or {}
            inventory[row.container][row.slot] = { item = row.item, amount = 1, metadata = Inventory.readMetadata(row.metadata,
                ('character %s %s slot %s'):format(tostring(charId), tostring(row.container), tostring(row.slot))) }
        end
    end
    return { inventory = inventory }
end

--- Has this person a key for this car? A server id, or `{ charId = n }` for a character online or not.
exports('HasVehicleKey', function(who, vehicleId)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    local holder, why = keyPockets(who)
    if not holder then return false, why end   -- a yes/no read: false, and why
    return Vehicles.playerHasKey(holder, vehicleId)
end)

--- The cars a person's keys fit: { [vehicleId] = plate }. A server id, or `{ charId = n }`, online or not.
exports('GetPlayerVehicleKeys', function(who)
    local holder, why = keyPockets(who)
    if not holder then return {}, why end   -- a list read: empty, and why
    return Vehicles.getPlayerKeys(holder)
end)

--- Find the vehicle wearing this plate, adopting it as a session vehicle if whip has never seen it, for a caller
--- with a plate and nothing else. Returns `(vehicleId|false, err)`.
--- Or the car itself: `{ entity = e }` or `{ netId = n }` adopts exactly that car (a plate is text a driver can
--- change, so pass the entity when you have it): `exports.whip_core:AdoptVehicle({ entity = veh })`.
--- `player = source` with the car adopts it for that player, counting against their street-car cap (20).
---@param ref string|{ entity?: number, netId?: number, player?: number }  a plate, or the car
---@return number|false vehicleId, string|nil err
local function adoptVehicle(ref)
    if type(ref) == 'table' then
        local entity = tonumber(rawget(ref, 'entity'))
        local netId = tonumber(rawget(ref, 'netId'))
        if not entity and netId then entity = NetworkGetEntityFromNetworkId(netId) end
        if not entity or entity == 0 or not DoesEntityExist(entity) then return false, 'No vehicle there' end
        if GetEntityType(entity) ~= 2 then return false, 'That is not a vehicle' end
        local player = tonumber(rawget(ref, 'player'))
        local known = Vehicles.getEntityVehicleId(entity)
        if player and not known and not Vehicles.mayAdoptStreetCar(player) then
            return false, 'Too many street cars brought in already'
        end
        local vehicleId, why = Vehicles.adoptEntity(entity)
        if not vehicleId then return false, why or 'Could not adopt that vehicle' end
        if player and not known then Vehicles.noteStreetCarAdopted(vehicleId, player) end
        return vehicleId
    end

    local plate = ref
    if type(plate) ~= 'string' then return false, 'Pass a plate, or { entity = vehicle } / { netId = id }' end
    plate = Sanitize.string(plate, 10)
    if plate == '' then return false, 'plate required' end

    local vehicleId = Vehicles.ensureSessionVehicle(plate)
    if not vehicleId then return false, 'No vehicle with that plate' end
    return vehicleId
end

exports('AdoptVehicle', adoptVehicle)

-- Ownership and kind are fields of GetVehicle (`.session`, `.owner` = { charId, name, online }). Fuel is a stat,
-- read and written with GetVehicleStat / SetVehicleStat like every other.

--- `true` / `false, why` like GiveVehicleKey.
exports('RemoveVehicleKey', function(who, vehicleId)
    local source, player = keyHolder(who)
    if not source then return false, player end
    ---@cast player table   -- with a source, keyHolder's second answer is the player
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if not Vehicles.removeKey(source, player, vehicleId) then
        return false, 'They have no key for that vehicle'
    end
    return true
end)

-- Vehicle appearance exports: the server decides what a vehicle looks like (a resource calls in, whip stores it and
-- shows everyone). A client's own report changes only dirt: a paid-for look is never the customer's word.

--- Which client is simulating this vehicle, if any (the appearance natives only take effect for the client with
--- network control, so the write goes to that one).
---@param entity number
---@return number|nil source
local function entityOwner(entity)
    if not entity or entity == 0 then return nil end

    local owner = NetworkGetEntityOwner(entity)
    if not owner or owner < 0 then return nil end
    return owner
end

--- Push a vehicle's stored appearance out to whoever can act on it.
---@param vehicleId number
---@param def table
local function pushAppearance(vehicleId, def)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return end

    local payload = {
        vehicleId  = vehicleId,
        plate      = def.plate,
        properties = def.properties,
    }

    local owner = entityOwner(entity)
    if owner then
        TriggerClientEvent('whip_core:client:vmApplyMods', owner, payload)
    else
        -- Nobody is simulating it. Tell the players in range and let whoever has it streamed in
        -- take control — clients with no entity for this id return immediately.
        local c = GetEntityCoords(entity)
        SendToPlayers(PlayersInRange(c.x, c.y), 'whip_core:client:vmApplyMods', payload)
    end
end

--- Change how a vehicle looks, from the server, and store it. The props are merged over what the vehicle carries
--- (pass a field as its default to clear it) and filtered through Vehicles.sanitizeProperties, so `plate` and
--- `model` can't be written this way.
---     exports.whip_core:SetVehicleAppearance(vehicleId, { mods = { ['11'] = 3 }, color1 = 27 })
--- `opts.data` / `opts.clearData` set and remove VehicleData keys in the same write as the look.
---@param vehicleId number|WhipVehicleRef|nil
---@param props table  appearance fields to apply over the current ones
---@param opts table|nil  { data = { [key] = value }, clearData = { key, ... } }
---@return boolean ok, string|nil err
exports('SetVehicleAppearance', function(vehicleId, props, opts)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if type(props) ~= 'table' then return false, 'props must be a table' end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'opts must be a table' end
    local data, clearData = opts and opts.data, opts and opts.clearData
    if data ~= nil and type(data) ~= 'table' then return false, 'opts.data must be a table of key = value' end
    if clearData ~= nil and type(clearData) ~= 'table' then return false, 'opts.clearData must be a list of keys' end

    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'vehicle not found' end

    -- The data goes into memory first, checked as SetVehicleData checks a table of them; the look's write carries it.
    local change
    if data or clearData then
        local stageErr
        change, stageErr = VehicleData.stage(vehicleId, data or {}, clearData or {}, GetInvokingResource() or GetCurrentResourceName())
        if not change then return false, stageErr end
        if change.count == 0 then change = nil else VehicleData.replicate(vehicleId) end
    end

    -- Merged, not replaced: changing the wheels must not reset the rest of the build.
    local merged = {}
    for k, v in pairs(def.properties or {}) do merged[k] = v end
    for k, v in pairs(props) do merged[k] = v end

    -- Mods merge one level deeper: setting mod 11 must not drop mod 23. Slot keys are made strings
    -- first, so 11 and "11" are one slot.
    local function slotKey(k)
        local n = tonumber(k)
        if n and n == math.floor(n) then return tostring(math.floor(n)) end
        return k
    end
    if type(props.mods) == 'table' then
        local mods = {}
        for k, v in pairs((def.properties or {}).mods or {}) do mods[slotKey(k)] = v end
        for k, v in pairs(props.mods) do mods[slotKey(k)] = v end
        merged.mods = mods
    end
    -- Extras the same way (whip_autos' Extras shelf sells one at a time): switching extra 3 keeps extra 5.
    if type(props.extras) == 'table' then
        local extras = {}
        for k, v in pairs((def.properties or {}).extras or {}) do extras[slotKey(k)] = v end
        for k, v in pairs(props.extras) do extras[slotKey(k)] = v end
        merged.extras = extras
    end

    -- The write's answer is the export's answer. Pushed either way, and what is pushed is what the
    -- server now holds: on a failed write persist puts the record back, so the car shows its old
    -- look. False means nothing changed; the caller should refund.
    local saved, saveErr = Vehicles.saveProperties(vehicleId, merged, change and { with = { change.store } })
    pushAppearance(vehicleId, def)
    if not saved then
        if change then
            change.undo()
            VehicleData.replicate(vehicleId)
        end
        return false, saveErr or 'save failed'
    end
    if change then change.announce() end
    -- A session car (a street car, a rental) has no row: the look lasts as long as the car.
    -- GetVehicle(id).session says which a car is, so a seller can tell the buyer.
    return true
end)

--- Put a vehicle back to the appearance the server has stored: the undo for anything a client did locally (mods
--- set with network control replicate to everyone, e.g. an abandoned shop preview).
---@param vehicleId number|WhipVehicleRef|nil
---@return boolean ok, string|nil err
exports('RestoreVehicleAppearance', function(vehicleId)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end

    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'vehicle not found' end

    pushAppearance(vehicleId, def)
    return true
end)

-- Sentinel truth: the entity's owning client (usually the driver) can write its bags, so every key this file stamps
-- is forgeable. The Sentinel (server/sentinel.lua) watches them; the truth functions live here with the private
-- state that answers them.

--- Resolve a tracked entity back to its vehicleId without reading the bag (the bag is what is being verified).
--- Goes through Vehicles._byEntity (a hit is believed only if the forward table agrees); it runs on every
--- watched-key echo, so it must not walk every car. A miss still walks, so a binding set elsewhere is found,
--- put back into the index, and said on the console.
---@param entity number
---@return number|nil vehicleId
function Vehicles.getTrackedVehicleIdForEntity(entity)
    local vid = Vehicles._byEntity[entity]
    if vid ~= nil and Vehicles._entities[vid] == entity then return vid end
    for id, ent in pairs(Vehicles._entities) do
        if ent == entity then
            -- Only if it is still that car (a stale forward entry may point at a reused handle). The
            -- fingerprint, not the stamp: the stamp is what the caller is verifying.
            local fp = Vehicles._fingerprint[id]
            if fp ~= nil and DoesEntityExist(entity) and NetworkGetNetworkIdFromEntity(entity) == fp.netId
                and GetEntityModel(entity) == fp.model
                and (not GetEntityOrphanMode or GetEntityOrphanMode(entity) == 2) then
                print(('[whip_core:vehicle] entity index missed vehicle %d — repaired (a write outside setTracked?)'):format(id))
                Vehicles._byEntity[entity] = id
                return id
            end
            return nil
        end
    end
    return nil
end

-- An untracked entity carrying any of these keys answers nil — which strips the key, and
-- that is the correct reading: either a tamper, or a stale stamp reconcile has retired.
Sentinel.watch({
    key = VEHICLE_STATE_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        return Vehicles.getTrackedVehicleIdForEntity(entity)
    end,
})

Sentinel.watch({
    key = VEHICLE_SESSION_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        local vid = Vehicles.getTrackedVehicleIdForEntity(entity)
        if not vid then return nil end
        local def = Vehicles._records[vid]
        -- true-or-absent, never false: the absence rule the key is documented with.
        return (def and def.session) and true or nil
    end,
})

-- The door mask's truth is the server's copy.
Sentinel.watch({
    key = VEHICLE_DOORS_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity) return Vehicles.getDoorMask(entity) end,
})

Sentinel.watch({
    key = VEHICLE_APPEARANCE_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        local vid = Vehicles.getTrackedVehicleIdForEntity(entity)
        if not vid then return nil end
        local def = Vehicles._records[vid]
        local props = def and def.properties
        -- The empty→nil rule from stampAppearance, reproduced exactly: no stored
        -- appearance means the key is ABSENT, not an empty table.
        if type(props) ~= 'table' or next(props) == nil then return nil end
        return props
    end,
})

exports('SetVehicleCustody', function(ref, held, expectedOwner)
    local owner = Registry.caller()
    if type(held) ~= 'boolean' then return false, 'Invalid custody state' end
    local vehicleId, why = Vehicles.idFromRef(ref)
    if not vehicleId then return false, why end
    local def = Vehicles._records[vehicleId]
    if not def or def.session then return false, 'Owned vehicle not found' end
    if expectedOwner ~= nil and def.ownerCharId ~= tonumber(expectedOwner) then return false, 'Vehicle ownership changed' end
    local holder = heldBy(def)
    if holder and holder ~= owner then return false, 'Vehicle is held by another resource' end
    if Vehicles._transitionLocks[vehicleId] then return false, 'Vehicle is busy' end
    if not held and not def.reservation then return true end
    return underTransitionLock(vehicleId, 'custody', function()
        return Vehicles.persist(vehicleId, { reservation = held and owner or Vehicles.NULL })
    end)
end)
