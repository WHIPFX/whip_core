-- ============================================
-- Vehicle & Garage Events (client → server)
-- The garage bays, seats, session cars, keys, storage and locks. The vehicle EXPORTS live in
-- server/vehicles.lua; ground items in server/events_inventory.lua and server/ground.lua.
-- ============================================

-- IsPlayerNearVehicle is a GLOBAL defined further down (stores.lua's keep-range check reads it too);
-- the handlers above it only call it at runtime.

-- ============================================
-- Garage — Request Vehicles, Retrieve, Store
-- ============================================

--- One row of a garage list, as the UI reads it. The one builder for every list payload.
---@param v table      cache def
---@param catalog table VehicleCatalog.rows
---@return table
local function garageRow(v, catalog)
    local cat = v.model and catalog[tostring(v.model):lower()] or nil
    return {
        vehicleId   = v.vehicleId,
        model       = v.model,
        plate       = v.plate,
        state       = v.state,
        garage      = v.garage,
        -- Every stat the car actually carries. See the note in VehicleStats.getStored
        -- for why this is the stored block rather than the filled-in one.
        vehStats    = VehicleStats.getStored(v.vehicleId),
        displayName = cat and cat.displayName or nil,
        class       = cat and cat.class or nil,
    }
end

-- ============================================
-- The bay flow — a list you scroll in the world
-- ============================================
--
-- The only way in and out of a garage: the bay you stand in is the interface.

--- A car marked 'out' that has no entity in the world any more: something outside whip removed it
--- (a cleanup script, txAdmin's vehicle wipe, the owner's client). Unrecovered, it is in no bay list
--- and can be neither stored nor retrieved.
---@param v table  vehicle def
---@return boolean
local function isLost(v)
    return v.state == 'out' and not v.session and not Vehicles.getEntity(v.vehicleId)
end

--- May this lost car be recovered at this garage? Its own garage, or any garage when it has none.
local function lostHere(v, garageKey)
    return isLost(v) and (v.garage == nil or v.garage == garageKey)
end

--- A garaged car with no garage (the admin tool's "— none —") is offered at every garage, as
--- Vehicles.retrieve and lostHere do.
local function garagedHere(v, garageKey)
    return v.state == 'garaged' and (v.garage == nil or v.garage == garageKey)
end

--- Just the cars parked in this garage (and lost ones it may recover). displayName and class come
--- from the vehicle catalog; absent for a model it does not have (the client shows the model name).
---@return table[]
local function garagedRowsFor(charId, garageKey)
    local catalog = VehicleCatalog.rows
    local rows = {}
    for _, v in ipairs(Vehicles.getByOwner(charId)) do
        if garagedHere(v, garageKey) or lostHere(v, garageKey) then
            rows[#rows + 1] = garageRow(v, catalog)
        end
    end
    return rows
end

-- A bay event that ends badly answers `false, why` (shown and recorded). A bay has nothing on the
-- client to release: it folds back up the moment E is pressed.

--- Where a SPOT is, for the `near` gate: the bay, not the garage's own position (a car park's far
--- corner can be a hundred metres from it). An unknown spot answers nil, and the schemas below say
--- `allowUnknown` so their handlers can answer "Unknown parking spot" rather than "too far".
---@return number|nil, number|nil, number|nil
local function spotPosition(_, _, spotId)
    local s = GarageSpots.get(spotId)
    if not s then return nil end
    return s.x, s.y, s.z
end

--- May this player use this bay's garage? A PRIVATE one (a property's: see "Private garages" in
--- server/garages.lua) is for the people its owner says. Asked in all three bay events below — the
--- prompts are hidden from everybody else, but a hidden prompt is a courtesy and this is the rule.
---@return boolean ok
---@return string|nil why
local function mayUseGarage(_, player, garageKey)
    if Garages.canUse(garageKey, player and player.charId) then return true end
    return false, 'That garage is private'
end

SecureEvent('whip_core:server:garageSpotList', {
    rateLimit = 500,
    params = { {'spotId', 'id'} },
    near = { range = 8.0, at = spotPosition, message = 'You are too far from the parking spot', allowUnknown = true },
}, function(source, player, spotId)
    local spot = GarageSpots.get(spotId)
    if not spot then return false, 'Unknown parking spot' end
    if not Garages.get(spot.garageKey) then return false, 'Unknown garage' end
    local may, mayWhy = mayUseGarage(source, player, spot.garageKey)
    if not may then return false, mayWhy end

    TriggerClientEvent('whip_core:client:garageSpotList', source,
        spotId, spot.garageKey, garagedRowsFor(player.charId, spot.garageKey))
end)

--- What is standing in a bay, if anything — a vehicle, or a player other than the one asking. A car
--- brought out into an occupied bay spawns inside it, and GTA throws one of them. The rule is
--- Vehicles.spotBlocked, shared with SpawnVehicle and CreateOwnedVehicle{spawnAt}.
---@return string|nil why
local function bayBlocked(spot, source)
    -- By the bay's outline (its heading), not a radius: the car parked in the bay beside it is not in it.
    return Vehicles.spotBlocked(spot.x, spot.y, spot.z, { exceptSource = source, heading = spot.heading or 0.0 })
end

SecureEvent('whip_core:server:garageSpotRetrieve', {
    rateLimit = 2000,
    params = {
        {'spotId', 'id'},
        -- Resolved AND ownership-checked by the framework, exactly as the panel's retrieve is, so
        -- this cannot be reached with somebody else's car.
        {'vehicle', 'vehicle'},
    },
    near = { range = 8.0, at = spotPosition, message = 'You are too far from the parking spot', allowUnknown = true },
}, function(source, player, spotId, v)
    -- Not for a builder in Isolate world: it would come out in the shared world, unseen.
    local away = Vehicles.cannotBringOutFor(source)
    if away then return false, away end

    local spot = GarageSpots.get(spotId)
    if not spot then return false, 'Unknown parking spot' end

    local garageKey = spot.garageKey
    if not Garages.get(garageKey) then return false, 'Unknown garage' end
    local may, mayWhy = mayUseGarage(source, player, garageKey)
    if not may then return false, mayWhy end

    -- A lost car (see isLost) is filed back into this garage first, then comes out like any other.
    -- `v` is a snapshot, so the check is made against the live record and the snapshot refreshed.
    local live = Vehicles.getDef(v.vehicleId)
    if live and lostHere(live, garageKey) then
        local stored, storeErr = Vehicles.store(v.vehicleId, garageKey)
        if not stored then return false, storeErr or 'Could not recover that vehicle' end
        v = Vehicles.context(v.vehicleId) or v
    end

    -- The car has to be in this garage (the param resolver settled ownership, not which garage).
    if not garagedHere(v, garageKey) then return false, 'That vehicle is not in this garage' end

    local blocked = bayBlocked(spot, source)
    if blocked then return false, blocked end

    -- Backed into its bay, it comes out of this one backed in too. Read before the retrieve, and
    -- kept through a put-back below.
    local reversed = (Vehicles.getDef(v.vehicleId) or {}).parkedReversed == true

    local ok, err = Vehicles.retrieve(v.vehicleId, garageKey)
    if not ok then return false, err or 'Cannot retrieve vehicle' end

    -- Asked again: retrieve waited on the database, and a second player on the same bay could pass
    -- the check above meanwhile. Nothing yields between here and the spawn, so this answer holds.
    blocked = bayBlocked(spot, source)
    if blocked then
        Vehicles.store(v.vehicleId, garageKey, { reversed = reversed })
        return false, blocked
    end

    -- Into the bay that was asked, facing the way it was parked.
    local heading = ((spot.heading or 0.0) + (reversed and 180.0 or 0.0)) % 360.0
    local entity, netIdOrErr = Vehicles.spawn(v.vehicleId, spot.x, spot.y, spot.z, heading)

    if not entity then
        Vehicles.store(v.vehicleId, garageKey, { reversed = reversed })
        return false, netIdOrErr and tostring(netIdOrErr) or 'Could not bring the vehicle out'
    end

    TriggerClientEvent('whip_core:client:garageSpawnVehicle', source, {
        vehicleId  = v.vehicleId,
        netId      = netIdOrErr,
        properties = v.properties,
    })
    ShowSuccess(source,
        ('Retrieved %s (%s)'):format(v.model, v.plate))
    DevTools.refresh('gm')
end)

SecureEvent('whip_core:server:garageSpotStore', {
    rateLimit = 2000,
    params = {
        {'spotId', 'id'},
        {'vehicle', 'vehicle'},
    },
    near = { range = 8.0, at = spotPosition, message = 'You are too far from the parking spot', allowUnknown = true },
}, function(source, player, spotId, v)
    local spot = GarageSpots.get(spotId)
    if not spot then return false, 'Unknown parking spot' end
    if not Garages.get(spot.garageKey) then return false, 'Unknown garage' end
    local may, mayWhy = mayUseGarage(source, player, spot.garageKey)
    if not may then return false, mayWhy end

    -- The car has to be in this bay, and the server decides that (the client's offer is a hint).
    local entity = Vehicles.getEntity(v.vehicleId)
    if not entity then return false, 'That vehicle is not in the world right now' end

    -- Generous relative to the client's own test, so a car sitting exactly on the boundary cannot
    -- be offered an option the server then refuses.
    local range = (Config.GarageSpotRadius or 3.5) + 2.0
    if #(GetEntityCoords(entity) - vector3(spot.x, spot.y, spot.z)) > range then
        return false, 'That vehicle is not in this parking spot'
    end

    -- More than a right angle from the bay's own heading is backed in, and it comes out of a bay
    -- backed in (garageSpotRetrieve above).
    local diff = math.abs(((GetEntityHeading(entity) - (spot.heading or 0.0)) + 180.0) % 360.0 - 180.0)
    local ok, err = Vehicles.store(v.vehicleId, spot.garageKey, { reversed = diff > 90.0 })
    if not ok then return false, err or 'Cannot store vehicle' end

    -- To the owner (whose client holds the car's def) and whoever stored it — not every player.
    local to = { source }
    local owner = v.ownerCharId and PlayersByCharId and PlayersByCharId[v.ownerCharId]
    if owner and owner.source ~= source then to[#to + 1] = owner.source end
    SendToPlayers(to, 'whip_core:client:garageStoreConfirmed', v.vehicleId)
    ShowSuccess(source,
        ('Stored %s (%s)'):format(v.model, v.plate))
    DevTools.refresh('gm')
end)

-- ============================================
-- Vehicle Properties Sync
-- ============================================

--- A client saying it has applied the stored appearance to the entity. Paint and mods are client
--- natives, so a server-created car is stock until a client dresses it, and a report of its looks
--- before then describes the wrong thing.
---
--- No ownership check: any client that can see a car can dress it, and the claim grants nothing.
---
--- A list of ids, or one: a car park streaming in confirms every car in it at once.
local DRESSED_BATCH_MAX = 64

SecureEvent('whip_core:server:appearanceApplied', {
    whileDead = true,   -- not an action: cars in view get dressed whatever state you are in
    rateLimit = 1000,
    burst     = 5,
    params = {
        {'vehicleIds', 'any'},   -- a list of ids, or one id; checked one by one below
    },
}, function(source, _, vehicleIds)
    if type(vehicleIds) ~= 'table' then vehicleIds = { vehicleIds } end

    for i = 1, math.min(#vehicleIds, DRESSED_BATCH_MAX) do
        -- Each one an address: rejected when malformed, never clamped onto another car.
        local vehicleId = Sanitize.id(vehicleIds[i])

        -- Generous on purpose: the engine already bounds which cars a client can dress. Too tight
        -- drops a real confirmation, and that car's reports are refused for good.
        if vehicleId and IsPlayerNearVehicle(source, vehicleId, 500.0) then
            -- Recorded against the ENTITY, so a car garaged and brought back out does not inherit it.
            Vehicles.markDressed(vehicleId)
        end
    end
end)

--- A client REPORTING what a car looks like: an observation, to catch changes whip did not author
--- (another mod shop, a direct SetVehicleMod). It can be wrong or forged. An instruction goes through
--- SetVehicleAppearance instead, server-side, from trusted code. Position isn't reported: the server
--- reads its own vehicles (Vehicles.flushPositions).
SecureEvent('whip_core:server:syncVehicleProperties', {
    -- Sent on every getting-out (and a released appearance hold): a few back to back, then one
    -- every 5 s.
    rateLimit = 5000,
    burst     = 3,
    params = {
        {'vehicleId', 'id'},
        {'props', 'any'},
    },
}, function(source, player, vehicleId, props)
    if type(props) ~= 'table' then return end

    local def = Vehicles.getDef(vehicleId)
    if not def then return end

    -- The car has to be wearing what the record says before its looks can be reported. Only dirt
    -- is taken from a report (mergeClientProperties), but an undressed car's reading is still the
    -- wrong car's, and this gate stands in front of any field taken later.
    if not Vehicles.isDressed(vehicleId) then
        print(('[whip_core:vehicle] #%d: ignored a client report — the car is not yet wearing its '
            .. 'stored appearance, so what it looks like is not what it is.'):format(vehicleId))
        return
    end

    -- An owned car's report comes from its owner. A street car has none, so the proximity check
    -- below is what bounds it.
    if not def.session and def.ownerCharId ~= player.charId then return end

    -- You have to be able to see it. Deliberately not a DRIVER check: the report that matters most
    -- is the one fired as the player climbs out, and by then they are not in the seat.
    if not IsPlayerNearVehicle(source, vehicleId, 10.0) then return end

    local merged, held = Vehicles.mergeClientProperties(vehicleId, props)

    -- Say so when something is held back: a shop that applies mods on the client and lets this
    -- report pick them up would otherwise half-work with nothing explaining why.
    if held then
        print(('[whip_core:vehicle] #%d: ignored a client report of %s from %s. A car\'s look is set '
            .. 'with exports.whip_core:SetVehicleAppearance, not by reporting it — a report only '
            .. 'updates dirt.')
            :format(vehicleId, table.concat(held, ', '), GetPlayerName(source) or '?'))
    end

    -- Dirt is all a report can change, so one that barely moves it saves nothing (a save rewrites and
    -- re-sends the whole appearance). Measured against what is stored, so drift still adds up (0-15).
    local storedDirt = def.properties and tonumber(def.properties.dirtLevel)
    local newDirt    = tonumber(merged.dirtLevel)
    if newDirt == nil or (storedDirt and math.abs(newDirt - storedDirt) < 0.5) then return end

    Vehicles.saveProperties(vehicleId, merged)
end)

-- ============================================
-- Who is sitting where — vehicle:entered / vehicle:exited
-- ============================================
--
-- Both events carry `seat` (-1 is the driver) on both sides. On the server:
--   * one record per player of the seat they are in, so an event fires once per real change;
--   * `exited` fires only for a seat this record holds, so a client cannot announce leaving a car
--     it never got into, and a player who disconnects in a car is announced as leaving it.
--
-- Moving seats without getting out is announced as `entered` again with the new seat; there is no
-- `exited` in between.

--- [source] = { vehicleId, seat }
local _seated = {}

--- Announce that a player left the seat the record holds for them. No record, no event.
---@param source number
---@param left string|nil  'logout' or 'dropped' when they left the car by leaving the game; nil: they got out
local function announceExited(source, left)
    local was = _seated[source]
    if not was then return end
    _seated[source] = nil

    local def = Vehicles.getDef(was.vehicleId)
    -- Through Vehicles.announce: core's own 'exited' hooks first (the accessory key and the unlock,
    -- below), then whip_core:vehicle:exited for everyone.
    Vehicles.announce('exited', {
        vehicleId = was.vehicleId,
        plate     = def and def.plate or nil,
        source    = source,
        seat      = was.seat,
        left      = left,
    })
end

--- Announce that a player is in a seat, unless that is already what the record says.
---@param source number
---@param vehicleId number
---@param seat number  -1 is the driver
---@param plate string|nil
---@return boolean announced  false when nothing changed
local function announceEntered(source, vehicleId, seat, plate)
    local was = _seated[source]
    if was and was.vehicleId == vehicleId and was.seat == seat then return false end

    -- In a different car with no exit in between (a teleport, a warp): leave the old one first.
    if was and was.vehicleId ~= vehicleId then announceExited(source) end

    _seated[source] = { vehicleId = vehicleId, seat = seat }
    -- Through Vehicles.announce, core's hooks first (see announceExited). `previousSeat` is the seat
    -- they moved from inside this car, nil for getting in — so leaving the driver's seat by sliding
    -- across can be told apart (the accessory key goes back then too).
    Vehicles.announce('entered', {
        vehicleId    = vehicleId,
        plate        = plate,
        source       = source,
        seat         = seat,
        previousSeat = (was and was.vehicleId == vehicleId) and was.seat or nil,
    })

    -- The activity log, from the record: every real entry, any seat, once.
    local player = Players[source]
    if player then
        local def = Vehicles.getDef(vehicleId)
        Log.write(player.charId, 'vehicle_enter', {
            detail = ('%s %s · %s'):format(def and def.model or 'vehicle', plate or '?',
                seat == -1 and 'driver seat' or ('seat ' .. seat)),
        })
    end
    return true
end

--- Is this player's ped in this seat of this car, as the SERVER sees it? Asked a few times over a
--- second, because the seat a client reports replicates to the server a moment after the client
--- sees it. `want` is what the answer should become: true for getting in, false for getting out.
---@return boolean
local function seatSettles(source, vehicleId, seat, want)
    for _ = 1, 6 do
        local entity = Vehicles.getEntity(vehicleId)
        if not entity then return not want end          -- no car any more: nobody is in it
        local ped = GetPlayerPed(source)
        if not ped or ped == 0 then return not want end
        if (GetPedInVehicleSeat(entity, seat) == ped) == want then return true end
        Wait(200)
    end
    return false
end

--- A client saying it got into, or out of, a seat. The driver's seat is also announced by the
--- ignition check below; the record means whichever arrives second changes nothing.
SecureEvent('whip_core:server:vehicleSeat', {
    -- The dead are put into and taken out of seats too (pulled out, carried in, respawned out of one).
    -- Not an action: the handler checks the seat against the server's own view of the ped.
    whileDead = true,
    rateLimit = 250,
    burst     = 4,
    params = {
        {'vehicleId', 'id'},
        {'seat',      'int', -1, 15},
        {'entered',   'bool'},
    },
}, function(source, _, vehicleId, seat, entered)
    local def = Vehicles.getDef(vehicleId)

    if entered then
        if not def then return end
        if not seatSettles(source, vehicleId, seat, true) then
            RecordEventRejection('whip_core:server:vehicleSeat', source,
                'reported a seat the server does not see them in')
            return
        end
        announceEntered(source, vehicleId, seat, def.plate)
        return
    end

    -- Getting out: only of the seat on record, and only once the server agrees they are out of it.
    local was = _seated[source]
    if not was or was.vehicleId ~= vehicleId then return end
    if not seatSettles(source, vehicleId, was.seat, false) then
        RecordEventRejection('whip_core:server:vehicleSeat', source,
            'reported leaving a seat they are still in')
        return
    end
    announceExited(source)
end)

-- Ending the character is leaving the car: the record belongs to the character, and after a logout
-- the client's own exit report is refused (the session is closing). The logout hook runs on both
-- paths (a /logout and a drop with a character), just before `whip_core:player:logout`.
Character.onLife('logout', function(e)
    announceExited(e.source, 'logout')
end)

-- Leaving the server in a car is leaving the car — here only for a drop with no character (the
-- logout hook above covers every other, after the save has noted the seat: clearing it here first, while
-- player_lifecycle's drop handler waits on a write, lost the note). The record must not pass to whoever
-- gets this source next.
AddEventHandler('playerDropped', function()
    if Players[source] then return end
    announceExited(source, 'dropped')
end)

-- ---- Back in the car they left in (Config.ArrivalScenes) ----
--
-- A character who leaves sitting in a car (quits, crashes, logs out) comes back in it while it is still
-- near: client/arrival.lua seats them and plays the wake-up. The seat is noted on the character as they
-- leave, from WhipPlayer:save's teardown, which runs before the logout hook above clears the record.

local LAST_SEAT_KEY = 'lastSeat'

--- Note the seat this player is leaving in (metadata `lastSeat`), or clear it when they are on foot. Whether
--- the car was locked as they left goes with it (Vehicles.wakeSeatFor).
---@param player table
function Vehicles.noteLastSeat(player)
    -- Leaving from the driver's seat of a locked car with its key in the ignition: the key comes out with them first,
    -- or the car unlocks (Vehicles.keyOutAsTheyLeave, below). The note then says how the car really was left.
    if Vehicles.keyOutAsTheyLeave then Vehicles.keyOutAsTheyLeave(player) end
    local was = player.source and _seated[player.source]
    local def = was and Vehicles.getDef(was.vehicleId)
    local note = def and { vehicleId = was.vehicleId, seat = was.seat, plate = def.plate, model = def.model,
                           locked = Vehicles.isLocked(was.vehicleId) or nil } or nil
    local had = player.metadata and player.metadata[LAST_SEAT_KEY]
    if note == nil and had == nil then return end
    if note and type(had) == 'table' and had.vehicleId == note.vehicleId and had.seat == note.seat
        and had.plate == note.plate and had.locked == note.locked then return end
    player:setMetadata(LAST_SEAT_KEY, note)
end

--- The car this character left in, if it is still within Config.ArrivalScenes.vehicleRange of where
--- they left: { netId, seat } for the client, which takes that seat (and may find it taken). The
--- character's position moves to the car, so arriving there counts as being placed
--- (WhipPlayer:getCoords). nil: on foot, as before. Asked after the player is back in bucket 0.
---
--- A LOCKED CAR IS NOT GOT INTO (Josh, 30 Oct): one locked as they left it, or since (its owner came back
--- and locked it), is { netId, outside = true }: they wake on foot beside it (a side the client's ray from
--- the cabin reaches, never through a wall), as by a car of their own, never in a seat. A wake-up must not be a way into a locked car (and out of it, unlocking it).
---@param player table
---@return table|nil
function Vehicles.wakeSeatFor(player)
    local cfg = Config.ArrivalScenes
    local note = player.metadata and player.metadata[LAST_SEAT_KEY]
    if not cfg or cfg.enabled == false or type(note) ~= 'table' or player.isDead then return nil end

    -- The same car: a street car's id lasts one server run, and the next run gives it to another car.
    local vehicleId = tonumber(note.vehicleId)
    local def = vehicleId and Vehicles.getDef(vehicleId)
    if not vehicleId or not def or def.plate ~= note.plate or def.model ~= note.model then return nil end
    local entity = Vehicles.getEntity(vehicleId)
    if not entity or GetEntityRoutingBucket(entity) ~= GetPlayerRoutingBucket(player.source) then return nil end

    local c, p = GetEntityCoords(entity), player.position
    if #(vector3(c.x, c.y, c.z) - vector3(p.x, p.y, p.z)) > (tonumber(cfg.vehicleRange) or 400.0) then return nil end

    player.position = vector4(c.x, c.y, c.z, GetEntityHeading(entity))
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if note.locked or Vehicles.isLocked(vehicleId) then return { netId = netId, outside = true } end
    return { netId = netId, seat = tonumber(note.seat) or -1 }
end

--- On foot, with a car of theirs out within Config.ArrivalScenes.nearCarRange of where they stand: the
--- nearest, { netId }, for the scenes made with a car (nearCar: leaning on its bonnet). nil otherwise.
---@param player table
---@return table|nil
function Vehicles.nearCarFor(player)
    local cfg = Config.ArrivalScenes
    if not cfg or cfg.enabled == false or player.isDead or type(cfg.nearCar) ~= 'table' or #cfg.nearCar == 0 then
        return nil
    end
    local range, p = tonumber(cfg.nearCarRange) or 25.0, player.position
    local bucket = GetPlayerRoutingBucket(player.source)
    local best, bestD = nil, nil
    for _, def in ipairs(Vehicles.getByOwner(player.charId)) do
        local entity = Vehicles.getEntity(def.vehicleId)
        if entity and GetEntityRoutingBucket(entity) == bucket then
            local c = GetEntityCoords(entity)
            local d = #(vector3(c.x, c.y, c.z) - vector3(p.x, p.y, p.z))
            if d <= range and (not bestD or d < bestD) then best, bestD = entity, d end
        end
    end
    return best and { netId = NetworkGetNetworkIdFromEntity(best) } or nil
end

-- ============================================
-- Session Vehicle Registration (NPC/AI vehicles)
-- Client detects NPC vehicle on enter → server
-- registers in-memory session entry for full features
-- ============================================

--- Resolve a client-reported netId to an entity the reporter is actually standing at. Everything
--- the registration events below carry is a client's claim, and the plate can't be verified, so
--- presence is: the entity must exist, be a vehicle, and be next to the player reporting it.
---@param source number
---@param netId number
---@return number|nil entity  nil when the claim does not survive inspection
local function reportedVehicleEntity(source, netId)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end

    -- A netId addresses ANY entity — a ped, a prop, another player. Same check adopt makes,
    -- made early so a non-vehicle never gets as far as the registry.
    if GetEntityType(entity) ~= 2 then return nil end

    -- 20m: generous for "just climbed in / standing at the pump", far too short for a scan.
    -- IsPlayerNear, not a copy of it: the copy had no character-creator rule.
    local vc = GetEntityCoords(entity)
    if not IsPlayerNear(source, vc.x, vc.y, vc.z, 20.0) then return nil end

    return entity
end

--- How many street cars one player may hold under whip's tracking at once. An adopted car is pinned
--- (KeepEntity) until nobody has been within 300m for ten minutes, so uncapped, a modified client
--- could keep any number alive. Twenty is far more than anyone drives in ten minutes.
local SESSION_ADOPT_CAP = 20

--- Street cars this player brought into tracking that are still held.
---@param source number
---@return number
local function adoptedBy(source)
    local n = 0
    for _, def in pairs(Vehicles.getAll()) do
        if def.session and def.adoptedBy == source then n = n + 1 end
    end
    return n
end

--- Tell the players near a car that its lock changed — for the honk, the flash and the door state.
---
--- Near, not everyone: the players whose streamed cells hold the car. The lock itself is already
--- applied server-side (setLocked); a car with no entity tells nobody.
---@param vehicleId number
---@param locked boolean
local function announceLockNear(vehicleId, locked)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return end
    local c = GetEntityCoords(entity)
    for _, src in ipairs(PlayersNearPoint(c.x, c.y)) do
        TriggerClientEvent('whip_core:client:vehicleLockState', src, vehicleId, locked)
    end
end

-- ============================================
-- Getting in and out: the accessory key, and the unlock
-- ============================================
--
-- The accessory key. A key in any slot of the accessory strip goes into the ignition of the car it
-- fits when its holder takes the driver's seat, and back to them when they leave that seat (getting
-- out, or sliding across). Slots 3 to 5 are its Key slots (shared/inventory_shape.lua).
-- Only:
--   * a key that was in the strip FIRST (keys in the main pockets never move by themselves);
--   * the driver's seat;
--   * a key that fits this car (Vehicles.keyFits): with several in the strip, the first that fits;
--   * an empty ignition.
-- Only the key that went in this way comes back, matched by its uid: to the slot it came from, the
-- first empty strip slot if that is filled, then the pockets, or it stays in the car when all are
-- full. A Store needs everyone out, so the key is back before the car is garaged; a Despawn files it
-- with the driver in, key in the ignition.
--
-- The unlock. Any player getting out of any whip car unlocks it, as a real car won't lock with you
-- stepping out of it.
--
-- Core's own 'entered' / 'exited' hooks (Vehicles.onLife), fired by the seat record above; each moves
-- things in its own thread, so the announcement never waits on a database write.

--- [vehicleId] = { source, uid, slot } — the key the accessory put in, whose it is, and the strip slot it left.
local _autoKey = {}

--- The strip's slots in order, lowest first: none with the strip off (Config.AccessoryStrip), so keys
--- only go in by hand.
---@return number[]
local function stripSlots()
    local slots = {}
    for slot in pairs(Inventory.AccessorySlots) do slots[#slots + 1] = slot end
    table.sort(slots)
    return slots
end

--- Where a key coming out of an ignition goes in this player's strip: `from` (the slot it left) while that is
--- empty, else the first empty slot that takes it. nil when there is no room (the pockets are next).
---@param player table
---@param item string
---@param from number|nil
---@return number|nil
local function stripSlotForKey(player, item, from)
    local function free(slot)
        return Inventory.AccessorySlots[slot] ~= nil and Inventory.slotTakes('accessory', slot, item)
            and not Inventory.getSlot(player.inventory, 'accessory', slot)
    end
    if from and free(from) then return from end
    for _, slot in ipairs(stripSlots()) do
        if free(slot) then return slot end
    end
    return nil
end

--- The key in this player's strip, and its slot, that would go into this car's ignition: the first that
--- fits, with the ignition empty. nil otherwise.
---
--- Asked twice: by insertAccessoryKey, and by the ignition answer the driver gets on sitting down,
--- which goes out before the key has moved, so it says the key is COMING.
---@param vehicleId number
---@param src number
---@return number|nil keySlot, table|nil key
local function accessoryKeyFor(vehicleId, src)
    local player = Players[src]
    if not player or player.closing or not player.inventory then return nil end
    -- A bicycle has no ignition to put it in (Vehicles.isBicycle): the key stays in the strip.
    if Vehicles.isBicycle(vehicleId) then return nil end
    if Vehicles.getIgnitionSlot(vehicleId) then return nil end
    for _, slot in ipairs(stripSlots()) do
        local key = Inventory.getSlot(player.inventory, 'accessory', slot)
        if key and key.item == 'vehicle_key' and Vehicles.keyFits(key.metadata, vehicleId) then
            return slot, key
        end
    end
    return nil
end

--- The driver just sat down: the key in their strip goes into this car's empty ignition.
---@param vehicleId number
---@param src number
local function insertAccessoryKey(vehicleId, src)
    local keySlot, key = accessoryKeyFor(vehicleId, src)
    if not keySlot then return end
    local uid = Log.ensureUid(key)
    local ok = Stores.moveByAddress(
        { kind = 'player', id = src, sub = 'accessory', slot = keySlot },
        { kind = 'vehicle', id = vehicleId, sub = 'key', slot = 1 },
        { reason = 'into the ignition as they took the driver\'s seat', source = src })
    if ok then _autoKey[vehicleId] = { source = src, uid = uid, slot = keySlot } end
end

--- The driver left their seat: the key the accessory put in goes back to them.
---
--- Not to a player who is leaving: a logout's hooks run after its final save, and a drop has no
--- inventory. It stays in the car instead.
---@param vehicleId number
---@param src number
local function returnAccessoryKey(vehicleId, src)
    local auto = _autoKey[vehicleId]
    if not auto or auto.source ~= src then return end
    _autoKey[vehicleId] = nil
    local inIgnition = Vehicles.getIgnitionSlot(vehicleId)
    if not (inIgnition and inIgnition.metadata and inIgnition.metadata.uid == auto.uid) then return end
    local player = Players[src]
    if not player or player.closing or player.dropped or not player.inventory then return end

    local from = { kind = 'vehicle', id = vehicleId, sub = 'key', slot = 1 }
    local opts = { reason = 'out of the ignition as they left the driver\'s seat', source = src }
    local keySlot = stripSlotForKey(player, inIgnition.item, auto.slot)
    if keySlot then
        if Stores.moveByAddress(from, { kind = 'player', id = src, sub = 'accessory', slot = keySlot }, opts) then
            return
        end
    end
    -- The strip was filled meanwhile: the pockets, wherever it fits. Full, it stays in the car.
    Stores.moveByAddress(from, { kind = 'player', id = src, sub = 'player' }, opts)
end

--- Somebody got out: a locked car unlocks (GTA lets you open a locked car's door from inside), unless the server
--- turned that off (Config.UnlockOnExit = false: the car stays locked, as a car that locks itself). Leaving the game in
--- it (`left`: a logout, a drop) is not getting out: the car stays as they locked it (Josh, 1 Nov: logging out in a
--- locked car left it open for anyone).
---@param vehicleId number
---@param src number
---@param left string|nil  the exit's `left`
local function unlockOnExit(vehicleId, src, left)
    if left or Config.UnlockOnExit == false then return end
    if not Vehicles.getDef(vehicleId) or not Vehicles.isLocked(vehicleId) then return end
    if Vehicles.setLocked(vehicleId, false, src) then announceLockNear(vehicleId, false) end
end

--- LEAVING THE GAME IN THE DRIVER'S SEAT OF A LOCKED CAR (a logout, a quit, a crash): the key in its ignition comes
--- out with them, to the strip or the pockets, so they can open it again when they come back. With no room for it,
--- the key stays and the car unlocks instead: never locked with its only key inside (audit 20, VEH-1: the car stays
--- locked when you leave the game in it, Josh 1 Nov, and the key stayed in it, so its owner came back locked out).
--- From WhipPlayer:save's teardown (Vehicles.noteLastSeat), before the pockets are written, so the key is in that save.
---@param player table
function Vehicles.keyOutAsTheyLeave(player)
    local src = player and player.source
    local was = src and _seated[src]
    if not was or was.seat ~= -1 then return end
    local vehicleId = was.vehicleId
    if not Vehicles.getDef(vehicleId) or not Vehicles.isLocked(vehicleId) then return end
    local key = Vehicles.getIgnitionSlot(vehicleId)
    if not key or not Inventory.isIgnitionKey(key.item) or not Vehicles.keyFits(key.metadata, vehicleId) then return end

    local from = { kind = 'vehicle', id = vehicleId, sub = 'key', slot = 1 }
    local opts = { reason = 'out of the ignition as they left the game in the driver\'s seat', source = src }
    local moved = false
    if Vehicles.canTakeKey(player) and player.inventory then
        local auto = _autoKey[vehicleId]
        local keySlot = stripSlotForKey(player, key.item, auto and auto.source == src and auto.slot or nil)
        if keySlot then
            moved = Stores.moveByAddress(from, { kind = 'player', id = src, sub = 'accessory', slot = keySlot }, opts) == true
        end
        if not moved then
            moved = Stores.moveByAddress(from, { kind = 'player', id = src, sub = 'player' }, opts) == true
        end
    end
    if moved then
        if _autoKey[vehicleId] and _autoKey[vehicleId].source == src then _autoKey[vehicleId] = nil end
        return
    end
    -- No room for it: the car is not left locked with its only key inside
    if Vehicles.setLocked(vehicleId, false, src) then announceLockNear(vehicleId, false) end
    print(('[whip_core:vehicle] charId %s left the game in locked car %s with no room for its key: left unlocked, key inside')
        :format(tostring(player.charId), tostring(vehicleId)))
end

Vehicles.onLife('entered', function(e)
    -- Sliding out of the driver's seat is leaving it: the key goes back.
    if e.previousSeat == -1 and e.seat ~= -1 then
        CreateThread(function() returnAccessoryKey(e.vehicleId, e.source) end)
    end
    if e.seat == -1 then
        CreateThread(function() insertAccessoryKey(e.vehicleId, e.source) end)
    end
end)

Vehicles.onLife('exited', function(e)
    CreateThread(function()
        if e.seat == -1 then returnAccessoryKey(e.vehicleId, e.source) end
        unlockOnExit(e.vehicleId, e.source, e.left)
    end)
end)

-- A car that is gone takes its record of the accessory key with it.
for _, kind in ipairs({ 'deleted', 'released' }) do
    Vehicles.onLife(kind, function(e)
        if type(e) == 'table' and e.vehicleId then _autoKey[e.vehicleId] = nil end
    end)
end

--- May this player bring one more street car into tracking? Asked by every path that adopts one:
--- the two events below, and the fuel pump.
---@param source number
---@return boolean
function Vehicles.mayAdoptStreetCar(source)
    return adoptedBy(source) < SESSION_ADOPT_CAP
end

--- Count a street car this player just brought into tracking against their cap.
---@param vehicleId number
---@param source number
function Vehicles.noteStreetCarAdopted(vehicleId, source)
    local def = Vehicles.getDef(vehicleId)
    if def and def.session then def.adoptedBy = source end
end

-- A source is reused by the next player to connect; the count must not follow the number.
AddEventHandler('playerDropped', function()
    local src = source
    for _, def in pairs(Vehicles.getAll()) do
        if def.session and def.adoptedBy == src then def.adoptedBy = nil end
    end
end)

--- A street car taken with its engine running comes with its key in the ignition. Asked again once the server sees the
--- driver in the seat (seatSettles): the first read can be a sync behind the report (Josh tests at ~217 ms), and then
--- the car never got a key, every later entry going by the known-car branch (audit 20, VEH-3). Once per car (keyMinted,
--- Vehicles.registerSessionVehicle's existing-plate branch makes it), and only for the report that made the record: a
--- known car's later entries do not ask, or a hotwired car left running would hand out its key. Tells the driver the
--- ignition's new state.
---@param source number
---@param vehicleId number
---@param netId number
local function keyIfTakenRunning(source, vehicleId, netId)
    local def = Vehicles.getDef(vehicleId)
    if not def or not def.session or def.keyMinted or Vehicles.hasKeyInIgnition(vehicleId) then return end
    local entity = Vehicles.getEntity(vehicleId)
    local ped = GetPlayerPed(source)
    if not entity or ped == 0 or GetPedInVehicleSeat(entity, -1) ~= ped or not GetIsVehicleEngineRunning(entity) then return end
    local player = Players[source]
    Vehicles.registerSessionVehicle(def.plate, def.model, netId, def.vehType, true, player and player.charId, source)
    if Vehicles.hasKeyInIgnition(vehicleId) then
        TriggerClientEvent('whip_core:client:ignitionState', source, vehicleId,
            Vehicles.ignitionReady(vehicleId), Vehicles.hasUnhackedKeyInIgnition(vehicleId))
    end
end

SecureEvent('whip_core:server:registerSessionVehicle', {
    rateLimit = 1000,
    params = {
        {'plate', 'string', 10},
        {'model', 'string', 60},
        {'netId', 'id'},
        {'vehType', 'string', 30, 'automobile'},
        {'engineOn', 'bool'},
    },
}, function(source, player, plate, model, netId, vehType, engineOn)
    -- The reporter must be AT the car they are reporting. Without this, any client could feed
    -- the registry plates and netIds from anywhere on the map — see reportedVehicleEntity.
    local entity = reportedVehicleEntity(source, netId)
    if not entity then
        RecordEventRejection('whip_core:server:registerSessionVehicle', source,
            'reported vehicle is not a vehicle near the reporter')
        return
    end

    -- A car whip already knows is answered by its id, not its plate: the client offers a car as a
    -- stranger whenever its id hasn't reached it yet. The entity's own stamp (confirmed by the index)
    -- is asked first, and answered the way checkIgnition answers it.
    local knownId = Vehicles.getEntityVehicleId(entity)
    local knownDef = knownId and Vehicles.getDef(knownId)
    if knownId and knownDef then
        -- The netId rides along so the client can tell a reply about THIS car from a late one about
        -- the car it sat in before.
        TriggerClientEvent('whip_core:client:sessionVehicleRegistered', source, knownId, netId)
        CreateThread(function()
            if seatSettles(source, knownId, -1, true) then announceEntered(source, knownId, -1, knownDef.plate) end
        end)
        -- The last value: the strip's key is about to go in (accessoryKeyFor), so the client holds
        -- an engine press until it lands rather than saying there is no key. (A bicycle needs none:
        -- Vehicles.ignitionReady.)
        local hasKey = Vehicles.ignitionReady(knownId)
        TriggerClientEvent('whip_core:client:ignitionState', source, knownId,
            hasKey, Vehicles.hasUnhackedKeyInIgnition(knownId), not hasKey and accessoryKeyFor(knownId, source) ~= nil)
        return
    end

    -- The car is asked, not the client: `engineOn` decides whether a street car comes with a key in
    -- its ignition, so only the person in the driver's seat of a running car gets one. (Its engine
    -- state is synced by the driver's own client, so this stops "anyone within 20m says true", not a
    -- cheater already driving it.)
    --
    -- The plate is read off the entity too, not the one the client typed: the registry is keyed by it.
    local ped = GetPlayerPed(source)
    local driving = ped ~= 0 and GetPedInVehicleSeat(entity, -1) == ped
    engineOn = (driving and GetIsVehicleEngineRunning(entity)) and true or false
    local entPlate = GetVehicleNumberPlateText(entity)
    if entPlate and entPlate ~= '' then plate = entPlate end

    -- An OWNED car's plate reaches its real vehicle id. That id is only handed to whoever is driving
    -- the entity whip actually tracks for it — a car that merely carries the same plate text is not it.
    local ownedId = Vehicles.getByPlate(plate)
    local ownedDef = ownedId and Vehicles.getDef(ownedId)
    if ownedId and ownedDef and not ownedDef.session and not Vehicles.isPlayerDriving(source, ownedId) then
        RecordEventRejection('whip_core:server:registerSessionVehicle', source,
            'plate belongs to an owned vehicle the reporter is not driving')
        return
    end

    -- A live record, not any record: a street car whose car has gone is replaced by a new record,
    -- which must count against the cap.
    if not Vehicles.getLiveByPlate(plate) and adoptedBy(source) >= SESSION_ADOPT_CAP then
        RecordEventRejection('whip_core:server:registerSessionVehicle', source,
            ('already holding %d street cars'):format(SESSION_ADOPT_CAP))
        return
    end
    -- The character goes with it, so a key found in the ignition is logged against whoever found it.
    local vehicleId, created = Vehicles.registerSessionVehicle(plate, model, netId, vehType, engineOn, player.charId, source)
    if not vehicleId then return end

    -- Counted when this call made the record (its own answer, not a guess from before it).
    if created then
        local def = Vehicles.getDef(vehicleId)
        if def and def.session then def.adoptedBy = source end
    end

    -- Only the driver registers a street car. Announced once the server sees them in that seat —
    -- see the ignition check below for why this waits, and why in its own thread.
    CreateThread(function()
        if seatSettles(source, vehicleId, -1, true) then
            announceEntered(source, vehicleId, -1, plate)
            if created then keyIfTakenRunning(source, vehicleId, netId) end
        end
    end)

    local hasKey = Vehicles.ignitionReady(vehicleId)   -- a street bicycle needs no key either
    local hasUnhacked = Vehicles.hasUnhackedKeyInIgnition(vehicleId)
    TriggerClientEvent('whip_core:client:sessionVehicleRegistered', source, vehicleId, netId)
    TriggerClientEvent('whip_core:client:ignitionState', source, vehicleId, hasKey, hasUnhacked)
end)

-- ============================================
-- Resolve Vehicle — Client API Callback
-- exports.whip_core:ResolveVehicle(entity) uses this
-- to ensure a session vehicle is registered and get its vehicleId.
-- ============================================

SecureCallback('whip_core:resolveVehicle', {
    rateLimit = 500,
    params = {
        {'plate', 'string', 10},
        {'model', 'string', 60},
        {'netId', 'id'},
        {'vehType', 'string', 30, 'automobile'},
    },
}, function(source, _, plate, model, netId, vehType)
    -- Gate first, from the car itself: the caller must be standing at the car, and the plate is the
    -- one the car carries. Each refusal answers `false, why`.
    local entity = reportedVehicleEntity(source, netId)
    if not entity then
        RecordEventRejection('whip_core:resolveVehicle', source,
            'claimed vehicle is not a vehicle near the caller')
        return false, 'That vehicle is not near you'
    end

    -- Already whip's: the stamp is the answer (it is replicated to every client anyway).
    local stamped = Vehicles.getEntityVehicleId(entity)
    if stamped then return stamped end

    local entPlate = GetVehicleNumberPlateText(entity)
    if entPlate and entPlate ~= '' then plate = entPlate end

    -- An owned car whip is not tracking on THIS entity is not this caller's to resolve by plate.
    local existingId = Vehicles.getByPlate(plate)
    local existingDef = existingId and Vehicles.getDef(existingId)
    if existingDef and not existingDef.session then
        RecordEventRejection('whip_core:resolveVehicle', source, 'plate belongs to an owned vehicle on another entity')
        return false, 'That plate belongs to an owned vehicle'
    end

    -- The same per-player cap as registerSessionVehicle, for a car whip is not tracking yet — a LIVE
    -- record, and counted by what the call says it made (see the event above).
    if not Vehicles.getLiveByPlate(plate) and adoptedBy(source) >= SESSION_ADOPT_CAP then
        RecordEventRejection('whip_core:resolveVehicle', source, ('already holding %d street cars'):format(SESSION_ADOPT_CAP))
        return false, ('You already hold %d street cars'):format(SESSION_ADOPT_CAP)
    end

    local vehicleId, created = Vehicles.registerSessionVehicle(plate, model, netId, vehType, false)
    local def = vehicleId and created and Vehicles.getDef(vehicleId)
    if def and def.session then def.adoptedBy = source end
    if not vehicleId then return false, 'That vehicle could not be registered' end
    return vehicleId
end)

-- ============================================
-- NPC Vehicle Lock Enforcement
-- ============================================
--
-- All non-framework vehicles stay locked; players lockpick them. The rule lives in
-- client/vehicles.lua: ambient traffic is created by clients, which already know the cars around
-- them (a server-side entityCreated subscription costs dispatch on every car the world spawns).
--
-- The server keeps the part that needs authority: `attemptLockpick` validates the item and the
-- distance and runs and judges the skill check itself (Skill.run), and whip storage refuses anyone
-- without a key. A door lock was never a security boundary: whichever client owns the entity
-- applies it.

-- ============================================
-- Player Position Save (event-driven, e.g. vehicle enter/exit)
-- ============================================

--- A client saying "I have just got in or out of a car, remember where I am". Marked through the
--- one writer (PlayerRows), so it goes out in the next batch: the sweep runs every 30 seconds and a
--- disconnect flushes unconditionally.
SecureEvent('whip_core:server:saveMyPosition', {
    whileDead = true,   -- only marks where you are for the next save
    -- The client sends no faster than this (client/vehicles.lua saveMyPosition: one inside the gap waits for it).
    rateLimit = 5000,
}, function(source)
    PlayerRows.markPosition(source)
end)

-- ============================================
-- Vehicle Proximity Helper
-- ============================================

--- Check if a player is within range of a vehicle entity. A car with no entity is near nobody.
---
--- A global: stores.lua re-checks it on every trunk and glovebox move (the keep range).
---@param source number  Player server ID
---@param vehicleId number  Vehicle ID
---@param maxDist number  Maximum distance in metres
---@return boolean
function IsPlayerNearVehicle(source, vehicleId, maxDist)
    -- Nobody in the character creator is near anything (as IsPlayerNear, server/helpers.lua).
    local player = Players and Players[source]
    if player and player._inCreator then return false end

    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local playerCoords = GetEntityCoords(ped)

    -- First: sitting in this very vehicle is near it. Asked before distance, which is measured from
    -- the car's origin (a coach driver sits further from it than a boot's keep range).
    local pedVeh = GetVehiclePedIsIn(ped, false)
    if pedVeh and pedVeh ~= 0 and Vehicles.getEntityVehicleId(pedVeh) == vehicleId then
        return true
    end

    -- Then: distance to the tracked entity (getEntity, so a reused handle is not measured).
    local entity = Vehicles.getEntity(vehicleId)
    if entity then
        local vehCoords = GetEntityCoords(entity)
        return #(playerCoords - vehCoords) <= maxDist
    end

    -- No car, no "near it": a car with no entity has despawned or been lost.
    return false
end

-- ============================================
-- Vehicle Lock/Unlock
-- ============================================

--- Open or shut one of a vehicle's doors, for everybody.
---
--- The server owns the door: SetVehicleDoorOpen is a LOCAL native and only the network owner's copy
--- counts (see VEHICLE_DOORS_KEY in shared/statebags.lua). The mask is written here, replicates, and
--- every client applies it to its own copy.
---
--- Addressed by net id, not vehicleId: the boot of a street car nobody has touched opens without
--- registering it. reportedVehicleEntity checks the entity exists, is a vehicle, and is beside the
--- player.
SecureEvent('whip_core:server:toggleVehicleDoor', {
    -- Doors are pressed in runs (walking round a car opening all four), so the burst matters more
    -- than the window.
    rateLimit = 250,
    burst     = 4,
    params = {
        {'netId', 'id'},
        -- 0-3 the passenger doors, 4 the bonnet, 5 the boot, 6/7 rear doors on the models that
        -- have them. Rejected rather than clamped: a clamp would move a door nobody named.
        {'doorIndex', 'id', 0, 7},
        -- Intent, not just toggle: the boot also moves when the storage panel opens and closes, and
        -- "shut" is idempotent where a toggle would race.
        {'want', 'enum', {'toggle', 'open', 'shut'}, 'toggle'},
    },
}, function(source, _, netId, doorIndex, want)
    local entity = reportedVehicleEntity(source, netId)
    if not entity then return end

    -- Tighter than reportedVehicleEntity's 20m: a door is an arm's-reach thing.
    local vc = GetEntityCoords(entity)
    if not IsPlayerNear(source, vc.x, vc.y, vc.z, 8.0) then
        RecordEventRejection('whip_core:server:toggleVehicleDoor', source,
            'too far from the vehicle to touch its doors')
        return
    end

    -- Read, flip one bit, write back (the whole state is one integer). The server's copy, not the
    -- bag: the car's network owner can write the bag.
    local mask = Vehicles.getDoorMask(entity) or 0

    local bit = 1 << doorIndex
    local isOpen = (mask & bit) ~= 0
    local wantOpen
    if want == 'open' then wantOpen = true
    elseif want == 'shut' then wantOpen = false
    else wantOpen = not isOpen end

    -- Nothing to say: a bag write replicates even unchanged, and the boot is told to shut every time
    -- a storage panel closes.
    if wantOpen == isOpen then return end

    -- A lock keeps doors from opening, not from closing (a boot left open when the owner locked up
    -- must still shut). Only for vehicles whip knows (a street car has no lock state);
    -- getEntityVehicleId, not the raw stamp, so a stale stamp can't lend this car another's lock.
    -- The prompts already hide the option; this holds against a hand-built event.
    if wantOpen then
        local vehicleId = Vehicles.getEntityVehicleId(entity)
        if vehicleId and Vehicles.isLocked(vehicleId) then
            RecordEventRejection('whip_core:server:toggleVehicleDoor', source,
                'the vehicle is locked')
            return
        end
    end

    mask = wantOpen and (mask | bit) or (mask & (~bit))

    -- Remembered here, then written to the bag (replicated) from that copy.
    Vehicles.setDoorMask(entity, mask)
end)

SecureEvent('whip_core:server:toggleVehicleLock', {
    rateLimit = 500,
    params = { {'vehicleId', 'id'} },
}, function(source, player, vehicleId)

    local def = Vehicles.getDef(vehicleId)
    if not def then return end

    -- Verify player has a key — inventory OR ignition (if in vehicle)
    local hasKeyInInventory = Vehicles.playerHasKey(player, vehicleId)

    -- Bound to THIS vehicle, not "is this ped sitting in something": the in-car branch skips the
    -- proximity check.
    local isInVehicle = Vehicles.isPlayerIn(source, vehicleId)

    if isInVehicle then
        -- Inside vehicle: key in ignition OR in inventory
        local keyInIgnition = Vehicles.hasKeyInIgnition(vehicleId)
        if not hasKeyInInventory and not keyInIgnition then
            return false, 'You don\'t have a key for this vehicle'   -- shown and recorded
        end
    else
        -- Outside vehicle: key must be in inventory + must be near vehicle
        if not hasKeyInInventory then
            return false, 'You don\'t have a key for this vehicle'
        end
        if not IsPlayerNearVehicle(source, vehicleId, Config.VehicleLockRange or 8.0) then
            return false, 'Too far from the vehicle'   -- said, like every other refusal here
        end
    end

    local newState = not Vehicles.isLocked(vehicleId)

    -- setLocked announces the change itself (whip_core:vehicle:lockChanged / :locked), so every
    -- way of locking a car is heard the same way. Checked: a failed save is not a lock.
    local ok, err = Vehicles.setLocked(vehicleId, newState, source)
    if not ok then
        return false, tostring(err or 'Could not change the lock')
    end

    -- The players near it hear it (for the honk, the flash and the door state) — see announceLockNear.
    announceLockNear(vehicleId, newState)

    local stateStr = newState and 'Locked' or 'Unlocked'
    ShowSuccess(source,
        ('%s — %s'):format(stateStr, def.plate))
end)

--- A client's NPC lock rule locked this car before learning it was a whip car (its id arrived late).
--- Put the server's lock state back. See NpcLockNearby in client/vehicles.lua.
---
--- No key or distance check: the answer is the server's own `locked`, so the worst a modified client
--- can do is make the server repeat it (rate limited).
---
--- Not for a street car: its lock is read from the world when adopted (bindEntity), so the server has
--- nothing of its own to put back.
SecureEvent('whip_core:server:reassertVehicleLock', {
    whileDead = true,   -- the game sends this, not the player, and the NPC rule runs while dead too
    rateLimit = 250,
    burst     = 3,   -- two cars spawned side by side can both be caught in one laggy moment
    params    = { {'vehicleId', 'id'} },
}, function(_, _, vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def or (def.session and not def.temp) then return end
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return end
    SetVehicleDoorsLocked(entity, Vehicles.isLocked(vehicleId) and 2 or 1)
end)

-- (whip_core:server:giveVehicleKey was here: a key cut for any owner who asked, with no page left that asked. Give the
-- key away and ask again, and it cut another, for ever. Keys come from a sale (CreateOwnedVehicle giveKey), the Vehicle
-- Manager's Give Key (admins) and GiveVehicleKey for a resource. Audit 20, VEH-10.)

-- ============================================
-- Vehicle Storage Events (Trunk + Glovebox)
-- ============================================

--- How far from a car its boot opens: Config.VehicleTrunkRange (how close to the back you stand)
--- plus the car's own length. The one read of the setting (config.lua ships 2.5).
---@return number metres
function Vehicles.trunkOpenRange()
    return (tonumber(Config.VehicleTrunkRange) or 2.5) + 3.0
end

--- Shed any OTHER vehicle's storage this player is still recorded in. A close that never arrives
--- (the client clears its side before sending it) would leave a membership that authorises writes
--- (Stores.fromWire) and pins the vehicle's cache open for the session. Opening a boot proves you
--- are somewhere else. This car's trunk and glovebox at once is legitimate and left alone. Logged:
--- a heal here means a close went missing.
---
--- Shared by the player's open (below) and Vehicles.openTrunkFor (OpenStore).
---@param source number
---@param vehicleId number  the vehicle being opened now
local function shedStaleStorage(source, vehicleId)
    local stale = {}
    for _, storeId in ipairs(Stores.viewedBy(source)) do
        local otherId = storeId:match('^vehicle:(%d+):%a+$')
        if otherId and tonumber(otherId) ~= vehicleId then
            stale[#stale + 1] = storeId
        end
    end
    -- Collected first, then removed.
    for _, storeId in ipairs(stale) do
        Stores.removeViewer(source, storeId)
        print(('[whip_core:vehicle] released stale storage membership %s for src %s — its '
            .. 'close never arrived'):format(storeId, tostring(source)))
    end
    -- The cache those memberships were pinning can go now, if nothing else holds it.
    for _, storeId in ipairs(stale) do
        local vid = tonumber(storeId:match('^vehicle:(%d+):'))
        if vid then Vehicles.unloadIfIdle(vid) end
    end
end

--- Send the open-storage screen for a vehicle compartment the player has just been let into.
--- Shared by the player's open (below) and Vehicles.openTrunkFor (OpenStore).
---@param source number
---@param player table
---@param def table  the vehicle's def
---@param vehicleId number
---@param storageType string
local function sendStoragePayload(source, player, def, vehicleId, storageType)
    -- Build storage def (mimics containerDef shape for NUI)
    local storageNames = { trunk = 'Trunk', glovebox = 'Glovebox', key = 'Ignition' }
    local storageName = storageNames[storageType] or storageType

    -- Activity log: opening a vehicle storage IS opening the inventory (in a car, F2 routes here
    -- instead of openInventory), so it is logged as inv_open with the storage named.
    Log.paced(player.charId, 'inv_open',
        { detail = ('%s of %s'):format(storageName, def.plate or '?') })
    local storageCfg       = Vehicles.getStorageConfig(vehicleId, storageType)
    local storageSlots     = storageCfg.slots
    local storageMaxWeight = storageCfg.maxWeight

    -- If opening glovebox and player is the driver, also include ignition data
    local showIgnition = false
    ---@type table|false
    local ignitionSlot = false  -- false = empty, table = has key
    if storageType == 'glovebox' then
        local ped = GetPlayerPed(source)
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            showIgnition = true
            ignitionSlot = Vehicles.getIgnitionSlot(vehicleId) or false
        end
    end

    local payload = Inventory.buildPayload(player)
    payload.vehicleId     = vehicleId
    payload.storageType   = storageType
    payload.storageDef    = {
        name      = storageName .. ' — ' .. def.plate,
        slots     = storageSlots,
        maxWeight = storageMaxWeight,
    }
    payload.storageInv    = Vehicles.serializeStorage(vehicleId, storageType)
    payload.storageWeight = Vehicles.getWeight(vehicleId, storageType)
    -- The plate on the record (the client's memory key is the vehicle id). The client compares it
    -- with the plate the car is wearing and traces any difference.
    payload.plate         = def.plate
    payload.showIgnition  = showIgnition
    payload.ignitionSlot  = ignitionSlot
    -- The id the delta protocol is keyed on — see the container open path for why.
    payload.storeId       = ('vehicle:%s:%s'):format(tostring(vehicleId), storageType)
    TriggerClientEvent('whip_core:client:openVehicleStorage', source, payload)
end

--- Player opens trunk (the boot's prompt) or glovebox (G key while in vehicle)
SecureEvent('whip_core:server:openVehicleStorage', {
    -- Burst 3: trunk, glovebox and ignition share one bucket, and the seat reconcile in
    -- client/vehicles.lua spends it too, so a reconcile and a press can land in the same half-second.
    rateLimit = 500,
    burst = 3,
    params = {
        -- 0 means "the vehicle I am sitting in, whichever that is" — see below. The trunk still
        -- names a vehicle, because you open a boot from outside and there is nothing to infer.
        {'vehicleId', 'id', 0},   -- 0 = resolve from the seat
        {'storageType', 'enum', {'trunk', 'glovebox', 'key'}},
    },
}, function(source, player, vehicleId, storageType)
    -- One refusal path, and it names the branch in the console (Config.LogVehicleStorage). `msg` is
    -- the toast, nil where the player is told nothing.
    local function deny(why, msg)
        if Config.LogVehicleStorage ~= false then
            print(('[whip_core:vehstore] REFUSED %s for %s (src %s) vehicleId=%s — %s')
                :format(tostring(storageType), GetPlayerName(source) or '?', tostring(source),
                        tostring(vehicleId), why))
        end
        if msg then ShowError(source, msg) end
        TriggerClientEvent('whip_core:client:openVehicleStorageDenied', source)
    end

    -- Every request, not just the refused ones: no request line means the client never sent one.
    if Config.LogVehicleStorage ~= false then
        print(('[whip_core:vehstore] request %s from %s (src %s) vehicleId=%s')
            :format(tostring(storageType), GetPlayerName(source) or '?', tostring(source),
                    tostring(vehicleId)))
    end

    if not player.inventory then
        deny('player inventory not loaded')
        return
    end

    -- The glovebox and ignition belong to the seat, not to a claimed id: the server reads which car
    -- the player sits in (a passenger's client may not know its id). This is not the lock (a modified
    -- client warps into a locked seat); the lock is held where every move passes, Stores.fromWire's
    -- mayReachInsideLocked.
    if storageType == 'glovebox' or storageType == 'key' then
        local ped = GetPlayerPed(source)
        local veh = (ped and ped ~= 0) and GetVehiclePedIsIn(ped, false) or 0
        if veh == 0 then
            deny('server says this player is not in a vehicle')
            return
        end

        local seatedId = Vehicles.getEntityVehicleId(veh)
        if not seatedId then
            -- The car has no vehicle record yet, so there is nothing to open. Usually means the
            -- driver's client has not registered it; it resolves itself a moment later.
            deny(('seat resolved entity %s but it has no vehicle record'):format(tostring(veh)),
                 'This vehicle is not ready yet')
            return
        end
        vehicleId = seatedId
    elseif vehicleId == 0 then
        -- Only the in-vehicle storages may leave the id to the server.
        deny('trunk request arrived with vehicleId 0 — only glovebox/key may omit it')
        return
    end

    local def = Vehicles.getDef(vehicleId)
    if not def then
        deny('no vehicle def for that id', 'Vehicle not found')
        return
    end

    -- A bicycle has no glovebox and no ignition. Its rider gets the plain inventory (the client asks
    -- for neither on one); this is the server's word on it.
    if (storageType == 'glovebox' or storageType == 'key') and Vehicles.isBicycle(vehicleId) then
        deny('a bicycle has no ' .. storageType, storageType == 'glovebox' and 'A bicycle has no glovebox' or nil)
        return
    end

    -- A trunk or glovebox turned off for its model or category (/whip Vehicle Adjustments). The clients hide it as
    -- well (vehicleStorageSync); this is the server's word on it.
    if storageType ~= 'key' and not Vehicles.hasStorage(vehicleId, storageType) then
        deny(storageType .. ' is off for this vehicle (Vehicle Adjustments)', 'This vehicle has no ' .. storageType)
        return
    end

    -- Distance check, for the boot only: the glovebox and ignition were resolved from the seat.
    if storageType == 'trunk'
       and not IsPlayerNearVehicle(source, vehicleId, Vehicles.trunkOpenRange()) then
        deny(('too far from the vehicle (allowed %.1fm)'):format(Vehicles.trunkOpenRange()))
        return
    end

    -- Trunk requires vehicle to be unlocked
    if storageType == 'trunk' and Vehicles.isLocked(vehicleId) then
        deny('vehicle is locked', 'Vehicle is locked')
        return
    end

    shedStaleStorage(source, vehicleId)

    -- Into its viewers: shared, as a stash is (two players may look in one boot; each move is atomic)
    Vehicles.tryOpenStorage(vehicleId, storageType, source)

    -- Load inventory on-demand. A failed read must not open an apparently-empty storage.
    if not Vehicles.invCache[vehicleId] then
        if not Vehicles.loadInventory(vehicleId) then
            Vehicles.releaseStorage(vehicleId, storageType, source)
            deny('inventory read failed', 'Could not read this vehicle storage')
            return
        end
    end

    sendStoragePayload(source, player, def, vehicleId, storageType)
end)

--- Open a vehicle's BOOT for a player from server code — OpenStore's path for
--- `{ kind = 'vehicle', id, sub = 'trunk' }`. The same rules as the player walking up and
--- pressing the key (the handler above) — near it, the car unlocked — and the same screen. The lock
--- is skippable by a caller that has already decided (`skipAccess`: a warrant, a spare key); the
--- distance is not, because it is also the keep range every move is held to (Stores.fromWire) and
--- the client closes a boot the player walks away from. The glovebox and ignition are not opened
--- this way: they belong to the seat (see above).
---@param source number
---@param player table
---@param vehicleId number
---@param opts table|nil  { skipAccess? }
---@return boolean ok
---@return string|nil reason
function Vehicles.openTrunkFor(source, player, vehicleId, opts)
    opts = opts or {}
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'Vehicle not found' end
    if not IsPlayerNearVehicle(source, vehicleId, Vehicles.trunkOpenRange()) then
        return false, 'Too far away'
    end
    if not opts.skipAccess and Vehicles.isLocked(vehicleId) then
        return false, 'Vehicle is locked'
    end

    shedStaleStorage(source, vehicleId)
    -- `skipAccess` opened a locked boot, so the viewer may keep moving in it while it stays locked.
    -- The keep range still holds.
    Vehicles.tryOpenStorage(vehicleId, 'trunk', source, opts.skipAccess and 'lock' or nil)
    if not Vehicles.invCache[vehicleId] and not Vehicles.loadInventory(vehicleId) then
        Vehicles.releaseStorage(vehicleId, 'trunk', source)
        return false, 'Could not read this vehicle storage'
    end

    sendStoragePayload(source, player, def, vehicleId, 'trunk')
    return true
end

--- A client noticed one of its storage requests never came back: printed in the server console,
--- next to the REFUSED line that probably caused it. An enum, not a string, so a client can't write
--- its own text into the log. Purely diagnostic.
SecureEvent('whip_core:server:reportStorageStall', {
    whileDead = true,   -- a diagnostic report, not an action
    rateLimit = 2000,
    burst     = 2,
    params    = { {'what', 'enum', {'trunk', 'glovebox', 'glovebox-swap'}} },
}, function(source, player, what)
    print(('[whip_core:stall] %s (src %s) got no reply to a %s request — it timed out after 5s. '
        .. 'Look just above for a REFUSED line naming this player.')
        :format(player and (player.fullName or player.firstName) or 'Unknown', tostring(source), what))
end)

--- Player closes inventory while vehicle storage is open
SecureEvent('whip_core:server:closeVehicleStorage', {
    whileDead = true,   -- dying closes the boot or glovebox, and its lock has to be released
    rateLimit = 250,
    burst     = 3,   -- closing a screen can retire trunk and glovebox in the same moment
    params = {
        {'vehicleId', 'id'},
        {'storageType', 'enum', {'trunk', 'glovebox', 'key'}, 'trunk'},
    },
}, function(source, _, vehicleId, storageType)
    -- Only a viewer may close (a close forces a save and an unload sweep).
    if not Stores.isViewer(source, ('vehicle:%s:%s'):format(tostring(vehicleId), storageType)) then
        RecordEventRejection('whip_core:server:closeVehicleStorage', source,
            'closed a vehicle storage they did not have open')
        return
    end

    pcall(Vehicles.saveInventory, vehicleId, storageType)
    Vehicles.releaseStorage(vehicleId, storageType, source)

    -- Drop the cache once nobody has ANY storage type of this vehicle open (one table per vehicle
    -- covers trunk, glovebox and key).
    Vehicles.unloadIfIdle(vehicleId)

end)

-- ============================================
-- Ignition Key Events
-- ============================================

--- Check if ignition has a key (called when player enters driver seat)
SecureEvent('whip_core:server:checkIgnition', {
    -- A seat entry happens at human pace; limited and pinned to the car the caller is at (it
    -- announces an entry, answers what is in the ignition, and loads the car's inventory).
    rateLimit = 500,
    burst     = 3,
    params = { {'vehicleId', 'id', 0} },   -- 0 = no whip id (an unregistered car)
}, function(source, _, vehicleId)
    if not vehicleId or vehicleId == 0 then
        -- No vehicleId (NPC not yet registered) — no key restriction
        TriggerClientEvent('whip_core:client:ignitionState', source, 0, true)
        return
    end

    local def = Vehicles.getDef(vehicleId)
    if not def then
        TriggerClientEvent('whip_core:client:ignitionState', source, 0, true)
        return
    end

    -- Asked on entering the driver's seat, so the asker is IN the car — 10m allows for the
    -- entry animation and a moving vehicle without allowing "across the map".
    if not IsPlayerNearVehicle(source, vehicleId, 10.0) then
        RecordEventRejection('whip_core:server:checkIgnition', source,
            'asked about a vehicle they are nowhere near')
        return
    end

    -- Taking the driver's seat, announced through the seat record (a repeat check announces nothing;
    -- passenger seats arrive through whip_core:server:vehicleSeat). Verified in its own thread: the
    -- server waits to see the ped in the seat, without holding up the ignition answer below.
    CreateThread(function()
        if not seatSettles(source, vehicleId, -1, true) then return end
        announceEntered(source, vehicleId, -1, def.plate)   -- logs the entry too, once
    end)

    -- Answered NOW, before the seat settles and the strip's key moves in — so it also says whether
    -- that key is coming (accessoryKeyFor), and the client holds an engine press until it lands.
    -- A bicycle has no ignition and needs no key (Vehicles.ignitionReady): yes, always.
    local hasKey = Vehicles.ignitionReady(vehicleId)
    local hasUnhacked = Vehicles.hasUnhackedKeyInIgnition(vehicleId)
    local coming = not hasKey and accessoryKeyFor(vehicleId, source) ~= nil
    TriggerClientEvent('whip_core:client:ignitionState', source, vehicleId, hasKey, hasUnhacked, coming)
end)

-- Key in/out of the ignition is an ordinary move: a one-slot 'vehicle' store with sub='key'. The
-- vehicle kind's hooks in stores.lua refuse swapping a key already in, and tell the client the
-- engine's state changed.

-- ============================================
-- Lockpick Vehicle (server-run skill check)
-- ============================================
--
-- One event; the server runs the minigame and judges it (Skill.run, server/skillcheck.lua), as
-- doors do (doorLockpickAttempt).

local LOCKPICK_RANGE = 10.0   -- metres from the car, before the pick and again after it

SecureEvent('whip_core:server:attemptLockpick', {
    rateLimit = 5000,
    params = { {'vehicleId', 'id'} },
    -- A retry inside the cooldown is answered: a miss can end the ring in under a second. The flat
    -- 5 s stays (no burst, decided).
    onReject = function(src, reason)
        if reason == 'Rate limited' then NotifyPlayer(src, 'One moment, then try the lock again', 'error') end
    end,
}, function(source, player, vehicleId)

    -- Validate player has a lockpick. Refusals here and below are `return false, 'why'`.
    if not Vehicles.playerHasLockpick(player) then
        return false, 'You don\'t have a lockpick'
    end

    local def = Vehicles.getDef(vehicleId)
    if not def then return end
    -- A secured car (SpawnTempVehicle opts.secure: a run's, whose key is the way in) cannot be picked.
    if def.secure then return false, 'This lock can\'t be picked' end

    -- Distance check
    if not IsPlayerNearVehicle(source, vehicleId, LOCKPICK_RANGE) then
        return false, 'Too far from that vehicle'
    end

    -- Issued and judged here: Config.LockpickGame, with a one-second floor (LockpickSkill, server/skillcheck.lua).
    local passed = LockpickSkill(source, 'medium')

    -- Everything re-checked AFTER the wait — the check takes seconds, and the lockpick, the car and
    -- the player's position can all have changed while it ran.
    if not Vehicles.playerHasLockpick(player) then return end

    if not passed then
        return false, 'Lockpick failed!'
    end

    def = Vehicles.getDef(vehicleId)
    if not def then return end

    -- Distance re-check: they passed, then walked off during the ring — said, not silent
    if not IsPlayerNearVehicle(source, vehicleId, LOCKPICK_RANGE) then
        return false, 'Too far from that vehicle'
    end

    -- Unlock via framework setLocked, which announces the lock change itself.
    local ok, err = Vehicles.setLocked(vehicleId, false, source)
    if not ok then
        return false, tostring(err or 'Could not unlock the vehicle')
    end
    announceLockNear(vehicleId, false)

    WhipEmit('whip_core:vehicle:lockpicked', {
        vehicleId = vehicleId,
        plate     = def.plate,
        source    = source,
    })

    ShowSuccess(source,
        ('Lockpicked — %s'):format(def.plate))

end)

-- ============================================
-- Hack Ignition (Hacked Vehicle Key) — server-run skill check
-- ============================================
--
-- As the lockpick above: the server runs and judges the check.

SecureEvent('whip_core:server:attemptHackIgnition', {
    -- Longer than the check itself, so a second attempt cannot start while the first is running.
    rateLimit = 8000,
    params = { {'vehicleId', 'id'} },
}, function(source, player, vehicleId)

    -- The player must be in THIS vehicle's driver seat. Refusals here and below are
    -- `return false, 'why'`: shown and recorded.
    if not Vehicles.isPlayerDriving(source, vehicleId) then
        return false, 'Must be in driver seat'
    end
    -- A secured car (SpawnTempVehicle opts.secure) cannot have its ignition hacked: its key is the way.
    local secured = Vehicles.getDef(vehicleId)
    if secured and secured.secure then return false, 'This ignition can\'t be hacked' end

    -- Validate unhacked key is in ignition
    local hasUnhacked, _ = Vehicles.hasUnhackedKeyInIgnition(vehicleId)
    if not hasUnhacked then
        return false, 'No hackable key in ignition'
    end

    -- The hard check, issued and judged here, the same game as the lockpicks (LockpickSkill).
    local passed = LockpickSkill(source, 'hard')
    if not passed then
        return false, 'Hack failed!'
    end

    -- Still in the driver's seat of the car being hacked. The check takes seconds, and the
    -- reward must not be collectable from wherever the player got to in the meantime.
    if not Vehicles.isPlayerDriving(source, vehicleId) then return end

    -- Re-validate unhacked key is still in ignition
    hasUnhacked = Vehicles.hasUnhackedKeyInIgnition(vehicleId)
    if not hasUnhacked then return end

    -- Link the hacked key to this vehicle
    local ok = Vehicles.linkHackedKey(vehicleId)
    if not ok then
        return false, 'Hack error'
    end

    -- Broadcast updated ignition state — key now counts as valid
    TriggerClientEvent('whip_core:client:ignitionState', source, vehicleId, true, false)
    TriggerClientEvent('whip_core:client:updateIgnitionSlot', source, {
        ignitionSlot = Vehicles.getIgnitionSlot(vehicleId),
    })

    -- Sync vehicle keys (hacked key now links to this vehicle)
    Vehicles.syncKeys(source, player)

    local def = Vehicles.getDef(vehicleId)
    ShowSuccess(source,
        ('Key hacked — %s'):format(def and def.plate or vehicleId))

end)

-- ============================================
-- The game's own list of vehicles (Vehicles.modelExists, server/vehicles.lua)
-- ============================================

--- A player's game says which vehicle models it has: sent as whip_core comes up in it, at the character screen
--- (client/vehicles.lua), so it needs no character and is taken from a dead one: it is a fact about the game,
--- not an action (Josh, 1 Nov: a character loading dead had it refused, and the server knew no cars that session).
--- Checked name by name (letters, digits, _ and - only) and capped.
-- Once per account a server run (its license; reconnecting does not report again), so a client cannot keep feeding
-- the list (which has its own ceiling). The list is saved for MODELS_FORGET_DAYS, so a report that would add more than
-- MODELS_SAVE_NEW_MAX new names to a list that already knows MODELS_SEEDED is believed for this run only, never
-- saved: GTA itself is about 800 cars and an add-on pack a few hundred, but a lying client's junk must not outlive
-- restarts or fill the ceiling for two weeks. (A name it shares with a believable report is saved then.)
-- MODELS_SAVE_NEW_MAX is for the whole run, every account together, not each one (audit 20, VEH-6: twelve accounts,
-- or one over twelve restarts, filled the saved list); what is over it is known until the restart only.
local modelsReported = {}   -- [license, or source] = true once that account's game has reported this run
local MODELS_SAVE_NEW_MAX = 1500
local MODELS_SEEDED = 500
local savedNewThisRun = 0   -- new names saved this run once the list was seeded, all reports together

SecureEvent('whip_core:server:vehicleModels', {
    requirePlayer = false,
    whileDead = true,
    rateLimit = 60000,
    params = { { 'models', 'list', { 'model', 'key', 60 }, 6000 } },
}, function(source, _, models)
    local who = GetPlayerIdentifierByType(source, 'license') or ('source:' .. tostring(source))
    if modelsReported[who] then return end
    modelsReported[who] = true
    local seeded = Vehicles.knownModelCount() >= MODELS_SEEDED
    -- Saved when the report is believable (all of its names: their days move on), within the run's budget; else known
    -- for this run only
    local saved = not seeded or savedNewThisRun + Vehicles.newModelCount(models) <= MODELS_SAVE_NEW_MAX
    local added = Vehicles.addKnownModels(models, nil, not saved)
    if saved and seeded then savedNewThisRun = savedNewThisRun + added end
    if added > 0 then
        print(('[whip_core:vehicle] %s\'s game knows %d vehicle models (%d new to the list%s)')
            :format(GetPlayerName(source) or tostring(source), #models, added,
                saved and '' or ', too many to trust: kept until the restart, not saved'))
    end
end)

-- (The vehicle, key and appearance exports live in server/vehicles.lua; a boot or glovebox is
-- reached by address — { kind = 'vehicle', id, sub = 'trunk' } — through the exports in
-- server/stores.lua. Garage and ground-item exports live in server/garages.lua and
-- server/ground.lua.)
