-- Trailers (a car's Tows, a take's tow: server/director/takes.lua towOf, nodes_world.lua Spawn Car, nodes_tasks.lua
-- Play Take and towTracks), against the real Director under the dev harness. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua tow_module.lua

-- ---- what the cards reach, faked: cars made (entity = 900 + id), actors' lists and trailers kept ----
local cars, made = {}, {}
local nextCar = 0
rawset(Vehicles, 'spawnTempFor', function(model, at)
    nextCar = nextCar + 1
    cars[nextCar] = { model = model, at = at }
    made[#made + 1] = model
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
local towSet, lists = {}, {}
rawset(Actors, 'setTow', function(_, ent, trailer) towSet[#towSet + 1] = { ent = ent, trailer = trailer } return 1 end)
rawset(Actors, 'runTasks', function(_, ent, plan, opts)
    local first = plan.steps[1]
    local p = opts.resolve(first)
    lists[#lists + 1] = { ent = ent, t = first.t, p = p, onEnd = opts.onEnd }
    return #lists
end)
-- Takes as the database would give them: the truck's 20 s, the trailer's own track starting at its placed spot.
local TAKES = {
    [11] = { id = 11, lengthMs = 20000, start = { x = 10.0, y = 0.0, z = 0.0, heading = 90.0 } },
    [12] = { id = 12, lengthMs = 20000, start = { x = 30.0, y = 5.0, z = 0.0, heading = 0.0 } },
}
rawset(DirectorTakes, 'get', function(id) return TAKES[math.tointeger(tonumber(id))] end)
rawset(DirectorTakes, 'load', function(id) return TAKES[math.tointeger(tonumber(id))] end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local at = function(x) return { x = x, y = 0.0, z = 0.0, heading = 0.0 } end
local function car(id, model, x, extra)
    local d = { model = model, coords = at(x) }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { id = id, kind = 'vehicle', layer = 'run', label = id, def = d }
end
local TAKE_TOW = { tracks = { trailer = 12 }, events = { { t = 4200, w = 'trailer', on = true }, { t = 900, w = 'gone', on = true },
                                                          { t = 15000, w = 'trailer', on = false } } }
local function doc(nodes, links, world)
    return { format = 2, name = 'Tow', description = '', vars = {}, comments = {}, world = world, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function tick(k) for _ = 1, k or 10 do HarnessTick(50) end end
local function start(key, d)
    local ok, probs = Director.activate(key, d, { rev = 1 })
    if not ok then
        local t = {}
        for _, p in ipairs(type(probs) == 'table' and probs or { { message = tostring(probs) } }) do
            if p.severity ~= 'warning' then t[#t + 1] = tostring(p.message) end
        end
        error({ msg = 'not switched on: ' .. table.concat(t, ' | ') })
    end
    local run, why = Director.startRun(Director.active[key], 1, nil, nil)
    if not run then error({ msg = 'no run: ' .. tostring(why) }) end
    tick()
    return run
end

RegisterTestModule({
    category = 'Trailers', order = 1,
    tests = {
        { name = 'a take\'s tow, read from its car: its tracks, its moments in order, none for a trailer it has no track of', fn = function()
            local g = { world = { truck = car('truck', 'phantom', 0, { takes = { { id = 11, tow = TAKE_TOW } } }) } }
            local tow = DirectorTakes.towOf(g, 11)
            assertNotNil(tow, 'read')
            ---@cast tow -nil
            assertEqual(tow.tracks.trailer, 12, 'the trailer\'s own track')
            assertEqual(#tow.events, 2, 'the moment for a trailer with no track left out')
            assertTrue(tow.events[1].t == 4200 and tow.events[1].on and tow.events[2].t == 15000 and not tow.events[2].on, 'in order')
            assertNil(DirectorTakes.towOf(g, 99), 'another take: none')
        end },
        { name = 'Spawn Car with Tows: the trailer made too, and hitched by the truck\'s game', fn = function()
            made, towSet, cars, nextCar = {}, {}, {}, 0
            start('tow_a', doc({ n('s', 'scenario.started'), n('c', 'vehicle.spawn', { cars = { 'truck' } }), n('w', 'scenario.succeed') },
                               { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'w') },
                               { car('truck', 'phantom', 0, { tow = 'trailer' }), car('trailer', 'trailers', -8) }))
            assertEqual(#made, 2, 'both made: ' .. table.concat(made, ','))
            assertEqual(made[2], 'trailers', 'the trailer after its truck')
            assertEqual(#towSet, 1, 'one hitch asked for')
            assertTrue(towSet[1].ent == 901 and towSet[1].trailer == 902, 'the truck, its trailer')
            Director.deactivate('tow_a', 'switched off')
        end },
        { name = 'the trailer on the same card\'s list too: made once, not said to be made already', fn = function()
            made, towSet, cars, nextCar = {}, {}, {}, 0
            local run = start('tow_b', doc({ n('s', 'scenario.started'), n('c', 'vehicle.spawn', { cars = { 'truck', 'trailer' } }), n('w', 'scenario.succeed') },
                                           { l('a', 's', 'out', 'c'), l('b', 'c', 'out', 'w') },
                                           { car('truck', 'phantom', 0, { tow = 'trailer' }), car('trailer', 'trailers', -8) }))
            assertEqual(#made, 2, 'two made, not three')
            local said = false
            for i = 1, run.trace.n do
                local e = run.trace[i]
                if e and type(e.text) == 'string' and e.text:find('already made', 1, true) then said = true end
            end
            assertFalse(said, 'nothing said about made already')
            Director.deactivate('tow_b', 'switched off')
        end },
        { name = 'Play Take with a trailer: made where its track starts, played on its own track from the same moment and game, hitched when it was', fn = function()
            made, towSet, lists, cars, nextCar = {}, {}, {}, {}, 0
            start('tow_c', doc({ n('s', 'scenario.started'), n('p', 'vehicle.playTake', { car = 'truck', take = 11, riders = false }), n('w', 'scenario.succeed') },
                               { l('a', 's', 'out', 'p'), l('b', 'p', 'done', 'w') },
                               { car('truck', 'phantom', 0, { takes = { { id = 11, tow = TAKE_TOW } } }), car('trailer', 'trailers', -8) }))
            assertEqual(#made, 2, 'the truck and its trailer made')
            local trailerCar = cars[2]
            assertTrue(trailerCar and trailerCar.at.x == 30.0 and trailerCar.at.y == 5.0, 'the trailer where its own track starts')
            assertTrue(#towSet == 1 and towSet[1].trailer == nil, 'the truck\'s Tows let go of: the take hitches from now')
            local truck, trailer
            for _, x in ipairs(lists) do
                if x.ent == 901 then truck = x elseif x.ent == 902 then trailer = x end
            end
            assertNotNil(truck, 'the truck plays its take')
            assertNotNil(trailer, 'the trailer plays its own')
            assertEqual(trailer.p.take, 12, 'its own track')
            assertTrue(trailer.p.startAt == truck.p.startAt and trailer.p.pin == truck.p.pin, 'from the same moment, on the same game')
            local tow = truck.p.tow
            assertTrue(type(tow) == 'table' and #tow == 2, 'the truck has its hitch moments')
            assertTrue(tow[1].t == 4200 and tow[1].on and tow[1].net == 902 + 10000, 'hitched at 4.2 s, by the trailer\'s netId')
            assertTrue(tow[2].t == 15000 and not tow[2].on, 'let go at 15 s')
            Director.deactivate('tow_c', 'switched off')
        end },
        { name = 'Check: Tows naming no car is an error; a take\'s trailer no longer placed, a warning', fn = function()
            local _, probs = DirectorGraph.check(doc({ n('s', 'scenario.started'), n('w', 'scenario.succeed') }, { l('a', 's', 'out', 'w') },
                { car('truck', 'phantom', 0, { tow = 'nope', takes = { { id = 11, label = 'Run', tow = { tracks = { gone = 12 }, events = {} } } } }) }))
            local err, warn = false, false
            for _, p in ipairs(probs or {}) do
                if p.severity == 'error' and tostring(p.message):find('tows "nope"', 1, true) then err = true end
                if p.severity == 'warning' and tostring(p.message):find('hitched "gone"', 1, true) then warn = true end
            end
            assertTrue(err, 'Tows: said')
            assertTrue(warn, 'the take\'s trailer: said')
        end },
    },
})
