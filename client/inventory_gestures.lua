-- ============================================
-- Inventory gestures: drag onto your character, drag out to drop
-- ============================================
--
-- Two gestures of the inventory page (js/core/inv-body.js, js/core/inv-actions.js), each with a switch in config.lua:
--
--   * ON YOUR CHARACTER (Config.InventoryDragToBody). While an item from the pockets is dragged, the page draws a ring
--     over the player's own character in the world, wherever they are on screen; letting go on it uses or equips the
--     item. The ring's place is the chest, projected here every frame while the drag lasts (bodyTrack).
--   * OUT OF THE INVENTORY (Config.InventoryDragOutDrops). Letting go outside every panel drops the stack, from the
--     hand (dropByHand): on foot the player bends down and puts it down; in a vehicle they wind the window down and toss
--     it out on their seat's side, moving or not, and it falls with the vehicle's speed. Either way the item is a real
--     object in the player's hand that falls with physics where the hand lets go, the path of a thrown item
--     (whip_core:server:throwLaunched / throwSettled): the pile exists from the moment it leaves the hand and lies
--     where the object comes to rest. Where no animation fits (swimming, falling, already dropping), it is a plain drop
--     on a clear spot (DropToGround, client/ground.lua).
--
-- BOTH ARE EXTRAS. Clicking (Use), the use keys, a drag onto Nearby and shift-click all work as before, whatever is
-- set here. Each gesture can be switched off in config.lua (InventoryDragToBody, InventoryDragOutDrops, and for the
-- drop InventoryDragOutInVehicle / InventoryDragOutAnimated), and for a while by a script (BlockInventoryGesture):
-- a cell, handcuffs, a no-littering zone.

local function yes(v) return v == true or v == 1 end

-- ---- Switched off for a while: a script's block ----

local GESTURES = { body = true, dropOut = true }
local gestureBlocks = {}   -- the registry's store: { gesture = 'body'|'dropOut'|nil (both), label = string|nil }
local gestureReg = Registry.new('InventoryGestureBlock', {
    label  = 'inventory gesture block',
    store  = gestureBlocks,
    scoped = true,
})

--- May `gesture` ('body' or 'dropOut') be used now? True, or false and why: a block's words, nil when config.lua has
--- it off (nothing to say: the gesture simply is not there).
---@return boolean allowed
---@return string|nil why
local function gestureAllowed(gesture)
    if gesture == 'body' and Config.InventoryDragToBody == false then return false end
    if gesture == 'dropOut' and Config.InventoryDragOutDrops == false then return false end
    for _, b in pairs(gestureBlocks) do
        if b.gesture == nil or b.gesture == gesture then return false, b.label end
    end
    return true
end
exports('InventoryGestureAllowed', gestureAllowed)

--- Switch a gesture off until UnblockInventoryGesture(id), or this resource stops. `gesture`: 'body', 'dropOut', or
--- nil for both. `label`: what the player is told when they try (a drop); nil says nothing.
---
---     exports.whip_core:BlockInventoryGesture('cell', 'dropOut', 'You cannot drop things in here')
exports('BlockInventoryGesture', function(id, gesture, label)
    if gesture ~= nil and not GESTURES[gesture] then return false, "gesture must be 'body', 'dropOut' or nil" end
    if label ~= nil and (type(label) ~= 'string' or #label > 120) then return false, 'label must be a string (120 at most)' end
    local ok, why = gestureReg:add(Registry.caller(), id, { gesture = gesture, label = label })
    if not ok then return false, why end
    return true
end)

exports('UnblockInventoryGesture', function(id)
    local ok, why = gestureReg:remove(Registry.caller(), id)
    if not ok then return false, why end
    return true
end)

-- ---- On your character ----

local BODY_BONE = 24818              -- SKEL_Spine3: the chest
local BODY_HIDDEN = { 0.5, 0.82 }    -- where the ring sits when the chest is not on screen (first person): low, centred
local bodyRun = 0   -- bumped by every on and off: a frame loop runs only while it is still the current one

--- The chest on screen as x, y (0-1), or the fallback spot when it cannot be seen.
local function bodyPoint()
    local ped = PlayerPedId()
    local firstPerson = IsPedInAnyVehicle(ped, false) and GetFollowVehicleCamViewMode() == 4
        or (not IsPedInAnyVehicle(ped, false) and GetFollowPedCamViewMode() == 4)
    if not firstPerson then
        local c = GetPedBoneCoords(ped, BODY_BONE, 0.0, 0.0, 0.0)
        local seen, x, y = GetScreenCoordFromWorldCoord(c.x, c.y, c.z)
        if yes(seen) and x > 0.02 and x < 0.98 and y > 0.02 and y < 0.98 then return x, y end
    end
    return BODY_HIDDEN[1], BODY_HIDDEN[2]
end

-- { on = true } starts the frames (action 'bodyPoint'), { on = false } stops them. Answers { on }: false when the
-- gesture is switched off or the inventory is not open, and the page draws no ring.
RegisterNUICallback('bodyTrack', function(data, cb)
    local on = type(data) == 'table' and data.on == true and gestureAllowed('body') and Inventory.isOpen()
    cb({ on = on and true or false })
    bodyRun = bodyRun + 1
    if not on then return end
    local mine = bodyRun
    CreateThread(function()
        local lastX, lastY = -1.0, -1.0
        while mine == bodyRun and Inventory.isOpen() do
            -- Blocked mid-drag: the ring goes.
            if not gestureAllowed('body') then SendNUIMessage({ action = 'bodyPoint', hidden = true }) break end
            local x, y = bodyPoint()
            -- Only a move the page can see: a still player sends nothing.
            if math.abs(x - lastX) > 0.0005 or math.abs(y - lastY) > 0.0005 then
                lastX, lastY = x, y
                SendNUIMessage({ action = 'bodyPoint', x = x, y = y })
            end
            Wait(0)
        end
    end)
end)

-- ---- Out of the inventory: a drop from the hand ----

-- On foot: bend down and put it down.
local FOOT = { dict = 'pickup_object', clip = 'putdown_low', release = 0.35, flags = 0, bone = 57005 }
-- In a vehicle: a drive-by grenade throw out of the seat's own window (throw_90l / throw_90r), upper body only, as a
-- secondary task, the weapon hidden.
local SEAT_DICT = {
    [-1] = 'veh@drivebystd_ds_grenades', [0] = 'veh@drivebystd_ps_grenades',
    [1] = 'veh@drivebystd_rds_grenades', [2] = 'veh@drivebystd_rps_grenades',
}
local BIKE_DICT = { front = 'veh@drivebybike@sport@front@grenade', rear = 'veh@drivebybike@sport@rear@grenade' }
local UPPER_BODY = 16 + 32 + 1048576
local RIGHT_HAND, LEFT_HAND = 57005, 18905
local MAX_LAUNCH = 28.0          -- m/s: an item tossed from a moving vehicle leaves with its speed, up to this
local LOAD_MS, RELEASE_MS = 1000, 1600
local ON_PERSON = { player = true, accessory = true }
-- At rest: slower than STILL_SPEED for STILL_MS (long enough for the server to see the object where it stopped) with
-- the floor right under it (GROUNDED, m). Still with no floor under it for FROZEN_MS: frozen in the air, where the
-- map's collision never loaded (left behind at speed); it goes to the floor found below.
local STILL_SPEED, STILL_MS, FROZEN_MS, GROUNDED = 0.04, 600, 2000, 1.0
local ANSWER_MS, TRACK_MS = 5000, 10000

local dropping = false
local pending = {}   -- [netId] = { groundId = number|false|nil }, as client/inventory.lua's throws

RegisterNetEvent('whip_core:client:throwAccepted', function(netId, groundId)
    if pending[netId] then pending[netId].groundId = groundId end
end)
RegisterNetEvent('whip_core:client:throwRefused', function(netId)
    if pending[netId] then pending[netId].groundId = false end
end)

local function seatOf(ped, vehicle)
    for seat = -1, GetVehicleMaxNumberOfPassengers(vehicle) - 1 do
        if GetPedInVehicleSeat(vehicle, seat) == ped then return seat end
    end
end

--- The toss out of this seat's window, or nil (no seat found, or the game lacks the clip).
local function vehicleAnim(ped, vehicle)
    local seat = seatOf(ped, vehicle)
    if seat == nil then return nil end
    local right = seat >= 0 and seat % 2 == 0
    local dict = SEAT_DICT[seat] or SEAT_DICT[right and 2 or 1]
    if GetVehicleClass(vehicle) == 8 then dict = seat == -1 and BIKE_DICT.front or BIKE_DICT.rear end
    if not yes(DoesAnimDictExist(dict)) then return nil end
    return { dict = dict, clip = right and 'throw_90r' or 'throw_90l', release = 0.35, flags = UPPER_BODY,
             seat = seat, right = right, bone = right and RIGHT_HAND or LEFT_HAND }
end

local function loadModel(model)
    RequestModel(model)
    local deadline = GetGameTimer() + LOAD_MS
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(model)
end

local function loadAnim(dict, model)
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + LOAD_MS
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(0) end
    return HasAnimDictLoaded(dict) and loadModel(model)
end

--- Where the item leaves the hand, and how fast. Out of a vehicle: just outside its side, with its speed and a push
--- away from it. On foot: a little ahead, at a walk's share of the player's speed.
local function launch(ped, obj, anim, vehicle)
    local pos = GetEntityCoords(obj)
    local motion = GetEntityVelocity(vehicle ~= 0 and vehicle or ped)
    if vehicle ~= 0 then
        local mn, mx = GetModelDimensions(GetEntityModel(vehicle))
        local hand = GetOffsetFromEntityGivenWorldCoords(vehicle, pos.x, pos.y, pos.z)
        local x = anim.right and math.max(hand.x, mx.x + 0.15) or math.min(hand.x, mn.x - 0.15)
        pos = GetOffsetFromEntityInWorldCoords(vehicle, x, hand.y, hand.z)
        local out = GetOffsetFromEntityInWorldCoords(vehicle, anim.right and 1.0 or -1.0, 0.0, 0.0) - GetEntityCoords(vehicle)
        local v = vector3(motion.x + out.x * 1.1, motion.y + out.y * 1.1, motion.z - 0.2)
        if #v > MAX_LAUNCH then v = v * (MAX_LAUNCH / #v) end
        return pos, v
    end
    local fwd = GetEntityForwardVector(ped)
    return pos, vector3(motion.x * 0.35 + fwd.x * 0.45, motion.y * 0.35 + fwd.y * 0.45, motion.z * 0.15 - 0.15)
end

--- Let it fly: at `pos`, turned as `rot`, at `vel`.
local function fly(obj, pos, rot, vel)
    SetEntityCoordsNoOffset(obj, pos.x, pos.y, pos.z, false, false, false)
    SetEntityRotation(obj, rot.x, rot.y, rot.z, 2, true)
    SetEntityDynamic(obj, true)
    SetEntityCollision(obj, true, true)
    SetEntityHasGravity(obj, true)
    ActivatePhysics(obj)
    SetEntityVelocity(obj, vel.x, vel.y, vel.z)
    -- The map's collision follows it: left behind by a fast vehicle, it would otherwise freeze in the air.
    SetEntityLoadCollisionFlag(obj, true, 1)
end

--- A model with no physics of its own (an attachment prop, a custom one) stays where the hand let go. It falls as an
--- invisible Config.DefaultGroundProp box instead (the server takes that for any item), carrying the item's model as
--- a local visual. Returns the box and the visual, or nil.
local function proxyFor(obj, model, pos, rot, vel)
    local box = GetHashKey(Config.DefaultGroundProp)
    if not loadModel(box) then return nil end
    local body = CreateObject(box, pos.x, pos.y, pos.z, true, true, false)
    SetModelAsNoLongerNeeded(box)
    if not body or body == 0 then return nil end
    SetEntityVisible(body, false, false)
    DeleteEntity(obj)
    local visual = loadModel(model) and CreateObject(model, pos.x, pos.y, pos.z, false, false, false) or 0
    if visual ~= 0 then
        SetEntityCollision(visual, false, false)
        AttachEntityToEntity(visual, body, 0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
        SetModelAsNoLongerNeeded(model)
    end
    fly(body, pos, rot, vel)
    return body, visual ~= 0 and visual or nil
end

--- Resting for real: the map's collision loaded around it and the floor right under it.
local function grounded(obj)
    return yes(HasCollisionLoadedAroundEntity(obj)) and GetEntityHeightAboveGround(obj) < GROUNDED
end

--- The floor's z under `c`, or nil.
local function groundZ(c)
    RequestCollisionAtCoord(c.x, c.y, c.z)
    for _, up in ipairs({ 2.0, 25.0 }) do
        local found, z = GetGroundZFor_3dCoord(c.x, c.y, c.z + up, false)
        if yes(found) then return z end
    end
end

--- Name the falling object to the server and follow it to rest (as client/inventory.lua's TrackThrow, with no hit
--- check: a drop is not a throw at anyone).
local function track(obj, data, visual)
    local deadline = GetGameTimer() + 1000
    while not yes(NetworkGetEntityIsNetworked(obj)) and GetGameTimer() < deadline do Wait(0) end
    local netId = NetworkGetNetworkIdFromEntity(obj)
    SetNetworkIdCanMigrate(netId, false)
    local t = {}
    pending[netId] = t
    TriggerServerEvent('whip_core:server:throwStarted', netId)
    TriggerServerEvent('whip_core:server:throwLaunched', data.container, data.slot, data.amount, netId)
    local started, stillSince = GetGameTimer(), nil
    while true do
        Wait(0)
        local now = GetGameTimer()
        -- Refused or unanswered: the item never left the pockets, so neither may its object.
        if t.groundId == false or (t.groundId == nil and now - started > ANSWER_MS) then
            if DoesEntityExist(obj) then DeleteEntity(obj) end
            break
        end
        if not DoesEntityExist(obj) then break end   -- picked out of the air
        if #GetEntityVelocity(obj) < STILL_SPEED then stillSince = stillSince or now else stillSince = nil end
        local stillMs = stillSince and now - stillSince or 0
        local landed = stillMs >= STILL_MS and grounded(obj)
        local stuck = stillMs >= FROZEN_MS or now - started > TRACK_MS
        if t.groundId and (landed or stuck) then
            -- How it lies goes with it, unless it is a box carrying a visual (the box's pose is not the item's) or it
            -- never came to rest: then it stands upright on the floor.
            local settled = landed and not visual
            local c, rot = GetEntityCoords(obj), GetEntityRotation(obj, 2)
            if not landed then
                local z = groundZ(c)
                if z then c = vector3(c.x, c.y, z) end
            end
            TriggerServerEvent('whip_core:server:throwSettled', t.groundId, c.x, c.y, c.z, rot.z % 360.0, rot.x, rot.y, settled)
            -- The server deletes it once the pile is drawn; this is the backstop.
            SetTimeout(5000, function() if DoesEntityExist(obj) then DeleteEntity(obj) end end)
            break
        end
    end
    pending[netId] = nil
    if visual then
        local untilAt = GetGameTimer() + 5000
        while DoesEntityExist(obj) and GetGameTimer() < untilAt do Wait(100) end
        if DoesEntityExist(visual) then DeleteEntity(visual) end
    end
end

local function perform(ped, anim, model, data, vehicle)
    local c = GetEntityCoords(ped)
    local obj = CreateObject(model, c.x, c.y, c.z - 2.0, true, true, false)
    SetModelAsNoLongerNeeded(model)
    if not obj or obj == 0 then
        -- No object: it lands at the feet, as a throw's fallback does.
        TriggerServerEvent('whip_core:server:throwItemLanded', data.container, data.slot, data.amount,
            c.x, c.y, c.z - 0.5, GetEntityHeading(ped))
        return
    end
    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, anim.bone), 0.12, 0.0, -0.02, 0.0, 0.0, 0.0,
        true, true, false, true, 1, true)

    TaskPlayAnim(ped, anim.dict, anim.clip, 4.0, -4.0, -1, anim.flags, 0.0, false, false, false)
    local deadline = GetGameTimer() + RELEASE_MS
    while GetGameTimer() < deadline do
        if yes(IsEntityPlayingAnim(ped, anim.dict, anim.clip, 3))
            and GetEntityAnimCurrentTime(ped, anim.dict, anim.clip) >= anim.release then break end
        Wait(0)
    end

    -- The hand lets go: it falls.
    local pos, vel = launch(ped, obj, anim, vehicle)
    local rot = GetEntityRotation(obj, 2)
    DetachEntity(obj, true, true)
    fly(obj, pos, rot, vel)
    Wait(0)
    local visual
    if not yes(DoesEntityHavePhysics(obj)) then
        local body
        body, visual = proxyFor(obj, model, pos, rot, vel)
        if body then obj = body end
    end
    CreateThread(function() track(obj, data, visual) end)

    deadline = GetGameTimer() + 1500
    while yes(IsEntityPlayingAnim(ped, anim.dict, anim.clip, 3)) and GetGameTimer() < deadline do Wait(50) end
    RemoveAnimDict(anim.dict)
end

-- { container, slot, amount, item }: a stack from the pockets, let go outside every panel. Answers { ok }, or
-- { ok = false, reason? } when the gesture is off here (the page leaves the item where it was and shows the reason).
RegisterNUICallback('dropByHand', function(data, cb)
    data = type(data) == 'table' and data or {}
    local allowed, why = gestureAllowed('dropOut')
    if not allowed then return cb({ ok = false, reason = why }) end
    if Config.InventoryDragOutInVehicle == false and IsPedInAnyVehicle(PlayerPedId(), false) then
        return cb({ ok = false })
    end
    local slot, amount = math.tointeger(tonumber(data.slot)), math.tointeger(tonumber(data.amount))
    if not ON_PERSON[data.container] or not slot or not amount or amount < 1 or type(data.item) ~= 'string' then
        return cb({ ok = false })
    end
    cb({ ok = true })

    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local anim = vehicle ~= 0 and vehicleAnim(ped, vehicle) or (vehicle == 0 and FOOT or nil)
    -- No animation where none fits, or none wanted (InventoryDragOutAnimated): a plain drop on a clear spot.
    if Config.InventoryDragOutAnimated == false or not anim or dropping or yes(IsPedSwimming(ped)) or yes(IsPedFalling(ped)) or yes(IsPedRagdoll(ped))
        or yes(IsEntityDead(ped)) then
        return DropToGround(data.container, slot, amount)
    end
    dropping = true
    CreateThread(function()
        local model = GetHashKey(Inventory.itemPropModel(data.item))
        if not loadAnim(anim.dict, model) then
            dropping = false
            return DropToGround(data.container, slot, amount)
        end
        if vehicle ~= 0 and anim.seat >= -1 and anim.seat <= 2 then RollDownWindow(vehicle, anim.seat + 1) end
        local ok, err = pcall(perform, ped, anim, model, { container = data.container, slot = slot, amount = amount }, vehicle)
        if not ok then print(('[whip_core:inv] a drop by hand failed: %s'):format(tostring(err))) end
        dropping = false
    end)
end)
