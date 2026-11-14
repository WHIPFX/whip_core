-- ============================================
-- VehicleData — per-vehicle data that is NOT a stat
-- ============================================
--
-- A vehicle stat is a NUMBER with a meaning: a range, a default, usually a gauge, often a drain.
-- This is for everything else a satellite wants to keep on a car: which distances a kit rolled on
-- install, a tuning profile's name, who fitted something and when.
--
-- A key/value store attached to a vehicle. Values are OPAQUE to whip: anything json-encodable,
-- never clamped, never decayed, never drawn, never consumed. It replicates to every client with the
-- car in scope and persists in the vehicle's own row.
--
-- Shaped like VehicleStats (get/set/clear/getAll, same argument order, the same stored-only
-- replication rule), so a developer who has used one already knows this.
--
-- Not to be confused with `vehicle_meta`, a different table for per-MODEL storage defaults (how
-- many trunk slots a Bison has). This is per VEHICLE.

VehicleData = {}

--- The targeted listeners' dispatcher, defined with the subscriptions at the bottom of this file.
local dispatchDataChange

--- Announce a data change: the OnVehicleDataChanged listeners FIRST, from here, then the public event.
---
--- From the write, not from the event, as OnVehicleStatChanged is fed: `whip_core:vehicle:dataChanged`
--- is a local event any server resource can fire. Every writer comes through here.
---@param data table  { vehicleId, key?, value?, old?, cleared?, resource? }
local function announceDataChange(data)
    if dispatchDataChange then dispatchDataChange(data) end
    WhipEmit('whip_core:vehicle:dataChanged', data)
end

--- How many keys one vehicle may carry, and how long a key may be.
---
--- Bounded because this is reachable by any satellite and every value here is replicated to
--- every client in scope. A store with no ceiling becomes a place to put things that should
--- have been a database table.
local MAX_KEYS    = 32
local MAX_KEY_LEN = 40

--- The whole block's ceiling, measured SERIALIZED, because serialized is what both costs:
--- the block rides the whipVehData statebag (re-sent to every client in scope on change, and
--- on every scope entry) and is written whole to the vehicle row. 8KB is roomy for what this store is
--- for (a kit's roll distances are ~100 bytes) and well under the 128KB statebag serialization
--- buffer. Anything bigger belongs in a database table, not on an entity.
local MAX_BLOCK_BYTES = 8192

--- Keys reach SQL as a JSON path, so they must not be able to carry one.
---@param key any
---@return boolean
local function validKey(key)
    return type(key) == 'string'
        and #key > 0 and #key <= MAX_KEY_LEN
        and key:match('^[%w_]+$') ~= nil
end

-- ============================================
-- Ownership
-- ============================================
--
-- A key belongs to the resource that first wrote it:
--   * another resource can READ any key, but writing or clearing one it does not own is refused;
--   * the key budget (MAX_KEYS) is counted per resource;
--   * ClearAllVehicleData takes away only the caller's own keys.
-- A key with no owner recorded is claimed by the first resource to write it.

--- Where the owners are SAVED: inside the same JSON the row holds, under a name no real key can
--- have ('@' fails validKey), so no resource can write it or collide with it. It is lifted out of
--- the block on load (blockOf) and put back only when writing the row (persist), so it never
--- replicates to clients and never appears in getAll.
local OWNERS_FIELD = '@owners'

--- The data block for a vehicle, created on demand, and its owners map.
---@param vehicleId number
---@return table|nil block
---@return table|nil owners  [key] = resource name
local function blockOf(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def then return nil end
    if type(def.vehData) ~= 'table' then def.vehData = {} end

    -- A block read from the row still carries its owners note. Lift it out on first touch.
    local saved = def.vehData[OWNERS_FIELD]
    if saved ~= nil then
        def.vehData[OWNERS_FIELD] = nil
        if type(saved) == 'table' then def.vehDataOwners = saved end
    end
    if type(def.vehDataOwners) ~= 'table' then def.vehDataOwners = {} end

    return def.vehData, def.vehDataOwners
end

--- How many keys on this vehicle one resource owns.
---@param owners table
---@param resource string
---@return number
local function ownedBy(owners, resource)
    local n = 0
    for _, who in pairs(owners) do
        if who == resource then n = n + 1 end
    end
    return n
end

--- The refusal for writing or clearing another resource's key, or nil when the caller may.
---@return string|nil reason
local function foreignKey(vehicleId, owners, key, resource)
    local holder = owners[key]
    if holder and holder ~= resource then
        return ('key "%s" on vehicle %s belongs to %s'):format(key, tostring(vehicleId), holder)
    end
    return nil
end

-- ============================================
-- Reading
-- ============================================

--- One value, or nil when this vehicle does not carry it.
---
--- There is no "registered default" here, unlike stats — nothing declares what data a
--- vehicle ought to have, so absent means absent and the caller decides what that means.
---@param vehicleId number
---@param key string
---@return any
function VehicleData.get(vehicleId, key)
    local block = blockOf(vehicleId)
    if not block or not validKey(key) then return nil end
    return block[key]
end

--- Everything this vehicle carries, as a plain copy.
---
--- A COPY, never the live table: handing that out would let a caller mutate what
--- everything else reads from, and the mutation would neither replicate nor persist.
---@param vehicleId number
---@return table
function VehicleData.getAll(vehicleId)
    local block = blockOf(vehicleId)
    if not block then return {} end

    local out = {}
    for k, v in pairs(block) do out[k] = v end
    return out
end

-- ============================================
-- Replication and persistence
-- ============================================

--- Put the block on the entity, where every client in range can read it.
---
--- Stored values only — the same rule the stat block follows. There is nothing to fill in
--- here anyway: absence is the whole meaning.
---@param vehicleId number
function VehicleData.replicate(vehicleId)
    local entity = Vehicles.getEntity(vehicleId)
    if not entity then return end

    -- Empty replicates as ABSENT, not as an empty table: the Sentinel truth for this key maps empty to
    -- nil, and a `[]` bag on the entity would read as tampering (three of those is a kick). An absent
    -- key also replicates nothing at all. The rule liveBlock in server/vehicle_stats.lua follows.
    local all = VehicleData.getAll(vehicleId)
    local block = next(all) ~= nil and all or nil

    Sentinel.setEntityKey(entity, VEHICLE_DATA_KEY, block)   -- whip's own write
end

-- The car's data block is a save unit, `vehdata:<vehicleId>`, mode 'now': written before the change
-- returns (data changes a handful of times in a car's life), through the Stores engine, so it lands
-- in ONE transaction with whatever the same player action did (the FMC kit leaving the pocket). The
-- block written is the one AS IT IS WHEN IT GOES, rewritten whole, so two keys cannot disagree about
-- which write came last.

--- The block's UPDATE, as it is now. A block that cannot be written (it cannot be encoded, or a row
--- hydrated before the size ceiling existed is over it) writes nothing rather than failing, so the
--- items its action saved are never held back by it; the mutators refuse those values up front.
---@param vehicleId number
---@return table[] queries
local function blockQueries(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def or def.session then return {} end

    -- json.encode RAISES on a value it cannot represent — a function, a cycle, a table with mixed keys.
    local built, encoded = pcall(json.encode, def.vehData or {})
    if not built then
        print(('[whip_core:vehdata] refusing to persist vehicle %s: %s')
            :format(tostring(vehicleId), tostring(encoded)))
        return {}
    end

    -- Belt-and-braces for the one path that skips the mutators: a block hydrated from a row
    -- that grew before the ceiling existed (vehicles.lua decodes vehData with only a type
    -- check). It still replicates as-is — there is no honest way to shrink someone's data —
    -- but it must not keep growing through the write path.
    if #encoded > MAX_BLOCK_BYTES then
        print(('[whip_core:vehdata] refusing to persist vehicle %s: block is %d bytes serialized, ceiling is %d')
            :format(tostring(vehicleId), #encoded, MAX_BLOCK_BYTES))
        return {}
    end

    -- An empty block is stored as NULL, not as "[]" (json.encode({}) is a JSON array): the same rule
    -- as replicate, absence is the meaning.
    local value = encoded ---@type string|nil
    if value == '[]' or value == '{}' then value = nil end

    -- The owners ride along in the same column (see OWNERS_FIELD), so who owns which key survives a
    -- restart without a schema change. Measured apart from the block above on purpose: the ceiling
    -- is about what replicates to clients, and the owners note never does.
    if value ~= nil and type(def.vehDataOwners) == 'table' and next(def.vehDataOwners) ~= nil then
        local toSave = {}
        for k, v in pairs(def.vehData or {}) do toSave[k] = v end
        toSave[OWNERS_FIELD] = def.vehDataOwners
        local builtAll, encodedAll = pcall(json.encode, toSave)
        if not builtAll then
            print(('[whip_core:vehdata] refusing to persist vehicle %s: %s')
                :format(tostring(vehicleId), tostring(encodedAll)))
            return {}
        end
        value = encodedAll
    end

    return { { query = 'UPDATE `vehicles` SET `vehData` = ? WHERE `vehicleId` = ?', values = { value, vehicleId } } }
end

Stores.defineUnit('vehdata', {
    mode      = 'now',
    persist   = blockQueries,
    faultMode = 'vehicle_data',   -- the name whip_test's fault tests arm
    label   = function(vehicleId) return ('data of vehicle #%s'):format(tostring(vehicleId)) end,
})

--- Write the block now (with whatever its action saved). A session vehicle — a street car whip took on —
--- has no row, and that is not a failure. False when it did not land: the mutators undo their change,
--- and the engine still owes the (undone) block, so the row ends up matching memory.
---@param vehicleId number
---@return boolean ok
local function persist(vehicleId)
    local def = Vehicles.getDef(vehicleId)
    if not def then return false end
    if def.session then return true end
    local ok, err = Stores.save(Stores.unit('vehdata', vehicleId))
    if not ok then
        print(('[whip_core:vehdata] write failed for vehicle %s: %s'):format(tostring(vehicleId), tostring(err)))
    end
    return ok
end

-- ============================================
-- Writing
-- ============================================

--- Attach one value to a vehicle. Passing nil removes it.
---@param vehicleId number
---@param key string
---@param value any  json-encodable, or nil to clear
---@param owner string|nil  the resource writing; the export thunk passes the caller. nil means
---                         whip_core itself.
---@return boolean ok
---@return string|nil err
function VehicleData.set(vehicleId, key, value, owner)
    local block, owners = blockOf(vehicleId)
    if not block then return false, 'no such vehicle' end
    ---@cast owners -nil   -- blockOf answers both or neither
    if not validKey(key) then
        return false, ('key must be 1-%d characters of [A-Za-z0-9_]'):format(MAX_KEY_LEN)
    end
    owner = owner or GetCurrentResourceName()

    -- Somebody else's key: read it all you like, but you may not change or remove it.
    local refused = foreignKey(vehicleId, owners, key, owner)
    if refused then return false, refused end

    -- The budget is PER RESOURCE: one busy satellite cannot use up the room another needs.
    if value ~= nil and owners[key] == nil and ownedBy(owners, owner) >= MAX_KEYS then
        return false, ('%s already has %d data keys on vehicle %s')
            :format(owner, MAX_KEYS, tostring(vehicleId))
    end

    -- Apply, measure, and only then keep: the ceiling is on the serialized whole (see
    -- MAX_BLOCK_BYTES), so it can only be measured with the value in place — and a value
    -- that busts it must leave no trace, or the refusal would lie. This also catches an
    -- unencodable value at the caller, with a reason, instead of five functions later as a
    -- console line the caller never sees.
    local prev, prevOwner = block[key], owners[key]
    block[key] = value

    local built, encoded = pcall(json.encode, block)
    if not built then
        block[key] = prev
        return false, ('value for "%s" is not json-encodable: %s'):format(key, tostring(encoded))
    end
    if #encoded > MAX_BLOCK_BYTES then
        block[key] = prev
        return false, ('vehicle %s data block would be %d bytes serialized — the ceiling is %d (refused for %s)')
            :format(tostring(vehicleId), #encoded, MAX_BLOCK_BYTES, owner)
    end

    -- Writing a key makes it yours (a key with no owner yet is claimed here); clearing it lets it go.
    if value ~= nil then owners[key] = owner else owners[key] = nil end

    VehicleData.replicate(vehicleId)

    -- Checked, and undone on failure the way Vehicles.persist undoes a failed row write.
    if not persist(vehicleId) then
        -- Not if another write changed this key while ours was in flight: that value is theirs.
        if block[key] == value then
            block[key] = prev
            owners[key] = prevOwner
        end
        VehicleData.replicate(vehicleId)
        return false, ('vehicle %s data could not be saved'):format(tostring(vehicleId))
    end

    -- Announced the way stat changes are, so a satellite can react to another's data
    -- without polling for it. `resource` says who made the change.
    announceDataChange({
        vehicleId = vehicleId,
        key       = key,
        value     = value,
        old       = prev,
        cleared   = value == nil,
        resource  = owner,
    })

    return true
end

--- Put `values` ([key] = value) into the block and take the `clear` keys out, IN MEMORY ONLY, checked
--- as one batch. Nothing is written or replicated: the caller writes (setMany, or SetVehicleAppearance's
--- `data`, which rides the look's write) and then calls change.undo() or change.announce().
---@param vehicleId number
---@param values table  [key] = value
---@param clear table  list of keys to remove
---@param owner string
---@return table|nil change  { count, store, undo = fn, announce = fn }; count 0 when nothing changed
---@return string|nil err  why the whole batch was refused
function VehicleData.stage(vehicleId, values, clear, owner)
    local block, owners = blockOf(vehicleId)
    if not block or type(values) ~= 'table' then return nil, 'no such vehicle' end
    ---@cast owners -nil   -- blockOf answers both or neither

    -- One foreign key refuses the WHOLE batch, named, before anything is touched. Writing the
    -- rest and quietly skipping it would leave the caller believing a key it does not own is set.
    for key in pairs(values) do
        if validKey(key) then
            local refused = foreignKey(vehicleId, owners, key, owner)
            if refused then return nil, refused end
        end
    end
    for _, key in ipairs(clear) do
        if not validKey(key) then
            return nil, ('key must be 1-%d characters of [A-Za-z0-9_]'):format(MAX_KEY_LEN)
        end
        if values[key] ~= nil then return nil, ('key "%s" is both set and cleared'):format(key) end
        local refused = foreignKey(vehicleId, owners, key, owner)
        if refused then return nil, refused end
    end

    -- ABSENT is a sentinel for "this key did not exist before the batch". A fresh table,
    -- because no stored value can ever be raw-equal to it — `true` or a string would collide
    -- with values a satellite might legitimately store.
    local ABSENT = {}
    local written, prevOwners, skipped = {}, {}, 0

    -- Removals first, so a key given up makes room under the ceiling below.
    for _, key in ipairs(clear) do
        if block[key] ~= nil and written[key] == nil then
            written[key] = block[key]
            prevOwners[key] = owners[key] or ABSENT
            block[key] = nil
            owners[key] = nil
        end
    end

    -- Trim at the key ceiling rather than refuse the batch: keys that fit are written, the overflow
    -- is SKIPPED and logged. The ceiling is the caller's own budget, the same as in set().
    local n = ownedBy(owners, owner)

    for key, value in pairs(values) do
        if validKey(key) then
            if owners[key] == nil and n >= MAX_KEYS then
                skipped = skipped + 1
            else
                if owners[key] == nil then n = n + 1 end
                written[key] = block[key] == nil and ABSENT or block[key]
                prevOwners[key] = owners[key] or ABSENT
                block[key] = value
                owners[key] = owner
            end
        end
    end
    if skipped > 0 then
        print(('[whip_core:vehdata] vehicle %s: %d key(s) skipped at the %d-key ceiling (from %s)')
            :format(tostring(vehicleId), skipped, MAX_KEYS, owner))
    end
    local count = 0
    for _ in pairs(written) do count = count + 1 end

    -- store: the unit that writes the block, for a caller putting it in its own transaction.
    local change = { count = count, store = Stores.unit('vehdata', vehicleId) }

    -- Spelled out, not `prev ~= ABSENT and prev or nil`: that form turns a stored `false` into nil.
    function change.undo()
        for key, prev in pairs(written) do
            if prev == ABSENT then block[key] = nil else block[key] = prev end
            local prevOwner = prevOwners[key]
            if prevOwner == ABSENT then owners[key] = nil else owners[key] = prevOwner end
        end
    end

    function change.announce()
        for key, prev in pairs(written) do
            local old = prev                    -- not `prev ~= ABSENT and prev or nil`: that loses a stored false
            if old == ABSENT then old = nil end
            announceDataChange({
                vehicleId = vehicleId, key = key, value = block[key], old = old,
                cleared = block[key] == nil, resource = owner,
            })
        end
    end

    if count == 0 then return change end

    -- The same serialized ceiling as set(), batch edition: bust it and the WHOLE batch is
    -- rolled back, because "some of your keys landed" is a worse answer than "none did".
    local built, encoded = pcall(json.encode, block)
    if not built or #encoded > MAX_BLOCK_BYTES then
        change.undo()
        local reason = not built
            and ('batch is not json-encodable: %s'):format(tostring(encoded))
            or  ('vehicle %s data block would be %d bytes serialized — the ceiling is %d (refused for %s)')
                :format(tostring(vehicleId), #encoded, MAX_BLOCK_BYTES, owner)
        return nil, reason
    end

    return change
end

--- Attach several values in one replication and one write.
---
--- The same reasoning as VehicleStats.setMany, and the same shape: a table of values rather
--- than a callback, so nothing has to cross the resource boundary except data.
---@param vehicleId number
---@param values table  [key] = value; a nil value cannot be expressed in a Lua table, so use
---                     VehicleData.clear for removal
---@param owner string|nil  the resource writing; the export thunk passes the caller. nil means
---                         whip_core itself.
---@return number written
---@return string|nil err  set when the whole batch was refused (written is then 0)
function VehicleData.setMany(vehicleId, values, owner)
    local change, err = VehicleData.stage(vehicleId, values, {}, owner or GetCurrentResourceName())
    if not change then return 0, err end
    if change.count == 0 then return 0 end

    VehicleData.replicate(vehicleId)

    -- Checked, and the whole batch undone on failure — see set().
    if not persist(vehicleId) then
        change.undo()
        VehicleData.replicate(vehicleId)
        return 0, ('vehicle %s data could not be saved'):format(tostring(vehicleId))
    end

    change.announce()
    return change.count
end

--- Take one value off a vehicle.
---@param vehicleId number
---@param key string
---@param owner string|nil  the resource clearing; nil means whip_core itself
---@return boolean ok
---@return string|nil err
function VehicleData.clear(vehicleId, key, owner)
    local block = blockOf(vehicleId)
    if not block then return false, 'no such vehicle' end
    if not validKey(key) then
        return false, ('key must be 1-%d characters of [A-Za-z0-9_]'):format(MAX_KEY_LEN)
    end
    if block[key] == nil then return true end       -- already absent; nothing to announce
    return VehicleData.set(vehicleId, key, nil, owner)
end

--- Take everything off a vehicle. For an uninstall that removes a whole kit.
---
--- With an owner (every export call), only THAT resource's keys go: uninstalling one kit must
--- not wipe another satellite's data off the same car. With no owner — whip_core itself — the
--- whole block goes.
---@param vehicleId number
---@param owner string|nil
---@return boolean ok
---@return string|nil err
function VehicleData.clearAll(vehicleId, owner)
    local def = Vehicles.getDef(vehicleId)
    if not def then return false, 'no such vehicle' end
    local block, owners = blockOf(vehicleId)
    ---@cast block -nil   -- the def is there (above), so blockOf answers both
    ---@cast owners -nil

    if owner then
        local removed = {}
        for key, who in pairs(owners) do
            if who == owner then removed[key] = block[key] end
        end
        if next(removed) == nil then return true end    -- nothing of yours here; nothing to announce

        for key in pairs(removed) do
            block[key] = nil
            owners[key] = nil
        end
        VehicleData.replicate(vehicleId)

        -- Checked, and undone on failure — see set(). A key someone wrote meanwhile stays theirs.
        if not persist(vehicleId) then
            for key, prev in pairs(removed) do
                if block[key] == nil and owners[key] == nil then
                    block[key] = prev
                    owners[key] = owner
                end
            end
            VehicleData.replicate(vehicleId)
            return false, ('vehicle %s data could not be saved'):format(tostring(vehicleId))
        end

        -- One event per key, so a listener on someone else's key is not told it was cleared.
        for key, prev in pairs(removed) do
            announceDataChange({
                vehicleId = vehicleId, key = key, value = nil, old = prev, cleared = true, resource = owner,
            })
        end
        return true
    end

    local before, beforeOwners = def.vehData, def.vehDataOwners
    def.vehData = {}
    def.vehDataOwners = {}
    VehicleData.replicate(vehicleId)

    -- Checked, and undone on failure — see set(). Only while nothing has replaced the block since.
    if not persist(vehicleId) then
        if next(def.vehData) == nil then
            def.vehData = before
            def.vehDataOwners = beforeOwners
        end
        VehicleData.replicate(vehicleId)
        return false, ('vehicle %s data could not be saved'):format(tostring(vehicleId))
    end

    announceDataChange({
        vehicleId = vehicleId, key = nil, value = nil, cleared = true,
        resource = GetCurrentResourceName(),
    })
    return true
end

-- ============================================
-- Subscriptions
-- ============================================
--
-- The server half of OnVehicleDataChanged.
--
-- Driven by the writes, through one function (announceDataChange, top of file): every writer calls
-- it, it calls these listeners and then fires `whip_core:vehicle:dataChanged` for everyone else, so
-- the targeted path and the broadcast cannot disagree, and a fired copy of the event can't reach them.

-- [key] = { ['<resource>:<id>'] = { fn, owner, asTable } }. Keyed, so a satellite registering from
-- whip_core:onReady (which fires on every resource start) replaces its listener instead of stacking
-- another; the owner rides with the callback, the same shape as OnVehicleStatChanged.
local _dataListeners = {}

--- Call one listener, in the shape it registered for.
local function callDataListener(reg, key, change)
    local ok, err
    if reg.asTable then
        ok, err = pcall(reg.fn, {
            vehicleId = change.vehicleId, key = key, value = change.value, old = change.old,
            cleared = change.cleared == true, resource = change.resource,
        })
    else
        -- `old` is FOURTH, after `cleared`: listeners read `cleared` third.
        ok, err = pcall(reg.fn, change.vehicleId, change.value, change.cleared == true, change.old)
    end
    if not ok then
        print(('[whip_core:vehdata] a "%s" listener errored: %s'):format(key, tostring(err)))
    end
end

local function notifyDataListeners(key, change)
    local list = _dataListeners[key]
    if not list then return end
    for _, reg in pairs(list) do callDataListener(reg, key, change) end
end

dispatchDataChange = function(data)
    if type(data) ~= 'table' or not data.vehicleId then return end

    if data.key then
        notifyDataListeners(data.key, data)
        return
    end

    -- clearAll names no key, because everything went. Every listener is told about its own key
    -- rather than none of them being told at all — "it is gone" is the answer they are waiting for.
    for key in pairs(_dataListeners) do
        notifyDataListeners(key, { vehicleId = data.vehicleId, cleared = true, resource = data.resource })
    end
end

--- Be told when one piece of vehicle data changes, on any vehicle.
---
--- The targeted alternative to the `whip_core:vehicle:dataChanged` event, and the server half of
--- the client export of the same name. The event is a broadcast: it enters every resource with a
--- handler on every data change anywhere on the server. Subscribing by key is entered only when
--- that key moved.
---
---     exports.whip_core:OnVehicleDataChanged('kitDistances', function(vehicleId, value, cleared, old)
---         if cleared then ... end
---     end)
---
--- The positions differ by side: here it is (vehicleId, value, cleared, old); the client's is
--- (vehicleId, value, old, entity). A listener moved from one side to the other reads the wrong
--- thing with no error — `table = true` (below) has the same field names on both sides.
---
--- Keyed `<your resource>:<id>`, `id` defaulting to the data key: calling it again replaces.
---
--- Options, the same as OnVehicleStatChanged's, third or fourth:
---
---     exports.whip_core:OnVehicleDataChanged('kitDistances', function(change)
---         -- change.vehicleId, change.key, change.value, change.old, change.cleared, change.resource
---     end, { table = true, now = true })
---
---   * `table = true` — one table with the same field names as the client's, instead of positional
---     arguments that mean different things on each side.
---   * `now = true` — also called once straight away for every vehicle that already carries the key.
---@param key string
---@param callback fun(vehicleId: number, value: any, cleared: boolean, old: any)
---@param id string|nil
---@param opts table|nil  { table?: boolean, now?: boolean }
---@return boolean registered
exports('OnVehicleDataChanged', function(key, callback, id, opts)
    -- `callback ~= nil`, not `type(callback) == 'function'`. A funcref that has crossed an export
    -- is callable but does not report as a Lua 'function', so a type test refuses every real caller.
    -- `false, why`, as OnStatChanged answers.
    if type(key) ~= 'string' or key == '' then return false, 'key is required (a vehicle data key)' end
    if callback == nil then return false, 'callback is required' end
    if type(id) == 'table' and opts == nil then id, opts = nil, id end
    opts = type(opts) == 'table' and opts or {}

    local owner = GetInvokingResource() or GetCurrentResourceName()
    if not _dataListeners[key] then _dataListeners[key] = {} end
    local regKey = owner .. ':' .. tostring(id or key)
    local reg = { fn = callback, owner = owner, asTable = opts.table == true }
    _dataListeners[key][regKey] = reg

    -- `now`: every car carrying it, once, after the registration has returned.
    if opts.now then
        CreateThread(function()
            for vehicleId in pairs(Vehicles.getAll()) do
                local value = VehicleData.get(vehicleId, key)
                local list = _dataListeners[key]
                if value ~= nil and list and list[regKey] == reg then
                    callDataListener(reg, key, { vehicleId = vehicleId, value = value, cleared = false })
                end
            end
        end)
    end

    return true
end)

-- A subscription lives in THIS resource's tables, so it dies with the resource that registered it.
-- Without this a stopped satellite's callback stays in the list and is pcall'd forever.
AddEventHandler('onResourceStop', function(res)
    for key, list in pairs(_dataListeners) do
        for regKey, reg in pairs(list) do
            if reg.owner == res then list[regKey] = nil end
        end
        if next(list) == nil then _dataListeners[key] = nil end
    end
end)

-- ============================================
-- Lifecycle
-- ============================================

-- A vehicle entering the world gets its data put on it immediately, so a client that
-- streams it in never has to ask for something that is already known. Lifecycle hooks, not
-- event handlers (see Vehicles.announce).
Vehicles.onLife('spawned', function(data) VehicleData.replicate(data.vehicleId) end)
Vehicles.onLife('registered', function(data) VehicleData.replicate(data.vehicleId) end)
-- A deleted car's row is gone: a data write it still owed has nowhere to land.
Vehicles.onLife('deleted', function(data) Stores.forget('vehdata:' .. tostring(data.vehicleId)) end)

-- ============================================
-- Exports
-- ============================================

--- Attach a value to a vehicle. Anything json-encodable; nil removes it. A table in place of the key sets several
--- at once, in one replication and one database write.
---
---     exports.whip_core:SetVehicleData(vehicleId, 'kitDistances', { 250, 777, ... })
---     exports.whip_core:SetVehicleData(vehicleId, { kit = 'street', kitAt = os.time() })
---
--- For a NUMBER WITH A RANGE that the player should see, register a vehicle stat instead —
--- that is what gauges, drains and `clearAtMin` are for. This is for everything else.
---
--- Every export here cleans its vehicleId first, the rule the vehicle exports follow (the string
--- '12' finds vehicle 12).
exports('SetVehicleData', function(vehicleId, key, value)
    local caller = GetInvokingResource()   -- first, before anything can yield
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    if type(key) ~= 'table' then return VehicleData.set(vehicleId, key, value, caller) end
    -- Several: `false, reason` when nothing was written (0 is true in Lua); a count only when something landed.
    local written, err = VehicleData.setMany(vehicleId, key, caller)
    if not written or written == 0 then
        return false, err or 'nothing written: no valid key (1–40 of A-Z a-z 0-9 _), or the key ceiling is full'
    end
    return written
end)

--- One value, or nil when this vehicle does not carry it. With no key, everything it carries, as a copy.
exports('GetVehicleData', function(vehicleId, key)
    vehicleId = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if key == nil then
        if not vehicleId then return {} end
        return VehicleData.getAll(vehicleId)
    end
    if not vehicleId then return nil end
    return VehicleData.get(vehicleId, key)
end)

--- Remove one value. Only a key your resource wrote.
exports('ClearVehicleData', function(vehicleId, key)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    return VehicleData.clear(vehicleId, key, GetInvokingResource() or GetCurrentResourceName())
end)

--- Remove every key YOUR resource put on this vehicle. For uninstalling a whole kit in one go.
--- Other resources' keys on the same car are left alone.
exports('ClearAllVehicleData', function(vehicleId)
    local refErr
    vehicleId, refErr = Vehicles.idFromRef(vehicleId)   -- a vehicleId or a vehicle reference
    if not vehicleId then return false, refErr end
    return VehicleData.clearAll(vehicleId, GetInvokingResource() or GetCurrentResourceName())
end)

-- ============================================
-- Sentinel truth — the data key this file writes
-- ============================================
--
-- Same contract as the stat truths in vehicle_stats.lua: registered by the module that
-- owns the state, resolved without touching the bag being verified.

Sentinel.watch({
    key = VEHICLE_DATA_KEY, family = 'entity', owner = 'whip_core',
    truth = function(entity)
        local vid = Vehicles.getTrackedVehicleIdForEntity(entity)
        if not vid then return nil end
        local block = VehicleData.getAll(vid)
        -- Empty → nil for the boot sweep, same reasoning as the stat block: getAll answers
        -- {} for a car carrying no data while such a car's bag is simply absent.
        if next(block) == nil then return nil end
        return block
    end,
})
