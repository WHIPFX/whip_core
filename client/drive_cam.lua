-- Driving camera: a chase camera for players who switch it on (pause menu: Settings → Server → Vehicles), when the server
-- allows it (Config.DrivingCamera). In a car, bike or quad it takes over with the camera system's chase shot
-- (client/cam_shots.lua). On top: free look (mouse or right stick, drifts back a second after release), look back
-- (GTA's look-behind, C), shake (Config.DrivingCamera.Shake) and a soft entry.
--
-- GTA's view button still sets how far back it sits, and first person is GTA's. It stands aside while aiming or
-- shooting, for the cinematic camera, for death, and for any other script's camera on screen.
--
-- Two styles, each player's choice: Consistent is the chase camera as it is, the same all the time; Cinematic puts a
-- director over it (below), which frames the car by what it is doing.

local PREF = 'drive.camera'
local STYLE = 'drive.cameraStyle'

local function offered() return Config.DrivingCamera == nil or Config.DrivingCamera.Enabled ~= false end

PlayerPrefs.define({
    key = PREF, group = 'Vehicles', label = 'Smooth driving camera',
    help = 'A chase camera that follows on a spring, leans into slides and widens with speed. The mouse or the right stick looks round, and it drifts back by itself. Your view button still sets how far back it sits.',
    type = 'toggle',
    default = function() return Config.DrivingCamera ~= nil and Config.DrivingCamera.Default == true end,
    visible = offered,
})

PlayerPrefs.define({
    key = STYLE, group = 'Vehicles', label = 'Camera style',
    help = 'Consistent stays behind the car the same way all the time. Cinematic frames the car by what it is doing: back and up in the air, further back and looser in a drift, lower and closer in a burnout, much wider on nitrous.',
    type = 'choice',
    options = { { value = 'consistent', label = 'Consistent' }, { value = 'cinematic', label = 'Cinematic' } },
    default = function()
        return Config.DrivingCamera ~= nil and Config.DrivingCamera.Style == 'cinematic' and 'cinematic' or 'consistent'
    end,
    visible = function() return offered() and PlayerPrefs.get(PREF) == true end,
})

local M = CamMath

-- How far back and up, by GTA's view (0 near, 1 middle, 2 far), for a car 4.6 m long; other vehicles scale it.
local VIEWS = {
    [0] = { dist = 4.4, height = 1.55, fov = 52.0, stiff = 7.5 },
    [1] = { dist = 5.2, height = 1.80, fov = 52.0, stiff = 7.0 },
    [2] = { dist = 6.8, height = 2.30, fov = 50.0, stiff = 6.2 },
}
local CAR_LENGTH = 4.6

-- Free look: degrees per unit of mouse input, the stick's turn rate, the limits, and how it drifts back.
local LOOK = { yaw = 16.0, pitch = 10.0, padYaw = 150.0, padPitch = 75.0, pitchMin = -25.0, pitchMax = 55.0,
               deadzone = 0.005, padDead = 0.12, returnDelay = 1.0, returnRate = 2.2, backRate = 14.0 }

-- Getting in: the springs start soft and ease up over ENTER_S seconds. Handing back eases over EXIT_MS; after standing
-- aside it waits AGAIN_MS before taking over again, so a quick aim does not flick it back and forth.
local ENTER_RATE, ENTER_S = 3.2, 0.9
local EXIT_MS, AGAIN_MS = 500, 600

-- Shake: road at speed, and knocks from a crash or a landing.
local SHAKE = { speed = 0.18, baseFreq = 7.0, speedFreq = 11.0, air = 0.15, land = 0.9, crash = 1.6,
                decay = 2.6, maxImpulse = 2.6, max = 2.5, dv = 4.0, dvFull = 22.0, hp = 8.0, hpFull = 120.0 }

---@type integer|nil
local cam = nil
local mem = {}
local run = { subjects = {}, frame = 0 }
local look = { yaw = 0.0, pitch = 0.0, amount = 0.0, free = false }
local idle, wasBack = 0.0, false
local enterT = 1.0
local lastYaw = nil
local blockedAt = -AGAIN_MS
local shake = { phase = 0.0, mag = 0.0, impulse = 0.0, cool = 0.0, pvx = nil, pvy = nil, pvz = nil, hp = nil, ground = true }
-- The Cinematic director (below): the moment with the camera, and its signals: air (s in the air), still (s stopped),
-- accel (m/s² along the way, smoothed), the last speed, a burnout under way, and the framing `f` now.
local dir = { name = 'cruise', since = 0.0, lastOn = 0.0, t = 0.0, k = 1.0, air = 0.0, still = 0.0, accel = 0.0,
              speed = nil, burning = false, f = nil }

local function directorReset()
    dir.name, dir.since, dir.lastOn, dir.t, dir.k = 'cruise', 0.0, 0.0, 0.0, 1.0
    dir.air, dir.still, dir.accel, dir.speed, dir.burning, dir.f = 0.0, 0.0, 0.0, nil, false, nil
end

--- Another script's camera on screen (a cutscene, the Camera Creator, noclip, a garage camera): it wins.
local function othersCamera()
    if Camera.IsActive() or FreeCam.isActive() or CameraCreatorActive then return true end
    local r = GetRenderingCam()
    return r ~= -1 and r ~= cam
end

--- The vehicle to follow now; or nil and why not: 'off' (not driving or switched off), 'cut' (first person),
--- 'aside' (aiming, cinematic camera, death: eased back), 'other' (another camera is up: left alone).
local function wanted()
    local dc = Config.DrivingCamera
    if not dc or dc.Enabled == false or not PlayerPrefs.get(PREF) then return nil, 'off' end
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil, 'off' end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not DoesEntityExist(veh) then return nil, 'off' end
    local model = GetEntityModel(veh)
    if not (IsThisModelACar(model) or IsThisModelABike(model) or IsThisModelAQuadbike(model)) then return nil, 'off' end
    if othersCamera() then return nil, 'other' end
    if GetFollowVehicleCamViewMode() == 4 then return nil, 'cut' end
    if IsEntityDead(ped) or IsPlayerFreeAiming(PlayerId()) or IsPedDoingDriveby(ped) or IsCinematicCamRendering() then
        return nil, 'aside'
    end
    return veh
end

local function begin()
    local gp, gr, gf = GetGameplayCamCoord(), GetGameplayCamRot(2), GetGameplayCamFov()
    cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', gp.x, gp.y, gp.z, gr.x, gr.y, gr.z, gf, true, 2)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    mem = { init = true, x = gp.x, y = gp.y, z = gp.z, pitch = gr.x, yaw = gr.z, fov = gf, roll = 0.0 }
    look.yaw, look.pitch, look.amount, look.free = 0.0, 0.0, 0.0, false
    idle, wasBack, enterT = 0.0, false, 0.0
    shake.mag, shake.impulse, shake.pvx, shake.hp, shake.ground = 0.0, 0.0, nil, nil, true
    directorReset()
end

--- Hand back, the way `why` (from wanted) asks. Another script's camera is left alone, since turning script cameras
--- off would end theirs too.
local function finish(why)
    local old = cam
    cam = nil
    if not old then return end
    if why == 'other' then
        DestroyCam(old, false)
        return
    end
    if why == 'cut' then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(old, false)
        return
    end
    -- Turn GTA's camera to where ours faced, so the ease back does not swing round.
    if lastYaw then SetGameplayCamRelativeHeading(M.wrap180(lastYaw - GetEntityHeading(PlayerPedId()))) end
    RenderScriptCams(false, true, EXIT_MS, true, true)
    -- Destroyed after the ease: destroying it earlier cuts the blend short.
    SetTimeout(EXIT_MS + 50, function() DestroyCam(old, false) end)
end

--- The viewer's look round the car this frame.
local function freeLook(dt)
    if IsControlPressed(0, 79) then   -- GTA's look behind in a vehicle (C, or the right stick's click)
        look.yaw = M.dampAngle(look.yaw, 180.0, LOOK.backRate, dt)
        look.pitch = M.damp(look.pitch, 0.0, LOOK.backRate, dt)
        idle, wasBack, look.free = 0.0, true, true
        look.amount = M.clamp(math.abs(look.yaw) / 180.0 + math.abs(look.pitch) / 60.0, 0.0, 1.0)
        return
    end
    -- Not the disabled readers: when a menu or the phone takes the look, the camera stays still.
    local lr, ud = GetControlNormal(0, 1), GetControlNormal(0, 2)
    local pad = WhipLastInputIsPad()
    local dYaw, dPitch, moved
    if pad then
        if math.abs(lr) < LOOK.padDead then lr = 0.0 end
        if math.abs(ud) < LOOK.padDead then ud = 0.0 end
        moved = lr ~= 0.0 or ud ~= 0.0
        dYaw, dPitch = -lr * LOOK.padYaw * dt, ud * LOOK.padPitch * dt
    else
        moved = math.abs(lr) + math.abs(ud) > LOOK.deadzone
        dYaw, dPitch = -lr * LOOK.yaw, ud * LOOK.pitch
    end
    -- Letting go of look-behind goes straight back at the rate it swung out.
    if wasBack and not moved then
        look.yaw = M.dampAngle(look.yaw, 0.0, LOOK.backRate, dt)
        look.pitch = M.damp(look.pitch, 0.0, LOOK.backRate, dt)
        if math.abs(look.yaw) < 0.5 and math.abs(look.pitch) < 0.5 then look.yaw, look.pitch, wasBack = 0.0, 0.0, false end
        idle = LOOK.returnDelay
    else
        wasBack = false
        if moved then
            idle = 0.0
            look.yaw = M.wrap180(look.yaw + dYaw)
            look.pitch = M.clamp(look.pitch + dPitch, LOOK.pitchMin, LOOK.pitchMax)
        else
            idle = idle + dt
            if idle >= LOOK.returnDelay then
                look.yaw = M.dampAngle(look.yaw, 0.0, LOOK.returnRate, dt)
                look.pitch = M.damp(look.pitch, 0.0, LOOK.returnRate, dt)
                if math.abs(look.yaw) < 0.08 and math.abs(look.pitch) < 0.08 then look.yaw, look.pitch = 0.0, 0.0 end
            end
        end
    end
    look.free = idle < LOOK.returnDelay
    look.amount = M.clamp(math.abs(look.yaw) / 180.0 + math.abs(look.pitch) / 60.0, 0.0, 1.0)
end

--- This frame's shake, in degrees: pitch, roll, yaw.
local function shakeFor(veh, s, dt)
    local scale = Config.DrivingCamera.Shake or 1.0
    if scale <= 0.0 then return 0.0, 0.0, 0.0 end
    local sh = shake
    sh.impulse = math.max(sh.impulse - SHAKE.decay * dt, 0.0)
    sh.cool = math.max(sh.cool - dt, 0.0)
    local inAir = IsEntityInAir(veh)
    if not sh.ground and not inAir then sh.impulse = sh.impulse + SHAKE.land end
    sh.ground = not inAir
    -- A crash: a sudden change of speed (not scaled by dt, so a hitch cannot hide one) or a drop in body health.
    local sev = 0.0
    if sh.pvx and dt < 0.12 then
        local dv = math.sqrt((s.vx - sh.pvx) ^ 2 + (s.vy - sh.pvy) ^ 2 + (s.vz - sh.pvz) ^ 2)
        sev = M.clamp((dv - SHAKE.dv) / SHAKE.dvFull, 0.0, 1.0)
    end
    sh.pvx, sh.pvy, sh.pvz = s.vx, s.vy, s.vz
    local hp = GetVehicleBodyHealth(veh)
    if hp and sh.hp and sh.hp - hp > 0.0 then
        sev = math.max(sev, M.clamp((sh.hp - hp - SHAKE.hp) / SHAKE.hpFull, 0.0, 1.0))
    end
    sh.hp = hp
    if sev > 0.0 and sh.cool <= 0.0 then
        sh.impulse = sh.impulse + SHAKE.crash * sev
        sh.cool = 0.2
    end
    sh.impulse = math.min(sh.impulse, SHAKE.maxImpulse)
    local speed = math.sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
    local visual = M.clamp(speed / 62.0, 0.0, 1.0) ^ 1.35
    local mag = SHAKE.speed * visual
    if inAir then mag = mag * SHAKE.air end
    mag = M.clamp((mag + sh.impulse) * scale, 0.0, SHAKE.max)
    sh.mag = M.damp(sh.mag, mag, 14.0, dt)
    sh.phase = sh.phase + (SHAKE.baseFreq + SHAKE.speedFreq * visual) * dt
    if sh.mag < 1e-4 then return 0.0, 0.0, 0.0 end
    return M.shake(sh.phase, sh.mag, 1.0)
end

-- ============================================
-- Cinematic: the director
-- ============================================
--
-- Every frame each moment below bids for the camera from what the car is doing; the highest bid takes it once the
-- moment holding it has had HOLD seconds, and only by MARGIN, so two close bids do not flick it back and forth. A
-- moment whose bid stops keeps the camera for its LINGER first. The shot then eases to that moment's framing, scaled
-- by how strongly it bids: Consistent's chase shot times `dist`, `height` and `stiff`, plus `fov`, with its own
-- `slip`, `tilt` and `ahead` (client/cam_shots.lua's chase).
--
--   jump     in the air a moment: back and up, a little narrower, on loose springs, so the landing is in frame
--   burnout  stopped first, then the wheels spinning: lower and closer, wider
--   drift    sliding: further back and on softer springs, following where the car is going, looking ahead
--   surge    a hard pull at speed (nitrous): closer and much wider, for a moment
--   cruise   anything else: Consistent's framing
--
-- A bump under 0.2 s in the air is not a jump, and a slide that swaps sides keeps the drift framing rather than
-- cutting back to cruise for a moment.

local FRAMING = {
    cruise  = { dist = 1.00, height = 1.00, fov = 0.0,  slip = 0.35, tilt = 1.5,  ahead = 3.5, stiff = 1.00 },
    surge   = { dist = 0.80, height = 0.97, fov = 15.0, slip = 0.20, tilt = 1.5,  ahead = 5.0, stiff = 1.14 },
    drift   = { dist = 1.10, height = 0.95, fov = 4.0,  slip = 0.85, tilt = 1.0,  ahead = 5.5, stiff = 0.60 },
    jump    = { dist = 1.37, height = 1.35, fov = -3.0, slip = 0.10, tilt = -2.0, ahead = 3.0, stiff = 0.37 },
    burnout = { dist = 0.86, height = 0.70, fov = 6.0,  slip = 0.05, tilt = 0.5,  ahead = 1.5, stiff = 0.93 },
}
local HOLD, MARGIN = 0.8, 0.12
local LINGER = { jump = 0.3, burnout = 0.4, drift = 0.5, surge = 0.5, cruise = 0.0 }
-- How fast the framing eases to a moment's, per second.
local BLEND, BLEND_FAST = 2.2, { jump = 4.5, surge = 3.5 }

--- What each moment bids this frame (absent = not bidding) and how strongly (0..1), and the slip in degrees.
local function bids(veh, s, dt)
    local speed = math.sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
    dir.air = IsEntityInAir(veh) and dir.air + dt or 0.0
    dir.still = speed < 1.5 and dir.still + dt or 0.0
    if dir.speed then dir.accel = M.damp(dir.accel, (speed - dir.speed) / dt, 6.0, dt) end
    dir.speed = speed
    local top = GetVehicleEstimatedMaxSpeed(veh)
    if not top or top < 5.0 then top = 50.0 end
    local share = M.clamp(speed / top, 0.0, 1.0)

    -- Slip: where it is going against where it points, going forwards (reversing is not a slide).
    local slip = 0.0
    local fx, fy = -math.sin(math.rad(s.h)), math.cos(math.rad(s.h))
    if speed > 1.0 and (s.vx * fx + s.vy * fy) > 0.0 then
        slip = M.clamp(M.wrap180(math.deg(math.atan(-s.vx, s.vy)) - s.h), -120.0, 120.0)
    end

    -- Wheelspin: the fastest wheel past the ground speed. A burnout starts only from a stop (a spin-out passing
    -- through low speed is not one) and lasts while the wheels keep spinning and the car has not got away.
    local spin = 0.0
    for i = 0, (GetVehicleNumberOfWheels(veh) or 0) - 1 do
        spin = math.max(spin, math.abs(GetVehicleWheelSpeed(veh, i) or 0.0))
    end
    spin = math.max(spin - speed, 0.0)
    if not dir.burning and spin > 5.0 and dir.still >= 0.4 then
        dir.burning = true
    elseif dir.burning and (spin < 3.0 or speed > 6.0) then
        dir.burning = false
    end

    local b, k = { cruise = 0.1 }, { cruise = 1.0 }
    if dir.air >= 0.2 then b.jump, k.jump = 1.0, M.clamp(0.4 + share, 0.0, 1.0) end
    if dir.burning then b.burnout, k.burnout = 0.9, M.clamp((spin - 3.0) / 10.0, 0.3, 1.0) end
    local a = math.abs(slip)
    if speed > 7.0 and a > 12.0 then
        b.drift = 0.3 + 0.55 * M.clamp((a - 12.0) / 28.0, 0.0, 1.0)
        k.drift = M.clamp((a - 8.0) / 30.0, 0.2, 1.0)
    end
    -- Harder than an ordinary launch pulls, so it is nitrous (or something as strong), not just a quick car.
    if speed > 12.0 and dir.accel > 6.5 then
        b.surge = 0.5 + 0.25 * M.clamp((dir.accel - 6.5) / 6.0, 0.0, 1.0)
        k.surge = M.clamp((dir.accel - 5.0) / 8.0, 0.2, 1.0)
    end
    return b, k
end

--- The moment that has the camera now, after this frame's bids `b`.
local function choose(b, dt)
    dir.t = dir.t + dt
    local cur = dir.name
    local curBid = b[cur] or 0.0
    if curBid > 0.0 then dir.lastOn = dir.t end
    local best, bestBid = cur, curBid
    for name, v in pairs(b) do
        if v > bestBid then best, bestBid = name, v end
    end
    if best == cur then return cur end
    local gone = curBid <= 0.0 and dir.t - dir.lastOn >= (LINGER[cur] or 0.0)
    local beaten = dir.t - dir.since >= HOLD and bestBid > curBid + MARGIN
    if best == 'jump' or gone or beaten then   -- a jump never waits: the landing must be in frame
        dir.name, dir.since, dir.lastOn = best, dir.t, dir.t
    end
    return dir.name
end

--- Consistent's chase `shot`, directed: eased towards the framing of the moment that has the camera.
local function direct(veh, s, shot, dt)
    local b, k = bids(veh, s, dt)
    local name = choose(b, dt)
    if k[name] then dir.k = k[name] end   -- a lingering moment keeps the strength it last had
    local C, F = FRAMING.cruise, FRAMING[name]
    if not dir.f then
        dir.f = {}
        for key, v in pairs(C) do dir.f[key] = v end
    end
    local rate = BLEND_FAST[name] or BLEND
    local f = dir.f
    for key, v in pairs(C) do f[key] = M.damp(f[key], M.lerp(v, F[key], dir.k), rate, dt) end
    shot.dist, shot.distAdd, shot.height = shot.dist * f.dist, shot.distAdd * f.dist, shot.height * f.height
    shot.fov, shot.stiff, shot.turnRate = shot.fov + f.fov, shot.stiff * f.stiff, shot.turnRate * f.stiff
    shot.slip, shot.tilt, shot.ahead = f.slip, f.tilt, f.ahead
end

local function frame(veh, dt)
    ---@cast cam -nil   -- (only with the camera up: the loop below)
    run.subjects.veh = veh
    run.frame = run.frame + 1
    local s = CamShots.subject(run, 'veh')
    if not s then return end

    local view = VIEWS[GetFollowVehicleCamViewMode()] or VIEWS[1]
    local scale = M.clamp((s.max.y - s.min.y) / CAR_LENGTH, 0.75, 2.6)
    local shot = {
        dist = view.dist * scale, height = view.height * math.sqrt(scale), ahead = 3.5, slip = 0.35,
        stiff = view.stiff, turnRate = 7.2, fov = view.fov, fovAdd = 10.0, distAdd = 1.1 * scale,
    }
    if PlayerPrefs.get(STYLE) == 'cinematic' then
        direct(veh, s, shot, dt)
    elseif dir.f then
        directorReset()   -- back to Consistent: a later Cinematic starts from the chase framing
    end
    if enterT < 1.0 then
        enterT = math.min(enterT + dt / ENTER_S, 1.0)
        local b = enterT * enterT * (3.0 - 2.0 * enterT)
        shot.stiff = M.lerp(ENTER_RATE, shot.stiff, b)
        shot.turnRate = M.lerp(ENTER_RATE, shot.turnRate, b)
    end

    freeLook(dt)
    local p = CamShots.chase(shot, s, mem, dt, 'veh', look)
    local sp, sr, sy = shakeFor(veh, s, dt)
    SetCamCoord(cam, p.x, p.y, p.z)
    SetCamRot(cam, p.pitch + sp, (p.roll or 0.0) + sr, p.yaw + sy, 2)
    SetCamFov(cam, p.fov)
    lastYaw = p.yaw
end

CreateThread(function()
    local upFrames = 0
    while true do
        local veh, why = wanted()
        if veh and not cam and GetGameTimer() - blockedAt < AGAIN_MS then veh = nil end
        if veh then
            if not cam then
                begin()
                upFrames = 0
            end
            ---@cast cam -nil   -- (begun)
            upFrames = upFrames + 1
            if upFrames > 3 and GetRenderingCam() == -1 then
                -- Script cameras were turned off under it: start again from GTA's camera.
                DestroyCam(cam, false)
                cam = nil
                blockedAt = GetGameTimer()
            else
                local dt = GetFrameTime()
                if dt <= 0.0 then dt = 1.0 / 60.0 end
                frame(veh, math.min(dt, 0.25))
            end
            Wait(0)
        else
            if cam then
                finish(why)
                blockedAt = GetGameTimer()
            elseif why and why ~= 'off' then
                blockedAt = GetGameTimer()
            end
            -- Polled faster while waiting out AGAIN_MS.
            Wait(why == nil and 50 or 250)
        end
    end
end)

-- A restart mid-drive gives GTA its camera back at once.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not cam then return end
    RenderScriptCams(false, false, 0, true, true)
    DestroyCam(cam, false)
    cam = nil
end)
