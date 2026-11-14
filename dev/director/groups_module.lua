-- Several placed things and named groups on one card (server/director/nodes.lua DirectorNodes.things): a group is every
-- placed thing of the card's kind whose Group it is. Old cards (one thing) upgraded; Check, the uses and the runs of
-- All Killed, NPC Killed, NPC Hurt and Car Entered with several. Against the real Director under the dev harness. Run from
-- whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua groups_module.lua
local R = DirectorRuntime

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
local blips = {}
rawset(Blips, 'show', function(_, _, id) blips[#blips + 1] = id return true end)
rawset(Blips, 'remove', function() end)
local removed = {}
local realRemoveMade = DirectorNodes.removeMade
rawset(DirectorNodes, 'removeMade', function(ctx, wid, h) removed[#removed + 1] = wid return realRemoveMade(ctx, wid, h) end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local at = function(x) return { x = x, y = 0.0, z = 0.0, heading = 0.0 } end
local function npc(id, x, group) return { id = id, kind = 'npc', layer = 'run', label = id, def = { model = 's_m_m_security_01', coords = at(x), group = group } } end
local function car(id, x) return { id = id, kind = 'vehicle', layer = 'run', label = id, def = { model = 'dominator', coords = at(x) } } end
local boss = npc('boss', 8, 'gate')
boss.layer = 'standing'
local WORLD = {
    npc('g1', 0, 'yard'), npc('g2', 2, ' yard '), npc('g3', 4, 'gate'), boss,
    { id = 'crate', kind = 'prop', layer = 'run', label = 'crate', def = { model = 'prop_box_wood02a', coords = at(6), group = 'yard' } },
    { id = 'sign', kind = 'prop', layer = 'standing', label = 'sign', def = { model = 'prop_sign_road_01a', coords = at(7), group = 'yard' } },
    car('car1', 10), car('car2', 14),
    { id = 'spot1', kind = 'spot', layer = 'run', label = 'spot1', def = { coords = at(20) } },
    { id = 'spot2', kind = 'spot', layer = 'run', label = 'spot2', def = { coords = at(24) } },
}
local function doc(nodes, links)
    return { format = 2, name = 'Groups', description = '', vars = {}, comments = {}, world = WORLD, nodes = nodes, links = links or {},
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props, v) return { id = id, type = t, v = v or 2, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function tick(k) for _ = 1, k or 10 do HarnessTick(50) end end

local function errors(d)
    local _, probs = DirectorGraph.check(d)
    local errs = {}
    for _, p in ipairs(probs or {}) do if p.severity == 'error' then errs[#errs + 1] = tostring(p.message) end end
    return table.concat(errs, ' | ')
end

--- A run of `nodes` (Spawn NPC of all three guards, Spawn Car of both cars, then the card under test wired to Succeed:
--- an event card listening from the start, an action card wired on after the cars, by `opts.pin` or 'out').
local function start(key, card, opts)
    cars, nextCar, npcs, nextNpc, patches, blips, removed = {}, 0, {}, 0, {}, {}, {}
    local links = { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'sc'), l('c', card.id, (opts and opts.pin) or 'out', 'w') }
    if not DirectorNodes.get(card.type).event then links[#links + 1] = l('d', 'sc', 'out', card.id) end
    local d = doc({ n('s', 'scenario.started', {}, 1), n('sn', 'npc.spawn', { npcs = { 'g1', 'g2', 'g3' }, tasks = false, together = false }, 1),
                    n('sc', 'vehicle.spawn', { cars = { 'car1', 'car2' } }, 1), card, n('w', 'scenario.succeed', {}, 1) }, links)
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

--- The NPC made for placed thing `wid` in this run.
local function npcOf(run, wid)
    local h = Director.handleOf(run, wid)
    return type(h) == 'table' and (h.npcId or (type(h.group) == 'table' and h.group[1])) or nil
end

local function kill(run, wid)
    local id = npcOf(run, wid)
    npcs[id].alive = false
    npcs[id].killer = 1
    R.emit('npc.killed', { npcId = id, killer = 1 })
    R.emit('npc.down', { npcId = id, killer = 1 })
    tick(2)
end

RegisterTestModule({
    category = 'Several things and groups on a card', order = 1,
    tests = {
        { name = 'a group: its members of the card\'s kind, trimmed, by id', fn = function()
            assertEqual(table.concat(DirectorNodes.expandThings(WORLD, { 'group:yard' }, 'npc'), ','), 'g1,g2', 'NPCs in yard')
            assertEqual(table.concat(DirectorNodes.expandThings(WORLD, { 'group:yard' }, 'prop'), ','), 'crate,sign', 'props in yard (a standing one too)')
            assertEqual(table.concat(DirectorNodes.expandThings(WORLD, { 'g3', 'group:yard', 'g1' }, 'npc'), ','), 'g3,g1,g2', 'each once, in order')
            assertEqual(table.concat(DirectorNodes.expandThings(WORLD, 'g3', 'npc'), ','), 'g3', 'one id (an older card) reads too')
        end },
        { name = 'an older card (one thing) is brought up to a list', fn = function()
            local d = DirectorDoc.load(doc({ n('k', 'npc.allKilled', { npc = 'g1' }, 1), n('e', 'vehicle.entered', { car = 'car1' }, 1),
                                            n('i', 'item.picked', { item = 'spot' }, 1), n('f', 'fail.npcDies', { npc = 'g3' }, 1) })) --[[@as table]]
            assertEqual(type(d.nodes[1].props.npc), 'table', 'All Killed: a list')
            assertEqual(d.nodes[1].props.npc[1], 'g1', 'its NPC kept')
            assertEqual(d.nodes[1].v, 2, 'its version')
            assertEqual(d.nodes[2].props.car[1], 'car1', 'Car Entered: its car kept')
            assertEqual(d.nodes[3].props.item[1], 'spot', 'Item Picked Up')
            assertEqual(d.nodes[4].props.npc[1], 'g3', 'Fail If an NPC Dies')
        end },
        { name = 'Check: nothing picked, a group nothing is in, a car where NPCs go: said', fn = function()
            local function one(props) return errors(doc({ n('s', 'scenario.started', {}, 1), n('k', 'npc.allKilled', props),
                n('w', 'scenario.succeed', {}, 1) }, { l('a', 'k', 'out', 'w') })) end
            assertTrue(one({ npc = {} }):find('nothing picked', 1, true) ~= nil, 'nothing picked: ' .. one({ npc = {} }))
            assertTrue(one({ npc = { 'group:nobody' } }):find('nothing of its kind is in the group "nobody"', 1, true) ~= nil, 'an empty group')
            assertTrue(one({ npc = { 'car1' } }):find('is a vehicle, not a npc', 1, true) ~= nil, 'a car')
            assertEqual(one({ npc = { 'group:yard', 'g3' } }), '', 'a group and an NPC: fine')
            assertEqual(one({ npc = { 'group:gate' } }), '', 'a group of one')
        end },
        { name = 'a group\'s members are used by the card (uses, references)', fn = function()
            local d = doc({ n('k', 'npc.allKilled', { npc = { 'group:yard' } }) })
            assertEqual(table.concat(DirectorGraph.usesOfWorld(d, 'g2'), ','), 'k', 'g2 is used')
            assertEqual(table.concat(DirectorGraph.usesOfWorld(d, 'g3'), ','), '', 'g3 is not')
            assertEqual(table.concat(DirectorGraph.usesOfWorld(d, 'crate'), ','), '', 'the crate is a prop: not an NPC card\'s')
            local named = {}
            DirectorRefs.each(d, function(r) if r.kind == 'world' then named[#named + 1] = r.id end end)
            table.sort(named)
            assertEqual(table.concat(named, ','), 'g1,g2', 'references: its members')
        end },
        { name = 'All Killed of group yard: not until both are down; the gate guard does not count', fn = function()
            local run = start('gr_all', n('k', 'npc.allKilled', { npc = { 'group:yard' } }))
            kill(run, 'g3')
            assertEqual(run.status, 'running', 'the gate guard down: still going')
            kill(run, 'g1')
            assertEqual(run.status, 'running', 'one of the yard down: still going')
            kill(run, 'g2')
            assertEqual(run.status, 'succeeded', 'both of the yard down')
        end },
        { name = 'NPC Killed of g1 and g3: either one', fn = function()
            local run = start('gr_one', n('k', 'npc.killed', { npc = { 'g1', 'g3' } }))
            kill(run, 'g2')
            assertEqual(run.status, 'running', 'g2 is not one of them')
            kill(run, 'g3')
            assertEqual(run.status, 'succeeded', 'g3 is')
        end },
        { name = 'NPC Hurt of group gate: a hit on that guard', fn = function()
            local run = start('gr_hurt', n('k', 'npc.damaged', { npc = { 'group:gate' } }))
            R.emit('npc.damaged', { npcId = npcOf(run, 'g1'), attacker = 1, amount = 30 })
            tick(2)
            assertEqual(run.status, 'running', 'a yard guard hurt: not it')
            R.emit('npc.damaged', { npcId = npcOf(run, 'g3'), attacker = 1, amount = 30 })
            tick(2)
            assertEqual(run.status, 'succeeded', 'the gate guard hurt')
        end },
        { name = 'every action card that took one thing is brought up to a list', fn = function()
            local cards = { { 'npc.flee', 'npc' }, { 'npc.emote', 'npc' }, { 'npc.walkTo', 'npc' }, { 'npc.follow', 'npc' },
                            { 'npc.me', 'npc' }, { 'prop.show', 'prop' }, { 'prop.hide', 'prop' }, { 'world.remove', 'what' },
                            { 'door.set', 'door' }, { 'item.place', 'item' }, { 'item.take', 'item' }, { 'map.blip', 'at' },
                            { 'map.blipRemove', 'at' }, { 'tasks.stop', 'what' }, { 'npc.hostile', 'npc' } }
            local nodes = {}
            for i, c in ipairs(cards) do nodes[i] = n('c' .. i, c[1], { [c[2]] = 'x' .. i }, 1) end
            local d = DirectorDoc.load(doc(nodes)) --[[@as table]]
            for i, c in ipairs(cards) do
                local v = d.nodes[i].props[c[2]]
                assertTrue(type(v) == 'table' and v[1] == 'x' .. i, c[1] .. ': its one thing, in a list')
                assertEqual(d.nodes[i].v, DirectorNodes.get(c[1]).v, c[1] .. ': its version now')
            end
        end },
        { name = 'NPC Plays Emote on group yard: only the yard guards change', fn = function()
            start('gr_emote', n('k', 'npc.emote', { npc = { 'group:yard' }, emote = '' }))
            local who = {}
            for _, p in ipairs(patches) do if p.patch and p.patch.anim ~= nil then who[#who + 1] = p.id end end
            assertEqual(#who, 2, 'two NPCs told')
        end },
        { name = 'NPC Walks To with group yard and g3: all three sent, spread round the spot', fn = function()
            start('gr_walk', n('k', 'npc.walkTo', { npc = { 'group:yard', 'g3' }, at = 'spot1' }), { pin = 'arrived' })
            local posts = {}
            for _, p in ipairs(patches) do if p.patch and p.patch.post then posts[#posts + 1] = p.patch.post end end
            assertEqual(#posts, 3, 'three posts')
            assertTrue(posts[1].x == 20.0 and posts[2].x ~= 20.0, 'the first on the spot, the next round it')
        end },
        { name = 'Check: a group\'s standing members are passed over, one picked by itself is not', fn = function()
            local function one(t, props) return errors(doc({ n('s', 'scenario.started', {}, 1), n('k', t, props),
                n('w', 'scenario.succeed', {}, 1) }, { l('a', 's', 'out', 'k'), l('b', 'k', 'out', 'w') })) end
            assertEqual(one('npc.emote', { npc = { 'group:gate' }, emote = '' }), '', 'group gate (the boss is standing): fine')
            assertTrue(one('npc.emote', { npc = { 'boss' }, emote = '' }):find('Always present', 1, true) ~= nil, 'the boss picked: said')
            assertTrue(one('prop.hide', { prop = { 'sign' } }):find('Always present', 1, true) ~= nil, 'the sign picked: said')
            assertEqual(one('prop.hide', { prop = { 'group:yard' } }), '', 'group yard (the sign is standing): fine')
        end },
        { name = 'Show Prop of group yard: the crate, never the standing sign', fn = function()
            local props = DirectorNodes.showPropsOf(doc({}), { prop = { 'group:yard' } })
            assertEqual(table.concat(props, ','), 'crate', 'the crate alone')
        end },
        { name = 'Remove of group yard: both yard guards taken away, g3 left', fn = function()
            start('gr_remove', n('k', 'world.remove', { what = { 'group:yard' } }))
            tick(5)
            table.sort(removed)
            assertEqual(table.concat(removed, ','), 'g1,g2', 'g1 and g2')
        end },
        { name = 'Show Blip of two spots: a blip on each', fn = function()
            start('gr_blip', n('k', 'map.blip', { at = { 'spot1', 'spot2' } }))
            assertEqual(#blips, 2, 'two blips')
        end },
        { name = 'Car Entered of both cars: the second one entered', fn = function()
            local run = start('gr_car', n('k', 'vehicle.entered', { car = { 'car1', 'car2' } }))
            local h2 = Director.handleOf(run, 'car2')
            assertNotNil(h2 and h2.vehicleId, 'car2 made')
            ---@cast h2 -nil
            R.emit('vehicle.entered', { source = 1, vehicleId = 99, seat = -1 })
            tick(2)
            assertEqual(run.status, 'running', 'another car: not it')
            R.emit('vehicle.entered', { source = 1, vehicleId = h2.vehicleId, seat = -1 })
            tick(2)
            assertEqual(run.status, 'succeeded', 'car2 entered')
        end },
    },
})
