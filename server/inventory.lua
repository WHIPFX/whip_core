-- ============================================
-- INVENTORY — Server Module
-- Provides: load, save, move, add, remove,
-- use, weight, and item registration
-- ============================================

Inventory = {}
Inventory.UseHandlers = {}
Inventory.MetaGenerators = {}
Inventory.ContextActions = {}  -- [actionKey] = handler; consumed by events_inventory + panels
Inventory.Cooldowns = {} -- [source] = { [itemKey] = lastUseTime }

-- Has every character the accessory strip (Config.AccessoryStrip, shared/inventory_shape.lua)? Worked out
-- here because this file asks at load, before inventory_sync.lua defines Inventory.isPlayerContainer.
local HAS_STRIP = false
for _, c in ipairs(PlayerContainers) do
    if c == 'accessory' then HAS_STRIP = true end
end

-- ============================================
-- Database — Table Creation (first-time setup)
-- ============================================

--- Create `character_inventory` if this database has never seen it. Answers whether it worked;
--- start-up refuses to run without it (CreateTable in server/helpers.lua).
---@return boolean ok
function Inventory.ensureTable()
    -- NO separate `charId` index: the primary key's leftmost column already is one, and a second
    -- would cost a write on every inventory save and buy nothing.
    return CreateTable('character_inventory', [[
        CREATE TABLE IF NOT EXISTS `character_inventory` (
            `charId`    INT UNSIGNED     NOT NULL,
            `container` ENUM('player','accessory') NOT NULL DEFAULT 'player',
            `slot`      SMALLINT UNSIGNED NOT NULL,
            `item`      VARCHAR(50)      NOT NULL,
            `amount`    INT UNSIGNED     NOT NULL DEFAULT 1,
            `metadata`  JSON             DEFAULT NULL,
            PRIMARY KEY (`charId`, `container`, `slot`),
            KEY `idx_inventory_item` (`item`),
            CONSTRAINT `fk_inventory_charId` FOREIGN KEY (`charId`)
                REFERENCES `characters` (`charId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

-- ============================================
-- Database Operations
-- ============================================

--- A row's `metadata` column as a table, or nil (empty, or unreadable). For every loader that reads
--- item rows: pockets, stashes, boots and ground items.
---
--- Type-checked before next(): a hand-edited row can hold any valid JSON (`5`, `"note"`), and one
--- bad row must not make a whole character or stash unloadable. The item still loads, without its
--- metadata, and the console names the row.
---@param raw any     the column as oxmysql gave it
---@param what string the row, for the console ("charId 12 slot 3")
---@return table|nil
function Inventory.readMetadata(raw, what)
    if raw == nil or raw == '' or raw == '{}' then return nil end
    local ok, decoded = true, raw
    if type(raw) == 'string' then ok, decoded = pcall(json.decode, raw) end
    if ok and type(decoded) == 'table' then
        return next(decoded) ~= nil and decoded or nil
    end
    print(('[whip_core:inv] %s has unreadable metadata (%s) — ignored, the item kept')
        :format(tostring(what), ok and type(decoded) or 'not JSON'))
    return nil
end

--- Load a character's inventory from the database.
---
--- Returns nil on read failure, never an empty cache: an empty cache's next save would delete
--- every row the character has. Callers MUST treat nil as "do not proceed", not as "empty".
---@param charId number
---@return table|nil { player = {[slot] = {item,amount,metadata}}, accessory = {...} }
---@return number|nil retired  stacks of retired items taken out as it loaded (server/retired_items.lua)
function Inventory.load(charId)
    local ok, rows

    -- Test seam: lets whip_test prove that a failed read does NOT delete the character's
    -- rows. Inert unless Config.EnableTestSeams; see server/testseams.lua.
    if TestSeams and TestSeams.shouldFail('inventory_read') then
        ok, rows = false, 'injected fault: inventory_read'
    else
        ok, rows = pcall(MySQL.query.await,
            'SELECT `container`, `slot`, `item`, `amount`, `metadata` FROM `character_inventory` WHERE `charId` = ?',
            { charId }
        )
    end

    if not ok then
        print(('[whip_core:inv] ERROR loading inventory for charId %d: %s'):format(charId, tostring(rows)))
        return nil
    end
    ---@cast rows -string

    local inv = {
        player    = {},
        accessory = {},
    }

    local itemCount = 0
    if rows then
        for _, row in ipairs(rows) do
            local container = row.container
            if inv[container] then
                local meta = Inventory.readMetadata(row.metadata,
                    ('character %s %s slot %s'):format(tostring(charId), tostring(container), tostring(row.slot)))
                inv[container][row.slot] = {
                    item     = row.item,
                    amount   = row.amount or 1,
                    metadata = meta,
                }
                itemCount = itemCount + 1
            end
        end
    end

    -- The rows just read are what is on disk, so they are the save snapshot (the first save is a
    -- diff). A load only happens with nothing owed for the character (the login settles first).
    Inventory.seedSnapshot(inv)

    -- WITHOUT THE STRIP (Config.AccessoryStrip = false): what the character had in it moves into their
    -- inventory's first empty slots. AFTER the snapshot, so the next save writes the move (rows leave
    -- 'accessory', arrive in 'player'); until then the database still has them in the strip and the next
    -- load moves them again, so nothing can be lost in between. What does not fit waits in the strip,
    -- unseen and unusable (nothing reaches 'accessory' while it is off), until the strip is turned back on.
    if not HAS_STRIP and next(inv.accessory) then
        local from = {}
        for slot in pairs(inv.accessory) do from[#from + 1] = slot end
        table.sort(from)
        local size, free, moved = Config.ContainerSlots.player or 0, 1, 0
        for _, slot in ipairs(from) do
            while free <= size and inv.player[free] do free = free + 1 end
            if free > size then break end
            inv.player[free], inv.accessory[slot] = inv.accessory[slot], nil
            moved = moved + 1
        end
        print(('[whip_core:inv] the accessory strip is off: moved %d item(s) of charId %d into their inventory%s')
            :format(moved, charId, #from > moved and (', %d did not fit and wait in the strip'):format(#from - moved) or ''))
    end

    -- Retired items (RetireItem) come out before anything sees them, logged. AFTER the snapshot, so the next save
    -- deletes their rows; the caller marks that save owed once the cache is live (it answers how many).
    return inv, RetiredItems.sweepPockets(charId, inv)
end

-- `container` is ENUM('player','accessory'); under STRICT_TRANS_TABLES any other value aborts
-- the whole transaction.
local VALID_CONTAINERS = { player = true, accessory = true }

-- `slot` is an unsigned integer column: anything outside this range would abort the transaction too.
local MAX_SLOT = 65535

-- ============================================
-- Incremental saves — snapshot and diff
-- ============================================
--
-- A save compares the cache against the last state CONFIRMED WRITTEN and emits only the
-- difference (firing one round changes one number in one item's metadata).
--
-- The snapshot is keyed on the cache table, weakly, not on charId: a reload's new table gets a
-- full write, logout lets the snapshot be collected, and the offline-admin path's detached cache
-- gets its own.
--
-- Metadata is deep-copied and deep-compared: a wallet's contents live in its metadata, so two
-- wallets differ only there. It is mutated in place, so the snapshot must hold a copy, not the
-- reference (which would always compare equal).
local _snapshots = setmetatable({}, { __mode = 'k' })

--- Capture the persistable shape of one slot, detached from the live cache.
local function snapshotSlot(data)
    return {
        item     = data.item,
        amount   = data.amount or 1,
        metadata = Stores.copyMetadata(data.metadata),
    }
end

--- Record a cache just read from the database as written: the first save is then a diff (see
--- Inventory.load). Rows a save would skip are left out, as buildSaveQueries leaves them out.
---@param cache table
function Inventory.seedSnapshot(cache)
    local snap = {}
    for container, slots in pairs(cache) do
        if VALID_CONTAINERS[container] and type(slots) == 'table' then
            for slot, data in pairs(slots) do
                local slotNum = tonumber(slot)
                if data and data.item and slotNum then snap[container .. '\0' .. slotNum] = snapshotSlot(data) end
            end
        end
    end
    _snapshots[cache] = snap
end

--- Is this slot unchanged since the last confirmed write?
local function slotUnchanged(prev, data)
    if not prev then return false end
    if prev.item ~= data.item then return false end
    if prev.amount ~= (data.amount or 1) then return false end
    return Stores.metadataEquivalent(prev.metadata, data.metadata)
end

--- Build the SQL queries needed to persist an inventory cache.
---
--- Rows that cannot legally be written are skipped, and a skipped row is treated as unchanged
--- so the diff never deletes something it could not read back. Skipping is always preferable
--- to failing the transaction; preserving is always preferable to deleting.
---
--- Returns two values. The second is a callback the COMMITTER must call once the transaction is
--- known to have gone through (Stores.commit batches several stores, so building can't advance it):
---
---     local queries, confirm = Inventory.buildSaveQueries(charId, cache)
---     ... commit, possibly merged with other queries ...
---     if committed then confirm() end
---
--- A caller that ignores `confirm` just keeps emitting full writes.
---@param charId number
---@param cache table
---@return table[] queries
---@return function confirm  call ONLY after a verified commit
function Inventory.buildSaveQueries(charId, cache)
    if not cache then return {}, function() end end

    local queries = {}
    local prev    = _snapshots[cache]
    local nextSnap = {}

    -- Walk the cache: build the next snapshot, and collect only what differs from the last.
    local values  = {}   -- rows to write
    local present = {}   -- "container\0slot" -> true, everything the cache legitimately holds

    for container, slots in pairs(cache) do
        if type(slots) == 'table' then
            if not VALID_CONTAINERS[container] then
                print(('[whip_core:inv] SKIPPED unknown container "%s" for charId %s — not a valid ENUM member')
                    :format(tostring(container), tostring(charId)))
            else
                for slot, data in pairs(slots) do
                    if data and data.item then
                        local slotNum = tonumber(slot)
                        if not slotNum or slotNum < 1 or slotNum > MAX_SLOT or slotNum % 1 ~= 0 then
                            print(('[whip_core:inv] SKIPPED out-of-range slot %s in %s for charId %s')
                                :format(tostring(slot), container, tostring(charId)))
                        else
                            local key = container .. '\0' .. slotNum
                            present[key] = true

                            -- Carry the previous entry forward unchanged when nothing moved,
                            -- so an untouched slot costs neither a copy nor a row.
                            local prevSlot = prev and prev[key]
                            if slotUnchanged(prevSlot, data) then
                                nextSnap[key] = prevSlot
                            else
                                -- A row that can't be encoded (a NaN in its metadata) is skipped, as
                                -- promised above: it keeps its last saved state (present, so the diff
                                -- won't delete it) and the rest of the save goes through.
                                local okMeta, metaJson = true, '{}'
                                if data.metadata then okMeta, metaJson = pcall(json.encode, data.metadata) end
                                if okMeta then
                                    nextSnap[key] = snapshotSlot(data)
                                    values[#values + 1] = {
                                        charId, container, slotNum,
                                        data.item, data.amount or 1,
                                        metaJson,
                                    }
                                else
                                    nextSnap[key] = prevSlot
                                    print(('[whip_core:inv] SKIPPED %s in %s slot %d for charId %s — its metadata cannot be saved: %s')
                                        :format(tostring(data.item), container, slotNum, tostring(charId), tostring(metaJson)))
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Written only for rows that changed. An upsert, not REPLACE INTO (a delete and an insert,
    -- re-checking the foreign key and rewriting the item index).
    if #values > 0 then
        local placeholders = {}
        local params = {}
        for _, v in ipairs(values) do
            placeholders[#placeholders + 1] = '(?, ?, ?, ?, ?, ?)'
            for _, p in ipairs(v) do params[#params + 1] = p end
        end
        queries[#queries + 1] = {
            query = 'INSERT INTO `character_inventory` (`charId`, `container`, `slot`, `item`, `amount`, `metadata`) VALUES '
                .. table.concat(placeholders, ', ')
                .. ' ON DUPLICATE KEY UPDATE `item` = VALUES(`item`), `amount` = VALUES(`amount`), `metadata` = VALUES(`metadata`)',
            values = params,
        }
    end

    if prev then
        -- Only slots that were there and are not any more (smaller and safer than NOT IN).
        local goneKeys, goneParams = {}, { charId }
        for key in pairs(prev) do
            if not present[key] then
                local container, slotNum = key:match('^(.-)%z(%d+)$')
                if container then
                    goneKeys[#goneKeys + 1] = '(?, ?)'
                    goneParams[#goneParams + 1] = container
                    goneParams[#goneParams + 1] = tonumber(slotNum)
                end
            end
        end
        if #goneKeys > 0 then
            queries[#queries + 1] = {
                query = 'DELETE FROM `character_inventory` WHERE `charId` = ? AND (`container`, `slot`) IN ('
                    .. table.concat(goneKeys, ', ') .. ')',
                values = goneParams,
            }
        end
    else
        -- First save for this cache: what is on disk is unknown, so write everything and prune
        -- anything else.
        local keepKeys, keepParams = {}, { charId }
        for key in pairs(present) do
            local container, slotNum = key:match('^(.-)%z(%d+)$')
            if container then
                keepKeys[#keepKeys + 1] = '(?, ?)'
                keepParams[#keepParams + 1] = container
                keepParams[#keepParams + 1] = tonumber(slotNum)
            end
        end
        if #keepKeys > 0 then
            queries[#queries + 1] = {
                query = 'DELETE FROM `character_inventory` WHERE `charId` = ? AND (`container`, `slot`) NOT IN ('
                    .. table.concat(keepKeys, ', ') .. ')',
                values = keepParams,
            }
        else
            queries[#queries + 1] = {
                query = 'DELETE FROM `character_inventory` WHERE `charId` = ?',
                values = { charId },
            }
        end
    end

    -- Record what this build produced, for whip_test (by the time anything asks, the write has
    -- happened; what the build emitted is the only observable).
    Inventory._lastWrite = {
        charId      = charId,
        queries     = #queries,
        replaceRows = #values,
        deleteRows  = 0,
    }
    for _, q in ipairs(queries) do
        if q.query:find('DELETE', 1, true) then
            Inventory._lastWrite.deleteRows =
                Inventory._lastWrite.deleteRows + math.floor((#q.values - 1) / 2)
        end
    end

    -- What this cost, against a full rewrite (`present` is every row the character owns).
    local ifFull = 0
    for _ in pairs(present) do ifFull = ifFull + 1 end
    Stores.recordWrite(#values + Inventory._lastWrite.deleteRows, ifFull)

    -- Advance the snapshot only once the transaction committed: a failed save leaves the old
    -- snapshot, so the next attempt re-emits everything since the last success.
    local function confirm()
        _snapshots[cache] = nextSnap
    end

    return queries, confirm
end

--- Forget the snapshot for a cache, forcing the next save to write everything.
--- Only needed where a cache table is REUSED after the rows beneath it changed outside the
--- normal path — a raw DELETE in a test, for example.
---@param cache table
function Inventory.invalidateSnapshot(cache)
    if cache then _snapshots[cache] = nil end
end

--- Save inventory to DB as an atomic transaction. Returns the result.
---@param charId number
---@param cache table
---@return boolean ok
---@return string|nil err
function Inventory.save(charId, cache)
    if not cache then
        print(('[whip_core:inv] WARNING: save called for charId %d but cache is nil'):format(charId))
        return false, 'No inventory cache'
    end

    -- If this character is half of a pending transfer, the store layer writes it: writing only
    -- this character's rows would land half a move on disk. Stores.flushNow commits the whole
    -- group. The store handle comes from the group (this function has only a charId).
    -- Ungrouped (the common case) falls through to the direct write below.
    local unit = 'player:' .. tostring(charId)
    local linked = Stores and Stores.linkedStore and Stores.linkedStore(unit)
    if linked then
        return Stores.flushNow(linked)
    end

    -- One commit per unit here too (Stores._inflight): two diffs against one snapshot can delete a
    -- row the other just wrote, and these callers run while a teardown flush may be in flight.
    -- Waited for, bounded, as flushNow waits.
    local claimed = false
    if Stores and Stores.claimUnit then
        if not Stores.claimUnit(unit) then
            print(('[whip_core:inv] save for charId %d gave up waiting for an in-flight commit'):format(charId))
            return false, 'another commit is still in flight'
        end
        claimed = true
        -- Asked again after the wait: a move during it may have linked this unit to another.
        local nowLinked = Stores.linkedStore(unit)
        if nowLinked then
            Stores.releaseUnit(unit)
            return Stores.flushNow(nowLinked)
        end
    end
    local function release() if claimed then Stores.releaseUnit(unit) end end

    -- buildSaveQueries can raise (json.encode on malformed metadata): pcalled, so one bad item
    -- can't take down the caller.
    local built, queries, confirm = pcall(Inventory.buildSaveQueries, charId, cache)
    if not built then
        release()
        print(('[whip_core:inv] ERROR building save for charId %d: %s'):format(charId, tostring(queries)))
        return false, tostring(queries)
    end

    -- An empty query set means nothing changed: a success (a nil cache is caught at the top).
    -- A held payment waiting on this unit goes in this write too.
    local payQueries, settlePay = {}, nil
    if Stores and Stores.carriedQueriesFor then payQueries, settlePay = Stores.carriedQueriesFor(unit) end
    for _, q in ipairs(payQueries) do queries[#queries + 1] = q end

    if #queries == 0 then
        release()
        return true
    end

    local called, ok, err = pcall(Stores.runTransaction, queries)   -- a raise must still settle the payment
    if not called then ok, err = false, tostring(ok) end
    release()
    if settlePay then settlePay(ok, err) end
    if not ok then
        print(('[whip_core:inv] ERROR saving inventory for charId %d: %s'):format(charId, tostring(err)))
        return false, err
    end

    -- Committed. Only now may the snapshot advance.
    confirm()
    return true
end

-- ============================================
-- Cache Accessors
-- ============================================

---@param cache table
---@param container string
---@param slot number
---@return table|nil  {item, amount, metadata}
function Inventory.getSlot(cache, container, slot)
    if not cache[container] then return nil end
    return cache[container][slot]
end

--- Copy a metadata table so two slots can never share one.
---
--- The one implementation (Stores.copyMetadata delegates here).
---
--- Recursive and key-preserving, not a json round-trip: json would turn integer keys (a wallet's
--- `slots`) into strings.
---
--- Depth-limited: a satellite handing in a cycle must not overflow the stack. Past the limit the
--- branch is dropped (it could never have been saved as JSON anyway).
---@param meta table|nil
---@param depth number|nil  internal
---@return table|nil
function Inventory.copyMetadata(meta, depth)
    if meta == nil then return nil end
    if type(meta) ~= 'table' then return meta end
    depth = depth or 0
    if depth > 16 then return nil end

    local out = {}
    for k, v in pairs(meta) do
        out[k] = type(v) == 'table' and Inventory.copyMetadata(v, depth + 1) or v
    end
    return out
end

--- Write a slot.
---
--- Metadata is copied here, a framework guarantee: two slots sharing one table would be one item
--- (five wallets that are one wallet, five guns with one serial). Enforced at the choke point every
--- player-inventory write passes through, so no caller has to remember.
---
--- Reads are not copied: getSlot returns the live table, and read-modify-in-place
--- (`slotData.metadata.fuel = 50`) stays valid. Mutating your own table after handing it to setSlot
--- does not reach the slot.
---@param cache table
---@param container string
---@param slot number
function Inventory.setSlot(cache, container, slot, item, amount, metadata)
    if not cache[container] then cache[container] = {} end
    cache[container][slot] = {
        item     = item,
        amount   = amount or 1,
        metadata = Inventory.copyMetadata(metadata),
    }
end

---@param cache table
---@param container string
---@param slot number
function Inventory.clearSlot(cache, container, slot)
    if cache[container] then
        cache[container][slot] = nil
    end
end

-- Item definitions: Config.Items[key]. What an item costs to carry: Inventory.effectiveWeight.

-- ============================================
-- Weight Calculation
-- ============================================
--
-- Items inside items count: contents live in the host's metadata (a wallet's cash, a gun's
-- magazine), read the way its RegisterPanelItem registration declares (`read(host)`, or a slot
-- array at `metadata[storageKey]`). Recursive, so a magazine in a gun in a bag in a boot costs its
-- rounds at every level.

--- How deep to follow contents. Three levels covers bag → weapon → magazine, which is deeper
--- than anything real, and it means a metadata cycle cannot hang the server.
local MAX_WEIGHT_DEPTH = 4

--- What is inside this item, if anything?
---
--- Uses the item's panel registration. A read hook gets a MINIMAL host (item and metadata only),
--- so it must not depend on source, container or slot: the documented contract.
---@param itemKey string
---@param metadata table|nil
---@return table|nil  { [slot] = { item, amount, metadata } }
local function readContents(itemKey, metadata)
    if type(metadata) ~= 'table' then return nil end

    local cfg = Panels and Panels.itemConfigs[itemKey]
    if not cfg then return nil end

    if cfg.read then
        local ok, projected = pcall(cfg.read, { item = itemKey, metadata = metadata })
        -- A hook that errors reads as empty: a broken weight reading must not make an item unpickable.
        if ok and type(projected) == 'table' then return projected end
        return nil
    end

    local stored = metadata[cfg.storageKey or 'slots']
    return type(stored) == 'table' and stored or nil
end
Inventory.contentsOf = readContents

--- What this stack actually costs to carry, contents included.
---@param itemKey string
---@param amount number|nil
---@param metadata table|nil
---@param _depth number|nil  internal
---@return number
function Inventory.effectiveWeight(itemKey, amount, metadata, _depth)
    local def = Config.Items[itemKey]
    if not def then return 0 end

    amount = amount or 1
    local total = (def.weight or 0) * amount

    local depth = (_depth or 0) + 1
    if depth > MAX_WEIGHT_DEPTH then return total end

    local contents = readContents(itemKey, metadata)
    if not contents then return total end

    for _, entry in pairs(contents) do
        if type(entry) == 'table' and entry.item then
            -- Contents are weighed once, not per stacked host: a stack shares one metadata table.
            total = total + Inventory.effectiveWeight(entry.item, entry.amount or 1, entry.metadata, depth)
        end
    end

    return total
end

--- How far weight is followed down. The move into a bag refuses anything that would sit deeper,
--- so nothing can be packed where its weight stops counting.
Inventory.MAX_NESTING = MAX_WEIGHT_DEPTH

--- How many levels deep this item goes: 1 for an item with nothing inside, 2 for a bag of plain
--- items, 3 for a bag holding a loaded gun. Stops counting past MAX_WEIGHT_DEPTH + 1, which is all
--- a caller needs to know.
---@param itemKey string
---@param metadata table|nil
---@param _depth number|nil  internal
---@return number
function Inventory.nestingDepth(itemKey, metadata, _depth)
    local depth = (_depth or 0) + 1
    if depth > MAX_WEIGHT_DEPTH then return depth end

    local deepest = depth
    local contents = readContents(itemKey, metadata)
    if contents then
        for _, entry in pairs(contents) do
            if type(entry) == 'table' and entry.item then
                local d = Inventory.nestingDepth(entry.item, entry.metadata, depth)
                if d > deepest then deepest = d end
            end
        end
    end
    return deepest
end

---@param cache table
---@param container string
---@return number
function Inventory.getWeight(cache, container)
    if not cache[container] then return 0 end
    local total = 0
    for _, data in pairs(cache[container]) do
        total = total + Inventory.effectiveWeight(data.item, data.amount, data.metadata)
    end
    return math.floor(total * 100 + 0.5) / 100
end

--- What a character's pockets weigh, the main grid and the strip together.
---@param cache table
---@return number
function Inventory.pocketsWeight(cache)
    local total = 0
    for _, c in ipairs(PlayerContainers) do total = total + Inventory.getWeight(cache, c) end
    return total
end

--- The most the pockets carry, the grid and the strip together: the grid's own limit (Config.MaxWeight.player). The
--- strip alone also carries no more than its own (Config.MaxWeight.accessory). Stores.pocketsOver asks it of
--- everything coming in.
---@return number
function Inventory.pocketsMaxWeight()
    return Config.MaxWeight.player or 9999
end

local function isPocket(container)
    for _, c in ipairs(PlayerContainers) do if c == container then return true end end
    return false
end

--- Can this pocket container take `additionalWeight` more, from outside the pockets: its own limit, and the pockets'
--- together (Inventory.pocketsMaxWeight).
---@param cache table
---@param container string
---@param additionalWeight number
---@return boolean
function Inventory.canAcceptWeight(cache, container, additionalWeight)
    local current = Inventory.getWeight(cache, container)
    local max = Config.MaxWeight[container] or 9999
    if (current + additionalWeight) > max then return false end
    if additionalWeight > 0 and isPocket(container)
        and Inventory.pocketsWeight(cache) + additionalWeight > Inventory.pocketsMaxWeight() then
        return false
    end
    return true
end

-- ============================================
-- Moving items: through a store
-- ============================================
--
--     Stores.move(fromStore, fromSlot, toStore, toSlot)
--     Stores.player(source, 'player')   -- how you get a player-container store
--
-- The mover handles the swap, the merge, the metadata comparison and both weight budgets.

-- ============================================
-- Add Item (find slot, respect stacking)
-- ============================================

--- Will this slot of a player container take this item? Only the accessory strip can say no: a resource
--- may type one of its slots (RegisterAccessorySlot's `accepts`, the same rule the player store kind reads),
--- so an overflowing reward can't land a burger in a badge slot. whip's own five take anything.
---@param container string
---@param slot number
---@param item string
---@return boolean
function Inventory.slotTakes(container, slot, item)
    if container ~= 'accessory' then return true end
    local def = Inventory.AccessorySlots[slot]
    return def ~= nil and (not def.accepts or def.accepts == item)
end

-- ============================================
-- Who a new item is for
-- ============================================
--
-- An item's default metadata (RegisterItemDefaultMetadata) is made when the item comes into being. The
-- generator gets a second argument, ctx, so it can depend on who it is for (a SIM card carrying its
-- buyer's new number):
--   ctx.source, ctx.charId   the player receiving it, when there is one (nil into a stash, a boot...)
--   ctx.reason               'given' (AddItem, StoreGive), 'pickup' (off the ground), 'shelf' (shown
--                            on an infinite shop's shelf: nobody has bought it yet), 'bought'
-- ctx can be nil (the Director's item rewards run generators with the key alone), so a generator
-- must cope without one.
--
-- Bought off an infinite shelf, an item is made again for the buyer only if its generator asked
-- (RegisterItemDefaultMetadata(key, fn, { forBuyer = true })); every other item keeps the shelf's metadata.

--- [itemKey] = true: its generator runs again for the buyer at purchase (see above).
Inventory.MetaForBuyer = {}

--- The ctx a generator is handed for a player (or for nobody, with a nil source).
---@param source number|nil
---@param reason string
---@return table
function Inventory.metaContext(source, reason)
    local p = source and Players[source] or nil
    return { source = source, charId = p and p.charId or nil, reason = reason }
end

--- Run an item's generator: its table, or nil when it has none, errors or answers something else.
---@param gen function|table|nil  a callable (a satellite's arrives as a callable table)
---@param item string
---@param ctx table|nil
---@return table|nil
function Inventory.runMetaGen(gen, item, ctx)
    if gen == nil then return nil end
    local ok, result = pcall(gen --[[@as function]], item, ctx or { reason = 'given' })   -- (or a callable table)
    if ok and type(result) == 'table' then return result end
    return nil
end

---@param cache table
---@param container string
---@param item string  Config.Items key
---@param amount? number  default 1
---@param metadata table|nil
---@param ctx table|nil  who it is for, handed to the item's generator (Inventory.metaContext)
---@return boolean, string|nil
function Inventory.addItem(cache, container, item, amount, metadata, ctx)
    local def = Config.Items[item]
    if not def then
        return false, 'Unknown item'
    end

    -- A whole number of 1 or more.
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end

    -- Auto-generate metadata if none provided and a generator is registered. `metaGen` is kept:
    -- each slot this item lands in needs its own run (see the placement loop).
    local metaGen = nil
    local firstMeta = nil   -- the generated metadata, used by the FIRST slot (see the placement loop)
    if not metadata then
        metaGen = Inventory.MetaGenerators[item]
        if metaGen then
            local result = Inventory.runMetaGen(metaGen, item, ctx)
            if result then
                metadata = result
                firstMeta = result
            else
                metaGen = nil   -- a generator that errors is no generator
            end
        end
    end
    local maxSlots  = Config.ContainerSlots[container]
    if not maxSlots then
        return false, 'Invalid container'
    end
    -- Weight check
    if not Inventory.canAcceptWeight(cache, container, Inventory.effectiveWeight(item, amount, metadata)) then
        return false, 'Too heavy'
    end

    -- Stack onto an existing stack only when it IS the same item (Stores.stacksWith, as every drag).
    local stacksWith = Stores and Stores.stacksWith
    local function canTopUp(slotData)
        return slotData and slotData.item == item
            and (not stacksWith or stacksWith(slotData.metadata, metadata))
    end

    -- Room first, changes second: the whole amount is proven to fit before anything is touched, so
    -- a refusal changes nothing (callers retry the full amount elsewhere).
    local mergeable = def.stack and def.maxStack and def.maxStack > 1
    local existing = cache[container]
    local stackRoom, emptySlots = 0, 0
    for slot = 1, maxSlots do
        local slotData = existing and existing[slot]
        if not slotData then
            if Inventory.slotTakes(container, slot, item) then emptySlots = emptySlots + 1 end
        elseif mergeable and canTopUp(slotData) then
            stackRoom = stackRoom + math.max(0, def.maxStack - slotData.amount)
        end
    end
    -- Exactly what the placement loop below puts in each empty slot — it must agree with it, or
    -- this check would promise room the loop then cannot use.
    local perSlot = (def.stack and def.maxStack) and def.maxStack or 1
    if amount > stackRoom + (emptySlots * perSlot) then
        return false, 'No empty slots'
    end

    if not cache[container] then cache[container] = {} end
    local remaining = amount

    -- Fill existing stacks first
    if mergeable then
        for slot = 1, maxSlots do
            if remaining <= 0 then break end
            local slotData = cache[container][slot]
            if canTopUp(slotData) then
                local canAdd = def.maxStack - slotData.amount
                if canAdd > 0 then
                    local toAdd = math.min(canAdd, remaining)
                    slotData.amount = slotData.amount + toAdd
                    remaining = remaining - toAdd
                end
            end
        end
    end

    -- Place remainder into empty slots
    while remaining > 0 do
        local emptySlot = nil
        for slot = 1, maxSlots do
            if not cache[container][slot] and Inventory.slotTakes(container, slot, item) then
                emptySlot = slot
                break
            end
        end

        if not emptySlot then
            return false, 'No empty slots'
        end

        local stackSize
        if def.stack and def.maxStack then
            stackSize = math.min(remaining, def.maxStack)
        else
            stackSize = 1
        end

        -- A fresh generator run per slot, for identity (setSlot already prevents aliasing): a
        -- generator mints an item's identity (a gun's serial), so five guns need five calls.
        -- Caller-supplied metadata falls through, and setSlot copies it per slot.
        -- The first slot takes the run made for the weight check, so nothing real a generator mints
        -- (a SIM's phone number) is left orphaned.
        local slotMeta = metadata
        if firstMeta then
            slotMeta = firstMeta
            firstMeta = nil
        elseif metaGen then
            slotMeta = Inventory.runMetaGen(metaGen, item, ctx) or slotMeta
        end

        Inventory.setSlot(cache, container, emptySlot, item, stackSize, slotMeta)
        remaining = remaining - stackSize
    end

    return true
end

-- ============================================
-- Test items
-- ============================================
--
-- A Director test's or a Systems test's own items carry its stamp (metadata.director, metadata.systest) and go
-- back when it ends: from its players' pockets and the ground (server/director/effects.lua,
-- server/systems/test_items.lua), and at the next login or start for one that was missed. Where a stamped item
-- may be PUT is stores.lua's placement veto, so the end finds it. Nothing else treats it differently: builders are
-- trusted, and while the test lasts its items are used, spent and sold like any other. A live Director run stamps
-- nothing: its items are real.

--- `only`: count and take ONLY the stacks whose metadata carries every one of its values ({ only = { fromRun =
--- runId } }: a Director goal that wants the run's own package, never the player's own of the same item). nil:
--- every stack.
local function skips(only, data)
    if type(only) ~= 'table' or type(only.only) ~= 'table' then return false end
    local md = data.metadata
    for k, v in pairs(only.only) do
        if type(md) ~= 'table' or md[k] ~= v then return true end
    end
    return false
end

--- The rule that counts and takes only the stacks carrying `match` (e.g. { director = runId }).
---@param match table
---@return table
function Inventory.onlyStamped(match) return { only = match } end

-- ============================================
-- Remove Item (across stacks, last slots first)
-- ============================================

---@param cache table
---@param container string
---@param item string
---@param amount? number  default 1
---@param only table|nil  Inventory.onlyStamped(match): take only the stacks carrying it (nil: any)
---@param taken table|nil  when given, each stack taken is added to it as { amount, metadata } — the items
---                        themselves, for a caller that passes them on (a payment into a stock room)
---@return boolean, string|nil
function Inventory.removeItem(cache, container, item, amount, only, taken)
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end

    -- An unknown container is refused, as addItem refuses it.
    local maxSlots = Config.ContainerSlots[container]
    if not maxSlots then
        return false, 'Invalid container'
    end

    if not cache[container] then
        return false, 'Container empty'
    end

    -- Count total first — the slots it can take from, the same ones the loop below walks.
    local total = Inventory.getItemCount(cache, container, item, only)
    if total < amount then
        return false, 'Not enough items'
    end

    -- Remove from highest slots first (preserve lower)
    local remaining = amount
    for slot = maxSlots, 1, -1 do
        if remaining <= 0 then break end
        local data = cache[container][slot]
        if data and data.item == item and not skips(only, data) then
            if data.amount <= remaining then
                remaining = remaining - data.amount
                if taken then taken[#taken + 1] = { amount = data.amount, metadata = Inventory.copyMetadata(data.metadata) } end
                Inventory.clearSlot(cache, container, slot)
            else
                data.amount = data.amount - remaining
                if taken then taken[#taken + 1] = { amount = remaining, metadata = Inventory.copyMetadata(data.metadata) } end
                remaining = 0
            end
        end
    end

    return true
end

-- ============================================
-- Has Item / Get Count
-- ============================================

---@param cache table
---@param container string
---@param item string
---@param amount number|nil  defaults to 1
---@return boolean
function Inventory.hasItem(cache, container, item, amount)
    amount = Sanitize.amount(amount, 1)
    if not amount then return false end   -- "has at least -3" is not a question
    return Inventory.getItemCount(cache, container, item) >= amount
end

--- How many of `item` a container holds IN ITS SLOTS — 1 to Config.ContainerSlots[container].
---
--- Only those: after the config lowers a slot count, items above it stay in the cache, unreachable.
--- Every count, and so every "have" and "take", agrees on this.
---@param cache table
---@param container string
---@param item string
---@param only table|nil  count only the stacks carrying it (see removeItem)
---@return number
---@diagnostic disable-next-line: duplicate-set-field -- the client's Inventory is a different table
function Inventory.getItemCount(cache, container, item, only)
    local slots = cache[container]
    if not slots then return 0 end
    local maxSlots = Config.ContainerSlots[container] or math.huge

    local total = 0
    for slot, data in pairs(slots) do
        local n = tonumber(slot)
        if n and n <= maxSlots and data.item == item and not skips(only, data) then total = total + data.amount end
    end

    return total
end

-- ============================================
-- Cross-Container Helpers
-- ============================================

--- Count total quantity of an item across every container the player carries
---@param cache table
---@param item string
---@param only table|nil  count only the stacks carrying it (see removeItem)
---@return number
function Inventory.getItemCountAcrossContainers(cache, item, only)
    local total = 0
    for _, container in ipairs(PlayerContainers) do
        total = total + Inventory.getItemCount(cache, container, item, only)   -- in-slot only
    end
    return total
end

--- Add an item wherever it fits, trying the player's containers in order.
---
--- Walks PlayerContainers rather than naming containers.
---@param cache table
---@param item string
---@param amount number
---@param metadata table|nil
---@param ctx table|nil  who it is for (Inventory.metaContext)
---@return boolean success
---@return string|nil error
function Inventory.addItemWithFallback(cache, item, amount, metadata, ctx)
    local lastErr
    for _, container in ipairs(PlayerContainers) do
        local ok, err = Inventory.addItem(cache, container, item, amount, metadata, ctx)
        if ok then return true end
        lastErr = err or lastErr
    end
    return false, lastErr or 'No room in any container'
end

--- Remove item across every player container in order (checks total first)
---@param cache table
---@param item string
---@param amount? number  default 1
---@param only table|nil  take only the stacks carrying it (see removeItem)
---@param taken table|nil  collects the stacks taken, as removeItem's
---@return boolean success
---@return string|nil error
function Inventory.removeItemAcrossContainers(cache, item, amount, only, taken)
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end   -- see removeItem

    -- Total first, so a partial removal can never happen.
    local total = Inventory.getItemCountAcrossContainers(cache, item, only)
    if total < amount then
        return false, 'Not enough items (have ' .. total .. ', need ' .. amount .. ')'
    end

    local remaining = amount

    -- Drain the containers in order.
    for _, container in ipairs(PlayerContainers) do
        if remaining <= 0 then break end
        if cache[container] then
            local have = Inventory.getItemCount(cache, container, item, only)
            if have > 0 then
                local toRemove = math.min(have, remaining)
                Inventory.removeItem(cache, container, item, toRemove, only, taken)
                remaining = remaining - toRemove
            end
        end
    end

    return true
end

-- ============================================
-- whip_core:item:added / :removed — every change, from one place
-- ============================================
--
-- Not fired from call sites. Every change to a player's pockets ends in a push to its owner
-- (Inventory.syncToClient, the only place an inventoryUpdate is sent) or a save (syncAndPersist);
-- both call Inventory.announceChanges, which compares what the player carries NOW, per item, with
-- what it last announced, and fires one event per item that went up or down. A new path is covered
-- the moment it pushes, and nothing fires twice.
--
-- Counted: the player's own containers (pockets, accessory strip), not the insides of a bag they
-- carry (cash moved into a wallet is "removed" from the pockets).
--
-- The payload is one table: { source, item, amount, count = what they carry now, reason = the
-- caller's reason, by = the resource that asked }. reason and by are known only for changes made
-- through the exports (AddItem, RemoveItem, the cash exports, StoreGive...), which note them just
-- before they push.

--- [source] = { [itemKey] = count } as last announced; nil until the baseline is taken.
local _carried = {}

--- [source] = { reason, by, at } — left by an export just before the push that announces it.
local _pendingReason = {}

--- A note is only trusted for the push that follows it; one left behind by a path that never
--- pushed must not label the next, unrelated change.
local REASON_TTL_MS = 1000

---@param cache table
---@return table<string, number>
local function countCarried(cache)
    local counts = {}
    for _, container in ipairs(PlayerContainers) do
        local slots = cache[container]
        if slots then
            for _, d in pairs(slots) do
                if type(d) == 'table' and d.item then
                    counts[d.item] = (counts[d.item] or 0) + (tonumber(d.amount) or 1)
                end
            end
        end
    end
    return counts
end

--- Say why the NEXT announced change for this player happened. Call it just before the push.
---
--- The event gets the caller's words, not the log line: callers often hand over the logged text
--- ('rental refund · by my_rentals', or only 'by my_rentals'), so the `· by ...` tail is taken off
--- here, once, and `e.reason == 'rental refund'` matches (whip_test 46).
---@param source number
---@param reason string|nil  the caller's own words, or the logged text (Log.reasonFrom) — either works
---@param by string|nil      'by <resource>' — Log.byCaller()
function Inventory.noteChangeReason(source, reason, by)
    if not source then return end
    if reason and by then
        if reason == by then
            reason = nil   -- no reason was given; the log line was only who asked
        else
            local tail = ' · ' .. by
            if #reason > #tail and reason:sub(-#tail) == tail then
                reason = reason:sub(1, #reason - #tail)
            end
        end
    end
    _pendingReason[source] = { reason = reason, by = by, at = GetGameTimer() }
end

--- Take the baseline for a player without announcing anything — at load.
---@param source number
---@param player table
function Inventory.resetCarried(source, player)
    if not source then return end
    _carried[source] = (player and player.inventory) and countCarried(player.inventory) or nil
    _pendingReason[source] = nil
end

--- Fire whip_core:item:added / :removed for everything that changed since the last call for this player.
---@param source number
---@param player table
function Inventory.announceChanges(source, player)
    if not source or not player or not player.inventory then return end
    -- Only a player's own live session: an admin editing an offline character's cache goes through
    -- the same save helpers, and must not be announced against whoever holds that source number.
    if Players[source] ~= player then return end
    local now = countCarried(player.inventory)
    local before = _carried[source]
    _carried[source] = now
    if not before then return end   -- no baseline yet: this call takes it

    local note = _pendingReason[source]
    _pendingReason[source] = nil
    if note and (GetGameTimer() - note.at) > REASON_TTL_MS then note = nil end

    local reason = note and note.reason or nil
    local by     = note and note.by or nil

    for item, n in pairs(now) do
        local was = before[item] or 0
        if n > was then
            WhipEmit('whip_core:item:added',
                { source = source, item = item, amount = n - was, count = n, reason = reason, by = by })
        end
    end
    for item, was in pairs(before) do
        local n = now[item] or 0
        if n < was then
            WhipEmit('whip_core:item:removed',
                { source = source, item = item, amount = was - n, count = n, reason = reason, by = by })
        end
    end
end

-- A source number is reused for the next player to join, so the baseline is cleared at logout. A
-- hook (not a handler on the public event anyone can fire), and the only clear: it runs on the drop
-- path too, after the teardown's give-backs, so those still announce.
Character.onLife('logout', function(e)
    _carried[e.source] = nil
    _pendingReason[e.source] = nil
end)

--- How many of `item` one of the player's containers can take now, by its weight left and its room (stacks it would
--- merge with, and empty slots that take it): the rules Inventory.addItem keeps. When it takes none, the second
--- answer says what stops it: 'Too heavy' or 'No empty slots'.
---@return number room
---@return string|nil full
local function roomIn(cache, container, item, def, metadata)
    local maxSlots  = Config.ContainerSlots[container] or 0
    local maxWeight = Config.MaxWeight[container] or 9999
    local currentWeight = Inventory.getWeight(cache, container)
    -- Its own limit, and the pockets' together (Inventory.pocketsMaxWeight): a full grid leaves the strip no room.
    local remainingWeight = math.min(maxWeight - currentWeight,
        Inventory.pocketsMaxWeight() - Inventory.pocketsWeight(cache))

    -- How many fit by weight: the EFFECTIVE weight of one (contents count), clamped at zero
    -- (someone over their limit has negative room).
    local unitWeight = Inventory.effectiveWeight(item, 1, metadata)
    local byWeight
    if unitWeight > 0 then
        byWeight = math.max(0, math.floor(remainingWeight / unitWeight))
    else
        byWeight = 999999
    end

    -- How many items fit by slot/stack capacity?
    local bySlots = 0

    -- Read only: a capacity check must not create `cache[container]` (it runs against a
    -- recipient's cache).
    local slots = cache[container]

    -- Space in existing stacks it would actually merge with (Stores.stacksWith, as addItem).
    local stacksWith = Stores and Stores.stacksWith
    if slots and def.stack and def.maxStack and def.maxStack > 1 then
        for slot = 1, maxSlots do
            local slotData = slots[slot]
            if slotData and slotData.item == item
                and (not stacksWith or stacksWith(slotData.metadata, metadata)) then
                bySlots = bySlots + math.max(0, def.maxStack - slotData.amount)
            end
        end
    end

    -- Empty slots — that would take it (the accessory strip's slots are typed)
    for slot = 1, maxSlots do
        if not (slots and slots[slot]) and Inventory.slotTakes(container, slot, item) then
            bySlots = bySlots + (def.stack and def.maxStack or 1)
        end
    end

    local room = math.min(byWeight, bySlots)
    if room > 0 then return room, nil end
    return 0, bySlots == 0 and 'No empty slots' or 'Too heavy'
end

--- Pre-check whether an item can fit across the player's containers.
---
--- `metadata` is optional, and matters for anything that carries contents: without it this measures
--- an EMPTY instance (an empty wallet). Pass the instance's metadata whenever you have it.
---@param cache table
---@param item string
---@param amount? number  default 1
---@param metadata table|nil  the instance's metadata, if this is about a specific one
---@return boolean canFit
---@return number availableCapacity
---@return string|nil full  when none fit: 'Too heavy' or 'No empty slots' (the main pockets' reason)
function Inventory.canFitItem(cache, item, amount, metadata)
    local def = Config.Items[item]
    if not def then return false, 0 end

    -- A bad amount fits nowhere; the CanFitItem export says why.
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, 0 end

    local totalCapacity, full = 0, nil
    for _, container in ipairs(PlayerContainers) do
        local room, why = roomIn(cache, container, item, def, metadata)
        totalCapacity = totalCapacity + room
        full = full or why
    end
    -- Each container's room counts the pockets' shared weight left (roomIn): the sum must not count it twice.
    local unitWeight = Inventory.effectiveWeight(item, 1, metadata)
    if unitWeight > 0 then
        local shared = math.max(0, math.floor((Inventory.pocketsMaxWeight() - Inventory.pocketsWeight(cache)) / unitWeight))
        if shared < totalCapacity then
            totalCapacity = shared
            if shared == 0 then full = 'Too heavy' end
        end
    end

    return totalCapacity >= amount, totalCapacity, totalCapacity == 0 and full or nil
end

--- Add as many of `amount` as the player's containers take now, filling each in PlayerContainers order to its own
--- room (roomIn): a pile too big for the pockets fills them, then the strip. All of it, part of it, or none; what
--- did not go in is the caller's to put back.
---@param cache table
---@param item string
---@param amount? number  default 1
---@param metadata table|nil
---@param ctx table|nil  who it is for (Inventory.metaContext)
---@return number added
---@return string|nil why  when none went in
function Inventory.addUpTo(cache, item, amount, metadata, ctx)
    local def = Config.Items[item]
    if not def then return 0, 'Unknown item' end
    amount = Sanitize.amount(amount, 1)
    if not amount then return 0, Sanitize.AMOUNT_ERR end

    local added, why = 0, nil
    for _, container in ipairs(PlayerContainers) do
        if added >= amount then break end
        local room, full = roomIn(cache, container, item, def, metadata)
        local n = math.min(room, amount - added)
        if n > 0 then
            local ok, err = Inventory.addItem(cache, container, item, n, metadata, ctx)
            if ok then added = added + n else why = why or err end
        else
            why = why or full
        end
    end
    if added == 0 then return 0, why or 'No room' end
    return added
end

-- ============================================
-- Serialize for NUI (slot keys as strings)
-- ============================================

---@param cache table
---@return table
function Inventory.serialize(cache)
    local result = { player = {}, accessory = {} }

    for container, slots in pairs(cache) do
        -- Only containers the character has: with the strip off, anything waiting in it stays unseen (Inventory.load).
        if result[container] and Inventory.isPlayerContainer(container) then
            for slot, data in pairs(slots) do
                result[container][tostring(slot)] = {
                    item     = data.item,
                    amount   = data.amount,
                    metadata = data.metadata,
                    -- What this stack weighs, contents and all: sent, because working it out
                    -- needs each item's server-side `read` hook.
                    w = Inventory.effectiveWeight(data.item, data.amount, data.metadata),
                }
            end
        end
    end

    return result
end

-- ============================================
-- Item images — where an icon actually lives
-- ============================================
--
-- A resource ships its own item art. FiveM serves any resource's declared files at
-- `https://cfx-nui-<resource>/<path>`, and an <img> may load across that boundary (no-cors, unlike
-- fetch). whip_core knows who registered each item (Inventory.itemOwner), so it works out where an
-- icon lives without being told.
--
-- The satellite's side of the contract is one line in its fxmanifest:
--
--     files { 'html/img/items/*.webp', 'html/img/items/*.png' }
--
-- plus a picture named after the item key, WebP or PNG. Nothing is copied, nothing is registered,
-- and a whip_core update cannot delete it because it was never inside whip_core.
--
-- nil means "whip_core's own PNG", which keeps every existing item working untouched.

local ITEM_IMG_DIR = 'html/img/items/'

--- The formats an icon may be in, in the order they are looked for. WebP first: the same picture at
--- a fraction of the size (every client downloads every icon). A resource may ship either, or mix.
local ITEM_IMG_EXTS = { 'webp', 'png' }

--- [resource] = { [itemKey] = path of the icon found, relative to that resource | false }. Looked
--- up on disk once per item: the definitions are rebuilt on every registration burst, and reading a
--- file each time would be the waste the definitions cache exists to avoid.
local _itemImgFound = {}

--- The icon file this resource ships for this item, or nil when it ships none.
---@param res string
---@param key string
---@return string|nil path  relative to the resource's root
local function findItemImage(res, key)
    local known = _itemImgFound[res]
    if not known then
        known = {}
        _itemImgFound[res] = known
    end
    local found = known[key]
    if found == nil then
        found = false
        for _, ext in ipairs(ITEM_IMG_EXTS) do
            local path = ITEM_IMG_DIR .. key .. '.' .. ext
            if LoadResourceFile(res, path) ~= nil then
                found = path
                break
            end
        end
        known[key] = found
    end
    return found or nil
end

-- A resource that (re)starts may bring new pictures — a PNG swapped for a WebP changes the URL — so
-- what was found for it is forgotten, and when it had items the clients are told their definitions
-- are stale (once; see Inventory.invalidateItemDefs, below).
AddEventHandler('onResourceStart', function(res)
    if _itemImgFound[res] == nil then return end
    _itemImgFound[res] = nil
    Inventory.invalidateItemDefs()
end)

--- `image = '@<resource>/<path>'`: a picture in another resource, for an item registered on its behalf (whip_gunny
--- registers a weapon pack's guns, whose pictures are the pack's). Its URL, or nil when `image` is not one.
---@param image any
---@return string|nil url
local function otherResourceImage(image)
    if type(image) ~= 'string' then return nil end
    local res, path = image:match('^@([%w_%-%.]+)/([%w_%-%./]+)$')
    if not res or path:find('..', 1, true) then return nil end
    return ('https://cfx-nui-%s/%s'):format(res:lower(), path)
end

--- Where this item's icon lives, as an absolute URL the NUI can load.
---@param key string
---@param def table
---@return string|nil url  nil for whip_core's own PNG items — the NUI falls back to its built-in path
function Inventory.resolveItemImage(key, def)
    local other = otherResourceImage(def.image)
    if other then return other end
    local res = Inventory.itemOwner and Inventory.itemOwner(key)
    local core = GetCurrentResourceName()
    if not res or res == core then
        -- whip_core's own: the NUI's built-in path is img/items/<key>.png beside its page, so only
        -- a WebP needs saying.
        local found = findItemImage(core, key)
        if found and found:sub(-5) == '.webp' then
            return ('https://cfx-nui-%s/%s'):format(core:lower(), found)
        end
        return nil
    end

    if res == 'unknown' then
        -- GetInvokingResource() came back nil at registration, so nothing knows where the icon
        -- lives. The item still works; it just cannot be given one.
        return nil
    end

    -- def.image is relative to the OWNING resource's root (or names another: '@res/path', above). Lowercase the
    -- resource name: the scheme handler is registered lowercased, so 'whip_Gunny' would 404. No
    -- picture at all still answers the PNG path, as it always did: the NUI then tries whip_core's
    -- folder and falls back to missing.png.
    local path = def.image or findItemImage(res, key) or (ITEM_IMG_DIR .. key .. '.png')
    return ('https://cfx-nui-%s/%s'):format(res:lower(), path)
end

-- ============================================
-- An item's right-click options (the rules are server/item_options.lua)
-- ============================================

--- Options other resources added to items they do not own (AddItemOption, below), the registry's
--- store: ['<itemKey>|<action>'] = { item = itemKey, option = option }.
Inventory.AddedOptions = {}

--- An item's options: its own (its definition's contextOptions), then the ones other resources added,
--- by action name. Its own win a clash. nil for none.
---@param itemKey string
---@return table|nil
function Inventory.itemOptions(itemKey)
    local def = Config.Items[itemKey]
    local list, seen = {}, {}
    if def and type(def.contextOptions) == 'table' then
        for _, opt in ipairs(def.contextOptions) do
            list[#list + 1] = opt
            seen[opt.action] = true
        end
    end
    local added = {}
    for _, entry in pairs(Inventory.AddedOptions) do
        if entry.item == itemKey and not seen[entry.option.action] then added[#added + 1] = entry.option end
    end
    table.sort(added, function(a, b) return a.action < b.action end)
    for _, opt in ipairs(added) do list[#list + 1] = opt end
    return list[1] and list or nil
end

--- One of an item's options by its action, or nil.
---@param itemKey string
---@param action string
---@return table|nil
function Inventory.optionFor(itemKey, action)
    for _, opt in ipairs(Inventory.itemOptions(itemKey) or {}) do
        if opt.action == action then return opt end
    end
    return nil
end

--- A require as Requirements.met reads it, made once per option (weak: an option
--- replaced by a new registration takes its copy with it).
local _cleanRequire = setmetatable({}, { __mode = 'k' })

--- May this player use this option on this item NOW? The server's answer: the page only hid what
--- did not pass. Answers true, or false and what to tell them.
---@param source number
---@param player table
---@param opt table  from Inventory.optionFor
---@param slotData table|nil  the item, for its `when`
---@return boolean
---@return string|nil why
function Inventory.optionAllowed(source, player, opt, slotData)
    if opt.when and not ItemOptions.whenMet(opt.when, slotData and slotData.metadata) then
        return false, opt.whyNot or ("%s isn't possible right now"):format(opt.label)
    end
    if opt.require then
        local req = _cleanRequire[opt]
        if req == nil then
            local clean = Requirements.clean(opt.require)
            -- A word it could not read is a refusal, never no requirement (config.lua's options were read before
            -- the reader was there: server/item_options.lua)
            req = Requirements.lost(opt.require, clean) and 'unreadable' or (clean or false)
            _cleanRequire[opt] = req
        end
        if req == 'unreadable' then return false, opt.whyNot or ("%s isn't possible right now"):format(opt.label) end
        if req then
            local ok, why = Requirements.met(source, player, req)
            if not ok then return false, why end
        end
    end
    return true
end

--- The root of the resource an item's `images` paths are in (the Items page shows them too).
---@param key string
---@return string
function Inventory.imageRoot(key)
    local res = Inventory.itemOwner and Inventory.itemOwner(key)
    if not res or res == 'unknown' then res = GetCurrentResourceName() end
    return ('https://cfx-nui-%s/'):format(res:lower())
end

--- Build item definitions for NUI (stripped of server-only fields)
---@return table
function Inventory.getItemDefs()
    local defs = {}
    for key, def in pairs(Config.Items) do
        defs[key] = {
            name     = def.name,
            desc     = def.desc,
            weight   = def.weight,
            type     = def.type,
            stack    = def.stack,
            maxStack = def.maxStack,
            css      = def.css,
            usable   = def.usable,
            -- Its own and the ones other resources added (AddItemOption), each with its when and
            -- require: the page shows what passes (client/inventory.lua answers the require).
            contextOptions = Inventory.itemOptions(key),
            -- What a pile of it offers after Pick up (client/ground.lua's prompt; server/item_options.lua).
            groundOptions  = def.groundOptions,
            -- Picked up with both hands ('2h') or one (client/ground.lua's grab; its /whip Items page).
            grab           = def.grab == '2h' and '2h' or nil,
            -- Held out to give, the player keeps their own walk (client/inventory.lua's give mode; its /whip Items page).
            playerWalk     = def.playerWalk == true or nil,
            metaFields     = def.metaFields,
            defaultAction  = def.defaultAction,
            -- nil for whip_core's own items: the NUI then uses its built-in path.
            img            = Inventory.resolveItemImage(key, def),
            -- The pictures that depend on the item (server/item_options.lua), and the root of the
            -- resource their paths are in.
            images         = def.images,
            imgRoot        = def.images and Inventory.imageRoot(key) or nil,
            -- The world model, for client Lua (the hand prop, the thrown prop, a dropped item).
            -- Client Lua merges this list into its own Config.Items, which otherwise knows only
            -- the items in the config file and not one a satellite registered.
            prop           = type(def.prop) == 'string' and def.prop or nil,
        }
    end
    return defs
end

-- ---- The item-definition cache ----
--
-- Item definitions change only when a resource registers an item, so the payload is cached and
-- invalidated on registration rather than rebuilt on every open.
local _itemDefsCache = nil
local _staleQueued   = false

--- Invalidate the cached item-definition payload. Called by RegisterItem.
function Inventory.invalidateItemDefs()
    _itemDefsCache = nil

    -- And tell every client its copy is stale: clients say on each open that they hold the
    -- definitions (Inventory.buildPayload leaves them out), so a new item would otherwise render
    -- nameless until they reconnect. A flag, not the definitions (the next open pulls the new copy),
    -- and one per burst: queued for the next tick, since registrations come fifty at a time at boot.
    if not _staleQueued then
        _staleQueued = true
        SetTimeout(0, function()
            _staleQueued = false
            TriggerClientEvent('whip_core:client:itemDefsStale', -1)
        end)
    end

    -- And forget the server's record that each player is up to date (a stash open doesn't carry
    -- the client's correction; only a plain inventory open does).
    if Players then
        for _, player in pairs(Players) do player._haveItemDefs = false end
    end
end

--- Item definitions for the NUI, built at most once per registration change.
---@return table
function Inventory.cachedItemDefs()
    if not _itemDefsCache then
        _itemDefsCache = Inventory.getItemDefs()
    end
    return _itemDefsCache
end

-- ============================================
-- Accessory + Ignition Slot Registry
-- ============================================
--
-- The stat system's contract, for the accessory slots and the ignition keys: registration is a
-- self-describing config, re-registration is idempotent, the registry broadcasts on every change
-- and on resource start, and a stopping satellite's entries are unregistered and rebroadcast. The
-- server's checks (the player store kind for `accepts`, the ignition gate and key sweeps) read
-- this table; the NUI's copies only make refusals instant.

Inventory.AccessorySlots = {}     -- [slot] = { slot, accepts, label, icon?, iconSvg? }
Inventory.IgnitionKeys   = {}     -- [itemName] = true

--- The wire payload both broadcast paths and the login sync share.
function Inventory.getSlotDefsPayload()
    local slots = {}
    for _, def in pairs(Inventory.AccessorySlots) do
        slots[#slots + 1] = {
            slot   = def.slot,
            accepts = def.accepts,
            label  = def.label,
            icon   = def.icon,
            iconSvg = def.iconSvg,
        }
    end
    table.sort(slots, function(a, b) return a.slot < b.slot end)
    local keys = {}
    for item in pairs(Inventory.IgnitionKeys) do keys[#keys + 1] = item end
    table.sort(keys)
    return { accessorySlots = slots, ignitionKeys = keys }
end

local function broadcastSlotDefs()
    TriggerClientEvent('whip_core:client:invSlotDefs', -1, Inventory.getSlotDefsPayload())
end

--- A slot definition, COPIED: the caller keeps no live reference into the registry (same rule as
--- Stats.register).
local function copySlotDef(def)
    return {
        slot    = def.slot,
        accepts = type(def.accepts) == 'string' and def.accepts or nil,
        label   = type(def.label) == 'string' and def.label or 'Accessory',
        icon    = type(def.icon) == 'string' and def.icon or nil,
        iconSvg = type(def.iconSvg) == 'string' and def.iconSvg or nil,
    }
end

--- whip's own definition of a slot (shared/inventory_shape.lua), if it has one.
local function seededSlot(slot)
    for _, def in ipairs(AccessoryStripSlots) do
        if def.slot == slot then return def end
    end
    return nil
end

-- Both on the one registration rule (shared/registry.lua): a second resource registering a taken
-- slot is refused. Ignition keys are a SHARED registry, held until the last resource that
-- registered one stops.
--
-- whip's own slots are defaults, not claims: a resource may replace one at runtime (whip_test does,
-- slot 4, for one test run), and when it stops or releases the registration's tag the default comes
-- back (onRemove). whip_core's own ignition keys are seeded as held.
local _accessorySlots = Registry.new('AccessorySlot', {
    label = 'accessory slot',
    store = Inventory.AccessorySlots,
    onAdd = function() broadcastSlotDefs() end,
    onRemove = function(slot)
        local seeded = seededSlot(slot)
        if seeded then Inventory.AccessorySlots[slot] = copySlotDef(seeded) end
        broadcastSlotDefs()
    end,
})

local _ignitionKeys = Registry.new('IgnitionKey', {
    label    = 'ignition key',
    store    = Inventory.IgnitionKeys,
    shared   = true,
    onAdd    = function() broadcastSlotDefs() end,
    onRemove = function() broadcastSlotDefs() end,
})

--- Register (or replace) one accessory-strip slot.
---
--- `tag` is a run tag (shared/registry.lua): exports.whip_core:ReleaseTag(tag) puts whip's own slot back,
--- for a slot that should only last as long as one run of something.
---@param def table { slot (1..Config.ContainerSlots.accessory), accepts?, label?, icon?, iconSvg?, tag? }
---@param owner string|nil  the registering resource; nil writes a config default (no owner)
---@return boolean ok
---@return string|nil err
function Inventory.RegisterAccessorySlot(def, owner)
    if type(def) ~= 'table' or type(def.slot) ~= 'number' then
        return false, 'def.slot (number) is required'
    end
    if not HAS_STRIP then
        return false, 'this server has no accessory strip (Config.AccessoryStrip is off)'
    end
    local maxSlots = Config.ContainerSlots.accessory or 5
    if def.slot < 1 or def.slot > maxSlots or def.slot % 1 ~= 0 then
        return false, ('slot must be a whole number 1..%d (Config.ContainerSlots.accessory)'):format(maxSlots)
    end

    if owner == nil then
        Inventory.AccessorySlots[def.slot] = copySlotDef(def)
        return true
    end

    local ok, why = _accessorySlots:add(owner, def.slot, copySlotDef(def), def.tag ~= nil and { tag = def.tag } or nil)
    if not ok then return false, why --[[@as string]] end
    return true
end

--- Register an item the vehicle ignition slot accepts — and that the key sweeps count.
---@param itemName string
---@param owner string  the registering resource
---@return boolean ok
---@return string|nil err
function Inventory.RegisterIgnitionKey(itemName, owner)
    if type(itemName) ~= 'string' or itemName == '' then
        return false, 'itemName (string) is required'
    end
    local ok, why = _ignitionKeys:add(owner or GetCurrentResourceName(), itemName, true)
    if not ok then return false, why --[[@as string]] end
    return true
end

--- The one question the ignition gate and the key sweeps ask.
---@param itemName string|nil
---@return boolean
function Inventory.isIgnitionKey(itemName)
    return itemName ~= nil and Inventory.IgnitionKeys[itemName] == true
end

exports('RegisterAccessorySlot', function(def)
    local owner = Registry.caller()   -- first, before anything can yield
    return Inventory.RegisterAccessorySlot(def, owner)
end)

--- What the accessory strip looks like right now.
---
--- The read side of RegisterAccessorySlot: which slots exist and what each accepts. A copy, not the
--- registry (writing goes through registration, with validation and an owner).
---
---@return table<number, { slot: number, accepts: string|nil, label: string, icon: string|nil }>
exports('GetAccessorySlots', function()
    local out = {}
    for slot, def in pairs(Inventory.AccessorySlots) do
        out[slot] = {
            slot    = def.slot,
            accepts = def.accepts,
            label   = def.label,
            icon    = def.icon,
        }
    end
    return out
end)

exports('RegisterIgnitionKey', function(itemName)
    local owner = Registry.caller()   -- first, before anything can yield
    return Inventory.RegisterIgnitionKey(itemName, owner)
end)

-- Seed whip's own slots. File scope is safe: this file loads before any satellite registers,
-- and the values are plain tables with no dependency on load order. No broadcast here: the
-- onResourceStart below sends the whole set once. With the strip off nothing is seeded (the
-- registration refuses), so the strip goes to every client empty and the screen leaves it out.
for _, def in ipairs(AccessoryStripSlots) do
    Inventory.RegisterAccessorySlot(def, nil)   -- a default, owned by nobody (see above)
end
--- whip_core's own ignition keys: the items the ignition slot takes and starts a car with. Code, not a
--- setting: a resource with a key of its own registers it (RegisterIgnitionKey).
local IGNITION_KEYS = { 'vehicle_key', 'hacked_vehicle_key' }
for _, item in ipairs(IGNITION_KEYS) do
    Inventory.IgnitionKeys[item] = true
    _ignitionKeys:setOwner(item, GetCurrentResourceName())
end

-- (The strip is on or off, Config.AccessoryStrip, applied at a restart.)


-- The three handler registries, on the one registration rule (shared/registry.lua): a second
-- satellite taking a key is refused with the first one's name; the same handler again (an onReady
-- re-fire) is a no-op; a stopped resource's handlers are swept. The stores are the tables the rest
-- of whip reads (Inventory.UseHandlers, .ContextActions, .MetaGenerators).
local _actions = Registry.new('ContextAction', { label = 'context action', store = Inventory.ContextActions,
                                                 prefixed = true })
local _uses    = Registry.new('UseHandler', { label = 'use handler', store = Inventory.UseHandlers })
local _metas   = Registry.new('ItemDefaultMeta', { label = 'metadata generator', store = Inventory.MetaGenerators })

--- Put a handler in one of the three owned registries.
---
--- Answers `true` or `false, reason`, so a satellite learns its registration was refused.
---@param reg table     one of the three registries above
---@param owner string  who it belongs to, read by the export before anything else
---@return boolean ok
---@return string|nil err
local function registerOwned(reg, key, handler, owner)
    if type(key) ~= 'string' or key == '' then
        return false, ('a %s needs a string key'):format(reg.label)
    end
    -- `~= nil`, never a type test: a function from another resource arrives as a callable table.
    if handler == nil then
        return false, ('%s "%s": no handler given'):format(reg.label, key)
    end

    local ok, why = reg:add(owner, key, handler)
    if not ok then
        print(('[whip_core:inv] %s refused for %s: %s'):format(reg.label, tostring(owner), tostring(why)))
        return false, why
    end
    return true
end

--- Register a context action for whip_core itself. panels.lua's dispatchers come through here so
--- they are owned, and a satellite cannot take one over.
---@return boolean ok, string|nil err
function Inventory.registerCoreContextAction(key, handler)
    return registerOwned(_actions, key, handler, GetCurrentResourceName())
end

--- A use handler whip_core holds for a while, under a run tag: the Director's "Use an item" start,
--- while its scenario is on (ReleaseTag gives the item back). The caller makes sure the item has no
--- use already: whip_core re-adding its own key would replace that one.
---@return boolean ok, string|nil err
function Inventory.registerTaggedUseHandler(key, handler, tag)
    if type(key) ~= 'string' or key == '' then return false, 'a use handler needs a string key' end
    if handler == nil then return false, ('use handler "%s": no handler given'):format(key) end
    local ok, why = _uses:add(GetCurrentResourceName(), key, handler, { tag = tag })
    if not ok then return false, why --[[@as string]] end
    return true
end

--- A metadata generator registered on another resource's behalf (panels.lua, for a panel item's
--- empty slot table). Owned by that resource, so it goes when it stops.
---@param owner string
---@return boolean ok, string|nil err
function Inventory.registerMetaGeneratorFor(owner, key, generator)
    return registerOwned(_metas, key, generator, owner)
end

--- Who registered a handler: whip_core's own get the live player, others the sheet.
---@param which string  'use' | 'action' | 'meta'
---@param key string
---@return string|nil owner
function Inventory.handlerOwner(which, key)
    local reg = (which == 'use' and _uses) or (which == 'action' and _actions) or _metas
    return reg:ownerOf(key)
end

--- The address of one of a player's pocket slots — what use handlers and context actions are handed,
--- and what FindItem answers with. `{ kind = 'player', id = source, sub = pocket, slot = slot }`.
---@param source number
---@param pocket string  a PlayerContainers entry
---@param slot number
---@return table addr
function Inventory.pocketAddr(source, pocket, slot)
    return { kind = 'player', id = source, sub = pocket, slot = slot }
end

--- Run a context action's handler for a player's slot. THE ONE PLACE a context action is called.
---
--- What the handler is handed depends on whose it is: whip_core's own get the live player; another
--- resource's get the data sheet GetPlayer returns (arguments cross the boundary as copies, and the
--- live object carries identifiers and the whole inventory). The same rule as use handlers, effect
--- callbacks and SecureEvent handlers.
---
--- The handler gets `(source, player, slotData, addr, how)`. `how`: how it came, nil from the inventory, or
--- `{ from = 'ground' }` straight after a pick up from a pile's prompt (a ground option: Equip on a gun).
---@param how table|nil
---@return boolean ran  false when there is no handler, or it threw
---@return string|nil err
---@return string|nil refused  the handler's refusal, or the database's, for the player
function Inventory.runContextAction(action, source, player, slotData, container, slot, how)
    return Inventory.runContextActionAt(action, source, player, slotData, Inventory.pocketAddr(source, container, slot), how)
end

--- The same, for an item at any address: an option marked `anywhere` run on a boot's, a stash's or a bag's
--- slot (storeContextAction). The handler is handed that address.
---@param addr table  { kind, id, sub, slot }
---@param how table|nil
---@return boolean ran
---@return string|nil err
---@return string|nil refused  the handler's refusal, or the database's, for the player
function Inventory.runContextActionAt(action, source, player, slotData, addr, how)
    local locked = DbHealth.refusal()   -- items are locked while the database is down (db_health.lua)
    if locked then return false, locked, locked end
    local handler = Inventory.ContextActions[action]
    if handler == nil then return false, 'no handler for "' .. tostring(action) .. '"' end

    local owner = _actions:ownerOf(action)
    local handPlayer = player
    if owner and owner ~= GetCurrentResourceName() and player and player.handlerSheet then
        handPlayer = player:handlerSheet()
    end

    -- Actions.call: what the handler saves through whip lands with this action.
    local ok, result, why = Actions.call(owner, handler, source, handPlayer, slotData, addr, how)
    if not ok then
        -- Filed under the action's resource (ErrorTap.caught), so GetErrorLog lists it as theirs.
        ErrorTap.caught(('[whip_core:inv] context action "%s" (%s) errored: %s')
            :format(tostring(action), tostring(owner or '?'), tostring(result)), owner)
        return false, tostring(result)
    end
    -- The handler's `false, 'why'` is its refusal, handed back so the player sees it.
    if result == false and type(why) == 'string' and why ~= '' then
        return true, nil, why
    end
    return true
end

-- A stopping satellite takes its handlers, slots, keys and metadata generators with it: the
-- registries above sweep them (shared/registry.lua).

-- Late starters: a satellite that registers before any player connects is covered by the
-- login sync (player_lifecycle sends the payload with inventoryFlagsSync); this rebroadcast
-- covers everyone already connected when whip_core itself restarts.
AddEventHandler('onResourceStart', function(res)
    if res == GetCurrentResourceName() then
        broadcastSlotDefs()
    end
end)

-- ============================================
-- Use Item
-- ============================================

--- [source] = { [itemKey] = true } while that item's use handler runs (see useItem).
local _useRunning = {}

--- Are this player's pockets held still for a bank payment (Stores.freeze: the ATM, a Sell card)? A
--- use, and a resource's take, wait it out: what is in them may not be paid for yet. whip_core's own
--- take-back runs inside the hold, so the check is on these doors.
---@param source number
---@return boolean
function Inventory.pocketsFrozen(source)
    local pockets = Stores.player(source, 'player')
    return pockets ~= nil and pockets.unit ~= nil and Stores.isFrozen(pockets.unit) == true
end

---@param source number
---@param player WhipPlayer
---@param container string
---@param slot number
---@return boolean, string|nil
---@return boolean|nil logged  the handler logged the use itself
function Inventory.useItem(source, player, container, slot)
    local cache = player.inventory
    if not cache then
        return false, 'No inventory'
    end
    -- Locked while the database is down (db_health.lua): a use could take effect and never be saved.
    local locked = DbHealth.refusal()
    if locked then return false, locked end
    -- Not while a bank payment holds the pockets (Inventory.pocketsFrozen).
    if Inventory.pocketsFrozen(source) then return false, 'Paying — wait a moment' end

    local slotData = Inventory.getSlot(cache, container, slot)
    if not slotData then
        return false, 'Empty slot'
    end

    local def = Config.Items[slotData.item]
    if not def then
        return false, 'Unknown item'
    end
    if not def.usable then
        return false, 'Item not usable'
    end

    -- Cooldown check
    local now = os.time()
    if not Inventory.Cooldowns[source] then Inventory.Cooldowns[source] = {} end
    local lastUse = Inventory.Cooldowns[source][slotData.item] or 0
    local cd = def.cooldown or 0
    if cd > 0 and (now - lastUse) < cd then
        return false, 'On cooldown'
    end

    -- Call registered handler
    -- Handler return values:
    --   true          = success, consume the item (food, bandage, drink)
    --   false         = success, do NOT consume (jerry can equip, reusable tools)
    --   false, 'why'  = REFUSED: nothing happened — no cooldown, no item:used, nothing consumed, and
    --                   the why is shown (an empty why refuses silently: a cancelled bar).
    -- No handler is a refusal, not a free use: its resource is stopped or never registered one, and
    -- only use stops until the resource is back. Every usable item has a handler.
    local handler = Inventory.UseHandlers[slotData.item]
    if handler == nil then
        return false, ("%s can't be used right now"):format(def.name or slotData.item)
    end
    local shouldConsume = true
    local alreadyLogged = false
    local itemKey = slotData.item
    -- The instance, so it can be found again if the handler yields (see below). Stamped here, not
    -- only read: a fresh stack has no uid until its first logged touch.
    local uid = Log.ensureUid(slotData)

    if handler then
        -- A satellite's handler gets the player SHEET (player:handlerSheet()), not the live object
        -- (see runContextAction). whip_core's own handlers keep the object.
        local owner = _uses:ownerOf(itemKey)
        local handedPlayer = (owner and owner ~= GetCurrentResourceName() and player.handlerSheet)
            and player:handlerSheet() or player
        -- The handler gets the item's address (what GetItemAt, StoreTake and SetItemMetadata
        -- take). Actions.call: what it saves lands with this use.
        --
        -- One use of an item at a time per player: the cooldown is stamped only after the handler
        -- answers, so a waiting handler could otherwise be entered twice. A second press meanwhile is
        -- refused silently. (The declared timed form has its own latch, _timedUseRunning.)
        local running = _useRunning[source]
        if running and running[itemKey] then return false, '' end
        if not running then running = {}; _useRunning[source] = running end
        running[itemKey] = true
        local handlerOk, handlerResult, handlerWhy, handlerNote = Actions.call(owner, handler, source, handedPlayer, slotData,
            Inventory.pocketAddr(source, container, slot))
        running[itemKey] = nil
        if not next(running) and _useRunning[source] == running then _useRunning[source] = nil end
        if not handlerOk then
            ErrorTap.caught(('[whip_core:inv] useItem ERROR: %s\'s use handler for "%s" crashed: %s')
                :format(tostring(owner or '?'), itemKey, tostring(handlerResult)), owner)
            return false, 'Use failed'
        end
        if handlerResult == false and type(handlerWhy) == 'string' then
            return false, handlerWhy
        end
        -- false = handler succeeded but item should NOT be consumed
        if handlerResult == false then
            shouldConsume = false
            -- A declared timed use took the item itself, through StoreTake, which logged it.
            alreadyLogged = handlerNote == 'logged'
        end
    end

    -- Record cooldown
    Inventory.Cooldowns[source][itemKey] = now

    -- Only consume if the handler said to
    if shouldConsume then
        -- Consume what was used, not whatever is in the slot now: during a yielding handler the
        -- stack may have been dragged elsewhere. The slot is re-read, and a moved stack followed by uid.
        local live = Inventory.getSlot(cache, container, slot)
        if live ~= slotData then
            live = nil
            if uid then
                for _, c in ipairs(PlayerContainers) do
                    for s, d in pairs(cache[c] or {}) do
                        if d.item == itemKey and d.metadata and d.metadata.uid == uid then
                            live, container, slot = d, c, s
                            break
                        end
                    end
                    if live then break end
                end
            end
        end

        if not live then
            -- It left the player during the use. The effect has happened; there is nothing on
            -- them to take. Said loudly, because a handler that yields is what makes this possible.
            print(('[whip_core:inv] useItem: "%s" was moved off %s while its use handler ran — not consumed')
                :format(itemKey, tostring(player.fullName)))
        elseif live.amount > 1 then
            live.amount = live.amount - 1
        else
            Inventory.clearSlot(cache, container, slot)
        end
    end

    -- Fire event for other scripts (whip_core:item:used).
    WhipEmit('whip_core:item:used',
        { source = source, item = itemKey, slot = slotData, addr = Inventory.pocketAddr(source, container, slot) })

    -- Third: the use was already logged (the caller must not write a second 'used' row).
    return true, nil, alreadyLogged
end

--- Clean up cooldowns when player disconnects
---@param source number
function Inventory.clearCooldowns(source)
    Inventory.Cooldowns[source] = nil
    _useRunning[source] = nil   -- a handler still waiting when they left must not hold the next owner of the id
end

-- Use handlers are registered in server/items/*.lua (one file per item)

-- ============================================
-- Public Exports
-- ============================================
-- The helpers these lean on (Inventory.giveOrDrop, Inventory.syncAndSave,
-- Inventory.isPlayerContainer — server/inventory_sync.lua) are resolved at call time.

--- Deep copy of a player's inventory cache — the pocket containers only, metadata copied one level
--- deep — for exports that hand back a snapshot.
---@param cache table
---@return table
local function deepCopyInventory(cache)
    local copy = {}
    for container, slots in pairs(cache) do
        if Inventory.isPlayerContainer(container) then
            copy[container] = {}
            for slot, data in pairs(slots) do
                local metaCopy = nil
                if data.metadata then
                    metaCopy = {}
                    for k, v in pairs(data.metadata) do metaCopy[k] = v end
                end
                copy[container][slot] = {
                    item     = data.item,
                    amount   = data.amount,
                    metadata = metaCopy,
                }
            end
        end
    end
    return copy
end

--- A deep copy of a player's whole inventory (their pockets). `{}, 'Player not loaded'` before they
--- load: a read that answers a table answers the empty one and why.
---@param source number
---@return table inventory
---@return string|nil err
function Inventory.pocketsCopy(source)
    local player = Players[source]
    if not player or not player.inventory then return {}, 'Player not loaded' end
    return deepCopyInventory(player.inventory)
end
exports('GetInventory', Inventory.pocketsCopy)

-- whip_core calls these by name (Inventory.give / take / pocketsCopy / findAll), never its own
-- exports: an export runs on a coroutine no player action owns. Each export below IS its function.

-- ============================================
-- Inventory — the four verbs
-- ============================================
--
-- Everything a resource does to a player's inventory is one of these four, and each one spans
-- EVERY container the character carries. A caller never picks a container: you want the item
-- on the player, and whip works out where it goes.
--
-- The client's HasItem and GetItemCount behave identically, so a check written on either side
-- of the boundary gives the same answer.
--
-- Acting on one specific slot is a different, explicit operation, by ADDRESS — GetItemAt,
-- SetItemMetadata, StoreGive and StoreTake (stores.lua) — and a use handler or FindItem hands you
-- the address to use.

--- Add an item to the player, wherever it fits.
---
--- A GIVE: if it fits nowhere, it is dropped at the player's feet rather than destroyed, and that
--- still counts as given. See Inventory.giveOrDrop in server/inventory_sync.lua for the whole policy.
---
--- The answer says where it went: 'inventory' or 'ground', or `false, reason` when nothing was given.
---
---     local where, err = AddItem(src, 'drink', 2, nil, 'quest reward')
---     if not where then print(err) elseif where == 'ground' then --[[ it was dropped ]] end
---
--- The last argument is a REASON or an OPTIONS table:
---
---     AddItem(src, 'drink', 2, nil, { reason = 'quest reward', noDrop = true })
---
---   reason   for the activity log, beside your resource's name ('quest reward · by my_jobs'). The
---            same last argument on RemoveItem.
---   noDrop   refuse instead of dropping at their feet when it will not fit
---   pocket   'player' or 'accessory' — only that pocket, instead of wherever it fits
---   coords   where to drop it when it will not fit, instead of at their feet
---
--- A mistyped item name or a bad amount is REFUSED — `(false, 'Unknown item "x"')` — and never dropped.
---@param opts string|table|nil  a reason, or { reason?, noDrop?, pocket?, coords? }
---@return string|false where  'inventory' | 'ground', or false when nothing was given
---@return string|nil err
function Inventory.give(source, item, amount, metadata, opts)
    local o = type(opts) == 'table' and opts or {}
    local give = {
        reason    = Log.reasonFrom(type(opts) == 'table' and o.reason or opts),   -- before any yield
        noDrop    = o.noDrop == true,
        container = o.pocket,
        coords    = o.coords,
    }

    -- Metadata is a table or nothing, as StoreGive: a reason written in its place
    -- (`AddItem(src, 'drink', 2, 'quest reward')`) is refused with how to write it.
    if metadata ~= nil and type(metadata) ~= 'table' then
        return false, 'metadata must be a table or nil — a reason goes fifth: AddItem(src, item, n, nil, reason)'
    end
    -- And one the database can hold (a function, a NaN can't be written), refused here instead of
    -- failing the next save.
    if metadata ~= nil then
        local okData, what = Inventory.saveableData(metadata)
        if not okData then return false, ('metadata cannot be saved: %s'):format(what) end
    end
    local ok, err, placement = Inventory.giveOrDrop(source, Players[source], item, amount, metadata, give)
    if not ok then return false, err --[[@as string|nil]] end
    return placement --[[@as string]]   -- (ok: 'inventory' or 'ground')
end
exports('AddItem', Inventory.give)

--- Remove an item from the player, from wherever it is.
--- Totals across containers first and removes nothing unless the full amount is present.
---@param reason string|table|nil  see AddItem
---@param only table|nil  take only the stacks carrying it (see removeItem: a Director goal's own package)
---@param evenFrozen boolean|nil  a TAKE-BACK inside a bank payment's hold (the Sell card's, when its debit failed)
function Inventory.take(source, item, amount, reason, only, evenFrozen)
    local why = Log.reasonFrom(reason)   -- first, before anything can yield
    local player = Players[source]
    if not player or not player.inventory then return false, 'Player not loaded' end
    -- Not while a bank payment holds the pockets (Inventory.pocketsFrozen). Here, so every taker is
    -- covered (RemoveItem, the Systems Take Item card, the Director's hand-over). Only the hold's
    -- own take-back passes `evenFrozen`.
    if not evenFrozen and Inventory.pocketsFrozen(source) then return false, 'Paying — wait a moment' end
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    local ok, err = Inventory.removeItemAcrossContainers(player.inventory, item, amount, only)
    if ok then
        -- An item leaving the game, logged with the resource that asked (Log.lost).
        Log.lost(player.charId, item, amount, why)
        -- The push announces whip_core:item:removed (Inventory.announceChanges).
        Inventory.noteChangeReason(source, why, Log.byCaller())
        Inventory.syncAndSave(source, player)
    end
    return ok, err
end
exports('RemoveItem', function(source, item, amount, reason)
    -- (Refused while a bank payment holds the pockets: Inventory.take asks.)
    return Inventory.take(source, item, amount, reason)
end)

--- Does the player have at least `amount` of this item, anywhere on them?
exports('HasItem', function(source, item, amount)
    local player = Players[source]
    if not player or not player.inventory then return false, 'Player not loaded' end
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    return Inventory.getItemCountAcrossContainers(player.inventory, item) >= amount
end)

--- How many of this item is the player carrying, across every container?
exports('GetItemCount', function(source, item)
    local player = Players[source]
    if not player or not player.inventory then return 0, 'Player not loaded' end
    return Inventory.getItemCountAcrossContainers(player.inventory, item)
end)

-- The handler registries and registerOwned are declared further up, where runContextAction and
-- the use path read them — a local is only visible to code below its declaration.

--- The item registry, on the one registration rule (shared/registry.lua).
---
--- An item belongs to whoever declared it. Re-registering your own is normal (onReady fires on every
--- resource start); taking over somebody else's (`cash` at weight 0) is refused, unless the owner has
--- stopped.
---
--- Never swept (`sweep = false`): players still carry the items after their resource stops. A
--- stopped owner no longer holds them, so a retired resource's keys are free to reuse.
---
--- The same definition again changes nothing, so it invalidates nothing (gunny re-registers ~213
--- items on every start). Who owns what: Inventory.itemOwner, below.

-- Who last registered each key, kept across restarts: RetireItem lets a resource end only a key no other resource
-- registered last (server/retired_items.lua), so one that starts first cannot take another's items away. One KVP
-- entry, written a few seconds after the last change: SetResourceKvp blocks the tick, and a start registers
-- hundreds of items, nearly all with the owner they had.
local REGISTRANTS_KVP = 'whip_core:itemRegistrants'
local _registrants = {}
do
    local ok, saved = pcall(json.decode, GetResourceKvpString(REGISTRANTS_KVP) or '')
    if ok and type(saved) == 'table' then _registrants = saved end
end
local _registrantsDue = false
local function noteRegistrant(key, owner)
    if _registrants[key] == owner then return end
    _registrants[key] = owner
    if _registrantsDue then return end
    _registrantsDue = true
    SetTimeout(5000, function()
        _registrantsDue = false
        SetResourceKvp(REGISTRANTS_KVP, json.encode(_registrants))
    end)
end

--- The resource that last registered `key` (this run or an earlier one), or nil when none has since whip_core began
--- keeping track.
---@param key string
---@return string|nil
function Inventory.lastRegistrant(key)
    return _registrants[key]
end

local _items = Registry.new('Item', {
    label = 'item',
    store = Config.Items,
    sweep = false,
    prefixed = true,   -- one list for the server: a key not starting with its resource's name is warned about
    onAdd = function(key, value, owner)
        -- The NUI item-definition payload is cached; registering an item is the only thing
        -- that can change it (Inventory.invalidateItemDefs, above). The Item Browser's refresh is
        -- guarded: DevTools loads after this file, and a registration made during load must not throw.
        Inventory.invalidateItemDefs()
        if DevTools then DevTools.refresh('ib') end
        -- Its settings page, made from what was stored (server/item_settings.lua).
        ItemSettings.added(key, value)
        noteRegistrant(key, owner)
    end,
    -- ...and so can one going (an item registered under a run tag, released: a Systems Test's).
    onRemove = function()
        Inventory.invalidateItemDefs()
        if DevTools then DevTools.refresh('ib') end
    end,
})
-- Config's items are whip_core's.
for key in pairs(Config.Items) do _items:setOwner(key, GetCurrentResourceName()) end

-- ...and their right-click options, pictures and own settings go through RegisterItem's checks too.
-- One that fails is said and left out: the item itself still works. Their settings pages are made
-- once whip_core is ready (ItemSettings.declareWaiting).
for key, def in pairs(Config.Items) do
    local options, optWhy = ItemOptions.cleanOptions(def.contextOptions, ('item "%s" contextOptions'):format(key))
    local images, imgWhy = ItemOptions.cleanImages(def.images, ('item "%s" images'):format(key))
    local settings, setWhy = ItemSettings.clean(def.settings, ('item "%s" settings'):format(key))
    local ground, groundWhy = ItemOptions.cleanGroundOptions(def.groundOptions, ('item "%s" groundOptions'):format(key))
    if optWhy then print(('[whip_core:inv] config.lua %s: left out'):format(optWhy)) end
    if imgWhy then print(('[whip_core:inv] config.lua %s: left out'):format(imgWhy)) end
    if setWhy then print(('[whip_core:inv] config.lua %s: left out'):format(setWhy)) end
    if groundWhy then print(('[whip_core:inv] config.lua %s: left out'):format(groundWhy)) end
    def.contextOptions, def.images, def.settings, def.groundOptions = options, images, settings, ground
    ItemSettings.prepareConfigItem(key, def)
    ItemSettings.added(key, def)
end

--- What a registered stacking item without a maxStack gets (below).
local REGISTERED_DEFAULT_MAX_STACK = 100

--- One meaning for maxStack, so every mover agrees: not stacking → 1; stacking with none →
--- REGISTERED_DEFAULT_MAX_STACK. A non-stacking item that claims more than 1 is a contradiction:
--- false and why, and the definition is left as it was.
---@param key string
---@param definition table  changed in place
---@return boolean ok
---@return string|nil why
local function settleMaxStack(key, definition)
    local maxStack = tonumber(definition.maxStack)
    if not definition.stack then
        if maxStack and maxStack > 1 then
            return false, ('item "%s": stack = false with maxStack %s — an item that does not stack holds one per slot')
                :format(key, tostring(definition.maxStack))
        end
        definition.maxStack = 1
    elseif definition.maxStack == nil then
        definition.maxStack = REGISTERED_DEFAULT_MAX_STACK
    elseif not maxStack or not (maxStack >= 1) or maxStack == math.huge then
        -- Given and unusable is said, not quietly made 100: 0, -3 or 'x' is a typo.
        return false, ('item "%s": maxStack %s — a whole number, 1 or more (leave it out for %d)')
            :format(key, tostring(definition.maxStack), REGISTERED_DEFAULT_MAX_STACK)
    else
        definition.maxStack = math.floor(maxStack)
    end
    return true
end

-- The same for config.lua's own items (the file beginners edit): a contradiction is said, and that
-- item is held to the fallback.
for key, def in pairs(Config.Items) do
    if type(def) == 'table' then
        local ok, why = settleMaxStack(key, def)
        if not ok then
            local fallback = def.stack and REGISTERED_DEFAULT_MAX_STACK or 1
            print(('^3[whip_core:inv] config.lua %s — it is held to %d per slot^0'):format(why, fallback))
            def.maxStack = fallback
        end
    end
end

-- A field of one of config.lua's items changed in /whip → Settings ('Items.food.weight'). Config.Items
-- is the item registry's store, so the entry already has it; its stack size is settled as at load
-- (the panel's cross check refused a contradiction), every player is told their definitions are
-- stale, and an open Item Browser redraws.
Settings.onChange('Items', function(_, _, path)
    local key = path:match('^Items%.([^%.]+)')
    local def = key and Config.Items[key]
    if type(def) ~= 'table' then return end
    settleMaxStack(key, def)
    Inventory.invalidateItemDefs()
    if DevTools and DevTools.refresh then DevTools.refresh('ib') end
end)

--- The resource that registered an item — whip_core for config's — or nil for an unknown key. A
--- stopped owner's name stays (the registry does not sweep items), as the icon path needs it.
---@param key string
---@return string|nil resource
function Inventory.itemOwner(key)
    return _items:ownerOf(key)
end

--- Take an item's definition away, for RetireItem (server/retired_items.lua): the owner's own, or one whose
--- resource has stopped. The ones already out there are RetireItem's to clear.
---@param key string
---@param owner string
---@return boolean ok
---@return string|nil err
function Inventory.unregisterItem(key, owner)
    if Config.Items[key] == nil then return true end
    local holder = _items:ownerOf(key)
    if holder ~= owner then
        if holder and Registry.alive(holder) then return false, ('item "%s" belongs to %s'):format(key, holder) end
        _items:setOwner(key, owner)   -- a stopped resource holds nothing (shared/registry.lua)
    end
    return _items:remove(owner, key)
end

-- ============================================
-- A timed use, declared
-- ============================================
--
-- "Use an item with a progress bar": the use handler can be a TABLE, and whip does the bar, the
-- animation, the prop, the re-check and the take:
--
--     exports.whip_core:RegisterUseHandler('alcohol', {
--         label = 'Drinking...', duration = 5000,
--         anim  = { dict = 'mp_player_intdrink', clip = 'loop_bottle' },
--         prop  = { model = 'prop_amb_beer_bottle' },
--         disable = { move = false },                          -- they can walk while they drink
--         canUse = function(source, player, item, addr) ... end, -- optional: false, 'why' refuses
--         onComplete = function(source, player, item, addr)      -- the bar finished and it is taken
--             return exports.whip_core:AddStat(source, 'drunk', 20, 'item:alcohol')   -- false gives it back
--         end,
--     })
--
-- The order: canUse → the bar, timed by the server (Progress) → the item is still where the use
-- started → it is TAKEN → onComplete. The effect only ever happens with the item gone; onComplete
-- answering `false, 'why'` (or erroring) puts it back.

--- [source] = true while a declared timed use is running for that player — one at a time.
local _timedUseRunning = {}

--- Is this handler argument a DECLARATION (a plain table with a duration) rather than a function?
--- A satellite's function also arrives as a table — the funcref — so it is told apart by rawget,
--- never by indexing it (a funcref throws on any key it does not hold).
local function isUseDeclaration(v)
    return type(v) == 'table' and rawget(v, '__cfx_functionReference') == nil and rawget(v, 'duration') ~= nil
end

--- Build the use handler for a declared timed use.
---@param itemKey string
---@param spec table  { label, duration, icon, anim, prop, disable, canCancel, cancelOnDeath, cancelOnExit, notWhile, consume, reason, canUse, onComplete }
---@param owner string
---@return function handler
local function declaredUse(itemKey, spec, owner)
    local def = Config.Items[itemKey]
    local bar = {
        label         = spec.label or ((def and def.name) and ('Using ' .. def.name .. '...')) or 'Using...',
        -- The bar's disc (the hint capsule) shows the item's picture; this glyph (html/js/glyphs.js) is for an
        -- item with none.
        icon          = type(spec.icon) == 'string' and spec.icon or nil,
        duration      = spec.duration,
        canCancel     = spec.canCancel ~= false,
        anim          = spec.anim,
        prop          = spec.prop,
        disable       = spec.disable,
        cancelOnDeath = spec.cancelOnDeath,
        -- Work done from a seat (a nitrous bottle fitted): getting out of the vehicle ends it (TimedAction.progress).
        cancelOnExit  = spec.cancelOnExit,
        -- Not while swimming, under water or falling, any it names (shared/body_state.lua).
        notWhile      = spec.notWhile,
    }
    local consume = spec.consume ~= false

    -- Every way out that did not use it answers `false, why`: useItem then records no use, starts
    -- no cooldown and announces nothing, and shows the why ('' = silently, for a cancelled bar).
    return function(source, player, slotData, addr)
        if _timedUseRunning[source] then return false, '' end

        -- ---- may they start? ----
        if spec.canUse ~= nil then
            local called, allowed, why = Actions.call(owner, spec.canUse, source, player, slotData, addr)
            if not called then
                ErrorTap.caught(('[whip_core:inv] canUse for "%s" (%s) errored: %s'):format(itemKey, tostring(owner), tostring(allowed)), owner)
                return false, 'You cannot use that right now'
            end
            if allowed == false then
                return false, (type(why) == 'string' and why ~= '') and why or 'You cannot use that right now'
            end
        end

        -- ---- the bar, timed by the server ----
        -- Its disc shows the item being used, its picture by its state (the icon is for one with no picture).
        local opts = {}
        for k, v in pairs(bar) do opts[k] = v end
        opts.item = { item = itemKey, metadata = slotData and slotData.metadata or nil }
        _timedUseRunning[source] = true
        local done = TimedAction.progress(source, opts, owner)
        _timedUseRunning[source] = nil
        if not done then return false, '' end

        -- ---- still the same item? They had the whole bar to move or drop it. ----
        local uid = slotData and slotData.metadata and slotData.metadata.uid
        local now = Stores.itemAt(addr)
        if not now or now.item ~= itemKey or (uid and (not now.metadata or now.metadata.uid ~= uid)) then
            return false, 'You no longer have it'
        end

        -- ---- taken, THEN the effect ----
        -- Stores.takeAt, not the StoreTake export: the take must belong to this action, so it is
        -- written with what onComplete changes.
        if consume then
            if not Stores.takeAt(addr, 1, { reason = spec.reason or 'used' }) then
                return false, 'Could not use it'
            end
        end

        if spec.onComplete ~= nil then
            -- Actions.call: the item whip just took and what onComplete changes land together.
            local called, result, why = Actions.call(owner, spec.onComplete, source, player, now, addr)
            if not called or result == false then
                if not called then
                    ErrorTap.caught(('[whip_core:inv] onComplete for "%s" (%s) errored: %s'):format(itemKey, tostring(owner), tostring(result)), owner)
                end
                -- Put back what was taken, so a use that didn't happen costs nothing — to the character
                -- it was taken from (an onComplete that waits can outlast a logout; gone by then, it is
                -- logged as lost). Matched by charId, not table: a satellite's handler holds a COPY of
                -- the player (handlerSheet). The give goes to the live player.
                if consume then
                    local live = Players[source]
                    if live and live.charId == player.charId then
                        Inventory.giveOrDrop(source, live, itemKey, 1, now.metadata, { reason = 'use undone' })
                    else
                        Log.lost(player.charId, itemKey, 1, 'use undone after they left')
                    end
                end
                -- A crash is not a quiet "no": the player watched the whole bar, so they are told it
                -- did not work (canUse erroring says so the same way). onComplete's own bare false
                -- stays silent — that is the handler choosing not to say anything.
                if not called then return false, 'That did not work' end
                return false, (type(why) == 'string') and why or ''
            end
        end

        -- Used. Consumed above (StoreTake logged it — so no second 'used' row), or kept with
        -- consume = false: either way useItem must not take another.
        if consume then return false, nil, 'logged' end
        return false
    end
end

--- Say what happens when a player USES an item (clicks Use, or presses its hotbar key).
---
--- Answers `true` or `false, reason`. The item must have `usable = true` in its definition, or
--- players only ever see "Item not usable" (said in the console when the item is already
--- registered without it). Registering the handler before the item is fine.
---
--- The handler gets `(source, player, slotData, addr)`: `addr` is the used item's address, for
--- GetItemAt / StoreTake / SetItemMetadata. Return `false` to keep the item.
---
--- Or a table, for a use with a progress bar: see "A timed use, declared" above.
---@param itemKey string
---@param handler fun(source: number, player: table, slotData: table, addr: table): boolean|nil|table
---@return boolean ok, string|nil err
exports('RegisterUseHandler', function(itemKey, handler)
    return Inventory.registerUseHandler(itemKey, handler, Registry.caller())   -- the caller first
end)

--- RegisterUseHandler's body, with its owner. whip_core's own items (server/items/*.lua) call this.
---@param owner string
function Inventory.registerUseHandler(itemKey, handler, owner)
    if isUseDeclaration(handler) then
        local duration = tonumber(rawget(handler, 'duration'))
        if not duration or not (duration > 0) or duration == math.huge then
            return false, ('use of "%s": duration must be a positive number of milliseconds'):format(tostring(itemKey))
        end
        -- A misspelt state is said here, not at every use.
        local notWhile, notWhileErr = BodyState.readList(rawget(handler, 'notWhile'))
        if not notWhile then return false, ('use of "%s": %s'):format(tostring(itemKey), notWhileErr) end
        handler = declaredUse(itemKey, handler, owner)
    elseif type(handler) == 'table' and rawget(handler, '__cfx_functionReference') == nil then
        -- A plain table with no duration (a typo: `durration`, `time`) is said here, not at every use.
        return false, ('use of "%s": a table needs a duration in milliseconds (or pass a function)')
            :format(tostring(itemKey))
    end
    local ok, err = registerOwned(_uses, itemKey, handler, owner)
    if ok then
        local def = Config.Items[itemKey]
        if def and not def.usable then
            print(('[whip_core:inv] WARNING: use handler for "%s" registered, but the item has no ' ..
                '`usable = true` — players will only ever see "Item not usable"'):format(itemKey))
        end
    end
    return ok, err
end

-- (REGISTERED_DEFAULT_MAX_STACK and settleMaxStack are above, beside _items: config's items go
-- through the same rule at load.)

exports('RegisterItem', function(key, definition)
    local owner = Registry.caller()   -- the caller first, before anything can yield
    local ok, why = Inventory.registerItem(key, definition, owner)
    if not ok then Registry.sayRefused(owner, why) end   -- a bad definition too, not only a taken key
    return ok, why
end)

--- RegisterItem's body, with its owner (the Systems Creator registers a system's own items through
--- it, never the export). `opts.tag` files the registration under a run tag, so
--- releasing the tag takes the item away again (an editor's Test); without one it stays, as every
--- registered item does (the registry does not sweep items: they are in people's pockets).
---@param key string
---@param definition table
---@param invoker string  the owner
---@param opts table|nil  { tag }
---@return boolean ok, string|nil err
function Inventory.registerItem(key, definition, invoker, opts)
    -- (ok, err), like every registration. Validation is minimal (a definition is open-ended), but
    -- bad arguments are said at the caller, not discovered at use time.
    if type(key) ~= 'string' or key == '' then
        return false, 'an item needs a string key'
    end
    -- At most 50: every item table keeps the key in a VARCHAR(50), and a longer one would fail
    -- every save of the pockets holding it.
    if #key > 50 then
        return false, ('item "%s": a key is 50 characters at most (this one is %d)'):format(key, #key)
    end
    if type(definition) ~= 'table' then
        return false, ('item "%s": expected a definition table'):format(key)
    end
    -- A key the rest of the API can find: keys are cleaned to letters, digits, _ and - elsewhere
    -- (FindItem, a SecureEvent 'key' param), and the icon file must be able to exist on Windows.
    -- And the two required fields are required.
    if not key:match('^[%w_%-]+$') then
        return false, ('item "%s": a key is letters, digits, _ and - only (no colons or spaces)'):format(key)
    end
    if type(definition.name) ~= 'string' or definition.name == '' then
        return false, ('item "%s": needs a name (what players see)'):format(key)
    end
    -- A finite weight: every comparison with NaN is false, which would make a container weightless.
    local weight = tonumber(definition.weight)
    if weight == nil or weight ~= weight or weight < 0 or weight == math.huge then
        return false, ('item "%s": needs a weight (kg, 0 or more)'):format(key)
    end
    -- Kept as the number it was checked as ('0.5' becomes 0.5).
    definition.weight = weight
    -- An item that holds a panel does not stack (each has its own contents), whichever is
    -- registered first.
    if definition.stack and Panels and Panels.itemConfigs[key] ~= nil then
        return false, ('item "%s": it holds a panel (RegisterPanelItem), so it cannot stack — each one has its own contents')
            :format(key)
    end

    -- One meaning for maxStack (settleMaxStack, above).
    local settled, stackWhy = settleMaxStack(key, definition)
    if not settled then return false, stackWhy end

    -- Its right-click options and pictures, checked and copied (server/item_options.lua): a word that
    -- is not one, or an option with no label, is said here and not found by a player.
    local options, optWhy = ItemOptions.cleanOptions(definition.contextOptions, ('item "%s" contextOptions'):format(key))
    if optWhy then return false, optWhy end
    local images, imgWhy = ItemOptions.cleanImages(definition.images, ('item "%s" images'):format(key))
    if imgWhy then return false, imgWhy end
    -- What a pile of it offers after Pick up (server/item_options.lua, "GROUND OPTIONS").
    local ground, groundWhy = ItemOptions.cleanGroundOptions(definition.groundOptions, ('item "%s" groundOptions'):format(key))
    if groundWhy then return false, groundWhy end
    definition.contextOptions, definition.images, definition.groundOptions = options, images, ground

    -- Its own settings checked, and an admin's changes to its name, description and weight written
    -- on (server/item_settings.lua). Its settings page is made once it is stored (_items' onAdd).
    local setOk, setWhy = ItemSettings.prepare(key, definition)
    if not setOk then return false, setWhy end

    -- Gone while its retirement holds (RetireItem, server/retired_items.lua).
    local retired = RetiredItems.why(key)
    if retired then
        local by = RetiredItems.owner(key)
        if by and by ~= invoker then
            return false, ('item "%s" is retired by %s (%s): give yours another key, such as "%s_%s"')
                :format(key, by, retired, tostring(invoker), key)
        end
        return false, ('item "%s" is retired (%s)'):format(key, retired)
    end

    -- Ownership, the no-op and the refusal are the registry's (_items above).
    local tag = type(opts) == 'table' and opts.tag or nil
    local ok, why = _items:add(invoker, key, definition, tag ~= nil and { tag = tag } or nil)
    if not ok then
        -- Another resource's refusal the registry says (Registry.sayRefused); whip_core's own (a system's item) here.
        if invoker == GetCurrentResourceName() then
            print(('[whip_core:inv] RegisterItem("%s") by %s refused: %s'):format(key, invoker, tostring(why)))
        end
        return false, why --[[@as string]]
    end
    return true
end

--- Metadata every NEW instance of an item starts with — a gun's serial, a phone's number.
--- The generator is `function(itemKey, ctx)`: ctx says who it is for (Inventory.metaContext, above
--- Inventory.addItem). opts.forBuyer: bought off an infinite shelf, it runs again for the buyer.
--- Answers `true` or `false, reason`.
exports('RegisterItemDefaultMetadata', function(itemKey, generator, opts)
    return Inventory.registerDefaultMeta(itemKey, generator, Registry.caller(), opts)   -- the caller first
end)

--- RegisterItemDefaultMetadata's body, with its owner. Owned, so the registry's sweep takes it away with
--- its resource (a forBuyer mark left behind with no generator does nothing: the purchase asks for both).
---@param owner string
---@param opts table|nil  { forBuyer = true }
function Inventory.registerDefaultMeta(itemKey, generator, owner, opts)
    local ok, err = registerOwned(_metas, itemKey, generator, owner)
    if ok then
        Inventory.MetaForBuyer[itemKey] = (type(opts) == 'table' and opts.forBuyer == true) or nil
    end
    return ok, err
end

--- What an item's right-click option (or its defaultAction) does. The action must be named by the
--- item's `defaultAction` or `contextOptions`, or no player can reach it. Answers `true` or
--- `false, reason`; a name whip_core uses for its own panels is refused.
--- The handler gets `(source, player, slotData, addr)`, the same as a use handler.
exports('RegisterContextAction', function(actionKey, handler)
    local owner = Registry.caller()   -- first, before anything can yield
    -- The wire carries at most 32 characters (customContextAction's 'action' param).
    if type(actionKey) == 'string' and #actionKey > 32 then
        return false, ('context action "%s" is longer than 32 characters'):format(actionKey)
    end
    return registerOwned(_actions, actionKey, handler, owner)
end)

--- Options added to items by resources that do not own them: one per item and action, the
--- adder's, gone when it stops. Any change is a new definition for every client.
local _addedOptions = Registry.new('ItemOption', {
    label = 'item option',
    store = Inventory.AddedOptions,
    onAdd = function() Inventory.invalidateItemDefs() end,
    onRemove = function() Inventory.invalidateItemDefs() end,
})

--- Add a right-click option to an item, yours or another resource's (a police resource's "Check for
--- prints" on whip_gunny's guns). The option is a contextOptions entry: { action, label, order?,
--- when?, require? }; its action is yours, registered with RegisterContextAction. It goes when your
--- resource stops. Answers `true` or `false, reason`: an item whose own options already have that
--- action is refused, and so is the same item and action added by another resource.
---@param itemKey string
---@param option table
---@return boolean ok, string|number|nil err  (the stored key when added)
exports('AddItemOption', function(itemKey, option)
    local owner = Registry.caller()   -- first, before anything can yield
    if type(itemKey) ~= 'string' or itemKey == '' then return false, 'AddItemOption needs an item key' end
    local opt, why = ItemOptions.cleanOption(option, ('AddItemOption("%s")'):format(itemKey))
    if not opt then return false, why end
    local def = Config.Items[itemKey]
    if def and type(def.contextOptions) == 'table' then
        for _, own in ipairs(def.contextOptions) do
            if own.action == opt.action then
                return false, ('item "%s" already has an option "%s" of its own'):format(itemKey, opt.action)
            end
        end
    end
    return _addedOptions:add(owner, itemKey .. '|' .. opt.action, { item = itemKey, option = opt })
end)

--- Take back an option AddItemOption added (only your own).
---@param itemKey string
---@param action string
---@return boolean ok, string|nil err
exports('RemoveItemOption', function(itemKey, action)
    local owner = Registry.caller()
    return _addedOptions:remove(owner, tostring(itemKey) .. '|' .. tostring(action))
end)

--- Will this item fit on the player at all — weight and slots, across every container?
---
--- Worth calling BEFORE an irreversible step, so a full inventory produces a clean refusal
--- rather than an item on the floor. AddItem's drop failsafe is the safety net, not the plan.
---
--- Pass `metadata` if the item carries contents, or it is measured empty (a full wallet as an empty one).
---
--- Answers `true`, or `false, reason`: 'Only 3 fit', 'No room', 'Unknown item "x"'.
---@param source number
---@param item string
---@param amount number|nil  default 1
---@param metadata table|nil
---@return boolean fits
---@return string|nil err
exports('CanFitItem', function(source, item, amount, metadata)
    local player = Players[source]
    if not player or not player.inventory then return false, 'Player not loaded' end
    if type(item) ~= 'string' or not Config.Items[item] then
        return false, ('Unknown item "%s"'):format(tostring(item))
    end
    amount = Sanitize.amount(amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    local fits, capacity = Inventory.canFitItem(player.inventory, item, amount, metadata)
    if fits then return true end
    capacity = tonumber(capacity) or 0
    if capacity > 0 then return false, ('Only %d fit'):format(capacity) end
    return false, 'No room'
end)

--- The pocket an export was asked about. Absent means the main grid; a named pocket that does not
--- exist is refused (nil), never quietly the main grid.
---@param container any
---@return string|nil
local function slotContainer(container)
    if container == nil then return 'player' end
    return Sanitize.enum(container, PlayerContainers)
end

--- Can this be saved as an item's metadata? It is written with json.encode, so: tables of strings,
--- numbers and booleans, keyed by strings or numbers. A function, a NaN or an infinity cannot be
--- written as JSON, and would fail the character's whole save.
---
--- Vectors are left to json.encode itself, which is asked last: it is the thing the save will
--- call, so its answer is the one that counts.
---@param value any
---@param depth number|nil
---@return boolean ok
---@return string|nil what  a short description of the first thing that cannot be saved
local function saveableData(value, depth)
    depth = depth or 0
    if depth > 16 then return false, 'nested too deep' end
    local t = type(value)
    if t == 'string' or t == 'boolean' then return true end
    if t == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return false, 'a NaN or infinite number' end
        return true
    end
    if t == 'vector2' or t == 'vector3' or t == 'vector4' or t == 'quat' then return true end
    if t ~= 'table' then return false, ('a %s'):format(t) end   -- functions, userdata, threads
    for k, v in pairs(value) do
        local kt = type(k)
        if kt ~= 'string' and kt ~= 'number' then return false, ('a %s used as a key'):format(kt) end
        local ok, what = saveableData(v, depth + 1)
        if not ok then return false, ('%s at "%s"'):format(what, tostring(k)) end
    end
    if depth == 0 then
        local encoded = pcall(json.encode, value)
        if not encoded then return false, 'something json.encode cannot write' end
    end
    return true
end

Inventory.saveableData = saveableData

--- The metadata a slot would have after a SetItemMetadata — built, checked, and not yet written.
---
---   * It MERGES: only the keys you pass change, everything else stays.
---   * `replace = true` makes the table you pass the whole metadata (nil with it clears it all).
---   * `remove = { 'key', ... }` takes keys away (a merge can't: nil is not a value in a Lua table).
---   * `uid` is kept either way: it is the item's identity in the activity log. Pass `uid = false`
---     to really clear it (`remove` does not take it).
---   * Anything that cannot be saved (a function, NaN) is REFUSED, before anything changes.
---@param old table|nil       the slot's metadata now
---@param metadata table|nil  what the caller passed
---@param opts { replace?: boolean, remove?: string[] }|nil
---@return table|nil|false new  false when refused
---@return string|nil err
function Inventory.buildMetadata(old, metadata, opts)
    opts = type(opts) == 'table' and opts or {}
    local replace, remove = opts.replace == true, opts.remove
    if metadata ~= nil and type(metadata) ~= 'table' then
        return false, 'metadata must be a table'
    end
    if remove ~= nil and type(remove) ~= 'table' then
        return false, "remove is a list of keys: { remove = { 'ammo' } }"
    end
    -- A bare nil changes nothing under a merge, and nobody means that: a variable that happened to
    -- be nil must not wipe an item either, so clearing everything is asked for by name.
    if metadata == nil and not replace and remove == nil then
        return false, 'metadata must be a table — to clear it all, pass nil with { replace = true }'
    end
    local new = {}
    if not replace and type(old) == 'table' then for k, v in pairs(old) do new[k] = v end end
    for k, v in pairs(metadata or {}) do new[k] = v end
    for _, k in ipairs(remove or {}) do
        if k ~= 'uid' then new[k] = nil end
    end
    -- The identity survives unless the caller clears it on purpose.
    if new.uid == false then
        new.uid = nil
    elseif new.uid == nil and type(old) == 'table' then
        new.uid = old.uid
    end
    if next(new) == nil then return nil end
    local okData, what = saveableData(new)
    if not okData then return false, ('metadata cannot be saved: %s'):format(what) end
    return new
end

-- SetItemMetadata and GetItemAt live with the other address calls in stores.lua: they work on any
-- store, not only the pockets. StoreTake(addr) is the take.

--- Where this item is on the player, and what it is: `{ item, amount, metadata, addr }`, a copy.
---@param player WhipPlayer
---@param pocket string
---@param slot number
---@param data table
---@return table
local function foundEntry(player, pocket, slot, data)
    return {
        item     = data.item,
        amount   = data.amount,
        metadata = data.metadata and json.decode(json.encode(data.metadata)) or nil,
        addr     = Inventory.pocketAddr(player.source, pocket, slot),
    }
end

--- Each slot of a pocket that holds `item`, LOWEST SLOT FIRST, as fn(slot, data); fn answering true stops the walk.
---
--- In slot order (pairs() over sparse slots has no order, so "the first stack" would be arbitrary).
--- Only the slots the pocket has (a lowered size hides the rest).
local function eachStackOf(player, p, item, fn)
    local slots = player.inventory[p]
    if type(slots) ~= 'table' then return end
    for slot = 1, (Config.ContainerSlots[p] or 0) do
        local data = slots[slot]
        if data and data.item == item and fn(slot, data) then return end
    end
end

--- The first stack of an item the player carries, the lowest slot first: `{ item, amount, metadata, addr }`, or nil.
--- `addr` is the handle for GetItemAt / StoreTake / SetItemMetadata. `pocket` limits the search to
--- one of GetPockets(); a pocket that does not exist finds nothing.
exports('FindItem', function(source, item, pocket)
    local player = Players[source]
    if not player or not player.inventory then return nil end
    item = Sanitize.key(item, 60) or ''
    -- A named pocket that does not exist finds nothing, rather than searching the main grid.
    if pocket ~= nil and not slotContainer(pocket) then return nil end
    local pockets = pocket and { slotContainer(pocket) } or PlayerContainers
    for _, p in ipairs(pockets) do
        local found = nil
        eachStackOf(player, p, item, function(slot, data)
            found = foundEntry(player, p, slot, data)
            return true
        end)
        if found then return found end
    end
    return nil
end)

--- Every stack of an item the player carries, as FindItem entries, lowest slot first. An empty list when none.
function Inventory.findAll(source, item, pocket)
    local player = Players[source]
    if not player or not player.inventory then return {}, 'Player not loaded' end
    item = Sanitize.key(item, 60) or ''
    local results = {}
    if pocket ~= nil and not slotContainer(pocket) then return results end   -- see FindItem
    local pockets = pocket and { slotContainer(pocket) } or PlayerContainers
    for _, p in ipairs(pockets) do
        eachStackOf(player, p, item, function(slot, data)
            results[#results + 1] = foundEntry(player, p, slot, data)
        end)
    end
    return results
end
exports('FindAllItems', Inventory.findAll)

-- ============================================
-- Public Exports — Item/Container Config Reads
-- ============================================
-- Pure Config reads with no subsystem owner; they live here because every caller is an
-- inventory caller.

exports('GetItemDef', function(key)
    return Config.Items[key]
end)

exports('GetItemDefs', function()
    return Config.Items
end)

--- The pockets a character carries on their person, in fallback order: { 'player', 'accessory' }.
---
--- Returns a COPY. The one source of truth for "which pockets exist": don't hardcode
--- { 'player', 'accessory' } in a schema enum. Use it for enum validation:
---     { 'pocket', 'enum', exports.whip_core:GetPockets(), 'player' }
---
--- Read it inside Whip.register, so it is read again each time whip_core starts: it does not change
--- while whip_core runs, but Config.AccessoryStrip changes it at the next start.
---@return string[]
exports('GetPockets', function()
    local out = {}
    for i, c in ipairs(PlayerContainers) do out[i] = c end
    return out
end)

--- Slot count for one of the player's pockets — see GetPockets for the valid names. Returns the
--- whole table when called with no argument, so external code can bound a slot loop by the real capacity.
---@param pocket string|nil
---@return number|table|nil
exports('GetPocketSlots', function(pocket)
    if pocket then return Config.ContainerSlots[pocket] end
    return Config.ContainerSlots
end)

--- Max weight for one of the player's pockets, same contract as GetPocketSlots.
---@param pocket string|nil
---@return number|table|nil
exports('GetPocketMaxWeight', function(pocket)
    if pocket then return Config.MaxWeight[pocket] end
    return Config.MaxWeight
end)

-- ============================================
-- Player Inventory Sessions
-- Allows one player (admin/robber) to view and
-- interact with another player's inventory as a
-- secondary panel.
-- ============================================
-- State and logic live here; the client-facing SecureEvents stay in events_misc.lua. Others read a
-- session through Inventory.playerInvSession; player_lifecycle.lua's clean-ups are
-- Inventory.closeOfflineSessionsOn and Inventory.endPlayerInvSessionsFor, below.

-- Session state: tracks which admin has which target open
-- { [adminSource] = { targetCharId, targetSource, targetCache, isOnline, range?, openedAt } }
local _playerInvSessions = {}

--- The session this player has open on another player's inventory, or nil. Live: read it, do not
--- keep it across a yield or change it.
---@param source number
---@return table|nil session
function Inventory.playerInvSession(source)
    return _playerInvSessions[source]
end

--- Close any OFFLINE admin session open against this character, saving the admin's edits first.
--- For a character logging in, before its live cache is built — see the note above the call in
--- server/player_lifecycle.lua for why the two must never coexist.
---@param charId number
---@return boolean saved  false when the admin's copy could not be written (the load must wait)
function Inventory.closeOfflineSessionsOn(charId)
    local saved = true
    for adminSrc, sess in pairs(_playerInvSessions) do
        if sess.targetCharId == charId and not sess.isOnline then
            -- Save while the admin's copy is still the ONLY copy (see player_lifecycle.lua), through
            -- the store, and checked: a failed save makes the load wait.
            if not Inventory.saveInspected(charId, sess.targetCache) then saved = false end
            _playerInvSessions[adminSrc] = nil
            TriggerClientEvent('whip_core:client:closePlayerInventory', adminSrc)
            ShowError(adminSrc,
                'That character just logged in — their inventory was saved and closed')
        end
    end
    return saved
end

--- A player is leaving (playerDropped): end the session they had open on somebody, and every
--- session open on THEM.
---@param source number
---@param player table|nil  their player object, when they had a character loaded
function Inventory.endPlayerInvSessionsFor(source, player)
    -- Clean up player inventory sessions (if this admin was viewing someone)
    local piSession = _playerInvSessions[source]
    if piSession then
        if piSession.isOnline then
            local targetPlayer = Players[piSession.targetSource]
            if targetPlayer then
                targetPlayer._inventoryLocked = nil
            end
        else
            Inventory.saveInspected(piSession.targetCharId, piSession.targetCache)
        end
        _playerInvSessions[source] = nil
    end

    -- If this disconnecting player was a target, close the admin's session
    if player then
        for adminSrc, sess in pairs(_playerInvSessions) do
            if sess.targetSource == source then
                -- Save what we have, unlock, close session. (Their LIVE cache: the rawInventory store
                -- is their own 'player:' unit then, so this takes the same claim their save does.)
                Inventory.saveInspected(sess.targetCharId, sess.targetCache)
                _playerInvSessions[adminSrc] = nil
                TriggerClientEvent('whip_core:client:closePlayerInventory', adminSrc)
                ShowError(adminSrc, 'Target player disconnected')
            end
        end
    end
end

-- A leashed session (see OpenPlayerInventory) ends after this long however it is going.
local PLAYER_INV_MAX_MS = 5 * 60 * 1000
-- The leash the OpenPlayerInventory export puts on when the caller does not say.
local PLAYER_INV_DEFAULT_RANGE = 5.0

--- Write an inspected character's inventory — the admin's copy of an OFFLINE target — now.
---
--- Through the store (flushNow claims the unit, takes its whole group, and says whether it landed),
--- so it can't overlap a flush of the same 'raw:' unit.
---@param charId number
---@param cache table
---@return boolean saved
function Inventory.saveInspected(charId, cache)
    local store = Stores.rawInventory(cache, charId, 'player')
    if not store then return false end
    local ok, saved = pcall(Stores.flushNow, store)
    return ok and saved == true
end

--- Is the viewer within `range` metres of the target's ped?
---@return boolean
function Inventory.targetInReach(viewer, target, range)
    local ped = target and GetPlayerPed(target)
    if not ped or ped == 0 then return false end
    local at = GetEntityCoords(ped)
    return IsPlayerNear(viewer, at.x, at.y, at.z, range) == true
end

--- Close a leashed session when its viewer walks off, its target leaves, or it has run too long.
--- Once a second; ends itself when the session is gone.
---@param source number
---@param session table
local function watchPlayerInventorySession(source, session)
    CreateThread(function()
        while _playerInvSessions[source] == session do
            Wait(1000)
            if _playerInvSessions[source] ~= session then return end
            local why
            if not Players[session.targetSource] then
                why = 'They are gone'
            elseif not Inventory.targetInReach(source, session.targetSource, session.range + 1.0) then
                why = 'Too far away — closed'
            elseif GetGameTimer() - session.openedAt > PLAYER_INV_MAX_MS then
                why = 'Closed — that took too long'
            end
            if why then
                local viewer = Players[source]
                if viewer then
                    ClosePlayerInventorySession(source, viewer, true)
                    NotifyPlayer(source, why, 'error')
                else
                    _playerInvSessions[source] = nil
                end
                return
            end
        end
    end)
end

--- Open another player's inventory as a secondary panel.
--- Works for both online (live cache) and offline (DB load) targets.
---
--- Answers `false, 'why'` rather than showing it: the admin event returns that (whip shows and
--- records it), and a resource calling the export decides what to tell whom.
---
--- A leash, for anything but the admin tool: with `range`, the viewer must stay within it of an
--- online target (checked on every move; a watcher closes the session when they leave it, when the
--- target goes, or after PLAYER_INV_MAX_MS, so a victim is never locked out for good).
---@param source number  The admin/viewer's server ID
---@param targetCharId number  The target character's charId
---@param range number|nil  metres the viewer must stay within of an online target; nil = no leash
---@param admin boolean|nil  the ACE-gated admin tool — the one session that may DESTROY the target's
---                          items; the export never sets it
---@return boolean success
---@return string|nil why
function OpenPlayerInventory(source, targetCharId, range, admin)
    local player = Players[source]
    if not player or not player.inventory then
        return false, 'Not loaded'
    end

    -- Already has a session open
    if _playerInvSessions[source] then
        return false, 'You already have a player inventory open'
    end

    -- Check if someone else already has this target open
    for _, session in pairs(_playerInvSessions) do
        if session.targetCharId == targetCharId then
            return false, 'Another player is already viewing this inventory'
        end
    end

    local targetCache
    local targetSource
    local targetName
    local isOnline = false
    ---@type number|nil
    local retiredGone = 0   -- retired items taken out as an offline copy loaded (Inventory.load)

    -- A character whose live cache is mid-build is neither online nor safely offline: the
    -- online branch cannot see it yet (PlayersByCharId is written last), so an open here would
    -- take the OFFLINE branch and produce exactly the detached second cache that wipes the
    -- live session on close. Refuse for the moment it takes to finish.
    if LoadingCharIds and LoadingCharIds[targetCharId] then
        return false, 'That character is logging in right now — try again in a moment'
    end

    -- Try online first
    local targetPlayer = PlayersByCharId[targetCharId]
    if targetPlayer then
        isOnline = true
        targetSource = targetPlayer.source
        targetCache = targetPlayer.inventory
        targetName = targetPlayer.fullName

        if not targetCache then
            return false, 'Target inventory not loaded'
        end

        if range and not Inventory.targetInReach(source, targetSource, range) then
            return false, 'They are too far away'
        end

        -- Lock the target's own inventory screen while someone else is in it
        targetPlayer._inventoryLocked = true
    else
        -- What is owed lands first (their last session's save, an earlier view's): this copy is
        -- saved as a diff of what it reads, so a later write under it would be mixed in.
        if not Stores.settle('player:' .. tostring(targetCharId))
            or not Stores.settle('raw:' .. tostring(targetCharId)) then
            return false, 'Their last save has not landed yet — try again in a moment'
        end

        -- Offline: load from DB. nil means the read failed — opening the session anyway
        -- would show an empty inventory and then persist that emptiness over their items.
        targetCache, retiredGone = Inventory.load(targetCharId)
        if not targetCache then
            return false, 'Could not read that character\'s inventory'
        end

        -- Get character name from DB (`deleted` is TIMESTAMP NULL, never 0).
        local ok, rows = pcall(MySQL.query.await,
            'SELECT `firstName`, `lastName` FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL LIMIT 1',
            { targetCharId }
        )
        if ok and rows and rows[1] then
            targetName = rows[1].firstName .. ' ' .. rows[1].lastName
        else
            return false, 'Character not found'
        end

        -- Asked again after the waits: another viewer may have opened this character, or it logged
        -- in. Two copies would each save their own version; the copy just read is dropped unused.
        if _playerInvSessions[source] then
            return false, 'You already have a player inventory open'
        end
        for _, other in pairs(_playerInvSessions) do
            if other.targetCharId == targetCharId then
                return false, 'Another player is already viewing this inventory'
            end
        end
        if PlayersByCharId[targetCharId] or (LoadingCharIds and LoadingCharIds[targetCharId]) then
            return false, 'That character just logged in — open their inventory again'
        end
    end

    -- Store session
    local session = {
        targetCharId = targetCharId,
        targetSource = targetSource,
        targetCache  = targetCache,
        isOnline     = isOnline,
        range        = isOnline and range or nil,   -- the leash; an offline target has no body
        openedAt     = GetGameTimer(),
        admin        = admin == true or nil,   -- may destroy (Stores.commitDestroy)
    }
    _playerInvSessions[source] = session
    if session.range then watchPlayerInventorySession(source, session) end
    -- Now that this copy is the one kept: the retired items it lost on loading are written with the next flush.
    -- (Each branch above returned if it had none.)
    ---@cast targetCache -nil
    if (retiredGone or 0) > 0 then Stores.markDirty(Stores.rawInventory(targetCache, targetCharId, 'player')) end

    -- Build and send payload
    local payload = Inventory.buildPayload(player)
    payload.targetInv       = Inventory.serialize(targetCache)
    payload.targetWeights   = {
        player   = Inventory.getWeight(targetCache, 'player'),
        accessory = Inventory.getWeight(targetCache, 'accessory'),
    }
    payload.targetMaxSlots  = Config.ContainerSlots
    payload.targetMaxWeight = Config.MaxWeight
    payload.targetCharName  = targetName
    payload.targetCharId    = targetCharId
    TriggerClientEvent('whip_core:client:openPlayerInventory', source, payload)

    print(('[whip_core] %s [%d] opened player inventory for %s (charId: %d, %s)'):format(
        player.fullName, source, targetName, targetCharId, isOnline and 'online' or 'offline'
    ))

    return true
end

--- Close a player-inventory session: save both sides, unlock the target, drop the session.
---
--- One implementation for both callers: the SecureEvent in events_misc.lua and the
--- ClosePlayerInventory export.
---@param source number
---@param player WhipPlayer
---@param notifyClient boolean  fire the client close event (the export's caller needs it;
---                             the SecureEvent's caller IS the client, whose UI already closed)
---@return boolean ok
---@return table|nil session  the closed session, for the caller's own logging
function ClosePlayerInventorySession(source, player, notifyClient)
    local session = _playerInvSessions[source]
    if not session then return false end

    -- Save target inventory
    if session.isOnline then
        local targetPlayer = Players[session.targetSource]
        if targetPlayer then
            targetPlayer._inventoryLocked = nil
            Inventory.syncAndSave(session.targetSource, targetPlayer)
        end
    elseif not Inventory.saveInspected(session.targetCharId, session.targetCache) then
        print(('[whip_core:inv] closing the inspection of charId %d: the save did not land — it stays owed')
            :format(session.targetCharId))
    end

    -- Save admin inventory
    Inventory.syncAndSave(source, player)

    _playerInvSessions[source] = nil

    if notifyClient then
        TriggerClientEvent('whip_core:client:closePlayerInventory', source)
    end
    return true, session
end

--- Open a target's pockets beside the viewer's own. The target is a person — `source` or
--- `{ charId = n }` (WhoIs) — so an offline character is `{ charId = n }`.
---
--- Leashed by default: the viewer must stay within `opts.range` metres of an
--- online target (5 when not given), and the session closes itself when they leave it, when the
--- target goes, or after five minutes. `{ range = false }` is for an admin tool that inspects from
--- anywhere — whip's own /whip tool does not use this export.
exports('OpenPlayerInventory', function(source, target, opts)
    local targetCharId, why = WhoIs(target)
    if not targetCharId then return false, why end
    ---@type number|nil
    local range = PLAYER_INV_DEFAULT_RANGE
    if type(opts) == 'table' and opts.range ~= nil then
        if opts.range == false then
            range = nil
        else
            range = tonumber(opts.range)
            if not range or range <= 0 then return false, 'range must be a number of metres, or false' end
        end
    end
    return OpenPlayerInventory(source, targetCharId, range)
end)

exports('ClosePlayerInventory', function(source)
    local player = Players[source]
    if not player then return false, 'Player not loaded' end
    if not ClosePlayerInventorySession(source, player, true) then
        return false, 'They have no player inventory open'
    end
    return true
end)

--- Is somebody (an admin, a robber) looking through this CHARACTER's inventory right now? (Not
--- whether the player has their own inventory screen up.)
---@param charId number|nil
---@return boolean
exports('IsCharacterBeingInspected', function(charId)
    charId = tonumber(charId)
    for _, session in pairs(_playerInvSessions) do
        if session.targetCharId == charId then return true end
    end
    return false
end)
