-- ============================================
-- INTERIOR ROOMS — which room of an MLO a point is in, and putting things there
-- ============================================
--
-- GTA draws an interior room by room: the room the camera is in, and whatever can be seen from it
-- through doorways (the MLO's portals). Every entity is filed under a room too, and is drawn only
-- when its room is. The game files them itself by following them through doorways, which works for
-- things that walk. It does not work for:
--
--   a free camera   flies through walls and floors, crosses no doorway — the game keeps the room
--                   it left and culls the one it is in (client/freecam.lua)
--   furniture       made with CreateObject and never told: filed by wherever its origin landed,
--                   often on the floor line or in a wall, or before the interior had loaded — so
--                   pieces vanish at some angles, and standing on a bed filed "outside" puts the
--                   PLAYER outside (the game takes your room from what you stand on)
--
-- This answers "which room is this point in" from the interior's own room boxes — the CFX room
-- natives, in the interior's own space, through the engine's own placement of it (what
-- tools/interior.lua reads, proven by /propprobe) — and files an entity there with
-- ForceRoomForEntity, the native Rockstar's scripts use for props they make inside interiors.
--
-- The smallest box wins: an MLO's room boxes overlap round doorways and stairwells, and a closet's
-- sits inside the bedroom's; the tighter box is the room the point is really in.
--
-- Two numbers for one interior: /propprobe found GetInteriorAtCoords names an interior with a
-- different number from GetInteriorFromEntity, and the room natives answered on the entity's. Both
-- are asked here; which one ForceRoomForEntity wants has not been seen on this server, so the game is
-- asked back (GetRoomKeyFromEntity) and the other number is tried — and kept — when the first is not
-- taken.

InteriorRooms = {}

local cache = {}   -- [interior number] = { place, limbo, list = { { key, name, mn, mx, vol } } } or false

--- Hash keys as unsigned, so a signed and an unsigned copy of one key compare equal.
function InteriorRooms.sameKey(a, b)
    local ia, ib = math.tointeger(a), math.tointeger(b)
    if not ia or not ib then return a ~= nil and a == b end
    return (ia & 0xFFFFFFFF) == (ib & 0xFFFFFFFF)
end
local sameKey = InteriorRooms.sameKey

--- An interior's rooms, read once and kept. Nil while it is still loading (asked again next time),
--- or when the room natives do not answer for this number (remembered as false).
function InteriorRooms.of(id)
    if not id or id == 0 then return nil end
    local known = cache[id]
    if known ~= nil then return known or nil end
    if not IsInteriorReady(id) then return nil end
    local ok, count = pcall(GetInteriorRoomCount, id)
    if not ok or type(count) ~= 'number' or count < 2 then
        cache[id] = false
        return nil
    end
    local o  = GetOffsetFromInteriorInWorldCoords(id, 0.0, 0.0, 0.0)
    local px = GetOffsetFromInteriorInWorldCoords(id, 1.0, 0.0, 0.0)
    local place = { x = o.x, y = o.y, z = o.z, yaw = math.deg(math.atan(px.y - o.y, px.x - o.x)) }
    local list = {}
    for i = 1, count - 1 do   -- room 0 is limbo: the outside
        local name = GetInteriorRoomName(id, i)
        local x1, y1, z1, x2, y2, z2 = GetInteriorRoomExtents(id, i)
        if name and name ~= '' and x1 then
            local mn = { math.min(x1, x2), math.min(y1, y2), math.min(z1, z2) }
            local mx = { math.max(x1, x2), math.max(y1, y2), math.max(z1, z2) }
            list[#list + 1] = { key = GetHashKey(name), name = name, mn = mn, mx = mx,
                                vol = (mx[1] - mn[1]) * (mx[2] - mn[2]) * (mx[3] - mn[3]) }
        end
    end
    local limbo = GetInteriorRoomName(id, 0)
    cache[id] = { place = place, list = list, limbo = GetHashKey((limbo and limbo ~= '') and limbo or 'limbo') }
    return cache[id]
end

--- A room's box, for drawing it: { place, mn, mx } in the interior's own space, or nil.
function InteriorRooms.boxOf(id, key)
    local c = InteriorRooms.of(id)
    if not c or key == nil then return nil end
    for _, room in ipairs(c.list) do
        if sameKey(room.key, key) then return { place = c.place, mn = room.mn, mx = room.mx } end
    end
    return nil
end

--- The room of interior `id` holding a point, or nil.
---
--- `prefer` (optional): a room key that wins when its box holds the point. Room boxes are rough and
--- can overlap well beyond doorways (the Diamond Casino's gaming floors); the game's own room for the
--- player follows them through doorways, so it settles which of the boxes a point near them is in.
function InteriorRooms.roomAt(id, x, y, z, prefer)
    local r = InteriorRooms.of(id)
    if not r then return nil end
    local lx, ly, lz = PropertyMath.toLocal(r.place, x, y, z)
    local best = nil
    for _, room in ipairs(r.list) do
        if lx >= room.mn[1] and lx <= room.mx[1] and ly >= room.mn[2] and ly <= room.mx[2]
            and lz >= room.mn[3] and lz <= room.mx[3] then
            if prefer and sameKey(room.key, prefer) then return room end
            if not best or room.vol < best.vol then best = room end
        end
    end
    return best
end

--- Which room a point is in, asking every number the interior might go by:
---
---   hint   an entity's own (GetInteriorFromEntity on the thing being filed): the same kind of number
---          as the player's, and it works while the player is still OUTSIDE — furniture streams back
---          in 60 m out, long before anyone walks through the door
---   mine   the player's ped's: proven to answer the room natives (/propprobe)
---   at     GetInteriorAtCoords at the point: a different kind of number, unproven with them
---@return table|nil room { id, alt, key, name }, boolean inInterior  whether the game puts an interior here at all
--- The room of interior `id` holding the point, as find answers it, or nil. (Its own function, not a
--- closure in find: a free camera asks find nearly every frame, and it builds nothing it can avoid.)
local function roomOf(id, x, y, z, at, mine, hint, prefer)
    local room = InteriorRooms.roomAt(id, x, y, z, prefer)
    if not room then return nil end
    -- The other way of naming it, for a native that will not take this one.
    local alt = (id == at) and ((mine ~= 0 and mine) or hint) or at
    return { id = id, alt = alt, key = room.key, name = room.name }
end

--- `prefer` (optional): a room key that wins over a smaller overlapping box (InteriorRooms.roomAt).
function InteriorRooms.find(x, y, z, hint, prefer)
    local at = GetInteriorAtCoords(x, y, z)
    local mine = GetInteriorFromEntity(PlayerPedId())
    local h = hint or 0
    -- hint, then mine, then at: each number once
    local found = h ~= 0 and roomOf(h, x, y, z, at, mine, hint, prefer) or nil
    if not found and mine ~= 0 and mine ~= h then found = roomOf(mine, x, y, z, at, mine, hint, prefer) end
    if not found and at ~= 0 and at ~= h and at ~= mine then found = roomOf(at, x, y, z, at, mine, hint, prefer) end
    return found, at ~= 0
end

--- The player's own room, as the game tracks it, for a camera within `near` metres of them (first person, a
--- seat or close camera); nil further out or outside an interior. A free camera away from the player keeps
--- "smallest wins": there the player's big room box is the wrong answer.
function InteriorRooms.playerRoomNear(p, near)
    if not GetRoomKeyFromEntity then return nil end
    local ped = PlayerPedId()
    if GetInteriorFromEntity(ped) == 0 then return nil end
    local q = GetEntityCoords(ped)
    local dx, dy, dz = p.x - q.x, p.y - q.y, p.z - q.z
    if dx * dx + dy * dy + dz * dz > near * near then return nil end
    local key = GetRoomKeyFromEntity(ped)
    if not key or math.tointeger(key) == 0 then return nil end
    return key
end

-- ---- filing entities ----

local HAS_ENTITY_ROOM = ForceRoomForEntity ~= nil and GetRoomKeyFromEntity ~= nil
local entityAlt = false     -- learned: the game files an entity only when the interior is named the other way
local toldNoTake = false    -- the console has been told nothing works (once)

--- File an entity in the room holding its middle. The middle, not its origin: a prop's origin is
--- wherever its artist left it — on the floor line, in a wall — and the room box either side of
--- that line is a coin toss.
---
--- `target` 'limbo' files it in that interior's limbo (room 0, its own "outside") instead.
---@param entity number
---@param target string|nil  nil: the room holding its middle; 'limbo': the interior's limbo
---@return string|nil key   the room it was filed in, or nil (its interior cannot be read from here
---                         yet, or the point is in no room: try again later)
---@return boolean confirmed  the game says it is in that room now. False: told, not confirmed — the
---                         game would not take it by either number; checking it again only repeats that
function InteriorRooms.put(entity, target)
    if not HAS_ENTITY_ROOM or not entity or not DoesEntityExist(entity) then return nil, false end
    local mn, mx = GetModelDimensions(GetEntityModel(entity))
    local c
    if mn and mx then
        c = GetOffsetFromEntityInWorldCoords(entity, (mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
    else
        c = GetEntityCoords(entity)
    end
    local room = InteriorRooms.find(c.x, c.y, c.z, GetInteriorFromEntity(entity))
    if not room then return nil, false end
    local limbo = target == 'limbo'
    if limbo then
        local rooms = InteriorRooms.of(room.id)
        if not rooms or not rooms.limbo then return nil, false end
        room = { id = room.id, alt = room.alt, key = rooms.limbo, name = 'limbo' }
    end

    --- Is it in that room now? An entity in an interior's limbo may answer 0 for its room rather than
    --- limbo's name, so for limbo either counts while the game has it in some interior.
    local function there()
        local k = GetRoomKeyFromEntity(entity)
        if sameKey(k, room.key) then return true end
        return limbo and math.tointeger(k) == 0 and GetInteriorFromEntity(entity) ~= 0
    end

    -- Already there (the game filed it right, or it was filed before): nothing to do.
    if there() then return room.key, true end

    local first, other = room.id, room.alt
    if entityAlt and other and other ~= 0 then first, other = other, first end
    ForceRoomForEntity(entity, first, room.key)
    if there() then return room.key, true end
    if other and other ~= 0 and other ~= first then
        ForceRoomForEntity(entity, other, room.key)
        if there() then
            entityAlt = not entityAlt
            print(('[whip_core:rooms] the game files objects in a room only by interior %s — using that from now on'):format(tostring(other)))
            return room.key, true
        end
    end
    if not toldNoTake then
        toldNoTake = true
        print(('[whip_core:rooms] could not file an object in room %s (interior %s / %s): the game kept it in %s')
            :format(room.name, tostring(room.id), tostring(room.alt), tostring(GetRoomKeyFromEntity(entity))))
    end
    return room.key, false
end

-- ---- how furniture is filed: lamps in limbo, the rest in their rooms ----
--
-- A lamp forced into a room lights nothing (it glows, but its light reaches nothing, and the room
-- stays dark to new lamps until a restart): a light belongs to its prop, so lamps go in limbo. The
-- rest of the furniture needs its room (or a bed stood on culls the house). By default each gets what
-- it needs:
--   hybrid   lamps (the catalog's lighting category) in the interior's limbo, the rest in its room
-- The other modes (room, limbo, none) were for testing; the switch for them (/furnfiling) is gone, and a
-- PC that kept one (the whip:furnfiling:v2 KVP) is no longer read.

local furnMode = 'hybrid'

---@return string 'hybrid' | 'room' | 'limbo' | 'none'
function InteriorRooms.furnitureMode() return furnMode end

--- Is a piece of furniture filed in a room (rather than limbo or not at all) under the mode?
---@param isLight boolean
function InteriorRooms.fileByRoom(isLight)
    return furnMode == 'room' or (furnMode == 'hybrid' and not isLight)
end

--- File a piece of furniture the way the mode says. The same answers as put; nil, false for none.
---@param entity number
---@param isLight boolean  a lamp (the catalog's lighting category)
function InteriorRooms.fileFurniture(entity, isLight)
    if furnMode == 'none' then return nil, false end
    return InteriorRooms.put(entity, (not InteriorRooms.fileByRoom(isLight)) and 'limbo' or nil)
end

--- The room key an entity's middle is in right now (no filing), for a mover deciding whether it has
--- crossed into another room.
function InteriorRooms.keyAt(entity)
    if not entity or not DoesEntityExist(entity) then return nil end
    local mn, mx = GetModelDimensions(GetEntityModel(entity))
    local c = (mn and mx) and GetOffsetFromEntityInWorldCoords(entity, (mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        or GetEntityCoords(entity)
    local room = InteriorRooms.find(c.x, c.y, c.z, GetInteriorFromEntity(entity))
    return room and room.key or nil
end
