-- ============================================
-- Dev Tools — /vehpoints: where an action would sit on a bike, boat, helicopter or plane
-- ============================================
--
-- For 3D prompts on vehicles without door handles. client/vehicle_points.lua
-- decides where each action's prompt goes; this draws what it has to work with and what it picked,
-- on the vehicle you look at, so a wrong pick can be seen standing next to it:
--
--   white dots      every part (bone) the model has, labelled with its name — or, for a part whose
--                   name is not on the lists below, its number (#17), grey. On a car only the useful
--                   ones are labelled (a car has well over a hundred); /vehpoints all labels the rest
--   pink            GTA's entry points (where the game stands you to get on or in)
--   grey box        the model's box, with its four sides' middles marked
--   coloured        each action's pick, and the line from it to where it lands on the skin
--
--   /vehpoints              on / off. It follows the vehicle you aim at; else the one you sit on,
--                           else the nearest within 15 m.
--   /vehpoints all          on a car too, label every part, not just the useful ones
--   /vehpoints dump [note]  save all of it, in the vehicle's own space, to whip_core/docs/probe/
--
-- whip.devtools only (the server checks the save again).

local on = false
local labelAll = false
local target = nil      -- the vehicle shown; kept until another is aimed at or it is too far

local REACH = 25.0      -- how far the aim looks for a vehicle
local KEEP = 30.0       -- how far the shown vehicle can be before it is let go
local NEAR = 15.0       -- the nearest vehicle within this, when none is aimed at or sat on

local DIM   = { 210, 210, 210 }
local GOOD  = { 140, 255, 140 }
local ENTRY = { 255, 90, 255 }
local BOXC  = { 150, 150, 150 }

local ACTION_COLOUR = {
    mount   = { 80, 220, 255 },
    board   = { 80, 220, 255 },
    fuel    = { 120, 255, 120 },
    engine  = { 255, 110, 90 },
    storage = { 255, 210, 80 },
    cargo   = { 255, 210, 80 },
    door    = { 255, 160, 60 },
}

-- ============================================
-- The parts looked for
-- ============================================
--
-- GTA has no way to give a bone's name, so names are asked for one by one, from these lists. KEY_BONES
-- are the ones an action could stand on (always labelled); OTHER_BONES the rest worth naming. GTA does
-- give how many bones a model has, and each one's place by its number, so a bone on neither list is
-- still drawn, as its number. A number that looks like a good spot is a name to find and add here.

local KEY_BONES = {
    'seat_f', 'seat_r', 'seat_dside_f', 'seat_pside_f', 'seat_dside_r', 'seat_pside_r',
    'seat_dside_r1', 'seat_pside_r1', 'seat_dside_r2', 'seat_pside_r2',
    'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r', 'door_hatch_l', 'door_hatch_r',
    'handle_dside_f', 'handle_pside_f', 'handle_dside_r', 'handle_pside_r',
    'petrolcap', 'petroltank', 'petroltank_l', 'petroltank_r',
    'engine', 'engine_l', 'engine_r', 'overheat',
    'prop_1', 'prop_2', 'prop_left', 'prop_right', 'rotor_main', 'rotor_rear', 'rotor_main_2', 'rotor_rear_2',
    'wing_l', 'wing_r', 'wing_lr', 'wing_rr', 'tail', 'rudder', 'rudder2',
    'gear_f', 'gear_rl', 'gear_rr', 'gear_lm1', 'gear_rm1',
    'boot', 'bonnet', 'steeringwheel', 'handlebars', 'hbgrip_l', 'hbgrip_r',
    'exhaust', 'static_prop', 'static_prop2', 'moving_prop', 'moving_prop2',
    'rope_attach_a', 'rope_attach_b', 'winch', 'legs', 'attach_female',
}

local OTHER_BONES = {
    'chassis', 'chassis_dummy', 'bodyshell', 'bumper_f', 'bumper_r', 'wing_lf', 'wing_rf',
    'windscreen', 'windscreen_r', 'window_lf', 'window_rf', 'window_lr', 'window_rr',
    'wheel_lf', 'wheel_rf', 'wheel_lr', 'wheel_rr', 'wheel_lm1', 'wheel_rm1',
    'forks_u', 'forks_l', 'swingarm', 'steering',
    'headlight_l', 'headlight_r', 'taillight_l', 'taillight_r', 'brakelight_l', 'brakelight_r',
    'numberplate', 'interiorlight', 'exhaust_2', 'exhaust_3', 'exhaust_4',
    'aileron_l', 'aileron_r', 'elevator_l', 'elevator_r', 'airbrake_l', 'airbrake_r', 'flap_l', 'flap_r',
    'gear_door_fl', 'gear_door_fr', 'gear_door_rl1', 'gear_door_rr1', 'gear_door_rl2', 'gear_door_rr2',
    'outriggers_l', 'outriggers_r', 'turret_1base', 'turret_1barrel', 'searchlight_base',
    'misc_a', 'misc_b', 'misc_c', 'misc_d', 'misc_e', 'misc_f', 'misc_g', 'misc_h', 'misc_i', 'misc_j',
    'extra_1', 'extra_2', 'extra_3', 'extra_4', 'extra_5', 'extra_6', 'extra_7', 'extra_8', 'extra_9', 'extra_10',
    'window_lm', 'window_rm', 'dashglow', 'spoiler', 'engineblock', 'overheat_2', 'siren1', 'siren2',
    'hub_lf', 'hub_rf', 'hub_lr', 'hub_rr', 'suspension_lf', 'suspension_rf', 'suspension_lr', 'suspension_rr',
    'transmission_f', 'transmission_r', 'neon_l', 'neon_r', 'neon_f', 'neon_b', 'bobble_head',
}

local MAX_BONES = 512   -- a model's bones, by number; no vehicle comes near it

--- The parts this vehicle has, read once per vehicle shown: { name, index, key, unnamed }. Each
--- bone once: by the first name on the lists that finds it, else by its number.
local found, foundFor, foundModel = {}, nil, nil
local function partsOf(veh)
    local model = GetEntityModel(veh)
    if foundFor == veh and foundModel == model then return found end
    found, foundFor, foundModel = {}, veh, model
    local seen = {}
    local function look(list, key)
        for _, name in ipairs(list) do
            local i = GetEntityBoneIndexByName(veh, name)
            if i ~= -1 and not seen[i] then
                seen[i] = true
                found[#found + 1] = { name = name, index = i, key = key }
            end
        end
    end
    look(KEY_BONES, true)
    look(OTHER_BONES, false)
    local count = math.min(GetEntityBoneCount(veh) or 0, MAX_BONES)
    for i = 0, count - 1 do
        if not seen[i] then found[#found + 1] = { name = '#' .. i, index = i, key = false, unnamed = true } end
    end
    return found
end

-- ============================================
-- Drawing
-- ============================================

local function text2d(y, line, c)
    c = c or DIM
    SetTextFont(4)
    SetTextScale(0.0, 0.33)
    SetTextOutline()
    SetTextColour(c[1], c[2], c[3], 235)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(line)
    EndTextCommandDisplayText(0.015, y)
end

local function text3d(p, line, c, scale)
    c = c or DIM
    SetDrawOrigin(p.x, p.y, p.z, 0)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.26)
    SetTextCentre(true)
    SetTextOutline()
    SetTextColour(c[1], c[2], c[3], 235)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(line)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function dot(p, c, size)
    size = size or 0.05
    DrawMarker(28, p.x, p.y, p.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, size, size, size,
        c[1], c[2], c[3], 220, false, false, 2, false, (nil) --[[@as string]], (nil) --[[@as string]], false)
end

local BOX_EDGES = { { 1, 2 }, { 2, 4 }, { 4, 3 }, { 3, 1 }, { 5, 6 }, { 6, 8 }, { 8, 7 }, { 7, 5 }, { 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 } }
local function drawBox(veh)
    local b = VehiclePoints.box(veh)
    if not b then return end
    local corners = {}
    for i = 0, 7 do
        local x = (i & 1) == 0 and b.mn.x or b.mx.x
        local y = (i & 2) == 0 and b.mn.y or b.mx.y
        local z = (i & 4) == 0 and b.mn.z or b.mx.z
        corners[i + 1] = GetOffsetFromEntityInWorldCoords(veh, x, y, z)
    end
    for _, e in ipairs(BOX_EDGES) do
        local a, c = corners[e[1]], corners[e[2]]
        DrawLine(a.x, a.y, a.z, c.x, c.y, c.z, BOXC[1], BOXC[2], BOXC[3], 160)
    end
    for _, side in ipairs({ 'left', 'right', 'front', 'rear' }) do
        local l = VehiclePoints.boxSide(veh, side)
        if l then
            local p = GetOffsetFromEntityInWorldCoords(veh, l.x, l.y, l.z)
            dot(p, BOXC, 0.07)
            if labelAll then text3d(p, 'box:' .. side, BOXC) end
        end
    end
end

-- ============================================
-- Which vehicle
-- ============================================

local probe = StartExpensiveSynchronousShapeTestLosProbe or StartShapeTestRay

local function aimedVehicle()
    local c = GetFinalRenderedCamCoord()
    local r = GetFinalRenderedCamRot(2)
    local p, y = math.rad(r.x), math.rad(r.z)
    local fx, fy, fz = -math.sin(y) * math.cos(p), math.cos(y) * math.cos(p), math.sin(p)
    local h = probe(c.x, c.y, c.z, c.x + fx * REACH, c.y + fy * REACH, c.z + fz * REACH, 1 + 2, PlayerPedId(), 7)
    local _, hit, _, _, ent = GetShapeTestResult(h)
    if (hit == 1 or hit == true) and ent and ent ~= 0 and DoesEntityExist(ent) and GetEntityType(ent) == 2 then
        return ent
    end
    return nil
end

--- The vehicle to show: the one aimed at; else the one already shown while it is near; else the one
--- you sit on; else the nearest.
local function pickTarget()
    local ped = PlayerPedId()
    local me = GetEntityCoords(ped)
    local aimed = aimedVehicle()
    if aimed then return aimed end
    if target and DoesEntityExist(target) and #(GetEntityCoords(target) - me) < KEEP then return target end
    local sat = GetVehiclePedIsIn(ped, false)
    if sat ~= 0 then return sat end
    local best, bestD = nil, NEAR
    for _, v in ipairs(GetGamePool('CVehicle')) do
        local d = #(GetEntityCoords(v) - me)
        if d < bestD then best, bestD = v, d end
    end
    return best
end

-- ============================================
-- The picks
-- ============================================

--- A place to try, as RULES writes it: 'windscreen', 'hbgrip_l/hbgrip_r', 'entry', 'box:rear'.
local function placeName(place)
    return type(place) == 'table' and table.concat(place, '/') or tostring(place)
end

--- Each action this kind of vehicle has: the spots its plan found (in the world) and the one a prompt
--- would use now, on the skin: { action, place?, spots = { vector3 }, pick? = { pos, raw, source, side,
--- onSkin } }. No place: the model has nowhere for it.
local function picksOf(veh, kind)
    local out = {}
    local actions = VehiclePoints.ACTIONS[kind] or {}
    -- A car's actions are vehicle_prompts.lua's; show what this file would do for it anyway, to
    -- compare with a vehicle that is not a car.
    if kind == 'car' then actions = { 'board', 'fuel', 'engine', 'storage' } end
    for _, action in ipairs(actions) do
        local row = { action = action, spots = {} }
        local plan = VehiclePoints.plan(veh, action)
        if plan then
            row.place = placeName(plan.place)
            for _, s in ipairs(plan.spots) do
                row.spots[#row.spots + 1] = GetOffsetFromEntityInWorldCoords(veh, s.at.x, s.at.y, s.at.z)
            end
            local x, y, z, _, spot, side = VehiclePoints.where(veh, action)
            if x then
                row.pick = {
                    pos = vector3(x, y, z), source = spot.source, side = side,
                    raw = GetOffsetFromEntityInWorldCoords(veh, spot.at.x, spot.at.y, spot.at.z),
                    onSkin = spot.face ~= nil or (spot.skin[side] and true or false),
                }
            end
        end
        out[#out + 1] = row
    end
    return out
end

local function frame()
    target = pickTarget()
    local veh = target
    if not veh then
        text2d(0.30, 'VEHPOINTS   no vehicle: aim at one, sit on one, or stand within 15 m of one')
        return
    end

    local model = GetEntityModel(veh)
    local kind = VehiclePoints.kindOf(veh)
    local parts = partsOf(veh)
    local entries = VehiclePoints.entries(veh)

    drawBox(veh)

    -- Anything but a car has few enough parts to label them all.
    local labelRest = labelAll or kind ~= 'car'
    for _, b in ipairs(parts) do
        local p = GetWorldPositionOfEntityBone(veh, b.index)
        dot(p, b.unnamed and BOXC or DIM, b.key and 0.05 or 0.03)
        if b.key or labelRest then text3d(p, b.name, b.unnamed and BOXC or DIM, b.key and 0.26 or 0.22) end
    end

    for _, e in ipairs(entries) do
        dot(e.pos, ENTRY, 0.09)
        DrawLine(e.pos.x, e.pos.y, e.pos.z - 0.9, e.pos.x, e.pos.y, e.pos.z + 0.3, ENTRY[1], ENTRY[2], ENTRY[3], 200)
        text3d(e.pos, 'entry ' .. e.index, ENTRY)
    end

    local picks = picksOf(veh, kind)
    for _, a in ipairs(picks) do
        local c = ACTION_COLOUR[a.action] or GOOD
        for _, p in ipairs(a.spots) do dot(p, c, 0.08) end
        local k = a.pick
        if k then
            DrawLine(k.raw.x, k.raw.y, k.raw.z, k.pos.x, k.pos.y, k.pos.z, c[1], c[2], c[3], 230)
            dot(k.pos, c, 0.14)
            text3d(vector3(k.pos.x, k.pos.y, k.pos.z + 0.16), a.action:upper(), c, 0.34)
        end
    end

    -- ---- the HUD ----
    local name = GetDisplayNameFromVehicleModel(model)
    text2d(0.30, ('VEHPOINTS   %s (%d)   class %d   kind %s   seats %d   doors %d'):format(
        tostring(name), model, GetVehicleClass(veh), kind,
        GetVehicleModelNumberOfSeats(model), GetNumberOfVehicleDoors(veh)), GOOD)
    local keys, unnamed = 0, 0
    for _, b in ipairs(parts) do
        if b.key then keys = keys + 1 end
        if b.unnamed then unnamed = unnamed + 1 end
    end
    local idx = {}
    for _, e in ipairs(entries) do idx[#idx + 1] = tostring(e.index) end
    text2d(0.325, ('parts %d: %d useful, %d named, %d by number only   entry points %d%s'):format(
        #parts, keys, #parts - keys - unnamed, unnamed, #entries, #idx > 0 and (' (' .. table.concat(idx, ', ') .. ')') or ''))
    local y = 0.35
    for _, a in ipairs(picks) do
        local c = ACTION_COLOUR[a.action] or GOOD
        local k = a.pick
        local what = k and ('%s   now %s, %s side%s'):format(a.place, k.source, k.side, k.onSkin and '' or ' (not on the skin)')
            or 'NOTHING'
        text2d(y, ('  %-8s %s'):format(a.action, what), k and c or { 255, 110, 110 })
        y = y + 0.022
    end
    text2d(y + 0.008, 'aim at another vehicle to switch   /vehpoints all   /vehpoints dump [note]')
end

-- ============================================
-- The dump
-- ============================================

local function r3(n) return math.floor(n * 1000 + 0.5) / 1000 end

--- A world point in the vehicle's own space: { right, forward, up }, to the millimetre.
local function loc(veh, p)
    local l = GetOffsetFromEntityGivenWorldCoords(veh, p.x, p.y, p.z)
    return { r3(l.x), r3(l.y), r3(l.z) }
end

local function isTrue(v) return v == 1 or v == true end

local function dump(note)
    local veh = pickTarget()
    if not veh then
        print('[vehpoints] no vehicle to dump: aim at one, sit on one, or stand within 15 m of one')
        return
    end
    local model = GetEntityModel(veh)
    local kind = VehiclePoints.kindOf(veh)
    local name = GetDisplayNameFromVehicleModel(model)
    local report = {
        tool = 'vehpoints', note = note, model = model, name = name,
        class = GetVehicleClass(veh), kind = kind,
        seats = GetVehicleModelNumberOfSeats(model),
        passengers = GetVehicleMaxNumberOfPassengers(veh),
        doorCount = GetNumberOfVehicleDoors(veh),
        boneCount = GetEntityBoneCount(veh),
        bones = {}, entries = {}, doors = {}, picks = {},
        player = loc(veh, GetEntityCoords(PlayerPedId())),
    }
    local b = VehiclePoints.box(veh)
    if b then report.box = { min = { r3(b.mn.x), r3(b.mn.y), r3(b.mn.z) }, max = { r3(b.mx.x), r3(b.mx.y), r3(b.mx.z) } } end
    for _, p in ipairs(partsOf(veh)) do
        report.bones[p.name] = { index = p.index, at = loc(veh, GetWorldPositionOfEntityBone(veh, p.index)) }
    end
    for _, e in ipairs(VehiclePoints.entries(veh)) do
        report.entries[#report.entries + 1] = { index = e.index, at = loc(veh, e.pos) }
    end
    for i = 0, 7 do
        report.doors[#report.doors + 1] = { index = i, valid = isTrue(GetIsDoorValid(veh, i)), open = r3(GetVehicleDoorAngleRatio(veh, i)) }
    end
    for _, a in ipairs(picksOf(veh, kind)) do
        local spots = {}
        for _, p in ipairs(a.spots) do spots[#spots + 1] = loc(veh, p) end
        local k = a.pick
        report.picks[a.action] = {
            place = a.place or false, spots = spots,
            now = k and { source = k.source, side = k.side, at = loc(veh, k.raw), skin = loc(veh, k.pos), onSkin = k.onSkin } or false,
        }
    end
    local label = ('vehpoints_%s'):format(tostring(name):lower())
    TriggerServerEvent('whip_core:server:propertyProbeSave', label:sub(1, 48), json.encode(report))
    print(('[vehpoints] sending %s (%s) to the server...'):format(tostring(name), kind))
end

RegisterCommand('vehpoints', function(_, args)
    CreateThread(function()
        local sub = tostring(args[1] or ''):lower()
        if sub == 'all' then
            labelAll = not labelAll
            print('[vehpoints] every part labelled: ' .. (labelAll and 'yes' or 'no'))
            return
        end
        if not on and not Callback('whip_core:devtools:checkAccess') then return end
        if sub == 'dump' then
            dump(table.concat(args, ' ', 2))
            return
        end
        on = not on
        print('[vehpoints] ' .. (on and 'on' or 'off'))
        if not on then target, foundFor = nil, nil end
        -- Every frame while it is on, and only then: it draws.
        while on do
            frame()
            Wait(0)
        end
    end)
end, false)
