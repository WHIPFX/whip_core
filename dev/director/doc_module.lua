-- DirectorDoc.load (server/director/doc.lua), the one way a document is read: its format (one from before the
-- Director's rebuild refused, never half-read), its lists, a card's own upgrade from an older version of itself (and
-- one that cannot be), the original never changed; and every way in uses it (Check, activation, a test's build).
-- Run from whip_core/dev/director:
--   MEMCAP_MB=256 lua54 guard.lua harness.lua doc_module.lua

local F = DirectorDoc.FORMAT
local function doc(nodes, extra)
    local d = { format = F, name = 'Doc', description = '', vars = {}, comments = {}, world = {}, nodes = nodes or {}, links = {},
                settings = { start = { mode = 'admin' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 } }
    for k, v in pairs(extra or {}) do d[k] = v end
    return d
end
local function n(id, t, props, v) return { id = id, type = t, v = v or 1, x = 0, y = 0, props = props or {} } end

-- A card that changed shape: version 2 keeps its words in `text`, version 1 kept them in `words`.
DirectorKit.define({
    type = 'test.reshaped', v = 2, category = 'flow', title = 'Reshaped', outputs = { 'out' },
    props = { { key = 'text', kind = 'text', label = 'Text' } },
    upgrade = function(props, from)
        if from < 2 then return { text = props.words } end
        return props
    end,
    run = function() return 'out' end,
})
DirectorKit.define({
    type = 'test.brokenup', v = 3, category = 'flow', title = 'Broken upgrade', outputs = { 'out' },
    upgrade = function() error('no way back') end,
    run = function() return 'out' end,
})

RegisterTestModule({
    category = 'Reading a document (DirectorDoc.load)', order = 1,
    tests = {
        { name = 'this format: read, a copy', fn = function()
            local raw = doc({ n('s', 'scenario.started') })
            local d, why = DirectorDoc.load(raw)
            assertNotNil(d, why)
            ---@cast d -nil
            assertTrue(d ~= raw and d.nodes ~= raw.nodes, 'a copy')
            assertEqual(d.nodes[1].type, 'scenario.started', 'its cards')
        end },
        { name = 'format 1 (from before the rebuild): refused, said why', fn = function()
            local d, why = DirectorDoc.load({ format = 1, name = 'Old', nodes = {} })
            assertNil(d, 'not read')
            assertTrue(type(why) == 'string' and why:find('before the Director was rebuilt', 1, true) ~= nil, why)
        end },
        { name = 'another format, or not a table: refused', fn = function()
            assertNil((DirectorDoc.load({ format = 99 })), 'format 99')
            assertNil((DirectorDoc.load('nope')), 'text')
        end },
        { name = 'a list that is not one: refused', fn = function()
            local d, why = DirectorDoc.load(doc({}, { links = 'oops' }))
            assertNil(d, 'not read')
            ---@cast why -nil
            assertTrue(why:find('links are not a list', 1, true) ~= nil, why)
        end },
        { name = 'a card saved older: its own upgrade brings it up to date; the original untouched', fn = function()
            local raw = doc({ n('r', 'test.reshaped', { words = 'hello' }, 1) })
            local d = DirectorDoc.load(raw) --[[@as table]]
            assertEqual(d.nodes[1].props.text, 'hello', 'its words where version 2 keeps them')
            assertEqual(d.nodes[1].v, 2, 'its version now')
            assertEqual(raw.nodes[1].props.words, 'hello', 'the original not changed')
            assertEqual(raw.nodes[1].v, 1, 'the original\'s version not changed')
        end },
        { name = 'a card already this version: left as it is', fn = function()
            local d = DirectorDoc.load(doc({ n('r', 'test.reshaped', { text = 'hi' }, 2) })) --[[@as table]]
            assertEqual(d.nodes[1].props.text, 'hi', 'kept')
        end },
        { name = 'a variant\'s cards upgraded too', fn = function()
            local d = DirectorDoc.load(doc({}, { variants = { { id = 'v2', nodes = { n('r', 'test.reshaped', { words = 'v' }, 1) }, links = {} } } })) --[[@as table]]
            assertEqual(d.variants[1].nodes[1].props.text, 'v', 'upgraded in the variant')
        end },
        { name = 'an upgrade that fails: Check says so, as an error', fn = function()
            local d, _, stale = DirectorDoc.load(doc({ n('b', 'test.brokenup', {}, 1) }))
            assertNotNil(d, 'still read')
            assertTrue(stale and stale[1]:find('could not be brought up to version 3', 1, true) ~= nil, stale and stale[1])
            local ok, problems = DirectorGraph.check(doc({ n('b', 'test.brokenup', {}, 1) }))
            assertFalse(ok, 'Check refuses it')
            assertTrue(problems[1] and problems[1].message:find('could not be brought up', 1, true) ~= nil, problems[1] and problems[1].message)
        end },
        { name = 'every way in reads it: Check, switching on and a test\'s build refuse format 1', fn = function()
            local old = { format = 1, name = 'Old', nodes = {}, links = {}, world = {}, vars = {} }
            local okC, probs = DirectorGraph.check(old)
            assertFalse(okC, 'Check')
            assertTrue(probs[1].message:find('before the Director was rebuilt', 1, true) ~= nil, probs[1].message)
            local okA, res = Director.activate('doc_old', old, { rev = 1 })
            assertFalse(okA, 'switching on')
            assertTrue(type(res) == 'table' and res[1].message:find('before the Director', 1, true) ~= nil, 'said why')
            local sc, why = Director.build('doc_old', old, { prefix = 'test' })
            assertFalse(sc, 'a test\'s build')
            assertTrue(type(why) == 'string' and why:find('before the Director', 1, true) ~= nil, why)
        end },
    },
})
