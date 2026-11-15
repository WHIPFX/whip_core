-- ============================================
-- Vehicle claims — a car nobody owns becomes someone's, and a plate changed
-- ============================================
--
-- A boosting job ends with the stolen car scratched clean and kept; a street race's prize is the
-- loser's car. A SESSION car (one whip knows but nobody owns: a run's car from SpawnTempVehicle, a
-- street car whip adopted) is made an OWNED car, saved like any other:
--
--   local vehicleId, why = exports.whip_core:ClaimVehicle(runCarId, source, { plate = 'BOOST01' })
--   exports.whip_core:SetVehiclePlate(vehicleId, 'NEWPLT')
--
-- IN THIS ORDER, so a failure leaves things as they were:
--   1. an owned car is made (its own new id; its plate new unless one is asked for), with the
--      session car's model (read off the car itself, from the vehicle catalog: a street car's record
--      may name no model at all), look and stats (its fuel among them);
--   2. what is in its trunk and glovebox moves across, stack by stack (Stores: logged, and moved back
--      if one will not go, with the new car taken away again);
--   3. only then the session car goes (the point of no return), and the owned one is put where it
--      stood (whoever was driving it is put back behind the wheel), or left in a garage;
--   4. the owner gets its key, and the claim is on their timeline (Log).
-- A car that cannot come out where it stood is waiting in its garage instead; the answer says so.
-- The session car is asked for again after every wait (it can go meanwhile: its run ends, it is put
-- away), and the claim undone if it went. `opts.leave` keeps stacks out of the move (a run's own
-- things, written off with the session car). After a claim, what pointed at the old car follows the
-- new one: 'claimed' is announced, and runtime points and the Director's run handles listen.

local STORAGES = { 'trunk', 'glovebox' }

--- Who is driving a car: the player's server id, or nil.
local function driverOf(entity)
    if not entity then return nil end
    local ped = GetPedInVehicleSeat(entity, -1)
    if not ped or ped == 0 then return nil end
    for _, s in ipairs(GetPlayers()) do
        local src = tonumber(s)
        if src and GetPlayerPed(src) == ped then return src end
    end
    return nil
end

local claimsUnderWay = {}   -- [vehicleId] = true while that car's claim runs

--- Is that car being claimed right now? Its record goes a moment before the owned one is out, so a
--- card watching the run's car waits rather than calling it lost.
---@param vehicleId number
function Vehicles.claimUnderWay(vehicleId) return claimsUnderWay[vehicleId] == true end

local function sameHash(a, b) return a and b and (a & 0xFFFFFFFF) == (b & 0xFFFFFFFF) end

--- The model a car is, as a name whip can spawn: found by its entity's hash in the vehicle catalog
--- (VehicleCatalog). A street car's record holds what its finder's game called it (a display name such as
--- 'washingt', a label, a hash as text), which may be no model at all; a
--- temporary car's is the name its maker gave.
local function modelOf(def, entity)
    local cat = VehicleCatalog.rows
    if entity and DoesEntityExist(entity) and type(cat) == 'table' then
        local hash = GetEntityModel(entity)
        for name in pairs(cat) do
            if sameHash(GetHashKey(name), hash) then return name end
        end
    end
    if def.temp and type(def.model) == 'string' and def.model ~= '' then return def.model end
    return nil
end

--- The slots of one compartment that hold something, in order (those `leave` keeps out).
local function filled(vehicleId, storageType, leave)
    local out = {}
    local slots = Vehicles.invCache[vehicleId] and Vehicles.invCache[vehicleId][storageType] or {}
    for slot, d in pairs(slots) do
        if type(d) == 'table' and d.item and not (leave and leave(d.metadata, d.item)) then out[#out + 1] = slot end
    end
    table.sort(out)
    return out
end

--- Move everything in one car's compartments into another's (but what `leave` says to leave).
--- Answers true, or false and why.
local function moveContents(fromId, toId, reason, leave)
    for _, st in ipairs(STORAGES) do
        for _, slot in ipairs(filled(fromId, st, leave)) do
            local ok, err = Stores.moveByAddress({ kind = 'vehicle', id = fromId, sub = st, slot = slot },
                                                 { kind = 'vehicle', id = toId, sub = st }, { reason = reason })
            if not ok then return false, ('the %s would not take what was in it (%s)'):format(st, tostring(err)) end
        end
    end
    return true
end

--- Make a car nobody owns someone's. Answers the new vehicleId (and a note when it was left in a garage),
--- or false and why.
---@param vehicleId number  a session car (temporary or adopted)
---@param who number|table  a server id or { charId }
---@param opts table|nil    { plate?, here? (default true: where it stands), garage?, key? (default true), reason?,
---                           leave? = fn(metadata, item) -> true for a stack to leave behind (written off with
---                           the session car: a run's own things, Director Claim Car) }
---@return number|false vehicleId
---@return string|nil why  (or, with a vehicleId, a note)
function Vehicles.claim(vehicleId, who, opts)
    opts = type(opts) == 'table' and opts or {}
    local charId, src = WhoIs(who)
    if not charId then return false, src --[[@as string]] end
    ---@cast src number|nil   -- with a charId, WhoIs's second answer is their source
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'No such car' end
    if not def.session then return false, 'That car is someone\'s already' end
    if def.releasing then return false, 'That car is going' end
    if def.claiming then return false, 'That car is being claimed already' end
    local plate, plateWhy = Vehicles.normalisePlate(opts.plate)
    if plateWhy then return false, plateWhy end
    if plate and Vehicles.getByPlate(plate) and plate ~= def.plate then return false, 'That plate is already taken' end
    local reason = type(opts.reason) == 'string' and opts.reason:sub(1, 120) or 'claimed'
    local leave = type(opts.leave) == 'function' and opts.leave or nil
    local model = modelOf(def, Vehicles.getEntity(vehicleId))
    if not model then return false, 'That car is not one whip knows the model of (the vehicle catalog), so it cannot be kept' end

    def.claiming = true
    claimsUnderWay[vehicleId] = true
    local function done(...)
        def.claiming = nil
        claimsUnderWay[vehicleId] = nil
        return ...
    end
    -- The car can go while this waits (the database, a key taken back): the run ends, it is put away,
    -- its resource stops. Asked again after every wait, and the claim undone if so.
    local function stillThere() return Vehicles.getDef(vehicleId) == def and not def.releasing end
    local newDefId   -- the owned car, once made
    local function undoNew(why)
        local gone, goneWhy = Vehicles.delete(newDefId)
        if not gone then
            print(('^1[whip_core:vehicle] claim #%d: the new car #%d could not be taken away again (%s): it stays its owner\'s^0')
                :format(vehicleId, newDefId, tostring(goneWhy)))
        end
        return done(false, why)
    end
    -- Every saved stat it carries (its fuel, its damage, a resource's own), as the owned car's to start with
    local stats = VehicleStats.getSaved(vehicleId)

    -- 1. The owned car. (The session car's plate is in use until it goes: an asked-for plate equal
    -- to it is put on after, below.)
    local wantPlate = plate
    if plate and plate == def.plate then plate = nil end
    local newDef, createWhy = Vehicles.create({
        ownerCharId = charId, model = model, plate = plate, state = 'garaged', garage = opts.garage,
        properties = def.properties, vehType = def.vehType, vehStats = stats,
        -- Written but its id read back too late (Vehicles.create): this claim has already failed, and the caller undone
        -- it, so the car it made goes again rather than stand as a second owned copy (audit 20, VEH-5)
        onLate = function(late)
            if not Vehicles.delete(late.vehicleId) then
                print(('^1[whip_core:vehicle] CRITICAL claim #%d: the car it made late (#%d) could not be removed^0')
                    :format(vehicleId, late.vehicleId))
            end
        end,
    })
    if not newDef then return done(false, createWhy or 'The car could not be registered') end
    local newId = newDef.vehicleId
    newDefId = newId
    if not stillThere() then return undoNew('That car went while it was being claimed') end

    -- 2. What is in it (but what `leave` leaves).
    if not Vehicles.loadInventory(newId) or not Vehicles.loadInventory(vehicleId) then
        return undoNew('What is in the car could not be read')
    end
    if not stillThere() then return undoNew('That car went while it was being claimed') end
    local moved, moveWhy = moveContents(vehicleId, newId, reason, leave)
    if not moved then
        -- Back as it was: everything that went across comes back, and the new car goes. What will not
        -- come back stays in the new car, which then stays (its owner's), rather than be lost with it.
        local back, backWhy = moveContents(newId, vehicleId, reason .. ' (undone)')
        if not back then
            print(('^1[whip_core:vehicle] CRITICAL claim #%d: what went into the new car #%d could not come back (%s): the new car keeps it, and stays^0')
                :format(vehicleId, newId, tostring(backWhy)))
            return done(false, ('%s; some of what was in it is in car #%d now'):format(tostring(moveWhy), newId))
        end
        return undoNew(moveWhy)
    end

    -- 3. The session car goes; the owned one stands where it stands NOW (it may have been driven
    -- while this waited), and only the entity that is this car is removed.
    local entity = Vehicles.getEntity(vehicleId)
    local here = opts.here ~= false and entity ~= nil
    local at
    if here then
        ---@cast entity -nil   -- `here` only with one
        local c = GetEntityCoords(entity)
        at = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(entity) }
    end
    local modelHash = entity and GetEntityModel(entity)
    local driver = driverOf(entity)
    local oldPlate = def.plate
    Vehicles.cleanupSessionVehicle(vehicleId, 'claimed')
    -- A street car is handed back to GTA by its release, not removed: it is replaced here. The handle
    -- read before the release waited, deleted only if it is still that car.
    if entity and DoesEntityExist(entity) and sameHash(GetEntityModel(entity), modelHash) then DeleteEntity(entity) end
    if wantPlate and not plate then
        -- The old car's plate, asked for: free now.
        local okP = Vehicles.setPlate(newId, wantPlate)
        if not okP then print(('[whip_core:vehicle] claim #%d: could not put plate %s on it'):format(newId, wantPlate)) end
    end
    local note
    if here then
        local newEntity, spawnWhy = Vehicles.spawn(newId, at.x, at.y, at.z, at.heading)
        if newEntity then
            if driver then SetPedIntoVehicle(GetPlayerPed(driver), newEntity, -1) end
        else
            note = 'it is waiting in its garage (' .. tostring(spawnWhy) .. ')'
        end
    end

    -- 4. The key and the record.
    if opts.key ~= false and src and Players[src] then
        local okK, keyWhy = Vehicles.giveKey(src, Players[src], newId)
        if not okK then note = (note and (note .. '; ') or '') .. 'no key: ' .. tostring(keyWhy) end
    end
    local claimed = Vehicles.getDef(newId)
    Log.write(charId, 'vehicle_claimed', {
        detail = ('#%d %s %s, from %s %s · %s'):format(newId, tostring(newDef.model), tostring(claimed and claimed.plate),
            def.temp and 'temporary car' or 'street car', tostring(oldPlate), reason),
    })
    -- Told first (what pointed at the old car moves to the new one: runtime points, a run's handle),
    -- and only then is the claim over.
    Vehicles.announce('claimed', { vehicleId = newId, from = vehicleId, ownerCharId = charId })
    return done(newId, note)
end

--- Change a car's plate (owned: saved; a session car's: until it goes). Answers true, or false and why.
---@param vehicleId number
---@param plate string  up to 8 characters
function Vehicles.setPlate(vehicleId, plate)
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'No such car' end
    local p, why = Vehicles.normalisePlate(plate)
    if why then return false, why end
    if not p then return false, 'A plate is 1 to 8 characters' end
    if p == def.plate then return true end
    if Vehicles.getByPlate(p) then return false, 'That plate is already taken' end
    local was = def.plate
    if def.session then
        -- A session car's keys are told by their plate (Vehicles.keyFits): the ones cut before
        -- carry this one, and must still fit.
        if was then
            def.keyPlates = def.keyPlates or {}
            def.keyPlates[(tostring(was):upper():gsub('%s+', ''))] = true
        end
        def.plate = p
    else
        local ok, err = Vehicles.persist(vehicleId, { plate = p })
        if not ok then return false, err or DB_ERROR end
    end
    local entity = Vehicles.getEntity(vehicleId)
    if entity then SetVehicleNumberPlateText(entity, Vehicles.displayPlate(p)) end
    -- Owned only: a street or temporary car's ownerCharId is 0, which is truthy, and its rows went under character 0
    -- (audit 20, VEH-11)
    if not def.session and def.ownerCharId and def.ownerCharId > 0 then
        Log.write(def.ownerCharId, 'vehicle_plate', { detail = ('#%d %s → %s'):format(vehicleId, tostring(was), p) })
        -- The owner's game lists its cars by plate (vehiclesSync, as vehicles.lua resends it on a
        -- create or a transfer): the new plate, now, not at their next login.
        local owner = PlayersByCharId and PlayersByCharId[def.ownerCharId]
        if owner then TriggerClientEvent('whip_core:client:vehiclesSync', owner.source, Vehicles.wireForOwner(def.ownerCharId)) end
    end
    Vehicles.announce('plateChanged', { vehicleId = vehicleId, from = was, to = p })
    return true
end

-- ============================================
-- Exports
-- ============================================

--- Make a car nobody owns someone's: ClaimVehicle(vehicleRef, who, { plate, here, garage, key, reason })
--- -> vehicleId (the new one) [, note] | false, why.
exports('ClaimVehicle', function(vehicle, who, opts)
    local id, err = Vehicles.idFromRef(vehicle)
    if not id then return false, err end
    return Vehicles.claim(id, who, opts)
end)

--- Change a car's plate: SetVehiclePlate(vehicleRef, plate) -> true | false, why.
exports('SetVehiclePlate', function(vehicle, plate)
    local id, err = Vehicles.idFromRef(vehicle)
    if not id then return false, err end
    return Vehicles.setPlate(id, plate)
end)
