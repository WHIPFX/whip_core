-- Stores: one model for every place an item can live (pockets, bags, stashes, boots, crafting panels).
-- A kind is declared once; an address ({kind, key, slot}) points at one slot of one instance.
-- Persistence is write-behind (dirty set + flush thread) or write-through, per kind.

Stores = {}

Stores._kinds = {}   -- [kindId] = kindDef

-- Transactions. oxmysql's transaction does not throw on rollback, so pcall(MySQL.transaction.await, q) gives:
--   (true, true) committed, (true, false) rolled back, (false, err) Lua error.
-- Mistaking a rollback for success under write-behind clears the dirty flag and loses the data.

--- How many transactions are with the database right now (a write-behind queue empties its list before awaiting).
Stores._txInFlight = 0

-- When each started, for the stall watchdog below: [token] = { at, mode }.
local _txStarted, _txToken = {}, 0

--- How long a write may be with the database before the watchdog says so.
local TX_STALL_MS = 30000

--- Run a transaction and report whether it committed.
---@param queries table[]  array of {query=string, values=table}
---@return boolean committed
---@return string|nil err
---@param faultMode string|nil  which injected fault applies; nil means 'transaction'
function Stores.runTransaction(queries, faultMode)
    if not queries or #queries == 0 then
        return false, 'no queries'
    end

    -- Fault injection point for whip_test; the write-behind thread uses its own mode so it can't consume a test's fault.
    faultMode = faultMode or 'transaction'
    if TestSeams and TestSeams.shouldFail(faultMode) then
        return false, 'injected fault: ' .. faultMode
    end

    Stores._txInFlight = Stores._txInFlight + 1
    _txToken = _txToken + 1
    local token = _txToken
    _txStarted[token] = { at = GetGameTimer(), mode = faultMode }
    local ok, result = pcall(MySQL.transaction.await, queries)
    _txStarted[token] = nil
    Stores._txInFlight = Stores._txInFlight - 1
    if not ok then
        return false, tostring(result)
    end
    if result == false then
        return false, 'transaction rolled back (see oxmysql:transaction-error)'
    end
    return true
end

-- Stall watchdog: a hung query blocks the write-behind thread. Past TX_STALL_MS it tells the console and
-- admins (whip.devtools) each minute, and says when it clears.
do
    local stalledSince, lastSaid = nil, 0
    Every('database stall watchdog', 5000, function()
        local now, oldest, mode = GetGameTimer(), nil, nil
        for _, t in pairs(_txStarted) do
            if not oldest or t.at < oldest then oldest, mode = t.at, t.mode end
        end

        if oldest and now - oldest > TX_STALL_MS then
            if not stalledSince or now - lastSaid >= 60000 then
                stalledSince = stalledSince or oldest
                lastSaid = now
                local secs = math.floor((now - oldest) / 1000)
                print(('^1[whip_core:stores] DATABASE WRITES HAVE STALLED — a %s commit has been waiting %ds. Saves are not landing; check the database and oxmysql.^0')
                    :format(tostring(mode), secs))
                for src in pairs(Players) do
                    if IsPlayerAceAllowed(src, 'whip.devtools') then
                        NotifyPlayer(src, ('Database writes have stalled for %ds, so saves are not landing. See the server console.'):format(secs), 'error')
                    end
                end
            end
        elseif stalledSince then
            print(('[whip_core:stores] database writes are moving again (stalled for %ds)')
                :format(math.floor((now - stalledSince) / 1000)))
            stalledSince = nil
        end
    end)
end

-- Kind registration
--
-- A kindDef provides:
--   resolve(key)                  -> handle|nil  turn an instance key into something to operate on
--   instanceId(key, handle)       -> string      stable identity of this store (see Stores.open)
--   unitKey(key, handle)          -> string      what persists together
--   slots(handle)                 -> number      capacity in slots
--   maxWeight(handle)             -> number      capacity in weight
--   get(handle, slot)             -> slotData|nil {item, amount, metadata}
--   set(handle, slot, item, amount, metadata) -> boolean
--   clear(handle, slot)
--   allows(handle, itemKey, metadata) -> boolean  optional item filter for the whole store
--   allowsAt(handle, slot, itemKey, metadata) -> boolean, string|nil  optional per-slot filter; absent means
--                                    every slot takes anything `allows` would
--   persist(handle)               -> queries[]|nil  nil means "cannot persist right now"
--   durability                    -> 'writeThrough' (default) | 'writeBehind'
--   label(key, handle)            -> string      for error messages and logs
--   beforeMove(handle, ctx)       -> false | 'handled' | any   optional veto/interception
--   afterMove(handle, ctx)                                     optional side effect, post-commit
--   afterWrite(handle, slots)                                  optional side effect of a direct write
--                                                              (Stores.giveAt / takeAt / setAt), which runs no move hooks
-- instanceId and unitKey take the resolved handle, so they can't drift when a player's session state changes.

--- Every store still queued for a write (dirty, or in a transfer group) opened with this kind definition.
--- Collected, so the caller may forget or rewrite them while walking. Queued stores hold their kind, so a
--- re-registered kind or a stopped owner must repoint or write them out.
---@param kindDef table
---@return table[] list  { { unit, store }, ... }
local function queuedOfKind(kindDef)
    local list, seen = {}, {}
    for unit, store in pairs(Stores._dirty or {}) do
        if store.kind == kindDef and not seen[unit] then seen[unit] = true; list[#list + 1] = { unit, store } end
    end
    for _, g in pairs(Stores._groups or {}) do
        for unit, store in pairs(g) do
            if type(store) == 'table' and store.kind == kindDef and not seen[unit] then
                seen[unit] = true; list[#list + 1] = { unit, store }
            end
        end
    end
    return list
end

-- whip_core's kinds use Stores.defineKind; a satellite's use RegisterStoreKind. `same = false`: a definition
-- is all functions (new references each time), so a re-registration always swaps it in.
local _storeKinds = Registry.new('StoreKind', {
    label = 'store kind',
    store = Stores._kinds,
    same  = false,
    onAdd = function(kindId, def, owner, old)
        if owner ~= GetCurrentResourceName() then StoreKindOwners[kindId] = owner end
        -- Re-registration: what is already queued writes through the new definition.
        if old and old ~= def then
            for _, q in ipairs(queuedOfKind(old)) do q[2].kind = def end
        end
    end,
    -- A stopped resource's kind is removed: its resolve() would point into a dead Lua state.
    onRemove = function(kindId, def, owner, why)
        StoreKindOwners[kindId] = nil
        if why == 'stopped' then
            print(('[whip_core:stores] dropped store kind "%s" — %s stopped'):format(kindId, owner))
            -- Queued writes go now, each with its whole group (a unit without its partners could duplicate or lose an item).
            local queued = def and queuedOfKind(def) or {}
            local lost = 0
            for _, q in ipairs(queued) do
                if not Stores.dispatchGroup(q[2]) then lost = lost + 1 end
            end
            for _, q in ipairs(queued) do Stores.forget(q[1]) end
            if lost > 0 then
                print(('[whip_core:stores] WARNING: %d unsaved write(s) of store kind "%s" were lost — %s stopped before they were written')
                    :format(lost, kindId, owner))
            end
        end
    end,
})

--- Validate a kind definition, and fill in its defaults. Raises on a malformed one.
---@param kindId string
---@param kindDef table
local function checkKindDef(kindId, kindDef)
    assert(type(kindId) == 'string', 'Stores.defineKind: kindId must be a string')
    assert(type(kindDef) == 'table', 'Stores.defineKind: kindDef must be a table')
    -- Present, not type 'function': an exported function is a callable whose Lua type is not 'function'.
    for _, required in ipairs({ 'resolve', 'instanceId', 'unitKey', 'slots', 'maxWeight', 'get', 'set', 'clear' }) do
        assert(kindDef[required] ~= nil,
            ('Stores.defineKind(%s): missing required function "%s"'):format(kindId, required))
    end
    if kindDef.durability == nil then
        kindDef.durability = 'writeThrough'
    end
    assert(kindDef.durability == 'writeThrough' or kindDef.durability == 'writeBehind',
        ('Stores.defineKind(%s): durability must be "writeThrough" or "writeBehind", got %s')
            :format(kindId, tostring(kindDef.durability)))

    kindDef.id = kindId

    -- Every kind's `allows` first asks the vetoes about stamped stacks (a Director test's metadata.director, a
    -- Systems Creator test's metadata.systest), so a test's items can't be stashed or given away. Every move asks
    -- `allows`; Inventory.addItem into pockets does not.
    local own = kindDef.allows
    kindDef.allows = function(h, itemKey, metadata)
        if type(metadata) == 'table' then
            local veto = Stores.placementVeto
            if veto ~= nil and metadata.director ~= nil then
                local okVeto, refused = pcall(veto, kindId, h, itemKey, metadata)
                if not okVeto or refused then return false end
            end
            for field, stampVeto in pairs(Stores.stampVetoes or {}) do
                if metadata[field] ~= nil then
                    local okVeto, refused = pcall(stampVeto, kindId, h, itemKey, metadata)
                    if not okVeto or refused then return false end
                end
            end
        end
        if own == nil then return true end
        return own(h, itemKey, metadata)
    end
end

--- Set by the Director: fn(kindId, handle, itemKey, metadata) -> true to refuse a run's stamped stack.
Stores.placementVeto = nil
--- [metadata field] = fn(kindId, handle, itemKey, metadata) -> true to refuse a stack carrying that
--- stamp (the Systems' `systest`). A veto that errors refuses, as the Director's does.
Stores.stampVetoes = {}

--- Define one of whip_core's own kinds. Raises on a malformed definition.
---@param kindId string
---@param kindDef table
function Stores.defineKind(kindId, kindDef)
    checkKindDef(kindId, kindDef)
    Stores._kinds[kindId] = kindDef
    _storeKinds:setOwner(kindId, GetCurrentResourceName())
end

---@param kindId string
---@return table|nil
function Stores.getKind(kindId)
    return Stores._kinds[kindId]
end

-- RegisterStoreKind: Stores.defineKind for satellites. It returns false plus a reason instead of asserting,
-- won't overwrite (core's names are reserved), removes the kind when its resource stops, and is server-only
-- until the definition supplies `authorize(src, addr)`.

--- Kinds registered by satellites: [kindId] = resourceName
StoreKindOwners = {}

--- Names a satellite may not claim: the defined kinds, `target` (admin inspect) and each PlayerContainers name.
--- Filled further down, next to CLIENT_KINDS.
Stores.ReservedKindNames = {}

--- Define a new kind of store from outside whip_core. Exported as RegisterStoreKind.
--- Required: resolve, instanceId, slots, maxWeight, get, set, clear (contract above, at the top).
--- Optional: unitKey (defaults to instanceId), allows, allowsAt, persist, durability, label, beforeMove, afterMove,
--- and authorize(src, addr) -> boolean: return true only when that player has this store open, to let clients
--- address the kind in a drag.
---
--- The handle must carry an id, not a live table: values crossing the export boundary are copied, so a handle
--- like `{ id = id, rows = myStorage[id] }` makes `set` write into a copy. Return `{ id = id }` and look storage
--- up by id in get/set/clear.
---
--- resolve/get/set/clear must not yield: the mover undoes a refused write with a plain `set` back, which is only
--- safe when nothing can run in between. `key` is { id, sub } as the client sent it, so resolve answers nil for
--- anything it doesn't know.
---@param kindId string
---@param kindDef table
---@return boolean ok
---@return string|nil err
local function defineStoreKind(kindId, kindDef)
    local resource = Registry.caller()   -- first, before anything can yield

    if type(kindId) ~= 'string' or kindId == '' then
        return false, 'kindId must be a non-empty string'
    end
    if type(kindDef) ~= 'table' then
        return false, 'kindDef must be a table'
    end

    if kindDef.unitKey == nil then kindDef.unitKey = kindDef.instanceId end
    if Stores.ReservedKindNames[kindId] then
        return false, ('"%s" is reserved by whip_core and cannot be redefined'):format(kindId)
    end
    local holder = _storeKinds:ownerOf(kindId)
    if holder and holder ~= resource and Registry.alive(holder) then
        return false, ('store kind "%s" belongs to %s'):format(kindId, holder)
    end

    -- Present, not type 'function': exported functions are callables.
    for _, required in ipairs({ 'resolve', 'instanceId', 'unitKey', 'slots',
                                'maxWeight', 'get', 'set', 'clear' }) do
        if kindDef[required] == nil then
            return false, ('missing required function "%s"'):format(required)
        end
    end

    -- A string, number or boolean is never callable.
    local authType = type(kindDef.authorize)
    if authType == 'string' or authType == 'number' or authType == 'boolean' then
        return false, 'authorize must be a function when provided'
    end
    if kindDef.durability ~= nil
       and kindDef.durability ~= 'writeThrough' and kindDef.durability ~= 'writeBehind' then
        return false, 'durability must be "writeThrough" or "writeBehind"'
    end

    -- A satellite's set/clear that errors becomes `false` (refused), so the movers undo the other end instead of
    -- leaving the item in both stores. Reads run before anything is written and stay unwrapped.
    local shielded = {}
    for k, v in pairs(kindDef) do shielded[k] = v end
    for _, name in ipairs({ 'set', 'clear' }) do
        local fn = kindDef[name]
        shielded[name] = function(...)
            local okCall, result = pcall(fn, ...)
            if not okCall then
                print(('[whip_core:stores] store kind "%s" %s() errored — treated as refused: %s')
                    :format(kindId, name, tostring(result)))
                return false
            end
            return result
        end
    end

    local ok, err = pcall(checkKindDef, kindId, shielded)
    if not ok then return false, tostring(err) end

    local isNew = Stores._kinds[kindId] == nil
    local added, why = _storeKinds:add(resource, kindId, shielded)
    if not added then return false, why --[[@as string]] end

    if isNew then
        print(('[whip_core:stores] %s defined store kind "%s"%s')
            :format(resource, kindId, kindDef.authorize and ' (client-addressable)' or ' (server-only)'))
    end
    return true
end

exports('RegisterStoreKind', defineStoreKind)

-- Store handles

--- Bind a kind + instance key into something the operations below can use.
--- Returns nil when the instance can't be resolved (e.g. contents failed to load): treat nil as "do not
--- proceed", never as "empty".
--- `id` is the stable string identity of this store; `unit` is what persists together (a player's containers
--- are separate stores but save as one character's row-set). Both come from the resolved handle, so they stay
--- stable after the player goes offline.
---@param kindId string
---@param key any
---@return table|nil store
---@return string|nil err
function Stores.open(kindId, key)
    local kind = Stores._kinds[kindId]
    if not kind then return nil, ('Unknown store kind "%s"'):format(tostring(kindId)) end

    local handle = kind.resolve(key)
    if handle == nil then return nil, ('Store %s is not available'):format(kindId) end

    local id = kind.instanceId(key, handle)
    return {
        kind   = kind,
        key    = key,
        handle = handle,
        id     = id,
        unit   = kind.unitKey(key, handle),
        label  = kind.label and kind.label(key, handle) or id,
    }
end

-- Save-only units: things that save but hold no items (a car's stats, a character's row) use the same dirty/flush
-- engine. Not a store kind (no slots), so nothing that moves items can address it.

--- unit kind id -> definition. Separate from Stores._kinds, which are addressable stores.
Stores._unitKinds = {}

--- Define a save-only unit kind. whip_core only. Raises on a malformed definition.
---   persist(key)  -> queries[], confirm?   required; what to write (nil = can't right now)
---   mode          -> 'later' (default: saved with the next flush) | 'now' (saved before the change returns)
---   every         -> ms, 'later' only: written once it has waited this long, unless saved sooner with a linked unit
---   unitKey(key)  -> string   optional; default '<kindId>:<key>'
---   label(key)    -> string   optional, for the console
---   what          -> string   optional; its line in the final save's console count (FinalSave)
---   faultMode     -> string   optional; the whip_test fault name its writes answer to when alone
---   invalidate(key)           optional; next persist writes it whole (see groupQueries)
---   writeOrder(key) -> number optional; units of this kind in one pass are written in this order
---@param kindId string
---@param def table
function Stores.defineUnit(kindId, def)
    assert(type(kindId) == 'string' and kindId ~= '', 'Stores.defineUnit: kindId must be a string')
    assert(type(def) == 'table' and def.persist ~= nil, ('Stores.defineUnit(%s): persist is required'):format(kindId))
    assert(not Stores._kinds[kindId], ('Stores.defineUnit(%s): already a store kind'):format(kindId))
    local mode = def.mode or 'later'
    assert(mode == 'later' or mode == 'now', ('Stores.defineUnit(%s): mode must be "later" or "now"'):format(kindId))
    assert(def.every == nil or (mode == 'later' and type(def.every) == 'number' and def.every > 0),
        ('Stores.defineUnit(%s): every must be a positive number of ms, on a "later" unit'):format(kindId))
    def.id = kindId
    def.mode = mode
    def.durability = mode == 'now' and 'writeThrough' or 'writeBehind'
    Stores._unitKinds[kindId] = def
    if def.what and FinalSave then
        FinalSave.add(11, def.what, function() end, function()
            local n = 0
            for _, store in pairs(Stores._dirty) do
                if store.kind == def then n = n + 1 end
            end
            return n
        end)
    end
end

--- Change how long a 'later' unit kind waits before it is written (its `every`, in ms); the next flush pass uses it.
---@param kindId string
---@param ms number
---@return boolean ok
---@return string|nil why
function Stores.setUnitEvery(kindId, ms)
    local def = Stores._unitKinds[kindId]
    if not def then return false, ('Unknown unit kind "%s"'):format(tostring(kindId)) end
    if def.mode ~= 'later' or type(ms) ~= 'number' or not (ms > 0) then
        return false, ('Stores.setUnitEvery(%s): a positive number of ms, on a "later" unit'):format(kindId)
    end
    def.every = ms
    return true
end

--- A handle for one unit, for Stores.markDirty / save / saveAll / settle like any store.
---@param kindId string
---@param key any  what persist gets (a vehicleId, a charId)
---@return table|nil unit
---@return string|nil err
function Stores.unit(kindId, key)
    local def = Stores._unitKinds[kindId]
    if not def then return nil, ('Unknown unit kind "%s"'):format(tostring(kindId)) end
    if key == nil then return nil, ('Unit %s needs a key'):format(kindId) end
    local name = def.unitKey and def.unitKey(key) or (kindId .. ':' .. tostring(key))
    return {
        kind   = def,
        key    = key,
        handle = key,
        id     = name,
        unit   = name,
        label  = def.label and def.label(key) or name,
    }
end

--- Do two store references point at the same store? Compares stable ids.
---@param a table
---@param b table
---@return boolean
local function sameStore(a, b)
    return a.kind.id == b.kind.id and a.id == b.id
end

Stores.sameStore = sameStore

-- Item definition access. An item with no definition (a satellite's, while it restarts) is not moved:
-- treating it as weightless would bypass weight limits.

---@param itemKey string
---@return table|nil def
local function itemDef(itemKey)
    return Config.Items[itemKey]
end

--- Weight of a stack, contents included (pass the metadata); nil when the item is unknown.
---@param itemKey string
---@param amount number
---@return number|nil
local function itemWeight(itemKey, amount, metadata)
    local def = itemDef(itemKey)
    if not def then return nil end
    return Inventory.effectiveWeight(itemKey, amount or 1, metadata)
end

--- Are two metadata tables equal (deep)? Strict: decides whether a slot changed and needs saving.
---@param a table|nil
---@param b table|nil
---@return boolean
local function metadataEquivalent(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    for k, v in pairs(a) do
        local other = b[k]
        if type(v) == 'table' and type(other) == 'table' then
            if not metadataEquivalent(v, other) then return false end
        elseif v ~= other then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

Stores.metadataEquivalent = metadataEquivalent

--- Bookkeeping keys that are not part of what an item is: `uid` is the activity log's instance id.
local STACK_IGNORED_KEYS = { uid = true }

local EMPTY_META = {}

--- Can these two stacks combine? Metadata equality ignoring top-level bookkeeping keys (uid); nil equals
--- "only a uid". A uid nested in an item's own sub-table is compared. Only stacking uses this: "did this slot
--- change" checks stay strict.
---@param a table|nil
---@param b table|nil
---@return boolean
local function stacksWith(a, b)
    a = a or EMPTY_META
    b = b or EMPTY_META

    for k, v in pairs(a) do
        if not STACK_IGNORED_KEYS[k] then
            local other = b[k]
            if type(v) == 'table' and type(other) == 'table' then
                if not metadataEquivalent(v, other) then return false end
            elseif v ~= other then
                return false
            end
        end
    end
    for k in pairs(b) do
        if not STACK_IGNORED_KEYS[k] and a[k] == nil then return false end
    end
    return true
end

Stores.stacksWith = stacksWith

--- Copy a metadata table so two slots never share one (metadata is stored by reference and encoded at save time).
--- Non-player kinds never pass through Inventory.setSlot, so the copy is needed here too.
---@param meta table|nil
---@return table|nil
local function copyMetadata(meta)
    return Inventory.copyMetadata(meta)
end

Stores.copyMetadata = copyMetadata

--- Total weight currently in a store. Items with no definition are skipped.
---@param store table
---@return number
function Stores.weightOf(store)
    local kind, handle = store.kind, store.handle
    if kind.weight then return kind.weight(handle) end

    local total = 0
    local slots = kind.slots(handle)
    for slot = 1, slots do
        local data = kind.get(handle, slot)
        if data and data.item then
            local w = itemWeight(data.item, data.amount, data.metadata)
            -- An undefined item weighs nothing here; moves refuse items with no definition.
            if w then total = total + w end
        end
    end
    return math.floor(total * 100 + 0.5) / 100
end

--- Is `inner` an open panel whose host item sits in `outer`? Its contents already count in `outer`'s weight
--- (a bag's weight includes its contents), so moving between the two must not be refused as "Too heavy".
---@param inner table  store
---@param outer table  store
---@return boolean
local function carriedInside(inner, outer)
    if not (inner and outer) or inner.kind ~= Stores._kinds.panel then return false end
    local h = inner.handle
    local host = h and h.session and h.session.host
    if not host or not host.container then return false end
    local hostStore = Stores.open('player', { source = h.source, container = host.container })
    return hostStore ~= nil and hostStore.id == outer.id
end

--- The pockets are one weight: the main grid and the strip together carry at most Inventory.pocketsMaxWeight.
--- Would `adding` kg coming into these pockets from outside take the character past it? `from` is the store it
--- leaves (nil: a pick up or a give). Moves within the pockets, or from a bag carried in them, answer false.
---@param store table  where it goes: any store but a player's pockets answers false
---@param adding number  kg
---@param from table|nil
---@return boolean over
function Stores.pocketsOver(store, adding, from)
    if not adding or adding <= 0 or store.kind.id ~= 'player' then return false end
    if from and from.unit == store.unit then return false end
    if from and from.kind == Stores._kinds.panel then
        local h = from.handle
        local host = h and h.session and h.session.host
        local hostStore = host and host.container and Stores.open('player', { source = h.source, container = host.container })
        if hostStore and hostStore.unit == store.unit then return false end
    end
    local cache = store.handle and store.handle.cache
    if not cache then return false end
    return Inventory.pocketsWeight(cache) + adding > Inventory.pocketsMaxWeight()
end

-- Move: one implementation for player containers, stashes, vehicle storage and panels.
-- `kind.get` returns the live slot table and `kind.set` replaces it. If both ends are the same slot they are one
-- table and a mover would mint items, so every mover reads its ends through readMoveEnds, which returns early for
-- the same slot and hands back detached copies. Metadata stays by reference until written into a second slot.

--- Read, validate and detach both ends of a move.
--- Returns nil in two cases, told apart by the second value:
---   nil, nil   the two ends are the same slot: nothing to do, which is a success.
---   nil, err   refused, with the reason to hand back to the player.
---@param fromStore table
---@param fromSlot number
---@param toStore table
---@param toSlot number
---@return table|nil ends  { def, from = {item,amount,metadata}, to = same|nil }
---@return string|nil err
local function readMoveEnds(fromStore, fromSlot, toStore, toSlot)
    local fromKind, fromHandle = fromStore.kind, fromStore.handle
    local toKind,   toHandle   = toStore.kind,   toStore.handle

    -- Same address: nothing to move, checked before any slot is read (everything below assumes distinct ends).
    if fromSlot == toSlot and sameStore(fromStore, toStore) then
        return nil, nil
    end

    if fromSlot < 1 or fromSlot > fromKind.slots(fromHandle) then
        return nil, 'Invalid slot number'
    end
    if toSlot < 1 or toSlot > toKind.slots(toHandle) then
        return nil, 'Invalid slot number'
    end

    local liveFrom = fromKind.get(fromHandle, fromSlot)
    if not liveFrom or not liveFrom.item or (liveFrom.amount or 0) < 1 then
        return nil, 'No item in source slot'
    end

    local def = itemDef(liveFrom.item)
    if not def then
        return nil, ('Unknown item "%s" — its resource may be restarting'):format(tostring(liveFrom.item))
    end

    if toKind.allows and not toKind.allows(toHandle, liveFrom.item, liveFrom.metadata) then
        return nil, 'That item does not go there'
    end
    -- The slot filter lives here so callers that skip the storeMove hooks are covered too.
    if toKind.allowsAt then
        local okAt, atReason = toKind.allowsAt(toHandle, toSlot, liveFrom.item, liveFrom.metadata)
        if not okAt then return nil, atReason or 'That item does not go there' end
    end

    -- A zero-amount slot counts as empty.
    local liveTo = toKind.get(toHandle, toSlot)
    if liveTo and (not liveTo.item or (liveTo.amount or 0) < 1) then
        liveTo = nil
    end

    return {
        def  = def,
        from = { item = liveFrom.item, amount = liveFrom.amount, metadata = liveFrom.metadata },
        to   = liveTo and { item = liveTo.item, amount = liveTo.amount, metadata = liveTo.metadata } or nil,
    }
end

--- Move an item between two store addresses. Handles merge, partial merge and swap.
---@param fromStore table
---@param fromSlot number
---@param toStore table
---@param toSlot number
---@return boolean ok
---@return string|nil err
function Stores.move(fromStore, fromSlot, toStore, toSlot)
    local ends, err = readMoveEnds(fromStore, fromSlot, toStore, toSlot)
    if not ends then
        return err == nil, err
    end

    local fromKind, fromHandle = fromStore.kind, fromStore.handle
    local toKind,   toHandle   = toStore.kind,   toStore.handle
    local def, fromData, toData = ends.def, ends.from, ends.to

    -- On a swap the returning item must be acceptable to the source store, and to the source slot (the beforeMove
    -- hooks only see the declared direction).
    if toData and fromKind.allows and not fromKind.allows(fromHandle, toData.item, toData.metadata) then
        return false, 'That item does not go there'
    end

    if toData and fromKind.allowsAt then
        local okAt, atReason = fromKind.allowsAt(fromHandle, fromSlot, toData.item, toData.metadata)
        if not okAt then
            return false, atReason or 'That item does not go there'
        end
    end

    -- ---- Merge two stacks of the same item ----
    if toData and toData.item == fromData.item
        and def.stack and def.maxStack and def.maxStack > 1
        and stacksWith(fromData.metadata, toData.metadata)
    then
        local canFit = def.maxStack - toData.amount

        -- Only what transfers is weighed: a partial merge moves canFit.
        local transfer = math.min(canFit, fromData.amount)
        if transfer > 0 and not sameStore(fromStore, toStore) and not carriedInside(fromStore, toStore) then
            local addedWeight = itemWeight(fromData.item, transfer, fromData.metadata)
            if addedWeight == nil then return false, 'Unknown item weight' end
            if (Stores.weightOf(toStore) + addedWeight) > toKind.maxWeight(toHandle)
                or Stores.pocketsOver(toStore, addedWeight, fromStore) then
                return false, 'Too heavy'
            end
        end

        -- Destination first, put back if the source refuses.
        if canFit >= fromData.amount then
            if not toKind.set(toHandle, toSlot, toData.item, toData.amount + fromData.amount, toData.metadata) then
                return false, 'Store is not available'
            end
            if fromKind.clear(fromHandle, fromSlot) == false then
                toKind.set(toHandle, toSlot, toData.item, toData.amount, toData.metadata)
                return false, 'Store is not available'
            end
            return true
        elseif canFit > 0 then
            if not toKind.set(toHandle, toSlot, toData.item, def.maxStack, toData.metadata) then
                return false, 'Store is not available'
            end
            if not fromKind.set(fromHandle, fromSlot, fromData.item, fromData.amount - canFit, fromData.metadata) then
                toKind.set(toHandle, toSlot, toData.item, toData.amount, toData.metadata)
                return false, 'Store is not available'
            end
            return true
        end
        -- Destination stack is full: fall through and swap instead.
    end

    if not sameStore(fromStore, toStore) then
        local movingWeight = itemWeight(fromData.item, fromData.amount, fromData.metadata)
        if movingWeight == nil then return false, 'Unknown item weight' end

        local returningWeight = 0
        if toData then
            local w = itemWeight(toData.item, toData.amount, toData.metadata)
            if w == nil then return false, 'Unknown item weight' end
            returningWeight = w
        end

        -- Not asked when the source is a bag carried in the destination: both are already on it.
        if not carriedInside(fromStore, toStore)
            and ((Stores.weightOf(toStore) - returningWeight + movingWeight) > toKind.maxWeight(toHandle)
                or Stores.pocketsOver(toStore, movingWeight - returningWeight, fromStore)) then
            return false, 'Too heavy'
        end

        -- On a swap, the source must hold what comes back. Same exemption the other way round.
        if toData and not carriedInside(toStore, fromStore) then
            if (Stores.weightOf(fromStore) - movingWeight + returningWeight) > fromKind.maxWeight(fromHandle)
                or Stores.pocketsOver(fromStore, returningWeight - movingWeight, toStore) then
                return false, 'Too heavy'
            end
        end
    end

    -- kind.set reports whether it wrote (an unloaded store refuses). Destination first, as it is the end that can
    -- refuse; the undo is safe because kind.set doesn't yield.
    if toData then
        if not toKind.set(toHandle, toSlot, fromData.item, fromData.amount, fromData.metadata) then
            return false, 'Store is not available'
        end
        if not fromKind.set(fromHandle, fromSlot, toData.item, toData.amount, toData.metadata) then
            toKind.set(toHandle, toSlot, toData.item, toData.amount, toData.metadata)
            return false, 'Store is not available'
        end
    else
        if not toKind.set(toHandle, toSlot, fromData.item, fromData.amount, fromData.metadata) then
            return false, 'Store is not available'
        end
        -- A source that can't be cleared would leave the item in both places: undo the destination.
        if fromKind.clear(fromHandle, fromSlot) == false then
            toKind.clear(toHandle, toSlot)
            return false, 'Store is not available'
        end
    end

    return true
end

--- Move a specific quantity out of a stack. A partial move can't swap, so the destination must be empty or hold
--- the same item with stack room and equivalent metadata.
---@param fromStore table
---@param fromSlot number
---@param toStore table
---@param toSlot number
---@param amount number|nil  nil or >= the whole stack delegates to Stores.move
---@return boolean ok
---@return string|nil err
function Stores.moveAmount(fromStore, fromSlot, toStore, toSlot, amount)
    local ends, err = readMoveEnds(fromStore, fromSlot, toStore, toSlot)
    if not ends then
        return err == nil, err
    end

    local fromKind, fromHandle = fromStore.kind, fromStore.handle
    local toKind,   toHandle   = toStore.kind,   toStore.handle
    local def, fromData, toData = ends.def, ends.from, ends.to

    if not amount or amount >= fromData.amount then
        return Stores.move(fromStore, fromSlot, toStore, toSlot)
    end
    -- Whole numbers only: the database column is INT.
    if amount < 1 or amount ~= math.floor(amount) then return false, 'Invalid amount' end
    -- A non-stackable slot holding several can't split: both halves would carry its metadata.
    if not def.stack then return false, 'That does not stack' end

    if toData then
        if toData.item ~= fromData.item then return false, 'Slot occupied' end
        if not stacksWith(fromData.metadata, toData.metadata) then return false, 'Different item state' end
        local room = (def.maxStack or 1) - toData.amount
        if room < amount then return false, 'Stack is full' end
    end

    -- A store with no weight limit (an infinite shelf) is not weighed.
    if not sameStore(fromStore, toStore) and not carriedInside(fromStore, toStore) then
        local movingWeight = itemWeight(fromData.item, amount, fromData.metadata)
        if movingWeight == nil then return false, 'Unknown item weight' end
        local limit = toKind.maxWeight(toHandle)
        if (limit ~= math.huge and (Stores.weightOf(toStore) + movingWeight) > limit)
            or Stores.pocketsOver(toStore, movingWeight, fromStore) then
            return false, 'Too heavy'
        end
    end

    -- Destination first: if it refuses, the source is untouched.
    local wrote
    if toData then
        wrote = toKind.set(toHandle, toSlot, toData.item, toData.amount + amount, toData.metadata)
    else
        wrote = toKind.set(toHandle, toSlot, fromData.item, amount, copyMetadata(fromData.metadata))
    end
    if not wrote then return false, 'Store is not available' end

    if not fromKind.set(fromHandle, fromSlot, fromData.item, fromData.amount - amount, copyMetadata(fromData.metadata)) then
        if toData then
            toKind.set(toHandle, toSlot, toData.item, toData.amount, toData.metadata)
        else
            toKind.clear(toHandle, toSlot)
        end
        return false, 'Store is not available'
    end
    return true
end

--- Move exactly one unit from a stack (right-click drag).
---@return boolean ok
---@return string|nil err
function Stores.moveOne(fromStore, fromSlot, toStore, toSlot)
    local ends, err = readMoveEnds(fromStore, fromSlot, toStore, toSlot)
    if not ends then
        return err == nil, err
    end

    local fromKind, fromHandle = fromStore.kind, fromStore.handle
    local toKind,   toHandle   = toStore.kind,   toStore.handle
    local def, fromData, toData = ends.def, ends.from, ends.to

    if not def.stack and fromData.amount > 1 then return false, 'That does not stack' end

    if toData then
        if toData.item ~= fromData.item then return false, 'Slot occupied' end
        if not stacksWith(fromData.metadata, toData.metadata) then return false, 'Different item state' end
        if def.maxStack and toData.amount >= def.maxStack then return false, 'Stack is full' end
    end

    -- Weight of the single unit crossing between stores (none, out of a bag carried in the destination).
    if not sameStore(fromStore, toStore) and not carriedInside(fromStore, toStore) then
        local unitWeight = itemWeight(fromData.item, 1, fromData.metadata)
        if unitWeight == nil then return false, 'Unknown item weight' end
        local limit = toKind.maxWeight(toHandle)
        if (limit ~= math.huge and (Stores.weightOf(toStore) + unitWeight) > limit)
            or Stores.pocketsOver(toStore, unitWeight, fromStore) then
            return false, 'Too heavy'
        end
    end

    -- Destination first; a new slot gets a copy of the metadata.
    local wrote
    if toData then
        wrote = toKind.set(toHandle, toSlot, toData.item, toData.amount + 1, toData.metadata)
    else
        wrote = toKind.set(toHandle, toSlot, fromData.item, 1, copyMetadata(fromData.metadata))
    end
    if not wrote then return false, 'Store is not available' end

    if fromData.amount <= 1 then
        if fromKind.clear(fromHandle, fromSlot) == false then
            if toData then
                toKind.set(toHandle, toSlot, toData.item, toData.amount, toData.metadata)
            else
                toKind.clear(toHandle, toSlot)
            end
            return false, 'Store is not available'
        end
    elseif not fromKind.set(fromHandle, fromSlot, fromData.item, fromData.amount - 1, fromData.metadata) then
        if toData then
            toKind.set(toHandle, toSlot, toData.item, toData.amount, toData.metadata)
        else
            toKind.clear(toHandle, toSlot)
        end
        return false, 'Store is not available'
    end

    return true
end

--- The first empty slot that would accept this item (allowsAt: accessory slots are typed): where a split's new
--- half goes. The NUI predicts the same slot.
---@param store table
---@param itemKey string
---@param metadata table|nil
---@return number|nil slot
function Stores.freeSlot(store, itemKey, metadata)
    local kind, handle = store.kind, store.handle
    for s = 1, kind.slots(handle) do
        if not kind.get(handle, s)
            and (not kind.allowsAt or kind.allowsAt(handle, s, itemKey, metadata))
        then
            return s
        end
    end
    return nil
end

-- Stores.place creates an item and Stores.take destroys one (the StoreGive and StoreTake exports). They are not
-- moves, but share slot bounds, weight, item filters and stacking with the mover.

--- Put an item into a specific slot, creating it.
--- Merges onto a matching stack when metadata is equivalent, otherwise requires an empty slot.
---@param store table
---@param slot number|string|nil
---@param itemKey string
---@param amount number
---@param metadata table|nil
---@return boolean ok
---@return string|nil err
function Stores.place(store, slot, itemKey, amount, metadata)
    local kind, handle = store.kind, store.handle

    -- Satellites call StoreGive: reject a fractional amount or a non-integer slot.
    amount = tonumber(amount) or 1
    if amount < 1 or amount ~= math.floor(amount) then return false, 'Invalid amount' end

    slot = tonumber(slot)
    if not slot or slot ~= math.floor(slot) then return false, 'Invalid slot' end

    local def = itemDef(itemKey)
    if not def then return false, 'Unknown item' end

    if slot < 1 or slot > kind.slots(handle) then return false, 'Invalid slot' end
    if kind.allows and not kind.allows(handle, itemKey, metadata) then
        return false, 'That item does not go there'
    end
    if kind.allowsAt then
        local okAt, atReason = kind.allowsAt(handle, slot, itemKey, metadata)
        if not okAt then return false, atReason or 'That item does not go there' end
    end

    local addWeight = itemWeight(itemKey, amount, metadata)
    if addWeight == nil then return false, 'Unknown item weight' end
    if (Stores.weightOf(store) + addWeight) > kind.maxWeight(handle) or Stores.pocketsOver(store, addWeight, nil) then
        return false, 'Too heavy'
    end

    local existing = kind.get(handle, slot)
    if existing then
        if existing.item ~= itemKey then return false, 'Slot occupied' end
        if not stacksWith(existing.metadata, metadata) then return false, 'Different item state' end
        if not (def.stack and def.maxStack and def.maxStack > 1) then return false, 'Slot occupied' end
        if (def.maxStack - existing.amount) < amount then return false, 'Stack is full' end
        if not kind.set(handle, slot, itemKey, existing.amount + amount, existing.metadata) then
            return false, 'Store is not available'
        end
        return true
    end

    if not kind.set(handle, slot, itemKey, amount, copyMetadata(metadata)) then
        return false, 'Store is not available'
    end
    return true
end

--- First slot that can accept this item: a partial stack it merges into, otherwise the first empty slot.
--- For callers that don't care which slot (a give, a purchase, a reward); it asks the same kind functions the
--- move uses.
---@param store table
---@param itemKey string
---@param amount number
---@param metadata table|nil
---@return number|nil slot  nil when the store has no room
function Stores.slotAccepting(store, itemKey, amount, metadata)
    local kind, handle = store.kind, store.handle
    local def = itemDef(itemKey)
    if not def then return nil end

    local total = kind.slots(handle)
    amount = tonumber(amount) or 1

    -- The same two filters the movers apply: the store as a whole, then each slot.
    if kind.allows and not kind.allows(handle, itemKey, metadata) then return nil end
    local function takes(slot)
        if not kind.allowsAt then return true end
        local okAt = kind.allowsAt(handle, slot, itemKey, metadata)
        return okAt and true or false
    end

    -- Merge into a partial stack before occupying a new slot.
    if def.stack and (def.maxStack or 1) > 1 then
        for slot = 1, total do
            local d = kind.get(handle, slot)
            if d and d.item == itemKey
                and stacksWith(d.metadata, metadata)
                and ((d.amount or 1) + amount) <= def.maxStack
                and takes(slot)
            then
                return slot
            end
        end
    end

    for slot = 1, total do
        if not kind.get(handle, slot) and takes(slot) then return slot end
    end
    return nil
end

--- Remove a quantity from a slot, destroying it.
---@param store table
---@param slot number|string|nil
---@param amount number|nil  nil removes the whole stack
---@return boolean ok
---@return string|nil err
---@return table|nil removed  { item, amount, metadata } for the caller to act on
function Stores.take(store, slot, amount)
    local kind, handle = store.kind, store.handle

    slot = tonumber(slot)
    if not slot or slot ~= math.floor(slot) then return false, 'Invalid slot' end

    local data = kind.get(handle, slot)
    if not data then return false, 'Empty slot' end

    amount = amount and tonumber(amount) or data.amount
    if not amount or amount < 1 or amount ~= math.floor(amount) then return false, 'Invalid amount' end
    if amount > data.amount then return false, 'Not enough items' end

    local removed = { item = data.item, amount = amount, metadata = copyMetadata(data.metadata) }

    if amount >= data.amount then
        if kind.clear(handle, slot) == false then return false, 'Store is not available' end
    elseif not kind.set(handle, slot, data.item, data.amount - amount, data.metadata) then
        return false, 'Store is not available'
    end
    return true, nil, removed
end

-- Kind: player. Each container is a separate store (own slots and weight), but all persist as one unit keyed by
-- charId, so a character's rows are written and pruned together.

Stores.defineKind('player', {
    --- key is { source = <playerId>, container = <a PlayerContainers entry> }
    resolve = function(key)
        local player = Players[key.source]
        if not player or not player.inventory then return nil end
        -- Only a container the character has: with the strip off (Config.AccessoryStrip), 'accessory' is nothing.
        if not Inventory.isPlayerContainer(key.container) or not Config.ContainerSlots[key.container] then return nil end
        return { player = player, cache = player.inventory, container = key.container }
    end,

    instanceId = function(_, h)
        return ('player:%d:%s'):format(h.player.charId, h.container)
    end,

    -- The whole character is one row-set (pruned together), so one container's flush can't delete another's rows.
    unitKey = function(_, h)
        return 'player:' .. h.player.charId
    end,

    label = function(_, h)
        return ('%s[%s]'):format(h.player.fullName or 'player', tostring(h.container))
    end,

    slots     = function(h) return Config.ContainerSlots[h.container] end,
    maxWeight = function(h) return Config.MaxWeight[h.container] or 9999 end,

    get = function(h, slot)
        return Inventory.getSlot(h.cache, h.container, slot)
    end,
    set = function(h, slot, item, amount, metadata)
        Inventory.setSlot(h.cache, h.container, slot, item, amount, metadata)
        return true
    end,
    clear = function(h, slot)
        Inventory.clearSlot(h.cache, h.container, slot)
    end,

    -- The accessory strip's per-slot rule, on every path (beforeMove below only sees the drag path).
    allowsAt = function(h, slot, itemKey)
        if h.container ~= 'accessory' then return true end
        local def = Inventory.AccessorySlots[slot]
        if not def then
            return false, 'No such accessory slot'
        end
        if def.accepts and itemKey ~= def.accepts then
            local acceptedDef = Config.Items[def.accepts]
            return false, ('Only %s can go there'):format(acceptedDef and acceptedDef.name or def.label)
        end
        return true
    end,

    -- The same rule on the drag path (the NUI has a copy for instant refusals; this is the real gate).
    beforeMove = function(h, ctx)
        if h.container ~= 'accessory' then return true end
        -- Only the destination slot's rule matters; moving out is always allowed.
        local destSlot
        if ctx.direction == 'in' then
            destSlot = ctx.slot
        elseif ctx.direction == 'within' then
            destSlot = ctx.otherSlot
        else
            return true
        end
        local def = Inventory.AccessorySlots[destSlot]
        if not def then
            return false, 'No such accessory slot'
        end
        if def.accepts and ctx.item ~= def.accepts then
            local acceptedDef = Config.Items[def.accepts]
            return false, ('Only %s can go there'):format(acceptedDef and acceptedDef.name or def.label)
        end
        return true
    end,

    -- The pockets and the character row and position are one unit and one transaction, so they can't deadlock
    -- or land out of order.
    persist = function(h)
        local queries, confirm = Inventory.buildSaveQueries(h.player.charId, h.cache)
        if queries == nil then return nil end
        local rowQueries, rowConfirm = PlayerRows.pending(h.player)
        for _, q in ipairs(rowQueries) do queries[#queries + 1] = q end
        return queries, function()
            if confirm then confirm() end
            if rowConfirm then rowConfirm() end
        end
    end,
    -- Forget the save snapshot: the next persist writes everything.
    invalidate = function(h) Inventory.invalidateSnapshot(h.cache) end,

    -- Deferred: the pockets change most often. Stores.saveAll commits at once when a move touches a
    -- write-through store; only changes inside the character wait.
    durability = 'writeBehind',
})

--- Convenience: open one of a player's containers.
---@param source number
---@param container string
---@return table|nil store
---@return string|nil err
function Stores.player(source, container)
    return Stores.open('player', { source = source, container = container })
end

-- Kind: rawInventory. Like 'player' but the cache is handed in (admin inventory viewer, on an online target's
-- live table or an offline one loaded from the database).

Stores.defineKind('rawInventory', {
    --- key is { cache = <inventory table>, container = <a PlayerContainers entry>, charId = number }
    resolve = function(key)
        if type(key.cache) ~= 'table' then return nil end
        if not Config.ContainerSlots[key.container] then return nil end
        if not key.charId then return nil end
        return { cache = key.cache, container = key.container, charId = key.charId }
    end,

    instanceId = function(_, h) return ('raw:%d:%s'):format(h.charId, h.container) end,
    -- The player's own unit for their live cache, so an admin edit and the player's flush can't commit side by side.
    unitKey    = function(_, h)
        local live = PlayersByCharId and PlayersByCharId[h.charId]
        if live and live.inventory == h.cache then return 'player:' .. tostring(h.charId) end
        return 'raw:' .. tostring(h.charId)
    end,
    label      = function(_, h) return ('char%d[%s]'):format(h.charId, h.container) end,

    slots     = function(h) return Config.ContainerSlots[h.container] end,
    maxWeight = function(h) return Config.MaxWeight[h.container] or 9999 end,

    get   = function(h, slot) return Inventory.getSlot(h.cache, h.container, slot) end,
    set   = function(h, slot, item, amount, metadata)
        Inventory.setSlot(h.cache, h.container, slot, item, amount, metadata)
        return true
    end,
    clear = function(h, slot) Inventory.clearSlot(h.cache, h.container, slot) end,

    -- The accessory strip's typed slots, as the 'player' kind.
    allowsAt = function(h, slot, itemKey)
        if Inventory.slotTakes(h.container, slot, itemKey) then return true end
        return false, 'That slot only takes one kind of item'
    end,

    persist = function(h) return Inventory.buildSaveQueries(h.charId, h.cache) end,
    invalidate = function(h) Inventory.invalidateSnapshot(h.cache) end,
})

--- Open an arbitrary character's inventory container from a cache you already hold.
---@param cache table
---@param charId number
---@param container string
---@return table|nil store
---@return string|nil err
function Stores.rawInventory(cache, charId, container)
    return Stores.open('rawInventory', { cache = cache, container = container, charId = charId })
end

-- allowedItems: an array `{ 'food', 'drink' }` or a set `{ food = true }` (both exist in saved data and satellites).
---@param allowed table|nil  array of keys, or a set keyed by item
---@param itemKey string
---@return boolean
function Stores.itemAllowedBy(allowed, itemKey)
    if not allowed then return true end          -- no list = everything allowed

    -- Set form: { food = true } / { food = {} }
    if allowed[itemKey] ~= nil then return true end

    -- Array form: { 'food', 'drink' }
    for _, entry in ipairs(allowed) do
        if entry == itemKey then return true end
    end

    -- A list that is present but matches nothing means "not allowed". An EMPTY list is
    -- treated as no restriction, matching how Containers.update clears the field.
    if next(allowed) == nil then return true end
    return false
end

-- Kind: container (persistent world stashes)

Stores.defineKind('container', {
    --- key is the containerId
    resolve = function(containerId)
        local def = Containers.getDef(containerId)
        if not def then return nil end
        -- Contents load on open and unload on close. A nil cache means "unknown", never
        -- "empty" — refusing here is what stops a failed load from emptying the stash.
        local inv = Containers.invCache[containerId]
        if not inv then return nil end
        return { containerId = containerId, def = def }
    end,

    instanceId = function(containerId) return 'container:' .. tostring(containerId) end,
    unitKey    = function(containerId) return 'container:' .. tostring(containerId) end,
    label      = function(containerId, h) return ('%s#%s'):format(h.def.name or 'container', tostring(containerId)) end,

    slots     = function(h) return h.def.slots or Config.ContainerDefaultSlots end,
    maxWeight = function(h) return h.def.maxWeight or Config.ContainerDefaultWeight end,

    get       = function(h, slot) return Containers.getSlot(h.containerId, slot) end,
    set       = function(h, slot, item, amount, metadata)
        return Containers.setSlot(h.containerId, slot, item, amount, metadata)
    end,
    clear     = function(h, slot) Containers.clearSlot(h.containerId, slot) end,

    -- A key never goes into the container it opens: inside, it would lock everyone out for good.
    -- Asked here because every way into a store asks `allows` (drag, swap, quick-move, StoreGive).
    allows    = function(h, itemKey)
        local req = h.def.requirements
        if type(req) == 'table' and type(req.items) == 'table' then
            for _, need in ipairs(req.items) do
                if type(need) == 'table' and need.key == itemKey then return false end
            end
        end
        return Stores.itemAllowedBy(h.def.allowedItems, itemKey)
    end,
    persist   = function(h) return Containers.buildSaveQueries(h.containerId) end,
    invalidate = function(h) Containers.invalidateSnapshot(h.containerId) end,

    -- Deferred (a shop's stock can hold a thousand slots). A player <-> stash move defers both ends, so one flush
    -- writes both in one transaction. unloadInventory flushes before dropping the cache.
    durability = 'writeBehind',
})

--- Open a persistent container as a store.
---@param containerId number
---@return table|nil store
---@return string|nil err
function Stores.container(containerId)
    return Stores.open('container', containerId)
end

-- Kind: vehicle storage (trunk / glovebox / ignition). The ignition ('key') is a one-slot store with a strict item
-- filter. The unit is vehicleId:storageType because rows are pruned per storage type: a vehicle-wide unit would let
-- a trunk save delete the glovebox.

Stores.defineKind('vehicle', {
    --- key is { vehicleId = number, storageType = 'trunk'|'glovebox'|'key' }
    resolve = function(key)
        local def = Vehicles.getDef(key.vehicleId)
        if not def then return nil end
        local inv = Vehicles.invCache[key.vehicleId]
        if not inv or not inv[key.storageType] then return nil end
        return { vehicleId = key.vehicleId, storageType = key.storageType, def = def }
    end,

    instanceId = function(key) return ('vehicle:%s:%s'):format(tostring(key.vehicleId), tostring(key.storageType)) end,
    unitKey    = function(key) return ('vehicle:%s:%s'):format(tostring(key.vehicleId), tostring(key.storageType)) end,
    label      = function(_, h) return ('%s %s'):format(h.def.plate or 'vehicle', tostring(h.storageType)) end,

    slots     = function(h) return Vehicles.getStorageConfig(h.vehicleId, h.storageType).slots end,
    maxWeight = function(h) return Vehicles.getStorageConfig(h.vehicleId, h.storageType).maxWeight end,

    get       = function(h, slot) return Vehicles.getSlot(h.vehicleId, h.storageType, slot) end,
    set       = function(h, slot, item, amount, metadata)
        return Vehicles.setSlot(h.vehicleId, h.storageType, slot, item, amount, metadata)
    end,
    clear     = function(h, slot) Vehicles.clearSlot(h.vehicleId, h.storageType, slot) end,

    -- This is what makes the ignition work: only a key matching THIS vehicle may go in.
    allows    = function(h, itemKey, metadata)
        return Vehicles.isItemAllowed(h.vehicleId, h.storageType, itemKey, metadata)
    end,

    --- The ignition refuses a swap: the key already in it would silently leave the vehicle.
    beforeMove = function(h, ctx)
        if h.storageType ~= 'key' then return true end
        if ctx.direction == 'in' and Vehicles.getSlot(h.vehicleId, 'key', 1) then
            return false
        end
        return true
    end,

    --- A key in or out changes whether the engine can run: tell the client.
    afterMove = function(h, ctx)
        if h.storageType ~= 'key' then return end
        local src = ctx.source
        if not src then return end

        local player = Players[src]
        if player then
            Vehicles.syncKeys(src, player)
        end
        TriggerClientEvent('whip_core:client:ignitionState', src, h.vehicleId,
            Vehicles.ignitionReady(h.vehicleId),
            Vehicles.hasUnhackedKeyInIgnition(h.vehicleId))
        TriggerClientEvent('whip_core:client:updateIgnitionSlot', src, {
            ignitionSlot = Vehicles.getIgnitionSlot(h.vehicleId),
        })
    end,

    --- A key put in or taken out by a resource (StoreGive / StoreTake, Dungeon Mode's Key settings): whoever sits in
    --- the car is told, as a drag tells the one who dragged, or their engine runs on with no key.
    afterWrite = function(h)
        if h.storageType == 'key' then Vehicles.tellIgnition(h.vehicleId) end
    end,

    persist   = function(h) return Vehicles.buildSaveQueries(h.vehicleId, h.storageType) end,
    invalidate = function(h) Vehicles.invalidateStorageSnapshot(h.vehicleId, h.storageType) end,

    -- Deferred, as containers. invCache is one table per vehicle, so dropping it retires up to three
    -- units: Vehicles.flushStorage writes every cached compartment first.
    durability = 'writeBehind',
})

--- Open a vehicle storage compartment as a store.
---@param vehicleId number
---@param storageType string  'trunk' | 'glovebox' | 'key'
---@return table|nil store
---@return string|nil err
function Stores.vehicle(vehicleId, storageType)
    return Stores.open('vehicle', { vehicleId = vehicleId, storageType = storageType })
end

--- The ignition is the vehicle's one-slot 'key' storage.
---@param vehicleId number
---@return table|nil store
---@return string|nil err
function Stores.ignition(vehicleId)
    return Stores.open('vehicle', { vehicleId = vehicleId, storageType = 'key' })
end

-- Kind: panel (OpenPanel): a grid a resource opens for one player (crafting input, magazine, SIM tray). No
-- persistence (`persist` is nil): the owner gets the contents back through onClose. Hooks (onValidate before a
-- move, onChange after) come from Panels.hooksFor via beforeMove / afterMove with one ctx (Stores.panelHookCtx).

Stores.defineKind('panel', {
    --- key is { src, panelId }. panelId nil resolves only when exactly one panel is open
    --- (Panels.sessionFor refuses to guess).
    resolve = function(key)
        if type(key) ~= 'table' then return nil end
        if not Panels then return nil end   -- panels.lua loads after this file
        local session = Panels.sessionFor(key.src, key.panelId)
        if not session then return nil end
        return { source = key.src, session = session }
    end,

    instanceId = function(_, h) return 'panel:' .. tostring(h.session.id) end,
    -- Ephemeral: never enqueued for persistence, so the unit key is only ever a label.
    unitKey    = function(_, h) return 'panel:' .. tostring(h.session.id) end,
    label      = function(_, h) return tostring(h.session.config.label or h.session.id) end,

    slots     = function(h) return h.session.config.slots or 10 end,
    maxWeight = function(h) return h.session.config.maxWeight or math.huge end,

    get   = function(h, slot) return h.session.items[slot] end,
    set   = function(h, slot, item, amount, metadata)
        h.session.items[slot] = { item = item, amount = amount, metadata = metadata }
        return true
    end,
    clear = function(h, slot) h.session.items[slot] = nil end,

    allows = function(h, itemKey)
        return Stores.itemAllowedBy(h.session.config.allowedItems, itemKey)
    end,

    --- The panel's own rules (read-only, its host item, carry weight), then its onValidate(ctx) hook
    --- (panelHookCtx below says what ctx holds).
    beforeMove = function(h, ctx)
        local session = h.session
        if session.config and session.config.readOnly and ctx.direction ~= 'within' then
            return false, 'This is read-only'
        end

        -- The host is checked for every panel that has one: a bag moved away with its panel open would duplicate
        -- whatever is dragged out of it. Panels.resolveHost follows the host by uid within the pockets.
        local host
        if session.host then
            host = Panels.resolveHost(h.source, session)
            if not host then
                -- The item this panel describes is gone. Refuse the move, and shut the panel
                -- rather than leave it open showing contents that no longer exist anywhere.
                Panels.closeIfHostGone(h.source, session)
                return false, 'That item is no longer there'
            end

            -- The host changed without the panel (a shot, a reload): the panel was just repainted,
            -- and this move aimed at what it used to show, so it is refused.
            if Panels.refreshFromHost(h.source, session, host) then
                return false, 'That changed while it was open. Try again.'
            end

            -- Anything from outside the container the bag sits in is weighed against that container (the
            -- pockets and the accessory strip have separate limits).
            local otherKind = ctx.other and ctx.other.kind.id
            local alreadyCarried = false
            if otherKind == 'player' then
                alreadyCarried = ctx.other.handle.container == host.container
            elseif otherKind == 'panel' and ctx.other.handle.source == h.source and ctx.other.handle.session.host ~= nil then
                local otherHost = Panels.resolveHost(h.source, ctx.other.handle.session)
                alreadyCarried = otherHost ~= nil and otherHost.container == host.container
            end
            -- Weight is only followed Inventory.MAX_NESTING levels down, so deeper packing is refused.
            -- This bag is level 1, so what goes in may be at most MAX_NESTING - 1 deep itself.
            if ctx.direction == 'in' and ctx.item
                and 1 + Inventory.nestingDepth(ctx.item, ctx.metadata) > Inventory.MAX_NESTING then
                return false, 'That is packed too deep to fit in there'
            end

            if ctx.direction == 'in' and ctx.other and not alreadyCarried then
                local hostStore = Stores.player(h.source, host.container)
                local adding = itemWeight(ctx.item, ctx.amount, ctx.metadata)
                if hostStore and (adding == nil
                    or Stores.weightOf(hostStore) + adding > hostStore.kind.maxWeight(hostStore.handle)
                    or Stores.pocketsOver(hostStore, adding, ctx.other)) then
                    return false, 'Too heavy to carry'
                end
            end
        end

        -- The panel's own rule (a RegisterPanelItem contract or the opener's), which may depend on the host item.
        -- Only `false` refuses; an error refuses too.
        local hooks, hookOwner = Panels.hooksFor(session)
        if hooks and hooks.onValidate ~= nil then
            local called, allowed, reason = Actions.call(hookOwner, hooks.onValidate, Stores.panelHookCtx(ctx, h, host))
            if not called then error(allowed, 0) end
            if allowed == false then
                return false, reason or 'Not allowed'
            end
        end

        -- The item must be able to save the result: its write() is tried first, so a broken one
        -- refuses the move rather than leaving it unsaved (Panels.writeWouldFail).
        if host and session.registration then
            local why = Panels.writeWouldFail(session, host, ctx)
            if why then return false, why end
        end
        return true
    end,

    --- After a move landed: fold a RegisterPanelItem panel into its item, then the panel's onChange. An error is
    --- logged by Stores.afterMove and rolls nothing back.
    afterMove = function(h, ctx)
        local session = h.session
        local hooks, hookOwner = Panels.hooksFor(session)
        local host

        if session.registration then
            -- Fold first, notify second: the contents become as durable as the host item at once.
            -- The fold's inventory update is this move's reply only if the NUI is waiting on one and
            -- nothing answered yet (storeMove's `awaitsReply`); otherwise it goes out unsolicited.
            local d = ctx.detail
            local asReply = d ~= nil and d.awaitsReply == true and not d.replied
            local folded, foldWhy = Panels.persistToHost(h.source, session, asReply)
            if folded and asReply then d.replied = true end
            if not folded then
                if Panels.closeIfHostGone(h.source, session) then
                    -- The host went while this move was in flight; the panel is shut.
                    return
                end
                -- The host is there but refused the fold: see Panels.foldFailed.
                Panels.foldFailed(h.source, session, ctx, foldWhy)
                return
            end
            if not (hooks and hooks.onChange ~= nil) then return end

            -- Resolved after the fold, so the host handed over carries the change.
            host = Panels.resolveHost(h.source, session)
            if not host then return end
        else
            -- A panel a resource opened: note who put what in, so the last close can hand it back
            -- when no onClose takes it (Panels.noteMove).
            Panels.noteMove(session, ctx)
            if not (hooks and hooks.onChange ~= nil) then return end
        end

        local cctx = Stores.panelHookCtx(ctx, h, host)
        -- What the panel holds now — a copy, keyed by slot. A hook that wants to change it uses
        -- StoreGive / StoreTake with the panel's address, which are logged and shown to viewers.
        local items = {}
        for slot, d in pairs(session.items) do
            if type(d) == 'table' then
                items[slot] = { item = d.item, amount = d.amount, metadata = copyMetadata(d.metadata) }
            end
        end
        cctx.items = items
        -- An error reaches Stores.afterMove, which logs it.
        local called, err = Actions.call(hookOwner, hooks.onChange, cctx)
        if not called then error(err, 0) end
    end,

    -- No persist: contents belong to the opener. A RegisterPanelItem panel folds them into the host
    -- item's metadata, which the host's store persists (`read`/`write` on the registration).
    persist = nil,
})

--- Open one of a player's open panels as a store.
---@param source number
---@param panelId any|nil  which panel; nil resolves only when exactly one is open
---@return table|nil store
---@return string|nil err
function Stores.panel(source, panelId)
    return Stores.open('panel', { src = source, panelId = panelId })
end

--- Would this move put an item inside itself (a bag into its own open panel)? Returns a refusal reason, or nil.
--- Checked by Stores.beforeMove for every client move. One level is enough: a panel only opens on an item
--- directly in the player's own containers. The host is matched by uid (its slot may be stale), falling back to
--- the slot for a host opened without a uid.
---@param from table  {store, slot}
---@param to table    {store, slot}
---@param detail table|nil  the item moving, { item, amount, metadata }; read from `from` when absent
---@return string|nil reason
function Stores.selfContainment(from, to, detail)
    if not (from and to and from.store and to.store) then return nil end
    if to.store.kind ~= Stores._kinds.panel then return nil end

    local h = to.store.handle
    local host = h and h.session and h.session.host
    if not host then return nil end

    if host.uid ~= nil then
        local moving = detail
        if moving == nil and from.store.kind and from.store.kind.get then
            moving = from.store.kind.get(from.store.handle, from.slot)
        end
        local meta = moving and moving.metadata
        if moving and meta and meta.uid == host.uid and (host.itemKey == nil or moving.item == host.itemKey) then
            return 'that cannot hold itself'
        end
        return nil
    end

    if not host.container or not host.slot then return nil end

    -- Compare store identities rather than rebuilding the kind's id format here.
    local hostStore = Stores.open('player', { source = h.source, container = host.container })
    if not hostStore then return nil end

    if from.store.id == hostStore.id and from.slot == host.slot then
        return 'that cannot hold itself'
    end
    return nil
end

-- Kind: basket, the shop's staging grid. One per player while a shop is open; never persisted (unpaid goods).
-- A real store so the shop's drags are ordinary moves. Sessions live in `_basketSessions` (server/shops.lua).
Stores.defineKind('basket', {
    resolve = function(source)
        local session = _basketSessions and _basketSessions[source]
        if not session then return nil end
        return { source = source, session = session }
    end,

    instanceId = function(_, h) return 'basket:' .. tostring(h.source) end,
    unitKey    = function(_, h) return 'basket:' .. tostring(h.source) end,
    label      = function() return 'Basket' end,

    slots     = function(h) return h.session.slots or 10 end,

    -- A basket is a list: weight is checked when the goods move into the buyer's inventory at purchase.
    maxWeight = function() return math.huge end,

    get   = function(h, slot) return h.session.items[slot] end,
    set   = function(h, slot, item, amount, metadata)
        h.session.items[slot] = { item = item, amount = amount, metadata = metadata }
        return true
    end,
    clear = function(h, slot) h.session.items[slot] = nil end,

    --- Unpaid goods: no drag may touch a basket. The shop screen has its own actions (server/shops.lua), and no
    --- client or resource can name a basket as an address, so anything reaching this hook came by an unintended path.
    beforeMove = function()
        return false, 'Use the shop screen'
    end,

    persist = nil,
})

--- Open a player's basket as a store.
---@param source number
---@return table|nil store
---@return string|nil err
function Stores.basket(source)
    return Stores.open('basket', source)
end

-- Kind: shop, the sell side for infinite and NPC shops only (a stocked shop's stock is a real container). The
-- catalog is a price list: one row per entry, and writes are no-ops, so the shelf is always full.
Stores.defineKind('shop', {
    resolve = function(shopId)
        local def = Shops and Shops.getDef and Shops.getDef(shopId)
        if not def then return nil end
        -- Stocked shops must never reach this kind; fromWire sends those to the container.
        if def.mode == 'stocked' then return nil end

        -- Sorted: slot 3 must mean the same item on every read, and pairs() order is not stable.
        local keys = {}
        for itemKey in pairs(def.catalog or {}) do keys[#keys + 1] = itemKey end
        table.sort(keys)

        return { shopId = shopId, def = def, keys = keys }
    end,

    instanceId = function(_, h) return 'shop:' .. tostring(h.shopId) end,
    unitKey    = function(_, h) return 'shop:' .. tostring(h.shopId) end,
    label      = function(_, h) return tostring(h.def.name or ('Shop ' .. tostring(h.shopId))) end,

    slots     = function(h) return #h.keys end,
    maxWeight = function() return math.huge end,

    --- One synthetic row per catalog entry, amount 1, with the item's generated metadata as Inventory.addItem
    --- would make it (a jerry can's fuel, a serial). Random ones (serials) don't stack.
    get = function(h, slot)
        local itemKey = h.keys[slot]
        if not itemKey then return nil end

        local metadata = nil
        local gen = Inventory and Inventory.MetaGenerators and Inventory.MetaGenerators[itemKey]
        if gen then
            -- A generator that errors sells the item bare. Made for nobody ('shelf'); a bought one is made again
            -- for its buyer if asked (forBuyer, server/shops.lua).
            metadata = Inventory.runMetaGen(gen, itemKey, { reason = 'shelf' })
        end

        return { item = itemKey, amount = 1, metadata = metadata }
    end,

    -- Infinite: the shelf never changes. No-ops on purpose.
    set   = function() return true end,
    clear = function() end,

    --- Every read is a new row (random metadata differs), so commitMove's change check compares the item only.
    synthetic = true,

    --- Nothing goes into an infinite shop (`set` would destroy it); selling back is its own transaction.
    beforeMove = function(_, ctx)
        if ctx.direction == 'in' then
            return false, 'This shop does not buy items'
        end
        return true
    end,

    persist = nil,
})

--- Open an infinite/NPC shop's shelf as a store.
---@param shopId any
---@return table|nil store
---@return string|nil err
function Stores.shop(shopId)
    return Stores.open('shop', shopId)
end

-- StoreMove, the public move: goes through Stores.commitMove like a player's drag (hooks, persistence, sync).
-- Takes addresses `{ kind, id, sub, slot }`, e.g.
--     exports.whip_core:StoreMove({ kind = 'container', id = 12, slot = 3 },
--                                 { kind = 'player', id = source, sub = 'player', slot = 1 })

--- Move a stack between any two stores as one committed operation (the StoreMove export's body).
--- `opts.source` is the player the move is for, handed to the stores' hooks; whip_core only, the export does not
--- pass it on.
---@param fromAddr table  { kind, id?, sub?, slot }
---@param toAddr table    { kind, id?, sub?, slot? } — no slot: wherever it fits
---@param opts table|nil  { amount?: number, mode?: 'move'|'one'|'split', reason?: string, source?: number }
---@param askedBy string|nil  who asked, for the log ('by whip_core' when nil)
---@return boolean ok
---@return string|nil err
function Stores.moveByAddress(fromAddr, toAddr, opts, askedBy)
    local from, to, fromSlot, toSlot, err

    askedBy = askedBy or 'by whip_core'
    local why = Log.reasonFrom(type(opts) == 'table' and opts.reason or nil) or askedBy

    if type(fromAddr) ~= 'table' or type(toAddr) ~= 'table' then
        return false, 'StoreMove takes two addresses: { kind, id, sub, slot }'
    end
    if opts ~= nil and type(opts) ~= 'table' then
        return false, 'StoreMove options must be a table: { amount, mode, reason }'
    end
    -- A whole number of 1 or more, or left out for the whole stack.
    local amount = nil
    if type(opts) == 'table' and opts.amount ~= nil then
        amount = Sanitize.amount(opts.amount)
        if not amount then return false, Sanitize.AMOUNT_ERR end
    end

    from, fromSlot, err = Stores.fromAddr(fromAddr)
    if not from then return false, err end
    -- The destination slot may be left out: "wherever it fits".
    to, toSlot, err = Stores.fromAddr(toAddr, { slotOptional = true })
    if not to then return false, err end
    if not toSlot then
        local moving = from.kind.get(from.handle, fromSlot)
        if not moving then return false, 'Empty slot' end
        local fits = (amount and amount <= moving.amount) and amount or moving.amount
        toSlot = Stores.slotAccepting(to, moving.item, fits, moving.metadata)
        if not toSlot then return false, 'No room there' end
    end

    opts = opts or {}

    local fromAddrResolved = { store = from, slot = fromSlot }
    local toAddrResolved   = { store = to,   slot = toSlot }

    local ok, moveErr = Stores.commitMove(
        fromAddrResolved,
        toAddrResolved,
        {
            mode   = opts.mode,
            amount = amount,   -- checked above
            source = opts.source,

            -- Anyone with these stores open is told, after the write and before afterMove.
            onCommitted = function()
                Stores.publishSlots(from, { fromSlot })
                if not (to.id == from.id and toSlot == fromSlot) then
                    Stores.publishSlots(to, { toSlot })
                end

                -- And the owner of a player store (never a viewer of their own pockets), once per player.
                local synced = {}
                for _, addr in ipairs({ fromAddrResolved, toAddrResolved }) do
                    local store = addr.store
                    if store.kind.id == 'player' then
                        local owner = store.handle and store.handle.player
                        local src = owner and owner.source
                        if src and not synced[src] and Inventory.syncToClient then
                            synced[src] = true
                            Inventory.syncToClient(src, owner)
                        end
                    end
                end

                -- Activity log: one "moved" row per character touched (one when neither end is a character),
                -- against the item's uid, saying who asked. The destination slot now holds what moved.
                local live = to.kind.get(to.handle, toSlot)
                if type(live) == 'table' and live.item then
                    local detail = ('%s · %s to %s'):format(why, Log.storeLabel(from), Log.storeLabel(to))
                    local logged = {}
                    for _, store in ipairs({ from, to }) do
                        local owner = store.kind.id == 'player' and store.handle and store.handle.player
                        local charId = owner and owner.charId or false
                        ---@cast charId any   -- false (no owner) is a key here too
                        if not logged[charId] then
                            logged[charId] = true
                            -- The live slot, so a first row mints the uid onto the real item.
                            Log.item(charId or nil, 'moved', live, { amount = live.amount, detail = detail })
                        end
                    end
                end
            end,
        }
    )

    -- `false` plus a reason, or `true` (a 'handled' verdict counts as success).
    return ok, moveErr
end

exports('StoreMove', function(fromAddr, toAddr, opts)
    -- Who asked, for the log: read before anything can yield.
    local askedBy = Log.byCaller() or 'by whip_core'
    -- The options a resource may give; `source` is whip_core's own (see Stores.moveByAddress).
    if type(opts) == 'table' then
        opts = { amount = opts.amount, mode = opts.mode, reason = opts.reason }
    end
    return Stores.moveByAddress(fromAddr, toAddr, opts, askedBy)
end)

-- beforeMove: a kind may reject a move or perform it itself ('handled'). It runs before anything is mutated (a
-- veto needs no rollback) and outside any store operation (a hook may call back into the inventory exports).

--- The address of a store: the `{ kind, id, sub, slot }` shape Stores.fromAddr reads, plus a `label`. Handed to
--- other resources in place of the store (a handle holds the live player and cache).
---
---   player      id = server id, sub = 'player' | 'accessory'
---   container   id = container id
---   vehicle     id = vehicle id, sub = 'trunk' | 'glovebox' | 'key'
---   panel       id = the panel's id, owner = the player's server id
---   basket      id = the player's server id
---   shop        id = shop id
---   rawInventory  id = charId, sub = container (an admin's view of a character)
---   anything else  id / sub from the key it was opened with
---@param store table
---@param slot number|nil
---@return table|nil addr
function Stores.addressOf(store, slot)
    if type(store) ~= 'table' or type(store.kind) ~= 'table' then return nil end
    local kindId, h, key = store.kind.id, store.handle or {}, store.key
    local addr = { kind = kindId, slot = slot, label = store.label }

    if kindId == 'player' then
        addr.id, addr.sub = h.player and h.player.source, h.container
    elseif kindId == 'rawInventory' then
        addr.id, addr.sub = h.charId, h.container
    elseif kindId == 'container' then
        addr.id = h.containerId
    elseif kindId == 'vehicle' then
        addr.id, addr.sub = h.vehicleId, h.storageType
    elseif kindId == 'panel' then
        addr.id, addr.owner = h.session and h.session.id, h.source
    elseif kindId == 'basket' then
        addr.id = h.source
    elseif kindId == 'shop' then
        addr.id = h.shopId
    elseif type(key) == 'table' then
        addr.id, addr.sub = key.id, key.sub
    else
        addr.id = key
    end
    return addr
end

--- A hook's `ctx` made fit to hand to another resource: `other` becomes an address and the internal `detail` is
--- left out.
---@param ctx table
---@return table
function Stores.hookCtxForSatellite(ctx)
    local out = {}
    for k, v in pairs(ctx) do out[k] = v end
    out.other = ctx.other and Stores.addressOf(ctx.other, ctx.otherSlot) or nil
    out.detail = nil
    return out
end

--- The table every panel hook (onValidate, onChange) is handed:
---   source      the player whose move it is
---   panel       the panel's id
---   host        a RegisterPanelItem panel's item: { source, container, slot, addr, item, amount, metadata }
---   direction   'in' (into the panel) | 'out' | 'within'
---   slot        the panel's slot;  otherSlot / other: the other end, `other` as an address
---   item, amount, metadata   what is moving;  swap: true for the returning half of a swap;
---                            replacing: { item, amount, metadata } on the forward half, what leaves as this arrives
---   items       onChange only: what the panel holds now (a copy)
---@param ctx table  the move's hook ctx (Stores.beforeMove / afterMove)
---@param h table    the panel store's handle { source, session }
---@param host table|nil
---@return table
function Stores.panelHookCtx(ctx, h, host)
    local out = Stores.hookCtxForSatellite(ctx)
    out.source = ctx.source or h.source
    out.panel  = h.session and h.session.id
    out.host   = host
    return out
end

--- The client-facing name for a store.
---@param store table
---@return string
function Stores.wireName(store)
    local kindId = store.kind.id
    if kindId == 'player' or kindId == 'rawInventory' then
        return store.handle.container            -- 'player' | 'accessory'
    elseif kindId == 'container' or kindId == 'vehicle' then
        return 'container'                       -- both present as the same UI panel
    end
    return kindId
end

--- Ask one store whether its end of a move may happen (its kind's beforeMove, run safely). A destroy asks too:
--- a side with no `other`, direction 'out', `destroyed = true`.
---@param side table  { addr = {store, slot}, other = {store, slot}|nil, direction, destroyed? }
---@param detail table|nil  { item, amount, metadata, swap }
---@return string verdict  'ok' | 'reject' | 'handled'
---@return string|nil reason
local function askSide(side, detail)
    local kind = side.addr.store.kind
    if not kind.beforeMove then return 'ok' end

    -- pcall's flag, the verdict, and an optional reason ("Incompatible magazine") for the player.
    local other = side.other
    local ctx = {
        direction  = side.direction,
        slot       = side.addr.slot,
        otherSlot  = other and other.slot,
        other      = other and other.store,
        otherName  = other and Stores.wireName(other.store),
        item       = detail and detail.item,
        amount     = detail and detail.amount,
        metadata   = detail and detail.metadata,
        -- True for the returning half of a swap: the slot's current occupant is leaving, so a hook counting
        -- what is already there should not count it.
        swap       = detail and detail.swap or nil,
        -- Forward half of a swap: what sits at the destination now and goes back the other way; nil if none.
        replacing  = detail and detail.replacing or nil,
        -- true when a player is DESTROYING the item: it is leaving ('out') and going nowhere.
        destroyed  = side.destroyed or nil,
    }
    -- A satellite's kind gets `other` as an address, not the store.
    if StoreKindOwners[kind.id] then ctx = Stores.hookCtxForSatellite(ctx) end
    local ok, result, hookReason = pcall(kind.beforeMove, side.addr.store.handle, ctx)
    if not ok then
        -- Fails closed: beforeMove is a veto, and a hook that errors has not approved anything. Treating silence
        -- as approval would turn a satellite's bug into an unnoticed exploit; a blocked slot gets fixed.
        -- `result` is usually nil: the error is printed in the owning resource and this pcall only learns it failed.
        local DIRECTION_WORD = { ['in'] = 'incoming', out = 'outgoing', within = 'internal' }
        print(('[whip_core:stores] beforeMove hook on kind "%s" errored during an %s ' ..
               'move — the move was REJECTED. Stack trace is in the owning ' ..
               'resource\'s output. (%s)')
            :format(kind.id, DIRECTION_WORD[side.direction] or side.direction,
                    result and tostring(result) or 'no message across resource boundary'))
        return 'reject', ('The %s could not verify this move'):format(kind.id)
    elseif result == false then
        return 'reject', hookReason or 'Move rejected'
    elseif result == 'handled' then
        return 'handled'
    end
    return 'ok'
end

--- Ask both ends whether a move may proceed. Returns:
---   'ok'        nothing objected: perform the move
---   'reject'    a kind vetoed it, with a reason
---   'handled'   a kind performed the move itself: do not move, do not revert
---@param from table  {store, slot}
---@param to table    {store, slot}
---@param detail table  { item, amount, metadata }
---@return string verdict
---@return string|nil reason
function Stores.beforeMove(from, to, detail)
    -- Containment first, ahead of the hooks, so no kind can approve, handle or error past it.
    local containment = Stores.selfContainment(from, to, detail)
    if containment then return 'reject', containment end

    -- A move within one store is ONE event, so a kind can't double-count a rearrangement.
    local sides
    if sameStore(from.store, to.store) then
        sides = { { addr = from, other = to, direction = 'within' } }
    else
        sides = {
            { addr = from, other = to,   direction = 'out' },
            { addr = to,   other = from, direction = 'in'  },
        }
    end

    for _, side in ipairs(sides) do
        local verdict, reason = askSide(side, detail)
        if verdict ~= 'ok' then return verdict, reason end
    end

    return 'ok'
end

-- Write accounting: each save builder reports what it wrote and what a full rewrite would have written, for
-- /whip_writes (a ratio back at 1.0 means the diff broke).
Stores.writeStats = {
    saves       = 0,   -- builds that produced at least one query
    noopSaves   = 0,   -- builds that produced nothing because nothing had changed
    rowsWritten = 0,   -- rows actually sent
    rowsIfFull  = 0,   -- rows a full rewrite would have sent
}

--- Record one save's cost.
---@param written number  rows this build emitted
---@param ifFull number   rows a full rewrite of the same store would have emitted
function Stores.recordWrite(written, ifFull)
    local s = Stores.writeStats
    if written > 0 then s.saves = s.saves + 1 else s.noopSaves = s.noopSaves + 1 end
    s.rowsWritten = s.rowsWritten + written
    s.rowsIfFull  = s.rowsIfFull + ifFull
end

-- No rollback after a commit fails: it would be an absolute write after a database yield, overwriting what other
-- viewers did meanwhile. A failed commit leaves the units owed: Stores.saveAll marks them dirty and the flush
-- thread retries with backoff. Memory is authoritative. Ground pickups delete the row first, so a failure is an
-- item owed to a pocket, never in two places.

--- Tell one store its end of a move (or a destroy) landed (its kind's afterMove, errors contained). Same `side`
--- shape as askSide.
---@param side table  { addr = {store, slot}, other = {store, slot}|nil, direction, destroyed? }
---@param detail table|nil
local function tellSide(side, detail)
    local kind = side.addr.store.kind
    if not kind.afterMove then return end
    local other = side.other
    local ctx = {
        direction = side.direction,
        slot      = side.addr.slot,
        otherSlot = other and other.slot,
        other     = other and other.store,
        otherName = other and Stores.wireName(other.store),
        item      = detail and detail.item,
        amount    = detail and detail.amount,
        metadata  = detail and detail.metadata,
        source    = detail and detail.source,
        destroyed = side.destroyed or nil,
        -- The move's own payload, by reference: the panel fold reads and sets `detail.replied`.
        detail    = detail,
    }
    -- A satellite's kind gets `other` as an address, and not the payload.
    if StoreKindOwners[kind.id] then ctx = Stores.hookCtxForSatellite(ctx) end
    local ok, err = pcall(kind.afterMove, side.addr.store.handle, ctx)
    if not ok then
        print(('[whip_core:stores] afterMove hook on kind "%s" errored: %s')
            :format(kind.id, tostring(err)))
    end
end

--- Tell both ends a move completed, after it is committed. Errors are contained: a broken hook must not make a
--- successful move look failed.
---@param from table  {store, slot}
---@param to table    {store, slot}
---@param detail table|nil
function Stores.afterMove(from, to, detail)
    local sides
    if sameStore(from.store, to.store) then
        sides = { { addr = from, other = to, direction = 'within' } }
    else
        sides = {
            { addr = from, other = to,   direction = 'out' },
            { addr = to,   other = from, direction = 'in'  },
        }
    end

    for _, side in ipairs(sides) do tellSide(side, detail) end
end

-- The committed move: the NUI handler (server/events_inventory.lua) and the StoreMove export both use it. Uid
-- stamping, activity-log rows and client sync for a player's own move stay with the NUI handler.
-- Order is the contract: save, then onCommitted (the caller's sync), then afterMove side effects.

--- unit -> its holds. A hold stops a drag carrying cash off while the ATM waits on a debit. Stores.commitMove,
--- drops, throws and pickups refuse while held; Stores.take and the other take primitives do not ask, so a new
--- path that takes from pockets after a wait must check Stores.isFrozen itself. The lapse is a backstop.
--- One hold per holder: racing withdrawals each let go of only their own.
Stores._frozen = {}   -- unit -> { [token] = when it lapses }
local FREEZE_MAX_MS = 660000

--- Hold this unit still. Answers the token that lets go of this hold (Stores.unfreeze).
---@param unit string
---@return table token
function Stores.freeze(unit)
    local token = { unit = unit }
    local holds = Stores._frozen[unit]
    if not holds then holds = {}; Stores._frozen[unit] = holds end
    holds[token] = GetGameTimer() + FREEZE_MAX_MS
    return token
end

---@param token table|nil  what Stores.freeze answered
function Stores.unfreeze(token)
    local holds = token and Stores._frozen[token.unit]
    if not (token and holds) then return end
    holds[token] = nil
    if next(holds) == nil then Stores._frozen[token.unit] = nil end
end

--- Is any hold on this unit still live? (A lapsed one is let go here.)
---@param unit string|nil
---@return boolean
function Stores.isFrozen(unit)
    local holds = unit ~= nil and Stores._frozen[unit]
    if not (unit and holds) then return false end
    local now, live = GetGameTimer(), false
    for token, lapses in pairs(holds) do
        if now < lapses then live = true else holds[token] = nil end
    end
    if not live then Stores._frozen[unit] = nil end
    return live
end

--- Move a stack between two stores, completely: hooks, the move itself, persistence, hooks again.
---
---@param from table  { store, slot }
---@param to table    { store, slot }
---@param opts table|nil
---   opts.mode        'move' (whole slot, default) | 'one' | 'split'
---   opts.amount      how many, for 'split' and for a partial 'move'. 0 means the whole slot.
---   opts.detail      the hook payload { item, amount, metadata, source }; built from the source slot when omitted
---   opts.onCommitted fun(from, to, detail): run after the move is durable and before afterMove
---@return boolean ok
---@return string|nil err
---@return string|nil verdict  'handled' when a kind performed the move itself; nothing else ran
function Stores.commitMove(from, to, opts)
    opts = opts or {}

    if not from or not from.store or not to or not to.store then
        return false, 'move needs two stores'
    end
    if Stores.isFrozen(from.store.unit) or Stores.isFrozen(to.store.unit) then
        return false, 'Paying — wait a moment'   -- see Stores.freeze
    end

    local mode   = opts.mode or 'move'
    local amount = tonumber(opts.amount) or 0

    local detail = opts.detail
    if not detail then
        local fromData = from.store.kind.get(from.store.handle, from.slot)
        detail = {
            item     = fromData and fromData.item,
            -- The hooks are asked about what actually moves: one unit, or the stack for an amount above it.
            amount   = (mode == 'one' and fromData) and 1
                       or ((amount > 0 and fromData) and math.min(amount, fromData.amount))
                       or (fromData and fromData.amount),
            metadata = fromData and fromData.metadata,
            source   = opts.source,
        }
    end

    -- The destination as the hooks will see it, for the recheck after them.
    local toBefore = to.store.kind.get(to.store.handle, to.slot)

    -- What kind of move this is, worked out before the hooks are asked. Whole-slot means any move that can reach
    -- Stores.move (it can swap); 'one' never swaps.
    local fromNow = from.store.kind.get(from.store.handle, from.slot)
    local wholeSlot = mode ~= 'one'
        and (amount <= 0 or (fromNow ~= nil and amount >= fromNow.amount))
    local onItself = sameStore(from.store, to.store) and from.slot == to.slot
    local occupant   -- what a whole-slot move onto a different item swaps back out
    if wholeSlot and fromNow and toBefore and not onItself then
        local def = itemDef(fromNow.item)
        local merges = toBefore.item == fromNow.item
            and def and def.stack and def.maxStack and def.maxStack > 1
            and stacksWith(fromNow.metadata, toBefore.metadata)
            and toBefore.amount < def.maxStack
        if not merges then
            occupant = toBefore
        elseif def and detail.amount and fromNow.amount + toBefore.amount > def.maxStack then
            -- A merge moves what fits, and the hooks and log are told that.
            detail.amount = math.min(detail.amount, def.maxStack - toBefore.amount)
        end
    end

    -- The forward half of a swap knows it is one: `replacing` is what is there now and will leave
    -- as this arrives (a new magazine replacing the fitted one, not a second beside it).
    if occupant then
        detail.replacing = { item = occupant.item, amount = occupant.amount, metadata = occupant.metadata }
    end

    -- Ask both ends before touching anything.
    local verdict, vetoReason = Stores.beforeMove(from, to, detail)
    if verdict == 'reject' then
        return false, vetoReason or 'Move rejected'
    elseif verdict == 'handled' then
        -- The hook did the move itself. Do NOT move, and do NOT revert.
        return true, nil, 'handled'
    end

    -- The returning half of a swap is a move too and is asked (flagged `swap`), or a hook-guarded slot could be
    -- filled by swapping. Anything but 'ok' refuses; a hook can't handle half a swap. Applies inside one store too.
    if occupant then
        local backVerdict, backReason = Stores.beforeMove(
            { store = to.store,   slot = to.slot },
            { store = from.store, slot = from.slot },
            { item = occupant.item, amount = occupant.amount, metadata = occupant.metadata,
              source = detail and detail.source, swap = true })
        if backVerdict ~= 'ok' then
            return false, backReason or 'That item does not go there'
        end
    end

    -- The source must still be what the hooks were asked about (a hook may yield). Item and metadata are
    -- compared, not the amount, which the movers read live. A synthetic kind compares the item only.
    if detail.item then
        local fromCheck = from.store.kind.get(from.store.handle, from.slot)
        if not fromCheck or fromCheck.item ~= detail.item
            or (not from.store.kind.synthetic and not stacksWith(fromCheck.metadata, detail.metadata)) then
            return false, 'That changed while it was being checked. Try again.'
        end
    end

    -- Same for the destination: its amount may change (the movers check the stack cap); what it holds may not.
    local toAfter = to.store.kind.get(to.store.handle, to.slot)
    local toChanged
    if (toBefore == nil) ~= (toAfter == nil) then
        toChanged = true
    elseif toBefore and toAfter then
        toChanged = toBefore.item ~= toAfter.item
            or (not to.store.kind.synthetic and not stacksWith(toBefore.metadata, toAfter.metadata))
    end
    if toChanged then
        return false, 'That changed while it was being checked. Try again.'
    end

    -- And a panel's item is still there: a waiting hook gave the bag time to be dropped or handed
    -- over, and the move would land in a panel with no host.
    for _, s in ipairs({ from.store, to.store }) do
        local session = s.kind.id == 'panel' and s.handle and s.handle.session
        if session and session.host and not Panels.resolveHost(s.handle.source, session) then
            return false, 'That item is no longer there'
        end
    end

    local ok, err
    if mode == 'one' then
        ok, err = Stores.moveOne(from.store, from.slot, to.store, to.slot)
    else
        if mode == 'split' and amount < 1 then return false, 'Split needs an amount' end
        -- Never more than the hooks approved, whatever the client sent.
        local n = amount > 0 and amount or nil
        if detail.amount and (n == nil or n > detail.amount) then n = detail.amount end
        local live = from.store.kind.get(from.store.handle, from.slot)
        if n and live and not from.store.kind.synthetic and live.amount > n then
            ok, err = Stores.moveAmount(from.store, from.slot, to.store, to.slot, n)
        elseif amount > 0 then
            ok, err = Stores.moveAmount(from.store, from.slot, to.store, to.slot, amount)
        else
            ok, err = Stores.move(from.store, from.slot, to.store, to.slot)
        end
    end

    if not ok then
        return false, err or 'Move failed'
    end

    -- A failed write is not a failed move: saveAll leaves the participants dirty and linked, and
    -- the flush thread retries (quarantine shouts if it never lands). The move stands.
    local saved, saveErr = Stores.saveAll({ from.store, to.store })
    if not saved then
        print(('[whip_core:stores] move persisted late for %s -> %s: %s')
            :format(tostring(from.store.unit), tostring(to.store.unit), tostring(saveErr)))
    end

    if opts.onCommitted then opts.onCommitted(from, to, detail) end

    -- Side effects last, and only once the move is durable.
    Stores.afterMove(from, to, detail)

    return true
end

--- Destroy the stack at an address (a player's "Destroy"): commitMove's one-sided sibling. The store's beforeMove
--- (direction 'out', `destroyed = true`, no `other`), the take, persistence, then afterMove. Stores.take is the
--- trusted resource path with nothing to ask. Never a shop shelf, a basket or the ignition.
---@param at table  { store, slot }
---@param opts table|nil
---   opts.detail      the hook payload { item, amount, metadata, source, awaitsReply, replied }; built from the slot when omitted
---   opts.source      the player, when opts.detail is omitted
---   opts.onCommitted fun(at, detail): after the destroy is durable and before the store is told
---@return boolean ok
---@return string|nil err
---@return table|nil removed  { item, amount, metadata }
---@return string|nil verdict  'handled' when a kind did it itself; nothing else ran
function Stores.commitDestroy(at, opts)
    opts = opts or {}
    if not at or not at.store or not at.slot then return false, 'destroy needs an address' end
    local store, slot = at.store, at.slot
    local kindId = store.kind.id

    if kindId == 'shop' or kindId == 'basket' then
        return false, 'That is not yours to destroy'
    end
    if kindId == 'vehicle' and store.handle.storageType == 'key' then
        return false, 'Take the key out first'
    end
    -- Destroying in someone else's pockets is the admin tool's alone (not a robbery's inspect session).
    if kindId == 'rawInventory' then
        local who = opts.source or (opts.detail and opts.detail.source)
        local sess = who and Inventory.playerInvSession(who)
        if not (sess and sess.admin) then return false, 'That is not yours to destroy' end
    end
    if slot < 1 or slot > store.kind.slots(store.handle) then return false, 'Invalid slot number' end

    local live = store.kind.get(store.handle, slot)
    if not live or not live.item or (live.amount or 0) < 1 then return false, 'No item in that slot' end

    local detail = opts.detail or {
        item = live.item, amount = live.amount, metadata = live.metadata, source = opts.source,
    }

    local side = { addr = at, direction = 'out', destroyed = true }
    local verdict, reason = askSide(side, detail)
    if verdict == 'reject' then
        return false, reason or 'You cannot destroy that'
    elseif verdict == 'handled' then
        return true, nil, nil, 'handled'
    end

    -- The slot is still what the hook was asked about (commitMove's re-read): a hook may wait,
    -- and a shared store can change meanwhile.
    local now = store.kind.get(store.handle, slot)
    if not now or now.item ~= detail.item
        or (not store.kind.synthetic and not stacksWith(now.metadata, detail.metadata)) then
        return false, 'That changed while it was being checked. Try again.'
    end
    -- And a panel's item is still there (as commitMove asks): a bag handed over during the wait left
    -- only the session copy to destroy, while the bag kept the item and the log said 'destroyed'.
    local session = store.kind.id == 'panel' and store.handle and store.handle.session
    if session and session.host and not Panels.resolveHost(store.handle.source, session) then
        return false, 'That item is no longer there'
    end

    -- No more than the hook approved: a stack that grew in the wait keeps what it gained.
    local amount = math.min(now.amount or 1, tonumber(detail.amount) or now.amount or 1)
    local ok, err, removed = Stores.take(store, slot, amount)
    if not ok then return false, err end

    -- A failed write is not a failed destroy — see the same note in commitMove.
    local saved, saveErr = Stores.saveAll({ store })
    if not saved then
        print(('[whip_core:stores] destroy persisted late for %s: %s')
            :format(tostring(store.unit), tostring(saveErr)))
    end

    if opts.onCommitted then opts.onCommitted(at, detail) end
    tellSide(side, detail)
    return true, nil, removed
end

--- unit -> { [entry] = true }: held payments waiting with the saves they pay for. If an action's write fails the
--- payment stays attached and goes in whichever transaction writes any of those units next. A refund lets it go
--- (Stores.cancelCarried).
Stores._carriedBy = {}

--- The held payments waiting on any of these units, once each; not one a write already carries (`inFlight`).
---@param units table  [unit] = true
---@return table[] entries
local function carriedFor(units)
    local out, seen = {}, {}
    for unit in pairs(units) do
        for entry in pairs(Stores._carriedBy[unit] or {}) do
            if not seen[entry] and not entry.inFlight then
                seen[entry] = true
                out[#out + 1] = entry
            end
        end
    end
    return out
end

--- Attach held payments to the stores whose saves they pay for.
---@param entries table[]
---@param stores table[]
local function attachCarried(entries, stores)
    for _, e in ipairs(entries) do
        e.waitingOn = e.waitingOn or {}
        for _, s in ipairs(stores) do
            e.waitingOn[s.unit] = true
            local set = Stores._carriedBy[s.unit]
            if not set then set = {}; Stores._carriedBy[s.unit] = set end
            set[e] = true
        end
    end
end

--- A payment held by a running action that holds any of these units goes with them, so a forced write can't land
--- the goods ahead of it.
---@param units table  [unit] = true
local function attachRunningCarries(units)
    for unit in pairs(units) do
        for rec in pairs(Stores._heldBy[unit] or {}) do
            local left = rec.carry
            if left and #left > 0 then
                rec.carry = nil
                local stores = {}
                for _, s in pairs(rec.units or {}) do stores[#stores + 1] = s end
                attachCarried(left, stores)
            end
        end
    end
end

---@param entry table
local function detachCarried(entry)
    for unit in pairs(entry.waitingOn or {}) do
        local set = Stores._carriedBy[unit]
        if set then
            set[entry] = nil
            if next(set) == nil then Stores._carriedBy[unit] = nil end
        end
    end
    entry.waitingOn = nil
end

--- Which payments a failed write carried can never land: per account, the carried debits against the balance now;
--- while they add up to more, the newest goes. A failed read decides nothing. Waits.
---@param carried table[]
---@return table refused  [entry] = true
local function refusedOf(carried)
    local refused, byAccount, order = {}, {}, {}
    for _, e in ipairs(carried) do
        if not e.dropAfter and e.debit then
            local okDebit, acct, amount = pcall(e.debit)
            if okDebit and acct ~= nil and type(amount) == 'number' then
                local g = byAccount[acct]
                if not g then g = { list = {}, balance = e.balance }; byAccount[acct] = g; order[#order + 1] = acct end
                g.list[#g.list + 1] = { e = e, amount = amount }
            end
        end
    end
    for _, acct in ipairs(order) do
        local g = byAccount[acct]
        local okRead, balance = pcall(g.balance, acct)
        if okRead and type(balance) == 'number' then
            local total = 0
            for _, x in ipairs(g.list) do total = total + x.amount end
            table.sort(g.list, function(a, b) return (a.e.seq or 0) > (b.e.seq or 0) end)   -- newest first
            for _, x in ipairs(g.list) do
                if total <= balance then break end
                refused[x.e] = true
                total = total - x.amount
            end
        end
    end
    return refused
end

--- Answer the waiting payments a write carried. Landed: answered and let go. Failed: each stays attached for the
--- retry, unless its unit was forgotten meanwhile (dropAfter) or it can never land (refusedOf): then the goods are
--- kept and the player's timeline says it went unpaid. In flight until decided; nothing may carry or cancel them.
---@param carried table[]
---@param ok boolean
---@param err string|nil
local function settleCarried(carried, ok, err)
    local refused = (not ok) and refusedOf(carried) or {}
    for _, e in ipairs(carried) do e.inFlight = nil end
    for _, e in ipairs(carried) do
        local answered, why = true, nil
        if ok then
            detachCarried(e)
            answered, why = pcall(e.landed)
        elseif e.dropAfter or refused[e] then
            detachCarried(e)
            answered, why = pcall(e.failed, err, not e.dropAfter)   -- goodsKept unless forgotten
        end
        if not answered then print(('[whip_core:stores] a held write\'s answer raised: %s'):format(tostring(why))) end
    end
end

--- For a write made outside Stores.commit (Inventory.save's direct path): the payments waiting on this unit, as
--- queries to send with it (marked in flight), and the function to call with how it went.
---@param unit string
---@return table[] queries
---@return fun(ok: boolean, err: string|nil) settle
function Stores.carriedQueriesFor(unit)
    local carried = carriedFor({ [unit] = true })
    local queries = {}
    for _, e in ipairs(carried) do
        e.inFlight = true
        for _, q in ipairs(e.queries) do queries[#queries + 1] = q end
    end
    return queries, function(ok, err) settleCarried(carried, ok, err) end
end

--- Persist every store that changed in one transaction, so a crash can't leave an item in both places.
--- Deduplicates by unit (a player -> accessory move is two stores, one unit).
---@param stores table[]  the stores that were mutated
---@return boolean ok
---@return string|nil err
---@param faultMode string|nil  passed through to runTransaction
---@param extra table[]|nil  queries that are not a unit's (a bank write), sent last in the same transaction
function Stores.commit(stores, faultMode, extra)
    -- A unit written alone uses its kind's fault name (vehicle_data…), which whip_test arms.
    if faultMode == nil and #stores == 1 and stores[1].kind.faultMode then
        faultMode = stores[1].kind.faultMode
    end
    local seen, queries, confirms = {}, {}, {}

    for _, store in ipairs(stores) do
        local kind, handle = store.kind, store.handle
        if kind.persist then
            local unit = store.unit
            if not seen[unit] then
                seen[unit] = true
                -- persist may also return a confirm callback, run once the transaction commits. Building can
                -- raise (json.encode on malformed metadata), so it is pcalled: one poisoned unit fails alone.
                local built, unitQueries, confirm = pcall(kind.persist, handle)
                if not built then
                    return false, ('persist raised for %s: %s'):format(tostring(unit), tostring(unitQueries))
                end
                -- nil means "cannot persist right now" and must not read as success.
                -- An empty table means "legitimately nothing to write" and is fine.
                if unitQueries == nil then
                    return false, ('cannot persist %s'):format(tostring(unit))
                end
                if confirm then confirms[#confirms + 1] = confirm end
                for _, q in ipairs(unitQueries) do
                    queries[#queries + 1] = q
                end
            end
        end
    end
    -- A held payment waiting on any of these units goes in this transaction, and so does one a
    -- running action holds with them.
    attachRunningCarries(seen)
    local carried = carriedFor(seen)
    for _, e in ipairs(carried) do
        for _, q in ipairs(e.queries) do queries[#queries + 1] = q end
    end
    for _, q in ipairs(extra or {}) do queries[#queries + 1] = q end

    -- Nothing changed: the confirms still run (they promote a snapshot that already matches).
    if #queries == 0 then
        for _, confirm in ipairs(confirms) do confirm() end
        return true
    end

    -- In flight while the write is out: no other write carries it (carriedFor), and a refund waits
    -- for this answer (Money.refund). Cleared whatever happens, so the call is pcalled.
    for _, e in ipairs(carried) do e.inFlight = true end
    local called, ok, err = pcall(Stores.runTransaction, queries, faultMode)
    if not called then ok, err = false, tostring(ok) end

    if not ok then
        settleCarried(carried, false, err)   -- a waiting payment stays attached for the retry, mostly
        return false, err
    end

    for _, confirm in ipairs(confirms) do confirm() end
    settleCarried(carried, true)
    return true
end

--- Stores.commit for a claimed batch: a raise counts as a failure, so the caller always releases the
--- claim (or the units stay claimed and their character locked out).
---@return boolean ok, string|nil err
local function safeCommit(batch, faultMode, extra)
    local okCall, ok, err = pcall(Stores.commit, batch, faultMode, extra)
    if not okCall then return false, ('commit raised: %s'):format(tostring(ok)) end
    return ok, err
end

-- Write-behind scheduling: Stores.commit turns a set of stores into one transaction; this decides when. A write's
-- cost is the commit fsync, not the row, so deferring scales persistence with players online rather than with
-- how often they act, and deduplicates (333 changes to one ammo slot write one row). Durability is per kind.

--- unit -> store, for every unit holding changes not yet on disk. Keyed by `unit`, not store id: a character's
--- containers share one unit.
Stores._dirty = {}

--- unit -> when it started waiting (GetGameTimer), for units whose kind has `every` only. Restarted
--- when a commit claims the unit, so a change made during that write waits its own `every`.
Stores._dirtySince = {}

--- unit -> { fails, retryAt } for units whose flush keeps failing.
Stores._quarantine = {}

-- Transaction groups: a move between two deferred stores puts both units in one transaction, so a trade can't
-- half-persist. A failed batch is retried by group, never unit by unit (an isolated retry would commit one side).
-- Merging is transitive: A -> B then B -> C in one window lands all three together. A group lives until its units commit.

--- Units with a commit in flight, from when their queries are built until the transaction finishes.
--- Inventory.buildSaveQueries diffs against the last confirmed snapshot, so a second build during a commit would
--- diff against a stale one and never emit "delete B" for an item moved A -> B -> C, leaving a duplicate.
--- So one commit per unit at a time; a unit in flight stays dirty and goes on the next pass.
Stores._inflight = {}

--- unit -> group id, for units that must be written in one transaction with others.
Stores._linked = {}

--- group id -> { [unit] = store }. The reverse of _linked, so a flush can expand a unit to its whole group.
--- It holds the store: a unit that left _dirty is reachable only from here, and without it a later change to its
--- partner would persist half a transfer. A failing unit keeps retrying until an admin drops its group with
--- /whipsaves drop.
Stores._groups = {}

local _groupSeq = 0

--- Every unit that must be written in the same transaction as this one, including itself.
--- Values are a store or `true` (an ungrouped unit has no store): callers must type-check them.
---@param unit string
---@return table members  unit -> store|true, always containing at least `unit`
local function groupOf(unit)
    local gid = Stores._linked[unit]
    if not gid then return { [unit] = true } end
    return Stores._groups[gid] or { [unit] = true }
end

--- Declare that these units must land together until they commit. Merges into an existing group when any member
--- already belongs to one.
---@param stores table  array of store tables
local function linkUnits(stores)
    -- Deduped first: a player -> accessory move is two stores sharing one unit.
    local seen, units, byUnit = {}, {}, {}
    for _, s in ipairs(stores) do
        -- A hosted panel (a wallet, a bag) has no unit of its own: its contents are the host item's
        -- metadata, in the owner's pockets. So it is linked as those pockets.
        if s and s.kind and s.kind.id == 'panel' and s.handle and s.handle.session
            and s.handle.session.host ~= nil then
            s = Stores.player(s.handle.source, 'player') or s
        end
        local u = s and s.unit
        if u and s.kind and s.kind.persist and not seen[u] then
            seen[u] = true
            units[#units + 1] = u
            byUnit[u] = s
        end
    end

    -- Nothing to keep together: one unit writes atomically by itself.
    if #units < 2 then return end

    -- Reuse a group already in play rather than minting an id per move.
    local gid
    for _, u in ipairs(units) do
        gid = Stores._linked[u]
        if gid then break end
    end

    if not gid then
        _groupSeq = _groupSeq + 1
        gid = _groupSeq
        Stores._groups[gid] = {}
    end

    local target = Stores._groups[gid]

    for _, u in ipairs(units) do
        local existing = Stores._linked[u]
        if existing and existing ~= gid then
            -- This unit was in a different group: fold that group in whole and drop it.
            local other = Stores._groups[existing]
            if other then
                for ou, ostore in pairs(other) do
                    target[ou] = ostore
                    Stores._linked[ou] = gid
                end
                Stores._groups[existing] = nil
            end
        end
        -- Keep the freshest handle: a stale one may point at something a teardown released.
        target[u] = byUnit[u]
        Stores._linked[u] = gid
    end
end

-- One player action, one save: every unit saved while a SecureEvent / SecureCallback handler runs is tied to that
-- action (secure.lua, Actions), linked with everything else it saved and held from the background flush until the
-- action ends (HOLD_MAX_MS at most). Forced saves (settle, teardown, the final save) ignore the hold.

--- unit -> { [action record] = true } while running actions hold it. Weak keys.
Stores._heldBy = {}

--- unit -> GetGameTimer() when an action first held it since its last write. Past HOLD_MAX_MS from this a group
--- is written anyway, so a group that keeps gaining members can't be put off for good.
Stores._heldSince = {}

local HOLD_MAX_MS = 30000

--- True while Stores.beforeFlush's steps mark units (runBeforeFlush): those marks belong to no one's
--- action, even when a forced flush runs inside one.
local _marking = false

--- What a store is about, to find its running action (Actions.current): a player for pockets, a car for its boot, stats or data.
---@param store table
---@return number|nil src
---@return number|nil vehicleId
local function storeAbout(store)
    local kind = store.kind
    if kind == Stores._kinds.player then return store.key and store.key.source, nil end
    if kind == Stores._kinds.vehicle then return nil, store.key and store.key.vehicleId end
    if kind == Stores._unitKinds.vehrow or kind == Stores._unitKinds.vehdata then return nil, store.key end
    if kind == Stores._unitKinds.log then return type(store.key) == 'table' and store.key.src or nil, nil end   -- Log.queue
    return nil, nil
end

--- Tie a store to the action(s) the current call belongs to.
---@param store table
local function tieToActions(store)
    if _marking or not Actions or not store or not store.unit or not store.kind.persist then return end
    local recs = Actions.current(storeAbout(store))
    if #recs > 0 and not Stores._heldSince[store.unit] then Stores._heldSince[store.unit] = GetGameTimer() end
    for _, rec in ipairs(recs) do
        rec.units = rec.units or {}
        rec.units[store.unit] = store
        local held = Stores._heldBy[store.unit]
        if not held then
            held = setmetatable({}, { __mode = 'k' })
            Stores._heldBy[store.unit] = held
        end
        held[rec] = true
        local list = {}
        for _, s in pairs(rec.units) do list[#list + 1] = s end
        linkUnits(list)
    end
end

--- Is a running action still holding this unit? `manualOnly`: only a Stores.hold counts (for a group past the cap).
---@param unit string
---@param now number
---@param manualOnly boolean|nil
---@return boolean
local function heldByAction(unit, now, manualOnly)
    local held = Stores._heldBy[unit]
    if not held then return false end
    for rec in pairs(held) do
        if (rec.manual or not manualOnly) and not rec.closed and now - (rec.openedAt or now) < HOLD_MAX_MS then
            return true
        end
    end
    return false
end

--- Is this unit waiting for a running action to end? Log.flush asks, so a view doesn't write an action half done.
---@param unit string
---@return boolean
function Stores.isHeld(unit)
    return heldByAction(unit, GetGameTimer())
end

--- The one action the current call belongs to; nil for none or several (a held payment rides one action's write).
---@param src number|nil        the player the call is about (Actions.current)
---@param vehicleId number|nil  the car it is about
---@return table|nil rec
local function soleAction(src, vehicleId)
    if not Actions or _marking then return nil end
    local recs = Actions.current(src, vehicleId)
    if #recs == 1 then return recs[1] end
    return nil
end

--- Hold `entry` ({ queries, landed = fn, failed = fn(err) }) on the running action: its next write or its end
--- carries it in the same transaction, so a payment lands with what it bought. False outside exactly one action.
--- `src`: the payer, picking their action out of several.
---@param entry table
---@param src number|nil
---@return boolean held
function Stores.carryWithAction(entry, src)
    local rec = soleAction(src)
    if not rec then return false end
    rec.carry = rec.carry or {}
    rec.carry[#rec.carry + 1] = entry
    entry.rec = rec
    return true
end

--- Take a held entry back before a write carried it (a refund of a payment that never landed).
---@param entry table
---@return boolean cancelled
function Stores.cancelCarried(entry)
    -- A write carrying it is out: not cancelled; its answer decides (Money.refund waits for it).
    if entry.inFlight then return false end
    -- Waiting with its saves after a failed write: the saves go on alone.
    if entry.waitingOn then
        detachCarried(entry)
        return true
    end
    local list = entry.rec and entry.rec.carry
    for i, e in ipairs(list or {}) do
        if e == entry then table.remove(list, i) return true end
    end
    return false
end

--- Tell held entries how their write went. Each in its own pcall: one bad callback must not leave
--- the others unanswered.
local function answerCarried(entries, ok, err)
    for _, e in ipairs(entries or {}) do
        local called, why = pcall(ok and e.landed or e.failed, err)
        if not called then print(('[whip_core:stores] a held write\'s answer raised: %s'):format(tostring(why))) end
    end
end

--- Hold a unit back from the background flush, as a running action does (the pump holds the car's row while it
--- pours). Renew it (Stores.renewHold) inside HOLD_MAX_MS or it lets go. Forced writes ignore holds.
---@param unit string
---@return table holder
function Stores.hold(unit)
    -- manual: held past the group cap too (readyToWrite) — the pump's car row, until settle.
    local holder = { openedAt = GetGameTimer(), unit = unit, manual = true }
    local held = Stores._heldBy[unit]
    if not held then
        held = setmetatable({}, { __mode = 'k' })
        Stores._heldBy[unit] = held
    end
    held[holder] = true
    return holder
end

---@param holder table
function Stores.renewHold(holder)
    if holder and not holder.closed then holder.openedAt = GetGameTimer() end
end

---@param holder table
function Stores.unhold(holder)
    if not holder or holder.closed then return end
    holder.closed = true
    local held = Stores._heldBy[holder.unit]
    if held then
        held[holder] = nil
        if next(held) == nil then Stores._heldBy[holder.unit] = nil end
    end
end

--- An action ended (secure.lua closeInvocation): what it saved may be written now. A held payment no write
--- carried is written here, with the action's owed saves. Waits (runs in the handler's coroutine).
---@param rec table
function Stores.releaseAction(rec)
    local left = rec.carry
    rec.carry = nil
    if left and #left > 0 then
        local owed = {}
        for unit, s in pairs(rec.units or {}) do
            if Stores.owes(unit) then owed[#owed + 1] = s end
        end
        if #owed > 0 then
            -- Attached to the owed saves first, so whichever write takes them carries it; a failure leaves it attached.
            attachCarried(left, owed)
            local ok, err = Stores.writeWith(owed, nil, 'bank')
            if not ok then
                print(('[whip_core:stores] a held payment\'s write failed (%s): it waits with the saves it pays for')
                    :format(tostring(err)))
            end
        else
            -- Nothing of the action's owed: the payment alone. A failure took nothing and delivered nothing.
            -- In flight while it is out, so a refund waits for its answer.
            local queries = {}
            for _, e in ipairs(left) do
                e.inFlight = true
                for _, q in ipairs(e.queries) do queries[#queries + 1] = q end
            end
            local called, ok, err = pcall(Stores.runTransaction, queries, 'bank')
            if not called then ok, err = false, tostring(ok) end
            for _, e in ipairs(left) do e.inFlight = nil end
            answerCarried(left, ok, err)
        end
    end
    for unit in pairs(rec.units or {}) do
        local held = Stores._heldBy[unit]
        if held then
            held[rec] = nil
            if next(held) == nil then Stores._heldBy[unit] = nil end
        end
    end
    rec.units = nil
end

--- Forget a unit's group membership, because it has been written or deliberately discarded.
---@param unit string
local function unlinkUnit(unit)
    local gid = Stores._linked[unit]
    if not gid then return end

    Stores._linked[unit] = nil

    local g = Stores._groups[gid]
    if not g then return end

    g[unit] = nil
    if next(g) == nil then Stores._groups[gid] = nil end
end

--- Widen a list of stores to everything their units are tied to: a commit touching a grouped unit takes the whole group.
---@param stores table  array of stores
---@return table  array of stores, deduped by unit, group members folded in
local function expandToGroups(stores)
    local seen, out = {}, {}

    --- Type-checked: group maps hold stores OR groupOf's `true`, and `true.unit` raises on the path
    --- every save takes.
    local function add(s)
        if type(s) ~= 'table' or not s.unit or seen[s.unit] then return end
        seen[s.unit] = true
        out[#out + 1] = s
    end

    for _, s in ipairs(stores) do
        add(s)
        -- Every member, dirty or not: a unit in a group is dirty or abandoned, and skipping it writes its partner alone.
        for u, partner in pairs(groupOf(s.unit)) do
            -- `true` = no handle here (see groupOf); _dirty is the only other place one could be.
            if partner == true then partner = Stores._dirty[u] end
            add(partner)
        end
    end

    return out
end

--- Release units after a successful commit: clear their backoff and grouping, unless they went dirty again during
--- the write (a move mid-write linked them to a newer transaction). Over-keeping a link only batches more;
--- under-keeping one duplicates.
---@param units table  array of unit strings
local function releaseCommitted(units)
    for _, unit in ipairs(units) do
        Stores._quarantine[unit] = nil
        if not Stores._dirty[unit] then unlinkUnit(unit) end
    end
end

--- Claim every unit in a batch for one commit, or refuse the whole batch (it is a transaction): if any member is
--- in flight the caller backs off and the units stay dirty.
---@param units table  array of unit strings
---@return boolean claimed
local function claimInflight(units)
    for _, u in ipairs(units) do
        if Stores._inflight[u] then return false end
    end
    for _, u in ipairs(units) do
        Stores._inflight[u] = true
        Stores._dirtySince[u] = nil   -- this write takes what waited; a change during it waits anew
        Stores._heldSince[u] = nil
    end
    return true
end

---@param units table
local function releaseInflight(units)
    for _, u in ipairs(units) do Stores._inflight[u] = nil end
end

--- Claim one unit for a commit made outside this file (Inventory.save's direct path). Waits, bounded, for a commit
--- already in flight. Pair every claim with Stores.releaseUnit once the commit has answered.
---@param unit string
---@param maxWaitMs number|nil  default 5000
---@return boolean claimed
function Stores.claimUnit(unit, maxWaitMs)
    local waited, limit = 0, maxWaitMs or 5000
    while not claimInflight({ unit }) do
        Wait(25)
        waited = waited + 25
        if waited >= limit then return false end
    end
    return true
end

---@param unit string
function Stores.releaseUnit(unit)
    releaseInflight({ unit })
end

--- After this many failures in a row a unit is stuck: reported to console and admins every minute, retried every
--- MAX_BACKOFF_MS, never dropped. Only /whipsaves drop gives one up.
local MAX_FLUSH_FAILS = 5
local MAX_BACKOFF_MS  = 60000

--- Does this kind defer its writes?
---@param kind table
---@return boolean
local function isDeferred(kind)
    return kind.durability == 'writeBehind'
end

Stores.isDeferred = isDeferred

--- Record that a store has changes not yet on disk. O(1), no I/O: what a mutation path calls instead of saving.
---@param store table|nil
function Stores.markDirty(store)
    if not store or not store.kind.persist then return end
    tieToActions(store)
    if store.kind.every and not Stores._dirtySince[store.unit] then
        Stores._dirtySince[store.unit] = GetGameTimer()
    end
    Stores._dirty[store.unit] = store

    -- Touching one member re-arms the whole group: an abandoned member still owes its half of a move.
    -- Partners go straight into _dirty (no recursion).
    local gid = Stores._linked[store.unit]
    if not gid then return end

    local g = Stores._groups[gid]
    if not g then return end

    for unit, partner in pairs(g) do
        if unit ~= store.unit and partner and not Stores._dirty[unit] then
            Stores._dirty[unit] = partner
        end
    end
end

--- Stores.flushNow's body, for a list of stores, with `extra` queries (a bank write) in the same
--- transaction when given (Stores.commitWithAction).
---@param stores table[]
---@param extra table[]|nil
---@param faultMode string|nil
---@return boolean ok
---@return string|nil err
local function flushBatch(stores, extra, faultMode)
    -- The whole group (teardown comes through here). One commit per unit at a time, so this waits (bounded) rather
    -- than refusing; the group is re-read after every wait, as a move during it can link a new unit.
    local batch, units
    local waited = 0
    while true do
        batch, units = expandToGroups(stores), {}
        for _, s in ipairs(batch) do units[#units + 1] = s.unit end
        if claimInflight(units) then break end
        Wait(25)
        waited = waited + 25
        if waited >= 5000 then
            -- A unit held far longer than any transaction: leave it owed and say so rather than block a teardown forever.
            for i, u in ipairs(units) do
                if not Stores._dirty[u] then Stores._dirty[u] = batch[i] end
            end
            print(('[whip_core:stores] flushNow gave up waiting for an in-flight commit on %s — left owed for the flush thread')
                :format(table.concat(units, ', ')))
            return false, 'another commit is still in flight'
        end
    end

    -- Cleared first: a mutation during the transaction's yield re-marks the unit for the next pass
    -- (the confirm only advances the snapshot as far as these queries).
    for _, u in ipairs(units) do Stores._dirty[u] = nil end

    local ok, err = safeCommit(batch, faultMode, extra)
    releaseInflight(units)

    if not ok then
        -- Still owed, still linked. The group must survive a failure or the retry could split it.
        for i, u in ipairs(units) do Stores._dirty[u] = batch[i] end
        return false, err
    end

    releaseCommitted(units)
    return true
end

--- Persist one store's unit now, synchronously: for teardown and any move that touches a write-through store.
---@param store table
---@return boolean ok
---@return string|nil err
function Stores.flushNow(store)
    if not store then return false, 'no store' end
    return flushBatch({ store })
end

--- Commit `queries` that belong to no unit (a bank write) in one transaction with everything the current action
--- has saved and not yet written, so an ATM deposit's cash and the account's credit land together or not at all.
--- A failure leaves the action's saves owed and runs none of `queries`. Outside any action, `queries` alone.
--- Also carried: a payment the action holds, and `alsoStores` (units that must land with this write though no
--- action tied them). `src` / `vehicleId` say whose action, among several.
---@param queries table[]|nil
---@param faultMode string|nil
---@param alsoStores table[]|nil
---@param src number|nil
---@param vehicleId number|nil
---@return boolean ok
---@return string|nil err
function Stores.commitWithAction(queries, faultMode, alsoStores, src, vehicleId)
    local stores, seen = {}, {}
    local function add(s)
        if s and s.unit and not seen[s.unit] then seen[s.unit] = true; stores[#stores + 1] = s end
    end
    if Actions and not _marking then
        for _, rec in ipairs(Actions.current(src, vehicleId)) do
            for unit, s in pairs(rec.units or {}) do
                if Stores.owes(unit) then add(s) end
            end
        end
    end
    for _, s in ipairs(alsoStores or {}) do add(s) end

    local rec = soleAction(src, vehicleId)
    local carried = rec and rec.carry
    if carried and #carried > 0 then
        rec.carry = nil
        local all = {}
        for _, q in ipairs(queries or {}) do all[#all + 1] = q end
        for _, e in ipairs(carried) do
            for _, q in ipairs(e.queries) do all[#all + 1] = q end
        end
        queries = all
    else
        carried = nil
    end

    -- In flight while the write is out: a refund waits for its answer (Money.refund).
    for _, e in ipairs(carried or {}) do e.inFlight = true end
    local called, ok, err
    if #stores == 0 then called, ok, err = pcall(Stores.runTransaction, queries, faultMode)
    else called, ok, err = pcall(flushBatch, stores, queries, faultMode) end
    if not called then ok, err = false, tostring(ok) end
    for _, e in ipairs(carried or {}) do e.inFlight = nil end
    answerCarried(carried, ok, err)
    return ok, err
end

--- Your resource's own queries in one transaction with what the player's current action has changed and not yet
--- written, so an item you took and the row you wrote for it land together. Outside an action, the queries alone.
--- `queries`: { { query = 'INSERT ...', values = { ... } }, ... }. `opts.source` (and `opts.vehicleId`) say whose
--- action, when your code runs outside the handler that started it.
exports('CommitWithAction', function(queries, opts)
    if type(queries) ~= 'table' or #queries == 0 then return false, 'queries is a list of { query = "...", values = { ... } }' end
    for i, q in ipairs(queries) do
        if type(q) ~= 'table' or type(q.query) ~= 'string' or q.query == '' then
            return false, ('query %d is { query = "...", values = { ... } }'):format(i)
        end
        if q.values ~= nil and type(q.values) ~= 'table' then return false, ('query %d: values is a list'):format(i) end
    end
    opts = type(opts) == 'table' and opts or {}
    local ok, err = Stores.commitWithAction(queries, nil, nil, tonumber(opts.source), tonumber(opts.vehicleId))
    if not ok then
        print(('[whip_core:stores] CommitWithAction for %s failed: %s'):format(tostring(GetInvokingResource()), tostring(err)))
        return false, DB_ERROR
    end
    return true
end)

--- Write these stores, with `queries`, in one transaction now.
---@param stores table[]
---@param queries table[]|nil
---@param faultMode string|nil
---@return boolean ok
---@return string|nil err
function Stores.writeWith(stores, queries, faultMode)
    return flushBatch(stores, queries, faultMode)
end

--- Mark these units owed and tie them together: the flush writes them in one transaction. Never waits.
---@param stores table[]
function Stores.writeTogether(stores)
    for _, s in ipairs(stores) do Stores.markDirty(s) end
    linkUnits(stores)
end

--- Route one store's save according to its kind's declared durability.
---@param store table|nil
---@return boolean ok
---@return string|nil err
function Stores.save(store)
    if not store then return false, 'no store' end
    if isDeferred(store.kind) then
        Stores.markDirty(store)
        return true
    end
    tieToActions(store)   -- so what its action saved before goes in this write too
    -- A payment the action holds rides this write: car data bought at Whiplash lands with the
    -- money for it.
    local src, vehicleId = storeAbout(store)
    local rec = soleAction(src, vehicleId)
    if rec and rec.carry and #rec.carry > 0 then
        return Stores.commitWithAction(nil, nil, { store }, src, vehicleId)
    end
    return Stores.flushNow(store)
end

--- Route a whole move's stores according to durability. Between two deferred stores a move is deferred (both units
--- in one transaction later); if any participant is write-through the whole move commits immediately.
---@param stores table[]
---@return boolean ok
---@return string|nil err
function Stores.saveAll(stores)
    if not stores or #stores == 0 then return true end
    for _, store in ipairs(stores) do tieToActions(store) end   -- before a write-through commit widens

    for _, store in ipairs(stores) do
        if store.kind.persist and not isDeferred(store.kind) then
            -- The commit takes any group its participants belong to: B may be half of a queued
            -- A -> B when B -> C (write-through) happens, and B must not land without A.

            -- A bag or wallet on the other end: the panel's afterMove folds its contents into the pockets after
            -- this save, so the move goes deferred, linked with the pockets, and the fold's dirty mark sends both.
            for _, s in ipairs(stores) do
                if s.kind.id == 'panel' and s.handle and s.handle.session and s.handle.session.host ~= nil then
                    for _, t in ipairs(stores) do Stores.markDirty(t) end
                    linkUnits(stores)
                    return true
                end
            end

            local batch, units = expandToGroups(stores), {}
            for _, s in ipairs(batch) do units[#units + 1] = s.unit end

            -- A unit already being written (Stores._inflight): hand the move to the deferred
            -- machinery, and the next flush writes it against a current snapshot.
            if not claimInflight(units) then
                for _, s in ipairs(batch) do Stores.markDirty(s) end
                linkUnits(batch)
                return true
            end

            -- Cleared before the yield, re-marked below if it fails (as flushNow).
            for _, u in ipairs(units) do Stores._dirty[u] = nil end

            local ok, err = safeCommit(batch)
            releaseInflight(units)

            if ok then
                releaseCommitted(units)
            end
            if not ok then
                -- The write failed but the move stands: the units are left owed and linked, so the retry writes them together.
                for _, s in ipairs(batch) do
                    Stores.markDirty(s)
                end
                linkUnits(batch)
            end
            return ok, err
        end
    end

    -- All deferred: mark them dirty and link them, so flushAll knows they are one move.
    for _, store in ipairs(stores) do
        Stores.markDirty(store)
    end
    linkUnits(stores)

    return true
end

--- A unit failed to flush on its own. Back off (2, 4, 8 … 60 s) and keep it owed until it lands.
---@param unit string
---@param store table
---@param err string|nil
local function quarantine(unit, store, err)
    local q = Stores._quarantine[unit] or { fails = 0, since = GetGameTimer() }
    q.fails = q.fails + 1
    q.lastErr = tostring(err)

    -- Shift, not 2^n: `^` gives a float in Lua 5.4, and '%d' below throws on one.
    local backoff = math.min(Config.FlushInterval * (1 << math.min(q.fails, 6)), MAX_BACKOFF_MS)
    q.retryAt = GetGameTimer() + backoff
    Stores._quarantine[unit] = q
    Stores._dirty[unit] = store

    if q.fails < MAX_FLUSH_FAILS then
        print(('[whip_core:stores] flush failed for %s (attempt %d), retrying in %dms: %s')
            :format(unit, q.fails, backoff, tostring(err)))
    elseif q.fails == MAX_FLUSH_FAILS then
        print(('^1[whip_core:stores] %s is STUCK after %d failed saves — still owed, retrying every %d s: %s^0')
            :format(unit, q.fails, MAX_BACKOFF_MS // 1000, tostring(err)))
        print('[whip_core:stores]   it lands as soon as the database takes it; /whipsaves lists stuck saves')
    end
end

--- Saves that have failed MAX_FLUSH_FAILS times or more, oldest first — for /whipsaves.
---@return table[] list  { unit, fails, since, lastErr }
function Stores.stuckUnits()
    local list = {}
    for unit, q in pairs(Stores._quarantine) do
        if q.fails >= MAX_FLUSH_FAILS then
            list[#list + 1] = { unit = unit, fails = q.fails, since = q.since, lastErr = q.lastErr }
        end
    end
    table.sort(list, function(a, b) return (a.since or 0) < (b.since or 0) end)
    return list
end

--- An admin's decision to give up on a stuck save, and on every unit that must land with it. Their changes stay
--- in memory but are never written. /whipsaves drop.
---@param unit string
---@return string[] dropped  the units given up on (empty when `unit` was not stuck)
function Stores.discardStuck(unit)
    local q = Stores._quarantine[unit]
    if not q or q.fails < MAX_FLUSH_FAILS then return {} end
    local dropped = {}
    for u in pairs(groupOf(unit)) do dropped[#dropped + 1] = u end
    for _, u in ipairs(dropped) do Stores.forget(u) end
    print(('^1[whip_core:stores] an admin discarded the unsaved changes of %s^0'):format(table.concat(dropped, ', ')))
    return dropped
end

-- Stuck saves are said once a minute, to the console and to admins online, until they land.
Every('stuck saves report', 60000, function()
    local stuck = Stores.stuckUnits()
    if #stuck == 0 then return end
    local secs = (GetGameTimer() - (stuck[1].since or GetGameTimer())) // 1000
    local msg = ('%d save(s) are stuck, the oldest (%s) for %d s. They are kept and retried; /whipsaves lists them.')
        :format(#stuck, stuck[1].unit, secs)
    print('^1[whip_core:stores] ' .. msg .. '^0')
    for src in pairs(Players) do
        if IsPlayerAceAllowed(src, 'whip.devtools') then NotifyPlayer(src, msg, 'error') end
    end
end)

--- Things owed a write that mark their units only when a save is about to run, so their hot path stays one table
--- assignment (player.lua marks the player unit from here). Run by every flushAll and the stop's dispatchOwed.
local _beforeFlush = {}

---@param fn function
function Stores.beforeFlush(fn)
    _beforeFlush[#_beforeFlush + 1] = fn
end

-- Character rows and positions (player.lua, which loads before this file and so cannot register itself).
Stores.beforeFlush(function() PlayerRows.markUnits() end)

local function runBeforeFlush()
    _marking = true
    for _, fn in ipairs(_beforeFlush) do
        local ok, err = pcall(fn)
        if not ok then print(('[whip_core:stores] before-flush step failed: %s'):format(tostring(err))) end
    end
    _marking = false
end

--- Units of a kind that declares `writeOrder` are put in that order, in the places they already hold; every
--- other unit stays where it is. The activity log's INSERTs keep their rows' id order this way.
---@param stores table[]
local function sortOrdered(stores)
    local at, list = {}, {}
    for i, s in ipairs(stores) do
        if s.kind.writeOrder then at[#at + 1] = i; list[#list + 1] = s end
    end
    if #list < 2 then return end
    table.sort(list, function(a, b) return a.kind.writeOrder(a.handle) < b.kind.writeOrder(b.handle) end)
    for j, i in ipairs(at) do stores[i] = list[j] end
end

--- Flush every dirty unit in one transaction (both sides of a move land or neither); the failure path isolates a
--- poisoned row.
---@param opts table|nil
---   opts.background  the timer thread: suppresses fault injection so it can't steal a test's fault
---   opts.force       ignore the quarantine backoff (teardown and tests)
---@return boolean ok  true only if nothing is still owed afterwards
function Stores.flushAll(opts)
    opts = opts or {}
    runBeforeFlush()
    local now = GetGameTimer()
    local pending, units = {}, {}
    local skipped = 0

    --- Is nothing holding this unit back from being written right now?
    local function unitReady(unit)
        local q = Stores._quarantine[unit]
        return opts.force or not q or now >= q.retryAt
    end

    -- Readiness is a group property: a group waits as a whole (backoff, a write in flight, a
    -- running action) or goes as a whole.
    local function readyToWrite(unit)
        local group = groupOf(unit)
        -- No group waits on actions past HOLD_MAX_MS, even while new actions keep tying members.
        local overdue = false
        if not opts.force then
            for u in pairs(group) do
                local since = Stores._heldSince[u]
                if since and Stores._dirty[u] and now - since >= HOLD_MAX_MS then overdue = true break end
            end
        end
        for u in pairs(group) do
            -- A partner mid-write holds the group back.
            if u ~= unit and Stores._inflight[u] then return false end
            -- Only owed units can hold a group back.
            if Stores._dirty[u] and not unitReady(u) then return false end
            -- An action still running holds what it saved, so it lands as one.
            -- Past the cap, only a Stores.hold still counts (the pump: fuel nobody has paid for yet).
            if not opts.force and heldByAction(u, now, overdue) then return false end
        end
        return true
    end

    --- Is the group due? A member with no `every` always is; one with `every` once it has waited
    --- that long. Any due member takes the whole group. A forced flush writes everything.
    local function dueNow(unit)
        if opts.force then return true end
        for u in pairs(groupOf(unit)) do
            local s = Stores._dirty[u]
            if s then
                local every = s.kind.every
                if not every or now - (Stores._dirtySince[u] or 0) >= every then return true end
            end
        end
        return false
    end

    for unit, store in pairs(Stores._dirty) do
        -- A unit whose commit is in flight is skipped (Stores._inflight) and stays dirty. Counted,
        -- so this pass can't read as "everything is on disk".
        if Stores._inflight[unit] then
            skipped = skipped + 1
        elseif readyToWrite(unit) and dueNow(unit) then
            pending[#pending + 1] = store
            units[#units + 1] = unit
        else
            -- Skipped (backing off, or not due yet) but still owed: counted, so a caller about to
            -- drop a cache doesn't read success.
            skipped = skipped + 1
        end
    end

    if #pending == 0 then return skipped == 0 end

    -- The whole group, on the first attempt too: a linked partner that isn't dirty (abandoned)
    -- still owes its half. (No expanded unit can be in flight: readyToWrite held those back.)
    pending = expandToGroups(pending)
    sortOrdered(pending)
    units = {}
    for i, s in ipairs(pending) do units[i] = s.unit end

    -- Claimed as one batch, so no other commit starts on these while this one runs.
    claimInflight(units)

    for _, unit in ipairs(units) do
        Stores._dirty[unit] = nil
    end

    local faultMode = opts.background and 'backgroundFlush' or nil
    local batchOk, batchErr = safeCommit(pending, faultMode)
    releaseInflight(units)

    if batchOk then
        releaseCommitted(units)
        return skipped == 0
    end

    -- A single pending unit: nothing to isolate, so no retry.
    if #pending == 1 then
        quarantine(units[1], pending[1], batchErr)
        return false
    end

    -- The batch failed: retry as transaction groups (never single units) to find the poisoned one. A failed group
    -- is quarantined but stays linked, so the next attempt gathers it whole.
    local batches, byGroup, seen = {}, {}, {}
    for i, store in ipairs(pending) do
        local unit = units[i]
        if not seen[unit] then
            seen[unit] = true
            local gid = Stores._linked[unit]
            if gid then
                local batch = byGroup[gid]
                if not batch then
                    batch = { stores = {}, units = {} }
                    byGroup[gid] = batch
                    batches[#batches + 1] = batch
                end
                batch.stores[#batch.stores + 1] = store
                batch.units[#batch.units + 1] = unit
            else
                batches[#batches + 1] = { stores = { store }, units = { unit } }
            end
        end
    end

    local failed = 0
    for _, batch in ipairs(batches) do
        -- Re-expanded now: a move during the failed commit's yield may have linked a new member.
        local stores = expandToGroups(batch.stores)
        local batchUnits = {}
        for i, s in ipairs(stores) do batchUnits[i] = s.unit end

        -- A pulled-in unit may have a commit in flight: skip, and the next pass gathers the group.
        if not claimInflight(batchUnits) then
            goto nextBatch
        end

        -- About to be written, so out of _dirty.
        for _, u in ipairs(batchUnits) do Stores._dirty[u] = nil end

        local groupOk, groupErr = safeCommit(stores, faultMode)
        releaseInflight(batchUnits)

        if groupOk then
            releaseCommitted(batchUnits)
        else
            failed = failed + 1
            for i, unit in ipairs(batchUnits) do
                -- quarantine re-marks the unit dirty itself, with its backoff.
                quarantine(unit, stores[i], groupErr)
            end
        end

        ::nextBatch::
    end

    -- Whether everything ultimately landed, not whether the first attempt did.
    return failed == 0 and skipped == 0
end

--- Flush a store's unit and stop tracking it, because its cache is about to be dropped (which would take pending
--- changes with it). Call before releasing any cache table; check the result and keep the cache on failure.
---@param store table
---@return boolean ok
---@return string|nil err
function Stores.teardown(store)
    if not store then return true end
    return Stores.flushNow(store)
end

--- Stop tracking a unit without writing it (discardable state: a session vehicle, a cache replaced by a reload).
---@param unit string
function Stores.forget(unit)
    Stores._dirty[unit] = nil
    Stores._dirtySince[unit] = nil
    Stores._heldBy[unit] = nil
    Stores._heldSince[unit] = nil
    Stores._quarantine[unit] = nil
    -- A held payment waiting on it is let go: what it paid for will never be written. One a write
    -- carries right now is that write's to answer (dropAfter).
    local waiting = {}
    for e in pairs(Stores._carriedBy[unit] or {}) do waiting[#waiting + 1] = e end
    for _, e in ipairs(waiting) do
        if e.inFlight then
            e.dropAfter = true
        else
            detachCarried(e)
            answerCarried({ e }, false, 'the save it rode was discarded')
        end
    end
    -- Unlinked too, or its partners would wait on it forever (readyToWrite).
    unlinkUnit(unit)
end

--- How many units are waiting to be written. For diagnostics and leak detection.
---@return number
function Stores.dirtyCount()
    local n = 0
    for _ in pairs(Stores._dirty) do n = n + 1 end
    return n
end

--- Does this unit still owe the database a write? True while dirty, being written, quarantined, or still linked to
--- a transfer partner. Anything about to drop or replace a cache asks this after its last yield.
---@param unit string
---@return boolean
function Stores.owes(unit)
    return Stores._dirty[unit] ~= nil
        or Stores._inflight[unit] == true
        or Stores._quarantine[unit] ~= nil
        or Stores._linked[unit] ~= nil
end

--- The store handle of a unit that is half of a pending transfer; nil when it is in no group or no handle is left.
--- For Inventory.save, which has only a charId and must hand a grouped unit to Stores.flushNow.
---@param unit string
---@return table|nil store
function Stores.linkedStore(unit)
    local groupId = Stores._linked[unit]
    if not groupId then return nil end
    local store = Stores._dirty[unit]
    if not store then
        local g = Stores._groups[groupId]
        store = g and g[unit] or nil
    end
    return store
end

--- Write whatever this unit still owes now, and say whether anything is left. For a load about to read the unit's
--- rows back: a queued write would otherwise put a moved item in two places. Yields.
---@param unit string
---@return boolean settled  true when nothing is owed any more
function Stores.settle(unit)
    if not Stores.owes(unit) then return true end

    -- The handle to write with: the queued one, or the group's copy of an abandoned member.
    local store = Stores._dirty[unit]
    if not store then
        local gid = Stores._linked[unit]
        local g = gid and Stores._groups[gid]
        local member = g and g[unit]
        if type(member) == 'table' then store = member end
    end

    if store then
        local ok, err = pcall(Stores.flushNow, store)
        if not ok then
            print(('[whip_core:stores] settle %s raised: %s'):format(unit, tostring(err)))
        end
    else
        -- Only in flight: somebody else is writing it. Wait for that, bounded like flushNow.
        local waited = 0
        while Stores._inflight[unit] and waited < 5000 do
            Wait(25)
            waited = waited + 25
        end
    end

    return not Stores.owes(unit)
end

--- The queries for a store's whole group. An in-flight member is written whole, not as a diff; if any member can't
--- be built nothing is sent.
---@param store table
---@return table|nil queries  nil when a member could not be built
---@return string[] units     every unit of the group
---@return table[] carried    the held payments that ride with it, marked in flight (only when it is whole)
local function groupQueries(store)
    local queries, units, whole = {}, {}, true
    for _, s in ipairs(expandToGroups({ store })) do
        units[#units + 1] = s.unit
        if whole and s.kind.persist then
            if Stores._inflight[s.unit] and s.kind.invalidate then
                pcall(s.kind.invalidate, s.handle)
            end
            local ok, q = pcall(s.kind.persist, s.handle)
            if ok and type(q) == 'table' then
                for _, one in ipairs(q) do queries[#queries + 1] = one end
            else
                whole = false
                print(('[whip_core:stores] %s could not be written (%s) — its whole group is left unsent')
                    :format(tostring(s.unit), tostring(q)))
            end
        end
    end
    -- A held payment waiting on these units goes with them, marked in flight. The caller answers it
    -- if it can hear back (dispatchGroup).
    local carried = {}
    if whole then
        local set = {}
        for _, u in ipairs(units) do set[u] = true end
        carried = carriedFor(set)
        for _, e in ipairs(carried) do
            e.inFlight = true
            for _, q in ipairs(e.queries) do queries[#queries + 1] = q end
        end
    end
    return whole and queries or nil, units, carried
end

--- Hand everything still owed to the database without waiting for an answer; returns how many units went.
--- For whip_core's own onResourceStop only: a stop handler can't wait, so each group goes as one transaction
--- without .await.
---@return number units
function Stores.dispatchOwed()
    runBeforeFlush()   -- character rows and positions mark their units here
    local owed = {}
    for _, store in pairs(Stores._dirty) do owed[#owed + 1] = store end
    -- Abandoned group members have left _dirty; the group map holds the only handle left.
    for _, g in pairs(Stores._groups) do
        for unit, s in pairs(g) do
            if type(s) == 'table' and not Stores._dirty[unit] then owed[#owed + 1] = s end
        end
    end

    local done, count = {}, 0
    for _, store in ipairs(owed) do
        if not done[store.unit] then
            local queries, units = groupQueries(store)
            for _, u in ipairs(units) do
                done[u] = true
                count = count + 1
            end
            if queries and #queries > 0 then pcall(MySQL.transaction --[[@as function]], queries) end
        end
    end
    return count
end

--- Send one unit's whole group now without waiting, for a satellite store kind whose resource is stopping. False
--- when a member's queries could not be built; nothing is sent then.
---@param store table
---@return boolean sent
function Stores.dispatchGroup(store)
    local queries, _, carried = groupQueries(store)
    if not queries then return false end
    if #queries == 0 then return true end
    if #carried == 0 then
        pcall(MySQL.transaction --[[@as function]], queries)
        return true
    end
    -- A held payment rides it and whip_core is still running: wait in a thread of its own (an
    -- onRemove must not wait) and answer the payment.
    CreateThread(function()
        local called, ok, err = pcall(Stores.runTransaction, queries)
        if not called then ok, err = false, tostring(ok) end
        settleCarried(carried, ok, err)
    end)
    return true
end

--- The flush thread: every Config.FlushInterval, every dirty unit of a 'writeBehind' kind goes to the database in
--- one transaction. Stores._flushPaused (set only by tests) suspends the timer; explicit flushes still work.
Stores._flushPaused = false

--- Is the flush thread paused (by a test)? The character-row flush thread in player.lua holds
--- itself on the same switch.
---@return boolean
function Stores.isFlushPaused()
    return Stores._flushPaused
end

CreateThread(function()
    while true do
        Wait(Config.FlushInterval or 1000)
        -- Not while the database is down (db_health.lua): it would only fail, and its return saves everything.
        if not Stores._flushPaused and DbHealth.up then
            -- background: must not consume a fault injected for a foreground operation under test.
            local ok, err = pcall(Stores.flushAll, { background = true })
            if not ok then
                print(('[whip_core:stores] flush thread error: %s'):format(tostring(err)))
            end
        end
    end
end)

--- Item stores owed a write: dirty, mid-write or backing off after a failure. For the console. Save
--- units (car stats…) are counted under their own names (Stores.defineUnit's `what`).
local function owedUnitCount()
    local seen, n = {}, 0
    for _, set in ipairs({ Stores._dirty, Stores._inflight, Stores._quarantine }) do
        for unit in pairs(set) do
            local kindId = unit:match('^([^:]+):')
            if not seen[unit] and not (kindId and Stores._unitKinds[kindId]) then
                seen[unit], n = true, n + 1
            end
        end
    end
    return n
end

-- STEP 10 of the final save (server/lifecycle.lua): everything owed, backoff ignored, waited for.
-- Step 52 sends what the kicked players' own saves leave behind.
FinalSave.add(10, 'pockets, stashes and boots', function()
    if not Stores.flushAll({ force = true }) then
        print(('[whip_core:stores] final save: %d store(s) still owed after the first pass'):format(Stores.dirtyCount()))
    end
end, owedUnitCount)

-- Again until nothing is owed or the time is up (half a second before the deadline). Names what never landed,
-- in flight included.
FinalSave.add(52, 'pockets, stashes and boots (last pass)', function(deadline)
    local by = deadline - 500
    local saved = Stores.flushAll({ force = true })
    while not saved and GetGameTimer() < by do
        Wait(100)
        saved = Stores.flushAll({ force = true })
    end
    if not saved then
        local seen, names = {}, {}
        for _, set in ipairs({ Stores._dirty, Stores._inflight, Stores._quarantine }) do
            for unit in pairs(set) do
                if not seen[unit] then seen[unit] = true; names[#names + 1] = unit end
            end
        end
        table.sort(names)
        print(('^1[whip_core:stores] final save: NOT written: %s — the database did not take them, or a write never answered^0')
            :format(table.concat(names, ', ')))
    end
    return saved
end)

-- The client boundary, Stores.fromWire: the one place a client-supplied address (the 'addr' SecureEvent param
-- type) becomes a store. A client may only name stores it currently holds open; the server may open any.
-- The wire shape is flat, with no nested tables from an untrusted source:
--     { kind = 'vehicle', id = 7, sub = 'trunk', slot = 1 }
--     { kind = 'container', id = 42, slot = 3 }
--     { kind = 'accessory', slot = 3 }
--     { kind = 'panel', id = '_gunny_mag', slot = 2 }

--- Kinds a client may name. `rawInventory` is absent (it would name another character's inventory by charId);
--- `ground` is absent (pickups have their own events and distance checks).
local CLIENT_KINDS = {
    container = true, vehicle = true, panel = true,
    -- Not 'shop' or 'basket': the shop screen has its own events. 'target' is the admin inspect path: its charId
    -- comes from the session the server opened after its own ACE check, never the client.
    target = true,
}

-- Every pocket is a client-addressable name, derived so a new pocket is addressable at once.
for _, c in ipairs(PlayerContainers) do CLIENT_KINDS[c] = true end

-- Names RegisterStoreKind refuses to a satellite: the kinds this file defines and the names
-- fromWire branches on. Built here so it can't fall out of step with CLIENT_KINDS.
for name in pairs(CLIENT_KINDS) do Stores.ReservedKindNames[name] = true end
for name in pairs(Stores._kinds) do Stores.ReservedKindNames[name] = true end

local EMPTY_VIEWERS = {}

-- Viewers: who currently has a store open. Several players can; being a viewer is not access (decided once at
-- open by Containers.canAccess and the distance check), it is what authorises a drag. Keyed on `store.id`, so
-- satellite kinds need no extra code. `mode` is per viewer, not per store.

--- [storeId] = { by = { [src] = { mode, anchor, addr } }, n = <count> }. Exists only while somebody has the store
--- open: the last one out removes it.
Stores._views = {}

--- [src] = { [storeId] = true } — so a disconnect is one lookup rather than a scan of every store.
Stores._viewing = {}

--- Register that this player now has this store open.
---@param src number
---@param storeId string
---@param mode string|nil  'rw' (default) or 'ro'
---@param anchor table|nil { x, y, z, range } where the open's distance check was made; fromWire holds the viewer
---                        to it while the store stays open. nil for opens never distance-checked (admin, script-driven).
---@param addr table|nil  the store's address, kept for GetOpenStores
---@param override string|nil  what the open let this viewer past, for fromWire to keep honouring:
---                        'lock' (a car's lock), 'access' (a stash's lock and requirements), 'admin' (the lock, the
---                        keep range and the driver's seat). nil for an ordinary open.
function Stores.addViewer(src, storeId, mode, anchor, addr, override)
    local view = Stores._views[storeId]
    if not view then
        view = { by = {}, n = 0 }
        Stores._views[storeId] = view
    end

    if not view.by[src] then
        view.n = view.n + 1
    end
    view.by[src] = { mode = mode or 'rw', anchor = anchor, addr = addr, override = override }

    local mine = Stores._viewing[src]
    if not mine then
        mine = {}
        Stores._viewing[src] = mine
    end
    mine[storeId] = true
end

--- What may this player do with this store right now? nil means they do not have it open.
---@param src number
---@param storeId string
---@return string|nil mode
function Stores.viewerMode(src, storeId)
    local view = Stores._views[storeId]
    local rec = view and view.by[src]
    return rec and rec.mode or nil
end

--- What this viewer's open let them past ('lock' | 'admin'), or nil. See addViewer.
---@param src number
---@param storeId string
---@return string|nil override
function Stores.viewerOverride(src, storeId)
    local view = Stores._views[storeId]
    local rec = view and view.by[src]
    local override = rec and rec.override or nil
    -- An admin's open lasts only while they ARE one (dev tools taken back with a boot open).
    if override == 'admin' and not DevTools.isAllowed(src) then return nil end
    return override
end

--- Does this player have this store open at all?
---@param src number
---@param storeId string
---@return boolean
function Stores.isViewer(src, storeId)
    return Stores.viewerMode(src, storeId) ~= nil
end

--- Is this viewer still where their open was distance-checked? True when there is no anchor. Every move
--- re-checks against the anchor (the keep range).
---@param src number
---@param storeId string
---@return boolean
function Stores.viewerInRange(src, storeId)
    local view = Stores._views[storeId]
    local rec = view and view.by[src]
    local a = rec and rec.anchor
    if not a then return true end
    return IsPlayerNear(src, a.x, a.y, a.z, a.range)
end

--- Remove one viewer. Takes a plain id, so a close still works after the store has gone.
---@param src number
---@param storeId string
---@return boolean removed
function Stores.removeViewer(src, storeId)
    local view = Stores._views[storeId]
    if not view or not view.by[src] then return false end

    view.by[src] = nil
    view.n = view.n - 1

    local mine = Stores._viewing[src]
    if mine then
        mine[storeId] = nil
        if next(mine) == nil then Stores._viewing[src] = nil end
    end

    if view.n <= 0 then
        -- Last one out: the record goes. Unloading the store's contents is the caller's decision
        -- (Containers.unloadInventory, Vehicles.unloadIfIdle), not this bookkeeping's.
        Stores._views[storeId] = nil
    end
    return true
end

--- Drop every membership this player holds, on disconnect. Must run before Players[source] is cleared.
---@param src number
---@return string[] storeIds  what they were in, for anything that needs to react
function Stores.releaseAllViews(src)
    local mine = Stores._viewing[src]
    if not mine then return {} end

    local released = {}
    for storeId in pairs(mine) do
        released[#released + 1] = storeId
    end
    -- Cleared first so removeViewer's own bookkeeping cannot see a half-emptied table.
    Stores._viewing[src] = nil
    for _, storeId in ipairs(released) do
        local view = Stores._views[storeId]
        if view and view.by[src] then
            view.by[src] = nil
            view.n = view.n - 1
            if view.n <= 0 then Stores._views[storeId] = nil end
        end
    end
    return released
end

--- Who is looking at this store? The table is live: do not hold it across a yield or mutate it.
---@param storeId string
---@return table by  [source] = { mode }
function Stores.viewersOf(storeId)
    local view = Stores._views[storeId]
    return view and view.by or EMPTY_VIEWERS
end

--- How many people have this store open.
---@param storeId string
---@return number
function Stores.viewerCount(storeId)
    local view = Stores._views[storeId]
    return view and view.n or 0
end

--- Every store this player has open, as a fresh list of ids — safe to walk while removing them.
---@param src number
---@return string[] storeIds
function Stores.viewedBy(src)
    local ids = {}
    for storeId in pairs(Stores._viewing[src] or {}) do ids[#ids + 1] = storeId end
    return ids
end

--- Forget a store's viewer record entirely. For when the store itself ceases to exist.
---@param storeId string
function Stores.forgetViews(storeId)
    local view = Stores._views[storeId]
    if not view then return end
    for src in pairs(view.by) do
        local mine = Stores._viewing[src]
        if mine then
            mine[storeId] = nil
            if next(mine) == nil then Stores._viewing[src] = nil end
        end
    end
    Stores._views[storeId] = nil
end

-- Telling the other viewers: only changed slots are sent, an emptied slot as `false` (so "now empty" differs from
-- "not mentioned"), and only to actual viewers of that store.

--- Build the wire form of some slots of a store as they are now.
---@param store table
---@param slots number[]
---@return table payload
local function buildSlotPayload(store, slots)
    local payload = { storeId = store.id, slots = {} }
    for _, slot in ipairs(slots) do
        local data = store.kind.get(store.handle, slot)
        payload.slots[tostring(slot)] = data
            and { item = data.item, amount = data.amount, metadata = data.metadata }
            or false
    end
    payload.weight = Stores.weightOf(store)
    return payload
end

--- Push the given slots of a store to everyone looking at it except the player who changed it.
---@param store table
---@param slots number[]  the slot numbers that changed
---@param exceptSrc number|nil  usually the player whose action caused the change
---@param alsoTo number|nil  one more player to send the same payload to (the mover, when their own grid takes the delta)
function Stores.publishSlots(store, slots, exceptSrc, alsoTo)
    if not store or not slots or #slots == 0 then return end

    local by = Stores.viewersOf(store.id)
    local recipients = {}
    for src in pairs(by) do
        if src ~= exceptSrc then recipients[#recipients + 1] = src end
    end
    if alsoTo and not (by[alsoTo] and alsoTo ~= exceptSrc) then recipients[#recipients + 1] = alsoTo end
    -- Nobody to tell (the common case) builds nothing: a build weighs the whole store.
    if #recipients == 0 then return end

    -- Built once, sent to every recipient.
    local payload = buildSlotPayload(store, slots)

    for _, src in ipairs(recipients) do
        TriggerClientEvent('whip_core:client:storeDelta', src, payload)
    end
end

--- Push the current state of some slots to one player. For refusals: the client undoes its optimistic update.
---@param src number
---@param store table
---@param slots number[]
function Stores.publishSlotsTo(src, store, slots)
    if not src or not store or not slots or #slots == 0 then return end
    TriggerClientEvent('whip_core:client:storeDelta', src, buildSlotPayload(store, slots))
end

--- How far a player may stray from a vehicle and still move things in its storage. Never tighter than the range
--- the boot opens from. Read per call: config is hot-editable.
---@return number metres
local function vehicleKeepRange()
    return math.max(tonumber(Config.VehicleStorageKeepRange) or 5.0, Vehicles.trunkOpenRange())
end

-- fromAddr: the same `{ kind, id, sub, slot }` address resolved for trusted server code. Not fromWire minus the
-- auth check: kinds that only mean something relative to a player ('target', the shop's session stores) are refused.

-- ['container:<id>' | 'vehicle:<id>'] = { kind, id, at }: storage the address exports loaded with nobody looking.
-- The sweep below unloads it two minutes after an export last touched it, through the unload a close uses.
local addrLoaded = {}
local ADDR_IDLE_MS = 120000

-- Every (lifecycle.lua), so one error can't end the sweep.
Every('idle store unload', 60000, function()
    local now = GetGameTimer()
    local due = {}
    for key, m in pairs(addrLoaded) do
        if now - (m.at or 0) >= ADDR_IDLE_MS then due[#due + 1] = key end
    end
    for _, key in ipairs(due) do
        local m = addrLoaded[key]
        if m and now - (m.at or 0) >= ADDR_IDLE_MS then
            if m.kind == 'container' then
                if not Containers.invCache[m.id] or Containers.unloadInventory(m.id) then
                    addrLoaded[key] = nil
                end
            elseif not Vehicles.invCache[m.id] then
                addrLoaded[key] = nil
            -- A car in the world keeps its storage (despawn writes and drops it).
            elseif not Vehicles.getEntity(m.id) and Vehicles.unloadIfIdle(m.id) then
                addrLoaded[key] = nil
            end
        end
    end
end)

--- Resolve a store address for trusted server code: no authorisation, no session lookups.
---@param addr table  { kind, id?, sub?, slot }
---   player     id = server id, sub = 'player' | 'accessory' (default 'player')
---   container  id = container id — loaded if nobody has opened it since the restart
---   vehicle    id = vehicle id, sub = 'trunk' | 'glovebox' | 'key' — loaded the same way
---   panel      id = the panel's id; owner = a player who has it open (optional: any viewer will do)
---@param opts table|nil  { slotOptional = true } — for a caller that can pick the slot itself
---@return table|nil store
---@return number|nil slot  nil only when opts.slotOptional and the address named none
---@return string|nil err
function Stores.fromAddr(addr, opts)
    if type(addr) ~= 'table' then return nil, nil, 'address must be a table' end

    local kind = Sanitize.key(addr.kind, 20)
    if not kind then return nil, nil, 'address needs a kind' end

    -- Slots are addresses, not quantities: reject rather than clamp. A missing slot is allowed
    -- only where the caller can choose one itself (StoreGive, StoreMove's destination, StoreRead).
    local slot = nil
    if addr.slot ~= nil or not (opts and opts.slotOptional) then
        slot = tonumber(addr.slot)
        if not slot or slot ~= math.floor(slot) or slot < 1 then
            return nil, nil, 'slot must be a positive integer'
        end
    end

    local function wholeId()
        local n = tonumber(addr.id)
        if not n or n ~= math.floor(n) then return nil end
        return math.tointeger and math.tointeger(n) or n
    end

    -- One spelling for the strip: { kind = 'player', id = source, sub = 'accessory' }.
    if kind == 'player' then
        local src = wholeId()
        if not src then return nil, nil, 'player address needs the server id in `id`' end
        local container = addr.sub or 'player'
        local store, err = Stores.player(src, container)
        if not store then return nil, nil, err end
        return store, slot
    end

    if kind == 'container' then
        local containerId = wholeId()
        if not containerId then return nil, nil, 'container address needs a whole-number id' end
        -- Loaded on demand, without a viewer: a resource can reach a stash nobody has open.
        if not Containers.invCache[containerId] then
            if not Containers.getDef(containerId) then return nil, nil, 'No such container' end
            if not Containers.loadInventory(containerId) then
                return nil, nil, 'could not read that container'
            end
            addrLoaded['container:' .. containerId] = { kind = 'container', id = containerId }
        end
        local mark = addrLoaded['container:' .. containerId]
        if mark then mark.at = GetGameTimer() end
        local store, err = Stores.container(containerId)
        if not store then return nil, nil, err end
        return store, slot
    end

    if kind == 'vehicle' then
        -- A vehicleId, or a vehicle reference ({ plate }, { entity }, { netId }) — the same forms
        -- every vehicle export takes (Vehicles.idFromRef).
        local vehicleId, refErr = Vehicles.idFromRef(addr.id)
        if not vehicleId then
            return nil, nil, refErr or 'vehicle address needs a vehicle id (or a vehicle reference)'
        end
        local storageType = Sanitize.enum(addr.sub, { 'trunk', 'glovebox', 'key' })
        if not storageType then
            return nil, nil, "vehicle address needs sub = 'trunk', 'glovebox' or 'key'"
        end
        -- Loaded on demand, like a stash above.
        if not Vehicles.invCache[vehicleId] then
            if not Vehicles.getDef(vehicleId) then return nil, nil, 'Vehicle not found' end
            if not Vehicles.loadInventory(vehicleId) then
                return nil, nil, 'could not read that vehicle\'s storage'
            end
            addrLoaded['vehicle:' .. vehicleId] = { kind = 'vehicle', id = vehicleId }
        end
        local vmark = addrLoaded['vehicle:' .. vehicleId]
        if vmark then vmark.at = GetGameTimer() end
        local store, err = Stores.vehicle(vehicleId, storageType)
        if not store then return nil, nil, err end
        return store, slot
    end

    -- A ground item is not a store (FindItemByUid answers `{ kind = 'ground', id }`): say so plainly.
    if kind == 'ground' then
        return nil, nil, 'a ground item is not a store address — read it with GetGroundItem(id); a player picks it up'
    end

    -- A panel is found by its id, through any viewer's session (they share one table); `owner`
    -- names one when the caller knows it.
    if kind == 'panel' then
        if addr.id == nil then return nil, nil, 'panel address needs the panel id in `id`' end
        local owner = tonumber(addr.owner)
        if not owner then
            for viewer in pairs(Stores.viewersOf('panel:' .. tostring(addr.id))) do
                owner = viewer
                break
            end
        end
        if not owner then return nil, nil, 'that panel is not open' end
        local store, err = Stores.panel(owner, addr.id)
        if not store then return nil, nil, err or 'that panel is not open' end
        -- A RegisterPanelItem panel's item may have changed while open (a shot, a reload): server
        -- code works on the item's current contents, not the panel's old copy.
        local session = store.handle and store.handle.session
        if session and session.registration and Panels.refreshFromHost then
            Panels.refreshFromHost(owner, session)
        end
        return store, slot
    end

    -- Session kinds are refused: 'shop' and 'basket' only exist relative to a player who has one
    -- open. Use the shop's own exports.
    if kind == 'shop' or kind == 'basket' then
        return nil, nil, ('"%s" is a per-player session store and has no server-side address')
            :format(kind)
    end

    -- Anything else, including satellite kinds, resolves through its own registered kind if it
    -- can take a plain key. Satellites that need something richer should expose their own export.
    local def = Stores._kinds[kind]
    if not def then
        return nil, nil, ('Unknown store kind "%s"'):format(tostring(kind))
    end

    local store, err = Stores.open(kind, { id = addr.id, sub = addr.sub })
    if not store then return nil, nil, err end
    return store, slot
end

--- May this player reach into a locked car's glovebox or ignition? Its owner, or anyone carrying a key to it.
--- A seat alone is not enough (a modified client can warp into one); a seat with a key in the ignition is, the
--- same rule as unlocking it (toggleVehicleLock).
---@param src number
---@param vehicleId number
---@return boolean
local function mayReachInsideLocked(src, vehicleId)
    if not Vehicles.isLocked(vehicleId) then return true end
    local p = Players[src]
    if not p then return false end
    local def = Vehicles.getDef(vehicleId)
    if def and def.ownerCharId and def.ownerCharId == p.charId then return true end
    if Vehicles.playerHasKey(p, vehicleId) then return true end
    return Vehicles.isPlayerIn(src, vehicleId) and Vehicles.hasKeyInIgnition(vehicleId)
end

--- Resolve AND authorise an address a client sent (the 'addr' param type in secure.lua).
---@param src number
---@param addr table  { kind, id?, sub?, slot }
---@param opts table|nil  { slotOptional = true } — a whole store, for a handler that picks the slot
---@return table|nil store
---@return number|nil slot  nil only when opts.slotOptional and the address named none
---@return string|nil err
function Stores.fromWire(src, addr, opts)
    if type(addr) ~= 'table' then return nil, nil, 'address must be a table' end

    -- Errors quote the sanitised kind, never addr.kind: this text reaches the console.
    local kind = Sanitize.key(addr.kind, 20)
    if not kind then
        return nil, nil, 'not a client-addressable store'
    end

    -- A satellite's kind is client-addressable only if its definition supplied authorize(); whip_core can't know
    -- what "has that store open" means for it. Anything that throws is a refusal.
    local satellite = StoreKindOwners and StoreKindOwners[kind] and Stores._kinds[kind]
    if satellite then
        -- Opened with OpenStore: the player is a viewer, and that is the authorisation (held to the
        -- keep range and read-only). The kind's own authorize() is the other road in.
        local viewing = false
        -- { id, sub }: the key every other path opens it with.
        local okOpen, opened = pcall(Stores.open, kind, { id = addr.id, sub = addr.sub })
        if okOpen and type(opened) == 'table' and opened.id and Stores.isViewer(src, opened.id) then
            if Stores.viewerMode(src, opened.id) == 'ro' then
                return nil, nil, 'You can only look at that'
            end
            if not Stores.viewerInRange(src, opened.id) then
                return nil, nil, 'You are too far away from that'
            end
            viewing = true
        end

        if not viewing then
            -- Checked for presence, not type 'function': through an export it is a callable table.
            -- The pcall decides, and a throw is a refusal.
            if satellite.authorize == nil then
                return nil, nil, ('store kind "%s" is server-only'):format(kind)
            end
            local okAuth, allowed = pcall(satellite.authorize, src, addr)
            if not okAuth or allowed ~= true then
                return nil, nil, ('you do not have that %s open'):format(kind)
            end
        end
    elseif not CLIENT_KINDS[kind] then
        return nil, nil, ('not a client-addressable store: %s'):format(kind)
    end

    -- Slots are addresses, not quantities: reject rather than clamp (Sanitize.int would act on a
    -- slot the caller never named). Real bounds come from the store, inside Stores.move.
    -- A missing slot only where the handler asked for a whole store; a slot that IS sent is checked.
    local slot = nil
    if addr.slot ~= nil or not (opts and opts.slotOptional) then
        slot = tonumber(addr.slot)
        if not slot or slot ~= math.floor(slot) or slot < 1 then
            return nil, nil, 'slot must be a positive integer'
        end
    end

    -- A player's own containers need no authorization beyond being that player.
    if Inventory.isPlayerContainer(kind) then
        local store, err = Stores.player(src, kind)
        if not store then return nil, nil, err end
        return store, slot
    end

    -- Ids must be whole numbers: store ids are built with tostring (7.0 gives "7.0", not "7"), and
    -- '%d' errors on a float.
    local function wholeId()
        local n = tonumber(addr.id)
        if not n or n ~= math.floor(n) then return nil end
        return math.tointeger and math.tointeger(n) or n
    end

    if kind == 'container' then
        local containerId = wholeId()
        if not containerId then return nil, nil, 'container address needs a whole-number id' end
        -- Membership is the authorization: added in openContainer after the distance check and
        -- Containers.canAccess, until the close. Must match the kind's instanceId: 'container:' .. id.
        if not Stores.isViewer(src, 'container:' .. tostring(containerId)) then
            return nil, nil, 'that container is not open for you'
        end
        -- A read-only viewer (addViewer's 'ro' mode) may look and never move.
        if Stores.viewerMode(src, 'container:' .. tostring(containerId)) == 'ro' then
            return nil, nil, 'that container is read-only for you'
        end
        if not Stores.viewerInRange(src, 'container:' .. tostring(containerId)) then
            return nil, nil, 'you are too far from that container'
        end
        -- And still allowed in: a stash locked, re-assigned or off-duty since the open shuts the
        -- viewer out on their next move. An open that skipped access (OpenStore's skipAccess, the
        -- shop's stock view, the Container Manager) recorded that, and it holds.
        if Stores.viewerOverride(src, 'container:' .. tostring(containerId)) == nil then
            local p = Players[src]
            local allowed, why = Containers.canAccess(containerId, p and p.charId, src, p)
            if not allowed then
                return nil, nil, why or 'you do not have access to that container'
            end
        end
        local store, err = Stores.container(containerId)
        if not store then return nil, nil, err end
        return store, slot
    end

    if kind == 'vehicle' then
        local vehicleId = wholeId()
        if not vehicleId then return nil, nil, 'vehicle address needs a whole-number id' end
        local storageType = Sanitize.enum(addr.sub, { 'trunk', 'glovebox', 'key' })
        if not storageType then return nil, nil, 'vehicle address needs trunk|glovebox|key' end
        local storeId = ('vehicle:%s:%s'):format(tostring(vehicleId), storageType)

        -- What the open let this viewer past still holds (OpenStore's skipAccess on a locked boot,
        -- the Vehicle Manager from anywhere): recorded on the viewer.
        local override = Stores.viewerOverride(src, storeId)

        if storageType == 'key' and override == 'admin' then
            if not Stores.isViewer(src, storeId) then
                return nil, nil, 'that vehicle storage is not open for you'
            end
        elseif storageType == 'key' then
            -- The ignition is authorized by presence: the driver's seat of THIS car (the UI only
            -- shows it to seat -1, events_vehicles.lua). Not a passenger, who could lift the key
            -- mid-drive, and not from inside another car.
            if not Vehicles.isPlayerDriving(src, vehicleId) then
                return nil, nil, 'you must be in the driver seat'
            end
            if not mayReachInsideLocked(src, vehicleId) then
                return nil, nil, 'that vehicle is locked'
            end
        else
            -- Membership, as the container branch. Must match the kind's instanceId:
            -- 'vehicle:' .. id .. ':' .. storageType.
            if not Stores.isViewer(src, storeId) then
                return nil, nil, 'that vehicle storage is not open for you'
            end
            -- Read-only viewers look and never move (see the container branch).
            if Stores.viewerMode(src, storeId) == 'ro' then
                return nil, nil, 'that vehicle storage is read-only for you'
            end

            -- Membership is not proximity: every move passes through fromWire, so it is checked here (range is
            -- vehicleKeepRange; sitting in the car counts). A missing IsPlayerNearVehicle refuses.
            -- A boot locked since the open is shut.
            if storageType == 'trunk' and override == nil and Vehicles.isLocked(vehicleId) then
                return nil, nil, 'that vehicle is locked'
            end
            -- The glovebox of a locked car: its owner, a keyholder, or someone sitting in it with its
            -- key in the ignition (see mayReachInsideLocked).
            if storageType == 'glovebox' and override == nil and not mayReachInsideLocked(src, vehicleId) then
                return nil, nil, 'that vehicle is locked'
            end
            local keep = vehicleKeepRange()
            if override ~= 'admin' and (not IsPlayerNearVehicle or not IsPlayerNearVehicle(src, vehicleId, keep)) then
                return nil, nil, ('you are too far from that vehicle (%.0fm)'):format(keep)
            end
        end
        local store, err = Stores.vehicle(vehicleId, storageType)
        if not store then return nil, nil, err end
        return store, slot
    end

    if kind == 'target' then
        -- The session IS the authorization: the server opened it (the ACE-gated admin tool, or the
        -- OpenPlayerInventory export) and it carries the charId. For the admin tool it survives
        -- the target disconnecting; Stores.rawInventory handles live and offline caches alike.
        local session = Inventory.playerInvSession(src)
        if not session then return nil, nil, 'you have no player inventory open' end

        -- And still beside them, when the session has a range (the export's, for a robbery). A
        -- watcher closes a session whose viewer has left; this refuses the moves in between.
        if session.range and not Inventory.targetInReach(src, session.targetSource, session.range + 1.0) then
            return nil, nil, 'you are too far from them'
        end

        local container = Sanitize.enum(addr.sub, PlayerContainers)
        if not container then return nil, nil, 'target address needs player|accessory' end

        local store, err = Stores.rawInventory(session.targetCache, session.targetCharId, container)
        if not store then return nil, nil, err end
        return store, slot
    end

    if kind == 'panel' then
        if not Panels.hasOpen(src) then return nil, nil, 'you have no panel open' end

        -- The id must match a session the server opened for THIS player, so a client can't reach
        -- another resource's or player's panel, or a guessed name.
        local panelId = Panels.wireId(addr.id)   -- a number id too
        if not panelId then return nil, nil, 'that is not a panel you have open' end

        local session = Panels.sessionById(src, panelId)
        if not session then return nil, nil, 'that is not a panel you have open' end

        if session.config and session.config.readOnly then
            return nil, nil, 'that panel is read-only'
        end
        -- Named explicitly: with several open, "this player's panel" no longer identifies one.
        local store, err = Stores.panel(src, session.id)
        if not store then return nil, nil, err end
        return store, slot
    end

    -- A satellite kind, already authorized at the top. Opened with the same key every server path
    -- uses, { id, sub }, so it has one id. (authorize() still sees the whole address.)
    if satellite then
        local store, err = Stores.open(kind, { id = addr.id, sub = addr.sub })
        if not store then return nil, nil, err or ('could not open that %s'):format(kind) end
        return store, slot
    end

    return nil, nil, 'unhandled store kind'
end

-- Public exports (they read Stores._viewing and parse the storeId grammar, which this file owns).

--- Every store this player has open, in a stable order, each as an address for StoreRead, StoreGive or StoreMove:
---     { { kind = 'container', id = 12 }, { kind = 'vehicle', id = 40, sub = 'trunk' }, ... }
--- The player's own pockets are never in the list. A shop they are browsing is `{ kind = 'shop' }` (no server-side
--- address). A panel carries its `label`, which is how a resource learns the id of a panel an item opened.
---@param source number
---@return table[] addresses  empty when nothing is open
exports('GetOpenStores', function(source)
    source = tonumber(source) or -1
    local out = {}
    local mine = Stores._viewing[source]
    if mine then
        for storeId in pairs(mine) do
            local view = Stores._views[storeId]
            local rec = view and view.by[source]
            local containerId = storeId:match('^container:(%d+)$')
            local vehicleId, storageType = storeId:match('^vehicle:(%d+):(%a+)$')
            local panelId = storeId:match('^panel:(.+)$')
            if rec and rec.addr then
                -- Opened with OpenStore, which kept the address it was given — the one form that
                -- survives any storeId a store kind makes up.
                out[#out + 1] = { kind = rec.addr.kind, id = rec.addr.id, sub = rec.addr.sub }
            elseif containerId then
                out[#out + 1] = { kind = 'container', id = tonumber(containerId) }
            elseif vehicleId then
                out[#out + 1] = { kind = 'vehicle', id = tonumber(vehicleId), sub = storageType }
            elseif panelId then
                -- The session's own id, not the string in the storeId: an id may be a number.
                local session = Panels.sessionById(source, panelId)
                out[#out + 1] = {
                    kind  = 'panel',
                    id    = session and session.id or (tonumber(panelId) or panelId),
                    owner = source,
                    label = session and session.config and session.config.label or nil,
                }
            else
                local kind, rest = storeId:match('^([%w_]+):(.+)$')
                if kind then out[#out + 1] = { kind = kind, id = tonumber(rest) or rest } end
            end
        end
    end
    if Shops and Shops.openShopOf and Shops.openShopOf(source) then
        out[#out + 1] = { kind = 'shop' }
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return tostring(a.id) .. tostring(a.sub) < tostring(b.id) .. tostring(b.sub)
    end)
    return out
end)

-- OpenStore / CloseStore: put any store in front of a player. A stash and a boot go through their own open paths
-- (access, distance and lock rules); any other kind shows in the same right-hand grid and makes the player a viewer.

--- Open a store on a player's screen, beside their pockets.
---     exports.whip_core:OpenStore(source, { kind = 'container', id = 12 })
---     exports.whip_core:OpenStore(source, { kind = 'vehicle', id = vehicleId, sub = 'trunk' }, { skipAccess = true })
---     exports.whip_core:OpenStore(source, { kind = 'my_safe', id = 3 }, { coords = safeCoords })
---
--- opts:
---   skipDistance  a stash: do not require the player to be standing at it (a boot always does)
---   skipAccess    a stash: ignore its lock, owner and requirements; a boot: open it even if the car is locked
---                 (for when your resource has already decided: a keycard, a warrant, a job)
---   coords, range your own kind: the player must stay within `range` (default 3 m) of `coords`
---   readOnly      your own kind: they can look, and every move is refused
--- A player's pockets open with OpenPlayerInventory, a panel with OpenPanel; a vehicle's glovebox and ignition open
--- from its seat. If the player already has a screen open, the open is declined. Answers `true` or `false, reason`.
---@param source number|string|nil
---@param addr table  { kind, id, sub }
---@param opts table|nil
---@return boolean ok
---@return string|nil err
exports('OpenStore', function(source, addr, opts)
    source = tonumber(source)
    local player = source and Players[source]
    if not source or not player or not player.inventory then return false, 'Player not loaded' end
    if type(addr) ~= 'table' then return false, 'OpenStore takes an address: { kind, id, sub }' end
    opts = type(opts) == 'table' and opts or {}
    local kind = addr.kind

    if kind == 'container' then
        local id = Sanitize.id(addr.id)
        if not id then return false, 'container address needs a whole-number id' end
        return Containers.openFor(source, player, id, opts)
    end
    if kind == 'vehicle' then
        local id, refErr = Vehicles.idFromRef(addr.id)   -- a vehicleId or a vehicle reference
        if not id then return false, refErr or 'vehicle address needs a vehicle id' end
        if addr.sub ~= 'trunk' then
            return false, "only a vehicle's 'trunk' opens this way; the glovebox and ignition open from its seat"
        end
        return Vehicles.openTrunkFor(source, player, id, opts)
    end
    if kind == 'player' then return false, "a player's pockets open with OpenPlayerInventory" end
    if kind == 'panel' then return false, 'a panel opens with OpenPanel' end
    if not (StoreKindOwners and StoreKindOwners[kind]) then
        return false, ('"%s" cannot be opened with OpenStore'):format(tostring(kind))
    end

    -- A store kind a resource registered.
    local store, _, err = Stores.fromAddr(addr, { slotOptional = true })
    if not store then return false, err end
    -- The instanceId must start with the kind's own name: one answering 'container:42' would share
    -- a real stash's viewers and its authorisation.
    if type(store.id) ~= 'string' or store.id:sub(1, #kind + 1) ~= kind .. ':' then
        return false, ('store kind "%s" gave the id "%s" — an instanceId must start with "%s:"')
            :format(kind, tostring(store.id), kind)
    end

    local anchor
    if type(opts.coords) == 'table' or type(opts.coords) == 'vector3' or type(opts.coords) == 'vector4' then
        anchor = { x = opts.coords.x, y = opts.coords.y, z = opts.coords.z, range = tonumber(opts.range) or 3.0 }
    end
    local where = { kind = kind, id = addr.id, sub = addr.sub }
    Stores.addViewer(source, store.id, opts.readOnly and 'ro' or nil, anchor, where)
    -- Inside a SecureEvent handler an error before the client hears about it releases this again.
    TrackInvocationLock(function() Stores.removeViewer(source, store.id) end)

    -- The right-hand grid's payload, in the shape a stash's is (Containers.openFor): the page keys
    -- slots by STRING, and reads name / slots / maxWeight from containerDef.
    local contents = Stores.read(store)
    local inv = {}
    for slot, it in pairs(contents.items) do inv[tostring(slot)] = it end
    local payload = Inventory.buildPayload(player)
    payload.containerDef = {
        name      = contents.label,
        slots     = contents.slots,
        -- The page cannot draw an infinite limit; a kind with none shows a large one instead.
        maxWeight = contents.maxWeight ~= math.huge and contents.maxWeight or 9999,
    }
    payload.containerInv    = inv
    payload.containerWeight = contents.weight
    payload.storeId         = store.id   -- what the delta protocol matches (Stores.publishSlots)
    payload.storeAddr       = where
    TriggerClientEvent('whip_core:client:openStore', source, payload)
    return true
end)

--- Take a store off a player's screen: once closed they can move nothing in it. Other viewers are untouched.
--- Answers `true`, or `false, reason` ('That is not open'). A panel closes with ClosePanel.
---@param source number|string|nil
---@param addr table  { kind, id, sub }
---@return boolean ok
---@return string|nil err
exports('CloseStore', function(source, addr)
    source = tonumber(source)
    if not source or type(addr) ~= 'table' then return false, 'CloseStore takes a player and an address' end
    local kind = addr.kind
    local storeId

    -- Not gated on the player still being loaded: a view held by someone who has gone is the one
    -- most worth releasing.
    if kind == 'container' then
        local id = Sanitize.id(addr.id)
        if not id then return false, 'container address needs a whole-number id' end
        storeId = 'container:' .. tostring(id)
        if not Stores.isViewer(source, storeId) then return false, 'That is not open' end
        -- The same three steps as the player's own close (events_containers.lua).
        pcall(Containers.saveInventory, id)
        Containers.release(id, source)
        Containers.unloadInventory(id)
    elseif kind == 'vehicle' then
        local id, refErr = Vehicles.idFromRef(addr.id)   -- a vehicleId or a vehicle reference
        if not id then return false, refErr or 'vehicle address needs a vehicle id' end
        storeId = ('vehicle:%s:%s'):format(tostring(id), tostring(addr.sub))
        if not Stores.isViewer(source, storeId) then return false, 'That is not open' end
        -- The same three steps as the player's own close (events_vehicles.lua).
        pcall(Vehicles.saveInventory, id, addr.sub)
        Vehicles.releaseStorage(id, addr.sub, source)
        Vehicles.unloadIfIdle(id)
    elseif kind == 'panel' then
        return false, 'a panel closes with ClosePanel'
    elseif kind == 'player' then
        return false, "a player's pockets close with ClosePlayerInventory"
    else
        -- A registered kind: found by the address OpenStore kept on the viewer record.
        for sid in pairs(Stores._viewing[source] or {}) do
            local view = Stores._views[sid]
            local rec = view and view.by[source]
            local a = rec and rec.addr
            if a and a.kind == kind and tostring(a.id) == tostring(addr.id) and tostring(a.sub) == tostring(addr.sub) then
                storeId = sid
                break
            end
        end
        if not storeId then return false, 'That is not open' end
        Stores.removeViewer(source, storeId)
    end

    -- The screen: it was showing something the player may no longer touch.
    TriggerClientEvent('whip_core:client:storeClosed', source, storeId)
    return true
end)

-- Stores for other resources: every store has one address `{ kind, id, sub, slot }`, and these verbs go through the
-- same Stores.place / Stores.take / commitMove every drag uses, so weight, filters, typed slots and stacking are
-- one set of rules:
--
--   StoreRead(addr)                          what is in it, its size and its weight
--   StoreCount(addr, item)                   how many of one item
--   StoreGive(addr, item, amount, meta?)     create an item in it (slot optional: wherever it fits)
--   StoreTake(addr, amount?, opts?)          destroy from a slot, or `opts.item` from wherever
--   StoreMove(fromAddr, toAddr, opts?)       move between two stores (the destination slot optional)
--   GetItemAt(addr)                          what is in one slot
--   SetItemMetadata(addr, meta, opts?)       change one item's metadata
--   FindItemByUid(uid)                       the address of one specific item, if it is loaded
--
-- A stash or boot nobody has opened is loaded on demand. `{ kind = 'player', id = source, sub = 'accessory' }` is the
-- accessory strip. Changes are saved, shown to anyone looking and logged; pockets announce itemAdded / itemRemoved.

--- The player whose pockets a store is, if it is.
---@param store table
---@return table|nil player
local function ownerOf(store)
    if store and store.kind.id == 'player' then
        return store.handle and store.handle.player or nil
    end
    return nil
end

--- Make a direct write stick and show it to whoever can see it: pockets are pushed whole to their owner (which
--- also saves and announces the item events); a panel goes through Panels.serverWrote; anything else is saved and
--- its changed slots published to its viewers.
---@param store table
---@param slots number[]
local function finishDirectWrite(store, slots)
    local kindId = store.kind.id
    if kindId == 'player' then
        local owner = store.handle and store.handle.player
        if owner and Players[owner.source] == owner then
            Inventory.syncAndSave(owner.source, owner)
        end
        return
    end
    if kindId == 'panel' then
        for _, slot in ipairs(slots) do
            Panels.serverWrote(store.handle.source, store.handle.session, slot)
        end
        return
    end
    local saved, err = Stores.saveAll({ store })
    if not saved then
        -- Owed, not undone: the flush thread retries (see Stores.saveAll).
        print(('[whip_core:stores] %s changed, save owed: %s'):format(tostring(store.label), tostring(err)))
    end
    Stores.publishSlots(store, slots)
    -- The kind's own side effect of a write that ran no move hooks (a car's ignition: its driver is told)
    if store.kind.afterWrite then
        local ok, hookErr = pcall(store.kind.afterWrite, store.handle, slots)
        if not ok then
            print(('[whip_core:stores] afterWrite hook on kind "%s" errored: %s'):format(tostring(kindId), tostring(hookErr)))
        end
    end
end

--- What a store holds, as plain data. The shape StoreRead answers with.
---@param store table
---@return table
function Stores.read(store)
    local addr = Stores.addressOf(store) or {}
    local out = {
        kind      = addr.kind,
        id        = addr.id,
        sub       = addr.sub,
        label     = store.label,
        slots     = store.kind.slots(store.handle),
        maxWeight = store.kind.maxWeight(store.handle),
        weight    = Stores.weightOf(store),
        items     = {},
    }
    for slot = 1, out.slots do
        local d = store.kind.get(store.handle, slot)
        if d and d.item then
            out.items[slot] = { item = d.item, amount = d.amount, metadata = copyMetadata(d.metadata) }
        end
    end
    return out
end

--- What is in a store: `{ kind, id, sub, label, slots, maxWeight, weight, items = { [slot] = {
--- item, amount, metadata } } }`, keyed by slot number. A copy: changing it changes nothing.
---     local stash = exports.whip_core:StoreRead({ kind = 'container', id = 12 })
---@param addr table  any address; a slot in it is ignored
---@return table|false store
---@return string|nil err
exports('StoreRead', function(addr)
    local store, _, err = Stores.fromAddr(addr, { slotOptional = true })
    if not store then return false, err end
    return Stores.read(store)
end)

--- How many of one item a store holds.
---@param addr table
---@param item string
---@return number|false count
---@return string|nil err
exports('StoreCount', function(addr, item)
    local store, _, err = Stores.fromAddr(addr, { slotOptional = true })
    if not store then return false, err end
    local count = 0
    for slot = 1, store.kind.slots(store.handle) do
        local d = store.kind.get(store.handle, slot)
        if d and d.item == item then count = count + (d.amount or 1) end
    end
    return count
end)

--- Create an item in any store.
---     local slot, err = exports.whip_core:StoreGive({ kind = 'container', id = 12 }, 'drink', 5)
--- With a `slot` in the address it goes into exactly that slot (stacking onto the same item) or is refused. Without
--- one it goes wherever it fits, across several slots if needed, all of it or none. The answer is the (first) slot.
--- The item must be registered and the amount a whole number (nil = 1). An item with a default-metadata generator
--- (a gun's serial) gets fresh metadata per slot when you pass none.
--- For a reward into a player's pockets AddItem is still the call: when full it drops at their feet.
---@param addr table
---@param item string|nil  anything but a known item key is refused, with the reason
---@param amount number|nil
---@param metadata table|nil
---@param opts string|table|nil  a reason for the activity log, or { reason = '...' }
---@return number|false slot
---@return string|nil err
function Stores.giveAt(addr, item, amount, metadata, opts)
    local askedBy = Log.byCaller() or 'by whip_core'   -- before anything can yield
    local why = Log.reasonFrom(type(opts) == 'table' and opts.reason or opts) or askedBy

    if type(item) ~= 'string' or not Config.Items[item] then
        return false, ('Unknown item "%s"'):format(tostring(item))
    end
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    if metadata ~= nil and type(metadata) ~= 'table' then return false, 'metadata must be a table' end
    -- One the database can hold, refused here rather than failing the next save.
    if metadata ~= nil then
        local okData, what = Inventory.saveableData(metadata)
        if not okData then return false, ('metadata cannot be saved: %s'):format(what) end
    end

    local store, slot, err = Stores.fromAddr(addr, { slotOptional = true })
    if not store then return false, err end

    local def = Config.Items[item]
    local perSlot = (def.stack and def.maxStack) and def.maxStack or 1

    -- A generator mints IDENTITY (a serial), so each slot gets its own call — see Inventory.addItem.
    -- Told who it is for when the store is a player's (Inventory.metaContext); nobody's otherwise.
    local gen = metadata == nil and Inventory.MetaGenerators[item] or nil
    local forWhom = gen and ownerOf(store) or nil
    local metaCtx = Inventory.metaContext(forWhom and forWhom.source or nil, 'given')
    local function metaFor()
        if metadata ~= nil or gen == nil then return metadata end
        return Inventory.runMetaGen(gen, item, metaCtx)
    end

    local placed = {}   -- { slot, amount } in order, for the all-or-nothing undo
    local function undo()
        for i = #placed, 1, -1 do Stores.take(store, placed[i].slot, placed[i].amount) end
    end

    if slot then
        -- Stores.place checks the stack limit only when MERGING; an empty slot took any amount.
        if amount > perSlot then
            return false, ('only %d %s fit in one slot'):format(perSlot, item)
        end
        local ok, placeErr = Stores.place(store, slot, item, amount, metaFor())
        if not ok then return false, placeErr end
        placed[1] = { slot = slot, amount = amount }
    else
        -- An item the store never takes says so, rather than "No room there".
        if store.kind.allows and not store.kind.allows(store.handle, item, metadata) then
            return false, 'That item does not go there'
        end
        local remaining = amount
        while remaining > 0 do
            local chunk = math.min(remaining, perSlot)
            local meta = metaFor()
            local at = Stores.slotAccepting(store, item, chunk, meta)
            if not at then
                undo()
                return false, 'No room there'
            end
            local ok, placeErr = Stores.place(store, at, item, chunk, meta)
            if not ok then
                undo()
                return false, placeErr
            end
            placed[#placed + 1] = { slot = at, amount = chunk }
            remaining = remaining - chunk
        end
    end

    local slots = {}
    for i, p in ipairs(placed) do slots[i] = p.slot end

    local owner = ownerOf(store)
    if owner then Inventory.noteChangeReason(owner.source, why, askedBy) end
    finishDirectWrite(store, slots)

    -- An item made from nothing by the calling resource (Log.gained in activity_log.lua).
    Log.gained(owner and owner.charId or nil, item, amount, why .. ' · into ' .. Log.storeLabel(store))
    return slots[1]
end
exports('StoreGive', Stores.giveAt)

--- Take items out of any store, destroying them (to put them somewhere, use StoreMove).
---     local taken, err = exports.whip_core:StoreTake({ kind = 'container', id = 12, slot = 3 }, 2)
---     local taken, err = exports.whip_core:StoreTake({ kind = 'container', id = 12 }, 5, { item = 'drink' })
--- With a slot in the address: from that slot (amount nil = the whole stack). Without one, name the item in
--- `opts.item` and it is taken from wherever it is, all or none. The answer is `{ item, amount, metadata }`
--- (metadata only when it came from one slot).
---@param addr table
---@param amount number|nil
---@param opts table|nil  { item = 'drink', reason = '...' }
---@return table|false taken
---@return string|nil err
---@param askedBy string|nil  'by <resource>' for the log; nil is whip_core
function Stores.takeAt(addr, amount, opts, askedBy)
    askedBy = askedBy or 'by whip_core'
    local o = type(opts) == 'table' and opts or {}
    -- `opts` or a plain reason string, as AddItem / StoreGive take it.
    local why = Log.reasonFrom(opts) or askedBy

    local store, slot, err = Stores.fromAddr(addr, { slotOptional = true })
    if not store then return false, err end

    local removed, slots
    if slot then
        if amount ~= nil then
            amount = Sanitize.amount(amount)
            if not amount then return false, Sanitize.AMOUNT_ERR end
        end
        local ok, takeErr, stack = Stores.take(store, slot, amount)
        if not ok then return false, takeErr end
        ---@cast stack -nil   -- a take that went through answers what it took
        removed, slots = stack, { slot }
    else
        local item = o.item
        if type(item) ~= 'string' then
            return false, 'name the slot in the address, or the item in opts.item'
        end
        amount = Sanitize.amount(amount, 1)
        if not amount then return false, Sanitize.AMOUNT_ERR end

        -- Count first, so a short store changes nothing.
        local total, n = 0, store.kind.slots(store.handle)
        for s = 1, n do
            local d = store.kind.get(store.handle, s)
            if d and d.item == item then total = total + d.amount end
        end
        if total < amount then
            return false, ('Not enough %s there (%d of %d)'):format(item, total, amount)
        end

        -- Last slots first, the same order RemoveItem takes from the pockets. Each take's answer is
        -- read (a satellite kind's write can refuse): on a shortfall what came out goes back.
        local remaining = amount
        local taken = {}   -- { slot, stack }
        slots = {}
        for s = n, 1, -1 do
            if remaining <= 0 then break end
            local d = store.kind.get(store.handle, s)
            if d and d.item == item then
                local part = math.min(d.amount, remaining)
                local ok, _, stack = Stores.take(store, s, part)
                if ok then
                    taken[#taken + 1] = { slot = s, stack = stack }
                    slots[#slots + 1] = s
                    remaining = remaining - part
                end
            end
        end
        if remaining > 0 then
            for i = #taken, 1, -1 do
                local t = taken[i]
                if t.stack then Stores.place(store, t.slot, t.stack.item, t.stack.amount, t.stack.metadata) end
            end
            if #slots > 0 then finishDirectWrite(store, slots) end
            return false, ('Could not take all of the %s (the store refused a write)'):format(item)
        end
        removed = { item = item, amount = amount }
    end

    local owner = ownerOf(store)
    if owner then Inventory.noteChangeReason(owner.source, why, askedBy) end
    finishDirectWrite(store, slots)

    -- From ONE slot it is a specific item, written on its own timeline (Log.item); by item, across
    -- slots, it is a count (Log.lost).
    if slot then
        Log.item(owner and owner.charId or nil, 'lost', removed,
            { amount = removed.amount, detail = why .. ' · from ' .. Log.storeLabel(store) })
    else
        Log.lost(owner and owner.charId or nil, removed.item, removed.amount, why .. ' · from ' .. Log.storeLabel(store))
    end
    return removed
end

exports('StoreTake', function(addr, amount, opts)
    local askedBy = Log.byCaller()   -- the caller first, before anything can yield
    -- Not out of a store a bank payment holds still (Stores.freeze: the ATM, a Sell card).
    local store = Stores.fromAddr(addr, { slotOptional = true })
    if store and store.unit and Stores.isFrozen(store.unit) then return false, 'Paying — wait a moment' end
    return Stores.takeAt(addr, amount, opts, askedBy)
end)

--- The store and slot an address names, with the slot checked against the store's real size.
---@return table|nil store
---@return number|nil slot
---@return string|nil err
local function slotOf(addr)
    local store, slot, err = Stores.fromAddr(addr)
    if not store then return nil, nil, err end
    if slot > store.kind.slots(store.handle) then return nil, nil, 'Invalid slot' end
    return store, slot
end

--- What is in one slot of any store: `{ item, amount, metadata }` (a copy), nil when empty, or `false, reason` when
--- the address is wrong (an export drops every value after a nil, so `false, reason` keeps the reason).
---     local item = exports.whip_core:GetItemAt(addr)
---@param addr table  an address WITH a slot
---@return table|false|nil item
---@return string|nil err  only with false
function Stores.itemAt(addr)
    local store, slot, err = slotOf(addr)
    if not store then return false, err end
    local d = store.kind.get(store.handle, slot)
    if not d or not d.item then return nil end
    return { item = d.item, amount = d.amount, metadata = copyMetadata(d.metadata) }
end
exports('GetItemAt', Stores.itemAt)

-- The item in a player's hand: the resource that puts an item in the hand says which slot (SetHeldItem); anyone
-- can ask (GetHeldItem). Only that resource changes or clears the record; it goes when the resource stops, at
-- logout and when the player leaves. The record notes the item and its serial, so a slot that no longer holds it
-- answers nil.

--- [source] = { sub, slot, item, serial }. Written only through heldReg (below), which keeps who said so.
Stores._held = {}

--- The player's own game is told each change (client/inventory.lua), so an action's `require = { held = ... }` is
--- checked there without crossing into any resource: { item, sub, slot }, or false for an empty hand.
local function tellHand(source, rec)
    if not GetPlayerName(source) then return end   -- gone: nobody to tell
    TriggerClientEvent('whip_core:client:heldItem', source,
        type(rec) == 'table' and { item = rec.item, sub = rec.sub, slot = rec.slot } or false)
end

--- On the one registry rule (shared/registry.lua): the record is the resource's that set it,
--- another running resource is refused naming it, and a stopped resource's records are swept. Every add, change and
--- removal (a sweep and a logout too) goes through the hooks, so the player's game always hears it.
local heldReg = Registry.new('heldItem', {
    label = 'item in hand', store = Stores._held,
    onAdd = function(source, rec) tellHand(source, rec) end,
    onRemove = function(source) tellHand(source, nil) end,
})

--- Put an item in a player's hand (addr, one of their pocket slots), or take it out of it (nil).
---@param source number|string|nil
---@param addr table|nil  { kind = 'player', id = source, sub = 'player'|'accessory', slot = n }
---@param owner string    the resource saying so
---@return boolean ok
---@return string|nil why
function Stores.setHeld(source, addr, owner)
    source = tonumber(source)
    if not source or not Players[source] then return false, 'Player not loaded' end
    if addr == nil then
        if Stores._held[source] == nil then return true end
        local ok, why = heldReg:remove(owner, source)
        if not ok then return false, why end
        return true
    end
    if type(addr) ~= 'table' or addr.kind ~= 'player' or tonumber(addr.id) ~= source then
        return false, 'the hand holds one of the player\'s own pocket slots'
    end
    local store, slot, err = Stores.fromAddr(addr)
    if not store then return false, err end
    local d = store.kind.get(store.handle, slot)
    if not d or not d.item then return false, 'That slot is empty' end
    local ok, why = heldReg:add(owner, source, { sub = addr.sub or 'player', slot = slot, item = d.item,
        serial = type(d.metadata) == 'table' and d.metadata.serial or nil })
    if not ok then return false, why --[[@as string]] end
    return true
end

--- The item in a player's hand, live (its slot's own table, for whip_core to change), with its address and
--- store; nil when nothing is held or it is no longer in that slot.
---@param source number
---@return table|nil slotData
---@return table|nil addr
---@return table|nil store
function Stores.held(source)
    local h = Stores._held[tonumber(source)]
    if not h then return nil end
    local store = Stores.player(source, h.sub)
    local d = store and store.kind.get(store.handle, h.slot)
    if not d or d.item ~= h.item then return nil end
    if h.serial ~= nil and (type(d.metadata) ~= 'table' or d.metadata.serial ~= h.serial) then return nil end
    return d, { kind = 'player', id = tonumber(source), sub = h.sub, slot = h.slot }, store
end

--- SetHeldItem(source, addr): the resource drawing an item into a player's hand says which slot it is; nil when it
--- is put away. Answers true, or false and why.
exports('SetHeldItem', function(source, addr)
    return Stores.setHeld(source, addr, Registry.caller())
end)

--- GetHeldItem(source): what the player holds, as GetItemAt answers it plus its `addr`; nil when nothing.
exports('GetHeldItem', function(source)
    local d, addr = Stores.held(source)
    if not d then return nil end
    return { addr = addr, item = d.item, amount = d.amount, metadata = copyMetadata(d.metadata) }
end)

-- At logout (and a drop) the hand is empty, whoever said otherwise. A stopped resource's records: the registry.
Character.onLife('logout', function(e)
    local src = e and e.source
    if src and Stores._held[src] ~= nil then heldReg:remove(heldReg:ownerOf(src) --[[@as string]], src) end
end)

--- Change the metadata of the item at an address (any store).
---     exports.whip_core:SetItemMetadata(addr, { ammo = 30 })                  -- only ammo changes
---     exports.whip_core:SetItemMetadata(addr, nil, { remove = { 'label' } })   -- take a key away
--- It merges: only the keys you pass change.
---   replace = true   the table you pass becomes the whole metadata (nil with it clears it all)
---   remove = {...}   keys to take away
---   quiet = true   for a player's pockets: save without pushing the inventory to the client, for a value changed
---                  many times a second that the client learns another way. Anything the player should see must not be quiet.
--- The item's `uid` is kept (pass `uid = false` to clear it), and anything that can't be saved is refused before
--- anything changes. True once the slot has changed, even if the save must be retried: memory is the truth.
---@param addr table  an address WITH a slot
---@param metadata table|nil  the keys to change (nil only with replace or remove)
---@param opts table|nil  { replace = boolean, remove = string[], quiet = boolean }
---@return boolean ok
---@return string|nil err
exports('SetItemMetadata', function(addr, metadata, opts)
    local store, slot, err = slotOf(addr)
    if not store then return false, err end
    opts = type(opts) == 'table' and opts or {}

    local kind, handle = store.kind, store.handle
    -- Not refused during a bank payment's hold (Stores.freeze), on purpose: satellites undo with it
    -- (whip_gunny's unload takes the rounds back if the magazine write fails), and a refusal would
    -- leave the rounds twice. A jerry can poured while its fill is paid for is refused by whip_fuel.
    local d = kind.get(handle, slot)
    if not d or not d.item then return false, 'Empty slot' end

    -- Built and checked first; nothing in the slot changes until it has passed.
    local new, buildErr = Inventory.buildMetadata(d.metadata, metadata, {
        replace = opts.replace == true,
        remove  = opts.remove,
    })
    if new == false then return false, buildErr end

    local owner = ownerOf(store)
    if owner then
        -- Heavier with it (a gun loaded, a bag filled through its metadata): held to the limits as anything coming
        -- into the pockets is, its own container's and the pockets' together (Stores.pocketsOver). Lighter, or the
        -- same, is never refused (a shot, a pour).
        local gained = Inventory.effectiveWeight(d.item, d.amount, new) - Inventory.effectiveWeight(d.item, d.amount, d.metadata)
        if gained > 0 and (Stores.weightOf(store) + gained > kind.maxWeight(handle) or Stores.pocketsOver(store, gained, nil)) then
            return false, 'Too heavy'
        end
        -- In place for the pockets: a running use handler holds this very table, and
        -- Inventory.useItem tells "the stack I was using" from "one that moved in" by identity.
        d.metadata = new
        if opts.quiet == true then
            if not Inventory.saveQuietly(owner.source, owner) then
                print(('[whip_core:stores] SetItemMetadata: %s slot %d changed, save owed (will retry)')
                    :format(tostring(store.label), slot))
            end
        else
            finishDirectWrite(store, { slot })
        end
        return true
    end

    -- Any other kind is written through its own set (a satellite kind's get answers with a copy),
    -- and its answer is read.
    if not kind.set(handle, slot, d.item, d.amount, new) then
        return false, 'That slot could not be written'
    end
    finishDirectWrite(store, { slot })
    return true
end)

--- Where the first item `has(d)` is true of is: `{ kind, id, sub?, slot }`, or nil. Looks through what is loaded
--- (online pockets, in-memory stashes, boots and panels, the ground); an item in an untouched stash or inside a bag
--- is not found.
---@param has fun(d: table): boolean
---@return table|nil addr
local function findLoaded(has)
    for src, player in pairs(Players) do
        if player.inventory then
            for _, c in ipairs(PlayerContainers) do
                for slot, d in pairs(player.inventory[c] or {}) do
                    if has(d) then return { kind = 'player', id = src, sub = c, slot = slot } end
                end
            end
        end
    end
    for containerId, inv in pairs(Containers.invCache or {}) do
        for slot, d in pairs(inv) do
            if has(d) then return { kind = 'container', id = containerId, slot = slot } end
        end
    end
    for vehicleId, inv in pairs(Vehicles.invCache or {}) do
        for storageType, slotsOf in pairs(inv) do
            for slot, d in pairs(slotsOf) do
                if has(d) then return { kind = 'vehicle', id = vehicleId, sub = storageType, slot = slot } end
            end
        end
    end
    local panelId, panelSlot = Panels.findSlot(has)
    if panelId ~= nil then return { kind = 'panel', id = panelId, slot = panelSlot } end
    for id, row in pairs(GroundItems and GroundItems.cache or {}) do
        if has(row) then return { kind = 'ground', id = id } end
    end
    return nil
end

--- Where one specific item is, by its uid — `{ kind, id, sub?, slot }`, or nil. Loaded places only (findLoaded).
---@param uid string
---@return table|nil addr
exports('FindItemByUid', function(uid)
    if uid == nil or uid == '' then return nil end
    return findLoaded(function(d) return type(d) == 'table' and type(d.metadata) == 'table' and d.metadata.uid == uid end)
end)

--- Where an item whose metadata `key` holds `value` is — `{ kind, id, sub?, slot }`, or nil: the first found, so for
--- a value one item carries (a gun's serial). Loaded places only (findLoaded); GetItemAt(addr) reads it.
---
---     exports.whip_core:FindItemByMeta('serial', 'AB12CD34EF56')
---@param key string
---@param value any  compared with ==
---@return table|nil addr
exports('FindItemByMeta', function(key, value)
    if type(key) ~= 'string' or key == '' or value == nil then return nil end
    return findLoaded(function(d) return type(d) == 'table' and type(d.metadata) == 'table' and d.metadata[key] == value end)
end)
