-- Prop sets, client: this game's own copies of the server's prop sets (server/prop_sets.lua), made as they come within
-- range and removed as they leave, on the prop streamer (client/streamprops.lua). Not networked, frozen where put.
--
--   * A prop inside an MLO (`interior`) waits until the interior is ready at its spot for two seconds, so it is not
--     made outside its rooms or unfileable. It is then filed in its room (InteriorRooms.fileFurniture) and rechecked
--     once a second; one whose interior went or was remade is taken away and made again when the interior is back.
--   * A model this game does not have is skipped and said once.
--
-- Moving props (the server's PropSets.move): each piece's timeline is played from the moment the server named, against
-- the server's clock (client/clock.lua), so every game has the prop in the same place. Frame by frame only while a
-- piece in range is mid-move; still between.
--
-- A set that arrives is made at once (StreamProps.passNow), and a prop taken away waits a moment for its replacement
-- (`leaving`, below). A run's props are ready sets from its start, models loaded before a card shows them.

PropSets = {}

local RANGE = 150.0               -- metres: made within this, removed beyond it
local INTERIOR_SETTLE_MS = 2000
local LOOK_GAP_MS = 3000          -- an interior not looked at for longer may have gone: its two seconds start over
local WATCH_MS = 1000             -- the interior pieces' look
local FAST_TRIES, SLOW_EVERY = 30, 10
local GRACE_MS, HANDOVER_MS, NEAR_M = 150, 3000, 2.0   -- a prop taken away: see `leaving`

local sets = {}       -- [wireId] = { keys = { key, ... } }
local pieces = {}     -- [key] = { x, y, z, m, rx, ry, rz, interior, light, nocol, set = wireId }
local ents = {}       -- [key] = entity
local missing = {}    -- [model] = true: not in this game (said once)
local readySeen = {}  -- [interior id] = { since, last }: seen ready all along from `since`, last looked at `last`
local held = {}       -- [model hash] = how many props of ready sets hold it loaded (see `ready sets`, below)
local filing = {}     -- [key] = { made = interior, filed, key = room key, byRoom, tries, next }: interior pieces made
local motions = {}    -- [wireId] = { ver, list = { [index] = motion } }: a set's moving props (below)
local watching = false
local watchPass = 0

local function interiorAt(p) return GetInteriorAtCoords(p.x, p.y, p.z + 1.0) end

local function isReady(id)
    if not id or id == 0 then return false end
    local r = IsInteriorReady(id)
    return r == true or (type(r) == 'number' and r ~= 0)
end

--- Has this interior been ready for INTERIOR_SETTLE_MS? Looking at it counts.
local function settled(id)
    if not isReady(id) then
        if id then readySeen[id] = nil end
        return false
    end
    local now = GetGameTimer()
    local s = readySeen[id]
    if not s or now - s.last > LOOK_GAP_MS then
        s = { since = now }
        readySeen[id] = s
    end
    s.last = now
    return now - s.since >= INTERIOR_SETTLE_MS
end

local function interiorReady(p)
    if not p.interior then return true end
    return settled(interiorAt(p))
end

--- The interior the player stands in, looked at every pass (the streamer's beforePass), so it has settled already.
local function lookHere()
    local id = GetInteriorFromEntity(PlayerPedId())
    if id and id ~= 0 then settled(id) end
end

--- File an interior piece in its room (a lamp in limbo) and note how that went.
local function fileOne(f, obj, p)
    local roomKey, confirmed = nil, false
    if InteriorRooms then roomKey, confirmed = InteriorRooms.fileFurniture(obj, p.light == true) end
    if confirmed then
        f.filed, f.tries, f.key = true, 0, roomKey
        f.byRoom = InteriorRooms.fileByRoom(p.light == true)
    else
        f.filed, f.tries = false, f.tries + 1
        f.next = watchPass + (f.tries <= FAST_TRIES and 1 or SLOW_EVERY)
    end
end

local despawn   -- defined below

--- Rechecks interior pieces once a second while any is made (see the top of the file).
local function startWatch()
    if watching then return end
    watching = true
    CreateThread(function()
        local playerInterior = GetInteriorFromEntity(PlayerPedId())
        while next(filing) do
            watchPass = watchPass + 1
            local here = GetInteriorFromEntity(PlayerPedId())
            local walked = here ~= playerInterior
            playerInterior = here
            local gone = {}
            for key, f in pairs(filing) do
                local obj, p = ents[key], pieces[key]
                if not obj or not p or not DoesEntityExist(obj) then
                    gone[#gone + 1] = key
                else
                    local id = interiorAt(p)
                    local lost = f.filed and (GetInteriorFromEntity(obj) == 0
                        or (f.byRoom and f.key and InteriorRooms and not InteriorRooms.sameKey(GetRoomKeyFromEntity(obj), f.key)))
                    if id ~= f.made or not isReady(id) or lost then
                        gone[#gone + 1] = key
                    else
                        settled(id)
                        if not f.filed and (walked or watchPass >= f.next) then fileOne(f, obj, p) end
                    end
                end
            end
            for _, key in ipairs(gone) do despawn(key) end
            Wait(WATCH_MS)
        end
        watching = false
    end)
end

--- Props the world builder (client/director.lua) hides while it builds, so each is on screen once.
--- [key] = true; nil while nothing is hidden.
local hiddenNow = nil

local handedOver   -- defined below

--- Its model's hash, or nil when this game does not have it (said once). A gun (p.wpn) is its weapon's world model.
local function modelOf(p)
    if p.wpn then
        local w = GetWeapontypeModel(GetHashKey(p.wpn))
        if w and w ~= 0 and IsModelInCdimage(w) then return w end
    end
    -- A model by number: a map prop whose name this game may not know.
    local hash = p.m:match('^%d+$') and tonumber(p.m) or GetHashKey(p.m)
    if hash > 0x7FFFFFFF then hash = hash - 0x100000000 end
    if IsModelInCdimage(hash) then return hash end
    missing[p.m] = true
    print(('[whip_core:propsets] %s is not a model this game has: left out'):format(p.m))
    return nil
end

--- Let a model go unless a ready set holds it.
local function release(model)
    if not held[model] then SetModelAsNoLongerNeeded(model) end
end

local placeMoving   -- defined below
local watchAttached -- defined below
local parentOf, ride -- defined below, with the attached props

local function spawn(p)
    local key = p.key
    if ents[key] or missing[p.m] then return end
    if hiddenNow and hiddenNow[key] then return end
    if not interiorReady(p) then return end   -- retried next pass
    local hash = modelOf(p)
    if not hash then return end
    local model = LoadModel(hash)
    if not model then return end
    -- Loading waited: the set may have gone, or another pass made it.
    if pieces[key] ~= p or ents[key] then release(model) return end
    local obj = CreateObjectNoOffset(model, p.x, p.y, p.z, false, false, false)
    release(model)
    if not obj or obj == 0 then return end
    SetEntityRotation(obj, p.rx + 0.0, p.ry + 0.0, p.rz + 0.0, 2, false)
    FreezeEntityPosition(obj, true)
    if p.nocol then SetEntityCollision(obj, false, false) end
    -- Drawn as far as it is made (drawDistance), past its model's own draw distance.
    if p.dd then SetEntityLodDist(obj, p.dd) end
    SetEntityAsMissionEntity(obj, true, true)
    ents[key] = obj
    if p.att then
        -- On its parent at once, as it is made: left for the watch's next look (up to 250 ms), it stood frozen and solid
        -- where it was made, in a moving car's way (WLVF's second review).
        local parent = parentOf(p.att)
        if parent and parent ~= obj then ride(obj, parent, p.att) end
        watchAttached()
    end
    placeMoving(key)
    if p.interior then
        local f = { made = interiorAt(p), tries = 0, next = 0 }
        filing[key] = f
        fileOne(f, obj, p)
        startWatch()
    end
    handedOver(key)
end

local function deleteObj(obj)
    if obj and DoesEntityExist(obj) then
        SetEntityAsMissionEntity(obj, true, true)
        DeleteEntity(obj)
    end
end

despawn = function(key)
    local obj = ents[key]
    ents[key] = nil
    filing[key] = nil
    deleteObj(obj)
end

local followParents -- defined below, with the attached props

StreamProps.addStream({
    name = 'propSets',
    defs = function() return pieces end,
    range = function() return RANGE end,
    isSpawned = function(key) return ents[key] ~= nil end,
    spawn = spawn,
    despawn = despawn,
    beforePass = function()
        lookHere()
        followParents()
    end,
})

-- A prop taken away waits briefly for its replacement, since the server takes a changed set down and puts the new one
-- up in the same moment:
--   * the same prop again takes over its object (no blink);
--   * a new prop within NEAR_M that is not made yet keeps it up until that one is made, HANDOVER_MS at most;
--   * anything else goes after GRACE_MS.
local leaving = {}   -- [object] = { obj, p, f (its filing), graceUntil, handoverUntil, waitFor = { [key] = true } }
local sweeping = false

local function samePiece(a, b)
    return a.m == b.m and math.abs(a.x - b.x) < 0.01 and math.abs(a.y - b.y) < 0.01 and math.abs(a.z - b.z) < 0.01
        and math.abs(a.rx - b.rx) < 0.1 and math.abs(a.ry - b.ry) < 0.1 and math.abs(a.rz - b.rz) < 0.1
        and a.interior == b.interior and a.light == b.light and a.nocol == b.nocol and a.dd == b.dd
end

local function nearPiece(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz <= NEAR_M * NEAR_M
end

--- A listed prop not made yet that will be (not one this game lacks or the world builder hides).
local function toCome(k, q)
    return not ents[k] and not missing[q.m] and not (hiddenNow and hiddenNow[k])
end

local function sweepSoon()
    if sweeping then return end
    sweeping = true
    CreateThread(function()
        while next(leaving) do
            local now, done = GetGameTimer(), {}
            for obj, l in pairs(leaving) do
                for k in pairs(l.waitFor) do
                    if not pieces[k] then l.waitFor[k] = nil end   -- taken away itself before it was made
                end
                if next(l.waitFor) then
                    if now >= l.handoverUntil then done[#done + 1] = obj end
                elseif now >= l.graceUntil then
                    done[#done + 1] = obj
                end
            end
            for _, obj in ipairs(done) do leaving[obj] = nil; deleteObj(obj) end
            Wait(50)
        end
        sweeping = false
    end)
end

--- A prop of a set taken away: held back instead of deleted.
local function letGo(key, p)
    local obj = ents[key]
    ents[key] = nil
    local f = filing[key]
    filing[key] = nil
    if not obj or not DoesEntityExist(obj) then return end
    if not p then return deleteObj(obj) end
    local now = GetGameTimer()
    local l = { obj = obj, p = p, f = f, graceUntil = now + GRACE_MS, handoverUntil = now + HANDOVER_MS, waitFor = {} }
    for k, q in pairs(pieces) do   -- a new prop near it shown first (Show Prop before Hide Prop), not made yet
        if toCome(k, q) and nearPiece(p, q) then l.waitFor[k] = true end
    end
    leaving[obj] = l
    sweepSoon()
end

--- A new set's props: the same piece takes over its object; one near something going keeps that up.
local function takeOver(keys)
    for _, key in ipairs(keys) do
        local q = pieces[key]
        local took = false
        for obj, l in pairs(leaving) do
            if samePiece(l.p, q) and DoesEntityExist(obj) then
                leaving[obj] = nil
                ents[key] = obj
                if l.f then filing[key] = l.f; startWatch() end
                took = true
                handedOver(key)
                break
            end
        end
        if not took and toCome(key, q) then
            for _, l in pairs(leaving) do
                if nearPiece(l.p, q) then l.waitFor[key] = true end
            end
        end
    end
end

--- This prop was made: whatever was waiting for it alone goes now.
handedOver = function(key)
    for obj, l in pairs(leaving) do
        if l.waitFor[key] then
            l.waitFor[key] = nil
            if not next(l.waitFor) then
                leaving[obj] = nil
                deleteObj(obj)
            end
        end
    end
end

-- Ready sets (server PropSets.ready: a Director run's props) are never made. Each prop in range has its model held and
-- its interior looked at every pass, so a set shown there later is made at once. Released out of range or when the
-- set goes.
local readyPieces = {}   -- [key] = piece, replaced by a new table on every change
local holding = {}       -- [key] = the model hash this ready piece holds

local function hold(p)
    if holding[p.key] or missing[p.m] then return end
    local hash = modelOf(p)
    if not hash then return end
    RequestModel(hash)   -- not waited for
    holding[p.key] = hash
    held[hash] = (held[hash] or 0) + 1
end

local function unhold(key)
    local hash = holding[key]
    if not hash then return end
    holding[key] = nil
    local n = (held[hash] or 1) - 1
    if n > 0 then
        held[hash] = n
    else
        held[hash] = nil
        SetModelAsNoLongerNeeded(hash)
    end
end

StreamProps.addStream({
    name = 'propReady',
    defs = function() return readyPieces end,
    range = function() return RANGE end,
    isSpawned = function(key) return holding[key] ~= nil end,
    spawn = hold,
    despawn = unhold,
    beforePass = function()
        for key in pairs(holding) do
            local p = readyPieces[key]
            if p and p.interior then settled(interiorAt(p)) end
        end
    end,
})

--- A new pieces table on every change, never one changed in place: the streamer walks it with pairs and waits
--- mid-walk, and a key added under a walk breaks it.
local function copyOf(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function remove(wireId)
    local s = sets[wireId]
    if not s then return end
    sets[wireId] = nil
    motions[wireId] = nil
    if s.ready then
        local nextReady = copyOf(readyPieces)
        for _, key in ipairs(s.keys) do nextReady[key] = nil end
        readyPieces = nextReady
        for _, key in ipairs(s.keys) do unhold(key) end
        return
    end
    local old = pieces
    local nextPieces = copyOf(pieces)
    for _, key in ipairs(s.keys) do nextPieces[key] = nil end
    pieces = nextPieces
    for _, key in ipairs(s.keys) do letGo(key, old[key]) end
end

local function add(wireId, w)
    remove(wireId)
    if type(w) ~= 'table' or type(w.props) ~= 'table' then return end
    local ready = w.ready == true
    local s = { keys = {}, ready = ready }
    local nextPieces = copyOf(ready and readyPieces or pieces)
    for i, p in ipairs(w.props) do
        if type(p) == 'table' and type(p.m) == 'string' and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then
            local key = wireId .. ':' .. i
            nextPieces[key] = { key = key, set = wireId, m = p.m, x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0,
                                rx = tonumber(p.rx) or 0.0, ry = tonumber(p.ry) or 0.0, rz = tonumber(p.rz) or 0.0,
                                interior = p.interior == true, light = p.light == true, nocol = p.nocol == true,
                                wpn = type(p.wpn) == 'string' and p.wpn or nil, att = type(p.att) == 'table' and p.att or nil,
                                hx = p.x + 0.0, hy = p.y + 0.0, hz = p.z + 0.0 }
            -- Seen from further (drawDistance): made out to it (the streamer adds `reach` to the range) and drawn
            -- that far (spawn).
            local dd = math.tointeger(tonumber(p.dd))
            if dd and dd > 0 then
                nextPieces[key].dd = dd
                nextPieces[key].reach = math.max(0.0, dd - RANGE)
            end
            s.keys[#s.keys + 1] = key
        end
    end
    sets[wireId] = s
    if ready then
        readyPieces = nextPieces
        StreamProps.passNow('propReady')
        return
    end
    pieces = nextPieces
    takeOver(s.keys)
    StreamProps.passNow('propSets')
end

RegisterNetEvent('whip_core:client:propSet', function(wireId, w)
    if type(wireId) ~= 'number' then return end
    if w == false then remove(wireId) else add(wireId, w) end
end)

--- Every set this character gets, at once; the old ones go first.
RegisterNetEvent('whip_core:client:propSets', function(list)
    local ids = {}
    for id in pairs(sets) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do remove(id) end
    for _, e in ipairs(type(list) == 'table' and list or {}) do
        if type(e) == 'table' and type(e.id) == 'number' then add(e.id, e.w) end
    end
end)

-- Moving props: the timelines

local moverOn = false

--- Ease in and out along a slide, turn or fade.
local function ease(f) return f * f * (3.0 - 2.0 * f) end

local function turnBetween(a, b, f)
    local d = ((b - a + 180.0) % 360.0) - 180.0
    return a + d * f
end

--- Where a timeline has its prop at server time `now`: x, y, z, heading, alpha (0-255), look, and whether it is mid-move.
local function poseAt(p, m, now)
    local x, y, z, h, alpha, look = p.x, p.y, p.z, p.rz, 255, nil
    local total = 0
    for _, s in ipairs(m.steps) do total = total + (s.ms or 0) end
    local t = now - m.at
    if m.stop then t = math.min(t, m.stop - m.at) end
    if m.loop and total > 0 and t > 0 then t = t % total end
    if t < 0 then return x, y, z, h, alpha, look, false end
    local at, moving = 0, false
    for _, s in ipairs(m.steps) do
        local d = s.ms or 0
        local f = d > 0 and math.max(0.0, math.min(1.0, (t - at) / d)) or (t >= at and 1.0 or 0.0)
        if t < at then break end
        if f > 0 and f < 1 and not m.stop then moving = true end
        local q = s.p or {}
        if s.t == 'slideTo' and q.at then
            local e = ease(f)
            x, y, z = x + (q.at.x - x) * e, y + (q.at.y - y) * e, z + (q.at.z - z) * e
        elseif s.t == 'turnTo' then
            h = turnBetween(h, tonumber(q.heading) or h, ease(f))
        elseif s.t == 'teleport' and q.at then
            x, y, z, h = q.at.x, q.at.y, q.at.z, tonumber(q.at.heading) or h
        elseif s.t == 'fade' then
            alpha = alpha + ((math.floor((tonumber(q.pct) or 0) * 2.55)) - alpha) * f
        elseif s.t == 'look' then
            look = math.floor(tonumber(q.variant) or 0)
        end
        at = at + d
    end
    return x, y, z, h, math.floor(alpha + 0.5), look, moving
end

local function motionOf(key)
    local p = pieces[key]
    if not p then return nil end
    local mo = motions[p.set]
    local i = tonumber(key:match(':(%d+)$'))
    return mo and i and mo.list[i] or nil, p
end

local function apply(obj, p, m, now)
    -- Attached, it goes where its parent goes: the timeline does not move it.
    if p.att and IsEntityAttached(obj) then return false end
    local x, y, z, h, alpha, look, moving = poseAt(p, m, now)
    SetEntityCoordsNoOffset(obj, x, y, z, false, false, false)
    SetEntityRotation(obj, p.rx + 0.0, p.ry + 0.0, h + 0.0, 2, false)
    if alpha >= 255 then ResetEntityAlpha(obj) else SetEntityAlpha(obj, alpha, false) end
    if look then SetObjectTextureVariation(obj, look) end
    return moving
end

--- Puts a prop where a timeline has it at `now` (p = { x, y, z, rx, ry, rz }, m = { steps, at, loop }); used by
--- client/director_preview.lua. Returns whether it is mid-move.
PropSets.applyMotion = apply

local function startMover()
    if moverOn then return end
    moverOn = true
    CreateThread(function()
        while true do
            local any, busy = false, false
            local now = Clock.now()
            for key, obj in pairs(ents) do
                local m, p = motionOf(key)
                if m and DoesEntityExist(obj) then
                    any = true
                    if apply(obj, p, m, now) then busy = true end
                end
            end
            if not any then break end
            -- Every frame while one is mid-move; a quarter second while all are still.
            Wait(busy and 0 or 250)
        end
        moverOn = false
    end)
end

--- A prop just made: placed where its timeline has it now.
placeMoving = function(key)
    local m, p = motionOf(key)
    local obj = ents[key]
    if not m or not obj then return end
    apply(obj, p, m, Clock.now())
    startMover()
end

RegisterNetEvent('whip_core:client:propMotions', function(wireId, ver, list)
    if type(wireId) ~= 'number' or type(ver) ~= 'number' then return end
    -- Before the clock answers, timelines read this game's own time; the mover's next pass corrects it.
    if not Clock.synced() then Clock.sync() end
    local mo = { ver = ver, list = {} }
    for i, m in pairs(type(list) == 'table' and list or {}) do
        local n = tonumber(i)
        if n and type(m) == 'table' and type(m.steps) == 'table' and tonumber(m.at) then mo.list[n] = m end
    end
    motions[wireId] = mo
    -- No timeline any more: back where it was placed.
    for key, obj in pairs(ents) do
        local p = pieces[key]
        if p and p.set == wireId and DoesEntityExist(obj) then
            local i = tonumber(key:match(':(%d+)$'))
            if not mo.list[i] then
                SetEntityCoordsNoOffset(obj, p.x, p.y, p.z, false, false, false)
                SetEntityRotation(obj, p.rx + 0.0, p.ry + 0.0, p.rz + 0.0, 2, false)
                ResetEntityAlpha(obj)
            end
        end
    end
    startMover()
    TriggerServerEvent('whip_core:server:propMotions', wireId, ver)
end)

--- Hide every prop standing where one of these rows is (same model within 2 cm) until PropSets.showHidden().
---@param rows table  { { model, x, y, z }, ... }
function PropSets.hideLike(rows)
    local hide = {}
    for key, p in pairs(pieces) do
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            if type(r.model) == 'string' and p.m == r.model:lower() and math.abs(p.x - (tonumber(r.x) or 0)) < 0.02
                and math.abs(p.y - (tonumber(r.y) or 0)) < 0.02 and math.abs(p.z - (tonumber(r.z) or 0)) < 0.02 then
                hide[key] = true
                break
            end
        end
    end
    hiddenNow = hide
    for key in pairs(hide) do despawn(key) end
end

--- The hidden props come back on the streamer's next pass.
function PropSets.showHidden()
    hiddenNow = nil
end

-- Attached props: a piece with `att` goes on its parent (a networked car or NPC by netId, or another set's piece
-- (wire, i)) once this game has both. Checked four times a second while any is made: reattached when needed, and put
-- back where placed when the parent goes. Its streaming spot follows a networked parent.

local attachOn = false

parentOf = function(att)
    if att.net then
        if not NetworkDoesNetworkIdExist(att.net) then return nil end
        local e = NetworkGetEntityFromNetworkId(att.net)
        return e ~= 0 and DoesEntityExist(e) and e or nil
    end
    local e = att.wire and ents[att.wire .. ':' .. tostring(att.i)]
    return e and DoesEntityExist(e) and e or nil
end

--- A made piece on its parent, riding it (not frozen: it moves with it).
ride = function(obj, parent, a)
    FreezeEntityPosition(obj, false)
    AttachEntityToEntity(obj, parent, 0, a.x + 0.0, a.y + 0.0, a.z + 0.0, a.rx + 0.0, a.ry + 0.0, a.rz + 0.0,
        false, false, false, false, 2, true)
end

--- Where a piece riding `parent` is in the world now: its own spot on it (never the parent's middle, inside it).
local function spotOn(parent, a)
    return GetOffsetFromEntityInWorldCoords(parent, a.x + 0.0, a.y + 0.0, a.z + 0.0)
end

--- Before each streaming pass: a piece riding a networked car or NPC is measured from where its parent is NOW,
--- whether or not this game has made it. (Its spot followed the parent only while made — watchAttached below — so a
--- speaker on a car that drove more than RANGE away was taken away and kept the spot where it was left: when the car
--- came back it was never made again, and a game never near where it was put down never made it at all. 14 Nov 2026.)
--- A parent this game does not have (gone, or out of its scope) puts it back where it was placed, as a made one is.
followParents = function()
    for key, p in pairs(pieces) do
        if p.att and p.att.net and not ents[key] then
            local parent = parentOf(p.att)
            if parent then
                local c = spotOn(parent, p.att)
                p.x, p.y, p.z = c.x, c.y, c.z
            else
                p.x, p.y, p.z = p.hx, p.hy, p.hz
            end
        end
    end
end

watchAttached = function()
    if attachOn then return end
    attachOn = true
    CreateThread(function()
        while true do
            local any = false
            for key, obj in pairs(ents) do
                local p = pieces[key]
                if p and p.att and DoesEntityExist(obj) then
                    any = true
                    local parent = parentOf(p.att)
                    if parent and parent ~= obj then
                        if not IsEntityAttachedToEntity(obj, parent) then ride(obj, parent, p.att) end
                        if p.att.net then
                            local c = spotOn(parent, p.att)
                            p.x, p.y, p.z = c.x, c.y, c.z
                        end
                    elseif IsEntityAttached(obj) then
                        DetachEntity(obj, false, false)
                        p.x, p.y, p.z = p.hx, p.hy, p.hz
                        SetEntityCoordsNoOffset(obj, p.x, p.y, p.z, false, false, false)
                        SetEntityRotation(obj, p.rx + 0.0, p.ry + 0.0, p.rz + 0.0, 2, false)
                        FreezeEntityPosition(obj, true)
                    end
                end
            end
            if not any then break end
            Wait(250)
        end
        attachOn = false
    end)
end

--- A set's piece (used by client/director_weapons.lua): its object (nil while not made here) and its data
--- ({ m, wpn, x, y, z, rx, ry, rz, att }).
function PropSets.pieceOf(wireId, index)
    local key = tostring(wireId) .. ':' .. tostring(index)
    local obj = ents[key]
    return obj and DoesEntityExist(obj) and obj or nil, pieces[key]
end

--- Which set's piece an object is: wireId, index, or nil.
function PropSets.ofEntity(entity)
    for key, obj in pairs(ents) do
        if obj == entity then
            local wire, i = key:match('^(%d+):(%d+)$')
            return tonumber(wire), tonumber(i)
        end
    end
    return nil
end

--- How many props are made now, and how many are listed.
function PropSets.counts()
    local made, listed = 0, 0
    for _ in pairs(ents) do made = made + 1 end
    for _ in pairs(pieces) do listed = listed + 1 end
    return made, listed
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for key in pairs(ents) do despawn(key) end
    for obj in pairs(leaving) do deleteObj(obj) end
    leaving = {}
    for key in pairs(holding) do unhold(key) end
end)
