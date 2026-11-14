-- The test window's engine side (server/director/runtime.lua): R.take, R.rewind, the steps' `n`, why a wait went on,
-- and what a card made, by step. Through the real nodes.lua and runtime.lua.
-- lua54 guard.lua rewind_test.lua [whip_core path]   (from dev/director; default: the whip_core it is in)
local root = arg[1] or (((arg[0] or ''):match('^(.*)[/\\]') or '.') .. '/../..')
local t = 0
rawset(_G, 'GetCurrentResourceName', function() return 'whip_core' end)
rawset(_G, 'GetGameTimer', function() return t end)
rawset(_G, 'CreateThread', function(fn) fn() end)
rawset(_G, 'Citizen', { CreateThreadNow = function(fn) fn() end })
-- (What satellite_api.lua gives the runtime: told of each thing made. Nothing to tell here.)
rawset(_G, 'Director', { thingMade = function() end })
rawset(_G, 'Registry', { new = function(_, o)
    return {
        seed = function(_, k, v) o.store[k] = v; if o.onAdd then o.onAdd() end end,
        add = function(_, _, k, v) o.store[k] = v; return true end,
        remove = function() return true end,
        ownerOf = function() return 'whip_core' end,
    }
end })
rawset(_G, 'IsDuplicityVersion', function() return true end)
dofile(root .. '/shared/director/kit.lua')
dofile(root .. '/shared/director/steps.lua')
dofile(root .. '/server/director/fields.lua')
dofile(root .. '/server/director/nodes.lua')
dofile(root .. '/server/director/runtime.lua')
local R = DirectorRuntime
local now = 0
R.setPorts({ log = function() end, now = function() return now end, thread = function(fn) fn() end, threadNow = function(fn) fn() end })

local pass, fail = 0, 0
local function ok(c, name, extra)
    if c then pass = pass + 1 else fail = fail + 1; print('FAIL ' .. name .. (extra ~= nil and ('  ' .. tostring(extra)) or '')) end
end

local made, ended = 0, {}
local function def(d) local okd, why = DirectorNodes.define(d); assert(okd, why) end
def({ type = 't.start', v = 1, category = 'events', title = 'Start', outputs = { 'out' }, event = { name = 'scenario.started' } })
-- Makes a thing for the world id in its props, and goes on.
def({ type = 't.make', v = 1, category = 'world', title = 'Make', outputs = { 'out' },
      props = { { key = 'what', kind = 'text', label = 'What' } },
      run = function(ctx) made = made + 1; ctx:remember(ctx.node.props.what, { npcId = made }); return 'out' end })
-- Waits a minute: Late, unless the tester takes another outcome.
def({ type = 't.wait', v = 1, category = 'flow', title = 'Wait', outputs = { 'late', 'a', 'b' }, latent = true,
      run = function(ctx) ctx:after(60000, 'late'); ctx:onEnd(function(pin, why) ended[#ended + 1] = tostring(pin) .. ':' .. tostring(why) end) end })
def({ type = 't.mark', v = 1, category = 'world', title = 'Mark', outputs = { 'out' }, run = function() return 'out' end })
def({ type = 't.end', v = 1, category = 'scenario', title = 'Succeed', outputs = {}, run = function(ctx) ctx:finish('success') end })

local function graph()
    local n = {}
    local function node(id, ty, props) n[id] = { id = id, type = ty, def = DirectorNodes.get(ty), props = props or {} } end
    node('s', 't.start'); node('m1', 't.make', { what = 'guard' }); node('w', 't.wait')
    node('ma', 't.make', { what = 'carA' }); node('wa', 't.wait'); node('mb', 't.make', { what = 'carB' })
    node('once', 't.mark', { onlyOnce = true }); node('e', 't.end')
    return { nodes = n, vars = {}, settings = {}, events = { ['scenario.started'] = { 's' } },
             out = { s = { out = { { node = 'm1', pin = 'in' } } },
                     m1 = { out = { { node = 'w', pin = 'in' } } },
                     w = { a = { { node = 'ma', pin = 'in' } }, b = { { node = 'mb', pin = 'in' } }, late = { { node = 'e', pin = 'in' } } },
                     ma = { out = { { node = 'once', pin = 'in' } } },
                     once = { out = { { node = 'wa', pin = 'in' } } },
                     wa = { late = { { node = 'e', pin = 'in' } } },
                     mb = { out = { { node = 'e', pin = 'in' } } } } }
end
local function settle(ms) for _ = 1, 10 do R.pass(); now = now + (ms or 50) end end
local function steps(run, kind) local out = {} for _, e in ipairs(R.trace(run)) do if not kind or e.kind == kind then out[#out + 1] = e end end return out end
local function stepOf(run, node, kind) for _, e in ipairs(R.trace(run)) do if e.node == node and e.kind == (kind or 'enter') then return e end end end

-- 1. Steps carry their number; what a card made is kept by the step that made it.
local run = assert(R.start(graph(), { scenarioId = 'x', test = true, starter = 1 }))
settle()
local all = R.trace(run)
ok(#all > 3 and all[1].n == 1 and all[#all].n == #all, 'each step has its number in order', all[#all] and all[#all].n)
ok(run.active.w ~= nil, 'the wait card is waiting')
ok(run.madeAt.guard == stepOf(run, 'm1').n, 'the guard is the Make step\'s', run.madeAt.guard)

-- 2. Take: the waiting card goes on from the outcome the tester picks, its end hook told it was answered.
ok(R.take(run, 'm1', 'out') == false, 'a card that is not waiting is not taken')
ok(R.take(run, 'w', 'nope') == false, 'an outcome it has not got is not taken')
ok(R.take(run, 'w', 'a') == true, 'the waiting card is taken')
settle()
local res = stepOf(run, 'w', 'resume')
ok(res and res.pin == 'a' and res.text == 'taken by the tester', 'its step says the tester took it', res and res.text)
ok(ended[#ended] == 'a:answered', 'its end hook heard the answer', ended[#ended])
ok(run.world.carA ~= nil and run.active.wa ~= nil, 'carA was made and the next wait waits')
ok(run.played.once ~= nil, 'the Only Once card has played')

-- 3. Rewind to the first wait, on from b: carA (made after it) is handed back and forgotten, the guard stays, the
--    waiting card stops, Only Once may play again, and the run goes the b way.
local wStep = stepOf(run, 'w')
local okr, list = R.rewind(run, wStep.n, 'w', 'b')
ok(okr == true, 'rewound', list)
local ids = {}
for _, m in ipairs(type(list) == 'table' and list or {}) do ids[#ids + 1] = m.id end
ok(#ids == 1 and ids[1] == 'carA' and list[1].h.npcId ~= nil, 'carA is handed back with its handle', table.concat(ids, ','))
ok(run.world.carA == nil and run.madeAt.carA == nil, 'the run forgets carA')
ok(run.world.guard ~= nil, 'the guard (made before) stays')
ok(run.active.wa == nil, 'the wait after it stopped')
ok(run.played.once == nil, 'Only Once may play again')
local rw = steps(run, 'rewind')[1]
ok(rw and rw.node == 'w' and rw.pin == 'b' and rw.text == ('back to step %d'):format(wStep.n), 'the rewind is a step of its own', rw and rw.text)
settle()
ok(run.status == 'succeeded' and run.world.carB ~= nil, 'the b way ran to its end', run.status)

-- 4. Over: nothing to rewind.
local okd, why = R.rewind(run, wStep.n, 'w', 'a')
ok(okd == false and why == 'the run is over', 'an ended run is not rewound', why)

-- 5. Why a wait went on: its time came.
local run2 = assert(R.start(graph(), { scenarioId = 'y', test = true, starter = 1 }))
settle()
now = now + 61000
settle()
local late = stepOf(run2, 'w', 'resume')
ok(late and late.pin == 'late' and late.text == 'its time came (60 s)', 'a timer says its time came', late and late.text)

-- 6. Rewound to before the card that made the guard's own step: what the card at that step made stays.
local run3 = assert(R.start(graph(), { scenarioId = 'z', test = true, starter = 1 }))
settle()
local m1 = stepOf(run3, 'm1')
local ok3, list3 = R.rewind(run3, m1.n, 'm1', 'out')
ok(ok3 and #list3 == 0 and run3.world.guard ~= nil, 'what the step\'s own card made stays', #list3)

-- 7. A ctx for work outside the pass.
local c = R.ctxOf(run3, 'm1')
c:remember('box', { id = 1 })
ok(run3.world.box ~= nil and c.node.id == 'm1', 'ctxOf remembers for the run')

-- 8. The cards' own memory goes back too (nodes_core.lua's real First Time Only and Wait for All): a First Time Only
--    that went on after the step goes on again; a Wait for All forgets the inputs that came after the step, keeps those
--    from before.
local okCore, coreErr = pcall(dofile, root .. '/server/director/nodes_core.lua')
ok(okCore, 'nodes_core.lua loads here', coreErr)
local function graph8()
    local n = {}
    local function node(id, ty, props) n[id] = { id = id, type = ty, def = DirectorNodes.get(ty), props = props or {} } end
    node('s', 't.start'); node('m0', 't.mark'); node('w', 't.wait'); node('first', 'flow.once'); node('all', 'flow.waitAll')
    node('ma', 't.mark'); node('done', 't.mark')
    return { nodes = n, vars = {}, settings = {}, events = { ['scenario.started'] = { 's' } },
             out = { s = { out = { { node = 'm0', pin = 'in' } } },
                     -- Before the wait: Wait for All's A. After it (its a): First Time Only, then Wait for All's B.
                     m0 = { out = { { node = 'all', pin = 'a' }, { node = 'w', pin = 'in' } } },
                     w = { a = { { node = 'first', pin = 'in' } } },
                     first = { out = { { node = 'ma', pin = 'in' } } },
                     ma = { out = { { node = 'all', pin = 'b' } } },
                     all = { done = { { node = 'done', pin = 'in' } } } },
             wiredIn = { all = { a = 1, b = 1 }, w = { ['in'] = 1 }, first = { ['in'] = 1 }, ma = { ['in'] = 1 },
                         m0 = { ['in'] = 1 }, done = { ['in'] = 1 } } }
end
if okCore then
    local r8 = assert(R.start(graph8(), { scenarioId = 'eight', test = true, starter = 1 }))
    settle()
    local wStep8 = stepOf(r8, 'w')
    ok(r8.state.all and r8.state.all.seen and r8.state.all.seen.a ~= nil, 'Wait for All has its A (from before the wait)')
    ok(R.take(r8, 'w', 'a') == true, 'the wait taken: a')
    settle()
    ok(r8.state.first and r8.state.first.done == true, 'First Time Only went on')
    ok(stepOf(r8, 'done') ~= nil, 'Wait for All went on (A and B)')
    -- Back to the wait: First Time Only forgets it went on; Wait for All had reset when it went on (empty: nothing to keep).
    local okr8 = R.rewind(r8, wStep8.n, 'w', 'b')
    ok(okr8 == true, 'rewound to the wait')
    ok(r8.state.first == nil, 'First Time Only may go on again')
    -- A Wait for All half filled across the step: its B (after) forgotten, its A (before) kept.
    local r9 = assert(R.start(graph8(), { scenarioId = 'nine', test = true, starter = 1 }))
    settle()
    local w9 = stepOf(r9, 'w')
    r9.state.all.seen.b = w9.n + 5   -- (B as if reached after the wait's step)
    R.rewind(r9, w9.n, 'w', 'b')
    ok(r9.state.all and r9.state.all.seen.a ~= nil and r9.state.all.seen.b == nil, 'Wait for All: A kept, B forgotten',
       r9.state.all and tostring(r9.state.all.seen.a) .. '/' .. tostring(r9.state.all.seen.b))
end

-- THE LEDGER (CTX:own): what a card put out is given back once, newest first: at a rewind, what came after the step;
-- at the end (R.release), the rest. One that fails does not stop the others.
do
    local r10 = assert(R.start(graph(), { scenarioId = 'ten', test = true, starter = 1 }))
    settle()
    local back = {}
    local function own(seq, name, failing)
        local ctx = R.ctxOf(r10, 'm1')
        ctx.seq = seq
        return ctx:own(function(reason)
            back[#back + 1] = name .. ':' .. reason
            if failing then error('it broke') end
        end, name)
    end
    own(1, 'early'); own(5, 'late'); own(6, 'later', true)
    local gone = own(2, 'given back by its card')
    gone.done()
    R.release(r10, 'rewound', 3)
    ok(table.concat(back, ',') == 'later:rewound,late:rewound', 'a rewind gives back what came after its step, newest first',
       table.concat(back, ','))
    back = {}
    R.release(r10, 'ended')
    ok(table.concat(back, ',') == 'early:ended', 'the end gives back the rest, once (not one its card gave back)', table.concat(back, ','))
    back = {}
    R.release(r10, 'ended')
    ok(#back == 0, 'never twice')
end

print(('%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
