-- Check (graph.lua) and the lead-in: no dead end said before Scenario Started, a card that hands something out there
-- warned of, the Cooldown setting checked. On the real card definitions.
-- lua54 guard.lua checklead_test.lua [resources path/]   (from dev/director; default: the resources it is in)
local ROOT = arg[1] or (((arg[0] or ''):match('^(.*)[/\\]') or '.') .. '/../../../')
local CORE = ROOT .. 'whip_core/'
local realPrint = print
rawset(_G, 'GetCurrentResourceName', function() return 'whip_core' end)
rawset(_G, 'GetInvokingResource', function() return nil end)
rawset(_G, 'GetResourceState', function() return 'started' end)
rawset(_G, 'GetGameTimer', function() return 0 end)
rawset(_G, 'exports', function() end)
rawset(_G, 'AddEventHandler', function() end)
rawset(_G, 'RegisterNetEvent', function() end)
rawset(_G, 'CreateThread', function() end)
rawset(_G, 'SetTimeout', function() end)
rawset(_G, 'print', function() end)
rawset(_G, 'json', { decode = nil })
for _, g in ipairs({ 'Config', 'Npcs', 'Vehicles', 'Stores', 'Inventory', 'Money', 'Bubbles', 'Conversations', 'RuntimePoints',
                     'Zones', 'PropSets', 'Doors', 'GroundItems', 'Jobs', 'Permissions', 'Character', 'PlayerFlags', 'EmoteList',
                     'DirectorLore', 'DirectorBand', 'DirectorTakes', 'Actors', 'Audience', 'Ports', 'SecureEvent', 'SecureCallback',
                     'Items', 'Bank', 'Blips', 'Stats', 'Interactions', 'PlayerText', 'Vision', 'Guards', 'DirectorRuntime' }) do
    _G[g] = _G[g] or {}
end
dofile(CORE .. 'shared/registry.lua')
rawset(_G, 'IsDuplicityVersion', function() return true end)
dofile(CORE .. 'shared/director/kit.lua')
dofile(CORE .. 'shared/director/steps.lua')
dofile(CORE .. 'shared/director/things.lua')
rawset(_G, 'Director', {})
dofile(CORE .. 'server/director/fields.lua')
dofile(CORE .. 'server/director/effects.lua')
dofile(CORE .. 'server/director/nodes.lua')
dofile(CORE .. 'server/director/doc.lua')
dofile(CORE .. 'server/task_seq.lua')
dofile(CORE .. 'server/director/tasks.lua')
pcall(dofile, CORE .. 'server/director/routes.lua')
dofile(CORE .. 'server/director/graph.lua')
for _, f in ipairs({ 'nodes_core', 'nodes_world', 'nodes_heist', 'nodes_talk', 'nodes_props', 'nodes_tasks', 'nodes_cars',
                     'nodes_basics', 'nodes_goals', 'nodes_npcs', 'nodes_script' }) do
    local ok, err = pcall(dofile, CORE .. 'server/director/' .. f .. '.lua')
    if not ok then realPrint('load ' .. f .. ': ' .. tostring(err)) end
end

local pass, fail = 0, 0
local function ok(c, name, extra)
    if c then pass = pass + 1 else fail = fail + 1; realPrint('FAIL ' .. name .. (extra ~= nil and ('  ' .. tostring(extra)) or '')) end
end
local function doc(nodes, links, settings)
    local s = { start = { mode = 'admin' }, maxConcurrentRuns = 1, maxRunSec = 900 }
    for k, v in pairs(settings or {}) do s[k] = v end
    return { format = 2, name = 't', nodes = nodes, links = links, vars = {}, world = {}, comments = {}, settings = s }
end
local function n(id, t, props) return { id = id, type = t, v = 1, x = 0, y = 0, props = props or {} } end
local function l(id, a, ap, b, bp) return { id = id, from = { node = a, pin = ap }, to = { node = b, pin = bp or 'in' } } end
local function problems(d)
    local okc, res, list = pcall(DirectorGraph.check, d)
    if not okc then return { { severity = 'error', message = 'CHECK THREW: ' .. tostring(res) } } end
    return type(list) == 'table' and list or (type(res) == 'table' and res or {})
end
local function said(list, pattern, node)
    for _, p in ipairs(list) do
        if tostring(p.message):find(pattern) and (node == nil or p.node == node) then return true end
    end
    return false
end

ok(DirectorNodes.get('scenario.begin') ~= nil, 'the Scenario Started card is defined')
ok(DirectorNodes.get('scenario.started').title == 'Scenario Enabled', 'the entry is called Scenario Enabled')
ok(DirectorNodes.get('scenario.begin').title == 'Scenario Started By Player', 'the job\'s start is called Scenario Started By Player')

-- Without the card: a wait that goes nowhere is a dead end, as before.
local p = problems(doc({ n('s', 'scenario.started'), n('t', 'flow.wait', { seconds = 5 }) }, { l('a', 's', 'out', 't') }))
ok(said(p, 'goes nowhere', 't'), 'no Scenario Started: the wait going nowhere is said')

-- With it: the lead-in's dead ends (the first wait's other way, Not now) are not said; after Started they are.
p = problems(doc({ n('s', 'scenario.started'), n('t', 'flow.wait', { seconds = 5 }), n('b', 'scenario.begin'), n('t2', 'flow.wait', { seconds = 5 }) },
    { l('a', 's', 'out', 't'), l('b', 't', 'done', 'b'), l('c', 'b', 'started', 't2') }))
ok(not said(p, 'goes nowhere', 'b'), 'Not now going nowhere is not a dead end (a quiet end)')
ok(said(p, 'goes nowhere', 't2'), 'after Started, a wait going nowhere is said')

-- A lead-in Pay: warned. One after Started: not.
p = problems(doc({ n('s', 'scenario.started'), n('pay', 'player.pay', { amount = 100 }), n('b', 'scenario.begin'), n('w', 'scenario.succeed') },
    { l('a', 's', 'out', 'pay'), l('b', 'pay', 'out', 'b'), l('c', 'b', 'started', 'w') }))
ok(said(p, 'hands something out before Scenario Started By Player', 'pay'), 'a Pay in the lead-in is warned of')
p = problems(doc({ n('s', 'scenario.started'), n('b', 'scenario.begin'), n('pay', 'player.pay', { amount = 100 }), n('w', 'scenario.succeed') },
    { l('a', 's', 'out', 'b'), l('b', 'b', 'started', 'pay'), l('c', 'pay', 'out', 'w') }))
ok(not said(p, 'hands something out'), 'a Pay after Started is not')
-- Every card that says it gives (givesItems, handsOut), not a list of some: Drop Item, Give Car Key.
p = problems(doc({ n('s', 'scenario.started'), n('drop', 'item.drop', { item = 'food', amount = 1 }), n('b', 'scenario.begin'),
                   n('w', 'scenario.succeed') },
    { l('a', 's', 'out', 'drop'), l('b', 'drop', 'placed', 'b'), l('c', 'b', 'started', 'w') }))
ok(said(p, 'hands something out before Scenario Started By Player', 'drop'), 'a Drop Item in the lead-in is warned of')
ok(DirectorNodes.get('vehicle.dropKey').handsOut == true and DirectorNodes.get('vehicle.give').handsOut == true,
   'Give Car Key and Give Car say they hand out')

-- Cooldown: whole minutes, 0 to a week.
ok(said(problems(doc({ n('s', 'scenario.started') }, {}, { cooldownMin = 2.5 })), 'Cooldown is a whole number'), 'a cooldown of 2.5 minutes is refused')
ok(said(problems(doc({ n('s', 'scenario.started') }, {}, { cooldownMin = 99999 })), 'Cooldown is a whole number'), 'more than a week is refused')
ok(not said(problems(doc({ n('s', 'scenario.started') }, {}, { cooldownMin = 30 })), 'Cooldown'), '30 minutes is fine')

realPrint(('%d passed, %d failed'):format(pass, fail))
