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

-- Read by client/interact.lua, the same way ThrowModeActive is: while a mode owns
-- the E key and the player's attention, prompts stand down (or E would open a
-- nearby door, or pick the item back up).
PlacingModeActive = false

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
local function CancelPlaceMode()
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
    local modelName = GetPlaceGhostModel(placeItemKey)
    local model = LoadModel(modelName)
    if not model then
        modelName = Config.DefaultGroundProp
        model = LoadModel(modelName)
        if not model then
            UI.Notify('Cannot place that here', 'error')
            CancelPlaceMode()
            return
        end
    end

    -- The stored z is PIVOT-space: offset so the model's bounding-box base — not its
    -- pivot, which for many props floats mid-model — kisses the surface the ray hit.
    -- The committed coords carry the same offset, so what the ghost shows is exactly
    -- what every client renders (WYSIWYG is the feature's whole contract).
    local minDim = GetModelDimensions(model)
    ghostZOffset = -(minDim and minDim.z or 0.0)

    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local obj = CreateObject(model, c.x, c.y, c.z, false, false, false)  -- non-networked: nobody else ever sees the ghost
    SetModelAsNoLongerNeeded(model)
    if not obj or obj == 0 then
        UI.Notify('Cannot place that here', 'error')
        CancelPlaceMode()
        return
    end

    SetEntityAlpha(obj, 160, false)
    SetEntityCollision(obj, false, false)     -- also keeps the ghost out of its own placement ray
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, true, true)
    SetEntityVisible(obj, false, false)       -- hidden until the first valid hit

    ghostProp = obj
    placeHeading = GetEntityHeading(ped)
    PlacingModeActive = true
    -- Give mode's set plus attack/aim (a stray click should not punch). The wheel turns the ghost: it is
    -- held off for weapon switching and read below with the disabled readers; so are the pad's triggers
    -- (24 / 25), which turn it on a pad. Reload (45) too: B cancels on a pad. And C (26), the cancel, so it
    -- does not swing the camera round as well (read with the disabled reader).
    ControlBlocks.hold('placing', { groups = { 'weaponWheel' }, controls = { 37, 44, 45, 140, 24, 25, 26 } })
    startModeLoop()
end)

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
                CancelPlaceMode()
            else
                -- Scroll = rotate, independent of everything else. GTA headings grow
                -- counter-clockwise, so wheel UP turns the item left, DOWN turns it
                -- right, 15° a notch; % keeps it in the event's 0..360 param range.
                if IsDisabledControlJustPressed(0, 17) then          -- wheel up → left
                    placeHeading = (placeHeading + PLACE_ROTATE_STEP) % 360.0
                elseif IsDisabledControlJustPressed(0, 16) then      -- wheel down → right
                    placeHeading = (placeHeading - PLACE_ROTATE_STEP) % 360.0
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
                local reach = Config.PlaceItemRange or 3.5
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
                local _, hit, hitCoords, surfaceNormal = GetShapeTestResult(ray)

                placeValid = hit == 1
                    and surfaceNormal and surfaceNormal.z >= PLACE_NORMAL_MIN_Z

                if placeValid and ghostProp and DoesEntityExist(ghostProp) then
                    placeHitX = hitCoords.x
                    placeHitY = hitCoords.y
                    placeHitZ = hitCoords.z + ghostZOffset

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
                    ShowPlaceText(WhipAcceptHint() .. ' Place ' .. placeItemName .. '  |  '
                        .. WhipKeyHint('Scroll', { 'lt', 'rt' }) .. ' Rotate  |  ' .. WhipCancelHint() .. ' Cancel')
                else
                    -- The invalid state: no ghost, and the text says why in plain words.
                    if ghostProp and DoesEntityExist(ghostProp) then
                        SetEntityVisible(ghostProp, false, false)
                    end
                    ShowPlaceText('Aim at a surface within reach  |  ' .. WhipCancelHint() .. ' Cancel', true)
                end

                -- Disabled readers: E and C still count while another block holds them. E is A on a
                -- pad, never LB + A (controller.lua, WhipAcceptJustPressed); C is B (WhipCancelJustPressed).
                if placeValid and WhipAcceptJustPressed() then                  -- E / A
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

-- A restart mid-placement must not orphan a ghost in the world; the rest of the state
-- dies with the Lua VM.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if ghostProp and DoesEntityExist(ghostProp) then
        DeleteEntity(ghostProp)
    end
end)
