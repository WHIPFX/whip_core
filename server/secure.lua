-- ============================================
-- SECURE EVENT & CALLBACK SYSTEM
-- Automatic validation, rate limiting, ACE gates,
-- player checks, and live monitoring for dev tools
-- ============================================

local _secureEventRegistry = {}   -- { [eventName] = { schema, resource, calls, rejects, lastCall } }

--- The Event Monitor's scrollback: TWO ring buffers, so success traffic can never evict the
--- refusals anyone wants to find. Both are recorded always, so the monitor reopens onto full
--- history. Local: the monitor's snapshot (emBuildLogArray) is the way in.
local SECURE_LOG_MAX = 500  -- per ring
local _emRingOk  = { buf = {}, head = 0, count = 0 }   -- 'ok'
local _emRingRej = { buf = {}, head = 0, count = 0 }   -- 'rejected' + 'error'

--- Monotonic sequence stamped on every entry (os.time() can't order a busy second): the total
--- order the two-ring merge and the NUI's feed sort by. Never reset, not even by Clear.
local _secureEventSeq = 0

--- { [source] = true } — Event Monitor dev tool viewers. Swept in this file (playerDropped, below).
local _secureEventViewers = {}

--- The most recent outcome per event name: { [eventName] = { status, reason, n } }. Separate from
--- the rings so eviction can never erase it (a test asks "what happened last to THIS event").
--- Created once per name and mutated in place. `n` counts every outcome: whip_test reads it to tell
--- "the server has finished with my request" from "the client sent it".
local _secureEventLastStatus = {}

--- What other files may ask about the two tables above (only the test seams do, server/testseams.lua).
SecureEvents = {}

--- Is this event — or 'cb:<name>' for a callback — registered through SecureEvent / SecureCallback?
---@param eventName string
---@return boolean
function SecureEvents.isRegistered(eventName)
    return _secureEventRegistry[eventName] ~= nil
end

--- The most recent outcome recorded for an event: { status, reason, n }, or nil when it has none.
--- Live: read it, do not keep or change it.
---@param eventName string
---@return table|nil
function SecureEvents.lastStatus(eventName)
    return _secureEventLastStatus[eventName]
end

--- Profiler scopes, bound once: not guaranteed to exist on every build, and an absent one would throw
--- inside every secure event. Locals also skip a global lookup per call.
local ProfilerEnterScope = ProfilerEnterScope or function() end
local ProfilerExitScope  = ProfilerExitScope  or function() end

-- ============================================
-- Internal: Parameter Validation
-- ============================================

--- A number off the wire: a number, or a string that reads as one (JavaScript often sends numbers as
--- strings). Anything else is nil here, so a declared default still answers for it.
---@return number|nil
local function wireNumber(raw)
    if type(raw) == 'number' then return raw end
    if type(raw) == 'string' then return tonumber(raw) end
    return nil
end

--- Is this another resource's function, as it arrives here? A function that crosses an export (or
--- sits inside a table that did) is a TABLE carrying `__cfx_functionReference`, callable through its
--- metatable — and INDEXING IT FOR ANY OTHER KEY THROWS ("Cannot index a funcref"). So a table is
--- only ever inspected with rawget, which bypasses that. See the house rule on export callables.
---
--- A net event can carry one too (a client's msgpack payload); validateParam refuses one for every type.
---@return boolean
local function isFuncRef(v)
    if type(v) ~= 'table' then return false end
    if rawget(v, '__cfx_functionReference') ~= nil then return true end
    -- Belt and braces, should the field ever be named differently: anything callable through its
    -- metatable is a function here, not a position.
    local mt = getmetatable(v)
    return type(mt) == 'table' and rawget(mt, '__call') ~= nil
end

--- Validate and sanitize a single parameter against its schema definition.
--- @param raw any          The raw value from the client
--- @param pDef table       Schema definition: {'name', 'type', ...}
--- @param src number       Invoking player, for types whose validity depends on who is asking
--- @return any sanitized   The sanitized value (or nil on failure)
--- @return string|nil reason  Error reason if validation failed
--- @return string|nil say  what the player is told, when the refusal is one they can meet honestly
local function validateParam(raw, pDef, src)
    local name    = pDef[1]
    local pType   = pDef[2]

    -- Not a function, whatever the type: 'slot', 'addr' and record lists index what they are given,
    -- and indexing a function reference throws.
    if isFuncRef(raw) then return nil, name .. ': a function is not a value' end

    if pType == 'int' then
        local min, max, default = pDef[3], pDef[4], pDef[5]
        local n = wireNumber(raw)
        if n == nil then
            if default ~= nil then return default, nil end
            return nil, name .. ': expected number, got ' .. type(raw)
        end
        return Sanitize.int(n, min, max, default), nil

    elseif pType == 'number' then
        local min, max, default = pDef[3], pDef[4], pDef[5]
        local n = wireNumber(raw)
        if n == nil then
            if default ~= nil then return default, nil end
            return nil, name .. ': expected number, got ' .. type(raw)
        end
        return Sanitize.number(n, min, max, default), nil

    elseif pType == 'id' then
        -- An address: a player, a vehicle, a ban, a slot, a door. {'name', 'id', min?, max?}
        -- (min defaults to 1). Rejected when out of range or not a whole number, never clamped (as
        -- 'int' does, which must not be used for these). See Sanitize.id.
        local val = Sanitize.id(raw, pDef[3], pDef[4])
        if val == nil then
            return nil, name .. ': invalid id'
        end
        return val, nil

    elseif pType == 'amount' then
        -- Money, or how many of something: {'name', 'amount', max?}. A whole number of 1 or more,
        -- refused otherwise (Sanitize.amount, as every item and bank call). 'int' would clamp.
        local val = Sanitize.amount(raw)
        if val == nil or (pDef[3] and val > pDef[3]) then
            return nil, name .. ': ' .. Sanitize.AMOUNT_ERR
        end
        return val, nil

    elseif pType == 'string' then
        local maxLen, default = pDef[3], pDef[4]
        local val = Sanitize.string(raw, maxLen, default)
        if val == '' and default == nil then
            return nil, name .. ': empty string'
        end
        return val, nil

    elseif pType == 'key' then
        -- Rejected, never corrected (as 'id'): a key names something, and cleaning it could name
        -- something else ('legion.sq' -> 'legionsq'). Anything the cleaner would change is refused.
        local maxLen = pDef[3]
        local val = Sanitize.key(raw, maxLen)
        if val == nil or val ~= raw then
            return nil, name .. ': invalid key'
        end
        return val, nil

    elseif pType == 'enum' then
        local allowed, default = pDef[3], pDef[4]
        local val = Sanitize.enum(raw, allowed, default)
        if val == nil then
            return nil, name .. ': invalid enum value'
        end
        return val, nil

    elseif pType == 'bool' then
        -- What the sender meant, not Lua truthiness ("false" and 0 are false). Anything else takes
        -- the declared default, or is refused.
        if raw == true or raw == 1 or raw == 'true' or raw == '1' then return true, nil end
        if raw == false or raw == 0 or raw == 'false' or raw == '0' or raw == '' then return false, nil end
        if raw == nil then return pDef[3] == true, nil end
        if pDef[3] ~= nil then return pDef[3] == true, nil end
        return nil, name .. ': expected true or false'

    elseif pType == 'addr' then
        -- A store address: { kind, id?, sub?, slot }. Resolved AND authorized here, so a handler
        -- receives a store this player is entitled to touch, or never runs. Returns { store, slot }
        -- so the slot travels with it.
        --
        -- pDef[3] options: { slotOptional = true } takes a WHOLE store (an address with no slot, for
        -- a handler that picks the slot itself, quickMove's destination); `slot` comes back nil.
        local store, slot, err = Stores.fromWire(src, raw, pDef[3])
        if not store then
            return nil, name .. ': ' .. tostring(err)
        end
        return { store = store, slot = slot }, nil

    elseif pType == 'vehicle' then
        -- A vehicle THIS PLAYER MAY ACT ON: resolved and authorised here, as 'addr' does for stores.
        --
        -- pDef[3] options: { session = true } also accepts an adopted street car (no owner to
        -- compare). { anyOwner = true } accepts a car whoever owns it, for an action anyone at the
        -- car may take (fitting a part: anyone can modify anyone's vehicle); pair it with `near`.
        --
        -- The id is rejected, not clamped: correcting an address would name a different vehicle.
        local opts = pDef[3] or {}

        local id = Sanitize.id(raw, 1)
        if not id then
            return nil, name .. ': must be a whole vehicle id'
        end

        -- The third answer is for the player: a bad id is a forged request and stays silent; "not
        -- yours" and "gone" are what a player meets pressing a real option, so SecureEvent shows them.
        local def = Vehicles and Vehicles.getDef and Vehicles.getDef(id)
        if not def then
            return nil, name .. ': no such vehicle', 'That vehicle is not there any more'
        end

        if def.session then
            -- An adopted street car belongs to nobody, so ownership cannot be tested.
            -- Only handlers that opt in may name one.
            if not opts.session then return nil, name .. ': not your vehicle', 'That is not your vehicle' end
        elseif opts.anyOwner then
            -- Any owner's car, by the handler's declaration (see above).
        else
            local player = Players and Players[src]
            if not player or def.ownerCharId ~= player.charId then
                return nil, name .. ': not your vehicle', 'That is not your vehicle'
            end
        end

        -- The record authorises; a snapshot (Vehicles.context) is handed over, never the live
        -- record. Occupants stay off (they walk every player). No fallback to `def`: context can't
        -- answer nil here, and a fallback would hand over the live record.
        return Vehicles.context(id), nil

    elseif pType == 'slot' then
        -- A slot in the caller's own pockets: {'name', 'slot', opts?}. "The item the player clicked",
        -- checked (not empty, the right item) before the handler runs.
        --
        -- The client sends a slot number (the main pockets), or { sub = 'accessory', slot = 3 }.
        --
        -- The handler gets { addr = {kind='player', id, sub, slot}, item, amount, metadata } — the
        -- address every slot call takes, and a COPY of what is in it. Refused when the slot is
        -- empty, or holds the wrong item: both a player meets when the item moved since they
        -- pressed, so they are told. Another pocket or a bad slot number is forged and stays silent.
        --
        -- opts: { item = 'key' | { 'key', ... }, allowEmpty = true }
        local opts = pDef[3] or {}
        local sub, slotNum = 'player', raw
        if type(raw) == 'table' then
            sub, slotNum = raw.sub or 'player', raw.slot
        end

        local isPocket = false
        for _, pocket in ipairs(PlayerContainers or { 'player' }) do
            if pocket == sub then isPocket = true; break end
        end
        if not isPocket then return nil, name .. ': not one of your pockets' end

        local maxSlot = (Config.ContainerSlots and Config.ContainerSlots[sub]) or 500
        local slot = Sanitize.id(slotNum, 1, maxSlot)
        if not slot then return nil, name .. ': invalid slot' end

        local player = Players and Players[src]
        if not player or not player.inventory then return nil, name .. ': no inventory' end

        local addr = { kind = 'player', id = src, sub = sub, slot = slot }
        local data = Inventory.getSlot(player.inventory, sub, slot)
        if not data then
            if opts.allowEmpty then return { addr = addr }, nil end
            return nil, name .. ': that slot is empty', 'That item is not there any more'
        end

        if opts.item ~= nil then
            local wanted = type(opts.item) == 'table' and opts.item or { opts.item }
            local match = false
            for _, key in ipairs(wanted) do
                if data.item == key then match = true; break end
            end
            if not match then return nil, name .. ': not the right item', 'That slot holds something else now' end
        end

        return {
            addr     = addr,
            item     = data.item,
            amount   = data.amount,
            metadata = Inventory.copyMetadata(data.metadata),
        }, nil

    elseif pType == 'list' then
        -- A list, checked entry by entry: {'name', 'list', entry, max?}
        --
        -- `entry` is one param definition every entry must pass — {'mod', 'int', 0, 50} — or a
        -- list of them, for entries that are tables: { {'slot', 'id', 1, 50}, {'index', 'int', -1, 99} }
        -- checks each entry's `slot` and `index` fields and hands back only those. `max` caps the
        -- length (default 50). (whip_autos' shopping basket, a list of pairs, is the case.)
        local entry, max = pDef[3], pDef[4] or 50
        if type(raw) ~= 'table' then return nil, name .. ': expected a list' end
        if type(entry) ~= 'table' then return nil, name .. ': the schema gives no entry type' end

        local n = #raw
        local count = 0
        for k in pairs(raw) do
            if math.type(k) ~= 'integer' or k < 1 or k > n then
                return nil, name .. ': expected a list (1, 2, 3...), not a table with other keys'
            end
            count = count + 1
        end
        if count ~= n then return nil, name .. ': the list has gaps' end
        if n > max then return nil, ('%s: at most %d entries'):format(name, max) end

        local isRecord = type(entry[1]) == 'table'
        local out = {}
        for i = 1, n do
            local el = raw[i]
            if isRecord then
                if type(el) ~= 'table' or isFuncRef(el) then return nil, ('%s[%d]: expected a table'):format(name, i) end
                local rec = {}
                for _, fDef in ipairs(entry) do
                    local v, why = validateParam(el[fDef[1]], fDef, src)
                    if why then return nil, ('%s[%d].%s'):format(name, i, why) end
                    rec[fDef[1]] = v
                end
                out[i] = rec
            else
                local v, why = validateParam(el, entry, src)
                if why then return nil, ('%s[%d]: %s'):format(name, i, why) end
                out[i] = v
            end
        end
        return out, nil

    elseif pType == 'player' then
        -- ANOTHER PLAYER, by server id: {'target', 'player', { range = 3, notSelf = true }}. The checks every
        -- "do something to them" handler wrote by hand: online with a character loaded, not in the character
        -- creator, in the caller's routing bucket, within `range` metres (default 3), and not the caller unless
        -- notSelf = false. The handler gets their light sheet (source, charId, names, isDead). A refusal the
        -- player can meet honestly (they walked off) is shown in plain words; a forged id stays silent.
        local opts = type(pDef[3]) == 'table' and pDef[3] or {}
        local id = Sanitize.id(wireNumber(raw))
        if not id then return nil, name .. ': expected a server id' end
        if id == src and opts.notSelf ~= false then return nil, name .. ': not yourself', 'Not on yourself' end
        local target = Players and Players[id]
        if not target or not target.charId or target._inCreator
            or GetPlayerRoutingBucket(id) ~= GetPlayerRoutingBucket(src) then
            return nil, name .. ': not here', 'They are not here'
        end
        if id ~= src then
            local range = tonumber(opts.range) or 3.0
            local pc, tc = GetEntityCoords(GetPlayerPed(src)), GetEntityCoords(GetPlayerPed(id))
            local dx, dy, dz = tc.x - pc.x, tc.y - pc.y, tc.z - pc.z
            if (dx * dx + dy * dy + dz * dz) > range * range then
                return nil, name .. ': too far', 'They are too far away'
            end
        end
        return target:lightSheet(), nil

    elseif pType == 'record' then
        -- ONE TABLE OF NAMED FIELDS, each checked like a list entry's:
        -- {'args', 'record', { {'accountId', 'id'}, {'note', 'string', 200} }}. Hands back only those fields.
        local fields = pDef[3]
        if type(raw) ~= 'table' then return nil, name .. ': expected a table' end
        if type(fields) ~= 'table' then return nil, name .. ': the schema gives no fields' end
        local rec = {}
        for _, fDef in ipairs(fields) do
            local v, why, say = validateParam(raw[fDef[1]], fDef, src)
            if why then return nil, ('%s.%s'):format(name, why), say end
            rec[fDef[1]] = v
        end
        return rec, nil

    elseif pType == 'any' then
        return raw, nil

    else
        return nil, name .. ': unknown param type "' .. tostring(pType) .. '"'
    end
end

--- Every param, into `out`. Answers nil, or the first refusal's reason. Run under pcall by both
--- wrappers, so anything a check throws on (a function reference buried where no check expects one)
--- is a refusal like any other, recorded and throttled, rather than an unattributed SCRIPT ERROR.
---@return string|nil reason
---@return string|nil say  what the player is told, when the refusal is one they can meet honestly (validateParam)
local function validateAll(params, args, src, out)
    for i, pDef in ipairs(params) do
        local val, reason, say = validateParam(args[i], pDef, src)
        if reason then return reason, say end
        out[i] = val
    end
    return nil
end

--- What a SATELLITE's handler is handed for an 'addr' param: the address and a copy of what is in
--- the slot — { addr, item, amount, metadata } — never whip's store object (its handle holds the
--- live player and cache, and everything crossing an export is copied). whip_core's own handlers
--- keep { store, slot }.
local function addrForSatellite(value)
    if type(value) ~= 'table' or value.store == nil then return value end
    local store, slot = value.store, value.slot
    local out = { addr = Stores.addressOf(store, slot) }
    if slot and store.kind and store.kind.get then
        local ok, data = pcall(store.kind.get, store.handle, slot)
        if ok and type(data) == 'table' then
            out.item, out.amount = data.item, data.amount
            out.metadata = Inventory.copyMetadata(data.metadata)
        end
    end
    return out
end

--- The params as a satellite's handler receives them: 'addr' values in their address form.
--- Untouched (the same table) when the schema has none.
---@param params table
---@param sanitized table
---@return table
local function paramsForSatellite(params, sanitized)
    local out
    for i, pDef in ipairs(params) do
        if pDef[2] == 'addr' then
            out = out or table.move(sanitized, 1, #params, 1, {})
            out[i] = addrForSatellite(sanitized[i])
        end
    end
    return out or sanitized
end

-- ============================================
-- Invocation Locks — framework-guaranteed release
-- ============================================
--
-- Locks a handler takes (a container, a vehicle storage, a ground item) are registered as they are
-- taken, and anything still held when the handler ERRORS is released automatically, or an error
-- would leave it "in use" until a restart. A handler that returns normally keeps its locks
-- (openContainer holds its lock until the client closes it).
--
-- One record per running handler, holding that call's locks and whether it refused
-- (RecordEventRejection). Handlers yield, so calls interleave and need their own records.
--
-- A call from inside a handler finds its record by one of three routes:
--
--   1. The coroutine the wrapper ran the handler on (whip_core's own handlers).
--   2. The event name and source: a satellite's calls into whip_core arrive on a fresh coroutine
--      (CfxLua runs every cross-resource call with CreateThreadNow), so route 1 finds nothing.
--   3. The resource, when it has exactly one handler running: the common case for a satellite that
--      passes no name. Only for satellites: whip_core's own lock helpers also run outside handlers,
--      where "do nothing" is right.

local _invocationByCo = setmetatable({}, { __mode = 'k' })   -- [coroutine] = record
local _openByKey      = {}                                     -- ['name|src'] = { record, ... }, oldest first
local _openBySrc      = {}                                     -- [src] = handlers running for that player

---@param name string  the registry name: the event, or 'cb:<name>' for a callback
---@param src number|nil
local function invocationKey(name, src)
    return tostring(name) .. '|' .. tostring(src)
end

--- Open the record for a handler about to run, on the coroutine that will run it.
---@param name string
---@param src number
---@param resource string  the handler's owner
---@return table rec
local function openInvocation(name, src, resource)
    local rec = { key = invocationKey(name, src), src = src, resource = resource, locks = {}, refused = false,
                  openedAt = GetGameTimer() }
    local list = _openByKey[rec.key]
    if not list then list = {}; _openByKey[rec.key] = list end
    list[#list + 1] = rec
    if src ~= nil then _openBySrc[src] = (_openBySrc[src] or 0) + 1 end

    local co = coroutine.running()
    if co then
        rec.co = co
        _invocationByCo[co] = rec
    end
    return rec
end

---@param rec table
local function closeInvocation(rec)
    if rec.closed then return end   -- counted once, closed once
    rec.closed = true
    -- What this action saved may now be written (Actions, below; stores.lua holds it until here), with
    -- a payment it holds that no write carried (Stores.carryWithAction).
    if (rec.units or rec.carry) and Stores and Stores.releaseAction then Stores.releaseAction(rec) end
    if rec.co then _invocationByCo[rec.co] = nil end
    if rec.src ~= nil then
        local n = (_openBySrc[rec.src] or 1) - 1
        _openBySrc[rec.src] = n > 0 and n or nil
    end
    local list = _openByKey[rec.key]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == rec then table.remove(list, i); break end
    end
    if #list == 0 then _openByKey[rec.key] = nil end
end

--- How many SecureEvent / SecureCallback handlers are running for this player right now, not counting
--- the one asking. Logout waits on it: `closing` stops new handlers at the gate, and this says when
--- the ones already past it have finished.
---
--- The asker, wherever it runs: whip_core's own is found by its coroutine; a satellite's handler
--- calling LogoutPlayer runs the export on a fresh coroutine, so `invoker` leaves out ONE of that
--- resource's handlers for this player (the one blocked in the export). One, not all: its other
--- handlers mid-Wait must still drain before the save.
---@param src number
---@param invoker string|nil  the calling resource (GetInvokingResource), when not whip_core itself
---@return number
function HandlersInFlight(src, invoker)
    local n = _openBySrc[src] or 0
    local co = coroutine.running()
    local mine = co and _invocationByCo[co]
    if mine and mine.src == src then n = n - 1 end
    if invoker and invoker ~= GetCurrentResourceName() then
        local asker = false
        for _, list in pairs(_openByKey) do
            for _, rec in ipairs(list) do
                if rec.src == src and rec.resource == invoker and rec ~= mine and not rec.closed then
                    asker = true
                    break
                end
            end
            if asker then break end
        end
        if asker then n = n - 1 end
    end
    return math.max(0, n)
end

--- The running handler a call belongs to. See the three routes above.
---@param name string|nil     an event or callback name, as registered or as 'cb:<name>'
---@param src number|nil
---@param invoker string|nil  the calling resource; route 3 is only for one that is not whip_core
---@return table|nil rec
---@return string|nil reason
local function findInvocation(name, src, invoker)
    local co = coroutine.running()
    local rec = co and _invocationByCo[co]
    if rec then return rec end

    if name ~= nil then
        local list = _openByKey[invocationKey(name, src)]
                  or _openByKey[invocationKey('cb:' .. tostring(name), src)]
        if list and list[#list] then return list[#list] end   -- the newest, if two overlap
        return nil, ('no handler for "%s" is running for source %s'):format(tostring(name), tostring(src))
    end

    if not invoker or invoker == GetCurrentResourceName() then
        return nil, 'not inside a SecureEvent or SecureCallback handler'
    end

    local found, n = nil, 0
    for _, list in pairs(_openByKey) do
        for _, r in ipairs(list) do
            if r.resource == invoker then found, n = r, n + 1 end
        end
    end
    if n == 1 then return found end
    if n == 0 then return nil, 'not inside a SecureEvent or SecureCallback handler' end
    return nil, ('%d of your handlers are running at once: pass the event name and the source'):format(n)
end

-- ============================================
-- Actions — one player action saves as one
-- ============================================
-- A running SecureEvent / SecureCallback handler IS an action. Whatever whip_core saves while it runs
-- is tied to it (stores.lua, tieToActions): linked, and written in one transaction once it ends, so a
-- part and the item it used land together with no saving code in the satellite. A satellite's calls
-- back into whip_core arrive on a fresh coroutine, so they belong to that resource's running
-- handlers, or to the action whip_core is calling into it for (Actions.call). More than one
-- candidate: the ones the call is about (below); still more, all of them. Tying too much only
-- batches more; too little is the duplication.
--
-- What the call is about: the player whose pockets, money or log row it is; for a car's boot,
-- stats or data, the action that named the car and the players at it. Everything one call saves
-- follows its first answer (_pinnedByCo).

Actions = {}

--- How far from a car its action's player may stand, for a car's save no action named the car for.
--- Wide on purpose: a part is fitted standing at the car, and a bus is long.
local ACTION_REACH = 10.0

--- [coroutine] = the action that satellite call was found to belong to. CfxLua runs each call into
--- whip_core on a coroutine of its own, and one call is one action's: what it saves after its first
--- answer follows that answer (a give's second pocket, a fitted part's car). Weak keys.
local _pinnedByCo = setmetatable({}, { __mode = 'k' })

--- The cars an action's 'vehicle' params named (the handler's schema).
---@param rec table
---@param params table
---@param sanitized table
local function noteVehicles(rec, params, sanitized)
    for i, pDef in ipairs(params) do
        if type(pDef) == 'table' and pDef[2] == 'vehicle' then
            local v = sanitized[i]
            local id = type(v) == 'table' and tonumber(v.vehicleId) or nil
            if id then
                rec.vehicles = rec.vehicles or {}
                rec.vehicles[id] = true
            end
        end
    end
end

--- Route 3's candidates, narrowed to what the call is about. Nothing matching keeps them all: a give
--- to a player with no action of their own still lands with the giver's.
---
--- A car keeps EVERY action at it: the one that named it and the players within reach (two people
--- working on one car are one save). And an action calling into this resource right now (Actions.call:
--- a use handler's onComplete) is always kept: it is the call's own.
---
--- WHAT IT CANNOT SEE: a satellite moving an item between two players in TWO calls (RemoveItem, then
--- AddItem) while both have a handler of it running ties each side to its own player's action. One call
--- (StoreMove) links both sides; docs.html says so.
---@param recs table[]
---@param src number|nil
---@param vehicleId number|nil
---@param invoker string
---@return table[]
local function narrowActions(recs, src, vehicleId, invoker)
    local keep, kept = {}, {}
    local function add(r)
        if not kept[r] then kept[r] = true; keep[#keep + 1] = r end
    end
    src = tonumber(src)
    if src then
        for _, r in ipairs(recs) do
            if tonumber(r.src) == src then add(r) end
        end
    elseif vehicleId then
        for _, r in ipairs(recs) do
            if r.vehicles and r.vehicles[vehicleId] then add(r) end
        end
        local entity = Vehicles and Vehicles.getEntity(vehicleId)
        if entity then
            local at = GetEntityCoords(entity)
            local reach2 = ACTION_REACH * ACTION_REACH
            for _, r in ipairs(recs) do
                local ped = r.src and GetPlayerPed(r.src)
                if ped and ped ~= 0 then
                    local c = GetEntityCoords(ped)
                    local dx, dy, dz = c.x - at.x, c.y - at.y, c.z - at.z
                    if dx * dx + dy * dy + dz * dz <= reach2 then add(r) end
                end
            end
        end
    end
    if #keep == 0 then return recs end
    for _, r in ipairs(recs) do
        if r.calling and (r.calling[invoker] or 0) > 0 then add(r) end
    end
    return keep
end

--- The actions the current call belongs to; empty outside any.
---@param src number|nil        the player the call is about: whose pockets, money, log row
---@param vehicleId number|nil  the car it is about: whose boot, stats, data
---@return table[] recs
function Actions.current(src, vehicleId)
    local co = coroutine.running()
    local rec = co and _invocationByCo[co]
    if rec then return rec.closed and {} or { rec } end
    local invoker = GetInvokingResource()
    if not invoker or invoker == GetCurrentResourceName() then return {} end
    local pinned = co and _pinnedByCo[co]
    if pinned and not pinned.closed then return { pinned } end
    local out = {}
    for _, list in pairs(_openByKey) do
        for _, r in ipairs(list) do
            if not r.closed and (r.resource == invoker or (r.calling and (r.calling[invoker] or 0) > 0)) then
                out[#out + 1] = r
            end
        end
    end
    if #out > 1 then out = narrowActions(out, src, vehicleId, invoker) end
    if #out == 1 and co then _pinnedByCo[co] = out[1] end
    return out
end

--- pcall a satellite's function for the current action, so what it saves through whip ties to it:
--- use handlers, a declared use's canUse/onComplete, item actions, AddAction's onUse, panel hooks.
---@param owner string|nil  the resource the function belongs to
---@param fn function
---@return boolean ok, any ...  as pcall
function Actions.call(owner, fn, ...)
    local recs = (owner and owner ~= GetCurrentResourceName()) and Actions.current() or {}
    ---@cast owner string   -- recs is empty without one
    for _, r in ipairs(recs) do
        r.calling = r.calling or {}
        r.calling[owner] = (r.calling[owner] or 0) + 1
    end
    local res = table.pack(pcall(fn, ...))
    for _, r in ipairs(recs) do r.calling[owner] = r.calling[owner] - 1 end
    return table.unpack(res, 1, res.n)
end

---@param releaseFn function
---@param eventName string|nil
---@param src number|nil
---@param invoker string|nil  set only for a satellite calling through the export (route 3)
---@return boolean ok
---@return string|nil reason
local function trackLock(releaseFn, eventName, src, invoker)
    -- `== nil`, never type(): a satellite's function crosses the export as a callable table.
    if releaseFn == nil then return false, 'TrackInvocationLock: a release function is required' end

    local rec, why = findInvocation(eventName, src, invoker)
    if not rec then return false, why end

    rec.locks[#rec.locks + 1] = releaseFn
    return true
end

--- Register a release function for a lock taken during the current handler invocation. If the
--- handler then ERRORS, the release runs; if it returns normally, the lock stays taken.
---
--- The global is whip_core's own and finds the call by its coroutine only (route 1): outside one of
--- whip_core's handlers it attaches nothing, including whip_core code running inside another
--- resource's export call (route 3's guess must not pick up a lock whip took for another reason).
---@param releaseFn function
---@param eventName string|nil
---@param src number|nil
---@return boolean ok
---@return string|nil reason
function TrackInvocationLock(releaseFn, eventName, src)
    return trackLock(releaseFn, eventName, src, nil)
end

--- The same, for a SATELLITE's handler. Pass the event (or callback) name and the source your
--- handler was given, and the lock lands on that call. Without them it lands on the one handler
--- your resource has running, and is refused if it has several.
---
--- One limit: two overlapping calls of the same event from the same player (burst > 1, a handler
--- that yields) can't be told apart, and the lock lands on the NEWER call. An event whose handler
--- takes locks should keep burst at 1.
exports('TrackInvocationLock', function(releaseFn, eventName, src)
    return trackLock(releaseFn, eventName, src, GetInvokingResource())
end)

--- Run a handler with lock tracking. Releases anything still held if it errored.
---
--- Returns a PACKED result: a callback handler may return several values (true and a value, or false
--- and why, and some answer more), and all of them must be handed back.
---@param rec table  the call's record, from openInvocation
---@return boolean ok
---@return table packed  table.pack of the handler's return values (or the error at [1])
local function callTracked(rec, handler, ...)
    local packed = table.pack(pcall(handler, ...))
    local ok = packed[1]

    local held = rec.locks
    if not ok then
        for i = #held, 1, -1 do
            local released, relErr = pcall(held[i])
            if not released then
                print(('[whip_core:secure] lock release failed after handler error: %s'):format(tostring(relErr)))
            end
        end
    end

    -- Pcall's own table, handed straight back: slot 1 is the success flag and the returns run from
    -- 2 to `n` (both callers read from 2, sparing a repack per call).
    return ok, packed
end

-- ============================================
-- Internal: Event Logging
-- ============================================

--- O(1) ring insert, overwrites oldest when full.
local function ringPush(ring, entry)
    ring.buf[ring.head] = entry
    ring.head = (ring.head + 1) % SECURE_LOG_MAX
    if ring.count < SECURE_LOG_MAX then ring.count = ring.count + 1 end
end

--- Unwind a ring oldest-first. Entries within one ring are already seq-ascending
--- (insertion order IS seq order), which is what makes the two-ring merge below trivial.
local function ringToArray(ring)
    local arr = {}
    if ring.count == 0 then return arr end
    local start = (ring.head - ring.count) % SECURE_LOG_MAX
    for i = 0, ring.count - 1 do
        arr[#arr + 1] = ring.buf[(start + i) % SECURE_LOG_MAX]
    end
    return arr
end

--- Record the outcome of a secure event or callback.
---
--- Two destinations: the MARKER (last outcome per event name, always written) and the RINGS (the
--- Event Monitor's scrollback, both statuses always recorded, watched or not).
---
--- The `calls` / `rejects` counters live on the registry and are counted by the wrapper and
--- RecordEventRejection, not here. A REJECTION's console line and live Event Monitor push are
--- throttled per player per event (one per window, with a count of what was held back), so a client
--- hammering an event can't make the refusals the load. The ring and counters still get everything.
local REJECT_LOG_WINDOW_MS = 5000
local _rejectThrottle = {}   -- [src] = { [eventName] = { at = ms, held = n } }

AddEventHandler('playerDropped', function()
    _rejectThrottle[source] = nil
    -- A handler that never returned must not leave the count up for whoever gets this id next (their
    -- logout would wait on it). Handlers still running close into a nil count harmlessly.
    _openBySrc[source] = nil
end)

--- Should this rejection be printed and pushed? Returns false while inside the window, and on the
--- first one after it the number that were held back.
---@return boolean announce
---@return number held
local function rejectionAnnounce(eventName, src)
    local key = src or 0
    local mine = _rejectThrottle[key]
    if not mine then mine = {}; _rejectThrottle[key] = mine end
    local t = mine[eventName]
    local now = GetGameTimer()
    if t and (now - t.at) < REJECT_LOG_WINDOW_MS then
        t.held = t.held + 1
        return false, 0
    end
    local held = t and t.held or 0
    mine[eventName] = { at = now, held = 0 }
    return true, held
end

--- A throw inside the param checks (validateAll under pcall). The client hears 'malformed
--- parameters'; the error is printed, throttled like a handler's: the code that throws there is
--- mostly whip's own (Stores.fromWire, Vehicles.context), and its bugs must leave a trace.
---@param name string  the event or callback
---@param src number
---@param err any      what validateAll threw
---@return string reason  the refusal the client hears
local function paramsThrew(name, src, err)
    local announce, held = rejectionAnnounce('malformed:' .. tostring(name), src)
    if announce then
        print(('[whip_core:secure] ERROR checking the parameters of "%s" (source %s)%s: %s'):format(
            tostring(name), tostring(src), held > 0 and (' — and %d more like it'):format(held) or '', tostring(err)))
    end
    return 'malformed parameters'
end

--- The live feed goes out in batches: successes are the big stream (every stat report, every gunny
--- shot), so they are queued and sent four times a second as one list. A batch keeps its newest
--- EM_BATCH_MAX entries.
local EM_FLUSH_MS  = 250
local EM_BATCH_MAX = 200
local _emPending, _emFlushArmed = {}, false

local function emQueue(entry)
    _emPending[#_emPending + 1] = entry
    if #_emPending > EM_BATCH_MAX then table.remove(_emPending, 1) end
    if _emFlushArmed then return end
    _emFlushArmed = true
    SetTimeout(EM_FLUSH_MS, function()
        _emFlushArmed = false
        local batch = _emPending
        _emPending = {}
        if #batch == 0 then return end
        -- Only to viewers still allowed: an admin demoted with the monitor open is dropped.
        DevTools.eachViewer(_secureEventViewers, function(viewer)
            TriggerClientEvent('whip_core:client:emNewEvents', viewer, batch)
        end)
    end)
end

--- What a dead player's call is told (refusedWhileDead). Callers and onReject get exactly this: it is
--- documented, and callers compare it.
local DEAD_REASON = 'Player is dead'

--- The fix, said beside that refusal in the console and to a developer in game (sayDead). Dead
--- players are refused by default, so an author who never read about the rule meets an event that
--- does nothing while they are dead; this names the field.
local DEAD_HINT = 'whileDead = true in its schema lets dead players through'

--- @param eventName string
--- @param src number
--- @param status string   'ok' | 'rejected' | 'error'
--- @param reason string|nil
--- @param durationMs number|nil
local function logSecureEvent(eventName, src, status, reason, durationMs)
    -- A reason can carry client text: one line, 300 characters, so a newline can't forge a line in
    -- the console or the txAdmin log.
    if reason ~= nil then
        reason = (tostring(reason):gsub('%c', ' ')):sub(1, 300)
    end

    -- The marker, always. Mutated in place — see above.
    local last = _secureEventLastStatus[eventName]
    if last then
        last.status, last.reason, last.n = status, reason, last.n + 1
    else
        _secureEventLastStatus[eventName] = { status = status, reason = reason, n = 1 }
    end

    local playerName = 'Unknown'
    if Players and Players[src] then
        playerName = Players[src].fullName or Players[src].firstName or 'Unknown'
    end

    -- The console line: rejections only (successes would bury it; 'error' is printed by the wrapper
    -- with its stack). On by default (Config.LogSecureRejections): a silent refusal looks exactly
    -- like a missing feature, and one that spams is itself the finding.
    local announce, held = true, 0
    if status == 'rejected' then announce, held = rejectionAnnounce(eventName, src) end

    if status == 'rejected' and announce and Config.LogSecureRejections ~= false then
        print(('[whip_core:secure] REFUSED %s from %s (src %s): %s%s%s')
            :format(eventName, playerName, tostring(src), tostring(reason or 'no reason given'),
                reason == DEAD_REASON and (' (' .. DEAD_HINT .. ')') or '',
                held > 0 and (' (+%d more held back in the last %ds)'):format(held, REJECT_LOG_WINDOW_MS // 1000) or ''))
    end

    _secureEventSeq = _secureEventSeq + 1
    local entry = {
        seq    = _secureEventSeq,
        t      = os.time(),
        event  = eventName,
        src    = src,
        name   = playerName,
        status = status,
        reason = reason,
        ms     = durationMs,
    }

    ringPush(status == 'ok' and _emRingOk or _emRingRej, entry)

    -- Broadcast to active viewers (a held-back rejection is in the ring, not pushed — see above)
    if not announce or next(_secureEventViewers) == nil then return end
    emQueue(entry)
end

-- ---- Refusals from a satellite's handler ----
--
-- A satellite's RecordEventRejection runs on a fresh coroutine, so the mark goes on the call's
-- record, found by name and source as TrackInvocationLock does (see "Invocation Locks" above);
-- otherwise the wrapper would log 'ok' over the refusal. Two overlapping calls of one event by one
-- player could swap marks: one wrong label in a log, never a wrong answer.

-- Callback names RecordEventRejection has already said match nothing: once each.
local _warnedRejectName = {}

--- Record that a handler REFUSED what a valid event or callback asked for.
---
--- SecureEvent and SecureCallback log the refusals they make (rate limit, ACE, session, params). A
--- handler that passed every check and then declined (a store move vetoed by onValidate) calls this,
--- so the Event Monitor and whip_test's assertRefused see both kinds.
---
--- A callback can be named as it was registered — 'myres:getPrice' — or as the registry knows it,
--- 'cb:myres:getPrice'; both find it.
---@param eventName string
---@param src number
---@param reason string|nil
function RecordEventRejection(eventName, src, reason)
    -- A satellite names its callback the way it registered it. The registry, the Event Monitor and
    -- the invocation below all know it as 'cb:<name>', so that is the name it is logged under.
    if not _secureEventRegistry[eventName] and _secureEventRegistry['cb:' .. tostring(eventName)] then
        eventName = 'cb:' .. tostring(eventName)
    end

    -- A 'cb:' name that matches no callback is a bug, said once. (Other names, a timed action's key
    -- or a Sentinel tamper, are not events and are left alone.)
    if type(eventName) == 'string' and eventName:sub(1, 3) == 'cb:' and not _secureEventRegistry[eventName]
            and not _warnedRejectName[eventName] then
        _warnedRejectName[eventName] = true
        print(('^3[whip_core:secure] RecordEventRejection("%s"): no callback has that name — the refusal cannot be tied to its call^0')
            :format(eventName))
    end

    logSecureEvent(eventName, src, 'rejected', reason, 0)

    -- Counted here: the wrapper skips its own count for a call marked refused below.
    local reg = _secureEventRegistry[eventName]
    if reg and reg.rejects then reg.rejects = reg.rejects + 1 end

    -- Mark THIS call as refused, so the wrapper does not log 'ok' over it when the handler returns.
    -- A refusal outside any running handler is only logged.
    --
    -- Only the handler it names: route 1 finds whatever handler owns the coroutine, and a refusal
    -- under another name (a nested helper's, a Sentinel tamper) must not flip it.
    local rec = findInvocation(eventName, src, nil)
    if rec and rec.key == invocationKey(eventName, src) then rec.refused = true end
end

exports('RecordEventRejection', RecordEventRejection)

-- ============================================
-- SecureEvent — Global + Export
-- ============================================

--- Every event is rate limited. A schema that leaves `rateLimit` out gets this default: up to ten
--- calls back-to-back, then one per 100ms, which no human clicking a panel reaches.
--- `rateLimit = false` opts out explicitly, for something that must never be refused.
local DEFAULT_RATE_LIMIT_MS = 100
local DEFAULT_RATE_BURST    = 10

--- A declared rateLimit with no burst stays a flat cooldown (burst 1), stricter than the default, on
--- purpose: a schema that declares one means exactly that (revive every 2 s). Closes and releases
--- give a burst. A declared burst with no rateLimit keeps its burst at the default interval.
---@param schema table
---@return number|nil interval, number|nil burst   nil interval = not limited
local function effectiveRate(schema)
    if schema.rateLimit == false then return nil, nil end
    if schema.rateLimit == nil then return DEFAULT_RATE_LIMIT_MS, schema.burst or DEFAULT_RATE_BURST end
    return schema.rateLimit, schema.burst
end

--- Is this call from a DEAD player, and does its schema not allow that?
---
--- Dead players act on nothing, by default. The death screen locks controls only on the player's own
--- client, so the rule lives in the one gate every request passes, and a new event is covered the
--- day it is written. The exceptions opt OUT:
---   whileDead = true  — something a dead player genuinely needs: the respawn flow, closing a
---                       screen, letting go of an escort, chat, logout, and background reports that
---                       are not actions at all (vitals, zone mirroring, dressing cars in view).
---   ace = '...'       — admin tools. They are not the character acting on the world, and an admin
---                       who is dead can still run the server.
---@param schema table
---@param player table|nil
---@return boolean
local function refusedWhileDead(schema, player)
    return player ~= nil and player.isDead == true and not schema.whileDead and not schema.ace
end

--- Tell a developer an event refused them for being dead, and the fix (DEAD_HINT): in game, that
--- refusal otherwise looks like an event that does nothing. Developer mode only, once per event per
--- player every 5 s (the console line's throttle, on a key of its own).
---@param name string  the event or callback
---@param src number
local function sayDead(name, src)
    if not DevTools.isAllowed(src) then return end
    if not rejectionAnnounce('dead:' .. tostring(name), src) then return end
    ShowError(src, ('%s refused while dead: %s'):format(tostring(name), DEAD_HINT))
end

--- A position in any of the shapes a schema may use: three numbers, a vector3 or vector4, or a
--- table ({ x, y, z } or { 1, 2, 3 }). Answers x, y, z, or nil when it is none of those.
local function toXYZ(a, b, c)
    if type(a) == 'number' then
        if type(b) == 'number' and type(c) == 'number' then return a, b, c end
        return nil
    end
    local ta = type(a)
    if ta == 'vector3' or ta == 'vector4' then return a.x, a.y, a.z end
    if ta == 'table' and not isFuncRef(a) then
        -- rawget: a table that is not a plain one must not get to throw on the way through.
        local x = rawget(a, 'x') or rawget(a, 1)
        local y = rawget(a, 'y') or rawget(a, 2)
        local z = rawget(a, 'z') or rawget(a, 3)
        if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then return x, y, z end
    end
    return nil
end

--- The `near` rule: is the player close enough to what this call is about?
---
--- `near.at` is one of:
---   * a function(source, player, ...params) answering x, y, z, a vector3 or an {x, y, z} table
---   * a fixed spot: a vector3 or an {x, y, z} table, for a satellite with one counter or bench
---   * 'vehicle': the car named by this schema's 'vehicle' param. Being seated in it counts as near.
---
--- No answer is a refusal: an `at` that finds no position refuses the call. `near.allowUnknown = true`
--- lets it through, for a handler that reports an unknown id itself with a better message than
--- "Too far away".
---@param schema table
---@param src number
---@param handPlayer table|nil
---@param sanitized table
---@param nParams number
---@return boolean ok
---@return string|nil reason   for the log
---@return string|nil status   'rejected' or 'error'
local function checkNear(schema, src, handPlayer, sanitized, nParams)
    local near  = schema.near
    local at    = near.at
    local range = near.range or 5.0
    -- A range that follows a setting (near.range = function() return Config.X + 2.0 end) is asked
    -- at each call, so a change in /whip → Settings reaches the check without a restart.
    if type(range) ~= 'number' then
        local ok, r = pcall(range)
        if not ok or type(r) ~= 'number' or not (r > 0) or r == math.huge then
            return false, ('near.range answered %s, not metres above 0'):format(ok and tostring(r) or 'an error'), 'error'
        end
        range = r
    end

    if at == 'vehicle' then
        local ctx
        for i, pDef in ipairs(schema.params or {}) do
            if pDef[2] == 'vehicle' then ctx = sanitized[i]; break end
        end
        if not ctx then
            return false, "near.at = 'vehicle' needs a 'vehicle' param in the schema", 'error'
        end
        if IsPlayerNearVehicle(src, ctx.vehicleId, range) then return true end
        return false, 'Too far away', 'rejected'
    end

    local x, y, z
    if type(at) == 'function' or isFuncRef(at) then
        -- A function, or a satellite's function (a callable table across the export). Asked with
        -- isFuncRef, never `at.x`: indexing a funcref throws. Pcall'd so a throw is recorded
        -- against the event.
        local okAt, a, b, c = pcall(at, src, handPlayer, table.unpack(sanitized, 1, nParams))
        if not okAt then
            return false, 'near.at: ' .. tostring(a), 'error'
        end
        x, y, z = toXYZ(a, b, c)
    else
        x, y, z = toXYZ(at)
        if not x then return false, 'near.at is not a function, a position or \'vehicle\'', 'error' end
    end

    if not (x and y and z) then
        if near.allowUnknown then return true end
        return false, 'Too far away (near.at found no position)', 'rejected'
    end

    if IsPlayerNear(src, x, y, z, range) then return true end
    return false, 'Too far away', 'rejected'
end

--- A refusal SecureEvent makes ITSELF — rate limit, ACE, session, dead, a param, distance: count it,
--- log it, and let the schema answer the client if it declared how (`onReject`).
---
--- onReject is for events that promise the client an answer (storeMove's opId: "you will hear back
--- about this drag"). These refusals happen BEFORE the handler, so without it the NUI would wait on
--- a move that never happened. The hook sees the RAW arguments: check anything it reads as untrusted.
---@param reg table
---@param eventName string
---@param src number
---@param reason string
---@param args table   the raw arguments as the client sent them
---@param status string|nil  'rejected' (default) or 'error'
local function refuseEvent(reg, eventName, src, reason, args, status)
    reg.rejects = reg.rejects + 1
    logSecureEvent(eventName, src, status or 'rejected', reason, 0)

    local onReject = reg.schema.onReject
    if onReject then
        local ok, err = pcall(onReject, src, reason, args)
        if not ok then
            print(('[whip_core:secure] ERROR in onReject for "%s": %s'):format(eventName, tostring(err)))
        end
    end
end

-- ============================================
-- Who owns a name
-- ============================================
--
-- An event name belongs to the first resource that registers it:
--   * the same resource registering again REPLACES its handler (a satellite restarting, or an
--     onReady re-fire).
--   * another resource is REFUSED, with the owner's name in the reason.
--   * a name whose owner has STOPPED is free again (its dead entry stays for the Event Monitor).
--   * names starting 'whip_core:' are whip_core's alone, even ones it has not declared.
--
-- Callbacks follow the same rule, in their own namespace. The rule is shared/registry.lua's; these
-- two registries hold only WHO owns each name (handlers and counters stay in _secureEventRegistry).
-- `same = false`: the same owner registering again must always swap its handler in.
local _eventNames = Registry.new('SecureEvent', { label = 'event', reserved = 'whip_core:', same = false })
local _callbackNames = Registry.new('SecureCallback', { label = 'callback', reserved = 'whip_core:', same = false })

--- May `resource` register `name`? Answers (true) or (false, reason).
---@param name string      the name as the caller wrote it
---@param kind string      'event' | 'callback'
---@param resource string  the caller
---@return boolean ok
---@return string|nil reason
local function claimName(name, kind, resource)
    local names = kind == 'callback' and _callbackNames or _eventNames
    local ok, why = names:add(resource, name, true)
    if ok then return true end
    return false, why --[[@as string]]
end

-- The param types validateParam knows. Kept next to the schema check below; a new type is added
-- in both places.
local PARAM_TYPES = {
    int = true, number = true, id = true, amount = true, string = true, key = true, enum = true,
    bool = true, addr = true, vehicle = true, slot = true, list = true, any = true, player = true, record = true,
}

--- One param definition, or the reason it is not one.
---@param pDef any
---@param where string  'param 2', 'param 3 entry' ... for the message
---@return string|nil reason
local function checkParamDef(pDef, where)
    if type(pDef) ~= 'table' then
        return where .. " is not a table like {'name', 'type', ...}"
    end
    if type(pDef[1]) ~= 'string' or pDef[1] == '' then
        return where .. ' has no name (its first entry)'
    end
    local t = pDef[2]
    if not PARAM_TYPES[t] then
        return ('%s (%s) has an unknown type "%s"'):format(where, pDef[1], tostring(t))
    end
    if t == 'enum' and type(pDef[3]) ~= 'table' then
        return ('%s (%s) is an enum with no list of allowed values'):format(where, pDef[1])
    end
    if t == 'player' and pDef[3] ~= nil and type(pDef[3]) ~= 'table' then
        return ('%s (%s) is a player whose options are not a table like { range = 3 }'):format(where, pDef[1])
    end
    if t == 'record' then
        local fields = pDef[3]
        if type(fields) ~= 'table' or type(fields[1]) ~= 'table' then
            return ('%s (%s) is a record with no fields, like { {\'accountId\', \'id\'}, {\'note\', \'string\', 200} }'):format(where, pDef[1])
        end
        for i, f in ipairs(fields) do
            local why = checkParamDef(f, ('%s (%s) field %d'):format(where, pDef[1], i))
            if why then return why end
            if f[2] == 'addr' then
                return ('%s (%s) field %d is an addr, which a record cannot carry: send it as a param of its own'):format(where, pDef[1], i)
            end
        end
    end
    if t == 'list' then
        local entry = pDef[3]
        if type(entry) ~= 'table' then
            return ('%s (%s) is a list with no entry definition'):format(where, pDef[1])
        end
        -- No 'addr' inside a list: only a top-level addr is turned back into a plain address before
        -- it reaches a satellite, so one in a list would hand over the player's live handle.
        if type(entry[1]) == 'table' then
            for i, f in ipairs(entry) do
                local why = checkParamDef(f, ('%s (%s) entry field %d'):format(where, pDef[1], i))
                if why then return why end
                if f[2] == 'addr' then
                    return ('%s (%s) entry field %d is an addr, which a list cannot carry — send a list of slots and one addr beside it'):format(where, pDef[1], i)
                end
            end
        else
            local why = checkParamDef(entry, ('%s (%s) entry'):format(where, pDef[1]))
            if why then return why end
            if entry[2] == 'addr' then
                return ('%s (%s) is a list of addr, which a list cannot carry — send a list of slots and one addr beside it'):format(where, pDef[1])
            end
        end
    end
    return nil
end

--- The schema's own mistakes, refused with the reason printed when it is registered, rather than
--- failing every call unseen (`burst = 0` would refuse every call after the first).
---@param schema table
---@return string|nil reason
local function checkSchema(schema)
    local rl = schema.rateLimit
    if rl ~= nil and rl ~= false and not (type(rl) == 'number' and rl > 0 and rl == rl) then
        return 'rateLimit must be a number of milliseconds above 0, or false for no limit'
    end
    local burst = schema.burst
    if burst ~= nil and not (type(burst) == 'number' and burst >= 1 and burst == math.floor(burst)) then
        return 'burst must be a whole number, 1 or more'
    end
    if schema.ace ~= nil and (type(schema.ace) ~= 'string' or schema.ace == '') then
        return 'ace must be the name of an ACE permission'
    end
    if schema.permission ~= nil then
        local p = schema.permission
        local ok = type(p) == 'string' and p ~= ''
        if type(p) == 'table' then
            ok = #p > 0
            for _, n in ipairs(p) do if type(n) ~= 'string' or n == '' then ok = false end end
        end
        if not ok then return 'permission must be a permission name, or a list of them (any of)' end
    end
    if schema.sheet ~= nil and schema.sheet ~= 'full' and schema.sheet ~= 'light' then
        return "sheet must be 'full' (the default) or 'light'"
    end
    local params = schema.params
    if params ~= nil then
        if type(params) ~= 'table' then return 'params must be a list of param definitions' end
        for i, pDef in ipairs(params) do
            local why = checkParamDef(pDef, 'param ' .. i)
            if why then return why end
        end
    end
    local near = schema.near
    if near ~= nil then
        if type(near) ~= 'table' or isFuncRef(near) then
            return 'near must be a table like { at = ..., range = 5.0 }'
        end
        if near.at == nil then return 'near needs an `at`: a function, a position or \'vehicle\'' end
        if near.range ~= nil and not (type(near.range) == 'number' and near.range > 0)
            and type(near.range) ~= 'function' and not isFuncRef(near.range) then
            return 'near.range must be a number of metres above 0, or a function answering one'
        end
        -- And an `at` that can work: not a mistyped string, nor 'vehicle' with no vehicle param.
        if type(near.at) == 'string' then
            if near.at ~= 'vehicle' then
                return ("near.at is a function, a position or 'vehicle' — not '%s'"):format(near.at)
            end
            local hasVehicle = false
            for _, pDef in ipairs(type(params) == 'table' and params or {}) do
                if type(pDef) == 'table' and pDef[2] == 'vehicle' then hasVehicle = true break end
            end
            if not hasVehicle then return "near.at = 'vehicle' needs a 'vehicle' param in the schema" end
        end
    end
    -- ownerOf names the 'id' param holding a netId: only that entity's network owner may send it.
    local ownerOf = schema.ownerOf
    if ownerOf ~= nil then
        if type(ownerOf) ~= 'string' or ownerOf == '' then return 'ownerOf must name a param (a netId)' end
        local found = false
        for _, pDef in ipairs(type(params) == 'table' and params or {}) do
            if type(pDef) == 'table' and pDef[1] == ownerOf then
                if pDef[2] ~= 'id' then return ("ownerOf: param '%s' must be an 'id' (a netId)"):format(ownerOf) end
                found = true
            end
        end
        if not found then return ("ownerOf: there is no param called '%s'"):format(ownerOf) end
    end
    return nil
end

--- The `ownerOf` rule: is the sender the network owner of the entity this call names? For what only
--- the client simulating an entity can report or do (an NPC's brain applied, its death seen). The
--- param must be an 'id' holding a netId. A refusal is quiet (no toast): ownership moves between
--- clients all the time, so a refused report is usually just a late one, and the server asks the
--- new owner itself.
---@return boolean ok
local function checkOwnerOf(schema, src, sanitized)
    local name = schema.ownerOf
    for i, pDef in ipairs(schema.params or {}) do
        if pDef[1] == name then
            local netId = sanitized[i]
            if type(netId) ~= 'number' then return false end
            local ent = NetworkGetEntityFromNetworkId(netId)
            return ent ~= nil and ent ~= 0 and NetworkGetEntityOwner(ent) == src
        end
    end
    return false
end

-- The schema keys SecureEvent/SecureCallback read. Anything else is almost always a typo
-- (`ratelimit`, `whiledead`), warned at registration.
local SCHEMA_KEYS = {
    rateLimit = true, burst = true, ace = true, requirePlayer = true, whileDead = true,
    params = true, near = true, onReject = true, sheet = true, ownerOf = true, permission = true,
}

--- A schema's `permission` (server/permissions.lua): held, or the reason it is not. A name or a list
--- (any of them). Unlike `ace`, it does not excuse the dead-player rule.
---@return string|nil reason
local function permissionRefusal(schema, src)
    local need = schema.permission
    if need == nil then return nil end
    if Permissions and Permissions.hasAny(src, need) then return nil end
    local name = type(need) == 'table' and table.concat(need, ' or ') or tostring(need)
    local d = Permissions and type(need) == 'string' and Permissions.get(need) or nil
    return 'Permission denied: ' .. (d and d.label or name)
end

-- Names an event may not take. RegisterNetEvent marks a NAME safe for the network across the whole
-- runtime, so every handler of it (whip_core's own playerDropped and onResourceStop, which trust
-- `source`) would run for a client that fires it. (A list, not "must contain a colon": whip_test's
-- own events have none.)
local LIFECYCLE_NAMES = {
    playerDropped = true, playerConnecting = true, playerJoining = true,
    onResourceStart = true, onResourceStop = true, onResourceStarting = true,
    onServerResourceStart = true, onServerResourceStop = true, onResourceListRefresh = true,
    entityCreated = true, entityCreating = true, entityRemoved = true,
    playerEnteredScope = true, playerLeftScope = true,
    rconCommand = true, chatMessage = true, gameEventTriggered = true,
}
local LIFECYCLE_PREFIXES = { 'txAdmin:', '__cfx_' }

---@param name string
---@return boolean
local function isLifecycleName(name)
    if LIFECYCLE_NAMES[name] then return true end
    for _, p in ipairs(LIFECYCLE_PREFIXES) do
        if name:sub(1, #p) == p then return true end
    end
    return false
end

--- Check the arguments every registration shares, and the name's owner. Prints a refusal,
--- because a registration that silently did nothing is a feature that silently does not work.
---@return boolean ok
---@return string|nil reason
local function admitRegistration(fnName, name, kind, schema, handler, resource)
    local reason
    local schemaWhy = type(schema) == 'table' and checkSchema(schema) or nil
    if type(name) ~= 'string' or name == '' or #name > 128 then
        reason = ('%s: the name must be a string of 1 to 128 characters'):format(fnName)
    elseif kind == 'event' and name:sub(1, 3) == 'cb:' then
        -- Callbacks are kept under 'cb:<name>' in the same table, so an event of that name would
        -- replace one.
        reason = ('%s("%s"): names starting "cb:" are callbacks\' — pick another'):format(fnName, name)
    elseif kind == 'event' and isLifecycleName(name) then
        reason = ('%s("%s"): that is a server lifecycle event — a client could fire it'):format(fnName, name)
    elseif type(schema) ~= 'table' then
        reason = ('%s("%s"): the schema must be a table'):format(fnName, name)
    elseif schemaWhy then
        reason = ('%s("%s"): %s'):format(fnName, name, schemaWhy)
    elseif handler == nil then
        -- `~= nil`, never type(): a satellite's handler crosses the export as a callable table,
        -- not a 'function'.
        reason = ('%s("%s"): a handler is required'):format(fnName, name)
    else
        local ok, why = claimName(name, kind, resource)
        if ok then
            -- A key nothing reads: warned, not refused — a schema written for a newer whip must
            -- still register on an older one.
            for k in pairs(schema) do
                if not SCHEMA_KEYS[k] then
                    print(('[whip_core:secure] WARNING %s("%s") from %s: "%s" is not a schema key — it does nothing (%s)')
                        :format(fnName, name, tostring(resource), tostring(k),
                            'rateLimit, burst, ace, permission, requirePlayer, whileDead, params, near, onReject, sheet, ownerOf'))
                end
            end
            return true
        end
        reason = why
    end

    print(('[whip_core:secure] REFUSED %s from %s: %s'):format(fnName, tostring(resource), reason))
    return false, reason
end

--- Register a secure net event with automatic validation, rate limiting, and logging.
---
--- Answers (true), or (false, reason) when the name belongs to another resource or the arguments
--- are wrong. See "Who owns a name" above.
--- @param eventName string     The event name to register
--- @param schema table         { rateLimit?, burst?, ace?, permission?, requirePlayer? (default true), whileDead?, params? }
---   permission — an in-game permission the player must hold (server/permissions.lua), or a list
---               of them (any of). Full admins (whip.devtools) hold them all. Unlike `ace`, it does
---               NOT excuse the dead-player rule: say `whileDead = true` too if a dead holder needs it.
---               SecureCallback takes it too.
---   rateLimit — sustained minimum interval between calls, in ms. Omitted: 100ms with a burst
---               of 10 (see DEFAULT_RATE_LIMIT_MS). `false`: not limited at all.
---   burst     — how many calls may arrive back-to-back before that interval is enforced.
---               With a declared rateLimit it defaults to 1, i.e. a plain cooldown; with none,
---               to 10 at the default 100ms (a burst alone is kept). Raise it for anything a player
---               drives by hand (drag-and-drop) where a flat cooldown would silently drop
---               legitimate input.
---   whileDead — `true` lets a DEAD player send this. Everything else is refused while the player
---               is dead (see refusedWhileDead above). SecureCallback takes it too.
---   onReject  — function(source, reason, rawArgs), called when THIS wrapper refuses the event
---               (not when the handler does). For events that owe the client an answer. The
---               arguments are raw and unvalidated. See refuseEvent above.
---   near      — { at, range? (5.0), message?, allowUnknown? }: the player must be within
---               `range` of `at` — a function, a fixed position, or 'vehicle'. See checkNear.
---   sheet     — 'light' hands another resource's handler only who the player is and whether they
---               are dead (WhipPlayer:lightSheet), for events fired many times a second. SecureCallback
---               takes it too. Default 'full'.
--- @param handler function     function(source, player, param1, param2, ...)
--- @return boolean ok
--- @return string|nil reason
function SecureEvent(eventName, schema, handler)
    local resource = GetInvokingResource() or GetCurrentResourceName()

    local admitted, why = admitRegistration('SecureEvent', eventName, 'event', schema, handler, resource)
    if not admitted then return false, why end

    local existing = _secureEventRegistry[eventName]

    _secureEventRegistry[eventName] = {
        schema   = schema,
        resource = resource,
        handler  = handler,
        -- Counters survive a re-registration so the Event Monitor does not appear to reset
        -- itself every time a satellite restarts.
        calls    = existing and existing.calls   or 0,
        rejects  = existing and existing.rejects or 0,
        lastCall = existing and existing.lastCall or 0,
    }

    -- Register the net handler exactly once per event name: RegisterNetEvent ADDS a handler, and a
    -- restarting satellite re-declares its events. The handler below reads `handler` from the
    -- registry, so re-registering swaps in the new function without adding a listener.
    if existing then return true end

    RegisterNetEvent(eventName, function(...)
        local src  = source
        local reg  = _secureEventRegistry[eventName]
        -- The owning resource stopped (see the sweep at the bottom): its handler is a reference into
        -- a Lua state that no longer exists. Refused cleanly rather than erroring on every fire.
        if not reg or reg.dead then return end
        local args = { ... }
        local t0   = GetGameTimer()

        local regSchema     = reg.schema
        local regHandler    = reg.handler
        local requirePlayer = regSchema.requirePlayer ~= false
        local rateLimit, rateBurst = effectiveRate(regSchema)
        local ace           = regSchema.ace
        local params        = regSchema.params or {}

        reg.calls    = reg.calls + 1
        reg.lastCall = os.time()

        -- Every refusal below goes through refuseEvent, which also runs the schema's onReject.

        -- Rate limit check
        if rateLimit and not RateLimit(src, eventName, rateLimit, rateBurst) then
            refuseEvent(reg, eventName, src, 'Rate limited', args)
            return
        end

        -- ACE permission check. whip.devtools also needs developer mode on (DevTools.aceRefusal), and an
        -- admin refused only for that is told how to fix it.
        local aceWhy = ace and DevTools.aceRefusal(src, ace)
        if aceWhy then
            if aceWhy == DevTools.OFF_REASON then DevTools.sayOff(src) end
            refuseEvent(reg, eventName, src, aceWhy, args)
            return
        end

        -- An in-game permission (server/permissions.lua)
        local denied = permissionRefusal(regSchema, src)
        if denied then
            refuseEvent(reg, eventName, src, denied, args)
            return
        end

        -- Player exists check. A session that is CLOSING (logout or disconnect has started and is
        -- waiting on its final save) counts as gone: anything it changed now would land after that
        -- save, in a cache about to be dropped, while the character's rows are read back by the
        -- next load.
        local player = Players and Players[src] or nil
        if requirePlayer and (not player or player.closing) then
            refuseEvent(reg, eventName, src, 'No player session', args)
            return
        end

        -- Dead players act on nothing unless the schema says otherwise (refusedWhileDead).
        if refusedWhileDead(regSchema, player) then
            refuseEvent(reg, eventName, src, DEAD_REASON, args)
            sayDead(eventName, src)
            return
        end

        -- Param validation (under pcall — see validateAll)
        local sanitized = {}
        local validated, badParam, badSay = pcall(validateAll, params, args, src, sanitized)
        if not validated then badParam, badSay = paramsThrew(eventName, src, badParam), nil end
        if badParam then
            refuseEvent(reg, eventName, src, badParam, args)
            -- A refusal a player meets pressing a real option ("That is not your vehicle") is said, as
            -- `near`'s is; a forged or malformed one stays silent.
            if badSay then ShowError(src, badSay) end
            return
        end

        -- Proximity check, declared in the schema so an early return inside the handler can't skip
        -- it. After param validation: the position usually comes from a validated param (a doorId).
        -- See checkNear.
        --
        -- What the handler is handed as `player`: the live object to whip_core's own handlers, the
        -- data sheet (WhipPlayer:handlerSheet) to a satellite's, since every argument is copied
        -- across and the live object carries identifiers and the whole inventory. `sheet = 'light'`
        -- hands only who they are and whether they are dead, for an event fired many times a second
        -- (gunny's shotFired).
        local handPlayer = player
        if reg.resource ~= GetCurrentResourceName() then
            if player then handPlayer = regSchema.sheet == 'light' and player:lightSheet() or player:handlerSheet() end
            sanitized = paramsForSatellite(params, sanitized)   -- 'addr' as an address
        end

        if regSchema.near then
            local nearOk, nearWhy, nearStatus = checkNear(regSchema, src, handPlayer, sanitized, #params)
            if not nearOk and nearStatus == 'error' then
                print(('[whip_core:secure] ERROR in near for "%s": %s'):format(eventName, tostring(nearWhy)))
                refuseEvent(reg, eventName, src, nearWhy --[[@as string]], args, 'error')
                return
            end
            if not nearOk then
                refuseEvent(reg, eventName, src, nearWhy --[[@as string]], args)
                -- And tell them: a silent return looks like the server is down. `near.message =
                -- false` stays silent, for anything fired on a tick rather than by a press.
                if regSchema.near.message ~= false then
                    ShowError(src,
                        regSchema.near.message or 'Too far away')
                end
                return
            end
        end

        if regSchema.ownerOf and not checkOwnerOf(regSchema, src, sanitized) then
            refuseEvent(reg, eventName, src, 'not the network owner of that entity', args)
            return
        end

        -- Call handler (locks taken during it are released automatically if it errors). An event's
        -- returns are read only for an error or a `false, why` refusal. The profiler scope is named so
        -- a capture can tell the handler from the wrapper's checks (which return early, so the scope
        -- wraps only the call). The invocation is open for the length of the handler, so a lock or a
        -- refusal a satellite records from its own coroutine can find it (see "Invocation Locks").
        local inv = openInvocation(eventName, src, reg.resource)
        noteVehicles(inv, params, sanitized)

        ProfilerEnterScope('whip:secureHandler')
        local ok, packed = callTracked(inv, regHandler, src, handPlayer, table.unpack(sanitized, 1, #params))
        ProfilerExitScope()

        -- Index 2: slot 1 of callTracked's packed result is pcall's success flag.
        local err = packed[2]

        local elapsed = GetGameTimer() - t0

        -- Did the handler refuse? It already logged why; don't stamp 'ok' over it.
        closeInvocation(inv)
        local refused = inv.refused

        -- A handler that answers `false, 'why'` has refused: the player is shown the why, and the
        -- refusal is recorded like whip's own. `return false` with no message refuses without a
        -- toast (still recorded).
        if ok and packed[2] == false then
            local message = packed[3]
            if type(message) ~= 'string' or message == '' then message = nil end   -- '' is no message, not a reason
            if message and NotifyPlayer then NotifyPlayer(src, message, 'error') end
            if not refused then
                reg.rejects = reg.rejects + 1
                logSecureEvent(eventName, src, 'rejected', message or 'refused by the handler', elapsed)
                refused = true
            end
        end

        if not ok then
            -- Throttled like refusals: a client that can make a handler throw must not print one
            -- ERROR per call.
            -- Kept for tools under the handler's owner every time (ErrorTap), printed when announced.
            local announce, held = rejectionAnnounce('error:' .. eventName, src)
            ErrorTap.caught(('[whip_core:secure] ERROR in %s\'s event "%s": %s'):format(tostring(reg.resource), eventName,
                tostring(err)), reg.resource,
                announce and ('[whip_core:secure] ERROR in %s\'s event "%s" (source %s)%s: %s'):format(tostring(reg.resource),
                    eventName, tostring(src), held > 0 and (' — and %d more like it'):format(held) or '', tostring(err)))
            logSecureEvent(eventName, src, 'error', tostring(err), elapsed)
        elseif not refused then
            logSecureEvent(eventName, src, 'ok', nil, elapsed)
        end
    end)
    return true
end

exports('SecureEvent', SecureEvent)

-- ============================================
-- SecureCallback — Global + Export
-- ============================================

--- Register a secure callback with automatic validation, rate limiting, and logging.
---
--- Answers (true), or (false, reason) — the same ownership rule as SecureEvent.
--- @param name string          The callback name
--- @param schema table         Same schema format as SecureEvent, except `onReject`: a callback's
---                             refusal IS its answer (`false, why`), so it is never called
--- @param handler function     function(source, player, param1, param2, ...) → return value
--- @return boolean ok
--- @return string|nil reason
function SecureCallback(name, schema, handler)
    local resource = GetInvokingResource() or GetCurrentResourceName()
    local regKey   = 'cb:' .. tostring(name)

    local admitted, why = admitRegistration('SecureCallback', name, 'callback', schema, handler, resource)
    if not admitted then return false, why end

    -- Said, not silently ignored: the schema check accepts onReject for both kinds.
    if schema.onReject ~= nil then
        print(('^3[whip_core:secure] SecureCallback "%s" (%s): onReject is for events — a callback\'s refusal is its answer (false, why), so it will not be called^0')
            :format(tostring(name), resource))
    end

    -- Counters survive a re-registration, as SecureEvent's do.
    local existing = _secureEventRegistry[regKey]
    _secureEventRegistry[regKey] = {
        schema   = schema,
        resource = resource,
        calls    = existing and existing.calls    or 0,
        rejects  = existing and existing.rejects  or 0,
        lastCall = existing and existing.lastCall or 0,
    }

    local requirePlayer = schema.requirePlayer ~= false
    local rateLimit, rateBurst = effectiveRate(schema)   -- the same default as SecureEvent
    local ace           = schema.ace
    local params        = schema.params or {}

    -- A refused callback says why: every refusal below answers `false, reason`, so a caller can
    -- tell "the server said no" from a timeout (nil). False, not nil: a return list crossing an
    -- export is cut at its first nil.
    ---@return boolean false
    ---@return string reason
    local function refuse(reg, src, reason, status)
        reg.rejects = reg.rejects + 1
        logSecureEvent(regKey, src, status or 'rejected', reason, 0)
        return false, reason
    end

    RegisterCallback(name, function(src, ...)
        local reg  = _secureEventRegistry[regKey]
        -- Its owner stopped; see the sweep at the bottom.
        if not reg or reg.dead then return false, 'That is no longer available' end
        local args = { ... }
        local t0   = GetGameTimer()

        reg.calls    = reg.calls + 1
        reg.lastCall = os.time()

        -- Rate limit check
        if rateLimit and not RateLimit(src, regKey, rateLimit, rateBurst) then
            return refuse(reg, src, 'Rate limited')
        end

        -- ACE permission check, developer mode included (as SecureEvent's, above).
        local aceWhy = ace and DevTools.aceRefusal(src, ace)
        if aceWhy then
            if aceWhy == DevTools.OFF_REASON then DevTools.sayOff(src) end
            return refuse(reg, src, aceWhy)
        end

        -- An in-game permission (server/permissions.lua)
        local denied = permissionRefusal(schema, src)
        if denied then return refuse(reg, src, denied) end

        -- Player exists check (a closing session counts as gone; see SecureEvent)
        local player = Players and Players[src] or nil
        if requirePlayer and (not player or player.closing) then
            return refuse(reg, src, 'No player session')
        end

        -- Dead players act on nothing unless the schema says otherwise (refusedWhileDead).
        if refusedWhileDead(schema, player) then
            sayDead(name, src)
            return refuse(reg, src, DEAD_REASON)
        end

        -- Param validation (under pcall — see validateAll)
        local sanitized = {}
        local validated, badParam, badSay = pcall(validateAll, params, args, src, sanitized)
        if not validated then badParam, badSay = paramsThrew(name, src, badParam), nil end
        if badParam then
            refuse(reg, src, badParam)
            -- The answer is the player's words when there are some ("That is not your vehicle"); the log keeps the detail.
            return false, badSay or badParam
        end

        -- Proximity check and the `player` handed over: as the event path above.
        local handPlayer = player
        if reg.resource ~= GetCurrentResourceName() then
            if player then handPlayer = schema.sheet == 'light' and player:lightSheet() or player:handlerSheet() end
            sanitized = paramsForSatellite(params, sanitized)   -- 'addr' as an address
        end

        if schema.near then
            local nearOk, nearWhy, nearStatus = checkNear(schema, src, handPlayer, sanitized, #params)
            if not nearOk and nearStatus == 'error' then
                print(('[whip_core:secure] ERROR in near for callback "%s": %s'):format(name, tostring(nearWhy)))
                return refuse(reg, src, nearWhy, 'error')
            end
            if not nearOk then
                -- Same reasoning as the event path above: tell the player, as well as the caller.
                if schema.near.message ~= false then
                    ShowError(src,
                        schema.near.message or 'Too far away')
                end
                return refuse(reg, src, nearWhy)
            end
        end

        if schema.ownerOf and not checkOwnerOf(schema, src, sanitized) then
            return refuse(reg, src, 'not the network owner of that entity')
        end

        -- Call handler (locks taken during it are released automatically if it errors), scoped
        -- as the event path is.
        local inv = openInvocation(regKey, src, reg.resource)   -- see the event path above
        noteVehicles(inv, params, sanitized)

        ProfilerEnterScope('whip:secureHandler')
        local ok, packed = callTracked(inv, handler, src, handPlayer, table.unpack(sanitized, 1, #params))
        ProfilerExitScope()

        local elapsed = GetGameTimer() - t0

        -- Did the handler refuse? As the event path. Only the LOG changes: the handler's answer
        -- still goes back to the caller.
        closeInvocation(inv)
        local refused = inv.refused

        if not ok then
            local announce, held = rejectionAnnounce('error:' .. regKey, src)   -- throttled; kept every time
            ErrorTap.caught(('[whip_core:secure] ERROR in %s\'s callback "%s": %s'):format(tostring(reg.resource), name,
                tostring(packed[2])), reg.resource,
                announce and ('[whip_core:secure] ERROR in %s\'s callback "%s" (source %s)%s: %s'):format(tostring(reg.resource),
                    name, tostring(src), held > 0 and (' — and %d more like it'):format(held) or '', tostring(packed[2])))
            logSecureEvent(regKey, src, 'error', tostring(packed[2]), elapsed)
            -- The error's text stays in the server console: it can name files and internals.
            return false, 'Server error'
        end

        if not refused then
            logSecureEvent(regKey, src, 'ok', nil, elapsed)
        end

        -- All of them, not just the first (compound answers), from 2 (slot 1 is pcall's success flag).
        return table.unpack(packed, 2, packed.n)
    end)
    return true
end

exports('SecureCallback', SecureCallback)

-- ============================================
-- Event Monitor — Server Events
-- ============================================
--
-- These three stay raw RegisterNetEvent: through SecureEvent the monitor would log and broadcast
-- its own traffic. ACE-gated inline instead.

--- Build registry summary for the Event Monitor UI
local function emBuildRegistrySummary()
    local summary = {}
    for eventName, reg in pairs(_secureEventRegistry) do
        summary[#summary + 1] = {
            event     = eventName,
            resource  = reg.resource,
            calls     = reg.calls,
            rejects   = reg.rejects,
            lastCall  = reg.lastCall,
            -- The limit actually applied, default included, so the monitor does not show "none"
            -- for an event that is in fact limited.
            rateLimit = reg.schema and (effectiveRate(reg.schema)) or nil,
        }
    end
    return summary
end

--- Build the ordered log array (oldest first): a two-pointer merge of both rings by
--- ascending seq. Each ring is internally seq-ascending, so this is O(n), and the result
--- is at most 1000 entries — the snapshot payload the monitor opens onto.
local function emBuildLogArray()
    local ok, rej = ringToArray(_emRingOk), ringToArray(_emRingRej)
    local arr = {}
    local i, j = 1, 1
    while i <= #ok or j <= #rej do
        local pickOk
        if i > #ok then pickOk = false
        elseif j > #rej then pickOk = true
        else pickOk = ok[i].seq < rej[j].seq end
        if pickOk then arr[#arr + 1] = ok[i]; i = i + 1
        else arr[#arr + 1] = rej[j]; j = j + 1 end
    end
    return arr
end

-- THE MONITOR'S OWN THREE EVENTS (open, close, clear) are plain net events, each gated by hand with
-- DevTools.isAllowed, and the Sentinel viewer's three are the same (server/sentinel.lua). The only ones in whip
-- that are not SecureEvents: the Monitor watches SecureEvent, and a viewer of it must not appear in the feed it is
-- reading, nor be rate-limited out of opening it while a flood it is there to watch is going on.

--- Open Event Monitor — register viewer + send initial data
RegisterNetEvent('whip_core:server:emGetAll', function()
    local source = source
    if not DevTools.isAllowed(source) then return end
    _secureEventViewers[source] = true
    TriggerClientEvent('whip_core:client:emAllData', source, {
        registry = emBuildRegistrySummary(),
        log      = emBuildLogArray(),
    })
end)

--- Close Event Monitor — unregister viewer. Not gated: leaving is never refused (a demoted admin must
--- still leave the feed).
RegisterNetEvent('whip_core:server:emClosed', function()
    _secureEventViewers[source] = nil
end)

--- Clear log — wipe both rings, tell viewers to empty their feed IN PLACE (a fresh emAllData would
--- re-run the client's whole open path). The marker, the registry counters and seq are untouched.
RegisterNetEvent('whip_core:server:emClearLog', function()
    if not DevTools.isAllowed(source) then return end
    _emRingOk  = { buf = {}, head = 0, count = 0 }
    _emRingRej = { buf = {}, head = 0, count = 0 }
    -- A pending live batch belongs to the log just cleared.
    _emPending = {}
    DevTools.eachViewer(_secureEventViewers, function(viewer)
        TriggerClientEvent('whip_core:client:emCleared', viewer)
    end)
end)

--- The viewer sweep.
AddEventHandler('playerDropped', function()
    _secureEventViewers[source] = nil
end)

--- A stopping resource's events and callbacks go DEAD: the net listener can't be removed, and its
--- handler lives in a Lua state that is gone. Marked rather than deleted, so the Event Monitor keeps
--- the history and a re-declare simply replaces the entry.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then return end
    for _, reg in pairs(_secureEventRegistry) do
        if reg.resource == res then reg.dead = true end
    end

    -- And its handlers still running are closed: a satellite handler waiting when its resource
    -- stopped never answers, and its open invocation would hold every logout of that player for the
    -- whole 2 s drain and leak its locks. The wrapper's coroutine can't be resumed from here; the
    -- bookkeeping is put right.
    local stale = {}
    for _, list in pairs(_openByKey) do
        for _, rec in ipairs(list) do
            if rec.resource == res then stale[#stale + 1] = rec end
        end
    end
    for _, rec in ipairs(stale) do
        -- Its locks go as they would had the handler errored (callTracked). A release function that
        -- belonged to the stopped resource cannot run any more; pcall says so and moves on.
        for i = #rec.locks, 1, -1 do
            local released, relErr = pcall(rec.locks[i])
            if not released then
                print(('[whip_core:secure] lock release failed for a %s handler stopped mid-call: %s'):format(res, tostring(relErr)))
            end
        end
        rec.locks = {}
        closeInvocation(rec)
    end
end)
