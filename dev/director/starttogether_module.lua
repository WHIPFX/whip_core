-- Start Tasks fed by a Spawn NPC (made at once) and a Spawn Car (a second to make), both wired into it: it waits for
-- the car, starts the NPC's and the car's tasks once, together, and the NPC's Sit In finds the car; the second pulse
-- joins that start instead of starting them all again. Everything made already: started at once, as before. One never
-- made: the rest start when the wait runs out, and it is said. Against the real Director under the dev harness:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua starttogether_module.lua

local cars, nextCar = {}, 0
local CAR_TAKES_MS = 1000
rawset(Vehicles, 'spawnTempFor', function(model, at)
    Wait(CAR_TAKES_MS)   -- (a car takes a moment to be made)
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
local npcs, nextNpc = {}, 0
rawset(Npcs, 'spawn', function()
    nextNpc = nextNpc + 1
    npcs[nextNpc] = { npcId = nextNpc, netId = 5000 + nextNpc, alive = true, coords = { x = 0.0, y = 0.0, z = 0.0 } }
    return nextNpc, 5000 + nextNpc
end)
rawset(Npcs, 'get', function(id) return npcs[id] end)
local starts = {}
rawset(Npcs, 'runTasks', function(_, _, plan, opts)
    -- (The NPC's first step, resolved as its game would be handed it.)
    local p = opts.resolve(plan.steps[1])
    starts[#starts + 1] = { who = 'npc', at = GetGameTimer(), step = plan.steps[1].t, p = p }
    return true
end)
rawset(Actors, 'runTasks', function(_, ent, plan)
    starts[#starts + 1] = { who = 'car', at = GetGameTimer(), step = plan.steps[1].t, ent = ent }
    return #starts
end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local at = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }
local function world(withCar)
    local w = {
        { id = 'npc1', kind = 'npc', layer = 'run', label = 'Guard', def = { model = 's_m_m_security_01', coords = at,
          conditions = { canMove = true }, tasks = { list = { { k = 'a', t = 'warpIn', car = 'car1' }, { k = 'b', t = 'wait', sec = 6 } }, after = 'stop' } } },
    }
    if withCar then
        w[#w + 1] = { id = 'car1', kind = 'vehicle', layer = 'run', label = 'Dominator', def = { model = 'dominator', coords = at,
            tasks = { list = { { k = 'c', t = 'wait', sec = 60 } }, after = 'stop' } } }
    end
    return w
end
local function doc(nodes, links, w)
    return { format = 2, name = 'Together', description = '', vars = {}, comments = {}, world = w, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function tick(k) for _ = 1, k or 10 do HarnessTick(50) end end
local function start(key, d)
    local okA, probs = Director.activate(key, d, { rev = 1 })
    if not okA then
        local t = {}
        for _, p in ipairs(type(probs) == 'table' and probs or { { message = tostring(probs) } }) do
            if p.severity ~= 'warning' then t[#t + 1] = tostring(p.message) end
        end
        error({ msg = 'not switched on: ' .. table.concat(t, ' | ') })
    end
    local run, why = Director.startRun(Director.active[key], 1, nil, nil)
    if not run then error({ msg = 'no run: ' .. tostring(why) }) end
    return run
end
local function countOf(run, node, pin)
    local c = 0
    for i = 1, run.trace.n do
        local e = run.trace[i]
        if e and e.node == node and e.pin == pin and e.kind ~= 'enter' then c = c + 1 end
    end
    return c
end
local function said(run, text)
    for i = 1, run.trace.n do
        local e = run.trace[i]
        if e and type(e.text) == 'string' and e.text:find(text, 1, true) then return true end
    end
    return false
end
local function reset() cars, nextCar, npcs, nextNpc, starts = {}, 0, {}, 0, {} end

RegisterTestModule({
    category = 'Start Tasks together', order = 1,
    tests = {
        { name = 'Spawn NPC and Spawn Car both wired in: started once, together, once the car is made; Sit In finds the car', fn = function()
            reset()
            local t0 = GetGameTimer()
            local run = start('st_a', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                            n('sc', 'vehicle.spawn', { cars = { 'car1' }, tasks = false }),
                                            n('st', 'tasks.start', { things = { 'npc1', 'car1' } }), n('w', 'scenario.succeed') },
                { l('a', 's', 'out', 'sn'), l('b', 's', 'out', 'sc'), l('c', 'sn', 'out', 'st'), l('d', 'sc', 'out', 'st'), l('e', 'st', 'out', 'w') },
                world(true)))
            tick(4)
            assertEqual(#starts, 0, 'nothing started while the car is still being made')
            tick(40)
            local npcStarts, carStarts = 0, 0
            local npcStart
            for _, s in ipairs(starts) do
                if s.who == 'npc' then npcStarts = npcStarts + 1; npcStart = s else carStarts = carStarts + 1 end
            end
            assertEqual(npcStarts, 1, 'the NPC\'s tasks started once')
            assertEqual(carStarts, 1, 'the car\'s tasks started once')
            assertTrue(npcStart and npcStart.at - t0 >= CAR_TAKES_MS, 'after the car was made')
            assertTrue(npcStart and npcStart.step == 'warpIn' and type(npcStart.p) == 'table' and npcStart.p.carNet == 10901,
                'Sit In handed the car (its netId)')
            assertEqual(countOf(run, 'st', 'out'), 1, 'Started once')
            Director.deactivate('st_a', 'switched off')
        end },
        { name = 'all made before it: started at once, as before', fn = function()
            reset()
            start('st_b', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                n('sc', 'vehicle.spawn', { cars = { 'car1' }, tasks = false }),
                                n('st', 'tasks.start', { things = { 'npc1', 'car1' } }), n('w', 'scenario.succeed') },
                { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'sc'), l('c', 'sc', 'out', 'st'), l('e', 'st', 'out', 'w') },
                world(true)))
            tick(30)
            assertEqual(#starts, 2, 'both started')
            assertTrue(starts[1].at == starts[2].at, 'in the same moment')
            Director.deactivate('st_b', 'switched off')
        end },
        { name = 'one never made: the rest start when the wait runs out, and it is said', fn = function()
            reset()
            local t0 = GetGameTimer()
            local run = start('st_c', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                            n('st', 'tasks.start', { things = { 'npc1', 'car1' } }), n('w', 'scenario.succeed'),
                                            n('sc', 'vehicle.spawn', { cars = { 'car1' }, tasks = false }) },
                { l('a', 's', 'out', 'sn'), l('c', 'sn', 'out', 'st'), l('e', 'st', 'out', 'w') },
                world(true)))
            tick(20)
            assertEqual(#starts, 0, 'waiting for the car')
            for _ = 1, 31 do tick(20) end
            assertEqual(#starts, 1, 'the NPC started without it')
            assertTrue(starts[1].at - t0 >= 30000, 'after 30 s')
            assertTrue(said(run, 'started without: car1'), 'and said')
            Director.deactivate('st_c', 'switched off')
        end },
    },
})
