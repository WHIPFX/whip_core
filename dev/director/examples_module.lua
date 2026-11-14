-- The shipped example scenarios (whip_core's server/director/examples and the whip_director_examples pack): each one,
-- its people and things placed, passes Check with no error and runs as a Test for a while without going wrong.
-- Run from whip_core/dev/director:
--   MEMCAP_MB=512 lua54 guard.lua harness.lua examples_module.lua

local here = (debug.getinfo(1, 'S').source:match('^@(.*)[/\\]') or '.')
local decode = dofile(here .. '/json_read.lua')
local ROOTS = {
    { dir = here .. '/../../server/director/examples/', name = 'whip_core' },
    { dir = here .. '/../../../whip_director_examples/scenarios/', name = 'pack' },
}
local NAMES = { 'courier', 'steal_car', 'vault' }

local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return decode(s)
end

-- (The game's makers, faked as the other modules fake them: an NPC or a car made is a number, at where it was asked.)
local made = 0
rawset(Npcs, 'spawn', function() made = made + 1 return made, 5000 + made end)
rawset(Npcs, 'get', function(id) return { id = id, coords = { x = 0.0, y = 0.0, z = 0.0 }, alive = true } end)
rawset(Vehicles, 'spawnTempFor', function() made = made + 1 return made end)
rawset(Vehicles, 'getEntity', function(id) return 900 + id end)
rawset(Vehicles, 'getDef', function(id) return { plate = 'P' .. id } end)
rawset(Vehicles, 'spotBlocked', function() return nil end)

-- (The items the examples hand out and hold, as the server's own item list has them.)
for _, item in ipairs({ 'package', 'cash', 'drill', 'gold_bar', 'lockpick', 'phone' }) do
    Config.Items[item] = Config.Items[item] or { label = item }
end

--- Every "spot" placed somewhere real (as a builder places them in the World tab), a few metres apart, and a door
--- picked off a door (its model the hash the game answers).
local function placed(doc)
    local n = 0
    for _, w in ipairs(doc.world or {}) do
        if type(w.def) == 'table' and w.def.coords == 'spot' then
            n = n + 1
            w.def.coords = { x = 100.0 + n * 4, y = 200.0, z = 30.0, heading = 0.0 }
        end
        if w.kind == 'door' and type(w.def) == 'table' and type(w.def.model) ~= 'number' then w.def.model = -1234567 end
    end
    return doc
end

local function errorsOf(doc)
    local _, probs = exports.whip_core:CheckDirectorScenario(doc)
    local out = {}
    for _, p in ipairs(probs or {}) do
        if p.severity == 'error' then out[#out + 1] = (p.node and (p.node .. ': ') or '') .. tostring(p.message) end
    end
    return out
end

local tests = {}
for _, root in ipairs(ROOTS) do
    for _, name in ipairs(NAMES) do
        tests[#tests + 1] = { name = ('%s %s: passes Check, placed'):format(root.name, name), fn = function()
            local doc = read(root.dir .. name .. '.json')
            assertNotNil(doc, 'read')
            local errs = errorsOf(placed(doc))
            assertEqual(#errs, 0, table.concat(errs, ' | '))
        end }
        tests[#tests + 1] = { name = ('%s %s: runs as a Test without going wrong'):format(root.name, name), fn = function()
            local doc = placed(read(root.dir .. name .. '.json'))
            local res, why = exports.whip_core:TestDirectorScenario(doc, { player = 1, wait = false })
            assertType(res, 'table', 'started (' .. tostring(why) .. ')')
            ---@cast res table
            for _ = 1, 40 do HarnessTick(50) end
            local now = exports.whip_core:GetDirectorTestResult(res.runId) or res
            assertNotEqual(now.outcome, 'faulted', 'faulted: ' .. tostring(now.reason))
            assertTrue(type(now.steps) == 'table' and #now.steps > 0, 'its first cards ran')
            exports.whip_core:SteerDirectorTest(res.runId, 'end')
            for _ = 1, 4 do HarnessTick(50) end
        end }
    end
end

RegisterTestModule({ category = 'The shipped example scenarios', order = 1, tests = tests })
