-- The Director health check's fixes, one test each: reinforcements join their crew (All Killed waits for every wave),
-- NPC Hurt's tally and a rewind, Take Item refused by the pockets, Kill Them All and Car Destroyed before what they
-- watch is made, Test and switch-on shutting each other out, DirectorEffects.give's answer, the login sweep, the run id
-- kept for the next start, a calmed guard. Against the real Director under the dev harness. Run from
-- whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua healthfix_module.lua
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
rawset(Npcs, 'setState', function() return true end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local kvp = {}
rawset(_G, 'GetResourceKvpInt', function(k) return kvp[k] end)
rawset(_G, 'SetResourceKvpInt', function(k, v) kvp[k] = v end)
rawset(Inventory, 'onlyStamped', Inventory.onlyStamped or function(match) return { only = match } end)

local at = function(x) return { x = x, y = 0.0, z = 0.0, heading = 0.0 } end
local function npc(id, x) return { id = id, kind = 'npc', layer = 'run', label = id, def = { model = 's_m_m_security_01', coords = at(x) } } end
local WORLD = {
    npc('g1', 0), npc('g2', 2), npc('g3', 4),
    { id = 'car1', kind = 'vehicle', layer = 'run', label = 'car1', def = { model = 'dominator', coords = at(10) } },
    { id = 'pkg', kind = 'groundItem', layer = 'run', label = 'pkg', def = { item = 'food', amount = 1, coords = at(12) } },
}
local function doc(nodes, links)
    return { format = 2, name = 'Health fixes', description = '', vars = {}, comments = {}, world = WORLD, nodes = nodes, links = links or {},
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end
local function n(id, t, props, v) return { id = id, type = t, v = v or 2, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function tick(k) for _ = 1, k or 10 do HarnessTick(50) end end

local function start(key, d)
    cars, nextCar, npcs, nextNpc = {}, 0, {}, 0
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

local function kill(id)
    npcs[id].alive = false
    R.emit('npc.killed', { npcId = id, killer = 1 })
    R.emit('npc.down', { npcId = id, killer = 1 })
    tick(2)
end

--- Two Spawn NPC cards (the second a wave for `wave2`), then All Killed of `watch`, wired to Succeed.
local function wavesRun(key, wave2, watch)
    return start(key, doc({ n('s', 'scenario.started', {}, 1),
        n('sn1', 'npc.spawn', { npcs = { 'g1', 'g2' }, tasks = false, together = true }, 1),
        n('sn2', 'npc.spawn', { npcs = wave2, tasks = false, together = true }, 1),
        n('k', 'npc.allKilled', { npc = watch }), n('w', 'scenario.succeed', {}, 1) },
        { l('a', 's', 'out', 'sn1'), l('b', 'sn1', 'out', 'sn2'), l('c', 'k', 'out', 'w') }))
end

local function runOf(key)
    for _, r in ipairs(R.list()) do if r.scenarioId == key then return r end end
    return nil
end

RegisterTestModule({
    category = 'Director health check fixes', order = 1,
    tests = {
        { name = 'reinforcements: a second wave of the same crew, so All Killed waits for both waves', fn = function()
            local run = wavesRun('hf_waves2', { 'g1', 'g2' }, { 'g1' })
            assertEqual(nextNpc, 4, 'four made')
            kill(3) kill(4)
            assertEqual(run.status, 'running', 'the second wave down: the first is still up')
            kill(1) kill(2)
            assertEqual(run.status, 'succeeded', 'every wave down')
            Director.deactivate('hf_waves2', 'done')
        end },
        { name = 'reinforcements: one NPC for a crew\'s thing joins the crew, so All Killed of the other waits for it', fn = function()
            local run = wavesRun('hf_waves', { 'g1' }, { 'g2' })
            assertEqual(nextNpc, 3, 'three made (g1, g2, then g1 again)')
            kill(1) kill(2)
            assertEqual(run.status, 'running', 'the first wave down: the second is still up')
            kill(3)
            assertEqual(run.status, 'succeeded', 'every wave down')
            Director.deactivate('hf_waves', 'done')
        end },
        { name = 'reinforcements: a wave for the thing itself counts for it too (its own group)', fn = function()
            local run = wavesRun('hf_wave1', { 'g3', 'g1' }, { 'g1' })
            kill(1) kill(2) kill(3)
            assertEqual(run.status, 'running', 'the second g1 is up')
            kill(4)
            assertEqual(run.status, 'succeeded', 'all down')
            Director.deactivate('hf_wave1', 'done')
        end },
        { name = 'NPC Hurt: the hits add up; a rewind forgets the ones after its step', fn = function()
            local run = start('hf_hurt', doc({ n('s', 'scenario.started', {}, 1), n('sn', 'npc.spawn', { npcs = { 'g1' }, tasks = false }, 1),
                n('k', 'npc.damaged', { npc = { 'g1' }, damage = 50 }), n('w', 'scenario.succeed', {}, 1) },
                { l('a', 's', 'out', 'sn'), l('c', 'k', 'out', 'w') }))
            R.emit('npc.damaged', { npcId = 1, attacker = 1, amount = 30 })
            tick(2)
            assertEqual(run.status, 'running', '30 of 50')
            R.emit('npc.damaged', { npcId = 1, attacker = 1, amount = 30 })
            tick(2)
            assertEqual(run.status, 'succeeded', '60 of 50')
            local s = { hurt = { [1] = { { n = 30, at = 5 }, { n = 30, at = 9 } } } }
            DirectorNodes.get('npc.damaged').rewind(s, 6)
            assertEqual(#s.hurt[1], 1, 'back to step 6: the hit at step 9 is forgotten')
            Director.deactivate('hf_hurt', 'done')
        end },
        { name = 'Take Item: refused by the pockets is Missing; taken is Taken', fn = function()
            local realFind, realTake = Inventory.findAll, Inventory.take
            local answer = { false, 'Paying — wait a moment' }
            local took = {}
            rawset(Inventory, 'findAll', function(_, item)
                local r = runOf('hf_take')
                return { { addr = { kind = 'player', id = 1, sub = 'player', slot = 1 }, amount = 2, item = item,
                           metadata = { fromRun = r and r.id, dworld = 'pkg' } } }
            end)
            rawset(Inventory, 'take', function(_, item, amount, _, only)
                took[#took + 1] = { item = item, amount = amount, only = only }
                return table.unpack(answer)
            end)
            local d = doc({ n('s', 'scenario.started', {}, 1), n('t', 'item.take', { item = { 'pkg' } }),
                            n('w', 'scenario.succeed', {}, 1), n('f', 'scenario.fail', {}, 1) },
                          { l('a', 's', 'out', 't'), l('b', 't', 'taken', 'w'), l('c', 't', 'missing', 'f') })
            local run = start('hf_take', d)
            tick(4)
            assertEqual(run.status, 'failed', 'refused: Missing')
            assertEqual(took[1] and took[1].amount, 2, 'all of the spot\'s, through Inventory.take')
            assertEqual(took[1] and took[1].only and took[1].only.only.dworld, 'pkg', 'only that spot\'s stacks')
            Director.deactivate('hf_take', 'done')
            answer = { true }
            run = start('hf_take', d)
            tick(4)
            assertEqual(run.status, 'succeeded', 'taken')
            Director.deactivate('hf_take', 'done')
            Inventory.findAll, Inventory.take = realFind, realTake
        end },
        { name = 'Kill Them All before its NPCs are made: it waits, never "all down"', fn = function()
            local run = start('hf_kill', doc({ n('s', 'scenario.started', {}, 1), n('k', 'goal.killAll', { npc = { 'g3' } }),
                n('w', 'scenario.succeed', {}, 1) }, { l('a', 's', 'out', 'k'), l('b', 'k', 'done', 'w') }))
            tick(60)
            assertEqual(run.status, 'running', 'nothing made: still waiting')
            Director.deactivate('hf_kill', 'done')
        end },
        { name = 'Car Destroyed before its car is made: it waits; made and gone: destroyed', fn = function()
            local function hold() return n('wt', 'flow.wait', { seconds = 600 }, 1), n('w', 'scenario.succeed', {}, 1) end
            local h1, h2 = hold()
            local run = start('hf_car', doc({ n('s', 'scenario.started', {}, 1), n('x', 'vehicle.destroyed', { car = { 'car1' } }),
                n('f', 'scenario.fail', {}, 1), h1, h2 },
                { l('a', 's', 'out', 'x'), l('b', 'x', 'destroyed', 'f'), l('h', 's', 'out', 'wt'), l('i', 'wt', 'done', 'w') }))
            tick(60)
            assertEqual(run.status, 'running', 'not made: nothing to lose')
            Director.deactivate('hf_car', 'done')
            h1, h2 = hold()
            run = start('hf_car', doc({ n('s', 'scenario.started', {}, 1), n('sc', 'vehicle.spawn', { cars = { 'car1' } }, 1),
                n('x', 'vehicle.destroyed', { car = { 'car1' } }), n('f', 'scenario.fail', {}, 1), h1, h2 },
                { l('a', 's', 'out', 'sc'), l('c', 'sc', 'out', 'x'), l('b', 'x', 'destroyed', 'f'), l('h', 's', 'out', 'wt'),
                  l('i', 'wt', 'done', 'w') }))
            tick(30)
            assertEqual(run.status, 'running', 'made and there')
            cars = {}
            tick(30)
            assertEqual(run.status, 'failed', 'gone: destroyed')
            Director.deactivate('hf_car', 'done')
        end },
        { name = 'Test and switch-on shut each other out', fn = function()
            local d = doc({ n('s', 'scenario.started', {}, 1), n('wt', 'flow.wait', { seconds = 600 }, 1), n('w', 'scenario.succeed', {}, 1) },
                          { l('a', 's', 'out', 'wt'), l('b', 'wt', 'done', 'w') })
            local sc = Director.build('hf_test', d, { prefix = 'test' })
            local run = Director.startRun(sc, 1, { source = 1 }, { test = true })
            assertNotNil(run, 'a test run')
            ---@cast run table
            assertTrue(Director.isTesting('hf_test'), 'it is being tested')
            local ok, why = Director.activate('hf_test', d, { rev = 1 })
            assertFalse(ok, 'not switched on while tested')
            assertTrue(tostring(why):find('testing', 1, true) ~= nil, 'said why: ' .. tostring(why))
            R.abort(run.id, 'stop')
            tick(4)
            assertFalse(Director.isTesting('hf_test'), 'the test is over')
            ok = Director.activate('hf_test', d, { rev = 1 })
            assertTrue(ok, 'switched on now')
            Director.deactivate('hf_test', 'done')
        end },
        { name = 'DirectorEffects.give: given is no "why"; nothing given says why', fn = function()
            local run = { id = 77, test = false, status = 'running', scenarioId = 'x', rev = 1, graph = { nodes = {} } }
            local gave, why = DirectorEffects.give(run, 'n', 1, 'food', 2)
            assertEqual(gave, 2, 'two given')
            assertNil(why, 'no reason on success')
            local realGive = Inventory.give
            rawset(Inventory, 'give', function() return nil, 'full' end)
            gave, why = DirectorEffects.give(run, 'n', 1, 'food', 2)
            Inventory.give = realGive
            assertEqual(gave, 0, 'none given')
            assertEqual(why, 'full', 'and why')
        end },
        { name = 'the login sweep takes back a stamp whose run is over (it was a nil call)', fn = function()
            local realCopy, realFind, realTakeAt = Inventory.pocketsCopy, Inventory.findAll, Stores.takeAt
            rawset(Inventory, 'pocketsCopy', function() return { player = { { item = 'food', amount = 1, metadata = { director = 999 } } } } end)
            rawset(Inventory, 'findAll', function() return { { addr = { kind = 'player', id = 1, sub = 'player', slot = 1 }, amount = 1, metadata = { director = 999 } } } end)
            local taken = 0
            rawset(Stores, 'takeAt', function() taken = taken + 1 return true end)
            local names = DirectorEffects.takeBackStale(1)
            Inventory.pocketsCopy, Inventory.findAll, Stores.takeAt = realCopy, realFind, realTakeAt
            assertEqual(taken, 1, 'taken')
            assertEqual(names[1], 'food', 'named')
        end },
        { name = 'the run id handed out is kept for the next start of whip', fn = function()
            local run = start('hf_kvp', doc({ n('s', 'scenario.started', {}, 1), n('wt', 'flow.wait', { seconds = 600 }, 1),
                                              n('w', 'scenario.succeed', {}, 1) }, { l('a', 's', 'out', 'wt'), l('b', 'wt', 'done', 'w') }))
            assertEqual(kvp['director:lastRunId'], run.id, 'kept')
            Director.deactivate('hf_kvp', 'done')
        end },
        { name = 'a calmed guard can be set on the players again, its vision calm', fn = function()
            local calmed = {}
            local realCalm = Vision.calm
            rawset(Vision, 'calm', function(w) calmed[#calmed + 1] = w return true end)
            local run = { alertedNpcs = { [5] = true, [6] = true }, guards = { [5] = { watch = 'w5' } } }
            DirectorGuards.calmed(run, { 5 })
            Vision.calm = realCalm
            assertNil(run.alertedNpcs[5], 'no longer alerted')
            assertTrue(run.alertedNpcs[6], 'another stays')
            assertEqual(calmed[1], 'w5', 'its vision calm')
        end },
        { name = 'Bring Item To: looked for each second, one take at a time; a missed take looks again', fn = function()
            local realCarried, realTake = Director.carried, Inventory.take
            rawset(Director, 'carried', function(_, item) return item == 'food' and 1 or 0 end)
            local takes, answers = 0, { false, true }
            rawset(Inventory, 'take', function()
                takes = takes + 1
                Wait(2500)
                return answers[takes]
            end)
            local run = start('hf_bring', doc({ n('s', 'scenario.started', {}, 1),
                n('b', 'goal.bring', { item = 'food', count = 1, at = 'g1', radius = 3, mark = false }, 1), n('w', 'scenario.succeed', {}, 1) },
                { l('a', 's', 'out', 'b'), l('c', 'b', 'done', 'w') }))
            tick(30)
            assertEqual(takes, 1, 'the first look: a take')
            tick(30)
            assertEqual(takes, 1, 'no second take while the first is out')
            assertEqual(run.status, 'running', 'still running')
            tick(30)
            assertEqual(takes, 2, 'the first missed: looked again, a second take')
            tick(40)
            assertEqual(run.status, 'succeeded', 'the second took it: Brought')
            Director.deactivate('hf_bring', 'done')
            Director.carried, Inventory.take = realCarried, realTake
        end },
        { name = 'Fire Weapon: its game\'s answer goes on at once, once; no answer is No answer', fn = function()
            local realSlot, realWire, realSend = DirectorTasks.propSlot, PropSets.wireOf, TriggerClientEvent
            local realVec, realCoords = vector3, GetEntityCoords
            -- (Vectors that subtract and measure, as the game's do: how near the shooter is.)
            local V = {}
            V.__index = V
            V.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V) end
            V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
            rawset(_G, 'vector3', function(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end)
            rawset(_G, 'GetEntityCoords', function() return vector3(0.0, 0.0, 0.0) end)
            rawset(DirectorTasks, 'propSlot', function() return 'set1', 1 end)
            rawset(PropSets, 'wireOf', function() return 'wire1' end)
            local token
            rawset(_G, 'TriggerClientEvent', function(name, _, f) if name == 'whip_core:client:directorFire' then token = f.token end end)
            local world = {}
            for i, w in ipairs(WORLD) do world[i] = w end
            world[#world + 1] = { id = 'gun', kind = 'prop', layer = 'run', label = 'gun',
                                  def = { model = 'w_pi_pistol', weapon = 'WEAPON_PISTOL', coords = at(1) } }
            local function fireDoc()
                local d = doc({ n('s', 'scenario.started', {}, 1), n('f', 'weapon.fire', { weapon = 'gun', shots = 1, gap = 0.5 }, 1),
                    n('w', 'scenario.succeed', {}, 1), n('x', 'scenario.fail', {}, 1) },
                    { l('a', 's', 'out', 'f'), l('b', 'f', 'fired', 'w'), l('c', 'f', 'timeout', 'x') })
                d.world = world
                return d
            end
            local fired = HARNESS_EVENTS['whip_core:server:directorFired']
            local run = start('hf_fire', fireDoc())
            assertNotNil(token, 'its game was told to fire')
            fired(1, nil, token, true, '')
            tick(2)
            assertEqual(run.status, 'succeeded', 'Fired, at once')
            fired(1, nil, token, true, '')   -- (a second answer: nothing left to answer)
            Director.deactivate('hf_fire', 'done')
            token = nil
            run = start('hf_fire', fireDoc())
            assertNotNil(token, 'told again')
            tick(200)
            assertEqual(run.status, 'running', 'its shots could still be going')
            tick(20)
            assertEqual(run.status, 'failed', 'No answer, once its shots should long be over')
            fired(1, nil, token, true, '')   -- (a late one: the card is over)
            Director.deactivate('hf_fire', 'done')
            DirectorTasks.propSlot, PropSets.wireOf, TriggerClientEvent = realSlot, realWire, realSend
            vector3, GetEntityCoords = realVec, realCoords
        end },
        { name = 'a value from a variable is checked by its field\'s kind (DirectorFields), lists and loot too', fn = function()
            local F = DirectorFields
            local world = { g1 = { id = 'g1', kind = 'npc' }, car1 = { id = 'car1', kind = 'vehicle' } }
            local cx = { world = world }
            assertEqual(F.fromVar({ kind = 'number', min = 1, max = 10 }, '25', cx), 10, 'a number held to its range')
            assertNil(F.fromVar({ kind = 'number' }, 'many', cx), 'no number: nothing')
            assertEqual(F.fromVar({ kind = 'text', maxLength = 3 }, 'abcdef', cx), 'abc', 'text cut to its length')
            assertEqual(F.fromVar({ kind = 'select', options = { 'a', 'b' } }, 'b', cx), 'b', 'a choice it has')
            assertNil(F.fromVar({ kind = 'select', options = { 'a', 'b' } }, 'c', cx), 'not one of its choices')
            assertEqual(F.fromVar({ kind = 'world', worldKind = 'npc' }, 'g1', cx), 'g1', 'a placed NPC')
            assertNil(F.fromVar({ kind = 'world', worldKind = 'npc' }, 'car1', cx), 'a car for an NPC field')
            assertNil(F.fromVar({ kind = 'worlds', worldKind = 'npc' }, { 'g1', 'nope' }, cx), 'a list naming a thing not placed (it went through)')
            assertEqual(F.fromVar({ kind = 'worlds', worldKind = 'npc' }, { 'g1' }, cx)[1], 'g1', 'a list of placed NPCs')
            assertNil(F.fromVar({ kind = 'loot' }, { { slot = 0, item = 'food' } }, cx), 'loot with no slot (it went through)')
            assertEqual(F.fromVar({ kind = 'runItem' }, 'food', cx), 'food', 'a run item\'s key')
            assertEqual(F.fromVar(nil, 'as is', cx), 'as is', 'no field: as it is')
        end },
        { name = 'what a card or a step does is its own say: the Haggle\'s list, a Wait for a card, an emote as an animation', fn = function()
            local hg = {}
            for _, t in ipairs(DirectorNodes.HAGGLED) do hg[t] = true end
            for _, t in ipairs({ 'player.pay', 'lore.pay', 'player.charge', 'player.giveItem', 'npc.sell' }) do
                assertTrue(hg[t], t .. ' can be haggled for (the old list)')
            end
            assertEqual(#DirectorNodes.HAGGLED, 5, 'and nothing more')
            assertTrue(DirectorSteps.waitsOnCard('wait', { by = 'card' }), 'a Wait for a card waits on one')
            assertFalse(DirectorSteps.waitsOnCard('wait', { by = 'time' }), 'a Wait for a time does not')
            assertFalse(DirectorSteps.waitsOnCard('goTo', { by = 'card' }), 'another step does not')
            local plan = DirectorTasks.compile('npc', { list = { { t = 'emote', by = 'animation', dict = 'a@b', clip = 'c' },
                                                                 { t = 'speech', line = 'not a name!' } } }, {})
            assertEqual(plan and plan.steps[1] and plan.steps[1].t, 'anim', 'an emote set to an animation plays as one')
            local _, probs = DirectorTasks.compile('npc', { list = { { t = 'speech', line = 'not a name!' } } }, {})
            assertTrue(probs[1] and tostring(probs[1].why):find('GTA name', 1, true) ~= nil, 'a step\'s own check: ' .. tostring(probs[1] and probs[1].why))
            _, probs = DirectorTasks.compile('prop', { list = { { t = 'wait', by = 'card', card = 'x', outs = { 'out' } } } }, {})
            assertTrue(probs[1] and tostring(probs[1].why):find('not a card', 1, true) ~= nil, 'a prop cannot wait on a card')
        end },
        { name = 'a car pool: each model made with its wheels on the placed ground, at its own height (def.lifts)', fn = function()
            local def = { model = 'blista', random = true,
                          models = { { model = 'blista', chance = 0 }, { model = 'boxville', chance = 0 }, { model = 'trailers', chance = 0 } },
                          coords = { x = 10.0, y = 0.0, z = 30.55, heading = 90.0, ground = 30.0 },
                          lifts = { blista = 0.55, boxville = 1.21, trailers = 1.9 } }
            for model, lift in pairs(def.lifts) do
                local where = DirectorNodes.carAt(def, model) --[[@as vector3]]
                assertTrue(math.abs(where.z - (30.0 + lift)) < 1e-6, model .. ' at its own height over the ground: ' .. where.z)
                assertEqual(where.x, 10.0, model .. ' x as placed')
            end
            assertEqual(DirectorNodes.carAt(def, 'adder').z, 30.55, 'a model with no height: where it was placed')
            local old = { model = 'blista', coords = { x = 1.0, y = 2.0, z = 3.0, heading = 0.0 } }
            assertEqual(DirectorNodes.carAt(old, 'blista').z, 3.0, 'a car placed before there was a ground: as placed')
            local bad = { model = 'blista', coords = { x = 1.0, y = 2.0, z = 3.0, ground = 2.5 }, lifts = { blista = 900 } }
            assertEqual(DirectorNodes.carAt(bad, 'blista').z, 3.0, 'a height no car has: as placed')
            -- Through Spawn Car: the model the pool picked, made at its height
            local realSpawn = Vehicles.spawnTempFor
            local made = {}
            rawset(Vehicles, 'spawnTempFor', function(model, where, ...)
                made[#made + 1] = { model = model, z = where.z }
                return realSpawn(model, where, ...)
            end)
            local world = {}
            for i, w in ipairs(WORLD) do world[i] = w end
            world[#world + 1] = { id = 'pool', kind = 'vehicle', layer = 'run', label = 'pool', def = def }
            local d = doc({ n('s', 'scenario.started', {}, 1), n('sc', 'vehicle.spawn', { cars = { 'pool' } }, 1),
                            n('wt', 'flow.wait', { seconds = 600 }, 1), n('w', 'scenario.succeed', {}, 1) },
                          { l('a', 's', 'out', 'sc'), l('b', 'sc', 'out', 'wt'), l('c', 'wt', 'done', 'w') })
            d.world = world
            for _ = 1, 6 do
                start('hf_pool', d)
                Director.deactivate('hf_pool', 'done')
            end
            Vehicles.spawnTempFor = realSpawn
            assertTrue(#made >= 6, 'made each time: ' .. #made)
            for _, m in ipairs(made) do
                assertTrue(math.abs(m.z - (30.0 + def.lifts[m.model])) < 1e-6, ('%s made at %.3f'):format(m.model, m.z))
            end
        end },
        { name = 'TestDirectorCard: the answer comes as its run ends', fn = function()
            local realCall, realCaller = Actions.call, CALLER
            rawset(Actions, 'call', function(_, fn, ...) return pcall(fn, ...) end)
            CALLER = 'hf_sat'
            local ok, why = HARNESS_EXPORTS.__RegisterDirectorCard('hfsat.ping', { title = 'Ping', outputs = { 'pong' }, v = 1, __whipCard = 1 },
                function(op) if op == 'run' then return { pin = 'pong', data = { n = 4 } } end return {} end)
            assertTrue(ok, 'registered (' .. tostring(why) .. ')')
            local got
            CreateThread(function() got = { HARNESS_EXPORTS.TestDirectorCard('hfsat.ping', {}, { player = 1 }) } end)
            tick(6)
            HARNESS_EXPORTS.__RemoveDirectorCard('hfsat.ping')
            Actions.call, CALLER = realCall, realCaller
            assertNotNil(got, 'answered within a few ticks')
            assertEqual(type(got[1]) == 'table' and got[1].outcome, 'pong', 'its outcome (' .. tostring(got[2]) .. ')')
            assertEqual(type(got[1]) == 'table' and got[1].data and got[1].data.n, 4, 'its data')
        end },
    },
})
