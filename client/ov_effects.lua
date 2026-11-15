-- ============================================
-- The Object Viewer's options, on the game that does them
-- ============================================
--
-- An admin's option (server/object_viewer.lua) that only a particular game can carry out arrives here, on every
-- player's game:
--
--   ovEffect   an entity this game owns: explode, kill, fire, repair (the server picks the owner); and the /whip
--              Vehicles page's tyres, fling and engine (server/vehicle_manager.lua). On GTA V Enhanced a car's
--              repair, tyres and engine are the server's own (server/object_viewer.lua CAR_ON_SERVER)
--   ovSelf     this player: fire, the character editor, a model, a walk, an emote; into a car's free seat
--              (warpInto, the Vehicles page's Teleport players into vehicle)
--   ovHold     this player's holds: frozen, no combat (attacks blocked)
--   the bag    ENTITY_OV_HOLD_KEY on an entity (hidden, invincible, frozen): kept by whichever game owns it now

local HIDDEN, INVINCIBLE, FROZEN = 1, 2, 4

-- Every wheel a car can have, by GTA's tyre numbers: the six, and a six-wheeler's middle pair.
local TYRES = { 0, 1, 2, 3, 4, 5, 45, 47 }

-- How long a fire an admin starts burns. GTA puts out a player's by itself, but an NPC (dead or alive) burned on for
-- good: so every one is put out after this, by whichever game owns the ped by then.
local FIRE_MS = 8000

--- Control of an entity this game was told to change. A car through Vehicles.takeControl (it refuses a car another
--- player drives: that player's game was the one told); anything else asked for briefly.
local control = Vehicles.takeEntityControl

--- Set it alight, and put it out FIRE_MS later if it is still burning.
local function burn(ent)
    StartEntityFire(ent)
    SetTimeout(FIRE_MS, function()
        if not DoesEntityExist(ent) or not IsEntityOnFire(ent) then return end
        CreateThread(function()
            if control(ent) then StopEntityFire(ent) end
        end)
    end)
end

RegisterNetEvent('whip_core:client:ovEffect', function(netId, what)
    if type(netId) ~= 'number' or not NetworkDoesNetworkIdExist(netId) then return end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if ent == 0 or not DoesEntityExist(ent) then return end
    CreateThread(function()
        if not control(ent) then return end
        if what == 'explode' and GetEntityType(ent) == 2 then
            NetworkExplodeVehicle(ent, true, false, false)
        elseif what == 'kill' then
            SetEntityHealth(ent, 0)
        elseif what == 'fire' then
            burn(ent)
        elseif what == 'repair' and GetEntityType(ent) == 2 then
            SetVehicleFixed(ent)
            SetVehicleDeformationFixed(ent)
            SetVehicleEngineHealth(ent, 1000.0)
            SetVehicleBodyHealth(ent, 1000.0)
            SetVehiclePetrolTankHealth(ent, 1000.0)
            SetVehicleDirtLevel(ent, 0.0)
            for _, wheel in ipairs(TYRES) do SetVehicleTyreFixed(ent, wheel) end
        elseif what == 'tyres' and GetEntityType(ent) == 2 then
            -- Bulletproof tyres too.
            SetVehicleTyresCanBurst(ent, true)
            for _, wheel in ipairs(TYRES) do SetVehicleTyreBurst(ent, wheel, true, 1000.0) end
        elseif what == 'fling' and GetEntityType(ent) == 2 then
            SetEntityVelocity(ent, 0.0, 0.0, 30.0)
        elseif what == 'engine' and GetEntityType(ent) == 2 then
            -- Below 0 the engine is dead and burning; -4000 is as far as GTA goes.
            SetVehicleEngineHealth(ent, -4000.0)
        end
    end)
end)

--- Into a car's first free seat (the Vehicles page's Teleport players into vehicle). Beside it first: a car far away
--- has no entity in this game until it streams in, so it is waited for (5 s).
---@param arg table  { netId, x, y, z }
local function warpInto(arg)
    local ped = PlayerPedId()
    if arg.x and arg.y and arg.z then SetEntityCoords(ped, arg.x + 2.5, arg.y, arg.z, false, false, false, true) end
    local veh, deadline = 0, GetGameTimer() + 5000
    while GetGameTimer() < deadline do
        if NetworkDoesNetworkIdExist(arg.netId) then
            veh = NetworkGetEntityFromNetworkId(arg.netId)
            if veh ~= 0 and DoesEntityExist(veh) then break end
        end
        Wait(100)
    end
    if veh == 0 or not DoesEntityExist(veh) then return end
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if IsVehicleSeatFree(veh, seat) then
            SetPedIntoVehicle(ped, veh, seat)
            UI.Notify('An admin put you in a vehicle', 'info')
            return
        end
    end
    UI.Notify('An admin tried to put you in a vehicle, but every seat is taken', 'info')
end

RegisterNetEvent('whip_core:client:ovSelf', function(what, arg)
    if not PlayerLoaded then return end
    if what == 'fire' then
        burn(PlayerPedId())
    elseif what == 'model' then
        CreateThread(function() WearModel(type(arg) == 'string' and arg or nil) end)
    elseif what == 'walk' and Emotes then
        Emotes.setWalk(type(arg) == 'string' and arg or nil)
    elseif what == 'emote' and Emotes then
        if type(arg) == 'string' then Emotes.play(arg) else Emotes.stop() end
    elseif what == 'warpInto' and type(arg) == 'table' and type(arg.netId) == 'number' then
        CreateThread(function() warpInto(arg) end)
    end
end)

local held = { frozen = false, noCombat = false }

RegisterNetEvent('whip_core:client:ovHold', function(flags)
    flags = type(flags) == 'table' and flags or {}
    local frozen, noCombat = flags.frozen == true, flags.noCombat == true
    if frozen ~= held.frozen then
        if frozen then PedHold.set('ovAdmin', { frozen = true }) else PedHold.release('ovAdmin') end
        UI.Notify(frozen and 'An admin has frozen you in place' or 'You can move again', 'info')
    end
    if noCombat ~= held.noCombat then
        -- Aiming, shooting, melee and drive-bys: nothing that hurts anyone.
        if noCombat then ControlBlocks.hold('ovNoCombat', { groups = { 'combat', 'vehicleCombat' } })
        else ControlBlocks.release('ovNoCombat') end
        UI.Notify(noCombat and 'An admin has turned your attacks off' or 'Your attacks are back', 'info')
    end
    held.frozen, held.noCombat = frozen, noCombat
end)

-- A character swap is someone else: the server forgets the last one's holds (server/object_viewer.lua), so this
-- game lets go of them too, or the next character would arrive frozen with the server saying none is on.
AddEventHandler('whip_core:player:logout', function()
    if held.frozen then PedHold.release('ovAdmin') end
    if held.noCombat then ControlBlocks.release('ovNoCombat') end
    held.frozen, held.noCombat = false, false
end)

-- ============================================
-- Held entities (hidden, invincible, frozen)
-- ============================================
--
-- Every bag seen, by its name; twice a second, each one this game owns is put to its mask. Owning moves between
-- games, so this asks every pass rather than once (three natives on a handful of entities). Born with the first
-- bag, gone with the last.
--
-- A NAME IS A NETWORK ID, AND IDS ARE GIVEN AGAIN. An entity deleted with its hold on says nothing here, and the
-- next entity with its id (anyone's car, a ped) would be hidden or frozen for good. So a bag whose entity is gone
-- from this game is forgotten (one streaming back in brings its bag again), and a hold is put only on the model it
-- was seen on.

local bags = {}       -- [bagName] = { mask, model }
local undo = {}       -- [bagName] = { bits, untilAt }: what to put back now it is off, by whoever owns it in time
local UNDO_MS = 10000 -- (the game that owns it then does it; one that never does stops asking)
local BAG_WAIT_MS = 10000   -- a hold whose entity this game has not got yet is kept this long for it to arrive
local loopOn = false

--- Only the bits that are on: one that is off is put back once (`release`), never pressed every pass, or a hold here
--- would fight whatever else hides or freezes the same entity.
local function apply(ent, mask)
    if mask & HIDDEN ~= 0 then SetEntityVisible(ent, false, false) end
    if mask & INVINCIBLE ~= 0 then SetEntityInvincible(ent, true) end
    if mask & FROZEN ~= 0 then FreezeEntityPosition(ent, true) end
end

local function release(ent, was)
    if was & HIDDEN ~= 0 then SetEntityVisible(ent, true, false) end
    if was & INVINCIBLE ~= 0 then SetEntityInvincible(ent, false) end
    if was & FROZEN ~= 0 then FreezeEntityPosition(ent, false) end
end

local function undoLater(name, bits)
    local u = undo[name]
    undo[name] = { bits = (u and u.bits or 0) | bits, untilAt = GetGameTimer() + UNDO_MS }
end

local function loop()
    while next(bags) or next(undo) do
        local now = GetGameTimer()
        for name, u in pairs(undo) do
            local ent = GetEntityFromStateBagName(name)
            if ent == 0 or not DoesEntityExist(ent) or now > u.untilAt then
                undo[name] = nil
            elseif NetworkHasControlOfEntity(ent) then
                release(ent, u.bits & ~(bags[name] and bags[name].mask or 0))
                undo[name] = nil
            end
        end
        for name, b in pairs(bags) do
            local ent = GetEntityFromStateBagName(name)
            if ent == 0 or not DoesEntityExist(ent) then
                -- A bag can land before its entity (house rule 11): one not seen yet is waited for a while; one seen and
                -- then gone (out of scope) is forgotten, and brings its bag again when it streams back in.
                if b.seen or now - (b.bornAt or now) > BAG_WAIT_MS then bags[name] = nil end
            else
                b.seen = true
                local model = GetEntityModel(ent)
                b.model = b.model or model
                if model ~= b.model then
                    bags[name] = nil   -- another entity under that id now: not the one held
                elseif NetworkHasControlOfEntity(ent) then
                    apply(ent, b.mask)
                end
            end
        end
        Wait(500)
    end
    loopOn = false
end

AddStateBagChangeHandler(ENTITY_OV_HOLD_KEY, nil, function(bagName, _, value)
    local had = bags[bagName]
    local was = had and had.mask
    if type(value) == 'number' and value > 0 then
        local ent = GetEntityFromStateBagName(bagName)
        local model = ent ~= 0 and DoesEntityExist(ent) and GetEntityModel(ent) or (had and had.model) or nil
        bags[bagName] = { mask = math.tointeger(value), model = model, seen = had and had.seen or nil,
                          bornAt = had and had.bornAt or GetGameTimer() }
        -- (A bit turned off is put back by its owner, as the whole mask going is.)
        if was then
            local gone = was & ~bags[bagName].mask
            if gone ~= 0 then undoLater(bagName, gone) end
        end
    else
        bags[bagName] = nil
        if was then undoLater(bagName, was) end
    end
    if not loopOn and (next(bags) or next(undo)) then
        loopOn = true
        CreateThread(loop)
    end
end)
