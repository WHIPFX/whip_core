-- ============================================
-- Camera API — client/camera.lua
-- Scripted camera playback for gameplay sequences.
-- Exports: PlayCamera, PlayCameraPath, PlayCameraSequence, OrbitCamera, StopCamera, IsCameraActive
-- ============================================
--
-- One scripted camera at a time, and whose it is. PlayCamera holds one shot; everything that moves —
-- a path, a timeline from the Camera Creator, an orbit round a car — is a SEQUENCE
-- (shared/cam_sequence.lua), played by Camera.PlaySequence below.

Camera = {}

-- Active camera state
---@type integer|nil
local _cam = nil   -- set whenever _active is
local _active = false
local _currentFilter = 'none'
-- The room the camera is in is kept right for the game while a sequence plays (client/viewport_room.lua):
-- a camera that cuts or glides into an interior crosses no doorway, and the game would cull the room.
local _following = false

local RESOURCE = GetCurrentResourceName()

--- Whose camera it is, and how it wants to hand back to gameplay.
---
--- The owner: the camera is released when its owner stops (cleanup at the bottom), and StopCamera
--- from another resource leaves it. `transitionOut`: how Stop eases back to gameplay.
local _owner    = nil
local _transOut = 0

--- Which camera is the current one. A loop remembers the number it started with and stops the
--- moment another camera replaces its own (or it would steer, and stop, the replacement).
local _gen = 0

-- ============================================
-- Timecycle Filters
-- ============================================

Camera.Filters = {
    'none',
    'scanline_cam',
    'CAMERA_secuirity',
    'CAMERA_secuirity_FUZZ',
    'heliGunCam',
    'NG_filmic04',
    'NG_filmic08',
    'cinema',
    'underwater',
    'Forest',
    'Tunnel',
    'phone_cam1',
    'phone_cam2',
}

local function ApplyFilter(name)
    -- The same filter again changes nothing (PlayPath asks every frame; re-setting could flicker).
    if (name or 'none') == _currentFilter then return end
    if _currentFilter ~= 'none' then
        ClearTimecycleModifier()
    end
    _currentFilter = name or 'none'
    if _currentFilter ~= 'none' then
        SetTimecycleModifier(_currentFilter)
        SetTimecycleModifierStrength(1.0)
    end
end

local function ClearFilter()
    if _currentFilter ~= 'none' then
        ClearTimecycleModifier()
        _currentFilter = 'none'
    end
end

-- ============================================
-- Guards
-- ============================================

--- A position or rotation: anything with numeric x, y and z.
local function isVec(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return false end
    return tonumber(v.x) ~= nil and tonumber(v.y) ~= nil and tonumber(v.z) ~= nil
end

--- May `owner` put a camera up now? Another resource's camera is busy, the way a dialog is. A
--- resource may replace its OWN camera (newest wins), and whip_core may replace any. Stops the camera
--- being replaced.
---@return boolean ok
---@return string|nil why
local function takeCamera(owner)
    if not _active then return true end
    if owner ~= _owner and owner ~= RESOURCE then return false, 'busy' end
    Camera.Stop()
    return true
end

--- Run a camera's per-frame loop, handing the player back to gameplay if it throws (a path has no
--- exit key).
local function runLoop(gen, loop, ...)
    local ok, err = pcall(loop, gen, ...)
    if not ok then
        print(('[whip_core:camera] a camera loop failed (%s), returning to gameplay: %s')
            :format(tostring(_owner), tostring(err)))
        if _active and _gen == gen then Camera.Stop() end
    end
end

-- ============================================
-- PlayCamera — Single Static Camera
-- ============================================

--- Play a single static camera. `true` once it has ended (or started, with `async`), or
--- `false, why`: 'busy' while another resource's camera is up, or what is wrong with `opts`.
--- @param opts table { pos, rot, fov, filter, canLook, canMove, exitKey, transitionIn, transitionOut, async }
--- @param owner string|nil — the resource playing it (the export fills it in)
--- @return boolean ok
--- @return string|nil why
function Camera.Play(opts, owner)
    opts = type(opts) == 'table' and opts or {}
    owner = owner or RESOURCE
    if opts.pos ~= nil and not isVec(opts.pos) then return false, 'pos must be a vector3' end
    if opts.rot ~= nil and not isVec(opts.rot) then return false, 'rot must be a vector3' end
    if opts.fov ~= nil and not tonumber(opts.fov) then return false, 'fov must be a number' end
    -- The transitions too, before anything is taken (a bad one would leak an active camera Stop
    -- cannot end). Numbers, or nothing.
    if opts.transitionIn ~= nil and not tonumber(opts.transitionIn) then return false, 'transitionIn must be a number of milliseconds' end
    if opts.transitionOut ~= nil and not tonumber(opts.transitionOut) then return false, 'transitionOut must be a number of milliseconds' end
    local took, busy = takeCamera(owner)
    if not took then return false, busy end

    local pos = opts.pos or GetGameplayCamCoord()
    local rot = opts.rot or vector3(0.0, 0.0, 0.0)
    local fov = opts.fov or 60.0
    local filter = opts.filter or 'none'
    local transIn = tonumber(opts.transitionIn) or 0
    local canLook = opts.canLook or false
    local canMove = opts.canMove or false
    local exitKey = opts.exitKey ~= false
    _owner    = owner
    _transOut = tonumber(opts.transitionOut) or 0

    _cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(_cam, pos.x, pos.y, pos.z)
    SetCamRot(_cam, rot.x, rot.y, rot.z, 2)
    SetCamFov(_cam, fov)
    SetCamActive(_cam, true)
    RenderScriptCams(true, transIn > 0, transIn, true, false)
    SetFocusPosAndVel(pos.x, pos.y, pos.z, 0.0, 0.0, 0.0)
    ApplyFilter(filter)
    _active = true

    -- What the camera reads, held off for the game until Camera.Stop: Esc (the exit key), the mouse
    -- (looking), the walk keys, jump and duck (moving, up and down).
    local controls = {}
    if exitKey then controls[#controls + 1] = 200 end
    if canLook then controls[#controls + 1] = 1; controls[#controls + 1] = 2 end
    if canMove then for _, c in ipairs({ 30, 31, 22, 36 }) do controls[#controls + 1] = c end end
    if #controls > 0 then ControlBlocks.hold('camera', { controls = controls }) end

    -- Blocking unless asked not to: the caller's thread waits until the camera ends (a cutscene
    -- script). `async = true` gives the loop a thread of its own.
    _gen = _gen + 1
    local gen = _gen
    if opts.async then
        CreateThread(function() runLoop(gen, Camera._playLoop, canLook, canMove, exitKey) end)
        return true
    end
    runLoop(gen, Camera._playLoop, canLook, canMove, exitKey)
    return true
end

--- The static camera's per-frame part: the exit key, looking and moving. Returns when it ends, or
--- when another camera replaces this one.
function Camera._playLoop(gen, canLook, canMove, exitKey)
    if canLook or canMove or exitKey then
        while _active and _gen == gen do
            ---@cast _cam -nil
            if exitKey then
                if IsDisabledControlJustPressed(0, 200) then
                    Camera.Stop()
                    return
                end
            end
            if canLook then
                local camR = GetCamRot(_cam, 2)
                local mx = GetDisabledControlNormal(0, 1) * 4.0
                local my = GetDisabledControlNormal(0, 2) * 4.0
                SetCamRot(_cam, math.max(-89.0, math.min(89.0, camR.x - my)), 0.0, camR.z - mx, 2)
            end
            if canMove then
                local camR = GetCamRot(_cam, 2)
                local camC = GetCamCoord(_cam)
                local pitch = math.rad(camR.x)
                local yaw = math.rad(camR.z)
                local speed = 0.5
                local dx, dy, dz = 0.0, 0.0, 0.0
                if IsDisabledControlPressed(0, 32) then
                    dx = dx - math.sin(yaw) * math.cos(pitch) * speed
                    dy = dy + math.cos(yaw) * math.cos(pitch) * speed
                    dz = dz + math.sin(pitch) * speed
                end
                if IsDisabledControlPressed(0, 33) then
                    dx = dx + math.sin(yaw) * math.cos(pitch) * speed
                    dy = dy - math.cos(yaw) * math.cos(pitch) * speed
                    dz = dz - math.sin(pitch) * speed
                end
                if IsDisabledControlPressed(0, 35) then
                    dx = dx + math.cos(yaw) * speed
                    dy = dy + math.sin(yaw) * speed
                end
                if IsDisabledControlPressed(0, 34) then
                    dx = dx - math.cos(yaw) * speed
                    dy = dy - math.sin(yaw) * speed
                end
                if IsDisabledControlPressed(0, 22) then dz = dz + speed end
                if IsDisabledControlPressed(0, 36) then dz = dz - speed end
                local newC = vector3(camC.x + dx, camC.y + dy, camC.z + dz)
                SetCamCoord(_cam, newC.x, newC.y, newC.z)
                SetFocusPosAndVel(newC.x, newC.y, newC.z, 0.0, 0.0, 0.0)
            end
            Wait(0)
        end
    end
end

-- ============================================
-- PlayCameraPath — Multi-Point Camera Path
-- ============================================

--- Play a camera path with interpolation or cycling. `true` once it has ended (or started, with
--- `async`), or `false, why`: 'busy' while another resource's camera is up, or what is wrong with
--- `opts` — checked BEFORE any camera exists (a point without pos/rot, or duration = 0).
--- @param opts table { points, mode, duration, easing, loop, cycleDuration, transitionIn, transitionOut, async }
--- @param owner string|nil — the resource playing it (the export fills it in)
--- @return boolean ok
--- @return string|nil why
function Camera.PlayPath(opts, owner)
    opts = type(opts) == 'table' and opts or {}
    owner = owner or RESOURCE

    local points = opts.points
    if type(points) ~= 'table' or #points < 2 then return false, 'a path needs at least 2 points' end
    for i = 1, #points do
        local p = points[i]
        if type(p) ~= 'table' or not isVec(p.pos) or not isVec(p.rot) then
            return false, ('point %d needs a pos and a rot (vector3)'):format(i)
        end
        if p.fov ~= nil and not tonumber(p.fov) then return false, ('point %d: fov must be a number'):format(i) end
    end
    local mode = opts.mode or 'interpolate'
    if mode ~= 'interpolate' and mode ~= 'cycle' then return false, "mode is 'interpolate' or 'cycle'" end
    local duration = tonumber(opts.duration or 10000)
    if not duration or duration <= 0 then return false, 'duration must be above 0 (milliseconds)' end
    local cycleDur = tonumber(opts.cycleDuration or 3000)
    if not cycleDur or cycleDur <= 0 then return false, 'cycleDuration must be above 0 (milliseconds)' end
    -- The transitions, checked before anything is taken (as Camera.Play).
    if opts.transitionIn ~= nil and not tonumber(opts.transitionIn) then return false, 'transitionIn must be a number of milliseconds' end
    if opts.transitionOut ~= nil and not tonumber(opts.transitionOut) then return false, 'transitionOut must be a number of milliseconds' end

    -- A path is a sequence: glides through the points at an even speed with the path's ease over the
    -- whole of it, or cuts from point to point (shared/cam_sequence.lua, CamSequence.fromPath).
    local seq, why = CamSequence.fromPath(opts)
    if not seq then return false, why end
    return Camera.PlaySequence(seq, {
        transitionIn = opts.transitionIn, transitionOut = opts.transitionOut, async = opts.async,
    }, owner)
end

-- ============================================
-- PlayCameraSequence — a timeline of shots
-- ============================================
--
-- What the Camera Creator makes, played: fixed shots, orbits, chases, mounted and tracking shots, and
-- how the camera moves between them (shared/cam_sequence.lua says what a sequence holds).

-- 2.39:1 bars on a 16:9 screen, as a share of its height each.
local LETTERBOX = 0.128

--- This frame's cinema bars, and no GTA HUD under them. The Camera Creator draws them too.
function Camera.letterbox()
    HideHudAndRadarThisFrame()
    DrawRect(0.5, LETTERBOX * 0.5, 1.0, LETTERBOX, 0, 0, 0, 255)
    DrawRect(0.5, 1.0 - LETTERBOX * 0.5, 1.0, LETTERBOX, 0, 0, 0, 255)
end

-- A viewer turning an orbit (`control`): nfsmw's feel. Look input turns it, the wheel (or a pad's
-- triggers) zooms, and it eases after the hand rather than jumping with it.
local CTL_YAW, CTL_PITCH = 16.0, 10.0          -- degrees per unit of mouse input
local CTL_PAD_YAW, CTL_PAD_PITCH = 150.0, 75.0 -- degrees a second, a stick all the way over
local CTL_PAD_DEAD = 0.12
local CTL_RATE = 12.0                          -- how quickly the view follows the hand
local CTL_ZOOM_STEP, CTL_ZOOM_MIN, CTL_ZOOM_MAX = 0.1, 0.35, 3.0
local CTL_PITCH_MIN, CTL_PITCH_MAX = -70.0, 75.0

--- The viewer's turn and zoom this frame, eased (run.ctl is what the orbit shots add).
local function steer(run, dt)
    local c = run.ctl
    local pad = WhipLastInputIsPad()
    local lr, ud = GetDisabledControlNormal(0, 1), GetDisabledControlNormal(0, 2)
    if pad then
        if math.abs(lr) < CTL_PAD_DEAD then lr = 0.0 end
        if math.abs(ud) < CTL_PAD_DEAD then ud = 0.0 end
        c.tYaw = c.tYaw - lr * CTL_PAD_YAW * dt
        c.tPitch = c.tPitch + ud * CTL_PAD_PITCH * dt
        -- LT out, RT in. The frontend pair only, not WhipPadTrigger: the camera's block holds 207 / 208 off, and on
        -- foot or in a car the others are a gun's or the car's, which this does not stop.
        local pull = GetDisabledControlNormal(0, 207) - GetDisabledControlNormal(0, 208)
        if math.abs(pull) > 0.08 then c.tZoom = c.tZoom * (1.0 + pull * dt * 1.4) end
    else
        -- A mouse's reading is already a distance moved this frame: not scaled by the frame.
        c.tYaw = c.tYaw - lr * CTL_YAW
        c.tPitch = c.tPitch + ud * CTL_PITCH
        if IsDisabledControlJustPressed(0, 241) then c.tZoom = c.tZoom * (1.0 - CTL_ZOOM_STEP) end
        if IsDisabledControlJustPressed(0, 242) then c.tZoom = c.tZoom * (1.0 + CTL_ZOOM_STEP) end
    end
    c.tPitch = CamMath.clamp(c.tPitch, CTL_PITCH_MIN - c.basePitch, CTL_PITCH_MAX - c.basePitch)
    c.tZoom = CamMath.clamp(c.tZoom, CTL_ZOOM_MIN, CTL_ZOOM_MAX)
    c.yaw = CamMath.damp(c.yaw, c.tYaw, CTL_RATE, dt)
    c.pitch = CamMath.damp(c.pitch, c.tPitch, CTL_RATE, dt)
    c.zoom = CamMath.damp(c.zoom, c.tZoom, CTL_RATE, dt)
end

--- A picture onto the camera: its shake, its filter, the bars, and the room it is in.
local function show(pose, fx, tMs, letterbox)
    ---@cast _cam -nil
    local sp, sr, sy = 0.0, 0.0, 0.0
    if fx and fx.shake then sp, sr, sy = CamMath.shake(tMs / 1000.0, fx.shake.amount, fx.shake.freq) end
    SetCamCoord(_cam, pose.x, pose.y, pose.z)
    SetCamRot(_cam, pose.pitch + sp, (pose.roll or 0.0) + sr, pose.yaw + sy, 2)
    SetCamFov(_cam, pose.fov or 50.0)
    SetFocusPosAndVel(pose.x, pose.y, pose.z, 0.0, 0.0, 0.0)
    ViewportRoom.follow(vector3(pose.x, pose.y, pose.z))
    ApplyFilter(fx and fx.filter or 'none')
    if letterbox then Camera.letterbox() end
end

-- Saved sequences by name, as the server last answered (server/camera_sequences.lua); forgotten when one
-- is saved again or deleted.
local savedCache = {}
RegisterNetEvent('whip_core:client:camseqChanged', function(name)
    if type(name) == 'string' then savedCache[name] = nil end
end)

--- A saved sequence by name: from the server the first time, kept after. Yields. nil and why when there
--- is none.
---@param name string
---@return table|nil seq, string|nil why
function Camera.saved(name)
    if savedCache[name] then return savedCache[name] end
    local data, why = Callback('whip_core:camseq:fetch', name)
    if type(data) ~= 'table' then return nil, why or ('there is no camera sequence called ' .. name) end
    savedCache[name] = data
    return data
end

--- Play a sequence. `true` once it has ended (or started, with `async`), or `false, why`: 'busy' while
--- another resource's camera is up, what is wrong with it (CamSequence.clean), or a subject not there.
---@param seq table|string  a sequence (shared/cam_sequence.lua), or the name one was saved under in the
---                         Camera Creator (fetched from the server: call it from a thread that can wait)
---@param opts table|nil {
---   subjects       { [name] = entity | { x, y, z, h } }: what the sequence's subject names stand for
---                  ('player' and 'vehicle' need nothing)
---   loop, letterbox  override the sequence's own
---   speed          1 is as made; 0.5 half speed
---   startAt        milliseconds into it to start from
---   hold           stay on the last moment until stopped, instead of ending (an orbit left up)
---   control        the viewer turns and zooms its orbits (mouse, wheel; a pad's stick and triggers)
---   exitKey        Esc (B) ends it (default off)
---   transitionIn, transitionOut   milliseconds to ease from and back to the game's camera
---   async          return at once; the sequence plays in a thread of its own
--- }
---@param owner string|nil  the resource playing it (the export fills it in)
---@return boolean ok
---@return string|nil why
function Camera.PlaySequence(seq, opts, owner)
    opts = type(opts) == 'table' and opts or {}
    owner = owner or RESOURCE
    if type(seq) == 'string' then
        local found, missing = Camera.saved(seq)
        if not found then return false, missing end
        seq = found
    end
    local clean, why = CamSequence.clean(seq)
    if not clean then return false, why end
    if opts.transitionIn ~= nil and not tonumber(opts.transitionIn) then return false, 'transitionIn must be a number of milliseconds' end
    if opts.transitionOut ~= nil and not tonumber(opts.transitionOut) then return false, 'transitionOut must be a number of milliseconds' end
    local speed = tonumber(opts.speed or 1.0)
    if not speed or speed < 0.05 or speed > 20.0 then return false, 'speed must be between 0.05 and 20' end
    local startAt = tonumber(opts.startAt or 0) or 0
    if opts.subjects ~= nil and type(opts.subjects) ~= 'table' then return false, 'subjects must be a table of names' end
    if opts.loop ~= nil then clean.loop = opts.loop == true end
    if opts.letterbox ~= nil then clean.letterbox = opts.letterbox == true end

    local run = CamSequence.newRun(clean, opts.subjects)
    if not CamSequence.captureAnchor(run) then return false, ('its anchor %s is not there'):format(clean.anchor) end
    if opts.control then run.ctl = { yaw = 0.0, pitch = 0.0, zoom = 1.0, tYaw = 0.0, tPitch = 0.0, tZoom = 1.0, basePitch = 0.0 } end
    -- The first picture before anything is taken: a sequence with nothing to show starts nothing.
    local first = CamSequence.evaluate(run, startAt, 1.0)
    if not first then return false, 'none of its subjects is there' end
    if run.ctl then
        local k1 = clean.keys[1].shot
        run.ctl.basePitch = k1.kind == 'orbit' and (k1.pitch or 0.0) or 0.0
    end

    local took, busy = takeCamera(owner)
    if not took then return false, busy end
    _owner    = owner
    _transOut = tonumber(opts.transitionOut) or 0
    local transIn = tonumber(opts.transitionIn) or 0

    _cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', first.x, first.y, first.z,
        first.pitch, first.roll or 0.0, first.yaw, first.fov or 50.0, true, 2)
    SetCamActive(_cam, true)
    RenderScriptCams(true, transIn > 0, transIn, true, false)
    _active, _following = true, true

    -- What the camera reads, held off for the game: Esc (the exit key), and looking and the wheel (control).
    local controls, groups = {}, nil
    if opts.exitKey then controls[#controls + 1] = 200; controls[#controls + 1] = 202 end
    if opts.control then
        groups = { 'look' }
        for _, c in ipairs({ 241, 242, 207, 208 }) do controls[#controls + 1] = c end
    end
    if #controls > 0 or groups then ControlBlocks.hold('camera', { groups = groups, controls = controls }) end

    _gen = _gen + 1
    local gen = _gen
    if opts.async then
        CreateThread(function() runLoop(gen, Camera._sequenceLoop, run, speed, startAt, opts) end)
        return true
    end
    runLoop(gen, Camera._sequenceLoop, run, speed, startAt, opts)
    return true
end

--- A sequence's per-frame part: the time, the picture, and the end (or the loop, or holding on).
function Camera._sequenceLoop(gen, run, speed, startAt, opts)
    local seq = run.seq
    local started = GetGameTimer() - startAt / speed
    local last = GetGameTimer()
    while _active and _gen == gen do
        local now = GetGameTimer()
        local dt = math.min((now - last) / 1000.0, 0.25)
        last = now
        local t = (now - started) * speed
        if t > seq.length then
            if seq.loop and seq.length > 0 then
                started, t = now, 0.0
            elseif not opts.hold then
                break
            end
        end
        if run.ctl then steer(run, dt) end
        local pose, fx = CamSequence.evaluate(run, t, dt)
        if pose then show(pose, fx, t, seq.letterbox) end
        if opts.exitKey and (IsDisabledControlJustPressed(0, 200) or IsDisabledControlJustPressed(0, 202)) then
            Camera.Stop()
            return
        end
        Wait(0)
    end
    -- Only the sequence's OWN camera is stopped at its end — never one that replaced it.
    if _active and _gen == gen then Camera.Stop() end
end

--- An orbit round anything, left up until stopped: a car in a showroom, a character, a prop, a place.
--- The viewer turns and zooms it unless `control = false`.
---@param target number|table  an entity, or a place { x, y, z, h }
---@param opts table|nil  the orbit's own numbers (yaw, pitch, fit or dist, aim, look, fov, turn, clear) and
---                       control, exitKey, letterbox, transitionIn, transitionOut (default 500 each)
function Camera.Orbit(target, opts, owner)
    opts = type(opts) == 'table' and opts or {}
    if type(target) ~= 'number' and type(target) ~= 'table' and type(target) ~= 'vector3' and type(target) ~= 'vector4' then
        return false, 'orbit what? an entity, or a place { x, y, z }'
    end
    local shot = { kind = 'orbit', subject = 'subject', yaw = opts.yaw or 35.0, pitch = opts.pitch or 12.0,
                   fit = opts.fit, dist = opts.dist, aim = opts.aim, look = opts.look, fov = opts.fov or 40.0,
                   turn = opts.turn, clear = opts.clear }
    if not shot.fit and not shot.dist then shot.fit = 1.3 end
    return Camera.PlaySequence({ keys = { { t = 0, shot = shot } }, letterbox = opts.letterbox == true }, {
        subjects = { subject = target }, control = opts.control ~= false, hold = true, exitKey = opts.exitKey == true,
        transitionIn = opts.transitionIn or 500, transitionOut = opts.transitionOut or 500, async = true,
    }, owner)
end

-- ============================================
-- StopCamera / IsCameraActive
-- ============================================

--- Stop the camera and hand back to gameplay, easing over `transitionOut` ms when the camera asked
--- for one.
--- @param owner string|nil — who is asking; another resource's camera is left alone (whip_core may stop any)
--- @return boolean stopped
function Camera.Stop(owner)
    if not _active then return false end
    owner = owner or RESOURCE
    if owner ~= RESOURCE and owner ~= _owner then return false end
    _active = false
    ControlBlocks.release('camera')
    ClearFilter()
    if _following then
        _following = false
        ViewportRoom.release()
    end
    if _cam then
        local cam, ease = _cam, _transOut
        _cam = nil
        RenderScriptCams(false, ease > 0, ease, true, false)
        -- Destroyed AFTER the ease: the game blends from this camera to gameplay, and destroying the
        -- camera it is blending from cuts the blend short.
        if ease > 0 then
            SetTimeout(ease, function() DestroyCam(cam, false) end)
        else
            DestroyCam(cam, false)
        end
    end
    ClearFocus()
    _owner, _transOut = nil, 0
    return true
end

function Camera.IsActive()
    return _active
end

-- ============================================
-- Exports
-- ============================================

-- The caller is read at the boundary: the camera is theirs, and only they may stop it.
exports('PlayCamera', function(opts) return Camera.Play(opts, GetInvokingResource() or RESOURCE) end)
exports('PlayCameraPath', function(opts) return Camera.PlayPath(opts, GetInvokingResource() or RESOURCE) end)
exports('PlayCameraSequence', function(sequence, opts) return Camera.PlaySequence(sequence, opts, GetInvokingResource() or RESOURCE) end)
exports('OrbitCamera', function(target, opts) return Camera.Orbit(target, opts, GetInvokingResource() or RESOURCE) end)
exports('StopCamera', function() return Camera.Stop(GetInvokingResource() or RESOURCE) end)
exports('IsCameraActive', Camera.IsActive)

-- ============================================
-- Cleanup
-- ============================================

-- whip_core stopping releases the camera; so does its OWNER stopping.
AddEventHandler('onResourceStop', function(res)
    if res == RESOURCE or (_active and res == _owner) then
        Camera.Stop()
    end
end)
