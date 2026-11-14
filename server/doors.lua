-- ============================================
-- Door System — Server
-- Server-authoritative door state management.
-- DB persistence, requirement checks, linked doors.
-- ============================================

Doors = {}

local doorCache = {}  -- [doorId] = door data

--- The autolock timer generation per door: [doorId] = number.
---
--- SetTimeout can't be cancelled, so every state change bumps the door's number; a timer whose
--- captured number no longer matches has been superseded and does nothing. Kept out of the door
--- record (which goes to the Door Manager).
local autolockToken = {}

-- ============================================
-- Held doors: a run's, in memory only
-- ============================================
--
-- A run (or any resource) can hold a door while it needs it (the vault door through a heist): any
-- door, saved or not; the holder decides who may press it (nobody until it says); it never relocks
-- by itself while held; when the hold ends it goes back to the lock it had. Lockpicking stays as
-- the door's own row says.
--
--   a saved door        held as it is, both leaves of a pair. Nothing is written to its row: the
--                       hold lives in memory, so a crash or a txAdmin restart leaves no trace (every
--                       door boots locked anyway). A property's or a resource's door is never held.
--   no door there       a TEMPORARY door is made, in memory only, with an id above 2^32 (never a
--                       row's); every client gets it like any other door, and it goes with the hold.
--                       No path that writes a row will take it (writeDoor, delete, link, unlink).
--
-- The hold's `requirements` decide who may press it (Doors.isAuthorizedWithReason), in a door's
-- shape. Holds join tag releases (ReleaseTag) and their owner's stop, through a registry.
local RUNTIME_BASE = 4294967296   -- 2^32
local nextRuntime = 0
local _holds = {}   -- [doorId] = hold record; both leaves of a held pair point at the same one
--- [doorId] = the autolock token its pending relock captured (scheduleAutolock). A relock is pending
--- while it still equals autolockToken[doorId]: no change to the door since it was armed.
local armedToken = {}
--- [doorId] = true while adoptOrCreate writes a door it is taking over (a property, EnsureDoors): the
--- write waits on the database, and a hold must not slip in between and make it both.
local _adopting = {}

--- A temporary door (made for a hold, never saved)?
---@param doorId any
---@return boolean
local function isRuntime(doorId) return type(doorId) == 'number' and doorId >= RUNTIME_BASE end
Doors.isRuntime = isRuntime

-- ============================================
-- Hooks: what happens to doors, for core code
-- ============================================

local hooks = {}   -- [kind] = { fn, ... }

--- Core code reacts to doors here, not on the public events: any resource can fire those (the
--- Npcs.onLife / Vehicles.onLife rule). Kinds:
---   'lockChanged'  { doorId, locked, source, cause }  only when the state really changed; cause is
---                  'press' | 'lockpick' | 'autolock' | 'code' | 'released' (a hold ended) | the caller's
---   'denied'       { doorId, source, reason }         a press refused (the reason is the player's own)
--- A hook must not yield: it runs inside the change.
---@param kind string
---@param fn function
function Doors.onLife(kind, fn)
    if type(fn) ~= 'function' then return end
    hooks[kind] = hooks[kind] or {}
    table.insert(hooks[kind], fn)
end

--- Hooks first (each under pcall), then the public event, for listeners.
local function announce(kind, payload)
    for _, fn in ipairs(hooks[kind] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then print(('[whip_core:doors] a %s hook failed: %s'):format(kind, tostring(err))) end
    end
    WhipEmit('whip_core:door:' .. kind, payload)
end

-- ============================================
-- Door-by-cell index
-- ============================================
--
-- The inverse of PlayersNearPoint: "which doors sit in these cells". Near players hear a toggle as
-- it happens; a player entering a cell is handed the current state of every door in it
-- (events_inventory.lua's sweep); nobody ever asks.
--
-- Keyed by the ground items' grid (GroundItems.cellKey), which the sweep speaks. Positions are
-- immutable (moving a door is delete-and-recreate), so each door is bucketed once.

local doorCells  = {}   -- [cellKey] = { [doorId] = true }
local doorCellOf = {}   -- [doorId]  = cellKey

local function cellInsert(door)
    -- A door with no position cannot be bucketed — the same doors updateState broadcasts to -1.
    if not (door.x and door.y) then return end
    local key = GroundItems.cellKey(door.x, door.y)
    if not doorCells[key] then doorCells[key] = {} end
    doorCells[key][door.doorId] = true
    doorCellOf[door.doorId] = key
end

local function cellRemove(doorId)
    local key = doorCellOf[doorId]
    if not key then return end
    doorCellOf[doorId] = nil
    local bucket = doorCells[key]
    if bucket then
        bucket[doorId] = nil
        if next(bucket) == nil then doorCells[key] = nil end
    end
end

--- The doors in the cells around a spot, for "is there a door right here" (create's duplicate
--- check, adoptOrCreate's) without walking every door. Cells are tens of metres, the question half
--- a metre, so the 3x3 block holds every answer.
---@return table[] doors
local function doorsAround(x, y)
    local out = {}
    local cs = Config.GroundItemCellSize or 50   -- the grid GroundItems.cellKey cuts
    for ox = -1, 1 do
        for oy = -1, 1 do
            local bucket = doorCells[GroundItems.cellKey(x + ox * cs, y + oy * cs)]
            if bucket then
                for doorId in pairs(bucket) do
                    local d = doorCache[doorId]
                    if d then out[#out + 1] = d end
                end
            end
        end
    end
    return out
end

--- Current lock state of every door in the given cells — the cell-entry catch-up payload.
---@param cellKeys table  a SET of cell keys ({ [key] = true }), the shape the ground sweep holds
---@return table[]  array of { doorId, locked }
function Doors.getStatesInCells(cellKeys)
    local out = {}
    for key in pairs(cellKeys) do
        local bucket = doorCells[key]
        if bucket then
            for doorId in pairs(bucket) do
                local door = doorCache[doorId]
                if door then
                    out[#out + 1] = { doorId = doorId, locked = door.locked }
                end
            end
        end
    end
    return out
end

--- The fields Doors.update accepts.
---
--- Position, model and heading are absent on purpose: set once at creation (moving a door means
--- deleting it and placing a new one). `locked` goes through the lock path (Doors.setLocked: the
--- linked twin and the announcement), not the row.
local DOOR_UPDATABLE = {
    label         = true,
    folder        = true,
    locked        = true,
    autolock      = true,
    autolockDelay = true,
    linkedDoorId  = true,
    requirements  = true,
    metadata      = true,
}

-- ============================================
-- Managed doors
-- ============================================
--
-- A door can BELONG to a system that sets its access for it. A property's front door is the
-- first: who may open it is the property's owner and keyholders, and the property writes that
-- list, not an admin. Such a door carries
--
--     metadata.managedBy = { system, id, key, label, created | adopted, prev }
--
--   system   who manages it: a plain word inside whip_core ('property'), 'resource:<name>' for a
--            satellite. The exports stamp that from the caller, so no resource speaks for another.
--   id       which of that system's things: property #12
--   key      the door's name within it: 'entrance', 'garage'
--   label    what the Door Manager shows: "Property #12 · Mega A 3-1"
--   created  whip made this door for its manager, and deletes it on release
--   adopted  the door was there first; `prev` holds what it was, and release puts that back
--
-- The manager owns a door's requirements, link, autolock and metadata; anyone else is refused (the
-- manager would write its own value back at its next reconcile). Label and folder stay open to all.
--
-- A manager that stops keeps its doors (rows it reconciles at its next start: a restart must not
-- delete a building's front doors). The Door Manager offers Release on a door whose resource is
-- no longer running.

--- The fields only a door's manager may change.
local MANAGED_FIELDS = {
    requirements  = true,
    linkedDoorId  = true,
    metadata      = true,
    autolock      = true,
    autolockDelay = true,
}

--- Who manages this door, or nil.
---@param door table|nil
---@return table|nil managedBy
local function managerOf(door)
    local meta = door and door.metadata
    local mb = type(meta) == 'table' and meta.managedBy or nil
    return type(mb) == 'table' and mb or nil
end
Doors.managerOf = managerOf

--- The same system and the same thing within it. The key is not part of it: every door of
--- property #12 has the same manager.
local function sameManager(a, b)
    return type(a) == 'table' and type(b) == 'table'
        and a.system ~= nil and a.system == b.system and tostring(a.id) == tostring(b.id)
end

local function managerName(mb)
    return mb.label or ('%s #%s'):format(tostring(mb.system), tostring(mb.id))
end

--- May `manager` change this door's managed fields? A door nobody manages is anybody's.
---@param door table
---@param manager table|nil  nil for an admin or an ordinary caller
---@return boolean ok, string|nil why
local function checkManager(door, manager)
    local mb = managerOf(door)
    if not mb or sameManager(mb, manager) then return true end
    -- A resource's door says where it changes: its EnsureDoors list, or the manager that holds it
    -- (nothing on the door says which).
    if type(mb.system) == 'string' and mb.system:sub(1, 9) == 'resource:' then
        return false, ('Door #%s belongs to %s. Change it in its EnsureDoors list, or through the manager that holds it')
            :format(tostring(door.doorId), managerName(mb))
    end
    return false, ('Door #%s belongs to %s — change it there'):format(tostring(door.doorId), managerName(mb))
end

local function shallowCopy(t)
    local out = {}
    if type(t) == 'table' then for k, v in pairs(t) do out[k] = v end end
    return out
end

-- ============================================
-- Database
-- ============================================

---@return boolean ok
function Doors.ensureTable()
    return CreateTable('doors', [[
        CREATE TABLE IF NOT EXISTS `doors` (
            `doorId`         INT UNSIGNED    NOT NULL AUTO_INCREMENT,
            `label`          VARCHAR(100)    NOT NULL DEFAULT 'Door',
            `folder`         VARCHAR(100)    DEFAULT NULL,
            `model`          BIGINT          NOT NULL,
            `x`              FLOAT           NOT NULL,
            `y`              FLOAT           NOT NULL,
            `z`              FLOAT           NOT NULL,
            `heading`        FLOAT           NOT NULL DEFAULT 0,
            `locked`         TINYINT(1)      NOT NULL DEFAULT 1,
            `defaultLocked`  TINYINT(1)      NOT NULL DEFAULT 1,
            `autolock`       TINYINT(1)      NOT NULL DEFAULT 0,
            `autolockDelay`  INT UNSIGNED    NOT NULL DEFAULT 10,
            `linkedDoorId`   INT UNSIGNED    DEFAULT NULL,
            `requirements`   JSON            DEFAULT NULL,
            `metadata`       JSON            DEFAULT NULL,
            `createdAt`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy`      INT UNSIGNED    DEFAULT NULL,
            PRIMARY KEY (`doorId`),
            INDEX `idx_door_pos` (`x`, `y`, `z`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

--- Turn a database row into the door record the cache holds.
---
--- Every door starts locked on every start, so lock state is never read from the database (the
--- `locked` and `defaultLocked` columns are unread) and Doors.updateState never writes it.
local function rowToDoor(row)
    local door = {
        doorId        = row.doorId,
        label         = row.label or 'Door',
        folder        = row.folder,
        -- Signed, whatever the row holds: a door saved from an unsigned number before Doors.create
        -- normalised it would otherwise never match its own object (see Doors.create).
        model         = PropertyMath.signedHash(row.model) or row.model,
        x             = row.x,
        y             = row.y,
        z             = row.z,
        heading       = row.heading or 0,
        locked        = true,   -- every door starts locked; see above
        autolock      = row.autolock == 1 or row.autolock == true,
        autolockDelay = tonumber(row.autolockDelay) or 10,
        linkedDoorId  = row.linkedDoorId,
        requirements  = nil,
        metadata      = nil,
    }
    if row.requirements then
        local ok, req = pcall(json.decode, row.requirements)
        door.requirements = ok and req or nil
    end
    if row.metadata then
        local ok, meta = pcall(json.decode, row.metadata)
        door.metadata = ok and meta or nil
    end
    return door
end

function Doors.loadAll()
    Doors.ensureTable()
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `doors`')
    if not ok or not rows then
        -- Said, and start-up halts: an empty door cache would make the property reconcile create a
        -- second row for every property door.
        print(('[whip_core:doors] ERROR loading doors: %s'):format(tostring(rows)))
        return false
    end
    for _, row in ipairs(rows) do
        local door = rowToDoor(row)
        doorCache[door.doorId] = door
        cellInsert(door)
    end
end

-- ============================================
-- Requirements — one shape
-- ============================================

--- One shape for a door's requirements, whichever spelling they arrive in (the door's, or AddAction
--- and the interaction points'). Anything else is refused with the reason, where the door is written.
---   jobs / job        a job key, or a list of them
---   charIds / charId  a character id, or a list (an EMPTY list is "nobody": a vacant property)
---   items / item      an item key, { key = 'x' } / { item = 'x' }, or a list of those
---   ace               an ACE string
---   onDuty, lockpick  kept only when true; onDuty with no jobs is "on duty at any job"
---@param req any
---@return table|nil|false req  nil = none, false = refused
---@return string|nil why
local function normaliseRequirements(req)
    if req == nil then return nil end
    if type(req) ~= 'table' then return false, 'requirements must be a table' end
    local function list(v) if type(v) == 'table' then return v end return { v } end
    local out = {}
    for k, v in pairs(req) do
        if k == 'jobs' or k == 'job' then
            out.jobs = out.jobs or {}
            for _, j in ipairs(list(v)) do
                if type(j) ~= 'string' or j == '' then return false, 'requirements.jobs: a job is named by its key' end
                out.jobs[#out.jobs + 1] = j
            end
        elseif k == 'charIds' or k == 'charId' then
            out.charIds = out.charIds or {}
            for _, c in ipairs(list(v)) do
                local id = tonumber(c)
                if not id then return false, 'requirements.charIds: a character is named by its id' end
                out.charIds[#out.charIds + 1] = id
            end
        elseif k == 'items' or k == 'item' then
            out.items = out.items or {}
            -- One { key = } / { item = } table is ONE item, not a list of them.
            local entries = (type(v) == 'table' and (rawget(v, 'key') or rawget(v, 'item'))) and { v } or list(v)
            for _, it in ipairs(entries) do
                local key = type(it) == 'string' and it or (type(it) == 'table' and (it.key or it.item)) or nil
                if type(key) ~= 'string' or key == '' then
                    return false, 'requirements.items: each is an item key, or { key = ... }'
                end
                -- The count is kept: `{ item = 'lockpick', count = 2 }`.
                local count = type(it) == 'table' and it.count or nil
                if count ~= nil then
                    count = tonumber(count)
                    if not count or count < 1 or count ~= math.floor(count) then
                        return false, ('requirements.items: "%s" count must be a whole number of 1 or more'):format(key)
                    end
                    if count == 1 then count = nil end
                end
                out.items[#out.items + 1] = { key = key, count = count }
            end
        elseif k == 'ace' then
            if v ~= '' then
                if type(v) ~= 'string' then return false, 'requirements.ace is an ACE string' end
                out.ace = v
            end
        elseif k == 'onDuty' or k == 'lockpick' then
            -- Only when true: a `false` would make the requirements non-empty (locked to everyone).
            if v == true then out[k] = true end
        else
            return false, ('requirements: "%s" is not a door requirement — jobs, charIds, items, ace, onDuty, lockpick')
                :format(tostring(k))
        end
    end
    -- An empty job list names no job; it is no requirement (an empty charIds list is "nobody", kept).
    if out.jobs and #out.jobs == 0 then out.jobs = nil end
    return out
end
Doors.normaliseRequirements = normaliseRequirements

--- `require`, the word actions and points use, given to a door or a stash in place of `requirements`. Taken when
--- it names ONE rule (a job, with onDuty or not; characters; one item; an ace), which means the same either way.
--- Refused when it names more: an action's `require` needs ALL its rules, a door's `requirements` lets in anyone
--- who meets ANY ONE, so { job, item } would let in either. Answers the data to use (a copy, `requirements` set
--- from `require`, when it was given), or false and why.
---@param data table
---@param what string  'door "office"', 'container "mycafe:locker"': how a refusal names it
---@return table|false data
---@return string|nil why
function Doors.takeRequire(data, what)
    if type(data) ~= 'table' or data.require == nil then return data end
    if data.requirements ~= nil then
        return false, ('%s: give requirements or require, not both'):format(what)
    end
    local req = data.require
    if type(req) ~= 'table' then return false, ('%s: require must be a table'):format(what) end
    local rules = 0
    if req.job ~= nil or req.jobs ~= nil then rules = rules + 1
    elseif req.onDuty == true then rules = rules + 1 end   -- on duty at any job; beside a job it is part of it
    if req.charId ~= nil or req.charIds ~= nil then rules = rules + 1 end
    if req.ace ~= nil then rules = rules + 1 end
    local items = req.item ~= nil and req.item or req.items
    if items ~= nil then
        -- An action's item list needs every item; one door rule is one item.
        local one = type(items) ~= 'table' or rawget(items, 'item') ~= nil or rawget(items, 'key') ~= nil
        rules = rules + (one and 1 or #items)
    end
    if rules > 1 then
        return false, ('%s: here require names one rule. This lets in anyone who meets ANY ONE of its requirements (an action\'s require needs them ALL), so these together would let in each alone. Give one rule, or requirements = { ... } meaning "any one of"'):format(what)
    end
    local copy = {}
    for k, v in pairs(data) do if k ~= 'require' then copy[k] = v end end
    copy.requirements = req
    return copy
end

-- The fields a declared door reads (EnsureDoors / EnsureDoor): anything else is warned about in the console.
local DOOR_FIELDS = {
    key = true, model = true, coords = true, x = true, y = true, z = true, heading = true, label = true,
    folder = true, requirements = true, link = true, autolock = true, autolockDelay = true,
}

-- ============================================
-- CRUD
-- ============================================

--- Spots a create is writing right now: a door reaches doorCache only after its INSERT returns, so
--- a second create at the same spot meanwhile is refused like one at an existing door (two rows on
--- one physical door are what adopt-or-refuse exists to prevent).
local _creating = {}   -- [reservation] = { x, y, z }

---@return table|nil door
---@return string|nil err
---@return number|nil existingDoorId  the door already at that spot, when that is why
function Doors.create(data, createdBy)
    if type(data) ~= 'table' then return nil, 'A door is a table: { model, x, y, z, heading, ... }' end

    -- The model is stored signed, as GetEntityModel answers (doors are matched to their object by
    -- it); map packs write door lists unsigned. A name is hashed.
    local model = PropertyMath.signedHash(data.model)
    if not model then return nil, 'A door needs a model' end
    if not (tonumber(data.x) and tonumber(data.y) and tonumber(data.z)) then
        return nil, 'A door needs x, y and z'
    end
    data = shallowCopy(data)
    data.model = model
    if data.requirements ~= nil then
        local req, why = normaliseRequirements(data.requirements)
        if req == false then return nil, why end
        data.requirements = req
    end

    -- Prevent duplicate doors at the same position (within 0.5m). The door in the way comes back
    -- as a third value.
    for _, existing in ipairs(doorsAround(tonumber(data.x), tonumber(data.y))) do
        local dx = existing.x - data.x
        local dy = existing.y - data.y
        local dz = existing.z - data.z
        if (dx*dx + dy*dy + dz*dz) < 0.25 then
            return nil, 'Door already exists at this position (#' .. existing.doorId .. ')', existing.doorId
        end
    end
    for _, spot in pairs(_creating) do
        local dx, dy, dz = spot.x - data.x, spot.y - data.y, spot.z - data.z
        if (dx*dx + dy*dy + dz*dz) < 0.25 then
            return nil, 'A door is being created at this position right now'
        end
    end
    -- Encoded BEFORE the reservation: an encode that throws must not leave the spot reserved.
    local reqJson = data.requirements and json.encode(data.requirements) or nil
    local metaJson = data.metadata and json.encode(data.metadata) or nil

    -- Held from here until the row is in doorCache (or the insert failed): nothing below may
    -- return between the reservation and its release without releasing it. (The insert is
    -- pcall'd, so it cannot throw past the release.)
    local reservation = { x = data.x, y = data.y, z = data.z }
    _creating[reservation] = reservation

    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `doors` (`label`, `folder`, `model`, `x`, `y`, `z`, `heading`, `locked`, `linkedDoorId`, `requirements`, `metadata`, `createdBy`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            data.label or 'Door',
            data.folder or nil,
            data.model,
            data.x, data.y, data.z,
            data.heading or 0,
            -- A new door is always locked (`data.locked` is not consulted; use SetDoorLocked after).
            1,
            data.linkedDoorId or nil,
            reqJson, metaJson,
            createdBy or nil,
        }
    )
    if not ok or not insertId then
        _creating[reservation] = nil
        print('[whip_core:doors] ERROR creating door: ' .. tostring(insertId))
        return nil, 'Could not save the door'
    end
    local door = {
        doorId        = insertId,
        label         = data.label or 'Door',
        folder        = data.folder,
        model         = data.model,
        x             = data.x, y = data.y, z = data.z,
        heading       = data.heading or 0,
        locked        = true,
        defaultLocked = true,
        autolock      = false,
        autolockDelay = 10,
        linkedDoorId  = data.linkedDoorId,
        requirements  = data.requirements,
        metadata      = data.metadata,
    }
    doorCache[insertId] = door
    _creating[reservation] = nil   -- the cache answers for this spot from here
    cellInsert(door)

    -- Replication lives with the mutation, so every creator is covered (as Shops.delete).
    -- wireOne, not the record: requirements never leave the server.
    TriggerClientEvent('whip_core:client:doorCreated', -1, Doors.wireOne(door))

    return door
end

--- Forward-declared: Doors.update is written above the function it hands the write to.
local writeDoor

--- Apply a partial update to a door: write it first, then believe it.
---
--- The cache follows the write: `updates` is laid over a COPY, so a rejected write leaves the
--- cached door as it was.
---
--- A trap: `{ requirements = nil }` does not clear requirements (it is an empty table in Lua). Pass
--- `{}`: isAuthorizedWithReason treats an empty table as "no requirements".
---
--- Unknown fields are refused, not ignored: anything the UPDATE doesn't carry would change the cache
--- and not the row (the Door Manager forwards whatever field its NUI names).
---
--- A managed door's access is its manager's (see "Managed doors" above): requirements, link,
--- autolock and metadata are refused unless `manager` is the one that manages it.
---@param doorId number
---@param updates table
---@param manager table|nil  { system, id }: the caller, when it manages doors
---@return boolean ok
---@return string|nil err
function Doors.update(doorId, updates, manager)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end
    if type(updates) ~= 'table' then return false, 'updates must be a table' end

    local touchesManaged = false
    for k in pairs(updates) do
        if not DOOR_UPDATABLE[k] then
            return false, ('"%s" is not an updatable door field'):format(tostring(k))
        end
        if MANAGED_FIELDS[k] then touchesManaged = true end
    end

    if touchesManaged then
        local ok, why = checkManager(door, manager)
        if not ok then return false, why end
    end

    -- Who manages a door changes only through adopt and release (an update can't claim a door by
    -- writing its own name into the metadata).
    if updates.metadata ~= nil then
        local wanted = type(updates.metadata) == 'table' and updates.metadata.managedBy or nil
        if not Registry.deepEquals(wanted, managerOf(door)) then
            return false, 'A door\'s manager is set by EnsureDoors or EnsureDoor, not by UpdateDoor'
        end
    end

    -- `locked` takes the lock path (the linked twin, the players at the door).
    local lockTo
    if updates.locked ~= nil then
        lockTo = updates.locked
        local rest = {}
        for k, v in pairs(updates) do
            if k ~= 'locked' then rest[k] = v end
        end
        updates = rest
    end

    -- `folder = ''` takes the door out of its folder (a nil is no key at all in a Lua table).
    local clears
    if updates.folder == '' then
        clears = { folder = true }
        local rest = {}
        for k, v in pairs(updates) do
            if k ~= 'folder' then rest[k] = v end
        end
        updates = rest
    end

    if next(updates) or clears then
        local ok, err = writeDoor(door, updates, clears)
        if not ok then return false, err end
    end
    if lockTo ~= nil then return Doors.setLocked(doorId, lockTo) end
    return true
end

local _doorWriting = {}   -- [doorId] = true while its row is being written

--- The write itself, with no rule applied: Doors.update's checks, and adopt and release, which
--- change the managedBy block on purpose.
---
--- `clears` names fields to set to nil. Leaving a key out of `updates` keeps its value (the
--- `{ requirements = nil }` trap above), so a release restoring a door that had no folder needs a
--- way to say "no folder".
---@param door table
---@param updates table
---@param clears table|nil  { [field] = true }
---@return boolean ok, string|nil err
function writeDoor(door, updates, clears)
    local doorId = door.doorId
    -- A run's temporary door has no row to write (see "Held doors" at the top).
    if isRuntime(doorId) then return false, ('Door #%d is a run\'s and is not saved'):format(doorId) end

    -- Requirements in the one shape, or refused with the reason (normaliseRequirements).
    if updates.requirements ~= nil then
        local req, why = normaliseRequirements(updates.requirements)
        if req == false then return false, why end
        local copy = {}
        for k, v in pairs(updates) do copy[k] = v end
        copy.requirements = req
        updates = copy
    end

    -- Autolock as what it is: a switch, and a number of seconds (1 to 3600).
    if updates.autolock ~= nil or updates.autolockDelay ~= nil then
        local copy = {}
        for k, v in pairs(updates) do copy[k] = v end
        if copy.autolock ~= nil then
            if type(copy.autolock) == 'number' then copy.autolock = copy.autolock ~= 0 end
            if type(copy.autolock) ~= 'boolean' then return false, 'autolock is true or false' end
        end
        if copy.autolockDelay ~= nil then
            local d = tonumber(copy.autolockDelay)
            if not d or d ~= d or d < 1 or d > 3600 then
                return false, 'autolockDelay is a number of seconds, 1 to 3600'
            end
            copy.autolockDelay = math.floor(d)
        end
        updates = copy
    end

    -- One write per door at a time: two overlapping writes (a key granted, one revoked) could leave
    -- memory on one and the row on the other.
    local waited = 0
    while _doorWriting[doorId] and waited < 5000 do Wait(25); waited = waited + 25 end
    if _doorWriting[doorId] then return false, 'The door is busy — try again' end
    _doorWriting[doorId] = true

    -- What every client sees of it now, to tell whether this write changes that (below).
    local wireBefore = Doors.wireOne(door)

    -- The door as it would be, if the write lands.
    local merged = {}
    for k, v in pairs(door) do merged[k] = v end
    for k, v in pairs(updates) do merged[k] = v end
    for k in pairs(clears or {}) do merged[k] = nil end

    local reqJson  = merged.requirements and json.encode(merged.requirements) or nil
    local metaJson = merged.metadata and json.encode(merged.metadata) or nil

    local ok, err = Stores.runTransaction({
        {
            query = 'UPDATE `doors` SET `label`=?, `folder`=?, `locked`=?, `defaultLocked`=?, ' ..
                    '`autolock`=?, `autolockDelay`=?, `linkedDoorId`=?, `requirements`=?, ' ..
                    '`metadata`=? WHERE `doorId`=?',
            values = {
                merged.label, merged.folder, merged.locked and 1 or 0,
                merged.defaultLocked and 1 or 0, merged.autolock and 1 or 0,
                merged.autolockDelay or 10,
                merged.linkedDoorId, reqJson, metaJson, doorId,
            },
        },
    }, 'door_update')
    _doorWriting[doorId] = nil

    if not ok then
        print(('[whip_core:doors] FAILED updating door %s: %s')
            :format(tostring(doorId), tostring(err)))
        return false, err
    end

    -- Only what this write changed: copying the whole snapshot back would undo whatever happened
    -- during the wait (a lock change). Lock state is memory's anyway.
    for k, v in pairs(updates) do door[k] = v end
    for k in pairs(clears or {}) do door[k] = nil end

    -- Replicated from the mutation itself, projected (most fields are server-private), and only
    -- when what clients see changed (a key granted rewrites requirements, which aren't on the wire).
    local wireAfter = Doors.wireOne(door)
    if not Registry.deepEquals(wireBefore, wireAfter) then
        TriggerClientEvent('whip_core:client:doorUpdated', -1, doorId, wireAfter)
    end

    return true
end

--- Persist a door's lock state AND tell the players who can see it.
---
--- Both halves, always, in one function.
---
--- Sent to players in range, not everyone (doors are toggled constantly). PlayersNearPoint reads the
--- ground items' cell index: a table lookup per player, no distance maths.
---
--- Every client holds every door (doorsSync at login), so a far player's copy is stale by design:
--- when the ground-item sweep grants a player new cells, it hands them the current state of every
--- door there (doorStatesBatch, Doors.getStatesInCells). Hear it if near; be caught up on arrival.
---
--- The coverage margin is load-bearing:
---
---   client DOOR_RANGE           50m   — a client registers a door's native only within this
---   GroundItemCellSize          50m
---   GroundItemStreamRange      100m   — ceil(100/50) = 2 cells each way, a 5×5 grid
---   => a player holds ~±125m of cells, against a 50m door range
---
--- So every door a client could be standing at sits in a cell it holds (the catch-up lands ~75m out).
--- Shrink GroundItemStreamRange or raise DOOR_RANGE past that margin and door states lag silently;
--- the boot check below says so out loud.
---
--- Lock state lives in memory only (every door starts locked): no database write in the way of
--- somebody opening a door.
---@param doorId number
---@param locked boolean
---@param why table|nil  { cause, source }: for the 'lockChanged' hook ('code' when not said)
---@return boolean ok, string|nil err
function Doors.updateState(doorId, locked, why)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end

    local changed = door.locked ~= locked
    door.locked = locked
    -- Every state change supersedes a pending autolock (the partner leaf, SetDoorLocked, the Door
    -- Manager), on every call, the same state again included. The toggle's timer captures both
    -- leaves' numbers after this.
    autolockToken[doorId] = (autolockToken[doorId] or 0) + 1

    -- A door with no position can't be scoped, so it goes to everyone.
    if not (door.x and door.y) then
        TriggerClientEvent('whip_core:client:doorStateChanged', -1, doorId, locked)
    else
        for _, src in ipairs(PlayersNearPoint(door.x, door.y)) do
            TriggerClientEvent('whip_core:client:doorStateChanged', src, doorId, locked)
        end
    end

    -- Told only when it really moved: the same state again is no news.
    if changed then
        announce('lockChanged', { doorId = doorId, locked = locked,
                                  source = type(why) == 'table' and why.source or nil,
                                  cause = type(why) == 'table' and why.cause or 'code' })
    end
    return true
end

--- Lock this door (and its linked partner) again after its autolock delay; only the most recent
--- unlock counts. The timer captures each leaf's number (Doors.updateState bumps it on every state
--- change) and does nothing if either has moved on since.
---
--- Every unlock schedules it (a press, SetDoorLocked, UpdateDoor's `locked`, the Door Manager), but
--- not a pick: a picked door stays open. Call it after both leaves have moved.
---@param doorId number
local function scheduleAutolock(doorId)
    local door = doorCache[doorId]
    if not door or not door.autolock or door.locked then return end
    -- A held door never relocks by itself: the run that holds it decides.
    if _holds[doorId] then return end
    -- Held to 1..3600 s here too, for an old row writeDoor never checked.
    local delay = math.min(3600, math.max(1, tonumber(door.autolockDelay) or 10)) * 1000
    local linkedId = door.linkedDoorId and doorCache[door.linkedDoorId] and door.linkedDoorId or nil

    local token = autolockToken[doorId]
    local linkedToken = linkedId and autolockToken[linkedId]
    -- Remembered, so a hold can tell "open, relocking soon" from "open for good" (a picked door).
    armedToken[doorId] = token

    SetTimeout(delay, function()
        if autolockToken[doorId] ~= token then return end
        if linkedId and autolockToken[linkedId] ~= linkedToken then return end
        if _holds[doorId] or (linkedId and _holds[linkedId]) then return end   -- held since: the run decides
        if doorCache[doorId] and not doorCache[doorId].locked then
            Doors.updateState(doorId, true, { cause = 'autolock' })
            if linkedId and doorCache[linkedId] then
                Doors.updateState(linkedId, true, { cause = 'autolock' })
            end
        end
    end)
end

--- Lock or unlock a door AND its linked twin: the lock path for everything but a player's own press
--- (SetDoorLocked, UpdateDoor's `locked`, the Door Manager).
---
--- The twin is a convenience, not part of the promise: the door named is locked, and a twin that
--- fails is reported rather than undoing the one that worked.
---@param doorId number
---@param locked any  FiveM-truthy: nil, false and 0 mean unlocked
---@param why table|nil  { cause, source } for the 'lockChanged' hook ('code' when not said)
---@return boolean ok, string|nil err
function Doors.setLocked(doorId, locked, why)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end
    locked = locked ~= nil and locked ~= false and locked ~= 0

    local ok, err = Doors.updateState(doorId, locked, why)
    if not ok then return false, err end

    local linked = door.linkedDoorId and doorCache[door.linkedDoorId]
    if linked then
        local lOk, lErr = Doors.updateState(linked.doorId, locked, why)
        if not lOk then
            print(('[whip_core:door] door %s %s but its linked door %s did not: %s'):format(tostring(doorId),
                locked and 'locked' or 'unlocked', tostring(linked.doorId), tostring(lErr)))
        end
    end

    -- An unlock by code autolocks like a press. Either leaf's setting counts; the first timer to fire
    -- moves both numbers on and the second stands down.
    if not locked then
        scheduleAutolock(doorId)
        if linked then scheduleAutolock(linked.doorId) end
    end
    return true
end

--- Delete a door, unlinking anything that points at it, in ONE transaction.
---
--- Atomic, or nothing happens (a failed delete must not leave a door with its pairing destroyed).
--- The unlink can't be left to the database: `linkedDoorId` has no foreign key, so no ON DELETE SET NULL.
---
--- A MANAGED DOOR is deleted only by its manager: the manager would put it straight back.
---@param doorId number
---@param manager table|nil  { system, id }: the caller, when it manages doors
---@return boolean ok
---@return string|nil err
function Doors.delete(doorId, manager)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end
    if isRuntime(doorId) then return false, ('Door #%d is a run\'s: it goes when the run ends'):format(doorId) end

    local allowed, why = checkManager(door, manager)
    if not allowed then return false, why end

    local queries  = {}
    local unlinked = {}

    for _, d in pairs(doorCache) do
        if d.linkedDoorId == doorId then
            unlinked[#unlinked + 1] = d
            queries[#queries + 1] = {
                query  = 'UPDATE `doors` SET `linkedDoorId`=NULL WHERE `doorId`=?',
                values = { d.doorId },
            }
        end
    end

    queries[#queries + 1] = {
        query  = 'DELETE FROM `doors` WHERE `doorId`=?',
        values = { doorId },
    }

    local ok, err = Stores.runTransaction(queries, 'door_delete')
    if not ok then
        print(('[whip_core:doors] FAILED deleting door %s: %s')
            :format(tostring(doorId), tostring(err)))
        return false, err
    end

    -- Only now. The cache follows the write, not the intention.
    for _, d in ipairs(unlinked) do d.linkedDoorId = nil end
    doorCache[doorId] = nil
    cellRemove(doorId)

    -- Bumped rather than cleared: "anything outstanding is stale", even if the id is reused.
    autolockToken[doorId] = (autolockToken[doorId] or 0) + 1

    -- Replicated from the mutation, as create.
    TriggerClientEvent('whip_core:client:doorDeleted', -1, doorId)

    return true
end

function Doors.getDef(doorId)
    return doorCache[doorId]
end

function Doors.getAll()
    local result = {}
    for _, door in pairs(doorCache) do
        result[#result + 1] = door
    end
    return result
end

--- The door as ordinary clients receive it: the seven fields the client reads, copied fresh, never
--- the live record (as Shops.wireOne and Garages.wire).
---
--- Withheld: requirements (the jobs, items and ACEs that open the door: intel) and every field the
--- client has no reader for (the server toggles linked doors itself). The Door Manager gets full
--- records through getDoorAll, which is ACE-gated.
---@param door table
---@return table
function Doors.wireOne(door)
    return {
        doorId = door.doorId,
        label  = door.label,
        model  = door.model,
        x      = door.x,
        y      = door.y,
        z      = door.z,
        locked = door.locked,
    }
end

--- Every door, projected, sorted by doorId — the doorsSync payload.
---@return table[]
function Doors.wire()
    local out = {}
    for _, door in pairs(doorCache) do
        out[#out + 1] = Doors.wireOne(door)
    end
    table.sort(out, function(a, b) return a.doorId < b.doorId end)
    return out
end

--- Pair two doors so they lock and unlock together.
---
--- One transaction: a link is a fact about a PAIR, and half of one is a door that follows a
--- partner which ignores it. A link is a managed field: every door it rewrites, old partners
--- included, must be the caller's to change (see "Managed doors").
---@param doorId1 number
---@param doorId2 number
---@param manager table|nil  { system, id }: the caller, when it manages doors
---@return boolean ok
---@return string|nil err
function Doors.linkDoors(doorId1, doorId2, manager)
    local d1 = doorCache[doorId1]
    local d2 = doorCache[doorId2]
    if not d1 or not d2 then return false, 'Door not found' end

    -- A door linked to itself has no meaning (the toggle would act on it twice).
    if doorId1 == doorId2 then return false, 'A door cannot be linked to itself' end
    -- Not a run's temporary door (no row), nor one a run holds: the hold is of the pair it found.
    for _, id in ipairs({ doorId1, doorId2 }) do
        if isRuntime(id) then return false, ('Door #%d is a run\'s and is not saved'):format(id) end
        if _holds[id] then return false, ('Door #%d is held by a run right now'):format(id) end
    end

    -- Unlink the old partners in the same transaction: making a new pair ends the old ones (or B
    -- would still point at A after A is linked to C).
    local queries = {}
    local stale = {}
    for _, pair in ipairs({ { d1, doorId2 }, { d2, doorId1 } }) do
        local d, newPartner = pair[1], pair[2]
        local old = d.linkedDoorId
        if old and old ~= newPartner and doorCache[old] and doorCache[old].linkedDoorId == d.doorId then
            queries[#queries + 1] = { query = 'UPDATE `doors` SET `linkedDoorId`=NULL WHERE `doorId`=?', values = { old } }
            stale[#stale + 1] = old
        end
    end

    for _, d in ipairs({ d1, d2 }) do
        local allowed, why = checkManager(d, manager)
        if not allowed then return false, why end
    end
    for _, old in ipairs(stale) do
        local allowed, why = checkManager(doorCache[old], manager)
        if not allowed then return false, why end
    end
    queries[#queries + 1] = { query  = 'UPDATE `doors` SET `linkedDoorId`=? WHERE `doorId`=?',
                              values = { doorId2, doorId1 } }
    queries[#queries + 1] = { query  = 'UPDATE `doors` SET `linkedDoorId`=? WHERE `doorId`=?',
                              values = { doorId1, doorId2 } }

    local ok, err = Stores.runTransaction(queries, 'door_link')

    if not ok then
        print(('[whip_core:doors] FAILED linking doors %s and %s: %s')
            :format(tostring(doorId1), tostring(doorId2), tostring(err)))
        return false, err
    end

    for _, old in ipairs(stale) do
        if doorCache[old] then doorCache[old].linkedDoorId = nil end
    end
    d1.linkedDoorId = doorId2
    d2.linkedDoorId = doorId1
    return true
end

--- Undo a link: both halves, in one write. (`UpdateDoor(id, { linkedDoorId = nil })` can't: see the
--- trap Doors.update describes.) A door that is not linked answers true. A link is a managed field.
---@param doorId number
---@param manager table|nil  { system, id }: the caller, when it manages doors
---@return boolean ok, string|nil err
function Doors.unlinkDoors(doorId, manager)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end
    local partnerId = door.linkedDoorId
    if not partnerId then return true end
    if _holds[doorId] then return false, ('Door #%d is held by a run right now'):format(doorId) end

    -- The partner is unlinked too only if it points back: a one-way link (an old half-write) leaves
    -- the other door's own link alone.
    local partner = doorCache[partnerId]
    if partner and partner.linkedDoorId ~= doorId then partner = nil end

    local allowed, why = checkManager(door, manager)
    if not allowed then return false, why end
    if partner then
        allowed, why = checkManager(partner, manager)
        if not allowed then return false, why end
    end

    local queries = { { query = 'UPDATE `doors` SET `linkedDoorId`=NULL WHERE `doorId`=?', values = { doorId } } }
    if partner then
        queries[2] = { query = 'UPDATE `doors` SET `linkedDoorId`=NULL WHERE `doorId`=?', values = { partnerId } }
    end
    local ok, err = Stores.runTransaction(queries, 'door_unlink')
    if not ok then
        print(('[whip_core:doors] FAILED unlinking door %s: %s'):format(tostring(doorId), tostring(err)))
        return false, err
    end

    door.linkedDoorId = nil
    if partner then partner.linkedDoorId = nil end
    return true, partner and partnerId or nil
end

-- ============================================
-- Managed doors: adopt, release, list
-- ============================================

--- How close an existing door must be to count as "the door that is already here". The same half
--- metre Doors.create refuses a second door inside, so every spot has one answer: the door there
--- is adopted, or it is a conflict, or there is none and a door is made.
local ADOPT_RANGE = 0.5

--- Take charge of the door at this spot, making it if there is none.
---
--- The one way a system comes to manage a door: never a second door on top of one already there,
--- and never quietly taking over a door somebody else manages.
---
---   no door here                  a new one is made, marked `created`
---   a door here, nobody's         it is adopted: what it was (requirements, label, folder,
---                                 autolock, link) is kept in `prev` for release to put back
---   a door here, this manager's   nothing changes but its key and label ('already')
---   the same key, moving between  it moves to this set, keeping its history ('already')
---     EnsureDoor's own set and
---     the resource's other set
---   a door here, someone else's   refused, with the door, so the caller can say which
---   a different model here        refused: the spot holds some other door
---
--- `data` is what Doors.create takes: model, x, y, z, heading, label, folder, requirements. On an
--- adopted door only label, folder and requirements are written; position, model and heading
--- are fixed at creation.
---@param data table
---@param manager table  { system, id, key?, label? }
---@return table|nil door, string howOrErr 'created' | 'adopted' | 'already', or why not
---@return table|nil conflict  the door in the way, when refused
function Doors.adoptOrCreate(data, manager)
    if type(data) ~= 'table' then return nil, 'data must be a table' end
    if type(manager) ~= 'table' or type(manager.system) ~= 'string' or manager.system == ''
        or manager.id == nil then
        return nil, 'A door manager needs a system and an id'
    end
    local model = PropertyMath.signedHash(data.model)
    if not model then return nil, 'A door needs a model' end
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if not (x and y and z) then return nil, 'A door needs x, y and z' end

    local mb = { system = manager.system, id = manager.id, key = manager.key, label = manager.label }

    local found, bestSq = nil, ADOPT_RANGE * ADOPT_RANGE
    for _, d in ipairs(doorsAround(x, y)) do   -- the cells around the spot, not every door
        local dx, dy, dz = d.x - x, d.y - y, d.z - z
        local dsq = dx * dx + dy * dy + dz * dz
        if dsq < bestSq then found, bestSq = d, dsq end
    end

    if not found then
        local meta = shallowCopy(data.metadata)
        mb.created = true
        meta.managedBy = mb
        local door, err = Doors.create({
            label = data.label, folder = data.folder, model = model,
            x = x, y = y, z = z, heading = data.heading,
            requirements = data.requirements, metadata = meta,
        })
        if not door then return nil, err or 'Could not create the door' end
        return door, 'created'
    end

    if found.model ~= model then
        return nil, ('Door #%d, a different model, is already here'):format(found.doorId), found
    end
    -- A door is managed or held, never both (a run's hold decides who presses it until it ends).
    if _holds[found.doorId] then
        return nil, ('Door #%d is held by a run right now'):format(found.doorId), found
    end

    local current = managerOf(found)
    -- One key moving between EnsureDoor's own set ('door:<key>') and another of the same resource's
    -- sets is allowed, keeping its history (made or adopted, and what release puts back). Anything
    -- else is refused: two managers of one resource must not take each other's doors.
    local function ensureDoorSet(m) return m.key ~= nil and tostring(m.id) == 'door:' .. tostring(m.key) end
    local rehome = current and not sameManager(current, manager)
        and type(current.system) == 'string' and current.system:sub(1, 9) == 'resource:'
        and current.system == manager.system
        and current.key ~= nil and tostring(current.key) == tostring(mb.key)
        and (ensureDoorSet(current) or ensureDoorSet(mb))
    if current and not sameManager(current, manager) and not rehome then
        return nil, ('Door #%d already belongs to %s'):format(found.doorId, managerName(current)), found
    end

    local updates = {}
    if data.label ~= nil then updates.label = data.label end
    if data.folder ~= nil then updates.folder = data.folder end
    if data.requirements ~= nil then
        -- In the stored spelling, so the comparison below matches the row (or every start would
        -- rewrite it). One that doesn't normalise goes through as it was; writeDoor refuses it.
        local norm = normaliseRequirements(data.requirements)
        updates.requirements = norm or data.requirements
    end

    local meta = shallowCopy(found.metadata)
    local how
    if current then
        -- Already ours. Only its name within the manager can have moved on, or its set (above).
        local same = shallowCopy(current)
        same.key, same.label = mb.key, mb.label
        if rehome then same.id = mb.id end
        meta.managedBy = same
        how = 'already'
    else
        mb.adopted = true
        mb.prev = {
            -- {} rather than nil, so a door that had no requirements goes back to having none.
            requirements  = found.requirements or {},
            label         = found.label,
            folder        = found.folder,
            autolock      = found.autolock and true or false,
            autolockDelay = found.autolockDelay or 10,
            linkedDoorId  = found.linkedDoorId,
        }
        meta.managedBy = mb
        how = 'adopted'
    end

    -- Nothing to write for an 'already' whose names all match: a reconcile at every boot must
    -- not rewrite every row it touches.
    local changed = not Registry.deepEquals(meta, found.metadata or {})
    for k, v in pairs(updates) do
        if not Registry.deepEquals(v, found[k]) then changed = true end
    end
    if not changed then return found, how end

    updates.metadata = meta
    -- The write waits on the database: a run must not hold this door meanwhile (Doors.hold asks).
    _adopting[found.doorId] = true
    local ok, err = writeDoor(found, updates)
    _adopting[found.doorId] = nil
    if not ok then return nil, err or 'Could not save the door' end
    return found, how
end

--- Give a door up: a door made for its manager is deleted, an adopted one is put back as it was.
---
--- A door nobody manages is already released, and answers true. Someone else's is refused.
---
--- The link: a pair the manager made is unlinked (both halves, one write); the pair the door had
--- when it was adopted is put back.
---@param doorId number
---@param manager table  { system, id }
---@return boolean ok, string|nil err
function Doors.release(doorId, manager)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end
    local mb = managerOf(door)
    if not mb then return true end
    if not sameManager(mb, manager) then
        return false, ('Door #%s belongs to %s'):format(tostring(doorId), managerName(mb))
    end

    if mb.created then return Doors.delete(doorId, manager) end

    local prev = type(mb.prev) == 'table' and mb.prev or {}

    if door.linkedDoorId and door.linkedDoorId ~= prev.linkedDoorId then
        local partner = doorCache[door.linkedDoorId]
        local queries = { { query = 'UPDATE `doors` SET `linkedDoorId`=NULL WHERE `doorId`=?', values = { doorId } } }
        if partner and partner.linkedDoorId == doorId then
            queries[2] = { query = 'UPDATE `doors` SET `linkedDoorId`=NULL WHERE `doorId`=?', values = { partner.doorId } }
        end
        local ok, err = Stores.runTransaction(queries, 'door_unlink')
        if not ok then return false, err end
        door.linkedDoorId = nil
        if partner and partner.linkedDoorId == doorId then partner.linkedDoorId = nil end
    end

    -- And the pair it had, back (linkDoors ended it if the manager re-paired the door): only while
    -- that door still exists, is free, and is nobody else's to decide about.
    local oldId = prev.linkedDoorId
    local old = oldId and oldId ~= doorId and doorCache[oldId]
    -- Not while a run holds that door (as linkDoors refuses).
    if old and door.linkedDoorId == nil and old.linkedDoorId == nil and not _holds[oldId] then
        local omb = managerOf(old)
        if omb == nil or sameManager(omb, manager) then
            local ok, err = Stores.runTransaction({
                { query = 'UPDATE `doors` SET `linkedDoorId`=? WHERE `doorId`=?', values = { oldId, doorId } },
                { query = 'UPDATE `doors` SET `linkedDoorId`=? WHERE `doorId`=?', values = { doorId, oldId } },
            }, 'door_link')
            if ok then
                door.linkedDoorId, old.linkedDoorId = oldId, doorId
            else
                print(('[whip_core:doors] released door %s could not be paired with door %s again: %s')
                    :format(tostring(doorId), tostring(oldId), tostring(err)))
            end
        end
    end

    local meta = shallowCopy(door.metadata)
    meta.managedBy = nil
    local updates = {
        requirements  = prev.requirements or {},
        label         = prev.label or door.label,
        autolock      = prev.autolock == true,
        autolockDelay = tonumber(prev.autolockDelay) or 10,
    }
    local clears = {}
    if prev.folder then updates.folder = prev.folder else clears.folder = true end
    if next(meta) then updates.metadata = meta else clears.metadata = true end
    return writeDoor(door, updates, clears)
end

-- ============================================
-- Held doors: take, set who may press, give back (see "Held doors" at the top)
-- ============================================

--- A hold ends: a temporary door goes, a saved one gets back the lock it had (both leaves), and is
--- left to its own autolock if that leaves it open, as any unlock by code is. Never waits: it runs
--- inside a registry release (a run's end, its owner stopping). No row is touched.
---@param rec table
local function endHold(rec)
    for _, leaf in ipairs(rec.leaves) do
        if _holds[leaf] == rec then _holds[leaf] = nil end
    end
    if rec.made then
        local id = rec.doorId
        if doorCache[id] then
            doorCache[id] = nil
            cellRemove(id)
            autolockToken[id] = (autolockToken[id] or 0) + 1
            TriggerClientEvent('whip_core:client:doorDeleted', -1, id)
        end
        return
    end
    for _, leaf in ipairs(rec.leaves) do
        local d = doorCache[leaf]
        -- Not one somebody manages since (an admin can't adopt a held door, but deleted and remade it
        -- could be): its manager decides, not a memory of the run.
        if d and not managerOf(d) and rec.prevLocked[leaf] ~= nil then
            Doors.updateState(leaf, rec.prevLocked[leaf], { cause = 'released' })
        end
    end
    -- Its relock again, only where one was coming when the hold began: a door left open on purpose
    -- (picked: it never relocks) stays open, as it would have without the hold.
    for _, leaf in ipairs(rec.leaves) do
        local d = doorCache[leaf]
        if d and not d.locked and rec.relock[leaf] then scheduleAutolock(leaf) end
    end
end

local holdReg = Registry.new('doorHold', {
    label = 'door',
    scoped = true,
    releaseOrder = 80,   -- doors near last in a run's release, before its zones (90)
    same = false,
    onRemove = function(_, rec) endHold(rec) end,
})

--- Take the door at this spot for `owner`, or make a temporary one if there is none.
---@param owner string  Registry.caller(), read before anything else
---@param data table { model, x, y, z, heading?, label? }: where the door is, as the Door Editor reads it
---@param opts table|nil { tag, requirements }: requirements say who may press it (default nobody)
---@return number|nil doorId
---@return string howOrWhy  'held' | 'made' | 'already', or why not
function Doors.hold(owner, data, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(data) ~= 'table' then return nil, 'data must be a table: { model, x, y, z, heading }' end
    local model = PropertyMath.signedHash(data.model)
    if not model then return nil, 'A door needs a model' end
    local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
    if not (x and y and z) then return nil, 'A door needs x, y and z' end
    local tag = opts.tag
    if tag ~= nil then
        local bad = Registry.badTag(tag)   -- before isClosed, which joins it into a key
        if bad then return nil, bad end
        if Registry.isClosed(owner, tag) then return nil, ('%s has ended'):format(tostring(tag)) end
    end
    local req
    if opts.requirements ~= nil then
        local why
        req, why = normaliseRequirements(opts.requirements)
        if req == false then return nil, why --[[@as string]] end
    end
    req = req or { charIds = {} }   -- nobody, until the holder says who

    local found, bestSq = nil, ADOPT_RANGE * ADOPT_RANGE
    for _, d in ipairs(doorsAround(x, y)) do
        local dx, dy, dz = d.x - x, d.y - y, d.z - z
        local dsq = dx * dx + dy * dy + dz * dz
        if dsq < bestSq then found, bestSq = d, dsq end
    end

    local rec, door
    if found then
        if found.model ~= model then
            return nil, ('Door #%d, a different model, is already here'):format(found.doorId)
        end
        local held = _holds[found.doorId]
        if held then
            if held.owner == owner and held.tag == tag then return held.doorId, 'already' end
            return nil, ('Door #%d is held by another run'):format(found.doorId)
        end
        local mb = managerOf(found)
        if mb then return nil, ('Door #%d belongs to %s, and is not a run\'s to take'):format(found.doorId, managerName(mb)) end
        local leaves = { found.doorId }
        local partner = found.linkedDoorId and doorCache[found.linkedDoorId]
        if partner then
            if _holds[partner.doorId] then return nil, ('Door #%d (its other leaf) is held by another run'):format(partner.doorId) end
            local pmb = managerOf(partner)
            if pmb then return nil, ('Door #%d (its other leaf) belongs to %s'):format(partner.doorId, managerName(pmb)) end
            leaves[2] = partner.doorId
        end
        for _, leaf in ipairs(leaves) do
            if _adopting[leaf] then return nil, ('Door #%d is being taken over by its manager right now'):format(leaf) end
        end
        local prevLocked, relock = {}, {}
        for _, leaf in ipairs(leaves) do
            prevLocked[leaf] = doorCache[leaf].locked == true
            -- Open with its autolock still to come (not open for good, as a picked door is).
            relock[leaf] = not prevLocked[leaf] and armedToken[leaf] ~= nil and armedToken[leaf] == autolockToken[leaf]
        end
        rec = { doorId = found.doorId, owner = owner, tag = tag, requirements = req, leaves = leaves,
                prevLocked = prevLocked, relock = relock, made = false }
    else
        -- Not where a door is being saved right now (its INSERT waits): two doors on one.
        for _, spot in pairs(_creating) do
            local dx, dy, dz = spot.x - x, spot.y - y, spot.z - z
            if dx * dx + dy * dy + dz * dz < ADOPT_RANGE * ADOPT_RANGE then
                return nil, 'A door is being saved at this spot right now: try again'
            end
        end
        nextRuntime = nextRuntime + 1
        local id = RUNTIME_BASE + nextRuntime
        door = {
            doorId = id, label = type(data.label) == 'string' and data.label or 'Door', model = model,
            x = x, y = y, z = z, heading = tonumber(data.heading) or 0,
            locked = true, autolock = false, autolockDelay = 10,
        }
        rec = { doorId = id, owner = owner, tag = tag, requirements = req, leaves = { id }, prevLocked = {}, relock = {}, made = true }
    end

    -- First, so a run that has ended is refused before anything exists.
    local ok, why = holdReg:add(owner, rec.doorId, rec, tag ~= nil and { tag = tag } or nil)
    if not ok then return nil, why --[[@as string]] end
    if door then
        doorCache[door.doorId] = door
        cellInsert(door)
        TriggerClientEvent('whip_core:client:doorCreated', -1, Doors.wireOne(door))
    end
    for _, leaf in ipairs(rec.leaves) do _holds[leaf] = rec end
    return rec.doorId, rec.made and 'made' or 'held'
end

--- Who may press a door you hold: requirements in a door's shape; nil = nobody, {} = anyone.
---@return boolean ok, string|nil why
function Doors.setHoldAccess(owner, doorId, requirements)
    local rec = _holds[doorId]
    if not rec or rec.owner ~= owner then return false, ('Door #%s is not one you hold'):format(tostring(doorId)) end
    local req = { charIds = {} }
    if requirements ~= nil then
        local norm, why = normaliseRequirements(requirements)
        if norm == false then return false, why end
        req = norm or {}
    end
    rec.requirements = req
    return true
end

--- Give a door back before the run ends (the run's end does it anyway).
---@return boolean ok, string|nil why
function Doors.releaseHold(owner, doorId)
    local rec = _holds[doorId]
    if not rec or rec.owner ~= owner then return false, ('Door #%s is not one you hold'):format(tostring(doorId)) end
    return holdReg:remove(owner, rec.doorId)
end

--- The hold on a door, as anyone may read it: { owner, tag, doorId, made }, or nil.
---@return table|nil
function Doors.holdOf(doorId)
    local rec = _holds[doorId]
    if not rec then return nil end
    return { owner = rec.owner, tag = rec.tag, doorId = rec.doorId, made = rec.made }
end

--- Every door one manager holds: all of a system's (id nil), or one thing's.
---@param system string
---@param id any|nil
---@return table[] doors
function Doors.listManaged(system, id)
    local out = {}
    for _, door in pairs(doorCache) do
        local mb = managerOf(door)
        if mb and mb.system == system and (id == nil or tostring(mb.id) == tostring(id)) then
            out[#out + 1] = door
        end
    end
    table.sort(out, function(a, b) return a.doorId < b.doorId end)
    return out
end

-- ============================================
-- Declared doors: a resource's own list
-- ============================================
--
-- A map pack declares its doors; it doesn't run its own door system. EnsureDoors: the list IS the
-- resource's doors, each named by a key that stays the same between runs.
--
--   a key with no door yet     the door is made (or the door already at that spot adopted — see
--                              Doors.adoptOrCreate), under manager 'resource:<name>' / <set id>
--   a key whose door exists    its label, folder, requirements, autolock and link follow the list
--   a key no longer listed     its door is released: deleted if the list made it, put back as it
--                              was if it was adopted (prune = false keeps them)
--
-- The list wins, every time the resource starts: an admin's change to a declared door's access is
-- refused (a managed door), a rename put back next start. Change the list. Position, model and
-- heading are fixed once made, like any door.

local DOOR_KEY_PATTERN = '^[%w_%-%.:]+$'

--- A declared door's position: `coords` (a vector3, a vector4 carrying the heading, or a table)
--- or plain x, y, z. `heading` wins over a vector4's w.
local function declaredPos(def)
    local x, y, z, h
    local c = def.coords
    local t = type(c)
    if t == 'vector3' or t == 'vector4' then
        x, y, z = c.x, c.y, c.z
        if t == 'vector4' then h = c.w end
    elseif t == 'table' then
        x, y, z = tonumber(c.x or c[1]), tonumber(c.y or c[2]), tonumber(c.z or c[3])
        h = tonumber(c.w or c.heading or c[4])
    else
        x, y, z = tonumber(def.x), tonumber(def.y), tonumber(def.z)
    end
    return x, y, z, tonumber(def.heading) or h
end

--- Make one manager's doors match a list — the engine behind EnsureDoors / EnsureDoor.
---
--- Checked WHOLE before anything is written: a typo in the fortieth door must not leave the first
--- thirty-nine made and the rest missing. After that, a door that cannot be placed (a different
--- door is at its spot, one somebody else manages) is reported by key and the rest go ahead.
---@param list table[]  { key, model, coords | x/y/z, heading?, label?, folder?, requirements?, autolock?, autolockDelay?, link? }
---@param manager table { system, id, label? }
---@param prune boolean release this manager's doors the list no longer names
---@return table|false result  { doors = { [key] = doorId }, failed = { [key] = why }, released = n }
---@return string|nil err
function Doors.ensureSet(list, manager, prune)
    if type(list) ~= 'table' then return false, 'a door list is a table of { key, model, coords, ... }' end

    -- `require` is read as requirements when it names one rule (Doors.takeRequire); a field no door reads is said in
    -- the console once, so a typo is not a door open to all without a word.
    local clean = {}
    for i, def in ipairs(list) do
        if type(def) == 'table' then
            local what = ('door "%s"'):format(tostring(def.key or i))
            local taken, why = Doors.takeRequire(def, what)
            if not taken then return false, why end
            local warn = {}
            InteractSpec.unknown(taken, DOOR_FIELDS, '', warn)
            if #warn > 0 then InteractSpec.say('doors', manager.system, what, warn) end
            def = taken
        end
        clean[i] = def
    end
    list = clean

    local seen = {}
    for i, def in ipairs(list) do
        if type(def) ~= 'table' then return false, ('door %d is not a table'):format(i) end
        local key = def.key
        if type(key) ~= 'string' or #key > 60 or not key:match(DOOR_KEY_PATTERN) then
            return false, ('door %d needs a key: letters, digits, _ - . and :, at most 60'):format(i)
        end
        if seen[key] then return false, ('two doors are called "%s"'):format(key) end
        seen[key] = def
        if not PropertyMath.signedHash(def.model) then return false, ('door "%s" needs a model'):format(key) end
        local x, y, z = declaredPos(def)
        if not (x and y and z) then return false, ('door "%s" needs coords'):format(key) end
        if def.requirements ~= nil and type(def.requirements) ~= 'table' then
            return false, ('door "%s": requirements must be a table'):format(key)
        end
        if def.link ~= nil and (type(def.link) ~= 'string' or def.link == key) then
            return false, ('door "%s": link is the key of another door in this list'):format(key)
        end
    end
    for key, def in pairs(seen) do
        if def.link ~= nil and not seen[def.link] then
            return false, ('door "%s" links to "%s", which is not in the list'):format(key, def.link)
        end
    end

    local result = { doors = {}, failed = {}, released = 0 }
    local function mgrFor(key)
        return { system = manager.system, id = manager.id, key = key, label = manager.label }
    end

    -- The doors themselves. adoptOrCreate writes label, folder and requirements; autolock is ours.
    for _, def in ipairs(list) do
        local x, y, z, h = declaredPos(def)
        local mgr = mgrFor(def.key)
        local door, how = Doors.adoptOrCreate({
            model = def.model, x = x, y = y, z = z, heading = h,
            label = def.label or def.key, folder = def.folder,
            -- {} rather than nil: a door whose requirements left the list goes back to none.
            requirements = def.requirements or {},
        }, mgr)
        if not door then
            result.failed[def.key] = how or 'could not place the door'
        else
            result.doors[def.key] = door.doorId
            local autolock, delay = def.autolock == true, tonumber(def.autolockDelay) or 10
            if (door.autolock == true) ~= autolock or (door.autolockDelay or 10) ~= delay then
                local ok, err = Doors.update(door.doorId, { autolock = autolock, autolockDelay = delay }, mgr)
                if not ok then result.failed[def.key] = err end
            end
        end
    end

    -- The links, by key, once every door exists.
    for _, def in ipairs(list) do
        local id = result.doors[def.key]
        local door = id and doorCache[id]
        if door then
            if def.link ~= nil then
                local other = result.doors[def.link]
                if other and door.linkedDoorId ~= other then
                    local ok, err = Doors.linkDoors(id, other, mgrFor(def.key))
                    if not ok then result.failed[def.key] = err end
                end
            elseif door.linkedDoorId then
                -- A link to one of this set's own doors that neither side declares any more.
                --   * The partner is in this list: the list decides, pruning or not.
                --   * It isn't: only a whole-set declaration (prune) reads "not declared here" as
                --     "unlinked" — a partial list must not break a pair declared elsewhere in the set.
                local partner = doorCache[door.linkedDoorId]
                local pmb = partner and managerOf(partner)
                local ours = pmb ~= nil and sameManager(pmb, manager)
                local pdef = ours and pmb and seen[pmb.key] or nil
                local stale = (pdef ~= nil and pdef.link ~= def.key) or (pdef == nil and prune)
                if ours and stale then
                    local ok, err = Doors.unlinkDoors(id, mgrFor(def.key))
                    if not ok then result.failed[def.key] = err end
                end
            end
        end
    end

    -- What the list no longer names goes back.
    if prune then
        for _, door in ipairs(Doors.listManaged(manager.system, manager.id)) do
            local mb = managerOf(door)
            if mb and not seen[mb.key] then
                local ok, err = Doors.release(door.doorId, manager)
                if ok then
                    result.released = result.released + 1
                else
                    result.failed[tostring(mb.key)] = err or 'could not release the door'
                end
            end
        end
    end

    return result
end

-- ============================================
-- Proximity Query
-- ============================================

--- Doors within `range` of a point, measured FLAT — `z` is accepted and deliberately unused.
---
--- Flat on purpose: a stairwell's doors differ only in height, and a caller at the bottom of a
--- tower block should see the whole stack. `z` stays in the signature (GetDoorsNearby's callers
--- pass a full position). Doors.getByPosition DOES use z: "which door is exactly here".
---@param x number
---@param y number
---@param _ number  the z, accepted for call-site symmetry; not used
---@param range number
---@return table[]
function Doors.getNearby(x, y, _, range)
    local result = {}
    local rangeSq = range * range
    for _, door in pairs(doorCache) do
        local dx = door.x - x
        local dy = door.y - y
        if (dx * dx + dy * dy) <= rangeSq then
            result[#result + 1] = door
        end
    end
    return result
end

function Doors.getByPosition(x, y, z, tolerance)
    tolerance = tolerance or 1.0
    local tolSq = tolerance * tolerance
    for _, door in pairs(doorCache) do
        local dx = door.x - x
        local dy = door.y - y
        local dz = door.z - z
        if (dx * dx + dy * dy + dz * dz) <= tolSq then
            return door
        end
    end
    return nil
end

-- ============================================
-- Authorization
-- ============================================

function Doors.isAuthorized(source, player, door)
    local authorized, _ = Doors.isAuthorizedWithReason(source, player, door)
    return authorized
end

--- May this player open this door, and if not, why not.
---
--- Requirements are any-of: a door opens for anyone who satisfies ONE of them. The reason handed
--- back is the first one recorded (the most specific).
---
--- With `player` nil (no loaded session) the charId and item checks are skipped: fail-closed, an
--- unmatched door gets the generic refusal.
---@param source number
---@param player table|nil
---@param door table
---@return boolean authorized
---@return string|nil reason
function Doors.isAuthorizedWithReason(source, player, door)
    -- A held door is pressed by whom its holder says (nobody, until it says), whatever its row's
    -- requirements. (Not the lockpick: that reads the row's own `lockpick`.)
    local h = _holds[door.doorId]
    return Doors.requirementsMet(source, player, h and h.requirements or door.requirements)
end

--- Does this player meet a set of requirements in the door shape (normaliseRequirements)?
---
--- The door's rule, for anything that opens: a container's `requirements` are asked here too (one
--- vocabulary, one check). `noun` only changes the wording ('door' when not given).
---@param source number
---@param player table|nil
---@param req table|nil
---@param noun string|nil  'door' (default) | 'container'
---@return boolean authorized
---@return string|nil reason
function Doors.requirementsMet(source, player, req, noun)
    noun = noun or 'door'
    if not req then return true, nil end  -- no requirements = always open
    -- Empty table = no requirements (NUI may save {} instead of nil)
    if not next(req) then return true, nil end
    -- The one shape (a row written before normaliseRequirements existed may not be in it). A shape
    -- that cannot be read keeps the door shut rather than throwing on every press.
    local clean, why = normaliseRequirements(req)
    if clean == false then return false, ('This %s is misconfigured: %s'):format(noun, tostring(why)) end
    req = clean
    -- Nothing left once read (a `lockpick = false` from an older save, an empty job list): open, as
    -- `{}` is.
    if req == nil or next(req) == nil then return true, nil end

    local reasons = {}

    -- On duty with no job named: on duty anywhere (as AddAction's `onDuty` reads).
    if req.onDuty == true and not req.jobs then
        for _, pJob in pairs(Jobs.getPlayerJobs(source) or {}) do
            if pJob.clockedOn == true then return true, nil end
        end
        reasons[#reasons + 1] = 'Requires being on duty'
    end

    -- Job check. `jobs` means has a role there (employed, or the owner), on duty or not; the
    -- opt-in `onDuty = true` asks for on duty there too.
    if req.jobs then
        local playerJobs = Jobs.getPlayerJobs(source)
        for _, jobKey in ipairs(req.jobs) do
            for _, pJob in pairs(playerJobs) do
                if pJob.key == jobKey and (req.onDuty ~= true or pJob.clockedOn == true) then
                    return true, nil
                end
            end
        end
        reasons[#reasons + 1] = 'Requires job: ' .. table.concat(req.jobs, ', ')
            .. (req.onDuty == true and ' (on duty)' or '')
    end

    -- Character ID check
    if req.charIds and player then
        for _, cid in ipairs(req.charIds) do
            if cid == player.charId then return true, nil end
        end
        reasons[#reasons + 1] = 'Not authorized for this ' .. noun
    end

    -- Item check
    if req.items and player then
        for _, itemReq in ipairs(req.items) do
            -- Carried anywhere on them: the accessory strip is where a keycard lives.
            if Inventory.getItemCountAcrossContainers(player.inventory, itemReq.key) >= (itemReq.count or 1) then
                return true, nil
            end
        end
        reasons[#reasons + 1] = 'Missing required key'
    end

    -- ACE check
    if req.ace then
        if DevTools.hasAce(source, req.ace) then return true, nil end   -- developer mode for whip.devtools
        reasons[#reasons + 1] = 'Missing permission: ' .. req.ace
    end

    return false, #reasons > 0 and reasons[1]
        or (noun == 'door' and 'Door is locked' or ('This %s is locked'):format(noun))
end

-- ============================================
-- Events
-- ============================================

-- Clients never ask for doors: the projected set rides doorsSync at login and on core restart;
-- create/update/delete announce themselves; lock changes go to the door's cell (updateState) and
-- are re-pushed to anyone entering a cell (doorStatesBatch, from the ground-item sweep).

--- Every door on the server, for the Door Manager. ACE-gated: the `requirements` blocks are a map
--- of what it takes to get through every locked door in the city. The only caller is the Door
--- Manager (client/doors.lua GetAllDoorsForTool), already dev-tool-only.
SecureCallback('whip_core:getDoorAll', {
    ace       = 'whip.devtools',
    rateLimit = 1000,
    -- The manager's own edit reads three times (before, 200 ms after, and on the doorUpdated it
    -- causes): four in a burst covers one edit.
    burst     = 4,
}, function()
    return Doors.getAll()
end)

-- Client toggles door
SecureEvent('whip_core:server:doorToggle', {
    rateLimit = 500,
    -- Config.DoorInteractRange is the distance the client offers the door at, so anything beyond
    -- it plus a tolerance is no legitimate press.
    near = {
        -- Asked at each press, so a change in /whip → Settings reaches it.
        range = function() return (Config.DoorInteractRange or 3.0) + 2.0 end,
        at = function(_, _, doorId)
            local door = doorCache[doorId]
            if not door then return nil end
            return door.x, door.y, door.z
        end,
    },
    params = { {'doorId', 'id'} },
}, function(source, player, doorId)
    local door = doorCache[doorId]
    if not door then return end

    -- Authorization runs on both directions: locking someone out is a permission question too.
    local authorized, reason = Doors.isAuthorizedWithReason(source, player, door)
    if not authorized then
        -- The reason is private: broadcasting it would tell the street what the lock wants.
        ShowError(source, reason or 'Door is locked')

        -- The refusal is public: everyone near sees the door flash amber (someone rattling a handle
        -- they have no right to). Scoped as updateState scopes, with the same fallback for a door
        -- with no position. The actor is added unconditionally: the cell index is rebuilt once a
        -- second, and a player who just walked up may not be in it yet.
        local told = { [source] = true }
        TriggerClientEvent('whip_core:client:doorDenied', source, doorId, reason)
        announce('denied', { doorId = doorId, source = source, reason = reason })

        if door.x and door.y then
            for _, src in ipairs(PlayersNearPoint(door.x, door.y)) do
                if not told[src] then
                    told[src] = true
                    -- No reason for the onlookers: just the flash.
                    TriggerClientEvent('whip_core:client:doorDenied', src, doorId)
                end
            end
        else
            TriggerClientEvent('whip_core:client:doorDenied', -1, doorId)
        end
        -- Offer lockpick if enabled — only meaningful when the door is currently locked.
        if door.locked and door.requirements and door.requirements.lockpick then
            TriggerClientEvent('whip_core:client:doorLockpickOffer', source, doorId)
        end
        return
    end

    -- The linked door moves too, so it is asked too (the two leaves' requirements can disagree).
    -- Refuse the whole toggle, with the partner's reason.
    local linked = door.linkedDoorId and doorCache[door.linkedDoorId]
    if linked then
        local linkedOk, linkedReason = Doors.isAuthorizedWithReason(source, player, linked)
        if not linkedOk then
            ShowError(source, linkedReason or 'Door is locked')
            TriggerClientEvent('whip_core:client:doorDenied', source, doorId, linkedReason)
            announce('denied', { doorId = doorId, source = source, reason = linkedReason })
            RecordEventRejection('whip_core:server:doorToggle', source, 'not authorized for the linked door')
            return
        end
    end

    -- Toggle: in memory, announced to the players in range (no database write). Fails only for a
    -- door that has gone.
    local wantLocked = not door.locked
    local ok, err = Doors.updateState(doorId, wantLocked, { cause = 'press', source = source })
    if not ok then
        ShowError(source,
            ('Could not %s that door — try again'):format(wantLocked and 'lock' or 'unlock'))
        print(('[whip_core:door] toggle by %s failed on door %s: %s')
            :format(GetPlayerName(source) or '?', tostring(doorId), tostring(err)))
        return
    end

    -- Linked door, before the autolock below, so the timer captures the partner's number after it.
    if door.linkedDoorId then
        local partner = doorCache[door.linkedDoorId]
        if partner then
            Doors.updateState(partner.doorId, door.locked, { cause = 'press', source = source })
        end
    end

    -- Notify the player
    if door.locked then
        ShowSuccess(source, (door.label or 'Door') .. ' locked')
    else
        ShowSuccess(source, (door.label or 'Door') .. ' unlocked')
        -- Autolock (scheduleAutolock): either leaf's own setting counts, as for Doors.setLocked.
        -- (Not the lockpick.)
        scheduleAutolock(doorId)
        if door.linkedDoorId and doorCache[door.linkedDoorId] then scheduleAutolock(door.linkedDoorId) end
    end
end)

--- The lockpick, done where it can be believed.
---
--- A passed minigame is not a standing credential (isAuthorizedWithReason has no lockpick branch),
--- so the pick is honoured here: the minigame runs through the server-driven SkillCheck
--- (server/skillcheck.lua: a one-shot token, a minimum elapsed time, a timeout), in one handler
--- with the same near-gate as the toggle.
---
--- The item, not the flag: the client offers the prompt off HasItemFlag('lockpick'), a client-side
--- registry; the server verifies the lockpick item itself.
SecureEvent('whip_core:server:doorLockpickAttempt', {
    -- One attempt per pick animation. An honest retry can land inside it (a quick pass is ~1.5 s),
    -- so it is answered rather than dropped silently. No burst, by decision.
    rateLimit = 2500,
    onReject = function(src, reason)
        if reason == 'Rate limited' then ShowError(src, 'One moment, then try the lock again') end
    end,
    near = {
        range = function() return (Config.DoorInteractRange or 3.0) + 2.0 end,
        at = function(_, _, doorId)
            local door = doorCache[doorId]
            if not door then return nil end
            return door.x, door.y, door.z
        end,
    },
    params = { {'doorId', 'id'} },
}, function(source, player, doorId)
    local door = doorCache[doorId]
    if not door then return end

    -- Only a LOCKED door that declares itself pickable. An unlocked one needs no pick, and
    -- a door without the lockpick requirement never offered one.
    if not door.locked or not door.requirements or not door.requirements.lockpick then
        RecordEventRejection('whip_core:server:doorLockpickAttempt', source,
            'door is not locked or not pickable')
        return
    end

    if not player.inventory
        or Inventory.getItemCountAcrossContainers(player.inventory, 'lockpick') < 1 then
        return false, 'You need a lockpick'
    end

    -- The same game and difficulty as the vehicle lockpick (LockpickSkill: Config.LockpickGame, a one-second
    -- floor), judged by the server; blocks until the client answers or times out. Skill.run answers 'busy' to a
    -- second attempt while one is in flight.
    local passed = LockpickSkill(source, 'medium')
    -- Still the same session after the wait (a logout mid-pick).
    if Players[source] ~= player then return end
    if not passed then
        Log.write(player.charId, 'lockpick_fail', { detail = 'door ' .. (door.label or door.doorId) })
        ShowError(source, 'Lockpick failed')
        return
    end

    -- Re-read after the yield: the skill check took seconds, and the door may have been
    -- opened, deleted, or re-configured while the tumblers were turning.
    door = doorCache[doorId]
    if not door or not door.locked then return end
    -- And still at it, as the car lockpick asks after its wait.
    if not IsPlayerNear(source, door.x, door.y, door.z, (Config.DoorInteractRange or 3.0) + 2.0) then
        return false, 'You moved away from the door'
    end

    -- Logged once the door is really picked.
    Log.write(player.charId, 'lockpick_door', { detail = door.label or ('door #' .. door.doorId) })

    -- Fails only for a door that has gone, which the re-read above caught.
    Doors.updateState(doorId, false, { cause = 'lockpick', source = source })

    ShowSuccess(source, (door.label or 'Door') .. ' picked')
    print(('[whip_core:door] %s picked door %s (%s)')
        :format(player.fullName, tostring(doorId), door.label or 'unnamed'))

    -- The partner opens with it ONLY if it is itself pickable. A pick defeats the lock it was used
    -- on; it is not a way through a partner door whose requirements never offered one.
    local partner = door.linkedDoorId and doorCache[door.linkedDoorId]
    if partner and partner.requirements and partner.requirements.lockpick then
        Doors.updateState(door.linkedDoorId, false, { cause = 'lockpick', source = source })
    end

    -- No autolock here, on purpose: a picked door stays open (a gameplay decision).
end)

-- Door editor: create door
SecureEvent('whip_core:server:doorCreate', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'data', 'any'} },
}, function(source, player, data)
    if type(data) ~= 'table' then return end
    local door, err = Doors.create(data, player and player.charId or nil)
    if door then
        -- No broadcast here: Doors.create announces itself (projected), so the export path
        -- and this handler replicate identically.
        ShowSuccess(source, 'Door saved (#' .. door.doorId .. ')')
    elseif err then
        ShowError(source, err)
    end
end)

-- ---- The doors wizard (html/js/wp/doors.js) ----
--
-- One door set up whole: the leaf or two leaves picked in the world (tools/zones.lua, the Door Editor picking for
-- it), its name and folder, how it locks, and who can lock and unlock it. Nothing is made until Create, and a
-- double door is both leaves or neither.

--- The jobs a door can be kept for (the Access step's chips).
SecureCallback('whip_core:doorWizardJobs', {
    ace       = 'whip.devtools',
    rateLimit = 1000,
}, function()
    local out = {}
    for _, j in ipairs(Jobs.getAll()) do
        if j.key then out[#out + 1] = { key = j.key, name = j.name or j.key } end
    end
    table.sort(out, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    return out
end)

--- `data` = { leaves = { { model, x, y, z, heading } } (one, or two for a double door), label, folder?, locked
--- (false: starts unlocked), autolock, autolockDelay?, requirements? }. Answers { ok, doorIds } or { ok = false, why }.
SecureCallback('whip_core:doorWizardCreate', {
    ace       = 'whip.devtools',
    rateLimit = 1000,
    params    = { { 'data', 'any' } },
}, function(source, player, data)
    if type(data) ~= 'table' or type(data.leaves) ~= 'table' then return { ok = false, why = 'Pick the door first' } end
    if #data.leaves > 2 then return { ok = false, why = 'A door has two leaves at most' } end
    local leaves = {}
    for _, l in ipairs(data.leaves) do
        local model = type(l) == 'table' and PropertyMath.signedHash(l.model) or nil
        local x, y, z = tonumber(type(l) == 'table' and l.x), tonumber(type(l) == 'table' and l.y), tonumber(type(l) == 'table' and l.z)
        if not (model and x and y and z) then return { ok = false, why = 'A leaf has no place: pick the door again' } end
        leaves[#leaves + 1] = { model = model, x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = (tonumber(l.heading) or 0.0) + 0.0 }
    end
    if #leaves == 0 then return { ok = false, why = 'Pick the door first' } end

    local label = Sanitize.string(data.label, 100)
    if label == '' then return { ok = false, why = 'Give it a name' } end
    local folder = Sanitize.string(data.folder, 100)
    local autolock = data.autolock == true
    local delay = math.floor(Sanitize.number(data.autolockDelay, 1, 300, 10))
    -- Checked before anything is made: a refusal is said with nothing to take back.
    local req = nil
    if data.requirements ~= nil then
        local why
        req, why = normaliseRequirements(data.requirements)
        if req == false then return { ok = false, why = why } end
    end

    local made = {}
    local function undo()
        for _, id in ipairs(made) do Doors.delete(id) end
    end
    for i, l in ipairs(leaves) do
        local door, err = Doors.create({
            model = l.model, x = l.x, y = l.y, z = l.z, heading = l.heading,
            label = label, folder = folder ~= '' and folder or nil, requirements = req,
        }, player and player.charId or nil)
        if not door then
            undo()
            return { ok = false, why = (#leaves > 1 and ('Leaf %d: '):format(i) or '') .. (err or 'The door was not saved') }
        end
        made[#made + 1] = door.doorId
    end

    if #made == 2 then
        local linked, linkErr = Doors.linkDoors(made[1], made[2])
        if not linked then
            undo()
            return { ok = false, why = linkErr or 'The two leaves could not be linked' }
        end
        -- As the editor's link does (doorLink, below): only an open Door Manager has anything to repaint.
        for _, id in ipairs(made) do
            TriggerClientEvent('whip_core:client:doorUpdated', -1, id, Doors.wireOne(doorCache[id]))
        end
    end
    if autolock then
        for _, id in ipairs(made) do Doors.update(id, { autolock = true, autolockDelay = delay }) end
    end
    -- A new door is always made locked (Doors.create); one that starts open is unlocked after, both leaves at once.
    if data.locked == false then Doors.setLocked(made[1], false) end

    ShowSuccess(source, #made == 2 and ('Double door saved (#%d and #%d)'):format(made[1], made[2])
        or ('Door saved (#%d)'):format(made[1]))
    return { ok = true, doorIds = made }
end)

-- Door editor: update door
SecureEvent('whip_core:server:doorUpdate', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'doorId', 'id'}, {'updates', 'any'} },
}, function(source, _, doorId, updates)
    if type(updates) ~= 'table' then return end
    -- Doors.update announces itself (projected).
    local ok, err = Doors.update(doorId, updates)
    if not ok then
        -- A refusal is said out loud: most often a managed door, whose access is its property's.
        ShowError(source, err or 'Could not update that door')
    end
end)

-- Door editor: delete door
SecureEvent('whip_core:server:doorDelete', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'doorId', 'id'} },
}, function(source, _, doorId)
    local ok, err = Doors.delete(doorId)
    if ok then
        -- Doors.delete announces itself.
        ShowSuccess(source, 'Door deleted')
    else
        ShowError(source, err or 'Could not delete that door')
    end
end)

-- Door manager: release a door whose managing resource is gone.
--
-- The way out for a door a satellite managed and then stopped managing for good (removed, renamed).
-- While that resource runs it is asked instead; properties release their own doors.
SecureEvent('whip_core:server:doorRelease', {
    ace = 'whip.devtools',
    rateLimit = 250,
    burst     = 5,   -- releasing a gone resource's doors is a run of clicks down the list
    params = { {'doorId', 'id'} },
}, function(source, _, doorId)
    local door = doorCache[doorId]
    local mb = managerOf(door)
    if not mb then return end

    local resource = type(mb.system) == 'string' and mb.system:match('^resource:(.+)$')
    if not resource then
        ShowError(source,
            ('Door #%d belongs to %s — remove it there'):format(doorId, managerName(mb)))
        return
    end
    if GetResourceState(resource) == 'started' then
        ShowError(source,
            ('%s is running and manages door #%d — release it from %s'):format(resource, doorId, resource))
        return
    end

    local ok, err = Doors.release(doorId, mb)
    if ok then
        ShowSuccess(source, ('Door #%d released'):format(doorId))
    else
        ShowError(source, err or 'Could not release that door')
    end
end)

-- Door editor: link doors
SecureEvent('whip_core:server:doorLink', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'doorId1', 'id'}, {'doorId2', 'id'} },   -- addresses: rejected, never clamped to door #1
}, function(source, _, doorId1, doorId2)
    local linked, linkErr = Doors.linkDoors(doorId1, doorId2)
    if not linked then
        ShowError(source, linkErr or 'Could not link those doors')
    else
        -- Sent from the handler: linkedDoorId is not a wire field, so these only repaint an open
        -- Door Manager (projected, like every client-bound door payload).
        TriggerClientEvent('whip_core:client:doorUpdated', -1, doorId1, Doors.wireOne(doorCache[doorId1]))
        TriggerClientEvent('whip_core:client:doorUpdated', -1, doorId2, Doors.wireOne(doorCache[doorId2]))
        ShowSuccess(source, 'Doors linked')
    end
end)

-- Door editor: unlink a door from its partner.
SecureEvent('whip_core:server:doorUnlink', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'doorId', 'id'} },
}, function(source, _, doorId)
    local ok, errOrPartner = Doors.unlinkDoors(doorId)
    if not ok then return false, errOrPartner or 'Could not unlink that door' end
    -- As for a link: only an open Door Manager has anything to repaint.
    for _, id in ipairs({ doorId, errOrPartner }) do
        if id and doorCache[id] then
            TriggerClientEvent('whip_core:client:doorUpdated', -1, id, Doors.wireOne(doorCache[id]))
        end
    end
    ShowSuccess(source, 'Door unlinked')
end)

-- Door manager: set lock state
SecureEvent('whip_core:server:doorSetLocked', {
    ace = 'whip.devtools',
    rateLimit = 100,
    burst     = 5,
    params = { {'doorId', 'id'}, {'locked', 'bool'} },
}, function(_, _, doorId, locked)
    local ok, err = Doors.setLocked(doorId, locked)
    if not ok then return false, err end
end)

-- Door manager: toggle — the server decides the new state (a client's copy of a far door may lag).
SecureEvent('whip_core:server:doorToggleLocked', {
    ace = 'whip.devtools',
    rateLimit = 100,
    burst     = 5,
    params = { {'doorId', 'id'} },
}, function(_, _, doorId)
    local door = doorCache[doorId]
    if not door then return false, 'Door not found' end
    local ok, err = Doors.setLocked(doorId, not door.locked)
    if not ok then return false, err end
end)

-- Doors.loadAll runs in the boot list in server/player_lifecycle.lua, after Migrations.run(), with
-- the doorsSync re-push for connected players.

-- ============================================
-- Exports
-- ============================================

--- A door named by its id, or — for a door the CALLER declared (EnsureDoors / EnsureDoor) — by its
--- key: `{ key = 'office' }`, plus `set = '<id>'` when the resource declares more than one set.
---
--- A key reaches only the caller's own doors: another resource's 'office' is not it.
---@param ref number|table
---@param caller string  Registry.caller(), read before anything could yield
---@return number|nil doorId
---@return string|nil why
local function doorIdOf(ref, caller)
    if type(ref) ~= 'table' then return tonumber(ref) end
    if type(ref.key) ~= 'string' or ref.key == '' then return nil, 'a door is its id, or { key = ... }' end
    local system = 'resource:' .. tostring(caller)
    local set = ref.set ~= nil and tostring(ref.set) or nil
    for id, door in pairs(doorCache) do
        local mb = managerOf(door)
        if mb and mb.system == system and mb.key == ref.key and (set == nil or tostring(mb.id) == set) then
            return id
        end
    end
    return nil, ('you have declared no door "%s"'):format(ref.key)
end

exports('GetDoor', function(doorId)
    local id = doorIdOf(doorId, Registry.caller())
    return id and Doors.getDef(id) or nil
end)
exports('GetDoorByPosition', function(x, y, z, range)
    -- (coords, range) as well as (x, y, z, range), as GetDoorsNearby
    if type(x) == 'vector3' or type(x) == 'vector4' or type(x) == 'table' then
        local c = x
        range = y
        x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    end
    return Doors.getByPosition(x, y, z, range)
end)
exports('GetDoors', function() return Doors.getAll() end)
-- `false`, not nil, on failure — an export truncates its return list at the first nil, so
-- Doors.create's (nil, err) arrived as a bare nil. Same rule as CreateGarage.
exports('CreateDoor', function(data)
    -- Not before the doors are loaded, as EnsureDoors waits: "is a door already here" reads a grid
    -- that is empty until Doors.loadAll.
    if not WaitForCoreReady() then return false, NOT_READY end
    local taken, takeWhy = Doors.takeRequire(data, 'CreateDoor')
    if not taken then return false, takeWhy end
    local door, err, existingId = Doors.create(taken)
    if not door then return false, err or 'Could not create the door', existingId end
    return door
end)
--- A satellite's manager, as the door system sees it: the calling resource's name, never one it
--- supplies. So a resource manages only its own doors, and cannot pass itself off as a property.
--- Read first in each export, before anything can yield.
---@param manager table|nil  { id, key?, label? }
---@return table|nil
local function callerManager(manager)
    local caller = Registry.caller()
    if type(manager) ~= 'table' then return nil end
    return { system = 'resource:' .. caller, id = manager.id, key = manager.key, label = manager.label }
end

exports('UpdateDoor', function(doorId, updates, manager)
    local caller = Registry.caller()
    local mgr = callerManager(manager)
    local id, why = doorIdOf(doorId, caller)
    if not id then return false, why or 'Door not found' end
    local taken, takeWhy = Doors.takeRequire(updates, 'UpdateDoor')
    if not taken then return false, takeWhy end
    return Doors.update(id, taken, mgr)
end)
exports('DeleteDoor', function(doorId, manager)
    local caller = Registry.caller()
    local mgr = callerManager(manager)
    local id, why = doorIdOf(doorId, caller)
    if not id then return false, why or 'Door not found' end
    return Doors.delete(id, mgr)
end)

--- Take charge of the door at a spot, making it if there is none. See Doors.adoptOrCreate. Internal: a resource's
--- managed doors come from EnsureDoors and EnsureDoor.
--- `false`, not nil, on failure (an export stops at the first nil), then why, then the door in
--- the way's id when another manager holds it.
exports('__AdoptOrCreateDoor', function(data, manager)
    local mgr = callerManager(manager)   -- first: it reads the caller, before anything can yield
    if not mgr or mgr.id == nil then return false, '__AdoptOrCreateDoor needs a manager with an id' end
    -- Not before the doors are loaded (see CreateDoor).
    if not WaitForCoreReady() then return false, NOT_READY end
    local taken, takeWhy = Doors.takeRequire(data, '__AdoptOrCreateDoor')
    if not taken then return false, takeWhy end
    local door, how, conflict = Doors.adoptOrCreate(taken, mgr)
    if not door then return false, how, conflict and conflict.doorId or nil end
    return door, how
end)

--- Give a managed door back: deleted if it was made for you, restored if it was adopted. Internal, beside
--- __AdoptOrCreateDoor.
exports('__ReleaseManagedDoor', function(doorId, manager)
    local caller = Registry.caller()
    local mgr = callerManager(manager)
    if not mgr then
        if type(doorId) == 'table' then
            -- One EnsureDoor made sits in its own set, 'door:<key>'.
            return false, "A declared door is released by declaring its set without it: EnsureDoors(list, { id = setId }); one from EnsureDoor with EnsureDoors({}, { id = 'door:<key>' })"
        end
        return false, '__ReleaseManagedDoor needs the manager that holds the door'
    end
    local id, why = doorIdOf(doorId, caller)
    if not id then return false, why or 'Door not found' end
    return Doors.release(id, mgr)
end)

--- Hold a door for as long as you need it (a heist's vault): the door at that spot, saved or not
--- (a temporary one is made where there is none), in memory only. Nobody may press it until you
--- say who (SetHeldDoorAccess); it never relocks by itself; lock it with SetDoorLocked. It goes back
--- to the lock it had when you release it, when its `tag` is released (ReleaseTag), or when you
--- stop. A property's or another resource's door is refused. See "Held doors" in this file.
---     -- vaultModel / vaultPos: what the Door Editor (GetEntityModel / GetEntityCoords) reads off the door
---     local vault = exports.whip_core:HoldDoor({ model = vaultModel, x = vaultPos.x, y = vaultPos.y,
---         z = vaultPos.z }, { tag = 'heist:' .. jobId })
---@return number|false doorId
---@return string howOrWhy  'held' | 'made' | 'already', or why not
exports('HoldDoor', function(data, opts)
    local caller = Registry.caller()   -- first, before anything can yield
    if not WaitForCoreReady() then return false, NOT_READY end
    local id, how = Doors.hold(caller, data, opts)
    if not id then return false, how end
    return id, how
end)

--- Who may press a door you hold, in a door's requirements shape: { charIds = { 41, 52 } }, { jobs =
--- 'police' }, ... nil = nobody; {} = anyone.
exports('SetHeldDoorAccess', function(doorId, requirements)
    local caller = Registry.caller()
    return Doors.setHoldAccess(caller, Sanitize.id(doorId), requirements)
end)

--- Give a held door back now, the pair of HoldDoor: its old lock, or gone if it was a temporary one.
exports('ReleaseDoor', function(doorId)
    local caller = Registry.caller()
    return Doors.releaseHold(caller, Sanitize.id(doorId))
end)

--- Who holds a door: { owner, tag, doorId, made } (made = a temporary door), or nil.
exports('GetDoorHold', function(doorId)
    return Doors.holdOf(Sanitize.id(doorId))
end)

--- The doors the calling resource manages, all of them (id nil) or one thing's.
exports('GetManagedDoors', function(id)
    local system = 'resource:' .. Registry.caller()
    return Doors.listManaged(system, id)
end)

-- Declared doors wait for whip's own to be loaded (WaitForCoreReady, helpers.lua, which every
-- Ensure* uses), or a declared door couldn't see the one already at its spot.

--- The set a declaration belongs to: 'resource:<caller>' and the caller's own set id.
local function declaredManager(caller, opts)
    opts = type(opts) == 'table' and opts or {}
    local id = opts.id ~= nil and tostring(opts.id) or 'doors'
    local label = type(opts.label) == 'string' and opts.label ~= '' and opts.label or caller
    return { system = 'resource:' .. caller, id = id, label = label }, opts
end

--- Declare your doors: the list is the whole set, by key. See Doors.ensureSet.
---
---     exports.whip_core:EnsureDoors({
---         { key = 'lobby_l', model = 'v_ilev_ph_gendoor004', coords = vector4(-868.84, -1275.53, 5.10, 110.0), link = 'lobby_r' },
---         { key = 'lobby_r', model = 'v_ilev_ph_gendoor004', coords = vector4(-867.60, -1273.20, 5.10, 110.0) },
---         { key = 'office',  model = 'v_ilev_ph_gendoor', coords = vector3(-870.1, -1280.4, 5.1), requirements = { jobs = { 'realestate' } } },
---     }, { label = 'Pink Lady' })
---
--- opts: { id = 'doors' (several sets per resource), label = <resource> (the Door Manager's name for
--- it), prune = true (release the doors a key left the list for) }.
---@return table|false result  { doors = { [key] = doorId }, failed = { [key] = why }, released = n }
---@return string|nil err
exports('EnsureDoors', function(list, opts)
    local caller = Registry.caller()   -- first, before anything can yield
    local manager, o = declaredManager(caller, opts)
    if not WaitForCoreReady() then return false, NOT_READY end
    local res, err = Doors.ensureSet(list, manager, o.prune ~= false)
    if not res then
        Registry.sayRefused(caller, 'EnsureDoors: ' .. tostring(err))
    else
        for key, why in pairs(res.failed or {}) do
            Registry.sayRefused(caller, ('EnsureDoors, door "%s": %s'):format(tostring(key), tostring(why)))
        end
    end
    return res, err
end)

--- One declared door, by key: EnsureDoors for a single door, never pruning. The door, or false and why.
---
--- Its own set unless told otherwise, 'door:<key>', so an EnsureDoors call doesn't prune it. A pair
--- is declared with EnsureDoors (`link` names another key in the same call). `opts.id` puts it in a
--- set you name.
exports('EnsureDoor', function(key, data, opts)
    local caller = Registry.caller()   -- first, before anything can yield
    if type(data) ~= 'table' then return false, 'EnsureDoor(key, { model, coords, ... })' end
    local def = shallowCopy(data)
    def.key = key
    opts = type(opts) == 'table' and shallowCopy(opts) or {}
    if opts.id == nil then opts.id = 'door:' .. tostring(key) end
    local manager = declaredManager(caller, opts)
    if not WaitForCoreReady() then return false, NOT_READY end
    local res, err = Doors.ensureSet({ def }, manager, false)
    local why = (not res and err) or (res and res.failed[key]) or nil
    local id = res and res.doors[key]
    if not why and (not id or not doorCache[id]) then why = 'could not place the door' end
    if why then
        Registry.sayRefused(caller, ('EnsureDoor("%s"): %s'):format(tostring(key), tostring(why)))
        return false, why
    end
    return doorCache[id]
end)
--- Lock or unlock a door, and its linked twin if it has one.
---
--- `(ok, err)`: `false, 'Door not found'` for a door that does not exist. (Lock state is kept in
--- memory only, so there is no save to fail.)
---@param doorId number
---@param locked boolean
---@return boolean ok, string|nil err
exports('SetDoorLocked', function(doorId, locked)
    local id, why = doorIdOf(doorId, Registry.caller())
    if not id then return false, why or 'Door not found' end
    return Doors.setLocked(id, locked)
end)
--- Is this door locked? nil for a door that does not exist (`false` would read as "unlocked").
exports('IsDoorLocked', function(doorId)
    local id = doorIdOf(doorId, Registry.caller())
    local d = id and doorCache[id]
    if not d then return nil end
    return d.locked == true
end)
--- May this player open this door? `true`, or `false` and why (the reason the player is shown).
exports('CanUseDoor', function(source, doorId)
    local id, refWhy = doorIdOf(doorId, Registry.caller())
    local door = id and doorCache[id]
    if not door then return false, refWhy or 'Door not found' end
    local player = Players[source]
    local ok, why = Doors.isAuthorizedWithReason(source, player, door)
    if ok then return true end
    return false, why or 'Door is locked'
end)
exports('LinkDoors', function(doorId1, doorId2, manager)
    local caller = Registry.caller()
    local mgr = callerManager(manager)
    local id1, why1 = doorIdOf(doorId1, caller)
    if not id1 then return false, why1 or 'Door not found' end
    local id2, why2 = doorIdOf(doorId2, caller)
    if not id2 then return false, why2 or 'Door not found' end
    return Doors.linkDoors(id1, id2, mgr)
end)
--- Undo a door's link, both halves. `true` also for a door that was not linked.
exports('UnlinkDoors', function(doorId, manager)
    local caller = Registry.caller()
    local mgr = callerManager(manager)
    local id, why = doorIdOf(doorId, caller)
    if not id then return false, why or 'Door not found' end
    local ok, err = Doors.unlinkDoors(id, mgr)
    if not ok then return false, err end
    return true
end)
--- Doors near a point: `(x, y, z, range)` or `(coords, range)` — the same shapes as the client export,
--- and the same 25 m default.
exports('GetDoorsNearby', function(x, y, z, range)
    if type(x) == 'vector3' or type(x) == 'vector4' or type(x) == 'table' then
        local c = x
        range = y
        x, y, z = tonumber(c.x), tonumber(c.y), tonumber(c.z)
    end
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not (x and y and z) then return {}, 'GetDoorsNearby needs a point: (x, y, z, range) or (coords, range)' end
    return Doors.getNearby(x, y, z, tonumber(range) or 25.0)
end)

-- The coverage margin, checked once at boot (see Doors.updateState): the ground-item settings
-- decide whether door locks keep up, so lowering the stream range is said out loud.
CreateThread(function()
    local DOOR_RANGE = 50.0   -- client/doors.lua DOOR_RANGE
    local cell  = Config.GroundItemCellSize or 50
    local range = Config.GroundItemStreamRange or 100.0
    local covered = math.ceil(range / cell) * cell
    if covered < DOOR_RANGE then
        print(('[whip_core:doors] WARNING: ground-item cells reach about %dm but doors are live from %dm, so '
            .. 'door lock changes will lag for players standing at a door. Raise Config.GroundItemStreamRange.')
            :format(math.floor(covered), math.floor(DOOR_RANGE)))
    end
end)
