-- ============================================
-- VehicleDamage — the damage an owned car keeps
-- ============================================
--
-- A car keeps its engine and body health, the doors torn off it and its burst tyres, through the
-- garage and a restart (Config.VehicleDamage). Five vehicle stats hold them, saved with the car's
-- other stats on its row unit. Dents are not kept: the car looks clean and keeps its numbers.
--
-- Where each number comes from:
--   engine, body   the SERVER reads them off the car (GTA's sync from the game running it): when
--                  the driver gets out, in the car sweep, and at the last look before a despawn.
--   doors, tyres   the DRIVER'S game reports them (client/vehicle_damage.lua). No server native
--                  sees a torn-off door, and the server numbers wheels its own way, not by the
--                  tyre numbers the natives that burst them use.
--
-- A new entity is a car like new, so nothing is read from it until its stored damage is back on
-- ("done", keyed on the entity, as Vehicles' dressed list is). The game running the car puts it
-- back: for a garage pull that is the player who pulled it, whose game gets the car first. It is
-- offered a few times just after the spawn, then by the sweep, and always to whoever takes the
-- wheel. The put-back only ever adds damage (the lower health, more doors and tyres), so sending it
-- twice, or onto a car hit since it spawned, does nothing wrong.
--
-- Both sources are the game running the car, as GTA's own sync is: a modified game can repair its
-- own car whichever way this is read.

VehicleDamage = {}

--- The stats, on GTA's own scales. Doors are a mask of door numbers 0-7 (bit n is door n); tyres
--- are masks over client/vehicle_damage.lua's TYRES list. A car never written reads the defaults: new.
local STATS = {
    engineHealth = { default = 1000, min = 0, max = 1000, persist = true },
    bodyHealth   = { default = 1000, min = 0, max = 1000, persist = true },
    doorsOff     = { default = 0,    min = 0, max = 255,  persist = true },
    tyresFlat    = { default = 0,    min = 0, max = 255,  persist = true },
    tyresRim     = { default = 0,    min = 0, max = 255,  persist = true },
}

for name, config in pairs(STATS) do
    local ok, err = VehicleStats.register(name, config, GetCurrentResourceName())
    if not ok then
        print(('[whip_core:damage] could not register "%s": %s'):format(name, tostring(err)))
    end
end

--- After the put-back is confirmed, reads wait this long: the server's copy of the car comes by
--- GTA's sync, which can land after the answer, and a read of the old copy would save the car as new.
local SETTLE_MS = 2000

--- An offer to the same game is not sent again inside this.
local RESEND_MS = 5000

--- When a fresh car is offered to the game running it, counted from the spawn. Nobody may run it
--- yet; after the last, the sweep and the driver's seat take over.
local OFFER_AFTER_MS = { 500, 1500, 3000, 6000, 10000 }

--- [vehicleId] = { entity, at }: this entity wears its stored damage (since `at`).
local done = {}

--- [vehicleId] = { entity, to = { [source] = GetGameTimer() } }: offered, not yet confirmed.
local sent = {}

local function on()
    return (Config.VehicleDamage or {}).remember ~= false
end

local function engineFloor()
    local n = tonumber((Config.VehicleDamage or {}).engineFloor) or 100
    return math.max(0, math.min(1000, n))
end

--- Only owned cars have a row to keep anything on.
local function keeps(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    return def ~= nil and not def.session
end

local function isDone(vehicleId, entity)
    local d = done[vehicleId]
    return d ~= nil and entity ~= nil and d.entity == entity
end

---@param settled boolean  read at once (nothing was put on, so there is nothing to wait for)
local function markDone(vehicleId, entity, settled)
    done[vehicleId] = { entity = entity, at = GetGameTimer() - (settled and SETTLE_MS or 0) }
    sent[vehicleId] = nil
end

--- What is stored, as the put-back sends it.
local function stored(vehicleId)
    local get = VehicleStats.get
    return {
        engine = get(vehicleId, 'engineHealth') or 1000,
        body   = get(vehicleId, 'bodyHealth') or 1000,
        doors  = get(vehicleId, 'doorsOff') or 0,
        flat   = get(vehicleId, 'tyresFlat') or 0,
        rim    = get(vehicleId, 'tyresRim') or 0,
    }
end

local function undamaged(d)
    return d.engine >= 1000 and d.body >= 1000 and d.doors == 0 and d.flat == 0 and d.rim == 0
end

--- Write one, taking the stat off at its default: an undamaged car carries none of them.
local function put(vehicleId, name, value)
    if value == STATS[name].default then return VehicleStats.clear(vehicleId, name) end
    return VehicleStats.set(vehicleId, name, value, 'damage')
end

--- Hand the stored damage to a game that can put it on: `to`, or whoever's game runs the car.
--- A car with nothing stored is done at once, and nothing is sent.
---@param vehicleId number
---@param entity number|nil  defaults to the tracked entity
---@param to number|nil      a player's server id; defaults to the car's network owner
function VehicleDamage.offer(vehicleId, entity, to)
    if not on() or not keeps(vehicleId) then return end
    entity = entity or Vehicles.getEntity(vehicleId)
    if not entity or not DoesEntityExist(entity) or isDone(vehicleId, entity) then return end

    local d = stored(vehicleId)
    if undamaged(d) then
        markDone(vehicleId, entity, true)
        return
    end

    to = to or NetworkGetEntityOwner(entity)
    if type(to) ~= 'number' or to <= 0 then return end   -- no game runs it yet

    local s = sent[vehicleId]
    if not s or s.entity ~= entity then
        s = { entity = entity, to = {} }
        sent[vehicleId] = s
    end
    local now = GetGameTimer()
    if s.to[to] and now - s.to[to] < RESEND_MS then return end
    s.to[to] = now

    TriggerClientEvent('whip_core:client:vehicleDamagePutBack', to, vehicleId,
        NetworkGetNetworkIdFromEntity(entity), {
            engine = math.max(d.engine, engineFloor()),
            body   = d.body,
            doors  = d.doors,
            flat   = d.flat,
            rim    = d.rim,
        })
end

--- Read engine and body health off the car and keep them. Nothing until this entity is done and
--- settled. Synchronous, no waits: Vehicles.despawn calls it just before the delete.
---@param vehicleId number
---@param entity number|nil  defaults to the tracked entity
function VehicleDamage.read(vehicleId, entity)
    if not on() or not keeps(vehicleId) then return end
    entity = entity or Vehicles.getEntity(vehicleId)
    if not entity or not DoesEntityExist(entity) or not isDone(vehicleId, entity) then return end
    if GetGameTimer() - done[vehicleId].at < SETTLE_MS then return end

    local engine, body = GetVehicleEngineHealth(entity), GetVehicleBodyHealth(entity)
    -- Both 0 is a car no game has sent the server yet (its copy starts empty), not a car at 0.
    if engine == 0 and body == 0 then return end

    engine = math.floor(math.max(0, math.min(1000, engine)) + 0.5)
    body   = math.floor(math.max(0, math.min(1000, body)) + 0.5)
    VehicleStats.batched(vehicleId, function()
        put(vehicleId, 'engineHealth', engine)
        put(vehicleId, 'bodyHealth', body)
    end)
end

--- The car sweep's turn (Vehicles' position sweep, every car out): read it, or offer it again.
function VehicleDamage.sweep(vehicleId, entity)
    if isDone(vehicleId, entity) then
        VehicleDamage.read(vehicleId, entity)
    else
        VehicleDamage.offer(vehicleId, entity)
    end
end

--- A repair: the car is like new on record. The car itself is fixed by the game running it (by the server on
--- GTA V Enhanced); reads wait SETTLE_MS again, so a read of the car before the fix lands does not put the damage back.
---@param vehicleId number
---@return boolean ok
---@return string|nil err
function VehicleDamage.clear(vehicleId)
    if not Vehicles.getDef(vehicleId) then return false, 'Vehicle not found' end
    VehicleStats.batched(vehicleId, function()
        for name in pairs(STATS) do VehicleStats.clear(vehicleId, name) end
    end)
    local d = done[vehicleId]
    if d then d.at = GetGameTimer() end
    return true
end

exports('ClearVehicleDamage', function(vehicle)
    local vehicleId, refErr = Vehicles.idFromRef(vehicle)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    return VehicleDamage.clear(vehicleId)
end)

-- ============================================
-- When
-- ============================================

Vehicles.onLife('spawned', function(e)
    if e.session or not e.entity then return end
    local vehicleId, entity = e.vehicleId, e.entity
    for _, ms in ipairs(OFFER_AFTER_MS) do
        SetTimeout(ms, function()
            if Vehicles.getEntity(vehicleId) == entity then VehicleDamage.offer(vehicleId, entity) end
        end)
    end
end)

-- Taking the wheel: the driver's game puts it on, whoever else's game runs the car.
Vehicles.onLife('entered', function(e)
    if e.seat == -1 then VehicleDamage.offer(e.vehicleId, nil, e.source) end
end)

Vehicles.onLife('exited', function(e)
    if e.seat == -1 then VehicleDamage.read(e.vehicleId) end
end)

for _, kind in ipairs({ 'despawned', 'deleted', 'released' }) do
    Vehicles.onLife(kind, function(e)
        if type(e) == 'table' and e.vehicleId then
            done[e.vehicleId] = nil
            sent[e.vehicleId] = nil
        end
    end)
end

-- ============================================
-- What the games say
-- ============================================

--- The put-back is on. Only from a game it was sent to, for the entity it was sent for.
SecureEvent('whip_core:server:vehicleDamagePutBack', {
    whileDead = true,   -- not an action: a car near you gets put right whatever state you are in
    rateLimit = 50,
    burst     = 40,     -- a car park streaming in hands over every car in it
    params = {
        {'vehicleId', 'id'},
    },
}, function(source, _, vehicleId)
    local s = sent[vehicleId]
    if not s or not s.to[source] then return end
    local entity = Vehicles.getEntity(vehicleId)
    if not entity or entity ~= s.entity then return end
    markDone(vehicleId, entity, false)
end)

--- The doors torn off and the burst tyres, from the driver's game (or, just after getting out, the
--- game still running the car). Ignored until the car wears its stored damage: a fresh car's
--- intact doors are not news.
SecureEvent('whip_core:server:vehicleDamageReport', {
    whileDead = true,   -- dying at the wheel still leaves the car as it is
    rateLimit = 1000,
    burst     = 3,
    params = {
        {'vehicleId', 'id'},
        {'doors', 'int', 0, 255},
        {'flat',  'int', 0, 255},
        {'rim',   'int', 0, 255},
    },
}, function(source, _, vehicleId, doors, flat, rim)
    if not on() or not keeps(vehicleId) then return end
    local entity = Vehicles.getEntity(vehicleId)
    if not entity or not isDone(vehicleId, entity) then return end

    local ped = GetPlayerPed(source)
    if GetPedInVehicleSeat(entity, -1) ~= ped and NetworkGetEntityOwner(entity) ~= source then return end

    VehicleStats.batched(vehicleId, function()
        put(vehicleId, 'doorsOff', doors)
        put(vehicleId, 'tyresFlat', flat & ~rim)   -- a tyre on its rim is not also flat
        put(vehicleId, 'tyresRim', rim)
    end)
end)

-- ============================================
-- Wrecked: blown up, or sunk
-- ============================================
--
-- A sunk car's health stays up as it fills with water: no server native shows it. The game running the
-- car says (client/vehicle_damage.lua), as GTA's own sync trusts that game with the car. Kept per
-- entity: a new one (out of the garage again) starts sound.

-- [vehicleId] = the entity it was wrecked as. By the car, and let go by its own lifecycle (below), not by an
-- entityRemoved handler: that fires for every networked entity the server drops (audit 20, VEH-9; vehicles.lua).
local wrecked = {}

for _, kind in ipairs({ 'despawned', 'deleted', 'released' }) do
    Vehicles.onLife(kind, function(e)
        if type(e) == 'table' and e.vehicleId then wrecked[e.vehicleId] = nil end
    end)
end

--- Is a car wrecked: blown up, or sunk? Said by the game running it; blown up also reads as no health here
--- (only while a game runs it: before one has sent the car, it reads 0).
---@param entity number
---@return boolean
function VehicleDamage.isWrecked(entity)
    if not entity or entity == 0 then return false end
    local vehicleId = Vehicles.getEntityVehicleId(entity)
    if vehicleId and wrecked[vehicleId] == entity then return true end
    local owner = NetworkGetEntityOwner(entity)
    return owner ~= nil and owner > 0 and GetEntityHealth(entity) <= 0
end

--- IsVehicleWrecked(vehicle) -> boolean: blown up, or sunk. false for a car that is not out in the world.
exports('IsVehicleWrecked', function(vehicle)
    local vehicleId = Vehicles.idFromRef(vehicle)   -- a vehicleId or a vehicle reference
    local entity = vehicleId and Vehicles.getEntity(vehicleId)
    return entity ~= nil and VehicleDamage.isWrecked(entity) == true
end)

SecureEvent('whip_core:server:vehicleWrecked', {
    whileDead = true,   -- drowning in it is one way a car sinks
    rateLimit = 1000,
    burst     = 3,
    params = {
        {'vehicleId', 'id'},
        {'wrecked', 'bool'},
    },
}, function(source, _, vehicleId, isWrecked)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity or NetworkGetEntityOwner(entity) ~= source then return end
    wrecked[vehicleId] = isWrecked and entity or nil
end)
