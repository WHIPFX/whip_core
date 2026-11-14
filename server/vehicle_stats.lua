-- ============================================
-- VehicleStats — per-vehicle stats, server side
--
-- What PlayerStats is for characters, this is for
-- vehicles: register a stat once, set it from
-- anywhere, and every client in the car sees it.
-- ============================================
--
-- Shaped like server/stats.lua: same register/get/set/add, same config fields, same decay, and the
-- same registration contract (owner sweep, copied config, (ok, err), reserved names).
--
-- No effect system: vehicle effects are left out until there is a real use. Stats with a decay
-- rate cover today's cases.

--- Profiler scopes, bound once: absent on some builds, and a nil call would throw inside stat
--- replication. See the same pair in server/secure.lua.
local ProfilerEnterScope = ProfilerEnterScope or function() end
local ProfilerExitScope  = ProfilerExitScope  or function() end

VehicleStats = {}

VehicleStats._registry  = {}  -- [name]      = config
VehicleStats._owners    = {}  -- [name]      = resource that registered it
VehicleStats._lastDecay = {}  -- [vehicleId] = { [name] = gameTimer }

--- Stats changed since the last flush, waiting to be written.
---
--- Write-behind: fuel ticks every second on every moving car, and a row write per tick per car is
--- not a database access pattern. Replication is not throttled (it is what players see); only the
--- trip to disk waits, as Stores' `durability = 'writeBehind'`.
VehicleStats._dirty = {}      -- [vehicleId] = { [name] = value }

--- Queue a stat write on the car's save unit, `vehrow:<vehicleId>` (stores.lua):
--- written once it has waited VehicleStatsSaveInterval, or at once with whatever the same player action
--- took (the nitro bottle, the turbo part), in one transaction.
local function queueStat(vehicleId, name, value)
    if not VehicleStats._dirty[vehicleId] then VehicleStats._dirty[vehicleId] = {} end
    VehicleStats._dirty[vehicleId][name] = value
    Stores.markDirty(Stores.unit('vehrow', vehicleId))
end

--- Consumption bookkeeping, per vehicle per stat.
---
--- Cumulative totals, not deltas: a client reporting "my running total is 41.7" can't lose burn
--- to a dropped message (the next one carries the whole story), where "I burned 3.2 since last
--- time" is forgiven if dropped. The server stores where it last read up to and applies the difference.
VehicleStats._consumeCursors = {}   -- [vehicleId] = { [name] = { total, source, last } }

--- Names whip_core owns. A satellite cannot take these; whip_core itself registers them, from
--- Config.VehicleStats at boot and the damage ones in vehicle_damage.lua. (Fuel is not one: it is whip_fuel's, and
--- without it there is none.)
VehicleStats.ReservedNames = {
    engine = true,

    engineHealth = true,
    bodyHealth   = true,
    doorsOff     = true,
    tyresFlat    = true,
    tyresRim     = true,
}

-- ============================================
-- Registration
-- ============================================

--- The vehicle stat registry, on the one registration rule (shared/registry.lua).
---
--- A satellite that stops takes its stat registrations with it (onRemove), but not the values:
--- see VehicleStats.unregister.
local _vehicleStats = Registry.new('VehicleStat', {
    label = 'vehicle stat',
    store = VehicleStats._registry,
    prefixed = true,   -- one list for the server (shared/registry.lua)
    onAdd = function(name, _, owner)
        VehicleStats._owners[name] = owner

        -- The stat defs carry the new stat's default to every client (what a car never written
        -- reads it as). No car is re-replicated: its stored block hasn't changed.
        VehicleStats.broadcastHudDefs()
        VehicleStats.broadcastStatDefs()
    end,
    onRemove = function(name, _, owner, why)
        VehicleStats._owners[name] = nil

        -- Stop believing consumption reports for it: the registration authorises them.
        for _, byName in pairs(VehicleStats._consumeCursors) do
            byName[name] = nil
        end

        VehicleStats.broadcastHudDefs()
        VehicleStats.broadcastStatDefs()

        if why == 'stopped' then
            print(('[whip_core:vehstats] dropped vehicle stat "%s" — %s stopped'):format(name, owner))
        end
    end,
})

--- A stat's `display`: how its value reads to a person, checked and put in one shape for every screen that shows it
--- (html/js/stat-display.js reads it):
---
---   display = { unit = 'psi', range = { -3, 30 } }                          -- the bottom and top of its range
---   display = { unit = '°C', points = { { 0, 20 }, { 50, 90 }, { 100, 130 } } }   -- percent → reading, straight between
---   display = { ends = { 'E', 'F' } }                                       -- the gauge shows these at its ends, no number
---
--- `decimals` 0-2 (default 0). A `range` becomes its two points. Answers the shape { unit?, decimals, points?, ends? },
--- nil for none, or false and why.
---@param d any
---@return table|nil|false display
---@return string|nil why
local function normDisplay(d)
    if d == nil then return nil end
    if type(d) ~= 'table' then return false, 'display must be a table' end
    local out = { decimals = 0 }
    if d.unit ~= nil then
        if type(d.unit) ~= 'string' or d.unit == '' or #d.unit > 8 then
            return false, "display.unit must be a short unit, up to 8 characters: 'psi', '°C'"
        end
        out.unit = d.unit
    end
    if d.decimals ~= nil then
        local n = tonumber(d.decimals)
        if not n or n < 0 or n > 2 or n ~= math.floor(n) then return false, 'display.decimals must be 0, 1 or 2' end
        out.decimals = n
    end
    if d.range ~= nil and d.points ~= nil then return false, 'display takes range or points, not both' end
    if d.range ~= nil then
        local r = d.range
        local bottom = type(r) == 'table' and tonumber(r[1]) or nil
        local top    = type(r) == 'table' and tonumber(r[2]) or nil
        if not bottom or not top then return false, 'display.range must be { bottom, top }: what the stat reads at each end' end
        out.points = { { 0, bottom }, { 100, top } }
    elseif d.points ~= nil then
        if type(d.points) ~= 'table' or #d.points < 2 or #d.points > 16 then
            return false, 'display.points must list 2 to 16 { percent, reading } pairs'
        end
        local pts = {}
        for i, p in ipairs(d.points) do
            local x = type(p) == 'table' and tonumber(p[1]) or nil
            local y = type(p) == 'table' and tonumber(p[2]) or nil
            if not x or not y or x < 0 or x > 100 then
                return false, ('display.points[%d] must be { percent 0-100, reading }'):format(i)
            end
            pts[#pts + 1] = { x, y }
        end
        table.sort(pts, function(p, q) return p[1] < q[1] end)
        out.points = pts
    end
    if d.ends ~= nil then
        local e = d.ends
        local empty = type(e) == 'table' and e[1] or nil
        local full  = type(e) == 'table' and e[2] or nil
        if type(empty) ~= 'string' or type(full) ~= 'string' or #empty > 3 or #full > 3 or (empty == '' and full == '') then
            return false, "display.ends must be { 'E', 'F' }: the empty end's marker, then the full end's, up to 3 characters each"
        end
        out.ends = { empty, full }
    end
    if not out.points and not out.ends then return false, 'display needs range, points or ends' end
    if out.unit and not out.points then return false, 'display.unit needs a range or points to go with' end
    return out
end

--- Register a vehicle stat.
---@param name string
---@param config table  { default, min, max, persist, decay, decayInterval, hud, display }
---@param owner string|nil  resource name; defaults to the caller
---@return boolean ok
---@return string|nil err
function VehicleStats.register(name, config, owner)
    if type(name) ~= 'string' or name == '' then
        return false, 'a vehicle stat needs a name'
    end
    -- A name the rest of the stat system can use: persist and the consume/live reports filter to
    -- [%w_], and the save's JSON path ('$.name') breaks on a leading digit.
    if not name:match('^[%a_][%w_]*$') or #name > 32 then
        return false, ('vehicle stat "%s": a name is letters, digits and _ (not starting with a digit), up to 32'):format(name)
    end
    if type(config) ~= 'table' then
        return false, ('vehicle stat "%s": expected a config table'):format(name)
    end

    owner = owner or GetCurrentResourceName()

    if VehicleStats.ReservedNames[name] and owner ~= GetCurrentResourceName() then
        return false, ('vehicle stat "%s" is owned by whip_core'):format(name)
    end

    -- Copy, never keep the caller's table (its later edits must not reach the registry).
    local entry = {
        name          = name,
        default       = tonumber(config.default) or 0,
        min           = tonumber(config.min) or 0,
        max           = tonumber(config.max) or 100,
        persist       = config.persist ~= false,

        -- Persisting a stat and persisting its value are two questions. `persist = true` means
        -- both (a tank's level). `'presence'` writes the stat when it appears and when it goes,
        -- and leaves it alone in between: a fitted turbo survives a restart, its momentary boost
        -- doesn't (it comes back at its resting value).
        persistMode   = (config.persist == 'presence') and 'presence' or 'value',

        decay         = tonumber(config.decay),
        decayInterval = tonumber(config.decayInterval) or 10,
        hud           = nil,
    }

    -- `decay = 0` means no decay (0 is truthy in Lua, so it would run the branch and add nothing).
    if entry.decay == 0 then entry.decay = nil end

    -- How the value reads to a person (normDisplay): a unit and a range or a curve, or a gauge's end markers.
    local display, displayWhy = normDisplay(config.display)
    if display == false then return false, ('vehicle stat "%s": %s'):format(name, displayWhy) end
    entry.display = display

    if type(config.hud) == 'table' then
        entry.hud = {
            -- Shown where a gauge needs a word (the garage list). The client falls back to the
            -- stat's own name, prettified.
            label         = type(config.hud.label) == 'string' and config.hud.label or nil,
            icon          = config.hud.icon,
            iconCritical  = config.hud.iconCritical,
            color         = config.hud.color,
            order         = tonumber(config.hud.order) or 99,
            iconOnly      = config.hud.iconOnly or false,
            heartbeat     = config.hud.heartbeat or false,
            hideWhenEmpty = config.hud.hideWhenEmpty or false,
            noCritical    = config.hud.noCritical or false,
            showAboveZero = config.hud.showAboveZero or false,

            -- Draw when the car HAS the stat, not when its value is above zero: a turbo idling at
            -- 1 would otherwise draw on every car (a car without one reads the default too). Use
            -- this for a fitting, showAboveZero for a quantity that runs out.
            showWhenPresent = config.hud.showWhenPresent or false,
        }
    end

    -- Consumption: the framework owns the whole pattern for a stat the vehicle burns down (fuel,
    -- nitrous, a battery). The client is the only side that knows how much was used; the server is
    -- the only side that writes it; the report is capped against the wall clock. A satellite writes
    -- `consume = { maxRate = 5.0 }` and gets the event, the driver check, the clock cap and a
    -- transport that can't lose burn. Fuel uses the same code.
    if config.consume ~= nil then
        if type(config.consume) ~= 'table' then
            return false, ('vehicle stat "%s": consume must be a table'):format(name)
        end

        local maxRate = tonumber(config.consume.maxRate)
        if not maxRate or maxRate <= 0 then
            return false, ('vehicle stat "%s": consume.maxRate must be a positive number ' ..
                           '(units per second, flat out)'):format(name)
        end

        entry.consume = {
            -- The ceiling the server believes. Anything above this per second is a lie.
            maxRate    = maxRate,

            -- Only the driver may report (default true: a passenger must not drain a tank).
            driverOnly = config.consume.driverOnly ~= false,

            -- Take the stat OFF the vehicle when it bottoms out: right for an installable (a spent
            -- bottle), wrong for anything intrinsic (an empty tank). Only sound when the default
            -- IS the floor; see the guard below.
            clearAtMin = config.consume.clearAtMin == true,

            -- Headroom over maxRate, for tick jitter and bunched reports.
            slack      = tonumber(config.consume.slack) or 1.25,

            -- How often the client is expected to report, in seconds. Sets the client's own
            -- send cadence and the ceiling applied to the first report of a run.
            interval   = math.max(0.25, tonumber(config.consume.interval) or 1.0),
        }

        -- A cleared stat reads as its DEFAULT, so `clearAtMin` with a default above the floor
        -- would refill itself every time it ran out. Refused: the combination has no correct use.
        if entry.consume.clearAtMin and entry.default ~= entry.min then
            return false, ('vehicle stat "%s": consume.clearAtMin needs default (%s) to equal ' ..
                           'min (%s). Clearing a stat makes it read as its default, so with a ' ..
                           'higher default it would come back full every time it drained. Use ' ..
                           'clearAtMin for installables (default 0), and leave it off for ' ..
                           'anything a vehicle always has.')
                :format(name, tostring(entry.default), tostring(entry.min))
        end
    end

    -- Live: `consume` with the sign taken out, for a client-driven stat that rises and falls (turbo
    -- boost, engine heat, a battery charging). The client reports what the value IS, and the server
    -- refuses anything that rose faster than maxRate.
    if config.live ~= nil then
        if type(config.live) ~= 'table' then
            return false, ('vehicle stat "%s": live must be a table'):format(name)
        end

        -- Mutually exclusive with consume: two answers to "who owns this number", and whichever
        -- report arrived last would win.
        if entry.consume then
            return false, ('vehicle stat "%s": a stat cannot declare both `consume` and `live`. ' ..
                           'Use consume for something the vehicle burns down, live for a value ' ..
                           'the client drives up and down.'):format(name)
        end

        local maxRate = tonumber(config.live.maxRate)
        if not maxRate or maxRate <= 0 then
            return false, ('vehicle stat "%s": live.maxRate must be a positive number ' ..
                           '(the fastest it can honestly RISE, in units per second)'):format(name)
        end

        entry.live = {
            -- The ceiling on how fast it may climb. Only rising is capped: claiming less is fine.
            maxRate    = maxRate,

            -- Default true, as consume: a passenger must not drive the driver's engine.
            driverOnly = config.live.driverOnly ~= false,

            -- Headroom over maxRate for tick jitter and network travel, so lag isn't read as cheating.
            slack      = tonumber(config.live.slack) or 1.25,

            -- How often the client sends (the server measures against the wall clock, so sending
            -- more often gains nothing). Floored at 0.25, the sender's own tick. It sets how often
            -- OTHER people's gauges update; the local effect is applied every frame regardless.
            interval   = math.max(0.25, tonumber(config.live.interval) or 0.5),
        }
    end

    -- The same registration again changes nothing and announces nothing (whip_core:onReady fires
    -- on every resource start). A foreign re-registration is refused, with the owner's name.
    local ok, why = _vehicleStats:add(owner, name, entry)
    if not ok then return false, why --[[@as string]] end
    return true
end

--- Drop a registration. THE VALUES STAY: the usual cause is a satellite restarting (`ensure`), and
--- a stop can't be told from a restart, so the reversible reading is the safe one. An unregistered
--- stat is not read, gauged or decayed; it sits in the stored block until its owner comes back.
--- Deleting values is asked for by name: VehicleStats.purge.
---
--- Internal: a stopping resource's registrations are dropped by the registry's sweep (same onRemove).
---@param name string
function VehicleStats.unregister(name)
    local owner = VehicleStats._owners[name]
    if owner then _vehicleStats:remove(owner, name) end
end

--- Delete a stat's VALUES from every vehicle, everywhere, for good.
---
--- For a stat genuinely retired, not reloaded: the values leave the cache, the statebag and the database.
---@param name string
---@return number touched  how many vehicles carried a value
function VehicleStats.purge(name)
    if type(name) ~= 'string' then return 0 end

    -- Collect then clear: clear() calls the change listeners, and a listener must not change the
    -- cache under a `pairs` walk.
    local ids = {}
    for vehicleId, def in pairs(Vehicles.getAll()) do
        if type(def.vehStats) == 'table' and def.vehStats[name] ~= nil then
            ids[#ids + 1] = vehicleId
        end
    end

    local touched = 0
    for _, vehicleId in ipairs(ids) do
        -- Through clear(), so the removal replicates, persists and announces like any other.
        if VehicleStats.clear(vehicleId, name) then touched = touched + 1 end
    end
    return touched
end

--- The registered stats that want a gauge, ordered.
--- Same shape as Stats.getHudDefs, plus iconOnly (dropped, an icon-only stat draws an empty ring).
---@return table[]
function VehicleStats.getHudDefs()
    local defs = {}
    for name, config in pairs(VehicleStats._registry) do
        if config.hud then
            defs[#defs + 1] = {
                name          = name,
                max           = config.max,
                -- `min`, `default` and `label` travel too: the garage list draws these as
                -- labelled meters from the STORED block, so a never-driven car falls back to
                -- the default.
                min           = config.min,
                default       = config.default,
                label         = config.hud.label,
                icon          = config.hud.icon,
                iconCritical  = config.hud.iconCritical,
                color         = config.hud.color,
                order         = config.hud.order,
                iconOnly      = config.hud.iconOnly,
                heartbeat     = config.hud.heartbeat,
                hideWhenEmpty = config.hud.hideWhenEmpty,
                noCritical    = config.hud.noCritical,
                showAboveZero = config.hud.showAboveZero,

                -- This is the only function that hands gauges to a client, so the flag must be here.
                showWhenPresent = config.hud.showWhenPresent,

                -- What the gauge shows instead of a percentage (normDisplay): 14 psi, or E and F at its ends.
                display = config.display,
            }
        end
    end
    table.sort(defs, function(a, b) return a.order < b.order end)
    return defs
end

--- Push the gauge list to everyone. Called whenever the registry changes, so a stat registered by
--- a satellite that started late still gets a gauge without anyone reconnecting.
function VehicleStats.broadcastHudDefs()
    if not Players then return end
    local defs = VehicleStats.getHudDefs()
    for src in pairs(Players) do
        TriggerClientEvent('whip_core:client:vehicleHudDefs', src, defs)
    end
end

--- Every registered stat, gauge or not, as the client needs to understand it.
---
--- Separate from the gauge list: a stat with no `hud` still has a default the client must resolve
--- (so both sides agree on an unset stat), and a `consume` stat a cadence it reports on.
---@return table[]
function VehicleStats.getStatDefs()
    local defs = {}
    for name, config in pairs(VehicleStats._registry) do
        defs[#defs + 1] = {
            name    = name,
            default = config.default,
            min     = config.min,
            max     = config.max,
            -- Only the cadence crosses: maxRate, slack and the driver rule stay server-side.
            consumeInterval = config.consume and config.consume.interval or nil,
            liveInterval    = config.live and config.live.interval or nil,
            display = config.display,   -- the /whip Vehicles page shows each value as it reads (normDisplay)
        }
    end
    return defs
end

--- Push the registry to everyone. Same trigger as the gauge list.
function VehicleStats.broadcastStatDefs()
    if not Players then return end
    local defs = VehicleStats.getStatDefs()
    for src in pairs(Players) do
        TriggerClientEvent('whip_core:client:vehicleStatDefs', src, defs)
    end
end

--- The stats a vehicle actually HAS a stored value for, as a plain copy.
---
--- Distinct from getAll, which fills in every default: `nitro = nil` means no bottle fitted,
--- `nitro = 0` a bottle fitted and empty. The vehicle-list payloads send THIS.
---@param vehicleId number
---@return table
function VehicleStats.getStored(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def or type(def.vehStats) ~= 'table' then return {} end

    local out = {}
    for k, v in pairs(def.vehStats) do out[k] = v end
    return out
end

--- The stats a vehicle has stored that are SAVED (a registered stat, not `persist = false`): what a car made from
--- this one carries over (ClaimVehicle: its fuel, its damage, a resource's own; not whether its engine runs).
---@param vehicleId number
---@return table
function VehicleStats.getSaved(vehicleId)
    local out = {}
    for name, v in pairs(VehicleStats.getStored(vehicleId)) do
        local config = VehicleStats._registry[name]
        if config and config.persist ~= false then out[name] = v end
    end
    return out
end

-- ============================================
-- Values
-- ============================================

--- Every stat on a vehicle, filled in with defaults for anything unset.
---@param vehicleId number
---@return table|nil
function VehicleStats.getAll(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def then return nil end
    if type(def.vehStats) ~= 'table' then def.vehStats = {} end

    local out = {}
    for name, config in pairs(VehicleStats._registry) do
        local v = def.vehStats[name]
        out[name] = tonumber(v) or config.default
    end
    return out
end

--- A stat's registered maximum — 100 when it declares none.
---@param name string
---@return number
function VehicleStats.maxOf(name)
    local config = VehicleStats._registry[name]
    return (config and tonumber(config.max)) or 100.0
end

--- A stat's registered default — nil when it declares none, or no stat has that name.
---@param name string
---@return number|nil
function VehicleStats.defaultOf(name)
    local config = VehicleStats._registry[name]
    return config and config.default
end

--- Is a stat by this name registered (by config or a satellite)?
---@param name string
---@return boolean
function VehicleStats.isRegistered(name)
    return VehicleStats._registry[name] ~= nil
end

---@param vehicleId number
---@param name string
---@return number|nil
function VehicleStats.get(vehicleId, name)
    local def = Vehicles.getDef(vehicleId)
    if not def then return nil end

    local stored = type(def.vehStats) == 'table' and def.vehStats[name] or nil
    if stored ~= nil then return tonumber(stored) end

    local config = VehicleStats._registry[name]
    return config and config.default or nil
end

--- Sentinel meaning "delete this path" in the dirty queue.
---
--- A table can't hold nil, and a unique table never collides with a real value.
VehicleStats.REMOVE = setmetatable({}, { __tostring = function() return '<remove>' end })

-- ============================================
-- Announcing a change
-- ============================================

--- Changes accumulated inside an open `batched` scope, per vehicle.
---
--- [vehicleId] = { order = { statName, ... }, byStat = { [statName] = entry } }
VehicleStats._batchChanges = {}

--- Server-side per-stat subscribers: [statName or '*']['<resource>:<id>'] = { fn, owner }
---
--- Keyed, not an array, so re-registering replaces (see OnVehicleStatChanged). The owner is stored
--- with each callback. '*' hears every stat.
VehicleStats._statListeners = {}

--- whip_core's OWN files hear one vehicle stat change here (the Systems Creator's "the engine starts"),
--- on the path OnVehicleStatChanged's listeners take (announce, below: once per transaction).
--- `fn({ vehicleId, key, value, old, cleared, source })` must not wait. Keyed `whip_core:<id>`: the
--- same id again replaces it.
---@param name string
---@param id string
---@param fn function
function VehicleStats.onChange(name, id, fn)
    local list = VehicleStats._statListeners[name]
    if not list then list = {}; VehicleStats._statListeners[name] = list end
    local owner = GetCurrentResourceName()
    list[('%s:%s'):format(owner, tostring(id))] = { fn = fn, owner = owner, asTable = true }
end

--- Call one listener, one table or positional as it registered. A '*' listener is also told which
--- stat moved: positional, the name comes second, as OnStatChanged's '*' does for players.
---@param reg table
---@param wildcard boolean
local function callListener(reg, wildcard, vehicleId, name, entry)
    -- pcall, and no type check: callables through an export aren't type 'function'.
    local ok, err
    if reg.asTable then
        ok, err = pcall(reg.fn, {
            vehicleId = vehicleId, key = name, value = entry.value, old = entry.previous,
            cleared = entry.cleared == true, source = entry.source,
        })
    elseif wildcard then
        ok, err = pcall(reg.fn, vehicleId, name, entry.value, entry.previous,
                        entry.cleared == true, entry.source)
    else
        ok, err = pcall(reg.fn, vehicleId, entry.value, entry.previous,
                        entry.cleared == true, entry.source)
    end
    if not ok then
        print(('[whip_core:vehstats] server listener for "%s" errored: %s'):format(name, tostring(err)))
    end
end

--- Tell the listeners what moved, once per transaction (`batched`), in the order it was written.
--- Only a stat someone subscribed to (OnVehicleStatChanged, VehicleStats.onChange) costs more than a
--- lookup. There is no broadcast event: one entered every running resource on every change, heard
--- or not.
---
--- Not batching over time: the batch is bounded by one synchronous call, every write in it has
--- completed, and the listeners run in the same frame. Never make it timer-driven ("collect for
--- 50 ms"): that would become a real source of desync.
---@param vehicleId number
---@param order table   stat names in the order they were written
---@param byStat table  [statName] = { stat, value, previous, cleared, source }
local function announce(vehicleId, order, byStat)
    local wild = VehicleStats._statListeners['*']
    for i = 1, #order do
        local name = order[i]
        local listeners = VehicleStats._statListeners[name]
        if listeners or wild then
            local entry = byStat[name]
            -- pairs: listeners are keyed by '<resource>:<id>'. Order between listeners is undefined.
            if listeners then
                for _, reg in pairs(listeners) do callListener(reg, false, vehicleId, name, entry) end
            end
            if wild then
                for _, reg in pairs(wild) do callListener(reg, true, vehicleId, name, entry) end
            end
        end
    end

    -- whip_core's own debug overlay is told directly.
    VehicleStats.tellDebugWatchers({ vehicleId = vehicleId, changes = byStat, order = order })
end

--- Announce one change, or fold it into the open batch if this vehicle has one.
---
--- A stat written twice inside a single batch keeps its ORIGINAL `previous`, so the
--- announcement describes the whole transaction rather than only its last hop.
---@param vehicleId number
---@param entry table
local function announceChange(vehicleId, entry)
    local batch = VehicleStats._batchChanges[vehicleId]
    if not batch then
        announce(vehicleId, { entry.stat }, { [entry.stat] = entry })
        return
    end

    local prior = batch.byStat[entry.stat]
    if prior then
        entry.previous = prior.previous
    else
        batch.order[#batch.order + 1] = entry.stat
    end
    batch.byStat[entry.stat] = entry
end

--- Take a stat off ONE vehicle, rather than off every vehicle.
---
--- For anything installable (a nitrous bottle, a tow hook): "present" is the key existing in the
--- stored block, so removing it is not the same as setting zero. Afterwards `get` and `getAll`
--- report the registered default.
---@param vehicleId number|string|nil
---@param name string
---@return boolean ok
---@return string|nil err
function VehicleStats.clear(vehicleId, name)
    vehicleId = tonumber(vehicleId)
    if not vehicleId then return false, 'Invalid vehicleId' end
    if type(name) ~= 'string' then return false, 'stat name must be a string' end

    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'Vehicle not found' end
    if type(def.vehStats) ~= 'table' then return true end
    if def.vehStats[name] == nil then return true end        -- already absent; nothing to announce

    local old = def.vehStats[name]
    def.vehStats[name] = nil

    -- Both keys: presence lives in the main block, and a live stat must leave the live key too.
    VehicleStats.replicate(vehicleId)

    local clearedConfig = VehicleStats._registry[name]
    if clearedConfig and clearedConfig.live then
        VehicleStats.replicateLive(vehicleId)
    end

    -- A live stat taken off takes its cursor (the rate check's baseline), so a refit starts from idle.
    local liveByVeh = VehicleStats._liveCursors[vehicleId]
    if liveByVeh then liveByVeh[name] = nil end

    -- Same guards as persist: session vehicles have no row, and the name reaches SQL as a JSON path.
    local config = VehicleStats._registry[name]
    if not def.session and (not config or config.persist) and name:match('^[%w_]+$') then
        queueStat(vehicleId, name, VehicleStats.REMOVE)
    end

    -- Announced with `cleared` ("gone", not "zero"); `value` is the registered default now.
    announceChange(vehicleId, {
        stat     = name,
        value    = config and config.default or 0,
        previous = old,
        cleared  = true,
        source   = 'clear',
    })
    return true
end

--- Write a stat: clamp it, store it, persist it, replicate it, announce it.
---@param vehicleId number
---@param name string
---@param value number|string|nil
---@param changeSource string|nil  for the event payload, e.g. 'refuel:pump'
---@return boolean ok
---@return string|nil err  why not
function VehicleStats.set(vehicleId, name, value, changeSource)
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'Vehicle not found' end

    value = tonumber(value)
    if not value then return false, ('value for "%s" must be a number'):format(tostring(name)) end

    local config = VehicleStats._registry[name]
    if config then
        value = math.max(config.min, math.min(config.max, value))
    end

    if type(def.vehStats) ~= 'table' then def.vehStats = {} end
    local old = def.vehStats[name]
    if old == value then return true end
    def.vehStats[name] = value

    -- A write that is not the driver's report restarts the live rate check (applyLiveReport):
    -- otherwise the next report would measure from the driver's OLD value and drag this one back.
    -- The next report adopts the stored value as its baseline, as a first report does.
    if changeSource ~= 'live' then
        local liveByVeh = VehicleStats._liveCursors and VehicleStats._liveCursors[vehicleId]
        if liveByVeh then liveByVeh[name] = nil end
    end

    -- Fuel is a stat like any other: no branch here, no second home on the def.

    -- Which key this goes out on: a client's live report moves only the live key (a number changing
    -- several times a second must not drag the whole block). Anything else moves the main block,
    -- and a live stat written that way (fitted, set by an admin) refreshes the live key too.
    if config and config.live and changeSource == 'live' then
        VehicleStats.replicateLive(vehicleId)
    else
        VehicleStats.replicate(vehicleId)
        if config and config.live then VehicleStats.replicateLive(vehicleId) end
    end

    -- Presence mode writes when the stat appears (`old == nil`), and not again: after that it is the
    -- live value moving. Removal is clear()'s, which marks the deletion itself.
    local presenceOnly = config and config.persistMode == 'presence' and old ~= nil
    if not presenceOnly then
        VehicleStats.persist(vehicleId, name, value, config)
    end

    announceChange(vehicleId, {
        stat     = name,
        value    = value,
        previous = old,
        source   = changeSource or 'direct',
    })

    return true
end

--- Write several stats at once, replicating ONCE at the end rather than once per stat.
---
--- The closure handed to `batched` is made HERE, in whip_core's own Lua state, so the grouping
--- doesn't depend on a satellite's function crossing the resource boundary once per stat.
---@param vehicleId number
---@param values table  [statName] = value
---@param changeSource string|nil
---@return number written
function VehicleStats.setMany(vehicleId, values, changeSource)
    if type(values) ~= 'table' then return 0 end
    if not Vehicles.getDef(vehicleId) then return 0 end

    local written = 0
    VehicleStats.batched(vehicleId, function()
        for name, value in pairs(values) do
            if type(name) == 'string' and tonumber(value) then
                if VehicleStats.set(vehicleId, name, value, changeSource) then
                    written = written + 1
                end
            end
        end
    end)
    return written
end

---@param vehicleId number
---@param name string
---@param delta number
---@param changeSource string|nil
---@return boolean
function VehicleStats.add(vehicleId, name, delta, changeSource)
    local current = VehicleStats.get(vehicleId, name)
    if current == nil then
        local config = VehicleStats._registry[name]
        current = config and config.default or 0
    end
    return VehicleStats.set(vehicleId, name, current + (tonumber(delta) or 0), changeSource)
end

-- ============================================
-- Replication and Persistence
-- ============================================

--- Vehicles whose replication is currently held: [vehicleId] = nesting depth.
VehicleStats._replicateHeld = {}

--- Which keys a held batch still owes a write to. See VehicleStats.batched.
VehicleStats._replicatePending = {}

--- Put a vehicle's stats on the entity, where every client in range can read them.
---
--- Only what the car actually has (the STORED block, not getAll's every default): every fuel tick
--- re-sends the block, so it stays small. Every reader resolves a missing key to the registered default.
---@param vehicleId number
function VehicleStats.replicate(vehicleId)
    if VehicleStats._replicateHeld[vehicleId] then
        local pending = VehicleStats._replicatePending[vehicleId]
        if pending then pending.main = true end
        return
    end

    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return end

    -- Named for the profiler: serialising the block for everyone with the car in scope grows with
    -- how many people are watching.
    ProfilerEnterScope('whip:statReplicate')

    -- Empty replicates as absent, matching the Sentinel truth below: a mismatch strikes the
    -- entity's owner (see VehicleData.replicate), and three strikes is a kick.
    local stored = VehicleStats.getStored(vehicleId)
    local block = next(stored) ~= nil and stored or nil

    Sentinel.setEntityKey(entity, VEHICLE_STATS_KEY, block)   -- whip's own write
    ProfilerExitScope()
end

--- The current value of every live stat this vehicle carries, or nil when it carries none.
---
--- Built from the same `def.vehStats` as the main block: one source of truth, two keys.
---@param vehicleId number
---@return table|nil
local function liveBlock(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def or type(def.vehStats) ~= 'table' then return nil end

    local out, any = nil, false
    for name, value in pairs(def.vehStats) do
        local config = VehicleStats._registry[name]
        if config and config.live then
            out = out or {}
            out[name] = value
            any = true
        end
    end

    -- nil rather than an empty table: an absent key replicates nothing (nearly every car).
    return any and out or nil
end

--- Put the live values on the entity, on their own key.
---
--- Separate from replicate() so a value moving several times a second does not drag the whole stat
--- block along with it. See VEHICLE_LIVE_KEY in shared/statebags.lua for why.
---@param vehicleId number
function VehicleStats.replicateLive(vehicleId)
    if VehicleStats._replicateHeld[vehicleId] then
        local pending = VehicleStats._replicatePending[vehicleId]
        if pending then pending.live = true end
        return
    end

    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return end

    -- Same scope name as the main block: the cost of a stat block on the wire, whichever key.
    ProfilerEnterScope('whip:statReplicate')
    Sentinel.setEntityKey(entity, VEHICLE_LIVE_KEY, liveBlock(vehicleId))   -- whip's own write
    ProfilerExitScope()
end

--- Make several stat writes to one vehicle and replicate ONCE at the end.
---
--- The stat block is one statebag key (shared/statebags.lua), and every set re-sends all of it:
--- ten stats changing together (a burn report) would send it ten times. The announcement is held
--- the same way (see `announce`): the listeners run once the transaction is over.
---
--- Reentrant, and it replicates AND announces on the way out even if `fn` throws: the writes it
--- already made are real.
---@param vehicleId number
---@param fn function
function VehicleStats.batched(vehicleId, fn)
    local held = VehicleStats._replicateHeld
    held[vehicleId] = (held[vehicleId] or 0) + 1

    if not VehicleStats._batchChanges[vehicleId] then
        VehicleStats._batchChanges[vehicleId] = { order = {}, byStat = {} }
        VehicleStats._replicatePending[vehicleId] = {}
    end

    local ok, err = pcall(fn)

    held[vehicleId] = held[vehicleId] - 1

    local batch
    if held[vehicleId] <= 0 then
        held[vehicleId] = nil
        batch = VehicleStats._batchChanges[vehicleId]
        VehicleStats._batchChanges[vehicleId] = nil

        -- Only the keys actually written: a live report must not re-send the main block.
        local pending = VehicleStats._replicatePending[vehicleId]
        VehicleStats._replicatePending[vehicleId] = nil

        if pending then
            if pending.main then VehicleStats.replicate(vehicleId) end
            if pending.live then VehicleStats.replicateLive(vehicleId) end
        end
    end

    -- Announced AFTER the hold is released, so a listener that writes another stat to this
    -- vehicle opens a batch of its own rather than silently joining one already on its way out.
    if batch and batch.order[1] then
        announce(vehicleId, batch.order, batch.byStat)
    end

    if not ok then error(err, 0) end
end

--- Mark a stat as needing a trip to disk. The write itself happens on the flush thread.
---@param vehicleId number
---@param name string
---@param value number
---@param config table|nil
function VehicleStats.persist(vehicleId, name, value, config)
    local def = Vehicles.getDef(vehicleId)
    if not def or def.session then return end          -- session vehicles have no row
    if config and not config.persist then return end

    -- The stat name reaches SQL as a JSON path, so it must not be able to carry one.
    if not name:match('^[%w_]+$') then
        print(('[whip_core:vehstats] refusing to persist stat with an unsafe name: %s'):format(name))
        return
    end

    queueStat(vehicleId, name, value)
end

--- One statement for a car's waiting stats: JSON_REMOVE for the cleared ones (a null would still be
--- a key), then JSON_SET for the rest, each by its own path. By path, not re-encoding the block, so
--- two writers can't lose each other's updates (stats have more than one writer by design).
---@param vehicleId number
---@param stats table  [name] = value | VehicleStats.REMOVE
---@return table|nil query
local function statsQuery(vehicleId, stats)
    local removes, sets, values = {}, {}, {}
    for name, value in pairs(stats) do
        if value == VehicleStats.REMOVE then
            removes[#removes + 1] = ("'$.%s'"):format(name)
        else
            sets[#sets + 1] = ("'$.%s', ?"):format(name)
            values[#values + 1] = value
        end
    end
    if #removes == 0 and #sets == 0 then return nil end
    local expr = "COALESCE(`vehStats`, '{}')"
    if #removes > 0 then expr = ('JSON_REMOVE(%s, %s)'):format(expr, table.concat(removes, ', ')) end
    if #sets > 0 then expr = ('JSON_SET(%s, %s)'):format(expr, table.concat(sets, ', ')) end
    values[#values + 1] = vehicleId
    return { query = ('UPDATE `vehicles` SET `vehStats` = %s WHERE `vehicleId` = ?'):format(expr), values = values }
end

-- The car's row is a save unit, `vehrow:<vehicleId>`: its stats and its position. The Stores engine
-- writes it every VehicleStatsSaveInterval (15 s), or at once with whatever the same player action
-- took; never given up on, sent at a stop and in the final save, one write per car at a time. Only
-- what was sent is cleared, so a value set again during the write keeps its newer value.
-- (Ownership, state, garage, lock and looks are Vehicles.persist's, written at once; car data is
-- its own 'now' unit, vehicle_data.lua.)
Stores.defineUnit('vehrow', {
    what      = 'vehicle stats and positions',
    faultMode = 'vehicle_stats',
    every = math.max(1000, (Config.VehicleStatsSaveInterval or 15) * 1000),
    label = function(vehicleId) return ('row of vehicle #%s'):format(tostring(vehicleId)) end,
    persist = function(vehicleId)
        local queries, sent = {}, {}
        for name, value in pairs(VehicleStats._dirty[vehicleId] or {}) do sent[name] = value end
        queries[#queries + 1] = statsQuery(vehicleId, sent)
        local posQuery, posConfirm = Vehicles.pendingPosition(vehicleId)
        if posQuery then queries[#queries + 1] = posQuery end
        if #queries == 0 then return {} end
        return queries, function()
            local now = VehicleStats._dirty[vehicleId]
            if now then
                for name, value in pairs(sent) do
                    if now[name] == value then now[name] = nil end
                end
                if next(now) == nil then VehicleStats._dirty[vehicleId] = nil end
            end
            if posConfirm then posConfirm() end
        end
    end,
})

-- A deleted car's row is gone: nothing it was owed may be written after (Vehicles.delete announces it).
Vehicles.onLife('deleted', function(data)
    VehicleStats._dirty[data.vehicleId] = nil
    Stores.forget('vehrow:' .. tostring(data.vehicleId))
end)

--- Write what is waiting now, for one vehicle or all of them, through the engine. For callers that
--- need it on disk (whip_test's flush seam); nothing in play has to call it.
---@param onlyVehicleId number|nil
---@return boolean ok  false when something is still owed
function VehicleStats.flush(onlyVehicleId)
    local ids = {}
    if onlyVehicleId then
        ids[1] = onlyVehicleId
    else
        for vehicleId in pairs(VehicleStats._dirty) do ids[#ids + 1] = vehicleId end
    end
    local ok = true
    for _, vehicleId in ipairs(ids) do
        if VehicleStats._dirty[vehicleId] then Stores.markDirty(Stores.unit('vehrow', vehicleId)) end
        if not Stores.settle('vehrow:' .. tostring(vehicleId)) then ok = false end
    end
    return ok
end

-- At a stop and in the final save, car stats go with every other save unit (the stop's step 60
-- dispatch runs after step 40's despawns switch every engine stat off).

-- ============================================
-- Lifecycle
-- ============================================

-- Lifecycle hooks, not event handlers (see Vehicles.announce): another resource firing the public
-- event does not run them.

-- A vehicle entering the world gets its stats put on it immediately, so a client that streams it
-- in never sees a car with no stat block.
Vehicles.onLife('spawned', function(data)
    VehicleStats.replicate(data.vehicleId)
end)

-- Same for a street car whip has just taken on — it is in the world already, so nothing else is
-- going to trigger the first replication.
Vehicles.onLife('registered', function(data)
    VehicleStats.replicate(data.vehicleId)
end)

-- Hand a joining player the gauge list (a Character hook, so the feature stays in one file).
Character.onLife('loaded', function(e)
    TriggerClientEvent('whip_core:client:vehicleHudDefs', e.source, VehicleStats.getHudDefs())
    TriggerClientEvent('whip_core:client:vehicleStatDefs', e.source, VehicleStats.getStatDefs())
end)

-- A vehicle that leaves the world loses its bookkeeping, and is not running when it comes back.
Vehicles.onLife('despawned', function(data)
    local vehicleId = data.vehicleId
    VehicleStats._lastDecay[vehicleId] = nil
    -- The consumption cursor goes with it (a car that comes back starts a new run).
    VehicleStats.forgetConsume(vehicleId)
    if Vehicles.getDef(vehicleId) then
        VehicleStats.set(vehicleId, 'engine', 0, 'despawned')
    end
end)

-- Vehicles.release does not announce despawned — it hands a street car back without deleting it —
-- so decay bookkeeping for released vehicles would leak without this.
Vehicles.onLife('released', function(data)
    VehicleStats._lastDecay[data.vehicleId] = nil
    VehicleStats.forgetConsume(data.vehicleId)
end)

-- ============================================
-- Tick — one thread, every vehicle
-- ============================================

-- The period is read before each wait, so a change in /whip → Settings takes effect from the next
-- tick. On Every (lifecycle.lua), so one error can't end every car's decay.
Every('vehicle stat decay tick', function() return math.max(250, (Config.VehicleStatsTickInterval or 1) * 1000) end, function()
    -- Nothing at all unless something decays (no built-in stat does: fuel is reported by the
    -- driver, engine is a discrete state), and then asked again only every 5 s: a stat registered
    -- with a decay starts within that.
    local anyDecays = false
    for _, config in pairs(VehicleStats._registry) do
        if config.decay then anyDecays = true break end
    end
    if not anyDecays then return 5000 end

    local now = GetGameTimer()

    -- Only the cars in the world (spawnedIds, a copy, so a spawn mid-walk changes nothing).
    local spawned = Vehicles.spawnedIds()
    for _, vehicleId in ipairs(spawned) do
        -- The analogue of "is this player still here". A vehicle with no entity is not in
        -- the world, so nothing about it should be draining.
        local def = Vehicles.getDef(vehicleId)
        local entity = (def and def.state == 'out') and Vehicles.getEntity(vehicleId) or nil
        if def and entity then
            for name, config in pairs(VehicleStats._registry) do
                -- A presence stat decays only on a car that HAS it: add() on an absent stat would
                -- write default+delta, fitting the part.
                local vs = def.vehStats
                local present = config.persistMode ~= 'presence'
                    or (type(vs) == 'table' and vs[name] ~= nil)
                if config.decay and present then
                    local interval = config.decayInterval * 1000
                    local last = (VehicleStats._lastDecay[vehicleId] or {})[name] or 0

                    if now - last >= interval then
                        if not VehicleStats._lastDecay[vehicleId] then
                            VehicleStats._lastDecay[vehicleId] = {}
                        end
                        VehicleStats._lastDecay[vehicleId][name] = now
                        VehicleStats.add(vehicleId, name, config.decay, 'decay')
                    end
                end
            end
        end
    end
end)

-- A built-in vehicle stat changed in /whip → Settings ('VehicleStats.engine'): registered again with
-- its new figures.
Settings.onChange('VehicleStats', function(_, _, path)
    local name = path:match('^VehicleStats%.([^%.]+)')
    if not (name and Config.VehicleStats and Config.VehicleStats[name]) then return end
    local ok, err = VehicleStats.register(name, Config.VehicleStats[name], GetCurrentResourceName())
    if not ok then print(('[whip_core:vehstats] %s did not take its new settings: %s'):format(name, tostring(err))) end
end)

-- The car-row save unit's interval is read at each flush pass, so a new one only needs handing over.
Settings.onChange('VehicleStatsSaveInterval', function(v)
    Stores.setUnitEvery('vehrow', math.max(1000, (v or 15) * 1000))
end)

-- ============================================
-- Built-ins
-- ============================================

CreateThread(function()
    Wait(0)   -- the next tick, once every server file has run (config.lua and shared load first)

    for name, config in pairs(Config.VehicleStats or {}) do
        local ok, err = VehicleStats.register(name, config, GetCurrentResourceName())
        if not ok then
            print(('[whip_core:vehstats] could not register built-in "%s": %s'):format(name, tostring(err)))
        end
    end

end)

-- ============================================
-- Consumption — one event, every consumable stat
-- ============================================
--
-- The client measures it because it already knows it (speed and throttle, every frame). The
-- server owns the value, clamps each report against the time that actually passed, and is the
-- only thing that writes the stat. One event for every consumable stat, driven by its registration.
--
-- The exploit surface, plainly: a modified client can under-report (or stop reporting) and pay
-- less. It cannot over-report beyond the cap, touch a vehicle it isn't driving, or set an absolute
-- value. A fair trade for not sampling every vehicle on the server every second.

--- Apply an allowed amount of burn to a stat, honouring clearAtMin.
---@---@param vehicleId number
---@param name string
---@param take number    already capped
---@param config table   registry entry
local function applyBurn(vehicleId, name, take, config)
    local rule = config.consume
    local current = VehicleStats.get(vehicleId, name)
    if current == nil then current = config.default end

    local left = current - take

    -- At the floor, installables come off rather than sit at zero (a spent bottle is no bottle).
    if left <= config.min and rule.clearAtMin then
        VehicleStats.clear(vehicleId, name)
    else
        VehicleStats.set(vehicleId, name, left, 'consume')
    end
end

--- May this reporter write this kind of stat? Answered at most once per batch, per kind.
---
--- The rule (`driverOnly`) is per stat; the answer is per batch: within one batch the source,
--- vehicle and seat are fixed (nothing yields between stats). Each answer costs three natives, so
--- it is memoised, and only worked out if asked.
---@param occ table  { source, vehicleId } — gains `driving` / `inside` as they are worked out
---@param driverOnly boolean
---@return boolean
local function mayReport(occ, driverOnly)
    if driverOnly then
        local v = occ.driving
        if v == nil then
            v = Vehicles.isPlayerDriving(occ.source, occ.vehicleId)
            occ.driving = v
        end
        return v
    end

    local v = occ.inside
    if v == nil then
        v = Vehicles.isPlayerIn(occ.source, occ.vehicleId)
        occ.inside = v
    end
    return v
end

--- Apply one stat's running-total report (several arrive together in one batch).
---@param source number
---@param vehicleId number
---@param name string
---@param total number
---@param now number  one clock reading for the whole batch
---@param occ table   the batch's occupancy memo — see mayReport
local function applyStatReport(source, vehicleId, name, total, now, occ)
    local config = VehicleStats._registry[name]
    if not (config and config.consume) then return end   -- not a consumable stat; nothing to do

    local rule = config.consume

    -- Who may report: by default the driver (a passenger must not drain someone's tank). The rule
    -- is per stat; the answer is worked out once for the batch (mayReport).
    if not mayReport(occ, rule.driverOnly) then return end

    local byVeh = VehicleStats._consumeCursors[vehicleId]
    if not byVeh then
        byVeh = {}
        VehicleStats._consumeCursors[vehicleId] = byVeh
    end
    local cursor = byVeh[name]

    -- One reporter at a time, latched (matters with `driverOnly = false`): switching on every new
    -- source would re-baseline every message and never bill. Another reporter takes over only once
    -- the latched one has gone quiet past the cadence; anyone else is ignored.
    if cursor and cursor.source ~= source then
        if (now - cursor.last) <= (rule.interval * 1000 * 4) then
            return                                   -- the latched reporter is still live
        end
        cursor = nil                                 -- they went quiet; hand over
    end

    -- A new run (no reporter yet, a new reporter, or the client's counter went backwards): adopt
    -- the baseline and charge NOTHING. With no baseline there is no honest amount, only a number
    -- the client chose, and `total < cursor.total` is the client's to trigger (a descending
    -- sequence would bill the allowance on every report). Every other path multiplies by time the
    -- SERVER measured. The cost: at most one interval of burn forgiven, and none for whip's own client, which tells each
    -- run's start (0) on its own before any burn (client/vehicle_stats.lua accumulateConsume).
    if not cursor or total < cursor.total then
        byVeh[name] = { total = total, source = source, last = now }
        return
    end

    local delta = total - cursor.total
    if delta <= 0 then
        cursor.last = now
        return
    end

    -- Cap it against the clock: no more than a flat-out rate since it last spoke.
    local elapsed = math.min((now - cursor.last) / 1000.0, rule.interval * 4)
    local take    = math.min(delta, rule.maxRate * elapsed * rule.slack)

    -- How far the cursor moves when the clock refused part of the claim: by what was billed, with
    -- what stays outstanding bounded to one interval's worth. Jitter and a dropped report are
    -- recovered next time; a fabricated total is written off almost at once and can't be banked.
    cursor.total = cursor.total + take

    local maxOutstanding = rule.maxRate * rule.interval * rule.slack
    if total - cursor.total > maxOutstanding then
        cursor.total = total - maxOutstanding
    end

    cursor.last = now

    if take <= 0 then return end

    applyBurn(vehicleId, name, take, config)
end

--- One report per vehicle, carrying every stat that burned: SecureEvent's rate limiter buckets on
--- (source, eventName), so one event per stat would share one bucket. The clock cap bounds
--- cheating; the limiter only stops a flood.
SecureEvent('whip_core:server:reportStatBurn', {
    whileDead = true,   -- fuel already burned is owed whatever happened to the driver
    rateLimit = 200,
    burst     = 6,
    params = {
        { 'vehicleId', 'id' },
        -- A map of stat name -> running total: `any` (a variable key set), validated in full below.
        { 'totals', 'any' },
    },
}, function(source, _, vehicleId, totals)
    if type(totals) ~= 'table' then return end
    if not Vehicles.getDef(vehicleId) then return end

    -- One clock reading, one occupancy answer (mayReport) and one replication (VehicleStats.batched)
    -- for the whole batch: every stat in it is one reporter, one vehicle, one interval.
    local now = GetGameTimer()

    local occ = { source = source, vehicleId = vehicleId }

    VehicleStats.batched(vehicleId, function()
        -- Bounded walk: the table's size is the client's choice.
        local seen = 0
        for name, total in pairs(totals) do
            seen = seen + 1
            if seen > 64 then break end

            if type(name) == 'string' and type(total) == 'number'
                and total == total                      -- NaN fails every comparison below
                and total >= 0 and total < 1e9
                and name:match('^[%w_]+$')
            then
                applyStatReport(source, vehicleId, name, total, now, occ)
            end
        end
    end)
end)

-- ============================================
-- Live values
-- ============================================
--
-- The rising counterpart to consumption, the same shape as the burn path: the client reports what
-- the value IS, and only the upward direction is policed.

--- Last accepted live value per vehicle, for the rate check.
--- [vehicleId] = { [name] = { value = number, at = ms } }
VehicleStats._liveCursors = {}

--- Take one client claim about what a live stat is now worth.
---
--- The defence is the clock, as for consumption: no value further above the last accepted one than
--- maxRate could carry it since. A client sending 100 every frame gets the honest ramp.
---@param _ number  the reporting player
---@param vehicleId number
---@param name string
---@param value number
---@param now number
---@param occ table  the batch's occupancy memo — see mayReport
local function applyLiveReport(_, vehicleId, name, value, now, occ)
    local config = VehicleStats._registry[name]
    if not (config and config.live) then return end   -- not a live stat; nothing to do

    local rule = config.live

    -- Only on a stat the vehicle already carries: a report must never CREATE one (a free turbo).
    -- Read off the cache, not getStored (which builds a table): this runs several times a second.
    local def = Vehicles.getDef(vehicleId)
    local stored = def and type(def.vehStats) == 'table' and def.vehStats[name] or nil
    if stored == nil then return end

    -- Rule per stat, answer per batch. Same split as the consumption path — see mayReport.
    if not mayReport(occ, rule.driverOnly) then return end

    local byVeh = VehicleStats._liveCursors[vehicleId]
    if not byVeh then
        byVeh = {}
        VehicleStats._liveCursors[vehicleId] = byVeh
    end

    local cursor = byVeh[name]

    -- A new run: adopt the stored value as the baseline, not the claim (as the burn path: a first
    -- report has no honest interval to measure against).
    if not cursor then
        cursor = { value = stored, at = now }
        byVeh[name] = cursor
    end

    local elapsed = math.min((now - cursor.at) / 1000.0, rule.interval * 4)
    local ceiling = cursor.value + (rule.maxRate * elapsed * rule.slack)

    -- Rising is capped; falling is not (understating yourself is no exploit).
    if value > ceiling then value = ceiling end

    if value < config.min then value = config.min end
    if value > config.max then value = config.max end

    cursor.value = value
    cursor.at    = now

    VehicleStats.set(vehicleId, name, value, 'live')
end

--- One report per vehicle, carrying every live stat that moved (batched as the burn path, for the
--- rate limiter's per-event bucket).
SecureEvent('whip_core:server:reportStatLive', {
    whileDead = true,   -- a reading off the car, not an action
    rateLimit = 150,
    burst     = 6,
    params = {
        { 'vehicleId', 'id' },
        -- A map of stat name -> current value: `any`, validated in full below.
        { 'values', 'any' },
    },
}, function(source, _, vehicleId, values)
    if type(values) ~= 'table' then return end
    if not Vehicles.getDef(vehicleId) then return end

    local now = GetGameTimer()

    -- One occupancy answer for the batch, as on the burn path above.
    local occ = { source = source, vehicleId = vehicleId }

    VehicleStats.batched(vehicleId, function()
        local seen = 0
        for name, value in pairs(values) do
            seen = seen + 1
            if seen > 64 then break end

            if type(name) == 'string' and type(value) == 'number'
                and value == value                      -- NaN fails every comparison below
                and value >= -1e9 and value < 1e9
                and name:match('^[%w_]+$')
            then
                applyLiveReport(source, vehicleId, name, value, now, occ)
            end
        end
    end)
end)

--- Forget per-vehicle report bookkeeping for a vehicle that has left the world.
---
--- Both cursor tables (nothing else prunes them). Every caller means "this car is gone".
---@param vehicleId number
function VehicleStats.forgetConsume(vehicleId)
    VehicleStats._liveCursors[vehicleId] = nil
    VehicleStats._consumeCursors[vehicleId] = nil
end

-- ============================================
-- Engine state
-- ============================================
--
-- The engine is an ordinary stat, so everyone in the car reads it as they read fuel. The client
-- performs the transition (a client native) but doesn't decide it: it asks, and the server checks
-- the ignition rule before the stat moves.

SecureEvent('whip_core:server:setVehicleEngine', {
    -- With a burst: on-off-on inside a second is honest driving (start it, pull the key), and the
    -- client only reports a change.
    rateLimit = 250,
    burst     = 3,
    params = {
        { 'vehicleId', 'id' },
        { 'on', 'bool' },
    },
}, function(source, _, vehicleId, on)
    local def = Vehicles.getDef(vehicleId)
    if not def then return end

    -- Must actually be driving it (seat -1): not a passenger, not someone across the map.
    if not Vehicles.isPlayerDriving(source, vehicleId) then return end

    -- Starting requires a key in the ignition; stopping never does — you can always switch a
    -- running engine off. (A bicycle needs no key: Vehicles.ignitionReady.)
    if on and not Vehicles.ignitionReady(vehicleId) then
        RecordEventRejection('whip_core:server:setVehicleEngine', source, 'No key in ignition')
        return
    end
    -- Nor while a resource holds it off (below): the driver's game refuses first, so this is a backstop
    if on and VehicleStats.engineHeld(vehicleId) then
        RecordEventRejection('whip_core:server:setVehicleEngine', source, 'engine held off')
        return
    end

    VehicleStats.set(vehicleId, 'engine', on and 1 or 0, 'ignition')
end)

-- (A vehicle that leaves the world is not running when it comes back: the 'despawned' hook in the
-- Lifecycle section above switches the engine stat off.)

-- ============================================
-- Holding an engine off — for every resource
-- ============================================
--
-- Any resource can keep a vehicle's engine from running, with a reason the driver is shown: out of fuel, a flat
-- battery, an immobiliser. While any hold is on it the engine will not start, however the driver asks (their game
-- refuses, and the server above), and one running stops — still able to roll, as a car with no fuel is. A hold is its
-- resource's own, named by it: off when that resource releases it, or stops.
--
-- THE REASON RIDES ON THE CAR (its state bag VEHICLE_ENGINE_HOLD_KEY): whoever drives it next, on any game, must
-- know at once, before their game starts it — a server answer comes a ping later, with the engine already turning.
-- One string, the reason to show (any hold's), nil when there is none. Put on again whenever the car comes back
-- into the world (spawned, registered), and these holds are its truth (the Sentinel). The key is stripped with the
-- car's others (vehicles.lua's WHIP_ENTITY_KEYS), and a car's holds go when its id does (released, deleted).

local ENGINE_HOLD_KEY = VEHICLE_ENGINE_HOLD_KEY
local engineHolds = {}   -- [vehicleId] = { ['<resource>:<key>'] = reason }

--- Is anything holding this vehicle's engine off? Its reason, or nil.
---@return string|nil
function VehicleStats.engineHeld(vehicleId)
    local holds = engineHolds[vehicleId]
    if not holds then return nil end
    for _, reason in pairs(holds) do return reason end
    return nil
end

-- The bag is the car's owner game's to write as well (sv_stateBagStrictMode is off on purpose): one that wrote a
-- reason of its own would stop every driver's engine for good. The holds here are its truth.
Sentinel.watch({
    key = ENGINE_HOLD_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        local vehicleId = Vehicles.getTrackedVehicleIdForEntity(entity)
        return vehicleId and VehicleStats.engineHeld(vehicleId) or nil
    end,
})

--- The reason on the car's state bag, as the holds are now.
local function showEngineHold(vehicleId)
    local ent = Vehicles.getEntity(vehicleId)
    if ent and ent ~= 0 and DoesEntityExist(ent) then
        Sentinel.setEntityKey(ent, ENGINE_HOLD_KEY, VehicleStats.engineHeld(vehicleId))
    end
end

-- The holds are a registry (shared/registry.lua): each is its resource's, keyed '<resource>:<vehicleId>:<key>', and a
-- resource that stops lets go of all of its own (the sweep). engineHolds is the index the engine reads, kept by
-- onAdd / onRemove.
local holdReg = Registry.new('engineHolds', {
    label  = 'engine hold',
    scoped = true,
    onAdd = function(regKey, value, _, old)
        if old and old.vehicleId ~= value.vehicleId and engineHolds[old.vehicleId] then
            engineHolds[old.vehicleId][regKey] = nil
        end
        engineHolds[value.vehicleId] = engineHolds[value.vehicleId] or {}
        engineHolds[value.vehicleId][regKey] = value.reason
        showEngineHold(value.vehicleId)
    end,
    onRemove = function(regKey, value)
        local holds = engineHolds[value.vehicleId]
        if not holds then return end
        holds[regKey] = nil
        if next(holds) == nil then engineHolds[value.vehicleId] = nil end
        showEngineHold(value.vehicleId)
    end,
})

--- Every hold on a car let go, whoever's (its id gone for good).
local function dropHolds(vehicleId)
    local mine = {}
    for regKey, value in pairs(holdReg.entries) do
        if value.vehicleId == vehicleId then mine[#mine + 1] = { owner = holdReg:ownerOf(regKey), id = value.id } end
    end
    for _, h in ipairs(mine) do holdReg:remove(h.owner, h.id) end
    engineHolds[vehicleId] = nil
end

Vehicles.onLife('spawned', function(data) if engineHolds[data.vehicleId] then showEngineHold(data.vehicleId) end end)
-- Taken on (maybe an entity whip held before, under an id now gone): written either way, so no reason from then
-- stays on it
Vehicles.onLife('registered', function(data) showEngineHold(data.vehicleId) end)
-- Its id gone for good (handed back to GTA, or deleted): its holds with it
Vehicles.onLife('released', function(data) if data then dropHolds(data.vehicleId) end end)
Vehicles.onLife('deleted', function(data) if data then dropHolds(data.vehicleId) end end)

--- Hold `vehicleId`'s engine off, saying `reason` to its driver. `key` names the hold (the caller's own: a resource
--- may hold one car for two reasons); the same key again replaces its reason. A running engine stops.
---@return boolean ok, string|nil why
exports('HoldVehicleEngine', function(vehicleId, key, reason)
    local owner = Registry.caller()
    vehicleId = tonumber(vehicleId)
    if not vehicleId or not Vehicles.getDef(vehicleId) then return false, 'no such vehicle' end
    local id = ('%d:%s'):format(vehicleId, tostring(key or 'hold'))
    local ok, why = holdReg:add(owner, id, {
        id = id, vehicleId = vehicleId,
        reason = (type(reason) == 'string' and reason ~= '') and reason:sub(1, 80) or 'The engine will not start',
    })
    if not ok then return false, why --[[@as string]] end
    if (VehicleStats.get(vehicleId, 'engine') or 0) > 0 then VehicleStats.set(vehicleId, 'engine', 0, 'held') end
    return true
end)

--- Let go of the caller's hold `key` on `vehicleId` (with no key: all of the caller's on it). true when one went, or
--- false and why.
---@return boolean released, string|nil why
exports('ReleaseVehicleEngine', function(vehicleId, key)
    local owner = Registry.caller()
    vehicleId = tonumber(vehicleId)
    if not vehicleId then return false, 'vehicleId is a number' end
    if key ~= nil then
        if (holdReg:remove(owner, ('%d:%s'):format(vehicleId, tostring(key)))) == true then return true end
        return false, ('you hold no engine hold %q on that car'):format(tostring(key))
    end
    local went = false
    for _, regKey in ipairs(holdReg:keysOf(owner)) do
        local value = holdReg:get(regKey)
        if value and value.vehicleId == vehicleId and holdReg:remove(owner, value.id) then went = true end
    end
    if not went then return false, 'you hold no engine hold on that car' end
    return true
end)

--- Is `vehicleId`'s engine held off? The reason, or nil.
exports('GetVehicleEngineHold', function(vehicleId)
    return VehicleStats.engineHeld(tonumber(vehicleId))
end)

-- ============================================
-- Debug — who is watching which vehicle
-- ============================================
--
-- Pushed on change, not polled, and only what the client can't see: the values are on the
-- statebag, but WHY a number moved (`changeSource`: 'consume', 'decay', 'refuel:pump') exists
-- only here. A table lookup per change, nothing when nobody is watching.

--- [source] = vehicleId the overlay is currently showing, or nil.
VehicleStats._debugWatch = {}

--- Follow one vehicle's stat changes. 0 stops.
---
--- The client says which vehicle (it knows which car the player is in). Naming a far-away car
--- reveals nothing beyond what is already replicated.
-- The ACE is for watching only: stopping (0) is never refused (dev tools taken back must stop it).
SecureEvent('whip_core:server:vehStatDebugWatch', {
    rateLimit = 250,
    whileDead = true,
    requirePlayer = false,
    params    = { { 'vehicleId', 'id', 0 } },   -- 0 = stop watching
}, function(source, _, vehicleId)
    if vehicleId > 0 and not DevTools.isAllowed(source) then return false, 'ACE denied: whip.devtools' end
    VehicleStats._debugWatch[source] = (vehicleId > 0) and vehicleId or nil
end)

--- Pass one announced change to the admins watching that vehicle's stats. Called by the announce
--- itself, not a handler on the public event.
---@param data table  { vehicleId, changes, order }
function VehicleStats.tellDebugWatchers(data)
    -- Nobody watching (the common case): one `next`.
    if next(VehicleStats._debugWatch) == nil then return end
    if not data or not data.vehicleId then return end

    -- Holders of the ACE only (see stats.lua's sender).
    DevTools.eachViewer(VehicleStats._debugWatch, function(src)
        if VehicleStats._debugWatch[src] == data.vehicleId then
            TriggerClientEvent('whip_core:client:vehStatChange', src, data)
        end
    end)
end

AddEventHandler('playerDropped', function()
    VehicleStats._debugWatch[source] = nil
end)

-- ============================================
-- Cleanup
-- ============================================

-- A satellite that registered stats has stopped: the registry's sweep drops them (_vehicleStats,
-- at the top of the Registration section).

-- ============================================
-- Exports
-- ============================================

exports('RegisterVehicleStat', function(name, config)
    local owner = Registry.caller()   -- first, before anything can yield
    return VehicleStats.register(name, config, owner)
end)

--- The refusal for writing a stat nobody registered, or nil when the name is known.
---
--- At the export, not in VehicleStats.set: a satellite must register a stat before writing it (a
--- typo like 'feul' would otherwise land on disk). whip_core's own paths use set() directly, so a
--- stopped satellite's stat is carried forward on a car rather than lost.
---@param name any
---@return string|nil reason
local function unknownStatName(name)
    if type(name) == 'string' and VehicleStats._registry[name] then return nil end
    return ('unknown vehicle stat "%s" — RegisterVehicleStat it first'):format(tostring(name))
end

-- Every export below resolves its vehicleId first (Vehicles.idFromRef), as the vehicle exports do.

exports('GetVehicleStat', function(vehicleId, name)
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return nil end
    return VehicleStats.get(vehicleId, name)
end)

--- Every stat on a vehicle, defaults filled in. `{ stored = true }`: only what it has a stored value for, no defaults
--- (`nil` for a stat means "not fitted", for an installable, which a default would hide).
exports('GetVehicleStats', function(vehicleId, opts)
    local stored = type(opts) == 'table' and opts.stored == true
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return stored and {} or nil end
    if stored then return VehicleStats.getStored(vehicleId) end
    return VehicleStats.getAll(vehicleId)
end)

exports('SetVehicleStat', function(vehicleId, name, value, changeSource)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    local unknown = unknownStatName(name)
    if unknown then return false, unknown end
    return VehicleStats.set(vehicleId, name, value, changeSource)
end)

--- Write several stats to one vehicle in a single replication.
---
---     exports.whip_core:SetVehicleStats(vehicleId, {
---         nitro = 100, part1 = 100, part2 = 100,
---     }, 'whip_autos:nitrous')
---
--- Worth reaching for whenever more than two stats are set together — fitting a kit,
--- applying a tune, resetting a car. One stat at a time needs nothing.
---
--- It takes the values, not a callback: a table crosses the resource boundary once.
---@param vehicleId number|WhipVehicleRef|nil
---@param values table  [statName] = value
---@param changeSource string|nil
---@return number|false written  how many actually took; FALSE when none did
---@return string|nil err  why, only with false
---
--- `false, reason` when nothing was written (0 is truthy in Lua); a count only when something landed.
exports('SetVehicleStats', function(vehicleId, values, changeSource)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if type(values) ~= 'table' then return false, 'values must be a table of [statName] = number' end

    -- Unregistered names are skipped (as non-numbers are) and named in the console; the rest lands.
    -- The reason is returned only when nothing landed (as SetVehicleData with a table).
    local known, unknown = {}, nil
    for name, value in pairs(values) do
        if unknownStatName(name) then
            unknown = unknown or {}
            unknown[#unknown + 1] = tostring(name)
        else
            known[name] = value
        end
    end

    local written = VehicleStats.setMany(vehicleId, known, changeSource)
    if unknown then
        local reason = ('unknown vehicle stat(s) %s — RegisterVehicleStat them first')
            :format(table.concat(unknown, ', '))
        print(('[whip_core:vehstats] SetVehicleStats from %s skipped %s'):format(
            tostring(GetInvokingResource()), reason))
        if written == 0 then return false, reason end
    end

    if written == 0 then
        if not Vehicles.getDef(vehicleId) then return false, 'Vehicle not found' end
        return false, 'nothing to write: no stat in the table had a number for a value'
    end
    return written
end)

exports('AddVehicleStat', function(vehicleId, name, delta, changeSource)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    local unknown = unknownStatName(name)
    if unknown then return false, unknown end
    return VehicleStats.add(vehicleId, name, delta, changeSource)
end)

--- Take a stat off ONE vehicle. See VehicleStats.clear for why this is not the same as setting it
--- to zero, and not the same as unregistering it.
exports('ClearVehicleStat', function(vehicleId, name)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    return VehicleStats.clear(vehicleId, name)
end)

--- Take a stat's values off EVERY vehicle, permanently.
---
--- For retiring a stat for good. Not what a restart does — see VehicleStats.unregister.
---
--- A stat a running resource has registered can only be purged by that resource. A stat with no
--- running owner (a retired one, the case this is for) can be purged by anyone.
---@return number|false touched
---@return string|nil reason
exports('PurgeVehicleStat', function(name)
    local caller = Registry.caller()   -- first, before anything can yield
    local owner = type(name) == 'string' and VehicleStats._owners[name] or nil
    if owner and owner ~= caller and Registry.alive(owner) then
        return false, ('vehicle stat "%s" belongs to %s'):format(name, owner)
    end
    return VehicleStats.purge(name)
end)

--- Be told when ONE stat changes, on any vehicle, without being woken for the rest.
---
--- The server half of OnVehicleStatChanged (the same name on both sides). Entered only when that
--- name moved, on any car, whoever registered the stat: another resource's stat is heard the same.
---
---     exports.whip_core:OnVehicleStatChanged('fuel', function(vehicleId, value, previous, cleared)
---         if value < 10 then ... end
---     end)
---
--- '*' (server only) hears every stat, once per stat that moved, with the stat's name second:
--- `function(vehicleId, name, value, previous, cleared, source)`. It is called the most of anything
--- here, so name the stats when you know them.
---
--- The callback's fourth argument differs by side: the server knows whether the stat was CLEARED,
--- the client which ENTITY it happened on.
---
--- Options, the same on both sides and on OnVehicleDataChanged:
---
---     exports.whip_core:OnVehicleStatChanged('fuel', function(change)
---         -- change.vehicleId, change.key, change.value, change.old, change.cleared, change.source
---     end, { table = true, now = true })
---
---   * `table = true` — the callback gets ONE table instead of positional arguments, with the
---     same field names on both sides (each side fills in what it knows: `cleared` and `source`
---     here, `entity` on the client).
---   * `now = true` — also called once straight away for every vehicle that already carries this
---     stat (`source = 'now'`), so there is no separate "read everything first" step.
---     `now = 'all'` (a named stat, server): every vehicle whip has, with the value it reads as, its
---     default included (one that only has the default does not carry the stat). Registering again
---     with it after the stat's default changed visits them all again.
---
--- The options can go third (as above) or fourth, after an `id`.
---@param name string
---@param callback fun(vehicleId: number, value: number, previous: number|nil, cleared: boolean, source: string|nil)
---@return boolean registered
---@param id any|nil  only when a caller genuinely wants two listeners on one stat
---@param opts table|nil  { table?: boolean, now?: boolean|'all' }
exports('OnVehicleStatChanged', function(name, callback, id, opts)
    -- `callback ~= nil`, not a type check: it arrived through this export as a callable.
    -- `false, why`, as OnStatChanged answers.
    if type(name) ~= 'string' or name == '' then return false, 'name is required (a vehicle stat name)' end
    if callback == nil then return false, 'callback is required' end
    if type(id) == 'table' and opts == nil then id, opts = nil, id end
    opts = type(opts) == 'table' and opts or {}

    -- Keyed by who registered it, so re-registering replaces: onReady fires on every resource
    -- start, and an appending list would run every listener N times. The same key as the client's,
    -- `<resource>:<id>` (id defaulting to the stat name). The owner lives with the callback.
    local resource = GetInvokingResource() or GetCurrentResourceName()
    local key = ('%s:%s'):format(resource, tostring(id or name))

    local list = VehicleStats._statListeners[name]
    if not list then
        list = {}
        VehicleStats._statListeners[name] = list
    end
    local reg = { fn = callback, owner = resource, asTable = opts.table == true }
    list[key] = reg

    -- `now`: every car that carries it, once, off the registration path so the caller gets its
    -- `true` back first. Read from the stored values — a car that only has the default does not
    -- CARRY the stat (see HasVehicleStat). For '*', every stat each car carries.
    if opts.now then
        local wildcard = name == '*'
        local function tell(vehicleId, statName, v)
            local ok, err
            if reg.asTable then
                ok, err = pcall(reg.fn, { vehicleId = vehicleId, key = statName, value = v,
                                          cleared = false, source = 'now' })
            elseif wildcard then
                ok, err = pcall(reg.fn, vehicleId, statName, v, nil, false, 'now')
            else
                ok, err = pcall(reg.fn, vehicleId, v, nil, false, 'now')
            end
            if not ok then
                print(('[whip_core:vehstats] "%s" listener errored on now: %s'):format(statName, tostring(err)))
            end
        end
        CreateThread(function()
            -- `now = 'all'` (one named stat): every car whip has, with the value it reads as, its default included (a
            -- listener that decides something from the value: a car with only the default must be decided too).
            if opts.now == 'all' and not wildcard then
                for vehicleId in pairs(Vehicles.getAll()) do
                    if list[key] ~= reg then break end
                    local v = VehicleStats.get(vehicleId, name)
                    if v ~= nil then tell(vehicleId, name, v) end
                end
                return
            end
            for vehicleId, def in pairs(Vehicles.getAll()) do
                local stats = type(def.vehStats) == 'table' and def.vehStats or nil
                if stats and list[key] == reg then
                    if wildcard then
                        for statName, raw in pairs(stats) do
                            local v = tonumber(raw)
                            if v ~= nil and list[key] == reg then tell(vehicleId, statName, v) end
                        end
                    else
                        local v = tonumber(stats[name])
                        if v ~= nil then tell(vehicleId, name, v) end
                    end
                end
            end
        end)
    end

    return true
end)

AddEventHandler('onResourceStop', function(res)
    for name, listeners in pairs(VehicleStats._statListeners) do
        for key, entry in pairs(listeners) do
            if entry.owner == res then listeners[key] = nil end
        end
        -- `next(...) == nil`, not `#`: a keyed map's `#` is always zero.
        if next(listeners) == nil then VehicleStats._statListeners[name] = nil end
    end
end)

--- Does this vehicle actually CARRY this stat?
---
--- The question GetVehicleStat can't answer (it resolves an absent stat to its default, so a turbo
--- idling at 1 reads as fitted on every car). The mirror of the client export of the same name.
--- Reads the cache directly, not through getStored.
---@param vehicleId number|WhipVehicleRef|nil
---@param name string
---@return boolean
exports('HasVehicleStat', function(vehicleId, name)
    if type(name) ~= 'string' then return false end

    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    local def = vehicleId and Vehicles.getDef(vehicleId)
    if not def or type(def.vehStats) ~= 'table' then return false end

    return def.vehStats[name] ~= nil
end)

-- ============================================
-- SENTINEL TRUTH — the stat keys this file writes
-- ============================================
--
-- Registered here, with the private state: getStored() is what replicate() sends, and liveBlock is
-- a file-local.
--
-- Cost: whipLive is written several times a second per driven live-stat car, and every write
-- echoes through the Sentinel's compare (a table walk of a few numbers). The profiler scope below
-- measures it; measure before optimising.

Sentinel.watch({
    key = VEHICLE_STATS_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        -- The scope takes in the entity -> vehicle lookup too (most of the cost).
        ProfilerEnterScope('whip:sentinelEcho')
        local vid = Vehicles.getTrackedVehicleIdForEntity(entity)
        local block = vid and VehicleStats.getStored(vid) or nil
        ProfilerExitScope()
        if not block then return nil end
        -- Empty -> nil, exactly as replicate() sends it: the handler reverts a mismatch AND strikes
        -- the entity's owner.
        if next(block) == nil then return nil end
        return block
    end,
})

Sentinel.watch({
    key = VEHICLE_LIVE_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        ProfilerEnterScope('whip:sentinelEcho')   -- the lookup included
        local vid = Vehicles.getTrackedVehicleIdForEntity(entity)
        local block = vid and liveBlock(vid) or nil
        ProfilerExitScope()
        return block
    end,
})
