-- Offline regression checks. Run from the repository root: lua5.4 dev/garage_defaults_test.lua
-- The production files run in an isolated environment; only native/database boundaries are stubs.
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function noop() end
local vectorMeta = {}
local function vector(x, y, z, w)
    return setmetatable({ x = x, y = y, z = z, w = w }, vectorMeta)
end
vectorMeta.__sub = function(a, b) return vector(a.x - b.x, a.y - b.y, a.z - b.z) end
vectorMeta.__len = function(v) return math.sqrt(v.x^2 + v.y^2 + v.z^2) end
local function environment()
    return setmetatable({ vector3 = vector, vector4 = vector, print = noop }, { __index = _G })
end
local function run(path, env) assert(loadfile(path, 't', env))() end

-- Real garage records, writes, spot seeding and default reconciliation against an in-memory DB.
local env = environment()
local writes, nextId, failWrite = 0, 0, false
local function write()
    if failWrite then error('simulated database failure') end
    writes = writes + 1
    nextId = nextId + 1
    return nextId
end
env.Config = {}
env.MySQL = { query = { await = write }, insert = { await = write }, update = { await = write } }
env.TriggerClientEvent = noop
env.GetCurrentResourceName = function() return 'whip_core' end
env.GetResourceState = function() return 'started' end
env.exports = noop
env.AddEventHandler = noop
env.Registry = { onRelease = noop }
env.Sanitize = { key = function(s) return s end }
env.WhipEmit = noop
env.WithTableCollation = function(s) return s end
run('server/garages.lua', env)
run('server/garage_spots.lua', env)
run('server/jbc_garage_setup.lua', env)
local garages, spots = env.Garages, env.GarageSpots
env.JbcGarageSetup()
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
check(count(garages.getAll()) == 16, 'first startup must create 16 default garages')
check(#spots.all() == 16, 'each default must have exactly one bay')
local before = writes
env.JbcGarageSetup()
check(writes == before, 'unchanged restart must perform no writes')

local retained = spots.all()[1]
local retainedId, garageKey = retained.spotId, retained.garageKey
local originalX = retained.x
assert(spots.create(garageKey, retained.x + 10, retained.y, retained.z, retained.heading))
env.JbcGarageSetup()
check(#spots.all() == 16 and spots.get(retainedId) ~= nil, 'remove surplus bays and preserve the nearest bay ID')
assert(spots.update(retainedId, originalX + 1, retained.y, retained.z, retained.heading + 2))
env.JbcGarageSetup()
check(spots.get(retainedId).x == originalX, 'restore a moved managed bay')
assert(spots.delete(retainedId))
env.JbcGarageSetup()
check(#spots.all() == 16, 'restore a missing managed bay')

local legacy = garages.get('whip_motelgarage')
legacy.resource = 'whip_garages'
env.JbcGarageSetup()
check(legacy.resource == 'whip_core', 'adopt the earlier satellite garage')
legacy.resource = 'whip_garages'
failWrite = true
env.JbcGarageSetup()
check(legacy.resource == 'whip_garages', 'failed adoption must retain the old in-memory owner')
failWrite = false
env.JbcGarageSetup()

local casino = garages.get('whip_casinogarage')
garages._records.whip_casinogarage = nil
spots.deleteForGarage('whip_casinogarage')
local custom = assert(garages.create({ key = 'custom_casino', name = 'Custom',
    x = casino.x, y = casino.y, z = casino.z,
    spawnX = casino.spawnX, spawnY = casino.spawnY, spawnZ = casino.spawnZ }))
local customCount = #spots.all()
env.JbcGarageSetup()
check(garages.get('whip_casinogarage') == nil, 'skip a default next to an existing public garage')
check(#spots.all() == customCount and garages.get('custom_casino').garageId == custom.garageId,
    'preserve custom garages and bays')

-- An existing default key owned by another resource must remain that resource's responsibility.
local motel = garages.get('whip_motelgarage')
motel.resource = 'another_resource'
spots.deleteForGarage(motel.key)
env.JbcGarageSetup()
local motelBays = 0
for _, s in ipairs(spots.all()) do if s.garageKey == motel.key then motelBays = motelBays + 1 end end
check(motelBays == 0 and motel.resource == 'another_resource', 'do not reconcile another resource\'s garage')

-- Load the full vehicle implementation, preserving its actual transition lock and persist function.
local veh = environment()
veh.exports, veh.AddEventHandler, veh.Every = noop, noop, noop
veh.CoreStop, veh.FinalSave = { add = noop }, { add = noop }
veh.Registry, veh.Sentinel = { onRelease = noop }, { watch = noop }
veh.GamePlatform = { name = 'legacy' }
veh.GetConvar = function(_, default) return default end
veh.GetResourceKvpString = noop
veh.json = { decode = noop }
veh.Config = { LinkPublicGarages = true }
veh.Garages = garages
veh.GarageSpots = spots
veh.WhipEmit = noop
local committed, dbError, duringCommit = 0, false, nil
veh.Stores = { commitWithAction = function()
    if duringCommit then duringCommit() end
    if dbError then return false, 'simulated database failure' end
    committed = committed + 1
    return true
end }
run('server/vehicles.lua', veh)
local vehicles = veh.Vehicles
local fromKey, toKey = 'legion_square', 'whip_pillboxgarage'
local function car(id, owner, state, key)
    local v = { vehicleId = id, ownerCharId = owner, state = state or 'garaged',
        garage = key or fromKey, model = 'sultan', plate = 'TEST' .. id }
    vehicles._records[id] = v
    vehicles.reindex(id, v)
    return v
end
local v = car(1, 42)
check(vehicles.transferGarage(1, 42, fromKey, toKey) == true and v.garage == toKey, 'persist a valid transfer')
v.garage = fromKey
check(vehicles.transferGarage(1, 99, fromKey, toKey) == false, 'reject another character\'s vehicle')
check(vehicles.transferGarage(1, 42, toKey, fromKey) == false, 'reject stale source garage')
check(vehicles.transferGarage(1, 42, fromKey, fromKey) == false, 'reject transfer to the same garage')
for _, state in ipairs({ 'out', 'impounded' }) do
    v.state = state
    check(vehicles.transferGarage(1, 42, fromKey, toKey) == false, 'reject state: ' .. state)
end
v.state = 'garaged'
for _, flag in ipairs({ 'session', 'temp' }) do
    v[flag] = true
    check(vehicles.transferGarage(1, 42, fromKey, toKey) == false, 'reject ' .. flag .. ' vehicle')
    v[flag] = nil
end
dbError = true
check(vehicles.transferGarage(1, 42, fromKey, toKey) == false and v.garage == fromKey,
    'failed database write must roll the garage back')
check(vehicles._transitionLocks[1] == nil, 'release transition lock after database refusal')
dbError = false
duringCommit = function()
    check(vehicles.transferGarage(1, 42, fromKey, toKey) == false, 'reject overlapping transfer during the write')
end
check(vehicles.transferGarage(1, 42, fromKey, toKey) == true, 'complete the original transfer')
duringCommit = nil
check(vehicles._transitionLocks[1] == nil, 'release transition lock after success')

-- Production callbacks, with only the FiveM native and registration boundaries replaced.
local callbacks, events, bucket, position, inVehicle, stopped = {}, {}, 0, nil, 0, false
veh.SecureCallback = function(name, schema, fn) callbacks[name] = fn end
veh.SecureEvent = function(name, schema, fn) events[name] = fn end
veh.Character = { onLife = noop }
veh.GetPlayerRoutingBucket = function() return bucket end
veh.GetPlayerPed = function() return 100 end
veh.GetVehiclePedIsIn = function() return inVehicle end
veh.GetEntityCoords = function() return position end
veh.GetResourceState = function() return stopped and 'stopped' or 'started' end
veh.VehicleStats = { getStored = function() return {} end }
veh.VehicleCatalog = { rows = {} }
veh.TriggerClientEvent = noop
run('server/events_vehicles.lua', veh)
local originSpot
for _, s in ipairs(spots.all()) do if s.garageKey == fromKey then originSpot = s end end
assert(originSpot, 'source bay exists')
position = vector(originSpot.x, originSpot.y, originSpot.z)
v.garage = fromKey
local options = callbacks['whip_core:jbcTransferOptions']
local commit = callbacks['whip_core:jbcTransferCommit']
local player = { charId = 42 }
check(type(options(1, player, originSpot.spotId)) == 'table', 'offer eligible vehicles and destinations')
veh.Config.LinkPublicGarages = false
check(options(1, player, originSpot.spotId) == false, 'disabled setting prevents the popup')
check(commit(1, player, originSpot.spotId, 1, toKey) == false, 'disabled setting also rejects stale confirmation')
veh.Config.LinkPublicGarages = true
bucket = 1
check(options(1, player, originSpot.spotId) == false, 'reject a different routing bucket')
bucket = 0
inVehicle = 50
check(options(1, player, originSpot.spotId) == false, 'player must be on foot')
inVehicle = 0
position = position - vector(20, 0, 0)
check(commit(1, player, originSpot.spotId, 1, toKey) == false, 'recheck distance at confirmation')
position = vector(originSpot.x, originSpot.y, originSpot.z)
check(options(1, player, -1) == false, 'reject a missing bay')
check(commit(1, player, originSpot.spotId, 1, 'nonexistent') == false, 'reject an unknown destination')
check(commit(1, { charId = 99 }, originSpot.spotId, 1, toKey) == false, 'callback rejects another owner')
stopped = true
check(options(1, player, originSpot.spotId) == false, 'reject garages owned by stopped resources')
stopped = false
garages.registerAccess('property:', function() return false end)
garages._records['property:test'] = { key = 'property:test', name = 'Private', x = 0, y = 0, z = 0 }
assert(spots.create('property:test', 0, 0, 0, 0))
check(commit(1, player, originSpot.spotId, 1, 'property:test') == false, 'reject private destinations')
local result = commit(1, player, originSpot.spotId, 1, toKey)
check(type(result) == 'table' and v.garage == toKey, 'callback completes and returns the destination name')
check(commit(1, player, originSpot.spotId, 1, toKey) == false, 'reject replay of a completed transfer')
print(('OK — %d garage/transfer regression checks'):format(checks))
