-- NPC Attacks at a director entity (server/director/nodes_world.lua npc.hostile): another NPC by its netId (the first
-- of its group still alive), a car by its netId, a spot where it is; Check's refusals (a route, the NPC itself, none
-- picked); and a card saved as "a car or a prop" read as a director entity. Against the real Director under the dev
-- harness. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua npcattacks_module.lua

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
local npcs, nextNpc = {}, 0
rawset(Npcs, 'spawn', function()
    nextNpc = nextNpc + 1
    npcs[nextNpc] = { npcId = nextNpc, netId = 5000 + nextNpc, alive = true, coords = { x = 0.0, y = 0.0, z = 0.0 } }
    return nextNpc, 5000 + nextNpc
end)
rawset(Npcs, 'get', function(id) return npcs[id] end)
local patches = {}
rawset(Npcs, 'setState', function(_, id, patch) patches[#patches + 1] = { id = id, patch = patch } return true end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local at = function(x) return { x = x, y = 0.0, z = 0.0, heading = 0.0 } end
local function npc(id, x) return { id = id, kind = 'npc', layer = 'run', label = id, def = { model = 's_m_m_security_01', coords = at(x) } } end
local WORLD = {
    npc('guard', 0), npc('victim', 5),
    { id = 'car1', kind = 'vehicle', layer = 'run', label = 'car1', def = { model = 'dominator', coords = at(10) } },
    { id = 'spot1', kind = 'spot', layer = 'run', label = 'spot1', def = { coords = at(20) } },
    { id = 'route1', kind = 'route', layer = 'run', label = 'route1', def = { points = { at(0), at(5) } } },
}
local function doc(nodes, links)
    return { format = 2, name = 'Attacks', description = '', vars = {}, comments = {}, world = WORLD, nodes = nodes, links = links,
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props, v) return { id = id, type = t, v = v or 1, x = 0, y = 0, props = props or {} } end
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

--- A run: the guard (and the victim and the car) made, then NPC Attacks at `thing`. Answers the guard's patch.
local function attackRun(key, thing, extra)
    cars, nextCar, npcs, nextNpc, patches = {}, 0, {}, 0, {}
    local props = { npc = 'guard', target = 'a director entity', thing = thing }
    for k, v in pairs(extra or {}) do props[k] = v end
    start(key, doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'guard', 'victim' }, tasks = false }),
                     n('sc', 'vehicle.spawn', { cars = { 'car1' } }), n('h', 'npc.hostile', props, 2), n('w', 'scenario.succeed') },
                   { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'sc'), l('c', 'sc', 'out', 'h'), l('d', 'h', 'out', 'w') }))
    Director.deactivate(key, 'switched off')
    for _, p in ipairs(patches) do if npcs[p.id] and npcs[p.id].netId == 5001 then return p.patch end end
    return patches[1] and patches[1].patch
end

local function problems(props, v)
    local _, probs = DirectorGraph.check(doc({ n('s', 'scenario.started'), n('h', 'npc.hostile', props, v or 2), n('w', 'scenario.succeed') },
                                             { l('a', 's', 'out', 'h'), l('b', 'h', 'out', 'w') }))
    local errs = {}
    for _, p in ipairs(probs or {}) do if p.severity == 'error' then errs[#errs + 1] = tostring(p.message) end end
    return table.concat(errs, ' | ')
end

RegisterTestModule({
    category = 'NPC Attacks: a director entity', order = 1,
    tests = {
        { name = 'another NPC: attacked by its netId', fn = function()
            local p = attackRun('na_npc', 'victim')
            assertNotNil(p, 'the guard was told')
            assertTrue(type(p.attack) == 'table' and p.attack.net == 5002, 'the victim\'s netId: ' .. tostring(p.attack and p.attack.net))
            assertEqual(p.hostileTo, false, 'no players')
        end },
        { name = 'another NPC that is dead: nobody is told to attack', fn = function()
            cars, nextCar, npcs, nextNpc, patches = {}, 0, {}, 0, {}
            local realGet = Npcs.get
            rawset(Npcs, 'get', function(id) local r = npcs[id] if r and r.netId == 5002 then r.alive = false end return r end)
            local p = attackRun('na_dead', 'victim')
            Npcs.get = realGet
            assertNil(p, 'nobody was told to attack')
        end },
        { name = 'a car: by its netId', fn = function()
            local p = attackRun('na_car', 'car1')
            assertTrue(p and type(p.attack) == 'table' and p.attack.net == 901 + 10000, 'the car\'s netId')
        end },
        { name = 'a spot: where it is', fn = function()
            local p = attackRun('na_spot', 'spot1')
            assertTrue(p and type(p.attack) == 'table' and p.attack.at and p.attack.at.x == 20.0, 'the spot\'s place')
        end },
        { name = 'Check: another NPC, a car or a spot is fine', fn = function()
            for _, thing in ipairs({ 'victim', 'car1', 'spot1' }) do
                assertEqual(problems({ npc = 'guard', target = 'a director entity', thing = thing }), '', thing)
            end
        end },
        { name = 'Check: a route, the NPC itself, or none picked: refused, said', fn = function()
            assertTrue(problems({ npc = 'guard', target = 'a director entity', thing = 'route1' }):find('is a route', 1, true) ~= nil, 'a route')
            assertTrue(problems({ npc = 'guard', target = 'a director entity', thing = 'guard' }):find('cannot attack itself', 1, true) ~= nil, 'itself')
            assertTrue(problems({ npc = 'guard', target = 'a director entity' }):find('Pick the director entity', 1, true) ~= nil, 'none')
            assertEqual(problems({ npc = 'guard', target = 'the run\'s players' }), '', 'players: no entity needed')
        end },
        { name = 'how it fights: Shoot At\'s defaults when left alone, the card\'s when set', fn = function()
            local p = attackRun('na_style0', 'victim')
            local s = p and p.style
            assertTrue(type(s) == 'table' and s.accuracy == 30 and s.rate == 40 and s.pattern == 'full auto' and s.skill == 'a pro',
                'the defaults: ' .. tostring(s and s.accuracy) .. ' ' .. tostring(s and s.rate) .. ' ' .. tostring(s and s.pattern) .. ' ' .. tostring(s and s.skill))
            p = attackRun('na_style1', 'victim', { accuracy = 85, rate = 70, pattern = 'bursts', skill = 'a killer' })
            s = p and p.style
            assertTrue(type(s) == 'table' and s.accuracy == 85 and s.rate == 70 and s.pattern == 'bursts' and s.skill == 'a killer', 'the card\'s own')
        end },
        { name = 'calmed down (Attacks off): its style goes', fn = function()
            local p = attackRun('na_calm', 'victim', { hostile = false })
            assertNotNil(p, 'told')
            assertEqual(p.style, false, 'style false')
        end },
        { name = 'the card\'s fight fields are Shoot At\'s own, shown only while it attacks', fn = function()
            local def = DirectorNodes.get('npc.hostile') --[[@as table]]
            local byKey = {}
            for _, f in ipairs(def.props) do byKey[f.key] = f end
            for _, f in ipairs(DirectorSteps.SHOOTING) do
                local c = byKey[f.key]
                assertNotNil(c, f.key)
                assertTrue(c.label == f.label and c.default == f.default and c.min == f.min and c.max == f.max, f.key .. ': as Shoot At\'s')
                assertTrue(type(c.when) == 'table' and c.when.key == 'hostile' and c.when.is == true, f.key .. ': only while it attacks')
                assertNil(f.when, f.key .. ': Shoot At\'s own has no when')
            end
        end },
        { name = 'saved as "a car or a prop" (version 1): read as a director entity', fn = function()
            local d = DirectorDoc.load(doc({ n('h', 'npc.hostile', { npc = 'guard', target = 'a car or a prop', thing = 'car1' }, 1) }, {})) --[[@as table]]
            assertEqual(d.nodes[1].props.target, 'a director entity', 'its target')
            assertEqual(d.nodes[1].v, DirectorNodes.get('npc.hostile').v, 'its version: the card\'s now')
            assertEqual(d.nodes[1].props.thing, 'car1', 'its thing kept')
            assertEqual(type(d.nodes[1].props.npc) == 'table' and d.nodes[1].props.npc[1], 'guard', 'its NPC kept, in a list')
        end },
    },
})
