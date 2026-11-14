-- ============================================
-- INTERIOR — what the game says about the interior you are standing in
-- ============================================
--
-- The Configurator's one reader of the interior natives, built on what /propprobe proved on this
-- server (dev/properties-probe.md):
--
--   the handle        GetInteriorFromEntity(ped); the room and portal natives answer on it
--   the placement     origin = GetOffsetFromInteriorInWorldCoords(id, 0,0,0), yaw from the +X basis
--                     vector; every interior probed was yaw-only (up axis exactly 0,0,1)
--   the rooms         interior-local extents, room 0 is limbo (the outside) and is skipped
--   portal doors      local position, and a heading that is MINUS the stored quaternion's yaw
--   other doors       found by shape in the object pool: Mega's flat doors are not portal doors
--
-- Everything handed back is in the interior's OWN space (and a world copy where useful), because
-- that is what a unit is described in. Nothing here writes anything.

Interior = {}

local function signed(h)
    return PropertyMath.signedHash(h) or 0
end

local function quatYaw(x, y, z, w)
    return math.deg(math.atan(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z)))
end

--- Wait for an interior to be loaded, pinning it if it is not. At most `ms`.
---@return boolean ready
function Interior.waitReady(id, ms)
    if IsInteriorReady(id) then return true end
    PinInteriorInMemory(id)
    local deadline = GetGameTimer() + (ms or 3000)
    while not IsInteriorReady(id) and GetGameTimer() < deadline do Wait(50) end
    return IsInteriorReady(id)
end

--- Where one interior stands: its archetype hash and its placement. Cheap — no rooms, no portals —
--- so Stamp mode can ask it several times a second. `id` is GetInteriorFromEntity's handle (the
--- probe's §9: the at-coords natives answer with a different number).
---@return table place # { hash, x, y, z, yaw }
---@return boolean yawOnly
function Interior.placementOf(id)
    local _, hash = GetInteriorLocationAndNamehash(id)
    local o  = GetOffsetFromInteriorInWorldCoords(id, 0.0, 0.0, 0.0)
    local px = GetOffsetFromInteriorInWorldCoords(id, 1.0, 0.0, 0.0)
    local pz = GetOffsetFromInteriorInWorldCoords(id, 0.0, 0.0, 1.0)
    local ex, ez = px - o, pz - o
    local yaw = math.deg(math.atan(ex.y, ex.x)) % 360.0
    return { hash = signed(hash), x = o.x, y = o.y, z = o.z, yaw = yaw }, ez.z >= 0.999
end

--- The interior the player is in, read whole. Blocks while it loads; call from a thread.
---@return table|nil info, string|nil why
function Interior.read()
    local ped = PlayerPedId()
    local id = GetInteriorFromEntity(ped)
    if not id or id == 0 then return nil, 'You are not inside an interior' end
    if not Interior.waitReady(id, 3000) then return nil, 'The interior has not finished loading — try again' end

    local place, yawOnly = Interior.placementOf(id)
    local info = {
        id = id,
        hash = place.hash,
        place = place,
        yawOnly = yawOnly,
        rooms = {},
        portals = {},
    }

    local roomKey = GetRoomKeyFromEntity(ped)
    local roomCount = GetInteriorRoomCount(id) or 0
    info.roomCount = roomCount
    for i = 1, roomCount - 1 do   -- 0 is limbo
        local name = GetInteriorRoomName(id, i)
        local x1, y1, z1, x2, y2, z2 = GetInteriorRoomExtents(id, i)
        if name and x1 then
            info.rooms[#info.rooms + 1] = {
                name = name,
                min = { x = math.min(x1, x2), y = math.min(y1, y2), z = math.min(z1, z2) },
                max = { x = math.max(x1, x2), y = math.max(y1, y2), z = math.max(z1, z2) },
            }
            if roomKey and GetHashKey(name) == roomKey then info.currentRoom = name end
        end
    end

    local portalCount = GetInteriorPortalCount(id) or 0
    info.portalCount = portalCount
    for p = 0, portalCount - 1 do
        local n = GetInteriorPortalEntityCount(id, p) or 0
        for e = 0, n - 1 do
            local arch = GetInteriorPortalEntityArchetype(id, p, e)
            local lx, ly, lz = GetInteriorPortalEntityPosition(id, p, e)
            local qx, qy, qz, qw = GetInteriorPortalEntityRotation(id, p, e)
            if arch and arch ~= 0 and lx then
                info.portals[#info.portals + 1] = {
                    model = signed(arch),
                    pos = { x = lx, y = ly, z = lz },
                    -- Stored inverted: the entity's local heading is minus the quaternion's yaw.
                    heading = qx and (-quatYaw(qx, qy, qz, qw)) % 360.0 or 0.0,
                    portal = p,
                }
            end
        end
    end
    return info
end

-- ============================================
-- Doors
-- ============================================

--- Is this model shaped like a door? From the probe: every door in seven interiors was
--- 0.04-0.16 m thick, 2.15-2.43 m tall and 0.92-1.21 m wide. Garage doors are wide and tall, and
--- can be much thicker than a door (over 0.45 m): a roll-up's drum, an up-and-over's frame.
---@return string|nil kind  'door' | 'garage'
function Interior.doorShape(model)
    local mn, mx = GetModelDimensions(model)
    if not mn or not mx then return nil end
    local w, t, h = mx.x - mn.x, mx.y - mn.y, mx.z - mn.z
    if h < 1.6 then return nil end
    if w >= 0.55 and w <= 1.7 and h <= 3.0 and t <= 0.3 then return 'door' end
    if w > 1.7 and w <= 9.0 and h <= 6.0 and t <= 1.2 then return 'garage' end
    return nil
end

--- Every door a unit could have, in the interior's own space: the portal doors, then any
--- door-shaped object near the space. Close duplicates (the same door found both ways) are one.
---@param place table          the placement everything is relative to
---@param portals table|nil    Interior.read's portal list, when there is an interior
---@param bounds table|nil     world { minX, minY, minZ, maxX, maxY, maxZ } to search around
---@param interiorId number|nil  objects in this interior count whatever the bounds say
---@return table[] candidates  { model, pos (local), heading (local), world, kind, source }
function Interior.doorCandidates(place, portals, bounds, interiorId)
    local out = {}
    local function add(model, world, heading, kind, source)
        for _, c in ipairs(out) do
            local dx, dy, dz = c.world.x - world.x, c.world.y - world.y, c.world.z - world.z
            if dx * dx + dy * dy + dz * dz < 0.3 * 0.3 then return end
        end
        local lx, ly, lz = PropertyMath.toLocal(place, world.x, world.y, world.z)
        out[#out + 1] = {
            model = model, world = world, kind = kind, source = source,
            pos = { x = lx, y = ly, z = lz },
            heading = PropertyMath.headingToLocal(place, heading),
        }
    end

    for _, p in ipairs(portals or {}) do
        local wx, wy, wz = PropertyMath.toWorld(place, p.pos.x, p.pos.y, p.pos.z)
        add(p.model, { x = wx, y = wy, z = wz }, PropertyMath.headingToWorld(place, p.heading),
            Interior.doorShape(p.model) or 'door', 'doorway')
    end

    -- A garage door is looked for further out than a door: a garage can be its own little building
    -- (Mirror Park's are separate interiors), its door metres from the home's own walls.
    local margin, garageMargin = 3.0, 12.0
    local function within(c, m)
        return bounds ~= nil and c.x >= bounds.minX - m and c.x <= bounds.maxX + m
            and c.y >= bounds.minY - m and c.y <= bounds.maxY + m
            and c.z >= bounds.minZ - m and c.z <= bounds.maxZ + m
    end
    for _, obj in ipairs(GetGamePool('CObject')) do
        if DoesEntityExist(obj) then
            local c = GetEntityCoords(obj)
            local inside = interiorId and interiorId ~= 0 and GetInteriorFromEntity(obj) == interiorId
            if inside or within(c, garageMargin) then
                local model = GetEntityModel(obj)
                local kind = Interior.doorShape(model)
                if kind and (inside or kind == 'garage' or within(c, margin)) then
                    add(signed(model), { x = c.x, y = c.y, z = c.z }, GetEntityHeading(obj), kind, 'scan')
                end
            end
        end
    end
    return out
end
