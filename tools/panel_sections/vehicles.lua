-- ============================================
-- /whip SECTION — Vehicles (client wiring)
-- ============================================
--
-- Replaces tools/vehicle_manager.lua. The section lifecycle speaks the SAME server
-- events the standalone tool did (vmOpen on enter, vmClosed on leave — the server's
-- viewer set never noticed the consolidation), the server's pushes forward through
-- WhipPanelData, and the mutation callbacks move here verbatim. The old vmClose
-- callback and ToolHandlers['Vehicles'] are gone — the shell's close funnel is the
-- only way out now. (The dead 'Vehicles' row in tools/core.lua's /w list is harmless,
-- same as 'Containers' — ToggleTool nil-guards a missing handler.)
--
-- ANSWER THE FETCH, ALWAYS. `cb('ok')` is not a formality. The panel posts through a
-- promise, and a callback that returns without answering leaves that promise pending
-- forever — the button stays dead. Worth keeping at the top of every replacement.

PanelSections['vehicles'] = {
    enter = function()
        TriggerServerEvent('whip_core:server:vmOpen')
    end,
    leave = function()
        TriggerServerEvent('whip_core:server:vmClosed')
    end,
}

-- ============================================
-- Server -> section
-- ============================================
--
-- No vmOpen gate here like the old file kept — the server only pushes to registered
-- viewers, and leave deregisters, so a push after close cannot happen; one that races
-- the close lands in a hidden section's DOM and hurts nothing.

RegisterNetEvent('whip_core:client:vmOpen', function(data)
    WhipPanelData('vehicles', 'all', data)
end)

--- The fleet list changed — somebody stored a car, deleted one, or made one.
RegisterNetEvent('whip_core:client:vmRows', function(rows)
    WhipPanelData('vehicles', 'rows', rows)
end)

--- One vehicle, in full. `nil` means it is gone, and the section clears its detail pane.
RegisterNetEvent('whip_core:client:vmDetail', function(vehicle)
    WhipPanelData('vehicles', 'detail', vehicle)
end)

--- Go to the car.
---
--- The SERVER decides where it is and sends coordinates, because a car that is not
--- streamed to this client has no entity here to read a position from — which is most
--- of the fleet, most of the time, and the reason this is not done locally.
RegisterNetEvent('whip_core:client:vmTeleportTo', function(coords, heading)
    if not coords then return end

    local ped = PlayerPedId()
    -- Put the admin BESIDE it rather than inside it. Landing on the exact coordinates
    -- of a car means landing in the car's own collision.
    SetEntityCoords(ped, coords.x + 2.5, coords.y, coords.z, false, false, false, true)
    if heading then SetEntityHeading(ped, heading) end
end)

---- whip_core:client:vmRepair: DELETED. Repair is the object viewer's (server/object_viewer.lua fixCar). ----

-- ============================================
-- Section -> server (moved verbatim from tools/vehicle_manager.lua)
-- ============================================

RegisterNUICallback('vmSelect', function(data, cb)
    if data and data.vehicleId then
        TriggerServerEvent('whip_core:server:vmSelect', data.vehicleId)
    end
    cb('ok')
end)

RegisterNUICallback('vmAction', function(data, cb)
    if data and data.vehicleId and data.action then
        TriggerServerEvent('whip_core:server:vmAction', data.vehicleId, data.action)
    end
    cb('ok')
end)

--- An action with something picked for it: a garage, or a character (server/vehicle_manager.lua vmActOn).
RegisterNUICallback('vmActOn', function(data, cb)
    if data and data.vehicleId and data.action then
        TriggerServerEvent('whip_core:server:vmActOn', data.vehicleId, data.action, data.arg)
    end
    cb('ok')
end)

RegisterNUICallback('vmTeleportTo', function(data, cb)
    if data and data.vehicleId then
        TriggerServerEvent('whip_core:server:vmTeleportTo', data.vehicleId)
    end
    cb('ok')
end)

RegisterNUICallback('vmSave', function(data, cb)
    if data and data.vehicleId and type(data.fields) == 'table' then
        TriggerServerEvent('whip_core:server:vmSave', data.vehicleId, data.fields)
    end
    cb('ok')
end)

RegisterNUICallback('vmSetStat', function(data, cb)
    if data and data.vehicleId and data.stat then
        TriggerServerEvent('whip_core:server:vmSetStat', data.vehicleId, data.stat, tonumber(data.value) or 0)
    end
    cb('ok')
end)

-- Open a compartment's inventory from the panel (admin override). Inventory handoff
-- v1: the shell CLOSES rather than suspends — resuming on inventory close needs a
-- clean inventory-closed hook that hasn't been verified; today's UX is preserved
-- exactly. Same call as containers' cmOpenContainer.
RegisterNUICallback('vmOpenStorage', function(data, cb)
    if data and data.vehicleId and data.storageType then
        WhipPanelClose()
        TriggerServerEvent('whip_core:server:vmOpenStorage', data.vehicleId, data.storageType)
    end
    cb('ok')
end)

RegisterNUICallback('vmCreate', function(data, cb)
    TriggerServerEvent('whip_core:server:vmCreate', data or {})
    cb('ok')
end)

-- ---- the new-vehicle wizard (html/js/wp/vehicles.js; server/vehicle_manager.lua) ----

--- Every model the wizard can pick from, and the storage each gets by default.
RegisterNUICallback('vmCatalog', function(_, cb)
    CreateThread(function()
        local res = Callback('whip_core:vmCatalog')
        cb(type(res) == 'table' and res or { vehicles = {} })
    end)
end)

--- The wizard's Owner step: everyone in the game, you first.
RegisterNUICallback('vmOnlinePlayers', function(_, cb)
    CreateThread(function()
        local res = Callback('whip_core:vmOnlinePlayers')
        cb(type(res) == 'table' and res or {})
    end)
end)

--- Where you stand, for the wizard's map while the car is to be spawned here (your own game's reading: the server
--- puts it there itself when it is made).
RegisterNUICallback('vwHere', function(_, cb)
    local c = GetEntityCoords(PlayerPedId())
    cb({ x = c.x, y = c.y })
end)

--- The wizard's Create: the car, its owner and where it goes, at once.
RegisterNUICallback('vmWizardCreate', function(data, cb)
    CreateThread(function()
        local res = Callback('whip_core:vmWizardCreate', data)
        cb(type(res) == 'table' and res or { ok = false, why = 'No answer from the server' })
    end)
end)
