-- ============================================
-- Dev Tools — Edit hand position (/whip → Items → an item)
-- ============================================
--
-- How an item sits in the hand when it is held out to give or throw (give mode), set by eye. The panel steps
-- aside, a free camera comes up beside a copy of you held still in one of give mode's poses, the item in its
-- hand, and every item is listed down the left (html/js/hand-edit.js) to go on to the next. Then:
--
--   the markers      the furnisher's arrows and rings (the Object Viewer's Move, tools/ov_move.lua): drag the
--                    arrows to slide it, R for the rings to turn it
--   right mouse      held: fly the camera (WASD, mouse) for a close look; let go and the cursor is back
--   H                the next pose (POSES): aiming, in a car at the left window, at the right window. The hand
--                    you leave is kept as you left it, so you can set each pose in turn
--   Confirm & Exit   save every hand you set and go back to the panel
--   Esc              back without saving (Backspace too)
--   the list         another item. With changes not saved the page asks first: Cancel, Save & swap, Disregard &
--                    swap. Typing in its search box takes the game's keys away, so an H or Esc typed there is a
--                    letter
--   the toggles      Allow player walk animation (the item's playerWalk setting): off, give mode puts the give walk
--                    on (the trash-bag walk, Config.GiveModeStyle); on, the player keeps their own. Shown by the two
--                    walking poses. Picked up with both hands (its grab setting, client/ground.lua). Both saved with
--                    the hands
--
-- Move's bar at the top shows only those keys (KEYS); nothing at the bottom (Josh, 12 Nov 2026).
--
-- THE POSES. Each is the game's own clip for holding a thrown thing (WEAPON_BALL's: weapons@projectile@, and a
-- car's drive-by throw), stopped on its last frame (the arm all the way out: how an item is held, aimed). Played
-- on a copy of you, never you: a clip stopped on a frame does not move, where your own ped's idle never stops
-- moving, and the car poses sit it in a car only this game has, made for the car poses and gone again with them.
-- A pose says its hand: a car's left seat throws left-handed (client/inventory.lua's throwHand), so that one is
-- the left hand's hold and the other two share the right's.
--
-- Saved on the item (server/item_holds.lua), it is where give mode holds it from then on, and a thrown one
-- leaves the hand turned that way (client/inventory.lua).
--
-- A RESOURCE'S HELD PROP (/w → Edit Held Prop: a pump's nozzle in your hand) opens the same editor on that prop:
-- HELD_POSES instead, its own bone, no list and no switches. Saved for its set's tag (server/held_props.lua), it
-- sits there in everyone's hand from then on. The prop in your own hand is hidden on your game meanwhile.
--
-- HOW A PLACE IN THE WORLD BECOMES A PLACE IN THE HAND. The markers move a loose copy of the item in the world.
-- An invisible marker is tied to the hand's bone with nothing added: it stands exactly as the bone does, so the
-- copy's place is read off in the bone's own axes. Its turn becomes the three angles in the order the tie is
-- told to use (TIE_ORDER). Saving checks it: a third copy is tied with what was worked out, and it must stand
-- where the loose one does.

local HAND_BONES = { right = 57005, left = 18905 }   -- SKEL_R_Hand, SKEL_L_Hand (server/events_inventory.lua)
-- AttachEntityToEntity's rotationOrder, the same one client/ui.lua's tieHeld gives every held prop (give mode's
-- included): 1, turn about y, then z, then x. The angles are worked out for this order (anglesOf); worked out
-- for another, a turn about two axes at once came out up to 25° wrong.
local TIE_ORDER = 1
local DEFAULT = { offset = { 0.05, 0.0, 0.0 }, rot = { 0.0, 0.0, 0.0 } }   -- its GIVE_OFFSET / GIVE_ROT

-- `phase` is where the clip stops (0 its first frame, 0.99 its last); `cam` is where the camera starts, in the
-- copy's own space (right, forward, up), looking at the hand; `seat` sits it in the car.
local POSES = {
    { label = 'Aiming', hand = 'right', dict = 'weapons@projectile@', clip = 'aim_intro', phase = 0.99,
      cam = vector3(1.0, 0.8, 0.5) },
    { label = 'In a car, left window', hand = 'left', dict = 'veh@drivebystd_ds_grenades', clip = 'intro_90l',
      phase = 0.99, seat = -1, cam = vector3(-1.4, 0.5, 0.3) },
    { label = 'In a car, right window', hand = 'right', dict = 'veh@drivebystd_ps_grenades', clip = 'intro_90r',
      phase = 0.99, seat = 0, cam = vector3(1.4, 0.5, 0.3) },
    -- To look at, not to set: walking and jogging on the spot (`move`, TaskGoStraightToCoord's speed, the copy held
    -- still), with the walk give mode puts on for this item as the toggle has it (walkNow), the item tied to the hand
    -- as give mode ties it and the markers put away. The camera looks at the chest (`look`, SKEL_Spine3).
    { label = 'Walking in place', hand = 'right', move = 1.0, look = 24818, cam = vector3(2.0, 1.8, 0.4) },
    { label = 'Jogging in place', hand = 'right', move = 2.0, look = 24818, cam = vector3(2.0, 1.8, 0.4) },
}
-- A resource's held prop (Edit Held Prop, from /w): standing with the arm down as a carried bag hangs (the heist
-- trash-bag carry, its first frame), then walking and jogging on the spot in the walk the player has now: the
-- resource's own while they hold it (a pump's nozzle: the trash-bag walk). Tied to the resource's own bone.
local HELD_POSES = {
    { label = 'Standing', hand = 'right', dict = 'anim@heists@narcotics@trash', clip = 'idle', phase = 0.0,
      cam = vector3(1.0, 0.8, 0.1) },
    { label = 'Walking in place', hand = 'right', move = 1.0, look = 24818, cam = vector3(2.0, 1.8, 0.4) },
    { label = 'Jogging in place', hand = 'right', move = 2.0, look = 24818, cam = vector3(2.0, 1.8, 0.4) },
}
local CAR = 'tailgater'   -- a four-door whose seats use the drive-by clips above (veh@drivebystd_*)

-- Move's bar: these, and nothing else.
local KEYS = {
    { key = 'H', text = 'Next position' },
    { key = 'R', text = 'Rotate / Move' },
    { key = 'Right mouse', text = 'Look' },
    { key = 'Esc', text = 'Cancel' },
}

-- A hold this close to the saved one is the saved one (what is read back off the game drifts by a hair).
local SAME_M, SAME_COS = 0.001, math.cos(math.rad(0.1))

-- { key, label, model, poses, pose, hand, holds = { right, left }, saved = { right, left }, visited, walk, savedWalk,
--   double, car, frame, item, probe, busy (saving, swapping or changing pose), asking (the item the page is asking
--   about), leave (Esc while busy: out once it is done), quiet (no keys until then), fromPanel (opened from /whip:
--   the panel comes back after), heldTag + bone (a resource's held prop, not an item: its set's tag, its bone) }
---@class HandEditSession
---@field key string
---@field label string
---@field model integer
---@field poses table[]
---@field pose integer
---@field hand string
---@field holds table<string, table>
---@field saved table<string, table>
---@field visited table<string, boolean>
---@field walk boolean|nil
---@field savedWalk boolean|nil
---@field grab boolean|nil
---@field savedGrab boolean|nil
---@field double integer
---@field car integer|nil
---@field walking boolean|nil
---@field frame integer
---@field item integer
---@field probe integer
---@field busy boolean|nil
---@field asking { key: string, name: string }|nil
---@field leave boolean|nil
---@field quiet integer|nil
---@field fromPanel boolean|nil
---@field heldTag string|nil
---@field bone integer|nil

---@type HandEditSession|nil
local ed = nil
-- What reads it below runs only while the editor is open (the way in checks it)
---@cast ed -nil

--- The bone the hand's hold is from: a held prop's own, else the pose's hand.
local function boneNow() return ed.bone or HAND_BONES[ed.hand] end

local function say(text, kind) UI.Notify(text, kind or 'info') end

local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

local function deleteObj(e) if e and DoesEntityExist(e) then DetachEntity(e, false, false); DeleteObject(e) end end
local function deleteEnt(e) if e and DoesEntityExist(e) then DeleteEntity(e) end end

--- An item's name as the list shows it.
local function itemName(key, given)
    if type(given) == 'string' and given ~= '' then return given end
    local def = Config.Items[key]
    return def and def.name or key
end

--- An entity's three axes in the world, read off the entity itself (no assumption about its rotation's order).
local function axesOf(ent)
    local p = GetEntityCoords(ent)
    return GetOffsetFromEntityInWorldCoords(ent, 1.0, 0.0, 0.0) - p,
           GetOffsetFromEntityInWorldCoords(ent, 0.0, 1.0, 0.0) - p,
           GetOffsetFromEntityInWorldCoords(ent, 0.0, 0.0, 1.0) - p, p
end

--- The three angles (degrees) of a turn given by its axes, in TIE_ORDER (R = Ry · Rz · Rx).
local function anglesOf(right, forward, up)
    local z = math.deg(math.asin(math.max(-1.0, math.min(1.0, right.y))))
    -- Turned a quarter about z: x and y turn about the same line, so x is taken as 0 and y does it all
    if forward.y * forward.y + up.y * up.y < 1e-8 then
        local s = right.y < 0 and -1.0 or 1.0
        return 0.0, math.deg(math.atan(forward.z * s, -forward.x * s)), z
    end
    return math.deg(math.atan(-up.y, forward.y)), math.deg(math.atan(-right.z, right.x)), z
end

--- The other way: a hold's right and forward axes in the hand, from its three angles (TIE_ORDER).
local function turnAxes(rot)
    local a, b, c = math.rad(rot[1]), math.rad(rot[2]), math.rad(rot[3])
    local ca, sa, cb, sb, cc, sc = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(c), math.sin(c)
    return vector3(cb * cc, sc, -sb * cc), vector3(-cb * sc * ca + sb * sa, cc * ca, sb * sc * ca + cb * sa)
end

--- Do two holds put it in the same place? Turns are compared as turns: two sets of angles can say the same one.
local function sameHold(a, b)
    for i = 1, 3 do
        if math.abs(a.offset[i] - b.offset[i]) > SAME_M then return false end
    end
    local ar, af = turnAxes(a.rot)
    local br, bf = turnAxes(b.rot)
    return dot(ar, br) >= SAME_COS and dot(af, bf) >= SAME_COS
end

--- Where the loose copy stands, in the hand's own space: { offset, rot }.
local function readHold()
    local fr, ff, fu, fp = axesOf(ed.frame)
    local ir, iff, iu, ip = axesOf(ed.item)
    local d = ip - fp
    local function inHand(v) return vector3(dot(v, fr), dot(v, ff), dot(v, fu)) end
    local x, y, z = anglesOf(inHand(ir), inHand(iff), inHand(iu))
    return { offset = { dot(d, fr), dot(d, ff), dot(d, fu) }, rot = { x, y, z } }
end

local function tie(ent, hold)
    local ped = ed.double
    local o, r = hold.offset, hold.rot
    AttachEntityToEntity(ent, ped, GetPedBoneIndex(ped, boneNow()), o[1] + 0.0, o[2] + 0.0, o[3] + 0.0,
        r[1] + 0.0, r[2] + 0.0, r[3] + 0.0, true, true, false, true, TIE_ORDER, true)
end

--- The loose copy put where `hold` has it in the hand now: tied for a frame, read, and let go there.
local function placeHold(hold)
    tie(ed.item, hold)
    Wait(0)
    local p, r = GetEntityCoords(ed.item), GetEntityRotation(ed.item, 2)
    DetachEntity(ed.item, false, false)
    SetEntityCoordsNoOffset(ed.item, p.x, p.y, p.z, false, false, false)
    SetEntityRotation(ed.item, r.x, r.y, r.z, 2, true)
    FreezeEntityPosition(ed.item, true)
end

--- The hand's bone, with the invisible marker tied to it exactly.
local function tieFrame()
    local ped = ed.double
    AttachEntityToEntity(ed.frame, ped, GetPedBoneIndex(ped, boneNow()), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        true, true, false, true, TIE_ORDER, true)
end

--- Does `hold`, tied, stand where the loose copy does? Degrees off (worst axis), and metres apart.
local function checkHold(hold)
    tie(ed.probe, hold)
    Wait(0)
    local pr, pf, pu, pp = axesOf(ed.probe)
    local ir, iff, iu, ip = axesOf(ed.item)
    local worst = 0.0
    for _, pair in ipairs({ { pr, ir }, { pf, iff }, { pu, iu } }) do
        local c = math.max(-1.0, math.min(1.0, dot(pair[1], pair[2])))
        worst = math.max(worst, math.deg(math.acos(c)))
    end
    DetachEntity(ed.probe, false, false)
    SetEntityCoordsNoOffset(ed.probe, 0.0, 0.0, -200.0, false, false, false)
    return worst, #(pp - ip)
end

--- The copy of you the poses are played on: where you stand, still, and nothing in its hands.
local function makeDouble()
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local d = ClonePed(ped, false, false, true)
    if not d or d == 0 then return nil end
    SetEntityAsMissionEntity(d, true, true)
    SetEntityCoordsNoOffset(d, c.x, c.y, c.z, false, false, false)
    SetEntityHeading(d, GetEntityHeading(ped))
    FreezeEntityPosition(d, true)
    SetEntityCollision(d, false, false)
    SetEntityInvincible(d, true)
    SetPedCanRagdoll(d, false)
    SetBlockingOfNonTemporaryEvents(d, true)
    SetPedCanPlayAmbientAnims(d, false)
    SetPedCanPlayAmbientBaseAnims(d, false)
    SetPedCanPlayGestureAnims(d, false)
    RemoveAllPedWeapons(d, true)
    return d
end

--- The car the car poses sit in, made when one is asked for: where you stand, still, windows down.
local function carFor()
    if ed.car and DoesEntityExist(ed.car) then return ed.car end
    local hash = LoadModel(CAR, 3000)
    if not hash then return nil end
    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local car = CreateVehicle(hash, c.x, c.y, c.z, GetEntityHeading(ped), false, false)
    SetModelAsNoLongerNeeded(hash)
    if not car or car == 0 then return nil end
    SetEntityAsMissionEntity(car, true, true)
    SetVehicleOnGroundProperly(car)
    FreezeEntityPosition(car, true)
    SetEntityCollision(car, false, false)
    SetEntityInvincible(car, true)
    RollDownWindow(car, 0)
    RollDownWindow(car, 1)
    ed.car = car
    return car
end

--- Keep the pose's clip on its frame (asked every frame: nothing may move it on). A walking pose has none.
local function holdStill(p)
    if not p.dict then return false end
    if IsEntityPlayingAnim(ed.double, p.dict, p.clip, 3) then
        SetEntityAnimCurrentTime(ed.double, p.dict, p.clip, p.phase)
        SetEntityAnimSpeed(ed.double, p.dict, p.clip, 0.0)
        return true
    end
    return false
end

--- The walk give mode puts on this item as the toggle has it, on the copy: the give walk, or with the toggle on
--- the game's own. A held prop: the walk the player has now (the resource's own while they hold it). Yields (the
--- walk loads).
local function walkNow()
    local d = ed.double
    local clipset
    if ed.heldTag then clipset = Emotes.wantedWalk() else clipset = not ed.walk and Inventory.giveWalkClipset(nil) or nil end
    if clipset and LoadAnimSet(clipset, 1000) then
        SetPedMovementClipset(d, clipset, 0.25)
    else
        ResetPedMovementClipset(d, 0.25)
    end
end

--- Put the copy in pose `p`: in or out of the car, its clip on its frame, or walking on the spot. Yields. False and
--- why when it cannot.
local function pose(p)
    local d = ed.double
    if p.dict and not LoadAnimDict(p.dict, 3000) then return false, 'The game would not load that pose' end
    if p.seat then
        local car = carFor()
        if not car then return false, 'No car for that pose' end
        if GetPedInVehicleSeat(car, p.seat) ~= d then
            FreezeEntityPosition(d, false)
            SetPedIntoVehicle(d, car, p.seat)
        end
    elseif IsPedInAnyVehicle(d, false) or ed.car then
        -- Out of the car and back where you stand, and the car goes: an on-foot pose has none
        local ped = PlayerPedId()
        local c = GetEntityCoords(ped)
        ClearPedTasksImmediately(d)
        SetEntityCoordsNoOffset(d, c.x, c.y, c.z, false, false, false)
        SetEntityHeading(d, GetEntityHeading(ped))
        FreezeEntityPosition(d, true)
        deleteEnt(ed.car)
        ed.car = nil
    end
    if p.move then
        -- Told to walk a kilometre straight ahead, held still: it walks on the spot, in the walk it has on
        ClearPedTasksImmediately(d)
        FreezeEntityPosition(d, true)
        walkNow()
        local to = GetOffsetFromEntityInWorldCoords(d, 0.0, 1000.0, 0.0)
        TaskGoStraightToCoord(d, to.x, to.y, to.z, p.move, -1, GetEntityHeading(d), 0.0)
        ed.walking = true
        Wait(0)
        return true
    end
    -- Off the walk (a car seat's own warp ends it there)
    if ed.walking and not p.seat then ClearPedTasksImmediately(d) end
    ed.walking = nil
    TaskPlayAnim(d, p.dict, p.clip, 1000.0, -1000.0, -1, 1, p.phase, false, false, false)
    local deadline = GetGameTimer() + 1000
    while not holdStill(p) do
        if GetGameTimer() > deadline then return false, 'The game would not play that pose' end
        Wait(0)
    end
    Wait(0)   -- a frame for the bones to stand in it before anything is read off the hand
    Wait(0)
    holdStill(p)
    return true
end

--- The camera beside the hand, looking at it (a walking pose: at the chest), for the pose on.
local function cameraFor(p)
    local hp = GetPedBoneCoords(ed.double, p.look or HAND_BONES[p.hand], 0.0, 0.0, 0.0)
    local at = GetOffsetFromEntityInWorldCoords(ed.double, p.cam.x, p.cam.y, p.cam.z)
    local d = hp - at
    return at, math.deg(math.atan(d.z, math.sqrt(d.x * d.x + d.y * d.y))), math.deg(math.atan(-d.x, d.y))
end

--- The line over the item's name on Move's bar: the pose on, and its hand.
local function caption()
    local p = ed.poses[ed.pose]
    return ('%s · %s hand'):format(p.label, p.hand)
end

--- Is the item tied to the hand as give mode ties it (a walking pose), rather than loose for the markers?
local function tiedNow() return ed.poses[ed.pose].move ~= nil end

--- The hold of the hand on screen: read off the loose copy as it stands, or (tied) the one it was tied with.
local function holdNow()
    if tiedNow() then return ed.holds[ed.hand] end
    return readHold()
end

--- Is anything set this time that is not saved? The hand on screen is read off it as it stands.
local function unsaved()
    if ed.walk ~= ed.savedWalk or ed.grab ~= ed.savedGrab then return true end
    if not sameHold(holdNow(), ed.saved[ed.hand]) then return true end
    for hand in pairs(ed.visited) do
        if hand ~= ed.hand and not sameHold(ed.holds[hand], ed.saved[hand]) then return true end
    end
    return false
end

local function finish()
    if not ed then return end
    local e = ed
    ed = nil
    if OvMove.active() then OvMove.stop() end
    if FreeCam.isActive() then FreeCam.stop({ movePed = false }) end
    deleteObj(e.item); deleteObj(e.frame); deleteObj(e.probe)
    deleteEnt(e.double); deleteEnt(e.car)
    SetModelAsNoLongerNeeded(e.model)
    PedHold.release('handEdit')
    Focus.release('handEditTyping')
    SendNUIMessage({ action = 'handEditClose' })
    if e.fromPanel then WhipPanelResume() end
end

--- The item's model, its holds as saved ({ right, left }; the left takes the right's when it has none), its
--- "Allow player walk animation", and whether it is picked up with both hands. Yields.
---@return number|nil hash
---@return table|string holds # or why not
---@return boolean|nil walk
---@return boolean|nil twoHands
local function loadItem(key)
    local model = Inventory.itemPropModel(key)
    local hash = model and LoadModel(model, 3000)
    if not hash then return nil, 'That item has no model to hold' end
    local saved, why = Callback('whip_core:itemHolds:get', key)
    if type(saved) ~= 'table' then return nil, why or 'Its hand position could not be read' end
    return hash, { right = saved.right or DEFAULT, left = saved.left or saved.right or DEFAULT }, saved.walk == true,
        saved.grab == '2h'
end

--- The item in the hand for the pose on: loose where the hold puts it, for the markers, or (a walking pose) tied
--- as give mode ties it, the markers put away. Yields.
local function putInHand()
    if tiedNow() then
        OvMove.update({ entity = ed.item, name = ed.label, caption = caption(), markers = false })
        FreezeEntityPosition(ed.item, false)   -- (placeHold and Move left it still, for the markers)
        tie(ed.item, ed.holds[ed.hand])
    else
        placeHold(ed.holds[ed.hand])
        OvMove.update({ entity = ed.item, name = ed.label, caption = caption(), markers = true })
    end
end

--- The three copies of the item: the one the markers move, and the two unseen ones (the bone, the check).
local function makeCopies(hash)
    local c = GetEntityCoords(PlayerPedId())
    local frame = CreateObject(hash, c.x, c.y, c.z - 50.0, false, false, false)
    local probe = CreateObject(hash, c.x, c.y, c.z - 200.0, false, false, false)
    local item = CreateObject(hash, c.x, c.y, c.z, false, false, false)
    for _, o in ipairs({ frame, probe }) do SetEntityVisible(o, false, false); SetEntityCollision(o, false, false) end
    SetEntityCollision(item, false, false)
    return item, frame, probe
end

--- Saves every hand set this time (the one on screen read off it now), checks it, and saves the walk toggle when it
--- changed. Yields. False when the server refused it: still in the editor, nothing lost.
local function saveHolds(e)
    if not tiedNow() then
        e.holds[e.hand] = readHold()
        e.visited[e.hand] = true
        -- Tied as give mode will tie it, it must stand where the loose copy does
        local off, apart = checkHold(e.holds[e.hand])
        if off > 2.0 or apart > 0.005 then
            print(('[whip_core:handedit] the saved hold is %.1f° and %.1f mm off what is on screen: tell Claude')
                :format(off, apart * 1000))
            say(('Saved, but it may sit %.0f° and %.0f mm off what you see (F8)'):format(off, apart * 1000), 'warning')
        end
    end
    if e.heldTag then
        -- A resource's held prop: one hold, saved for its tag and moved there in every hand holding it
        local h = e.holds.right
        if e.visited.right then
            local o, r = h.offset, h.rot
            local res, why = Callback('whip_core:heldHolds:save', e.heldTag, o[1], o[2], o[3], r[1], r[2], r[3])
            if type(res) ~= 'table' then say(why or 'It was not saved', 'error') return false end
            e.saved.right = h
        end
        say(e.label .. ': saved', 'success')
        return true
    end
    local held = false
    for _, hand in ipairs({ 'right', 'left' }) do
        local h = e.holds[hand]
        if h and e.visited[hand] then
            local o, r = h.offset, h.rot
            local res, why = Callback('whip_core:itemHolds:save', e.key, hand, o[1], o[2], o[3], r[1], r[2], r[3])
            if type(res) ~= 'table' then say(why or 'It was not saved', 'error') return false end
            e.saved[hand] = h
            held = true
        end
    end
    if e.walk ~= e.savedWalk then
        local res, why = Callback('whip_core:itemHolds:walk', e.key, e.walk)
        if type(res) ~= 'table' then say(why or 'Its walk was not saved', 'error') return false end
        e.savedWalk = e.walk
    end
    if e.grab ~= e.savedGrab then
        local res, why = Callback('whip_core:itemHolds:grab', e.key, e.grab)
        if type(res) ~= 'table' then say(why or 'How it is picked up was not saved', 'error') return false end
        e.savedGrab = e.grab
    end
    if held then SendNUIMessage({ action = 'handEditSaved', key = e.key }) end   -- the list's "Set"
    say(e.label .. ': saved', 'success')
    return true
end

--- Confirm & Exit: everything set saved, and back to the panel. Yields.
local function confirmExit()
    local e = ed
    if not e or e.busy or e.asking then return end
    e.busy = true
    local ok = saveHolds(e)
    e.busy = nil
    if ok or e.leave then finish() end
end

--- The next item in the same pose and hand, the camera where it is: its copies made, the markers moved onto it,
--- the old copies gone. Yields.
local function swapTo(e, key, name)
    local hash, holds, walk, grab = loadItem(key)
    if not hash then say(holds, 'error') return false end
    local old, oldModel = { e.item, e.frame, e.probe }, e.model
    e.item, e.frame, e.probe = makeCopies(hash)
    e.key, e.label, e.model = key, itemName(key, name), hash
    e.holds, e.saved, e.visited = holds, { right = holds.right, left = holds.left }, {}
    e.walk, e.savedWalk = walk, walk
    e.grab, e.savedGrab = grab, grab
    SendNUIMessage({ action = 'handEditWalk', on = walk })
    SendNUIMessage({ action = 'handEditGrab', on = grab })
    tieFrame()
    putInHand()
    if tiedNow() then walkNow() end
    for _, o in ipairs(old) do deleteObj(o) end
    if oldModel ~= hash then SetModelAsNoLongerNeeded(oldModel) end
    return true
end

--- An item picked in the list. `how`: nil asks first when there are changes not saved, 'save' saves them first,
--- 'discard' leaves them. Yields.
local function pick(key, name, how)
    local e = ed
    if not e or e.busy or e.asking or key == e.key or not Config.Items[key] then return end
    if how == nil and unsaved() then
        e.asking = { key = key, name = itemName(key, name) }
        SendNUIMessage({ action = 'handEditAsk', from = e.label, to = e.asking.name })
        return
    end
    e.busy = true
    if how ~= 'save' or saveHolds(e) then swapTo(e, key, name) end
    e.busy = nil
    if e.leave then finish() return end
    SendNUIMessage({ action = 'handEditCurrent', key = e.key })
end

--- H: the next pose, the hand left kept as it is. Yields.
local function nextPose()
    local e = ed
    e.busy = true
    if not tiedNow() then
        e.holds[e.hand] = readHold()
        e.visited[e.hand] = true
    end
    local was = e.pose
    e.pose = e.pose % #e.poses + 1
    local p = e.poses[e.pose]
    local done, whyNot = pose(p)
    if not done then
        say(whyNot, 'error')
        e.pose = was
        pose(e.poses[was])
        p = e.poses[was]
    end
    e.hand = p.hand
    tieFrame()
    Wait(0)
    putInHand()
    local cat, cpitch, cyaw = cameraFor(p)
    FreeCam.setPose(cat.x, cat.y, cat.z, cpitch, 0.0, cyaw)
    e.busy = nil
    if e.leave then finish() end
end

--- Open the editor on `e` ({ key, label, model, poses, holds, walk?, grab?, fromPanel?, heldTag?, bone? }: startItem,
--- startHeld): the copy of you in its first pose, the thing loose in its hand for the markers. Yields. False and why
--- when it cannot (a refusal once `ed` is set leaves it for the caller's finish() to clear away).
local function open(e)
    if IsPedInAnyVehicle(PlayerPedId(), false) then return false, 'Get out of the vehicle first' end
    e.pose, e.hand, e.visited = 1, e.poses[1].hand, {}
    e.saved = { right = e.holds.right, left = e.holds.left }
    e.savedWalk, e.savedGrab = e.walk, e.grab
    ed = e
    PedHold.set('handEdit', { frozen = true, invincible = true })
    ed.double = makeDouble()
    if not ed.double then return false, 'Could not make the copy to pose' end
    local ok, err = pose(ed.poses[1])
    if not ok then return false, err end

    ed.item, ed.frame, ed.probe = makeCopies(ed.model)
    tieFrame()
    placeHold(ed.holds[ed.hand])

    local at, pitch, yaw = cameraFor(ed.poses[1])
    FreeCam.start({ hidePed = false, pedFollows = false, coords = at, rot = { x = pitch, y = 0.0, z = yaw } })
    FreeCam.setInputEnabled(false)

    local me = ed
    ok, err = OvMove.start({ entity = ed.item, kind = 'object', name = ed.label, caption = caption(),
        doneText = 'Confirm & Exit', keys = KEYS,
        -- Confirm & Exit: confirmExit ends the markers itself (a refusal leaves them up)
        onDone = function() if ed == me then CreateThread(confirmExit) end end,
    }, function()
        -- Esc in the markers: back without saving (once a save or a swap under way is done)
        if not ed then return end
        if ed.busy then ed.leave = true else finish() end
    end)
    if not ok then return false, err end

    CreateThread(function()
        while ed == me do
            -- You stand where the copy does, unseen while it is posed, and so is the prop in your own hand
            SetEntityLocallyInvisible(PlayerPedId())
            if ed.heldTag then
                local real = UI.ownHeldProp(ed.model, ed.heldTag)
                if real then SetEntityLocallyInvisible(real) end
            end
            holdStill(ed.poses[ed.pose])
            -- The camera flies only while the right mouse button is down (the markers have the cursor otherwise)
            FreeCam.setInputEnabled(IsDisabledControlPressed(0, 25) or IsControlPressed(0, 25))
            local function pressed(c) return IsControlJustPressed(0, c) or IsDisabledControlJustPressed(0, c) end
            if ed.busy or ed.asking or GetGameTimer() < (ed.quiet or 0) then   -- saving, swapping, asking: keys wait
            elseif pressed(74) then        -- H: the next pose
                nextPose()
                if ed ~= me then break end
            -- NOT 177 (INPUT_CELLPHONE_CANCEL: the right mouse button too, the camera's fly button).
            elseif pressed(200) or pressed(202) then   -- Esc, Backspace: back
                finish()
                break
            end
            Wait(0)
        end
    end)
    return true
end

--- Start on an item (the Items page's Edit hand position). Yields.
local function startItem(key, label)
    if IsPedInAnyVehicle(PlayerPedId(), false) then return false, 'Get out of the vehicle first' end
    local hash, holds, walk, grab = loadItem(key)
    if not hash then return false, holds end
    local list = Callback('whip_core:itemHolds:list')
    local ok, why = open({ key = key, label = itemName(key, label), model = hash, poses = POSES, holds = holds,
                           walk = walk, grab = grab, fromPanel = true })
    if not ok then return false, why end
    SendNUIMessage({ action = 'handEditOpen', items = type(list) == 'table' and list or {}, current = key, walk = walk,
                     grab = grab })
    return true
end

--- Start on the prop in your hand: a resource's own (/w → Edit Held Prop: a pump's nozzle). Saved for its tag, it
--- sits there in everyone's hand from then on (server/held_props.lua). No item list: one prop. Yields.
local function startHeld()
    if IsPedInAnyVehicle(PlayerPedId(), false) then return false, 'Get out of the vehicle first' end
    local mine, why = Callback('whip_core:heldHolds:mine')
    if type(mine) ~= 'table' then return false, why or 'Hold a resource\'s prop first (a pump\'s nozzle)' end
    local hash = LoadModel(mine.model, 3000)
    if not hash then return false, 'Its model would not load' end
    local o, r = mine.offset or {}, mine.rot or {}
    local hold = { offset = { tonumber(o[1]) or 0.0, tonumber(o[2]) or 0.0, tonumber(o[3]) or 0.0 },
                   rot = { tonumber(r[1]) or 0.0, tonumber(r[2]) or 0.0, tonumber(r[3]) or 0.0 } }
    return open({ key = mine.tag, label = mine.tag, model = hash, poses = HELD_POSES, holds = { right = hold },
                  heldTag = mine.tag, bone = math.floor(tonumber(mine.bone) or 28422) })
end

-- /w → Edit Held Prop (tools/core.lua): a one-off that opens the editor on what you hold.
ToolHandlers['Edit Held Prop'] = {
    enter = function()
        if ed then return end
        CreateThread(function()
            local ok, why = startHeld()
            if not ok then
                if ed then finish() end
                say(why or 'Could not start', 'error')
            end
        end)
    end,
    exit = function() end,
    isActive = function() return false end,
}

RegisterNUICallback('ibHandEdit', function(data, cb)
    cb('ok')
    local key = type(data) == 'table' and data.itemKey
    if type(key) ~= 'string' or key == '' or ed then return end
    if not (DevToolsOn and DevToolsOn()) then return say('Developer mode only', 'error') end
    WhipPanelSuspend()
    CreateThread(function()
        local ok, why = startItem(key, type(data.label) == 'string' and data.label or nil)
        if not ok then
            -- finish() puts the panel back itself (once: a second resume would take the screen twice)
            if ed then finish() else WhipPanelResume() end
            say(why or 'Could not start', 'error')
        end
    end)
end)

-- ---- the list down the left (html/js/hand-edit.js) ----

RegisterNUICallback('handEditPick', function(data, cb)
    cb('ok')
    local key = type(data) == 'table' and data.itemKey
    if not ed or type(key) ~= 'string' then return end
    CreateThread(function() pick(key, data.name) end)
end)

-- The page's answer to "changes not saved": 'save', 'discard', or anything else to stay.
RegisterNUICallback('handEditAnswer', function(data, cb)
    cb('ok')
    local asked = ed and ed.asking
    if not asked then return end
    ed.asking = nil
    -- The Esc that answered Cancel may reach the game's keys a frame after this: it is not the way out too
    ed.quiet = GetGameTimer() + 300
    local how = type(data) == 'table' and data.choice
    if how == 'save' or how == 'discard' then CreateThread(function() pick(asked.key, asked.name, how) end) end
end)

-- The toggle: "Allow player walk animation" for the item on screen. Saved with the hands; a walking pose shows it at
-- once. Busy, it stays as it was (the page is told back either way).
RegisterNUICallback('handEditWalk', function(data, cb)
    cb('ok')
    if not ed then return end
    if not (ed.busy or ed.asking) then ed.walk = type(data) == 'table' and data.on == true end
    SendNUIMessage({ action = 'handEditWalk', on = ed.walk })
    -- (The thread starts next tick: the editor may have closed by then.)
    if tiedNow() and not ed.busy then CreateThread(function() if ed then walkNow() end end) end
end)

-- The second switch: "Picked up with both hands" for the item on screen (its grab setting: '2h' on, '1h' off; how
-- client/ground.lua picks one up). Saved with the hands. Busy, it stays as it was.
RegisterNUICallback('handEditGrab', function(data, cb)
    cb('ok')
    if not ed then return end
    if not (ed.busy or ed.asking) then ed.grab = type(data) == 'table' and data.on == true end
    SendNUIMessage({ action = 'handEditGrab', on = ed.grab })
end)

-- The search box has the keys (on) or let them go: while it has them the game gets none.
RegisterNUICallback('handEditTyping', function(data, cb)
    cb('ok')
    if ed and type(data) == 'table' and data.on == true then
        Focus.take('handEditTyping', { screen = true, keepInput = false })
    else
        Focus.release('handEditTyping')
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and ed then finish() end
end)
