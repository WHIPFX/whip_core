-- A driving event removed from its car (DirectorTakes.onCar) is never played: not by the car's Play a Scripted Driving
-- Event task, not by a Play Scripted Driving Event card, and Check says so. Its row is kept (older revisions name it),
-- so the server could still read it. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua removedtake_module.lua

-- ---- what the cards reach, faked: cars made (entity = 900 + id), the lists they are given ----
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
local lists = {}
rawset(Actors, 'setTow', function() return 1 end)
rawset(Actors, 'runTasks', function(_, ent, plan, opts)
    local first = plan.steps[1]
    lists[#lists + 1] = { ent = ent, t = first.t, p = opts.resolve(first) }
    return #lists
end)
-- Both takes still in the database: the old one (20) removed from the car's page, the new one (24) on it.
local TAKES = {
    [20] = { id = 20, lengthMs = 20000, start = { x = 1.0, y = 0.0, z = 0.0, heading = 0.0 } },
    [24] = { id = 24, lengthMs = 20000, start = { x = 2.0, y = 0.0, z = 0.0, heading = 0.0 } },
}
rawset(DirectorTakes, 'get', function(id) return TAKES[math.tointeger(tonumber(id))] end)
rawset(DirectorTakes, 'load', function(id) return TAKES[math.tointeger(tonumber(id))] end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local function car(take)
    return { id = 'car3', kind = 'vehicle', layer = 'run', label = 'Phantom Custom', def = { model = 'phantom', coords = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 },
        takes = { { id = 24, label = 'Driving event 1' } }, tasks = take and { list = { { k = 'a', t = 'take', take = take } }, after = 'stop' } or nil } }
end
local function doc(nodes, links, world)
    return { format = 2, name = 'Removed', description = '', vars = {}, comments = {}, world = world, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function tick(k) for _ = 1, k or 10 do HarnessTick(50) end end
local function said(run, text)
    for i = 1, run.trace.n do
        local e = run.trace[i]
        if e and type(e.text) == 'string' and e.text:find(text, 1, true) then return true end
    end
    return false
end
-- Switched on past Check (which refuses one naming a removed take: tested below): the run is what is under test, as a
-- scenario switched on before the take was removed.
local function start(key, d)
    local check = DirectorGraph.check
    rawset(DirectorGraph, 'check', function() return true, {} end)
    local okA, err = pcall(Director.activate, key, d, { rev = 1 })
    DirectorGraph.check = check
    if not okA then error(err) end
    local sc = Director.active[key]
    if not sc then error({ msg = 'not switched on' }) end
    local run, why = Director.startRun(sc, 1, nil, nil)
    if not run then error({ msg = 'no run: ' .. tostring(why) }) end
    tick()
    return run
end
local function errorsOf(d)
    local _, probs = DirectorGraph.check(d)
    local out = {}
    for _, p in ipairs(probs or {}) do if p.severity == 'error' then out[#out + 1] = tostring(p.message) end end
    return out
end
local SPAWN = function(take)
    return doc({ n('s', 'scenario.started'), n('c', 'vehicle.spawn', { cars = { 'car3' } }), n('w', 'scenario.succeed') },
               { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'w') }, { car(take) })
end

RegisterTestModule({
    category = 'Removed driving events', order = 1,
    tests = {
        { name = 'onCar: one of the car\'s own takes, not one removed from it', fn = function()
            local w = car(20)
            assertTrue(DirectorTakes.onCar(w, 24), 'its own')
            assertTrue(DirectorTakes.onCar(w, '24'), 'by text too')
            assertFalse(DirectorTakes.onCar(w, 20), 'removed')
            assertFalse(DirectorTakes.onCar({ id = 'x', kind = 'vehicle', def = {} }, 24), 'a car with none')
        end },
        { name = 'the car\'s task names the removed one: its list does not play it, and the run says why', fn = function()
            if not DirectorTasks.compile then error({ msg = 'no DirectorTasks' }) end
            lists, cars, nextCar = {}, {}, 0
            local run = start('rm_a', SPAWN(20))
            local played = false
            for _, x in ipairs(lists) do if x.t == 'take' and x.p and x.p.take == 20 then played = true end end
            assertFalse(played, 'driving event 20 never played')
            assertTrue(said(run, 'was removed from the car'), 'the run\'s log says it was removed')
            Director.deactivate('rm_a', 'switched off')
        end },
        { name = 'the car\'s task names its own: played', fn = function()
            lists, cars, nextCar = {}, {}, 0
            start('rm_b', SPAWN(24))
            local played = false
            for _, x in ipairs(lists) do if x.t == 'take' and x.p and x.p.take == 24 then played = true end end
            assertTrue(played, 'driving event 24 played')
            Director.deactivate('rm_b', 'switched off')
        end },
        { name = 'a Play Scripted Driving Event card naming the removed one: Could not, nothing played', fn = function()
            lists, cars, nextCar = {}, {}, 0
            local run = start('rm_c', doc({ n('s', 'scenario.started'), n('p', 'vehicle.playTake', { car = 'car3', take = 20, riders = false }),
                                            n('w', 'scenario.succeed'), n('f', 'scenario.fail') },
                                          { l('a', 's', 'out', 'p'), l('b', 'p', 'done', 'w'), l('c', 'p', 'failed', 'f') }, { car(nil) }))
            tick(10)
            assertEqual(#lists, 0, 'nothing played')
            assertTrue(said(run, 'driving event 20 was removed from the car'), 'the run\'s log says it was removed')
            Director.deactivate('rm_c', 'switched off')
        end },
        { name = 'Switching on refuses a scenario whose task names a removed one', fn = function()
            local ok = Director.activate('rm_d', SPAWN(20), { rev = 1 })
            assertFalse(ok and Director.active.rm_d ~= nil, 'not switched on')
            if Director.active.rm_d then Director.deactivate('rm_d', 'switched off') end
        end },
        { name = 'Check: the task naming the removed one is an error; its own, none', fn = function()
            local bad, found = errorsOf(SPAWN(20)), false
            for _, m in ipairs(bad) do if m:find('was removed from the car', 1, true) then found = true end end
            assertTrue(found, 'said: ' .. table.concat(bad, ' | '))
            for _, m in ipairs(errorsOf(SPAWN(24))) do assertFalse(m:find('Driving event', 1, true) ~= nil, 'no take error: ' .. m) end
        end },
    },
})
