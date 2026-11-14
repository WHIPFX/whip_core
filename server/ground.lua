-- ============================================
-- GROUND ITEMS — Server Module
-- Persistent 3D world items with MySQL storage
-- ============================================

GroundItems = {}
GroundItems.cache = {}        -- [id] = { id, item, amount, metadata, x, y, z, heading, createdAt, createdBy }
GroundItems._pickupLocks = {} -- [id] = true — prevents race condition on simultaneous pickup
GroundItems._grid       = {} -- [cellKey] = { [id] = true } — spatial grid
GroundItems._itemCells  = {} -- [id] = cellKey — reverse lookup
-- [id] = { netId, owner, launchedAt }: piles still flying (a throw). Memory only — the
-- row is on disk at the launch point, so a restart mid-flight leaves an ordinary pile there.
GroundItems._flights    = {}

--- Metadata keys that say where a PILE lies, not what the item is: left on the ground when it is picked up
--- (events_inventory.lua pickupMetadata), so the item in the pocket is a plain one. A Director standing spot's
--- stamp (director/main.lua): the spot's pile goes with its scenario's tag, but the item taken from it is the
--- finder's to keep, drop and stack. A run's own pile (drun, DirectorEffects.placePile): its run clears it, and a
--- start of whip clears one whip_core stopped under; what was picked up from it is not the pile.
GroundItems.PILE_KEYS = { dstanding = true, drun = true }

-- ============================================
-- Spatial Grid Helpers
-- ============================================

local CELL_SIZE = nil

local function getCellSize()
    if not CELL_SIZE then CELL_SIZE = Config.GroundItemCellSize or 50 end
    return CELL_SIZE
end

--- Compute cell key from world X/Y coordinates.
function GroundItems.cellKey(x, y)
    local cs = getCellSize()
    return math.floor(x / cs) .. '_' .. math.floor(y / cs)
end

--- Add an item to the spatial grid.
function GroundItems.gridInsert(id, x, y)
    local key = GroundItems.cellKey(x, y)
    if not GroundItems._grid[key] then
        GroundItems._grid[key] = {}
    end
    GroundItems._grid[key][id] = true
    GroundItems._itemCells[id] = key
end

--- Remove an item from the spatial grid.
function GroundItems.gridRemove(id)
    local key = GroundItems._itemCells[id]
    if key and GroundItems._grid[key] then
        GroundItems._grid[key][id] = nil
        if not next(GroundItems._grid[key]) then
            GroundItems._grid[key] = nil
        end
    end
    GroundItems._itemCells[id] = nil
end

--- Get cell keys within range of a world position (2D).
function GroundItems.getNearbyCellKeys(x, y, range)
    local cs = getCellSize()
    local radius = math.ceil(range / cs)
    local cx = math.floor(x / cs)
    local cy = math.floor(y / cs)
    local keys = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            keys[(cx + dx) .. '_' .. (cy + dy)] = true
        end
    end
    return keys
end

--- Get all cached items in a set of cell keys.
function GroundItems.getItemsInCells(cellKeys)
    local result = {}
    for key in pairs(cellKeys) do
        local bucket = GroundItems._grid[key]
        if bucket then
            for id in pairs(bucket) do
                local data = GroundItems.cache[id]
                if data then
                    result[id] = data
                end
            end
        end
    end
    return result
end

--- Injectable broadcast for item creation (overridden in events_inventory.lua for proximity sync).
---@diagnostic disable-next-line: duplicate-set-field -- the default; events_inventory.lua replaces it
GroundItems.broadcastCreate = function(data)
    TriggerClientEvent('whip_core:client:groundItemCreated', -1, data)
end

--- Injectable broadcast for an amount change (overridden in events_inventory.lua, the same way).
---@diagnostic disable-next-line: duplicate-set-field -- the default; events_inventory.lua replaces it
GroundItems.broadcastUpdate = function(data)
    TriggerClientEvent('whip_core:client:groundItemUpdated', -1, data.id, data.amount)
end

-- ============================================
-- Database Operations
-- ============================================

--- Auto-create the ground_items table if it doesn't exist
---@return boolean ok
function GroundItems.ensureTable()
    return CreateTable('ground_items', [[
        CREATE TABLE IF NOT EXISTS `ground_items` (
            `id`        INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `item`      VARCHAR(50)  NOT NULL,
            `amount`    INT UNSIGNED NOT NULL DEFAULT 1,
            `metadata`  JSON         DEFAULT NULL,
            `x`         FLOAT        NOT NULL,
            `y`         FLOAT        NOT NULL,
            `z`         FLOAT        NOT NULL,
            `heading`   FLOAT        NOT NULL DEFAULT 0.0,
            `placed`    TINYINT(1)   NOT NULL DEFAULT 0,
            `rx`        FLOAT        NOT NULL DEFAULT 0.0,
            `ry`        FLOAT        NOT NULL DEFAULT 0.0,
            `createdAt` TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy` INT UNSIGNED DEFAULT NULL,
            PRIMARY KEY (`id`),
            KEY `idx_ground_item` (`item`),
            CONSTRAINT `fk_ground_createdBy` FOREIGN KEY (`createdBy`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

function GroundItems.loadAll()
    GroundItems.ensureTable()
    local ok, rows = pcall(MySQL.query.await,
        'SELECT * FROM `ground_items`', {}
    )

    if not ok then
        print(('[whip_core:ground] ERROR loading ground items: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    GroundItems.cache = {}
    GroundItems._grid = {}
    GroundItems._itemCells = {}
    if rows then
        for _, row in ipairs(rows) do
            -- TYPE-CHECKED BEFORE next() (Inventory.readMetadata, the rule every item loader shares):
            -- a row whose metadata decodes to a number or a string — written by a caller that got
            -- GroundItems.create's argument order wrong, or edited by hand — made `next(decoded)`
            -- throw INSIDE the load loop, so one bad row took every ground item on the server down
            -- with it. The item still loads, just without whatever could not be read.
            local meta = Inventory.readMetadata(row.metadata, ('ground item #%s'):format(tostring(row.id)))

            -- Epoch SECONDS, like a drop made this session (os.time()); oxmysql gives the column back
            -- in milliseconds.
            local created = EpochSeconds(row.createdAt) or 0

            -- Read once, used three times below. See the note on `placed` for why it has to
            -- accept an integer OR a boolean.
            local isPlacedFlag = (row.placed == 1) or (row.placed == true)

            GroundItems.cache[row.id] = {
                id        = row.id,
                item      = row.item,
                amount    = row.amount or 1,
                metadata  = meta,
                x         = row.x,
                y         = row.y,
                z         = row.z,
                heading   = row.heading or 0.0,
                -- true or NIL, never false: cache rows travel whole into the sync payloads,
                -- and the flag only exists on deliberately-placed items — the unset case
                -- (thrown, dropped, spawned) should cost the wire nothing. Same rule for
                -- the tilt pair: they only ride on placed rows.
                --
                -- Both shapes accepted: the INSERT writes 1 or 0, but oxmysql type-casts TINYINT(1)
                -- to a Lua boolean on the way back. The shape is the driver's to decide, so both are
                -- compared (as DbBool does).
                placed    = isPlacedFlag and true or nil,
                rx        = isPlacedFlag and (row.rx or 0.0) or nil,
                ry        = isPlacedFlag and (row.ry or 0.0) or nil,
                createdAt = created,
                createdBy = row.createdBy,
            }
            GroundItems.gridInsert(row.id, row.x, row.y)
        end
    end

end

--- Create a ground item.
---
--- Accepts EITHER shape, because the positional-only form has now been got wrong by two
--- independent callers in exactly the same way:
---
---     create(item, amount, metadata, x, y, z, heading, createdBy)
---     create(item, amount, coords,   metadata, heading, createdBy)   -- coords = vector3
---
--- shops.lua passed a table where x belonged: a shop purchase that overflowed the player's
--- inventory threw inside the INSERT, the pcall swallowed it, the caller discarded the return,
--- and the item was DESTROYED after payment had been taken.
---
--- When callers reach for `coords` against one signature, the signature is the defect. Both forms now work, and x/y/z being NOT NULL can no longer turn an honest mistake
--- at the call site into silent item loss.
---@param item string
---@param amount number
---@param metaOrCoords table|vector3|nil  metadata, or coords in the second form
---@param xOrMeta number|table|nil     x, or metadata in the second form
---@param placed boolean|table|nil     POSITIONAL FORM ONLY: truthy = exact placement (placing
---                                    mode) — the client renderer trusts the stored z/heading
---                                    and skips PlaceObjectOnGroundProperly. As a table it
---                                    also carries the surface tilt: { rx = pitch, ry = roll }
---                                    in degrees. The coords form does not accept it: its
---                                    argument-shifting is already delicate, and no
---                                    coords-form caller places.
---@param flight table|nil             POSITIONAL FORM ONLY: { netId, owner } — the pile is still
---                                    flying as that networked object (a throw). Clients draw no
---                                    prop of their own until GroundItems.settle says where it lies.
function GroundItems.create(item, amount, metaOrCoords, xOrMeta, y, z, heading, createdBy, placed, flight)
    local metadata, x

    -- Which form is this? The decisive signal is the FOURTH argument, not the third: in the
    -- positional form it is `x`, a number. Checking that first means a metadata table which
    -- happens to carry numeric x/y/z fields — a map marker, a saved position — is still read
    -- as metadata rather than mistaken for coordinates.
    local looksLikeCoords =
        type(xOrMeta) ~= 'number'
        and (type(metaOrCoords) == 'vector3'
             or (type(metaOrCoords) == 'table'
                 and type(metaOrCoords.x) == 'number'
                 and type(metaOrCoords.y) == 'number'
                 and type(metaOrCoords.z) == 'number'))

    if looksLikeCoords then
        -- Coords form: (item, amount, coords, metadata, heading, createdBy). Every later
        -- argument shifts down by two, so read heading and createdBy out of the y and z
        -- slots BEFORE overwriting those from the vector. `placed` is deliberately NOT
        -- threaded through this form — see the doc-comment above.
        metadata  = type(xOrMeta) == 'table' and xOrMeta or nil
        heading   = tonumber(y) or 0.0
        createdBy = z
        placed    = nil
        ---@cast metaOrCoords -nil
        x, y, z   = metaOrCoords.x, metaOrCoords.y, metaOrCoords.z
    else
        metadata = metaOrCoords
        x        = xOrMeta
    end

    -- FAILURE IS `false, reason` AND NOT `nil, reason`, AND THE DIFFERENCE IS LOAD-BEARING.
    --
    -- A FiveM export truncates its return list AT THE FIRST NIL, wherever that nil sits: the
    -- caller across the boundary gets everything before it and nothing after. So
    -- `return nil, 'Invalid coordinates'` reached every satellite as a bare nil with the reason
    -- silently dropped — indistinguishable from the swallowed INSERT failure this guard exists
    -- to replace.
    --
    -- It is not only a LEADING nil. `true, nil, 'inventory'` in Inventory.giveOrDrop lost its third value
    -- the same way; AddItem's ground case survived only because its middle slot happens to hold
    -- a non-nil error string.
    --
    -- `false` is falsy, so every existing `if not data then` caller is unaffected, and the reason
    -- now actually crosses. The rule for every export in this framework: NEVER return nil in any
    -- slot that has a value after it.
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
        print(('[whip_core:ground] REFUSED to create "%s": no usable coordinates. Pass either ' ..
               '(item, amount, metadata, x, y, z) or (item, amount, coords, metadata).')
            :format(tostring(item)))
        return false, 'Invalid coordinates'
    end

    local metaJson = metadata and json.encode(metadata) or '{}'

    -- `placed` is truthy-or-nil; as a table it also carries the surface tilt.
    local placedFlag = placed and 1 or 0
    local rx = (type(placed) == 'table' and tonumber(placed.rx)) or 0.0
    local ry = (type(placed) == 'table' and tonumber(placed.ry)) or 0.0

    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `ground_items` (`item`, `amount`, `metadata`, `x`, `y`, `z`, `heading`, `placed`, `rx`, `ry`, `createdBy`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        { item, amount or 1, metaJson, x, y, z, heading or 0.0, placedFlag, rx, ry, createdBy }
    )

    if not ok then
        print(('[whip_core:ground] ERROR creating ground item: %s'):format(tostring(insertId)))
        return false, 'Database error'
    end

    local data = {
        id        = insertId,
        item      = item,
        amount    = amount or 1,
        metadata  = metadata,
        x         = x,
        y         = y,
        z         = z,
        heading   = heading or 0.0,
        placed    = placed and true or nil,   -- nil, not false — see loadAll's note
        rx        = placed and rx or nil,
        ry        = placed and ry or nil,
        createdAt = os.time(),
        createdBy = createdBy,
        -- The flying object's network id, for clients to follow it; nil once it lies still.
        flight    = (type(flight) == 'table' and tonumber(flight.netId)) or nil,
        -- Who threw it (a server id), beside it: a game follows an object only while the thrower's game owns it
        -- (client/inventory.lua, watchThrows)
        flightBy  = (type(flight) == 'table' and tonumber(flight.netId) and tonumber(flight.owner)) or nil,
    }

    GroundItems.cache[insertId] = data
    GroundItems.gridInsert(insertId, x, y)
    if data.flight and flight then
        GroundItems._flights[insertId] = { netId = data.flight, owner = flight.owner, launchedAt = GetGameTimer() }
    end

    -- Broadcast to synced clients (proximity-aware)
    GroundItems.broadcastCreate(data)

    return data
end

--- The flying object of a throw, or nil when it is gone (or never reached the server).
---@param netId number|nil
---@return number|nil entity
local function flyingEntity(netId)
    if not netId then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
    return nil
end

--- Take a pile out of memory and off every screen — its row is already gone. A pile still flying
--- takes its flying object with it (picked out of the air).
---@param id number
local function forget(id)
    local data = GroundItems.cache[id]
    -- To the players holding its cell, as its create and splits are. One who was away and still holds
    -- it is caught up when the cell is granted again (groundItemsBatchAdd drops what the grant does not
    -- carry). In the air, the holders of where it has got to as well. (No row in memory: everyone.)
    local to
    if data then
        to = PlayersNearPoint(data.x, data.y)
        if data.flight then
            local x, y = GroundItems.where(data)
            local seen = {}
            for _, src in ipairs(to) do seen[src] = true end
            for _, src in ipairs(PlayersNearPoint(x, y)) do
                if not seen[src] then to[#to + 1] = src end
            end
        end
    end
    local flight = GroundItems._flights[id]
    if flight then
        GroundItems._flights[id] = nil
        local entity = flyingEntity(flight.netId)
        if entity then DeleteEntity(entity) end
    end
    GroundItems.cache[id] = nil
    GroundItems.gridRemove(id)
    GroundItems._pickupLocks[id] = nil
    if to then
        SendToPlayers(to, 'whip_core:client:groundItemDeleted', id)
    else
        TriggerClientEvent('whip_core:client:groundItemDeleted', -1, id)
    end
end

-- A throw's reach, by how far it fell. The client launches at 18 m/s plus a 2.5 m/s lift, so ~20.5 m/s
-- at most; from h above where it lands, the furthest any angle carries is (v/g)·sqrt(v² + 2gh): 43 m
-- on the flat, ~150 m off the Maze Bank. THROW_ROLL more for the bounce and roll. It rises v²/2g (21 m)
-- at most.
local THROW_V, THROW_G = 20.5, 9.81
local THROW_ROLL, THROW_RISE = 20.0, 25.0

--- Could a throw from `from` have got to `to`? Anything with x, y, z.
---@return boolean
function GroundItems.withinThrow(from, to)
    local drop = from.z - to.z
    if drop < -THROW_RISE then return false end
    local reach = (THROW_V / THROW_G) * math.sqrt(THROW_V * THROW_V + 2 * THROW_G * math.max(drop, 0)) + THROW_ROLL
    local dx, dy = to.x - from.x, to.y - from.y
    return dx * dx + dy * dy <= reach * reach
end

--- Where a pile is NOW: a flying one is wherever its object has got to (the server's own view of
--- it), anything else where its row says. For reach checks, which must follow a pile in the air.
--- The object is the thrower's: past a throw's reach from the launch (the row, while it flies), the
--- launch point is the answer, for the watchdog's settle and every pickup.
---@param data table  a cache row
---@return number x, number y, number z
function GroundItems.where(data)
    local entity = data.flight and flyingEntity(data.flight)
    if entity then
        local c = GetEntityCoords(entity)
        if GroundItems.withinThrow(data, c) then return c.x, c.y, c.z end
    end
    return data.x, data.y, data.z
end

--- Who threw a pile that is still flying (a server id), or nil when it is not in the air.
---@param id number
---@return number|nil
function GroundItems.flightOwner(id)
    local flight = GroundItems._flights[id]
    return flight and flight.owner or nil
end

--- Tell everyone who can see either end of a flight where the pile came to rest. Players who were
--- sent the pile are those synced to its launch cell; the landing may be a cell further on.
---@param data table  the settled cache row
---@param fromX number
---@param fromY number
local function announceSettled(data, fromX, fromY)
    local told = {}
    for _, at in ipairs({ { fromX, fromY }, { data.x, data.y } }) do
        for _, src in ipairs(PlayersNearPoint(at[1], at[2])) do
            if not told[src] then
                told[src] = true
                TriggerClientEvent('whip_core:client:groundItemSettled', src, data)
            end
        end
    end
end

--- A flying pile has come to rest: its row, the cache and every client move to where it lies, and
--- its flying object is deleted a moment later — after clients have drawn the pile in its place, so
--- nothing blinks out between the two. `placed` as in create ({ rx, ry } keeps its exact pose; nil
--- is snapped upright).
---@param id number
---@param x number
---@param y number
---@param z number
---@param heading number
---@param placed table|nil
---@return boolean ok
---@return string|nil err
function GroundItems.settle(id, x, y, z, heading, placed)
    local data = GroundItems.cache[id]
    local flight = GroundItems._flights[id]
    if not data or not flight then return false, 'Not flying' end
    GroundItems._flights[id] = nil   -- first: a second settle (the watchdog) finds nothing to do

    local rx = (type(placed) == 'table' and tonumber(placed.rx)) or 0.0
    local ry = (type(placed) == 'table' and tonumber(placed.ry)) or 0.0
    local ok, changed = pcall(MySQL.update.await,
        'UPDATE `ground_items` SET `x` = ?, `y` = ?, `z` = ?, `heading` = ?, `placed` = ?, `rx` = ?, `ry` = ? WHERE `id` = ?',
        { x, y, z, heading or 0.0, placed and 1 or 0, rx, ry, id })
    if not ok then
        -- The row still says the launch point, and the pile is drawn there after a restart.
        print(('[whip_core:ground] ERROR settling ground item #%d: %s'):format(id, tostring(changed)))
    end

    -- The flying object goes a moment after either answer below: settled, it is drawn in its place
    -- first; picked up while the write waited, the pickup could not delete it (no flight by then).
    local netId = flight.netId
    SetTimeout(1000, function()
        local entity = flyingEntity(netId)
        if entity then DeleteEntity(entity) end
    end)

    -- Picked up while the write waited: the pickup's forget already took it off every screen.
    if GroundItems.cache[id] ~= data then return false, 'Item not found' end

    local fromX, fromY = data.x, data.y
    data.x, data.y, data.z = x, y, z
    data.heading = heading or 0.0
    data.placed  = placed and true or nil
    data.rx      = placed and rx or nil
    data.ry      = placed and ry or nil
    data.flight, data.flightBy = nil, nil
    GroundItems.gridRemove(id)
    GroundItems.gridInsert(id, x, y)
    announceSettled(data, fromX, fromY)
    return true
end

-- THE WATCHDOG for throws whose thrower never says where they landed (a crash, a disconnect, the
-- object lost). After FLIGHT_MAX_MS, or as soon as the object or its thrower is gone, the pile is
-- settled where the server last saw it, snapped upright. Asleep while nothing is in the air.
local FLIGHT_MAX_MS = 15000
Every('ground item flights', 1000, function()
    if next(GroundItems._flights) == nil then return 5000 end
    local now = GetGameTimer()
    local due = {}
    for id, flight in pairs(GroundItems._flights) do
        local entity = flyingEntity(flight.netId)
        if not entity or not Players[flight.owner] or now - flight.launchedAt > FLIGHT_MAX_MS then
            due[#due + 1] = id
        end
    end
    for _, id in ipairs(due) do
        local data = GroundItems.cache[id]
        if data then
            local x, y, z = GroundItems.where(data)
            GroundItems.settle(id, x, y, z, data.heading, nil)
        else
            GroundItems._flights[id] = nil
        end
    end
end)

function GroundItems.delete(id)
    if not GroundItems.cache[id] then return false, 'Item not found' end

    -- update.await, which answers how many rows went (query.await answered nothing to check).
    local ok, removed = pcall(MySQL.update.await,
        'DELETE FROM `ground_items` WHERE `id` = ?',
        { id }
    )

    if not ok then
        print(('[whip_core:ground] ERROR deleting ground item #%d: %s'):format(id, tostring(removed)))
        return false, 'Database error'
    end

    -- Only the DELETE that took the row has taken the pile: a pickup's lock lapses after 10 s, and a
    -- DELETE can wait longer on a slow database, letting a second pickup in. The row is the one truth
    -- both can see; the loser is told it is gone.
    if (tonumber(removed) or 0) < 1 then
        forget(id)
        return false, 'Item not found'
    end

    forget(id)
    return true
end

--- Change how many a ground pile holds — the row, the cache and everyone who can see it.
--- Write-through like create and delete: the row is updated first, and nothing else changes if
--- that fails. The prop and its position are untouched; only the count on it moves.
---@param id number
---@param amount number  a whole number, at least 1 (to empty a pile, delete it)
---@return boolean ok
---@return string|nil err
function GroundItems.setAmount(id, amount)
    local data = GroundItems.cache[id]
    if not data then return false, 'Item not found' end
    if type(amount) ~= 'number' or amount < 1 or amount ~= math.floor(amount) then
        return false, 'Invalid amount'
    end
    -- Nothing to write — and a write of the same value may count as no row changed, which below
    -- reads as "the pile is gone".
    if data.amount == amount then return true end

    local ok, changed = pcall(MySQL.update.await,
        'UPDATE `ground_items` SET `amount` = ? WHERE `id` = ?',
        { amount, id }
    )
    if not ok then
        print(('[whip_core:ground] ERROR updating ground item #%d: %s'):format(id, tostring(changed)))
        return false, 'Database error'
    end
    -- A row that is gone is not a pile: a split racing a stalled pickup must not make its half out of
    -- nothing.
    if (tonumber(changed) or 0) < 1 then
        forget(id)
        return false, 'Item not found'
    end

    data.amount = amount
    GroundItems.broadcastUpdate(data)
    return true
end

--- Put a pile somewhere else, exactly as given (an admin's Move: the Object Viewer, Dungeon Mode): the row, the cache
--- and everyone who can see either end, as a throw that lands. It lies as placed, its tilt `rot` { rx, ry }, never
--- snapped to the ground. Write-through; nothing changes if the write fails.
---@return boolean ok
---@return string|nil err
function GroundItems.place(id, x, y, z, heading, rot)
    local data = GroundItems.cache[id]
    if not data then return false, 'Item not found' end
    if data.flight then return false, 'It is in the air' end
    local rx = (type(rot) == 'table' and tonumber(rot.rx)) or 0.0
    local ry = (type(rot) == 'table' and tonumber(rot.ry)) or 0.0
    -- (No "is the row gone" from how many rows it changed: a pile moved onto where the row has it changes none.)
    local ok, err = pcall(MySQL.update.await,
        'UPDATE `ground_items` SET `x` = ?, `y` = ?, `z` = ?, `heading` = ?, `placed` = 1, `rx` = ?, `ry` = ? WHERE `id` = ?',
        { x, y, z, heading or 0.0, rx, ry, id })
    if not ok then
        print(('[whip_core:ground] ERROR moving ground item #%d: %s'):format(id, tostring(err)))
        return false, 'Database error'
    end
    -- Picked up while the write waited: gone from every screen already.
    if GroundItems.cache[id] ~= data then return false, 'Item not found' end
    local fromX, fromY = data.x, data.y
    data.x, data.y, data.z, data.heading = x, y, z, heading or 0.0
    data.placed, data.rx, data.ry = true, rx, ry
    GroundItems.gridRemove(id)
    GroundItems.gridInsert(id, x, y)
    announceSettled(data, fromX, fromY)
    return true
end

--- Make a pile another item, where it lies (an admin's Change item): its item, how many and its metadata (`metadata`
--- nil: none). Every game near it draws it again as the new item. Write-through. The caller logs what went and came.
---@return boolean ok
---@return string|nil err
function GroundItems.setItem(id, item, amount, metadata)
    local data = GroundItems.cache[id]
    if not data then return false, 'Item not found' end
    if data.flight then return false, 'It is in the air' end
    if type(item) ~= 'string' or not Config.Items[item] then return false, ('Unknown item "%s"'):format(tostring(item)) end
    if type(amount) ~= 'number' or amount < 1 or amount ~= math.floor(amount) then return false, 'Invalid amount' end
    local ok, err = pcall(MySQL.update.await,
        'UPDATE `ground_items` SET `item` = ?, `amount` = ?, `metadata` = ? WHERE `id` = ?',
        { item, amount, metadata and json.encode(metadata) or '{}', id })
    if not ok then
        print(('[whip_core:ground] ERROR changing ground item #%d: %s'):format(id, tostring(err)))
        return false, 'Database error'
    end
    if GroundItems.cache[id] ~= data then return false, 'Item not found' end
    data.item, data.amount, data.metadata = item, amount, metadata
    announceSettled(data, data.x, data.y)
    return true
end


-- ============================================
-- Cache Accessors
-- ============================================

function GroundItems.getById(id)
    return GroundItems.cache[id]
end

function GroundItems.getAll()
    return GroundItems.cache
end

--- Return cache as an array (for NUI serialization)
function GroundItems.getAllArray()
    local arr = {}
    for _, data in pairs(GroundItems.cache) do
        arr[#arr + 1] = data
    end
    return arr
end

function GroundItems.getNearby(x, y, z, range)
    local nearby = {}
    local rangeSq = range * range
    local cellKeys = GroundItems.getNearbyCellKeys(x, y, range)

    for key in pairs(cellKeys) do
        local bucket = GroundItems._grid[key]
        if bucket then
            for id in pairs(bucket) do
                local data = GroundItems.cache[id]
                if data then
                    local dx = data.x - x
                    local dy = data.y - y
                    local dz = data.z - z
                    if (dx * dx + dy * dy + dz * dz) <= rangeSq then
                        nearby[#nearby + 1] = data
                    end
                end
            end
        end
    end

    return nearby
end

--- Delete all ground items within range of coords
---@return number count of deleted items
function GroundItems.clearNearby(x, y, z, range)
    local toDelete = {}
    local rangeSq = range * range
    local cellKeys = GroundItems.getNearbyCellKeys(x, y, range)

    for key in pairs(cellKeys) do
        local bucket = GroundItems._grid[key]
        if bucket then
            for id in pairs(bucket) do
                local data = GroundItems.cache[id]
                if data then
                    local dx = data.x - x
                    local dy = data.y - y
                    local dz = data.z - z
                    if (dx * dx + dy * dy + dz * dz) <= rangeSq then
                        toDelete[#toDelete + 1] = id
                    end
                end
            end
        end
    end

    for _, id in ipairs(toDelete) do
        GroundItems.delete(id)
    end

    return #toDelete
end

--- Delete ALL ground items
---@return number count of deleted items
function GroundItems.clearAll()
    local count = 0
    local ids = {}
    for id in pairs(GroundItems.cache) do
        ids[#ids + 1] = id
    end

    for _, id in ipairs(ids) do
        if GroundItems.delete(id) then
            count = count + 1
        end
    end

    return count
end

function GroundItems.clearCell(cellKey)
    local bucket = GroundItems._grid[cellKey]
    if not bucket then return 0 end

    local ids = {}
    for id in pairs(bucket) do
        ids[#ids + 1] = id
    end

    local count = 0
    for _, id in ipairs(ids) do
        if GroundItems.delete(id) then
            count = count + 1
        end
    end

    return count
end

-- ============================================
-- Pickup with race condition protection
-- ============================================

-- A pickup lock lasts one handler call. SecureEvent pcalls its handlers, so an error between
-- tryLock and unlock would leave the item unpickable until a restart: locks carry a timestamp,
-- and one older than this is treated as abandoned.
local PICKUP_LOCK_TTL_MS = 10000

---@param id number  ground item ID
---@return boolean locked  true if lock acquired, false if already locked
function GroundItems.tryLock(id)
    local held = GroundItems._pickupLocks[id]
    if held then
        if (GetGameTimer() - held) < PICKUP_LOCK_TTL_MS then
            return false
        end
        print(('[whip_core:ground] reclaimed abandoned pickup lock on item #%s'):format(tostring(id)))
    end
    GroundItems._pickupLocks[id] = GetGameTimer()
    -- Released automatically if the acquiring handler errors (secure.lua). The TTL above
    -- remains as a backstop for any acquirer outside a SecureEvent handler.
    TrackInvocationLock(function() GroundItems.unlock(id) end)
    return true
end

function GroundItems.unlock(id)
    GroundItems._pickupLocks[id] = nil
end

-- ============================================
-- Public Exports
-- ============================================

--- Drop an item on the ground.
---
---     CreateGroundItem({ item = 'drink', amount = 2, coords = vector3(x, y, z), metadata = nil, heading = 0.0,
---                        reason = 'quest reward' })
---
--- `reason` is for the activity log, beside who asked ('quest reward · by my_jobs'), as AddItem's is.
--- One table, the only shape: the old positional ones put coords in two different places, which was
--- easy to get wrong.
---
--- The item must be registered, and the amount a whole number of 1 or more (nil = 1).
---
--- Returns the created row, or `false, reason` — never nil, which an export would cut the reason
--- off (house rule). CHECK THE RETURN: discarding it turns a failed insert into silent item
--- destruction.
---
--- whip_core calls GroundItems.createItem / deleteItem, never these exports; each
--- export is its function.
---@param t table { item, amount?, coords, metadata?, heading?, reason?, createdBy? }
function GroundItems.createItem(t)
    -- Who asked, read BEFORE the insert: after a database wait GetInvokingResource no longer
    -- names the caller.
    local askedBy = Log.byCaller() or 'by whip_core'

    if type(t) ~= 'table' then
        return false, 'CreateGroundItem takes one table: { item, amount, coords, metadata?, heading?, reason? }'
    end
    -- Its reason in the log, beside who asked (a Director run's drop says which run).
    if t.reason ~= nil then askedBy = Log.reasonFrom(t.reason) or askedBy end
    local where = t.coords
    if type(where) ~= 'vector3' and type(where) ~= 'vector4' and type(where) ~= 'table' then
        return false, 'CreateGroundItem needs coords'
    end
    local a, b, c = t.item, t.amount, t.metadata
    local d, e, f, g = tonumber(where.x), tonumber(where.y), tonumber(where.z),
        tonumber(t.heading) or tonumber(where.w) or 0.0
    local h = t.createdBy

    -- A row for an item that exists, in an amount that means something.
    -- GroundItems.create checks neither — whip's own drops only ever put real stacks down, and a
    -- player dropping an item whose resource has since been removed must still be able to — so
    -- the check is here, where something is being made from nothing.
    if type(a) ~= 'string' or not Config.Items[a] then
        return false, ('Unknown item "%s"'):format(tostring(a))
    end
    b = Sanitize.amount(b, 1)
    if not b then return false, Sanitize.AMOUNT_ERR end

    local item, err = GroundItems.create(a, b, c, d, e, f, g, h)
    if not item then return false, err or 'Could not create the ground item' end

    -- Another resource putting an item on the ground from nothing is an item entering the game
    -- (Log.gained in activity_log.lua). Whip's own drops call GroundItems.create directly and are
    -- logged where they happen, as 'dropped'/'threw'/'placed'.
    -- GroundItems.create answers with the cached row itself, not its id.
    local row = type(item) == 'table' and item or nil
    if row then
        Log.write(row.createdBy, 'gained', {
            itemKey = row.item, amount = row.amount,
            detail  = askedBy .. ' · on the ground',
            x = row.x, y = row.y, z = row.z,
        })
    end
    return item
end
exports('CreateGroundItem', GroundItems.createItem)

function GroundItems.deleteItem(id)
    -- Both read before the delete: it takes the row out of the cache, and its database wait
    -- would lose the caller.
    local row = GroundItems.cache[id]
    local askedBy = Log.byCaller() or 'by whip_core'
    local ok, err = GroundItems.delete(id)
    if ok and row then
        Log.write(nil, 'lost', {
            itemKey = row.item, amount = row.amount,
            detail  = askedBy .. ' · removed from the ground',
            x = row.x, y = row.y, z = row.z,
        })
    end
    return ok, err
end
exports('DeleteGroundItem', GroundItems.deleteItem)

--- Ground items within `range` metres. `GetGroundItemsNearby(x, y, z, range)` or
--- `GetGroundItemsNearby(coords, range)`. The range defaults to 10 m.
---@return table[]  the rows: { id, item, amount, metadata, x, y, z, heading, ... }
exports('GetGroundItemsNearby', function(x, y, z, range)
    if type(x) == 'vector3' or type(x) == 'vector4' or type(x) == 'table' then
        local c = x
        range = y
        x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return {} end
    range = tonumber(range) or 10.0
    if range <= 0 then return {} end
    return GroundItems.getNearby(x, y, z, range)
end)

--- One ground item by its id, or nil.
---@param id number|nil
---@return table|nil row
exports('GetGroundItem', function(id)
    id = Sanitize.id(id)
    return id and GroundItems.cache[id] or nil
end)
