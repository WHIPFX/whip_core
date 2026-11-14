-- ============================================
-- Property stashes — furniture that holds things
-- ============================================
--
-- Put down furniture that is a stash, and it belongs to that property: nobody opens
-- it but the owner and the people with a key.
--
-- WHICH FURNITURE: Config.PropertyStashProps, model -> { label, slots, weight }. Those props are placed
-- like any other. They stay in their own category in the furnisher and show under Containers as well:
-- the catalog marks them (server/prop_catalog.lua, `stash` on each row).
--
-- WHAT ONE IS: a container (server/containers.lua) with
--   propertyId     the property it belongs to
--   requirements   { property = id }: the owner and the keyholders open it, nobody else
--   prop = false   no prop of its own: the furniture is what you see, and its prompt goes round it
-- and the piece of furniture's row names its container (property_objects.containerId).
--
-- KEPT THROUGH EVERY SAVE. A furniture save writes the room anew (PropertyObjects.replace), so the link
-- travels with the piece: the furnisher gets `extra.stash` with each row it opens on, and sends it back
-- with the row.
--   a piece sent back with its stash      keeps it, and the stash follows it to where it now stands
--   a stash piece sent with none          gets a new, empty stash
--   a stash no piece is sent back with    goes with its piece, but ONLY ONCE IT IS EMPTY
-- A STASH WITH ANYTHING IN IT IS NEVER THROWN AWAY BY A SAVE: the save is refused, saying what to empty
-- first. A stash id that is not this property's, or that comes twice, counts as none, so a modified
-- game can neither take another home's stash nor share one stash between two pieces.
--
-- A SAVE, IN ORDER, inside the room's save lock (PropertyObjects.replace):
--   1. prepare  the stashes leaving are frozen (nothing goes in or out) and checked empty
--   2. make     new stashes are made, and every row learns its stash
--   3. (the room is written, each row with its stash)
--   4. finish   the stashes that left are deleted; the kept ones follow their furniture
-- A failure at 2 or 3 deletes the stashes it made and lets go of the freeze (abandon), so a refused
-- save changes nothing.
--
-- AND ELSEWHERE:
--   a property deleted        takes its stashes; what they held is written down as lost
--   the admin's Clear         refused while a stash holds anything (an admin can open any stash from
--                             the Container Manager)
--   a property re-bound       its stashes follow their furniture (Properties.resync)
--   start-up                  a stash no furniture is (a delete that failed half-way) goes if it is
--                             empty, and is kept and said if not: its owner can still open it where it
--                             stands, and an admin from the Container Manager
-- The property changing hands keeps its stashes and what is in them, as it keeps its furniture.

PropertyStashes = {}

local function log(fmt, ...) print(('[whip_core:property_stashes] ' .. fmt):format(...)) end

-- Config.PropertyStashProps by lowercase model (a key typed in capitals still counts), rebuilt when the
-- setting is replaced (/whip → Settings).
local _byOf, _by = nil, {}
local function byModel()
    local t = Config.PropertyStashProps
    if t ~= _byOf then
        _byOf, _by = t, {}
        if type(t) == 'table' then
            for k, v in pairs(t) do if type(k) == 'string' then _by[k:lower()] = v end end
        end
    end
    return _by
end

--- What a model holds as a stash: { label, slots, weight }, or nil when it is not one.
---@param model string
---@return table|nil
function PropertyStashes.spec(model)
    if type(model) ~= 'string' then return nil end
    local s = byModel()[model:lower()]
    if type(s) ~= 'table' then return nil end
    local slots, weight = math.tointeger(tonumber(s.slots)), tonumber(s.weight)
    if not slots or slots < 1 or not weight or weight <= 0 then return nil end
    local label = (type(s.label) == 'string' and s.label ~= '') and s.label:sub(1, 40) or 'Stash'
    return { label = label, slots = math.min(slots, 500), weight = weight }
end

--- The most stashes one property may have.
function PropertyStashes.limit()
    return math.max(0, math.floor(tonumber(Config.PropertyStashLimit) or 6))
end

--- This property's stashes: [containerId] = def.
---@return table<number, table>
function PropertyStashes.of(propertyId)
    local out = {}
    for id, def in pairs(Containers.getAll()) do
        if def.propertyId == propertyId then out[id] = def end
    end
    return out
end

--- How many things a stash holds (0 empty), reading it if it is not in memory: nil when it could not be
--- read. `loadedHere` when this read it in, for a caller that is not about to delete it to let go of.
---@return number|nil count
---@return boolean loadedHere
local function holdings(id)
    local loadedHere = false
    if not Containers.invCache[id] then
        if not Containers.loadInventory(id) then return nil, false end
        loadedHere = true
    end
    local n = 0
    for _, s in pairs(Containers.invCache[id] or {}) do
        if type(s) == 'table' and s.item then n = n + (tonumber(s.amount) or 1) end
    end
    return n, loadedHere
end

local function unitOf(id) return 'container:' .. tostring(id) end

--- A stash to where its furniture stands, if it is not there already.
local function moveTo(id, x, y, z, heading)
    local def = Containers.getDef(id)
    if not def or not (x and y and z) then return end
    heading = (tonumber(heading) or 0.0) % 360.0
    local dx, dy, dz = (def.x or 0) - x, (def.y or 0) - y, (def.z or 0) - z
    local dh = math.abs(((def.heading or 0.0) - heading + 180.0) % 360.0 - 180.0)
    if dx * dx + dy * dy + dz * dz < 0.0004 and dh < 1.0 then return end
    local ok, why = Containers.update(id, { x = x, y = y, z = z, heading = heading })
    if not ok then log('stash #%d could not follow its furniture: %s', id, tostring(why)) end
end

--- Freeze these stashes and make sure each is empty. Answers the freeze tokens, or false and why (with
--- every freeze let go).
local function freezeEmpty(ids, defs)
    local frozen = {}
    for _, id in ipairs(ids) do frozen[#frozen + 1] = Stores.freeze(unitOf(id)) end
    local function thaw() for _, t in ipairs(frozen) do Stores.unfreeze(t) end end
    for _, id in ipairs(ids) do
        local name = (defs[id] and defs[id].name) or 'stash'
        local n, loadedHere = holdings(id)
        if n == nil then
            thaw()
            return false, ('Could not check what the %s holds — try again'):format(name)
        end
        if n > 0 then
            if loadedHere then pcall(Containers.unloadInventory, id) end
            thaw()
            return false, ('Empty the %s first — it still holds %d thing%s'):format(name, n, n == 1 and '' or 's')
        end
    end
    return frozen
end

-- ============================================
-- A furniture save (PropertyObjects.replace)
-- ============================================

--- Step 1. `objects` as the furnisher sent them (world space, each with its `extra.stash`), `clean` as
--- checked (the same order). Answers the save's stash job, or false and why with nothing held.
---@param rec table
---@param objects table
---@param clean table
---@param actor number|nil  who is saving (their charId), for what the stashes write down
---@return table|false job
---@return string|nil why
function PropertyStashes.prepare(rec, objects, clean, actor)
    local mine = PropertyStashes.of(rec.propertyId)
    local keep, create, seen, kept = {}, {}, {}, 0
    for i, o in ipairs(objects) do
        local extra = type(o) == 'table' and type(o.extra) == 'table' and o.extra or nil
        local sent = extra and math.tointeger(tonumber(extra.stash)) or nil
        if sent and mine[sent] and not seen[sent] then
            keep[i], seen[sent], kept = sent, true, kept + 1
        elseif PropertyStashes.spec(clean[i].model) then
            create[#create + 1] = i
        end
    end
    -- The limit is on ADDING: a room already over it (the limit lowered) can still be saved.
    local limit = PropertyStashes.limit()
    if #create > 0 and kept + #create > limit then
        return false, ('That is %d stashes — one property may have %d'):format(kept + #create, limit)
    end

    local remove = {}
    for id in pairs(mine) do if not seen[id] then remove[#remove + 1] = id end end
    table.sort(remove)
    local frozen, why = freezeEmpty(remove, mine)
    if not frozen then return false, why end
    return { keep = keep, create = create, remove = remove, frozen = frozen, made = {}, actor = actor }
end

--- Step 2: the new stashes made, and every row in `clean` told its stash (`containerId`). Answers true,
--- or false and why with nothing made and nothing held.
function PropertyStashes.make(job, rec, objects, clean)
    for i, id in pairs(job.keep) do clean[i].containerId = id end
    for _, i in ipairs(job.create) do
        local spec, o = PropertyStashes.spec(clean[i].model), objects[i]
        -- prepare put only stash models in job.create, but the stash list can change while a stash before this one
        -- is made (Containers.create waits).
        if not spec then
            PropertyStashes.abandon(job)
            return false, 'The stash models changed during the save: try again'
        end
        local def, why = Containers.create({
            name = spec.label, type = 'stash', slots = spec.slots, maxWeight = spec.weight,
            x = tonumber(o.x), y = tonumber(o.y), z = tonumber(o.z), heading = (tonumber(o.rz) or 0.0) % 360.0,
            prop = false, propertyId = rec.propertyId, requirements = { property = rec.propertyId },
            createdBy = job.actor,
        })
        if not def then
            PropertyStashes.abandon(job)
            return false, 'Could not make the ' .. spec.label:lower() .. ': ' .. tostring(why)
        end
        job.made[#job.made + 1] = def.containerId
        clean[i].containerId = def.containerId
    end
    return true
end

--- A save that failed after step 1: the stashes it made go (they are empty), the freeze is let go.
function PropertyStashes.abandon(job)
    if not job then return end
    for _, id in ipairs(job.made or {}) do
        local ok, why = Containers.delete(id, job.actor)
        if not ok then log('a stash made for a save that failed (#%d) could not be deleted: %s — it goes at the next start', id, tostring(why)) end
    end
    job.made = {}
    for _, t in ipairs(job.frozen or {}) do Stores.unfreeze(t) end
    job.frozen = {}
end

--- Step 4, the room written: the stashes that left go; the kept ones follow their furniture.
function PropertyStashes.finish(job, rec, objects)
    for _, id in ipairs(job.remove) do
        local ok, why = Containers.delete(id, job.actor)
        if not ok then
            log('stash #%d of property %d was taken away but could not be deleted: %s — it goes at the next start',
                id, rec.propertyId, tostring(why))
        end
    end
    for _, t in ipairs(job.frozen) do Stores.unfreeze(t) end
    job.frozen = {}
    for i, id in pairs(job.keep) do
        local o = objects[i]
        moveTo(id, tonumber(o.x), tonumber(o.y), tonumber(o.z), tonumber(o.rz))
    end
end

-- ============================================
-- The property's other changes
-- ============================================

--- The admin's Clear: every stash goes, but only if every one is empty. Answers true, or false and why.
---@return boolean ok, string|nil why
function PropertyStashes.clear(propertyId, actor)
    local mine = PropertyStashes.of(propertyId)
    local ids = {}
    for id in pairs(mine) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then return true end
    local frozen, why = freezeEmpty(ids, mine)
    if not frozen then
        return false, why .. ' (an admin can open any stash from the Container Manager)'
    end
    for _, id in ipairs(ids) do
        local ok, err = Containers.delete(id, actor)
        if not ok then log('stash #%d could not be deleted with its room: %s', id, tostring(err)) end
    end
    for _, t in ipairs(frozen) do Stores.unfreeze(t) end
    return true
end

--- The property was deleted: its stashes go, what they held written down as lost (Containers.delete).
function PropertyStashes.removeAll(propertyId)
    for id in pairs(PropertyStashes.of(propertyId)) do
        local ok, err = Containers.delete(id, nil)
        if not ok then log('stash #%d of deleted property %d could not be deleted: %s', id, propertyId, tostring(err)) end
    end
end

--- A property's stashes to where its furniture stands now (its placement moved: Re-bind, a pack).
--- Writes only what moved.
function PropertyStashes.follow(rec)
    if not rec or not rec.place then return end
    for _, row in ipairs(PropertyObjects.rowsOf(rec.propertyId)) do
        if row.containerId and Containers.getDef(row.containerId) then
            local x, y, z = PropertyMath.toWorld(rec.place, row.lx or 0.0, row.ly or 0.0, row.lz or 0.0)
            moveTo(row.containerId, x, y, z, PropertyMath.headingToWorld(rec.place, row.rz or 0.0))
        end
    end
end

-- ============================================
-- Start-up
-- ============================================

--- After properties, their furniture and every container have loaded: furniture and stashes agree.
---   a row naming a stash that is gone, or not its property's, or another row's   -> plain furniture
---   a stash no furniture is (a delete that failed half-way)                      -> deleted if empty,
---                                                                                   kept and said if not
---   every stash where its furniture stands
function PropertyStashes.reconcile()
    local linked, unlink = {}, {}
    for propertyId, list in pairs(PropertyObjects.allRows()) do
        for _, row in ipairs(list) do
            local id = row.containerId
            if id then
                local def = Containers.getDef(id)
                if def and def.propertyId == propertyId and not linked[id] then linked[id] = propertyId
                else unlink[#unlink + 1] = row end
            end
        end
    end
    for _, row in ipairs(unlink) do
        local ok, err = pcall(MySQL.update.await, 'UPDATE `property_objects` SET `containerId` = NULL WHERE `objectId` = ?', { row.objectId })
        if ok then row.containerId = nil else log('could not unlink furniture #%s from its stash: %s', tostring(row.objectId), tostring(err)) end
    end

    local loose = {}
    for id, def in pairs(Containers.getAll()) do
        if def.propertyId and not linked[id] then loose[#loose + 1] = id end
    end
    table.sort(loose)
    for _, id in ipairs(loose) do
        local def = Containers.getDef(id)
        local n, loadedHere = holdings(id)
        if n and n > 0 and loadedHere then pcall(Containers.unloadInventory, id) end
        if n == 0 then
            local ok, err = Containers.delete(id, nil)
            if not ok then log('a stash no furniture is (#%d) could not be deleted: %s', id, tostring(err)) end
        elseif n == nil then
            log('stash #%d (property %s) is no piece of furniture and could not be read: left as it is', id, tostring(def.propertyId))
        else
            log('stash #%d (property %s) is no piece of furniture, and still holds %d thing(s): kept where it stands. Its owner can still open it; an admin from the Container Manager.',
                id, tostring(def.propertyId), n)
        end
    end

    local done = {}
    for _, propertyId in pairs(linked) do
        if not done[propertyId] then
            done[propertyId] = true
            PropertyStashes.follow(Properties.get(propertyId))
        end
    end
    local n = 0
    for _ in pairs(linked) do n = n + 1 end
    if n > 0 or #unlink > 0 then log('%d stash(es) in properties; %d piece(s) of furniture unlinked from a stash that was gone', n, #unlink) end
end

--- A property's stashes for another resource (a police raid, a server owner's tool): plain data.
---@return table[] { containerId, name, slots, maxWeight, x, y, z }
exports('GetPropertyStashes', function(propertyId)
    local out = {}
    for id, def in pairs(PropertyStashes.of(tonumber(propertyId))) do
        out[#out + 1] = { containerId = id, name = def.name, slots = def.slots, maxWeight = def.maxWeight,
                          x = def.x, y = def.y, z = def.z }
    end
    table.sort(out, function(a, b) return a.containerId < b.containerId end)
    return out
end)

-- ============================================
-- Test seams (whip_test 68). Inert unless Config.EnableTestSeams.
-- ============================================

--- A furniture save as the furnisher makes it, over the room's current version, with nobody saving.
--- One table back: an export drops every value after a nil, and a success's error is nil.
---@return table { ok, err, stashes }
exports('__TestFurnitureSave', function(propertyId, objects)
    if Config.EnableTestSeams ~= true then return { ok = false, err = 'test seams are off' } end
    local ok, err, stashes = PropertyObjects.replace(propertyId, objects, PropertyObjects.version(tonumber(propertyId)), nil)
    return { ok = ok == true, err = err, stashes = stashes or {} }
end)

--- The admin's Clear.
exports('__TestFurnitureClear', function(propertyId)
    if Config.EnableTestSeams ~= true then return false, 'test seams are off' end
    return PropertyObjects.clear(propertyId, nil)
end)

--- What the tests place: a stash model and a plain one, both placeable, and the limit.
exports('__TestStashSetup', function()
    if Config.EnableTestSeams ~= true then return nil end
    local stash, plain
    local models = {}
    for m in pairs(byModel()) do models[#models + 1] = m end
    table.sort(models)
    for _, m in ipairs(models) do
        local row = PropCatalog.get(m)
        if row and row.status ~= 'unavailable' and PropertyStashes.spec(m) then stash = m break end
    end
    local all = {}
    for m, row in pairs(PropCatalog.getAll()) do
        if row.status ~= 'unavailable' and not PropertyStashes.spec(m) then all[#all + 1] = m end
    end
    table.sort(all)
    plain = all[1]
    return { stash = stash, plain = plain, limit = PropertyStashes.limit() }
end)
