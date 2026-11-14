-- Activate After Failure / Success (runtime.lua startAfter): the chain plays once the run fails or succeeds, everything
-- else stopped, and the run then ends as it was going to.
-- lua54 guard.lua after_test.lua [whip_core path]   (from dev/director; default: the whip_core it is in)
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
pcall(dofile, root .. '/server/director/nodes_conditions.lua')
local R = DirectorRuntime
local now = 0
R.setPorts({ log = function() end, now = function() return now end, thread = function(fn) fn() end, threadNow = function(fn) fn() end })
R.bridge('scenario.started')

local pass, fail = 0, 0
local function ok(c, name, extra)
    if c then pass = pass + 1 else fail = fail + 1; print('FAIL ' .. name .. (extra ~= nil and ('  ' .. tostring(extra)) or '')) end
end
local played = {}
local function def(d) local okd, why = DirectorNodes.define(d); assert(okd, why) end
def({ type = 't.talk', v = 1, category = 'dialog', title = 'Talk', outputs = { 'yes', 'no', 'late' }, latent = true,
      run = function(ctx) ctx:after(3600 * 1000, 'late') end })
def({ type = 't.mark', v = 1, category = 'world', title = 'Mark', outputs = { 'out' },
      run = function(ctx) played[#played + 1] = ctx.node.id return 'out' end })
def({ type = 't.slow', v = 1, category = 'flow', title = 'Slow', outputs = { 'done' }, latent = true,
      run = function(ctx) ctx:after(1000, 'done') end })

ok(DirectorNodes.get('run.afterFail') ~= nil and DirectorNodes.get('run.afterSuccess') ~= nil, 'the two After cards are defined')

local function N(id, ty) return { id = id, type = ty, def = DirectorNodes.get(ty), props = {} } end
local function graph()
    local n = { s = N('s', 'scenario.started'), t = N('t', 't.talk'), win = N('win', 'scenario.succeed'), lose = N('lose', 'scenario.fail'),
                af = N('af', 'run.afterFail'), as = N('as', 'run.afterSuccess'), slow = N('slow', 't.slow'),
                mf = N('mf', 't.mark'), ms = N('ms', 't.mark'), again = N('again', 'scenario.succeed') }
    return { nodes = n, vars = {}, settings = {}, events = { ['scenario.started'] = { 's' } },
             out = { s = { out = { { node = 't', pin = 'in' } } },
                     t = { yes = { { node = 'win', pin = 'in' } }, no = { { node = 'lose', pin = 'in' } } },
                     af = { out = { { node = 'slow', pin = 'in' } } }, slow = { done = { { node = 'mf', pin = 'in' } } },
                     mf = { out = { { node = 'again', pin = 'in' } } },
                     as = { out = { { node = 'ms', pin = 'in' } } } } }
end
local function settle(ms, n) for _ = 1, n or 10 do R.pass(); now = now + (ms or 50) end end

-- 1. Fails: its After Failure chain plays (a wait in it too), a Succeed in it changes nothing, then it is failed.
local run = assert(R.start(graph(), { scenarioId = 'x', starter = 1 }))
settle()
R.take(run, 't', 'no')
settle(50, 4)
ok(run.status == 'running' and run.after == 'failed', 'failed: still going, in its After chain', run.status)
ok(run.active.t == nil, 'the rest of it stopped (the talk no longer waits)')
settle(200, 10)
ok(played[1] == 'mf' and #played == 1, 'the After Failure chain played (not the Success one)', table.concat(played, ','))
ok(run.status == 'failed', 'then it is over: failed, as it was going to be', run.status)

-- 2. Succeeds: the After Success chain.
played = {}
run = assert(R.start(graph(), { scenarioId = 'y', starter = 1 }))
settle()
R.take(run, 't', 'yes')
settle(50, 10)
ok(played[1] == 'ms' and run.status == 'succeeded', 'succeeded: its After Success chain, then succeeded', run.status .. ' ' .. table.concat(played, ','))

-- 3. Its chain has its time: one that waits too long is cut, the run still failed.
local g = graph()
g.nodes.slow.def = DirectorNodes.get('t.talk')
g.nodes.slow.type = 't.talk'
g.out.af = { out = { { node = 'slow', pin = 'in' } } }
run = assert(R.start(g, { scenarioId = 'z', starter = 1 }))
settle()
R.take(run, 't', 'no')
settle()
now = now + R.LIMITS.afterSec * 1000 + 1000
settle()
ok(run.status == 'failed', 'an After chain out of time: the run ends failed', run.status)

print(('%d passed, %d failed'):format(pass, fail))
