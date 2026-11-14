-- ============================================
-- Container Events (client → server)
-- ============================================
-- The open logic (Containers.openFor), the panel system (server/panels.lua) and every export
-- moved out with the subsystems that own them; this file is the client-facing event handlers.

--- Player presses E near a container prop
SecureEvent('whip_core:server:openContainer', {
    rateLimit = 500,
    -- Burst 3; see the note on openInventory in server/events_inventory.lua. A stash open that is
    -- silently eaten reads as the prompt not working. (closeContainer below is generous — burst 5 —
    -- but it does have a limit now, and it only closes a container you actually have open.)
    burst     = 3,
    params = { {'containerId', 'id'} },
}, function(source, player, containerId)
    local ok, reason = Containers.openFor(source, player, containerId)
    if not ok then
        -- The screen waiting to open is told on its own event; the reason is `return false, 'why'`
        -- shown to the player and recorded.
        TriggerClientEvent('whip_core:client:openContainerDenied', source)
        return false, reason or 'Could not open'
    end
    Log.write(player.charId, 'opened_container', { detail = '#' .. containerId })
end)

--- Player closes inventory while container is open
---
--- Only a container you have open (a close saves, releases and unloads, so it must not be a free way
--- to force those on other people's containers). Generous (a burst for UI churn), but a close.
SecureEvent('whip_core:server:closeContainer', {
    whileDead = true,   -- dying closes the stash, and its lock has to be released
    rateLimit = 250,
    burst     = 5,
    params = { {'containerId', 'id'} },
}, function(source, _, containerId)
    if not Stores.isViewer(source, 'container:' .. tostring(containerId)) then
        RecordEventRejection('whip_core:server:closeContainer', source, 'not a viewer of that container')
        return
    end

    -- Save + release + unload
    pcall(Containers.saveInventory, containerId)
    Containers.release(containerId, source)
    Containers.unloadInventory(containerId)

end)

--- Player closes the inventory while a store a resource OPENED WITH OpenStore is on screen — one of
--- that resource's own store kinds (a stash or a boot opened that way closes through the two events
--- above, like any other). Only a store they are a viewer of: leaving a set you are in needs nothing
--- else, and a close for anything else changes nothing.
SecureEvent('whip_core:server:closeStore', {
    whileDead = true,   -- dying closes the screen, and the view has to go with it
    rateLimit = 250,
    burst     = 5,
    params = { {'storeId', 'string', 120} },
}, function(source, _, storeId)
    -- A resource's own kind only: whip's stashes, boots and panels close through their own events,
    -- which also save, release and unload; this only drops the view.
    local kindName = storeId:match('^([^:]+):')
    if not (kindName and StoreKindOwners and StoreKindOwners[kindName]) then
        RecordEventRejection('whip_core:server:closeStore', source, 'not a resource-defined store')
        return
    end
    if not Stores.isViewer(source, storeId) then
        RecordEventRejection('whip_core:server:closeStore', source, 'not a viewer of that store')
        return
    end
    Stores.removeViewer(source, storeId)
end)

--- Container Manager — permission-gated open
SecureEvent('whip_core:server:cmGetAll', {
    ace = 'whip.devtools',
}, function(source)
    TriggerClientEvent('whip_core:client:cmAllData', source, Containers.getAll())
end)

--- Admin override: open any container from Container Manager (bypasses distance/access/lock checks)
SecureEvent('whip_core:server:cmOpenContainer', {
    ace = 'whip.devtools',
    params = { {'containerId', 'id'} },
}, function(source, player, containerId)
    if not player.inventory then
        TriggerClientEvent('whip_core:client:openContainerDenied', source)
        return false, 'Not loaded'
    end

    local def = Containers.getDef(containerId)
    if not def then
        TriggerClientEvent('whip_core:client:openContainerDenied', source)
        return false, 'Container not found'
    end

    -- Admin override. No longer needs to kick anyone: joining a viewer set does not displace
    -- the people already in it. Recorded as 'admin', so the lock and requirements every move is
    -- held to (Stores.fromWire) do not refuse the admin's drags.
    Stores.addViewer(source, 'container:' .. tostring(containerId), nil, nil, nil, 'admin')

    -- Load inventory on-demand. A failed read does not open (it would show an empty stash), as in
    -- Containers.openFor.
    if not Containers.invCache[containerId] then
        if not Containers.loadInventory(containerId) then
            Containers.release(containerId, source)
            TriggerClientEvent('whip_core:client:openContainerDenied', source)
            return false, 'Could not read this container'
        end
    end

    local payload = Inventory.buildPayload(player)
    payload.containerId     = containerId
    payload.containerDef    = Containers.serializeDef(containerId)
    payload.containerInv    = Containers.serializeInventory(containerId)
    payload.containerWeight = Containers.getWeight(containerId)
    -- The id the delta protocol is keyed on. Without it the client receives updates caused by
    -- other viewers and has no way to tell which of its open grids they belong to.
    payload.storeId         = 'container:' .. tostring(containerId)
    TriggerClientEvent('whip_core:client:openContainer', source, payload)

end)

-- ============================================
-- Container CRUD Events (manager tool)
-- ============================================

SecureEvent('whip_core:server:createContainer', {
    ace = 'whip.devtools',
    params = { {'data', 'any'} },
}, function(source, player, data)
    if type(data) ~= 'table' then return end

    data.createdBy = player.charId

    data.name   = Sanitize.string(data.name, 100, 'Container')
    data.type   = Sanitize.key(data.type, 60) or 'stash'
    data.x      = Sanitize.number(data.x, -10000, 10000)
    data.y      = Sanitize.number(data.y, -10000, 10000)
    data.z      = Sanitize.number(data.z, -500, 2000)
    data.prop   = Sanitize.key(data.prop, 80) or Config.ContainerDefaultProp
    data.slots  = Sanitize.int(data.slots, 1, 1000, Config.ContainerDefaultSlots)
    data.maxWeight = Sanitize.number(data.maxWeight, 0, 10000, Config.ContainerDefaultWeight)
    data.ownerCharId  = tonumber(data.ownerCharId) or nil
    data.accessCharId = tonumber(data.accessCharId) or nil
    if data.ownerCharId  == 0 then data.ownerCharId  = nil end
    if data.accessCharId == 0 then data.accessCharId = nil end
    -- next(), not #: a keyed whitelist has a length of 0.
    if type(data.allowedItems) == 'table' and next(data.allowedItems) == nil then data.allowedItems = nil end

    local def = Containers.create(data)
    if not def then return false, 'Failed to create container' end   -- shown and recorded
    TriggerClientEvent('whip_core:client:cmContainerCreated', source, def)
    ShowSuccess(source,
        ('Container #%d "%s" created'):format(def.containerId, def.name))
end)

SecureEvent('whip_core:server:updateContainer', {
    ace = 'whip.devtools',
    params = {
        {'containerId', 'id'},
        {'data', 'any'},
    },
}, function(source, _, containerId, data)
    if type(data) ~= 'table' then return end

    if data.name      ~= nil then data.name      = Sanitize.string(data.name, 100, 'Container') end
    if data.type      ~= nil then data.type      = Sanitize.key(data.type, 60) end
    if data.x         ~= nil then data.x         = Sanitize.number(data.x, -10000, 10000) end
    if data.y         ~= nil then data.y         = Sanitize.number(data.y, -10000, 10000) end
    if data.z         ~= nil then data.z         = Sanitize.number(data.z, -500, 2000) end
    if data.prop      ~= nil then data.prop      = Sanitize.key(data.prop, 80) end
    if data.slots     ~= nil then data.slots     = Sanitize.int(data.slots, 1, 1000) end
    if data.maxWeight ~= nil then data.maxWeight = Sanitize.number(data.maxWeight, 0, 10000) end

    -- Its reason ("slot 12 still holds something", "being changed — try again"), not a generic one
    local ok, why = Containers.update(containerId, data)
    if not ok then return false, why or 'Failed to update container' end
    ShowSuccess(source,
        ('Container #%d updated'):format(containerId))
end)

SecureEvent('whip_core:server:deleteContainer', {
    ace = 'whip.devtools',
    params = { {'containerId', 'id'} },
}, function(source, player, containerId)

    -- The admin is the one the contents' lost rows are written against.
    local ok, err = Containers.delete(containerId, player and player.charId)
    if not ok then return false, err or 'Failed to delete container' end
    ShowSuccess(source,
        ('Container #%d deleted'):format(containerId))
end)

-- (Container exports live in server/containers.lua; the address exports — StoreGive, StoreTake,
-- GetItemAt, OpenStore, GetOpenStores — live in server/stores.lua; the panel system lives in
-- server/panels.lua.)

