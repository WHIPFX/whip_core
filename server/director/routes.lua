-- Routes: the points an NPC walks, placed in the world builder, each with an optional wait.
--   w.def = { points = { { k, at = { x, y, z, heading }, wait = seconds, act = 'stand' | 'look' | 'emote' |
--             'scenario', emote, scenario } }, order = 'loop' | 'once' | 'pingpong' | 'random', pace = 'walk' | 'run',
--             findWay = true (GTA pathfinds between points; else a straight line) }
-- An NPC walks one with the Walk a Route task (tasks.lua). A route is compiled to task steps when the NPC is made.
-- Each Go To carries its drawn point (`leg`): an NPC on that line walks straight (client/npcs.lua), one off it
-- pathfinds to the point first. At random never draws the lines: it always pathfinds.

DirectorRoutes = {}

local MAX_POINTS  = 24
local RANDOM_LAPS = 4          -- a random round visits each point about this many times before it repeats
local LOOSE_M     = 1.5        -- how far "loosely" moves a point, at most
local TURN_MS     = 1000       -- a stop with something to do turns to its point's way first
local LOOK_SCENARIO = 'WORLD_HUMAN_GUARD_STAND'
local PACE_MPS    = { walk = 1.2, run = 3.5 }

local finite, coords, dist = DirectorKit.finite, DirectorKit.place, DirectorKit.dist

--- A route's points that are placed, in order: { { at, wait, act, emote, scenario, n = its number } }.
local function pointsOf(w)
    local out = {}
    local list = type(w) == 'table' and type(w.def) == 'table' and w.def.points or nil
    for i, p in ipairs(type(list) == 'table' and list or {}) do
        local at = type(p) == 'table' and coords(p.at) or nil
        if at and #out < MAX_POINTS then
            local wait = tonumber(p.wait)
            out[#out + 1] = { at = at, n = i, wait = finite(wait) and math.max(0, math.min(600, wait)) or 0,
                              act = p.act, emote = p.emote, scenario = p.scenario }
        end
    end
    return out
end

--- The order the points are visited in, one round (indexes into pts), and whether the round goes again.
--- `once`: one time round, for a task list (at random: each point about once).
local function visits(n, order, rand, once)
    local seq = {}
    if order == 'pingpong' and n > 2 then
        for i = 1, n do seq[#seq + 1] = i end
        for i = n - 1, once and 1 or 2, -1 do seq[#seq + 1] = i end   -- (once: back to where it started)
        return seq, 'loop'
    elseif order == 'random' and n > 2 then
        -- Each next point is any but the current one.
        local last = nil
        for _ = 1, n * (once and 1 or RANDOM_LAPS) do
            local i = rand(n - (last and 1 or 0))
            if last and i >= last then i = i + 1 end
            seq[#seq + 1] = i
            last = i
        end
        if seq[#seq] == seq[1] then seq[#seq] = nil end   -- (round again: never the same one twice)
        return seq, 'loop'
    end
    for i = 1, n do seq[#seq + 1] = i end
    return seq, (order == 'once' or n == 1) and 'stop' or 'loop'
end

--- A point moved a little for "loosely" (the move is in the step, so every game agrees).
local function loosen(at, rand)
    local a = rand(360) * math.pi / 180.0
    local r = LOOSE_M * rand(100) / 100.0
    return { x = at.x + math.cos(a) * r, y = at.y + math.sin(a) * r, z = at.z, heading = at.heading }
end

--- The steps of a stop: a wait facing the point's way, or that turn and then what it does there.
local function stopSteps(p, k, steps)
    local ms = math.floor(p.wait * 1000)
    if ms <= 0 then return end
    local h = p.at.heading
    local anim
    if p.act == 'look' then
        anim = { t = 'scenario', p = { scenario = LOOK_SCENARIO } }
    elseif p.act == 'scenario' and type(p.scenario) == 'string' and p.scenario:match('^[%w_]+$') then
        anim = { t = 'scenario', p = { scenario = p.scenario } }
    elseif p.act == 'emote' and type(p.emote) == 'string' and DirectorTasks.emoteAnim then
        local a = DirectorTasks.emoteAnim(p.emote)
        if a then anim = { t = 'emote', p = { emote = p.emote, anim = a } } end
    end
    if not anim or ms <= TURN_MS then
        steps[#steps + 1] = { k = k .. 'w', t = 'wait', timing = 'timed', ms = ms, p = { heading = h } }
        return
    end
    steps[#steps + 1] = { k = k .. 't', t = 'wait', timing = 'timed', ms = TURN_MS, p = { heading = h } }
    steps[#steps + 1] = { k = k .. 'a', t = anim.t, timing = 'timed', ms = ms - TURN_MS, p = anim.p, lasting = true }
end

--- A route as an NPC's patrol: { steps, after } for Npcs.setIdleTasks, or nil and why.
---@param w table          the route (the World tab's thing)
---@param opts table|nil   { loose = true, once = true (one time round: a task), rand = fn(n) -> 1..n (math.random) }
function DirectorRoutes.plan(w, opts)
    opts = opts or {}
    if type(w) ~= 'table' or w.kind ~= 'route' then return nil, 'that is not a route' end
    local pts = pointsOf(w)
    if #pts == 0 then return nil, 'its route has no points placed yet' end
    local rand = opts.rand or math.random
    local pace = type(w.def) == 'table' and w.def.pace == 'run' and 'run' or 'walk'
    local order = type(w.def) == 'table' and w.def.order or 'loop'
    local seq, after = visits(#pts, order, rand, opts.once)
    if opts.once then after = 'stop' end
    local straight = order ~= 'random' and not (type(w.def) == 'table' and w.def.findWay == true)
    local steps = {}
    local prev = pts[seq[#seq]].at   -- (for the first leg: the round's last point; the NPC may be anywhere)
    for v, i in ipairs(seq) do
        local p = pts[i]
        local at = opts.loose and loosen(p.at, rand) or p.at
        local giveUp = math.floor(math.max(v == 1 and 30000 or 15000, dist(prev, at) / PACE_MPS[pace] * 2500 + 5000))
        local k = ('%d.%d'):format(v, p.n)
        -- The first point has a drawn line only when the route goes round.
        local leg = (v > 1 or order ~= 'once') and { x = prev.x, y = prev.y, z = prev.z } or nil
        steps[#steps + 1] = { k = k, t = 'goTo', timing = 'until', giveUpMs = giveUp,
                              p = { at = at, pace = pace, straight = straight and leg ~= nil, leg = straight and leg or nil } }
        stopSteps(p, k, steps)
        prev = at
    end
    return { steps = steps, after = after }
end

--- Does its task list walk a route (Walk a Route)?
local function tasksWalk(def)
    local list = type(def.tasks) == 'table' and def.tasks.list or nil
    for _, s in ipairs(type(list) == 'table' and list or {}) do
        if type(s) == 'table' and DirectorSteps.is(s.t, 'route') then return true end
    end
    return false
end

--- An NPC's own definition as Npcs.spawn takes it: one that walks a route by its tasks must be able to move.
function DirectorRoutes.npcDef(def)
    local d = {}
    for k, v in pairs(type(def) == 'table' and def or {}) do d[k] = v end
    if tasksWalk(d) then
        local c = {}
        for k, v in pairs(type(d.conditions) == 'table' and d.conditions or {}) do c[k] = v end
        c.canMove = true
        d.conditions = c
    end
    return d
end

-- ============================================
-- Check (graph.lua): a route
-- ============================================

--- { { severity, why } } for one placed thing.
function DirectorRoutes.problems(w)
    local out = {}
    local def = type(w) == 'table' and type(w.def) == 'table' and w.def or {}
    local function add(sev, why) out[#out + 1] = { severity = sev, why = why } end
    if w.kind == 'route' then
        local n, placed = 0, #pointsOf(w)
        for _ in ipairs(type(def.points) == 'table' and def.points or {}) do n = n + 1 end
        if n == 0 then add('warning', 'it has no points yet (+ Point, on its page)')
        elseif placed < n then add('warning', ('%d of its %d points are not placed: they are passed over'):format(n - placed, n)) end
        if n > MAX_POINTS then add('warning', ('a route walks %d points at most'):format(MAX_POINTS)) end
        for _, p in ipairs(type(def.points) == 'table' and def.points or {}) do
            if type(p) == 'table' and (tonumber(p.wait) or 0) > 0 then
                if p.act == 'emote' and DirectorTasks.emoteAnim and not DirectorTasks.emoteAnim(tostring(p.emote or '')) then
                    add('error', ('a point plays "%s", which is not an emote with an animation (see /e)'):format(tostring(p.emote or '')))
                elseif p.act == 'scenario' and not tostring(p.scenario or ''):match('^[%w_]+$') then
                    add('error', 'a point plays a scenario: a GTA name, like WORLD_HUMAN_SMOKING')
                end
            end
        end
    end
    return out
end
