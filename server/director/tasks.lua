-- ============================================
-- Director — tasks: what a placed thing does, one step after another
-- ============================================
--
-- An NPC, a car or a prop of the World tab can have a TASK LIST (its page: Tasks): go to a point, play
-- an emote, look at the player, get in a car and drive off, slide a crate across the floor. A card
-- starts it (Spawn NPC's "Start its tasks", Start Tasks) and it runs top to bottom, then stops or
-- starts again. A standing NPC (always there, no run) plays its own by itself whenever nothing else has it
-- (server/director/nodes_tasks.lua playStanding), passing over what needs a run (a step's standingSkip).
-- Menyoo's Spooner task sequences are where the idea comes from (whip_scenes plays those for filming); these are
-- played the networked way:
--
--   an NPC   its brain carries the step (server/npcs.lua): whichever player's game owns the ped runs
--            it, says it applied it, and says when a step that waits for something is done. A new
--            owner is sent the step again and carries on.
--   a car    the same, through Actors (server/actors.lua): the car's owner runs the step.
--   a prop   every game makes its own copy, so every game plays the same timeline from the same
--            moment (the server's clock: client/clock.lua), and says it has it (server/prop_sets.lua).
--
-- THE SAVED SHAPE (the scenario's world thing): def.tasks = { list = { step, ... }, after = 'stop' |
-- 'loop', fight = true|false }. A step is { k = '<key>', t = '<type>', <its fields> }: `k` is a short
-- key that stays put while steps move up and down (the world builder names a step's point by it).
--
-- THE STEPS THEMSELVES (their fields, timing, and how each behaves) are shared/director/steps.lua's DirectorSteps,
-- read on both sides. This file adds other resources' steps (Whip.task), hands the editor the catalogue, and reads a
-- saved list into the steps the brain plays (compile).

DirectorTasks = {}

local MAX_STEPS = DirectorSteps.MAX_STEPS
local MAX_SEC   = DirectorSteps.MAX_SEC
local NO_END_MS = DirectorSteps.NO_END_MS
local TYPES, ORDER, GROUPS = DirectorSteps.TYPES, DirectorSteps.ORDER, DirectorSteps.GROUPS
local SEAT_N, STYLE_N = DirectorSteps.SEAT_N, DirectorSteps.STYLE_N

-- ============================================
-- Tasks from other resources (Whip.task; server/director/satellite_api.lua checks them)
-- ============================================
--
-- A resource's type is '<its namespace>.<name>' and sits beside whip_core's, owned by that resource and gone when it
-- stops (shared/registry.lua). Its step is sent to the game that owns the thing as whip_core's are, and played there
-- by that resource's own code (client/director_tasks.lua). A list naming one that is not here now says so on Check,
-- and a run passes it over.

local SAT = {}   -- [type] = def, another resource's

--- The editor's catalogue moved: every open editor asks for it again (cards_api.lua's push, after this tick).
local function satChanged()
    DirectorNodes.rev = DirectorNodes.rev + 1
    Director.catalogueChanged()
end

local SatTypes = Registry.new('directorTask', {
    label = 'Director task', store = SAT,
    -- (Every registration replaces: its fields may have changed.)
    same = false,
    onAdd = satChanged,
    onRemove = satChanged,
})

--- whip_core's own groups, by key (a resource's task may go in one, or in its own).
DirectorTasks.GROUP_KEYS = {}
for _, g in ipairs(GROUPS) do DirectorTasks.GROUP_KEYS[g.key] = true end

--- Add, or change, another resource's task type (satellite_api.lua builds `def`): refused when the type is
--- someone else's.
---@return boolean ok
---@return string|nil why
function DirectorTasks.defineFor(owner, def)
    if TYPES[def.t] then return false, ('"%s" is whip_core\'s own task'):format(def.t) end
    def.owner, def.satellite = owner, true
    local ok, why = SatTypes:add(owner, def.t, def)
    return ok, why --[[@as string|nil]]
end

--- Take one of `owner`'s task types away (never anyone else's).
function DirectorTasks.remove(owner, t) return SatTypes:remove(owner, t) end

--- What a STANDING NPC passes over in its list, and why (nil: it plays it).
function DirectorTasks.standingSkip(t)
    local why = DirectorSteps.is(t, 'standingSkip')
    if why then return why end
    local d = SAT[t]
    if d and d.standing == false then return ('%s needs a run (%s says so)'):format(d.label, d.owner) end
    return nil
end

--- A step type a saved list may hold ({ label, fields, ... }) by its name, whip_core's or a running resource's, or
--- nil (the brain's own internal steps are never saved). To read: never changed.
function DirectorTasks.get(t)
    local d = TYPES[t]
    if d then return not d.internal and d or nil end
    return SAT[t]
end

local function wireType(d)
    local kinds = {}
    for k in pairs(d.kinds) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    return { t = d.t, label = d.label, group = d.group, kinds = kinds, timing = d.timing,
             next = d.next, sec = d.sec, giveUp = d.giveUp, lasting = d.lasting == true,
             fields = d.fields, untilWhen = d.untilWhen, owner = d.owner, desc = d.desc,
             doneText = d.doneText, secLabel = d.secLabel, length = d.length == true, startSec = d.startSec }
end

--- The catalogue for the editor: plain data, in picker order (whip_core's, then other resources' by name, each in
--- its group: one of whip_core's, or its own after them).
function DirectorTasks.wire()
    local types, groups = {}, {}
    for _, g in ipairs(GROUPS) do groups[#groups + 1] = g end
    for _, t in ipairs(ORDER) do types[#types + 1] = wireType(TYPES[t]) end
    local names, own = {}, {}
    for t in pairs(SAT) do names[#names + 1] = t end
    table.sort(names)
    for _, t in ipairs(names) do
        local d = SAT[t]
        types[#types + 1] = wireType(d)
        if not DirectorTasks.GROUP_KEYS[d.group] and not own[d.group] then
            own[d.group] = true
            groups[#groups + 1] = { key = d.group, title = d.groupTitle or d.group }
        end
    end
    return { groups = groups, types = types, max = MAX_STEPS }
end

-- ============================================
-- Reading a saved list
-- ============================================

local finite, coords = DirectorKit.finite, DirectorKit.place

--- A step's time in ms, from what is saved (`v`, seconds; unset: its type's `default`, as it always played). 0 is no end
--- (NO_END_MS: it goes on until its list is stopped), or at once for one that is one action (`length`).
--- shared/director/steps.lua THE TIMING.
local function msOf(v, default, length)
    local n = tonumber(v)
    if not finite(n) then n = tonumber(default) or 0 end
    if n <= 0 then return length and 0 or NO_END_MS end
    return math.floor(math.max(0.1, math.min(MAX_SEC, n + 0.0)) * 1000)
end

-- whip_core's own steps: each field of a kind a step may have, each `when` one the language reads (DirectorFields), or
-- the file is refused as it loads.
for _, t in ipairs(ORDER) do
    local d = TYPES[t]
    for _, f in ipairs(d.fields) do
        assert(DirectorFields.usable(f.kind, 'step'), ('[whip_core:director] step %s: field %s has kind %s, not one a step has (%s)')
            :format(t, f.key, tostring(f.kind), DirectorFields.namesFor('step')))
        assert(f.when == nil or not DirectorFields.whenProblem(f.when), ('[whip_core:director] step %s: field %s: %s')
            :format(t, f.key, tostring(f.when and DirectorFields.whenProblem(f.when))))
    end
    assert(d.untilWhen == nil or not DirectorFields.whenProblem(d.untilWhen), ('[whip_core:director] step %s: untilWhen: %s')
        :format(t, tostring(d.untilWhen and DirectorFields.whenProblem(d.untilWhen))))
end

--- Does a field count for this step: one with a `when` only while it holds (DirectorFields.holds).
local function fieldShown(def, raw, f) return DirectorFields.holds(f.when, raw, def.fields) end

--- A step's own checks beyond its fields (its catalogue's problem: a name the game must know).
local function stepProblem(d, p)
    return d.problem and d.problem(p) or nil
end


--- What a target field resolves at run time needs: a thing (`thing`) or a point (`at`).
local function targetExtra(raw, p, world)
    if p.target == 'thing' then
        local v = raw.thing
        if type(v) ~= 'string' or v == '' or not (world and world[v]) then return 'has no placed thing picked' end
        p.thing = v
    elseif p.target == 'point' then
        local c = coords(raw.at)
        if not c then return 'has no point placed in the world' end
        p.at = c
    end
    return nil
end

--- A thing's task list as the server plays it: { steps, after, fight }, plus the problems found (a step
--- with one is left out). `kind` is the thing's ('npc', 'vehicle', 'prop'); `world` the scenario's
--- [id] = thing, for the fields that name one; `owner` the thing itself (a car's take is one of its own).
---@return table|nil plan  nil when it has no steps to play
---@return table problems  { { i = step number, label, why } }
function DirectorTasks.compile(kind, tasks, world, owner)
    local problems = {}
    if type(tasks) ~= 'table' or type(tasks.list) ~= 'table' then return nil, problems end
    local steps = {}
    for i, raw in ipairs(tasks.list) do
        if i > MAX_STEPS then
            problems[#problems + 1] = { i = i, label = 'Task', why = ('a list is at most %d tasks'):format(MAX_STEPS) }
            break
        end
        local d = type(raw) == 'table' and DirectorTasks.get(raw.t) or nil
        if not d then
            local t = tostring(type(raw) == 'table' and raw.t)
            -- (Another resource's, by its dotted name: it may only be stopped.)
            problems[#problems + 1] = { i = i, label = 'Task', why = t:find('.', 1, true)
                and ('"%s" is not on this server now (the resource that adds it may be stopped)'):format(t)
                or ('"%s" is not a task this server has'):format(t) }
        elseif not d.kinds[kind] then
            problems[#problems + 1] = { i = i, label = d.label, why = ('a %s cannot do it'):format(kind == 'vehicle' and 'car' or kind) }
        else
            local p, bad = {}, nil
            local cx = { world = world, owner = owner }
            for _, f in ipairs(d.fields) do
                if fieldShown(d, raw, f) then
                    local v, why = DirectorFields.read(f, raw[f.key], cx)
                    if why then bad = ('%s %s'):format(f.label, why) break end
                    p[f.key] = v
                end
            end
            if not bad and p.target then bad = targetExtra(raw, p, world) end
            if not bad then bad = stepProblem(d, p) end
            -- (A prop's list is a timeline every game plays from one moment: it cannot wait on a card.)
            if not bad and kind == 'prop' and DirectorSteps.waitsOnCard(d.t, p) then bad = 'a prop waits for a time, not a card' end
            local walk
            if not bad and d.route then
                -- Its route's walks and stops, once round, in its place.
                local plan, why = DirectorRoutes.plan(world and world[p[d.route]], { once = true, loose = p.loose == true })
                if plan then walk = plan.steps else bad = 'Route: ' .. tostring(why) end
            end
            if bad then
                problems[#problems + 1] = { i = i, label = d.label, why = bad }
            elseif walk then
                local key = type(raw.k) == 'string' and raw.k:sub(1, 8) or tostring(i)
                for _, s in ipairs(walk) do
                    s.k = (key .. ':' .. s.k):sub(1, 16)
                    steps[#steps + 1] = s
                end
            else
                local timing = d.timing
                if timing == 'either' then timing = raw.next == 'time' and 'timed' or 'until' end
                -- (Waiting for a card: until it gives an outcome picked, or its Gives up after.)
                if DirectorSteps.waitsOnCard(d.t, p) then timing = 'until' end
                -- (Played as another step while its playsAs holds: Play Emote set to an animation is client/npcs.lua's anim.)
                local t = d.playsAs and DirectorFields.holds(d.playsAs.when, p, d.fields) and d.playsAs.t or d.t
                local step = {
                    k = type(raw.k) == 'string' and raw.k:sub(1, 16) or tostring(i), t = t, timing = timing, p = p,
                    lasting = d.lasting == true, once = d.once == true,
                }
                if timing == 'timed' then step.ms = msOf(raw.sec, d.sec, d.length == true) end
                if timing == 'until' then step.giveUpMs = msOf(raw.giveUp, d.giveUp) end
                -- Seats, styles and speeds as the game takes them.
                if p.seat then p.seatN = SEAT_N[p.seat] or -1 end
                if p.style then p.styleN = STYLE_N[p.style] or STYLE_N.normal end
                if p.speed then p.mps = p.speed / 3.6 end
                steps[#steps + 1] = step
            end
        end
    end
    if #steps == 0 then return nil, problems end
    return { steps = steps, after = tasks.after == 'loop' and 'loop' or 'stop', fight = tasks.fight ~= false }, problems
end

--- An emote's animation: { dict, clip } or { scenario }, or nil (shared/emote_list.lua).
function DirectorTasks.emoteAnim(cmd)
    for _, e in ipairs(EmoteList and EmoteList.emotes or {}) do
        if e.cmd == cmd then
            if e.scenario then return { scenario = e.scenario } end
            if e.dict and e.anim then return { dict = e.dict, clip = e.anim } end
            return nil
        end
    end
    return nil
end

--- Does a thing have tasks to play?
function DirectorTasks.has(w)
    local t = type(w) == 'table' and type(w.def) == 'table' and w.def.tasks or nil
    return type(t) == 'table' and type(t.list) == 'table' and #t.list > 0
end

--- The longest a list takes once through, in ms, when every step has a fixed length (a prop's always
--- does: slides, turns, fades and waits). nil when a step waits on something. (A step with no end counts NO_END_MS: a
--- list with one is not over in any run's time.)
function DirectorTasks.length(plan)
    local ms = 0
    for _, s in ipairs(plan and plan.steps or {}) do
        if s.timing == 'until' then return nil end
        ms = ms + (s.ms or 0)
    end
    return ms
end
