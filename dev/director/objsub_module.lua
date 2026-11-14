-- Show Objective's Subtext: the line under the objective is the scenario's name (the default, and a card from before
-- the field), none, or the card's own words (none when none are typed). Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua objsub_module.lua

local shownName = {}   -- what each objective card put up asked for under it, newest last
local realObjective = PlayerText.objective
rawset(PlayerText, 'objective', function(_, _, _, text, opts)
    shownName[#shownName + 1] = { text = text, name = type(opts) == 'table' and opts.name or nil }
    return true
end)

local function doc(props)
    local function n(id, t, p) return { id = id, type = t, v = 1, x = 0, y = 0, props = p or {} } end
    local function l(id, a, ap, b) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = 'in' } } end
    local o = { text = 'Get to the docks' }
    for k, v in pairs(props) do o[k] = v end
    return { format = 2, name = 'Alleyway Shootout', description = '', vars = {}, comments = {}, world = {},
             nodes = { n('s', 'scenario.started'), n('o', 'player.objective', o), n('w', 'flow.wait', { seconds = 60 }),
                       n('ok', 'scenario.succeed') },
             links = { l('a', 's', 'out', 'o'), l('b', 'o', 'out', 'w'), l('c', 'w', 'done', 'ok') },
             settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
end

local function shown(key, props)
    shownName = {}
    local okA, res, why = pcall(Director.activate, key, doc(props), { rev = 1 })
    if not okA then error(res) end
    local sc = Director.active[key]
    if not sc then
        local _, probs = DirectorGraph.check(doc(props))
        local said = {}
        for _, p in ipairs(probs or {}) do if p.severity == 'error' then said[#said + 1] = tostring(p.message) end end
        error({ msg = 'not switched on: ' .. tostring(why) .. ' | ' .. table.concat(said, ' | ') })
    end
    local run, whyNoRun = Director.startRun(sc, 1, nil, nil)
    if not run then error({ msg = 'no run: ' .. tostring(whyNoRun) }) end
    for _ = 1, 10 do HarnessTick(50) end
    local last = shownName[#shownName]
    Director.deactivate(key, 'switched off')
    if not last then error({ msg = 'no objective shown' }) end
    return last
end

RegisterTestModule({
    category = 'Show Objective subtext', order = 1,
    tests = {
        { name = 'a card from before the field: the scenario\'s name', fn = function()
            local s = shown('os_a', {})
            assertEqual(s.text, 'Get to the docks', 'its objective')
            assertEqual(s.name, 'Alleyway Shootout', 'the name under it')
        end },
        { name = 'The scenario\'s name', fn = function()
            assertEqual(shown('os_b', { subShown = 'name', sub = 'ignored' }).name, 'Alleyway Shootout', 'the name')
        end },
        { name = 'None: nothing under it', fn = function()
            assertEqual(shown('os_c', { subShown = 'none' }).name, nil, 'no subtext')
        end },
        { name = 'My own words', fn = function()
            assertEqual(shown('os_d', { subShown = 'other', sub = '  Before they leave  ' }).name, 'Before they leave', 'its words, trimmed')
        end },
        { name = 'My own words left empty: none', fn = function()
            assertEqual(shown('os_e', { subShown = 'other', sub = '   ' }).name, nil, 'no subtext')
        end },
        { name = '(the real PlayerText.objective back)', fn = function()
            PlayerText.objective = realObjective
            assertTrue(PlayerText.objective == realObjective, 'put back')
        end },
    },
})
