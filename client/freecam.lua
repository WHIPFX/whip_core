-- ============================================
-- FREE CAM
-- A detached camera you fly with WASD, and the one
-- implementation of it.
-- ============================================
--
-- One camera for noclip (tools/noclip.lua) and the furnisher. What the two callers disagree about is
-- small and lives in `opts`, plus one runtime switch:
--
--   noclip      plain scroll zooms, Shift+scroll changes fly speed, and exiting drops the ped
--               wherever the camera ended up, with the car they sit in (`vehicle`). That is what
--               noclip IS. It listens the whole time.
--   furnisher   the wheel as noclip has it, but it listens only while the right mouse button is
--               down (let go, the wheel scrolls its catalog), because it holds NUI focus and the
--               pointer is also picking things out of a catalog (FreeCam.setInputEnabled); exiting
--               leaves the player where they were standing, because they never went anywhere.
--
-- Everything else (the damping, the 89-degree pitch clamp, the FOV lerp, the ped nudge that keeps
-- the world streaming) is the same for both and is not configurable.

FreeCam = {}

-- Movement constants: the FEEL of the camera. Changing one changes every caller, which is the point
-- of them living here.
--
-- tools/camera.lua carries its own identical copies deliberately: the camera creator composes and
-- saves named poses for cutscenes, with its own reasons to diverge.
local CC_MOVE_SPEED  = 40.0
local CC_DAMPING     = 6.0
local CC_SENSITIVITY = 4.0
local CC_FAST_MULT   = 3.0
local CC_FOV_MIN     = 10.0
local CC_FOV_MAX     = 120.0
local CC_FOV_LERP    = 0.12
local CC_ZOOM_SPEED  = 3.0
local CC_SPEED_MIN   = 0.1
local CC_SPEED_MAX   = 10.0
local CC_SPEED_STEP  = 0.2

local active   = false
local cam      = nil
local velocity = vector3(0.0, 0.0, 0.0)
local startLoop   -- the camera's frame loop, started by FreeCam.start; defined with the loop below
local releaseRoom -- hands the camera's room back to the game; defined with "The room the camera is in"
local speed    = 1.0
local fov      = 60.0
local fovTarget = 60.0
local opts     = {}

-- THE CAMERA'S POSE, AS THIS FILE LAST WROTE IT. Only this file moves the camera (start, setPose, frame
-- and the loop), so a frame works from these rather than asking the game for what it was told, and
-- writes only what changed. fovSet is the lens last written.
local camX, camY, camZ = 0.0, 0.0, 0.0
local camPitch, camRoll, camYaw = 0.0, 0.0, 0.0
local fovSet = nil
local focusX, focusY, focusZ = nil, nil, nil   -- where the streaming focus was last put (nil: put it again)
local function poseAt(x, y, z) camX, camY, camZ = x + 0.0, y + 0.0, z + 0.0 end
local function turnTo(p, r, y) camPitch, camRoll, camYaw = p + 0.0, r + 0.0, y + 0.0 end

--- Is the camera listening to the mouse and the keyboard?
---
--- FOR A CALLER THAT SHARES THE MOUSE WITH A CURSOR. Noclip never does — it owns the screen for as
--- long as it is up — but the housing furnisher holds NUI focus the whole time, so the pointer is
--- doing two jobs: picking a sofa out of a catalog, and turning the room. Right mouse held is which
--- one, and this is the switch it throws.
---
--- ONLY THE READS ARE GATED. Damping, the FOV lerp, the ped nudge and writing the camera all keep
--- running, so releasing the button mid-glide coasts to a stop instead of stopping dead — and a
--- camera that is not listening is still a camera, not a frozen frame.
local inputEnabled = true

--- Held: the caller drives the camera (the Camera Creator looking through its timeline), and the loop
--- neither reads input nor moves it — it only keeps the world streaming and the room right where the
--- caller puts it. See FreeCam.hold and FreeCam.setPose.
local held = false

--- On a controller the sticks read as sticks. The left one
--- flies as far as it is pushed (the keys' reads are all or nothing), the right one looks at a turn rate
--- (a mouse's reading is a distance moved, a stick's is how far over it is), RT and LT fly up and down,
--- and L3 held is fast. Asked for by the caller, never assumed: FreeCam.setPad (the furnisher, the
--- config page's Place camera, each from its own frame), or `pad = 'auto'` at start, which follows the
--- device in hand frame by frame (noclip). `padTriggers` false leaves the triggers to the caller (the
--- furnisher raises and lowers the selection with them).
---
--- Noclip follows the device: on the keys' reads a pad's right stick reads as a mouse (a distance every
--- frame, so it turns faster at a higher frame rate), so with a pad it flies as the furnisher does.
local padMode, padTriggers = false, true
local PAD_DEAD = 0.12          -- a resting stick reads a little off centre
local PAD_LOOK = 140.0         -- degrees a second, the right stick all the way over (at Camera look speed 100%)
local PAD_CURVE = 1.6          -- a light push is slow and exact: a stick's speed grows as push ^ this (the menu circle's)
local PAD_FAST = 209           -- L3 (client/pad.lua)
-- (The triggers: WhipPadTrigger, client/controller.lua.)

-- EACH PLAYER'S OWN (the pause menu's Settings → Server → Controller): how fast a full push looks and flies, as a
-- share of PAD_LOOK and of the fly speed. Kept here as numbers, changed by their rows, so a frame reads no setting.
PlayerPrefs.define({
    key = 'pad.lookSpeed', group = 'Controller', type = 'slider', label = 'Camera look speed',
    help = "How fast the right stick turns a free camera: the Director's world builder, noclip, the Place camera.",
    min = 25, max = 250, step = 5, unit = '%', default = 100,
})
PlayerPrefs.define({
    key = 'pad.moveSpeed', group = 'Controller', type = 'slider', label = 'Camera move speed',
    help = 'How fast the left stick and the triggers fly a free camera. L3 held is still three times that.',
    min = 25, max = 250, step = 5, unit = '%', default = 100,
})
local padLook, padMove = 1.0, 1.0
local function readPadSpeeds()
    padLook = (tonumber(PlayerPrefs.get('pad.lookSpeed')) or 100) / 100
    padMove = (tonumber(PlayerPrefs.get('pad.moveSpeed')) or 100) / 100
end
readPadSpeeds()
PlayerPrefs.onChange('pad.lookSpeed', readPadSpeeds)
PlayerPrefs.onChange('pad.moveSpeed', readPadSpeeds)

--- A stick's axis: 0 inside the dead zone, then from 0 at its edge to 1 at a full push, curved (PAD_CURVE). It used to
--- jump straight to 0.12 past the dead zone and grow evenly, so a small push was never slower than that.
local function padAxis(v)
    local a = v < 0 and -v or v
    if a <= PAD_DEAD then return 0.0 end
    local t = math.min(1.0, (a - PAD_DEAD) / (1.0 - PAD_DEAD)) ^ PAD_CURVE
    return v < 0 and -t or t
end

-- Where the ped was standing when the camera left it.
--
-- KEPT BECAUSE THE PED DOES NOT STAY THERE. The loop nudges it to the camera every hundred frames
-- so the game keeps streaming the world around what is actually on screen — which is invisible and
-- correct for noclip, where the ped was going to end up at the camera anyway. It is NOT correct for
-- a caller that asked not to be moved: without this, closing the furnisher would leave the player
-- standing wherever they last happened to be looking from.
local startCoords = nil
local startHeading = 0.0

-- Look, move, Tab, attack/aim and the wheel, held off for the flight (FreeCam.start, FreeCam.holdControls).
local FREECAM_BLOCK = { groups = { 'look', 'move' }, controls = { 37, 24, 25, 241, 242 } }
-- The same with a car carried (`vehicle`): its driving, getting out, its guns, the radio and the horn too, as the
-- keys that fly the camera also drive, honk and leave a car.
local CARRY_BLOCK = { groups = { 'look', 'move', 'driving', 'vehicleCombat', 'radio' }, controls = { 37, 24, 25, 241, 242, 86 } }
local block = FREECAM_BLOCK   -- the one held for this flight

-- THE CAR THE PLAYER SITS IN, CARRIED (noclip's `vehicle`): it goes where the ped goes, hidden, frozen and
-- without collision for the flight, and the player stays in their seat. nil when none is carried.
local carried = nil   -- { veh, seat, from, heading }

--- The car the ped sits in, if this game may move it (Vehicles.takeControl: never one another player drives).
--- Waits for control.
local function takeCar(ped)
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not Vehicles.takeControl(veh) then return nil end
    local seat = -1
    for s = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if GetPedInVehicleSeat(veh, s) == ped then seat = s break end
    end
    return { veh = veh, seat = seat, from = GetEntityCoords(veh), heading = GetEntityHeading(veh) }
end

--- Hide, freeze and take the collision off the carried car for the flight, or give them back.
local function holdCar(veh, on)
    FreezeEntityPosition(veh, on)
    SetEntityCollision(veh, not on, not on)
    SetEntityVisible(veh, not on, false)
    SetEntityVelocity(veh, 0.0, 0.0, 0.0)
end

--- Give the carried car back to the game: shown, solid, unfrozen, and its physics woken. Unfrozen alone it hung where
--- it was let go, in the air too, until it was driven (the game leaves a frozen car's physics asleep); the small push
--- down starts the fall. Called after the player's own hold is let go: a frozen player in its seat holds it too.
local function letGoCar(veh)
    holdCar(veh, false)
    ActivatePhysics(veh)
    SetEntityVelocity(veh, 0.0, 0.0, -0.01)
end

-- ============================================
-- Enter / exit
-- ============================================

--- Take the camera off the player.
---@param o table|nil {
---   hidePed  boolean   hide and freeze the ped while flying (default true)
---   scroll   string    'fov'  plain scroll zooms, Shift+scroll changes speed (default)
---                      'none' the camera ignores the wheel entirely, for a caller that wants it
---   fov      number    starting field of view (default 60)
---   speed    number    starting speed multiplier (default 1)
---   pedFollows boolean the ped is nudged to the camera every 100 frames to keep the world
---                      streamed (default true). false leaves it where it stands, which is what
---                      the SERVER sees: a caller that is not moving the player must say false,
---                      or a disconnect saves the player wherever the camera was.
---   leash    table     { x, y, z, radius } the camera may not leave this sphere (default none)
---   coords   table     { x, y, z } where the camera starts (default the ped)
---   rot      table     { x, y, z } which way it starts looking (default the gameplay camera's); roll is
---                      dropped, as the camera flies without it
---   pad      string    'auto' the controller's reads while a pad is the device (WhipPadActive), the keys'
---                      and mouse's otherwise, followed every frame (noclip). Default: the keys' reads
---                      until the caller says otherwise (FreeCam.setPad)
---   vehicle  boolean   the car the player sits in goes with them, and they stay in their seat (noclip).
---                      Not one another player drives: the player leaves that one, as on foot. Waits for
---                      control of the car.
--- }
function FreeCam.start(o)
    if active then return end
    local car = type(o) == 'table' and o.vehicle and takeCar(PlayerPedId()) or nil
    if active then return end   -- started meanwhile, while control of the car was asked for
    opts = o or {}
    carried = car
    if carried then holdCar(carried.veh, true) end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local camRot = GetGameplayCamRot(2)
    -- A caller placing a shot starts the camera AT the shot (the config page's Place camera, a hero shot's
    -- Edit in world). A table from the page or a vector from Lua.
    local function point(v)
        local t = type(v)
        if (t == 'table' or t == 'vector3' or t == 'vector4') and tonumber(v.x) and tonumber(v.y) and tonumber(v.z) then return v end
        return nil
    end
    local at = point(opts.coords) or coords
    local look = point(opts.rot) or camRot

    startCoords  = coords
    startHeading = GetEntityHeading(ped)

    if opts.hidePed ~= false then
        PedHold.set('freecam', { hidden = true, noCollision = true, invincible = true, frozen = true })
        SetLocalPlayerVisibleLocally(false)
    end

    fov = opts.fov or 60.0
    fovTarget = fov

    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    poseAt(at.x, at.y, at.z)
    turnTo(math.max(-89.0, math.min(89.0, look.x + 0.0)), 0.0, look.z)
    SetCamCoord(cam, camX, camY, camZ)
    SetCamRot(cam, camPitch, camRoll, camYaw, 2)
    SetCamFov(cam, fov)
    fovSet = fov
    focusX = nil   -- a camera started where the last one stopped still needs the focus put (stop cleared it)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, false)

    velocity = vector3(0.0, 0.0, 0.0)
    speed    = opts.speed or 1.0
    -- RESET ON EVERY START, not just declared once. A caller that switched it off and was then
    -- torn down by something other than its own exit path would otherwise hand the next caller —
    -- noclip, usually — a camera that ignores the keyboard, with nothing on screen to explain it.
    inputEnabled = true
    held = false
    padMode, padTriggers = false, true
    active   = true
    -- Look, move, Tab, attack/aim and the wheel are held off for the flight (the one control loop);
    -- the camera still reads them through the disabled readers. Not Esc: a block that names 200 owns
    -- it, and nothing in noclip or lighttest exits on it. A caller whose Esc is an exit names 200 in
    -- its own block; GTA's pause stays shut by pauseKeys.
    block = carried and CARRY_BLOCK or FREECAM_BLOCK
    ControlBlocks.hold('freecam', block)
    startLoop()
end

--- Hold the game's walking and looking off while flying (as it starts), or give them back while the
--- camera stays up (the Camera Creator's Game controls: the player walks while its camera watches).
---@param on boolean
function FreeCam.holdControls(on)
    if not active then return end
    if on then ControlBlocks.hold('freecam', block) else ControlBlocks.release('freecam') end
end

--- Start or stop listening to the mouse and keyboard. See `inputEnabled`.
---@param on boolean
function FreeCam.setInputEnabled(on)
    inputEnabled = on and true or false
end

---@return boolean
function FreeCam.isInputEnabled() return inputEnabled end

--- Read the sticks as a controller's (see `padMode`); `triggers` false leaves LT and RT to the caller.
---@param on boolean
---@param triggers boolean|nil
function FreeCam.setPad(on, triggers)
    padMode = on and true or false
    padTriggers = triggers ~= false
end

--- Put the carried car at `dest`, exactly, as the ped is put on foot, facing `heading`, with the player back in their
--- seat. Still held: FreeCam.stop lets it go (letGoCar) once the player's own hold is off, and from up in the air it
--- falls then, as the ped does. Its passengers ride in it the whole way: nothing here moves them. Waits.
local function landCar(car, ped, dest, heading)
    local veh = car.veh
    SetEntityCoordsNoOffset(veh, dest.x, dest.y, dest.z, false, false, false)
    SetEntityHeading(veh, heading % 360.0)
    -- Collision first, as for the ped in FreeCam.stop: what is under it may not be streamed yet.
    RequestCollisionAtCoord(dest.x, dest.y, dest.z)
    local timeout = 0
    while not HasCollisionLoadedAroundEntity(veh) and timeout < 2000 do
        Wait(10)
        timeout = timeout + 10
    end
    if GetVehiclePedIsIn(ped, false) ~= veh then SetPedIntoVehicle(ped, veh, car.seat) end
end

--- Put the camera back on the player.
---
--- WHETHER THE PED FOLLOWS IS THE CALLER'S CALL, and it is the one genuinely behavioural difference
--- between the two users. Noclip's whole purpose is to move you, so it says yes; the furnisher flew
--- around a room the player was already standing in, so it says no and the player lands back on
--- their own feet.
---@param o table|nil { movePed boolean — teleport the ped to the camera (default true); stay boolean — leave
---   the ped where it is now, moved neither to the camera nor back (a caller whose player moved themselves
---   meanwhile: the Camera Creator's Game controls) }
---@return vector3 finalCoords  where the camera ended up, whether or not the ped went there
function FreeCam.stop(o)
    o = o or {}
    local ped = PlayerPedId()
    local finalCoords = cam and GetCamCoord(cam) or GetEntityCoords(ped)

    if cam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(cam, false)
        cam = nil
    end
    ClearFocus()
    -- The game goes back to its own idea of the room, which follows the ped again from here.
    releaseRoom()
    active = false
    ControlBlocks.release('freecam')

    -- WHERE THE PED LANDS. Either the camera's last position, or back where it started — and both
    -- are a real teleport, because the loop has been dragging the ped around behind the camera the
    -- whole time to keep the world streamed. Or nowhere (`stay`): the player moved themselves, and is
    -- where they should be — sending them back would undo it (and pull them out of a car).
    local car = carried and DoesEntityExist(carried.veh) and carried or nil
    carried = nil
    if car then
        -- The car goes there with the player in it, facing where the camera looked (or back as it stood); with
        -- `stay`, it stays. Let go below, after the player's own hold.
        if not o.stay then
            local back = o.movePed == false
            landCar(car, ped, back and car.from or finalCoords, back and car.heading or camYaw)
        end
    elseif not o.stay then
        local dest = (o.movePed ~= false) and finalCoords or (startCoords or finalCoords)

        -- COLLISION FIRST, OR YOU FALL THROUGH THE WORLD. The ped is being put somewhere the game may
        -- not have streamed; dropping it there before the collision mesh exists is a fall into the sea
        -- that looks like a teleport bug.
        RequestCollisionAtCoord(dest.x, dest.y, dest.z)
        local timeout = 0
        while not HasCollisionLoadedAroundEntity(ped) and timeout < 2000 do
            Wait(10)
            timeout = timeout + 10
        end
        SetEntityCoordsNoOffset(ped, dest.x, dest.y, dest.z, false, false, false)
        if o.movePed == false then SetEntityHeading(ped, startHeading) end
    end
    startCoords = nil

    if opts.hidePed ~= false then
        -- Its own hold only (client/ped_hold.lua): a downed player stays frozen and invincible.
        PedHold.release('freecam')
        SetLocalPlayerVisibleLocally(true)
    end
    if car then letGoCar(car.veh) end

    opts = {}
    return finalCoords
end

-- ============================================
-- Reads
-- ============================================

---@return boolean
function FreeCam.isActive() return active end

--- The camera handle, for a caller that needs to raycast from it.
---@return number|nil
function FreeCam.getCam() return cam end

---@return vector3
function FreeCam.getCoord()
    if not cam then return GetEntityCoords(PlayerPedId()) end
    return GetCamCoord(cam)
end

---@return vector3 rot # pitch, roll, yaw in rotation order 2
function FreeCam.getRot()
    if not cam then return GetGameplayCamRot(2) end
    return GetCamRot(cam, 2)
end

--- Unit vector the camera is looking along. The furnisher casts its placement ray down this.
---@return vector3
function FreeCam.forward()
    local rot = FreeCam.getRot()
    local p, y = math.rad(rot.x), math.rad(rot.z)
    local cp = math.cos(p)
    return vector3(-math.sin(y) * cp, math.cos(y) * cp, math.sin(p))
end

--- Current fly speed multiplier, for a caller drawing it on a HUD.
---@return number
function FreeCam.getSpeed() return speed end

--- The field of view now (it eases toward the one asked for), and the one asked for.
---@return number fov, number target
function FreeCam.getFov() return fov, fovTarget end

--- Ask for a field of view; the camera eases to it. For a caller zooming without the wheel (a controller).
---@param f number
function FreeCam.setFov(f)
    fovTarget = math.max(CC_FOV_MIN, math.min(CC_FOV_MAX, tonumber(f) or fovTarget))
end

--- THE WHEEL'S ZOOM, noclip's and any camera's that zooms like it (the camera item, client/items/camera.lua): a
--- notch up narrows the lens asked for by CC_ZOOM_SPEED degrees, a notch down widens it, held to `lo`..`hi` (the
--- flying limits when left out). Read from the disabled readers, so the wheel must be in the caller's block.
---@param target number  the lens asked for now
---@param lo number|nil
---@param hi number|nil
---@return number  the lens asked for after this frame's notches
function FreeCam.wheelZoom(target, lo, hi)
    if IsDisabledControlPressed(0, 241) then target = target - CC_ZOOM_SPEED end
    if IsDisabledControlPressed(0, 242) then target = target + CC_ZOOM_SPEED end
    return math.max(lo or CC_FOV_MIN, math.min(hi or CC_FOV_MAX, target))
end

--- One frame of the lens easing to the one asked for, as noclip's eases.
---@param f number
---@param target number
---@return number
function FreeCam.easeFov(f, target)
    return f + (target - f) * CC_FOV_LERP
end

--- Put the camera somewhere, now: its place, turn (roll too) and lens, with no glide carried in. The
--- lens is taken as it is, outside the flying limits (a sequence's shot can be wider or longer).
function FreeCam.setPose(x, y, z, pitch, roll, yaw, f)
    if not cam then return end
    poseAt(x, y, z)
    turnTo(pitch, roll or 0.0, yaw)
    SetCamCoord(cam, camX, camY, camZ)
    SetCamRot(cam, camPitch, camRoll, camYaw, 2)
    velocity = vector3(0.0, 0.0, 0.0)
    if f then
        fov, fovTarget = f + 0.0, math.max(CC_FOV_MIN, math.min(CC_FOV_MAX, f + 0.0))
        SetCamFov(cam, fov)
        fovSet = fov
    end
end

--- Hold the camera for the caller (it drives it with setPose), or let it fly again from where it is.
---@param on boolean
function FreeCam.hold(on)
    held = on and true or false
    velocity = vector3(0.0, 0.0, 0.0)
end

---@return boolean
function FreeCam.isHeld() return held end

-- ============================================
-- Moving it
-- ============================================

--- Jump the camera so that a point sits `distance` metres dead ahead of it.
---
--- THE ORIENTATION IS NOT TOUCHED, and that is the whole design of it. Turning to face the target
--- as well would be two movements at once, and arriving somewhere pointing a direction the player
--- did not choose is the disorientating half — arriving with the framing you already had is not.
--- The point lands in the centre of the screen either way, because "ahead" is measured down the
--- camera's own forward vector.
---
--- THE VELOCITY IS CLEARED, or the camera carries whatever glide it was on into the new position
--- and slides away from the thing it was just sent to look at.
---
--- Used by the housing furnisher's object list: picking a row selects something that may be three
--- rooms away, and an editor that lets you adjust what you cannot see is a numeric form.
---@param x number
---@param y number
---@param z number
---@param distance number|nil  how far in front to leave it (default 3)
function FreeCam.frame(x, y, z, distance)
    if not cam then return end
    distance = distance or 3.0

    local f = FreeCam.forward()
    poseAt(x - f.x * distance, y - f.y * distance, z - f.z * distance)
    SetCamCoord(cam, camX, camY, camZ)
    velocity = vector3(0.0, 0.0, 0.0)
end

-- ============================================
-- The room the camera is in
-- ============================================
--
-- GTA draws an MLO by the ROOM the camera is in — that room, and whatever can be seen from it through doorways (the
-- MLO's portals) — and it keeps track of which room that is by watching the camera pass through the
-- doorways. Walking always goes through a doorway, so it never loses count. This camera flies
-- through walls and floors, crosses no doorway, and the game goes on believing it is in the room (or
-- the street) it left: it draws that one's view and culls the room the camera is really in.
--
-- So the camera's room is kept right for the game by client/viewport_room.lua, which follows it
-- every frame the camera is up and hands the room back when the camera stops. The same follower
-- puts a spawn right (ViewportRoom.settle).

--- Hand the room back to the game. (Declared at the top: FreeCam.stop, above, calls it.)
releaseRoom = function() ViewportRoom.release() end

--- Every frame the camera is up: keep the game's idea of the camera's room right.
local function followRoom(p) ViewportRoom.follow(p) end

-- ============================================
-- The loop
-- ============================================
--
-- Started with the camera, ended with it: a thread per flight, not one for the session.

local loopRunning = false

-- Below these the glide and the lens count as arrived (they ease toward them and never quite land), so a
-- camera at rest writes nothing: 1 mm a second, a thousandth of a degree of lens.
local REST_SPEED, REST_FOV = 0.001, 0.001
-- The streaming focus is put at the camera whenever it moves, and at least this often while it does not.
local FOCUS_EVERY = 100

--- Streaming follows the camera (see the loop), told when it has moved or every FOCUS_EVERY frames.
local function focusAt(x, y, z, frames)
    if x ~= focusX or y ~= focusY or z ~= focusZ or frames == 0 then
        focusX, focusY, focusZ = x, y, z
        SetFocusPosAndVel(x, y, z, 0.0, 0.0, 0.0)
    end
end

local function loop()
    local frames = 0

    while true do
        if active and cam and held then
            -- The caller drives it (FreeCam.hold, FreeCam.setPose): only the world and the room follow it.
            followRoom(vector3(camX, camY, camZ))
            frames = (frames + 1) % FOCUS_EVERY
            focusAt(camX, camY, camZ, frames)
            Wait(0)
        elseif active and cam then
            local dt = GetFrameTime()

            local camCoords = vector3(camX, camY, camZ)
            local camRot    = vector3(camPitch, camRoll, camYaw)

            local pitch    = math.rad(camRot.x)
            local yaw      = math.rad(camRot.z)
            local cosPitch = math.cos(pitch)
            local fwdX     = -math.sin(yaw) * cosPitch
            local fwdY     =  math.cos(yaw) * cosPitch
            local fwdZ     =  math.sin(pitch)
            local rightX   =  math.cos(yaw)
            local rightY   =  math.sin(yaw)

            -- ---- the reads, and the one switch that silences them ----
            --
            -- Everything from here to the end of the wheel block asks the player what to do. A
            -- caller sharing the mouse with a cursor turns the lot off in one place rather than
            -- every caller growing its own idea of when the camera is listening.
            if opts.pad == 'auto' then padMode = WhipPadActive == true end
            local shift = nil   -- Shift held (read once a frame); nil until the keys' reads ask
            if inputEnabled and padMode then
                local moveSpeed = CC_MOVE_SPEED * speed * padMove
                if IsDisabledControlPressed(0, PAD_FAST) then moveSpeed = moveSpeed * CC_FAST_MULT end
                -- The left stick (30 across, 31 down-is-back), the look's way like W and D.
                local lx, ly = padAxis(GetDisabledControlNormal(0, 30)), padAxis(GetDisabledControlNormal(0, 31))
                velocity = velocity + (vector3(fwdX, fwdY, fwdZ) * -ly + vector3(rightX, rightY, 0.0) * lx) * moveSpeed * dt
                if padTriggers then
                    local up = WhipPadTrigger('rt', PAD_DEAD) - WhipPadTrigger('lt', PAD_DEAD)
                    velocity = velocity + vector3(0.0, 0.0, up * moveSpeed) * dt
                end
                -- The right stick, as a rate: the mouse's signs (down looks down, right turns right).
                local rx, ry = padAxis(GetDisabledControlNormal(0, 1)), padAxis(GetDisabledControlNormal(0, 2))
                local look = PAD_LOOK * padLook
                camRot = vector3(math.max(-89.0, math.min(89.0, camRot.x - ry * look * dt)), 0.0,
                                 camRot.z - rx * look * dt)
            elseif inputEnabled then
                local moveSpeed = CC_MOVE_SPEED * speed
                shift = IsDisabledControlPressed(0, 21)
                if shift then
                    moveSpeed = moveSpeed * CC_FAST_MULT
                end

                if IsDisabledControlPressed(0, 32) then
                    velocity = velocity + vector3(fwdX, fwdY, fwdZ) * moveSpeed * dt
                end
                if IsDisabledControlPressed(0, 33) then
                    velocity = velocity - vector3(fwdX, fwdY, fwdZ) * moveSpeed * dt
                end
                if IsDisabledControlPressed(0, 35) then
                    velocity = velocity + vector3(rightX, rightY, 0.0) * moveSpeed * dt
                end
                if IsDisabledControlPressed(0, 34) then
                    velocity = velocity - vector3(rightX, rightY, 0.0) * moveSpeed * dt
                end
                if IsDisabledControlPressed(0, 22) then
                    velocity = velocity + vector3(0.0, 0.0, moveSpeed) * dt
                end
                if IsDisabledControlPressed(0, 36) then
                    velocity = velocity - vector3(0.0, 0.0, moveSpeed) * dt
                end

                local mouseX   = GetDisabledControlNormal(0, 1) * CC_SENSITIVITY
                local mouseY   = GetDisabledControlNormal(0, 2) * CC_SENSITIVITY
                local newPitch = math.max(-89.0, math.min(89.0, camRot.x - mouseY))
                local newYaw   = camRot.z - mouseX
                camRot = vector3(newPitch, 0.0, newYaw)
            end

            -- OUTSIDE THE GATE. Damping and integration are what the camera is DOING, not what it
            -- is being told — letting go of the look button mid-glide has to coast, not stop dead.
            velocity = velocity * (1.0 - CC_DAMPING * dt)
            if #velocity < REST_SPEED then velocity = vector3(0.0, 0.0, 0.0) end   -- landed: nothing more to write
            camCoords = camCoords + velocity * dt

            -- THE LEASH. A caller that works on one place (the furnisher, one house) keeps the camera
            -- there; flying it through walls into somebody else's interior is not part of the job.
            local leash = opts.leash
            if leash then
                local dx, dy, dz = camCoords.x - leash.x, camCoords.y - leash.y, camCoords.z - leash.z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d > leash.radius then
                    local k = leash.radius / d
                    camCoords = vector3(leash.x + dx * k, leash.y + dy * k, leash.z + dz * k)
                    velocity = vector3(0.0, 0.0, 0.0)
                end
            end

            -- THE WHEEL, AND WHO GETS IT. Noclip zooms with it and changes fly speed with
            -- Shift+wheel; the furnisher turns the object being placed with it and cannot share.
            -- `scroll = 'none'` hands it over entirely rather than trying to split it, because a
            -- wheel that sometimes zooms and sometimes rotates is a wheel you stop trusting.
            if inputEnabled and opts.scroll ~= 'none' then
                if shift == nil then shift = IsDisabledControlPressed(0, 21) end
                if shift then
                    if IsDisabledControlPressed(0, 241) then
                        speed = math.min(CC_SPEED_MAX, speed + CC_SPEED_STEP)
                    end
                    if IsDisabledControlPressed(0, 242) then
                        speed = math.max(CC_SPEED_MIN, speed - CC_SPEED_STEP)
                    end
                else
                    fovTarget = FreeCam.wheelZoom(fovTarget)
                end
            end

            fov = FreeCam.easeFov(fov, fovTarget)
            if math.abs(fovTarget - fov) < REST_FOV then fov = fovTarget end

            -- Written only when they changed: a camera at rest asks the game for nothing.
            local x, y, z = camCoords.x, camCoords.y, camCoords.z
            if x ~= camX or y ~= camY or z ~= camZ then
                camX, camY, camZ = x, y, z
                SetCamCoord(cam, x, y, z)
            end
            if camRot.x ~= camPitch or camRot.y ~= camRoll or camRot.z ~= camYaw then
                camPitch, camRoll, camYaw = camRot.x, camRot.y, camRot.z
                SetCamRot(cam, camPitch, camRoll, camYaw, 2)
            end
            if fov ~= fovSet then
                fovSet = fov
                SetCamFov(cam, fov)
            end

            -- The room it is in, so the game draws that room (see "The room the camera is in").
            followRoom(camCoords)

            -- STREAMING FOLLOWS THE CAMERA, and the ped follows it every hundred frames. The focus
            -- call alone streams the world in; moving the ped periodically is what keeps the game
            -- from deciding the player is somewhere else entirely and unloading around them.
            -- NOT for a caller that said pedFollows = false: the ped's position is the player's
            -- position as far as the server is concerned (proximity checks, the saved position).
            frames = (frames + 1) % FOCUS_EVERY
            focusAt(x, y, z, frames)
            -- A carried car goes instead, with the player in it: moving the ped alone takes it out of its seat.
            if frames == 0 and opts.pedFollows ~= false then
                local mover = carried and DoesEntityExist(carried.veh) and carried.veh or PlayerPedId()
                SetEntityCoordsNoOffset(mover, x, y, z, false, false, false)
            end

            Wait(0)
        else
            break
        end
    end
    loopRunning = false
end

startLoop = function()
    if loopRunning then return end
    loopRunning = true
    CreateThread(loop)
end

-- A RESTART MID-FLIGHT MUST GIVE THE PLAYER BACK. The ped is hidden, frozen, invincible and without
-- collision while the camera is up, and nothing else would undo that once this resource is gone.
-- FreeCam.stop waits on collision and a stop handler cannot wait, so this is its no-wait half.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not active then return end
    local ped = PlayerPedId()
    if cam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(cam, false)
        cam = nil
    end
    ClearFocus()
    releaseRoom()
    active = false
    if opts.pedFollows == false and startCoords then
        SetEntityCoordsNoOffset(ped, startCoords.x, startCoords.y, startCoords.z, false, false, false)
        SetEntityHeading(ped, startHeading)
    end
    -- A carried car is shown and let go where it is (landing it waits for collision), after the player's hold.
    local car = carried and DoesEntityExist(carried.veh) and carried.veh or nil
    carried = nil
    if opts.hidePed ~= false then
        PedHold.release('freecam')
        SetLocalPlayerVisibleLocally(true)
    end
    if car then letGoCar(car) end
end)
