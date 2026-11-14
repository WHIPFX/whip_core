-- ============================================
-- PROPERTY OBJECTS — the furniture, Server
-- ============================================
--
-- One row per placed object, owned by a property, spawned client-side and non-networked (as
-- housing's furniture was, and containers' props are): no server entities, no network cost, and
-- everyone who walks in spawns their own copy from the same rows.
--
-- STORED IN THE INTERIOR'S OWN SPACE. A row is { model, lx, ly, lz, rx, ry, rz } relative to the
-- property's placement, and world space is worked out when it is used: world = placement + local,
-- and a world heading is rz + yaw (GTA's rotation order 2 applies Z last, so the placement's turn
-- simply adds to it). A property re-bound to a moved interior takes its furniture with it.
--
-- FETCHED ON APPROACH, NOT SENT AT LOGIN. Housing sent every room's furniture to every player at
-- login — a few KB then, several MB at four hundred furnished properties. Now login carries one
-- number per property (a version), and a client asks for a room's rows when that property streams
-- in, and again only when its version changes.
--
-- BOUNDED BY THE SPACE. Every object must sit inside the property's space (with 0.3 m of give for
-- things pushed against a wall), so furniture cannot be put across the street or in a neighbour's
-- flat — the question housing answered with "within 30 m of one point".
--
-- WHAT A CLIENT IS TRUSTED WITH: nothing it names goes in unchecked. The model is checked against
-- prop_catalog, the count against the property's limit, every position against the space.

PropertyObjects = {}

local _rows    = {}   -- [propertyId] = { row, ... }  (local coordinates)
local _version = {}   -- [propertyId] = number, bumped on every save
local _saving  = {}   -- [propertyId] = true while a save is being written (PropertyObjects.replace)

--- How much give the space has for furniture, on every side.
local SLACK = 0.3

-- ============================================
-- Database
-- ============================================

---@return boolean ok
function PropertyObjects.ensureTable()
    -- A property's furniture goes when the property does; a stash that goes leaves its piece holding nothing.
    return CreateTable('property_objects', [[
        CREATE TABLE IF NOT EXISTS `property_objects` (
            `objectId`   INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `propertyId` INT UNSIGNED NOT NULL,
            `model`      VARCHAR(80)  NOT NULL,
            `lx`         FLOAT        NOT NULL DEFAULT 0,
            `ly`         FLOAT        NOT NULL DEFAULT 0,
            `lz`         FLOAT        NOT NULL DEFAULT 0,
            `rx`         FLOAT        NOT NULL DEFAULT 0,
            `ry`         FLOAT        NOT NULL DEFAULT 0,
            `rz`         FLOAT        NOT NULL DEFAULT 0,
            -- The stash this piece is (server/property_stashes.lua; migration 032 adds it to an
            -- existing table). NULL for furniture that holds nothing.
            `containerId` INT UNSIGNED DEFAULT NULL,
            `createdAt`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`objectId`),
            KEY `idx_pobj_property` (`propertyId`),
            KEY `idx_pobj_container` (`containerId`),
            CONSTRAINT `fk_pobj_property` FOREIGN KEY (`propertyId`)
                REFERENCES `properties` (`propertyId`) ON DELETE CASCADE,
            CONSTRAINT `fk_pobj_container` FOREIGN KEY (`containerId`)
                REFERENCES `containers` (`containerId`) ON DELETE SET NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ]])
end

function PropertyObjects.loadAll()
    PropertyObjects.ensureTable()
    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `property_objects` ORDER BY `objectId`', {})
    if not ok then
        print('[whip_core:properties] ERROR loading furniture: ' .. tostring(rows))
        return false   -- start-up halts (player_lifecycle.lua)
    end
    _rows, _version = {}, {}
    local n = 0
    for _, row in ipairs(rows or {}) do
        local list = _rows[row.propertyId]
        if not list then list = {}; _rows[row.propertyId] = list; _version[row.propertyId] = 1 end
        list[#list + 1] = row
        n = n + 1
    end
    print(('[whip_core:properties] %d piece%s of furniture'):format(n, n == 1 and '' or 's'))
end

-- ============================================
-- Reads
-- ============================================

---@return number
function PropertyObjects.count(propertyId)
    local list = _rows[tonumber(propertyId) or -1]
    return list and #list or 0
end

---@return number
function PropertyObjects.version(propertyId)
    return _version[tonumber(propertyId) or -1] or 0
end

--- One property's rows (local space), as held: for server/property_stashes.lua. Do not change them.
---@return table[]
function PropertyObjects.rowsOf(propertyId)
    return _rows[tonumber(propertyId) or -1] or {}
end

--- Every property's rows: [propertyId] = { row, ... }. For the start-up stash check; do not change them.
function PropertyObjects.allRows()
    return _rows
end

--- One property's rows as a client receives them: local coordinates, which the client places
--- with the property's own placement.
---
--- `light` marks a lamp (the catalog's lighting category). The client files lamps in the interior's
--- limbo rather than a room: a lamp forced into a room glows and lights nothing (see
--- client/interior_rooms.lua).
---
--- `stash` is the container a piece is (server/property_stashes.lua): the client puts the stash's prompt
--- round the piece, and the furnisher sends it back with the piece, which is how a stash stays with it.
local function wireRows(list)
    local out = {}
    for i, o in ipairs(list or {}) do
        local cat = PropCatalog.get(o.model)
        out[i] = { id = o.objectId, model = o.model, lx = o.lx, ly = o.ly, lz = o.lz,
                   rx = o.rx, ry = o.ry, rz = o.rz,
                   light = (cat and cat.category == 'lighting') or nil,
                   stash = o.containerId or nil }
    end
    return out
end

--- The version and count of every furnished property — all a client needs at login to know which
--- rooms have furniture and when a cached room has gone stale.
function PropertyObjects.sync(target)
    local index = {}
    for id, list in pairs(_rows) do
        index[#index + 1] = { id = id, v = _version[id] or 1, n = #list }
    end
    TriggerClientEvent('whip_core:client:propertyObjectsIndex', target or -1, index)
end

local function announce(propertyId)
    TriggerClientEvent('whip_core:client:propertyObjectsChanged', -1,
        propertyId, PropertyObjects.version(propertyId), PropertyObjects.count(propertyId))
end

--- Forget a property's furniture: called when the property goes (its rows went with it).
function PropertyObjects.forget(propertyId)
    propertyId = tonumber(propertyId)
    if not propertyId or not _rows[propertyId] then return end
    _rows[propertyId] = nil
    _version[propertyId] = (_version[propertyId] or 0) + 1
    announce(propertyId)
end

--- Take every piece of furniture out of a property: the admin panel's Clear. Unlike a save it asks
--- nothing of the space, so a property whose space is wrong can still be emptied.
---
--- ITS STASHES GO WITH IT, but only if every one is empty (server/property_stashes.lua): a Clear never
--- throws anybody's things away. Refused, saying which still holds something.
---@param actor number|nil  the admin's charId
---@return boolean ok, string|nil err
function PropertyObjects.clear(propertyId, actor)
    propertyId = tonumber(propertyId)
    if not propertyId then return false, 'Unknown property' end
    -- Not while a save is being written: its stashes are being made or checked (the save's own lock).
    if _saving[propertyId] then return false, 'This room is being saved — try again in a moment' end
    _saving[propertyId] = true
    local cok, sok, swhy = pcall(PropertyStashes.clear, propertyId, actor)
    _saving[propertyId] = nil
    if not cok then
        print(('[whip_core:property_objects] clearing the stashes of property %d failed: %s'):format(propertyId, tostring(sok)))
        return false, 'Could not clear the stashes — try again'
    end
    if not sok then return false, swhy end
    local ok, err = pcall(MySQL.query.await, 'DELETE FROM `property_objects` WHERE `propertyId`=?', { propertyId })
    if not ok then
        -- The raw error to the console, DB_ERROR to the caller.
        print(('[whip_core:property_objects] database error clearing property %s: %s'):format(tostring(propertyId), tostring(err)))
        return false, DB_ERROR
    end
    PropertyObjects.forget(propertyId)
    return true
end

-- ============================================
-- Writes
-- ============================================

--- Write a validated room (PropertyObjects.replace, below): the transaction, the re-read, the version.
---@return boolean ok, string|nil err
local function writeRoom(rec, clean)
    local queries = { { query = 'DELETE FROM `property_objects` WHERE `propertyId`=?', values = { rec.propertyId } } }
    for _, o in ipairs(clean) do
        queries[#queries + 1] = {
            query = 'INSERT INTO `property_objects` (`propertyId`,`model`,`lx`,`ly`,`lz`,`rx`,`ry`,`rz`,`containerId`) VALUES (?,?,?,?,?,?,?,?,?)',
            values = { rec.propertyId, o.model, o.lx, o.ly, o.lz, o.rx, o.ry, o.rz, o.containerId },
        }
    end
    local ok, err = Stores.runTransaction(queries, 'property_objects_replace')
    if not ok then
        print(('[whip_core:properties] FAILED saving furniture for property %d: %s'):format(rec.propertyId, tostring(err)))
        return false, 'Database error saving the furniture'
    end

    -- Re-read rather than patch: the inserts made new objectIds the transaction does not hand back.
    -- A re-read that fails does not blank the room: tried again, and if it never answers, memory takes
    -- what was just written (every row but its objectId, which nothing outside the database relies
    -- on), so the room stays visible and the next Save cannot delete it.
    local rows
    for attempt = 1, 3 do
        local rok, res = pcall(MySQL.query.await,
            'SELECT * FROM `property_objects` WHERE `propertyId`=? ORDER BY `objectId`', { rec.propertyId })
        if rok then rows = res or {} break end
        if attempt < 3 then Wait(500) end
    end
    if not rows then
        print(('[whip_core:properties] saved property %d but could not re-read it — keeping what was written'):format(rec.propertyId))
        rows = {}
        for i, o in ipairs(clean) do
            rows[i] = { objectId = -i, propertyId = rec.propertyId, model = o.model,
                        lx = o.lx, ly = o.ly, lz = o.lz, rx = o.rx, ry = o.ry, rz = o.rz, containerId = o.containerId }
        end
    end
    _rows[rec.propertyId] = #rows > 0 and rows or nil

    _version[rec.propertyId] = (_version[rec.propertyId] or 0) + 1
    announce(rec.propertyId)
    return true
end

--- Replace one property's furniture with `objects`, given in WORLD space.
---
--- Validated whole before anything is written, then one transaction: a bad model or a chair
--- through the wall refuses the save rather than half-emptying the room.
---
--- Only over the room the editor opened on: the editor sends the version it loaded, and a save over
--- any other version is refused (an editor opened on a failed or stale fetch must not delete the real
--- furniture).
---
--- Its stashes too (server/property_stashes.lua): a piece that is a stash keeps its stash through the
--- save (its `extra.stash`, sent back as it was opened on), a new one gets one, and a stash taken away
--- goes with it only when it is empty. A save that would throw a stash's things away is refused.
---@param objects table  list of { model, x, y, z, rx, ry, rz, extra? = { stash }, tag? }, world space
---@param baseVersion number  the version the editor loaded (PropertyObjects.version)
---@param actor number|nil  who is saving (their charId): what the stashes write down
---@return boolean ok, string|nil err
---@return table|nil stashes  with a success: { { tag, containerId or 0 }, ... } (see the end)
function PropertyObjects.replace(propertyId, objects, baseVersion, actor)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    if type(objects) ~= 'table' then return false, 'Expected a list of objects' end
    if rec.active == false then return false, 'This property is closed right now' end
    if baseVersion ~= PropertyObjects.version(rec.propertyId) then
        return false, 'This room changed since you opened the furnisher (someone else saved it) — close it and open it again'
    end
    local shapes = rec.world and rec.world.shapes
    if not shapes or #shapes == 0 then
        return false, 'This property\'s space is not set up yet — an admin needs to finish it'
    end

    local max = (rec.effective and tonumber(rec.effective.maxObjects)) or Config.PropertyMaxObjects or 150
    if #objects > max then
        return false, ('That is %d objects — the limit here is %d'):format(#objects, max)
    end

    -- What is already in the room may stay, even once its model stops being placeable: the catalog
    -- decides what can be ADDED. Counted per model, so the ones there can be kept and moved but no
    -- more of them added (taking a model out of the catalog must not refuse every room holding one).
    local already = {}
    for _, row in ipairs(_rows[rec.propertyId] or {}) do
        local m = tostring(row.model or ''):lower()
        already[m] = (already[m] or 0) + 1
    end

    local place = rec.place
    local clean = {}
    for i = 1, #objects do
        local o = objects[i]
        if type(o) ~= 'table' then return false, 'Malformed object list' end

        local model = tostring(o.model or ''):lower()
        if model == '' then return false, 'An object has no model' end
        local cat = PropCatalog.get(model)
        if not cat or cat.status == 'unavailable' then
            if (already[model] or 0) <= 0 then return false, ('"%s" is not a placeable prop'):format(model) end
            already[model] = already[model] - 1
        end

        local x, y, z = tonumber(o.x), tonumber(o.y), tonumber(o.z)
        if not x or not y or not z or x ~= x or y ~= y or z ~= z
            or math.abs(x) == math.huge or math.abs(y) == math.huge or math.abs(z) == math.huge then
            return false, 'An object has an impossible position'
        end
        if not Shapes.containsAny(shapes, x, y, z, SLACK) then
            return false, ('"%s" is outside the property'):format(model)
        end

        local rx, ry, rz = tonumber(o.rx) or 0.0, tonumber(o.ry) or 0.0, tonumber(o.rz) or 0.0
        if rx ~= rx or ry ~= ry or rz ~= rz then rx, ry, rz = 0.0, 0.0, 0.0 end

        local lx, ly, lz = PropertyMath.toLocal(place, x, y, z)
        clean[i] = { model = model, lx = lx, ly = ly, lz = lz, rx = rx % 360.0, ry = ry % 360.0,
                     rz = PropertyMath.headingToLocal(place, rz) }
    end

    -- One write of a room at a time: the version check above is read before the write's waits and the
    -- version only moves at its end, so two saves inside one round trip would both pass it. Nothing
    -- between that check and this mark waits, so a second save finds the mark and is refused; once
    -- the first is done, the version has moved and the check refuses it. Cleared however the write
    -- ends, an error included, so a room can never be left unsaveable.
    local id = rec.propertyId
    if _saving[id] then return false, 'This room is still being saved — try again in a moment' end
    _saving[id] = true
    -- The stashes inside the same lock: the ones leaving checked empty and held still, the new ones made
    -- and every row told its stash, all before the room is written, so a refusal writes nothing.
    local job, written = nil, false
    local okW, ok, err = pcall(function()
        local why
        job, why = PropertyStashes.prepare(rec, objects, clean, actor)
        if not job then return false, why end
        local made, mwhy = PropertyStashes.make(job, rec, objects, clean)
        if not made then job = nil; return false, mwhy end   -- (make let go of everything itself)
        local wok, werr = writeRoom(rec, clean)
        if not wok then
            PropertyStashes.abandon(job)
            job = nil
            return false, werr
        end
        written = true
        PropertyStashes.finish(job, rec, objects)
        return true
    end)
    _saving[id] = nil
    if not okW then
        -- An error before the room was written: what the stashes made or held is let go. After it, the
        -- room stands (and names its stashes); only the tidying after it was cut short.
        if job and not written then pcall(PropertyStashes.abandon, job) end
        print(('[whip_core:properties] FAILED saving furniture for property %d: %s'):format(id, tostring(ok)))
        return false, 'Database error saving the furniture'
    end
    if not ok then return false, err end

    -- Which piece is which stash now, for the furnisher that stays open: { tag, containerId or 0 } for
    -- each piece sent with a tag (its own number for the piece) that is a stash or was sent as one.
    local stashes = {}
    for i, o in ipairs(objects) do
        local tag = math.tointeger(tonumber(o.tag))
        local sent = type(o.extra) == 'table' and o.extra.stash ~= nil
        if tag and (sent or clean[i].containerId) then
            stashes[#stashes + 1] = { tag, clean[i].containerId or 0 }
        end
    end
    return true, nil, stashes
end

-- ============================================
-- One furnisher at a time
-- ============================================
--
-- Only one person has a property's furnisher open: opening it takes the property's lock (the
-- furnishLock callback); a second person is refused, told who has it; and a Save is taken only from
-- the lock's holder.
--
-- Tied to the player's session, never to a timer alone. It goes when the furnisher closes (every way
-- out of it on the client sends the close: Exit, Backspace, death, another /furnish), and the server
-- lets go by itself when the holder disconnects, logs out or switches character, or is no longer at
-- the property (a teleport away; not for an admin, who dresses properties from anywhere), or the
-- property is closed or gone. A holder found gone on any of those checks is let go there and then,
-- so a lock can never be stuck. whip_core restarting forgets them all, and every furnisher with it.

local _lock   = {}   -- [propertyId] = { source, charId, name, admin }
local _lockOf = {}   -- [source] = the propertyId they hold

--- At the property: the reach property:objects answers within.
local function atProperty(source, rec)
    local a = rec.world and rec.world.anchor
    if not a then return true end
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end
    local c = GetEntityCoords(ped)
    local reach = (Config.PropertyStreamRange or 60.0) + (a.r or 0) + 40.0
    local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
    return dx * dx + dy * dy + dz * dz <= reach * reach
end

--- Is a lock still its holder's session: the same player, on the same character?
local function lockLive(l)
    local p = Players[l.source]
    return p ~= nil and p.charId ~= nil and p.charId == l.charId
end

--- Let go of a property's lock. `tell`: why, sent to the holder's furnisher, which closes.
local function unlock(propertyId, tell)
    local l = _lock[propertyId]
    if not l then return end
    _lock[propertyId] = nil
    if _lockOf[l.source] == propertyId then _lockOf[l.source] = nil end
    if tell then TriggerClientEvent('whip_core:client:propertyFurnishLost', l.source, propertyId, tell) end
end

--- Does `source` (on this character) hold the property's lock?
local function holdsLock(source, player, propertyId)
    local l = _lock[propertyId]
    return l ~= nil and l.source == source and player ~= nil and l.charId == player.charId
end

--- Who has a property's furnisher open: their name, or nil. (For an admin panel or a test.)
---@return string|nil
function PropertyObjects.furnishingBy(propertyId)
    local l = _lock[tonumber(propertyId) or -1]
    return l and lockLive(l) and l.name or nil
end

--- The furnisher opening: the owner, or an admin; at the property unless an admin; nobody else in it.
SecureCallback('whip_core:property:furnishLock', {
    rateLimit = 1000,
    burst     = 3,
    params    = { {'propertyId', 'id'} },
}, function(source, player, propertyId)
    local rec = Properties.get(propertyId)
    if not rec then return { ok = false, why = 'Unknown property' } end
    if rec.active == false then return { ok = false, why = 'This property is closed right now' } end
    local mine = player and rec.ownerCharId and rec.ownerCharId == player.charId
    local admin = DevTools.isAllowed(source)   -- developer mode on, too
    if not mine and not admin then return { ok = false, why = 'That is not your property' } end
    if not admin and not atProperty(source, rec) then return { ok = false, why = 'You need to be at the property to furnish it' } end

    local id = rec.propertyId
    local l = _lock[id]
    if l and l.source ~= source and lockLive(l) then
        return { ok = false, why = ('%s is furnishing this property right now — try again when they are done'):format(l.name) }
    end
    if l then unlock(id) end                                         -- a stale holder, or their own again
    if _lockOf[source] ~= nil then unlock(_lockOf[source]) end       -- one property at a time
    _lock[id] = { source = source, charId = player.charId, name = player.fullName or 'Someone', admin = admin }
    _lockOf[source] = id
    -- Released if anything after this in the call errors (secure.lua): never held by a failed open.
    TrackInvocationLock(function() unlock(id) end)
    return { ok = true }
end)

--- The furnisher closed (every way out of it sends this). Only the holder's close lets go.
SecureEvent('whip_core:server:propertyFurnishClosed', {
    whileDead = true,   -- dying closes the furnisher, and its lock has to go with it
    rateLimit = 250,
    burst     = 4,
    params    = { {'propertyId', 'id'} },
}, function(source, _, propertyId)
    local l = _lock[propertyId]
    if l and l.source == source then unlock(propertyId) end
end)

local function unlockFor(source)
    local id = _lockOf[source]
    if id then unlock(id) end
end
Character.onLife('logout', function(e) if e and e.source then unlockFor(e.source) end end)   -- logout, disconnect
AddEventHandler('playerDropped', function() unlockFor(source) end)

-- The holder no longer at the property, or the property closed or gone: let go, and their furnisher
-- closes saying why. A lock whose session is over goes with no message (there is nobody to tell).
Every('property-furnish-locks', 5000, function()
    if next(_lock) == nil then return 10000 end
    for id, l in pairs(_lock) do   -- (clearing a field while walking the table is allowed)
        local rec = Properties.get(id)
        if not lockLive(l) then
            unlock(id)
        elseif not rec then
            unlock(id, 'this property is gone')
        elseif rec.active == false then
            unlock(id, 'this property was closed')
        elseif not l.admin and not atProperty(l.source, rec) then
            unlock(id, 'you left the property')
        end
    end
end)

-- ============================================
-- Events
-- ============================================

--- A room's furniture, for a client whose player has come near it.
---
--- NEAR ONLY: the property's own streaming distance, from its anchor, with room to spare. A client
--- has no reason to ask for a room across the map, and answering would hand anyone a way to read
--- every furnished room on the server.
SecureCallback('whip_core:property:objects', {
    rateLimit = 100,
    burst     = 20,
    params    = { {'propertyId', 'id'} },
}, function(source, _, propertyId)
    -- A refusal says why (false, why), never nil, which reads as "no answer, try again" (audit 20, WLD-3)
    local rec = Properties.get(propertyId)
    if not rec then return false, 'Unknown property' end
    local a = rec.world and rec.world.anchor
    if a then
        local c = GetEntityCoords(GetPlayerPed(source))
        local reach = (Config.PropertyStreamRange or 60.0) + (a.r or 0) + 40.0
        local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
        if dx * dx + dy * dy + dz * dz > reach * reach then return false, 'Too far from the property' end
    end
    return { version = PropertyObjects.version(propertyId), rows = wireRows(_rows[rec.propertyId]) }
end)

--- The furnisher's save. The owner, or an admin dressing a property before it is sold.
SecureEvent('whip_core:server:propertyObjectsSave', {
    -- Each save is a delete, up to a few hundred inserts and a re-read.
    rateLimit = 4000,
    -- baseVersion: the room the editor opened on. 'id' with 0 allowed: exact or refused, never clamped.
    params = { {'propertyId', 'id'}, {'objects', 'any'}, {'baseVersion', 'id', 0} },
}, function(source, player, propertyId, objects, baseVersion)
    local rec = Properties.get(propertyId)
    if not rec then
        ShowError(source, 'Unknown property')
        TriggerClientEvent('whip_core:client:propertyFurnishSaved', source, false)
        return
    end

    local mine = player and rec.ownerCharId and rec.ownerCharId == player.charId
    local admin = DevTools.isAllowed(source)
    if not mine and not admin then
        RecordEventRejection('whip_core:server:propertyObjectsSave', source, 'Not the owner')
        ShowError(source, 'That is not your property')
        TriggerClientEvent('whip_core:client:propertyFurnishSaved', source, false)
        return
    end

    -- At the property, the same reach property:objects answers within. The
    -- furnisher only runs there, and every save rebuilds the room on every client that has it
    -- spawned — an owner could repeat that every four seconds from across the map. Admins dress
    -- properties from wherever they are.
    local a = rec.world and rec.world.anchor
    if a and not admin then
        local c = GetEntityCoords(GetPlayerPed(source))
        local reach = (Config.PropertyStreamRange or 60.0) + (a.r or 0) + 40.0
        local dx, dy, dz = c.x - a.x, c.y - a.y, c.z - a.z
        if dx * dx + dy * dy + dz * dz > reach * reach then
            RecordEventRejection('whip_core:server:propertyObjectsSave', source, 'not at the property')
            ShowError(source, 'You need to be at the property to save its furniture')
            TriggerClientEvent('whip_core:client:propertyFurnishSaved', source, false)
            return
        end
    end

    -- Only from the one furnishing it: the holder of the property's lock (below).
    if not holdsLock(source, player, rec.propertyId) then
        ShowError(source, 'Your furnisher is not open on this property any more — open it again')
        TriggerClientEvent('whip_core:client:propertyFurnishSaved', source, false)
        return
    end

    local ok, err, stashes = PropertyObjects.replace(propertyId, objects, baseVersion, player and player.charId)
    if ok then
        ShowSuccess(source,
            ('Saved — %d object(s)'):format(type(objects) == 'table' and #objects or 0))
    else
        ShowError(source, err or 'Could not save')
    end
    -- The new version rides the answer: the editor stays open, and its next Save is over this one. And
    -- which piece is which stash, so the next Save keeps them.
    TriggerClientEvent('whip_core:client:propertyFurnishSaved', source, ok == true, PropertyObjects.version(propertyId), stashes)
end)

exports('GetPropertyObjectCount', function(propertyId) return PropertyObjects.count(propertyId) end)
exports('GetPropertyObjectVersion', function(propertyId) return PropertyObjects.version(propertyId) end)
