-- ============================================
-- GROUND ITEMS — Server Module
-- Persistent 3D world items with MySQL storage
-- ============================================

GroundItems = {}
GroundItems.cache = {}        -- [id] = { id, item, amount, metadata, x, y, z, heading, createdAt, createdBy }
GroundItems._pickupLocks = {} -- [id] = true — prevents race condition on simultaneous pickup
GroundItems._grid       = {} -- [cellKey] = { [id] = true } — spatial grid
GroundItems._itemCells  = {} -- [id] = cellKey — reverse lookup
-- [id] = { netId, owner, launchedAt, path }: piles still flying (a throw; `path` for a script's, ThrowGroundItem).
-- Memory only — the row is on disk at the launch point, so a restart mid-flight leaves an ordinary pile there.
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

--- What a thrown pile weighs, in kg (a bag with what is in it): with its speed, it decides whether it knocks over
--- whoever it hits (Config.ThrowKnockdown.MinImpact, client/inventory.lua).
---@return number
function GroundItems.throwKg(item, amount, metadata)
    return Inventory.effectiveWeight(item, amount or 1, metadata) or 0
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
---@param flight table|nil             POSITIONAL FORM ONLY: { netId, owner, path? } — the pile is still
---                                    flying as that networked object (a throw). Clients draw no
---                                    prop of their own until GroundItems.settle says where it lies.
---                                    `path`: a script's throw, checked along it (flightReaches).
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
        -- What it weighs (kg): with its speed, whether it knocks over whoever it hits
        flightKg  = (type(flight) == 'table' and tonumber(flight.netId)) and GroundItems.throwKg(item, amount, metadata)
                    or nil,
    }

    GroundItems.cache[insertId] = data
    GroundItems.gridInsert(insertId, x, y)
    if data.flight and flight then
        GroundItems._flights[insertId] = { netId = data.flight, owner = flight.owner, launchedAt = GetGameTimer(),
                                           path = flight.path }
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

--- Could a script's throw along `path` (ThrowGroundItem's throwPath) have got to `pos`? Within its roll of the
--- line from where it left to where it should come down: short of that (something in the way) or on past it
--- (a bounce, a skid), but not off to one side or far beyond, and no higher than it rises.
---@param path table
---@return boolean
local function onPath(path, pos)
    if pos.z > path.apex + 3.0 then return false end
    local ax, ay = path.from.x, path.from.y
    local ux, uy = path.lands.x - ax, path.lands.y - ay
    local len2 = ux * ux + uy * uy
    local s = 0.0
    if len2 > 1e-6 then s = math.max(0.0, math.min(1.0, ((pos.x - ax) * ux + (pos.y - ay) * uy) / len2)) end
    local dx, dy = pos.x - (ax + ux * s), pos.y - (ay + uy * s)
    return dx * dx + dy * dy <= path.roll * path.roll
end

--- Could this flying pile have got to `pos`? A script's throw along its own path; a player's within a throw's
--- reach of where it was launched (the row, while it flies).
---@param data table  a cache row
---@return boolean
function GroundItems.flightReaches(data, pos)
    local flight = GroundItems._flights[data.id]
    if flight and flight.path then return onPath(flight.path, pos) end
    return GroundItems.withinThrow(data, pos)
end

--- Where a pile is NOW: a flying one is wherever its object has got to (the server's own view of
--- it), anything else where its row says. For reach checks, which must follow a pile in the air.
--- The object is the thrower's: somewhere its throw could not have got to (flightReaches), the
--- launch point is the answer, for the watchdog's settle and every pickup.
---@param data table  a cache row
---@return number x, number y, number z
function GroundItems.where(data)
    local entity = data.flight and flyingEntity(data.flight)
    if entity then
        local c = GetEntityCoords(entity)
        if GroundItems.flightReaches(data, c) then return c.x, c.y, c.z end
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

--- The networked object a client just made, once the server has heard of it: the event naming it
--- can arrive a moment before the object does.
---@param netId number
---@param ms number
---@return number|nil entity
function GroundItems.awaitEntity(netId, ms)
    local deadline = GetGameTimer() + ms
    while true do
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
        if GetGameTimer() > deadline then return nil end
        Wait(50)
    end
end

--- A hash as one unsigned number, so the server's and GetHashKey's spellings compare.
local function uhash(h) return (math.tointeger(h) or 0) & 0xFFFFFFFF end

--- Is this object the item it is thrown as: of the item's model, or the box an item without one
--- throws as? A ground row must not be pinned to somebody's car.
---@param entity number
---@param itemKey string
---@return boolean
function GroundItems.isItemObject(entity, itemKey)
    local def = Config.Items[itemKey]
    local model = uhash(GetEntityModel(entity))
    return model == uhash(GetHashKey((def and def.prop) or Config.DefaultGroundProp))
        or model == uhash(GetHashKey(Config.DefaultGroundProp))
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
    data.flight, data.flightBy, data.flightKg = nil, nil, nil
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

-- ============================================
-- A script's throw: ThrowGroundItem
-- ============================================
--
-- Only a game runs physics, so a throw a script asks for is flown by a player's game: `by`, the player the
-- script names (the robber at the ATM), or else the nearest player in the same world. Either must be within
-- THROW_FOR_RANGE of `from`, where their game has the ground loaded; further off, the item could fall through
-- the map there. That game makes the object and lets it go as it lets its own player's throws go
-- (client/inventory.lua, throwFor), then names it (throwForLaunched, below). From there it is a throw like any
-- other: the object checked as throwLaunched checks one, a pile flying from the start that anyone in reach can
-- grab, settled by its flier (throwSettled) or by the watchdog. Nobody near enough, or no launch in time: the pile
-- is put down where the throw should have come down, at once.
--
-- It is aimed as a player's throw is (ThrowAim, shared/throw_aim.lua): at `target`, at `power`, so it falls short
-- when too soft and comes in flat and fast when hard. The server works out where it should come down with the
-- same numbers, and checks the landing along that path (onPath) rather than a throw's whole reach: power goes
-- higher than a player's, and a cheating flier could otherwise drag the pile as far as that power carries.
--
-- The ask is one-shot, as Ask's questions are (server/ask.lua): a launch answers only the ask made of that game,
-- once, as the character it was made of. A launch after the ask gave up is refused, and its game drops the
-- object, so an item is never both put down and flying.

local THROW_FOR_RANGE     = 50.0   -- metres from `from` to the player whose game flies it
-- No launch by then: put down instead. The flier may take up to 2 s for the model and 2 s for a network id under load
-- (client/inventory.lua throwFor, TrackThrow), and says so at once when it cannot (throwForFailed).
local THROW_FOR_ANSWER_MS = 8000
local THROW_FOR_POWER     = 40.0   -- m/s at most (a player throws at 18)
local LAUNCH_EVENT        = 'whip_core:server:throwForLaunched'

-- ONE THROW EVERY THROW_SPACING_MS AT MOST, whoever asks. Faster than that the flier's game cannot keep up (a model
-- each, a network id each: some were put down at the target instead), so a call that comes sooner waits its turn,
-- in the order asked, and the console says so (once every THROW_WARN_MS while there is a queue).
local THROW_SPACING_MS = 500
local THROW_WARN_MS    = 5000
local throwNextAt  = 0   -- when the next throw may start (GetGameTimer)
local throwWarnedAt = -THROW_WARN_MS

--- [token] = { flier, charId, promise }: asks waiting for their launch
local throwAsks = {}
local throwAskToken = 0

--- A finite number, or nil.
local function finite(n)
    n = tonumber(n)
    if n and n == n and n > -math.huge and n < math.huge then return n end
    return nil
end

--- A position from a vector3, a vector4 or { x, y, z }, or nil.
---@return vector3|nil
local function vec3Of(v)
    local tv = type(v)
    if tv ~= 'vector3' and tv ~= 'vector4' and tv ~= 'table' then return nil end
    local x, y, z = finite(v.x), finite(v.y), finite(v.z)
    if not (x and y and z) then return nil end
    return vector3(x, y, z)
end

--- Whose game flies a script's throw: `by` when they are near enough, else the nearest player near enough in
--- the same world as `by` (its routing bucket; the shared world without one), else nil. Someone still making
--- their character never flies one, and nor does anyone on the character screen (no character loaded).
---@param by number|table|nil  a person, as WhoIs takes one
---@param from vector3
---@return number|nil source
local function throwFlier(by, from)
    local named
    if by ~= nil then
        local _, src = WhoIs(by)
        named = tonumber(src)
        if named and IsPlayerNear(named, from.x, from.y, from.z, THROW_FOR_RANGE) then return named end
    end
    local bucket = named and GetPlayerRoutingBucket(named) or 0
    local best, bestD2 = nil, THROW_FOR_RANGE * THROW_FOR_RANGE
    for src, p in pairs(Players) do
        if p.charId and not p._inCreator and GetPlayerRoutingBucket(src) == bucket then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                local dx, dy, dz = c.x - from.x, c.y - from.y, c.z - from.z
                local d2 = dx * dx + dy * dy + dz * dz
                if d2 <= bestD2 then best, bestD2 = src, d2 end
            end
        end
    end
    return best
end

--- How a script's throw goes, by ThrowAim's rule: aimed at `target` at `power`, or with no power the gentlest
--- throw that reaches it (at most THROW_FOR_POWER, past which it falls short). `lands` is where its arc comes
--- back down to the target's height, or to `from`'s when it never rises that high: the target itself, unless a
--- hard throw at something above passes through it still rising and comes down further on. `rest` is where it
--- is put when nobody flies it: the target when the throw reaches it, else `lands`. `roll` is how far off the
--- line to `lands` a bounce or a skid may carry it, further the harder it is thrown.
---@return table path { from, vel, lands, rest, apex, roll }
local function throwPath(from, target, power)
    local speed, vx, vy, vz = power, nil, nil, nil
    if power then
        vx, vy, vz = ThrowAim.arc(from, target, power)
    else
        local soft, sx, sy, sz = ThrowAim.softest(from, target)
        if soft <= THROW_FOR_POWER then speed, vx, vy, vz = soft, sx, sy, sz else speed = THROW_FOR_POWER end
    end
    local reaches = vx ~= nil
    if not reaches then
        if speed > 0 then vx, vy, vz = ThrowAim.straight(from, target, speed) end
        if not vx then vx, vy, vz = 0.0, 0.0, 0.0 end   -- no power, or `from` is the target: let go
    end
    local lands = vector3(ThrowAim.landing(from, vx, vy, vz, target.z))
    return { from = from, vel = vector3(vx, vy, vz), lands = lands, rest = reaches and target or lands,
             apex = ThrowAim.apex(from, vz), roll = THROW_ROLL * math.max(1.0, speed / THROW_V) }
end

--- Ask `flier`'s game to fly it along `path`, and wait for the launch: the pile, flying, or nil and why (no launch in
--- time, or not the object asked for, which its game is told to drop). The why is said with the put-down pile.
---@return table|nil row
---@return string|nil why
local function askThrow(flier, item, amount, metadata, createdBy, path)
    throwAskToken = throwAskToken + 1
    local token = throwAskToken
    local kg = GroundItems.throwKg(item, amount, metadata)
    local ask = { flier = flier, charId = Players[flier] and Players[flier].charId, promise = promise.new(),
                  from = path.from, kg = kg }
    throwAsks[token] = ask
    TriggerClientEvent('whip_core:client:throwFor', flier, token, item, path.from, path.vel, kg)
    SetTimeout(THROW_FOR_ANSWER_MS, function()
        if throwAsks[token] == ask then
            throwAsks[token] = nil
            ask.promise:resolve(false)
        end
    end)
    local netId = Citizen.Await(ask.promise)
    if not netId then
        return nil, ask.failed or ('no launch from the thrower\'s game within %g s'):format(THROW_FOR_ANSWER_MS / 1000)
    end

    -- The object, checked as a player's throw is (throwLaunched): the flier's own, of the item's model, and
    -- somewhere along its path.
    local function refuse(recorded, why)
        if recorded then RecordEventRejection(LAUNCH_EVENT, flier, recorded) end
        TriggerClientEvent('whip_core:client:throwRefused', flier, netId)
        return nil, why
    end
    local entity = GroundItems.awaitEntity(netId, 1500)
    if not entity then return refuse(nil, 'the server did not see the thrown object within 1.5 s') end
    if GetEntityType(entity) ~= 3 or NetworkGetEntityOwner(entity) ~= flier then
        return refuse('not their own thrown object', 'the thrown object was not the thrower\'s own')
    end
    if not GroundItems.isItemObject(entity, item) then
        return refuse('the thrown object is not that item', 'the thrown object was not that item\'s model')
    end
    local at = GetEntityCoords(entity)
    if not onPath(path, at) then
        return refuse('thrown object off its path', 'the thrown object was off its path when the server looked')
    end

    local row = GroundItems.create(item, amount, metadata, at.x, at.y, at.z, GetEntityHeading(entity), createdBy,
        nil, { netId = netId, owner = flier, path = path })
    if not row then return refuse(nil, 'the pile could not be made') end
    TriggerClientEvent('whip_core:client:throwAccepted', flier, netId, row.id)
    return row
end

--- The flier's game let go of what it was asked to throw (askThrow), and names the object. Only the game
--- asked, once, as the character asked; anything else, a launch after the ask gave up included, is dropped
--- by that game.
SecureEvent(LAUNCH_EVENT, {
    -- The default rate limit: ThrowGroundItem starts one throw every THROW_SPACING_MS, so an honest game never meets it
    whileDead = true,              -- the flier may be down: their game still runs the throw
    params = { {'token', 'id'}, {'netId', 'id'} },
}, function(source, player, token, netId)
    local ask = throwAsks[token]
    if not ask or ask.flier ~= source or ask.charId ~= player.charId then
        TriggerClientEvent('whip_core:client:throwRefused', source, netId)
        if ask then RecordEventRejection(LAUNCH_EVENT, source, 'not their throw') end
        return
    end
    throwAsks[token] = nil
    -- Every game near where it is thrown from watches it (a player's own throw says this itself: throwStarted), and
    -- knows what it weighs at once
    SendToPlayers(PlayersInRange(ask.from.x, ask.from.y), 'whip_core:client:playerThrew', source, netId, ask.kg)
    ask.promise:resolve(netId)
end)

--- The flier's game could not throw it (throwFor): no model, no object, or no network id for it (too many in the air
--- at once). The item is put down at once, with that said, rather than when the ask runs out.
local FAILED_WHY = {
    model   = 'the thrower\'s game could not load its model',
    object  = 'the thrower\'s game could not make the object',
    network = 'the thrower\'s game could not give the object a network id (too many in the air at once)',
}
SecureEvent('whip_core:server:throwForFailed', {
    whileDead = true,    -- (the default rate limit, as the launch's)
    params = { {'token', 'id'}, {'why', 'enum', { 'model', 'object', 'network' }} },
}, function(source, player, token, why)
    local ask = throwAsks[token]
    if not ask or ask.flier ~= source or ask.charId ~= player.charId then return end
    throwAsks[token] = nil
    ask.failed = FAILED_WHY[why]
    ask.promise:resolve(false)
end)

--- Throw an item from a point at a target, as a player throws one: it flies, anyone in reach can grab it out of
--- the air, and it lies where it comes to rest.
---
---     ThrowGroundItem({ item = 'cash', amount = 250, from = vector3(x, y, z), target = vector3(x, y, z),
---                       power = 20, by = source, reason = 'ATM robbery' })
---
--- `power` is how hard, 0 to THROW_FOR_POWER (m/s; a player throws at 18): too soft and it falls short, hard and
--- it comes in flat and skids on. Without it, the gentlest throw that reaches the target, which comes down
--- closest to it. `by` (a person: a server id or { charId = n }) is whose game flies it when they are within
--- THROW_FOR_RANGE of `from`; else the nearest player who is. With nobody that near it is put down where the
--- throw should come down (the target, when it reaches; a vector4 target's w is its heading), lying still.
--- `metadata`, `reason` and `createdBy` as CreateGroundItem's.
---
--- One throw starts every THROW_SPACING_MS at most: a call that comes sooner waits its turn, in the order asked (and
--- the console warns that throws are being asked for too quickly).
---
--- Returns the row and how it went, 'thrown' (flying now) or 'ground' (put down, and why), or `false, reason`. It
--- waits its turn, then for the flier's game: a round trip, THROW_FOR_ANSWER_MS at most. From a SecureCallback (the
--- client gives up after 10 s), throw in a CreateThread and answer at once.
---@param t table { item, amount?, from, target, power?, by?, metadata?, reason?, createdBy? }
function GroundItems.throwItem(t)
    -- Who asked, read BEFORE anything waits (see createItem).
    local askedBy = Log.byCaller() or 'by whip_core'

    if type(t) ~= 'table' then
        return false, 'ThrowGroundItem takes one table: { item, amount?, from, target, power?, by?, metadata?, reason? }'
    end
    if t.reason ~= nil then askedBy = Log.reasonFrom(t.reason) or askedBy end
    local from, target = vec3Of(t.from), vec3Of(t.target)
    if not from then return false, 'ThrowGroundItem needs from (a vector3)' end
    if not target then return false, 'ThrowGroundItem needs target (a vector3)' end
    local power
    if t.power ~= nil then
        power = finite(t.power)
        if not power or power < 0 or power > THROW_FOR_POWER then
            return false, ('power is 0 to %g'):format(THROW_FOR_POWER)
        end
    end
    if type(t.item) ~= 'string' or not Config.Items[t.item] then
        return false, ('Unknown item "%s"'):format(tostring(t.item))
    end
    local amount = Sanitize.amount(t.amount, 1)
    if not amount then return false, Sanitize.AMOUNT_ERR end
    local metadata = type(t.metadata) == 'table' and t.metadata or nil
    -- `by` as the character, read now: after the wait below a server id may be someone else's, or theirs again under
    -- a new id. Not online is no refusal (the nearest flies it); not a person at all is.
    local by
    if t.by ~= nil then
        if type(t.by) ~= 'table' and not tonumber(t.by) then return false, 'by is a server id or { charId = n }' end
        local charId, why = WhoIs(t.by)
        if not charId and type(t.by) == 'table' then return false, why end
        by = charId and { charId = charId } or nil
    end

    -- Its turn: the next free slot, THROW_SPACING_MS after the one before. Who flies it is chosen when it comes.
    local now = GetGameTimer()
    local startAt = math.max(now, throwNextAt)
    throwNextAt = startAt + THROW_SPACING_MS
    if startAt > now then
        if now - throwWarnedAt >= THROW_WARN_MS then
            throwWarnedAt = now
            print(('^3[whip_core:ground] ThrowGroundItem is being asked to throw faster than one every %d ms (%s): going '
                .. 'faster causes problems, so the throws are queued (%d waiting)^7')
                :format(THROW_SPACING_MS, askedBy, math.ceil((startAt - now) / THROW_SPACING_MS)))
        end
        Wait(startAt - now)
    end

    local path = throwPath(from, target, power)
    local how = 'thrown'
    local flier = throwFlier(by, from)
    local row, putDownWhy
    if flier then
        row, putDownWhy = askThrow(flier, t.item, amount, metadata, t.createdBy, path)
    else
        putDownWhy = ('nobody within %g m of where it is thrown from'):format(THROW_FOR_RANGE)
    end
    if not row then
        how = 'ground'
        local at = path.rest
        local heading = (type(t.target) == 'vector4' or type(t.target) == 'table') and finite(t.target.w) or 0.0
        local err
        row, err = GroundItems.create(t.item, amount, metadata, at.x, at.y, at.z, heading, t.createdBy)
        if not row then return false, err or 'Could not create the ground item' end
    end

    DevTools.refresh('gim')
    -- An item entering the game, as CreateGroundItem's.
    Log.write(row.createdBy, 'gained', {
        itemKey = row.item, amount = row.amount,
        detail  = askedBy .. (how == 'thrown' and ' · thrown' or ' · on the ground'),
        x = row.x, y = row.y, z = row.z,
    })
    if how == 'ground' then return row, how, putDownWhy end
    return row, how
end
exports('ThrowGroundItem', GroundItems.throwItem)

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

-- ============================================
-- The throw test (/throwtest, tools/throw_test.lua)
-- ============================================
--
-- A developer trying ThrowGroundItem in the world: each ask throws one item, picked at random from every item any
-- resource has registered, from their point at their target at their power, exactly as a script's call would, with
-- `by` = them (their own game flies it when they are near the point). Held down, the tool asks up to 20 times a
-- second, and ThrowGroundItem queues them: developer mode only. Clear takes back what the test threw that still lies
-- on the ground. The answer of each throw goes back to the tool's card, never as a toast (held down, that is two a
-- second).

local TEST_REACH = 20000.0   -- metres either way a test point may be (the map is well inside that)

--- [source] = { [ground item id] = true }: what each developer's test threw, for Clear
local testThrown = {}

--- One registered item's key, any resource's, at random.
---@return string|nil
local function randomItemKey()
    local keys = {}
    for key in pairs(Config.Items) do keys[#keys + 1] = key end
    if #keys == 0 then return nil end
    return keys[math.random(#keys)]
end

SecureEvent('whip_core:server:throwTest', {
    ace = 'whip.devtools',
    -- Held down, the tool asks up to 20 times a second (tools/throw_test.lua ASK_MS); ThrowGroundItem queues them,
    -- one every 500 ms (THROW_SPACING_MS)
    rateLimit = 50, burst = 10,
    params = {
        {'fx', 'number', -TEST_REACH, TEST_REACH}, {'fy', 'number', -TEST_REACH, TEST_REACH}, {'fz', 'number', -500, 3000},
        {'tx', 'number', -TEST_REACH, TEST_REACH}, {'ty', 'number', -TEST_REACH, TEST_REACH}, {'tz', 'number', -500, 3000},
        {'tw', 'number', -360, 720, 0}, {'power', 'number', 0, THROW_FOR_POWER},
    },
}, function(source, player, fx, fy, fz, tx, ty, tz, tw, power)
    local key = randomItemKey()
    if not key then
        TriggerClientEvent('whip_core:client:throwTestResult', source, false, nil, 'No items are registered')
        return
    end
    local def = Config.Items[key]
    local label = type(def) == 'table' and def.label or key
    local charId = player.charId
    -- Thrown in a thread: a queued throw may wait a long time for its turn, and the event is done with
    CreateThread(function()
        local row, how, putDownWhy = GroundItems.throwItem({
            item = key, amount = 1, from = vector3(fx, fy, fz), target = vector4(tx, ty, tz, tw), power = power,
            by = source, reason = 'Throw test',
        })
        -- (It waited: answered, and kept for Clear, only while it is still them, or a dropped source's list would
        -- come back for whoever gets that id next)
        local now = Players[source]
        if not now or now.charId ~= charId then return end
        if not row then
            TriggerClientEvent('whip_core:client:throwTestResult', source, false, label, tostring(how))
            return
        end
        local mine = testThrown[source]
        if not mine then mine = {} testThrown[source] = mine end
        mine[row.id] = true
        TriggerClientEvent('whip_core:client:throwTestResult', source, how, label, putDownWhy)
    end)
end)

SecureEvent('whip_core:server:throwTestClear', {
    ace = 'whip.devtools',
    rateLimit = 1000, burst = 2,
}, function(source)
    local mine = testThrown[source]
    testThrown[source] = nil
    local removed = 0
    for id in pairs(mine or {}) do
        -- (One a player picked up, or removed already, is not there to remove: false, and not counted)
        if GroundItems.cache[id] and GroundItems.deleteItem(id) then removed = removed + 1 end
    end
    TriggerClientEvent('whip_core:client:throwTestCleared', source, removed)
end)

AddEventHandler('playerDropped', function()
    local src = source
    testThrown[src] = nil
end)

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
