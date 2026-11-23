-- Client entry point: character list, character select NUI callbacks, utility commands.

local characterList = {}
local maxCharacters = Config.MaxCharacters

-- Ask for the character list, and ask again if no answer comes: joining and /logout both go black and ask. A lost
-- request is asked again every few seconds, at most REQUEST_TRIES times, then the player is told to reconnect.
local REQUEST_TRIES, REQUEST_WAIT_MS = 6, 5000
local charsAnswered, charsRequestGen = false, 0

function RequestCharacterList()
    charsAnswered = false
    charsRequestGen = charsRequestGen + 1
    local gen = charsRequestGen
    CreateThread(function()
        for _ = 1, REQUEST_TRIES do
            if charsAnswered or gen ~= charsRequestGen then return end
            TriggerServerEvent('whip_core:server:requestCharacters')
            local waited = 0
            while not charsAnswered and gen == charsRequestGen and waited < REQUEST_WAIT_MS do
                Wait(250)
                waited = waited + 250
            end
        end
        if not charsAnswered and gen == charsRequestGen then
            UI.Notify('Could not get your characters from the server — please reconnect', 'error', 30000)
        end
    end)
end

-- The server could not send a fresh list (e.g. a database error): ask, with the retries.
RegisterNetEvent('whip_core:client:charactersStale', function()
    RequestCharacterList()
end)

-- Receive the character list from the server and show the screen

RegisterNetEvent('whip_core:client:receiveCharacters', function(chars, maxChars)
    charsAnswered = true
    characterList = chars or {}
    maxCharacters = maxChars or Config.MaxCharacters

    -- CharSelect.Open owns the NUI message and the focus; it runs in a thread because it waits on the fade and camera.
    CreateThread(function()
        CharSelect.Open(characterList, maxCharacters)
    end)
end)

-- Hide the NUI when a character loads

RegisterNetEvent('whip_core:client:playerLoaded', function()
    -- Close() deletes the preview peds, stops the camera and restores the local ped's collision and visibility.
    -- This happens behind a black screen (BeginLoad and BeginCreate fade out first); client/player.lua raises
    -- the picture again. keepFaded is required: without it Close() ends the blackout, which is the only thing
    -- hiding the character being rebuilt and moved across the map.
    CharSelect.EndLoad()
    CharSelect.Close(true)
    SendNUIMessage({ action = 'hide' })
    Focus.release('charselect')   -- Close(true) keeps it, for the black
end)

-- Toasts via UI.Notify. NotifyPlayer, ShowError and ShowSuccess all send `notify`. While the admin panel is on
-- screen, success and error land in its result strip instead; info and warning stay in the world corner.
-- WhipPanelIsVisible (not IsOpen) so a suspended panel still gets the world toast. `duration` (ms) is optional;
-- pass it when the player needs time to read.
local NOTIFY_KINDS = { info = true, success = true, warning = true, error = true }

local function showToast(message, kind, duration)
    if not NOTIFY_KINDS[kind] then kind = 'info' end
    if (kind == 'success' or kind == 'error') and WhipPanelIsVisible and WhipPanelIsVisible() then
        WhipPanelResult(message, kind == 'success' and 'ok' or 'err')
    else
        UI.Notify(message, kind, tonumber(duration))
    end
end

RegisterNetEvent('whip_core:client:notify', showToast)

-- Player Manager: teleport to coords
RegisterNetEvent('whip_core:client:pmTeleport', function(x, y, z)
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, x, y, z + 1.0, false, false, false)
end)

--- The ground under x, y, for a teleport given no height: the world there is streamed in first (GTA only knows the
--- ground of what is loaded), then tried from high up down. nil when none was found.
local function groundUnder(ent, x, y)
    for _, probe in ipairs({ 1000.0, 800.0, 600.0, 400.0, 300.0, 200.0, 150.0, 100.0, 50.0, 25.0, 0.0 }) do
        SetEntityCoordsNoOffset(ent, x, y, probe, false, false, false)
        RequestCollisionAtCoord(x, y, probe)
        local untilMs = GetGameTimer() + 400
        repeat
            local found, gz = GetGroundZFor_3dCoord(x, y, probe, false)
            if found then return gz end
            Wait(0)
        until GetGameTimer() > untilMs
    end
    return nil
end

--- A teleport behind a fade: fade, move, wait for the ground, fade back. Waits are bounded, so the screen always returns.
--- No z: onto the ground there. withVehicle: a car this player drives comes along (/tp, /tpm, /back, /bring in server/commands.lua).
local fadeTeleporting = false
local lastTeleportFrom = nil
local function fadeTeleport(x, y, z, heading, withVehicle)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y) or fadeTeleporting then return end
    fadeTeleporting = true

    DoScreenFadeOut(250)
    local t = GetGameTimer() + 1000
    while not IsScreenFadedOut() and GetGameTimer() < t do Wait(0) end

    local ped = PlayerPedId()
    local veh = withVehicle and GetVehiclePedIsIn(ped, false) or 0
    local car = veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped and veh or nil
    local ent = car or ped
    local prev = GetEntityCoords(ent)
    lastTeleportFrom = { x = prev.x, y = prev.y, z = prev.z, heading = GetEntityHeading(ent) }
    PedHold.set('fadeTeleport', { frozen = true })
    if car then FreezeEntityPosition(car, true) end
    if not z then
        NewLoadSceneStartSphere(x, y, 100.0, 80.0, 0)
        local gz = groundUnder(ent, x, y)
        NewLoadSceneStop()
        if not gz then UI.Notify('No ground found there: you are left high up', 'error') end
        z = (gz or 400.0) + (car and 0.5 or 1.0)
    end
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
    if tonumber(heading) then SetEntityHeading(ent, tonumber(heading) + 0.0) end
    t = GetGameTimer() + 3000
    while not HasCollisionLoadedAroundEntity(ent) and GetGameTimer() < t do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end
    if car then
        FreezeEntityPosition(car, false)
        SetVehicleOnGroundProperly(car)
    end
    PedHold.release('fadeTeleport')   -- its own hold: a downed player stays frozen (client/ped_hold.lua)

    DoScreenFadeIn(250)
    fadeTeleporting = false
end
RegisterNetEvent('whip_core:client:fadeTeleport', fadeTeleport)

-- /tpm: the waypoint is on this game's map only
RegisterNetEvent('whip_core:client:tpWaypoint', function()
    local blip = GetFirstBlipInfoId(8)
    if not DoesBlipExist(blip) then return UI.Notify('Set a waypoint on the map first', 'error') end
    local c = GetBlipInfoIdCoord(blip)
    fadeTeleport(c.x, c.y, nil, nil, true)
end)

-- /back: return to where you stood before your last teleport
RegisterNetEvent('whip_core:client:tpBack', function()
    if not lastTeleportFrom then
        return UI.Notify('No previous teleport location', 'error')
    end
    local dest = lastTeleportFrom
    fadeTeleport(dest.x, dest.y, dest.z, dest.heading, true)
end)

-- /car: wait briefly for the spawned networked vehicle to stream in, then seat the admin in the driver seat
RegisterNetEvent('whip_core:client:seatInVehicle', function(netId)
    if type(netId) ~= 'number' then return end
    CreateThread(function()
        local veh, deadline = 0, GetGameTimer() + 3000
        while GetGameTimer() < deadline do
            if NetworkDoesNetworkIdExist(netId) then
                veh = NetworkGetEntityFromNetworkId(netId)
                if veh ~= 0 and DoesEntityExist(veh) then break end
            end
            Wait(50)
        end
        if veh == 0 or not DoesEntityExist(veh) then return end
        local ped = PlayerPedId()
        SetPedIntoVehicle(ped, veh, -1)
        SetVehicleEngineOn(veh, true, true, false)
    end)
end)

RegisterNetEvent('whip_core:client:playerLogout', function()
    lastTeleportFrom = nil
end)

-- NUI callbacks

RegisterNUICallback('selectCharacter', function(data, cb)
    local index = tonumber(data.index)
    if not index or index < 1 or index > #characterList then
        cb({ ok = false, error = 'Invalid character index' })
        return
    end
    -- Answer the browser first: BeginLoad blocks on the fade, and an unreturned NUI callback keeps the cursor up.
    cb({ ok = true })
    CreateThread(function()
        CharSelect.BeginLoad(index)
    end)
end)

--- Travel to a slot's hero shot (clicking a card both looks at and chooses a character). Answered before the
--- journey starts, as selectCharacter is, since SelectSlot does streaming work behind a curtain.
RegisterNUICallback('selectSlot', function(data, cb)
    -- A place per character a player may have (Config.MaxCharacters); SelectSlot refuses one past the last.
    local index = math.tointeger(tonumber(data and data.index))
    if not index or index < 1 then
        cb({ ok = false, error = 'Invalid slot index' })
        return
    end
    cb({ ok = true })
    CharSelect.SelectSlot(index)
end)

RegisterNUICallback('createCharacter', function(data, cb)
    local firstName = data.firstName
    local lastName = data.lastName
    local dateOfBirth = data.dateOfBirth
    local gender = data.gender

    if not firstName or #firstName < 2 then
        cb({ ok = false, error = 'First name must be at least 2 characters' })
        return
    end
    if not lastName or #lastName < 2 then
        cb({ ok = false, error = 'Last name must be at least 2 characters' })
        return
    end
    if not dateOfBirth or not dateOfBirth:match('^%d%d%d%d%-%d%d%-%d%d$') then
        cb({ ok = false, error = 'Date of birth must be YYYY-MM-DD' })
        return
    end
    if gender ~= 'male' and gender ~= 'female' then
        cb({ ok = false, error = 'Invalid gender selection' })
        return
    end

    -- Answer the browser first, as selectCharacter does: BeginCreate blocks on the fade.
    cb({ ok = true })
    CreateThread(function()
        CharSelect.BeginCreate(firstName, lastName, dateOfBirth, gender)
    end)
end)

RegisterNUICallback('deleteCharacter', function(data, cb)
    local index = tonumber(data.index)
    if not index or index < 1 or index > #characterList then
        cb({ ok = false, error = 'Invalid character index' })
        return
    end
    -- By the character's id, not its position in the list.
    local charId = characterList[index] and characterList[index].charId
    if not charId then
        cb({ ok = false, error = 'Invalid character' })
        return
    end
    TriggerServerEvent('whip_core:server:deleteCharacter', charId)
    cb({ ok = true })
end)

-- /logout: return to character selection

RegisterCommand('logout', function()
    if not PlayerLoaded then return end
    TriggerServerEvent('whip_core:server:logout')
end, false)

-- Exports: config

exports('GetItemDef', function(key)
    return Config.Items[key]
end)

exports('GetItemDefs', function()
    return Config.Items
end)
