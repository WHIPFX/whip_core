-- Vehicle stats, client side: satellites react to server-registered vehicle stats here, e.g.
--     exports.whip_core:OnVehicleStatChange('nos', function(vehicleId, value, old, entity) ... end)
-- Pushed by statebag handlers for every vehicle streamed to this client.

-- [statName] = { ['<resource>:<id>'] = callback }. Keyed so registering twice from one resource replaces
-- (whip_core:onReady fires again on every other resource's start).
local _changeListeners = {}
local _previous        = {}     -- [entity] = { vehicleId, stats = last seen stat table }, for computing `old`

--- Watchers, and who currently carries what: `_holders[name][entity] = value` for every vehicle in scope, kept by
--- the change handler so no one reads the statebag per frame. Watcher ids are '<resource>:<id>'.
local _watchers      = {}       -- [statName] = { [watcherId] = watcher }
local _holders       = {}       -- [statName] = { [entity] = value }

--- How many entities' snapshots to keep before pruning dead ones (entities leaving scope never announce it).
local PRUNE_AT = 256

local function pruneDead()
    local kept = 0
    for entity in pairs(_previous) do
        if DoesEntityExist(entity) then
            kept = kept + 1
        else
            _previous[entity] = nil
        end
    end
    return kept
end

--- Resolve the vehicleId for an entity (via client/vehicles.lua's cache), or nil if it is not a whip vehicle.
local function vehicleIdOf(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return Vehicles.idByEntity(entity)
end

--- The vehicle entity a client export was handed, or nil when it does not exist.
--- A bare number is a vehicleId; an entity handle is `{ entity = veh }` (handles and ids overlap, so never guess).
--- A vehicle reference is `{ entity = }`, `{ id = }`, `{ plate = }` or `{ netId = }`.
---@param entity any
---@return number|nil
local function resolveEntity(entity)
    entity = Vehicles.refEntity(entity)
    if type(entity) ~= 'number' or entity == 0 then return nil end
    if DoesEntityExist(entity) and GetEntityType(entity) == 2 then return entity end
    return nil
end

-- ---- What the server says exists ----
-- Only stats a vehicle has are replicated: an absent key means the registered default, which needs the registry.

--- Every registered stat, as the server last described it (whip_core:client:vehicleStatDefs): resolves defaults and
--- consumable report cadence.
local _statDefs = {}   -- [name] = { default, min, max, consumeInterval }

RegisterNetEvent('whip_core:client:vehicleStatDefs', function(defs)
    _statDefs = {}
    for _, d in ipairs(defs or {}) do
        if d.name then _statDefs[d.name] = d end
    end
end)

--- What a stat reads as when a vehicle has no stored value for it.
---@param name string
---@return number|nil
local function registeredDefault(name)
    local def = _statDefs[name]
    return def and def.default or nil
end

--- Read one stat out of an already-fetched block, resolving absence to the default. Global, shared with client/vehicles.lua.
---@param stats table|nil  the replicated stat block
---@param name string
---@return number|nil
--- @param live table|nil  the VEHICLE_LIVE_KEY block, when the caller has it
function ResolveVehicleStat(stats, name, live)
    -- Live first: a live stat's current value rides its own key (VEHICLE_LIVE_KEY); the copy in `stats` is stale.
    if type(live) == 'table' then
        local v = live[name]
        if v ~= nil then return v end
    end

    if type(stats) == 'table' then
        local v = stats[name]
        if v ~= nil then return v end
    end
    return registeredDefault(name)
end

--- The live-value block for an entity, or nil when it carries no live stats. Global: the HUD reads it.
---@param entity number
---@return table|nil
function GetVehicleLiveBlock(entity)
    if not entity or entity == 0 then return nil end
    local live = Entity(entity).state[VEHICLE_LIVE_KEY]
    return type(live) == 'table' and live or nil
end

--- Both blocks for an entity (stored, and live), off one state-bag accessor. Global: client/vehicles.lua seeds its HUD cache from it.
--- The car this player sits in comes from that cache (Vehicles.heldStatBlocks), not the bag, because a bag read decodes
--- both blocks into new tables. Those tables are shared: read only. `fresh`: read the bag itself.
---@param entity number
---@param fresh boolean|nil
---@return table|nil stats
---@return table|nil live
function GetVehicleStatBlocks(entity, fresh)
    if not entity or entity == 0 then return nil, nil end

    if not fresh then
        local stats, live, held = Vehicles.heldStatBlocks(entity)
        if held then return stats, live end
    end

    local st = Entity(entity).state
    local stats, live = st[VEHICLE_STATS_KEY], st[VEHICLE_LIVE_KEY]

    -- Normalised here so callers (the presence readers) can test the blocks directly.
    return type(stats) == 'table' and stats or nil,
           type(live)  == 'table' and live  or nil
end

--- The whole set: every registered stat, with what the vehicle carries laid over the defaults. Always a copy.
---@param stats table|nil  the replicated stat block
---@return table
---@param live table|nil  the VEHICLE_LIVE_KEY block, laid over the stored values
function ResolveAllVehicleStats(stats, live)
    local out = {}
    for name, def in pairs(_statDefs) do out[name] = def.default end
    if type(stats) == 'table' then
        for k, v in pairs(stats) do out[k] = v end
    end

    -- Last, so a live stat's current value wins over the copy in the stored block.
    if type(live) == 'table' then
        for k, v in pairs(live) do out[k] = v end
    end
    return out
end

-- ---- Presence ----
-- Declared above the change handler, which calls it.

--- Tell every watcher of `name` that `entity` has just gained or lost it.
---@param name string
---@param entity number
---@param value number|nil  the new value on gain, nil on loss
---@param gained boolean
local function announcePresence(name, entity, value, gained)
    local watchers = _watchers[name]
    if not watchers then return end

    for _, w in pairs(watchers) do
        local fn = gained and w.onGained or w.onLost
        if fn then
            -- pcall, and no type check on `fn`: an export callback is a callable, not a Lua 'function'.
            local ok, err = pcall(fn, entity, value)
            if not ok then
                print(('[whip_core:vehstats] %s for "%s" errored: %s')
                    :format(gained and 'onGained' or 'onLost', name, tostring(err)))
            end
        end
    end
end

--- Fold one vehicle's replicated block into the holder registry, announcing the transitions.
--- Reads the raw block: presence is "is there a stored value", and resolving would answer the default for every car.
---@param entity number
---@param block table  the replicated stat block
local function updateHolders(entity, block)
    for name, holders in pairs(_holders) do
        local held = block[name]
        local was  = holders[entity]

        if held ~= nil and was == nil then
            holders[entity] = held
            announcePresence(name, entity, held, true)
        elseif held == nil and was ~= nil then
            holders[entity] = nil
            announcePresence(name, entity, nil, false)
        elseif held ~= nil then
            -- Still held, new number: no transition, nothing announced (OnVehicleStatChange covers every change).
            holders[entity] = held
        end
    end
end

-- ---- The change handler ----

--- Call one change listener in the shape it registered for: positional `(vehicleId, value, old, entity)`, or one
--- table with the server's field names. `cleared` means this car does not carry the stat.
---@param reg table   { fn, owner, asTable }
---@param name string
---@param vehicleId number
---@param value any
---@param old any
---@param entity number
---@param cleared boolean
local function callStatListener(reg, name, vehicleId, value, old, entity, cleared)
    local ok, err
    if reg.asTable then
        ok, err = pcall(reg.fn, {
            vehicleId = vehicleId, key = name, value = value, old = old,
            cleared = cleared == true, entity = entity,
        })
    else
        ok, err = pcall(reg.fn, vehicleId, value, old, entity)
    end
    if not ok then
        print(('[whip_core:vehstats] listener for "%s" errored: %s'):format(name, tostring(err)))
    end
end

--- Tell every listener whatever moved, and refresh the snapshot. Takes both blocks, so a listener hears the number
--- GetVehicleStat would answer.
---@param entity number
---@param vehicleId number
---@param stats table|nil  the VEHICLE_STATS_KEY block
---@param live table|nil   the VEHICLE_LIVE_KEY block
local function dispatchChanges(entity, vehicleId, stats, live)
    -- The snapshot counts only if it is of this car: entity handles are recycled.
    local rec  = _previous[entity]
    local prev = rec and rec.vehicleId == vehicleId and rec.stats or nil

    for name, listeners in pairs(_changeListeners) do
        -- Resolved, not read: a retired stat (`clearAtMin`) leaves the block, and that removal must be heard.
        local now = ResolveVehicleStat(stats, name, live)
        local old = prev and prev[name] or nil

        if now ~= nil and old ~= now then
            -- pairs, not ipairs: listeners are keyed by '<resource>:<id>', in no defined order.
            local cleared = type(stats) ~= 'table' or stats[name] == nil
            for _, reg in pairs(listeners) do
                -- pcall'd inside: one bad callback must not stop the others.
                callStatListener(reg, name, vehicleId, now, old, entity, cleared)
            end
        end
    end

    -- Snapshot after dispatch, so every listener sees the same `old`. Resolved (not raw) for anything listened to,
    -- both blocks with live last. The same car's table is reused: this runs on every live change.
    local snapshot
    if rec and rec.vehicleId == vehicleId then
        snapshot = rec.stats
        for k in pairs(snapshot) do snapshot[k] = nil end
    else
        snapshot = {}
        _previous[entity] = { vehicleId = vehicleId, stats = snapshot }
    end
    if type(stats) == 'table' then for k, v in pairs(stats) do snapshot[k] = v end end
    if type(live)  == 'table' then for k, v in pairs(live)  do snapshot[k] = v end end
    for name in pairs(_changeListeners) do
        if snapshot[name] == nil then snapshot[name] = ResolveVehicleStat(stats, name, live) end
    end

    -- Cheap check, rare sweep. See PRUNE_AT.
    local count = 0
    for _ in pairs(_previous) do
        count = count + 1
        if count > PRUNE_AT then pruneDead() break end
    end
end

--- Is anything interested in vehicle stat changes at all?
local function anyoneListening()
    return next(_changeListeners) ~= nil or next(_watchers) ~= nil
end

--- One stored-block change, for an entity that exists.
---@param entity number
---@param value table
---@param knownId number|nil  the car's whip id, when the caller has it (the id handler below)
local function onStoredBlock(entity, value, knownId)
    local vehicleId = knownId or vehicleIdOf(entity)
    if not vehicleId then
        -- The block can land before the id: come back when it is stamped (Vehicles.awaitBagId).
        Vehicles.awaitBagId(entity, VEHICLE_STATS_KEY, function(id)
            local current = Entity(entity).state[VEHICLE_STATS_KEY]
            if type(current) == 'table' then onStoredBlock(entity, current, id) end
        end)
        return
    end
    Vehicles.awaitBagId(entity, VEHICLE_STATS_KEY, nil)

    dispatchChanges(entity, vehicleId, value, GetVehicleLiveBlock(entity))

    -- Presence comes from here only: a live stat is in this block while fitted. After the change listeners.
    updateHolders(entity, value)
end

--- The stored block: presence, and every value that changes at human pace.
AddStateBagChangeHandler(VEHICLE_STATS_KEY, nil, function(bagName, _, value)
    if type(value) ~= 'table' then return end
    if not anyoneListening() then return end

    local entity = GetEntityFromStateBagName(bagName)
    if entity and entity ~= 0 then
        onStoredBlock(entity, value)
        return
    end

    -- The bag arrived before the car: wait for it and read the bag then, not `value` (Vehicles.awaitBagEntity).
    Vehicles.awaitBagEntity(bagName, VEHICLE_STATS_KEY, function(arrived)
        local current = Entity(arrived).state[VEHICLE_STATS_KEY]
        if type(current) == 'table' then onStoredBlock(arrived, current) end
    end)
end)

-- (The stats can arrive before the id: onStoredBlock waits through Vehicles.awaitBagId.)

--- The live block: the current value of anything registered `live`. Separate because it fires several times a second;
--- it does not touch presence (updateHolders with only this block would retire every non-live stat).
AddStateBagChangeHandler(VEHICLE_LIVE_KEY, nil, function(bagName, _, value)
    if not anyoneListening() then return end

    local entity = GetEntityFromStateBagName(bagName)
    if not entity or entity == 0 then return end

    local vehicleId = vehicleIdOf(entity)
    if not vehicleId then return end

    local live = type(value) == 'table' and value or nil

    -- Values only, for stats already held: `holders[entity]` is not created here (presence is the stored block's).
    for name, holders in pairs(_holders) do
        if holders[entity] ~= nil then
            local now = live and live[name] or nil
            if now ~= nil then holders[entity] = now end
        end
    end

    -- The stored block: the HUD's copy for the car this player sits in (a live change does not move it), else the bag.
    local held, _, isHeld = Vehicles.heldStatBlocks(entity)
    dispatchChanges(entity, vehicleId, isHeld and held or Entity(entity).state[VEHICLE_STATS_KEY], live)
end)

-- ---- The watcher tick: one loop for every watcher ----

--- How long the loop sleeps while nothing in scope carries a watched stat, and the longest it ever sleeps.
--- It is a ceiling so a slow watcher does not delay onStart / onStop noticing a car has gone.
local WATCH_IDLE_MS = 200

--- How often dead entities are swept out of the holder registry.
local WATCH_REAP_MS = 1000

--- Longest step whileHeld is told about, in seconds (or twice the watcher's own interval, if longer), so an idle
--- watcher or an alt-tab does not receive the whole gap as one delta.
local WATCH_MAX_DT = 0.25

---@param w table
---@param name string
---@param entity number
---@param value number
---@param dt number
local function runHeld(w, name, entity, value, dt)
    -- Profiled: self time here is the pcall plus the crossing into the satellite.
    ProfilerEnterScope('whip:vehicleStatHeld')
    local cost = WhipCost.start()
    local ok, ret = pcall(w.whileHeld, entity, value, dt)
    if cost then WhipCost.stop('vehicle stats: ' .. name .. ' whileHeld (with the crossing)', cost) end
    ProfilerExitScope()

    if not ok then
        print(('[whip_core:vehstats] whileHeld for "%s" errored: %s'):format(name, tostring(ret)))
        return false
    end

    -- A number back is this client's gauge reading for the stat on this car (Vehicles.statReading). Anything else
    -- clears it, and the gauge falls back to the provider or the replicated value.
    ret = tonumber(ret)
    if ret ~= nil and ret == ret and ret ~= math.huge and ret ~= -math.huge then
        w.reading = w.reading or {}
        w.reading[entity] = ret
        return true
    end
    if w.reading then w.reading[entity] = nil end
    return false
end

--- A watcher's gauge reading for a stat on a car (what its whileHeld last returned), or nil. Goes with the watcher.
---@param name string
---@param entity number|nil
---@return number|nil
function Vehicles.statReading(name, entity)
    local watchers = entity and _watchers[name]
    if not watchers then return nil end
    for _, w in pairs(watchers) do
        local r = w.reading and w.reading[entity]
        if r ~= nil then return r end
    end
    return nil
end

--- Fire onStart / onStop, the lifecycle of whileHeld. Unlike onGained / onLost they follow driverOnly, so getting
--- out of the car fires onStop (see WatchVehicleStat).
---@param w table
---@param name string
---@param which 'onStart'|'onStop'
---@param entity number
---@param value number|nil
local function fireLifecycle(w, name, which, entity, value)
    local fn = w[which]
    if not fn then return end

    local ok, err = pcall(fn, entity, value)
    if not ok then
        print(('[whip_core:vehstats] %s for "%s" errored: %s'):format(which, name, tostring(err)))
    end
end

--- Drop holders whose entity has gone (no statebag event fires for that), announcing onLost; onStop follows next pass.
local function reapHolders()
    for name, holders in pairs(_holders) do
        for entity in pairs(holders) do
            if not DoesEntityExist(entity) then
                holders[entity] = nil
                announcePresence(name, entity, nil, false)
            end
        end
    end
end

CreateThread(function()
    local lastReap = 0

    while true do
        local sleep = WATCH_IDLE_MS
        local passCost = WhipCost.start()

        if next(_watchers) ~= nil then
            local now = GetGameTimer()

            if now - lastReap >= WATCH_REAP_MS then
                -- Profiled: this walks every holder of every stat calling DoesEntityExist.
                ProfilerEnterScope('whip:vehicleStatReap')
                local cost = WhipCost.start()
                reapHolders()
                WhipCost.stop('vehicle stats: reap', cost)
                ProfilerExitScope()
                lastReap = now
            end

            -- Once per pass, not once per watcher per holder.
            ProfilerEnterScope('whip:vehicleStatSeat')
            local ped     = PlayerPedId()
            local driving = GetVehiclePedIsIn(ped, false)
            if driving ~= 0 and GetPedInVehicleSeat(driving, -1) ~= ped then driving = 0 end
            ProfilerExitScope()

            --- Milliseconds until the soonest whileHeld is next due (not the shortest interval declared).
            local soonest = nil

            ProfilerEnterScope('whip:vehicleStatSweep')
            local sweepCost = WhipCost.start()

            for name, watchers in pairs(_watchers) do
                local holders = _holders[name] or {}

                for _, w in pairs(watchers) do
                    local active = w.active

                    -- Nothing held and nothing running: skip the watcher (the common case).
                    if next(active) == nil and next(holders) == nil then goto nextWatcher end

                    -- onStop first, and not guarded on holders being non-empty: the last car losing the stat needs it.
                    for entity in pairs(active) do
                        local held     = holders[entity] ~= nil
                        local inFilter = (not w.driverOnly) or entity == driving

                        if not (held and inFilter) then
                            active[entity] = nil
                            if w.reading then w.reading[entity] = nil end   -- back to the replicated value
                            fireLifecycle(w, name, 'onStop', entity, nil)
                        end
                    end

                    if next(holders) ~= nil then
                        -- Cadence belongs to whileHeld: a lifecycle-only watcher (interval 0) must not pin the loop to Wait(0).
                        local due, dt = false, 0.0

                        -- Only a watcher that can act sets it: a driverOnly watcher on foot must not pull the loop down;
                        -- a non-driverOnly one with holders does.
                        local canAct = (not w.driverOnly)
                            or (driving ~= 0 and holders[driving] ~= nil)

                        if w.whileHeld then
                            due = (now - w.lastRun) >= w.interval
                            dt  = math.min((now - w.lastRun) / 1000.0, math.max(WATCH_MAX_DT, (w.interval or 0) / 500.0))
                            if due then w.lastRun = now end

                            -- Read after lastRun moves: a watcher that just ran asks for a full interval.
                            if canAct then
                                local untilDue = (w.lastRun + w.interval) - now
                                if untilDue < 0 then untilDue = 0 end
                                if soonest == nil or untilDue < soonest then soonest = untilDue end
                            end
                        end

                        if w.driverOnly then
                            -- One lookup, not a walk over every holder. driverOnly suits physics: you only own the car you drive.
                            local value = driving ~= 0 and holders[driving] or nil
                            if value ~= nil then
                                if not active[driving] then
                                    active[driving] = true
                                    fireLifecycle(w, name, 'onStart', driving, value)
                                end
                                if due then
                                    local gaveReading = runHeld(w, name, driving, value, dt)

                                    -- The gauge, at the satellite's cadence: a local reading may have changed. Throttled by the HUD.
                                    if gaveReading or (Vehicles.hasStatDisplay and Vehicles.hasStatDisplay(name)) then
                                        Vehicles.refreshHudThrottled()
                                    end
                                end
                            end
                        else
                            for entity, value in pairs(holders) do
                                if not active[entity] then
                                    active[entity] = true
                                    fireLifecycle(w, name, 'onStart', entity, value)
                                end
                                if due and runHeld(w, name, entity, value, dt) then
                                    Vehicles.refreshHudThrottled()   -- a reading to draw (runHeld)
                                end
                            end
                        end
                    end

                    -- Still running something: hold the loop at that watcher's plain interval, to fire onStop.
                    if w.whileHeld and next(active) ~= nil then
                        if soonest == nil or w.interval < soonest then soonest = w.interval end
                    end

                    ::nextWatcher::
                end
            end

            WhipCost.stop('vehicle stats: sweep (the watchers, with their whileHeld)', sweepCost)
            ProfilerExitScope()

            -- Never longer than WATCH_IDLE_MS: the due-time only shortens the sleep.
            if soonest and soonest < sleep then sleep = soonest end
        end

        WhipCost.stop('vehicle stats: a whole pass', passCost)
        Wait(sleep)
    end
end)

-- ---- Watcher registration ----

--- One stat's watcher, for WatchVehicleStat (below). Answers its id.
local function watchOne(name, data, resource, id)
    -- Keyed by who registered it, so re-registering replaces. `data.id` lets one resource hold several on one stat
    -- (default: the stat name).

    -- Replacing a live watcher fires onStop for its cars first, as UnwatchVehicleStat does.
    local existing = _watchers[name] and _watchers[name][id]
    if existing then
        for entity in pairs(existing.active) do
            existing.active[entity] = nil
            fireLifecycle(existing, name, 'onStop', entity, nil)
        end
    end

    local w = {
        id         = id,
        -- The same value the id was built from: decides who may stop or retune it and when it dies.
        owner      = resource,
        onGained   = data.onGained,
        onLost     = data.onLost,
        onStart    = data.onStart,
        onStop     = data.onStop,
        whileHeld  = data.whileHeld,

        -- Which entities whileHeld is running for, from which onStart/onStop are derived.
        active     = {},

        -- The developer's call, including zero: a watcher that wants a frame gets a frame.
        interval   = math.max(tonumber(data.interval) or 0, 0),
        driverOnly = data.driverOnly == true,
        lastRun    = GetGameTimer(),
    }

    _watchers[name] = _watchers[name] or {}
    _watchers[name][id] = w

    -- Seed from the world once, for the first watcher of a stat: the change handler only hears blocks that change.
    local holders = _holders[name]
    if not holders then
        holders = {}
        _holders[name] = holders

        for _, veh in ipairs(GetGamePool('CVehicle')) do
            -- Presence from the stored block, value from the live one when fresher.
            local stats, live = GetVehicleStatBlocks(veh)
            if stats and stats[name] ~= nil then
                holders[veh] = ResolveVehicleStat(stats, name, live)
            end
        end
    end

    -- Announce what is already out there, so onGained is the only place a satellite sets up.
    if w.onGained then
        for entity, value in pairs(holders) do
            local ok, err = pcall(w.onGained, entity, value)
            if not ok then
                print(('[whip_core:vehstats] onGained for "%s" errored: %s')
                    :format(name, tostring(err)))
            end
        end
    end

    return id
end

--- [groupId] = { owner, ids = { per-stat watcher id, ... } } — one entry per list registration.
local _watchGroups = {}

--- A callback that is handed the stat's name second: (entity, name, ...the usual arguments).
local function withName(fn, name)
    if fn == nil then return nil end
    return function(entity, ...) return fn(entity, name, ...) end
end

--- Forward-declared: the list branch of the export tears an old group down through it.
local unwatchOne

-- A refusal answers false, why, as its data twin WatchVehicleData does.
--- Run code while a vehicle in scope carries a stat, without writing a presence cache.
---
---   onGained / onLost   facts about the world: fire for every vehicle in scope, ignoring driverOnly.
---   onStart / onStop    lifecycle of whileHeld for an entity; follow driverOnly. They cover getting out, losing the
---                       stat, the car despawning and the stat being pulled by someone else.
---
--- To modify a vehicle and put it back, use onStart/onStop. They do not run when whip_core or the watcher's own
--- resource stops: put it back in Whip.onCoreLost and onResourceStop too.
--- whileHeld defaults to every holder in scope; `driverOnly = true` narrows it to the car this player drives.
---
---     exports.whip_core:WatchVehicleStat('boost', {
---         onStart    = function(entity, value) captureHandling(entity) end,
---         whileHeld  = function(entity, value, dt) simulate(entity, value, dt) end,
---         onStop     = function(entity) restoreHandling() end,
---         interval   = 50,
---         driverOnly = true,
---     })
---
--- whileHeld may return a number: this client's own reading of the stat on that car, shown by the vehicle capsule
--- instead of the replicated value (without a callback per repaint). Return nothing to show the replicated value.
---
--- Several stats in one call: pass a list of names and each callback gets the stat's name second:
---
---     exports.whip_core:WatchVehicleStat({ 'part1', 'part2', 'part3' }, {
---         onStart = function(entity, name, value) ... end,
---         onStop  = function(entity, name) ... end,
---         driverOnly = true,
---     })
---
--- The id that comes back covers the whole list: UnwatchVehicleStat and SetVehicleStatWatchInterval act on every stat.
--- A list's whileHeld runs once per stat (ten stats at 100ms is a hundred crossings a second); for one job per car,
--- use onStart/onStop and a loop of your own.
---@param name string|string[]
---@param data table { onGained?, onLost?, onStart?, onStop?, whileHeld?, interval?, driverOnly?, id? }
---@return string|false watcherId, string|nil why
exports('WatchVehicleStat', function(name, data)
    if type(data) ~= 'table' then return false, 'data must be a table of callbacks' end

    -- No type check on the callbacks: they arrive as callables, not Lua 'function's.
    if data.onGained == nil and data.onLost == nil and data.onStart == nil
       and data.onStop == nil and data.whileHeld == nil then
        return false, 'give at least one of onGained, onLost, onStart, onStop, whileHeld'
    end

    -- The owner, as every registry asks (shared/registry.lua): ids carry the owner's name, only the owner may retune
    -- or stop them, and a stopped owner's watchers are swept.
    local resource = Registry.caller()

    if type(name) == 'string' then
        return watchOne(name, data, resource, ('%s:%s'):format(resource, tostring(data.id or name)))
    end
    if type(name) ~= 'table' then return false, 'name is a stat name or a list of them' end

    -- A LIST: one watcher per stat, each passing its name on, under one id for the whole list.
    local names = {}
    for _, n in ipairs(name) do
        if type(n) == 'string' and n ~= '' then names[#names + 1] = n end
    end
    if #names == 0 then return false, 'the list holds no stat names' end

    local groupId = ('%s:%s'):format(resource, tostring(data.id or table.concat(names, ',')))

    -- Registering the same list again replaces it, onStop and all, like one watcher does.
    local old = _watchGroups[groupId]
    if old then
        for _, id in ipairs(old.ids) do unwatchOne(id, resource) end
        _watchGroups[groupId] = nil
    end

    local ids = {}
    for _, n in ipairs(names) do
        ids[#ids + 1] = watchOne(n, {
            onGained   = withName(data.onGained, n),
            onLost     = withName(data.onLost, n),
            onStart    = withName(data.onStart, n),
            onStop     = withName(data.onStop, n),
            whileHeld  = withName(data.whileHeld, n),
            interval   = data.interval,
            driverOnly = data.driverOnly,
        }, resource, groupId .. '#' .. n)
    end
    _watchGroups[groupId] = { owner = resource, ids = ids }
    return groupId
end)

--- Change a live watcher's whileHeld cadence. The fastest watcher that can act sets the loop's wake rate, so raise it
--- only while busy. Cheap to call on every state flip; lastRun is left alone. Your watchers only.
---@param watcherId string  the id WatchVehicleStat returned
---@param ms number         new whileHeld interval in milliseconds; 0 means every pass
---@return boolean changed
exports('SetVehicleStatWatchInterval', function(watcherId, ms)
    local owner = Registry.caller()   -- first, before anything can yield
    if not watcherId then return false end

    local interval = math.max(tonumber(ms) or 0, 0)

    -- A list registration's id: every stat in it.
    local group = _watchGroups[watcherId]
    if group then
        if group.owner ~= owner then return false end
        local changed = false
        for _, id in ipairs(group.ids) do
            for _, watchers in pairs(_watchers) do
                local w = watchers[id]
                if w and w.owner == owner and w.interval ~= interval then
                    w.interval = interval
                    changed = true
                end
            end
        end
        return changed
    end

    -- Every stat this id watches (one id may watch several).
    local changed = false
    for _, watchers in pairs(_watchers) do
        local w = watchers[watcherId]
        if w and w.owner == owner and w.interval ~= interval then
            w.interval = interval
            changed = true
        end
    end

    return changed
end)

--- Stop a watcher. Fires onStop for anything it was still running for, not onLost. Every stat the id watches.
---@param watcherId string
---@param owner string  only this resource's watchers are touched
---@return boolean removed
function unwatchOne(watcherId, owner)
    local removed = false
    for name, watchers in pairs(_watchers) do
        local w = watchers[watcherId]
        if w and w.owner == owner then
            for entity in pairs(w.active) do
                w.active[entity] = nil
                fireLifecycle(w, name, 'onStop', entity, nil)
            end

            watchers[watcherId] = nil   -- clearing a field mid-pairs is allowed
            removed = true

            -- Last watcher of this stat: stop maintaining its holders too.
            if next(watchers) == nil then
                _watchers[name] = nil
                _holders[name]  = nil
            end
        end
    end

    return removed
end

--- Stop one of YOUR watchers.
exports('UnwatchVehicleStat', function(watcherId)
    local owner = Registry.caller()   -- first, before anything can yield
    if not watcherId then return false end

    -- A list registration's id: every stat in it.
    local group = _watchGroups[watcherId]
    if group then
        if group.owner ~= owner then return false end
        _watchGroups[watcherId] = nil
        for _, id in ipairs(group.ids) do unwatchOne(id, owner) end
        return true
    end

    return unwatchOne(watcherId, owner)
end)

AddEventHandler('onResourceStop', function(res)
    for name, watchers in pairs(_watchers) do
        for id, w in pairs(watchers) do
            if w.owner == res then watchers[id] = nil end
        end
        if next(watchers) == nil then
            _watchers[name] = nil
            _holders[name]  = nil
        end
    end
    for groupId, group in pairs(_watchGroups) do
        if group.owner == res then _watchGroups[groupId] = nil end
    end
end)

-- ---- Exports ----

--- Read one stat off a vehicle, falling back to the registered default as the server's GetVehicleStat does.
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@param name string
---@return number|nil
exports('GetVehicleStat', function(vehicle, name)
    local entity = resolveEntity(vehicle)
    if not entity then return nil end

    -- Live block first: it holds a live stat's current value.
    local stats, live = GetVehicleStatBlocks(entity)
    return ResolveVehicleStat(stats, name, live)
end)

--- Does this vehicle actually carry this stat, as opposed to reading as its default? GetVehicleStat cannot say.
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@param name string
---@return boolean
exports('HasVehicleStat', function(vehicle, name)
    if type(name) ~= 'string' then return false end

    local entity = resolveEntity(vehicle)
    if not entity then return false end

    -- The main block, not the live one: presence is written there when fitted and cleared.
    local stats = Entity(entity).state[VEHICLE_STATS_KEY]
    return type(stats) == 'table' and stats[name] ~= nil
end)

--- Every stat on a vehicle, as a plain copy.
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@return table
exports('GetAllVehicleStats', function(vehicle)
    local entity = resolveEntity(vehicle)
    if not entity then return {} end

    -- Every registered stat, defaults filled in (the server's GetAllVehicleStats). What a car has is GetStoredVehicleStats.
    local stats, live = GetVehicleStatBlocks(entity)
    return ResolveAllVehicleStats(stats, live)
end)

--- Be told when a vehicle stat changes, on any vehicle streamed to this client. Mirrors OnStatChange (client/stats.lua),
--- with the vehicle passed too. Options, third or fourth, as on the server:
---
---     exports.whip_core:OnVehicleStatChange('nitro', function(change)
---         -- change.vehicleId, change.key, change.value, change.old, change.cleared, change.entity
---     end, { table = true, now = true })
---
---   * `table = true`: one table, with the server's field names.
---   * `now = true`: also called once straight away for every car in range that carries the stat.
---@param name string
---@param callback fun(vehicleId: number, value: number, old: number|nil, entity: number)
---@param id any|nil
---@param opts table|nil  { table?: boolean, now?: boolean }
---@return boolean registered
exports('OnVehicleStatChange', function(name, callback, id, opts)
    -- `callback ~= nil`, not a type check: an export callback is a callable of another type. Answers `false, why` as OnStatChange does.
    if type(name) ~= 'string' or name == '' then return false, 'name is required (a vehicle stat name)' end
    if callback == nil then return false, 'callback is required' end
    if type(id) == 'table' and opts == nil then id, opts = nil, id end
    opts = type(opts) == 'table' and opts or {}

    -- Keyed `<resource>:<id>` so re-registering replaces; `id` defaults to the stat name.
    local resource = GetInvokingResource() or GetCurrentResourceName()
    local key = ('%s:%s'):format(resource, tostring(id or name))

    if not _changeListeners[name] then _changeListeners[name] = {} end
    -- The owner rides with the callback (a separate map would be shared by two stats under one id).
    local reg = { fn = callback, owner = resource, asTable = opts.table == true }
    _changeListeners[name][key] = reg

    -- `now`: every car in range that carries the stat, once, after the registration has returned.
    if opts.now then
        CreateThread(function()
            for _, veh in ipairs(GetGamePool('CVehicle')) do
                local vehicleId = vehicleIdOf(veh)
                if vehicleId and _changeListeners[name] and _changeListeners[name][key] == reg then
                    local stats, live = GetVehicleStatBlocks(veh)
                    if type(stats) == 'table' and stats[name] ~= nil then
                        callStatListener(reg, name, vehicleId, ResolveVehicleStat(stats, name, live),
                            nil, veh, false)
                    end
                end
            end
        end)
    end

    return true
end)

AddEventHandler('onResourceStop', function(res)
    for name, listeners in pairs(_changeListeners) do
        for key, reg in pairs(listeners) do
            if reg.owner == res then
                listeners[key] = nil
            end
        end
        -- `next(...) == nil`: `#` on a keyed table is always 0.
        if next(listeners) == nil then _changeListeners[name] = nil end
    end
end)

-- ---- Consumption: burning a stat down by driving ----
-- Call every frame with the amount used; the framework accumulates, reports and rate-limits:
--     exports.whip_core:ConsumeVehicleStat({ entity = veh }, 'nitro', 5.0 * GetFrameTime())
-- It sends a running total, not a delta, so a dropped report costs latency, not fuel.

-- ---- /vehstatdebug: what this car is carrying, and what is moving it ----
-- Values come off the entity's statebag; changes (`changeSource`: `consume`, `decay`, a satellite) come from the
-- server. Reads every stat the car has, not only those that draw a gauge.

local vsdActive   = false
local vsdVehicle  = nil     -- vehicleId currently being watched, so we only re-tell the server on a change
local vsdChanges  = {}      -- newest last: { stat, delta, value, source, cleared, at }

local VSD_MAX_CHANGES = 30
local VSD_RATE_WINDOW = 3000   -- ms of history the per-stat rate is averaged over
local VSD_DATA_CHARS  = 400    -- an attached value longer than this as text is cut

--- One message per transaction, carrying every stat that moved in it (the server's own shape).
RegisterNetEvent('whip_core:client:vehStatChange', function(data)
    if not vsdActive or type(data) ~= 'table' then return end

    local changes, order = data.changes, data.order
    if type(changes) ~= 'table' or type(order) ~= 'table' then return end

    local at = GetGameTimer()
    for i = 1, #order do
        local c = changes[order[i]]
        if type(c) == 'table' then
            vsdChanges[#vsdChanges + 1] = {
                stat    = c.stat or order[i],
                value   = c.value,
                delta   = (type(c.value) == 'number' and type(c.previous) == 'number')
                            and (c.value - c.previous) or nil,
                source  = c.source or '?',
                cleared = c.cleared == true,
                at      = at,
            }
        end
    end

    while #vsdChanges > VSD_MAX_CHANGES do table.remove(vsdChanges, 1) end
end)

--- Recent rate and last source for every stat, in one pass over the change list.
--- Rate is averaged over a window (reports arrive on a cadence, so one delta is not a rate). Source ignores the
--- window, so the walk does not break early.
---@param now number
---@return table rates    [stat] = units per second
---@return table sources  [stat] = the most recent changeSource
local function vsdSummarise(now)
    local sums, seen, sources = {}, {}, {}

    for i = #vsdChanges, 1, -1 do
        local c = vsdChanges[i]
        local stat = c.stat

        -- Backwards, so the first one seen for a stat is its most recent.
        if sources[stat] == nil then sources[stat] = c.source end

        if (now - c.at) <= VSD_RATE_WINDOW and c.delta then
            sums[stat] = (sums[stat] or 0) + c.delta
            seen[stat] = true
        end
    end

    -- Against the window, not the span of the samples: two reports 200ms apart are not a 5Hz drain.
    local rates = {}
    for stat, sum in pairs(sums) do
        if seen[stat] and sum ~= 0 then
            rates[stat] = sum / (VSD_RATE_WINDOW / 1000.0)
        end
    end

    return rates, sources
end

--- How often the overlay redraws while it is open, in ms (values are read locally off the statebag).
local VSD_TICK_MS = 50

--- Started when the overlay opens, ended when it closes.
local vsdLoopRunning = false

-- ---- The cards over the whip cars near you (tools/debug_cards.lua) ----
--
-- Every whip car within VSD_CARD_RANGE but your own gets a card: plate, id and its stats as bars. Read off the
-- statebags; nothing is asked of the server.

local VSD_CARD_RANGE = 40.0
local VSD_CARD_MAX   = 8
local VSD_CARD_EVERY = 5      -- loop ticks between card updates: four a second

---@param veh number
---@param vehicleId number
local function vsdCard(veh, vehicleId)
    local block, live = GetVehicleStatBlocks(veh)
    local huds = Vehicles.hudDefsByName and Vehicles.hudDefsByName() or {}
    local rows = {}
    for name, def in pairs(_statDefs) do
        local stored = type(block) == 'table' and block[name] or nil
        if stored ~= nil then
            local value = (live and live[name] ~= nil) and live[name] or stored
            local min, max = def.min or 0, def.max or 100
            local pct = 0
            if max > min and type(value) == 'number' then
                pct = math.max(0, math.min(100, (value - min) / (max - min) * 100))
            end
            local hud = huds[name]
            rows[#rows + 1] = {
                n = hud and hud.label or name, p = math.floor(pct + 0.5),
                v = type(value) == 'number' and ('%.1f'):format(value) or tostring(value),
                c = hud and hud.color or nil,
            }
        end
    end
    table.sort(rows, function(a, b) return a.n < b.n end)
    return {
        title = (GetVehicleNumberPlateText(veh) or '???'):gsub('^%s+', ''):gsub('%s+$', ''),
        sub = '#' .. tostring(vehicleId),
        rows = rows,
        note = #rows == 0 and 'No stats fitted' or nil,
    }
end

--- Cards over the nearest whip cars, the one you are in left out.
---@param myVeh number  0 when on foot
local function vsdCards(myVeh)
    if not DebugCards then return end
    local me = GetEntityCoords(PlayerPedId())
    local near = {}
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if veh ~= myVeh then
            local p = GetEntityCoords(veh)
            local dx, dy, dz = p.x - me.x, p.y - me.y, p.z - me.z
            local d = dx * dx + dy * dy + dz * dz
            if d <= VSD_CARD_RANGE * VSD_CARD_RANGE then
                local id = Vehicles.idByEntity(veh)
                if id then near[#near + 1] = { veh = veh, id = id, d = d } end
            end
        end
    end
    table.sort(near, function(a, b) return a.d < b.d end)
    local keep = {}
    for i = 1, math.min(#near, VSD_CARD_MAX) do
        local n = near[i]
        local key = 'v:' .. tostring(n.id)
        keep[key] = true
        DebugCards.set(key, n.veh, vsdCard(n.veh, n.id))
    end
    DebugCards.keep('v:', keep)
end

local function vsdLoop()
    local tick = 0
    while vsdActive do
        Wait(VSD_TICK_MS)
        if not vsdActive then break end
        tick = tick + 1

        do
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            local inVeh = veh and veh ~= 0 and DoesEntityExist(veh)

            local vehicleId = inVeh and Vehicles.idByEntity(veh) or nil

            if tick % VSD_CARD_EVERY == 1 then vsdCards(inVeh and veh or 0) end

            -- Tell the server which car to forward changes for, only when it changes. Leaving a vehicle sends 0.
            if vehicleId ~= vsdVehicle then
                vsdVehicle = vehicleId
                vsdChanges = {}
                TriggerServerEvent('whip_core:server:vehStatDebugWatch', vehicleId or 0)
            end

            if not inVeh then
                SendNUIMessage({ action = 'vehStatDebug', data = { vehicle = nil } })
                goto continue
            end

            local now         = GetGameTimer()
            local block, live = GetVehicleStatBlocks(veh)
            local huds        = Vehicles.hudDefsByName and Vehicles.hudDefsByName() or {}

            -- Rate and source for every stat at once, before the row loop (vsdSummarise).
            local rates, sources = vsdSummarise(now)

            -- Every registered stat, with what this car actually stores marked as such (absent reads as its default).
            local rows = {}
            for name, def in pairs(_statDefs) do
                -- Presence from the stored block, value preferring the live one.
                local stored = type(block) == 'table' and block[name] or nil
                local value  = stored
                if live and live[name] ~= nil then value = live[name] end
                if value == nil then value = def.default end

                local min = def.min or 0
                local max = def.max or 100
                local pct = 0
                if max > min and type(value) == 'number' then
                    pct = math.floor(((value - min) / (max - min)) * 1000 + 0.5) / 10
                    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
                end

                local hud = huds[name]
                rows[#rows + 1] = {
                    name     = name,
                    label    = hud and hud.label or nil,
                    value    = value,
                    min      = min,
                    max      = max,
                    pct      = pct,
                    color    = hud and hud.color or nil,
                    gauged   = hud ~= nil,
                    stored   = stored ~= nil,
                    consumes = def.consumeInterval ~= nil,
                    rate     = rates[name],
                    source   = sources[name],
                }
            end

            table.sort(rows, function(a, b)
                -- What the car has first, then alphabetically, so rows do not move as values change.
                if a.stored ~= b.stored then return a.stored end
                return a.name < b.name
            end)

            local changes = {}
            for i = #vsdChanges, 1, -1 do
                local c = vsdChanges[i]
                changes[#changes + 1] = {
                    stat    = c.stat,
                    delta   = c.delta,
                    value   = c.value,
                    source  = c.source,
                    cleared = c.cleared,
                    ago     = (now - c.at) / 1000.0,
                }
            end

            -- Whatever resources have attached to this car, shown as text (it is opaque to whip). A table as JSON:
            -- tostring of a table is its address, which would look like data changing every read.
            local attached = {}
            for key, value in pairs(Entity(veh).state[VEHICLE_DATA_KEY] or {}) do
                local text
                if type(value) == 'table' then
                    local ok, encoded = pcall(json.encode, value)
                    text = ok and type(encoded) == 'string' and encoded or '(not readable)'
                    if #text > VSD_DATA_CHARS then text = text:sub(1, VSD_DATA_CHARS) .. '…' end
                else
                    text = tostring(value)
                end
                attached[#attached + 1] = { key = key, text = text }
            end
            table.sort(attached, function(a, b) return a.key < b.key end)

            SendNUIMessage({
                action = 'vehStatDebug',
                data = {
                    vehicle = {
                        id    = vehicleId,
                        plate = GetVehicleNumberPlateText(veh),
                        seat  = GetPedInVehicleSeat(veh, -1) == ped and 'driver' or 'passenger',
                    },
                    stats    = rows,
                    attached = attached,
                    changes  = changes,
                },
            })
        end

        ::continue::
    end
    vsdLoopRunning = false
end

--- `want` (true/false) sets it instead of flipping (see ToggleStatsDebug).
---@param want boolean|nil
function ToggleVehStatDebug(want)
    if want ~= nil and (want == true) == vsdActive then return vsdActive end
    vsdActive = not vsdActive

    if vsdActive and not vsdLoopRunning then
        vsdLoopRunning = true
        CreateThread(vsdLoop)
    end

    if not vsdActive then
        -- Stop the server forwarding before the panel goes.
        TriggerServerEvent('whip_core:server:vehStatDebugWatch', 0)
        vsdVehicle = nil
        vsdChanges = {}
        if DebugCards then DebugCards.keep('v:', {}) end   -- the cards over nearby cars go too
    end

    SendNUIMessage({ action = vsdActive and 'vehStatDebugShow' or 'vehStatDebugHide' })
    return vsdActive
end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and vsdActive then
        TriggerServerEvent('whip_core:server:vehStatDebugWatch', 0)
    end
end)

--- [name] = { vehicleId, total, sentTotal, lastSent, lastTouched, fresh }
local _consume = {}

--- How often a stat is expected to report, in ms. Comes from the registration.
local function consumeIntervalMs(name)
    local def = _statDefs[name]
    return math.max(250, ((def and def.consumeInterval) or 1.0) * 1000)
end

--- Add one delta to the accumulator, for a vehicle already resolved (shared by both consume exports).
---@param vehicleId number
---@param name string
---@param delta number|nil
---@param now number  one clock reading, shared across a batch
---@return boolean
local function accumulateConsume(vehicleId, name, delta, now)
    if type(name) ~= 'string' then return false end

    delta = tonumber(delta)
    if not delta or delta <= 0 then return false end

    local st = _consume[name]

    -- A different vehicle, or one after a pause, is a new run: its count starts at 0 and the start is sent on its own
    -- first (`fresh`), because the server bills nothing for the first count it sees (applyStatReport).
    if not st or st.vehicleId ~= vehicleId then
        st = { vehicleId = vehicleId, total = 0.0, sentTotal = 0.0, lastSent = 0, fresh = true }
        _consume[name] = st
    end

    st.total       = st.total + delta
    st.lastTouched = now
    return true
end

--- The vehicleId a consume call is for, or nil when there is nothing to accumulate against.
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@return number|nil
local function consumeTarget(vehicle)
    local entity = resolveEntity(vehicle)
    if not entity then return nil end

    return Vehicles.idByEntity(entity)
end

--- Report that this client used some of a stat on a vehicle. Safe to call every frame: accumulates locally and
--- reports on the stat's cadence; the server caps what arrives. Use ConsumeVehicleStats for several.
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@param name string
---@param delta number  amount used since the last call. Positive.
---@return boolean
function ConsumeVehicleStat(vehicle, name, delta)   -- global: the export below, and whip_core's own callers
    local vehicleId = consumeTarget(vehicle)
    if not vehicleId then return false end

    return accumulateConsume(vehicleId, name, delta, GetGameTimer())
end
exports('ConsumeVehicleStat', ConsumeVehicleStat)

--- Report several stats used on one vehicle, in a single call (one export crossing; each stat keeps its cadence).
---
--- ```lua
--- local used = {}
--- for i = 1, 10 do used['part' .. i] = FULL * moved / distance[i] end
--- exports.whip_core:ConsumeVehicleStats({ entity = veh }, used)
--- ```
---
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@param deltas table  [statName] = amount used since the last call. Positive.
---@return boolean ok        false when the vehicle could not be resolved
---@return number accepted   how many of the deltas were valid and applied
exports('ConsumeVehicleStats', function(vehicle, deltas)
    if type(deltas) ~= 'table' then return false, 0 end

    local vehicleId = consumeTarget(vehicle)
    if not vehicleId then return false, 0 end

    -- One clock reading for the batch.
    local now, accepted = GetGameTimer(), 0

    for name, delta in pairs(deltas) do
        if accumulateConsume(vehicleId, name, delta, now) then
            accepted = accepted + 1
        end
    end

    -- (true, 0) is a real answer: the vehicle resolved and nothing in the table was usable.
    return true, accepted
end)

--- [name] = { vehicleId, value, sentValue, lastSent, repeats, lastTouched }
local _live = {}

--- How many times to repeat the final value after a live stat settles, so a lost last report cannot freeze a gauge.
local LIVE_TAIL_REPEATS = 3

--- How often a live stat is expected to report, in ms. From the registration, floored at the sender's cadence (250ms).
local function liveIntervalMs(name)
    local def = _statDefs[name]
    return math.max(250, ((def and def.liveInterval) or 0.5) * 1000)
end

--- Report what a live stat is worth right now: for a value the client drives both ways (boost, heat, charge).
--- Safe to call every frame; the newest value supersedes older ones. The server caps how fast it may rise and
--- refuses it unless the vehicle already carries the stat.
---@param vehicle number|WhipVehicleRef  a vehicleId, or a reference: `{ entity = veh }` for a handle
---@param name string
---@param value number|nil  what the stat is worth now
---@return boolean
exports('ReportVehicleStat', function(vehicle, name, value)
    if type(name) ~= 'string' then return false end

    value = tonumber(value)
    if not value then return false end

    local entity = resolveEntity(vehicle)
    if not entity then return false end

    local vehicleId = Vehicles.idByEntity(entity)
    if not vehicleId then return false end

    local st = _live[name]

    -- A different vehicle is a different run, as for consumption.
    if not st or st.vehicleId ~= vehicleId then
        st = { vehicleId = vehicleId, value = value, sentValue = nil, lastSent = 0 }
        _live[name] = st
    end

    st.value       = value
    st.lastTouched = GetGameTimer()
    return true
end)

--- How many times to repeat the final total after consumption stops, in case the last send was dropped (a duplicate is a no-op).
local CONSUME_TAIL_REPEATS = 3

--- The reporting cadence, and the tail. On a clock, not on the caller, so the last partial amount still goes.
--- Nothing is zeroed: `sentTotal` only records how far reports have got.
CreateThread(function()
    while true do
        Wait(250)
        local cost = WhipCost.start()

        if next(_consume) then
            local now = GetGameTimer()

            -- Collected per vehicle, then sent once: the server rate-limits per (source, event).
            local batch = nil   -- [vehicleId] = { [name] = total }, built only if needed

            for name, st in pairs(_consume) do
                local due = (now - st.lastSent) >= consumeIntervalMs(name)
                local send = false
                local told = st.total

                if st.fresh then
                    -- A new run's start (0) goes on its own, so every later report is billed (accumulateConsume).
                    st.fresh, st.lastSent = nil, now
                    send, told = true, 0.0

                elseif st.total > st.sentTotal and due then
                    -- New burn to report; repeats owed for the previous total are moot.
                    st.lastSent  = now
                    st.sentTotal = st.total
                    st.repeats   = CONSUME_TAIL_REPEATS
                    send = true

                elseif (st.repeats or 0) > 0 and due then
                    -- Nothing new, but the last total is not yet repeated enough: same number again.
                    st.lastSent = now
                    st.repeats  = st.repeats - 1
                    send = true
                end

                if send then
                    batch = batch or {}
                    local forVeh = batch[st.vehicleId]
                    if not forVeh then
                        forVeh = {}
                        batch[st.vehicleId] = forVeh
                    end
                    forVeh[name] = told
                end

                -- Fully reported, repeats exhausted, untouched for a while: the run is over.
                if st.total <= st.sentTotal
                    and (st.repeats or 0) <= 0
                    and (now - (st.lastTouched or 0)) > 30000
                then
                    _consume[name] = nil
                end
            end

            if batch then
                for vehicleId, totals in pairs(batch) do
                    TriggerServerEvent('whip_core:server:reportStatBurn', vehicleId, totals)
                end
            end
        end

        -- ---- live values ----
        -- In this thread (one wake, two jobs). The newest value supersedes older ones; only the last can be lost.
        if next(_live) then
            local now = GetGameTimer()
            local batch = nil   -- [vehicleId] = { [name] = value }

            for name, st in pairs(_live) do
                local due  = (now - st.lastSent) >= liveIntervalMs(name)
                local send = false

                if due and st.value ~= st.sentValue then
                    st.lastSent  = now
                    st.sentValue = st.value
                    st.repeats   = LIVE_TAIL_REPEATS
                    send = true

                elseif due and (st.repeats or 0) > 0 then
                    st.lastSent = now
                    st.repeats  = st.repeats - 1
                    send = true
                end

                if send then
                    batch = batch or {}
                    local forVeh = batch[st.vehicleId]
                    if not forVeh then
                        forVeh = {}
                        batch[st.vehicleId] = forVeh
                    end
                    forVeh[name] = st.value
                end

                -- Settled and untouched for a while: the run is over.
                if st.value == st.sentValue and (st.repeats or 0) <= 0
                    and (now - (st.lastTouched or 0)) > 30000
                then
                    _live[name] = nil
                end
            end

            if batch then
                for vehicleId, values in pairs(batch) do
                    TriggerServerEvent('whip_core:server:reportStatLive', vehicleId, values)
                end
            end
        end

        WhipCost.stop('vehicle stats: burn and live reports to the server (4 a second)', cost)
    end
end)
