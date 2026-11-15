-- Dungeon Mode, this game's half: the Director's world builder (client/property_furnish.lua Furnisher.open) on the
-- live world with no scenario. Server half: server/director/live.lua; permission director.live.
--   Put down  a pick (Props, NPCs, Vehicles, Weapons) is made in the world for real (whip_core:director:liveMake)
--             for everyone; the real one joins the builder's list (the Placed tab) and its markers move it.
--   Click     a click on nothing of the builder's is on the world's thing there (prop, ground item, car, NPC,
--             player): its Object Viewer options open (tools/ov_panel.lua), lasting ones greyed for non-admins.
--             Their Move puts the markers on it (held). What a click would pick is lit white (client/highlight.lua).
--   Move      a thing is moved on this game (it takes control of a car, NPC or object; the server moves a player);
--             the server hears where it ended up once it stops.
--   Nothing lasts past a restart, and nothing is unsaved: Done (or Exit) just closes it.

DirectorLive = {}

local MOVED_MS = 400         -- the server hears where a thing went this long after its last move
local PLAYER_MOVE_MS = 100   -- a player's ped, to the server, at most this often
local FIND_MS = 500          -- how often a thing of mine not in the list yet is looked for
local SYNC_MS = 5000         -- and how often the server's list is read again (one removed elsewhere goes)
local LOST_MS = 3000         -- one of mine not on this game this long leaves the list (until it is back)
local RAY = 300.0

local live = false           -- the builder is open on the live world
local made = {}              -- [thingId] = { view = the server's, it = the builder's row or nil, at = noted (GetGameTimer) }
local removedAt = {}         -- [thingId] = when this game removed it: a list asked for before that cannot bring it back
local held = nil             -- a thing of the world held to move, from its options: { it, back }
local moving = setmetatable({}, { __mode = 'k' })   -- [row] = when it last moved
local findAt, syncAt = 0, 0

local KIND_OF = { npc = 'npc', vehicle = 'vehicle', prop = 'prop' }

local handlers = {}          -- the session's (Furnisher.open spec.live): below

local function say(text, kind) UI.Notify(text, kind or 'info', 3500) end

--- The builder's row for one of mine: where it is, what it shows, how this game finds it.
local function rowOf(v, ent)
    local c, rot = GetEntityCoords(ent), GetEntityRotation(ent, 2)
    return {
        model = v.model, x = c.x, y = c.y, z = c.z, rx = rot.x, ry = rot.y, rz = GetEntityHeading(ent),
        extra = { kind = v.kind == 'prop' and 'liveProp' or 'live', shows = v.kind, live = v.id,
                  label = v.label or (v.weapon and v.weapon:gsub('^WEAPON_', ''):lower()) or v.model,
                  netId = v.netId, wire = v.wire, weapon = v.weapon },
    }
end

--- The entity a row of the world stands for, on this game now (nil: not here, out of range or gone).
local function entityOf(it)
    local x = type(it) == 'table' and it.extra or nil
    if type(x) ~= 'table' then return nil end
    if x.sid then
        local p = GetPlayerFromServerId(x.sid)
        local ped = p ~= -1 and GetPlayerPed(p) or 0
        return ped ~= 0 and DoesEntityExist(ped) and ped or nil
    end
    if x.netId and NetworkDoesNetworkIdExist(x.netId) then
        local e = NetworkGetEntityFromNetworkId(x.netId)
        return e ~= 0 and DoesEntityExist(e) and e or nil
    end
    if x.wire then return (PropSets.pieceOf(x.wire, 1)) end
    -- (A ground item moved is drawn again where it went: a new object, found by its pile.)
    if x.ground then return GroundPiles.prop(x.ground) end
    if x.entity and DoesEntityExist(x.entity) then return x.entity end
    return nil
end

-- Moving a thing of the world

local sentAt = 0

--- Control of a networked car, NPC or object, asked for once at a time (a drag sends a move a frame).
local function haveControl(it, ent)
    if not NetworkGetEntityIsNetworked(ent) or NetworkHasControlOfEntity(ent) then return true end
    if it.asking then return false end
    it.asking = true
    CreateThread(function()
        Vehicles.takeEntityControl(ent)
        it.asking = nil
    end)
    return false
end

local function move(it)
    local ent = it.obj
    if not ent or not DoesEntityExist(ent) then return end
    moving[it] = GetGameTimer()
    local x = it.extra or {}
    if x.sid then
        local now = GetGameTimer()
        if now - sentAt >= PLAYER_MOVE_MS then
            sentAt = now
            TriggerServerEvent('whip_core:server:ovMovePlayer', x.sid, it.x, it.y, it.z, it.rz or 0.0)
        end
        return
    end
    if not haveControl(it, ent) then return end
    SetEntityCoordsNoOffset(ent, it.x, it.y, it.z, false, false, false)
    if x.kind == 'liveProp' then SetEntityRotation(ent, it.rx or 0.0, it.ry or 0.0, it.rz or 0.0, 2, true)
    else SetEntityHeading(ent, (it.rz or 0.0) % 360.0) end
end

--- One of mine stopped moving: the server hears where (an NPC stands there now; a prop is shown there for
--- everyone as a new set, and this game's copy is found again under it).
local function moved(it)
    local x = it.extra or {}
    if x.sid then
        TriggerServerEvent('whip_core:server:ovMovePlayer', x.sid, it.x, it.y, it.z, it.rz or 0.0)
        return
    end
    -- A ground item lies there from now on, for everyone (server/object_viewer.lua pile.place).
    if x.ground then
        local ref = { ground = x.ground }
        local at = { x = it.x, y = it.y, z = it.z, heading = (it.rz or 0.0) % 360.0, rx = it.rx or 0.0, ry = it.ry or 0.0 }
        CreateThread(function()
            local r, why = Callback('whip_core:ov:act', ref, 'pile.place', at)
            if type(r) ~= 'table' then say(why or 'Its new place was not kept', 'error') end
        end)
        return
    end
    -- An NPC of a run or script: the server keeps its new place as its post, or it walks back.
    if not x.live and x.shows == 'npc' and x.netId then
        local ref = { net = x.netId }
        local at = { x = it.x, y = it.y, z = it.z, heading = (it.rz or 0.0) % 360.0 }
        CreateThread(function()
            local r, why = Callback('whip_core:ov:act', ref, 'npc.place', at)
            if type(r) ~= 'table' then say(why or 'Its new place was not kept', 'error') end
        end)
        return
    end
    if not x.live then return end
    local id = x.live
    local coords = { x = it.x, y = it.y, z = it.z, heading = (it.rz or 0.0) % 360.0 }
    local rot = { x = it.rx or 0.0, y = it.ry or 0.0 }
    CreateThread(function()
        local v, why = Callback('whip_core:director:liveMove', id, coords, rot)
        if type(v) ~= 'table' then say(why or 'Its new place was not kept', 'error') return end
        local m = made[id]
        if m then m.view = v end
        if x.live == id and v.wire then x.wire = v.wire end
    end)
end

-- The Object Viewer's options, over the builder

local openOptions   -- (below)

--- Their Move: the builder's markers on it. One of mine in the list is selected; anything else is held while it
--- is the selection (then its options come back).
local function holdToMove(target, back)
    local ent = target and target.entity
    if not ent or not DoesEntityExist(ent) then return false, 'It is not there any more' end
    Furnisher.pause(false)
    for _, m in pairs(made) do
        if m.it and m.it.obj == ent then
            Furnisher.select(m.it)
            return true
        end
    end
    local c = GetEntityCoords(ent)
    local kind = target.kind
    local extra = { kind = 'live', shows = kind == 'player' and 'npc' or kind == 'object' and 'prop' or kind,
                    label = target.label or target.name, sid = kind == 'player' and target.sid or nil,
                    netId = kind ~= 'player' and target.netId or nil, entity = ent }
    local rot = GetEntityRotation(ent, 2)
    -- Someone else's Dungeon Mode prop (admin view): it tilts, and the server hears where it went.
    if target.prop == 'set' and target.liveId and type(target.ref) == 'table' then
        extra = { kind = 'liveProp', shows = 'prop', live = target.liveId, wire = target.ref.wire,
                  label = target.label or target.name, entity = ent }
    elseif target.prop == 'pile' and type(target.ref) == 'table' then
        -- A ground item tilts too, and the server hears where it was left.
        extra = { kind = 'liveProp', shows = 'prop', ground = target.ref.ground, label = target.label or target.name, entity = ent }
    end
    local it = Furnisher.hold({
        model = target.model or '', x = c.x, y = c.y, z = c.z, rx = rot.x, ry = rot.y, rz = GetEntityHeading(ent), extra = extra,
    }, true)
    if not it then return false, 'It cannot be held here' end
    held = { it = it, back = back }
    return true
end

local afterClose = nil   -- what an option leaves to do once the options have closed (Duplicate's carry)

--- One of my props' own options done here (the rest are the server's: server/object_viewer.lua): a Fixed Weapon
--- fires from this game; Duplicate puts a copy in hand, made where it is put down.
local function propExtras(it)
    local x = it and it.extra
    if type(x) ~= 'table' or x.kind ~= 'liveProp' or not x.live then return nil end
    local list = {}
    -- (A map prop whose name this game does not know is made by its number.)
    if type(it.model) == 'string' and it.model ~= '' and not it.model:match('^%d+$') then
        list[#list + 1] = { key = 'dup', group = 'liveProp', label = 'Duplicate',
                            hint = 'A copy of it in hand, turned as it is: put it down and it is made for everyone.',
                            run = function()
                                local row = { model = it.model, rx = it.rx, ry = it.ry, rz = it.rz,
                                              extra = { kind = 'prop', label = x.label, weapon = x.weapon } }
                                afterClose = function() FurnishBuilder.carryCopy(row) end
                                return { ok = true, close = true }
                            end }
    end
    if x.weapon and x.wire then
        local function fire(shots, gap)
            return function()
                DirectorWeapons.fireNow({ wire = x.wire, i = 1, weapon = x.weapon, shots = shots, gapMs = gap }, function(ok, why)
                    if not ok then say(why or 'It did not fire', 'error') end
                end)
                TriggerServerEvent('whip_core:server:liveFired', x.live, shots)
                return { ok = true, text = shots == 1 and 'Fired' or ('Firing ' .. shots) }
            end
        end
        list[#list + 1] = { key = 'fire', group = 'liveProp', label = 'Fire', run = fire(1, 500),
                            hint = 'One shot from its barrel, the way it points, as the Fire Weapon card fires.' }
        list[#list + 1] = { key = 'burst', group = 'liveProp', label = 'Fire a burst', run = fire(5, 400),
                            hint = 'Five shots from its barrel, close together.' }
    end
    return list
end

--- An option took one of mine out of the world (Remove, Swap): out of the list now, not once its entity is gone.
local function gone(entity)
    for id, m in pairs(made) do
        if m.it and m.it.obj == entity then
            Furnisher.letGo(m.it)
            made[id] = nil
            removedAt[id] = GetGameTimer()
        end
    end
end

--- An option made one of mine (a map prop taken over): into the list and selected. One shown again (a new set)
--- keeps its row, which follows the new copy.
local function adopt(v)
    if type(v) ~= 'table' or not v.id then return end
    local m = made[v.id]
    if m then
        m.view = v
        if m.it and type(m.it.extra) == 'table' then
            m.it.extra.wire = v.wire
            m.it.obj = nil
        end
        return
    end
    if not v.mine then return end
    made[v.id] = { view = v, select = true, at = GetGameTimer() }
    findAt = 0
end

openOptions = function(entity, it)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    if OvPanel.busy() then OvPanel.close() end
    Furnisher.pause(true)
    afterClose = nil
    OvPanel.open(entity, nil, { over = true, move = holdToMove, extras = propExtras(it), onGone = gone, onMade = adopt,
                                onClose = function()
                                    Furnisher.pause(false)
                                    local after = afterClose
                                    afterClose = nil
                                    if after then after() end
                                end })
    -- (Opens in a thread: if it never opens, the builder gets its keys back.)
    CreateThread(function()
        Wait(1500)
        if live and not OvPanel.busy() then Furnisher.pause(false) end
    end)
end

-- What the pointer is on: a ray, then boxes. The ray from the camera through the pointer finds what it meets
-- first; glass stops it (a click on a car's window is on the car), a see-through fence does not. What no ray can
-- meet (a ground item or prop with no collision, a car the ray slipped past) is found by its model's box. Only a
-- box in front of where the ray stopped counts, so nothing is picked through a wall; of several, the smallest.
-- A gun or prop in a ped's hands is the ped.

local PICK_FLAGS = 1 | 2 | 4 | 8 | 16   -- the map, cars, peds and their ragdolls, objects
local PICK_OPTIONS = 2 | 4              -- past see-through and no-collision faces; glass stops it
local NEAR_RANGE = 120.0                -- the boxes asked: what is within this of the camera
local NEAR_MS = 1000                    -- and that list read again this often
local near, nearAt = {}, -NEAR_MS

--- Has it no collision (a ground item, a non-solid prop: no ray meets it)? Read at call time: FiveM puts a native
--- into _G only on its first ordinary lookup, so a rawget at load sees nil. Falls back to the hash.
local function collisionOff(e)
    local ok, v = pcall(GetEntityCollisionDisabled, e)
    if not ok then ok, v = pcall(Citizen.InvokeNative, 0xCCF1E97BEFDAE480, e, Citizen.ReturnResultAnyway()) end
    return ok and (v == true or v == 1)
end

--- [model] = { mn, mx, r, vol } (false: no box), read once a model.
local boxes = {}
local function boxOf(ent)
    local model = GetEntityModel(ent)
    local b = boxes[model]
    if b == nil then
        local mn, mx = GetModelDimensions(model)
        if mn and mx then
            local ex = math.max(math.abs(mn.x), math.abs(mx.x))
            local ey = math.max(math.abs(mn.y), math.abs(mx.y))
            local ez = math.max(math.abs(mn.z), math.abs(mx.z))
            b = { mn = mn, mx = mx, r = math.sqrt(ex * ex + ey * ey + ez * ez),
                  vol = math.max(0.001, (mx.x - mn.x) * (mx.y - mn.y) * (mx.z - mn.z)) }
        else
            b = false
        end
        boxes[model] = b
    end
    return b or nil
end

--- Where the segment first enters the entity's box (0-1 along it) and the box's size, or nil (misses, or starts inside).
local function boxEntry(ent, from, to)
    local b = boxOf(ent)
    if not b then return nil end
    local c = GetEntityCoords(ent)
    local sx, sy, sz = to.x - from.x, to.y - from.y, to.z - from.z
    local len2 = sx * sx + sy * sy + sz * sz
    local px, py, pz = c.x - from.x, c.y - from.y, c.z - from.z
    local u = len2 > 0 and math.max(0.0, math.min(1.0, (px * sx + py * sy + pz * sz) / len2)) or 0.0
    local qx, qy, qz = px - sx * u, py - sy * u, pz - sz * u
    if qx * qx + qy * qy + qz * qz > b.r * b.r then return nil end
    local a = GetOffsetFromEntityGivenWorldCoords(ent, from.x, from.y, from.z)
    local e = GetOffsetFromEntityGivenWorldCoords(ent, to.x, to.y, to.z)
    local tmin, tmax, entered = 0.0, 1.0, false
    for _, k in ipairs({ 'x', 'y', 'z' }) do
        local o, dir = a[k], e[k] - a[k]
        local lo, hi = b.mn[k], b.mx[k]
        if math.abs(dir) < 1e-9 then
            if o < lo or o > hi then return nil end
        else
            local t1, t2 = (lo - o) / dir, (hi - o) / dir
            if t1 > t2 then t1, t2 = t2, t1 end
            if t1 > tmin then tmin, entered = t1, true end
            if t2 < tmax then tmax = t2 end
            if tmin > tmax then return nil end
        end
    end
    if not entered then return nil end
    return tmin, b.vol
end

--- The peds, cars and objects near the camera (never the player's own ped), re-read every NEAR_MS with their
--- place and box reach, so a hover tests the ray in Lua first. `moves`: a car or ped, whose place is re-read.
local function nearList(from)
    local now = GetGameTimer()
    if now - nearAt < NEAR_MS then return near end
    nearAt = now
    near = {}
    local me = PlayerPedId()
    for _, pool in ipairs({ 'CVehicle', 'CPed', 'CObject' }) do
        local moves = pool ~= 'CObject'
        for _, ent in ipairs(GetGamePool(pool)) do
            if ent ~= me then
                local c = GetEntityCoords(ent)
                if #(c - from) <= NEAR_RANGE then
                    local b = boxOf(ent)
                    if b then near[#near + 1] = { ent = ent, c = c, r = b.r, moves = moves } end
                end
            end
        end
    end
    return near
end

--- Does the segment from `from` (s: its length along each axis, len2: squared) pass within `r` of `c`? Lua only.
local function passesNear(c, r, from, sx, sy, sz, len2)
    local px, py, pz = c.x - from.x, c.y - from.y, c.z - from.z
    local u = len2 > 0 and math.max(0.0, math.min(1.0, (px * sx + py * sy + pz * sz) / len2)) or 0.0
    local qx, qy, qz = px - sx * u, py - sy * u, pz - sz * u
    return qx * qx + qy * qy + qz * qz <= r * r
end

--- Can it be clicked? Visible, or hidden by an Object Viewer option (still there to unhide).
local function seen(ent)
    if IsEntityVisible(ent) then return true end
    if not NetworkGetEntityIsNetworked(ent) then return false end
    local mask = Entity(ent).state[ENTITY_OV_HOLD_KEY]
    return type(mask) == 'number' and mask & 1 ~= 0
end

--- A gun or a prop in a ped's hands is the ped.
local function rootOf(ent)
    if GetEntityType(ent) == 3 and IsEntityAttachedToAnyPed(ent) then
        local p = GetEntityAttachedTo(ent)
        if p and p ~= 0 and DoesEntityExist(p) then return p end
    end
    return ent
end

--- What a click through the pointer is on in the world (a ped, a car or an object; never the player's own ped), or nil.
local function entityAt(from, dx, dy, dz)
    local to = vector3(from.x + dx * RAY, from.y + dy * RAY, from.z + dz * RAY)
    local me = PlayerPedId()
    local ray = StartExpensiveSynchronousShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, PICK_FLAGS, me, PICK_OPTIONS)
    local _, hit, at, _, ent = GetShapeTestResult(ray)
    local limit, met = 1.0, nil
    if hit == 1 or hit == true then
        limit = #(at - from) / RAY
        if ent and ent ~= 0 and ent ~= me and DoesEntityExist(ent) then
            local t = GetEntityType(ent)
            if t >= 1 and t <= 3 then met = ent end
        end
    end
    -- Boxes in front of where the ray stopped: all when it met nothing, else only what it could not have met
    -- (no collision). The near test runs first in Lua; a prop is where it was a moment ago (half a metre to
    -- spare), a car or ped is re-read.
    local sx, sy, sz = to.x - from.x, to.y - from.y, to.z - from.z
    local len2 = sx * sx + sy * sy + sz * sz
    local best, bestVol = nil, math.huge
    for _, n in ipairs(nearList(from)) do
        local e = n.ent
        if e ~= met then
            local c = n.c
            if n.moves then c = DoesEntityExist(e) and GetEntityCoords(e) or c end
            if passesNear(c, n.r + (n.moves and 0.0 or 0.5), from, sx, sy, sz, len2)
                and DoesEntityExist(e) and (not met or collisionOff(e)) and seen(e) then
                local t, vol = boxEntry(e, from, to)   -- (both, or nil)
                if t and t <= limit + 0.0005 and vol < bestVol then best, bestVol = e, vol --[[@as number]] end
            end
        end
    end
    local pick = best or met
    return pick and rootOf(pick) or nil
end

-- The session's handlers (Furnisher.open spec.live)

handlers.entityOf = entityOf
handlers.move = move

--- A pick put down: made for real where it was put.
function handlers.putDown(it)
    local x = type(it.extra) == 'table' and it.extra or {}
    local kind = KIND_OF[x.kind or 'prop']
    if not kind then say('Places belong to a scenario: in Live, pick an NPC, a car, a prop or a gun', 'error') return end
    if type(it.model) ~= 'string' or it.model == '' then return end
    local spec = { kind = kind, model = it.model, label = x.label, weapon = kind == 'prop' and x.weapon or nil,
                   coords = { x = it.x, y = it.y, z = it.z, heading = (it.rz or 0.0) % 360.0 },
                   rot = { x = it.rx or 0.0, y = it.ry or 0.0 } }
    CreateThread(function()
        local v, why = Callback('whip_core:director:liveMake', spec)
        if type(v) ~= 'table' then say(why or 'It could not be made', 'error') return end
        made[v.id] = { view = v, at = GetGameTimer() }
        findAt = 0   -- (looked for at once)
    end)
end

--- A click on nothing of the builder's: the world's thing there, and its options.
function handlers.click(from, dx, dy, dz)
    local ent = entityAt(from, dx, dy, dz)
    if not ent then return end
    -- (One of mine the builder holds has its own options too: Fire and Remove.)
    for _, m in pairs(made) do
        if m.it and m.it.obj == ent then openOptions(ent, m.it) return end
    end
    openOptions(ent)
end

--- What a click there would open the options of (marked white: client/property_furnish.lua hoverFrame).
function handlers.hover(from, dx, dy, dz)
    return entityAt(from, dx, dy, dz)
end

--- A click on the room while the options are open: they go.
function handlers.away()
    if OvPanel.busy() then OvPanel.close() else Furnisher.pause(false) end
end

--- The bubble's Options, on one the builder holds.
function handlers.options(it)
    if it.obj and DoesEntityExist(it.obj) then openOptions(it.obj, it) end
end

--- Remove (the bubble's, or Delete): one of mine goes from the world; one held to move is let go, where it is.
function handlers.remove(it)
    local x = it.extra or {}
    if held and held.it == it then
        -- (Let go as a click elsewhere does; its options come back.)
        local h = held
        held = nil
        if h.back then
            Furnisher.pause(true)
            h.back()
        end
        return
    end
    if not x.live then return end
    local id = x.live
    made[id] = nil
    removedAt[id] = GetGameTimer()
    CreateThread(function()
        local ok, why = Callback('whip_core:director:liveRemove', id)
        if not ok then say(why or 'It could not be removed', 'error') end
    end)
end

--- Once a frame: mine found as they come, the list's rows following their things, the server told where one went.
function handlers.frame(items, selected)
    local now = GetGameTimer()
    local sel = selected and items[selected] or nil
    -- A thing held to move, no longer the selection: let go, and its options back.
    if held and held.it ~= sel then
        local h = held
        held = nil
        Furnisher.letGo(h.it)
        if h.back then
            Furnisher.pause(true)
            h.back()
        end
    end
    -- Where each thing is now (not the one being moved: the markers have it).
    for i = #items, 1, -1 do
        local it = items[i]
        if it.world then
            -- (A moved prop is shown again as a new set: a new object, found under it.)
            if not (it.obj and DoesEntityExist(it.obj)) then it.obj = entityOf(it) end
            if it.obj and it ~= sel and not moving[it] then
                local c = GetEntityCoords(it.obj)
                it.x, it.y, it.z = c.x, c.y, c.z
                it.rz = GetEntityHeading(it.obj)
            end
        end
    end
    -- One stopped moving: the server hears.
    for it, at in pairs(moving) do
        if now - at >= MOVED_MS then
            moving[it] = nil
            moved(it)
        end
    end
    -- Mine not in the list yet (just made, or come into range).
    if now >= findAt then
        findAt = now + FIND_MS
        for _, m in pairs(made) do
            if not m.it then
                local ent = entityOf({ extra = { netId = m.view.netId, wire = m.view.wire } })
                if ent then m.it, m.lostAt = Furnisher.hold(rowOf(m.view, ent), false), nil end
                -- (One an option just made: selected, its markers on it.)
                if m.it and m.select then
                    m.select = nil
                    Furnisher.select(m.it)
                end
            elseif not m.it.obj then
                -- Gone a while (out of range): out of the list until back. (A moment is a moved prop shown again.)
                m.lostAt = m.lostAt or now
                if now - m.lostAt >= LOST_MS then
                    Furnisher.letGo(m.it)
                    m.it, m.lostAt = nil, nil
                end
            else
                m.lostAt = nil
            end
        end
    end
    -- The server's list again: one removed elsewhere goes from mine.
    if now >= syncAt then
        syncAt = now + SYNC_MS
        -- The answer is as things stood when asked: one removed here since is not brought back, one made since is kept.
        local askedAt = GetGameTimer()
        CreateThread(function()
            local r = Callback('whip_core:director:liveList')
            if not live or type(r) ~= 'table' then return end
            local up = {}
            for _, v in ipairs(type(r.mine) == 'table' and r.mine or {}) do
                up[v.id] = true
                local m = made[v.id]
                if m then
                    m.view = v
                    if m.it and type(m.it.extra) == 'table' then m.it.extra.netId, m.it.extra.wire = v.netId, v.wire end
                elseif not (removedAt[v.id] and removedAt[v.id] >= askedAt) then
                    made[v.id] = { view = v, at = askedAt }
                end
            end
            for id, m in pairs(made) do
                if not up[id] and (m.at or 0) < askedAt then
                    if m.it then Furnisher.letGo(m.it) end
                    made[id] = nil
                end
            end
            -- (Forgotten once no answer asked before them can still come)
            for id, at in pairs(removedAt) do
                if at < askedAt then removedAt[id] = nil end
            end
        end)
    end
end

-- Open and close

local function closed()
    live = false
    held = nil
    made, removedAt = {}, {}
    if OvPanel.busy() then OvPanel.close() end
end

--- Open the builder on the live world. Answers true, or false and why.
function DirectorLive.open()
    if live then return false, 'It is open' end
    if not PlayerLoaded or PlayerIsDead then return false, 'Not now' end
    if (IsAnyUIOpen and IsAnyUIOpen()) or (FocusScreenUp and FocusScreenUp('none')) then return false, 'Close what is open first' end
    local vehicles, weapons = DirectorScreen.lists()
    made, held, findAt, syncAt = {}, nil, 0, 0
    live = true
    local ok, why = Furnisher.open({
        title = 'Dungeon Mode',
        noun = 'Dungeon Mode',
        rows = {},
        -- More is its Weapons alone (a spot or a door is a scenario's). Done: nothing to save, it only closes.
        page = { tabs = { 'catalog', 'npcs', 'vehicles', 'more', 'placed' }, done = 'Done', byName = true,
                 vehicles = vehicles, weapons = weapons, live = true },
        onDone = function() end,
        onClose = closed,
        live = handlers,
    })
    if not ok then
        live = false
        return false, why
    end
    say('Dungeon Mode: what you put down is made for everyone. Click anything in the world for its options.', 'info')
    return true
end

function DirectorLive.isOpen() return live end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and live then closed() end
end)

-- A logout closes it at once, before character select opens under it.
AddEventHandler('whip_core:player:logout', function()
    if live and Furnisher.close then Furnisher.close() end
end)
