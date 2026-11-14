-- ============================================
-- Item: camera — Client Logic
-- Used, it comes out and up to the eye (GTA's paparazzi clips), and a second later the player looks
-- through it: a camera at their eyes that turns with the mouse (the right stick) and zooms with the
-- wheel as noclip does (FreeCam.wheelZoom), under the viewfinder (html/js/viewfinder.js). No photos yet.
-- ============================================
--
-- Put away, with the lowering clip, by Esc, Backspace, the right mouse button or C (B on a pad), a hotbar slot
-- used (the number keys work while it is up), a screen opening over it (the inventory's key), or the hands
-- wanted for something else ('freeHands'). At once, with
-- no clip, by what ends it: death, a logout, a ragdoll, a fall, water, a car, the camera leaving the pockets,
-- or the server taking the prop (another set took the hand: server/items/camera.lua).
--
-- What the player sees is the camera's own: the ped and the camera in its hand are hidden on this game
-- only, so everyone else sees them holding it up to their face, turning as they look about. They walk
-- while it is up (a walk at most): the game's own first person is put on under it, so they face where the
-- lens looks and step sideways as first person does. While it comes up and goes down, the game's camera
-- is theirs to look about with.

local CORE = GetCurrentResourceName()

local RAISE = { dict = 'amb@world_human_paparazzi@male@enter', clip = 'enter' }
local HOLD  = { dict = 'amb@world_human_paparazzi@male@base', clip = 'base' }
local LOWER = { dict = 'amb@world_human_paparazzi@male@exit', clip = 'exit' }
local RAISE_MS     = 1000   -- from the clip starting to the viewfinder
local LOWER_MAX_MS = 1500   -- the lowering clip, at most, before the camera leaves the hand
local PROP = (`prop_pap_camera_01`) --[[@as integer]]   -- server/items/camera.lua's

-- The eyes: the head bone, as the ped stands when it comes up, a little up and in front of it.
local HEAD_BONE   = 31086
local EYE_UP      = 0.06
local EYE_FORWARD = 0.12

-- The lens: noclip's zoom (client/freecam.lua), from 7.5 times closer than the lens it opens on to 30 degrees wider.
local FOV_START = 50.0
local FOV_MIN   = FOV_START / 7.5
local FOV_MAX   = 80.0
local PITCH_MAX = 80.0
local LOOK      = 4.0      -- the mouse, as noclip's (CC_SENSITIVITY); slower as the lens narrows
local PAD_LOOK  = 140.0    -- degrees a second, the right stick all the way over (noclip's)
local PAD_ZOOM  = 30.0     -- degrees a second, a trigger all the way down
local PAD_DEAD  = 0.12       -- a stick or trigger at rest (the triggers: WhipPadTrigger, client/controller.lua)

-- Held from the clip starting until the camera has left the hand: no fighting, jumping, cover, crouching or
-- getting into a car, and a walk at most. `mode`: the E prompts and pad's world buttons stand down; `hotbar`:
-- the hotbar's number keys still work, and using one puts the camera away (whip_core:hotbar:slotUsed, below).
local BLOCK_ID = 'cameraItem'
local HANDS = {
    groups = { 'combat', 'weaponWheel' },
    controls = { 22, 23, 36, 44 },
    walk = true,
    mode = true,
    hotbar = true,
}
-- ...and while looking through it, the look and the wheel are the viewfinder's, Esc, Backspace and C its exit
-- (named, so the pause keys leave Esc to it), and V would change the game's view.
local LOOKING = {
    groups = { 'combat', 'weaponWheel', 'look' },
    controls = { 22, 23, 36, 44, 200, 202, 177, 26, 0, 241, 242 },
    walk = true,
    mode = true,
    hotbar = true,
}
local FIRST_PERSON = 4   -- the game's view mode under the viewfinder

local state = 'off'   -- 'raising' | 'on' | 'lowering' | 'off'
local gen = 0         -- bumped by every raise and put-away: a raise still on its way checks it was not called off
local cam, prop = nil, nil
local yaw, pitch, fov, fovTarget = 0.0, 0.0, FOV_START, FOV_START
local viewMode = nil   -- the player's own view mode, given back when the viewfinder closes

-- "Is the player carrying a camera", kept fresh by whip_core: when it goes, so does the viewfinder.
Inventory.registerItemFlagFor(CORE, 'camera')

local function padAxis(v) return (v > PAD_DEAD or v < -PAD_DEAD) and v or 0.0 end

local function play(a, flag)
    TaskPlayAnim(PlayerPedId(), a.dict, a.clip, 8.0, -8.0, -1, flag, 0, false, false, false)
end

--- What ends it at once: nothing the player could hold a camera up through.
local function mustEnd(ped)
    return IsEntityDead(ped) or IsPedRagdoll(ped) or IsPedFalling(ped) or IsPedSwimming(ped)
        or IsPedInAnyVehicle(ped, true) or not Inventory.hasItemFlag('camera')
end

local function closeViewfinder()
    if not cam then return end
    RenderScriptCams(false, false, 0, true, false)
    DestroyCam(cam, false)
    cam, prop = nil, nil
    CleanScreen.release(BLOCK_ID)
    SendNUIMessage({ action = 'viewfinder', on = false })
    if viewMode then SetFollowPedCamViewMode(viewMode) end
    viewMode = nil
    -- The game's camera picks up looking where the viewfinder did.
    SetGameplayCamRelativeHeading(0.0)
    SetGameplayCamRelativePitch(pitch, 1.0)
end

--- Down and away, from wherever it has got to. `quick`: no clip (what ended it took the ped's body, or the
--- hand already: death, a ragdoll, the server).
local putAway
putAway = function(quick)
    if state == 'off' or state == 'lowering' then return end
    gen = gen + 1
    local my = gen
    closeViewfinder()
    ControlBlocks.hold(BLOCK_ID, HANDS)   -- the game's camera is the player's again while it goes down
    state = 'lowering'
    CreateThread(function()
        local ped = PlayerPedId()
        StopAnimTask(ped, RAISE.dict, RAISE.clip, 2.0)
        StopAnimTask(ped, HOLD.dict, HOLD.clip, 2.0)
        if not quick and HasAnimDictLoaded(LOWER.dict) then
            play(LOWER, 48)
            local ms = math.floor((GetAnimDuration(LOWER.dict, LOWER.clip) or 0) * 1000)
            Wait(math.max(0, math.min(LOWER_MAX_MS, ms)))
            StopAnimTask(PlayerPedId(), LOWER.dict, LOWER.clip, 2.0)
        end
        if gen ~= my then return end
        UI.dropOwnHeldProp(PROP, 'camera')
        TriggerServerEvent('whip_core:server:cameraHold', false)
        ControlBlocks.release(BLOCK_ID)
        RemoveAnimDict(RAISE.dict)
        RemoveAnimDict(HOLD.dict)
        RemoveAnimDict(LOWER.dict)
        state = 'off'
    end)
end

--- Every frame while it is up: the look, the lens, the ped turning with them, and what ends it.
local function viewLoop(my)
    while state == 'on' and gen == my and cam do
        local ped = PlayerPedId()
        if mustEnd(ped) then putAway(true) break end
        -- A screen opened over it (the inventory's key, the emote menu): the clean screen would hide it.
        if IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 177) or WhipCancelJustPressed()
            or IsAnyUIOpen() then
            putAway(false)
            break
        end

        local slow = fov / FOV_START
        if WhipPadActive then
            local dt = GetFrameTime()
            yaw = yaw - padAxis(GetDisabledControlNormal(0, 1)) * PAD_LOOK * slow * dt
            pitch = pitch - padAxis(GetDisabledControlNormal(0, 2)) * PAD_LOOK * slow * dt
            fovTarget = math.max(FOV_MIN, math.min(FOV_MAX, fovTarget + (WhipPadTrigger('lt', PAD_DEAD) - WhipPadTrigger('rt', PAD_DEAD)) * PAD_ZOOM * dt))
        else
            yaw = yaw - GetDisabledControlNormal(0, 1) * LOOK * slow
            pitch = pitch - GetDisabledControlNormal(0, 2) * LOOK * slow
            fovTarget = FreeCam.wheelZoom(fovTarget, FOV_MIN, FOV_MAX)
        end
        yaw = yaw % 360.0
        pitch = math.max(-PITCH_MAX, math.min(PITCH_MAX, pitch))
        fov = FreeCam.easeFov(fov, fovTarget)
        SetCamRot(cam, pitch, 0.0, yaw, 2)
        SetCamFov(cam, fov)
        -- The ped faces the lens, and the game's first person camera under it faces the same way, so a walk
        -- goes where the lens looks.
        SetEntityHeading(ped, yaw)
        if GetFollowPedCamViewMode() ~= FIRST_PERSON then SetFollowPedCamViewMode(FIRST_PERSON) end
        SetGameplayCamRelativeHeading(0.0)

        -- The lens is at the eyes: the head, the hands and the camera itself would fill it.
        SetEntityLocallyInvisible(ped)
        if not prop or not DoesEntityExist(prop) then prop = UI.ownHeldProp(PROP, 'camera') end
        if prop then SetEntityLocallyInvisible(prop) end
        if not IsEntityPlayingAnim(ped, HOLD.dict, HOLD.clip, 3) then play(HOLD, 49) end
        Wait(0)
    end
end

local function openViewfinder(my)
    local ped = PlayerPedId()
    local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
    local eye = GetOffsetFromEntityGivenWorldCoords(ped, head.x, head.y, head.z)
    yaw, pitch = GetEntityHeading(ped), 0.0
    fov, fovTarget = FOV_START, FOV_START
    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    AttachCamToEntity(cam, ped, 0.0, eye.y + EYE_FORWARD, eye.z + EYE_UP, true)
    SetCamRot(cam, pitch, 0.0, yaw, 2)
    SetCamFov(cam, fov)
    RenderScriptCams(true, false, 0, true, false)
    viewMode = GetFollowPedCamViewMode()
    SetFollowPedCamViewMode(FIRST_PERSON)
    ControlBlocks.hold(BLOCK_ID, LOOKING)
    -- The HUD and whip's screens go; whip's things in the world (/me bubbles, prompts) stay unless the server says.
    CleanScreen.hold(BLOCK_ID, { keepWorld = Config.CameraHidesDui ~= true })
    SendNUIMessage({ action = 'viewfinder', on = true })
    play(HOLD, 49)
    state = 'on'
    viewLoop(my)
end

local function raise()
    if state ~= 'off' then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, true) then UI.Notify('You cannot use a camera in a vehicle', 'error') return end
    if mustEnd(ped) then return end
    gen = gen + 1
    local my = gen
    state = 'raising'
    CreateThread(function()
        if Inventory.isOpen() then Inventory.close() end
        local free = Inventory.freeHands()
        if gen ~= my then return end
        if not free then state = 'off' return end
        if not (LoadAnimDict(RAISE.dict) and LoadAnimDict(HOLD.dict) and LoadAnimDict(LOWER.dict)) then
            if gen == my then state = 'off' end
            return
        end
        if gen ~= my then return end
        ControlBlocks.hold(BLOCK_ID, HANDS)
        TriggerServerEvent('whip_core:server:cameraHold', true)
        play(RAISE, 50)
        Wait(RAISE_MS)
        if gen ~= my then return end
        if mustEnd(PlayerPedId()) then putAway(true) return end
        openViewfinder(my)
    end)
end

-- The server's answer to using it (server/items/camera.lua): out if it is away, away if it is out.
RegisterNetEvent('whip_core:client:cameraUse', function()
    if state == 'off' then raise() else putAway(false) end
end)

-- The server took the camera out of the hand (another set took it, or a move to another world).
RegisterNetEvent('whip_core:client:cameraAway', function() putAway(true) end)

-- A hotbar slot used while it is up (the camera's own slot too: its use then finds it going down, and leaves it).
AddEventHandler('whip_core:hotbar:slotUsed', function() putAway(false) end)

AddEventHandler('whip_core:player:died', function() putAway(true) end)
AddEventHandler('whip_core:player:logout', function() putAway(true) end)

-- Something else wants the hands (the phone): the camera comes down first, and that waits for it. Not while
-- it is coming up: its own raise asks the same.
RegisterClientHook('freeHands', function()
    if state ~= 'on' then return 0 end
    putAway(false)
    return LOWER_MAX_MS
end, 'camera')

-- A restart with it up gives the player the game's camera back: nothing else would.
AddEventHandler('onResourceStop', function(res)
    if res ~= CORE or not cam then return end
    RenderScriptCams(false, false, 0, true, false)
    DestroyCam(cam, false)
    cam = nil
    if viewMode then SetFollowPedCamViewMode(viewMode) end
    StopAnimTask(PlayerPedId(), HOLD.dict, HOLD.clip, 2.0)
end)
