-- Vehicle data, client side: the read side of server/vehicle_data.lua (json-encodable data a resource attached
-- to a vehicle). Read only, since a value a client could write is one a modified client could invent.
-- Same accessors as client/vehicle_stats.lua; an absent key means the car does not carry it.

--- The vehicle entity an export was handed, or nil when it is not a vehicle that exists.
--- A bare number is a vehicleId; an entity is `{ entity = veh }`. Never a guess (see resolveEntity in
--- client/vehicle_stats.lua): the ranges overlap, so a despawned car's handle could read another car's data.
---@param entity any
---@return number|nil
local function resolveEntity(entity)
    entity = Vehicles.refEntity(entity)
    if type(entity) ~= 'number' or entity == 0 then return nil end
    if DoesEntityExist(entity) and GetEntityType(entity) == 2 then return entity end
    return nil
end

--- The whole data block off an entity, or nil.
---@param entity number|nil
---@return table|nil
local function blockOf(entity)
    if not entity then return nil end
    local block = Entity(entity).state[VEHICLE_DATA_KEY]
    return type(block) == 'table' and block or nil
end

--- Read one value off a vehicle. No default, unlike a stat: nil means the car does not carry it. With no key,
--- everything it carries, as a copy (changing it replicates nothing).
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@param key string|nil
---@return any
exports('GetVehicleData', function(vehicle, key)
    if key == nil then
        local all = blockOf(resolveEntity(vehicle))
        local copy = {}
        for k, v in pairs(all or {}) do copy[k] = v end
        return copy
    end
    if type(key) ~= 'string' then return nil end
    local block = blockOf(resolveEntity(vehicle))
    if not block then return nil end

    -- As stored, false included.
    return block[key]
end)

-- Change notification

--- [key] = { ['<resource>:<id>'] = { fn, owner } }. Keyed so an onReady re-registration replaces rather than stacks.
local _listeners = {}

--- Last seen block per vehicle id, so a change can report what it replaced: [vehicleId] = { entity, block }.
--- Pruned by the sweep below once the entity is gone or carries another car (handles are reused).
local _previous = {}

--- Call one listener in the shape it registered for: positional `(vehicleId, value, old, entity)`, or one table.
local function callDataListener(reg, key, vehicleId, value, old, entity)
    local ok, err
    if reg.asTable then
        ok, err = pcall(reg.fn, {
            vehicleId = vehicleId, key = key, value = value, old = old,
            cleared = value == nil, entity = entity,
        })
    else
        ok, err = pcall(reg.fn, vehicleId, value, old, entity)
    end
    if not ok then
        print(('[whip_core:vehdata] listener for "%s" errored: %s'):format(key, tostring(err)))
    end
end

-- Watchers (WatchVehicleData)
-- The data twin of WatchVehicleStat (client/vehicle_stats.lua), for things every client must apply to a car
-- itself because GTA replicates none of them (engine sound, wheel stance, handling). Declared above the
-- change handler, which feeds them.

local _watchers = {}   -- [key] = { [watcherId] = watcher }
local _holders  = {}   -- [key] = { [entity] = { value, vehicleId } }

--- Same contents, comparing tables key by key. The bag hands over a fresh table on every replication, so
--- identity would report "changed" when other keys moved (and re-applying an engine sound resets the radio).
local function sameValue(a, b, depth)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    depth = (depth or 0) + 1
    if depth > 8 then return false end
    for k, v in pairs(a) do
        if not sameValue(v, b[k], depth) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Call one watcher callback; an error must not stop the others.
local function fireWatch(w, key, which, ...)
    local fn = w[which]
    if fn == nil then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        print(('[whip_core:vehdata] %s for "%s" errored: %s'):format(which, key, tostring(err)))
    end
end

--- The car this player is driving, or 0.
local function drivenVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 and GetPedInVehicleSeat(veh, -1) ~= ped then return 0 end
    return veh
end

--- One entity's value for `key` has gone from `was` (a holder or nil) to `now` (a value or nil):
--- tell every watcher of the key, and move the holder.
local function holderMoved(key, entity, vehicleId, was, now)
    local watchers = _watchers[key]
    local holders = _holders[key]
    if not watchers or not holders then return end

    if now ~= nil and was == nil then
        holders[entity] = { value = now, vehicleId = vehicleId }
        for _, w in pairs(watchers) do fireWatch(w, key, 'onGained', entity, now, vehicleId) end
        -- onStart is the sweep's to fire (it knows who is driving).
    elseif now == nil and was ~= nil then
        holders[entity] = nil
        for _, w in pairs(watchers) do
            if w.active[entity] then
                w.active[entity] = nil
                fireWatch(w, key, 'onStop', entity, was.value, was.vehicleId)
            end
            fireWatch(w, key, 'onLost', entity, was.value, was.vehicleId)
        end
    elseif now ~= nil and not sameValue(now, was.value) then
        local old = was.value
        holders[entity] = { value = now, vehicleId = vehicleId }
        for _, w in pairs(watchers) do
            -- A new value while held: onChanged if present; otherwise onLost(old) then onGained(new).
            if w.onChanged ~= nil then
                fireWatch(w, key, 'onChanged', entity, now, old, vehicleId)
            else
                fireWatch(w, key, 'onLost', entity, old, vehicleId)
                fireWatch(w, key, 'onGained', entity, now, vehicleId)
            end
            -- onStart's setup is torn down and redone for the new value.
            if w.active[entity] then
                fireWatch(w, key, 'onStop', entity, old, vehicleId)
                fireWatch(w, key, 'onStart', entity, now, vehicleId)
            end
        end
    end
end

--- Fold one car's replicated block into the holders of every watched key.
local function updateHolders(entity, vehicleId, block)
    for key, holders in pairs(_holders) do
        holderMoved(key, entity, vehicleId, holders[entity], block[key])
    end
end

--- One data-block change, for an entity that exists: tell every listener whose key moved.
---@param entity number
---@param value table
---@param knownId number|nil  the car's whip id, when the caller has it
local function onDataBlock(entity, value, knownId)
    -- Vehicles.idByEntity's cached map, not the bag: this fires for every streamed vehicle.
    local vehicleId = knownId or Vehicles.idByEntity(entity)
    if not vehicleId then
        -- The data can land before the id: come back when the id is stamped (Vehicles.awaitBagId).
        Vehicles.awaitBagId(entity, VEHICLE_DATA_KEY, function(id)
            local block = Entity(entity).state[VEHICLE_DATA_KEY]
            onDataBlock(entity, type(block) == 'table' and block or {}, id)
        end)
        return
    end
    Vehicles.awaitBagId(entity, VEHICLE_DATA_KEY, nil)

    if next(_holders) ~= nil then updateHolders(entity, vehicleId, value) end
    if next(_listeners) == nil then return end

    -- A car that streamed back in is a new entity and announces everything (GTA replicates none of it).
    local seen = _previous[vehicleId]
    local prev = (seen and seen.entity == entity) and seen.block or {}

    for key, listeners in pairs(_listeners) do
        local now, old = value[key], prev[key]

        -- Only scalars are diffed; anything else is announced on every replication and the listener decides.
        local changed
        if type(now) == 'table' or type(old) == 'table' then
            changed = true
        else
            changed = now ~= old
        end

        if changed and (now ~= nil or old ~= nil) then
            for _, reg in pairs(listeners) do
                -- pcall'd inside: one bad callback must not stop the others.
                callDataListener(reg, key, vehicleId, now, old, entity)
            end
        end
    end

    local snapshot = {}
    for k, v in pairs(value) do snapshot[k] = v end
    _previous[vehicleId] = { entity = entity, block = snapshot }
end

AddStateBagChangeHandler(VEHICLE_DATA_KEY, nil, function(bagName, _, value)
    if next(_listeners) == nil and next(_holders) == nil then return end   -- nobody listening; do no work
    if type(value) ~= 'table' then value = {} end

    local entity = GetEntityFromStateBagName(bagName)
    if entity and entity ~= 0 then
        onDataBlock(entity, value)
        return
    end

    -- The bag can arrive before the car: wait, then read the bag (see Vehicles.awaitBagEntity).
    Vehicles.awaitBagEntity(bagName, VEHICLE_DATA_KEY, function(arrived)
        local current = Entity(arrived).state[VEHICLE_DATA_KEY]
        onDataBlock(arrived, type(current) == 'table' and current or {})
    end)
end)

-- Drop the last-seen block of every car that left this client (or whose handle now belongs to another car).
CreateThread(function()
    while true do
        Wait(60000)
        for vehicleId, seen in pairs(_previous) do
            if not DoesEntityExist(seen.entity) or Vehicles.idByEntity(seen.entity) ~= vehicleId then
                _previous[vehicleId] = nil
            end
        end
    end
end)

--- Be told when a piece of vehicle data changes, on any vehicle streamed to this client.
---
---     exports.whip_core:OnVehicleDataChanged('kitDistances', function(vehicleId, value)
---         ...
---     end)
---
--- Keyed `<your resource>:<id>`, `id` defaulting to the data key: registering again replaces rather than
--- stacks. Cleared when your resource stops. Options (third or fourth argument), as on the server:
---   * `table = true`: one table (change.vehicleId, key, value, old, cleared, entity).
---   * `now = true`: also called once straight away for every car in range carrying the key.
---@param key string
---@param callback fun(vehicleId: number, value: any, old: any, entity: number)
---@param id string|nil
---@param opts table|nil  { table?: boolean, now?: boolean }
---@return boolean registered
exports('OnVehicleDataChanged', function(key, callback, id, opts)
    -- `callback ~= nil`, not a type check: an exported callback arrives as a callable, not a Lua 'function'.
    -- Listeners are pcall'd when they fire. Refusals answer `false, why`.
    if type(key) ~= 'string' or key == '' then return false, 'key is required (a vehicle data key)' end
    if callback == nil then return false, 'callback is required' end
    if type(id) == 'table' and opts == nil then id, opts = nil, id end
    opts = type(opts) == 'table' and opts or {}

    local owner = GetInvokingResource() or GetCurrentResourceName()
    if not _listeners[key] then _listeners[key] = {} end
    local regKey = owner .. ':' .. tostring(id or key)
    local reg = { fn = callback, owner = owner, asTable = opts.table == true }
    _listeners[key][regKey] = reg

    -- `now`: every car in range carrying the key, once, after registration returns.
    if opts.now then
        CreateThread(function()
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                local block = blockOf(veh)
                local vehicleId = block and Vehicles.idByEntity(veh)
                local list = _listeners[key]
                if vehicleId and block and block[key] ~= nil and list and list[regKey] == reg then
                    callDataListener(reg, key, vehicleId, block[key], nil, veh)
                end
            end
        end)
    end

    return true
end)

AddEventHandler('onResourceStop', function(res)
    for key, listeners in pairs(_listeners) do
        for regKey, reg in pairs(listeners) do
            if reg.owner == res then listeners[regKey] = nil end
        end
        if next(listeners) == nil then _listeners[key] = nil end
    end
end)

-- WatchVehicleData: the sweep and the exports

--- How often (ms) the sweep looks for cars that have left, and at who is driving. A car leaving scope fires no
--- bag event, so this is how onLost/onStop hear about it.
local DATA_WATCH_MS = 200

CreateThread(function()
    while true do
        if next(_watchers) == nil then
            Wait(1000)
        else
            local cost = WhipCost.start()
            local driving = drivenVehicle()
            for key, watchers in pairs(_watchers) do
                local holders = _holders[key] or {}

                -- Gone, or the handle belongs to another car now.
                for entity, h in pairs(holders) do
                    if not DoesEntityExist(entity) or Vehicles.idByEntity(entity) ~= h.vehicleId then
                        holderMoved(key, entity, h.vehicleId, h, nil)
                    end
                end

                for _, w in pairs(watchers) do
                    if w.onStart ~= nil or w.onStop ~= nil then
                        -- Stop what no longer qualifies: the car lost the key, or the player stopped driving it.
                        for entity in pairs(w.active) do
                            local h = holders[entity]
                            if not h or (w.driverOnly and entity ~= driving) then
                                w.active[entity] = nil
                                fireWatch(w, key, 'onStop', entity, h and h.value, h and h.vehicleId)
                            end
                        end
                        -- Start what now does.
                        if w.driverOnly then
                            local h = driving ~= 0 and holders[driving]
                            if h and not w.active[driving] then
                                w.active[driving] = true
                                fireWatch(w, key, 'onStart', driving, h.value, h.vehicleId)
                            end
                        else
                            for entity, h in pairs(holders) do
                                if not w.active[entity] then
                                    w.active[entity] = true
                                    fireWatch(w, key, 'onStart', entity, h.value, h.vehicleId)
                                end
                            end
                        end
                    end
                end
            end
            WhipCost.stop('vehicle data: watchers (start, stop, lost cars)', cost)
            Wait(DATA_WATCH_MS)
        end
    end
end)

--- Run code while a vehicle in scope carries a piece of data (the data twin of WatchVehicleStat).
---
---     exports.whip_core:WatchVehicleData('engine', {
---         onGained   = function(entity, value, vehicleId) ... end,        -- every car in scope
---         onChanged  = function(entity, value, old, vehicleId) ... end,   -- a new value while held
---         onLost     = function(entity, value, vehicleId) ... end,        -- the key went, or the car did
---         onStart    = function(entity, value, vehicleId) ... end,        -- with driverOnly: you got in
---         onStop     = function(entity, value, vehicleId) ... end,        --   ...and got out
---         driverOnly = true,
---     })
---
--- The same two pairs as WatchVehicleStat:
---   onGained / onChanged / onLost  every car in scope carrying the key, whoever is in it (a sound, a wheel
---                                  offset). Cars already in scope are announced at once.
---   onStart / onStop               this watcher's own car. With `driverOnly`, only the car this player is
---                                  driving. A new value fires onStop(old) then onStart(new).
--- Without onChanged, a new value fires onLost(old) then onGained(new). Values are compared by content, so a
--- car whose other data moved does not re-fire.
--- whip_core stopping and your own resource stopping reach no onStop: put things back in Whip.onCoreLost and
--- your onResourceStop.
--- Registering again with the same key and `id` (default: the key) replaces, onStop and all.
--- A refusal is `false, why`, since an export's answer is cut at its first nil.
---@param key string
---@param data table { onGained?, onChanged?, onLost?, onStart?, onStop?, driverOnly?, id? }
---@return string|false watcherId, string|nil why
local function watchData(owner, key, data)
    if type(key) ~= 'string' or key == '' then return false, 'key is required (a vehicle data key)' end
    if type(data) ~= 'table' then return false, 'data must be a table of callbacks' end
    if data.onGained == nil and data.onChanged == nil and data.onLost == nil
       and data.onStart == nil and data.onStop == nil then
        return false, 'give at least one of onGained, onChanged, onLost, onStart, onStop'
    end

    local id = ('%s:%s'):format(owner, tostring(data.id or key))

    local old = _watchers[key] and _watchers[key][id]
    if old then
        for entity in pairs(old.active) do
            local h = _holders[key] and _holders[key][entity]
            fireWatch(old, key, 'onStop', entity, h and h.value, h and h.vehicleId)
        end
    end

    local w = {
        owner = owner,
        onGained = data.onGained, onChanged = data.onChanged, onLost = data.onLost,
        onStart = data.onStart, onStop = data.onStop,
        driverOnly = data.driverOnly == true,
        active = {},
    }
    _watchers[key] = _watchers[key] or {}
    _watchers[key][id] = w

    -- Seed from the world once per key: an unchanging car in scope is never announced by the bag handler.
    if not _holders[key] then
        local holders = {}
        _holders[key] = holders
        for _, veh in ipairs(GetGamePool('CVehicle')) do
            local block = blockOf(veh)
            local vehicleId = block and block[key] ~= nil and Vehicles.idByEntity(veh)
            if vehicleId and block then holders[veh] = { value = block[key], vehicleId = vehicleId } end
        end
    end

    -- Announce what is out there, so onGained is the only place to set up.
    for entity, h in pairs(_holders[key]) do
        fireWatch(w, key, 'onGained', entity, h.value, h.vehicleId)
    end

    return id
end

exports('WatchVehicleData', function(key, data)
    return watchData(Registry.caller(), key, data)   -- the caller first, before anything can yield
end)

--- WatchVehicleData for whip_core's own files, without an export call (client/npcs.lua: the cars NPCs can stand on).
VehicleData = {
    watch = function(key, data) return watchData(GetCurrentResourceName(), key, data) end,
}

--- Stop one of your data watchers. Fires onStop for anything it had started, not onLost.
exports('UnwatchVehicleData', function(watcherId)
    local owner = Registry.caller()
    if type(watcherId) ~= 'string' then return false end
    for key, watchers in pairs(_watchers) do
        local w = watchers[watcherId]
        if w and w.owner == owner then
            for entity in pairs(w.active) do
                local h = _holders[key] and _holders[key][entity]
                fireWatch(w, key, 'onStop', entity, h and h.value, h and h.vehicleId)
            end
            watchers[watcherId] = nil
            if next(watchers) == nil then
                _watchers[key] = nil
                _holders[key] = nil
            end
            return true
        end
    end
    return false
end)

-- A stopped resource's watchers go without callbacks: its functions are going with it.
AddEventHandler('onResourceStop', function(res)
    for key, watchers in pairs(_watchers) do
        for id, w in pairs(watchers) do
            if w.owner == res then watchers[id] = nil end
        end
        if next(watchers) == nil then
            _watchers[key] = nil
            _holders[key] = nil
        end
    end
end)
