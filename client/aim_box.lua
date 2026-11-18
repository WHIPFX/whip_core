-- ============================================
-- AIMED AT A BOX — where the player looks, on a car's or a prop's bounding box
-- ============================================
--
-- An action at `at = { aimBox = 'vehicle' }` (client/actions.lua) is a prompt that
-- appears on whatever car (or prop, or person) the player is looking at, exactly where the look
-- meets its model box: flat on that side like a sign, wrapped round a corner when it runs past one
-- (the wrap a stash's prompt has: interact_world.lua, foldQuad), or just over the box's top. onSelect's
-- ctx.coords is that point and ctx.entity the thing: a rope (whip_rope) ties there.
--
-- 'world' is the map itself (its ground, walls, rock: what is not a car, a prop or a person): the prompt is where
-- the look meets it, flat on a wall or just over the ground, with no entity (ctx.entity nil, ctx.world true, and
-- ctx.normal the way the surface there faces). A rope ties to the map there.
--
-- WHICH THING: one ray from the camera with the world in it too, so a wall in front hides the car
-- behind it. The entity it hits, when of a wanted kind, is the one; and the last one stays while the
-- look still meets its box — the ray can pass a box's corner without touching the body inside it —
-- so the prompt slides off an edge rather than flickering on and off.
--
-- WHERE ON IT: the same ray against the box in the entity's own space (its axes and
-- GetModelDimensions): the side it comes in through, and the point. A side's sign stands upright,
-- turned to face straight out of it (a car on a slope keeps its sign upright).

AimBox = {}

local SIGN_OFF = 0.02   -- metres off a side, so the sign never sinks into it
local TOP_LIFT = 0.04   -- metres over a top (or under a bottom) it is aimed at
-- How far in front of the body the look may meet the box and the box still be used (see onBody, below).
-- A car's box hugs it: well under this anywhere on it. A helicopter's or a plane's does not.
local BOX_SLACK = 1.5
local KIND_TYPE = { ped = 1, vehicle = 2, object = 3 }
local KIND_FLAG = { ped = 8, vehicle = 2, object = 16 }

local boxes = {}   -- [model] = { minX, minY, minZ, maxX, maxY, maxZ }, read once

local function boxOf(model)
    local b = boxes[model]
    if b then return b end
    local mn, mx = GetModelDimensions(model)
    b = { mn.x, mn.y, mn.z, mx.x, mx.y, mx.z }
    boxes[model] = b
    return b
end

--- The kinds an `aimBox` names ('vehicle', 'object', 'ped', 'world', or a list of them), as a set, and the
--- shape-test flags that find them (the world always in, for what stands in front). nil when none.
---@return table|nil kinds
---@return number|nil flags
function AimBox.kinds(v)
    local list = type(v) == 'table' and v or { v }
    local set, flags = {}, 1
    for _, k in ipairs(list) do
        if k == 'world' then
            set.world = true   -- (the map is in every ray already)
        elseif KIND_TYPE[k] and not set[k] then
            set[k] = true
            flags = flags + KIND_FLAG[k]
        end
    end
    if next(set) == nil then return nil end
    return set, flags
end

--- Did the ray hit the map itself? (no entity, or one that is part of the map: a building's)
local function isMap(ent)
    return not ent or ent == 0 or not DoesEntityExist(ent) or GetEntityType(ent) == 0
end

--- One axis of the box against the ray (the slab test): the entry and exit so far, narrowed.
local function slab(o, d, mn, mx, a, tmin, tmax, axis, sign)
    if math.abs(d) < 1e-7 then
        if o < mn or o > mx then return nil end
        return tmin, tmax, axis, sign
    end
    local t1, t2, s = (mn - o) / d, (mx - o) / d, -1   -- in through the min side: its normal is -axis
    if t1 > t2 then t1, t2, s = t2, t1, 1 end
    if t1 > tmin then tmin, axis, sign = t1, a, s end
    if t2 < tmax then tmax = t2 end
    if tmin > tmax then return nil end
    return tmin, tmax, axis, sign
end

--- The entity's own axes in the world (its right, forward and up, each a metre long) and its origin:
--- the space GetModelDimensions measures in. From GetOffsetFromEntityInWorldCoords rather than
--- GetEntityMatrix, whose four answers are named in one order and documented in another.
local function axesOf(ent)
    local p = GetEntityCoords(ent)
    local r = GetOffsetFromEntityInWorldCoords(ent, 1.0, 0.0, 0.0) - p
    local f = GetOffsetFromEntityInWorldCoords(ent, 0.0, 1.0, 0.0) - p
    local u = GetOffsetFromEntityInWorldCoords(ent, 0.0, 0.0, 1.0) - p
    return r, f, u, p
end

--- Where the ray first meets an entity's box, up to maxT along it: the distance, the point in the
--- entity's own space, the side (axis 1 its right, 2 its forward, 3 its up; sign -1 or 1), and the
--- axes and box it was read with. nil when it misses, starts inside, or is past maxT.
local function rayBox(ent, ox, oy, oz, dx, dy, dz, maxT)
    local r, f, u, p = axesOf(ent)
    local b = boxOf(GetEntityModel(ent))
    local rx, ry, rz = ox - p.x, oy - p.y, oz - p.z
    local o1, o2, o3 = rx * r.x + ry * r.y + rz * r.z, rx * f.x + ry * f.y + rz * f.z, rx * u.x + ry * u.y + rz * u.z
    local d1, d2, d3 = dx * r.x + dy * r.y + dz * r.z, dx * f.x + dy * f.y + dz * f.z, dx * u.x + dy * u.y + dz * u.z
    local tmin, tmax, axis, sign = slab(o1, d1, b[1], b[4], 1, -math.huge, math.huge, nil, 0)
    if not tmin then return nil end
    tmin, tmax, axis, sign = slab(o2, d2, b[2], b[5], 2, tmin, tmax, axis, sign)
    if not tmin then return nil end
    tmin, tmax, axis, sign = slab(o3, d3, b[3], b[6], 3, tmin, tmax, axis, sign)
    if not tmin or not axis or tmin < 0 or tmin > maxT then return nil end
    return tmin, o1 + d1 * tmin, o2 + d2 * tmin, o3 + d3 * tmin, axis, sign, r, f, u, p, b
end

--- THE BODY ITSELF, WHERE THE BOX IS NO USE (e.g. the Skylift). A model's box
--- holds everything the model has — a helicopter's whole rotor span, a plane's wings — so standing by the
--- hull the camera is INSIDE the box (rayBox finds nothing), or, from outside, the box's side is metres out in
--- the air in front of the body. Then the point the look met the body is the one (the shape test's own hit),
--- and the sign stands on it facing out along the surface there: upright on a side, over a top. The map's
--- own surface ('world') is placed the same way, with no entity (`ent` nil).
local function onBody(ent, hitPos, normal, out)
    out.entity, out.x, out.y, out.z = ent, hitPos.x, hitPos.y, hitPos.z
    out.nx, out.ny, out.nz = normal.x, normal.y, normal.z
    local nx, ny, nz = normal.x, normal.y, normal.z
    local hl = math.sqrt(nx * nx + ny * ny)
    if hl < 0.5 then
        -- Facing mostly up (or down): over it, turning to face you
        out.px, out.py, out.pz = hitPos.x + nx * TOP_LIFT, hitPos.y + ny * TOP_LIFT, hitPos.z + nz * TOP_LIFT
        out.heading, out.wrap = nil, nil
        return true
    end
    nx, ny = nx / hl, ny / hl
    out.px, out.py, out.pz = hitPos.x + nx * SIGN_OFF, hitPos.y + ny * SIGN_OFF, hitPos.z
    out.heading = math.deg(math.atan(-nx, ny))
    out.wrap = nil   -- a flat sign: the body has no box corners to wrap round
    return true
end

local function wanted(kinds, ent)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return false end
    local t = GetEntityType(ent)
    for k in pairs(kinds) do
        if KIND_TYPE[k] == t then return true end
    end
    return false
end

local rays, rayFrame, rayCount = {}, -1, 0

local function cameraRay(cam, dx, dy, dz, flags, maxT)
    local frame, ped = GetFrameCount(), PlayerPedId()
    if frame ~= rayFrame then rayFrame, rayCount = frame, 0 end
    for i = 1, rayCount do
        local r = rays[i]
        if r.flags == flags and r.maxT == maxT and r.ped == ped
            and r.x == cam.x and r.y == cam.y and r.z == cam.z
            and r.dx == dx and r.dy == dy and r.dz == dz then
            return r.hit, r.pos, r.normal, r.entity
        end
    end
    rayCount = rayCount + 1
    local r = rays[rayCount]
    if not r then r = {}; rays[rayCount] = r end
    r.flags, r.maxT, r.ped = flags, maxT, ped
    r.x, r.y, r.z, r.dx, r.dy, r.dz = cam.x, cam.y, cam.z, dx, dy, dz
    local _, hit, pos, normal, entity = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
        cam.x, cam.y, cam.z, cam.x + dx * maxT, cam.y + dy * maxT, cam.z + dz * maxT, flags, ped, 4))
    r.hit, r.pos, r.normal, r.entity = hit, pos, normal, entity
    return hit, pos, normal, entity
end

--- What the player is looking at among `kinds`, up to maxT metres from the camera, written into `out`
--- (kept and reused, so nothing is made per frame):
---   out.entity          the thing (nil: the map itself, with 'world' among the kinds)
---   out.x, out.y, out.z the point the look meets its box (onSelect's ctx.coords)
---   out.nx, ny, nz      the way the surface faces there, where the look met the surface itself (the map, a body)
---   out.px, py, pz      where the prompt stands: on that side, or just over the top
---   out.heading         a side's: GTA's heading straight out of it; nil over a top (it faces you)
---   out.wrap            a side's: the box as seen from that side, for the renderer to wrap on
--- `sticky` is the one it had: kept while the look still meets its box. Answers whether it found one.
---@return boolean
function AimBox.aim(kinds, flags, maxT, sticky, out)
    local cam = GetFinalRenderedCamCoord()
    local dx, dy, dz = InteractGetCameraForward()
    local hit, hitPos, hitNormal, ent = cameraRay(cam, dx, dy, dz, flags, maxT)
    local limit, target = maxT, nil
    local wx, wy, wz = hitPos.x - cam.x, hitPos.y - cam.y, hitPos.z - cam.z
    local hitT = math.sqrt(wx * wx + wy * wy + wz * wz)
    -- (The map itself, asked for: where the look meets it, unless the thing it had is still in front of that)
    local onMap = false
    if hit == 1 then
        if wanted(kinds, ent) then
            target = ent
        else
            -- The world, or something not asked for, in the way: nothing behind it counts.
            limit = hitT
            onMap = kinds.world == true and isMap(ent)
        end
    end
    local which = target or ((sticky and wanted(kinds, sticky)) and sticky or nil)
    if not which then
        if onMap then return onBody(nil, hitPos, hitNormal, out) end
        return false
    end

    local t, l1, l2, l3, axis, sign, r, f, u, p, b = rayBox(which, cam.x, cam.y, cam.z, dx, dy, dz, limit)
    -- The look met the body itself, and the box is no use there (the camera inside it, or its side far out
    -- in front of the body): the body's own point (onBody, above)
    if target and (not t or hitT - t > BOX_SLACK) then return onBody(target, hitPos, hitNormal, out) end
    if not t then
        if onMap then return onBody(nil, hitPos, hitNormal, out) end
        return false
    end
    -- (A hit: rayBox answers all of them.)
    ---@cast r -nil
    ---@cast f -nil
    ---@cast u -nil
    ---@cast p -nil
    ---@cast b -nil
    local hx = p.x + r.x * l1 + f.x * l2 + u.x * l3
    local hy = p.y + r.y * l1 + f.y * l2 + u.y * l3
    local hz = p.z + r.z * l1 + f.z * l2 + u.z * l3
    out.entity, out.x, out.y, out.z = which, hx, hy, hz
    out.nx, out.ny, out.nz = nil, nil, nil

    if axis == 3 then
        -- Its top (or underneath): over it, turning to face you.
        out.px, out.py, out.pz = hx + u.x * sign * TOP_LIFT, hy + u.y * sign * TOP_LIFT, hz + u.z * sign * TOP_LIFT
        out.heading, out.wrap = nil, nil
        return true
    end

    -- A side: upright, flat on it, slid along it to where the look meets it. The box on the ground
    -- plan, from the entity's right and forward laid flat.
    local rl = math.sqrt(r.x * r.x + r.y * r.y)
    local fl = math.sqrt(f.x * f.x + f.y * f.y)
    if rl < 0.001 or fl < 0.001 then
        -- On its side, nose up: no upright side to stand on; over it instead.
        out.px, out.py, out.pz, out.heading, out.wrap = hx, hy, hz, nil, nil
        return true
    end
    local rfx, rfy, ffx, ffy = r.x / rl, r.y / rl, f.x / fl, f.y / fl
    local cx, cy = (b[1] + b[4]) / 2, (b[2] + b[5]) / 2
    local halfX, halfY = (b[4] - b[1]) / 2, (b[5] - b[2]) / 2
    local mx, my = p.x + rfx * cx + ffx * cy, p.y + rfy * cx + ffy * cy
    local nx, ny, depth, ax, ay, half
    if axis == 1 then
        nx, ny, depth, ax, ay, half = rfx * sign, rfy * sign, halfX, ffx, ffy, halfY
    else
        nx, ny, depth, ax, ay, half = ffx * sign, ffy * sign, halfY, rfx, rfy, halfX
    end
    local d = depth + SIGN_OFF
    local ox, oy = mx + nx * d, my + ny * d
    local along = (hx - mx) * ax + (hy - my) * ay
    out.px, out.py, out.pz = ox + ax * along, oy + ay * along, hz
    out.heading = math.deg(math.atan(-nx, ny))
    local w = out.wrapT
    if not w then w = {}; out.wrapT = w end
    w.ox, w.oy, w.ax, w.ay, w.tx, w.ty = ox, oy, ax, ay, -nx, -ny
    w.lo, w.hi, w.depth = -(half + SIGN_OFF), half + SIGN_OFF, 2 * d
    out.wrap = w
    return true
end
