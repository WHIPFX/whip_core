-- ============================================
-- VEHICLE POINTS — where an action happens on a vehicle with no door handles
-- ============================================
--
-- 3D prompts for motorbikes, boats, helicopters and planes. A car's prompts hang off
-- its handle, boot and bonnet bones (client/vehicle_prompts.lua). These vehicles mostly have none of
-- those, so each ACTION here finds its spot by a list of places to try, in order (RULES):
--
--   'windscreen'          a NAMED BONE (a part of the model) — a real thing on it, where it has one
--   { 'hbgrip_l', ... }   any of these bones: the one nearest the player
--   'entry'               GTA'S OWN ENTRY POINTS (_GET_ENTRY_POSITION_OF_DOOR): where the game stands
--                         a ped to get on or in; the nearest
--   'box'                 the middle of the model box's side, at waist height; the player's side
--   'box:rear'            the middle of its back (or 'box:front')
--   'filler'              a car's filler, worked out from what every car has (fillerSpot, below): no model
--                         marks one, bar the few with a petrol cap bone
--
-- The first of these the model has is the one. The spot then goes ON THE VEHICLE'S SKIN: a level ray
-- from outside its side in toward the middle, at the spot's height and place along it, so a prompt sits
-- on the paint where the player stands rather than inside the hull. A spot on the middle line (a
-- windscreen) is reached from the side the player is on; one off it (a grip, an entry point), from its
-- own side. Its prompt faces out of that side.
--
-- WORKED OUT ONCE PER MODEL, in the vehicle's own space (plan), so a prompt asking every frame (where)
-- costs a handful of natives: which spot is nearest the player, and where that is now.
--
-- /vehpoints (tools/vehpoints.lua) draws what this answers.

VehiclePoints = {}

-- ============================================
-- What a vehicle is, and the rules
-- ============================================

--- 'bike' | 'cycle' | 'boat' | 'heli' | 'plane' | 'car', by GTA's vehicle class.
---@return string
function VehiclePoints.kindOf(veh)
    local class = GetVehicleClass(veh)
    if class == 8 then return 'bike' end
    if class == 13 then return 'cycle' end
    if class == 14 then return 'boat' end
    if class == 15 then return 'heli' end
    if class == 16 then return 'plane' end
    return 'car'
end

--- What each kind of vehicle could offer, for the overlay. A car's are client/vehicle_prompts.lua's;
--- a helicopter's and a plane's doors are too (their door parts).
VehiclePoints.ACTIONS = {
    bike  = { 'mount', 'fuel', 'engine' },
    cycle = { 'mount' },
    boat  = { 'board', 'fuel', 'engine', 'storage' },
    heli  = { 'board', 'fuel', 'engine' },
    plane = { 'board', 'fuel', 'engine', 'cargo' },
    car   = {},
}

--- Per action, per kind of vehicle (`default` for the rest): the places to try, in order.
VehiclePoints.RULES = {
    mount = {
        -- A bike's is at the end of the handlebar on your side.
        default = { { 'hbgrip_l', 'hbgrip_r' }, 'seat_f', 'entry', 'box' },
    },
    board = {
        -- A boat's is at its windscreen, or its steering wheel when it has none.
        boat    = { 'windscreen', 'steeringwheel', 'entry', 'box' },
        default = { 'entry', { 'seat_dside_f', 'seat_pside_f' }, 'seat_f', 'box' },
    },
    fuel = {
        bike    = { 'petroltank', 'petrolcap', 'box' },
        boat    = { 'petrolcap', 'engine', 'prop_1', 'box' },
        plane   = { { 'wing_l', 'wing_r' }, 'petrolcap', 'engine', 'box' },
        car     = { 'petrolcap', 'filler' },
        default = { 'petrolcap', 'petroltank', 'box' },
    },
    engine = {
        boat    = { 'engine', 'prop_1', 'box:rear' },
        plane   = { 'engine', 'prop_1', 'box:front' },
        default = { 'engine', 'box:rear' },
    },
    storage = { default = { 'boot', 'box:rear' } },
    cargo   = { default = { 'boot', { 'door_hatch_l', 'door_hatch_r' }, 'box:rear' } },
}

-- ============================================
-- What a vehicle has
-- ============================================

local NATIVE_ENTRY_POSITION = 0xC0572928C0ABFDA3   -- _GET_ENTRY_POSITION_OF_DOOR(vehicle, doorIndex)
local ENTRY_INDICES = 8                             -- eDoorId 0-7: the four doors, bonnet, boot, two more
local MIDDLE = 0.15                                 -- metres either side of the middle line that count as on it
local FACING = { left = 90.0, right = -90.0, front = 0.0, rear = 180.0 }   -- a sign out of that side, from the vehicle's heading

--- GTA's entry points for this vehicle, in the world: { { index, pos } }. An index the vehicle has no
--- entry for answers nothing useful (zero, or the vehicle's own origin); those, and repeats, are left
--- out.
function VehiclePoints.entries(veh)
    local out = {}
    local origin = GetEntityCoords(veh)
    for i = 0, ENTRY_INDICES - 1 do
        local ok, p = pcall(Citizen.InvokeNative, NATIVE_ENTRY_POSITION, veh, i, Citizen.ResultAsVector())
        if ok and p and (p.x ~= 0.0 or p.y ~= 0.0 or p.z ~= 0.0) then
            local d = #(p - origin)
            if d > 0.05 and d < 25.0 then
                local dup = false
                for _, e in ipairs(out) do
                    if #(e.pos - p) < 0.2 then dup = true break end
                end
                if not dup then out[#out + 1] = { index = i, pos = p } end
            end
        end
    end
    return out
end

--- The model's box in the vehicle's own space: { mn, mx } (vector3s), or nil.
local _box = {}
function VehiclePoints.box(veh)
    local model = GetEntityModel(veh)
    local b = _box[model]
    if b == nil then
        local mn, mx = GetModelDimensions(model)
        b = (mn and mx and (mx.y - mn.y) > 0.05) and { mn = mn, mx = mx } or false
        if b then _box[model] = b end
    end
    return b or nil
end

--- The middle of one side of the box ('left' | 'right' | 'front' | 'rear') at waist height (a metre up
--- from its bottom, or half its height if lower), in the vehicle's own space.
---@return vector3|nil
function VehiclePoints.boxSide(veh, which)
    local b = VehiclePoints.box(veh)
    if not b then return nil end
    local mn, mx = b.mn, b.mx
    local x, y = (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5
    local z = mn.z + math.min(1.0, (mx.z - mn.z) * 0.5)
    if which == 'left' then x = mn.x
    elseif which == 'right' then x = mx.x
    elseif which == 'front' then y = mx.y
    else y = mn.y end
    return vector3(x, y, z)
end

local function toLocal(veh, p)
    return GetOffsetFromEntityGivenWorldCoords(veh, p.x, p.y, p.z)
end

--- A bone's place in the vehicle's own space, or nil when the model has no such bone.
local function boneAt(veh, name)
    local i = GetEntityBoneIndexByName(veh, name)
    if i == -1 then return nil end
    return toLocal(veh, GetWorldPositionOfEntityBone(veh, i))
end

--- The first of these bones the model has, in its own space.
local function firstBoneAt(veh, names)
    for _, name in ipairs(names) do
        local p = boneAt(veh, name)
        if p then return p end
    end
    return nil
end

-- ============================================
-- A car's filler
-- ============================================
--
-- No model marks where its fuel goes in, bar the few with a petrol cap bone. So it is worked out from
-- what every car has: ABOVE A REAR WHEEL, AT THE HEIGHT OF ITS DOOR HANDLES, on one side, where most
-- cars' fuel doors are. Which side is the model's own (Config.VehicleFillers), else the side of the
-- one side tank it has, else a guess fixed per model: always the same side for the same model.
--
--   a side tank           a model with petroltank_l / petroltank_r (a truck's tank under its cab): there
--   a truck               an industrial or commercial one without: between its front wheel and the next
--                         one back, at the top of the wheels (where a truck's side tank hangs)
--   nothing there         a dune buggy has no body above its rear wheel at handle height: the top of the
--                         wheel instead, onto whatever is there (skinOf)

local SIDE_BONES = {
    left  = { tank = 'petroltank_l', rear = 'wheel_lr', front = 'wheel_lf', middle = 'wheel_lm1',
              handles = { 'handle_dside_r', 'handle_dside_f' } },
    right = { tank = 'petroltank_r', rear = 'wheel_rr', front = 'wheel_rf', middle = 'wheel_rm1',
              handles = { 'handle_pside_r', 'handle_pside_f' } },
}
local OTHER = { left = 'right', right = 'left' }
local TRUCK_CLASSES = { [10] = true, [20] = true }   -- industrial, commercial
local WHEEL_TOP_CLEAR = 0.08                         -- metres above a wheel's top: on the body, not the tyre

--- Which side the filler is on: 'left' | 'right' | 'rear', and how that was known ('set', 'tank', 'guess').
local function fillerSide(veh, model)
    local set = (Config.VehicleFillers or {})[model]
    set = type(set) == 'table' and set.side or nil
    if set == 'left' or set == 'right' or set == 'rear' then return set, 'set' end
    local l = GetEntityBoneIndexByName(veh, 'petroltank_l') ~= -1
    local r = GetEntityBoneIndexByName(veh, 'petroltank_r') ~= -1
    if l ~= r then return l and 'left' or 'right', 'tank' end
    return (model % 2 == 0) and 'left' or 'right', 'guess'
end

--- This car's filler, in its own space: { source, at, side | face, low? }. `low` is a second height to try
--- when nothing is at `at`'s (skinOf). nil without a model box.
local function fillerSpot(veh)
    local b = VehiclePoints.box(veh)
    if not b then return nil end
    local side, why = fillerSide(veh, GetEntityModel(veh))

    -- The door handles' height: this side's (its rear door's, nearer the wheel), else the other's, else waist.
    local near = SIDE_BONES[side] or SIDE_BONES.left
    local far = SIDE_BONES[OTHER[side] or 'right']
    local handle = firstBoneAt(veh, near.handles) or firstBoneAt(veh, far.handles)
    local high = handle and handle.z or VehiclePoints.boxSide(veh, 'left').z

    if side == 'rear' then
        return { source = 'filler:rear (' .. why .. ')', at = vector3(0.0, b.mn.y, high), face = 'rear' }
    end

    local x = (side == 'left') and b.mn.x or b.mx.x
    local tank = boneAt(veh, near.tank)
    if tank then
        return { source = 'filler:' .. near.tank, at = vector3(x, tank.y, tank.z), side = side }
    end

    local rear = boneAt(veh, near.rear) or boneAt(veh, far.rear)
    local front = boneAt(veh, near.front) or boneAt(veh, far.front)
    -- A wheel's top: its middle is as high above the ground (the box's bottom) as its top is above its middle.
    local function top(w)
        if not w or w.z <= b.mn.z then return nil end
        return w.z + (w.z - b.mn.z) + WHEEL_TOP_CLEAR
    end

    if TRUCK_CLASSES[GetVehicleClass(veh)] and front and rear then
        local behind = boneAt(veh, near.middle) or boneAt(veh, far.middle) or rear
        return { source = 'filler:truck (' .. why .. ')', side = side,
                 at = vector3(x, (front.y + behind.y) * 0.5, top(front) or high) }
    end

    if not rear then
        -- No wheels to go by: a quarter of the way up from the back.
        return { source = 'filler:box (' .. why .. ')', side = side,
                 at = vector3(x, b.mn.y + (b.mx.y - b.mn.y) * 0.25, high) }
    end
    return { source = 'filler:rear wheel (' .. why .. ')', side = side,
             at = vector3(x, rear.y, high), low = top(rear) }
end

-- ============================================
-- The plan: an action's spots on one model
-- ============================================

--- [action][model] = plan, or false for a model with nowhere for it.
local plans = {}

-- A model's filler side is a setting: every plan is worked out again when it changes.
Settings.onChange('VehicleFillers', function()
    for action in pairs(plans) do plans[action] = nil end
end)

--- The spots one place to try gives on this vehicle, in its own space: { source, at, side?, face? }.
local function spotsOf(veh, place)
    local out = {}
    if place == 'entry' then
        for _, e in ipairs(VehiclePoints.entries(veh)) do
            out[#out + 1] = { source = 'entry:' .. e.index, at = toLocal(veh, e.pos) }
        end
    elseif place == 'box' then
        for _, side in ipairs({ 'left', 'right' }) do
            local at = VehiclePoints.boxSide(veh, side)
            if at then out[#out + 1] = { source = 'box:' .. side, at = at, side = side } end
        end
    elseif place == 'filler' then
        out[1] = fillerSpot(veh)
    elseif type(place) == 'string' and place:sub(1, 4) == 'box:' then
        local face = place:sub(5)
        local at = VehiclePoints.boxSide(veh, face)
        if at then out[1] = { source = place, at = at, face = face } end
    else
        for _, name in ipairs(type(place) == 'table' and place or { place }) do
            local i = GetEntityBoneIndexByName(veh, name)
            if i ~= -1 then
                out[#out + 1] = { source = 'bone:' .. name, at = toLocal(veh, GetWorldPositionOfEntityBone(veh, i)) }
            end
        end
    end
    return out
end

--- This action's spots on this vehicle's model, worked out once per model:
--- { action, kind, place (the one that answered, as written in RULES), spots = { { source, at, side?,
--- face?, skin = {}, retryAt = {} } } }. nil when the model has none of the places.
---@param model number|nil  the vehicle's model, when the caller has read it this frame
---@return table|nil
function VehiclePoints.plan(veh, action, model)
    local byModel = plans[action]
    if not byModel then
        if not VehiclePoints.RULES[action] then return nil end
        byModel = {}
        plans[action] = byModel
    end
    model = model or GetEntityModel(veh)
    local plan = byModel[model]
    if plan ~= nil then return plan or nil end

    local kind = VehiclePoints.kindOf(veh)
    local rule = VehiclePoints.RULES[action]
    plan = false
    for _, place in ipairs(rule[kind] or rule.default) do
        local spots = spotsOf(veh, place)
        if #spots > 0 then
            for _, s in ipairs(spots) do
                -- Which side it is on, when it is off the middle line; nil: the player's side.
                if not s.side and not s.face then
                    s.side = (s.at.x <= -MIDDLE and 'left') or (s.at.x >= MIDDLE and 'right') or nil
                end
                s.skin, s.retryAt = {}, {}
            end
            plan = { action = action, kind = kind, place = place, spots = spots }
            break
        end
    end
    byModel[model] = plan
    return plan or nil
end

-- ============================================
-- Onto the skin
-- ============================================

--- A spot's place on this side's skin: a level ray from outside the box's side, at the spot's place
--- along the vehicle and its height, in toward the middle line, and where it first meets this vehicle.
---@return vector3|nil skin  in the vehicle's own space
---@return boolean settled  fit to keep: false when something else was in the way (asked again later)
local function measureSkin(veh, at, side)
    local b = VehiclePoints.box(veh)
    if not b then return nil, true end
    local sign = (side == 'left') and -1.0 or 1.0
    local s = GetOffsetFromEntityInWorldCoords(veh, ((sign < 0) and b.mn.x or b.mx.x) + sign, at.y, at.z)
    local e = GetOffsetFromEntityInWorldCoords(veh, 0.0, at.y, at.z)
    local _, hit, pos, _, ent = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
        s.x, s.y, s.z, e.x, e.y, e.z, 2, PlayerPedId(), 7))
    if hit ~= 1 then return nil, true end     -- nothing there to stand on (an open deck): the spot itself
    if ent ~= veh then return nil, false end  -- another vehicle alongside
    return toLocal(veh, pos), true
end

--- This spot on `side`'s skin (its own `at` when there is no skin there), in the vehicle's own space.
--- Measured the first time it is asked for, then kept with the plan. A spot with a `low` height (a car's
--- filler) is tried there too when nothing is at its own: the skin found there is the one kept.
local function skinOf(veh, spot, side)
    if spot.face then return spot.at end
    local s = spot.skin[side]
    if s then return s end
    if s == false then return spot.at end
    local now = GetGameTimer()
    if (spot.retryAt[side] or 0) > now then return spot.at end
    local found, settled = measureSkin(veh, spot.at, side)
    if not found and settled and spot.low then
        found, settled = measureSkin(veh, vector3(spot.at.x, spot.at.y, spot.low), side)
    end
    if found then
        spot.skin[side] = found
        return found
    end
    if settled then spot.skin[side] = false else spot.retryAt[side] = now + 1000 end
    return spot.at
end

-- ============================================
-- Where, now
-- ============================================

local atan2 = math.atan

--- The vehicle's own axes and origin: GetEntityMatrix's four answers (forward, right, up, position: forward first, as
--- client/doors.lua reads it), or the ones the caller read this frame (`c`: client/vehicle_prompts.lua reads a car once
--- a prompt pass for all its circles). The offsets here are worked out from them, one native for what took two or three.
---@param c table|nil  { fwd, right, up, pos }
---@return vector3 fwd, vector3 right, vector3 up, vector3 pos
function VehiclePoints.axes(veh, c)
    if c then return c.fwd, c.right, c.up, c.pos end
    return GetEntityMatrix(veh)
end

--- A point in the vehicle's own space, in the world (what GetOffsetFromEntityInWorldCoords answers), from its axes.
---@return number x, number y, number z
function VehiclePoints.toWorld(fwd, right, up, pos, x, y, z)
    return pos.x + right.x * x + fwd.x * y + up.x * z,
           pos.y + right.y * x + fwd.y * y + up.y * z,
           pos.z + right.z * x + fwd.z * y + up.z * z
end

--- VehiclePoints.facing, on axes already in hand.
local function facingOn(veh, fwd, right, a)
    local r = math.rad(a)
    local s, k = -math.sin(r), math.cos(r)
    -- The vehicle's own (-sin a, cos a, 0) in the world, its level part
    local nx, ny = right.x * s + fwd.x * k, right.y * s + fwd.y * k
    if nx * nx + ny * ny < 0.04 then return (GetEntityHeading(veh) + a) % 360.0 end
    return math.deg(atan2(-nx, ny)) % 360.0
end

--- The world heading a sign must face to look along the vehicle's own direction `a` (degrees from its front, + to its
--- left), on the vehicle as it lies now. Upright that is its heading plus `a`. Past its side (on its roof), its left is
--- the world's right: the sign turns round with it (180 degrees) instead of facing into it and going out of sight, and
--- stays upright, so it reads the right way. Within about 12 degrees of straight up or down (on its side): its heading
--- plus `a`, as before.
---@param veh number
---@param a number
---@param c table|nil  the vehicle's axes, when the caller read them this frame (VehiclePoints.axes)
---@return number heading  degrees, 0-360
function VehiclePoints.facing(veh, a, c)
    local fwd, right = VehiclePoints.axes(veh, c)
    return facingOn(veh, fwd, right, a)
end

--- Where this action's prompt is on this vehicle right now: the spot nearest the player, on the skin,
--- and the heading of a sign facing out of its side. nil when the model has nowhere for it.
---@param c table|nil  the vehicle's model and axes, when the caller read them this frame ({ model, fwd, right, up, pos })
---@param me vector3|nil  the player's position, likewise
---@return number|nil x, number y, number z, number heading, table spot, string side
function VehiclePoints.where(veh, action, c, me)
    local plan = VehiclePoints.plan(veh, action, c and c.model)
    ---@diagnostic disable-next-line: missing-return-value -- nil alone: nowhere (the rest come only with x)
    if not plan then return nil end
    local fwd, right, up, pos = VehiclePoints.axes(veh, c)
    me = me or GetEntityCoords(PlayerPedId())
    -- The player in the vehicle's own space: how far along each axis (a metre long, square to the others)
    local mx, my, mz = me.x - pos.x, me.y - pos.y, me.z - pos.z
    local plx = mx * right.x + my * right.y + mz * right.z
    local ply = mx * fwd.x + my * fwd.y + mz * fwd.z
    local plz = mx * up.x + my * up.y + mz * up.z
    local best, bestD = nil, math.huge
    for _, s in ipairs(plan.spots) do
        local dx, dy, dz = s.at.x - plx, s.at.y - ply, s.at.z - plz
        local d = dx * dx + dy * dy + dz * dz
        if d < bestD then best, bestD = s, d end
    end
    ---@cast best -nil   -- a plan has a spot at least (VehiclePoints.plan)
    local side = best.face or best.side or ((plx < 0) and 'left' or 'right')
    local at = skinOf(veh, best, side)
    local x, y, z = VehiclePoints.toWorld(fwd, right, up, pos, at.x, at.y, at.z)
    return x, y, z, facingOn(veh, fwd, right, FACING[side]), best, side
end

-- ============================================
-- For every resource
-- ============================================
--
-- Where a named point is on a vehicle — its filler ('fuel'), its engine, its boot ('storage'), how you get on
-- ('mount', 'board'), its cargo — on this vehicle, now, on the side nearest the player: for whatever a resource
-- puts there (a nozzle, a cable, a hose). A resource may also name points of its own (a wash bay's spot, a
-- charging port) by the same rules (VehiclePoints.RULES: per kind of vehicle, the places to try in order), and
-- they go when it stops.

--- A place in a rule: a bone name, 'entry', 'box', 'box:rear', 'box:front', 'filler', or a list of bone names.
local function isPlace(p)
    if type(p) == 'string' then return p ~= '' end
    if type(p) ~= 'table' or #p == 0 then return false end
    for _, b in ipairs(p) do if type(b) ~= 'string' or b == '' then return false end end
    return true
end

--- The resources' own points: a registry (shared/registry.lua), [action] = rules. Each is its resource's; one that
--- stops takes its points with it (the sweep). Put in VehiclePoints.RULES as they come, and out as they go.
local pointReg   -- (named first: its validate reads it)
pointReg = Registry.new('vehiclePoints', {
    label = 'vehicle point',
    validate = function(action, rules)
        if VehiclePoints.RULES[action] and not pointReg:get(action) then
            return false, ('"%s" is whip\'s own point'):format(action)
        end
        if type(rules) ~= 'table' or type(rules.default) ~= 'table' then
            return false, 'rules = { default = { place, ... }, <kind> = { ... } }'
        end
        for kind, list in pairs(rules) do
            if type(kind) ~= 'string' or type(list) ~= 'table' or #list == 0 then
                return false, ('rules.%s is a list of places'):format(tostring(kind))
            end
            for i, p in ipairs(list) do
                if not isPlace(p) then
                    return false, ('rules.%s[%d] is not a place (a bone name, a list of them, entry, box, box:rear, box:front)'):format(kind, i)
                end
            end
        end
        return true
    end,
    onAdd = function(action, rules)
        VehiclePoints.RULES[action] = rules
        plans[action] = nil   -- worked out again with these
    end,
    onRemove = function(action)
        VehiclePoints.RULES[action] = nil
        plans[action] = nil
    end,
})

--- Is every spot of this plan on the one side, whichever side the player stands (a car's filler)? Not when they are
--- on both sides (a boat's box) or on the middle line (the player's side, then).
local function oneSided(plan)
    local only = nil
    for _, s in ipairs(plan.spots) do
        local side = s.face or s.side
        if not side or (only and side ~= only) then return false end
        only = side
    end
    return only ~= nil
end

--- Where `action`'s point is on `vehicle` now: { x, y, z, heading (a sign facing out of its side), side ('left',
--- 'right', 'front', 'rear'), fixed }, or nil when the model has nowhere for it. `fixed`: the point is on that side
--- wherever the player stands (a car's filler is on one side of it); false, it is on the side they are on. `vehicle`
--- is a vehicle reference, as every vehicle export takes: a bare number is a vehicleId, the entity is
--- { entity = veh } (audit 20, VEH-8).
---@return table|nil
exports('GetVehiclePoint', function(ref, action)
    local vehicle = Vehicles.refEntity(ref)
    if type(action) ~= 'string' or not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return nil end
    local x, y, z, heading, _, side = VehiclePoints.where(vehicle, action)
    if not x then return nil end
    return { x = x, y = y, z = z, heading = heading, side = side,
             fixed = oneSided(VehiclePoints.plan(vehicle, action)) }
end)

--- Name a point of the caller's own: `rules` = { default = { place, ... }, bike = { ... }, boat = ... } as in
--- VehiclePoints.RULES (a place is a bone name, a list of bone names, 'entry', 'box', 'box:rear' or 'box:front').
--- whip's own points cannot be renamed; a point of another resource's cannot be taken.
---@return boolean ok, string|nil why
exports('SetVehiclePointRules', function(action, rules)
    local owner = Registry.caller()
    if type(action) ~= 'string' or action == '' then return false, 'name the point' end
    local ok, why = pointReg:add(owner, action, rules)
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end)
