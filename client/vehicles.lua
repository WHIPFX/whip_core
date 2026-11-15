-- Vehicles (client): keys and ignition, lock/unlock, trunk and glovebox, the garage, the vehicle HUD,
-- and reporting appearance to the server. Ignition, HUD, appearance and enter/exit share local state.

--- The client half of Vehicles (the server has its own, in another Lua state).
Vehicles = {}

-- Defined further down, declared here so earlier code reaches the same local.
local refreshVehicleHud
local requestVehicleDoor

local vehicleStoragePending = false

--- Bumped once per vehicle-storage request, so a safety timeout can tell whether the request it
--- was armed for is still the one in flight: the timers are never cancelled, so a timer captures the
--- sequence it was armed at and stands down if anything has asked since. The newest request is the
--- only one that can time itself out.
local storageReqSeq = 0

--- Identity of one storage of one vehicle, for the optimistic-open memory in client/inventory.lua.
--- The same string as the server's storeId for it ('vehicle:8:trunk').
---
--- Keyed on the vehicle id, and both sides of an open build it from the same number: the press
--- records it as the panel the player is waiting for, and the reply names the panel it carries.
--- Inventory.confirmPanel refuses a reply whose key is not the one awaited, so both sides must spell
--- the car the same way: the id stamped on the entity (Vehicles.idByEntity).
---@param vehicleId number|nil
---@param storageType string
---@return string|nil
local function vehicleStorageKey(vehicleId, storageType)
    local id = tonumber(vehicleId)
    if not id or id == 0 then return nil end
    -- tointeger: Lua 5.4 prints 8 and 8.0 differently.
    return ('vehicle:%s:%s'):format(tostring(math.tointeger(id) or id), storageType)
end

--- Which compartment is drawn on spec right now, if any.
---
--- Inventory.activeVehicleStorage is only set when the SERVER confirms (it carries the server's
--- resolved vehicleId), so for the length of an optimistic open the seat reconcile would see no
--- glovebox while one is on screen, and request another.
local optimisticStorageType = nil

--- Draw a vehicle storage from memory before asking the server, if we have seen it before.
---
--- Both compartments go through here so they cannot drift apart: the boot and the glovebox are
--- the same panel with different contents.
--- No id (an unstamped car) means no key: nothing is drawn and the reply cold-opens.
---@param vehicleId number|nil
---@param storageType string
local function drawVehicleStorage(vehicleId, storageType)
    local key = vehicleStorageKey(vehicleId, storageType)
    if not key then return end

    if Inventory.drawRememberedPanel({ key = key, open = 'openInventoryWithContainer' }) then
        optimisticStorageType = storageType
    end
end

local trunkDoorEntity       = nil   -- Entity whose door 5 (trunk) Vehicles.openTrunk opened, to shut when the panel closes

local vehicleDefs      = {}    -- [vehicleId] = def (from server sync, owner only)
local vehicleKeys      = {}    -- [vehicleId] = plateText (keys the player has)
-- The entity carries its own id: see Vehicles.idByEntity and getEntityForVehicleId below.

-- Current vehicle tracking
local currentVehicle    = nil   -- entity handle while in vehicle
local currentVehicleId  = nil   -- vehicleId (set on enter for owners, set by ignitionState for non-owners)

-- Live secondary-panel swap (ground <-> glovebox while the inventory stays open). State-driven:
-- the vehicle thread asks "am I seated" every tick, so any cause of a seat change works.
local swapPending      = false  -- a swap-in request is in flight
local swapDenied       = false  -- server refused for THIS seating; do not ask again until we move
local lastSwapRequest  = 0      -- GetGameTimer() of the last request, for the debounce

--- Logs what this client decided about a storage request, with the guard flags.
---@param msg string
local function StorageTrace(msg)
    if Config.LogVehicleStorage == false then return end
    print(('[whip_core:vehstore] %s  [pending=%s swapPending=%s swapDenied=%s optimistic=%s active=%s]')
        :format(msg, tostring(vehicleStoragePending), tostring(swapPending), tostring(swapDenied),
                tostring(optimisticStorageType), tostring(Inventory.activeVehicleStorage ~= nil)))
end

-- Must clear the 500ms rate limit on openVehicleStorage (keyed on the event name, and a limited call gets no reply).
local SWAP_DEBOUNCE_MS = 600

-- Ignition state: this is its only writer.

local ignitionHasKey    = {}    -- [vehicleId] = true/false
local ignitionUnhacked  = {}    -- [vehicleId] = true/false (unhacked key in ignition)
local engineOn          = false -- manual engine state for current vehicle
local ignitionNotified  = false -- prevent spamming "no key" notification

--- The key may still be on its way after taking the wheel; until it lands an engine press is held, not refused.
---   ignitionComing[vehicleId] = until when a press is held
---   heldIgnition              = { vId, want }, run the moment the key state lands
local KEY_WAIT_MS       = 4000
local ignitionComing    = {}
local heldIgnition      = nil
local RequestIgnition           -- defined with the bindings below; the key-state handler runs a held press

--- Whether the ignition has anything to do, and the car it would do it to. Derived on the 200ms occupant tick.
local ignitionActive    = false -- driving a vehicle whip knows the id of
local ignitionVeh       = nil   -- that vehicle's entity, so the bindings need not ask for it again

--- A bicycle has no ignition and no glovebox. Uses the game's class (13), so add-on bicycles count.
---@param veh number|nil
---@return boolean
local function isBicycle(veh)
    return veh ~= nil and veh ~= 0 and GetVehicleClass(veh) == 13
end

--- Which trunks and gloveboxes are off, by class and by model (model wins). From the server (Vehicles.storageWire).
local storageOff = { classes = {}, models = {} }

RegisterNetEvent('whip_core:client:vehicleStorageSync', function(wire)
    local classes, models = {}, {}
    for _, c in ipairs(type(wire) == 'table' and wire.classes or {}) do
        local class = tonumber(c.class)
        if class then classes[class] = { trunk = c.trunk, glovebox = c.glovebox } end
    end
    for _, m in ipairs(type(wire) == 'table' and wire.models or {}) do
        if type(m.model) == 'string' then models[GetHashKey(m.model)] = { trunk = m.trunk, glovebox = m.glovebox } end
    end
    storageOff = { classes = classes, models = models }
end)

--- Has this car a trunk (or glovebox) at all?
---@param veh number
---@param kind 'trunk'|'glovebox'
---@return boolean
local function hasStorage(veh, kind)
    local m = storageOff.models[GetEntityModel(veh)]
    if m and m[kind] ~= nil then return m[kind] end
    local c = storageOff.classes[GetVehicleClass(veh)]
    return not (c and c[kind] == false)
end

--- What the engine and driveable natives were last told, per entity, so they are only told again on a change.
local _ignitionAsserted = { entity = nil, engine = nil, undriveable = nil, at = 0 }

--- How often the state is re-asserted even when nothing has changed, to undo outside changes.
local IGNITION_REASSERT_MS = 500

--- The car a recorded drive had at the last look (AssertIgnition): the ignition picks up from it when the drive is over.
local ignitionTakeCar = nil

--- The throttle is held off while the engine is off: GTA starts an engine itself on accelerate, and the car
--- stays driveable so it can roll. Accelerate (71) is held off for the driver; brake/reverse (72) only while
--- the car is all but stopped. Aircraft use 87 (up) and 88 (down, only while all but still). Bicycles are never held.
local ENGINE_OFF_REVERSE_SPEED = 1.0   -- m/s: below this, brake / reverse is held off too
local throttleVeh = nil                -- the car whose throttle is held, or nil
local throttleAir = false              -- it is a plane or a helicopter (87/88 as well)

local function engineOffFrame()
    if throttleVeh and GetEntitySpeed(throttleVeh) < ENGINE_OFF_REVERSE_SPEED then
        DisableControlAction(0, 72, true)
        if throttleAir then DisableControlAction(0, 88, true) end
    end
end

--- Hold the throttle off for `veh`, or let it go (nil). Only acts on a change.
---@param veh number|nil
local function HoldThrottle(veh)
    if veh and IsThisModelABicycle(GetEntityModel(veh)) then veh = nil end
    if veh == throttleVeh then return end
    throttleVeh = veh
    if veh then
        local model = GetEntityModel(veh)
        throttleAir = (IsThisModelAPlane(model) or IsThisModelAHeli(model)) and true or false
        ControlBlocks.hold('engineOff', { controls = throttleAir and { 71, 87 } or { 71 } }, engineOffFrame)
    else
        ControlBlocks.release('engineOff')
    end
end

--- Set the engine and driveable state, skipping natives that would change nothing. The only writer,
--- so `_ignitionAsserted` stays true to the car.
---@param veh number|nil
---@param engine boolean
---@param undriveable boolean
local function SetIgnitionState(veh, engine, undriveable)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    -- A recorded drive (client/actors.lua) owns the engine until it is over.
    if TakePlayer.on(veh) then return end

    local now   = GetGameTimer()
    local stale = (now - _ignitionAsserted.at) >= IGNITION_REASSERT_MS

    if _ignitionAsserted.entity ~= veh then
        _ignitionAsserted.entity      = veh
        _ignitionAsserted.engine      = nil
        _ignitionAsserted.undriveable = nil
        stale = true
    end

    if stale or _ignitionAsserted.engine ~= engine then
        _ignitionAsserted.engine = engine

        -- `instantly` is false when starting (starter turns over) and true when stopping.
        SetVehicleEngineOn(veh, engine, not engine, true)
    end

    if stale or _ignitionAsserted.undriveable ~= undriveable then
        _ignitionAsserted.undriveable = undriveable
        SetVehicleUndriveable(veh, undriveable)
    end

    if stale then _ignitionAsserted.at = now end

    -- The throttle follows the engine (HoldThrottle), for the driver only.
    if engine then
        HoldThrottle(nil)
    elseif throttleVeh ~= veh and GetPedInVehicleSeat(veh, -1) == PlayerPedId() then
        HoldThrottle(veh)
    end
end

-- Garage state: the definitions the blips and the bay labels read.
local garageDefs        = {}    -- synced from server (replaces Config.Garages)
local garageBlips       = {}    -- [key] = blip handle

function Vehicles.getGarageDefs() return garageDefs end

-- Vehicle HUD: client-owned gauges only (those the server cannot own); the rest come from the server's stat registry.
-- `value` is a Lua-side reader with no arguments (1 or 0 for an iconOnly gauge). Never send it to the NUI (see HudDefForNui).
local CLIENT_HUD_DEFS = {}

--- Gauges registered on the server, as last sent. Filled by whip_core:client:vehicleHudDefs.
local serverHudDefs = {}

--- The gauges the capsule is currently drawing: server-registered stats, then client-owned ones.
local activeHudDefs = {}

--- A def as the NUI may see it: an explicit field list (a `value` function cannot be encoded).
local function HudDefForNui(def)
    return {
        name          = def.name,
        max           = def.max,
        -- `min`, `default` and `label` travel for the garage list's meters; `default` shows fuel on a never-driven car.
        min           = def.min,
        default       = def.default,
        label         = def.label,
        icon          = def.icon,
        iconCritical  = def.iconCritical,
        color         = def.color,
        order         = def.order,
        iconOnly      = def.iconOnly,
        heartbeat     = def.heartbeat,
        hideWhenEmpty = def.hideWhenEmpty,
        noCritical    = def.noCritical,
        showAboveZero = def.showAboveZero,
        showWhenPresent = def.showWhenPresent,
        -- How the value reads (server/vehicle_stats.lua normDisplay): 14 psi, 92°C, or E and F at the gauge's ends.
        -- Plain data, checked on the server.
        display       = def.display,
    }
end

--- What the NUI was last told, so SendVehicleHud can send only on change.
local _lastHudSent = {}
local _lastHudIcons = {}   -- [statName] = the icon a rule last gave it (SetVehicleStatIcon), or false for its own

-- Client-driven gauge values: a provider replaces the number on this client's own dial only (for a value the
-- client computes in real time, such as boost). Presence and other players' views still use the replicated value.
local _statDisplay = {}   -- [statName] = { fn = provider }

-- Registration rule (shared/registry.lua): a reading belongs to whoever set it first; swept when they stop.
local _statDisplays = Registry.new('VehicleStatDisplay', {
    label    = 'vehicle stat display',
    store    = _statDisplay,
    onRemove = function() refreshVehicleHud() end,
})

--- Ask the provider for a stat, if one is registered. Global so client/vehicle_stats.lua can call it.
---@param name string
---@param entity number|nil
---@param replicated number|nil  what the statebag says, passed through so a provider can defer
---@return number|nil
local function readVehicleStatDisplay(name, entity, replicated)
    -- A watcher's own reading first (its last whileHeld result, vehicle_stats.lua).
    local reading = Vehicles.statReading and Vehicles.statReading(name, entity)
    if reading ~= nil then return reading end

    local entry = _statDisplay[name]
    if not entry then return nil end

    -- pcall, no type check: an exported provider is callable but not a 'function'; a failing satellite must not break the capsule.
    local ok, value = pcall(entry.fn, entity, replicated)
    if not ok then
        print(('[whip_core:vehhud] display provider for "%s" errored: %s'):format(name, tostring(value)))
        return nil
    end

    return tonumber(value)
end

--- Whether a stat's gauge is drawn on a car, by a resource's rule (SetVehicleStatShown), e.g. no fuel gauge on an
--- electric car. [statName] = { fn = function(entity) -> false to hide }.
local _statShown = {}
local _statShowns = Registry.new('VehicleStatShown', {
    label    = 'vehicle stat shown',
    store    = _statShown,
    onRemove = function() refreshVehicleHud() end,
})

--- Is this rule's answer kept for this car? Asked once a car, keyed by entity and model so a reused handle is asked
--- again; a rule set again is a new entry.
local function keptFor(entry, entity)
    return entry.carEntity == entity and entry.carModel == GetEntityModel(entity)
end
local function keepFor(entry, entity)
    entry.carEntity, entry.carModel = entity, GetEntityModel(entity)
end

--- Is this stat's gauge hidden on this car (its rule answered false)? Asked once a car.
local function statHiddenOn(name, entity)
    local entry = entity and _statShown[name]
    if not entry then return false end
    if keptFor(entry, entity) then return entry.hidden end
    local ok, shown = pcall(entry.fn, entity)
    if not ok then
        print(('[whip_core:vehhud] the shown rule for "%s" errored: %s'):format(name, tostring(shown)))
        shown = nil
    end
    keepFor(entry, entity)
    entry.hidden = shown == false
    return entry.hidden
end

--- A stat's gauge icon on a car, by a resource's rule (SetVehicleStatIcon).
--- [statName] = { fn = function(entity) -> icon | nil }.
local _statIcon = {}
local _statIcons = Registry.new('VehicleStatIcon', {
    label    = 'vehicle stat icon',
    store    = _statIcon,
    onRemove = function() refreshVehicleHud() end,
})

--- This stat's icon on this car by its rule, or nil for its own. Asked once a car (keptFor, above).
local function statIconOn(name, entity)
    local entry = entity and _statIcon[name]
    if not entry then return nil end
    if keptFor(entry, entity) then return entry.icon end
    local ok, icon = pcall(entry.fn, entity)
    if not ok then
        print(('[whip_core:vehhud] the icon rule for "%s" errored: %s'):format(name, tostring(icon)))
        icon = nil
    end
    keepFor(entry, entity)
    entry.icon = (type(icon) == 'string' and icon ~= '') and icon or nil
    return entry.icon
end

--- Does anything provide a local reading for this stat? Read by the vehicle-stat watcher.
---@param name string
---@return boolean
function Vehicles.hasStatDisplay(name)
    return _statDisplay[name] ~= nil
end

--- Forget what was last sent, so the next SendVehicleHud is unconditional.
local function ResetVehicleHud()
    _lastHudSent = {}
    _lastHudIcons = {}
end

--- What the NUI was last sent, so an identical re-send can be skipped (see SendVehicleHudDefs).
local _lastHudDefsSig = nil

--- Rebuild the merged list and hand it to the NUI. Re-runnable: runs on character load and when the server's registry changes.
local function SendVehicleHudDefs()
    activeHudDefs = {}

    for _, def in ipairs(serverHudDefs) do
        activeHudDefs[#activeHudDefs + 1] = def
    end
    for _, def in ipairs(CLIENT_HUD_DEFS) do
        activeHudDefs[#activeHudDefs + 1] = def
    end

    -- registerVehicleHud renders in array order, so sort by `order` here.
    table.sort(activeHudDefs, function(a, b) return (a.order or 99) < (b.order or 99) end)

    local payload = {}
    for i, def in ipairs(activeHudDefs) do
        payload[i] = HudDefForNui(def)
    end

    -- Only a real change goes to the NUI, since a send rebuilds its gauges. Encoding fails soft: no signature means send.
    local okSig, sig = pcall(json.encode, payload)
    if okSig and sig == _lastHudDefsSig then return end
    _lastHudDefsSig = okSig and sig or nil

    SendNUIMessage({ action = 'registerVehicleHud', stats = payload })

    -- The NUI rebuilt its gauges empty: forget what was last sent.
    ResetVehicleHud()
end

RegisterNetEvent('whip_core:client:vehicleHudDefs', function(defs)
    serverHudDefs = defs or {}
    SendVehicleHudDefs()
end)

--- The gauge definitions keyed by stat name (label, colour, range). Only stats with a `hud` block appear, so callers must cope with a miss.
---@return table  [name] = hud def
function Vehicles.hudDefsByName()
    local byName = {}
    for _, d in ipairs(activeHudDefs) do byName[d.name] = d end
    return byName
end

--- The engine state this client last told the server about. Reset on every vehicle change.
local lastReportedEngine = nil

--- Tell the server the engine went on or off. On change only (AssertIgnition re-states it every tick).
--- The server checks the driver and the key, so this is a request.
---@param on boolean
local function ReportEngine(on)
    if not currentVehicleId then return end
    if lastReportedEngine == on then return end
    if not currentVehicle or not DoesEntityExist(currentVehicle) then return end
    if GetPedInVehicleSeat(currentVehicle, -1) ~= PlayerPedId() then return end

    lastReportedEngine = on
    TriggerServerEvent('whip_core:server:setVehicleEngine', currentVehicleId, on)
end

--- Tell the car what its ignition should be right now. Runs on the 200ms occupant tick and directly when the key
--- table moves. Reads engineOn and the key table; writes engineOn only to correct it when the key has gone.
--- Is a resource holding this car's engine off (server/vehicle_stats.lua HoldVehicleEngine: out of fuel, a flat
--- battery...)? Its reason, off the car's state bag, or nil.
---@return string|nil
local function EngineHold(veh)
    if not veh or veh == 0 then return nil end
    -- Read by the bag's name directly: this runs on every occupant tick.
    local bag = NetworkGetEntityIsNetworked(veh) and ('entity:%d'):format(NetworkGetNetworkIdFromEntity(veh))
        or ('localEntity:%d'):format(veh)
    local why = GetStateBagValue(bag, VEHICLE_ENGINE_HOLD_KEY)
    return type(why) == 'string' and why or nil
end

--- The hold's reason said once a car, not every tick (reset when there is none).
local holdNotified = nil

---@param veh number
---@param vId number|nil
local function AssertIgnition(veh, vId)
    if not veh or veh == 0 then return end

    -- A recorded drive has the car (SetIgnitionState); when over, the engine stays as the drive left it.
    if TakePlayer.on(veh) then
        ignitionTakeCar = veh
        return
    end
    if ignitionTakeCar == veh then
        ignitionTakeCar = nil
        local running = GetIsVehicleEngineRunning(veh)
        engineOn = running == true or running == 1
        ReportEngine(engineOn)
    end

    -- A bicycle: no ignition, rideable as soon as it is sat on.
    if isBicycle(veh) then
        SetIgnitionState(veh, false, false)
        return
    end

    if not ignitionHasKey[vId] then
        -- No key: engine off and undriveable. Also the path a removed key arrives on.
        SetIgnitionState(veh, false, true)
        engineOn = false
        -- Change-gated inside, so re-asserting costs nothing when it has not moved.
        ReportEngine(false)
    elseif engineOn and EngineHold(veh) then
        -- Held off (out of fuel...): stopped but still driveable, so it can be pushed. Said once.
        engineOn = false
        SetIgnitionState(veh, false, false)
        ReportEngine(false)
        local why = EngineHold(veh) --[[@as string]]   -- the elseif just found it
        if holdNotified ~= why then
            holdNotified = why
            UI.Notify(why, 'error')
        end
    elseif engineOn then
        SetIgnitionState(veh, true, false)
    else
        -- Key in, engine off. Driveable, so the car can still roll.
        SetIgnitionState(veh, false, false)
        if not EngineHold(veh) then holdNotified = nil end
    end
end

--- The two stat blocks for the car we sit in, as last delivered by the change handlers (so the HUD rarely reads the
--- statebag). Keyed by entity.
local _hudBlocks = { entity = nil, stats = nil, live = nil }

--- The statebag name of the car we are in, so the change handler can compare strings.
local _hudBagName = nil

--- Read both blocks and cache them: the only place the HUD reads the statebags. Runs on a cold cache and on the
--- one-second occupant tick (a real read, so a missed change handler cannot leave a stale dial).
local function SeedHudBlocks(entity)
    _hudBlocks.entity = entity
    if entity and DoesEntityExist(entity) then
        -- One accessor for the pair (one Entity(...).state wrapper). `true`: the bag itself, never these copies.
        _hudBlocks.stats, _hudBlocks.live = GetVehicleStatBlocks(entity, true)
        -- Built once: the entity only changes when the player does.
        _hudBagName      = ('entity:%d'):format(NetworkGetNetworkIdFromEntity(entity))
    else
        _hudBlocks.stats, _hudBlocks.live = nil, nil
        _hudBagName = nil
    end
end

--- The two stat blocks of the car this player sits in, as the HUD keeps them, for GetVehicleStatBlocks
--- (client/vehicle_stats.lua). Shared tables, read only. `held` is false for any other car.
---@param entity number
---@return table|nil stats
---@return table|nil live
---@return boolean held
function Vehicles.heldStatBlocks(entity)
    if not entity or entity ~= currentVehicle or _hudBlocks.entity ~= entity then return nil, nil, false end
    local stats, live = _hudBlocks.stats, _hudBlocks.live
    return type(stats) == 'table' and stats or nil, type(live) == 'table' and live or nil, true
end

--- The capsule payload and its `missing` list, allocated once and refilled on every repaint (safe: SendNUIMessage
--- serialises before it returns).
local _hudPayload = { action = 'updateVehicleHud' }
local _hudMissing = {}
_hudPayload.missing = _hudMissing
local _hudIcons = {}         -- [statName] = icon: a gauge whose rule gives it another icon on this car (SetVehicleStatIcon)
_hudPayload.icons = _hudIcons

--- True while a repaint is mid-flight. See the guard at the top of SendVehicleHud.
local _hudSending = false

--- A changed capsule waiting to ride on the dials' next message (client/vehicle_hud.lua takes it with
--- Vehicles.takeHudCarry). Only the frequent paths carry; getting in, a withdrawn provider and the safety net send at once.
local _hudCarry = nil

--- The whole vehicle HUD switched off with /vehiclehud.
local _hudOff = false

--- Push current values for every registered gauge. Sends only on change, so it is safe to call from anywhere.
---@param carry boolean|nil  hand a change to the dials' next message rather than sending it now
local function SendVehicleHud(carry)
    if _hudOff then return end
    -- Re-entrancy guard: satellite code called below may ask for a repaint, which would wipe the shared payload.
    if _hudSending then return end
    _hudSending = true

    -- Profiled here so every path that paints the panel is counted.
    ProfilerEnterScope('whip:vehicleHudRepaint')
    local cost = WhipCost.start()

    -- From the cache, kept current by the change handlers.
    local stats, live = nil, nil
    if currentVehicle and DoesEntityExist(currentVehicle) then
        if _hudBlocks.entity ~= currentVehicle then SeedHudBlocks(currentVehicle) end
        stats = _hudBlocks.stats

        -- The live key carries the current value of `live` stats; presence still comes from `stats` below.
        live = _hudBlocks.live
    end

    -- Wiped, not rebuilt: everything but `action`, `missing` and `icons` goes, since the message is a complete
    -- snapshot and a leftover key would say a removed stat is still fitted.
    local payload, changed = _hudPayload, false
    for k in pairs(payload) do
        if k ~= 'action' and k ~= 'missing' and k ~= 'icons' then payload[k] = nil end
    end
    for i = #_hudMissing, 1, -1 do _hudMissing[i] = nil end
    for k in pairs(_hudIcons) do _hudIcons[k] = nil end

    for _, def in ipairs(activeHudDefs) do
        local v
        local stored = type(stats) == 'table' and stats[def.name] or nil

        if def.value then
            v = def.value()                                   -- gauge the server does not own at all
        else
            -- An absent key means "at its registered default". A live stat's value comes off the live key;
            -- `stored` is used below for presence, not drawing.
            v = (live and live[def.name] ~= nil) and live[def.name] or stored
            if v == nil then v = def.default end

            -- A local reading, only for a stat the car carries: a provider changes the number, never whether there is a dial.
            if stored ~= nil then
                local reading = readVehicleStatDisplay(def.name, currentVehicle, v)
                if reading ~= nil then v = reading end
            end
        end

        -- A presence gauge (showWhenPresent) on a car without the stat is left out, which hides it in the NUI.
        -- `def.value` is exempt; a display provider is not. A shown rule saying no hides it the same way.
        if (def.showWhenPresent and not def.value and stored == nil)
            or (not def.value and statHiddenOn(def.name, currentVehicle)) then
            payload.missing[#payload.missing + 1] = def.name

            -- `false` marks "not carried" in the change detector, so a stat appearing or vanishing repaints.
            if _lastHudSent[def.name] ~= false then changed = true end
            _lastHudSent[def.name] = false

        elseif v ~= nil then
            payload[def.name] = v
            if _lastHudSent[def.name] ~= v then changed = true end
            _lastHudSent[def.name] = v

            -- Its icon on this car, when a rule gives it another (else the stat's own: left out)
            local icon = statIconOn(def.name, currentVehicle)
            if icon then _hudIcons[def.name] = icon end
            if (_lastHudIcons[def.name] or false) ~= (icon or false) then changed = true end
            _lastHudIcons[def.name] = icon or false
        end
    end

    if changed then
        -- Only while seated: the dials' loop sends nothing on foot, it only flushes (vehicle_hud.lua).
        if carry and currentVehicle then
            _hudCarry = payload
        else
            _hudCarry = nil
            SendNUIMessage(payload)
        end
    end

    WhipCost.stop('vehicle HUD: repaint', cost)
    ProfilerExitScope()

    -- Cleared last, on every exit path, so a throwing provider cannot leave the capsule unable to repaint.
    _hudSending = false
end

--- Floor on how often the capsule is repainted (ten a second). Raising it shows as steps unless the bars get a CSS
--- transition sized to the cadence (--vh-smooth, tied to DIAL_TICK_MS).
local HUD_REPAINT_MIN_MS = 100

--- When the capsule was last painted, by any path: one clock for the watcher tick and the live statebag.
local _hudPaintedAt = 0

--- Repaint the capsule now, unconditionally (getting into a car, a provider withdrawn, the safety net).
function refreshVehicleHud()
    _hudPaintedAt = GetGameTimer()
    SendVehicleHud()
end

--- Repaint the capsule unless it was just painted. For the high-rate paths; the next paint draws what arrived.
---@return boolean painted
function Vehicles.refreshHudThrottled()
    local now = GetGameTimer()
    if (now - _hudPaintedAt) < HUD_REPAINT_MIN_MS then return false end

    _hudPaintedAt = now
    SendVehicleHud(true)   -- rides on the dials' next message (_hudCarry)
    return true
end

--- The capsule change waiting for the dials' next message, or nil; taking it clears it.
---@return table|nil payload
function Vehicles.takeHudCarry()
    local p = _hudCarry
    _hudCarry = nil
    return p
end

-- /vehiclehud: switches the whole vehicle HUD off and on, for performance tests. Not saved; only affects the player's own screen.

--- Is the vehicle HUD on?
---@return boolean
function Vehicles.hudOn()
    return not _hudOff
end

RegisterCommand('vehiclehud', function(_, args)
    local want = args[1] and tostring(args[1]):lower()
    local off
    if want == 'off' then off = true elseif want == 'on' then off = false else off = not _hudOff end
    if off ~= _hudOff then
        _hudOff = off
        _hudCarry = nil
        SendNUIMessage({ action = 'vehicleHudEnabled', on = not off })
        if not off then
            -- The page's gauges start from nothing: everything goes again (the dial's loop re-sends its own).
            ResetVehicleHud()
            if currentVehicle then refreshVehicleHud() end
        end
    end
    UI.Notify(_hudOff and 'Vehicle HUD: off (/vehiclehud to turn it back on)' or 'Vehicle HUD: on', 'info')
end, false)

-- Chat help. On load rather than at file scope: whip_chat starts after whip_core (see /loading's).
AddEventHandler('whip_core:player:loaded', function()
    TriggerEvent('chat:addSuggestion', '/vehiclehud', 'Turn the vehicle HUD off or on (for performance tests)', {
        { name = 'on|off', help = 'left out: switches it' },
    })
end)

--- Tells the server which vehicles this game has (GetAllVehicleModels, add-ons included), once a session, so a
--- nonexistent car cannot be bought or spawned (Vehicles.modelExists). Only names the server's check accepts go:
--- letters, digits, _ and -. Sent once the session has started, after add-on cars have streamed.
local SESSION_WAIT_MS = 120000
local modelsReported = false
AddEventHandler('whip_core:onReady', function(info)
    if type(info) ~= 'table' or info.reason ~= 'coreStarted' then return end
    if modelsReported or not GetAllVehicleModels then return end
    modelsReported = true
    CreateThread(function()
        local by = GetGameTimer() + SESSION_WAIT_MS
        while not NetworkIsSessionStarted() and GetGameTimer() < by do Wait(500) end
        if not NetworkIsSessionStarted() then modelsReported = false return end
        Wait(2000)
        local list, seen = {}, {}
        for _, raw in ipairs(GetAllVehicleModels() or {}) do
            local m = tostring(raw):lower()
            if #m <= 60 and m:match('^[%w_%-]+$') and not m:match('^%-?%d+$') and not seen[m] then
                seen[m] = true
                list[#list + 1] = m
                if #list >= 6000 then break end
            end
        end
        if #list == 0 then modelsReported = false return end
        -- Latent: about 10 KB, spread out while the world loads.
        TriggerLatentServerEvent('whip_core:server:vehicleModels', 50000, list)
    end)
end)

--- Let this client draw its own reading for a stat. The provider is called with `(entity, replicatedValue)` on each
--- repaint; return nil to defer to the replicated value. It does not write the stat or decide whether the gauge is drawn.
---
---     exports.whip_core:SetVehicleStatDisplay('boost', function(entity, replicated)
---         return liveBoost
---     end)
---@param name string
---@param fn fun(entity: number|nil, replicated: number|nil): number|nil
---@return boolean registered
---@return string|nil reason
exports('SetVehicleStatDisplay', function(name, fn)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' or fn == nil then
        return false, 'SetVehicleStatDisplay: a stat name and a provider are required'
    end
    local ok, why = _statDisplays:add(owner, name, { fn = fn })
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    return true
end)

--- Stop drawing a local reading for a stat. Only the resource that set the provider can clear it.
---@param name string
---@return boolean removed
---@return string|nil reason
exports('ClearVehicleStatDisplay', function(name)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' then return false, 'ClearVehicleStatDisplay: a stat name is required' end
    return _statDisplays:remove(owner, name)
end)

--- Whether a stat's gauge is drawn on a car: `fn(entity)` answers false to hide it (no fuel gauge on an electric car).
--- Asked as the capsule repaints; only this client's dial. One rule a stat, swept when its setter stops.
---
---     exports.whip_core:SetVehicleStatShown('fuel', function(entity) return not isElectric(entity) end)
---@param name string
---@param fn fun(entity: number): boolean
---@return boolean registered
---@return string|nil reason
exports('SetVehicleStatShown', function(name, fn)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' or fn == nil then
        return false, 'SetVehicleStatShown: a stat name and a rule are required'
    end
    local ok, why = _statShowns:add(owner, name, { fn = fn })
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    refreshVehicleHud()
    return true
end)

--- Every car shows the stat's gauge again (by its own rules). Only the resource that set the rule can clear it.
---@param name string
---@return boolean removed
---@return string|nil reason
exports('ClearVehicleStatShown', function(name)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' then return false, 'ClearVehicleStatShown: a stat name is required' end
    return _statShowns:remove(owner, name)
end)

--- A stat's gauge icon by car: `fn(entity)` answers the icon, or nil for the stat's own. An icon is one of the dial's
--- glyphs ('fuel', 'fuel_left', 'fuel_right', 'turbo', 'nitro', 'coolant', 'hack', 'weapon') or an SVG path in a 24x24
--- viewBox. Asked at most once a second. One rule a stat, swept when its setter stops.
---
---     exports.whip_core:SetVehicleStatIcon('fuel', function(entity) return sideOf(entity) and 'fuel_left' end)
---@param name string
---@param fn fun(entity: number): string|nil
---@return boolean registered
---@return string|nil reason
exports('SetVehicleStatIcon', function(name, fn)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' or fn == nil then
        return false, 'SetVehicleStatIcon: a stat name and a rule are required'
    end
    local ok, why = _statIcons:add(owner, name, { fn = fn })
    if not ok then return false, why --[[@as string]] end   -- a refusal's reason
    refreshVehicleHud()
    return true
end)

--- Every car draws the stat's own icon again. Only the resource that set the rule can clear it.
---@param name string
---@return boolean removed
---@return string|nil reason
exports('ClearVehicleStatIcon', function(name)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(name) ~= 'string' then return false, 'ClearVehicleStatIcon: a stat name is required' end
    return _statIcons:remove(owner, name)
end)

--- Repaint the moment a stat moves rather than waiting for the occupant tick. Only for the car this player sits in:
--- the bag name is compared as a string against one built on entry, which is cheaper than resolving the entity.
--- The tick stays for client-side `value()` gauges and the first paint after getting in.
---@param bagName string
---@param key string
---@param value any  the new block, already decoded for us
local function RepaintIfOurs(bagName, key, value)
    -- Both tests: `_hudBagName` is only rebuilt on seeding, so after a car swap it still names the old one.
    if not currentVehicle or bagName ~= _hudBagName then return end
    if _hudBlocks.entity ~= currentVehicle then return end

    -- The cache is filled even if the throttle drops the paint below.
    if key == VEHICLE_STATS_KEY then
        _hudBlocks.stats = value
    elseif key == VEHICLE_LIVE_KEY then
        _hudBlocks.live = value
    else
        return
    end

    -- Throttled, sharing its clock with the watcher tick. A passenger's only paint.
    Vehicles.refreshHudThrottled()
end

AddStateBagChangeHandler(VEHICLE_STATS_KEY, nil, RepaintIfOurs)

-- The live key as well, so live gauges repaint for passengers.
AddStateBagChangeHandler(VEHICLE_LIVE_KEY, nil, RepaintIfOurs)

-- On whip_core:onReady (every client file has run; re-fires after a core restart). The page may not be
-- listening yet, so the defs go again at playerLoaded.
AddEventHandler('whip_core:onReady', SendVehicleHudDefs)

RegisterNetEvent('whip_core:client:playerLoaded', function()
    SendVehicleHudDefs()
end)

-- Helpers

--- entity -> vehicleId, or `false` for an entity known to carry none (cached: most street cars have no id).
--- Kept current by the change handler below.
local _vehicleIdByEntity = {}

--- The NPC lock rule's bookkeeping (NpcLockNearby). [entity] = { at = GetGameTimer(), netId } for a car it could
--- not name yet; [entity] = true for a car the rule locked.
local _npcFirstSeen = {}
local _npcLocked = {}

--- [entity] = { [key] = fn(vehicleId) }: car blocks that came before the car's id (Vehicles.awaitBagId).
local _awaitingId = {}

--- Run `fn(vehicleId)` once this car's id is stamped, for a block (data, stats) that arrived before it. One wait per
--- car and key: asking again replaces it, `fn = nil` drops it. The id is handed over because its own key is not
--- stored yet while its handler runs.
---@param entity number
---@param key string  the statebag key whose block is waiting
---@param fn fun(vehicleId: number)|nil
function Vehicles.awaitBagId(entity, key, fn)
    local waiting = _awaitingId[entity]
    if fn == nil then
        if waiting then
            waiting[key] = nil
            if next(waiting) == nil then _awaitingId[entity] = nil end
        end
        return
    end
    if not waiting then waiting = {}; _awaitingId[entity] = waiting end
    waiting[key] = fn
end

-- The push half: a recycled entity handle gets the new car's id here. A bag arriving before its handle is read
-- lazily by Vehicles.idByEntity.
AddStateBagChangeHandler(VEHICLE_STATE_KEY, nil, function(bagName, _, value)
    local entity = GetEntityFromStateBagName(bagName)
    if not entity or entity == 0 then return end
    _vehicleIdByEntity[entity] = (type(value) == 'number') and value or false

    -- The blocks that were waiting for this id (Vehicles.awaitBagId).
    local waiting = type(value) == 'number' and _awaitingId[entity]
    if waiting then
        _awaitingId[entity] = nil
        for key, fn in pairs(waiting) do
            local ok, err = pcall(fn, value)
            if not ok then print(('[whip_core:vehicles] %s id wait errored: %s'):format(tostring(key), tostring(err))) end
        end
    end

    -- The NPC rule locked a whip car whose id arrived after its grace: ask the server to restore the real lock state.
    if type(value) == 'number' and _npcLocked[entity] then
        _npcLocked[entity] = nil
        TriggerServerEvent('whip_core:server:reassertVehicleLock', value)
    end
end)

--- Drop entries for cars that have gone. Slow on purpose: each is a DoesEntityExist call.
CreateThread(function()
    while true do
        Wait(30000)
        for entity in pairs(_vehicleIdByEntity) do
            if not DoesEntityExist(entity) then _vehicleIdByEntity[entity] = nil end
        end
        -- The NPC rule's two tables.
        for entity in pairs(_npcFirstSeen) do
            if not DoesEntityExist(entity) then _npcFirstSeen[entity] = nil end
        end
        for entity in pairs(_npcLocked) do
            if not DoesEntityExist(entity) then _npcLocked[entity] = nil end
        end
        -- A car that left before its id came has nothing left to wait for.
        for entity in pairs(_awaitingId) do
            if not DoesEntityExist(entity) then _awaitingId[entity] = nil end
        end
    end
end)

--- Resolve vehicleId from a vehicle entity: the id the server stamps on it, the same on every client.
---@param vehicleEntity number
---@return number|nil
function Vehicles.idByEntity(vehicleEntity)
    if not vehicleEntity or vehicleEntity == 0 then return nil end

    local cached = _vehicleIdByEntity[vehicleEntity]
    if cached ~= nil then return cached or nil end      -- false means "asked, has none"

    -- Cold: read once and remember.
    local id = Entity(vehicleEntity).state[VEHICLE_STATE_KEY]
    if type(id) ~= 'number' then
        _vehicleIdByEntity[vehicleEntity] = false
        return nil
    end

    _vehicleIdByEntity[vehicleEntity] = id
    return id
end

local _lastLookup = { vehicleId = nil, entity = nil }

--- Find the entity for a vehicleId among the vehicles streamed in around this client, or nil. Exported as GetVehicleEntity.
---@param vehicleId number
---@return number|nil entity
local function getEntityForVehicleId(vehicleId)
    if not vehicleId then return nil end
    if currentVehicleId == vehicleId and currentVehicle and DoesEntityExist(currentVehicle) then
        return currentVehicle
    end

    -- The last answer first, re-checked: an open boot asks for the same car five times a second.
    local last = _lastLookup
    if last.vehicleId == vehicleId and last.entity and DoesEntityExist(last.entity)
        and Vehicles.idByEntity(last.entity) == vehicleId then
        return last.entity
    end

    -- Through the cache: the first scan warms every streamed vehicle.
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if Vehicles.idByEntity(veh) == vehicleId then
            last.vehicleId, last.entity = vehicleId, veh
            return veh
        end
    end
    return nil
end

-- Vehicle references: every vehicle export takes one of
--     { id = vehicleId }   { entity = entity }   { plate = 'ABC123' }   { netId = netId }
-- A bare number is a vehicleId. A client only knows cars streamed in around it, so a far car answers nil.

--- The entity a vehicle reference names, or nil.
---@param ref any
---@return number|nil entity
function Vehicles.refEntity(ref)
    if type(ref) == 'number' or type(ref) == 'string' then
        local id = tonumber(ref)
        return id and getEntityForVehicleId(id) or nil
    end
    if type(ref) ~= 'table' then return nil end

    if ref.entity ~= nil then return tonumber(ref.entity) end
    -- `vehicleId` too: a GetVehicle answer is its own reference.
    local byId = ref.id
    if byId == nil then byId = ref.vehicleId end
    if byId ~= nil then
        local id = tonumber(byId)
        return id and getEntityForVehicleId(id) or nil
    end
    if ref.netId ~= nil then
        local netId = tonumber(ref.netId)
        if not netId or netId <= 0 or not NetworkDoesNetworkIdExist(netId) then return nil end
        return NetworkGetEntityFromNetworkId(netId)
    end
    if type(ref.plate) == 'string' and ref.plate ~= '' then
        -- The game pads plates with spaces: compare without them.
        local want = ref.plate:upper():gsub('%s+', '')
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local plate = (GetVehicleNumberPlateText(veh) or ''):upper():gsub('%s+', '')
            if plate == want then return veh end
        end
    end
    return nil
end

--- The vehicleId a vehicle reference names, or nil.
---@param ref any
---@return number|nil vehicleId
local function vehicleRefId(ref)
    if type(ref) == 'number' or type(ref) == 'string' then return tonumber(ref) end
    if type(ref) ~= 'table' then return nil end
    if ref.id ~= nil then return tonumber(ref.id) end
    if ref.vehicleId ~= nil then return tonumber(ref.vehicleId) end

    local entity = Vehicles.refEntity(ref)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return Vehicles.idByEntity(entity)
end

-- Network control

--- Takes network control of a vehicle, up to `attempts` times (mod, paint and repair natives do nothing without
--- it). Never from another player at the wheel: it makes their car rubber-band. Waits, so call it from a thread.
---@param entity number|nil
---@param opts table|nil  { attempts = 3, wait = 500 } — tries, and ms per try
---@return boolean ok, string|nil why
function Vehicles.takeControl(entity, opts)
    if not entity or entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= 2 then
        return false, 'no such vehicle'
    end
    if NetworkHasControlOfEntity(entity) then return true end

    local driver = GetPedInVehicleSeat(entity, -1)
    if driver ~= 0 and driver ~= PlayerPedId() and IsPedAPlayer(driver) then
        return false, 'another player is driving it'
    end

    opts = type(opts) == 'table' and opts or {}
    local attempts = math.max(1, math.min(10, math.floor(tonumber(opts.attempts) or 3)))
    local waitMs = math.max(10, math.min(5000, tonumber(opts.wait) or 500))
    for _ = 1, attempts do
        NetworkRequestControlOfEntity(entity)
        local deadline = GetGameTimer() + waitMs
        while not NetworkHasControlOfEntity(entity) and GetGameTimer() < deadline do
            Wait(10)
        end
        if NetworkHasControlOfEntity(entity) then return true end
        if not DoesEntityExist(entity) then return false, 'no such vehicle' end
    end
    return false, 'control was not granted'
end

exports('TakeVehicleControl', function(vehicle, opts)
    return Vehicles.takeControl(Vehicles.refEntity(vehicle), opts)
end)

--- Takes network control of any entity: a car by Vehicles.takeControl, an NPC or object waited on up to `ms`
--- (default 1000). An entity only this game has is always its own. Waits, so call it from a thread.
---@return boolean ok, string|nil why
function Vehicles.takeEntityControl(ent, ms)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return false, 'it is gone' end
    if not NetworkGetEntityIsNetworked(ent) or NetworkHasControlOfEntity(ent) then return true end
    if GetEntityType(ent) == 2 then return Vehicles.takeControl(ent) end
    NetworkRequestControlOfEntity(ent)
    local deadline = GetGameTimer() + (tonumber(ms) or 1000)
    while DoesEntityExist(ent) and not NetworkHasControlOfEntity(ent) and GetGameTimer() < deadline do Wait(10) end
    if NetworkHasControlOfEntity(ent) then return true end
    return false, 'control was not granted'
end

--- [bagName .. '\0' .. key] = { bag, fn, deadline } — statebag changes that arrived before their entity did.
local _awaitingBags = {}
local _awaitWorker = false

--- Run `fn(entity)` once the entity behind a statebag exists on this client, giving up after five seconds.
--- A bag can arrive before its entity (they replicate separately), so GetEntityFromStateBagName answers 0 for a
--- car a moment away; every car key's handler waits here on one shared thread.
--- One wait per bag and key: asking again replaces the callback. `fn` must read the bag itself (a newer change
--- may have landed) and must not wait.
---@param bagName string
---@param key string  the statebag key whose handler is waiting
---@param fn fun(entity: number)
function Vehicles.awaitBagEntity(bagName, key, fn)
    _awaitingBags[bagName .. '\0' .. tostring(key)] = { bag = bagName, fn = fn, deadline = GetGameTimer() + 5000 }
    if _awaitWorker then return end
    _awaitWorker = true

    CreateThread(function()
        while next(_awaitingBags) do
            Wait(100)
            local now, ready = GetGameTimer(), {}

            for name, w in pairs(_awaitingBags) do
                local entity = GetEntityFromStateBagName(w.bag)
                if entity and entity ~= 0 and DoesEntityExist(entity) then
                    ready[#ready + 1] = { fn = w.fn, entity = entity }
                    _awaitingBags[name] = nil
                elseif now > w.deadline then
                    _awaitingBags[name] = nil   -- never arrived; nothing to tell anyone about
                end
            end

            -- Run after the walk: a callback may add a key to the table.
            for i = 1, #ready do
                local ok, err = pcall(ready[i].fn, ready[i].entity)
                if not ok then
                    print(('[whip_core:vehicles] statebag wait callback errored: %s'):format(tostring(err)))
                end
            end
        end
        _awaitWorker = false
    end)
end

--- The model name for a vehicle, as a lowercase string. (GetDisplayNameFromVehicleModel returns the hash for some
--- models; the GXT label is then the readable one.)
---@param veh number
---@return string
local function VehicleModelName(veh)
    local modelName = GetDisplayNameFromVehicleModel(GetEntityModel(veh))
    if modelName and (tonumber(modelName) or modelName:match('^%-?%d+$')) then
        local label = GetLabelText(modelName)
        if label and label ~= 'NULL' then modelName = label end
    end
    return (modelName or 'unknown'):lower()
end

--- Offer a vehicle to the server as a session vehicle. Cheap for a registered one (the server ignores a known plate).
---@param veh number
local function offerSessionVehicle(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    local plate = GetVehicleNumberPlateText(veh)
    if not plate or plate == '' then return end

    local netId = NetworkGetNetworkIdFromEntity(veh)
    if not netId or netId <= 0 then return end

    TriggerServerEvent('whip_core:server:registerSessionVehicle',
        plate, VehicleModelName(veh), netId, GetVehicleType(veh), GetIsVehicleEngineRunning(veh))
end

--- Check if player has a key for a vehicleId
local function HasKeyForVehicle(vehicleId)
    return vehicleKeys[vehicleId] ~= nil
end

--- Check if player has a key for a vehicle by plate (a linear scan; prefer HasKeyForVehicle).
local function hasKeyForPlate(plate)
    if type(plate) ~= 'string' or plate == '' then return false end
    local norm = plate:upper():gsub('%s+', '')
    for _, keyPlate in pairs(vehicleKeys) do
        if type(keyPlate) == 'string' and keyPlate:upper():gsub('%s+', '') == norm then
            return true
        end
    end
    return false
end

-- Server to client sync

RegisterNetEvent('whip_core:client:vehiclesSync', function(vehicles)
    vehicleDefs = {}
    if vehicles then
        if type(vehicles) == 'table' then
            for _, v in ipairs(vehicles) do
                if v and v.vehicleId then
                    vehicleDefs[v.vehicleId] = v
                end
            end
        end
    end
end)

RegisterNetEvent('whip_core:client:vehicleKeysSync', function(keys)
    vehicleKeys = keys or {}
end)

RegisterNetEvent('whip_core:client:ignitionState', function(vehicleId, hasKey, hasUnhacked, coming)
    if vehicleId == 0 then return end  -- NPC vehicle, no restrictions
    ignitionHasKey[vehicleId] = hasKey
    ignitionUnhacked[vehicleId] = hasUnhacked or false
    -- `coming`: no key yet, but the strip's is going in.
    ignitionComing[vehicleId] = (coming == true and not hasKey) and (GetGameTimer() + KEY_WAIT_MS) or nil

    -- Set currentVehicleId from the server if unset, only if the car we are in says so (a late reply for a
    -- previous car must not name this one). If not yet stamped, the seat tick picks it up within 200 ms.
    if not currentVehicleId and currentVehicle and DoesEntityExist(currentVehicle)
        and Vehicles.idByEntity(currentVehicle) == vehicleId then
        currentVehicleId = vehicleId
    end

    -- (A bicycle has no ignition to empty; an add-on one answered "no key" is left rideable.)
    if currentVehicleId == vehicleId and not hasKey and not isBicycle(currentVehicle) then
        -- Key removed: kill the engine through SetIgnitionState so the cache stays true.
        engineOn = false
        ReportEngine(false)
        SetIgnitionState(currentVehicle, false, true)
    end

    -- A press held while the key was on its way runs now.
    if heldIgnition and heldIgnition.vId == vehicleId and not ignitionComing[vehicleId] then
        local held = heldIgnition
        heldIgnition = nil
        if ignitionActive and currentVehicleId == vehicleId then RequestIgnition(held.want) end
    end
end)

RegisterNetEvent('whip_core:client:updateIgnitionSlot', function(data)
    SendNUIMessage({ action = 'updateIgnitionSlot', data = data })
end)

-- Session vehicle registered: the server assigned a vehicleId to an NPC vehicle
RegisterNetEvent('whip_core:client:sessionVehicleRegistered', function(vehicleId, netId)
    if not vehicleId then return end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 then return end
    -- The server names the car it answered for; a late reply about a previous car must not rename this one.
    if netId and NetworkGetEntityFromNetworkId(netId) ~= veh then return end

    -- No local bookkeeping: the server stamped the id on the entity.
    currentVehicleId = vehicleId
    SetEntityAsMissionEntity(veh, true, true)

    -- If the engine was running when we got in, keep it: pre-set ignitionHasKey so the engine thread does not
    -- kill it before the ignitionState event arrives.
    if GetIsVehicleEngineRunning(veh) then
        engineOn = true
        ignitionHasKey[vehicleId] = true
        SetIgnitionState(veh, true, false)
        ReportEngine(true)
    end
end)

-- Pin or unpin a street car whip holds, asked of the network owner (server's pinOnOwner): pinned so GTA does not
-- cull it. Only the owner can set it.
RegisterNetEvent('whip_core:client:pinStreetCar', function(netId, pin)
    if type(netId) ~= 'number' or not NetworkDoesEntityExistWithNetworkId(netId) then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) or not NetworkHasControlOfEntity(veh) then return end
    if pin then
        SetEntityAsMissionEntity(veh, true, true)
    else
        SetEntityAsNoLongerNeeded(veh)
    end
end)

-- Vehicle storage: denied, opened, updated

--- Give up on an in-flight storage request and put this client back how it was. Called by the server's refusal
--- and by the timeouts: storage opens optimistically, and a rate-limited event gets no reply.
--- A refusal is an answer (no retry); a timeout is not (retry after SWAP_DEBOUNCE_MS).
---@param answered boolean true when the server refused; false when we never heard back
local function abandonStorageRequest(answered)
    StorageTrace(answered and 'ABANDON: server refused' or 'ABANDON: no reply (timeout)')

    vehicleStoragePending = false
    optimisticStorageType = nil

    -- Inventory.close, not a bare hide: it releases server-side holds and is safe when nothing is on screen.
    if Inventory.hasOptimisticPanel() then Inventory.close() end

    -- The intent, cleared unconditionally: a stale `panelWanted` makes Inventory.confirmPanel refuse every other panel.
    Inventory.cancelPanelOpen()

    -- A refused swap is not retried (it was toasted); an unanswered one is, after SWAP_DEBOUNCE_MS, by the
    -- level-triggered reconcile. One attempt per seating; cleared when they move.
    if swapPending then
        swapPending = false
        if answered then swapDenied = true end
    end

    -- Close the trunk door if we opened it optimistically, through the server (a local shut would desync others).
    if trunkDoorEntity and DoesEntityExist(trunkDoorEntity) then
        requestVehicleDoor(trunkDoorEntity, 5, 'shut')
    end
    trunkDoorEntity = nil
end

--- The server said no, with a reason already toasted server-side.
RegisterNetEvent('whip_core:client:openVehicleStorageDenied', function()
    -- Answered: a swap refused here stays refused until the player moves.
    abandonStorageRequest(true)
end)

RegisterNetEvent('whip_core:client:openVehicleStorage', function(data)
    -- The success line: a request with no OPENED or REFUSED vanished in transit.
    StorageTrace(('OPENED %s of #%s'):format(tostring(data and data.storageType),
        tostring(data and data.vehicleId)))

    vehicleStoragePending = false

    -- Resolved either way; cleared before the early return so a malformed payload cannot strand it.
    optimisticStorageType = nil

    if not data then return end

    -- Keyed from the id the payload names, not the car the player sits in now (see vehicleStorageKey).
    local storageKey = vehicleStorageKey(data.vehicleId, data.storageType)

    -- Diagnostic only: a car whose plate differs from its record still opens, but plate lookups would miss it.
    if data.plate then
        local car  = getEntityForVehicleId(data.vehicleId)
        local worn = car and GetVehicleNumberPlateText(car)
        if worn and worn:upper():gsub('%s+', '') ~= tostring(data.plate):upper():gsub('%s+', '') then
            StorageTrace(('NOTE: #%s wears plate "%s" but its record says "%s"')
                :format(tostring(data.vehicleId), worn, tostring(data.plate)))
        end
    end

    -- Reuse the container panel, shaped as openInventoryWithContainer does.
    local nuiData = {
        inventory     = data.inventory,
        weights       = data.weights,
        itemDefs      = data.itemDefs,
        charName      = data.charName,
        charId        = data.charId,
        accountNumber = data.accountNumber,
        maxSlots      = data.maxSlots,
        maxWeight     = data.maxWeight,
        containerDef  = data.storageDef,
        containerInv  = data.storageInv,
        containerWeight = data.storageWeight,
        showIgnition      = data.showIgnition,
        ignitionSlot      = data.ignitionSlot,
        ignitionVehicleId = data.vehicleId,
        -- Same grid as a stash, keyed by 'vehicle:7:trunk' rather than 'container:42'.
        storeId           = data.storeId,
    }
    -- Live swap: the inventory is open on the ground and this is the glovebox. OpenInventoryUI refuses while any UI is up.
    if swapPending and data.storageType == 'glovebox' then
        swapPending = false

        -- They may have got out or opened something else in flight: release the viewer slot the server added.
        if not IsPedInAnyVehicle(PlayerPedId(), false) or not Inventory.isSwappable() then
            TriggerServerEvent('whip_core:server:closeVehicleStorage', data.vehicleId, data.storageType)
            return
        end

        -- Same tick as the NUI message, full shape: the vehicleStorageUpdate filter, client/ground.lua and the
        -- trunk-door watcher read this global the instant the grid appears.
        -- data.vehicleId is the server-resolved id; never currentVehicleId (nil for a passenger).
        Inventory.setActiveVehicleStorage({ vehicleId = data.vehicleId, storageType = data.storageType })
        -- Item definitions only if the page does not already hold this set (client/inventory.lua).
        SendNUIMessage({ action = 'swapSecondaryPanel', data = Inventory.withoutHeldItemDefs(nuiData) })
        return
    end

    -- Inventory.confirmPanel remembers the payload, folds it into a panel drawn from memory or cold-opens, and
    -- answers false if the player closed or asked for another panel meanwhile. A declined open still owes the
    -- server a release (see client/containers.lua).
    local shown, why = Inventory.confirmPanel({
        key     = storageKey,
        open    = 'openInventoryWithContainer',
        sync    = 'swapSecondaryPanel',
        -- `admin`: opened from the Vehicle Manager, from anywhere; the position rules below leave it alone.
        context = { vehicleStorage = { vehicleId = data.vehicleId, storageType = data.storageType,
                                       admin = data.admin == true or nil } },
        -- Predicted by vehicle id (drawVehicleStorage).
        noLearn = true,
    }, nuiData)
    if not shown then
        -- Said out loud, so an OPENED with nothing on screen says which reason fired.
        StorageTrace(('DECLINED %s of #%s — %s'):format(tostring(data.storageType),
            tostring(data.vehicleId), tostring(why or 'no reason given')))
        TriggerServerEvent('whip_core:server:closeVehicleStorage', data.vehicleId, data.storageType)
    end
end)

RegisterNetEvent('whip_core:client:vehicleStorageUpdate', function(data)
    if not data then return end

    -- Only paint an update for the compartment on screen (trunk and glovebox share one grid; the ignition 'key' has
    -- its own channel, updateIgnitionSlot). An update with no storageType is forwarded.
    if data.storageType and Inventory.activeVehicleStorage then
        if data.storageType ~= Inventory.activeVehicleStorage.storageType
           or (data.vehicleId and data.vehicleId ~= Inventory.activeVehicleStorage.vehicleId) then
            return
        end
    end

    -- Keep the memory current while the panel is open, from server payloads only. Keyed off the compartment the
    -- update names; an update that names none is not remembered.
    if data.vehicleId and data.storageType then
        Inventory.patchRememberedPanel(vehicleStorageKey(data.vehicleId, data.storageType), {
            containerInv    = data.inventory,
            containerWeight = data.containerWeight,
        })
    end

    SendNUIMessage({ action = 'containerUpdate', data = data })
end)

-- Vehicle lock state broadcast

RegisterNetEvent('whip_core:client:vehicleLockState', function(vehicleId, locked)
    -- One lookup covers owner and non-owner.
    local entity = getEntityForVehicleId(vehicleId)

    if entity and DoesEntityExist(entity) then
        -- Apply lock state
        SetVehicleDoorsLocked(entity, locked and 2 or 1)

        -- Horn honk and light flash feedback (in a thread, for Wait)
        local capturedEntity = entity
        local capturedLocked = locked
        CreateThread(function()
            local vCoords = GetEntityCoords(capturedEntity)
            local ped = PlayerPedId()
            local pCoords = GetEntityCoords(ped)
            local dist = #(pCoords - vCoords)
            if dist < 40.0 then
                StartVehicleHorn(capturedEntity, 200, GetHashKey('NORMAL'), false)
                if capturedLocked then
                    SetVehicleLights(capturedEntity, 2)
                    Wait(150)
                    SetVehicleLights(capturedEntity, 0)
                    Wait(150)
                    SetVehicleLights(capturedEntity, 2)
                    Wait(150)
                    SetVehicleLights(capturedEntity, 0)
                else
                    SetVehicleLights(capturedEntity, 2)
                    Wait(200)
                    SetVehicleLights(capturedEntity, 0)
                end
            end
        end)
    end
end)

-- Taking delivery of a server-built vehicle: wait for it to stream in, apply properties (client natives) and
-- seat the player.

--- @param data table  { vehicleId, netId, properties?, warp? }
--- Take delivery of a server-created vehicle.
---@return number|nil vehicle  the entity handle, once it has actually arrived on this client
local function ReceiveSpawnedVehicle(data)
    if not data or not data.netId then return nil end
    local netId = data.netId

    -- The vehicle must reach this client before there is a handle; ten seconds covers slow streaming.
    local deadline = GetGameTimer() + 10000
    while not NetworkDoesNetworkIdExist(netId) and GetGameTimer() < deadline do
        Wait(50)
    end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        print(('[whip_core:vehicle] netId %s never arrived on this client'):format(tostring(netId)))
        return nil
    end

    if vehicleDefs[data.vehicleId] then
        vehicleDefs[data.vehicleId].state = 'out'
    end

    -- Colours, mods and extras need control of an entity we did not create, or they silently do nothing.
    if data.properties and type(data.properties) == 'table' then
        local applied = Vehicles.takeControl(vehicle, { attempts = 3, wait = 1000 })
        if applied then
            SetVehicleProperties(vehicle, data.properties)
        else
            print(('[whip_core:vehicle] could not take control of vehicle #%s to apply its properties')
                :format(tostring(data.vehicleId)))
        end
    end

    -- The dev tool seats the player; the garage does not. It travels in the payload.
    if data.warp then
        TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)
    end

    return vehicle
end

-- Appearance: apply what the server says a vehicle looks like (the event SetVehicleAppearance and
-- RestoreVehicleAppearance push through).

RegisterNetEvent('whip_core:client:vmApplyMods', function(data)
    if not data or not data.vehicleId then return end

    local vehicle = getEntityForVehicleId(data.vehicleId)

    if not vehicle or not DoesEntityExist(vehicle) then
        return
    end

    -- The server broadcasts when it finds no owner; a driver applies it on their own client.
    if not Vehicles.takeControl(vehicle, { attempts = 1, wait = 1000 }) then
        return
    end

    if data.properties then
        SetVehicleProperties(vehicle, data.properties)
        TriggerServerEvent('whip_core:server:appearanceApplied', data.vehicleId)
    end

end)

-- Garage blips. The single-garage sync events touch only their own blip; only the full garagesSync rebuilds all.
local function removeGarageBlip(key)
    local blip = garageBlips[key]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    garageBlips[key] = nil
end

local function createGarageBlip(key, g)
    removeGarageBlip(key)
    -- No blip for a private garage, one whose resource is not running, or one with icon 0 (GTA draws an arrow).
    if g.private or g.ownerAway or g.blipSprite == 0 then return end
    local blip = AddBlipForCoord(g.x, g.y, g.z)
    SetBlipSprite(blip, g.blipSprite or 357)
    SetBlipColour(blip, g.blipColor or 3)
    SetBlipScale(blip, 0.8)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(g.name or 'Garage')
    EndTextCommandSetBlipName(blip)
    garageBlips[key] = blip
end

local function recreateGarageBlips()
    for key in pairs(garageBlips) do
        removeGarageBlip(key)
    end
    for key, g in pairs(garageDefs) do
        createGarageBlip(key, g)
    end
end

-- Garage sync: blips only. Parking bays register their own prompts (client/garage_spots.lua) and read the
-- garage's name from these definitions.
RegisterNetEvent('whip_core:client:garagesSync', function(garages)
    garageDefs = garages or {}
    recreateGarageBlips()
end)

RegisterNetEvent('whip_core:client:garageCreated', function(key, data)
    garageDefs[key] = data
    createGarageBlip(key, data)
end)

RegisterNetEvent('whip_core:client:garageUpdated', function(key, data)
    garageDefs[key] = data
    createGarageBlip(key, data)
end)

RegisterNetEvent('whip_core:client:garageDeleted', function(key)
    garageDefs[key] = nil
    removeGarageBlip(key)
    -- The bays go too: each spot announces its own removal.
end)

-- Garage: retrieve a vehicle

--- The server has built a retrieved vehicle and is handing this client the netId.
RegisterNetEvent('whip_core:client:garageSpawnVehicle', function(data)
    -- No `warp`: the player stands beside the car.
    ReceiveSpawnedVehicle(data)
end)

-- Garage: store confirmed. A failure needs nothing here (the server toasts).

RegisterNetEvent('whip_core:client:garageStoreConfirmed', function(vehicleId)
    vehicleId = tonumber(vehicleId)
    if not vehicleId then return end

    -- No DeleteEntity: the server already removed it.
    if vehicleDefs[vehicleId] then
        vehicleDefs[vehicleId].state = 'garaged'
    end
end)

-- Key fob animation

local function PlayKeyFobAnim()
    local ped = PlayerPedId()
    local dict = 'anim@mp_player_intmenu@key_fob@'
    if LoadAnimDict(dict, 2000) then
        -- Flag 49 = upper body only + allow movement
        TaskPlayAnim(ped, dict, 'fob_click', 3.0, 3.0, 750, 49, 0, false, false, false)
    end
end

-- L-key lock / unlock (RegisterKeyMapping)

local lockTogglePressed = false

-- A press is a latch spent by the 200 ms poll below, so short taps are not lost. Ignored while a screen owns the
-- keys (an "l" typed in a search box must not lock the car).
RegisterCommand('+whip_togglelock', function()
    if not IsGameInputFree() then return end
    lockTogglePressed = true
end, false)

RegisterCommand('-whip_togglelock', function() end, false)

RegisterKeyMapping('+whip_togglelock', 'Lock/Unlock Vehicle', 'keyboard', 'l')

-- NPC vehicle lock: every non-whip vehicle stays locked; players must lockpick. Runs on the client, which already
-- knows the cars around it, and rides the 200 ms lock-key thread below (GetClosestVehicle, no pool scan).

--- How long a car must lack a whip id before the rule locks it (the id can arrive a moment after the car). The
--- VEHICLE_STATE_KEY handler above fixes the lock if the id is later than this.
local NPC_LOCK_GRACE_MS = 750

--- Lock the nearest vehicle that is not a whip vehicle. Called from the 200ms thread below.
local function NpcLockNearby()
    local range = Config.NpcVehicleLockRange or 0
    if range <= 0 then return end          -- rule switched off in config

    local ped = PlayerPedId()

    -- On foot only: in a vehicle the nearest car is usually your own.
    if IsPedInAnyVehicle(ped, false) then return end

    local c = GetEntityCoords(ped)
    local veh = GetClosestVehicle(c.x, c.y, c.z, range + 0.0, 0, 71)
    if not veh or veh == 0 then return end

    -- A non-networked car (a scene's, a preview) is left alone: the server could never unlock it.
    if not NetworkGetEntityIsNetworked(veh) then return end

    -- Cheap question first: a locked car stays locked.
    if GetVehicleDoorLockStatus(veh) ~= 2 then
        -- Vehicles.idByEntity is a statebag read, the expensive call here: once per car.
        if not Vehicles.idByEntity(veh) then
            -- Not on the first look (NPC_LOCK_GRACE_MS). Keyed with the network id so a recycled handle is a new car.
            local now, netId = GetGameTimer(), NetworkGetNetworkIdFromEntity(veh)
            local seen = _npcFirstSeen[veh]
            if not seen or seen.netId ~= netId then
                _npcFirstSeen[veh] = { at = now, netId = netId }
                return
            end
            if now - seen.at < NPC_LOCK_GRACE_MS then return end

            SetVehicleDoorsLocked(veh, 2)
            _npcLocked[veh] = true
        end
    end
end

CreateThread(function()
    while true do
        Wait(200)

        -- NPC lock rule rides this thread.
        NpcLockNearby()

        -- Only do work when L was pressed
        if not lockTogglePressed then goto continue end
        lockTogglePressed = false

        local ped = PlayerPedId()
        local pCoords = GetEntityCoords(ped)

        if IsPedInAnyVehicle(ped, false) then
            -- In vehicle — only driver can lock
            local veh = GetVehiclePedIsIn(ped, false)
            if GetPedInVehicleSeat(veh, -1) == ped then
                local vId = currentVehicleId
                if vId and (HasKeyForVehicle(vId) or ignitionHasKey[vId]) then
                    TriggerServerEvent('whip_core:server:toggleVehicleLock', vId)
                end
            end
        else
            -- On foot — find nearest vehicle we have a key for
            local closestVeh = nil
            -- Same fallback as the server-side reader (events_vehicles.lua), so a trimmed config does not error on nil.
            local closestDist = Config.VehicleLockRange or 8.0
            local closestVId = nil

            -- One pass: the entity answers "is this car mine?".
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                if DoesEntityExist(veh) then
                    local dist = #(pCoords - GetEntityCoords(veh))
                    if dist < closestDist then
                        local vId = Vehicles.idByEntity(veh)
                        if vId and vehicleKeys[vId] then
                            closestDist = dist
                            closestVeh = veh
                            closestVId = vId
                        end
                    end
                end
            end

            if closestVeh and closestVId then
                PlayKeyFobAnim()
                TriggerServerEvent('whip_core:server:toggleVehicleLock', closestVId)
            end
        end

        ::continue::
    end
end)

-- Reporting a vehicle's appearance

--- Vehicles whose appearance is a preview, not real yet (reports are skipped). Held by vehicleId on the previewing
--- client. [vehicleId] = true while a resource holds it.
local appearanceHeld = {}

--- Put a car's stored look back after its holder stopped. Declared here, assigned below the appearance statebag handler.
local restoreStoredLook

-- The holds (shared/registry.lua rule): a hold belongs to whoever took it; a holder that stops is swept and the
-- car's stored look goes back on.
local _appearanceHolds = Registry.new('VehicleAppearanceHold', {
    label    = 'appearance hold',
    store    = appearanceHeld,
    onRemove = function(vehicleId, _, _, why)
        if why == 'stopped' and restoreStoredLook then restoreStoredLook(vehicleId) end
    end,
})

--- Tell the server what the car you are in looks like. A report, believed only for dirt (mergeClientProperties);
--- paint, parts and bodywork change only through SetVehicleAppearance.
local function syncCurrentVehicle()
    if not currentVehicle or not DoesEntityExist(currentVehicle) or not currentVehicleId then
        return
    end
    if appearanceHeld[currentVehicleId] then return end

    TriggerServerEvent('whip_core:server:syncVehicleProperties',
        currentVehicleId, GetVehicleProperties(currentVehicle))
end

--- Stop whip storing a vehicle's appearance while something is previewing it.
---
---     exports.whip_core:HoldVehicleAppearance(vehicleId, true)   -- before the first preview
---     exports.whip_core:HoldVehicleAppearance(vehicleId, false)  -- once the car is real again
---
--- Releasing reports the car immediately. Always release: a hold left set stops the car's appearance being stored.
--- A stopping holder is released automatically. Answers (false, reason) when another resource holds the car or the
--- release is not yours; releasing a car nobody holds answers true.
---@param vehicleId number|WhipVehicleRef|nil  a vehicleId or a vehicle reference
---@param held boolean
---@return boolean ok
---@return string|nil reason
exports('HoldVehicleAppearance', function(vehicleId, held)
    local owner = Registry.caller()        -- first, before anything can yield
    vehicleId = vehicleRefId(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, 'HoldVehicleAppearance: no such vehicle' end

    if held then
        local ok, why = _appearanceHolds:add(owner, vehicleId, true)
        if not ok then return false, why --[[@as string]] end   -- a refusal's reason
        return true
    end

    if appearanceHeld[vehicleId] == nil then return true end
    local ok, why = _appearanceHolds:remove(owner, vehicleId)
    if not ok then return false, why end
    if currentVehicleId == vehicleId then syncCurrentVehicle() end
    return true
end)

-- Appearance: dress a car as soon as it is seen. A statebag, not an event: paint and mods are client natives and
-- a statebag replicates on stream-in, so the look waits on the entity for whoever turns up.

--- Vehicles this client has dressed, keyed by entity (a re-spawned car is a new entity), holding a fingerprint
--- of what was applied.
local appearanceApplied = {}

-- Pruned like _vehicleIdByEntity.
CreateThread(function()
    while true do
        Wait(30000)
        for entity in pairs(appearanceApplied) do
            if not DoesEntityExist(entity) then appearanceApplied[entity] = nil end
        end
    end
end)

-- Every field the server keeps (Vehicles.sanitizeProperties' APPEARANCE_FIELDS), except dirt, which
-- changes on its own.
local APPEARANCE_PRINT_FIELDS = {
    'color1', 'color2', 'pearlescent', 'wheelColor',
    'wheelType', 'windowTint', 'livery', 'plateIndex',
    'headlightColor', 'interiorColor', 'dashboardColor',
    'turbo', 'smokeEnabled', 'xenon',
}
local APPEARANCE_PRINT_RGB = { 'customColor1', 'customColor2', 'tyreSmoke', 'neonColor' }

--- A short string that changes when the appearance does (the statebag hands over a fresh table every time).
local function AppearanceFingerprint(props)
    local out = {}

    -- Walk a list of names: most fields are optional, and `#` on an array with holes is undefined.
    for i = 1, #APPEARANCE_PRINT_FIELDS do
        out[#out + 1] = tostring(props[APPEARANCE_PRINT_FIELDS[i]])
    end

    -- The {r, g, b} colours, then the two on/off lists in fixed order (neon sides 1-4, extras 1-14).
    for i = 1, #APPEARANCE_PRINT_RGB do
        local c = props[APPEARANCE_PRINT_RGB[i]]
        out[#out + 1] = type(c) == 'table' and (tostring(c.r) .. ',' .. tostring(c.g) .. ',' .. tostring(c.b)) or '-'
    end
    if type(props.neonEnabled) == 'table' then
        for side = 1, 4 do out[#out + 1] = tostring(props.neonEnabled[side]) end
    end
    if type(props.extras) == 'table' then
        for extra = 1, 14 do
            local v = props.extras[tostring(extra)]
            if v ~= nil then out[#out + 1] = 'x' .. extra .. ':' .. tostring(v) end
        end
    end

    -- Mods in slot order (pairs() has no order).
    if type(props.mods) == 'table' then
        for slot = 0, 49 do
            local v = props.mods[tostring(slot)]
            if v then out[#out + 1] = slot .. ':' .. tostring(v) end
        end
    end

    return table.concat(out, '|')
end

--- Is somebody else driving this? Then it is not ours to touch (taking ownership makes their car rubber-band).
---@param entity number
---@return boolean
local function DrivenBySomeoneElse(entity)
    local driver = GetPedInVehicleSeat(entity, -1)
    if not driver or driver == 0 or not DoesEntityExist(driver) then return false end
    return driver ~= PlayerPedId()
end

--- Same colour, for the {r, g, b} tables.
local function SameRgb(want, have)
    if type(have) ~= 'table' then return false end
    return (want.r or 0) == have.r and (want.g or 0) == have.g and (want.b or 0) == have.b
end

--- Does this car already look the way `props` says? Mods replicate, so once any client has dressed a car re-dressing
--- would only cost a control request per viewer. Mirrors SetVehicleProperties (client/vehicle_properties.lua)
--- field for field; plate text is compared trimmed, dirt is left out. Anything unconfirmed reads as "does not match".
---@param entity number
---@param props table
---@return boolean
local function AppearanceMatches(entity, props)
    local live = GetVehicleProperties(entity)

    -- Each colour on its own, as SetVehicleProperties sets it: one the props leave out is not compared
    for _, f in ipairs({ 'color1', 'color2', 'pearlescent', 'wheelColor' }) do
        if props[f] ~= nil and live[f] ~= props[f] then return false end
    end
    if props.customColor1 and not SameRgb(props.customColor1, live.customColor1) then return false end
    if props.customColor2 and not SameRgb(props.customColor2, live.customColor2) then return false end

    if props.plate then
        local want = tostring(props.plate):match('^%s*(.-)%s*$')
        local have = tostring(live.plate or ''):match('^%s*(.-)%s*$')
        if want ~= have then return false end
    end

    for _, f in ipairs({ 'plateIndex', 'wheelType', 'windowTint', 'headlightColor', 'interiorColor', 'dashboardColor' }) do
        if props[f] ~= nil and live[f] ~= props[f] then return false end
    end
    if props.livery ~= nil and props.livery >= 0 and live.livery ~= props.livery then return false end

    if type(props.mods) == 'table' then
        local liveMods = live.mods or {}
        for i = 0, 49 do
            local v = props.mods[tostring(i)]
            if v ~= nil and v >= 0 and liveMods[tostring(i)] ~= v then return false end
        end
    end

    -- On/off as a boolean or a BOOL native's 1: the same answer
    local function yes(v) return v == true or v == 1 end
    for _, f in ipairs({ 'turbo', 'xenon', 'smokeEnabled' }) do
        if props[f] ~= nil and yes(live[f]) ~= yes(props[f]) then return false end
    end

    if props.tyreSmoke and not SameRgb(props.tyreSmoke, live.tyreSmoke) then return false end
    if props.neonColor and not SameRgb(props.neonColor, live.neonColor) then return false end
    if type(props.neonEnabled) == 'table' then
        local have = live.neonEnabled or {}
        for i = 1, 4 do
            if yes(props.neonEnabled[i]) ~= yes(have[i]) then return false end
        end
    end

    if type(props.extras) == 'table' then
        local have = live.extras or {}
        for i = 1, 14 do
            local v = props.extras[tostring(i)]
            -- An extra this model lacks cannot differ.
            if v ~= nil and have[tostring(i)] ~= nil and yes(have[tostring(i)]) ~= yes(v) then
                return false
            end
        end
    end

    return true
end

--- Dressed confirmations waiting to go to the server: [vehicleId] = true. Batched, one event a second, to stay
--- under the server's rate limit for appearanceApplied.
local _dressedPending = {}
local _dressedFlushQueued = false
local DRESSED_BATCH_MAX = 64   -- the server's cap per event (server/events_vehicles.lua)

--- Say "this car now looks right", batched with others in the next second.
---@param vehicleId number
local function QueueDressedConfirmation(vehicleId)
    _dressedPending[vehicleId] = true
    if _dressedFlushQueued then return end
    _dressedFlushQueued = true

    SetTimeout(1000, function()
        _dressedFlushQueued = false
        local batch = {}
        for id in pairs(_dressedPending) do
            batch[#batch + 1] = id
            if #batch == DRESSED_BATCH_MAX then
                TriggerServerEvent('whip_core:server:appearanceApplied', batch)
                batch = {}
            end
        end
        _dressedPending = {}
        if #batch > 0 then TriggerServerEvent('whip_core:server:appearanceApplied', batch) end
    end)
end

--- Apply a stored appearance to an entity, taking control first (Vehicles.takeControl). Losing the race is fine:
--- mods replicate. Never on a car anyone else (NPCs included) is driving; their client dresses it.
---@return boolean applied
local function ApplyStoredAppearance(entity, props)
    if DrivenBySomeoneElse(entity) then return false end
    if not Vehicles.takeControl(entity) then return false end
    SetVehicleProperties(entity, props)
    return true
end

--- Put a stored look on a car, in its own thread (it may wait for control).
---@param entity number
---@param value table  the stored block
local function dressFromBag(entity, value)
    CreateThread(function()
        if not DoesEntityExist(entity) then return end
        local vehicleId = Vehicles.idByEntity(entity)

        -- Something is previewing this car: do not repaint over it.
        if vehicleId and appearanceHeld[vehicleId] then return end

        -- Already wearing this block on this entity (the handler fires on every change and stream-in).
        local fingerprint = AppearanceFingerprint(value)
        if appearanceApplied[entity] == fingerprint then return end

        -- Already wearing it: nothing to take control of (most stream-ins land here).
        if not AppearanceMatches(entity, value) then
            if not ApplyStoredAppearance(entity, value) then return end
        end
        appearanceApplied[entity] = fingerprint

        -- Tell the server the car looks right; until then it ignores this client's reports (QueueDressedConfirmation).
        if vehicleId then
            QueueDressedConfirmation(vehicleId)
        end
    end)
end

AddStateBagChangeHandler(VEHICLE_APPEARANCE_KEY, nil, function(bagName, _, value)
    if type(value) ~= 'table' then return end
    local entity = GetEntityFromStateBagName(bagName)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        dressFromBag(entity, value)
        return
    end
    -- The bag can arrive before the entity: the shared wait, then the bag is read again.
    Vehicles.awaitBagEntity(bagName, VEHICLE_APPEARANCE_KEY, function(arrived)
        local current = Entity(arrived).state[VEHICLE_APPEARANCE_KEY]
        if type(current) == 'table' then dressFromBag(arrived, current) end
    end)
end)

--- A resource holding a car's appearance has stopped: the registry sweep calls this per car. The stored look goes
--- back on; the current one is not reported (it may wear parts nobody paid for).
restoreStoredLook = function(vehicleId)
    local entity = getEntityForVehicleId(vehicleId)
    local stored = entity and Entity(entity).state[VEHICLE_APPEARANCE_KEY]
    if entity and type(stored) == 'table' then
        CreateThread(function()
            if DoesEntityExist(entity) and not AppearanceMatches(entity, stored) then
                ApplyStoredAppearance(entity, stored)
            end
        end)
    end
end


-- Vehicle enter / exit detection

local wasInVehicle = false
local wasDriver = false
local seatsTickFailed = false   -- Seats.tick threw once (printed once, not every 200 ms)
local weaponLockTickFailed = false   -- WeaponLock.tick likewise

--- The seat this player is in, -1 being the driver's; nil when not in a car.
local currentSeat = nil

--- Which seat of `veh` this ped is in.
---@return number|nil
local function seatOf(veh, ped)
    for seat = -1, GetVehicleMaxNumberOfPassengers(veh) - 1 do
        if GetPedInVehicleSeat(veh, seat) == ped then return seat end
    end
    return nil
end

--- Tell this client's resources, and the server, that we are now in `seat` of the current car. Both sides'
--- `whip_core:vehicle:entered` carry the seat (driver is -1). The server is told once the car's id is known.
local function announceSeat(seat)
    ---@cast currentVehicle -nil   -- said only from the seat tick, in a car
    currentSeat = seat
    WhipEmit('whip_core:vehicle:entered', {
        vehicleId = currentVehicleId,
        entity    = currentVehicle,
        plate     = GetVehicleNumberPlateText(currentVehicle),
        seat      = seat,
    })
    if currentVehicleId and seat then
        TriggerServerEvent('whip_core:server:vehicleSeat', currentVehicleId, seat, true)
    end
end

--- What taking the wheel costs: the ignition check if the car has a whip id, otherwise the offer that makes a
--- street car a session vehicle. Shared by the three ways to become driver: getting in, sliding across, a late id.
local function onTookWheel(veh)
    if currentVehicleId then
        -- Until the answer lands an engine press is held, not refused (ignitionComing).
        ignitionComing[currentVehicleId] = GetGameTimer() + KEY_WAIT_MS
        TriggerServerEvent('whip_core:server:checkIgnition', currentVehicleId)
    else
        offerSessionVehicle(veh)
    end
end

-- "Remember where I am", no faster than the server takes it (one per 5 s, events_vehicles.lua). A request inside
-- the gap is sent once the gap is over. A little over 5 s, since the server times arrivals and high ping skews them.
local SAVE_POS_GAP_MS = 5000 + 250
local lastPosSave, posSaveQueued = -SAVE_POS_GAP_MS, false

local function saveMyPosition()
    local since = GetGameTimer() - lastPosSave
    if since >= SAVE_POS_GAP_MS then
        lastPosSave = GetGameTimer()
        TriggerServerEvent('whip_core:server:saveMyPosition')
        return
    end
    if posSaveQueued then return end
    posSaveQueued = true
    SetTimeout(SAVE_POS_GAP_MS - since, function()
        posSaveQueued = false
        lastPosSave = GetGameTimer()
        TriggerServerEvent('whip_core:server:saveMyPosition')
    end)
end

CreateThread(function()
    while true do
        local cost = WhipCost.start()
        local ped = PlayerPedId()
        local inVehicle = IsPedInAnyVehicle(ped, false)

        -- Warped straight from one car into another: no moment out of a vehicle, so treat this tick as "out"
        -- for the old car; the next tick enters the new one.
        if inVehicle and wasInVehicle and currentVehicle and GetVehiclePedIsIn(ped, false) ~= currentVehicle then
            inVehicle = false
        end

        local isDriver = inVehicle and currentVehicle ~= nil and DoesEntityExist(currentVehicle)
            and GetPedInVehicleSeat(currentVehicle, -1) == ped

        -- The id statebag may not have arrived yet: while seated with no id, keep asking (one read per tick).
        local part = WhipCost.start()   -- this pass's parts, timed apart too (/whipcost)
        if inVehicle and wasInVehicle and currentVehicle and DoesEntityExist(currentVehicle) then
            if not currentVehicleId then
                currentVehicleId = Vehicles.idByEntity(currentVehicle)
                if currentVehicleId then
                    announceSeat(seatOf(currentVehicle, ped))
                    -- The id was late: now that it is known, a driver gets the known-car check.
                    if isDriver then onTookWheel(currentVehicle) end
                end
            end

            -- Changed seat without getting out: announced in any car so resources follow the seat (pad driving
            -- controls, weapon lock off in a turret seat). The server is told for a whip car only (announceSeat).
            local seat = seatOf(currentVehicle, ped)
            if seat and seat ~= currentSeat then announceSeat(seat) end

            -- Slid across into the driver seat (onTookWheel).
            if isDriver and not wasDriver then onTookWheel(currentVehicle) end
        end
        WhipCost.stop('vehicles: in-car pass: seat and id', part)

        if inVehicle and not wasInVehicle then
            -- Just entered a vehicle
            local veh = GetVehiclePedIsIn(ped, false)
            currentVehicle = veh
            currentVehicleId = Vehicles.idByEntity(veh)

            announceSeat(seatOf(veh, ped))

            -- Inherit the engine state GTA has.
            engineOn = GetIsVehicleEngineRunning(veh) == true
            lastReportedEngine = nil   -- a new vehicle reports afresh

            -- Show the vehicle panel, then clear the change cache (the NUI starts with no values). One message
            -- shows the dial and its gauges (html/js/vehicle-dial.js).
            SendNUIMessage({ action = 'showVehicleHud' })
            ResetVehicleHud()

            if currentVehicleId then
                -- Nothing to seed: gauges are replicated stats, filled in by the occupant tick below.
                refreshVehicleHud()

                -- A known whip vehicle needs only its ignition check. Anything else the player is driving is
                -- offered to the server as a session vehicle (also how a running street car gets its key).
                if GetPedInVehicleSeat(veh, -1) == ped then onTookWheel(veh) end
            else
                -- Not a whip vehicle at all — offer it (driver only).
                if GetPedInVehicleSeat(veh, -1) == ped then onTookWheel(veh) end
            end
            isDriver = GetPedInVehicleSeat(veh, -1) == ped

            -- Save player position on vehicle enter
            saveMyPosition()
        elseif not inVehicle and wasInVehicle then
            -- Just exited a vehicle
            WhipEmit('whip_core:vehicle:exited', {
                vehicleId = currentVehicleId,
                entity    = currentVehicle,
                plate     = currentVehicle and DoesEntityExist(currentVehicle) and GetVehicleNumberPlateText(currentVehicle) or nil,
                seat      = currentSeat,
            })
            -- The server announces its own `vehicle:exited` once it agrees.
            if currentVehicleId then
                TriggerServerEvent('whip_core:server:vehicleSeat', currentVehicleId, currentSeat or -1, false)
            end
            currentSeat = nil

            -- Save vehicle properties and position to the server, skipped while the car is being previewed.
            syncCurrentVehicle()

            lastReportedEngine = nil

            -- Hide vehicle HUD capsule
            SendNUIMessage({ action = 'hideVehicleHud' })

            -- Save player position on vehicle exit
            saveMyPosition()

            -- Ignition only: the glovebox is the reconcile's below (two writers of
            -- Inventory.activeVehicleStorage on one tick would race). Inventory.close does the whole close and
            -- releases the ignition session (Inventory.releaseVehicleStorage).
            if Inventory.activeVehicleStorage and Inventory.activeVehicleStorage.storageType == 'key'
               and not Inventory.activeVehicleStorage.admin then   -- an admin's view of another car's stays
                Inventory.close()
            end

            currentVehicle = nil
            currentVehicleId = nil
        end

        -- Live secondary-panel reconcile. Level-triggered: it compares what the panel should be against what it
        -- is every tick, so any cause of a seat change works and a request lost to the rate limiter retries.
        --
        -- Walked away from an open boot: the server (Stores.fromWire) refuses moves out of range, so the panel
        -- closes itself at the same distance. Trunk only; not an admin's view (no range for the 'admin' viewer).
        part = WhipCost.start()
        if Inventory.activeVehicleStorage and Inventory.activeVehicleStorage.storageType == 'trunk'
           and not Inventory.activeVehicleStorage.admin then
            local ent = getEntityForVehicleId(Inventory.activeVehicleStorage.vehicleId)
            if ent and DoesEntityExist(ent) then
                -- A metre of slack past the server's figure (vehicleKeepRange in stores.lua over Vehicles.trunkOpenRange).
                local keep = math.max(tonumber(Config.VehicleStorageKeepRange) or 5.0,
                                      (tonumber(Config.VehicleTrunkRange) or 2.5) + 3.0) - 1.0
                local d = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(ent))
                if d > keep then
                    StorageTrace(('trunk: closing — walked %.1fm away (keep %.1fm)'):format(d, keep))
                    UI.Notify('You moved away from the vehicle', 'info')
                    Inventory.close()
                end
            end
        end

        -- Runs outside the edge branches so it still converges when the two disagree.
        if Inventory.isSwappable and Inventory.isSwappable() then
            -- A glovebox drawn but not yet confirmed counts as having one (activeVehicleStorage is set from server
            -- payloads only).
            local haveGlovebox = (Inventory.activeVehicleStorage ~= nil
                                  and Inventory.activeVehicleStorage.storageType == 'glovebox')
                or optimisticStorageType == 'glovebox'
            -- Not for the dead (F2 is blocked, so they could not close it), a bicycle, or a car whose glovebox is off (hasStorage).
            local wantGlovebox = inVehicle and not PlayerIsDead and not isBicycle(currentVehicle)
                and hasStorage(currentVehicle --[[@as number]], 'glovebox')   -- in a car: set on entry

            if wantGlovebox and not haveGlovebox then
                if not swapPending and not swapDenied and not vehicleStoragePending
                   and GetGameTimer() - lastSwapRequest >= SWAP_DEBOUNCE_MS then
                    swapPending           = true
                    vehicleStoragePending = true
                    lastSwapRequest       = GetGameTimer()
                    -- 0, never currentVehicleId: the server resolves the vehicle from the seat, and a passenger
                    -- cannot resolve an id client-side.
                    TriggerServerEvent('whip_core:server:openVehicleStorage', 0, 'glovebox')

                    -- The same safety timeout as the manual opens (a rate-limited call gets no reply), guarded by
                    -- storageReqSeq.
                    storageReqSeq = storageReqSeq + 1
                    local myReq = storageReqSeq
                    SetTimeout(5000, function()
                        if storageReqSeq ~= myReq then return end
                        if not vehicleStoragePending and not swapPending then return end
                        print('[whip_core:vehicle] glovebox swap request timed out after 5s — '
                            .. 'the server never replied (dropped, rate-limited, or refused)')
                        -- Also logged for the operator (reportStorageStall).
                        TriggerServerEvent('whip_core:server:reportStorageStall', 'glovebox-swap')
                        -- Unanswered: the reconcile asks again after SWAP_DEBOUNCE_MS (abandonStorageRequest).
                        abandonStorageRequest(false)
                    end)
                end

            elseif haveGlovebox and not wantGlovebox then
                if Inventory.activeVehicleStorage then
                    -- No round trip on the way out: client/ground.lua keeps its data current.
                    -- The order is load-bearing, the reverse of the way in:
                    --   1. capture the real id before anything clears it (releasing with 0 would charge vehicle #1)
                    --   2. clear the global, or RefreshNUIGroundItems returns early and Nearby stays empty
                    --   3. swap the panel, then fill it
                    --   4. release last: move authorisation is viewer-set membership, so an early release leaves
                    --      a visible grid whose every drag fails
                    local id, kind = Inventory.activeVehicleStorage.vehicleId, Inventory.activeVehicleStorage.storageType
                    Inventory.setActiveVehicleStorage(nil)
                    SendNUIMessage({ action = 'swapSecondaryPanel', data = { toGround = true } })
                    if RefreshNUIGroundItems then RefreshNUIGroundItems() end
                    Inventory.releaseVehicleStorage(id, kind)
                else
                    -- Optimistic only (a panel drawn from memory, open unanswered): nothing to release, so take the
                    -- drawn panel back. A later confirmation is closed by the next tick through the branch above.
                    optimisticStorageType = nil
                    SendNUIMessage({ action = 'swapSecondaryPanel', data = { toGround = true } })
                    if RefreshNUIGroundItems then RefreshNUIGroundItems() end
                end
            end
        end

        -- One refusal per seating; standing up earns another attempt.
        if not inVehicle and swapDenied then swapDenied = false end
        WhipCost.stop('vehicles: in-car pass: boot and glovebox', part)
        part = WhipCost.start()

        -- The ignition's one input. Level-triggered, not hung off enter/exit edges (sliding across is neither).
        -- The id is part of the test: every branch reads ignitionHasKey[vId], so a car whose id has not landed
        -- is not active until the seated re-check above fills it in.
        if inVehicle and currentVehicleId and currentVehicle
           and DoesEntityExist(currentVehicle)
           and GetPedInVehicleSeat(currentVehicle, -1) == ped
        then
            ignitionActive, ignitionVeh = true, currentVehicle

            -- The ignition re-assert rides here (AssertIgnition).
            AssertIgnition(currentVehicle, currentVehicleId)
        else
            ignitionActive, ignitionVeh = false, nil
            HoldThrottle(nil)   -- out of the driver's seat: the throttle is nobody's to hold

            -- Reset only when not in a vehicle at all: standing up earns another "No key in ignition!".
            if not inVehicle then ignitionNotified = false end
        end

        -- An engine press held for a key that never came (ignitionComing's deadline) is asked again now, which says
        -- why. Out of the driver's seat, it is dropped.
        if heldIgnition then
            if not ignitionActive or currentVehicleId ~= heldIgnition.vId then
                heldIgnition = nil
            elseif GetGameTimer() >= (ignitionComing[heldIgnition.vId] or 0) then
                local held = heldIgnition
                heldIgnition = nil
                ignitionComing[held.vId] = nil
                RequestIgnition(held.want)
            end
        end
        WhipCost.stop('vehicles: in-car pass: ignition', part)

        -- The seat rules ride this wake (client/seats.lua), under pcall so a fault cannot stop this loop.
        part = WhipCost.start()
        if Seats then
            local ok, err = pcall(Seats.tick, ped, inVehicle)
            if not ok and not seatsTickFailed then
                seatsTickFailed = true
                print(('[whip_core:seats] the seat tick failed: %s'):format(tostring(err)))
            end
        end
        WhipCost.stop('vehicles: in-car pass: seat rules', part)

        -- The weapon lock off in a gun turret seat (WeaponLock, client/inventory.lua), on foot too. Under pcall.
        part = WhipCost.start()
        if WeaponLock then
            local ok, err = pcall(WeaponLock.tick, ped)
            if not ok and not weaponLockTickFailed then
                weaponLockTickFailed = true
                print(('[whip_core:weapons] the weapon lock tick failed: %s'):format(tostring(err)))
            end
        end
        WhipCost.stop('vehicles: in-car pass: weapon lock', part)

        wasInVehicle = inVehicle
        wasDriver = inVehicle and isDriver or false
        WhipCost.stop('vehicles: in or out, ignition, seats (5 a second)', cost)
        Wait(200)
    end
end)

-- Occupant tick (1 s, for everyone in the vehicle): keeps the panel live; only the driver writes back.
-- The stats are the server's; this only reads them.

--- Is the local player driving the vehicle they are in?
local function IsDriver()
    if not currentVehicle or not DoesEntityExist(currentVehicle) then return false end
    return GetPedInVehicleSeat(currentVehicle, -1) == PlayerPedId()
end

CreateThread(function()
    while true do
        Wait(1000)

        if not currentVehicle or not DoesEntityExist(currentVehicle) then
            goto continue
        end

        local cost = WhipCost.start()

        -- The safety net and the only poll: re-seeds from the entity once a second in case a change handler
        -- never arrives.
        SeedHudBlocks(currentVehicle)
        refreshVehicleHud()

        -- The driver keeps the local def's stats current, so the garage list reads right
        if IsDriver() then
            local d = currentVehicleId and vehicleDefs[currentVehicleId]
            if d and type(_hudBlocks.stats) == 'table' then
                if type(d.vehStats) ~= 'table' then d.vehStats = {} end
                for k, v in pairs(_hudBlocks.stats) do d.vehStats[k] = v end
            end
        end

        WhipCost.stop('vehicles: HUD re-seed (once a second)', cost)

        ::continue::
    end
end)

-- Engine control: scroll up starts the engine, scroll down stops it. Bound by key mappings, not polled. The
-- bindings read ignitionActive and ignitionVeh (200 ms occupant tick) and ignitionHasKey (filled by the server).

--- Act on a request to change the ignition, from any binding below. Does nothing on foot, in a passenger seat, or
--- in a car whose id has not landed.
---@param want 'on'|'off'|'toggle'
function RequestIgnition(want)   -- the local declared with the ignition state at the top
    -- The pad's toggle names its answer in /paddebug's log.
    local function padLog(what)
        if want == 'toggle' and WhipPadDebugFire then WhipPadDebugFire('bind', 'engine toggle', what) end
    end

    if not ignitionActive then return padLog('refused: not driving a car whip knows') end
    -- Not under a screen (scrolling a catalogue must not switch the engine).
    if not IsGameInputFree() then return padLog('refused: a screen or mode has the keys') end

    local veh = ignitionVeh
    local vId = currentVehicleId
    if not veh or veh == 0 then return padLog('refused: no vehicle') end
    -- A bicycle has no engine to switch.
    if isBicycle(veh) then return padLog('refused: a bicycle has no engine') end

    -- Scroll paths only ('on' and 'off') arm the weapon-wheel suppressor, as BindNav does; 'toggle' (D-pad left)
    -- cannot open a wheel.
    if want ~= 'toggle' and Inventory.suppressWeaponWheel then Inventory.suppressWeaponWheel() end

    if TakePlayer.on(veh) then return padLog('refused: a recorded drive has the car') end

    if not ignitionHasKey[vId] then
        -- No key. The toggle counts as an attempt too (the pad's only way to ask). An 'off' also takes back a held 'on'.
        if want == 'off' then heldIgnition = nil; return end

        -- Not yet (ignitionComing): held, run when the key state lands or refused at the deadline.
        local coming = ignitionComing[vId]
        if coming and GetGameTimer() < coming then
            heldIgnition = { vId = vId, want = want }
            return padLog('held: the key is on its way into the ignition')
        end

        if ignitionUnhacked[vId] then
            TriggerServerEvent('whip_core:server:attemptHackIgnition', vId)
        elseif not ignitionNotified then
            ignitionNotified = true
            UI.Notify('No key in ignition!', 'error')
        end
        return padLog('refused: no key in the ignition')
    end

    ignitionNotified = false   -- reset so it can notify again if the key is removed

    local turnOn
    if want == 'toggle' then turnOn = not engineOn else turnOn = (want == 'on') end
    if turnOn == engineOn then return end

    -- Held off by a resource (out of fuel...): said, every ask
    local held = turnOn and EngineHold(veh)
    if held then
        UI.Notify(held, 'error')
        return padLog('refused: ' .. held)
    end

    engineOn = turnOn
    SetIgnitionState(veh, turnOn, false)
    ReportEngine(turnOn)
    padLog(turnOn and 'engine on' or 'engine off')
end

-- The mouse wheel is directional (up starts, down stops); a D-pad direction toggles. IOM_WHEEL_UP/DOWN are
-- controls 16/17, not 14/15 (those are also the gamepad triggers). Every '+' command has its '-' half: an
-- unregistered release command falls through to chat.

RegisterCommand('+whip_ignition_on', function() RequestIgnition('on') end, false)
RegisterCommand('-whip_ignition_on', function() end, false)
RegisterKeyMapping('+whip_ignition_on', 'Vehicle: Engine On', 'MOUSE_WHEEL', 'IOM_WHEEL_UP')

RegisterCommand('+whip_ignition_off', function() RequestIgnition('off') end, false)
RegisterCommand('-whip_ignition_off', function() end, false)
RegisterKeyMapping('+whip_ignition_off', 'Vehicle: Engine Off', 'MOUSE_WHEEL', 'IOM_WHEEL_DOWN')

--- The toggle. On a pad it is D-pad left, read by client/pad.lua's reader, which runs this command.
--- Unbound on keyboard (Arrow Left is 189 too); a player can bind a key in Settings.
RegisterCommand('+whip_ignition_toggle', function() RequestIgnition('toggle') end, false)
RegisterCommand('-whip_ignition_toggle', function() end, false)
RegisterKeyMapping('+whip_ignition_toggle', 'Vehicle: Engine Toggle', 'keyboard', '')

-- To block the radio, call SetVehicleRadioEnabled(veh, false) once on entry, never a per-frame DisableControlAction.

-- Glovebox: opened via F2 in a vehicle (called from inventory.lua).

--- Attempt to open the glovebox for the current vehicle. Returns true if handled.
--- An in-flight request never blocks the UI: `vehicleStoragePending` debounces the request only, and the panel
--- opens from memory whenever asked (Inventory.confirmPanel matches on what is wanted).
function Vehicles.tryOpenGlovebox()
    -- Both early returns are traced: they look like "F2 did nothing". IsAnyUIOpen compounds seven flags
    -- (client/inventory.lua); one stuck true blocks everything.
    if IsAnyUIOpen() then
        StorageTrace('glovebox: suppressed — IsAnyUIOpen() is true (something is already open)')
        return true
    end

    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        StorageTrace('glovebox: not in a vehicle')
        return false
    end
    -- A bicycle has no glovebox: F2 is the plain inventory.
    if isBicycle(GetVehiclePedIsIn(ped, false)) then
        StorageTrace('glovebox: a bicycle has none — the plain inventory')
        return false
    end
    -- Nor one whose glovebox is off (Vehicle Adjustments).
    if not hasStorage(GetVehiclePedIsIn(ped, false), 'glovebox') then
        StorageTrace('glovebox: off for this vehicle — the plain inventory')
        return false
    end

    -- 0 means "whichever vehicle I am sitting in": the server reads the seat, so passengers work.
    local vId = currentVehicleId or 0

    -- Drawn before the ask, unconditionally, so the panel appears in the same frame as the keypress. Keyed on the
    -- id stamped on the car (the server resolves the seat from the same stamp), not on vId.
    drawVehicleStorage(Vehicles.idByEntity(GetVehiclePedIsIn(ped, false)), 'glovebox')

    -- Only the request is debounced, so a spammed key cannot flood the reliable event channel.
    if not vehicleStoragePending then
        vehicleStoragePending = true
        StorageTrace(('glovebox: sending (vehicleId %s, server reads the seat)'):format(tostring(vId)))
        TriggerServerEvent('whip_core:server:openVehicleStorage', vId, 'glovebox')

        -- Safety timeout (a rate-limited call gets no reply), guarded by storageReqSeq.
        storageReqSeq = storageReqSeq + 1
        local myReq = storageReqSeq
        SetTimeout(5000, function()
            if storageReqSeq ~= myReq or not vehicleStoragePending then return end
            print('[whip_core:vehicle] glovebox open timed out after 5s — the server never '
                .. 'replied (dropped, rate-limited, or refused)')
            TriggerServerEvent('whip_core:server:reportStorageStall', 'glovebox')
            -- Unanswered: nothing is owed to the server; take the drawn panel back (abandonStorageRequest).
            abandonStorageRequest(false)
        end)
    else
        -- Names a client whose debounce never cleared (the server's log cannot see it).
        StorageTrace('glovebox: SUPPRESSED — vehicleStoragePending is still true from an earlier '
            .. 'request that never resolved')
    end

    return true
end

-- Generic door helpers used by the door prompts, the boot and the bonnet.

--- Is this door currently open at all? Read from the car, so it agrees however the door was opened.
---@param entity number
---@param doorIndex number  0-3 doors, 4 bonnet, 5 boot
---@return boolean
function Vehicles.isDoorOpen(entity, doorIndex)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    return GetVehicleDoorAngleRatio(entity, doorIndex) > 0.0
end

-- Doors: the server owns them. SetVehicleDoorOpen is a local native (a non-owner's door is corrected shut a frame
-- later), so the client asks, the server writes a bitmask on the vehicle's state bag, and every client applies it
-- (VEHICLE_DOORS_KEY in shared/statebags.lua).

--- Move only the doors that disagree with the mask (re-asserting an open door restarts its animation).
---@param entity number
---@param mask number  bit N set = door N open
local function applyDoorMask(entity, mask)
    for i = 0, 7 do
        local wantOpen = (mask & (1 << i)) ~= 0
        local isOpen = GetVehicleDoorAngleRatio(entity, i) > 0.0
        if wantOpen ~= isOpen then
            if wantOpen then
                SetVehicleDoorOpen(entity, i, false, false)
            else
                SetVehicleDoorShut(entity, i, false)
            end
        end
    end
end

AddStateBagChangeHandler(VEHICLE_DOORS_KEY, nil, function(bagName, _, value)
    -- The car is here: apply the mask it was handed (handlers run in change order, so the newest wins).
    local entity = GetEntityFromStateBagName(bagName)
    if entity and entity ~= 0 and DoesEntityExist(entity) then
        applyDoorMask(entity, type(value) == 'number' and value or 0)
        return
    end
    -- The bag can arrive before the entity: the shared wait, then the bag is read again (the newest mask applies once).
    Vehicles.awaitBagEntity(bagName, VEHICLE_DOORS_KEY, function(arrived)
        local mask = Entity(arrived).state[VEHICLE_DOORS_KEY]
        applyDoorMask(arrived, type(mask) == 'number' and mask or 0)
    end)
end)

--- Ask the server to move a door. Not applied optimistically: on a car this client does not own a local change
--- is corrected back. The door moves once, for everybody, after the round trip.
---@param entity number
---@param doorIndex number  0-3 doors, 4 bonnet, 5 boot, 6/7 rear
---@param want string|nil   'open' | 'shut' | nil for toggle
function requestVehicleDoor(entity, doorIndex, want)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    -- A non-networked car (a scene's, a preview) has no server to ask: its door moves here, at once.
    if not NetworkGetEntityIsNetworked(entity) then
        local open = GetVehicleDoorAngleRatio(entity, doorIndex) > 0.0
        local wantOpen = want == 'open' or (want ~= 'shut' and not open)
        if wantOpen and not open then
            SetVehicleDoorOpen(entity, doorIndex, false, false)
        elseif not wantOpen and open then
            SetVehicleDoorShut(entity, doorIndex, false)
        end
        return
    end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId == 0 then return end
    TriggerServerEvent('whip_core:server:toggleVehicleDoor', netId, doorIndex, want or 'toggle')
end

--- Put a door up/open, or shut it if already open (bonnet is 4, boot 5). Fails quietly if the model has no such door.
---@param entity number
---@param doorIndex number
function Vehicles.toggleDoor(entity, doorIndex)
    requestVehicleDoor(entity, doorIndex, 'toggle')
end

--- Shut a door, and only shut it (a second press while it swings shut does not reopen it).
---@param entity number
---@param doorIndex number
function Vehicles.shutDoor(entity, doorIndex)
    requestVehicleDoor(entity, doorIndex, 'shut')
end

--- Open a door, and only open it (a second press while it swings open does not shut it).
---@param entity number
---@param doorIndex number
function Vehicles.openDoor(entity, doorIndex)
    requestVehicleDoor(entity, doorIndex, 'open')
end

-- The boot: one implementation for both ways in (the aim-target "Open Trunk" and View Trunk Inventory in
-- client/vehicle_prompts.lua). Here because it touches drawVehicleStorage, vehicleStoragePending and trunkDoorEntity.

--- Can this vehicle's boot be opened right now? Uses GTA's lock status (2 is locked), so it answers for any car.
---@param entity number
---@return boolean
function Vehicles.canOpenTrunk(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    -- `vehicleStoragePending` is not checked: a call lost to the rate limiter would hide the boot for five seconds.
    return GetVehicleDoorLockStatus(entity) ~= 2
end

--- Has this car a trunk (or glovebox) to look in at all (Vehicle Adjustments)? The lid works either way.
---@param entity number
---@param kind 'trunk'|'glovebox'
---@return boolean
---@diagnostic disable-next-line: duplicate-set-field -- the server's Vehicles is a different table
function Vehicles.hasStorage(entity, kind)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    return hasStorage(entity, kind)
end

--- Swing the boot open and put its contents on screen. View Trunk Inventory is offered only with the lid already
--- up, so only the aim-target "Open Trunk" swings the lid here (and shuts it again after).
---@param entity number
function Vehicles.openTrunk(entity)
    -- A non-networked car (a scene's) keeps nothing in its boot; the option still shows and picking it only says so.
    if DoesEntityExist(entity) and not NetworkGetEntityIsNetworked(entity) then
        UI.Notify('You can only open the trunk on non-scene vehicles', 'error')
        return
    end
    -- Open the trunk door (index 5), on a model that has one: a van's back doors are already open when this is
    -- offered (client/vehicle_prompts.lua). Only claim a lid we opened: `trunkDoorEntity` makes the watcher below
    -- shut it when the panel closes, which is wrong for a lid the player left up.
    if DoesEntityExist(entity) and GetIsDoorValid(entity, 5) and not Vehicles.isDoorOpen(entity, 5) then
        requestVehicleDoor(entity, 5, 'open')
        trunkDoorEntity = entity
    end
    -- Resolve vehicleId (registers NPC vehicle if needed)
    ---@type number|false|nil, string|nil
    local vId, why = Vehicles.idByEntity(entity), nil
    if not vId then
        vId, why = Vehicles.resolve(entity)
    end
    if not vId then
        -- No id means no request is sent and the server logs nothing: this line and the player's notice say so.
        StorageTrace(('trunk: could not resolve a vehicleId for entity %s — NOTHING SENT (%s)')
            :format(tostring(entity), tostring(why)))
        UI.Notify(why or 'Cannot identify vehicle', 'error', 2500)
        return
    end

    -- Drawn at once, like the glovebox.
    drawVehicleStorage(vId, 'trunk')

    -- Request debounced, panel not (see Vehicles.tryOpenGlovebox).
    if not vehicleStoragePending then
        vehicleStoragePending = true
        StorageTrace(('trunk: sending for vehicleId %s'):format(tostring(vId)))
        TriggerServerEvent('whip_core:server:openVehicleStorage', vId, 'trunk')
        -- Sequence-guarded; see storageReqSeq.
        storageReqSeq = storageReqSeq + 1
        local myReq = storageReqSeq
        SetTimeout(5000, function()
            if storageReqSeq ~= myReq or not vehicleStoragePending then return end
            print('[whip_core:vehicle] trunk open timed out after 5s — the server never replied '
                .. '(dropped, rate-limited, or refused)')
            TriggerServerEvent('whip_core:server:reportStorageStall', 'trunk')
            -- Unanswered: release the claimed boot and the optimistic panel (abandonStorageRequest).
            abandonStorageRequest(false)
        end)
    else
        -- Names a stuck client: the debounce never cleared and the server was never asked.
        StorageTrace('trunk: SUPPRESSED — vehicleStoragePending is still true from an earlier '
            .. 'request that never resolved')
    end
end

-- The bonnet is visual only: it stays up until put down, so it is a toggle and the prompt flips its label
-- (client/vehicle_prompts.lua).

--- Is the bonnet currently up?
---@param entity number
---@return boolean
function Vehicles.isHoodOpen(entity)
    return Vehicles.isDoorOpen(entity, 4)
end

--- Can this vehicle's bonnet be worked right now? Not when locked, as with the boot.
---@param entity number
---@return boolean
function Vehicles.canOpenHood(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    return GetVehicleDoorLockStatus(entity) ~= 2
end

--- Put the bonnet up, or back down if it is already up. Door 4 is the bonnet, as door 5 is the boot.
---@param entity number
function Vehicles.toggleHood(entity)
    Vehicles.toggleDoor(entity, 4)
end

-- Locks and lockpicking: one implementation for the aim-target menu and the door circle. None of these decide
-- anything; the lock toggle and lockpick are server events that re-run their own authorization.

--- Is this vehicle locked, by GTA's reckoning (2 is locked)? Answers for any car.
---@param entity number
---@return boolean
---@diagnostic disable-next-line: duplicate-set-field -- the server's Vehicles is a different table
function Vehicles.isLocked(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    return GetVehicleDoorLockStatus(entity) == 2
end

--- whip's id for this vehicle entity, or nil. For the world prompts in client/vehicle_prompts.lua. Resolves
--- nothing (see Vehicles.startLockpick).
---@param entity number
---@return number|nil
function Vehicles.idFor(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return Vehicles.idByEntity(entity)
end

--- Does the player hold a key for this vehicle?
---@param entity number
---@return boolean
---@diagnostic disable-next-line: duplicate-set-field -- the server's Vehicles is a different table
function Vehicles.playerHasKey(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    local vId = Vehicles.idByEntity(entity)
    return vId ~= nil and HasKeyForVehicle(vId)
end

--- Lock or unlock, if the player has a key. Does not resolve an unknown vehicle.
---@param entity number
function Vehicles.toggleLock(entity)
    local vId = Vehicles.idByEntity(entity)
    if not vId then return end
    PlayKeyFobAnim()
    -- The same event as the L key, so the server's checks apply identically.
    TriggerServerEvent('whip_core:server:toggleVehicleLock', vId)
end

--- Is picking this lock a thing that could happen right now?
---@param entity number
---@return boolean
function Vehicles.canLockpick(entity)
    if not Vehicles.isLocked(entity) then return false end
    return Inventory.hasItemFlag('lockpick')
end

--- Ask the server to start a lockpick attempt. The item check above is courtesy; the server verifies the item and
--- judges the skill check.
---@param entity number
function Vehicles.startLockpick(entity)
    if not DoesEntityExist(entity) then return end
    -- Resolved here, unlike the lock toggle: an unknown NPC vehicle is the expected case.
    ---@type number|false|nil, string|nil
    local vId, why = Vehicles.idByEntity(entity), nil
    if not vId then
        vId, why = Vehicles.resolve(entity)
    end
    if not vId then
        UI.Notify(why or 'Cannot identify vehicle', 'error', 2500)
        return
    end

    TaskTurnPedToFaceEntity(PlayerPedId(), entity, 500)
    TriggerServerEvent('whip_core:server:attemptLockpick', vId)
end

-- Shut the boot Vehicles.openTrunk opened, once its panel closes

CreateThread(function()
    while true do
        if trunkDoorEntity then
            -- A boot drawn but not yet confirmed still counts as open.
            if not vehicleStoragePending
               and optimisticStorageType ~= 'trunk'
               and (not Inventory.activeVehicleStorage or Inventory.activeVehicleStorage.storageType ~= 'trunk') then
                if DoesEntityExist(trunkDoorEntity) then
                    requestVehicleDoor(trunkDoorEntity, 5, 'shut')
                end
                trunkDoorEntity = nil
            end
        end
        Wait(200)
    end
end)

-- Lockpick and hacked key skill checks are client/items/*.lua (self-contained item files).

-- Cleanup on resource stop

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        -- Sync properties before cleanup.
        syncCurrentVehicle()
        SendNUIMessage({ action = 'hideVehicleHud' })
        Inventory.setActiveVehicleStorage(nil)
        ignitionHasKey = {}
        ignitionUnhacked = {}
        engineOn = false
        -- Remove garage blips
        for _, blip in pairs(garageBlips) do
            if DoesBlipExist(blip) then RemoveBlip(blip) end
        end
        garageBlips = {}

        -- No vehicles to delete: they belong to the server, which is still running.
    end
end)

-- Client exports: vehicle API

--- Get vehicleId from entity (cache-only, no server round-trip).
--- Returns vehicleId or nil. Safe in a prompt's canInteract.
exports('GetVehicleId', function(entity)
    -- `{ entity = veh }` is taken too. A bare number here is the entity (this is the entity-to-id call).
    if type(entity) == 'table' then entity = entity.entity end
    return Vehicles.idByEntity(entity)
end)

--- The other direction: the entity for a vehicleId, or nil when that car is not streamed in here.
exports('GetVehicleEntity', function(vehicleId)
    -- A vehicle reference works too; a bare number is a vehicleId.
    local entity = Vehicles.refEntity(vehicleId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return entity
end)

--- Does the player have a key for this car? A vehicleId or a vehicle reference, from the key cache. `{ plate = }` reads
--- the cache by plate, so a car that is not streamed in here is found too.
exports('HasVehicleKey', function(ref)
    if type(ref) == 'table' and ref.plate ~= nil then return hasKeyForPlate(ref.plate) end
    return HasKeyForVehicle(vehicleRefId(ref))
end)

--- Resolve a vehicle entity to a vehicleId, registering it as a session vehicle if it is not one already.
--- Blocks only for a vehicle whip has never seen, so do not call it from a prompt's canInteract (use GetVehicleId).
--- Answers the vehicleId, or `false, why`.
---@return number|false vehicleId
---@return string|nil why
function Vehicles.resolve(entity)
    if type(entity) == 'table' then entity = entity.entity end   -- `{ entity = veh }` too
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false, 'That vehicle is not there' end
    if not IsEntityAVehicle(entity) then return false, 'That is not a vehicle' end

    -- Fast path: the entity already knows.
    local existingId = Vehicles.idByEntity(entity)
    if existingId then return existingId end

    local plate = GetVehicleNumberPlateText(entity)
    if not plate or plate == '' then return false, 'That vehicle has no plate' end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId <= 0 then return false, 'That vehicle is not networked' end

    local vehicleId, why = Callback('whip_core:resolveVehicle', plate, VehicleModelName(entity), netId, GetVehicleType(entity))
    if not vehicleId then return false, why or 'That vehicle could not be identified' end

    -- No local cache to write: the server stamped the entity.
    return vehicleId
end
exports('ResolveVehicle', Vehicles.resolve)

--- Everything this client knows about a vehicle: every occupant including ambient peds, live damage and colours.
--- It cannot see ownership, the garage, or an unstreamed vehicle; unknown fields are absent. Needs a vehicleId.
---@param vehicleId number
---@return table|nil
local function BuildVehicleContext(vehicleId)
    if not vehicleId then return nil end

    local entity = getEntityForVehicleId(vehicleId)
    if not entity then
        -- Not streamed in here: say so rather than return a table of nils.
        return nil
    end

    local modelHash = GetEntityModel(entity)
    local colorPrimary, colorSecondary = GetVehicleColours(entity)

    -- Every seat, including ambient peds (the server half cannot see them).
    local occupants = {}
    local maxSeats = GetVehicleMaxNumberOfPassengers(entity)
    for seat = -1, maxSeats - 1 do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped and ped ~= 0 then
            local occupant = { seat = seat, ped = ped, isPlayer = false }
            if IsPedAPlayer(ped) then
                local idx = NetworkGetPlayerIndexFromPed(ped)
                if idx and idx >= 0 then
                    -- The server id only; GetPlayerFullName(serverId) gives the name.
                    occupant.isPlayer = true
                    occupant.serverId = GetPlayerServerId(idx)
                end
            end
            occupants[#occupants + 1] = occupant
        end
    end

    -- Both blocks, one accessor (one bag read).
    local stats, live = GetVehicleStatBlocks(entity)

    -- vehicleDefs only holds this player's own vehicles: it answers "is it mine?".
    local mine = vehicleDefs[vehicleId]

    return {
        vehicleId   = vehicleId,
        entity      = entity,
        netId       = NetworkGetNetworkIdFromEntity(entity),
        plate       = GetVehicleNumberPlateText(entity),
        model       = VehicleModelName(entity),
        modelHash   = modelHash,
        class       = GetVehicleClass(entity),
        vehType     = GetVehicleType(entity),
        session     = Entity(entity).state[VEHICLE_SESSION_KEY] == true,

        mine        = mine ~= nil,
        hasKey      = vehicleKeys[vehicleId] ~= nil,

        -- ignitionHasKey is only sent to the driver, so it is absent unless we are in this vehicle.
        keyInIgnition = (currentVehicleId == vehicleId) and (ignitionHasKey[vehicleId] == true) or nil,

        coords      = GetEntityCoords(entity),
        heading     = GetEntityHeading(entity),

        locked        = GetVehicleDoorLockStatus(entity) == 2,
        engineOn      = GetIsVehicleEngineRunning(entity) == true,
        bodyHealth    = GetVehicleBodyHealth(entity),
        engineHealth  = GetVehicleEngineHealth(entity),
        colorPrimary  = colorPrimary,
        colorSecondary = colorSecondary,

        occupants = occupants,

        -- Defaults filled in (the block holds only what the car carries), as a copy; both keys, so a live stat
        -- reads at its current value.
        stats     = ResolveAllVehicleStats(stats, live),

        -- Data a resource has attached (not stats, mods or storage): a copy, always a table.
        data      = (function()
            local block = Entity(entity).state[VEHICLE_DATA_KEY]
            local copy = {}
            if type(block) == 'table' then
                for k, v in pairs(block) do copy[k] = v end
            end
            return copy
        end)(),
    }
end

--- Everything this client knows about a vehicle: the client half of the server's GetVehicle, same shape but
--- less data (no owner name, no stored row). By its id, or by a reference that says what you hold (ids and
--- entity handles are plain integers in overlapping ranges, so a bare number is always a vehicleId):
---
---     exports.whip_core:GetVehicle({ entity = veh })
---     exports.whip_core:GetVehicle({ plate = 'ABC123' })   -- a car streamed in near you
---     exports.whip_core:GetVehicle({ netId = netId })
---
--- A far car returns nil here; ask the server.
---@param ref number|table|nil  a vehicleId, or { id = }, { entity = }, { plate = }, { netId = }
---@return table|nil
function Vehicles.get(ref)
    local vehicleId = vehicleRefId(ref)
    if not vehicleId then return nil end
    return BuildVehicleContext(vehicleId)
end
exports('GetVehicle', function(ref) return Vehicles.get(ref) end)

--- Get all vehicles within a radius, sorted by distance (closest first).
--- Returns array of { entity, plate, vehicleId, distance, model }.
exports('GetNearbyVehicles', function(radius)
    radius = radius or 25.0
    if radius > 100.0 then radius = 100.0 end
    local results = {}
    local myPos = GetEntityCoords(PlayerPedId())
    local vehicles = GetGamePool('CVehicle')
    for _, veh in ipairs(vehicles) do
        local pos = GetEntityCoords(veh)
        local dist = #(myPos - pos)
        if dist <= radius then
            results[#results + 1] = {
                entity    = veh,
                plate     = GetVehicleNumberPlateText(veh),
                vehicleId = Vehicles.idByEntity(veh),
                distance  = dist,
                model     = GetDisplayNameFromVehicleModel(GetEntityModel(veh)):lower(),
            }
        end
    end
    table.sort(results, function(a, b) return a.distance < b.distance end)
    return results
end)

-- Radial menu: the built-in vehicle options, registered through the public API. Each reuses control code in this file.

--- Toggle the engine through the ignition system (it re-asserts from `engineOn`, so a direct native call would
--- be undone), with the same key check as the scroll path.
local function RadialToggleEngine()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return end

    -- Driver only: a passenger's engineOn is not maintained.
    if GetPedInVehicleSeat(veh, -1) ~= ped then
        UI.Notify('You are not in the driver seat', 'error')
        return
    end

    if TakePlayer.on(veh) then
        UI.Notify('The Scripted Driving Event has the engine until it is over', 'info')
        return
    end

    local vId = Vehicles.idByEntity(veh)
    if vId and not ignitionHasKey[vId] then
        UI.Notify('No key in ignition!', 'error')
        return
    end

    -- Toggle from what the vehicle is actually doing, not our copy. Through SetIgnitionState, which sets `instantly`
    -- on a stop. Driveable either way: the key is in.
    local turnOn = not GetIsVehicleEngineRunning(veh)
    local held = turnOn and EngineHold(veh)
    if held then
        UI.Notify(held, 'error')
        return
    end
    engineOn = turnOn
    SetIgnitionState(veh, engineOn, false)
    ReportEngine(engineOn)
end

--- Register the built-ins on whip_core:onReady (this file loads before radial.lua). Idempotent: the group is
--- cleared first. WhipRadialAddOption is the in-state global; a satellite uses AddAction (`at = { radial = true }`).
--- The owner falls back to whip_core, so these are never culled when another resource stops.
local function RegisterVehicleRadialOptions()
    WhipRadialRemoveGroup('vehicle')

    local inVehicle = function()
        return IsPedInAnyVehicle(PlayerPedId(), false)
    end

    WhipRadialAddOption({
        label = 'Engine',
        icon = 'power',
        description = 'Start or stop the engine',
        group = 'vehicle',
        -- Not on a bicycle: it has none (isBicycle).
        condition = function()
            return inVehicle() and not isBicycle(GetVehiclePedIsIn(PlayerPedId(), false))
        end,
        callback = RadialToggleEngine,
    })

    WhipRadialAddOption({
        label = 'Lock / Unlock',
        icon = 'lock',
        description = 'Lock or unlock this car',
        group = 'vehicle',
        condition = inVehicle,
        callback = function()
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh == 0 then return end
            local vId = Vehicles.idByEntity(veh)
            if not vId then return end
            -- The same event as the L key.
            TriggerServerEvent('whip_core:server:toggleVehicleLock', vId)
        end,
    })

    WhipRadialAddOption({
        label = 'Headlights',
        icon = 'headlights',
        description = 'Lights on or off',
        group = 'vehicle',
        condition = inVehicle,
        callback = function()
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh == 0 then return end
            -- GetVehicleLightsState returns (ok, lightsOn, highbeamsOn); lightsOn is 1 or 0 (both truthy), so
            -- compare. 3 and 4 switch the lights on and off the way the H key does, without forcing them.
            local _, lightsOn = GetVehicleLightsState(veh)
            local lit = lightsOn == 1 or lightsOn == true
            SetVehicleLights(veh, lit and 4 or 3)
        end,
    })

    -- The Seats page (client/seats.lua): the wheel stays up and shows every seat; pick one to move.
    WhipRadialAddOption({
        label = 'Seats',
        icon = 'seat',
        description = 'See the seats and move to a free one',
        group = 'vehicle',
        condition = inVehicle,
        keepOpen = true,
        callback = function() Seats.openPage() end,
    })

    WhipRadialAddOption({
        label = 'Boot',
        icon = 'trunk_lid',
        description = 'Open or shut the boot',
        group = 'vehicle',
        condition = inVehicle,
        callback = function()
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if veh == 0 then return end
            -- Door 5 is the boot, opened visually only (the storage is the trunk panel).
            if GetVehicleDoorAngleRatio(veh, 5) > 0.0 then
                requestVehicleDoor(veh, 5, 'shut')
            else
                requestVehicleDoor(veh, 5, 'open')
            end
        end,
    })
end

-- The event covers the normal path and a whip_core restart; once per whip_core start.
AddEventHandler('whip_core:onReady', function(info)
    if type(info) == 'table' and info.reason ~= 'coreStarted' then return end
    RegisterVehicleRadialOptions()
end)
