-- ============================================
-- Director — tasks from other resources, and what a resource keeps on a placed thing (the Director API)
-- ============================================
--
-- TASKS. A resource adds a type to the Tasks list of NPCs and cars with Whip.task (@whip_core/lib/satellite.lua),
-- one call in a shared file: on the server it sends the type as DATA (__RegisterDirectorTask, checked here and kept by
-- server/director/tasks.lua beside whip_core's), and on every game it hands in the code that plays a step
-- (client/director_tasks.lua). A run plays it as whip_core's own: the game that owns the thing runs it, a new owner
-- is sent it again, and a step that waits is done when that code says so. Its fields are a few of the kinds whip_core's
-- steps use (server/director/fields.lua's satStep), so the editor draws them, and the world builder places its point,
-- as it does theirs.
--
-- WHAT A RESOURCE KEEPS ON A THING. A resource's buttons on a thing's page and in the world builder's bubble
-- (client/director_buttons.lua) may save data of their own on it: w.def.ext[<resource>], saved with the scenario.
-- Each run that makes the thing says so (whip_core:run:thingMade, with every resource's data on it), a card of
-- that resource's reads its own with card:made(id).data, and anyone asks GetDirectorThingData.

local CORE = GetCurrentResourceName()

local NAME = '^[%a][%w_]*$'
local MAX_FIELDS = 8
local MAX_SEC = 3600

local callable, text, finite = DirectorKit.callable, DirectorKit.text, DirectorKit.number

--- A plain copy: 6 deep, 64 keys a table, text cut at 1000; nil for anything else.
local function plain(v) return DirectorKit.plain(v, { depth = 6, keys = 64, text = 1000, clean = true }) end

-- ============================================
-- A resource's task, as data, made into a task type
-- ============================================

local KINDS = { npc = true, vehicle = true }
local TIMINGS = { instant = true, timed = true, ['until'] = true, either = true }
local TARGETS = { nearest = true, trigger = true, thing = true, point = true }
-- (k, t and the time rows are every step's own; `thing` is where a target that is a placed thing keeps it.)
local RESERVED = { k = true, t = true, sec = true, giveUp = true, next = true, thing = true }

-- The fields a resource's step may have (DirectorFields' satStep): the kinds whip_core's steps use that need nothing of
-- whip_core's to read. number (`slider = true`: drawn as one, between its min and max), select (`look = 'seg'`: a row
-- of 2-4 buttons), point (one, key `at`): a place the world builder puts down, joined to its thing. target (one, key
-- `target`): the nearest player, who set the card off, a placed thing or a point, as Look At's. world: one of the
-- scenario's things.

local function options(t, f, out, min, max)
    if type(f.options) ~= 'table' or callable(f.options) or #f.options < min or #f.options > max then
        return nil, ('%s: field %s: %d to %d options'):format(t, out.key, min, max)
    end
    out.options = {}
    local seen = {}
    for j, o in ipairs(f.options) do
        local s = text(o, 30)
        if not s or s == '' or seen[s] then return nil, ('%s: field %s: option %d is not a new piece of text'):format(t, out.key, j) end
        seen[s] = true
        out.options[j] = s
    end
    if f.default ~= nil and not seen[f.default] then return nil, ('%s: field %s: its default is not one of its options'):format(t, out.key) end
    out.default = f.default or out.options[1]
    return out
end

--- One field of a resource's task, as tasks.lua keeps it, or nil and why.
local function fieldOf(t, i, f, keys)
    if type(f) ~= 'table' or callable(f) then return nil, ('%s: field %d is not a field'):format(t, i) end
    if type(f.key) ~= 'string' or not f.key:match(NAME) or #f.key > 24 then return nil, ('%s: field %d needs a key (one word)'):format(t, i) end
    if RESERVED[f.key] then return nil, ('%s: "%s" is a key every step has'):format(t, f.key) end
    if keys[f.key] then return nil, ('%s: field "%s" twice'):format(t, f.key) end
    keys[f.key] = true
    if not DirectorFields.usable(f.kind, 'satStep') then
        return nil, ('%s: field %s: kind is one of %s'):format(t, f.key, DirectorFields.namesFor('satStep'))
    end
    local out = { key = f.key, kind = f.kind, label = text(f.label, 40) or f.key, hint = text(f.hint, 80),
                  unit = text(f.unit, 8), required = f.required == true or nil }
    local k, d = f.kind, f.default
    if k == 'number' then
        out.min, out.max = finite(f.min), finite(f.max)
        if (f.min ~= nil and out.min == nil) or (f.max ~= nil and out.max == nil) then return nil, ('%s: field %s: min and max are numbers'):format(t, f.key) end
        if out.min and out.max and out.min > out.max then return nil, ('%s: field %s: min is above max'):format(t, f.key) end
        if f.slider == true then
            if not (out.min and out.max) then return nil, ('%s: field %s: a slider needs min and max'):format(t, f.key) end
            out.slider = true
            out.step = finite(f.step) or 1
            if out.step <= 0 then return nil, ('%s: field %s: step is above 0'):format(t, f.key) end
        end
        if d ~= nil then
            out.default = finite(d)
            if out.default == nil or (out.min and out.default < out.min) or (out.max and out.default > out.max) then
                return nil, ('%s: field %s: its default is not a number between min and max'):format(t, f.key)
            end
        elseif out.slider then
            out.default = out.min
        end
    elseif k == 'bool' then
        if d ~= nil and type(d) ~= 'boolean' then return nil, ('%s: field %s: its default is true or false'):format(t, f.key) end
        out.default = d == true
    elseif k == 'select' then
        if f.look == 'seg' then
            out.look = 'seg'
            return options(t, f, out, 2, 4)
        end
        return options(t, f, out, 1, 200)   -- (as a card's choice: only a guard against a resource gone wrong)
    elseif k == 'text' then
        out.max = math.min(128, math.max(1, math.tointeger(f.max) or 64))
        if d ~= nil then
            out.default = text(d, out.max)
            if out.default == nil then return nil, ('%s: field %s: its default is text'):format(t, f.key) end
        end
    elseif k == 'point' then
        -- (A step has one point, `at`: the world builder names it by the step, tasks.lua reads it by that key.)
        if f.key ~= 'at' then return nil, ('%s: a point field\'s key is "at"'):format(t) end
    elseif k == 'world' then
        if f.worldKind ~= nil then
            if type(f.worldKind) ~= 'string' or not f.worldKind:match(NAME) or #f.worldKind > 24 then
                return nil, ('%s: field %s: worldKind is a kind of placed thing (npc, vehicle, prop, spot...)'):format(t, f.key)
            end
            out.worldKind = f.worldKind
        end
    elseif k == 'target' then
        if f.key ~= 'target' then return nil, ('%s: a target field\'s key is "target"'):format(t) end
        local list = f.options ~= nil and f.options or { 'nearest', 'trigger', 'thing', 'point' }
        if type(list) ~= 'table' or callable(list) or #list == 0 then return nil, ('%s: target options are nearest, trigger, thing and point'):format(t) end
        out.options = {}
        local seen = {}
        for j, o in ipairs(list) do
            if not TARGETS[o] or seen[o] then return nil, ('%s: target option %d is nearest, trigger, thing or point'):format(t, j) end
            seen[o] = true
            out.options[j] = o
        end
        if d ~= nil and not seen[d] then return nil, ('%s: the target\'s default is not one of its options'):format(t) end
        out.default = d or out.options[1]
    end
    return out
end

--- A resource's task (Whip.task's data) as a task type, or nil and why.
local function buildTask(t, spec)
    if type(spec) ~= 'table' or callable(spec) or spec.__whipTask == nil then return nil, 'use Whip.task (@whip_core/lib/satellite.lua)' end
    if type(t) ~= 'string' or #t > 64 or not t:match('^[%a][%w_]*%.[%a][%w_]*$') then
        return nil, 'a task type is "<your namespace>.<name>", like autos.paint'
    end
    local ns = t:match('^([^.]+)')
    local label = text(spec.label, 40)
    if not label or label:match('^%s*$') then return nil, t .. ': it needs a label' end
    local def = { t = t, label = label, desc = text(spec.desc, 160), kinds = {} }

    -- Its group in the picker: one of whip_core's (move, look, fight, act, car, body, wait), else its own.
    local group = spec.group == nil and ns or spec.group
    if type(group) ~= 'string' or not group:match(NAME) or #group > 24 then return nil, t .. ': group is one word' end
    def.group = group
    if not DirectorTasks.GROUP_KEYS[group] then def.groupTitle = text(spec.groupTitle, 24) or group end

    -- What can do it. (A prop's list is a timeline every game plays from one moment by itself: not another resource's.)
    if type(spec.kinds) ~= 'table' or callable(spec.kinds) or #spec.kinds == 0 then return nil, t .. ': kinds is a list: npc, vehicle' end
    for _, k in ipairs(spec.kinds) do
        if k == 'prop' then return nil, t .. ': a prop\'s tasks are whip_core\'s only (every game plays them by itself)' end
        if not KINDS[k] then return nil, ('%s: kinds are npc and vehicle, not "%s"'):format(t, tostring(k)) end
        def.kinds[k] = true
    end

    def.timing = spec.timing == nil and 'timed' or spec.timing
    if not TIMINGS[def.timing] then return nil, t .. ': timing is instant, timed, until or either' end
    if def.timing == 'timed' or def.timing == 'either' then
        def.sec = finite(spec.sec) or 3
        if def.sec < 0.1 or def.sec > MAX_SEC then return nil, ('%s: sec is 0.1 to %d'):format(t, MAX_SEC) end
    end
    if def.timing == 'until' or def.timing == 'either' then
        def.giveUp = finite(spec.giveUp) or 30
        if def.giveUp < 1 or def.giveUp > MAX_SEC then return nil, ('%s: giveUp is 1 to %d seconds'):format(t, MAX_SEC) end
    end
    if def.timing == 'either' then
        def.next = spec.next == nil and 'done' or spec.next
        if def.next ~= 'done' and def.next ~= 'time' then return nil, t .. ": next is 'done' or 'time'" end
    end
    for _, b in ipairs({ 'lasting', 'once', 'standing' }) do
        if spec[b] ~= nil and type(spec[b]) ~= 'boolean' then return nil, ('%s: %s is true or false'):format(t, b) end
    end
    def.lasting, def.once = spec.lasting == true, spec.once == true
    def.standing = spec.standing ~= false

    if spec.fields ~= nil and (type(spec.fields) ~= 'table' or callable(spec.fields)) then return nil, t .. ': fields is a list' end
    local list = spec.fields or {}
    if #list > MAX_FIELDS then return nil, ('%s: %d fields at most'):format(t, MAX_FIELDS) end
    def.fields = {}
    local keys, point, target = {}, false, nil
    for i, f in ipairs(list) do
        local nf, why = fieldOf(t, i, f, keys)
        if not nf then return nil, why end
        if nf.kind == 'point' then point = true end
        if nf.kind == 'target' then target = nf end
        def.fields[#def.fields + 1] = nf
    end
    -- (A target that may be a point keeps it in `at`, as a point field would.)
    if point and target then
        for _, o in ipairs(target.options) do
            if o == 'point' then return nil, t .. ': a point field and a target that may be a point both keep it in "at": one of them' end
        end
    end
    return def
end

-- ============================================
-- What a resource keeps on a placed thing
-- ============================================

--- What `owner` keeps on the scenario's thing `worldId` (a copy), or nil. `graph`: a run's or a scenario's.
function Director.thingData(graph, worldId, owner)
    local w = type(graph) == 'table' and type(graph.world) == 'table' and graph.world[worldId] or nil
    local ext = type(w) == 'table' and type(w.def) == 'table' and type(w.def.ext) == 'table' and w.def.ext or nil
    if not ext or type(owner) ~= 'string' then return nil end
    return plain(ext[owner])
end

--- whip_core:run:thingMade's news of a thing made for a placed thing: what it is, what was made, and what each resource
--- keeps on it (data[<resource>]). nil for a thing the graph has not got.
local function madeNews(graph, worldId, h)
    local w = type(graph) == 'table' and type(graph.world) == 'table' and graph.world[worldId] or nil
    if type(w) ~= 'table' then return nil end
    local ext = type(w.def) == 'table' and type(w.def.ext) == 'table' and w.def.ext or nil
    -- (A car's model as made: a random vehicle's is one of its models.)
    local car = h.vehicleId and Vehicles.getDef(h.vehicleId) or nil
    return { world = worldId, kind = w.kind, label = w.label,
             netId = h.netId, npcId = h.npcId, vehicleId = h.vehicleId, containerId = h.containerId, groundId = h.groundId,
             doorId = h.doorId, model = car and car.model or nil, data = ext and plain(ext) or {} }
end

--- A car a run made for a placed thing players may stand on while it moves (its General tab: def.standOn) carries
--- VehicleData directorStandOn, which each game reads under its own player (client/director_standon.lua). (A car is
--- never standing: only a run makes one.)
local function markStandOn(graph, worldId, h)
    local w = type(graph) == 'table' and type(graph.world) == 'table' and graph.world[worldId] or nil
    if not (type(w) == 'table' and w.kind == 'vehicle' and type(w.def) == 'table' and w.def.standOn == true) then return end
    if not (type(h) == 'table' and h.vehicleId) or VehicleData.get(h.vehicleId, 'directorStandOn') == true then return end
    local ok, why = VehicleData.set(h.vehicleId, 'directorStandOn', true)
    if not ok then print(('[whip_core:director] %s: players could not be let stand on it: %s'):format(tostring(worldId), tostring(why))) end
end

--- A run made something for one of its placed things (runtime.lua CTX:remember): other resources hear it after the
--- pass, with what each keeps on it. A builder's Test too (run.test): what a resource keeps on a thing is how it comes
--- out (a car's Whiplash look), which a Test must show; a resource that must not act on a Test checks run.test.
function Director.thingMade(run, worldId, h)
    markStandOn(run.graph, worldId, h)
    local news = madeNews(run.graph, worldId, h)
    if not news then return end
    news.run = Director.view(run)
    Director.announce('run:thingMade', news)
end

--- The standing layer (Always present) made something when the scenario was switched on, or for a Test (`test`): the
--- same news, with no run (main.lua Director.build).
function Director.standingMade(sc, worldId, h, test)
    local news = madeNews(sc.graph, worldId, h)
    if not news then return end
    news.scenario, news.standing, news.test = sc.id, true, test == true or nil
    Director.announce('run:thingMade', news)
end

-- ============================================
-- Exports
-- ============================================

--- __RegisterDirectorTask(taskType, spec) -> true | false, why. Through Whip.task only: it sends the type as data
--- (its step's code stays on each game: __RegisterDirectorTaskStep there).
exports('__RegisterDirectorTask', function(taskType, spec)
    local owner = Registry.caller()
    if owner == CORE then return false, 'whip_core\'s own tasks are defined in server/director/tasks.lua' end
    local def, why = buildTask(taskType, spec)
    if not def then return false, why end
    local ok, err = DirectorNodes.claimSpace(owner, taskType:match('^([^.]+)'))
    if not ok then return false, err end
    ok, err = DirectorTasks.defineFor(owner, def)
    if not ok then return false, err end
    return true
end)

--- __RemoveDirectorTask(taskType) -> true | false, why. Only your own (they go by themselves when you stop).
exports('__RemoveDirectorTask', function(taskType)
    local owner = Registry.caller()
    if type(taskType) ~= 'string' then return false, 'taskType is the task\'s type' end
    return DirectorTasks.remove(owner, taskType)
end)

--- GetDirectorThingData(where, worldId) -> what YOU keep on a placed thing (your buttons' saves), nil when nothing is
--- saved | false, why (no such run, scenario or thing: a nil first value would lose the why across the export).
--- `where`: a run's id (that run's revision of the scenario) or a scenario's key (the revision that is on now).
exports('GetDirectorThingData', function(where, worldId)
    local owner = Registry.caller()
    if type(worldId) ~= 'string' then return false, 'worldId is the placed thing\'s id' end
    local graph
    if type(where) == 'number' then
        local run = DirectorRuntime.get(math.tointeger(where) or -1)
        if not run then return false, 'No run with that id is going' end
        graph = run.graph
    elseif type(where) == 'string' then
        local sc = Director.active[where]
        if not sc then return false, 'That scenario is not on' end
        graph = sc.graph
    else
        return false, 'where is a run\'s id or a scenario\'s key'
    end
    if not (graph and graph.world and graph.world[worldId]) then return false, ('"%s" is not one of its placed things'):format(worldId) end
    return Director.thingData(graph, worldId, owner)
end)
