-- ============================================
-- Seats — who sits where, and moving between seats
-- ============================================
--
-- The seat map (client/seats.lua) moves a player between the seats of the vehicle they are in. The
-- move is the player's own game's to make (a ped is moved by the client that owns it), but TWO
-- PLAYERS CAN PICK THE SAME FREE SEAT AT ONCE, and each game still sees it free: the other's move is
-- a ping away. So a move is CLAIMED here first. The first claim on a seat holds it for CLAIM_MS; a
-- second is told someone is moving there.
--
-- THE SERVER CANNOT COUNT SEATS. GetVehicleMaxNumberOfPassengers is a client native, and the server
-- only knows who sits in a seat (OneSync keeps 32 per vehicle). A seat past what the vehicle has is
-- the client's own game's to refuse; here it is only checked to be one GTA can have (-1..15).
--
-- ANY VEHICLE, whip's or a street car: claims are keyed on the entity. A locked car does not stop a
-- move: a lock is about getting in, and these players are in. Moving at speed is allowed.
-- A downed player is refused by SecureCallback itself (no `whileDead`).

local CLAIM_MS = 3000   -- the slide across takes about 2 s, then the seat has to replicate

--- [entity] = { [seat] = { source = n, untilMs = n } }
local _claims = {}

--- Which seat of `entity` this ped sits in, as the server sees it; nil for none.
---@param entity number
---@param ped number
---@return number|nil
local function seatIn(entity, ped)
    for s = -1, 15 do
        if GetPedInVehicleSeat(entity, s) == ped then return s end
    end
    return nil
end

--- Let go of every claim `source` holds, and of any that have run out (so the table only ever holds
--- the few claims made in the last few seconds).
---@param source number|nil  nil only sweeps the expired ones
local function dropClaims(source)
    local now = GetGameTimer()
    for entity, seats in pairs(_claims) do
        for seat, c in pairs(seats) do
            if c.source == source or c.untilMs <= now then seats[seat] = nil end
        end
        if next(seats) == nil then _claims[entity] = nil end
    end
end

--- A player asking to move to another seat of the vehicle they are in. True means move now.
SecureCallback('whip_core:seats:claim', {
    rateLimit = 250,
    burst     = 4,
    params = {
        {'netId', 'id'},
        -- An address inside the car: refused when out of range, never clamped ('int' would turn
        -- 16 into 15 and claim a seat nobody asked for).
        {'seat',  'id', -1, 15},
    },
}, function(source, _, netId, seat)
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'That vehicle is gone'
    end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 or GetVehiclePedIsIn(ped, false) ~= entity then
        return false, 'You need to be in that vehicle'
    end
    if seatIn(entity, ped) == seat then return false, 'You are already in that seat' end
    if GetPedInVehicleSeat(entity, seat) ~= 0 then return false, 'That seat is occupied' end

    dropClaims(source)   -- one claim per player: a new pick replaces the last one
    local byEntity = _claims[entity]
    if byEntity and byEntity[seat] then return false, 'Someone is already moving into that seat' end

    _claims[entity] = byEntity or {}
    _claims[entity][seat] = { source = source, untilMs = GetGameTimer() + CLAIM_MS }
    return true
end)

AddEventHandler('playerDropped', function()
    dropClaims(source)
end)

--- Which seat is this player in? The SERVER's view of them, any vehicle, street cars included.
---
---     local at, why = exports.whip_core:GetPlayerSeat(source)
---     if at and at.driver then ... end
---
--- `vehicleId` is there only for a car whip looks after (nil for a street car); `netId` always is.
--- To hear about seat changes instead of asking, listen to whip_core:vehicle:entered (it fires again
--- with the new seat when someone moves seat without getting out) and whip_core:vehicle:exited.
---@param source number|string|nil
---@return table|false at  { seat, driver, vehicleId?, netId }
---@return string|nil why
exports('GetPlayerSeat', function(source)
    source = Sanitize.id(source)
    if not source then return false, 'Invalid source' end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false, 'Player not found' end
    local entity = GetVehiclePedIsIn(ped, false)
    if not entity or entity == 0 then return false, 'Not in a vehicle' end
    local seat = seatIn(entity, ped)
    if not seat then return false, 'Not in a seat yet' end
    return {
        seat      = seat,
        driver    = seat == -1,
        vehicleId = Vehicles.getEntityVehicleId(entity),
        netId     = NetworkGetNetworkIdFromEntity(entity),
    }
end)
