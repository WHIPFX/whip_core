-- Guards: NPCs with "Sees players" on (w.def.vision) are watched by Vision (server/vision.lua) once a run makes them.
-- When one spots a run player, the alerted NPCs are the guard, its group, or the run's NPCs near it that react to
-- danger; they Attack, Come to look, or do nothing but the card. Guard Spots You hears every spot.
-- run.guards = { [npcId] = { watch = Vision's id, worldId } }
-- run.alertedNpcs = { [npcId] = true }: already set on the players, not set on again until DirectorGuards.calmed.

local CORE = GetCurrentResourceName()

local define = DirectorKit.define

local LOOK_MS = 8000                       -- a guard come to look looks round this long
local LOOK_SCENARIO = 'WORLD_HUMAN_GUARD_STAND'

DirectorGuards = {}

DirectorRuntime.bridge('npc.spotted')   -- (emitted below, to the run whose guard it was)

--- What an NPC's page says it sees: { range, cone, spotMs (up close), farMs (at its range), sneak, alert, alertRange,
--- react }, or nil. An alert of 'all' is read as 'near'.
function DirectorGuards.visionOf(w)
    local v = type(w) == 'table' and type(w.def) == 'table' and w.def.vision or nil
    if type(v) ~= 'table' or v.on ~= true then return nil end
    local function num(x, lo, hi, d) return DirectorKit.num(x, d, lo, hi) end
    local spotS = num(v.spotS, 1, 10, 2)   -- (a second at least: time to react)
    return {
        range = num(v.range, 3, 80, 20), cone = num(v.cone, 20, 360, 100), spotMs = math.floor(spotS * 1000),
        farMs = math.floor(math.max(spotS, num(v.farS, 1, 30, 8)) * 1000),
        sneak = v.sneak ~= false,
        alert = v.alert == 'self' and 'self' or (v.alert == 'near' or v.alert == 'all') and 'near' or 'group',
        alertRange = num(v.alertRange, 5, 100, 30),
        react = (v.react == 'look' or v.react == 'card') and v.react or 'attack',
    }
end

local function players(run)
    local out = {}
    for s in pairs(run.players) do out[#out + 1] = s end
    table.sort(out)
    return out
end

--- The NPCs a run made for a placed thing.
local function npcsOf(run, worldId) return DirectorNodes.npcIds(run.world[worldId]) end

--- The placed NPCs the run has made, by id, in a set order.
local function madeNpcs(run)
    local out = {}
    for wid in pairs(run.world or {}) do
        local w = run.graph.world[wid]
        if type(w) == 'table' and w.kind == 'npc' then out[#out + 1] = wid end
    end
    table.sort(out)
    return out
end

--- A placed NPC's Group (its General tab), or nil.
local function groupOf(w)
    local g = type(w) == 'table' and type(w.def) == 'table' and w.def.group or nil
    return type(g) == 'string' and g ~= '' and g or nil
end

--- Who a spot alerts (`v`: the spotting guard's visionOf).
local function alerted(run, worldId, npcId, v)
    if v.alert == 'self' then return { npcId } end
    local out, seen = {}, {}
    local function add(id) if not seen[id] then seen[id] = true; out[#out + 1] = id end end
    add(npcId)
    if v.alert == 'near' then
        local me = Npcs.get(npcId)
        local at = me and me.coords
        if not at then return out end
        local r2 = v.alertRange * v.alertRange
        for _, wid in ipairs(madeNpcs(run)) do
            for _, id in ipairs(npcsOf(run, wid)) do
                local info = Npcs.get(id)
                local c = info and info.coords
                if info and c and info.conditions and info.conditions.reacts == true then
                    local dx, dy, dz = c.x - at.x, c.y - at.y, c.z - at.z
                    if dx * dx + dy * dy + dz * dz <= r2 then add(id) end
                end
            end
        end
        return out
    end
    -- Its group: the NPCs made for its own placed thing, and for every placed NPC of the same Group.
    for _, id in ipairs(npcsOf(run, worldId)) do add(id) end
    local g = groupOf(run.graph.world[worldId])
    if g then
        for _, wid in ipairs(madeNpcs(run)) do
            if wid ~= worldId and groupOf(run.graph.world[wid]) == g then
                for _, id in ipairs(npcsOf(run, wid)) do add(id) end
            end
        end
    end
    return out
end

local function same(s) return s.p end

--- One guard comes to look where the player was seen, and looks round; then its post or its patrol again.
local function comeToLook(run, id, at)
    local g = run.guards and run.guards[id]
    local plan = { after = 'stop', fight = true, keepPost = true, steps = {
        { k = 'look1', t = 'goTo', timing = 'until', giveUpMs = 30000, p = { at = { x = at.x, y = at.y, z = at.z, heading = 0.0 }, pace = 'run' } },
        { k = 'look2', t = 'scenario', timing = 'timed', ms = LOOK_MS, lasting = true, p = { scenario = LOOK_SCENARIO } },
    } }
    local ok = Npcs.runTasks(CORE, id, plan, { resolve = same, onEnd = function()
        if g and g.watch then Vision.calm(g.watch) end
    end })
    if ok and g and g.watch then Vision.setState(g.watch, 'search') end
end

--- A guard of the run spotted `src`: the card hears it, and those it alerts do what its page says.
local function spotted(run, worldId, npcId, src, at)
    if run.status ~= 'running' then return end
    local w = run.graph.world[worldId]
    local v = DirectorGuards.visionOf(w) or { alert = 'group', alertRange = 30, react = 'attack' }
    DirectorRuntime.emit('npc.spotted', { runId = run.id, npcId = npcId, worldId = worldId, source = src, at = at }, run)
    if v.react == 'card' then return end
    run.alertedNpcs = run.alertedNpcs or {}
    for _, id in ipairs(alerted(run, worldId, npcId, v)) do
        local info = Npcs.get(id)
        local g = run.guards and run.guards[id]
        if info and info.alive and not run.alertedNpcs[id] then
            if v.react == 'attack' then
                -- What the NPC debug shows as the reason (Npcs.explain).
                local because = { text = id == npcId and 'its vision spotted {who}' or 'another guard spotted {who}', who = src }
                local ok = Npcs.setState(CORE, id, { hostileTo = { people = players(run) } }, because)
                if ok then
                    run.alertedNpcs[id] = true
                    if g and g.watch then Vision.setState(g.watch, 'alert') end
                    -- A player who joins later is fought too.
                    Director.followCrew(run, 'npc:' .. tostring(id), function(list)
                        return (Npcs.setState(CORE, id, { hostileTo = { people = list } }, because))
                    end)
                end
            else
                comeToLook(run, id, at)
            end
        end
    end
end

--- NPCs calmed down (NPC Attacks set to No): a guard among them can be alerted again by its next spot.
function DirectorGuards.calmed(run, ids)
    for _, id in ipairs(ids) do
        if run.alertedNpcs then run.alertedNpcs[id] = nil end
        local g = run.guards and run.guards[id]
        if g and g.watch then Vision.calm(g.watch) end
    end
end

--- Watch what a run's NPCs see, for a placed NPC whose page has Sees players on. `ids`: the ones just made.
function DirectorGuards.arm(ctx, worldId, ids)
    local run = ctx.run
    local cfg = DirectorGuards.visionOf(run.graph.world[worldId])
    if not cfg then return end
    run.guards = run.guards or {}
    for _, id in ipairs(ids) do
        local npc = id
        local watch, why = Vision.watch(CORE, npc, cfg, {
            tag = ctx:tag(),
            audience = function() return players(run) end,
            onSpotted = function(src, at) spotted(run, worldId, npc, src, at) end,
        })
        if watch then
            run.guards[npc] = { watch = watch, worldId = worldId }
        else
            ctx:log('%s: NPC %s cannot see: %s', tostring(worldId), tostring(npc), tostring(why))
        end
    end
end

-- The card

define({
    type = 'npc.spotted', v = 2, category = 'events', title = 'Guard Spots You',
    desc = 'When a guard (an NPC whose page has Sees players on) spots one of the scenario\'s players. The player spotted is who set it off.',
    outputs = { 'out' },
    upgrade = function(props) return DirectorNodes.toList(props, 'npc') end,
    props = { DirectorNodes.thingsField('npc', 'npc', 'Guards (or groups)', {
                check = function(v, doc)
                    local world = type(doc) == 'table' and type(doc.world) == 'table' and doc.world or {}
                    local byId = {}
                    for _, w in ipairs(world) do if type(w) == 'table' then byId[w.id] = w end end
                    for _, id in ipairs(DirectorNodes.expandThings(world, v, 'npc')) do
                        local w = byId[id]
                        if w and not DirectorGuards.visionOf(w) then
                            return ('"%s" does not see players: turn Sees players on, on its page'):format(tostring(w.label or w.id))
                        end
                    end
                    return nil
                end }) },
    event = {
        name = 'npc.spotted', once = true,
        filter = function(ctx, p)
            if type(p) ~= 'table' or not p.source or p.runId ~= ctx.run.id then return nil end
            for _, wid in ipairs(DirectorNodes.things(ctx, 'npc')) do
                for _, id in ipairs(npcsOf(ctx.run, wid)) do
                    if id == p.npcId then return 'out', { source = p.source } end
                end
            end
            return nil
        end,
    },
})
