-- ============================================
-- ESCORT SYSTEM — client/escort.lua
-- Grab players and move them (the arrow keys, below). Seating someone in a car and pulling them out
-- are handled here and on the server, but nothing offers them yet: they wait for prompts on the
-- car's doors. Loads BEFORE death.lua.
-- ============================================

local escortTarget       = nil    -- serverId of player we're escorting
local isBeingEscorted    = false  -- true if we're being escorted
local escortedBySource   = nil    -- serverId of person escorting us

-- ============================================
-- Exports
-- ============================================

exports('IsEscorting', function() return escortTarget ~= nil end)
exports('IsBeingEscorted', function() return isBeingEscorted end)
exports('GetEscortTarget', function() return escortTarget end)

-- ============================================
-- Helpers
-- ============================================

local function getPlayerPedFromServerId(serverId)
    local playerId = GamePlatform.playerIndex(serverId)
    if playerId then
        return GetPlayerPed(playerId)
    end
    return nil
end

local function findNearestPlayerPed(range)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local bestPed, bestDist, bestServerId = nil, range * range, nil

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= PlayerId() then
            local ped = GetPlayerPed(playerId)
            if ped and ped ~= 0 and DoesEntityExist(ped) then
                local pos = GetEntityCoords(ped)
                local dx = pos.x - myCoords.x
                local dy = pos.y - myCoords.y
                local dz = pos.z - myCoords.z
                local distSq = dx*dx + dy*dy + dz*dz
                if distSq < bestDist then
                    local sid = GetPlayerServerId(playerId)
                    local pState = Player(sid).state
                    if not pState[PLAYER_ESCORTED_KEY] and not IsPedInAnyVehicle(ped, false) then
                        bestDist = distSq
                        bestPed = ped
                        bestServerId = sid
                    end
                end
            end
        end
    end
    return bestPed, bestServerId
end

-- ============================================
-- Attach / Detach
-- ============================================

local function detachSelf()
    local myPed = PlayerPedId()
    DetachEntity(myPed, true, false)
    SetPedCanRagdoll(myPed, true)
end

--- Let go of whoever is carrying us, HERE, before anything moves us — for a respawn (client/death.lua
--- DoRespawn), which teleports to a hospital. The per-frame re-attach below would otherwise snap the
--- respawned ped straight back onto the holder before the server's release arrived (audit 4, PLY-4:
--- a respawn while carried came back at full health where they were held). The server ends the
--- escort on its side when the respawn reaches it (events_misc.lua playerRespawned).
function EscortReleaseSelf()
    if isBeingEscorted then detachSelf() end
    isBeingEscorted = false
    escortedBySource = nil
end

-- ============================================
-- Control Lock + Per-Frame Re-Attach Thread
-- (escorted player — runs every frame)
-- ============================================
--
-- BOTH THREADS HERE RUN ONLY WHILE THERE IS AN ESCORT (audit 4, CLI-5). They ran all session on
-- every client, waking to find nobody held; each now starts when its escort does and ends with it.

local escortedLoopRunning, holderLoopRunning = false, false

local function escortedLoop()
    while isBeingEscorted and escortedBySource do
        local myPed = PlayerPedId()
        local escorterPed = getPlayerPedFromServerId(escortedBySource)

        -- Disable ragdoll on escorted ped (prevents wobble)
        SetPedCanRagdoll(myPed, false)

        -- Per-frame re-attach to prevent networked ped drift/wobble
        if escorterPed and DoesEntityExist(escorterPed) then
            AttachEntityToEntity(myPed, escorterPed, 11816,
                0.54, 0.54, 0.0,
                0.0, 0.0, 0.0,
                false,   -- p9
                false,   -- useSoftPinning (rigid)
                false,   -- collision between peds OFF
                true,    -- isPed
                2,       -- vertexIndex (ped-to-ped)
                true     -- fixedRot
            )
        end
        Wait(0)
    end
    ControlBlocks.release('escorted')
    escortedLoopRunning = false
end

local function startEscortedLoop()
    -- Walking, sprint, jump and getting in or out of a car, held off while carried (the one control
    -- loop); this loop keeps the per-frame re-attach.
    ControlBlocks.hold('escorted', { controls = { 30, 31, 21, 22, 23, 75 } })
    if escortedLoopRunning then return end
    escortedLoopRunning = true
    CreateThread(escortedLoop)
end

-- ============================================
-- Safety Monitor Thread (escort holder)
-- ============================================

local function holderLoop()
    -- Half a second before the first look, as the old always-on loop gave a fresh grab to settle.
    Wait(500)
    while escortTarget do
        local myPed = PlayerPedId()
        local targetPed = getPlayerPedFromServerId(escortTarget)

        local shouldRelease = false

        if not targetPed or not DoesEntityExist(targetPed) then
            shouldRelease = true
        elseif IsPedRagdoll(myPed) or IsPedRagdoll(targetPed) then
            shouldRelease = true
        elseif IsEntityDead(myPed) then
            shouldRelease = true
        else
            local myCoords = GetEntityCoords(myPed)
            local tgtCoords = GetEntityCoords(targetPed)
            local dx = myCoords.x - tgtCoords.x
            local dy = myCoords.y - tgtCoords.y
            local distSq = dx*dx + dy*dy
            if distSq > 100.0 then -- 10m squared
                shouldRelease = true
            end
        end

        if shouldRelease then
            -- OPTIMISTIC: clear our half immediately instead of waiting for the server's
            -- escortReleased reply to do it. This was level-triggered — a delayed or
            -- dropped reply meant another releaseEscort every 500ms, indefinitely — and
            -- every condition above is a state we already know is broken, so there is
            -- nothing to keep. escortStarted re-establishes the target if the server
            -- disagrees.
            escortTarget = nil
            TriggerServerEvent('whip_core:server:releaseEscort')
        end

        Wait(500)
    end
    holderLoopRunning = false
end

local function startHolderLoop()
    if holderLoopRunning then return end
    holderLoopRunning = true
    CreateThread(holderLoop)
end

-- ============================================
-- Server → Client Events
-- ============================================

-- We started escorting someone
RegisterNetEvent('whip_core:client:escortStarted', function(targetServerId)
    escortTarget = targetServerId
    if escortTarget then startHolderLoop() end
end)

-- Someone is escorting us
RegisterNetEvent('whip_core:client:youAreEscorted', function(bySource)
    isBeingEscorted = true
    escortedBySource = bySource
    -- The per-frame thread handles attachment
    if escortedBySource then startEscortedLoop() end
end)

-- Server rejected our escort attempt (revert optimistic state). The reason is whip's toast: the
-- server's handler answers `false, reason`, which shows it (UI-1).
RegisterNetEvent('whip_core:client:escortFailed', function()
    escortTarget = nil
end)

-- Escort released (sent to both players)
RegisterNetEvent('whip_core:client:escortReleased', function()
    if isBeingEscorted then
        detachSelf()
        isBeingEscorted = false
        escortedBySource = nil
        -- If dead, unfreeze to let gravity settle then refreeze
        if PlayerIsDead and DeathRefreezeAfterDrop then
            DeathRefreezeAfterDrop()
        end
    end
    escortTarget = nil
end)

-- Seat us in vehicle
RegisterNetEvent('whip_core:client:seatInVehicle', function(vehicleNetId, seatIndex)
    local vehicle = NetworkGetEntityFromNetworkId(vehicleNetId)
    if not vehicle or not DoesEntityExist(vehicle) then return end
    local myPed = PlayerPedId()

    -- Ensure vehicle is registered before seating (prevents unknown vehicle state)
    Vehicles.resolve(vehicle)

    TaskWarpPedIntoVehicle(myPed, vehicle, seatIndex)
end)

-- Pulled out of a vehicle. Only OUT: the escort itself starts when the server has recorded it and
-- says so (youAreEscorted). This used to mark us escorted here, before the server agreed, and a
-- server that then changed its mind never told us — frozen until /logout (audit 3, H7).
RegisterNetEvent('whip_core:client:pullFromVehicle', function()
    -- Dead in the seat: a dead ped takes no task, so death.lua lays them beside the door.
    if DeathPullFromSeat and DeathPullFromSeat() then return end
    local myPed = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(myPed, false)
    if vehicle and vehicle ~= 0 then
        TaskLeaveVehicle(myPed, vehicle, 16) -- 16 = teleport out
    end
end)

-- ============================================
-- Keybinds
-- ============================================

-- Both keys ask IsGameInputFree first (audit 5, CLI-1): the arrows are the furnisher's nudge keys,
-- and every nudge also grabbed (or looked for) a player.
RegisterCommand('escort_grab', function()
    if not IsGameInputFree() then return end
    if not PlayerLoaded or PlayerIsDead or escortTarget or isBeingEscorted then return end
    if IsPedInAnyVehicle(PlayerPedId(), false) then return end
    local _, serverId = findNearestPlayerPed(3.0)
    if serverId then
        TriggerServerEvent('whip_core:server:escortPlayer', serverId)
    else
        UI.Notify('No player nearby', 'error')
    end
end, false)
RegisterKeyMapping('escort_grab', 'Escort Player', 'keyboard', 'LEFT')

RegisterCommand('escort_release', function()
    if not escortTarget or not IsGameInputFree() then return end
    TriggerServerEvent('whip_core:server:releaseEscort')
end, false)
RegisterKeyMapping('escort_release', 'Release Escort', 'keyboard', 'RIGHT')

-- ============================================
-- Cleanup
-- ============================================

RegisterNetEvent('whip_core:client:playerLogout', function()
    if isBeingEscorted then detachSelf() end
    escortTarget = nil
    isBeingEscorted = false
    escortedBySource = nil
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if isBeingEscorted then detachSelf() end
    escortTarget = nil
    isBeingEscorted = false
    escortedBySource = nil
end)
