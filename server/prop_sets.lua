-- ============================================
-- Prop sets — props from the server, made by each player's own game
-- ============================================
--
-- Dressing for a scene: crates in a warehouse, barriers across a road, cash on a table. A resource
-- puts a SET of props up from SERVER code, and every player's game makes its own copies near them:
--
--   exports.whip_core:ShowPropSet('camp', {
--       props = {
--           { model = 'prop_box_wood02a', coords = vector3(x, y, z), rot = vector3(0.0, 0.0, 90.0) },
--           { model = 'prop_worklight_03a', coords = vector3(x2, y2, z2), light = true },
--       },
--       audience = 'everyone',   -- or { people = { 3, { charId = 12 } } }
--       tag = 'run:42',
--   })
--   exports.whip_core:HidePropSet('camp')
--
--   * CLIENT-MADE, NOT NETWORKED: no entity on the server, nothing for FiveM to sync or migrate, no
--     population budget used. Each game makes them as it comes within range (client/prop_sets.lua,
--     on the one prop streamer) and removes them as it leaves. They are scenery: collision is each
--     game's own, they cannot be picked up, and a prop nobody can see costs nothing.
--   * EXACTLY WHERE THEY ARE PUT: no snap to the ground. `rot` is GTA's rotation order 2 (x tilts
--     forward, y tilts sideways, z is the heading), as the furnisher saves furniture.
--   * INSIDE AN MLO, `interior = true` makes each game wait for the interior to be there before it
--     makes the prop (the Mirror Park loader brings interiors in and out), and files it in its room;
--     a lamp (`light = true`) goes in the interior's limbo, so its light reaches the room (the
--     furnisher's rule, client/interior_rooms.lua).
--   * YOURS: ids are your resource's own. The same id again replaces that set. Yours go when your
--     resource stops, and with your run's tag. At most Config.PropSetMaxProps props a set (256).
--   * READY, NOT MADE (PropSets.ready): a set each game near it only gets ready for, its
--     models loaded and its interiors watched, so props shown there later are made the moment they come
--     (the Director readies each run's props as it starts: nodes_props.lua).
--   * MOVING (PropSets.move): a prop of a set can play TASKS (slide, turn, teleport, fade, change its
--     look: server/director/tasks.lua). Each game makes its own copy, so each plays the same timeline
--     from the same moment, in the server's milliseconds (client/clock.lua), and a game that makes the
--     prop later (it came near, it logged in) puts it where the timeline has it by now. Every game it is
--     sent to says it has it (whip_core:server:propMotions); one that has not is sent it again each
--     second, and one still without it after five seconds is said in the console.
--   * A GUN (`weapon = 'WEAPON_RPG'`): the prop is that firearm's world model (GTA's, or one a running resource adds:
--     shared/weapon_catalog.lua), each
--     game making it from the weapon itself; the Director's Fire Weapon fires it (client/director_weapons.lua).
--   * ATTACHED (`attach = { net = netId } | { set = id, index = n } | { index = n }` (a prop of this same set),
--     `attachOffset = { x, y, z }`, `attachRot =
--     { x, y, z }`): on a networked car or NPC, or on a prop of one of your sets up now, at that offset and turn from it.
--     Each game attaches its own copy once it has both, and puts it back where it was placed when the parent goes.

PropSets = {}

--- The most props one set may hold (Config.PropSetMaxProps, /whip → Settings), read each time so a change
--- applies to the next set shown.
local function maxProps()
    local n = math.floor(tonumber(Config.PropSetMaxProps) or 256)
    return math.max(1, math.min(1000, n))
end
PropSets.maxProps = maxProps   -- the Director's run readying keeps to it too (nodes_props.lua)

local nextWire = 0
local live = {}   -- [wireId] = the record up now

local function num(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

local function readVec(c)
    local t = type(c)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    if not (num(x) and num(y) and num(z)) then return nil end
    return x, y, z
end

--- One prop as each game makes it, or nil and why.
local readAttach   -- (below)

local function readProp(p, i, owner)
    if type(p) ~= 'table' then return nil, ('prop %d is { model, coords, rot }'):format(i) end
    if type(p.model) ~= 'string' or #p.model == 0 or #p.model > 64 or not p.model:match('^[%w_]+$') then
        return nil, ('prop %d: model is a prop\'s name (letters, digits and _)'):format(i)
    end
    local x, y, z = readVec(p.coords)
    if not x then return nil, ('prop %d: coords is a vector3 or { x, y, z }'):format(i) end
    local w = { m = p.model:lower(), x = x, y = y, z = z, rx = 0.0, ry = 0.0, rz = 0.0 }
    if p.rot ~= nil then
        local rx, ry, rz = readVec(p.rot)
        if not rx then return nil, ('prop %d: rot is a vector3 or { x, y, z } (degrees)'):format(i) end
        w.rx, w.ry, w.rz = rx % 360.0, ry % 360.0, rz % 360.0
    elseif p.heading ~= nil then
        local h = tonumber(p.heading)
        if not num(h) then return nil, ('prop %d: heading is a number'):format(i) end
        w.rz = h % 360.0
    end
    w.interior = p.interior == true or nil
    w.light = p.light == true or nil
    w.nocol = p.collision == false or nil
    if p.weapon ~= nil then
        if not WeaponCatalog.modelOf(p.weapon) then
            return nil, ('prop %d: weapon is a firearm with a world model (GTA\'s, like WEAPON_RPG, or one a running resource adds)'):format(i)
        end
        w.wpn = p.weapon:upper()
    end
    if p.attach ~= nil then
        local a, why = readAttach(p, owner)
        if not a then return nil, ('prop %d: %s'):format(i, why) end
        w.att = a
    end
    return w
end

--- What a prop is attached to, as each game takes it: { net } | { wire, i }, with its offset (x, y, z) and turn (rx, ry,
--- rz) from it. A set is one of `owner`'s up now. Answers it, or nil and why.
function readAttach(p, owner)
    local a = p.attach
    if type(a) ~= 'table' then return nil, 'attach is { net = netId } or { set = id, index = n }' end
    local out = {}
    if a.net ~= nil then
        local n = math.tointeger(tonumber(a.net))
        if not n or n < 1 or n > 65535 then return nil, 'attach.net is a networked car\'s or NPC\'s netId' end
        out.net = n
    elseif a.index ~= nil then
        local i = math.tointeger(tonumber(a.index))
        if not i or i < 1 then return nil, 'attach.index is the place of its prop in that set (1, 2, ...)' end
        if a.set ~= nil then
            local wire = PropSets.wireOf(owner, a.set)
            if not wire then return nil, 'attach.set names no set of yours that is up' end
            out.wire = wire
        else
            out.self = true   -- (a prop of this same set: its wire id is given as the set goes up, PropSets.show)
        end
        out.i = i
    else
        return nil, 'attach is { net = netId }, { set = id, index = n }, or { index = n } (a prop of this set)'
    end
    out.x, out.y, out.z, out.rx, out.ry, out.rz = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
    if p.attachOffset ~= nil then
        out.x, out.y, out.z = readVec(p.attachOffset)
        if not out.x then return nil, 'attachOffset is { x, y, z }: metres from what it is attached to' end
    end
    if p.attachRot ~= nil then
        out.rx, out.ry, out.rz = readVec(p.attachRot)
        if not out.rx then return nil, 'attachRot is { x, y, z }: degrees, turned from what it is attached to' end
    end
    return out
end

--- A caller's spec, as each game makes it. Answers the wire table, or nil and why.
local function readSpec(spec, owner)
    if type(spec) ~= 'table' or type(spec.props) ~= 'table' then
        return nil, 'a prop set is { props = { { model, coords, rot }, ... } }'
    end
    if #spec.props == 0 then return nil, 'a prop set needs at least one prop' end
    local max = maxProps()
    if #spec.props > max then
        return nil, ('a prop set is at most %d props (Props per scene set, /whip Settings)'):format(max)
    end
    local props = {}
    for i, p in ipairs(spec.props) do
        local w, why = readProp(p, i, owner)
        if not w then return nil, why end
        props[i] = w
    end
    return { props = props }
end

-- ============================================
-- Who has which made
-- ============================================

local MOTION_RESEND_MS, MOTION_WARN_MS = 1000, 5000

--- A set's moving props to one game: all of them in one message, under the set's motion version.
local function sendMotions(rec, src)
    if not rec.mver then return end
    rec.mSent[src] = rec.mSent[src] or GetGameTimer()
    rec.mLast[src] = GetGameTimer()
    TriggerClientEvent('whip_core:client:propMotions', src, rec.wireId, rec.mver, rec.motions)
end

local function send(rec, src, on)
    if on then
        rec.sentTo[src] = true
        TriggerClientEvent('whip_core:client:propSet', src, rec.wireId, rec.wire)
        if rec.mver then rec.mAcked[src] = nil; sendMotions(rec, src) end
    elseif rec.sentTo[src] then
        rec.sentTo[src] = nil
        rec.mAcked[src], rec.mSent[src], rec.mLast[src] = nil, nil, nil
        TriggerClientEvent('whip_core:client:propSet', src, rec.wireId, false)
    end
end

--- A new set to its audience. (A set is never changed in place: the same id again is a new record,
--- and the old one is taken off every game first, so there is no one to take it off here.)
local function push(rec)
    for src in pairs(Audience.sources(rec.audience)) do send(rec, src, true) end
end

local function drop(rec)
    rec.gone = true
    if live[rec.wireId] == rec then live[rec.wireId] = nil end
    for src in pairs(rec.sentTo) do send(rec, src, false) end
end

local reg = Registry.new('propSet', {
    label = 'prop set',
    scoped = true,
    releaseOrder = 30,   -- after what is pressed and seen on the map, with the world's things
    same = false,
    onAdd = function(_, rec, _, old)
        -- The same id again: the old set goes from every game, the new one comes.
        if old then drop(old) end
        live[rec.wireId] = rec
        push(rec)
    end,
    onRemove = function(_, rec) drop(rec) end,
})

--- Put a set up (or replace the one with that id). Answers true, or false and why.
---@param owner string   Registry.caller()
---@param id string|number
---@param spec table     { props, audience?, tag? }: see the header
---@return boolean ok
---@return string|nil why
function PropSets.show(owner, id, spec, ready)
    local wire, why = readSpec(spec, owner)
    if not wire then return false, why end
    wire.ready = ready == true or nil
    ---@type string|table
    local aud = 'everyone'
    if spec.audience ~= nil then
        local a, awhy = Audience.read(spec.audience, true)
        if not a then return false, awhy or 'audience is \'everyone\' or { people = {...} }' end
        aud = a
    end
    nextWire = nextWire + 1
    -- A prop attached to another of this set: its wire id is this one.
    for _, p in ipairs(wire.props) do
        if p.att and p.att.self then p.att.self, p.att.wire = nil, nextWire end
    end
    local rec = { owner = owner, id = id, audience = aud, wire = wire, wireId = nextWire, sentTo = {},
                  motions = {}, mAcked = {}, mSent = {}, mLast = {} }
    local ok, rwhy = reg:add(owner, id, rec, spec.tag ~= nil and { tag = spec.tag } or nil)
    if not ok then return false, rwhy --[[@as string]] end
    return true
end

--- Get each game near these props ready for them without making them (see the header). The same spec as
--- show; the same ids (the same id again replaces it), taken down with hide. Answers true, or false and why.
function PropSets.ready(owner, id, spec)
    return PropSets.show(owner, id, spec, true)
end

--- Take one of the caller's sets down. Answers true, or false and why.
function PropSets.hide(owner, id)
    return reg:remove(owner, id)
end

--- Make one prop of a set move (MOVING, above), or stop it where it got to, or put it back still.
---@param index number|nil   the prop's place in the set's list (1, 2, ...)
---@param motion table|false  { steps (DirectorTasks.compile's, a prop's), startAt = server ms, after = 'stop'|'loop',
---                              stopAt = server ms (held where it was then) } | false (still, as placed)
---@return boolean ok
---@return string|nil why
function PropSets.move(owner, id, index, motion)
    local rec = reg:get(reg:keyOf(owner, id))
    if not rec or rec.gone then return false, 'no such set of yours' end
    index = math.tointeger(tonumber(index))
    if not index or not rec.wire.props[index] then return false, 'no such prop in that set' end
    local m = nil
    if motion then
        if type(motion) ~= 'table' or type(motion.steps) ~= 'table' or not tonumber(motion.startAt) then
            return false, 'a motion is { steps, startAt }'
        end
        local steps = {}
        for i, s in ipairs(motion.steps) do
            steps[i] = { t = s.t, p = s.p, ms = s.ms or 0 }
        end
        m = { steps = steps, at = math.floor(tonumber(motion.startAt) --[[@as number]]), loop = motion.after == 'loop' or nil,
              stop = tonumber(motion.stopAt) and math.floor(tonumber(motion.stopAt) --[[@as number]]) or nil }
    end
    rec.motions[index] = m
    rec.mver = (rec.mver or 0) + 1
    -- (mWarned: [src] = the version said of, so each player's late ack of each version is said once)
    rec.mAcked, rec.mSent, rec.mLast, rec.mWarned = {}, {}, {}, {}
    for src in pairs(rec.sentTo) do sendMotions(rec, src) end
    return true
end

--- Every game a set went to has its latest motions? (Sent again each second until each says so.)
Every('prop motions', 1000, function()
    local now = GetGameTimer()
    for _, rec in pairs(live) do
        if rec.mver then
            for src in pairs(rec.sentTo) do
                if rec.mAcked[src] ~= rec.mver then
                    if now - (rec.mLast[src] or 0) >= MOTION_RESEND_MS then sendMotions(rec, src) end
                    rec.mWarned = type(rec.mWarned) == 'table' and rec.mWarned or {}
                    if rec.mWarned[src] ~= rec.mver and now - (rec.mSent[src] or now) >= MOTION_WARN_MS then
                        rec.mWarned[src] = rec.mver
                        print(('^3[whip_core:propsets] %s\'s set %s: player %d has not said it has its moving props in %d s^7')
                            :format(tostring(rec.owner), tostring(rec.id), src, MOTION_WARN_MS // 1000))
                    end
                end
            end
        end
    end
end)

SecureEvent('whip_core:server:propMotions', {
    rateLimit = 50, burst = 40, whileDead = true,
    params = { {'wireId', 'id'}, {'ver', 'int', 0, 1000000} },
}, function(source, _, wireId, ver)
    local rec = live[wireId]
    if not rec or not rec.sentTo[source] then return end
    if ver == rec.mver then rec.mAcked[source] = ver end
end)

--- The caller's sets: { { id, props = n } }.
function PropSets.list(owner)
    local out = {}
    for _, key in ipairs(reg:keysOf(owner)) do
        local rec = reg:get(key)
        if rec then out[#out + 1] = { id = rec.id, props = #rec.wire.props } end
    end
    return out
end

--- The wire id each game knows one of the caller's sets by (a prop attached to it, the Fire Weapon card), or nil.
function PropSets.wireOf(owner, id)
    local rec = reg:get(reg:keyOf(owner, id))
    return rec and not rec.gone and rec.wireId or nil
end

--- Whose set is up under a wire id (a game said which piece it means: the Object Viewer), and its id: owner, id. nil
--- when none is.
function PropSets.byWire(wireId)
    local rec = live[wireId]
    if not rec or rec.gone then return nil end
    return rec.owner, rec.id
end

-- A character coming on: every set meant for them.
Character.onLife('loaded', function(e)
    local src = e and e.source
    if not src then return end
    local list = {}
    for wireId, rec in pairs(live) do
        if Audience.has(rec.audience, src) then
            rec.sentTo[src] = true
            list[#list + 1] = { id = wireId, w = rec.wire }
        else
            rec.sentTo[src] = nil
        end
    end
    TriggerClientEvent('whip_core:client:propSets', src, list)
    -- ...and the ones moving, where they are by now.
    for _, rec in pairs(live) do
        if rec.sentTo[src] and rec.mver then
            rec.mAcked[src], rec.mSent[src] = nil, nil
            sendMotions(rec, src)
        end
    end
end)

-- ...and going out: none of them on the character screen.
Character.onLife('logout', function(e)
    local src = e and e.source
    if not src then return end
    for _, rec in pairs(live) do rec.sentTo[src] = nil end
    if e.why ~= 'disconnect' then TriggerClientEvent('whip_core:client:propSets', src, {}) end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, rec in pairs(live) do
        rec.sentTo[src] = nil
        rec.mAcked[src], rec.mSent[src], rec.mLast[src] = nil, nil, nil
    end
end)

-- ============================================
-- Exports
-- ============================================

--- Props made by each player's game: ShowPropSet(id, { props = { { model, coords, rot | heading,
--- interior, light, collision } }, audience, tag }) -> true | false, why. The same id again replaces it.
exports('ShowPropSet', function(id, spec)
    local owner = Registry.caller()
    return PropSets.show(owner, id, spec)
end)

--- Take yours down: HidePropSet(id) -> true | false, why.
exports('HidePropSet', function(id)
    local owner = Registry.caller()
    return PropSets.hide(owner, id)
end)
