-- The Haggle as hot and cold (nodes_talk.lua npc.haggle): yes / no / insult, the ruler the capsule gets, Settle, Angry,
-- and the price agreed reaching the card it is for (runtime.lua CTX:prop: a Pay's amount).
-- lua54 guard.lua haggle_test.lua [resources path/]   (from dev/director; default: the resources it is in)
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
rawset(_G, 'CreateThread', function(fn) fn() end)
rawset(_G, 'SetTimeout', function() end)
rawset(_G, 'Citizen', { CreateThreadNow = function(fn) fn() end })
rawset(_G, 'print', function() end)
rawset(_G, 'json', { decode = nil })
for _, g in ipairs({ 'Config', 'Npcs', 'Vehicles', 'Stores', 'Inventory', 'Money', 'Bubbles', 'Conversations', 'RuntimePoints',
                     'Zones', 'PropSets', 'Doors', 'GroundItems', 'Jobs', 'Permissions', 'Character', 'PlayerFlags', 'EmoteList',
                     'DirectorLore', 'DirectorBand', 'DirectorTakes', 'Actors', 'Audience', 'SecureEvent', 'SecureCallback',
                     'Items', 'Bank', 'Blips', 'Stats', 'Interactions', 'PlayerText', 'Vision', 'Guards' }) do
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
dofile(CORE .. 'server/director/runtime.lua')
for _, f in ipairs({ 'nodes_core', 'nodes_world', 'nodes_talk', 'nodes_basics' }) do
    local ok, err = pcall(dofile, CORE .. 'server/director/' .. f .. '.lua')
    if not ok then realPrint('load ' .. f .. ': ' .. tostring(err)) end
end
local R = DirectorRuntime
local now = 0
R.setPorts({ log = function() end, now = function() return now end, thread = function(fn) fn() end, threadNow = function(fn) fn() end })
for _, name in ipairs({ 'scenario.started', 'conversation.choice', 'conversation.ended' }) do R.bridge(name) end

local pass, fail = 0, 0
local function ok(c, name, extra)
    if c then pass = pass + 1 else fail = fail + 1; realPrint('FAIL ' .. name .. (extra ~= nil and ('  ' .. tostring(extra)) or '')) end
end

-- What the haggle says to the player: the last spec it sent.
---@type table
local said = nil
rawset(Director, 'playerOf', function() return 7 end)
rawset(Director, 'handleOf', function() return { netId = 5, npcId = 9 } end)
rawset(_G, 'DirectorTalk', {
    speak = function(_, _, _, _, spec) said = spec end,
    converse = function(_, _, _, spec) said = spec return 1 end,
    noAnswerAfter = function() end,
    leave = function() end,
})
rawset(Director, 'event', function() end)
rawset(DirectorNodes, 'shownName', function() return 'Irwin' end)
local paid = nil

-- A Pay card stand-in: what its amount reads (CTX:prop, the haggled price standing in).
local okd, why = DirectorNodes.define({ type = 't.paid', v = 1, category = 'player', title = 'Paid', outputs = { 'out' },
    haggle = { key = 'amount', toPlayer = true, unit = 'money' },
    props = { { key = 'amount', kind = 'number', label = 'Amount', default = 100, min = 0, max = 1000000 } },
    run = function(ctx) paid = ctx:prop('amount') return 'out' end })
assert(okd, why)

local function N(id, ty, props) return { id = id, type = ty, def = DirectorNodes.get(ty), props = props or {} } end
local function graph(hprops, payAfter)
    local n = { s = N('s', 'scenario.started'), h = N('h', 'npc.haggle', hprops), pay = N('pay', 't.paid', { amount = 100 }),
                win = N('win', 'scenario.succeed') }
    return { nodes = n, vars = {}, settings = {}, events = { ['scenario.started'] = { 's' } },
             world = { irwin = { id = 'irwin', kind = 'npc', def = {} } },
             out = { s = { out = { { node = 'h', pin = 'in' } } },
                     h = { deal = { { node = payAfter and 'pay' or 'win', pin = 'in' } }, bad = { { node = payAfter and 'pay' or 'win', pin = 'in' } } },
                     pay = { out = { { node = 'win', pin = 'in' } } } } }
end
local function settle(ms) for _ = 1, 10 do R.pass(); now = now + (ms or 50) end end
local function choose(run, option, amount)
    R.emit('conversation.choice', { runId = run.id, nodeId = 'h', convId = 1, source = 7, option = option, amount = amount })
    settle()
end

-- speakerOf needs the NPC: it is a placed thing the run has made.
local function start(props, payAfter)
    local g = graph(props, payAfter)
    local run = assert(R.start(g, { scenarioId = 'x', starter = 7 }))
    run.world.irwin = { netId = 5, npcId = 9 }
    settle()
    return run
end

-- 1. They pay: opens at 1000, limit 1500. Three asks; the ruler carries them.
local base = { npc = 'irwin', base = 1000, floor = 700, ceiling = 1500, rounds = 3, patience = 'normal' }
local run = start(base)
ok(said and said.haggle, 'the opening line carries the ruler', said and said.line)
if said and said.haggle then
    local hg = said.haggle
    ok(hg.buys == true and hg.lo <= 700 and hg.hi > 1500, 'the ruler runs past the limit', ('%s..%s'):format(hg.lo, hg.hi))
    ok(hg.left == 3 and hg.pat == 2 and hg.patMax == 2, 'three asks, two patience')
end
choose(run, 'ask', 1200)
local a = said.haggle.asks[1]
ok(a and a.r == 'yes' and a.h > 0.3 and a.h < 0.5, 'within the limit: a yes, warm', a and a.h)
ok(said.haggle.a == 1200, 'the band starts at the best yes', said.haggle.a)
choose(run, 'ask', 1700)
a = said.haggle.asks[2]
ok(a and a.r == 'no' and said.haggle.pat == 1, 'just over: a No, a patience gone', a and a.r)
ok(said.haggle.b == 1700, 'the band ends at the nearest no', said.haggle.b)
choose(run, 'ask', 1480)
a = said.haggle.asks[3]
ok(a and a.r == 'yes' and a.h >= 0.85, 'close under it: a hot yes', a and a.h)
ok(said.haggle.left == 0 and #said.options == 2, 'asks used up: settle or leave', #said.options)
choose(run, 'take')
ok(run.status == 'succeeded' or run.vars ~= nil, 'settled')
local res = nil
for _, e in ipairs(R.trace(run)) do if e.node == 'h' and (e.kind == 'out' or e.kind == 'resume') then res = e.pin end end
ok(res == 'deal', 'settled above its opening offer: Deal', res)

-- 2. An insult: its best drops to the floor, two patience gone (normal: Angry).
run = start(base)
choose(run, 'ask', 5000)
res = nil
for _, e in ipairs(R.trace(run)) do if e.node == 'h' and (e.kind == 'out' or e.kind == 'resume') then res = e.pin end end
ok(res == 'angry', 'an insult with normal patience: Angry', res)
run = start({ npc = 'irwin', base = 1000, floor = 700, ceiling = 1500, rounds = 3, patience = 'long' })
choose(run, 'ask', 5000)
ok(said.haggle.asks[1].r == 'insult' and said.haggle.pat == 1, 'an insult with long patience: two gone', said.haggle.pat)
ok(said.options[2] and said.options[2].label == 'Settle: $700', 'its best is now the floor', said.options[2] and said.options[2].label)
choose(run, 'take')
res = nil
for _, e in ipairs(R.trace(run)) do if e.node == 'h' and (e.kind == 'out' or e.kind == 'resume') then res = e.pin end end
ok(res == 'bad', 'settled under its opening offer: Bad deal', res)

-- 3. Haggling for a card: the price agreed is what the Pay pays.
paid = nil
run = start({ npc = 'irwin', forCard = 'pay', base = 1000, floor = 700, ceiling = 1500, rounds = 3, patience = 'normal' }, true)
choose(run, 'ask', 1400)
choose(run, 'take')
ok(paid == 1400, 'the Pay pays the price agreed, not its own', paid)
ok(said.haggle == nil or said.haggle.buys == true, 'a Pay: they pay the player')

realPrint(('%d passed, %d failed'):format(pass, fail))
