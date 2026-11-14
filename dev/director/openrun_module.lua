-- When it's switched on (main.lua Director.openRun / claim / waitForAnyone, runtime.lua open runs), against the real
-- Director under the dev harness. Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua <this file>
local R = DirectorRuntime

-- ---- what the cards reach, faked: NPCs made, prompts put up (their onUse kept, to press) ----
local npcN = 0
local spawned = {}
rawset(Npcs, 'spawn', function(_, def, _) npcN = npcN + 1; spawned[#spawned + 1] = def.model; return npcN, 500 + npcN end)
rawset(Npcs, 'get', function(id) return { npcId = id, coords = { x = 0, y = 0, z = 0 }, alive = true } end)
rawset(Npcs, 'despawn', function() return true end)
local points, pointN = {}, 0
rawset(RuntimePoints, 'add', function(_, def) pointN = pointN + 1; points[pointN] = def; return pointN end)
rawset(RuntimePoints, 'remove', function(_, id) points[id] = nil; return true end)
rawset(RuntimePoints, 'update', function(_, id, patch)
    if points[id] then for k, v in pairs(patch) do points[id][k] = v end end
    return true
end)
rawset(Players, 2, { source = 2, charId = 8, fullName = 'Second Player', userId = 4 })
-- (satellite_api.lua is not loaded here: the standing layer's news goes nowhere.)
if type(rawget(Director, 'standingMade')) ~= 'function' then rawset(Director, 'standingMade', function() end) end
NOTIFIED = {}
rawset(_G, 'NotifyPlayer', function(s, text) NOTIFIED[#NOTIFIED + 1] = tostring(s) .. ':' .. tostring(text) end)

local function tick(n) for _ = 1, n or 6 do HarnessTick(50) end end
local function newestPoint(filter)
    for i = pointN, 1, -1 do
        local p = points[i]
        if p and (not filter or filter(p)) then return p, i end
    end
end
local function runOf(key)
    for _, r in ipairs(R.list()) do if r.scenarioId == key and r.status == 'running' then return r end end
end

local at = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 }
local function doc(nodes, links, world, start)
    return { format = 2, name = 'Open ' .. tostring(#nodes), description = '', vars = {}, comments = {},
             settings = { start = start or { mode = 'enabled' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 },
             world = world, nodes = nodes, links = links }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local GIRL = { id = 'girl', kind = 'npc', layer = 'run', label = 'Emily', def = { model = 'mp_f_freemode_01', coords = at } }
local function talkDoc(withBegin)
    local nodes = { n('start', 'scenario.started'), n('sp', 'npc.spawn', { npcs = { 'girl' } }),
                    n('line', 'dialog.line', { npc = 'girl', line = 'Start the job?', opt1 = 'Yes', talk = 'Start Mission?' }),
                    n('win', 'scenario.succeed') }
    local links = { l('a', 'start', 'out', 'sp'), l('b', 'sp', 'out', 'line') }
    if withBegin then
        nodes[#nodes + 1] = n('begin', 'scenario.begin')
        links[#links + 1] = l('c', 'line', 'opt1', 'begin')
        links[#links + 1] = l('d', 'begin', 'started', 'win')
    else
        links[#links + 1] = l('c', 'line', 'opt1', 'win')
    end
    return doc(nodes, links, { GIRL })
end
local function activate(key, d)
    local ok, probs = Director.activate(key, d, { rev = 1 })
    if not ok then
        local t = {}
        for _, p in ipairs(type(probs) == 'table' and probs or { { message = tostring(probs) } }) do
            if p.severity ~= 'warning' then t[#t + 1] = tostring(p.message) end
        end
        error({ msg = 'not switched on: ' .. table.concat(t, ' | ') })
    end
end

RegisterTestModule({
    category = 'When it\'s switched on', order = 1,
    tests = {
        { name = 'switched on: its run starts with nobody in it, Scenario Enabled plays', fn = function()
            activate('open_a', talkDoc(false))
            tick()
            local run = runOf('open_a')
            assertNotNil(run, 'a run started as it was switched on')
            assertTrue(run.open == true and run.opened == true and run.pre == true, 'open, a lead-in')
            assertNil(next(run.players), 'nobody in it')
            assertNil(run.deadlineAt, 'no time limit while nobody is in it')
            assertEqual(spawned[#spawned], 'mp_f_freemode_01', 'Scenario Enabled went on: the girl made')
            local p = newestPoint(function(x) return x.talk end)
            assertNotNil(p, 'her Talk is up')
            assertNil(p.audience, 'for everyone')
            assertEqual(p.label, 'Start Mission?', 'with the Dialog Line\'s own prompt')
        end },
        { name = 'the first to talk joins, the line plays for them, the job counts; over: a fresh run', fn = function()
            local run = runOf('open_a')
            local p = newestPoint(function(x) return x.talk and x.audience == nil end)
            local res = table.pack(p.onUse(1, { useId = 77 }))
            assertTrue(res[1] ~= false, 'the press is taken (' .. tostring(res[2]) .. ')')
            assertTrue(run.players[1] == true and run.starter == 1, 'they are in it, its starter')
            assertNil(run.open, 'open no more')
            assertNil(run.pre, 'no Scenario Run Started By Player card: the job started as they joined')
            assertNotNil(run.deadlineAt, 'its time limit from now')
            local refused = table.pack(p.onUse(2, { useId = 78 }))
            assertFalse(refused[1], 'a second player at the same Talk is refused')
            tick()
            -- (Played again for player 1: Conversations is not here, so its own Talk for them goes up.)
            local mine = newestPoint(function(x) return x.talk and type(x.audience) == 'table' end)
            assertNotNil(mine, 'the Dialog Line played for them')
            assertEqual(mine.audience.people[1], 1, 'theirs')
            R.emit('conversation.choice', { runId = run.id, nodeId = 'line', source = 1, option = 'opt1' })
            tick()
            assertEqual(run.status, 'succeeded', 'Yes: Succeed')
            for _ = 1, 60 do HarnessTick(50) end
            local again = runOf('open_a')
            assertNotNil(again, 'a new run once it was over')
            assertTrue(again.id ~= run.id and again.open == true, 'fresh, open again')
        end },
        { name = 'with Scenario Run Started By Player: a lead-in from the join, the job there', fn = function()
            activate('open_b', talkDoc(true))
            tick()
            local run = runOf('open_b')
            local p = newestPoint(function(x) return x.talk and x.audience == nil end)
            p.onUse(2, { useId = 90 })
            assertTrue(run.pre == true and run.players[2] == true, 'joined, still a lead-in')
            assertNotNil(run.preDeadlineAt, 'its lead-in time from now')
            assertNil(run.begunAt, 'not counted yet')
            tick()
            R.emit('conversation.choice', { runId = run.id, nodeId = 'line', source = 2, option = 'opt1' })
            tick()
            assertNotNil(run.begunAt, 'Scenario Run Started By Player: the job began')
            assertEqual(run.status, 'succeeded', 'and went on to Succeed')
        end },
        { name = 'nothing to wait for, nobody in it: it stays up (scenery)', fn = function()
            activate('open_c', doc({ n('start', 'scenario.started'), n('sp', 'npc.spawn', { npcs = { 'girl' } }) },
                                   { l('a', 'start', 'out', 'sp') }, { GIRL }))
            for _ = 1, 40 do HarnessTick(50) end
            local run = runOf('open_c')
            assertNotNil(run, 'still going')
            assertTrue(run.open == true, 'still open')
        end },
        { name = 'switched off: its run ends, and none starts again', fn = function()
            local run = runOf('open_c')
            Director.deactivate('open_c', 'switched off')
            for _ = 1, 60 do HarnessTick(50) end
            assertTrue(run.status ~= 'running', 'ended')
            assertNil(runOf('open_c'), 'no new one')
        end },
        { name = 'Succeed with nobody in it: ends, not started again (no loop)', fn = function()
            activate('open_d', doc({ n('start', 'scenario.started'), n('win', 'scenario.succeed') },
                                   { l('a', 'start', 'out', 'win') }, {}))
            for _ = 1, 60 do HarnessTick(50) end
            assertNil(runOf('open_d'), 'over, and no new one')
            Director.deactivate('open_d', 'switched off')
        end },
        { name = 'Start a run by hand: that player joins the waiting run', fn = function()
            activate('open_e', doc({ n('start', 'scenario.started'), n('sp', 'npc.spawn', { npcs = { 'girl' } }) },
                                   { l('a', 'start', 'out', 'sp') }, { GIRL }))
            tick()
            local run = runOf('open_e')
            local got, why = Director.startRun(Director.active.open_e, 2, nil, nil)
            assertTrue(got == run, 'the same run (' .. tostring(why) .. ')')
            assertTrue(run.players[2] == true and not run.open, 'they joined it')
            local again = Director.startRun(Director.active.open_e, 1, nil, nil)
            assertFalse(again, 'nobody else while it is theirs')
            Director.deactivate('open_e', 'switched off')
        end },
        { name = 'Wait for Press: anyone may press, the first joins and it goes on', fn = function()
            local SPOT = { id = 'desk', kind = 'spot', layer = 'run', label = 'Desk', def = { coords = at } }
            activate('open_f', doc({ n('start', 'scenario.started'), n('press', 'point.press', { at = 'desk', label = 'Sign in' }),
                                     n('win', 'scenario.succeed') },
                                   { l('a', 'start', 'out', 'press'), l('b', 'press', 'used', 'win') }, { SPOT }))
            tick()
            local run = runOf('open_f')
            local p = newestPoint(function(x) return x.label == 'Sign in' end)
            assertNotNil(p, 'its prompt is up')
            assertNil(p.audience, 'for everyone')
            p.onUse(1, { useId = 5 })
            tick()
            assertTrue(run.players[1] == true, 'the presser joined')
            assertEqual(run.status, 'succeeded', 'Pressed went on')
            Director.deactivate('open_f', 'switched off')
        end },
        { name = 'Player Arrives: the first to come near joins', fn = function()
            local SPOT = { id = 'lot', kind = 'spot', layer = 'run', label = 'Lot', def = { coords = at } }
            local realEligible = Director.eligibleNow
            rawset(Director, 'eligibleNow', function() return { { src = 2, x = 1, y = 0, z = 0 } } end)
            activate('open_g', doc({ n('start', 'scenario.started'), n('near', 'area.entered', { at = 'lot', radius = 10 }),
                                     n('win', 'scenario.succeed') },
                                   { l('a', 'start', 'out', 'near'), l('b', 'near', 'entered', 'win') }, { SPOT }))
            -- (The open run, taken as it starts: an ended run leaves R.list at once.)
            local run = runOf('open_g')
            assertNotNil(run, 'its open run is waiting')
            for _ = 1, 40 do HarnessTick(50) end
            Director.eligibleNow = realEligible
            assertTrue(run and run.players[2] == true, 'the one who came near joined')
            assertEqual(run and run.status, 'succeeded', 'it went on to Succeed')
            Director.deactivate('open_g', 'switched off')
        end },
        { name = 'an old talk-to-start scenario is as it was', fn = function()
            local OLD = { id = 'boss', kind = 'npc', layer = 'standing', label = 'Boss', def = { model = 'a_m_m_business_01', coords = at } }
            activate('old_a', doc({ n('start', 'scenario.started'), n('win', 'scenario.succeed') }, { l('a', 'start', 'out', 'win') },
                                  { OLD }, { mode = 'interaction', world = 'boss', label = 'Talk' }))
            tick()
            assertNil(runOf('old_a'), 'no run until someone talks')
            Director.deactivate('old_a', 'switched off')
        end },
    },
})
