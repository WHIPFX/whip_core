-- ============================================
-- Zone System — Server
-- On-demand point-in-zone checks, DB persistence,
-- EnsureZone for resource-defined zones.
-- ============================================

Zones = {}

local serverZones = {}   -- [id] = zone data
local dbZones     = {}   -- [zoneId] = zone data (DB-backed zones, keyed by DB ID)
local dbZoneByKey = {}   -- [key] = 'dbzone_<n>', for the saved zones that have a key

--- A zone by its id OR its key. A saved zone's id is 'dbzone_<n>', which no resource can know in
--- advance; its key is the name a resource made it with. Saved zones first, as in every lookup here
--- (see Zones.contains), by key too, so a client's report can't shadow a saved zone.
---@param idOrKey string
---@return table|nil zone
local function resolve(idOrKey)
    if idOrKey == nil then return nil end
    return dbZones[idOrKey] or dbZones[dbZoneByKey[idOrKey] or false] or serverZones[idOrKey]
end
Zones.resolve = resolve

-- ============================================
-- Containment Math (mirrors client)
-- ============================================

local function windingNumber(points, px, py)
    local wn = 0
    local n = #points
    for i = 1, n do
        local x1 = points[i].x or points[i][1]
        local y1 = points[i].y or points[i][2]
        local j = (i % n) + 1
        local x2 = points[j].x or points[j][1]
        local y2 = points[j].y or points[j][2]
        if y1 <= py then
            if y2 > py then
                if (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1) > 0 then wn = wn + 1 end
            end
        else
            if y2 <= py then
                if (x2 - x1) * (py - y1) - (px - x1) * (y2 - y1) < 0 then wn = wn - 1 end
            end
        end
    end
    return wn
end

local function isPointInZone(zone, px, py, pz)
    if zone.type == 'sphere' then
        local dx = px - zone.pos.x
        local dy = py - zone.pos.y
        local dz = pz - zone.pos.z
        return (dx * dx + dy * dy + dz * dz) <= (zone.radius * zone.radius)
    elseif zone.type == 'box' then
        local halfZ = zone.size.z / 2
        if pz < zone.pos.z - halfZ or pz > zone.pos.z + halfZ then return false end
        local rad = math.rad(zone.heading or 0)
        local cosH, sinH = math.cos(rad), math.sin(rad)
        local dx = px - zone.pos.x
        local dy = py - zone.pos.y
        local lx = dx * cosH + dy * sinH
        local ly = -dx * sinH + dy * cosH
        return math.abs(lx) <= zone.size.x / 2 and math.abs(ly) <= zone.size.y / 2
    elseif zone.type == 'poly' then
        -- Per-vertex Z, the same rule as client/zones.lua (registerZone's poly branch): a room scanned
        -- floor by floor carries its heights on the points, not the zone. Worked out once per points
        -- table and kept: an edit replaces the table, which recomputes.
        if zone._zFor ~= zone.points then
            local perVertex = false
            local effMin, effMax = zone.minZ or math.huge, zone.maxZ or -math.huge
            for _, pt in ipairs(zone.points) do
                if pt.minZ or pt.maxZ then perVertex = true end
                local vMin = pt.minZ or zone.minZ
                local vMax = pt.maxZ or zone.maxZ
                if vMin and vMin < effMin then effMin = vMin end
                if vMax and vMax > effMax then effMax = vMax end
            end
            zone._zFor, zone._perVertexZ, zone._effMinZ, zone._effMaxZ = zone.points, perVertex, effMin, effMax
        end
        if zone._perVertexZ then
            if pz < zone._effMinZ or pz > zone._effMaxZ then return false end
        else
            if zone.minZ and pz < zone.minZ then return false end
            if zone.maxZ and pz > zone.maxZ then return false end
        end
        return windingNumber(zone.points, px, py) ~= 0
    end
    return false
end

-- ============================================
-- Registry (in-memory, for code-registered zones)
-- ============================================

--- Register a zone in the server-side registry.
---
--- Two kinds of zone live here and they are governed differently:
---
---   Server-registered (`reporter` is nil): created by server code via the RegisterZone
---   export. `_reporters` stays nil. Authoritative. Clients can never overwrite or remove one.
---
---   Client-mirrored (`reporter` is a player source): `client/zones.lua` reports every
---   locally-registered zone up so server code can query it with IsPointInZone. The SAME
---   zone is reported by EVERY player who has it (the login sync and the editor broadcast both
---   call registerZone on each client), so this is not ownership: it is a set of reports. The
---   zone survives until the last reporter is gone.
---
--- The shape most reporters agree on: each reporter's latest shape is kept (clients report moves
--- and resizes too), and the zone takes the shape the most reporters hold; a tie keeps the current
--- one. One modified client reporting a different shape is outvoted by the honest ones.

--- The fields a report carries, all taken from the elected shape.
local SHAPE_FIELDS = { 'type', 'pos', 'size', 'heading', 'radius', 'points', 'minZ', 'maxZ', 'group', 'label' }

--- Two reports of the same zone are the same shape when these agree, to the centimetre — clients
--- doing the same float maths may not agree to the last bit.
---@param g table  a sanitised report
---@return string
local function shapeSig(g)
    local function r(n) return n and ('%.2f'):format(n) or '-' end
    local pos, size = g.pos or {}, g.size or {}
    local parts = { tostring(g.type), r(pos.x), r(pos.y), r(pos.z), r(g.radius), r(size.x), r(size.y),
                    r(size.z), r(g.heading), r(g.minZ), r(g.maxZ) }
    for _, p in ipairs(g.points or {}) do
        parts[#parts + 1] = r(p.x) .. ',' .. r(p.y) .. ',' .. r(p.minZ) .. ',' .. r(p.maxZ)
    end
    return table.concat(parts, '|')
end

--- Put a report's shape on the zone. New tables, so a poly's cached heights (isPointInZone keys
--- them on the points table) are worked out again.
local function applyShape(zone, g)
    for _, f in ipairs(SHAPE_FIELDS) do zone[f] = g[f] end
    zone.pos   = zone.pos or vector3(0, 0, 0)
    zone.label = zone.label or zone.id
end

--- Take the shape the most reporters hold; the current one keeps a tie.
local function electShape(zone)
    local current = zone._shape and zone._shapes[zone._shape]
    local best, bestCount = zone._shape, current and current.count or 0
    for sig, s in pairs(zone._shapes) do
        if s.count > bestCount then best, bestCount = sig, s.count end
    end
    if best and zone._shapes[best] and best ~= zone._shape then
        zone._shape = best
        applyShape(zone, zone._shapes[best].data)
    end
end

--- Forget what one reporter said.
local function dropReport(zone, reporter)
    local sig = zone._reporters[reporter]
    if not sig then return end
    zone._reporters[reporter] = nil
    local s = zone._shapes[sig]
    if s then
        s.count = s.count - 1
        if s.count <= 0 then zone._shapes[sig] = nil end
    end
    if zone._shape == sig and not zone._shapes[sig] then zone._shape = nil end
end

---@param id string
---@param data table
---@param reporter number|nil  player source, or nil for server-registered
---@return boolean registered
function Zones.register(id, data, reporter)
    local existing = serverZones[id]

    if reporter then
        local sig = shapeSig(data)
        if existing then
            -- Server-registered zones are off limits to clients entirely.
            if not existing._reporters then return false end
            if existing._reporters[reporter] == sig then return true end   -- nothing new
            dropReport(existing, reporter)
            local s = existing._shapes[sig]
            if s then s.count = s.count + 1 else existing._shapes[sig] = { data = data, count = 1 } end
            existing._reporters[reporter] = sig
            electShape(existing)
            return true
        end
        local zone = {
            id         = id,
            _reporters = { [reporter] = sig },   -- source -> the shape they last reported
            _shapes    = { [sig] = { data = data, count = 1 } },
            _shape     = sig,
        }
        applyShape(zone, data)
        serverZones[id] = zone
        return true
    end

    local zone = {
        id = id,
        -- Server enter/exit events, for a zone the SERVER registered; a client's report
        -- does not get to make the server announce anything.
        trackPlayers = data.trackPlayers == true or nil,
        -- _reporters stays nil: server-registered, authoritative.
    }
    applyShape(zone, data)
    serverZones[id] = zone
    return true
end

--- Remove a zone.
--- A client removal only drops that player's report — the zone stays while anyone else
--- still has it (in the shape most of them now hold). Server removal (reporter nil) deletes it
--- outright.
---@param id string
---@param reporter number|nil
---@return boolean removed  true if the zone itself was deleted
---@diagnostic disable-next-line: duplicate-set-field -- the client's Zones is a different table
function Zones.remove(id, reporter)
    local existing = serverZones[id]
    if not existing then return false end

    if reporter then
        -- Clients cannot touch server-registered zones.
        if not existing._reporters then return false end
        dropReport(existing, reporter)
        if next(existing._reporters) then
            electShape(existing)
            return false   -- someone else still reports it; keep it
        end
    end

    serverZones[id] = nil
    return true
end

--- Drop a disconnecting player's reports, deleting only zones nobody else reports.
---@param source number
---@return number deleted
function Zones.removeAllForReporter(source)
    local deleted = 0
    for id, zone in pairs(serverZones) do
        if zone._reporters and zone._reporters[source] then
            dropReport(zone, source)
            if not next(zone._reporters) then
                serverZones[id] = nil
                deleted = deleted + 1
            else
                electShape(zone)
            end
        end
    end
    return deleted
end

--- How many zones a given player is currently reporting.
---@param source number
---@return number
function Zones.countForReporter(source)
    local n = 0
    for _, zone in pairs(serverZones) do
        if zone._reporters and zone._reporters[source] then n = n + 1 end
    end
    return n
end

--- Is this player already reporting this zone?
---@param id string
---@param source number
---@return boolean
function Zones.isReportedBy(id, source)
    local zone = serverZones[id]
    return (zone and zone._reporters and zone._reporters[source]) ~= nil
end

-- Containment, guarded: a malformed zone can still arrive from the DB or an old save, and this is
-- called from satellite code through an export, where a throw lands in THEIR handler. A zone whose
-- maths cannot be evaluated contains nothing; that is an answer, not an error.
local function safeContains(zone, x, y, z)
    local ok, inside = pcall(isPointInZone, zone, x, y, z)
    return ok and inside == true
end

-- Database zones first in every lookup: they are the server's own and cannot be reported by a
-- client; the mirror can (see zoneRegistered), and must not shadow a saved zone.
function Zones.contains(id, point)
    local zone = resolve(id)
    if not zone or type(point) ~= 'table' and type(point) ~= 'vector3' and type(point) ~= 'vector4' then
        return false
    end
    return safeContains(zone, point.x, point.y, point.z)
end

--- The same question, asked of the server's OWN zones only — saved ones and RegisterZone's —
--- never a client-reported mirror. For a gate: a mirror's shape is whatever its reporters said (a
--- lone modified client could make it a 2 km sphere). A zone only clients know answers false.
---@param id string
---@param point table|vector3
---@return boolean
function Zones.containsTrusted(id, point)
    local zone = resolve(id)
    if not zone or zone._reporters ~= nil then return false end
    if type(point) ~= 'table' and type(point) ~= 'vector3' and type(point) ~= 'vector4' then return false end
    return safeContains(zone, point.x, point.y, point.z)
end

function Zones.getAll()
    local result = {}
    for _, zone in pairs(serverZones) do
        result[#result + 1] = zone
    end
    for _, zone in pairs(dbZones) do
        result[#result + 1] = zone
    end
    return result
end

function Zones.getDef(id)
    return resolve(id)
end

-- ============================================
-- Query Functions
-- ============================================

--- Where a player stands as far as the world's zones are concerned, or nil: not while they are in
--- the character creator (a private bucket, at a real spot on the map) or logging out.
---
--- Routing buckets are not asked: a zone is a place, and whoever stands in it counts, in any bucket
--- (a satellite's instanced heist crew or apartment included).
---@param src number
---@param player table|nil
---@return vector3|nil
local function worldPosition(src, player)
    if not player or player._inCreator or player.closing then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped <= 0 then return nil end
    return GetEntityCoords(ped)
end

function Zones.getPlayersInZone(id)
    local zone = resolve(id)
    if not zone then return {} end
    local result = {}
    for src, player in pairs(Players) do
        local pos = worldPosition(src, player)
        if pos and safeContains(zone, pos.x, pos.y, pos.z) then
            result[#result + 1] = src
        end
    end
    return result
end

--- The vehicles in a zone: { { vehicleId, entity }, ... }. `vehicleId` is nil for a car whip does not
--- track (an ambient NPC car), and `entity` is always there.
function Zones.getVehiclesInZone(id)
    local zone = resolve(id)
    if not zone then return {} end
    local result = {}
    local allVehicles = GetAllVehicles() --[[@as integer[] ]]   -- the server native: a list
    for _, entity in ipairs(allVehicles) do
        local pos = GetEntityCoords(entity)
        if safeContains(zone, pos.x, pos.y, pos.z) then
            result[#result + 1] = { vehicleId = Vehicles.getEntityVehicleId(entity), entity = entity }
        end
    end
    return result
end

-- ============================================
-- Database Persistence
-- ============================================

function Zones.ensureTable()
    -- pcall'd like every other ensureTable.
    local ok, err = pcall(MySQL.query.await, WithTableCollation [[
        CREATE TABLE IF NOT EXISTS `zones` (
            `zoneId`    INT UNSIGNED    NOT NULL AUTO_INCREMENT,
            `key`       VARCHAR(60)     DEFAULT NULL,
            `label`     VARCHAR(100)    NOT NULL DEFAULT 'Zone',
            `type`      ENUM('box','sphere','poly') NOT NULL,
            `groupName` VARCHAR(60)     DEFAULT NULL,
            `priority`  TINYINT         NOT NULL DEFAULT 0,
            `x`         FLOAT           NOT NULL DEFAULT 0,
            `y`         FLOAT           NOT NULL DEFAULT 0,
            `z`         FLOAT           NOT NULL DEFAULT 0,
            `sizeX`     FLOAT           DEFAULT NULL,
            `sizeY`     FLOAT           DEFAULT NULL,
            `sizeZ`     FLOAT           DEFAULT NULL,
            `heading`   FLOAT           DEFAULT 0,
            `radius`    FLOAT           DEFAULT NULL,
            `points`    JSON            DEFAULT NULL,
            `minZ`      FLOAT           DEFAULT NULL,
            `maxZ`      FLOAT           DEFAULT NULL,
            `metadata`  JSON            DEFAULT NULL,
            `createdAt` TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `createdBy` INT UNSIGNED    DEFAULT NULL,
            PRIMARY KEY (`zoneId`),
            UNIQUE KEY `uk_zone_key` (`key`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
    if not ok then
        print(('[whip_core:zones] ERROR creating zones table: %s'):format(tostring(err)))
    end
    return ok
end

local function rowToZone(row)
    local zone = {
        id      = 'dbzone_' .. row.zoneId,
        zoneId  = row.zoneId,
        dbZone  = true,
        key     = row.key,
        type    = row.type,
        label   = row.label or 'Zone',
        group   = row.groupName,
        priority = row.priority or 0,
        pos     = vector3(row.x or 0, row.y or 0, row.z or 0),
        heading = row.heading or 0,
        radius  = row.radius,
        minZ    = row.minZ,
        maxZ    = row.maxZ,
    }
    if row.type == 'box' then
        zone.size = vector3(row.sizeX or 10, row.sizeY or 10, row.sizeZ or 5)
    end
    if row.type == 'poly' and row.points then
        local ok, pts = pcall(json.decode, row.points)
        zone.points = ok and pts or {}
    end
    if row.metadata then
        local ok, meta = pcall(json.decode, row.metadata)
        zone.metadata = ok and meta or {}
        if zone.metadata.rules then zone.rules = zone.metadata.rules end
        if zone.metadata.notify ~= nil then zone.notify = zone.metadata.notify end
        if zone.metadata.trackVehicles ~= nil then zone.trackVehicles = zone.metadata.trackVehicles end
        if zone.metadata.trackPlayers ~= nil then zone.trackPlayers = zone.metadata.trackPlayers end
    end
    return zone
end

--- What a DB zone carries to clients. One builder for the connect sync, the create broadcast and
--- the update broadcast, so they can't disagree.
---@param zone table
---@return table
local function zoneWire(zone)
    return {
        id            = zone.id,
        -- The key too, so a client can be asked about a saved zone by the name it was made with.
        key           = zone.key,
        type          = zone.type,
        pos           = zone.pos,
        size          = zone.size,
        heading       = zone.heading,
        radius        = zone.radius,
        points        = zone.points,
        minZ          = zone.minZ,
        maxZ          = zone.maxZ,
        group         = zone.group,
        label         = zone.label,
        priority      = zone.priority,
        rules         = zone.rules,
        notify        = zone.notify,
        trackVehicles = zone.trackVehicles,
        dbZone        = true,
    }
end

--- The metadata column: the zone's own metadata plus the fields stored inside it.
local function zoneMetaJson(zone)
    local meta = {}
    for k, v in pairs(zone.metadata or {}) do meta[k] = v end
    if zone.rules then meta.rules = zone.rules end
    if zone.notify ~= nil then meta.notify = zone.notify end
    if zone.trackVehicles ~= nil then meta.trackVehicles = zone.trackVehicles == true end
    if zone.trackPlayers ~= nil then meta.trackPlayers = zone.trackPlayers == true end
    return next(meta) and json.encode(meta) or nil
end

function Zones.loadAll()
    Zones.ensureTable()
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `zones`')
    if not ok or not rows then
        print(('[whip_core:zones] ERROR loading zones: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end
    for _, row in ipairs(rows) do
        local zone = rowToZone(row)
        dbZones[zone.id] = zone
        if zone.key then dbZoneByKey[zone.key] = zone.id end
    end
    Zones.loaded = true   -- (Zones.isSaved answers for the saved ones from now: item options ask it)
end

function Zones.saveToDb(data, createdBy)
    local pointsJson = data.points and json.encode(data.points) or nil
    -- rules, notify and trackVehicles live inside the metadata column
    local metaJson = zoneMetaJson(data)
    local ok, insertId = pcall(MySQL.insert.await,
        'INSERT INTO `zones` (`key`, `label`, `type`, `groupName`, `priority`, `x`, `y`, `z`, `sizeX`, `sizeY`, `sizeZ`, `heading`, `radius`, `points`, `minZ`, `maxZ`, `metadata`, `createdBy`) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        {
            data.key or nil,
            data.label or 'Zone',
            data.type,
            data.group or nil,
            data.priority or 0,
            data.pos and data.pos.x or 0,
            data.pos and data.pos.y or 0,
            data.pos and data.pos.z or 0,
            data.size and data.size.x or nil,
            data.size and data.size.y or nil,
            data.size and data.size.z or nil,
            data.heading or 0,
            data.radius or nil,
            pointsJson,
            data.minZ or nil,
            data.maxZ or nil,
            metaJson,
            createdBy or nil,
        }
    )
    if not ok or not insertId then
        print('[whip_core:zones] ERROR saving zone: ' .. tostring(insertId))
        return nil
    end
    -- Add to in-memory cache
    local id = 'dbzone_' .. insertId
    dbZones[id] = {
        id       = id,
        zoneId   = insertId,
        dbZone   = true,
        key      = data.key,
        type     = data.type,
        label    = data.label or 'Zone',
        group    = data.group,
        priority = data.priority or 0,
        pos      = data.pos or vector3(0, 0, 0),
        size     = data.size,
        heading  = data.heading or 0,
        radius   = data.radius,
        points   = data.points,
        minZ     = data.minZ,
        maxZ     = data.maxZ,
        rules    = data.rules,
        notify   = data.notify,
        trackVehicles = data.trackVehicles,
        trackPlayers  = data.trackPlayers,
        metadata = data.metadata,
    }
    if data.key then dbZoneByKey[data.key] = id end
    return dbZones[id]
end

--- The fields the zone editor may change. Everything else on a cached zone is identity or
--- bookkeeping: `zoneId` is the row the UPDATE writes to, `id` the key every client holds.
local EDITABLE_ZONE_FIELDS = {
    label = true, group = true, priority = true, pos = true, size = true, heading = true,
    radius = true, points = true, minZ = true, maxZ = true, rules = true, notify = true,
    trackVehicles = true, trackPlayers = true, metadata = true,
}

--- `clears` names editable fields to set to nil: leaving a key out of `updates` keeps its value (a
--- nil in a Lua table is no key at all), so EnsureZone needs a way to say "no rules any more".
---@param id string
---@param updates table
---@param clears table|nil  { [field] = true }
---@return boolean ok
function Zones.updateInDb(id, updates, clears)
    local zone = dbZones[id]
    if not zone or not zone.zoneId then return false end

    -- Staged, written, THEN applied: the cache must not describe a row the database refused.
    local staged = {}
    for k, v in pairs(zone) do staged[k] = v end
    for k, v in pairs(updates) do
        if EDITABLE_ZONE_FIELDS[k] then staged[k] = v end
    end
    for k in pairs(clears or {}) do
        if EDITABLE_ZONE_FIELDS[k] then staged[k] = nil end
    end
    local zoneOld = zone
    zone = staged

    local pointsJson = zone.points and json.encode(zone.points) or nil
    local metaJson = zoneMetaJson(zone)
    local ok, affected = pcall(MySQL.update.await,
        'UPDATE `zones` SET `label`=?, `groupName`=?, `priority`=?, `x`=?, `y`=?, `z`=?, `sizeX`=?, `sizeY`=?, `sizeZ`=?, `heading`=?, `radius`=?, `points`=?, `minZ`=?, `maxZ`=?, `metadata`=? WHERE `zoneId`=?',
        {
            zone.label, zone.group, zone.priority or 0,
            zone.pos and zone.pos.x or 0, zone.pos and zone.pos.y or 0, zone.pos and zone.pos.z or 0,
            zone.size and zone.size.x or nil, zone.size and zone.size.y or nil, zone.size and zone.size.z or nil,
            zone.heading or 0, zone.radius or nil, pointsJson, zone.minZ, zone.maxZ,
            metaJson,
            zone.zoneId,
        }
    )
    if not ok then
        print(('[whip_core:zones] ERROR updating zone %s: %s'):format(tostring(id), tostring(affected)))
        return false
    end

    -- Written — now the cache may say so. Replaced in place so anything holding the old table
    -- (the editor's view of it) sees the same object change.
    for k in pairs(zoneOld) do zoneOld[k] = nil end
    for k, v in pairs(zone) do zoneOld[k] = v end
    return true
end

function Zones.deleteFromDb(id)
    local zone = dbZones[id]
    if not zone or not zone.zoneId then return false, 'Zone not found' end
    -- Checked, as update is: a failed delete keeps the zone in memory.
    local ok, err = pcall(MySQL.query.await, 'DELETE FROM `zones` WHERE `zoneId` = ?', { zone.zoneId })
    if not ok then
        print(('[whip_core:zones] ERROR deleting zone %s: %s'):format(tostring(id), tostring(err)))
        return false, 'Database error — the zone was not deleted'
    end
    if zone.key and dbZoneByKey[zone.key] == id then dbZoneByKey[zone.key] = nil end
    dbZones[id] = nil
    return true
end

function Zones.getByKey(key)
    local id = key ~= nil and dbZoneByKey[key]
    return id and dbZones[id] or nil
end

--- Is this a SAVED zone (by id or key) — one every client has and the server trusts? The only kind an
--- action's `require` may name on the server (server/requirements.lua).
---@param idOrKey any
---@return boolean
function Zones.isSaved(idOrKey)
    if idOrKey == nil then return false end
    return dbZones[idOrKey] ~= nil or dbZoneByKey[idOrKey] ~= nil
end

-- ============================================
-- EnsureZone: a resource's saved zone, by key
-- ============================================
--
-- A resource declares a zone by a key it chooses; whip saves it and gives every client it.
--
-- The declaration decides, when it changes. Each zone remembers the declaration it was last made
-- from (metadata.ensured = { by, decl }). Same declaration again: nothing is written, so an admin's
-- edits in the zone editor stand. A different one: the resource was edited, and its zone follows.
-- A key another RUNNING resource declared is refused; a key from a stopped one, or made in the
-- editor, is taken over.

local ZONE_KEY_PATTERN = '^[%w_%-%.:]+$'

--- A declared number, to the millimetre. A vector's parts are single floats (100.3 is
--- 100.30000305...), and the declaration makes a trip through JSON: unrounded, the same zone read
--- back would never equal itself.
local function mm(n)
    n = tonumber(n)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.floor(n * 1000 + 0.5) / 1000
end

local function plainVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return { x = mm(v.x), y = mm(v.y), z = mm(v.z) } end
    if t == 'table' then
        local x, y, z = mm(v.x or v[1]), mm(v.y or v[2]), mm(v.z or v[3])
        if x and y then return { x = x, y = y, z = z or 0.0 } end
    end
    return nil
end

--- A zone declaration as plain values — what is compared to tell whether a resource changed its
--- zone. nil and why for one that cannot be a zone.
---@return table|nil decl
---@return string|nil why
local function declaration(data)
    if type(data) ~= 'table' then
        return nil, 'a zone is a table: { type, pos, size | radius | points, ... }'
    end
    local t = data.type
    if t ~= 'box' and t ~= 'sphere' and t ~= 'poly' then return nil, "type is 'box', 'sphere' or 'poly'" end
    local d = { type = t }
    if t == 'poly' then
        if type(data.points) ~= 'table' or #data.points < 3 then return nil, 'a poly needs at least 3 points' end
        d.points = {}
        for i, p in ipairs(data.points) do
            local v = plainVec(p)
            if not v then return nil, ('point %d is not a position'):format(i) end
            -- With its own heights: per-point minZ/maxZ are a zone feature both containment paths read.
            local pMin = type(p) == 'table' and mm(p.minZ) or nil
            local pMax = type(p) == 'table' and mm(p.maxZ) or nil
            d.points[i] = { x = v.x, y = v.y, minZ = pMin, maxZ = pMax }
        end
        d.pos = plainVec(data.pos)
    else
        d.pos = plainVec(data.pos)
        if not d.pos then return nil, ('a %s needs pos'):format(t) end
        if t == 'box' then
            d.size = plainVec(data.size)
            if not d.size then return nil, 'a box needs size' end
            d.heading = mm(data.heading) or 0
        else
            d.radius = mm(data.radius)
            if not d.radius or not (d.radius > 0) then return nil, 'a sphere needs a radius' end
        end
    end
    d.minZ, d.maxZ = mm(data.minZ), mm(data.maxZ)
    if type(data.label) == 'string' and data.label ~= '' then d.label = data.label end
    if type(data.group) == 'string' and data.group ~= '' then d.group = data.group end
    d.priority = tonumber(data.priority)
    if type(data.rules) == 'table' then d.rules = data.rules end
    if data.notify ~= nil then d.notify = data.notify end
    if data.trackVehicles ~= nil then d.trackVehicles = data.trackVehicles == true end
    if data.trackPlayers ~= nil then d.trackPlayers = data.trackPlayers == true end
    return d
end

--- What saveToDb / updateInDb take, from a declaration.
local function zoneFields(key, d)
    return {
        key = key, type = d.type,
        label = d.label or key, group = d.group, priority = d.priority or 0,
        pos = d.pos and vector3(d.pos.x, d.pos.y, d.pos.z) or vector3(0, 0, 0),
        size = d.size and vector3(d.size.x, d.size.y, d.size.z) or nil,
        heading = d.heading or 0, radius = d.radius, points = d.points, minZ = d.minZ, maxZ = d.maxZ,
        rules = d.rules, notify = d.notify, trackVehicles = d.trackVehicles, trackPlayers = d.trackPlayers,
    }
end

--- The optional fields a declaration can drop, cleared when it has.
local CLEARABLE = { 'group', 'size', 'radius', 'points', 'minZ', 'maxZ', 'rules', 'notify',
                    'trackVehicles', 'trackPlayers' }

---@param key string
---@param data table
---@param caller string|nil  the declaring resource
---@return table|false zone
---@return string|nil reason
function Zones.ensureZone(key, data, caller)
    if type(key) ~= 'string' or #key > 60 or not key:match(ZONE_KEY_PATTERN) then
        return false, 'a zone key is letters, digits, _ - . and :, at most 60'
    end
    local d, why = declaration(data)
    if not d then return false, why end
    caller = caller or GetCurrentResourceName()

    local existing = Zones.getByKey(key)
    if existing then
        local ens = type(existing.metadata) == 'table' and existing.metadata.ensured or nil
        local by = type(ens) == 'table' and ens.by or nil
        if by and by ~= caller and Registry.alive(by) then
            return false, ('zone "%s" is declared by %s'):format(key, by)
        end
        -- The same declaration as last time: an admin's edits since then stand.
        if by == caller and type(ens) == 'table' and Registry.deepEquals(ens.decl, d) then return existing end

        if existing.type == d.type then
            local fields = zoneFields(key, d)
            fields.key, fields.type = nil, nil
            local meta = {}
            for k, v in pairs(existing.metadata or {}) do meta[k] = v end
            -- These live in the metadata column as well; the declaration's own values are written
            -- from the fields, so a stale copy here must not survive them.
            meta.rules, meta.notify, meta.trackVehicles, meta.trackPlayers = nil, nil, nil, nil
            meta.ensured = { by = caller, decl = d }
            fields.metadata = meta
            local clears = {}
            for _, f in ipairs(CLEARABLE) do
                if fields[f] == nil then clears[f] = true end
            end
            if not Zones.updateInDb(existing.id, fields, clears) then
                return false, 'the zone could not be saved'
            end
            local zone = dbZones[existing.id]
            TriggerClientEvent('whip_core:client:zoneDbUpdated', -1, zone.id, zoneWire(zone))
            return zone
        end

        -- A different type is a different row shape: the old zone goes, and a new one is made
        -- under the same key (a new 'dbzone_<n>' — ask for it by key).
        local ok, err = Zones.deleteFromDb(existing.id)
        if not ok then return false, err end
        TriggerClientEvent('whip_core:client:zoneDbDeleted', -1, existing.id)
    end

    local fields = zoneFields(key, d)
    fields.metadata = { ensured = { by = caller, decl = d } }
    local zone = Zones.saveToDb(fields)
    if not zone then return false, 'the zone could not be saved' end
    -- Told to everyone already in the game, like an editor-created zone (the connect sync covers
    -- only those who join after).
    TriggerClientEvent('whip_core:client:zoneDbCreated', -1, zoneWire(zone))
    return zone
end

--- Delete a saved zone, by key or id. A zone another
--- RUNNING resource declared is refused: it would be made again the next time that resource starts.
---@param keyOrId string
---@param caller string|nil
---@return boolean ok
---@return string|nil reason
function Zones.deleteZone(keyOrId, caller)
    local zone = resolve(keyOrId)
    if not zone then return false, 'Zone not found' end
    if not zone.dbZone then
        return false, 'not a saved zone — RemoveZone removes your own server zones'
    end
    local ens = type(zone.metadata) == 'table' and zone.metadata.ensured or nil
    local by = type(ens) == 'table' and ens.by or nil
    if by and caller and by ~= caller and Registry.alive(by) then
        return false, ('zone "%s" is declared by %s'):format(tostring(zone.key or zone.id), by)
    end
    local ok, err = Zones.deleteFromDb(zone.id)
    if not ok then return false, err end
    TriggerClientEvent('whip_core:client:zoneDbDeleted', -1, zone.id)
    return true
end

-- ============================================
-- Sync persistent zones to connecting clients
-- ============================================

function Zones.getDbZonesForSync()
    local result = {}
    for _, zone in pairs(dbZones) do
        result[#result + 1] = zoneWire(zone)
    end
    return result
end

-- ============================================
-- Events (sync from client + editor)
-- ============================================

-- Cap on how many distinct zones one player may be reporting. Without it a client can
-- register unbounded zones, and every one costs memory plus work in getPlayersInZone.
-- Generous: a busy server legitimately has hundreds of resource-defined zones, and every
-- player reports all of them.
local MAX_CLIENT_ZONES_PER_SOURCE = 500

--- Largest poly a client may report. The room scanner simplifies with Douglas-Peucker before
--- registering, so an honest zone is dozens of points; this cap only exists so a hostile one
--- cannot be thousands.
local MAX_POLY_POINTS = 256

--- A finite number, or nil. NaN and the infinities pass tonumber and then poison every
--- comparison they touch, so they die here.
local function finiteNumber(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

--- A world coordinate that could plausibly be on or near the map.
local function worldCoord(v, lo, hi)
    v = finiteNumber(v)
    if not v or v < lo or v > hi then return nil end
    return v
end

--- Something .x can be read from without erroring: a table, or one of the vector types.
local function indexable(v)
    local t = type(v)
    return t == 'table' or t == 'vector3' or t == 'vector4'
end

--- Rebuild a zone as a FRESH table of verified fields, or refuse it and say why.
---
--- The wire schema is {'data','any'}, because a zone is a union of three shapes no param type
--- describes, so everything in it is untyped until this runs. isPointInZone does arithmetic on
--- these fields, and unknown keys must not ride into the registry: field-by-field reconstruction,
--- nothing unverified survives, in value or in key.
---
--- Server zones too: RegisterZone reads the shape here as well, and the caller hears what
--- was wrong.
---@param data table
---@return table|nil zone
---@return string|nil why
local function readZoneShape(data)
    local ztype = data.type
    if ztype ~= 'sphere' and ztype ~= 'box' and ztype ~= 'poly' then
        return nil, "type is 'sphere', 'box' or 'poly'"
    end

    local out = {
        type  = ztype,
        group = type(data.group) == 'string' and data.group:sub(1, 60) or nil,
        label = type(data.label) == 'string' and data.label:sub(1, 80) or nil,
    }

    if ztype == 'sphere' or ztype == 'box' then
        if not indexable(data.pos) then return nil, 'pos is a vector3: where the zone is' end
        local x = worldCoord(data.pos.x, -16000, 16000)
        local y = worldCoord(data.pos.y, -16000, 16000)
        local z = worldCoord(data.pos.z, -5000, 5000)
        if not x or not y or not z then return nil, 'pos is off the map' end
        out.pos = vector3(x, y, z)
    end

    if ztype == 'sphere' then
        local radius = finiteNumber(data.radius)
        if not radius or radius <= 0 or radius > 2000 then return nil, 'radius is a number of metres, above 0 and at most 2000' end
        out.radius = radius

    elseif ztype == 'box' then
        if not indexable(data.size) then return nil, 'size is a vector3: the box\'s width, length and height' end
        local sx = finiteNumber(data.size.x)
        local sy = finiteNumber(data.size.y)
        local sz = finiteNumber(data.size.z)
        if not sx or sx <= 0 or sx > 4000 or not sy or sy <= 0 or sy > 4000 or not sz or sz <= 0 or sz > 4000 then
            return nil, 'size is metres above 0 and at most 4000 on each side'
        end
        out.size = vector3(sx, sy, sz)
        local heading = finiteNumber(data.heading)
        out.heading = heading or 0.0

    else -- poly
        if type(data.points) ~= 'table' then return nil, 'points is a list of { x, y }' end
        local n = #data.points
        if n < 3 or n > MAX_POLY_POINTS then return nil, ('a poly has 3 to %d points'):format(MAX_POLY_POINTS) end
        local points = {}
        for i = 1, n do
            local p = data.points[i]
            if not indexable(p) then return nil, ('point %d is { x, y }'):format(i) end
            -- Both spellings the containment math reads, normalised to one.
            local px = worldCoord(p.x or p[1], -16000, 16000)
            local py = worldCoord(p.y or p[2], -16000, 16000)
            if not px or not py then return nil, ('point %d is off the map'):format(i) end
            -- Per-vertex heights survive the copy: the containment check reads them.
            points[i] = { x = px, y = py,
                          minZ = worldCoord(p.minZ, -5000, 5000),
                          maxZ = worldCoord(p.maxZ, -5000, 5000) }
        end
        out.points = points
        out.minZ = worldCoord(data.minZ, -5000, 5000)
        out.maxZ = worldCoord(data.maxZ, -5000, 5000)
        if out.minZ and out.maxZ and out.maxZ < out.minZ then return nil, 'maxZ is below minZ' end
    end

    return out
end

--- A client mirrors a locally-registered zone up so server code can query it.
---
--- What the mirror is, stated plainly: the shape most of its reporters hold (see
--- Zones.register — a move or resize is reported again, with this same event). A hostile client
--- is outvoted by the honest ones, but a zone only it reports is whatever it says. Server code
--- that must not be lied to registers its zones server-side (RegisterZone / EnsureZone) —
--- those are off limits to clients entirely; the mirror is a convenience view of client-side
--- zones and should be trusted exactly as far as its reporters. The same caveat applies to zone
--- RULES (noPvP, speed limits, eject): they are enforced by each client on itself, in
--- client/zones.lua, and a modified client simply ignores them.
SecureEvent('whip_core:server:zoneRegistered', {
    whileDead = true,   -- mirroring the client's zones, not an action (dead players are refused by default)
    rateLimit = 50,
    burst     = 100,  -- a client reports its entire zone set in one go on spawn
    requirePlayer = false,
    params = {
        {'id', 'key', 60},
        {'data', 'any'},
    },
}, function(source, _, id, data)
    if type(data) ~= 'table' then return end

    -- Not a database zone's id: those are the server's own ('dbzone_<n>'), and clients never report
    -- them (see the _dbZone guard in client/zones.lua). Nor a saved zone's key: a report under it is
    -- about the server's zone, and nothing a client should be able to file.
    if dbZones[id] or dbZoneByKey[id] or id:sub(1, 7) == 'dbzone_' then
        RecordEventRejection('whip_core:server:zoneRegistered', source, 'reserved zone id')
        return
    end

    -- Only count against the cap when this would be a NEW zone for this player.
    if not Zones.isReportedBy(id, source)
        and Zones.countForReporter(source) >= MAX_CLIENT_ZONES_PER_SOURCE then
        return
    end

    -- Verified geometry or nothing. See readZoneShape.
    local clean, bad = readZoneShape(data)
    if not clean then
        RecordEventRejection('whip_core:server:zoneRegistered', source,
            'zone data failed validation: ' .. tostring(bad))
        return
    end

    Zones.register(id, clean, source)
end)

SecureEvent('whip_core:server:zoneRemoved', {
    whileDead = true,
    rateLimit = 50,
    burst     = 100,
    requirePlayer = false,
    params = { {'id', 'key', 60} },
}, function(source, _, id)
    -- Drops only THIS player's report. The zone stays while any other player still has it, and
    -- server-registered zones are untouchable. Nothing is broadcast: one client tidying up its
    -- local mirror must not tell everyone else to delete the zone.
    Zones.remove(id, source)
end)

-- Editor: create persistent zone
SecureEvent('whip_core:server:zeCreateZone', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'data', 'any'} },
}, function(source, player, data)
    local src = source
    if type(data) ~= 'table' then return false, 'Nothing to create' end
    local zone = Zones.saveToDb(data, player and player.charId or nil)
    if zone then
        -- Broadcast to all clients
        TriggerClientEvent('whip_core:client:zoneDbCreated', -1, zoneWire(zone))
        ShowSuccess(src, 'Zone created (#' .. zone.zoneId .. ')')
    else
        -- Said, not silent: a save that failed tells the admin.
        return false, 'The zone was not saved — see the server console'
    end
end)

-- Editor: update zone (DB or memory)
SecureEvent('whip_core:server:zeUpdateZone', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'id', 'key', 60}, {'updates', 'any'} },
}, function(_, _, id, updates)
    if type(updates) ~= 'table' then return end
    -- `clear`: editable fields to take off (the /whip Zones wizard's "no group any more").
    -- A nil sent from the page arrives as no key at all, so it cannot say that on its own.
    local clears = nil
    if type(updates.clear) == 'table' then
        clears = {}
        for _, k in ipairs(updates.clear) do
            if type(k) == 'string' and EDITABLE_ZONE_FIELDS[k] then clears[k] = true end
        end
    end
    updates.clear = nil
    -- Try DB zone first
    if dbZones[id] then
        if not Zones.updateInDb(id, updates, clears) then
            return false, 'Zone update was not saved'   -- shown and recorded
        end
        TriggerClientEvent('whip_core:client:zoneDbUpdated', -1, id, zoneWire(dbZones[id]))
    else
        -- Memory-only zone: update server registry and broadcast to all clients, the editable fields
        -- only, as the saved branch takes them (never `_reporters`, `type` or the id).
        local clean = {}
        for k, v in pairs(updates) do
            if EDITABLE_ZONE_FIELDS[k] then clean[k] = v end
        end
        -- The cleared names go too, here and on every client (`clear`, which zoneDbUpdated reads) —
        -- the plain ones only: a script's zone without its shape or rules is no zone.
        local cleared = {}
        for k in pairs(clears or {}) do
            if (k == 'group' or k == 'label') and clean[k] == nil then cleared[#cleared + 1] = k end
        end
        if next(clean) == nil and #cleared == 0 then return false, 'Nothing the editor may change' end
        if serverZones[id] then
            for k, v in pairs(clean) do serverZones[id][k] = v end
            for _, k in ipairs(cleared) do serverZones[id][k] = nil end
        end
        if #cleared > 0 then clean.clear = cleared end
        TriggerClientEvent('whip_core:client:zoneDbUpdated', -1, id, clean)
    end
end)

-- Editor: delete persistent zone
SecureEvent('whip_core:server:zeDeleteZone', {
    ace = 'whip.devtools',
    rateLimit = 250,
    params = { {'id', 'key', 60} },
}, function(source, _, id)
    local ok, err = Zones.deleteFromDb(id)
    if not ok then return false, err or 'Zone not deleted' end   -- shown and recorded
    TriggerClientEvent('whip_core:client:zoneDbDeleted', -1, id)
    ShowSuccess(source, 'Zone deleted')
end)

-- ============================================
-- Players entering and leaving, on the SERVER
-- ============================================
--
-- The client's own zoneEnter/zoneExit can't be believed by a server. A zone that sets `trackPlayers = true`
-- (RegisterZone or EnsureZone) is swept here every Config.ZoneTrackInterval ms:
--
--     AddEventHandler('whip_core:zone:entered', function(e) end)   -- { zoneId, key?, source }
--     AddEventHandler('whip_core:zone:exited',  function(e) end)   -- { zoneId, key?, source, dropped?, removed? }
--
-- Local server events, from the server's own reading of each ped's position. `dropped` is a player
-- who left the server while inside; `removed` a zone that went while players were in it. Nothing is
-- swept while no zone asks, and each sweep reads every player's position once.

local tracking = {}   -- [zoneId] = { [source] = true }: inside at the last sweep
-- [zoneId] = its key at the last sweep: the exit for a zone that has just gone (deleted, or
-- replaced by a type-changing EnsureZone) has nothing else left to read the key from.
local trackedKey = {}

-- Core's own hook, before the event (the Character.onLife / Vehicles.onLife rule): the Systems Creator's
-- "When a player enters an area" listens here, never to the public event, which any resource can fire.
local trackHooks = {}

--- Run `fn(kind, payload)` whenever the sweep finds a player entering or leaving a tracked zone: kind
--- 'entered' { zoneId, key, source } or 'exited' { zoneId, key, source, dropped?, removed? }. For
--- whip_core's own files; a hook must not wait.
---@param fn fun(kind: string, payload: table)
function Zones.onTrack(fn)
    trackHooks[#trackHooks + 1] = fn
end

local function announceTrack(kind, payload)
    for _, fn in ipairs(trackHooks) do
        local ok, err = pcall(fn, kind, payload)
        if not ok then print(('[whip_core:zones] a tracking hook errored: %s'):format(tostring(err))) end
    end
    WhipEmit('whip_core:zone:' .. kind, payload)
end

local function emitExit(zone, id, src, extra)
    local payload = { zoneId = id, key = (zone and zone.key) or trackedKey[id], source = src }
    if extra then for k, v in pairs(extra) do payload[k] = v end end
    announceTrack('exited', payload)
end

-- On Every (lifecycle.lua), so one error doesn't end zone tracking.
Every('zone tracking', function() return tonumber(Config.ZoneTrackInterval) or 1000 end, function()
    local watched = {}
    for id, zone in pairs(serverZones) do
        if zone.trackPlayers == true and not zone._reporters then watched[id] = zone end
    end
    for id, zone in pairs(dbZones) do
        if zone.trackPlayers == true then watched[id] = zone end
    end

    -- A zone that went (or stopped asking) with players still in it says they left.
    for id, inside in pairs(tracking) do
        if not watched[id] then
            for src in pairs(inside) do emitExit(resolve(id), id, src, { removed = true }) end
            tracking[id] = nil
            trackedKey[id] = nil
        end
    end

    if next(watched) then
        local positions = {}
        for src, player in pairs(Players) do
            positions[src] = worldPosition(src, player)   -- nil in the creator / logging out
        end
        for id, zone in pairs(watched) do
            local before = tracking[id] or {}
            local now = {}
            for src, pos in pairs(positions) do
                if safeContains(zone, pos.x, pos.y, pos.z) then
                    now[src] = true
                    if not before[src] then
                        announceTrack('entered', { zoneId = id, key = zone.key, source = src })
                    end
                end
            end
            for src in pairs(before) do
                if not now[src] then emitExit(zone, id, src) end
            end
            tracking[id] = now
            trackedKey[id] = zone.key
        end
    end
end)

-- Drop a disconnecting player's mirrored zones, and say
-- they left the tracked zones they were in.
AddEventHandler('playerDropped', function()
    local src = source
    Zones.removeAllForReporter(src)
    for id, inside in pairs(tracking) do
        if inside[src] then
            inside[src] = nil
            emitExit(resolve(id), id, src, { dropped = true })
        end
    end
end)

-- ============================================
-- Zone Authorization + Debug Overlay Callbacks
-- ============================================

--- Does the CALLER hold this ACE? Gameplay, not a dev tool: the client asks on entering an
--- ACE-whitelisted zone to decide whether it should eject itself, so this cannot be gated
--- behind whip.devtools. It answers only about the asker, which is what keeps it from being
--- an oracle for anyone else's permissions.
---
--- The burst matters more than the rate: a rejection reaches the client as `false, reason`, false
--- reads as "not allowed", and "not allowed" ejects. Crossing several whitelisted boundaries in quick
--- succession is legitimate driving, not a flood, and must never be the thing that throws a
--- player out of a zone they are entitled to stand in.
SecureCallback('whip_core:checkAcePermission', {
    whileDead = true,   -- a permission question, not an action
    rateLimit = 250,
    burst     = 4,
    params    = { {'aceName', 'string', 64} },
}, function(source, _, aceName)
    -- whip.devtools is answered with developer mode (DevTools.hasAce): an admin who has not turned it on
    -- is treated as not holding it — the F1 wheel's admin actions, an admin-only zone.
    return DevTools.hasAce(source, aceName)
end)

--- Server id → character name, for the zone debug overlay's player list. Dev-gated: ungated, it
--- would be a walk-the-ids roster builder.
---
--- The burst is sized to the client's fan-out: refreshCharNameCache fires one lookup per
--- uncached player in a single tick, so a flat cooldown would fill the cache one name per
--- interval and make the overlay look broken on a busy server.
SecureCallback('whip_core:getCharName', {
    ace       = 'whip.devtools',
    rateLimit = 100,
    burst     = 16,
    -- 'id' rather than 'int': the int type CLAMPS, and an id is an address. 'id' rejects instead.
    params    = { {'targetSource', 'id'} },
}, function(_, _, targetSource)
    local target = Players[targetSource]
    -- `false, why`, whip's refusal
    if not target or not target.fullName then return false, 'No character loaded for that player' end
    return target.fullName
end)

-- (Zones.loadAll runs from player_lifecycle.lua's startup sequence, after the migrations.)

-- ============================================
-- Exports
-- ============================================

-- A server zone belongs to the resource that registered it, and goes when that resource stops —
-- the one registration rule (shared/registry.lua). The registry holds WHO owns each id; the zone
-- itself lives in serverZones with the client-mirrored ones. A second resource registering the same
-- id is refused, and RemoveZone removes the caller's own only.
local _zoneIds = Registry.new('ServerZone', {
    label    = 'server zone',
    prefixed = true,    -- one list for the server (shared/registry.lua)
    same     = false,   -- the same owner registering again always re-applies the geometry
    releaseOrder = 90,  -- a run's areas go last, after everything that stood in them
    onRemove = function(id) Zones.remove(id) end,
})

--- Register a server-side zone. Returns (true) or (false, reason).
exports('RegisterZone', function(id, data)
    local owner = Registry.caller()   -- first, before anything can yield
    -- The client's RegisterZone(data) makes up its own id; the server's takes yours first. Said plainly, as shared
    -- code calling the client form here is the likely mistake.
    if type(id) == 'table' and data == nil then
        return false, "the server's RegisterZone takes (id, data): an id of your own first, then the zone"
    end
    if type(data) ~= 'table' then return false, 'RegisterZone: data must be a table' end
    -- The shape read as a client's report is: a zone nothing can ever be inside is refused
    -- with what was wrong, not stored. trackPlayers is a server zone's own word.
    local shape, bad = readZoneShape(data)
    if not shape then return false, ('RegisterZone "%s": %s'):format(tostring(id), bad) end
    shape.trackPlayers = data.trackPlayers == true or nil

    -- data.tag: a run's area, removed by ReleaseTag with the rest of the run.
    local ok, why = _zoneIds:add(owner, id, true, data.tag ~= nil and { tag = data.tag } or nil)
    if not ok then return false, why end
    if not Zones.register(id, shape) then
        _zoneIds:remove(owner, id)
        return false, ('zone "%s" could not be registered'):format(tostring(id))
    end
    return true
end)

--- Remove one of YOUR server zones. Returns (true) or (false, reason).
exports('RemoveZone', function(id)
    local owner = Registry.caller()   -- first, before anything can yield
    return _zoneIds:remove(owner, id)
end)
--- Is `point` inside zone `id`? `trusted = true` reads only a zone the SERVER holds (a saved zone, or
--- one made with RegisterZone) and says false for a client-made one — the question to ask for
--- anti-cheat. Without it, a client-made zone counts as its players report it.
exports('IsPointInZone', function(id, point, trusted)
    if trusted == true then return Zones.containsTrusted(id, point) end
    return Zones.contains(id, point)
end)
exports('GetPlayersInZone', function(id) return Zones.getPlayersInZone(id) end)
exports('GetVehiclesInZone', function(id) return Zones.getVehiclesInZone(id) end)
exports('GetZones', function() return Zones.getAll() end)
exports('GetZone', function(id) return Zones.getDef(id) end)
--- A saved zone, declared by key: made, or brought up to date when the declaration changed.
--- The zone, or false and why. See Zones.ensureZone. Waits for whip_core to finish starting.
exports('EnsureZone', function(key, data)
    local caller = Registry.caller()   -- first, before anything can yield
    if not WaitForCoreReady() then return false, NOT_READY end
    local zone, why = Zones.ensureZone(key, data, caller)
    if not zone then Registry.sayRefused(caller, ('EnsureZone("%s"): %s'):format(tostring(key), tostring(why))) end
    return zone, why
end)
--- Delete a saved zone by key or id. (true) or (false, reason).
exports('DeleteZone', function(keyOrId)
    local caller = Registry.caller()
    return Zones.deleteZone(keyOrId, caller)
end)
