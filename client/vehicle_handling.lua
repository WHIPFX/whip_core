-- Vehicle handling: the one owner of handling writes. Features never write handling; they declare a layer on a car:
--
--     exports.whip_core:SetVehicleHandlingLayer({ entity = veh }, 'engine', {
--         set   = { fInitialDriveForce = 0.34, nInitialDriveGears = 6 },   -- absolute values
--     })
--     exports.whip_core:SetVehicleHandlingLayer({ entity = veh }, 'turbo', {
--         scale = { fInitialDriveForce = 1.8, fInitialDriveMaxFlatVel = 1.4 },   -- multipliers
--     })
--     exports.whip_core:SetVehicleHandlingLayer({ entity = veh }, 'topSpeed', {
--         add   = { fInitialDriveMaxFlatVel = 42.2 },   -- amounts added (whip_autos' top speed)
--     })
--     exports.whip_core:ClearVehicleHandlingLayer('turbo')
--
-- Per field the car gets: its stock value, then every layer's `set` in `order` (a later order wins), then every
-- layer's `add` summed on, then every layer's `scale` multiplied in.
--
-- One car at a time: the one this player drives (only the driver owns its physics). A layer on a different car
-- puts the previous one back and drops its layers.
--
-- Stock is captured per field before the first write. Every written field goes back when the last layer leaves:
-- layers clearing, a different car, the car dying, the layer's resource stopping, or whip_core stopping.

local VehicleHandling = {}

--- Handling writes do nothing to the drivetrain until the transmission is re-initialised (ModifyVehicleTopSpeed).
--- 0.0, not 1.0: the argument is a top speed change in percent.
local TOPSPEED_COMMIT = 0.0

--- Smallest change worth a write on a field a multiplier moves (every write rebuilds the transmission).
--- Fields only set are written whenever they differ.
local WRITE_EPSILON = 0.05

--- Fields whose change needs the transmission rebuilt (fDriveBiasFront, which axle is driven, is one).
local DRIVETRAIN = {
    fInitialDriveForce = true, fInitialDriveMaxFlatVel = true, fDriveInertia = true,
    nInitialDriveGears = true, fClutchChangeRateScaleUpShift = true, fClutchChangeRateScaleDownShift = true,
    fDriveBiasFront = true,
}

--- The one car being modified: its entity, each touched field's stock value, the last write, and what the layers last asked for.
local tuned = { entity = nil, stock = {}, wrote = {}, asked = {} }

--- [layerKey '<resource>:<name>'] = { owner, name, order, set = {field=value}, add = {field=amount}, scale = {field=factor} }
--- On shared/registry.lua: keyed per resource and swept when it stops; a layer going re-applies or restores the car.
local layers = {}
local layerReg            -- made below apply, which its hooks call
local _releasing = false  -- release taking every layer off: one put-back, not one per layer

local function isInt(field) return field:sub(1, 1) == 'n' end

local function readField(entity, field)
    if isInt(field) then return GetVehicleHandlingInt(entity, 'CHandlingData', field) end
    return GetVehicleHandlingFloat(entity, 'CHandlingData', field)
end

local function writeField(entity, field, value)
    if isInt(field) then
        local n = math.floor(value + 0.5)
        if field == 'nInitialDriveGears' then n = math.max(1, math.min(7, n)) end
        SetVehicleHandlingInt(entity, 'CHandlingData', field, n)
        if field == 'nInitialDriveGears' then SetVehicleHighGear(entity, n) end
    else
        SetVehicleHandlingFloat(entity, 'CHandlingData', field, value + 0.0)
    end
end

--- Put the car back and forget it. Safe at any time, including when nothing is tuned.
function VehicleHandling.release()
    local entity = tuned.entity
    if entity and DoesEntityExist(entity) then
        local drivetrain = false
        for field, value in pairs(tuned.stock) do
            writeField(entity, field, value)
            if DRIVETRAIN[field] then drivetrain = true end
        end
        if drivetrain then ModifyVehicleTopSpeed(entity, TOPSPEED_COMMIT) end
    end
    tuned.entity, tuned.stock, tuned.wrote, tuned.asked = nil, {}, {}, {}
    if _releasing or next(layers) == nil then return end
    _releasing = true
    local all = {}
    for _, l in pairs(layers) do all[#all + 1] = l end
    for _, l in ipairs(all) do layerReg:remove(l.owner, l.name) end
    _releasing = false
end

--- Work out every touched field and write the ones that moved.
local function apply()
    local entity = tuned.entity
    if not entity or not DoesEntityExist(entity) then return end

    -- Layers sorted by `order`, then name, so ties resolve the same way every time.
    local ordered = {}
    for key, l in pairs(layers) do ordered[#ordered + 1] = { key = key, l = l } end
    table.sort(ordered, function(a, b)
        if a.l.order ~= b.l.order then return a.l.order < b.l.order end
        return a.key < b.key
    end)

    local want, scaled = {}, {}
    for _, o in ipairs(ordered) do
        for field in pairs(o.l.set) do want[field] = true end
        for field in pairs(o.l.add) do want[field] = true end
        for field in pairs(o.l.scale) do want[field] = true end
    end

    -- Capture stock for any field about to be touched for the first time.
    for field in pairs(want) do
        if tuned.stock[field] == nil then tuned.stock[field] = readField(entity, field) end
    end

    local values = {}
    for field in pairs(want) do values[field] = tuned.stock[field] end
    for _, o in ipairs(ordered) do
        for field, v in pairs(o.l.set) do values[field] = v end
    end
    -- Then the amounts added, onto whatever the sets left.
    for _, o in ipairs(ordered) do
        for field, d in pairs(o.l.add) do values[field] = values[field] + d end
    end
    -- Before any multiplier: what a scaled field returns to when every scale is 1.
    local unscaled = {}
    for field, v in pairs(values) do unscaled[field] = v end
    for _, o in ipairs(ordered) do
        for field, f in pairs(o.l.scale) do
            values[field] = values[field] * f
            scaled[field] = true
        end
    end

    -- Fields no layer mentions any more go back to stock.
    for field, stock in pairs(tuned.stock) do
        if not want[field] then values[field] = stock end
    end

    local drivetrain = false
    for field, value in pairs(values) do
        local wrote = tuned.wrote[field]
        local base = tuned.stock[field] or value
        local moved
        if wrote == nil then
            moved = value ~= base
        elseif scaled[field] then
            -- A moving value is written in deadband steps; one that has stopped moving (asked for twice running,
            -- or back to its unscaled value) is written exactly, or the last small steps would never land.
            moved = math.abs(value - wrote) >= math.max(math.abs(base) * WRITE_EPSILON, 1e-4)
                or (value ~= wrote and (value == tuned.asked[field] or value == unscaled[field]))
        else
            moved = value ~= wrote
        end
        tuned.asked[field] = scaled[field] and value or nil
        if moved then
            writeField(entity, field, value)
            tuned.wrote[field] = value
            if DRIVETRAIN[field] then drivetrain = true end
        end
        if not want[field] then
            -- Back at stock and nothing wants it: stop tracking it.
            tuned.stock[field] = nil
            tuned.wrote[field] = nil
            tuned.asked[field] = nil
        end
    end
    if drivetrain then ModifyVehicleTopSpeed(entity, TOPSPEED_COMMIT) end
end

layerReg = Registry.new('vehicleHandlingLayers', {
    label  = 'handling layer',
    store  = layers,
    scoped = true,
    -- Every set applies, a repeat included: a stopped scaled value is written exactly on its repeat (apply's settle rule).
    same   = false,
    onAdd  = function() apply() end,
    -- A layer gone (cleared, or its resource stopped): the rest re-applied, or the car put back.
    onRemove = function()
        if _releasing then return end
        if next(layers) == nil then VehicleHandling.release() else apply() end
    end,
})

--- A handling field name this owner will touch: CHandlingData floats (f...) and ints (n...).
local function validField(field)
    return type(field) == 'string' and field:match('^[fn][A-Z][%w]+$') ~= nil and #field <= 48
end

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end

--- Declare (or replace) your layer on a car.
---@param vehicle any     a vehicle reference: { entity = veh } or a vehicleId
---@param name string     your layer's name, one per feature ('engine', 'turbo')
---@param spec table      { set = { field = value }, add = { field = amount }, scale = { field = factor }, order = number }
---@return boolean ok, string|nil why
function VehicleHandling.setLayer(vehicle, name, spec, owner)
    local entity = Vehicles.refEntity(vehicle)
    if type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'no such vehicle'
    end
    if type(name) ~= 'string' or name == '' or #name > 40 then return false, 'name is required (1-40 characters)' end
    if type(spec) ~= 'table' then return false, 'spec must be a table: { set = {...}, add = {...}, scale = {...} }' end

    local set, add, scale = {}, {}, {}
    for field, v in pairs(type(spec.set) == 'table' and spec.set or {}) do
        if not validField(field) then return false, ('"%s" is not a handling field'):format(tostring(field)) end
        if not finite(v) then return false, ('set.%s must be a number'):format(field) end
        set[field] = v
    end
    for field, d in pairs(type(spec.add) == 'table' and spec.add or {}) do
        if not validField(field) then return false, ('"%s" is not a handling field'):format(tostring(field)) end
        if not finite(d) or d < -1000 or d > 1000 then
            return false, ('add.%s must be an amount between -1000 and 1000'):format(field)
        end
        add[field] = d
    end
    for field, f in pairs(type(spec.scale) == 'table' and spec.scale or {}) do
        if not validField(field) then return false, ('"%s" is not a handling field'):format(tostring(field)) end
        if not finite(f) or f < 0.01 or f > 100 then
            return false, ('scale.%s must be a factor between 0.01 and 100'):format(field)
        end
        scale[field] = f
    end

    -- A different car means the old one goes back first, layers and all.
    if tuned.entity and tuned.entity ~= entity then VehicleHandling.release() end
    tuned.entity = entity

    -- Applied by the registry's onAdd, every time (same = false, above).
    local ok, why = layerReg:add(owner, name, {
        owner = owner, name = name,
        order = finite(spec.order) and spec.order or 0,
        set = set, add = add, scale = scale,
    })
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end

--- Take your layer off (whatever car it is on). The car goes back to stock once nothing is left.
---@return boolean removed
function VehicleHandling.clearLayer(name, owner)
    if layers[layerReg:keyOf(owner, name)] == nil then return false end
    return (layerReg:remove(owner, name))   -- onRemove re-applies or puts the car back
end

--- A field's value after every layer's `set` and `add` but before any `scale` (what a multiplier multiplies).
--- For an unmodified car, its current value.
function VehicleHandling.base(vehicle, field)
    local entity = Vehicles.refEntity(vehicle)
    if type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) or not validField(field) then return nil end
    if entity ~= tuned.entity or tuned.stock[field] == nil then return readField(entity, field) end
    local value, bestOrder, bestKey = tuned.stock[field], nil, nil
    for key, l in pairs(layers) do
        if l.set[field] ~= nil and (bestOrder == nil or l.order > bestOrder or (l.order == bestOrder and key > bestKey)) then
            value, bestOrder, bestKey = l.set[field], l.order, key
        end
    end
    for _, l in pairs(layers) do
        if l.add[field] ~= nil then value = value + l.add[field] end
    end
    return value
end

exports('SetVehicleHandlingLayer', function(vehicle, name, spec) return VehicleHandling.setLayer(vehicle, name, spec, Registry.caller()) end)
exports('ClearVehicleHandlingLayer', function(name) return VehicleHandling.clearLayer(name, Registry.caller()) end)
exports('GetVehicleHandlingBase', function(vehicle, field) return VehicleHandling.base(vehicle, field) end)

-- Engine power: torque, not gearing. A turbo or nitrous adds torque via SET_VEHICLE_CHEAT_POWER_INCREASE
-- (scaling fInitialDriveMaxFlatVel would stretch the gears). It multiplies drive force, needs no rebuild and
-- lasts one frame, so it is written every frame from whip's per-frame loop; an unasked car is back at 1.0.
-- One writer: the last write in a frame wins, so resources ask here and the car gets the product.
-- The car this player drives, one at a time, as with the layers.

local power = { entity = nil, mult = 1.0, held = false }

--- ['<resource>:<name>'] = { owner, name, entity, mult }
local powers = {}
local powerReg   -- made below powerApply, which its hooks call

--- Every frame while held: the product, onto the car. No existence check (half this hook's cost): a vanished
--- car is forgotten within a second by the thread below, and GTA ignores writes to a dead handle.
local function powerFrame()
    if not power.held then return end   -- a hook let go earlier in this frame still runs once
    local e = power.entity
    if e then SetVehicleCheatPowerIncrease(e, power.mult) end
end

--- The product of every ask on the current car, and the per-frame write held only while it is not 1.
local function powerApply()
    local mult = 1.0
    for _, p in pairs(powers) do
        if p.entity == power.entity then mult = mult * p.mult end
    end
    -- Nothing asked: no car.
    if next(powers) == nil then power.entity = nil end
    power.mult = mult
    local want = power.entity ~= nil and mult ~= 1.0
    if want ~= power.held then
        power.held = want
        if want then ControlBlocks.hold('vehiclePower', {}, powerFrame)
        else ControlBlocks.release('vehiclePower') end
    end
end

powerReg = Registry.new('vehiclePower', {
    label    = 'vehicle power',
    store    = powers,
    scoped   = true,
    onAdd    = function() powerApply() end,
    onRemove = function() powerApply() end,
})

--- Ask for engine torque on the car this player drives: a multiplier, 1.0 being the engine as it is.
---@param vehicle any        a vehicle reference: { entity = veh } or a vehicleId
---@param name string        your ask's name, one per feature
---@param multiplier number  0 to 10; the car gets the product of every resource's
---@return boolean ok, string|nil why
function VehicleHandling.setPower(vehicle, name, multiplier, owner)
    local entity = Vehicles.refEntity(vehicle)
    if type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'no such vehicle'
    end
    if type(name) ~= 'string' or name == '' or #name > 40 then return false, 'name is required (1-40 characters)' end
    if not finite(multiplier) or multiplier < 0 or multiplier > 10 then
        return false, 'multiplier must be a number from 0 to 10'
    end

    -- The same ask again on the same car (a turbo's, ten times a second): update the multiplier and the product,
    -- skipping the registry's whole pass (about 3 KB an ask).
    local same = power.entity == entity and powers[powerReg:keyOf(owner, name)]
    if same and same.owner == owner and same.entity == entity then
        same.mult = multiplier
        powerApply()
        return true
    end

    -- A different car: the old asks go first, while the old car is still current; the last one going forgets
    -- the current car, which must not be the new one.
    if power.entity ~= entity then
        local stale = {}
        for _, p in pairs(powers) do
            if p.entity ~= entity then stale[#stale + 1] = p end
        end
        for _, p in ipairs(stale) do powerReg:remove(p.owner, p.name) end
        power.entity = entity
    end

    local ok, why = powerReg:add(owner, name, { owner = owner, name = name, entity = entity, mult = multiplier })
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end

--- Take your ask off, whatever car it is on.
---@return boolean removed
function VehicleHandling.clearPower(name, owner)
    if powers[powerReg:keyOf(owner, name)] == nil then return false end
    return (powerReg:remove(owner, name))
end

exports('SetVehiclePower', function(vehicle, name, multiplier)
    -- /whipcost: the work alone.
    local cost = WhipCost.start()
    local ok, why = VehicleHandling.setPower(vehicle, name, multiplier, Registry.caller())
    WhipCost.stop('vehicle power: SetVehiclePower (the work, without the crossing)', cost)
    return ok, why
end)
exports('ClearVehiclePower', function(name) return VehicleHandling.clearPower(name, Registry.caller()) end)

-- The car died or was deleted: forget it, its layers and its engine asks (release writes nothing to a dead handle).
CreateThread(function()
    while true do
        Wait(1000)
        if tuned.entity and not DoesEntityExist(tuned.entity) then VehicleHandling.release() end
        if power.entity and not DoesEntityExist(power.entity) then
            local all = {}
            for _, p in pairs(powers) do all[#all + 1] = p end
            for _, p in ipairs(all) do powerReg:remove(p.owner, p.name) end
        end
    end
end)

-- A stopped resource's layers come off through the registry's sweep (onRemove, above). whip_core
-- stopping is not swept: it puts the car back here.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then VehicleHandling.release() end
end)
