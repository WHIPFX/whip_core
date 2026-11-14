-- A car's driving event leaves to its tasks what they set (Lights, Indicators, Siren, Engine): its take step carries
-- `leave` (client/actors.lua skips those of the recording). A car's own list with a Lights step: its take step's
-- leave.lights; a list without: no leave. A Play Scripted Driving Event card on a car whose tasks the run started: the
-- same. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua takeleave_module.lua

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
-- Each list a car is given: its take step as it would be sent (resolved).
local takeSteps = {}
rawset(Actors, 'setTow', function() return 1 end)
rawset(Actors, 'runTasks', function(_, ent, plan, opts)
    for _, s in ipairs(plan.steps) do
        if s.t == 'take' then takeSteps[#takeSteps + 1] = { ent = ent, p = opts.resolve(s) } end
    end
    if opts.onEnd then SetTimeout(10, function() opts.onEnd('done') end) end
    return #takeSteps
end)
local TAKES = { [24] = { id = 24, lengthMs = 20000, start = { x = 2.0, y = 0.0, z = 0.0, heading = 0.0 } } }
rawset(DirectorTakes, 'get', function(id) return TAKES[math.tointeger(tonumber(id))] end)
rawset(DirectorTakes, 'load', function(id) return TAKES[math.tointeger(tonumber(id))] end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local function car(list)
    return { id = 'car3', kind = 'vehicle', layer = 'run', label = 'Phantom', def = { model = 'phantom',
        coords = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }, takes = { { id = 24, label = 'Driving event 1' } },
        tasks = { list = list, after = 'stop' } } }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = 'in' } } end
local function doc(nodes, links, world)
    return { format = 2, name = 'Lights', description = '', vars = {}, comments = {}, world = world, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function run(key, d)
    local check = DirectorGraph.check
    rawset(DirectorGraph, 'check', function() return true, {} end)
    local okA, err = pcall(Director.activate, key, d, { rev = 1 })
    DirectorGraph.check = check
    if not okA then error(err) end
    local sc = Director.active[key]
    if not sc then error({ msg = 'not switched on' }) end
    local r, why = Director.startRun(sc, 1, nil, nil)
    if not r then error({ msg = 'no run: ' .. tostring(why) }) end
    for _ = 1, 20 do HarnessTick(50) end
    return r
end
local LIGHTS = { k = 'a', t = 'lights', lights = 'on', beam = false, inside = false }
local TAKE = { k = 'b', t = 'take', take = 24 }
local SPAWN = function(list)
    return doc({ n('s', 'scenario.started'), n('c', 'vehicle.spawn', { cars = { 'car3' } }), n('w', 'scenario.succeed') },
               { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'w') }, { car(list) })
end

RegisterTestModule({
    category = 'A drive leaves to its car\'s tasks', order = 1,
    tests = {
        { name = 'Lights, then the driving event: its step leaves the lights', fn = function()
            takeSteps, cars, nextCar = {}, {}, 0
            run('tl_a', SPAWN({ LIGHTS, TAKE }))
            local s = takeSteps[#takeSteps]
            assertTrue(s ~= nil, 'the take step sent')
            assertTrue(s and type(s.p.leave) == 'table' and s.p.leave.lights == true, 'leave.lights')
            assertTrue(s and not s.p.leave.engine and not s.p.leave.siren, 'only what the list sets')
            Director.deactivate('tl_a', 'switched off')
        end },
        { name = 'The driving event alone: nothing left (the recording plays all of it)', fn = function()
            takeSteps, cars, nextCar = {}, {}, 0
            run('tl_b', SPAWN({ TAKE }))
            local s = takeSteps[#takeSteps]
            assertTrue(s ~= nil, 'the take step sent')
            assertTrue(s and s.p.leave == nil, 'no leave')
            Director.deactivate('tl_b', 'switched off')
        end },
        { name = 'Siren and Engine too, after the take in the list (a round): left', fn = function()
            takeSteps, cars, nextCar = {}, {}, 0
            run('tl_c', SPAWN({ TAKE, { k = 'c', t = 'siren', on = true }, { k = 'd', t = 'engine', how = 'off' } }))
            local s = takeSteps[#takeSteps]
            assertTrue(s and s.p.leave and s.p.leave.siren and s.p.leave.engine and not s.p.leave.lights, 'siren and engine')
            Director.deactivate('tl_c', 'switched off')
        end },
        { name = 'Play Scripted Driving Event on a car whose tasks the run started (Spawn Car): leaves its Lights', fn = function()
            takeSteps, cars, nextCar = {}, {}, 0
            local d = doc({ n('s', 'scenario.started'), n('c', 'vehicle.spawn', { cars = { 'car3' } }),
                            n('p', 'vehicle.playTake', { car = 'car3', take = 24, riders = false }), n('w', 'scenario.succeed') },
                          { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'p'), l('d', 'p', 'done', 'w') },
                          { car({ LIGHTS }) })
            run('tl_d', d)
            local s = takeSteps[#takeSteps]
            assertTrue(s ~= nil, 'the card\'s take step sent')
            assertTrue(s and s.p.leave and s.p.leave.lights == true, 'leave.lights from the car\'s own list')
            Director.deactivate('tl_d', 'switched off')
        end },
        { name = 'Play Scripted Driving Event making the car itself (its tasks never started): nothing left', fn = function()
            takeSteps, cars, nextCar = {}, {}, 0
            local d = doc({ n('s', 'scenario.started'),
                            n('p', 'vehicle.playTake', { car = 'car3', take = 24, riders = false }), n('w', 'scenario.succeed') },
                          { l('a', 's', 'out', 'p'), l('d', 'p', 'done', 'w') },
                          { car({ LIGHTS }) })
            run('tl_e', d)
            local s = takeSteps[#takeSteps]
            assertTrue(s ~= nil, 'the card\'s take step sent')
            assertTrue(s and s.p.leave == nil, 'no leave: its Lights never played')
            Director.deactivate('tl_e', 'switched off')
        end },
    },
})
