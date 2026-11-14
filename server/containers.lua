-- ============================================
-- CONTAINERS — Server Module
-- Persistent world stashes with MySQL storage
-- ============================================

Containers = {}
Containers.cache     = {}   -- [containerId] = definition data
Containers.invCache  = {}   -- [containerId] = { [slot] = {item,amount,metadata} }  (on-demand)
Containers._keyIndex = {}   -- [key] = containerId, for the ones declared by key (EnsureContainer)
-- Who has a container open lives in Stores._views, keyed on the store id: a SET (see the viewer
-- registry in stores.lua).

-- A run's container (the Director's: a vault's safe). Made with
-- `persist = false` by a resource (never by the admin screen), it has NO ROW: an id above 2^32
-- (never a row's, which are INT UNSIGNED), contents that live in memory only and are never unloaded
-- (with nothing on disk an unload would lose them), and an owner and a `tag`, so ReleaseTag(tag)
-- removes it with the rest of a run: its screens shut, its contents written down as lost. Gone with
-- the server too, like everything else a run makes. Containers.isRuntime says which kind a def is.
local RUNTIME_BASE = 4294967296   -- 2^32
local nextRuntime = 0

---@param def table|nil
---@return boolean
function Containers.isRuntime(def)
    return type(def) == 'table' and def.persist == false
end

-- ============================================
-- Database — Table Creation
-- ============================================

---@return boolean ok
function Containers.ensureTable()
    local ok = CreateTable('containers', [[
        CREATE TABLE IF NOT EXISTS `containers` (
            `containerId`  INT UNSIGNED     NOT NULL AUTO_INCREMENT,
            `name`         VARCHAR(50)      NOT NULL DEFAULT 'Stash',
            `type`         VARCHAR(20)      NOT NULL DEFAULT 'stash',
            -- SMALLINT, not TINYINT: a container may declare more than 255 slots.
            `slots`        SMALLINT UNSIGNED NOT NULL DEFAULT 20,
            `maxWeight`    FLOAT            NOT NULL DEFAULT 100.0,
            `ownerCharId`  INT UNSIGNED     DEFAULT NULL,
            `accessCharId` INT UNSIGNED     DEFAULT NULL,
            `locked`       TINYINT(1)       NOT NULL DEFAULT 0,
            `x`            FLOAT            NOT NULL,
            `y`            FLOAT            NOT NULL,
            `z`            FLOAT            NOT NULL,
            `heading`      FLOAT            NOT NULL DEFAULT 0.0,
            `prop`         VARCHAR(60)      NOT NULL DEFAULT 'prop_cs_cardbox_01',
            `allowedItems` JSON             DEFAULT NULL,
            `createdAt`    TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy`    INT UNSIGNED     DEFAULT NULL,
            -- EnsureContainer (migration 022 adds both to an existing table): the
            -- key a resource declares the container by, and the declaration it last made.
            `key`          VARCHAR(100)     DEFAULT NULL,
            `declared`     JSON             DEFAULT NULL,
            -- Who may open it, in the doors' shape (migration 026 adds it to an
            -- existing table): { jobs, onDuty, charIds, items, ace }. NULL = no requirement.
            `requirements` JSON             DEFAULT NULL,
            -- A property's stash: a piece of its furniture that holds things (server/property_stashes.lua;
            -- migration 032 adds it to an existing table). NULL for every other container.
            `propertyId`   INT UNSIGNED     DEFAULT NULL,
            PRIMARY KEY (`containerId`),
            UNIQUE KEY `uq_container_key` (`key`),
            KEY `idx_container_property` (`propertyId`),
            KEY `idx_container_owner` (`ownerCharId`),
            KEY `idx_container_access` (`accessCharId`),
            -- SET NULL: a stash whose owner is deleted becomes unowned and keeps its contents.
            CONSTRAINT `fk_container_owner` FOREIGN KEY (`ownerCharId`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL,
            CONSTRAINT `fk_container_access` FOREIGN KEY (`accessCharId`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL,
            CONSTRAINT `fk_container_createdBy` FOREIGN KEY (`createdBy`)
                REFERENCES `characters` (`charId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    -- CASCADE: a stash's contents go with it.
    local ok2 = CreateTable('container_inventory', [[
        CREATE TABLE IF NOT EXISTS `container_inventory` (
            `containerId` INT UNSIGNED     NOT NULL,
            `slot`        SMALLINT UNSIGNED NOT NULL,
            `item`        VARCHAR(50)      NOT NULL,
            `amount`      INT UNSIGNED     NOT NULL DEFAULT 1,
            `metadata`    JSON             DEFAULT NULL,
            PRIMARY KEY (`containerId`, `slot`),
            CONSTRAINT `fk_cinv_container` FOREIGN KEY (`containerId`)
                REFERENCES `containers` (`containerId`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    return ok and ok2
end

-- ============================================
-- Load All Definitions
-- ============================================

function Containers.loadAll()
    Containers.ensureTable()

    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `containers`', {})
    if not ok then
        print(('[whip_core:container] ERROR loading containers: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    Containers.cache = {}
    Containers._keyIndex = {}

    --- One JSON column, guarded as the shop loader's are: a row that is not a JSON object (hand-edited, a cut-off write)
    --- is read as none and named, rather than stopping the load or breaking every move into it (audit 20, INV-2).
    local function jsonColumn(row, column)
        local raw = row[column]
        if type(raw) ~= 'string' or raw == '' or raw == 'null' then return nil end
        local okJson, v = pcall(json.decode, raw)
        if not okJson or type(v) ~= 'table' then
            print(('^3[whip_core:container] container %s ("%s"): its %s is not a JSON object, read as none^7')
                :format(tostring(row.containerId), tostring(row.name), column))
            return nil
        end
        return v
    end

    if rows then
        for _, row in ipairs(rows) do
            local allowed = jsonColumn(row, 'allowedItems')
            local declared = jsonColumn(row, 'declared')
            local requirements = jsonColumn(row, 'requirements')
            if row.key then Containers._keyIndex[row.key] = row.containerId end
            -- '' on disk is no prop at all (a property's stash: the furniture is what you see).
            ---@type string|false
            local prop = row.prop or Config.ContainerDefaultProp
            if prop == '' then prop = false end

            Containers.cache[row.containerId] = {
                containerId = row.containerId,
                name        = row.name,
                type        = row.type or 'stash',
                slots       = row.slots or Config.ContainerDefaultSlots,
                maxWeight   = row.maxWeight or Config.ContainerDefaultWeight,
                ownerCharId = row.ownerCharId,
                accessCharId = row.accessCharId,
                -- DbBool: the query path returns the TINYINT(1) column as a boolean.
                locked      = DbBool(row.locked),
                x           = row.x,
                y           = row.y,
                z           = row.z,
                heading     = row.heading or 0.0,
                prop        = prop,
                allowedItems = allowed,
                propertyId  = row.propertyId,
                createdAt   = EpochSeconds(row.createdAt),   -- seconds, like a container made this session
                createdBy   = row.createdBy,
                key         = row.key,
                declared    = declared,
                requirements = requirements,
            }
        end
    end

end

--- The rules a container may be given, for every refusal to name.
local CONTAINER_RULES = 'jobs, onDuty, charIds, items, ace, property'

--- A container's `requirements` — nil for none (`false`, `{}` or nothing), or false and why for a shape
--- that cannot be read. Refused where it is written, so a typo is an error at declaration rather than
--- a stash nobody can open.
---
--- Who may open it, any ONE of: a job (and on duty), named characters, an ACE, an item carried (a
--- keycard), or access to a property. The doors' shape (Doors.normaliseRequirements) reads jobs,
--- onDuty, charIds, items and ace; `property` is a container's own; `lockpick` is the doors' and is
--- refused here.
---
--- A required item never goes into the container that requires it, by any path (the container
--- kind's `allows`, stores.lua), so a keycard can't lock its holder out.
---@param req any
---@return table|nil|false req
---@return string|nil why
local function containerRequirements(req)
    if req == nil or req == false then return nil end
    if type(req) ~= 'table' then return false, 'requirements must be a table' end
    -- `lockpick` is the doors' own (a door that can be picked); on a stash it would lock it for all.
    if rawget(req, 'lockpick') ~= nil then
        return false, 'requirements.lockpick is for doors — a container takes ' .. CONTAINER_RULES
    end

    -- Access to a property: its owner and keyholders (Properties.hasAccess), named by propertyId or its
    -- key. It must exist when declared, so a mistyped key is an error rather than a stash for nobody.
    local property = rawget(req, 'property')
    local rest = req
    if property ~= nil then
        local rec
        if type(property) == 'string' and property ~= '' then
            rec = Properties.getByKey(property)
        elseif math.type(property) == 'integer' and property > 0 then
            rec = Properties.get(property)
        else
            return false, 'requirements.property is a propertyId or a property key'
        end
        if not rec then return false, ('requirements.property: there is no property "%s"'):format(tostring(property)) end
        rest = {}
        for k, v in pairs(req) do if k ~= 'property' then rest[k] = v end end
    end

    local out, why = Doors.normaliseRequirements(rest)
    if out == false then return false, why end
    out = out or {}
    if property ~= nil then out.property = property end
    if next(out) == nil then return nil end
    -- Through JSON, so a declaration compares equal to what the row gives back (EnsureContainer).
    return (json.decode(json.encode(out)))
end

-- The fields CreateContainer, EnsureContainer and UpdateContainer read: anything else is said in the console once.
local CONTAINER_FIELDS = {
    name = true, type = true, slots = true, maxWeight = true, x = true, y = true, z = true, heading = true,
    prop = true, locked = true, allowedItems = true, requirements = true, key = true, ownerCharId = true,
    accessCharId = true, propertyId = true, persist = true, tag = true, items = true, interior = true,
    placed = true, rx = true, ry = true, createdBy = true, declared = true,
}

--- A caller's container table, read at the export: `require` as requirements when it names one rule
--- (Doors.takeRequire), and a field no container reads said once, so `require` with two rules or a typo is never a
--- stash anyone can open without a word. The data to use, or false and why.
---@return table|false data
---@return string|nil why
local function readContainerData(data, owner, what)
    if type(data) ~= 'table' then return data end
    local taken, why = Doors.takeRequire(data, what)
    if not taken then return false, why end
    local warn = {}
    InteractSpec.unknown(taken, CONTAINER_FIELDS, '', warn)
    if #warn > 0 then InteractSpec.say('containers', owner, what, warn) end
    return taken
end

-- ============================================
-- Hooks: what happens to containers, for core code
-- ============================================

local hooks = {}   -- [kind] = { fn, ... }

--- Core code reacts to containers here, not on the public events: any resource can fire those (the
--- Npcs.onLife / Vehicles.onLife rule). Kinds:
---   'opened'  { containerId, source, charId }  the server opened it on someone's screen
--- A hook must not yield: it runs inside the open.
---@param kind string
---@param fn function
function Containers.onLife(kind, fn)
    if type(fn) ~= 'function' then return end
    hooks[kind] = hooks[kind] or {}
    table.insert(hooks[kind], fn)
end

--- Hooks first (each under pcall), then the public event, for listeners.
local function announce(kind, payload)
    for _, fn in ipairs(hooks[kind] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then print(('[whip_core:container] a %s hook failed: %s'):format(kind, tostring(err))) end
    end
    WhipEmit('whip_core:container:' .. kind, payload)
end

-- ============================================
-- Run containers (persist = false)
-- ============================================

--- A run container goes: the screens it is open on shut, what it held is written down as lost, and
--- every client is told. Never waits: it runs inside a registry release (a run's end, its owner
--- stopping), which must not yield. With no row there is nothing to delete.
---@param def table
---@param why string|nil  'released' | 'stopped' | 'removed'
local function destroyRuntime(def, why)
    local id = def.containerId
    if Containers.cache[id] ~= def then return end   -- already gone
    local storeId = 'container:' .. tostring(id)
    -- A copy of who has it open: the set is live, and forgetting the views empties it.
    local viewers = {}
    for src in pairs(Stores.viewersOf(storeId)) do viewers[#viewers + 1] = src end
    for _, src in ipairs(viewers) do TriggerClientEvent('whip_core:client:storeClosed', src, storeId) end
    Stores.forgetViews(storeId)
    for _, slotData in pairs(Containers.invCache[id] or {}) do
        if type(slotData) == 'table' and slotData.item then
            -- Against the admin who deleted it, when one did (as a stash's delete is).
            Log.item(def.removedBy, 'lost', slotData, { detail = ('run container %s gone (%s)'):format(def.name or ('#' .. id),
                def.goneWhy or why or 'removed') })
        end
    end
    -- Nothing of it is ever written (buildSaveQueries answers none), so nothing owed is lost here;
    -- the other end of a move into it writes itself.
    Stores.forget(storeId)
    Containers.cache[id] = nil
    Containers.invCache[id] = nil
    TriggerClientEvent('whip_core:client:containerDeleted', -1, id)
end

local runtimeReg = Registry.new('runtimeContainer', {
    label = 'container',
    scoped = true,
    releaseOrder = 40,   -- after a run's cars (30), before its zones (90)
    same = false,
    onRemove = function(_, def, _, why) destroyRuntime(def, why) end,
})

--- Written down before the server goes: memory dies with whip_core, so each run container is put away
--- the way a run's end does (its contents logged lost), on whip_core's stop (before step 60 sends the
--- owed log rows) and txAdmin's shutdown (before the final save). Never waits.
local function putAwayAllRuntime(why)
    local list = {}
    for _, def in pairs(Containers.cache) do
        if Containers.isRuntime(def) then list[#list + 1] = def end
    end
    for _, def in ipairs(list) do
        def.goneWhy = why
        local ok = runtimeReg:remove(def.owner, def.containerId)
        if not ok then destroyRuntime(def, why) end
    end
end
CoreStop.add(5, 'run containers: write down what they held', function() putAwayAllRuntime('whip_core stopping') end)
FinalSave.add(8, 'run containers: write down what they held', function(_, shutdown)
    -- Only when the server is really going (txAdmin kicking everyone), not a restart warning.
    if shutdown then putAwayAllRuntime('server stopping') end
end)

--- Make a run container: in memory, the caller's, under its tag. See RUNTIME_BASE at the top.
---@return table|nil def
---@return string|nil why
local function createRuntime(data, owner, requirements)
    if data.key ~= nil then return nil, 'a container with persist = false has no key: it is never saved' end
    if data.prop ~= nil and data.prop ~= false and (type(data.prop) ~= 'string' or data.prop == '') then
        return nil, 'prop is a model name, or false for no prop'
    end
    if data.items ~= nil and type(data.items) ~= 'table' then
        return nil, 'items is a list of { item = ..., amount = ..., metadata = ..., slot = ... }'
    end
    local slots = math.tointeger(tonumber(data.slots) or Config.ContainerDefaultSlots)
    if not slots or slots < 1 or slots > 65535 then return nil, 'slots must be a whole number, 1 or more' end
    local maxWeight = tonumber(data.maxWeight) or Config.ContainerDefaultWeight
    if not (maxWeight > 0) then return nil, 'maxWeight must be a number above 0' end

    nextRuntime = nextRuntime + 1
    local id = RUNTIME_BASE + nextRuntime
    local def = {
        containerId  = id,
        persist      = false,
        owner        = owner,
        tag          = data.tag,
        name         = data.name or 'Stash',
        type         = data.type or 'stash',
        slots        = slots,
        maxWeight    = maxWeight,
        ownerCharId  = data.ownerCharId,
        accessCharId = data.accessCharId,
        locked       = data.locked == true,
        x            = tonumber(data.x) + 0.0,
        y            = tonumber(data.y) + 0.0,
        z            = tonumber(data.z) + 0.0,
        heading      = tonumber(data.heading) or 0.0,
        prop         = (data.prop == nil) and Config.ContainerDefaultProp or data.prop,   -- false: no prop
        placed       = data.placed == true or nil,   -- exactly where given: no snap to the ground
        rx           = tonumber(data.rx),
        ry           = tonumber(data.ry),
        interior     = data.interior == true or nil, -- inside an MLO: its prop waits for the interior
        allowedItems = data.allowedItems,
        createdAt    = os.time(),
        requirements = requirements,
    }
    -- FIRST, so a run that has ended (a closed tag) is refused before anything exists.
    local ok, why = runtimeReg:add(owner, id, def, data.tag ~= nil and { tag = data.tag } or nil)
    if not ok then return nil, why --[[@as string]] end
    Containers.cache[id] = def
    Containers.invCache[id] = {}   -- known, and empty: there is nothing on disk to read

    -- What it holds from the start (the vault's money), each made as StoreGive makes an item. All or
    -- nothing: one that cannot go in takes the container back out. The maker is named in the reason
    -- (Stores.giveAt doesn't know it, and it is the part of a 'gained' row a caller can't choose:
    -- Log.reasonFrom), clipped first so the name isn't cut off. Stores.giveAt, not the StoreGive
    -- export: a self-export runs on a fresh coroutine no player action owns.
    local reason = Sanitize.string(type(data.reason) == 'string' and data.reason or '', 80, '')
    if reason == '' then reason = ('into %s'):format(def.name) end
    reason = reason .. ' · by ' .. owner
    for i, it in ipairs(data.items or {}) do
        local item = type(it) == 'table' and it.item or nil
        -- In the slot it names (the Director's Create Container lays them out), else wherever it goes.
        local at = type(it) == 'table' and math.tointeger(tonumber(it.slot)) or nil
        if at and (at < 1 or at > slots) then at = nil end
        local slot, gwhy = Stores.giveAt({ kind = 'container', id = id, slot = at }, item,
            type(it) == 'table' and it.amount or nil, type(it) == 'table' and it.metadata or nil,
            { reason = reason })
        if not slot then
            runtimeReg:remove(owner, id)
            return nil, ('items %d (%s): %s'):format(i, tostring(item), tostring(gwhy))
        end
    end

    TriggerClientEvent('whip_core:client:containerCreated', -1, Containers.wireOne(def))
    return def
end

-- ============================================
-- CRUD
-- ============================================

--- Make a container. A row, as every stash is, unless `data.persist == false` from a resource
--- (`owner`, its Registry.caller()): then a run container (see RUNTIME_BASE), which also takes
--- `tag`, `items` (what it holds from the start), `prop = false`, and `placed` with `rx` / `ry`.
---@param data table
---@param owner string|nil  the resource making it; nil for the admin screen (always a row)
function Containers.create(data, owner)
    if type(data) ~= 'table' then return nil, 'CreateContainer needs a data table' end
    -- Asked here rather than left to the NOT NULL columns, which answered a missing position with
    -- a bare 'Database error'.
    if not (tonumber(data.x) and tonumber(data.y) and tonumber(data.z)) then
        return nil, 'a container needs x, y and z'
    end
    if data.key ~= nil and Containers._keyIndex[data.key] then
        return nil, ('the key "%s" is already a container\'s'):format(tostring(data.key))
    end
    local requirements, reqWhy = containerRequirements(data.requirements)
    if requirements == false then return nil, reqWhy end

    if data.persist == false then
        if type(owner) ~= 'string' or owner == '' then
            return nil, 'only a resource can make a container that is not saved (persist = false)'
        end
        return createRuntime(data, owner, requirements)
    end

    local allowedJson = data.allowedItems and json.encode(data.allowedItems) or nil
    local declaredJson = data.declared and json.encode(data.declared) or nil
    local requirementsJson = requirements and json.encode(requirements) or nil
    -- `prop = false`: no prop of its own (a property's stash is a piece of its furniture). '' on disk.
    local prop = data.prop
    if prop == nil then prop = Config.ContainerDefaultProp end
    local propertyId = math.tointeger(tonumber(data.propertyId))

    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `containers` (`name`,`type`,`slots`,`maxWeight`,`ownerCharId`,`accessCharId`,`locked`,`x`,`y`,`z`,`heading`,`prop`,`allowedItems`,`createdBy`,`key`,`declared`,`requirements`,`propertyId`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        {
            data.name or 'Stash',
            data.type or 'stash',
            data.slots or Config.ContainerDefaultSlots,
            data.maxWeight or Config.ContainerDefaultWeight,
            data.ownerCharId or nil,
            data.accessCharId or nil,
            data.locked and 1 or 0,
            data.x, data.y, data.z,
            data.heading or 0.0,
            prop == false and '' or prop,
            allowedJson,
            data.createdBy or nil,
            data.key or nil,
            declaredJson,
            requirementsJson,
            propertyId,
        }
    )

    if not ok then
        print(('[whip_core:container] ERROR creating container: %s'):format(tostring(insertId)))
        return nil, DB_ERROR
    end

    local def = {
        containerId  = insertId,
        name         = data.name or 'Stash',
        type         = data.type or 'stash',
        slots        = data.slots or Config.ContainerDefaultSlots,
        maxWeight    = data.maxWeight or Config.ContainerDefaultWeight,
        ownerCharId  = data.ownerCharId,
        accessCharId = data.accessCharId,
        locked       = data.locked or false,
        x            = data.x,
        y            = data.y,
        z            = data.z,
        heading      = data.heading or 0.0,
        prop         = prop,
        allowedItems = data.allowedItems,
        createdAt    = os.time(),
        createdBy    = data.createdBy,
        key          = data.key,
        declared     = data.declared,
        requirements = requirements,
        propertyId   = propertyId,
    }

    Containers.cache[insertId] = def
    if def.key then Containers._keyIndex[def.key] = insertId end
    TriggerClientEvent('whip_core:client:containerCreated', -1, Containers.wireOne(def))

    return def
end

--- The fields Containers.update can change — the columns of its UPDATE, in one list, so the copy it
--- works on and the copy back cannot drift apart.
local UPDATABLE_FIELDS = {
    'name', 'type', 'slots', 'maxWeight', 'ownerCharId', 'accessCharId', 'locked',
    'x', 'y', 'z', 'heading', 'prop', 'allowedItems', 'key', 'declared', 'requirements',
}

--- The highest slot that holds something, loading the contents to find out. nil and why when they
--- cannot be read; `loadedHere` when this call pulled them into memory (the caller lets them go).
---@return number|nil highest
---@return string|boolean|nil whyOrLoadedHere
local function highestUsedSlot(containerId)
    local loadedHere = false
    if not Containers.invCache[containerId] then
        if not Containers.loadInventory(containerId) then
            return nil, 'Could not read what the container holds'
        end
        loadedHere = true
    end
    local highest = 0
    for slot, entry in pairs(Containers.invCache[containerId] or {}) do
        local n = tonumber(slot)
        if entry and n and n > highest then highest = n end
    end
    return highest, loadedHere
end

local function updateNow(containerId, data)
    local def = Containers.cache[containerId]
    if not def then return false, 'Container not found' end

    -- Row first, memory second, like Shops.update and Jobs.update: the changes are worked out on a
    -- copy, and the cache only takes them once the row has.
    local nextDef = {}
    for _, k in ipairs(UPDATABLE_FIELDS) do nextDef[k] = def[k] end

    -- Update fields that were provided
    if data.name        ~= nil then nextDef.name        = data.name end
    if data.type        ~= nil then nextDef.type        = data.type end
    if data.slots       ~= nil then nextDef.slots       = tonumber(data.slots) or def.slots end
    if data.maxWeight   ~= nil then nextDef.maxWeight   = tonumber(data.maxWeight) or def.maxWeight end
    if data.ownerCharId ~= nil then nextDef.ownerCharId = (tonumber(data.ownerCharId) or 0) > 0 and tonumber(data.ownerCharId) or nil end
    if data.accessCharId ~= nil then nextDef.accessCharId = (tonumber(data.accessCharId) or 0) > 0 and tonumber(data.accessCharId) or nil end
    if data.locked      ~= nil then nextDef.locked      = data.locked end
    if data.x           ~= nil then nextDef.x           = tonumber(data.x) or def.x end
    if data.y           ~= nil then nextDef.y           = tonumber(data.y) or def.y end
    if data.z           ~= nil then nextDef.z           = tonumber(data.z) or def.z end
    if data.heading     ~= nil then nextDef.heading     = tonumber(data.heading) or def.heading end
    if data.prop        ~= nil then nextDef.prop        = data.prop end
    if data.allowedItems ~= nil then
        -- Empty table/array means "clear" (allow all items). Empty is next() == nil, not # == 0: a
        -- keyed whitelist `{ evidence_bag = true }` has a length of 0.
        if type(data.allowedItems) == 'table' and next(data.allowedItems) == nil then
            nextDef.allowedItems = nil
        else
            nextDef.allowedItems = data.allowedItems
        end
    end
    -- The key it is declared by (EnsureContainer; `false` clears it), and that declaration.
    if data.key ~= nil and data.key ~= false and Containers.isRuntime(def) then
        return false, 'a container that is not saved has no key'
    end
    if data.key ~= nil then
        local holder = data.key and Containers._keyIndex[data.key]
        if holder and holder ~= containerId then
            return false, ('the key "%s" is already container #%d\'s'):format(tostring(data.key), holder)
        end
        nextDef.key = data.key or nil
    end
    if data.declared ~= nil then nextDef.declared = data.declared or nil end
    -- Who may open it. `false` or `{}` clears it; a shape doors could not read is
    -- refused with the reason, like at creation.
    if data.requirements ~= nil then
        local req, why = containerRequirements(data.requirements)
        if req == false then return false, why end
        nextDef.requirements = req
    end

    -- Fewer slots only over empty ones (an item above the new count would be unreachable). Shrunk in
    -- memory before the write, the one field that is: a drag during the UPDATE's wait could otherwise
    -- land above the new count. A failed write puts the old count back.
    local loadedHere = false
    local shrunkFrom = nil
    if nextDef.slots and def.slots and nextDef.slots < def.slots then
        local highest, whyOrLoaded = highestUsedSlot(containerId)
        if not highest then return false, whyOrLoaded end
        loadedHere = whyOrLoaded == true
        if highest > nextDef.slots then
            if loadedHere then pcall(Containers.unloadInventory, containerId) end
            return false, ('slot %d still holds something — empty the slots above %d first')
                :format(highest, nextDef.slots)
        end
        shrunkFrom = def.slots
        def.slots = nextDef.slots   -- no wait between the check and this
    end

    -- Not an item it already holds: a rule requiring an item the stash holds would shut it inside.
    -- Asked only when the rule changes.
    local wants = nextDef.requirements and nextDef.requirements.items
    if type(wants) == 'table' and not Registry.deepEquals(nextDef.requirements, def.requirements) then
        if not Containers.invCache[containerId] then
            if not Containers.loadInventory(containerId) then
                if shrunkFrom then def.slots = shrunkFrom end
                return false, 'Could not read what the container holds'
            end
            loadedHere = true
        end
        for _, slotData in pairs(Containers.invCache[containerId] or {}) do
            for _, need in ipairs(wants) do
                if type(slotData) == 'table' and type(need) == 'table' and slotData.item == need.key then
                    if shrunkFrom then def.slots = shrunkFrom end
                    if loadedHere then pcall(Containers.unloadInventory, containerId) end
                    return false, ('it holds %s, which it would then need to be opened: take it out first'):format(need.key)
                end
            end
        end
    end

    local allowedJson = nextDef.allowedItems and json.encode(nextDef.allowedItems) or nil
    local declaredJson = nextDef.declared and json.encode(nextDef.declared) or nil
    local requirementsJson = nextDef.requirements and json.encode(nextDef.requirements) or nil

    -- A run container has no row to write: the change is memory's alone.
    local ok, err = true, nil
    if not Containers.isRuntime(def) then
        ok, err = pcall(MySQL.query.await,
            'UPDATE `containers` SET `name`=?,`type`=?,`slots`=?,`maxWeight`=?,`ownerCharId`=?,`accessCharId`=?,`locked`=?,`x`=?,`y`=?,`z`=?,`heading`=?,`prop`=?,`allowedItems`=?,`key`=?,`declared`=?,`requirements`=? WHERE `containerId`=?',
            {
                nextDef.name, nextDef.type, nextDef.slots, nextDef.maxWeight,
                nextDef.ownerCharId, nextDef.accessCharId, nextDef.locked and 1 or 0,
                nextDef.x, nextDef.y, nextDef.z, nextDef.heading, nextDef.prop == false and '' or nextDef.prop, allowedJson,
                nextDef.key, declaredJson, requirementsJson,
                containerId,
            }
        )
    end

    if not ok then
        if shrunkFrom then def.slots = shrunkFrom end
        if loadedHere then pcall(Containers.unloadInventory, containerId) end
        print(('[whip_core:container] ERROR updating container #%d: %s'):format(containerId, tostring(err)))
        return false, DB_ERROR
    end
    -- Gone during the write (a run container's registry, or anything outside the turn): not made again.
    if Containers.cache[containerId] ~= def then
        if loadedHere then pcall(Containers.unloadInventory, containerId) end
        return false, 'Container not found'
    end

    -- The key index follows the row.
    if def.key ~= nextDef.key then
        if def.key and Containers._keyIndex[def.key] == containerId then Containers._keyIndex[def.key] = nil end
        if nextDef.key then Containers._keyIndex[nextDef.key] = containerId end
    end

    -- Onto the SAME table, not a replacement: stores, viewers and open sessions hold references to it.
    for _, k in ipairs(UPDATABLE_FIELDS) do def[k] = nextDef[k] end

    -- Contents read only to answer the slot question go again (if nobody has opened it since).
    if loadedHere then pcall(Containers.unloadInventory, containerId) end

    TriggerClientEvent('whip_core:client:containerUpdated', -1, Containers.wireOne(def))
    return true
end

local updating = {}   -- [containerId] = true while an update of that container is under way
local UPDATE_WAIT_MS = 5000

--- One change at a time per container (Shops.update's rule): an update writes EVERY column and waits on
--- the write, so two at once would overwrite each other. A second waits for the first (a few seconds at
--- most) and builds from what it left. A delete takes the same turn.
local function inContainerTurn(containerId, fn, ...)
    local deadline = GetGameTimer() + UPDATE_WAIT_MS
    while updating[containerId] do
        if GetGameTimer() > deadline then return false, 'that container is being changed — try again in a moment' end
        Wait(20)
    end
    updating[containerId] = true
    local ran, ok, why = pcall(fn, containerId, ...)
    updating[containerId] = nil
    if not ran then error(ok, 0) end
    return ok, why
end

--- Change a container, in its turn (above).
---@param containerId number
---@param data table
---@return boolean ok
---@return string|nil why
function Containers.update(containerId, data)
    return inContainerTurn(containerId, updateNow, data)
end

--- Delete a container (Containers.delete, below, runs it in the container's turn).
local function deleteNow(containerId, actorCharId)
    if not Containers.cache[containerId] then return false, 'Container not found' end

    -- A run container goes through its registry, which shuts its screens and writes its contents
    -- down as lost (destroyRuntime): there is no row to delete.
    local runDef = Containers.cache[containerId]
    if Containers.isRuntime(runDef) then
        runDef.removedBy = actorCharId
        local ok, why = runtimeReg:remove(runDef.owner, containerId)
        if not ok then return false, why end
        return true
    end

    -- Not while a shop sells from it: the shop would keep pointing at a shelf that no longer exists,
    -- and every open basket's goods would have nowhere to go back to. Unlink it in the shop first.
    if Shops and Shops.cache then
        for shopId, def in pairs(Shops.cache) do
            if def.containerId == containerId then
                return false, ('Shop #%d (%s) uses this container for its stock. Unlink it from the shop first.')
                    :format(shopId, tostring(def.name))
            end
        end
    end

    -- Owed writes land first and are forgotten only after the DELETE (as Vehicles.delete does):
    -- forgetting first would unlink a half-done move.
    local unit = 'container:' .. tostring(containerId)
    if not Stores.settle(unit) then
        print(('[whip_core:container] delete #%d refused: a write for it is still owed'):format(containerId))
        return false, 'Its contents could not be saved first. Try again in a moment.'
    end

    -- Delete the contents AND the prices WITH the definition, in one transaction, children first (the
    -- dependency order, rather than relying on the cascade mid-transaction).
    --
    -- What is in it is read first, so the loss is written down once the delete lands (every path that
    -- destroys items writes a lost row). If that read fails the delete still goes ahead, and the
    -- console says what was not logged.
    if not Containers.invCache[containerId] and not Containers.loadInventory(containerId) then
        print(('[whip_core:container] could not read stash #%d before deleting it — its contents are not in the activity log')
            :format(containerId))
    end
    local contents = Containers.invCache[containerId]

    local ok, err = Stores.runTransaction({
        { query = 'DELETE FROM `container_inventory` WHERE `containerId` = ?', values = { containerId } },
        { query = 'DELETE FROM `shop_item_prices` WHERE `containerId` = ?',    values = { containerId } },
        { query = 'DELETE FROM `containers` WHERE `containerId` = ?',          values = { containerId } },
    })

    if not ok then
        print(('[whip_core:container] ERROR deleting container #%d: %s'):format(containerId, tostring(err)))
        return false, DB_ERROR
    end

    -- Anything queued during the DELETE would write rows under a stash that is gone, so drop it.
    Stores.forget(unit)

    if type(contents) == 'table' then
        for _, slotData in pairs(contents) do
            if type(slotData) == 'table' and slotData.item then
                Log.item(actorCharId, 'lost', slotData, { detail = ('stash #%d deleted'):format(containerId) })
            end
        end
    end

    local key = Containers.cache[containerId] and Containers.cache[containerId].key   -- (the write yielded)
    if key and Containers._keyIndex[key] == containerId then Containers._keyIndex[key] = nil end
    Containers.cache[containerId] = nil
    Containers.invCache[containerId] = nil
    -- The container no longer exists, so nobody can be looking at it. Drops every viewer's
    -- membership, not just one — this is deletion, not a close.
    Stores.forgetViews('container:' .. tostring(containerId))
    if Shops and Shops.priceCache then Shops.priceCache[containerId] = nil end

    TriggerClientEvent('whip_core:client:containerDeleted', -1, containerId)
    return true
end

--- Delete a container: see deleteNow. In the container's turn, so an update in flight can't bring it back.
function Containers.delete(containerId, actorCharId)
    return inContainerTurn(containerId, deleteNow, actorCharId)
end

--- A deleted character's stashes go back to stock: what is in them stays, and they lose their owner and
--- their one-person lock (ownerCharId / accessCharId), as a house keeps its furniture when sold
--- (characters are soft-deleted, so the foreign keys don't fire). `locked` is an admin's setting and
--- stays. A hook the delete runs, not a handler on the public event.
Character.onLife('deleted', function(e)
    local charId = type(e) == 'table' and tonumber(e.charId) or nil
    if not charId then return end
    local ids = {}   -- first: each update below waits on the database
    for id, def in pairs(Containers.cache) do
        if def.ownerCharId == charId or def.accessCharId == charId then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do
        local def = Containers.cache[id]
        if def then
            local fields = {}
            if def.ownerCharId == charId then fields.ownerCharId = 0 end    -- 0 clears (Containers.update)
            if def.accessCharId == charId then fields.accessCharId = 0 end
            local ok, err = Containers.update(id, fields)
            if not ok then
                print(('[whip_core:container] deleted character %d still holds container #%d: %s')
                    :format(charId, id, tostring(err)))
            end
        end
    end
end)

-- ============================================
-- Cache Accessors
-- ============================================

function Containers.getAll()
    return Containers.cache
end

--- A container as its clients draw it: where it stands, what it looks like, whether it is locked.
---
--- This goes to every client, so not the owner and access charIds, who made it, its allowed items or
--- its key. client/containers.lua reads nothing else.
---@param def table
---@return table
function Containers.wireOne(def)
    local w = {
        containerId = def.containerId,
        name        = def.name,
        x = def.x, y = def.y, z = def.z,
        heading     = def.heading,
        prop        = def.prop,   -- false: no prop (a run container in a room that has its own safe)
        locked      = def.locked,
    }
    -- Exactly where it was put, tilted as given, rather than snapped to the ground (run containers).
    if def.placed then w.placed, w.rx, w.ry = true, def.rx, def.ry end
    -- Inside an interior (an MLO): its prop waits for the interior (client/containers.lua).
    if def.interior then w.interior = true end
    -- A property's stash: its prompt is for the people who live there (client/containers.lua), and it
    -- stands round the piece of furniture it is (client/property_objects.lua).
    if def.propertyId then w.property = def.propertyId end
    return w
end

--- Every container, projected (see wireOne). For the login sync.
---@return table<number, table>
function Containers.wireAll()
    local out = {}
    for id, def in pairs(Containers.cache) do out[id] = Containers.wireOne(def) end
    return out
end

function Containers.getDef(containerId)
    return Containers.cache[containerId]
end

---@param key string
---@return table|nil
function Containers.getByKey(key)
    local containerId = key ~= nil and Containers._keyIndex[key]
    return containerId and Containers.cache[containerId] or nil
end

-- ============================================
-- Declared by key (EnsureContainer)
-- ============================================

local CONTAINER_KEY_PATTERN = '^[%w_%-%.:]+$'

--- A declared number, to the millimetre — the zone rule (zones.lua `mm`): the declaration is read
--- back through JSON, and an unrounded float never equals itself again.
local function mm(n)
    n = tonumber(n)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.floor(n * 1000 + 0.5) / 1000
end

--- A container declaration as plain values — what is compared to tell whether a resource changed
--- its container. nil and why for one that cannot be a container.
---@return table|nil decl
---@return string|nil why
local function containerDeclaration(data)
    local d = {}
    for _, f in ipairs({ 'x', 'y', 'z', 'heading' }) do
        if data[f] ~= nil then
            d[f] = mm(data[f])
            if not d[f] then return nil, f .. ' must be a number' end
        end
    end
    if not (d.x and d.y and d.z) then return nil, 'a container needs x, y and z' end
    for _, f in ipairs({ 'name', 'type', 'prop' }) do
        if data[f] ~= nil then
            if type(data[f]) ~= 'string' or data[f] == '' then return nil, f .. ' must be text' end
            d[f] = data[f]
        end
    end
    if data.slots ~= nil then
        d.slots = math.tointeger(tonumber(data.slots))
        if not d.slots or d.slots < 1 then return nil, 'slots must be a whole number, 1 or more' end
    end
    if data.maxWeight ~= nil then
        d.maxWeight = mm(data.maxWeight)
        if not d.maxWeight or d.maxWeight <= 0 then return nil, 'maxWeight must be a number above 0' end
    end
    if data.locked ~= nil then d.locked = data.locked == true end
    if data.allowedItems ~= nil then
        if type(data.allowedItems) ~= 'table' then return nil, 'allowedItems must be a table' end
        -- Through JSON now, so it compares equal to what the row gives back. Empty is "anything",
        -- the same as not declaring it (Containers.update reads an empty whitelist that way too).
        local list = json.decode(json.encode(data.allowedItems)) or {}
        if next(list) ~= nil then d.allowedItems = list end
    end
    -- Who may open it, declared with it: a police locker is `requirements = { jobs =
    -- 'police', onDuty = true }` in the same call, not a lock plus an action plus an event plus a
    -- skipAccess open.
    if data.requirements ~= nil then
        local req, why = containerRequirements(data.requirements)
        if req == false then return nil, why end   -- (the reason already names requirements)
        d.requirements = req
    end
    return d
end

--- Find-or-create by key, declared in code (the EnsureShop / EnsureZone rule):
---   * a new key makes the container;
---   * the SAME declaration as last time changes nothing, so an admin's edits since then stand;
---   * a CHANGED declaration is applied — every field it names; an `allowedItems` or `requirements`
---     it stops declaring is cleared; fewer slots only over empty ones (Containers.update);
---   * a key another running resource declared is refused.
--- The job/duty/item rules (`requirements`) are declared; the one character it belongs to
--- (ownerCharId, accessCharId) is not: that is the game's to change.
---@param key string
---@param data table
---@param caller string|nil  the declaring resource
---@return table|nil def
---@return string|nil why
function Containers.ensure(key, data, caller)
    if type(key) ~= 'string' or #key > 100 or not key:match(CONTAINER_KEY_PATTERN) then
        return nil, 'a container key is letters, digits, _ - . and :, at most 100'
    end
    if type(data) ~= 'table' then return nil, 'EnsureContainer needs a data table' end
    local d, why = containerDeclaration(data)
    if not d then return nil, why end
    caller = caller or GetCurrentResourceName()
    local declared = { by = caller, decl = d }

    local existing = Containers.getByKey(key)
    if not existing then
        local fields = { key = key, declared = declared }
        for k, v in pairs(d) do fields[k] = v end
        return Containers.create(fields)
    end

    ---@type table|nil
    local ens = type(existing.declared) == 'table' and existing.declared or nil
    local by = ens and ens.by or nil
    if by and by ~= caller and Registry.alive(by) then
        return nil, ('container "%s" is declared by %s'):format(key, by)
    end
    if ens and by == caller and Registry.deepEquals(ens.decl, d) then return existing end

    local fields = { declared = declared }
    for k, v in pairs(d) do fields[k] = v end
    local before = ens and by and type(ens.decl) == 'table' and ens.decl or {}
    if d.allowedItems == nil and before.allowedItems ~= nil then fields.allowedItems = {} end
    if d.requirements == nil and before.requirements ~= nil then fields.requirements = false end

    local ok, err = Containers.update(existing.containerId, fields)
    if not ok then return nil, err end
    return Containers.cache[existing.containerId]
end

-- ============================================
-- Access Control
-- ============================================

--- A container's requirements: any ONE rule lets the player in — its jobs (on duty, with `onDuty`),
--- charIds, items carried or ace (the doors' own checks, Doors.requirementsMet), or access to its
--- `property` (owner or keyholder). A property that no longer exists lets nobody in by that rule.
---@param req table
---@return boolean ok
---@return string|nil why
local function requirementsMet(req, charId, source, player)
    local prop = req.property
    if prop == nil then return Doors.requirementsMet(source, player, req, 'container') end
    local rec
    if type(prop) == 'string' then rec = Properties.getByKey(prop) else rec = Properties.get(tonumber(prop)) end
    if rec and charId and Properties.hasAccess(rec.propertyId, charId) then return true end
    local rest = {}
    for k, v in pairs(req) do if k ~= 'property' then rest[k] = v end end
    if next(rest) == nil then return false, 'You do not have access to this property' end
    return Doors.requirementsMet(source, player, rest, 'container')
end

--- May this player open this container, and if not, why not.
---
---   locked         nobody (an admin opens it from the Container Manager; a resource with skipAccess)
---   accessCharId   that one character
---   requirements   any ONE of: its jobs (on duty, with `onDuty`), charIds, items carried, ace, or
---                  access to its property — see containerRequirements
--- Each field that is set must pass. `source` and `player` are needed for requirements: without
--- them a container that has any is refused (fail closed).
---@param containerId number
---@param charId number|nil
---@param source number|nil
---@param player table|nil
---@return boolean ok
---@return string|nil why
function Containers.canAccess(containerId, charId, source, player)
    local def = Containers.cache[containerId]
    if not def then return false, 'Container not found' end

    if def.locked then return false, 'This container is locked' end
    if def.accessCharId and def.accessCharId ~= charId then
        return false, 'You do not have access to this container'
    end
    if def.requirements then
        if not source then return false, 'You do not have access to this container' end
        local ok, why = requirementsMet(def.requirements, charId, source, player)
        if not ok then return false, why end
    end

    return true
end

--- Add this player to the container's viewer set. Several may share one: containers share ONE
--- invCache and Stores.move never yields, so concurrent moves resolve on their own (the loser of a
--- race finds the slot empty). Kept as tryOpen/false: callers branch on it, and a future cap (a till
--- only two staff may share) belongs behind this signature.
---@param containerId number
---@param source number
---@param anchor table|nil  { x, y, z, range } — the keep range; see Stores.viewerInRange
---@param override string|false|nil  what the open let this viewer past, which fromWire keeps honouring
---                        : false = nothing — an access-checked open (Containers.openFor),
---                        held to the container's lock and requirements on every move; 'access' (the
---                        default, for a caller that decided by its own rules — the shop's stock view,
---                        OpenStore's skipAccess) and 'admin' are not re-asked.
---@return boolean ok
function Containers.tryOpen(containerId, source, anchor, override)
    if override == nil then override = 'access' end
    Stores.addViewer(source, 'container:' .. tostring(containerId), nil, anchor, nil, override or nil)
    -- If the handler that added this viewer errors before the client ever hears about it, the
    -- framework removes it for us (secure.lua). A handler that returns normally keeps it —
    -- openContainer is meant to hold it until the client closes the container.
    TrackInvocationLock(function() Containers.release(containerId, source) end)
    return true
end

--- Remove this player from the container's viewer set. Other viewers are unaffected.
---@param containerId number
---@param source number
function Containers.release(containerId, source)
    Stores.removeViewer(source, 'container:' .. tostring(containerId))
end

-- ============================================
-- Container Inventory — On-demand Loading
-- ============================================

--- Load a container's contents into the cache.
---
--- On read failure the cache is left UNPOPULATED (nil) rather than set to {}.
--- An empty table means "loaded, and genuinely empty"; nil means "unknown". buildSaveQueries
--- emits `DELETE FROM container_inventory WHERE containerId = ?` for an empty table, so
--- caching {} after a failed read would wipe the stash on the next save.
---@param containerId number
---@return boolean loaded
function Containers.loadInventory(containerId)
    -- A run container's contents are only ever in memory: there is nothing to read.
    if Containers.isRuntime(Containers.cache[containerId]) then return Containers.invCache[containerId] ~= nil end

    local ok, rows

    -- Test seam — see server/testseams.lua. Inert unless Config.EnableTestSeams.
    if TestSeams and TestSeams.shouldFail('container_read') then
        ok, rows = false, 'injected fault: container_read'
    else
        ok, rows = pcall(MySQL.query.await,
            'SELECT * FROM `container_inventory` WHERE `containerId` = ?',
            { containerId }
        )
    end

    if not ok then
        print(('[whip_core:container] ERROR loading inventory for container #%d: %s'):format(containerId, tostring(rows)))
        return false
    end

    -- Another load may have finished while this one waited on the database, and moves may
    -- already have landed in its cache. Replacing it with these rows would undo them in memory
    -- while the other end of each move kept its half, so the cache that got here first wins.
    if Containers.invCache[containerId] then return true end

    local inv = {}
    if type(rows) == 'table' then
        for _, row in ipairs(rows) do
            -- type-checked: one hand-edited row must not make the stash unopenable
            local meta = Inventory.readMetadata(row.metadata,
                ('container #%s slot %s'):format(tostring(containerId), tostring(row.slot)))

            inv[row.slot] = {
                item     = row.item,
                amount   = row.amount or 1,
                metadata = meta,
            }
        end
    end

    Containers.invCache[containerId] = inv
    -- The rows just read are what is on disk: the save snapshot, so the first save is a diff. A cache
    -- is only ever dropped with nothing owed (unloadInventory), so a reload reads the last write.
    Containers.seedSnapshot(inv)
    -- Retired items (RetireItem) come out as it opens, logged, and the flush deletes their rows.
    RetiredItems.sweepStore(Stores.container(containerId))
    return true
end

-- Snapshots of the last CONFIRMED-WRITTEN contents, keyed on the cache table itself with
-- weak keys. Unloading a container clears Containers.invCache[id], which drops the last
-- reference and takes the snapshot with it — no cleanup code, and no chance of a stale
-- snapshot being matched to a container that has since been reloaded from disk.
--
-- See Inventory.buildSaveQueries; the same mechanism applied to a stash (a shop shelf can declare a
-- thousand slots).
local _containerSnapshots = setmetatable({}, { __mode = 'k' })

--- Record a cache just read from the database as written (see Containers.loadInventory).
---@param inv table
function Containers.seedSnapshot(inv)
    local snap = {}
    for slot, data in pairs(inv) do
        local slotNum = tonumber(slot)
        if data and data.item and slotNum then
            snap[slotNum] = { item = data.item, amount = data.amount or 1, metadata = Stores.copyMetadata(data.metadata) }
        end
    end
    _containerSnapshots[inv] = snap
end

--- Build SQL queries for saving a container's inventory.
---
--- Returns two values — see Inventory.buildSaveQueries. The second is a callback the COMMITTER must
--- call once the transaction is known to have gone through. A caller that ignores it writes everything
--- every time, which is safe.
---@param containerId number
---@return table[] queries
---@return function confirm  call ONLY after a verified commit
function Containers.buildSaveQueries(containerId)
    local inv = Containers.invCache[containerId]
    if not inv then return {}, function() end end
    -- A run container writes nothing, and says so with an empty list (not nil, which means "cannot be
    -- saved" and would fail the player's own save it is linked with): the session-car rule.
    if Containers.isRuntime(Containers.cache[containerId]) then return {}, function() end end

    local queries  = {}
    local values   = {}
    local prev     = _containerSnapshots[inv]
    local nextSnap = {}
    local present  = {}

    for slot, data in pairs(inv) do
        if data and data.item then
            -- `slot` is an unsigned integer column; out-of-range values are rejected by the
            -- DB under STRICT_TRANS_TABLES and would abort the whole transaction. Skip the
            -- row but keep it in the preserve-list rather than deleting what is on disk.
            local slotNum = tonumber(slot)
            if not slotNum or slotNum < 1 or slotNum > 65535 or slotNum % 1 ~= 0 then
                print(('[whip_core:container] SKIPPED out-of-range slot %s in container #%s')
                    :format(tostring(slot), tostring(containerId)))
            else
                present[slotNum] = true

                local prevSlot = prev and prev[slotNum]
                local unchanged = prevSlot
                    and prevSlot.item == data.item
                    and prevSlot.amount == (data.amount or 1)
                    and Stores.metadataEquivalent(prevSlot.metadata, data.metadata)

                -- Encoded FIRST and guarded: a row that cannot be written is skipped (it keeps its
                -- last saved state, and is present so the diff will not delete it) rather than
                -- failing the whole save and everything linked to it.
                local okMeta, metaJson = true, '{}'
                if not unchanged and data.metadata then okMeta, metaJson = pcall(json.encode, data.metadata) end

                if unchanged then
                    nextSnap[slotNum] = prevSlot
                elseif not okMeta then
                    nextSnap[slotNum] = prevSlot
                    print(('[whip_core:container] SKIPPED %s in slot %d of container %s — its metadata cannot be saved: %s')
                        :format(tostring(data.item), slotNum, tostring(containerId), tostring(metaJson)))
                else
                    nextSnap[slotNum] = {
                        item     = data.item,
                        amount   = data.amount or 1,
                        -- A copy: metadata is held by reference and mutated in place, so
                        -- storing the reference would compare a table against itself and
                        -- nothing would ever be written again.
                        metadata = Stores.copyMetadata(data.metadata),
                    }
                    values[#values + 1] = {
                        containerId, slotNum, data.item,
                        data.amount or 1,
                        metaJson,
                    }
                end
            end
        end
    end

    if #values > 0 then
        local placeholders = {}
        local params = {}
        for _, v in ipairs(values) do
            placeholders[#placeholders + 1] = '(?,?,?,?,?)'
            for _, p in ipairs(v) do params[#params + 1] = p end
        end
        -- An upsert, not REPLACE INTO (a delete and an insert) — see Inventory.buildSaveQueries.
        queries[#queries + 1] = {
            query = 'INSERT INTO `container_inventory` (`containerId`,`slot`,`item`,`amount`,`metadata`) VALUES '
                .. table.concat(placeholders, ', ')
                .. ' ON DUPLICATE KEY UPDATE `item` = VALUES(`item`), `amount` = VALUES(`amount`), `metadata` = VALUES(`metadata`)',
            values = params,
        }
    end

    if prev then
        -- Slots that WERE there and are not any more, deleted directly (smaller and safer than a
        -- NOT IN naming every survivor).
        local goneKeys, goneParams = {}, { containerId }
        for slotNum in pairs(prev) do
            if not present[slotNum] then
                goneKeys[#goneKeys + 1] = '?'
                goneParams[#goneParams + 1] = slotNum
            end
        end
        if #goneKeys > 0 then
            queries[#queries + 1] = {
                query = 'DELETE FROM `container_inventory` WHERE `containerId` = ? AND `slot` IN ('
                    .. table.concat(goneKeys, ', ') .. ')',
                values = goneParams,
            }
        end
    else
        -- First save for this cache: what is on disk is unknown, so write everything and prune
        -- anything else.
        local keepKeys, keepParams = {}, { containerId }
        for slotNum in pairs(present) do
            keepKeys[#keepKeys + 1] = '?'
            keepParams[#keepParams + 1] = slotNum
        end
        if #keepKeys > 0 then
            queries[#queries + 1] = {
                query = 'DELETE FROM `container_inventory` WHERE `containerId` = ? AND `slot` NOT IN ('
                    .. table.concat(keepKeys, ', ') .. ')',
                values = keepParams,
            }
        else
            queries[#queries + 1] = {
                query = 'DELETE FROM `container_inventory` WHERE `containerId` = ?',
                values = { containerId },
            }
        end
    end

    local deleteRows = 0
    for _, q in ipairs(queries) do
        if q.query:find('DELETE', 1, true) then
            deleteRows = deleteRows + math.max(0, #q.values - 1)
        end
    end
    local ifFull = 0
    for _ in pairs(present) do ifFull = ifFull + 1 end
    Stores.recordWrite(#values + deleteRows, ifFull)

    local function confirm()
        _containerSnapshots[inv] = nextSnap
    end

    return queries, confirm
end

--- Forget a container's save snapshot, forcing the next save to write everything.
---
--- Mirrors Inventory.invalidateSnapshot. Needed wherever a cache table is REUSED after the
--- rows beneath it changed outside the normal path — a raw DELETE in a test, or a test that
--- needs a genuine pending write without mutating any items.
---@param containerId number
function Containers.invalidateSnapshot(containerId)
    local inv = Containers.invCache[containerId]
    if inv then _containerSnapshots[inv] = nil end
end

--- Save container inventory to DB as an atomic transaction.
---@param containerId number
---@return boolean ok
---@return string|nil err
function Containers.saveInventory(containerId)
    -- "Contents were never loaded" is asked directly (an unchanged container builds no queries). A
    -- nil cache refuses: that is what stops a failed load from emptying a stash.
    if not Containers.invCache[containerId] then
        return false, 'contents not loaded'
    end
    if Containers.isRuntime(Containers.cache[containerId]) then return true end   -- nothing of it is saved

    -- Honour the kind's declared durability, but only AFTER the guard above. Deferring first
    -- would enqueue a container whose contents were never loaded, and the flush would then
    -- build a save from a cache that does not exist.
    local store = Stores.container(containerId)
    if store and Stores.isDeferred(store.kind) then
        Stores.markDirty(store)
        return true
    end

    local built, queries, confirm = pcall(Containers.buildSaveQueries, containerId)
    if not built then
        print(('[whip_core:container] ERROR building save for container #%s: %s')
            :format(tostring(containerId), tostring(queries)))
        return false, tostring(queries)
    end

    -- Nothing changed. That is a success.
    if #queries == 0 then
        return true
    end

    local ok, err = Stores.runTransaction(queries)
    if not ok then
        print(('[whip_core:container] ERROR saving container #%s: %s'):format(tostring(containerId), tostring(err)))
        return false, err
    end

    confirm()
    return true
end

--- Drop a container's contents from memory, writing anything still owed first.
---
--- The flush must happen before the drop: a dropped cache is unreachable (Stores.container() refuses
--- it, and its save snapshot goes with it), so an owed write would vanish without a trace. Refuses to
--- drop when the write fails: for a container nothing else holds the contents.
---@param containerId number
---@return boolean unloaded
function Containers.unloadInventory(containerId)
    -- Never a run container's: with no row, the cache is the only copy of what it holds, and dropping
    -- it would lose the lot. It goes when the container does (destroyRuntime). Every path that lets a
    -- stash go (the last close, a disconnect, CloseStore, the idle sweep) comes through here.
    if Containers.isRuntime(Containers.cache[containerId]) then return false end

    -- Never drop a cache somebody is still looking at: one person leaving a shared stash must not
    -- evict it from under everyone else.
    if Stores.viewerCount('container:' .. tostring(containerId)) > 0 then
        return false
    end

    -- A shop's shelf is in use while anyone is shopping (customers reach the stock through their shop
    -- session, not as viewers).
    if Shops and Shops.containerInUse and Shops.containerInUse(containerId) then
        return false
    end

    local store = Stores.container(containerId)
    if store then
        local ok, err = Stores.teardown(store)
        if not ok then
            print(('[whip_core:container] REFUSING to unload container #%s — its pending write failed: %s')
                :format(tostring(containerId), tostring(err)))
            return false
        end
    end

    -- Asked again, because teardown yields on the database: somebody who opened the container in
    -- that gap is using the cache this line would drop, and whatever they move would be written
    -- by nothing — a dropped cache builds no save queries. Somebody who opened, moved and CLOSED
    -- again in that gap has left no viewer behind but has left a change owed, so that is asked too.
    if Stores.viewerCount('container:' .. tostring(containerId)) > 0
        or Stores.owes('container:' .. tostring(containerId))
        or (Shops and Shops.containerInUse and Shops.containerInUse(containerId)) then
        return false
    end

    Containers.invCache[containerId] = nil
    return true
end

-- ============================================
-- Container Inventory — Slot Operations
-- ============================================

function Containers.getSlot(containerId, slot)
    local inv = Containers.invCache[containerId]
    if not inv then return nil end
    return inv[slot]
end

--- Write a slot. Refuses if the container's contents were never successfully loaded: a nil cache
--- means "contents unknown" and must never be written from (a one-entry cache would save as a delete
--- of every other slot).
---@return boolean written
function Containers.setSlot(containerId, slot, item, amount, metadata)
    if not Containers.invCache[containerId] then
        print(('[whip_core:container] REFUSED setSlot on container #%s slot %s — contents not loaded')
            :format(tostring(containerId), tostring(slot)))
        return false
    end
    Containers.invCache[containerId][slot] = {
        item     = item,
        amount   = amount or 1,
        metadata = metadata,
    }
    return true
end

function Containers.clearSlot(containerId, slot)
    if Containers.invCache[containerId] then
        Containers.invCache[containerId][slot] = nil
    end
end

--- The weight shown for a stash: THE SAME answer the movers use (Stores.weightOf, contents of bags
--- and loaded guns included).
function Containers.getWeight(containerId)
    local store = Stores.container(containerId)
    return store and Stores.weightOf(store) or 0
end

--- Serialize inventory for NUI (string keys)
function Containers.serializeInventory(containerId)
    local inv = Containers.invCache[containerId]
    if not inv then return {} end
    local result = {}
    for slot, data in pairs(inv) do
        result[tostring(slot)] = {
            item     = data.item,
            amount   = data.amount,
            metadata = data.metadata,
        }
    end
    return result
end

--- Serialize definition for NUI (safe subset)
function Containers.serializeDef(containerId)
    local def = Containers.cache[containerId]
    if not def then return nil end
    return {
        containerId  = def.containerId,
        name         = def.name,
        type         = def.type,
        slots        = def.slots,
        maxWeight    = def.maxWeight,
        locked       = def.locked,
        allowedItems = def.allowedItems,
    }
end

-- ============================================
-- Opening
-- ============================================

--- Open a container for a player.
---
--- One implementation, two callers: the player pressing E (events_containers.lua) and the OpenStore
--- export (server/stores.lua), so a satellite opening a container it owns (a heist stash, a keycard
--- locker) gets access, distance, locking and the payload right.
---
--- Returns a reason rather than messaging the player, so the caller decides how a refusal is
--- presented. The event handler turns it into the errors players already see.
---
---@param source number
---@param player table
---@param containerId number
---@param opts table|nil { skipDistance?: boolean, skipAccess?: boolean }
---@return boolean ok
---@return string|nil reason
function Containers.openFor(source, player, containerId, opts)
    opts = opts or {}

    if not player or not player.inventory then return false, 'Not loaded' end

    local def = Containers.getDef(containerId)
    if not def then return false, 'Container not found' end

    -- Access control. skipAccess is for the resource that OWNS the container and has decided by its own
    -- rules (a keycard, a lockpick, a job). Access is not being a viewer: having it open right now is
    -- what authorises a drag.
    if not opts.skipAccess then
        local allowed, why = Containers.canAccess(containerId, player.charId, source, player)
        if not allowed then return false, why or 'You do not have access to this container' end
    end

    -- Distance check. Skippable because a script-driven open is not always the player walking
    -- up to a prop, and because the caller has already decided the open is legitimate.
    -- IsPlayerNear, which also refuses a missing ped and a player still in the character creator.
    if not opts.skipDistance then
        local range = Config.ContainerInteractRange + 2.0
        if not (def.x and IsPlayerNear(source, def.x, def.y, def.z, range)) then
            return false, 'Too far away'
        end
    end

    -- Join the container's viewer set (shared: see Containers.tryOpen).
    --
    -- The anchor is the keep range: a distance-checked open stays usable only while the player stays
    -- near it (Stores.viewerInRange, on every move). Twice the open range, so shuffling at the stash
    -- never refuses anything; walking off does.
    local anchor = nil
    if not opts.skipDistance then
        anchor = { x = def.x, y = def.y, z = def.z, range = (Config.ContainerInteractRange + 2.0) * 2 }
    end
    -- And the access is held, like the distance: an open that asked canAccess keeps being asked on
    -- every move (Stores.fromWire), so a stash locked or re-assigned while open, or an officer going
    -- off duty at the locker, stops the looting there. skipAccess was the caller's decision, and
    -- stays one.
    if not Containers.tryOpen(containerId, source, anchor, opts.skipAccess and 'access' or false) then
        return false, 'Someone else is using this container'
    end

    -- Load inventory on-demand. If the read fails we must NOT open — the client would be
    -- shown an empty stash and any move from it would be evaluated against unknown contents.
    if not Containers.invCache[containerId] then
        if not Containers.loadInventory(containerId) then
            Containers.release(containerId, source)
            return false, 'Could not read this container'
        end
    end

    -- Build payload: player inventory + container definition + container inventory
    local payload = Inventory.buildPayload(player)
    payload.containerId     = containerId
    payload.containerDef    = Containers.serializeDef(containerId)
    payload.containerInv    = Containers.serializeInventory(containerId)
    payload.containerWeight = Containers.getWeight(containerId)
    -- The id the delta protocol is keyed on. Without it the client receives updates caused by
    -- other viewers and has no way to tell which of its open grids they belong to.
    payload.storeId         = 'container:' .. tostring(containerId)
    TriggerClientEvent('whip_core:client:openContainer', source, payload)

    -- Opened by the server, however it was asked (E, OpenStore). Their
    -- game may still decline the screen; this is the server's word that it was opened for them.
    announce('opened', { containerId = containerId, source = source, charId = player.charId })
    return true
end

-- ============================================
-- Public Exports
-- ============================================

-- To open or close a stash from code: OpenStore and CloseStore (stores.lua) with
-- `{ kind = 'container', id = id }`, through Containers.openFor as the player's own open is.

--- A run container (persist = false) is its owner's alone to change or delete.
---@return string|nil why
local function notYours(containerId, caller)
    local def = Containers.cache[containerId]
    if Containers.isRuntime(def) and def.owner ~= caller then
        return ('container #%d is %s\'s'):format(containerId, tostring(def.owner))
    end
    return nil
end

--- Change a container's definition after it has been created (who may open it, a transferred stash, a
--- job handover). Fields absent from `data` are left alone.
---@param containerId number
---@param data table { name?, type?, slots?, maxWeight?, ownerCharId?, accessCharId?, locked?, x?, y?, z?, heading?, prop?, allowedItems? }
---@return boolean ok
---@return string|nil err
exports('UpdateContainer', function(containerId, data)
    local caller = Registry.caller()   -- first, before anything can yield
    local id = Sanitize.id(containerId)
    if not id then return false, 'a container id is a whole number' end
    containerId = id
    if type(data) ~= 'table' then return false, 'data must be a table of the fields to change' end
    local theirs = notYours(containerId, caller)
    if theirs then return false, theirs end
    local read, readWhy = readContainerData(data, caller, ('container %d'):format(containerId))
    if not read then return false, readWhy end
    data = read
    local key = data.key
    if key ~= nil and key ~= false
        and (type(key) ~= 'string' or #key > 100 or not key:match(CONTAINER_KEY_PATTERN)) then
        return false, 'a container key is letters, digits, _ - . and :, at most 100 (false removes it)'
    end
    -- `declared` is EnsureContainer's own record; a caller does not write it.
    local fields = {}
    for k, v in pairs(data) do if k ~= 'declared' then fields[k] = v end end
    local ok, err = Containers.update(containerId, fields)
    if not ok then return false, err or 'Could not update the container' end
    return true
end)

--- Create a container.
---
--- `false`, not nil, on failure: an export's return list is cut at the first nil.
---
--- `persist = false` makes one that is NEVER SAVED, yours, gone when you stop or when its `tag` is
--- released (ReleaseTag), with `items` it holds from the start — a heist's safe:
---
---     local safe = exports.whip_core:CreateContainer({ persist = false, tag = 'heist:1', name = 'Safe',
---         x = 255.1, y = 225.4, z = 101.9, prop = false, items = { { item = 'cash', amount = 5000 } },
---         requirements = { charIds = { 41, 52 } } })
---@return table|false container
---@return string|nil err
exports('CreateContainer', function(data)
    local caller = Registry.caller()   -- first, before anything can yield
    local readWhy
    data, readWhy = readContainerData(data, caller, 'CreateContainer')
    if data == false then return false, readWhy end
    local container, err = Containers.create(data, caller)
    if not container then return false, err or 'Could not create the container' end
    return container
end)

--- Delete a container and everything in it. Answers `true` or `false, reason` — refused while a
--- shop sells from it. A container made with persist = false only by the resource that made it.
---@param containerId number
---@return boolean ok
---@return string|nil err
exports('DeleteContainer', function(containerId)
    local caller = Registry.caller()   -- first, before anything can yield
    local id = Sanitize.id(containerId)
    if not id then return false, 'a container id is a whole number' end
    containerId = id
    local theirs = notYours(containerId, caller)
    if theirs then return false, theirs end
    local ok, err = Containers.delete(containerId)
    if not ok then return false, err or 'Could not delete the container' end
    return true
end)

--- What a container IS — its name, size, position, owner — by its id or a reference: `{ id = }`, or
--- `{ key = }` (EnsureContainer's). nil when there is none. What it HOLDS is StoreRead:
--- `StoreRead({ kind = 'container', id = containerId })`.
---@param ref number|table|nil
---@return table|nil
exports('GetContainer', function(ref)
    if type(ref) ~= 'table' then return Containers.getDef(Sanitize.id(ref)) end
    if ref.id ~= nil then return Containers.getDef(Sanitize.id(ref.id)) end
    if ref.key ~= nil then return type(ref.key) == 'string' and Containers.getByKey(ref.key) or nil end
    return nil
end)

--- A container declared by key — the EnsureShop / EnsureZone rule. Put it in Whip.register: the first
--- call makes it, later calls find it (and follow your code if you changed the declaration). See
--- Containers.ensure. Called while whip_core is still starting, it waits for it (up to 60 s).
---
---     local locker = exports.whip_core:EnsureContainer('pd:weapon_locker', {
---         name = 'Weapon Locker', slots = 50, maxWeight = 200.0,
---         x = 441.2, y = -996.8, z = 30.7, heading = 90.0,
---         allowedItems = { gunny_pistol = true, gunny_mag_pistol = true },
---     })
---@param key string
---@param data table
---@return table|false container
---@return string|nil why
exports('EnsureContainer', function(key, data)
    local caller = Registry.caller()   -- first, before anything can yield
    local read, readWhy = readContainerData(data, caller, ('container "%s"'):format(tostring(key)))
    if read == false then
        Registry.sayRefused(caller, readWhy)
        return false, readWhy
    end
    data = read
    if not WaitForCoreReady() then return false, NOT_READY end
    local def, why = Containers.ensure(key, data, caller)
    if not def then
        why = why or 'Could not create the container'
        Registry.sayRefused(caller, ('EnsureContainer("%s"): %s'):format(tostring(key), why))
        return false, why
    end
    return def
end)
