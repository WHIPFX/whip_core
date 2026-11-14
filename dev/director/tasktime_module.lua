-- A task's time (shared/director/steps.lua THE TIMING): 0, where every task starts until a time is set, is no end, sent
-- as NO_END_MS; a time set is that time, at most a day; a step whose time is how long its move takes (a prop's slide)
-- keeps its own, and 0 is at once. Against the real compile (server/director/tasks.lua):
--   MEMCAP_MB=512 lua54 guard.lua harness.lua tasktime_module.lua

local NO_END = DirectorSteps.NO_END_MS
local at = { x = 1.0, y = 2.0, z = 3.0, heading = 0.0 }

local function compile(kind, list)
    local plan, probs = DirectorTasks.compile(kind, { list = list, after = 'stop' }, {}, nil)
    assertNotNil(plan, 'compiled: ' .. tostring(type(probs) == 'table' and probs[1] and probs[1].why))
    return plan.steps
end

RegisterTestModule({
    category = 'Task times', order = 1,
    tests = {
        { name = 'Shoot At with no time set: no end (it shot for 3 seconds)', fn = function()
            local s = compile('npc', { { k = 'a', t = 'shootAt', target = 'nearest' } })
            assertEqual(s[1].timing, 'timed', 'a timed step')
            assertEqual(s[1].ms, NO_END, 'no end')
        end },
        { name = 'a time of 0 is no end; a time set is that time', fn = function()
            local s = compile('npc', { { k = 'a', t = 'shootAt', target = 'nearest', sec = 0 },
                                       { k = 'b', t = 'aimAt', target = 'nearest', sec = 90 },
                                       { k = 'c', t = 'wander', sec = 3725 } })
            assertEqual(s[1].ms, NO_END, '0: no end')
            assertEqual(s[2].ms, 90000, '1 min 30 s')
            assertEqual(s[3].ms, 3725000, '1 h 2 min 5 s')
        end },
        { name = 'giving up: never, unless a time is set', fn = function()
            local s = compile('npc', { { k = 'a', t = 'goTo', at = at },
                                       { k = 'b', t = 'goTo', at = at, giveUp = 45 },
                                       { k = 'c', t = 'getOut' } })
            assertEqual(s[1].timing, 'until', 'Go To waits to get there')
            assertEqual(s[1].giveUpMs, NO_END, 'never gives up')
            assertEqual(s[2].giveUpMs, 45000, 'gives up after the time set')
            assertEqual(s[3].giveUpMs, NO_END, 'Get Out never gives up either')
        end },
        { name = 'Go To set to go on after a time, none set: no end', fn = function()
            local s = compile('npc', { { k = 'a', t = 'goTo', at = at, next = 'time' } })
            assertEqual(s[1].timing, 'timed', 'timed')
            assertEqual(s[1].ms, NO_END, 'no end')
        end },
        { name = "a prop's slide, turn and fade keep their own time, and 0 is at once", fn = function()
            local s = compile('prop', { { k = 'a', t = 'slideTo', at = at },
                                        { k = 'b', t = 'slideTo', at = at, sec = 0 },
                                        { k = 'c', t = 'fade' },
                                        { k = 'd', t = 'turnTo', heading = 90 } })
            assertEqual(s[1].ms, 3000, 'Slide To: its own 3 s')
            assertEqual(s[2].ms, 0, 'Slide To at 0: at once')
            assertEqual(s[3].ms, 1000, 'Fade: its own 1 s')
            assertEqual(s[4].ms, 2000, 'Turn To: its own 2 s')
        end },
        { name = 'a time is at most a day', fn = function()
            local s = compile('npc', { { k = 'a', t = 'shootAt', target = 'nearest', sec = 999999 } })
            assertEqual(s[1].ms, DirectorSteps.MAX_SEC * 1000, 'cut to 23 h 59 min 59 s')
        end },
        { name = "a prop's list with a Wait of no end is not over in any run's time", fn = function()
            local s = compile('prop', { { k = 'a', t = 'slideTo', at = at }, { k = 'b', t = 'wait' } })
            assertEqual(s[2].ms, NO_END, 'the Wait has no end')
            assertGte(DirectorTasks.length({ steps = s }), NO_END, 'its length is past any run')
            assertGt(NO_END, 24 * 3600 * 1000, 'longer than a day')
        end },
    },
})
