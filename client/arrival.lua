-- ============================================
-- THE ARRIVAL — client/arrival.lua
-- ============================================
--
-- What the player sees as the picture comes back after picking a character (Config.ArrivalScenes):
-- one of GTA's own character-switch scenes, played where they are — the game's animation and the
-- game's camera move for it, as story mode plays them on a swap — then they have the controls, and the
-- camera comes back as the game gives it back (at the end of Arrival.play).
--
-- WHERE THEY ARRIVE (Arrival.place, behind the black), and the list a scene is picked from:
--   on foot          where they stood                                      onFoot
--   in a seat        the car they left in (the server's Vehicles.wakeSeatFor), in the seat they had
--                                                                          inVehicle
--   by a motorbike   the motorbike they left on, stood back up             onBike
--   by their car     on foot, with a car of theirs near (Vehicles.nearCarFor)   nearCar
--   beside it        the car they left in is locked (as they left it, or since), or their seat is taken:
--                    on foot by a side a ray from the cabin reaches (never through a wall), never in it
--                                                                          nearCar
--
-- PLACED WHERE THEY ARE, NOT WHERE THE SCENE WAS SHOT. A switch scene is authored around a point of
-- its own (a bench, a car door), and the character starts some way off it. The scene's origin is
-- worked back from where the clip starts (GetAnimInitialOffsetPosition), so its first frame has the
-- player exactly where they stand, facing the way they face. A scene made with a vehicle in it
-- (`vehicleClip`) is lined up with the real one instead: the vehicle's clip starts where it stands, the
-- player is put where the scene has them. The vehicle itself stays out of the scene (in one it is moved
-- by its clip with no physics, and its wheels hang at full travel: Josh, 29 Oct); a door opens when the
-- player's hand reaches its handle instead (see "Doors"). `getsIn`: it ends with them in the seat, and the
-- doors they opened shut. The camera move plays from
-- the same origin, so it frames them.
--
-- `from` (0-1): the scene starts that far through (the story's opening is not wanted).
--
-- SEEN BY EVERYONE. Standing, it is a networked synchronised scene, so the people nearby see it too.
-- Seated, the clip is a task on the seated ped (a scene would take them out of the seat), which
-- replicates as well.
--
-- WITH ITS PROP: what the story put in the character's hand (a cigar, a phone, a bottle), from the scene's
-- line or the game's own table (client/arrival_list.lua). See "The scene's prop" below.
--
-- ROOM (Josh, 1 Nov: arriving puts you where you were, or very near). A scene plays only where it fits: its walk,
-- body-wide, tested before it plays (roomFor; one lined up with a car too, the car itself not counting as a wall),
-- and a scene that walks into something anyway as it plays is stopped and they are put back where they were (the
-- safety net in Arrival.play). None fitting, the picture just comes back where they were put. Inside a building
-- only the lines marked `indoors` play. While one plays, everything that is not the picture is put
-- away (CleanScreen), the controls are held and nothing can hurt them. It always ends: a scene that
-- never reports its end is let go after its own length and a margin.
--
-- FEET ON THE FLOOR (Josh, 1 Nov: "my character's feet are sometimes through the floor"). The scene's origin is
-- worked out from where they stand, or from the car it is lined up with, and neither says where the floor is: a car
-- that sits lower than the story's, or a spawn a little low, put the feet under it. Before a standing scene plays it
-- is posed on its first frame for a moment, behind the black (feetOnFloor), the feet are measured against the floor
-- under them, and the scene is raised or lowered by the difference. Its walk is only picked where the floor stays
-- within FLOOR_MAX of where it starts (the clip walks on the flat; past that the feet sink or float).

Arrival = {}

local SEAT_WAIT_MS   = 5000   -- for the car to stream in around the spawn
local START_WAIT_MS  = 500    -- for a networked scene's local copy to exist
local END_MARGIN_MS  = 3000   -- past a scene's own length, the longest it may run
local HAND_BACK_AT   = 0.99   -- the phase the camera is handed back at: the scene's last frame, still held
local PATH_STEPS     = 12     -- points along the clip's walk tested for room
local FLOOR_MAX      = 0.15   -- m the floor may rise or fall under the walk (the clip walks on the flat: feet on it)
local FOOT_BONES     = { 14201, 52301 }     -- SKEL_L_Foot, SKEL_R_Foot
local FOOT_REST      = 0.1    -- m a foot bone sits over the floor standing, when it cannot be measured on them
local FOOT_FIX_MIN   = 0.03   -- m: feet closer to the floor than this are left as they are
local FOOT_FIX_MAX   = 0.5    -- m: further off than this is not the feet (a table over them, a measure gone wrong)
local BODY_HEIGHTS   = { 0.45, 1.0, 1.5 }   -- m above the floor: knees, waist, shoulders
local BODY_HALF      = 0.22   -- m either side of the walk's line: the shoulders
local BODY_FLAGS     = 1 + 2 + 16           -- the map, vehicles, objects
local MOTORBIKE      = 8      -- the vehicle class
local ROOF_M         = 5.0    -- a roof this close overhead is indoors

-- Synced-scene flags: don't interrupt (4), hide the weapon (1024), stop if they die (2048). Not
-- physics: the path is tested before, and with physics a kerb can stop the walk half way.
local SCENE_FLAGS = 4 + 1024 + 2048

-- Bumped by every logout: a scene (or a wait for the map) from before one stops where it is. See "Logging out".
local outGen = 0
RegisterNetEvent('whip_core:client:playerLogout', function() outGen = outGen + 1 end)

--- How many logouts so far. The load (client/player.lua) reads it as it starts and hands it to Arrival.run / fromMap:
--- a logout during the load's own waits, before the scene is prepared, then stops it too.
---@return integer
function Arrival.generation() return outGen end

-- Vehicle classes with no car seat to sleep in: the player is put back on the seat with no scene.
local NOT_CAR_SEATS = { [8] = true, [13] = true, [14] = true, [15] = true, [16] = true, [21] = true }

-- Which list each place picks from.
local POOL = { foot = 'onFoot', seat = 'inVehicle', bike = 'onBike', near = 'nearCar' }

local function shuffled(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = v end
    for i = #out, 2, -1 do
        local j = math.random(i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

local function startPhase(s)
    return math.max(0.0, math.min(0.95, tonumber(s.from) or 0.0)) + 0.0
end

--- Where a line ends it early (`to`), or nil: to its last frame.
local function endPhase(s, from)
    local to = tonumber(s.to)
    if not to then return nil end
    return math.max(from + 0.02, math.min(HAND_BACK_AT, to)) + 0.0
end

--- The scene's origin and turn that put `clip` at `at`, facing `heading`, at `phase`.
local function originFor(s, clip, at, heading, phase, rx, ry)
    local r0 = GetAnimInitialOffsetRotation(s.dict, clip, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, phase, 2)
    local rot = vector3(rx or 0.0, ry or 0.0, (heading - r0.z) % 360.0)
    local p0 = GetAnimInitialOffsetPosition(s.dict, clip, 0.0, 0.0, 0.0, rot.x, rot.y, rot.z, phase, 2)
    return vector3(at.x - p0.x, at.y - p0.y, at.z - p0.z), rot
end

--- Where the clip has the player at `phase` (0-1), for a scene at origin/rot.
local function pointAt(s, origin, rot, phase)
    return GetAnimInitialOffsetPosition(s.dict, s.clip, origin.x, origin.y, origin.z, rot.x, rot.y, rot.z, phase + 0.0, 2)
end

local function floorUnder(p)
    local found, z = GetGroundZFor_3dCoord(p.x, p.y, p.z + 1.0, false)
    return found and z or nil
end

--- Does a body moving from `a` to `b` (floors `fa`, `fb` under them) go through anything? Rays at knee, waist and
--- shoulder height, down the middle and at each shoulder. `ignore`: the one entity that does not count. `flags`: what
--- counts (default BODY_FLAGS).
local function bodyBlocked(a, b, fa, fb, ignore, flags)
    local dx, dy = b.x - a.x, b.y - a.y
    local len = math.sqrt(dx * dx + dy * dy)
    -- The shoulders lie across the way they move; standing still, across the x axis (any way will do).
    local sx, sy = 0.0, BODY_HALF
    if len > 0.01 then sx, sy = -dy / len * BODY_HALF, dx / len * BODY_HALF end
    for _, h in ipairs(BODY_HEIGHTS) do
        for side = -1, 1 do
            local ox, oy = sx * side, sy * side
            local probe = StartExpensiveSynchronousShapeTestLosProbe(a.x + ox, a.y + oy, fa + h, b.x + ox, b.y + oy, fb + h,
                flags or BODY_FLAGS, ignore, 7)
            local _, hit, _, _, entity = GetShapeTestResult(probe)
            if hit == 1 or hit == true then return true, entity end
        end
    end
    return false
end

--- What a ray hit, in words for F8: the map, or a vehicle / ped / object and its model.
local function hitWords(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return 'the map' end
    local kind = ({ [1] = 'a ped', [2] = 'a vehicle', [3] = 'an object' })[GetEntityType(entity)] or 'something'
    return ('%s (model %d)'):format(kind, GetEntityModel(entity))
end

--- Is there room here for the scene (from `from` to `to`)? Josh's rule (1 Nov): an arrival scene plays only where it
--- fits; one that walks a few steps needs those steps clear, one that is a mere step needs only that.
--- The body, not a line (bodyBlocked), between points PATH_STEPS along the clip, the floor under each one within
--- FLOOR_MAX of the floor where it starts (no slope or step the flat clip would sink into, no ledge, no climbing a wall). `ignore`: the car a scene is lined up with (they sit on its
--- bonnet, get into it), else the player. `before`: where they stand now, for a scene that starts somewhere else (one
--- lined up with a car): the way from there to its start must be clear too. GetGroundZFor_3dCoord does not count a
--- vehicle as floor, so sitting on a bonnet or in a seat is not a ledge.
local function roomFor(s, origin, rot, from, to, ignore, before)
    local prev = pointAt(s, origin, rot, from)
    local floor0 = floorUnder(prev)
    if not floor0 then return false end
    if before then
        local fb = floorUnder(before)
        if not fb or bodyBlocked(before, prev, fb, floor0, ignore) then return false end
    end
    local prevFloor = floor0
    for i = 1, PATH_STEPS do
        local p = pointAt(s, origin, rot, from + (to - from) * i / PATH_STEPS)
        local floor = floorUnder(p)
        if not floor or math.abs(floor - floor0) > FLOOR_MAX then return false end
        if bodyBlocked(prev, p, prevFloor, floor, ignore) then return false end
        prev, prevFloor = p, floor
    end
    return true
end

--- Inside a building: a game interior, a property they stand in, or a roof within ROOF_M overhead (a
--- property's shell is a roof like any other). Only the scenes marked `indoors` play there: little
--- walking, a camera move that fits a room (Josh's list).
local function indoors(ped)
    if GetInteriorFromEntity(ped) ~= 0 then return true end
    if GetCurrentProperty and GetCurrentProperty() then return true end
    local c = GetEntityCoords(ped)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(c.x, c.y, c.z + 0.5, c.x, c.y, c.z + ROOF_M, 1 + 16, ped, 7)
    local _, hit = GetShapeTestResult(probe)
    return hit == 1 or hit == true
end

--- A scene's animation, camera and vehicle clip are all in the game (a name copied wrong is skipped).
local function loaded(s)
    if type(s) ~= 'table' or type(s.dict) ~= 'string' or type(s.clip) ~= 'string' then return false end
    if not LoadAnimDict(s.dict, 3000) then return false end
    return GetAnimDuration(s.dict, s.clip) > 0
        and (not s.cam or GetAnimDuration(s.dict, s.cam) > 0)
        and (not s.vehicleClip or GetAnimDuration(s.dict, s.vehicleClip) > 0)
end

--- The seat they had in `veh`, while it is free (never another: the driver's seat is not handed to a passenger).
local function ownSeat(veh, want)
    local last = GetVehicleModelNumberOfSeats(GetEntityModel(veh)) - 2
    if want and want >= -1 and want <= last and IsVehicleSeatFree(veh, want) then return want end
    return nil
end

--- On foot beside `veh`, facing it: where a locked car's wake-up puts them. WALLS ARE THE CLIENT'S
--- QUESTION: a ray from inside the cabin must reach the spot (so a car parked against a building never
--- puts them through its wall), with ground under it near the car's own. The driver's side, the
--- passenger's, behind, in front, then its roof; none clear: Config.DefaultSpawn. false: no scene by the car.
local function besideCar(veh)
    local ped = PlayerPedId()
    local min, max = GetModelDimensions(GetEntityModel(veh))
    local cabin = GetOffsetFromEntityInWorldCoords(veh, 0.0, 0.0, 0.5)
    local floor = GetEntityCoords(veh).z + min.z
    local spots = {
        { min.x - 0.7, 0.3 }, { max.x + 0.7, 0.3 }, { 0.0, min.y - 0.9 }, { 0.0, max.y + 0.9 },
    }
    for _, s in ipairs(spots) do
        local at = GetOffsetFromEntityInWorldCoords(veh, s[1], s[2], 0.5)
        local probe = StartExpensiveSynchronousShapeTestLosProbe(cabin.x, cabin.y, cabin.z, at.x, at.y, at.z, 1 + 2 + 16, veh, 7)
        local _, hit = GetShapeTestResult(probe)
        if not (hit == 1 or hit == true) then
            local found, z = GetGroundZFor_3dCoord(at.x, at.y, at.z + 0.5, false)
            if found and math.abs(z - floor) <= 1.5 then
                SetEntityCoordsNoOffset(ped, at.x, at.y, z, false, false, false)
                SetEntityHeading(ped, GetHeadingFromVector_2d(cabin.x - at.x, cabin.y - at.y))
                return true
            end
        end
    end
    local roof = GetOffsetFromEntityInWorldCoords(veh, 0.0, 0.0, max.z + 1.0)
    local probe = StartExpensiveSynchronousShapeTestLosProbe(cabin.x, cabin.y, cabin.z, roof.x, roof.y, roof.z, 1 + 16, veh, 7)
    local _, hit = GetShapeTestResult(probe)
    if not (hit == 1 or hit == true) then
        SetEntityCoordsNoOffset(ped, roof.x, roof.y, roof.z - 0.9, false, false, false)
        return false
    end
    local d = Config.DefaultSpawn
    SetEntityCoordsNoOffset(ped, d.x, d.y, d.z, false, false, false)
    SetEntityHeading(ped, d.w)
    return false
end

--- A vehicle the server named by network id, once it has streamed in. Yields.
local function vehicleOf(netId)
    if not netId then return nil end
    local deadline = GetGameTimer() + SEAT_WAIT_MS
    while GetGameTimer() < deadline do
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local veh = NetworkGetEntityFromNetworkId(netId)
            if veh ~= 0 and DoesEntityExist(veh) and IsEntityAVehicle(veh) then return veh end
        end
        Wait(50)
    end
    return nil
end

local function seatIn(veh, seat)
    local ped = PlayerPedId()
    SetPedIntoVehicle(ped, veh, seat)
    local by = GetGameTimer() + 1000
    while GetVehiclePedIsIn(ped, false) ~= veh and GetGameTimer() < by do Wait(0) end
    return GetVehiclePedIsIn(ped, false) == veh
end

local function hasPool(name)
    local list = (Config.ArrivalScenes or {})[name]
    return type(list) == 'table' and #list > 0
end

--- Where this load arrives: in the seat of the car they left in, by the motorbike they left on, beside a
--- locked car they left in, or by a car of theirs near where they stood (data.wakeIn / data.nearCar from
--- the server). Behind the black, after SpawnCharacterAt has put them there. Yields.
---@param data table  the load's player sheet
---@return table|nil  { veh, how = 'seat'|'bike'|'near', seat?, outside? }; nil: on foot where they stand
function Arrival.place(data)
    if type(data) ~= 'table' or data.isDead then return nil end
    local wake = data.wakeIn
    local veh = type(wake) == 'table' and vehicleOf(wake.netId) or nil
    if veh then
        -- A motorbike: stood back up, and they arrive beside it rather than on it.
        if GetVehicleClass(veh) == MOTORBIKE and hasPool('onBike') then return { veh = veh, how = 'bike' } end
        local seat = not wake.outside and ownSeat(veh, tonumber(wake.seat)) or nil
        if seat and seatIn(veh, seat) then return { veh = veh, how = 'seat', seat = seat } end
        -- Locked, or their seat taken: on foot beside it (never a scene that gets them in)
        if not besideCar(veh) then return nil end
        if hasPool('nearCar') and not NOT_CAR_SEATS[GetVehicleClass(veh)] then
            return { veh = veh, how = 'near', outside = true }
        end
        return nil
    end
    local near = type(data.nearCar) == 'table' and hasPool('nearCar') and vehicleOf(data.nearCar.netId) or nil
    if near and not NOT_CAR_SEATS[GetVehicleClass(near)] then return { veh = near, how = 'near' } end
    return nil
end

--- A Config.ArrivalScenes line with no prop of its own takes the game's, from client/arrival_list.lua: a
--- scene made with a bottle in the hand has the bottle.
local listed = nil
local function withListProp(s)
    if type(s) ~= 'table' or s.prop ~= nil or type(s.dict) ~= 'string' or type(s.clip) ~= 'string' then return s end
    if not listed then
        listed = {}
        for _, e in ipairs(ArrivalSceneList or {}) do listed[e.dict .. '/' .. e.clip] = e end
    end
    local e = listed[s.dict .. '/' .. s.clip]
    if not (e and e.prop) then return s end
    local copy = {}
    for k, v in pairs(s) do copy[k] = v end
    copy.prop = e.prop
    return copy
end

--- A scene line as the login plays it: the game's prop in the hand when it has none of its own. The settings page's
--- Watch plays a line as edited there, saved or not (tools/panel_sections/config.lua).
function Arrival.line(s) return withListProp(s) end

--- Line a scene up for this place. nil: it does not fit here. Yields (control of a vehicle).
local function placeScene(s, ped, place, testPath)
    local from = startPhase(s)
    local to = endPhase(s, from)
    local veh = place and place.veh
    if s.vehicleClip then
        if not veh then return nil end
        -- Outside a locked car (or one whose seat is taken): never a scene that ends with them in it
        if s.getsIn and place.outside then return nil end
        -- Stood up first (a motorbike on its side), so the scene lines up with it upright.
        if NOT_CAR_SEATS[GetVehicleClass(veh)] and Vehicles.takeControl(veh, { attempts = 2 }) then
            SetVehicleOnGroundProperly(veh)
            Wait(0)
        end
        local vr = GetEntityRotation(veh, 2)
        local origin, rot = originFor(s, s.vehicleClip, GetEntityCoords(veh), GetEntityHeading(veh), from, vr.x, vr.y)
        -- The scene puts them where IT has them round the car, not where besideCar stood them: the way there and its
        -- walk need room, as one on foot does (a car parked against a wall walked them into it, 1 Nov).
        if testPath and not roomFor(s, origin, rot, from, to or 1.0, veh, GetEntityCoords(ped)) then return nil end
        -- fromSeat: they logged out in this car (the inVehicle list), and the scene starts with them at or in it.
        return { def = s, origin = origin, rot = rot, from = from, to = to, lineup = veh, seat = place.seat,
                 fromSeat = place.how == 'seat' }
    end
    if place and place.how == 'seat' then
        if NOT_CAR_SEATS[GetVehicleClass(veh)] then return nil end
        local vr = GetEntityRotation(veh, 2)
        local origin, rot = originFor(s, s.clip, GetEntityCoords(ped), GetEntityHeading(veh), from, vr.x, vr.y)
        return { def = s, origin = origin, rot = rot, from = from, to = to, veh = veh }
    end
    if place then return nil end   -- by a bike or a car: only scenes lined up with it
    local origin, rot = originFor(s, s.clip, GetEntityCoords(ped), GetEntityHeading(ped), from)
    if testPath and not roomFor(s, origin, rot, from, to or 1.0, ped) then return nil end
    return { def = s, origin = origin, rot = rot, from = from, to = to }
end

--- Pick the scene for where the player is now, and place it. Behind the black. Yields (loads clips).
---@param place table|nil  from Arrival.place
---@param only table|nil  this scene and no other (Watch on the settings page: played wherever it is asked, walls or not)
---@param since integer|nil  Arrival.generation() when the load began (else now): logged out since, no scene
---@return table|nil  for Arrival.play; nil: no scene fits, the picture just comes back
function Arrival.prepare(place, only, since)
    local cfg = Config.ArrivalScenes
    if not cfg or (cfg.enabled == false and not only) then return nil end
    local gen = since or outGen   -- a logout while this yields stops the scene before it starts (see "Logging out")
    if gen ~= outGen then return nil end
    local ped = PlayerPedId()
    if IsEntityDead(ped) or IsPedSwimming(ped) or IsEntityInWater(ped) then return nil end
    if not place and IsPedInAnyVehicle(ped, false) then return nil end

    local pool = only and { only } or shuffled(cfg[POOL[place and place.how or 'foot']])
    -- On foot inside a building: only the scenes that fit one.
    if not only and not place and indoors(ped) then
        local fits = {}
        for _, s in ipairs(pool) do if s.indoors then fits[#fits + 1] = s end end
        pool = fits
    end
    for _, s in ipairs(pool) do
        s = withListProp(s)
        if loaded(s) then
            local run = placeScene(s, ped, place, not only)
            if run then
                run.outGen = gen
                return run
            end
        end
    end
    return nil
end

-- ---- The scene's prop ----
--
-- What the story scripts put in the character's hand (a cigar, a phone, a bottle), as the scene's
-- `prop` = { model, how, clip?, bone?, pos?, rot?, at? } (client/arrival_list.lua has the game's own):
--   how = 'clip'  the prop has its own clip in the scene and moves with it (a binbag tossed, a cup)
--         'drop'  held in `bone` (28422 right hand, 60309 left), let go at phase `at` (it falls)
--         'hide'  held the same, gone at `at` (a phone put away)
--         'set'   a piece of the story's set (a lamp, a door): not made here
-- Networked, so the people watching see it too. Gone when the scene ends.

local function makeProp(p)
    if type(p) ~= 'table' or type(p.model) ~= 'string' or p.how == 'set' then return nil end
    local weapon = p.model:match('^weapon:(.+)$')
    local hash = weapon and GetWeapontypeModel(GetHashKey(weapon)) or GetHashKey(p.model)
    if not LoadModel(hash, 3000) then return nil end
    local c = GetEntityCoords(PlayerPedId())
    local obj = CreateObject(hash, c.x, c.y, c.z - 2.0, true, true, false)
    SetModelAsNoLongerNeeded(hash)
    return obj ~= 0 and obj or nil
end

local function holdProp(obj, p, ped)
    local pos, rot = p.pos or { 0.0, 0.0, 0.0 }, p.rot or { 0.0, 0.0, 0.0 }
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, tonumber(p.bone) or 28422),
        pos[1] + 0.0, pos[2] + 0.0, pos[3] + 0.0, rot[1] + 0.0, rot[2] + 0.0, rot[3] + 0.0,
        true, true, false, true, 1, true)
end

--- At phase `at`: dropped or put away.
local function letGoOfProp(run, phase)
    local p, obj = run.def.prop, run.prop
    if not obj or run.propGone or not p or not p.at or phase < p.at then return end
    run.propGone = true
    if p.how == 'drop' then
        DetachEntity(obj, true, true)
    else
        DeleteObject(obj)
        run.prop = nil
    end
end

-- ---- Doors, for a scene lined up with a car ----
--
-- The car is not in the scene, so its clip cannot swing a door. A door opens as the player's hand reaches
-- its handle (the model's own handle bones, so any car), and the doors it opened shut at the scene's end
-- (once they are in, for getsIn). Only with control of the car: a door is the owner's to move.

local DOORS = { { 0, 'handle_dside_f' }, { 1, 'handle_pside_f' }, { 2, 'handle_dside_r' }, { 3, 'handle_pside_r' } }
local HANDS = { 57005, 18905 }   -- SKEL_R_Hand, SKEL_L_Hand
local REACH = 0.45               -- m from the handle that counts as a hand on it

local function handlesOf(veh)
    local out = {}
    for _, d in ipairs(DOORS) do
        local bone = GetEntityBoneIndexByName(veh, d[2])
        if bone ~= -1 then out[#out + 1] = { door = d[1], bone = bone } end
    end
    return out
end

local function openReached(run, ped)
    for _, h in ipairs(run.doors) do
        if not h.open then
            local handle = GetWorldPositionOfEntityBone(run.lineup, h.bone)
            for _, hand in ipairs(HANDS) do
                if #(GetPedBoneCoords(ped, hand, 0.0, 0.0, 0.0) - handle) < REACH then
                    SetVehicleDoorOpen(run.lineup, h.door, false, false)
                    h.open = true
                    break
                end
            end
        end
    end
end

local function shutOpened(run)
    for _, h in ipairs(run.doors or {}) do
        if h.open then SetVehicleDoorShut(run.lineup, h.door, false) end
    end
end

--- How far through it is (0-1), or nil once it has stopped.
local function phaseOf(run, ped)
    local s = run.def
    if run.veh then
        if not IsEntityPlayingAnim(ped, s.dict, s.clip, 3) then return nil end
        return GetEntityAnimCurrentTime(ped, s.dict, s.clip)
    end
    if not run.localScene or not IsSynchronizedSceneRunning(run.localScene) then return nil end
    return GetSynchronizedScenePhase(run.localScene)
end

--- How high the lower foot bone is over the floor under it, now (nil: no floor found under either). The floor is
--- looked for from just over the foot, so a table or a shelf above it is not taken for it.
local function footHeight(ped)
    local best = nil
    for _, bone in ipairs(FOOT_BONES) do
        local f = GetPedBoneCoords(ped, bone, 0.0, 0.0, 0.0)
        local found, z = GetGroundZFor_3dCoord(f.x, f.y, f.z + FOOT_FIX_MAX + 0.1, false)
        if found and (not best or f.z - z < best) then best = f.z - z end
    end
    return best
end

--- FEET ON THE FLOOR (see the header): the standing scene posed on its first frame for a moment (a local scene, not
--- seen: behind the black or the map), its feet measured, and run.origin raised or lowered so they stand as `rest`
--- (the foot height measured on them standing before it, or FOOT_REST). Yields two frames.
local function feetOnFloor(run, ped, rest)
    local s, o, r = run.def, run.origin, run.rot
    local scene = CreateSynchronizedScene(o.x, o.y, o.z, r.x, r.y, r.z, 2)
    TaskSynchronizedScene(ped, scene, s.dict, s.clip, 1000.0, -1000.0, SCENE_FLAGS, 0, 1000.0, 0)
    SetSynchronizedScenePhase(scene, run.from or 0.0)
    SetSynchronizedSceneRate(scene, 0.0)
    Wait(0); Wait(0)
    local h = IsSynchronizedSceneRunning(scene) and footHeight(ped) or nil
    ClearPedTasksImmediately(ped)
    if not h then return end
    local d = rest - h
    if math.abs(d) < FOOT_FIX_MIN or math.abs(d) > FOOT_FIX_MAX then return end
    run.origin = vector3(o.x, o.y, o.z + d)
    print(('[whip_core:arrival] %s/%s: feet put on the floor (%s %.2f m)'):format(s.dict, s.clip, d > 0 and 'up' or 'down', math.abs(d)))
end

--- Hold a playing scene on the frame it is on, its camera with it, or let it go (Arrival.fromMap: the map lines up
--- with that camera first). A synced scene by its rate; a seated clip and a camera on its own clock by pinning them
--- every frame (pinHeld).
local function holdScene(run, on)
    run.held = on
    if run.localScene then SetSynchronizedSceneRate(run.localScene, on and 0.0 or 1.0) end
    -- A seated clip's speed stays where pinHeld left it: back to normal, or the camera plays on and they never move
    -- (Josh, 31 Oct: every arrival in a car).
    if not on and run.veh then
        local s = run.def
        SetEntityAnimSpeed(PlayerPedId(), s.dict, s.clip, 1.0)
    end
end

local function pinHeld(run, ped)
    if not run.held then return end
    local s, from = run.def, run.from or 0.0
    if run.veh then
        SetEntityAnimCurrentTime(ped, s.dict, s.clip, from)
        SetEntityAnimSpeed(ped, s.dict, s.clip, 0.0)
        if run.cam then SetCamAnimCurrentPhase(run.cam, from) end
    elseif not run.localScene and run.cam then
        SetCamAnimCurrentPhase(run.cam, from)
    end
end

-- ---- Logging out in the middle of one ----
--
-- (Josh, 1 Nov: logged out while a scene with a prop played, and still had the prop in their hand when they came
-- back.) The scene went on into the character screen, and its prop was only deleted at the scene's own end, up to
-- half a minute later. Now a logout moves outGen on, and a scene from before it stops at its next frame (gone): the
-- networked scene stopped, the prop deleted, the camera and the holds let go, and none of its ending (the camera's
-- catch-up, a seat, putting them back, lifting the curtain) is done into the character screen.

--- A prop the scene made, gone: off the hand first, then deleted.
local function deleteProp(obj)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return end
    if IsEntityAttached(obj) then DetachEntity(obj, false, false) end
    SetEntityAsMissionEntity(obj, true, true)
    DeleteObject(obj)
    if DoesEntityExist(obj) then DeleteEntity(obj) end
end

--- Everything a scene holds, let go of now, where it is, with no ending: a logout, or anything that throws.
local function stopNow(run)
    run.stopped = true
    local ped = PlayerPedId()
    if run.netScene then NetworkStopSynchronisedScene(run.netScene); run.netScene = nil end
    if run.def and IsEntityPlayingAnim(ped, run.def.dict, run.def.clip, 3) then
        StopAnimTask(ped, run.def.dict, run.def.clip, 2.0)
    end
    deleteProp(run.prop)
    run.prop = nil
    if run.cam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(run.cam, false)
        run.cam = nil
    end
    if run.doors and run.lineup and DoesEntityExist(run.lineup) then shutOpened(run) end
    CleanScreen.release('arrival')
    ControlBlocks.release('arrival')
    PedHold.release('arrival')
end

--- Logged out since this scene was prepared? Then it is stopped (stopNow) and the caller returns at once.
local function gone(run)
    if run.outGen == outGen then return false end
    if not run.stopped then
        stopNow(run)
        print('[whip_core:arrival] logged out during the arrival scene: stopped, and its prop deleted')
    end
    return true
end

--- Play a prepared scene, lifting the curtain once its first frame is on (uncoverMs; nil when the
--- picture is already up). Returns when the camera is back behind the player. Yields.
---
--- opts.hold (Arrival.fromMap): the scene is held on its first frame, its camera on screen, and hold.ready() is
--- called; it plays on once hold.go() says so (asked every frame), or after hold.maxMs, when hold.lost() is called
--- first. opts.onStart: called as it plays on (the map fades).
---@param run table  from Arrival.prepare
---@param uncoverMs number|nil
---@param opts table|nil  { hold = { ready, go, lost, maxMs }, onStart }
function Arrival.play(run, uncoverMs, opts)
    local hold = opts and opts.hold
    local onStart = opts and opts.onStart
    local s, o, r, from = run.def, run.origin, run.rot, run.from or 0.0
    -- Logged out since it was prepared: nothing to play. (A run not from prepare counts from now.)
    if run.outGen == nil then run.outGen = outGen end
    if gone(run) then return end
    local ped = PlayerPedId()
    local lengthMs = GetAnimDuration(s.dict, s.clip) * 1000.0
    -- Where the safety net below puts them back: where they stand before the scene moves them, or, out of a seat
    -- into a scene round the car, where it starts (roomFor found the way there clear).
    local backTo, backH = GetEntityCoords(ped), GetEntityHeading(ped)
    if not run.veh and IsPedInAnyVehicle(ped, false) then backTo = pointAt(s, o, r, from) end
    -- How high their feet sit over the floor standing (shoes differ): what the scene's first frame is matched to.
    local rest = FOOT_REST
    if not run.veh and not IsPedInAnyVehicle(ped, false) then
        local h = footHeight(ped)
        if h and h > 0.0 and h < 0.25 then rest = h end
    end

    PedHold.set('arrival', { invincible = true })
    ControlBlocks.hold('arrival', { all = true })
    CleanScreen.hold('arrival')

    ---@type integer|nil
    local cam = s.cam and CreateCam('DEFAULT_ANIMATED_CAMERA', true) or nil
    run.cam = cam   -- (for Arrival.run's clean-up, should anything below throw)
    run.prop = makeProp(s.prop)
    -- In the scene with its own clip when standing; otherwise (and seated, where there is no scene) in the hand.
    local propInScene = run.prop and not run.veh and s.prop.how == 'clip' and type(s.prop.clip) == 'string'
    if run.prop and not propInScene then holdProp(run.prop, s.prop, ped) end
    if run.veh then
        TaskPlayAnim(ped, s.dict, s.clip, 1000.0, -4.0, -1, 0, 0.0, false, false, false)
        if cam then PlayCamAnim(cam, s.cam, s.dict, o.x, o.y, o.z, r.x, r.y, r.z, false, 2) end
        if from > 0 then
            Wait(0)
            if gone(run) then return end
            SetEntityAnimCurrentTime(ped, s.dict, s.clip, from)
            if cam then SetCamAnimCurrentPhase(cam, from) end
        end
        if hold then holdScene(run, true); pinHeld(run, ped) end
    else
        -- Lined up with a vehicle they sit in: out of it first (a scene cannot take a seated ped).
        if run.lineup and IsPedInAnyVehicle(ped, false) then
            ClearPedTasksImmediately(ped)
            local p = pointAt(s, o, r, from)
            SetEntityCoordsNoOffset(ped, p.x, p.y, p.z, false, false, false)
        end
        -- Feet on the floor: the origin moved up or down to match, before anyone sees the scene. Not for one that
        -- starts with them in the car they woke in (the get-in one): its first frame has them half inside it, the floor
        -- under their feet is the car's, and it was lifted through the roof (Josh, 1 Nov). It is placed by the car.
        if not run.fromSeat then feetOnFloor(run, ped, rest) end
        if gone(run) then return end
        o = run.origin
        run.netScene = NetworkCreateSynchronisedScene(o.x, o.y, o.z, r.x, r.y, r.z, 2, false, false, 1.0, from, 1.0)
        NetworkAddPedToSynchronisedScene(ped, run.netScene, s.dict, s.clip, 1000.0, -4.0, SCENE_FLAGS, 0, 1000.0, 0)
        if propInScene then
            NetworkAddEntityToSynchronisedScene(run.prop, run.netScene, s.dict, s.prop.clip, 1000.0, -8.0, 1)
        end
        -- The vehicle stays out of it (its physics, its wheels on the ground); its doors are opened by hand.
        if run.lineup and Vehicles.takeControl(run.lineup, { attempts = 2 }) then run.doors = handlesOf(run.lineup) end
        if gone(run) then return end
        NetworkStartSynchronisedScene(run.netScene)
        local by = GetGameTimer() + START_WAIT_MS
        repeat
            Wait(0)
            local id = NetworkGetLocalSceneFromNetworkId(run.netScene)
            if id and id ~= -1 then run.localScene = id end
        until run.localScene or GetGameTimer() > by
        if gone(run) then return end
        if run.localScene and from > 0 and GetSynchronizedScenePhase(run.localScene) < from - 0.02 then
            SetSynchronizedScenePhase(run.localScene, from)
        end
        -- Held from its first frame (the map lines up with it): only this game's copy, so the people watching see it
        -- start a moment early, which nobody can tell.
        if hold then holdScene(run, true) end
        -- Tied to the scene's own clock where it can be, so the two cannot drift apart. A scene started
        -- part way keeps its camera move from the beginning: Josh likes the car-door one that way (the
        -- camera comes down as the door opens).
        if cam then
            if run.localScene then
                PlaySynchronizedCamAnim(cam, run.localScene, s.cam, s.dict)
            else
                PlayCamAnim(cam, s.cam, s.dict, o.x, o.y, o.z, r.x, r.y, r.z, false, 2)
                if from > 0 then SetCamAnimCurrentPhase(cam, from) end
            end
        end
    end
    if cam and not IsCamPlayingAnim(cam, s.cam, s.dict) then
        -- The camera move did not take (never seen; a missing clip is caught in prepare): the scene
        -- plays under the game's own camera rather than from wherever an empty camera sits.
        DestroyCam(cam, false)
        cam, run.cam = nil, nil
    end
    if cam then RenderScriptCams(true, false, 0, true, false) end

    -- Two frames for the first pose and shot to be on, then the picture.
    Wait(0); Wait(0)
    if gone(run) then return end
    if uncoverMs then Curtain.Uncover(uncoverMs) end

    -- Held on that first frame until the map has lined up with its camera (Arrival.fromMap).
    if hold then
        pinHeld(run, ped)
        hold.ready()
        local by, went = GetGameTimer() + (hold.maxMs or 15000), false
        while GetGameTimer() < by do
            if gone(run) then return end
            if hold.go() then went = true; break end
            pinHeld(run, ped)
            Wait(0)
        end
        if not went and hold.lost then hold.lost() end
        holdScene(run, false)
    end
    if onStart then onStart() end

    -- To its last frame (or `to`, where a line ends it early), with the scene's camera on it the whole way.
    --
    -- THE SAFETY NET (Josh's option 1, 1 Nov): the room was tested before it was picked (roomFor), but a scene plays
    -- with no physics, so should the body still go through something (a car parked since, a door shut since), it is
    -- caught frame by frame (bodyBlocked, from the last frame's spot to this one) and the scene stops there. They
    -- are put back where they were (backTo), not left wherever it stopped. Not for a clip played in a seat (no walk),
    -- and not for a scene that gets them into the car (getsIn): its body ends up inside the car, and it was stopped
    -- early as walking into a wall (Josh, 1 Nov). Its way to the car is still tested before it is picked (roomFor).
    local endAt = run.to or HAND_BACK_AT
    local stopBy = GetGameTimer() + lengthMs * (endAt - from) + END_MARGIN_MS
    local last = not run.veh and not s.getsIn and GetEntityCoords(ped) or nil
    while GetGameTimer() < stopBy do
        if gone(run) then return end
        if IsEntityDead(ped) then break end
        local phase = phaseOf(run, ped)
        if not phase or phase >= endAt then break end
        letGoOfProp(run, phase)
        if run.doors then openReached(run, ped) end
        if last then
            local now = GetEntityCoords(ped)
            if #(now - last) > 0.02 then
                -- The root is about a metre up: knees, waist and shoulders from there. The map and vehicles only: the
                -- scene's own prop moves beside the body (objects were tested before it was picked).
                local blocked, what = bodyBlocked(last, now, last.z - 1.0, now.z - 1.0, run.lineup or ped, 1 + 2)
                if blocked then
                    run.blocked = true
                    print(('[whip_core:arrival] %s/%s walked into %s: stopped, and put back where they were')
                        :format(s.dict, s.clip, hitWords(what)))
                    break
                end
                last = now
            end
        end
        Wait(0)
    end

    local function putBack()
        if run.netScene then NetworkStopSynchronisedScene(run.netScene); run.netScene = nil end
        ClearPedTasksImmediately(ped)
        SetEntityCoordsNoOffset(ped, backTo.x, backTo.y, backTo.z, false, false, false)
        SetEntityHeading(ped, backH)
    end

    -- A scene that ends with them getting in: in the seat they had while it is still free and the car
    -- still unlocked (never another seat, never past a lock: as Arrival.place), before the camera comes
    -- back (it comes back to them in the car). Otherwise they stay standing where the scene ended, or, stopped by
    -- the safety net, where they were. A scene that got them in but found no seat for them (the car locked, or
    -- their seat taken, while it played) ends with its body inside the car: they are put back where they stood too.
    local seated = run.veh ~= nil
    if s.getsIn and run.lineup and DoesEntityExist(run.lineup) and not IsEntityDead(ped) then
        if run.netScene then NetworkStopSynchronisedScene(run.netScene); run.netScene = nil end
        local seat = not Vehicles.isLocked(run.lineup) and ownSeat(run.lineup, run.seat) or nil
        seated = seat ~= nil and seatIn(run.lineup, seat)
    end
    if (run.blocked or s.getsIn) and not seated and not IsEntityDead(ped) then putBack() end
    -- Doors a hand opened shut again (once they are in, for one that ends in the seat).
    if run.doors and DoesEntityExist(run.lineup) then shutOpened(run) end

    -- THE CAMERA BACK THE WAY THE GAME GIVES IT BACK (player_timetable_scene, at a switch's end):
    -- standing, the gameplay camera takes over where the scene's camera is, looking where it looks,
    -- and only catches up to its place behind them as they move (STOP_RENDERING_SCRIPT_CAMS_USING_
    -- CATCH_UP) — they can look around from the last shot first. In a car, the game cuts straight back.
    if cam then
        if seated or IsEntityDead(ped) then
            RenderScriptCams(false, false, 0, true, false)
        else
            local camRot = GetCamRot(cam, 2)
            SetGameplayCamRelativeHeading((camRot.z - GetEntityHeading(ped) + 540.0) % 360.0 - 180.0)
            SetGameplayCamRelativePitch(camRot.x, 1.0)
            ---@diagnostic disable-next-line: redundant-parameter -- renderingOptions, NativeDB's 4th: not in the natives' docs
            StopRenderingScriptCamsUsingCatchUp(false, 0.0, 3, 0)
        end
        DestroyCam(cam, false)
        run.cam = nil
    end

    if run.netScene then NetworkStopSynchronisedScene(run.netScene) end
    if run.veh and IsEntityPlayingAnim(ped, s.dict, s.clip, 3) then StopAnimTask(ped, s.dict, s.clip, 2.0) end
    if run.prop and DoesEntityExist(run.prop) then DeleteObject(run.prop) end
    run.prop = nil

    CleanScreen.release('arrival')
    ControlBlocks.release('arrival')
    PedHold.release('arrival')
    RemoveAnimDict(s.dict)
end

--- Arrival.prepare then Arrival.play, caught. A scene takes lasting holds (the ped, every control, the clean
--- screen, a camera, a networked scene, a prop) over config lines an admin edits: anything that throws on the
--- way lets go of all of them, so a bad line never leaves a player black-screened with no controls (the load
--- then lifts the curtain and carries on). Answers whether a scene played. Yields.
---@param place table|nil  from Arrival.place
---@param uncoverMs number|nil
---@param since integer|nil  Arrival.generation() when the load began
---@return boolean
function Arrival.run(place, uncoverMs, since)
    local run
    local ok, err = pcall(function()
        run = Arrival.prepare(place, nil, since)
        if run then Arrival.play(run, uncoverMs) end
    end)
    if ok then return run ~= nil end
    print(('^1[whip_core:arrival] the arrival scene failed, so it was let go: %s^7'):format(tostring(err)))
    if run then
        stopNow(run)
    else
        CleanScreen.release('arrival')
        ControlBlocks.release('arrival')
        PedHold.release('arrival')
    end
    return false
end

-- ---- From the spawn picker's map ----
--
-- A character picked on the map (client/charselect.lua's spawn picker) arrives with no black at all (Josh, 31 Oct):
--   1. the map waits straight over the place, with the loading logo, while the scene is chosen behind it;
--   2. the scene starts and is HELD on its first frame, its camera on screen, and the map is sent that camera
--      (CharSelect.MapReady);
--   3. the map lines up with it exactly, GTA's space 1:1 with the map's, and says so (spawnsel:go);
--   4. both hold still for HOLD_MS, then the scene plays on and the map fades in the same frame
--      (CharSelect.MapStarted, which feeds it the moving camera until it has gone): the map's buildings seem to
--      turn into the game's.
-- No scene fits (dead, in water, walls all round): the same onto the game's own camera behind them, the controls
-- held until the map has gone.

local STREAM_MS   = 3000    -- for the world round them to stream in before the scene starts
local HOLD_MS     = 500     -- lined up, both still, before the scene plays and the map fades
local GO_WAIT_MS  = 15000   -- for the map to line up; past it, whip's black over the map and the scene plays on
local MAP_GONE_MS = 2500    -- with no scene, the longest the controls wait for the map to go

--- The hand-over's hold for Arrival.play (opts.hold), or for the game's own camera: ready sends the camera on screen
--- to the map, go is true HOLD_MS after the map says it is lined up, lost puts whip's black over a map that never did.
local function mapHold()
    local since, goAt = nil, nil
    local h = { maxMs = GO_WAIT_MS }
    h.ready = function() since = CharSelect.MapReady() end
    h.go = function()
        if not goAt and since and CharSelect.MapWent(since) then goAt = GetGameTimer() + HOLD_MS end
        return goAt ~= nil and GetGameTimer() >= goAt
    end
    h.lost = function()
        h.gone = true
        print('[whip_core:arrival] the map never lined up with the arrival: it was sent away')
        CharSelect.AbortMap(false)
        Curtain.Uncover(CharSelect.TIMES.fadeIn)
    end
    -- As the scene plays on: the map fades, fed the moving camera (not once it was sent away).
    h.start = function() if not h.gone then return CharSelect.MapStarted() end end
    return h
end

--- Arrive from the spawn picker's map (client/player.lua's load, step 7). Yields until the camera is back behind
--- them. Caught: anything that throws lets go of every hold, the map is sent away and the picture comes back.
---@param place table|nil  from Arrival.place
---@param since integer|nil  Arrival.generation() when the load began
function Arrival.fromMap(place, since)
    local run
    local gen = since or outGen
    -- Logged out on the way (see "Logging out"): the holds go and nothing more is done into the character screen.
    local function loggedOut()
        if gen == outGen then return false end
        CleanScreen.release('arrival')
        ControlBlocks.release('arrival')
        PedHold.release('arrival')
        return true
    end
    local ok, err = pcall(function()
        -- Held from here, while the map still covers them: Arrival.play takes the same holds and lets them go at its
        -- end; with no scene, they go below once the map has.
        PedHold.set('arrival', { invincible = true })
        ControlBlocks.hold('arrival', { all = true })
        CleanScreen.hold('arrival')

        local ped = PlayerPedId()
        -- The world round them in, as the scene's camera will see it.
        local at = GetEntityCoords(ped)
        NewLoadSceneStartSphere(at.x, at.y, at.z, 150.0, 0)
        local by = GetGameTimer() + STREAM_MS
        while not IsNewLoadSceneLoaded() and GetGameTimer() < by do Wait(0) end
        NewLoadSceneStop()

        -- The game's picture back under the map (the spawn's backstop fade: client/spawn.lua).
        if IsScreenFadedOut() or IsScreenFadingOut() then DoScreenFadeIn(0) end
        local frames = 0
        while IsScreenFadedOut() and frames < 10 do Wait(0); frames = frames + 1 end
        if loggedOut() then return end

        local hold = mapHold()
        run = Arrival.prepare(place, nil, gen)
        if run then
            Arrival.play(run, nil, { hold = hold, onStart = hold.start })
            return
        end
        SetGameplayCamRelativeHeading(0.0)
        SetGameplayCamRelativePitch(0.0, 1.0)
        Wait(0); Wait(0)
        if loggedOut() then return end
        hold.ready()
        local holdBy, went = GetGameTimer() + hold.maxMs, false
        while GetGameTimer() < holdBy do
            if loggedOut() then return end
            if hold.go() then went = true; break end
            Wait(0)
        end
        if not went then hold.lost() end
        local mapSince = hold.start()
        if mapSince then CharSelect.WaitMapGone(mapSince, MAP_GONE_MS) end
        CleanScreen.release('arrival')
        ControlBlocks.release('arrival')
        PedHold.release('arrival')
    end)
    if ok then return end

    print(('^1[whip_core:arrival] the arrival from the map failed, so it was let go: %s^7'):format(tostring(err)))
    if run then
        stopNow(run)
    else
        CleanScreen.release('arrival')
        ControlBlocks.release('arrival')
        PedHold.release('arrival')
    end
    if CharSelect.ViaMap() then CharSelect.AbortMap(false) end
    Curtain.Uncover(CharSelect.TIMES.fadeIn)
end

--- Are this scene's animation and camera in the game? (The settings page's Watch says why one will not play:
--- tools/panel_sections/config.lua.) Yields: loads the dictionary.
Arrival.inGame = loaded
