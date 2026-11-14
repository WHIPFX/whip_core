-- Goal cards as goalCard declares them (nodes_goals.lua: the fields, Out of time and objective every goal has), and the
-- checks they share with their base cards (DirectorSpots.arrived / delivered, DirectorNodes.carLook): Go To and Player
-- Arrives, Deliver the Car and Car Delivered, Steal the Car, Car Destroyed, Survive. Against the real Director:
--   MEMCAP_MB=512 lua54 guard.lua harness.lua goals_module.lua

-- A world of its own: where each player and car stands, who drives, what reads wrecked.
local pos = { [1] = { x = 0.0, y = 0.0, z = 0.0 } }
local cars = {}          -- [vehicleId] = { at, driver, wrecked }
local function carEnt(id) return 900 + id end
rawset(_G, 'GetEntityCoords', function(ent)
    if ent and ent > 900 then local c = cars[ent - 900] return c and c.at or { x = 0.0, y = 0.0, z = 0.0 } end
    return pos[(ent or 0) - 100] or { x = 0.0, y = 0.0, z = 0.0 }
end)
rawset(_G, 'GetPedInVehicleSeat', function(ent, seat)
    local c = ent and cars[ent - 900]
    return (c and seat == -1 and c.driver) or 0
end)
rawset(_G, 'GetVehiclePedIsIn', function() return 0 end)
rawset(Vehicles, 'getDef', function(id) return cars[id] and { plate = 'P' .. id } or nil end)
rawset(Vehicles, 'getEntity', function(id) return cars[id] and carEnt(id) or nil end)
rawset(Vehicles, 'claimUnderWay', function() return false end)
rawset(VehicleDamage, 'isWrecked', function(ent) local c = ent and cars[ent - 900] return c ~= nil and c.wrecked == true end)

-- What the band was told: [text] = true.
local shown = {}
local realObjective = DirectorBand.objective
rawset(DirectorBand, 'objective', function(run, s, text, key)
    shown[#shown + 1] = text
    return realObjective(run, s, text, key)
end)

local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local SPOT = { id = 'here', kind = 'spot', layer = 'run', label = 'Here', def = { coords = { x = 50.0, y = 0.0, z = 0.0, heading = 0.0 } } }
local CAR = { id = 'car1', kind = 'vehicle', layer = 'run', label = 'Car', def = { model = 'dominator', coords = { x = 0.0, y = 0.0, z = 0.0 } } }
local function doc(nodes, links)
    return { format = 2, name = 'Goals', description = '', vars = {}, comments = {}, world = { SPOT, CAR }, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
-- start -> the card under test; each of its outcomes to a card of its own, so which one fired is read back.
local function oneCard(type, props, pins)
    local nodes = { n('s', 'scenario.started'), n('c', type, props), n('win', 'scenario.succeed'), n('lose', 'scenario.fail') }
    local links = { l('a', 's', 'out', 'c') }
    for i, p in ipairs(pins) do links[#links + 1] = l('p' .. i, 'c', p, i == 1 and 'win' or 'lose') end
    return doc(nodes, links)
end
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
local function fired(run, pin)
    for i = 1, run.trace.n do
        local e = run.trace[i]
        if e and e.node == 'c' and e.pin == pin and (e.kind == 'out' or e.kind == 'resume') then return true end
    end
    return false
end
local function keys(def)
    local out = {}
    for _, f in ipairs(def.props) do out[#out + 1] = f.key end
    return table.concat(out, ',')
end
local function reset() pos[1] = { x = 0.0, y = 0.0, z = 0.0 }; cars = {}; shown = {} end

RegisterTestModule({
    category = 'Goal cards on their base cards', order = 1,
    tests = {
        { name = 'goalCard: every goal\'s fields and Out of time, Survive without a time limit', fn = function()
            local go = DirectorNodes.get('goal.goTo') --[[@as table]]
            assertEqual(keys(go), 'text,at,radius,who,mark,seconds', 'Go To\'s fields')
            assertEqual(table.concat(go.outputs, ','), 'done,timeout', 'Go To\'s outcomes')
            assertEqual(go.labels.timeout, 'Out of time', 'Out of time')
            assertEqual(go.category, 'goals', 'a goal')
            assertNotNil(go.pinWhen and go.pinWhen.timeout, 'Out of time only with a time limit')
            local sv = DirectorNodes.get('goal.survive') --[[@as table]]
            assertEqual(keys(sv), 'text,length,at,radius,mark', 'Survive\'s fields')
            assertEqual(table.concat(sv.outputs, ','), 'done,failed', 'Survive\'s outcomes')
            assertEqual(sv.props[#sv.props].label, 'Mark the area on the map', 'its Mark words')
            assertEqual(table.concat(DirectorNodes.get('goal.deliverCar').outputs, ','), 'done,lost,timeout', 'Deliver the Car\'s')
        end },
        { name = 'Goal: Go To: its objective up, Arrived once the player is there', fn = function()
            reset()
            local run = start('g_a', oneCard('goal.goTo', { at = 'here', radius = 5 }, { 'done', 'timeout' }))
            tick(30)
            assertEqual(run.status, 'running', 'waiting while they are away')
            assertEqual(shown[1], 'Go to the marked spot', 'the objective\'s own words')
            pos[1] = { x = 50.0, y = 1.0, z = 0.0 }
            tick(30)
            assertEqual(run.status, 'succeeded', 'Arrived (' .. tostring(run.reason) .. ')')
            assertTrue(fired(run, 'done'), 'out of Arrived')
            Director.deactivate('g_a', 'switched off')
        end },
        { name = 'Goal: Go To with a time limit and words of its own: Out of time', fn = function()
            reset()
            local run = start('g_b', oneCard('goal.goTo', { at = 'here', radius = 5, seconds = 5, text = 'Get to the docks' }, { 'done', 'timeout' }))
            tick(140)
            assertEqual(shown[1], 'Get to the docks', 'its own words')
            assertTrue(fired(run, 'timeout'), 'Out of time')
            assertEqual(run.status, 'failed', 'failed by the Fail wired to it')
            Director.deactivate('g_b', 'switched off')
        end },
        { name = 'Player Arrives: the same check, Entered', fn = function()
            reset()
            local run = start('g_c', oneCard('area.entered', { at = 'here', radius = 5 }, { 'entered' }))
            tick(30)
            assertEqual(run.status, 'running', 'waiting')
            pos[1] = { x = 49.0, y = 0.0, z = 0.0 }
            tick(30)
            assertTrue(fired(run, 'entered'), 'Entered')
            Director.deactivate('g_c', 'switched off')
        end },
        { name = 'Deliver the Car: driven there by the player, Delivered; Car Delivered the same', fn = function()
            for _, t in ipairs({ { 'goal.deliverCar', 'done', 'g_d' }, { 'vehicle.reached', 'reached', 'g_e' } }) do
                reset()
                cars[1] = { at = { x = 0.0, y = 0.0, z = 0.0 } }
                local run = start(t[3], oneCard(t[1], { car = 'car1', at = 'here', radius = 5 }, { t[2], 'lost' }))
                run.world.car1 = { vehicleId = 1 }
                tick(30)
                assertEqual(run.status, 'running', t[1] .. ': waiting')
                cars[1].at = { x = 50.0, y = 0.0, z = 0.0 }
                tick(30)
                assertEqual(run.status, 'running', t[1] .. ': there, but nobody of the run drives it')
                cars[1].driver = GetPlayerPed(1)
                tick(30)
                assertTrue(fired(run, t[2]), t[1] .. ': delivered')
                Director.deactivate(t[3], 'switched off')
            end
        end },
        { name = 'Deliver the Car: wrecked three looks in a row is Car lost; gone is Car lost', fn = function()
            reset()
            cars[1] = { at = { x = 0.0, y = 0.0, z = 0.0 } }
            local run = start('g_f', oneCard('goal.deliverCar', { car = 'car1', at = 'here', radius = 5 }, { 'done', 'lost' }))
            run.world.car1 = { vehicleId = 1 }
            tick(30)
            cars[1].wrecked = true
            tick(30)
            assertEqual(run.status, 'running', 'two looks: not yet')
            tick(30)
            assertTrue(fired(run, 'lost'), 'Car lost')
            Director.deactivate('g_f', 'switched off')
            reset()
            cars[1] = { at = { x = 0.0, y = 0.0, z = 0.0 } }
            run = start('g_g', oneCard('goal.stealCar', { car = 'car1' }, { 'done', 'lost' }))
            run.world.car1 = { vehicleId = 1 }
            tick(30)
            cars[1] = nil
            tick(30)
            assertTrue(fired(run, 'lost'), 'Steal the Car: gone is Car lost')
            Director.deactivate('g_g', 'switched off')
        end },
        { name = 'Steal the Car: in its driver\'s seat, In the car; Car Destroyed hears the wreck', fn = function()
            reset()
            cars[1] = { at = { x = 0.0, y = 0.0, z = 0.0 } }
            local run = start('g_h', oneCard('goal.stealCar', { car = 'car1' }, { 'done', 'lost' }))
            run.world.car1 = { vehicleId = 1 }
            tick(30)
            cars[1].driver = GetPlayerPed(1)
            tick(30)
            assertTrue(fired(run, 'done'), 'In the car')
            Director.deactivate('g_h', 'switched off')
            reset()
            cars[1] = { at = { x = 0.0, y = 0.0, z = 0.0 } }
            run = start('g_i', oneCard('vehicle.destroyed', { car = 'car1' }, { 'destroyed' }))
            run.world.car1 = { vehicleId = 1 }
            tick(30)
            cars[1].wrecked = true
            tick(90)
            assertTrue(fired(run, 'destroyed'), 'Destroyed')
            Director.deactivate('g_i', 'switched off')
        end },
        { name = 'Goal: Survive: its own clock, Survived', fn = function()
            reset()
            local run = start('g_j', oneCard('goal.survive', { length = 5 }, { 'done', 'failed' }))
            tick(30)
            assertEqual(shown[1], 'Survive', 'its words')
            assertEqual(run.status, 'running', 'holding out')
            tick(120)
            assertTrue(fired(run, 'done'), 'Survived')
            Director.deactivate('g_j', 'switched off')
        end },
    },
})
