-- ============================================
-- Dev Tools — Invisible, God Mode, Restore Player Cores, Kill Me, Repair Vehicle
-- ============================================
--
-- Five /w entries for whoever has dev tools:
--   Invisible                nobody else sees you; you see yourself at half opacity
--   God Mode                 no damage, and health kept full whatever else tries to take it
--   Restore Player Cores     your health, armour, food and drink full
--   Kill Me                  you go down at once, as any death does
--   Repair Vehicle           the car you are in repaired, driving it or not
--
-- Hidden and invincible are PED HOLDS (client/ped_hold.lua): death, character select and
-- the editors hold the same flags without cancelling these, and a new ped gets them back. What is left
-- per frame is a hook each on ControlBlocks (an empty spec: no controls held), only while on: drawing
-- yourself at half opacity, and topping health up. Both hooks stand aside while no character is loaded.

-- ---- Invisible ----

local INVISIBLE_ALPHA = 128   -- how much of yourself you see: half

local function invisibleFrame()
    if not PlayerLoaded then return end
    local ped = PlayerPedId()
    -- Hidden from everyone by the hold; drawn for this player, this frame, at half opacity.
    SetEntityLocallyVisible(ped)
    if GetEntityAlpha(ped) ~= INVISIBLE_ALPHA then SetEntityAlpha(ped, INVISIBLE_ALPHA, false) end
end

ToolHandlers['Invisible'] = {
    enter = function()
        PedHold.set('devInvisible', { hidden = true })
        ControlBlocks.hold('devInvisible', {}, invisibleFrame)
    end,
    exit = function()
        ControlBlocks.release('devInvisible')
        PedHold.release('devInvisible')
        ResetEntityAlpha(PlayerPedId())
    end,
}

-- ---- God Mode ----

local function godFrame()
    if not PlayerLoaded then return end
    -- Health taken by anything but the game's own damage (a need at zero, a script) is put back. The
    -- ped's health is reported to the server as usual, so the server's copy follows it.
    local ped = PlayerPedId()
    local max = GetEntityMaxHealth(ped)
    if GetEntityHealth(ped) < max then SetEntityHealth(ped, max) end
end

ToolHandlers['God Mode'] = {
    enter = function()
        PedHold.set('devGod', { invincible = true })
        ControlBlocks.hold('devGod', {}, godFrame)
    end,
    exit = function()
        ControlBlocks.release('devGod')
        PedHold.release('devGod')   -- death's own hold keeps a downed player invincible
    end,
}

-- ---- Restore Player Cores ----

--- A one-off, not a toggle: it never stays lit (isActive). Health, armour, food and drink are the server's
--- (server/devtools.lua), which says when it is done.
ToolHandlers['Restore Player Cores'] = {
    enter = function() TriggerServerEvent('whip_core:server:devRestore') end,
    exit = function() end,
    isActive = function() return false end,
}

-- ---- Teleport to Waypoint ----

--- A one-off: /tpm (server/commands.lua), so the same whip.devtools check and the same activity log line. The waypoint
--- is read on this game when the server answers (client/main.lua whip_core:client:tpWaypoint).
ToolHandlers['Teleport to Waypoint'] = {
    enter = function() ExecuteCommand('tpm') end,
    exit = function() end,
    isActive = function() return false end,
}

-- ---- Kill Me ----

--- A one-off. The server checks it is an admin's and that they are up (server/devtools.lua), then says
--- go. The ped's health goes to zero and nothing else: client/death.lua's poll finds the death and
--- everything after is a death's own (the report the server checks against the ped, the screen, the
--- respawn), so in a car you stay slumped in the seat. Noclip and God Mode are off before it is asked
--- (its `ends`, tools/core.lua).
ToolHandlers['Kill Me'] = {
    enter = function() TriggerServerEvent('whip_core:server:devKillMe') end,
    exit = function() end,
    isActive = function() return false end,
}

RegisterNetEvent('whip_core:client:devKillMe', function()
    -- Out of Noclip and God Mode first, as the Kill Me row does (tools/core.lua `ends`): God Mode would put the health
    -- straight back, and /whip_kill or the Player Manager can down a staff member who has either on.
    for _, name in ipairs({ 'Noclip', 'God Mode' }) do
        if DevToolActive(name) then SetDevTool(name, false) end
    end
    local ped = PlayerPedId()
    if not IsEntityDead(ped) then SetEntityHealth(ped, 0) end
end)

-- ---- Repair Vehicle ----

--- A one-off too. The SERVER finds the car this player is in and has the game that owns it do the
--- repair (server/devtools.lua): repair natives need network control, and a car another player is
--- driving belongs to their game, which is why Fix Me could only fix a car you were driving.
ToolHandlers['Repair Vehicle'] = {
    enter = function() TriggerServerEvent('whip_core:server:devRepairVehicle') end,
    exit = function() end,
    isActive = function() return false end,
}

--- Asked by the server: repair this car. Sent to the game that owns it, so it normally has control
--- already; a car nobody held comes to the admin's own game, which takes it first. A car that is not
--- here (it left this game's range since) is left alone.
RegisterNetEvent('whip_core:client:devRepairVehicle', function(netId)
    if type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return end
    local veh = NetToVeh(netId)
    if veh == 0 or not DoesEntityExist(veh) then return end
    CreateThread(function()
        if not NetworkHasControlOfEntity(veh) and not Vehicles.takeControl(veh) then return end
        SetVehicleFixed(veh)
        SetVehicleDeformationFixed(veh)
        SetVehicleEngineHealth(veh, 1000.0)
        SetVehicleBodyHealth(veh, 1000.0)
        SetVehiclePetrolTankHealth(veh, 1000.0)
        SetVehicleDirtLevel(veh, 0.0)
    end)
end)
