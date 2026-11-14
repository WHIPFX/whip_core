-- ============================================
-- PROPERTY OBJECTS — the furniture, Client
-- ============================================
--
-- A property's furniture exists only while the property is streamed in (client/properties.lua
-- calls PropertyStreamedIn / PropertyStreamedOut). All of it goes in at once and comes out at once:
-- if you are near enough to see one chair you are near enough to see the room.
--
-- And only for the nearest few: in an apartment tower every flat is inside the 60 m stream. At most
-- Config.PropertyFurnitureRooms furnished properties are furnished on screen: the one you are
-- standing in, then the nearest. Re-chosen as you move.
--
-- Fetched, and cached by version: login brings one version number per furnished property; the rows
-- are asked for when a property first streams in, and again only when the server says its version
-- moved (propertyObjectsChanged).
--
-- Local rows, placed here, relative to the property's placement, so a property re-bound to a moved
-- interior brings its furniture with it.
--
-- Non-networked, collision on, frozen.
--
-- Filed in its room (InteriorRooms.put): the game files a CreateObject by wherever its origin lands
-- (often a wall, or nowhere when the interior had not loaded) and draws it only with that room. Each
-- object is filed in the room holding its middle, and kept filed (see `filing` below).
--
-- Except lamps, which go in the interior's limbo: a lamp forced into a room glows and lights
-- nothing. The server marks lamps (`light`, from the catalog); client/interior_rooms.lua has the why
-- and the /furnfiling switch.

local index   = {}   -- [propertyId] = { v = version, n = count } from the server
local cache   = {}   -- [propertyId] = { v = version, rows = { local rows } }
local spawned = {}   -- [propertyId] = { entity, ... } while in the world
local paused  = {}   -- [propertyId] = true while the furnisher owns the room
local loading = {}   -- [propertyId] = true while its rows are being fetched
local allowed = {}   -- [propertyId] = true for the rooms chosen to be furnished (chooseRooms)
-- [entity] = true while a spawn loop is still making its set: a set only reaches `spawned` once
-- every object is up, so a stop in between must still find the ones already made.
local making  = {}
-- Filing is kept up for as long as the piece exists: furniture streams back in 60 m out, where the
-- game may refuse a room or the interior may not be readable. Nothing is given up on:
--   walking into or out of an interior   every piece is tried at once — that is when a refusal
--                                        from outside turns into a room taken from inside
--   inside the property                  once a second, its pieces: filed ones checked (still in
--                                        their room? one cheap native) and filed again if not; the
--                                        rest tried every pass for FAST_TRIES, then every SLOW_EVERY-th
--   anywhere else                        nothing (from the street the answer cannot change; walking
--                                        in already tries everything)
local filing = {}      -- [entity] = { property, key, last = 'filed' | 'waiting' | 'refused', tries, next, interior, byRoom }
-- [propertyId] = true: its set was made through the grace (standing in it, its interior there and not
-- ready: "The interior first" below), so it is made again once that interior says ready.
local madeUnready = {}
-- [entity] = the interior the game put a piece in when it was made, before whip filed it (a new
-- object put in NO interior means its lamps stay dark). For the warning in bringIn.
local madeIn = {}
-- The floor ("The floor first", in bringIn): the interior found live and ready by the last
-- look, sets made while their floor was not that interior's, and the line said about it.
local liveOf = {}        -- [propertyId] = interior number
local madeUnlinked = {}  -- [propertyId] = true
local saidUnlinked = {}  -- [propertyId] = true, said once a session
local floorWaitUntil = {}  -- [propertyId] = when its wait for the floor gives up (despawn clears it)
-- [propertyId] = passes in a row its set's interior was not found ready (see the pass: one miss is
-- not an unload, for a placement that names its archetype).
local missed = {}
local pass = 0         -- the once-a-second pass's count
local playerInterior = 0   -- the player's interior at the last pass, to see them walk in or out
local FAST_TRIES, SLOW_EVERY = 30, 10

--- File an object in the room holding its middle, and note how that went.
---   filed     the game has it in its room
---   waiting   its interior cannot be read from where the player is yet
---   refused   told, and the game kept it where it was
local function fileInRoom(obj, propertyId, isLight)
    local f = filing[obj]
    if not f then f = { property = propertyId, tries = 0, light = isLight == true }; filing[obj] = f end
    local key, confirmed = nil, false
    -- A lamp in the interior's limbo, everything else in its room: a lamp forced into a room lights
    -- nothing (client/interior_rooms.lua).
    if InteriorRooms then key, confirmed = InteriorRooms.fileFurniture(obj, f.light) end
    if key then f.key = key end
    if confirmed then
        f.tries, f.last = 0, 'filed'
        f.next = pass + 1
        -- What it was filed in, to see it lost (interiorReloaded below): an interior, and a room
        -- unless it went in limbo (where the game may answer 0 for the room).
        f.interior = GetInteriorFromEntity(obj)
        f.byRoom = InteriorRooms.fileByRoom(f.light)
    else
        f.tries = f.tries + 1
        f.last = key and 'refused' or 'waiting'
        f.next = pass + (f.tries <= FAST_TRIES and 1 or SLOW_EVERY)
    end
end

local function place(propertyId)
    local defs = GetPropertyDefs and GetPropertyDefs() or {}
    local p = defs[propertyId]
    return p and p.place or nil
end

--- A local row in world space: position and rotation, with the placement's yaw added to Z.
---
--- `extra.stash`: the stash this piece is (server/property_stashes.lua). The furnisher keeps `extra` with
--- the piece and sends it back with it, which is how the stash stays with its furniture through a save.
local function toWorldRow(pl, r)
    local x, y, z = PropertyMath.toWorld(pl, r.lx or 0.0, r.ly or 0.0, r.lz or 0.0)
    local stash = math.tointeger(tonumber(r.stash))
    return {
        id = r.id, model = r.model, x = x, y = y, z = z,
        rx = r.rx or 0.0, ry = r.ry or 0.0, rz = PropertyMath.headingToWorld(pl, r.rz or 0.0),
        light = r.light == true,   -- a lamp: the server marks it from the catalog
        stash = stash,
        extra = stash and { stash = stash } or nil,
    }
end

-- The piece each stash is, while it stands in the world: its prompt goes round it (client/containers.lua).
local stashObj = {}   -- [containerId] = entity
local objStash = {}   -- [entity] = containerId

--- The piece of furniture a property's stash is, or nil while it is not in the world.
---@return number|nil entity
function PropertyStashEntity(containerId)
    local obj = stashObj[containerId]
    if obj and DoesEntityExist(obj) then return obj end
    return nil
end

local function spawnOne(w, propertyId)
    local model = GetHashKey(w.model)
    if not IsModelValid(model) or not LoadModel(model) then return nil end

    -- No offset: exactly where it was saved. CreateObject lifts some models on the Z axis (a wall
    -- shelf), and the furnisher saves the exact position (SetEntityCoordsNoOffset).
    local obj = CreateObjectNoOffset(model, w.x, w.y, w.z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not obj or obj == 0 then return nil end
    -- Rotation order 2, the order the furnisher composes angles in.
    madeIn[obj] = GetInteriorFromEntity(obj)   -- where the game put it, before anything files it
    SetEntityRotation(obj, w.rx, w.ry, w.rz, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityLodDist(obj, 300)
    -- After the rotation: its middle is worked out from where it actually stands. A lamp in limbo,
    -- the rest in its room; not at all under /furnfiling none (client/interior_rooms.lua).
    if not InteriorRooms or InteriorRooms.furnitureMode() ~= 'none' then fileInRoom(obj, propertyId, w.light) end
    return obj
end

-- ============================================
-- How far along a property's furniture is
-- ============================================
--
-- For an interior resource that keeps its windows covered until the room behind them is finished
-- (Mirror Park Homes): GetInteriorFurnishState (the bottom of this file) answers
--   'pending'  it will be made, or made again, and is not up yet: waiting for its interior, the settle,
--              the rows, the floor, or a remake after whip_core:interiorRefreshed
--   'done'     it is up (or the furnisher has the room: its copies stand in for it)
--   'none'     nothing to wait for: no saved furniture, or not a property's interior
--   'idle'     it has furniture, and is not to be made now (too far, or not among the nearest)
-- and says each change as whip_core:property:furnishStateChanged { propertyId, interiorId, state }.

--- A property's state, as above. `interiorId`: the copy of its interior asked about. A set standing
--- on another copy is about to go (the pass sees it lost), so that copy's answer is 'pending'.
local function furnishState(propertyId, interiorId)
    local w = index[propertyId]
    if not w or (w.n or 0) == 0 then return 'none' end
    if paused[propertyId] then return 'done' end
    if spawned[propertyId] then
        local live = liveOf[propertyId]
        if interiorId == nil or live == nil or live == interiorId then return 'done' end
        return 'pending'
    end
    return allowed[propertyId] and 'pending' or 'idle'
end

local lastState = {}   -- [propertyId] = the state last said

--- Say a property's state if it changed. A first look that finds it at rest ('idle', 'none') says
--- nothing: login brings every furnished property, and none of them has moved.
local function noteState(propertyId)
    local state = furnishState(propertyId)
    local was = lastState[propertyId]
    if was == state then return end
    lastState[propertyId] = state
    if was == nil and (state == 'idle' or state == 'none') then return end
    WhipEmit('whip_core:property:furnishStateChanged',
        { propertyId = propertyId, interiorId = liveOf[propertyId], state = state })
end

local function despawn(propertyId)
    floorWaitUntil[propertyId] = nil   -- a room let go (or remade) waits for its floor afresh next time
    local list = spawned[propertyId]
    if not list then noteState(propertyId) return end
    for _, obj in ipairs(list) do
        filing[obj], madeIn[obj] = nil, nil
        local s = objStash[obj]
        if s then
            objStash[obj] = nil
            if stashObj[s] == obj then stashObj[s] = nil end
        end
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    spawned[propertyId] = nil
    madeUnready[propertyId] = nil
    madeUnlinked[propertyId] = nil
    missed[propertyId] = nil
    WhipEmit('whip_core:property:unfurnished', { propertyId = propertyId, interiorId = liveOf[propertyId] })
    noteState(propertyId)
end

--- Is this room still wanted in the world: near, one of the rooms chosen, and not handed to the
--- furnisher?
local function wanted(propertyId)
    return not paused[propertyId] and allowed[propertyId] == true
        and IsPropertyNear ~= nil and IsPropertyNear(propertyId) == true
end

-- ============================================
-- The interior first
-- ============================================
--
-- Furniture is made only once its interior is there, and goes when the interior goes. An MLO need
-- not be loaded just because its property is near (Mirror Park's loader brings each home's interior
-- in within ~52 m; furniture streams at 60 m), and a lamp made before its interior exists glows and
-- lights nothing however it is filed afterwards. So a set waits until its interior is loaded AND
-- ready, for a second so it has settled, and is taken away when it stops being so.

local READY_SETTLE_MS = 1000
local WAIT_SAY_MS = 15000
local INSIDE_GRACE_MS = 5000   -- standing in it, an interior there and not ready is waited for this long first
local REBUILD_GAP_MS = 30000   -- a set made again because its interior was reloaded: at most this often
local readySince = {}    -- [propertyId] = when its interior was first seen ready, this stretch
local waitingSince = {}  -- [propertyId] = when it began waiting for its interior (to say so once)
local insideSince = {}   -- [propertyId] = when, standing in it, its interior was first there and not ready
local rebuiltAt = {}     -- [propertyId] = when its set was last made again (interiorReloaded)

-- ============================================
-- Which interior is the property's
-- ============================================
--
-- The spot's answer is not enough: GetInteriorAtCoords answers with whatever interior covers the
-- point, which may be a neighbour's, Rockstar's tunnel under Mirror Park (id2_21_a_tun1, never
-- ready), or a DEAD COPY of the house a loader left behind (same design, same spot, never ready).
--
-- So an interior counts only if it is THE PROPERTY'S (its archetype the placement's, place.hash,
-- standing at the placement, PLACE_MATCH_M), and the live one among those is found four ways:
--   the typed lookup at the placement   GetInteriorAtCoordsWithTypehash, a metre above its origin:
--   and at its anchor                   other designs and the tunnel never answer it, but a dead
--                                       copy can, and so can a neighbour of the same design (a Mega
--                                       flat's origin lies inside the flat next door's box). The
--                                       anchor, in the middle of the flat, is inside its own.
--   standing in it                      the interior the game has the player in
--   a test object at the anchor         made, asked which interior the game put it in, and deleted
--                                       in the same frame: from outside, past a dead copy
-- The last two are the property's own evidence, so only they may speak up about something odd: an
-- interior of its design off its placement, or an interior at its placement of ANOTHER design — the
-- archetype hash on record out of date, which is taken by its position (as the spot was before) and
-- said once. A placement with no archetype hash on record is asked the old way: the spot, any
-- interior.
local PLACE_MATCH_M = 2.0      -- same-design flats sit 4-6 m apart in Mega; a dead copy sits on the spot
local TEST_EVERY_MS = 1000     -- a test object at most this often, per property
-- Small, and checked against the game's object list (server/prop_catalog_seed.lua).
local TEST_MODEL = GetHashKey('prop_soap_disp_01')
local tested = {}              -- [propertyId] = { at, id }: the last test object's interior
local saidOff = {}             -- [propertyId] = true: its design found off its placement, said once
local saidStale = {}           -- [propertyId] = true: another design at its placement, said once

local function readyNum(id)
    if not id or id == 0 then return false end
    local r = IsInteriorReady(id)
    return r == true or (type(r) == 'number' and r ~= 0)
end

--- What interior `id` is to the property:
---   'own'    its archetype, at its placement
---   'stale'  at its placement, another archetype (the hash on record out of date)
---   'off'    its archetype, elsewhere (a neighbour of the same design, or a placement off)
---   nil      nothing to do with it
---@return string|nil verdict, number|nil distance, number|nil namehash
local function judge(id, pl)
    if not id or id == 0 or not InteriorRooms then return nil end
    local ok, loc, hash = pcall(GetInteriorLocationAndNamehash, id)
    if not ok or not loc then return nil end
    local d = math.sqrt((loc.x - pl.x) ^ 2 + (loc.y - pl.y) ^ 2 + (loc.z - pl.z) ^ 2)
    local same = InteriorRooms.sameKey(hash, pl.hash)
    if d <= PLACE_MATCH_M then return same and 'own' or 'stale', d, hash end
    return same and 'off' or nil, d, hash
end

--- One answer, weighed: 'ready' (the property's own, live and ready), 'there' (its own, not ready
--- yet), or nil. `evidence`: the answer is where the player or a new object actually is (not a lookup
--- at a point), so it may take a stale hash by position, and may say what it found.
local function weigh(propertyId, pl, id, evidence)
    local v, d, hash = judge(id, pl)
    if v == 'stale' and evidence then
        if not saidStale[propertyId] then
            saidStale[propertyId] = true
            print(('[whip_core:props] property %s: the interior at its placement is archetype %s, not the %s on record; taken by its position (update the property\'s template)')
                :format(tostring(propertyId), tostring(hash), tostring(pl.hash)))
        end
        v = 'own'
    elseif v == 'off' and evidence and not saidOff[propertyId] then
        saidOff[propertyId] = true
        print(('[whip_core:props] property %s: %s an interior of its design %.1f m from its placement; not taken as its own (if this keeps happening, check the placement)')
            :format(tostring(propertyId), (id == GetInteriorFromEntity(PlayerPedId())) and 'you are in' or 'a new object there landed in', d))
    end
    if v ~= 'own' then return nil end
    return readyNum(id) and 'ready' or 'there'
end

--- The interior the game puts a new object in at the anchor: made and deleted in one frame, so it is
--- never drawn and never touched; at most every TEST_EVERY_MS. NIL when it could not be tried (the
--- model not loaded yet), which is not the same as 0, "put in no interior".
local function testAt(propertyId, p)
    local now = GetGameTimer()
    local t = tested[propertyId]
    if t and now - t.at < TEST_EVERY_MS then return t.id end
    if not IsModelValid(TEST_MODEL) then return nil end
    if not HasModelLoaded(TEST_MODEL) then RequestModel(TEST_MODEL) return nil end
    local id = 0
    local obj = CreateObjectNoOffset(TEST_MODEL, p.x, p.y, p.z, false, false, false)
    if obj and obj ~= 0 then
        id = GetInteriorFromEntity(obj)
        DeleteEntity(obj)
    end
    tested[propertyId] = { at = now, id = id }
    return id
end

--- Is the property's interior there and ready to hold furniture? Asked at its placement's origin, a
--- metre up (where the loaders ask), and at its anchor (the middle of its space).
---
--- There is not enough: it must be READY. A Mirror Park home's interior is there from about 52 m but
--- only ready from about 32 m, and furniture made in between has dark lamps.
---
--- Standing in it, there is enough, after a while: an interior can be there and never say ready, so
--- inside the property it is taken as ready after INSIDE_GRACE_MS (not at once: on joining inside a
--- home it is often there a moment before it is ready). A set made through the grace is made again if
--- the interior does say ready later (madeUnready).
---
--- Which interior is asked is "Which interior is the property's" above: its own, live, when its
--- placement names an archetype; any at the spot otherwise.
---@param strict boolean|nil  ready only (no grace)
local function interiorReady(propertyId, strict)
    local defs = GetPropertyDefs and GetPropertyDefs() or {}
    local p = defs[propertyId]
    if not p then return false end
    local there = false
    local pl = p.place
    local here = GetCurrentProperty and GetCurrentProperty()
    local inside = here ~= nil and here.id == propertyId
    liveOf[propertyId] = nil   -- the interior this look finds live and ready (the floor check asks it)
    if pl and pl.x and pl.hash and pl.hash ~= 0 then
        -- Its own, live: the typed lookups first (all a healthy house needs), then the interior the
        -- game has the player in, then a test object at the anchor — past a dead copy (above).
        local function ready() insideSince[propertyId] = nil return true end
        -- Each answer weighed as it comes, even one an earlier route gave: a number from a lookup at a
        -- point and the same number from where an object landed are different evidence.
        local function try(id, evidence)
            if not id or id == 0 then return false end
            local w = weigh(propertyId, pl, id, evidence)
            if w == 'there' then there = true end
            if w == 'ready' then liveOf[propertyId] = id end
            return w == 'ready'
        end
        if try(GetInteriorAtCoordsWithTypehash(pl.x, pl.y, pl.z + 1.0, pl.hash), false) then return ready() end
        if p.x and try(GetInteriorAtCoordsWithTypehash(p.x, p.y, p.z, pl.hash), false) then return ready() end
        if inside and try(GetInteriorFromEntity(PlayerPedId()), true) then return ready() end
        if p.x and try(testAt(propertyId, p), true) then return ready() end
        -- Standing in some interior that is none of the above (an archetype changed and moved): the
        -- grace below furnishes it, as it did before.
        if not there and inside and GetInteriorFromEntity(PlayerPedId()) ~= 0 then there = true end
    else
        if pl and pl.x then
            local id = GetInteriorAtCoords(pl.x, pl.y, pl.z + 1.0)
            if id ~= 0 then
                if IsInteriorReady(id) then insideSince[propertyId] = nil return true end
                there = true
            end
        end
        if p.x then
            local id = GetInteriorAtCoords(p.x, p.y, p.z)
            if id ~= 0 then
                -- (No liveOf here: this lookup may answer a neighbour, so the floor check has nothing
                -- to hold the floor to.)
                if IsInteriorReady(id) then insideSince[propertyId] = nil return true end
                there = true
            end
        end
    end
    if strict then return false end
    if there and inside then
        local now = GetGameTimer()
        local since = insideSince[propertyId]
        if not since then insideSince[propertyId] = now return false end
        return now - since >= INSIDE_GRACE_MS
    end
    insideSince[propertyId] = nil
    return false
end

--- Was its interior reloaded under it? A loader can take a home's interior away and bring it back
--- between two once-a-second looks; the furniture then sits on an interior it was not made in, its
--- lamps dark however it is filed. The pieces show it: one the game had filed has lost its interior,
--- or its room. Then the set is made again (once the interior is back and ready), not filed again.
local function interiorReloaded(propertyId)
    for _, obj in ipairs(spawned[propertyId] or {}) do
        local f = filing[obj]
        if f and f.last == 'filed' and DoesEntityExist(obj) then
            if (f.interior or 0) ~= 0 and GetInteriorFromEntity(obj) == 0 then return true end
            if f.byRoom and f.key and InteriorRooms and not InteriorRooms.sameKey(GetRoomKeyFromEntity(obj), f.key) then
                return true
            end
        end
    end
    return false
end

--- Ready, and for long enough to have settled. Says once if a wanted room waits a long while — its
--- interior may never be found where it is asked for.
local function interiorSettled(propertyId)
    local now = GetGameTimer()
    if not interiorReady(propertyId) then
        readySince[propertyId] = nil
        local w = waitingSince[propertyId]
        if not w then
            waitingSince[propertyId] = now
        elseif w > 0 and now - w > WAIT_SAY_MS then
            waitingSince[propertyId] = -1   -- said
            print(('[whip_core:props] property %s: its interior has not been ready in %ds — its furniture waits for it (or for you to walk in)')
                :format(tostring(propertyId), WAIT_SAY_MS // 1000))
        end
        return false
    end
    waitingSince[propertyId] = nil
    local since = readySince[propertyId]
    if not since then readySince[propertyId] = now return false end
    return now - since >= READY_SETTLE_MS
end

-- ============================================
-- The floor first
-- ============================================
--
-- A new object takes its interior from the floor under it, and a lamp's light is settled when it is
-- made: where the game has the house's floor collision marked OUTSIDE (FiveM can leave a house's
-- collision behind across a reconnect, and an MLO reloaded at the wrong moment comes back on it),
-- every lamp glows and lights nothing. Waiting does not mend it; a full FiveM restart does.
--
-- Asked only a metre above a floor: you, if you are standing in the property; its visit point; its
-- lowest pieces (not its anchor, which can be in the slab between two storeys). Called broken only on
-- evidence: a point inside one of the interior's own rooms whose floor the game marks outside.
--
-- So a set waits, up to FLOOR_WAIT_MS, while its floor is shown outside. The wait is the property's,
-- not the try's: a look that loses the interior for a moment (a threshold) and starts again later
-- finishes the time that was left. If the floor never comes right, the set is made anyway —
-- furniture with dark lamps beats none — and the console says why, once; and if the floor is its
-- interior's later, the set is made again.
local FLOOR_WAIT_MS, FLOOR_LOOK_MS, FLOOR_SAMPLES = 8000, 500, 4

--- The floor at the property, as the game files it:
---   'linked'   its live interior's (a lamp made now lights the room)
---   'outside'  marked outside, belonging to no interior, at a point inside one of its rooms
---   'unknown'  nothing to compare (no live interior known; a placement with no archetype hash; the
---              native missing), or no point answered either way — treated as fine: never worse
---              than before
local function floorState(propertyId, rows, pl)
    local live = liveOf[propertyId]
    if not live or live == 0 or GetInteriorFromCollision == nil then return 'unknown' end
    local sawOutside = false
    local function ask(x, y, z)
        local ok, id = pcall(GetInteriorFromCollision, x, y, z)
        if not ok then return false end
        if id == live then return true end
        if (id or 0) == 0 and InteriorRooms and InteriorRooms.roomAt(live, x, y, z) then
            local okO, out = pcall(IsCollisionMarkedOutside, x, y, z)
            if okO and (out == true or (type(out) == 'number' and out ~= 0)) then sawOutside = true end
        end
        return false
    end
    local here = GetCurrentProperty and GetCurrentProperty()
    if here ~= nil and here.id == propertyId then
        local c = GetEntityCoords(PlayerPedId())
        if ask(c.x, c.y, c.z) then return 'linked' end
    end
    local p = (GetPropertyDefs and GetPropertyDefs() or {})[propertyId]
    local v = p and p.visit
    if v and v.x and ask(v.x, v.y, v.z + 0.9) then return 'linked' end
    if pl and rows and #rows > 0 then
        local low = {}
        for i, r in ipairs(rows) do low[i] = r end
        table.sort(low, function(a, b) return (a.lz or 0) < (b.lz or 0) end)
        for i = 1, math.min(FLOOR_SAMPLES, #low) do
            local w = toWorldRow(pl, low[i])
            if ask(w.x, w.y, w.z + 0.9) then return 'linked' end
        end
    end
    return sawOutside and 'outside' or 'unknown'
end

--- Forward-declared: a spawn that finishes on stale rows starts the next one.
local bringIn

--- Put a streamed-in property's furniture in the world, fetching its rows if the cache is stale.
---
--- Two things can change while this is working (the fetch and the spawning both wait):
---   the room's version (somebody saved)   the rows are fetched until they match the index, and a
---                                         set spawned from rows that went stale meanwhile is
---                                         replaced as soon as it is up
---   whether the room is wanted            the furnisher opening, or the player walking off, while
---                                         objects were still being created — the finished set is
---                                         thrown away rather than left in the world beside (or
---                                         instead of) the editor's working copies
function bringIn(propertyId)
    if paused[propertyId] or spawned[propertyId] or loading[propertyId] or not allowed[propertyId] then return end
    local want = index[propertyId]
    if not want or (want.n or 0) == 0 then return end   -- an unfurnished room: nothing to fetch
    -- Its interior first (above). Asked again by the once-a-second pass until it is there.
    if not interiorSettled(propertyId) then return end

    loading[propertyId] = true
    CreateThread(function()
        local c = nil
        for _ = 1, 3 do
            local w = index[propertyId]
            if not w or (w.n or 0) == 0 then c = nil break end
            c = cache[propertyId]
            if c and c.v == w.v then break end
            local res = Callback('whip_core:property:objects', propertyId)
            if type(res) ~= 'table' then c = nil break end
            c = { v = res.version, rows = res.rows or {} }
            cache[propertyId] = c
        end
        local current = c ~= nil and index[propertyId] ~= nil and c.v == index[propertyId].v

        -- The interior asked again: the fetch waited, and a loader may have unloaded it meanwhile.
        local pl = place(propertyId)
        if not c or not pl or spawned[propertyId] or not wanted(propertyId) or not interiorReady(propertyId) then
            loading[propertyId] = nil
            return
        end

        -- The floor first (above): while it is shown outside, up to the property's FLOOR_WAIT_MS, looked
        -- at twice a second. Left (the deadline kept) if the room stops being wanted, its interior
        -- stops being ready, or the room is saved meanwhile — the next try fetches it again.
        local state = floorState(propertyId, c.rows, pl)
        if state == 'outside' and not floorWaitUntil[propertyId] then
            floorWaitUntil[propertyId] = GetGameTimer() + FLOOR_WAIT_MS
        end
        while state == 'outside' and GetGameTimer() < (floorWaitUntil[propertyId] or 0) do
            Wait(FLOOR_LOOK_MS)
            local w = index[propertyId]
            if spawned[propertyId] or not wanted(propertyId) or not interiorReady(propertyId)
                or (current and (not w or w.v ~= c.v)) then
                loading[propertyId] = nil
                return
            end
            state = floorState(propertyId, c.rows, pl)
        end
        floorWaitUntil[propertyId] = nil
        local linked = state ~= 'outside'

        local list, stashes = {}, {}
        for _, r in ipairs(c.rows) do
            local w = toWorldRow(pl, r)
            local obj = spawnOne(w, propertyId)
            if obj then
                list[#list + 1] = obj
                making[obj] = true
                if w.stash then stashes[obj] = w.stash end
            end
        end
        for _, obj in ipairs(list) do making[obj] = nil end
        loading[propertyId] = nil

        if spawned[propertyId] or not wanted(propertyId) then
            for _, obj in ipairs(list) do
                madeIn[obj] = nil
                if DoesEntityExist(obj) then DeleteEntity(obj) end
            end
            return
        end
        spawned[propertyId] = list
        for obj, s in pairs(stashes) do stashObj[s], objStash[obj] = obj, s end
        -- Up: said for anything waiting on it (an interior's window cover: "How far along", above).
        WhipEmit('whip_core:property:furnished',
            { propertyId = propertyId, interiorId = liveOf[propertyId], count = #list })
        noteState(propertyId)
        -- Made on a floor not its interior's (the floor first, above): its lamps give no light. Said
        -- once a session, in words a server owner can act on, and recorded for an admin; made again by
        -- the pass if the floor is its interior's later.
        if not linked then
            madeUnlinked[propertyId] = true
            if not saidUnlinked[propertyId] then
                saidUnlinked[propertyId] = true
                print(('[whip_core:props] property %s: its floor is not attached to its interior (the game marks it outside), so lamps made on it give no light. Leaving and coming back can mend it; a full FiveM restart does (after a server restart, restart FiveM rather than reconnecting)')
                    :format(tostring(propertyId)))
            end
        end
        -- Made through the grace (standing in it, the interior there and never ready): made again if
        -- the interior says ready after all (the once-a-second pass).
        madeUnready[propertyId] = not interiorReady(propertyId, true) or nil

        -- Saved again while these were being made: swap them for the new rows. Only when the rows
        -- DID match the index when fetched, or this would fetch, spawn and delete for ever.
        local w = index[propertyId]
        if current and w and w.v ~= c.v then
            despawn(propertyId)
            bringIn(propertyId)
        end
    end)
end

-- ============================================
-- Which rooms are furnished
-- ============================================

-- Only close up (made from the street, furniture finds an interior a loader has not finished): a
-- property is furnished only while the player is within Config.PropertyFurnitureDistance of its space
-- (inside counts), and kept until FURNITURE_KEEP further, so standing on the line does not make and
-- unmake it.
local FURNITURE_KEEP = 2.0

--- The furnished, streamed-in rooms to show: those the player is close to (above), the one they are
--- standing in first, then the nearest by anchor, up to Config.PropertyFurnitureRooms.
---@return table  [propertyId] = true
local function chooseRooms()
    local cap = math.max(1, math.floor(tonumber(Config.PropertyFurnitureRooms) or 4))
    local reach = math.max(0.0, tonumber(Config.PropertyFurnitureDistance) or 20.0)
    local defs = GetPropertyDefs and GetPropertyDefs() or {}
    local pos = GetEntityCoords(PlayerPedId())

    local list = {}
    for id, w in pairs(index) do
        local p = defs[id]
        if (w.n or 0) > 0 and p and p.x and IsPropertyNear and IsPropertyNear(id)
            and IsNearPropertySpace and IsNearPropertySpace(id, reach + (allowed[id] and FURNITURE_KEEP or 0.0)) then
            local dx, dy, dz = pos.x - p.x, pos.y - p.y, pos.z - p.z
            list[#list + 1] = { id = id, d = dx * dx + dy * dy + dz * dz }
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)

    local pick, count = {}, 0
    local inside = GetCurrentProperty and GetCurrentProperty()
    if inside and inside.id and index[inside.id] and (index[inside.id].n or 0) > 0 and IsPropertyNear and IsPropertyNear(inside.id) then
        pick[inside.id], count = true, 1
    end
    for _, e in ipairs(list) do
        if count >= cap then break end
        if not pick[e.id] then pick[e.id], count = true, count + 1 end
    end
    return pick
end

--- Choose again and act on it: rooms that dropped out lose their furniture, rooms that came in get it.
local function refreshRooms()
    local pick = chooseRooms()
    -- The new choice first, so a room let go is said as 'idle' (noteState), not as waiting to be made.
    local old = allowed
    allowed = pick
    for id in pairs(old) do
        if not pick[id] then despawn(id) end
    end
    for id in pairs(pick) do bringIn(id) end
    for id in pairs(pick) do noteState(id) end
end

-- Walking through a tower changes which flats are nearest. Once a second, and only while some
-- property is streamed in: the pass reads the index (furnished properties only), not the world.
CreateThread(function()
    while true do
        -- An interior unloaded under its furniture (a loader took it away): the furniture goes too, and
        -- is made again once the interior is back (see "The interior first"). One taken away and brought
        -- back between two looks shows in the pieces (interiorReloaded), and so does a set made before
        -- its interior said ready: both are made again, at most every REBUILD_GAP_MS each.
        for id in pairs(spawned) do
            if not paused[id] then
                if not interiorReady(id) then
                    -- One miss is not an unload (the player on the threshold, a dead copy on the
                    -- spot): two passes in a row; a placement with no archetype hash, the first.
                    local defs = GetPropertyDefs and GetPropertyDefs() or {}
                    local pl = defs[id] and defs[id].place
                    missed[id] = (missed[id] or 0) + 1
                    if missed[id] >= 2 or not (pl and pl.hash and pl.hash ~= 0) then
                        despawn(id)
                        readySince[id] = nil
                    end
                else
                    missed[id] = nil
                    local why = interiorReloaded(id) and 'its interior was reloaded under it'
                        or (madeUnready[id] and interiorReady(id, true) and 'it was made before its interior was ready')
                        or (madeUnlinked[id] and floorState(id, cache[id] and cache[id].rows, place(id)) == 'linked'
                            and 'its floor is now attached to its interior (it was made while it was not)')
                    local now = GetGameTimer()
                    if why and now - (rebuiltAt[id] or -REBUILD_GAP_MS) >= REBUILD_GAP_MS then
                        rebuiltAt[id] = now
                        print(('[whip_core:props] property %s: %s, so its furniture is made again'):format(tostring(id), why))
                        despawn(id)
                        readySince[id] = nil
                    end
                end
            end
        end
        if next(index) ~= nil then
            local anyNear = false
            for id in pairs(index) do
                if IsPropertyNear and IsPropertyNear(id) then anyNear = true break end
            end
            if anyNear or next(allowed) ~= nil then refreshRooms() end
        end
        -- Keep the furniture in its rooms (see `filing`): everything when the player walks into or out
        -- of an interior, the pieces of the property they are standing in once a second, and nothing
        -- at all while they are outside every property.
        pass = pass + 1
        local mine = GetInteriorFromEntity(PlayerPedId())
        local moved = mine ~= playerInterior
        playerInterior = mine
        local here = GetCurrentProperty and GetCurrentProperty()
        local hereId = here and here.id
        if moved or hereId then
            for obj, f in pairs(filing) do
                if not DoesEntityExist(obj) then
                    filing[obj] = nil
                elseif moved or (f.property == hereId and pass >= (f.next or 0)) then
                    if f.last == 'filed' and f.key and InteriorRooms.sameKey(GetRoomKeyFromEntity(obj), f.key) then
                        f.next = pass + 1
                    else
                        fileInRoom(obj)
                    end
                end
            end
        end
        Wait(1000)
    end
end)

-- ============================================
-- The hooks client/properties.lua calls
-- ============================================

function PropertyStreamedIn(_) refreshRooms() end

-- Walking in or out (client/properties.lua): chosen again at once, not at the next pass. (Coming
-- within Config.PropertyFurnitureDistance of a property is noticed by the once-a-second pass.)
AddEventHandler('whip_core:property:entered', function() refreshRooms() end)
AddEventHandler('whip_core:property:exited', function() refreshRooms() end)

function PropertyStreamedOut(propertyId)
    allowed[propertyId] = nil   -- before the despawn, so it is said as 'idle'
    despawn(propertyId)
    refreshRooms()   -- its place may go to the next nearest
end

-- An interior redrawn under its furniture (a home's theme changed: server/property_themes.lua). The
-- resource that drew it says so, on this client only, right after its RefreshInterior:
--     TriggerEvent('whip_core:interiorRefreshed', interiorId)
-- Furniture left on a refreshed interior keeps lamps that glow and light nothing ("Was its interior
-- reloaded under it?" above), so the property on it is made again at once (past REBUILD_GAP_MS: this is
-- somebody's choice, not a loader's churn), once its interior says ready again.
AddEventHandler('whip_core:interiorRefreshed', function(interiorId)
    interiorId = tonumber(interiorId)
    if not interiorId or interiorId == 0 then return end
    for id, list in pairs(spawned) do
        local on = liveOf[id] == interiorId
        if not on then
            for _, obj in ipairs(list) do
                local f = filing[obj]
                if (f and f.interior == interiorId) or madeIn[obj] == interiorId then on = true break end
            end
        end
        if on and not paused[id] then
            rebuiltAt[id] = GetGameTimer()
            print(('[whip_core:props] property %s: its interior was redrawn (its theme), so its furniture is made again'):format(tostring(id)))
            despawn(id)
            readySince[id] = nil
        end
    end
end)

-- ============================================
-- Server sync
-- ============================================

RegisterNetEvent('whip_core:client:propertyObjectsIndex', function(list)
    allowed = {}   -- before the despawns, so they are said as 'idle' until chosen again below
    for id in pairs(spawned) do despawn(id) end
    index, cache = {}, {}
    for _, e in ipairs(type(list) == 'table' and list or {}) do
        if e.id then index[e.id] = { v = e.v, n = e.n } end
    end
    -- Anything already streamed in gets its furniture now rather than at its next stream-in.
    refreshRooms()
    for id in pairs(lastState) do noteState(id) end   -- one no longer chosen, or no longer furnished
end)

RegisterNetEvent('whip_core:client:propertyObjectsChanged', function(propertyId, version, count)
    propertyId = tonumber(propertyId)
    if not propertyId then return end
    index[propertyId] = { v = version, n = count }
    cache[propertyId] = nil
    -- A room someone is standing in is rebuilt now: the save that changed it may be theirs.
    if spawned[propertyId] and not paused[propertyId] then
        despawn(propertyId)
        bringIn(propertyId)
    end
    noteState(propertyId)   -- emptied: 'none'
end)

-- ============================================
-- For the furnisher
-- ============================================

--- Take a room's furniture out of the world and keep it out, so the furnisher's editable copies
--- are the only ones on screen.
function PropertyPauseFurniture(propertyId)
    paused[propertyId] = true
    despawn(propertyId)
end

--- Give the room back to the stream.
function PropertyResumeFurniture(propertyId)
    paused[propertyId] = nil
    refreshRooms()
    noteState(propertyId)   -- not chosen again (walked off while furnishing): 'idle'
end

--- A room's furniture in WORLD space, fetched now if it is not cached. Blocks; call from a thread.
--- The rows: { id, model, x, y, z, rx, ry, rz }.
---
--- `fresh` (the furnisher): ask the server whatever the cache holds, and answer `rows, version` — or
--- NIL when it did not answer. An editor must never open on a room it failed to read: it would look
--- empty, and its first Save would delete the real furniture.
---@param fresh boolean|nil
---@return table[]|nil rows
---@return number|nil version
---@return string|nil why  with nil rows: the server's reason when it refused (nothing when it did not answer)
function GetPropertyFurnitureRows(propertyId, fresh)
    local want = index[propertyId]
    local c = cache[propertyId]
    if fresh or (want and (want.n or 0) > 0 and (not c or c.v ~= want.v)) then
        local res, why = Callback('whip_core:property:objects', propertyId)
        if type(res) == 'table' and tonumber(res.version) then
            c = { v = res.version, rows = res.rows or {} }
            cache[propertyId] = c
        elseif fresh then
            return nil, nil, res == false and type(why) == 'string' and why or nil
        end
    end
    local pl = place(propertyId)
    local out = {}
    if c and pl then
        for i, r in ipairs(c.rows) do out[i] = toWorldRow(pl, r) end
    end
    return out, c and c.v
end

-- ============================================
-- GetInteriorFurnishState (an interior resource asks: "How far along", above)
-- ============================================

--- Which property an interior copy is: the one whose placement it stands on (PLACE_MATCH_M), among the
--- furnished ones. Kept per interior and looked at again at most once a second, so asking every
--- frame costs a table lookup (an interior number can be a new copy's after a reload).
local ownerOfInterior = {}   -- [interiorId] = { id = propertyId | false, at }
local OWNER_LOOK_MS = 1000

local function propertyOfInterior(interiorId)
    local now = GetGameTimer()
    local c = ownerOfInterior[interiorId]
    if c and now - c.at < OWNER_LOOK_MS then return c.id or nil end
    local found = nil
    for id, live in pairs(liveOf) do   -- the copy a look already found live
        if live == interiorId and index[id] then found = id break end
    end
    if not found then
        local ok, loc = pcall(GetInteriorLocationAndNamehash, interiorId)
        if ok and loc then
            local best
            for id in pairs(index) do
                local pl = place(id)
                if pl and pl.x then
                    local d = math.sqrt((loc.x - pl.x) ^ 2 + (loc.y - pl.y) ^ 2 + (loc.z - pl.z) ^ 2)
                    if d <= PLACE_MATCH_M and (not best or d < best) then found, best = id, d end
                end
            end
        end
    end
    ownerOfInterior[interiorId] = { id = found or false, at = now }
    return found
end

--- How far along the furniture of the property this interior is: 'pending' | 'done' | 'none' | 'idle'
--- ("How far along", above). An interior that is no property's, or nothing, answers 'none'.
exports('GetInteriorFurnishState', function(interiorId)
    interiorId = tonumber(interiorId)
    if not interiorId or interiorId == 0 then return 'none' end
    local propertyId = propertyOfInterior(interiorId)
    if not propertyId then return 'none' end
    return furnishState(propertyId, interiorId)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for id in pairs(spawned) do despawn(id) end
    -- And a set still being made.
    for obj in pairs(making) do
        if DoesEntityExist(obj) then DeleteEntity(obj) end
    end
    making = {}
    filing = {}
    madeIn = {}
    stashObj, objStash = {}, {}
end)
