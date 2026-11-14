-- ============================================
-- Vehicle Manager — dev tool, server side
-- ============================================
--
-- Everything an admin might want to do to a car, on the public vehicle API and nothing else: never
-- assign onto the record or write SQL here. Every handler below goes through the same calls a
-- satellite would use; if something is awkward here, the API is awkward.

local VM_ACE = 'whip.devtools'

--- Everyone with the panel open.
DevTools.viewers.vm = DevTools.viewers.vm or {}

--- One row per vehicle for the list.
---
--- Deliberately thin. The list shows dozens of cars at once and only needs enough to search and
--- sort; the detail panel asks for the whole vehicle when one is selected.
---@param v table  a GetVehicle snapshot
---@return table
local function vmRow(v)
    return {
        vehicleId = v.vehicleId,
        plate     = v.plate,
        model     = v.model,
        display   = v.displayName,
        class     = v.class,
        state     = v.state,
        garage    = v.garage,
        spawned   = v.spawned,
        locked    = v.locked,
        session   = v.session,
        owner     = v.owner,
    }
end

--- Vehicles.context only names an owner who is ONLINE (PlayersByCharId); the panel's list shows
--- the owner's name either way, so offline names come from ResolveCharNames — cached there, because
--- the fleet list rebroadcasts on every mutation.
---@param rows table[]  vmRow() rows; owner.name is filled in place where missing
local function vmFillOwnerNames(rows)
    local missing, seen = {}, {}
    for _, r in ipairs(rows) do
        local cid = r.owner and tonumber(r.owner.charId)
        if cid and not r.owner.name and not seen[cid] then
            seen[cid] = true
            missing[#missing + 1] = cid
        end
    end
    if #missing == 0 then return end
    local names = ResolveCharNames(missing)
    for _, r in ipairs(rows) do
        local cid = r.owner and tonumber(r.owner.charId)
        if cid and not r.owner.name then r.owner.name = names[cid] end
    end
end

--- Every vehicle whip knows about, as list rows.
local function vmAllRows()
    local rows = {}
    for vehicleId in pairs(Vehicles.getAll()) do
        local v = Vehicles.context(vehicleId)
        if v then rows[#rows + 1] = vmRow(v) end
    end
    table.sort(rows, function(a, b) return (a.vehicleId or 0) < (b.vehicleId or 0) end)
    vmFillOwnerNames(rows)
    return rows
end

--- Push the list to everyone watching.
---
--- Called after anything that changes what the list shows, so two admins with the panel open never
--- disagree about the fleet. Only this file changes it, so the function is this file's own.
local function vmBroadcast()
    if not next(DevTools.viewers.vm) then return end
    local rows = vmAllRows()
    DevTools.eachViewer(DevTools.viewers.vm, function(src)   -- still allowed
        TriggerClientEvent('whip_core:client:vmRows', src, rows)
    end, VM_ACE)
end

--- Send one vehicle's full detail to one admin.
local function vmSendDetail(source, vehicleId)
    local v = Vehicles.context(vehicleId, { occupants = true })
    if not v then
        TriggerClientEvent('whip_core:client:vmDetail', source, nil)
        return
    end

    -- Storage is only reported by context when the inventory is already in memory, and the panel
    -- is exactly the case where an admin wants the numbers whether or not somebody has opened the
    -- boot today. Asking for it here is a deliberate side effect of opening a specific vehicle,
    -- not of listing the fleet.
    if not v.storage then
        Vehicles.loadInventory(vehicleId)
        v = Vehicles.context(vehicleId, { occupants = true })
        if not v then   -- deleted while the load waited
            TriggerClientEvent('whip_core:client:vmDetail', source, nil)
            return
        end
    end

    -- Same offline-owner naming the list rows get.
    vmFillOwnerNames({ v })

    -- What its actions say about it: whether a key is in its ignition (Remove key), and whether it is held frozen
    -- (Freeze, the object viewer's hold).
    v.ignitionKey = Vehicles.getIgnitionSlot(vehicleId) ~= nil
    v.frozen = v.entity ~= nil and ObjectViewer ~= nil and ObjectViewer.isFrozen(v.entity) or nil

    -- The car's own storage overrides, which context does not carry (Save sends a blank box as
    -- "clear"). Numbers only: no override is no field, and the box stays blank.
    local def = Vehicles.getDef(vehicleId)
    if def then
        for _, key in ipairs({ 'trunkSlots', 'trunkMaxWeight', 'gloveboxSlots', 'gloveboxMaxWeight' }) do
            if type(def[key]) == 'number' then v[key] = def[key] end
        end
    end

    TriggerClientEvent('whip_core:client:vmDetail', source, v)
end

-- ============================================
-- Opening and closing
-- ============================================

SecureEvent('whip_core:server:vmOpen', {
    ace = VM_ACE,
}, function(source)
    DevTools.viewers.vm[source] = true

    -- snapshotAll, not getAll: this crosses to a NUI, and the record does not leave the server.
    -- The full snapshot rather than Garages.wire() because the admin panel names a vehicle's
    -- garage and the player projection is deliberately smaller than that.
    TriggerClientEvent('whip_core:client:vmOpen', source, {
        rows     = vmAllRows(),
        garages  = Garages.snapshotAll(),
        statDefs = VehicleStats and VehicleStats.getStatDefs() or {},
    })
end)

SecureEvent('whip_core:server:vmClosed', {   -- no ACE: leaving is never refused (devtools.lua plmClosed)
    requirePlayer = false, whileDead = true,
}, function(source)
    DevTools.viewers.vm[source] = nil
end)

SecureEvent('whip_core:server:vmSelect', {
    ace = VM_ACE,
    rateLimit = 100,
    params = { { 'vehicleId', 'id' } },
}, function(source, _, vehicleId)
    vmSendDetail(source, vehicleId)
end)

-- ============================================
-- Actions
-- ============================================
--
-- One handler, one verb, and every one of them reports what happened in the framework's own words.

--- Say how it went, and refresh what the admin is looking at. RETURN WHAT THIS RETURNS: a failure
--- is answered (`false, 'why'`), which shows the admin the reason and records it in the Event Monitor.
local function vmResult(source, vehicleId, ok, err, okMsg)
    if ok then
        ShowSuccess(source, okMsg)
    end

    if vehicleId then vmSendDetail(source, vehicleId) end
    vmBroadcast()
    if ok then return true end
    return false, tostring(err or 'Failed')
end

--- Out beside a player (the admin's Bring to me, or Bring to player): from its garage if it is in one, moved if it is
--- out already (Vehicles.spawn takes away whatever it had first).
---@param forSource number  the player it comes out beside
---@return boolean ok
---@return string|nil why
local function bringOutBeside(vehicleId, forSource)
    local ped = GetPlayerPed(forSource)
    local at = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    if not at then return false, 'They have no position' end
    -- At their feet, so not while they are in Isolate world: it would come out unseen.
    local away = Vehicles.cannotBringOutFor(forSource)
    if away then return false, away end
    -- From its own garage, as the 'retrieve' action asks (every car has one: loadAll files a car with none under
    -- the default). Already out is fine; anything else is not.
    local v = Vehicles.context(vehicleId)
    local retrieved, rErr = Vehicles.retrieve(vehicleId, v and v.garage or nil)
    if not retrieved then
        v = Vehicles.context(vehicleId)
        if not v or v.state ~= 'out' then return false, rErr end
    end
    local entity, netIdOrErr = Vehicles.spawn(vehicleId, at.x + 3.0, at.y, at.z, GetEntityHeading(ped) or 0.0)
    if not entity then return false, netIdOrErr --[[@as string]] end
    return true
end

--- The car in the world, for an action that needs it: its entity, or nil and why not.
local function inWorld(vehicleId)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then
        local def = Vehicles.getDef(vehicleId)
        return nil, def and def.state == 'out' and 'It is out but not in the world: bring it to you first'
            or 'It is in its garage: bring it out first'
    end
    return entity
end

-- The object viewer's one-offs (ObjectViewer.carEffect: the server on Enhanced where it can, otherwise the game that
-- owns the car): what each says.
local OWNER_EFFECTS = {
    explode = 'Vehicle #%d exploded',
    tyres   = 'Vehicle #%d: every tyre burst',
    fling   = 'Vehicle #%d flung into the air',
    engine  = 'Vehicle #%d: engine destroyed',
}

SecureEvent('whip_core:server:vmAction', {
    ace = VM_ACE,
    rateLimit = 250,
    params = {
        { 'vehicleId', 'id' },
        { 'action', 'enum', {
            'spawn', 'despawn', 'bringToMe', 'store', 'retrieve',
            'lock', 'unlock', 'giveKey', 'repair', 'delete',
            'ejectAll', 'freeze', 'removeKey', 'doorsOpen', 'doorsClose',
            'explode', 'tyres', 'fling', 'engine',
        } },
    },
}, function(source, player, vehicleId, action)
    -- Bring to me is spawn, at my feet: a car already out is moved rather than duplicated.
    if action == 'bringToMe' or action == 'spawn' then
        local ok, err = bringOutBeside(vehicleId, source)
        return vmResult(source, vehicleId, ok, err, ('Vehicle #%d brought to you'):format(vehicleId))

    elseif OWNER_EFFECTS[action] then
        local entity, why = inWorld(vehicleId)
        if not entity then return vmResult(source, vehicleId, false, why) end
        local ok, err = ObjectViewer.carEffect(source, entity, action)
        return vmResult(source, vehicleId, ok, err, OWNER_EFFECTS[action]:format(vehicleId))

    elseif action == 'ejectAll' then
        local entity, why = inWorld(vehicleId)
        if not entity then return vmResult(source, vehicleId, false, why) end
        local n = ObjectViewer.ejectAll(entity)
        if n == 0 then return vmResult(source, vehicleId, false, 'Nobody is in it') end
        return vmResult(source, vehicleId, true, nil, n == 1 and 'One out of it' or (n .. ' out of it'))

    elseif action == 'freeze' then
        local entity, why = inWorld(vehicleId)
        if not entity then return vmResult(source, vehicleId, false, why) end
        local on = ObjectViewer.toggleFrozen(entity)
        return vmResult(source, vehicleId, true, nil,
            ('Vehicle #%d %s'):format(vehicleId, on and 'frozen where it is' or 'can move again'))

    elseif action == 'doorsOpen' or action == 'doorsClose' then
        -- The doors are the server's (Vehicles.setDoorMask, the bag every game follows): every one at once, the
        -- bonnet and the boot too. A door the model does not have is left alone by each game.
        local entity, why = inWorld(vehicleId)
        if not entity then return vmResult(source, vehicleId, false, why) end
        Vehicles.setDoorMask(entity, action == 'doorsOpen' and 0xFF or 0)
        return vmResult(source, vehicleId, true, nil,
            ('Vehicle #%d: every door %s'):format(vehicleId, action == 'doorsOpen' and 'open' or 'shut'))

    elseif action == 'removeKey' then
        -- Into the admin's pockets, as a driver takes it out: the engine hears it (the ignition's hooks).
        if not Vehicles.getIgnitionSlot(vehicleId) then return vmResult(source, vehicleId, false, 'There is no key in it') end
        local ok, err = Stores.moveByAddress(
            { kind = 'vehicle', id = vehicleId, sub = 'key', slot = 1 },
            { kind = 'player', id = source, sub = 'player' },
            { reason = 'out of the ignition by an admin (the Vehicles page)', source = source })
        return vmResult(source, vehicleId, ok == true, err or 'There is no room for it in your pockets',
            ('The key from vehicle #%d is in your pockets'):format(vehicleId))

    elseif action == 'despawn' then
        -- Into its garage, not just out of the world. Only an owned car that was out goes to a garage;
        -- a street or temporary car is just gone.
        local def = Vehicles.getDef(vehicleId)
        local filed = def and not def.session and def.state == 'out'   -- as despawnToGarage decides (a temp car is a session one)
        local removed, err = Vehicles.despawnToGarage(vehicleId)
        return vmResult(source, vehicleId, removed, err or 'It was not in the world',
            (filed and 'Vehicle #%d despawned (in its garage now)' or 'Vehicle #%d despawned'):format(vehicleId))

    elseif action == 'store' then
        local v = Vehicles.context(vehicleId)
        local ok, err = Vehicles.store(vehicleId, v and v.garage or nil)
        return vmResult(source, vehicleId, ok, err, ('Vehicle #%d stored'):format(vehicleId))

    elseif action == 'retrieve' then
        local v = Vehicles.context(vehicleId)
        local ok, err = Vehicles.retrieve(vehicleId, v and v.garage or nil)
        return vmResult(source, vehicleId, ok, err,
            ('Vehicle #%d marked out — spawn it to place it'):format(vehicleId))

    elseif action == 'lock' or action == 'unlock' then
        local ok, err = Vehicles.setLocked(vehicleId, action == 'lock', source)
        return vmResult(source, vehicleId, ok, err,
            ('Vehicle #%d %s'):format(vehicleId, action == 'lock' and 'locked' or 'unlocked'))

    elseif action == 'giveKey' then
        local ok, err = Vehicles.giveKey(source, player, vehicleId)
        return vmResult(source, vehicleId, ok, err, 'Key given')

    elseif action == 'repair' then
        -- The object viewer's Repair: the car, then its record (the dirt and the kept damage), or the next spawn
        -- puts them back.
        local entity, why = inWorld(vehicleId)
        if not entity then return vmResult(source, vehicleId, false, why) end
        local ok, err = ObjectViewer.fixCar(source, entity)
        return vmResult(source, vehicleId, ok, err, ('Vehicle #%d repaired'):format(vehicleId))

    elseif action == 'delete' then
        local ok, err = Vehicles.delete(vehicleId)
        if ok then
            TriggerClientEvent('whip_core:client:vmDetail', source, nil)
            ShowSuccess(source,
                ('Vehicle #%d deleted'):format(vehicleId))
            vmBroadcast()
            return true
        end
        return vmResult(source, vehicleId, false, err)
    end
end)

--- Teleport the ADMIN to the vehicle. Server-side because only the server reliably knows where a
--- car is when it is not streamed to the person asking.
SecureEvent('whip_core:server:vmTeleportTo', {
    ace = VM_ACE,
    rateLimit = 500,
    params = { { 'vehicleId', 'id' } },
}, function(source, _, vehicleId)
    local v = Vehicles.context(vehicleId)
    if not v then
        return false, 'Vehicle not found'   -- shown and recorded
    end
    if not v.coords then
        return false, 'That vehicle has no position — it is in a garage'
    end

    TriggerClientEvent('whip_core:client:vmTeleportTo', source, v.coords, v.heading)
end)

--- A character playing now, by id: their player record, or nil and why not.
local function onlineChar(charId)
    local p = charId and PlayersByCharId[charId]
    if not p or not p.source then return nil, 'They are not in the game now' end
    return p
end

--- The Vehicles page's actions that take something picked: a garage (moveGarage) or a character (the rest).
---   moveGarage   into that garage: put away there if it is out, filed there if it is garaged (or impounded)
---   tpPlayer     that player beside it
---   bringPlayer  it out beside that player
---   owner        theirs now (Vehicles.transferOwner), online or not
---   keyTo        a key for them
---   warpIn       that player into its first free seat (their game takes them there: client/ov_effects.lua)
SecureEvent('whip_core:server:vmActOn', {
    ace = VM_ACE,
    rateLimit = 250,
    params = {
        { 'vehicleId', 'id' },
        { 'action', 'enum', { 'moveGarage', 'tpPlayer', 'bringPlayer', 'owner', 'keyTo', 'warpIn' } },
        { 'arg', 'any' },
    },
}, function(source, _, vehicleId, action, arg)
    local def = Vehicles.getDef(vehicleId)
    if not def then return vmResult(source, vehicleId, false, 'Vehicle not found') end

    if action == 'moveGarage' then
        local key = type(arg) == 'string' and arg or nil
        local garage = key and Garages.get(key)
        if not garage then return vmResult(source, vehicleId, false, 'There is no such garage') end
        if def.session then return vmResult(source, vehicleId, false, 'A street car has no garage') end
        local ok, err
        if def.state == 'out' then
            ok, err = Vehicles.store(vehicleId, key)
        else
            ok, err = Vehicles.persist(vehicleId, { garage = key, state = 'garaged' })
        end
        return vmResult(source, vehicleId, ok, err, ('Vehicle #%d is in %s'):format(vehicleId, garage.name or key))
    end

    local charId = Sanitize.id(arg)
    if not charId then return vmResult(source, vehicleId, false, 'Pick who') end

    if action == 'owner' then
        local ok, err = Vehicles.transferOwner(vehicleId, charId)
        local name = ok and (ResolveCharNames({ charId }) or {})[charId] or nil
        return vmResult(source, vehicleId, ok, err,
            ('Vehicle #%d is %s\'s now'):format(vehicleId, name or ('character #' .. charId)))
    end

    local target, why = onlineChar(charId)
    if not target then return vmResult(source, vehicleId, false, why) end
    local who = target.fullName or ('player ' .. target.source)

    if action == 'bringPlayer' then
        local ok, err = bringOutBeside(vehicleId, target.source)
        return vmResult(source, vehicleId, ok, err, ('Vehicle #%d brought to %s'):format(vehicleId, who))

    elseif action == 'keyTo' then
        local ok, err = Vehicles.giveKey(target.source, target, vehicleId)
        return vmResult(source, vehicleId, ok, err, ('%s has a key to vehicle #%d'):format(who, vehicleId))
    end

    -- Beside it, or into it: it has to be in the world.
    local entity, notThere = inWorld(vehicleId)
    if not entity then return vmResult(source, vehicleId, false, notThere) end
    local coords, heading = GetEntityCoords(entity), GetEntityHeading(entity)

    if action == 'tpPlayer' then
        TriggerClientEvent('whip_core:client:vmTeleportTo', target.source, coords, heading)
        return vmResult(source, vehicleId, true, nil, ('%s is beside vehicle #%d'):format(who, vehicleId))
    end

    -- warpIn
    TriggerClientEvent('whip_core:client:ovSelf', target.source, 'warpInto',
        { netId = NetworkGetNetworkIdFromEntity(entity), x = coords.x, y = coords.y, z = coords.z })
    return vmResult(source, vehicleId, true, nil, ('%s is going into vehicle #%d'):format(who, vehicleId))
end)

-- ============================================
-- Editing
-- ============================================

--- The highest slot of one car's trunk or glovebox holding something — on disk, and in memory when
--- its storage is loaded (write-behind; a street car never reaches the disk). For the shrink rule below.
---@param vehicleId number
---@param kind 'trunk'|'glovebox'
---@return number|nil top  0 when empty
---@return string|nil why
local function highestUsedSlotOf(vehicleId, kind)
    local ok, top = pcall(MySQL.scalar.await,
        'SELECT MAX(`slot`) FROM `vehicle_inventory` WHERE `vehicleId` = ? AND `storageType` = ?',
        { vehicleId, kind })
    if not ok then return nil, DB_ERROR end
    top = tonumber(top) or 0
    local inv = Vehicles.invCache[vehicleId]
    for slot, entry in pairs(inv and inv[kind] or {}) do
        if entry and tonumber(slot) and tonumber(slot) > top then top = tonumber(slot) end
    end
    return top
end

--- Change a vehicle's details.
---
--- Straight through Vehicles.persist, which declares every writable column once and coerces what
--- it is given.
SecureEvent('whip_core:server:vmSave', {
    ace = VM_ACE,
    rateLimit = 500,
    params = {
        { 'vehicleId', 'id' },
        { 'fields', 'any' },
    },
}, function(source, _, vehicleId, fields)
    if type(fields) ~= 'table' then return end

    -- Only what the panel is allowed to edit. persist would refuse an unknown column anyway; this
    -- is about not letting the tool grow a field the API has not agreed to.
    local allowed = {
        ownerCharId = true, model = true, plate = true, state = true, garage = true,
        vehType = true, trunkSlots = true, trunkMaxWeight = true,
        gloveboxSlots = true, gloveboxMaxWeight = true,
    }

    local out, changed = {}, false
    for name, value in pairs(fields) do
        if allowed[name] then
            -- The form sends '' for "no override". That means CLEAR, not empty string.
            if value == '' or value == false then
                out[name] = Vehicles.NULL
            else
                out[name] = value
            end
            changed = true
        end
    end

    if not changed then return end

    -- The plate by the same rule as a new car: trimmed, upper case, 8 at most (what GTA puts on the
    -- car), and not one another car wears.
    if out.plate ~= nil then
        if out.plate == Vehicles.NULL then
            return vmResult(source, vehicleId, false, 'A vehicle needs a plate')
        end
        local plate, plateErr = Vehicles.normalisePlate(out.plate)
        if not plate then return vmResult(source, vehicleId, false, plateErr or 'A vehicle needs a plate') end
        local holderId = Vehicles.getByPlate(plate)   -- answers the id first
        if holderId and holderId ~= vehicleId then
            return vmResult(source, vehicleId, false, ('Plate %s is already on vehicle #%s'):format(plate, tostring(holderId)))
        end
        out.plate = plate
    end

    -- A garage that exists: a car filed under a key no garage has is in no garage's
    -- list. "— none —" (Vehicles.NULL) stays allowed: a car with no garage is offered at every one.
    if out.garage ~= nil and out.garage ~= Vehicles.NULL then
        local _, garageErr = Vehicles.checkGarage(out.garage)
        if garageErr then return vmResult(source, vehicleId, false, garageErr) end
    end

    -- Fewer slots only over empty ones, the rule the model defaults below and a container's resize
    -- follow ('' falls back to the model's, its category's or the config's size, which can be smaller):
    -- whatever sat above the new size would be out of reach for good.
    for kind, f in pairs({ trunk = 'trunkSlots', glovebox = 'gloveboxSlots' }) do
        if out[f] ~= nil then
            local newSlots
            if out[f] == Vehicles.NULL then
                local def = Vehicles.getDef(vehicleId)
                newSlots = Vehicles.modelStorage(def and def.model, kind).slots
            else
                newSlots = tonumber(out[f])
                if not newSlots or newSlots < 1 or newSlots ~= math.floor(newSlots) or newSlots > 500 then
                    return vmResult(source, vehicleId, false, f .. ' must be a whole number from 1 to 500')
                end
                out[f] = newSlots
            end
            local top, why = highestUsedSlotOf(vehicleId, kind)
            if not top then return vmResult(source, vehicleId, false, why) end
            if top > newSlots then
                return vmResult(source, vehicleId, false,
                    ('its %s has something in slot %d — empty the slots above %d first'):format(kind, top, newSlots))
            end
        end
    end

    local before = Vehicles.context(vehicleId)

    -- Not a new state for a car that is in the world ('garaged' on a car still in the street would
    -- let the garage bring out a second one). Store and Despawn (the action buttons) take a car out of
    -- the world properly; this form is for the record.
    if before and out.state ~= nil and out.state ~= before.state and Vehicles.getEntity(vehicleId) then
        return vmResult(source, vehicleId, false,
            'That car is in the world. Use Store or Despawn first, then change its state.')
    end

    local ok, err = Vehicles.persist(vehicleId, out)

    -- A car in the world wears its new plate at once: the record and the car must not differ.
    if ok and out.plate then
        local entity = Vehicles.getEntity(vehicleId)
        if entity then SetVehicleNumberPlateText(entity, out.plate) end
    end

    -- Ownership moving is worth announcing, because two client lists have to change and only one
    -- of them belongs to the person who did it.
    if ok and before and out.ownerCharId and out.ownerCharId ~= before.owner.charId then
        Vehicles.announce('ownerChanged', {
            vehicleId = vehicleId,
            from      = before.owner.charId,
            to        = out.ownerCharId,
        })
    end

    return vmResult(source, vehicleId, ok, err, ('Vehicle #%d saved'):format(vehicleId))
end)

--- Set one stat on one vehicle.
---
--- Through VehicleStats.set, never the column. That is what puts the value on the entity's
--- statebag and tells its OnVehicleStatChanged listeners — an admin editing fuel on a car somebody is
--- sitting in should move the gauge in front of them, not just the database.
SecureEvent('whip_core:server:vmSetStat', {
    ace = VM_ACE,
    rateLimit = 250,
    params = {
        { 'vehicleId', 'id' },
        { 'stat', 'key', 40 },
        { 'value', 'number', -1000000, 1000000 },
    },
}, function(source, _, vehicleId, stat, value)
    -- A registered stat, or one this car already carries (from a satellite that has since stopped).
    -- Anything else is a typo, and would be saved on the car forever — the rule the exports follow.
    local def = Vehicles.getDef(vehicleId)
    local carried = def and type(def.vehStats) == 'table' and def.vehStats[stat] ~= nil
    if not VehicleStats.isRegistered(stat) and not carried then
        return vmResult(source, vehicleId, false, ('unknown vehicle stat "%s"'):format(stat), nil)
    end

    local ok, err = VehicleStats.set(vehicleId, stat, value, 'vm:admin')
    return vmResult(source, vehicleId, ok ~= false, err, ('%s set to %s'):format(stat, tostring(value)))
end)

--- Open a compartment without the lock or the distance check.
---
--- The admin override the ordinary path deliberately does not have. Joining a viewer set does not
--- displace whoever is already inside.
SecureEvent('whip_core:server:vmOpenStorage', {
    ace = VM_ACE,
    rateLimit = 500,
    params = {
        { 'vehicleId', 'id' },
        { 'storageType', 'enum', { 'trunk', 'glovebox', 'key' } },
    },
}, function(source, player, vehicleId, storageType)
    if not player.inventory then
        TriggerClientEvent('whip_core:client:openVehicleStorageDenied', source)
        return
    end

    local v = Vehicles.context(vehicleId)
    if not v then
        TriggerClientEvent('whip_core:client:openVehicleStorageDenied', source)
        return false, 'Vehicle not found'
    end

    -- 'admin': the moves keep the override too — past the lock, the keep range and the ignition's
    -- driver's seat, the checks the open skipped.
    Stores.addViewer(source, ('vehicle:%s:%s'):format(tostring(vehicleId), storageType), nil, nil, nil, 'admin')

    if not Vehicles.invCache[vehicleId] then
        Vehicles.loadInventory(vehicleId)
    end

    local names = { trunk = 'Trunk', glovebox = 'Glovebox', key = 'Ignition' }
    local cfg = Vehicles.getStorageConfig(vehicleId, storageType)

    local payload = Inventory.buildPayload(player)
    payload.vehicleId     = vehicleId
    payload.storageType   = storageType
    payload.storageDef    = {
        name      = (names[storageType] or storageType) .. ' — ' .. tostring(v.plate),
        slots     = cfg.slots,
        maxWeight = cfg.maxWeight,
    }
    payload.storageInv    = Vehicles.serializeStorage(vehicleId, storageType)
    payload.storageWeight = Vehicles.getWeight(vehicleId, storageType)
    -- The client's own rules that shut a compartment for where the player is (walked away from the boot,
    -- not in the car for the glovebox, out of the car for the ignition) leave an admin's view alone
    -- (client/vehicles.lua): an admin opens from anywhere.
    payload.admin         = true
    TriggerClientEvent('whip_core:client:openVehicleStorage', source, payload)
end)

--- Create one.
SecureEvent('whip_core:server:vmCreate', {
    ace = VM_ACE,
    rateLimit = 1000,
    params = { { 'data', 'any' } },
}, function(source, player, data)
    if type(data) ~= 'table' then return end

    -- An address: Sanitize.id rejects (int would clamp an empty or 0 owner to character #1).
    local ownerCharId = Sanitize.id(data.ownerCharId)
    if not ownerCharId then
        return false, 'Owner CharID is required'   -- shown and recorded
    end

    local def, createErr = Vehicles.create({
        ownerCharId = ownerCharId,
        model       = Sanitize.key(data.model, 60) or 'adder',
        plate       = Sanitize.string(data.plate, 8),   -- 8, as Vehicles.create allows
        state       = Sanitize.enum(data.state, { 'garaged', 'out', 'impounded' }, 'garaged'),
        garage      = Sanitize.key(data.garage, 60),
    })

    if not def then
        return false, createErr or 'Failed to create vehicle'
    end

    if player and def.ownerCharId == player.charId then
        Vehicles.giveKey(source, player, def.vehicleId)
    end

    ShowSuccess(source,
        ('Vehicle #%d created (%s)'):format(def.vehicleId, def.plate))
    vmBroadcast()
    vmSendDetail(source, def.vehicleId)
end)

-- ============================================
-- The new-vehicle wizard
-- ============================================
--
-- html/js/wp/vehicles.js's + New vehicle: Vehicle (a picture of every model the catalog has), Owner, Extras
-- (its own plate, and its own trunk and glovebox sizes — or its model's), Where (a garage, or out beside the
-- admin), Create. Its stats start at their defaults; its page edits them.

--- Every model the vehicle catalog has (VehicleCatalog: name, class, picture), by name: the wizard's pictures and
--- the Vehicle Adjustments page's categories.
---@return table[]  { { model, name, cls, img, url } }
local function catalogList()
    local list = {}
    for model, row in pairs(VehicleCatalog.rows) do
        -- url: an add-on pack's own picture (RegisterVehicles), where a media pack has none.
        list[#list + 1] = { model = model, name = row.displayName or nil, cls = tonumber(row.class),
                            img = row.hasImage == true or row.addonImage ~= nil, url = row.addonImage }
    end
    table.sort(list, function(a, b) return (a.name or a.model):lower() < (b.name or b.model):lower() end)
    return list
end

--- config.lua's trunk and glovebox, for a model nothing else names (one typed in, that the catalog has not).
local function configStorage()
    return {
        trunkSlots = Config.VehicleTrunkSlots, trunkMaxWeight = Config.VehicleTrunkMaxWeight,
        gloveboxSlots = Config.VehicleGloveboxSlots, gloveboxMaxWeight = Config.VehicleGloveboxMaxWeight,
    }
end

--- What the wizard picks from: every model the vehicle catalog has, and the storage a new car of each would get if
--- not given its own (Vehicles.modelStorage: its model's row, its category's, config.lua; off is hasTrunk = false).
--- Answers { vehicles = { { model, name, cls, img } }, storage = { defaults, models } }.
SecureCallback('whip_core:vmCatalog', {
    ace       = VM_ACE,
    rateLimit = 1000,
}, function()
    local list = catalogList()
    local models = {}
    local function add(model)
        local t, g = Vehicles.modelStorage(model, 'trunk'), Vehicles.modelStorage(model, 'glovebox')
        models[model] = { trunkSlots = t.slots, trunkMaxWeight = t.maxWeight, hasTrunk = t.on,
                          gloveboxSlots = g.slots, gloveboxMaxWeight = g.maxWeight, hasGlovebox = g.on }
    end
    for _, c in ipairs(list) do add(c.model) end
    -- A model the catalog has not (an add-on, typed in) with a row of its own.
    for model in pairs(Vehicles.metaCache) do if not models[model] then add(model) end end
    return {
        vehicles = list,
        storage = { defaults = configStorage(), models = models },
    }
end)

--- The wizard's Create. `data` = { model, ownerCharId, plate?, trunkSlots?, trunkMaxWeight?, gloveboxSlots?,
--- gloveboxMaxWeight?, place = 'garage' | 'here', garage? }. A storage size left out is the model's. 'here' makes it
--- in its garage and brings it out beside the admin, as Bring to me does. Answers { ok, vehicleId, out } or
--- { ok = false, why }; the page opens on the new car (vmSendDetail).
SecureCallback('whip_core:vmWizardCreate', {
    ace       = VM_ACE,
    rateLimit = 1500,
    params    = { { 'data', 'any' } },
}, function(source, player, data)
    if type(data) ~= 'table' then return { ok = false, why = 'Nothing to make' } end
    local ownerCharId = Sanitize.id(data.ownerCharId)
    if not ownerCharId then return { ok = false, why = 'Pick whose it is' } end
    local model = Sanitize.key(data.model, 60)
    if not model then return { ok = false, why = 'Pick a vehicle' } end
    model = model:lower()

    local place = data.place == 'here' and 'here' or 'garage'
    local garage = place == 'garage' and Sanitize.key(data.garage, 60) or nil
    if place == 'garage' and not garage then return { ok = false, why = 'Pick the garage it goes into' } end
    -- A property's garage is its owner's and keyholders': this car's owner must be one of them.
    if garage and Garages.isPrivate(garage) and not Garages.canUse(garage, ownerCharId) then
        return { ok = false, why = 'That is a private garage its owner cannot use' }
    end

    local ped = GetPlayerPed(source)
    local at = (place == 'here' and ped and ped ~= 0) and GetEntityCoords(ped) or nil
    if place == 'here' then
        if not at then return { ok = false, why = 'You have no position to bring it out at' } end
        local away = Vehicles.cannotBringOutFor(source)
        if away then return { ok = false, why = away } end
    end

    -- Its own sizes, or nil: the model's (vehicle_meta), then config.lua.
    local function size(v, max, int)
        local n = tonumber(v)
        if not n or n <= 0 then return nil end
        n = math.min(max, n)
        return int and math.floor(n) or n
    end
    local def, err = Vehicles.create({
        ownerCharId       = ownerCharId,
        model             = model,
        plate             = Sanitize.string(data.plate, 8),
        state             = 'garaged',
        garage            = garage,
        -- Slots up to 500, as the page's Save allows (vmSave).
        trunkSlots        = size(data.trunkSlots, 500, true),
        trunkMaxWeight    = size(data.trunkMaxWeight, 5000),
        gloveboxSlots     = size(data.gloveboxSlots, 500, true),
        gloveboxMaxWeight = size(data.gloveboxMaxWeight, 5000),
    })
    if not def then return { ok = false, why = err or 'The vehicle was not made' } end

    if player and def.ownerCharId == player.charId then Vehicles.giveKey(source, player, def.vehicleId) end

    -- Out beside the admin: from its garage, at their feet (the Bring to me path).
    local out, outWhy = false, nil
    if place == 'here' then
        ---@cast at -nil   -- 'here' was refused above without one
        local retrieved, rErr = Vehicles.retrieve(def.vehicleId, def.garage)
        if retrieved then
            local entity, netOrErr = Vehicles.spawn(def.vehicleId, at.x + 3.0, at.y, at.z, GetEntityHeading(ped) or 0.0)
            out, outWhy = entity ~= nil and entity ~= false, not entity and netOrErr or nil
        else
            outWhy = rErr
        end
    end

    ShowSuccess(source, ('Vehicle #%d made (%s)%s'):format(def.vehicleId, def.plate,
        place == 'here' and (out and ', beside you' or ', in its garage: it could not be brought out') or ''))
    vmBroadcast()
    vmSendDetail(source, def.vehicleId)
    return { ok = true, vehicleId = def.vehicleId, out = out, why = outWhy and tostring(outWhy) or nil }
end)

-- ============================================
-- Vehicle Adjustments — trunk and glovebox per category and per model
-- ============================================
--
-- The /whip Vehicles group's Vehicle Adjustments page (html/js/wp/vehicleModels.js) writes `vehicle_class_meta`
-- (a category: every model of one GTA vehicle class) and `vehicle_meta` (one model) with these calls, read by
-- Vehicles.modelStorage. What a car gets: its own sizes (given when it was made) → its model's row → its
-- category's → config.lua. Either row can turn the trunk or the glovebox off, the model's word over its category's.

local SIZE_FIELDS = { 'trunkSlots', 'trunkMaxWeight', 'gloveboxSlots', 'gloveboxMaxWeight' }
local CLASS_LAST = 22   -- GTA's vehicle classes: 0 (compacts) to 22 (open wheel)

--- A row as the page reads it.
local function rowOut(m)
    return {
        trunkSlots = m.trunkSlots, trunkMaxWeight = m.trunkMaxWeight, hasTrunk = m.hasTrunk,
        gloveboxSlots = m.gloveboxSlots, gloveboxMaxWeight = m.gloveboxMaxWeight, hasGlovebox = m.hasGlovebox,
    }
end

--- The page: each category's row and config.lua's sizes for it, each model's row, and (on entering) the catalog to
--- list them by. Lists, not keyed by number, for the trip to the page.
local function adjustmentsList(withCatalog)
    local classes = {}
    for class = 0, CLASS_LAST do
        local c = Vehicles.classMetaCache[class]
        classes[#classes + 1] = {
            class = class, row = c and rowOut(c) or nil,
            config = {
                trunkSlots = Vehicles.configSlots(class, 'trunk'), trunkMaxWeight = Config.VehicleTrunkMaxWeight,
                gloveboxSlots = Vehicles.configSlots(class, 'glovebox'), gloveboxMaxWeight = Config.VehicleGloveboxMaxWeight,
            },
        }
    end
    local models = {}
    for model, m in pairs(Vehicles.metaCache) do
        local r = rowOut(m)
        r.model = model
        models[#models + 1] = r
    end
    table.sort(models, function(a, b) return a.model < b.model end)
    return { classes = classes, models = models, config = configStorage(), catalog = withCatalog and catalogList() or nil }
end

--- What every model's trunks and gloveboxes hold now, for the check below: per model, the highest slot in use across
--- its cars that take their size from it (none of their own), and whether any of its cars has anything in there at
--- all. On disk, and in memory for the cars loaded now (write-behind, and street cars that never reach the database).
---@return table|nil used  [model] = { trunk = { top, any }, glovebox = { top, any } }
---@return string|nil why
local function usedByModel()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT LOWER(v.`model`) AS model, vi.`storageType` AS kind,
               MAX(CASE WHEN (vi.`storageType` = 'trunk' AND v.`trunkSlots` IS NULL)
                          OR (vi.`storageType` = 'glovebox' AND v.`gloveboxSlots` IS NULL)
                        THEN vi.`slot` ELSE 0 END) AS top
        FROM `vehicle_inventory` vi JOIN `vehicles` v ON v.`vehicleId` = vi.`vehicleId`
        WHERE vi.`storageType` IN ('trunk', 'glovebox')
        GROUP BY LOWER(v.`model`), vi.`storageType`
    ]], {})
    if not ok then return nil, DB_ERROR end
    local used = {}
    local function note(model, kind, top)
        local m = used[model]
        if not m then
            m = { trunk = { top = 0, any = false }, glovebox = { top = 0, any = false } }
            used[model] = m
        end
        m[kind].any = true
        if top > m[kind].top then m[kind].top = top end
    end
    for _, row in ipairs(rows or {}) do
        if Vehicles.STORAGE_KEYS[row.kind] then note(tostring(row.model), row.kind, tonumber(row.top) or 0) end
    end
    for vehicleId, def in pairs(Vehicles.getAll()) do
        local inv = Vehicles.invCache[vehicleId]
        if inv then
            local model = tostring(def.model or ''):lower()
            for kind, k in pairs(Vehicles.STORAGE_KEYS) do
                for slot, entry in pairs(inv[kind] or {}) do
                    -- A car with its own size counts as holding something, not towards the top.
                    if entry and tonumber(slot) then note(model, kind, def[k.slots] and 0 or tonumber(slot)) end
                end
            end
        end
    end
    return used
end

--- Would a change put something out of reach? For each model it touches, what its cars hold against its storage
--- now and after (Vehicles.layeredStorage with its rows now and with the new one): off must be empty, smaller must be
--- empty above its new size. Only what the change itself takes away: something already out of reach (put in by a
--- script) does not stop a change that leaves it so.
---@param used table  usedByModel()
---@param list table[]  { { model, class, now = { classRow, modelRow }, after = { classRow, modelRow } } }
---@return boolean ok
---@return string|nil why  naming the first model it stops on
local function checkReach(used, list)
    local function lost(s, u)
        return (not s.on and u.any) or (s.on and u.top > s.slots)
    end
    for _, t in ipairs(list) do
        local u = used[t.model]
        if u then
            for kind in pairs(Vehicles.STORAGE_KEYS) do
                local before = Vehicles.layeredStorage(kind, t.class, t.now[1], t.now[2])
                local after = Vehicles.layeredStorage(kind, t.class, t.after[1], t.after[2])
                if lost(after, u[kind]) and not lost(before, u[kind]) then
                    if not after.on then
                        return false, ('a %s still has something in its %s: empty it before turning the %s off')
                            :format(t.model, kind, kind)
                    end
                    return false, ('a %s still has something in %s slot %d: empty the slots above %d first')
                        :format(t.model, kind, u[kind].top, after.slots)
                end
            end
        end
    end
    return true
end

--- The page's fields, checked: the four sizes (blank: not said) and the two on/offs (true, false, or not said). A
--- category's "on" is not said (on is what config.lua gives). Answers the row, and whether it says anything.
---@return table|nil clean
---@return boolean|string any  or why not
local function cleanFields(data, forClass)
    if type(data) ~= 'table' then return nil, 'Nothing to save' end
    local clean, any = {}, false
    for _, f in ipairs(SIZE_FIELDS) do
        local v = data[f]
        if v ~= nil and v ~= '' then
            v = tonumber(v)
            local isSlots = f:find('Slots') ~= nil
            if not v or v ~= v or v <= 0 or (isSlots and v ~= math.floor(v)) then
                return nil, ('%s must be %s'):format(f, isSlots and 'a whole number above 0' or 'a number above 0')
            end
            if isSlots and v > 500 then return nil, f .. ' is at most 500' end
            clean[f] = isSlots and math.floor(v) or v
            any = true
        end
    end
    for _, f in ipairs({ 'hasTrunk', 'hasGlovebox' }) do
        local v = data[f]
        if v ~= nil and v ~= true and v ~= false then return nil, f .. ' is on, off, or not said' end
        if forClass and v == true then v = nil end
        if v ~= nil then
            clean[f] = v
            any = true
        end
    end
    return clean, any
end

--- Tell every client which trunks and gloveboxes are off now (their prompts and F2 go by it).
local function broadcastStorage()
    TriggerClientEvent('whip_core:client:vehicleStorageSync', -1, Vehicles.storageWire())
end

SecureCallback('whip_core:vm:modelStorage', {
    ace = VM_ACE, whileDead = true, rateLimit = 250,
    params = { {'withCatalog', 'bool', false} },
}, function(_, _, withCatalog)
    return adjustmentsList(withCatalog)
end)

--- Set one model's own: blank sizes and an unsaid on/off are its category's; nothing said at all removes its row.
SecureCallback('whip_core:vm:setModelStorage', {
    ace = VM_ACE, whileDead = true, rateLimit = 250,
    params = { {'model', 'string', 60}, {'data', 'any'} },
}, function(_, _, model, data)
    model = tostring(model or ''):lower():gsub('%s+', '')
    if model == '' or not model:match('^[%w_%-]+$') then return false, 'A model name is letters, digits, _ and -' end
    local clean, any = cleanFields(data, false)
    if not clean then return false, any end

    local used, why = usedByModel()
    if not used then return false, why end
    local class = Vehicles.classForModel(model)
    local classRow = class and Vehicles.classMetaCache[class] or nil
    local ok, lostWhy = checkReach(used, { { model = model, class = class,
        now = { classRow, Vehicles.metaCache[model] }, after = { classRow, any and clean or nil } } })
    if not ok then return false, lostWhy end

    local saved
    if any then saved = Vehicles.saveMeta(model, clean) else saved = Vehicles.deleteMeta(model) end
    if not saved then return false, DB_ERROR end
    broadcastStorage()
    return true
end)

SecureCallback('whip_core:vm:clearModelStorage', {
    ace = VM_ACE, whileDead = true, rateLimit = 250,
    params = { {'model', 'string', 60} },
}, function(_, _, model)
    model = tostring(model or ''):lower():gsub('%s+', '')
    if not Vehicles.metaCache[model] then return false, 'That model has nothing of its own' end
    local used, why = usedByModel()
    if not used then return false, why end
    local class = Vehicles.classForModel(model)
    local classRow = class and Vehicles.classMetaCache[class] or nil
    local ok, lostWhy = checkReach(used, { { model = model, class = class,
        now = { classRow, Vehicles.metaCache[model] }, after = { classRow, nil } } })
    if not ok then return false, lostWhy end
    if not Vehicles.deleteMeta(model) then return false, DB_ERROR end
    broadcastStorage()
    return true
end)

--- A category's number from the page: a whole number from 0 to 22, else nil.
local function classOf(raw)
    local class = tonumber(raw)
    if not class or class ~= math.floor(class) or class < 0 or class > CLASS_LAST then return nil end
    return class
end

--- Every model of a category the check must look at: the catalog's, with their own rows.
local function reachList(class, after)
    local now = Vehicles.classMetaCache[class]
    local list = {}
    for model, row in pairs(VehicleCatalog.rows) do
        if tonumber(row.class) == class then
            local m = Vehicles.metaCache[model]
            list[#list + 1] = { model = model, class = class, now = { now, m }, after = { after, m } }
        end
    end
    return list
end

--- Set one category's: every model of that class without its own. Blank sizes are config.lua's; nothing said at all
--- removes its row.
SecureCallback('whip_core:vm:setClassStorage', {
    ace = VM_ACE, whileDead = true, rateLimit = 250,
    params = { {'class', 'any'}, {'data', 'any'} },
}, function(_, _, rawClass, data)
    local class = classOf(rawClass)
    if not class then return false, 'No such category' end
    local clean, any = cleanFields(data, true)
    if not clean then return false, any end

    local used, why = usedByModel()
    if not used then return false, why end
    local ok, lostWhy = checkReach(used, reachList(class, any and clean or nil))
    if not ok then return false, lostWhy end

    local saved
    if any then saved = Vehicles.saveClassMeta(class, clean) else saved = Vehicles.deleteClassMeta(class) end
    if not saved then return false, DB_ERROR end
    broadcastStorage()
    return true
end)

SecureCallback('whip_core:vm:clearClassStorage', {
    ace = VM_ACE, whileDead = true, rateLimit = 250,
    params = { {'class', 'any'} },
}, function(_, _, rawClass)
    local class = classOf(rawClass)
    if not class then return false, 'No such category' end
    if not Vehicles.classMetaCache[class] then return false, 'That category has nothing of its own' end
    local used, why = usedByModel()
    if not used then return false, why end
    local ok, lostWhy = checkReach(used, reachList(class, nil))
    if not ok then return false, lostWhy end
    if not Vehicles.deleteClassMeta(class) then return false, DB_ERROR end
    broadcastStorage()
    return true
end)
