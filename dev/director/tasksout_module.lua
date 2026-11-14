-- Start Tasks' outcomes come from its OWN lists (nodes_tasks.lua DirectorTasks.over): Finished when they finished,
-- Stopped when a Stop Tasks stopped them or another card started them again (that card's Finished is its own), Could
-- not when none could play. NPCs as server/npcs.lua ends their lists: a list put in place of one ends it 'stopped'.
-- Against the real Director:
--   MEMCAP_MB=512 lua54 guard.lua harness.lua tasksout_module.lua

local npcs, nextNpc = {}, 0
local lists = {}   -- [npcId] = the list it plays: { onEnd, from }
rawset(Npcs, 'spawn', function()
    nextNpc = nextNpc + 1
    npcs[nextNpc] = { npcId = nextNpc, netId = 5000 + nextNpc, alive = true, coords = { x = 0.0, y = 0.0, z = 0.0 } }
    return nextNpc, 5000 + nextNpc
end)
rawset(Npcs, 'get', function(id) return npcs[id] end)
local function endList(id, why)
    local l = lists[id]
    lists[id] = nil
    if l then l.onEnd(why) end
end
rawset(Npcs, 'runTasks', function(_, id, _, opts)
    endList(id, 'stopped')   -- (in place of the one it plays)
    lists[id] = { onEnd = opts.onEnd }
    return true
end)
rawset(Npcs, 'stopTasks', function(_, id)
    if not lists[id] then return nil end
    endList(id, 'stopped')
    return 1
end)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end

local at = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }
local WORLD = { { id = 'npc1', kind = 'npc', layer = 'run', label = 'Guard', def = { model = 's_m_m_security_01', coords = at,
                  conditions = { canMove = true }, tasks = { list = { { k = 'a', t = 'wait', sec = 60 } }, after = 'stop' } } } }
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function doc(nodes, links, vars)
    -- (Every test holds the run at 'hold': a Succeed after it, for Check.)
    nodes[#nodes + 1] = n('win', 'scenario.succeed')
    links[#links + 1] = l('z', 'hold', 'done', 'win')
    return { format = 2, name = 'Outcomes', description = '', vars = vars or {}, comments = {}, world = WORLD, nodes = nodes,
             links = links, settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
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
local function fired(run, node, pin)
    local c = 0
    for i = 1, run.trace.n do
        local e = run.trace[i]
        if e and e.node == node and e.pin == pin and (e.kind == 'out' or e.kind == 'resume') then c = c + 1 end
    end
    return c
end
local function reset() npcs, nextNpc, lists = {}, 0, {} end
local VARS = { { id = 'k', label = 'k', type = 'number', default = 0 } }

RegisterTestModule({
    category = 'Start Tasks: its own outcomes', order = 1,
    tests = {
        { name = 'left to finish: Finished', fn = function()
            reset()
            local run = start('to_a', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                            n('st', 'tasks.start', { things = { 'npc1' } }), n('hold', 'flow.wait', { seconds = 600 }) },
                { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'st'), l('c', 'st', 'out', 'hold') }))
            tick(20)
            assertEqual(fired(run, 'st', 'out'), 1, 'Started')
            endList(1, 'done')
            tick(20)
            assertEqual(fired(run, 'st', 'done'), 1, 'Finished')
            assertEqual(fired(run, 'st', 'stopped'), 0, 'not Stopped')
            Director.deactivate('to_a', 'switched off')
        end },
        { name = 'a Stop Tasks stops them: Stopped, never Finished', fn = function()
            reset()
            local run = start('to_b', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                            n('st', 'tasks.start', { things = { 'npc1' } }), n('w', 'flow.wait', { seconds = 2 }),
                                            n('stop', 'tasks.stop', { what = 'npc1' }), n('hold', 'flow.wait', { seconds = 600 }),
                                            n('fin', 'var.add', { var = 'k', amount = 1 }) },
                { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'st'), l('c', 'st', 'out', 'w'), l('d', 'w', 'done', 'stop'),
                  l('e', 'stop', 'out', 'hold'), l('f', 'st', 'done', 'fin') }, VARS))
            tick(80)
            assertEqual(fired(run, 'st', 'stopped'), 1, 'Stopped')
            assertEqual(fired(run, 'st', 'done'), 0, 'not Finished')
            assertEqual(run.vars.k, 0, 'nothing wired to Finished played')
            Director.deactivate('to_b', 'switched off')
        end },
        { name = 'another Start Tasks starts them again: the first Stopped, the second Finished when they finish', fn = function()
            reset()
            local run = start('to_c', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                            n('st', 'tasks.start', { things = { 'npc1' } }), n('w', 'flow.wait', { seconds = 2 }),
                                            n('st2', 'tasks.start', { things = { 'npc1' } }), n('hold', 'flow.wait', { seconds = 600 }) },
                { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'st'), l('c', 'st', 'out', 'w'), l('d', 'w', 'done', 'st2'),
                  l('e', 'st2', 'out', 'hold') }))
            tick(80)
            assertEqual(fired(run, 'st', 'stopped'), 1, 'the first: Stopped')
            assertEqual(fired(run, 'st', 'done'), 0, 'the first never Finished')
            assertEqual(fired(run, 'st2', 'done'), 0, 'the second still playing')
            endList(1, 'done')
            tick(20)
            assertEqual(fired(run, 'st2', 'done'), 1, 'the second: Finished')
            assertEqual(fired(run, 'st', 'done'), 0, 'and still not the first')
            Director.deactivate('to_c', 'switched off')
        end },
        { name = 'none could play: Could not', fn = function()
            reset()
            local run = start('to_d', doc({ n('s', 'scenario.started'), n('sn', 'npc.spawn', { npcs = { 'npc1' }, tasks = false }),
                                            n('st', 'tasks.start', { things = { 'npc1' } }), n('hold', 'flow.wait', { seconds = 600 }) },
                { l('a', 's', 'out', 'sn'), l('b', 'sn', 'out', 'st'), l('c', 'st', 'out', 'hold') }))
            tick(20)
            endList(1, 'nothing to do')
            tick(20)
            assertEqual(fired(run, 'st', 'failed'), 1, 'Could not')
            Director.deactivate('to_d', 'switched off')
        end },
    },
})
