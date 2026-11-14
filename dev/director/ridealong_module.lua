-- Play Scripted Driving Event's Ride along: the player's game seats them and says so, only then does the take start, on
-- their game, and it is told when the ride is over. A driver NPC is not made for it; the card's own car has its key in the
-- ignition. Refused, or never answered, the take plays without them. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua ridealong_module.lua

local cars, nextCar = {}, 0
rawset(Vehicles, 'spawnTempFor', function(model, at, opts)
    nextCar = nextCar + 1
    cars[nextCar] = { model = model, at = at, opts = opts }
    return nextCar
end)
rawset(Vehicles, 'getDef', function(id) return cars[id] and { plate = 'P' .. id, model = cars[id].model } or nil end)
rawset(Vehicles, 'getEntity', function(id) return cars[id] and 900 + id or nil end)
rawset(Vehicles, 'spotBlocked', function() return nil end)
rawset(Vehicles, 'despawnByRef', function(id) cars[id] = nil end)
rawset(Vehicles, 'getEntityVehicleId', function() return nil end)
rawset(_G, 'NetworkGetNetworkIdFromEntity', function(ent) return ent + 10000 end)
rawset(_G, 'DoesEntityExist', function(e) return e ~= nil and e ~= 0 end)
rawset(_G, 'GetEntityCoords', function() return { x = 2.0, y = 0.0, z = 0.0 } end)
rawset(_G, 'GetAllVehicles', function() return {} end)
rawset(_G, 'GetAllPeds', function() return {} end)
rawset(Players, 1, Players[1] or { charId = 1 })
rawset(Players, 2, Players[2] or { charId = 2 })

-- What this game was told, and each list a car is given.
local told, lists, npcs, seats = {}, {}, {}, {}
rawset(_G, 'TriggerClientEvent', function(name, src, ...)
    if name == 'whip_core:client:takeRide' or name == 'whip_core:client:takeRideOver' then
        told[#told + 1] = { name = name:match('[^:]+$'), src = src, args = { ... } }
    end
end)
rawset(Actors, 'setTow', function() return 1 end)
rawset(Actors, 'runTasks', function(_, ent, plan, opts)
    local rec = { ent = ent, plan = plan, opts = opts }
    for _, s in ipairs(plan.steps) do
        if s.t == 'take' then rec.take = opts.resolve(s) end
    end
    lists[#lists + 1] = rec
    return #lists
end)
rawset(Npcs, 'spawn', function(_, d)
    npcs[#npcs + 1] = d
    return #npcs, 7000 + #npcs
end)
rawset(Npcs, 'setState', function(_, id, state)
    if type(state.ride) == 'table' then seats[#seats + 1] = { id = id, seat = state.ride.seat } end
    return true
end)
local TAKES = { [24] = { id = 24, lengthMs = 20000, start = { x = 2.0, y = 0.0, z = 0.0, heading = 0.0 } } }
rawset(DirectorTakes, 'get', function(id) return TAKES[math.tointeger(tonumber(id))] end)
rawset(DirectorTakes, 'load', function(id) return TAKES[math.tointeger(tonumber(id))] end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local function reset() told, lists, npcs, seats, cars, nextCar = {}, {}, {}, {}, {}, 0 end

local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = 'in' } } end
local function world(riders)
    local w = { { id = 'car3', kind = 'vehicle', layer = 'run', label = 'Adder', def = { model = 'adder',
        coords = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }, takes = { { id = 24, label = 'Driving event 1' } }, riders = riders } } }
    for _, r in ipairs(riders or {}) do
        w[#w + 1] = { id = r.npc, kind = 'npc', layer = 'run', label = r.npc, def = { model = 'a_m_y_business_01',
            coords = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 } } }
    end
    return w
end
local function doc(props, riders, spawn)
    props.car, props.take = 'car3', 24
    if props.riders == nil then props.riders = riders ~= nil end
    local nodes = { n('s', 'scenario.started'), n('p', 'vehicle.playTake', props), n('w', 'scenario.succeed') }
    local links = { l('a', 's', 'out', 'p'), l('d', 'p', 'done', 'w') }
    if spawn then
        nodes[#nodes + 1] = n('c', 'vehicle.spawn', { cars = { 'car3' }, tasks = false })
        links = { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'p'), l('d', 'p', 'done', 'w') }
    end
    return { format = 2, name = 'Ride', description = '', vars = {}, comments = {}, world = world(riders), nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function start(key, d)
    local check = DirectorGraph.check
    rawset(DirectorGraph, 'check', function() return true, {} end)
    local okA, err = pcall(Director.activate, key, d, { rev = 1 })
    DirectorGraph.check = check
    if not okA then error(err) end
    local sc = Director.active[key]
    if not sc then error({ msg = 'not switched on' }) end
    local r, why = Director.startRun(sc, 1, nil, nil)
    if not r then error({ msg = 'no run: ' .. tostring(why) }) end
    for _ = 1, 10 do HarnessTick(50) end
    return r
end
local function asked() for _, t in ipairs(told) do if t.name == 'takeRide' then return t end end end
local function over() for _, t in ipairs(told) do if t.name == 'takeRideOver' then return t end end end
local function answer(src, ok)
    HARNESS_EVENTS['whip_core:server:takeRideSeated'](src, nil, asked().args[1], ok)
    for _ = 1, 4 do HarnessTick(50) end
end
local function finish(how)
    lists[#lists].opts.onEnd(how or 'done')
    for _ = 1, 8 do HarnessTick(50) end
end

RegisterTestModule({
    category = 'Play Scripted Driving Event: Ride along', order = 1,
    tests = {
        { name = 'The take waits for their game, then plays on it', fn = function()
            reset()
            start('ra_a', doc({ ride = true }))
            local a = asked()
            assertTrue(a ~= nil and a.src == 1, 'the player who started it is asked')
            assertEqual(a and a.args[2], 901 + 10000, 'of the car, by its network id')
            assertEqual(a and a.args[3].x, 2.0, 'told where the car is')
            assertTrue(a and a.args[4] > 20000, 'given longer than the take to let go by itself')
            assertEqual(#lists, 0, 'no take until they are seated')
            answer(1, true)
            assertEqual(#lists, 1, 'seated: the take starts')
            assertEqual(lists[1].take.pin, 1, 'on their game')
            assertTrue(over() == nil, 'still riding')
            finish()
            assertTrue(over() ~= nil, 'told it is over')
            assertEqual(over().args[2], false, 'it stops: they stay at the wheel')
            Director.deactivate('ra_a', 'switched off')
        end },
        { name = 'A car the card makes has its key in the ignition, for the ride only', fn = function()
            reset()
            start('ra_b', doc({ ride = true }))
            assertEqual(cars[1].opts.keyInIgnition, true, 'in the ignition')
            Director.deactivate('ra_b', 'switched off')
            reset()
            start('ra_b2', doc({}))
            assertEqual(cars[1].opts.keyInIgnition, nil, 'no ride: its key nobody\'s, as before')
            assertTrue(asked() == nil, 'no ride: nobody asked')
            assertEqual(#lists, 1, 'no ride: the take starts at once')
            Director.deactivate('ra_b2', 'switched off')
        end },
        { name = 'No NPC at the wheel; the others still sit', fn = function()
            reset()
            local riders = { { npc = 'drv', seat = 'driver' }, { npc = 'pas', seat = 'front passenger' } }
            start('ra_c', doc({ ride = true }, riders))
            assertEqual(#seats, 1, 'one NPC seated')
            assertTrue(seats[1] and seats[1].seat ~= -1, 'not at the wheel')
            local def = DirectorNodes.get('vehicle.playTake') --[[@as table]]
            local made = def.makes({ car = 'car3', ride = true }, doc({ ride = true }, riders))
            assertTrue(made.pas == true and made.drv == nil, 'Check knows it makes no driver')
            made = def.makes({ car = 'car3' }, doc({}, riders))
            assertTrue(made.drv == true, 'without the ride, it does')
            Director.deactivate('ra_c', 'switched off')
        end },
        { name = 'Everyone out, and their tasks start: out of the car; driving on: stays', fn = function()
            for key, want in pairs({ ['everyone gets out'] = true, ['their tasks start'] = true, ['it drives on'] = false }) do
                reset()
                local k = 'ra_d' .. key:sub(1, 3)
                start(k, doc({ ride = true, ending = key }))
                answer(1, true)
                finish()
                assertEqual(over() and over().args[2], want, key)
                Director.deactivate(k, 'switched off')
            end
        end },
        { name = 'Their game says no: the take plays without them, at once', fn = function()
            reset()
            start('ra_e', doc({ ride = true }))
            answer(1, false)
            assertEqual(#lists, 1, 'it plays')
            local o = over()
            assertTrue(o ~= nil, 'their game told to let go')
            finish()
            local count = 0
            for _, t in ipairs(told) do if t.name == 'takeRideOver' then count = count + 1 end end
            assertEqual(count, 1, 'and not told again at the end')
            Director.deactivate('ra_e', 'switched off')
        end },
        { name = 'Their game never answers: the take plays without them after the wait', fn = function()
            reset()
            start('ra_f', doc({ ride = true }))
            for _ = 1, 150 do HarnessTick(50) end
            assertEqual(#lists, 0, 'still waiting at 7.5 s')
            for _ = 1, 70 do HarnessTick(50) end
            assertEqual(#lists, 1, 'plays by 11 s')
            assertTrue(over() ~= nil, 'their game told to let go')
            Director.deactivate('ra_f', 'switched off')
        end },
        { name = 'Someone else\'s answer counts for nothing', fn = function()
            reset()
            start('ra_g', doc({ ride = true }))
            answer(2, true)
            assertEqual(#lists, 0, 'still waiting for theirs')
            answer(1, true)
            assertEqual(#lists, 1, 'theirs')
            Director.deactivate('ra_g', 'switched off')
        end },
        { name = 'The run stopped while riding: told, and not told to get out', fn = function()
            reset()
            start('ra_h', doc({ ride = true, ending = 'everyone gets out' }))
            answer(1, true)
            Director.deactivate('ra_h', 'switched off')
            for _ = 1, 10 do HarnessTick(50) end
            assertTrue(over() ~= nil, 'told it is over')
            assertEqual(over().args[2], false, 'nobody told to get out')
        end },
        { name = 'A take that does not finish: told, and not told to get out', fn = function()
            reset()
            start('ra_i', doc({ ride = true, ending = 'everyone gets out' }))
            answer(1, true)
            finish('stopped')
            assertTrue(over() ~= nil, 'told it is over')
            assertEqual(over().args[2], false, 'nobody told to get out')
            Director.deactivate('ra_i', 'switched off')
        end },
    },
})
