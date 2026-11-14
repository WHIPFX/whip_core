-- ============================================
-- Item: vehicle_key (Vehicle Key Fob)
-- Non-usable — ownership validation + give helper
-- ============================================

--- Returns true if the player's inventory contains a vehicle_key with matching vehicleId
---@diagnostic disable-next-line: duplicate-set-field -- the client's Vehicles is a different table
function Vehicles.playerHasKey(player, vehicleId)
    if not player or not player.inventory then return false end
    for _, container in pairs(PlayerContainers) do
        local slots = player.inventory[container]
        if slots then
            for _, slot in pairs(slots) do
                -- keyFits, not an id comparison — see Vehicles.keyFits for why a street car's key
                -- has to match its plate as well as its (reusable) session id.
                if slot and Inventory.isIgnitionKey(slot.item)
                    and Vehicles.keyFits(slot.metadata, vehicleId) then
                    return true
                end
            end
        end
    end
    return false
end

--- Scan player inventory and return table of vehicleIds they have keys for
function Vehicles.getPlayerKeys(player)
    local keys = {}
    if not player or not player.inventory then return keys end
    for _, container in pairs(PlayerContainers) do
        local slots = player.inventory[container]
        if slots then
            for _, slot in pairs(slots) do
                if slot and Inventory.isIgnitionKey(slot.item)
                    and slot.metadata
                    and slot.metadata.vehicleId then
                    local vId = tonumber(slot.metadata.vehicleId)
                    -- Only keys that still FIT: a stale street-car key names an id that now belongs
                    -- to a different car, and the client would otherwise show it as a working key.
                    if vId and Vehicles.keyFits(slot.metadata, vId) then
                        local def = Vehicles.getDef(vId)
                        keys[vId] = (def and def.plate) or true
                    end
                end
            end
        end
    end
    return keys
end

-- What each player's client was last sent, as a signature. [source] = string ('' = no keys)
local _keysSent = {}

--- Tell a player's client which cars their keys fit — only when that changed, unless `force`.
---
--- The list is worked out each time (a scan of the pockets, cheap) and compared with what was sent,
--- so a key that stops fitting without moving is still noticed, but only a change is sent. EVERY
--- sender goes through here, which keeps the remembered signature equal to what the client holds.
---@param source number
---@param player table
---@param force boolean|nil  send even if unchanged (a character loading)
function Vehicles.syncKeys(source, player, force)
    local keys = Vehicles.getPlayerKeys(player)
    local parts = {}
    for id, plate in pairs(keys) do parts[#parts + 1] = tostring(id) .. '=' .. tostring(plate) end
    table.sort(parts)
    local sig = table.concat(parts, ',')
    if not force and _keysSent[source] == sig then return end
    _keysSent[source] = sig
    TriggerClientEvent('whip_core:client:vehicleKeysSync', source, keys)
end

AddEventHandler('playerDropped', function()
    _keysSent[source] = nil
end)

--- Everyone sitting in this car, told what its ignition holds now (a key put in or taken out by code, not by their own
--- drag: the store's afterMove tells the one who dragged). Their game stops the engine when the key went.
---@param vehicleId number
function Vehicles.tellIgnition(vehicleId)
    local ent = Vehicles.getEntity(vehicleId)
    if not ent then return end
    for src, p in pairs(Players) do
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) == ent then
            Vehicles.syncKeys(src, p)
            TriggerClientEvent('whip_core:client:ignitionState', src, vehicleId, Vehicles.ignitionReady(vehicleId),
                Vehicles.hasUnhackedKeyInIgnition(vehicleId))
            TriggerClientEvent('whip_core:client:updateIgnitionSlot', src, { ignitionSlot = Vehicles.getIgnitionSlot(vehicleId) })
        end
    end
end

--- Every online player's key list sent again where it changed: a car's keys stopped fitting without moving (its
--- key token changed: Vehicles.setSecure).
function Vehicles.resyncAllKeys()
    for src, p in pairs(Players) do Vehicles.syncKeys(src, p) end
end

--- Can a player's pockets take a car key now (giveKey's own containers, Inventory.canFitItem)? Asked BEFORE a key
--- leaves where it is (an ignition, a glovebox) for their pockets, so a refusal never leaves the car keyless.
---@param player table  WhipPlayer instance
---@return boolean fits
---@return string|nil why
function Vehicles.canTakeKey(player)
    if not player or not player.inventory then return false, 'Player has no inventory' end
    if not Inventory.canFitItem(player.inventory, 'vehicle_key', 1) then return false, 'Their pockets have no room for a key' end
    return true
end

--- THE KEY'S METADATA, the one shape every key of a car is cut with: { vehicleId, plate, model, token } (token: a
--- secure car's, Vehicles.keyFits; nil for every other car), with `extra`'s fields added (a Director run's stamp, its
--- director and dworld; Dungeon Mode's dlive). nil when whip has no such car.
---@param vehicleId number
---@param extra table|nil
---@return table|nil metadata
function Vehicles.keyMetadata(vehicleId, extra)
    local def = Vehicles.getDef(vehicleId)
    if not def then return nil end
    local md = { vehicleId = vehicleId, plate = def.plate, model = def.model, token = def.keyToken }
    for k, v in pairs(extra or {}) do md[k] = v end
    return md
end

--- Give a vehicle key to a player: add to inventory, save, sync to client.
--- @param source number  Player server ID
--- @param player table   WhipPlayer instance
--- @param vehicleId number
--- @return boolean success, string message
function Vehicles.giveKey(source, player, vehicleId)
    if not player or not player.inventory then
        return false, 'Player has no inventory'
    end

    local def = Vehicles.getDef(vehicleId)
    if not def then
        return false, ('Vehicle #%d not found'):format(vehicleId)
    end

    if Vehicles.playerHasKey(player, vehicleId) then
        return false, 'Already has a key for this vehicle'
    end

    local ok, err = Inventory.addItemWithFallback(player.inventory, 'vehicle_key', 1, Vehicles.keyMetadata(vehicleId))

    if not ok then
        return false, ('Failed to give key: %s'):format(err or 'No room')
    end

    -- A key being made is an item entering the game — and a free key was one of the worst bugs
    -- the 22 Sep audit found, so every one is on the record.
    Log.gained(player.charId, 'vehicle_key', 1, 'key for ' .. tostring(def.plate))

    -- Flushed through the store (which also sends the inventory update and the key sync). A key is
    -- usually handed over beside a write-through change — a purchase, a garage record — so it is
    -- committed now; Inventory.save did that too, but blind to an in-flight flush of this character.
    Inventory.syncAndFlush(source, player)

    return true, ('Received key for %s (%s)'):format(def.model, def.plate)
end

--- Remove a vehicle's keys from a player's inventory (confiscate/impound, a sale's revokeOldKeys).
--- Scans all their containers and takes EVERY key that fits, then syncs the client once.
---
--- Every one, and by Vehicles.keyFits, the one rule every key reader uses (a seller may hold two
--- keys; an id may be stored as a string).
--- @param source number  Player server ID
--- @param player table   WhipPlayer instance
--- @param vehicleId number
--- @return boolean removed  true if at least one key was taken
function Vehicles.removeKey(source, player, vehicleId)
    if not player or not player.inventory then return false end
    local found = {}
    for _, containerKey in ipairs(PlayerContainers) do
        local slots = player.inventory[containerKey]
        if slots then
            for slot, slotData in pairs(slots) do
                if slotData and Inventory.isIgnitionKey(slotData.item)
                    and Vehicles.keyFits(slotData.metadata, vehicleId) then
                    found[#found + 1] = { containerKey = containerKey, slot = slot, slotData = slotData }
                end
            end
        end
    end
    if #found == 0 then return false end

    -- Collected first, cleared after: clearing inside the walk edits the table being walked.
    for _, k in ipairs(found) do
        Inventory.clearSlot(player.inventory, k.containerKey, k.slot)
        Log.item(player.charId, 'lost', k.slotData, {
            amount = k.slotData.amount or 1,
            detail = 'key for ' .. tostring(k.slotData.metadata.plate or ('vehicle #' .. vehicleId)) .. ' taken back',
        })
    end
    Inventory.syncAndFlush(source, player)   -- see giveKey
    return true
end
