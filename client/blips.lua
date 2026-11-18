-- ============================================
-- BLIPS — the client half of server/blips.lua (ShowBlip, HideBlip, SetPlayerWaypoint)
-- ============================================
--
-- The server says which blips this player sees; this makes them, and nothing else. No frame loop:
-- a GTA blip is made when one arrives, remade when it changes, and removed when it goes. A character
-- coming on gets the whole list (whip_core:client:blips), and logging out clears it.

local blips = {}   -- [wireId] = { point = blip, area = blip }

--- [GTA blip handle] = its label. GTA lets nothing read a blip's name back, so the pause map
--- (client/pause.lua) asks here for whip's labels and those registered by other resources.
local labelOf = {}
local externalLabels = {}
local labelReg = Registry.new('blipLabel', { store = externalLabels })

exports('SetBlipLabel', function(handle, label)
    local owner = Registry.caller()
    if type(handle) ~= 'number' or handle % 1 ~= 0 or handle <= 0 then
        return false, 'blip handle must be a positive integer'
    end
    if label == nil then
        if externalLabels[handle] == nil then return true end
        return labelReg:remove(owner, handle)
    end
    if type(label) ~= 'string' or label == '' then return false, 'blip label must be a non-empty string' end
    if not DoesBlipExist(handle) then return false, 'blip does not exist' end
    if labelOf[handle] then return false, 'blip belongs to whip_core' end
    return labelReg:add(owner, handle, label)
end)

--- A registered blip label, or nil.
---@param handle number
---@return string|nil
function WhipBlipLabel(handle)
    return labelOf[handle] or externalLabels[handle]
end

--- [GTA blip handle] = the number on it (ShowBlip's `number`). GTA lets nothing read that back either, so whip's own
--- maps (client/pause.lua, client/minimap.lua) ask here.
local numberOf = {}

--- The number on a whip blip, or nil.
---@param handle number
---@return integer|nil
function WhipBlipNumber(handle)
    return numberOf[handle]
end

--- Name, for the pause map, a blip whip_core made outside this file (/w Reveal Players); nil forgets it.
--- GTA's own name for it is the caller's to set.
---@param handle number
---@param label string|nil
function WhipBlipSetLabel(handle, label)
    labelOf[handle] = label
end

local function kill(id)
    local b = blips[id]
    if not b then return end
    blips[id] = nil
    if b.point then labelOf[b.point] = nil; numberOf[b.point] = nil end
    if b.point and DoesBlipExist(b.point) then RemoveBlip(b.point) end
    if b.area and DoesBlipExist(b.area) then RemoveBlip(b.area) end
end

local function make(id, w)
    kill(id)
    if type(w) ~= 'table' or type(w.x) ~= 'number' then return end
    local b = {}
    if w.radius then
        -- An area: a translucent circle, in the blip's colour. Never routed to on its own.
        b.area = AddBlipForRadius(w.x, w.y, w.z, w.radius + 0.0)
        SetBlipColour(b.area, w.color or 5)
        SetBlipAlpha(b.area, 90)
        SetBlipAsShortRange(b.area, w.shortRange == true)
    end
    if (w.sprite or 1) > 0 then
        b.point = AddBlipForCoord(w.x, w.y, w.z)
        SetBlipSprite(b.point, w.sprite or 1)
        SetBlipColour(b.point, w.color or 5)
        SetBlipScale(b.point, w.scale or 0.9)
        SetBlipAsShortRange(b.point, w.shortRange == true)
        if w.flash then SetBlipFlashes(b.point, true) end
        if w.number then
            ShowNumberOnBlip(b.point, w.number)
            numberOf[b.point] = w.number
        end
        if w.label then
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(w.label)
            EndTextCommandSetBlipName(b.point)
            labelOf[b.point] = w.label
        end
        if w.route then
            SetBlipRoute(b.point, true)
            SetBlipRouteColour(b.point, w.color or 5)
        end
    end
    blips[id] = b
end

RegisterNetEvent('whip_core:client:blip', function(id, w)
    if type(id) ~= 'number' then return end
    if w then make(id, w) else kill(id) end
end)

RegisterNetEvent('whip_core:client:blips', function(list)
    local ids = {}
    for id in pairs(blips) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do kill(id) end
    for _, e in ipairs(type(list) == 'table' and list or {}) do
        if type(e) == 'table' and type(e.id) == 'number' then make(e.id, e.w) end
    end
end)

-- GTA's own waypoint (the one a player can set on the pause map), set for them.
RegisterNetEvent('whip_core:client:waypoint', function(x, y)
    x, y = tonumber(x), tonumber(y)
    if x and y then SetNewWaypoint(x + 0.0, y + 0.0) end
end)

-- ============================================
-- ONE WAYPOINT PER VEHICLE (server/blips.lua's vehicleWaypoint)
-- ============================================
--
-- A waypoint set or cleared in a vehicle with another player in it is set or cleared for them too, as in GTA
-- Online — the minimap and the pause map both draw GTA's waypoint, so both show it. GTA says nothing when a
-- waypoint changes (the pause map, a server's SetPlayerWaypoint, GTA clearing it on arrival), so it is watched:
-- twice a second, only from getting in to getting out. Only a change made in the car is shared; one already set
-- when you got in is yours. One that arrives from the car is not sent back (WP_ECHO_MS).

local WP_TICK_MS = 500
local WP_ECHO_MS = 1000
---@type { x: number, y: number }|false
local wpKnown = false        -- the waypoint as last seen, shared or received: { x, y }, or false for none
local wpQuietUntil = 0       -- a received one is settling in: not read as this player's own change
local wpWatching = false

local function readWaypoint()
    local wp = GetFirstBlipInfoId(8)
    if not DoesBlipExist(wp) then return false end
    local c = GetBlipInfoIdCoord(wp)
    return { x = c.x, y = c.y }
end

local function sameWaypoint(a, b)
    if not a or not b then return (not a) == (not b) end
    return math.abs(a.x - b.x) < 1.0 and math.abs(a.y - b.y) < 1.0
end

--- Another PLAYER in this vehicle? (Sharing with nobody sends nothing.)
local function anotherPlayerIn(veh, ped)
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        local p = GetPedInVehicleSeat(veh, seat)
        if p ~= 0 and p ~= ped and IsPedAPlayer(p) then return true end
    end
    return false
end

AddEventHandler('whip_core:vehicle:entered', function()
    if wpWatching then return end
    wpWatching = true
    wpKnown = readWaypoint()
    CreateThread(function()
        while true do
            Wait(WP_TICK_MS)
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh == 0 then break end
            if GetGameTimer() >= wpQuietUntil then
                local now = readWaypoint()
                if not sameWaypoint(now, wpKnown) then
                    wpKnown = now
                    if anotherPlayerIn(veh, ped) then
                        if now then
                            TriggerServerEvent('whip_core:server:vehicleWaypoint', now.x, now.y, true)
                        else
                            TriggerServerEvent('whip_core:server:vehicleWaypoint', 0.0, 0.0, false)
                        end
                    end
                end
            end
        end
        wpWatching = false
    end)
end)

-- Another player in this vehicle set or cleared theirs: ours follows, and is not shared back.
RegisterNetEvent('whip_core:client:vehicleWaypoint', function(x, y, set)
    wpQuietUntil = GetGameTimer() + WP_ECHO_MS
    if set then
        x, y = tonumber(x), tonumber(y)
        if not (x and y) then return end
        wpKnown = { x = x, y = y }
        SetNewWaypoint(x + 0.0, y + 0.0)
    else
        wpKnown = false
        SetWaypointOff()
    end
end)

AddEventHandler('whip_core:player:logout', function()
    local ids = {}
    for id in pairs(blips) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do kill(id) end
end)
