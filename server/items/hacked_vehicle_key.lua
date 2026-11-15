-- ============================================
-- Item: hacked_vehicle_key (Hacked Vehicle Key)
-- Non-usable — bypass key for vehicle ignitions
-- ============================================

--- Check if a vehicle's ignition contains an unhacked key (no vehicleId in metadata)
---@param vehicleId number
---@return boolean hasUnhacked, table|nil slotData
function Vehicles.hasUnhackedKeyInIgnition(vehicleId)
    if not Vehicles.invCache[vehicleId] then
        Vehicles.loadInventory(vehicleId)
    end
    local keyInv = Vehicles.invCache[vehicleId] and Vehicles.invCache[vehicleId].key
    if not keyInv then return false, nil end
    for _, slotData in pairs(keyInv) do
        if slotData.item == 'hacked_vehicle_key' then
            local meta = slotData.metadata or {}
            if not meta.vehicleId then
                return true, slotData
            end
        end
    end
    return false, nil
end

--- Link a hacked key in the ignition to a specific vehicle (post-hack success)
--- Updates metadata with vehicleId, plate, model, status and saves to DB
---@param vehicleId number
---@return boolean success
function Vehicles.linkHackedKey(vehicleId)
    if not Vehicles.invCache[vehicleId] then
        Vehicles.loadInventory(vehicleId)
    end
    local keyInv = Vehicles.invCache[vehicleId] and Vehicles.invCache[vehicleId].key
    if not keyInv or not keyInv[1] then return false end

    local slotData = keyInv[1]
    if slotData.item ~= 'hacked_vehicle_key' then return false end

    local def = Vehicles.getDef(vehicleId)
    if not def then return false end

    -- Get model name — if it looks like a hash (number or negative), use plate as fallback
    local modelName = def.model
    if modelName and (tonumber(modelName) or modelName:match('^%-?%d+$')) then
        modelName = nil
    end

    slotData.metadata = slotData.metadata or {}
    slotData.metadata.vehicleId = vehicleId
    slotData.metadata.plate = def.plate
    slotData.metadata.model = modelName
    slotData.metadata.status = 'hacked'
    -- Cut for the car's locks as they are (Vehicles.keyFits): a car whose locks were changed takes it now, and a
    -- later change of them shuts it out like every other key.
    slotData.metadata.token = def.keyToken

    pcall(Vehicles.saveInventory, vehicleId, 'key')
    return true
end
