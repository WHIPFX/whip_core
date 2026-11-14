-- The lead-in (runtime.lua run.pre, nodes_core.lua scenario.begin): before Scenario Started every end is quiet, a
-- lead-in holds no Runs at once, it has its own time; from Started on the run counts.
-- lua54 guard.lua leadin_test.lua [whip_core path]   (from dev/director; default: the whip_core it is in)
local root = arg[1] or (((arg[0] or ''):match('^(.*)[/\\]') or '.') .. '/../..')
rawset(_G, 'GetCurrentResourceName', function() return 'whip_core' end)
rawset(_G, 'GetGameTimer', function() return 0 end)
rawset(_G, 'CreateThread', function(fn) fn() end)
rawset(_G, 'Citizen', { CreateThreadNow = function(fn) fn() end })
rawset(_G, 'Director', {})
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
dofile(root .. '/server/director/nodes_core.lua')
local R = DirectorRuntime
local now = 0
R.setPorts({ log = function() end, now = function() return now end, thread = function(fn) fn() end, threadNow = function(fn) fn() end })

local pass, fail = 0, 0
local function ok(c, name, extra)
    if c then pass = pass + 1 else fail = fail + 1; print('FAIL ' .. name .. (extra ~= nil and ('  ' .. tostring(extra)) or '')) end
end

-- Director.beginRun as main.lua's, in short: `refuse` says why not.
local refuse = nil
rawset(Director, 'beginRun', function(run)
    if refuse then return refuse end
    run.pre = nil
    run.begunAt = now
    return nil
end)

local function def(d) local okd, why = DirectorNodes.define(d); assert(okd, why) end
-- Waits for the test to say which way (a talk).
def({ type = 't.talk', v = 1, category = 'dialog', title = 'Talk', outputs = { 'yes', 'no', 'late' }, latent = true,
      run = function(ctx) ctx:after(3600 * 1000, 'late') end })
def({ type = 't.go', v = 1, category = 'flow', title = 'Go', outputs = { 'out' }, run = function() return 'out' end })

local function N(id, ty) return { id = id, type = ty, def = DirectorNodes.get(ty), props = {} } end
--   Pre-Scenario -> talk: yes -> Scenario Started: started -> talk2: yes -> Succeed, no -> Fail
--                         no  -> Fail                     notnow  -> (nothing)
local function graph(withBegin)
    local n = { s = N('s', 'scenario.started'), t1 = N('t1', 't.talk'), b = N('b', 'scenario.begin'), t2 = N('t2', 't.talk'),
                win = N('win', 'scenario.succeed'), lose = N('lose', 'scenario.fail'), dead = N('dead', 't.go') }
    local out = { s = { out = { { node = 't1', pin = 'in' } } },
                  t1 = { yes = { { node = withBegin and 'b' or 't2', pin = 'in' } }, no = { { node = 'lose', pin = 'in' } } },
                  b = { started = { { node = 't2', pin = 'in' } } },
                  t2 = { yes = { { node = 'win', pin = 'in' } }, no = { { node = 'lose', pin = 'in' } } } }
    if not withBegin then n.b = nil end
    return { nodes = n, vars = {}, settings = { maxConcurrentRuns = 1 }, events = { ['scenario.started'] = { 's' } }, out = out }
end
local function settle(ms) for _ = 1, 10 do R.pass(); now = now + (ms or 50) end end

-- 1. With the card, a run starts in its lead-in.
local g = graph(true)
local run = assert(R.start(g, { scenarioId = 'x', starter = 1 }))
settle()
ok(run.pre == true and run.active.t1 ~= nil, 'starts in its lead-in, at the talk')

-- 2. A Fail in the lead-in: called off, quietly, saying it was before the start.
ok(R.take(run, 't1', 'no'), 'the talk answered no')
settle()
ok(run.status == 'aborted' and run.quiet == true, 'a Fail before Scenario Started ends quietly', run.status)
ok(type(run.reason) == 'string' and run.reason:find('^before Scenario Started By Player') ~= nil, 'its reason says so', run.reason)

-- 3. Through Scenario Started: from then on a Fail is a failure, and the run is no lead-in.
run = assert(R.start(g, { scenarioId = 'x', starter = 1 }))
settle()
R.take(run, 't1', 'yes')
settle()
ok(run.pre == nil and run.begunAt ~= nil and run.active.t2 ~= nil, 'Started: the job has begun, the next talk waits')
R.take(run, 't2', 'no')
settle()
ok(run.status == 'failed' and not run.quiet, 'a Fail after the start is a failure', run.status)

-- 4. Not now: the run stays a lead-in, and with nothing wired on it ends quietly (no dead-end failure).
refuse = 'a player is cooling down'
run = assert(R.start(g, { scenarioId = 'x', starter = 1 }))
settle()
R.take(run, 't1', 'yes')
settle()
ok(run.status == 'aborted' and run.quiet == true, 'Not now with nothing after it: a quiet end', run.status .. ' ' .. tostring(run.reason))
refuse = nil

-- 5. A lead-in has its own time: past it, a quiet end.
run = assert(R.start(g, { scenarioId = 'x', starter = 1 }))
settle()
now = now + R.LIMITS.preSec * 1000 + 1000
settle()
ok(run.status == 'aborted' and run.quiet == true and tostring(run.reason):find('too long') ~= nil, 'a lead-in that takes too long ends quietly', run.reason)

-- 6. Runs at once: a lead-in holds none; a begun run does.
local a = assert(R.start(g, { scenarioId = 'y', starter = 1 }))
settle()
local b2, why = R.start(g, { scenarioId = 'y', starter = 2 })
ok(b2 ~= false, 'a second lead-in may start while one is talking', why)
R.take(a, 't1', 'yes')
settle()
ok(a.pre == nil, 'the first one began')
local c, cwhy = R.start(g, { scenarioId = 'y', starter = 3 })
ok(c == false and cwhy == 'this scenario is already running', 'with one begun, Runs at once (1) is full', cwhy)

-- 7. Without the card: the job starts at the first card, as before; a Fail is a failure.
local plain = graph(false)
run = assert(R.start(plain, { scenarioId = 'z', starter = 1 }))
settle()
ok(not run.pre, 'no Scenario Started card: no lead-in')
R.take(run, 't1', 'no')
settle()
ok(run.status == 'failed', 'a Fail is a failure, as before', run.status)

-- 8. A fault in a lead-in stays a fault.
def({ type = 't.boom', v = 1, category = 'flow', title = 'Boom', outputs = { 'out' }, run = function() error('boom') end })
local gb = graph(true)
gb.nodes.boom = N('boom', 't.boom')
gb.out.s = { out = { { node = 'boom', pin = 'in' } } }
gb.hasBegin = nil
run = assert(R.start(gb, { scenarioId = 'w', starter = 1 }))
settle()
ok(run.status == 'faulted', 'a fault in the lead-in is still a fault', run.status)

print(('%d passed, %d failed'):format(pass, fail))
