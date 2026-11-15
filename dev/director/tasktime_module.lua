-- A task's time (shared/director/steps.lua THE TIMING): a step with no time saved plays its type's, as it always did (a
-- scenario saved before plays as it was built); 0 is no end, sent as NO_END_MS; a time set is that time, at most a day;
-- a step that is one action (a throw, the horn, a prop's slide: `length`) keeps a time and its 0 is at once; a give-up is
-- its type's unless one is typed, and a typed 0 is never; a scenario saved before 0 was no end reads its 0 as the tenth
-- of a second it played (server/director/doc.lua TASK_TIMES). Against the real compile (server/director/tasks.lua):
--   MEMCAP_MB=512 lua54 guard.lua harness.lua tasktime_module.lua

local NO_END = DirectorSteps.NO_END_MS
local at = { x = 1.0, y = 2.0, z = 3.0, heading = 0.0 }

local function compile(kind, list)
    local plan, probs = DirectorTasks.compile(kind, { list = list, after = 'stop' }, {}, nil)
    assertNotNil(plan, 'compiled: ' .. tostring(type(probs) == 'table' and probs[1] and probs[1].why))
    ---@cast plan -nil
    return plan.steps
end

RegisterTestModule({
    category = 'Task times', order = 1,
    tests = {
        { name = 'a step saved with no time plays its type\'s, as before (no saved scenario changes)', fn = function()
            local s = compile('npc', { { k = 'a', t = 'shootAt', target = 'nearest' },
                                       { k = 'b', t = 'wait' },
                                       { k = 'c', t = 'wander' } })
            assertEqual(s[1].ms, 3000, 'Shoot At: 3 s')
            assertEqual(s[2].ms, 3000, 'Wait: 3 s')
            assertEqual(s[3].ms, 20000, 'Wander: 20 s')
        end },
        { name = 'a new Shoot At (its startSec, 0) has no end; a time set is that time', fn = function()
            local d = DirectorSteps.get('shootAt')
            assertEqual(d.startSec, 0, 'a new Shoot At starts at 0')
            local s = compile('npc', { { k = 'a', t = 'shootAt', target = 'nearest', sec = d.startSec },
                                       { k = 'b', t = 'aimAt', target = 'nearest', sec = 90 },
                                       { k = 'c', t = 'wander', sec = 3725 },
                                       { k = 'd', t = 'wait', sec = 0 } })
            assertEqual(s[1].ms, NO_END, '0: no end')
            assertEqual(s[2].ms, 90000, '1 min 30 s')
            assertEqual(s[3].ms, 3725000, '1 h 2 min 5 s')
            assertEqual(s[4].ms, NO_END, 'a Wait at 0 holds')
        end },
        { name = 'one action keeps a time, and its 0 is at once, never no end', fn = function()
            for _, t in ipairs({ 'throw', 'face', 'horn', 'flashLights', 'brake', 'speedTo' }) do
                local d = DirectorSteps.get(t)
                assertTrue(d.length == true, t .. ' is one action')
                assertNil(d.startSec, t .. ' starts at its own time')
                assertGt(d.sec, 0, t .. ' has a time')
            end
            local s = compile('npc', { { k = 'a', t = 'throw', target = 'point', at = at, sec = 0 },
                                       { k = 'b', t = 'face', target = 'nearest' } })
            assertEqual(s[1].ms, 0, 'Throw at 0: at once')
            assertEqual(s[2].ms, 2000, 'Turn To Face: its 2 s')
            local c = compile('vehicle', { { k = 'a', t = 'horn' }, { k = 'b', t = 'horn', sec = 0 }, { k = 'c', t = 'brake', sec = 0 } })
            assertEqual(c[1].ms, 1000, 'the horn: its 1 s')
            assertEqual(c[2].ms, 0, 'the horn at 0: at once')
            assertEqual(c[3].ms, 0, 'a brake at 0: at once')
        end },
        { name = 'giving up: its type\'s time unless one is typed, and a typed 0 is never', fn = function()
            local s = compile('npc', { { k = 'a', t = 'goTo', at = at },
                                       { k = 'b', t = 'goTo', at = at, giveUp = 45 },
                                       { k = 'c', t = 'getOut' },
                                       { k = 'd', t = 'goTo', at = at, giveUp = 0 } })
            assertEqual(s[1].timing, 'until', 'Go To waits to get there')
            assertEqual(s[1].giveUpMs, 30000, 'gives up after its 30 s')
            assertEqual(s[2].giveUpMs, 45000, 'gives up after the time set')
            assertEqual(s[3].giveUpMs, 10000, 'Get Out: its 10 s')
            assertEqual(s[4].giveUpMs, NO_END, 'a typed 0: never')
            for _, t in ipairs({ 'getIn', 'getOut', 'everyoneOut', 'take', 'goTo', 'driveTo', 'cover' }) do
                assertGt(DirectorSteps.get(t).giveUp, 0, t .. ' gives up in time')
            end
        end },
        { name = "a prop's slide, turn and fade keep their own time, and 0 is at once", fn = function()
            local s = compile('prop', { { k = 'a', t = 'slideTo', at = at },
                                        { k = 'b', t = 'slideTo', at = at, sec = 0 },
                                        { k = 'c', t = 'fade' },
                                        { k = 'd', t = 'turnTo', heading = 90 },
                                        { k = 'e', t = 'slideTo', at = at, sec = 0.4 } })
            assertEqual(s[1].ms, 3000, 'Slide To: its own 3 s')
            assertEqual(s[2].ms, 0, 'Slide To at 0: at once')
            assertEqual(s[3].ms, 1000, 'Fade: its own 1 s')
            assertEqual(s[4].ms, 2000, 'Turn To: its own 2 s')
            assertEqual(s[5].ms, 400, 'a 0.4 s slide stays 0.4 s')
        end },
        { name = 'a time is at most a day', fn = function()
            local s = compile('npc', { { k = 'a', t = 'shootAt', target = 'nearest', sec = 999999 } })
            assertEqual(s[1].ms, DirectorSteps.MAX_SEC * 1000, 'cut to 23 h 59 min 59 s')
        end },
        { name = "a prop's list with a Wait of no end is not over in any run's time", fn = function()
            local s = compile('prop', { { k = 'a', t = 'slideTo', at = at }, { k = 'b', t = 'wait', sec = 0 } })
            assertEqual(s[2].ms, NO_END, 'the Wait has no end')
            assertGte(DirectorTasks.length({ steps = s }), NO_END, 'its length is past any run')
            assertGt(NO_END, 24 * 3600 * 1000, 'longer than a day')
        end },
        { name = 'a scenario saved before 0 was no end plays its times of 0 as it did, a tenth of a second', fn = function()
            local function thing(id, kind, list) return { id = id, kind = kind, def = { tasks = { list = list, after = 'stop' } } } end
            local raw = { format = DirectorDoc.FORMAT, name = 'Old', vars = {}, nodes = {}, links = {},
                world = { thing('n1', 'npc', { { k = 'a', t = 'wait', sec = 0 },
                                               { k = 'b', t = 'goTo', at = at, giveUp = 0 },
                                               { k = 'c', t = 'shootAt', target = 'nearest', sec = -2 },
                                               { k = 'd', t = 'wander', sec = '0' },
                                               { k = 'e', t = 'aimAt', target = 'nearest', sec = 5 },
                                               { k = 'f', t = 'wander' } }),
                          thing('p1', 'prop', { { k = 'a', t = 'slideTo', at = at, sec = 0 }, { k = 'b', t = 'wait', sec = 0 } }) },
                variants = { { id = 'v2', name = 'B', nodes = {}, links = {}, world = { thing('n2', 'npc', { { k = 'a', t = 'wait', sec = 0 } }) } } } }
            local doc = DirectorDoc.load(raw)
            assertNotNil(doc, 'it loads')
            ---@cast doc -nil
            assertEqual(doc.taskTimes, DirectorDoc.TASK_TIMES, 'and is marked')
            assertEqual(raw.world[1].def.tasks.list[1].sec, 0, 'what was saved is not changed')
            local s = compile('npc', doc.world[1].def.tasks.list)
            assertEqual(s[1].ms, 100, 'a Wait of 0: a tenth, as before')
            assertEqual(s[2].giveUpMs, 100, 'a give-up of 0: a tenth, as before')
            assertEqual(s[3].ms, 100, 'less than 0: a tenth')
            assertEqual(s[4].ms, 100, 'a 0 saved as text: a tenth')
            assertEqual(s[5].ms, 5000, 'a time set is kept')
            assertEqual(s[6].ms, 20000, 'no time saved: its type\'s')
            local p = compile('prop', doc.world[2].def.tasks.list)
            assertEqual(p[1].ms, 100, 'a prop\'s slide of 0: a tenth')
            assertEqual(DirectorTasks.length({ steps = p }), 200, 'its list as long as it was')
            assertEqual(compile('npc', doc.variants[1].world[1].def.tasks.list)[1].ms, 100, 'every variant\'s')
        end },
        { name = 'a scenario saved since keeps its 0 as no end, saved and read again', fn = function()
            local raw = { format = DirectorDoc.FORMAT, name = 'New', vars = {}, nodes = {}, links = {}, taskTimes = DirectorDoc.TASK_TIMES,
                world = { { id = 'n1', kind = 'npc', def = { tasks = { list = { { k = 'a', t = 'shootAt', target = 'nearest', sec = 0 },
                                                                               { k = 'b', t = 'goTo', at = at, giveUp = 0 } } } } } } }
            local doc = DirectorDoc.load(raw) --[[@as table]]
            local s = compile('npc', doc.world[1].def.tasks.list)
            assertEqual(s[1].ms, NO_END, 'a 0: no end')
            assertEqual(s[2].giveUpMs, NO_END, 'a give-up of 0: never')
            -- (The editor sends back what it was given, the mark with it: an old one, once read, is not read as old again.)
            local old = DirectorDoc.load({ format = DirectorDoc.FORMAT, name = 'Old', vars = {}, nodes = {}, links = {}, world = {} }) --[[@as table]]
            old.world[1] = { id = 'n1', kind = 'npc', def = { tasks = { list = { { k = 'a', t = 'shootAt', target = 'nearest', sec = 0 } } } } }
            local again = DirectorDoc.load(old) --[[@as table]]
            assertEqual(compile('npc', again.world[1].def.tasks.list)[1].ms, NO_END, 'a 0 set after the mark: no end')
        end },
    },
})
