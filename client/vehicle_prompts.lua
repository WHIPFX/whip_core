-- Interaction circles on parts of a car: boot, bonnet, each door's handle (and its inside while open).
-- A table of parts (PARTS), one row each. The circle sits on the panel's free edge, opposite the
-- hinge (partGeometry), follows a swinging door (partPoint), and a torn-off panel has `onDetached`.
-- The actions live in client/vehicles.lua.

-- The parts
--
-- `side` is the face of the car the circle lives on (box face, sign direction, "outward").
-- `clearance` positive is further out from the car, negative inset.
local SIDES = {
    front = { axis = 'y', sign =  1.0, heading =   0.0 },
    rear  = { axis = 'y', sign = -1.0, heading = 180.0 },
    -- Local +X is the car's right; the driver's side is the left in every stock model, so `dside` bones are `left`.
    left  = { axis = 'x', sign = -1.0, heading =  90.0 },
    right = { axis = 'x', sign =  1.0, heading = -90.0 },
}
--
-- `edgeDir` is which way the free edge lies from the hinge, and so which axis the panel swings about:
--   'down' (boot lid, bonnet) and 'up' (tailgate): about X
--   'aft' (ordinary door), 'fore' (rear-hinged door) and 'mirror' (hinged down one side): about Z
--   'auto': worked out from the model (partGeometry); only the boot varies.

-- Options contributed by other resources: a satellite adds an AddAction with
-- `at = { vehiclePart = 'hood' }` and client/actions.lua hands it to VehiclePartOptions.add as
-- { id, icon, label, can, act }. Engine work goes on 'hood'. A part can gate contributions with
-- `extrasRequire` (see bindOptions). Keyed by owning resource, so a restart replaces its options.

--- [partKey][resourceName] = { option, option, ... }
local extraOptions = {}

--- whip_core's own name: its contributions keep their place in the stack.
local CORE = GetCurrentResourceName()

-- What a car is asked, once a pass: each question is asked once per prompt pass (Interactions.pass) and
-- shared by every circle and option on the car. Between passes it asks the car itself.

--- [veh] = { at = { [question] = the pass it was asked in }, v = { [question] = its answer } }
local carAsks = {}

--- `fn(veh)`, or `fn(veh, arg)`, asked once this pass for this car. `key` names the question with its argument.
local function askCar(veh, key, fn, arg)
    local pass = Interactions.pass
    if not pass then
        if arg == nil then return fn(veh) end
        return fn(veh, arg)
    end
    local a = carAsks[veh]
    if not a then
        a = { at = {}, v = {} }
        carAsks[veh] = a
    end
    if a.at[key] == pass then return a.v[key] end
    local v
    if arg == nil then v = fn(veh) else v = fn(veh, arg) end
    a.at[key], a.v[key] = pass, v
    return v
end

-- The per-door question names
local DOOR_OPEN, DOOR_TORN, DOOR_RATIO = {}, {}, {}
for i = 0, 7 do DOOR_OPEN[i], DOOR_TORN[i], DOOR_RATIO[i] = 'open' .. i, 'torn' .. i, 'ratio' .. i end

local function carThere(veh) return askCar(veh, 'there', DoesEntityExist) end
local function carLocked(veh) return askCar(veh, 'locked', Vehicles.isLocked) end
local function doorOpen(veh, i) return askCar(veh, DOOR_OPEN[i], Vehicles.isDoorOpen, i) end
local function doorTorn(veh, i) return askCar(veh, DOOR_TORN[i], IsVehicleDoorDamaged, i) end

--- Open / shut this door, on its handle. A locked car refuses, so with no key or pick the prompt usually does not draw.
---@param doorIndex number
---@return table option
local function doorOption(doorIndex)
    return {
        id    = 'door',
        icon  = 'door',
        label = function(veh)
            return doorOpen(veh, doorIndex) and 'Close Door' or 'Open Door'
        end,
        can   = function(veh) return not carLocked(veh) end,
        act   = function(veh) Vehicles.toggleDoor(veh, doorIndex) end,
        press = true,   -- the hand on the handle first (pressThen)
    }
end

--- Close this door: the one option on the inside of an open door. It shuts rather than toggles, so a
--- second press while swinging shut cannot reopen it. Same lock gate as the outside.
---@param doorIndex number
---@return table option
local function doorCloseOption(doorIndex)
    return {
        id    = 'door',
        icon  = 'door',
        label = 'Close Door',
        can   = function(veh) return not carLocked(veh) end,
        act   = function(veh) Vehicles.shutDoor(veh, doorIndex) end,
        press = true,   -- the hand on the door first (pressThen)
    }
end

--- One passenger door's part definition. `act` and `can` take the vehicle; addPrompt binds them to the car.
---@param isFront boolean  front doors carry the lock and lockpick options; rear doors do not
---@param handleBone string  the authored handle bone (see partGeometry)
local function doorPart(key, bone, handleBone, doorIndex, side, isFront)
    local opts = {}

    -- Store is on every door too, added by client/garage_spots.lua through VehiclePartOptions.add.

    if isFront then
        -- Lock / unlock: needs a key.
        opts[#opts + 1] = {
            id    = 'lock',
            icon  = function(veh) return carLocked(veh) and 'lock' or 'unlock' end,
            label = function(veh) return carLocked(veh) and 'Unlock' or 'Lock' end,
            can   = function(veh) return askCar(veh, 'key', Vehicles.playerHasKey) end,
            act   = function(veh) Vehicles.toggleLock(veh) end,
        }

        -- Lockpick: a locked car and a pick in hand.
        opts[#opts + 1] = {
            id    = 'lockpick',
            icon  = 'lockpick',
            label = 'Lockpick',
            can   = function(veh) return askCar(veh, 'pick', Vehicles.canLockpick) end,
            act   = function(veh) Vehicles.startLockpick(veh) end,
        }
    end

    -- Open / shut this door (doorOption).
    opts[#opts + 1] = doorOption(doorIndex)

    return {
        key     = key,
        -- All four read one config entry (`tune`).
        tuneKey = 'door',
        bone    = bone,

        -- The circle goes on the handle itself; the hinge is only the fallback's reference.
        anchorBone = handleBone,

        door    = doorIndex,
        side    = side,
        edgeDir = 'aft',

        -- No door, no prompt.
        onDetached = 'hide',

        options = opts,

        -- `drop` and `rise` are for an add-on model without handle bones.
        def = { drop = 0.62, rise = 0.18, clearance = 0.0,
                range = 1.8, activeRange = 1.1, scale = 1.32 },
    }
end

--- The inside of one open door: a circle on its inner face that closes it. It sits opposite the handle,
--- `inset` in, facing the other way, and swings with the door. Only while open, only Close Door.
---@return table part
local function doorInsidePart(key, bone, handleBone, doorIndex, side)
    return {
        key        = key,
        -- The doors' tuning entry, plus `inset`.
        tuneKey    = 'door',
        bone       = bone,
        anchorBone = handleBone,
        door       = doorIndex,
        side       = side,
        edgeDir    = 'aft',
        face       = 'inside',
        onDetached = 'hide',
        can        = function(veh) return doorOpen(veh, doorIndex) end,
        options    = { doorCloseOption(doorIndex) },
        def = { drop = 0.62, rise = 0.18, clearance = 0.0, inset = 0.12,
                range = 1.8, activeRange = 1.1, scale = 1.32 },
    }
end

--- Get on / Board: into the driver's seat (Seats.enter), while it is free and the vehicle unlocked.
---@param label string
---@return table option
local function rideOption(label)
    return {
        id    = 'ride',
        icon  = 'seat',
        label = label,
        can   = function(veh)
            if carLocked(veh) then return false end
            local free = IsVehicleSeatFree(veh, -1)
            return free == 1 or free == true
        end,
        act   = function(veh) Seats.enter(veh, -1) end,
    }
end

--- A prompt on a vehicle with no door handles (bike, bicycle, boat). client/vehicle_points.lua finds the
--- spot on the player's side; there is no panel to follow. The rest works as a car part does.
---@param kinds table  { [kind] = true }, VehiclePoints.kindOf's names
---@return table part
local function pointPart(key, kinds, point, options, def)
    return {
        key     = key,
        kinds   = kinds,
        point   = point,
        fixed   = true,
        options = options,
        -- Only the reach and the size apply here; the spot is the model's own.
        def     = def or { drop = 0.0, rise = 0.0, clearance = 0.0, range = 1.8, activeRange = 1.1, scale = 1.32 },
    }
end

--- Has this car a boot lid to open? Not once torn off, nor on a model whose boot has no door 5.
---@return boolean
local function hasTrunkLid(veh)
    if not GetIsDoorValid(veh, 5) then return false end   -- BOOL: 1 or false, so a truth test
    return not doorTorn(veh, 5)
end
local function trunkLid(veh) return askCar(veh, 'lid', hasTrunkLid) end

local PARTS = {
    {
        key     = 'trunk',
        bone    = 'boot',
        door    = 5,
        side    = 'rear',
        edgeDir = 'auto',

        -- Holds still: the circle stays where the shut lid puts it.
        fixed   = true,

        -- The storage is the car's, so the prompt stays without a lid, with only View Trunk Inventory.
        onDetached = 'fallback',

        -- The lid comes first, then the storage:
        --   lid shut: Open Trunk. lid open: Close Trunk, View Trunk Inventory.
        --   no lid (torn off, or no boot door): View Trunk Inventory. locked: nothing.
        -- The lid stays first so E keeps the same option under the player when the storage appears.
        options = {
            {
                id = 'lid',

                label = function(veh)
                    return doorOpen(veh, 5) and 'Close Trunk' or 'Open Trunk'
                end,
                icon = 'trunk_lid',

                -- No lid: this option drops out of the stack.
                can = function(veh)
                    if not trunkLid(veh) then return false end
                    return askCar(veh, 'trunkOk', Vehicles.canOpenTrunk)
                end,
                act = function(veh) Vehicles.toggleDoor(veh, 5) end,
                press = true,
            },
            {
                id = 'storage',

                label = 'View Trunk Inventory',

                -- Offered with the boot open (or no lid at all).
                icon = 'trunk_open',

                can = function(veh)
                    if not askCar(veh, 'trunkOk', Vehicles.canOpenTrunk) then return false end
                    if not askCar(veh, 'trunkHas', Vehicles.hasStorage, 'trunk') then return false end
                    return not trunkLid(veh) or doorOpen(veh, 5)
                end,
                act = function(veh) Vehicles.openTrunk(veh) end,
                press = true,   -- the hand towards the boot first (pressThen)
            },
        },
        def = { drop = 0.30, clearance = -0.15, range = 1.8, activeRange = 1.1, scale = 1.32 },
    },
    {
        key     = 'hood',
        bone    = 'bonnet',
        door    = 4,
        side    = 'front',
        edgeDir = 'down',

        -- Holds still, as the boot does.
        fixed   = true,

        -- The prompt survives the panel (engine work goes here); a detached panel's point is the closed anchor.
        onDetached = 'fallback',

        -- Contributed options need the bay open (see extraOptions); torn off counts as open.
        extrasRequire = function(veh)
            if doorTorn(veh, 4) then return true end
            return askCar(veh, 'hoodOpen', Vehicles.isHoodOpen)
        end,

        -- An intact bonnet needs the car unlocked (the release is in the cabin); a torn-off one does not.
        can = function(veh)
            if doorTorn(veh, 4) then return true end
            return askCar(veh, 'hoodOk', Vehicles.canOpenHood)
        end,

        options = {
            {
                id = 'hood',

                -- The picture shows open or shut.
                label = function() return 'Hood' end,
                icon  = function(veh)
                    return askCar(veh, 'hoodOpen', Vehicles.isHoodOpen) and 'hood_open' or 'hood_closed'
                end,

                -- Gone with the panel; contributed options stay.
                can = function(veh)
                    if doorTorn(veh, 4) then return false end
                    return askCar(veh, 'hoodOk', Vehicles.canOpenHood)
                end,
                act = function(veh) Vehicles.toggleHood(veh) end,
                press = true,   -- the hand towards the bonnet first (pressThen)
            },
        },

        def = { drop = 0.30, clearance = -0.15, range = 1.8, activeRange = 1.1, scale = 1.32 },
    },

    -- The four passenger doors; the rear ones carry no lock or lockpick.
    --                 key             hinge bone      handle bone       idx  side     front?
    doorPart('door_dside_f', 'door_dside_f', 'handle_dside_f', 0, 'left',  true),
    doorPart('door_pside_f', 'door_pside_f', 'handle_pside_f', 1, 'right', true),
    doorPart('door_dside_r', 'door_dside_r', 'handle_dside_r', 2, 'left',  false),
    doorPart('door_pside_r', 'door_pside_r', 'handle_pside_r', 3, 'right', false),

    -- The same four doors from the inside, while open.
    doorInsidePart('door_dside_f_in', 'door_dside_f', 'handle_dside_f', 0, 'left'),
    doorInsidePart('door_pside_f_in', 'door_pside_f', 'handle_pside_f', 1, 'right'),
    doorInsidePart('door_dside_r_in', 'door_dside_r', 'handle_dside_r', 2, 'left'),
    doorInsidePart('door_pside_r_in', 'door_pside_r', 'handle_pside_r', 3, 'right'),

    -- Vehicles with no door handles: a bike's at the handlebar end on your side, a boat's at its windscreen
    -- or wheel. A boat's reaches further, to board from a jetty or the water.
    pointPart('bike',    { bike = true },  'mount', { rideOption('Get On') }),
    pointPart('bicycle', { cycle = true }, 'mount', { rideOption('Get On') }),
    pointPart('boat',    { boat = true },  'board', { rideOption('Board') },
              { drop = 0.0, rise = 0.0, clearance = 0.0, range = 3.0, activeRange = 2.2, scale = 1.32 }),

    -- A car's filler, where a pump's nozzle goes (client/vehicle_points.lua fillerSpot; Config.VehicleFillers
    -- sets the side). No options of its own, so it shows only while a resource's is on offer.
    pointPart('fuel',    { car = true },   'fuel', {}),
}
-- `scale` multiplies how big the circle and its text are drawn, for vehicle prompts only.

--- This part's tuning: config if there is any, else the part's own defaults. Read at use, not cached.
--- `tuneKey` lets several parts share one set of figures.
local function tune(part, field)
    local all = Config.VehiclePartPrompts
    local mine = all and all[part.tuneKey or part.key]
    local v = mine and mine[field]
    if v ~= nil then return v end
    return part.def[field]
end

-- [partKey][entity] = { id, model, label }
local held = {}

-- [partKey][model] = geometry record (see partGeometry) or `false` for a model with no such bone.
-- Keyed by model, so the bone lookup and hinge classification happen once per model.
local anchorCache = {}

for _, part in ipairs(PARTS) do
    held[part.key] = {}
    anchorCache[part.key] = {}
end

local function sign(v) return (v < 0) and -1 or 1 end

--- Has this panel been torn off the car? A part with no door index never is.
local function isDetached(part, veh)
    if not part.door then return false end
    return doorTorn(veh, part.door)
end

-- A car read once a prompt pass: existence, model and matrix are read once per pass (Interactions.pass)
-- and shared by all its circles, as is the player's position (for pointPart).

--- [veh] = { pass, exists, model, fwd, right, up, pos }, while the car has prompts
local carFacts = {}
local playerSeen = { pass = nil, at = nil }

---@return table  { exists, model, fwd, right, up, pos } as of this pass
local function factsOf(veh)
    local pass = Interactions.pass
    local c = carFacts[veh]
    if c and pass and c.pass == pass then return c end
    if not c then
        c = {}
        carFacts[veh] = c
    end
    c.pass = pass
    c.exists = carThere(veh)
    if c.exists then
        c.model = GetEntityModel(veh)
        c.fwd, c.right, c.up, c.pos = GetEntityMatrix(veh)
    end
    return c
end

---@return vector3  the player's position as of this pass
local function playerAt()
    local pass = Interactions.pass
    if not (pass and playerSeen.pass == pass) then
        playerSeen.pass, playerSeen.at = pass, GetEntityCoords(PlayerPedId())
    end
    return playerSeen.at
end

-- Where the circle goes, and which way the panel swings

--- The door's own skin, for a door with no handle bone. A helicopter's or plane's box is far wider than
--- its door, so a level ray from outside the box toward the middle finds where it first meets this vehicle.
--- Measured with the door shut. Until then, or while something else is in the way, the hinge's line
--- stands in and is measured again a second later (`settled` false); a meeting further out than a
--- door bulges, or none at all, keeps the hinge's line.
---@return number x  the skin, across the model's own space
---@return boolean settled  fit to keep for this model
local function doorSkin(veh, part, sd, bl, edgeY, rise, minDim, maxDim)
    local hingeX = bl.x
    local ratio = GetVehicleDoorAngleRatio(veh, part.door) or 0.0
    if ratio > 0.01 then return hingeX, false end
    local y, z = bl.y + edgeY, bl.z + rise
    local s = GetOffsetFromEntityInWorldCoords(veh, ((sd.sign < 0) and minDim.x or maxDim.x) + sd.sign, y, z)
    local e = GetOffsetFromEntityInWorldCoords(veh, 0.0, y, z)
    local _, hit, at, _, ent = GetShapeTestResult(StartExpensiveSynchronousShapeTestLosProbe(
        s.x, s.y, s.z, e.x, e.y, e.z, 2, PlayerPedId(), 7))
    if hit ~= 1 then return hingeX, true end
    if ent ~= veh then return hingeX, false end
    local l = GetOffsetFromEntityGivenWorldCoords(veh, at.x, at.y, at.z)
    if (l.x - hingeX) * sd.sign > 0.35 then return hingeX, true end
    return l.x, true
end

--- Work out, once per model, everything geometric about this part. Returns a record of:
---   hx, hy, hz   the hinge, in the model's own space
---   ex, ey, ez   the offset from the hinge to the prompt, when the panel is closed
---   mode         which end of the panel the hinge is on
---   dir          which way round the panel swings (derived from the sign of ey and the mode)
--- The prompt belongs on the free edge, not the hinge. The mode is guessed from where the hinge sits
--- (Config.VehiclePartHinges overrides it per model).
---@param c table|nil  the car as of this pass (factsOf), when the caller has it
---@return table|nil
local function partGeometry(part, veh, c)
    -- A vehicle with no handles (pointPart): its spot is client/vehicle_points.lua's.
    if part.point then
        if part.kinds and not part.kinds[VehiclePoints.kindOf(veh)] then return nil end
        return VehiclePoints.plan(veh, part.point)
    end

    local model = c and c.model or GetEntityModel(veh)
    local cache = anchorCache[part.key]

    local cached = cache[model]
    if cached ~= nil then
        if not cached then return nil end
        -- `retryAt`: a door's skin not yet measured (doorSkin).
        if not cached.retryAt or GetGameTimer() < cached.retryAt then return cached end
    end

    local bone = GetEntityBoneIndexByName(veh, part.bone)
    if not bone or bone == -1 then
        cache[model] = false
        return nil
    end

    -- The bone folded back into the model's own space (no native gives a bone's local offset).
    local bw = GetWorldPositionOfEntityBone(veh, bone)
    local bl = GetOffsetFromEntityGivenWorldCoords(veh, bw.x, bw.y, bw.z)

    local minDim, maxDim = GetModelDimensions(model)
    if not minDim or not maxDim then
        cache[model] = false
        return nil
    end

    local sd = SIDES[part.side]
    if not sd then
        print(('[whip_core:vehicles] part "%s" has an unknown side "%s"')
            :format(part.key, tostring(part.side)))
        cache[model] = false
        return nil
    end

    -- Which way the free edge lies from the hinge. The per-model override wins on every part.
    local override = (Config.VehiclePartHinges or {})[model]
    override = override and override[part.key]

    local mode = override or part.edgeDir
    if mode == 'auto' then
        local halfW = math.max(math.abs(minDim.x), math.abs(maxDim.x))
        local height = maxDim.z - minDim.z
        local frac = (height > 0.01) and ((bl.z - minDim.z) / height) or 1.0

        if halfW > 0.01 and math.abs(bl.x) > (halfW * 0.45) then
            mode = 'mirror'
        elseif frac >= (Config.VehiclePartHingeTopFrac or 0.52) then
            mode = 'down'
        else
            mode = 'up'
        end
    end

    -- The offset from the hinge to the prompt, panel closed: one axis is pinned to the face, one carries
    -- the free edge. Clearance is usually negative: the bounding box ends at the bumper or mirror.
    local clearance = tune(part, 'clearance')
    local drop  = tune(part, 'drop')
    local rise  = tune(part, 'rise') or 0.0

    local ex, ey, ez = 0.0, 0.0, rise
    local settled = true

    if sd.axis == 'y' then
        -- Front or rear panel: the face pins y.
        local faceY = ((sd.sign < 0) and minDim.y or maxDim.y) + (sd.sign * clearance)
        ey = faceY - bl.y
        if mode == 'mirror' then
            ex = -2.0 * bl.x          -- hinged down one side of the opening, edge across it
        elseif mode == 'up' then
            ez = ez + drop            -- gate stands above its hinge
        else
            ez = ez - drop            -- lid hangs below its hinge
            mode = 'down'
        end
    else
        -- Side panel (a door): the face pins x. It is the box's side, or the door's own skin (doorSkin) with no handle bone.
        local faceX = (sd.sign < 0) and minDim.x or maxDim.x
        local hb = part.anchorBone and GetEntityBoneIndexByName(veh, part.anchorBone) or -1
        if hb == -1 and part.door then
            faceX, settled = doorSkin(veh, part, sd, bl, (mode == 'fore') and drop or -drop, rise, minDim, maxDim)
        end
        faceX = faceX + (sd.sign * clearance)
        ex = faceX - bl.x
        if mode == 'fore' then
            ey = drop                 -- rear-hinged, "suicide" door
        else
            ey = -drop                -- ordinary door: hinge at the front, handle at the back
            mode = 'aft'
        end
    end

    -- Which way it swings, from where the free edge sits: a top-hung panel lifts as it opens, a
    -- bottom-hung one drops, a door swings outward.
    local dir
    if mode == 'mirror' then
        -- Swings toward the end of the car it belongs to.
        dir = sd.sign * sign(ex)
    elseif mode == 'aft' or mode == 'fore' then
        -- Swings out to its own side of the car.
        dir = sd.sign * sign(-ey)
    else
        -- A hinge on the end face leaves ey near zero (its sign is noise), so the end of the car decides.
        local eySign = (math.abs(ey) < 0.05) and sd.sign or ey
        dir = sign(eySign) * ((mode == 'down') and 1 or -1)
    end

    local g = {
        hx = bl.x, hy = bl.y, hz = bl.z,
        ex = ex, ey = ey, ez = ez,
        mode = mode, dir = dir,
        -- Which way the sign looks, as an offset from the car's own heading.
        heading = sd.heading,
        faceSign = sd.sign,
        -- Vertical-axis rotations (see rotateEdge).
        vertical = (sd.axis == 'x') or (mode == 'mirror'),
    }

    -- The authored handle bone, when the model has one: a child of the door bone, so it follows the
    -- door exactly. The derivation above is the fallback for add-on models.
    if part.anchorBone then
        local hb = GetEntityBoneIndexByName(veh, part.anchorBone)
        if hb and hb ~= -1 then
            g.handleBone = hb
            -- Kept so the live facing can be read off the pair (panelHeading).
            g.hingeBone = bone

            -- Handle-to-hinge distance, the same at any door angle.
            local hw = GetWorldPositionOfEntityBone(veh, hb)
            local dw = GetWorldPositionOfEntityBone(veh, bone)
            local ax, ay, az = hw.x - dw.x, hw.y - dw.y, hw.z - dw.z
            g.arm = math.sqrt(ax * ax + ay * ay + az * az)
        end
    end

    if not settled then g.retryAt = GetGameTimer() + 1000 end
    cache[model] = g
    return g
end

-- The prompt's world position is the offset rotated by hand, since GetEntityBoneRotation's euler order is
-- undocumented. The one approximation is how far the panel swings (Config.VehiclePartOpenAngle).

--- The free-edge offset, swung by `t` radians about this panel's hinge axis (lateral for a lid or
--- tailgate, vertical for a door or side-hung boot).
---@return number ex, number ey, number ez
local function rotateEdge(g, t)
    local c, s = math.cos(t), math.sin(t)
    if g.vertical then
        return g.ex * c - g.ey * s, g.ex * s + g.ey * c, g.ez
    end
    return g.ex, g.ey * c - g.ez * s, g.ey * s + g.ez * c
end

-- Lua 5.3 has no math.atan2; the runtimes differ.
local atan2 = math.atan

--- Which way this panel is facing now, as a world heading. Read off the hinge and handle bones, so no
--- open angle is assumed; the outward normal is that vector turned a quarter turn. Only for panels that
--- turn in yaw (a boot lid keeps the car's heading).
---@param hw vector3|nil  the handle bone's world position, when already read this frame
---@param c table|nil  the car as of this pass (factsOf)
---@return number|nil heading  nil when it cannot be derived and the caller should fall back
local function panelHeading(g, veh, hw, c)
    if not (g.handleBone and g.hingeBone) then return nil end

    hw = hw or GetWorldPositionOfEntityBone(veh, g.handleBone)
    local dw = GetWorldPositionOfEntityBone(veh, g.hingeBone)

    -- The quarter turn is about the car's up, not the world's (the car may be on its roof).
    local _, _, up = VehiclePoints.axes(veh, c)
    local dx, dy, dz = hw.x - dw.x, hw.y - dw.y, hw.z - dw.z
    -- The level part of cross(up, hinge to handle).
    local nx = (up.y * dz - up.z * dy) * g.faceSign
    local ny = (up.z * dx - up.x * dz) * g.faceSign
    local len = math.sqrt(nx * nx + ny * ny)
    -- Degenerate: a panel facing straight up or down.
    if len < 0.02 then return nil end
    nx, ny = nx / len, ny / len

    -- An entity's forward is (-sin h, cos h); invert it for the heading.
    return math.deg(atan2(-nx, ny)) % 360.0
end

--- How far open this panel is, 0..1. Zero for a torn-off panel (the prompt sits where it would be shut)
--- and for a part whose door index the model lacks (the NaN guard).
local function openRatio(part, veh, detached)
    if detached or not part.door then return 0.0 end
    local ratio = askCar(veh, DOOR_RATIO[part.door], GetVehicleDoorAngleRatio, part.door) or 0.0
    if ratio ~= ratio or ratio < 0.0 then return 0.0 end
    if ratio > 1.0 then return 1.0 end
    return ratio
end

--- Which way this part's panel faces outward now, as a world heading. A door turns in yaw, so its circle
--- turns with it (read off the bones where possible). A boot lid or bonnet pitches and a `fixed` part never
--- swings, so those keep the car's heading.
---@param hw vector3|nil  the handle bone's world position, when already read this frame (panelHeading)
---@param c table|nil  the car as of this pass (factsOf)
---@return number heading  degrees, 0-360
local function faceHeading(part, g, veh, detached, hw, c)
    local swings = g.vertical and not part.fixed
    local h = swings and panelHeading(g, veh, hw, c) or nil
    if not h then
        -- The face's outward offset from the car's heading (0 front, 180 back, 90 sides), plus an approximate
        -- swing for a yaw-turning panel on a model whose bones could not supply it, turned the way the car lies.
        local a = g.heading
        if swings then
            a = a + (Config.VehiclePartOpenAngle or 70.0) * openRatio(part, veh, detached) * g.dir
        end
        h = VehiclePoints.facing(veh, a, c)
    end
    return h % 360.0
end

--- Where this part's circle is in the world now. A door's inside (`face = 'inside'`) is its handle's point
--- moved `inset` in through the door.
---@return number|nil x, number y, number z
local partPointOutside   -- below

local function partPoint(part, veh, detached)
    local x, y, z = partPointOutside(part, veh, detached)
    if not x or part.face ~= 'inside' then return x, y, z end
    local h = math.rad(faceHeading(part, partGeometry(part, veh), veh, detached))
    local inset = tune(part, 'inset') or 0.12
    -- The outward normal is (-sin h, cos h); in is the other way.
    return x + math.sin(h) * inset, y - math.cos(h) * inset, z
end

--- A fourth answer: the handle bone's world position when it was read (for panelHeading).
--- `g`: the part's geometry, when the caller has it; `c`: the car as of this pass (factsOf).
---@return number|nil x, number y, number z, vector3|nil hw
partPointOutside = function(part, veh, detached, g, c)
    if part.point then
        local x, y, z = VehiclePoints.where(veh, part.point, c)
        return x, y, z
    end
    g = g or partGeometry(part, veh, c)
    ---@diagnostic disable-next-line: missing-return-value -- nil alone: nowhere (the rest come only with x)
    if not g then return nil end

    -- The authored handle, read live every frame. Not for a torn-off door (the bone goes with the
    -- panel): the derivation gives the fixed spot.
    if g.handleBone and not detached then
        local hw = GetWorldPositionOfEntityBone(veh, g.handleBone)

        -- Clearance nudges it off the paint along the car's own lateral axis.
        local clr = tune(part, 'clearance') or 0.0
        if clr ~= 0.0 then
            local _, right = VehiclePoints.axes(veh, c)
            local off = g.faceSign * clr
            return hw.x + right.x * off, hw.y + right.y * off, hw.z + right.z * off, hw
        end
        return hw.x, hw.y, hw.z, hw
    end

    local ex, ey, ez = g.ex, g.ey, g.ez

    -- A `fixed` part is drawn shut whatever the panel is doing.
    local ratio = part.fixed and 0.0 or openRatio(part, veh, detached)
    if ratio > 0.001 then
        ex, ey, ez = rotateEdge(g, math.rad((Config.VehiclePartOpenAngle or 70.0) * ratio * g.dir))
    end

    local fwd, right, up, pos = VehiclePoints.axes(veh, c)
    return VehiclePoints.toWorld(fwd, right, up, pos, g.hx + ex, g.hy + ey, g.hz + ez)
end

--- How much further from the body the prompt ends up once this panel is fully open, so an open panel's
--- prompt stays in reach. Measured at full open, so the range changes twice per open and shut, not per frame.
---@return number metres
local function openReach(part, veh)
    local g = partGeometry(part, veh)
    if not g then return 0.0 end

    -- With an authored handle this is the chord of its arc about the hinge, 2r*sin(a/2).
    if g.arm then
        return 2.0 * g.arm * math.sin(math.rad(Config.VehiclePartOpenAngle or 70.0) * 0.5)
    end

    local ox, oy, oz = rotateEdge(g, math.rad((Config.VehiclePartOpenAngle or 70.0) * g.dir))
    local dx, dy, dz = ox - g.ex, oy - g.ey, oz - g.ez
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Registration

--- Widen this prompt's reach while its panel is open, and put it back when it shuts. Only pushed on a change.
local function refreshRange(part, veh)
    local rec = held[part.key][veh]
    if not rec then return end

    local open = openRatio(part, veh, isDetached(part, veh)) > 0.01
    -- A `fixed` part's circle does not move, so it needs no more reach.
    local bump = (open and not part.fixed) and openReach(part, veh) or 0.0

    if rec.bump == bump then return end
    rec.bump = bump
    Interactions.setRange(rec.id, tune(part, 'range') + bump, tune(part, 'activeRange') + bump)
end

--- Do the thing, then refresh the range after a short delay (the door's angle ratio is still 0 on that
--- frame, and doors are server-authoritative); the scan is the backstop.
local function fireAndCatchUp(part, veh, act)
    act(veh)
    SetTimeout(150, function()
        if DoesEntityExist(veh) then refreshRange(part, veh) end
    end)
end

--- An option with `press`: the action at once, with the hand press alongside towards the circle's
--- point (client/interact_press.lua). The press never waits, so this runs in the callback itself.
local function pressThen(part, veh, act)
    local detached = isDetached(part, veh)
    local x, y, z = partPoint(part, veh, detached)
    fireAndCatchUp(part, veh, act)
    if x then
        local g = partGeometry(part, veh)
        local normal = nil
        if g then
            local h = math.rad(faceHeading(part, g, veh, detached))
            normal = vector3(-math.sin(h), math.cos(h), 0.0)   -- either way round: the press turns it to the player
        end
        InteractPress.play(vector3(x, y, z), { normal = normal })
    end
end

--- Bind this part's options to one vehicle, in the shape Interactions.register wants (a part's
--- functions take the vehicle; interact.lua calls them with no arguments). A part with no `options`
--- gets one built from its own label and act. Labels stay functions, read live.
---@return table options
local function bindOptions(part, veh)
    -- The part's own options, then other resources', which go after so a new resource never takes
    -- the E press unless it asks to (`first`).
    local src = part.options
    local extra = extraOptions[part.key]
    if extra then
        local merged = {}
        -- Sorted by resource name so the order is stable, whip_core's own first.
        local names = {}
        for res in pairs(extra) do names[#names + 1] = res end
        table.sort(names, function(a, b)
            if (a == CORE) ~= (b == CORE) then return a == CORE end
            return a < b
        end)

        -- The part's gate on everything contributed to it; the option's own condition still runs.
        local gate = part.extrasRequire
        local function gated(o)
            if not gate then return o end
            local own = o.can
            return {
                id = o.id, icon = o.icon, label = o.label, image = o.image, act = o.act,
                can = function(v)
                    if not gate(v) then return false end
                    if own then return own(v) end
                    return true
                end,
            }
        end

        -- An option may ask to go first (`first`, AddAction's), e.g. a pump nozzle in hand at the filler.
        for _, res in ipairs(names) do
            for _, o in ipairs(extra[res]) do
                if o.first then merged[#merged + 1] = gated(o) end
            end
        end
        for i = 1, #(src or {}) do merged[#merged + 1] = src[i] end
        for _, res in ipairs(names) do
            for _, o in ipairs(extra[res]) do
                if not o.first then merged[#merged + 1] = gated(o) end
            end
        end
        if #merged > 0 then src = merged end
    end

    if not src then
        return { {
            id    = part.key,
            label = function() return part.label(veh, isDetached(part, veh)) end,
            -- Carried through so a one-option part can show state (open or shut).
            icon  = (type(part.icon) == 'string') and part.icon
                    or (part.icon ~= nil and function() return part.icon(veh) end or nil),
            callback = function() fireAndCatchUp(part, veh, part.act) end,
        } }
    end

    local out = {}
    for i = 1, #src do
        local o = src[i]
        out[i] = {
            id        = o.id,
            -- A string passes through; anything else is bound to this car (tested for a string, since an
            -- exported function is a callable table).
            icon      = (type(o.icon) == 'string') and o.icon
                        or (o.icon ~= nil and function() return o.icon(veh) end or nil),
            label     = (type(o.label) == 'string') and o.label
                        or (o.label ~= nil and function() return o.label(veh) end or nil),
            -- Drawn above the label; same string-or-bound rule.
            image     = (type(o.image) == 'string') and o.image
                        or (o.image ~= nil and function() return o.image(veh) end or nil),
            condition = o.can and function() return o.can(veh) end or nil,
            callback  = o.press and function() pressThen(part, veh, o.act) end
                        or function() fireAndCatchUp(part, veh, o.act) end,
        }
    end
    return out
end

-- Not through a wall: a part is offered only if a ray from chest height or knee height reaches its point
-- (client/ground.lua inSight). Walls, doors and glass stop rays; vehicles and peds do not.

local SIGHT_FLAGS   = 1 | 16          -- the map (interiors included) and objects (doors); not vehicles or peds
local SIGHT_OPTIONS = 4               -- ignore no-collision only: glass blocks
local SIGHT_SLACK2  = 0.05 * 0.05     -- squared metres: a ray stopping this close to the point reached it
local SIGHT_FOR_MS  = 200             -- an answer lasts this long

local function rayReaches(fx, fy, fz, tx, ty, tz, ped)
    local ray = StartExpensiveSynchronousShapeTestLosProbe(fx, fy, fz, tx, ty, tz, SIGHT_FLAGS, ped, SIGHT_OPTIONS)
    local _, hit, at = GetShapeTestResult(ray)
    if hit ~= 1 then return true end
    local dx, dy, dz = at.x - tx, at.y - ty, at.z - tz
    return dx * dx + dy * dy + dz * dz <= SIGHT_SLACK2
end

--- [prompt id] = { untilAt, yes }
local sightCache = {}

--- Can the player see this part's point on this car? The dearest question, so it is asked last and cached.
---@return boolean
local function partInSight(id, part, veh)
    local now = GetGameTimer()
    local c = sightCache[id]
    if c and now < c.untilAt then return c.yes end
    local yes = false
    local ped = PlayerPedId()
    local x, y, z = partPoint(part, veh, isDetached(part, veh))
    if x and ped ~= 0 then
        local p = GetEntityCoords(ped)   -- the pelvis, about 1 m up
        yes = rayReaches(p.x, p.y, p.z + 0.6, x, y, z, ped) or rayReaches(p.x, p.y, p.z - 0.5, x, y, z, ped)
    end
    if c then c.untilAt, c.yes = now + SIGHT_FOR_MS, yes
    else sightCache[id] = { untilAt = now + SIGHT_FOR_MS, yes = yes } end
    return yes
end

--- Has this part anything to offer: options of its own, or a resource's? The filler has none of its own.
local function offersAnything(part)
    if part.options == nil or #part.options > 0 then return true end
    local extra = extraOptions[part.key]
    return extra ~= nil and next(extra) ~= nil
end

--- Give this vehicle a prompt for this part, if it has one and has not got it already.
local function addPrompt(part, veh)
    if held[part.key][veh] then return end
    if not Interactions then return end
    -- A bike's prompt on bikes only, a boat's on boats.
    if part.kinds and not part.kinds[VehiclePoints.kindOf(veh)] then return end
    -- Nothing to offer: no prompt. An option added or removed hands the prompts back and the scan asks again.
    if not offersAnything(part) then return end

    -- nil means the model has no such bone: not registered.
    local wx, wy, wz = partPoint(part, veh, isDetached(part, veh))
    if not wx then return end

    local id = ('veh_%s_%d'):format(part.key, veh)

    Interactions.register({
        id    = id,

        -- Seeded with the real position: interact.lua range-tests the registry position before it calls `follow`.
        x = wx, y = wy, z = wz,

        -- Every option this part offers on this car.
        options = bindOptions(part, veh),
        group   = 'vehicles',

        -- Position, not aim, as doors: you walk round to the back of a car.
        focusMode = 'near',

        -- This point's own ranges. (Config.VehicleTrunkRange is the server's authorisation gate, not this.)
        visibleRange = tune(part, 'range'),
        activeRange  = tune(part, 'activeRange'),

        -- Pinned, apart from activeRange (which refreshRange widens), so the badge does not inflate.
        sizeRange = tune(part, 'activeRange'),
        scale     = tune(part, 'scale'),

        --- Where the panel is now and which way the circle looks: the way the panel faces, or the
        --- other way for a door's inside circle.
        follow = function()
            -- The car, read once this pass for all its circles
            local c = factsOf(veh)
            if not c.exists then return nil end
            -- A vehicle with no handles: the spot nearest the player, facing out of their side.
            if part.point then
                local x, y, z, h = VehiclePoints.where(veh, part.point, c, playerAt())
                return x, y, z, h
            end
            local g = partGeometry(part, veh, c)
            if not g then return nil end
            -- Torn off matters only to a handle (its bone goes with the panel) or a panel that swings
            local det = (g.handleBone or not part.fixed) and isDetached(part, veh) or false
            local x, y, z, hw = partPointOutside(part, veh, det, g, c)
            if not x then return nil end

            local h = faceHeading(part, g, veh, det, hw, c)
            if part.face == 'inside' then
                -- In through the door along the way it faces (as partPoint's inside branch)
                local r = math.rad(h)
                local inset = tune(part, 'inset') or 0.12
                x, y = x + math.sin(r) * inset, y - math.cos(r) * inset
                h = h + 180.0
            end
            return x, y, z, h % 360.0
        end,

        --- Whether this prompt exists at all; if every option fails its own condition the prompt drops.
        condition = function()
            if not carThere(veh) then return false end
            -- Not on a moving car.
            if askCar(veh, 'speed', GetEntitySpeed) > 1.0 then return false end
            if part.onDetached == 'hide' and isDetached(part, veh) then return false end
            if part.can and not part.can(veh) then return false end
            -- Not through a wall; last, as its rays are the dearest question.
            return partInSight(id, part, veh)
        end,

        --- Used only when a part has no options of its own.
        callback = function()
            if not DoesEntityExist(veh) then return end
            if part.act then part.act(veh) end
        end,
    })

    -- The model is recorded because the game reuses handles; the scan compares it to re-register.
    held[part.key][veh] = { id = id, model = GetEntityModel(veh), bump = 0.0 }

    -- A panel already open gets the open ranges now.
    refreshRange(part, veh)
end

local function removePrompt(part, veh)
    local rec = held[part.key][veh]
    if not rec then return end
    if Interactions then Interactions.remove(rec.id) end
    sightCache[rec.id] = nil
    held[part.key][veh] = nil
    carFacts[veh] = nil   -- (read again by the car's next circle, if it has any left)
    carAsks[veh] = nil
end

--- Hand back everything for one part, or for all of them when `part` is nil.
local function clearPrompts(part)
    for _, p in ipairs(PARTS) do
        if not part or p.key == part.key then
            for veh, rec in pairs(held[p.key]) do
                if Interactions then Interactions.remove(rec.id) end
                sightCache[rec.id] = nil
                carFacts[veh] = nil
                carAsks[veh] = nil
            end
            held[p.key] = {}
        end
    end
end

-- A car part setting changed: panels are worked out again and the prompts re-registered by the scan.
local function partSettingsChanged()
    for _, p in ipairs(PARTS) do anchorCache[p.key] = {} end
    clearPrompts(nil)
end
Settings.onChange('VehiclePartPrompts', partSettingsChanged)
Settings.onChange('VehiclePartHingeTopFrac', partSettingsChanged)
Settings.onChange('VehiclePartHinges', partSettingsChanged)
Settings.onChange('VehicleFillers', partSettingsChanged)   -- the filler's spot (client/vehicle_points.lua)

-- Proximity: the scan decides which cars have a point in the grid, once a second; each part's own
-- `range` decides which draw, so a car is registered before you are close enough to see it.

CreateThread(function()
    while not PlayerLoaded do Wait(500) end
    Wait(2000)

    local seen = {}   -- reused scratch, so a per-second scan allocates nothing

    --- Was the player in a vehicle last pass?
    local wasSeated = false

    while true do
        local ped = PlayerPedId()

        -- Not while the player is in a car: every part is reached on foot and the scan walks the whole
        -- vehicle pool. Prompts are dropped once, on the way in.
        if IsPedInAnyVehicle(ped, false) then
            if not wasSeated then
                wasSeated = true
                clearPrompts(nil)
            end

            Wait(1000)
            goto continue
        end
        wasSeated = false

        local pos = GetEntityCoords(ped)
        local scan = Config.VehiclePartPromptScan or 15.0
        local scanSq = scan * scan

        for k in pairs(seen) do seen[k] = nil end

        -- Not cars on the move; a car that stops is picked up next pass.
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local c = GetEntityCoords(veh)
            local dx, dy = c.x - pos.x, c.y - pos.y
            if (dx * dx + dy * dy) <= scanSq and GetEntitySpeed(veh) <= 1.0 then
                seen[veh] = c
            end
        end

        for _, part in ipairs(PARTS) do
            local mine = held[part.key]

            if tune(part, 'enabled') == false then
                -- Turned off at runtime: let go of anything still held.
                if next(mine) then clearPrompts(part) end
            else
                for veh in pairs(seen) do
                    local rec = mine[veh]
                    if rec and rec.model ~= GetEntityModel(veh) then
                        -- Handle reused for a different vehicle.
                        removePrompt(part, veh)
                        rec = nil
                    end

                    if not rec then
                        addPrompt(part, veh)
                    else
                        -- Keep the registered position current (interact.lua range-tests it before `follow`),
                        -- only when the car has moved, turned, or lost the part.
                        local c, h = seen[veh], GetEntityHeading(veh)
                        local det = isDetached(part, veh)
                        if not rec.lx or det ~= rec.ldet or math.abs(h - rec.lh) > 1.0
                            or math.abs(c.x - rec.lx) + math.abs(c.y - rec.ly) + math.abs(c.z - rec.lz) > 0.05 then
                            local wx, wy, wz = partPoint(part, veh, det)
                            if wx then Interactions.updatePosition(rec.id, wx, wy, wz) end
                            rec.lx, rec.ly, rec.lz, rec.lh, rec.ldet = c.x, c.y, c.z, h, det
                        end

                        -- Also catches state this player did not cause.
                        refreshRange(part, veh)
                    end
                end

                -- Anything held that is no longer near (driven off, despawned, streamed out).
                local gone = nil
                for veh in pairs(mine) do
                    if not seen[veh] then
                        gone = gone or {}
                        gone[#gone + 1] = veh
                    end
                end
                if gone then
                    for i = 1, #gone do removePrompt(part, gone[i]) end
                end
            end
        end

        Wait(1000)

        ::continue::
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        clearPrompts(nil)
    end
end)

-- The satellite API. Registering twice from one resource replaces, it does not stack.

--- Do two registrations of an option say the same thing? Compared on plain values only; functions
--- are ignored.
local function sameOptionData(a, b)
    for _, t in ipairs({ { a, b }, { b, a } }) do
        for k, v in pairs(t[1]) do
            local tv = type(v)
            if (tv == 'string' or tv == 'number' or tv == 'boolean') and t[2][k] ~= v then return false end
        end
    end
    return true
end

--- Add an option to a vehicle part's interaction stack.
---@param res string      the resource the option belongs to
---@param partKey string  a key from PARTS: 'trunk', 'hood', 'door_dside_f', ...
---@param option table    { id, icon, label, can?, act }; icon, label, can and act may be functions taking the vehicle
---@return boolean ok
---@return string|nil reason
local function addPartOptionFor(res, partKey, option)
    if type(partKey) ~= 'string' or type(option) ~= 'table' then return false, 'a part key and an option table' end

    local known = false
    for _, p in ipairs(PARTS) do
        if p.key == partKey then known = true break end
    end
    if not known then
        return false, ('no vehicle part called "%s"'):format(partKey)
    end

    local byRes = extraOptions[partKey]
    if not byRes then
        byRes = {}
        extraOptions[partKey] = byRes
    end

    local list = byRes[res]
    if not list then
        list = {}
        byRes[res] = list
    end

    -- Replace by id within this resource's own list.
    local replaced, same = false, false
    for i = 1, #list do
        if list[i].id == option.id then
            same = sameOptionData(list[i], option)
            list[i] = option
            replaced = true
            break
        end
    end
    if not replaced then list[#list + 1] = option end

    -- The same option again leaves the prompts alone (onReady fires whenever any resource starts).
    if same then return true end

    -- Drop the bound prompts; the scan re-registers them with the new option.
    clearPrompts({ key = partKey })
    return true
end

--- Take one option off a part, from one resource's bucket.
---@param res string
---@param partKey string
---@param id string
---@return boolean removed
local function removePartOptionFor(res, partKey, id)
    local list = extraOptions[partKey] and extraOptions[partKey][res]
    if not list then return false end
    for i = #list, 1, -1 do
        if list[i].id == id then
            table.remove(list, i)
            if #list == 0 then extraOptions[partKey][res] = nil end
            clearPrompts({ key = partKey })
            return true
        end
    end
    return false
end

--- For client/actions.lua, which puts each resource's `at = { vehiclePart = ... }` action on a part
--- under that resource's name.
VehiclePartOptions = { add = addPartOptionFor, remove = removePartOptionFor }

--- A stopping satellite's options are dropped here (its own stop handler cannot reach whip_core's tables).
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end

    local touched = false
    for key, byRes in pairs(extraOptions) do
        if byRes[res] then
            byRes[res] = nil
            clearPrompts({ key = key })
            touched = true
        end
    end
    if touched then
        print(('[whip_core:vehicles] dropped vehicle part options belonging to %s'):format(res))
    end
end)
