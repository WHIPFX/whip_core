-- ============================================
-- PLACING MODE — set an item down exactly where you're looking
-- ============================================
--
-- The third sibling of give and throw: right-click an item, Place, and a transparent
-- ghost of its world prop follows the camera ray; E commits it as an ordinary ground
-- item at the ghost's exact spot, C cancels. The point over throwing/dropping is
-- EXACTNESS — a wallet ON the table, a pistol laid on the counter — which is why the
-- server marks these rows `placed` and the ground renderer skips its usual
-- PlaceObjectOnGroundProperly snap for them (client/ground.lua).
--
-- Modelled on give mode (client/inventory.lua): same NUI-callback entry that closes
-- the inventory first, same two-state mode thread, same E/C controls.
--
-- THE SAME GHOST FOR ANY RESOURCE: exports.whip_core:PlaceObject(model, opts) runs this mode for a prop of the
-- caller's (a speaker, a sign) and answers where it was put, instead of making a ground item. Its extras: the arrows
-- (the D-pad's up and down) raise and lower it, Ctrl turns it and raises it finely, and with opts.vehicles it can go
-- on a car, where the answer says which car and where on it (the caller attaches its prop there).

-- Read by client/interact.lua, the same way ThrowModeActive is: while a mode owns
-- the E key and the player's attention, prompts stand down (or E would open a
-- nearby door, or pick the item back up).
PlacingModeActive = false

-- ONE START AT A TIME. A start waits while its ghost's model loads, and PlacingModeActive comes on only after: a second
-- start in that time got past the busy check, its ghost took the first's place, the first's was left in the world and
-- its PlaceObject call was never answered (WLVF's review). While one loads, PlaceObject answers 'busy' and a Place from
-- the inventory is let go.
local placeLoading = false

local startModeLoop   -- the mode's frame loop, started on entry; defined with the loop below

local placeContainer  = nil
local placeSlot       = nil
local placeItemKey    = nil
local placeItemName   = nil
local placeItemAmount = 0
local ghostProp       = nil
local ghostZOffset    = 0.0
local placeValid      = false
local placeHitX, placeHitY, placeHitZ = 0.0, 0.0, 0.0
-- The ghost's OWN heading, independent of where the player faces, owned by the scroll
-- wheel. Seeded from the ped once on entry, then only the wheel changes it.
local placeHeading    = 0.0
-- Pitch/roll matching the surface under the ghost, recomputed per frame from the hit
-- normal and committed with the placement — an item on a slope LIES on the slope.
local placeRx, placeRy = 0.0, 0.0
-- A PlaceObject call's (nil for an item's Place): { p = its promise, label, vehicles, reach, nudge = metres raised,
-- vehicle = the car the ghost is on now or nil }.
local placeSession    = nil
local NUDGE_STEP, NUDGE_FINE = 0.05, 0.01        -- metres per arrow press; with Ctrl held
local NUDGE_MIN, NUDGE_MAX = -0.5, 2.0
local ROTATE_FINE = 2.0                          -- degrees per wheel notch with Ctrl held

-- No timeout: lining up a placement is deliberate work, and the mode has three exits (E, C, death).
local PLACE_ROTATE_STEP = 15.0    -- degrees per scroll notch
-- On a pad the triggers turn it: LT left, RT right, faster the further they are pulled. The triggers,
-- not the D-pad (the player's own buttons): here they are aim and attack, already held off below.
local PLACE_PAD_TURN = 140.0      -- degrees a second at a full pull
local PLACE_PAD_DEAD = 0.08       -- a trigger resting short of this is not pulled
-- The surface must face broadly UP (walls and ceilings are invalid), but 0.1 admits slopes up
-- to ~84°: tilt is stored and rendered, so the item sits at the surface's own angle.
local PLACE_NORMAL_MIN_Z = 0.1

-- ---- bottom-of-screen helper text (the ShowGiveText change-detection pattern) ----

local _lastPlaceText = nil
--- The hint capsule, its disc the place glyph; `warn` rings it amber — nowhere to put it.
local function ShowPlaceText(text, warn)
    if text == _lastPlaceText then return end
    _lastPlaceText = text
    UI.ShowText(text, { position = 'bottom', icon = 'place', tone = warn and 'warn' or nil })
end

local function HidePlaceText()
    if _lastPlaceText == nil then return end
    _lastPlaceText = nil
    UI.HideText()
end

-- ---- the single exit funnel ----
-- Every way out (E-confirm, C, death, re-entry, a failed ghost) lands here,
-- so there is exactly one place that can forget to delete the ghost, and it doesn't.
-- A PlaceObject call still waiting is answered `false, why` (default 'cancelled'); a confirm answers it first.
local function CancelPlaceMode(why)
    if ghostProp and DoesEntityExist(ghostProp) then
        DeleteEntity(ghostProp)
    end
    ghostProp       = nil
    HidePlaceText()
    PlacingModeActive = false
    ControlBlocks.release('placing')
    placeContainer  = nil
    placeSlot       = nil
    placeItemKey    = nil
    placeItemName   = nil
    placeItemAmount = 0
    placeValid      = false
    if placeSession then
        local s = placeSession
        placeSession = nil
        s.p:resolve({ false, why or 'cancelled' })
    end
end

--- The see-through ghost of `model` (a name or hash), hidden until the ray first finds a surface. true, or false when
--- the model will not load or the object cannot be made.
local function makeGhost(model)
    local hash = LoadModel(model)
    if not hash then return false end
    -- The stored z is PIVOT-space: offset so the model's bounding-box base — not its
    -- pivot, which for many props floats mid-model — kisses the surface the ray hit.
    -- The committed coords carry the same offset, so what the ghost shows is exactly
    -- what every client renders (WYSIWYG is the feature's whole contract).
    local minDim = GetModelDimensions(hash)
    ghostZOffset = -(minDim and minDim.z or 0.0)
    local c = GetEntityCoords(PlayerPedId())
    local obj = CreateObject(hash, c.x, c.y, c.z, false, false, false)  -- non-networked: nobody else ever sees the ghost
    SetModelAsNoLongerNeeded(hash)
    if not obj or obj == 0 then return false end
    SetEntityAlpha(obj, 160, false)
    SetEntityCollision(obj, false, false)     -- also keeps the ghost out of its own placement ray
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityVisible(obj, false, false)       -- hidden until the first valid hit
    ghostProp = obj
    return true
end

--- The mode's keys held off: give mode's set plus attack/aim (a stray click should not punch). The wheel turns the
--- ghost: it is held off for weapon switching and read below with the disabled readers; so are the pad's triggers
--- (24 / 25), which turn it on a pad. Reload (45) too: B cancels on a pad. And C (26), the cancel, so it does not
--- swing the camera round as well (read with the disabled reader). A PlaceObject call's also holds the arrows (the
--- height) and Ctrl (fine, and no crouching).
local function holdKeys(session)
    local controls = { 37, 44, 45, 140, 24, 25, 26 }
    if session then
        controls[#controls + 1] = 172
        controls[#controls + 1] = 173
        controls[#controls + 1] = 36
    end
    ControlBlocks.hold('placing', { groups = { 'weaponWheel' }, controls = controls })
end

-- Same resolver as ground.lua's and inventory.lua's file-local copies: the item's own
-- world prop, or the cardboard box everything falls back to.
local function GetPlaceGhostModel(itemKey)
    local def = Config.Items[itemKey]
    if def and def.prop then
        return def.prop
    end
    return Config.DefaultGroundProp
end

-- ---- entry: the NUI 'Place' context option ----

RegisterNUICallback('placeItem', function(data, cb)
    cb('ok')

    -- (One whose ghost is still loading: this Place is let go.)
    if placeLoading then return end

    -- Rapid re-entry: a second Place while a ghost is already up replaces the first
    -- mode wholesale rather than leaking its ghost.
    if PlacingModeActive then
        CancelPlaceMode()
    end

    placeContainer  = data.container
    placeSlot       = data.slot
    placeItemKey    = data.itemKey
    placeItemName   = data.itemName or 'item'
    placeItemAmount = data.itemAmount or 1

    Inventory.close()

    -- The named moment for satellites, exactly like beforeGiveMode: holster, drop a
    -- carried box, put the phone away — anything that needs the hands or the camera.
    RunClientHook('beforePlaceMode')

    -- Build the ghost. A model that will not load falls back to the default prop; if
    -- even that fails, abort loudly — nothing has been sent, the item never moved.
    placeLoading = true
    local okG, made = pcall(function()
        return makeGhost(GetPlaceGhostModel(placeItemKey)) or makeGhost(Config.DefaultGroundProp)
    end)
    placeLoading = false
    if not (okG and made) then
        UI.Notify('Cannot place that here', 'error')
        CancelPlaceMode()
        return
    end

    placeHeading = GetEntityHeading(PlayerPedId())
    PlacingModeActive = true
    holdKeys(false)
    startModeLoop()
end)

-- ---- entry: PlaceObject, for any resource ----

--- Let the player put a prop of yours down exactly: the item placer's ghost of `model` follows where they look, the
--- wheel turns it, the arrows raise and lower it, E puts it there, C cancels. WAITS for them: call it from a thread.
---   opts.label     what the hint calls it ('Speaker'; default 'it')
---   opts.vehicles  true: it may go on a car (on its roof, its bed); the answer then says which car and where on it
---   opts.reach     metres from the camera it may go (default the item placer's, Config.PlaceItemRange)
--- Answers { coords = vector3, rot = vector3(tiltForward, tiltSideways, heading) } where it was put — on a car also
--- { netId = the car's, offset = vector3, offsetRot = vector3 } in the car's own frame, for AttachEntityToEntity or a
--- prop set's attach — or false, why: 'cancelled', 'busy' (something else is being placed), 'model' (it will not
--- load), 'dead' (they went down).
local function placeObject(model, opts)
    if type(model) ~= 'string' and type(model) ~= 'number' then return false, 'model' end
    opts = type(opts) == 'table' and opts or {}
    if PlacingModeActive or placeLoading then return false, 'busy' end
    if PlayerIsDead then return false, 'dead' end
    placeLoading = true
    local okG, made = pcall(function()
        RunClientHook('beforePlaceMode')
        return makeGhost(model)
    end)
    placeLoading = false
    if not (okG and made) then return false, 'model' end
    if PlayerIsDead then CancelPlaceMode('dead') return false, 'dead' end   -- (went down while it loaded)
    local label = type(opts.label) == 'string' and opts.label ~= '' and opts.label:sub(1, 40) or 'it'
    placeSession = { p = promise.new(), label = label, vehicles = opts.vehicles == true,
                     reach = math.max(1.0, math.min(10.0, tonumber(opts.reach) or Config.PlaceItemRange or 3.5)),
                     nudge = 0.0 }
    placeItemName = label
    placeHeading = GetEntityHeading(PlayerPedId())
    PlacingModeActive = true
    holdKeys(true)
    local p = placeSession.p
    startModeLoop()
    local answer = Citizen.Await(p)
    if answer[1] == false then return false, answer[2] end
    return answer[1]
end
exports('PlaceObject', function(model, opts) return placeObject(model, opts) end)

-- ---- the mode thread (give mode's two-state skeleton), started on entry, ended with the mode ----

local modeLoopRunning = false

local function modeLoop()
    while true do
        if PlacingModeActive then
            -- Death ends the mode the frame it happens, and so does being knocked down (a long fall is said
            -- as falling); both say so on the capsule before the mode takes its text down (UI.ShowInterrupted).
            local stopped = (PlayerIsDead and 'You went down')
                or (IsPedRagdoll(PlayerPedId()) and BodyState.ragdollWhy(PlayerPedId())) or nil
            if stopped then
                UI.ShowInterrupted(stopped, 'Placing ' .. tostring(placeItemName))
                CancelPlaceMode(PlayerIsDead and 'dead' or 'cancelled')
            else
                -- Scroll = rotate, independent of everything else. GTA headings grow
                -- counter-clockwise, so wheel UP turns the item left, DOWN turns it
                -- right, 15° a notch; % keeps it in the event's 0..360 param range.
                -- (A PlaceObject call's: 2° with Ctrl held, and the arrows raise and lower it.)
                local session = placeSession
                local fine = session ~= nil and IsDisabledControlPressed(0, 36)
                local step = fine and ROTATE_FINE or PLACE_ROTATE_STEP
                if IsDisabledControlJustPressed(0, 17) then          -- wheel up → left
                    placeHeading = (placeHeading + step) % 360.0
                elseif IsDisabledControlJustPressed(0, 16) then      -- wheel down → right
                    placeHeading = (placeHeading - step) % 360.0
                end
                if session then
                    local n = fine and NUDGE_FINE or NUDGE_STEP
                    if IsDisabledControlJustPressed(0, 172) then          -- up arrow / D-pad up
                        session.nudge = math.min(NUDGE_MAX, session.nudge + n)
                    elseif IsDisabledControlJustPressed(0, 173) then      -- down arrow / D-pad down
                        session.nudge = math.max(NUDGE_MIN, session.nudge - n)
                    end
                end
                if WhipPadActive then                                 -- LT → left, RT → right
                    local pull = WhipPadTrigger('lt', PLACE_PAD_DEAD) - WhipPadTrigger('rt', PLACE_PAD_DEAD)
                    if pull ~= 0.0 then
                        local turn = PLACE_PAD_TURN * pull * math.abs(pull) * GetFrameTime()   -- squared: a light pull is fine
                        placeHeading = (placeHeading + turn) % 360.0
                    end
                end

                local ped = PlayerPedId()
                local camPos = GetFinalRenderedCamCoord()
                -- InteractGetCameraForward is interact.lua's shared global: every "where am I
                -- looking" answers with the same maths.
                local fx, fy, fz = InteractGetCameraForward()
                local reach = session and session.reach or Config.PlaceItemRange or 3.5
                local endX = camPos.x + fx * reach
                local endY = camPos.y + fy * reach
                local endZ = camPos.z + fz * reach

                -- World + vehicles + objects + pickups + glass (1+2+16+32+64 = 115). Placing on a
                -- bonnet works, but a ground item is frozen in world space and hangs mid-air if the
                -- car drives away. Peds, foliage and water stay out of the mask.
                --
                -- Props with their collision off are invisible to every shape test, which is every
                -- prop whip spawns (ground items, stash and shop props), so the preview passes
                -- straight through an already-placed item.
                local ray = StartShapeTestRay(camPos.x, camPos.y, camPos.z, endX, endY, endZ, 115, ped, 0)
                local _, hit, hitCoords, surfaceNormal, hitEntity = GetShapeTestResult(ray)

                placeValid = hit == 1
                    and surfaceNormal and surfaceNormal.z >= PLACE_NORMAL_MIN_Z
                -- A PlaceObject call's ghost on a car: only when the caller takes cars (it attaches its prop there);
                -- else it would hang in the air once the car drove off.
                local onCar = placeValid and hitEntity and hitEntity ~= 0 and DoesEntityExist(hitEntity)
                    and GetEntityType(hitEntity) == 2 and hitEntity or nil
                local notOnCar = session ~= nil and onCar ~= nil and not session.vehicles
                if notOnCar then placeValid = false end
                if session then session.vehicle = onCar end

                if placeValid and ghostProp and DoesEntityExist(ghostProp) then
                    placeHitX = hitCoords.x
                    placeHitY = hitCoords.y
                    placeHitZ = hitCoords.z + ghostZOffset + (session and session.nudge or 0.0)

                    -- Lie ON the surface, not across it: tilt the ghost so its up-axis
                    -- follows the hit normal while the scroll wheel keeps owning yaw.
                    -- Derivation (exact for yaw→pitch→roll composition): rotate the
                    -- normal into the yawed local frame — forward = (-sin h, cos h),
                    -- right = (cos h, sin h) — then pitch from n·forward, roll from
                    -- n·right.
                    --
                    -- The signs are empirical, verified in game: the textbook signs (pitch = +atan2,
                    -- roll = -asin) lean every item INTO the hill. If tilts ever mirror again, these
                    -- two leading signs are the knobs.
                    local h = math.rad(placeHeading)
                    local sinH, cosH = math.sin(h), math.cos(h)
                    local nF = -surfaceNormal.x * sinH + surfaceNormal.y * cosH
                    local nR =  surfaceNormal.x * cosH + surfaceNormal.y * sinH
                    if nR > 1.0 then nR = 1.0 elseif nR < -1.0 then nR = -1.0 end
                    placeRx = -math.deg(math.atan(nF, surfaceNormal.z))
                    placeRy = math.deg(math.asin(nR))

                    SetEntityCoordsNoOffset(ghostProp, placeHitX, placeHitY, placeHitZ, false, false, false)
                    SetEntityRotation(ghostProp, placeRx, placeRy, placeHeading, 2, true)
                    SetEntityVisible(ghostProp, true, false)
                    SetEntityAlpha(ghostProp, 160, false)
                    if session then
                        ShowPlaceText(WhipAcceptHint() .. ' Place ' .. placeItemName .. (onCar and ' on the car' or '')
                            .. '  |  ' .. WhipKeyHint('Scroll', { 'lt', 'rt' }) .. ' Rotate  |  '
                            .. WhipKeyHint('Up/Down', { 'dpad_up', 'dpad_down' }) .. ' Height  |  '
                            .. (WhipPadActive and '' or '[Ctrl] Fine  |  ') .. WhipCancelHint() .. ' Cancel')
                    else
                        ShowPlaceText(WhipAcceptHint() .. ' Place ' .. placeItemName .. '  |  '
                            .. WhipKeyHint('Scroll', { 'lt', 'rt' }) .. ' Rotate  |  ' .. WhipCancelHint() .. ' Cancel')
                    end
                else
                    -- The invalid state: no ghost, and the text says why in plain words.
                    if ghostProp and DoesEntityExist(ghostProp) then
                        SetEntityVisible(ghostProp, false, false)
                    end
                    ShowPlaceText((notOnCar and 'Not on a car' or 'Aim at a surface within reach') .. '  |  '
                        .. WhipCancelHint() .. ' Cancel', true)
                end

                -- Disabled readers: E and C still count while another block holds them. E is A on a
                -- pad, never LB + A (controller.lua, WhipAcceptJustPressed); C is B (WhipCancelJustPressed).
                if placeValid and session and WhipAcceptJustPressed() then      -- E / A, a PlaceObject call's
                    -- Where it was put; on a car, where on that car (its own frame), for the caller to attach to.
                    local answer = { coords = vector3(placeHitX, placeHitY, placeHitZ),
                                     rot = vector3(placeRx, placeRy, placeHeading) }
                    local car = session.vehicle
                    if car and DoesEntityExist(car) and NetworkGetEntityIsNetworked(car) then
                        answer.netId = NetworkGetNetworkIdFromEntity(car)
                        answer.offset = GetOffsetFromEntityGivenWorldCoords(car, placeHitX, placeHitY, placeHitZ)
                        -- Its turn within the car's: the car's taken off its own (rotation order 2, as AttachEntityToEntity
                        -- reads it). Its angles less the car's were right only on a level car or facing the car's way: a
                        -- speaker turned on the roof of a car on a slope sat tilted (WLVF's second review).
                        local cr = GetEntityRotation(car, 2)
                        local qc = CamMath.quatFromEuler(cr.x, cr.y, cr.z)
                        local q = CamMath.quatMul({ qc[1], -qc[2], -qc[3], -qc[4] }, CamMath.quatFromEuler(placeRx, placeRy, placeHeading))
                        local rx, ry, rz = CamMath.quatToEuler(q)
                        answer.offsetRot = vector3(rx, ry, rz % 360.0)
                    end
                    placeSession = nil
                    CancelPlaceMode()
                    session.p:resolve({ answer })
                elseif placeValid and WhipAcceptJustPressed() then              -- E / A
                    -- Optimistic exit, the same bet the throw makes: the server either
                    -- takes the item and creates the row, or never takes it / rolls it
                    -- back and the inventory revert puts the truth back on screen.
                    TriggerServerEvent('whip_core:server:placeItem',
                        placeContainer, placeSlot, placeItemAmount,
                        placeHitX, placeHitY, placeHitZ, placeHeading,
                        placeRx, placeRy)
                    CancelPlaceMode()
                elseif WhipCancelJustPressed() then                             -- C / B
                    CancelPlaceMode()
                    UI.Notify('Place cancelled', 'error')
                end
            end
            Wait(0)
        else
            break
        end
    end
    modeLoopRunning = false
end

startModeLoop = function()
    if modeLoopRunning then return end
    modeLoopRunning = true
    CreateThread(modeLoop)
end

-- A logout ends it: the mode outlived character select, and E then placed whatever the next character had in
-- the slot this one picked.
AddEventHandler('whip_core:player:logout', function()
    if PlacingModeActive or placeSession then CancelPlaceMode('logout') end
end)

-- A restart mid-placement must not orphan a ghost in the world; the rest of the state
-- dies with the Lua VM.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if ghostProp and DoesEntityExist(ghostProp) then
        DeleteEntity(ghostProp)
    end
end)
