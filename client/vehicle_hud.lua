-- Vehicle dial: what the 3D rev dial shows (rpm, speed, gear, four lights; aircraft instruments, boat anchor).
-- The dial is read off the car fifteen times a second and sent on its own path; the gauges around it are
-- server stats sent by SendVehicleHud (client/vehicles.lua). A gauge change rides in the dial's next message
-- (Vehicles.takeHudCarry). Showing and hiding stays with client/vehicles.lua; with the HUD off (/vehiclehud)
-- this file reads and sends nothing.

-- Settings, read once

--- Config with the gaps filled in, read into locals for the loop.
local CFG = Config.VehicleHud or {}
local UNITS, RPM_MAX, REDLINE, RPM_BY_CLASS, RPM_BY_MODEL, RPM_ELECTRIC, IDLE_RPM, IDLE_MEASURED

--- Vehicle classes by the names config.lua uses (GetVehicleClass's numbers).
local CLASS_NAMES = {
    [0] = 'compacts', [1] = 'sedans', [2] = 'suvs', [3] = 'coupes', [4] = 'muscle', [5] = 'sportsclassics',
    [6] = 'sports', [7] = 'super', [8] = 'motorcycles', [9] = 'offroad', [10] = 'industrial', [11] = 'utility',
    [12] = 'vans', [13] = 'cycles', [14] = 'boats', [15] = 'helicopters', [16] = 'planes', [17] = 'service',
    [18] = 'emergency', [19] = 'military', [20] = 'commercial', [21] = 'trains', [22] = 'openwheel',
}

--- Vehicles with no dial (bicycles, trains): nothing is read on them.
local NO_DIAL = { [13] = true, [21] = true }

--- Dial kind: helicopters and planes get flight instruments; boats read engine power 0 to 100% with F / N / R
--- and the anchor light; everything else is a car.
local KIND = { [14] = 'boat', [15] = 'air', [16] = 'air' }

local ATTITUDE, BANK_SIGN, DASH_SKINS
local DIAL_ON = true   -- false: the player chose no dial (Settings → Server): none shown, nothing read

-- Each player's own choice (client/player_prefs.lua: custom dials, whip's, or none); Config.VehicleHud is the default.
PlayerPrefs.define({
    key = 'dial.style', group = 'Vehicles', type = 'choice', label = 'Vehicle dial',
    help = 'Each car\'s own dashboard look, whip\'s dial on every car, or no dial at all (no speed, revs or fuel on screen).',
    options = { { value = 'custom', label = 'Each car\'s own' }, { value = 'whip', label = 'whip\'s dial' },
                { value = 'none', label = 'No dial' } },
    default = function() return (Config.VehicleHud or {}).dashSkins ~= false and 'custom' or 'whip' end,
})
PlayerPrefs.define({
    key = 'dial.speedUnit', group = 'Vehicles', type = 'choice', label = 'Speed unit',
    help = 'What the dial shows your speed in.',
    options = { { value = 'mph', label = 'mph' }, { value = 'kmh', label = 'km/h' } },
    default = function() return (Config.VehicleHud or {}).speedUnit == 'kmh' and 'kmh' or 'mph' end,
})
PlayerPrefs.define({
    key = 'dial.horizon', group = 'Vehicles', type = 'choice', label = 'Aircraft horizon',
    help = 'How the dial shows a helicopter or plane\'s pitch and roll.',
    options = { { value = 'ball', label = '3D ball' }, { value = 'flat', label = 'Flat disc' } },
    default = function() return (Config.VehicleHud or {}).attitude == 'flat' and 'flat' or 'ball' end,
})

local function readHudConfig()
    UNITS        = PlayerPrefs.get('dial.speedUnit') == 'kmh' and 'kmh' or 'mph'
    ATTITUDE     = PlayerPrefs.get('dial.horizon') == 'flat' and 'flat' or 'ball'
    local style  = PlayerPrefs.get('dial.style')
    DASH_SKINS   = style == 'custom'   -- cars wear their own GTA dashboard's look on the dial
    DIAL_ON      = style ~= 'none'
    BANK_SIGN    = CFG.flipBank == true and -1 or 1
    RPM_MAX      = tonumber(CFG.rpmMax) or 8
    REDLINE      = tonumber(CFG.redline) or 0.87
    RPM_ELECTRIC = tonumber(CFG.rpmElectric) or 20
    -- Where the needle rests at idle (thousands), the same for every engine; idleMeasured uses each engine's own.
    IDLE_RPM      = tonumber(CFG.idleRpm)
    IDLE_MEASURED = CFG.idleMeasured == true or IDLE_RPM == nil
    RPM_BY_CLASS = type(CFG.rpmByClass) == 'table' and CFG.rpmByClass or {}
    -- by model HASH, from names: the lookup per vehicle is then one table read
    RPM_BY_MODEL = {}
    for name, max in pairs(type(CFG.rpmByModel) == 'table' and CFG.rpmByModel or {}) do
        if type(name) == 'string' and tonumber(max) then RPM_BY_MODEL[GetHashKey(name)] = tonumber(max) end
    end
end
readHudConfig()

--- Measured rev ranges, data/rpm_by_model.lua: { idle, limiter } in thousands per spawn name, and a top per class.
--- Used for the idle and for class tops when config.lua leaves a class out. Loaded in an empty environment as
--- plain data; a missing or broken file leaves the config's numbers.
local MEASURED, MEASURED_CLASS = {}, {}
do
    local src = LoadResourceFile(GetCurrentResourceName(), 'data/rpm_by_model.lua')
    local chunk = src and load(src, '@data/rpm_by_model.lua', 't', {})
    local ok, t = false, nil
    if chunk then ok, t = pcall(chunk) end
    if ok and type(t) == 'table' then
        for name, r in pairs(type(t.models) == 'table' and t.models or {}) do
            local idle, limiter = type(r) == 'table' and tonumber(r[1]), type(r) == 'table' and tonumber(r[2])
            if type(name) == 'string' and idle and limiter and limiter > idle then
                MEASURED[GetHashKey(name)] = { idle, limiter }
            end
        end
        for class, max in pairs(type(t.classMax) == 'table' and t.classMax or {}) do
            if type(class) == 'string' and tonumber(max) then MEASURED_CLASS[class] = tonumber(max) end
        end
    else
        print('^3[whip_core] data/rpm_by_model.lua did not load: the rev dial uses config.lua\'s ranges only^7')
    end
end

--- Dial skins: data/dash_skins.lua is { [spawn name] = skin id }, keyed by the vehicle's own model (its
--- dashboard), not its engine. A vehicle not in it keeps the default dial. Read as data like rpm_by_model.lua.
local DASH_SKIN = {}   -- [model hash] = skin id (html/js/vehicle_hud/skins3d.js)
do
    local src = LoadResourceFile(GetCurrentResourceName(), 'data/dash_skins.lua')
    local chunk = src and load(src, '@data/dash_skins.lua', 't', {})
    local ok, t = false, nil
    if chunk then ok, t = pcall(chunk) end
    if ok and type(t) == 'table' then
        for name, id in pairs(t) do
            if type(name) == 'string' and type(id) == 'string' then DASH_SKIN[GetHashKey(name)] = id end
        end
    else
        print('^3[whip_core] data/dash_skins.lua did not load: every vehicle keeps the dial as designed^7')
    end
end

--- Where idle sits on the dial when nothing measured says: ~11%.
local IDLE_SHARE = 0.113

-- The engine a vehicle's revs come from
-- The rev range goes by the engine and its class. A vehicle's engine is its own model unless a resource says
-- otherwise with SetVehicleRevRange (below); electric engines run to rpmElectric.

--- [entity] = { engine = hash, class = n } or { max = k, idle = k|nil }. Per client; written only through
--- revReg (below), which keeps who set each one.
local _revSet = {}

--- [model hash] = is that engine electric? (_GET_IS_VEHICLE_ELECTRIC, build 3258+, asked once per model;
--- a build without it answers through the pcall: not electric.)
local _electric = {}
local function isElectric(hash)
    local e = _electric[hash]
    if e == nil then
        local ok, r = pcall(Citizen.InvokeNative, 0x1FCB07FE230B6639, hash, Citizen.ReturnResultAnyway())
        e = ok and (r == true or r == 1)                       -- a BOOL native answers 1 or false here
        _electric[hash] = e
    end
    return e
end

--- A vehicle's rev range: dial top in thousands of rpm, where the red zone starts, and the idle.
--- GetVehicleCurrentRpm runs 0.2 at idle to 1.0 at the limiter for every engine, so the range comes from the
--- engine (its own, or the one SetVehicleRevRange says it carries), first match wins:
---   1. config.lua's rpmByModel for the engine's model;
---   2. rpmElectric, for an electric engine;
---   3. config.lua's rpmByClass, then the measured class top, then rpmMax.
--- Idle: 0 for an electric; else config.lua's idleRpm, or the measured idle with idleMeasured; else ~11%.
--- A resource can also give a range outright ({ max, idle }).
---@param veh number
---@return number maxRpm  thousands, 2..20 (the dial's range)
---@return number redline thousands
---@return number idle    thousands: where GTA's 0.2 lands on the dial
local function revRange(veh)
    local set = _revSet[veh]
    local chosenIdle = not IDLE_MEASURED and IDLE_RPM or nil
    if set and set.max then
        local max = math.max(2.0, math.min(20.0, set.max))
        return max, max * REDLINE, math.min(set.idle or chosenIdle or max * IDLE_SHARE, max * 0.5)
    end
    local engine = set and set.engine or GetEntityModel(veh)
    local class = CLASS_NAMES[set and set.class or GetVehicleClass(veh)]
    local electric = isElectric(engine)
    local max = RPM_BY_MODEL[engine] or (electric and RPM_ELECTRIC)
        or tonumber(RPM_BY_CLASS[class]) or MEASURED_CLASS[class] or RPM_MAX
    max = math.max(2.0, math.min(20.0, max))
    local idle = electric and 0 or chosenIdle or (MEASURED[engine] and MEASURED[engine][1]) or max * IDLE_SHARE
    return max, max * REDLINE, math.min(idle, max * 0.5)
end

-- Cadence

--- How often the dial is read while seated, in ms. 66 = four frames at 60 fps (67 would take five).
--- Slower shows the needle's easing; faster costs NUI messages, which are the cost, not the natives.
local DIAL_TICK_MS = 66

--- How often to check whether the player got into a car, while on foot or the HUD is off.
local IDLE_TICK_MS = 250

--- How far the rpm (0..1) must move from the last sent reading before it is sent again (noise floor; keep 1-2%).
local RPM_DEADBAND = 0.015

--- The limiter: crossing this either way is always sent, so the limiter effects start and stop regardless of the
--- deadband. 0.985 is the first quantised reading inside the dial's limiter (raw ~0.981).
local RPM_LIMITER = 0.985

--- An aircraft's pitch, roll and altitude steps (degrees, metres): sent when they move past these, not on the
--- rpm deadband; the page eases between readings.
local ANGLE_STEP, ALT_STEP = 0.25, 0.3

--- The natives, by hash: _DOES_VEHICLE_HAVE_LANDING_GEAR, GET_LANDING_GEAR_STATE, IS_BOAT_ANCHORED.
local HAS_LANDING_GEAR, LANDING_GEAR_STATE, BOAT_ANCHORED = 0xE43701C36CAFF1A4, 0x9B0F3DCA3DB0F4CD, 0xB0AD1238A709B1A2

-- Reading the car

--- A game yes/no as a boolean. A BOOL native answers 1 or false, never true, so `== true` would read every answer as no.
local function yes(v) return v == true or v == 1 end

--- Is this vehicle actually going backwards? `gear == 0` misses a slow reverse (the native says 1) and also
--- means engine off, so velocity relative to the vehicle is checked too, with a deadband for hill roll.
---@param veh number
---@param gear number
---@return boolean
local function IsReversing(veh, gear)
    if GetEntitySpeedVector(veh, true).y < -0.5 then return true end
    return gear == 0 and yes(GetIsVehicleEngineRunning(veh))
end

--- The gear as the dial shows it: a number, R, or N (stopped with the handbrake on, or the engine off).
local function GearLabel(veh, gear, speedKmh, handbrake)
    if IsReversing(veh, gear) then return 'R' end
    if (handbrake and speedKmh < 0.5) or gear == 0 then return 'N' end
    return gear
end

--- 'off', 'low' or 'high', from GetVehicleLightsState (its first value is whether the call worked).
local function LightsOf(veh)
    local _, on, high = GetVehicleLightsState(veh)
    if on ~= 1 and on ~= true then return 'off' end
    return (high == 1 or high == true) and 'high' or 'low'
end

--- Landing gear for the gear light: 'down' (green), 'moving' (red), 'up' or 'none' (grey).
--- GET_LANDING_GEAR_STATE: 0 deployed, 1 retracting, 3 deploying, 4 retracted, 5 broken (shows red).
local function LandingGearOf(veh)
    if not yes(Citizen.InvokeNative(HAS_LANDING_GEAR, veh, Citizen.ReturnResultAnyway())) then return 'none' end
    local g = Citizen.InvokeNative(LANDING_GEAR_STATE, veh, Citizen.ResultAsInteger())
    if g == 0 then return 'down' end
    if g == 4 then return 'up' end
    return 'moving'
end

--- A boat's shift lever as the dial shows it, from which way the hull is moving: F, N or R.
local function BoatGear(veh)
    local ahead = GetEntitySpeedVector(veh, true).y
    return ahead > 0.5 and 'F' or ahead < -0.5 and 'R' or 'N'
end

--- Is a boat's propeller out of the water with the throttle held? The engine revs to its top but GTA's boat rpm
--- follows hull speed, so while this holds the page shows full power (html/js/vehicle-dial.js).
--- The propeller is the 'prop_1' bone, else the bottom of the stern, against the water height there; a hull clear
--- of the water counts too. Held PROP_HOLD_MS after it goes back in to avoid flicker. Needs the engine running and
--- throttle held.
local PROP_HOLD_MS  = 250
local PROP_THROTTLE = 0.3
local propVeh, propBone, propStern = 0, -1, nil   -- the boat these were looked up for
local propOutAt = -1                               -- when the propeller was last seen out (game ms)

local function BoatPropOut(veh, running, now)
    if veh ~= propVeh then
        propVeh, propOutAt = veh, -1
        propBone = GetEntityBoneIndexByName(veh, 'prop_1')
        propStern = GetModelDimensions(GetEntityModel(veh))   -- its first answer: the box's minimum corner
    end
    ---@cast propStern -nil   -- set above for this boat
    if running and math.abs(GetVehicleThrottleOffset(veh)) >= PROP_THROTTLE then
        local out = not yes(IsEntityInWater(veh))
        if not out then
            local p = propBone ~= -1 and GetWorldPositionOfEntityBone(veh, propBone)
                or GetOffsetFromEntityInWorldCoords(veh, 0.0, propStern.y, propStern.z)
            local found, water = GetWaterHeight(p.x, p.y, p.z + 10.0)
            out = not yes(found) or p.z > water
        end
        if out then propOutAt = now end
    end
    return propOutAt >= 0 and now - propOutAt < PROP_HOLD_MS
end

-- Change detection

--- What the NUI was last told. Sent only on change.
local _last = {}

--- Forget it, so the next read is sent unconditionally.
local function ResetDials()
    _last = {}
end

--- Round to a step before comparing: an idling engine's rpm wobbles in the far decimals forever.
local function Quantise(value, step)
    return math.floor(value / step + 0.5) * step
end

-- The loop

--- The dial payload, allocated once and refilled on every send. `hud` is set only when a gauge change rides along.
local _dialMsg = {
    action = 'updateVehicleDials',
    rpm = 0.0, speed = 0, gear = 'N', eng = false, lights = 'off', locked = false, dmg = false,
    launch = false,   -- first gear, or the handbrake held: the needle may bounce off the limiter (hud.js)
    -- aircraft (kind 'air'): degrees, metres above sea level, the landing gear; boats (kind 'boat'): the anchor
    -- and freeRev (BoatPropOut). Only the current kind's are kept up to date; the page reads by kind.
    pitch = 0.0, roll = 0.0, alt = 0.0, gearState = 'none', anchored = false, freeRev = false,
}

local function SendDialConfig()
    SendNUIMessage({ action = 'vehicleHudConfig', units = UNITS, attitude = ATTITUDE, skins = DASH_SKINS })
end

--- On getting into a vehicle: its range, dial kind (car, air, boat), whether it gets a dial, and its skin
--- (DASH_SKIN; false: none).
local function SendDialRange(veh)
    local max, redline, idle = revRange(veh)
    local class = GetVehicleClass(veh)
    local kind = KIND[class] or 'car'
    SendNUIMessage({ action = 'vehicleDialRange', maxRpm = max, redline = redline, idle = idle,
        dial = DIAL_ON and not NO_DIAL[class], kind = kind,
        skin = kind ~= 'air' and DASH_SKIN[GetEntityModel(veh)] or false })
end

--- A changed engine on the player's car reaches the dial at once (the loop sends ranges only on getting in).
local function rangeChanged(entity)
    if Vehicles.hudOn() and GetVehiclePedIsIn(PlayerPedId(), false) == entity then SendDialRange(entity) end
end

--- Who set a vehicle's range, on the registry rule (shared/registry.lua): another running resource is refused, a
--- stopped resource's settings go. Any change reaches the dial of the player's car.
local revReg = Registry.new('vehicleRevRange', {
    label    = 'rev range',
    store    = _revSet,
    onAdd    = function(entity) rangeChanged(entity) end,
    onRemove = function(entity) rangeChanged(entity) end,
})

--- Drop dead cars from _revSet now and then.
local _revSets = 0
local function pruneRevSet()
    _revSets = _revSets + 1
    if _revSets % 64 ~= 0 then return end
    local gone = {}
    for entity in pairs(_revSet) do
        if not DoesEntityExist(entity) then gone[#gone + 1] = entity end
    end
    for _, entity in ipairs(gone) do revReg:remove(revReg:ownerOf(entity) --[[@as string]], entity) end   -- (held, so owned)
end

--- Where a vehicle's rev dial comes from, on this client.
---   engine   a model name: the vehicle carries that model's engine (class, electric, rpmByModel);
---            { max = thousands, idle = thousands|nil }: exactly that range;
---            nil: the vehicle's own engine again.
--- The setting belongs to the resource that made it: another is refused while it runs; a stopped resource's
--- settings are dropped.
---@param vehicle number|WhipVehicleRef
---@param engine string|{ max: number, idle?: number }|nil
---@return boolean ok
---@return string|nil why
exports('SetVehicleRevRange', function(vehicle, engine)
    local owner = Registry.caller()
    local entity = Vehicles.refEntity(vehicle)
    -- Clearing works on a car that just went (onLost); setting needs one that is there. Only your own setting is cleared.
    if engine == nil and type(entity) == 'number' and revReg:get(entity) ~= nil then
        local ok, why = revReg:remove(owner, entity)
        if not ok then return false, why end
        return true
    end
    if type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'no such vehicle'
    end
    if engine == nil then return true end   -- nothing was set: it is on its own engine already

    local entry
    if type(engine) == 'string' then
        local hash = GetHashKey(engine)
        if engine == '' or #engine > 40 or not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
            return false, ('"%s" is not a vehicle model'):format(engine)
        end
        entry = { engine = hash, class = GetVehicleClassFromName(hash) }
    elseif type(engine) == 'table' then
        local max, idle = tonumber(engine.max), tonumber(engine.idle)
        if not max or max ~= max or max < 2 or max > 20 then return false, 'max must be 2 to 20 (thousand rpm)' end
        if engine.idle ~= nil and (not idle or idle ~= idle or idle < 0 or idle >= max) then
            return false, 'idle must be 0 or more and under max (thousand rpm)'
        end
        entry = { max = max, idle = idle }
    else
        return false, 'engine must be a model name, { max, idle } or nil'
    end

    pruneRevSet()
    local ok, why = revReg:add(owner, entity, entry)
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end)

--- Is this vehicle's engine electric (its own, or the one SetVehicleRevRange says it carries)? False for a
--- vehicle that is not here, and on a game build without the flag.
---@param vehicle number|WhipVehicleRef
---@return boolean
exports('IsVehicleElectric', function(vehicle)
    local entity = Vehicles.refEntity(vehicle)
    if type(entity) ~= 'number' or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false
    end
    local set = _revSet[entity]
    return isElectric(set and set.engine or GetEntityModel(entity)) == true
end)

-- A car its gearbox is not moving (a recorded drive): GTA's gear says nothing, so the gear is worked out from speed.

local GEAR_BACK = 0.85   -- worked out: a gear changed up to is left this far under the speed it was changed up at

--- The speed (m/s) each gear tops out at, from the gear ratios: [gear] = speed, every gear but the top. Empty for
--- a car with one gear, or a game without the natives.
local function gearLimits(veh)
    if type(GetVehicleGearRatio) ~= 'function' or type(GetVehicleHighGear) ~= 'function' then return {} end
    local high = GetVehicleHighGear(veh)
    if type(high) ~= 'number' or high < 2 then return {} end
    local top, last = GetVehicleModelEstimatedMaxSpeed(GetEntityModel(veh)), GetVehicleGearRatio(veh, high)
    if type(top) ~= 'number' or type(last) ~= 'number' or last <= 0 then return {} end
    local out = {}
    for g = 1, high - 1 do
        local r = GetVehicleGearRatio(veh, g)
        if type(r) ~= 'number' or r <= 0 then return {} end
        out[g] = top * last / r
    end
    return out
end

--- The gear its speed puts a car in: 1 and up. `keep` is the caller's per-car table (gear limits, current gear)
--- so it does not flick between two gears.
function Vehicles.speedGear(veh, keep)
    if not keep.limits then keep.limits = gearLimits(veh) end
    local speed, g = GetEntitySpeed(veh), keep.gear or 1
    while keep.limits[g] and speed > keep.limits[g] do g = g + 1 end
    while g > 1 and speed < keep.limits[g - 1] * GEAR_BACK do g = g - 1 end
    keep.gear = g
    return g
end

--- A car handed back to its gearbox: GTA's gear is set to this one. A car going backwards is left alone.
function Vehicles.gearboxTo(veh, gear)
    if not DoesEntityExist(veh) or GetEntitySpeedVector(veh, true).y < -0.5 then return end
    if type(SetVehicleCurrentGear) ~= 'function' or type(SetVehicleNextGear) ~= 'function' then return end
    if type(GetVehicleHighGear) == 'function' then gear = math.max(1, math.min(gear, GetVehicleHighGear(veh) or gear)) end
    SetVehicleNextGear(veh, gear)
    SetVehicleCurrentGear(veh, gear)
end

--- [entity] = the forward gear the dial shows, when a resource drives the gears itself. Reverse and N stay the
--- game's. Or 'speed', for a car a resource moves itself: worked out in _speedKeep.
local _gearSet, _speedKeep = {}, {}
local gearReg = Registry.new('vehicleDialGear', { label = 'dial gear', store = _gearSet,
    onRemove = function(entity) _speedKeep[entity] = nil end })

--- Show `gear` as the forward gear of this vehicle on the dial; nil: the game's gear again. Same registry rule
--- as SetVehicleRevRange. 'speed': you move the car, so the dial works the gear out from its speed.
---@param vehicle number|WhipVehicleRef
---@param gear integer|'speed'|nil  1 and up, or 'speed'
---@return boolean ok
---@return string|nil why
exports('SetVehicleDialGear', function(vehicle, gear)
    local owner = Registry.caller()
    local entity = Vehicles.refEntity(vehicle)
    if type(entity) ~= 'number' then return false, 'no such vehicle' end
    if gear == nil then
        local was = gearReg:get(entity)
        if was == nil then return true end
        local handBack = was == 'speed' and DoesEntityExist(entity) and Vehicles.dialGear(entity)
        local ok, why = gearReg:remove(owner, entity)
        if not ok then return false, why end
        if handBack then Vehicles.gearboxTo(entity, handBack) end
        return true
    end
    if gear ~= 'speed' then
        gear = tonumber(gear)
        if not gear or gear ~= math.floor(gear) or gear < 1 or gear > 20 then
            return false, "gear must be a whole number, 1 to 20, or 'speed'"
        end
    end
    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then return false, 'no such vehicle' end
    for other in pairs(_gearSet) do
        if not DoesEntityExist(other) then gearReg:remove(gearReg:ownerOf(other) --[[@as string]], other) end   -- (held, so owned)
    end
    local ok, why = gearReg:add(owner, entity, gear)
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    _speedKeep[entity] = nil   -- worked out afresh: the handle may be a deleted car's
    return true
end)

--- The gear the dial shows for a driven vehicle: SetVehicleDialGear's going forward, else the game's own.
function Vehicles.dialGear(veh)
    local set = _gearSet[veh]
    if set == 'speed' then
        local keep = _speedKeep[veh]
        if not keep then keep = {}; _speedKeep[veh] = keep end
        return Vehicles.speedGear(veh, keep)
    end
    local gear = GetVehicleCurrentGear(veh)
    if gear >= 1 and set then return set end
    return gear
end

-- Changed in /whip Settings: read again, and the dial told.
local function hudConfigChanged()
    readHudConfig()
    SendDialConfig()
    local veh = GetVehiclePedIsIn(PlayerPedId(), false)
    if veh ~= 0 and DoesEntityExist(veh) then
        ResetDials()          -- a dial switched back on is sent everything again, not only what moved
        SendDialRange(veh)
    end
end
Settings.onChange('VehicleHud', hudConfigChanged)
-- And the player's own choices (Settings → Server).
PlayerPrefs.onChange('dial.style', hudConfigChanged)
PlayerPrefs.onChange('dial.speedUnit', hudConfigChanged)
PlayerPrefs.onChange('dial.horizon', hudConfigChanged)

CreateThread(function()
    -- A self-gating loop: polling "am I in a car" cannot get stuck on a missed exit edge.
    local seatedIn = 0
    local seatedKind, noDial = 'car', false   -- the seated vehicle's dial (KIND), or none at all (NO_DIAL)

    while true do
        local cost = WhipCost.start()   -- /whipcost (lib/cost.lua); stopped in each branch below, before its Wait
        -- HUD off (/vehiclehud) reads as on foot; switched back on in a car counts as freshly seated.
        local veh =Vehicles.hudOn() and GetVehiclePedIsIn(PlayerPedId(), false) or 0
        local inVehicle = veh ~= 0 and DoesEntityExist(veh)

        -- Named for the profiler; a no-op while nothing records.
        ProfilerEnterScope('whip:vehicleDials')

        -- A different or freshly seated vehicle: range and kind first, everything sent fresh.
        if inVehicle and veh ~= seatedIn then
            seatedIn = veh
            local class = GetVehicleClass(veh)
            seatedKind, noDial = KIND[class] or 'car', NO_DIAL[class] == true
            ResetDials()
            SendDialRange(veh)
        end

        if inVehicle and not noDial and DIAL_ON then
            local running   = yes(GetIsVehicleEngineRunning(veh))
            local rpm       = running and Quantise(GetVehicleCurrentRpm(veh), 0.005) or 0.0
            local speed     = math.floor(GetEntitySpeed(veh) * 3.6 + 0.5)          -- km/h: the dial converts
            local handbrake = yes(GetVehicleHandbrake(veh))
            local rawGear   = TakePlayer.gearOn(veh) or Vehicles.dialGear(veh)      -- a recorded drive's while one plays
            local gear      = seatedKind == 'boat' and BoatGear(veh)                -- a boat's lever: F / N / R
                or GearLabel(veh, rawGear, speed, handbrake)
            -- The needle bounces off the limiter (`launch` on the page) in first gear always, and in other gears
            -- only with the handbrake held; otherwise only the outline flashes. Uses the game's gear, not the label.
            local launch    = seatedKind == 'car' and (rawGear == 1 or handbrake)
            local lights    = LightsOf(veh)
            local locked    = GetVehicleDoorLockStatus(veh) == 2                    -- whip's locked
            local damaged   = GetVehicleEngineHealth(veh) < 400.0

            -- Aircraft and boats: instruments quantised to the page's steps.
            local kindMoved = false
            if seatedKind == 'air' then
                local pitch = Quantise(GetEntityPitch(veh), ANGLE_STEP)
                local roll  = Quantise(GetEntityRoll(veh) * BANK_SIGN, ANGLE_STEP)
                local alt   = Quantise(GetEntityCoords(veh).z, ALT_STEP)
                local gs    = LandingGearOf(veh)
                kindMoved = pitch ~= _last.pitch or roll ~= _last.roll or alt ~= _last.alt or gs ~= _last.gearState
                _dialMsg.pitch, _dialMsg.roll, _dialMsg.alt, _dialMsg.gearState = pitch, roll, alt, gs
            elseif seatedKind == 'boat' then
                local anchored = yes(Citizen.InvokeNative(BOAT_ANCHORED, veh, Citizen.ReturnResultAnyway()))
                local freeRev = BoatPropOut(veh, running, GetGameTimer())
                kindMoved = anchored ~= _last.anchored or freeRev ~= _last.freeRev
                _dialMsg.anchored, _dialMsg.freeRev = anchored, freeRev
            end

            -- The deadband is measured against what was last sent. Crossing into the limiter always sends.
            -- Integers, strings and booleans are exact.
            local lastRpm  = _last.rpm
            local rpmMoved = lastRpm == nil or math.abs(rpm - lastRpm) >= RPM_DEADBAND
                or (rpm >= RPM_LIMITER) ~= (lastRpm >= RPM_LIMITER) or (rpm == 0) ~= (lastRpm == 0)

            local carry = Vehicles.takeHudCarry()

            -- Not gated on the dial being on screen, or values the page never received would be recorded as sent.
            -- The handbrake is not sent: it only decides the gear's N and the launch flag.
            if carry or rpmMoved or kindMoved or speed ~= _last.speed or gear ~= _last.gear or running ~= _last.eng
                or lights ~= _last.lights or locked ~= _last.locked or damaged ~= _last.dmg or launch ~= _last.launch then
                -- All recorded whenever any sends, since the payload carries all of them.
                _last.rpm, _last.speed, _last.gear, _last.eng = rpm, speed, gear, running
                _last.lights, _last.locked, _last.dmg, _last.launch = lights, locked, damaged, launch
                _last.pitch, _last.roll, _last.alt, _last.gearState = _dialMsg.pitch, _dialMsg.roll, _dialMsg.alt, _dialMsg.gearState
                _last.anchored, _last.freeRev = _dialMsg.anchored, _dialMsg.freeRev

                _dialMsg.rpm, _dialMsg.speed, _dialMsg.gear, _dialMsg.eng = rpm, speed, gear, running
                _dialMsg.lights, _dialMsg.locked, _dialMsg.dmg, _dialMsg.launch = lights, locked, damaged, launch
                _dialMsg.hud = carry   -- nil leaves it out (html/js/vehicle-dial.js hands it on)
                local sendCost = WhipCost.start()
                SendNUIMessage(_dialMsg)
                WhipCost.stop('vehicle dial: send to the page', sendCost)
            end

            WhipCost.stop('vehicle dial: read + send (in a vehicle)', cost)
            ProfilerExitScope()
            Wait(DIAL_TICK_MS)
        else
            -- On foot, HUD off, a bicycle or train, or no dial chosen: nothing is read or sent. Hiding is the
            -- exit handler's job (client/vehicles.lua).
            if not inVehicle and seatedIn ~= 0 then
                seatedIn = 0
                ResetDials()
            end

            -- A gauge change made just as the player got out is sent on its own, so the next car shows no stale gauge.
            local carry = Vehicles.takeHudCarry()
            if carry then SendNUIMessage(carry) end

            WhipCost.stop('vehicle dial: idle check (on foot)', cost)
            ProfilerExitScope()
            Wait(IDLE_TICK_MS)
        end
    end
end)

-- On whip_core:onReady and again at playerLoaded, for a page that missed the first.
AddEventHandler('whip_core:onReady', function(info)
    if type(info) == 'table' and info.reason ~= 'coreStarted' then return end
    SendDialConfig()
end)

RegisterNetEvent('whip_core:client:playerLoaded', function()
    SendDialConfig()
end)
