-- "Players and NPCs can stand on it while it moves" (a car's def.standOn: server/director/satellite_api.lua markStandOn):
-- every car a run makes for it carries VehicleData directorStandOn (Spawn Car, Play Take's car); a car without it
-- carries nothing. Against the real Director under the dev harness. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua standon_module.lua
local cars, nextCar = {}, 0
rawset(Vehicles, 'spawnTempFor', function(model, at)
    nextCar = nextCar + 1
    cars[nextCar] = { model = model, at = at }
    return nextCar
end)
rawset(Vehicles, 'getDef', function(id) return cars[id] and { plate = 'P' .. id, model = cars[id].model } or nil end)
rawset(Vehicles, 'getEntity', function(id) return cars[id] and 900 + id or nil end)
rawset(Vehicles, 'spotBlocked', function() return nil end)
rawset(Vehicles, 'despawnByRef', function(id) cars[id] = nil end)
rawset(Vehicles, 'getEntityVehicleId', function() return nil end)
rawset(_G, 'NetworkGetNetworkIdFromEntity', function(ent) return ent + 10000 end)
rawset(_G, 'GetAllVehicles', function() return {} end)
rawset(_G, 'GetAllPeds', function() return {} end)
local data = {}
rawset(VehicleData, 'get', function(id, key) return data[id] and data[id][key] end)
rawset(VehicleData, 'set', function(id, key, value) data[id] = data[id] or {}; data[id][key] = value return true end)
rawset(Actors, 'setTow', function() return 1 end)
-- (Not in the harness's own list: the made-thing news and the mark are there.)
local HERE = debug.getinfo(1, 'S').source:match('^@(.*)[/\\]') or '.'
local loaded, lerr = pcall(dofile, HERE .. '/../../server/director/satellite_api.lua')
if not loaded then io.stderr:write('LOAD satellite_api.lua: ' .. tostring(lerr) .. '\n') end

local function car(id, extra, layer)
    local d = { model = 'sultan', coords = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 } }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { id = id, kind = 'vehicle', layer = layer or 'run', label = id, def = d }
end
local function doc(nodes, links, world)
    return { format = 2, name = 'Stand', description = '', vars = {}, comments = {}, world = world, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function tick(k) for _ = 1, k or 10 do HarnessTick(50) end end
local function idOf(model)
    for id, c in pairs(cars) do if c.model == model then return id end end
end

RegisterTestModule({
    category = 'Stand on a car', order = 1,
    tests = {
        { name = 'Spawn Car: the car with it switched on carries directorStandOn; the other does not', fn = function()
            cars, nextCar, data = {}, 0, {}
            local ok, probs = Director.activate('so_a', doc({ n('s', 'scenario.started'), n('c', 'vehicle.spawn', { cars = { 'roof', 'plain' } }), n('w', 'scenario.succeed') },
                { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'w') },
                { car('roof', { standOn = true, model = 'flatbed' }), car('plain', { model = 'futo' }) }), { rev = 1 })
            assertTrue(ok, 'switched on: ' .. tostring(type(probs) == 'table' and probs[1] and probs[1].message))
            local run = Director.startRun(Director.active.so_a, 1, nil, nil)
            assertNotNil(run, 'a run')
            tick()
            local roof, plain = idOf('flatbed'), idOf('futo')
            assertNotNil(roof, 'the flatbed made')
            assertNotNil(plain, 'the futo made')
            assertTrue(data[roof] and data[roof].directorStandOn == true, 'the flatbed carries it')
            assertTrue(not (data[plain] and data[plain].directorStandOn), 'the futo does not')
            Director.deactivate('so_a', 'switched off')
        end },
        { name = 'Play Take: the car it makes where its take starts carries it too', fn = function()
            cars, nextCar, data = {}, 0, {}
            rawset(DirectorTakes, 'load', function(id) return id == 31 and { id = 31, lengthMs = 5000, start = { x = 5.0, y = 0.0, z = 0.0, heading = 0.0 } } or nil end)
            rawset(DirectorTakes, 'get', DirectorTakes.load)
            rawset(Actors, 'runTasks', function() return 1 end)
            local ok, probs = Director.activate('so_b', doc({ n('s', 'scenario.started'), n('p', 'vehicle.playTake', { car = 'roof', take = 31, riders = false }), n('w', 'scenario.succeed') },
                { l('a', 's', 'out', 'p'), l('b', 'p', 'done', 'w') },
                { car('roof', { standOn = true, model = 'flatbed', takes = { { id = 31 } } }) }), { rev = 1 })
            local why = {}
            for _, p in ipairs(type(probs) == 'table' and probs or { { message = tostring(probs) } }) do why[#why + 1] = tostring(p.message) end
            assertTrue(ok, 'switched on: ' .. table.concat(why, ' | '))
            local run = Director.startRun(Director.active.so_b, 1, nil, nil)
            assertNotNil(run, 'a run')
            tick()
            local roof = idOf('flatbed')
            assertNotNil(roof, 'the flatbed made where its take starts')
            assertTrue(data[roof] and data[roof].directorStandOn == true, 'it carries it')
            Director.deactivate('so_b', 'switched off')
        end },
    },
})
