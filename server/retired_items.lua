-- ============================================
-- RETIRED ITEMS — an item taken out of the game for good
-- ============================================
--
--     exports.whip_core:RetireItem('turbo', 'Turbos are sold at Whiplash now, in stages')
--
-- The item stops being an item: its definition goes (so nothing can make a new one: AddItem, a shop, a ground
-- drop all refuse an unknown item), RegisterItem refuses the name, and every one already out there is taken
-- away. Not refunded.
--
--   * At once, from everything loaded: online players' pockets, every open stash and boot, the ground.
--   * Later, from the rest, as each loads: a character's pockets at login (and an admin's offline look at
--     them: Inventory.load), a stash when it is opened (Containers.loadInventory), a car's boot, glovebox and
--     ignition (Vehicles.loadInventory). Nothing is read from the database to find them: a stash nobody opens
--     keeps its rows, unseen, until someone does.
--
-- Inside other items too, at every level: a duffle bag's slots, a wallet's (a plain slot array at
-- metadata[storageKey], RegisterPanelItem). Not inside an item whose panel keeps its own shape (a panel with
-- read/write: a magazine's rounds), nor a satellite's own store kinds (RegisterStoreKind): those shapes are
-- their resources' to clear.
--
-- Each one taken is a 'lost' row on its own timeline and its holder's (/whip → Item Log), with the reason.
--
-- Only your own key: one no running resource holds and no other resource registered last (whip_core remembers
-- each key's last registrant across restarts), so start order never decides whose items go.
--
-- A retirement belongs to the resource that made it, as every registration (shared/registry.lua): held while
-- it runs, given up when it stops. What was taken stays taken; any still in a stash nobody opened are then
-- "unknown items" again, until it starts and retires them once more.

RetiredItems = {}

--- A car's three compartments (server/stores.lua, the vehicle kind).
local VEHICLE_STORAGES = { 'trunk', 'glovebox', 'key' }

-- One sweep of everything loaded at a time; a retirement that comes in during one asks for another after it.
local _sweeping, _sweepAgain = false, false

local queueSweep   -- below

--- [itemKey] = { reason }. Owned, and swept with its resource (the registry's default).
local _retired = Registry.new('RetiredItem', {
    label = 'retired item',
    -- A first retirement (or the first since its resource came back) clears out what is loaded now. In a
    -- thread: onAdd must not yield, and each online player's pockets and each ground pile are written.
    onAdd = function(key, value, owner, old)
        if old ~= nil then return end
        print(('[whip_core] item "%s" retired by %s (%s): taking it out of everything loaded')
            :format(key, owner, value.reason))
        queueSweep()
    end,
})

--- Why an item is retired, or nil while it is not.
---@param itemKey string
---@return string|nil reason
function RetiredItems.why(itemKey)
    local entry = _retired:get(itemKey)
    return entry and entry.reason or nil
end

--- The resource whose retirement of an item holds, or nil.
---@param itemKey string
---@return string|nil
function RetiredItems.owner(itemKey)
    return _retired:ownerOf(itemKey)
end

--- Is anything retired at all? (The loaders ask on every load, so this is the cheap answer.)
---@return boolean
local function anyRetired()
    return next(_retired.entries) ~= nil
end

-- ============================================
-- Taking them out
-- ============================================

--- Take retired items out of what one item holds (a duffle bag's slots, a wallet's), at every level, IN
--- PLACE, as far down as weight is followed (Inventory.MAX_NESTING). Each one taken is added to `out` as
--- { gone = the stack, why, inside = the holding item's key }.
---@param itemKey string
---@param metadata table|nil
---@param out table
---@param depth number
local function stripInside(itemKey, metadata, out, depth)
    if type(metadata) ~= 'table' or depth > Inventory.MAX_NESTING then return end
    local cfg = Panels and Panels.itemConfigs[itemKey]
    if not cfg or cfg.read then return end   -- no panel, or one that keeps its own shape
    local slots = metadata[cfg.storageKey or 'slots']
    if type(slots) ~= 'table' then return end

    -- The keys first: taking entries out during pairs() is fine in Lua, but recursing into one that is
    -- then removed is not worth reasoning about.
    local keys = {}
    for k in pairs(slots) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local entry = slots[k]
        if type(entry) == 'table' and entry.item then
            local why = RetiredItems.why(entry.item)
            if why then
                slots[k] = nil
                out[#out + 1] = { gone = entry, why = why, inside = itemKey }
            else
                stripInside(entry.item, entry.metadata, out, depth + 1)
            end
        end
    end
end

--- What an item is called, for a log line.
local function nameOf(itemKey)
    local def = Config.Items[itemKey]
    return def and def.name or itemKey
end

--- One 'lost' row per stack taken, on the stack's own timeline and its holder's.
---@param charId number|nil
---@param g table  { gone, why, inside }
---@param where string  'Player Inventory', 'Trunk of AB123CD', 'the ground'
---@param at table|nil  { x, y, z } for a ground pile
local function logGone(charId, g, where, at)
    local from = g.inside and ('inside a %s, %s'):format(nameOf(g.inside), where) or where
    Log.item(charId, 'lost', g.gone, {
        detail = ('retired (%s) · taken from %s'):format(g.why, from),
        x = at and at.x, y = at and at.y, z = at and at.z,
    })
end

--- Take every retired item out of one store, and out of the items in it. Memory only, never yields; the
--- caller says when it is written. Logged.
---@param store table|nil  from Stores.open
---@param charId number|nil  whose timeline it also goes on; nil for nobody's
---@return number taken  stacks taken
---@return number[] slots  the slots that changed
local function strip(store, charId)
    if not store then return 0, {} end
    local kind, h = store.kind, store.handle
    local size = tonumber(kind.slots(h)) or 0
    local gone, changed = {}, {}
    for slot = 1, size do
        local data = kind.get(h, slot)
        if type(data) == 'table' and data.item then
            local why = RetiredItems.why(data.item)
            if why then
                -- The trusted take (no hooks to ask: nobody may keep a retired item).
                local ok, err, removed = Stores.take(store, slot)
                if ok then
                    gone[#gone + 1] = { gone = removed, why = why }
                    changed[#changed + 1] = slot
                else
                    print(('[whip_core] could not take retired "%s" out of %s slot %d: %s')
                        :format(data.item, tostring(store.id), slot, tostring(err)))
                end
            else
                local before = #gone
                stripInside(data.item, data.metadata, gone, 1)
                -- Put back through the kind, so a kind whose get() answers a copy keeps the change too.
                if #gone > before then
                    kind.set(h, slot, data.item, data.amount, data.metadata)
                    changed[#changed + 1] = slot
                end
            end
        end
    end
    if #gone == 0 then return 0, changed end
    local where = Log.storeLabel(store)
    for _, g in ipairs(gone) do logGone(charId, g, where) end
    return #gone, changed
end

--- Take every retired item out of a loaded stash or car compartment and mark it owed: the next flush writes it,
--- deleting the rows. Whoever has it open is shown the change, and a car's ignition tells its driver, as any
--- direct write does (StoreTake). Never yields. As each loads, and for everything loaded at once.
---@param store table|nil  from Stores.open
---@param charId number|nil  whose timeline it also goes on
---@return number taken
function RetiredItems.sweepStore(store, charId)
    if not store or not anyRetired() then return 0 end
    local n, slots = strip(store, charId)
    if #slots == 0 then return n end
    Stores.markDirty(store)
    Stores.publishSlots(store, slots)
    if store.kind.afterWrite then
        local ok, err = pcall(store.kind.afterWrite, store.handle, slots)
        if not ok then print(('[whip_core] afterWrite on "%s" errored after a retired item sweep: %s'):format(store.kind.id, tostring(err))) end
    end
    return n
end

--- Take retired items out of a character's pockets just read from the database (Inventory.load), before
--- anything sees them. Memory only: the save snapshot still holds them, so the next save of these pockets
--- deletes their rows. Not marked owed here, while the cache is not yet live (a login: player_lifecycle.lua
--- marks it once the player is; an admin's offline look, once its session is stored).
---@param charId number
---@param cache table  { player = {...}, accessory = {...} }
---@return number taken
function RetiredItems.sweepPockets(charId, cache)
    if not anyRetired() then return 0 end
    local n = 0
    for _, container in ipairs(PlayerContainers) do
        n = n + (strip(Stores.rawInventory(cache, charId, container), charId))
    end
    return n
end

--- Take every retired item off the car's three compartments (Vehicles.loadInventory, and the sweep below).
---@param vehicleId number
---@return number taken
function RetiredItems.sweepVehicle(vehicleId)
    if not anyRetired() then return 0 end
    local def = Vehicles.getDef(vehicleId)
    local owner = def and def.ownerCharId or nil
    local n = 0
    for _, storageType in ipairs(VEHICLE_STORAGES) do
        n = n + RetiredItems.sweepStore(Stores.vehicle(vehicleId, storageType), owner)
    end
    return n
end

--- One ground pile: gone if it is a retired item, emptied of any it holds. Written through (the row first,
--- as every ground change is). A pile someone is picking up right now is left: it is in their pockets next.
---@param id number
local function sweepGroundPile(id)
    local row = GroundItems.cache[id]
    if not row or row.flight then return end
    local at = { x = row.x, y = row.y, z = row.z }

    local why = RetiredItems.why(row.item)
    if why then
        if not GroundItems.tryLock(id) then return end
        local ok, err = GroundItems.delete(id)
        GroundItems.unlock(id)
        if ok then
            logGone(nil, { gone = { item = row.item, amount = row.amount, metadata = row.metadata }, why = why },
                'the ground', at)
        elseif err ~= 'Item not found' then
            print(('[whip_core] could not take retired "%s" off the ground (#%d): %s'):format(row.item, id, tostring(err)))
        end
        return
    end

    -- What it holds, on a copy: the row is written first, and memory only follows a write that landed.
    local meta = Stores.copyMetadata(row.metadata)
    local gone = {}
    stripInside(row.item, meta, gone, 1)
    if #gone == 0 then return end
    if not GroundItems.tryLock(id) then return end
    local ok, err = GroundItems.setItem(id, row.item, row.amount, meta)
    GroundItems.unlock(id)
    if not ok then
        print(('[whip_core] could not take retired items out of ground pile #%d: %s'):format(id, tostring(err)))
        return
    end
    for _, g in ipairs(gone) do logGone(nil, g, 'the ground', at) end
end

--- Everything loaded right now: online players' pockets (pushed and saved), stashes and car compartments
--- (owed to the flush), the ground (written through). The keys are taken first each time: saves yield.
function RetiredItems.sweepLoaded()
    if not anyRetired() then return end
    local taken = 0

    local sources = {}
    for src in pairs(Players) do sources[#sources + 1] = src end
    for _, src in ipairs(sources) do
        local player = Players[src]
        if player and player.inventory then
            -- Paying (the pockets held still for a bank payment): left until their next login.
            if Inventory.pocketsFrozen(src) then
                print(('[whip_core] %s is paying right now: retired items leave their pockets at their next login')
                    :format(tostring(player.fullName)))
            else
                local n, any = 0, false
                for _, container in ipairs(PlayerContainers) do
                    local got, slots = strip(Stores.player(src, container), player.charId)
                    n, any = n + got, any or #slots > 0
                end
                if any then
                    taken = taken + n
                    -- whip_core:item:removed says why (Inventory.announceChanges).
                    Inventory.noteChangeReason(src, 'retired', nil)
                    Inventory.syncAndSave(src, player)
                end
            end
        end
    end

    local containerIds = {}
    for id in pairs(Containers.invCache) do containerIds[#containerIds + 1] = id end
    for _, id in ipairs(containerIds) do
        taken = taken + RetiredItems.sweepStore(Stores.container(id))
    end

    local vehicleIds = {}
    for id in pairs(Vehicles.invCache) do vehicleIds[#vehicleIds + 1] = id end
    for _, id in ipairs(vehicleIds) do
        taken = taken + RetiredItems.sweepVehicle(id)
    end

    local pileIds = {}
    for id in pairs(GroundItems.cache) do pileIds[#pileIds + 1] = id end
    for _, id in ipairs(pileIds) do sweepGroundPile(id) end

    if taken > 0 then
        print(('[whip_core] retired items: took %d stack(s) out of loaded pockets, stashes and boots'):format(taken))
    end
end

queueSweep = function()
    if _sweeping then _sweepAgain = true; return end
    _sweeping = true
    CreateThread(function()
        repeat
            _sweepAgain = false
            local ok, err = pcall(RetiredItems.sweepLoaded)
            if not ok then print(('^1[whip_core] retired item sweep failed: %s^0'):format(tostring(err))) end
        until not _sweepAgain
        _sweeping = false
    end)
end

-- ============================================
-- Exports
-- ============================================

--- RetireItem's body, with its owner.
---@param name string
---@param reason any
---@param owner string
---@return boolean ok
---@return string|nil err
function RetiredItems.retire(name, reason, owner)
    if type(name) ~= 'string' or #name > 50 or not name:match('^[%w_%-]+$') then
        return false, 'RetireItem needs an item key (letters, digits, _ and -)'
    end
    reason = Sanitize.string(reason, 120)
    if reason == '' then reason = 'no longer in the game' end

    -- Only an item nobody running holds, or the caller's own, can be ended: asked before anything changes.
    local holder = Config.Items[name] ~= nil and Inventory.itemOwner(name) or nil
    if holder and holder ~= owner and Registry.alive(holder) then
        return false, ('item "%s" belongs to %s: only it can retire it'):format(name, holder)
    end
    -- Nor one another resource registered last, running or not (Inventory.lastRegistrant, kept across restarts):
    -- otherwise whichever started first decided, and a seller's 'turbo' could be taken from every player.
    local last = Inventory.lastRegistrant(name)
    if last and last ~= owner then
        return false, ('item "%s" was registered by %s: only it can retire it'):format(name, last)
    end

    local ok, why = _retired:add(owner, name, { reason = reason })
    if not ok then return false, why --[[@as string]] end

    if Config.Items[name] ~= nil then
        local gone, goneWhy = Inventory.unregisterItem(name, owner)
        if not gone then print(('[whip_core] item "%s" is retired, but its definition stayed: %s'):format(name, tostring(goneWhy))) end
    end
    return true
end

--- RetireItem(name, reason): take an item out of the game for good (the top of this file). Answers true, or
--- false and why. Asking again with the same reason changes nothing.
exports('RetireItem', function(key, reason)
    return RetiredItems.retire(key, reason, Registry.caller())   -- the caller first, before anything yields
end)

--- UnretireItem(name): give up your own retirement. The name is free again (RegisterItem it to bring the item
--- back); what was taken stays taken.
exports('UnretireItem', function(key)
    return _retired:remove(Registry.caller(), key)
end)
