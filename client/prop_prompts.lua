-- Prop prompts: a prompt on every map prop of a given model near the player (cash machines, pumps).
-- This file finds the props, their ids and badge placement; a kind supplies what the prompt offers.
--
-- A kind is declared once, at file scope:
--
--     PropPrompts.define({
--         kind          = 'atm',              -- ids, the log tag, and the interaction group
--         faces        = 1,                  -- 1, or 2 for a prop used from both sides
--         modelsKey     = 'AtmProps',         -- Config[modelsKey] is the list of models
--         offsetKey     = 'AtmBadgeOffset',   -- Config[offsetKey] is where the badge sits
--         defaultOffset = { side = 0.0, out = 0.4, up = 0.3, yaw = 0.0 },
--         searchRange   = function() return Config.AtmSearchRange or 30.0 end,
--         visibleRange  = function() return Config.AtmVisibleRange or 3.0 end,
--         activeRange   = function() return Config.AtmActiveRange or 1.4 end,
--         prompt        = function(rec) return { options = ..., onBlur = ... } end,
--         onRemove      = function(rec) end,               -- optional
--     })
--
-- A record (`rec`) is one prompt: one face of one prop:
--
--     { id, baseId, kind, face, prop, entity, model, rawX, rawY, rawZ, heading,
--       x, y, z, badgeHeading }
--
--   id            the prompt id
--   baseId        the prop's id, the same for both faces of a two-sided prop
--   raw*/heading  where the prop stands and which way it faces
--   x/y/z         where the badge is; badgeHeading which way it faces

PropPrompts = {}

--- [kind] = the spec it was defined with, plus `hashes` ([model] = hash).
local kinds = {}

--- Kinds in definition order, so the sweep runs in a stable order.
local kindOrder = {}

--- [kind] = { [baseId] = prop }, where prop = { baseId, kind, entity, model, rawX, rawY, rawZ,
--- heading, faces = { rec, rec? } }.
local props = {}

--- [promptId] = rec, across every kind. What PropPrompts.get reads.
local byId = {}

-- Every call into a kind goes through here under pcall, so one kind's error is reported and does not stop the others.
---@return boolean ok
---@return any result
local function callKind(spec, field, ...)
    local fn = spec[field]
    if fn == nil then return true, nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        print(('[whip_core:%s] %s threw: %s'):format(spec.kind, field, tostring(res)))
    end
    return ok, res
end

-- Identity and position

--- A stable id for a prop, derived from where it is.
---
--- From coordinates, not the entity handle (handles are reused as objects stream). Rounded to 10 cm.
local function idFor(kind, x, y, z)
    return ('%s_%d_%d_%d'):format(kind,
        math.floor(x * 10 + 0.5), math.floor(y * 10 + 0.5), math.floor(z * 10 + 0.5))
end

--- The offset figures for a model, always a full table. Order: the model's own (Config[offsetKey], or `offsets` for a
--- kind made in code), then the kind's one `offset`, then the model default, then the kind's default.
---@return table { side, out, up, yaw? }
local function offsetFor(spec, model)
    local all = (spec.offsetKey and Config[spec.offsetKey]) or spec.offsets or {}
    local own = all[model] or spec.offset
    if own then return own end
    local default = PromptOffset.get(model)
    if default then return default.prop end
    return all.default or spec.defaultOffset or { side = 0.0, out = 0.4, up = 0.3 }
end

--- 1 for the first face, -1 for the second.
---
--- The second face is the first turned half a circle about the prop's upright axis: (x, y) lands at (-x, -y) and the
--- heading gains 180. This is a rotation, not the mirror client/doors.lua uses.
local function faceSign(face)
    return (face == 2) and -1.0 or 1.0
end

--- Where a face's badge belongs, from the current config figures. Uses the entity's local space, so `out` is away
--- from its face however the prop is turned. Falls back to the raw position if the entity has streamed out.
---@return number x, number y, number z
local function badgePosition(spec, rec)
    local entity = rec.entity
    if not entity or not DoesEntityExist(entity) then return rec.rawX, rec.rawY, rec.rawZ end
    local off = offsetFor(spec, rec.model)
    local s = faceSign(rec.face)
    local p = GetOffsetFromEntityInWorldCoords(entity,
        s * (off.side or 0.0), s * (off.out or 0.0), off.up or 0.0)
    return p.x, p.y, p.z
end

--- Which way a face's badge faces, as a world heading. A sign, not a billboard: stored as a yaw relative to the prop
--- (a prop's local +Y is its forward, which for an ATM often points into the wall).
--- A `billboard` kind has none for a model whose figures give no yaw: the badge turns to face the viewer.
---@return number|nil degrees
local function badgeHeading(spec, rec)
    local off = offsetFor(spec, rec.model)
    if off.yaw == false or (spec.billboard and off.yaw == nil) then return nil end
    local base = (rec.entity and DoesEntityExist(rec.entity)) and GetEntityHeading(rec.entity) or 0.0
    local turned = (rec.face == 2) and 180.0 or 0.0
    return (base + (off.yaw or 0.0) + turned) % 360.0
end

--- Move and turn every tracked badge of a kind to its current config figures. Uses updatePosition / updateHeading, not
--- re-register (which resets a menu and cancels input).
local function refreshPositions(kind)
    local spec = kinds[kind]
    for _, prop in pairs(props[kind] or {}) do
        for _, rec in ipairs(prop.faces) do
            rec.x, rec.y, rec.z = badgePosition(spec, rec)
            rec.badgeHeading = badgeHeading(spec, rec)
            Interactions.updatePosition(rec.id, rec.x, rec.y, rec.z)
            Interactions.updateHeading(rec.id, rec.badgeHeading)
        end
    end
end

-- Tracking props

local function addProp(spec, entity, model)
    local pos = GetEntityCoords(entity)
    local baseId = idFor(spec.kind, pos.x, pos.y, pos.z)
    local mine = props[spec.kind]
    if mine[baseId] then return end

    local prop = {
        baseId = baseId, kind = spec.kind,
        entity = entity, model = model,
        -- Kept so the badge can be recomputed when the offset changes or the entity streams out.
        rawX = pos.x, rawY = pos.y, rawZ = pos.z,
        heading = GetEntityHeading(entity),
        faces = {},
    }
    mine[baseId] = prop

    local faceCount = (spec.faces == 2) and 2 or 1
    for f = 1, faceCount do
        local id = baseId
        if faceCount == 2 then id = baseId .. ((f == 1) and '_a' or '_b') end

        local rec = {
            id = id, baseId = baseId, kind = spec.kind, face = f, prop = prop,
            entity = entity, model = model,
            rawX = pos.x, rawY = pos.y, rawZ = pos.z, heading = prop.heading,
        }
        rec.x, rec.y, rec.z = badgePosition(spec, rec)
        rec.badgeHeading = badgeHeading(spec, rec)

        prop.faces[f] = rec
        -- Tracked before the kind is asked, so PropPrompts.get works inside its prompt().
        byId[id] = rec

        local ok, extra = callKind(spec, 'prompt', rec)

        -- A kind whose prompt() threw gets no circle; the prop stays tracked.
        if ok then
            local reg = {
                id    = id,
                x     = rec.x, y = rec.y, z = rec.z,
                -- The kind's own group, or the one it asks for.
                group = spec.group or spec.kind,

                -- A sign anchored to the world: not drawn from behind.
                heading = rec.badgeHeading,

                -- 'near' rather than the aim cone: you walk up to these.
                focusMode = 'near',

                visibleRange = spec.visibleRange and spec.visibleRange() or nil,
                activeRange  = spec.activeRange and spec.activeRange() or nil,
            }
            if type(extra) == 'table' then
                for k, v in pairs(extra) do reg[k] = v end
            end

            local off = offsetFor(spec, model)
            if off.visualOffset then
                local x, y, z = PromptOffset.xyz(off.visualOffset)
                local sign = faceSign(f)
                reg.visual = PromptOffset.visual(function() return rec.entity end, vector3(sign*x, sign*y, z))
            end
            if off.radius then
                reg.follow = function()
                    if not DoesEntityExist(rec.entity) then return nil end
                    rec.x, rec.y, rec.z = badgePosition(spec, rec)
                    rec.badgeHeading = badgeHeading(spec, rec)
                    return rec.x, rec.y, rec.z, rec.badgeHeading
                end
                reg.target = PromptOffset.target(function()
                    if not DoesEntityExist(rec.entity) then return nil end
                    rec.x, rec.y, rec.z = badgePosition(spec, rec)
                    return rec.x, rec.y, rec.z, off.radius
                end, reg.activeRange, reg.visibleRange)
            end

            Interactions.register(reg)
        end
    end
end

local function removeProp(kind, baseId)
    local mine = props[kind]
    local prop = mine and mine[baseId]
    if not prop then return end
    mine[baseId] = nil

    local spec = kinds[kind]
    for _, rec in ipairs(prop.faces) do
        -- Interactions.remove cancels live input, so a prop streaming away does not leave number keys captured.
        Interactions.remove(rec.id)
        byId[rec.id] = nil
        callKind(spec, 'onRemove', rec)
    end
end

--- The kind's models, from its Config list (or its own `models`).
local function hashModels(spec)
    spec.hashes = {}
    for _, model in ipairs(spec.models or Config[spec.modelsKey] or {}) do
        spec.hashes[model] = GetHashKey(model)
    end
end

--- Set by define/undefine so the sweep runs at once.
local sweepNow = false

-- Public

--- Declare a kind (shape at the top of this file). Call it at the bottom of the kind's file, below every local its
--- functions use (a local declared below its user compiles as a nil global).
---@param spec table
function PropPrompts.define(spec)
    local kind = spec.kind
    if type(kind) ~= 'string' or kind == '' then
        print('[whip_core:props] PropPrompts.define needs a `kind`')
        return
    end

    hashModels(spec)

    if not kinds[kind] then kindOrder[#kindOrder + 1] = kind end
    kinds[kind] = spec
    props[kind] = props[kind] or {}
    sweepNow = true
end

--- Take a kind away: its props and prompts are dropped and the sweep stops looking for its models.
---@param kind string
function PropPrompts.undefine(kind)
    if not kinds[kind] then return end
    for baseId in pairs(props[kind] or {}) do removeProp(kind, baseId) end
    kinds[kind] = nil
    props[kind] = nil
    for i = #kindOrder, 1, -1 do
        if kindOrder[i] == kind then table.remove(kindOrder, i) end
    end
end

--- The record for a prompt id; nil when the prop was dropped (check after anything that yielded).
---@param promptId string
---@return table|nil
function PropPrompts.get(promptId)
    return promptId and byId[promptId] or nil
end

--- Call fn(rec) for every tracked prompt of a kind, both faces. fn may change options but must not remove props.
---@param kind string
---@param fn fun(rec: table)
function PropPrompts.each(kind, fn)
    for _, prop in pairs(props[kind] or {}) do
        for _, rec in ipairs(prop.faces) do fn(rec) end
    end
end

--- A kind's models or ranges changed: drop its tracked props; the sweep re-finds them within 5 seconds with the new figures.
---@param kind string
function PropPrompts.refresh(kind)
    local spec = kinds[kind]
    if not spec then return end
    hashModels(spec)
    for baseId in pairs(props[kind] or {}) do removeProp(kind, baseId) end
end

--- A kind's badge offsets changed: every tracked badge moves and turns to the new figures.
---@param kind string
function PropPrompts.reposition(kind)
    if kinds[kind] then refreshPositions(kind) end
end

-- Finding props. No coordinate list: an MLO that adds a bank works with no edit. One prop per model per pass
-- (GetClosestObjectOfType returns the nearest entity; map props are not reliably in the CObject pool), so walking
-- along a row discovers them in turn. Stepping out of a car re-sweeps at once.

CreateThread(function()
    while not PlayerLoaded do Wait(500) end

    -- Where and when the world was last swept; the sweep runs when the player moved or enough time passed.
    local lastSweepX, lastSweepY, lastSweepZ = nil, nil, nil
    local lastSweepAt = 0

    -- Movement before sweeping again: under the drop slack, so a prop is not dropped before a sweep could re-find it.
    local RESWEEP_DIST_SQ = 4.0 * 4.0

    -- A stationary player sweeps this often anyway (props stream in around them).
    local RESWEEP_MAX_MS = 5000

    local wasSeated = false

    while true do
        local ped = PlayerPedId()
        local pos = GetEntityCoords(ped)
        local now = GetGameTimer()

        -- Not in a car: props are dropped once on the way in, and the sweep state with them.
        local seated = IsPedInAnyVehicle(ped, false)
        if seated then
            if not wasSeated then
                wasSeated = true
                for kind, mine in pairs(props) do
                    for baseId in pairs(mine) do removeProp(kind, baseId) end
                end
                lastSweepX, lastSweepY, lastSweepZ = nil, nil, nil
                lastSweepAt = 0
            end

            Wait(1000)
            goto continue
        end
        wasSeated = false

        local moved = (lastSweepX == nil)
            or ((pos.x - lastSweepX) ^ 2 + (pos.y - lastSweepY) ^ 2 + (pos.z - lastSweepZ) ^ 2)
                > RESWEEP_DIST_SQ

        if moved or sweepNow or (now - lastSweepAt) >= RESWEEP_MAX_MS then
            sweepNow = false
            lastSweepX, lastSweepY, lastSweepZ = pos.x, pos.y, pos.z
            lastSweepAt = now

            -- Found first, dropped second: re-adding a prop in range would reset its menu.
            for _, kind in ipairs(kindOrder) do
                local spec = kinds[kind]
                local range = spec.searchRange and spec.searchRange() or 30.0
                for model, hash in pairs(spec.hashes) do
                    local entity = GetClosestObjectOfType(pos.x, pos.y, pos.z, range, hash, false, false, false)
                    if entity and entity ~= 0 and DoesEntityExist(entity) then
                        addProp(spec, entity, model)
                    end
                end
            end
        end

        -- Slack on the way out so a prop at the search radius does not flicker; measured from the prop, not its badge.
        for _, kind in ipairs(kindOrder) do
            local spec = kinds[kind]
            local range = (spec.searchRange and spec.searchRange() or 30.0) + 10.0
            local dropSq = range * range
            for baseId, prop in pairs(props[kind]) do
                local dx, dy, dz = prop.rawX - pos.x, prop.rawY - pos.y, prop.rawZ - pos.z
                if (dx * dx + dy * dy + dz * dz) > dropSq then
                    removeProp(kind, baseId)
                end
            end
        end

        Wait(500)

        ::continue::
    end
end)

-- Watching props: unlike the prompt sweep, a watch reports every prop of its models within WATCH_RANGE (seated or
-- not), once as each comes and once as it goes. It finds the nearest of each model, and only when one is in range
-- walks the object pool for the rest, after WATCH_RESWEEP metres of movement or WATCH_MAX_MS. Runs only while a watch is on.

local WATCH_RANGE    = 50.0
local WATCH_DROP     = WATCH_RANGE + 10.0   -- slack on the way out, so one at the edge does not flicker
local WATCH_RESWEEP  = 4.0
local WATCH_MAX_MS   = 3000

--- [key] = { models = { [hash] = model name }, found = fn, lost = fn, seen = { [prop id] = p } }
local watches = {}
local watchRunning = false
local watchNow = false

local function tellWatch(w, field, p)
    local fn = w[field]
    if type(fn) ~= 'function' then return end
    CreateThread(function()
        local ok, err = pcall(fn, p)
        if not ok then print(('[whip_core] a prop watch\'s %s failed: %s'):format(field, tostring(err))) end
    end)
end

--- A model hash as one unsigned number (natives return either sign).
local function uhash(h) return (math.tointeger(h) or 0) & 0xFFFFFFFF end

local function watchAdd(key, w, entity, model)
    local c = GetEntityCoords(entity)
    local id = idFor(key, c.x, c.y, c.z)
    local had = w.seen[id]
    if had then
        if had.entity == entity or DoesEntityExist(had.entity) then return end
        w.seen[id] = nil   -- same prop under a new handle: lost, then found again
        tellWatch(w, 'lost', had)
    end
    local p = { prop = id, entity = entity, model = model, coords = c }
    w.seen[id] = p
    tellWatch(w, 'found', p)
end

local function watchLoop()
    local lastX, lastY, lastZ, lastAt = nil, nil, nil, 0
    while next(watches) do
        local pos = GetEntityCoords(PlayerPedId())
        local now = GetGameTimer()
        local moved = lastX == nil
            or ((pos.x - lastX) ^ 2 + (pos.y - lastY) ^ 2 + (pos.z - lastZ) ^ 2) > WATCH_RESWEEP ^ 2
        if moved or watchNow or now - lastAt >= WATCH_MAX_MS then
            watchNow = false
            lastX, lastY, lastZ, lastAt = pos.x, pos.y, pos.z, now
            local wanted = {}
            for key, w in pairs(watches) do
                for hash, model in pairs(w.models) do
                    wanted[hash] = wanted[hash] or {}
                    wanted[hash][#wanted[hash] + 1] = { key = key, w = w, model = model }
                end
            end
            -- Nearest of each model first: with none in range the pool is not walked (GetGamePool builds a new list each call).
            local any = false
            for _, list in pairs(wanted) do
                local hash = GetHashKey(list[1].model)                local obj = GetClosestObjectOfType(pos.x, pos.y, pos.z, WATCH_RANGE, hash, false, false, false)
                if obj and obj ~= 0 and DoesEntityExist(obj) then
                    any = true
                    for _, t in ipairs(list) do watchAdd(t.key, t.w, obj, t.model) end
                end
            end
            if any then
                local rangeSq = WATCH_RANGE * WATCH_RANGE
                for _, obj in ipairs(GetGamePool('CObject')) do
                    local list = wanted[uhash(GetEntityModel(obj))]
                    if list then
                        local c = GetEntityCoords(obj)
                        if (c.x - pos.x) ^ 2 + (c.y - pos.y) ^ 2 + (c.z - pos.z) ^ 2 <= rangeSq then
                            for _, t in ipairs(list) do watchAdd(t.key, t.w, obj, t.model) end
                        end
                    end
                end
            end
        end
        -- Gone: out of range, or the entity is gone or replaced under its handle
        local dropSq = WATCH_DROP * WATCH_DROP
        for _, w in pairs(watches) do
            for id, p in pairs(w.seen) do
                local e = p.entity
                local gone = not DoesEntityExist(e) or not w.models[uhash(GetEntityModel(e))]
                if not gone then
                    local c = p.coords
                    gone = (c.x - pos.x) ^ 2 + (c.y - pos.y) ^ 2 + (c.z - pos.z) ^ 2 > dropSq
                end
                if gone then
                    w.seen[id] = nil
                    tellWatch(w, 'lost', p)
                end
            end
        end
        Wait(1000)
    end
    watchRunning = false
end

--- Be told about every prop of `models` near the player: found(p) within WATCH_RANGE (50 m), lost(p) as it goes
--- (WATCH_DROP) or despawns. p = { prop (id), entity, model, coords }. Each call runs in its own thread. The same key
--- again replaces the watch (what it had seen is lost first).
---@param key string
---@param spec table  { models = { 'prop_name', ... }, found = fn(p), lost = fn(p) }
function PropPrompts.watch(key, spec)
    PropPrompts.unwatch(key)
    local models = {}
    for _, name in ipairs(type(spec.models) == 'table' and spec.models or {}) do models[uhash(GetHashKey(name))] = name end
    watches[key] = { models = models, found = spec.found, lost = spec.lost, seen = {} }
    watchNow = true
    if not watchRunning then
        watchRunning = true
        CreateThread(watchLoop)
    end
end

--- Stop a watch: lost told for every prop it had seen.
---@param key string
function PropPrompts.unwatch(key)
    local w = watches[key]
    if not w then return end
    watches[key] = nil
    for _, p in pairs(w.seen) do tellWatch(w, 'lost', p) end
end

-- Cleanup

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- removeProp tells each kind to forget its menus.
    for kind, mine in pairs(props) do
        for baseId in pairs(mine) do removeProp(kind, baseId) end
    end
end)
