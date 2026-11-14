-- ============================================
-- GetVehicleProperties / SetVehicleProperties
-- Full capture/restore of all vehicle visual + performance state
-- ============================================
--
-- A LEAF. Natives in, a plain table out, and nothing else — no whip state, no cache, no statebag,
-- no event. That is the entire reason this is its own file: it was 217 lines sitting in the middle
-- of client/vehicles.lua, which is where anything vehicle-shaped ended up regardless of whether it
-- had anything to do with the rest.
--
-- It reads and writes ONE entity handle. It does not know what a vehicleId is, cannot tell an owned
-- car from a street car, and has no opinion about persistence — which is what makes it safe to call
-- from anywhere, and safe to move here without an accessor of any kind.
--
-- WHERE THE AUTHORITY LIVES, since this file has none. Nothing here is stored. A satellite that
-- wants an appearance to survive must hand it to the server with SetVehicleAppearance, because
-- only the server writes the database and a client describing a car can describe anything it
-- likes. See server/vehicles.lua's mergeClientProperties for what the server does with a report.

--- Read everything about how a vehicle currently looks.
---@param vehicle number|nil entity handle
---@return table props
function GetVehicleProperties(vehicle)
    if not vehicle or vehicle == 0 then return {} end

    local props = {}

    -- Identity
    props.model      = GetEntityModel(vehicle)
    props.plate      = GetVehicleNumberPlateText(vehicle)
    props.plateIndex = GetVehicleNumberPlateTextIndex(vehicle)

    -- Colors
    local primary, secondary = GetVehicleColours(vehicle)
    props.color1 = primary
    props.color2 = secondary

    local hasCustom1 = GetIsVehiclePrimaryColourCustom(vehicle)
    if hasCustom1 then
        local r, g, b = GetVehicleCustomPrimaryColour(vehicle)
        props.customColor1 = { r = r, g = g, b = b }
    end

    local hasCustom2 = GetIsVehicleSecondaryColourCustom(vehicle)
    if hasCustom2 then
        local r, g, b = GetVehicleCustomSecondaryColour(vehicle)
        props.customColor2 = { r = r, g = g, b = b }
    end

    props.pearlescent, props.wheelColor = GetVehicleExtraColours(vehicle)

    -- Mods (slots 0-49)
    --
    -- TOGGLE SLOTS ARE SKIPPED, and that is a fix rather than an omission. 18, 20 and 22 are the
    -- turbo, the tyre smoke and the xenons — toggles, whose real value is read with IsToggleModOn
    -- and reported below as booleans. GetVehicleMod on a toggle returns -1 whether it is on or off.
    --
    -- Writing them here as well described one thing twice, and the two copies disagreed: a car with
    -- a turbo stored `turbo = true` AND `mods["18"] = -1`. Vehicle #31413 in the live database was
    -- exactly that. Applying survived it — SetVehicleProperties skips negative mod values and runs
    -- the toggles afterwards — but every client report then listed both `turbo` and `18` as
    -- performance mods the server had to hold back, for one part.
    SetVehicleModKit(vehicle, 0)
    props.mods = {}
    for i = 0, 49 do
        if i ~= 18 and i ~= 20 and i ~= 22 then
            props.mods[tostring(i)] = GetVehicleMod(vehicle, i)
        end
    end
    props.wheelType = GetVehicleWheelType(vehicle)

    -- Toggleable mods — the ONLY place these three are described.
    -- Every on/off here is written as a real boolean: a BOOL native answers 1 or false, never true, and the table
    -- is compared with true and handed back to SetVehicleProperties, which takes only booleans for extras.
    props.turbo        = IsToggleModOn(vehicle, 18) and true or false
    props.smokeEnabled = IsToggleModOn(vehicle, 20) and true or false
    props.xenon        = IsToggleModOn(vehicle, 22) and true or false

    -- Tyre smoke color
    local sr, sg, sb = GetVehicleTyreSmokeColor(vehicle)
    props.tyreSmoke = { r = sr, g = sg, b = sb }

    -- Neon lights
    local nr, ng, nb = GetVehicleNeonLightsColour(vehicle)
    props.neonColor = { r = nr, g = ng, b = nb }
    props.neonEnabled = {
        IsVehicleNeonLightEnabled(vehicle, 0) and true or false,
        IsVehicleNeonLightEnabled(vehicle, 1) and true or false,
        IsVehicleNeonLightEnabled(vehicle, 2) and true or false,
        IsVehicleNeonLightEnabled(vehicle, 3) and true or false,
    }

    -- Window tint
    props.windowTint = GetVehicleWindowTint(vehicle)

    -- Livery
    props.livery = GetVehicleLivery(vehicle)

    -- Extras (1-14)
    props.extras = {}
    for i = 1, 14 do
        if DoesExtraExist(vehicle, i) then
            props.extras[tostring(i)] = IsVehicleExtraTurnedOn(vehicle, i) and true or false
        end
    end

    -- Dirt level
    props.dirtLevel = GetVehicleDirtLevel(vehicle)

    -- Headlight color (xenon)
    props.headlightColor = GetVehicleHeadlightsColour(vehicle)

    -- Interior + dashboard color
    props.interiorColor = GetVehicleInteriorColour(vehicle)
    props.dashboardColor = GetVehicleDashboardColour(vehicle)

    return props
end

-- ============================================
-- Extras, without GTA's repair
-- ============================================
--
-- SWITCHING AN EXTRA REPAIRS THE CAR (SET_VEHICLE_EXTRA): its body, its engine, its doors and tyres, its fuel and
-- dirt with them. The game's switch to stop it (SetVehicleAutoRepairDisabled) is said to stop extras changing at all.
-- So an extra is only switched when it is not already as asked, and the car's wear is read first and put back after:
-- a light bar is never a free repair (Josh, 1 Nov: the Extras shelf in Whiplash). The dents themselves (deformation)
-- cannot be put back; whip keeps health, doors and tyres, not dents.

local EXTRA_LAST = 14                              -- extras 1-14: what whip saves (GetVehicleProperties)
local WEAR_TYRES = { 0, 1, 2, 3, 4, 5, 45, 47 }    -- GTA's tyre numbers (client/vehicle_damage.lua's TYRES)
local WEAR_DOORS = 7                               -- doors 0-7

local function readWear(veh)
    local w = {
        engine = GetVehicleEngineHealth(veh), body = GetVehicleBodyHealth(veh), tank = GetVehiclePetrolTankHealth(veh),
        fuel = GetVehicleFuelLevel(veh), dirt = GetVehicleDirtLevel(veh), doors = {}, rim = {}, flat = {},
    }
    for door = 0, WEAR_DOORS do
        if GetIsDoorValid(veh, door) and IsVehicleDoorDamaged(veh, door) then w.doors[#w.doors + 1] = door end
    end
    for _, tyre in ipairs(WEAR_TYRES) do
        if IsVehicleTyreBurst(veh, tyre, true) then w.rim[#w.rim + 1] = tyre
        elseif IsVehicleTyreBurst(veh, tyre, false) then w.flat[#w.flat + 1] = tyre end
    end
    return w
end

local function putWearBack(veh, w)
    SetVehicleEngineHealth(veh, w.engine + 0.0)
    SetVehicleBodyHealth(veh, w.body + 0.0)
    SetVehiclePetrolTankHealth(veh, w.tank + 0.0)
    SetVehicleFuelLevel(veh, w.fuel + 0.0)
    SetVehicleDirtLevel(veh, w.dirt + 0.0)
    for _, door in ipairs(w.doors) do
        if not IsVehicleDoorDamaged(veh, door) then SetVehicleDoorBroken(veh, door, true) end   -- true: gone
    end
    for _, tyre in ipairs(w.rim) do SetVehicleTyreBurst(veh, tyre, true, 1000.0) end
    for _, tyre in ipairs(w.flat) do SetVehicleTyreBurst(veh, tyre, false, 1000.0) end
end

--- Switch a car's extras, keeping its wear (above). `extras` is { [n or "n"] = true (on) | false (off) }, n 1-14
--- (1 / 0 are taken too: a BOOL native's answer); one the model does not have, or already as asked, is left alone.
--- Answers how many were switched.
---@param veh number|nil
---@param extras table
---@return integer
local function setExtras(veh, extras)
    if not veh or veh == 0 or not DoesEntityExist(veh) or type(extras) ~= 'table' then return 0 end
    local switch = {}
    for k, on in pairs(extras) do
        local n = math.tointeger(tonumber(k))
        if on == 1 or on == 0 then on = on == 1 end
        -- IsVehicleExtraTurnedOn answers 1 or false: as a boolean, or every extra that is on is switched again
        -- (and repaired by it) each time
        if n and n >= 1 and n <= EXTRA_LAST and type(on) == 'boolean' and DoesExtraExist(veh, n)
            and (IsVehicleExtraTurnedOn(veh, n) and true or false) ~= on then
            switch[#switch + 1] = { n, on }
        end
    end
    if #switch == 0 then return 0 end
    local wear = readWear(veh)
    for _, s in ipairs(switch) do SetVehicleExtra(veh, s[1], not s[2]) end   -- disable: false is on
    putWearBack(veh, wear)
    return #switch
end

--- Apply an appearance to a vehicle entity.
---@param vehicle number entity handle
---@param props table
function SetVehicleProperties(vehicle, props)
    if not vehicle or vehicle == 0 or not props then return end

    SetVehicleModKit(vehicle, 0)

    -- Colors. Each native sets a pair: a half the props leave out keeps what the car has. (Filled with 0 it was
    -- black: a primary saved alone blacked the secondary, and a wheel colour saved with no pearl was never put on.)
    if props.color1 ~= nil or props.color2 ~= nil then
        local primary, secondary = GetVehicleColours(vehicle)
        SetVehicleColours(vehicle, props.color1 or primary, props.color2 or secondary)
    end
    if props.customColor1 then
        local c = props.customColor1
        SetVehicleCustomPrimaryColour(vehicle, c.r or 0, c.g or 0, c.b or 0)
    end
    if props.customColor2 then
        local c = props.customColor2
        SetVehicleCustomSecondaryColour(vehicle, c.r or 0, c.g or 0, c.b or 0)
    end
    if props.pearlescent ~= nil or props.wheelColor ~= nil then
        local pearl, wheel = GetVehicleExtraColours(vehicle)
        SetVehicleExtraColours(vehicle, props.pearlescent or pearl, props.wheelColor or wheel)
    end

    -- Plate
    if props.plate then SetVehicleNumberPlateText(vehicle, props.plate) end
    if props.plateIndex then SetVehicleNumberPlateTextIndex(vehicle, props.plateIndex) end

    -- Wheel type (must be set before wheel mods)
    if props.wheelType ~= nil then SetVehicleWheelType(vehicle, props.wheelType) end

    -- Mods. A stored -1 is STOCK and is applied as stock: skipping it left whatever part was fitted
    -- (a preview in whip_autos, say) on the car, so "put it back as it was saved" did not.
    if props.mods then
        for i = 0, 49 do
            local v = props.mods[tostring(i)]
            if v ~= nil then
                if v >= 0 then
                    SetVehicleMod(vehicle, i, v, false)
                else
                    RemoveVehicleMod(vehicle, i)
                end
            end
        end
    end

    -- Toggle mods
    if props.turbo ~= nil then ToggleVehicleMod(vehicle, 18, props.turbo) end
    if props.xenon ~= nil then ToggleVehicleMod(vehicle, 22, props.xenon) end
    if props.smokeEnabled ~= nil then ToggleVehicleMod(vehicle, 20, props.smokeEnabled) end

    -- Tyre smoke
    if props.tyreSmoke then
        SetVehicleTyreSmokeColor(vehicle, props.tyreSmoke.r or 255, props.tyreSmoke.g or 255, props.tyreSmoke.b or 255)
    end

    -- Neon
    if props.neonColor then
        SetVehicleNeonLightsColour(vehicle, props.neonColor.r or 255, props.neonColor.g or 255, props.neonColor.b or 0)
    end
    if props.neonEnabled then
        for i = 0, 3 do
            SetVehicleNeonLightEnabled(vehicle, i, props.neonEnabled[i + 1] or false)
        end
    end

    -- Window tint
    if props.windowTint ~= nil then SetVehicleWindowTint(vehicle, props.windowTint) end

    -- Livery
    if props.livery ~= nil and props.livery >= 0 then SetVehicleLivery(vehicle, props.livery) end

    -- Extras: only those not already as saved, and without GTA's repair (setExtras). Every push of a car's look
    -- used to set them all, which repaired any car with extras each time.
    if type(props.extras) == 'table' then setExtras(vehicle, props.extras) end

    -- Dirt
    if props.dirtLevel ~= nil then SetVehicleDirtLevel(vehicle, props.dirtLevel) end

    -- Headlight color (xenon). Xenons stored with no colour (saved before whip_autos sold colours) are
    -- the stock one, 255 (left alone, a restore would keep whatever colour was last previewed).
    if props.headlightColor ~= nil then
        SetVehicleHeadlightsColour(vehicle, props.headlightColor)
    elseif props.xenon ~= nil then
        SetVehicleHeadlightsColour(vehicle, 255)
    end

    -- Interior + dashboard color
    if props.interiorColor ~= nil then SetVehicleInteriorColour(vehicle, props.interiorColor) end
    if props.dashboardColor ~= nil then SetVehicleDashboardColour(vehicle, props.dashboardColor) end
end

-- ============================================
-- Exports
-- ============================================

--- Read everything about how a vehicle looks, as a plain table.
---
--- Mods 0-49, colours, wheels, tint, neon, livery, extras. The same shape SetVehicleProperties
--- takes, so capture-then-restore round-trips.
---
--- USE IT TO REMEMBER, NOT TO STORE. A satellite that wants an appearance to persist must hand
--- it to the server — exports.whip_core:SetVehicleAppearance — because only the server writes
--- the database, and a client saying what a car looks like is a client that can say anything.
---@param vehicle number|table  a vehicleId, or a vehicle reference — the entity as { entity = veh }
---@return table
exports('GetVehicleProperties', function(vehicle)
    return GetVehicleProperties(Vehicles.refEntity(vehicle))
end)

local _saidEntityHint = {}   -- [resource] = true once told (SetVehicleProperties, below)

--- Apply an appearance to a vehicle, here and now.
---
--- LOCAL AND UNSAVED, BUT NOT UNSEEN. Vehicle mods are part of GTA's networked vehicle state, so
--- this changes the car for every player who can see it — provided this client holds network
--- control of the entity. Without control the natives silently do nothing, so take it first (in a thread):
---
---     if Whip.call('TakeVehicleControl', { entity = veh }) then
---         exports.whip_core:SetVehicleProperties({ entity = veh }, props)
---     end
---
--- Nothing here is stored. The car reverts to what the server has the next time its appearance
--- is pushed — which is what makes this safe to use for previewing something a player has not
--- bought yet, and why exports.whip_core:RestoreVehicleAppearance exists on the server.
---@param vehicle number|table  a vehicleId, or a vehicle reference — the entity as { entity = veh }
---@param props table
---@return boolean ok, string|nil why
---
--- A bare number is a vehicleId. QBCore's and ox_lib's SetVehicleProperties take the entity there, so a number that
--- names no car here but is an entity is refused with that hint, said once per resource in F8.
exports('SetVehicleProperties', function(vehicle, props)
    if type(props) ~= 'table' then return false, 'props is a table, as GetVehicleProperties answers' end
    local veh = Vehicles.refEntity(vehicle)
    if not veh or veh == 0 or not DoesEntityExist(veh) then
        if type(vehicle) == 'number' and DoesEntityExist(vehicle) then
            local res = GetInvokingResource() or '?'
            if not _saidEntityHint[res] then
                _saidEntityHint[res] = true
                print(('^3[whip_core] %s: SetVehicleProperties(%d, ...): that number is an entity handle, and a bare number is a vehicleId in whip. Pass { entity = veh }^7')
                    :format(res, vehicle))
            end
            return false, 'that number is an entity handle, not a vehicleId: pass { entity = veh }'
        end
        return false, 'no such vehicle here'
    end
    SetVehicleProperties(veh, props)
    return true
end)

--- Switch a vehicle's extras (the parts GTA turns on and off: light bars, roof racks, covers), keeping its damage.
---
--- GTA REPAIRS A CAR WHEN AN EXTRA IS SWITCHED: its health, doors, tyres, fuel and dirt. This reads them first and
--- puts them back, and switches only the extras not already as asked. Use it, not SetVehicleExtra, or switching a
--- part is a free repair. Local and unsaved like SetVehicleProperties (control first); stored with the car through
--- SetVehicleAppearance's `extras`.
---
---     if Whip.call('TakeVehicleControl', { entity = veh }) then
---         Whip.call('SetVehicleExtras', { entity = veh }, { [3] = true, [5] = false })
---     end
---
---@param vehicle number|table  a vehicleId, or a vehicle reference — the entity as { entity = veh }
---@param extras table  { [n] = true (on) | false (off) }, n 1-14
---@return integer switched  how many changed (one the model lacks, or already as asked, is left alone)
exports('SetVehicleExtras', function(vehicle, extras)
    return setExtras(Vehicles.refEntity(vehicle), extras)
end)
