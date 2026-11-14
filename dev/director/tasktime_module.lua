-- A task's time (shared/director/steps.lua THE TIMING): a step with no time saved plays its type's, as it always did (a
-- scenario saved before plays as it was built); 0 is no end, sent as NO_END_MS; a time set is that time, at most a day;
-- a step that is one action (a throw, the horn, a prop's slide: `length`) keeps a time and its 0 is at once; a give-up is
-- its type's unless one is typed, and a typed 0 is never. Against the real compile (server/director/tasks.lua):
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
    },
})
