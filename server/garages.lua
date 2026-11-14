-- ============================================
-- GARAGES — Server Module
-- ============================================
--
-- The same shape the rest of the framework has: a private record, one write funnel, reads that hand
-- back copies, and a declared projection for anything that crosses to a client.
--
-- A garage is a location with a spawn point. What is IN it is not stored here — a vehicle's `garage`
-- column is the only record of that, so there is one answer to "where is this car" and nothing to
-- keep in step.

Garages = {}

--- Every garage, by key. PRIVATE.
---
--- Named `_records` rather than `cache` for the reason the vehicle records are: a table called
--- `cache` invites callers to treat it as a convenience copy they may read freely, and it was
--- neither — it is the live authority, and handing it out let a reader become a writer by accident.
--- Internal code uses Garages.get / Garages.getAll; anything outside whip_core gets a snapshot.
Garages._records = {}

--- What a garage row is allowed to contain, and what each field must be.
---
--- Declared once so update() cannot drift from create() the way eleven hand-written statements
--- drifted in the vehicle system. `key` is absent on purpose: it is the identity, set at creation
--- and never rewritten.
local FIELDS = {
    name         = { kind = 'string', default = 'Garage' },
    x            = { kind = 'number', default = 0 },
    y            = { kind = 'number', default = 0 },
    z            = { kind = 'number', default = 0 },
    heading      = { kind = 'number', default = 0 },
    spawnX       = { kind = 'number', default = 0 },
    spawnY       = { kind = 'number', default = 0 },
    spawnZ       = { kind = 'number', default = 0 },
    spawnHeading = { kind = 'number', default = 0 },
    blipSprite   = { kind = 'number', default = 357 },
    blipColor    = { kind = 'number', default = 3 },
}

--- Column order for the writes. A fixed list, so the INSERT and the UPDATE cannot disagree about
--- which columns exist.
local COLUMNS = {
    'name', 'x', 'y', 'z', 'heading',
    'spawnX', 'spawnY', 'spawnZ', 'spawnHeading',
    'blipSprite', 'blipColor',
}

--- Coerce one field, or fall back to what is already there.
local function coerce(name, value, current)
    local f = FIELDS[name]
    if not f then return nil end
    if value == nil then return current ~= nil and current or f.default end

    if f.kind == 'number' then
        return tonumber(value) or (current ~= nil and current or f.default)
    end
    return tostring(value)
end

-- ============================================
-- Database
-- ============================================

function Garages.ensureTable()
    local ok, err = pcall(MySQL.query.await, WithTableCollation [[
        CREATE TABLE IF NOT EXISTS `garages` (
            `garageId`      INT UNSIGNED  NOT NULL AUTO_INCREMENT,
            `key`           VARCHAR(60)   NOT NULL,
            `name`          VARCHAR(100)  NOT NULL DEFAULT 'Garage',
            `x`             FLOAT         NOT NULL DEFAULT 0,
            `y`             FLOAT         NOT NULL DEFAULT 0,
            `z`             FLOAT         NOT NULL DEFAULT 0,
            `heading`       FLOAT         NOT NULL DEFAULT 0,
            `spawnX`        FLOAT         NOT NULL DEFAULT 0,
            `spawnY`        FLOAT         NOT NULL DEFAULT 0,
            `spawnZ`        FLOAT         NOT NULL DEFAULT 0,
            `spawnHeading`  FLOAT         NOT NULL DEFAULT 0,
            `blipSprite`    INT           NOT NULL DEFAULT 357,
            `blipColor`     INT           NOT NULL DEFAULT 3,
            `resource`      VARCHAR(64)   DEFAULT NULL,
            PRIMARY KEY (`garageId`),
            UNIQUE KEY `uk_key` (`key`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {})

    if not ok then
        print(('[whip_core:garage] ERROR creating garages table: %s'):format(tostring(err)))
    end
    return ok
end

function Garages.loadAll()
    Garages.ensureTable()

    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `garages`', {})
    if not ok then
        print(('[whip_core:garage] ERROR loading garages: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    Garages._records = {}

    if rows then
        for _, row in ipairs(rows) do
            local def = { garageId = row.garageId, key = row.key, resource = row.resource }
            for name, f in pairs(FIELDS) do
                def[name] = row[name] ~= nil and row[name] or f.default
            end
            Garages._records[row.key] = def
        end
    end
end

function Garages.seedFromConfig()
    if next(Garages._records) then return end
    if not Config.Garages or not next(Config.Garages) then return end

    for key, g in pairs(Config.Garages) do
        local spawnPos = g.spawnPos or g.pos
        local created, err = Garages.create({
            key          = key,
            name         = g.name or key,
            x            = g.pos.x,     y = g.pos.y,     z = g.pos.z,     heading      = g.pos.w or 0,
            spawnX       = spawnPos.x,  spawnY = spawnPos.y, spawnZ = spawnPos.z, spawnHeading = spawnPos.w or 0,
            blipSprite   = g.blipSprite or 357,
            blipColor    = g.blipColor or 3,
        })

        if not created then
            print(('[whip_core:garage] ERROR seeding garage "%s": %s'):format(key, tostring(err)))
        end
    end
end

-- ============================================
-- Internal accessors — LIVE, whip_core only
-- ============================================

--- The live record. INTERNAL. Anything outside whip_core takes Garages.snapshot instead.
function Garages.get(key)
    return Garages._records[key]
end

--- The live table. INTERNAL, and the same warning applies.
function Garages.getAll()
    return Garages._records
end

-- ============================================
-- Reads that leave the framework
-- ============================================

-- ============================================
-- Private garages
-- ============================================
--
-- A private garage belongs to something that says who may use it: a property's garage is for its
-- owner and keyholders and nobody else. The system that owns it registers a key prefix and a
-- question, and every garage whose key starts with that prefix is private. The question is asked
-- everywhere a player would use one:
--
--   the bay events (list, retrieve, store)   server/events_vehicles.lua — the rule
--   the bay prompts, the Store option        client/garage_spots.lua — the courtesy
--   the map                                  no blip: it is somebody's home
--   Garages.nearest, GetNearestGarage        skip it: "the garage I am at" is a public one
--
-- ACCESS CAN BE LOST — a key taken back, a house sold — and a car left inside would then be out of
-- its owner's reach for good. Garages.evict moves every car whose owner may no longer use the
-- garage to the nearest public one, and tells them.
--
-- THE PREFIXES CONTAIN A ':', which a key typed into the Garage Manager cannot (Sanitize.key), so no
-- admin-made garage becomes private by accident and the manager cannot rewrite one: it is changed
-- where it is owned.

local _access = {}   -- [prefix] = { canUse = fn(garageKey, charId) -> boolean, label = fn(garageKey) -> string }

--- Claim every garage whose key starts with `prefix`.
---@param prefix string    e.g. 'property:'
---@param canUse function  (garageKey, charId) -> boolean
---@param label function|nil  (garageKey) -> what owns it, for the Garage Manager
function Garages.registerAccess(prefix, canUse, label)
    if type(prefix) ~= 'string' or not prefix:find(':', 1, true) then
        error('Garages.registerAccess: a private prefix must contain a ":"', 2)
    end
    _access[prefix] = { canUse = canUse, label = label }
end

local function accessOf(key)
    if type(key) ~= 'string' then return nil end
    for prefix, a in pairs(_access) do
        if key:sub(1, #prefix) == prefix then return a end
    end
    return nil
end

---@return boolean
function Garages.isPrivate(key)
    return accessOf(key) ~= nil
end

--- May this character use this garage? Always, for a public one.
---@return boolean
function Garages.canUse(key, charId)
    local a = accessOf(key)
    if not a then return true end
    if not charId then return false end
    local ok, res = pcall(a.canUse, key, charId)
    return ok and res == true
end

--- What owns a private garage, in words ('Property #12 · Mega B 805'), or nil.
function Garages.ownerLabel(key)
    local a = accessOf(key)
    if not (a and a.label) then return nil end
    local ok, res = pcall(a.label, key)
    return ok and res or nil
end

--- The private garages this character may use, as a set.
---@return table<string, boolean>
function Garages.accessFor(charId)
    local out = {}
    for key in pairs(Garages._records) do
        if Garages.isPrivate(key) and Garages.canUse(key, charId) then out[key] = true end
    end
    return out
end

--- Tell a player's client which private garages are theirs to use, so it shows only those bays.
function Garages.pushAccess(source)
    local p = Players and Players[source]
    if not (p and p.charId) then return end
    TriggerClientEvent('whip_core:client:garageAccess', source, Garages.accessFor(p.charId))
end

--- The same, for characters by id — whoever of them is online.
---@param charIds number[]
function Garages.pushAccessFor(charIds)
    for _, charId in ipairs(charIds or {}) do
        local p = PlayersByCharId and PlayersByCharId[charId]
        if p and p.source then Garages.pushAccess(p.source) end
    end
end

--- Where a car goes when it may no longer stay in a private garage: the public garage nearest to
--- it, or the server's first garage when it has no position.
---@return string|nil key
function Garages.fallbackFor(key)
    local g = Garages._records[key]
    if g then
        local near = Garages.nearest(g.x, g.y, g.z)
        if near then return near end
    end
    return Vehicles and Vehicles.getDefaultGarage and Vehicles.getDefaultGarage() or nil
end

--- Move cars out of a private garage: every car whose owner may no longer use it, or (everyone)
--- every car in it, as when the garage itself is going. Their owners are told where they went.
---
--- IDEMPOTENT: run it after any change of who may use the garage, and it moves only what has to
--- move. A car that is out keeps being out; its home garage is what changes.
---@param key string
---@param everyone boolean|nil
---@return number moved
function Garages.evict(key, everyone)
    if not (Vehicles and Vehicles.getAll) then return 0 end
    if not everyone and not Garages.isPrivate(key) then return 0 end

    -- The ids first, as Garages.delete does: each move awaits the database, and a car created or
    -- released during one of those awaits would change the table pairs() is walking.
    local ids = {}
    for vehicleId, v in pairs(Vehicles.getAll()) do
        if v.garage == key and not v.session then ids[#ids + 1] = vehicleId end
    end

    local to, moved = nil, 0
    for _, vehicleId in ipairs(ids) do
        local v = Vehicles.getDef(vehicleId)
        if v and v.garage == key and (everyone or not Garages.canUse(key, v.ownerCharId)) then
            to = to or Garages.fallbackFor(key)
            if not to or to == key then
                print(('[whip_core:garage] no public garage to move vehicle #%d out of "%s" to'):format(vehicleId, key))
                return moved
            end
            local ok, err = Vehicles.persist(vehicleId, { garage = to })
            if ok then
                moved = moved + 1
                local p = v.ownerCharId and PlayersByCharId and PlayersByCharId[v.ownerCharId]
                if p and p.source then
                    local dest = Garages._records[to]
                    NotifyPlayer(p.source,
                        ('Your %s (%s) was moved to %s'):format(tostring(v.model), tostring(v.plate),
                            dest and dest.name or to), 'info', 8000)
                end
            else
                print(('[whip_core:garage] could not move vehicle #%d out of "%s": %s')
                    :format(vehicleId, key, tostring(err)))
            end
        end
    end
    return moved
end

--- One garage, as a copy.
---@param key string
---@return table|nil
function Garages.snapshot(key)
    local def = Garages._records[key]
    if not def then return nil end

    local out = { garageId = def.garageId, key = def.key, resource = def.resource }
    for name in pairs(FIELDS) do out[name] = def[name] end
    -- Whose it is, when it is somebody's: the Garage Manager shows it and leaves it alone.
    if Garages.isPrivate(key) then
        out.private = true
        out.managedBy = Garages.ownerLabel(key)
    end
    return out
end

--- Every garage, as copies, keyed the same way.
---@return table
function Garages.snapshotAll()
    local out = {}
    for key in pairs(Garages._records) do out[key] = Garages.snapshot(key) end
    return out
end

--- What a CLIENT is told about the garages.
---
--- A declared projection, not the record (a column added here must not silently become a field on
--- every client): blips and markers need the position, the name and the blip style. The spawn point
--- does not travel; the server places retrieved vehicles itself.
---@return table
function Garages.wire()
    local out = {}
    for key, def in pairs(Garages._records) do
        out[key] = {
            key        = key,
            name       = def.name,
            x          = def.x,
            y          = def.y,
            z          = def.z,
            heading    = def.heading,
            blipSprite = def.blipSprite,
            blipColor  = def.blipColor,
            -- Somebody's: no blip, and its bays only for the players garageAccess names.
            private    = Garages.isPrivate(key) or nil,
            -- Made by a resource that is not running: no blip (see "Who made it" below).
            ownerAway  = Garages.ownerAway(def) or nil,
        }
    end
    return out
end

-- ============================================
-- Who made it
-- ============================================
--
-- A garage CreateGarage made remembers the resource that asked (`resource`; NULL for one an admin
-- or the config made). Its blip shows only while that resource runs. The garage and the cars in it
-- stay: only the blip goes.

---@param def table
---@return boolean
function Garages.ownerAway(def)
    local owner = def and def.resource
    if not owner or owner == GetCurrentResourceName() then return false end
    local state = GetResourceState(owner)
    return state ~= 'started' and state ~= 'starting'
end

-- The maker starting or stopping: its garages' blips come or go on every client. (While stopping its
-- state is 'stopping', while starting 'starting' — Garages.ownerAway reads both right.)
local function ownerChanged(resource)
    for key, def in pairs(Garages._records or {}) do
        if def.resource == resource then
            TriggerClientEvent('whip_core:client:garageUpdated', -1, key, Garages.wire()[key])
        end
    end
end
AddEventHandler('onResourceStart', ownerChanged)
AddEventHandler('onResourceStop', ownerChanged)

--- The garage closest to a point.
---
--- A garage is its marker and its parking bays: each garage's distance is to whichever of its marker
--- or bays is closest.
---
--- And an optional `maxRange`: with it, nothing further away than that counts, so "is this player
--- AT a garage" is one call instead of a call and a distance check.
---
--- Public garages only: a private one (see "Private garages") is somebody's home: an impound or a
--- job asking "which garage is this player at" must not be handed it.
---@param maxRange number|nil
---@return string|nil key, number|nil distance
function Garages.nearest(x, y, z, maxRange)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return nil end
    maxRange = tonumber(maxRange)

    local here = vector3(x, y, z)
    local byGarage = {}

    for key, def in pairs(Garages._records) do
        if not Garages.isPrivate(key) then byGarage[key] = #(here - vector3(def.x, def.y, def.z)) end
    end
    for _, spot in ipairs(GarageSpots and GarageSpots.all() or {}) do
        local current = byGarage[spot.garageKey]
        if current then
            local d = #(here - vector3(spot.x, spot.y, spot.z))
            if d < current then byGarage[spot.garageKey] = d end
        end
    end

    local bestKey, bestDist
    for key, d in pairs(byGarage) do
        if (not maxRange or d <= maxRange) and (not bestDist or d < bestDist) then
            bestKey, bestDist = key, d
        end
    end

    return bestKey, bestDist
end

--- Count vehicles garaged at each garage key.
function Garages.getVehicleCounts()
    local counts = {}
    for key in pairs(Garages._records) do
        counts[key] = 0
    end
    if Vehicles and Vehicles.getAll then
        for _, veh in pairs(Vehicles.getAll()) do
            if veh.state == 'garaged' and veh.garage and counts[veh.garage] ~= nil then
                counts[veh.garage] = counts[veh.garage] + 1
            end
        end
    end
    return counts
end

--- The vehicles sitting in one garage. Already a projection rather than the records themselves.
function Garages.getGarageVehicles(key)
    local vehicles = {}
    if Vehicles and Vehicles.getAll then
        for _, veh in pairs(Vehicles.getAll()) do
            if veh.state == 'garaged' and veh.garage == key then
                vehicles[#vehicles + 1] = {
                    vehicleId   = veh.vehicleId,
                    model       = veh.model,
                    plate       = veh.plate,
                    ownerCharId = veh.ownerCharId,
                    -- The stat block, like every other vehicle payload. This sent a
                    -- flat `fuel` field — the last place on the server still
                    -- projecting one stat by name — and the Garage Manager never
                    -- drew it, so it was a private spelling of a value nothing read.
                    vehStats    = VehicleStats.getStored(veh.vehicleId),
                }
            end
        end
    end
    return vehicles
end

-- ============================================
-- Writes
-- ============================================

--- Create a garage.
---
--- MySQL.insert rather than Stores.runTransaction, and the split is not arbitrary: a transaction
--- reports whether it committed, not what id it allocated, and a create has to hand back the row it
--- made. Vehicles.create takes the same route for the same reason. Everything that does NOT need an
--- id goes through the funnel below.
---@param data table  { key, name?, x?, y?, z?, heading?, spawnX?, spawnY?, spawnZ?, spawnHeading?, blipSprite?, blipColor? }
---@param resource string|nil  the resource that asked (CreateGarage), so the blip shows only while it runs
---@return table|nil garage, string|nil err
function Garages.create(data, resource)
    if type(data) ~= 'table' then return nil, 'Expected a table' end

    local key = data.key
    if not key or key == '' then return nil, 'Key is required' end
    if Garages._records[key] then return nil, 'Key already exists' end

    local def = { key = key, resource = resource }
    local values = {}
    for i = 1, #COLUMNS do
        local name = COLUMNS[i]
        def[name]  = coerce(name, data[name], nil)
        values[i]  = def[name]
    end
    values[#values + 1] = key
    values[#values + 1] = resource

    local placeholders = ('?,'):rep(#COLUMNS) .. '?,?'
    local ok, insertId = pcall(MySQL.insert.await,
        ('INSERT INTO `garages` (`%s`,`key`,`resource`) VALUES (%s)')
            :format(table.concat(COLUMNS, '`,`'), placeholders),
        values
    )

    if not ok or not insertId then
        print(('[whip_core:garage] ERROR creating garage "%s": %s'):format(key, tostring(insertId)))
        return nil, tostring(insertId)
    end

    def.garageId = insertId
    Garages._records[key] = def

    TriggerClientEvent('whip_core:client:garageCreated', -1, key, Garages.wire()[key])
    -- Its first bay, or nobody can reach it. Here, the one create path, so a garage made by the
    -- config seed, the Garage Manager or CreateGarage gets one alike (see GarageSpots.seedGarage).
    GarageSpots.seedGarage(key)
    return Garages.snapshot(key)
end

--- Change a garage.
---
--- THE ROW GOES FIRST, THEN MEMORY. It was the other way round: every field was assigned onto the
--- live record and the write happened afterwards, so a failed write left the server believing a
--- change that was never saved — and believing it until the next restart, when the garage moved
--- back on its own with nothing to explain why.
---@param key string
---@param data table
---@return boolean ok, string|nil err
function Garages.update(key, data)
    local def = Garages._records[key]
    if not def then return false, 'Garage not found' end
    if type(data) ~= 'table' then return false, 'Expected a table' end

    local pending, values = {}, {}
    for i = 1, #COLUMNS do
        local name   = COLUMNS[i]
        pending[name] = coerce(name, data[name], def[name])
        values[i]     = pending[name]
    end
    values[#values + 1] = key

    local sets = {}
    for i = 1, #COLUMNS do sets[i] = ('`%s`=?'):format(COLUMNS[i]) end

    local ok, err = Stores.runTransaction({
        {
            query  = ('UPDATE `garages` SET %s WHERE `key`=?'):format(table.concat(sets, ',')),
            values = values,
        },
    }, 'garage_row')

    if not ok then
        print(('[whip_core:garage] FAILED updating "%s": %s'):format(key, tostring(err)))
        return false, err
    end

    for name, value in pairs(pending) do def[name] = value end

    TriggerClientEvent('whip_core:client:garageUpdated', -1, key, Garages.wire()[key])
    return true
end

--- Delete a garage, and move every vehicle filed under it to `moveTo`, or (none named) the nearest other
--- garage.
---@param key string
---@param moveTo string|nil  the garage its cars go to: a public one, not itself (the panel's choice).
---                          nil keeps the nearest, for scripts (DeleteGarage) and properties.
---@return boolean ok, string|nil err
function Garages.delete(key, moveTo)
    local g = Garages._records[key]
    if not g then return false, 'Garage not found' end

    -- Its cars go to the nearest other garage, and their owners are told (a car filed under no garage
    -- would be stranded). (Garages.evict, which properties use, bails here for a PUBLIC garage: its
    -- "nearest" would be the garage being deleted.) Only with no other garage at all does a car get
    -- none, and such a car is offered at every garage. "The nearest" is asked with this garage out of
    -- the list, so it cannot answer itself.
    --
    -- Or where the admin says: the /whip panel names one garage and they all go there. Somebody's private
    -- garage is no place for strangers' cars, and a garage cannot take its own.
    local to
    if moveTo ~= nil then
        if moveTo == key then return false, 'Its cars cannot go into the garage being deleted' end
        if not Garages._records[moveTo] then return false, 'The garage its cars were to go to is not there' end
        if Garages.isPrivate(moveTo) then return false, 'Its cars cannot go into a private garage' end
        to = moveTo
    else
        Garages._records[key] = nil
        to = Garages.nearest(g.x, g.y, g.z)
        if not to and Vehicles and Vehicles.getDefaultGarage then to = Vehicles.getDefaultGarage() end
        if to == key then to = nil end
        Garages._records[key] = g
    end

    -- The cars move and the garage goes in one transaction (one UPDATE for every car in it, beside the
    -- DELETE), so no car is ever left filed under a garage that no longer exists.
    local ok, err = Stores.runTransaction({
        to and { query = 'UPDATE `vehicles` SET `garage` = ? WHERE `garage` = ?', values = { to, key } }
            or { query = 'UPDATE `vehicles` SET `garage` = NULL WHERE `garage` = ?', values = { key } },
        { query = 'DELETE FROM `garages` WHERE `key` = ?', values = { key } },
    }, 'garage_row')

    if not ok then
        print(('[whip_core:garage] FAILED deleting "%s": %s'):format(key, tostring(err)))
        return false, err
    end

    Garages._records[key] = nil

    -- Memory follows the rows just written, and every owner is told where their car went.
    if Vehicles and Vehicles.getAll then
        local moved = 0
        for _, v in pairs(Vehicles.getAll()) do
            if v.garage == key then
                v.garage = to
                moved = moved + 1
                local p = v.ownerCharId and PlayersByCharId and PlayersByCharId[v.ownerCharId]
                if p and p.source then
                    local dest = to and Garages._records[to]
                    NotifyPlayer(p.source, ('Your %s (%s) was moved to %s — its garage closed')
                        :format(tostring(v.model), tostring(v.plate), dest and dest.name or 'another garage'), 'info', 8000)
                end
            end
        end
        if moved > 0 and not to then
            print(('[whip_core:garage] WARNING: deleted "%s" and there is no other garage — %d vehicle(s) have none until one exists')
                :format(key, moved))
        end
    end

    -- The bays that led here go with it. A spot whose garage is gone is a prompt that opens a list
    -- of nothing — worse than no prompt — and its row would sit in the table forever, since nothing
    -- would ever look it up again.
    --
    -- Guarded because this file loads before server/garage_spots.lua in the manifest, and a garage
    -- deleted during that window should still delete its row rather than erroring.
    if GarageSpots then GarageSpots.deleteForGarage(key) end

    TriggerClientEvent('whip_core:client:garageDeleted', -1, key)
    return true
end

-- ============================================
-- Init
-- ============================================
-- (No file-scope loadAll any more. It ran at script load — BEFORE onResourceStart, therefore
-- before Migrations.run() — so on any boot that migrated the garages table, this cache was
-- filled from the pre-migration schema. player_lifecycle.lua's startup sequence loads it now,
-- after migrations, with every other loadAll.)

-- ============================================
-- Public Exports
-- ============================================
--
-- Garages had no exports at all until these. Every one of these functions existed; none of them
-- could be reached from outside whip_core, which made StoreVehicle(vehicleId, garageKey) an export
-- whose second parameter no satellite could legally obtain — there was no way to list the garages,
-- no way to validate a key, and no way to find the nearest one. The usual result was a hardcoded
-- string copied out of config.lua and a "Wrong garage" error when it drifted.

--- One garage, by key.
---@param key string
---@return table|nil  a COPY — editing it changes nothing
exports('GetGarage', function(key)
    if type(key) ~= 'string' or key == '' then return nil end
    return Garages.snapshot(key)
end)

--- Every garage whip knows about, keyed by garage key.
---@return table  map of key -> garage copy
exports('GetGarages', function()
    return Garages.snapshotAll()
end)

--- The garage closest to a point.
---
--- The call a satellite actually wants: "which garage is this player standing at" is the question
--- an impound, a rental or a job garage asks.
---
--- Counts a garage's parking bays as part of it, and takes an optional `maxRange`:
---
---     local key = exports.whip_core:GetNearestGarage(x, y, z, 10.0)   -- nil unless within 10m
---@param x number|vector3|vector4|table|nil  or the coords, then y is maxRange
---@param y number|nil
---@param z number|nil
---@param maxRange number|nil
---@return string|nil key, number|nil distance
exports('GetNearestGarage', function(x, y, z, maxRange)
    -- (coords, maxRange) as well as (x, y, z, maxRange): a vector3 wherever a position is taken
    if type(x) == 'vector3' or type(x) == 'vector4' or type(x) == 'table' then
        local c = x
        maxRange = y
        x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    end
    return Garages.nearest(x, y, z, maxRange)
end)

--- May this person use this garage? Always true for a public one; for a PRIVATE one (a
--- property's), whatever owns it says — its owner and keyholders.
---
---     if exports.whip_core:CanUseGarage(key, source) then ... end
---
--- The person is `source` or `{ charId = n }` (WhoIs), and the answer is `true` or `false, why` —
--- every access check answers alike.
---@param key string
---@param who number|{ charId: number }
---@return boolean ok
---@return string|nil why
exports('CanUseGarage', function(key, who)
    if type(key) ~= 'string' or not Garages.get(key) then return false, 'No such garage' end
    local charId, why = WhoIs(who)
    if not charId then return false, why --[[@as string]] end
    if Garages.canUse(key, charId) then return true end
    local owner = Garages.ownerLabel(key)
    return false, owner and ('That garage belongs to %s'):format(owner) or 'That garage is private'
end)

--- The vehicles currently stored in one garage, as full GetVehicle snapshots.
---
--- The same shape as GetVehicle and GetVehiclesOf. (The Garage Manager panel gets a small projection,
--- from the internal function.)
---@param key string
---@return table[]  array of GetVehicle snapshots
exports('GetGarageVehicles', function(key)
    if type(key) ~= 'string' or key == '' then return {} end
    if not Garages.get(key) then return {} end

    local out = {}
    for _, row in ipairs(Garages.getGarageVehicles(key)) do
        local snapshot = Vehicles.context(row.vehicleId)
        if snapshot then out[#out + 1] = snapshot end
    end
    return out
end)

--- Create a garage.
---@param data table  { key, name?, x?, y?, z?, heading?, spawnX?, spawnY?, spawnZ?, spawnHeading?, blipSprite?, blipColor? }
---@return table|false garage, string|nil err
exports('CreateGarage', function(data)
    local caller = Registry.caller()   -- first, before anything can yield
    -- Who asked is kept, so the blip shows only while that resource runs ("Who made it").
    local garage, err = Garages.create(data, caller ~= GetCurrentResourceName() and caller or nil)
    -- `false`, not nil. A FiveM export truncates its return list at the first nil, so returning nil
    -- here would take the reason with it and the caller would be told only that something failed.
    if not garage then return false, err or 'Could not create the garage' end
    return garage
end)

-- A garage another running resource made (CreateGarage keeps who) is that resource's to change or delete, as a
-- zone is (DeleteZone). One made in /whip or by a property, or whose resource is not running, is open to any.
local function garageOfAnother(key, caller)
    local g = Garages.get(key)
    local by = g and g.resource
    if by and by ~= caller and Registry.alive(by) then
        return ('garage "%s" belongs to %s: only it can change or delete it'):format(key, by)
    end
    return nil
end

--- Change a garage.
---@param key string
---@param data table  any subset of the writable fields; absent fields are left alone
---@return boolean ok, string|nil err
exports('UpdateGarage', function(key, data)
    local caller = Registry.caller()
    if type(key) ~= 'string' or key == '' then return false, 'key required' end
    local theirs = garageOfAnother(key, caller)
    if theirs then return false, theirs end
    return Garages.update(key, data)
end)

--- Delete a garage. Vehicles stored in it move to the nearest other garage and their owners are
--- told; they are not deleted.
---@param key string
---@return boolean ok, string|nil err
exports('DeleteGarage', function(key)
    local caller = Registry.caller()
    if type(key) ~= 'string' or key == '' then return false, 'key required' end
    local theirs = garageOfAnother(key, caller)
    if theirs then return false, theirs end
    return Garages.delete(key)
end)

--- Move a vehicle to a different garage without taking it out of storage.
---
--- NOT THE SAME AS StoreVehicle, and this is the gap it fills: Vehicles.store refuses anything that
--- is not currently `out` — "Vehicle is already stored" — so until now moving a garaged car between
--- garages was possible only from the admin tool. An impound releasing a car back to its home
--- garage, or a dealership delivering to the buyer's garage of choice, both need exactly this.
--- Lives here rather than vehicles.lua because the garage-key validation is the half that earns
--- its keep; the vehicle write goes through Vehicles.persist either way.
---@param vehicleId number|WhipVehicleRef|nil  a vehicleId or a vehicle reference
---@param garageKey string
---@return boolean ok, string|nil err
exports('SetVehicleGarage', function(vehicleId, garageKey)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if type(garageKey) ~= 'string' or garageKey == '' then return false, 'garageKey required' end

    if not Garages.get(garageKey) then return false, 'No such garage' end
    if not Vehicles.getDef(vehicleId) then return false, 'Vehicle not found' end

    return Vehicles.persist(vehicleId, { garage = garageKey })
end)
