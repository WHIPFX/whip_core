-- ============================================
-- Garage spots — server
-- The parking bays a garage is reached through.
-- ============================================
--
-- A GARAGE USED TO BE ONE PLACE. It had a position you stood at and a position cars appeared at,
-- both columns on its own row — which is right for a lock-up with one door and wrong for anything
-- shaped like a car park, where the same garage should be reachable from any of thirty bays.
--
-- A SPOT IS AN ENTRY POINT, NOT A GARAGE. Every spot belongs to exactly one garage and adds nothing
-- of its own except a place: the vehicles, the name, the blip and the permissions all still live on
-- the garage. Thirty bays on one garage is one garage with thirty ways in, and emphatically not
-- thirty garages that happen to share a name.
--
-- A SPOT IS ALSO WHERE THE CAR ARRIVES. The bay you press E in is the bay the car is put in, which
-- is what makes several of them useful rather than merely decorative — the old single `spawnX` is
-- still there and is still the answer for a garage with no spots at all.
--
-- ITS OWN TABLE, like doors and zones, rather than a list folded into the garage row. Spots are
-- set out in the world (the bay tool), they carry their own id, and a child table is what every
-- other record-shaped thing in whip already is.

GarageSpots = {}
GarageSpots._records = {}   -- [spotId] = { spotId, garageKey, x, y, z, heading, label }

-- ============================================
-- Storage
-- ============================================

function GarageSpots.ensureTable()
    local ok, err = pcall(MySQL.query.await, WithTableCollation [[
        CREATE TABLE IF NOT EXISTS `garage_spots` (
            `spotId`     INT UNSIGNED  NOT NULL AUTO_INCREMENT,
            `garageKey`  VARCHAR(60)   NOT NULL,
            `x`          FLOAT         NOT NULL DEFAULT 0,
            `y`          FLOAT         NOT NULL DEFAULT 0,
            `z`          FLOAT         NOT NULL DEFAULT 0,
            `heading`    FLOAT         NOT NULL DEFAULT 0,
            `label`      VARCHAR(60)   NULL,
            PRIMARY KEY (`spotId`),
            KEY `idx_garageKey` (`garageKey`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {})

    if not ok then
        print(('[whip_core:garage] ERROR creating garage_spots table: %s'):format(tostring(err)))
    end
    return ok
end

function GarageSpots.loadAll()
    GarageSpots.ensureTable()

    local ok, rows = pcall(MySQL.query.await, 'SELECT * FROM `garage_spots`', {})
    if not ok then
        print(('[whip_core:garage] ERROR loading garage spots: %s'):format(tostring(rows)))
        return false   -- start-up halts (player_lifecycle.lua)
    end

    GarageSpots._records = {}
    if rows then
        for _, r in ipairs(rows) do
            GarageSpots._records[r.spotId] = {
                spotId    = r.spotId,
                garageKey = r.garageKey,
                x = r.x, y = r.y, z = r.z, heading = r.heading,
                label     = r.label,
            }
        end
    end
end

--- Give a NEW garage its first bay, at its spawn point (or its marker when it has none).
---
--- A GARAGE WITH NO BAYS CANNOT BE REACHED — bays are the only way in, so without one it is a name,
--- a blip and a list of cars nobody can get to. Garages.create calls this for every new garage,
--- whichever way it was made: the config seed on first boot, the Garage Manager, CreateGarage.
---
--- Once, at birth, and never again: a garage whose last bay an admin deleted on purpose must not get
--- one back at the next restart.
---@param key string
---@return table|nil spot
function GarageSpots.seedGarage(key)
    local g = Garages.get(key)
    if not g then return nil end

    -- The garage's own position when it has no spawn point worth the name. A zeroed spawn column
    -- would otherwise put the bay at the map origin.
    local x, y, z, h = g.spawnX, g.spawnY, g.spawnZ, g.spawnHeading
    if not x or (x == 0 and y == 0 and z == 0) then
        x, y, z, h = g.x, g.y, g.z, g.heading
    end
    if not x or (x == 0 and y == 0 and z == 0) then
        print(('[whip_core:garage] garage "%s" has no usable position, so it has no parking spot '
            .. 'and cannot be reached. Add one with the Garage Manager.'):format(key))
        return nil
    end

    local spot, err = GarageSpots.create(key, x, y, z, h or 0.0, nil)
    if not spot then
        print(('[whip_core:garage] could not give garage "%s" its first parking spot: %s'):format(key, tostring(err)))
    end
    return spot
end

-- ============================================
-- Reads
-- ============================================

---@return table[]  every spot, as a flat list for the wire
function GarageSpots.all()
    local out = {}
    for _, s in pairs(GarageSpots._records) do
        out[#out + 1] = s
    end
    return out
end

---@param spotId number
---@return table|nil
function GarageSpots.get(spotId)
    return GarageSpots._records[tonumber(spotId) or -1]
end

--- The spot nearest a position, within `range`.
---
--- USED TO DECIDE WHICH BAY A CAR IS SITTING IN, which is why it answers with a distance too — the
--- caller wants to know how sure the answer is, not just what it was.
---@return table|nil spot, number|nil distance
function GarageSpots.nearest(x, y, z, range)
    range = range or 5.0
    local best, bestD = nil, range * range
    for _, s in pairs(GarageSpots._records) do
        local dx, dy, dz = s.x - x, s.y - y, s.z - z
        local d = dx * dx + dy * dy + dz * dz
        if d < bestD then best, bestD = s, d end
    end
    if not best then return nil end
    return best, math.sqrt(bestD)
end

-- ============================================
-- Writes
-- ============================================

--- Add a bay to a garage.
---@return table|nil spot, string|nil err
function GarageSpots.create(garageKey, x, y, z, heading, label)
    if type(garageKey) ~= 'string' or garageKey == '' then return nil, 'Expected a garage key' end
    if not Garages.get(garageKey) then return nil, 'Unknown garage' end

    local ok, id = pcall(MySQL.insert.await,
        'INSERT INTO `garage_spots` (`garageKey`,`x`,`y`,`z`,`heading`,`label`) VALUES (?,?,?,?,?,?)',
        { garageKey, x + 0.0, y + 0.0, z + 0.0, (heading or 0.0) + 0.0, label })

    if not ok or not id then
        return nil, 'Database error creating spot'
    end

    local spot = {
        spotId = id, garageKey = garageKey,
        x = x + 0.0, y = y + 0.0, z = z + 0.0, heading = (heading or 0.0) + 0.0,
        label = label,
    }
    GarageSpots._records[id] = spot

    TriggerClientEvent('whip_core:client:garageSpotCreated', -1, spot)
    return spot
end

--- Move an existing bay, keeping its id.
---
--- Takes a point, trusted: whoever calls it with one a player sent leashes it to that player first
--- (whip_core:gmWizardSave, Config.GarageWizardReach), so "anywhere on the map from anywhere else on it"
--- is still impossible — the same shape placeItem uses for the same reason.
---@param spotId number|nil
---@param x number|nil
---@param y number|nil
---@param z number|nil
---@param heading number|nil
---@return table|nil spot, string|nil err
function GarageSpots.update(spotId, x, y, z, heading)
    spotId = tonumber(spotId)
    local spot = spotId and GarageSpots._records[spotId]
    if not spot then return nil, 'Unknown spot' end

    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    heading = tonumber(heading)
    if not (x and y and z and heading) then return nil, 'Expected a position and a heading' end

    -- Wrapped into 0..360 here rather than trusting the caller. A heading of -45 or 400 stores
    -- and reads back fine, and then every comparison against it — the helper's alignment test
    -- especially — is quietly working in a different number space from everything else.
    heading = heading % 360.0

    local ok = pcall(MySQL.query.await,
        'UPDATE `garage_spots` SET `x` = ?, `y` = ?, `z` = ?, `heading` = ? WHERE `spotId` = ?',
        { x + 0.0, y + 0.0, z + 0.0, heading, spotId })
    if not ok then return nil, 'Database error updating spot' end

    -- ROW FIRST, MEMORY SECOND, the same order Shops.setSlotPrice states: a discarded failure
    -- would move the bay for everyone until the next restart put it silently back.
    spot.x, spot.y, spot.z, spot.heading = x + 0.0, y + 0.0, z + 0.0, heading

    TriggerClientEvent('whip_core:client:garageSpotUpdated', -1, spot)
    return spot
end

---@return boolean ok, string|nil err
function GarageSpots.delete(spotId)
    spotId = tonumber(spotId)
    if not spotId or not GarageSpots._records[spotId] then return false, 'Unknown spot' end

    local ok = pcall(MySQL.query.await, 'DELETE FROM `garage_spots` WHERE `spotId` = ?', { spotId })
    if not ok then return false, 'Database error deleting spot' end

    GarageSpots._records[spotId] = nil
    TriggerClientEvent('whip_core:client:garageSpotDeleted', -1, spotId)
    return true
end

--- Drop every spot belonging to a garage.
---
--- CALLED WHEN THE GARAGE ITSELF GOES. A spot whose garage no longer exists is a prompt that opens
--- a list of nothing, which is worse than no prompt — and the row would sit in the table forever,
--- since nothing else would ever look at it again.
---@param garageKey string
---@return number removed
function GarageSpots.deleteForGarage(garageKey)
    local doomed = {}
    for id, s in pairs(GarageSpots._records) do
        if s.garageKey == garageKey then doomed[#doomed + 1] = id end
    end
    for _, id in ipairs(doomed) do GarageSpots.delete(id) end
    return #doomed
end

-- ============================================
-- Sync
-- ============================================

--- Push the full set at a player, or at everyone when `target` is -1.
function GarageSpots.sync(target)
    TriggerClientEvent('whip_core:client:garageSpotsSync', target or -1, GarageSpots.all())
end

-- ============================================
-- No editor events
-- ============================================
--
-- One way to set bays out: the bay tool, through the garage wizard, whose saves are
-- server/devtools.lua's (whip_core:gmWizardCreate for a new garage, whip_core:gmWizardSave for a saved
-- one: they add, move and remove, leashed to the admin).

exports('__GetGarageSpots', function() return GarageSpots.all() end)
exports('__GetGarageSpot', function(spotId) return GarageSpots.get(spotId) end)
