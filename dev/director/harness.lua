-- Offline harness: whip_core's Director (real runtime, cards, main.lua, testing.lua) under a fake scheduler, and
-- whip_test's Director modules run against it. Modules or tests that need the game (DK.ask) are skipped here.
--   lua54 harness.lua [<whip_core> <whip_test>] <module.lua> [...]   (default: the whip_core it is in, and its whip_test)
--   CHECKONLY=1   every scenario a module would run is only put through Check (for the world modules)
--   MEMCAP_MB=n   stop past n MB (1024 at most, the default): unknown names are stubs here, and a runaway must never
--                 fill the server's memory
-- A stand-in for one of whip_core's or the game's own names is set with rawset, not assigned: the editor's Lua language
-- server would take an assignment for one more definition of the real thing.
io.stdout:setvbuf("no")
local here = (arg[0] or ''):match('^(.*)[/\\]') or '.'
local CORE_ROOT, TEST_ROOT, FIRST_MODULE = arg[1], arg[2], 3
if not CORE_ROOT or CORE_ROOT:match('%.lua$') then
    CORE_ROOT, TEST_ROOT, FIRST_MODULE = here .. '/../..', here .. '/../../../whip_test', 1
end

-- ---- a memory cap: past MEM_CAP_KB the harness stops at once (a runaway must never fill the VPS) ----
-- Checked by a count hook in the main thread and in every coroutine (hooks are per coroutine in Lua 5.4).
local MEM_CAP_KB = math.min(tonumber(os.getenv('MEMCAP_MB')) or 1024, 1024) * 1024
local function memGuard()
    if collectgarbage('count') > MEM_CAP_KB then
        io.stderr:write(('HARNESS STOPPED: memory over %d MB\n'):format(MEM_CAP_KB // 1024))
        os.exit(3)
    end
end
debug.sethook(memGuard, '', 20000)
local rawCreate = coroutine.create
rawset(coroutine, 'create', function(fn)
    return rawCreate(function(...)
        debug.sethook(memGuard, '', 20000)
        return fn(...)
    end)
end)

-- ---- a catch-all world: anything unknown is a callable stub answering nil ----
-- A number key is never made up (it answers nil): a loop over a stub's list ends at once instead of making
-- stubs forever.
local stubMeta = {}
local function stub() return setmetatable({}, stubMeta) end
stubMeta.__index = function(t, k)
    if type(k) == 'number' then return nil end
    local s = stub(); rawset(t, k, s); return s
end
stubMeta.__call = function() return nil end
local realG = {}
setmetatable(_G, { __index = function(t, k)
    if realG[k] ~= nil then return realG[k] end
    local s = stub(); rawset(t, k, s); return s
end })

-- ---- the scheduler ----
local now = 1000
local threads = {}
rawset(_G, 'GetGameTimer', function() return now end)
rawset(_G, 'CreateThread', function(fn) threads[#threads + 1] = { co = coroutine.create(fn), at = now } end)
rawset(_G, 'SetTimeout', function(ms, fn) threads[#threads + 1] = { co = coroutine.create(fn), at = now + (ms or 0) } end)
rawset(_G, 'Wait', function(ms)
    local _, main = coroutine.running()
    if main then error('Wait outside a thread', 2) end
    coroutine.yield(ms or 0)
end)
rawset(_G, 'Citizen', { CreateThread = CreateThread, Wait = Wait, SetTimeout = SetTimeout,
            CreateThreadNow = function(fn) CreateThread(fn) end })
-- FiveM's promises (state 0 waiting, 1 resolved, 2 rejected), and Citizen.Await on the fake scheduler.
rawset(_G, 'promise', {})
rawset(promise, '__index', promise)
rawset(promise, 'new', function() return setmetatable({ state = 0 }, promise) end)
rawset(promise, 'resolve', function(self, v) if self.state == 0 then self.state, self.value = 1, v end end)
rawset(promise, 'reject', function(self, e) if self.state == 0 then self.state, self.value = 2, e end end)
rawset(Citizen, 'Await', function(p)
    while p.state == 0 do Wait(0) end
    if p.state == 2 then error(p.value, 2) end
    return p.value
end)
--- Where `t` is in the list now, or nil.
local function placeOf(t)
    for j = 1, #threads do if threads[j] == t then return j end end
    return nil
end

-- A test calls HarnessTick from its own thread, so this runs inside a thread it is stepping through: that one is
-- running (or 'normal', having resumed another), so it is skipped, and the list may have changed under the outer pass
-- by the time a resume returns, so a thread is found again before it is dropped.
local function resumeDue()
    local i = 1
    while i <= #threads do
        local t = threads[i]
        if t.at <= now and coroutine.status(t.co) == 'suspended' then
            local ok, ms = coroutine.resume(t.co)
            local at = placeOf(t) or i
            if not ok then
                -- A module's own hook, when it sets one. Read raw: through _G's catch-all a missing hook would be a stub,
                -- and calling it would swallow the error.
                local onError = rawget(_G, 'HARNESS_ON_ERROR')
                if onError then onError(t, ms) else print('THREAD ERROR: ' .. tostring(ms)) end
                if threads[at] == t then table.remove(threads, at) end
                i = at
            elseif coroutine.status(t.co) == 'dead' then
                if threads[at] == t then table.remove(threads, at) end
                i = at
            else
                t.at = now + (ms or 0)
                i = at + 1
            end
        else
            i = i + 1
        end
    end
end
function HarnessTick(ms)
    now = now + (ms or 50)
    resumeDue()
end
function HarnessThreads() return #threads end

-- ---- FiveM and whip bits the Director touches ----
rawset(_G, 'GetCurrentResourceName', function() return 'whip_core' end)
rawset(_G, 'IsDuplicityVersion', function() return true end)   -- (the server's side: shared files load their server half)
CALLER = 'whip_test'
rawset(_G, 'Registry', { new = function(_, o)
    local store = o.store or {}
    return {
        seed = function(_, k, v) store[k] = v end,
        add = function(_, _, k, v) store[k] = v; return true end,
        remove = function(_, _, k) store[k] = nil; return true end,
        ownerOf = function() return 'whip_core' end,
        get = function(_, k) return store[k] end,
    }
end, caller = function() return CALLER end, releaseTag = function() end, releaseTagEverywhere = function() end,
   alive = function() return true end })
setmetatable(Registry, stubMeta)
rawset(_G, 'Portraits', { MAX_LEN = 65536 })
local registered = {}
rawset(_G, 'exports', setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, _)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                local fn = registered[name]
                if not fn then error('no export ' .. tostring(name), 2) end
                return fn(...)
            end
        end })
    end,
}))
HARNESS_EXPORTS = registered
rawset(_G, 'vector3', function(x, y, z) return { x = x, y = y, z = z } end)
rawset(_G, 'vector4', function(x, y, z, w) return { x = x, y = y, z = z, w = w } end)
rawset(_G, 'Players', { [1] = { source = 1, charId = 7, fullName = 'Test Tester', userId = 3 } })
rawset(_G, 'GetPlayerName', function(s) return Players[s] and 'Tester' or nil end)
rawset(_G, 'GetPlayers', function() return { '1' } end)
rawset(_G, 'GetPlayerPed', function(s) return Players[s] and 100 + s or 0 end)
rawset(_G, 'GetEntityCoords', function() return { x = 0.0, y = 0.0, z = 0.0 } end)
rawset(_G, 'GetEntityHeading', function() return 0.0 end)
rawset(_G, 'GetPlayerRoutingBucket', function() return 0 end)
rawset(_G, 'DoesEntityExist', function() return false end)
NOTIFIED = {}
rawset(_G, 'NotifyPlayer', function(s, text, kind) NOTIFIED[#NOTIFIED + 1] = { s = s, text = text, kind = kind } end)
rawset(_G, 'TriggerClientEvent', function() end)
rawset(_G, 'TriggerLatentClientEvent', function() end)
rawset(_G, 'TriggerEvent', function() end)
rawset(_G, 'AddEventHandler', function() end)
rawset(_G, 'RegisterNetEvent', function() end)
rawset(_G, 'RegisterCommand', function() end)
HARNESS_EVENTS = {}   -- [name] = its handler: a module plays a game answering
rawset(_G, 'SecureEvent', function(name, _, fn) HARNESS_EVENTS[name] = fn end)
rawset(_G, 'SecureCallback', function() end)
rawset(_G, 'Every', function(_, ms, fn)
    CreateThread(function()
        Wait(ms)
        while true do
            local ok, n = pcall(fn)
            Wait((ok and tonumber(n)) or ms)
        end
    end)
end)
rawset(_G, 'GetResourceKvpString', function() return nil end)
rawset(_G, 'SetResourceKvp', function() end)
rawset(_G, 'print', function(...) if HARNESS_QUIET then return end io.write(table.concat({ ... }, '\t'), '\n') end)
rawset(_G, 'json', { encode = function() return '{}' end, decode = function() return nil end })
rawset(_G, 'Config', { Items = { food = { label = 'Food' }, water = { label = 'Water' } } })
rawset(_G, 'Permissions', { has = function() return true end })
-- Prop sets: nothing goes to any game here; a set is never up (wireOf).
rawset(_G, 'PropSets', setmetatable({ maxProps = function() return 256 end, wireOf = function() return nil end,
                          show = function() return true end, ready = function() return true end }, stubMeta))
-- NPCs: none made before the Director's files are read (lore_voice.lua looks at start); a module fakes the rest.
rawset(_G, 'Npcs', setmetatable({ list = function() return {} end }, stubMeta))
-- A fake pocket: counts by item ('cash' too), what a run stamped kept apart so its end can take it back.
POCKET = { cash = 250 }
STAMPED = {}
rawset(Players[1], 'inventory', {})
rawset(_G, 'Inventory', {
    give = function(_, item, n, md)
        POCKET[item] = (POCKET[item] or 0) + n
        if type(md) == 'table' and md.director then STAMPED[item] = (STAMPED[item] or 0) + n end
        return 'player'
    end,
    getItemCountAcrossContainers = function(_, item) return POCKET[item] or 0 end,
})
rawset(_G, 'CoreStop', setmetatable({ running = false }, stubMeta))
HARNESS_TAKEBACK = function()
    for item, n in pairs(STAMPED) do POCKET[item] = (POCKET[item] or 0) - n end
    STAMPED = {}
end
rawset(_G, 'PlayerFlags', { validName = function(n) return type(n) == 'string' and n:match('^[%a][%w_.:%-]*$') ~= nil end, get = function() return nil end })

local files = { 'shared/emote_list.lua', 'shared/gta_weapons.lua', 'shared/gta_weapon_models.lua', 'shared/weapon_catalog.lua',
  'shared/skillcheck.lua', 'shared/take_track.lua', 'shared/director/kit.lua', 'shared/director/steps.lua', 'shared/director/things.lua',
  'server/director/core.lua', 'server/director/fields.lua', 'server/director/effects.lua', 'server/director/nodes.lua', 'server/director/doc.lua', 'server/director/tasks.lua', 'server/director/refs.lua', 'server/director/routes.lua',
  'server/director/graph.lua', 'server/director/runtime.lua', 'server/director/band.lua', 'server/director/spots.lua',
  'server/director/talk.lua', 'server/director/nodes_core.lua', 'server/director/nodes_world.lua', 'server/director/nodes_heist.lua',
  'server/director/nodes_talk.lua', 'server/director/nodes_props.lua', 'server/director/nodes_tasks.lua',
  'server/director/guards.lua', 'server/director/nodes_cars.lua', 'server/director/nodes_basics.lua',
  'server/director/nodes_goals.lua', 'server/director/nodes_conditions.lua', 'server/director/nodes_npcs.lua',
  'server/director/nodes_script.lua', 'server/director/nodes_weapons.lua', 'server/director/lore.lua',
  'server/director/lore_voice.lua', 'server/director/takes.lua',
  'server/director/main.lua', 'server/director/commands.lua', 'server/director/npctests.lua', 'server/director/hub.lua', 'server/director/api.lua',
  'server/director/cards_api.lua', 'server/director/satellite_api.lua', 'server/director/testing.lua',
  'server/director/live.lua' }
-- (store.lua and packs.lua are the database's: stubs here, as the world is.)
HARNESS_QUIET = true
for _, f in ipairs(files) do
    local ok, err = pcall(dofile, CORE_ROOT .. '/' .. f)
    if not ok then io.stderr:write('LOAD ' .. f .. ': ' .. tostring(err) .. '\n') end
end
HARNESS_QUIET = false
-- (The start-up thread that reads the store never ran here: on.)
CreateThread(function() Wait(0) Director.off = nil end)
for _ = 1, 5 do HarnessTick(10) end
Director.off = nil
-- The Director's own pass, as main.lua's Every and wake would run it.
local R = DirectorRuntime
R.setPorts({ now = function() return now end, wake = function() end,
             onEnd = function(run, outcome, reason) Director.runEnded(run, outcome, reason) end,
             log = function(t) if os.getenv('DLOG') then io.write('[run] ', tostring(t), '\n') end end })
CreateThread(function() while true do pcall(R.pass) Wait(50) end end)

-- ---- whip_test's runner, as the modules see it ----
local asserts = 0
local function fail(label, msg) error({ assert = true, msg = (label and (label .. ': ') or '') .. msg }, 3) end
local function show(v) if type(v) == 'string' then return ('%q'):format(v) end return tostring(v) end
function _G.assertEqual(a, e, l) asserts = asserts + 1 if a ~= e then fail(l, ('expected %s, got %s'):format(show(e), show(a))) end end
function _G.assertNotEqual(a, e, l) asserts = asserts + 1 if a == e then fail(l, ('expected not %s'):format(show(e))) end end
function _G.assertType(v, t, l) asserts = asserts + 1 if type(v) ~= t then fail(l, ('expected a %s, got %s'):format(t, type(v))) end end
function _G.assertNotNil(v, l) asserts = asserts + 1 if v == nil then fail(l, 'expected a value, got nil') end end
function _G.assertNil(v, l) asserts = asserts + 1 if v ~= nil then fail(l, 'expected nil, got ' .. show(v)) end end
function _G.assertTrue(v, l) asserts = asserts + 1 if not v then fail(l, 'expected true, got ' .. show(v)) end end
function _G.assertFalse(v, l) asserts = asserts + 1 if v then fail(l, 'expected false, got ' .. show(v)) end end
function _G.assertGt(v, t, l) asserts = asserts + 1 if not (v > t) then fail(l, ('expected more than %s, got %s'):format(show(t), show(v))) end end
function _G.assertGte(v, t, l) asserts = asserts + 1 if not (v >= t) then fail(l, ('expected at least %s, got %s'):format(show(t), show(v))) end end
function _G.skip(reason) error({ skip = true, msg = reason }, 2) end
function _G.waitFor(fn, ms)
    local deadline = GetGameTimer() + (ms or 5000)
    while GetGameTimer() < deadline do
        local v = fn()
        if v then return v end
        Wait(50)
    end
    return nil
end
local modules = {}
function RegisterTestModule(m) modules[#modules + 1] = m end
-- The client half is not here: a test that asks the game is skipped.
HARNESS_OFFLINE = true
registered.GetPlayer = function(s) return Players[s] end
-- (As the real export: what a run handed out is not the player's to count.)
registered.GetItemCount = function(_, item) return (POCKET[item] or 0) - (STAMPED[item] or 0) end
-- Every stack, a run's too: one slot an item, in the pockets.
registered.GetInventory = function()
    local slots, i = {}, 0
    for item, n in pairs(POCKET) do
        if item ~= 'cash' and n > 0 then i = i + 1; slots[i] = { item = item, amount = n } end
    end
    return { player = slots }
end
registered.GetPlayerCash = function() return POCKET.cash or 0 end
rawset(DirectorEffects, 'takeBack', function() HARNESS_TAKEBACK() return 0 end)

dofile(TEST_ROOT .. '/server/director_kit.lua')
-- CHECKONLY: every scenario a module would run is put through Check and its errors printed (the world is not here);
-- the test then ends at once.
if os.getenv('CHECKONLY') then
    HARNESS_OFFLINE = false
    ---@diagnostic disable-next-line: undefined-global -- DK is whip_test's (director_kit.lua, read above)
    DK.toField = function() return DK.FIELD end
    ---@diagnostic disable-next-line: undefined-global -- DK is whip_test's
    DK.goHome = function() end
    ---@diagnostic disable-next-line: undefined-global -- DK is whip_test's
    DK.ask = function() return nil, false end
    ---@diagnostic disable-next-line: undefined-global -- DK is whip_test's
    DK.teleport = function(_, at) return at end
    CHECKED = { docs = 0, bad = 0 }
    registered.TestDirectorScenario = function(doc)
        CHECKED.docs = CHECKED.docs + 1
        local _, probs = registered.CheckDirectorScenario(doc)
        local errs = {}
        for _, p in ipairs(probs or {}) do
            if p.severity == 'error' and not p.live then errs[#errs + 1] = (p.node and (p.node .. ': ') or '') .. tostring(p.message) end
        end
        if #errs > 0 then
            CHECKED.bad = CHECKED.bad + 1
            print('      CHECK ERRORS: ' .. table.concat(errs, ' | '))
        end
        return { runId = -1, status = 'checked', done = true, steps = {}, fired = {}, entered = {}, things = {}, made = {}, vars = {}, waiting = {} }
    end
    -- (Asserts say nothing here: only Check's errors count. A test still goes on to its next scenario.)
    for _, name in ipairs({ 'assertEqual', 'assertNotEqual', 'assertType', 'assertNotNil', 'assertNil', 'assertTrue', 'assertFalse', 'assertGt', 'assertGte' }) do
        _G[name] = function() asserts = asserts + 1 end
    end
    _G.waitFor = function(fn) return fn() end
    GetDirectorTestResult = nil
    registered.GetDirectorTestResult = function() return { runId = -1, status = 'checked', done = true, steps = {}, fired = {}, entered = {}, things = {}, made = {}, vars = {}, waiting = {} } end
    registered.SteerDirectorTest = function() return true end
    registered.AddItem = function() return 'player' end
    rawset(_G, 'MySQL', { insert = { await = function() return 4242 end }, query = { await = function() return {} end } })
end
for i = FIRST_MODULE, #arg do dofile(arg[i]) end
table.sort(modules, function(a, b) return (a.order or 99) < (b.order or 99) end)

-- ---- run them ----
local pass, failed, skipped = 0, 0, 0
local function runInThread(fn, ...)
    local args = table.pack(...)
    local res = { done = false }
    threads[#threads + 1] = { at = now, co = coroutine.create(function()
        local ok, err = pcall(fn, table.unpack(args, 1, args.n))
        res.ok, res.err, res.done = ok, err, true
    end) }
    local guard = 0
    while not res.done do
        HarnessTick(50)
        guard = guard + 1
        if guard > 200000 then res.ok, res.err, res.done = false, 'harness: never finished', true end
    end
    return res.ok, res.err
end
local only = os.getenv('ONLY')
for _, m in ipairs(modules) do
    print(('== %s'):format(m.category))
    local ctx = {}
    local okS, errS = true, nil
    if m.setup then okS, errS = runInThread(m.setup, 1, ctx) end
    if not okS then
        local e = type(errS) == 'table' and errS or { msg = tostring(errS) }
        print(('   SETUP %s: %s'):format(e.skip and 'SKIP' or 'FAIL', tostring(e.msg)))
    else
        for _, t in ipairs(m.tests) do
            if not only or t.name:find(only, 1, true) then
                asserts = 0
                NOTIFIED = {}
                local ok, err = runInThread(t.fn, 1, ctx)
                local e = type(err) == 'table' and err or { msg = tostring(err) }
                if ok and asserts == 0 then ok, e = false, { msg = 'no asserts' } end
                if ok then pass = pass + 1 print('   ok   ' .. t.name)
                elseif e.skip then skipped = skipped + 1 print('   skip ' .. t.name .. '  (' .. tostring(e.msg) .. ')')
                else failed = failed + 1 print('   FAIL ' .. t.name .. '\n        ' .. tostring(e.msg)) end
                -- (Between tests: a run left going ends by its own time; let the scheduler settle.)
                for _ = 1, 4 do HarnessTick(50) end
            end
        end
    end
    if m.teardown then runInThread(m.teardown, ctx, 1) end
end
print(('%d passed, %d failed, %d skipped'):format(pass, failed, skipped))
if rawget(_G, 'CHECKED') then print(('CHECKONLY: %d scenarios checked, %d with errors'):format(CHECKED.docs, CHECKED.bad)) end
